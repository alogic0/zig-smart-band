// Synthetic activity-store fixtures. No device health data belongs in tests.
function makeStore(clock, sample, options = {}) {
  const offset = options.offset ?? -21600;
  const now = Math.floor((clock.utc ?? (Date.UTC(clock.year, clock.month - 1, clock.day, clock.hour, clock.minute) - offset * 1000)) / 60000) * 60;
  const today = now - clock.hour * 3600 - clock.minute * 60;
  const first = today - 2 * 86400 - 60;
  const pages = options.pages || 12, capacity = (pages - 2) * 4096;
  const end = 24 + pages * 4096, zip = end + 32;
  const bytes = Buffer.alloc(zip + 35 + pages, 255);
  bytes.write('SHAREDP', 0); bytes[7] = 2;
  bytes.writeUInt32LE(24, 8); bytes.writeUInt16LE(pages, 12);
  bytes.writeUInt32LE(end, 14); bytes.writeUInt32LE(zip, 18);
  bytes[22] = 8; bytes[23] = 12;
  const anchor = options.anchor ?? first - 600;
  const position = options.position ?? 8192 + capacity - 256;
  for (let at = 24; at < 60; at += 12) {
    bytes.writeUInt32LE(anchor, at); bytes.writeUInt32LE(position, at + 4);
    bytes[at + 8] = (offset / 900 + 256) % 256;
  }
  bytes.write('SHAREP_ZIPLIST', zip); bytes[zip + 30] = 133; bytes[zip + 31] = 80;
  for (let i = 0; i < pages; i++) bytes[zip + 32 + i] = i;
  bytes[zip + 32 + pages] = 0; bytes[zip + 33 + pages] = 192; bytes[zip + 34 + pages] = 255;
  for (let timestamp = first; timestamp < now; timestamp += 60) {
    const raw = sample ? sample(timestamp, today) : [80, 0, 0, 60, 0, 0, 0, 0];
    if (!raw) continue;
    const at = 24 + 8192 + (((position - 8192 + (timestamp - anchor) / 60 * 8) % capacity) + capacity) % capacity;
    Buffer.from(raw).copy(bytes, at);
  }
  return {bytes, first, now, today, capacity, anchor, position};
}

function fixtureFs(getBytes) {
  let bytes, cursor = 0;
  return {
    O_RDONLY: 0, SEEK_SET: 0,
    stat_asset(name) {
      if (name !== '../../../health_allday_activity') throw Error('Unexpected path');
      bytes = getBytes();
      return [{size: bytes.length}, 0];
    },
    open_asset(name, flags) {
      if (name !== '../../../health_allday_activity' || flags !== 0) throw Error('Read-only activity access required');
      cursor = 0; return 3;
    },
    seek(fd, position, mode) { if (fd !== 3 || mode !== 0) throw Error('Invalid seek'); cursor = position; return position; },
    read(fd, buffer, offset, length) {
      if (fd !== 3) throw Error('Invalid read');
      const take = Math.min(length, bytes.length - cursor);
      new Uint8Array(buffer).set(bytes.subarray(cursor, cursor + take), offset);
      cursor += take; return take;
    },
    close(fd) { if (fd !== 3) throw Error('Invalid close'); }
  };
}

function stagesStore(clock, state) {
  let basic = state.basic;
  const ranges = state.stages.map(stage => {
    let start = stage.start, stop = stage.stop;
    if (basic && basic.endTime >= 1440) {start -= 1440; stop -= 1440;}
    else if (basic && basic.startTime > basic.endTime) {
      if (start >= basic.startTime) start -= 1440;
      if (stop >= basic.startTime) stop -= 1440;
    }
    if (stop < start) start -= 1440;
    return {start, stop, model: stage.model};
  });
  return makeStore(clock, (timestamp, today) => {
    const minute = (timestamp - today) / 60;
    let model = 0;
    for (const range of ranges) if (minute >= range.start && minute <= range.stop) model = range.model;
    return [model === 0 ? 80 : 120, 0, 0, 60, 0, 0, model === 6 ? 43 : 0, model === 8 ? 60 : 0];
  }).bytes;
}
module.exports = {makeStore, fixtureFs, stagesStore};
