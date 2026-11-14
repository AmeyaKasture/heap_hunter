//! Deterministic synthetic graph catalogue for dominator testing.
const std = @import("std");

pub const Edge = struct {
    source: u32,
    target: u32,
};

pub const Graph = struct {
    n_nodes: u32,
    edges: []Edge,
    shallow: []const u32,

    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        allocator.free(self.edges);
        allocator.free(self.shallow);
        self.* = .{
            .n_nodes = 0,
            .edges = &.{},
            .shallow = &.{},
        };
    }
};

// ---------------------------------------------------------------------------
// Canonical shapes (small, hand-analyzable)
// ---------------------------------------------------------------------------

pub fn linearChain(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 4;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = 0, .target = 1 });
    try edges.append(allocator, .{ .source = 1, .target = 2 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn diamond(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 5;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = 0, .target = 1 });
    try edges.append(allocator, .{ .source = 0, .target = 2 });
    try edges.append(allocator, .{ .source = 1, .target = 3 });
    try edges.append(allocator, .{ .source = 2, .target = 3 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn twoRootsIntoOne(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 4;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = root, .target = 1 });
    try edges.append(allocator, .{ .source = 0, .target = 2 });
    try edges.append(allocator, .{ .source = 1, .target = 2 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn cycle(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 4;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = 0, .target = 1 });
    try edges.append(allocator, .{ .source = 1, .target = 2 });
    try edges.append(allocator, .{ .source = 2, .target = 0 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn selfLoop(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 2;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = 0, .target = 0 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn unreachableIsland(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 4;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = 1, .target = 2 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

// ---------------------------------------------------------------------------
// Structural shapes (larger, deterministic)
// ---------------------------------------------------------------------------

pub fn diamondLadder(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 9;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try appendDiamond(&edges, allocator, 0, 1, 2, 3);
    try appendDiamond(&edges, allocator, 3, 4, 5, 6);
    try edges.append(allocator, .{ .source = 6, .target = 7 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn twoRootsShareDeepTail(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 8;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = root, .target = 1 });
    try edges.append(allocator, .{ .source = 0, .target = 2 });
    try edges.append(allocator, .{ .source = 2, .target = 4 });
    try edges.append(allocator, .{ .source = 4, .target = 6 });
    try edges.append(allocator, .{ .source = 1, .target = 3 });
    try edges.append(allocator, .{ .source = 3, .target = 5 });
    try edges.append(allocator, .{ .source = 5, .target = 6 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn rootPointsAtEverything(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 8;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    for (0..root) |target| {
        try edges.append(allocator, .{ .source = root, .target = @intCast(target) });
    }
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn cycleThroughRoot(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 3;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = 0, .target = 1 });
    try edges.append(allocator, .{ .source = 1, .target = root });
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn star(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 8;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    for (1..root) |leaf| {
        try edges.append(allocator, .{ .source = 0, .target = @intCast(leaf) });
    }
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn binaryTree(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 15;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    const max_parent = (n_nodes - 2) / 2; // last real node index is n_nodes - 2
    var parent: u32 = 0;
    while (parent <= max_parent) : (parent += 1) {
        const left = 2 * parent + 1;
        const right = 2 * parent + 2;
        if (left <= n_nodes - 2) {
            try edges.append(allocator, .{ .source = parent, .target = left });
        }
        if (right <= n_nodes - 2) {
            try edges.append(allocator, .{ .source = parent, .target = right });
        }
    }
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn layeredDag(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 13;
    const root = n_nodes - 1;
    const layer_sizes = [_]u32{ 1, 2, 3, 3, 3 };
    var starts = std.ArrayList(u32).empty;
    defer starts.deinit(allocator);
    try starts.append(allocator, 0);
    for (layer_sizes) |size| {
        try starts.append(allocator, starts.getLast() + size);
    }
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    // Virtual root points to the only node in layer 0.
    try edges.append(allocator, .{ .source = root, .target = 0 });
    for (0..layer_sizes.len - 1) |layer| {
        const layer_start = starts.items[layer];
        const next_start = starts.items[layer + 1];
        const next_end = starts.items[layer + 2];
        var src = layer_start;
        while (src < next_start) : (src += 1) {
            var dst = next_start;
            while (dst < next_end) : (dst += 1) {
                try edges.append(allocator, .{ .source = src, .target = dst });
            }
        }
    }
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn grid(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const side: u32 = 4;
    const n_nodes: u32 = side * side + 1;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    var r: u32 = 0;
    while (r < side) : (r += 1) {
        var c: u32 = 0;
        while (c < side) : (c += 1) {
            const id = r * side + c;
            if (r + 1 < side) {
                try edges.append(allocator, .{ .source = id, .target = (r + 1) * side + c });
            }
            if (c + 1 < side) {
                try edges.append(allocator, .{ .source = id, .target = r * side + (c + 1) });
            }
        }
    }
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn completeGraph(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 6;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    for (0..root) |target| {
        try edges.append(allocator, .{ .source = root, .target = @intCast(target) });
    }
    var src: u32 = 0;
    while (src < root) : (src += 1) {
        var dst: u32 = 0;
        while (dst < root) : (dst += 1) {
            if (src != dst) {
                try edges.append(allocator, .{ .source = src, .target = dst });
            }
        }
    }
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn deepChain(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 50;
    return chainGraph(allocator, n_nodes);
}

pub fn wideFanout(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 22;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    for (1..root) |leaf| {
        try edges.append(allocator, .{ .source = 0, .target = @intCast(leaf) });
    }
    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn longDominatorChain(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 100;
    return chainGraph(allocator, n_nodes);
}

pub fn islands(allocator: std.mem.Allocator, seed: u64) !Graph {
    _ = seed;
    const n_nodes: u32 = 10;
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    try edges.append(allocator, .{ .source = 0, .target = 1 });
    try edges.append(allocator, .{ .source = 2, .target = 3 });
    try edges.append(allocator, .{ .source = 4, .target = 5 });
    try edges.append(allocator, .{ .source = 6, .target = 7 });
    try edges.append(allocator, .{ .source = 8, .target = 9 });
    return graphFromEdges(allocator, n_nodes, &edges);
}

// ---------------------------------------------------------------------------
// Random generators (seeded)
// ---------------------------------------------------------------------------

pub fn randomGraph(allocator: std.mem.Allocator, n_nodes: u32, m_edges: u32, seed: u64) !Graph {
    if (n_nodes < 2) return error.InvalidGraphSize;
    if (m_edges < n_nodes - 1) return error.EdgeCountTooSmall;

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);

    // Plant a spanning arborescence rooted at the virtual root (n_nodes - 1).
    // Each non-root node chooses a parent with a strictly greater ordinal, so
    // the virtual root can reach every real node.
    var v: u32 = 0;
    while (v < n_nodes - 1) : (v += 1) {
        const parent = rnd.intRangeLessThan(u32, v + 1, n_nodes);
        try edges.append(allocator, .{ .source = parent, .target = v });
    }

    var remaining: u32 = m_edges - (n_nodes - 1);
    while (remaining > 0) : (remaining -= 1) {
        const source = rnd.intRangeLessThan(u32, 0, n_nodes);
        const target = rnd.intRangeLessThan(u32, 0, n_nodes);
        try edges.append(allocator, .{ .source = source, .target = target });
    }

    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn randomDag(allocator: std.mem.Allocator, n_nodes: u32, m_edges: u32, seed: u64) !Graph {
    if (n_nodes < 2) return error.InvalidGraphSize;
    if (m_edges < n_nodes - 1) return error.EdgeCountTooSmall;

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);

    // Spanning arborescence with edges directed from high to low ordinals.
    var v: u32 = 0;
    while (v < n_nodes - 1) : (v += 1) {
        const parent = rnd.intRangeLessThan(u32, v + 1, n_nodes);
        try edges.append(allocator, .{ .source = parent, .target = v });
    }

    var remaining: u32 = m_edges - (n_nodes - 1);
    while (remaining > 0) : (remaining -= 1) {
        const source = rnd.intRangeLessThan(u32, 1, n_nodes);
        const target = rnd.intRangeLessThan(u32, 0, source);
        try edges.append(allocator, .{ .source = source, .target = target });
    }

    return graphFromEdges(allocator, n_nodes, &edges);
}

pub fn randomSparse(allocator: std.mem.Allocator, n_nodes: u32, seed: u64) !Graph {
    if (n_nodes < 2) return error.InvalidGraphSize;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const extra = rnd.intRangeLessThan(u32, 0, n_nodes / 4 + 1);
    const m_edges = n_nodes + extra;
    return randomGraph(allocator, n_nodes, m_edges, seed);
}

pub fn randomDense(allocator: std.mem.Allocator, n_nodes: u32, seed: u64) !Graph {
    if (n_nodes < 2) return error.InvalidGraphSize;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const max_extra = 2 * n_nodes;
    const extra = rnd.intRangeLessThan(u32, n_nodes, max_extra + 1);
    const m_edges = n_nodes + extra;
    return randomGraph(allocator, n_nodes, m_edges, seed);
}

// ---------------------------------------------------------------------------
// Catalogue helpers
// ---------------------------------------------------------------------------

pub fn catalogue(allocator: std.mem.Allocator, seed_base: u64) ![]Graph {
    var graphs = std.ArrayList(Graph).empty;
    defer graphs.deinit(allocator);

    try appendCanonical(&graphs, allocator);
    try appendStructural(&graphs, allocator);

    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const seed = seed_base + i;
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();
        const n = rnd.intRangeLessThan(u32, 5, 61);
        const max_m = 3 * n;
        const m = n + rnd.intRangeLessThan(u32, 0, max_m - n + 1);
        try graphs.append(allocator, try randomGraph(allocator, n, m, seed));
    }

    return try graphs.toOwnedSlice(allocator);
}

pub fn deinitCatalogue(allocator: std.mem.Allocator, graphs: *[]Graph) void {
    for (graphs.*) |*graph| {
        graph.deinit(allocator);
    }
    allocator.free(graphs.*);
    graphs.* = &[]Graph{};
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn graphFromEdges(allocator: std.mem.Allocator, n_nodes: u32, edges: *std.ArrayList(Edge)) !Graph {
    const edges_slice = try edges.toOwnedSlice(allocator);
    errdefer allocator.free(edges_slice);
    const shallow = try shallowUniform(allocator, n_nodes);
    errdefer allocator.free(shallow);
    return .{
        .n_nodes = n_nodes,
        .edges = edges_slice,
        .shallow = shallow,
    };
}

fn shallowUniform(allocator: std.mem.Allocator, n_nodes: u32) ![]u32 {
    const shallow = try allocator.alloc(u32, n_nodes);
    @memset(shallow, 1);
    shallow[n_nodes - 1] = 0;
    return shallow;
}

fn appendDiamond(
    edges: *std.ArrayList(Edge),
    allocator: std.mem.Allocator,
    top: u32,
    left: u32,
    right: u32,
    bottom: u32,
) !void {
    try edges.append(allocator, .{ .source = top, .target = left });
    try edges.append(allocator, .{ .source = top, .target = right });
    try edges.append(allocator, .{ .source = left, .target = bottom });
    try edges.append(allocator, .{ .source = right, .target = bottom });
}

fn chainGraph(allocator: std.mem.Allocator, n_nodes: u32) !Graph {
    const root = n_nodes - 1;
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    try edges.append(allocator, .{ .source = root, .target = 0 });
    var v: u32 = 0;
    while (v + 1 < root) : (v += 1) {
        try edges.append(allocator, .{ .source = v, .target = v + 1 });
    }
    return graphFromEdges(allocator, n_nodes, &edges);
}

fn appendCanonical(graphs: *std.ArrayList(Graph), allocator: std.mem.Allocator) !void {
    try graphs.append(allocator, try linearChain(allocator, 0));
    try graphs.append(allocator, try diamond(allocator, 0));
    try graphs.append(allocator, try twoRootsIntoOne(allocator, 0));
    try graphs.append(allocator, try cycle(allocator, 0));
    try graphs.append(allocator, try selfLoop(allocator, 0));
    try graphs.append(allocator, try unreachableIsland(allocator, 0));
}

fn appendStructural(graphs: *std.ArrayList(Graph), allocator: std.mem.Allocator) !void {
    try graphs.append(allocator, try diamondLadder(allocator, 0));
    try graphs.append(allocator, try twoRootsShareDeepTail(allocator, 0));
    try graphs.append(allocator, try rootPointsAtEverything(allocator, 0));
    try graphs.append(allocator, try cycleThroughRoot(allocator, 0));
    try graphs.append(allocator, try star(allocator, 0));
    try graphs.append(allocator, try binaryTree(allocator, 0));
    try graphs.append(allocator, try layeredDag(allocator, 0));
    try graphs.append(allocator, try grid(allocator, 0));
    try graphs.append(allocator, try completeGraph(allocator, 0));
    try graphs.append(allocator, try deepChain(allocator, 0));
    try graphs.append(allocator, try wideFanout(allocator, 0));
    try graphs.append(allocator, try longDominatorChain(allocator, 0));
    try graphs.append(allocator, try islands(allocator, 0));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dominator graph generators are deterministic for a fixed seed" {
    const allocator = std.testing.allocator;
    const seed: u64 = 0xabc123;

    var a = try randomGraph(allocator, 20, 35, seed);
    defer a.deinit(allocator);
    var b = try randomGraph(allocator, 20, 35, seed);
    defer b.deinit(allocator);

    try std.testing.expectEqual(a.n_nodes, b.n_nodes);
    try std.testing.expectEqual(a.edges.len, b.edges.len);
    try std.testing.expectEqual(a.shallow.len, b.shallow.len);
    for (a.edges, b.edges) |edge_a, edge_b| {
        try std.testing.expectEqual(edge_a.source, edge_b.source);
        try std.testing.expectEqual(edge_a.target, edge_b.target);
    }
    for (a.shallow, b.shallow) |size_a, size_b| {
        try std.testing.expectEqual(size_a, size_b);
    }
}
