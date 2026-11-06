---
version: alpha
name: Sleep today
description: A sleep summary and scrollable two-day ledger for the Xiaomi Smart Band 7.
colors:
  background: "#000000"
  text: "#F2F4FA"
  muted: "#AEB8CF"
  light: "#ACC9ED"
  deep: "#8998D7"
  rem: "#D0B1DB"
  track: "#202A3C"
typography:
  display:
    fontFamily: "system-ui, sans-serif"
    fontSize: "48px"
  body:
    fontFamily: "system-ui, sans-serif"
    fontSize: "19px"
  utility:
    fontFamily: "system-ui, sans-serif"
    fontSize: "16px"
  nightStartAndHistory:
    fontFamily: "system-ui, sans-serif"
    fontSize: "22px"
  nightAndNaps:
    fontFamily: "system-ui, sans-serif"
    fontSize: "24px"
omitted:
  - section: rounded
    reason: "No cards, buttons, or other rounded containers."
spacing:
  inset: "18px"
  row: "31px"
components:
  goalArc:
    backgroundColor: "{colors.track}"
---

# Sleep today

## Overview

One native Zepp OS page for the owner of a Smart Band 7 NFC. Its job is to
answer how much sleep belongs to today's wake-up date: the complete main sleep
periods, including their pre-midnight portions, plus additional completed periods
ending today in local raw history. The calculation
runs on the band; there is no phone service, Linux sync, account, or network.
The owner explicitly chose raw history for all app totals, with the same
wake-up-date and stage-estimation rules as `src/sleep_stats.zig`.

The visual reference is a compact sleep ledger: one total, Night/Naps rows, three stage rows,
and a thin arc following the upper screen edge. The arc is the signature; it
shows reported sleep as a fraction of the owner's chosen eight-hour daily goal.
This is a personal target, not a universal recommendation or sleep-quality score.
The target is an English-language, 192 by 490 pixel touch display on a wrist.
There is no Japan-market or multilingual scope in this first version.

## Colors

Black preserves OLED contrast. Pale blue, periwinkle, and lilac distinguish
light, deep, and REM, with explicit text labels so color is never the sole cue.
Muted text remains readable against black. The arc uses pale blue for progress
and the track color for the remaining goal. Progress is encoded by filled arc
length. The owner chose an eight-hour target; do not repeat its percentage in
a text caption. Numeric sleep totals remain readable independently of color.

## Typography

Use the device's native system font. A 48 pixel total is readable at a glance;
Night/Naps labels and values use 24 pixels; the night-start caption and period
list use 22 pixels. Stage labels use 19 pixels and utility copy uses 16. The system-ui
family in the token declaration describes the preview fallback, not a bundled
web font. Durations are H:MM and dates use unambiguous YYYY-MM-DD.

## Layout

Keep the summary in one screen, with 18 pixel horizontal insets and extra
clearance at the capsule-shaped top and bottom. Night and Naps share the same
fixed label/value columns and 31 pixel row rhythm as the three stage rows below.
The wake-up date sits inside the upper arc. The caption above the total is
`Night from HH:MM`, showing the first counted raw minute in today's Night total.
There is no on-screen app
title, Refresh button, "Hours asleep today" line, or goal caption. The two freed
caption lines contain the Night/Naps breakdown.
The native page owns regular vertical scrolling and the system back gesture.
A swipe hint at y=445 leads to the history heading at y=500 and the period
list at y=536. The list groups today and yesterday by wake-up date, newest first
within each day. Each period has Start and End lines in HH:MM form and
a Sleep duration line. Dates appear only in day headers; `Previous day`
identifies overnight starts. The single multiline native text widget and background
grow to fit measured text; the loaded snapshot stays fixed while scrolling.
The enlarged night-start caption uses a 176-pixel box at x=8, y=109, height=30.
The larger Night/Naps rows use 30-pixel boxes within the existing row rhythm.

## Elevation & Depth

Flat surfaces, no shadows, cards, or decorative layers.

## Shapes

