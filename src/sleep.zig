//! Authenticated Huami activity history, raw capture and sleep export.
//! Wire reference: Gadgetbridge AbstractFetchOperation / FetchActivityOperation.
const std = @import("std");
const clock = @import("band_time.zig");
const dbus = @import("dbus.zig");
const bluez = @import("bluez.zig");
const Io = std.Io;
const A = std.mem.Allocator;
// Bound a single unexpected response without imposing a calendar-history limit.
const max_block_bytes = 16 * 1024 * 1024;
pub const Background = struct {
    context: *anyopaque,
    process: *const fn (*anyopaque) anyerror!void,
};

const Transport = struct {
    allocator: A,
    io: Io,
    connection: *dbus.Connection,
    control: bluez.Node,
    metadata_receiver: *dbus.Receiver,
    data_receiver: *dbus.Receiver,
    background: Background,
    pub fn write(self: *@This(), bytes: []const u8) !void {
        var reply = try self.connection.call(self.control.path, "org.bluez.GattCharacteristic1", "WriteValue", .{
            .write_bytes = bytes,
            .dictionary_string = .{ .key = "type", .value = if (self.control.write_without_response) "command" else "request" },
            .timeout_us = 15_000_000,
        });
        reply.deinit();
    }
    pub fn startData(self: *@This()) !void {
        try self.data_receiver.start(self.allocator);
    }
    pub fn stopData(self: *@This()) !void {
        self.data_receiver.deinit();
        self.data_receiver.head = 0;
        self.data_receiver.tail = 0;
        self.data_receiver.failed = false;
    }
    pub fn next(self: *@This(), deadline: Io.Timestamp) !Frame {
        while (true) {
            try self.background.process(self.background.context);
            // Drain activity packets first so a completion message cannot overtake them.
            if (try self.data_receiver.poll()) |bytes| return .{ .data = bytes };
            if (try self.metadata_receiver.poll()) |bytes| return .{ .metadata = bytes };
            try self.connection.processSignals(self.io, deadline);
        }
    }
};

pub fn fromBand(a: A, io: Io, connection: *dbus.Connection, nodes: []const bluez.Node, device: bluez.Node, options: Options, out: *Io.Writer, background: Background) !void {
    const control = bluez.findCharacteristic(nodes, device.path, "00000004-0000-3512-2118-0009af100700") orelse return error.HistoryServiceUnavailable;
    const data = bluez.findCharacteristic(nodes, device.path, "00000005-0000-3512-2118-0009af100700") orelse return error.HistoryServiceUnavailable;
    var meta_receiver: dbus.Receiver = .{ .connection = connection, .path = control.path };
    try meta_receiver.start(a);
    defer meta_receiver.deinit();
    var data_receiver: dbus.Receiver = .{ .connection = connection, .path = data.path };
    defer data_receiver.deinit();
    var transport: Transport = .{ .allocator = a, .io = io, .connection = connection, .control = control, .metadata_receiver = &meta_receiver, .data_receiver = &data_receiver, .background = background };
    try download(a, io, &transport, options, out);
}

pub const Options = struct {
    since: clock.Calendar,
    output_dir: []const u8,
    all_history: bool = false,
    timeout_seconds: u32 = 900,
};

