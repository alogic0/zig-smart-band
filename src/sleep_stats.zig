//! Offline wake-up-date totals from saved activity history. Merge before counting so
//! repeated downloads and later sleep reclassifications cannot inflate totals.
const std = @import("std");
const clock = @import("band_time.zig");
const sleep = @import("sleep.zig");
const Io = std.Io;
const A = std.mem.Allocator;

pub const Options = struct {
    input_dir: []const u8,
    since: ?u32 = null,
    until: ?u32 = null,
    csv: bool = false,
};

fn dateKey(date: clock.Calendar) u32 {
    return @as(u32, date.year) * 10000 + @as(u32, date.month) * 100 + date.day;
}

fn parseDate(text: []const u8) !u32 {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidSleepStatsDate;
    for (text, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return error.InvalidSleepStatsDate;
    const date = clock.localDate(
        std.fmt.parseInt(u16, text[0..4], 10) catch return error.InvalidSleepStatsDate,
        std.fmt.parseInt(u8, text[5..7], 10) catch return error.InvalidSleepStatsDate,
        std.fmt.parseInt(u8, text[8..10], 10) catch return error.InvalidSleepStatsDate,
    ) catch return error.InvalidSleepStatsDate;
    return dateKey(date);
}

pub fn parse(a: A, env: *const std.process.Environ.Map, args: []const []const u8) !Options {
    var input: ?[]const u8 = null;
    var since: ?u32 = null;
    var until: ?u32 = null;
    var csv = false;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--csv") and !csv) {
            csv = true;
            i += 1;
            continue;
        }
        if (i + 1 == args.len) return error.InvalidSleepStatsArguments;
        const value = args[i + 1];
        if (std.mem.eql(u8, arg, "--input") and input == null and value.len != 0) {
            input = value;
        } else if (std.mem.eql(u8, arg, "--since") and since == null) {
            since = try parseDate(value);
        } else if (std.mem.eql(u8, arg, "--until") and until == null) {
            until = try parseDate(value);
        } else return error.InvalidSleepStatsArguments;
        i += 2;
    }
    if (since != null and until != null and since.? > until.?) return error.InvalidSleepStatsArguments;
    if (input == null) {
        const xdg = env.get("XDG_DATA_HOME");
        input = if (xdg != null and std.fs.path.isAbsolute(xdg.?))
            try std.fs.path.join(a, &.{ xdg.?, "smart-band", "sleep" })
        else
            try std.fs.path.join(a, &.{ env.get("HOME") orelse return error.ConfigDirectoryUnavailable, ".local", "share", "smart-band", "sleep" });
    }
    return .{ .input_dir = input.?, .since = since, .until = until, .csv = csv };
}

const Source = struct {
    path: []const u8,
    captured_at: i96,

    fn lessThan(_: void, left: Source, right: Source) bool {
        if (left.captured_at != right.captured_at) return left.captured_at < right.captured_at;
        return std.mem.lessThan(u8, left.path, right.path);
    }
};

fn addSource(a: A, io: Io, files: *std.ArrayList(Source), path: []const u8) !bool {
    const info = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (info.kind != .file) return error.InvalidSleepCapture;
    // Default capture names retain their original order even after copying.
    // Custom --output directories fall back to download.json's modification time.
    const name = std.fs.path.basename(std.fs.path.dirname(path) orelse ".");
    const milliseconds = if (name.len > 17 and std.mem.startsWith(u8, name, "sleep-") and name[16] == '-')
        std.fmt.parseInt(i64, name[17..], 10) catch null
    else
        null;
    const owned = try a.dupe(u8, path);
    errdefer a.free(owned);
    try files.append(a, .{
        .path = owned,
        .captured_at = if (milliseconds) |ms| @as(i96, ms) * 1_000_000 else info.mtime.nanoseconds,
    });
    return true;
}

fn findSources(a: A, io: Io, files: *std.ArrayList(Source), root: []const u8) !void {
    const dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.NoSleepDownloads,
        else => return err,
    };
    defer dir.close(io);
    const direct = try std.fs.path.join(a, &.{ root, "download.json" });
    defer a.free(direct);
    if (try addSource(a, io, files, direct)) return;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(a, &.{ root, entry.name, "download.json" });
        defer a.free(path);
        _ = try addSource(a, io, files, path);
    }
    if (files.items.len == 0) return error.NoSleepDownloads;
    std.mem.sort(Source, files.items, {}, Source.lessThan);
}

