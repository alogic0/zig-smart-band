// Complete sleep-session accounting shared by the page and offline checks.
var SleepTodayStats = (function () {
  var DAY = 1440;
  var EMPTY = 0;
  var LIGHT = 1;
  var DEEP = 2;
  var REM = 3;
  var AWAKE = 4;

  function integer(value) {
    return typeof value === 'number' && isFinite(value) && Math.floor(value) === value;
  }

  function pad(value) {
    return value < 10 ? '0' + value : String(value);
  }

  function duration(minutes) {
    return Math.floor(minutes / 60) + ':' + pad(minutes % 60);
  }

  function dayKey(clock) {
    return clock.year + '-' + pad(clock.month) + '-' + pad(clock.day);
  }

  function stageCode(model, constants) {
    if (model === constants.LIGHT_STAGE) return LIGHT;
    if (model === constants.DEEP_STAGE) return DEEP;
    if (model === constants.REM_STAGE) return REM;
    if (model === constants.WAKE_STAGE) return AWAKE;
    return EMPTY;
  }

  function validConstants(constants) {
    if (!constants) return false;
    var keys = ['LIGHT_STAGE', 'DEEP_STAGE', 'REM_STAGE', 'WAKE_STAGE'];
    var values = [];
    for (var i = 0; i < keys.length; i++) {
      var value = constants[keys[i]];
      if (!integer(value) || values.indexOf(value) !== -1) return false;
      values.push(value);
    }
    return true;
  }

  // Verified against the Band 7's native deepMin: stage endpoints are inclusive,
  // including a one-minute stage whose start equals stop. getTotalTime() includes
  // awake intervals and must not replace the sum of actual sleep stages.
  // Some builds return an unwrapped two-day sleep window; others wrap at
  // midnight. Normalize both onto today's midnight, allowing negative minutes
  // for yesterday's part of a session that ends today.
  function interval(stage, basic) {
    var start = stage.start;
    var stop = stage.stop;
    if (!integer(start) || !integer(stop) || Math.abs(start) > DAY * 2 || Math.abs(stop) > DAY * 2) {
      throw new Error('Invalid sleep interval');
    }
    if (basic && integer(basic.endTime) && basic.endTime >= DAY) {
      start -= DAY;
      stop -= DAY;
    } else if (basic && integer(basic.startTime) && integer(basic.endTime) && basic.startTime > basic.endTime) {
      if (start >= basic.startTime) start -= DAY;
      if (stop >= basic.startTime) stop -= DAY;
    }
    if (stop < start) start -= DAY;
    return { start: start, end: stop + 1 };
  }

  function summarize(stages, constants, basic, nowMinutes) {
    if (!Array.isArray(stages) || !validConstants(constants) || !integer(nowMinutes) || nowMinutes < 0 || nowMinutes > DAY) {
      throw new Error('Sleep data unavailable');
    }
    // Retain yesterday as well as today so midnight never truncates a session.
    // Select completed sessions afterward, using their wake-up date.
    var minutes = new Uint8Array(DAY * 2);
    var selected = new Uint8Array(DAY * 2);
    var truncatedPrefix = false;
    for (var i = 0; i < stages.length; i++) {
      var stage = stages[i];
      if (!stage || typeof stage !== 'object') throw new Error('Invalid sleep interval');
      var code = stageCode(stage.model, constants);
      if (code === EMPTY) throw new Error('Unknown sleep stage');
      var range = interval(stage, basic);
      if (range.start < -DAY && range.end > -DAY) truncatedPrefix = true;
      var start = Math.max(-DAY, range.start);
      var end = Math.min(DAY, range.end);
      // A later stage record replaces an overlapping earlier classification.
      for (var minute = start; minute < end; minute++) minutes[minute + DAY] = code;
    }
    // The legacy API exposes a main sleep window, not a separate nap flag.
    // Use that boundary rather than guessing from a fixed morning cutoff.
    var main = null;
    if (basic && integer(basic.startTime) && integer(basic.endTime) &&
        Math.abs(basic.startTime) <= DAY * 2 && Math.abs(basic.endTime) <= DAY * 2) {
      main = interval({ start: basic.startTime, stop: basic.endTime }, basic);
    }
    function belongsToday(end) {
      // End is exclusive: waking exactly at midnight belongs to the new day.
      return end >= 0 && end < DAY && end <= nowMinutes;
    }

    function select(start, end) {
      var asleep = 0;
      for (var minute = Math.max(-DAY, start); minute < Math.min(DAY, end); minute++) {
        var code = minutes[minute + DAY];
        selected[minute + DAY] = code;
        if (code >= LIGHT && code <= REM) asleep++;
      }
      return asleep;
    }

    var night = null;
    var naps = 0;
    var completedSessions = 0;
    var inProgress = !!(main && main.start <= nowMinutes && main.end > nowMinutes);
    var currentMain = !!(main && main.start >= -DAY && main.end >= 0 && main.end < DAY);
    if (currentMain && belongsToday(main.end)) {
      night = select(main.start, main.end);
      if (night > 0) completedSessions++;
    }

    // Outside the main window, consecutive returned stages (including brief
    // awake stages) form an additional session. Unknown gaps separate sessions.
    // Attribute the whole session to its end date; never count a partial nap.
    var cursor = -DAY;
    while (cursor < DAY) {
      if (main && cursor >= main.start && cursor < main.end) {
        cursor = Math.min(DAY, main.end);
        continue;
      }
      if (minutes[cursor + DAY] === EMPTY) { cursor++; continue; }
      var sessionStart = cursor;
      var hasSleep = false;
      while (cursor < DAY && minutes[cursor + DAY] !== EMPTY &&
             !(main && cursor >= main.start && cursor < main.end)) {
        var value = minutes[cursor + DAY];
        if (value >= LIGHT && value <= REM) hasSleep = true;
        cursor++;
      }
      if (!hasSleep) continue;
      if (sessionStart === -DAY && truncatedPrefix) continue;
      if (sessionStart <= nowMinutes && cursor > nowMinutes) inProgress = true;
      if (belongsToday(cursor)) {
        naps += select(sessionStart, cursor);
        completedSessions++;
      }
    }

    var counts = [0, 0, 0, 0, 0];
    for (var index = 0; index < minutes.length; index++) {
      counts[selected[index]]++;
    }
    return {
      total: counts[LIGHT] + counts[DEEP] + counts[REM],
      night: night,
      // No extra intervals cannot establish that there were no naps: some
      // Band 7 firmware exposes only the main window through this API.
      naps: currentMain && naps > 0 ? naps : null,
      light: counts[LIGHT],
      deep: counts[DEEP],
      rem: counts[REM],
      awake: counts[AWAKE],
      minutes: selected,
      firstMinute: -DAY,
      completedSessions: completedSessions,
      inProgress: inProgress,
      nowMinutes: nowMinutes
    };
  }

  return {
    duration: duration,
    pad: pad,
    dayKey: dayKey,
    summarize: summarize
  };
})();
