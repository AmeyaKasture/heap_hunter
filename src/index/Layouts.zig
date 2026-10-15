//! Stage 3: resolve flattened instance-field layouts from the class table and
//! persist them as `fields.bin`.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const HeapDump = @import("../hprof/HeapDump.zig");
const Scanner = @import("Scanner.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");

pub const Field = struct {
    name: []const u8,
    type: hprof.PrimitiveType,
    byte_offset: u32,
    declaring_class_raw_id: hprof.Id,
};

pub const Layout = struct {
    class_raw_id: hprof.Id,
    fields: []const Field,
    reference_offsets: []const u32,

    pub fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        for (self.fields) |field| {
            allocator.free(field.name);
        }
        allocator.free(self.fields);
        allocator.free(self.reference_offsets);
    }
};

pub const LayoutTable = struct {
    allocator: std.mem.Allocator,
    layouts: []const Layout,
    by_id: std.AutoHashMap(hprof.Id, usize),
    path: []const u8,

    pub fn deinit(self: *LayoutTable) void {
        self.by_id.deinit();
        for (self.layouts) |layout| {
            layout.deinit(self.allocator);
        }
        self.allocator.free(self.layouts);
        self.allocator.free(self.path);
    }

    pub fn lookup(self: *const LayoutTable, class_raw_id: hprof.Id) ?*const Layout {
        const idx = self.by_id.get(class_raw_id) orelse return null;
        return &self.layouts[idx];
    }
};

fn isReferenceType(ty: hprof.PrimitiveType) bool {
    return ty == .object or ty == .array_object;
}

