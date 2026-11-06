// Canonical native UI tokens; DESIGN.md records their roles and mapping.
var SleepTodayTheme = {
  width: 192,
  height: 490,
  colors: {
    background: 0x000000,
    text: 0xf2f4fa,
    muted: 0xaeb8cf,
    light: 0xacc9ed,
    deep: 0x8998d7,
    rem: 0xd0b1db,
    track: 0x202a3c
  },
  font: { value: 48, body: 19, caption: 16, nightStart: 22, sleepRows: 24, history: 22 },
  inset: 18,
  goalMinutes: 480,
  screenHoldSeconds: 180,
  loading: { x: 70, y: 146, size: 52, lineWidth: 4, interval: 80, batchDelay: 20, batchRecords: 64 },
  history: { headingY: 500, textY: 536, fallbackLineHeight: 32 },
  goalArc: { x: 8, y: 8, size: 176, radius: 88, lineWidth: 6, startAngle: 180, sweepAngle: 180 }
};
