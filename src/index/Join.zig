//! Stage 5: resolve raw edge endpoints to dense ordinals via external sort
//! and streaming merge joins against the sorted catalog.
//!
//! After Stage 4, edges are still expressed as raw HPROF IDs (JVM heap
//! addresses). This module converts every `(source_raw_id, target_raw_id)` pair
//! into `(source_ordinal, target_ordinal)` where the ordinals are the row
//! indices of the corresponding IDs in `catalog.bin`. The conversion is done
//! in two passes:
//!
//!   1. Sort edges by source raw ID and merge-join with `catalog.bin` to
//!      obtain `source_ordinal`.
//!   2. Sort the intermediate records by target raw ID and merge-join again
//!      to obtain `target_ordinal`.
//!
//! Virtual-root edges (source == `EdgeEmitter.virtual_root_sentinel`) are
//! resolved to ordinal `n_objects` without catalog lookup. Edges whose source
//! or target cannot be found in the catalog are dropped and counted in
//! `Manifest.Diagnostics`.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const CatalogSorter = @import("CatalogSorter.zig");
const EdgeEmitter = @import("EdgeEmitter.zig");
const Scanner = @import("Scanner.zig");
const ExtSort = @import("ExtSort.zig");

/// Size in bytes of one source-resolved intermediate record:
/// `source_ordinal u32` + `target_raw_id u64`.
pub const source_resolved_record_size = 12;

/// Intermediate edge representation after the first merge-join.
/// The source endpoint has been replaced by its dense ordinal, while the
/// target endpoint is still a raw HPROF ID waiting for the second pass.
pub const SourceResolvedRecord = struct {
    /// Dense ordinal of the source vertex (row index in `catalog.bin`), or
    /// `n_objects` for the synthetic virtual root.
    source_ordinal: u32,
    /// Raw HPROF ID of the target vertex; resolved in the second pass.
    target_raw_id: u64,
};

/// Serialize `rec` as a fixed 12-byte record into `writer`.
/// Layout: `source_ordinal` (little-endian u32), `target_raw_id` (little-endian u64).
pub fn writeSourceResolvedRecord(writer: *Io.Writer, rec: SourceResolvedRecord) !void {
    var buf: [source_resolved_record_size]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], rec.source_ordinal, .little);
    std.mem.writeInt(u64, buf[4..12], rec.target_raw_id, .little);
    try writer.writeAll(&buf);
}

/// Deserialize a 12-byte source-resolved record from `buf`.
/// `buf` must be exactly `source_resolved_record_size` bytes long.
pub fn readSourceResolvedRecord(buf: *const [source_resolved_record_size]u8) SourceResolvedRecord {
    return .{
        .source_ordinal = std.mem.readInt(u32, buf[0..4], .little),
        .target_raw_id = std.mem.readInt(u64, buf[4..12], .little),
    };
}

/// Size in bytes of one final resolved edge record:
/// `source_ordinal u32` + `target_ordinal u32`.
pub const resolved_record_size = 8;

/// Final edge representation used by the CSR writers in Stage 7.
/// Both endpoints are dense `u32` ordinals suitable for adjacency arrays.
pub const ResolvedRecord = struct {
    /// Dense ordinal of the source vertex.
    source_ordinal: u32,
    /// Dense ordinal of the target vertex.
    target_ordinal: u32,
};

/// Serialize `rec` as a fixed 8-byte record into `writer`.
/// Layout: `source_ordinal` (little-endian u32), `target_ordinal` (little-endian u32).
pub fn writeResolvedRecord(writer: *Io.Writer, rec: ResolvedRecord) !void {
    var buf: [resolved_record_size]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], rec.source_ordinal, .little);
    std.mem.writeInt(u32, buf[4..8], rec.target_ordinal, .little);
    try writer.writeAll(&buf);
}

/// Deserialize an 8-byte resolved edge record from `buf`.
/// `buf` must be exactly `resolved_record_size` bytes long.
pub fn readResolvedRecord(buf: *const [resolved_record_size]u8) ResolvedRecord {
    return .{
        .source_ordinal = std.mem.readInt(u32, buf[0..4], .little),
        .target_ordinal = std.mem.readInt(u32, buf[4..8], .little),
    };
}

/// Result returned by `run`. Holds the path to `edges.resolved` and the total
/// number of edges that survived both join passes.
pub const Result = struct {
    /// Absolute path to `edges.resolved` in the staging directory.
    resolved_path: []const u8,
    /// Number of edges whose source and target both existed in the catalog.
    n_edges: u64,

    /// Free the allocated `resolved_path`. The resolved edge file itself is
    /// left in the staging directory for later stages.
    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved_path);
    }
};

/// Errors specific to the Stage 5 join pipeline.
pub const Error = error{
    /// `edges.raw` (or an intermediate edge file) has a length that is not a
    /// multiple of its expected record size.
    InvalidEdgeFile,
    /// `catalog.bin` has a length that is not a multiple of `catalog_row_size`.
    InvalidCatalogFile,
};

