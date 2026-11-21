//! Developer-only dominator benchmark harness.
//!
//! Usage:
//!   zig build bench -- dominator --dump <path.hprof> --algorithm chk|lt|both
//!       --cache cold|warm [--reuse-index] --json out.json
//!   zig build bench -- dominator --synthetic <n_nodes> --algorithm chk|lt|both
//!       --json out.json
//!
//! `--synthetic` writes the stage files for a deterministic dense random
//! graph with `n_nodes` ordinals (no hprof, no scan), so the stage can be
//! measured at a chosen scale without a dump.
//!
//! Per algorithm this reports two measurements:
//!   * `backend_ms`: the backend alone, running on CSR data already read
//!     into RAM. Isolates the algorithm from I/O and page-fault noise.
//!   * `stage_ms`: the production `Dominator.run` path, including the
//!     demand-paged CSR/catalog mappings, the retained sweep, and the
//!     output writes. `minor_faults` / `major_faults` deltas around this
//!     pass feed the in-CSR re-fault escalation decision documented in
//!     Dominator.zig (prefault in_offsets vs. dfn-ordered pred array):
//!     a cold-vs-warm `stage_ms` ratio near 1 and near-zero major faults
//!     mean the page cache absorbed the pass and no escalation is worth
//!     its memory. `--cache cold` drops the stage files from the page
//!     cache (fadvise DONTNEED) before each stage pass so the two runs
//!     are actually comparable.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Backend = @import("Backend.zig");
const Chk = @import("Chk.zig");
const Commands = @import("../../Commands.zig");
const Config = @import("../../Config.zig").Config;
const CsrView = @import("CsrView.zig").CsrView;
const Dominator = @import("../Dominator.zig");
const Graphs = @import("Graphs.zig");
const Lt = @import("Lt.zig");
const Manifest = @import("../Manifest.zig");
const Numbering = @import("Numbering.zig");
const Preflight = @import("../Preflight.zig");
const TestSupport = @import("TestSupport.zig");

const NONE = std.math.maxInt(u32);