pub fn parse(a: A, io: Io, env: *const std.process.Environ.Map, args: []const []const u8) !Options {
    var since: ?clock.Calendar = null;
    var directory: ?[]const u8 = null;
    var all_history = false;
    var timeout_seconds: ?u32 = null;
    var index: usize = 0;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--all")) {
            if (all_history or since != null) return error.InvalidSleepArguments;
            all_history = true;
            index += 1;
            continue;
        }
        if (index + 1 == args.len) return error.InvalidSleepArguments;
        if (std.mem.eql(u8, args[index], "--since") and since == null and !all_history) {
            const text = args[index + 1];
            if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidSleepDate;
            for (text, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return error.InvalidSleepDate;
            since = clock.localDate(
                std.fmt.parseInt(u16, text[0..4], 10) catch return error.InvalidSleepDate,
                std.fmt.parseInt(u8, text[5..7], 10) catch return error.InvalidSleepDate,
                std.fmt.parseInt(u8, text[8..10], 10) catch return error.InvalidSleepDate,
            ) catch return error.InvalidSleepDate;
        } else if (std.mem.eql(u8, args[index], "--output") and directory == null and args[index + 1].len != 0) {
            directory = args[index + 1];
        } else if (std.mem.eql(u8, args[index], "--timeout") and timeout_seconds == null) {
            const text = args[index + 1];
            if (text.len == 0) return error.InvalidSleepArguments;
            for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidSleepArguments;
            timeout_seconds = std.fmt.parseInt(u32, text, 10) catch return error.InvalidSleepArguments;
            if (timeout_seconds.? == 0) return error.InvalidSleepArguments;
        } else return error.InvalidSleepArguments;
        index += 2;
    }
    // The Band 7 was manufactured after 2000. An older request lets the firmware
    // return its first retained record, rather than assuming a retention duration.
    const start = if (all_history) try clock.localDate(2000, 1, 1) else since orelse try clock.localDaysAgo(7);
    if (try start.unixSeconds() > Io.Timestamp.now(io, .real).toSeconds()) return error.InvalidSleepDate;
    if (directory == null) {
        const now = try clock.localNow();
        const name = try std.fmt.allocPrint(a, "sleep-{d:0>4}-{d:0>2}-{d:0>2}-{d}", .{ now.year, now.month, now.day, Io.Timestamp.now(io, .real).toMilliseconds() });
        const home = env.get("HOME");
        const xdg = env.get("XDG_DATA_HOME");
        directory = if (xdg != null and std.fs.path.isAbsolute(xdg.?))
            try std.fs.path.join(a, &.{ xdg.?, "smart-band", "sleep", name })
        else
            try std.fs.path.join(a, &.{ home orelse return error.ConfigDirectoryUnavailable, ".local", "share", "smart-band", "sleep", name });
    }
    return .{ .since = start, .output_dir = directory.?, .all_history = all_history, .timeout_seconds = timeout_seconds orelse 900 };
}

pub fn startRequest(calendar: clock.Calendar) ![10]u8 {
    _ = try calendar.unixSeconds();
    var bytes: [10]u8 = .{ 1, 1, 0, 0, calendar.month, calendar.day, calendar.hour, calendar.minute, calendar.second, @bitCast(calendar.utc_quarters) };
    std.mem.writeInt(u16, bytes[2..4], calendar.year, .little);
    return bytes;
}

const Header = struct {
    reported_length: u32,
    start: clock.Calendar,
    raw: []const u8,
};

fn header(a: A, bytes: []const u8, requested: clock.Calendar) !Header {
    if ((bytes.len != 15 and bytes.len != 16) or !std.mem.eql(u8, bytes[0..3], &.{ 0x10, 1, 1 })) return error.InvalidHistoryHeader;
    const length = std.mem.readInt(u32, bytes[3..7], .little);
    if (length > max_block_bytes / 8) return error.HistoryTooLarge;
    const start: clock.Calendar = if (length == 0) requested else .{
        .year = std.mem.readInt(u16, bytes[7..9], .little),
        .month = bytes[9],
        .day = bytes[10],
        .hour = bytes[11],
        .minute = bytes[12],
        .second = bytes[13],
        .utc_quarters = @bitCast(bytes[14]),
        .weekday = 0,
    };
    _ = try start.unixSeconds();
    return .{ .reported_length = length, .start = start, .raw = try a.dupe(u8, bytes) };
}

