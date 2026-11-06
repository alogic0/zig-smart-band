const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(readFileSync(path.join(__dirname, '../src/stats.js'), 'utf8'), context);
const stats = context.SleepTodayStats;
const models = { WAKE_STAGE: 0, LIGHT_STAGE: 4, DEEP_STAGE: 6, REM_STAGE: 8 };
const stage = (start, stop, model = models.LIGHT_STAGE) => ({ start, stop, model });

test('totals separate sleep sessions during the current day, excluding awake', () => {
  const result = stats.summarize([
    stage(0, 119), stage(120, 179, models.DEEP_STAGE),
    stage(180, 194, models.WAKE_STAGE), stage(195, 239, models.REM_STAGE),
    stage(780, 809)
  ], models, { startTime: 0, endTime: 239 }, 900);
  assert.equal(result.total, 255);
  assert.equal(result.night, 225);
  assert.equal(result.naps, 30);
  assert.equal(result.night + result.naps, result.total);
  assert.equal(result.light, 150);
  assert.equal(result.deep, 60);
  assert.equal(result.rem, 45);
  assert.equal(result.awake, 15);
});

test('preserves a whole unwrapped night across midnight, with inclusive endpoints', () => {
  const result = stats.summarize([stage(1380, 1499), stage(1500, 1559, models.DEEP_STAGE)],
    models, { startTime: 1380, endTime: 1559 }, 300);
  assert.equal(result.total, 180);
  assert.equal(result.light, 120);
  assert.equal(result.deep, 60);
  assert.equal(result.night, 180);
  assert.equal(result.naps, null);
});

test('preserves a complete wrapped 22:00 to 06:00 night', () => {
  const result = stats.summarize([stage(1320, 1439), stage(0, 179), stage(180, 359, models.DEEP_STAGE)],
    models, { startTime: 1320, endTime: 359 }, 600);
  assert.equal(result.total, 480);
  assert.equal(result.night, 480);
  assert.equal(result.light, 300);
  assert.equal(result.deep, 180);
});

test('overlapping stages count once and later awake classification replaces sleep', () => {
  const result = stats.summarize([stage(10, 69), stage(30, 89, models.DEEP_STAGE),
    stage(40, 49, models.WAKE_STAGE)], models, null, 120);
  assert.equal(result.total, 70);
  assert.equal(result.light, 20);
  assert.equal(result.deep, 50);
});

test('counts one-minute sleep and whole signed sessions that end today', () => {
  const result = stats.summarize([stage(-10, 0), stage(12, 12)], models, null, 60);
  assert.equal(result.total, 12);
  assert.equal(stats.duration(result.total), '0:12');
});

test('empty sensor data differs from malformed or unsupported data', () => {
  assert.equal(stats.summarize([], models, null, 60).total, 0);
  assert.throws(() => stats.summarize(undefined, models, null, 60));
  assert.throws(() => stats.summarize([stage(0, 10, 99)], models, null, 60));
  assert.throws(() => stats.summarize([stage(NaN, 10)], models, null, 60));
  assert.throws(() => stats.summarize([], {}, null, 60));
});

test('main sleep and multiple completed naps resolve overlaps once', () => {
  const result = stats.summarize([
    stage(1380, 1499), stage(1500, 1559, models.DEEP_STAGE),
    stage(2220, 2249), stage(2230, 2234, models.WAKE_STAGE),
    stage(2400, 2419, models.REM_STAGE), stage(2500, 2600)
  ], models, { startTime: 1380, endTime: 1559 }, 1000);
  assert.equal(result.night, 180);
  assert.equal(result.naps, 45);
  assert.equal(result.night + result.naps, result.total);
});

test('excludes yesterday\'s separate naps while including the entire night and today\'s nap', () => {
  const result = stats.summarize([
    stage(900, 929), stage(1320, 1799), stage(2220, 2249)
  ], models, { startTime: 1320, endTime: 1799 }, 900);
  assert.equal(result.night, 480);
  assert.equal(result.naps, 30);
  assert.equal(result.total, 510);
  assert.equal(result.completedSessions, 2);
});

test('counts a whole additional session crossing midnight but excludes an unfinished nap', () => {
  const result = stats.summarize([
    stage(-80, -51), stage(-20, 19), stage(300, 359), stage(820, 879)
  ], models, { startTime: 300, endTime: 359 }, 840);
  assert.equal(result.night, 60);
  assert.equal(result.naps, 40);
  assert.equal(result.total, 100);
  assert.equal(result.inProgress, true);
});

test('does not count an unfinished night or future-only sleep as completed', () => {
  const result = stats.summarize([stage(1380, 1439), stage(0, 599), stage(780, 809)],
    models, { startTime: 1380, endTime: 599 }, 400);
  assert.equal(result.night, null);
  assert.equal(result.naps, null);
  assert.equal(result.total, 0);
  assert.equal(result.completedSessions, 0);
  assert.equal(result.inProgress, true);
});

test('attributes a session waking exactly at midnight to the new day', () => {
  const result = stats.summarize([stage(-180, -121), stage(-120, -1)],
    models, { startTime: -120, endTime: -1 }, 0);
  assert.equal(result.night, 120);
  assert.equal(result.total, 120);
  assert.equal(result.naps, null);
});

test('does not relabel an older night or count an incompletely exposed long session', () => {
  const older = stats.summarize([stage(-180, -121), stage(600, 629)],
    models, { startTime: -180, endTime: -121 }, 900);
  assert.equal(older.total, 30);
  assert.equal(older.night, null);
  assert.equal(older.naps, null);
  const truncated = stats.summarize([stage(-1500, 59)], models, null, 900);
  assert.equal(truncated.total, 0);
  assert.equal(truncated.completedSessions, 0);
});

test('a late morning end remains part of the main sleep window', () => {
  const result = stats.summarize([stage(1740, 1909), stage(1910, 1924, models.WAKE_STAGE),
    stage(1925, 2040)], models, { startTime: 1740, endTime: 2040 }, 900);
  assert.equal(result.night, 286);
  assert.equal(result.naps, null);
  assert.equal(result.total, 286);
});

test('unavailable main-window metadata leaves the split unknown without hiding the total', () => {
  for (const basic of [null, {}, { startTime: NaN, endTime: 50 }]) {
    const result = stats.summarize([stage(0, 59)], models, basic, 900);
    assert.equal(result.total, 60);
    assert.equal(result.night, null);
    assert.equal(result.naps, null);
  }
});