const stage_file_names = [_][]const u8{
    "out_offsets.bin",
    "out_targets.bin",
    "in_offsets.bin",
    "in_sources.bin",
    "catalog.bin",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    var dump_path: ?[]const u8 = null;
    var json_path: ?[]const u8 = null;
    var cache_mode: []const u8 = "warm";
    var algorithm_arg: []const u8 = "both";
    var reuse_index = false;
    var synthetic_nodes: ?u32 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dump")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            dump_path = args[i];
        } else if (std.mem.eql(u8, arg, "--synthetic")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            synthetic_nodes = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            json_path = args[i];
        } else if (std.mem.eql(u8, arg, "--cache")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            cache_mode = args[i];
        } else if (std.mem.eql(u8, arg, "--algorithm")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            algorithm_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--reuse-index")) {
            reuse_index = true;
        }
    }

    const dump: []const u8 = if (dump_path) |p| p else if (synthetic_nodes) |n| blk: {
        break :blk try std.fmt.allocPrint(allocator, "synthetic-{d}-nodes", .{n});
    } else {
        std.debug.print("usage: bench dominator --dump <path.hprof> | --synthetic <n> --json out.json [--algorithm chk|lt|both] [--cache cold|warm] [--reuse-index]\n", .{});
        return error.InvalidArgument;
    };
    const out_path = json_path orelse {
        std.debug.print("usage: bench dominator --dump <path.hprof> --json out.json [--algorithm chk|lt|both] [--cache cold|warm] [--reuse-index]\n", .{});
        return error.InvalidArgument;
    };
    var algorithms: [2]bool = .{ true, true }; // [chk, lt]
    if (std.mem.eql(u8, algorithm_arg, "chk")) {
        algorithms = .{ true, false };
    } else if (std.mem.eql(u8, algorithm_arg, "lt")) {
        algorithms = .{ false, true };
    } else if (!std.mem.eql(u8, algorithm_arg, "both")) {
        std.debug.print("unknown --algorithm '{s}' (expected chk, lt, or both)\n", .{algorithm_arg});
        return error.InvalidArgument;
    }
    const cold = std.mem.eql(u8, cache_mode, "cold");

    const index_dir = try std.fs.path.join(allocator, &.{ "/tmp", "bench_dominator" });
    defer allocator.free(index_dir);

    // `--reuse-index` measures against an index already built at
    // /tmp/bench_dominator: the pipeline buffers are the peak of this
    // process's memory, and re-paying them just to re-measure backends can
    // push a small box over its limit.
    var manifest: Manifest.IndexManifest = undefined;
    if (reuse_index) {
        std.debug.print("reusing existing index at {s}\n", .{index_dir});
        manifest = try readManifest(allocator, io, index_dir);
    } else if (synthetic_nodes) |n| {
        try Io.Dir.cwd().deleteTree(io, index_dir);
        try Io.Dir.cwd().createDirPath(io, index_dir);
        manifest = try buildSyntheticIndex(allocator, io, index_dir, n);
    } else {
        try Io.Dir.cwd().deleteTree(io, index_dir);
        try Io.Dir.cwd().createDirPath(io, index_dir);

        // Build the index so the CSR files exist.
        try runHuntIndex(allocator, io, dump, index_dir);
        manifest = try readManifest(allocator, io, index_dir);
    }

    const V = manifest.n_objects + 1;

    // Read CSR into memory for the backend-isolated measurement.
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

    var chk_timing: ?Timing = null;
    var lt_timing: ?Timing = null;
    var chk_stage: ?StageTiming = null;
    var lt_stage: ?StageTiming = null;

    if (algorithms[0]) {
        chk_timing = try runMeasurement(allocator, io, V, &out_view, &in_view, .chk);
        chk_stage = try runStageMeasurement(allocator, io, index_dir, dump, manifest, .chk, cold);
    }
    if (algorithms[1]) {
        lt_timing = try runMeasurement(allocator, io, V, &out_view, &in_view, .lt);
        lt_stage = try runStageMeasurement(allocator, io, index_dir, dump, manifest, .lt, cold);
    }

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
    try writer.interface.print("  \"max_dfs_depth\": {d},\n", .{if (chk_timing) |t| t.max_depth else lt_timing.?.max_depth});
    try writer.interface.print("  \"in_degree_histogram\": {{ \"0\": {d}, \"1\": {d}, \"2\": {d}, \"3+\": {d} }},\n", .{
        histogram[0], histogram[1], histogram[2], histogram[3],
    });
    if (chk_timing) |t| {
        try writeBackendBlock(&writer.interface, "chk", t, chk_stage.?);
    }
    if (lt_timing) |t| {
        try writeBackendBlock(&writer.interface, "lt", t, lt_stage.?);
    }
    try writer.interface.print("  \"peak_rss_bytes\": {d},\n", .{getPeakRss()});
    try writer.interface.print("  \"cache_mode\": \"{s}\"\n", .{cache_mode});
    try writer.interface.print("}}\n", .{});
    try writer.flush();
}

