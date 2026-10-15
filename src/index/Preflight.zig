//! Stage 0: validate source, compare fingerprint, and prepare a staging directory.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Publish = @import("Publish.zig");
const Cli = @import("../Cli.zig");

pub const Job = struct {
    source_path: []const u8,
    index_dir: []const u8,
    staging_dir: []const u8,
    budget_bytes: usize,
    fingerprint: Manifest.Fingerprint,
    header: hprof.Header.Header,

    pub fn deinit(self: *const Job, allocator: std.mem.Allocator) void {
        self.fingerprint.deinit(allocator);
        allocator.free(self.staging_dir);
    }
};

pub const Result = union(enum) {
    reused,
    job: Job,
};

pub const Options = struct {
    sorting_budget_mb: u32 = 512,
    force: bool = false,
};

/// Run Stage 0 preflight. On success returns either `reused` (an up-to-date
/// index already exists) or a `Job` describing the staging directory and
/// fingerprint. The caller must call `Job.deinit` when done.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    source_path: []const u8,
    index_dir: []const u8,
    options: Options,
    stderr: *Io.Writer,
) !Result {
    const dir = Io.Dir.cwd();
    var file = try dir.openFile(io, source_path, .{});
    defer file.close(io);

    const file_len = try file.length(io);
    if (file_len == 0) {
        try stderr.print("error: file is empty\n", .{});
        return error.EmptyFile;
    }

    var mm = try Io.File.MemoryMap.create(io, file, .{
        .len = file_len,
        .protection = .{ .read = true, .write = false },
    });
    defer mm.destroy(io);

    const header = try hprof.Header.parse(mm.memory);
    const mtime = try sourceMtime(io, source_path);
    const fingerprint = try Manifest.computeFingerprint(allocator, mm.memory, header, mtime);

    try ensureIndexDir(io, index_dir, stderr);

    if (!options.force) {
        const manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
        defer allocator.free(manifest_path);

        if (Manifest.IndexManifest.parseFromFile(allocator, io, manifest_path)) |existing| {
            defer existing.deinit(allocator);
            if (existing.fingerprint.eql(fingerprint)) {
                if (hasAllIndexFiles(io, index_dir)) {
                    fingerprint.deinit(allocator);
                    return .reused;
                }
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                // Treat unreadable manifest as stale; continue to rebuild.
            },
        }
    }

    const staging_dir = try createStagingDir(io, allocator, index_dir);
    errdefer {
        Io.Dir.cwd().deleteTree(io, staging_dir) catch {};
        allocator.free(staging_dir);
    }

    return .{ .job = .{
        .source_path = source_path,
        .index_dir = index_dir,
        .staging_dir = staging_dir,
        .budget_bytes = @as(usize, options.sorting_budget_mb) * 1024 * 1024,
        .fingerprint = fingerprint,
        .header = header,
    } };
}

fn hasAllIndexFiles(io: Io, index_dir: []const u8) bool {
    const dir = Io.Dir.cwd();
    for (Publish.final_files) |name| {
        const path = std.fs.path.join(std.heap.page_allocator, &.{ index_dir, name }) catch return false;
        defer std.heap.page_allocator.free(path);
        var file = dir.openFile(io, path, .{}) catch return false;
        file.close(io);
    }
    return true;
}

fn sourceMtime(io: Io, path: []const u8) !i128 {
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    return stat.mtime.nanoseconds;
}

fn ensureIndexDir(io: Io, index_dir: []const u8, stderr: *Io.Writer) !void {
    Io.Dir.cwd().createDirPath(io, index_dir) catch |err| {
        try Cli.printError(stderr, "failed to create or access index directory '{s}': {s}", .{ index_dir, @errorName(err) });
        return error.IndexDirInaccessible;
    };

    const test_path = try std.fs.path.join(std.heap.page_allocator, &.{ index_dir, ".hunt-write-test" });
    defer std.heap.page_allocator.free(test_path);
    defer Io.Dir.cwd().deleteFile(io, test_path) catch {};

    Io.Dir.cwd().writeFile(io, .{
        .sub_path = test_path,
        .data = "test",
    }) catch |err| {
        try Cli.printError(stderr, "index directory '{s}' is not writable: {s}", .{ index_dir, @errorName(err) });
        return error.IndexDirNotWritable;
    };
}

fn createStagingDir(io: Io, allocator: std.mem.Allocator, index_dir: []const u8) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);

    const staging_dir = try std.fmt.allocPrint(allocator, "{s}/.staging-{s}", .{ index_dir, suffix[0..] });
    errdefer allocator.free(staging_dir);

    try Io.Dir.cwd().createDirPath(io, staging_dir);
    return staging_dir;
}

fn tempSpaceEstimate(file_len: u64, sorting_budget_mb: u32) u64 {
    // Conservative upper bound: up to 3x the dump size for catalog + edges +
    // sort runs, but at least enough to hold a few budget-sized runs.
    const budget_bytes = @as(u64, sorting_budget_mb) * 1024 * 1024;
    const from_dump = file_len * 3;
    const from_budget = budget_bytes * 2;
    return @max(from_dump, from_budget);
}

test "preflight reuse path with matching manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);
    const index_dir = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir);

    const source_path = "test_hprofs/heapforge.hprof";

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // First run: should create a staging directory and return a job.
    const result1 = try run(allocator, io, source_path, index_dir, .{}, stderr);
    switch (result1) {
        .reused => return error.UnexpectedReuse,
        .job => |*job| job.deinit(allocator),
    }

    // Compute the fingerprint and write a manifest with matching fingerprint.
    const dir = Io.Dir.cwd();
    var file = try dir.openFile(io, source_path, .{});
    defer file.close(io);
    const file_len = try file.length(io);
    var mm = try Io.File.MemoryMap.create(io, file, .{
        .len = file_len,
        .protection = .{ .read = true, .write = false },
    });
    defer mm.destroy(io);

    const header = try hprof.Header.parse(mm.memory);
    const mtime = try sourceMtime(io, source_path);
    const fp = try Manifest.computeFingerprint(allocator, mm.memory, header, mtime);
    defer fp.deinit(allocator);

    const manifest = Manifest.IndexManifest{ .fingerprint = fp };
    const manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    try manifest.writeToFile(allocator, io, manifest_path);

    // Write the binary files that preflight checks for before reuse.
    for (Publish.final_files) |name| {
        try createSyntheticFile(allocator, io, index_dir, name, name);
    }

    // Second run without force: should report reused.
    const result2 = try run(allocator, io, source_path, index_dir, .{}, stderr);
    switch (result2) {
        .reused => {},
        .job => |*job| job.deinit(allocator),
    }

    // Third run with force: should ignore the manifest and return a job.
    const result3 = try run(allocator, io, source_path, index_dir, .{ .force = true }, stderr);
    switch (result3) {
        .reused => return error.UnexpectedReuse,
        .job => |*job| job.deinit(allocator),
    }
}

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
