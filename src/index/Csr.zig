//! Stage 6: convert resolved ordinal edges into compressed sparse row (CSR)
//! files and resolve GC root targets to ordinals.
//!
//! After Stage 5 the heap graph is a flat list of `(source_ordinal,
//! target_ordinal)` edges. This module builds two CSR views of that graph:
//!
//!   1. Forward CSR (`out_offsets.bin` + `out_targets.bin`) — for each vertex,
//!      the vertices it points to.
//!   2. Reverse CSR (`in_offsets.bin` + `in_sources.bin`) — for each vertex,
//!      the vertices that point to it.
//!
//! It also resolves the raw GC root records from Stage 1 (`roots.raw`) to
//! catalog ordinals and writes `roots.bin`.
//!
//! The CSR construction is streaming: edges are sorted externally and then
//! scanned once per view. No full edge list is materialized in memory.
const std = @import("std");
const Io = std.Io;
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const CatalogSorter = @import("CatalogSorter.zig");
const Scanner = @import("Scanner.zig");
const Join = @import("Join.zig");
const EdgeEmitter = @import("EdgeEmitter.zig");
const ExtSort = @import("ExtSort.zig");

/// Size in bytes of one CSR offset entry: a little-endian `u64`.
pub const offset_entry_size = 8;

/// Size in bytes of one resolved root record in `roots.bin`:
/// `target_ordinal u32` + `root_kind u8` + 3 padding bytes + `thread_serial u32`.
pub const roots_bin_record_size = 12;

/// Result of Stage 6. Holds the paths to the four CSR files and the resolved
/// roots file, plus the number of roots that were successfully resolved.
pub const Result = struct {
    /// Path to the forward CSR offsets file.
    out_offsets_path: []const u8,
    /// Path to the forward CSR adjacency file.
    out_targets_path: []const u8,
    /// Path to the reverse CSR offsets file.
    in_offsets_path: []const u8,
    /// Path to the reverse CSR adjacency file.
    in_sources_path: []const u8,
    /// Path to the resolved roots file.
    roots_path: []const u8,
    /// Number of roots whose target raw ID was found in the catalog.
    n_roots: u64,

    /// Free all allocated paths. The output files themselves are left in the
    /// staging directory for later stages.
    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.out_offsets_path);
        allocator.free(self.out_targets_path);
        allocator.free(self.in_offsets_path);
        allocator.free(self.in_sources_path);
        allocator.free(self.roots_path);
    }
};

/// Errors specific to the Stage 6 CSR writer pipeline.
pub const Error = error{
    /// `edges.resolved` (or an intermediate sorted edge file) has a length that
    /// is not a multiple of `Join.resolved_record_size`.
    InvalidResolvedEdgeFile,
    /// `roots.raw` has a length that is not a multiple of
    /// `Scanner.root_record_size`.
    InvalidRootFile,
    /// `catalog.bin` has a length that is not a multiple of
    /// `CatalogSorter.catalog_row_size`.
    InvalidCatalogFile,
};

/// Comparator used to sort resolved edges by `(source, target)` for the
/// forward CSR. Primary sort key is `source_ordinal` (bytes `[0..4)`);
/// secondary sort key is `target_ordinal` (bytes `[4..8)`).
fn lessBySource(_: void, a: []const u8, b: []const u8) bool {
    const a_s = std.mem.readInt(u32, a[0..4], .little);
    const b_s = std.mem.readInt(u32, b[0..4], .little);
    if (a_s != b_s) return a_s < b_s;
    const a_t = std.mem.readInt(u32, a[4..8], .little);
    const b_t = std.mem.readInt(u32, b[4..8], .little);
    return a_t < b_t;
}

/// One resolved edge decoded into host-endian `u32` ordinals.
const EdgePair = struct { source: u32, target: u32 };

/// Deserialize an 8-byte resolved edge record from a fixed-size buffer.
fn readResolvedEdge(buf: *const [Join.resolved_record_size]u8) EdgePair {
    return .{
        .source = std.mem.readInt(u32, buf[0..4], .little),
        .target = std.mem.readInt(u32, buf[4..8], .little),
    };
}

/// Extract the primary sort key for the forward CSR (the source ordinal).
fn sourceKey(edge: EdgePair) u32 {
    return edge.source;
}

