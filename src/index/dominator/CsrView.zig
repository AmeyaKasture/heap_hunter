//! Read-only view over one CSR (compressed sparse row) file pair.
const std = @import("std");

pub const CsrView = struct {
    n_nodes: u32,
    offsets: []const u8,
    adjacency: []const u8,

    pub fn init(n_nodes: u32, offsets: []const u8, adjacency: []const u8) CsrView {
        return .{
            .n_nodes = n_nodes,
            .offsets = offsets,
            .adjacency = adjacency,
        };
    }

    inline fn start(self: *const CsrView, node: u32) u64 {
        const off = @as(usize, node) * 8;
        return std.mem.readInt(u64, self.offsets[off..][0..8], .little);
    }

    inline fn end(self: *const CsrView, node: u32) u64 {
        const off = (@as(usize, node) + 1) * 8;
        return std.mem.readInt(u64, self.offsets[off..][0..8], .little);
    }

    /// Neighbours of `node`. The returned slice is `[]align(1) const u32`.
    pub fn edges(self: *const CsrView, node: u32) []align(1) const u32 {
        const s = self.start(node);
        const e = self.end(node);
        const base = s * 4;
        const len = (e - s) * 4;
        return std.mem.bytesAsSlice(u32, self.adjacency[base .. base + len]);
    }

    pub fn degree(self: *const CsrView, node: u32) u32 {
        const s = self.start(node);
        const e = self.end(node);
        return @intCast(e - s);
    }

    pub fn validate(self: *const CsrView) !void {
        if (self.offsets.len != (@as(usize, self.n_nodes) + 1) * 8) return error.InvalidCsrFile;
        if (self.adjacency.len % 4 != 0) return error.InvalidCsrFile;
        if (self.end(self.n_nodes - 1) * 4 != self.adjacency.len) return error.InvalidCsrFile;
    }
};

test "dominator csr view returns the neighbours of a node" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // 3 nodes (0, 1, 2). Edges: 0->1, 0->2, 1->2.
    const offsets = &[_]u64{ 0, 2, 3, 3 };
    const targets = &[_]u32{ 1, 2, 2 };

    const offsets_path = try std.fs.path.join(allocator, &.{ tmp_path, "offsets.bin" });
    defer allocator.free(offsets_path);
    const adj_path = try std.fs.path.join(allocator, &.{ tmp_path, "adj.bin" });
    defer allocator.free(adj_path);

    {
        const f = try Io.Dir.cwd().createFile(io, offsets_path, .{});
        defer f.close(io);
        var buf: [4096]u8 = undefined;
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
        var buf: [4096]u8 = undefined;
        var writer: Io.File.Writer = .init(f, io, &buf);
        for (targets) |t| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, t, .little);
            try writer.interface.writeAll(&b);
        }
        try writer.flush();
    }

    const offsets_data = try Io.Dir.cwd().readFileAlloc(io, offsets_path, allocator, .unlimited);
    defer allocator.free(offsets_data);
    const adj_data = try Io.Dir.cwd().readFileAlloc(io, adj_path, allocator, .unlimited);
    defer allocator.free(adj_data);

    const view = CsrView.init(3, offsets_data, adj_data);
    try view.validate();

    const e0 = view.edges(0);
    try std.testing.expectEqual(@as(usize, 2), e0.len);
    try std.testing.expectEqual(@as(u32, 1), e0[0]);
    try std.testing.expectEqual(@as(u32, 2), e0[1]);

    const e1 = view.edges(1);
    try std.testing.expectEqual(@as(usize, 1), e1.len);
    try std.testing.expectEqual(@as(u32, 2), e1[0]);

    const e2 = view.edges(2);
    try std.testing.expectEqual(@as(usize, 0), e2.len);

    try std.testing.expectEqual(@as(u32, 2), view.degree(0));
    try std.testing.expectEqual(@as(u32, 1), view.degree(1));
    try std.testing.expectEqual(@as(u32, 0), view.degree(2));
}

test "dominator csr view rejects a malformed csr" {
    const offsets = &[_]u8{0} ** 8; // only 1 entry, need 4 for n_nodes=3
    const adj = &[_]u8{0} ** 4;
    const view = CsrView.init(3, offsets, adj);
    try std.testing.expectError(error.InvalidCsrFile, view.validate());
}

const Io = std.Io;
