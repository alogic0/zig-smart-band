//! Huami 2021 framing and authenticated Zepp OS commands.
//! Wire-format reference: Gadgetbridge Huami2021 and Zepp OS services.
const std = @import("std");
const dbus = @import("dbus.zig");
const bluez = @import("bluez.zig");
const b163 = @import("b163.zig");
const notification = @import("notification.zig");
const band_time = @import("band_time.zig");
const alarms = @import("alarms.zig");
const weather = @import("weather.zig");
const sleep = @import("sleep.zig");
const Aes = std.crypto.core.aes.Aes128;
const Crc = std.hash.Crc32;
const Io = std.Io;
const write_uuid = "00000016-0000-3512-2118-0009af100700";
const read_uuid = "00000017-0000-3512-2118-0009af100700";
const limit = 16384;

fn write(connection: *dbus.Connection, node: bluez.Node, bytes: []const u8) !void {
    var reply = try connection.call(node.path, "org.bluez.GattCharacteristic1", "WriteValue", .{
        .write_bytes = bytes,
        .dictionary_string = .{ .key = "type", .value = if (node.write_without_response) "command" else "request" },
        .timeout_us = 15_000_000,
    });
    reply.deinit();
}

pub fn encrypt(key: [16]u8, bytes: []u8) void {
    const aes = Aes.initEnc(key);
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 16) aes.encrypt(bytes[offset..][0..16], bytes[offset..][0..16]);
}
fn decrypt(key: [16]u8, bytes: []u8) void {
    const aes = Aes.initDec(key);
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 16) aes.decrypt(bytes[offset..][0..16], bytes[offset..][0..16]);
}
fn messageKey(key: [16]u8, handle: u8) [16]u8 {
    var result = key;
    for (&result) |*byte| byte.* ^= handle;
    return result;
}
fn encryptedSize(length: usize) usize {
    return (length + 8 + 15) / 16 * 16;
}

const Message = struct { endpoint: u16, data: []const u8 };
pub const Decoder = struct {
    buffer: [limit]u8 = undefined,
    used: usize = 0,
    length: usize = 0,
    expected: usize = 0,
    endpoint: u16 = 0,
    handle: ?u8 = null,
    count: u8 = 0,
    encrypted: bool = false,
    last_sequence: ?u32 = null,

    pub fn push(self: *Decoder, packet: []const u8, key: ?[16]u8) !?Message {
        if (packet.len == 0) return error.InvalidChunk;
        if (packet[0] == 4) return null; // transport acknowledgment
        if (packet.len < 5 or packet[0] != 3 or packet[2] != 0) return error.InvalidChunk;
        const first = packet[1] & 1 != 0;
        const encrypted = packet[1] & 8 != 0;
        const header: usize = if (first) 11 else 5;
        if (packet.len < header) return error.InvalidChunk;
        if (first) {
            if (self.handle != null or packet[4] != 0) return error.InvalidChunkOrder;
            self.length = std.mem.readInt(u32, packet[5..9], .little);
            if (self.length == 0 or self.length > limit - 32) return error.InvalidChunkLength;
            self.expected = if (encrypted) encryptedSize(self.length) else self.length;
            self.endpoint = std.mem.readInt(u16, packet[9..11], .little);
            self.handle = packet[3];
            self.count = 0;
            self.encrypted = encrypted;
            self.used = 0;
        }
        if (self.handle == null or self.handle.? != packet[3] or self.count != packet[4] or self.encrypted != encrypted) return error.InvalidChunkOrder;
        const data = packet[header..];
        if (data.len > self.expected - self.used) return error.InvalidChunkLength;
        @memcpy(self.buffer[self.used..][0..data.len], data);
        self.used += data.len;
        if (packet[1] & 2 == 0) {
            if (self.count == 255 or self.used == self.expected) return error.InvalidChunkOrder;
            self.count += 1;
            return null;
        }
        if (self.used != self.expected) return error.InvalidChunkLength;
        const handle = self.handle.?;
        self.handle = null;
        if (encrypted) {
            decrypt(messageKey(key orelse return error.AuthenticationRequired, handle), self.buffer[0..self.used]);
            const crc = std.mem.readInt(u32, self.buffer[self.length + 4 ..][0..4], .little);
            if (Crc.hash(self.buffer[0 .. self.length + 4]) != crc) return error.InvalidPacketChecksum;
            const sequence = std.mem.readInt(u32, self.buffer[self.length..][0..4], .little);
            if (self.last_sequence) |previous| {
                if (sequence <= previous) return error.ReplayedPacket;
            }
            self.last_sequence = sequence;
        }
        return .{ .endpoint = self.endpoint, .data = self.buffer[0..self.length] };
    }
};

