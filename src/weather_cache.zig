//! Persistent weather cache, populated before Bluetooth connection setup.
const std = @import("std");
const weather = @import("weather.zig");
const Io = std.Io;
const A = std.mem.Allocator;
const Raw = @FieldType(weather.Data, "raw");

const Record = struct {
    version: u8,
    fetched_at: i64,
    latitude: f64,
    longitude: f64,
    raw: Raw,
};
const Cached = struct { data: weather.Data, age_seconds: i64, previous_name: ?[]const u8 = null };

fn validDate(date: []const u8) bool {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return false;
    for (date, 0..) |c, i| {
        if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn datedPath(a: A, base: []const u8, date: []const u8) ![]u8 {
    if (!validDate(date)) return error.InvalidWeatherData;
    const stem = std.fs.path.stem(base);
    const name = try std.fmt.allocPrint(a, "weather-{s}{s}.json", .{ date, stem["weather".len..] });
    return std.fs.path.join(a, &.{ std.fs.path.dirname(base) orelse ".", name });
}

fn removeOldNames(a: A, io: Io, dir: Io.Dir, base: []const u8, date: []const u8) !void {
    const name = try std.fmt.allocPrint(a, "{s}-{s}.json", .{ std.fs.path.stem(base), date });
    const previous = try std.fs.path.join(a, &.{ std.fs.path.dirname(base) orelse ".", name });
    const current = try datedPath(a, base, date);
    dir.deleteFile(io, base) catch {};
    if (!std.mem.eql(u8, previous, current)) dir.deleteFile(io, previous) catch {};
}

pub fn path(a: A, env: *const std.process.Environ.Map, settings: weather.Settings) ![]u8 {
    const identity = try std.fmt.allocPrint(a, "open-meteo-celsius-v1:{d:.5},{d:.5}", .{ settings.latitude, settings.longitude });
    const name = try std.fmt.allocPrint(a, "weather-{x:0>16}.json", .{std.hash.Wyhash.hash(0, identity)});
    if (env.get("XDG_CACHE_HOME")) |root| {
        if (std.fs.path.isAbsolute(root)) return std.fs.path.join(a, &.{ root, "smart-band", name });
    }
    const home = env.get("HOME") orelse return error.CacheDirectoryUnavailable;
    return std.fs.path.join(a, &.{ home, ".cache", "smart-band", name });
}

fn fresh(record: Record, settings: weather.Settings, now: i64) bool {
    if (record.version != 1 or settings.cache_ttl_seconds == 0 or
        record.latitude != settings.latitude or record.longitude != settings.longitude or
        now < record.fetched_at or @as(i128, now) - record.fetched_at >= settings.cache_ttl_seconds or
        record.raw.daily.time.len == 0) return false;
    // Today's high/low is the first forecast entry. Refresh at local midnight,
    // even when a caller has configured a long cache lifetime.
    const local: i128 = @as(i128, now) + record.raw.utc_offset_seconds;
    if (local < 0 or local > 253402300799) return false;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(local) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var date_buffer: [10]u8 = undefined;
    const date = std.fmt.bufPrint(&date_buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, @backingInt(month_day.month), @as(u8, month_day.day_index) + 1 }) catch return false;
    return std.mem.eql(u8, record.raw.daily.time[0], date);
}

fn readFile(a: A, io: Io, dir: Io.Dir, file: []const u8, settings: weather.Settings, now: i64) !?Cached {
    const source = try dir.readFileAlloc(io, file, a, .limited(128 * 1024));
    const record = try std.json.parseFromSliceLeaky(Record, a, source, .{ .allocate = .alloc_always });
    if (!fresh(record, settings, now)) return null;
    return .{ .data = try weather.fromRaw(a, settings, record.raw), .age_seconds = now - record.fetched_at };
}

fn read(a: A, io: Io, dir: Io.Dir, base: []const u8, settings: weather.Settings, now: i64) !?Cached {
    // Use the date returned by the provider, which can differ from the computer's
    // date. Inspect this location's dated files without fetching timezone data.
    const directory = try dir.openDir(io, std.fs.path.dirname(base) orelse ".", .{ .iterate = true });
    defer directory.close(io);
    const name = std.fs.path.basename(base);
    const stem = std.fs.path.stem(name);
    var iterator = directory.iterate();
    var latest: ?Cached = null;
    while (try iterator.next(io)) |entry| {
        const undated = std.mem.eql(u8, entry.name, name);
        const dated_length = entry.name.len == stem.len + 16 and std.mem.endsWith(u8, entry.name, ".json");
        const date_first = dated_length and std.mem.startsWith(u8, entry.name, "weather-") and
            validDate(entry.name[8..18]) and std.mem.eql(u8, entry.name[18 .. entry.name.len - 5], stem["weather".len..]);
        const date_last = dated_length and std.mem.startsWith(u8, entry.name, stem) and
            entry.name[stem.len] == '-' and validDate(entry.name[stem.len + 1 ..][0..10]);
        if (!undated and !date_first and !date_last) continue;
        var candidate = (readFile(a, io, directory, entry.name, settings, now) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => null,
        }) orelse continue;
        const date = if (date_first) entry.name[8..18] else if (date_last) entry.name[stem.len + 1 ..][0..10] else null;
        if (date) |value| if (!std.mem.eql(u8, value, candidate.data.raw.daily.time[0])) continue;
        if (!date_first) candidate.previous_name = try a.dupe(u8, entry.name);
        if (latest == null or candidate.age_seconds < latest.?.age_seconds or
            (candidate.age_seconds == latest.?.age_seconds and date_first)) latest = candidate;
    }
    return latest;
}

