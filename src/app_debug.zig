//! Filter a bounded diagnostic capture to this project's own app only.
const std = @import("std");
const app_install = @import("app_install.zig");
const marker = "SLEEP_TODAY_DIAG ";

pub fn textFragment(message: []const u8, session: u8) ?[]const u8 {
    if (message.len < 4 or message[0] != 7 or message[2] != session) return null;
    const app_end = std.mem.indexOfScalarPos(u8, message, 3, 0) orelse return null;
    const decimal_id = std.fmt.parseInt(u32, message[3..app_end], 10) catch 0;
    const hexadecimal_id = std.fmt.parseInt(u32, message[3..app_end], 16) catch 0;
    if ((decimal_id != app_install.app_id and hexadecimal_id != app_install.app_id) or message.len - app_end < 12) return null;
    // NUL after the app ID, one reserved byte, timestamp u64, log level.
    const text_start = app_end + 11;
    const text_end = std.mem.indexOfScalarPos(u8, message, text_start, 0) orelse message.len;
    return message[text_start..text_end];
}

pub fn payload(message: []const u8, session: u8) ?[]const u8 {
    const text = textFragment(message, session) orelse return null;
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const json = std.mem.trim(u8, text[start + marker.len ..], " \t\r\n");
    if (json.len == 0 or json.len > 8192 or json[0] != '{' or json[json.len - 1] != '}') return null;
    return json;
}

pub const Assembler = struct {
    buffer: [8192]u8 = undefined,
    used: usize = 0,
    active: bool = false,
    id: [32]u8 = undefined,
    id_length: usize = 0,
    next_part: usize = 0,
    part_count: usize = 0,

    pub fn push(self: *Assembler, message: []const u8, session: u8) !?[]const u8 {
        const text = textFragment(message, session) orelse return null;
        var fragment = text;
        if (std.mem.indexOf(u8, text, "STDIAG ")) |start| {
            // HmLogger adds a separator space to every logged argument. Our
            // canonical diagnostic JSON has no whitespace at chunk boundaries.
            const record = std.mem.trimEnd(u8, text[start + 7 ..], " \t\r\n");
            const id_end = std.mem.indexOfScalar(u8, record, ' ') orelse return null;
            if (id_end == 0 or id_end > self.id.len) return null;
            const part_end = std.mem.indexOfScalarPos(u8, record, id_end + 1, ' ') orelse return null;
            const slash = std.mem.indexOfScalarPos(u8, record, id_end + 1, '/') orelse return null;
            if (slash >= part_end) return null;
            const part = std.fmt.parseInt(usize, record[id_end + 1 .. slash], 10) catch return null;
            const count = std.fmt.parseInt(usize, record[slash + 1 .. part_end], 10) catch return null;
            if (count == 0 or count > 128 or part >= count) return null;
            if (part == 0) {
                @memcpy(self.id[0..id_end], record[0..id_end]);
                self.id_length = id_end;
                self.used = 0;
                self.next_part = 0;
                self.part_count = count;
                self.active = true;
            }
            if (!self.active or !std.mem.eql(u8, self.id[0..self.id_length], record[0..id_end]) or
                self.next_part != part or self.part_count != count)
            {
                self.active = false;
                return null;
            }
            self.next_part += 1;
            fragment = record[part_end + 1 ..];
        } else if (std.mem.indexOf(u8, text, marker)) |start| {
            self.used = 0;
            self.active = true;
            self.part_count = 0;
            fragment = text[start + marker.len ..];
        } else if (!self.active or self.part_count != 0) return null;
        if (fragment.len > self.buffer.len - self.used) return error.AppDiagnosticTooLarge;
        @memcpy(self.buffer[self.used..][0..fragment.len], fragment);
        self.used += fragment.len;
        if (self.part_count != 0 and self.next_part != self.part_count) return null;
        const json = std.mem.trim(u8, self.buffer[0..self.used], " \t\r\n");
        if (json.len == 0 or json[0] != '{') {
            self.active = false;
            return null;
        }
        if (json[json.len - 1] != '}') return null;
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        self.active = false;
        return json;
    }
};

test "diagnostic capture ignores other apps, sessions and ordinary messages" {
    const header = [_]u8{ 7, 0, 4 } ++ "1397502007\x00".* ++ @as([9]u8, @splat(0)) ++ .{2};
    const message = header ++ "SLEEP_TODAY_DIAG {\"version\":1}\x00".*;
    try std.testing.expectEqualStrings("{\"version\":1}", payload(&message, 4).?);
    try std.testing.expect(payload(&message, 5) == null);
    var other = message;
    other[3] = '2';
    try std.testing.expect(payload(&other, 4) == null);
    try std.testing.expect(payload(&(header ++ "Unrelated app log\x00".*), 4) == null);
    try std.testing.expect(payload(message[0..10], 4) == null);
}

test "native logger fragments are joined before JSON validation" {
    const header = [_]u8{ 7, 0, 4 } ++ "1397502007\x00".* ++ @as([9]u8, @splat(0)) ++ .{2};
    var capture: Assembler = .{};
    try std.testing.expect(try capture.push(&(header ++ "SLEEP_TODAY_DIAG {\"version\":1,\"stages\":[".*), 4) == null);
    try std.testing.expect(try capture.push(&(header ++ "[350,373,2],".*), 4) == null);
    const result = (try capture.push(&(header ++ "[374,400,3]]}\r\n".*), 4)).?;
    try std.testing.expectEqualStrings("{\"version\":1,\"stages\":[[350,373,2],[374,400,3]]}", result);
}

test "numbered diagnostic chunks survive log prefixes and reject missing parts" {
    const header = [_]u8{ 7, 0, 4 } ++ "1397502007\x00".* ++ @as([9]u8, @splat(0)) ++ .{2};
    var capture: Assembler = .{};
    try std.testing.expect(try capture.push(&(header ++ "[logger] STDIAG 123-1 0/2 {\"version\": \r\n".*), 4) == null);
    try std.testing.expectEqualStrings("{\"version\":1}", (try capture.push(&(header ++ "[logger] STDIAG 123-1 1/2 1} \r\n".*), 4)).?);
    try std.testing.expect(try capture.push(&(header ++ "STDIAG 123-2 0/3 {\"version\":".*), 4) == null);
    try std.testing.expect(try capture.push(&(header ++ "STDIAG 123-2 2/3 1}".*), 4) == null);
}
