# Native desktop weather applet

The `smart-band-panel` executable is written entirely in Zig. GTK 3 and
Ayatana AppIndicator provide the top-bar icon, temperature label and menu.
`smart-band` supplies the existing weather fetching, cache and authenticated
band updates. No JavaScript, Python, browser runtime or new Shell extension is
needed. The small native ABI adapter loads installed shared libraries; building
does not require GTK development headers.

Build and install from the repository root:

```sh
zig build
./zig-out/bin/smart-band-panel --install
```

The installer copies both binaries into `$XDG_DATA_HOME/smart-band/bin/`
(normally `~/.local/share/smart-band/bin/`) and enables
`smart-band-weather-panel.service` in your graphical user session. It starts
immediately and returns at login. Your desktop does not need to restart.
Reinstalling replaces the binaries atomically and preserves panel settings.
The existing `smart-band/config.zon` and pairing key remain the sources for
location, device and authentication.

The top bar shows a weather icon and Celsius temperature. Its menu includes the
location, conditions, today's high/low, humidity, wind, a short forecast,
Open-Meteo attribution, and separate weather-check and band-sync status.
Actions update weather and band immediately, or update desktop weather only.
The previous weather remains visible with `*` when a later provider fetch fails.

Every 30 minutes, and at startup, the applet runs `smart-band weather --json`.
That command writes only JSON to stdout, puts cache diagnostics on stderr, and
does not open Bluetooth or read the pairing key. The applet displays that data
before starting `smart-band weather --background`, which reuses the same cache.
Both operations run outside the GTK thread; menu actions and scheduled updates
cannot start overlapping jobs. On exit, the worker is canceled and joined, and
any child process is terminated and reaped before its memory is freed.

Background sync makes one connection attempt, caps search/connect/service waits
at 10/20/15 seconds, and skips a device already connected through this computer.
The normal interactive command retains its configured retries and timeouts.
The applet also bounds the entire background child process to 180 seconds.
Failed band updates leave the desktop weather usable and retry at the next
scheduled update. There are no repeated desktop notifications on failure.

The band's firmware requests the weather routes. It may request daily high/low
only when its Weather forecast page is opened. The menu distinguishes a full
update, a current-only update, no request, and unavailable/busy Bluetooth. A
full-sync time is recorded only after the CLI confirms both current and daily
forecast responses were supplied. The applet cannot force a firmware request.

Settings: `~/.config/smart-band/panel.zon` (or the XDG config directory).

```zig
.{
    .interval_minutes = 30,
    .sync_band = true,
    .band_timeout_seconds = 180,
    .command = null, // Use the installed smart-band executable.
}
```

Restart after editing settings:

```sh
systemctl --user restart smart-band-weather-panel.service
journalctl --user -u smart-band-weather-panel.service -n 30
```

To stop the applet and disable login startup:

```sh
systemctl --user disable --now smart-band-weather-panel.service
```

The display snapshot is `~/.cache/smart-band/panel-state.json`, saved atomically
with owner-only permissions. Native weather data retains the existing dated
cache files beside it. Pairing keys are never included in desktop state.

Runtime libraries: `libgtk-3.so.0`, `libglib-2.0.so.0`, `libgobject-2.0.so.0`, and
`libayatana-appindicator3.so.1`. The desktop must provide an indicator host;
Ubuntu GNOME's existing AppIndicators extension supplies it on the tested system.

Implementation:

- `src/panel_main.zig`: GTK lifecycle, worker ownership, scheduling, cache, installation.
- `src/panel_ui.zig`: small dynamically loaded native ABI adapter.
- `src/panel_model.zig`: typed weather validation, settings and sync-result classification.
- `src/weather.zig` and `src/weather_cache.zig`: existing provider, forecast and cache logic.

`zig build check test` compiles both executables and runs offline checks, including
the real JSON contract, settings validation and partial-sync classification.

ABI references: [Ayatana AppIndicator header](https://github.com/AyatanaIndicators/libayatana-appindicator/blob/main/src/app-indicator.h),
[GTK initialization](https://docs.gtk.org/gtk3/func.init_check.html),
[GLib timers](https://docs.gtk.org/glib/func.timeout_add_seconds.html).
