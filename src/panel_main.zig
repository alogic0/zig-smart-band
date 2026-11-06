//! Native GTK/AppIndicator desktop adapter for the existing Zig weather command.
const std = @import("std");
const model = @import("panel_model.zig");
const ui = @import("panel_ui.zig");
const band_time = @import("band_time.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const unit_name = "smart-band-weather-panel.service";

const Paths = struct {
    config: []const u8,
    cache: []const u8,
    bin_dir: []const u8,
    command: []const u8,
    panel: []const u8,
    unit: []const u8,
    lock: []const u8,

    fn init(a: A, env: *const std.process.Environ.Map) !Paths {
        const home = env.get("HOME") orelse return error.HomeUnavailable;
        const cfg = try xdg(a, env, "XDG_CONFIG_HOME", home, ".config");
        const data = try xdg(a, env, "XDG_DATA_HOME", home, ".local/share");
        const cache = try xdg(a, env, "XDG_CACHE_HOME", home, ".cache");
        const runtime = env.get("XDG_RUNTIME_DIR") orelse return error.DesktopRuntimeUnavailable;
        if (!std.fs.path.isAbsolute(runtime)) return error.DesktopRuntimeUnavailable;
        const bin = try std.fs.path.join(a, &.{ data, "smart-band", "bin" });
        return .{
            .config = try std.fs.path.join(a, &.{ cfg, "smart-band", "panel.zon" }),
            .cache = try std.fs.path.join(a, &.{ cache, "smart-band", "panel-state.json" }),
            .bin_dir = bin,
            .command = try std.fs.path.join(a, &.{ bin, "smart-band" }),
            .panel = try std.fs.path.join(a, &.{ bin, "smart-band-panel" }),
            .unit = try std.fs.path.join(a, &.{ cfg, "systemd", "user", unit_name }),
            .lock = try std.fs.path.join(a, &.{ runtime, "smart-band-weather-panel.lock" }),
        };
    }
};

fn xdg(a: A, env: *const std.process.Environ.Map, name: []const u8, home: []const u8, fallback: []const u8) ![]const u8 {
    if (env.get(name)) |value| if (std.fs.path.isAbsolute(value)) return value;
    return std.fs.path.join(a, &.{ home, fallback });
}

fn atomicWrite(io: Io, path: []const u8, bytes: []const u8, mode: u32) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| _ = try cwd.createDirPathStatus(io, dir, .fromMode(0o700));
    var file = try cwd.createFileAtomic(io, path, .{ .replace = true, .permissions = .fromMode(mode) });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.replace(io);
}

fn systemctl(a: A, io: Io, args: []const []const u8) !void {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "/usr/bin/systemctl", "--user" }, args });
    defer a.free(argv);
    const result = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    if (!result.term.success()) return error.UserServiceCommandFailed;
}

fn quoteUnit(a: A, path: []const u8) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try text.writer.writeByte('"');
    for (path) |c| {
        switch (c) {
            '\n', '\r', 0 => return error.InvalidInstallPath,
            '\\', '"' => try text.writer.writeByte('\\'),
            '%', '$' => try text.writer.writeByte(c),
            else => {},
        }
        try text.writer.writeByte(c);
    }
    try text.writer.writeByte('"');
    return a.dupe(u8, text.written());
}

