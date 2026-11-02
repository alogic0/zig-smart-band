const std = @import("std");
const dbus = @import("dbus.zig");
const connect = @import("connect.zig");
const bluez = @import("bluez.zig");
const config = @import("config.zig");
const notification = @import("notification.zig");
const gatt_names = @import("gatt_names.zig");
const zepp = @import("zepp.zig");
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
        \\smart-band: read band information and send authenticated BLE notifications
        \\
        \\Usage:
        \\  smart-band scan [seconds]   Discover nearby devices (default 10, max 60)
        \\  smart-band info [ADDRESS]     Read device information and battery
        \\  smart-band battery [ADDRESS]  Read battery percentage
        \\  smart-band inspect [ADDRESS]  List the device's GATT services and characteristics
        \\  smart-band notify MESSAGE     Send a text alert to the configured band
        \\  smart-band sync-time          Sync the band to the computer's local time
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
    if (!scan and !info and !battery and !inspect and !notify and !sync_time) return error.UnknownCommand;
    if (command.len > 2) return error.InvalidArguments;
    if (sync_time and command.len != 1) return error.InvalidArguments;
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
    defer if (auth_key) |*key| std.crypto.secureZero(u8, key);
    const address = if (scan) "" else if (!notify and !sync_time and command.len == 2) command[1] else blk: {
        const path = config_path orelse try config.defaultPath(a, init.environ_map);
        const saved = try config.load(a, io, path);
        bluetooth = saved.bluetooth;
        if (notify or sync_time) auth_key = try config.loadAuthKey(a, io, path, saved);
        if (notify) wake_screen = saved.notification_wake_screen;
        break :blk saved.device.address;
    };
    if (!scan) try bluez.validateAddress(address);
    var connection = try dbus.Connection.init();
    defer connection.deinit();

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

    if (sync_time) {
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
            error.DeviceNotFound, error.DeviceDisconnected, error.DBusCallFailed => std.debug.print("Keep the band nearby and awake; temporarily disconnect the phone app, then run scan.\n", .{}),
            error.PairingKeyUnavailable, error.InvalidPairingKey => std.debug.print("Save the 32 hexadecimal pairing-key digits in auth-key.hex beside the config, or set auth_key_file.\n", .{}),
            error.AuthenticationRequired => std.debug.print("The band requires authentication. No pairing keys or settings were changed.\n", .{}),
            error.BatteryServiceUnavailable => std.debug.print("No readable battery service was exposed. Run inspect to examine this firmware.\n", .{}),
            error.AuthenticatedServiceUnavailable => std.debug.print("The Huami 2021 authentication characteristics are unavailable.\n", .{}),
            error.EmptyNotification => std.debug.print("Supply nonempty text, for example: smart-band notify \"Build finished\"\n", .{}),
            error.InvalidNotificationText => std.debug.print("Notification text must be valid UTF-8 without NUL bytes.\n", .{}),
            error.NotificationTooLong => std.debug.print("Notification text exceeds the {d}-byte maximum.\n", .{notification.max_message_bytes}),
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
}