pub const Frame = union(enum) { metadata: []const u8, data: []const u8 };
const RawBytes = struct {
    values: []const u8,
    pub fn jsonStringify(self: RawBytes, output: *std.json.Stringify) std.json.Stringify.Error!void {
        // std.json treats byte slices as text by default; history bytes are numeric.
        try output.beginArray();
        for (self.values) |byte| try output.write(byte);
        try output.endArray();
    }
};
pub const Sample = struct {
    timestamp_utc: i64,
    raw: [8]u8,
    pub fn sleeping(self: Sample) bool {
        return self.raw[0] == 120;
    }
    pub fn stage(self: Sample) []const u8 {
        if (!self.sleeping()) return if (self.raw[0] == 115 or self.raw[0] == 118) "not_worn" else "unknown";
        // These are Gadgetbridge-compatible estimates, not band-provided stage labels.
        if (self.raw[7] & 127 > 55) return "rem";
        if (self.raw[6] & 127 > 42) return "deep";
        return "light";
    }
    pub fn heartRate(self: Sample) ?u8 {
        return if (self.raw[3] == 0 or self.raw[3] == 255) null else self.raw[3];
    }
    pub fn jsonStringify(self: Sample, output: *std.json.Stringify) std.json.Stringify.Error!void {
        try output.beginObject();
        try output.objectField("timestamp_utc");
        try output.write(self.timestamp_utc);
        try output.objectField("raw");
        try output.write(RawBytes{ .values = &self.raw });
        try output.objectField("sleeping");
        try output.write(self.sleeping());
        try output.objectField("stage_estimate");
        try output.write(if (self.sleeping()) self.stage() else null);
        try output.objectField("heart_rate");
        try output.write(self.heartRate());
        try output.endObject();
    }
};

const Block = struct {
    index: usize,
    start_utc: i64,
    reported_length: u32,
    received_bytes: usize,
    raw_header: RawBytes,
    reported_crc32: ?u32,
    computed_crc32: u32,
    complete: bool,
};

const Capture = struct {
    a: A,
    io: Io,
    dir: Io.Dir,
    options: Options,
    samples: std.ArrayList(Sample) = .empty,
    blocks: std.ArrayList(Block) = .empty,

    fn init(a: A, io: Io, options: Options) !Capture {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, options.output_dir, .{ .permissions = .fromMode(0o700) });
        errdefer dir.close(io);
        // Reserve this capture directory; never overwrite a previous download.
        try dir.writeFile(io, .{ .sub_path = "download.json", .data = "{\"complete\":false,\"status\":\"in_progress\"}\n", .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) } });
        return .{ .a = a, .io = io, .dir = dir, .options = options };
    }
    fn deinit(self: *Capture) void {
        self.dir.close(self.io);
        self.samples.deinit(self.a);
        self.blocks.deinit(self.a);
    }
    fn rawBlock(self: *Capture, index: usize, info: Header, bytes: []const u8, crc: ?u32, complete: bool) !void {
        const name = try std.fmt.allocPrint(self.a, "block-{d:0>4}{s}.bin", .{ index, if (complete) "" else ".partial" });
        try self.dir.writeFile(self.io, .{ .sub_path = name, .data = bytes, .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) } });
        try self.blocks.append(self.a, .{ .index = index, .start_utc = try info.start.unixSeconds(), .reported_length = info.reported_length, .received_bytes = bytes.len, .raw_header = .{ .values = info.raw }, .reported_crc32 = crc, .computed_crc32 = std.hash.Crc32.hash(bytes), .complete = complete });
    }
    fn exportFiles(self: *Capture, complete: bool, failure: ?[]const u8) !void {
        const source = try std.json.Stringify.valueAlloc(self.a, .{
            .version = 1,
            .complete = complete,
            .failure = failure,
            .since_utc = try self.options.since.unixSeconds(),
            .request_scope = if (self.options.all_history) "all_available_activity_history" else "since",
            .timeout_seconds = self.options.timeout_seconds,
            .sample_interval_seconds = 60,
            .reported_length_unit = "samples",
            .stage_estimation = "raw_kind=120; REM score & 127 > 55; otherwise deep score & 127 > 42; otherwise light. Estimates, not device stage labels.",
            .raw_byte_order = "activity_kind,intensity,steps,heart_rate,unknown1,sleep_score,deep_score,rem_score",
            .blocks = self.blocks.items,
            .samples = self.samples.items,
        }, .{ .whitespace = .indent_2 });
        var atomic = try self.dir.createFileAtomic(self.io, "download.json", .{ .replace = true, .permissions = .fromMode(0o600) });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, source);
        try atomic.replace(self.io);
        inline for (.{ false, true }) |sleep_only| {
            const name = if (sleep_only) "sleep.csv" else "activity.csv";
            const file = try self.dir.createFile(self.io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
            defer file.close(self.io);
            var buffer: [4096]u8 = undefined;
            var output = file.writer(self.io, &buffer);
            const out = &output.interface;
            try out.writeAll("timestamp_utc,local_time,raw_kind,intensity,steps,heart_rate,unknown1,sleep_score,deep_score,rem_score,stage_estimate\n");
            for (self.samples.items) |sample| {
                if (sleep_only and !sample.sleeping()) continue;
                const date = try clock.localAt(sample.timestamp_utc);
                try out.print("{d},", .{sample.timestamp_utc});
                try date.print(out);
                try out.print(",{d},{d},{d},", .{ sample.raw[0], sample.raw[1], sample.raw[2] });
                if (sample.heartRate()) |value| try out.print("{d}", .{value});
                try out.print(",{d},{d},{d},{d},{s}\n", .{ sample.raw[4], sample.raw[5], sample.raw[6], sample.raw[7], sample.stage() });
            }
            try out.flush();
        }
    }
};

