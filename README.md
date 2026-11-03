# zig-smart-band

A Linux command-line tool written in Zig 0.17.0 for Xiaomi Smart Band battery
and device information, plus authenticated notifications from scripts.
It can also synchronize the band's clock with the computer.

It uses BlueZ over D-Bus through `libsystemd.so.0`, and OpenSSL 3 for B-163
key exchange. AES and packet checksums use Zig's standard library. No Python,
third-party Zig packages, development headers, or phone app are needed at runtime.

## Requirements

- Linux, a powered Bluetooth adapter, and the BlueZ service.
- Access to the system D-Bus and BlueZ as your regular user.
- The system `libsystemd.so.0`, libc, and `libcrypto.so.3` runtimes.
- Zig 0.17.0, matching `.zigversion`, to build.

## Build and run

```sh
zig build
./zig-out/bin/smart-band --help
./zig-out/bin/smart-band scan
./zig-out/bin/smart-band info
./zig-out/bin/smart-band battery
./zig-out/bin/smart-band inspect
./zig-out/bin/smart-band notify "Build finished"
./zig-out/bin/smart-band sync-time
```

The same commands work through `zig build run -- COMMAND`.

## Device configuration

Save `config.example.zon` as `~/.config/smart-band/config.zon`, and enter your
band's address from `scan`. With an absolute `XDG_CONFIG_HOME`, the default is
`$XDG_CONFIG_HOME/smart-band/config.zon` instead.

```zig
.{
    .device = .{
        .name = "My Xiaomi Smart Band 7",
        .address = "AA:BB:CC:DD:EE:FF",
    },
    .auth_key_file = "auth-key.hex",
}
```

`name` is descriptive and optional. The address selects the device. Battery and
revision strings are read from the band. The config works from any directory.

For notifications, save the existing pairing key as 32 hexadecimal digits in
`auth-key.hex` beside the config, with file permissions `0600`. Keep this file
outside the repository. The key is never printed. `auth_key_file` is optional;
it defaults to `auth-key.hex`. Relative paths resolve beside the selected config.
Key acquisition is a separate setup step; this program does not contact vendor
cloud services.

See [How we retrieved the device key](DEVICE_KEY_RETRIEVAL.md) for the tested
USB, Xiaomi account linking, and cloud-retrieval procedure.

```sh
./zig-out/bin/smart-band --config /path/to/config.zon notify "Backup done"
```

`info`, `battery`, and `inspect` accept an optional address override; `notify`
uses the configured device. `scan` and explicit address overrides require no config.
Invalid notification text, key files, and configurations fail before Bluetooth access.

## Commands

- `scan [seconds]`: discover for 1–60 seconds (default 10). The BlueZ snapshot
  can include cached devices, so a listing does not prove current reachability.
- `info [ADDRESS]`: read available model/manufacturer/revision strings and battery.
  Unavailable fields are explicit; failure to read any values exits unsuccessfully.
- `battery [ADDRESS]`: read the percentage. GATT reads take priority over BlueZ's
  optional cached Battery1 property. Values outside 0–100 fail.
- `inspect [ADDRESS]`: list GATT services and characteristics with readable names,
  full UUIDs, and access flags. Unidentified UUIDs are explicitly labeled unknown.
- `notify MESSAGE`: authenticate, negotiate services, and send a Zepp OS alert
  titled `PC`, with app name `Desktop`. Quote messages containing spaces.
- `sync-time`: authenticate and set the configured band's clock to the computer's
  current local date, time, and UTC offset, then verify the clock by reading it back.
- `alarm`: list, add, edit, enable, disable, or delete alarms on the configured band.
- `weather`: fetch weather for the configured location and answer the band's
  authenticated weather requests. `weather --preview` prints the forecast.
- `sleep`: download sleep/activity history and export raw records, JSON, and CSV.

## Sleep history

```sh
./zig-out/bin/smart-band sleep
./zig-out/bin/smart-band sleep --all
./zig-out/bin/smart-band sleep --all --timeout 1800
./zig-out/bin/smart-band sleep --since 2026-10-27
./zig-out/bin/smart-band sleep --since 2026-10-27 --output ./sleep-download
```

