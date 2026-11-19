//! Stage 4: second scan of the HPROF dump to emit raw edges.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Scanner = @import("Scanner.zig");
const Layouts = @import("Layouts.zig");
const profiling = @import("profiling");

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

/// Profiling accumulators for the inline (sequential) emission path. Workers
/// skip these because profiling state is global and not thread-safe.
const EdgeAccs = struct {
    statics: profiling.Acc = .{},
    instances: profiling.Acc = .{},
    arrays: profiling.Acc = .{},
    roots: profiling.Acc = .{},
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
    var edges_buf: [Scanner.worker_io_buffer_size]u8 = undefined;
    var edges_file_writer: Io.File.Writer = .init(edges_file, io, &edges_buf);
    const edges_writer = &edges_file_writer.interface;

    var n_edges: u64 = 0;

    // Collect heap dump segment byte ranges in a cheap pre-pass, then dispatch
    // to worker threads for large dumps or run inline for small/single-segment
    // dumps. The pre-pass is sequential and shares no mutable state with the
    // heavy per-segment decoding below.
    var segments: std.ArrayList(Scanner.SegmentRange) = .empty;
    defer segments.deinit(allocator);

    var reader = try hprof.Reader.init(source_data);
    while (try reader.next()) |record| {
        switch (record) {
            .heap_dump, .heap_dump_segment => |heap_reader| {
                const hr = heap_reader;
                try segments.append(allocator, .{
                    .offset = hr.body_offset,
                    .len = hr.cursor.remaining(),
                });
            },
            else => {},
        }
    }

    try emitEdgesParallel(
        allocator,
        io,
        job,
        source_data,
        segments.items,
        layout_table,
        edges_writer,
        diagnostics,
        &n_edges,
    );

    try edges_file_writer.flush();

    return .{
        .edges_path = edges_path,
        .n_edges = n_edges,
    };
}

/// Fan edge emission out over worker threads for large dumps, or run it
/// inline on the calling thread for small/single-segment dumps.
fn emitEdgesParallel(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    source_data: []const u8,
    segments: []const Scanner.SegmentRange,
    layout_table: *const Layouts.LayoutTable,
    edges_writer: *Io.Writer,
    diagnostics: *Manifest.Diagnostics,
    n_edges: *u64,
) !void {
    if (segments.len == 0) return;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers = @min(cpu_count, @max(1, segments.len / Scanner.min_segments_per_worker));
    var accs: EdgeAccs = .{};
    return emitEdgesDispatched(
        allocator,
        io,
        job,
        source_data,
        segments,
        layout_table,
        edges_writer,
        diagnostics,
        n_edges,
        n_workers,
        &accs,
    );
}

/// Emit edges with an explicit worker count. Exposed so tests can exercise
/// the parallel path deterministically regardless of host CPU count.
fn emitEdgesDispatched(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    source_data: []const u8,
    segments: []const Scanner.SegmentRange,
    layout_table: *const Layouts.LayoutTable,
    edges_writer: *Io.Writer,
    diagnostics: *Manifest.Diagnostics,
    n_edges: *u64,
    n_workers: usize,
    accs: ?*EdgeAccs,
) !void {
    if (segments.len == 0) return;

    if (n_workers <= 1) {
        for (segments) |seg| {
            const end: usize = @intCast(seg.offset + seg.len);
            const body = source_data[@intCast(seg.offset)..end];
            var hr = hprof.HeapDumpReader.initWithOffset(body, job.header.id_size, @intCast(seg.offset));
            try scanHeapDump(
                io,
                job,
                &hr,
                layout_table,
                edges_writer,
                n_edges,
                diagnostics,
                accs,
            );
        }
        return;
    }

    const buckets = try Scanner.partitionSegmentsLPT(allocator, segments, n_workers);
    defer {
        for (buckets) |*b| b.deinit(allocator);
        allocator.free(buckets);
    }

    const workers = try allocator.alloc(EdgeWorkerState, n_workers);
    defer allocator.free(workers);

    // Open each worker's spill file before spawning. On any error after a
    // worker is initialized, clean up its open file, spill file, and path.
    var n_inited: usize = 0;
    var n_finalized: usize = 0;
    errdefer for (workers[n_finalized..n_inited]) |*w| {
        w.closeFiles();
        const cleanup_dir = Io.Dir.cwd();
        cleanup_dir.deleteFile(io, w.edges_spill_path) catch {};
        w.deinit();
    };
    for (buckets, 0..) |*b, i| {
        workers[i] = try EdgeWorkerState.init(allocator, io, job, source_data, layout_table, b.items, i);
        n_inited += 1;
    }

    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(allocator);
    var n_joined: usize = 0;
    // Join exactly once: threads appended after a spawn but before an append
    // failure are joined inline; threads already joined on the normal path are
    // excluded here via `n_joined`.
    errdefer for (threads.items[n_joined..]) |t| t.join();
    for (workers) |*w| {
        const t = try std.Thread.spawn(.{}, workerEmit, .{w});
        threads.append(allocator, t) catch |e| {
            t.join();
            return e;
        };
    }
    for (threads.items[n_joined..]) |t| {
        t.join();
        n_joined += 1;
    }

    // Flush bytes still sitting in the workers' write buffers and close the
    // spill files so the merge can read them back. A flush failure (e.g. disk
    // full during an auto-drain) is recorded as the worker's error.
    for (workers) |*w| {
        w.edges_writer.flush() catch |e| {
            if (w.err == null) w.err = e;
        };
        w.closeFiles();
    }

    for (workers) |*w| {
        if (w.err) |e| return e;
    }

    // Merge in worker order for deterministic output: stream each worker's
    // spill file into the final edges file, then remove the spill files.
    const merge_dir = Io.Dir.cwd();
    var merge_buf: [Scanner.worker_io_buffer_size]u8 = undefined;
    for (workers) |*w| {
        try Scanner.streamSpillFile(io, w.edges_spill_path, edges_writer, &merge_buf);
        try merge_dir.deleteFile(io, w.edges_spill_path);
        n_edges.* += w.n_edges;
        Scanner.mergeDiagnostics(diagnostics, &w.diagnostics);
        w.deinit();
        n_finalized += 1;
    }
}

