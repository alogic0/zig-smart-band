//! Mi Band 7 Zepp OS alarm service (endpoint 0x000f, ten slots).
//! Protocol reference: Gadgetbridge ZeppOsAlarmsService and model/Alarm.
const std = @import("std");
const Io = std.Io;
pub const slot_count = 10;
const enabled_flag: u8 = 4;

pub const Clock = struct { hour: u8, minute: u8 };
pub const Command = union(enum) {
    list,
    add: struct { clock: Clock, repeat: u8 = 0, enabled: bool = true },
    set: struct { position: u8, clock: Clock, repeat: ?u8 },
    enable: u8,
    disable: u8,
    delete: u8,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 0) return error.InvalidAlarmArguments;
    const verb = args[0];
    if (std.mem.eql(u8, verb, "list")) {
        if (args.len != 1) return error.InvalidAlarmArguments;
        return .list;
    }
    if (std.mem.eql(u8, verb, "add")) {
        if (args.len < 2 or args.len > 4) return error.InvalidAlarmArguments;
        var result: Command = .{ .add = .{ .clock = try parseClock(args[1]) } };
        var seen_repeat = false;
        var seen_disabled = false;
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--disabled")) {
                if (seen_disabled) return error.InvalidAlarmArguments;
                result.add.enabled = false;
                seen_disabled = true;
            } else {
                if (seen_repeat) return error.InvalidAlarmArguments;
                result.add.repeat = try parseRepeat(arg);
                seen_repeat = true;
            }
        }
        return result;
    }
    if (std.mem.eql(u8, verb, "set")) {
        if (args.len < 3 or args.len > 4) return error.InvalidAlarmArguments;
        return .{ .set = .{ .position = try parseId(args[1]), .clock = try parseClock(args[2]), .repeat = if (args.len == 4) try parseRepeat(args[3]) else null } };
    }
    if (args.len != 2) return error.InvalidAlarmArguments;
    const position = try parseId(args[1]);
    if (std.mem.eql(u8, verb, "enable")) return .{ .enable = position };
    if (std.mem.eql(u8, verb, "disable")) return .{ .disable = position };
    if (std.mem.eql(u8, verb, "delete")) return .{ .delete = position };
    return error.InvalidAlarmArguments;
}