const Download = struct {
    version: ?u8 = null,
    complete: bool,
    status: ?[]const u8 = null,
    sample_interval_seconds: ?u32 = null,
    samples: ?[]const sleep.Sample = null,
};
const Samples = std.AutoHashMap(i64, sleep.Sample);
const LoadResult = enum { complete, partial, in_progress };

fn load(a: A, io: Io, file: []const u8, samples: *Samples) !LoadResult {
    const source = try Io.Dir.cwd().readFileAlloc(io, file, a, .unlimited);
    defer a.free(source);
    const parsed = std.json.parseFromSlice(Download, a, source, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidSleepCapture,
    };
    defer parsed.deinit();
    const record = parsed.value;
    if (!record.complete and record.version == null and record.samples == null and
        record.status != null and std.mem.eql(u8, record.status.?, "in_progress")) return .in_progress;
    if (record.version != 1 or record.sample_interval_seconds != 60 or record.samples == null) return error.InvalidSleepCapture;
    // Validate the whole file before merging; a malformed file is never counted.
    for (record.samples.?) |sample| {
        if (sample.timestamp_utc < 0 or sample.timestamp_utc > 253402214340 or @mod(sample.timestamp_utc, 60) != 0) return error.InvalidSleepCapture;
    }
    for (record.samples.?) |sample| try samples.put(sample.timestamp_utc, sample);
    return if (record.complete) .complete else .partial;
}

const Day = struct {
    date: clock.Calendar,
    expected: u16,
    recorded: u16 = 0,
    asleep: u64 = 0,
    light: u64 = 0,
    deep: u64 = 0,
    rem: u64 = 0,
    incomplete_sleep: bool = false,

    fn coverage(self: Day) []const u8 {
        return if (self.recorded == 0) "missing" else if (self.recorded == self.expected) "full" else "partial";
    }

    fn addSleep(self: *Day, sample: sleep.Sample) void {
        self.asleep += 1;
        const stage = sample.stage();
        if (std.mem.eql(u8, stage, "rem")) {
            self.rem += 1;
        } else if (std.mem.eql(u8, stage, "deep")) {
            self.deep += 1;
        } else self.light += 1;
    }
};

fn sampleLessThan(_: void, left: sleep.Sample, right: sleep.Sample) bool {
    return left.timestamp_utc < right.timestamp_utc;
}

fn summarize(a: A, samples: []const sleep.Sample, options: Options, now: i64) !std.ArrayList(Day) {
    var days: std.ArrayList(Day) = .empty;
    errdefer days.deinit(a);
    if (samples.len == 0) return days;
    const first = try clock.localAt(samples[0].timestamp_utc);
    var date = try clock.localDate(first.year, first.month, first.day);
    var start = try date.unixSeconds();
    var index: usize = 0;
    while (index < samples.len) {
        const next = try clock.nextLocalDate(date);
        const end = try next.unixSeconds();
        if (end <= start or @mod(end - start, 60) != 0) return error.UnsupportedLocalTime;
        var day: Day = .{ .date = date, .expected = @intCast(@divExact(end - start, 60)) };
        while (index < samples.len and samples[index].timestamp_utc < end) : (index += 1) day.recorded += 1;
        try days.append(a, day);
        date = next;
        start = end;
    }

    // Activity history has no native main-window metadata. Infer periods only
    // from contiguous sleep minutes, bounded by observed non-sleep minutes.
    // Never bridge missing data or infer a wake-up at the end of a capture.
    index = 0;
    var wake_day: usize = 0;
    while (index < samples.len) {
        if (!samples[index].sleeping()) {
            index += 1;
            continue;
        }
        const begin = index;
        index += 1;
        while (index < samples.len and samples[index].sleeping() and
            samples[index].timestamp_utc == samples[index - 1].timestamp_utc + 60) : (index += 1)
        {}
        const wake = samples[index - 1].timestamp_utc + 60;
        const ended = index < samples.len and !samples[index].sleeping() and samples[index].timestamp_utc == wake;
        const began = begin > 0 and !samples[begin - 1].sleeping() and
            samples[begin - 1].timestamp_utc + 60 == samples[begin].timestamp_utc;
        const wake_key = dateKey(try clock.localAt(wake));
        while (wake_day + 1 < days.items.len and dateKey(days.items[wake_day].date) < wake_key) wake_day += 1;
        if (began and ended and wake <= now) {
            for (samples[begin..index]) |sample| days.items[wake_day].addSleep(sample);
        } else {
            // Full calendar coverage alone cannot establish a complete night's
            // sleep when a period's start or wake-up boundary is missing.
            days.items[wake_day].incomplete_sleep = true;
        }
    }
    // Filter only after attributing whole periods, so --since includes the
    // previous evening's sleep when it ends on the requested date.
    var kept: usize = 0;
    for (days.items) |day| {
        const key = dateKey(day.date);
        if ((options.since == null or key >= options.since.?) and (options.until == null or key <= options.until.?)) {
            days.items[kept] = day;
            kept += 1;
        }
    }
    days.shrinkRetainingCapacity(kept);
    return days;
}

