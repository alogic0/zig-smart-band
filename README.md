# zig-smart-band

A Linux command-line tool written in Zig 0.17.0 for Xiaomi Smart Band battery
and device information, plus authenticated notifications from scripts.

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
- `inspect [ADDRESS]`: list GATT services, characteristics, and access flags.
- `notify MESSAGE`: authenticate, negotiate services, and send a Zepp OS alert
  titled `PC`, with app name `Desktop`. Quote messages containing spaces.

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
looks for unknown addresses for up to 30 seconds, connects, and waits for services.
Connections opened by the tool are closed on normal and handled-error exits;
preexisting connections are preserved.

D-Bus calls normally time out after five seconds; connect/write calls use fifteen
seconds. Service discovery allows fifteen seconds, and protocol responses twenty.
These are per-phase limits, rather than a whole-command deadline. Cleanup may take
another five seconds. Read-only requests retry once after a transport failure;
notification writes are not replayed. An initial battery read lets a fresh link settle.

Battery/info commands still use ordinary readable GATT services. Authentication
is currently performed for notifications. The tool does not pair, unbind, reset,
or update firmware. The optional screen-wake preference above is the only band
setting it changes. NFC payments, history, and health data
are outside this version.

## Validation

```sh
zig build check test --summary all
zig build check test -Doptimize=safe --summary all
```

Offline tests cover battery/address/config parsing, key exchange and peer
validation, notification encoding, chunk validation, encrypted checksums, and
replay rejection. They do not connect over Bluetooth. OpenSSL 3 is needed for
the key-exchange test.

On 2026-11-02 the tool read battery 42%, hardware `0.91.17.21`, and software
`2.1.0.1` from a Xiaomi Smart Band 7. Zepp Life identifies it as the NFC variant.
The authenticated sender completed a live handshake and negotiated notification
service version 3. An initial authenticated write did not display; the band
requested an app icon. After implementing the icon upload and acknowledgment,
the user confirmed that the notification appeared on the band. A second
notification over a fresh connection also appeared, using the cached icon.
The screen-wake setting was read back as enabled, and the user confirmed that
a subsequent notification woke the display without touch or wrist movement.
Other models and firmware versions have not been tested.

## Protocol references

- [BlueZ Device API](https://bluez.readthedocs.io/en/latest/device-api/)
- [BlueZ GATT API](https://bluez.readthedocs.io/en/latest/gatt-api/)
- [systemd sd-bus API](https://www.freedesktop.org/software/systemd/man/latest/sd-bus.html)
- [Gadgetbridge Huami protocol implementation](https://github.com/Freeyourgadget/Gadgetbridge/tree/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/huami)

The implementation is original Zig code. Gadgetbridge sources were consulted
for wire-format facts; their Java implementations are not included.
