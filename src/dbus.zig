//! Minimal sd-bus bindings. The runtime library is loaded without SDK headers.
//! ABI reference: https://www.freedesktop.org/software/systemd/man/latest/sd-bus.html
const std = @import("std");
const Bus = opaque {};
const Message = opaque {};
const CStr = [*:0]const u8;
const BusError = extern struct {
    name: ?CStr = null,
    message: ?CStr = null,
    need_free: c_int = 0,
};

const Api = struct {
    sd_bus_add_match: *const fn (*Bus, *?*anyopaque, CStr, *const fn (*Message, ?*anyopaque, *BusError) callconv(.c) c_int, ?*anyopaque) callconv(.c) c_int,
    sd_bus_slot_unref: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    sd_bus_process: *const fn (*Bus, ?*?*Message) callconv(.c) c_int,
    sd_bus_wait: *const fn (*Bus, u64) callconv(.c) c_int,
    sd_bus_open_system: *const fn (*?*Bus) callconv(.c) c_int,
    sd_bus_unref: *const fn (*Bus) callconv(.c) ?*Bus,
    sd_bus_message_unref: *const fn (*Message) callconv(.c) ?*Message,
    sd_bus_error_free: *const fn (*BusError) callconv(.c) void,
    sd_bus_message_new_method_call: *const fn (*Bus, *?*Message, CStr, CStr, CStr, CStr) callconv(.c) c_int,
    sd_bus_message_append_array: *const fn (*Message, u8, [*]const u8, usize) callconv(.c) c_int,
    sd_bus_message_append_basic: *const fn (*Message, u8, *const anyopaque) callconv(.c) c_int,
    sd_bus_call: *const fn (*Bus, *Message, u64, *BusError, *?*Message) callconv(.c) c_int,
    sd_bus_message_open_container: *const fn (*Message, u8, ?CStr) callconv(.c) c_int,
    sd_bus_message_close_container: *const fn (*Message) callconv(.c) c_int,
    sd_bus_message_enter_container: *const fn (*Message, u8, ?CStr) callconv(.c) c_int,
    sd_bus_message_exit_container: *const fn (*Message) callconv(.c) c_int,
    sd_bus_message_skip: *const fn (*Message, ?CStr) callconv(.c) c_int,
    sd_bus_message_read_basic: *const fn (*Message, u8, *anyopaque) callconv(.c) c_int,
    sd_bus_message_read_array: *const fn (*Message, u8, *?*const anyopaque, *usize) callconv(.c) c_int,
};

/// Bounded signal queue; its address must stay stable between start and deinit.
pub const Receiver = struct {
    connection: *Connection,
    path: CStr,
    slot: ?*anyopaque = null,
    packets: [64][517]u8 = undefined,
    lengths: [64]usize = undefined,
    head: usize = 0,
    tail: usize = 0,
    failed: bool = false,
    started: bool = false,

    pub fn start(self: *Receiver, a: std.mem.Allocator) !void {
        const rule = try std.fmt.allocPrintSentinel(a, "type='signal',sender='org.bluez',path='{s}',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'", .{std.mem.span(self.path)}, 0);
        try checked(self.connection.api.sd_bus_add_match(self.connection.bus, &self.slot, rule, callback, self));
        errdefer self.deinit();
        try self.connection.simple(self.path, "org.bluez.GattCharacteristic1", "StartNotify", 5_000_000);
        self.started = true;
    }

    pub fn deinit(self: *Receiver) void {
        if (self.started) self.connection.simple(self.path, "org.bluez.GattCharacteristic1", "StopNotify", 5_000_000) catch {};
        if (self.slot) |slot| _ = self.connection.api.sd_bus_slot_unref(slot);
        self.slot = null;
        self.started = false;
    }

    fn callback(message: *Message, userdata: ?*anyopaque, _: *BusError) callconv(.c) c_int {
        const self: *Receiver = @ptrCast(@alignCast(userdata.?));
        self.receive(message) catch {
            self.failed = true;
        };
        return 0;
    }

    fn receive(self: *Receiver, message: *Message) !void {
        var reply: Reply = .{ .connection = self.connection, .message = message };
        const interface = std.mem.span(try reply.basic(CStr, 's'));
        if (!std.mem.eql(u8, interface, "org.bluez.GattCharacteristic1")) return;
        try reply.require('a', "{sv}");
        while (try reply.enter('e', "sv")) {
            const key = std.mem.span(try reply.basic(CStr, 's'));
            if (std.mem.eql(u8, key, "Value")) {
                try reply.require('v', "ay");
                var data: ?*const anyopaque = null;
                var size: usize = 0;
                try checked(self.connection.api.sd_bus_message_read_array(message, 'y', &data, &size));
                if (size > 517 or self.tail - self.head == 64) return error.SignalQueueOverflow;
                if (size != 0) {
                    const ptr: [*]const u8 = @ptrCast(data orelse return error.InvalidDBusReply);
                    @memcpy(self.packets[self.tail % 64][0..size], ptr[0..size]);
                    self.lengths[self.tail % 64] = size;
                    self.tail += 1;
                }
                try reply.exit();
            } else try reply.skip("v");
            try reply.exit();
        }
    }

    pub fn next(self: *Receiver, io: std.Io, deadline: std.Io.Timestamp) ![]const u8 {
        while (true) {
            if (self.failed) return error.InvalidBluetoothSignal;
            if (self.head != self.tail) {
                const index = self.head % 64;
                self.head += 1;
                return self.packets[index][0..self.lengths[index]];
            }
            if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) return error.BandResponseTimedOut;
            const processed = self.connection.api.sd_bus_process(self.connection.bus, null);
            try checked(processed);
            if (processed == 0) try checked(self.connection.api.sd_bus_wait(self.connection.bus, 100_000));
        }
    }
};

