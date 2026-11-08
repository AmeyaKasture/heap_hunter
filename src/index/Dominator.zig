//! Stage 7: compute the dominator tree of the heap flow graph and the
//! retained sizes derived from it using the Cooper-Harvey-Kennedy (CHK)
//! iterative algorithm.
//!
//! High-performance implementation: reachability/RPO discovery, parallel CHK
//! idom refinement (Jacobi double-buffered, race-free), and retained-size
//! accumulation.
const std = @import("std");
const Io = std.Io;
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Scanner = @import("Scanner.zig");

pub const dom_parent_entry_size = 4;
pub const dom_order_entry_size = 4;
pub const retained_entry_size = 8;

pub const NONE: u32 = std.math.maxInt(u32);

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
    DominatorDidNotConverge,
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
    if (offsets.len < (@as(usize, node) + 2) * 8) return &[_]u32{};
    const off = @as(usize, node) * 8;
    const start = readU64LE(offsets, off);
    const end = readU64LE(offsets, off + 8);
    if (end < start) return &[_]u32{};
    const base = start * 4;
    const len_bytes = (end - start) * 4;
    if (base + len_bytes > targets.len) return &[_]u32{};
    return std.mem.bytesAsSlice(u32, targets[base .. base + len_bytes]);
}

fn inEdges(offsets: []const u8, sources: []const u8, node: u32) []align(1) const u32 {
    return outEdges(offsets, sources, node);
}

fn threadCountFor(n_reachable: u32) usize {
    if (n_reachable < 4096) return 1;
    const cpu = std.Thread.getCpuCount() catch 1;
    const by_work = @max(@as(usize, 1), @as(usize, n_reachable) / 2048);
    const n = @min(cpu, by_work);
    return @max(@as(usize, 1), @min(n, 32));
}

const IntersectCtx = struct {
    rpo_id: []const u32,
    idom: []const u32,
};

/// CHK finger intersection. Assumes inputs are reachable nodes with valid rpo_id/idom.
inline fn intersectDominators(a0: u32, b0: u32, ctx: IntersectCtx) u32 {
    var a = a0;
    var b = b0;
    // Bound iterations defensively; valid idom climbs toward root.
    var guard: u32 = 0;
    const max_guard: u32 = @intCast(@min(ctx.rpo_id.len, std.math.maxInt(u32)));
    while (a != b and guard < max_guard) : (guard += 1) {
        const ra = ctx.rpo_id[a];
        const rb = ctx.rpo_id[b];
        // rpo_id 0 means not in RPO mapping (should not happen for reachable); climb conservatively.
        if (ra == 0) {
            a = ctx.idom[a];
            if (a == NONE or a == a0) return b;
            continue;
        }
        if (rb == 0) {
            b = ctx.idom[b];
            if (b == NONE or b == b0) return a;
            continue;
        }
        if (ra < rb) {
            b = ctx.idom[b];
        } else {
            a = ctx.idom[a];
        }
        if (a == NONE) return b;
        if (b == NONE) return a;
    }
    return a;
}

fn pickInitialIdom(
    v: u32,
    preds: []align(1) const u32,
    reachable: []const bool,
    rpo_id: []const u32,
    dfs_parent: []const u32,
    root: u32,
) u32 {
    // Prefer a reachable predecessor with smallest RPO id (CHK init heuristic).
    var best: u32 = NONE;
    var best_rpo: u32 = std.math.maxInt(u32);
    for (preds) |p| {
        if (p >= reachable.len) continue;
        if (!reachable[p]) continue;
        if (p == v) continue;
        const rp = rpo_id[p];
        if (rp == 0) continue;
        if (rp < best_rpo) {
            best_rpo = rp;
            best = p;
        }
    }
    if (best != NONE) return best;
    const par = dfs_parent[v];
    if (par < reachable.len and reachable[par] and rpo_id[par] != 0) return par;
    return root;
}

const ChkWorkerArgs = struct {
    start: usize, // index into vertex/rpo order (inclusive), >= 1
    end: usize, // exclusive
    root: u32,
    V: usize,
    vertex: []const u32,
    rpo_id: []const u32,
    idom: []const u32,
    idom_next: []u32,
    reachable: []const bool,
    in_offsets: []const u8,
    in_sources: []const u8,
    changed: *std.atomic.Value(bool),
};

