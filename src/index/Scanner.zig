//! Stage 1 scan: walk the HPROF dump once and emit the unsorted catalog,
//! raw root records, and an in-memory class/name table.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Progress = @import("../Progress.zig").Progress;
const ThreadTraces = @import("ThreadTraces.zig");
const log = @import("log");
const profiling = @import("profiling");

/// Fixed size of a catalog row on disk: 32 bytes, little-endian.
pub const catalog_row_size = 32;

/// Kind of node stored in `catalog.unsorted`.
/// The numeric values are part of the on-disk format.
pub const CatalogKind = enum(u8) {
    /// Plain object instance created by `new`.
    instance = 0,
    /// Array of object references.
    object_array = 1,
    /// Array of primitive values (e.g. `int[]`, `char[]`).
    primitive_array = 2,
    /// Class metadata from a `GC_CLASS_DUMP` record.
    class = 3,
};

/// One row in `catalog.unsorted`. One row is written for every heap entity
/// (instance, class, object array, or primitive array) found in the dump.
pub const CatalogRow = struct {
    /// Raw HPROF object/class/array ID (the heap address recorded by the JVM).
    raw_id: u64,
    /// Absolute byte offset of the sub-record body in the original HPROF file.
    /// Later stages use this to seek back and decode the raw bytes.
    source_offset: u64,
    /// Class ID for instances/arrays; self-referential for class rows.
    class_raw_id: u64,
    /// Size of this node in bytes (instance payload, array payload, or
    /// `instance_size` for classes). Used for shallow-size accounting.
    shallow_size: u32,
    /// Node classification.
    kind: CatalogKind,
};

/// Serialize `row` into a fixed 32-byte buffer and write it to `writer`.
pub fn writeCatalogRow(writer: *Io.Writer, row: CatalogRow) !void {
    var buf: [catalog_row_size]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], row.raw_id, .little);
    std.mem.writeInt(u64, buf[8..16], row.source_offset, .little);
    std.mem.writeInt(u64, buf[16..24], row.class_raw_id, .little);
    std.mem.writeInt(u32, buf[24..28], row.shallow_size, .little);
    buf[28] = @intFromEnum(row.kind);
    // Three bytes of reserved padding to keep the row 32-byte aligned.
    buf[29] = 0;
    buf[30] = 0;
    buf[31] = 0;
    try writer.writeAll(&buf);
}

/// Deserialize a `CatalogRow` from a fixed 32-byte buffer.
/// Returns `error.InvalidCatalogKind` if the kind byte is out of range.
pub fn readCatalogRow(buf: *const [catalog_row_size]u8) !CatalogRow {
    const kind_int = buf[28];
    const kind: CatalogKind = switch (kind_int) {
        0 => .instance,
        1 => .object_array,
        2 => .primitive_array,
        3 => .class,
        else => return error.InvalidCatalogKind,
    };
    return .{
        .raw_id = std.mem.readInt(u64, buf[0..8], .little),
        .source_offset = std.mem.readInt(u64, buf[8..16], .little),
        .class_raw_id = std.mem.readInt(u64, buf[16..24], .little),
        .shallow_size = std.mem.readInt(u32, buf[24..28], .little),
        .kind = kind,
    };
}

/// Fixed size of a root record on disk: 16 bytes, little-endian.
pub const root_record_size = 16;

/// Fixed size of a primitive histogram entry on disk: 17 bytes, little-endian.
pub const prim_histogram_entry_size = 17;

/// One row in `roots.raw`. One row is written for every GC root sub-record.
pub const RootRecord = struct {
    /// Raw HPROF ID of the object/class being kept alive.
    target_raw_id: u64,
    /// Root kind: raw `hprof.HeapSubtag` value (e.g. 0x03 for JAVA_FRAME).
    root_kind: u8,
    /// Thread serial number for thread-attached roots; zero otherwise.
    thread_serial: u32,
};

/// Serialize `rec` into a fixed 16-byte buffer and write it to `writer`.
pub fn writeRootRecord(writer: *Io.Writer, rec: RootRecord) !void {
    var buf: [root_record_size]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], rec.target_raw_id, .little);
    buf[8] = rec.root_kind;
    // Three bytes of reserved padding before the thread_serial u32.
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 0;
    std.mem.writeInt(u32, buf[12..16], rec.thread_serial, .little);
    try writer.writeAll(&buf);
}

/// Deserialize a `RootRecord` from a fixed 16-byte buffer.
pub fn readRootRecord(buf: *const [root_record_size]u8) RootRecord {
    return .{
        .target_raw_id = std.mem.readInt(u64, buf[0..8], .little),
        .root_kind = buf[8],
        .thread_serial = std.mem.readInt(u32, buf[12..16], .little),
    };
}

/// One row in `prim_histogram.bin`. Aggregates primitive arrays by element type.
pub const PrimHistogramEntry = struct {
    element_type: hprof.PrimitiveType,
    count: u64,
    bytes: u64,
};

/// Serialize `entry` into a fixed 17-byte buffer and write it to `writer`.
pub fn writePrimHistogramEntry(writer: *Io.Writer, entry: PrimHistogramEntry) !void {
    var buf: [prim_histogram_entry_size]u8 = undefined;
    buf[0] = @intFromEnum(entry.element_type);
    std.mem.writeInt(u64, buf[1..9], entry.count, .little);
    std.mem.writeInt(u64, buf[9..17], entry.bytes, .little);
    try writer.writeAll(&buf);
}

/// Deserialize a `PrimHistogramEntry` from a fixed 17-byte buffer.
pub fn readPrimHistogramEntry(buf: *const [prim_histogram_entry_size]u8) !PrimHistogramEntry {
    const ty = buf[0];
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        if (field.value == ty) {
            return .{
                .element_type = @as(hprof.PrimitiveType, @enumFromInt(ty)),
                .count = std.mem.readInt(u64, buf[1..9], .little),
                .bytes = std.mem.readInt(u64, buf[9..17], .little),
            };
        }
    }
    return error.InvalidPrimitiveType;
}

/// In-memory metadata for a single class extracted from `GC_CLASS_DUMP`.
/// The raw field bytes are owned by this entry so they remain valid after the
/// HPROF source buffer is no longer needed.
pub const ClassEntry = struct {
    /// Raw HPROF ID of the `java.lang.Class` object.
    class_id: hprof.Id,
    /// Raw HPROF ID of the direct superclass (0 for `java.lang.Object`).
    super_class_id: hprof.Id,
    /// Total instance size declared by HPROF, including inherited fields.
    instance_size: u32,
    /// Raw HPROF ID of the class loader that defined this class.
    class_loader_id: hprof.Id,
    /// UTF8 name ID for this class (from `LOAD_CLASS`). Zero if not yet known.
    name_id: hprof.Id,
    /// Raw binary of the declared instance fields: sequence of `{name_id, type}`.
    instance_fields_raw: []const u8,
    /// Raw binary of the static fields: sequence of `{name_id, type, value}`.
    static_fields_raw: []const u8,
    /// Raw binary of the constant pool entries.
    constant_pool_raw: []const u8,

    /// Release owned raw-field copies.
    pub fn deinit(self: *const ClassEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.instance_fields_raw);
        allocator.free(self.static_fields_raw);
        allocator.free(self.constant_pool_raw);
    }
};

/// Pairing from a `LOAD_CLASS` record.
pub const LoadClassEntry = struct {
    class_id: hprof.Id,
    name_id: hprof.Id,
};

