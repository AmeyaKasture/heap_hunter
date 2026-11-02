//! Decoding of well-known Java objects held in the heap dump.
//!
//! Today: `java.lang.String` text decoding (backing `char[]` UTF-16,
//! or JDK 9+ compact strings in `byte[]` with a `coder` field).
//! A home for future class-aware decoders (collections, boxed values...).
const std = @import("std");
const hprof = @import("hprof.zig");

pub fn decodeLatin1(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    for (bytes) |b| {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(b, &buf) catch {
            try result.appendSlice(allocator, "?");
            continue;
        };
        try result.appendSlice(allocator, buf[0..len]);
    }
    return result.toOwnedSlice(allocator);
}

pub fn decodeUtf16(allocator: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian) std.mem.Allocator.Error![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i + 1 < bytes.len) {
        const cu = std.mem.readInt(u16, bytes[i .. i + 2][0..2], endian);
        i += 2;
        var codepoint: u21 = cu;
        if (cu >= 0xD800 and cu <= 0xDBFF) {
            if (i + 1 >= bytes.len) break;
            const low = std.mem.readInt(u16, bytes[i .. i + 2][0..2], endian);
            i += 2;
            if (low < 0xDC00 or low > 0xDFFF) continue;
            codepoint = 0x10000 + ((@as(u21, cu & 0x3FF) << 10) | @as(u21, low & 0x3FF));
        } else if (cu >= 0xDC00 and cu <= 0xDFFF) {
            continue;
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
            try result.appendSlice(allocator, "?");
            continue;
        };
        try result.appendSlice(allocator, buf[0..len]);
    }
    return result.toOwnedSlice(allocator);
}

/// Decode the backing array of a `java.lang.String` instance.
/// Returns `null` when the array is not a string backing store
/// (e.g. an `int[]`), so callers can skip preview emission.
pub fn decodeStringBacking(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    element_type: hprof.PrimitiveType,
    coder: ?u8,
) std.mem.Allocator.Error!?[]const u8 {
    return switch (element_type) {
        .char => try decodeUtf16(allocator, bytes, .big),
        .byte => if (coder == 1)
            try decodeUtf16(allocator, bytes, .little)
        else
            try decodeLatin1(allocator, bytes),
        else => null,
    };
}

/// True when the code unit renders safely inside a JSON string value
/// without special care (printable, non-control, not a lone surrogate).
pub fn isPrintableChar(c: u16) bool {
    if (c < 0x20) return false;
    if (c >= 0xD800 and c <= 0xDFFF) return false;
    if (c == 0x7F) return false;
    if (c >= 0x80 and c <= 0x9F) return false;
    return true;
}

/// UTF-8 encode a code unit into `buf` (must be 4 bytes).
/// Unpaired surrogates encode as U+FFFD to keep output valid UTF-8.
pub fn encodeCharUtf8(c: u16, buf: *[4]u8) []const u8 {
    const codepoint: u21 = if (c >= 0xD800 and c <= 0xDFFF) 0xFFFD else c;
    const len = std.unicode.utf8Encode(codepoint, buf) catch {
        buf[0] = '?';
        return buf[0..1];
    };
    return buf[0..len];
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "decodeLatin1 handles ASCII and high bytes" {
    const allocator = std.testing.allocator;
    const a = try decodeLatin1(allocator, "main");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("main", a);

    const e = try decodeLatin1(allocator, &[_]u8{ 'c', 'a', 'f', 0xE9 });
    defer allocator.free(e);
    try std.testing.expectEqualStrings("caf\u{00e9}", e);
}

test "decodeUtf16 big-endian decodes char arrays" {
    const allocator = std.testing.allocator;
    const s = try decodeUtf16(allocator, &[_]u8{ 0, 'm', 0, 'a', 0, 'i', 0, 'n' }, .big);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("main", s);
}

test "decodeUtf16 little-endian decodes compact strings" {
    const allocator = std.testing.allocator;
    const s = try decodeUtf16(allocator, &[_]u8{ 'h', 0, 0xE9, 0, 'i', 0 }, .little);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("h\u{00e9}i", s);
}

test "decodeUtf16 combines surrogate pairs" {
    const allocator = std.testing.allocator;
    // U+1F600 = D83D DE00 (big-endian bytes).
    const s = try decodeUtf16(allocator, &[_]u8{ 0xD8, 0x3D, 0xDE, 0x00 }, .big);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("\u{1f600}", s);
}

test "decodeUtf16 drops trailing unpaired high surrogate" {
    const allocator = std.testing.allocator;
    const s = try decodeUtf16(allocator, &[_]u8{ 0, 'a', 0xD8, 0x3D }, .big);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("a", s);
}

test "decodeStringBacking dispatches by element type and coder" {
    const allocator = std.testing.allocator;
    const char_bytes = [_]u8{ 0, 'm', 0, 'a', 0, 'i', 0, 'n' };

    const s1 = (try decodeStringBacking(allocator, &char_bytes, .char, null)).?;
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("main", s1);

    const s2 = (try decodeStringBacking(allocator, "main", .byte, null)).?;
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("main", s2);

    const le_bytes = [_]u8{ 'm', 0, 'a', 0, 'i', 0, 'n', 0 };
    const s3 = (try decodeStringBacking(allocator, &le_bytes, .byte, 1)).?;
    defer allocator.free(s3);
    try std.testing.expectEqualStrings("main", s3);

    try std.testing.expectEqual(@as(?[]const u8, null), try decodeStringBacking(allocator, "x", .int, null));
}

test "isPrintableChar and encodeCharUtf8" {
    try std.testing.expect(isPrintableChar('A'));
    try std.testing.expect(isPrintableChar(0xE9));
    try std.testing.expect(!isPrintableChar('\t'));
    try std.testing.expect(!isPrintableChar(0x7F));
    try std.testing.expect(!isPrintableChar(0x9F));
    try std.testing.expect(!isPrintableChar(0xD800));

    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("A", encodeCharUtf8('A', &buf));
    try std.testing.expectEqualStrings("\u{fffd}", encodeCharUtf8(0xD800, &buf));
    try std.testing.expectEqualStrings("\u{00e9}", encodeCharUtf8(0xE9, &buf));
}