fn metadata(transport: anytype, deadline: Io.Timestamp, command: u8) ![]const u8 {
    while (true) {
        const frame = try transport.next(deadline);
        if (frame == .data) return error.UnexpectedHistoryData;
        const bytes = frame.metadata;
        if (bytes.len < 3 or bytes[0] != 0x10 or bytes[1] != command) continue;
        if (bytes[2] != 1) {
            std.debug.print("History response: command {x}, status {x}, length {d}.\n", .{ command, bytes[2], bytes.len });
            return error.HistoryRequestRejected;
        }
        return bytes;
    }
}

fn acknowledge(transport: anytype, deadline: Io.Timestamp) !void {
    // Never send 03 01: that marks detailed records as saved and can discard them.
    try transport.write(&.{ 3, 9 });
    _ = try metadata(transport, deadline, 3);
}

fn phaseDeadline(io: Io, overall: Io.Timestamp) Io.Timestamp {
    return .{ .nanoseconds = @min(overall.nanoseconds, Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(30)).nanoseconds) };
}

fn transfer(capture: *Capture, transport: anytype, requested: clock.Calendar, index: usize, deadline: Io.Timestamp, out: *Io.Writer) !?clock.Calendar {
    try transport.stopData();
    try transport.write(&try startRequest(requested));
    const info = try header(capture.a, try metadata(transport, phaseDeadline(capture.io, deadline), 1), requested);
    try out.print("History block {d}: band reports {d} samples, starting ", .{ index, info.reported_length });
    try info.start.print(out);
    try out.writeAll(".\n");
    try out.flush();
    if (info.reported_length == 0) {
        try acknowledge(transport, phaseDeadline(capture.io, deadline));
        return null;
    }
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(capture.a);
    var saved = false;
    errdefer if (!saved and bytes.items.len != 0) capture.rawBlock(index, info, bytes.items, null, false) catch {};
    try transport.startData();
    try transport.write(&.{2});
    var counter: u8 = 0;
    var progress_bytes: usize = 0;
    var reported_crc: ?u32 = null;
    while (true) {
        const frame = try transport.next(phaseDeadline(capture.io, deadline));
        switch (frame) {
            .data => |packet| {
                if (packet.len < 1 or packet[0] != counter) return error.InvalidHistoryPacketSequence;
                counter +%= 1;
                if (bytes.items.len + packet.len - 1 > max_block_bytes) return error.HistoryTooLarge;
                try bytes.appendSlice(capture.a, packet[1..]);
                if (bytes.items.len - progress_bytes >= 64 * 1024) {
                    progress_bytes = bytes.items.len;
                    try out.print("Receiving block {d}: {d}/{d} samples...\n", .{ index, bytes.items.len / 8, info.reported_length });
                    try out.flush();
                }
            },
            .metadata => |packet| {
                if (packet.len < 3 or !std.mem.eql(u8, packet[0..2], &.{ 0x10, 2 })) continue;
                if (packet[2] != 1 or (packet.len != 3 and packet.len != 7)) return error.InvalidHistoryCompletion;
                if (packet.len == 7) reported_crc = std.mem.readInt(u32, packet[3..7], .little);
                break;
            },
        }
    }
    const computed = std.hash.Crc32.hash(bytes.items);
    const valid_length = bytes.items.len == @as(usize, info.reported_length) * 8;
    const valid = bytes.items.len != 0 and valid_length and (reported_crc == null or reported_crc.? == computed);
    try capture.rawBlock(index, info, bytes.items, reported_crc, valid);
    saved = true;
    if (bytes.items.len == 0 or bytes.items.len % 8 != 0) return error.InvalidHistorySampleLength;
    if (!valid_length) {
        try acknowledge(transport, phaseDeadline(capture.io, deadline));
        return error.HistoryLengthMismatch;
    }
    if (reported_crc != null and reported_crc.? != computed) {
        try out.print("Activity CRC32: band {x}, raw bytes {x}; raw capture preserved.\n", .{ reported_crc.?, computed });
        try out.flush();
        try acknowledge(transport, phaseDeadline(capture.io, deadline));
        return error.HistoryChecksumMismatch;
    }
    const count = bytes.items.len / 8;
    const start = try info.start.unixSeconds();
    const since = try capture.options.since.unixSeconds();
    for (0..count) |i| {
        const timestamp = start + @as(i64, @intCast(i)) * 60;
        if (timestamp < since) continue;
        if (capture.samples.items.len != 0 and timestamp <= capture.samples.items[capture.samples.items.len - 1].timestamp_utc) continue;
        try capture.samples.append(capture.a, .{ .timestamp_utc = timestamp, .raw = bytes.items[i * 8 ..][0..8].* });
    }
    try out.print("Saved {d} activity samples; records kept on the band.\n", .{count});
    try out.flush();
    try acknowledge(transport, phaseDeadline(capture.io, deadline));
    const next = start + @as(i64, @intCast(count)) * 60;
    if (next <= try requested.unixSeconds()) return error.HistoryNoProgress;
    return try clock.localAt(next);
}

