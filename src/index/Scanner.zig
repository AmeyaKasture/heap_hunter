//! Stage 1 scan: walk the HPROF dump once and emit the unsorted catalog,
//! raw root records, and an in-memory class/name table.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Progress = @import("../Progress.zig").Progress;
const log = @import("log");

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

    var diagnostics: Manifest.Diagnostics = .{};
    var n_catalog_rows: u64 = 0;
    var n_roots: u64 = 0;
    var prim_histogram: [16]PrimHistogramEntry = undefined;
    for (&prim_histogram) |*slot| {
        slot.* = .{
            .element_type = .byte,
            .count = 0,
            .bytes = 0,
        };
    }
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        prim_histogram[field.value] = .{
            .element_type = @as(hprof.PrimitiveType, @enumFromInt(field.value)),
            .count = 0,
            .bytes = 0,
        };
    }

    var reader = try hprof.Reader.init(source_data);
    while (try reader.next()) |record| {
        switch (record) {
            .utf8 => |u| {
                try class_table.addUtf8(u.id, u.bytes);
            },
            .load_class => |lc| {
                try class_table.addLoadClass(lc.serial, lc.class_id, lc.name_id);
            },
            // HPROF 1.0.2 uses either a single HEAP_DUMP or multiple HEAP_DUMP_SEGMENT records.
            .heap_dump => |heap_reader| {
                var hr = heap_reader;
                try scanHeapDump(
                    job,
                    &hr,
                    &class_table,
                    catalog_writer,
                    roots_writer,
                    &n_catalog_rows,
                    &n_roots,
                    &diagnostics,
                    &prim_histogram,
                );
            },
            .heap_dump_segment => |heap_reader| {
                var hr = heap_reader;
                try scanHeapDump(
                    job,
                    &hr,
                    &class_table,
                    catalog_writer,
                    roots_writer,
                    &n_catalog_rows,
                    &n_roots,
                    &diagnostics,
                    &prim_histogram,
                );
            },
            else => {},
        }
        if (progress) |p| p.tick();
    }

    try catalog_file_writer.flush();
    try roots_file_writer.flush();

    var prim_count: u32 = 0;
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        if (prim_histogram[field.value].count > 0) prim_count += 1;
    }
    try writeU32(prim_histogram_writer, prim_count);
    inline for (@typeInfo(hprof.PrimitiveType).@"enum".fields) |field| {
        const entry = prim_histogram[field.value];
        if (entry.count > 0) {
            try writePrimHistogramEntry(prim_histogram_writer, entry);
        }
    }
    try prim_histogram_file_writer.flush();

    log.debug("scanner complete: n_catalog_rows={d}, n_roots={d}, diagnostics={any}", .{ n_catalog_rows, n_roots, diagnostics });

    return .{
        .catalog_path = catalog_path,
        .roots_path = roots_path,
        .prim_histogram_path = prim_histogram_path,
        .class_table = class_table,
        .n_catalog_rows = n_catalog_rows,
        .n_roots = n_roots,
        .diagnostics = diagnostics,
    };
}

fn writeU32(writer: *Io.Writer, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try writer.writeAll(&buf);
}

/// Scan all sub-records inside a single `HEAP_DUMP` or `HEAP_DUMP_SEGMENT`.
/// Emits catalog rows for heap entities and root records for GC roots.
fn scanHeapDump(
    job: *const Preflight.Job,
    hr: *hprof.HeapDumpReader,
    class_table: *ClassTable,
    catalog_writer: *Io.Writer,
    roots_writer: *Io.Writer,
    n_catalog_rows: *u64,
    n_roots: *u64,
    diagnostics: *Manifest.Diagnostics,
    prim_histogram: []PrimHistogramEntry,
) !void {
    while (try hr.nextWithOffset()) |item| {
        switch (item.record) {
            .gc_class_dump => |cd| {
                try class_table.addClassDump(cd);

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
            // Any remaining subtag is one of the nine GC root kinds.
            else => |root| {
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
