//! Stage 8: publish the staged index by renaming files into the final index
//! directory, writing the manifest.json last, and removing the staging directory.
//!
//! This module is the final step of the indexer pipeline. It assumes the staged
//! files have already passed validation (`Validate.zig`). Publication performs
//! atomic directory renames, populates the manifest with file sizes, writes
//! `manifest.json` as the commit record, and removes the staging directory.
//!
//! If any step fails, the staging directory is left in place for diagnosis and
//! an error is returned.
const std = @import("std");
const Io = std.Io;
const Manifest = @import("Manifest.zig");

/// Errors that can be returned by the publication pipeline.
pub const Error = error{
    /// A file rename, directory operation, or stat failed.
    PublishFailed,
    /// Writing `manifest.json` failed.
    ManifestWriteFailed,
    OutOfMemory,
    WriteFailed,
};

/// The set of staged files that are moved into the final index directory.
/// These names match the files produced by earlier stages and checked by
/// `Validate.zig`.
pub const final_files = &[_][]const u8{
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

/// Result of Stage 8 publication. Holds the total byte size of the published
/// index files and the manifest file entries.
pub const Result = struct {
    /// Sum of the sizes of all published binary files (excluding manifest.json).
    index_bytes: u64,
    /// Owned slice of manifest file entries, including name and size.
    files: []const Manifest.FileEntry,

    /// Free the owned file entry names and the files slice itself. The actual
    /// published files in `index_dir` are left untouched.
    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        for (self.files) |entry| {
            allocator.free(entry.name);
        }
        allocator.free(self.files);
    }
};

/// Rename the staged index files into `index_dir`, populate the manifest file
/// list with their sizes, write `manifest.json` last, and remove the staging
/// directory. If any step fails, the staging directory is left in place for
/// diagnostic purposes; the caller is expected to clean it up via `errdefer`.
///
/// `manifest` is mutated: its `files` slice is replaced with the published file
/// entries. `virtual_root_ordinal` and other metadata are expected to already
/// be set by the caller.
///
/// Files are renamed via `Dir.rename`, which is atomic on most filesystems when
/// source and destination are on the same mount. This ensures that a query
/// engine never sees a partially published index.
pub fn publish(
    allocator: std.mem.Allocator,
    io: Io,
    staging_dir: []const u8,
    index_dir: []const u8,
    manifest: *Manifest.IndexManifest,
    stderr: *Io.Writer,
) Error!Result {
    const dir = Io.Dir.cwd();

    // Rename each final file from the staging directory into the index directory.
    var staging_dir_handle = Io.Dir.cwd().openDir(io, staging_dir, .{}) catch |err| {
        try stderr.print("error: failed to open staging directory {s}: {}\n", .{ staging_dir, err });
        return error.PublishFailed;
    };
    defer staging_dir_handle.close(io);
    var index_dir_handle = Io.Dir.cwd().openDir(io, index_dir, .{}) catch |err| {
        try stderr.print("error: failed to open index directory {s}: {}\n", .{ index_dir, err });
        return error.PublishFailed;
    };
    defer index_dir_handle.close(io);

    for (final_files) |name| {
        staging_dir_handle.rename(name, index_dir_handle, name, io) catch |err| {
            try stderr.print("error: failed to publish {s}: {}\n", .{ name, err });
            return error.PublishFailed;
        };
    }

    // Collect file sizes from the published files for the manifest.
    var files = std.ArrayList(Manifest.FileEntry).empty;
    errdefer {
        for (files.items) |entry| {
            allocator.free(entry.name);
        }
        files.deinit(allocator);
    }

    var index_bytes: u64 = 0;
    for (final_files) |name| {
        const new_path = try std.fs.path.join(allocator, &.{ index_dir, name });
        defer allocator.free(new_path);

        const stat = dir.statFile(io, new_path, .{}) catch |err| {
            try stderr.print("error: failed to stat published file {s}: {}\n", .{ name, err });
            return error.PublishFailed;
        };

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try files.append(allocator, .{ .name = owned_name, .size = stat.size });
        index_bytes += stat.size;
    }

    manifest.files = try files.toOwnedSlice(allocator);

    // Write manifest.json last. It is the commit record: a query engine can
    // test for its existence to know the index is complete.
    const manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
    defer allocator.free(manifest_path);

    manifest.writeToFile(allocator, io, manifest_path) catch |err| {
        try stderr.print("error: failed to write manifest.json: {}\n", .{err});
        return error.ManifestWriteFailed;
    };

    // Remove the (now empty) staging directory.
    dir.deleteTree(io, staging_dir) catch |err| {
        try stderr.print("error: failed to remove staging directory {s}: {}\n", .{ staging_dir, err });
        return error.PublishFailed;
    };

    return .{
        .index_bytes = index_bytes,
        .files = manifest.files,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Create a synthetic file named `name` in `dir` containing `data`.
fn createSyntheticFile(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
    data: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    try writer.interface.writeAll(data);
    try writer.flush();
}

/// Return true if `path` exists and is openable.
fn fileExists(io: Io, path: []const u8) bool {
    const dir = Io.Dir.cwd();
    var file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

// All staged files are moved, manifest is written, and staging is removed.
test "publish renames files and writes manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_path, "staging" });
    defer allocator.free(staging_dir);
    try Io.Dir.cwd().createDirPath(io, staging_dir);

    const index_dir = try std.fs.path.join(allocator, &.{ tmp_path, "index" });
    defer allocator.free(index_dir);
    try Io.Dir.cwd().createDirPath(io, index_dir);

    for (final_files) |name| {
        try createSyntheticFile(allocator, io, staging_dir, name, name);
    }

    const fingerprint = Manifest.Fingerprint{
        .file_length = 1,
        .hprof_timestamp = 2,
        .id_size = 8,
        .hash_algorithm = "fnv1a64",
        .hash_value = "0000000000000000",
        .source_mtime = 0,
    };
    var manifest = Manifest.IndexManifest{
        .format_version = 1,
        .fingerprint = fingerprint,
        .n_objects = 10,
        .n_edges = 5,
        .virtual_root_ordinal = 10,
        .diagnostics = .{ .duplicate_object_ids = 1 },
    };

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);

    const result = try publish(allocator, io, staging_dir, index_dir, &manifest, &stderr_writer.interface);
    defer result.deinit(allocator);

    // Verify all files are in the index directory.
    for (final_files) |name| {
        const path = try std.fs.path.join(allocator, &.{ index_dir, name });
        defer allocator.free(path);
        try std.testing.expect(fileExists(io, path));
    }

    // Verify manifest.json exists and is the commit record.
    const manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    try std.testing.expect(fileExists(io, manifest_path));

    // Verify manifest content round-trips.
    const parsed = try Manifest.IndexManifest.parseFromFile(allocator, io, manifest_path);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 10), parsed.n_objects);
    try std.testing.expectEqual(@as(u64, 5), parsed.n_edges);
    try std.testing.expectEqual(@as(u32, 10), parsed.virtual_root_ordinal);
    try std.testing.expectEqual(@as(u64, 1), parsed.diagnostics.duplicate_object_ids);
    try std.testing.expectEqual(final_files.len, parsed.files.len);

    // Verify staging directory is removed.
    const staging_exists = blk: {
        var d = Io.Dir.cwd().openDir(io, staging_dir, .{}) catch break :blk false;
        d.close(io);
        break :blk true;
    };
    try std.testing.expect(!staging_exists);
}