pub fn download(a: A, io: Io, transport: anytype, options: Options, out: *Io.Writer) !void {
    var capture = try Capture.init(a, io, options);
    defer capture.deinit();
    try out.print("Saving sleep/activity history to {s}\n", .{options.output_dir});
    if (options.all_history) try out.writeAll("Requesting all available sleep/activity history.\n");
    try out.flush();
    const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(options.timeout_seconds));
    const target = Io.Timestamp.now(io, .real).toSeconds() - 60;
    var requested = options.since;
    var index: usize = 1;
    while (true) : (index += 1) {
        const next = transfer(&capture, transport, requested, index, deadline, out) catch |err| {
            capture.exportFiles(false, @errorName(err)) catch |save_error| std.debug.print("Could not finalize partial history export: {t}\n", .{save_error});
            return err;
        };
        if (next == null or try next.?.unixSeconds() >= target) break;
        requested = next.?;
    }
    try capture.exportFiles(true, null);
    var sleeping_minutes: usize = 0;
    for (capture.samples.items) |sample| if (sample.sleeping()) {
        sleeping_minutes += 1;
    };
    try out.print("Downloaded {d} activity minutes, including {d} sleeping minutes.\nFiles: download.json, activity.csv, sleep.csv, and raw block files.\n", .{ capture.samples.items.len, sleeping_minutes });
}

test "sleep requests use Huami minute timestamps and stage estimates preserve original bytes" {
    const date: clock.Calendar = .{ .year = 2026, .month = 11, .day = 2, .hour = 0, .minute = 0, .second = 0, .weekday = 1, .utc_quarters = -24 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0xea, 7, 11, 2, 0, 0, 0, 0xe8 }, &try startRequest(date));
    var sample: Sample = .{ .timestamp_utc = 0, .raw = .{ 120, 0, 0, 255, 0, 20, 171, 183 } };
    try std.testing.expectEqualStrings("deep", sample.stage());
    try std.testing.expect(sample.heartRate() == null);
    sample.raw[7] = 184;
    try std.testing.expectEqualStrings("rem", sample.stage());
    sample.raw[0] = 115;
    try std.testing.expectEqualStrings("not_worn", sample.stage());
}

