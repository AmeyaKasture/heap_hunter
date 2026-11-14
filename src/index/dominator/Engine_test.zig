//! Characterisation and property tests for the dominator engine.
const std = @import("std");
const Io = std.Io;

const Backend = @import("Backend.zig");
const Dominator = @import("../Dominator.zig");
const Graphs = @import("Graphs.zig");
const Oracle = @import("Oracle.zig");
const TestSupport = @import("TestSupport.zig");

const NONE = std.math.maxInt(u32);

const EngineOracleResult = struct {
    engine: TestSupport.EngineOutput,
    oracle: []u32,
    logical_idom: []u32,
};

fn runEngineAndOracle(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_path: []const u8,
    graph: Graphs.Graph,
) !EngineOracleResult {
    return runEngineAndOracleWithOptions(allocator, io, tmp_path, graph, .{});
}

fn runEngineAndOracleWithOptions(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_path: []const u8,
    graph: Graphs.Graph,
    options: Backend.Options,
) !EngineOracleResult {
    var engine = try TestSupport.runEngine(allocator, io, tmp_path, graph, options);
    errdefer engine.deinit(allocator);
    const logical_idom = try toLogicalIdom(allocator, engine.dom_parent, engine.dom_order, graph.n_nodes);
    errdefer allocator.free(logical_idom);
    const oracle = try Oracle.immediateDominators(allocator, graph);
    errdefer allocator.free(oracle);
    return .{ .engine = engine, .oracle = oracle, .logical_idom = logical_idom };
}

/// The engine writes `NONE` for reachable nodes whose immediate dominator is
/// the virtual root. The oracle (and the mathematical definition) uses the
/// root ordinal. Convert the on-disk form to the logical form so the two can
/// be compared.
fn toLogicalIdom(
    allocator: std.mem.Allocator,
    dom_parent: []const u32,
    dom_order: []const u32,
    n_nodes: u32,
) ![]u32 {
    const root = n_nodes - 1;
    const logical = try allocator.alloc(u32, dom_parent.len);

    var reachable = try allocator.alloc(bool, dom_parent.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    reachable[root] = true;
    for (dom_order) |node| {
        reachable[node] = true;
    }

    for (0..dom_parent.len) |i| {
        const v: u32 = @intCast(i);
        const p = dom_parent[i];
        logical[i] = if (p == NONE and reachable[v] and v != root) root else p;
    }
    return logical;
}

test "dominator oracle agrees with engine on a linear chain" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.linearChain(allocator, 0);
    defer graph.deinit(allocator);

    var both = try runEngineAndOracle(allocator, io, tmp_path, graph);
    defer both.engine.deinit(allocator);
    defer allocator.free(both.oracle);
    defer allocator.free(both.logical_idom);

    try std.testing.expectEqualSlices(u32, both.oracle, both.logical_idom);
}

test "dominator oracle agrees with engine on a diamond" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.diamond(allocator, 0);
    defer graph.deinit(allocator);

    var both = try runEngineAndOracle(allocator, io, tmp_path, graph);
    defer both.engine.deinit(allocator);
    defer allocator.free(both.oracle);
    defer allocator.free(both.logical_idom);

    try std.testing.expectEqualSlices(u32, both.oracle, both.logical_idom);
}

test "dominator oracle agrees with engine on two roots into one object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.twoRootsIntoOne(allocator, 0);
    defer graph.deinit(allocator);

    var both = try runEngineAndOracle(allocator, io, tmp_path, graph);
    defer both.engine.deinit(allocator);
    defer allocator.free(both.oracle);
    defer allocator.free(both.logical_idom);

    try std.testing.expectEqualSlices(u32, both.oracle, both.logical_idom);
}

test "dominator oracle agrees with engine on a reference cycle" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.cycle(allocator, 0);
    defer graph.deinit(allocator);

    var both = try runEngineAndOracle(allocator, io, tmp_path, graph);
    defer both.engine.deinit(allocator);
    defer allocator.free(both.oracle);
    defer allocator.free(both.logical_idom);

    try std.testing.expectEqualSlices(u32, both.oracle, both.logical_idom);
}

test "dominator oracle agrees with engine on a self loop" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.selfLoop(allocator, 0);
    defer graph.deinit(allocator);

    var both = try runEngineAndOracle(allocator, io, tmp_path, graph);
    defer both.engine.deinit(allocator);
    defer allocator.free(both.oracle);
    defer allocator.free(both.logical_idom);

    try std.testing.expectEqualSlices(u32, both.oracle, both.logical_idom);
}

