//! Persistent index manifest: fingerprint, counts, diagnostics, and file list.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");

pub const hash_block_size = 1024 * 1024; // 1 MiB
pub const hash_algorithm_name = "fnv1a64";

pub const Fingerprint = struct {
    file_length: u64,
    hprof_timestamp: u64,
    id_size: u32,
    hash_algorithm: []const u8,
    hash_value: []const u8,
    source_mtime: i128,

    pub fn deinit(self: Fingerprint, allocator: std.mem.Allocator) void {
        allocator.free(self.hash_algorithm);
        allocator.free(self.hash_value);
    }

    pub fn clone(self: Fingerprint, allocator: std.mem.Allocator) !Fingerprint {
        return .{
            .file_length = self.file_length,
            .hprof_timestamp = self.hprof_timestamp,
            .id_size = self.id_size,
            .hash_algorithm = try allocator.dupe(u8, self.hash_algorithm),
            .hash_value = try allocator.dupe(u8, self.hash_value),
            .source_mtime = self.source_mtime,
        };
    }

    pub fn eql(a: Fingerprint, b: Fingerprint) bool {
        return a.file_length == b.file_length and
            a.hprof_timestamp == b.hprof_timestamp and
            a.id_size == b.id_size and
            std.mem.eql(u8, a.hash_algorithm, b.hash_algorithm) and
            std.mem.eql(u8, a.hash_value, b.hash_value);
    }
};

pub const Diagnostics = struct {
    duplicate_object_ids: u64 = 0,
    skipped_constant_pool_refs: u64 = 0,
    dangling_source_edges: u64 = 0,
    dangling_target_edges: u64 = 0,
    missing_superclass: u64 = 0,
    superclass_cycle: u64 = 0,
    unknown_root_kind: u64 = 0,
    missing_layout: u64 = 0,
    dangling_root_targets: u64 = 0,
};

pub const FileEntry = struct {
    name: []const u8,
    size: u64,
};

pub const IndexManifest = struct {
    format_version: u32 = 1,
    fingerprint: Fingerprint,
    n_objects: u64 = 0,
    n_edges: u64 = 0,
    virtual_root_ordinal: u32 = 0,
    diagnostics: Diagnostics = .{},
    files: []const FileEntry = &.{},
    /// Absolute or relative path to the source HPROF file used to build the
    /// index. Stored to support query commands that need to decode raw object
    /// records from the dump.
    source_path: ?[]const u8 = null,

    pub fn deinit(self: *const IndexManifest, allocator: std.mem.Allocator) void {
        self.fingerprint.deinit(allocator);
        for (self.files) |entry| {
            allocator.free(entry.name);
        }
        if (self.files.len > 0) allocator.free(self.files);
        if (self.source_path) |p| allocator.free(p);
    }

    pub fn clone(self: IndexManifest, allocator: std.mem.Allocator) !IndexManifest {
        const files = try allocator.alloc(FileEntry, self.files.len);
        errdefer allocator.free(files);
        for (self.files, 0..) |entry, i| {
            files[i] = .{
                .name = try allocator.dupe(u8, entry.name),
                .size = entry.size,
            };
        }
        return .{
            .format_version = self.format_version,
            .fingerprint = try self.fingerprint.clone(allocator),
            .n_objects = self.n_objects,
            .n_edges = self.n_edges,
            .virtual_root_ordinal = self.virtual_root_ordinal,
            .diagnostics = self.diagnostics,
            .files = files,
            .source_path = if (self.source_path) |p| try allocator.dupe(u8, p) else null,
        };
    }

    pub fn write(self: IndexManifest, writer: *Io.Writer) !void {
        var opts: std.json.Stringify.Options = .{};
        opts.whitespace = .indent_2;
        try std.json.Stringify.value(self, opts, writer);
        try writer.writeByte('\n');
    }

    pub fn toJson(self: IndexManifest, allocator: std.mem.Allocator) ![]const u8 {
        var aw = Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try self.write(&aw.writer);
        const len = aw.writer.end;
        const result = try allocator.alloc(u8, len);
        @memcpy(result, aw.writer.buffer[0..len]);
        return result;
    }

    pub fn parse(allocator: std.mem.Allocator, slice: []const u8) !IndexManifest {
        const parsed = try std.json.parseFromSlice(IndexManifest, allocator, slice, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return try parsed.value.clone(allocator);
    }

    pub fn writeToFile(self: IndexManifest, allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
        const data = try self.toJson(allocator);
        defer allocator.free(data);
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = data,
        });
    }

    pub fn parseFromFile(allocator: std.mem.Allocator, io: Io, path: []const u8) !IndexManifest {
        const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(data);
        return try parse(allocator, data);
    }
};