fn chkWorker(args: *ChkWorkerArgs) void {
    var local_changed = false;
    const ctx = IntersectCtx{ .rpo_id = args.rpo_id, .idom = args.idom };
    var i = args.start;
    while (i < args.end) : (i += 1) {
        const v = args.vertex[i];
        if (v == args.root) {
            args.idom_next[v] = args.root;
            continue;
        }
        if (v >= args.V or !args.reachable[v]) {
            if (v < args.V) args.idom_next[v] = NONE;
            continue;
        }

        const preds = inEdges(args.in_offsets, args.in_sources, v);
        var new_idom: u32 = NONE;
        for (preds) |p| {
            if (p >= args.V) continue;
            if (!args.reachable[p]) continue;
            if (p == v) continue;
            const rp = args.rpo_id[p];
            if (rp == 0) continue;
            if (new_idom == NONE) {
                new_idom = p;
            } else {
                new_idom = intersectDominators(p, new_idom, ctx);
            }
        }
        if (new_idom == NONE) new_idom = args.root;
        args.idom_next[v] = new_idom;
        if (new_idom != args.idom[v]) local_changed = true;
    }
    if (local_changed) args.changed.store(true, .monotonic);
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
    const V_usize: usize = @intCast(V);
    const root: u32 = V - 1;

    // Budget precheck for CHK working set (approximate, conservative).
    // Core arrays: reachable bool(1) + rpo_id u32(4) + vertex u32(4) + dfs_parent u32(4)
    // + idom u32(4) + idom_next u32(4) + dom_parent u32(4) + shallow u32(4) + retained u64(8)
    // + postorder temp u32(4) + DFS stack overhead margin.
    const bytes_per_node: u64 = 56;
    const needed = @as(u64, V) * bytes_per_node;
    const dom_budget = if (job.dominator_budget_bytes != 0) job.dominator_budget_bytes else if (job.budget_bytes != 0) job.budget_bytes else @as(usize, 4096) * 1024 * 1024;
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

    const reachable = try allocator.alloc(bool, V_usize);
    defer allocator.free(reachable);
    @memset(reachable, false);
    const rpo_id = try allocator.alloc(u32, V_usize); // 1..k, 0 = not in RPO
    defer allocator.free(rpo_id);
    @memset(rpo_id, 0);
    const vertex = try allocator.alloc(u32, V_usize); // RPO list
    defer allocator.free(vertex);
    @memset(vertex, 0);
    const dfs_parent = try allocator.alloc(u32, V_usize);
    defer allocator.free(dfs_parent);
    @memset(dfs_parent, NONE);

    var cat_mf = try MappedFile.open(io, catalog_path);
    defer cat_mf.close(io);
    const catalog_data = cat_mf.data();
    if (catalog_data.len % Scanner.catalog_row_size != 0) return error.InvalidCatalogFile;
    if (catalog_data.len / Scanner.catalog_row_size != n_objects) return error.InvalidCatalogFile;

    const shallow = try allocator.alloc(u32, V_usize);
    defer allocator.free(shallow);
    shallow[V_usize - 1] = 0;
    var oi: u64 = 0;
    while (oi < n_objects) : (oi += 1) {
        const row = Scanner.readCatalogRow(catalog_data[oi * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size]) catch return error.InvalidCatalogFile;
        shallow[@intCast(oi)] = row.shallow_size;
    }

    // --- Phase A: iterative DFS from root to compute reachability + reverse postorder (CHK) ---
    // We need: reachable set, DFS tree parent (for init heuristic), and vertex[] in RPO with rpo_id.
    const Frame = struct { node: u32, idx: usize, entered: bool };
    var stack = std.ArrayList(Frame).empty;
    defer stack.deinit(allocator);

    const postorder = try allocator.alloc(u32, V_usize);
    defer allocator.free(postorder);
    var post_n: u32 = 0;

    reachable[root] = true;
    dfs_parent[root] = root;
    try stack.append(allocator, .{ .node = root, .idx = 0, .entered = false });

    while (stack.items.len > 0) {
        const ti = stack.items.len - 1;
        var fr = &stack.items[ti];
        if (!fr.entered) {
            fr.entered = true;
        }
        const v = fr.node;
        const succs = outEdges(out_offsets, out_targets, v);
        if (fr.idx < succs.len) {
            const w = succs[fr.idx];
            fr.idx += 1;
            if (w == v) continue;
            if (w >= V) continue;
            if (!reachable[w]) {
                reachable[w] = true;
                dfs_parent[w] = v;
                try stack.append(allocator, .{ .node = w, .idx = 0, .entered = false });
            }
        } else {
            postorder[post_n] = v;
            post_n += 1;
            _ = stack.pop();
        }
    }

    // Reverse postorder -> vertex[0..n_reachable), root should be first
    var n_reachable: u32 = post_n;
    var i: u32 = 0;
    while (i < n_reachable) : (i += 1) {
        const v = postorder[n_reachable - 1 - i];
        vertex[i] = v;
        rpo_id[v] = i + 1; // 1-based
    }
    if (n_reachable == 0) {
        n_reachable = 1;
        vertex[0] = root;
        rpo_id[root] = 1;
        reachable[root] = true;
        dfs_parent[root] = root;
    }

    const idom = try allocator.alloc(u32, V_usize);
    defer allocator.free(idom);
    @memset(idom, NONE);
    const idom_next = try allocator.alloc(u32, V_usize);
    defer allocator.free(idom_next);
    @memset(idom_next, NONE);

    // --- CHK init ---
    idom[root] = root;
    var vi: u32 = 1;
    while (vi < n_reachable) : (vi += 1) {
        const v = vertex[vi];
        idom[v] = pickInitialIdom(v, inEdges(in_offsets, in_sources, v), reachable, rpo_id, dfs_parent, root);
    }
    // unreachable/unvisited stay NONE

    // --- CHK iterative refinement, parallel Jacobi double-buffer ---
    const max_iters: u32 = 10_000;
    const n_threads = threadCountFor(n_reachable);
    var iter: u32 = 0;
    while (iter < max_iters) : (iter += 1) {
        // copy current into next for untouched entries (unreachable/root/others)
        @memcpy(idom_next, idom);

        var changed = std.atomic.Value(bool).init(false);
        if (n_threads <= 1 or n_reachable <= 2) {
            var args = ChkWorkerArgs{
                .start = 1,
                .end = n_reachable,
                .root = root,
                .V = V_usize,
                .vertex = vertex[0..n_reachable],
                .rpo_id = rpo_id,
                .idom = idom,
                .idom_next = idom_next,
                .reachable = reachable,
                .in_offsets = in_offsets,
                .in_sources = in_sources,
                .changed = &changed,
            };
            chkWorker(&args);
        } else {
            var threads = try allocator.alloc(std.Thread, n_threads);
            defer allocator.free(threads);
            var worker_args = try allocator.alloc(ChkWorkerArgs, n_threads);
            defer allocator.free(worker_args);
            var spawned: usize = 0;
            errdefer {
                var j: usize = 0;
                while (j < spawned) : (j += 1) threads[j].join();
            }

            const work = @as(usize, n_reachable - 1);
            var t: usize = 0;
            while (t < n_threads) : (t += 1) {
                const start_rel = (work * t) / n_threads;
                const end_rel = (work * (t + 1)) / n_threads;
                worker_args[t] = .{
                    .start = 1 + start_rel,
                    .end = 1 + end_rel,
                    .root = root,
                    .V = V_usize,
                    .vertex = vertex[0..n_reachable],
                    .rpo_id = rpo_id,
                    .idom = idom,
                    .idom_next = idom_next,
                    .reachable = reachable,
                    .in_offsets = in_offsets,
                    .in_sources = in_sources,
                    .changed = &changed,
                };
                threads[t] = try std.Thread.spawn(.{}, chkWorker, .{&worker_args[t]});
                spawned += 1;
            }
            var j: usize = 0;
            while (j < spawned) : (j += 1) threads[j].join();
        }

        // commit Jacobi buffer
        @memcpy(idom, idom_next);

        if (!changed.load(.monotonic)) break;
    } else {
        return error.DominatorDidNotConverge;
    }

    // --- materialize dom_parent ---
    const dom_parent = try allocator.alloc(u32, V_usize);
    defer allocator.free(dom_parent);
    var di: usize = 0;
    while (di < V_usize) : (di += 1) {
        const node: u32 = @intCast(di);
        if (node == root or !reachable[di]) {
            dom_parent[di] = NONE;
        } else {
            const p = idom[di];
            if (p == NONE or p == node) {
                dom_parent[di] = root; // conservative fallback inside reachable graph
            } else {
                dom_parent[di] = p;
            }
        }
    }

    var unreachable_count: u64 = 0;
    var uo: u32 = 0;
    while (uo < V - 1) : (uo += 1) {
        if (!reachable[uo]) unreachable_count += 1;
    }
    diagnostics.unreachable_objects = unreachable_count;

    // --- retained sizes: bottom-up in reverse vertex/RPO order ---
    const retained = try allocator.alloc(u64, V_usize);
    defer allocator.free(retained);
    var rsi: usize = 0;
    while (rsi < V_usize) : (rsi += 1) {
        if (rsi == V_usize - 1) retained[rsi] = 0 else retained[rsi] = shallow[rsi];
    }

    var slot: usize = n_reachable;
    while (slot > 1) {
        slot -= 1;
        const v = vertex[slot];
        const p = dom_parent[v];
        if (p == NONE or p >= V) continue;
        retained[p] += retained[v];
    }

    var shallow_reachable: u64 = 0;
    var ri: u32 = 0;
    while (ri < V - 1) : (ri += 1) {
        if (reachable[ri]) shallow_reachable += shallow[ri];
    }
    retained[V_usize - 1] = shallow_reachable;

    // --- write files ---
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
        var buf: [262144]u8 = undefined;
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
        var buf: [262144]u8 = undefined;
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
        var buf: [262144]u8 = undefined;
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

// ---- tests ----

const test_io = std.testing.io;

fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    var buf: [16]u8 = undefined;
    test_io.random(&buf);
    const name = try std.fmt.allocPrint(allocator, "/tmp/hunt-dom-test-{x}", .{std.mem.readInt(u64, buf[0..8], .little)});
    try Io.Dir.cwd().createDirPath(test_io, name);
    return name;
}