const Session = struct {
    connection: *dbus.Connection,
    io: Io,
    writer: bluez.Node,
    reader: bluez.Node,
    receiver: *dbus.Receiver,
    key: ?[16]u8 = null,
    sequence: u32 = 0,
    handle: u8 = 0,
    decoder: Decoder = .{},

    fn send(self: *Session, endpoint: u16, plain: []const u8, encrypted: bool) !void {
        if (plain.len == 0 or plain.len > limit - 32 or self.handle == 255) return error.MessageTooLarge;
        self.handle += 1;
        var buffer: [limit]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &buffer);
        @memcpy(buffer[0..plain.len], plain);
        const size = if (encrypted) encryptedSize(plain.len) else plain.len;
        if (encrypted) {
            if (self.sequence == std.math.maxInt(u32)) return error.SequenceExhausted;
            std.mem.writeInt(u32, buffer[plain.len..][0..4], self.sequence, .little);
            self.sequence += 1;
            std.mem.writeInt(u32, buffer[plain.len + 4 ..][0..4], Crc.hash(buffer[0 .. plain.len + 4]), .little);
            encrypt(messageKey(self.key orelse return error.AuthenticationRequired, self.handle), buffer[0..size]);
        }
        const mtu = @min(@max(self.writer.mtu, 23), 517);
        if (size > @as(usize, mtu - 14) + 255 * @as(usize, mtu - 8)) return error.MessageTooLarge;
        var offset: usize = 0;
        var count: u8 = 0;
        while (offset < size) {
            var packet: [514]u8 = undefined;
            const header: usize = if (offset == 0) 11 else 5;
            const take = @min(size - offset, mtu - 3 - header);
            const last = offset + take == size;
            packet[0] = 3;
            packet[1] = (if (encrypted) @as(u8, 8) else 0) | (if (offset == 0) @as(u8, 1) else 0) | (if (last) @as(u8, 6) else 0);
            packet[2] = 0;
            packet[3] = self.handle;
            packet[4] = count;
            if (offset == 0) {
                std.mem.writeInt(u32, packet[5..9], @intCast(plain.len), .little);
                std.mem.writeInt(u16, packet[9..11], endpoint, .little);
            }
            @memcpy(packet[header..][0..take], buffer[offset..][0..take]);
            try write(self.connection, self.writer, packet[0 .. header + take]);
            offset += take;
            if (!last) {
                if (count == 255) return error.MessageTooLarge;
                count += 1;
            }
        }
    }
    fn receive(self: *Session, endpoint: u16) ![]const u8 {
        return self.receiveMatching(endpoint, null);
    }

    fn receiveMatching(self: *Session, endpoint: u16, command: ?u8) ![]const u8 {
        const deadline = Io.Timestamp.now(self.io, .awake).addDuration(.fromSeconds(20));
        while (true) {
            const value = try self.next(deadline);
            if (value.endpoint == endpoint and (command == null or value.data[0] == command.?)) return value.data;
        }
    }

    fn next(self: *Session, deadline: Io.Timestamp) !Message {
        while (true) {
            const packet = try self.receiver.next(self.io, deadline);
            if (try self.processPacket(packet)) |value| return value;
        }
    }

    fn processPacket(self: *Session, packet: []const u8) !?Message {
        const message = try self.decoder.push(packet, self.key);
        if (packet.len >= 5 and packet[0] == 3 and packet[1] & 4 != 0) {
            try write(self.connection, self.reader, &.{ 4, 0, packet[3], 1, packet[4] });
        }
        if (message) |value| {
            // Keep the Zepp channel alive while legacy history characteristics stream.
            if (value.endpoint == 0x15 and value.data[0] == 3) {
                try self.send(0x15, &.{4}, false);
                return null;
            }
        }
        return message;
    }

    fn maintain(context: *anyopaque) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        while (try self.receiver.poll()) |packet| _ = try self.processPacket(packet);
    }
};