/// Extract the primary sort key for the reverse CSR (the target ordinal).
fn targetKey(edge: EdgePair) u32 {
    return edge.target;
}

/// Function type used by `writeCsrWithExtractor` to select the primary and
/// secondary sort keys.
const KeyExtractor = fn (EdgePair) u32;

/// Write one CSR view from a sorted edge file.
///
/// `sorted_path` must contain 8-byte resolved edge records sorted by
/// `(primary_key(edge), secondary_key(edge))`. The function writes:
///
///   * `offsets_path`: `(n_nodes + 1)` `u64` offsets in little-endian.
///   * `adj_path`: `n_edges` `u32` neighbor ordinals in little-endian.
///
/// For the forward view call with `primary_key = sourceKey` and
/// `secondary_key = targetKey`. For the reverse view call with
/// `primary_key = targetKey` and `secondary_key = sourceKey`.
///
/// The function validates that the input is sorted, that every ordinal is in
/// range, and that every edge is consumed exactly once. `expected_edges` must
/// match the number of edges in `sorted_path`; otherwise an error is returned.
fn writeCsrWithExtractor(
    io: Io,
    sorted_path: []const u8,
    offsets_path: []const u8,
    adj_path: []const u8,
    n_nodes: u64,
    expected_edges: u64,
    comptime primary_key: KeyExtractor,
    comptime secondary_key: KeyExtractor,
) !void {
    const dir = Io.Dir.cwd();

    // Open and validate the sorted edge file.
    var sorted_file = try dir.openFile(io, sorted_path, .{});
    defer sorted_file.close(io);
    const sorted_len = try sorted_file.length(io);
    if (sorted_len % Join.resolved_record_size != 0) return error.InvalidResolvedEdgeFile;

    const n_edges = sorted_len / Join.resolved_record_size;
    if (n_edges != expected_edges) return error.InvalidResolvedEdgeFile;

    // Prepare the offsets output file with a small stack buffer.
    var offsets_file = try dir.createFile(io, offsets_path, .{});
    defer offsets_file.close(io);
    var offsets_buf: [8192]u8 = undefined;
    var offsets_writer: Io.File.Writer = .init(offsets_file, io, &offsets_buf);
    const offsets_out = &offsets_writer.interface;

    // Prepare the adjacency output file with a larger stack buffer.
    var adj_file = try dir.createFile(io, adj_path, .{});
    defer adj_file.close(io);
    var adj_buf: [65536]u8 = undefined;
    var adj_writer: Io.File.Writer = .init(adj_file, io, &adj_buf);
    const adj_out = &adj_writer.interface;

    // Empty edge list: every offset is zero and the adjacency file is empty.
    if (n_edges == 0) {
        var node: u64 = 0;
        const zero_offset: [offset_entry_size]u8 = .{0} ** offset_entry_size;
        while (node <= n_nodes) : (node += 1) {
            try offsets_out.writeAll(&zero_offset);
        }
        try offsets_writer.flush();
        try adj_writer.flush();
        return;
    }

    // Memory-map the sorted edge file for sequential read access.
    var sorted_mm = try Io.File.MemoryMap.create(io, sorted_file, .{
        .len = sorted_len,
        .protection = .{ .read = true, .write = false },
    });
    defer sorted_mm.destroy(io);

    var edge_idx: usize = 0;
    var next_offset: u64 = 0;
    var last_primary: ?u32 = null;

    // Iterate over all nodes including the sentinel at n_nodes.
    var node: u64 = 0;
    while (node <= n_nodes) : (node += 1) {
        var offset_bytes: [offset_entry_size]u8 = undefined;
        std.mem.writeInt(u64, &offset_bytes, next_offset, .little);
        try offsets_out.writeAll(&offset_bytes);

        // Consume all edges whose primary key equals the current node.
        while (edge_idx < n_edges) {
            const edge = readResolvedEdge(
                sorted_mm.memory[edge_idx * Join.resolved_record_size ..][0..Join.resolved_record_size],
            );
            const p = primary_key(edge);
            if (p < node) {
                // Sorted input violated; a record for this primary key should
                // have been consumed already.
                return error.InvalidResolvedEdgeFile;
            }
            if (p != node) break;
            if (p > n_nodes - 1) return error.InvalidResolvedEdgeFile;
            if (last_primary) |lp| {
                if (p < lp) return error.InvalidResolvedEdgeFile;
            }
            last_primary = p;

            const s = secondary_key(edge);
            if (s > n_nodes - 1) return error.InvalidResolvedEdgeFile;

            var adj_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &adj_bytes, s, .little);
            try adj_out.writeAll(&adj_bytes);

            edge_idx += 1;
            next_offset += 1;
        }
    }

    try offsets_writer.flush();
    try adj_writer.flush();

    // All edges must have been consumed exactly once.
    if (edge_idx != n_edges) return error.InvalidResolvedEdgeFile;
    if (next_offset != n_edges) return error.InvalidResolvedEdgeFile;
}