/// Resolve flattened instance-field layouts for every class in `class_table`,
/// write `fields.bin` to `staging_dir`, and return an in-memory `LayoutTable`.
///
/// Fields are ordered subclass-first (the order used in real HPROF instance
/// bytes), and diagnostics are updated for missing superclasses and cycles.
pub fn writeFields(
    allocator: std.mem.Allocator,
    io: Io,
    staging_dir: []const u8,
    class_table: *const Scanner.ClassTable,
    id_size: u32,
    diagnostics: *Manifest.Diagnostics,
) !LayoutTable {
    // Collect and sort class IDs so the output order matches classes.bin.
    var class_ids = std.ArrayList(hprof.Id).empty;
    defer class_ids.deinit(allocator);

    var class_it = class_table.classes.iterator();
    while (class_it.next()) |entry| {
        try class_ids.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort(hprof.Id, class_ids.items, {}, std.sort.asc(hprof.Id));

    var layouts = std.ArrayList(Layout).empty;
    errdefer {
        for (layouts.items) |layout| {
            layout.deinit(allocator);
        }
        layouts.deinit(allocator);
    }
    var by_id = std.AutoHashMap(hprof.Id, usize).init(allocator);
    errdefer by_id.deinit();

    // Track classes already known to be part of a superclass cycle so that
    // each strongly-connected cycle component is counted once.
    var cyclic_classes = std.AutoHashMap(hprof.Id, void).init(allocator);
    defer cyclic_classes.deinit();

    // Build in-memory layouts first; they are small and we need them for the
    // caller and for the reference-offset mask.
    for (class_ids.items) |class_id| {
        const layout = try buildLayout(
            allocator,
            class_table,
            class_id,
            id_size,
            diagnostics,
            &cyclic_classes,
        );
        errdefer layout.deinit(allocator);
        try layouts.append(allocator, layout);
        try by_id.put(class_id, layouts.items.len - 1);
    }

    const fields_path = try std.fs.path.join(allocator, &.{ staging_dir, "fields.bin" });
    errdefer allocator.free(fields_path);

    const dir = Io.Dir.cwd();
    var fields_file = try dir.createFile(io, fields_path, .{});
    defer fields_file.close(io);
    var file_buf: [65536]u8 = undefined;
    var file_writer: Io.File.Writer = .init(fields_file, io, &file_buf);
    const writer = &file_writer.interface;

    for (layouts.items) |layout| {
        var header: [12]u8 = undefined;
        std.mem.writeInt(u64, header[0..8], layout.class_raw_id, .little);
        std.mem.writeInt(u32, header[8..12], @intCast(layout.fields.len), .little);
        try writer.writeAll(&header);

        for (layout.fields) |field| {
            var name_len: [2]u8 = undefined;
            const name_len_u16 = std.math.cast(u16, field.name.len) orelse return error.FieldNameTooLong;
            std.mem.writeInt(u16, &name_len, name_len_u16, .little);
            try writer.writeAll(&name_len);
            if (field.name.len > 0) {
                try writer.writeAll(field.name);
            }

            var tail: [13]u8 = undefined;
            tail[0] = @intFromEnum(field.type);
            std.mem.writeInt(u32, tail[1..5], field.byte_offset, .little);
            std.mem.writeInt(u64, tail[5..13], field.declaring_class_raw_id, .little);
            try writer.writeAll(&tail);
        }
    }

    try file_writer.flush();

    return .{
        .allocator = allocator,
        .layouts = try layouts.toOwnedSlice(allocator),
        .by_id = by_id,
        .path = fields_path,
    };
}

fn buildLayout(
    allocator: std.mem.Allocator,
    class_table: *const Scanner.ClassTable,
    class_id: hprof.Id,
    id_size: u32,
    diagnostics: *Manifest.Diagnostics,
    cyclic_classes: *std.AutoHashMap(hprof.Id, void),
) !Layout {
    // Walk the superclass chain from the target class upward, subclass-first.
    var chain = std.ArrayList(*const Scanner.ClassEntry).empty;
    defer chain.deinit(allocator);
    // Maps a class id to its index in `chain` so we can identify the classes
    // that participate in a cycle when we revisit one.
    var visited = std.AutoHashMap(hprof.Id, usize).init(allocator);
    defer visited.deinit();

    var cur: hprof.Id = class_id;
    while (cur != 0) {
        if (visited.get(cur)) |cycle_start| {
            var new_cycle_members: usize = 0;
            // cur itself is the repeated class; all entries from cycle_start
            // onward belong to the cycle.
            const cur_result = try cyclic_classes.getOrPut(cur);
            if (!cur_result.found_existing) new_cycle_members += 1;
            for (chain.items[cycle_start..]) |entry| {
                const entry_result = try cyclic_classes.getOrPut(entry.class_id);
                if (!entry_result.found_existing) new_cycle_members += 1;
            }
            if (new_cycle_members > 0) {
                diagnostics.superclass_cycle += 1;
            }
            break;
        }
        try visited.put(cur, chain.items.len);
        const entry = class_table.classes.getPtr(cur) orelse {
            diagnostics.missing_superclass += 1;
            break;
        };
        try chain.append(allocator, entry);
        cur = entry.super_class_id;
    }

    var fields = std.ArrayList(Field).empty;
    defer fields.deinit(allocator);
    var ref_offsets = std.ArrayList(u32).empty;
    defer ref_offsets.deinit(allocator);

    var offset: u32 = 0;
    for (chain.items) |entry| {
        var it = HeapDump.InstanceFieldIterator.init(entry.instance_fields_raw, id_size);
        while (try it.next()) |inst_field| {
            const raw_name = class_table.utf8.get(inst_field.name_id) orelse "";
            const name = try allocator.dupe(u8, raw_name);
            errdefer allocator.free(name);

            try fields.append(allocator, .{
                .name = name,
                .type = inst_field.type,
                .byte_offset = offset,
                .declaring_class_raw_id = entry.class_id,
            });
            if (isReferenceType(inst_field.type)) {
                try ref_offsets.append(allocator, offset);
            }
            offset += inst_field.type.size(id_size);
        }
    }

    return .{
        .class_raw_id = class_id,
        .fields = try fields.toOwnedSlice(allocator),
        .reference_offsets = try ref_offsets.toOwnedSlice(allocator),
    };
}

fn createTestJob(
    allocator: std.mem.Allocator,
    io: Io,
    source_data: []const u8,
    tmp_dir: []const u8,
) !Preflight.Job {
    const header = try hprof.Header.parse(source_data);
    const fingerprint = try Manifest.computeFingerprint(allocator, source_data, header, 0);
    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "staging" });
    try Io.Dir.cwd().createDirPath(io, staging_dir);
    return .{
        .source_path = "test.hprof",
        .index_dir = tmp_dir,
        .staging_dir = staging_dir,

        .budget_bytes = 1024 * 1024,
        .fingerprint = fingerprint,
        .header = header,
    };
}

