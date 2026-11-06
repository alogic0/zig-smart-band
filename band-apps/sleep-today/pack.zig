//! Build the device app with Zig alone; the packaged runtime remains JavaScript.
const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
const app_id = 1397502007;
const maximum_size = 256 * 1024;
const default_output = "zig-out/band-apps/sleep-today.bin";
const usage =
    \\Usage: zig build sleep-app -- [--diagnostics] [--output FILE]
    \\Default output: zig-out/band-apps/sleep-today.bin
    \\--diagnostics enables temporary local sleep-stage logging.
    \\
;

const Options = struct {
    output: []const u8 = default_output,
    diagnostics: bool = false,
    help: bool = false,
};

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--diagnostics")) {
            options.diagnostics = true;
        } else if (std.mem.eql(u8, args[i], "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i == args.len or args[i].len == 0 or std.mem.startsWith(u8, args[i], "--")) return error.InvalidArguments;
            options.output = args[i];
        } else return error.InvalidArguments;
    }
    return options;
}

fn isString(value: ?std.json.Value, expected: []const u8) bool {
    const actual = value orelse return false;
    return actual == .string and std.mem.eql(u8, actual.string, expected);
}

fn makeManifest(a: A, source: []const u8, diagnostics: bool) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, source, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAppManifest;
    const app = parsed.value.object.get("app") orelse return error.InvalidAppManifest;
    if (app != .object) return error.InvalidAppManifest;
    const id = app.object.get("appId") orelse return error.InvalidAppManifest;
    if (id != .integer or id.integer != app_id or
        !isString(app.object.get("appType"), "app") or
        !isString(app.object.get("appName"), "Sleep today")) return error.InvalidAppManifest;
    const arena = parsed.arena.allocator();
    try parsed.value.object.put(arena, "debug", .{ .bool = diagnostics });
    // Fixed timestamps and field order preserve reproducible package bytes.
    var info: std.json.ObjectMap = .{};
    try info.put(arena, "mode", .{ .string = "preview" });
    try info.put(arena, "timeStamp", .{ .integer = 1793664000 });
    try info.put(arena, "expiredTime", .{ .integer = 157680000 });
    try info.put(arena, "generator", .{ .string = "zig-smart-band" });
    try parsed.value.object.put(arena, "packageInfo", .{ .object = info });
    return std.json.Stringify.valueAlloc(a, parsed.value, .{});
}

fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

fn square(value: i32) i32 {
    return value * value;
}

fn icon() [64 + 100 * 100 * 2]u8 {
    var bytes: [64 + 100 * 100 * 2]u8 = @splat(0);
    bytes[0] = 46;
    bytes[2] = 2;
    put(u16, &bytes, 12, 100);
    put(u16, &bytes, 14, 100);
    bytes[16] = 16;
    bytes[17] = 0x20;
    // Dialog-chip app assets require SOMH followed by the real row width.
    @memcpy(bytes[18..22], "SOMH");
    put(u16, &bytes, 22, 100);
    for (0..100) |y| {
        for (0..100) |x| {
            const ix: i32 = @intCast(x);
            const iy: i32 = @intCast(y);
            var coverage: u32 = 0;
            // Eighth-pixel integer sampling exactly preserves the circular
            // background's 4x4 antialiasing. Black corners blend into the menu.
            for ([_]i32{ 1, 3, 5, 7 }) |dx| {
                for ([_]i32{ 1, 3, 5, 7 }) |dy| {
                    if (square(ix * 8 + dx - 400) + square(iy * 8 + dy - 400) < square(49 * 8)) coverage += 1;
                }
            }
            var rgb: u32 = (0x10 * coverage / 16) << 16 | (0x18 * coverage / 16) << 8 | (0x28 * coverage / 16);
            const moon = square(ix - 46) + square(iy - 39) < square(24);
            const cutout = square(ix - 57) + square(iy - 29) < square(22);
            if (moon and !cutout) rgb = 0xf2f4fa;
            if (y >= 70 and y < 79) {
                if (x >= 23 and x < 40) {
                    rgb = 0xacc9ed;
                } else if (x >= 42 and x < 59) {
                    rgb = 0x8998d7;
                } else if (x >= 61 and x < 78) {
                    rgb = 0xd0b1db;
                }
            }
            const red = (rgb >> 16) & 255;
            const green = (rgb >> 8) & 255;
            const blue = rgb & 255;
            put(u16, &bytes, 64 + 2 * (y * 100 + x), @intCast((red >> 3) << 11 | (green >> 2) << 5 | (blue >> 3)));
        }
    }
    return bytes;
}

const Entry = struct { name: []const u8, data: []const u8 };