const Action = union(enum) {
    notification: struct { text: []const u8, wake_screen: ?bool },
    sync_time: *Io.Writer,
    alarm: struct { command: alarms.Command, out: *Io.Writer },
    weather: struct { data: weather.Data, out: *Io.Writer },
    sleep: struct { options: sleep.Options, out: *Io.Writer },
};

pub fn downloadSleep(a: std.mem.Allocator, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, secret: [16]u8, options: sleep.Options, out: *Io.Writer) !void {
    try run(a, io, connection, nodes, device, secret, .{ .sleep = .{ .options = options, .out = out } });
}

pub fn updateWeather(a: std.mem.Allocator, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, secret: [16]u8, data: weather.Data, out: *Io.Writer) !void {
    try run(a, io, connection, nodes, device, secret, .{ .weather = .{ .data = data, .out = out } });
}

const WeatherTransport = struct {
    session: *Session,
    encrypted_http: bool,
    pub fn send(self: *@This(), endpoint: u16, bytes: []const u8) !void {
        try self.session.send(endpoint, bytes, if (endpoint == 1) self.encrypted_http else false);
    }
    pub fn next(self: *@This(), deadline: Io.Timestamp) !Message {
        return self.session.next(deadline);
    }
};

pub fn manageAlarms(a: std.mem.Allocator, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, secret: [16]u8, command: alarms.Command, out: *Io.Writer) !void {
    try run(a, io, connection, nodes, device, secret, .{ .alarm = .{ .command = command, .out = out } });
}

const AlarmTransport = struct {
    session: *Session,
    encrypted: bool,
    pub fn send(self: *AlarmTransport, bytes: []const u8) !void {
        try self.session.send(0xf, bytes, self.encrypted);
    }
    pub fn receive(self: *AlarmTransport, command: u8) ![]const u8 {
        return self.session.receiveMatching(0xf, command);
    }
};

pub fn notify(a: std.mem.Allocator, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, secret: [16]u8, text: []const u8, wake_screen: ?bool) !void {
    try run(a, io, connection, nodes, device, secret, .{ .notification = .{ .text = text, .wake_screen = wake_screen } });
}

pub fn syncTime(a: std.mem.Allocator, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, secret: [16]u8, out: *Io.Writer) !void {
    try run(a, io, connection, nodes, device, secret, .{ .sync_time = out });
}

