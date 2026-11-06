//! Install only this project's standalone Sleep today app, never OS firmware.
//! Wire-format reference: Gadgetbridge's ZeppOsFirmwareUpdateOperation.
const std = @import("std");
const dbus = @import("dbus.zig");
const bluez = @import("bluez.zig");
const Io = std.Io;
const A = std.mem.Allocator;
const Crc = std.hash.Crc32;
pub const app_id: u32 = 1397502007;
const maximum_size = 256 * 1024;
const control_uuid = "00001531-0000-3512-2118-0009af100700";
const data_uuid = "00001532-0000-3512-2118-0009af100700";
const names = [_][]const u8{ "app.json", "app.js", "page/index.js", "assets/icon.png" };

pub const Package = struct {
    bytes: []const u8,
    crc: u32,
};

pub fn listed(payload: []const u8) !bool {
    if (payload.len < 16 or !std.mem.eql(u8, payload[0..3], &.{ 2, 0, 1 })) return error.InvalidAppInstallResponse;
    var items = std.mem.splitScalar(u8, std.mem.trim(u8, payload[16..], "\x00 "), ';');
    while (items.next()) |item| {
        if (item.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, item, '-') orelse return error.InvalidAppInstallResponse;
        const id = std.fmt.parseInt(u32, item[0..separator], 16) catch return error.InvalidAppInstallResponse;
        if (id == app_id) return true;
    }
    return false;
}

pub fn load(a: A, io: Io, path: []const u8) !Package {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(maximum_size));
    return parse(a, bytes);
}

fn uint16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn uint32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

/// Accept the four stored ZIP entries emitted by `zig build sleep-app`.
/// Check both ZIP directories and their CRCs before opening Bluetooth.
pub fn parse(a: A, bytes: []const u8) !Package {
    if (bytes.len < 22 or bytes.len > maximum_size) return error.InvalidSleepAppPackage;
    var offsets: [4]usize = undefined;
    var sizes: [4]u32 = undefined;
    var crcs: [4]u32 = undefined;
    var found: [4]bool = @splat(false);
    var manifest: ?[]const u8 = null;
    var count: usize = 0;
    var at: usize = 0;
    while (at + 4 <= bytes.len and uint32(bytes, at) == 0x04034b50) {
        if (bytes.len - at < 30 or count == names.len) return error.InvalidSleepAppPackage;
        const compressed: usize = uint32(bytes, at + 18);
        const size = uint32(bytes, at + 22);
        const name_length: usize = uint16(bytes, at + 26);
        const extra_length: usize = uint16(bytes, at + 28);
        if (uint16(bytes, at + 6) != 0 or uint16(bytes, at + 8) != 0 or compressed != size) return error.InvalidSleepAppPackage;
        const header = 30 + name_length + extra_length;
        if (header > bytes.len - at or compressed > bytes.len - at - header) return error.InvalidSleepAppPackage;
        const name = bytes[at + 30 ..][0..name_length];
        const index = for (names, 0..) |allowed, index| {
            if (std.mem.eql(u8, name, allowed)) break index;
        } else return error.InvalidSleepAppPackage;
        if (found[index]) return error.InvalidSleepAppPackage;
        const contents = bytes[at + header ..][0..compressed];
        const crc = uint32(bytes, at + 14);
        if (Crc.hash(contents) != crc) return error.InvalidSleepAppPackage;
        offsets[index] = at;
        sizes[index] = size;
        crcs[index] = crc;
        found[index] = true;
        if (index == 0) manifest = contents;
        count += 1;
        at += header + compressed;
    }
    if (count != names.len or manifest == null) return error.InvalidSleepAppPackage;
    const directory = at;
    var central_found: [4]bool = @splat(false);
    for (0..count) |_| {
        if (bytes.len - at < 46 or uint32(bytes, at) != 0x02014b50) return error.InvalidSleepAppPackage;
        const name_length: usize = uint16(bytes, at + 28);
        const extra_length: usize = uint16(bytes, at + 30);
        const comment_length: usize = uint16(bytes, at + 32);
        const size = 46 + name_length + extra_length + comment_length;
        if (size > bytes.len - at) return error.InvalidSleepAppPackage;
        const name = bytes[at + 46 ..][0..name_length];
        const index = for (names, 0..) |allowed, index| {
            if (std.mem.eql(u8, name, allowed)) break index;
        } else return error.InvalidSleepAppPackage;
        if (central_found[index] or uint16(bytes, at + 8) != 0 or uint16(bytes, at + 10) != 0 or
            uint16(bytes, at + 34) != 0 or uint32(bytes, at + 42) != offsets[index] or
            uint32(bytes, at + 16) != crcs[index] or uint32(bytes, at + 20) != sizes[index] or
            uint32(bytes, at + 24) != sizes[index]) return error.InvalidSleepAppPackage;
        central_found[index] = true;
        at += size;
    }
    if (bytes.len - at != 22 or uint32(bytes, at) != 0x06054b50 or
        uint16(bytes, at + 4) != 0 or uint16(bytes, at + 6) != 0 or
        uint16(bytes, at + 8) != count or uint16(bytes, at + 10) != count or
        uint32(bytes, at + 12) != at - directory or uint32(bytes, at + 16) != directory or
        uint16(bytes, at + 20) != 0) return error.InvalidSleepAppPackage;

    const Manifest = struct {
        app: struct { appId: u32, appType: []const u8, appName: []const u8 },
    };
    const parsed = std.json.parseFromSlice(Manifest, a, manifest.?, .{ .ignore_unknown_fields = true }) catch return error.InvalidSleepAppPackage;
    defer parsed.deinit();
    if (parsed.value.app.appId != app_id or !std.mem.eql(u8, parsed.value.app.appType, "app") or
        !std.mem.eql(u8, parsed.value.app.appName, "Sleep today")) return error.InvalidSleepAppPackage;
    return .{ .bytes = bytes, .crc = Crc.hash(bytes) };
}

