//! Developer-only dominator benchmark harness.
//!
//! Usage:
//!   zig build bench -- dominator --dump <path.hprof> --cache cold|warm --json out.json
const std = @import("std");
const Io = std.Io;

const Backend = @import("Backend.zig");
const Chk = @import("Chk.zig");
const Commands = @import("../../Commands.zig");
const Config = @import("../../Config.zig").Config;
const CsrView = @import("CsrView.zig").CsrView;
const Manifest = @import("../Manifest.zig");
const Numbering = @import("Numbering.zig");

const NONE = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    var dump_path: ?[]const u8 = null;
    var json_path: ?[]const u8 = null;
    var cache_mode: []const u8 = "warm";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dump")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            dump_path = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            json_path = args[i];
        } else if (std.mem.eql(u8, arg, "--cache")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            cache_mode = args[i];
        }
    }

    const dump = dump_path orelse {
        std.debug.print("usage: bench dominator --dump <path.hprof> --json out.json [--cache cold|warm]\n", .{});
        return error.InvalidArgument;
    };
    const out_path = json_path orelse {
        std.debug.print("usage: bench dominator --dump <path.hprof> --json out.json [--cache cold|warm]\n", .{});
        return error.InvalidArgument;
    };

    const index_dir = try std.fs.path.join(allocator, &.{ "/tmp", "bench_dominator" });
    defer allocator.free(index_dir);
    try Io.Dir.cwd().deleteTree(io, index_dir);
    try Io.Dir.cwd().createDirPath(io, index_dir);

    // Build the index so the CSR files exist.
    try runHuntIndex(allocator, io, dump, index_dir);

    const manifest = try readManifest(allocator, io, index_dir);

    const V = manifest.n_objects + 1;

    // Read CSR into memory.
    const out_offsets = try readFileBytes(allocator, io, index_dir, "out_offsets.bin");
    defer allocator.free(out_offsets);
    const out_targets = try readFileBytes(allocator, io, index_dir, "out_targets.bin");
    defer allocator.free(out_targets);
    const in_offsets = try readFileBytes(allocator, io, index_dir, "in_offsets.bin");
    defer allocator.free(in_offsets);
    const in_sources = try readFileBytes(allocator, io, index_dir, "in_sources.bin");
    defer allocator.free(in_sources);

    const out_view = CsrView.init(@intCast(V), out_offsets, out_targets);
    const in_view = CsrView.init(@intCast(V), in_offsets, in_sources);

    const timing = try runMeasurement(allocator, V, &out_view, &in_view);

    // In-degree histogram over distinct reachable predecessors.
    const histogram = try computeInDegreeHistogram(allocator, @intCast(V), &out_view, &in_view);

    const f = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);

    try writer.interface.print("{{\n", .{});
    try writer.interface.print("  \"dump\": \"{s}\",\n", .{dump});
    try writer.interface.print("  \"n_objects\": {d},\n", .{manifest.n_objects});
    try writer.interface.print("  \"n_edges\": {d},\n", .{manifest.n_edges});
    try writer.interface.print("  \"n_reachable\": {d},\n", .{timing.n_reachable});
    try writer.interface.print("  \"max_dfs_depth\": {d},\n", .{timing.max_depth});
    try writer.interface.print("  \"in_degree_histogram\": {{ \"0\": {d}, \"1\": {d}, \"2\": {d}, \"3+\": {d} }},\n", .{
        histogram[0], histogram[1], histogram[2], histogram[3],
    });
    try writer.interface.print("  \"chk_iterations\": {d},\n", .{timing.stats.iterations});
    try writer.interface.print("  \"nodes_changed\": {d},\n", .{timing.stats.nodes_changed});
    try writer.interface.print("  \"edges_processed\": {d},\n", .{timing.stats.edges_processed});
    try writer.interface.print("  \"intersect_steps_total\": {d},\n", .{timing.stats.intersect_steps_total});
    try writer.interface.print("  \"intersect_steps_max\": {d},\n", .{timing.stats.intersect_steps_max});
    try writer.interface.print("  \"shortcut_nodes\": {d},\n", .{timing.stats.shortcut_nodes});
    try writer.interface.print("  \"stage_ms\": {{ \"dfs\": {d}, \"sweeps\": {d}, \"total\": {d} }},\n", .{ timing.dfs_ms, timing.sweeps_ms, timing.total_ms });
    try writer.interface.print("  \"peak_rss_bytes\": {d},\n", .{timing.peak_rss});
    try writer.interface.print("  \"cache_mode\": \"{s}\"\n", .{cache_mode});
    try writer.interface.print("}}\n", .{});
    try writer.flush();
}

