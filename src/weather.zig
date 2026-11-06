//! Open-Meteo weather and the Zepp OS weather HTTP wire format.
const std = @import("std");
const Io = std.Io;
const A = std.mem.Allocator;

pub const Command = enum { sync, preview, json, background };
pub fn parseCommand(args: []const []const u8) !Command {
    if (args.len == 0) return .sync;
    if (args.len != 1) return error.InvalidArguments;
    if (std.mem.eql(u8, args[0], "--preview")) return .preview;
    if (std.mem.eql(u8, args[0], "--json")) return .json;
    if (std.mem.eql(u8, args[0], "--background")) return .background;
    return error.InvalidArguments;
}

pub const Settings = struct {
    location: []const u8,
    latitude: f64,
    longitude: f64,
    cache_ttl_seconds: u32 = 600,
    pub fn validate(self: Settings) !void {
        if (self.location.len == 0 or self.location.len > 80 or !std.unicode.utf8ValidateSlice(self.location) or
            std.mem.indexOfScalar(u8, self.location, 0) != null or
            !std.math.isFinite(self.latitude) or @abs(self.latitude) > 90 or
            !std.math.isFinite(self.longitude) or @abs(self.longitude) > 180) return error.InvalidWeatherConfiguration;
    }
};

const Raw = struct {
    utc_offset_seconds: i32,
    current: struct {
        time: []const u8,
        temperature_2m: f64,
        relative_humidity_2m: f64,
        weather_code: u8,
        surface_pressure: f64,
        wind_speed_10m: f64,
        wind_direction_10m: f64,
    },
    daily: struct {
        time: []const []const u8,
        temperature_2m_min: []const f64,
        temperature_2m_max: []const f64,
        weather_code: []const u8,
        sunrise: []const []const u8,
        sunset: []const []const u8,
        wind_speed_10m_max: []const f64,
        wind_direction_10m_dominant: []const f64,
        uv_index_max: []const f64,
    },
    hourly: struct {
        time: []const []const u8,
        temperature_2m: []const f64,
        relative_humidity_2m: []const f64,
        weather_code: []const u8,
        wind_speed_10m: []const f64,
        wind_direction_10m: []const f64,
        visibility: []const f64,
        uv_index: []const f64,
    },
};

