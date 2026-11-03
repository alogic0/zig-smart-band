const std = @import("std");
const bluez = @import("bluez.zig");
const connect = @import("connect.zig");
const weather = @import("weather.zig");
const A = std.mem.Allocator;

pub const Config = struct {
    bluetooth: connect.Options = .{},
    auth_key_file: ?[]const u8 = null,
    notification_wake_screen: ?bool = null,
    weather: ?weather.Settings = null,
    device: struct {
        address: []const u8,
        name: ?[]const u8 = null,
    },
};

pub fn loadAuthKey(a: A, io: std.Io, config_path: []const u8, saved: Config) ![16]u8 {
    const directory = std.fs.path.dirname(config_path) orelse ".";
    const file = saved.auth_key_file orelse "auth-key.hex";
    const path = if (std.fs.path.isAbsolute(file)) file else try std.fs.path.join(a, &.{ directory, file });
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128)) catch return error.PairingKeyUnavailable;
    defer {
        std.crypto.secureZero(u8, source);
        a.free(source);
    }
    return decodeAuthKey(source);
}

pub fn decodeAuthKey(source: []const u8) ![16]u8 {
    const hex = std.mem.trim(u8, source, " \t\r\n");
    if (hex.len != 32) return error.InvalidPairingKey;
    var key: [16]u8 = undefined;
    errdefer std.crypto.secureZero(u8, &key);
    _ = std.fmt.hexToBytes(&key, hex) catch return error.InvalidPairingKey;
    return key;
}

pub fn defaultPath(a: A, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |directory| {
        if (std.fs.path.isAbsolute(directory)) return std.fs.path.join(a, &.{ directory, "smart-band", "config.zon" });
    }
    const home = env.get("HOME") orelse return error.ConfigDirectoryUnavailable;
    return std.fs.path.join(a, &.{ home, ".config", "smart-band", "config.zon" });
}

/// Parsed strings belong to the supplied arena.
pub fn parse(a: A, source: []const u8, path: ?[]const u8) !Config {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const config = std.zon.parse.fromSlice(Config, .{
        .gpa = a,
        .arena = a,
        .source = try a.dupeSentinel(u8, source, 0),
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) {
            if (path) |file| diagnostics.log(file);
            return error.InvalidConfiguration;
        }
        return err;
    };
    try bluez.validateAddress(config.device.address);
    try config.bluetooth.validate();
    if (config.weather) |settings| try settings.validate();
    return config;
}

pub fn load(a: A, io: std.Io, path: []const u8) !Config {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024)) catch |err| {
        std.debug.print("Cannot read device config {s}: {t}\n", .{ path, err });
        if (err == error.FileNotFound) {
            std.debug.print("Create it using config.example.zon, or supply a Bluetooth address explicitly.\n", .{});
        }
        return err;
    };
    return parse(a, source, path);
}

test "device config owns the address and accepts an optional display name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parse(arena.allocator(), ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\", .name = \"My band\" } }", null);
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", config.device.address);
    try std.testing.expectEqualStrings("My band", config.device.name.?);
    const unnamed = try parse(arena.allocator(), ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" } }", null);
    try std.testing.expect(unnamed.device.name == null);
}

test "invalid and misspelled configuration fails before device access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidBluetoothAddress, parse(a, ".{ .device = .{ .address = \"bad\" } }", null));
    try std.testing.expectError(error.InvalidConfiguration, parse(a, ".{ .device = .{ .addres = \"AA:BB:CC:DD:EE:FF\" } }", null));
    try std.testing.expectError(error.InvalidConfiguration, parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\", .extra = true } }", null));
}

test "config path respects XDG and falls back to HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/home/example");
    try std.testing.expectEqualStrings("/home/example/.config/smart-band/config.zon", try defaultPath(a, &env));
    try env.put("XDG_CONFIG_HOME", "/tmp/example-config");
    try std.testing.expectEqualStrings("/tmp/example-config/smart-band/config.zon", try defaultPath(a, &env));
    try env.put("XDG_CONFIG_HOME", "relative");
    try std.testing.expectEqualStrings("/home/example/.config/smart-band/config.zon", try defaultPath(a, &env));
}

test "pairing key accepts a single hex value and rejects malformed input" {
    const key = try decodeAuthKey("  00112233445566778899AABBCCDDEEFF\n");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff }, &key);
    try std.testing.expectError(error.InvalidPairingKey, decodeAuthKey("0011"));
    try std.testing.expectError(error.InvalidPairingKey, decodeAuthKey("00112233445566778899aabbccddeefg"));
}

test "screen wake configuration preserves an explicit false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unchanged = try parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" } }", null);
    try std.testing.expect(unchanged.notification_wake_screen == null);
    const disabled = try parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" }, .notification_wake_screen = false }", null);
    try std.testing.expectEqual(@as(?bool, false), disabled.notification_wake_screen);
    const enabled = try parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" }, .notification_wake_screen = true }", null);
    try std.testing.expectEqual(@as(?bool, true), enabled.notification_wake_screen);
}

test "Bluetooth setup options load overrides and reject invalid limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved = try parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" }, .bluetooth = .{ .search_timeout_seconds = 120, .connect_timeout_seconds = 45, .connect_attempts = 10 } }", null);
    try std.testing.expectEqual(@as(u16, 120), saved.bluetooth.search_timeout_seconds);
    try std.testing.expectEqual(@as(u16, 45), saved.bluetooth.connect_timeout_seconds);
    try std.testing.expectEqual(@as(u16, 30), saved.bluetooth.service_timeout_seconds);
    try std.testing.expectEqual(@as(u8, 10), saved.bluetooth.connect_attempts);
    try std.testing.expectError(error.InvalidBluetoothOptions, parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" }, .bluetooth = .{ .connect_attempts = 0 } }", null));
    try std.testing.expectError(error.InvalidBluetoothOptions, parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" }, .bluetooth = .{ .search_timeout_seconds = 601 } }", null));
}

test "weather configuration is optional and validates the configured coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved = try parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" }, .weather = .{ .location = \"Germantown, TN\", .latitude = 35.08676, .longitude = -89.81009, .cache_ttl_seconds = 1200 } }", null);
    try std.testing.expectEqualStrings("Germantown, TN", saved.weather.?.location);
    try std.testing.expectEqual(@as(u32, 1200), saved.weather.?.cache_ttl_seconds);
    try std.testing.expectError(error.InvalidWeatherConfiguration, parse(a, ".{ .device = .{ .address = \"AA:BB:CC:DD:EE:FF\" }, .weather = .{ .location = \"Test\", .latitude = 91.0, .longitude = 0.0 } }", null));
}