fn expectField(
    layout: Layout,
    index: usize,
    expected_name: []const u8,
    expected_type: hprof.PrimitiveType,
    expected_offset: u32,
) !void {
    const field = layout.fields[index];
    try std.testing.expectEqualStrings(expected_name, field.name);
    try std.testing.expectEqual(expected_type, field.type);
    try std.testing.expectEqual(expected_offset, field.byte_offset);
}

test "worked example: 8-byte IDs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 8);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "com/acme/persistence/AuditedEntity");
    try b.utf8(0x1002, "com/acme/checkout/CheckoutSession");
    try b.utf8(0x1010, "createdAt");
    try b.utf8(0x1011, "createdBy");
    try b.utf8(0x1020, "expiresAt");
    try b.utf8(0x1021, "completed");
    try b.utf8(0x1022, "cart");
    try b.utf8(0x1023, "customer");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);
    try b.loadClass(3, 0x2002, 0x1002);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 0,
    });
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 16,
        .instance_fields = &.{
            .{ .name_id = 0x1010, .type = .long },
            .{ .name_id = 0x1011, .type = .object },
        },
    });
    _ = try heap.classDump(.{
        .class_id = 0x2002,
        .super_class_id = 0x2001,
        .instance_size = 41,
        .instance_fields = &.{
            .{ .name_id = 0x1020, .type = .long },
            .{ .name_id = 0x1021, .type = .boolean },
            .{ .name_id = 0x1022, .type = .object },
            .{ .name_id = 0x1023, .type = .object },
        },
    });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var scan_result = try Scanner.run(allocator, io, &job, bytes, null);
    defer scan_result.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    var layout_table = try writeFields(
        allocator,
        io,
        job.staging_dir,
        &scan_result.class_table,
        job.header.id_size,
        &diagnostics,
    );
    defer layout_table.deinit();

    const checkout = layout_table.lookup(0x2002).?;
    try std.testing.expectEqual(@as(usize, 6), checkout.fields.len);
    try expectField(checkout.*, 0, "expiresAt", .long, 0);
    try expectField(checkout.*, 1, "completed", .boolean, 8);
    try expectField(checkout.*, 2, "cart", .object, 9);
    try expectField(checkout.*, 3, "customer", .object, 17);
    try expectField(checkout.*, 4, "createdAt", .long, 25);
    try expectField(checkout.*, 5, "createdBy", .object, 33);

    try std.testing.expectEqual(@as(usize, 3), checkout.reference_offsets.len);
    try std.testing.expectEqual(@as(u32, 9), checkout.reference_offsets[0]);
    try std.testing.expectEqual(@as(u32, 17), checkout.reference_offsets[1]);
    try std.testing.expectEqual(@as(u32, 33), checkout.reference_offsets[2]);

    try std.testing.expectEqual(@as(u64, 0), diagnostics.missing_superclass);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.superclass_cycle);
}