fn printDuration(out: *Io.Writer, minutes: u64) !void {
    try out.print("{d: >2}:{d:0>2}", .{ minutes / 60, minutes % 60 });
}

fn printDays(out: *Io.Writer, days: []const Day, csv: bool) !void {
    if (csv) {
        try out.writeAll("date,sleep_minutes,light_minutes_estimate,deep_minutes_estimate,rem_minutes_estimate,recorded_minutes,expected_minutes,coverage\n");
    } else {
        try out.print("{s: <10}  {s: >5}  {s: >5}  {s: >5}  {s: >5}  Activity coverage\n", .{ "Date", "Sleep", "Light", "Deep", "REM" });
    }
    var full_days: u64 = 0;
    var full_sleep: u64 = 0;
    for (days) |day| {
        try out.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ day.date.year, day.date.month, day.date.day });
        if (csv) {
            if (day.recorded == 0) {
                try out.writeAll(",,,,");
            } else {
                try out.print(",{d},{d},{d},{d}", .{ day.asleep, day.light, day.deep, day.rem });
            }
            try out.print(",{d},{d},{s}\n", .{ day.recorded, day.expected, day.coverage() });
        } else {
            inline for (.{ day.asleep, day.light, day.deep, day.rem }) |minutes| {
                try out.writeAll("  ");
                if (day.recorded == 0) try out.writeAll("   --") else try printDuration(out, minutes);
            }
            try out.print("  {s} ({d}/{d} min)\n", .{ day.coverage(), day.recorded, day.expected });
        }
        if (day.recorded == day.expected and !day.incomplete_sleep) {
            full_days += 1;
            full_sleep += day.asleep;
        }
    }
    if (csv) return;
    if (days.len == 0) try out.writeAll("No recorded days match this date range.\n");
    if (full_days > 0) {
        try out.print("\nAverage completed sleep across {d} full days: ", .{full_days});
        const average = (full_sleep + full_days / 2) / full_days;
        try out.print("{d}:{d:0>2}\n", .{ average / 60, average % 60 });
    }
    try out.writeAll("\nCompleted sleep periods are assigned to their local wake-up date, including sleep before midnight.\nAwake minutes and periods with missing boundaries or an unrecorded wake-up are excluded.\nLight/deep/REM and period boundaries are inferred from activity records; native app totals may differ.\nFull coverage means all activity minutes of the calendar day are present.\n");
}

