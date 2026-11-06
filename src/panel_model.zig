//! Data and settings for the native desktop weather indicator.
const std = @import("std");

pub const Settings = struct {
    interval_minutes: u16 = 30,
    sync_band: bool = true,
    command: ?[]const u8 = null,
    band_timeout_seconds: u16 = 180,

    pub fn validate(self: Settings) !void {
        if (self.interval_minutes < 5 or self.interval_minutes > 1440 or
            self.band_timeout_seconds < 30 or self.band_timeout_seconds > 300) return error.InvalidPanelSettings;
        if (self.command) |path| {
            if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPanelSettings;
        }
    }
};

pub const Day = struct { date: []const u8, low_celsius: f64, high_celsius: f64, description: []const u8 };
pub const Weather = struct {
    version: u8,
    location: []const u8,
    temperature_celsius: f64,
    description: []const u8,
    icon_name: []const u8,
    observed_at: []const u8,
    humidity_percent: f64,
    wind_kph: f64,
    high_celsius: f64,
    low_celsius: f64,
    daily: []const Day,

    pub fn validate(self: Weather) !void {
        if (self.version != 1 or self.location.len == 0 or self.location.len > 200 or
            !std.unicode.utf8ValidateSlice(self.location) or self.observed_at.len != 16 or
            self.observed_at[10] != 'T' or self.daily.len == 0 or self.daily.len > 7 or
            !std.mem.startsWith(u8, self.icon_name, "weather-") or !std.mem.endsWith(u8, self.icon_name, "-symbolic") or
            self.icon_name.len > 80) return error.InvalidPanelWeather;
        for (self.icon_name) |c| if (!std.ascii.isAlphabetic(c) and c != '-') return error.InvalidPanelWeather;
        for ([_][]const u8{ self.location, self.description, self.icon_name, self.observed_at }) |text| {
            if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidPanelWeather;
        }
        for ([_]f64{ self.temperature_celsius, self.humidity_percent, self.wind_kph, self.high_celsius, self.low_celsius }) |n| {
            if (!std.math.isFinite(n) or @abs(n) > 1_000_000) return error.InvalidPanelWeather;
        }
        for (self.daily) |day| {
            if (day.date.len != 10 or day.date[4] != '-' or day.date[7] != '-' or
                !std.math.isFinite(day.low_celsius) or !std.math.isFinite(day.high_celsius) or
                @abs(day.low_celsius) > 1_000_000 or @abs(day.high_celsius) > 1_000_000 or
                day.description.len > 200 or std.mem.indexOfScalar(u8, day.description, 0) != null or
                !std.unicode.utf8ValidateSlice(day.description)) return error.InvalidPanelWeather;
        }
    }
};

pub const Band = enum {
    pending,
    syncing,
    full,
    partial,
    waiting,
    busy,
    unavailable,
    failed,

    pub fn message(self: Band) []const u8 {
        return switch (self) {
            .pending => "Band: not synchronized yet",
            .syncing => "Band: synchronizing…",
            .full => "Band: current weather and forecast updated",
            .partial => "Band: current updated; open forecast for high/low",
            .waiting => "Band: open Weather to request the update",
            .busy => "Band: Bluetooth busy; retry next update",
            .unavailable => "Band: unavailable; retry next update",
            .failed => "Band: update failed; see service log",
        };
    }
};

pub fn syncResult(success: bool, stdout: []const u8, stderr: []const u8) Band {
    if (success and std.mem.indexOf(u8, stdout, "Current weather and daily high/low supplied") != null) return .full;
    if (std.mem.indexOf(u8, stderr, "WeatherForecastNotRequested") != null) return .partial;
    if (std.mem.indexOf(u8, stderr, "WeatherNotRequested") != null) return .waiting;
    if (std.mem.indexOf(u8, stderr, "BluetoothBusy") != null) return .busy;
    return .unavailable;
}

pub const Saved = struct {
    weather: ?Weather = null,
    checked_at: ?i64 = null,
    last_band_sync: ?i64 = null,
};

test "native panel settings reject unsafe paths and unreasonable schedules" {
    try (Settings{}).validate();
    try std.testing.expectError(error.InvalidPanelSettings, (Settings{ .interval_minutes = 0 }).validate());
    try std.testing.expectError(error.InvalidPanelSettings, (Settings{ .command = "sh -c bad" }).validate());
    try std.testing.expectError(error.InvalidPanelSettings, (Settings{ .band_timeout_seconds = 0 }).validate());
}

test "a partial or failed sync never records complete weather delivery" {
    try std.testing.expectEqual(Band.full, syncResult(true, "Current weather and daily high/low supplied (3 responses)", ""));
    try std.testing.expectEqual(Band.partial, syncResult(false, "", "smart-band: WeatherForecastNotRequested"));
    try std.testing.expectEqual(Band.waiting, syncResult(false, "", "smart-band: WeatherNotRequested"));
    try std.testing.expectEqual(Band.busy, syncResult(false, "", "smart-band: BluetoothBusy"));
    try std.testing.expectEqual(Band.unavailable, syncResult(false, "Current weather and daily high/low supplied", ""));
    try std.testing.expectEqual(Band.unavailable, syncResult(true, "", ""));
}

test "native panel parses the real Zig JSON contract and rejects malformed display data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const weather = @import("weather.zig");
    const data = try weather.parse(a, .{ .location = "Test", .latitude = 35, .longitude = -89 }, @embedFile("testdata/weather.json"));
    var parsed = try std.json.parseFromSlice(Weather, a, try data.panelJson(a), .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    try parsed.value.validate();
    parsed.value.temperature_celsius = std.math.nan(f64);
    try std.testing.expectError(error.InvalidPanelWeather, parsed.value.validate());
}
