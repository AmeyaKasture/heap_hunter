//! HPROF heap dump sub-record parser.
const std = @import("std");
const Types = @import("Types.zig");
const Cursor = Types.Cursor;
const Error = Types.Error;
const Id = Types.Id;
const PrimitiveType = Types.PrimitiveType;
const Value = Types.Value;
const readPrimitiveType = Types.readPrimitiveType;

pub const ConstantPoolEntry = struct {
    index: u16,
    type: PrimitiveType,
    value: Value,
};

pub const StaticField = struct {
    name_id: Id,
    type: PrimitiveType,
    value: Value,
};

pub const InstanceField = struct {
    name_id: Id,
    type: PrimitiveType,
};

pub const ConstantPoolIterator = struct {
    cursor: Cursor,
    id_size: u32,
    count: u16,
    index: u16,

    pub fn init(raw: []const u8, id_size: u32) ConstantPoolIterator {
        return .{
            .cursor = Cursor.init(raw),
            .id_size = id_size,
            .count = 0,
            .index = 0,
        };
    }

    pub fn countFromHead(self: *ConstantPoolIterator) Error!u16 {
        if (self.count == 0 and self.cursor.remaining() >= 2) {
            self.count = try self.cursor.readU2();
        }
        return self.count;
    }

    pub fn next(self: *ConstantPoolIterator) Error!?ConstantPoolEntry {
        const total = try self.countFromHead();
        if (self.index >= total) return null;
        const index = try self.cursor.readU2();
        const ty = try readPrimitiveType(&self.cursor);
        const value = try self.cursor.readValue(ty, self.id_size);
        self.index += 1;
        return .{
            .index = index,
            .type = ty,
            .value = value,
        };
    }
};

pub const StaticFieldIterator = struct {
    cursor: Cursor,
    id_size: u32,
    count: u16,
    index: u16,

    pub fn init(raw: []const u8, id_size: u32) StaticFieldIterator {
        return .{
            .cursor = Cursor.init(raw),
            .id_size = id_size,
            .count = 0,
            .index = 0,
        };
    }

    pub fn countFromHead(self: *StaticFieldIterator) Error!u16 {
        if (self.count == 0 and self.cursor.remaining() >= 2) {
            self.count = try self.cursor.readU2();
        }
        return self.count;
    }

    pub fn next(self: *StaticFieldIterator) Error!?StaticField {
        const total = try self.countFromHead();
        if (self.index >= total) return null;
        const name_id = try self.cursor.readId(self.id_size);
        const ty = try readPrimitiveType(&self.cursor);
        const value = try self.cursor.readValue(ty, self.id_size);
        self.index += 1;
        return .{
            .name_id = name_id,
            .type = ty,
            .value = value,
        };
    }
};

pub const InstanceFieldIterator = struct {
    cursor: Cursor,
    id_size: u32,
    count: u16,
    index: u16,

    pub fn init(raw: []const u8, id_size: u32) InstanceFieldIterator {
        return .{
            .cursor = Cursor.init(raw),
            .id_size = id_size,
            .count = 0,
            .index = 0,
        };
    }

    pub fn countFromHead(self: *InstanceFieldIterator) Error!u16 {
        if (self.count == 0 and self.cursor.remaining() >= 2) {
            self.count = try self.cursor.readU2();
        }
        return self.count;
    }

    pub fn next(self: *InstanceFieldIterator) Error!?InstanceField {
        const total = try self.countFromHead();
        if (self.index >= total) return null;
        const name_id = try self.cursor.readId(self.id_size);
        const ty = try readPrimitiveType(&self.cursor);
        self.index += 1;
        return .{
            .name_id = name_id,
            .type = ty,
        };
    }
};

pub const ClassDump = struct {
    class_id: Id,
    stack_trace_serial: u32,
    super_class_id: Id,
    class_loader_id: Id,
    signers_id: Id,
    protection_domain_id: Id,
    reserved1: Id,
    reserved2: Id,
    instance_size: u32,
    constant_pool_raw: []const u8,
    static_fields_raw: []const u8,
    instance_fields_raw: []const u8,

    pub fn constantPoolIterator(self: ClassDump, id_size: u32) ConstantPoolIterator {
        return ConstantPoolIterator.init(self.constant_pool_raw, id_size);
    }

    pub fn staticFieldIterator(self: ClassDump, id_size: u32) StaticFieldIterator {
        return StaticFieldIterator.init(self.static_fields_raw, id_size);
    }

    pub fn instanceFieldIterator(self: ClassDump, id_size: u32) InstanceFieldIterator {
        return InstanceFieldIterator.init(self.instance_fields_raw, id_size);
    }
};

pub const InstanceDump = struct {
    object_id: Id,
    stack_trace_serial: u32,
    class_id: Id,
    bytes: []const u8,
};

pub const ObjectArrayDump = struct {
    array_id: Id,
    stack_trace_serial: u32,
    element_count: u32,
    class_id: Id,
    elements_raw: []const u8,

    pub fn element(self: ObjectArrayDump, index: u32, id_size: u32) Error!Id {
        if (index >= self.element_count) return Error.BufferOverflow;
        var c = Cursor.init(self.elements_raw[index * id_size ..][0..id_size]);
        return c.readId(id_size);
    }
};