pub const Data = struct {
    settings: Settings,
    raw: Raw,

    pub fn panelJson(self: Data, a: A) ![]u8 {
        const Day = struct { date: []const u8, low_celsius: f64, high_celsius: f64, description: []const u8 };
        const days = try a.alloc(Day, self.raw.daily.time.len);
        defer a.free(days);
        for (days, 0..) |*day, i| day.* = .{
            .date = self.raw.daily.time[i],
            .low_celsius = self.raw.daily.temperature_2m_min[i],
            .high_celsius = self.raw.daily.temperature_2m_max[i],
            .description = conditionName(self.raw.daily.weather_code[i]),
        };
        return json(a, .{
            .version = 1,
            .location = self.settings.location,
            .temperature_celsius = self.raw.current.temperature_2m,
            .description = conditionName(self.raw.current.weather_code),
            .icon_name = conditionIcon(self.raw.current.weather_code),
            .observed_at = self.raw.current.time,
            .utc_offset_seconds = self.raw.utc_offset_seconds,
            .humidity_percent = self.raw.current.relative_humidity_2m,
            .wind_kph = self.raw.current.wind_speed_10m,
            .high_celsius = days[0].high_celsius,
            .low_celsius = days[0].low_celsius,
            .daily = days,
            .provider = "Open-Meteo",
        });
    }

    pub fn preview(self: Data, out: *Io.Writer) !void {
        try out.print("{s}: {d:.1} °C, {s}; humidity {d:.0}%, wind {d:.1} km/h\nUpdated {s}; Open-Meteo.\n", .{
            self.settings.location,                self.raw.current.temperature_2m, conditionName(self.raw.current.weather_code),
            self.raw.current.relative_humidity_2m, self.raw.current.wind_speed_10m, self.raw.current.time,
        });
        for (self.raw.daily.time, self.raw.daily.temperature_2m_min, self.raw.daily.temperature_2m_max, self.raw.daily.weather_code) |date, low, high, code| {
            try out.print("{s}: {d:.0}–{d:.0} °C, {s}\n", .{ date, low, high, conditionName(code) });
        }
    }

    pub fn locationPacket(self: Data, a: A, timestamp: i64) ![]u8 {
        // A new key invalidates the band's cached weather and triggers fresh requests.
        return std.fmt.allocPrint(a, "\x09\x02\x00\x00\x00{d:.5},{d:.5},xiaomi_accu:{d}\x00{s}\x00", .{
            self.settings.latitude, self.settings.longitude, timestamp, self.settings.location,
        });
    }

    pub fn body(self: Data, a: A, path: []const u8) !?[]u8 {
        const r = self.raw;
        const pub_time = try dateTime(a, r.current.time, r.utc_offset_seconds);
        if (std.mem.eql(u8, path, "/weather/current")) {
            return try json(a, .{
                .currentWeatherModel = .{
                    .humidity = try unit(a, "%", r.current.relative_humidity_2m),
                    .pressure = try unit(a, "mb", r.current.surface_pressure),
                    .pubTime = pub_time,
                    .temperature = try unit(a, "℃", r.current.temperature_2m),
                    .uvIndex = try number(a, r.hourly.uv_index[0]),
                    .visibility = try unit(a, "km", r.hourly.visibility[0] / 1000),
                    .weather = try number(a, @floatFromInt(try conditionCode(r.current.weather_code))),
                    .wind = try wind(a, r.current.wind_direction_10m, r.current.wind_speed_10m),
                },
                // This provider request does not include air-quality measurements.
                .aqiModel = .{ .aqi = null, .co = null, .no2 = null, .o3 = null, .pm10 = null, .pm25 = null, .pubTime = null, .so2 = null },
            });
        }
        if (std.mem.eql(u8, path, "/weather/v2/forecast")) {
            const count = r.daily.time.len;
            const temperatures = try a.alloc(Range, count);
            const conditions = try a.alloc(Range, count);
            const directions = try a.alloc(Range, count);
            const speeds = try a.alloc(Range, count);
            const sun = try a.alloc(Range, count);
            for (0..count) |i| {
                temperatures[i] = .{ .from = try number(a, r.daily.temperature_2m_min[i]), .to = try number(a, r.daily.temperature_2m_max[i]) };
                const code = try number(a, @floatFromInt(try conditionCode(r.daily.weather_code[i])));
                conditions[i] = .{ .from = code, .to = code };
                const direction = try number(a, r.daily.wind_direction_10m_dominant[i]);
                directions[i] = .{ .from = direction, .to = direction };
                const speed = try number(a, r.daily.wind_speed_10m_max[i]);
                speeds[i] = .{ .from = speed, .to = speed };
                sun[i] = .{ .from = try sunTime(a, r.daily.sunrise[i]), .to = try sunTime(a, r.daily.sunset[i]) };
            }
            return try json(a, .{
                .pubTime = pub_time,
                .humidity = empty,
                .temperature = temperatures,
                .weather = conditions,
                .windDirection = directions,
                .sunRiseSet = sun,
                .windSpeed = speeds,
                .moonRiseSet = .{ .moonPhaseValue = empty, .moonRise = empty },
                .airQualities = empty,
            });
        }
        if (std.mem.eql(u8, path, "/weather/forecast/hourly")) {
            const count = r.hourly.time.len;
            const conditions = try a.alloc([]const u8, count);
            const temperatures = try a.alloc([]const u8, count);
            const humidity = try a.alloc([]const u8, count);
            const times = try a.alloc([]const u8, count);
            const directions = try a.alloc([]const u8, count);
            const speeds = try a.alloc([]const u8, count);
            const scales = try a.alloc([]const u8, count);
            for (0..count) |i| {
                conditions[i] = try number(a, @floatFromInt(try conditionCode(r.hourly.weather_code[i])));
                temperatures[i] = try number(a, r.hourly.temperature_2m[i]);
                humidity[i] = try number(a, r.hourly.relative_humidity_2m[i]);
                times[i] = try dateTime(a, r.hourly.time[i], r.utc_offset_seconds);
                directions[i] = try number(a, r.hourly.wind_direction_10m[i]);
                speeds[i] = try number(a, r.hourly.wind_speed_10m[i]);
                const force = beaufort(r.hourly.wind_speed_10m[i]);
                scales[i] = try std.fmt.allocPrint(a, "{d}-{d}", .{ force, force });
            }
            return try json(a, .{ .pubTime = pub_time, .weather = conditions, .temperature = temperatures, .humidity = humidity, .fxTime = times, .windDirection = directions, .windSpeed = speeds, .windScale = scales });
        }
        if (std.mem.eql(u8, path, "/weather/index")) return try json(a, .{ .pubTime = pub_time, .dataList = empty });
        // No alert source is fetched; do not claim there are no active alerts.
        return null;
    }
};