/// Lookup tables built while streaming through the HPROF file.
/// Holds string data, class-name mappings, and full class metadata used by
/// later stages to resolve field layouts and class names.
pub const ClassTable = struct {
    allocator: std.mem.Allocator,
    /// UTF8 id -> owned string bytes (e.g. class names, field names).
    utf8: std.AutoHashMap(hprof.Id, []const u8),
    /// LOAD_CLASS serial -> {class_id, name_id}.
    /// Serial numbers are used by TRACE/FRAME records to refer to classes.
    loaded: std.AutoHashMap(u32, LoadClassEntry),
    /// class_id -> name_id. Bridges class dumps to their UTF8 names.
    class_names: std.AutoHashMap(hprof.Id, hprof.Id),
    /// class_id -> full ClassEntry metadata.
    classes: std.AutoHashMap(hprof.Id, ClassEntry),

    pub fn init(allocator: std.mem.Allocator) ClassTable {
        return .{
            .allocator = allocator,
            .utf8 = std.AutoHashMap(hprof.Id, []const u8).init(allocator),
            .loaded = std.AutoHashMap(u32, LoadClassEntry).init(allocator),
            .class_names = std.AutoHashMap(hprof.Id, hprof.Id).init(allocator),
            .classes = std.AutoHashMap(hprof.Id, ClassEntry).init(allocator),
        };
    }

    pub fn deinit(self: *ClassTable) void {
        // UTF8 values are owned copies; free them before the map.
        var utf8_it = self.utf8.iterator();
        while (utf8_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.utf8.deinit();
        self.loaded.deinit();
        self.class_names.deinit();

        // ClassEntry owns the raw field bytes.
        var class_it = self.classes.iterator();
        while (class_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.classes.deinit();
    }

    /// Store a UTF8 string under `id`. The bytes are copied and owned by the table.
    pub fn addUtf8(self: *ClassTable, id: hprof.Id, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        const old = self.utf8.fetchPut(id, copy) catch |err| {
            self.allocator.free(copy);
            return err;
        };
        if (old) |kv| {
            self.allocator.free(kv.value);
        }
    }

    /// Store the class-id/name-id mapping from a `LOAD_CLASS` record.
    /// If a class dump for this class was already processed, backfill its name.
    pub fn addLoadClass(self: *ClassTable, serial: u32, class_id: hprof.Id, name_id: hprof.Id) !void {
        try self.loaded.put(serial, .{ .class_id = class_id, .name_id = name_id });
        try self.class_names.put(class_id, name_id);
        if (self.classes.getPtr(class_id)) |entry| {
            entry.name_id = name_id;
        }
    }

    /// Store full class metadata from a `GC_CLASS_DUMP` sub-record.
    /// Copies the raw field/constant-pool bytes so they survive after scanHeapDump returns.
    pub fn addClassDump(self: *ClassTable, cd: hprof.ClassDump) !void {
        const entry = entry: {
            const instance_fields_raw = try self.allocator.dupe(u8, cd.instance_fields_raw);
            errdefer self.allocator.free(instance_fields_raw);
            const static_fields_raw = try self.allocator.dupe(u8, cd.static_fields_raw);
            errdefer self.allocator.free(static_fields_raw);
            const constant_pool_raw = try self.allocator.dupe(u8, cd.constant_pool_raw);
            errdefer self.allocator.free(constant_pool_raw);

            break :entry ClassEntry{
                .class_id = cd.class_id,
                .super_class_id = cd.super_class_id,
                .instance_size = cd.instance_size,
                .class_loader_id = cd.class_loader_id,
                .name_id = self.class_names.get(cd.class_id) orelse 0,
                .instance_fields_raw = instance_fields_raw,
                .static_fields_raw = static_fields_raw,
                .constant_pool_raw = constant_pool_raw,
            };
        };
        errdefer entry.deinit(self.allocator);

        const old = try self.classes.fetchPut(cd.class_id, entry);
        if (old) |kv| {
            kv.value.deinit(self.allocator);
        }
    }

    /// Resolve the human-readable class name for `class_id`, or null if unknown.
    pub fn className(self: *const ClassTable, class_id: hprof.Id) ?[]const u8 {
        const name_id = self.class_names.get(class_id) orelse return null;
        return self.utf8.get(name_id);
    }
};

/// Result of running Stage 1. The caller owns `class_table` and the paths.
pub const Result = struct {
    /// Path to `catalog.unsorted` in the staging directory.
    catalog_path: []const u8,
    /// Path to `roots.raw` in the staging directory.
    roots_path: []const u8,
    /// Path to `prim_histogram.bin` in the staging directory.
    prim_histogram_path: []const u8,
    /// Path to `thread_traces.bin` in the staging directory.
    thread_traces_path: []const u8,
    /// In-memory class/name tables used by later stages.
    class_table: ClassTable,
    /// Total catalog rows written.
    n_catalog_rows: u64,
    /// Total root records written.
    n_roots: u64,
    /// Diagnostic counters collected while scanning.
    diagnostics: Manifest.Diagnostics,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.catalog_path);
        allocator.free(self.roots_path);
        allocator.free(self.prim_histogram_path);
        allocator.free(self.thread_traces_path);
        self.class_table.deinit();
    }
};

/// Run the Stage 1 scanner over `source_data`.
///
/// Writes `catalog.unsorted` and `roots.raw` into `job.staging_dir` and returns
/// an in-memory `ClassTable` that must be freed by the caller via `Result.deinit`.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    source_data: []const u8,
    progress: ?*Progress,
) !Result {
    log.debug("scanner starting: staging_dir={s}, source_len={d}", .{ job.staging_dir, source_data.len });

    const catalog_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "catalog.unsorted" });
    errdefer allocator.free(catalog_path);
    const roots_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "roots.raw" });
    errdefer allocator.free(roots_path);
    const prim_histogram_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "prim_histogram.bin" });
    errdefer allocator.free(prim_histogram_path);
    const thread_traces_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "thread_traces.bin" });
    errdefer allocator.free(thread_traces_path);

    const dir = Io.Dir.cwd();
    var catalog_file = try dir.createFile(io, catalog_path, .{});
    defer catalog_file.close(io);
    var catalog_buf: [65536]u8 = undefined;
    var catalog_file_writer: Io.File.Writer = .init(catalog_file, io, &catalog_buf);
    const catalog_writer = &catalog_file_writer.interface;

    var roots_file = try dir.createFile(io, roots_path, .{});
    defer roots_file.close(io);
    var roots_buf: [65536]u8 = undefined;
    var roots_file_writer: Io.File.Writer = .init(roots_file, io, &roots_buf);
    const roots_writer = &roots_file_writer.interface;

    var prim_histogram_file = try dir.createFile(io, prim_histogram_path, .{});
    defer prim_histogram_file.close(io);
    var prim_histogram_buf: [65536]u8 = undefined;
    var prim_histogram_file_writer: Io.File.Writer = .init(prim_histogram_file, io, &prim_histogram_buf);
    const prim_histogram_writer = &prim_histogram_file_writer.interface;

    var class_table = ClassTable.init(allocator);
    errdefer class_table.deinit();

    var thread_traces = ThreadTraces.Collector.init(allocator);
    defer thread_traces.deinit();

    var diagnostics: Manifest.Diagnostics = .{};
    var n_catalog_rows: u64 = 0;
    var n_roots: u64 = 0;
    var prim_histogram = initPrimHistogram();

    var segments: std.ArrayList(SegmentRange) = .empty;
    defer segments.deinit(allocator);

    var reader = try hprof.Reader.init(source_data);
    var accs: ScanAccs = .{};
    {
        var span = profiling.begin(io, "records");
        defer span.end(io);
        while (try reader.next()) |record| {
            switch (record) {
                .utf8 => |u| {
                    try class_table.addUtf8(u.id, u.bytes);
                },
                .load_class => |lc| {
                    try class_table.addLoadClass(lc.serial, lc.class_id, lc.name_id);
                },
                .frame => |frame| {
                    try thread_traces.addFrame(frame);
                },
                .trace => |trace| {
                    try thread_traces.addTrace(trace, job.header.id_size);
                },
                // HPROF 1.0.2 uses either a single HEAP_DUMP or multiple
                // HEAP_DUMP_SEGMENT records. Defer segment bodies to the
                // parallel phase; record their byte ranges here.
                .heap_dump, .heap_dump_segment => {
                    const hr = switch (record) {
                        .heap_dump => |h| h,
                        .heap_dump_segment => |h| h,
                        else => unreachable,
                    };
                    try segments.append(allocator, .{
                        .offset = hr.body_offset,
                        .len = hr.cursor.remaining(),
                    });
                },
                else => {},
            }
            if (progress) |p| p.tick();
        }
    }

    {
        var span = profiling.begin(io, "segments");
        defer span.end(io);
        try scanSegmentsParallel(
            allocator,
            io,
            job,
            source_data,
            segments.items,
            &class_table,
            &thread_traces,
            catalog_writer,
            roots_writer,
            &n_catalog_rows,
            &n_roots,
            &diagnostics,
            &prim_histogram,
            progress,
            &accs,
        );
    }

    try catalog_file_writer.flush();
    try roots_file_writer.flush();

    var prim_count: u32 = 0;
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        if (prim_histogram[field.value].count > 0) prim_count += 1;
    }
    {
        var span = profiling.begin(io, "histogram");
        defer span.end(io);
        try writeU32(prim_histogram_writer, prim_count);
        inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
            const entry = prim_histogram[field.value];
            if (entry.count > 0) {
                try writePrimHistogramEntry(prim_histogram_writer, entry);
            }
        }
        try prim_histogram_file_writer.flush();
    }

    {
        var span = profiling.begin(io, "thread_traces");
        defer span.end(io);
        try writeThreadTraces(allocator, io, &class_table, &thread_traces, thread_traces_path);
    }

    log.debug(
        "scanner complete: n_catalog_rows={d}, n_roots={d}, n_followup_frames={d}, n_traces={d}, n_thread_roots={d}, diagnostics={any}",
        .{
            n_catalog_rows,
            n_roots,
            thread_traces.frames.count(),
            thread_traces.traces.count(),
            thread_traces.thread_roots.count(),
            diagnostics,
        },
    );

    return .{
        .catalog_path = catalog_path,
        .roots_path = roots_path,
        .prim_histogram_path = prim_histogram_path,
        .thread_traces_path = thread_traces_path,
        .class_table = class_table,
        .n_catalog_rows = n_catalog_rows,
        .n_roots = n_roots,
        .diagnostics = diagnostics,
    };
}

/// Minimum segments a worker must be assigned for spawning to pay off;
/// below this the inline path is faster than thread startup.
const min_segments_per_worker: usize = 32;