fn writeBackendBlock(
    writer: *Io.Writer,
    name: []const u8,
    timing: Timing,
    stage: StageTiming,
) !void {
    try writer.print("  \"{s}\": {{\n", .{name});
    try writer.print("    \"n_reachable\": {d},\n", .{timing.n_reachable});
    // CHK sweep statistics.
    try writer.print("    \"chk_iterations\": {d},\n", .{timing.stats.iterations});
    try writer.print("    \"nodes_changed\": {d},\n", .{timing.stats.nodes_changed});
    try writer.print("    \"shortcut_nodes\": {d},\n", .{timing.stats.shortcut_nodes});
    try writer.print("    \"intersect_steps_total\": {d},\n", .{timing.stats.intersect_steps_total});
    try writer.print("    \"intersect_steps_max\": {d},\n", .{timing.stats.intersect_steps_max});
    // LT eval/link statistics.
    try writer.print("    \"eval_calls\": {d},\n", .{timing.stats.eval_calls});
    try writer.print("    \"compress_steps\": {d},\n", .{timing.stats.compress_steps});
    try writer.print("    \"compress_steps_max\": {d},\n", .{timing.stats.compress_steps_max});
    try writer.print("    \"edges_processed\": {d},\n", .{timing.stats.edges_processed});
    try writer.print("    \"backend_ms\": {{ \"dfs\": {d}, \"sweeps\": {d}, \"total\": {d} }},\n", .{ timing.dfs_ms, timing.sweeps_ms, timing.total_ms });
    try writer.print("    \"stage_ms\": {d},\n", .{stage.stage_ms});
    try writer.print("    \"stage_faults\": {{ \"minor\": {d}, \"major\": {d} }},\n", .{ stage.minor_faults, stage.major_faults });
    try writer.print("    \"stage_n_reachable\": {d}\n", .{stage.n_reachable});
    try writer.print("  }},\n", .{});
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
        .compute_dominators = false,
        // Constrained budgets: this harness holds everything in one arena,
        // so the default 4 GiB sort budget is a silent OOM on small boxes.
        .sorting_budget_mb = 1024,
        .dominator_budget_mb = 1024,
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

/// Builds the stage files for a dense synthetic tier directly (no hprof, no
/// scan): a deterministic random graph with `n_nodes` ordinals and
/// `n_nodes + n_nodes/8` edges, the edges-per-object ratio of the reference
/// dumps. The DFS depth profile (a random recursive tree, depth ~ln n),
/// CSR sizes, and catalog rows are representative of a dense heap at the
/// chosen scale, and identical across runs for a fixed seed.
fn buildSyntheticIndex(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    n_nodes: u32,
) !Manifest.IndexManifest {
    if (n_nodes < 2) return error.InvalidArgument;
    const n_edges: u32 = n_nodes + n_nodes / 8;
    var graph = try Graphs.randomGraph(allocator, n_nodes, n_edges, 0x5eed_c0de);
    defer graph.deinit(allocator);
    try TestSupport.writeCsrAndCatalog(allocator, io, index_dir, graph);

    const hprof = @import("../../hprof.zig");
    const header: hprof.Header.Header = .{ .id_size = 8, .timestamp = 0 };
    return .{
        .fingerprint = try Manifest.computeFingerprint(allocator, "", header, 0),
        .n_objects = n_nodes - 1,
        .n_edges = n_edges,
        .virtual_root_ordinal = n_nodes - 1,
        .source_path = null,
        .has_dominators = false,
    };
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

const StageTiming = struct {
    stage_ms: u64,
    minor_faults: u64,
    major_faults: u64,
    n_reachable: u64,
};

const FaultCounters = struct {
    minor: u64,
    major: u64,
};

fn faultCounters() FaultCounters {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    return .{
        .minor = @intCast(@max(usage.minflt, 0)),
        .major = @intCast(@max(usage.majflt, 0)),
    };
}

fn nowMs(io: Io) u64 {
    // Monotonic milliseconds via the Io clock (same source as Commands'
    // stage timings), keeping the bench free of any libc dependency.
    const ns = Io.Timestamp.now(io, .awake).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_ms));
}

fn runMeasurement(
    allocator: std.mem.Allocator,
    io: Io,
    V: u64,
    out_view: *const CsrView,
    in_view: *const CsrView,
    algorithm: Backend.Algorithm,
) !Timing {
    const start_total = nowMs(io);

    const numbering_options: Numbering.Options = .{
        .emit_dfs_tree = algorithm == .lt,
    };
    var numbering = try Numbering.compute(allocator, @intCast(V), out_view, numbering_options);
    defer numbering.deinit(allocator);
    const dfs_ms = nowMs(io) - start_total;

    const start_sweeps = nowMs(io);
    const ctx: Backend.Context = .{
        .allocator = allocator,
        .n_nodes = @intCast(V),
        .root = @intCast(V - 1),
        .n_reachable = numbering.n_reachable,
        .rpo_num = numbering.rpo_num,
        .rpo_vertex = numbering.rpo_vertex,
        .reachable = numbering.reachable,
        .dfn = numbering.dfn,
        .dfn_vertex = numbering.dfn_vertex,
        .parent = numbering.parent,
        .max_dfs_depth = numbering.max_depth,
        .options = .{ .algorithm = algorithm },
        .out_edges = out_view,
        .in_edges = in_view,
    };
    const backend_result = switch (algorithm) {
        .chk => try Chk.compute(&ctx),
        .lt => try Lt.compute(&ctx),
    };
    defer allocator.free(backend_result.idom);
    const sweeps_ms = nowMs(io) - start_sweeps;

    var stats = backend_result.stats;
    stats.edges_processed = estimateEdgesProcessed(in_view, numbering.reachable, @intCast(V));

    return .{
        .n_reachable = numbering.n_reachable,
        .max_depth = numbering.max_depth,
        .stats = stats,
        .dfs_ms = dfs_ms,
        .sweeps_ms = sweeps_ms,
        .total_ms = nowMs(io) - start_total,
        .peak_rss = getPeakRss(),
    };
}