fn save(a: A, io: Io, dir: Io.Dir, file: []const u8, data: weather.Data, now: i64) !void {
    const record: Record = .{ .version = 1, .fetched_at = now, .latitude = data.settings.latitude, .longitude = data.settings.longitude, .raw = data.raw };
    const source = try std.json.Stringify.valueAlloc(a, record, .{});
    const dated = try datedPath(a, file, data.raw.daily.time[0]);
    var atomic = try dir.createFileAtomic(io, dated, .{ .replace = true, .make_path = true, .permissions = .fromMode(0o600) });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, source);
    try atomic.replace(io);
    // The date-first copy is complete; discard obsolete names for the same day.
    try removeOldNames(a, io, dir, file, data.raw.daily.time[0]);
}

fn getAt(a: A, io: Io, dir: Io.Dir, file: []const u8, settings: weather.Settings, now: i64, out: *Io.Writer, provider: anytype) !weather.Data {
    try settings.validate();
    if (settings.cache_ttl_seconds != 0) {
        const cached = read(a, io, dir, file, settings, now) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => null, // A missing, damaged or unreadable cache triggers a new fetch.
        };
        if (cached) |entry| {
            var cached_file = try datedPath(a, file, entry.data.raw.daily.time[0]);
            if (entry.previous_name) |previous_name| {
                const previous = try std.fs.path.join(a, &.{ std.fs.path.dirname(file) orelse ".", previous_name });
                // Renaming preserves both the payload and its original age.
                dir.rename(previous, dir, cached_file, io) catch |err| switch (err) {
                    error.Canceled => return err,
                    else => {
                        std.debug.print("Could not rename weather cache {s} to {s} ({t}); using cached weather.\n", .{ previous, cached_file, err });
                        cached_file = previous;
                    },
                };
            } else {
                try removeOldNames(a, io, dir, file, entry.data.raw.daily.time[0]);
            }
            const full_path = try dir.realPathFileAlloc(io, cached_file, a);
            defer a.free(full_path);
            try out.print("Using cached weather ({d} seconds old): {s}\n", .{ entry.age_seconds, full_path });
            try out.flush();
            return entry.data;
        }
    }
    try out.writeAll("Fetching weather from Open-Meteo...\n");
    try out.flush();
    const data = try provider.fetch(settings);
    if (settings.cache_ttl_seconds != 0) {
        const dated = try datedPath(a, file, data.raw.daily.time[0]);
        // Persist a successful download before the caller opens any Bluetooth link.
        // Using the request's start time makes the age conservative.
        save(a, io, dir, file, data, now) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => {
                std.debug.print("Could not save weather cache {s} ({t}); continuing with downloaded weather.\n", .{ dated, err });
                return data;
            },
        };
        const full_path = try dir.realPathFileAlloc(io, dated, a);
        defer a.free(full_path);
        try out.print("Saved weather cache: {s}\n", .{full_path});
        try out.flush();
    }
    return data;
}

pub fn get(a: A, io: Io, env: *const std.process.Environ.Map, settings: weather.Settings, out: *Io.Writer) !weather.Data {
    const Provider = struct {
        allocator: A,
        io: Io,
        pub fn fetch(self: *@This(), location: weather.Settings) !weather.Data {
            return weather.fetch(self.allocator, self.io, location);
        }
    };
    var provider: Provider = .{ .allocator = a, .io = io };
    const file = if (settings.cache_ttl_seconds == 0) "" else try path(a, env, settings);
    return getAt(a, io, .cwd(), file, settings, Io.Timestamp.now(io, .real).toSeconds(), out, &provider);
}

