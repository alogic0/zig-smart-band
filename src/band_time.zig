//! Zepp OS Current Time characteristic: local calendar, Sunday=0, UTC quarters.
//! Wire reference: Gadgetbridge ZeppOsSupport.setCurrentTimeWithService.
const std = @import("std");
const bluez = @import("bluez.zig");
const dbus = @import("dbus.zig");
const Io = std.Io;
pub const characteristic_uuid = "00002a2b-0000-1000-8000-00805f9b34fb";

// Linux libc struct tm, including the tm_gmtoff and tm_zone extensions.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn time(timer: ?*std.c.time_t) std.c.time_t;
extern "c" fn tzset() void;
extern "c" fn localtime_r(timer: *const std.c.time_t, result: *Tm) ?*Tm;
extern "c" fn mktime(tm: *Tm) std.c.time_t;

pub const Calendar = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8,
    utc_quarters: i8,

    fn validate(self: Calendar) !void {
        if (self.year < 1582 or self.year > 9999 or self.month < 1 or self.month > 12 or
            self.day < 1 or self.day > daysInMonth(self.year, self.month) or
            self.hour > 23 or self.minute > 59 or self.second > 59 or self.weekday > 6 or
            self.utc_quarters < -48 or self.utc_quarters > 56) return error.InvalidBandTime;
    }
    pub fn encode(self: Calendar) ![11]u8 {
        try self.validate();
        var bytes: [11]u8 = .{ 0, 0, self.month, self.day, self.hour, self.minute, self.second, self.weekday, 0, 8, @bitCast(self.utc_quarters) };
        std.mem.writeInt(u16, bytes[0..2], self.year, .little);
        return bytes;
    }
    pub fn decode(bytes: []const u8, fallback_offset: i8) !Calendar {
        if (bytes.len != 10 and bytes.len != 11) return error.InvalidBandTime;
        const result: Calendar = .{
            .year = std.mem.readInt(u16, bytes[0..2], .little),
            .month = bytes[2],
            .day = bytes[3],
            .hour = bytes[4],
            .minute = bytes[5],
            .second = bytes[6],
            .weekday = bytes[7],
            .utc_quarters = if (bytes.len == 11) @bitCast(bytes[10]) else fallback_offset,
        };
        try result.validate();
        return result;
    }
    pub fn unixSeconds(self: Calendar) !i64 {
        try self.validate();
        var days = 365 * (@as(i64, self.year) - 1970) + leapYearsBefore(self.year) - leapYearsBefore(1970);
        var month: u8 = 1;
        while (month < self.month) : (month += 1) days += daysInMonth(self.year, month);
        days += self.day - 1;
        return days * 86400 + @as(i64, self.hour) * 3600 + @as(i64, self.minute) * 60 + self.second - @as(i64, self.utc_quarters) * 900;
    }
    pub fn print(self: Calendar, out: *Io.Writer) !void {
        const minutes: u16 = @as(u16, @intCast(@abs(@as(i16, self.utc_quarters)))) * 15;
        try out.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC{s}{d:0>2}:{d:0>2}", .{
            self.year,                               self.month,   self.day,     self.hour, self.minute, self.second,
            if (self.utc_quarters < 0) "-" else "+", minutes / 60, minutes % 60,
        });
    }
};

fn leapYearsBefore(year: u16) i64 {
    const y = @as(i64, year) - 1;
    return @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
}
fn daysInMonth(year: u16, month: u8) u8 {
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    return if (month == 2 and leap) 29 else days[month - 1];
}

pub fn localNow() !Calendar {
    const seconds = time(null);
    if (seconds == -1) return error.SystemClockUnavailable;
    return localAt(@intCast(seconds));
}

