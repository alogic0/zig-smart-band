//! Zepp OS display items (endpoint 0x0026), main-menu type 1.
//! Wire reference: Gadgetbridge ZeppOsDisplayItemsService / ZeppOsMenuType.
//! Preserve each returned record verbatim except the positions being moved.
const std = @import("std");
const app_install = @import("app_install.zig");
const A = std.mem.Allocator;
const Io = std.Io;
pub const endpoint: u16 = 0x26;

pub const Command = union(enum) {
    list,
    move: struct { id: u32, position: u16 },
    up: u32,
    down: u32,
};

const Name = struct { id: u32, key: []const u8, label: []const u8 };
const names = [_]Name{
    .{ .id = app_install.app_id, .key = "sleep-today", .label = "Sleep today" },
    .{ .id = 0x01, .key = "activity-intelligence", .label = "Personal activity intelligence" },
    .{ .id = 0x02, .key = "heart-rate", .label = "Heart rate" },
    .{ .id = 0x03, .key = "workout", .label = "Workout" },
    .{ .id = 0x04, .key = "weather", .label = "Weather" },
    .{ .id = 0x09, .key = "alarm", .label = "Alarm" },
    .{ .id = 0x0a, .key = "camera", .label = "Camera" },
    .{ .id = 0x0b, .key = "music", .label = "Music" },
    .{ .id = 0x0c, .key = "stopwatch", .label = "Stopwatch" },
    .{ .id = 0x0d, .key = "timer", .label = "Timer" },
    .{ .id = 0x0e, .key = "find-phone", .label = "Find phone" },
    .{ .id = 0x0f, .key = "mute-phone", .label = "Mute phone" },
    .{ .id = 0x10, .key = "cards", .label = "Cards" },
    .{ .id = 0x11, .key = "alipay", .label = "Alipay" },
    .{ .id = 0x13, .key = "settings", .label = "Settings" },
    .{ .id = 0x14, .key = "workout-history", .label = "Workout history" },
    .{ .id = 0x15, .key = "reminders", .label = "Reminders" },
    .{ .id = 0x16, .key = "compass", .label = "Compass" },
    .{ .id = 0x19, .key = "pai", .label = "PAI" },
    .{ .id = 0x1a, .key = "world-clock", .label = "World clock" },
    .{ .id = 0x1c, .key = "stress", .label = "Stress" },
    .{ .id = 0x1d, .key = "cycles", .label = "Cycles" },
    .{ .id = 0x1e, .key = "workout-status", .label = "Workout status" },
    .{ .id = 0x20, .key = "calendar", .label = "Calendar" },
    .{ .id = 0x23, .key = "sleep", .label = "Sleep (built-in)" },
    .{ .id = 0x24, .key = "spo2", .label = "SpO2" },
    .{ .id = 0x25, .key = "phone", .label = "Phone" },
    .{ .id = 0x26, .key = "events", .label = "Events" },
    .{ .id = 0x31, .key = "wechat-pay", .label = "WeChat Pay" },
    .{ .id = 0x33, .key = "breathing", .label = "Breathing" },
    .{ .id = 0x38, .key = "pomodoro", .label = "Pomodoro" },
    .{ .id = 0x39, .key = "alexa", .label = "Alexa" },
    .{ .id = 0x3f, .key = "mi-ai", .label = "Mi AI" },
    .{ .id = 0x102, .key = "flashlight", .label = "Flashlight" },
};

fn nameFor(id: u32) ?Name {
    for (names) |name| if (name.id == id) return name;
    return null;
}

