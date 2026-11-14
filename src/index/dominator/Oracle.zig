//! Independent brute-force dominator oracle used to validate the engine.
const std = @import("std");
const Graphs = @import("Graphs.zig");

const NONE = std.math.maxInt(u32);

/// Compute the immediate dominator of every node in `graph` relative to the
/// virtual root `n_nodes - 1`. Unreachable nodes and the root itself receive
/// `NONE`.
pub fn immediateDominators(allocator: std.mem.Allocator, graph: Graphs.Graph) ![]u32 {
    const V = graph.n_nodes;
    const root = V - 1;
    const words = (V + 63) / 64;

    var preds = try allocator.alloc(std.ArrayList(u32), V);
    errdefer allocator.free(preds);
    var succs = try allocator.alloc(std.ArrayList(u32), V);
    errdefer allocator.free(succs);
    for (preds, succs) |*p, *s| {
        p.* = std.ArrayList(u32).empty;
        s.* = std.ArrayList(u32).empty;
    }
    defer {
        for (preds, succs) |*p, *s| {
            p.deinit(allocator);
            s.deinit(allocator);
        }
        allocator.free(preds);
        allocator.free(succs);
    }

    for (graph.edges) |edge| {
        try preds[edge.target].append(allocator, edge.source);
        try succs[edge.source].append(allocator, edge.target);
    }

    const reachable = try computeReachability(allocator, V, root, succs);
    defer allocator.free(reachable);

    const dom = try allocator.alloc(u64, @as(usize, V) * words);
    defer allocator.free(dom);
    @memset(dom, ~@as(u64, 0));
    clearBits(dom, root * words, V);
    setBit(dom, root * words, root);

    var changed = true;
    var new_set = try allocator.alloc(u64, words);
    defer allocator.free(new_set);

    while (changed) {
        changed = false;
        var v: u32 = 0;
        while (v < V) : (v += 1) {
            if (v == root or !reachable[v]) continue;
            const base = @as(usize, v) * words;

            @memset(new_set, ~@as(u64, 0));
            var has_reachable_pred = false;
            for (preds[v].items) |p| {
                if (!reachable[p]) continue;
                if (!has_reachable_pred) {
                    @memcpy(new_set, dom[@as(usize, p) * words ..][0..words]);
                    has_reachable_pred = true;
                } else {
                    const p_base = @as(usize, p) * words;
                    for (0..words) |w| {
                        new_set[w] &= dom[p_base + w];
                    }
                }
            }
            if (!has_reachable_pred) {
                @memset(new_set, 0);
            }
            setBit(new_set, 0, v);

            for (0..words) |w| {
                if (dom[base + w] != new_set[w]) {
                    dom[base + w] = new_set[w];
                    changed = true;
                }
            }
        }
    }

    return deriveIdom(allocator, V, root, words, dom, reachable);
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
        const v = stack.pop().?;
        for (succs[v].items) |w| {
            if (!reachable[w]) {
                reachable[w] = true;
                try stack.append(allocator, w);
            }
        }
    }

    return reachable;
}

fn deriveIdom(
    allocator: std.mem.Allocator,
    V: u32,
    root: u32,
    words: u32,
    dom: []const u64,
    reachable: []const bool,
) ![]u32 {
    const idom = try allocator.alloc(u32, V);
    @memset(idom, NONE);

    var v: u32 = 0;
    while (v < V) : (v += 1) {
        if (!reachable[v] or v == root) continue;
        const base = @as(usize, v) * words;

        var candidate: u32 = NONE;
        var d: u32 = 0;
        while (d < V) : (d += 1) {
            if (d == v or !isBitSet(dom, base, d)) continue;

            var dominated_by_all_others = true;
            var d2: u32 = 0;
            while (d2 < V) : (d2 += 1) {
                if (d2 == v or d2 == d or !isBitSet(dom, base, d2)) continue;
                // Every other strict dominator of v must also dominate d.
                if (!isBitSet(dom, @as(usize, d) * words, d2)) {
                    dominated_by_all_others = false;
                    break;
                }
            }

            if (dominated_by_all_others) {
                candidate = d;
                break;
            }
        }

        idom[v] = candidate;
    }

    return idom;
}

fn setBit(bits: []u64, base: usize, node: u32) void {
    const word = node / 64;
    const bit: u6 = @intCast(node % 64);
    bits[base + word] |= @as(u64, 1) << bit;
}

fn clearBits(bits: []u64, base: usize, V: u32) void {
    const full_words = V / 64;
    for (0..full_words) |w| {
        bits[base + w] = 0;
    }
    const remainder = V % 64;
    if (remainder > 0) {
        const last = base + full_words;
        bits[last] = 0;
    }
}

fn isBitSet(bits: []const u64, base: usize, node: u32) bool {
    const word = node / 64;
    const bit: u6 = @intCast(node % 64);
    return (bits[base + word] & (@as(u64, 1) << bit)) != 0;
}

// ---------------------------------------------------------------------------
// Tests against hand-computed expectations for the six canonical shapes.
// ---------------------------------------------------------------------------

fn expectIdom(allocator: std.mem.Allocator, graph: Graphs.Graph, expected: []const u32) !void {
    const idom = try immediateDominators(allocator, graph);
    defer allocator.free(idom);
    try std.testing.expectEqualSlices(u32, expected, idom);
}

test "dominator oracle computes the expected chain" {
    const allocator = std.testing.allocator;
    var graph = try Graphs.linearChain(allocator, 0);
    defer graph.deinit(allocator);
    // root = 3: 3 -> 0 -> 1 -> 2
    const expected = &[_]u32{ 3, 0, 1, NONE };
    try expectIdom(allocator, graph, expected);
}

test "dominator oracle computes the expected diamond" {
    const allocator = std.testing.allocator;
    var graph = try Graphs.diamond(allocator, 0);
    defer graph.deinit(allocator);
    // root = 4: 4 -> 0, 0 -> {1,2}, {1,2} -> 3
    const expected = &[_]u32{ 4, 0, 0, 0, NONE };
    try expectIdom(allocator, graph, expected);
}

test "dominator oracle computes the expected two roots into one" {
    const allocator = std.testing.allocator;
    var graph = try Graphs.twoRootsIntoOne(allocator, 0);
    defer graph.deinit(allocator);
    // root = 3: 3 -> {0,1}, {0,1} -> 2
    const expected = &[_]u32{ 3, 3, 3, NONE };
    try expectIdom(allocator, graph, expected);
}

test "dominator oracle computes the expected cycle" {
    const allocator = std.testing.allocator;
    var graph = try Graphs.cycle(allocator, 0);
    defer graph.deinit(allocator);
    // root = 3: 3 -> 0 -> 1 -> 2 -> 0
    const expected = &[_]u32{ 3, 0, 1, NONE };
    try expectIdom(allocator, graph, expected);
}

test "dominator oracle computes the expected self loop" {
    const allocator = std.testing.allocator;
    var graph = try Graphs.selfLoop(allocator, 0);
    defer graph.deinit(allocator);
    // root = 1: 1 -> 0, 0 -> 0
    const expected = &[_]u32{ 1, NONE };
    try expectIdom(allocator, graph, expected);
}

test "dominator oracle computes the expected unreachable island" {
    const allocator = std.testing.allocator;
    var graph = try Graphs.unreachableIsland(allocator, 0);
    defer graph.deinit(allocator);
    // root = 3: 3 -> 0; island 1 -> 2
    const expected = &[_]u32{ 3, NONE, NONE, NONE };
    try expectIdom(allocator, graph, expected);
}