test "sleep JSON writes byte values as numeric arrays including non-UTF8 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample: Sample = .{ .timestamp_utc = 0, .raw = .{ 120, 0, 0, 255, 0, 20, 171, 184 } };
    const source = try std.json.Stringify.valueAlloc(a, sample, .{});
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
    const bytes = value.object.get("raw").?.array.items;
    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    for (bytes, sample.raw) |encoded, byte| try std.testing.expectEqual(@as(i64, byte), encoded.integer);
    try std.testing.expectEqualStrings("rem", value.object.get("stage_estimate").?.string);
    try std.testing.expect(value.object.get("heart_rate").? == .null);
}

test "sleep CLI rejects invalid dates and flags before Bluetooth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    defer env.deinit();
    const options = try parse(arena.allocator(), std.testing.io, &env, &.{ "--since", "2026-02-28", "--output", "data" });
    try std.testing.expectEqual(@as(u8, 28), options.since.day);
    try std.testing.expectError(error.InvalidSleepDate, parse(arena.allocator(), std.testing.io, &env, &.{ "--since", "2026-02-30" }));
    try std.testing.expectError(error.InvalidSleepArguments, parse(arena.allocator(), std.testing.io, &env, &.{"--output"}));
}

test "all-history CLI accepts a timeout and excludes competing ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const options = try parse(a, std.testing.io, &env, &.{ "--all", "--timeout", "1800", "--output", "data" });
    try std.testing.expect(options.all_history);
    try std.testing.expectEqual(@as(u16, 2000), options.since.year);
    try std.testing.expectEqual(@as(u32, 1800), options.timeout_seconds);
    try std.testing.expectError(error.InvalidSleepArguments, parse(a, std.testing.io, &env, &.{ "--all", "--all" }));
    try std.testing.expectError(error.InvalidSleepArguments, parse(a, std.testing.io, &env, &.{ "--all", "--since", "2026-01-01" }));
    try std.testing.expectError(error.InvalidSleepArguments, parse(a, std.testing.io, &env, &.{ "--since", "2026-01-01", "--all" }));
    try std.testing.expectError(error.InvalidSleepArguments, parse(a, std.testing.io, &env, &.{ "--timeout", "0" }));
    try std.testing.expectError(error.InvalidSleepArguments, parse(a, std.testing.io, &env, &.{ "--timeout", "-1" }));
}

const RetainedHistory = struct {
    body: []const u8,
    rounds: usize = 1,
    completed: usize = 0,
    state: enum { header, data, completion, ack, empty_ack } = .header,
    offset: usize = 0,
    counter: u8 = 0,
    packet: [241]u8 = undefined,
    response: [16]u8 = undefined,
    no_progress: bool = false,

    pub fn write(_: *@This(), bytes: []const u8) !void {
        if (bytes[0] == 3) try std.testing.expectEqualSlices(u8, &.{ 3, 9 }, bytes);
    }
    pub fn startData(_: *@This()) !void {}
    pub fn stopData(_: *@This()) !void {}
    pub fn next(self: *@This(), _: Io.Timestamp) !Frame {
        while (true) switch (self.state) {
            .header => {
                const count: u32 = if (self.completed == self.rounds) 0 else @intCast(self.body.len / 8);
                const base: i64 = 1577923200; // 2020-01-02T00:00:00Z.
                const timestamp = base + @as(i64, @intCast(self.completed * self.body.len / 8)) * 60 - @as(i64, if (self.no_progress) 60 else 0);
                const request = try startRequest(try clock.localAt(timestamp));
                self.response = @splat(0);
                @memcpy(self.response[0..3], &[_]u8{ 0x10, 1, 1 });
                std.mem.writeInt(u32, self.response[3..7], count, .little);
                @memcpy(self.response[7..15], request[2..10]);
                self.offset = 0;
                self.counter = 0;
                self.state = if (count == 0) .empty_ack else .data;
                return .{ .metadata = &self.response };
            },
            .data => {
                if (self.offset == self.body.len) {
                    self.state = .completion;
                    continue;
                }
                const take = @min(self.body.len - self.offset, 240);
                self.packet[0] = self.counter;
                self.counter +%= 1;
                @memcpy(self.packet[1..][0..take], self.body[self.offset..][0..take]);
                self.offset += take;
                return .{ .data = self.packet[0 .. take + 1] };
            },
            .completion => {
                @memcpy(self.response[0..3], &[_]u8{ 0x10, 2, 1 });
                std.mem.writeInt(u32, self.response[3..7], std.hash.Crc32.hash(self.body), .little);
                self.state = .ack;
                return .{ .metadata = self.response[0..7] };
            },
            .ack => {
                self.completed += 1;
                self.state = .header;
                return .{ .metadata = &.{ 0x10, 3, 1 } };
            },
            .empty_ack => return .{ .metadata = &.{ 0x10, 3, 1 } },
        };
    }
};