fn run(a: std.mem.Allocator, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, secret: [16]u8, action: Action) !void {
    const writer = bluez.findCharacteristic(nodes, device.path, write_uuid) orelse return error.AuthenticatedServiceUnavailable;
    const reader = bluez.findCharacteristic(nodes, device.path, read_uuid) orelse return error.AuthenticatedServiceUnavailable;
    var receiver: dbus.Receiver = .{ .connection = connection, .path = reader.path };
    try receiver.start(a);
    defer receiver.deinit();
    var session: Session = .{ .connection = connection, .io = io, .writer = writer, .reader = reader, .receiver = &receiver };
    defer {
        if (session.key) |*key| std.crypto.secureZero(u8, key);
        std.crypto.secureZero(u8, &session.decoder.buffer);
    }
    var exchange = try b163.Exchange.init();
    defer exchange.deinit();
    var start: [52]u8 = undefined;
    @memcpy(start[0..4], "\x04\x02\x00\x02");
    @memcpy(start[4..], &try exchange.public());
    try session.send(0x82, &start, false);
    const challenge = try session.receive(0x82);
    if (challenge.len != 67 or !std.mem.eql(u8, challenge[0..3], "\x10\x04\x01")) return error.InvalidAuthChallenge;
    var shared = try exchange.shared(challenge[19..67].*);
    defer std.crypto.secureZero(u8, &shared);
    var key: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    for (&key, secret, shared[8..24]) |*byte, s, k| byte.* = s ^ k;
    session.key = key;
    session.sequence = std.mem.readInt(u32, shared[0..4], .little);
    var response: [33]u8 = undefined;
    defer std.crypto.secureZero(u8, &response);
    response[0] = 5;
    Aes.initEnc(secret).encrypt(response[1..17], challenge[3..19]);
    Aes.initEnc(key).encrypt(response[17..33], challenge[3..19]);
    try session.send(0x82, &response, false);
    const accepted = try session.receive(0x82);
    if (!std.mem.eql(u8, accepted, "\x10\x05\x01")) {
        if (accepted.len >= 3) std.debug.print("Band authentication response: command {x}, status {x}, length {d}.\n", .{ accepted[1], accepted[2], accepted.len });
        return error.BandAuthenticationFailed;
    }
    std.debug.print("Band authentication succeeded.\n", .{});
    switch (action) {
        .sync_time => |out| {
            try band_time.sync(a, io, connection, nodes, device, out);
            return;
        },
        else => {},
    }
    try session.send(0x15, &.{1}, false);
    const mtu_reply = try session.receive(0x15);
    if (mtu_reply.len != 3 or mtu_reply[0] != 2) return error.InvalidBluetoothMtu;
    const att_payload = std.mem.readInt(u16, mtu_reply[1..3], .little);
    if (att_payload < 20 or att_payload > 514) return error.InvalidBluetoothMtu;
    session.writer.mtu = att_payload + 3;
    try session.send(0, &.{3}, false);
    const services = try session.receive(0);
    const alert = switch (action) {
        .sleep => |value| {
            try sleep.fromBand(a, io, connection, nodes, device, value.options, value.out, .{ .context = &session, .process = Session.maintain });
            return;
        },
        .weather => |value| {
            // Replies share the decoder buffer; consume the service list before more reads.
            const encrypted_http = try serviceEncryption(services, 1);
            const encrypted_config = try serviceEncryption(services, 0xa);
            // The wire format carries Celsius; set only the temperature display unit.
            try setCelsius(&session, encrypted_config);
            var transport: WeatherTransport = .{ .session = &session, .encrypted_http = encrypted_http };
            try weather.update(a, io, &transport, value.data, value.out);
            return;
        },
        .alarm => |value| {
            var transport: AlarmTransport = .{ .session = &session, .encrypted = try serviceEncryption(services, 0xf) };
            try alarms.execute(&transport, value.command, value.out);
            return;
        },
        .notification => |value| value,
        .sync_time => unreachable,
    };
    const encrypted_notifications = try serviceEncryption(services, 0x1e);
    const encrypted_files = try serviceEncryption(services, 0x0d);
    if (alert.wake_screen) |enabled| {
        const encrypted_config = try serviceEncryption(services, 0x0a);
        try setNotificationWake(&session, encrypted_config, enabled);
    }
    std.debug.print("Notification encryption advertised: {any}.\n", .{encrypted_notifications});
    try session.send(0x1e, &.{1}, encrypted_notifications);
    const capabilities = try notification.Capabilities.parse(try session.receive(0x1e));
    std.debug.print("Notification service version {d}.\n", .{capabilities.version});
    const payload = try notification.encodeAuthenticated(a, alert.text, capabilities, session.sequence);
    defer a.free(payload);
    try session.send(0x1e, payload, encrypted_notifications);
    // A write acknowledgment is not display confirmation. Keep processing requests
    // and acknowledgments briefly before closing the BLE connection.
    var end = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(10));
    while (true) {
        const packet = receiver.next(io, end) catch |err| {
            if (err == error.BandResponseTimedOut) break;
            return err;
        };
        const incoming = try session.decoder.push(packet, session.key);
        if (incoming) |message| {
            std.debug.print("Band response endpoint {x}, command {x}, length {d}.\n", .{ message.endpoint, message.data[0], message.data.len });
            if (message.endpoint == 0x1e and message.data[0] == 0x10) {
                const request = try a.dupe(u8, message.data);
                defer a.free(request);
                try sendIcon(a, &session, request, encrypted_files, encrypted_notifications);
                end = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(10));
            }
        }
        if (packet.len >= 5 and packet[0] == 3 and packet[1] & 4 != 0) try write(connection, reader, &.{ 4, 0, packet[3], 1, packet[4] });
    }
}

