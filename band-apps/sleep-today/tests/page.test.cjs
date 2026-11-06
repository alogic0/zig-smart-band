const assert = require('node:assert/strict');
const test = require('node:test');
const { start } = require('./runtime.cjs');
const {makeStore, fixtureFs} = require('./fixtures.cjs');

function texts(app) { return app.active.filter(item => item.type === 'TEXT').map(item => item.props.text); }

test('raw totals remain independent of native stage counts and can work without a native sleep sensor', () => {
  const clock = {year: 2026, month: 11, day: 5, hour: 14, minute: 30};
  const store = makeStore(clock, (timestamp, today) => [
    timestamp >= today + 780 * 60 && timestamp < today + 786 * 60 ? 120 : 80, 0, 0, 60, 0, 0, 0, 0
  ]);
  for (const unsupported of [false, true]) {
    const app = start({clock, unsupported, stages: [{start: 0, stop: 479, model: 6}], fs: fixtureFs(() => store.bytes)});
    app.runShortTimers();
    assert.ok(texts(app).includes('0:06'));
    assert.ok(!texts(app).includes('8:00'));
    assert.ok(texts(app).includes('Read 14:30'));
    app.destroy();
  }
});

test('device page renders totals from local raw history, with no phone input', () => {
  const app = start({ stages: [{ start: 0, stop: 59, model: 4 }, { start: 60, stop: 89, model: 6 }] });
  app.runShortTimers();
  assert.ok(texts(app).includes('1:30'));
  assert.ok(texts(app).includes('1:00'));
  assert.ok(texts(app).includes('0:30'));
  assert.ok(texts(app).includes('2026-11-03'));
  assert.ok(!texts(app).includes('Sleep today'));
  assert.ok(!texts(app).includes('Hours asleep today'));
  assert.ok(!texts(app).some(text => text.includes('goal') || text.includes('%')));
  assert.ok(texts(app).includes('Night'));
  assert.ok(texts(app).includes('Naps'));
  assert.ok(texts(app).includes('Night from --:--'));
  assert.ok(!texts(app).includes('Since midnight'));
  assert.ok(!app.active.some(item => item.type === 'BUTTON'));
  const background = app.active.find(item => item.type === 'FILL_RECT');
  for (const { props } of app.active) {
    assert.ok(props.x >= 0 && props.y >= 0);
    assert.ok(props.x + props.w <= 192 && props.y + props.h <= background.props.h);
    if (props.y < 490 && props !== background.props) assert.ok(props.y + props.h <= 490);
  }
  app.destroy();
});

test('a read failure waits for reopening instead of retrying in the open page', () => {
  const app = start({fail: true});
  app.runShortTimers();
  const before = app.state.updates;
  app.state.fail = false;
  app.state.stages = [{ start: 0, stop: 4, model: 4 }];
  app.runMinuteTimer();
  app.runMinuteTimer();
  app.runShortTimers();
  assert.equal(app.state.updates, before);
  assert.ok(texts(app).includes('--:--'));
  assert.ok(texts(app).includes('Reopen to retry'));
  app.destroy();
  assert.equal(app.timers.size, 0);
  const reopened = start({stages: app.state.stages});
  reopened.runShortTimers();
  assert.ok(texts(reopened).includes('0:05'));
  assert.ok(texts(reopened).includes('Read 14:30'));
  reopened.destroy();
});

test('valid empty data and unsupported API have distinct visible states', () => {
  const empty = start();
  empty.runShortTimers();
  assert.ok(texts(empty).includes('0:00'));
  assert.ok(texts(empty).includes('Read 14:30'));
  assert.ok(texts(empty).some(text => text.includes('No complete\nperiods')));
  empty.destroy();
  const unsupported = start({ fs: null });
  unsupported.runShortTimers();
  assert.ok(texts(unsupported).includes('--:--'));
  assert.ok(texts(unsupported).includes('Raw history unavailable'));
  unsupported.destroy();
});

test('reopening changes the wake-up date and retains the full session across midnight', () => {
  let app = start({ stages: [{ start: 0, stop: 59, model: 4 }] });
  app.runShortTimers();
  app.destroy();
  app = start({clock: {day: 4, hour: 0, minute: 3},
    stages: [{start: 1439, stop: 1441, model: 4}], basic: {startTime: 1439, endTime: 1441}});
  app.runShortTimers();
  assert.ok(texts(app).includes('2026-11-04'));
  assert.ok(texts(app).includes('0:03'));
  app.destroy();
});