test "all history can exceed 31 days and wrap the packet counter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(a);
    const count = 32 * 24 * 60;
    const body = try a.alloc(u8, count * 8);
    for (0..count) |i| @memcpy(body[i * 8 ..][0..8], &[_]u8{ 120, 0, 0, 60, 0, 20, 0, 0 });
    var fake: RetainedHistory = .{ .body = body };
    var options = try testOptions(a, tmp);
    options.all_history = true;
    try download(a, std.testing.io, &fake, options, &out.writer);
    const raw = try tmp.dir.readFileAlloc(std.testing.io, "capture/block-0001.bin", a, .limited(1024 * 1024));
    try std.testing.expectEqualSlices(u8, body, raw);
    const csv = try tmp.dir.readFileAlloc(std.testing.io, "capture/sleep.csv", a, .limited(8 * 1024 * 1024));
    try std.testing.expectEqual(@as(usize, count + 1), std.mem.count(u8, csv, "\n"));
}

test "all history follows more than 64 blocks until the band reports no more records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(a);
    var fake: RetainedHistory = .{ .body = &.{ 120, 0, 0, 60, 0, 20, 0, 0 }, .rounds = 65 };
    var options = try testOptions(a, tmp);
    options.all_history = true;
    try download(a, std.testing.io, &fake, options, &out.writer);
    try std.testing.expectEqual(@as(usize, 65), fake.completed);
    const source = try tmp.dir.readFileAlloc(std.testing.io, "capture/download.json", a, .limited(128 * 1024));
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
    try std.testing.expect(value.object.get("complete").?.bool);
    try std.testing.expectEqualStrings("all_available_activity_history", value.object.get("request_scope").?.string);
    try std.testing.expectEqual(@as(usize, 65), value.object.get("samples").?.array.items.len);
}

test "a nonadvancing history cursor stops an all-history download" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(a);
    var fake: RetainedHistory = .{ .body = &.{ 120, 0, 0, 60, 0, 20, 0, 0 }, .no_progress = true };
    var options = try testOptions(a, tmp);
    options.all_history = true;
    try std.testing.expectError(error.HistoryNoProgress, download(a, std.testing.io, &fake, options, &out.writer));
    try std.testing.expectEqual(@as(usize, 1), fake.completed);
}

const Fake = struct {
    frame: usize = 0,
    writes: usize = 0,
    bad_crc: bool = false,
    sequence_gap: bool = false,
    bad_length: bool = false,
    start_header: [16]u8 = undefined,
    completion: [7]u8 = undefined,
    second_packet: [9]u8 = undefined,
    const activity = [_]u8{ 120, 4, 0, 60, 0, 20, 0, 0, 120, 0, 0, 62, 0, 20, 50, 60 };
    pub fn write(self: *@This(), bytes: []const u8) !void {
        self.writes += 1;
        switch (bytes[0]) {
            1 => {
                try std.testing.expectEqual(@as(usize, 10), bytes.len);
                try std.testing.expectEqual(@as(u8, 1), bytes[1]);
            },
            2 => try std.testing.expectEqual(@as(usize, 1), bytes.len),
            3 => try std.testing.expectEqualSlices(u8, &.{ 3, 9 }, bytes),
            else => return error.UnexpectedWrite,
        }
    }
    pub fn startData(_: *@This()) !void {}
    pub fn stopData(_: *@This()) !void {}
    pub fn next(self: *@This(), _: Io.Timestamp) !Frame {
        defer self.frame += 1;
        return switch (self.frame) {
            0 => blk: {
                self.start_header = .{ 0x10, 1, 1, 2, 0, 0, 0, 0xe4, 7, 1, 2, 0, 0, 0, 0, 0 };
                if (self.bad_length) self.start_header[3] = 3;
                break :blk .{ .metadata = &self.start_header };
            },
            1 => .{ .data = &.{ 0, 120, 4, 0, 60, 0, 20, 0, 0 } },
            2 => blk: {
                self.second_packet[0] = if (self.sequence_gap) 3 else 1;
                @memcpy(self.second_packet[1..], activity[8..]);
                break :blk .{ .data = &self.second_packet };
            },
            3 => blk: {
                @memcpy(self.completion[0..3], &[_]u8{ 0x10, 2, 1 });
                const crc = std.hash.Crc32.hash(&activity) ^ @as(u32, if (self.bad_crc) 1 else 0);
                std.mem.writeInt(u32, self.completion[3..7], crc, .little);
                break :blk .{ .metadata = &self.completion };
            },
            4, 6 => .{ .metadata = &.{ 0x10, 3, 1 } },
            5 => .{ .metadata = &.{ 0x10, 1, 1, 0, 0, 0, 0, 0xe4, 7, 1, 2, 0, 2, 0, 0, 0 } },
            else => error.UnexpectedRead,
        };
    }
};

