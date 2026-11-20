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

test "index progress checkpoints carry intra-step percent on non-TTY stderr" {
    // A terminal renders the live bar instead of per-line checkpoints, so
    // the line-format assertion only applies when stderr is piped.
    if (@import("../Cli.zig").isStderrTty(std.testing.io)) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const config_load: Config.LoadResult = .{};

    var index_stdout_buf: [4096]u8 = undefined;
    var index_stdout: Io.Writer = Io.Writer.fixed(&index_stdout_buf);
    var index_stderr_buf: [16384]u8 = undefined;
    var index_stderr: Io.Writer = Io.Writer.fixed(&index_stderr_buf);

    try Commands.runIndexCommand(allocator, io, .{
        .hprof_path = "fixtures/heapforge.hprof",
        .index_dir = tmp_path_z[0..tmp_path_z.len],
        .no_progress = false,
        .profile = false,
    }, &index_stdout, &index_stderr, config_load, null, null);

    try index_stderr.flush();
    const stderr_text = index_stderr.buffered();

    // Step boundaries still land as plain checkpoint lines.
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "] scanning heap dump") != null);
    // The scan step reports its position, appending the command-wide
    // percent to the label.
    var it = std.mem.splitScalar(u8, stderr_text, '\n');
    var found_percent_line = false;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "scanning heap dump") != null and std.mem.endsWith(u8, line, "%")) {
            found_percent_line = true;
            break;
        }
    }
    try std.testing.expect(found_percent_line);
}