pub fn run(a: A, io: Io, options: Options, out: *Io.Writer) !void {
    var files: std.ArrayList(Source) = .empty;
    defer {
        for (files.items) |file| a.free(file.path);
        files.deinit(a);
    }
    try findSources(a, io, &files, options.input_dir);
    var samples = Samples.init(a);
    defer samples.deinit();
    var partial: usize = 0;
    var in_progress: usize = 0;
    for (files.items) |file| {
        const result = load(a, io, file.path, &samples) catch |err| {
            std.debug.print("Could not read sleep download {s} ({t}).\n", .{ file.path, err });
            return err;
        };
        switch (result) {
            .complete => {},
            .partial => partial += 1,
            .in_progress => in_progress += 1,
        }
    }
    if (samples.count() == 0) return error.NoSleepSamples;
    const ordered = try a.alloc(sleep.Sample, samples.count());
    defer a.free(ordered);
    var iterator = samples.valueIterator();
    var i: usize = 0;
    while (iterator.next()) |sample| : (i += 1) ordered[i] = sample.*;
    std.mem.sort(sleep.Sample, ordered, {}, sampleLessThan);
    var days = try summarize(a, ordered, options, Io.Timestamp.now(io, .real).toSeconds());
    defer days.deinit(a);
    if (!options.csv) {
        try out.print("Merged {d} downloads: {d} unique activity minutes; newest capture wins overlaps.\n", .{ files.items.len - in_progress, samples.count() });
        if (partial != 0) try out.print("Includes {d} partial captures; only exported samples are counted.\n", .{partial});
        if (in_progress != 0) try out.print("Skipped {d} in-progress captures.\n", .{in_progress});
        try out.writeAll("\n");
    }
    try printDays(out, days.items, options.csv);
}

test "statistics CLI validates inclusive ranges and uses the download data directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    const defaults = try parse(a, &env, &.{});
    try std.testing.expectEqualStrings("/home/tester/.local/share/smart-band/sleep", defaults.input_dir);
    try env.put("XDG_DATA_HOME", "/data");
    try std.testing.expectEqualStrings("/data/smart-band/sleep", (try parse(a, &env, &.{})).input_dir);
    try env.put("XDG_DATA_HOME", "relative");
    try std.testing.expectEqualStrings(defaults.input_dir, (try parse(a, &env, &.{})).input_dir);
    const options = try parse(a, &env, &.{ "--since", "2026-10-27", "--until", "2026-11-02", "--input", "capture", "--csv" });
    try std.testing.expectEqual(@as(?u32, 20261027), options.since);
    try std.testing.expectEqual(@as(?u32, 20261102), options.until);
    try std.testing.expectEqualStrings("capture", options.input_dir);
    try std.testing.expect(options.csv);
    try std.testing.expectError(error.InvalidSleepStatsDate, parse(a, &env, &.{ "--since", "2026-02-29" }));
    try std.testing.expectError(error.InvalidSleepStatsArguments, parse(a, &env, &.{ "--since", "2026-11-02", "--until", "2026-11-01" }));
    try std.testing.expectError(error.InvalidSleepStatsArguments, parse(a, &env, &.{"--input"}));
    try std.testing.expectError(error.InvalidSleepStatsArguments, parse(a, &env, &.{ "--csv", "--csv" }));
    try std.testing.expectError(error.InvalidSleepStatsArguments, parse(a, &env, &.{"--all"}));
}

fn testSample(timestamp: i64, kind: u8, deep: u8, rem: u8) sleep.Sample {
    return .{ .timestamp_utc = timestamp, .raw = .{ kind, 0, 0, 60, 0, 0, deep, rem } };
}

fn testRoot(a: A, tmp: std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

fn writeTestCapture(a: A, tmp: std.testing.TmpDir, name: []const u8, complete: bool, samples: []const sleep.Sample) !void {
    try tmp.dir.createDirPath(std.testing.io, name);
    const path = try std.fs.path.join(a, &.{ name, "download.json" });
    defer a.free(path);
    const source = try std.json.Stringify.valueAlloc(a, .{ .version = 1, .complete = complete, .sample_interval_seconds = 60, .samples = samples }, .{});
    defer a.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = source });
}

test "repeated downloads count minutes once and newer raw samples replace sleep and stage classifications" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(a, tmp);
    defer a.free(root);
    const start = try (try clock.localDate(2026, 10, 27)).unixSeconds();
    const newer = [_]sleep.Sample{
        testSample(start, 80, 0, 0), // Reclassified as awake.
        testSample(start + 60, 120, 0, 0),
        testSample(start + 120, 120, 0, 60), // Reclassified as REM.
        testSample(start + 180, 120, 43, 0),
        testSample(start + 240, 80, 0, 0), // Observed wake-up completes the period.
    };
    // Create these in reverse order so filesystem order/mtime cannot pick the winner.
    try writeTestCapture(a, tmp, "sleep-2026-10-27-2000", false, &newer);
    const older = [_]sleep.Sample{
        testSample(start, 120, 43, 0),
        testSample(start + 60, 120, 0, 0),
        testSample(start + 120, 120, 0, 0),
    };
    try writeTestCapture(a, tmp, "sleep-2026-10-27-1000", true, &older);
    try tmp.dir.createDirPath(std.testing.io, "pending");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pending/download.json", .data = "{\"complete\":false,\"status\":\"in_progress\"}" });
    var output: Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try run(a, std.testing.io, .{ .input_dir = root, .csv = true }, &output.writer);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "2026-10-27,3,1,1,1,5,1440,partial\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), "\n"));

    const direct = try std.fs.path.join(a, &.{ root, "sleep-2026-10-27-2000" });
    defer a.free(direct);
    var single: Io.Writer.Allocating = .init(a);
    defer single.deinit();
    try run(a, std.testing.io, .{ .input_dir = direct, .csv = true }, &single.writer);
    try std.testing.expectEqualStrings(output.written(), single.written());
}

