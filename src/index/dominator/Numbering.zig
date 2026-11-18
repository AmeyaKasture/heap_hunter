//! Shared iterative DFS numbering for dominator computation.
const std = @import("std");
const CsrView = @import("CsrView.zig").CsrView;

const NONE = std.math.maxInt(u32);

/// Which DFS products to emit. The reverse-postorder products (`rpo_vertex`,
/// plus `rpo_num` for CHK) and the DFS-tree products (`dfn`, `dfn_vertex`,
/// `parent`, for Lengauer-Tarjan) are never needed together, so they
/// alternate to keep the stage's per-node footprint minimal.
pub const Options = struct {
    /// Emit `dfn` (ordinal -> preorder slot), `dfn_vertex` (preorder slot ->
    /// ordinal), and `parent` (preorder slot -> parent's preorder slot).
    /// When false, `rpo_num` is emitted instead.
    emit_dfs_tree: bool = false,
};

pub const Numbering = struct {
    n_nodes: u32,
    n_reachable: u32,
    /// Ordinal -> reverse-postorder slot. Empty in dfs-tree mode; only the
    /// CHK backend consumes it.
    rpo_num: []u32,
    /// Reverse-postorder slot -> ordinal. Always emitted: the orchestrator
    /// writes dom_order.bin from it and sweeps retained sizes with it.
    rpo_vertex: []u32,
    reachable: []bool,
    max_depth: u32,
    // --- DFS-tree products (dfs-tree mode only) ---
    /// Ordinal -> preorder slot (NONE when unreachable).
    dfn: []u32 = &.{},
    /// Preorder slot -> ordinal.
    dfn_vertex: []u32 = &.{},
    /// Preorder slot -> parent's preorder slot (NONE for the virtual root).
    /// Stored in preorder space so the Lengauer-Tarjan backend's main loop
    /// reads it sequentially.
    parent: []u32 = &.{},

    pub fn deinit(self: *Numbering, allocator: std.mem.Allocator) void {
        if (self.rpo_num.len != 0) allocator.free(self.rpo_num);
        allocator.free(self.rpo_vertex);
        allocator.free(self.reachable);
        if (self.dfn.len != 0) allocator.free(self.dfn);
        if (self.dfn_vertex.len != 0) allocator.free(self.dfn_vertex);
        if (self.parent.len != 0) allocator.free(self.parent);
    }

    /// Release the DFS-tree products once the backend no longer needs them,
    /// so the orchestrator's output arrays do not stack on top of them.
    pub fn releaseDfsTree(self: *Numbering, allocator: std.mem.Allocator) void {
        if (self.dfn.len != 0) allocator.free(self.dfn);
        if (self.dfn_vertex.len != 0) allocator.free(self.dfn_vertex);
        if (self.parent.len != 0) allocator.free(self.parent);
        self.dfn = &.{};
        self.dfn_vertex = &.{};
        self.parent = &.{};
    }
};

const StackFrame = struct {
    node: u32,
    cursor: u32,
};