test "dominator oracle agrees with engine with an unreachable island" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.unreachableIsland(allocator, 0);
    defer graph.deinit(allocator);

    var both = try runEngineAndOracle(allocator, io, tmp_path, graph);
    defer both.engine.deinit(allocator);
    defer allocator.free(both.oracle);
    defer allocator.free(both.logical_idom);

    try std.testing.expectEqualSlices(u32, both.oracle, both.logical_idom);
}

test "dominator engine produces identical output across repeated runs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.diamondLadder(allocator, 0);
    defer graph.deinit(allocator);

    var first = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{});
    defer first.deinit(allocator);

    var second = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{});
    defer second.deinit(allocator);

    try std.testing.expectEqualSlices(u32, first.dom_parent, second.dom_parent);
    try std.testing.expectEqualSlices(u32, first.dom_order, second.dom_order);
    try std.testing.expectEqualSlices(u64, first.retained, second.retained);
}

test "dominator shortcut does not change the answer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.layeredDag(allocator, 0);
    defer graph.deinit(allocator);

    var with_shortcut = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{ .use_shortcut = true });
    defer with_shortcut.deinit(allocator);

    var without_shortcut = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{ .use_shortcut = false });
    defer without_shortcut.deinit(allocator);

    try std.testing.expectEqualSlices(u32, with_shortcut.dom_parent, without_shortcut.dom_parent);
    try std.testing.expectEqualSlices(u32, with_shortcut.dom_order, without_shortcut.dom_order);
    try std.testing.expectEqualSlices(u64, with_shortcut.retained, without_shortcut.retained);
}

test "dominator result does not depend on the edge order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.randomGraph(allocator, 20, 40, 123);
    defer graph.deinit(allocator);

    var baseline = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{});
    defer baseline.deinit(allocator);

    // Shuffle the edge array in-place with a different seed.
    var prng = std.Random.DefaultPrng.init(456);
    prng.random().shuffle(Graphs.Edge, graph.edges);

    var shuffled = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{});
    defer shuffled.deinit(allocator);

    try std.testing.expectEqualSlices(u32, baseline.dom_parent, shuffled.dom_parent);
    try std.testing.expectEqualSlices(u64, baseline.retained, shuffled.retained);
}

test "dominator relation survives a renumbering of the ordinals" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var graph = try Graphs.randomGraph(allocator, 20, 40, 789);
    defer graph.deinit(allocator);

    var original = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{});
    defer original.deinit(allocator);

    // Build a random permutation of ordinals 0..V-1 that keeps the root fixed.
    const V = graph.n_nodes;
    const root = V - 1;
    const original_idom = try toLogicalIdom(allocator, original.dom_parent, original.dom_order, V);
    defer allocator.free(original_idom);
    var perm = try allocator.alloc(u32, V);
    defer allocator.free(perm);
    for (0..V) |i| perm[i] = @intCast(i);
    var prng = std.Random.DefaultPrng.init(101112);
    prng.random().shuffle(u32, perm[0 .. V - 1]);

    var inv_perm = try allocator.alloc(u32, V);
    defer allocator.free(inv_perm);
    for (0..V) |i| inv_perm[perm[i]] = @intCast(i);

    // Remap edges and shallow sizes.
    var new_edges = try allocator.alloc(Graphs.Edge, graph.edges.len);
    defer allocator.free(new_edges);
    for (graph.edges, 0..) |edge, i| {
        new_edges[i] = .{
            .source = perm[edge.source],
            .target = perm[edge.target],
        };
    }
    var new_shallow = try allocator.alloc(u32, V);
    defer allocator.free(new_shallow);
    for (0..V) |old| new_shallow[perm[old]] = graph.shallow[old];

    const remapped_graph = Graphs.Graph{
        .n_nodes = V,
        .edges = new_edges,
        .shallow = new_shallow,
    };

    var remapped = try TestSupport.runEngine(allocator, io, tmp_path, remapped_graph, .{});
    defer remapped.deinit(allocator);
    const remapped_idom = try toLogicalIdom(allocator, remapped.dom_parent, remapped.dom_order, V);
    defer allocator.free(remapped_idom);

    // For every original edge in the dominator relation, check it survives.
    for (0..V) |old_v| {
        const old_idom = original_idom[old_v];
        const new_idom = remapped_idom[perm[old_v]];
        if (old_idom == NONE) {
            try std.testing.expectEqual(NONE, new_idom);
        } else if (old_idom == root) {
            try std.testing.expectEqual(root, new_idom);
        } else {
            try std.testing.expectEqual(perm[@intCast(old_idom)], new_idom);
        }
    }
}