fn zipStored(a: A, entries: [4]Entry) ![]u8 {
    var size: usize = 22;
    for (entries) |entry| {
        if (entry.data.len > maximum_size) return error.AppPackageTooLarge;
        size += 30 + entry.name.len + entry.data.len + 46 + entry.name.len;
    }
    if (size > maximum_size) return error.AppPackageTooLarge;
    const bytes = try a.alloc(u8, size);
    @memset(bytes, 0);
    var offsets: [4]u32 = undefined;
    var crcs: [4]u32 = undefined;
    const date = (2026 - 1980) << 9 | 11 << 5 | 3;
    var at: usize = 0;
    for (entries, 0..) |entry, i| {
        offsets[i] = @intCast(at);
        crcs[i] = std.hash.Crc32.hash(entry.data);
        put(u32, bytes, at, 0x04034b50);
        put(u16, bytes, at + 4, 20);
        put(u16, bytes, at + 12, date);
        put(u32, bytes, at + 14, crcs[i]);
        put(u32, bytes, at + 18, @intCast(entry.data.len));
        put(u32, bytes, at + 22, @intCast(entry.data.len));
        put(u16, bytes, at + 26, @intCast(entry.name.len));
        @memcpy(bytes[at + 30 ..][0..entry.name.len], entry.name);
        at += 30 + entry.name.len;
        @memcpy(bytes[at..][0..entry.data.len], entry.data);
        at += entry.data.len;
    }
    const directory = at;
    for (entries, 0..) |entry, i| {
        put(u32, bytes, at, 0x02014b50);
        put(u16, bytes, at + 4, 0x0314); // Unix creator, ZIP version 2.0.
        put(u16, bytes, at + 6, 20);
        put(u16, bytes, at + 14, date);
        put(u32, bytes, at + 16, crcs[i]);
        put(u32, bytes, at + 20, @intCast(entry.data.len));
        put(u32, bytes, at + 24, @intCast(entry.data.len));
        put(u16, bytes, at + 28, @intCast(entry.name.len));
        put(u32, bytes, at + 38, 0o100644 << 16);
        put(u32, bytes, at + 42, offsets[i]);
        @memcpy(bytes[at + 46 ..][0..entry.name.len], entry.name);
        at += 46 + entry.name.len;
    }
    put(u32, bytes, at, 0x06054b50);
    put(u16, bytes, at + 8, entries.len);
    put(u16, bytes, at + 10, entries.len);
    put(u32, bytes, at + 12, @intCast(at - directory));
    put(u32, bytes, at + 16, @intCast(directory));
    return bytes;
}

const app_entry =
    \\(function () {
    \\  var host = __$$hmAppManager$$__.currentApp;
    \\  host.app = DeviceRuntimeCore.App({
    \\    globalData: {},
    \\    onCreate: function () {},
    \\    onDestroy: function () {}
    \\  });
    \\})();
    \\
;

const page_registration =
    \\;
    \\  var SleepTodayFilesystemProbe, SleepTodayRawPattern, SleepTodayFileRanges;
    \\  function Page(definition) {
    \\    var host = __$$hmAppManager$$__.currentApp;
    \\    host.current.module = DeviceRuntimeCore.Page(definition);
    \\  }
    \\
;

pub fn buildPackage(a: A, diagnostics: bool) ![]u8 {
    const manifest = try makeManifest(a, @embedFile("app.json"), diagnostics);
    defer a.free(manifest);
    const page = try std.mem.concat(a, u8, &.{
        "(function () {\n  var SleepTodayDiagnostics = ",
        if (diagnostics) "true" else "false",
        page_registration,
        @embedFile("src/stats.js"),
        "\n",
        @embedFile("src/theme.js"),
        "\n",
        @embedFile("src/history.js"),
        "\n",
        @embedFile("src/page.js"),
        "\n})();\n",
    });
    defer a.free(page);
    const image = icon();
    // Keep stable lexical order and exactly the four installer-approved files.
    return zipStored(a, .{
        .{ .name = "app.js", .data = app_entry },
        .{ .name = "app.json", .data = manifest },
        .{ .name = "assets/icon.png", .data = &image },
        .{ .name = "page/index.js", .data = page },
    });
}

fn execute(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const options = try parseOptions(args[1..]);
    var buffer: [1024]u8 = undefined;
    var output = Io.File.stdout().writer(init.io, &buffer);
    const out = &output.interface;
    if (options.help) {
        try out.writeAll(usage);
    } else {
        const bytes = try buildPackage(a, options.diagnostics);
        var atomic = try Io.Dir.cwd().createFileAtomic(init.io, options.output, .{ .replace = true, .make_path = true });
        defer atomic.deinit(init.io);
        try atomic.file.writeStreamingAll(init.io, bytes);
        try atomic.replace(init.io);
        try out.print("Built {s} ({d} bytes, app {d})\n", .{ options.output, bytes.len, app_id });
    }
    try out.flush();
}

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        std.debug.print("sleep-app: {t}\n", .{err});
        if (err == error.InvalidArguments) std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
}

test "package options preserve explicit diagnostic and custom-output controls" {
    const defaults = try parseOptions(&.{});
    try std.testing.expect(!defaults.diagnostics);
    try std.testing.expectEqualStrings(default_output, defaults.output);
    const custom = try parseOptions(&.{ "--diagnostics", "--output", "nested output/app.bin" });
    try std.testing.expect(custom.diagnostics);
    try std.testing.expectEqualStrings("nested output/app.bin", custom.output);
    try std.testing.expect((try parseOptions(&.{"--help"})).help);
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{"--unknown"}));
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{"--output"}));
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{ "--output", "--diagnostics" }));
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{ "--output", "" }));
}

test "manifest rejects firmware and other app identities before packaging" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidAppManifest, makeManifest(a, "[]", false));
    try std.testing.expectError(error.InvalidAppManifest, makeManifest(a, "{\"app\":{\"appId\":1}}", false));
    try std.testing.expectError(error.InvalidAppManifest, makeManifest(a, "{\"app\":{\"appId\":1397502007,\"appType\":\"firmware\",\"appName\":\"Sleep today\"}}", false));
}

test "identical inputs produce reproducible app package bytes" {
    const a = std.testing.allocator;
    const first = try buildPackage(a, false);
    defer a.free(first);
    const second = try buildPackage(a, false);
    defer a.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
}