/// Per-worker state for the parallel edge-emission phase. Edges are streamed
/// to a per-worker spill file (fixed 64 KiB write buffer) and merged in worker
/// order afterwards, so emission memory is bounded by worker count.
const EdgeWorkerState = struct {
    path_alloc: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    source: []const u8,
    segments: []const Scanner.SegmentRange,
    layout_table: *const Layouts.LayoutTable,

    edges_spill_path: []u8,
    edges_buf: []u8,
    edges_file: Io.File,
    edges_writer: Io.File.Writer,
    files_open: bool = false,
    diagnostics: Manifest.Diagnostics = .{},
    n_edges: u64 = 0,
    err: ?anyerror = null,

    fn init(
        allocator: std.mem.Allocator,
        io_arg: Io,
        job_arg: *const Preflight.Job,
        source_arg: []const u8,
        layout_table_arg: *const Layouts.LayoutTable,
        segments_arg: []const Scanner.SegmentRange,
        worker_index: usize,
    ) !EdgeWorkerState {
        const edges_spill_path = try std.fmt.allocPrint(allocator, "{s}/edges.spill-{d}", .{ job_arg.staging_dir, worker_index });
        errdefer allocator.free(edges_spill_path);
        const edges_buf = try allocator.alloc(u8, Scanner.worker_io_buffer_size);
        errdefer allocator.free(edges_buf);

        const dir = Io.Dir.cwd();
        const edges_file = try dir.createFile(io_arg, edges_spill_path, .{});
        errdefer edges_file.close(io_arg);

        return .{
            .path_alloc = allocator,
            .io = io_arg,
            .job = job_arg,
            .source = source_arg,
            .segments = segments_arg,
            .layout_table = layout_table_arg,
            .edges_spill_path = edges_spill_path,
            .edges_buf = edges_buf,
            .edges_file = edges_file,
            .edges_writer = .init(edges_file, io_arg, edges_buf),
            .files_open = true,
        };
    }

    fn closeFiles(self: *EdgeWorkerState) void {
        if (self.files_open) {
            self.edges_file.close(self.io);
            self.files_open = false;
        }
    }

    fn deinit(self: *EdgeWorkerState) void {
        self.path_alloc.free(self.edges_buf);
        self.path_alloc.free(self.edges_spill_path);
    }

    fn scanAll(self: *EdgeWorkerState) !void {
        for (self.segments) |seg| {
            const end: usize = @intCast(seg.offset + seg.len);
            const body = self.source[@intCast(seg.offset)..end];
            var hr = hprof.HeapDumpReader.initWithOffset(body, self.job.header.id_size, @intCast(seg.offset));
            try scanHeapDump(
                self.io,
                self.job,
                &hr,
                self.layout_table,
                &self.edges_writer.interface,
                &self.n_edges,
                &self.diagnostics,
                null,
            );
        }
    }
};