test "dominator engine satisfies the dominator property set on random graphs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const n: u32 = 5 + (i % 56);
        const m: u32 = n + (i % (2 * n + 1));
        const seed = random.int(u64);

        var graph = try Graphs.randomGraph(allocator, n, m, seed);
        defer graph.deinit(allocator);

        var both = try runEngineAndOracle(allocator, io, tmp_path, graph);
        defer both.engine.deinit(allocator);
        defer allocator.free(both.oracle);
        defer allocator.free(both.logical_idom);

        try std.testing.expectEqualSlices(u32, both.oracle, both.logical_idom);
        try checkProperties(allocator, graph, both.engine, both.logical_idom);
    }
}

fn checkProperties(
    allocator: std.mem.Allocator,
    graph: Graphs.Graph,
    engine: TestSupport.EngineOutput,
    idom: []const u32,
) !void {
    const V = graph.n_nodes;
    const root = V - 1;

    var reachable = try allocator.alloc(bool, V);
    defer allocator.free(reachable);
    @memset(reachable, false);
    reachable[root] = true;

    var stack = std.ArrayList(u32).empty;
    defer stack.deinit(allocator);
    {
        var succs = try allocator.alloc(std.ArrayList(u32), V);
        defer {
            for (succs) |*s| s.deinit(allocator);
            allocator.free(succs);
        }
        for (succs) |*s| s.* = std.ArrayList(u32).empty;
        for (graph.edges) |edge| {
            try succs[edge.source].append(allocator, edge.target);
        }
        try stack.append(allocator, root);
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
    }

    var rpo_num = try allocator.alloc(u32, V);
    defer allocator.free(rpo_num);
    @memset(rpo_num, NONE);
    for (engine.dom_order, 0..) |node, slot| {
        rpo_num[node] = @intCast(slot);
    }

    // 1. Chain terminates; 2. strict ascent in RPO; 3. no self-domination.
    for (0..V) |v| {
        if (!reachable[v]) {
            try std.testing.expectEqual(NONE, idom[v]);
            continue;
        }
        if (v == root) {
            try std.testing.expectEqual(NONE, idom[v]);
            continue;
        }
        var cur: u32 = @intCast(v);
        var seen = std.AutoHashMap(u32, void).init(allocator);
        defer seen.deinit();
        var steps: u32 = 0;
        while (idom[@intCast(cur)] != NONE) {
            try std.testing.expect(!seen.contains(cur));
            try seen.put(cur, {});
            const p = idom[@intCast(cur)];
            try std.testing.expect(rpo_num[@intCast(p)] < rpo_num[@intCast(cur)]);
            cur = p;
            steps += 1;
            try std.testing.expect(steps <= V);
        }
        try std.testing.expectEqual(@as(u32, @intCast(root)), cur);
    }

    // 4. Dominance preserved: if u dominates v, retained[u] >= retained[v].
    // 5. Retained >= shallow; 8. Unreachable isolation.
    for (0..V) |v| {
        try std.testing.expect(engine.retained[v] >= graph.shallow[v]);
        if (!reachable[v]) {
            try std.testing.expectEqual(graph.shallow[v], engine.retained[v]);
            continue;
        }
        var cur: u32 = @intCast(v);
        while (cur != root) {
            const p = idom[@intCast(cur)];
            try std.testing.expect(engine.retained[@intCast(p)] >= engine.retained[@intCast(cur)]);
            cur = p;
        }
    }

    // 6. Reconciliation.
    var total_shallow: u64 = 0;
    for (0..V) |v| {
        if (reachable[v]) total_shallow += graph.shallow[v];
    }
    try std.testing.expectEqual(total_shallow, engine.retained[@intCast(root)]);

    // 7. Subtree identity.
    var children = try allocator.alloc(std.ArrayList(u32), V);
    defer {
        for (children) |*c| c.deinit(allocator);
        allocator.free(children);
    }
    for (children) |*c| c.* = std.ArrayList(u32).empty;
    for (0..V) |v| {
        const p = idom[v];
        if (p != NONE and p != v) {
            try children[@intCast(p)].append(allocator, @intCast(v));
        }
    }
    for (0..V) |v| {
        if (!reachable[v]) continue;
        var child_sum: u64 = 0;
        for (children[v].items) |c| {
            child_sum += engine.retained[@intCast(c)];
        }
        try std.testing.expectEqual(engine.retained[v], graph.shallow[v] + child_sum);
    }
}
