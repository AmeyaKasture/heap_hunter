//! Lengauer-Tarjan (1979) dominator algorithm, classic "simple" variant:
//! semidominators via eval/link with path compression, then immediate
//! dominators via the bucket pass and a preorder fixup. O(E log V) worst
//! case, near-linear in practice on heap graphs.
//!
//! Memory layout: every scratch array is indexed by *preorder slot*, not
//! ordinal. The preorder slots are a permutation of the reachable ordinals
//! and are already produced by the shared DFS (`Numbering`), so the
//! relabeling costs no extra bytes. The main loop runs in decreasing slot
//! order, so its writes to `sdom`/`bucket` land in a left-to-right
//! shrinking frontier: sequential and prefetchable, instead of one random
//! write per node. The remaining random accesses per node are the pred
//! translation `dfn[u]`, the eval pointer hops, and `bucket_head[sdom]`.
const std = @import("std");
const Backend = @import("Backend.zig");
const Context = Backend.Context;
const Result = Backend.Result;
const Stats = Backend.Stats;

const NONE = std.math.maxInt(u32);

pub fn compute(ctx: *const Context) anyerror!Result {
    const n = ctx.n_reachable;
    const root_slot: u32 = 0; // The DFS discovers the virtual root first.
    std.debug.assert(ctx.dfn[ctx.root] == root_slot);
    std.debug.assert(ctx.max_dfs_depth > 0);

    const dfn = ctx.dfn; // ordinal -> slot (NONE when unreachable)
    const dfn_vertex = ctx.dfn_vertex; // slot -> ordinal
    const parent = ctx.parent; // slot -> parent slot (NONE for the root)

    const allocator = ctx.allocator;

    // Output, allocated first so every later free is unconditional and no
    // fallible operation happens after the scratch arrays are released.
    const idom = try allocator.alloc(u32, ctx.n_nodes);
    errdefer allocator.free(idom);
    @memset(idom, NONE);

    // Semidominator per slot, stored as the sdom's preorder slot. Init to
    // the node's own slot; the tree-parent edge always lowers it below that
    // (the parent is a predecessor and has a smaller slot).
    const sdom = try allocator.alloc(u32, n);
    errdefer allocator.free(sdom);
    for (0..n) |i| sdom[i] = @intCast(i);

    // Relative / immediate dominator per slot (NONE until assigned).
    const doms = try allocator.alloc(u32, n);
    errdefer allocator.free(doms);
    @memset(doms, NONE);

    // eval/link forest: ancestor per slot (self = root of its forest tree),
    // and label = the slot with minimum sdom on the path from the node to
    // its forest root, excluding the root.
    const anc = try allocator.alloc(u32, n);
    errdefer allocator.free(anc);
    for (0..n) |i| anc[i] = @intCast(i);

    const label = try allocator.alloc(u32, n);
    errdefer allocator.free(label);
    for (0..n) |i| label[i] = @intCast(i);

    // Buckets as linked lists threaded through the bucketed nodes: slot s
    // owns the list of nodes v with sdom[v] == s. Insertion is O(1), the
    // total size over all buckets is one entry per node, and draining is a
    // forward walk with slot-decreasing reads.
    const bucket_head = try allocator.alloc(u32, n);
    errdefer allocator.free(bucket_head);
    @memset(bucket_head, NONE);

    const bucket_next = try allocator.alloc(u32, n);
    errdefer allocator.free(bucket_next);

    // Reused path buffer for eval's iterative compression. A forest chain
    // is a sub-path of a root-to-node DFS tree path, so the DFS depth caps
    // it; reserving that bound up front keeps eval infallible.
    var path = std.ArrayList(u32).empty;
    defer path.deinit(allocator);
    try path.ensureTotalCapacity(allocator, ctx.max_dfs_depth);

    var stats: Stats = .{};

    // Main loop: slots in decreasing order. For every v with sdom(v) == w,
    // the intermediates on the tree path from v up to w have slots in
    // (w, v), so they are all linked when w is processed — which is exactly
    // when bucket[w] is drained, and eval(v) then covers the full path
    // below w.
    var i: u32 = n;
    while (i > 1) {
        i -= 1;
        const w = i;

        // Drain the bucket of w.
        var bv = bucket_head[w];
        while (bv != NONE) {
            const v = bv;
            bv = bucket_next[v];
            const u = eval(anc, label, sdom, &path, v, &stats);
            doms[v] = if (sdom[u] < sdom[v]) u else w;
        }
        bucket_head[w] = NONE;

        // sdom(w) from the predecessors of w: a smaller-slot pred
        // contributes itself (it cannot be an interior vertex of a longer
        // semidominator path to w, since interiors must exceed w); a
        // larger-slot pred contributes the minimum sdom on its forest
        // path, which is what eval returns.
        const w_ord = dfn_vertex[w];
        for (ctx.in_edges.edges(w_ord)) |p_ord| {
            stats.edges_processed += 1;
            if (p_ord == w_ord) continue; // self-loop
            const u_slot = dfn[p_ord];
            if (u_slot == NONE) continue; // unreachable pred
            if (u_slot < w) {
                if (u_slot < sdom[w]) sdom[w] = u_slot;
            } else {
                const u = eval(anc, label, sdom, &path, u_slot, &stats);
                if (sdom[u] < sdom[w]) sdom[w] = sdom[u];
            }
        }

        // Bucket w under its semidominator, or assign idom directly when
        // sdom(w) == parent(w): the idom then lies on the tree path from
        // parent(w) to w, which has no interior vertex, so it is the
        // parent itself (GTW §2.2 bucket-skip).
        const s = sdom[w];
        const p = parent[w];
        if (s == p) {
            doms[w] = p;
        } else {
            bucket_next[w] = bucket_head[s];
            bucket_head[s] = w;
        }

        // link(parent(w), w): the forest now spans every processed node,
        // hung from unprocessed roots.
        anc[w] = p;
    }

    // The loop above excludes the root (slot 0), so the root's bucket is
    // the only one left: every v with sdom(v) == root has idom == root.
    var bv = bucket_head[root_slot];
    while (bv != NONE) {
        const v = bv;
        bv = bucket_next[v];
        doms[v] = root_slot;
    }
    bucket_head[root_slot] = NONE;

    // Preorder fixup: turn relative dominators into immediate dominators.
    // A relative dominator has a smaller slot, so in ascending order its
    // own doms entry is already final.
    for (1..n) |j| {
        const w: u32 = @intCast(j);
        if (doms[w] != sdom[w]) doms[w] = doms[doms[w]];
    }

    // Convert to the ordinal-indexed contract of Backend.Result: the root
    // dominates itself, unreachable nodes stay NONE. This only reads doms
    // and dfn_vertex, so the other scratch arrays can go first.
    allocator.free(sdom);
    allocator.free(anc);
    allocator.free(label);
    allocator.free(bucket_head);
    allocator.free(bucket_next);

    for (1..n) |j| {
        const v = dfn_vertex[j];
        std.debug.assert(doms[j] != NONE);
        idom[v] = dfn_vertex[doms[j]];
    }
    idom[ctx.root] = ctx.root;
    allocator.free(doms);

    return .{ .idom = idom, .stats = stats };
}