fn testOptions(a: A, tmp: std.testing.TmpDir) !Options {
    return .{
        .since = .{ .year = 2020, .month = 1, .day = 2, .hour = 0, .minute = 0, .second = 0, .weekday = 4, .utc_quarters = 0 },
        .output_dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "capture" }),
    };
}

test "sleep download exports complete records, preserves raw bytes and always acknowledges keep-data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(a);
    var fake: Fake = .{};
    try download(a, std.testing.io, &fake, try testOptions(a, tmp), &out.writer);
    try std.testing.expectEqual(@as(usize, 5), fake.writes);
    const raw = try tmp.dir.readFileAlloc(std.testing.io, "capture/block-0001.bin", a, .limited(1024));
    try std.testing.expectEqualSlices(u8, &Fake.activity, raw);
    const source = try tmp.dir.readFileAlloc(std.testing.io, "capture/download.json", a, .limited(16 * 1024));
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
    try std.testing.expect(value.object.get("complete").?.bool);
    try std.testing.expectEqual(@as(usize, 2), value.object.get("samples").?.array.items.len);
    const csv = try tmp.dir.readFileAlloc(std.testing.io, "capture/sleep.csv", a, .limited(16 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, csv, ",light\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, ",rem\n") != null);
}

test "sleep CRC failures preserve raw data and mark the export incomplete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(a);
    var fake: Fake = .{ .bad_crc = true };
    try std.testing.expectError(error.HistoryChecksumMismatch, download(a, std.testing.io, &fake, try testOptions(a, tmp), &out.writer));
    const raw = try tmp.dir.readFileAlloc(std.testing.io, "capture/block-0001.partial.bin", a, .limited(1024));
    try std.testing.expectEqualSlices(u8, &Fake.activity, raw);
    const source = try tmp.dir.readFileAlloc(std.testing.io, "capture/download.json", a, .limited(16 * 1024));
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
    try std.testing.expect(!value.object.get("complete").?.bool);
    try std.testing.expectEqualStrings("HistoryChecksumMismatch", value.object.get("failure").?.string);
}

test "sleep packet gaps stop decoding and preserve the received partial block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(a);
    var fake: Fake = .{ .sequence_gap = true };
    try std.testing.expectError(error.InvalidHistoryPacketSequence, download(a, std.testing.io, &fake, try testOptions(a, tmp), &out.writer));
    const raw = try tmp.dir.readFileAlloc(std.testing.io, "capture/block-0001.partial.bin", a, .limited(1024));
    try std.testing.expectEqualSlices(u8, Fake.activity[0..8], raw);
}

test "sleep counts must match the band announcement even with a valid CRC" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(a);
    var fake: Fake = .{ .bad_length = true };
    try std.testing.expectError(error.HistoryLengthMismatch, download(a, std.testing.io, &fake, try testOptions(a, tmp), &out.writer));
    const raw = try tmp.dir.readFileAlloc(std.testing.io, "capture/block-0001.partial.bin", a, .limited(1024));
    try std.testing.expectEqualSlices(u8, &Fake.activity, raw);
}