const sample = @embedFile("testdata/weather.json");
const test_settings: weather.Settings = .{ .location = "Germantown, TN", .latitude = 35.08676, .longitude = -89.81009 };
const test_time: i64 = 1793644200; // 2026-11-02 12:30 in Germantown (UTC-06:00).

test "weather cache freshness checks expiry, location, schema, clock rollback and local date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = try weather.parse(arena.allocator(), test_settings, sample);
    var record: Record = .{ .version = 1, .fetched_at = test_time, .latitude = test_settings.latitude, .longitude = test_settings.longitude, .raw = data.raw };
    try std.testing.expect(fresh(record, test_settings, test_time));
    try std.testing.expect(fresh(record, test_settings, test_time + 599));
    try std.testing.expect(!fresh(record, test_settings, test_time + 600));
    try std.testing.expect(!fresh(record, test_settings, test_time - 1));
    var settings = test_settings;
    settings.cache_ttl_seconds = 0;
    try std.testing.expect(!fresh(record, settings, test_time));
    settings.cache_ttl_seconds = 1200;
    try std.testing.expect(fresh(record, settings, test_time + 1199));
    settings.latitude += 0.01;
    try std.testing.expect(!fresh(record, settings, test_time));
    record.version = 2;
    try std.testing.expect(!fresh(record, test_settings, test_time));
    record.version = 1;
    record.fetched_at = test_time + 11 * 3600 + 29 * 60; // 23:59 local.
    try std.testing.expect(fresh(record, test_settings, record.fetched_at));
    try std.testing.expect(!fresh(record, test_settings, record.fetched_at + 60));
}

const FakeProvider = struct {
    allocator: A,
    calls: usize = 0,
    fail: bool = false,
    pub fn fetch(self: *@This(), settings: weather.Settings) !weather.Data {
        self.calls += 1;
        if (self.fail) return error.WeatherProviderFailed;
        return weather.parse(self.allocator, settings, sample);
    }
};

test "successful weather download persists before caller connects and a quick retry skips the provider" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: Io.Writer.Allocating = .init(a);
    var provider: FakeProvider = .{ .allocator = a };
    const data = try getAt(a, std.testing.io, tmp.dir, "nested/weather.json", test_settings, test_time, &output.writer, &provider);
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    const stored = (try read(a, std.testing.io, tmp.dir, "nested/weather.json", test_settings, test_time)).?;
    try std.testing.expectEqual(data.raw.current.temperature_2m, stored.data.raw.current.temperature_2m);

    // A connection failure after getAt returns cannot discard the disk cache.
    // A separate invocation/provider can use it even if the network is now down.
    var offline: FakeProvider = .{ .allocator = a, .fail = true };
    const cached = try getAt(a, std.testing.io, tmp.dir, "nested/weather.json", test_settings, test_time + 30, &output.writer, &offline);
    try std.testing.expectEqual(@as(usize, 0), offline.calls);
    try std.testing.expectEqualStrings(data.raw.current.time, cached.raw.current.time);
    try std.testing.expectError(error.WeatherProviderFailed, getAt(a, std.testing.io, tmp.dir, "nested/weather.json", test_settings, test_time + 600, &output.writer, &offline));
    try std.testing.expectEqual(@as(usize, 1), offline.calls);
    // Failed refresh leaves the last successful entry intact.
    try std.testing.expect(try read(a, std.testing.io, tmp.dir, "nested/weather.json", test_settings, test_time + 30) != null);
}

test "corrupt, wrong-location and disabled weather caches trigger downloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: Io.Writer.Allocating = .init(a);
    var provider: FakeProvider = .{ .allocator = a };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "weather.json", .data = "{broken cache" });
    _ = try getAt(a, std.testing.io, tmp.dir, "weather.json", test_settings, test_time, &output.writer, &provider);
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    var changed = test_settings;
    changed.longitude += 1;
    _ = try getAt(a, std.testing.io, tmp.dir, "weather.json", changed, test_time, &output.writer, &provider);
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    // A disabled cache ignores existing data and never overwrites it.
    var disabled = changed;
    disabled.cache_ttl_seconds = 0;
    _ = try getAt(a, std.testing.io, tmp.dir, "weather.json", disabled, test_time + 10, &output.writer, &provider);
    try std.testing.expectEqual(@as(usize, 3), provider.calls);
    const preserved = (try read(a, std.testing.io, tmp.dir, "weather.json", changed, test_time + 10)).?;
    try std.testing.expectEqual(@as(i64, 10), preserved.age_seconds);
}

