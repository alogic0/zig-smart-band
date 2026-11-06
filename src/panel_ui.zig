//! Small native ABI adapter. No GTK SDK headers or JavaScript are required.
//! ABI: GTK 3, GLib/GObject 2, libayatana-appindicator3's app-indicator.h.
const std = @import("std");
pub const Widget = opaque {};
pub const Indicator = opaque {};
pub const Str = [*:0]const u8;
pub const Callback = *const fn (?*anyopaque) callconv(.c) c_int;
pub const Activate = *const fn (*Widget, ?*anyopaque) callconv(.c) void;

pub const Functions = struct {
    gtk_init_check: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    gtk_main: *const fn () callconv(.c) void,
    gtk_main_quit: *const fn () callconv(.c) void,
    gtk_menu_new: *const fn () callconv(.c) ?*Widget,
    gtk_menu_item_new_with_label: *const fn (Str) callconv(.c) ?*Widget,
    gtk_separator_menu_item_new: *const fn () callconv(.c) ?*Widget,
    gtk_menu_shell_append: *const fn (*Widget, *Widget) callconv(.c) void,
    gtk_menu_item_set_label: *const fn (*Widget, Str) callconv(.c) void,
    gtk_widget_set_sensitive: *const fn (*Widget, c_int) callconv(.c) void,
    gtk_widget_set_visible: *const fn (*Widget, c_int) callconv(.c) void,
    gtk_widget_show_all: *const fn (*Widget) callconv(.c) void,
    gtk_widget_destroy: *const fn (*Widget) callconv(.c) void,
    g_object_unref: *const fn (*anyopaque) callconv(.c) void,
    g_signal_connect_data: *const fn (*Widget, Str, Activate, ?*anyopaque, ?*anyopaque, c_uint) callconv(.c) c_ulong,
    g_timeout_add: *const fn (c_uint, Callback, ?*anyopaque) callconv(.c) c_uint,
    g_timeout_add_seconds: *const fn (c_uint, Callback, ?*anyopaque) callconv(.c) c_uint,
    g_unix_signal_add: *const fn (c_int, Callback, ?*anyopaque) callconv(.c) c_uint,
    g_source_remove: *const fn (c_uint) callconv(.c) c_int,
    app_indicator_new: *const fn (Str, Str, c_int) callconv(.c) ?*Indicator,
    app_indicator_set_status: *const fn (*Indicator, c_int) callconv(.c) void,
    app_indicator_set_menu: *const fn (*Indicator, *Widget) callconv(.c) void,
    app_indicator_set_label: *const fn (*Indicator, Str, Str) callconv(.c) void,
    app_indicator_set_title: *const fn (*Indicator, Str) callconv(.c) void,
    app_indicator_set_icon_full: *const fn (*Indicator, Str, Str) callconv(.c) void,
};

pub const Api = struct {
    libs: [4]std.DynLib,
    f: Functions,

    pub fn init() !Api {
        var result: Api = undefined;
        var opened: usize = 0;
        errdefer for (result.libs[0..opened]) |*lib| lib.close();
        for ([_][]const u8{ "libgtk-3.so.0", "libglib-2.0.so.0", "libgobject-2.0.so.0", "libayatana-appindicator3.so.1" }, 0..) |name, i| {
            result.libs[i] = std.DynLib.open(name) catch {
                std.debug.print("Missing panel runtime: {s}\n", .{name});
                return error.PanelLibraryUnavailable;
            };
            opened += 1;
        }
        inline for (@typeInfo(Functions).@"struct".field_names, @typeInfo(Functions).@"struct".field_types) |name, T| {
            @field(result.f, name) = blk: {
                for (&result.libs) |*lib| if (lib.lookup(T, name)) |symbol| break :blk symbol;
                std.debug.print("Missing panel ABI symbol: {s}\n", .{name});
                return error.PanelSymbolUnavailable;
            };
        }
        return result;
    }

    pub fn deinit(self: *Api) void {
        var i = self.libs.len;
        while (i > 0) {
            i -= 1;
            self.libs[i].close();
        }
    }
};
