//! Test-only helpers for running the production dominator engine over a
//! synthetic `Graphs.Graph`.
const std = @import("std");
const Io = std.Io;

const Backend = @import("Backend.zig");
const Dominator = @import("../Dominator.zig");
const Graphs = @import("Graphs.zig");
const Manifest = @import("../Manifest.zig");
const Preflight = @import("../Preflight.zig");
const Scanner = @import("../Scanner.zig");

pub const EngineOutput = struct {
    dom_parent: []u32,
    dom_order: []u32,
    retained: []u64,

    pub fn deinit(self: *EngineOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.dom_parent);
        allocator.free(self.dom_order);
        allocator.free(self.retained);
        self.* = .{
            .dom_parent = &.{},
            .dom_order = &.{},
            .retained = &.{},
        };
    }
};

/// Writes `out_offsets.bin`, `out_targets.bin`, `in_offsets.bin`,
/// `in_sources.bin`, and `catalog.bin` into `dir` so that the production
/// dominator stage can consume them.
pub fn writeCsrAndCatalog(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    graph: Graphs.Graph,
) !void {
    const n_nodes = graph.n_nodes;
    const n_objects = n_nodes - 1;
    const n_edges = graph.edges.len;

    var out_degrees = try allocator.alloc(u32, n_nodes);
    defer allocator.free(out_degrees);
    @memset(out_degrees, 0);
    var in_degrees = try allocator.alloc(u32, n_nodes);
    defer allocator.free(in_degrees);
    @memset(in_degrees, 0);

    for (graph.edges) |edge| {
        out_degrees[edge.source] += 1;
        in_degrees[edge.target] += 1;
    }

    var out_offsets = try allocator.alloc(u64, n_nodes + 1);
    defer allocator.free(out_offsets);
    var in_offsets = try allocator.alloc(u64, n_nodes + 1);
    defer allocator.free(in_offsets);

    out_offsets[0] = 0;
    in_offsets[0] = 0;
    for (0..n_nodes) |i| {
        out_offsets[i + 1] = out_offsets[i] + out_degrees[i];
        in_offsets[i + 1] = in_offsets[i] + in_degrees[i];
    }

    var out_next = try allocator.alloc(u64, n_nodes);
    defer allocator.free(out_next);
    var in_next = try allocator.alloc(u64, n_nodes);
    defer allocator.free(in_next);
    for (0..n_nodes) |i| {
        out_next[i] = out_offsets[i];
        in_next[i] = in_offsets[i];
    }

    var out_targets = try allocator.alloc(u32, n_edges);
    defer allocator.free(out_targets);
    var in_sources = try allocator.alloc(u32, n_edges);
    defer allocator.free(in_sources);

    for (graph.edges) |edge| {
        const out_idx = out_next[edge.source];
        out_next[edge.source] += 1;
        out_targets[out_idx] = edge.target;

        const in_idx = in_next[edge.target];
        in_next[edge.target] += 1;
        in_sources[in_idx] = edge.source;
    }

    // Sort adjacency lists to match the production CSR writer's output.
    for (0..n_nodes) |i| {
        const start = out_offsets[i];
        const end = out_offsets[i + 1];
        std.mem.sort(u32, out_targets[start..end], {}, std.sort.asc(u32));
    }
    for (0..n_nodes) |i| {
        const start = in_offsets[i];
        const end = in_offsets[i + 1];
        std.mem.sort(u32, in_sources[start..end], {}, std.sort.asc(u32));
    }

    const out_offsets_path = try path(allocator, dir, "out_offsets.bin");
    defer allocator.free(out_offsets_path);
    const out_targets_path = try path(allocator, dir, "out_targets.bin");
    defer allocator.free(out_targets_path);
    const in_offsets_path = try path(allocator, dir, "in_offsets.bin");
    defer allocator.free(in_offsets_path);
    const in_sources_path = try path(allocator, dir, "in_sources.bin");
    defer allocator.free(in_sources_path);
    const catalog_path = try path(allocator, dir, "catalog.bin");
    defer allocator.free(catalog_path);

    try writeU64File(io, out_offsets_path, out_offsets);
    try writeU32File(io, out_targets_path, out_targets);
    try writeU64File(io, in_offsets_path, in_offsets);
    try writeU32File(io, in_sources_path, in_sources);

    {
        const f = try Io.Dir.cwd().createFile(io, catalog_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var writer: Io.File.Writer = .init(f, io, &buf);
        for (0..n_objects) |ord| {
            try Scanner.writeCatalogRow(&writer.interface, .{
                .raw_id = @intCast(ord + 1),
                .source_offset = 0,
                .class_raw_id = 0,
                .shallow_size = graph.shallow[ord],
                .kind = .instance,
            });
        }
        try writer.flush();
    }
}

/// Runs the production dominator engine over `graph` and returns the three
/// logical output arrays. `dir` must be an existing directory; files are
/// written inside it and a `staging` subdirectory is created for the engine.
pub fn runEngine(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    graph: Graphs.Graph,
    options: Backend.Options,
) !EngineOutput {
    try writeCsrAndCatalog(allocator, io, dir, graph);

    const staging_dir = try std.fs.path.join(allocator, &.{ dir, "staging" });
    try Io.Dir.cwd().createDirPath(io, staging_dir);

    const job = try createTestJob(allocator, io, dir, staging_dir);
    defer job.deinit(allocator);

    const out_offsets_path = try path(allocator, dir, "out_offsets.bin");
    defer allocator.free(out_offsets_path);
    const out_targets_path = try path(allocator, dir, "out_targets.bin");
    defer allocator.free(out_targets_path);
    const in_offsets_path = try path(allocator, dir, "in_offsets.bin");
    defer allocator.free(in_offsets_path);
    const in_sources_path = try path(allocator, dir, "in_sources.bin");
    defer allocator.free(in_sources_path);
    const catalog_path = try path(allocator, dir, "catalog.bin");
    defer allocator.free(catalog_path);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try Dominator.run(
        allocator,
        io,
        &job,
        out_offsets_path,
        out_targets_path,
        in_offsets_path,
        in_sources_path,
        catalog_path,
        graph.n_nodes - 1,
        graph.edges.len,
        &diagnostics,
        options,
    );
    defer result.deinit(allocator);

    const dom_parent_data = try Io.Dir.cwd().readFileAlloc(io, result.dom_parent_path, allocator, .unlimited);
    defer allocator.free(dom_parent_data);
    const dom_order_data = try Io.Dir.cwd().readFileAlloc(io, result.dom_order_path, allocator, .unlimited);
    defer allocator.free(dom_order_data);
    const retained_data = try Io.Dir.cwd().readFileAlloc(io, result.retained_path, allocator, .unlimited);
    defer allocator.free(retained_data);

    const V = graph.n_nodes;
    const dom_parent = try allocator.alloc(u32, V);
    errdefer allocator.free(dom_parent);
    const retained = try allocator.alloc(u64, V);
    errdefer allocator.free(retained);

    for (0..V) |i| {
        dom_parent[i] = std.mem.readInt(u32, dom_parent_data[i * 4 ..][0..4], .little);
        retained[i] = std.mem.readInt(u64, retained_data[i * 8 ..][0..8], .little);
    }

    const dom_order = try allocator.alloc(u32, dom_order_data.len / 4);
    errdefer allocator.free(dom_order);
    for (0..dom_order.len) |i| {
        dom_order[i] = std.mem.readInt(u32, dom_order_data[i * 4 ..][0..4], .little);
    }

    return .{
        .dom_parent = dom_parent,
        .dom_order = dom_order,
        .retained = retained,
    };
}

/// Compute the in-degree histogram over distinct reachable predecessors.
/// Returns a 4-element array: [deg 0, deg 1, deg 2, deg 3+].
pub fn inDegreeHistogram(
    allocator: std.mem.Allocator,
    graph: Graphs.Graph,
) ![4]u64 {
    const V = graph.n_nodes;
    const root = V - 1;

    var succs = try allocator.alloc(std.ArrayList(u32), V);
    defer {
        for (succs) |*s| s.deinit(allocator);
        allocator.free(succs);
    }
    for (succs) |*s| s.* = std.ArrayList(u32).empty;

    for (graph.edges) |edge| {
        try succs[edge.source].append(allocator, edge.target);
    }

    const reachable = try computeReachability(allocator, V, root, succs);
    defer allocator.free(reachable);

    var buckets = [4]u64{ 0, 0, 0, 0 };
    var preds_seen = try allocator.alloc(u32, V);
    defer allocator.free(preds_seen);

    for (0..V) |v| {
        @memset(preds_seen, NONE);
        var distinct: u32 = 0;
        for (graph.edges) |edge| {
            if (edge.target != v) continue;
            if (edge.source == v) continue; // self-loop
            if (!reachable[edge.source]) continue; // unreachable
            const p = edge.source;
            if (preds_seen[p] == v) continue; // duplicate
            preds_seen[p] = @intCast(v);
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
    succs: []std.ArrayList(u32),
) ![]bool {
    const reachable = try allocator.alloc(bool, V);
    @memset(reachable, false);

    var stack = std.ArrayList(u32).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);
    reachable[root] = true;

    while (stack.items.len > 0) {
        const v = stack.pop() orelse unreachable;
        for (succs[@intCast(v)].items) |w| {
            if (w == v or w >= V) continue;
            if (!reachable[@intCast(w)]) {
                reachable[@intCast(w)] = true;
                try stack.append(allocator, w);
            }
        }
    }

    return reachable;
}

fn createTestJob(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    staging_dir: []const u8,
) !Preflight.Job {
    _ = io;
    const hprof = @import("../../hprof.zig");
    const header: hprof.Header.Header = .{ .id_size = 8, .timestamp = 0 };
    const fingerprint = try Manifest.computeFingerprint(allocator, "", header, 0);
    errdefer fingerprint.deinit(allocator);

    return .{
        .source_path = "test.hprof",
        .index_dir = index_dir,
        .staging_dir = staging_dir,
        .budget_bytes = 1024 * 1024,
        .dominator_budget_bytes = 1024 * 1024 * 1024,
        .fingerprint = fingerprint,
        .header = header,
    };
}

fn path(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ dir, name });
}

fn writeU32File(io: Io, path_arg: []const u8, values: []const u32) !void {
    const f = try Io.Dir.cwd().createFile(io, path_arg, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try writer.interface.writeAll(&bytes);
    }
    try writer.flush();
}

fn writeU64File(io: Io, path_arg: []const u8, values: []const u64) !void {
    const f = try Io.Dir.cwd().createFile(io, path_arg, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try writer.interface.writeAll(&bytes);
    }
    try writer.flush();
}

const NONE = std.math.maxInt(u32);

test "TestSupport runs the engine on a diamond" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.diamond(allocator, 0);
    defer graph.deinit(allocator);

    var output = try runEngine(allocator, io, tmp_path, graph, .{});
    defer output.deinit(allocator);

    const root = graph.n_nodes - 1;
    try std.testing.expectEqual(root, output.dom_order[0]);
    try std.testing.expectEqual(Dominator.NONE, output.dom_parent[root]);
}