fn parseId(text: []const u8) !u8 {
    if (text.len == 0) return error.InvalidAlarmId;
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidAlarmId;
    const id = std.fmt.parseInt(u8, text, 10) catch return error.InvalidAlarmId;
    if (id < 1 or id > slot_count) return error.InvalidAlarmId;
    return id - 1;
}
fn parseClock(text: []const u8) !Clock {
    if (text.len != 5 or text[2] != ':') return error.InvalidAlarmTime;
    for ([_]usize{ 0, 1, 3, 4 }) |index| if (!std.ascii.isDigit(text[index])) return error.InvalidAlarmTime;
    const hour = std.fmt.parseInt(u8, text[0..2], 10) catch return error.InvalidAlarmTime;
    const minute = std.fmt.parseInt(u8, text[3..5], 10) catch return error.InvalidAlarmTime;
    if (hour > 23 or minute > 59) return error.InvalidAlarmTime;
    return .{ .hour = hour, .minute = minute };
}
const day_names = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
pub fn parseRepeat(text: []const u8) !u8 {
    const names = [_][]const u8{ "once", "daily", "weekdays", "weekends" };
    const values = [_]u8{ 0, 127, 31, 96 };
    for (names, values) |name, value| if (std.ascii.eqlIgnoreCase(name, text)) return value;
    var days = std.mem.splitScalar(u8, text, ',');
    var mask: u8 = 0;
    while (days.next()) |name| {
        var found = false;
        for (day_names, 0..) |day, index| {
            if (std.ascii.eqlIgnoreCase(day, name)) {
                const bit: u8 = @as(u8, 1) << @intCast(index);
                if (mask & bit != 0) return error.InvalidAlarmRepeat;
                mask |= bit;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidAlarmRepeat;
    }
    return mask;
}

pub const Record = struct {
    flags: u8,
    position: u8,
    hour: u8,
    minute: u8,
    repeat: u8,
    pub fn enabled(self: Record) bool {
        return self.flags & enabled_flag != 0;
    }
    pub fn withEnabled(self: Record, state: bool) Record {
        var result = self;
        result.flags = if (state) self.flags | enabled_flag else self.flags & ~enabled_flag;
        return result;
    }
    pub fn encode(self: Record) [12]u8 {
        // CREATE is also the reference protocol's upsert for an existing position.
        return .{ 3, 1, self.flags, self.position, self.hour, self.minute, self.repeat, 0, 0, 0, 0, 0 };
    }
};

pub const List = struct {
    records: [slot_count]Record = undefined,
    len: usize = 0,
    pub fn find(self: List, position: u8) ?Record {
        for (self.records[0..self.len]) |record| if (record.position == position) return record;
        return null;
    }
    pub fn firstFree(self: List) !u8 {
        for (0..slot_count) |index| if (self.find(@intCast(index)) == null) return @intCast(index);
        return error.AlarmSlotsFull;
    }
    pub fn print(self: List, out: *Io.Writer) !void {
        if (self.len == 0) return out.writeAll("No alarms configured.\n");
        try out.writeAll("ID  State  Time   Repeat\n");
        for (0..slot_count) |index| {
            if (self.find(@intCast(index))) |record| {
                try out.print("{d: >2}  {s: <5}  {d:0>2}:{d:0>2}  ", .{ record.position + 1, if (record.enabled()) "on" else "off", record.hour, record.minute });
                try printRepeat(record.repeat & 0x7f, out);
                if (record.flags & 1 != 0) try out.writeAll(" (smart wake)");
                try out.writeAll("\n");
            }
        }
    }
};

fn printRepeat(mask: u8, out: *Io.Writer) !void {
    switch (mask) {
        0 => return out.writeAll("once"),
        127 => return out.writeAll("daily"),
        31 => return out.writeAll("weekdays"),
        96 => return out.writeAll("weekends"),
        else => {},
    }
    var separator = false;
    for (day_names, 0..) |name, index| {
        if (mask & (@as(u8, 1) << @intCast(index)) != 0) {
            if (separator) try out.writeAll(",");
            try out.writeAll(name);
            separator = true;
        }
    }
}

pub fn decode(bytes: []const u8) !List {
    if (bytes.len < 2 or bytes[0] != 0x0a or bytes[1] > slot_count or bytes.len != 2 + @as(usize, bytes[1]) * 10) return error.InvalidAlarmList;
    var result: List = .{};
    for (0..bytes[1]) |index| {
        const record = bytes[2 + index * 10 ..][0..10];
        if (record[1] >= slot_count or record[2] > 23 or record[3] > 59 or result.find(record[1]) != null) return error.InvalidAlarmList;
        result.records[result.len] = .{ .flags = record[0], .position = record[1], .hour = record[2], .minute = record[3], .repeat = record[4] };
        result.len += 1;
    }
    return result;
}

pub const Change = union(enum) { put: Record, remove: u8 };
pub fn plan(before: List, command: Command) !Change {
    return switch (command) {
        .list => error.InvalidAlarmArguments,
        .add => |value| .{ .put = .{ .position = try before.firstFree(), .flags = if (value.enabled) enabled_flag else 0, .hour = value.clock.hour, .minute = value.clock.minute, .repeat = value.repeat } },
        .set => |value| blk: {
            var record = before.find(value.position) orelse return error.AlarmNotFound;
            record.hour = value.clock.hour;
            record.minute = value.clock.minute;
            if (value.repeat) |mask| record.repeat = mask;
            break :blk .{ .put = record };
        },
        .enable => |position| .{ .put = (before.find(position) orelse return error.AlarmNotFound).withEnabled(true) },
        .disable => |position| .{ .put = (before.find(position) orelse return error.AlarmNotFound).withEnabled(false) },
        .delete => |position| blk: {
            _ = before.find(position) orelse return error.AlarmNotFound;
            break :blk .{ .remove = position };
        },
    };
}

pub fn verifyChange(before: List, after: List, change: Change) !void {
    const position = switch (change) {
        .put => |record| record.position,
        .remove => |id| id,
    };
    switch (change) {
        .put => |expected| {
            const actual = after.find(position) orelse return error.AlarmChangeNotVerified;
            var normalized_expected = expected;
            var normalized_actual = actual;
            // Some Band 7 firmware reports bit 7 alongside the weekday mask.
            // Preserve it on existing records; permit device normalization after an edit.
            normalized_expected.repeat &= 0x7f;
            normalized_actual.repeat &= 0x7f;
            if (!std.meta.eql(normalized_expected, normalized_actual)) return error.AlarmChangeNotVerified;
        },
        .remove => if (after.find(position) != null) return error.AlarmChangeNotVerified,
    }
    for (before.records[0..before.len]) |old| {
        if (old.position == position) continue;
        if (!std.meta.eql(old, after.find(old.position) orelse return error.UnrelatedAlarmsChanged)) return error.UnrelatedAlarmsChanged;
    }
    for (after.records[0..after.len]) |record| {
        if (record.position != position and before.find(record.position) == null) return error.UnrelatedAlarmsChanged;
    }
}

fn read(transport: anytype) !List {
    try transport.send(&.{9});
    return decode(try transport.receive(0x0a));
}

pub fn execute(transport: anytype, command: Command, out: *Io.Writer) !void {
    const before = try read(transport);
    if (command == .list) return before.print(out);
    const change = try plan(before, command);
    mutate(transport, before, change) catch |err| {
        std.debug.print("Alarm change was not verified. It was not automatically repeated; run alarm list to check the band.\n", .{});
        return err;
    };
    const position = switch (change) {
        .put => |record| record.position,
        .remove => |id| id,
    };
    try out.print("Alarm {d} {s} (verified).\n", .{ position + 1, if (change == .remove) "deleted" else "saved" });
}

fn mutate(transport: anytype, before: List, change: Change) !void {
    switch (change) {
        .put => |record| try transport.send(&record.encode()),
        .remove => |position| try transport.send(&.{ 5, 1, position }),
    }
    const ack = try transport.receive(if (change == .put) 4 else 6);
    if (ack.len < 2) return error.InvalidAlarmAck;
    const after = try read(transport);
    try verifyChange(before, after, change);
}

test "alarm CLI validates IDs, clock times, repeat days and flags before Bluetooth" {
    const add = try parse(&.{ "add", "07:30", "mon,wed,fri", "--disabled" });
    try std.testing.expectEqual(@as(u8, 21), add.add.repeat);
    try std.testing.expect(!add.add.enabled);
    try std.testing.expectEqual(@as(u8, 9), (try parse(&.{ "enable", "10" })).enable);
    try std.testing.expect((try parse(&.{ "set", "1", "08:15" })).set.repeat == null);
    try std.testing.expectEqual(@as(u8, 96), try parseRepeat("WEEKENDS"));
    try std.testing.expectError(error.InvalidAlarmTime, parse(&.{ "add", "24:00" }));
    try std.testing.expectError(error.InvalidAlarmTime, parse(&.{ "add", "7:30" }));
    try std.testing.expectError(error.InvalidAlarmId, parse(&.{ "delete", "0" }));
    try std.testing.expectError(error.InvalidAlarmId, parse(&.{ "delete", "11" }));
    try std.testing.expectError(error.InvalidAlarmRepeat, parseRepeat("mon,mon"));
    try std.testing.expectError(error.InvalidAlarmRepeat, parseRepeat("mon,"));
    try std.testing.expectError(error.InvalidAlarmArguments, parse(&.{"enable"}));
}

test "alarm list validates lengths, positions and duplicates" {
    const bytes = [_]u8{ 0x0a, 1, 5, 2, 7, 30, 31, 0, 0, 0, 1, 0 };
    const list = try decode(&bytes);
    const record = list.find(2).?;
    try std.testing.expect(record.enabled());
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 5, 2, 7, 30, 31, 0, 0, 0, 0, 0 }, &record.encode());
    try std.testing.expectError(error.InvalidAlarmList, decode(bytes[0..11]));
    var invalid = bytes;
    invalid[3] = 10;
    try std.testing.expectError(error.InvalidAlarmList, decode(&invalid));
    invalid = bytes;
    invalid[4] = 24;
    try std.testing.expectError(error.InvalidAlarmList, decode(&invalid));
    const duplicate = [_]u8{ 0x0a, 2 } ++ bytes[2..].* ++ bytes[2..].*;
    try std.testing.expectError(error.InvalidAlarmList, decode(&duplicate));
}