/// Compute the source fingerprint from a memory-mapped HPROF dump.
/// The returned fingerprint owns its strings; the caller must eventually free
/// them via `Fingerprint.deinit` or by placing it in a `IndexManifest`.
pub fn computeFingerprint(allocator: std.mem.Allocator, data: []const u8, header: hprof.Header.Header, source_mtime: i128) !Fingerprint {
    var hasher = std.hash.Fnv1a_64.init();
    if (data.len <= hash_block_size * 2) {
        hasher.update(data);
    } else {
        hasher.update(data[0..hash_block_size]);
        hasher.update(data[data.len - hash_block_size ..]);
    }
    const hash = hasher.final();

    const hash_value = try std.fmt.allocPrint(allocator, "{x:0>16}", .{hash});
    errdefer allocator.free(hash_value);
    const hash_algorithm = try allocator.dupe(u8, hash_algorithm_name);
    errdefer allocator.free(hash_algorithm);

    return .{
        .file_length = data.len,
        .hprof_timestamp = header.timestamp,
        .id_size = header.id_size,
        .hash_algorithm = hash_algorithm,
        .hash_value = hash_value,
        .source_mtime = source_mtime,
    };
}

test "fingerprint hashes first and last block" {
    const allocator = std.testing.allocator;
    var data: [hash_block_size * 2 + 128]u8 = undefined;
    @memset(&data, 0xAB);
    data[0] = 0x12;
    data[hash_block_size * 2] = 0x34;
    data[data.len - 1] = 0x56;

    const header: hprof.Header.Header = .{ .id_size = 8, .timestamp = 123456789 };
    const fp = try computeFingerprint(allocator, &data, header, 0);
    defer fp.deinit(allocator);

    try std.testing.expectEqual(@as(u64, data.len), fp.file_length);
    try std.testing.expectEqual(@as(u64, 123456789), fp.hprof_timestamp);
    try std.testing.expectEqual(@as(u32, 8), fp.id_size);
    try std.testing.expectEqualStrings(hash_algorithm_name, fp.hash_algorithm);
    try std.testing.expectEqual(@as(usize, 16), fp.hash_value.len);
}

test "manifest JSON roundtrip" {
    const allocator = std.testing.allocator;
    const fp_source = Fingerprint{
        .file_length = 1024,
        .hprof_timestamp = 42,
        .id_size = 8,
        .hash_algorithm = hash_algorithm_name,
        .hash_value = "deadbeefdeadbeef",
        .source_mtime = 99,
    };
    const fp = try fp_source.clone(allocator);
    defer fp.deinit(allocator);

    var manifest = IndexManifest{
        .format_version = 1,
        .fingerprint = fp,
        .n_objects = 100,
        .n_edges = 50,
        .virtual_root_ordinal = 100,
        .diagnostics = .{
            .duplicate_object_ids = 2,
            .dangling_source_edges = 1,
        },
        .files = &.{
            .{ .name = "catalog.bin", .size = 3200 },
            .{ .name = "out_targets.bin", .size = 200 },
        },
    };

    const json = try manifest.toJson(allocator);
    defer allocator.free(json);

    const parsed = try IndexManifest.parse(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(manifest.format_version, parsed.format_version);
    try std.testing.expectEqual(manifest.fingerprint.file_length, parsed.fingerprint.file_length);
    try std.testing.expectEqual(manifest.fingerprint.hprof_timestamp, parsed.fingerprint.hprof_timestamp);
    try std.testing.expectEqual(manifest.fingerprint.id_size, parsed.fingerprint.id_size);
    try std.testing.expectEqualStrings(manifest.fingerprint.hash_value, parsed.fingerprint.hash_value);
    try std.testing.expectEqual(manifest.fingerprint.source_mtime, parsed.fingerprint.source_mtime);
    try std.testing.expectEqual(manifest.n_objects, parsed.n_objects);
    try std.testing.expectEqual(manifest.n_edges, parsed.n_edges);
    try std.testing.expectEqual(manifest.virtual_root_ordinal, parsed.virtual_root_ordinal);
    try std.testing.expectEqual(manifest.diagnostics.duplicate_object_ids, parsed.diagnostics.duplicate_object_ids);
    try std.testing.expectEqual(manifest.diagnostics.dangling_source_edges, parsed.diagnostics.dangling_source_edges);
    try std.testing.expectEqual(@as(usize, 2), parsed.files.len);
    try std.testing.expectEqualStrings("catalog.bin", parsed.files[0].name);
    try std.testing.expectEqual(@as(u64, 3200), parsed.files[0].size);
    try std.testing.expectEqualStrings("out_targets.bin", parsed.files[1].name);
    try std.testing.expectEqual(@as(u64, 200), parsed.files[1].size);
}

test "fingerprint mismatch detection" {
    const fp_a = Fingerprint{
        .file_length = 100,
        .hprof_timestamp = 1,
        .id_size = 8,
        .hash_algorithm = hash_algorithm_name,
        .hash_value = "aabbccddeeff0011",
        .source_mtime = 0,
    };
    const fp_b = Fingerprint{
        .file_length = 100,
        .hprof_timestamp = 2,
        .id_size = 8,
        .hash_algorithm = hash_algorithm_name,
        .hash_value = "aabbccddeeff0011",
        .source_mtime = 0,
    };
    try std.testing.expect(!fp_a.eql(fp_b));

    const fp_c = Fingerprint{
        .file_length = 100,
        .hprof_timestamp = 1,
        .id_size = 8,
        .hash_algorithm = hash_algorithm_name,
        .hash_value = "aabbccddeeff0011",
        .source_mtime = 999,
    };
    try std.testing.expect(fp_a.eql(fp_c));
}
