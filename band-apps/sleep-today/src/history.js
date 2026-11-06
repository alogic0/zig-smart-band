// Read-only access to the Band 7's local activity store. Firmware-specific.
var SleepTodayHistory = (function () {
  var PATH = '../../../health_allday_activity';
  function integer(value) { return typeof value === 'number' && isFinite(value) && Math.floor(value) === value; }
  function open(fs) {
    var info = fs.stat_asset(PATH);
    if (!info || info[1] !== 0 || !info[0] || !integer(info[0].size) || info[0].size < 24 || info[0].size > 2 * 1024 * 1024) throw new Error('Activity file unavailable');
    var handle = fs.open_asset(PATH, fs.O_RDONLY);
    if (!integer(handle) || handle < 0) throw new Error('Cannot open activity file');
    return { size: info[0].size, handle: handle };
  }
  function readAt(fs, file, offset, length) {
    if (!integer(offset) || !integer(length) || offset < 0 || length < 1 || length > 4096 || offset + length > file.size) throw new Error('Invalid activity read');
    var position = fs.seek(file.handle, offset, fs.SEEK_SET);
    if (typeof position === 'number' && position < 0) throw new Error('Activity seek failed');
    var buffer = new ArrayBuffer(length), used = 0;
    while (used < length) {
      var got = fs.read(file.handle, buffer, used, length - used);
      if (!integer(got) || got <= 0 || got > length - used) throw new Error('Short activity read');
      used += got;
    }
    return new Uint8Array(buffer);
  }
  function hex(bytes) {
    var result = '';
    for (var i = 0; i < bytes.length; i++) result += ('0' + bytes[i].toString(16)).slice(-2);
    return result;
  }
  function inspect(fs, ranges) {
    if (!Array.isArray(ranges) || ranges.length > 8) throw new Error('Invalid probe ranges');
    var file = open(fs), total = 0;
    try {
      var result = { path: '/storage/health_allday_activity', size: file.size, ranges: [] };
      for (var i = 0; i < ranges.length; i++) {
        var range = ranges[i];
        total += range.length;
        if (total > 2048) throw new Error('Probe is too large');
        var offset = range.offset < 0 ? file.size + range.offset : range.offset;
        result.ranges.push({ offset: offset, hex: hex(readAt(fs, file, offset, range.length)) });
      }
      return result;
    } finally { fs.close(file.handle); }
  }
  function u32(bytes, at) { return (bytes[at] + bytes[at + 1] * 256 + bytes[at + 2] * 65536 + bytes[at + 3] * 16777216) >>> 0; }
  function text(bytes, at, value) {
    for (var i = 0; i < value.length; i++) if (bytes[at + i] !== value.charCodeAt(i)) return false;
    return true;
  }
  function mod(value, divisor) { return ((value % divisor) + divisor) % divisor; }
  function layout(fs, file, now, offset) {
    var header = readAt(fs, file, 0, 84);
    var pages = header[12] + header[13] * 256;
    var poolEnd = u32(header, 14), index = u32(header, 18);
    if (!text(header, 0, 'SHAREDP') || header[7] !== 2 || u32(header, 8) !== 24 ||
        header[22] !== 8 || header[23] !== 12 || pages < 3 || pages > 255 ||
        poolEnd !== 24 + pages * 4096 || index !== poolEnd + 32 || index + 35 + pages !== file.size) throw new Error('Unsupported activity layout');
    var mapping = readAt(fs, file, index, 35 + pages);
    if (!text(mapping, 0, 'SHAREP_ZIPLIST') || mapping[30] !== 133 || mapping[31] !== 80 ||
        mapping[32 + pages] !== 0 || mapping[33 + pages] !== 192 || mapping[34 + pages] !== 255) throw new Error('Unsupported activity page map');
    for (var page = 0; page < pages; page++) if (mapping[32 + page] !== page) throw new Error('Unsupported activity page map');
    var references = [];
    for (var at = 24; at < 84; at += 12) {
      var timestamp = u32(header, at), position = u32(header, at + 4);
      var quarters = header[at + 8] < 128 ? header[at + 8] : header[at + 8] - 256;
      if (timestamp < 946684800 || timestamp % 60 !== 0 ||
          position < 8192 || position >= pages * 4096 || position % 8 !== 0 || quarters < -48 || quarters > 56) continue;
      references.push({ timestamp: timestamp, position: position, offset: quarters * 900 });
    }
    references.sort(function (a, b) { return a.timestamp - b.timestamp; });
    if (!references.length || references[references.length - 1].offset !== offset ||
        references[references.length - 1].timestamp > now) throw new Error('Activity clock reference unavailable');
    return { header: header, references: references, capacity: (pages - 2) * 4096 };
  }
  function clockWindow(clock) {
    if (!clock || !integer(clock.utc) || clock.utc < 946684800000 || !integer(clock.hour) || !integer(clock.minute) ||
        clock.hour < 0 || clock.hour > 23 || clock.minute < 0 || clock.minute > 59) throw new Error('Clock unavailable');
    var now = Math.floor(clock.utc / 60000) * 60;
    var calendar = Date.UTC(clock.year, clock.month - 1, clock.day, clock.hour, clock.minute) / 1000;
    var offset = calendar - now;
    if (!integer(offset) || offset % 900 !== 0 || offset < -43200 || offset > 50400) throw new Error('Clock offset unavailable');
    var today = now - clock.hour * 3600 - clock.minute * 60;
    // Include the preceding night for both wake-up dates shown in the history.
    return { now: now, today: today, first: today - 2 * 86400 - 60, offset: offset };
  }
  function crcByte(crc, byte) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    return crc >>> 0;
  }
  function beginLoad(fs, clock) {
    var window = clockWindow(clock), file = open(fs);
    var store, count, codes;
    try {
      store = layout(fs, file, window.now, window.offset);
      count = (window.now - window.first) / 60;
      codes = new Uint8Array(count);
    } catch (error) { fs.close(file.handle); throw error; }
    var crc = 0xffffffff, recorded = 0, referenceIndex = -1, i = 0;
    var cached = null, cachedAt = -1, closed = false;
    function close() {
      if (closed) return;
      closed = true;
      cached = null;
      fs.close(file.handle);
    }
    function step(limit) {
      if (closed) throw new Error('Activity reader closed');
      try {
        if (!integer(limit) || limit < 1 || limit > 512) throw new Error('Invalid activity batch');
        var until = Math.min(count, i + limit);
        for (; i < until; i++) {
          var timestamp = window.first + i * 60;
          while (referenceIndex + 1 < store.references.length && store.references[referenceIndex + 1].timestamp <= timestamp) referenceIndex++;
          if (referenceIndex < 0 || timestamp < window.now - store.capacity / 8 * 60) { crc = null; continue; }
          var reference = store.references[referenceIndex];
          var position = 8192 + mod(reference.position - 8192 + (timestamp - reference.timestamp) / 60 * 8, store.capacity);
          var physical = 24 + position;
          if (!cached || physical < cachedAt || physical + 8 > cachedAt + cached.length) {
            cachedAt = physical;
            cached = readAt(fs, file, physical, Math.min(4096, 24 + 8192 + store.capacity - physical));
          }
          var at = physical - cachedAt, erased = true;
          for (var byte = 0; byte < 8; byte++) {
            if (cached[at + byte] !== 255) erased = false;
            if (crc !== null) crc = crcByte(crc, cached[at + byte]);
          }
          if (erased) continue;
          recorded++;
          codes[i] = cached[at] !== 120 ? 4 : ((cached[at + 7] & 127) > 55 ? 3 : ((cached[at + 6] & 127) > 42 ? 2 : 1));
        }
        if (i < count) return null;
        var after = readAt(fs, file, 0, store.header.length);
        for (var h = 0; h < after.length; h++) if (after[h] !== store.header[h]) throw new Error('Activity store changed; retry');
        var result = { codes: codes, window: window, source: { first_utc: window.first, last_utc: window.now - 60,
          records: count, recorded: recorded, crc32: crc === null ? null : (crc ^ 0xffffffff) >>> 0,
          anchor_utc: store.references[store.references.length - 1].timestamp } };
        close();
        return result;
      } catch (error) { close(); throw error; }
    }
    return { step: step, close: close, progress: function () { return Math.floor(i * 100 / count); } };
  }
  function load(fs, clock) {
    var reader = beginLoad(fs, clock);
    try {
      var result = null;
      while (result === null) result = reader.step(512);
      return result;
    } finally { reader.close(); }
  }
  function summarize(data, basic) {
    var codes = data.codes, window = data.window;
    var result = { total: 0, light: 0, deep: 0, rem: 0, night: null, naps: null,
      completedSessions: 0, inProgress: false, incompletePeriods: 0, source: data.source, periods: [],
      recentPeriods: [], nightStart: null, nightEnd: null, today_utc: window.today, offset_seconds: window.offset };
    var main = null;
    if (basic && integer(basic.startTime) && integer(basic.endTime) && Math.abs(basic.startTime) <= 2880 && Math.abs(basic.endTime) <= 2880) {
      var start = basic.startTime, end = basic.endTime;
      if (end >= 1440) { start -= 1440; end -= 1440; }
      else if (start > end) start -= 1440;
      if (end + 1 >= 0 && end + 1 < 1440) main = { start: window.today + start * 60, end: window.today + (end + 1) * 60 };
    }
    if (main) { result.night = 0; result.naps = 0; }
    var index = 0;
    while (index < codes.length) {
      if (codes[index] < 1 || codes[index] > 3) { index++; continue; }
      var begin = index, light = 0, deep = 0, rem = 0;
      while (index < codes.length && codes[index] >= 1 && codes[index] <= 3) {
        if (codes[index] === 1) light++; else if (codes[index] === 2) deep++; else rem++;
        index++;
      }
      var wake = window.first + index * 60;
      if (index === codes.length) result.inProgress = true;
      if (wake < window.today - 86400 || wake >= window.today + 86400 || wake > window.now) continue;
      if (begin === 0 || codes[begin - 1] !== 4 || index === codes.length || codes[index] !== 4) {
        if (wake >= window.today) result.incompletePeriods++;
        continue;
      }
      var periodStart = window.first + begin * 60;
      var minutes = light + deep + rem;
      var period = { start_utc: periodStart, end_utc: wake, minutes: minutes };
      result.recentPeriods.push(period);
      if (wake < window.today) continue;
      result.total += minutes; result.light += light; result.deep += deep; result.rem += rem;
      result.completedSessions++;
      if (main) {
        if (periodStart < main.end && wake > main.start) {
          result.night += minutes;
          if (result.nightStart === null) result.nightStart = periodStart;
          result.nightEnd = wake;
        }
        else result.naps += minutes;
      }
      if (result.periods.length < 32) result.periods.push(period);
    }
    return result;
  }
  function read(fs, clock, basic) { return summarize(load(fs, clock), basic); }
  return { inspect: inspect, beginLoad: beginLoad, load: load, summarize: summarize, read: read, clockWindow: clockWindow };
})();
