const std = @import("std");
const dbus = @import("dbus.zig");
const A = std.mem.Allocator;

pub const Node = struct {
    path: [:0]const u8,
    device: bool = false,
    adapter: bool = false,
    characteristic: bool = false,
    service: bool = false,
    name: ?[:0]const u8 = null,
    address: ?[:0]const u8 = null,
    uuid: ?[:0]const u8 = null,
    connected: bool = false,
    resolved: bool = false,
    powered: bool = false,
    readable: bool = false,
    writable: bool = false,
    write_without_response: bool = false,
    notifiable: bool = false,
    mtu: u16 = 23,
    battery: ?u8 = null,
};

fn property(a: A, reply: *dbus.Reply, node: *Node, key: []const u8) !void {
    inline for (.{ .{ "Name", "name" }, .{ "Address", "address" }, .{ "UUID", "uuid" } }) |field| {
        if (std.mem.eql(u8, key, field[0])) {
            try reply.require('v', "s");
            @field(node, field[1]) = try reply.string(a, 's');
            try reply.exit();
            return;
        }
    }
    inline for (.{ .{ "Connected", "connected" }, .{ "ServicesResolved", "resolved" }, .{ "Powered", "powered" } }) |field| {
        if (std.mem.eql(u8, key, field[0])) {
            try reply.require('v', "b");
            @field(node, field[1]) = (try reply.basic(c_int, 'b')) != 0;
            try reply.exit();
            return;
        }
    }
    if (std.mem.eql(u8, key, "MTU")) {
        try reply.require('v', "q");
        node.mtu = try reply.basic(u16, 'q');
        try reply.exit();
    } else if (std.mem.eql(u8, key, "Percentage")) {
        try reply.require('v', "y");
        const value = try reply.basic(u8, 'y');
        if (value > 100) return error.InvalidBatteryValue;
        node.battery = value;
        try reply.exit();
    } else if (std.mem.eql(u8, key, "Flags")) {
        try reply.require('v', "as");
        try reply.require('a', "s");
        // Read each string until the array ends, then leave both containers.
        while (true) {
            const flag = reply.basic([*:0]const u8, 's') catch |err| {
                if (err == error.InvalidDBusReply) break;
                return err;
            };
            if (std.mem.eql(u8, std.mem.span(flag), "read")) node.readable = true;
            if (std.mem.eql(u8, std.mem.span(flag), "write")) node.writable = true;
            if (std.mem.eql(u8, std.mem.span(flag), "write-without-response")) node.write_without_response = true;
            if (std.mem.eql(u8, std.mem.span(flag), "notify")) node.notifiable = true;
        }
        try reply.exit();
        try reply.exit();
    } else {
        try reply.skip("v");
    }
}

/// Snapshot strings and nodes are owned by the supplied allocator.
pub fn snapshot(a: A, connection: *dbus.Connection) ![]Node {
    var reply = try connection.call("/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", .{});
    defer reply.deinit();
    var nodes: std.ArrayList(Node) = .empty;
    try reply.require('a', "{oa{sa{sv}}}");
    while (try reply.enter('e', "oa{sa{sv}}")) {
        var node: Node = .{ .path = try reply.string(a, 'o') };
        try reply.require('a', "{sa{sv}}");
        while (try reply.enter('e', "sa{sv}")) {
            const interface = try reply.string(a, 's');
            const known = blk: {
                inline for (.{ .{ "org.bluez.Device1", "device" }, .{ "org.bluez.Adapter1", "adapter" }, .{ "org.bluez.GattCharacteristic1", "characteristic" }, .{ "org.bluez.GattService1", "service" } }) |field| {
                    if (std.mem.eql(u8, interface, field[0])) {
                        @field(node, field[1]) = true;
                        break :blk true;
                    }
                }
                break :blk std.mem.eql(u8, interface, "org.bluez.Battery1");
            };
            if (known) {
                try reply.require('a', "{sv}");
                while (try reply.enter('e', "sv")) {
                    const key = try reply.string(a, 's');
                    try property(a, &reply, &node, key);
                    try reply.exit();
                }
                try reply.exit();
            } else try reply.skip("a{sv}");
            try reply.exit();
        }
        try reply.exit();
        try reply.exit();
        if (node.device or node.adapter or node.characteristic or node.service) try nodes.append(a, node);
    }
    try reply.exit();
    return nodes.toOwnedSlice(a);
}

