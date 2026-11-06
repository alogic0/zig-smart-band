# Sleep today

A standalone JavaScript app for the Xiaomi Smart Band 7's 192 × 490 screen.
Version 0.3.2 reads the band's local raw activity history. It totals complete
sleep periods ending today, with Night/Naps, estimated light/deep/REM
subtotals, and an upper-edge goal arc. A night crossing midnight is assigned to
its wake-up date, including the previous evening's sleep. It calculates on the
band and does not need a phone service or Linux statistics sync.

The page stays lit while open and restores the normal screen timeout on exit.
The caption shows `Night from HH:MM`, the first raw sleep minute counted in
today's Night total. Swipe up below the summary to see complete sleep periods
for today and yesterday, newest first within each wake-up date. Each entry
shows its start and end time and sleep duration. Dates appear once in each
day's header; an overnight period adds `Previous day`. Whole periods
crossing midnight remain grouped by their end date. Swipe right to exit.

On opening, a rotating circular loader appears before history collection starts.
The reader processes 64 records per timer callback and yields between batches,
keeping the page able to draw while loading. It reads the history once per
opening, then leaves the result fixed and shows `Read HH:MM` in the footer.
Reopen the app for new data. Closing cancels the pending read and
animation and closes its file handle.

The `Night from` caption and sleep-period list use 22 px text. Night/Naps labels
and their values use 24 px text, while stage labels keep their 19 px size.
The enlarged caption uses a wider text box; list height follows the measured
text size, and short day annotations fit the narrow screen.

Build from the repository root:

```sh
zig build sleep-app
zig build
./zig-out/bin/smart-band install-sleep-app zig-out/band-apps/sleep-today.bin
./zig-out/bin/smart-band apps
node --test band-apps/sleep-today/tests/*.test.cjs
```

The output is `zig-out/band-apps/sleep-today.bin`, a device app ZIP containing
JavaScript, `app.json`, and a Dialog-chip RGB565 icon. `pack.zig` builds it using
Zig 0.17.0 and its standard library, including manifest generation, JavaScript
bundling, icon generation, CRCs, and both ZIP directories. The app itself runs
JavaScript on the band. No Python, npm, or external ZIP tools are needed to build.

Custom output and temporary diagnostic builds use arguments after `--`:

```sh
zig build sleep-app -- --output path/to/sleep-today.bin
zig build sleep-app -- --help
```

Inputs are embedded at compile time, so changes to the manifest or JavaScript
invalidate the Zig build cache. The builder runs on the host even when the
Bluetooth CLI is cross-compiled, and writes the output atomically. Fixed ZIP
timestamps and entry order make the package reproducible. `zig build check test`
checks the builder and validates both package modes through the installer's
actual ZIP preflight. The JavaScript runtime tests require Node.js, with no npm
dependencies.

The package declares the native 192-pixel design width and registers through
`DeviceRuntimeCore.App` and `DeviceRuntimeCore.Page`; it does not rely on
SDK-injected App/Page globals being present on the device. The package test
executes the actual built entry points in that runtime model.

Each raw record represents one minute. The calculation excludes awake records,
preserves full periods across midnight, and uses the same raw-kind and score
thresholds as `sleep stats`. A period needs observed non-sleep minutes before
and after it; missing samples and unfinished periods are excluded. The current
minute is not read until it has finished. Opening the page reads local history
once; keeping it open performs no more file or sensor reads. There is no Refresh button or
on-screen app title. Swipe right to close the page; reopening requests fresh data.

The upper-edge arc shows progress toward the owner's chosen eight-hour daily
sleep goal (`goalMinutes: 480` in `src/theme.js`). It fills clockwise over the
top of the screen, from left to right. The arc caps at a full semicircle; the
numeric sleep total can exceed eight hours. Missing data leaves an unfilled arc.
There is no repeated goal-percentage or "Hours asleep today" text caption.
This is a personal target, not a universal recommendation or sleep-quality score.

