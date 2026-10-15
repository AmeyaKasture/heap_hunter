//! Stage 4: second scan of the HPROF dump to emit raw edges.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Scanner = @import("Scanner.zig");
const Layouts = @import("Layouts.zig");

pub const edge_record_size = 16;

pub const EdgeRecord = struct {
    source_raw_id: u64,
    target_raw_id: u64,
};

pub const virtual_root_sentinel: u64 = std.math.maxInt(u64);

/// Serialize one 16-byte edge record into `writer`.
/// The record is written as two little-endian `u64` values: source raw ID
/// followed by target raw ID.
pub fn writeEdgeRecord(writer: *Io.Writer, rec: EdgeRecord) !void {
    var buf: [edge_record_size]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], rec.source_raw_id, .little);
    std.mem.writeInt(u64, buf[8..16], rec.target_raw_id, .little);
    try writer.writeAll(&buf);
}

/// Deserialize one 16-byte edge record from a fixed-size buffer.
/// Returns the source and target raw IDs as little-endian `u64` values.
pub fn readEdgeRecord(buf: *const [edge_record_size]u8) EdgeRecord {
    return .{
        .source_raw_id = std.mem.readInt(u64, buf[0..8], .little),
        .target_raw_id = std.mem.readInt(u64, buf[8..16], .little),
    };
}

/// Result of Stage 4. Holds the path to `edges.raw` and the total number of
/// edges emitted during the second pass.
pub const Result = struct {
    edges_path: []const u8,
    n_edges: u64,

    /// Free the path string. The edge file itself is left in the staging
    /// directory for later stages.
    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.edges_path);
    }
};

/// Stage 4: walk the dump a second time and emit raw `(source_raw_id,
/// target_raw_id)` records to `edges.raw`.
///
/// Edges are emitted for:
/// - non-null object references in instance fields (using the reference mask
///   from the resolved layouts);
/// - non-null elements of object arrays;
/// - non-null object-typed static fields of class dumps;
/// - GC roots, with `virtual_root_sentinel` as the source.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    source_data: []const u8,
    layout_table: *const Layouts.LayoutTable,
    diagnostics: *Manifest.Diagnostics,
) !Result {
    const edges_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "edges.raw" });
    errdefer allocator.free(edges_path);

    const dir = Io.Dir.cwd();
    var edges_file = try dir.createFile(io, edges_path, .{});
    defer edges_file.close(io);
    var edges_buf: [65536]u8 = undefined;
    var edges_file_writer: Io.File.Writer = .init(edges_file, io, &edges_buf);
    const edges_writer = &edges_file_writer.interface;

    var n_edges: u64 = 0;

    var reader = try hprof.Reader.init(source_data);
    while (try reader.next()) |record| {
        switch (record) {
            .heap_dump => |heap_reader| {
                var hr = heap_reader;
                try scanHeapDump(job, &hr, layout_table, edges_writer, &n_edges, diagnostics);
            },
            .heap_dump_segment => |heap_reader| {
                var hr = heap_reader;
                try scanHeapDump(job, &hr, layout_table, edges_writer, &n_edges, diagnostics);
            },
            else => {},
        }
    }

    try edges_file_writer.flush();

    return .{
        .edges_path = edges_path,
        .n_edges = n_edges,
    };
}

/// Scan a single `HEAP_DUMP` or `HEAP_DUMP_SEGMENT` body and emit edges for
/// every reference inside it.
///
/// Emits:
/// - one edge per non-null object-typed static field of a class dump;
/// - one edge per non-null object field of an instance dump, using the
///   `reference_offsets` from the object's class layout;
/// - one edge per non-null element of an object array;
/// - one edge per GC root, with `virtual_root_sentinel` as the source.
///
/// Primitive arrays produce no edges. Null targets are skipped.
fn scanHeapDump(
    job: *const Preflight.Job,
    hr: *hprof.HeapDumpReader,
    layout_table: *const Layouts.LayoutTable,
    edges_writer: *Io.Writer,
    n_edges: *u64,
    diagnostics: *Manifest.Diagnostics,
) !void {
    while (try hr.nextWithOffset()) |item| {
        switch (item.record) {
            .gc_class_dump => |cd| {
                var it = cd.staticFieldIterator(job.header.id_size);
                while (try it.next()) |field| {
                    if (field.type != .object and field.type != .array_object) continue;
                    const target = switch (field.type) {
                        .object => field.value.object,
                        .array_object => field.value.array_object,
                        else => unreachable,
                    };
                    if (target == 0) continue;
                    try writeEdgeRecord(edges_writer, .{
                        .source_raw_id = cd.class_id,
                        .target_raw_id = target,
                    });
                    n_edges.* += 1;
                }
            },
            .gc_instance_dump => |id| {
                const layout = layout_table.lookup(id.class_id) orelse {
                    diagnostics.missing_layout += 1;
                    continue;
                };
                for (layout.reference_offsets) |offset| {
                    if (@as(usize, offset) + job.header.id_size > id.bytes.len) continue;
                    var c = hprof.Cursor.init(id.bytes[offset..][0..job.header.id_size]);
                    const target = try c.readId(job.header.id_size);
                    if (target == 0) continue;
                    try writeEdgeRecord(edges_writer, .{
                        .source_raw_id = id.object_id,
                        .target_raw_id = target,
                    });
                    n_edges.* += 1;
                }
            },
            .gc_obj_array_dump => |oa| {
                var i: u32 = 0;
                while (i < oa.element_count) : (i += 1) {
                    const target = try oa.element(i, job.header.id_size);
                    if (target == 0) continue;
                    try writeEdgeRecord(edges_writer, .{
                        .source_raw_id = oa.array_id,
                        .target_raw_id = target,
                    });
                    n_edges.* += 1;
                }
            },
            .gc_prim_array_dump => {},
            else => |root| {
                const info = Scanner.extractRootInfo(root);
                if (info.target == 0) continue;
                try writeEdgeRecord(edges_writer, .{
                    .source_raw_id = virtual_root_sentinel,
                    .target_raw_id = info.target,
                });
                n_edges.* += 1;
            },
        }
    }
}