test "alarm plans select unused slots and preserve flags and repetition on edits" {
    var before = try decode(&.{ 0x0a, 1, 7, 0, 7, 30, 31, 0, 0, 0, 1, 0 });
    const added = try plan(before, try parse(&.{ "add", "09:00" }));
    try std.testing.expectEqual(@as(u8, 1), added.put.position);
    const disabled = try plan(before, .{ .disable = 0 });
    try std.testing.expectEqual(@as(u8, 3), disabled.put.flags);
    try std.testing.expectEqual(@as(u8, 31), disabled.put.repeat);
    const edit = try plan(before, try parse(&.{ "set", "1", "08:00" }));
    try std.testing.expectEqual(@as(u8, 7), edit.put.flags);
    try std.testing.expectEqual(@as(u8, 31), edit.put.repeat);
    try std.testing.expectError(error.AlarmNotFound, plan(before, .{ .delete = 9 }));
    for (0..slot_count) |index| before.records[index] = .{ .flags = 0, .position = @intCast(index), .hour = 0, .minute = 0, .repeat = 0 };
    before.len = slot_count;
    try std.testing.expectError(error.AlarmSlotsFull, before.firstFree());
}

test "alarm read-back detects changed unrelated alarms and unsuccessful writes" {
    const before = try decode(&.{ 0x0a, 1, 4, 0, 7, 30, 31, 0, 0, 0, 1, 0 });
    const change = try plan(before, .{ .disable = 0 });
    try std.testing.expectError(error.AlarmChangeNotVerified, verifyChange(before, before, change));
    var after = before;
    after.records[0] = change.put;
    try verifyChange(before, after, change);
    after.records[1] = .{ .flags = 4, .position = 1, .hour = 9, .minute = 0, .repeat = 0 };
    after.len = 2;
    try std.testing.expectError(error.UnrelatedAlarmsChanged, verifyChange(before, after, change));
    try verifyChange(before, .{}, .{ .remove = 0 });
}