fn workerEmit(state: *EdgeWorkerState) void {
    state.scanAll() catch |err| {
        if (state.err == null) state.err = err;
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
    io: Io,
    job: *const Preflight.Job,
    hr: *hprof.HeapDumpReader,
    layout_table: *const Layouts.LayoutTable,
    edges_writer: *Io.Writer,
    n_edges: *u64,
    diagnostics: *Manifest.Diagnostics,
    accs: ?*EdgeAccs,
) !void {
    while (try hr.nextWithOffset()) |item| {
        switch (item.record) {
            .gc_class_dump => |cd| {
                if (accs) |a| a.statics.start(io, "statics");
                defer if (accs) |a| a.statics.stop(io);
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
                if (accs) |a| a.instances.start(io, "instances");
                defer if (accs) |a| a.instances.stop(io);
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
                if (accs) |a| a.arrays.start(io, "arrays");
                defer if (accs) |a| a.arrays.stop(io);
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
                if (accs) |a| a.roots.start(io, "roots");
                defer if (accs) |a| a.roots.stop(io);
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
        .dominator_budget_bytes = 1024 * 1024,
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
        "fixtures/heapforge.hprof",
        "fixtures/heapforge_classloaders.hprof",
        "fixtures/heapforge_threads.hprof",
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

/// Edge records sorted lexicographically, so two edge files can be compared as
/// multisets regardless of the emission order that produced them.
fn sortedEdgeRecords(allocator: std.mem.Allocator, data: []const u8) ![][edge_record_size]u8 {
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @intCast(data.len % edge_record_size)));
    const rows = try allocator.dupe([edge_record_size]u8, std.mem.bytesAsSlice([edge_record_size]u8, data));
    errdefer allocator.free(rows);
    std.mem.sort([edge_record_size]u8, rows, {}, struct {
        fn less(_: void, a: [edge_record_size]u8, b: [edge_record_size]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.less);
    return rows;
}

/// Run edge emission with an explicit worker count and return the edge file
/// bytes, edge count, and diagnostics. Caller owns `edges`.
fn runTestDispatch(
    allocator: std.mem.Allocator,
    io: Io,
    source_data: []const u8,
    tmp_dir: []const u8,
    n_workers: usize,
) !struct { edges: []const u8, n_edges: u64, diagnostics: Manifest.Diagnostics } {
    var setup = try runThroughLayouts(allocator, io, source_data, tmp_dir);
    defer setup.job.deinit(allocator);
    defer setup.layout_table.deinit();

    var diagnostics: Manifest.Diagnostics = .{};
    var n_edges: u64 = 0;

    const edges_path = try std.fs.path.join(allocator, &.{ setup.job.staging_dir, "edges.raw" });
    defer allocator.free(edges_path);
    const dir = Io.Dir.cwd();
    var edges_file = try dir.createFile(io, edges_path, .{});
    defer edges_file.close(io);
    var edges_buf: [Scanner.worker_io_buffer_size]u8 = undefined;
    var edges_file_writer: Io.File.Writer = .init(edges_file, io, &edges_buf);

    const segments = try Scanner.collectTestSegmentRanges(allocator, source_data);
    defer allocator.free(segments);

    var accs: EdgeAccs = .{};
    try emitEdgesDispatched(
        allocator,
        io,
        &setup.job,
        source_data,
        segments,
        &setup.layout_table,
        &edges_file_writer.interface,
        &diagnostics,
        &n_edges,
        n_workers,
        &accs,
    );
    try edges_file_writer.interface.flush();

    const edges = try dir.readFileAlloc(io, edges_path, allocator, .limited(1 << 26));
    return .{ .edges = edges, .n_edges = n_edges, .diagnostics = diagnostics };
}

test "parallel edge emission is deterministic and matches sequential as multiset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Build a dump with one HEAP_DUMP record and 72 HEAP_DUMP_SEGMENT records
    // so an explicit 4-worker dispatch fans out across the pool.
    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "com.shop.Node");
    try b.utf8(0x1002, "next");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    // Single-record form: the first segment; also dumps the Node class with a
    // reference field so instance layouts exist.
    var seg0 = try b.heapDump();
    _ = try seg0.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 4,
        .instance_fields = &.{
            .{ .name_id = 0x1002, .type = .object },
        },
    });
    _ = try seg0.instanceDump(0x3000, 0x2001, &[_]u8{0} ** 4);
    seg0.end();

    var seg_i: usize = 0;
    while (seg_i < 72) : (seg_i += 1) {
        var seg = try b.heapDumpSegment();
        const inst_id: hprof.Id = @intCast(0x3100 + seg_i);
        var inst_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &inst_bytes, @intCast(0x3000 + seg_i), .big);
        _ = try seg.instanceDump(inst_id, 0x2001, &inst_bytes);

        // Duplicate object id in two distant segments: both edges must survive
        // the worker merge identically.
        if (seg_i == 5 or seg_i == 60) {
            _ = try seg.instanceDump(0x9999, 0x2001, &inst_bytes);
        }

        // GC roots in two different workers' segments.
        if (seg_i == 7) {
            _ = try seg.rootThreadObject(0x3200, 11, 1);
        }
        if (seg_i == 40) {
            _ = try seg.rootThreadObject(0x3201, 12, 2);
        }

        // Object array producing edges.
        if (seg_i == 10) {
            _ = try seg.objectArrayDump(0x3300, 0x2000, &[_]hprof.Id{ 0x3100, 0 });
        }

        // Class dump with a non-null static object field so diagnostics and
        // per-worker state merging are exercised.
        if (seg_i == 30) {
            _ = try seg.classDump(.{
                .class_id = 0x2002,
                .super_class_id = 0x2000,
                .instance_size = 0,
                .static_fields = &.{
                    .{ .name_id = 0x1002, .type = .object, .value = .{ .object = 0x3100 } },
                },
            });
        }
        seg.end();
    }

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const segments = try Scanner.collectTestSegmentRanges(allocator, bytes);
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 73), segments.len);

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    var tmp_c = std.testing.tmpDir(.{});
    defer tmp_c.cleanup();
    const path_a = try tmp_a.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_a);
    const path_b = try tmp_b.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_b);
    const path_c = try tmp_c.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_c);

    const seq = try runTestDispatch(allocator, io, bytes, path_a[0..path_a.len], 1);
    defer allocator.free(seq.edges);

    const par1 = try runTestDispatch(allocator, io, bytes, path_b[0..path_b.len], 4);
    defer allocator.free(par1.edges);

    const par2 = try runTestDispatch(allocator, io, bytes, path_c[0..path_c.len], 4);
    defer allocator.free(par2.edges);

    try std.testing.expectEqual(seq.n_edges, par1.n_edges);
    try std.testing.expectEqual(par1.n_edges, par2.n_edges);
    try std.testing.expectEqual(@as(u64, 0), par1.diagnostics.missing_layout);

    // Run-to-run byte determinism of the parallel path.
    try std.testing.expectEqualSlices(u8, par1.edges, par2.edges);

    // Multiset parity with the sequential emission order.
    const seq_sorted = try sortedEdgeRecords(allocator, seq.edges);
    defer allocator.free(seq_sorted);
    const par_sorted = try sortedEdgeRecords(allocator, par1.edges);
    defer allocator.free(par_sorted);
    try std.testing.expectEqualSlices([edge_record_size]u8, seq_sorted, par_sorted);
}

