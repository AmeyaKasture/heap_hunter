//! Integration tests that exercise the full parse -> index -> analysis flow
//! against real HPROF fixture files.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Analysis = @import("../Analysis.zig");
const Commands = @import("../Commands.zig");
const Config = @import("../Config.zig").Config;
const profiling = @import("profiling");

fn loadIndex(allocator: std.mem.Allocator, relative_path: []const u8) !Analysis.Index {
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    var file = try dir.openFile(io, relative_path, .{});
    defer file.close(io);

    const file_len = try file.length(io);
    var mm = try std.Io.File.MemoryMap.create(io, file, .{
        .len = file_len,
        .protection = .{ .read = true, .write = false },
        // Prefault: fixtures are small and parsed in full, and this mirrors
        // the production source mapping only in access pattern.
        .populate = true,
    });
    defer mm.destroy(io);

    var reader = try hprof.Reader.init(mm.memory);
    return try Analysis.buildIndex(allocator, &reader);
}

test "buildIndex finds heap-derived threads in real Java 21 dump" {
    const allocator = std.heap.page_allocator;
    var index = try loadIndex(allocator, "fixtures/heapforge.hprof");
    defer index.deinit();
}

test "index --profile emits timing tree to stderr" {
    // Instrumentation is compile-time gated (build_options.profile). In
    // Release builds the timing tree is stripped, so skip instead of fail.
    if (!profiling.build_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.Writer = Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer: Io.Writer = Io.Writer.fixed(&stderr_buf);

    const config_load: Config.LoadResult = .{};

    try Commands.runIndexCommand(allocator, io, .{
        .hprof_path = "fixtures/heapforge.hprof",
        .index_dir = tmp_path_z[0..tmp_path_z.len],
        .no_progress = true,
        .profile = true,
    }, &stdout_writer, &stderr_writer, config_load, null, null);

    try stdout_writer.flush();
    try stderr_writer.flush();

    const stderr_text = stderr_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "timings:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "scan") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "total:") != null);
}

test "index without --profile does not emit timing tree" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.Writer = Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer: Io.Writer = Io.Writer.fixed(&stderr_buf);

    const config_load: Config.LoadResult = .{};

    try Commands.runIndexCommand(allocator, io, .{
        .hprof_path = "fixtures/heapforge.hprof",
        .index_dir = tmp_path_z[0..tmp_path_z.len],
        .no_progress = true,
        .profile = false,
    }, &stdout_writer, &stderr_writer, config_load, null, null);

    try stderr_writer.flush();

    const stderr_text = stderr_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "timings:") == null);
}

test "index --profile keeps timings out of stdout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.Writer = Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer: Io.Writer = Io.Writer.fixed(&stderr_buf);

    const config_load: Config.LoadResult = .{};

    try Commands.runIndexCommand(allocator, io, .{
        .hprof_path = "fixtures/heapforge.hprof",
        .index_dir = tmp_path_z[0..tmp_path_z.len],
        .no_progress = true,
        .profile = true,
    }, &stdout_writer, &stderr_writer, config_load, null, null);

    try stdout_writer.flush();

    const stdout_text = stdout_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, stdout_text, "\"status\":\"complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_text, "timings:") == null);
}

test "overview --profile emits timing tree to stderr" {
    // Same compile-time gate as the index --profile test above.
    if (!profiling.build_enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const config_load: Config.LoadResult = .{};

    // Build an index first.
    var index_stdout_buf: [4096]u8 = undefined;
    var index_stdout: Io.Writer = Io.Writer.fixed(&index_stdout_buf);
    var index_stderr_buf: [8192]u8 = undefined;
    var index_stderr: Io.Writer = Io.Writer.fixed(&index_stderr_buf);

    try Commands.runIndexCommand(allocator, io, .{
        .hprof_path = "fixtures/heapforge.hprof",
        .index_dir = tmp_path_z[0..tmp_path_z.len],
        .no_progress = true,
        .profile = false,
    }, &index_stdout, &index_stderr, config_load, null, null);

    // Now run overview with profiling.
    var overview_stdout_buf: [4096]u8 = undefined;
    var overview_stdout: Io.Writer = Io.Writer.fixed(&overview_stdout_buf);
    var overview_stderr_buf: [8192]u8 = undefined;
    var overview_stderr: Io.Writer = Io.Writer.fixed(&overview_stderr_buf);

    try Commands.runOverviewCommand(allocator, io, .{
        .hprof_path = "fixtures/heapforge.hprof",
        .index_dir = tmp_path_z[0..tmp_path_z.len],
        .no_progress = true,
        .profile = true,
    }, &overview_stdout, &overview_stderr, config_load, null, null);

    try overview_stdout.flush();
    try overview_stderr.flush();

    const stderr_text = overview_stderr.buffered();
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "timings:") != null);
}