/// Comparator used by the first external sort: order 16-byte raw edge records
/// by their `source_raw_id` (bytes `[0..8)`), ascending.
fn edgeLessBySource(_: void, a: []const u8, b: []const u8) bool {
    const a_id = std.mem.readInt(u64, a[0..8], .little);
    const b_id = std.mem.readInt(u64, b[0..8], .little);
    return a_id < b_id;
}

/// Comparator used by the second external sort: order 12-byte source-resolved
/// records by their `target_raw_id` (bytes `[4..12)`), ascending.
fn sourceResolvedLessByTarget(_: void, a: []const u8, b: []const u8) bool {
    const a_id = std.mem.readInt(u64, a[4..12], .little);
    const b_id = std.mem.readInt(u64, b[4..12], .little);
    return a_id < b_id;
}

/// Stage 5 entry point: resolve raw edge endpoints to dense ordinals.
///
/// The function performs two external sorts and two streaming merge joins:
///
///   1. Sort `edges.raw` by source raw ID.
///   2. Merge-join the sorted edges with `catalog.bin` to attach
///      `source_ordinal`, writing `edges.source_resolved`.
///   3. Sort `edges.source_resolved` by target raw ID.
///   4. Merge-join the sorted intermediate records with `catalog.bin` to
///      attach `target_ordinal`, writing `edges.resolved`.
///
/// Virtual-root edges (source == `EdgeEmitter.virtual_root_sentinel`) bypass
/// the catalog lookup and use ordinal `n_objects`. Edges that cannot be
/// resolved are dropped and counted in `diagnostics`.
///
/// `n_objects` is the number of unique rows in `catalog.bin` (i.e., the
/// real vertex count). The virtual root is assigned ordinal `n_objects`.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    edges_path: []const u8,
    catalog_path: []const u8,
    n_objects: u64,
    diagnostics: *Manifest.Diagnostics,
) !Result {
    // The virtual root is the synthetic vertex immediately after all real
    // catalog rows. It must fit in a u32 because all ordinals do.
    const virtual_root_ordinal: u32 = @intCast(n_objects);

    // Sort edges by source raw ID.
    const edges_by_source_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "edges.by_source" });
    defer allocator.free(edges_by_source_path);

    try ExtSort.sortStreaming(io, allocator, edges_path, edges_by_source_path, .{
        .record_size = EdgeEmitter.edge_record_size,
        .budget_bytes = job.budget_bytes,
    }, null, {}, edgeLessBySource);

    // Resolve source IDs: merge-join sorted edges with the catalog.
    const source_resolved_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "edges.source_resolved" });
    defer allocator.free(source_resolved_path);

    try resolveSourcesStreaming(
        allocator,
        io,
        edges_by_source_path,
        catalog_path,
        source_resolved_path,
        virtual_root_ordinal,
        diagnostics,
        job.budget_bytes,
    );

    // Sort intermediate records by target raw ID.
    const edges_by_target_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "edges.by_target" });
    defer allocator.free(edges_by_target_path);

    try ExtSort.sortStreaming(io, allocator, source_resolved_path, edges_by_target_path, .{
        .record_size = source_resolved_record_size,
        .budget_bytes = job.budget_bytes,
    }, null, {}, sourceResolvedLessByTarget);

    // Resolve target IDs: merge-join sorted intermediate records with the catalog.
    const resolved_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "edges.resolved" });
    errdefer allocator.free(resolved_path);

    const n_edges = try resolveTargetsStreaming(
        allocator,
        io,
        edges_by_target_path,
        catalog_path,
        resolved_path,
        diagnostics,
        job.budget_bytes,
    );

    return .{
        .resolved_path = resolved_path,
        .n_edges = n_edges,
    };
}

/// A catalog row paired with its ordinal index. Used by the streaming merge-join
/// passes to attach ordinals without memory-mapping the entire catalog.
const CatalogRowWithOrdinal = struct {
    row: Scanner.CatalogRow,
    ordinal: u32,
};

/// Read the next catalog row from a streaming reader. Returns `null` at EOF.
fn readNextCatalogRow(reader: *Io.File.Reader, next_ordinal: *u32) !?CatalogRowWithOrdinal {
    const buf = reader.interface.takeArray(Scanner.catalog_row_size) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
    const row = try Scanner.readCatalogRow(buf);
    const ordinal = next_ordinal.*;
    next_ordinal.* += 1;
    return .{ .row = row, .ordinal = ordinal };
}

/// Read the next 16-byte edge record from a streaming reader. Returns `null` at EOF.
fn readNextEdgeRecord(reader: *Io.File.Reader) !?EdgeEmitter.EdgeRecord {
    const buf = reader.interface.takeArray(EdgeEmitter.edge_record_size) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
    return EdgeEmitter.readEdgeRecord(buf);
}

/// Read the next 12-byte source-resolved record from a streaming reader. Returns `null` at EOF.
fn readNextSourceResolvedRecord(reader: *Io.File.Reader) !?SourceResolvedRecord {
    const buf = reader.interface.takeArray(source_resolved_record_size) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => |e| return e,
    };
    return readSourceResolvedRecord(buf);
}

