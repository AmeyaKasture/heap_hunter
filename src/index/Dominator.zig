//! Stage 7: compute the dominator tree of the heap flow graph and the
//! retained sizes derived from it (Lengauer-Tarjan).
const std = @import("std");
const Io = std.Io;
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Scanner = @import("Scanner.zig");
const CatalogSorter = @import("CatalogSorter.zig");
const Csr = @import("Csr.zig");

pub const dom_parent_entry_size = 4;
pub const dom_order_entry_size = 4;
pub const retained_entry_size = 8;

pub const NONE = std.math.maxInt(u32);

pub const Result = struct {
    dom_parent_path: []const u8,
    dom_order_path: []const u8,
    retained_path: []const u8,
    n_reachable: u64,
    unreachable_objects: u64,
    total_retained_bytes: u64,

    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.dom_parent_path);
        allocator.free(self.dom_order_path);
        allocator.free(self.retained_path);
    }
};

pub const Error = error{
    DominatorBudgetExceeded,
    InvalidCatalogFile,
    InvalidCsrFile,
};

const MappedFile = struct {
    file: Io.File,
    mm: ?Io.File.MemoryMap,
    fn open(io: Io, path: []const u8) !MappedFile {
        const dir = Io.Dir.cwd();
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        const len = try file.length(io);
        if (len == 0) return .{ .file = file, .mm = null };
        const mm = try Io.File.MemoryMap.create(io, file, .{
            .len = len,
            .protection = .{ .read = true, .write = false },
            .populate = true,
        });
        return .{ .file = file, .mm = mm };
    }
    fn close(self: *MappedFile, io: Io) void {
        if (self.mm) |*mm| mm.destroy(io);
        self.file.close(io);
    }
    fn data(self: *const MappedFile) []const u8 {
        if (self.mm) |mm| return mm.memory;
        return &.{};
    }
};