fn parseId(text: []const u8) !u32 {
    for (names) |name| if (std.ascii.eqlIgnoreCase(name.key, text)) return name.id;
    if (text.len != 8) return error.InvalidMenuApp;
    for (text) |c| if (!std.ascii.isHex(c)) return error.InvalidMenuApp;
    return std.fmt.parseInt(u32, text, 16) catch return error.InvalidMenuApp;
}

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 1 and std.mem.eql(u8, args[0], "list")) return .list;
    if (args.len < 2) return error.InvalidMenuArguments;
    const id = try parseId(args[1]);
    if (args.len == 2) {
        if (std.mem.eql(u8, args[0], "up")) return .{ .up = id };
        if (std.mem.eql(u8, args[0], "down")) return .{ .down = id };
    }
    if (args.len == 3 and std.mem.eql(u8, args[0], "move")) {
        if (args[2].len == 0) return error.InvalidMenuPosition;
        for (args[2]) |c| if (!std.ascii.isDigit(c)) return error.InvalidMenuPosition;
        const position = std.fmt.parseInt(u16, args[2], 10) catch return error.InvalidMenuPosition;
        if (position == 0 or position > 256) return error.InvalidMenuPosition;
        return .{ .move = .{ .id = id, .position = position } };
    }
    return error.InvalidMenuArguments;
}

const Section = enum(u8) {
    main = 1,
    more = 2,
    hidden = 3,

    fn label(self: Section) []const u8 {
        return switch (self) {
            .main => "Main menu",
            .more => "More",
            .hidden => "Hidden",
        };
    }
};

const Item = struct {
    id: u32,
    section: Section,
    position: u8,
    start: usize,
    end: usize,
};

const List = struct {
    bytes: []const u8,
    items: []Item,

    fn deinit(self: List, a: A) void {
        a.free(self.items);
        a.free(self.bytes);
    }

    fn find(self: List, id: u32) ?Item {
        for (self.items) |item| if (item.id == id) return item;
        return null;
    }

    fn ordered(self: List, section: Section, buffer: *[256]usize) []usize {
        var len: usize = 0;
        for (self.items, 0..) |item, index| {
            if (item.section != section) continue;
            buffer[len] = index;
            len += 1;
        }
        const order = buffer[0..len];
        std.mem.sort(usize, order, self.items, struct {
            fn lessThan(items: []Item, left: usize, right: usize) bool {
                return items[left].position < items[right].position;
            }
        }.lessThan);
        return order;
    }

    fn printItem(item: Item, position: ?usize, out: *Io.Writer) !void {
        if (position) |value| try out.print("{d: >3}  ", .{value}) else try out.writeAll("  -  ");
        try out.print("{X:0>8}  {s}", .{ item.id, if (nameFor(item.id)) |name| name.label else "Unknown app" });
        if (nameFor(item.id)) |name| try out.print(" ({s})", .{name.key});
        try out.writeAll("\n");
    }

    fn print(self: List, out: *Io.Writer) !void {
        for ([_]Section{ .main, .more, .hidden }) |section| {
            var count: usize = 0;
            for (self.items) |item| if (item.section == section) {
                count += 1;
            };
            if (count == 0) continue;
            try out.print("{s}:\nPos  App ID    App\n", .{section.label()});
            if (section == .hidden) {
                for (self.items) |item| if (item.section == section) try printItem(item, null, out);
            } else {
                var buffer: [256]usize = undefined;
                for (self.ordered(section, &buffer), 0..) |index, rank| try printItem(self.items[index], rank + 1, out);
            }
            try out.writeAll("\n");
        }
        if (self.items.len == 0) try out.writeAll("The band returned an empty menu.\n");
    }
};

fn skipString(bytes: []const u8, index: *usize) !void {
    if (index.* >= bytes.len) return error.InvalidMenuResponse;
    const end = std.mem.indexOfScalarPos(u8, bytes, index.*, 0) orelse return error.InvalidMenuResponse;
    index.* = end + 1;
}