const empty: []const []const u8 = &.{};
const Range = struct { from: []const u8, to: []const u8 };
const Unit = struct { unit: []const u8, value: []const u8 };
fn unit(a: A, name: []const u8, value: f64) !Unit {
    return .{ .unit = name, .value = try number(a, value) };
}
fn wind(a: A, direction: f64, speed: f64) !struct { direction: Unit, speed: Unit } {
    return .{ .direction = try unit(a, "°", direction), .speed = try unit(a, "km/h", speed) };
}
fn number(a: A, value: f64) ![]u8 {
    if (!std.math.isFinite(value) or @abs(value) > 1_000_000) return error.InvalidWeatherData;
    return std.fmt.allocPrint(a, "{d}", .{@as(i32, @intFromFloat(@round(value)))});
}
fn json(a: A, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}
fn dateTime(a: A, time: []const u8, offset: i32) ![]u8 {
    if (time.len != 16 or time[10] != 'T' or @abs(offset) > 14 * 3600) return error.InvalidWeatherData;
    const minutes = @abs(offset) / 60;
    return std.fmt.allocPrint(a, "{s}:00{s}{d:0>2}{d:0>2}", .{ time, if (offset < 0) "-" else "+", minutes / 60, minutes % 60 });
}
fn sunTime(a: A, time: []const u8) ![]u8 {
    if (time.len != 16 or time[10] != 'T') return error.InvalidWeatherData;
    return std.fmt.allocPrint(a, "{s} {s}:00", .{ time[0..10], time[11..] });
}
fn beaufort(kph: f64) u8 {
    for ([_]f64{ 1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118 }, 0..) |threshold, i| if (kph < threshold) return @intCast(i);
    return 12;
}

pub fn conditionCode(wmo: u8) !u8 {
    return switch (wmo) {
        0 => 0,
        1, 2 => 1,
        3 => 2,
        45 => 18,
        48 => 32,
        51, 53, 55, 61, 80 => 7,
        63, 81 => 8,
        65, 82 => 9,
        56, 57, 66, 67 => 19,
        71, 77, 85 => 14,
        73 => 15,
        75, 86 => 16,
        95 => 4,
        96, 99 => 5,
        else => error.InvalidWeatherData,
    };
}
fn conditionName(wmo: u8) []const u8 {
    return switch (wmo) {
        0 => "clear",
        1, 2 => "partly cloudy",
        3 => "overcast",
        45, 48 => "fog",
        51, 53, 55 => "drizzle",
        61, 63, 65, 80, 81, 82 => "rain",
        56, 57, 66, 67 => "freezing rain",
        71, 73, 75, 77, 85, 86 => "snow",
        95, 96, 99 => "thunderstorm",
        else => "unknown",
    };
}