const NativeTransport = struct {
    connection: *dbus.Connection,
    io: Io,
    control_node: bluez.Node,
    data_node: bluez.Node,
    receiver: *dbus.Receiver,
    packet_size: usize,

    fn write(self: *@This(), node: bluez.Node, bytes: []const u8) !void {
        var reply = try self.connection.call(node.path, "org.bluez.GattCharacteristic1", "WriteValue", .{
            .write_bytes = bytes,
            .dictionary_string = .{ .key = "type", .value = if (node.write_without_response) "command" else "request" },
            .timeout_us = 15_000_000,
        });
        reply.deinit();
    }
    pub fn control(self: *@This(), bytes: []const u8) !void {
        try self.write(self.control_node, bytes);
    }
    pub fn data(self: *@This(), bytes: []const u8) !void {
        try self.write(self.data_node, bytes);
    }
    pub fn receive(self: *@This()) ![]const u8 {
        return self.receiver.next(self.io, Io.Timestamp.now(self.io, .awake).addDuration(.fromSeconds(30)));
    }
};

pub fn fromBand(a: A, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, package: Package, att_payload: usize, out: *Io.Writer) !void {
    const control = bluez.findCharacteristic(nodes, device.path, control_uuid) orelse return error.AppInstallUnavailable;
    const data = bluez.findCharacteristic(nodes, device.path, data_uuid) orelse return error.AppInstallUnavailable;
    if ((!control.writable and !control.write_without_response) or !control.notifiable or
        (!data.writable and !data.write_without_response) or att_payload < 20 or att_payload > 514) return error.AppInstallUnavailable;
    var receiver: dbus.Receiver = .{ .connection = connection, .path = control.path };
    try receiver.start(a);
    defer receiver.deinit();
    var transport: NativeTransport = .{
        .connection = connection,
        .io = io,
        .control_node = control,
        .data_node = data,
        .receiver = &receiver,
        .packet_size = att_payload,
    };
    try send(&transport, package, out);
}

fn response(transport: anytype, command: u8) ![]const u8 {
    const reply = try transport.receive();
    if (reply.len < 3 or reply[0] != 0x10 or reply[1] != command) return error.InvalidAppInstallResponse;
    if (command == 0xd4) {
        if (reply.len < 6) return error.InvalidAppInstallResponse;
    } else if (reply[2] != 1) {
        if (reply[2] == 0x47) return error.AppStorageFull;
        if (reply[2] == 0x22) return error.AppInstallBatteryLow;
        return error.AppInstallRejected;
    }
    return reply;
}