/// Scan the collected heap dump segment ranges. Large dumps are fanned out
/// over worker threads (LPT-partitioned by segment length); small dumps run
/// inline on the calling thread. Workers stream rows to per-worker spill
/// files and buffer shared-state records locally; this function merges the
/// spill files in deterministic worker order afterwards.
fn scanSegmentsParallel(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    source_data: []const u8,
    segments: []const SegmentRange,
    class_table: *ClassTable,
    thread_traces: *ThreadTraces.Collector,
    catalog_writer: *Io.Writer,
    roots_writer: *Io.Writer,
    n_catalog_rows: *u64,
    n_roots: *u64,
    diagnostics: *Manifest.Diagnostics,
    prim_histogram: []PrimHistogramEntry,
    progress: ?*Progress,
    accs: *ScanAccs,
) !void {
    if (segments.len == 0) return;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers = @min(cpu_count, @max(1, segments.len / min_segments_per_worker));
    return scanSegmentsDispatched(
        allocator,
        io,
        job,
        source_data,
        segments,
        class_table,
        thread_traces,
        catalog_writer,
        roots_writer,
        n_catalog_rows,
        n_roots,
        diagnostics,
        prim_histogram,
        progress,
        accs,
        n_workers,
    );
}

/// Scan the collected segment ranges with an explicit worker count: one
/// worker (or fewer segments than the spawn threshold) runs inline on the
/// calling thread; more workers run the LPT-partitioned thread pool. Exposed
/// with an explicit `n_workers` so tests can exercise the parallel path
/// deterministically regardless of host CPU count.
fn scanSegmentsDispatched(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    source_data: []const u8,
    segments: []const SegmentRange,
    class_table: *ClassTable,
    thread_traces: *ThreadTraces.Collector,
    catalog_writer: *Io.Writer,
    roots_writer: *Io.Writer,
    n_catalog_rows: *u64,
    n_roots: *u64,
    diagnostics: *Manifest.Diagnostics,
    prim_histogram: []PrimHistogramEntry,
    progress: ?*Progress,
    accs: *ScanAccs,
    n_workers: usize,
) !void {
    if (segments.len == 0) return;

    if (n_workers <= 1) {
        for (segments) |seg| {
            const end: usize = @intCast(seg.offset + seg.len);
            const body = source_data[@intCast(seg.offset)..end];
            var hr = hprof.HeapDumpReader.initWithOffset(body, job.header.id_size, @intCast(seg.offset));
            try scanHeapDump(
                io,
                .{ .sequential = .{
                    .class_table = class_table,
                    .thread_traces = thread_traces,
                } },
                job,
                &hr,
                catalog_writer,
                roots_writer,
                n_catalog_rows,
                n_roots,
                diagnostics,
                prim_histogram,
                accs,
            );
            if (progress) |p| p.tick();
        }
        return;
    }

    const buckets = try partitionSegmentsLPT(allocator, segments, n_workers);
    defer {
        for (buckets) |*b| b.deinit(allocator);
        allocator.free(buckets);
    }

    const workers = try allocator.alloc(WorkerState, n_workers);
    defer allocator.free(workers);

    // Open each worker's spill files before spawning. On any error after a
    // worker is initialized, clean up its open files, spill files, and paths.
    var n_inited: usize = 0;
    var n_finalized: usize = 0;
    errdefer for (workers[n_finalized..n_inited]) |*w| {
        w.closeFiles();
        const cleanup_dir = Io.Dir.cwd();
        cleanup_dir.deleteFile(io, w.catalog_spill_path) catch {};
        cleanup_dir.deleteFile(io, w.roots_spill_path) catch {};
        w.deinit();
    };
    for (buckets, 0..) |*b, i| {
        workers[i] = try WorkerState.init(allocator, io, job, source_data, b.items, i);
        n_inited += 1;
    }

    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(allocator);
    var n_joined: usize = 0;
    // Join exactly once: threads appended after a spawn but before an
    // append failure are joined inline; threads already joined on the
    // normal path are excluded here via `n_joined`.
    errdefer for (threads.items[n_joined..]) |t| t.join();
    for (workers) |*w| {
        const t = try std.Thread.spawn(.{}, workerScan, .{w});
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
        w.catalog_writer.flush() catch |e| {
            if (w.err == null) w.err = e;
        };
        w.roots_writer.flush() catch |e| {
            if (w.err == null) w.err = e;
        };
        w.closeFiles();
    }

    for (workers) |*w| {
        if (w.err) |e| return e;
    }

    // Merge in worker order for deterministic output: stream each worker's
    // spill file into the final outputs, then remove the spill files.
    const merge_dir = Io.Dir.cwd();
    var merge_buf: [worker_io_buffer_size]u8 = undefined;
    for (workers) |*w| {
        try streamSpillFile(io, w.catalog_spill_path, catalog_writer, &merge_buf);
        try streamSpillFile(io, w.roots_spill_path, roots_writer, &merge_buf);
        try merge_dir.deleteFile(io, w.catalog_spill_path);
        try merge_dir.deleteFile(io, w.roots_spill_path);
        n_catalog_rows.* += w.n_catalog_rows;
        n_roots.* += w.n_roots;
        for (w.prim_histogram, 0..) |entry, i| {
            prim_histogram[i].count += entry.count;
            prim_histogram[i].bytes += entry.bytes;
        }
        mergeDiagnostics(diagnostics, &w.diagnostics);
        for (w.class_dumps.items) |cd| {
            try class_table.addClassDump(cd);
        }
        for (w.thread_roots.items) |tr| {
            try thread_traces.addThreadRoot(tr.thread_object_id, tr.thread_serial, tr.stack_trace_serial);
        }
        if (progress) |p| p.tick();
        w.deinit();
        n_finalized += 1;
    }
}

/// Stream the entire contents of `path` into `dest` through a bounded buffer,
/// so merge memory does not scale with spill-file size.
fn streamSpillFile(io: Io, path: []const u8, dest: *Io.Writer, buf: []u8) !void {
    const dir = Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var file_reader: Io.File.Reader = .init(file, io, buf);
    _ = try file_reader.interface.streamRemaining(dest);
}

/// Longest-processing-time-first partition: segments are sorted by length
/// (descending, offset ascending on ties) and each goes to the currently
/// lightest worker bucket. Deterministic for a given segment list, and each
/// bucket preserves that sorted order. Caller owns the returned buckets.
fn partitionSegmentsLPT(
    allocator: std.mem.Allocator,
    segments: []const SegmentRange,
    n_workers: usize,
) ![]std.ArrayList(SegmentRange) {
    var loads = try allocator.alloc(u64, n_workers);
    defer allocator.free(loads);
    @memset(loads, 0);

    const order = try allocator.alloc(SegmentRange, segments.len);
    defer allocator.free(order);
    @memcpy(order, segments);
    std.mem.sort(SegmentRange, order, {}, struct {
        fn less(_: void, a: SegmentRange, b: SegmentRange) bool {
            if (a.len != b.len) return a.len > b.len;
            return a.offset < b.offset;
        }
    }.less);

    const buckets = try allocator.alloc(std.ArrayList(SegmentRange), n_workers);
    errdefer {
        for (buckets) |*b| b.deinit(allocator);
        allocator.free(buckets);
    }
    for (buckets) |*b| b.* = .empty;
    for (order) |seg| {
        var min_i: usize = 0;
        for (1..n_workers) |i| {
            if (loads[i] < loads[min_i]) min_i = i;
        }
        try buckets[min_i].append(allocator, seg);
        loads[min_i] += seg.len;
    }
    return buckets;
}