fn install(init: std.process.Init, paths: Paths, executable: []const u8) !void {
    const a = init.arena.allocator();
    const io = init.io;
    // Read both sources before replacing anything, so reinstalling is safe.
    const source = try Io.Dir.cwd().realPathFileAlloc(io, executable, a);
    const sibling = try std.fs.path.join(a, &.{ std.fs.path.dirname(source).?, "smart-band" });
    const panel_binary = try Io.Dir.cwd().readFileAlloc(io, source, a, .limited(100 * 1024 * 1024));
    const cli_binary = try Io.Dir.cwd().readFileAlloc(io, sibling, a, .limited(100 * 1024 * 1024));
    const exists = blk: {
        _ = Io.Dir.cwd().statFile(io, paths.unit, .{}) catch |err| {
            if (err == error.FileNotFound) break :blk false;
            return err;
        };
        break :blk true;
    };
    if (exists) try systemctl(a, io, &.{ "stop", unit_name });
    try atomicWrite(io, paths.panel, panel_binary, 0o700);
    try atomicWrite(io, paths.command, cli_binary, 0o700);
    const config_dir = std.fs.path.dirname(paths.config).?;
    _ = try Io.Dir.cwd().createDirPathStatus(io, config_dir, .fromMode(0o700));
    if (Io.Dir.cwd().createFile(io, paths.config, .{ .exclusive = true, .permissions = .fromMode(0o600) })) |file| {
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\.{
            \\    .interval_minutes = 30,
            \\    .sync_band = true,
            \\    .band_timeout_seconds = 180,
            \\    .command = null, // Use the installed smart-band executable.
            \\}
            \\
        );
    } else |err| if (err != error.PathAlreadyExists) return err;
    const unit = try std.fmt.allocPrint(a,
        \\[Unit]
        \\Description=Smart Band weather in the desktop top bar (Zig)
        \\After=graphical-session-pre.target
        \\PartOf=graphical-session.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s}
        \\Restart=on-failure
        \\RestartSec=15
        \\TimeoutStopSec=10
        \\KillMode=control-group
        \\
        \\[Install]
        \\WantedBy=graphical-session.target
        \\
    , .{try quoteUnit(a, paths.panel)});
    try atomicWrite(io, paths.unit, unit, 0o600);
    try systemctl(a, io, &.{"daemon-reload"});
    try systemctl(a, io, &.{ "enable", "--now", unit_name });
    std.debug.print("Installed Zig panel: {s}\nPanel settings: {s}\nDisplay cache: {s}\n", .{ paths.panel, paths.config, paths.cache });
}

const Job = struct {
    io: Io,
    command: []const u8,
    sync: bool,
    timeout: u16,
    fetched: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    fetch_result: ?std.process.RunResult = null,
    fetch_error: ?anyerror = null,
    band_result: ?std.process.RunResult = null,
    band_error: ?anyerror = null,

    fn runCommand(self: *Job, option: []const u8, seconds: u16) !std.process.RunResult {
        const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } }).toDeadline(self.io);
        return std.process.run(std.heap.smp_allocator, self.io, .{
            .argv = &.{ self.command, "weather", option },
            .stdout_limit = .limited(128 * 1024),
            .stderr_limit = .limited(128 * 1024),
            .timeout = deadline,
        });
    }

    fn work(self: *Job) void {
        defer self.done.store(true, .release);
        self.fetch_result = self.runCommand("--json", 45) catch |err| blk: {
            self.fetch_error = err;
            break :blk null;
        };
        self.fetched.store(true, .release);
        if (self.fetch_error != null or !self.fetch_result.?.term.success() or !self.sync) return;
        self.band_result = self.runCommand("--background", self.timeout) catch |err| blk: {
            self.band_error = err;
            break :blk null;
        };
    }

    fn deinit(self: *Job) void {
        for ([_]?std.process.RunResult{ self.fetch_result, self.band_result }) |maybe| if (maybe) |result| {
            std.heap.smp_allocator.free(result.stdout);
            std.heap.smp_allocator.free(result.stderr);
        };
    }
};