/// First merge-join pass: streaming implementation.
///
/// Reads edge records and catalog rows through bounded buffers instead of
/// memory-mapping the entire files. Keeps only one edge record and one catalog
/// row in flight at a time, so memory usage is O(budget) rather than O(edges +
/// objects).
fn resolveSourcesStreaming(
    allocator: std.mem.Allocator,
    io: Io,
    sorted_edges_path: []const u8,
    catalog_path: []const u8,
    output_path: []const u8,
    virtual_root_ordinal: u32,
    diagnostics: *Manifest.Diagnostics,
    budget_bytes: usize,
) !void {
    const dir = Io.Dir.cwd();

    // Open and validate the sorted edge file.
    var edges_file = try dir.openFile(io, sorted_edges_path, .{});
    defer edges_file.close(io);
    const edges_len = try edges_file.length(io);
    if (edges_len % EdgeEmitter.edge_record_size != 0) return error.InvalidEdgeFile;

    // Empty input: produce an empty output file and exit.
    if (edges_len == 0) {
        var empty_out = try dir.createFile(io, output_path, .{});
        empty_out.close(io);
        diagnostics.dangling_source_edges = 0;
        return;
    }

    const buffer_size = @max(budget_bytes / 3, 4 * 1024);

    const edges_reader_buf = try allocator.alloc(u8, buffer_size);
    defer allocator.free(edges_reader_buf);
    var edges_reader: Io.File.Reader = .init(edges_file, io, edges_reader_buf);

    // Open and validate the catalog file.
    var catalog_file = try dir.openFile(io, catalog_path, .{});
    defer catalog_file.close(io);
    const catalog_len = try catalog_file.length(io);
    if (catalog_len % CatalogSorter.catalog_row_size != 0) return error.InvalidCatalogFile;

    const catalog_reader_buf = try allocator.alloc(u8, buffer_size);
    defer allocator.free(catalog_reader_buf);
    var catalog_reader: Io.File.Reader = .init(catalog_file, io, catalog_reader_buf);

    // Open the output file.
    var out_file = try dir.createFile(io, output_path, .{});
    defer out_file.close(io);
    const out_buf = try allocator.alloc(u8, buffer_size);
    defer allocator.free(out_buf);
    var out_file_writer: Io.File.Writer = .init(out_file, io, out_buf);
    const out_writer = &out_file_writer.interface;

    var next_ordinal: u32 = 0;
    var current_catalog: ?CatalogRowWithOrdinal = try readNextCatalogRow(&catalog_reader, &next_ordinal);
    var dangling_sources: u64 = 0;

    while (try readNextEdgeRecord(&edges_reader)) |edge| {
        if (edge.source_raw_id == EdgeEmitter.virtual_root_sentinel) {
            try writeSourceResolvedRecord(out_writer, .{
                .source_ordinal = virtual_root_ordinal,
                .target_raw_id = edge.target_raw_id,
            });
            continue;
        }

        // Advance catalog pointer until the current catalog row's raw ID is
        // >= the edge's source raw ID.
        while (current_catalog) |cat| {
            if (cat.row.raw_id >= edge.source_raw_id) break;
            current_catalog = try readNextCatalogRow(&catalog_reader, &next_ordinal);
        }

        if (current_catalog) |cat| {
            if (cat.row.raw_id == edge.source_raw_id) {
                try writeSourceResolvedRecord(out_writer, .{
                    .source_ordinal = cat.ordinal,
                    .target_raw_id = edge.target_raw_id,
                });
                continue;
            }
        }

        dangling_sources += 1;
    }

    try out_file_writer.flush();
    diagnostics.dangling_source_edges = dangling_sources;
}