fn writeOffsets(path: []const u8, offsets: []const u64) !void {
    const f = try Io.Dir.cwd().createFile(test_io, path, .{ .truncate = true });
    defer f.close(test_io);
    var buf: [4096]u8 = undefined;
    var w = Io.File.Writer.init(f, test_io, &buf);
    for (offsets) |o| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, o, .little);
        try w.interface.writeAll(&b);
    }
    try w.flush();
}

fn writeAdj(path: []const u8, vals: []const u32) !void {
    const f = try Io.Dir.cwd().createFile(test_io, path, .{ .truncate = true });
    defer f.close(test_io);
    var buf: [4096]u8 = undefined;
    var w = Io.File.Writer.init(f, test_io, &buf);
    for (vals) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.interface.writeAll(&b);
    }
    try w.flush();
}

fn writeCatalog(path: []const u8, shallows: []const u32) !void {
    const f = try Io.Dir.cwd().createFile(test_io, path, .{ .truncate = true });
    defer f.close(test_io);
    var buf: [4096]u8 = undefined;
    var w = Io.File.Writer.init(f, test_io, &buf);
    var row: [Scanner.catalog_row_size]u8 = [_]u8{0} ** Scanner.catalog_row_size;
    for (shallows, 0..) |s, i| {
        std.mem.writeInt(u64, row[0..8], @as(u64, i + 1), .little); // raw_id
        std.mem.writeInt(u32, row[24..28], s, .little); // shallow_size
        try w.interface.writeAll(&row);
    }
    try w.flush();
}

