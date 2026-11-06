const std = @import("std");
const dbus = @import("dbus.zig");
const connect = @import("connect.zig");
const bluez = @import("bluez.zig");
const config = @import("config.zig");
const notification = @import("notification.zig");
const gatt_names = @import("gatt_names.zig");
const zepp = @import("zepp.zig");
const alarms = @import("alarms.zig");
const weather = @import("weather.zig");
const weather_cache = @import("weather_cache.zig");
const sleep = @import("sleep.zig");
const sleep_stats = @import("sleep_stats.zig");
const app_install = @import("app_install.zig");
const menu = @import("menu.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const discover = connect.discover;

fn readCharacteristic(a: A, io: Io, connection: *dbus.Connection, node: bluez.Node) ![]const u8 {
    if (!node.readable) return error.CharacteristicNotReadable;
    var reply = connection.call(node.path, "org.bluez.GattCharacteristic1", "ReadValue", .{ .empty_dict = true, .report_failure = false }) catch |err| blk: {
        if (err != error.DBusCallFailed) return err;
        // Retrying a read is safe; authentication failures are never retried.
        try io.sleep(.fromMilliseconds(250), .awake);
        break :blk try connection.call(node.path, "org.bluez.GattCharacteristic1", "ReadValue", .{ .empty_dict = true });
    };
    defer reply.deinit();
    return reply.bytes(a);
}

fn readBattery(a: A, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node) !u8 {
    // Prefer an actual GATT read over BlueZ's optional cached Battery1 property.
    for ([_][]const u8{ "00002a19-0000-1000-8000-00805f9b34fb", "00000006-0000-3512-2118-0009af100700" }) |uuid| {
        if (bluez.findCharacteristic(nodes, device.path, uuid)) |node| {
            if (!node.readable) continue;
            return bluez.batteryLevel(uuid, try readCharacteristic(a, io, connection, node));
        }
    }
    if (device.battery) |value| return value;
    return error.BatteryServiceUnavailable;
}

fn help(out: *Io.Writer) !void {
    try out.writeAll(
        \\smart-band: control a Xiaomi Smart Band over Bluetooth LE
        \\
        \\Usage:
        \\  smart-band scan [seconds]   Discover nearby devices (default 10, max 60)
        \\  smart-band info [ADDRESS]     Read device information and battery
        \\  smart-band battery [ADDRESS]  Read battery percentage
        \\  smart-band inspect [ADDRESS]  List the device's GATT services and characteristics
        \\  smart-band notify MESSAGE     Send a text alert to the configured band
        \\  smart-band sync-time          Sync the band to the computer's local time
        \\  smart-band weather            Update weather for the configured location (Celsius)
        \\  smart-band weather --preview  Fetch and print weather without Bluetooth
        \\  smart-band weather --json     Fetch desktop weather JSON without Bluetooth
        \\  smart-band weather --background  Sync with one bounded connection attempt
        \\  smart-band sleep [--all | --since YYYY-MM-DD] [--output DIR] [--timeout SECONDS]
        \\    Download sleep/activity history (default: last seven days); keep records on band.
        \\    --all requests all retained sleep/activity records; timeout defaults to 900 seconds.
        \\  smart-band sleep stats [--input DIR] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--csv]
        \\    Show completed sleep by wake-up date from saved downloads, without Bluetooth.
        \\  smart-band install-sleep-app FILE
        \\    Install this project's Sleep today JavaScript app; rejects OS firmware.
        \\  smart-band apps              List installed app-package IDs and versions
        \\  smart-band menu list         List app-menu IDs and current positions
        \\  smart-band menu move APP POSITION
        \\  smart-band menu up|down APP
        \\    APP: eight-digit hex ID or a listed name, for example sleep-today.
        \\    Positions start at 1 within the app's current section; moves are read back.
        \\  smart-band sleep-app-debug [SECONDS]
        \\    Capture one diagnostic snapshot from this app only (default 180s, max 240s).
        \\  smart-band alarm list
        \\  smart-band alarm add HH:MM [REPEAT] [--disabled]
        \\  smart-band alarm set ID HH:MM [REPEAT]
        \\  smart-band alarm enable|disable|delete ID
        \\    REPEAT: once (default), daily, weekdays, weekends, or mon,wed,fri
        \\    IDs are 1-10, as printed by alarm list; times use the band's local clock.
        \\  smart-band --help
        \\
        \\The default device is read from $XDG_CONFIG_HOME/smart-band/config.zon
        \\or ~/.config/smart-band/config.zon when XDG_CONFIG_HOME is unset.
        \\Use smart-band --config PATH COMMAND for a different config file.
        \\An optional ADDRESS overrides the config (for example AA:BB:CC:DD:EE:FF).
        \\notify writes an alert; it does not pair, reset, unbind, or update firmware.
        \\notify authenticates using auth-key.hex beside the config, or auth_key_file.
        \\sync-time uses the same key and verifies the clock with a GATT read-back.
        \\Optional notification_wake_screen sets and verifies the band's screen-wake preference.
        \\Bluetooth setup defaults: search 60s, connect 30s, services 30s, up to 3 attempts.
        \\Override these limits in the config's bluetooth section.
        \\
    );
}