/// eval(v): the slot with minimum sdom on v's path to its forest root,
/// excluding the root. Iterative: walk up collecting the path, then fold
/// labels top-down and point every path node at the root. Never recurses —
/// a 100M-deep chain must not overflow the call stack. The path buffer must
/// be pre-reserved to the DFS depth; a forest chain cannot exceed it.
fn eval(
    anc: []u32,
    label: []u32,
    sdom: []const u32,
    path: *std.ArrayList(u32),
    v_in: u32,
    stats: *Stats,
) u32 {
    stats.eval_calls += 1;

    const v = v_in;
    var u = anc[v];
    if (u == v) return v; // v is a forest root: nothing to compress.

    // Collect the compressible path [a1, ..., ak] below the root, where
    // a1 = anc[v] and anc[ak] is the root.
    path.clearRetainingCapacity();
    while (anc[u] != u) {
        path.appendAssumeCapacity(u);
        u = anc[u];
    }
    const root = u;
    stats.compress_steps += path.items.len;
    if (path.items.len > stats.compress_steps_max) {
        stats.compress_steps_max = @intCast(path.items.len);
    }

    // Fold labels top-down: the node just under the root gets no fold (the
    // root itself is excluded from the minimum), and each lower node folds
    // in the label of the node above it, which is already final.
    var j: usize = path.items.len;
    while (j > 1) {
        j -= 1;
        const a = path.items[j - 1];
        const up = path.items[j];
        if (sdom[label[up]] < sdom[label[a]]) label[a] = label[up];
    }

    // Compress: every path node points at the root, and v folds in the
    // label of its own ancestor a1.
    for (path.items) |a| {
        anc[a] = root;
    }
    if (path.items.len > 0) {
        const a1 = path.items[0];
        if (sdom[label[a1]] < sdom[label[v]]) label[v] = label[a1];
        anc[v] = root;
    }
    return label[v];
}