The default request starts at local midnight seven days ago. `--since` is
inclusive and uses the computer's local timezone, including daylight saving.
Use `--all` to download all retained sleep/activity records: the tool requests
from 2000-01-01 (before the band existed), then follows each returned block until
the band reports no more records or reaches the latest minute at download start.
`--all` and `--since` cannot be combined. This covers the activity stream,
including sleep, movement, steps, and its heart-rate samples; other health and
workout-history types are separate streams.
Use `TZ=America/Chicago` before the command to select that timezone explicitly.
The saved pairing key is used for authentication. Keep the band nearby with
the phone's Bluetooth off for the transfer.

On the tested band, Linux also needed standard Bluetooth pairing to keep a
long transfer connected. If BlueZ reports `No agent available` and the band
disconnects during a download, keep a Bluetooth pairing agent open while
running the command and approve the request for your band. This computer's
saved Bluetooth bond is separate from `auth-key.hex`.

Downloads are stored in a new directory under
`$XDG_DATA_HOME/smart-band/sleep/`, or `~/.local/share/smart-band/sleep/` by default.
`--output DIR` selects the directory. Existing downloads are not overwritten.
Files use mode `0600`; new directories use mode `0700`.

Each download contains:

- `download.json`: completion status, failure details if any, block metadata,
  UTC timestamps, and the original eight bytes of each activity sample.
- `activity.csv`: all downloaded activity minutes, raw sleep scores, heart rate,
  and estimated sleep stage. Invalid heart-rate sentinels are left empty.
- `sleep.csv`: the same columns, restricted to records the band marks as sleep.
- `block-0001.bin`, etc.: original activity bytes before decoding; incomplete
  blocks use `.partial.bin`.

The Band 7 records one activity sample per minute. Its light/deep/REM labels in
the CSV are estimates using the reference implementation's score thresholds;
the original scores and bytes remain available. Times in the CSV follow the
computer's timezone, while UTC timestamps are also included.

The transfer checks packet order, announced sample counts, eight-byte alignment, and any supplied
CRC32 before decoding a block. Errors stop the download and preserve captured
raw bytes; `download.json` marks partial results as incomplete. Transfers are
bounded by a configurable timeout (900 seconds by default); `--timeout SECONDS`
sets another positive duration. There is no fixed number of rounds or 31-day
total sample cap. Packet inactivity is limited to 30 seconds, and a single block
is limited to 16 MiB to reject malformed responses. A stalled cursor stops the
transfer instead of looping. A fresh command can download the range again.
The tool always acknowledges with the keep-data flag;
it does not mark detailed records as consumed or delete them from the band.
Only history still available on the band can be downloaded.

## Weather

Add a location to `~/.config/smart-band/config.zon`, using its coordinates:

```zig
.weather = .{
    .location = "Germantown, TN",
    .latitude = 35.08676,
    .longitude = -89.81009,
    .cache_ttl_seconds = 600,
},
```

```sh
./zig-out/bin/smart-band weather --preview
./zig-out/bin/smart-band weather
```

The preview loads and prints current conditions and a seven-day forecast.
Weather data is loaded before Bluetooth setup. A successful download is saved
immediately, so a failed connection to the band does not lose it. Quick retries
and previews reuse the saved data for 600 seconds (10 minutes) by default.
`cache_ttl_seconds` in the `weather` section changes that lifetime; set it to
`0` to fetch on every invocation and disable cache reads and writes.

Cache files live in `$XDG_CACHE_HOME/smart-band/`, or
`~/.cache/smart-band/` when `XDG_CACHE_HOME` is unset. Each location has its own
cache, named `weather-YYYY-MM-DD-LOCATION_HASH.json` using the weather location's
local forecast date, so filenames sort by date. Existing caches with the date
at the end or no date are renamed when reused, retaining
their original age. Expired, invalid, or future-dated entries trigger a fresh download, as
does a new local calendar day so yesterday's high/low cannot be reused as today's.
An expired cache is not used if the provider request fails. The command prints
whether it is fetching weather or reusing a cache and how old the cached data is.

