//! HPROF primitive types, tag enums, error set, and byte-cursor helpers.
const std = @import("std");

pub const Id = u64;

pub const PrimitiveType = enum(u8) {
    array_object = 1,
    object = 2,
    boolean = 4,
    char = 5,
    float = 6,
    double = 7,
    byte = 8,
    short = 9,
    int = 10,
    long = 11,

    pub fn size(self: PrimitiveType, id_size: u32) u32 {
        return switch (self) {
            .array_object => id_size,
            .object => id_size,
            .boolean => 1,
            .byte => 1,
            .char => 2,
            .short => 2,
            .float => 4,
            .int => 4,
            .double => 8,
            .long => 8,
        };
    }
};

pub const Value = union(PrimitiveType) {
    array_object: Id,
    object: Id,
    boolean: bool,
    char: u16,
    float: f32,
    double: f64,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
};

pub const RecordTag = enum(u8) {
    utf8 = 0x01,
    load_class = 0x02,
    unload_class = 0x03,
    frame = 0x04,
    trace = 0x05,
    alloc_sites = 0x06,
    heap_summary = 0x07,
    start_thread = 0x0a,
    end_thread = 0x0b,
    heap_dump = 0x0c,
    cpu_samples = 0x0d,
    control_settings = 0x0e,
    heap_dump_segment = 0x1c,
    heap_dump_end = 0x2c,
};

pub const HeapSubtag = enum(u8) {
    gc_root_jni_global = 0x01,
    gc_root_jni_local = 0x02,
    gc_root_java_frame = 0x03,
    gc_root_native_stack = 0x04,
    gc_root_sticky_class = 0x05,
    gc_root_thread_block = 0x06,
    gc_root_monitor_used = 0x07,
    gc_root_thread_object = 0x08,
    gc_class_dump = 0x20,
    gc_instance_dump = 0x21,
    gc_obj_array_dump = 0x22,
    gc_prim_array_dump = 0x23,
    gc_root_unknown = 0xff,
};

pub const Error = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidIdSize,
    TruncatedRecord,
    UnknownRecordTag,
    UnknownHeapSubtag,
    InvalidPrimitiveType,
    BufferOverflow,
};

pub const Cursor = struct {
    buf: []const u8,
    pos: usize,

    pub fn init(buf: []const u8) Cursor {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn remaining(self: Cursor) usize {
        return self.buf.len - self.pos;
    }

    pub fn isEmpty(self: Cursor) bool {
        return self.pos >= self.buf.len;
    }

    pub fn readU1(self: *Cursor) Error!u8 {
        if (self.pos + 1 > self.buf.len) return Error.TruncatedRecord;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readU2(self: *Cursor) Error!u16 {
        if (self.pos + 2 > self.buf.len) return Error.TruncatedRecord;
        const v = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    pub fn readU4(self: *Cursor) Error!u32 {
        if (self.pos + 4 > self.buf.len) return Error.TruncatedRecord;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    pub fn readU8(self: *Cursor) Error!u64 {
        if (self.pos + 8 > self.buf.len) return Error.TruncatedRecord;
        const v = std.mem.readInt(u64, self.buf[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    pub fn readI4(self: *Cursor) Error!i32 {
        if (self.pos + 4 > self.buf.len) return Error.TruncatedRecord;
        const v = std.mem.readInt(i32, self.buf[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    pub fn readId(self: *Cursor, id_size: u32) Error!Id {
        switch (id_size) {
            4 => return @as(Id, try self.readU4()),
            8 => return try self.readU8(),
            else => return Error.InvalidIdSize,
        }
    }

    pub fn readBytes(self: *Cursor, len: usize) Error![]const u8 {
        if (self.pos + len > self.buf.len) return Error.TruncatedRecord;
        const v = self.buf[self.pos .. self.pos + len];
        self.pos += len;
        return v;
    }

    pub fn readValue(self: *Cursor, ty: PrimitiveType, id_size: u32) Error!Value {
        return switch (ty) {
            .array_object => .{ .array_object = try self.readId(id_size) },
            .object => .{ .object = try self.readId(id_size) },
            .boolean => .{ .boolean = (try self.readU1()) != 0 },
            .char => .{ .char = try self.readU2() },
            .float => .{ .float = @bitCast(try self.readU4()) },
            .double => .{ .double = @bitCast(try self.readU8()) },
            .byte => .{ .byte = @bitCast(try self.readU1()) },
            .short => .{ .short = @bitCast(try self.readU2()) },
            .int => .{ .int = @bitCast(try self.readU4()) },
            .long => .{ .long = @bitCast(try self.readU8()) },
        };
    }

    pub fn skipValue(self: *Cursor, ty: PrimitiveType, id_size: u32) Error!void {
        const s = ty.size(id_size);
        if (self.pos + s > self.buf.len) return Error.TruncatedRecord;
        self.pos += s;
    }
};

pub fn readPrimitiveType(c: *Cursor) Error!PrimitiveType {
    const ty = try c.readU1();
    inline for (@typeInfo(PrimitiveType).@"enum".fields) |field| {
        if (field.value == ty) return @as(PrimitiveType, @enumFromInt(ty));
    }
    return Error.InvalidPrimitiveType;
}

pub fn recordTagFromInt(v: u8) Error!RecordTag {
    inline for (@typeInfo(RecordTag).@"enum".fields) |field| {
        if (field.value == v) return @as(RecordTag, @enumFromInt(v));
    }
    return Error.UnknownRecordTag;
}

pub fn heapSubtagFromInt(v: u8) Error!HeapSubtag {
    inline for (@typeInfo(HeapSubtag).@"enum".fields) |field| {
        if (field.value == v) return @as(HeapSubtag, @enumFromInt(v));
    }
    return Error.UnknownHeapSubtag;
}

test "Cursor reads big-endian values" {
    var c = Cursor.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 });
    try std.testing.expectEqual(@as(u8, 0x01), try c.readU1());
    try std.testing.expectEqual(@as(u16, 0x0203), try c.readU2());
    try std.testing.expectEqual(@as(u32, 0x04050607), try c.readU4());
    try std.testing.expectEqual(@as(u8, 0x08), try c.readU1());
}

test "Cursor readId with 4-byte IDs" {
    var c = Cursor.init(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    try std.testing.expectEqual(@as(Id, 0xDEADBEEF), try c.readId(4));
}

test "Cursor readId with 8-byte IDs" {
    var c = Cursor.init(&[_]u8{ 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF });
    try std.testing.expectEqual(@as(Id, 0xDEADBEEF), try c.readId(8));
}