pub const PrimitiveArrayDump = struct {
    array_id: Id,
    stack_trace_serial: u32,
    element_type: PrimitiveType,
    element_count: u32,
    bytes: []const u8,
};

pub const HeapRecord = union(Types.HeapSubtag) {
    gc_root_jni_global: struct {
        object_id: Id,
        jni_ref_id: Id,
    },
    gc_root_jni_local: struct {
        object_id: Id,
        thread_serial: u32,
        frame: i32,
    },
    gc_root_java_frame: struct {
        object_id: Id,
        thread_serial: u32,
        frame: i32,
    },
    gc_root_native_stack: struct {
        object_id: Id,
        thread_serial: u32,
    },
    gc_root_sticky_class: Id,
    gc_root_thread_block: struct {
        object_id: Id,
        thread_serial: u32,
    },
    gc_root_monitor_used: Id,
    gc_root_thread_object: struct {
        thread_object_id: Id,
        thread_serial: u32,
        stack_trace_serial: u32,
    },
    gc_class_dump: ClassDump,
    gc_instance_dump: InstanceDump,
    gc_obj_array_dump: ObjectArrayDump,
    gc_prim_array_dump: PrimitiveArrayDump,
    gc_root_unknown: Id,
};

pub const HeapRecordWithOffset = struct {
    /// Absolute byte offset of the sub-record body (after the subtag byte)
    /// in the original HPROF file.
    body_offset: usize,
    record: HeapRecord,
};

pub const Reader = struct {
    cursor: Cursor,
    id_size: u32,
    /// Absolute offset of `cursor.buf[0]` in the original HPROF file.
    body_offset: usize,

    pub fn init(body: []const u8, id_size: u32) Reader {
        return .{
            .cursor = Cursor.init(body),
            .id_size = id_size,
            .body_offset = 0,
        };
    }

    pub fn initWithOffset(body: []const u8, id_size: u32, body_offset: usize) Reader {
        return .{
            .cursor = Cursor.init(body),
            .id_size = id_size,
            .body_offset = body_offset,
        };
    }

    pub fn next(self: *Reader) Error!?HeapRecord {
        const with_offset = try self.nextWithOffset();
        return if (with_offset) |wo| wo.record else null;
    }

    pub fn nextWithOffset(self: *Reader) Error!?HeapRecordWithOffset {
        if (self.cursor.isEmpty()) return null;
        const subtag_start = self.cursor.pos;
        const subtag_byte = try self.cursor.readU1();
        const subtag = try Types.heapSubtagFromInt(subtag_byte);
        return .{
            .body_offset = self.body_offset + subtag_start + 1,
            .record = try self.readSubtag(subtag),
        };
    }

    fn readSubtag(self: *Reader, subtag: Types.HeapSubtag) Error!HeapRecord {
        const c = &self.cursor;
        const id_size = self.id_size;
        switch (subtag) {
            .gc_root_unknown => {
                return .{ .gc_root_unknown = try c.readId(id_size) };
            },
            .gc_root_jni_global => {
                return .{ .gc_root_jni_global = .{
                    .object_id = try c.readId(id_size),
                    .jni_ref_id = try c.readId(id_size),
                } };
            },
            .gc_root_jni_local => {
                return .{ .gc_root_jni_local = .{
                    .object_id = try c.readId(id_size),
                    .thread_serial = try c.readU4(),
                    .frame = try c.readI4(),
                } };
            },
            .gc_root_java_frame => {
                return .{ .gc_root_java_frame = .{
                    .object_id = try c.readId(id_size),
                    .thread_serial = try c.readU4(),
                    .frame = try c.readI4(),
                } };
            },
            .gc_root_native_stack => {
                return .{ .gc_root_native_stack = .{
                    .object_id = try c.readId(id_size),
                    .thread_serial = try c.readU4(),
                } };
            },
            .gc_root_sticky_class => {
                return .{ .gc_root_sticky_class = try c.readId(id_size) };
            },
            .gc_root_thread_block => {
                return .{ .gc_root_thread_block = .{
                    .object_id = try c.readId(id_size),
                    .thread_serial = try c.readU4(),
                } };
            },
            .gc_root_monitor_used => {
                return .{ .gc_root_monitor_used = try c.readId(id_size) };
            },
            .gc_root_thread_object => {
                return .{ .gc_root_thread_object = .{
                    .thread_object_id = try c.readId(id_size),
                    .thread_serial = try c.readU4(),
                    .stack_trace_serial = try c.readU4(),
                } };
            },
            .gc_class_dump => {
                return .{ .gc_class_dump = try self.readClassDump() };
            },
            .gc_instance_dump => {
                const object_id = try c.readId(id_size);
                const stack_trace_serial = try c.readU4();
                const class_id = try c.readId(id_size);
                const byte_count = try c.readU4();
                const bytes = try c.readBytes(byte_count);
                return .{ .gc_instance_dump = .{
                    .object_id = object_id,
                    .stack_trace_serial = stack_trace_serial,
                    .class_id = class_id,
                    .bytes = bytes,
                } };
            },
            .gc_obj_array_dump => {
                const array_id = try c.readId(id_size);
                const stack_trace_serial = try c.readU4();
                const element_count = try c.readU4();
                const class_id = try c.readId(id_size);
                const elements_raw = try c.readBytes(@as(usize, element_count) * id_size);
                return .{ .gc_obj_array_dump = .{
                    .array_id = array_id,
                    .stack_trace_serial = stack_trace_serial,
                    .element_count = element_count,
                    .class_id = class_id,
                    .elements_raw = elements_raw,
                } };
            },
            .gc_prim_array_dump => {
                const array_id = try c.readId(id_size);
                const stack_trace_serial = try c.readU4();
                const element_count = try c.readU4();
                const element_type = try readPrimitiveType(c);
                const byte_count = @as(usize, element_count) * element_type.size(id_size);
                const bytes = try c.readBytes(byte_count);
                return .{ .gc_prim_array_dump = .{
                    .array_id = array_id,
                    .stack_trace_serial = stack_trace_serial,
                    .element_type = element_type,
                    .element_count = element_count,
                    .bytes = bytes,
                } };
            },
        }
    }

    fn readClassDump(self: *Reader) Error!ClassDump {
        const c = &self.cursor;
        const id_size = self.id_size;

        const class_id = try c.readId(id_size);
        const stack_trace_serial = try c.readU4();
        const super_class_id = try c.readId(id_size);
        const class_loader_id = try c.readId(id_size);
        const signers_id = try c.readId(id_size);
        const protection_domain_id = try c.readId(id_size);
        const reserved1 = try c.readId(id_size);
        const reserved2 = try c.readId(id_size);
        const instance_size = try c.readU4();

        const cp_start = c.pos;
        const cp_count = try c.readU2();
        var i: usize = 0;
        while (i < cp_count) : (i += 1) {
            _ = try c.readU2();
            const ty = try readPrimitiveType(c);
            try c.skipValue(ty, id_size);
        }
        const cp_end = c.pos;

        const sf_start = c.pos;
        const sf_count = try c.readU2();
        i = 0;
        while (i < sf_count) : (i += 1) {
            c.pos += id_size;
            const ty = try readPrimitiveType(c);
            try c.skipValue(ty, id_size);
        }
        const sf_end = c.pos;

        const if_start = c.pos;
        const if_count = try c.readU2();
        i = 0;
        while (i < if_count) : (i += 1) {
            c.pos += id_size;
            _ = try c.readU1();
        }
        const if_end = c.pos;

        return .{
            .class_id = class_id,
            .stack_trace_serial = stack_trace_serial,
            .super_class_id = super_class_id,
            .class_loader_id = class_loader_id,
            .signers_id = signers_id,
            .protection_domain_id = protection_domain_id,
            .reserved1 = reserved1,
            .reserved2 = reserved2,
            .instance_size = instance_size,
            .constant_pool_raw = c.buf[cp_start..cp_end],
            .static_fields_raw = c.buf[sf_start..sf_end],
            .instance_fields_raw = c.buf[if_start..if_end],
        };
    }
};