/// Resolve the captured FRAME/TRACE/thread-root metadata against the fully
/// populated class table and write `thread_traces.bin` into the staging dir.
///
/// This runs once after the heap walk so frame class serials can be resolved
/// even for LOAD_CLASS records that appear after the heap dump records.
fn writeThreadTraces(
    allocator: std.mem.Allocator,
    io: Io,
    class_table: *const ClassTable,
    collector: *ThreadTraces.Collector,
    path: []const u8,
) !void {
    const dir = Io.Dir.cwd();
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var write_buf: [65536]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &write_buf);
    const writer = &file_writer.interface;

    var resolved_frames = std.ArrayList(ThreadTraces.ResolvedFrame).empty;
    errdefer {
        for (resolved_frames.items) |frame| {
            allocator.free(frame.class_name);
        }
        resolved_frames.deinit(allocator);
    }
    var frame_index = std.AutoHashMap(hprof.Id, u32).init(allocator);
    defer frame_index.deinit();

    // Frames sorted by raw id for deterministic output.
    var frame_ids = std.ArrayList(hprof.Id).empty;
    defer frame_ids.deinit(allocator);
    var fit = collector.frames.iterator();
    while (fit.next()) |entry| {
        try frame_ids.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort(hprof.Id, frame_ids.items, {}, std.sort.asc(hprof.Id));

    if (frame_ids.items.len >= ThreadTraces.missing_frame_index) {
        return error.TooManyFrames;
    }

    for (frame_ids.items, 0..) |frame_id, ordinal| {
        try frame_index.put(frame_id, @intCast(ordinal));
        const frame = collector.frames.get(frame_id).?;
        const class_name = try resolveFrameClassName(allocator, class_table, frame.class_serial);
        errdefer allocator.free(class_name);
        const method_name = class_table.utf8.get(frame.method_name_id) orelse "<?>";
        const source_name = class_table.utf8.get(frame.source_file_name_id) orelse "<?>";
        try resolved_frames.append(allocator, .{
            .frame_id = frame_id,
            .class_name = class_name,
            .method_name = method_name,
            .source_name = source_name,
            .line_number = frame.line_number,
        });
    }

    // Traces sorted by serial, with frame ids resolved to frame-table indices
    // (missing frames become the sentinel index).
    var traces = std.ArrayList(ThreadTraces.TraceOut).empty;
    defer {
        for (traces.items) |trace| allocator.free(trace.frame_indices);
        traces.deinit(allocator);
    }
    var trace_serials = std.ArrayList(u32).empty;
    defer trace_serials.deinit(allocator);
    var tit = collector.traces.iterator();
    while (tit.next()) |entry| {
        try trace_serials.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort(u32, trace_serials.items, {}, std.sort.asc(u32));

    for (trace_serials.items) |serial| {
        const raw = collector.traces.get(serial).?;
        const indices = try allocator.alloc(u32, raw.frame_ids.len);
        errdefer allocator.free(indices);
        for (raw.frame_ids, 0..) |fid, i| {
            indices[i] = frame_index.get(fid) orelse ThreadTraces.missing_frame_index;
        }
        try traces.append(allocator, .{
            .serial = serial,
            .thread_serial = raw.thread_serial,
            .frame_indices = indices,
        });
    }

    // Thread roots sorted by object id for deterministic output.
    var thread_roots = std.ArrayList(ThreadTraces.ThreadRoot).empty;
    defer thread_roots.deinit(allocator);
    var rit = collector.thread_roots.iterator();
    while (rit.next()) |entry| {
        try thread_roots.append(allocator, entry.value_ptr.*);
    }
    std.mem.sort(ThreadTraces.ThreadRoot, thread_roots.items, {}, struct {
        fn less(_: void, a: ThreadTraces.ThreadRoot, b: ThreadTraces.ThreadRoot) bool {
            return a.thread_object_id < b.thread_object_id;
        }
    }.less);

    try ThreadTraces.serialize(allocator, writer, resolved_frames.items, traces.items, thread_roots.items);
    try file_writer.flush();

    // Free the resolved class names (method/source are borrowed utf8 values).
    for (resolved_frames.items) |frame| {
        allocator.free(frame.class_name);
    }
    resolved_frames.deinit(allocator);
}

/// Resolve the dotted class name for a frame's `class_serial`, mirroring
/// Resolve the dotted class name for a frame class serial. Returns an owned copy.
fn resolveFrameClassName(
    allocator: std.mem.Allocator,
    class_table: *const ClassTable,
    class_serial: u32,
) ![]const u8 {
    const load = class_table.loaded.get(class_serial) orelse {
        return try replaceSlashes(allocator, "<?>");
    };
    const name_id = class_table.class_names.get(load.class_id) orelse {
        return try replaceSlashes(allocator, "<?>");
    };
    const raw = class_table.utf8.get(name_id) orelse "<?>";
    return try replaceSlashes(allocator, raw);
}

fn replaceSlashes(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = try allocator.dupe(u8, s);
    for (result, 0..) |c, i| {
        if (c == '/') result[i] = '.';
    }
    return result;
}

fn writeU32(writer: *Io.Writer, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try writer.writeAll(&buf);
}

/// Accumulator buckets for per-record-kind timings inside `scanHeapDump`.
/// Lives across heap-dump segments so counts accumulate over the whole scan.
const ScanAccs = struct {
    classes: profiling.Acc = .{},
    instances: profiling.Acc = .{},
    arrays: profiling.Acc = .{},
    roots: profiling.Acc = .{},
};

/// Byte range of one heap dump segment body within the source HPROF.
const SegmentRange = struct {
    offset: u64,
    len: u64,
};

/// How `scanHeapDump` routes records that touch shared state.
const ScanMode = union(enum) {
    /// Main-thread mode: class dumps go into the class table, thread roots
    /// into the collector.
    sequential: struct {
        class_table: *ClassTable,
        thread_traces: *ThreadTraces.Collector,
    },
    /// Worker mode: shared-state records are buffered locally and merged by
    /// the main thread after the worker finishes. Profiling accs are skipped.
    worker: struct {
        alloc: std.mem.Allocator,
        class_dumps: *std.ArrayList(hprof.ClassDump),
        thread_roots: *std.ArrayList(ThreadTraces.ThreadRoot),
    },
};

/// Size of each worker's spill-file write buffer. Workers stream scan output
/// to per-worker spill files through this buffer instead of accumulating rows
/// in RAM, keeping parallel-scan memory bounded regardless of dump size.
const worker_io_buffer_size = 65536;

/// Per-worker scan state for the parallel heap-segment phase.
/// Catalog/root rows are streamed to per-worker spill files (fixed 64 KiB
/// write buffers, auto-drained through the thread-safe `Io`); class dumps and
/// thread roots are buffered locally (bounded by class/thread counts). The
/// main thread merges the spill files in worker order afterwards.
const WorkerState = struct {
    path_alloc: std.mem.Allocator,
    alloc: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    source: []const u8,
    segments: []const SegmentRange,

    catalog_spill_path: []u8,
    roots_spill_path: []u8,
    catalog_buf: []u8,
    roots_buf: []u8,
    catalog_file: Io.File,
    roots_file: Io.File,
    catalog_writer: Io.File.Writer,
    roots_writer: Io.File.Writer,
    files_open: bool = false,
    class_dumps: std.ArrayList(hprof.ClassDump),
    thread_roots: std.ArrayList(ThreadTraces.ThreadRoot),
    prim_histogram: [16]PrimHistogramEntry,
    diagnostics: Manifest.Diagnostics = .{},
    n_catalog_rows: u64 = 0,
    n_roots: u64 = 0,
    err: ?anyerror = null,

    /// Open the spill files and wire their writers. The writers only point at
    /// heap memory and copied file handles, so the by-value return is safe.
    fn init(
        allocator: std.mem.Allocator,
        io: Io,
        job: *const Preflight.Job,
        source: []const u8,
        segments: []const SegmentRange,
        worker_index: usize,
    ) !WorkerState {
        const alloc = std.heap.smp_allocator;
        const catalog_spill_path = try std.fmt.allocPrint(allocator, "{s}/catalog.spill-{d}", .{ job.staging_dir, worker_index });
        errdefer allocator.free(catalog_spill_path);
        const roots_spill_path = try std.fmt.allocPrint(allocator, "{s}/roots.spill-{d}", .{ job.staging_dir, worker_index });
        errdefer allocator.free(roots_spill_path);
        const catalog_buf = try allocator.alloc(u8, worker_io_buffer_size);
        errdefer allocator.free(catalog_buf);
        const roots_buf = try allocator.alloc(u8, worker_io_buffer_size);
        errdefer allocator.free(roots_buf);

        const dir = Io.Dir.cwd();
        const catalog_file = try dir.createFile(io, catalog_spill_path, .{});
        errdefer catalog_file.close(io);
        const roots_file = try dir.createFile(io, roots_spill_path, .{});
        errdefer roots_file.close(io);

        return .{
            .path_alloc = allocator,
            .alloc = alloc,
            .io = io,
            .job = job,
            .source = source,
            .segments = segments,
            .catalog_spill_path = catalog_spill_path,
            .roots_spill_path = roots_spill_path,
            .catalog_buf = catalog_buf,
            .roots_buf = roots_buf,
            .catalog_file = catalog_file,
            .roots_file = roots_file,
            .catalog_writer = .init(catalog_file, io, catalog_buf),
            .roots_writer = .init(roots_file, io, roots_buf),
            .files_open = true,
            .class_dumps = .empty,
            .thread_roots = .empty,
            .prim_histogram = initPrimHistogram(),
        };
    }

    fn closeFiles(self: *WorkerState) void {
        if (self.files_open) {
            self.catalog_file.close(self.io);
            self.roots_file.close(self.io);
            self.files_open = false;
        }
    }

    fn deinit(self: *WorkerState) void {
        self.class_dumps.deinit(self.alloc);
        self.thread_roots.deinit(self.alloc);
        self.path_alloc.free(self.catalog_buf);
        self.path_alloc.free(self.roots_buf);
        self.path_alloc.free(self.catalog_spill_path);
        self.path_alloc.free(self.roots_spill_path);
    }

    fn scanAll(self: *WorkerState) !void {
        for (self.segments) |seg| {
            const end: usize = @intCast(seg.offset + seg.len);
            const body = self.source[@intCast(seg.offset)..end];
            var hr = hprof.HeapDumpReader.initWithOffset(body, self.job.header.id_size, @intCast(seg.offset));
            try scanHeapDump(
                self.io,
                .{ .worker = .{
                    .alloc = self.alloc,
                    .class_dumps = &self.class_dumps,
                    .thread_roots = &self.thread_roots,
                } },
                self.job,
                &hr,
                &self.catalog_writer.interface,
                &self.roots_writer.interface,
                &self.n_catalog_rows,
                &self.n_roots,
                &self.diagnostics,
                &self.prim_histogram,
                null,
            );
        }
    }
};

fn workerScan(state: *WorkerState) void {
    state.scanAll() catch |err| {
        if (state.err == null) state.err = err;
    };
}

fn initPrimHistogram() [16]PrimHistogramEntry {
    var histogram: [16]PrimHistogramEntry = undefined;
    for (&histogram) |*slot| {
        slot.* = .{ .element_type = .byte, .count = 0, .bytes = 0 };
    }
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        histogram[field.value] = .{
            .element_type = @as(hprof.PrimitiveType, @enumFromInt(field.value)),
            .count = 0,
            .bytes = 0,
        };
    }
    return histogram;
}

