//! Shared iterative DFS numbering for dominator computation.
const std = @import("std");
const CsrView = @import("CsrView.zig").CsrView;

pub const Numbering = struct {
    n_nodes: u32,
    n_reachable: u32,
    rpo_num: []u32,
    rpo_vertex: []u32,
    reachable: []bool,
    max_depth: u32,

    pub fn deinit(self: *Numbering, allocator: std.mem.Allocator) void {
        allocator.free(self.rpo_num);
        allocator.free(self.rpo_vertex);
        allocator.free(self.reachable);
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
) !Numbering {
    const reachable = try allocator.alloc(bool, n_nodes);
    errdefer allocator.free(reachable);
    @memset(reachable, false);

    const rpo_num = try allocator.alloc(u32, n_nodes);
    errdefer allocator.free(rpo_num);
    @memset(rpo_num, std.math.maxInt(u32));

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
    var i: u32 = 0;
    while (i < n_reachable) : (i += 1) {
        const node = post_list.items[n_reachable - 1 - i];
        rpo_vertex[i] = node;
        rpo_num[node] = i;
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
    var numbering = try compute(allocator, 4, &view);
    defer numbering.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), numbering.n_reachable);
    try std.testing.expectEqual(@as(u32, 3), numbering.rpo_vertex[0]);
    try std.testing.expectEqual(@as(u32, 0), numbering.rpo_num[3]);
    try std.testing.expect(numbering.rpo_num[0] > 0);
    try std.testing.expect(numbering.rpo_num[1] > 0);
    try std.testing.expect(numbering.rpo_num[2] > 0);
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
    var numbering = try compute(allocator, @intCast(n_nodes), &view);
    defer numbering.deinit(allocator);

    try std.testing.expectEqual(n_nodes, numbering.n_reachable);
    try std.testing.expectEqual(n_nodes, numbering.max_depth);
    try std.testing.expectEqual(@as(u32, n_nodes - 1), numbering.rpo_vertex[0]);
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