fn conditionIcon(wmo: u8) []const u8 {
    return switch (wmo) {
        0 => "weather-clear-symbolic",
        1, 2 => "weather-few-clouds-symbolic",
        3 => "weather-overcast-symbolic",
        45, 48 => "weather-fog-symbolic",
        51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82 => "weather-showers-symbolic",
        71, 73, 75, 77, 85, 86 => "weather-snow-symbolic",
        95, 96, 99 => "weather-storm-symbolic",
        else => "weather-severe-alert-symbolic",
    };
}

pub fn parse(a: A, settings: Settings, source: []const u8) !Data {
    const r = try std.json.parseFromSliceLeaky(Raw, a, source, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return fromRaw(a, settings, r);
}

pub fn fromRaw(a: A, settings: Settings, r: Raw) !Data {
    try settings.validate();
    // All parallel lists must be aligned before any indexed access.
    inline for (.{ "daily", "hourly" }) |group| {
        const fields = @field(r, group);
        const count = fields.time.len;
        if (count == 0 or count > (if (std.mem.eql(u8, group, "daily")) @as(usize, 7) else 72)) return error.InvalidWeatherData;
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |name| {
            const values = @field(fields, name);
            if (values.len != count) return error.InvalidWeatherData;
            for (values) |value| {
                if (@TypeOf(value) == f64) {
                    if (!std.math.isFinite(value) or @abs(value) > 1_000_000) return error.InvalidWeatherData;
                }
            }
        }
    }
    inline for (@typeInfo(@TypeOf(r.current)).@"struct".field_names) |name| {
        const value = @field(r.current, name);
        if (@TypeOf(value) == f64) {
            if (!std.math.isFinite(value) or @abs(value) > 1_000_000) return error.InvalidWeatherData;
        }
    }
    _ = try dateTime(a, r.current.time, r.utc_offset_seconds);
    for (r.hourly.time) |time| _ = try dateTime(a, time, r.utc_offset_seconds);
    for (r.daily.sunrise, r.daily.sunset, r.daily.temperature_2m_min, r.daily.temperature_2m_max) |rise, set, low, high| {
        _ = try sunTime(a, rise);
        _ = try sunTime(a, set);
        if (low > high) return error.InvalidWeatherData;
    }
    _ = try conditionCode(r.current.weather_code);
    for (r.daily.weather_code) |code| _ = try conditionCode(code);
    for (r.hourly.weather_code) |code| _ = try conditionCode(code);
    return .{ .settings = settings, .raw = r };
}

fn request(client: *std.http.Client, url: []const u8, out: *Io.Writer) anyerror!std.http.Client.FetchResult {
    return client.fetch(.{ .location = .{ .url = url }, .response_writer = out, .redirect_behavior = .not_allowed });
}
fn timeout(io: Io) Io.Cancelable!void {
    try io.sleep(.fromSeconds(30), .awake);
}
pub fn fetch(a: A, io: Io, settings: Settings) !Data {
    try settings.validate();
    const url = try std.fmt.allocPrint(a, "https://api.open-meteo.com/v1/forecast?latitude={d:.5}&longitude={d:.5}&timezone=auto&forecast_days=7&forecast_hours=72&temperature_unit=celsius&wind_speed_unit=kmh&current=temperature_2m,relative_humidity_2m,weather_code,surface_pressure,wind_speed_10m,wind_direction_10m&daily=temperature_2m_min,temperature_2m_max,weather_code,sunrise,sunset,wind_speed_10m_max,wind_direction_10m_dominant,uv_index_max&hourly=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,visibility,uv_index", .{ settings.latitude, settings.longitude });
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var bytes: [128 * 1024]u8 = undefined;
    var out = Io.Writer.fixed(&bytes);
    const Result = union(enum) { response: anyerror!std.http.Client.FetchResult, timeout: Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &results);
    // Join both tasks before releasing client, writer, buffer, or allocator.
    defer select.cancelDiscard();
    try select.concurrent(.response, request, .{ &client, url, &out });
    try select.concurrent(.timeout, timeout, .{io});
    switch (try select.await()) {
        .timeout => |result| {
            try result;
            return error.WeatherFetchTimedOut;
        },
        .response => |result| if ((try result).status != .ok) return error.WeatherProviderFailed,
    }
    return parse(a, settings, out.buffered());
}

pub const Request = struct { id: u8, path: []const u8 };
pub fn decodeRequest(a: A, bytes: []const u8) !Request {
    if (bytes.len < 4 or bytes[0] != 1) return error.InvalidWeatherRequest;
    const method_end = std.mem.indexOfScalarPos(u8, bytes, 2, 0) orelse return error.InvalidWeatherRequest;
    if (!std.mem.eql(u8, bytes[2..method_end], "GET")) return error.InvalidWeatherRequest;
    const url_end = std.mem.indexOfScalarPos(u8, bytes, method_end + 1, 0) orelse return error.InvalidWeatherRequest;
    const uri = std.Uri.parse(bytes[method_end + 1 .. url_end]) catch return error.InvalidWeatherRequest;
    const path = try uri.path.toRawMaybeAlloc(a);
    // Routes are local responses; URLs from the band are never fetched.
    return .{ .id = bytes[1], .path = try a.dupe(u8, path) };
}
pub fn httpReply(a: A, id: u8, body: ?[]const u8) ![]u8 {
    const content = body orelse return a.dupe(u8, &.{ 2, id, 2, 0, 0, 0, 0 });
    if (content.len > 16_000) return error.WeatherResponseTooLarge;
    const packet = try a.alloc(u8, 8 + content.len);
    @memcpy(packet[0..4], &[_]u8{ 2, id, 1, 200 });
    std.mem.writeInt(u32, packet[4..8], @intCast(content.len), .little);
    @memcpy(packet[8..], content);
    return packet;
}

pub fn update(a: A, io: Io, transport: anytype, data: Data, out: *Io.Writer) !void {
    const stamp = Io.Timestamp.now(io, .real).toMilliseconds();
    try transport.send(0xe, try data.locationPacket(a, stamp));
    try out.writeAll("Weather location sent. Open Weather on the band and scroll to the daily forecast to update high/low temperatures; waiting up to 60 seconds...\n");
    try out.flush();
    const end = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(60));
    var deadline = end;
    var current = false;
    var forecast = false;
    var replies: usize = 0;
    while (true) {
        if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) break;
        const message = transport.next(deadline) catch |err| {
            if (err == error.BandResponseTimedOut) break;
            return err;
        };
        if (message.endpoint != 1) continue;
        const req = decodeRequest(a, message.data) catch |err| {
            try out.print("Could not decode band weather request ({t}, {d} bytes).\n", .{ err, message.data.len });
            try out.flush();
            if (message.data.len >= 2) try transport.send(1, try httpReply(a, message.data[1], null));
            continue;
        };
        try out.print("Band requested {s}.\n", .{req.path});
        try out.flush();
        const body = try data.body(a, req.path);
        try transport.send(1, try httpReply(a, req.id, body));
        if (body != null) {
            replies += 1;
            try out.print("Supplied {s}.\n", .{req.path});
            try out.flush();
            current = current or std.mem.eql(u8, req.path, "/weather/current");
            forecast = forecast or std.mem.eql(u8, req.path, "/weather/v2/forecast");
            if (std.mem.eql(u8, req.path, "/weather/v2/forecast")) {
                try out.print("Today's forecast supplied: high {d:.0} °C, low {d:.0} °C.\n", .{ data.raw.daily.temperature_2m_max[0], data.raw.daily.temperature_2m_min[0] });
                try out.flush();
            }
        } else {
            try out.print("Weather route {s} is not supported.\n", .{req.path});
            try out.flush();
        }
        if (current and forecast) deadline = .{ .nanoseconds = @min(end.nanoseconds, Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(5)).nanoseconds) };
    }
    if (!current) return error.WeatherNotRequested;
    if (!forecast) {
        try out.writeAll("Partial update: current weather supplied; daily high/low temperatures were not delivered.\n");
        try out.flush();
        return error.WeatherForecastNotRequested;
    }
    try out.print("Current weather and daily high/low supplied ({d} responses); check the band's display.\n", .{replies});
}