pub fn localAt(timestamp: i64) !Calendar {
    tzset();
    const seconds: std.c.time_t = @intCast(timestamp);
    var tm: Tm = undefined;
    if (localtime_r(&seconds, &tm) == null) return error.SystemClockUnavailable;
    if (tm.year < -318 or tm.year > 8099 or tm.mon < 0 or tm.mon > 11 or
        tm.mday < 1 or tm.mday > 31 or tm.hour < 0 or tm.hour > 23 or
        tm.min < 0 or tm.min > 59 or tm.sec < 0 or tm.sec > 59 or tm.wday < 0 or tm.wday > 6 or
        @rem(tm.gmtoff, 900) != 0 or tm.gmtoff < -43200 or tm.gmtoff > 50400) return error.UnsupportedLocalTime;
    const result: Calendar = .{
        .year = @intCast(tm.year + 1900),
        .month = @intCast(tm.mon + 1),
        .day = @intCast(tm.mday),
        .hour = @intCast(tm.hour),
        .minute = @intCast(tm.min),
        .second = @intCast(tm.sec),
        .weekday = @intCast(tm.wday),
        .utc_quarters = @intCast(@divExact(tm.gmtoff, 900)),
    };
    try result.validate();
    return result;
}

pub fn localDate(year: u16, month: u8, day: u8) !Calendar {
    const candidate: Calendar = .{ .year = year, .month = month, .day = day, .hour = 0, .minute = 0, .second = 0, .weekday = 0, .utc_quarters = 0 };
    try candidate.validate();
    return normalizedLocalDate(year, month, day);
}

/// Advance the calendar date, allowing libc to resolve the next midnight's DST.
pub fn nextLocalDate(date: Calendar) !Calendar {
    try date.validate();
    return normalizedLocalDate(date.year, date.month, date.day + 1);
}

fn normalizedLocalDate(year: u16, month: u8, day: u8) !Calendar {
    tzset();
    var tm = std.mem.zeroes(Tm);
    tm.year = @as(c_int, year) - 1900;
    tm.mon = @as(c_int, month) - 1;
    tm.mday = day;
    tm.isdst = -1;
    const seconds = mktime(&tm);
    if (seconds == -1) return error.SystemClockUnavailable;
    return localAt(@intCast(seconds));
}

pub fn localDaysAgo(days: u8) !Calendar {
    tzset();
    const seconds = time(null);
    var tm: Tm = undefined;
    if (seconds == -1 or localtime_r(&seconds, &tm) == null) return error.SystemClockUnavailable;
    tm.mday -= days;
    tm.hour = 0;
    tm.min = 0;
    tm.sec = 0;
    tm.isdst = -1;
    const result = mktime(&tm);
    if (result == -1) return error.SystemClockUnavailable;
    return localAt(@intCast(result));
}

pub fn sync(a: std.mem.Allocator, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, out: *Io.Writer) !void {
    const node = bluez.findCharacteristic(nodes, device.path, characteristic_uuid) orelse return error.TimeServiceUnavailable;
    if (!node.writable or !node.readable) return error.TimeServiceUnavailable;
    // Sample only after connection/authentication; discovery can take minutes.
    const target = try localNow();
    const packet = try target.encode();
    try out.writeAll("Synchronizing band to ");
    try target.print(out);
    try out.writeAll("...\n");
    try out.flush();
    var reply = try connection.call(node.path, "org.bluez.GattCharacteristic1", "WriteValue", .{
        .write_bytes = &packet,
        .dictionary_string = .{ .key = "type", .value = "request" },
        .timeout_us = 15_000_000,
    });
    reply.deinit();
    verify(a, io, connection, node, target.utc_quarters, out) catch |err| {
        std.debug.print("Time write completed, but read-back verification failed; the write was not repeated.\n", .{});
        return err;
    };
}

fn verify(a: std.mem.Allocator, io: Io, connection: *dbus.Connection, node: bluez.Node, offset: i8, out: *Io.Writer) !void {
    _ = io;
    var reply = try connection.call(node.path, "org.bluez.GattCharacteristic1", "ReadValue", .{ .empty_dict = true });
    defer reply.deinit();
    const bytes = try reply.bytes(a);
    defer a.free(bytes);
    const actual = try Calendar.decode(bytes, offset);
    const now = time(null);
    if (now == -1) return error.SystemClockUnavailable;
    try verifyClock(actual, @as(i64, now), offset);
    try out.writeAll("Band time verified: ");
    try actual.print(out);
    try out.writeAll(if (bytes.len == 10) " (clock read back; UTC offset supplied by sync)\n" else "\n");
}