fn decode(a: A, payload: []const u8) !List {
    if (payload.len < 4 or payload[0] != 4 or payload[1] != 1) return error.InvalidMenuResponse;
    const count = std.mem.readInt(u16, payload[2..4], .little);
    if (count > (payload.len - 4) / 12) return error.InvalidMenuResponse;
    const bytes = try a.dupe(u8, payload);
    errdefer a.free(bytes);
    const items = try a.alloc(Item, count);
    errdefer a.free(items);
    var at: usize = 4;
    for (items, 0..) |*item, index| {
        if (bytes.len - at < 12 or bytes[at + 8] != 0) return error.InvalidMenuResponse;
        const hex = bytes[at..][0..8];
        for (hex) |c| if (!std.ascii.isHex(c)) return error.InvalidMenuResponse;
        const id = std.fmt.parseInt(u32, hex, 16) catch return error.InvalidMenuResponse;
        const section = std.enums.fromInt(Section, bytes[at + 9]) orelse return error.InvalidMenuResponse;
        const position = bytes[at + 10];
        for (items[0..index]) |previous| {
            if (previous.id == id or (section != .hidden and previous.section == section and previous.position == position)) return error.InvalidMenuResponse;
        }
        const start = at;
        const flags = bytes[at + 11];
        at += 12;
        if (flags & 6 != 0) try skipString(bytes, &at);
        if (flags & 6 == 6) try skipString(bytes, &at);
        item.* = .{ .id = id, .section = section, .position = position, .start = start, .end = at };
    }
    if (at != bytes.len) return error.InvalidMenuResponse;
    return .{ .bytes = bytes, .items = items };
}

const Change = struct {
    id: u32,
    section: Section,
    position: usize,
    payload: ?[]u8,
};

fn plan(a: A, before: List, command: Command) !Change {
    const id = switch (command) {
        .list => return error.InvalidMenuArguments,
        .move => |move| move.id,
        .up, .down => |value| value,
    };
    const item = before.find(id) orelse return error.MenuAppNotFound;
    if (item.section == .hidden) return error.MenuAppHidden;
    var buffer: [256]usize = undefined;
    const order = before.ordered(item.section, &buffer);
    const from = for (order, 0..) |index, rank| {
        if (before.items[index].id == id) break rank;
    } else unreachable;
    const to: usize = switch (command) {
        .list => unreachable,
        .move => |move| if (move.position == 0 or move.position > order.len) return error.InvalidMenuPosition else move.position - 1,
        .up => from -| 1,
        .down => @min(from + 1, order.len - 1),
    };
    var change: Change = .{ .id = id, .section = item.section, .position = to + 1, .payload = null };
    if (from == to) return change;
    var positions: [256]u8 = undefined;
    for (order, 0..) |index, rank| positions[rank] = before.items[index].position;
    const moving = order[from];
    if (to < from) {
        std.mem.copyBackwards(usize, order[to + 1 .. from + 1], order[to..from]);
    } else {
        std.mem.copyForwards(usize, order[from..to], order[from + 1 .. to + 1]);
    }
    order[to] = moving;
    const payload = try a.dupe(u8, before.bytes);
    payload[0] = 5;
    for (order, 0..) |index, rank| payload[before.items[index].start + 10] = positions[rank];
    change.payload = payload;
    return change;
}

fn verify(before: List, expected: []const u8, after: List) !void {
    if (before.items.len != after.items.len) return error.MenuChangeNotVerified;
    for (before.items) |item| {
        const actual = after.find(item.id) orelse return error.MenuChangeNotVerified;
        if (!std.mem.eql(u8, expected[item.start..item.end], after.bytes[actual.start..actual.end])) return error.MenuChangeNotVerified;
    }
}

fn read(a: A, transport: anytype) !List {
    try transport.send(&.{ 3, 1 });
    return decode(a, try transport.receive(4));
}

fn apply(a: A, transport: anytype, before: List, payload: []const u8) !List {
    try transport.send(payload);
    const ack = try transport.receive(6);
    if (ack.len != 3 or ack[0] != 6 or ack[1] != 1) return error.InvalidMenuResponse;
    if (ack[2] != 1) return error.MenuChangeRejected;
    const after = try read(a, transport);
    errdefer after.deinit(a);
    try verify(before, payload, after);
    return after;
}