/// Serialize one resolved root record into `writer`.
/// Layout: `target_ordinal` (little-endian u32), `root_kind` (u8), 3 zero
/// padding bytes, `thread_serial` (little-endian u32).
pub fn writeRootRecord(writer: *Io.Writer, rec: struct { target_ordinal: u32, root_kind: u8, thread_serial: u32 }) !void {
    var buf: [roots_bin_record_size]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], rec.target_ordinal, .little);
    buf[4] = rec.root_kind;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    std.mem.writeInt(u32, buf[8..12], rec.thread_serial, .little);
    try writer.writeAll(&buf);
}

/// Deserialize one resolved root record from a fixed-size buffer.
pub fn readRootRecord(buf: *const [roots_bin_record_size]u8) struct { target_ordinal: u32, root_kind: u8, thread_serial: u32 } {
    return .{
        .target_ordinal = std.mem.readInt(u32, buf[0..4], .little),
        .root_kind = buf[4],
        .thread_serial = std.mem.readInt(u32, buf[8..12], .little),
    };
}

/// Stage 6 entry point: build the forward and reverse CSR files plus the
/// resolved `roots.bin`.
///
/// `n_objects` is the number of unique rows in the catalog; node ordinals are
/// `0..n_objects` with `n_objects` reserved for the virtual root. All
/// `n_edges` from `resolved_path` must be accounted for in the output CSR
/// files.
///
/// The function:
///   1. Sorts `edges.resolved` by source and writes the forward CSR.
///   2. Writes the reverse CSR from `edges.resolved`, which is already sorted
///      by target ordinal after Stage 5.
///   3. Resolves each GC root in `roots.raw` to a catalog ordinal and writes
///      `roots.bin`.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    resolved_path: []const u8,
    roots_raw_path: []const u8,
    catalog_path: []const u8,
    n_objects: u64,
    n_edges: u64,
    n_roots: u64,
    diagnostics: *Manifest.Diagnostics,
) !Result {
    // Guard against overflow: n_nodes = n_objects + 1 must fit in a u32 and
    // leave room for the sentinel offset.
    if (n_objects + 1 > std.math.maxInt(u32) - 1) return error.InvalidResolvedEdgeFile;
    const n_nodes = n_objects + 1; // includes virtual root

    // Build output paths in the staging directory.
    const out_offsets_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "out_offsets.bin" });
    errdefer allocator.free(out_offsets_path);
    const out_targets_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "out_targets.bin" });
    errdefer allocator.free(out_targets_path);
    const in_offsets_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "in_offsets.bin" });
    errdefer allocator.free(in_offsets_path);
    const in_sources_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "in_sources.bin" });
    errdefer allocator.free(in_sources_path);
    const roots_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "roots.bin" });
    errdefer allocator.free(roots_path);

    // Sort edges by source ordinal and write the forward CSR.
    const sorted_by_source = try std.fs.path.join(allocator, &.{ job.staging_dir, "edges.resolved.by_source" });
    defer allocator.free(sorted_by_source);

    try ExtSort.sortStreaming(io, allocator, resolved_path, sorted_by_source, .{
        .record_size = Join.resolved_record_size,
        .budget_bytes = job.budget_bytes,
    }, null, {}, lessBySource);

    try writeCsrWithExtractor(
        io,
        sorted_by_source,
        out_offsets_path,
        out_targets_path,
        n_nodes,
        n_edges,
        sourceKey,
        targetKey,
    );

    // `edges.resolved` is already sorted by target ordinal after Stage 5's
    // second merge-join pass, so the reverse CSR can be written directly
    // without another external sort.
    try writeCsrWithExtractor(
        io,
        resolved_path,
        in_offsets_path,
        in_sources_path,
        n_nodes,
        n_edges,
        targetKey,
        sourceKey,
    );

    // Resolve GC root targets to ordinals.
    const n_roots_resolved = try resolveRoots(
        io,
        roots_raw_path,
        catalog_path,
        roots_path,
        n_objects,
        n_roots,
        diagnostics,
    );

    return .{
        .out_offsets_path = out_offsets_path,
        .out_targets_path = out_targets_path,
        .in_offsets_path = in_offsets_path,
        .in_sources_path = in_sources_path,
        .roots_path = roots_path,
        .n_roots = n_roots_resolved,
    };
}

