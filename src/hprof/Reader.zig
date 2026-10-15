//! HPROF top-level record iterator.
const std = @import("std");
const Types = @import("Types.zig");
const Header = @import("Header.zig");
const Record = @import("Record.zig");
const Cursor = Types.Cursor;
const Error = Types.Error;
const log = @import("log");

pub const Reader = struct {
    cursor: Cursor,
    id_size: u32,
    timestamp: u64,

    pub fn init(data: []const u8) Error!Reader {
        const header = try Header.parse(data);
        log.debug("hprof reader initialized: id_size={d}, timestamp={d}", .{ header.id_size, header.timestamp });
        return .{
            .cursor = Cursor.init(data[Header.header_size..]),
            .id_size = header.id_size,
            .timestamp = header.timestamp,
        };
    }

    pub fn next(self: *Reader) Error!?Record.Record {
        if (self.cursor.isEmpty()) return null;
        const tag_byte = try self.cursor.readU1();
        const tag = try Types.recordTagFromInt(tag_byte);
        _ = try self.cursor.readU4(); // microseconds
        const length = try self.cursor.readU4();
        const body = try self.cursor.readBytes(length);
        const body_offset = @intFromPtr(body.ptr) - @intFromPtr(self.cursor.buf.ptr) + Header.header_size;
        log.debug("hprof record: tag={s}, length={d}, body_offset={d}", .{ @tagName(tag), length, body_offset });
        return try Record.decodeWithOffset(tag, body, self.id_size, body_offset);
    }
};

test "parse minimal HPROF file" {
    const id_size: u32 = 4;
    var buf: [256]u8 = undefined;
    var pos: usize = 0;

    // Header
    @memcpy(buf[pos..pos + Header.magic.len], Header.magic);
    pos += Header.magic.len;
    buf[pos] = 0;
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], id_size, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;

    // UTF8 record: id=0x1234, bytes="java/lang/Object"
    const utf8_id: u32 = 0x1234;
    const utf8_bytes = "java/lang/Object";
    buf[pos] = @intFromEnum(Types.RecordTag.utf8);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // microseconds
    pos += 4;
    const utf8_body_len = id_size + utf8_bytes.len;
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(utf8_body_len), .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], utf8_id, .big);
    pos += 4;
    @memcpy(buf[pos..pos + utf8_bytes.len], utf8_bytes);
    pos += utf8_bytes.len;

    // LOAD_CLASS record
    buf[pos] = @intFromEnum(Types.RecordTag.load_class);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // microseconds
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 16, .big); // body length
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .big); // serial
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0x5678, .big); // class_id
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // stack_trace_serial
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], utf8_id, .big); // name_id
    pos += 4;

    // HEAP_DUMP record with two sub-records
    buf[pos] = @intFromEnum(Types.RecordTag.heap_dump);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // microseconds
    pos += 4;
    const heap_body_start = pos;
    pos += 4; // length placeholder

    // GC_ROOT_UNKNOWN
    buf[pos] = @intFromEnum(Types.HeapSubtag.gc_root_unknown);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0x1111, .big);
    pos += 4;

    // GC_INSTANCE_DUMP
    buf[pos] = @intFromEnum(Types.HeapSubtag.gc_instance_dump);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0x2222, .big); // object_id
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // stack_trace_serial
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0x5678, .big); // class_id
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // bytes length
    pos += 4;

    const heap_body_len = pos - heap_body_start - 4;
    std.mem.writeInt(u32, buf[heap_body_start..][0..4], @intCast(heap_body_len), .big);

    var reader = try Reader.init(buf[0..pos]);

    const utf8_record = (try reader.next()).?;
    try std.testing.expectEqual(Types.RecordTag.utf8, std.meta.activeTag(utf8_record));
    try std.testing.expectEqual(@as(Types.Id, 0x1234), utf8_record.utf8.id);
    try std.testing.expectEqualStrings(utf8_bytes, utf8_record.utf8.bytes);

    const load_class_record = (try reader.next()).?;
    try std.testing.expectEqual(Types.RecordTag.load_class, std.meta.activeTag(load_class_record));
    try std.testing.expectEqual(@as(u32, 1), load_class_record.load_class.serial);
    try std.testing.expectEqual(@as(Types.Id, 0x5678), load_class_record.load_class.class_id);

    const heap_record = (try reader.next()).?;
    try std.testing.expectEqual(Types.RecordTag.heap_dump, std.meta.activeTag(heap_record));
    var hr = heap_record.heap_dump;

    const sub1 = (try hr.next()).?;
    try std.testing.expectEqual(Types.HeapSubtag.gc_root_unknown, std.meta.activeTag(sub1));
    try std.testing.expectEqual(@as(Types.Id, 0x1111), sub1.gc_root_unknown);

    const sub2 = (try hr.next()).?;
    try std.testing.expectEqual(Types.HeapSubtag.gc_instance_dump, std.meta.activeTag(sub2));
    try std.testing.expectEqual(@as(Types.Id, 0x2222), sub2.gc_instance_dump.object_id);
    try std.testing.expectEqual(@as(Types.Id, 0x5678), sub2.gc_instance_dump.class_id);

    try std.testing.expectEqual(@as(?Record.Record, null), try reader.next());
}
