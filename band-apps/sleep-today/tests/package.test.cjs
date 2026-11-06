const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, readFileSync, rmSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { start } = require('./runtime.cjs');

function buildPackage(output, diagnostics = false) {
  execFileSync('zig', ['build', 'sleep-app', '--',
    ...(diagnostics ? ['--diagnostics'] : []), '--output', output],
  { cwd: path.resolve(__dirname, '../../..') });
  // Extract the four stored entries without a Python or ZIP-tool dependency.
  // The Zig integration test checks both directories and CRCs through the
  // actual installer's preflight; these tests execute the packaged JS runtime.
  const bytes = readFileSync(output);
  const files = Object.create(null);
  let offset = 0;
  while (bytes.readUInt32LE(offset) === 0x04034b50) {
    assert.equal(bytes.readUInt16LE(offset + 6), 0);
    assert.equal(bytes.readUInt16LE(offset + 8), 0);
    const size = bytes.readUInt32LE(offset + 18);
    assert.equal(bytes.readUInt32LE(offset + 22), size);
    const length = bytes.readUInt16LE(offset + 26);
    const extra = bytes.readUInt16LE(offset + 28);
    const name = bytes.subarray(offset + 30, offset + 30 + length).toString('utf8');
    assert.equal(files[name], undefined);
    offset += 30 + length + extra;
    files[name] = bytes.subarray(offset, offset + size);
    assert.equal(files[name].length, size);
    offset += size;
  }
  assert.deepEqual(Object.keys(files).sort(), ['app.js', 'app.json', 'assets/icon.png', 'page/index.js']);
  assert.equal(bytes.readUInt32LE(offset), 0x02014b50);
  assert.equal(bytes.readUInt32LE(bytes.length - 22), 0x06054b50);
  assert.equal(bytes.readUInt32LE(bytes.length - 6), offset);
  return files;
}