/// Resolve raw GC root records to catalog ordinals.
///
/// Streams through `roots_raw_path`, looks up each `target_raw_id` in the
/// sorted `catalog.bin` via binary search, and writes the resolved record to
/// `roots_path`. Roots whose target is not in the catalog are dropped and
/// counted in `diagnostics.dangling_root_targets`.
///
/// Returns the number of roots that were successfully resolved.
fn resolveRoots(
    io: Io,
    roots_raw_path: []const u8,
    catalog_path: []const u8,
    roots_path: []const u8,
    n_objects: u64,
    n_roots: u64,
    diagnostics: *Manifest.Diagnostics,
) !u64 {
    const dir = Io.Dir.cwd();

    // Prepare the resolved roots output file.
    var roots_bin_file = try dir.createFile(io, roots_path, .{});
    defer roots_bin_file.close(io);
    var roots_buf: [65536]u8 = undefined;
    var roots_writer: Io.File.Writer = .init(roots_bin_file, io, &roots_buf);
    const roots_out = &roots_writer.interface;

    // No roots: produce an empty file.
    if (n_roots == 0) {
        try roots_writer.flush();
        diagnostics.dangling_root_targets = 0;
        return 0;
    }

    // Open and validate the raw roots file.
    var roots_raw_file = try dir.openFile(io, roots_raw_path, .{});
    defer roots_raw_file.close(io);
    const roots_raw_len = try roots_raw_file.length(io);
    if (roots_raw_len % Scanner.root_record_size != 0) return error.InvalidRootFile;
    const n_roots_raw = roots_raw_len / Scanner.root_record_size;
    if (n_roots_raw != n_roots) return error.InvalidRootFile;

    // Memory-map the raw roots file read-only.
    var roots_raw_mm = try Io.File.MemoryMap.create(io, roots_raw_file, .{
        .len = roots_raw_len,
        .protection = .{ .read = true, .write = false },
    });
    defer roots_raw_mm.destroy(io);
    const roots_raw_data = roots_raw_mm.memory;

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

    var dangling: u64 = 0;
    var resolved: u64 = 0;

    // Stream through raw roots and resolve each target raw ID.
    var i: usize = 0;
    while (i < n_roots_raw) : (i += 1) {
        const raw = Scanner.readRootRecord(
            roots_raw_data[i * Scanner.root_record_size ..][0..Scanner.root_record_size],
        );
        const ordinal = CatalogSorter.ordinalForRawId(catalog_data, raw.target_raw_id);
        if (ordinal) |ord| {
            // Catalog ordinals are always 0..n_objects-1 for real objects.
            if (ord >= n_objects) {
                dangling += 1;
                continue;
            }
            try writeRootRecord(roots_out, .{
                .target_ordinal = ord,
                .root_kind = raw.root_kind,
                .thread_serial = raw.thread_serial,
            });
            resolved += 1;
        } else {
            dangling += 1;
        }
    }

    try roots_writer.flush();

    diagnostics.dangling_root_targets = dangling;
    return resolved;
}

// ─────────────────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Create a synthetic `edges.resolved` file from in-memory records. Returns
/// the path to the file; caller must free it.
fn createSyntheticResolvedFile(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_dir: []const u8,
    edges: []const Join.ResolvedRecord,
) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ tmp_dir, "edges.resolved" });
    errdefer allocator.free(path);

    const dir = Io.Dir.cwd();
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buf);
    for (edges) |edge| {
        try Join.writeResolvedRecord(&writer.interface, edge);
    }
    try writer.flush();
    return path;
}