// The total byte count returned in Result must equal the sum of file sizes.
test "publish computes total index bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_path, "staging" });
    defer allocator.free(staging_dir);
    try Io.Dir.cwd().createDirPath(io, staging_dir);

    const index_dir = try std.fs.path.join(allocator, &.{ tmp_path, "index" });
    defer allocator.free(index_dir);
    try Io.Dir.cwd().createDirPath(io, index_dir);

    // Write 4 bytes to each file: total should be 8 files * 4 = 32 bytes.
    for (final_files) |name| {
        try createSyntheticFile(allocator, io, staging_dir, name, "abcd");
    }

    const fingerprint = Manifest.Fingerprint{
        .file_length = 1,
        .hprof_timestamp = 2,
        .id_size = 8,
        .hash_algorithm = "fnv1a64",
        .hash_value = "0000000000000000",
        .source_mtime = 0,
    };
    var manifest = Manifest.IndexManifest{
        .format_version = 1,
        .fingerprint = fingerprint,
        .n_objects = 0,
        .n_edges = 0,
        .virtual_root_ordinal = 0,
    };

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);

    const result = try publish(allocator, io, staging_dir, index_dir, &manifest, &stderr_writer.interface);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, final_files.len * 4), result.index_bytes);
}

const hprof = @import("../hprof.zig");

// Missing staged files must fail before any file is published.
test "publish fails cleanly when staging file is missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_path, "staging" });
    defer allocator.free(staging_dir);
    try Io.Dir.cwd().createDirPath(io, staging_dir);

    const index_dir = try std.fs.path.join(allocator, &.{ tmp_path, "index" });
    defer allocator.free(index_dir);
    try Io.Dir.cwd().createDirPath(io, index_dir);

    // Only write some files; publish should fail.
    try createSyntheticFile(allocator, io, staging_dir, "catalog.bin", "x");

    const fingerprint = Manifest.Fingerprint{
        .file_length = 1,
        .hprof_timestamp = 2,
        .id_size = 8,
        .hash_algorithm = "fnv1a64",
        .hash_value = "0000000000000000",
        .source_mtime = 0,
    };
    var manifest = Manifest.IndexManifest{
        .format_version = 1,
        .fingerprint = fingerprint,
        .n_objects = 0,
        .n_edges = 0,
        .virtual_root_ordinal = 0,
    };

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);

    try std.testing.expectError(error.PublishFailed, publish(allocator, io, staging_dir, index_dir, &manifest, &stderr_writer.interface));
}
