//! Stage 8: validate structural invariants of the staged index before publication.
//!
//! After Stages 1–7 have produced the staged index files, this module runs a
//! battery of checks to ensure the files are internally consistent and match
//! the expected pipeline counts. If any check fails, publication is aborted
//! and the staging directory is left intact for diagnosis.
//!
//! The checks cover:
//!   1. All expected staged files exist and are readable.
//!   2. `catalog.bin` is sorted, unique, and contains the expected row/class counts.
//!   3. `classes.bin` is sorted and parseable.
//!   4. `fields.bin` is parseable and its class count matches.
//!   5. CSR offset files are monotone, start at 0, and end at `n_edges`.
//!   6. CSR adjacency files contain exactly `n_edges` in-range ordinals.
//!   7. `roots.bin` contains exactly `n_roots` in-range ordinals.
//!
//! Validation is streaming: each file is memory-mapped or treated as empty and
//! scanned sequentially. No index file is loaded into the heap in its entirety,
//! so validation honors the same sorting-budget contract as the rest of the
//! pipeline.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Scanner = @import("Scanner.zig");
const CatalogSorter = @import("CatalogSorter.zig");
const Csr = @import("Csr.zig");
const Cli = @import("../Cli.zig");

/// Errors that can be returned by the validation pipeline.
pub const Error = error{
    /// A structural invariant does not hold (e.g., wrong row count, unsorted IDs).
    InvariantViolation,
    /// An expected staged file is missing or unreadable.
    MissingFile,
    /// `catalog.bin` has the wrong size or malformed rows.
    InvalidCatalogFile,
    /// An offsets file has the wrong size or non-monotone entries.
    InvalidOffsetFile,
    /// An adjacency file has the wrong size or out-of-range ordinals.
    InvalidAdjacencyFile,
    /// `classes.bin` has the wrong size or malformed records.
    InvalidClassesFile,
    /// `fields.bin` has the wrong size or malformed records.
    InvalidFieldsFile,
    /// `roots.bin` has the wrong size or malformed records.
    InvalidRootsFile,
    OutOfMemory,
    WriteFailed,
};

/// The set of files that must exist in the staging directory before validation
/// can proceed. These are the files that `Publish.zig` will move into the final
/// index directory.
const expected_files = &[_][]const u8{
    "catalog.bin",
    "classes.bin",
    "fields.bin",
    "out_offsets.bin",
    "out_targets.bin",
    "in_offsets.bin",
    "in_sources.bin",
    "roots.bin",
    "prim_histogram.bin",
};

/// A read-only memory map of a file plus its exposed byte slice.
/// The underlying file handle is kept open until the map is destroyed; this
/// matches the pattern used elsewhere in the indexer and avoids destroying a
/// map after its file has been closed.
const MappedFile = struct {
    file: Io.File,
    mm: Io.File.MemoryMap,
    data: []const u8,
};

/// Open `path`, memory-map it read-only, and return the file handle, map, and
/// its data. If the file is empty, returns `null` so callers can treat it as an
/// empty slice without attempting a zero-length mmap.
fn mapFileReadOnly(
    io: Io,
    path: []const u8,
    name: []const u8,
    stderr: *Io.Writer,
    err: Error,
) Error!?MappedFile {
    const dir = Io.Dir.cwd();
    var file = dir.openFile(io, path, .{}) catch |open_err| {
        try Cli.printError(stderr, "index validation failed: failed to open '{s}': {s}", .{ name, @errorName(open_err) });
        return err;
    };
    const len = file.length(io) catch |len_err| {
        try Cli.printError(stderr, "index validation failed: failed to read size of '{s}': {s}", .{ name, @errorName(len_err) });
        file.close(io);
        return err;
    };
    if (len == 0) {
        file.close(io);
        return null;
    }

    const mm = Io.File.MemoryMap.create(io, file, .{
        .len = len,
        .protection = .{ .read = true, .write = false },
    }) catch |map_err| {
        try Cli.printError(stderr, "index validation failed: failed to map '{s}': {s}", .{ name, @errorName(map_err) });
        file.close(io);
        return err;
    };
    return .{ .file = file, .mm = mm, .data = mm.memory };
}