test "weather cache path honors XDG and separates locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/home/example");
    const home_path = try path(a, &env, test_settings);
    try std.testing.expect(std.mem.startsWith(u8, home_path, "/home/example/.cache/smart-band/weather-"));
    try env.put("XDG_CACHE_HOME", "/tmp/cache");
    const xdg_path = try path(a, &env, test_settings);
    try std.testing.expect(std.mem.startsWith(u8, xdg_path, "/tmp/cache/smart-band/weather-"));
    var other = test_settings;
    other.latitude += 1;
    try std.testing.expect(!std.mem.eql(u8, xdg_path, try path(a, &env, other)));
    try env.put("XDG_CACHE_HOME", "relative");
    try std.testing.expectEqualStrings(home_path, try path(a, &env, test_settings));
}

test "weather cache filenames include the forecast date and reject path separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("nested/weather-2026-11-02-abcd.json", try datedPath(a, "nested/weather-abcd.json", "2026-11-02"));
    const earlier = try datedPath(a, "weather-ffff.json", "2026-11-01");
    const later = try datedPath(a, "weather-0000.json", "2026-11-02");
    try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, earlier, later));
    try std.testing.expectError(error.InvalidWeatherData, datedPath(a, "weather.json", "../../file"));
    try std.testing.expectError(error.InvalidWeatherData, datedPath(a, "weather.json", "2026-1-02"));
}

test "date-last cache names migrate to date-first without refreshing the data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try weather.parse(a, test_settings, sample);
    const record: Record = .{ .version = 1, .fetched_at = test_time, .latitude = test_settings.latitude, .longitude = test_settings.longitude, .raw = data.raw };
    const source = try std.json.Stringify.valueAlloc(a, record, .{});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "weather-abcd-2026-11-02.json", .data = source });
    var provider: FakeProvider = .{ .allocator = a, .fail = true };
    var output: Io.Writer.Allocating = .init(a);
    _ = try getAt(a, std.testing.io, tmp.dir, "weather-abcd.json", test_settings, test_time + 30, &output.writer, &provider);
    try std.testing.expectEqual(@as(usize, 0), provider.calls);
    const moved = try tmp.dir.readFileAlloc(std.testing.io, "weather-2026-11-02-abcd.json", a, .limited(128 * 1024));
    try std.testing.expectEqualStrings(source, moved);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "weather-abcd-2026-11-02.json", a, .limited(128 * 1024)));
    const cached = (try read(a, std.testing.io, tmp.dir, "weather-abcd.json", test_settings, test_time + 45)).?;
    try std.testing.expectEqual(@as(i64, 45), cached.age_seconds);
    try std.testing.expect(cached.previous_name == null);
    // A current date-first entry also cleans up an older date-last duplicate.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "weather-abcd-2026-11-02.json", .data = source });
    _ = try getAt(a, std.testing.io, tmp.dir, "weather-abcd.json", test_settings, test_time + 45, &output.writer, &provider);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "weather-abcd-2026-11-02.json", a, .limited(128 * 1024)));
}

test "undated weather caches migrate without downloading or resetting their age" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try weather.parse(a, test_settings, sample);
    const record: Record = .{ .version = 1, .fetched_at = test_time, .latitude = test_settings.latitude, .longitude = test_settings.longitude, .raw = data.raw };
    const source = try std.json.Stringify.valueAlloc(a, record, .{});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "weather.json", .data = source });
    var provider: FakeProvider = .{ .allocator = a, .fail = true };
    var output: Io.Writer.Allocating = .init(a);
    _ = try getAt(a, std.testing.io, tmp.dir, "weather.json", test_settings, test_time + 30, &output.writer, &provider);
    try std.testing.expectEqual(@as(usize, 0), provider.calls);
    const moved = try tmp.dir.readFileAlloc(std.testing.io, "weather-2026-11-02.json", a, .limited(128 * 1024));
    try std.testing.expectEqualStrings(source, moved);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "weather.json", a, .limited(128 * 1024)));
    const cached = (try read(a, std.testing.io, tmp.dir, "weather.json", test_settings, test_time + 45)).?;
    try std.testing.expectEqual(@as(i64, 45), cached.age_seconds);
    try std.testing.expect(cached.previous_name == null);
    _ = try getAt(a, std.testing.io, tmp.dir, "weather.json", test_settings, test_time + 45, &output.writer, &provider);
    try std.testing.expectEqual(@as(usize, 0), provider.calls);
    // Expired undated entries are removed only after a fresh dated download is saved.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "weather.json", .data = source });
    provider.fail = false;
    _ = try getAt(a, std.testing.io, tmp.dir, "weather.json", test_settings, test_time + 600, &output.writer, &provider);
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "weather.json", a, .limited(128 * 1024)));
}
