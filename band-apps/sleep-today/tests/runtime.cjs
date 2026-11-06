const { readFileSync } = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {fixtureFs, stagesStore} = require('./fixtures.cjs');

function start(options = {}) {
  const widgets = [];
  const timers = new Map();
  const logs = [];
  const screenCalls = [];
  const scrolling = { enabled: false, swipe: null, offset: 0, calls: 0 };
  const clock = { year: 2026, month: 11, day: 3, hour: 14, minute: 30, ...options.clock };
  const state = {
    stages: options.stages || [],
    basic: options.basic || null,
    fail: options.fail || false,
    updates: 0
  };
  if (clock.utc === undefined) Object.defineProperty(clock, 'utc', {get() {
    return Date.UTC(clock.year, clock.month - 1, clock.day, clock.hour, clock.minute) + 21600000;
  }});
  const files = Object.prototype.hasOwnProperty.call(options, 'fs') ? options.fs || undefined : fixtureFs(() => {
    if (state.fail) throw Error('Activity file unavailable');
    return stagesStore(clock, state);
  });
  const constants = { WAKE_STAGE: 0, LIGHT_STAGE: 4, DEEP_STAGE: 6, REM_STAGE: 8 };
  const sensor = {
    updateInfo() { state.updates++; },
    getSleepStageData() {
      if (state.fail) throw new Error('Sensor failed');
      return state.stages;
    },
    getSleepStageModel() { return constants; },
    getBasicInfo() { return state.basic; },
    getTotalTime() { return options.sensorTotal === undefined ? null : options.sensorTotal; }
  };
  let page;
  let nextTimer = 1;
  let elapsed = 0;
  const host = { currentApp: { current: {} } };
  const context = vm.createContext({
    Page(value) { page = value; },
    __$$hmAppManager$$__: host,
    DeviceRuntimeCore: {
      App(value) { return value; },
      Page(value) { page = value; return value; },
      HmLogger: { getLogger() { return { log(message) { logs.push(message); } }; } }
    },
    hmUI: {
      widget: { TEXT: 'TEXT', BUTTON: 'BUTTON', FILL_RECT: 'FILL_RECT', ARC: 'ARC' },
      prop: { MORE: 'MORE', VISIBLE: 'VISIBLE' },
      align: { LEFT: 'left', RIGHT: 'right', CENTER_H: 'center', CENTER_V: 'middle', TOP: 'top' },
      text_style: { NONE: 0 },
      setScrollView(enabled) { scrolling.swipe = enabled; scrolling.offset = 0; scrolling.calls++; },
      setLayerScrolling(enabled) { scrolling.enabled = enabled; scrolling.offset = 0; scrolling.calls++; },
      getTextLayout(text, options) {
        return { height: text.split('\n').length * (options.text_size + 10), width: options.text_width };
      },
      createWidget(type, props) {
        const widget = {
          type, props: { ...props }, deleted: false,
          setProperty(key, patch) {
            if (key === 'VISIBLE') this.visible = patch;
            else Object.assign(this.props, patch);
          }
        };
        widgets.push(widget);
        return widget;
      },
      deleteWidget(widget) { widget.deleted = true; }
    },
    hmSensor: {
      id: { TIME: 'TIME', SLEEP: 'SLEEP' },
      createSensor(id) {
        if (id === 'TIME') return clock;
        if (options.unsupported) throw new Error('Sleep API unavailable');
        return sensor;
      }
    },
    hmFS: files,
    hmSetting: options.noScreenControl ? undefined : {
      setBrightScreen(seconds) { screenCalls.push(seconds); return options.screenResult || 0; },
      setBrightScreenCancel() { screenCalls.push('cancel'); return 0; }
    },
    SleepTodayRawPattern: options.rawPattern,
    SleepTodayFilesystemProbe: options.fsProbe,
    SleepTodayFileRanges: options.fileRanges,
    timer: {
      createTimer(delay, period, callback) {
        const id = nextTimer++;
        timers.set(id, { delay, period, callback, due: elapsed + delay });
        return id;
      },
      stopTimer(id) { timers.delete(id); }
    }
  });
  if (options.noDeleteWidget) delete context.hmUI.deleteWidget;
  if (options.staleGlobals) Object.assign(context, options.staleGlobals);
  if (options.entrypoints) {
    delete context.Page;
    for (let source of options.entrypoints) {
      const configuration = [
        ['SleepTodayFilesystemProbe', options.fsProbe],
        ['SleepTodayRawPattern', options.rawPattern],
        ['SleepTodayFileRanges', options.fileRanges]
      ].filter(([, value]) => value !== undefined).map(([name, value]) => 'var ' + name + ' = ' + JSON.stringify(value) + ';').join('\n');
      source = source.replace('var SleepTodayDiagnostics = true;', 'var SleepTodayDiagnostics = true;\n' + configuration);
      vm.runInContext(source, context);
    }
  } else {
    for (const name of ['stats.js', 'theme.js', 'history.js', 'page.js']) {
      vm.runInContext(readFileSync(path.join(__dirname, '../src', name), 'utf8'), context);
    }
  }
  page.build();
  return {
    page, clock, state, timers, widgets, host, logs, screenCalls, scrolling,
    get active() { return widgets.filter(widget => !widget.deleted && widget.visible !== false); },
    runMinuteTimer() {
      for (const [id, item] of Array.from(timers)) {
        if (item.period === 60000 && timers.has(id)) item.callback();
      }
    },
    runNextShortTimer() {
      const next = Array.from(timers).filter(([, item]) => item.period < 60000).sort((a, b) => a[1].due - b[1].due)[0];
      if (!next) return false;
      const [id, item] = next;
      elapsed = item.due;
      item.due += item.period;
      item.callback();
      return true;
    },
    runShortTimers() {
      let count = 0;
      while (this.runNextShortTimer()) if (++count > 2000) throw Error('Short timers did not settle');
    },
    destroy() { page.onDestroy(); }
  };
}

module.exports = { start };