/// Validate all structural invariants of the staged index. Any failure prints a
/// one-line error to `stderr` and returns `error.InvariantViolation` (or a more
/// specific file-format error). On success the staged files are guaranteed to
/// be internally consistent and safe to publish.
///
/// `n_objects` is the number of unique rows in `catalog.bin`. The virtual root
/// ordinal is `n_objects` and every edge endpoint must be `<= n_objects`.
///
/// The validation order is deliberately conservative: missing files are caught
/// first, then format errors, then count/ordering invariants. This makes
/// failures easier to diagnose.
pub fn validate(
    allocator: std.mem.Allocator,
    io: Io,
    staging_dir: []const u8,
    n_objects: u64,
    n_edges: u64,
    n_roots: u64,
    n_classes: u64,
    stderr: *Io.Writer,
) Error!void {
    // 1. Every expected file exists and is readable.
    for (expected_files) |name| {
        const path = try std.fs.path.join(allocator, &.{ staging_dir, name });
        defer allocator.free(path);
        _ = fileSize(io, path) catch |err| {
            try Cli.printError(stderr, "index validation failed: missing or unreadable staged file '{s}': {s}", .{ name, @errorName(err) });
            return error.MissingFile;
        };
    }

    // Build paths to the individual staged files.
    const catalog_path = try std.fs.path.join(allocator, &.{ staging_dir, "catalog.bin" });
    defer allocator.free(catalog_path);

    const classes_path = try std.fs.path.join(allocator, &.{ staging_dir, "classes.bin" });
    defer allocator.free(classes_path);

    const fields_path = try std.fs.path.join(allocator, &.{ staging_dir, "fields.bin" });
    defer allocator.free(fields_path);

    const out_offsets_path = try std.fs.path.join(allocator, &.{ staging_dir, "out_offsets.bin" });
    defer allocator.free(out_offsets_path);
    const out_targets_path = try std.fs.path.join(allocator, &.{ staging_dir, "out_targets.bin" });
    defer allocator.free(out_targets_path);

    const in_offsets_path = try std.fs.path.join(allocator, &.{ staging_dir, "in_offsets.bin" });
    defer allocator.free(in_offsets_path);
    const in_sources_path = try std.fs.path.join(allocator, &.{ staging_dir, "in_sources.bin" });
    defer allocator.free(in_sources_path);

    const roots_path = try std.fs.path.join(allocator, &.{ staging_dir, "roots.bin" });
    defer allocator.free(roots_path);

    const virtual_root_ordinal = n_objects;
    const n_nodes = n_objects + 1;

    // 2. Catalog raw IDs are strictly sorted and unique, and kind values are valid.
    try validateCatalog(io, catalog_path, n_objects, n_classes, stderr);

    // 3. classes.bin is sorted and parseable, and its record count matches n_classes.
    try validateClasses(io, classes_path, n_classes, stderr);

    // 4. fields.bin is parseable (we do not fully decode names here; we just
    //    verify the per-class counts and per-field lengths are consistent).
    try validateFields(io, fields_path, n_classes, stderr);

    // 5. Forward and reverse CSR offsets are monotone, start at 0, end at n_edges,
    //    and have exactly n_nodes + 1 entries.
    try validateOffsets(io, out_offsets_path, n_nodes, n_edges, "out_offsets.bin", stderr);
    try validateOffsets(io, in_offsets_path, n_nodes, n_edges, "in_offsets.bin", stderr);

    // 6. Every target/source ordinal in the adjacency arrays is a valid node.
    try validateAdjacency(io, out_targets_path, n_edges, virtual_root_ordinal, "out_targets.bin", stderr);
    try validateAdjacency(io, in_sources_path, n_edges, virtual_root_ordinal, "in_sources.bin", stderr);

    // 7. roots.bin target ordinals are valid and its record count matches n_roots.
    try validateRoots(io, roots_path, n_roots, virtual_root_ordinal, stderr);
}

/// Return the size of `path` in bytes, or propagate the underlying I/O error.
fn fileSize(io: Io, path: []const u8) !u64 {
    const dir = Io.Dir.cwd();
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    return try file.length(io);
}

