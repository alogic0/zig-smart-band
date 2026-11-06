const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../src/history.js'), 'utf8'), context);
const history = context.SleepTodayHistory;
const {makeStore, fixtureFs} = require('./fixtures.cjs');

function fileSystem(bytes, options = {}) {
  let cursor = 0, closed = 0;
  return {
    O_RDONLY: 0, SEEK_SET: 0,
    get closed() { return closed; },
    stat_asset(name) { assert.equal(name, '../../../health_allday_activity'); return [{size: bytes.length}, 0]; },
    open_asset(name, flags) { assert.equal(name, '../../../health_allday_activity'); assert.equal(flags, 0); return 3; },
    seek(handle, position, mode) { assert.equal(handle, 3); assert.equal(mode, 0); cursor = position; return options.seekFailure ? -1 : position; },
    read(handle, buffer, offset, length) {
      assert.equal(handle, 3);
      if (options.readFailure) return 0;
      const take = Math.min(options.chunk || length, length, bytes.length - cursor);
      new Uint8Array(buffer).set(bytes.subarray(cursor, cursor + take), offset);
      cursor += take;
      return take;
    },
    close(handle) { assert.equal(handle, 3); closed++; }
  };
}

test('read-only ranges support partial reads and offsets from EOF without leaking a handle', () => {
  const bytes = Buffer.from(Array.from({length: 256}, (_, i) => i));
  const files = fileSystem(bytes, {chunk: 7});
  const result = history.inspect(files, [{offset: 10, length: 23}, {offset: -16, length: 16}]);
  assert.equal(result.ranges[0].hex, bytes.subarray(10, 33).toString('hex'));
  assert.equal(result.ranges[1].offset, 240);
  assert.equal(result.ranges[1].hex, bytes.subarray(240).toString('hex'));
  assert.equal(files.closed, 1);
});

test('invalid offsets, excessive output, seek failures and short reads always close the file', () => {
  for (const ranges of [[{offset: 250, length: 20}], [{offset: -300, length: 1}], [{offset: 0, length: 2049}]]) {
    const files = fileSystem(Buffer.alloc(256));
    assert.throws(() => history.inspect(files, ranges));
    assert.equal(files.closed, 1);
  }
  for (const options of [{seekFailure: true}, {readFailure: true}]) {
    const files = fileSystem(Buffer.alloc(256), options);
    assert.throws(() => history.inspect(files, [{offset: 0, length: 16}]));
    assert.equal(files.closed, 1);
  }
});

const clock = {year: 2026, month: 11, day: 5, hour: 14, minute: 30,
  utc: Date.UTC(2026, 10, 5, 20, 30)};
const awake = [80, 0, 0, 60, 0, 0, 0, 0];
const light = [120, 0, 0, 60, 0, 0, 0, 0];

function crc32(bytes) {
  let c = 0xffffffff;
  for (const byte of bytes) { c ^= byte; for (let bit = 0; bit < 8; bit++) c = (c >>> 1) ^ ((c & 1) ? 0xedb88320 : 0); }
  return (c ^ 0xffffffff) >>> 0;
}

test('circular reads preserve every record and CRC across the ring boundary', () => {
  const sample = (timestamp, today) => {
    const minute = (timestamp - today) / 60;
    if (minute >= -120 && minute < 360) return [120, 0, 0, 60, 0, 0, minute < -60 ? 43 : 0, minute >= 300 ? 60 : 0];
    return minute === 780 || minute >= 860 ? light : awake;
  };
  const store = makeStore(clock, sample);
  const files = fixtureFs(() => store.bytes);
  const data = history.load(files, clock);
  const expected = [];
  for (let timestamp = store.first; timestamp < store.now; timestamp += 60) expected.push(...sample(timestamp, store.today));
  assert.equal(data.source.crc32, crc32(expected));
  assert.equal(data.source.recorded, data.source.records);
  const result = history.summarize(data, {startTime: 1320, endTime: 1799});
  assert.equal(result.total, 481);
  assert.equal(result.night, 480);
  assert.equal(result.naps, 1);
  assert.equal(result.light, 361);
  assert.equal(result.deep, 60);
  assert.equal(result.rem, 60);
  assert.equal(result.inProgress, true);
  assert.equal(result.periods.length, 2);
});

test('erased samples split periods and cannot establish a completed nap', () => {
  const store = makeStore(clock, (timestamp, today) => {
    const minute = (timestamp - today) / 60;
    if (minute === 779 || minute === 803) return null;
    return (minute >= 780 && minute < 782) || (minute >= 800 && minute < 803) ? light : awake;
  });
  const result = history.read(fixtureFs(() => store.bytes), clock, null);
  assert.equal(result.total, 0);
  assert.equal(result.incompletePeriods, 2);
  assert.equal(result.source.recorded, result.source.records - 2);
});