fn serviceEncryption(services: []const u8, endpoint: u16) !bool {
    if (services.len < 3 or services[0] != 4) return error.InvalidServiceList;
    const count = std.mem.readInt(u16, services[1..3], .little);
    if (services.len != 3 + @as(usize, count) * 3) return error.InvalidServiceList;
    var offset: usize = 3;
    while (offset < services.len) : (offset += 3) {
        if (std.mem.readInt(u16, services[offset..][0..2], .little) == endpoint) {
            return switch (services[offset + 2]) {
                0 => false,
                1 => true,
                else => error.UnsupportedNotificationProtocol,
            };
        }
    }
    return error.AuthenticatedServiceUnavailable;
}

test "decoder rejects incomplete, oversized and out-of-order packets" {
    var d: Decoder = .{};
    try std.testing.expectError(error.InvalidChunk, d.push(&.{3}, null));
    try std.testing.expectError(error.InvalidChunkOrder, d.push(&.{ 3, 0, 0, 1, 0, 1 }, null));
    try std.testing.expectError(error.InvalidChunkLength, d.push(&.{ 3, 7, 0, 1, 0, 255, 255, 255, 255, 0x82, 0 }, null));
    const message = (try d.push(&.{ 3, 7, 0, 1, 0, 3, 0, 0, 0, 0x82, 0, 0x10, 5, 1 }, null)).?;
    try std.testing.expectEqual(@as(u16, 0x82), message.endpoint);
    try std.testing.expectEqualSlices(u8, "\x10\x05\x01", message.data);
}

test "encrypted packet integrity and replay protection" {
    const key: [16]u8 = @splat(0x31);
    var block: [16]u8 = @splat(0);
    block[0] = 1;
    std.mem.writeInt(u32, block[1..5], 42, .little);
    std.mem.writeInt(u32, block[5..9], Crc.hash(block[0..5]), .little);
    encrypt(messageKey(key, 1), &block);
    var packet: [27]u8 = .{ 3, 15, 0, 1, 0, 1, 0, 0, 0, 0x1e, 0 } ++ @as([16]u8, @splat(0));
    @memcpy(packet[11..], &block);
    var d: Decoder = .{};
    try std.testing.expectEqualSlices(u8, &.{1}, (try d.push(&packet, key)).?.data);
    try std.testing.expectError(error.ReplayedPacket, d.push(&packet, key));
    d = .{};
    packet[11] ^= 0x80;
    try std.testing.expectError(error.InvalidPacketChecksum, d.push(&packet, key));
}