test "weather settings and WMO codes reject invalid values" {
    try (Settings{ .location = "Germantown, TN", .latitude = 35.08676, .longitude = -89.81009 }).validate();
    try std.testing.expectError(error.InvalidWeatherConfiguration, (Settings{ .location = "", .latitude = 0, .longitude = 0 }).validate());
    try std.testing.expectError(error.InvalidWeatherConfiguration, (Settings{ .location = "Test", .latitude = std.math.nan(f64), .longitude = 0 }).validate());
    try std.testing.expectEqual(@as(u8, 0), try conditionCode(0));
    try std.testing.expectEqual(@as(u8, 19), try conditionCode(67));
    try std.testing.expectEqual(@as(u8, 16), try conditionCode(86));
    try std.testing.expectError(error.InvalidWeatherData, conditionCode(255));
}

test "band HTTP requests and replies preserve IDs and UTF-8 byte lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try decodeRequest(a, "\x01\x2aGET\x00https://api-mifit.huami.com/weather/current?locale=en\x00");
    try std.testing.expectEqual(@as(u8, 42), req.id);
    try std.testing.expectEqualStrings("/weather/current", req.path);
    try std.testing.expectError(error.InvalidWeatherRequest, decodeRequest(a, "\x01\x00GET\x00missing terminator"));
    try std.testing.expectError(error.InvalidWeatherRequest, decodeRequest(a, "\x01\x00POST\x00https://example.org/\x00"));
    const packet = try httpReply(a, req.id, "℃");
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, packet[4..8], .little));
    try std.testing.expectEqualSlices(u8, &.{ 2, 42, 2, 0, 0, 0, 0 }, try httpReply(a, 42, null));
    try std.testing.expectEqualStrings("2026-11-02T12:30:00-0600", try dateTime(a, "2026-11-02T12:30", -21600));
}