test('total, night, stages, and goal arc all include the pre-midnight part of sleep', () => {
  const app = start({ basic: { startTime: 1320, endTime: 1799 },
    stages: [{ start: 1320, stop: 1799, model: 4 }, { start: 2220, stop: 2249, model: 4 }] });
  app.runShortTimers();
  const valueAt = y => app.active.find(item => item.type === 'TEXT' && item.props.x === 94 && item.props.y === y).props.text;
  assert.equal(valueAt(216), '8:00');
  assert.equal(valueAt(247), '0:30');
  assert.ok(texts(app).includes('Night from 22:00'));
  assert.equal(valueAt(292), '8:30');
  assert.equal(app.active.find(item => item.type === 'TEXT' && item.props.text_size === 48).props.text, '8:30');
  assert.equal(app.active.filter(item => item.type === 'ARC')[1].props.end_angle, 360);
  app.destroy();
});

test('reopening after sleep ends includes the entire session', () => {
  const options = { clock: { hour: 6, minute: 40 }, basic: { startTime: 1380, endTime: 599 },
    stages: [{ start: 1380, stop: 1439, model: 4 }, { start: 0, stop: 599, model: 4 }] };
  let app = start(options);
  app.runShortTimers();
  assert.ok(texts(app).includes('Read 06:40'));
  assert.equal(app.active.find(item => item.type === 'TEXT' && item.props.text_size === 48).props.text, '0:00');
  app.destroy();
  app = start({...options, clock: {hour: 10, minute: 1}});
  app.runShortTimers();
  assert.ok(texts(app).includes('Read 10:01'));
  assert.equal(app.active.find(item => item.type === 'TEXT' && item.props.text_size === 48).props.text, '11:00');
  app.destroy();
});

test('keeping the page open retains its widgets without requiring deleteWidget support', () => {
  const app = start({ noDeleteWidget: true, stages: [{ start: 0, stop: 59, model: 4 }] });
  app.runShortTimers();
  const count = app.widgets.length;
  for (let i = 0; i < 5; i++) {
    app.runMinuteTimer();
    app.runShortTimers();
    assert.ok(texts(app).includes('1:00'));
    assert.equal(app.widgets.length, count);
  }
  app.destroy();
  assert.equal(app.timers.size, 0);
});

test('upper-edge arc measures the 8-hour goal without a repeated text caption', () => {
  for (const [minutes, angle, filled] of [
    [0, 181, false],
    [270, 281, true],
    [480, 360, true],
    [600, 360, true]
  ]) {
    const app = start({ stages: minutes ? [{ start: 0, stop: minutes - 1, model: 4 }] : [] });
    app.runShortTimers();
    const [track, progress] = app.active.filter(item => item.type === 'ARC');
    assert.equal(track.props.start_angle, 180);
    assert.equal(track.props.end_angle, 360);
    assert.equal(track.props.x, 8);
    assert.equal(track.props.y, 8);
    assert.equal(progress.props.end_angle, angle);
    assert.equal(progress.props.color === track.props.color, !filled);
    assert.ok(!texts(app).some(text => text.includes('goal') || text.includes('%')));
    if (minutes === 600) assert.ok(texts(app).includes('10:00'));
    app.destroy();
  }
  const unavailable = start({ fs: null });
  assert.ok(!texts(unavailable).some(text => text.includes('%')));
  unavailable.destroy();
});

test('raw night and nap rows use the native window only as a label and can establish zero naps', () => {
  let app = start({ basic: { startTime: 0, endTime: 269 },
    stages: [{ start: 0, stop: 269, model: 4 }, { start: 780, stop: 809, model: 4 }] });
  app.runShortTimers();
  const valueAt = y => app.active.find(item => item.type === 'TEXT' && item.props.x === 94 && item.props.y === y).props.text;
  assert.equal(valueAt(216), '4:30');
  assert.equal(valueAt(247), '0:30');
  assert.ok(texts(app).includes('5:00'));
  app.destroy();
  app = start({basic: {startTime: 0, endTime: 269}, stages: [{start: 0, stop: 269, model: 4}]});
  app.runShortTimers();
  assert.equal(valueAt(216), '4:30');
  assert.equal(valueAt(247), '0:00');
  app.destroy();
});

test('screen hold renews while open and releases once on exit, with an optional API', () => {
  const app = start();
  app.runShortTimers();
  assert.ok(app.screenCalls.length > 0);
  assert.ok(app.screenCalls.every(seconds => seconds === 180));
  const before = app.screenCalls.length;
  app.runMinuteTimer();
  assert.equal(app.screenCalls.length, before + 1);
  app.destroy();
  app.destroy();
  app.runMinuteTimer();
  assert.equal(app.screenCalls.filter(call => call === 'cancel').length, 1);
  assert.equal(app.screenCalls.length, before + 2);
  for (const options of [{noScreenControl: true}, {screenResult: -1}]) {
    const fallback = start(options);
    fallback.runShortTimers();
    assert.ok(texts(fallback).includes('0:00'));
    fallback.destroy();
    assert.ok(!fallback.screenCalls.includes('cancel'));
  }
});