/// Runs the production dominator stage end to end (demand-paged CSR and
/// catalog, backend, retained sweep, output writes) and captures the fault
/// deltas around it. This is the measurement the in-CSR re-fault escalation
/// decision in Dominator.zig is judged against.
fn runStageMeasurement(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    dump: []const u8,
    manifest: Manifest.IndexManifest,
    algorithm: Backend.Algorithm,
    cold: bool,
) !StageTiming {
    if (cold) dropStageFileCache(allocator, io, index_dir);

    var job = blk: {
        const staging_dir = try std.fs.path.join(allocator, &.{ index_dir, "bench-staging" });
        errdefer allocator.free(staging_dir);
        try Io.Dir.cwd().createDirPath(io, staging_dir);
        break :blk Preflight.Job{
            .source_path = dump,
            .index_dir = index_dir,
            .staging_dir = staging_dir,
            .budget_bytes = 1024 * 1024 * 1024,
            .dominator_budget_bytes = 64 * 1024 * 1024 * 1024,
            .fingerprint = try manifest.fingerprint.clone(allocator),
            .header = .{
                .id_size = manifest.fingerprint.id_size,
                .timestamp = manifest.fingerprint.hprof_timestamp,
            },
        };
    };
    defer job.deinit(allocator);

    const out_offsets_path = try std.fs.path.join(allocator, &.{ index_dir, "out_offsets.bin" });
    defer allocator.free(out_offsets_path);
    const out_targets_path = try std.fs.path.join(allocator, &.{ index_dir, "out_targets.bin" });
    defer allocator.free(out_targets_path);
    const in_offsets_path = try std.fs.path.join(allocator, &.{ index_dir, "in_offsets.bin" });
    defer allocator.free(in_offsets_path);
    const in_sources_path = try std.fs.path.join(allocator, &.{ index_dir, "in_sources.bin" });
    defer allocator.free(in_sources_path);
    const catalog_path = try std.fs.path.join(allocator, &.{ index_dir, "catalog.bin" });
    defer allocator.free(catalog_path);

    const before = faultCounters();
    const start = nowMs(io);
    var diagnostics: Manifest.Diagnostics = .{};
    var result = try Dominator.run(
        allocator,
        io,
        &job,
        out_offsets_path,
        out_targets_path,
        in_offsets_path,
        in_sources_path,
        catalog_path,
        manifest.n_objects,
        manifest.n_edges,
        &diagnostics,
        .{ .algorithm = algorithm },
    );
    defer result.deinit(allocator);
    const stage_ms = nowMs(io) - start;
    const after = faultCounters();

    return .{
        .stage_ms = stage_ms,
        .minor_faults = after.minor - before.minor,
        .major_faults = after.major - before.major,
        .n_reachable = result.n_reachable,
    };
}

/// Best-effort page-cache drop for the stage files so a cold run is
/// reproducible without root privileges. Only meaningful on Linux.
fn dropStageFileCache(allocator: std.mem.Allocator, io: Io, index_dir: []const u8) void {
    if (builtin.os.tag != .linux) return;
    for (stage_file_names) |name| {
        const path = std.fs.path.join(allocator, &.{ index_dir, name }) catch continue;
        defer allocator.free(path);
        const file = Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer file.close(io);
        // Ignore failures: a best-effort drop still beats benching a warm
        // cache by accident.
        _ = std.os.linux.fadvise(file.handle, 0, 0, std.posix.POSIX_FADV.DONTNEED);
    }
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
    // Dedup marker: seen[p] holds the v of the last iteration that visited
    // p, so one initial clear suffices — a per-node memset would make this
    // O(V^2), which is hours at the 5.5M-node workbench tier.
    @memset(seen, NONE);

    for (0..V) |v| {
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
