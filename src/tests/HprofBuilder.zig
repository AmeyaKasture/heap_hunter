//! Synthetic HPROF buffer builder for tests.
const std = @import("std");
const hprof = @import("../hprof.zig");

pub const Id = hprof.Id;
pub const PrimitiveType = hprof.PrimitiveType;
pub const Value = hprof.Value;

pub const InstanceFieldSpec = struct {
    name_id: Id,
    type: PrimitiveType,
};

pub const StaticFieldSpec = struct {
    name_id: Id,
    type: PrimitiveType,
    value: ?Value = null,
};

pub const ConstantPoolSpec = struct {
    index: u16,
    type: PrimitiveType,
    value: ?Value = null,
};

pub const ClassDumpOptions = struct {
    class_id: Id,
    super_class_id: Id = 0,
    class_loader_id: Id = 0,
    signers_id: Id = 0,
    protection_domain_id: Id = 0,
    reserved1: Id = 0,
    reserved2: Id = 0,
    instance_size: u32,
    constant_pool: []const ConstantPoolSpec = &.{},
    static_fields: []const StaticFieldSpec = &.{},
    instance_fields: []const InstanceFieldSpec = &.{},
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    id_size: u32,

    pub fn init(allocator: std.mem.Allocator, id_size: u32) Builder {
        return .{
            .allocator = allocator,
            .buf = std.ArrayList(u8).empty,
            .id_size = id_size,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.buf.deinit(self.allocator);
    }

    /// Return the built buffer as an allocator-owned slice. The builder is reset
    /// and may be reused; the caller must free the returned slice.
    pub fn finish(self: *Builder) ![]u8 {
        const result = try self.allocator.dupe(u8, self.buf.items);
        self.buf.clearRetainingCapacity();
        return result;
    }

    pub fn bytesLen(self: *const Builder) usize {
        return self.buf.items.len;
    }

    pub fn header(self: *Builder, timestamp: u64) !void {
        try self.buf.appendSlice(self.allocator, hprof.Header.magic);
        try self.buf.append(self.allocator, 0);
        try self.writeU32(@intCast(self.id_size));
        try self.writeU32(@intCast(timestamp >> 32));
        try self.writeU32(@intCast(timestamp & 0xFFFFFFFF));
    }

    pub fn utf8(self: *Builder, id: Id, bytes: []const u8) !void {
        try self.startRecord(.utf8);
        const start = self.buf.items.len;
        try self.writeId(id);
        try self.buf.appendSlice(self.allocator, bytes);
        self.finishRecord(start);
    }

    pub fn loadClass(self: *Builder, serial: u32, class_id: Id, name_id: Id) !void {
        try self.startRecord(.load_class);
        const start = self.buf.items.len;
        try self.writeU32(serial);
        try self.writeId(class_id);
        try self.writeU32(0); // stack_trace_serial
        try self.writeId(name_id);
        self.finishRecord(start);
    }

    pub fn heapDump(self: *Builder) !HeapDumpBuilder {
        return try HeapDumpBuilder.init(self, .heap_dump);
    }

    pub fn heapDumpSegment(self: *Builder) !HeapDumpBuilder {
        return try HeapDumpBuilder.init(self, .heap_dump_segment);
    }

    fn startRecord(self: *Builder, tag: hprof.RecordTag) !void {
        try self.buf.append(self.allocator, @intFromEnum(tag));
        try self.writeU32(0); // microseconds
        try self.writeU32(0); // length placeholder
    }

    fn finishRecord(self: *Builder, start: usize) void {
        const body_len = self.buf.items.len - start;
        std.mem.writeInt(u32, self.buf.items[start - 4 ..][0..4], @intCast(body_len), .big);
    }

    fn writeU8(self: *Builder, v: u8) !void {
        try self.buf.append(self.allocator, v);
    }

    fn writeU16(self: *Builder, v: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, v, .big);
        try self.buf.appendSlice(self.allocator, &buf);
    }

    fn writeU32(self: *Builder, v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .big);
        try self.buf.appendSlice(self.allocator, &buf);
    }

    fn writeId(self: *Builder, id: Id) !void {
        switch (self.id_size) {
            4 => try self.writeU32(@intCast(id & 0xFFFFFFFF)),
            8 => {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &buf, id, .big);
                try self.buf.appendSlice(self.allocator, &buf);
            },
            else => unreachable,
        }
    }

    fn writePrimitiveType(self: *Builder, ty: PrimitiveType) !void {
        try self.buf.append(self.allocator, @intFromEnum(ty));
    }

    fn writeValue(self: *Builder, ty: PrimitiveType, value: ?Value) !void {
        if (value) |v| {
            switch (ty) {
                .array_object => try self.writeId(v.array_object),
                .object => try self.writeId(v.object),
                .boolean => try self.writeU8(@intFromBool(v.boolean)),
                .char => try self.writeU16(v.char),
                .float => try self.writeU32(@bitCast(v.float)),
                .double => {
                    var buf: [8]u8 = undefined;
                    std.mem.writeInt(u64, &buf, @bitCast(v.double), .big);
                    try self.buf.appendSlice(self.allocator, &buf);
                },
                .byte => try self.writeU8(@bitCast(v.byte)),
                .short => try self.writeU16(@bitCast(v.short)),
                .int => try self.writeU32(@bitCast(v.int)),
                .long => {
                    var buf: [8]u8 = undefined;
                    std.mem.writeInt(u64, &buf, @bitCast(v.long), .big);
                    try self.buf.appendSlice(self.allocator, &buf);
                },
            }
        } else {
            // Write a zero value of the appropriate width.
            const zeroes = switch (ty) {
                .array_object, .object => self.id_size,
                .boolean, .byte => 1,
                .char, .short => 2,
                .float, .int => 4,
                .double, .long => 8,
            };
            try self.buf.appendNTimes(self.allocator, 0, zeroes);
        }
    }

    pub const HeapDumpBuilder = struct {
        parent: *Builder,
        tag: hprof.RecordTag,
        length_pos: usize,
        body_start: usize,

        fn init(parent: *Builder, tag: hprof.RecordTag) !HeapDumpBuilder {
            try parent.startRecord(tag);
            const length_pos = parent.buf.items.len - 4;
            const body_start = parent.buf.items.len;
            return .{
                .parent = parent,
                .tag = tag,
                .length_pos = length_pos,
                .body_start = body_start,
            };
        }

        pub fn end(self: *HeapDumpBuilder) void {
            const body_len = self.parent.buf.items.len - self.body_start;
            std.mem.writeInt(u32, self.parent.buf.items[self.length_pos..][0..4], @intCast(body_len), .big);
        }

        fn subtagBodyOffset(self: *const HeapDumpBuilder) usize {
            return self.parent.buf.items.len + 1; // +1 to skip the subtag byte
        }

        pub fn rootUnknown(self: *HeapDumpBuilder, object_id: Id) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_unknown));
            try self.parent.writeId(object_id);
            return offset;
        }

        pub fn rootStickyClass(self: *HeapDumpBuilder, class_id: Id) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_sticky_class));
            try self.parent.writeId(class_id);
            return offset;
        }

        pub fn rootJniGlobal(self: *HeapDumpBuilder, object_id: Id, jni_ref_id: Id) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_jni_global));
            try self.parent.writeId(object_id);
            try self.parent.writeId(jni_ref_id);
            return offset;
        }

        pub fn rootJniLocal(self: *HeapDumpBuilder, object_id: Id, thread_serial: u32, frame: i32) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_jni_local));
            try self.parent.writeId(object_id);
            try self.parent.writeU32(thread_serial);
            try self.parent.writeU32(@bitCast(frame));
            return offset;
        }

        pub fn rootJavaFrame(self: *HeapDumpBuilder, object_id: Id, thread_serial: u32, frame: i32) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_java_frame));
            try self.parent.writeId(object_id);
            try self.parent.writeU32(thread_serial);
            try self.parent.writeU32(@bitCast(frame));
            return offset;
        }

        pub fn rootNativeStack(self: *HeapDumpBuilder, object_id: Id, thread_serial: u32) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_native_stack));
            try self.parent.writeId(object_id);
            try self.parent.writeU32(thread_serial);
            return offset;
        }

        pub fn rootThreadBlock(self: *HeapDumpBuilder, object_id: Id, thread_serial: u32) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_thread_block));
            try self.parent.writeId(object_id);
            try self.parent.writeU32(thread_serial);
            return offset;
        }

        pub fn rootMonitorUsed(self: *HeapDumpBuilder, object_id: Id) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_monitor_used));
            try self.parent.writeId(object_id);
            return offset;
        }

        pub fn rootThreadObject(self: *HeapDumpBuilder, thread_object_id: Id, thread_serial: u32, stack_trace_serial: u32) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_root_thread_object));
            try self.parent.writeId(thread_object_id);
            try self.parent.writeU32(thread_serial);
            try self.parent.writeU32(stack_trace_serial);
            return offset;
        }

        pub fn classDump(self: *HeapDumpBuilder, options: ClassDumpOptions) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_class_dump));
            try self.parent.writeId(options.class_id);
            try self.parent.writeU32(0); // stack_trace_serial
            try self.parent.writeId(options.super_class_id);
            try self.parent.writeId(options.class_loader_id);
            try self.parent.writeId(options.signers_id);
            try self.parent.writeId(options.protection_domain_id);
            try self.parent.writeId(options.reserved1);
            try self.parent.writeId(options.reserved2);
            try self.parent.writeU32(options.instance_size);

            try self.parent.writeU16(@intCast(options.constant_pool.len));
            for (options.constant_pool) |entry| {
                try self.parent.writeU16(entry.index);
                try self.parent.writePrimitiveType(entry.type);
                try self.parent.writeValue(entry.type, entry.value);
            }

            try self.parent.writeU16(@intCast(options.static_fields.len));
            for (options.static_fields) |field| {
                try self.parent.writeId(field.name_id);
                try self.parent.writePrimitiveType(field.type);
                try self.parent.writeValue(field.type, field.value);
            }

            try self.parent.writeU16(@intCast(options.instance_fields.len));
            for (options.instance_fields) |field| {
                try self.parent.writeId(field.name_id);
                try self.parent.writePrimitiveType(field.type);
            }

            return offset;
        }

        pub fn instanceDump(self: *HeapDumpBuilder, object_id: Id, class_id: Id, bytes: []const u8) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_instance_dump));
            try self.parent.writeId(object_id);
            try self.parent.writeU32(0); // stack_trace_serial
            try self.parent.writeId(class_id);
            try self.parent.writeU32(@intCast(bytes.len));
            try self.parent.buf.appendSlice(self.parent.allocator, bytes);
            return offset;
        }

        pub fn objectArrayDump(self: *HeapDumpBuilder, array_id: Id, class_id: Id, elements: []const Id) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_obj_array_dump));
            try self.parent.writeId(array_id);
            try self.parent.writeU32(0); // stack_trace_serial
            try self.parent.writeU32(@intCast(elements.len));
            try self.parent.writeId(class_id);
            for (elements) |elem| {
                try self.parent.writeId(elem);
            }
            return offset;
        }

        pub fn primitiveArrayDump(self: *HeapDumpBuilder, array_id: Id, element_type: PrimitiveType, element_count: u32, bytes: []const u8) !usize {
            const offset = self.subtagBodyOffset();
            try self.parent.buf.append(self.parent.allocator, @intFromEnum(hprof.HeapSubtag.gc_prim_array_dump));
            try self.parent.writeId(array_id);
            try self.parent.writeU32(0); // stack_trace_serial
            try self.parent.writeU32(element_count);
            try self.parent.writePrimitiveType(element_type);
            try self.parent.buf.appendSlice(self.parent.allocator, bytes);
            return offset;
        }
    };
};