fn mergeDiagnostics(dst: *Manifest.Diagnostics, src: *const Manifest.Diagnostics) void {
    inline for (@typeInfo(Manifest.Diagnostics).@"struct".fields) |f| {
        @field(dst, f.name) += @field(src, f.name);
    }
}

/// Scan all sub-records inside a single `HEAP_DUMP` or `HEAP_DUMP_SEGMENT`.
/// Emits catalog rows for heap entities and root records for GC roots.
fn scanHeapDump(
    io: Io,
    mode: ScanMode,
    job: *const Preflight.Job,
    hr: *hprof.HeapDumpReader,
    catalog_writer: *Io.Writer,
    roots_writer: *Io.Writer,
    n_catalog_rows: *u64,
    n_roots: *u64,
    diagnostics: *Manifest.Diagnostics,
    prim_histogram: []PrimHistogramEntry,
    accs: ?*ScanAccs,
) !void {
    while (try hr.nextWithOffset()) |item| {
        switch (item.record) {
            .gc_class_dump => |cd| {
                if (accs) |a| a.classes.start(io, "classes");
                defer if (accs) |a| a.classes.stop(io);
                switch (mode) {
                    .sequential => |s| try s.class_table.addClassDump(cd),
                    .worker => |w| try w.class_dumps.append(w.alloc, cd),
                }

                // Count non-null object-typed constant-pool references. These are intentionally
                // skipped as edges in v1 per design correction #3.
                var cp_it = cd.constantPoolIterator(job.header.id_size);
                while (try cp_it.next()) |entry| {
                    switch (entry.type) {
                        .object, .array_object => {
                            const id = switch (entry.value) {
                                .object => |v| v,
                                .array_object => |v| v,
                                else => 0,
                            };
                            if (id != 0) {
                                diagnostics.skipped_constant_pool_refs += 1;
                            }
                        },
                        else => {},
                    }
                }

                try writeCatalogRow(catalog_writer, .{
                    .raw_id = cd.class_id,
                    .source_offset = item.body_offset,
                    .class_raw_id = cd.class_id,
                    .shallow_size = cd.instance_size,
                    .kind = .class,
                });
                n_catalog_rows.* += 1;
            },
            .gc_instance_dump => |id| {
                if (accs) |a| a.instances.start(io, "instances");
                defer if (accs) |a| a.instances.stop(io);
                const size = std.math.cast(u32, id.bytes.len) orelse return error.InstanceTooLarge;
                try writeCatalogRow(catalog_writer, .{
                    .raw_id = id.object_id,
                    .source_offset = item.body_offset,
                    .class_raw_id = id.class_id,
                    .shallow_size = size,
                    .kind = .instance,
                });
                n_catalog_rows.* += 1;
            },
            .gc_obj_array_dump => |oa| {
                if (accs) |a| a.arrays.start(io, "arrays");
                defer if (accs) |a| a.arrays.stop(io);
                const size = std.math.cast(u32, @as(u64, oa.element_count) * job.header.id_size) orelse return error.ArrayTooLarge;
                try writeCatalogRow(catalog_writer, .{
                    .raw_id = oa.array_id,
                    .source_offset = item.body_offset,
                    .class_raw_id = oa.class_id,
                    .shallow_size = size,
                    .kind = .object_array,
                });
                n_catalog_rows.* += 1;
            },
            .gc_prim_array_dump => |pa| {
                if (accs) |a| a.arrays.start(io, "arrays");
                defer if (accs) |a| a.arrays.stop(io);
                const size = std.math.cast(u32, pa.bytes.len) orelse return error.ArrayTooLarge;
                try writeCatalogRow(catalog_writer, .{
                    .raw_id = pa.array_id,
                    .source_offset = item.body_offset,
                    // Primitive arrays carry an element type, not a class ID.
                    .class_raw_id = 0,
                    .shallow_size = size,
                    .kind = .primitive_array,
                });
                n_catalog_rows.* += 1;

                const ty_int = @intFromEnum(pa.element_type);
                if (ty_int < prim_histogram.len) {
                    prim_histogram[ty_int].count += 1;
                    prim_histogram[ty_int].bytes += size;
                }
            },
            // Thread object roots carry the stack-trace serial needed to map a
            // thread instance to its recorded stack trace; capture it before
            // falling through to the generic root handling.
            .gc_root_thread_object => |r| {
                if (accs) |a| a.roots.start(io, "roots");
                defer if (accs) |a| a.roots.stop(io);
                switch (mode) {
                    .sequential => |s| try s.thread_traces.addThreadRoot(r.thread_object_id, r.thread_serial, r.stack_trace_serial),
                    .worker => |w| try w.thread_roots.append(w.alloc, .{
                        .thread_object_id = r.thread_object_id,
                        .thread_serial = r.thread_serial,
                        .stack_trace_serial = r.stack_trace_serial,
                    }),
                }
                try writeRootRecord(roots_writer, .{
                    .target_raw_id = r.thread_object_id,
                    .root_kind = @intFromEnum(hprof.HeapSubtag.gc_root_thread_object),
                    .thread_serial = r.thread_serial,
                });
                n_roots.* += 1;
            },
            // Any remaining subtag is one of the nine GC root kinds.
            else => |root| {
                if (accs) |a| a.roots.start(io, "roots");
                defer if (accs) |a| a.roots.stop(io);
                const info = extractRootInfo(root);
                try writeRootRecord(roots_writer, .{
                    .target_raw_id = info.target,
                    .root_kind = info.kind,
                    .thread_serial = info.thread_serial,
                });
                n_roots.* += 1;
            },
        }
    }
}

/// Transient normalized view of a GC root sub-record.
pub const RootInfo = struct {
    /// Raw ID of the object/class kept alive by this root.
    target: hprof.Id,
    /// Root kind as a raw `hprof.HeapSubtag` byte.
    kind: u8,
    /// Thread serial for roots attached to a thread; zero otherwise.
    thread_serial: u32,
};

/// Normalize any GC root union variant into a flat `RootInfo`.
/// `record` must be a root sub-record; non-root variants zhit `unreachable`.
pub fn extractRootInfo(record: hprof.HeapRecord) RootInfo {
    switch (record) {
        .gc_root_unknown => |id| return .{ .target = id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_unknown), .thread_serial = 0 },
        .gc_root_jni_global => |r| return .{ .target = r.object_id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_jni_global), .thread_serial = 0 },
        .gc_root_jni_local => |r| return .{ .target = r.object_id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_jni_local), .thread_serial = r.thread_serial },
        .gc_root_java_frame => |r| return .{ .target = r.object_id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_java_frame), .thread_serial = r.thread_serial },
        .gc_root_native_stack => |r| return .{ .target = r.object_id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_native_stack), .thread_serial = r.thread_serial },
        .gc_root_sticky_class => |id| return .{ .target = id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_sticky_class), .thread_serial = 0 },
        .gc_root_thread_block => |r| return .{ .target = r.object_id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_thread_block), .thread_serial = r.thread_serial },
        .gc_root_monitor_used => |id| return .{ .target = id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_monitor_used), .thread_serial = 0 },
        .gc_root_thread_object => |r| return .{ .target = r.thread_object_id, .kind = @intFromEnum(hprof.HeapSubtag.gc_root_thread_object), .thread_serial = r.thread_serial },
        else => unreachable,
    }
}

/// Build a `Preflight.Job` for unit tests using the given HPROF bytes.
/// Creates a temporary staging directory under `tmp_dir`.
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

