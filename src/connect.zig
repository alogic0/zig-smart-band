//! Bluetooth discovery and connection setup. Retries stop before application I/O.
const std = @import("std");
const bluez = @import("bluez.zig");
const dbus = @import("dbus.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const device_interface = "org.bluez.Device1";

pub const Options = struct {
    search_timeout_seconds: u16 = 60,
    connect_timeout_seconds: u16 = 30,
    service_timeout_seconds: u16 = 30,
    connect_attempts: u8 = 3,
    retry_delay_seconds: u8 = 2,

    pub fn validate(self: Options) !void {
        if (self.search_timeout_seconds == 0 or self.search_timeout_seconds > 600 or
            self.connect_timeout_seconds == 0 or self.connect_timeout_seconds > 120 or
            self.service_timeout_seconds == 0 or self.service_timeout_seconds > 120 or
            self.connect_attempts == 0 or self.connect_attempts > 5 or self.retry_delay_seconds > 10)
            return error.InvalidBluetoothOptions;
    }
};

pub const Ready = struct {
    nodes: []const bluez.Node,
    device: bluez.Node,
    opened_here: bool,

    pub fn close(self: Ready, connection: *dbus.Connection) void {
        if (self.opened_here) connection.simple(self.device.path, device_interface, "Disconnect", 5_000_000) catch {};
    }
};

pub fn discover(a: A, io: Io, connection: *dbus.Connection, seconds: u16, address: ?[]const u8) ![]bluez.Node {
    const before = try bluez.snapshot(a, connection);
    var adapter: ?bluez.Node = null;
    for (before) |node| {
        if (node.adapter and node.powered) {
            adapter = node;
            break;
        }
    }
    const path = (adapter orelse return error.NoPoweredBluetoothAdapter).path;
    var filter_reply = try connection.call(path, "org.bluez.Adapter1", "SetDiscoveryFilter", .{
        .dictionary_string = .{ .key = "Transport", .value = "le" },
    });
    filter_reply.deinit();
    try connection.simple(path, "org.bluez.Adapter1", "StartDiscovery", 5_000_000);
    defer connection.simple(path, "org.bluez.Adapter1", "StopDiscovery", 5_000_000) catch {};
    const end = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(seconds));
    while (true) {
        const nodes = try bluez.snapshot(a, connection);
        if (address) |target| {
            if (bluez.findDevice(nodes, target) != null) return nodes;
        }
        const now = Io.Timestamp.now(io, .awake);
        if (now.nanoseconds >= end.nanoseconds) return nodes;
        const remaining = now.durationTo(end);
        try io.sleep(.fromNanoseconds(@min(remaining.nanoseconds, 500 * std.time.ns_per_ms)), .awake);
    }
}

pub fn open(a: A, io: Io, connection: *dbus.Connection, address: []const u8, options: Options) !Ready {
    try options.validate();
    var context: Context = .{ .a = a, .io = io, .connection = connection, .address = address, .options = options };
    return retrySetup(&context, options.connect_attempts);
}

const Context = struct {
    a: A,
    io: Io,
    connection: *dbus.Connection,
    address: []const u8,
    options: Options,

    fn attempt(self: *Context) !Ready {
        var nodes = try bluez.snapshot(self.a, self.connection);
        if (bluez.findDevice(nodes, self.address) == null) {
            std.debug.print("Looking for {s} for up to {d} seconds...\n", .{ self.address, self.options.search_timeout_seconds });
            nodes = try discover(self.a, self.io, self.connection, self.options.search_timeout_seconds, self.address);
        }
        var device = bluez.findDevice(nodes, self.address) orelse return error.DeviceNotFound;
        const opened_here = !device.connected;
        // Finish cleanup before retrying. Existing connections are preserved.
        errdefer if (opened_here) self.connection.simple(device.path, device_interface, "Disconnect", 5_000_000) catch {};
        if (opened_here) {
            std.debug.print("Connecting to {s} (up to {d} seconds)...\n", .{ device.name orelse self.address, self.options.connect_timeout_seconds });
            try self.connection.simple(device.path, device_interface, "Connect", @as(u64, self.options.connect_timeout_seconds) * 1_000_000);
        }
        const end = Io.Timestamp.now(self.io, .awake).addDuration(.fromSeconds(self.options.service_timeout_seconds));
        var observed_connected = device.connected;
        while (true) {
            nodes = try bluez.snapshot(self.a, self.connection);
            device = bluez.findDevice(nodes, self.address) orelse return error.DeviceDisconnected;
            if (device.connected) {
                observed_connected = true;
            } else if (observed_connected) return error.DeviceDisconnected;
            if (device.connected and device.resolved) return .{ .nodes = nodes, .device = device, .opened_here = opened_here };
            if (Io.Timestamp.now(self.io, .awake).nanoseconds >= end.nanoseconds) return error.ServiceDiscoveryTimedOut;
            try self.io.sleep(.fromMilliseconds(100), .awake);
        }
    }

    fn pause(self: *Context, err: anyerror, next: u8, total: u8) !void {
        std.debug.print("Bluetooth setup failed ({t}); retrying connection {d}/{d} in {d} seconds...\n", .{ err, next, total, self.options.retry_delay_seconds });
        try self.io.sleep(.fromSeconds(self.options.retry_delay_seconds), .awake);
    }
};