test "worked example: 4-byte IDs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "com/acme/persistence/AuditedEntity");
    try b.utf8(0x1002, "com/acme/checkout/CheckoutSession");
    try b.utf8(0x1010, "createdAt");
    try b.utf8(0x1011, "createdBy");
    try b.utf8(0x1020, "expiresAt");
    try b.utf8(0x1021, "completed");
    try b.utf8(0x1022, "cart");
    try b.utf8(0x1023, "customer");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);
    try b.loadClass(3, 0x2002, 0x1002);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 0,
    });
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 12,
        .instance_fields = &.{
            .{ .name_id = 0x1010, .type = .long },
            .{ .name_id = 0x1011, .type = .object },
        },
    });
    _ = try heap.classDump(.{
        .class_id = 0x2002,
        .super_class_id = 0x2001,
        .instance_size = 29,
        .instance_fields = &.{
            .{ .name_id = 0x1020, .type = .long },
            .{ .name_id = 0x1021, .type = .boolean },
            .{ .name_id = 0x1022, .type = .object },
            .{ .name_id = 0x1023, .type = .object },
        },
    });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var scan_result = try Scanner.run(allocator, io, &job, bytes, null);
    defer scan_result.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    var layout_table = try writeFields(
        allocator,
        io,
        job.staging_dir,
        &scan_result.class_table,
        job.header.id_size,
        &diagnostics,
    );
    defer layout_table.deinit();

    const checkout = layout_table.lookup(0x2002).?;
    try std.testing.expectEqual(@as(usize, 6), checkout.fields.len);
    try expectField(checkout.*, 0, "expiresAt", .long, 0);
    try expectField(checkout.*, 1, "completed", .boolean, 8);
    try expectField(checkout.*, 2, "cart", .object, 9);
    try expectField(checkout.*, 3, "customer", .object, 13);
    try expectField(checkout.*, 4, "createdAt", .long, 17);
    try expectField(checkout.*, 5, "createdBy", .object, 25);

    try std.testing.expectEqual(@as(usize, 3), checkout.reference_offsets.len);
    try std.testing.expectEqual(@as(u32, 9), checkout.reference_offsets[0]);
    try std.testing.expectEqual(@as(u32, 13), checkout.reference_offsets[1]);
    try std.testing.expectEqual(@as(u32, 25), checkout.reference_offsets[2]);

    try std.testing.expectEqual(@as(u64, 0), diagnostics.missing_superclass);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.superclass_cycle);
}

test "three-level inheritance with mixed fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 8);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "Base");
    try b.utf8(0x1002, "Mid");
    try b.utf8(0x1003, "Leaf");
    try b.utf8(0x1010, "baseInt");
    try b.utf8(0x1011, "midBool");
    try b.utf8(0x1012, "leafRef");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);
    try b.loadClass(3, 0x2002, 0x1002);
    try b.loadClass(4, 0x2003, 0x1003);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 0,
    });
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 4,
        .instance_fields = &.{
            .{ .name_id = 0x1010, .type = .int },
        },
    });
    _ = try heap.classDump(.{
        .class_id = 0x2002,
        .super_class_id = 0x2001,
        .instance_size = 5,
        .instance_fields = &.{
            .{ .name_id = 0x1011, .type = .boolean },
        },
    });
    _ = try heap.classDump(.{
        .class_id = 0x2003,
        .super_class_id = 0x2002,
        .instance_size = 13,
        .instance_fields = &.{
            .{ .name_id = 0x1012, .type = .object },
        },
    });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var scan_result = try Scanner.run(allocator, io, &job, bytes, null);
    defer scan_result.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    var layout_table = try writeFields(
        allocator,
        io,
        job.staging_dir,
        &scan_result.class_table,
        job.header.id_size,
        &diagnostics,
    );
    defer layout_table.deinit();

    const leaf = layout_table.lookup(0x2003).?;
    try std.testing.expectEqual(@as(usize, 3), leaf.fields.len);
    try expectField(leaf.*, 0, "leafRef", .object, 0);
    try expectField(leaf.*, 1, "midBool", .boolean, 8);
    try expectField(leaf.*, 2, "baseInt", .int, 9);

    try std.testing.expectEqual(@as(usize, 1), leaf.reference_offsets.len);
    try std.testing.expectEqual(@as(u32, 0), leaf.reference_offsets[0]);
}

test "missing superclass truncates chain" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 8);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "Orphan");
    try b.utf8(0x1010, "field");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x9999, // missing
        .instance_size = 8,
        .instance_fields = &.{
            .{ .name_id = 0x1010, .type = .object },
        },
    });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var scan_result = try Scanner.run(allocator, io, &job, bytes, null);
    defer scan_result.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    var layout_table = try writeFields(
        allocator,
        io,
        job.staging_dir,
        &scan_result.class_table,
        job.header.id_size,
        &diagnostics,
    );
    defer layout_table.deinit();

    const orphan = layout_table.lookup(0x2001).?;
    try std.testing.expectEqual(@as(usize, 1), orphan.fields.len);
    try expectField(orphan.*, 0, "field", .object, 0);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.missing_superclass);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.superclass_cycle);
}