pub fn execute(a: A, transport: anytype, command: Command, out: *Io.Writer) !void {
    const before = try read(a, transport);
    defer before.deinit(a);
    if (command == .list) return before.print(out);
    const change = try plan(a, before, command);
    const payload = change.payload orelse {
        try out.print("App {X:0>8} is already at {s} position {d}; no update needed.\n\n", .{ change.id, change.section.label(), change.position });
        return before.print(out);
    };
    defer a.free(payload);
    const after = apply(a, transport, before, payload) catch |err| {
        std.debug.print("Menu update could not be confirmed; run menu list to check the band before repeating the command. The write was not replayed.\n", .{});
        return err;
    };
    defer after.deinit(a);
    try out.print("Moved app {X:0>8} to {s} position {d}; verified on the band.\n\n", .{ change.id, change.section.label(), change.position });
    try after.print(out);
}

// Deliberately unsorted, with gaps in the visible positions and all flag/string
// combinations. Unknown/custom records must survive a write byte for byte.
const fixture = "\x04\x01\x06\x00" ++
    "00000013\x00\x01\x07\x01" ++
    "534c3037\x00\x01\x2a\x06" ++ "0.1.8\x00custom\x00" ++
    "DEADBEEF\x00\x01\x1e\x04" ++ "extra\x00" ++
    "00000004\x00\x02\x02\x00" ++
    "00000002\x00\x03\x00\x80" ++
    "00000009\x00\x02\x08\x02" ++ "1.0\x00";

test "menu CLI accepts app aliases and hex IDs, and validates positions before Bluetooth" {
    try std.testing.expectEqual(Command.list, try parse(&.{"list"}));
    try std.testing.expectEqualDeep(Command{ .move = .{ .id = app_install.app_id, .position = 1 } }, try parse(&.{ "move", "sleep-today", "1" }));
    try std.testing.expectEqualDeep(Command{ .up = app_install.app_id }, try parse(&.{ "up", "534c3037" }));
    try std.testing.expectEqualDeep(Command{ .down = 0xdeadbeef }, try parse(&.{ "down", "DEADBEEF" }));
    try std.testing.expectEqualDeep(Command{ .move = .{ .id = 4, .position = 256 } }, try parse(&.{ "move", "weather", "256" }));
    try std.testing.expectError(error.InvalidMenuArguments, parse(&.{}));
    try std.testing.expectError(error.InvalidMenuArguments, parse(&.{ "list", "weather" }));
    try std.testing.expectError(error.InvalidMenuArguments, parse(&.{ "up", "sleep-today", "1" }));
    try std.testing.expectError(error.InvalidMenuApp, parse(&.{ "up", "not-an-app" }));
    try std.testing.expectError(error.InvalidMenuApp, parse(&.{ "up", "0x534c3037" }));
    inline for (.{ "0", "257", "-1", "+1", "1x", "" }) |position| {
        try std.testing.expectError(error.InvalidMenuPosition, parse(&.{ "move", "sleep-today", position }));
    }
}