const sample = @embedFile("testdata/weather.json");
const test_settings: Settings = .{ .location = "Germantown, TN", .latitude = 35.08676, .longitude = -89.81009 };

test "desktop weather JSON preserves values, dates, attribution and Unicode location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var settings = test_settings;
    settings.location = "City \"test\" — TN";
    const data = try parse(a, settings, sample);
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, try data.panelJson(a), .{});
    const obj = doc.object;
    try std.testing.expectEqualStrings(settings.location, obj.get("location").?.string);
    try std.testing.expectEqual(data.raw.current.temperature_2m, obj.get("temperature_celsius").?.float);
    try std.testing.expectEqualStrings("weather-snow-symbolic", obj.get("icon_name").?.string);
    try std.testing.expectEqualStrings(data.raw.daily.time[0], obj.get("daily").?.array.items[0].object.get("date").?.string);
    try std.testing.expectEqualStrings("Open-Meteo", obj.get("provider").?.string);
}

test "weather command modes separate desktop reads from Bluetooth writes" {
    try std.testing.expectEqual(Command.sync, try parseCommand(&.{}));
    try std.testing.expectEqual(Command.json, try parseCommand(&.{"--json"}));
    try std.testing.expectEqual(Command.background, try parseCommand(&.{"--background"}));
    try std.testing.expectError(error.InvalidArguments, parseCommand(&.{"--unknown"}));
    try std.testing.expectError(error.InvalidArguments, parseCommand(&.{ "--json", "--background" }));
}