The arc is the upper half of a 176 by 176 pixel circle at (8, 8), with a 6 pixel
stroke. It runs clockwise from 180 to 360 degrees, left edge over the top to
right edge, leaving a small inset from the capsule-shaped screen boundary.
The filled sweep is capped at 180 degrees once the eight-hour goal is reached;
the displayed sleep duration remains uncapped. The app-menu icon keeps its moon
and three stage marks inside a circular background, with black corners blending
into the native black menu. Avoid extra frames on this display.

## Components

`src/theme.js` is the canonical runtime token source (model B); this file mirrors
its values and explains their roles. `src/page.js` reads these tokens, and the
Zig packager concatenates the same source into `page/index.js`. The native system font
maps to the typography roles above. `goalMinutes` (480) and `goalArc` in the same
theme own the goal and arc geometry; the page consumes them directly.

Canonical ownership: `src/history.js` owns local-file validation, bounded reads,
circular addressing, complete-period selection, raw stage estimates, and the
Night/Naps split. `src/stats.js` retains shared date/duration formatting and the
native-source calculation used by explicitly configured filesystem probes.
`src/page.js` owns the native text/arc helpers
and loading, success, empty, unavailable, and retry
states. No sibling GUI exists in the CLI repository to inherit from.

Opening the page reads local raw history and the native main-window
metadata used only to label periods as Night or Naps. It reads once per opening;
data, date and read-time text remain fixed until the page is reopened, including
across midnight. Startup first draws a rotating native
ARC loader in the total's space, then starts collecting after returning from
build. Collection processes 64 records per callback with 20 ms yields between
batches; the loading arc advances every 80 ms. There is no synchronous duplicate
read during startup. After successful collection, the footer shows only
`Read HH:MM`. An unavailable API or malformed record
displays dashes and a reopen hint rather than inventing zero sleep. Valid empty
history displays zero and has no complete periods in the list.
Both cases leave the arc unfilled. The spinner widget is hidden on completion. Timers
are removed and an in-progress file read is closed when the page closes; the OS owns release
of the native widget tree. The system back gesture closes the page; there is no
background service or self-relaunch. A temporary 180-second screen-on request
is renewed each minute without reading history or sensor data, and canceled on exit. Unsupported
firmware keeps its normal screen timeout.

Night counts the whole main sleep session ending today. A 22:00–06:00 night
belongs to its wake-up date and includes the two hours before midnight. Awake
and unreported minutes do not count as sleep. There is no fixed bedtime or
morning cutoff. Naps counts additional completed sessions ending today; separate
sessions that ended yesterday are excluded. An additional session crossing
midnight is counted whole on its end date. Contiguous raw sleep records define
periods, with observed non-sleep boundaries; missing samples are never bridged.
Sessions unfinished at read time are excluded from that snapshot. A session
waking exactly at midnight belongs to the new date.

The total, all stage subtotals, and the arc use the same selected sessions.
This split is inferred from the main window, not a native nap flag. Missing
main-window metadata leaves both rows unknown while keeping valid totals for
complete periods. With a main-window label and complete raw coverage, zero
additional sleep displays `0:00`. The bounded minute map starts one minute
before the day before yesterday, retaining complete overnight periods for both
wake-up dates shown in the history. Yesterday's periods do not affect today's
summary. Missing main-window metadata leaves the night-start caption unknown.
Sessions whose start is outside that returned-data window are not reported as
complete from a truncated portion.

Motion is limited to the functional loading ring. There is no external font, raw health-data logging, or
historical calendar. Light/deep/REM use the CLI's raw-score estimates. The footer
shows only the read time after success. An explicitly requested diagnostic build
sends bounded native log chunks once per opening to a local debug capture.
Normal builds disable logging.

## Do's and Don'ts

- Keep today's summary separate from the two-day history and preserve complete sessions across midnight.
- Count each reported minute once and exclude awake intervals.
- Keep all calculations on the band and recover from read failures by reopening.
- Do not claim that unreported intervals are awake or that all naps are exposed.
- Do not replace or modify the built-in Sleep app.