/// Iterative DFS from the virtual root over the forward CSR.
/// Never recurses: a 100M-node linked list must not overflow the stack.
pub fn compute(
    allocator: std.mem.Allocator,
    n_nodes: u32,
    out_edges: *const CsrView,
    options: Options,
) !Numbering {
    const emit_tree = options.emit_dfs_tree;

    const reachable = try allocator.alloc(bool, n_nodes);
    errdefer allocator.free(reachable);
    @memset(reachable, false);

    // Reverse-postorder products. `rpo_vertex` is needed by the orchestrator
    // regardless of backend; `rpo_num` is CHK-only and is skipped in
    // dfs-tree mode to save 4 B/node.
    var rpo_num: []u32 = &.{};
    if (!emit_tree) {
        rpo_num = try allocator.alloc(u32, n_nodes);
        errdefer allocator.free(rpo_num);
        @memset(rpo_num, NONE);
    }

    // DFS-tree products, emitted only when the Lengauer-Tarjan backend will
    // consume them. All three are indexed by (or map into) preorder space.
    var dfn: []u32 = &.{};
    var dfn_vertex: []u32 = &.{};
    var parent: []u32 = &.{};
    if (emit_tree) {
        dfn = try allocator.alloc(u32, n_nodes);
        errdefer allocator.free(dfn);
        @memset(dfn, NONE);

        dfn_vertex = try allocator.alloc(u32, n_nodes);
        errdefer allocator.free(dfn_vertex);

        parent = try allocator.alloc(u32, n_nodes);
        errdefer allocator.free(parent);
        @memset(parent, NONE);
    }

    const rpo_vertex = try allocator.alloc(u32, n_nodes);
    errdefer allocator.free(rpo_vertex);

    const root = n_nodes - 1;
    reachable[root] = true;

    var stack = std.ArrayList(StackFrame).empty;
    errdefer stack.deinit(allocator);
    try stack.append(allocator, .{ .node = root, .cursor = 0 });

    var post_list = std.ArrayList(u32).empty;
    errdefer post_list.deinit(allocator);
    try post_list.ensureTotalCapacity(allocator, n_nodes);

    var max_depth: u32 = 0;
    var next_dfn: u32 = 0;
    if (emit_tree) {
        // The virtual root is discovered first: preorder slot 0.
        dfn[root] = 0;
        dfn_vertex[0] = root;
        next_dfn = 1;
    }

    while (stack.items.len > 0) {
        const top_idx = stack.items.len - 1;
        const top = &stack.items[top_idx];
        const succs = out_edges.edges(top.node);
        if (top.cursor < succs.len) {
            const w = succs[top.cursor];
            top.cursor += 1;
            if (w == top.node) continue;
            if (w >= n_nodes) continue;
            if (reachable[w]) continue;
            reachable[w] = true;
            if (emit_tree) {
                // Assign the preorder slot at discovery; the parent's slot
                // was assigned when the parent was pushed, so the tree
                // parent comes for free.
                dfn[w] = next_dfn;
                dfn_vertex[next_dfn] = w;
                parent[next_dfn] = dfn[top.node];
                next_dfn += 1;
            }
            try stack.append(allocator, .{ .node = w, .cursor = 0 });
            if (stack.items.len > max_depth) {
                max_depth = @intCast(stack.items.len);
            }
        } else {
            try post_list.append(allocator, top.node);
            _ = stack.pop();
        }
    }

    const n_reachable: u32 = @intCast(post_list.items.len);
    std.debug.assert(!emit_tree or n_reachable == next_dfn);
    var i: u32 = 0;
    if (!emit_tree) {
        while (i < n_reachable) : (i += 1) {
            const node = post_list.items[n_reachable - 1 - i];
            rpo_vertex[i] = node;
            rpo_num[node] = i;
        }
    } else {
        while (i < n_reachable) : (i += 1) {
            rpo_vertex[i] = post_list.items[n_reachable - 1 - i];
        }
    }

    stack.deinit(allocator);
    post_list.deinit(allocator);

    return .{
        .n_nodes = n_nodes,
        .n_reachable = n_reachable,
        .rpo_num = rpo_num,
        .rpo_vertex = rpo_vertex,
        .reachable = reachable,
        .max_depth = max_depth,
        .dfn = dfn,
        .dfn_vertex = dfn_vertex,
        .parent = parent,
    };
}

comptime {
    std.debug.assert(@sizeOf(StackFrame) == 8);
}

test "dominator dfs stack frame is eight bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(StackFrame));
}