/// Validate `catalog.bin`.
///
/// Checks:
///   * File size is a multiple of `Scanner.catalog_row_size`.
///   * Row count equals `n_objects`.
///   * `raw_id` values are strictly increasing.
///   * Kind byte is in the valid range.
///   * Number of class rows equals `n_classes`.
fn validateCatalog(
    io: Io,
    path: []const u8,
    n_objects: u64,
    n_classes: u64,
    stderr: *Io.Writer,
) Error!void {
    var mapped = try mapFileReadOnly(io, path, "catalog.bin", stderr, error.InvalidCatalogFile);
    defer if (mapped) |*m| {
        m.mm.destroy(io);
        m.file.close(io);
    };
    const data = if (mapped) |m| m.data else &[_]u8{};

    if (data.len % Scanner.catalog_row_size != 0) {
        try Cli.printError(stderr, "index validation failed: catalog.bin has an unexpected size", .{});
        return error.InvalidCatalogFile;
    }

    const n_rows = data.len / Scanner.catalog_row_size;
    if (n_rows != n_objects) {
        try Cli.printError(stderr, "index validation failed: catalog.bin has an unexpected number of rows", .{});
        return error.InvariantViolation;
    }

    var class_count: u64 = 0;
    var last_id: u64 = 0;
    var i: usize = 0;
    while (i < n_rows) : (i += 1) {
        const row = data[i * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size];
        const raw_id = std.mem.readInt(u64, row[0..8], .little);
        const kind_byte = row[28];

        // CatalogKind values are 0..3; anything else is corrupt.
        if (kind_byte > 3) {
            try Cli.printError(stderr, "index validation failed: catalog.bin contains an invalid row", .{});
            return error.InvalidCatalogFile;
        }
        if (kind_byte == 3) {
            class_count += 1;
        }

        // Raw IDs must be strictly sorted so that ordinals are stable and
        // binary search in later stages works.
        if (i > 0) {
            if (raw_id <= last_id) {
                try Cli.printError(stderr, "index validation failed: catalog.bin rows are not sorted", .{});
                return error.InvariantViolation;
            }
        }
        last_id = raw_id;
    }

    if (class_count != n_classes) {
        try Cli.printError(stderr, "index validation failed: catalog.bin class count does not match expected value", .{});
        return error.InvariantViolation;
    }
}

/// Validate `classes.bin`.
///
/// Checks:
///   * Records are parseable: class ID, superclass ID, instance size, name length,
///     and name bytes all fit inside the file.
///   * Class IDs are strictly increasing.
///   * Record count equals `n_classes`.
fn validateClasses(
    io: Io,
    path: []const u8,
    n_classes: u64,
    stderr: *Io.Writer,
) Error!void {
    var mapped = try mapFileReadOnly(io, path, "classes.bin", stderr, error.InvalidClassesFile);
    defer if (mapped) |*m| {
        m.mm.destroy(io);
        m.file.close(io);
    };
    const data = if (mapped) |m| m.data else &[_]u8{};

    var offset: usize = 0;
    var count: u64 = 0;
    var last_id: u64 = 0;
    while (offset < data.len) {
        if (offset + 24 > data.len) {
            try Cli.printError(stderr, "index validation failed: classes.bin is truncated", .{});
            return error.InvalidClassesFile;
        }
        const class_id = std.mem.readInt(u64, data[offset..][0..8], .little);
        const name_len = std.mem.readInt(u32, data[offset + 20 ..][0..4], .little);
        if (offset + 24 + name_len > data.len) {
            try Cli.printError(stderr, "index validation failed: classes.bin is truncated", .{});
            return error.InvalidClassesFile;
        }
        if (count > 0 and class_id <= last_id) {
            try Cli.printError(stderr, "index validation failed: classes.bin is not sorted", .{});
            return error.InvariantViolation;
        }
        last_id = class_id;
        offset += 24 + name_len;
        count += 1;
    }

    if (count != n_classes) {
        try Cli.printError(stderr, "index validation failed: classes.bin has an unexpected number of records", .{});
        return error.InvariantViolation;
    }
}