/// Second merge-join pass: streaming implementation.
///
/// Reads source-resolved records and catalog rows through bounded buffers. Keeps
/// only one intermediate record and one catalog row in flight at a time.
fn resolveTargetsStreaming(
    allocator: std.mem.Allocator,
    io: Io,
    sorted_intermediate_path: []const u8,
    catalog_path: []const u8,
    output_path: []const u8,
    diagnostics: *Manifest.Diagnostics,
    budget_bytes: usize,
) !u64 {
    const dir = Io.Dir.cwd();

    var intermediate_file = try dir.openFile(io, sorted_intermediate_path, .{});
    defer intermediate_file.close(io);
    const intermediate_len = try intermediate_file.length(io);
    if (intermediate_len % source_resolved_record_size != 0) return error.InvalidEdgeFile;

    // Empty input: produce an empty output file and exit.
    if (intermediate_len == 0) {
        var empty_out = try dir.createFile(io, output_path, .{});
        empty_out.close(io);
        diagnostics.dangling_target_edges = 0;
        return 0;
    }

    const buffer_size = @max(budget_bytes / 3, 4 * 1024);

    const intermediate_reader_buf = try allocator.alloc(u8, buffer_size);
    defer allocator.free(intermediate_reader_buf);
    var intermediate_reader: Io.File.Reader = .init(intermediate_file, io, intermediate_reader_buf);

    var catalog_file = try dir.openFile(io, catalog_path, .{});
    defer catalog_file.close(io);
    const catalog_len = try catalog_file.length(io);
    if (catalog_len % CatalogSorter.catalog_row_size != 0) return error.InvalidCatalogFile;

    const catalog_reader_buf = try allocator.alloc(u8, buffer_size);
    defer allocator.free(catalog_reader_buf);
    var catalog_reader: Io.File.Reader = .init(catalog_file, io, catalog_reader_buf);

    var out_file = try dir.createFile(io, output_path, .{});
    defer out_file.close(io);
    const out_buf = try allocator.alloc(u8, buffer_size);
    defer allocator.free(out_buf);
    var out_file_writer: Io.File.Writer = .init(out_file, io, out_buf);
    const out_writer = &out_file_writer.interface;

    var next_ordinal: u32 = 0;
    var current_catalog: ?CatalogRowWithOrdinal = try readNextCatalogRow(&catalog_reader, &next_ordinal);
    var dangling_targets: u64 = 0;
    var n_edges: u64 = 0;

    while (try readNextSourceResolvedRecord(&intermediate_reader)) |inter| {
        const target_raw_id = inter.target_raw_id;

        // Advance catalog pointer until the current catalog row's raw ID is
        // >= the target raw ID.
        while (current_catalog) |cat| {
            if (cat.row.raw_id >= target_raw_id) break;
            current_catalog = try readNextCatalogRow(&catalog_reader, &next_ordinal);
        }

        if (current_catalog) |cat| {
            if (cat.row.raw_id == target_raw_id) {
                try writeResolvedRecord(out_writer, .{
                    .source_ordinal = inter.source_ordinal,
                    .target_ordinal = cat.ordinal,
                });
                n_edges += 1;
                continue;
            }
        }

        dangling_targets += 1;
    }

    try out_file_writer.flush();
    diagnostics.dangling_target_edges = dangling_targets;
    return n_edges;
}

/// First merge-join pass: resolve the `source_raw_id` of every edge to a
/// catalog ordinal.
///
/// Both `sorted_edges_path` and `catalog_path` must be sorted ascending by raw
/// ID. The function memory-maps both inputs and streams the output to
/// `output_path`. Virtual-root edges are emitted using `virtual_root_ordinal`
/// without catalog lookup. Edges whose source ID is absent from the catalog
/// are silently dropped and counted in `diagnostics.dangling_source_edges`.
fn resolveSourcesMapped(
    io: Io,
    sorted_edges_path: []const u8,
    catalog_path: []const u8,
    output_path: []const u8,
    virtual_root_ordinal: u32,
    diagnostics: *Manifest.Diagnostics,
) !void {
    const dir = Io.Dir.cwd();

    // Open and validate the sorted edge file.
    var edges_file = try dir.openFile(io, sorted_edges_path, .{});
    defer edges_file.close(io);
    const edges_len = try edges_file.length(io);
    if (edges_len % EdgeEmitter.edge_record_size != 0) return error.InvalidEdgeFile;

    // Empty input: produce an empty output file and exit. Avoids a
    // zero-length mmap, which the runtime rejects.
    if (edges_len == 0) {
        var empty_out = try dir.createFile(io, output_path, .{});
        empty_out.close(io);
        diagnostics.dangling_source_edges = 0;
        return;
    }

    // Memory-map the sorted edge file read-only.
    var edges_mm = try Io.File.MemoryMap.create(io, edges_file, .{
        .len = edges_len,
        .protection = .{ .read = true, .write = false },
    });
    defer edges_mm.destroy(io);

    // Open and validate the catalog file.
    var catalog_file = try dir.openFile(io, catalog_path, .{});
    defer catalog_file.close(io);
    const catalog_len = try catalog_file.length(io);
    if (catalog_len % CatalogSorter.catalog_row_size != 0) return error.InvalidCatalogFile;

    // Memory-map the catalog read-only, handling an empty catalog specially
    // so that all non-virtual-root edges are counted as dangling.
    var catalog_mm: ?Io.File.MemoryMap = null;
    defer if (catalog_mm) |*mm| mm.destroy(io);
    const catalog_data: []const u8 = blk: {
        if (catalog_len == 0) break :blk &[_]u8{};
        catalog_mm = try Io.File.MemoryMap.create(io, catalog_file, .{
            .len = catalog_len,
            .protection = .{ .read = true, .write = false },
        });
        break :blk catalog_mm.?.memory;
    };

    const n_edges = edges_len / EdgeEmitter.edge_record_size;
    const n_catalog = catalog_len / CatalogSorter.catalog_row_size;

    // Prepare the output file with a 64 KiB stack buffer.
    var out_file = try dir.createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buf: [65536]u8 = undefined;
    var out_file_writer: Io.File.Writer = .init(out_file, io, &out_buf);
    const out_writer = &out_file_writer.interface;

    // `catalog_idx` is the merge-join cursor. It only moves forward because
    // both inputs are sorted ascending by raw ID.
    var catalog_idx: usize = 0;
    var dangling_sources: u64 = 0;

    // Stream through the sorted edges, resolving each source raw ID.
    var edge_idx: usize = 0;
    while (edge_idx < n_edges) : (edge_idx += 1) {
        const edge = EdgeEmitter.readEdgeRecord(
            edges_mm.memory[edge_idx * EdgeEmitter.edge_record_size ..][0..EdgeEmitter.edge_record_size],
        );

        // Virtual-root edges represent GC roots; their source is the
        // synthetic root vertex, not a real object in the catalog.
        if (edge.source_raw_id == EdgeEmitter.virtual_root_sentinel) {
            try writeSourceResolvedRecord(out_writer, .{
                .source_ordinal = virtual_root_ordinal,
                .target_raw_id = edge.target_raw_id,
            });
            continue;
        }

        // Advance catalog cursor until the current catalog raw ID is greater
        // than or equal to the edge's source raw ID. Because both files are
        // sorted, we never need to move the cursor backward.
        while (catalog_idx < n_catalog) {
            const cat_id = std.mem.readInt(u64, catalog_data[catalog_idx * CatalogSorter.catalog_row_size ..][0..8], .little);
            if (cat_id >= edge.source_raw_id) break;
            catalog_idx += 1;
        }

        // If the cursor points to the exact source ID, emit the record with
        // the cursor's index as the source ordinal. Otherwise the source is
        // dangling.
        if (catalog_idx < n_catalog) {
            const cat_id = std.mem.readInt(u64, catalog_data[catalog_idx * CatalogSorter.catalog_row_size ..][0..8], .little);
            if (cat_id == edge.source_raw_id) {
                try writeSourceResolvedRecord(out_writer, .{
                    .source_ordinal = @intCast(catalog_idx),
                    .target_raw_id = edge.target_raw_id,
                });
                continue;
            }
        }

        dangling_sources += 1;
    }

    try out_file_writer.flush();
    diagnostics.dangling_source_edges = dangling_sources;
}