test "dominator numbering computes reverse postorder with the root first" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // 4 nodes: 0,1,2 real; 3 virtual root.
    // Edges: 3->0, 3->1, 0->2, 1->2.
    const offsets = &[_]u64{ 0, 1, 2, 2, 4 };
    const targets = &[_]u32{ 2, 2, 0, 1 };

    const offsets_path = try std.fs.path.join(allocator, &.{ tmp_path, "offsets.bin" });
    defer allocator.free(offsets_path);
    const adj_path = try std.fs.path.join(allocator, &.{ tmp_path, "adj.bin" });
    defer allocator.free(adj_path);

    try writeCsr(io, offsets_path, adj_path, offsets, targets);

    const offsets_data = try Io.Dir.cwd().readFileAlloc(io, offsets_path, allocator, .unlimited);
    defer allocator.free(offsets_data);
    const adj_data = try Io.Dir.cwd().readFileAlloc(io, adj_path, allocator, .unlimited);
    defer allocator.free(adj_data);

    const view = CsrView.init(4, offsets_data, adj_data);
    var numbering = try compute(allocator, 4, &view, .{});
    defer numbering.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), numbering.n_reachable);
    try std.testing.expectEqual(@as(u32, 3), numbering.rpo_vertex[0]);
    try std.testing.expectEqual(@as(u32, 0), numbering.rpo_num[3]);
    try std.testing.expect(numbering.rpo_num[0] > 0);
    try std.testing.expect(numbering.rpo_num[1] > 0);
    try std.testing.expect(numbering.rpo_num[2] > 0);
    // Without the dfs-tree request the tree products stay unallocated.
    try std.testing.expectEqual(@as(usize, 0), numbering.dfn.len);
    try std.testing.expectEqual(@as(usize, 0), numbering.dfn_vertex.len);
    try std.testing.expectEqual(@as(usize, 0), numbering.parent.len);
}

test "dominator numbering emits dfs preorder slots and tree parents on demand" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // Same diamond as the rpo test: 4 nodes (0,1,2 real; 3 virtual root).
    // Edges: 3->0, 3->1, 0->2, 1->2. With sorted successor lists the DFS
    // discovers 3 (slot 0), 0 (slot 1), 2 (slot 2), then 1 (slot 3).
    const offsets = &[_]u64{ 0, 1, 2, 2, 4 };
    const targets = &[_]u32{ 2, 2, 0, 1 };

    const offsets_path = try std.fs.path.join(allocator, &.{ tmp_path, "offsets.bin" });
    defer allocator.free(offsets_path);
    const adj_path = try std.fs.path.join(allocator, &.{ tmp_path, "adj.bin" });
    defer allocator.free(adj_path);

    try writeCsr(io, offsets_path, adj_path, offsets, targets);

    const offsets_data = try Io.Dir.cwd().readFileAlloc(io, offsets_path, allocator, .unlimited);
    defer allocator.free(offsets_data);
    const adj_data = try Io.Dir.cwd().readFileAlloc(io, adj_path, allocator, .unlimited);
    defer allocator.free(adj_data);

    const view = CsrView.init(4, offsets_data, adj_data);
    var numbering = try compute(allocator, 4, &view, .{ .emit_dfs_tree = true });
    defer numbering.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), numbering.n_reachable);

    // Root occupies preorder slot 0 and has no tree parent.
    try std.testing.expectEqual(@as(u32, 3), numbering.dfn_vertex[0]);
    try std.testing.expectEqual(@as(u32, 0), numbering.dfn[3]);
    try std.testing.expectEqual(NONE, numbering.parent[0]);

    // Node 0 is discovered from the root: slot 1, parent slot 0.
    try std.testing.expectEqual(@as(u32, 1), numbering.dfn[0]);
    try std.testing.expectEqual(numbering.dfn[3], numbering.parent[numbering.dfn[0]]);

    // Node 2 is discovered from 0: slot 2, parent slot 1.
    try std.testing.expectEqual(@as(u32, 2), numbering.dfn[2]);
    try std.testing.expectEqual(numbering.dfn[0], numbering.parent[numbering.dfn[2]]);

    // Node 1 is discovered from the root after 0's subtree: slot 3.
    try std.testing.expectEqual(@as(u32, 3), numbering.dfn[1]);
    try std.testing.expectEqual(numbering.dfn[3], numbering.parent[numbering.dfn[1]]);

    // dfn and dfn_vertex are inverses of each other.
    for (0..4) |v| {
        try std.testing.expectEqual(@as(u32, @intCast(v)), numbering.dfn_vertex[numbering.dfn[v]]);
    }

    // In dfs-tree mode the CHK-only rpo_num is skipped.
    try std.testing.expectEqual(@as(usize, 0), numbering.rpo_num.len);
}