test('built package registers in the firmware runtime without SDK-injected globals', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'sleep-today-package-'));
  try {
    const output = path.join(directory, 'nested output', 'app.bin');
    const files = buildPackage(output);
    const data = Object.fromEntries(['app.json', 'app.js', 'page/index.js'].map(name => [name, files[name].toString('utf8')]));
    const icon = files['assets/icon.png'];
    const pixel = (x, y) => icon.readUInt16LE(64 + 2 * (y * 100 + x));
    const manifest = JSON.parse(data['app.json']);
    assert.equal(manifest.designWidth, 192);
    assert.equal(manifest.app.appType, 'app');
    assert.equal(manifest.debug, false);
    assert.ok(data['page/index.js'].includes('SleepTodayDiagnostics = false'));
    assert.equal(icon.subarray(18, 22).toString('ascii'), 'SOMH');
    assert.equal(icon.readUInt16LE(22), icon.readUInt16LE(12));
    assert.equal(icon.readUInt16LE(14), 100);
    assert.equal(icon.length, 64 + icon.readUInt16LE(12) * icon.readUInt16LE(14) * 2);
    assert.deepEqual([[0, 0], [99, 0], [0, 99], [99, 99], [10, 10]].map(([x, y]) => pixel(x, y)), [0, 0, 0, 0, 0]);
    assert.notEqual(pixel(50, 50), 0);
    assert.notEqual(pixel(50, 2), 0);
    const app = start({
      entrypoints: [data['app.js'], data['page/index.js']],
      stages: [{ start: 0, stop: 59, model: 4 }]
    });
    app.runShortTimers();
    assert.ok(app.host.currentApp.app);
    assert.equal(app.host.currentApp.current.module, app.page);
    assert.ok(app.active.some(widget => widget.props.text === '1:00'));
    assert.equal(app.logs.length, 0);
    app.destroy();
    assert.equal(app.timers.size, 0);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('temporary diagnostic build uses the native logger and keeps the screen functional', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'sleep-today-diagnostic-'));
  try {
    const output = path.join(directory, 'app.bin');
    const files = buildPackage(output, true);
    assert.equal(JSON.parse(files['app.json']).debug, true);
    const sources = ['app.js', 'page/index.js'].map(name => files[name].toString('utf8'));
    const app = start({ entrypoints: sources, sensorTotal: 59,
      staleGlobals: { SleepTodayFilesystemProbe: true, SleepTodayFileRanges: [{offset: 0, length: 8}], SleepTodayRawPattern: [1,2,3,4,5,6,7,8] },
      stages: [{ start: 0, stop: 59, model: 4 }] });
    app.runShortTimers();
    const first = app.logs[0].match(/^STDIAG (\S+) (\d+)\/(\d+) (.*)$/);
    const parts = app.logs.slice(0, Number(first[3])).map(line => {
      assert.ok(line.length < 170);
      return line.match(/^STDIAG (\S+) (\d+)\/(\d+) (.*)$/)[4];
    });
    const record = JSON.parse(parts.join(''));
    assert.equal(record.sensorTotal, 59);
    assert.equal(record.capabilities.getNap, 'undefined');
    assert.ok(record.capabilities.names.includes('getSleepStageData'));
    assert.equal(record.napData, null);
    assert.equal(record.filesystem.available, true);
    assert.equal(record.filesystem.enabled, false);
    assert.equal(record.history.recorded, record.history.records);
    assert.deepEqual(record.stages, [[0, 59, 4]]);
    assert.ok(app.active.some(widget => widget.props.text === '1:00'));
    app.destroy();
    const calls = [];
    const filesystem = {
      O_RDONLY: 0,
      stat_asset(file) {
        calls.push(['stat', file]);
        return [{ size: 16, mode: 32768, mtime: 1 }, 0];
      },
      open_asset(file, flags) {
        calls.push(['open', file, flags]);
        assert.ok(file === 'icon.png' || file === '../../../activity');
        assert.equal(flags, 0);
        return 3;
      },
      read(fd, buffer, offset, length) {
        assert.equal(fd, 3);
        assert.equal(length, 16);
        new Uint8Array(buffer)[offset] = 46;
        return 16;
      },
      close(fd) { calls.push(['close', fd]); },
      readdir(file) {
        if (file === '/storage') return [['activity', '.', '../bad'], 0];
        assert.ok(['/storage/pm_data', '/storage/statistics'].includes(file));
        return [[], 0];
      }
    };
    const probe = start({ entrypoints: sources, fs: filesystem, fsProbe: true });
    probe.runShortTimers();
    const partsCount = Number(probe.logs[0].match(/^STDIAG \S+ \d+\/(\d+) /)[1]);
    const snapshot = JSON.parse(probe.logs.slice(0, partsCount).map(line => line.match(/^STDIAG \S+ \d+\/\d+ (.*)$/)[1]).join(''));
    assert.equal(snapshot.filesystem.assetBytes[0], 46);
    assert.equal(snapshot.filesystem.root.entries.length, 1);
    assert.equal(snapshot.filesystem.root.entries[0].name, 'activity');
    assert.ok(calls.some(call => call[0] === 'stat' && call[1] === '../../../activity'));
    assert.ok(calls.some(call => call[0] === 'close' && call[1] === 3));
    probe.destroy();
    const raw = Buffer.alloc(5000, 128);
    const pattern = [120, 1, 2, 60, 4, 5, 6, 7];
    Buffer.from(pattern).copy(raw, 4094); // Match crosses the 4096-byte read boundary.
    let cursor = 0, closed = false;
    const rawFs = {
      O_RDONLY: 0, SEEK_SET: 0,
      stat_asset(file) { assert.equal(file, '../../../health_allday_activity'); return [{size: raw.length}, 0]; },
      open_asset(file, flags) { assert.equal(file, '../../../health_allday_activity'); assert.equal(flags, 0); return 4; },
      read(fd, buffer, offset, length) {
        assert.equal(fd, 4);
        const take = Math.min(length, raw.length - cursor);
        new Uint8Array(buffer).set(raw.subarray(cursor, cursor + take), offset);
        cursor += take;
        return take;
      },
      seek(fd, offset, mode) { assert.equal(fd, 4); assert.equal(mode, 0); cursor = offset; return 0; },
      close(fd) { assert.equal(fd, 4); closed = true; }
    };
    const rawProbe = start({ entrypoints: sources, fs: rawFs, rawPattern: pattern });
    rawProbe.runShortTimers();
    const rawParts = Number(rawProbe.logs[0].match(/^STDIAG \S+ \d+\/(\d+) /)[1]);
    const rawSnapshot = JSON.parse(rawProbe.logs.slice(0, rawParts).map(line => line.match(/^STDIAG \S+ \d+\/\d+ (.*)$/)[1]).join(''));
    assert.deepEqual(rawSnapshot.filesystem.activity.matches, [4094]);
    assert.equal(rawSnapshot.filesystem.activity.sampleHex, raw.subarray(4094, 4094 + 48).toString('hex'));
    assert.equal(closed, true);
    rawProbe.destroy();
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
