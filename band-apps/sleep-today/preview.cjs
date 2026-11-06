// Render the actual device page against a native-widget harness. Synthetic data
// is confined to this developer preview and is never packaged into the app.
const { writeFileSync, mkdirSync } = require('node:fs');
const path = require('node:path');
const { start } = require('./tests/runtime.cjs');
const cases = [
  ['Overnight, 22:00–06:00', { basic: { startTime: 1320, endTime: 1799 },
    stages: [{ start: 1320, stop: 1799, model: 4 }] }],
  ['Full night + nap', { stages: [
    { start: 1380, stop: 1679, model: 4 },
    { start: 1680, stop: 1769, model: 6 },
    { start: 1770, stop: 1844, model: 8 },
    { start: 1845, stop: 1859, model: 0 },
    { start: 2220, stop: 2249, model: 4 }
  ], basic: { startTime: 1380, endTime: 1859 } }],
  ['Above the 8h goal', { basic: { startTime: 0, endTime: 539 }, stages: [{ start: 0, stop: 539, model: 4 }] }],
  ['Sleep in progress', { clock: { hour: 6, minute: 40 }, basic: { startTime: 1380, endTime: 599 },
    stages: [{ start: 1380, stop: 1439, model: 4 }, { start: 0, stop: 599, model: 4 }] }],
  ['No records', {}],
  ['Unavailable API', { unsupported: true }]
];
const result = cases.map(([name, options]) => {
  const app = start(options);
  app.runShortTimers();
  const widgets = app.active.map(item => ({ type: item.type, ...item.props }));
  app.destroy();
  return { name, widgets };
});
const output = path.resolve(__dirname, '../../zig-out/band-apps/sleep-today-preview.json');
mkdirSync(path.dirname(output), { recursive: true });
writeFileSync(output, JSON.stringify(result, null, 2));
console.log(output);
