//! HPROF file header parsing.
const std = @import("std");
const Types = @import("Types.zig");
const Cursor = Types.Cursor;
const Error = Types.Error;

pub const Header = struct {
    id_size: u32,
    timestamp: u64,
};

pub const magic = "JAVA PROFILE 1.0.2";
pub const header_size = magic.len + 1 + 4 + 4 + 4; // magic + null + id_size + high + low

pub fn parse(data: []const u8) Error!Header {
    if (data.len < header_size) return Error.TruncatedRecord;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return Error.InvalidMagic;
    if (data[magic.len] != 0) return Error.InvalidMagic;

    var c = Cursor.init(data[magic.len + 1 ..]);
    const id_size = try c.readU4();
    const high = try c.readU4();
    const low = try c.readU4();

    if (id_size != 4 and id_size != 8) return Error.InvalidIdSize;

    return .{
        .id_size = id_size,
        .timestamp = (@as(u64, high) << 32) | @as(u64, low),
    };
}

test "parse valid header" {
    const id_size: u32 = 8;
    const high: u32 = 0x00000001;
    const low: u32 = 0x23456789;
    var data: [header_size]u8 = undefined;
    @memcpy(data[0..magic.len], magic);
    data[magic.len] = 0;
    std.mem.writeInt(u32, data[magic.len + 1 ..][0..4], id_size, .big);
    std.mem.writeInt(u32, data[magic.len + 5 ..][0..4], high, .big);
    std.mem.writeInt(u32, data[magic.len + 9 ..][0..4], low, .big);

    const header = try parse(&data);
    try std.testing.expectEqual(id_size, header.id_size);
    try std.testing.expectEqual((@as(u64, high) << 32) | @as(u64, low), header.timestamp);
}

test "parse rejects invalid magic" {
    var data = [_]u8{0} ** header_size;
    try std.testing.expectError(Error.InvalidMagic, parse(&data));
}

test "parse rejects bad id size" {
    var data: [header_size]u8 = undefined;
    @memcpy(data[0..magic.len], magic);
    data[magic.len] = 0;
    std.mem.writeInt(u32, data[magic.len + 1 ..][0..4], 2, .big);
    std.mem.writeInt(u32, data[magic.len + 5 ..][0..4], 0, .big);
    std.mem.writeInt(u32, data[magic.len + 9 ..][0..4], 0, .big);

    try std.testing.expectError(Error.InvalidIdSize, parse(&data));
}