test "uncertain alarm write is never replayed" {
    const Fake = struct {
        writes: usize = 0,
        pub fn send(self: *@This(), bytes: []const u8) !void {
            if (bytes[0] == 3) self.writes += 1;
        }
        pub fn receive(_: *@This(), command: u8) ![]const u8 {
            if (command == 0x0a) return &.{ 0x0a, 0 };
            return error.BandResponseTimedOut;
        }
    };
    var fake: Fake = .{};
    const change = try plan(.{}, try parse(&.{ "add", "09:00" }));
    try std.testing.expectError(error.BandResponseTimedOut, mutate(&fake, .{}, change));
    try std.testing.expectEqual(@as(usize, 1), fake.writes);
}

test "firmware repeat flag is preserved by toggles and normalized for explicit schedules" {
    const before = try decode(&.{ 0x0a, 1, 0, 1, 18, 2, 255, 0, 0, 0, 1, 0 });
    const change = try plan(before, .{ .enable = 1 });
    try std.testing.expectEqual(@as(u8, 255), change.put.repeat);
    const edit = try plan(before, try parse(&.{ "set", "2", "19:00", "daily" }));
    var after = before;
    after.records[0] = edit.put;
    after.records[0].repeat = 255;
    try verifyChange(before, after, edit);
}

test "adding an alarm sends one unused slot and verifies the complete list" {
    const Fake = struct {
        sends: usize = 0,
        receives: usize = 0,
        pub fn send(self: *@This(), bytes: []const u8) !void {
            const expected: []const u8 = switch (self.sends) {
                0, 2 => &.{9},
                1 => &.{ 3, 1, 0, 1, 9, 0, 31, 0, 0, 0, 0, 0 },
                else => return error.UnexpectedWrite,
            };
            try std.testing.expectEqualSlices(u8, expected, bytes);
            self.sends += 1;
        }
        pub fn receive(self: *@This(), command: u8) ![]const u8 {
            self.receives += 1;
            switch (self.receives) {
                1 => {
                    try std.testing.expectEqual(@as(u8, 0x0a), command);
                    return &.{ 0x0a, 1, 7, 0, 7, 30, 255, 0, 0, 0, 1, 0 };
                },
                2 => {
                    try std.testing.expectEqual(@as(u8, 4), command);
                    return &.{ 4, 1 };
                },
                3 => {
                    try std.testing.expectEqual(@as(u8, 0x0a), command);
                    return &.{ 0x0a, 2, 7, 0, 7, 30, 255, 0, 0, 0, 1, 0, 0, 1, 9, 0, 159, 0, 0, 0, 1, 0 };
                },
                else => return error.UnexpectedRead,
            }
        }
    };
    var fake: Fake = .{};
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try execute(&fake, try parse(&.{ "add", "09:00", "weekdays", "--disabled" }), &output.writer);
    try std.testing.expectEqual(@as(usize, 3), fake.sends);
    try std.testing.expectEqual(@as(usize, 3), fake.receives);
}
