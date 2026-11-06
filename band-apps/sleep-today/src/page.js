// The device page is bundled with stats.js and theme.js by pack.zig.
Page({
  build: function () {
    var self = this;
    var theme = SleepTodayTheme;
    var colors = theme.colors;
    var widgets = {};
    var tick = null;
    var delayed = null;
    var spinTimer = null;
    var reader = null;
    var busy = false;
    var disposed = false;
    var screenHeld = false;
    var diagnosticSequence = 0;
    var filesystemProbe = null;
    var sensor;
    var clock;

    function holdScreen() {
      if (disposed || typeof hmSetting === 'undefined' || typeof hmSetting.setBrightScreen !== 'function' ||
          typeof hmSetting.setBrightScreenCancel !== 'function') return;
      try {
        var result = hmSetting.setBrightScreen(theme.screenHoldSeconds);
        if (result === 0 || result === undefined) screenHeld = true;
      } catch (_) {}
    }

    function localDate(timestamp, offset) {
      var date = new Date((timestamp + offset) * 1000);
      return { date: date.getUTCFullYear() + '-' + SleepTodayStats.pad(date.getUTCMonth() + 1) + '-' + SleepTodayStats.pad(date.getUTCDate()),
        time: SleepTodayStats.pad(date.getUTCHours()) + ':' + SleepTodayStats.pad(date.getUTCMinutes()) };
    }

    function showPeriods(summary) {
      if (!widgets.history) return;
      var lines = [];
      if (summary && typeof summary.today_utc === 'number') {
        var periods = summary.recentPeriods || [];
        for (var day = 0; day < 2; day++) {
          var start = summary.today_utc - day * 86400, end = start + 86400;
          lines.push(localDate(start, summary.offset_seconds).date, '');
          var count = 0;
          for (var i = periods.length - 1; i >= 0; i--) {
            var period = periods[i];
            if (period.end_utc < start || period.end_utc >= end) continue;
            var from = localDate(period.start_utc, summary.offset_seconds);
            var to = localDate(period.end_utc, summary.offset_seconds);
            if (period.start_utc < start) lines.push(period.start_utc >= start - 86400 ?
              'Previous day' : '2 days before');
            lines.push('Start ' + from.time,
              'End   ' + to.time,
              'Sleep ' + SleepTodayStats.duration(period.minutes), '');
            count++;
          }
          if (!count) lines.push('No complete', 'periods', '');
        }
      } else lines.push('History', 'unavailable');
      var content = lines.join('\n');
      var height = lines.length * theme.history.fallbackLineHeight;
      try {
        if (typeof hmUI.getTextLayout === 'function') {
          var measured = hmUI.getTextLayout(content, { text_size: theme.font.history,
            text_width: theme.width - 2 * theme.inset, wrapped: 1 });
          if (measured && measured.height > 0) height = measured.height + 8;
        }
      } catch (_) {}
      widgets.history.setProperty(hmUI.prop.MORE, { text: content, h: height });
      widgets.background.setProperty(hmUI.prop.MORE, { h: theme.history.textY + height + theme.inset });
    }

    function text(y, height, size, value, color, x, width, alignment) {
      return hmUI.createWidget(hmUI.widget.TEXT, {
        x: x === undefined ? theme.inset : x,
        y: y,
        w: width === undefined ? theme.width - 2 * theme.inset : width,
        h: height,
        text: value,
        text_size: size,
        color: color,
        align_h: alignment === undefined ? hmUI.align.CENTER_H : alignment,
        align_v: hmUI.align.CENTER_V,
        text_style: hmUI.text_style.NONE
      });
    }

    function set(widget, value) {
      widget.setProperty(hmUI.prop.MORE, { text: value });
    }

    function startLoading() {
      var geometry = theme.loading;
      var size = geometry.size;
      widgets.loading.setProperty(hmUI.prop.MORE, {
        x: (theme.width - size) / 2, y: geometry.y,
        w: size, h: size, radius: size / 2, start_angle: -90, end_angle: 0
      });
      widgets.loading.setProperty(hmUI.prop.VISIBLE, true);
      set(widgets.total, '');
      set(widgets.updated, 'Reading sleep...');
      if (typeof timer === 'undefined' || !timer.createTimer) return;
      var angle = 0;
      spinTimer = timer.createTimer(geometry.interval, geometry.interval, function () {
        if (disposed) return;
        angle = (angle + 30) % 360;
        widgets.loading.setProperty(hmUI.prop.MORE, { start_angle: angle - 90, end_angle: angle });
      });
    }

    function finishLoading() {
      if (spinTimer !== null) { timer.stopTimer(spinTimer); spinTimer = null; }
      if (reader) { reader.close(); reader = null; }
      widgets.loading.setProperty(hmUI.prop.VISIBLE, false);
      busy = false;
    }

    function later(delay, callback) {
      delayed = timer.createTimer(delay, delay, function () {
        timer.stopTimer(delayed);
        delayed = null;
        if (!disposed) callback();
      });
    }

    function filesystemMode() {
      return typeof SleepTodayDiagnostics !== 'undefined' && SleepTodayDiagnostics &&
        ((typeof SleepTodayFilesystemProbe !== 'undefined' && SleepTodayFilesystemProbe === true) ||
         typeof SleepTodayRawPattern !== 'undefined' || typeof SleepTodayFileRanges !== 'undefined');
    }

    function arc(color, endAngle) {
      var geometry = theme.goalArc;
      return hmUI.createWidget(hmUI.widget.ARC, {
        x: geometry.x, y: geometry.y, w: geometry.size, h: geometry.size,
        radius: geometry.radius, line_width: geometry.lineWidth,
        start_angle: geometry.startAngle, end_angle: endAngle, color: color
      });
    }

    function showGoal(total) {
      var fraction = total === null ? 0 : Math.max(0, Math.min(1, total / theme.goalMinutes));
      widgets.goalArc.setProperty(hmUI.prop.MORE, {
        // Avoid equal start/end angles: some native renderers treat them as a
        // full circle. At zero/unknown, a track-colored degree blends in.
        end_angle: theme.goalArc.startAngle + Math.max(1, Math.round(theme.goalArc.sweepAngle * fraction)),
        color: fraction > 0 ? colors.light : colors.track
      });
    }

    function showFailure(message) {
      showGoal(null);
      if (clock) set(widgets.date, SleepTodayStats.dayKey(clock));
      set(widgets.total, '--:--');
      set(widgets.night, '--:--');
      set(widgets.naps, '--:--');
      set(widgets.light, '--:--');
      set(widgets.deep, '--:--');
      set(widgets.rem, '--:--');
      set(widgets.nightFrom, 'Night from --:--');
      set(widgets.updated, message);
      showPeriods(null);
    }

    function emitDiagnostic(record) {
      var diagnostic = JSON.stringify(record);
      if (diagnostic.length > 7600) diagnostic = JSON.stringify({ version: 1, error: 'Diagnostic exceeds size limit' });
      var diagnosticId = String(clock.utc) + '-' + (++diagnosticSequence);
      var partCount = Math.ceil(diagnostic.length / 100);
      var logger = DeviceRuntimeCore.HmLogger.getLogger('sleep-today');
      for (var part = 0; part < partCount; part++) logger.log('STDIAG ' + diagnosticId + ' ' + part + '/' + partCount + ' ' + diagnostic.slice(part * 100, (part + 1) * 100));
    }

    function probeActivityFile(pattern) {
      var result = { path: '/storage/health_allday_activity', matches: [] };
      if (!Array.isArray(pattern) || pattern.length < 8 || pattern.length > 64) return { error: 'Invalid probe pattern' };
      for (var p = 0; p < pattern.length; p++) {
        if (typeof pattern[p] !== 'number' || pattern[p] < 0 || pattern[p] > 255 || Math.floor(pattern[p]) !== pattern[p]) return { error: 'Invalid probe pattern' };
      }
      var info = hmFS.stat_asset('../../../health_allday_activity');
      result.statError = info[1];
      if (info[1] !== 0 || !info[0]) return result;
      result.size = info[0].size;
      var handle = hmFS.open_asset('../../../health_allday_activity', hmFS.O_RDONLY);
      if (typeof handle !== 'number' || handle < 0) { result.openError = handle; return result; }
      try {
        var buffer = new ArrayBuffer(4096 + pattern.length - 1);
        var bytes = new Uint8Array(buffer);
        var consumed = 0, carry = 0;
        var limit = Math.min(result.size, 1024 * 1024);
        while (consumed < limit) {
          var length = hmFS.read(handle, buffer, carry, Math.min(4096, limit - consumed));
          if (typeof length !== 'number' || length <= 0 || length > 4096) { result.readError = length; break; }
          if (consumed === 0) {
            result.headerHex = '';
            for (var headerIndex = 0; headerIndex < Math.min(48, length); headerIndex++) result.headerHex += ('0' + bytes[headerIndex].toString(16)).slice(-2);
          }
          var available = carry + length;
          for (var offset = 0; offset <= available - pattern.length; offset++) {
            if (bytes[offset] !== pattern[0]) continue;
            var matched = 1;
            while (matched < pattern.length && bytes[offset + matched] === pattern[matched]) matched++;
            if (matched === pattern.length && result.matches.length < 4) result.matches.push(consumed - carry + offset);
          }
          consumed += length;
          if (result.matches.length) break;
          carry = Math.min(pattern.length - 1, available);
          for (var c = 0; c < carry; c++) bytes[c] = bytes[available - carry + c];
        }
        result.bytesScanned = consumed;
        result.patternBytes = pattern.length;
        if (result.matches.length && typeof hmFS.seek === 'function') {
          result.seekResult = hmFS.seek(handle, result.matches[0], hmFS.SEEK_SET);
          var sample = new ArrayBuffer(48);
          result.sampleRead = hmFS.read(handle, sample, 0, 48);
          var sampleBytes = new Uint8Array(sample);
          result.sampleHex = '';
          for (var sampleIndex = 0; sampleIndex < Math.max(0, Math.min(48, result.sampleRead)); sampleIndex++) result.sampleHex += ('0' + sampleBytes[sampleIndex].toString(16)).slice(-2);
        }
      } finally { hmFS.close(handle); }
      return result;
    }

    function read(history) {
      if (disposed) return;
      try {
        if (!clock || typeof hmFS === 'undefined') {
          showFailure('Raw history unavailable');
          return;
        }
        var hour = clock.hour;
        var minute = clock.minute;
        var key = SleepTodayStats.dayKey(clock);
        set(widgets.date, key);
        var stages = [], constants = null, basic = null;
        try {
          if (sensor) {
            // Normal totals need only the main-window label from the sensor.
            if (typeof SleepTodayDiagnostics !== 'undefined' && SleepTodayDiagnostics) {
              if (typeof sensor.getSleepStageData === 'function') stages = sensor.getSleepStageData();
              if (typeof sensor.getSleepStageModel === 'function') constants = sensor.getSleepStageModel();
            }
            if (typeof sensor.getBasicInfo === 'function') basic = sensor.getBasicInfo();
          }
        } catch (_) { basic = null; }
        var probeMode = filesystemMode();
        var summary = probeMode ? SleepTodayStats.summarize(stages, constants, basic, hour * 60 + minute) :
          SleepTodayHistory.summarize(history, basic);
        if (typeof SleepTodayDiagnostics !== 'undefined' && SleepTodayDiagnostics) {
          try {
            var sensorTotal = typeof sensor.getTotalTime === 'function' ? sensor.getTotalTime() : null;
            var capabilities = {
              getNap: typeof sensor.getNap,
              getNapData: typeof sensor.getNapData,
              getNapInfo: typeof sensor.getNapInfo,
              getSleepingStatus: typeof sensor.getSleepingStatus,
              names: []
            };
            try {
              var object = sensor;
              for (var depth = 0; object && depth < 2; depth++) {
                var names = Object.getOwnPropertyNames(object);
                for (var nameIndex = 0; nameIndex < names.length && capabilities.names.length < 128; nameIndex++) {
                  if (capabilities.names.indexOf(names[nameIndex]) === -1) capabilities.names.push(names[nameIndex]);
                }
                object = Object.getPrototypeOf(object);
              }
            } catch (_) {
              // Some firmware host objects do not support JS reflection.
            }
            var napData = null;
            if (typeof sensor.getNap === 'function') {
              try { napData = sensor.getNap(); }
              catch (_) { capabilities.getNapError = true; }
            }
            if (filesystemProbe === null) {
              filesystemProbe = {
                available: typeof hmFS !== 'undefined',
                enabled: (typeof SleepTodayFilesystemProbe !== 'undefined' && SleepTodayFilesystemProbe === true) || typeof SleepTodayRawPattern !== 'undefined' || typeof SleepTodayFileRanges !== 'undefined'
              };
              if (filesystemProbe.enabled && filesystemProbe.available) {
                try {
                  if (typeof SleepTodayFileRanges !== 'undefined') {
                    filesystemProbe.activity = SleepTodayHistory.inspect(hmFS, SleepTodayFileRanges);
                  } else if (typeof SleepTodayRawPattern !== 'undefined') {
                    filesystemProbe.activity = probeActivityFile(SleepTodayRawPattern);
                  } else {
                    // Read-only control: a known file packaged with this app.
                    var control = hmFS.stat_asset('icon.png');
                    filesystemProbe.assetStat = { error: control[1], size: control[0] && control[0].size };
                    var file = hmFS.open_asset('icon.png', hmFS.O_RDONLY);
                    if (typeof file === 'number' && file >= 0) {
                      try {
                        var buffer = new ArrayBuffer(16);
                        filesystemProbe.assetRead = hmFS.read(file, buffer, 0, 16);
                        filesystemProbe.assetBytes = Array.prototype.slice.call(new Uint8Array(buffer));
                      } finally { hmFS.close(file); }
                    } else filesystemProbe.assetOpenError = file;
                    var listing = hmFS.readdir('/storage');
                    filesystemProbe.root = { path: '/storage', error: listing[1], entries: [] };
                    var entries = listing[0];
                    if (Array.isArray(entries)) {
                      filesystemProbe.root.total = entries.length;
                      for (var entryIndex = 0; entryIndex < Math.min(96, entries.length); entryIndex++) {
                        var filename = entries[entryIndex];
                        if (typeof filename !== 'string' || filename.length > 64 || filename.indexOf('/') !== -1 || filename === '.' || filename === '..') continue;
                        var entry = { name: filename };
                        if (/sleep|activity|raw_data/i.test(filename)) try {
                          // The Band 7's shared storage sits three levels above app assets.
                          var info = hmFS.stat_asset('../../../' + filename);
                          entry.error = info[1];
                          if (info[0]) {
                            entry.size = info[0].size;
                            entry.mode = info[0].mode;
                            entry.mtime = info[0].mtime;
                          }
                        } catch (_) { entry.statFailed = true; }
                        filesystemProbe.root.entries.push(entry);
                      }
                    }
                  }
                } catch (error) { filesystemProbe.error = String(error).slice(0, 120); }
              }
            }
            emitDiagnostic(filesystemProbe.enabled && filesystemProbe.available ? {
              build: 'raw-local-v2',
              version: 1, date: key, hour: hour, minute: minute, filesystem: filesystemProbe
            } : {
              build: 'raw-local-v2',
              version: 1, date: key, hour: hour, minute: minute, utc: clock.utc,
              basic: basic ? { start: basic.startTime, end: basic.endTime, deep: basic.deepMin } : null,
              sensorTotal: sensorTotal,
              capabilities: capabilities,
              napData: napData,
              filesystem: filesystemProbe,
              history: summary.source || null,
              periods: summary.periods || null,
              models: [constants.LIGHT_STAGE, constants.DEEP_STAGE, constants.REM_STAGE, constants.WAKE_STAGE],
              stages: stages.map(function (stage) { return [stage.start, stage.stop, stage.model]; }),
              calculated: [summary.total, summary.light, summary.deep, summary.rem]
            });
          } catch (_) {
            // Optional diagnostics must never make the sleep screen fail.
          }
        }
        set(widgets.total, SleepTodayStats.duration(summary.total));
        set(widgets.night, summary.night === null ? '--:--' : SleepTodayStats.duration(summary.night));
        set(widgets.naps, summary.naps === null ? '--:--' : SleepTodayStats.duration(summary.naps));
        set(widgets.light, SleepTodayStats.duration(summary.light));
        set(widgets.deep, SleepTodayStats.duration(summary.deep));
        set(widgets.rem, SleepTodayStats.duration(summary.rem));
        set(widgets.nightFrom, 'Night from ' + (summary.nightStart === null || summary.nightStart === undefined ? '--:--' :
          localDate(summary.nightStart, summary.offset_seconds).time));
        showPeriods(summary);
        set(widgets.updated, 'Read ' + SleepTodayStats.pad(clock.hour) + ':' + SleepTodayStats.pad(clock.minute));
        showGoal(summary.total);
      } catch (error) {
        showFailure('Reopen to retry');
        if (typeof SleepTodayDiagnostics !== 'undefined' && SleepTodayDiagnostics && clock) try {
          emitDiagnostic({ version: 1, date: SleepTodayStats.dayKey(clock), error: String(error).slice(0, 120),
            clock: { utc: clock.utc, hour: clock.hour, minute: clock.minute } });
        } catch (_) {}
      } finally {
        finishLoading();
      }
    }

    function readBatch() {
      if (disposed) return;
      try {
        if (typeof hmFS === 'undefined' || filesystemMode()) { read(null); return; }
        if (!reader) reader = SleepTodayHistory.beginLoad(hmFS, clock);
        var history = reader.step(theme.loading.batchRecords);
        if (history) {
          reader = null;
          var current = SleepTodayHistory.clockWindow(clock);
          if (history.window.today !== current.today || history.window.offset !== current.offset) {
            // A midnight or clock change during collection needs a fresh window.
            later(theme.loading.batchDelay, readBatch);
            return;
          }
          read(history);
          return;
        }
        set(widgets.updated, 'Reading ' + reader.progress() + '%');
        if (typeof timer !== 'undefined' && timer.createTimer) later(theme.loading.batchDelay, readBatch);
        else {
          while (history === null) history = reader.step(512);
          reader = null;
          read(history);
        }
      } catch (_) {
        finishLoading();
        showFailure('Reopen to retry');
      }
    }

    function loadOnce() {
      if (busy || disposed) return;
      busy = true;
      try {
        holdScreen();
        if (clock) set(widgets.date, SleepTodayStats.dayKey(clock));
        startLoading();
        // Return from build before sensor/filesystem work so the loader can paint.
        if (typeof timer !== 'undefined' && timer.createTimer) {
          later(100, function () {
            holdScreen();
            try { if (sensor && typeof sensor.updateInfo === 'function') sensor.updateInfo(); } catch (_) {}
            later(500, readBatch);
          });
        } else readBatch();
      } catch (_) {
        finishLoading();
        showFailure('Reopen to retry');
      }
    }

    try {
      if (typeof hmUI.setScrollView === 'function') hmUI.setScrollView(false);
      if (typeof hmUI.setLayerScrolling === 'function') hmUI.setLayerScrolling(true);
    } catch (_) {}
    widgets.background = hmUI.createWidget(hmUI.widget.FILL_RECT, {
      x: 0, y: 0, w: theme.width, h: theme.height, color: colors.background
    });
    arc(colors.track, theme.goalArc.startAngle + theme.goalArc.sweepAngle);
    widgets.goalArc = arc(colors.track, theme.goalArc.startAngle + 1);
    widgets.date = text(75, 25, theme.font.caption, '', colors.muted);
    widgets.nightFrom = text(109, 30, theme.font.nightStart, 'Night from --:--', colors.muted, 8, theme.width - 16);
    widgets.total = text(141, 62, theme.font.value, '--:--', colors.text);
    var rows = [
      { key: 'night', label: 'Night', y: 216, color: colors.text, size: theme.font.sleepRows },
      { key: 'naps', label: 'Naps', y: 247, color: colors.text, size: theme.font.sleepRows },
      { key: 'light', label: 'Light', y: 292, color: colors.light },
      { key: 'deep', label: 'Deep', y: 323, color: colors.deep },
      { key: 'rem', label: 'REM', y: 354, color: colors.rem }
    ];
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var size = row.size || theme.font.body;
      var height = row.size ? 30 : 28;
      text(row.y, height, size, row.label, row.color, theme.inset, 73, hmUI.align.LEFT);
      widgets[row.key] = text(row.y, height, size, '--:--', colors.text, 94, 80, hmUI.align.RIGHT);
    }
    widgets.updated = text(389, 23, theme.font.caption, 'Reading sleep...', colors.muted);
    text(445, 23, theme.font.caption, 'Swipe up for periods', colors.muted);
    text(theme.history.headingY, 30, theme.font.history, 'Sleep periods', colors.text, theme.inset,
      theme.width - 2 * theme.inset, hmUI.align.LEFT);
    widgets.history = hmUI.createWidget(hmUI.widget.TEXT, {
      x: theme.inset, y: theme.history.textY, w: theme.width - 2 * theme.inset, h: 64,
      text: 'Reading\nhistory...', text_size: theme.font.history, color: colors.text,
      align_h: hmUI.align.LEFT, align_v: hmUI.align.TOP, line_space: 0,
      text_style: hmUI.text_style.WRAP === undefined ? hmUI.text_style.NONE : hmUI.text_style.WRAP
    });
    widgets.loading = hmUI.createWidget(hmUI.widget.ARC, {
      x: theme.loading.x, y: theme.loading.y, w: theme.loading.size, h: theme.loading.size,
      radius: theme.loading.size / 2, line_width: theme.loading.lineWidth,
      start_angle: -90, end_angle: 0, color: colors.light
    });
    widgets.loading.setProperty(hmUI.prop.VISIBLE, false);

    try {
      clock = hmSensor.createSensor(hmSensor.id.TIME);
      try { sensor = hmSensor.createSensor(hmSensor.id.SLEEP); } catch (_) { sensor = null; }
      loadOnce();
      // Renew only the display hold; keep the displayed history and read time fixed.
      if (typeof timer !== 'undefined' && timer.createTimer) tick = timer.createTimer(60000, 60000, holdScreen);
    } catch (_) {
      showFailure('Sleep unavailable');
    }

    self.disposeSleepToday = function () {
      if (disposed) return;
      disposed = true;
      if (typeof timer !== 'undefined') {
        if (tick !== null) timer.stopTimer(tick);
        if (delayed !== null) timer.stopTimer(delayed);
        if (spinTimer !== null) timer.stopTimer(spinTimer);
      }
      if (reader) { reader.close(); reader = null; }
      if (screenHeld) {
        try { hmSetting.setBrightScreenCancel(); } catch (_) {}
        screenHeld = false;
      }
      // The OS releases the page's widget tree. Do not mutate destroyed widgets.
      sensor = null;
      clock = null;
    };
  },
  onDestroy: function () {
    if (this.disposeSleepToday) this.disposeSleepToday();
  }
});