fn sendIcon(a: std.mem.Allocator, session: *Session, request: []const u8, encrypted_files: bool, encrypted_notifications: bool) !void {
    const package = "org.zig.smartband";
    if (request.len != package.len + 7 or !std.mem.eql(u8, request[1 .. 1 + package.len], package) or request[1 + package.len] != 0) return error.InvalidIconRequest;
    const base = package.len + 2;
    const format = request[base];
    const width = std.mem.readInt(u16, request[base + 1 ..][0..2], .little);
    const height = std.mem.readInt(u16, request[base + 3 ..][0..2], .little);
    if (width == 0 or height == 0 or width > 128 or height > 128) return error.InvalidIconRequest;
    const format_name: []const u8 = switch (format) {
        4 => "TGA_RGB565_GCNANOLITE",
        8 => "TGA_RGB565_DAVE2D",
        else => return error.UnsupportedIconFormat,
    };
    std.debug.print("Sending desktop icon ({d}x{d}, format {d}).\n", .{ width, height, format });
    const image = try desktopIcon(a, width, height, format);
    defer a.free(image);
    try session.send(0xd, &.{1}, encrypted_files);
    const caps = try session.receive(0xd);
    if (caps.len >= 4) std.debug.print("File transfer version {d}, chunk {d}, BLE MTU {d}.\n", .{ caps[1], std.mem.readInt(u16, caps[2..4], .little), session.writer.mtu });
    if (caps.len < 4 or caps[0] != 2 or caps[1] < 1 or caps[1] > 2) return error.UnsupportedIconTransfer;
    const chunk_size = std.mem.readInt(u16, caps[2..4], .little);
    if (chunk_size == 0 or chunk_size > limit - 64 or (image.len + chunk_size - 1) / chunk_size + session.handle + 3 >= 255) return error.UnsupportedIconTransfer;
    const url = try std.fmt.allocPrint(a, "notification://logo?app_id={s}&width={d}&height={d}&format={s}", .{ package, width, height, format_name });
    defer a.free(url);
    var upload: std.ArrayList(u8) = .empty;
    defer upload.deinit(a);
    try upload.appendSlice(a, &.{ 3, 0 });
    try upload.appendSlice(a, url);
    try upload.appendSlice(a, "\x00logo_org_zig_smartband.tga\x00");
    var sizes: [8]u8 = undefined;
    std.mem.writeInt(u32, sizes[0..4], @intCast(image.len), .little);
    std.mem.writeInt(u32, sizes[4..8], Crc.hash(image), .little);
    try upload.appendSlice(a, &sizes);
    try session.send(0xd, upload.items, encrypted_files);
    const reply = try session.receive(0xd);
    if (reply.len < 7 or reply[0] != 4 or reply[1] != 0 or reply[2] != 0) return error.IconTransferRejected;
    var offset: usize = std.mem.readInt(u32, reply[3..7], .little);
    if (offset > image.len) return error.InvalidIconProgress;
    var index: u8 = 0;
    while (offset < image.len) {
        const take = @min(image.len - offset, chunk_size);
        const first = offset == 0;
        const last = offset + take == image.len;
        const header: usize = if (first) 10 else 6;
        // The device's v1/v2 protocol uses fixed-size blocks, including final padding.
        const block = try a.alloc(u8, 10 + chunk_size);
        defer a.free(block);
        @memset(block, 0);
        block[0] = 0x10;
        block[1] = (if (first) @as(u8, 1) else 0) | (if (last) @as(u8, 2) else 0);
        block[2] = 0;
        block[3] = index;
        std.mem.writeInt(u16, block[header - 2 ..][0..2], @intCast(take), .little);
        @memcpy(block[header..][0..take], image[offset..][0..take]);
        try session.send(0xd, block, encrypted_files);
        const ack = try session.receive(0xd);
        if (ack.len < 3 or ack[0] != 0x11 or ack[1] != 0 or ack[2] != 0) return error.IconTransferRejected;
        offset += take;
        index +%= 1;
    }
    const ack = try a.alloc(u8, package.len + 3);
    defer a.free(ack);
    ack[0] = 0x11;
    @memcpy(ack[1..][0..package.len], package);
    ack[package.len + 1] = 0;
    ack[package.len + 2] = 1;
    try session.send(0x1e, ack, encrypted_notifications);
    std.debug.print("Desktop icon transferred and acknowledged.\n", .{});
}

fn desktopIcon(a: std.mem.Allocator, width: u16, height: u16, format: u8) ![]u8 {
    const data = try a.alloc(u8, 64 + @as(usize, width) * height * 2);
    @memset(data, 0);
    data[0] = 46;
    data[2] = 2;
    std.mem.writeInt(u16, data[12..14], width, .little);
    std.mem.writeInt(u16, data[14..16], height, .little);
    data[16] = 16;
    data[17] = 0x20;
    @memcpy(data[18..23], if (format == 4) "SOMHP" else "SOMH6");
    for (0..height) |y| {
        for (0..width) |x| {
            const screen = x >= width / 5 and x < width * 4 / 5 and y >= height / 5 and y < height * 3 / 5;
            const stand = x >= width * 2 / 5 and x < width * 3 / 5 and y >= height * 3 / 5 and y < height * 4 / 5;
            const color: u16 = if (screen or stand) 0xffff else 0x2197;
            std.mem.writeInt(u16, data[64 + (y * width + x) * 2 ..][0..2], color, .little);
        }
    }
    return data;
}