fn readU32File(allocator: std.mem.Allocator, path: []const u8) ![]u32 {
    const data = try Io.Dir.cwd().readFileAlloc(test_io, path, allocator, .unlimited);
    defer allocator.free(data);
    const n = data.len / 4;
    const out = try allocator.alloc(u32, n);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    return out;
}

fn readU64File(allocator: std.mem.Allocator, path: []const u8) ![]u64 {
    const data = try Io.Dir.cwd().readFileAlloc(test_io, path, allocator, .unlimited);
    defer allocator.free(data);
    const n = data.len / 8;
    const out = try allocator.alloc(u64, n);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = std.mem.readInt(u64, data[i * 8 ..][0..8], .little);
    return out;
}

test "CHK dominator: diamond retains at root dominator" {
    const allocator = std.testing.allocator;
    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);
    defer Io.Dir.cwd().deleteTree(test_io, dir) catch {};

    // 3 real objects + virtual root(3)
    // root(3)->0, root(3)->1, 0->2, 1->2
    const out_off = try std.fs.path.join(allocator, &.{ dir, "out_off.bin" });
    defer allocator.free(out_off);
    const out_tgt = try std.fs.path.join(allocator, &.{ dir, "out_tgt.bin" });
    defer allocator.free(out_tgt);
    const in_off = try std.fs.path.join(allocator, &.{ dir, "in_off.bin" });
    defer allocator.free(in_off);
    const in_src = try std.fs.path.join(allocator, &.{ dir, "in_src.bin" });
    defer allocator.free(in_src);
    const cat = try std.fs.path.join(allocator, &.{ dir, "cat.bin" });
    defer allocator.free(cat);

    try writeOffsets(out_off, &[_]u64{ 0, 1, 2, 2, 4 }); // 0->[2],1->[2],2->[],3->[0,1]
    try writeAdj(out_tgt, &[_]u32{ 2, 2, 0, 1 });
    try writeOffsets(in_off, &[_]u64{ 0, 1, 2, 4, 4 }); // 0<-[3],1<-[3],2<-[0,1],3<-[]
    try writeAdj(in_src, &[_]u32{ 3, 3, 0, 1 });
    try writeCatalog(cat, &[_]u32{ 10, 20, 30 });

    var diagnostics = Manifest.Diagnostics{};
    const fp = Manifest.Fingerprint{ .file_length = 0, .hprof_timestamp = 0, .id_size = 8, .hash_algorithm = "", .hash_value = "", .source_mtime = 0 };

    var job = Preflight.Job{
        .source_path = "x",
        .index_dir = dir,
        .staging_dir = dir,
        .budget_bytes = 64 * 1024 * 1024,
        .dominator_budget_bytes = 64 * 1024 * 1024,
        .fingerprint = fp,
        .header = .{ .id_size = 8, .timestamp = 0 },
    };

    var res = try run(allocator, test_io, &job, out_off, out_tgt, in_off, in_src, cat, 3, 4, &diagnostics);
    defer res.deinit(allocator);

    const parents = try readU32File(allocator, res.dom_parent_path);
    defer allocator.free(parents);
    const retained = try readU64File(allocator, res.retained_path);
    defer allocator.free(retained);

    try std.testing.expectEqual(@as(u32, 3), parents[0]); // root dominates 0
    try std.testing.expectEqual(@as(u32, 3), parents[1]); // root dominates 1
    try std.testing.expectEqual(@as(u32, 3), parents[2]); // diamond: root dominates 2
    try std.testing.expectEqual(NONE, parents[3]);
    try std.testing.expectEqual(@as(u64, 60), retained[3]); // total reachable shallow
    try std.testing.expectEqual(@as(u64, 10), retained[0]);
    try std.testing.expectEqual(@as(u64, 20), retained[1]);
    try std.testing.expectEqual(@as(u64, 30), retained[2]);
}