Night counts raw sleep periods overlapping the native main-sleep window. The
window labels the periods; all counted minutes and stage estimates come from
raw records, without adding the native sensor's total. For example, a
continuous 22:00–06:00 night contributes eight hours to the wake-up date, rather
than six hours after midnight. There is no fixed bedtime or morning cutoff.
Naps counts additional completed sessions ending today, including a whole
additional session that crosses midnight. Separate sessions that ended yesterday
are excluded. Contiguous sleep-marked minutes define periods; awake records and
missing data separate them. Waking exactly at midnight
assigns the session to the new date. A session still unfinished when the page
reads its records is excluded from that snapshot's totals.

If the native main window is unavailable, Night and Naps show `--:--`, while
valid raw totals remain visible. Complete raw coverage can establish zero naps,
shown as `0:00`. The total, stage subtotals, and goal arc use the same selected
periods. A bounded minute map reads from the day before yesterday through the
last completed minute so both displayed dates retain their overnight sleep.
The two-day history does not add yesterday's sleep to today's summary.
Light/deep/REM remain raw stage estimates. The footer shows only the read time
after a successful collection, including when there are no completed periods
or the file contains gaps.

The reader uses read-only access to the firmware-specific `SHAREDP` version 2
activity file, a 4 KiB read buffer, timestamp anchors, and circular addressing.
It validates the known identity page mapping and rereads metadata to reject
concurrent changes. Unsupported layouts, clock-offset mismatches and short reads
show an unavailable/retry state. It never silently substitutes native totals.
Dates follow the band's currently configured UTC offset; that offset must match
the latest activity clock reference. There is no timezone-rule database in the
app. Native classifications can still differ from the displayed raw estimates.

Screen control uses the temporary `hmSetting.setBrightScreen(180)` request,
renewed each minute without reading data, and cancels it when the page is destroyed.
Firmware without this optional API retains its normal timeout. History uses
the native page's regular vertical scrolling; the content stays fixed until the
page is reopened. `Night from --:--` means no counted night
start could be established from the native main-window label.
For example, `Night from 05:13` means 05:13 is the first raw sleep minute included
in today's Night total. It describes the counted records rather than a fixed
bedtime or daily cutoff; awake minutes and excluded incomplete periods do not
move that start earlier.

## Device verification

On 2026-11-05, version 0.2.1's on-band raw reader was compared with a fresh
Bluetooth activity download. Its timestamped window checksum matched the
download byte for byte, including the same missing minute. The daily total and
all three stage estimates matched `sleep stats`, and the user confirmed that
the short sleep period appeared in Naps. The regular build disables diagnostic
logging and performs the same local calculation without a computer connection.

On 2026-11-03, version 0.1.1 was installed on the Smart Band 7 NFC running
firmware 2.1.0.1. The installer verified the app ID in the band's returned app
list, and the user confirmed that the updated screen was readable and showed
a current-day total. The initial version omitted native screen-width metadata
and explicit runtime registration; both are corrected in 0.1.1 and covered by
the built-package test.

A subsequent live capture of all native stage intervals verified the app's
arithmetic: their inclusive durations reproduced its light/deep/REM totals,
and the deep subtotal matched the sensor's `getBasicInfo().deepMin` exactly.
The sensor's `getTotalTime()` covered the complete main sleep window, including
awake intervals, so it must not be displayed as time asleep.

Those early native-source captures produced different classifications and totals
from raw history. Version 0.2.1 replaces that source with raw records for every
count and uses the same stage-estimation thresholds as the CLI.

Version 0.1.5 corrects the menu icon's native image metadata: Dialog-chip app
assets require `SOMH` followed by the actual row width. The earlier notification
image tag made the icon declare a 54-pixel row instead of 100. The user confirmed
the corrected crescent-and-bars icon on the band.

Version 0.1.6 removes the title and Refresh button and replaces the former
24-hour stage timeline with a native goal arc along the upper edge. Automatic
updates reuse the same two arc widgets; the OS releases them when the page closes.

Version 0.1.7 replaces the two redundant captions with Night and Naps rows. It
also gives the app-menu icon a circular background. The native RGB565 asset
retains its verified width metadata; black corners blend into the black menu.