test "AES ECB multi-block interoperability vector" {
    var key: [16]u8 = undefined;
    var plaintext: [32]u8 = undefined;
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, "2b7e151628aed2a6abf7158809cf4f3c");
    _ = try std.fmt.hexToBytes(&plaintext, "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");
    _ = try std.fmt.hexToBytes(&expected, "3ad77bb40d7a3660a89ecaf32466ef97f5d3d58503b9699de785895a96fdbaaf");
    const original = plaintext;
    encrypt(key, &plaintext);
    try std.testing.expectEqualSlices(u8, &expected, &plaintext);
    decrypt(key, &plaintext);
    try std.testing.expectEqualSlices(u8, &original, &plaintext);
    try std.testing.expectEqual(@as(u32, 0xcbf43926), Crc.hash("123456789"));
}

test "multi-chunk ciphertext preserves text across block and ATT boundaries" {
    const key: [16]u8 = @splat(0x42);
    var clear: [48]u8 = @splat(0);
    const text = "A complete notification message!";
    try std.testing.expectEqual(@as(usize, 32), text.len);
    @memcpy(clear[0..32], text);
    std.mem.writeInt(u32, clear[32..36], 18, .little);
    std.mem.writeInt(u32, clear[36..40], Crc.hash(clear[0..36]), .little);
    encrypt(messageKey(key, 7), &clear);
    var d: Decoder = .{};
    var first: [20]u8 = .{ 3, 9, 0, 7, 0, 32, 0, 0, 0, 0x1e, 0 } ++ @as([9]u8, @splat(0));
    @memcpy(first[11..], clear[0..9]);
    try std.testing.expect((try d.push(&first, key)) == null);
    var middle: [20]u8 = .{ 3, 8, 0, 7, 1 } ++ @as([15]u8, @splat(0));
    @memcpy(middle[5..], clear[9..24]);
    try std.testing.expect((try d.push(&middle, key)) == null);
    middle[4] = 2;
    @memcpy(middle[5..], clear[24..39]);
    try std.testing.expect((try d.push(&middle, key)) == null);
    var last: [14]u8 = .{ 3, 14, 0, 7, 3 } ++ @as([9]u8, @splat(0));
    @memcpy(last[5..], clear[39..48]);
    const result = (try d.push(&last, key)).?;
    try std.testing.expectEqualSlices(u8, text, result.data);
}

test "service list boundaries and desktop icon format" {
    try std.testing.expect(try serviceEncryption(&.{ 4, 2, 0, 0x1e, 0, 1, 0xd, 0, 0 }, 0x1e));
    try std.testing.expect(!try serviceEncryption(&.{ 4, 1, 0, 0xd, 0, 0 }, 0xd));
    try std.testing.expectError(error.InvalidServiceList, serviceEncryption(&.{ 4, 255, 255 }, 0x1e));
    const icon = try desktopIcon(std.testing.allocator, 54, 54, 8);
    defer std.testing.allocator.free(icon);
    try std.testing.expectEqual(@as(usize, 5896), icon.len);
    try std.testing.expectEqualSlices(u8, "SOMH6", icon[18..23]);
    try std.testing.expectEqual(@as(u16, 54), std.mem.readInt(u16, icon[12..14], .little));
    try std.testing.expectEqual(@as(u8, 16), icon[16]);
}

// Config endpoint 0x000a: DISPLAY group 1, version 2, boolean argument 0x0c.
fn temperatureUnit(data: []const u8) !u8 {
    if (data.len != 9 or !std.mem.eql(u8, data[0..8], &.{ 4, 1, 0xa, 1, 0, 1, 0x12, 0x10 }) or data[8] > 1) return error.UnsupportedTemperatureSetting;
    return data[8];
}