fn retryable(err: anyerror) bool {
    return switch (err) {
        error.DeviceNotFound, error.DeviceDisconnected, error.DBusCallFailed, error.ServiceDiscoveryTimedOut => true,
        else => false,
    };
}

// Only setup returns Ready. Authentication, settings and notification writes are
// performed by the caller after this loop has returned, and can never be replayed here.
fn retrySetup(context: anytype, attempts: u8) !Ready {
    var number: u8 = 1;
    while (true) {
        const ready = context.attempt() catch |err| {
            if (!retryable(err) or number >= attempts) return err;
            number += 1;
            try context.pause(err, number, attempts);
            continue;
        };
        return ready;
    }
}

const Fake = struct {
    errors: []const anyerror,
    calls: usize = 0,
    pauses: usize = 0,
    fn attempt(self: *Fake) !Ready {
        self.calls += 1;
        if (self.calls <= self.errors.len) return self.errors[self.calls - 1];
        return .{ .nodes = &.{}, .device = .{ .path = "/device", .connected = true, .resolved = true }, .opened_here = true };
    }
    fn pause(self: *Fake, _: anyerror, _: u8, _: u8) !void {
        self.pauses += 1;
    }
};

test "a transient setup disconnect recovers within the same command" {
    var fake: Fake = .{ .errors = &.{error.DeviceDisconnected} };
    const result = try retrySetup(&fake, 3);
    try std.testing.expect(result.device.connected and result.device.resolved);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.pauses);
}

test "setup retries stop at the limit and preserve the final error" {
    var fake: Fake = .{ .errors = &.{ error.DBusCallFailed, error.DeviceDisconnected, error.ServiceDiscoveryTimedOut } };
    try std.testing.expectError(error.ServiceDiscoveryTimedOut, retrySetup(&fake, 3));
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqual(@as(usize, 2), fake.pauses);
    fake = .{ .errors = &.{error.DeviceDisconnected} };
    try std.testing.expectError(error.DeviceDisconnected, retrySetup(&fake, 1));
    try std.testing.expectEqual(@as(usize, 0), fake.pauses);
}

test "authentication and nontransport failures never cause setup retries" {
    for ([_]anyerror{ error.AuthenticationRequired, error.InvalidDBusReply, error.NoPoweredBluetoothAdapter, error.Canceled }) |failure| {
        var fake: Fake = .{ .errors = &.{failure} };
        try std.testing.expectError(failure, retrySetup(&fake, 3));
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expectEqual(@as(usize, 0), fake.pauses);
    }
}

test "Bluetooth timeouts and retry counts are bounded" {
    try (Options{}).validate();
    try std.testing.expectError(error.InvalidBluetoothOptions, (Options{ .search_timeout_seconds = 0 }).validate());
    try std.testing.expectError(error.InvalidBluetoothOptions, (Options{ .search_timeout_seconds = 601 }).validate());
    try std.testing.expectError(error.InvalidBluetoothOptions, (Options{ .connect_timeout_seconds = 121 }).validate());
    try std.testing.expectError(error.InvalidBluetoothOptions, (Options{ .service_timeout_seconds = 0 }).validate());
    try std.testing.expectError(error.InvalidBluetoothOptions, (Options{ .connect_attempts = 0 }).validate());
    try std.testing.expectError(error.InvalidBluetoothOptions, (Options{ .retry_delay_seconds = 11 }).validate());
}