/// Validate `fields.bin`.
///
/// Checks:
///   * File is parseable as a sequence of class records.
///   * Each class record has a `class_raw_id` and `field_count`.
///   * Each field record fits inside the file.
///   * Class record count equals `n_classes`.
///
/// Field names and types are not fully decoded here; structural consistency is
/// enough because the query-time reader will detect malformed field data.
fn validateFields(
    io: Io,
    path: []const u8,
    n_classes: u64,
    stderr: *Io.Writer,
) Error!void {
    var mapped = try mapFileReadOnly(io, path, "fields.bin", stderr, error.InvalidFieldsFile);
    defer if (mapped) |*m| {
        m.mm.destroy(io);
        m.file.close(io);
    };
    const data = if (mapped) |m| m.data else &[_]u8{};

    var offset: usize = 0;
    var class_count: u64 = 0;
    while (offset < data.len) {
        if (offset + 12 > data.len) {
            try Cli.printError(stderr, "index validation failed: fields.bin is truncated", .{});
            return error.InvalidFieldsFile;
        }
        // class_raw_id u64 + field_count u32
        const field_count = std.mem.readInt(u32, data[offset + 8 ..][0..4], .little);
        offset += 12;

        var field_idx: u32 = 0;
        while (field_idx < field_count) : (field_idx += 1) {
            if (offset + 2 > data.len) {
                try Cli.printError(stderr, "index validation failed: fields.bin is truncated", .{});
                return error.InvalidFieldsFile;
            }
            const name_len = std.mem.readInt(u16, data[offset..][0..2], .little);
            // name_len u16 + name bytes + type u8 + byte_offset u32 + declaring_class_raw_id u64
            if (offset + 2 + name_len + 13 > data.len) {
                try Cli.printError(stderr, "index validation failed: fields.bin is truncated", .{});
                return error.InvalidFieldsFile;
            }
            offset += 2 + name_len + 13;
        }
        class_count += 1;
    }

    if (class_count != n_classes) {
        try Cli.printError(stderr, "index validation failed: fields.bin has an unexpected number of class records", .{});
        return error.InvariantViolation;
    }
}

/// Validate a CSR offsets file (`out_offsets.bin` or `in_offsets.bin`).
///
/// Checks:
///   * File size is a multiple of 8 bytes.
///   * Entry count equals `n_nodes + 1`.
///   * First entry is 0.
///   * Entries are monotone non-decreasing.
///   * Last entry equals `n_edges`.
fn validateOffsets(
    io: Io,
    path: []const u8,
    n_nodes: u64,
    n_edges: u64,
    name: []const u8,
    stderr: *Io.Writer,
) Error!void {
    var mapped = try mapFileReadOnly(io, path, name, stderr, error.InvalidOffsetFile);
    defer if (mapped) |*m| {
        m.mm.destroy(io);
        m.file.close(io);
    };
    const data = if (mapped) |m| m.data else &[_]u8{};

    if (data.len % 8 != 0) {
        try Cli.printError(stderr, "index validation failed: {s} has an unexpected size", .{name});
        return error.InvalidOffsetFile;
    }

    const n_entries = data.len / 8;
    if (n_entries != n_nodes + 1) {
        try Cli.printError(stderr, "index validation failed: {s} has an unexpected number of entries", .{name});
        return error.InvariantViolation;
    }

    var last: u64 = 0;
    var i: usize = 0;
    while (i < n_entries) : (i += 1) {
        const value = std.mem.readInt(u64, data[i * 8 ..][0..8], .little);
        if (i == 0 and value != 0) {
            try Cli.printError(stderr, "index validation failed: {s} starts with a non-zero value", .{name});
            return error.InvariantViolation;
        }
        if (value < last) {
            try Cli.printError(stderr, "index validation failed: {s} is not monotone", .{name});
            return error.InvariantViolation;
        }
        last = value;
    }

    if (last != n_edges) {
        try Cli.printError(stderr, "index validation failed: {s} ends with an unexpected value", .{name});
        return error.InvariantViolation;
    }
}