// End-to-end test: build a minimal synthetic HPROF dump, run the scanner, and
// verify the resulting catalog rows, root record, and class-name lookup.
test "scanner writes catalog rows and roots for synthetic dump" {
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
    try b.utf8(0x1001, "com.shop.User");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    const class_off = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 16,
        .instance_fields = &.{
            .{ .name_id = 0x1002, .type = .object },
            .{ .name_id = 0x1003, .type = .int },
        },
    });
    const inst_bytes = [_]u8{0} ** 8;
    const inst_off = try heap.instanceDump(0x3000, 0x2001, &inst_bytes);
    const arr_off = try heap.objectArrayDump(0x4000, 0x2000, &[_]hprof.Id{ 0x3000, 0, 0x3000 });
    const prim_off = try heap.primitiveArrayDump(0x5000, .int, 2, &[_]u8{0} ** 8);
    _ = try heap.rootUnknown(0x3000);
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var result = try run(allocator, io, &job, bytes, null);
    defer result.deinit(allocator);

    // Expect one row for the class, instance, object array, and primitive array.
    try std.testing.expectEqual(@as(u64, 4), result.n_catalog_rows);
    try std.testing.expectEqual(@as(u64, 1), result.n_roots);

    const catalog_data = try Io.Dir.cwd().readFileAlloc(io, result.catalog_path, allocator, .limited(4096));
    defer allocator.free(catalog_data);
    try std.testing.expectEqual(@as(usize, 4 * catalog_row_size), catalog_data.len);

    var rows: [4]CatalogRow = undefined;
    for (0..4) |i| {
        rows[i] = try readCatalogRow(catalog_data[i * catalog_row_size ..][0..catalog_row_size]);
    }

    try std.testing.expectEqual(@as(hprof.Id, 0x2001), rows[0].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .class), rows[0].kind);
    try std.testing.expectEqual(class_off, rows[0].source_offset);

    try std.testing.expectEqual(@as(hprof.Id, 0x3000), rows[1].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .instance), rows[1].kind);
    try std.testing.expectEqual(inst_off, rows[1].source_offset);

    try std.testing.expectEqual(@as(hprof.Id, 0x4000), rows[2].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .object_array), rows[2].kind);
    try std.testing.expectEqual(arr_off, rows[2].source_offset);

    try std.testing.expectEqual(@as(hprof.Id, 0x5000), rows[3].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .primitive_array), rows[3].kind);
    try std.testing.expectEqual(prim_off, rows[3].source_offset);

    const roots_data = try Io.Dir.cwd().readFileAlloc(io, result.roots_path, allocator, .limited(4096));
    defer allocator.free(roots_data);
    try std.testing.expectEqual(@as(usize, root_record_size), roots_data.len);

    const root = readRootRecord(roots_data[0..root_record_size]);
    try std.testing.expectEqual(@as(hprof.Id, 0x3000), root.target_raw_id);
    try std.testing.expectEqual(@intFromEnum(hprof.HeapSubtag.gc_root_unknown), root.root_kind);
    try std.testing.expectEqual(@as(u32, 0), root.thread_serial);

    try std.testing.expectEqualStrings("com.shop.User", result.class_table.className(0x2001).?);
}

// Test that non-null object references in a class dump constant pool are counted
// in `diagnostics.skipped_constant_pool_refs` but not emitted as edges.
test "scanner counts skipped constant pool object refs" {
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
    try b.loadClass(1, 0x2000, 0x1000);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 8,
        .constant_pool = &.{
            .{ .index = 0, .type = .object, .value = .{ .object = 0x3000 } },
            .{ .index = 1, .type = .object, .value = .{ .object = 0 } },
            .{ .index = 2, .type = .int, .value = .{ .int = 42 } },
        },
    });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var result = try run(allocator, io, &job, bytes, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.diagnostics.skipped_constant_pool_refs);
}

// Test that for each fixture heap dump, the scanner's catalog row count
// matches the existing `Analysis` object's count. This is a parity check
// against the previous implementation.
test "scanner catalog count matches Analysis on fixtures" {
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

        var analysis_reader = try hprof.Reader.init(source_data);
        var analysis_index = try @import("../Analysis.zig").buildIndex(allocator, &analysis_reader);
        defer analysis_index.deinit();

        const job = try createTestJob(allocator, io, source_data, tmp_path_z[0..tmp_path_z.len]);
        defer job.deinit(allocator);

        var result = try run(allocator, io, &job, source_data, null);
        defer result.deinit(allocator);

        const expected = analysis_index.total_objects + analysis_index.classes.count();
        try std.testing.expectEqual(expected, result.n_catalog_rows);
    }
}

test "scanner handles 8-byte ids" {
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
    try b.utf8(0x1001, "com.shop.User");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    const class_off = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 24,
        .instance_fields = &.{
            .{ .name_id = 0x1002, .type = .object },
            .{ .name_id = 0x1003, .type = .long },
        },
    });
    const inst_bytes = [_]u8{0} ** 16;
    const inst_off = try heap.instanceDump(0x3000, 0x2001, &inst_bytes);
    const arr_off = try heap.objectArrayDump(0x4000, 0x2000, &[_]hprof.Id{ 0x3000, 0, 0x3000 });
    const prim_off = try heap.primitiveArrayDump(0x5000, .int, 2, &[_]u8{0} ** 8);
    _ = try heap.rootUnknown(0x3000);
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var result = try run(allocator, io, &job, bytes, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 4), result.n_catalog_rows);
    try std.testing.expectEqual(@as(u64, 1), result.n_roots);

    const catalog_data = try Io.Dir.cwd().readFileAlloc(io, result.catalog_path, allocator, .limited(4096));
    defer allocator.free(catalog_data);
    try std.testing.expectEqual(@as(usize, 4 * catalog_row_size), catalog_data.len);

    var rows: [4]CatalogRow = undefined;
    for (0..4) |i| {
        rows[i] = try readCatalogRow(catalog_data[i * catalog_row_size ..][0..catalog_row_size]);
    }

    try std.testing.expectEqual(@as(hprof.Id, 0x2001), rows[0].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .class), rows[0].kind);
    try std.testing.expectEqual(class_off, rows[0].source_offset);

    try std.testing.expectEqual(@as(hprof.Id, 0x3000), rows[1].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .instance), rows[1].kind);
    try std.testing.expectEqual(inst_off, rows[1].source_offset);

    try std.testing.expectEqual(@as(hprof.Id, 0x4000), rows[2].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .object_array), rows[2].kind);
    try std.testing.expectEqual(arr_off, rows[2].source_offset);

    try std.testing.expectEqual(@as(hprof.Id, 0x5000), rows[3].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .primitive_array), rows[3].kind);
    try std.testing.expectEqual(prim_off, rows[3].source_offset);

    try std.testing.expectEqualStrings("com.shop.User", result.class_table.className(0x2001).?);
}

test "scanner treats multiple heap dump segments as continuous" {
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
    try b.loadClass(1, 0x2000, 0x1000);

    // First HEAP_DUMP_SEGMENT with one instance
    var seg1 = try b.heapDumpSegment();
    _ = try seg1.classDump(.{ .class_id = 0x2000, .instance_size = 8 });
    _ = try seg1.instanceDump(0x3000, 0x2000, &[_]u8{0} ** 8);
    seg1.end();

    // Second HEAP_DUMP_SEGMENT with a different instance
    var seg2 = try b.heapDumpSegment();
    _ = try seg2.instanceDump(0x3001, 0x2000, &[_]u8{0} ** 8);
    seg2.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var result = try run(allocator, io, &job, bytes, null);
    defer result.deinit(allocator);

    // One class + two instances = 3 catalog rows
    try std.testing.expectEqual(@as(u64, 3), result.n_catalog_rows);

    const catalog_data = try Io.Dir.cwd().readFileAlloc(io, result.catalog_path, allocator, .limited(4096));
    defer allocator.free(catalog_data);
    try std.testing.expectEqual(@as(usize, 3 * catalog_row_size), catalog_data.len);

    var rows: [3]CatalogRow = undefined;
    for (0..3) |i| {
        rows[i] = try readCatalogRow(catalog_data[i * catalog_row_size ..][0..catalog_row_size]);
    }

    // Class
    try std.testing.expectEqual(@as(hprof.Id, 0x2000), rows[0].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .class), rows[0].kind);
    // Instance from segment 1
    try std.testing.expectEqual(@as(hprof.Id, 0x3000), rows[1].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .instance), rows[1].kind);
    // Instance from segment 2
    try std.testing.expectEqual(@as(hprof.Id, 0x3001), rows[2].raw_id);
    try std.testing.expectEqual(@as(CatalogKind, .instance), rows[2].kind);
}

// ─── Parallel heap-segment scan tests ────────────────────────────────────────

/// Byte-level scan output of one dispatch, read back from the staging files.
const DispatchOutcome = struct {
    catalog: []u8,
    roots: []u8,
    prim_histogram: []u8,
    n_catalog_rows: u64,
    n_roots: u64,
    diagnostics: Manifest.Diagnostics,

    fn deinit(self: *DispatchOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.catalog);
        allocator.free(self.roots);
        allocator.free(self.prim_histogram);
    }
};

/// Collect the byte ranges of every HEAP_DUMP / HEAP_DUMP_SEGMENT record body,
/// mirroring what `run` records before dispatching to the scan phase.
fn collectTestSegmentRanges(allocator: std.mem.Allocator, source_data: []const u8) ![]SegmentRange {
    var segments: std.ArrayList(SegmentRange) = .empty;
    errdefer segments.deinit(allocator);
    var reader = try hprof.Reader.init(source_data);
    while (try reader.next()) |record| {
        switch (record) {
            .heap_dump, .heap_dump_segment => {
                const hr = switch (record) {
                    .heap_dump => |h| h,
                    .heap_dump_segment => |h| h,
                    else => unreachable,
                };
                try segments.append(allocator, .{
                    .offset = hr.body_offset,
                    .len = hr.cursor.remaining(),
                });
            },
            else => {},
        }
    }
    return segments.toOwnedSlice(allocator);
}