test "whole periods use their wake-up date, missing days stay unknown and recorded zero sleep stays zero" {
    const a = std.testing.allocator;
    const midnight = try (try clock.localDate(2026, 10, 30)).unixSeconds();
    const awake = try (try clock.localDate(2026, 11, 1)).unixSeconds();
    const end = try (try clock.localDate(2026, 11, 2)).unixSeconds();
    const samples = [_]sleep.Sample{
        testSample(midnight - 120, 80, 0, 0),
        testSample(midnight - 60, 120, 0, 0),
        testSample(midnight, 120, 43, 0),
        testSample(midnight + 60, 80, 0, 0),
        testSample(awake, 80, 0, 0),
        testSample(end, 80, 0, 0),
    };
    var days = try summarize(a, &samples, .{ .input_dir = "", .since = 20261030, .until = 20261101 }, end);
    defer days.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), days.items.len);
    try std.testing.expectEqual(@as(u64, 2), days.items[0].asleep);
    try std.testing.expectEqual(@as(u64, 1), days.items[0].light);
    try std.testing.expectEqual(@as(u16, 1), days.items[0].deep);
    try std.testing.expectEqualStrings("missing", days.items[1].coverage());
    try std.testing.expectEqual(@as(u16, 0), days.items[2].asleep);
    try std.testing.expectEqual(@as(u16, 1), days.items[2].recorded);
    var output: Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try printDays(&output.writer, days.items, true);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "2026-10-31,,,,,0,1440,missing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "2026-11-01,0,0,0,0,1,") != null);
}

test "overnight sleep and a completed nap use the wake-up date across a DST change" {
    const a = std.testing.allocator;
    const midnight = try (try clock.localDate(2026, 11, 1)).unixSeconds();
    const next = try (try clock.localDate(2026, 11, 2)).unixSeconds();
    var wake_date = try clock.localAt(next - 18 * 3600); // 06:00 on a 24/25-hour day.
    wake_date.hour = 6;
    const wake = try wake_date.unixSeconds();
    var nap_date = try clock.localAt(wake);
    nap_date.hour = 13;
    const nap = try nap_date.unixSeconds();
    const bedtime = midnight - 2 * 3600;
    const first = bedtime - 60;
    const count: usize = @intCast(@divExact(nap + 30 * 60 - first, 60) + 1);
    const samples = try a.alloc(sleep.Sample, count);
    defer a.free(samples);
    for (samples, 0..) |*sample, i| {
        const timestamp = first + @as(i64, @intCast(i)) * 60;
        const night = timestamp >= bedtime and timestamp < wake;
        const napping = timestamp >= nap and timestamp < nap + 30 * 60;
        sample.* = testSample(timestamp, if (night or napping) 120 else 80, if (night and timestamp < bedtime + 60 * 60) 43 else 0, if (night and timestamp >= bedtime + 60 * 60 and timestamp < bedtime + 90 * 60) 60 else 0);
    }
    var days = try summarize(a, samples, .{ .input_dir = "", .since = 20261101, .until = 20261101 }, nap + 31 * 60);
    defer days.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), days.items.len);
    const total: u64 = @intCast(@divExact(wake - bedtime, 60) + 30);
    try std.testing.expectEqual(total, days.items[0].asleep);
    try std.testing.expectEqual(@as(u64, 60), days.items[0].deep);
    try std.testing.expectEqual(@as(u64, 30), days.items[0].rem);
    try std.testing.expectEqual(total - 90, days.items[0].light);
    try std.testing.expectEqual(@as(u16, @intCast(@divExact(next - midnight, 60))), days.items[0].expected);
}