The update uses the saved pairing key, verifies the band's temperature display
unit as Celsius, and sends the configured location. The band then requests its
weather data over Bluetooth; keep it nearby, open its Weather app, and scroll
to the daily forecast so it requests today's high and low temperatures.
The command waits up to 60 seconds for requests, prints the supplied high/low,
and reports which responses it supplied. Success requires both current weather
and the daily forecast. A current-only update reports a partial result and exits
with an error so scripts can detect missing high/low data. Check the screen to
confirm the weather was displayed.

Weather comes from [Open-Meteo](https://open-meteo.com/), with current conditions,
seven daily forecasts, and up to 72 hours of hourly forecasts. The HTTPS fetch
uses native Zig, has a 30-second deadline and a 128 KiB response limit, and
requires no API key for personal, noncommercial use. Coordinates are sent to
Open-Meteo. Weather data is provided under
[CC BY 4.0](https://open-meteo.com/en/licence), and its condition codes are
converted to the band's weather icons. Air quality, weather alerts, tides, and
moon data are not supplied.

Each invocation performs one update. Run it again to refresh the band's cached
weather. It does not install a background updater. Existing configs work with
the optional `weather` section absent or set to `null`.

## Alarm management

```sh
./zig-out/bin/smart-band alarm list
./zig-out/bin/smart-band alarm add 07:30 weekdays
./zig-out/bin/smart-band alarm add 09:00 once --disabled
```

Use an alarm's ID from `list` or the result of `add` in these commands
(replace `ID` with that number):

```sh
./zig-out/bin/smart-band alarm set ID 08:00 mon,wed,fri
./zig-out/bin/smart-band alarm disable ID
./zig-out/bin/smart-band alarm enable ID
./zig-out/bin/smart-band alarm delete ID
```

Alarm commands use the saved pairing key and the same connection-setup retries
as notifications. Times must use 24-hour `HH:MM` and refer to the band's local
clock. Use `sync-time` first if the clock needs correcting.

`list` shows stable alarm IDs 1–10, enabled state, time, repetition, and existing
smart-wake status. IDs identify slots rather than row numbers; gaps are normal.
Always use an ID from the current list when editing or deleting an alarm.

`add` chooses an unused slot and enables the new alarm unless `--disabled` is
supplied. It fails when all ten slots are occupied. Repetition defaults to
`once`; alternatives are `daily`, `weekdays`, `weekends`, or comma-separated
day names (`mon,tue,wed,thu,fri,sat,sun`, case-insensitive).

`set ID HH:MM [REPEAT]` changes an existing alarm's time. Omitting repetition
preserves its existing schedule. It also preserves enabled state and smart-wake
flags. `enable` and `disable` change only the enabled flag. New alarms use ordinary
wake behavior; existing smart-wake settings are preserved.

Every change reads the latest list, writes only the target slot, and reads the
list back to verify both the requested change and preservation of other alarms.
Firmware-specific repeat flags are retained when the schedule is unchanged;
weekday-mask normalization is allowed when checking an explicit schedule change.
An alarm write is never automatically repeated after a timeout or uncertain
result. Run `alarm list` to inspect the actual state before retrying a change.

## Clock synchronization

```sh
./zig-out/bin/smart-band sync-time
```

This uses the same saved pairing key and Bluetooth setup retries as `notify`.
The clock is sampled after connection and authentication, so time spent searching
for the band does not make the update stale. The command reports the timestamp
and UTC offset being sent. Its read-back check allows five seconds of clock drift.
The time write is never automatically replayed after an uncertain result.

The computer's local timezone is used, including its current daylight-saving
offset. To select another timezone for one invocation, use the `TZ` environment
variable, for example:

```sh
TZ=UTC ./zig-out/bin/smart-band sync-time
```

The update contains the current offset rather than timezone transition rules;
resynchronize when the desired offset changes. The band uses the Zepp OS
11-byte Current Time layout. A 10-byte standard read-back confirms the clock
but cannot independently confirm the supplied UTC offset; the output notes this.

## Service and characteristic names

`inspect` shows names first and keeps UUIDs available for protocol debugging:

```text
service Battery Service (0000180f-0000-1000-8000-00805f9b34fb)
  characteristic Battery Level (00002a19-0000-1000-8000-00805f9b34fb) read notify
```

The catalog is in [src/gatt_names.zig](src/gatt_names.zig). It includes standard
Bluetooth names and known Huami channels, with case-insensitive matching of full
UUIDs. Unknown identifiers retain their UUID and an explicit unknown label.
Vendor channels labeled `Legacy` use older protocol assignments; their name
alone does not establish which commands a particular firmware implements.

## Authenticated notifications

The sender uses Huami 2021 B-163 authentication and a fresh AES session. It queries
service encryption requirements and notification capabilities, then fragments the
message according to the BLE MTU. Notification service versions 3–5 are supported;
version 3 is used by the tested band. The old, unreliable Alert Notification
Service sender has been removed.

When the band requests an app icon, the sender uploads a small desktop-monitor
icon and completes its acknowledgment. This supports RGB565 icon formats 4/8
and file-transfer service versions 1/2. Other formats fail explicitly.

Messages must be nonempty, valid UTF-8 without NUL bytes, and at most 506 bytes.
Messages are rejected without truncation. The connection stays open for ten
seconds after sending or completing an icon upload, to process responses. This
does not set the band's onscreen display duration.

Command success confirms authentication and completed writes, not visual delivery.
Notification writes are never automatically retried: after an uncertain outcome,
check the band before resending. Failed commands exit nonzero. The command does
not automatically forward notifications from other desktop apps.

### Turn the screen on for notifications

Add this option at the root of your device config:

```zig
.notification_wake_screen = true,
```

On the next `notify`, the tool reads the band's screen-wake preference, changes
it only when necessary, and verifies the value before sending the notification.
This is a persistent band setting and also applies to phone notifications.
Use `false` to disable it, or omit the option/use `null` to leave the setting as-is.
Removing the option does not undo a setting previously applied to the band.
The setting respects the band's Do Not Disturb mode and does not set the display
duration. Other display preferences are left unchanged.

## Bluetooth behavior

Keep the band nearby and awake. Temporarily turn off phone Bluetooth when Zepp
Life or Mi Fitness is connected to the band. The tool uses Bluetooth LE discovery,
looks for unknown addresses for up to 60 seconds, connects, and waits for services.
Connections opened by the tool are closed on normal and handled-error exits;
preexisting connections are preserved.

Connection setup allows 30 seconds for connecting and another 30 seconds for
service discovery. An early disconnect or transport failure during setup is
cleaned up and retried, up to three setup attempts with a two-second pause.
Unknown-device discovery can run again on a later attempt. Each attempt starts
with a fresh BlueZ snapshot; an already connected device skips the connect call.
Authentication, settings changes, and notification writes happen after setup
retries finish. They are never replayed by this loop.

The limits are optional fields in the config's root `bluetooth` section:

```zig
.bluetooth = .{
    .search_timeout_seconds = 60,
    .connect_timeout_seconds = 30,
    .service_timeout_seconds = 30,
    .connect_attempts = 3,
    .retry_delay_seconds = 2,
},
```

Search accepts 1–600 seconds, connect/service timeouts 1–120 seconds, attempts
1–255, and retry delay 0–10 seconds. For example, `.connect_attempts = 10`
allows up to ten total setup attempts. Set `connect_attempts` to 1 to disable setup
retries. Existing configs use the defaults above. Explicit address overrides
bypass the device config and use defaults; `scan [seconds]` retains its own
1–60 second duration.

These are per-attempt, per-phase limits, rather than a whole-command deadline.
Other D-Bus calls normally time out after five seconds; application writes allow
fifteen seconds, and protocol responses twenty. Cleanup may take another five
seconds. Read-only requests retry once after a transport failure; notification
writes are not replayed. Notifications and clock synchronization use an initial
battery read to let a fresh link settle; weather uses a best-effort battery read,
and alarm commands authenticate directly.

Battery/info commands still use ordinary readable GATT services. Authentication
is performed for notifications, clock synchronization, alarms, weather, and sleep
history. The tool does not pair,
unbind, reset, or update firmware. It changes the clock only with `sync-time`
and alarms only through explicit alarm commands, and the temperature display unit
and weather location through `weather`. It changes the screen-wake preference
only when explicitly configured. NFC payments and other health-history types
are outside this version.

## Validation

```sh
zig build check test --summary all
zig build check test -Doptimize=safe --summary all
```

Offline tests cover battery/address/config parsing, key exchange and peer
validation, notification encoding, chunk validation, encrypted checksums,
replay rejection, alarm parsing, slot allocation, and verified updates, and
weather parsing, condition mapping, response encoding, and request handling.
Sleep-history tests cover request encoding, score interpretation, packet gaps,
CRC failures, raw capture, CSV/JSON export, and the keep-data acknowledgment,
plus downloads exceeding 31 days and 64 blocks and stalled-cursor detection.
They do not connect over Bluetooth. OpenSSL 3 is needed for
the key-exchange test.

On 2026-11-02 the tool read battery 42%, hardware `0.91.17.21`, and software
`2.1.0.1` from a Xiaomi Smart Band 7. Zepp Life identifies it as the NFC variant.
The authenticated sender completed a live handshake and negotiated notification
service version 3. An initial authenticated write did not display; the band
requested an app icon. After implementing the icon upload and acknowledgment,
the user confirmed that the notification appeared on the band. A second
notification over a fresh connection also appeared, using the cached icon.
Clock synchronization was also tested: the band accepted the computer's local
time and UTC offset, and its Current Time read-back matched the system clock.
Alarm management passed a live create/edit/enable/disable/delete cycle in an
unused slot, with every change read back and the original three alarms preserved.
The screen-wake setting was read back as enabled, and the user confirmed that
a subsequent notification woke the display without touch or wrist movement.
Weather was also tested with Germantown, Tennessee: Celsius was read back as
the selected temperature unit, the band requested current conditions, and the
user confirmed the updated weather appeared. In a subsequent live test, opening
Weather and scrolling to the daily forecast triggered daily and hourly forecast
requests. The tool supplied both, and the user confirmed high and low
temperatures appeared.
Sleep-history download was tested on the same band: three blocks yielded
11,553 continuous minute records, including 3,140 minutes marked as sleep.
All three raw-block CRC32 values matched the band, sample counts matched their
announcements, and the exported CSV row counts matched the JSON records.
The transfer used the keep-data acknowledgment for every block.
A repeat download retrieved 1,413 identical existing records plus three newly
recorded minutes, confirming that the first transfer left records available.
On 2026-11-03, `sleep --all` retrieved 65,424 continuous minute records from
September 18 through November 3, including 14,576 minutes marked as sleep.
All three blocks passed sample-count and CRC32 checks, and both CSV row counts
matched the JSON records. This repeated full download succeeded with the saved
Linux Bluetooth bond after closing the temporary pairing agent.
Other models and firmware versions have not been tested.

## Protocol references

- [BlueZ Device API](https://bluez.readthedocs.io/en/latest/device-api/)
- [BlueZ GATT API](https://bluez.readthedocs.io/en/latest/gatt-api/)
- [systemd sd-bus API](https://www.freedesktop.org/software/systemd/man/latest/sd-bus.html)
- [Gadgetbridge Huami protocol implementation](https://github.com/Freeyourgadget/Gadgetbridge/tree/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/huami)
- [Gadgetbridge Zepp OS weather format](https://github.com/Freeyourgadget/Gadgetbridge/blob/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/huami/zeppos/ZeppOsWeather.java)
- [Open-Meteo forecast API](https://open-meteo.com/en/docs)
- [Gadgetbridge Huami activity history protocol](https://github.com/Freeyourgadget/Gadgetbridge/tree/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/huami/operations/fetch)

The implementation is original Zig code. Gadgetbridge sources were consulted
for wire-format facts; their Java implementations are not included.