/// Second merge-join pass: resolve the `target_raw_id` of every intermediate
/// record to a catalog ordinal.
///
/// `sorted_intermediate_path` must contain 12-byte `(source_ordinal,
/// target_raw_id)` records sorted by `target_raw_id`. The function streams
/// through the records and `catalog.bin` together, writing final resolved
/// edges to `output_path`. Records whose target ID is absent from the catalog
/// are dropped and counted in `diagnostics.dangling_target_edges`.
///
/// Returns the number of edges that survived both join passes.
fn resolveTargetsMapped(
    io: Io,
    sorted_intermediate_path: []const u8,
    catalog_path: []const u8,
    output_path: []const u8,
    diagnostics: *Manifest.Diagnostics,
) !u64 {
    const dir = Io.Dir.cwd();

    // Open and validate the sorted intermediate file.
    var intermediate_file = try dir.openFile(io, sorted_intermediate_path, .{});
    defer intermediate_file.close(io);
    const intermediate_len = try intermediate_file.length(io);
    if (intermediate_len % source_resolved_record_size != 0) return error.InvalidEdgeFile;

    // Empty input: produce an empty output file and exit.
    if (intermediate_len == 0) {
        var empty_out = try dir.createFile(io, output_path, .{});
        empty_out.close(io);
        diagnostics.dangling_target_edges = 0;
        return 0;
    }

    // Memory-map the intermediate file read-only.
    var intermediate_mm = try Io.File.MemoryMap.create(io, intermediate_file, .{
        .len = intermediate_len,
        .protection = .{ .read = true, .write = false },
    });
    defer intermediate_mm.destroy(io);

    // Open and validate the catalog file.
    var catalog_file = try dir.openFile(io, catalog_path, .{});
    defer catalog_file.close(io);
    const catalog_len = try catalog_file.length(io);
    if (catalog_len % CatalogSorter.catalog_row_size != 0) return error.InvalidCatalogFile;

    // Memory-map the catalog read-only, handling the empty-catalog edge case.
    var catalog_mm: ?Io.File.MemoryMap = null;
    defer if (catalog_mm) |*mm| mm.destroy(io);
    const catalog_data: []const u8 = blk: {
        if (catalog_len == 0) break :blk &[_]u8{};
        catalog_mm = try Io.File.MemoryMap.create(io, catalog_file, .{
            .len = catalog_len,
            .protection = .{ .read = true, .write = false },
        });
        break :blk catalog_mm.?.memory;
    };

    const n_intermediate = intermediate_len / source_resolved_record_size;
    const n_catalog = catalog_len / CatalogSorter.catalog_row_size;

    // Prepare the output file.
    var out_file = try dir.createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buf: [65536]u8 = undefined;
    var out_file_writer: Io.File.Writer = .init(out_file, io, &out_buf);
    const out_writer = &out_file_writer.interface;

    // Forward-only catalog cursor for the merge-join.
    var catalog_idx: usize = 0;
    var dangling_targets: u64 = 0;
    var n_edges: u64 = 0;

    // Stream through the intermediate records and resolve each target.
    var inter_idx: usize = 0;
    while (inter_idx < n_intermediate) : (inter_idx += 1) {
        const inter = readSourceResolvedRecord(
            intermediate_mm.memory[inter_idx * source_resolved_record_size ..][0..source_resolved_record_size],
        );
        const target_raw_id = inter.target_raw_id;

        // Advance catalog cursor until the current catalog raw ID is greater
        // than or equal to the intermediate target raw ID.
        while (catalog_idx < n_catalog) {
            const cat_id = std.mem.readInt(u64, catalog_data[catalog_idx * CatalogSorter.catalog_row_size ..][0..8], .little);
            if (cat_id >= target_raw_id) break;
            catalog_idx += 1;
        }

        // Exact match: emit the final resolved edge.
        if (catalog_idx < n_catalog) {
            const cat_id = std.mem.readInt(u64, catalog_data[catalog_idx * CatalogSorter.catalog_row_size ..][0..8], .little);
            if (cat_id == target_raw_id) {
                try writeResolvedRecord(out_writer, .{
                    .source_ordinal = inter.source_ordinal,
                    .target_ordinal = @intCast(catalog_idx),
                });
                n_edges += 1;
                continue;
            }
        }

        dangling_targets += 1;
    }

    try out_file_writer.flush();
    diagnostics.dangling_target_edges = dangling_targets;
    return n_edges;
}