test "dominator numbering is iterative and handles a million node chain" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const n: u32 = 1_000_000;
    const n_nodes = n + 1; // include virtual root

    const offsets = try allocator.alloc(u64, n_nodes + 1);
    defer allocator.free(offsets);
    const targets = try allocator.alloc(u32, n);
    defer allocator.free(targets);

    // Chain: root(n) -> 0 -> 1 -> ... -> 999999.
    // Nodes 0..n-2 each have one outbound edge; node n-1 has none; root has one.
    var i: u32 = 0;
    while (i <= n) : (i += 1) {
        offsets[i] = i;
    }
    // Node n-1 has no outgoing edges, so its start/end are both n-1.
    offsets[n] = n - 1;
    // Virtual root node n uses target[n-1] to point to node 0.
    offsets[n + 1] = n;

    i = 0;
    while (i < n - 1) : (i += 1) {
        targets[i] = i + 1;
    }
    targets[n - 1] = 0;

    const offsets_path = try std.fs.path.join(allocator, &.{ tmp_path, "offsets.bin" });
    defer allocator.free(offsets_path);
    const adj_path = try std.fs.path.join(allocator, &.{ tmp_path, "adj.bin" });
    defer allocator.free(adj_path);

    try writeCsr(io, offsets_path, adj_path, offsets, targets);

    const offsets_data = try Io.Dir.cwd().readFileAlloc(io, offsets_path, allocator, .unlimited);
    defer allocator.free(offsets_data);
    const adj_data = try Io.Dir.cwd().readFileAlloc(io, adj_path, allocator, .unlimited);
    defer allocator.free(adj_data);

    const view = CsrView.init(@intCast(n_nodes), offsets_data, adj_data);
    var numbering = try compute(allocator, @intCast(n_nodes), &view, .{ .emit_dfs_tree = true });
    defer numbering.deinit(allocator);

    try std.testing.expectEqual(n_nodes, numbering.n_reachable);
    try std.testing.expectEqual(n_nodes, numbering.max_depth);
    try std.testing.expectEqual(@as(u32, n_nodes - 1), numbering.rpo_vertex[0]);

    // The chain is discovered in order, so node k gets preorder slot k+1
    // (the root holds slot 0) and every non-root node's parent slot is one
    // less than its own.
    for (0..n) |k| {
        const v: u32 = @intCast(k);
        try std.testing.expectEqual(v + 1, numbering.dfn[v]);
        try std.testing.expectEqual(v, numbering.dfn_vertex[v + 1]);
        try std.testing.expectEqual(v, numbering.parent[v + 1]);
    }
    try std.testing.expectEqual(NONE, numbering.parent[0]);

    // Releasing the tree products frees exactly the dfs-tree arrays and
    // leaves the shared products intact for the orchestrator.
    numbering.releaseDfsTree(allocator);
    try std.testing.expectEqual(@as(usize, 0), numbering.dfn.len);
    try std.testing.expectEqual(@as(usize, 0), numbering.dfn_vertex.len);
    try std.testing.expectEqual(@as(usize, 0), numbering.parent.len);
    try std.testing.expectEqual(n_nodes, numbering.rpo_vertex.len);
}

fn writeCsr(
    io: Io,
    offsets_path: []const u8,
    adj_path: []const u8,
    offsets: []const u64,
    targets: []const u32,
) !void {
    {
        const f = try Io.Dir.cwd().createFile(io, offsets_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var writer: Io.File.Writer = .init(f, io, &buf);
        for (offsets) |off| {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, off, .little);
            try writer.interface.writeAll(&b);
        }
        try writer.flush();
    }
    {
        const f = try Io.Dir.cwd().createFile(io, adj_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var writer: Io.File.Writer = .init(f, io, &buf);
        for (targets) |t| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, t, .little);
            try writer.interface.writeAll(&b);
        }
        try writer.flush();
    }
}

const Io = std.Io;
