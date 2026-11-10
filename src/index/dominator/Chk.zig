//! Cooper-Harvey-Kennedy (CHK) iterative dominator algorithm.
const std = @import("std");
const Backend = @import("Backend.zig");
const Context = Backend.Context;
const Result = Backend.Result;
const Stats = Backend.Stats;

pub const NONE = std.math.maxInt(u32);

pub fn compute(ctx: *const Context) anyerror!Result {
    const V = ctx.n_nodes;
    const root = ctx.root;

    const idom = try ctx.allocator.alloc(u32, V);
    errdefer ctx.allocator.free(idom);
    @memset(idom, NONE);
    idom[root] = root;

    const sole_pred = try ctx.allocator.alloc(u32, V);
    errdefer ctx.allocator.free(sole_pred);
    @memset(sole_pred, NONE);

    if (ctx.options.use_shortcut) {
        computeShortcutDecisions(ctx, sole_pred);
    }

    var stats: Stats = .{};

    while (true) {
        const changed = sweep(ctx, idom, sole_pred, &stats);
        stats.iterations += 1;
        if (!changed) break;
        if (stats.iterations > ctx.options.max_iterations) {
            ctx.allocator.free(sole_pred);
            return error.DominatorIterationLimitExceeded;
        }
    }

    ctx.allocator.free(sole_pred);
    return .{ .idom = idom, .stats = stats };
}

fn computeShortcutDecisions(ctx: *const Context, sole_pred: []u32) void {
    const n_reachable = ctx.n_reachable;
    var rpo_slot: u32 = 0;
    while (rpo_slot < n_reachable) : (rpo_slot += 1) {
        const v = ctx.rpo_vertex[rpo_slot];
        sole_pred[v] = NONE;

        const preds = ctx.in_edges.edges(v);
        var count: u32 = 0;
        var the_pred: u32 = NONE;
        var previous: u32 = NONE;
        for (preds) |p| {
            if (p == v) continue;
            if (!ctx.reachable[p]) continue;
            if (p == previous) continue;
            previous = p;
            count += 1;
            the_pred = p;
        }
        if (count == 1) {
            if (ctx.rpo_num[the_pred] < ctx.rpo_num[v]) {
                sole_pred[v] = the_pred;
            }
        }
    }
}

fn sweep(
    ctx: *const Context,
    idom: []u32,
    sole_pred: []u32,
    stats: *Stats,
) bool {
    var changed = false;
    const n_reachable = ctx.n_reachable;
    var rpo_slot: u32 = 1;
    while (rpo_slot < n_reachable) : (rpo_slot += 1) {
        const v = ctx.rpo_vertex[rpo_slot];
        if (idom[v] != NONE) continue;

        const shortcut = sole_pred[v];
        if (shortcut != NONE) {
            idom[v] = shortcut;
            stats.shortcut_nodes += 1;
            changed = true;
            continue;
        }

        const preds = ctx.in_edges.edges(v);
        var candidate: u32 = NONE;
        for (preds) |p| {
            if (p == v) continue;
            if (!ctx.reachable[p]) continue;
            if (ctx.rpo_num[p] >= ctx.rpo_num[v]) continue;
            if (idom[p] == NONE) continue;
            if (candidate == NONE) {
                candidate = p;
            } else {
                candidate = intersect(ctx, idom, p, candidate, stats);
            }
        }
        if (candidate == NONE) continue;
        if (idom[v] != candidate) {
            idom[v] = candidate;
            changed = true;
            stats.nodes_changed += 1;
        }
    }
    return changed;
}

fn intersect(
    ctx: *const Context,
    idom: []u32,
    a_in: u32,
    b_in: u32,
    stats: *Stats,
) u32 {
    var a = a_in;
    var b = b_in;
    var steps: u32 = 0;
    while (a != b) {
        while (ctx.rpo_num[a] > ctx.rpo_num[b]) {
            std.debug.assert(idom[a] != NONE);
            a = idom[a];
            steps += 1;
        }
        while (ctx.rpo_num[b] > ctx.rpo_num[a]) {
            std.debug.assert(idom[b] != NONE);
            b = idom[b];
            steps += 1;
        }
    }
    stats.intersect_steps_total += steps;
    if (steps > stats.intersect_steps_max) {
        stats.intersect_steps_max = steps;
    }
    return a;
}

test "dominator intersect moves the finger with the larger reverse postorder slot" {
    const allocator = std.testing.allocator;
    // Tree: root(0) has children a(1) and b(2); a has child c(3).
    // RPO slots are strictly increasing away from the root.
    var rpo_num = try allocator.alloc(u32, 4);
    defer allocator.free(rpo_num);
    rpo_num[0] = 0; // root
    rpo_num[1] = 1; // a
    rpo_num[2] = 2; // b
    rpo_num[3] = 3; // c

    var idom = try allocator.alloc(u32, 4);
    defer allocator.free(idom);
    idom[0] = 0; // root -> root
    idom[1] = 0; // a -> root
    idom[2] = 0; // b -> root
    idom[3] = 1; // c -> a

    var stats: Stats = .{};
    const ctx: Context = .{
        .allocator = allocator,
        .n_nodes = 4,
        .root = 0,
        .n_reachable = 4,
        .rpo_num = rpo_num,
        .rpo_vertex = &.{},
        .reachable = &.{},
        .options = .{},
        .out_edges = undefined,
        .in_edges = undefined,
    };

    // Intersecting c (RPO 3) and b (RPO 2) should walk both fingers up to root.
    const result = intersect(&ctx, idom, 3, 2, &stats);
    try std.testing.expectEqual(@as(u32, 0), result);
    try std.testing.expect(stats.intersect_steps_total > 0);
}