/// Build a minimal `Preflight.Job` for unit tests using the given HPROF bytes.
/// Creates a temporary staging directory under `tmp_dir` and computes the
/// fingerprint and header from `source_data`.
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

/// Test helper that runs Stages 1-3 so Stage 4 tests have a populated
/// `LayoutTable`. Returns the `Preflight.Job` (caller owns) and the in-memory
/// `LayoutTable` (caller must call `LayoutTable.deinit`).
///
/// Carries Stage 3 diagnostics (`missing_superclass`, `superclass_cycle`) into
/// the local diagnostics set so callers can assert on them if needed.
fn runThroughLayouts(
    allocator: std.mem.Allocator,
    io: Io,
    source_data: []const u8,
    tmp_dir: []const u8,
) !struct { job: Preflight.Job, layout_table: Layouts.LayoutTable } {
    const job = try createTestJob(allocator, io, source_data, tmp_dir);
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

    var layout_diagnostics: Manifest.Diagnostics = .{};
    var layout_table = try Layouts.writeFields(
        allocator,
        io,
        job.staging_dir,
        &scan_result.class_table,
        job.header.id_size,
        &layout_diagnostics,
    );
    errdefer layout_table.deinit();

    // Carry layout diagnostics into the sort set so callers see them.
    sort_diagnostics.missing_superclass = layout_diagnostics.missing_superclass;
    sort_diagnostics.superclass_cycle = layout_diagnostics.superclass_cycle;

    return .{ .job = job, .layout_table = layout_table };
}

/// Assert that the edge at `index` in a raw `edges.raw` byte slice matches
/// the expected source and target raw IDs.
fn expectEdge(
    edges_data: []const u8,
    index: usize,
    expected_source: hprof.Id,
    expected_target: hprof.Id,
) !void {
    const rec = readEdgeRecord(edges_data[index * edge_record_size ..][0..edge_record_size]);
    try std.testing.expectEqual(expected_source, rec.source_raw_id);
    try std.testing.expectEqual(expected_target, rec.target_raw_id);
}

test "cart array emits exactly two non-null edges" {
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
    try b.utf8(0x1001, "com/shop/Cart");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 8,
    });
    const cart_off = try heap.instanceDump(0x3000, 0x2001, &[_]u8{0} ** 8);
    const arr_off = try heap.objectArrayDump(0x4000, 0x2000, &[_]hprof.Id{ 0x3000, 0, 0x3000 });
    _ = cart_off;
    _ = arr_off;
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var setup = try runThroughLayouts(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer setup.job.deinit(allocator);
    defer setup.layout_table.deinit();

    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io, &setup.job, bytes, &setup.layout_table, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 2), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.missing_layout);

    const edges_data = try Io.Dir.cwd().readFileAlloc(io, result.edges_path, allocator, .limited(4096));
    defer allocator.free(edges_data);
    try std.testing.expectEqual(@as(usize, 2 * edge_record_size), edges_data.len);

    try expectEdge(edges_data, 0, 0x4000, 0x3000);
    try expectEdge(edges_data, 1, 0x4000, 0x3000);
}