/// Validate a CSR adjacency file (`out_targets.bin` or `in_sources.bin`).
///
/// Checks:
///   * File size is a multiple of 4 bytes.
///   * Entry count equals `n_edges`.
///   * Every ordinal is `<= virtual_root_ordinal`.
fn validateAdjacency(
    io: Io,
    path: []const u8,
    n_edges: u64,
    virtual_root_ordinal: u64,
    name: []const u8,
    stderr: *Io.Writer,
) Error!void {
    var mapped = try mapFileReadOnly(io, path, name, stderr, error.InvalidAdjacencyFile);
    defer if (mapped) |*m| {
        m.mm.destroy(io);
        m.file.close(io);
    };
    const data = if (mapped) |m| m.data else &[_]u8{};

    if (data.len % 4 != 0) {
        try Cli.printError(stderr, "index validation failed: {s} has an unexpected size", .{name});
        return error.InvalidAdjacencyFile;
    }

    const n_entries = data.len / 4;
    if (n_entries != n_edges) {
        try Cli.printError(stderr, "index validation failed: {s} has an unexpected number of entries", .{name});
        return error.InvariantViolation;
    }

    var i: usize = 0;
    while (i < n_entries) : (i += 1) {
        const value = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        if (value > virtual_root_ordinal) {
            try Cli.printError(stderr, "index validation failed: {s} contains an invalid ordinal", .{name});
            return error.InvariantViolation;
        }
    }
}

/// Validate `roots.bin`.
///
/// Checks:
///   * File size is a multiple of `Csr.roots_bin_record_size`.
///   * Record count equals `n_roots`.
///   * Every `target_ordinal` is `<= virtual_root_ordinal`.
fn validateRoots(
    io: Io,
    path: []const u8,
    n_roots: u64,
    virtual_root_ordinal: u64,
    stderr: *Io.Writer,
) Error!void {
    var mapped = try mapFileReadOnly(io, path, "roots.bin", stderr, error.InvalidRootsFile);
    defer if (mapped) |*m| {
        m.mm.destroy(io);
        m.file.close(io);
    };
    const data = if (mapped) |m| m.data else &[_]u8{};

    if (data.len % Csr.roots_bin_record_size != 0) {
        try Cli.printError(stderr, "index validation failed: roots.bin has an unexpected size", .{});
        return error.InvalidRootsFile;
    }

    const n_entries = data.len / Csr.roots_bin_record_size;
    if (n_entries != n_roots) {
        try Cli.printError(stderr, "index validation failed: roots.bin has an unexpected number of records", .{});
        return error.InvariantViolation;
    }

    var i: usize = 0;
    while (i < n_entries) : (i += 1) {
        const rec = Csr.readRootRecord(data[i * Csr.roots_bin_record_size ..][0..Csr.roots_bin_record_size]);
        if (rec.target_ordinal > virtual_root_ordinal) {
            try Cli.printError(stderr, "index validation failed: roots.bin contains an invalid ordinal", .{});
            return error.InvariantViolation;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Create a synthetic `catalog.bin` file in `dir` from in-memory rows.
fn createSyntheticCatalog(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    rows: []const Scanner.CatalogRow,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "catalog.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (rows) |row| {
        try Scanner.writeCatalogRow(&writer.interface, row);
    }
    try writer.flush();
}

/// Create a synthetic CSR offsets file in `dir` with the given name.
fn createSyntheticOffsets(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
    offsets: []const u64,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (offsets) |off| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, off, .little);
        try writer.interface.writeAll(&bytes);
    }
    try writer.flush();
}

/// Create a synthetic CSR adjacency file in `dir` with the given name.
fn createSyntheticAdjacency(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
    values: []const u32,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |v| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, v, .little);
        try writer.interface.writeAll(&bytes);
    }
    try writer.flush();
}

/// In-memory representation of a resolved root for test fixtures.
const SyntheticRoot = struct {
    target_ordinal: u32,
    root_kind: u8,
    thread_serial: u32,
};

/// Create a synthetic `roots.bin` file in `dir` from in-memory roots.
fn createSyntheticRoots(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    roots: []const SyntheticRoot,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "roots.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (roots) |r| {
        try Csr.writeRootRecord(&writer.interface, .{
            .target_ordinal = r.target_ordinal,
            .root_kind = r.root_kind,
            .thread_serial = r.thread_serial,
        });
    }
    try writer.flush();
}