test('unsupported file versions, page mappings and clock offsets fail instead of guessing', () => {
  for (const corrupt of [
    bytes => { bytes[7] = 3; },
    bytes => { const at = bytes.readUInt32LE(18); bytes[at + 33] = 2; },
    bytes => { bytes.writeUInt32LE(clock.utc / 1000 + 60, 48); },
    bytes => { for (let at = 32; at < 60; at += 12) bytes[at] = 236; }
  ]) {
    const store = makeStore(clock);
    corrupt(store.bytes);
    const files = fileSystem(store.bytes);
    assert.throws(() => history.load(files, clock));
    assert.equal(files.closed, 1);
  }
});

test('records outside ring retention are missing rather than repeated as current data', () => {
  const store = makeStore(clock, (timestamp, today) => (timestamp - today) / 60 === 780 ? light : awake, {pages: 3});
  const result = history.read(fixtureFs(() => store.bytes), clock, null);
  assert.equal(result.total, 1);
  assert.equal(result.source.recorded, 512);
  assert.ok(result.source.recorded < result.source.records);
  assert.equal(result.source.crc32, null);
});

test('a header changing during a read is rejected and the file is closed', () => {
  const store = makeStore(clock), files = fileSystem(store.bytes);
  const original = files.read;
  let reads = 0;
  files.read = function (...args) {
    const result = original(...args);
    if (++reads === 3) store.bytes[52] ^= 8;
    return result;
  };
  assert.throws(() => history.load(files, clock), /changed/);
  assert.equal(files.closed, 1);
});

test('clock conversion derives the band offset without depending on the host timezone', () => {
  const window = history.clockWindow(clock);
  assert.equal(window.offset, -21600);
  assert.equal(window.today, Date.UTC(2026, 10, 5, 6) / 1000);
  assert.throws(() => history.clockWindow({...clock, utc: clock.utc + 60000}), /offset/);
});

test('two wake-up dates retain their entire nights while totals select only today', () => {
  const store = makeStore(clock, (timestamp, today) => {
    const minute = (timestamp - today) / 60;
    return (minute >= -1560 && minute < -1080) || // Previous evening to yesterday 06:00.
      (minute >= -120 && minute < 360) || // Last night to today 06:00.
      (minute >= 780 && minute < 786) ? light : awake;
  });
  const result = history.read(fixtureFs(() => store.bytes), clock, {startTime: 1320, endTime: 1799});
  assert.equal(result.total, 486);
  assert.equal(result.night, 480);
  assert.equal(result.naps, 6);
  assert.equal(result.nightStart, store.today - 7200);
  assert.equal(result.nightEnd, store.today + 21600);
  assert.equal(result.periods.length, 2);
  assert.deepEqual(Array.from(result.recentPeriods, p => [p.start_utc, p.end_utc, p.minutes]), [
    [store.today - 93600, store.today - 64800, 480],
    [store.today - 7200, store.today + 21600, 480],
    [store.today + 46800, store.today + 47160, 6]
  ]);
});

test('night start is the first counted raw minute, rather than the native window start', () => {
  const store = makeStore(clock, (timestamp, today) => {
    const minute = (timestamp - today) / 60;
    return (minute >= 313 && minute < 330) || (minute >= 340 && minute < 360) ? light : awake;
  });
  const result = history.read(fixtureFs(() => store.bytes), clock, {startTime: 298, endTime: 359});
  assert.equal(result.nightStart, store.today + 313 * 60);
  assert.equal(result.nightEnd, store.today + 360 * 60);
  assert.equal(result.night, 37);
});

test('incremental reads match the independent CRC and the synchronous result', () => {
  const sample = (timestamp, today) => {
    const minute = (timestamp - today) / 60;
    return minute >= 313 && minute < 360 ? light : minute === 500 ? null : awake;
  };
  const store = makeStore(clock, sample), files = fileSystem(store.bytes);
  const reader = history.beginLoad(files, clock);
  assert.equal(reader.progress(), 0);
  assert.equal(reader.step(64), null);
  assert.equal(files.closed, 0);
  assert.ok(reader.progress() > 0 && reader.progress() < 100);
  let result;
  while ((result = reader.step(64)) === null) {}
  const expected = [];
  for (let timestamp = store.first; timestamp < store.now; timestamp += 60) {
    expected.push(...(sample(timestamp, store.today) || Array(8).fill(255)));
  }
  assert.equal(result.source.crc32, crc32(expected));
  assert.equal(reader.progress(), 100);
  assert.equal(files.closed, 1);
  assert.deepEqual(result, history.load(fileSystem(store.bytes), clock));
  reader.close();
  assert.equal(files.closed, 1);
});

test('incremental cancellation and changes between batches close the activity file once', () => {
  const store = makeStore(clock), files = fileSystem(store.bytes);
  const canceled = history.beginLoad(files, clock);
  assert.equal(canceled.step(64), null);
  canceled.close();
  canceled.close();
  assert.equal(files.closed, 1);
  assert.throws(() => canceled.step(64), /closed/);
  const changedFiles = fileSystem(store.bytes), changed = history.beginLoad(changedFiles, clock);
  assert.equal(changed.step(64), null);
  store.bytes[52] ^= 8;
  assert.throws(() => { while (changed.step(64) === null) {} }, /changed/);
  assert.equal(changedFiles.closed, 1);
});