test "parallel edge emission spills rows and stays bounded" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 4 workers with enough edges per worker to force multiple buffer drains.
    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "com.shop.Node");
    try b.utf8(0x1002, "next");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var seg0 = try b.heapDump();
    _ = try seg0.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 4,
        .instance_fields = &.{
            .{ .name_id = 0x1002, .type = .object },
        },
    });
    _ = try seg0.instanceDump(0x3000, 0x2001, &[_]u8{0} ** 4);
    seg0.end();

    var seg_i: usize = 0;
    while (seg_i < 72) : (seg_i += 1) {
        var seg = try b.heapDumpSegment();
        var i: usize = 0;
        while (i < 1100) : (i += 1) {
            const inst_id: hprof.Id = @intCast(0x4000 + seg_i * 1100 + i);
            var inst_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &inst_bytes, @intCast(0x5000 + seg_i * 1100 + i), .big);
            _ = try seg.instanceDump(inst_id, 0x2001, &inst_bytes);
        }
        seg.end();
    }

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const result = try runTestDispatch(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len], 4);
    defer allocator.free(result.edges);

    // 72 segments * 1100 instances; the segment0 instance has a zero target so
    // it emits no edge, yielding 79,200 edges.
    try std.testing.expectEqual(@as(u64, 79200), result.n_edges);
    try std.testing.expectEqual(@as(usize, 79200 * edge_record_size), result.edges.len);

    // Spill files must all have been deleted after the merge.
    const dir = Io.Dir.cwd();
    var worker_i: usize = 0;
    while (worker_i < 4) : (worker_i += 1) {
        const spill_path = try std.fmt.allocPrint(allocator, "{s}/staging/edges.spill-{d}", .{ tmp_path_z[0..tmp_path_z.len], worker_i });
        defer allocator.free(spill_path);
        const spill_file = dir.openFile(io, spill_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        spill_file.close(io);
        try std.testing.expect(false);
    }
}