/// Create a synthetic `catalog.bin` file containing the given raw IDs in
/// ascending order. Returns the path; caller must free it.
fn createSyntheticCatalog(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_dir: []const u8,
    raw_ids: []const u64,
) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ tmp_dir, "catalog.bin" });
    errdefer allocator.free(path);

    const dir = Io.Dir.cwd();
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buf);
    for (raw_ids) |id| {
        try Scanner.writeCatalogRow(&writer.interface, .{
            .raw_id = id,
            .source_offset = 0,
            .class_raw_id = 0,
            .shallow_size = 0,
            .kind = .instance,
        });
    }
    try writer.flush();
    return path;
}

/// Create a synthetic `roots.raw` file from in-memory root records. Returns
/// the path; caller must free it.
fn createSyntheticRootsRaw(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_dir: []const u8,
    roots: []const Scanner.RootRecord,
) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ tmp_dir, "roots.raw" });
    errdefer allocator.free(path);

    const dir = Io.Dir.cwd();
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buf);
    for (roots) |root| {
        try Scanner.writeRootRecord(&writer.interface, root);
    }
    try writer.flush();
    return path;
}

/// Read an entire CSR offsets file into a newly allocated `[]u64`. Caller
/// must free the returned slice.
fn readOffsets(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]const u64 {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);
    if (data.len % offset_entry_size != 0) return error.InvalidResolvedEdgeFile;
    const n = data.len / offset_entry_size;
    const result = try allocator.alloc(u64, n);
    errdefer allocator.free(result);
    for (0..n) |i| {
        result[i] = std.mem.readInt(u64, data[i * offset_entry_size ..][0..offset_entry_size], .little);
    }
    return result;
}

/// Read an entire CSR adjacency file into a newly allocated `[]u32`. Caller
/// must free the returned slice.
fn readAdjacency(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]const u32 {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);
    if (data.len % 4 != 0) return error.InvalidResolvedEdgeFile;
    const n = data.len / 4;
    const result = try allocator.alloc(u32, n);
    errdefer allocator.free(result);
    for (0..n) |i| {
        result[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    }
    return result;
}

/// Build a synthetic `Preflight.Job` for unit tests.
fn createTestJob(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8) !Preflight.Job {
    const header: hprof.Header.Header = .{ .id_size = 8, .timestamp = 0 };
    const fingerprint = try Manifest.computeFingerprint(allocator, "", header, 0);
    errdefer fingerprint.deinit(allocator);

    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "staging" });
    errdefer allocator.free(staging_dir);
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

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

// Validate forward and reverse CSR for a simple 3-node graph.
test "CSR invariants for simple graph" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    // 2 real objects + virtual root = 3 nodes.
    const edges = &[_]Join.ResolvedRecord{
        .{ .source_ordinal = 0, .target_ordinal = 1 },
        .{ .source_ordinal = 0, .target_ordinal = 2 },
        .{ .source_ordinal = 1, .target_ordinal = 2 },
    };
    const resolved_path = try createSyntheticResolvedFile(allocator, io, job.staging_dir, edges);
    defer allocator.free(resolved_path);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try run(
        allocator,
        io,
        &job,
        resolved_path,
        resolved_path, // dummy roots path, not used in this test
        resolved_path, // dummy catalog path, not used in this test
        2,
        edges.len,
        0,
        &diagnostics,
    );
    defer result.deinit(allocator);

    const out_offsets = try readOffsets(allocator, io, result.out_offsets_path);
    defer allocator.free(out_offsets);
    const out_targets = try readAdjacency(allocator, io, result.out_targets_path);
    defer allocator.free(out_targets);
    const in_offsets = try readOffsets(allocator, io, result.in_offsets_path);
    defer allocator.free(in_offsets);
    const in_sources = try readAdjacency(allocator, io, result.in_sources_path);
    defer allocator.free(in_sources);

    try std.testing.expectEqual(@as(usize, 4), out_offsets.len);
    try std.testing.expectEqual(@as(u64, 0), out_offsets[0]);
    try std.testing.expectEqual(@as(u64, 2), out_offsets[1]);
    try std.testing.expectEqual(@as(u64, 3), out_offsets[2]);
    try std.testing.expectEqual(@as(u64, 3), out_offsets[3]);

    try std.testing.expectEqual(@as(usize, 3), out_targets.len);
    try std.testing.expectEqual(@as(u32, 1), out_targets[0]);
    try std.testing.expectEqual(@as(u32, 2), out_targets[1]);
    try std.testing.expectEqual(@as(u32, 2), out_targets[2]);

    try std.testing.expectEqual(@as(usize, 4), in_offsets.len);
    try std.testing.expectEqual(@as(u64, 0), in_offsets[0]); // node 0 has no incoming
    try std.testing.expectEqual(@as(u64, 0), in_offsets[1]); // node 1 has one incoming
    try std.testing.expectEqual(@as(u64, 1), in_offsets[2]); // node 2 has two incoming
    try std.testing.expectEqual(@as(u64, 3), in_offsets[3]); // sentinel

    try std.testing.expectEqual(@as(usize, 3), in_sources.len);
    try std.testing.expectEqual(@as(u32, 0), in_sources[0]);
    try std.testing.expectEqual(@as(u32, 0), in_sources[1]);
    try std.testing.expectEqual(@as(u32, 1), in_sources[2]);
}