fn verifyClock(actual: Calendar, now: i64, offset: i8) !void {
    if (@abs(try actual.unixSeconds() - now) > 5 or actual.utc_quarters != offset) return error.TimeVerificationFailed;
}

test "next local date crosses leap days and year boundaries at midnight" {
    const leap = try nextLocalDate(try localDate(2024, 2, 28));
    try std.testing.expectEqual(@as(u8, 29), leap.day);
    const march = try nextLocalDate(leap);
    try std.testing.expectEqual(@as(u8, 3), march.month);
    try std.testing.expectEqual(@as(u8, 1), march.day);
    const new_year = try nextLocalDate(try localDate(2026, 12, 31));
    try std.testing.expectEqual(@as(u16, 2027), new_year.year);
    try std.testing.expectEqual(@as(u8, 1), new_year.month);
    try std.testing.expectEqual(@as(u8, 1), new_year.day);
    try std.testing.expectEqual(@as(u8, 0), new_year.hour);
}

test "Zepp time encodes local date, Sunday-zero weekday, and signed UTC quarters" {
    const sample: Calendar = .{ .year = 2026, .month = 11, .day = 2, .hour = 16, .minute = 49, .second = 59, .weekday = 1, .utc_quarters = -24 };
    const bytes = try sample.encode();
    try std.testing.expectEqualSlices(u8, &.{ 0xea, 7, 11, 2, 16, 49, 59, 1, 0, 8, 0xe8 }, &bytes);
    const read = try Calendar.decode(&bytes, 0);
    try std.testing.expectEqual(sample, read);
    try std.testing.expectEqual(sample, try Calendar.decode(bytes[0..10], -24));
}

test "time verification handles fractional offsets and date boundaries" {
    const nepal: Calendar = .{ .year = 1970, .month = 1, .day = 1, .hour = 5, .minute = 45, .second = 0, .weekday = 4, .utc_quarters = 23 };
    try std.testing.expectEqual(@as(i64, 0), try nepal.unixSeconds());
    const west: Calendar = .{ .year = 1969, .month = 12, .day = 31, .hour = 20, .minute = 30, .second = 0, .weekday = 3, .utc_quarters = -14 };
    try std.testing.expectEqual(@as(i64, 0), try west.unixSeconds());
    var leap = nepal;
    leap.year = 2024;
    leap.month = 2;
    leap.day = 29;
    _ = try leap.encode();
    leap.year = 2023;
    try std.testing.expectError(error.InvalidBandTime, leap.encode());
    leap.month = 13;
    try std.testing.expectError(error.InvalidBandTime, leap.encode());
    try std.testing.expectError(error.InvalidBandTime, Calendar.decode(&.{ 1, 2, 3 }, 0));
}

test "clock read-back rejects drift and a different UTC offset" {
    var actual: Calendar = .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 5, .weekday = 4, .utc_quarters = 0 };
    try verifyClock(actual, 0, 0);
    actual.second = 6;
    try std.testing.expectError(error.TimeVerificationFailed, verifyClock(actual, 0, 0));
    actual.second = 0;
    actual.hour = 1;
    actual.utc_quarters = 4;
    try std.testing.expectEqual(@as(i64, 0), try actual.unixSeconds());
    try std.testing.expectError(error.TimeVerificationFailed, verifyClock(actual, 0, 0));
}

test "native local-time conversion agrees with the system epoch" {
    const calendar = try localNow();
    const seconds = time(null);
    try std.testing.expect(seconds != -1);
    try std.testing.expect(@abs(try calendar.unixSeconds() - @as(i64, seconds)) <= 2);
}