test "superclass cycle truncates chain" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 8);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "A");
    try b.utf8(0x1001, "B");
    try b.utf8(0x1010, "aField");
    try b.utf8(0x1011, "bField");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .super_class_id = 0x2001,
        .instance_size = 8,
        .instance_fields = &.{
            .{ .name_id = 0x1010, .type = .object },
        },
    });
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 8,
        .instance_fields = &.{
            .{ .name_id = 0x1011, .type = .object },
        },
    });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var scan_result = try Scanner.run(allocator, io, &job, bytes, null);
    defer scan_result.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    var layout_table = try writeFields(
        allocator,
        io,
        job.staging_dir,
        &scan_result.class_table,
        job.header.id_size,
        &diagnostics,
    );
    defer layout_table.deinit();

    const a = layout_table.lookup(0x2000).?;
    const b_class = layout_table.lookup(0x2001).?;
    // Chain stops before revisiting a class, so each layout contains the
    // fields of both classes in the cycle.
    try std.testing.expectEqual(@as(usize, 2), a.fields.len);
    try expectField(a.*, 0, "aField", .object, 0);
    try expectField(a.*, 1, "bField", .object, 8);

    try std.testing.expectEqual(@as(usize, 2), b_class.fields.len);
    try expectField(b_class.*, 0, "bField", .object, 0);
    try expectField(b_class.*, 1, "aField", .object, 8);

    try std.testing.expectEqual(@as(u64, 1), diagnostics.superclass_cycle);
}

test "fields.bin parses and matches classes.bin on fixtures" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const fixtures = .{
        "test_hprofs/heapforge.hprof",
        "test_hprofs/heapforge_classloaders.hprof",
        "test_hprofs/heapforge_threads.hprof",
    };

    inline for (fixtures) |fixture_path| {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);

        const source_data = try Io.Dir.cwd().readFileAlloc(io, fixture_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source_data);

        const job = try createTestJob(allocator, io, source_data, tmp_path_z[0..tmp_path_z.len]);
        defer job.deinit(allocator);

        var scan_result = try Scanner.run(allocator, io, &job, source_data, null);
        defer scan_result.deinit(allocator);

        var sort_diagnostics: Manifest.Diagnostics = .{};
        const catalog_result = try @import("CatalogSorter.zig").sortAndDedupe(
            allocator,
            io,
            &job,
            scan_result.catalog_path,
            &sort_diagnostics,
        );
        defer catalog_result.deinit(allocator);

        const classes_path = try @import("CatalogSorter.zig").writeClasses(
            allocator,
            io,
            job.staging_dir,
            &scan_result.class_table,
        );
        defer allocator.free(classes_path);

        var diagnostics: Manifest.Diagnostics = .{};
            var layout_table = try writeFields(
                allocator,
                io,
                job.staging_dir,
                &scan_result.class_table,
                job.header.id_size,
                &diagnostics,
            );
        defer layout_table.deinit();

        // Every class dump should have a matching layout.
        try std.testing.expectEqual(scan_result.class_table.classes.count(), layout_table.layouts.len);

        // Layouts are sorted by class_raw_id.
        var last_id: hprof.Id = 0;
        for (layout_table.layouts) |layout| {
            try std.testing.expect(layout.class_raw_id > last_id);
            last_id = layout.class_raw_id;
        }

        // Offsets are tightly packed and reference_offsets match object fields.
        for (layout_table.layouts) |layout| {
            var offset: u32 = 0;
            var ref_idx: usize = 0;
            for (layout.fields) |field| {
                try std.testing.expectEqual(offset, field.byte_offset);
                if (isReferenceType(field.type)) {
                    try std.testing.expect(ref_idx < layout.reference_offsets.len);
                    try std.testing.expectEqual(offset, layout.reference_offsets[ref_idx]);
                    ref_idx += 1;
                }
                offset += field.type.size(job.header.id_size);
            }
            try std.testing.expectEqual(ref_idx, layout.reference_offsets.len);
        }
    }
}