// An empty edge list must produce zero offsets and empty adjacency files.
test "CSR with empty edges writes zero offsets and empty adjacency" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    const edges = &[_]Join.ResolvedRecord{};
    const resolved_path = try createSyntheticResolvedFile(allocator, io, job.staging_dir, edges);
    defer allocator.free(resolved_path);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try run(
        allocator,
        io,
        &job,
        resolved_path,
        resolved_path,
        resolved_path,
        2,
        0,
        0,
        &diagnostics,
    );
    defer result.deinit(allocator);

    const out_offsets = try readOffsets(allocator, io, result.out_offsets_path);
    defer allocator.free(out_offsets);
    const out_targets = try readAdjacency(allocator, io, result.out_targets_path);
    defer allocator.free(out_targets);

    try std.testing.expectEqual(@as(usize, 4), out_offsets.len);
    for (out_offsets) |off| {
        try std.testing.expectEqual(@as(u64, 0), off);
    }
    try std.testing.expectEqual(@as(usize, 0), out_targets.len);
}

// Edges sourced from the virtual root must be stored in the forward CSR.
test "CSR with virtual root edges" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    // 2 real objects, virtual root ordinal = 2.
    const edges = &[_]Join.ResolvedRecord{
        .{ .source_ordinal = 2, .target_ordinal = 0 },
        .{ .source_ordinal = 2, .target_ordinal = 1 },
    };
    const resolved_path = try createSyntheticResolvedFile(allocator, io, job.staging_dir, edges);
    defer allocator.free(resolved_path);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try run(
        allocator,
        io,
        &job,
        resolved_path,
        resolved_path,
        resolved_path,
        2,
        edges.len,
        0,
        &diagnostics,
    );
    defer result.deinit(allocator);

    const out_offsets = try readOffsets(allocator, io, result.out_offsets_path);
    defer allocator.free(out_offsets);
    const out_targets = try readAdjacency(allocator, io, result.out_targets_path);
    defer allocator.free(out_targets);

    try std.testing.expectEqual(@as(usize, 4), out_offsets.len);
    try std.testing.expectEqual(@as(u64, 0), out_offsets[0]); // node 0
    try std.testing.expectEqual(@as(u64, 0), out_offsets[1]); // node 1
    try std.testing.expectEqual(@as(u64, 0), out_offsets[2]); // virtual root (starts at offset 0)
    try std.testing.expectEqual(@as(u64, 2), out_offsets[3]); // sentinel

    try std.testing.expectEqual(@as(usize, 2), out_targets.len);
    try std.testing.expectEqual(@as(u32, 0), out_targets[0]);
    try std.testing.expectEqual(@as(u32, 1), out_targets[1]);
}