/// Build a synthetic `Preflight.Job` for unit tests.
/// Creates a temporary staging directory under `tmp_dir` and fills in a
/// minimal job with a deterministic fingerprint.
fn createTestJob(allocator: std.mem.Allocator, io_arg: Io, tmp_dir: []const u8) !Preflight.Job {
    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "staging" });
    errdefer allocator.free(staging_dir);
    try Io.Dir.cwd().createDirPath(io_arg, staging_dir);

    const header: hprof.Header.Header = .{ .id_size = 8, .timestamp = 0 };
    const fingerprint = try Manifest.computeFingerprint(allocator, "", header, 0);
    errdefer fingerprint.deinit(allocator);

    return .{
        .source_path = "test.hprof",
        .index_dir = tmp_dir,
        .staging_dir = staging_dir,

        .budget_bytes = 1024 * 1024,
        .fingerprint = fingerprint,
        .header = header,
    };
}

/// Create synthetic `catalog.bin` and `edges.raw` files from in-memory rows
/// and edges. Used by unit tests to exercise `run` without parsing real
/// HPROF data.
fn createSyntheticFiles(
    allocator: std.mem.Allocator,
    io_arg: Io,
    tmp_dir: []const u8,
    catalog_rows: []const Scanner.CatalogRow,
    edges: []const EdgeEmitter.EdgeRecord,
) !struct { catalog_path: []const u8, edges_path: []const u8 } {
    const catalog_path = try std.fs.path.join(allocator, &.{ tmp_dir, "catalog.bin" });
    errdefer allocator.free(catalog_path);
    const edges_path = try std.fs.path.join(allocator, &.{ tmp_dir, "edges.raw" });
    errdefer allocator.free(edges_path);

    const dir = Io.Dir.cwd();

    // Write catalog rows in the order provided; tests supply them sorted.
    var catalog_file = try dir.createFile(io_arg, catalog_path, .{});
    defer catalog_file.close(io_arg);
    var catalog_buf: [65536]u8 = undefined;
    var catalog_writer: Io.File.Writer = .init(catalog_file, io_arg, &catalog_buf);
    for (catalog_rows) |row| {
        try Scanner.writeCatalogRow(&catalog_writer.interface, row);
    }
    try catalog_writer.flush();

    // Write raw edge records.
    var edges_file = try dir.createFile(io_arg, edges_path, .{});
    defer edges_file.close(io_arg);
    var edges_buf: [65536]u8 = undefined;
    var edges_writer: Io.File.Writer = .init(edges_file, io_arg, &edges_buf);
    for (edges) |edge| {
        try EdgeEmitter.writeEdgeRecord(&edges_writer.interface, edge);
    }
    try edges_writer.flush();

    return .{ .catalog_path = catalog_path, .edges_path = edges_path };
}

/// Assert that the resolved edge at `index` in `data` equals the expected
/// source and target ordinals.
fn expectResolved(
    data: []const u8,
    index: usize,
    expected_source: u32,
    expected_target: u32,
) !void {
    const rec = readResolvedRecord(data[index * resolved_record_size ..][0..resolved_record_size]);
    try std.testing.expectEqual(expected_source, rec.source_ordinal);
    try std.testing.expectEqual(expected_target, rec.target_ordinal);
}

