//! Dense-graph characterization of the CHK engine ("chk analyse" for the
//! gate decision). The S2 random sweep caps out around `randomDense`
//! (E ≈ 2–3N); real heaps can be far denser per component, and profiling on
//! main suggested CHK struggles there. This probe measures CHK's iteration
//! count and intersect-walk cost on deliberately dense graphs and asserts
//! correctness against the oracle at a size the oracle can afford.
//!
//! The probe records measurements via `std.debug.print`; the gate verdict
//! (G1 thresholds: <10 iterations, <50 avg intersect steps/edge) is drawn
//! from these numbers in the planning notes — no threshold is asserted
//! here, so tuning can never make a test green by construction.
const std = @import("std");
const Io = std.Io;

const Backend = @import("Backend.zig");
const Engine_test = @import("Engine_test.zig");
const Graphs = @import("Graphs.zig");
const Oracle = @import("Oracle.zig");
const TestSupport = @import("TestSupport.zig");

const NONE: u32 = std.math.maxInt(u32);

const Shape = struct {
    label: []const u8,
    n_nodes: u32,
    m_edges: u32,
    seed: u64,
};

/// Density ladder, from the S2-style sparse regime to an extremely dense
/// random graph (E ≈ V²/2 ≈ half of complete). Oracle agreement is checked
/// only where the oracle's O(V²) bitset cost stays reasonable (V ≤ 400).
const shapes = [_]Shape{
    .{ .label = "sparse   V=500  E=2V", .n_nodes = 500, .m_edges = 1000, .seed = 901 },
    .{ .label = "medium   V=500  E=10V", .n_nodes = 500, .m_edges = 5000, .seed = 902 },
    .{ .label = "dense    V=500  E=50V", .n_nodes = 500, .m_edges = 25000, .seed = 903 },
    .{ .label = "dense    V=500  E=100V", .n_nodes = 500, .m_edges = 50000, .seed = 904 },
    .{ .label = "x-dense  V=400  E=V^2/2", .n_nodes = 400, .m_edges = 80_000, .seed = 905 },
};

test "dense graphs: engine agrees with the oracle and CHK cost is recorded" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    for (shapes) |shape| {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path);

        var graph = try Graphs.randomGraph(allocator, shape.n_nodes, shape.m_edges, shape.seed);
        defer graph.deinit(allocator);

        var engine = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{});
        defer engine.deinit(allocator);

        // `Chk` does not count swept edges itself; the bench harness derives
        // `edges_processed` as the sum of in-degrees over reachable nodes
        // (the sweep visits every in-edge of every reachable node). The
        // probe computes the same quantity from the edge list — the CSR the
        // engine consumed keeps duplicates, so raw edge counts match.
        var in_degree = try allocator.alloc(u32, graph.n_nodes);
        defer allocator.free(in_degree);
        @memset(in_degree, 0);
        for (graph.edges) |edge| in_degree[edge.target] += 1;

        var edges_processed: u64 = 0;
        for (engine.dom_order) |node| edges_processed += in_degree[node];
        // The virtual root is reachable; `dom_order` includes it, but count
        // defensively in case a future layout drops it.
        edges_processed += in_degree[graph.n_nodes - 1];

        const s = engine.stats;
        const avg_steps: f64 = if (edges_processed == 0)
            0
        else
            @as(f64, @floatFromInt(s.intersect_steps_total)) / @as(f64, @floatFromInt(edges_processed));

        std.debug.print(
            "dense probe {s}: iterations={d} edges_processed={d} avg_steps/edge={d:.2} max_steps={d} shortcut_nodes={d}\n",
            .{ shape.label, s.iterations, edges_processed, avg_steps, s.intersect_steps_max, s.shortcut_nodes },
        );

        // The engine must never hit its own iteration cap on these shapes;
        // that would be a non-convergence, not a slow convergence.
        try std.testing.expect(s.iterations <= Backend.default_max_iterations);

        if (shape.n_nodes <= 400) {
            const logical = try Engine_test.toLogicalIdom(allocator, engine.dom_parent, engine.dom_order, graph.n_nodes);
            defer allocator.free(logical);
            const oracle = try Oracle.immediateDominators(allocator, graph);
            defer allocator.free(oracle);
            try std.testing.expectEqualSlices(u32, oracle, logical);
        }
    }
}