fn runHuntIndex(
    allocator: std.mem.Allocator,
    io: Io,
    dump: []const u8,
    index_dir: []const u8,
) !void {
    var stdout_buf: Io.Writer.Allocating = .init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf: Io.Writer.Allocating = .init(allocator);
    defer stderr_buf.deinit();

    const config_load: Config.LoadResult = .{ .config = .{} };
    defer config_load.deinit(allocator);

    const options: Commands.IndexOptions = .{
        .hprof_path = dump,
        .index_dir = index_dir,
        .force = true,
        .no_progress = true,
        .compute_dominators = true,
    };

    Commands.runIndexCommand(
        allocator,
        io,
        options,
        &stdout_buf.writer,
        &stderr_buf.writer,
        config_load,
        null,
        null,
    ) catch {
        std.debug.print("hunt index failed:\n{s}\n", .{stderr_buf.writer.buffer[0..stderr_buf.writer.end]});
        return error.IndexFailed;
    };
}

fn readManifest(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
) !Manifest.IndexManifest {
    const path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
    defer allocator.free(path);
    const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);
    return try Manifest.IndexManifest.parse(allocator, data);
}

const Timing = struct {
    n_reachable: u32,
    max_depth: u32,
    stats: Backend.Stats,
    dfs_ms: u64,
    sweeps_ms: u64,
    total_ms: u64,
    peak_rss: u64,
};

fn nowMs() u64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @intCast(tv.sec * std.time.ms_per_s + @divFloor(tv.usec, std.time.us_per_ms));
}

fn runMeasurement(
    allocator: std.mem.Allocator,
    V: u64,
    out_view: *const CsrView,
    in_view: *const CsrView,
) !Timing {
    const start_total = nowMs();

    var numbering = try Numbering.compute(allocator, @intCast(V), out_view);
    defer numbering.deinit(allocator);
    const dfs_ms = nowMs() - start_total;

    const start_sweeps = nowMs();
    const ctx: Backend.Context = .{
        .allocator = allocator,
        .n_nodes = @intCast(V),
        .root = @intCast(V - 1),
        .n_reachable = numbering.n_reachable,
        .rpo_num = numbering.rpo_num,
        .rpo_vertex = numbering.rpo_vertex,
        .reachable = numbering.reachable,
        .options = .{},
        .out_edges = out_view,
        .in_edges = in_view,
    };
    const backend_result = try Chk.compute(&ctx);
    defer allocator.free(backend_result.idom);
    const sweeps_ms = nowMs() - start_sweeps;

    var stats = backend_result.stats;
    stats.edges_processed = estimateEdgesProcessed(in_view, numbering.reachable, @intCast(V));

    return .{
        .n_reachable = numbering.n_reachable,
        .max_depth = numbering.max_depth,
        .stats = stats,
        .dfs_ms = dfs_ms,
        .sweeps_ms = sweeps_ms,
        .total_ms = nowMs() - start_total,
        .peak_rss = getPeakRss(),
    };
}

fn estimateEdgesProcessed(
    in_view: *const CsrView,
    reachable: []const bool,
    V: u32,
) u64 {
    var total: u64 = 0;
    for (0..V) |v| {
        if (!reachable[v]) continue;
        total += in_view.edges(@intCast(v)).len;
    }
    return total;
}

fn computeInDegreeHistogram(
    allocator: std.mem.Allocator,
    V: u32,
    out_view: *const CsrView,
    in_view: *const CsrView,
) ![4]u64 {
    const reachable = try computeReachability(allocator, V, @intCast(V - 1), out_view);
    defer allocator.free(reachable);

    var buckets = [4]u64{ 0, 0, 0, 0 };
    var seen = try allocator.alloc(u32, V);
    defer allocator.free(seen);

    for (0..V) |v| {
        @memset(seen, NONE);
        var distinct: u32 = 0;
        const preds = in_view.edges(@intCast(v));
        for (preds) |p| {
            if (p == v or p >= V) continue;
            if (!reachable[p]) continue;
            if (seen[p] == @as(u32, @intCast(v))) continue;
            seen[p] = @intCast(v);
            distinct += 1;
            if (distinct >= 3) break;
        }
        buckets[@min(3, distinct)] += 1;
    }

    return buckets;
}

fn computeReachability(
    allocator: std.mem.Allocator,
    V: u32,
    root: u32,
    out_view: *const CsrView,
) ![]bool {
    const reachable = try allocator.alloc(bool, V);
    @memset(reachable, false);

    var stack = std.ArrayList(u32).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);
    reachable[root] = true;

    while (stack.items.len > 0) {
        const v = stack.pop() orelse unreachable;
        for (out_view.edges(v)) |w| {
            if (w == v or w >= V) continue;
            if (!reachable[w]) {
                reachable[w] = true;
                try stack.append(allocator, w);
            }
        }
    }

    return reachable;
}

fn readFileBytes(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    return try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

fn getPeakRss() u64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    return @intCast(usage.maxrss);
}