pub const CallOptions = struct {
    empty_dict: bool = false,
    timeout_us: u64 = 5_000_000,
    report_failure: bool = true,
    write_bytes: ?[]const u8 = null,
    dictionary_string: ?struct { key: CStr, value: CStr } = null,
};

pub const Connection = struct {
    library: std.DynLib,
    api: Api,
    bus: *Bus,

    pub fn init() !Connection {
        var library = std.DynLib.open("libsystemd.so.0") catch return error.SystemdLibraryUnavailable;
        errdefer library.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |name, T| {
            @field(api, name) = library.lookup(T, name) orelse return error.SystemdSymbolMissing;
        }
        var bus: ?*Bus = null;
        if (api.sd_bus_open_system(&bus) < 0) return error.SystemBusUnavailable;
        return .{ .library = library, .api = api, .bus = bus.? };
    }

    pub fn deinit(self: *Connection) void {
        _ = self.api.sd_bus_unref(self.bus);
        self.library.close();
        self.* = undefined;
    }

    /// A reply owns its message; it must be destroyed before this connection.
    pub fn call(self: *Connection, path: CStr, interface: CStr, member: CStr, options: CallOptions) !Reply {
        var request: ?*Message = null;
        try checked(self.api.sd_bus_message_new_method_call(self.bus, &request, "org.bluez", path, interface, member));
        defer _ = self.api.sd_bus_message_unref(request.?);
        if (options.write_bytes) |bytes| {
            try checked(self.api.sd_bus_message_append_array(request.?, 'y', bytes.ptr, bytes.len));
        }
        if (options.empty_dict or options.dictionary_string != null) {
            try checked(self.api.sd_bus_message_open_container(request.?, 'a', "{sv}"));
            if (options.dictionary_string) |entry| {
                try checked(self.api.sd_bus_message_open_container(request.?, 'e', "sv"));
                try checked(self.api.sd_bus_message_append_basic(request.?, 's', entry.key));
                try checked(self.api.sd_bus_message_open_container(request.?, 'v', "s"));
                try checked(self.api.sd_bus_message_append_basic(request.?, 's', entry.value));
                try checked(self.api.sd_bus_message_close_container(request.?));
                try checked(self.api.sd_bus_message_close_container(request.?));
            }
            try checked(self.api.sd_bus_message_close_container(request.?));
        }
        var reply: ?*Message = null;
        var failure: BusError = .{};
        defer self.api.sd_bus_error_free(&failure);
        const result = self.api.sd_bus_call(self.bus, request.?, options.timeout_us, &failure, &reply);
        if (result < 0) {
            if (reply) |message| _ = self.api.sd_bus_message_unref(message);
            const name = if (failure.name) |s| std.mem.span(s) else "D-Bus error";
            const text = if (failure.message) |s| std.mem.span(s) else "no detail";
            if (options.report_failure) std.debug.print("{s}: {s}: {s} (code {d})\n", .{ std.mem.span(member), name, text, result });
            if (std.mem.endsWith(u8, name, ".NotAuthorized") or std.mem.endsWith(u8, name, ".NotPermitted")) return error.AuthenticationRequired;
            return error.DBusCallFailed;
        }
        return .{ .connection = self, .message = reply orelse return error.InvalidDBusReply };
    }

    pub fn simple(self: *Connection, path: CStr, interface: CStr, member: CStr, timeout_us: u64) !void {
        var reply = try self.call(path, interface, member, .{ .timeout_us = timeout_us });
        reply.deinit();
    }
};

fn checked(result: c_int) !void {
    if (result < 0) return error.InvalidDBusMessage;
}

pub const Reply = struct {
    connection: *Connection,
    message: *Message,

    pub fn deinit(self: *Reply) void {
        _ = self.connection.api.sd_bus_message_unref(self.message);
        self.* = undefined;
    }

    pub fn enter(self: *Reply, kind: u8, contents: ?CStr) !bool {
        const result = self.connection.api.sd_bus_message_enter_container(self.message, kind, contents);
        try checked(result);
        return result > 0;
    }

    pub fn require(self: *Reply, kind: u8, contents: ?CStr) !void {
        if (!try self.enter(kind, contents)) return error.InvalidDBusReply;
    }

    pub fn exit(self: *Reply) !void {
        try checked(self.connection.api.sd_bus_message_exit_container(self.message));
    }

    pub fn skip(self: *Reply, signature: CStr) !void {
        try checked(self.connection.api.sd_bus_message_skip(self.message, signature));
    }

    pub fn basic(self: *Reply, comptime T: type, kind: u8) !T {
        var value: T = undefined;
        const result = self.connection.api.sd_bus_message_read_basic(self.message, kind, @ptrCast(&value));
        try checked(result);
        if (result == 0) return error.InvalidDBusReply;
        return value;
    }

    pub fn string(self: *Reply, a: std.mem.Allocator, kind: u8) ![:0]const u8 {
        return a.dupeSentinel(u8, std.mem.span(try self.basic(CStr, kind)), 0);
    }

    pub fn bytes(self: *Reply, a: std.mem.Allocator) ![]const u8 {
        var data: ?*const anyopaque = null;
        var size: usize = 0;
        const result = self.connection.api.sd_bus_message_read_array(self.message, 'y', &data, &size);
        try checked(result);
        if (result == 0 or size > 4096) return error.InvalidDBusReply;
        if (size == 0) return &.{};
        const ptr: [*]const u8 = @ptrCast(data orelse return error.InvalidDBusReply);
        return a.dupe(u8, ptr[0..size]);
    }
};
