//! Zepp OS notification payloads and capability negotiation.
const std = @import("std");
pub const max_message_bytes = 506;

pub fn validate(message: []const u8) !void {
    if (message.len == 0) return error.EmptyNotification;
    if (message.len > max_message_bytes) return error.NotificationTooLong;
    if (std.mem.indexOfScalar(u8, message, 0) != null) return error.InvalidNotificationText;
    if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidNotificationText;
}

pub const Capabilities = struct {
    version: u8,
    pictures: bool = false,
    notification_key: bool = false,
    pub fn parse(data: []const u8) !Capabilities {
        if (data.len < 2 or data[0] != 2 or data[1] < 3 or data[1] > 5) return error.UnsupportedNotificationProtocol;
        if (data[1] < 4) return .{ .version = data[1] };
        if (data.len < 8) return error.InvalidNotificationCapabilities;
        const count = std.mem.readInt(u16, data[6..8], .little);
        const end = 8 + @as(usize, count);
        if (end > data.len) return error.InvalidNotificationCapabilities;
        var result: Capabilities = .{ .version = data[1] };
        if (result.version == 5) {
            if (data.len < end + 2) return error.InvalidNotificationCapabilities;
            result.pictures = data[end] != 0;
            result.notification_key = data[end + 1] != 0;
        }
        return result;
    }
};

pub fn encodeAuthenticated(a: std.mem.Allocator, text: []const u8, caps: Capabilities, id: u32) ![]u8 {
    try validate(text);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    try bytes.append(a, 3);
    var encoded_id: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded_id, id, .little);
    try bytes.appendSlice(a, &encoded_id);
    try bytes.appendSlice(a, "\xfa\x00org.zig.smartband\x00PC\x00");
    try bytes.appendSlice(a, text);
    try bytes.appendSlice(a, "\x00Desktop\x00\x00");
    if (caps.version >= 5) try bytes.append(a, 0);
    if (caps.pictures) try bytes.append(a, 0);
    if (caps.notification_key) try bytes.append(a, 0);
    return bytes.toOwnedSlice(a);
}

test "authenticated notification capabilities and UTF-8 packet" {
    const caps = try Capabilities.parse(&.{ 2, 5, 100, 0, 1, 1, 0, 0, 1, 1 });
    try std.testing.expect(caps.pictures and caps.notification_key);
    try std.testing.expectError(error.InvalidNotificationCapabilities, Capabilities.parse(&.{ 2, 5, 0, 0, 0, 0, 255, 255 }));
    const data = try encodeAuthenticated(std.testing.allocator, "Готово", caps, 0x12345678);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualSlices(u8, "\x03\x78\x56\x34\x12\xfa\x00org.zig.smartband\x00PC\x00Готово\x00Desktop\x00\x00\x00\x00\x00", data);
}

test "notification input validation and version boundaries" {
    try std.testing.expectError(error.EmptyNotification, validate(""));
    try std.testing.expectError(error.InvalidNotificationText, validate("bad\x00text"));
    try std.testing.expectError(error.InvalidNotificationText, validate("\xff"));
    const long: [507]u8 = @splat('x');
    try std.testing.expectError(error.NotificationTooLong, validate(&long));
    const caps = try Capabilities.parse(&.{ 2, 3 });
    try std.testing.expectEqual(@as(u8, 3), caps.version);
    try std.testing.expectError(error.UnsupportedNotificationProtocol, Capabilities.parse(&.{ 2, 9 }));
}