test "weather response data owns strings, encodes Celsius and rejects misaligned provider lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupe(u8, sample);
    const data = try parse(a, test_settings, source);
    @memset(source, 0);
    const current = (try data.body(a, "/weather/current")).?;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, current, .{});
    const model = value.object.get("currentWeatherModel").?.object;
    const temperature = model.get("temperature").?.object;
    try std.testing.expectEqualStrings("℃", temperature.get("unit").?.string);
    try std.testing.expectEqualStrings("-2", temperature.get("value").?.string);
    try std.testing.expectEqualStrings("14", model.get("weather").?.string);
    const forecast = try std.json.parseFromSliceLeaky(std.json.Value, a, (try data.body(a, "/weather/v2/forecast")).?, .{});
    const today = forecast.object.get("temperature").?.array.items[0].object;
    try std.testing.expectEqualStrings("-5", today.get("from").?.string);
    try std.testing.expectEqualStrings("2", today.get("to").?.string);
    for ([_][]const u8{ "/weather/v2/forecast", "/weather/forecast/hourly", "/weather/index" }) |path| {
        const body = (try data.body(a, path)).?;
        _ = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        try std.testing.expect(body.len < 16_000);
    }
    try std.testing.expect(try data.body(a, "/weather/alerts") == null);
    try std.testing.expect(try data.body(a, "/private") == null);
    var invalid = data.raw;
    invalid.hourly.wind_speed_10m = &.{};
    try std.testing.expectError(error.InvalidWeatherData, parse(a, test_settings, try json(a, invalid)));
    invalid = data.raw;
    invalid.current.temperature_2m = std.math.inf(f64);
    // Invalid numeric provider input is rejected before reaching Bluetooth.
    try std.testing.expectError(error.InvalidWeatherData, number(a, invalid.current.temperature_2m));
}

test "weather update serves band requests locally and distinguishes an absent request" {
    const Fake = struct {
        index: usize = 0,
        sent: usize = 0,
        no_requests: bool = false,
        current_only: bool = false,
        pub fn send(self: *@This(), endpoint: u16, bytes: []const u8) !void {
            if (self.sent == 0) {
                try std.testing.expectEqual(@as(u16, 0xe), endpoint);
                try std.testing.expectEqualSlices(u8, &.{ 9, 2, 0, 0, 0 }, bytes[0..5]);
                try std.testing.expect(std.mem.endsWith(u8, bytes, "\x00Germantown, TN\x00"));
            } else {
                try std.testing.expectEqual(@as(u16, 1), endpoint);
                try std.testing.expectEqual(@as(u8, 2), bytes[0]);
                try std.testing.expectEqual(@as(u8, @intCast(self.sent)), bytes[1]);
                if (self.sent == 4) {
                    try std.testing.expectEqualSlices(u8, &.{ 2, 4, 2, 0, 0, 0, 0 }, bytes);
                } else {
                    try std.testing.expectEqual(@as(u8, 200), bytes[3]);
                    try std.testing.expectEqual(@as(usize, std.mem.readInt(u32, bytes[4..8], .little)), bytes.len - 8);
                }
            }
            self.sent += 1;
        }
        pub fn next(self: *@This(), _: Io.Timestamp) !struct { endpoint: u16, data: []const u8 } {
            if (self.no_requests) return error.BandResponseTimedOut;
            if (self.current_only and self.index == 1) return error.BandResponseTimedOut;
            const requests = [_][]const u8{
                "\x01\x01GET\x00https://api-mifit.huami.com/weather/current\x00",
                "\x01\x02GET\x00https://api-mifit.huami.com/weather/v2/forecast?days=10\x00",
                "\x01\x03GET\x00https://api-mifit.huami.com/weather/forecast/hourly?hours=72\x00",
                "\x01\x04GET\x00https://example.org/private\x00",
            };
            if (self.index == requests.len) return error.BandResponseTimedOut;
            const data = requests[self.index];
            self.index += 1;
            return .{ .endpoint = 1, .data = data };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try parse(a, test_settings, sample);
    var output: Io.Writer.Allocating = .init(a);
    var fake: Fake = .{};
    try update(a, std.testing.io, &fake, data, &output.writer);
    try std.testing.expectEqual(@as(usize, 5), fake.sent);
    fake = .{ .current_only = true };
    try std.testing.expectError(error.WeatherForecastNotRequested, update(a, std.testing.io, &fake, data, &output.writer));
    try std.testing.expectEqual(@as(usize, 2), fake.sent);
    fake = .{ .no_requests = true };
    try std.testing.expectError(error.WeatherNotRequested, update(a, std.testing.io, &fake, data, &output.writer));
}