test "lt eval compresses a chain and returns the min-sdom label" {
    const allocator = std.testing.allocator;

    // Forest chain: 4 -> 3 -> 2 -> 1 -> 0(root). sdom values chosen so the
    // minimum sits in the middle of the chain, and the root's sdom is NOT
    // the minimum (a root fold would corrupt the result).
    const n = 5;
    var anc = try allocator.alloc(u32, n);
    defer allocator.free(anc);
    var label = try allocator.alloc(u32, n);
    defer allocator.free(label);
    const sdom = try allocator.alloc(u32, n);
    defer allocator.free(sdom);

    for (0..n) |i| {
        anc[i] = @intCast(i);
        label[i] = @intCast(i);
        sdom[i] = @intCast(i);
    }
    for (1..n) |i| anc[i] = @intCast(i - 1);
    // Slot 2 carries the minimum on the path 4 -> 3 -> 2 -> 1 below the
    // root; slot 0 (the root) is excluded from the fold.
    sdom[1] = 3;
    sdom[2] = 1;
    sdom[3] = 2;
    sdom[4] = 3;

    var path = std.ArrayList(u32).empty;
    defer path.deinit(allocator);
    try path.ensureTotalCapacity(allocator, n);
    var stats: Stats = .{};

    const u = eval(anc, label, sdom, &path, 4, &stats);
    try std.testing.expectEqual(@as(u32, 2), u);
    try std.testing.expectEqual(@as(u32, 0), anc[4]);
    try std.testing.expectEqual(@as(u64, 3), stats.compress_steps);
}

test "lt eval returns v itself when v is a forest root" {
    const allocator = std.testing.allocator;

    const n = 3;
    var anc = try allocator.alloc(u32, n);
    defer allocator.free(anc);
    var label = try allocator.alloc(u32, n);
    defer allocator.free(label);
    const sdom = try allocator.alloc(u32, n);
    defer allocator.free(sdom);
    for (0..n) |i| {
        anc[i] = @intCast(i);
        label[i] = @intCast(i);
        sdom[i] = @intCast(i);
    }

    var path = std.ArrayList(u32).empty;
    defer path.deinit(allocator);
    try path.ensureTotalCapacity(allocator, n);
    var stats: Stats = .{};

    try std.testing.expectEqual(@as(u32, 2), eval(anc, label, sdom, &path, 2, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.compress_steps);
}

test "lt eval folds a single-node path and skips the root" {
    const allocator = std.testing.allocator;

    // v's only ancestor is the root itself: the path is empty and v's
    // label must stay untouched (the root is excluded from the minimum).
    const n = 2;
    var anc = try allocator.alloc(u32, n);
    defer allocator.free(anc);
    var label = try allocator.alloc(u32, n);
    defer allocator.free(label);
    const sdom = try allocator.alloc(u32, n);
    defer allocator.free(sdom);
    anc[0] = 0;
    anc[1] = 0; // 1's ancestor is the root.
    label[0] = 0;
    label[1] = 1;
    sdom[0] = 0; // root sdom is the global minimum on purpose.
    sdom[1] = 1;

    var path = std.ArrayList(u32).empty;
    defer path.deinit(allocator);
    try path.ensureTotalCapacity(allocator, n);
    var stats: Stats = .{};

    try std.testing.expectEqual(@as(u32, 1), eval(anc, label, sdom, &path, 1, &stats));
}

test "lt eval path buffer handles a deep chain without recursion" {
    const allocator = std.testing.allocator;

    // A 100k chain: recursive compress would overflow the test stack.
    const n: u32 = 100_000;
    var anc = try allocator.alloc(u32, n);
    defer allocator.free(anc);
    var label = try allocator.alloc(u32, n);
    defer allocator.free(label);
    const sdom = try allocator.alloc(u32, n);
    defer allocator.free(sdom);
    for (0..n) |i| {
        anc[i] = @intCast(i);
        label[i] = @intCast(i);
        sdom[i] = @intCast(i);
    }
    for (1..n) |i| anc[i] = @intCast(i - 1);
    // The minimum sits at slot 1, just under the root.
    sdom[1] = 0;

    var path = std.ArrayList(u32).empty;
    defer path.deinit(allocator);
    try path.ensureTotalCapacity(allocator, n);
    var stats: Stats = .{};

    const u = eval(anc, label, sdom, &path, n - 1, &stats);
    try std.testing.expectEqual(@as(u32, 1), u);
    try std.testing.expectEqual(@as(u64, n - 2), stats.compress_steps);
    try std.testing.expectEqual(@as(u32, 0), anc[n - 1]);
}