test "parse class dump" {
    const id_size: u32 = 4;
    var buf: [256]u8 = undefined;
    var pos: usize = 0;

    buf[pos] = @intFromEnum(Types.HeapSubtag.gc_class_dump);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0xAAAA, .big); // class_id
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .big); // stack_trace_serial
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0xBBBB, .big); // super_class_id
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0xCCCC, .big); // class_loader_id
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0xDDDD, .big); // signers_id
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0xEEEE, .big); // protection_domain_id
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // reserved1
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // reserved2
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 16, .big); // instance_size
    pos += 4;

    std.mem.writeInt(u16, buf[pos..][0..2], 0, .big); // constant pool count
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], 0, .big); // static field count
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], 1, .big); // instance field count
    pos += 2;
    std.mem.writeInt(u32, buf[pos..][0..4], 0x1234, .big); // field name id
    pos += 4;
    buf[pos] = @intFromEnum(Types.PrimitiveType.int); // field type
    pos += 1;

    var hr = Reader.init(buf[0..pos], id_size);
    const record = (try hr.next()).?;
    try std.testing.expectEqual(Types.HeapSubtag.gc_class_dump, std.meta.activeTag(record));
    const class = record.gc_class_dump;
    try std.testing.expectEqual(@as(Types.Id, 0xAAAA), class.class_id);
    try std.testing.expectEqual(@as(Types.Id, 0xBBBB), class.super_class_id);
    try std.testing.expectEqual(@as(u32, 16), class.instance_size);

    var it = class.instanceFieldIterator(id_size);
    const field = (try it.next()).?;
    try std.testing.expectEqual(@as(Types.Id, 0x1234), field.name_id);
    try std.testing.expectEqual(Types.PrimitiveType.int, field.type);
    try std.testing.expectEqual(@as(?InstanceField, null), try it.next());
}