/// Run `scanSegmentsDispatched` against a fresh staging dir and read back all
/// scan output. `class_table` and `thread_traces` stay populated for callers
/// that want to assert on the merged shared state.
fn runTestDispatch(
    allocator: std.mem.Allocator,
    io: Io,
    source_data: []const u8,
    tmp_dir: []const u8,
    n_workers: usize,
    class_table: *ClassTable,
    thread_traces: *ThreadTraces.Collector,
) !DispatchOutcome {
    const job = try createTestJob(allocator, io, source_data, tmp_dir);
    defer job.deinit(allocator);

    const dir = Io.Dir.cwd();
    const catalog_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "catalog.unsorted" });
    defer allocator.free(catalog_path);
    const roots_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "roots.raw" });
    defer allocator.free(roots_path);
    const hist_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "prim_histogram.bin" });
    defer allocator.free(hist_path);

    var catalog_file = try dir.createFile(io, catalog_path, .{});
    defer catalog_file.close(io);
    var catalog_buf: [65536]u8 = undefined;
    var catalog_file_writer: Io.File.Writer = .init(catalog_file, io, &catalog_buf);

    var roots_file = try dir.createFile(io, roots_path, .{});
    defer roots_file.close(io);
    var roots_buf: [65536]u8 = undefined;
    var roots_file_writer: Io.File.Writer = .init(roots_file, io, &roots_buf);

    const segments = try collectTestSegmentRanges(allocator, source_data);
    defer allocator.free(segments);

    var accs: ScanAccs = .{};
    var prim_histogram = initPrimHistogram();
    var n_catalog_rows: u64 = 0;
    var n_roots: u64 = 0;
    var diagnostics: Manifest.Diagnostics = .{};

    try scanSegmentsDispatched(
        allocator,
        io,
        &job,
        source_data,
        segments,
        class_table,
        thread_traces,
        &catalog_file_writer.interface,
        &roots_file_writer.interface,
        &n_catalog_rows,
        &n_roots,
        &diagnostics,
        &prim_histogram,
        null,
        &accs,
        n_workers,
    );
    try catalog_file_writer.interface.flush();
    try roots_file_writer.interface.flush();

    // Serialize the histogram in the same format `run` writes, so the files
    // are byte-comparable with the full-pipeline output.
    var hist_file = try dir.createFile(io, hist_path, .{});
    defer hist_file.close(io);
    var hist_buf: [65536]u8 = undefined;
    var hist_file_writer: Io.File.Writer = .init(hist_file, io, &hist_buf);
    const hist_writer = &hist_file_writer.interface;
    var prim_count: u32 = 0;
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        if (prim_histogram[field.value].count > 0) prim_count += 1;
    }
    try writeU32(hist_writer, prim_count);
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        const entry = prim_histogram[field.value];
        if (entry.count > 0) {
            try writePrimHistogramEntry(hist_writer, entry);
        }
    }
    try hist_writer.flush();

    return .{
        .catalog = try dir.readFileAlloc(io, catalog_path, allocator, .limited(1 << 20)),
        .roots = try dir.readFileAlloc(io, roots_path, allocator, .limited(1 << 20)),
        .prim_histogram = try dir.readFileAlloc(io, hist_path, allocator, .limited(1 << 20)),
        .n_catalog_rows = n_catalog_rows,
        .n_roots = n_roots,
        .diagnostics = diagnostics,
    };
}

/// Catalog rows sorted lexicographically, so two unsorted catalog files can be
/// compared as multisets regardless of the scan order that produced them.
fn sortedTestCatalogRows(allocator: std.mem.Allocator, data: []const u8) ![][catalog_row_size]u8 {
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @intCast(data.len % catalog_row_size)));
    const rows = try allocator.dupe([catalog_row_size]u8, std.mem.bytesAsSlice([catalog_row_size]u8, data));
    errdefer allocator.free(rows);
    std.mem.sort([catalog_row_size]u8, rows, {}, struct {
        fn less(_: void, a: [catalog_row_size]u8, b: [catalog_row_size]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.less);
    return rows;
}

/// Root records sorted lexicographically, for order-independent comparison.
fn sortedTestRootRecords(allocator: std.mem.Allocator, data: []const u8) ![][root_record_size]u8 {
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @intCast(data.len % root_record_size)));
    const records = try allocator.dupe([root_record_size]u8, std.mem.bytesAsSlice([root_record_size]u8, data));
    errdefer allocator.free(records);
    std.mem.sort([root_record_size]u8, records, {}, struct {
        fn less(_: void, a: [root_record_size]u8, b: [root_record_size]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.less);
    return records;
}

fn expectTestDiagnosticsEqual(a: Manifest.Diagnostics, b: Manifest.Diagnostics) !void {
    inline for (@typeInfo(Manifest.Diagnostics).@"struct".fields) |f| {
        try std.testing.expectEqual(@field(a, f.name), @field(b, f.name));
    }
}

test "parallel scan is deterministic and matches sequential scan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Build a dump with one HEAP_DUMP record and 72 HEAP_DUMP_SEGMENT records
    // so an explicit 4-worker dispatch genuinely fans out across the pool.
    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "com.shop.User");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    // Single-record form: the first segment.
    var seg0 = try b.heapDump();
    _ = try seg0.instanceDump(0x3000, 0x2001, &[_]u8{0} ** 16);
    seg0.end();

    var seg_i: usize = 0;
    while (seg_i < 72) : (seg_i += 1) {
        var seg = try b.heapDumpSegment();
        const inst_id: hprof.Id = @intCast(0x3100 + seg_i);
        _ = try seg.instanceDump(inst_id, 0x2001, &[_]u8{0} ** 16);
        // Duplicate object id in two distant segments: exercises the
        // worker-merge + dedupe interplay (dedupe happens later in the
        // sorter, so both rows must survive the scan identically).
        if (seg_i == 5 or seg_i == 60) {
            _ = try seg.instanceDump(0x9999, 0x2001, &[_]u8{0} ** 16);
        }
        // Thread-object roots in two different workers' segments.
        if (seg_i == 7) {
            _ = try seg.rootThreadObject(0x3200, 11, 1);
        }
        if (seg_i == 40) {
            _ = try seg.rootThreadObject(0x3201, 12, 2);
        }
        // Arrays of both kinds, feeding the histogram merge.
        if (seg_i == 10) {
            _ = try seg.primitiveArrayDump(0x3300, .int, 4, &[_]u8{0} ** 16);
        }
        if (seg_i == 50) {
            _ = try seg.objectArrayDump(0x3301, 0x2000, &[_]hprof.Id{ 0x3100, 0 });
        }
        // A class dump with a non-null constant-pool object ref, so the
        // per-worker diagnostics are non-trivial and must sum on merge.
        if (seg_i == 30) {
            _ = try seg.classDump(.{
                .class_id = 0x2002,
                .super_class_id = 0x2000,
                .instance_size = 8,
                .constant_pool = &.{
                    .{ .index = 0, .type = .object, .value = .{ .object = 0x3100 } },
                },
            });
        }
        seg.end();
    }

    const bytes = try b.finish();
    defer allocator.free(bytes);

    // Sanity: the deferred-segment path really saw all 73 records.
    const segments = try collectTestSegmentRanges(allocator, bytes);
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 73), segments.len);

    // Four staging dirs: full run(), inline dispatch, 4-worker dispatch twice.
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    var tmp_c = std.testing.tmpDir(.{});
    defer tmp_c.cleanup();
    var tmp_d = std.testing.tmpDir(.{});
    defer tmp_d.cleanup();
    const path_a = try tmp_a.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_a);
    const path_b = try tmp_b.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_b);
    const path_c = try tmp_c.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_c);
    const path_d = try tmp_d.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_d);

    // A: the real entry point (inline or parallel depending on host CPUs).
    const job_a = try createTestJob(allocator, io, bytes, path_a);
    defer job_a.deinit(allocator);
    var result_a = try run(allocator, io, &job_a, bytes, null);
    defer result_a.deinit(allocator);
    const dir = Io.Dir.cwd();
    const catalog_a = try dir.readFileAlloc(io, result_a.catalog_path, allocator, .limited(1 << 20));
    defer allocator.free(catalog_a);
    const roots_a = try dir.readFileAlloc(io, result_a.roots_path, allocator, .limited(1 << 20));
    defer allocator.free(roots_a);
    const hist_a = try dir.readFileAlloc(io, result_a.prim_histogram_path, allocator, .limited(1 << 20));
    defer allocator.free(hist_a);

    // B: forced inline. C/D: forced 4-worker pool.
    var class_table_b = ClassTable.init(allocator);
    defer class_table_b.deinit();
    var thread_traces_b = ThreadTraces.Collector.init(allocator);
    defer thread_traces_b.deinit();
    var out_b = try runTestDispatch(allocator, io, bytes, path_b, 1, &class_table_b, &thread_traces_b);
    defer out_b.deinit(allocator);

    var class_table_c = ClassTable.init(allocator);
    defer class_table_c.deinit();
    var thread_traces_c = ThreadTraces.Collector.init(allocator);
    defer thread_traces_c.deinit();
    var out_c = try runTestDispatch(allocator, io, bytes, path_c, 4, &class_table_c, &thread_traces_c);
    defer out_c.deinit(allocator);

    var class_table_d = ClassTable.init(allocator);
    defer class_table_d.deinit();
    var thread_traces_d = ThreadTraces.Collector.init(allocator);
    defer thread_traces_d.deinit();
    var out_d = try runTestDispatch(allocator, io, bytes, path_d, 4, &class_table_d, &thread_traces_d);
    defer out_d.deinit(allocator);

    // Determinism: two 4-worker runs produce byte-identical output, including
    // the order of rows within the unsorted catalog and the roots file.
    try std.testing.expectEqualSlices(u8, out_c.catalog, out_d.catalog);
    try std.testing.expectEqualSlices(u8, out_c.roots, out_d.roots);
    try std.testing.expectEqualSlices(u8, out_c.prim_histogram, out_d.prim_histogram);

    // The parallel worker merge really applied the shared-state records.
    try std.testing.expect(class_table_c.classes.contains(0x2002));
    try std.testing.expectEqual(@as(usize, 2), thread_traces_c.thread_roots.count());

    // Parity across paths: identical row multisets, root multisets, histogram
    // bytes, counts, and diagnostics. Row/root order legitimately differs
    // between the inline and worker paths (workers emit in bucket order);
    // downstream stages normalize via source_offset tiebreaks.
    const rows_a = try sortedTestCatalogRows(allocator, catalog_a);
    defer allocator.free(rows_a);
    const rows_b = try sortedTestCatalogRows(allocator, out_b.catalog);
    defer allocator.free(rows_b);
    const rows_c = try sortedTestCatalogRows(allocator, out_c.catalog);
    defer allocator.free(rows_c);
    try std.testing.expectEqualSlices([catalog_row_size]u8, rows_a, rows_b);
    try std.testing.expectEqualSlices([catalog_row_size]u8, rows_b, rows_c);

    const roots_rec_a = try sortedTestRootRecords(allocator, roots_a);
    defer allocator.free(roots_rec_a);
    const roots_rec_b = try sortedTestRootRecords(allocator, out_b.roots);
    defer allocator.free(roots_rec_b);
    const roots_rec_c = try sortedTestRootRecords(allocator, out_c.roots);
    defer allocator.free(roots_rec_c);
    try std.testing.expectEqualSlices([root_record_size]u8, roots_rec_a, roots_rec_b);
    try std.testing.expectEqualSlices([root_record_size]u8, roots_rec_b, roots_rec_c);

    try std.testing.expectEqualSlices(u8, hist_a, out_b.prim_histogram);
    try std.testing.expectEqualSlices(u8, hist_a, out_c.prim_histogram);

    try std.testing.expectEqual(result_a.n_catalog_rows, out_b.n_catalog_rows);
    try std.testing.expectEqual(result_a.n_catalog_rows, out_c.n_catalog_rows);
    try std.testing.expectEqual(result_a.n_roots, out_b.n_roots);
    try std.testing.expectEqual(result_a.n_roots, out_c.n_roots);
    try expectTestDiagnosticsEqual(result_a.diagnostics, out_b.diagnostics);
    try expectTestDiagnosticsEqual(result_a.diagnostics, out_c.diagnostics);

    // Content sanity for the fixture: 73 instance rows + 2 duplicate rows +
    // 1 class row + 2 array rows; 2 thread-object roots; 1 skipped
    // constant-pool ref counted on every path.
    try std.testing.expectEqual(@as(u64, 78), out_c.n_catalog_rows);
    try std.testing.expectEqual(@as(u64, 2), out_c.n_roots);
    try std.testing.expectEqual(@as(u64, 1), out_c.diagnostics.skipped_constant_pool_refs);
}