pub fn findDevice(nodes: []const Node, address: []const u8) ?Node {
    for (nodes) |node| {
        if (node.device and node.address != null and std.ascii.eqlIgnoreCase(node.address.?, address)) return node;
    }
    return null;
}

pub fn belongsTo(path: []const u8, device: []const u8) bool {
    return path.len > device.len and std.mem.startsWith(u8, path, device) and path[device.len] == '/';
}

pub fn findCharacteristic(nodes: []const Node, device: []const u8, uuid: []const u8) ?Node {
    for (nodes) |node| {
        if (node.characteristic and belongsTo(node.path, device) and node.uuid != null and std.ascii.eqlIgnoreCase(node.uuid.?, uuid)) return node;
    }
    return null;
}

pub fn validateAddress(address: []const u8) !void {
    if (address.len != 17) return error.InvalidBluetoothAddress;
    for (address, 0..) |byte, i| {
        if (i % 3 == 2) {
            if (byte != ':') return error.InvalidBluetoothAddress;
        } else if (!std.ascii.isHex(byte)) return error.InvalidBluetoothAddress;
    }
}

pub fn batteryLevel(uuid: []const u8, bytes: []const u8) !u8 {
    const offset: usize = if (std.ascii.eqlIgnoreCase(uuid, "00002a19-0000-1000-8000-00805f9b34fb")) blk: {
        if (bytes.len != 1) return error.InvalidBatteryValue;
        break :blk 0;
    } else if (std.ascii.eqlIgnoreCase(uuid, "00000006-0000-3512-2118-0009af100700")) blk: {
        if (bytes.len < 2) return error.InvalidBatteryValue;
        break :blk 1;
    } else return error.UnsupportedBatteryFormat;
    if (bytes[offset] > 100) return error.InvalidBatteryValue;
    return bytes[offset];
}

test "strict battery decoding rejects missing and out-of-range values" {
    const standard = "00002a19-0000-1000-8000-00805f9b34fb";
    const huami = "00000006-0000-3512-2118-0009af100700";
    try std.testing.expectEqual(@as(u8, 0), try batteryLevel(standard, &.{0}));
    try std.testing.expectEqual(@as(u8, 100), try batteryLevel(standard, &.{100}));
    try std.testing.expectEqual(@as(u8, 48), try batteryLevel(huami, &.{ 15, 48, 0 }));
    try std.testing.expectError(error.InvalidBatteryValue, batteryLevel(standard, &.{}));
    try std.testing.expectError(error.InvalidBatteryValue, batteryLevel(standard, &.{255}));
    try std.testing.expectError(error.InvalidBatteryValue, batteryLevel(huami, &.{15}));
    try std.testing.expectError(error.UnsupportedBatteryFormat, batteryLevel("unknown", &.{50}));
}

test "device boundaries and Bluetooth addresses are checked" {
    try validateAddress("C2:0B:03:01:3B:39");
    try std.testing.expectError(error.InvalidBluetoothAddress, validateAddress("C2:0B:03:01:3B:3X"));
    try std.testing.expectError(error.InvalidBluetoothAddress, validateAddress("C2_0B_03_01_3B_39"));
    try std.testing.expect(belongsTo("/dev_ABC/service1", "/dev_ABC"));
    try std.testing.expect(!belongsTo("/dev_ABCD/service1", "/dev_ABC"));
}

test "characteristics from another device cannot be selected" {
    const uuid = "00002a19-0000-1000-8000-00805f9b34fb";
    const nodes = [_]Node{
        .{ .path = "/org/bluez/hci0/dev_ABCD/service1/char1", .characteristic = true, .uuid = uuid },
        .{ .path = "/org/bluez/hci0/dev_ABC/service1/char2", .characteristic = true, .uuid = uuid },
    };
    const found = findCharacteristic(&nodes, "/org/bluez/hci0/dev_ABC", uuid).?;
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_ABC/service1/char2", found.path);
    try std.testing.expect(findCharacteristic(&nodes, "/org/bluez/hci0/dev_OTHER", uuid) == null);
}