test "moving a custom app preserves all metadata, hidden entries, other sections and position gaps" {
    const a = std.testing.allocator;
    const before = try decode(a, fixture);
    defer before.deinit(a);
    const change = try plan(a, before, try parse(&.{ "move", "sleep-today", "1" }));
    const payload = change.payload.?;
    defer a.free(payload);
    try std.testing.expectEqual(@as(u8, 5), payload[0]);
    try std.testing.expectEqual(@as(usize, 1), change.position);
    for (before.items) |item| {
        const expected: u8 = switch (item.id) {
            app_install.app_id => 7,
            0x13 => 30,
            0xdeadbeef => 42,
            else => item.position,
        };
        try std.testing.expectEqual(expected, payload[item.start + 10]);
        try std.testing.expectEqualSlices(u8, before.bytes[item.start .. item.start + 10], payload[item.start .. item.start + 10]);
        try std.testing.expectEqualSlices(u8, before.bytes[item.start + 11 .. item.end], payload[item.start + 11 .. item.end]);
    }
    // A symmetric move down restores the original menu payload.
    const response = try a.dupe(u8, payload);
    defer a.free(response);
    response[0] = 4;
    const moved = try decode(a, response);
    defer moved.deinit(a);
    const restored = (try plan(a, moved, try parse(&.{ "move", "sleep-today", "3" }))).payload.?;
    defer a.free(restored);
    try std.testing.expectEqualSlices(u8, fixture[1..], restored[1..]);

    const more = (try plan(a, before, try parse(&.{ "up", "alarm" }))).payload.?;
    defer a.free(more);
    try std.testing.expectEqual(@as(u8, 2), more[before.find(9).?.start + 10]);
    try std.testing.expectEqual(@as(u8, 8), more[before.find(4).?.start + 10]);
    for (before.items) |item| if (item.section != .more) {
        try std.testing.expectEqualSlices(u8, before.bytes[item.start..item.end], more[item.start..item.end]);
    };
}

test "invalid, truncated, duplicate and unknown-section menu records are rejected" {
    const a = std.testing.allocator;
    inline for (.{ "", "\x04", "\x04\x01\x01\x00", "\x04\x02\x00\x00", "\x04\x01\x00\x00x" }) |bytes| {
        try std.testing.expectError(error.InvalidMenuResponse, decode(a, bytes));
    }
    const invalid = [_][]const u8{
        "\x04\x01\x01\x00" ++ "activity\x00\x01\x00\x00", // Not a hex ID.
        "\x04\x01\x01\x00" ++ "00000013x\x01\x00\x00", // Missing ID terminator.
        "\x04\x01\x01\x00" ++ "00000013\x00\x04\x00\x00", // Unknown section.
        "\x04\x01\x01\x00" ++ "00000013\x00\x01\x00\x02" ++ "unterminated",
        "\x04\x01\x01\x00" ++ "00000013\x00\x01\x00\x06" ++ "one\x00", // Missing second string.
        "\x04\x01\x02\x00" ++ "00000013\x00\x01\x00\x00" ++ "00000013\x00\x02\x01\x00", // Duplicate ID.
        "\x04\x01\x02\x00" ++ "00000013\x00\x01\x00\x00" ++ "00000004\x00\x01\x00\x00", // Duplicate visible position.
    };
    for (invalid) |bytes| try std.testing.expectError(error.InvalidMenuResponse, decode(a, bytes));
    // Removing any suffix of a valid nonempty frame cannot produce a valid frame.
    for (4..fixture.len) |end| try std.testing.expectError(error.InvalidMenuResponse, decode(a, fixture[0..end]));
}

const Fake = struct {
    buffer: [1024]u8 = undefined,
    saved: [1024]u8 = undefined,
    saved_length: usize = 0,
    requests: usize = 0,
    writes: usize = 0,
    fail_ack: bool = false,
    ack_status: u8 = 1,
    fail_readback: bool = false,
    tamper: bool = false,

    pub fn send(self: *@This(), bytes: []const u8) !void {
        if (bytes[0] == 3) {
            try std.testing.expectEqualSlices(u8, &.{ 3, 1 }, bytes);
            self.requests += 1;
        } else {
            try std.testing.expectEqual(@as(u8, 5), bytes[0]);
            self.writes += 1;
            @memcpy(self.saved[0..bytes.len], bytes);
            self.saved[0] = 4;
            self.saved_length = bytes.len;
        }
    }

    pub fn receive(self: *@This(), command: u8) ![]const u8 {
        if (command == 6) {
            if (self.fail_ack) return error.BandResponseTimedOut;
            self.buffer[0..3].* = .{ 6, 1, self.ack_status };
            return self.buffer[0..3];
        }
        try std.testing.expectEqual(@as(u8, 4), command);
        if (self.writes > 0 and self.fail_readback) return error.BandResponseTimedOut;
        const source = if (self.writes == 0) fixture else self.saved[0..self.saved_length];
        @memcpy(self.buffer[0..source.len], source);
        if (self.writes > 0 and self.tamper) self.buffer[15] ^= 0x80; // Settings flags changed.
        return self.buffer[0..source.len];
    }
};