test "LPT partition is deterministic and balanced" {
    const allocator = std.testing.allocator;

    const segs = [_]SegmentRange{
        .{ .offset = 100, .len = 100 },
        .{ .offset = 200, .len = 90 },
        .{ .offset = 300, .len = 80 },
        .{ .offset = 400, .len = 80 }, // ties on length: offset must break it
        .{ .offset = 500, .len = 10 },
        .{ .offset = 600, .len = 10 }, // ties on length: offset must break it
        .{ .offset = 700, .len = 5 },
    };

    const buckets_a = try partitionSegmentsLPT(allocator, &segs, 3);
    defer {
        for (buckets_a) |*bucket| bucket.deinit(allocator);
        allocator.free(buckets_a);
    }
    const buckets_b = try partitionSegmentsLPT(allocator, &segs, 3);
    defer {
        for (buckets_b) |*bucket| bucket.deinit(allocator);
        allocator.free(buckets_b);
    }

    // Same input, same partition.
    try std.testing.expectEqual(buckets_a.len, buckets_b.len);
    for (buckets_a, buckets_b) |bucket_a, bucket_b| {
        try std.testing.expectEqualSlices(SegmentRange, bucket_a.items, bucket_b.items);
    }

    // Every segment assigned exactly once.
    var total: usize = 0;
    for (buckets_a) |bucket| total += bucket.items.len;
    try std.testing.expectEqual(segs.len, total);

    // Each bucket preserves the (len desc, offset asc) assignment order.
    for (buckets_a) |bucket| {
        var i: usize = 1;
        while (i < bucket.items.len) : (i += 1) {
            const prev = bucket.items[i - 1];
            const cur = bucket.items[i];
            try std.testing.expect(prev.len > cur.len or (prev.len == cur.len and prev.offset < cur.offset));
        }
    }

    // One worker takes everything, longest first.
    const single = try partitionSegmentsLPT(allocator, &segs, 1);
    defer {
        for (single) |*bucket| bucket.deinit(allocator);
        allocator.free(single);
    }
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqual(segs.len, single[0].items.len);
    try std.testing.expectEqual(@as(u64, 100), single[0].items[0].offset);
}

/// Assert that no worker spill files remain in the staging dir for a
/// `max_workers`-worker run.
fn expectTestDirWithoutSpills(io: Io, dir_path: []const u8, max_workers: usize) !void {
    var worker: usize = 0;
    while (worker < max_workers) : (worker += 1) {
        for ([_][]const u8{ "catalog.spill-", "roots.spill-" }) |prefix| {
            const name = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}{d}", .{ dir_path, prefix, worker });
            defer std.testing.allocator.free(name);
            if (Io.Dir.cwd().openFile(io, name, .{})) |_| {
                return error.SpillFileLeftOver;
            } else |err| {
                try std.testing.expectEqual(error.FileNotFound, err);
            }
        }
    }
}

test "parallel scan spills rows and stays bounded" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // ~16000 instance rows (~512 KiB of catalog rows): each 4-worker bucket
    // must drain its 64 KiB spill buffer multiple times, and the merge reads
    // every spill file back in chunks.
    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.loadClass(1, 0x2000, 0x1000);

    var seg_i: usize = 0;
    while (seg_i < 80) : (seg_i += 1) {
        var seg = try b.heapDumpSegment();
        var j: usize = 0;
        while (j < 200) : (j += 1) {
            const id: hprof.Id = @intCast(0x100000 + seg_i * 200 + j);
            _ = try seg.instanceDump(id, 0x2000, &[_]u8{0} ** 8);
        }
        seg.end();
    }

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    var tmp_c = std.testing.tmpDir(.{});
    defer tmp_c.cleanup();
    var tmp_d = std.testing.tmpDir(.{});
    defer tmp_d.cleanup();
    const path_b = try tmp_b.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_b);
    const path_c = try tmp_c.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_c);
    const path_d = try tmp_d.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_d);

    var class_table_b = ClassTable.init(allocator);
    defer class_table_b.deinit();
    var thread_traces_b = ThreadTraces.Collector.init(allocator);
    defer thread_traces_b.deinit();
    var out_b = try runTestDispatch(allocator, io, bytes, path_b, 1, &class_table_b, &thread_traces_b);
    defer out_b.deinit(allocator);

    var class_table_c = ClassTable.init(allocator);
    defer class_table_c.deinit();
    var thread_traces_c = ThreadTraces.Collector.init(allocator);
    defer thread_traces_c.deinit();
    var out_c = try runTestDispatch(allocator, io, bytes, path_c, 4, &class_table_c, &thread_traces_c);
    defer out_c.deinit(allocator);

    var class_table_d = ClassTable.init(allocator);
    defer class_table_d.deinit();
    var thread_traces_d = ThreadTraces.Collector.init(allocator);
    defer thread_traces_d.deinit();
    var out_d = try runTestDispatch(allocator, io, bytes, path_d, 4, &class_table_d, &thread_traces_d);
    defer out_d.deinit(allocator);

    // Determinism across repeated 4-worker runs.
    try std.testing.expectEqualSlices(u8, out_c.catalog, out_d.catalog);
    try std.testing.expectEqualSlices(u8, out_c.roots, out_d.roots);

    // Parity: same row multiset inline vs pooled.
    const rows_b = try sortedTestCatalogRows(allocator, out_b.catalog);
    defer allocator.free(rows_b);
    const rows_c = try sortedTestCatalogRows(allocator, out_c.catalog);
    defer allocator.free(rows_c);
    try std.testing.expectEqualSlices([catalog_row_size]u8, rows_b, rows_c);
    try std.testing.expectEqual(@as(u64, 16000), out_c.n_catalog_rows);

    // All spill files are cleaned up on both paths: staging dirs hold only
    // the outputs the pipeline produces.
    const staging_b = try std.fs.path.join(allocator, &.{ path_b, "staging" });
    defer allocator.free(staging_b);
    const staging_c = try std.fs.path.join(allocator, &.{ path_c, "staging" });
    defer allocator.free(staging_c);
    const staging_d = try std.fs.path.join(allocator, &.{ path_d, "staging" });
    defer allocator.free(staging_d);
    try expectTestDirWithoutSpills(io, staging_b, 1);
    try expectTestDirWithoutSpills(io, staging_c, 4);
    try expectTestDirWithoutSpills(io, staging_d, 4);
}