// End-to-end Stage 5 worked example with three objects and two edges.
test "Stage 5 worked example verbatim" {
    const allocator = std.testing.allocator;
    const io_arg = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io_arg, ".", allocator);
    defer allocator.free(tmp_path);

    const rows = &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
        .{ .raw_id = 0x3000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
    };

    const edges = &[_]EdgeEmitter.EdgeRecord{
        .{ .source_raw_id = 0x2000, .target_raw_id = 0x3000 },
        .{ .source_raw_id = 0x1000, .target_raw_id = 0x2000 },
    };

    const files = try createSyntheticFiles(allocator, io_arg, tmp_path, rows, edges);
    defer allocator.free(files.catalog_path);
    defer allocator.free(files.edges_path);

    var job = try createTestJob(allocator, io_arg, tmp_path);
    defer job.deinit(allocator);


    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io_arg, &job, files.edges_path, files.catalog_path, 3, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 2), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_source_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_target_edges);

    const data = try Io.Dir.cwd().readFileAlloc(io_arg, result.resolved_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, 2 * resolved_record_size), data.len);
    try expectResolved(data, 0, 0, 1);
    try expectResolved(data, 1, 1, 2);
}

// A GC-root edge must resolve to the virtual-root ordinal (equal to the
// catalog size), not be looked up in the catalog.
test "virtual root edge resolves to virtual root ordinal" {
    const allocator = std.testing.allocator;
    const io_arg = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io_arg, ".", allocator);
    defer allocator.free(tmp_path);

    const rows = &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
    };

    const edges = &[_]EdgeEmitter.EdgeRecord{
        .{ .source_raw_id = EdgeEmitter.virtual_root_sentinel, .target_raw_id = 0x1000 },
    };

    const files = try createSyntheticFiles(allocator, io_arg, tmp_path, rows, edges);
    defer allocator.free(files.catalog_path);
    defer allocator.free(files.edges_path);

    var job = try createTestJob(allocator, io_arg, tmp_path);
    defer job.deinit(allocator);


    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io_arg, &job, files.edges_path, files.catalog_path, 2, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_source_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_target_edges);

    const data = try Io.Dir.cwd().readFileAlloc(io_arg, result.resolved_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, resolved_record_size), data.len);
    try expectResolved(data, 0, 2, 0);
}

// An edge whose source raw ID is missing from the catalog must be dropped
// and counted as a dangling source.
test "dangling source is dropped and counted" {
    const allocator = std.testing.allocator;
    const io_arg = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io_arg, ".", allocator);
    defer allocator.free(tmp_path);

    const rows = &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
    };

    const edges = &[_]EdgeEmitter.EdgeRecord{
        .{ .source_raw_id = 0xdeadbeef, .target_raw_id = 0x2000 },
        .{ .source_raw_id = 0x1000, .target_raw_id = 0x2000 },
    };

    const files = try createSyntheticFiles(allocator, io_arg, tmp_path, rows, edges);
    defer allocator.free(files.catalog_path);
    defer allocator.free(files.edges_path);

    var job = try createTestJob(allocator, io_arg, tmp_path);
    defer job.deinit(allocator);


    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io_arg, &job, files.edges_path, files.catalog_path, 2, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.n_edges);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.dangling_source_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_target_edges);

    const data = try Io.Dir.cwd().readFileAlloc(io_arg, result.resolved_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, resolved_record_size), data.len);
    try expectResolved(data, 0, 0, 1);
}

// An edge whose target raw ID is missing from the catalog must be dropped
// and counted as a dangling target.
test "dangling target is dropped and counted" {
    const allocator = std.testing.allocator;
    const io_arg = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io_arg, ".", allocator);
    defer allocator.free(tmp_path);

    const rows = &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
    };

    const edges = &[_]EdgeEmitter.EdgeRecord{
        .{ .source_raw_id = 0x1000, .target_raw_id = 0xdeadbeef },
        .{ .source_raw_id = 0x1000, .target_raw_id = 0x2000 },
    };

    const files = try createSyntheticFiles(allocator, io_arg, tmp_path, rows, edges);
    defer allocator.free(files.catalog_path);
    defer allocator.free(files.edges_path);

    var job = try createTestJob(allocator, io_arg, tmp_path);
    defer job.deinit(allocator);


    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io_arg, &job, files.edges_path, files.catalog_path, 2, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_source_edges);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.dangling_target_edges);

    const data = try Io.Dir.cwd().readFileAlloc(io_arg, result.resolved_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, resolved_record_size), data.len);
    try expectResolved(data, 0, 0, 1);
}

// An empty `edges.raw` must produce an empty `edges.resolved` with no
// diagnostics and no errors.
test "empty edges produce empty resolved file" {
    const allocator = std.testing.allocator;
    const io_arg = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io_arg, ".", allocator);
    defer allocator.free(tmp_path);

    const rows = &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
    };

    const edges = &[_]EdgeEmitter.EdgeRecord{};

    const files = try createSyntheticFiles(allocator, io_arg, tmp_path, rows, edges);
    defer allocator.free(files.catalog_path);
    defer allocator.free(files.edges_path);

    var job = try createTestJob(allocator, io_arg, tmp_path);
    defer job.deinit(allocator);


    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io_arg, &job, files.edges_path, files.catalog_path, 1, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 0), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_source_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_target_edges);

    const data = try Io.Dir.cwd().readFileAlloc(io_arg, result.resolved_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, 0), data.len);
}