fn execute(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var out_buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writer(io, &out_buffer);
    const out = &output.interface;
    defer out.flush() catch {};
    var command_index: usize = 1;
    var config_path: ?[]const u8 = null;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--config")) {
        if (args.len < 4) return error.InvalidArguments;
        config_path = args[2];
        command_index = 3;
    }
    const command = args[command_index..];
    if (command.len == 0 or (command.len == 1 and std.mem.eql(u8, command[0], "--help"))) {
        try help(out);
        try out.flush();
        return;
    }
    const scan = std.mem.eql(u8, command[0], "scan");
    const info = std.mem.eql(u8, command[0], "info");
    const battery = std.mem.eql(u8, command[0], "battery");
    const inspect = std.mem.eql(u8, command[0], "inspect");
    const notify = std.mem.eql(u8, command[0], "notify");
    const sync_time = std.mem.eql(u8, command[0], "sync-time");
    const alarm = std.mem.eql(u8, command[0], "alarm");
    const weather_command = std.mem.eql(u8, command[0], "weather");
    const sleep_command = std.mem.eql(u8, command[0], "sleep");
    const install_sleep_app = std.mem.eql(u8, command[0], "install-sleep-app");
    const list_apps = std.mem.eql(u8, command[0], "apps");
    const menu_command = std.mem.eql(u8, command[0], "menu");
    const sleep_app_debug = std.mem.eql(u8, command[0], "sleep-app-debug");
    if (sleep_command and command.len > 1 and std.mem.eql(u8, command[1], "stats")) {
        const options = try sleep_stats.parse(a, init.environ_map, command[2..]);
        // Release each parsed download after merging, even though Init uses an arena.
        try sleep_stats.run(std.heap.smp_allocator, io, options, out);
        return;
    }
    if (!scan and !info and !battery and !inspect and !notify and !sync_time and !alarm and !weather_command and !sleep_command and !install_sleep_app and !list_apps and !sleep_app_debug and !menu_command) return error.UnknownCommand;
    if (!alarm and !sleep_command and !menu_command and command.len > 2) return error.InvalidArguments;
    const menu_request: ?menu.Command = if (menu_command) try menu.parse(command[1..]) else null;
    const alarm_request: ?alarms.Command = if (alarm) try alarms.parse(command[1..]) else null;
    const sleep_request: ?sleep.Options = if (sleep_command) try sleep.parse(a, io, init.environ_map, command[1..]) else null;
    if (install_sleep_app and command.len != 2) return error.InvalidSleepAppPackage;
    if (list_apps and command.len != 1) return error.InvalidArguments;
    const sleep_app: ?app_install.Package = if (install_sleep_app) try app_install.load(a, io, command[1]) else null;
    const debug_seconds: u8 = if (sleep_app_debug and command.len == 2)
        std.fmt.parseInt(u8, command[1], 10) catch return error.InvalidArguments
    else
        180;
    if (sleep_app_debug and (debug_seconds == 0 or debug_seconds > 240)) return error.InvalidArguments;
    if (sync_time and command.len != 1) return error.InvalidArguments;
    const weather_mode: ?weather.Command = if (weather_command) try weather.parseCommand(command[1..]) else null;
    const weather_preview = weather_mode == .preview or weather_mode == .json;
    if (notify) {
        if (command.len != 2) return error.InvalidArguments;
        try notification.validate(command[1]);
    }
    var seconds: u8 = 10;
    if (scan and command.len == 2) {
        seconds = std.fmt.parseInt(u8, command[1], 10) catch return error.InvalidScanDuration;
        if (seconds == 0 or seconds > 60) return error.InvalidScanDuration;
    }
    var bluetooth: connect.Options = .{};
    var auth_key: ?[16]u8 = null;
    var wake_screen: ?bool = null;
    var weather_settings: ?weather.Settings = null;
    defer if (auth_key) |*key| std.crypto.secureZero(u8, key);
    const address = if (scan) "" else if (!notify and !sync_time and !alarm and !weather_command and !sleep_command and !install_sleep_app and !list_apps and !sleep_app_debug and !menu_command and command.len == 2) command[1] else blk: {
        const path = config_path orelse try config.defaultPath(a, init.environ_map);
        const saved = try config.load(a, io, path);
        bluetooth = saved.bluetooth;
        if (notify or sync_time or alarm or sleep_command or install_sleep_app or list_apps or sleep_app_debug or menu_command or (weather_command and !weather_preview)) auth_key = try config.loadAuthKey(a, io, path, saved);
        if (notify) wake_screen = saved.notification_wake_screen;
        if (weather_command) weather_settings = saved.weather orelse return error.WeatherLocationUnavailable;
        break :blk saved.device.address;
    };
    if (!scan) try bluez.validateAddress(address);
    var weather_log: Io.Writer.Allocating = .init(a);
    defer weather_log.deinit();
    const weather_data: ?weather.Data = if (weather_command) try weather_cache.get(a, io, init.environ_map, weather_settings.?, if (weather_mode == .json) &weather_log.writer else out) else null;
    if (weather_data) |data| {
        if (weather_mode == .json) {
            std.debug.print("{s}", .{weather_log.written()});
            try out.print("{s}\n", .{try data.panelJson(a)});
            return;
        }
        try data.preview(out);
        try out.flush();
        if (weather_preview) return;
    }
    var connection = try dbus.Connection.init();
    defer connection.deinit();

    if (weather_mode == .background) {
        const snapshot = try bluez.snapshot(a, &connection);
        if (bluez.findDevice(snapshot, address)) |device| if (device.connected) return error.BluetoothBusy;
        bluetooth.search_timeout_seconds = @min(bluetooth.search_timeout_seconds, 10);
        bluetooth.connect_timeout_seconds = @min(bluetooth.connect_timeout_seconds, 20);
        bluetooth.service_timeout_seconds = @min(bluetooth.service_timeout_seconds, 15);
        bluetooth.connect_attempts = 1;
    }

    if (scan) {
        std.debug.print("Discovering for {d} seconds...\n", .{seconds});
        const nodes = try discover(a, io, &connection, seconds, null);
        try out.writeAll("BlueZ device snapshot (may include cached devices):\n");
        for (nodes) |node| {
            if (!node.device or node.address == null) continue;
            try out.print("{s}  {s}\n", .{ node.address.?, node.name orelse "(unnamed)" });
        }
        try out.flush();
        return;
    }

    const ready = try connect.open(a, io, &connection, address, bluetooth);
    defer ready.close(&connection);
    const nodes = ready.nodes;
    const device = ready.device;

    if (menu_request) |request| {
        _ = readBattery(a, io, &connection, nodes, device) catch {};
        try zepp.manageMenu(a, io, &connection, nodes, device, auth_key.?, request, out);
    } else if (sleep_app_debug) {
        _ = readBattery(a, io, &connection, nodes, device) catch {};
        try zepp.debugSleepApp(a, io, &connection, nodes, device, auth_key.?, debug_seconds, out);
    } else if (list_apps) {
        _ = readBattery(a, io, &connection, nodes, device) catch {};
        try zepp.listApps(a, io, &connection, nodes, device, auth_key.?, out);
    } else if (sleep_app) |package| {
        _ = try readBattery(a, io, &connection, nodes, device);
        try zepp.installSleepApp(a, io, &connection, nodes, device, auth_key.?, package, out);
    } else if (sleep_request) |request| {
        _ = readBattery(a, io, &connection, nodes, device) catch {};
        try zepp.downloadSleep(a, io, &connection, nodes, device, auth_key.?, request, out);
    } else if (weather_data) |data| {
        // Let initial GATT traffic settle, without requiring battery access.
        _ = readBattery(a, io, &connection, nodes, device) catch {};
        try zepp.updateWeather(a, io, &connection, nodes, device, auth_key.?, data, out);
    } else if (alarm) {
        try zepp.manageAlarms(a, io, &connection, nodes, device, auth_key.?, alarm_request.?, out);
    } else if (sync_time) {
        _ = try readBattery(a, io, &connection, nodes, device);
        try zepp.syncTime(a, io, &connection, nodes, device, auth_key.?, out);
    } else if (notify) {
        _ = try readBattery(a, io, &connection, nodes, device);
        try zepp.notify(a, io, &connection, nodes, device, auth_key.?, command[1], wake_screen);
        try out.writeAll("Authenticated notification written; check the band for display confirmation.\n");
    } else if (inspect) {
        try out.print("{s} ({s})\n", .{ device.name orelse "(unnamed)", address });
        for (nodes) |node| {
            if (!bluez.belongsTo(node.path, device.path) or node.uuid == null) continue;
            const kind: gatt_names.Kind = if (node.service) .service else .characteristic;
            const label = gatt_names.lookup(kind, node.uuid.?) orelse if (node.service) "Unknown service" else "Unknown characteristic";
            try out.print("{s} {s} ({s}){s}{s}{s}{s}\n", .{
                if (node.service) "service" else "  characteristic",
                label,
                node.uuid.?,
                if (node.readable) " read" else "",
                if (node.writable) " write" else "",
                if (node.write_without_response) " write-without-response" else "",
                if (node.notifiable) " notify" else "",
            });
        }
    } else if (battery) {
        try out.print("{d}%\n", .{try readBattery(a, io, &connection, nodes, device)});
    } else {
        try out.print("Name: {s}\nAddress: {s}\n", .{ device.name orelse "(unnamed)", address });
        var values_read: usize = 0;
        for ([_][2][]const u8{
            .{ "Model", "00002a24-0000-1000-8000-00805f9b34fb" },
            .{ "Manufacturer", "00002a29-0000-1000-8000-00805f9b34fb" },
            .{ "Firmware", "00002a26-0000-1000-8000-00805f9b34fb" },
            .{ "Hardware", "00002a27-0000-1000-8000-00805f9b34fb" },
            .{ "Software", "00002a28-0000-1000-8000-00805f9b34fb" },
        }) |field| {
            if (bluez.findCharacteristic(nodes, device.path, field[1])) |node| {
                const data = readCharacteristic(a, io, &connection, node) catch |err| {
                    try out.print("{s}: unavailable ({t})\n", .{ field[0], err });
                    continue;
                };
                if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidDeviceText;
                const text = std.mem.trimEnd(u8, data, "\x00");
                try out.print("{s}: {s}\n", .{ field[0], text });
                values_read += 1;
            }
        }
        const level = readBattery(a, io, &connection, nodes, device) catch |err| {
            try out.print("Battery: unavailable ({t})\n", .{err});
            if (err == error.AuthenticationRequired or err == error.BatteryServiceUnavailable) {
                try out.writeAll("This firmware may require vendor authentication for battery access.\n");
            }
            try out.flush();
            if (values_read == 0) return err;
            return;
        };
        try out.print("Battery: {d}%\n", .{level});
    }
    try out.flush();
}

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        std.debug.print("smart-band: {t}\n", .{err});
        switch (err) {
            error.InvalidBluetoothOptions => std.debug.print("Check the config's bluetooth section: search_timeout_seconds 1-600, connect_timeout_seconds and service_timeout_seconds 1-120, connect_attempts 1-255, retry_delay_seconds 0-10.\n", .{}),
            error.WeatherLocationUnavailable, error.InvalidWeatherConfiguration => std.debug.print("Set weather = .{{ .location = \"City\", .latitude = 0.0, .longitude = 0.0 }} in the device config, using your city's coordinates.\n", .{}),
            error.WeatherNotRequested => std.debug.print("The band did not request current weather. Open its Weather app while running the weather command again.\n", .{}),
            error.WeatherForecastNotRequested => std.debug.print("Run weather again, open Weather on the band, and scroll to its daily forecast while the command is connected.\n", .{}),
            error.InvalidSleepArguments, error.InvalidSleepDate => std.debug.print("Use sleep [--all | --since YYYY-MM-DD] [--output DIR] [--timeout SECONDS]. --all and --since are exclusive; timeout must be positive. Dates use the computer's local timezone and cannot be in the future.\n", .{}),
            error.InvalidSleepStatsArguments, error.InvalidSleepStatsDate => std.debug.print("Use sleep stats [--input DIR] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--csv]. Dates are inclusive local calendar dates; --until cannot precede --since.\n", .{}),
            error.NoSleepDownloads, error.NoSleepSamples => std.debug.print("No saved activity samples found. Download with sleep --all, or select a capture directory with sleep stats --input DIR.\n", .{}),
            error.InvalidSleepCapture => std.debug.print("Expected a version-1 download.json with eight-byte activity samples at 60-second intervals.\n", .{}),
            error.InvalidSleepAppPackage => std.debug.print("Supply the Sleep today app built by zig build sleep-app. Other apps and OS firmware are rejected.\n", .{}),
            error.AppStorageFull => std.debug.print("The band has insufficient app storage for Sleep today.\n", .{}),
            error.AppInstallBatteryLow => std.debug.print("The band rejected app installation because its battery is too low.\n", .{}),
            error.InstalledAppNotListed => std.debug.print("The app transfer completed, but Sleep today was not found in the returned app list. Check the band's menu before retrying.\n", .{}),
            error.InvalidMenuArguments, error.InvalidMenuApp => std.debug.print("Use menu list, menu move APP POSITION, or menu up|down APP. APP is an eight-digit hex ID or a listed name such as sleep-today.\n", .{}),
            error.InvalidMenuPosition => std.debug.print("Menu positions start at 1 within the app's current section. Use menu list to see available positions.\n", .{}),
            error.MenuAppNotFound, error.MenuAppHidden => std.debug.print("The selected app is not in a visible menu section. Run menu list to see app IDs and sections.\n", .{}),
            error.InvalidMenuResponse => std.debug.print("The band returned a malformed or unsupported menu response; its entries could not be preserved.\n", .{}),
            error.MenuChangeRejected, error.MenuChangeNotVerified => std.debug.print("The band did not confirm the requested menu order. Run menu list to inspect the current order.\n", .{}),
            error.WeatherFetchTimedOut, error.WeatherProviderFailed => std.debug.print("Could not fetch weather from Open-Meteo; try weather --preview to check the data connection.\n", .{}),
            error.DeviceNotFound, error.DeviceDisconnected, error.DBusCallFailed => std.debug.print("Keep the band nearby and awake; temporarily disconnect the phone app, then run scan.\n", .{}),
            error.PairingKeyUnavailable, error.InvalidPairingKey => std.debug.print("Save the 32 hexadecimal pairing-key digits in auth-key.hex beside the config, or set auth_key_file.\n", .{}),
            error.AuthenticationRequired => std.debug.print("The band requires authentication. No pairing keys or settings were changed.\n", .{}),
            error.BatteryServiceUnavailable => std.debug.print("No readable battery service was exposed. Run inspect to examine this firmware.\n", .{}),
            error.AuthenticatedServiceUnavailable => std.debug.print("The Huami 2021 authentication characteristics are unavailable.\n", .{}),
            error.EmptyNotification => std.debug.print("Supply nonempty text, for example: smart-band notify \"Build finished\"\n", .{}),
            error.InvalidNotificationText => std.debug.print("Notification text must be valid UTF-8 without NUL bytes.\n", .{}),
            error.NotificationTooLong => std.debug.print("Notification text exceeds the {d}-byte maximum.\n", .{notification.max_message_bytes}),
            error.InvalidAlarmArguments, error.InvalidAlarmId, error.InvalidAlarmTime, error.InvalidAlarmRepeat => std.debug.print("Use alarm list, alarm add HH:MM [REPEAT] [--disabled], alarm set ID HH:MM [REPEAT], or alarm enable|disable|delete ID. IDs: 1-10; repeat: once, daily, weekdays, weekends, or mon,wed,fri.\n", .{}),
            error.AlarmNotFound => std.debug.print("No alarm at that ID. Run alarm list for current IDs.\n", .{}),
            error.AlarmSlotsFull => std.debug.print("All ten alarm slots are occupied. Delete an alarm explicitly before adding one.\n", .{}),
            else => {},
        }
        std.process.exit(1);
    };
}

test {
    _ = @import("bluez.zig");
    _ = @import("config.zig");
    _ = @import("notification.zig");
    _ = @import("zepp.zig");
    _ = @import("b163.zig");
    _ = @import("connect.zig");
    _ = @import("gatt_names.zig");
    _ = @import("band_time.zig");
    _ = @import("alarms.zig");
    _ = @import("weather.zig");
    _ = @import("weather_cache.zig");
    _ = @import("sleep.zig");
    _ = @import("sleep_stats.zig");
    _ = @import("app_install.zig");
    _ = @import("menu.zig");
    _ = @import("app_debug.zig");
}