/// Type 8 always denotes a JavaScript app. This path sends no firmware/reboot
/// command and never repeats uncertain writes or an unexpected progress offset.
pub fn send(transport: anytype, package: Package, out: ?*Io.Writer) !void {
    if (package.bytes.len == 0 or package.bytes.len > maximum_size or transport.packet_size < 20 or transport.packet_size > 514) return error.InvalidSleepAppPackage;
    try transport.control(&.{0xd0});
    const caps = try response(transport, 0xd0);
    if (caps.len < 6) return error.InvalidAppInstallResponse;
    const chunk: usize = uint16(caps, 4);
    if (chunk == 0) return error.InvalidAppInstallResponse;
    var descriptor: [14]u8 = .{ 0xd2, 8 } ++ @as([12]u8, @splat(0));
    std.mem.writeInt(u32, descriptor[2..6], @intCast(package.bytes.len), .little);
    std.mem.writeInt(u32, descriptor[6..10], package.crc, .little);
    std.mem.writeInt(u16, descriptor[10..12], @intCast(chunk), .little);
    descriptor[13] = 0xff;
    try transport.control(&descriptor);
    _ = try response(transport, 0xd2);
    try transport.control(&.{ 0xd3, 1 });
    _ = try response(transport, 0xd3);
    var offset: usize = 0;
    while (offset < package.bytes.len) {
        const end = @min(offset + chunk, package.bytes.len);
        while (offset < end) {
            const take = @min(transport.packet_size, end - offset);
            try transport.data(package.bytes[offset..][0..take]);
            offset += take;
        }
        const progress = try response(transport, 0xd4);
        if (uint32(progress, 2) != offset) return error.UnexpectedAppInstallProgress;
        if (out) |writer| {
            try writer.print("Sleep today app: {d}/{d} bytes acknowledged.\n", .{ offset, package.bytes.len });
            try writer.flush();
        }
    }
    try transport.control(&.{0xd5});
    _ = try response(transport, 0xd5);
    try transport.control(&.{0xd6});
    _ = try response(transport, 0xd6);
}

test "app installation sends app type, exact bytes, and no firmware reboot" {
    const Fake = struct {
        packet_size: usize = 20,
        command: u8 = 0,
        bytes: usize = 0,
        reply: [6]u8 = @splat(0),
        pub fn control(self: *@This(), payload: []const u8) !void {
            self.command = payload[0];
            if (payload[0] == 0xd2) {
                try std.testing.expectEqual(@as(u8, 8), payload[1]);
                try std.testing.expectEqual(@as(u32, 45), uint32(payload, 2));
            }
            try std.testing.expect(payload[0] != 5);
        }
        pub fn data(self: *@This(), bytes: []const u8) !void {
            try std.testing.expect(bytes.len <= self.packet_size);
            for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0x42), byte);
            self.bytes += bytes.len;
        }
        pub fn receive(self: *@This()) ![]const u8 {
            self.reply = .{ 0x10, self.command, 1, 0, 32, 0 };
            if (self.command == 0xd3 or self.command == 0xd4) {
                if (self.bytes > 0) {
                    self.command = 0xd4;
                    self.reply[1] = 0xd4;
                    std.mem.writeInt(u32, self.reply[2..6], @intCast(self.bytes), .little);
                }
            }
            return &self.reply;
        }
    };
    var fake: Fake = .{};
    const bytes: [45]u8 = @splat(0x42);
    try send(&fake, .{ .bytes = &bytes, .crc = Crc.hash(&bytes) }, null);
    try std.testing.expectEqual(@as(usize, 45), fake.bytes);
    try std.testing.expectEqual(@as(u8, 0xd6), fake.command);
}

test "a raw firmware or invalid ZIP cannot pass the app preflight" {
    try std.testing.expectError(error.InvalidSleepAppPackage, parse(std.testing.allocator, "not a JavaScript app"));
    const malformed: [64]u8 = @splat(0);
    try std.testing.expectError(error.InvalidSleepAppPackage, parse(std.testing.allocator, &malformed));
}

test "Zig-built release and diagnostic packages pass the installer's ZIP preflight" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |diagnostics| {
        const bytes = try @import("sleep_app_builder").buildPackage(a, diagnostics);
        defer a.free(bytes);
        const package = try parse(a, bytes);
        try std.testing.expectEqualSlices(u8, bytes, package.bytes);
        try std.testing.expectEqual(std.hash.Crc32.hash(bytes), package.crc);
    }
}

test "app list accepts uppercase hexadecimal ids without confusing a different app" {
    const header: [16]u8 = .{ 2, 0, 1 } ++ @as([13]u8, @splat(0));
    try std.testing.expect(try listed(&(header ++ "534C3037-0.1.0;\x00".*)));
    try std.testing.expect(!try listed(&(header ++ "534C3038-0.1.0;\x00".*)));
}
