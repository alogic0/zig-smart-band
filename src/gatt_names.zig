//! Bluetooth SIG assigned names and known Huami UUID labels.
//! Standard: https://www.bluetooth.com/specifications/assigned-numbers/
//! Vendor: Gadgetbridge devices/huami/HuamiService.java (protocol identifiers).
const std = @import("std");

pub const Kind = enum { service, characteristic };
const Entry = struct { uuid: []const u8, name: []const u8 };

fn standard(comptime short: []const u8, name: []const u8) Entry {
    return .{ .uuid = "0000" ++ short ++ "-0000-1000-8000-00805f9b34fb", .name = name };
}
fn huami(comptime short: []const u8, name: []const u8) Entry {
    return .{ .uuid = "0000" ++ short ++ "-0000-3512-2118-0009af100700", .name = name };
}

const services = [_]Entry{
    standard("1800", "Generic Access"),
    standard("1801", "Generic Attribute"),
    standard("180a", "Device Information"),
    standard("180d", "Heart Rate"),
    standard("180f", "Battery Service"),
    standard("1811", "Alert Notification Service"),
    standard("fee0", "Huami Main Service"),
    standard("fee1", "Huami Secondary Service"),
    huami("1530", "Huami Firmware Transfer"),
};

const characteristics = [_]Entry{
    standard("2a00", "Device Name"),
    standard("2a01", "Appearance"),
    standard("2a05", "Service Changed"),
    standard("2a19", "Battery Level"),
    standard("2a23", "System ID"),
    standard("2a24", "Model Number String"),
    standard("2a25", "Serial Number String"),
    standard("2a26", "Firmware Revision String"),
    standard("2a27", "Hardware Revision String"),
    standard("2a28", "Software Revision String"),
    standard("2a29", "Manufacturer Name String"),
    standard("2a2b", "Current Time"),
    standard("2a37", "Heart Rate Measurement"),
    standard("2a46", "New Alert"),
    standard("2a50", "PnP ID"),
    huami("0001", "Huami Legacy Raw Sensor Control"),
    huami("0002", "Huami Legacy Raw Sensor Data"),
    huami("0003", "Huami Legacy Configuration"),
    huami("0005", "Huami Legacy Activity Data"),
    huami("0006", "Huami Legacy Battery Information"),
    huami("0007", "Huami Legacy Realtime Steps"),
    huami("0008", "Huami Legacy User Settings"),
    huami("0009", "Huami Legacy Authentication"),
    huami("0016", "Huami 2021 Command Channel"),
    huami("0017", "Huami 2021 Response Channel"),
    huami("0023", "Zepp OS File Transfer V3"),
    huami("1531", "Huami Firmware Control"),
    huami("1532", "Huami Firmware Data"),
};

/// Match complete UUIDs, including their namespace. Unknown identifiers stay unknown.
pub fn lookup(kind: Kind, uuid: []const u8) ?[]const u8 {
    const entries: []const Entry = switch (kind) {
        .service => &services,
        .characteristic => &characteristics,
    };
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.uuid, uuid)) return entry.name;
    }
    return null;
}

test "names distinguish UUID namespaces and service/characteristic kinds" {
    try std.testing.expectEqualStrings("Battery Level", lookup(.characteristic, "00002A19-0000-1000-8000-00805F9B34FB").?);
    try std.testing.expectEqualStrings("Huami 2021 Command Channel", lookup(.characteristic, "00000016-0000-3512-2118-0009af100700").?);
    try std.testing.expect(lookup(.characteristic, "00000016-0000-1000-8000-00805f9b34fb") == null);
    try std.testing.expect(lookup(.service, "00002a19-0000-1000-8000-00805f9b34fb") == null);
    try std.testing.expect(lookup(.service, "cc353442-be58-4ea2-876e-11d8d6976366") == null);
    try std.testing.expect(lookup(.characteristic, "2a19") == null);
}

test "catalog contains no duplicate UUIDs within each kind" {
    for ([_]Kind{ .service, .characteristic }) |kind| {
        const entries: []const Entry = if (kind == .service) &services else &characteristics;
        for (entries, 0..) |entry, index| {
            try std.testing.expect(entry.name.len > 0);
            for (entries[index + 1 ..]) |other| {
                try std.testing.expect(!std.ascii.eqlIgnoreCase(entry.uuid, other.uuid));
            }
        }
    }
}