fn setCelsius(session: *Session, encrypted: bool) !void {
    const request = [_]u8{ 3, 0, 0xa, 1, 0x12 };
    try session.send(0xa, &request, encrypted);
    const current = try temperatureUnit(try session.receiveMatching(0xa, 4));
    if (current != 0) {
        try session.send(0xa, &.{ 5, 0xa, 1, 0, 1, 0x12, 0x10, 0 }, encrypted);
        const ack = try session.receiveMatching(0xa, 6);
        if (ack.len < 2) return error.InvalidConfigurationAck;
        try session.send(0xa, &request, encrypted);
        if (try temperatureUnit(try session.receiveMatching(0xa, 4)) != 0) return error.TemperatureSettingNotApplied;
    }
    std.debug.print("Weather temperature unit: Celsius (verified).\n", .{});
}

test "temperature unit parser validates the requested system byte" {
    try std.testing.expectEqual(@as(u8, 0), try temperatureUnit(&.{ 4, 1, 0xa, 1, 0, 1, 0x12, 0x10, 0 }));
    try std.testing.expectEqual(@as(u8, 1), try temperatureUnit(&.{ 4, 1, 0xa, 1, 0, 1, 0x12, 0x10, 1 }));
    try std.testing.expectError(error.UnsupportedTemperatureSetting, temperatureUnit(&.{ 4, 1, 0xa, 1, 0, 1, 0x12, 0x10, 2 }));
}

const wake_request = [_]u8{ 3, 0, 1, 1, 0x0c };

fn parseNotificationWake(data: []const u8) !bool {
    if (data.len != 9 or !std.mem.eql(u8, data[0..8], &.{ 4, 1, 1, 2, 0, 1, 0x0c, 0x0b }) or data[8] > 1) return error.UnsupportedWakeScreenSetting;
    return data[8] == 1;
}

fn wakeSetting(enabled: bool) [8]u8 {
    return .{ 5, 1, 2, 0, 1, 0x0c, 0x0b, @intFromBool(enabled) };
}

fn setNotificationWake(session: *Session, encrypted: bool, enabled: bool) !void {
    try session.send(0xa, &wake_request, encrypted);
    const current = try parseNotificationWake(try session.receive(0xa));
    if (current != enabled) {
        try session.send(0xa, &wakeSetting(enabled), encrypted);
        const ack = try session.receive(0xa);
        if (ack.len < 2 or ack[0] != 6) return error.InvalidConfigurationAck;
        // Read-back verifies the actual state independently of ACK status codes.
        try session.send(0xa, &wake_request, encrypted);
        if (try parseNotificationWake(try session.receive(0xa)) != enabled) return error.WakeScreenSettingNotApplied;
    }
    std.debug.print("Notification screen wake: {s} (verified).\n", .{if (enabled) "on" else "off"});
}

test "notification wake setting changes only the requested display boolean" {
    try std.testing.expectEqualSlices(u8, &.{ 5, 1, 2, 0, 1, 0x0c, 0x0b, 1 }, &wakeSetting(true));
    try std.testing.expectEqualSlices(u8, &.{ 5, 1, 2, 0, 1, 0x0c, 0x0b, 0 }, &wakeSetting(false));
    try std.testing.expect(try parseNotificationWake(&.{ 4, 1, 1, 2, 0, 1, 0x0c, 0x0b, 1 }));
    try std.testing.expect(!try parseNotificationWake(&.{ 4, 1, 1, 2, 0, 1, 0x0c, 0x0b, 0 }));
    try std.testing.expectError(error.UnsupportedWakeScreenSetting, parseNotificationWake(&.{ 4, 1, 1, 2, 0, 0 }));
    try std.testing.expectError(error.UnsupportedWakeScreenSetting, parseNotificationWake(&.{ 4, 1, 1, 2, 0, 1, 0x0c, 0x0b, 2 }));
    try std.testing.expectError(error.UnsupportedWakeScreenSetting, parseNotificationWake(&.{ 4, 1, 1, 3, 0, 1, 0x0c, 0x0b, 1 }));
}