test "waking exactly at midnight assigns every inclusive sleep minute to the new date" {
    const a = std.testing.allocator;
    const midnight = try (try clock.localDate(2026, 10, 30)).unixSeconds();
    const samples = [_]sleep.Sample{
        testSample(midnight - 180, 80, 0, 0),
        testSample(midnight - 120, 120, 0, 0),
        testSample(midnight - 60, 120, 0, 60),
        testSample(midnight, 80, 0, 0),
    };
    var days = try summarize(a, &samples, .{ .input_dir = "", .since = 20261030 }, midnight);
    defer days.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), days.items.len);
    try std.testing.expectEqual(@as(u64, 2), days.items[0].asleep);
    try std.testing.expectEqual(@as(u64, 1), days.items[0].rem);
}

test "truncated, gapped, unfinished and future periods are excluded while a complete one-minute nap counts" {
    const a = std.testing.allocator;
    const start = try (try clock.localDate(2026, 10, 30)).unixSeconds();
    const samples = [_]sleep.Sample{
        testSample(start, 120, 0, 0), // No observed start.
        testSample(start + 60, 80, 0, 0),
        testSample(start + 180, 120, 0, 0), // Gap before sleep.
        testSample(start + 240, 80, 0, 0),
        testSample(start + 300, 120, 43, 0), // A complete one-minute nap.
        testSample(start + 360, 80, 0, 0),
        testSample(start + 420, 120, 0, 0), // Unobserved wake-up across a gap.
        testSample(start + 540, 80, 0, 0),
        testSample(start + 600, 120, 0, 60),
        testSample(start + 660, 80, 0, 0), // Future wake-up relative to now.
        testSample(start + 720, 120, 0, 0), // Still sleeping at the capture's end.
    };
    var days = try summarize(a, &samples, .{ .input_dir = "" }, start + 630);
    defer days.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), days.items.len);
    try std.testing.expectEqual(@as(u64, 1), days.items[0].asleep);
    try std.testing.expectEqual(@as(u64, 1), days.items[0].deep);
    try std.testing.expect(days.items[0].incomplete_sleep);
}

test "malformed or unsupported captures fail without contributing samples" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(a, tmp);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "download.json" });
    defer a.free(path);
    var samples = Samples.init(a);
    defer samples.deinit();
    const invalid = [_][]const u8{
        "{",
        "{\"version\":2,\"complete\":true,\"sample_interval_seconds\":60,\"samples\":[]}",
        "{\"version\":1,\"complete\":true,\"sample_interval_seconds\":30,\"samples\":[]}",
        "{\"version\":1,\"complete\":true,\"sample_interval_seconds\":60,\"samples\":[{\"timestamp_utc\":0,\"raw\":[120]}]}",
        "{\"version\":1,\"complete\":true,\"sample_interval_seconds\":60,\"samples\":[{\"timestamp_utc\":0,\"raw\":[120,0,0,0,0,0,0,0]},{\"timestamp_utc\":-1,\"raw\":[120,0,0,0,0,0,0,0]}]}",
    };
    for (invalid) |source| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "download.json", .data = source });
        try std.testing.expectError(error.InvalidSleepCapture, load(a, std.testing.io, path, &samples));
        try std.testing.expectEqual(@as(u32, 0), samples.count());
    }
}

test "averages exclude partial and missing days and include fully recorded zero-sleep days" {
    const a = std.testing.allocator;
    const date = try clock.localDate(2026, 10, 27);
    const days = [_]Day{
        .{ .date = date, .expected = 1440, .recorded = 1440, .asleep = 480 },
        .{ .date = date, .expected = 1440, .recorded = 1440, .asleep = 0 },
        .{ .date = date, .expected = 1440, .recorded = 600, .asleep = 600 },
        .{ .date = date, .expected = 1440, .recorded = 1440, .asleep = 600, .incomplete_sleep = true },
        .{ .date = date, .expected = 1440 },
    };
    var output: Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try printDays(&output.writer, &days, false);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "across 2 full days: 4:00\n") != null);
}