test "builder produces parseable HPROF buffer" {
    const allocator = std.testing.allocator;
    var b = Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0x123456789);
    try b.utf8(0x1234, "java/lang/Object");
    try b.loadClass(1, 0x5678, 0x1234);

    var heap = try b.heapDump();
    const root_off = try heap.rootUnknown(0x1111);
    const class_off = try heap.classDump(.{
        .class_id = 0xAAAA,
        .super_class_id = 0xBBBB,
        .instance_size = 16,
        .instance_fields = &.{
            .{ .name_id = 0x1234, .type = .object },
        },
    });
    const inst_off = try heap.instanceDump(0x2222, 0x5678, &[_]u8{0} ** 8);
    _ = try heap.objectArrayDump(0x3333, 0x5678, &[_]Id{ 0x4444, 0, 0x5555 });
    _ = try heap.primitiveArrayDump(0x6666, .int, 2, &[_]u8{0, 0, 0, 0, 0, 0, 0, 0});
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var reader = try hprof.Reader.init(bytes);
    try std.testing.expectEqual(@as(u32, 4), reader.id_size);
    try std.testing.expectEqual(@as(u64, 0x123456789), reader.timestamp);

    const utf8_rec = (try reader.next()).?;
    try std.testing.expectEqual(hprof.RecordTag.utf8, std.meta.activeTag(utf8_rec));
    try std.testing.expectEqualStrings("java/lang/Object", utf8_rec.utf8.bytes);

    const lc_rec = (try reader.next()).?;
    try std.testing.expectEqual(hprof.RecordTag.load_class, std.meta.activeTag(lc_rec));
    try std.testing.expectEqual(@as(Id, 0x5678), lc_rec.load_class.class_id);

    const heap_rec = (try reader.next()).?;
    try std.testing.expectEqual(hprof.RecordTag.heap_dump, std.meta.activeTag(heap_rec));
    var hr = heap_rec.heap_dump;

    const r1 = (try hr.nextWithOffset()).?;
    try std.testing.expectEqual(hprof.HeapSubtag.gc_root_unknown, std.meta.activeTag(r1.record));
    try std.testing.expectEqual(root_off, r1.body_offset);

    const r2 = (try hr.nextWithOffset()).?;
    try std.testing.expectEqual(hprof.HeapSubtag.gc_class_dump, std.meta.activeTag(r2.record));
    try std.testing.expectEqual(class_off, r2.body_offset);

    const r3 = (try hr.nextWithOffset()).?;
    try std.testing.expectEqual(hprof.HeapSubtag.gc_instance_dump, std.meta.activeTag(r3.record));
    try std.testing.expectEqual(inst_off, r3.body_offset);

    _ = (try hr.next()).?;
    _ = (try hr.next()).?;
    try std.testing.expectEqual(@as(?hprof.HeapRecord, null), try hr.next());

}