test "deep dominator chain with dense back-edge fan-in: CHK cost is recorded" {
    // Hypothesis behind the profiling observation: uniform density is not
    // what hurts CHK — *depth combined with fan-in* is. In this shape the
    // dominator tree is a single chain of depth V (spine 0 -> 1 -> ...), and
    // every spine node additionally receives random BACK-edges from deeper
    // spine nodes. Back-edges add no reachability, so the chain — and
    // therefore every idom — is preserved, but each extra predecessor forces
    // an intersect walk that climbs from the deep predecessor up to the
    // spine node, so walk length scales with tree depth while the edge
    // count stays modest. The brute-force oracle is too slow at this depth,
    // and the chain part is already hand-verified by
    // `linearChain`/`longDominatorChain` in the S2 suite.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const depth: u32 = 2000;
    const cross_edges: u32 = 2000;
    var prng = std.Random.DefaultPrng.init(906);
    const rnd = prng.random();

    // Nodes 0..depth-1 form the spine; `depth` is the virtual root.
    const n_nodes: u32 = depth + 1;
    const root: u32 = depth;
    var edges = std.ArrayList(Graphs.Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    var i: u32 = 0;
    while (i + 1 < depth) : (i += 1) {
        try edges.append(allocator, .{ .source = i, .target = i + 1 });
    }
    var c: u32 = 0;
    while (c < cross_edges) : (c += 1) {
        // t < depth-1 so the strictly-deeper source range is never empty.
        const t = rnd.intRangeLessThan(u32, 1, depth - 1); // back-edge target
        const s = rnd.intRangeLessThan(u32, t + 1, depth); // strictly deeper source
        try edges.append(allocator, .{ .source = s, .target = t });
    }

    // Ownership transfers to `graph`: deinit frees both `edges` and `shallow`.
    const shallow_sizes = try allocator.alloc(u32, n_nodes);
    @memset(shallow_sizes, 1);

    var graph = Graphs.Graph{
        .n_nodes = n_nodes,
        .edges = try edges.toOwnedSlice(allocator),
        .shallow = shallow_sizes,
    };
    defer graph.deinit(allocator);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var engine = try TestSupport.runEngine(allocator, io, tmp_path, graph, .{});
    defer engine.deinit(allocator);

    var in_degree = try allocator.alloc(u32, n_nodes);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);
    for (graph.edges) |edge| in_degree[edge.target] += 1;

    var edges_processed: u64 = 0;
    for (engine.dom_order) |node| edges_processed += in_degree[node];
    edges_processed += in_degree[root];

    const s = engine.stats;
    const avg_steps: f64 = @as(f64, @floatFromInt(s.intersect_steps_total)) /
        @as(f64, @floatFromInt(edges_processed));

    std.debug.print(
        "dense probe deep-spine V={d} E={d}: iterations={d} edges_processed={d} avg_steps/edge={d:.2} max_steps={d}\n",
        .{ depth, graph.edges.len, s.iterations, edges_processed, avg_steps, s.intersect_steps_max },
    );

    // Back-edges add no reachability, so the spine chain is preserved:
    // node i's immediate dominator is node i-1 (node 0 is dominated by the
    // virtual root, which the on-disk form writes as NONE).
    try std.testing.expectEqual(NONE, engine.dom_parent[0]);
    var j: u32 = 1;
    while (j < depth) : (j += 1) {
        try std.testing.expectEqual(j - 1, engine.dom_parent[j]);
    }
}

test "dense probe: default max iterations constant is sane" {
    // The probe above references this constant; keep it tied to the real
    // backend default so a silent change cannot invalidate the probe.
    try std.testing.expectEqual(@as(u32, 64), Backend.default_max_iterations);
}