test "static object field emits class-to-target edge" {
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
    try b.utf8(0x1001, "com/shop/Holder");
    try b.utf8(0x1002, "instance");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 8,
        .static_fields = &.{
            .{ .name_id = 0x1002, .type = .object, .value = .{ .object = 0x3000 } },
        },
    });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var setup = try runThroughLayouts(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer setup.job.deinit(allocator);
    defer setup.layout_table.deinit();

    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io, &setup.job, bytes, &setup.layout_table, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.missing_layout);

    const edges_data = try Io.Dir.cwd().readFileAlloc(io, result.edges_path, allocator, .limited(4096));
    defer allocator.free(edges_data);
    try expectEdge(edges_data, 0, 0x2001, 0x3000);
}

test "root unknown emits virtual-root edge" {
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
    try b.loadClass(1, 0x2000, 0x1000);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 8,
    });
    _ = try heap.rootUnknown(0x3000);
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var setup = try runThroughLayouts(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer setup.job.deinit(allocator);
    defer setup.layout_table.deinit();

    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io, &setup.job, bytes, &setup.layout_table, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.n_edges);

    const edges_data = try Io.Dir.cwd().readFileAlloc(io, result.edges_path, allocator, .limited(4096));
    defer allocator.free(edges_data);
    try expectEdge(edges_data, 0, virtual_root_sentinel, 0x3000);
}

test "instance field emits edge and skips nulls" {
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
    try b.utf8(0x1001, "com/shop/Node");
    try b.utf8(0x1002, "next");
    try b.utf8(0x1003, "prev");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 16,
        .instance_fields = &.{
            .{ .name_id = 0x1002, .type = .object },
            .{ .name_id = 0x1003, .type = .object },
        },
    });
    // next = 0x3000, prev = null
    var inst_bytes: [16]u8 = undefined;
    @memset(&inst_bytes, 0);
    std.mem.writeInt(u64, inst_bytes[0..8], 0x3000, .big);
    _ = try heap.instanceDump(0x4000, 0x2001, &inst_bytes);
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var setup = try runThroughLayouts(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer setup.job.deinit(allocator);
    defer setup.layout_table.deinit();

    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io, &setup.job, bytes, &setup.layout_table, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.missing_layout);

    const edges_data = try Io.Dir.cwd().readFileAlloc(io, result.edges_path, allocator, .limited(4096));
    defer allocator.free(edges_data);
    try expectEdge(edges_data, 0, 0x4000, 0x3000);
}

test "4-byte IDs normalize to u64 targets" {
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
    try b.utf8(0x1001, "com/shop/Node");
    try b.utf8(0x1002, "child");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 4,
        .instance_fields = &.{
            .{ .name_id = 0x1002, .type = .object },
        },
    });
    var inst_bytes: [4]u8 = undefined;
    @memset(&inst_bytes, 0);
    std.mem.writeInt(u32, inst_bytes[0..4], 0x3000, .big);
    _ = try heap.instanceDump(0x4000, 0x2001, &inst_bytes);
    const arr_off = try heap.objectArrayDump(0x5000, 0x2000, &[_]hprof.Id{ 0x4000, 0 });
    _ = arr_off;
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var setup = try runThroughLayouts(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer setup.job.deinit(allocator);
    defer setup.layout_table.deinit();

    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io, &setup.job, bytes, &setup.layout_table, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 2), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.missing_layout);

    const edges_data = try Io.Dir.cwd().readFileAlloc(io, result.edges_path, allocator, .limited(4096));
    defer allocator.free(edges_data);
    try expectEdge(edges_data, 0, 0x4000, 0x3000);
    try expectEdge(edges_data, 1, 0x5000, 0x4000);
}

test "missing layout increments diagnostic and skips instance" {
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
    try b.loadClass(1, 0x2000, 0x1000);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 8,
    });
    // Instance references a class that was never dumped, so no layout exists.
    var inst_bytes: [8]u8 = undefined;
    @memset(&inst_bytes, 0);
    std.mem.writeInt(u64, inst_bytes[0..8], 0x3000, .big);
    _ = try heap.instanceDump(0x4000, 0x9999, &inst_bytes);
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var setup = try runThroughLayouts(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer setup.job.deinit(allocator);
    defer setup.layout_table.deinit();

    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io, &setup.job, bytes, &setup.layout_table, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 0), result.n_edges);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.missing_layout);
}

test "fixtures produce non-zero raw edges" {
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

        var setup = try runThroughLayouts(allocator, io, source_data, tmp_path_z[0..tmp_path_z.len]);
        defer setup.job.deinit(allocator);
        defer setup.layout_table.deinit();

        var diagnostics: Manifest.Diagnostics = .{};
        var result = try run(allocator, io, &setup.job, source_data, &setup.layout_table, &diagnostics);
        defer result.deinit(allocator);

        try std.testing.expect(result.n_edges > 0);
    }
}