test "CHK dominator: chain retains accumulate" {
    const allocator = std.testing.allocator;
    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);
    defer Io.Dir.cwd().deleteTree(test_io, dir) catch {};

    // root(2)->0->1
    const out_off = try std.fs.path.join(allocator, &.{ dir, "out_off.bin" });
    defer allocator.free(out_off);
    const out_tgt = try std.fs.path.join(allocator, &.{ dir, "out_tgt.bin" });
    defer allocator.free(out_tgt);
    const in_off = try std.fs.path.join(allocator, &.{ dir, "in_off.bin" });
    defer allocator.free(in_off);
    const in_src = try std.fs.path.join(allocator, &.{ dir, "in_src.bin" });
    defer allocator.free(in_src);
    const cat = try std.fs.path.join(allocator, &.{ dir, "cat.bin" });
    defer allocator.free(cat);

    // out: 0->[1], 1->[], 2->[0]
    try writeOffsets(out_off, &[_]u64{ 0, 1, 1, 2 });
    try writeAdj(out_tgt, &[_]u32{ 1, 0 });
    // in: 0<-[2],1<-[0],2<-[]
    try writeOffsets(in_off, &[_]u64{ 0, 1, 2, 2 });
    try writeAdj(in_src, &[_]u32{ 2, 0 });
    try writeCatalog(cat, &[_]u32{ 5, 7 });

    var diagnostics = Manifest.Diagnostics{};
    const fp = Manifest.Fingerprint{ .file_length = 0, .hprof_timestamp = 0, .id_size = 8, .hash_algorithm = "", .hash_value = "", .source_mtime = 0 };

    var job = Preflight.Job{ .source_path = "x", .index_dir = dir, .staging_dir = dir, .budget_bytes = 64 * 1024 * 1024, .dominator_budget_bytes = 64 * 1024 * 1024, .fingerprint = fp, .header = .{ .id_size = 8, .timestamp = 0 } };

    var res = try run(allocator, test_io, &job, out_off, out_tgt, in_off, in_src, cat, 2, 2, &diagnostics);
    defer res.deinit(allocator);

    const parents = try readU32File(allocator, res.dom_parent_path);
    defer allocator.free(parents);
    const retained = try readU64File(allocator, res.retained_path);
    defer allocator.free(retained);

    try std.testing.expectEqual(@as(u32, 2), parents[0]);
    try std.testing.expectEqual(@as(u32, 0), parents[1]);
    try std.testing.expectEqual(@as(u64, 12), retained[2]);
    try std.testing.expectEqual(@as(u64, 12), retained[0]); // 5 + 7
    try std.testing.expectEqual(@as(u64, 7), retained[1]);
}