// Multiple edges sharing the same source must be resolved without advancing
// the catalog cursor past the matching row.
test "multiple edges from same source" {
    const allocator = std.testing.allocator;
    const io_arg = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io_arg, ".", allocator);
    defer allocator.free(tmp_path);

    const rows = &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
        .{ .raw_id = 0x3000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 0, .kind = .instance },
    };

    const edges = &[_]EdgeEmitter.EdgeRecord{
        .{ .source_raw_id = 0x1000, .target_raw_id = 0x2000 },
        .{ .source_raw_id = 0x1000, .target_raw_id = 0x3000 },
        .{ .source_raw_id = 0x2000, .target_raw_id = 0x3000 },
    };

    const files = try createSyntheticFiles(allocator, io_arg, tmp_path, rows, edges);
    defer allocator.free(files.catalog_path);
    defer allocator.free(files.edges_path);

    var job = try createTestJob(allocator, io_arg, tmp_path);
    defer job.deinit(allocator);


    var diagnostics: Manifest.Diagnostics = .{};
    var result = try run(allocator, io_arg, &job, files.edges_path, files.catalog_path, 3, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 3), result.n_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_source_edges);
    try std.testing.expectEqual(@as(u64, 0), diagnostics.dangling_target_edges);

    const data = try Io.Dir.cwd().readFileAlloc(io_arg, result.resolved_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, 3 * resolved_record_size), data.len);

    // Sorted by target raw ID: (0x1000->0x2000), (0x1000->0x3000), (0x2000->0x3000)
    try expectResolved(data, 0, 0, 1);
    try expectResolved(data, 1, 0, 2);
    try expectResolved(data, 2, 1, 2);
}

// End-to-end integration test: run Stages 1–5 on every fixture and assert
// that at least some edges are resolved.
test "fixtures produce resolved edges" {
    const allocator = std.testing.allocator;
    const io_arg = std.testing.io;

    const fixtures = .{
        "test_hprofs/heapforge.hprof",
        "test_hprofs/heapforge_classloaders.hprof",
        "test_hprofs/heapforge_threads.hprof",
    };

    inline for (fixtures) |fixture_path| {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        const tmp_path = try tmp_dir.dir.realPathFileAlloc(io_arg, ".", allocator);
        defer allocator.free(tmp_path);

        const source_data = try Io.Dir.cwd().readFileAlloc(io_arg, fixture_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source_data);


        var job = try createTestJobFromSource(allocator, io_arg, source_data, tmp_path);
        defer job.deinit(allocator);

        var scan_result = try Scanner.run(allocator, io_arg, &job, source_data, null);
        defer scan_result.deinit(allocator);

        var sort_diagnostics: Manifest.Diagnostics = .{};
        var catalog_result = try CatalogSorter.sortAndDedupe(allocator, io_arg, &job, scan_result.catalog_path, &sort_diagnostics);
        defer catalog_result.deinit(allocator);

        const classes_path = try CatalogSorter.writeClasses(allocator, io_arg, job.staging_dir, &scan_result.class_table);
        defer allocator.free(classes_path);

        var layout_diagnostics: Manifest.Diagnostics = .{};
        var layout_table = try Layouts.writeFields(
            allocator,
            io_arg,
            job.staging_dir,
            &scan_result.class_table,
            job.header.id_size,
            &layout_diagnostics,
        );
        defer layout_table.deinit();

        var edge_diagnostics: Manifest.Diagnostics = .{};
        var edge_result = try EdgeEmitter.run(allocator, io_arg, &job, source_data, &layout_table, &edge_diagnostics);
        defer edge_result.deinit(allocator);

        var join_diagnostics: Manifest.Diagnostics = .{};
        var join_result = try run(allocator, io_arg, &job, edge_result.edges_path, catalog_result.catalog_path, catalog_result.n_objects, &join_diagnostics);
        defer join_result.deinit(allocator);

        try std.testing.expect(join_result.n_edges > 0);
    }
}

/// Build a `Preflight.Job` from real HPROF bytes. Extracts the header and
/// computes the fingerprint so that the full pipeline can run on a fixture.
fn createTestJobFromSource(
    allocator: std.mem.Allocator,
    io_arg: Io,
    source_data: []const u8,
    tmp_dir: []const u8,
) !Preflight.Job {
    const header = try hprof.Header.parse(source_data);
    const fingerprint = try Manifest.computeFingerprint(allocator, source_data, header, 0);
    errdefer fingerprint.deinit(allocator);

    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "staging" });
    errdefer allocator.free(staging_dir);
    try Io.Dir.cwd().createDirPath(io_arg, staging_dir);

    return .{
        .source_path = "test.hprof",
        .index_dir = tmp_dir,
        .staging_dir = staging_dir,

        .budget_bytes = 1024 * 1024,
        .fingerprint = fingerprint,
        .header = header,
    };
}

const Layouts = @import("Layouts.zig");