/// In-memory representation of a classes.bin record for test fixtures.
const SyntheticClass = struct {
    class_id: u64,
    super_id: u64,
    instance_size: u32,
    name: []const u8,
};

/// Create a synthetic `classes.bin` file in `dir` from in-memory classes.
fn createSyntheticClasses(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    classes: []const SyntheticClass,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "classes.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (classes) |c| {
        var header: [24]u8 = undefined;
        std.mem.writeInt(u64, header[0..8], c.class_id, .little);
        std.mem.writeInt(u64, header[8..16], c.super_id, .little);
        std.mem.writeInt(u32, header[16..20], c.instance_size, .little);
        std.mem.writeInt(u32, header[20..24], @intCast(c.name.len), .little);
        try writer.interface.writeAll(&header);
        if (c.name.len > 0) {
            try writer.interface.writeAll(c.name);
        }
    }
    try writer.flush();
}

/// Create a synthetic `fields.bin` file with `class_count` empty class records.
fn createSyntheticFields(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    class_count: u64,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "fields.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);

    var i: u64 = 0;
    while (i < class_count) : (i += 1) {
        var class_header: [12]u8 = undefined;
        std.mem.writeInt(u64, class_header[0..8], i, .little);
        std.mem.writeInt(u32, class_header[8..12], 0, .little);
        try writer.interface.writeAll(&class_header);
    }
    try writer.flush();
}

/// Create a synthetic `prim_histogram.bin` file in `dir`.
fn createSyntheticPrimHistogram(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "prim_histogram.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, 0, .little);
    try writer.interface.writeAll(&count_buf);
    try writer.flush();
}

/// Run `validate` on `dir` with the given counts and capture stderr to a buffer.
fn runValidate(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    n_objects: u64,
    n_edges: u64,
    n_roots: u64,
    n_classes: u64,
) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    try validate(allocator, io, dir, n_objects, n_edges, n_roots, n_classes, &stderr_writer.interface);
}

// A complete, valid staged directory passes all checks.
test "validate accepts consistent 2-node graph" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // 2 real objects, virtual root ordinal = 2.
    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });

    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{});
    try createSyntheticFields(allocator, io, tmp_path, 0);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 1, 1, 1 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 1, 1 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{1});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{0});

    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{
        .{ .target_ordinal = 0, .root_kind = 0x01, .thread_serial = 0 },
    });

    try runValidate(allocator, io, tmp_path, 2, 1, 1, 0);
}

// Non-increasing raw IDs in the catalog must be rejected.
test "validate rejects unsorted catalog" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });

    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 2, 0, 0, 1));
}

// Decreasing offset entries would break the CSR invariant; they must fail.
test "validate rejects non-monotone offsets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 1, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 1, 0, 0, 1));
}

// Ordinals greater than the virtual root ordinal are out of range.
test "validate rejects adjacency ordinal exceeding virtual root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 1 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 1 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{2}); // virtual root = 1, so 2 is invalid
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{0});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 1, 1, 0, 1));
}

// The catalog row count must equal n_objects.
test "validate rejects catalog row count mismatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 2, 0, 0, 1));
}

// The classes.bin record count must match the number of class rows in the catalog.
test "validate rejects classes.bin count mismatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .class },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
        .{ .class_id = 0x2000, .super_id = 0, .instance_size = 8, .name = "B" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 2);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    // n_classes claims 1, but catalog has 2 class rows and classes.bin has 2 records.
    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 2, 0, 0, 1));
}

// The roots.bin record count must match n_roots.
test "validate rejects roots.bin count mismatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{
        .{ .target_ordinal = 0, .root_kind = 0x01, .thread_serial = 0 },
    });

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 1, 0, 0, 1));
}

// Root target ordinals must also be in range.
test "validate rejects roots target ordinal exceeding virtual root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{
        .{ .target_ordinal = 2, .root_kind = 0x01, .thread_serial = 0 },
    });

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 1, 0, 1, 1));
}

// A completely empty staging directory must fail the missing-file check.
test "validate detects missing staged file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try std.testing.expectError(error.MissingFile, runValidate(allocator, io, tmp_path, 0, 0, 0, 0));
}