test "menu move sends a single update and verifies every entry through a shared receive buffer" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try execute(a, &fake, try parse(&.{ "move", "sleep-today", "1" }), &out.writer);
    try std.testing.expectEqual(@as(usize, 1), fake.writes);
    try std.testing.expectEqual(@as(usize, 2), fake.requests);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "position 1; verified on the band.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  1  534C3037  Sleep today") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Hidden:") != null);
}

test "listing, already-positioned and boundary moves send no update" {
    const a = std.testing.allocator;
    const commands = [_]Command{
        .list,
        .{ .move = .{ .id = app_install.app_id, .position = 3 } },
        .{ .up = 0x13 },
        .{ .down = app_install.app_id },
    };
    for (commands) |command| {
        var fake: Fake = .{};
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try execute(a, &fake, command, &out.writer);
        try std.testing.expectEqual(@as(usize, 0), fake.writes);
        try std.testing.expectEqual(@as(usize, 1), fake.requests);
    }
}

test "missing, hidden and out-of-range apps fail before any menu write" {
    const a = std.testing.allocator;
    const cases = .{
        .{ Command{ .up = 0x12345678 }, error.MenuAppNotFound },
        .{ Command{ .up = 2 }, error.MenuAppHidden },
        .{ Command{ .move = .{ .id = app_install.app_id, .position = 4 } }, error.InvalidMenuPosition },
    };
    inline for (cases) |case| {
        var fake: Fake = .{};
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try std.testing.expectError(case[1], execute(a, &fake, case[0], &out.writer));
        try std.testing.expectEqual(@as(usize, 0), fake.writes);
    }
}

test "ack timeouts, rejection, readback timeouts and unrelated changes never replay a menu write" {
    const a = std.testing.allocator;
    const before = try decode(a, fixture);
    defer before.deinit(a);
    const change = try plan(a, before, .{ .up = app_install.app_id });
    defer a.free(change.payload.?);
    const cases = .{
        .{ Fake{ .fail_ack = true }, error.BandResponseTimedOut },
        .{ Fake{ .ack_status = 0 }, error.MenuChangeRejected },
        .{ Fake{ .fail_readback = true }, error.BandResponseTimedOut },
        .{ Fake{ .tamper = true }, error.MenuChangeNotVerified },
    };
    inline for (cases) |case| {
        var fake = case[0];
        try std.testing.expectError(case[1], apply(a, &fake, before, change.payload.?));
        try std.testing.expectEqual(@as(usize, 1), fake.writes);
    }
}

test "readback verification follows stable IDs rather than wire record order" {
    const a = std.testing.allocator;
    const before = try decode(a, fixture);
    defer before.deinit(a);
    const payload = (try plan(a, before, .{ .up = app_install.app_id })).payload.?;
    defer a.free(payload);
    const reversed = try a.alloc(u8, payload.len);
    defer a.free(reversed);
    @memcpy(reversed[0..4], fixture[0..4]);
    var at: usize = 4;
    var index = before.items.len;
    while (index > 0) {
        index -= 1;
        const item = before.items[index];
        const bytes = payload[item.start..item.end];
        @memcpy(reversed[at..][0..bytes.len], bytes);
        at += bytes.len;
    }
    const after = try decode(a, reversed);
    defer after.deinit(a);
    try verify(before, payload, after);
}