// Resolvable roots become ordinal records; dangling roots are counted.
test "roots resolved and dangling targets counted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    const edges = &[_]Join.ResolvedRecord{};
    const resolved_path = try createSyntheticResolvedFile(allocator, io, job.staging_dir, edges);
    defer allocator.free(resolved_path);

    const catalog_path = try createSyntheticCatalog(allocator, io, job.staging_dir, &[_]u64{ 0x1000, 0x2000 });
    defer allocator.free(catalog_path);

    const roots = &[_]Scanner.RootRecord{
        .{ .target_raw_id = 0x2000, .root_kind = 0x01, .thread_serial = 7 },
        .{ .target_raw_id = 0xdeadbeef, .root_kind = 0x02, .thread_serial = 0 },
    };
    const roots_raw_path = try createSyntheticRootsRaw(allocator, io, job.staging_dir, roots);
    defer allocator.free(roots_raw_path);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try run(
        allocator,
        io,
        &job,
        resolved_path,
        roots_raw_path,
        catalog_path,
        2,
        0,
        roots.len,
        &diagnostics,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.n_roots);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.dangling_root_targets);

    const data = try Io.Dir.cwd().readFileAlloc(io, result.roots_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, roots_bin_record_size), data.len);
    const rec = readRootRecord(data[0..roots_bin_record_size]);
    try std.testing.expectEqual(@as(u32, 1), rec.target_ordinal);
    try std.testing.expectEqual(@as(u8, 0x01), rec.root_kind);
    try std.testing.expectEqual(@as(u32, 7), rec.thread_serial);
}