const App = struct {
    a: A,
    io: Io,
    api: *ui.Api,
    paths: Paths,
    settings: model.Settings,
    indicator: *ui.Indicator,
    menu: *ui.Widget,
    rows: [14]*ui.Widget = undefined,
    update_action: *ui.Widget = undefined,
    weather_action: *ui.Widget = undefined,
    weather: ?std.json.Parsed(model.Weather) = null,
    saved: ?std.json.Parsed(model.Saved) = null,
    checked_at: ?i64 = null,
    last_band_sync: ?i64 = null,
    weather_error: ?[]const u8 = null,
    band: model.Band = .pending,
    job: ?*Job = null,
    future: ?Io.Future(void) = null,
    applied_fetch: bool = false,
    timer_id: c_uint = 0,
    poll_id: c_uint = 0,
    signals: [2]c_uint = .{ 0, 0 },

    fn from(raw: ?*anyopaque) *App {
        return @ptrCast(@alignCast(raw.?));
    }

    fn data(self: *App) ?*const model.Weather {
        if (self.weather) |*value| return &value.value;
        if (self.saved) |*value| if (value.value.weather) |*w| return w;
        return null;
    }

    fn build(self: *App) !void {
        const f = self.api.f;
        for (&self.rows) |*row| {
            row.* = f.gtk_menu_item_new_with_label("") orelse return error.WidgetUnavailable;
            f.gtk_widget_set_sensitive(row.*, 0);
            f.gtk_menu_shell_append(self.menu, row.*);
        }
        f.gtk_menu_shell_append(self.menu, f.gtk_separator_menu_item_new() orelse return error.WidgetUnavailable);
        self.update_action = f.gtk_menu_item_new_with_label("Update weather + band now") orelse return error.WidgetUnavailable;
        self.weather_action = f.gtk_menu_item_new_with_label("Update desktop weather only") orelse return error.WidgetUnavailable;
        f.gtk_menu_shell_append(self.menu, self.update_action);
        f.gtk_menu_shell_append(self.menu, self.weather_action);
        _ = f.g_signal_connect_data(self.update_action, "activate", activateBoth, self, null, 0);
        _ = f.g_signal_connect_data(self.weather_action, "activate", activateWeather, self, null, 0);
        f.app_indicator_set_title(self.indicator, "Smart Band Weather");
        f.app_indicator_set_menu(self.indicator, self.menu);
        f.app_indicator_set_status(self.indicator, 1);
        f.gtk_widget_show_all(self.menu);
        self.restore();
        self.render();
    }

    fn setRow(self: *App, index: usize, comptime fmt: []const u8, args: anytype) void {
        var buffer: [1024]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buffer, fmt, args, 0) catch "Display value too long";
        self.api.f.gtk_menu_item_set_label(self.rows[index], text);
    }

    fn setTime(self: *App, index: usize, prefix: []const u8, timestamp: ?i64) void {
        const t = band_time.localAt(timestamp orelse 0) catch {
            self.setRow(index, "{s}: unknown", .{prefix});
            return;
        };
        if (timestamp == null) self.setRow(index, "{s}: not yet", .{prefix}) else self.setRow(index, "{s}: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ prefix, t.year, t.month, t.day, t.hour, t.minute });
    }

    fn render(self: *App) void {
        const f = self.api.f;
        const w = self.data();
        if (w) |value| {
            var label_buffer: [40]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&label_buffer, "{d}°C{s}", .{ @as(i32, @intFromFloat(@round(value.temperature_celsius))), if (self.weather_error != null) "*" else "" }, 0) catch "?°C";
            f.app_indicator_set_label(self.indicator, label, "−88°C");
            var icon_buffer: [81]u8 = undefined;
            const icon = std.fmt.bufPrintSentinel(&icon_buffer, "{s}", .{value.icon_name}, 0) catch "weather-severe-alert-symbolic";
            f.app_indicator_set_icon_full(self.indicator, icon, "Weather");
            self.setRow(0, "{s}", .{value.location});
            self.setRow(1, "{d:.1} °C · {s}", .{ value.temperature_celsius, value.description });
            self.setRow(2, "High {d:.0} °C / Low {d:.0} °C", .{ value.high_celsius, value.low_celsius });
            self.setRow(3, "Humidity {d:.0}% · Wind {d:.1} km/h", .{ value.humidity_percent, value.wind_kph });
            self.setRow(4, "Weather at {s}", .{value.observed_at});
            for (10..13) |i| {
                if (value.daily.len > i - 9) {
                    const day = value.daily[i - 9];
                    self.setRow(i, "{s}: {d:.0}–{d:.0} °C, {s}", .{ day.date, day.low_celsius, day.high_celsius, day.description });
                } else self.setRow(i, "", .{});
            }
        } else {
            f.app_indicator_set_label(self.indicator, "…°C", "−88°C");
            self.setRow(0, "Smart Band weather", .{});
            self.setRow(1, "{s}", .{if (self.job != null) "Fetching weather…" else "Weather unavailable"});
        }
        self.setTime(5, "Checked", self.checked_at);
        self.setRow(6, "{s}", .{self.weather_error orelse ""});
        self.setRow(7, "{s}", .{self.band.message()});
        self.setTime(8, "Last full band sync", self.last_band_sync);
        self.setRow(9, "Automatic update: every {d} minutes", .{self.settings.interval_minutes});
        self.setRow(13, "Weather data: Open-Meteo", .{});
        f.gtk_widget_set_sensitive(self.update_action, @intFromBool(self.job == null));
        f.gtk_widget_set_sensitive(self.weather_action, @intFromBool(self.job == null));
        f.gtk_widget_set_visible(self.rows[6], @intFromBool(self.weather_error != null));
        f.gtk_widget_set_visible(self.rows[8], @intFromBool(self.last_band_sync != null));
        for (10..13) |i| f.gtk_widget_set_visible(self.rows[i], @intFromBool(w != null and w.?.daily.len > i - 9));
        for (2..5) |i| f.gtk_widget_set_visible(self.rows[i], @intFromBool(w != null));
    }

    fn restore(self: *App) void {
        const source = Io.Dir.cwd().readFileAlloc(self.io, self.paths.cache, self.a, .limited(32 * 1024)) catch return;
        defer self.a.free(source);
        var saved = std.json.parseFromSlice(model.Saved, self.a, source, .{ .allocate = .alloc_always }) catch return;
        if (saved.value.weather) |w| w.validate() catch {
            saved.deinit();
            return;
        };
        self.checked_at = saved.value.checked_at;
        self.last_band_sync = saved.value.last_band_sync;
        self.saved = saved;
    }

    fn persist(self: *App) void {
        const state: model.Saved = .{ .weather = if (self.data()) |w| w.* else null, .checked_at = self.checked_at, .last_band_sync = self.last_band_sync };
        const bytes = std.json.Stringify.valueAlloc(self.a, state, .{}) catch return;
        defer self.a.free(bytes);
        atomicWrite(self.io, self.paths.cache, bytes, 0o600) catch |err| std.debug.print("Panel cache: {t}\n", .{err});
    }

    fn start(self: *App, sync: bool) void {
        if (self.job != null) return;
        const job = self.a.create(Job) catch return;
        job.* = .{ .io = self.io, .command = self.settings.command orelse self.paths.command, .sync = sync and self.settings.sync_band, .timeout = self.settings.band_timeout_seconds };
        self.job = job;
        self.applied_fetch = false;
        self.future = Io.concurrent(self.io, Job.work, .{job}) catch {
            self.a.destroy(job);
            self.job = null;
            self.weather_error = "Could not start weather update";
            self.render();
            return;
        };
        self.poll_id = self.api.f.g_timeout_add(100, poll, self);
        self.render();
    }

    fn applyFetch(self: *App, job: *Job) void {
        const result = job.fetch_result orelse {
            std.debug.print("Weather fetch failed: {t}\n", .{job.fetch_error.?});
            self.weather_error = "Weather unavailable; retaining previous data";
            return;
        };
        if (!result.term.success()) {
            std.debug.print("Weather fetch: {s}\n", .{result.stderr});
            self.weather_error = "Weather unavailable; retaining previous data";
            return;
        }
        var parsed = std.json.parseFromSlice(model.Weather, self.a, result.stdout, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            self.weather_error = "Invalid weather response";
            return;
        };
        parsed.value.validate() catch {
            parsed.deinit();
            self.weather_error = "Invalid weather response";
            return;
        };
        if (self.weather) |*old| old.deinit();
        if (self.saved) |*old| old.deinit();
        self.saved = null;
        self.weather = parsed;
        self.weather_error = null;
        self.checked_at = Io.Timestamp.now(self.io, .real).toSeconds();
        if (job.sync) self.band = .syncing;
        self.persist();
    }

    fn poll(raw: ?*anyopaque) callconv(.c) c_int {
        const self = from(raw);
        const job = self.job.?;
        const done = job.done.load(.acquire);
        if (!self.applied_fetch and (done or job.fetched.load(.acquire))) {
            self.applied_fetch = true;
            self.applyFetch(job);
            self.render(); // Publish the desktop data before waiting for the band.
        }
        if (!done) return 1;
        self.future.?.await(self.io);
        self.future = null;
        if (job.band_result) |result| {
            self.band = model.syncResult(result.term.success(), result.stdout, result.stderr);
            std.debug.print("{s}\n{s}{s}", .{ self.band.message(), result.stdout, result.stderr });
            if (self.band == .full) self.last_band_sync = Io.Timestamp.now(self.io, .real).toSeconds();
        } else if (job.band_error) |err| {
            self.band = .failed;
            std.debug.print("Band update failed: {t}\n", .{err});
        }
        job.deinit();
        self.a.destroy(job);
        self.job = null;
        self.poll_id = 0;
        self.persist();
        self.render();
        return 0;
    }

    fn activateBoth(_: *ui.Widget, raw: ?*anyopaque) callconv(.c) void {
        from(raw).start(true);
    }
    fn activateWeather(_: *ui.Widget, raw: ?*anyopaque) callconv(.c) void {
        from(raw).start(false);
    }
    fn tick(raw: ?*anyopaque) callconv(.c) c_int {
        from(raw).start(true);
        return 1;
    }
    fn stop(raw: ?*anyopaque) callconv(.c) c_int {
        from(raw).api.f.gtk_main_quit();
        return 1;
    }

    fn deinit(self: *App) void {
        const f = self.api.f;
        if (self.timer_id != 0) _ = f.g_source_remove(self.timer_id);
        if (self.poll_id != 0) _ = f.g_source_remove(self.poll_id);
        for (self.signals) |id| if (id != 0) {
            _ = f.g_source_remove(id);
        };
        if (self.future) |*future| future.cancel(self.io);
        if (self.job) |job| {
            job.deinit();
            self.a.destroy(job);
        }
        if (self.weather) |*value| value.deinit();
        if (self.saved) |*value| value.deinit();
        f.app_indicator_set_status(self.indicator, 0);
        f.g_object_unref(self.indicator);
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const paths = try Paths.init(a, init.environ_map);
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--install")) return install(init, paths, args[0]);
    if (args.len != 1) return error.InvalidArguments;
    const lock = try Io.Dir.cwd().createFile(init.io, paths.lock, .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer lock.close(init.io);
    if (!try lock.tryLock(init.io, .exclusive)) return error.PanelAlreadyRunning;
    const config = Io.Dir.cwd().readFileAlloc(init.io, paths.config, a, .limited(16384)) catch |err| blk: {
        if (err == error.FileNotFound) break :blk ".{}";
        return err;
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const settings = std.zon.parse.fromSlice(model.Settings, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, config, 0), .diagnostics = &diagnostics }) catch |err| {
        if (err == error.ParseZon) diagnostics.log(paths.config);
        return err;
    };
    try settings.validate();
    var api = try ui.Api.init();
    if (api.f.gtk_init_check(null, null) == 0) {
        api.deinit();
        return error.DesktopDisplayUnavailable;
    }
    // GTK's global GType registrations retain library callbacks until exit.
    // Keep these runtimes loaded for the rest of the process lifetime.
    const indicator = api.f.app_indicator_new("smart-band-weather", "weather-severe-alert-symbolic", 2) orelse return error.IndicatorUnavailable;
    const menu = api.f.gtk_menu_new() orelse return error.WidgetUnavailable;
    var app: App = .{ .a = init.gpa, .io = init.io, .api = &api, .paths = paths, .settings = settings, .indicator = indicator, .menu = menu };
    defer app.deinit();
    try app.build();
    app.signals = .{ api.f.g_unix_signal_add(15, App.stop, &app), api.f.g_unix_signal_add(2, App.stop, &app) };
    app.timer_id = api.f.g_timeout_add_seconds(@as(c_uint, settings.interval_minutes) * 60, App.tick, &app);
    app.start(true);
    api.f.gtk_main();
}

test {
    _ = model;
}

test "service executable quoting preserves spaces, percent and dollar signs" {
    const quoted = try quoteUnit(std.testing.allocator, "/tmp/a b/%name/$bin");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("\"/tmp/a b/%%name/$$bin\"", quoted);
    try std.testing.expectError(error.InvalidInstallPath, quoteUnit(std.testing.allocator, "bad\npath"));
}