Version 0.1.8 assigns complete sessions to their wake-up date, includes the
pre-midnight part of the main sleep, and applies that rule to the overall total,
stage breakdown, and goal arc. The scope label is now "Night + naps". This app
rule is retained by subsequent versions and the CLI's wake-up-date statistics.
Version 0.3.0 replaces that caption with the counted night start and adds the
scrollable two-day period list and temporary screen hold.
Version 0.3.1 defers collection until after the first frame, adds an animated
loading ring, splits the read into timer-driven batches, and removes duplicate
startup reads. The history now prints dates only in its day headers.
Version 0.3.2 enlarges the night-start caption, Night/Naps rows and period list.
It removes automatic rereads while the page is open and replaces status text
with the successful collection time, `Read HH:MM`.

## Optional device diagnostics

Normal builds disable diagnostic logging. For an explicit local investigation:

```sh
zig build sleep-app -- --diagnostics --output zig-out/band-apps/sleep-today-diagnostic.bin
./zig-out/bin/smart-band install-sleep-app zig-out/band-apps/sleep-today-diagnostic.bin
./zig-out/bin/smart-band sleep-app-debug 240
```

Close and reopen the updated app after the capture is connected. The
temporary build sends numbered 100-character chunks through the native
`HmLogger` because firmware truncates longer log lines. The reader filters to
this app and session, checks chunk ordering, and validates the reconstructed
JSON. It captures at most one snapshot, with a bounded timeout, and stops the
log session on exit. The output contains sleep data and is not a public test
fixture. Rebuild and install the normal package afterward to disable logging
and retain the read-time footer.

Diagnostic snapshots also list the sleep sensor's available properties and
check for nap getters. If `getNap()` exists, its result is captured. The live
Band 7 check on 2026-11-05 exposed the legacy sleep getters but no `getNap`,
`getNapData`, or `getNapInfo`; the extra raw sleep period was still absent from
the refreshed sensor stages.

## Local activity-file investigation

A separate read-only on-band probe on 2026-11-05 confirmed that this firmware
allows access to `/storage/health_allday_activity`. Absolute `hmFS.readdir`
listed shared storage; `hmFS.stat_asset` and `hmFS.open_asset` with the relative
path `../../../health_allday_activity` accessed the activity file. This is a
firmware-specific behavior, outside the documented app-data isolation contract.

The file was 536,798 bytes and began with `SHAREDP` followed by version byte 2.
A streaming search using a 4 KiB buffer found a 32-byte fingerprint from a known
short sleep period. A subsequent 48-byte read matched all six downloaded
eight-byte minute records exactly, including the two minutes not supplied in
the search pattern. The version 0.2.1 reader additionally decodes the validated
timestamp/position anchors, known identity page mapping, and circular data range.
Synthetic tests cover wraparound, erased records, unsupported mappings, file
changes, short reads, and handle cleanup. Other firmware layouts remain unsupported.

Filesystem probes run only in diagnostic builds with explicit private probe
configuration (`SleepTodayFilesystemProbe` or `SleepTodayRawPattern`). Standard
diagnostic builds retain the native sensor snapshot; normal builds perform no
directory inventory or pattern-search probe. They only read the validated
activity store for the counter. The diagnostic stream search uses read-only
flags, limits scans to 1 MiB,
and closes its handle on success and failure. Personal search patterns, device
snapshots, and comparison records stay outside the repository.

Wire-path reference: the original
[Toolbox Path implementation](https://github.com/melianmiko/ZeppOS-Libraries/blob/master/Path.js).

References:

- [Zepp OS 1.0 sleep sensor](https://docs.zepp.com/docs/1.0/watchface/api/hmSensor/sensorId/SLEEP/)
- [Zepp OS 1.0 UI framework](https://docs.zepp.com/docs/1.0/guides/framework/device/intro/)
- [Zepp OS 1.0 arc widget](https://docs.zepp.com/docs/1.0/reference/device-app-api/hmUI/widget/ARC/)
- [ZMake's Band 7 package and graphics documentation](https://mmk.pw/en/zmake/guide/)
- [Zepp OS 1.0 native logging](https://docs.zepp.com/docs/1.0/guides/best-practice/debug/)
- [Temporary screen-on time](https://docs.zepp.com/docs/1.0/watchface/api/hmSetting/setBrightScreen/)
- [Native page scrolling](https://docs.zepp.com/docs/1.0/reference/device-app-api/hmUI/setScrollView/)
- [Zepp loading animation guidance](https://docs.zepp.com/docs/v2/designs/elements/loading/)