// Forward and reverse CSR must represent the same multiset of edges.
test "CSR forward and reverse multisets are mirror images" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    // 5 real objects, virtual root = 5.
    // Edges must be sorted by target ordinal because the reverse CSR is built
    // directly from `edges.resolved` without re-sorting.
    const edges = &[_]Join.ResolvedRecord{
        .{ .source_ordinal = 5, .target_ordinal = 0 },
        .{ .source_ordinal = 0, .target_ordinal = 1 },
        .{ .source_ordinal = 0, .target_ordinal = 2 },
        .{ .source_ordinal = 0, .target_ordinal = 2 }, // duplicate
        .{ .source_ordinal = 3, .target_ordinal = 4 },
    };
    const resolved_path = try createSyntheticResolvedFile(allocator, io, job.staging_dir, edges);
    defer allocator.free(resolved_path);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try run(
        allocator,
        io,
        &job,
        resolved_path,
        resolved_path,
        resolved_path,
        5,
        edges.len,
        0,
        &diagnostics,
    );
    defer result.deinit(allocator);

    const out_offsets = try readOffsets(allocator, io, result.out_offsets_path);
    defer allocator.free(out_offsets);
    const out_targets = try readAdjacency(allocator, io, result.out_targets_path);
    defer allocator.free(out_targets);
    const in_offsets = try readOffsets(allocator, io, result.in_offsets_path);
    defer allocator.free(in_offsets);
    const in_sources = try readAdjacency(allocator, io, result.in_sources_path);
    defer allocator.free(in_sources);

    try std.testing.expectEqual(out_offsets[out_offsets.len - 1], out_targets.len);
    try std.testing.expectEqual(in_offsets[in_offsets.len - 1], in_sources.len);
    try std.testing.expectEqual(out_targets.len, in_sources.len);

    var expected_out = std.AutoHashMap(u64, u64).init(allocator);
    defer expected_out.deinit();
    var expected_in = std.AutoHashMap(u64, u64).init(allocator);
    defer expected_in.deinit();

    for (edges) |edge| {
        const out_key = (@as(u64, edge.source_ordinal) << 32) | edge.target_ordinal;
        const entry = try expected_out.getOrPut(out_key);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;

        const in_key = (@as(u64, edge.target_ordinal) << 32) | edge.source_ordinal;
        const in_entry = try expected_in.getOrPut(in_key);
        if (!in_entry.found_existing) in_entry.value_ptr.* = 0;
        in_entry.value_ptr.* += 1;
    }

    var actual_out = std.AutoHashMap(u64, u64).init(allocator);
    defer actual_out.deinit();
    var i: usize = 0;
    while (i < out_offsets.len - 1) : (i += 1) {
        const start = out_offsets[i];
        const end = out_offsets[i + 1];
        var j: usize = @intCast(start);
        while (j < end) : (j += 1) {
            const key = (@as(u64, @intCast(i)) << 32) | out_targets[j];
            const entry = try actual_out.getOrPut(key);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }

    var actual_in = std.AutoHashMap(u64, u64).init(allocator);
    defer actual_in.deinit();
    i = 0;
    while (i < in_offsets.len - 1) : (i += 1) {
        const start = in_offsets[i];
        const end = in_offsets[i + 1];
        var j: usize = @intCast(start);
        while (j < end) : (j += 1) {
            const key = (@as(u64, @intCast(i)) << 32) | in_sources[j];
            const entry = try actual_in.getOrPut(key);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }

    try std.testing.expectEqual(expected_out.count(), actual_out.count());
    var it = expected_out.iterator();
    while (it.next()) |kv| {
        const actual = actual_out.get(kv.key_ptr.*) orelse 0;
        try std.testing.expectEqual(kv.value_ptr.*, actual);
    }

    try std.testing.expectEqual(expected_in.count(), actual_in.count());
    var in_it = expected_in.iterator();
    while (in_it.next()) |kv| {
        const actual = actual_in.get(kv.key_ptr.*) orelse 0;
        try std.testing.expectEqual(kv.value_ptr.*, actual);
    }
}

// End-to-end integration test: run Stages 1–6 on every fixture and assert
// structural CSR invariants.
test "fixture end-to-end produces consistent CSR" {
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
        const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path);

        const source_data = try Io.Dir.cwd().readFileAlloc(io, fixture_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source_data);

        var job = try createTestJobFromSource(allocator, io, source_data, tmp_path);
        defer job.deinit(allocator);

        var scan_result = try Scanner.run(allocator, io, &job, source_data, null);
        defer scan_result.deinit(allocator);

        var sort_diagnostics: Manifest.Diagnostics = .{};
        var catalog_result = try CatalogSorter.sortAndDedupe(allocator, io, &job, scan_result.catalog_path, &sort_diagnostics);
        defer catalog_result.deinit(allocator);

        const classes_path = try CatalogSorter.writeClasses(allocator, io, job.staging_dir, &scan_result.class_table);
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
        defer layout_table.deinit();

        var edge_diagnostics: Manifest.Diagnostics = .{};
        var edge_result = try EdgeEmitter.run(allocator, io, &job, source_data, &layout_table, &edge_diagnostics);
        defer edge_result.deinit(allocator);

        var join_diagnostics: Manifest.Diagnostics = .{};
        var join_result = try Join.run(allocator, io, &job, edge_result.edges_path, catalog_result.catalog_path, catalog_result.n_objects, &join_diagnostics);
        defer join_result.deinit(allocator);

        var csr_diagnostics: Manifest.Diagnostics = .{};
        var csr_result = try run(
            allocator,
            io,
            &job,
            join_result.resolved_path,
            scan_result.roots_path,
            catalog_result.catalog_path,
            catalog_result.n_objects,
            join_result.n_edges,
            scan_result.n_roots,
            &csr_diagnostics,
        );
        defer csr_result.deinit(allocator);

        const out_offsets = try readOffsets(allocator, io, csr_result.out_offsets_path);
        defer allocator.free(out_offsets);
        const out_targets = try readAdjacency(allocator, io, csr_result.out_targets_path);
        defer allocator.free(out_targets);
        const in_offsets = try readOffsets(allocator, io, csr_result.in_offsets_path);
        defer allocator.free(in_offsets);
        const in_sources = try readAdjacency(allocator, io, csr_result.in_sources_path);
        defer allocator.free(in_sources);

        try std.testing.expectEqual(out_offsets.len, catalog_result.n_objects + 2);
        try std.testing.expectEqual(in_offsets.len, catalog_result.n_objects + 2);
        try std.testing.expectEqual(out_offsets[out_offsets.len - 1], join_result.n_edges);
        try std.testing.expectEqual(in_offsets[in_offsets.len - 1], join_result.n_edges);
        try std.testing.expectEqual(out_targets.len, in_sources.len);
    }
}

/// Build a `Preflight.Job` from real HPROF bytes. Extracts the header and
/// computes the fingerprint so that the full pipeline can run on a fixture.
fn createTestJobFromSource(
    allocator: std.mem.Allocator,
    io: Io,
    source_data: []const u8,
    tmp_dir: []const u8,
) !Preflight.Job {
    const header = try hprof.Header.parse(source_data);
    const fingerprint = try Manifest.computeFingerprint(allocator, source_data, header, 0);
    errdefer fingerprint.deinit(allocator);

    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "staging" });
    errdefer allocator.free(staging_dir);
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

const hprof = @import("../hprof.zig");
const Layouts = @import("Layouts.zig");