fn readU32LE(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}
fn readU64LE(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

fn outEdges(offsets: []const u8, targets: []const u8, node: u32) []align(1) const u32 {
    const off = @as(usize, node) * 8;
    const start = readU64LE(offsets, off);
    const end = readU64LE(offsets, off + 8);
    const base = start * 4;
    const len = (end - start) * 4;
    const bytes = targets[base .. base + len];
    return std.mem.bytesAsSlice(u32, bytes);
}

fn inEdges(offsets: []const u8, sources: []const u8, node: u32) []align(1) const u32 {
    return outEdges(offsets, sources, node);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    out_offsets_path: []const u8,
    out_targets_path: []const u8,
    in_offsets_path: []const u8,
    in_sources_path: []const u8,
    catalog_path: []const u8,
    n_objects: u64,
    n_edges: u64,
    diagnostics: *Manifest.Diagnostics,
) !Result {
    _ = n_edges;
    if (n_objects + 1 > std.math.maxInt(u32) - 1) return error.InvalidCsrFile;
    const V: u32 = @intCast(n_objects + 1);
    const root: u32 = V - 1;

    const bytes_per_node: u64 = 80;
    const needed = @as(u64, V) * bytes_per_node;
    const dom_budget = if (job.dominator_budget_bytes == 0) job.budget_bytes else job.dominator_budget_bytes;
    if (needed > dom_budget) return error.DominatorBudgetExceeded;

    var out_off_mf = try MappedFile.open(io, out_offsets_path);
    defer out_off_mf.close(io);
    var out_tgt_mf = try MappedFile.open(io, out_targets_path);
    defer out_tgt_mf.close(io);
    var in_off_mf = try MappedFile.open(io, in_offsets_path);
    defer in_off_mf.close(io);
    var in_src_mf = try MappedFile.open(io, in_sources_path);
    defer in_src_mf.close(io);

    const out_offsets = out_off_mf.data();
    const out_targets = out_tgt_mf.data();
    const in_offsets = in_off_mf.data();
    const in_sources = in_src_mf.data();

    const rpo_num = try allocator.alloc(u32, V); // preorder number (dfn)
    defer allocator.free(rpo_num);
    const vertex = try allocator.alloc(u32, V); // preorder slot -> node
    defer allocator.free(vertex);
    const parent_arr = try allocator.alloc(u32, V);
    defer allocator.free(parent_arr);
    const semi = try allocator.alloc(u32, V); // semi-dominator node
    defer allocator.free(semi);
    const idom = try allocator.alloc(u32, V);
    defer allocator.free(idom);
    const ancestor = try allocator.alloc(u32, V);
    defer allocator.free(ancestor);
    const path_buf = try allocator.alloc(u32, V);
    defer allocator.free(path_buf);
    const label = try allocator.alloc(u32, V);
    defer allocator.free(label);
    const bucket_head = try allocator.alloc(u32, V);
    defer allocator.free(bucket_head);
    const bucket_next = try allocator.alloc(u32, V);
    defer allocator.free(bucket_next);
    const visited = try allocator.alloc(bool, V);
    defer allocator.free(visited);
    const reachable = try allocator.alloc(bool, V);
    defer allocator.free(reachable);

    @memset(rpo_num, 0);
    @memset(vertex, 0);
    @memset(parent_arr, 0);
    @memset(semi, 0);
    @memset(idom, NONE);
    @memset(ancestor, NONE);
    @memset(label, 0);
    @memset(bucket_head, NONE);
    @memset(bucket_next, NONE);
    @memset(visited, false);
    @memset(reachable, false);

    var cat_mf = try MappedFile.open(io, catalog_path);
    defer cat_mf.close(io);
    const catalog_data = cat_mf.data();
    if (catalog_data.len % Scanner.catalog_row_size != 0) return error.InvalidCatalogFile;
    if (catalog_data.len / Scanner.catalog_row_size != n_objects) return error.InvalidCatalogFile;

    const shallow = try allocator.alloc(u32, V);
    defer allocator.free(shallow);
    shallow[V - 1] = 0;
    var oi: u64 = 0;
    while (oi < n_objects) : (oi += 1) {
        const row = Scanner.readCatalogRow(catalog_data[oi * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size]) catch return error.InvalidCatalogFile;
        shallow[@intCast(oi)] = row.shallow_size;
    }

    // --- Phase A: iterative DFS preorder from root over out CSR ---
    const Frame = struct { node: u32, idx: usize };
    var stack = std.ArrayList(Frame).empty;
    defer stack.deinit(allocator);

    visited[root] = true;
    parent_arr[root] = root;
    rpo_num[root] = 0;
    vertex[0] = root;
    var counter: u32 = 1;
    try stack.append(allocator, .{ .node = root, .idx = 0 });

    while (stack.items.len > 0) {
        const top_idx = stack.items.len - 1;
        const v = stack.items[top_idx].node;
        const succs = outEdges(out_offsets, out_targets, v);
        if (stack.items[top_idx].idx < succs.len) {
            const w = succs[stack.items[top_idx].idx];
            stack.items[top_idx].idx += 1;
            if (w == v) continue;
            if (w >= V) continue;
            if (!visited[w]) {
                visited[w] = true;
                parent_arr[w] = v;
                rpo_num[w] = counter;
                vertex[counter] = w;
                counter += 1;
                try stack.append(allocator, .{ .node = w, .idx = 0 });
            }
        } else {
            _ = stack.pop();
        }
    }

    for (0..V) |i| reachable[@intCast(i)] = visited[@intCast(i)];
    const n_reachable: u64 = counter;

    for (0..V) |i| {
        if (reachable[@intCast(i)]) {
            const node: u32 = @intCast(i);
            semi[node] = node;
            label[node] = node;
        }
    }

    // eval with path compression (iterative)
    const Eval = struct {
        fn compress(
            v: u32,
            ancestor_arr: []u32,
            label_arr: []u32,
            semi_arr: []const u32,
            rpo_arr: []const u32,
            path_buf_arr: []u32,
        ) void {
            var plen: usize = 0;
            var cur = v;
            while (ancestor_arr[cur] != NONE and ancestor_arr[ancestor_arr[cur]] != NONE) {
                if (plen >= path_buf_arr.len) return;
                path_buf_arr[plen] = cur;
                plen += 1;
                cur = ancestor_arr[cur];
            }
            var j = plen;
            while (j > 0) {
                j -= 1;
                const x = path_buf_arr[j];
                const anc = ancestor_arr[x];
                if (anc != NONE and ancestor_arr[anc] != NONE) {
                    if (rpo_arr[semi_arr[label_arr[anc]]] < rpo_arr[semi_arr[label_arr[x]]]) {
                        label_arr[x] = label_arr[anc];
                    }
                    ancestor_arr[x] = ancestor_arr[anc];
                }
            }
        }
        fn eval(
            v: u32,
            ancestor_arr: []u32,
            label_arr: []u32,
            semi_arr: []const u32,
            rpo_arr: []const u32,
            path_buf_arr: []u32,
        ) u32 {
            if (ancestor_arr[v] == NONE) return v;
            compress(v, ancestor_arr, label_arr, semi_arr, rpo_arr, path_buf_arr);
            return label_arr[v];
        }
    };

    // --- Phase B: semi-dominators + bucket drain (reverse preorder) ---
    var i: u32 = @intCast(n_reachable);
    while (i > 1) {
        i -= 1;
        const w = vertex[i];
        const preds = inEdges(in_offsets, in_sources, w);
        for (preds) |v| {
            if (!reachable[v]) continue;
            if (v == w) continue;
            const u = Eval.eval(v, ancestor, label, semi, rpo_num, path_buf);
            if (rpo_num[semi[u]] < rpo_num[semi[w]]) {
                semi[w] = semi[u];
            }
        }
        // push w to bucket of semi[w]
        const sw = semi[w];
        bucket_next[w] = bucket_head[sw];
        bucket_head[sw] = w;
        // drain this vertex's bucket while w is still unlinked, so eval()
        // returns candidates limited to the tree path strictly below w
        var vcur = bucket_head[w];
        while (vcur != NONE) {
            const u = Eval.eval(vcur, ancestor, label, semi, rpo_num, path_buf);
            if (semi[u] == semi[vcur]) {
                idom[vcur] = semi[vcur];
            } else {
                idom[vcur] = u;
            }
            vcur = bucket_next[vcur];
        }
        bucket_head[w] = NONE;
        // link parent[w], w
        ancestor[w] = parent_arr[w];
    }

    // --- Deferred idom resolution (preorder) ---
    idom[root] = root;
    var j: u32 = 1;
    while (j < @as(u32, @intCast(n_reachable))) : (j += 1) {
        const w = vertex[j];
        if (idom[w] == NONE or idom[w] != semi[w]) {
            const iv = idom[w];
            if (iv == NONE or iv >= V or idom[iv] == NONE) {
                idom[w] = root;
            } else {
                idom[w] = idom[iv];
            }
        }
    }

    // virtual root's parent = NONE
    idom[root] = NONE;

    // Build dom_parent
    const dom_parent = try allocator.alloc(u32, V);
    defer allocator.free(dom_parent);
    for (0..V) |idx| {
        const node: u32 = @intCast(idx);
        if (!reachable[node] or node == root) {
            dom_parent[node] = NONE;
        } else {
            dom_parent[node] = idom[node];
        }
    }

    var unreachable_count: u64 = 0;
    var uo: u32 = 0;
    while (uo < V - 1) : (uo += 1) {
        if (!reachable[uo]) unreachable_count += 1;
    }
    diagnostics.unreachable_objects = unreachable_count;

    // retained sizes: every reachable node accumulates its retained size into
    // its dominator tree parent, processed in reverse preorder (children before
    // parents). The virtual root ends up holding the total reachable heap.
    const retained = try allocator.alloc(u64, V);
    defer allocator.free(retained);
    for (0..V) |idx| {
        const node: u32 = @intCast(idx);
        if (node == root) retained[node] = 0 else retained[node] = shallow[node];
    }

    var slot: usize = n_reachable;
    while (slot > 1) {
        slot -= 1;
        const v = vertex[slot];
        const p = dom_parent[v];
        if (p == NONE) continue;
        retained[p] += retained[v];
    }

    var shallow_reachable: u64 = 0;
    var ri: u32 = 0;
    while (ri < V - 1) : (ri += 1) {
        if (reachable[ri]) shallow_reachable += shallow[ri];
    }
    retained[root] = shallow_reachable;

    // write files
    const dir = Io.Dir.cwd();
    const dom_parent_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "dom_parent.bin" });
    errdefer allocator.free(dom_parent_path);
    const dom_order_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "dom_order.bin" });
    errdefer allocator.free(dom_order_path);
    const retained_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "retained.bin" });
    errdefer allocator.free(retained_path);

    {
        var f = try dir.createFile(io, dom_parent_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var w: Io.File.Writer = .init(f, io, &buf);
        var node: u32 = 0;
        while (node < V) : (node += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, dom_parent[node], .little);
            try w.interface.writeAll(&b);
        }
        try w.flush();
    }
    {
        var f = try dir.createFile(io, dom_order_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var w: Io.File.Writer = .init(f, io, &buf);
        var slot2: usize = 0;
        while (slot2 < n_reachable) : (slot2 += 1) {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, vertex[slot2], .little);
            try w.interface.writeAll(&b);
        }
        try w.flush();
    }
    {
        var f = try dir.createFile(io, retained_path, .{});
        defer f.close(io);
        var buf: [65536]u8 = undefined;
        var w: Io.File.Writer = .init(f, io, &buf);
        var node: u32 = 0;
        while (node < V) : (node += 1) {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, retained[node], .little);
            try w.interface.writeAll(&b);
        }
        try w.flush();
    }

    return .{
        .dom_parent_path = dom_parent_path,
        .dom_order_path = dom_order_path,
        .retained_path = retained_path,
        .n_reachable = n_reachable,
        .unreachable_objects = unreachable_count,
        .total_retained_bytes = shallow_reachable,
    };
}