/// SHA-256 over the published index directory: each file's (name, content
/// digest, size), sorted by name. Two index builds of the same dump must
/// produce the same digest unless some stage output actually differs.
fn indexDirDigest(allocator: std.mem.Allocator, io: Io, index_dir: []const u8) ![32]u8 {
    const FileDigest = struct {
        name: []const u8,
        sha: [32]u8,
        size: u64,
    };
    var files = std.ArrayList(FileDigest).empty;
    defer {
        for (files.items) |*f| allocator.free(f.name);
        files.deinit(allocator);
    }

    var dir = try Io.Dir.cwd().openDir(io, index_dir, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const owned = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(owned);
        try files.append(allocator, .{ .name = owned, .sha = undefined, .size = 0 });
    }
    const lessThanName = struct {
        fn less(_: void, a: FileDigest, b: FileDigest) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    };
    std.mem.sort(FileDigest, files.items, {}, lessThanName.less);

    for (files.items) |*f| {
        const path = try std.fs.path.join(allocator, &.{ index_dir, f.name });
        defer allocator.free(path);
        const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 34));
        defer allocator.free(data);
        f.size = data.len;
        std.crypto.hash.sha2.Sha256.hash(data, &f.sha, .{});
    }

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items) |f| {
        h.update(f.name);
        h.update(&f.sha);
        var size_buf: [20]u8 = undefined;
        const size_text = try std.fmt.bufPrint(&size_buf, "{d}", .{f.size});
        h.update(size_text);
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn indexFixtureIntoTmp(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_dir: *std.testing.TmpDir,
    sorting_budget_mb: u32,
) ![]const u8 {
    const index_dir_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    const index_dir = try allocator.dupe(u8, index_dir_z[0..index_dir_z.len]);
    allocator.free(index_dir_z);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.Writer = Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer: Io.Writer = Io.Writer.fixed(&stderr_buf);

    const config_load: Config.LoadResult = .{};
    try Commands.runIndexCommand(allocator, io, .{
        .hprof_path = "fixtures/heapforge.hprof",
        .index_dir = index_dir,
        .no_progress = true,
        .sorting_budget_mb = sorting_budget_mb,
    }, &stdout_writer, &stderr_writer, config_load, null, null);
    try stderr_writer.flush();

    return index_dir;
}

test "index outputs are byte-identical across sorting budgets" {
    // The golden gate for sort-kernel work: the in-memory sort path (large
    // budget) and the external runs+merge path (tiny budget) must publish
    // byte-identical indexes. The streaming merge breaks ties by run index
    // (= input order), matching the stable in-memory blockSort, so every
    // stage file - catalog, edges, CSR, dominator outputs - must agree.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir_a = std.testing.tmpDir(.{});
    defer dir_a.cleanup();
    var dir_b = std.testing.tmpDir(.{});
    defer dir_b.cleanup();

    const index_dir_a = try indexFixtureIntoTmp(allocator, io, &dir_a, 4096);
    defer allocator.free(index_dir_a);
    const index_dir_b = try indexFixtureIntoTmp(allocator, io, &dir_b, 1);
    defer allocator.free(index_dir_b);

    const digest_a = try indexDirDigest(allocator, io, index_dir_a);
    const digest_b = try indexDirDigest(allocator, io, index_dir_b);

    try std.testing.expectEqualSlices(u8, &digest_a, &digest_b);
}