test('scrollable history shows dates and endpoints and stays in place while open', () => {
  const clock = {year: 2026, month: 11, day: 5, hour: 14, minute: 30};
  const store = makeStore(clock, (timestamp, today) => {
    const minute = (timestamp - today) / 60;
    return [(minute >= -1560 && minute < -1080) || (minute >= -120 && minute < 360) ||
      (minute >= 780 && minute < 786) ? 120 : 80, 0, 0, 60, 0, 0, 0, 0];
  });
  const app = start({clock, basic: {startTime: 1320, endTime: 1799}, fs: fixtureFs(() => store.bytes)});
  app.runShortTimers();
  const history = app.active.find(item => item.type === 'TEXT' && item.props.y === 536);
  const content = history.props.text;
  assert.equal(app.scrolling.enabled, true);
  assert.equal(app.scrolling.swipe, false);
  assert.ok(content.indexOf('2026-11-05') < content.indexOf('2026-11-04'));
  assert.equal(content.split('Previous day\nStart 22:00\nEnd   06:00\nSleep 8:00').length - 1, 2);
  assert.ok(content.includes('Start 13:00\nEnd   13:06\nSleep 0:06'));
  assert.ok(!/\b(?:Start|End)\s+11-/.test(content));
  assert.ok(texts(app).includes('Night from 22:00'));
  assert.equal(history.props.align_v, 'top');
  assert.equal(history.props.h, content.split('\n').length * 32 + 8);
  const count = app.widgets.length, calls = app.scrolling.calls;
  app.scrolling.offset = 600;
  app.runMinuteTimer();
  app.runShortTimers();
  assert.equal(app.widgets.length, count);
  assert.equal(app.scrolling.calls, calls);
  assert.equal(app.scrolling.offset, 600);
  app.destroy();
});

test('the loaded history, date and read time remain fixed even across midnight', () => {
  const app = start({basic: {startTime: 0, endTime: 59}, stages: [{start: 0, stop: 59, model: 4}]});
  app.runShortTimers();
  const history = app.active.find(item => item.type === 'TEXT' && item.props.y === 536);
  const content = history.props.text;
  assert.ok(history.props.text.includes('Start 00:00'));
  app.clock.day = 4;
  app.clock.hour = 0;
  app.clock.minute = 3;
  app.state.stages = [];
  app.runMinuteTimer();
  app.runShortTimers();
  assert.equal(history.props.text, content);
  assert.ok(texts(app).includes('2026-11-03'));
  assert.ok(texts(app).includes('Read 14:30'));
  app.state.fail = true;
  app.runMinuteTimer();
  app.runShortTimers();
  assert.equal(history.props.text, content);
  assert.ok(texts(app).includes('Read 14:30'));
  app.destroy();
});

test('startup paints a rotating loader before I/O and reads once per page opening', () => {
  const clock = {year: 2026, month: 11, day: 5, hour: 14, minute: 30};
  const store = makeStore(clock), files = fixtureFs(() => store.bytes);
  let opens = 0, closes = 0;
  const open = files.open_asset, close = files.close;
  files.open_asset = (...args) => { opens++; return open(...args); };
  files.close = (...args) => { closes++; return close(...args); };
  const app = start({clock, fs: files});
  const spinner = app.active.find(widget => widget.type === 'ARC' && widget.props.w === 52);
  assert.ok(spinner);
  assert.equal(opens, 0);
  assert.equal(app.state.updates, 0);
  const angle = spinner.props.start_angle;
  app.runNextShortTimer(); // First frame can rotate before sensor/filesystem work.
  assert.notEqual(spinner.props.start_angle, angle);
  assert.equal(opens, 0);
  app.runShortTimers();
  assert.equal(opens, 1);
  assert.equal(closes, 1);
  assert.equal(spinner.visible, false);
  app.clock.minute = 55;
  for (let i = 0; i < 20; i++) app.runMinuteTimer();
  assert.ok(texts(app).includes('0:00'));
  app.runShortTimers();
  assert.equal(opens, 1);
  assert.equal(closes, 1);
  assert.equal(app.state.updates, 1);
  assert.ok(texts(app).includes('Read 14:30'));
  assert.equal(spinner.visible, false);
  app.destroy();
});

test('exiting during collection cancels animation and closes the in-progress read', () => {
  const clock = {year: 2026, month: 11, day: 5, hour: 14, minute: 30};
  const store = makeStore(clock), files = fixtureFs(() => store.bytes);
  let opened = false, closes = 0;
  const open = files.open_asset, close = files.close;
  files.open_asset = (...args) => { opened = true; return open(...args); };
  files.close = (...args) => { closes++; return close(...args); };
  const app = start({clock, fs: files});
  for (let i = 0; !opened && i < 100; i++) app.runNextShortTimer();
  assert.ok(opened);
  assert.equal(closes, 0);
  app.destroy();
  app.destroy();
  assert.equal(closes, 1);
  assert.equal(app.timers.size, 0);
  assert.equal(app.runNextShortTimer(), false);
});
