//! Binary-curve ECDH via the system OpenSSL implementation (sect163r2).
const std = @import("std");
const P = *anyopaque;
const C = *const anyopaque;
const Api = struct {
    OBJ_txt2nid: *const fn ([*:0]const u8) callconv(.c) c_int,
    EC_KEY_new_by_curve_name: *const fn (c_int) callconv(.c) ?P,
    EC_KEY_generate_key: *const fn (P) callconv(.c) c_int,
    EC_KEY_free: *const fn (P) callconv(.c) void,
    EC_KEY_get0_group: *const fn (C) callconv(.c) ?C,
    EC_KEY_get0_private_key: *const fn (C) callconv(.c) ?C,
    EC_KEY_get0_public_key: *const fn (C) callconv(.c) ?C,
    EC_POINT_new: *const fn (C) callconv(.c) ?P,
    EC_POINT_free: *const fn (P) callconv(.c) void,
    EC_POINT_set_affine_coordinates: *const fn (C, P, C, C, ?P) callconv(.c) c_int,
    EC_POINT_get_affine_coordinates: *const fn (C, C, P, P, ?P) callconv(.c) c_int,
    EC_POINT_is_on_curve: *const fn (C, C, ?P) callconv(.c) c_int,
    EC_POINT_is_at_infinity: *const fn (C, C) callconv(.c) c_int,
    EC_POINT_mul: *const fn (C, P, ?C, ?C, ?C, ?P) callconv(.c) c_int,
    EC_GROUP_get0_order: *const fn (C) callconv(.c) ?C,
    BN_new: *const fn () callconv(.c) ?P,
    BN_clear_free: *const fn (P) callconv(.c) void,
    BN_lebin2bn: *const fn ([*]const u8, c_int, ?P) callconv(.c) ?P,
    BN_bn2lebinpad: *const fn (C, [*]u8, c_int) callconv(.c) c_int,
};

pub const Exchange = struct {
    library: std.DynLib,
    api: Api,
    key: P,
    pub fn init() !Exchange {
        var lib = std.DynLib.open("libcrypto.so.3") catch return error.OpenSslUnavailable;
        errdefer lib.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |name, T| {
            @field(api, name) = lib.lookup(T, name) orelse return error.OpenSslSymbolMissing;
        }
        const key = api.EC_KEY_new_by_curve_name(api.OBJ_txt2nid("sect163r2")) orelse return error.EcdhFailed;
        errdefer api.EC_KEY_free(key);
        if (api.EC_KEY_generate_key(key) != 1) return error.EcdhFailed;
        return .{ .library = lib, .api = api, .key = key };
    }
    pub fn deinit(self: *Exchange) void {
        self.api.EC_KEY_free(self.key);
        self.library.close();
    }
    fn coordinates(self: *Exchange, point: C) ![48]u8 {
        const group = self.api.EC_KEY_get0_group(self.key) orelse return error.EcdhFailed;
        const x = self.api.BN_new() orelse return error.EcdhFailed;
        defer self.api.BN_clear_free(x);
        const y = self.api.BN_new() orelse return error.EcdhFailed;
        defer self.api.BN_clear_free(y);
        if (self.api.EC_POINT_get_affine_coordinates(group, point, x, y, null) != 1) return error.EcdhFailed;
        var result: [48]u8 = undefined;
        if (self.api.BN_bn2lebinpad(x, &result, 24) != 24 or self.api.BN_bn2lebinpad(y, result[24..].ptr, 24) != 24) return error.EcdhFailed;
        return result;
    }
    pub fn public(self: *Exchange) ![48]u8 {
        return self.coordinates(self.api.EC_KEY_get0_public_key(self.key) orelse return error.EcdhFailed);
    }
    pub fn shared(self: *Exchange, remote: [48]u8) ![48]u8 {
        const api = self.api;
        const group = api.EC_KEY_get0_group(self.key) orelse return error.EcdhFailed;
        const x = api.BN_lebin2bn(&remote, 24, null) orelse return error.EcdhFailed;
        defer api.BN_clear_free(x);
        const y = api.BN_lebin2bn(remote[24..].ptr, 24, null) orelse return error.EcdhFailed;
        defer api.BN_clear_free(y);
        const point = api.EC_POINT_new(group) orelse return error.EcdhFailed;
        defer api.EC_POINT_free(point);
        if (api.EC_POINT_set_affine_coordinates(group, point, x, y, null) != 1 or api.EC_POINT_is_on_curve(group, point, null) != 1 or api.EC_POINT_is_at_infinity(group, point) != 0) return error.InvalidRemotePublicKey;
        const product = api.EC_POINT_new(group) orelse return error.EcdhFailed;
        defer api.EC_POINT_free(product);
        const order = api.EC_GROUP_get0_order(group) orelse return error.EcdhFailed;
        if (api.EC_POINT_mul(group, product, null, point, order, null) != 1 or api.EC_POINT_is_at_infinity(group, product) != 1) return error.InvalidRemotePublicKey;
        if (api.EC_POINT_mul(group, product, null, point, api.EC_KEY_get0_private_key(self.key), null) != 1) return error.EcdhFailed;
        return self.coordinates(product);
    }
};

test "B163 exchanges agree and reject an invalid peer" {
    var alice = try Exchange.init();
    defer alice.deinit();
    var bob = try Exchange.init();
    defer bob.deinit();
    try std.testing.expectEqualSlices(u8, &try alice.shared(try bob.public()), &try bob.shared(try alice.public()));
    try std.testing.expectError(error.InvalidRemotePublicKey, alice.shared(@splat(0)));
}
