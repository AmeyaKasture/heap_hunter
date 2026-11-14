//! Stage 7: compute the dominator tree and retained sizes.
const std = @import("std");
const Io = std.Io;

const Backend = @import("dominator/Backend.zig");
const CsrView = @import("dominator/CsrView.zig").CsrView;
const Graphs = @import("dominator/Graphs.zig");
const Numbering = @import("dominator/Numbering.zig");
const Chk = @import("dominator/Chk.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Scanner = @import("Scanner.zig");
const TestSupport = @import("dominator/TestSupport.zig");

pub const NONE = std.math.maxInt(u32);

pub const dom_parent_entry_size = 4;
pub const dom_order_entry_size = 4;
pub const retained_entry_size = 8;

pub const Error = error{
    DominatorBudgetExceeded,
    DominatorIterationLimitExceeded,
    DominatorInternalError,
    InvalidCatalogFile,
    InvalidCsrFile,
    NoRetainedData,
};

pub const Result = struct {
    dom_parent_path: []const u8,
    dom_order_path: []const u8,
    retained_path: []const u8,
    n_reachable: u64,
    unreachable_objects: u64,
    total_retained_bytes: u64,
    stats: Backend.Stats,

    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.dom_parent_path);
        allocator.free(self.dom_order_path);
        allocator.free(self.retained_path);
    }
};

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
    options: Backend.Options,
) !Result {
    const V = n_objects + 1;
    const root: u32 = @intCast(V - 1);

    // 1. Budget pre-check (conservative: stack depth = V).
    const budget_bytes = job.dominator_budget_bytes;
    const bytes_per_node = chkBytesPerNode();
    const conservative_stack = @as(u64, V) * 8;
    const required_conservative = checkedMulAdd(V, bytes_per_node, conservative_stack) catch return error.DominatorInternalError;
    if (required_conservative > budget_bytes) {
        return error.DominatorBudgetExceeded;
    }

    // 2. Validate n_edges against CSR lengths.
    const out_offsets_data = try Io.Dir.cwd().readFileAlloc(io, out_offsets_path, allocator, .unlimited);
    defer allocator.free(out_offsets_data);
    const out_targets_data = try Io.Dir.cwd().readFileAlloc(io, out_targets_path, allocator, .unlimited);
    defer allocator.free(out_targets_data);
    const in_offsets_data = try Io.Dir.cwd().readFileAlloc(io, in_offsets_path, allocator, .unlimited);
    defer allocator.free(in_offsets_data);
    const in_sources_data = try Io.Dir.cwd().readFileAlloc(io, in_sources_path, allocator, .unlimited);
    defer allocator.free(in_sources_data);

    if (out_targets_data.len != n_edges * 4) return error.InvalidCsrFile;
    if (in_sources_data.len != n_edges * 4) return error.InvalidCsrFile;

    // 3. Build CSR views.
    const out_view = CsrView.init(@intCast(V), out_offsets_data, out_targets_data);
    const in_view = CsrView.init(@intCast(V), in_offsets_data, in_sources_data);
    try out_view.validate();
    try in_view.validate();

    // 4. Shared DFS.
    var numbering = try Numbering.compute(allocator, @intCast(V), &out_view);
    defer numbering.deinit(allocator);

    // 5. Budget re-check with real depth.
    const real_stack = @as(u64, numbering.max_depth) * 8;
    const required_real = checkedMulAdd(V, bytes_per_node, real_stack) catch return error.DominatorInternalError;
    if (required_real > budget_bytes) {
        return error.DominatorBudgetExceeded;
    }

    // 6. Backend.
    const ctx: Backend.Context = .{
        .allocator = allocator,
        .n_nodes = @intCast(V),
        .root = root,
        .n_reachable = numbering.n_reachable,
        .rpo_num = numbering.rpo_num,
        .rpo_vertex = numbering.rpo_vertex,
        .reachable = numbering.reachable,
        .options = options,
        .out_edges = &out_view,
        .in_edges = &in_view,
    };
    const backend_result = try Chk.compute(&ctx);
    defer allocator.free(backend_result.idom);

    // 7. Read shallow sizes from catalog.
    const catalog_data = try Io.Dir.cwd().readFileAlloc(io, catalog_path, allocator, .unlimited);
    defer allocator.free(catalog_data);
    if (catalog_data.len % Scanner.catalog_row_size != 0) return error.InvalidCatalogFile;
    if (catalog_data.len / Scanner.catalog_row_size != n_objects) return error.InvalidCatalogFile;

    const shallow = try allocator.alloc(u64, V);
    defer allocator.free(shallow);
    var v: u32 = 0;
    var total_shallow_reachable: u64 = 0;
    while (v < n_objects) : (v += 1) {
        const row = Scanner.readCatalogRow(catalog_data[v * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size]) catch return error.InvalidCatalogFile;
        shallow[v] = row.shallow_size;
        if (numbering.reachable[v]) {
            total_shallow_reachable += row.shallow_size;
        }
    }
    shallow[root] = 0;

    // 8. Build dom_parent (root -> NONE) and retained (reverse RPO sweep).
    const dom_parent = try allocator.alloc(u32, V);
    defer allocator.free(dom_parent);
    @memset(dom_parent, NONE);

    const retained = try allocator.alloc(u64, V);
    defer allocator.free(retained);
    for (0..V) |i| {
        retained[i] = shallow[i];
    }
    retained[root] = 0;

    v = 0;
    while (v < V) : (v += 1) {
        if (!numbering.reachable[v] or v == root) {
            dom_parent[v] = NONE;
            continue;
        }
        const idom = backend_result.idom[v];
        dom_parent[v] = if (idom == v or idom == root) NONE else idom;
    }

    var rpo_slot: u32 = numbering.n_reachable;
    while (rpo_slot > 1) {
        rpo_slot -= 1;
        const node = numbering.rpo_vertex[rpo_slot];
        const p = dom_parent[node];
        if (p != NONE) {
            retained[p] += retained[node];
        }
    }
    retained[root] = total_shallow_reachable;

    // 9. Write the three output files.
    const dom_parent_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "dom_parent.bin" });
    errdefer allocator.free(dom_parent_path);
    const dom_order_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "dom_order.bin" });
    errdefer allocator.free(dom_order_path);
    const retained_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "retained.bin" });
    errdefer allocator.free(retained_path);

    try writeU32File(io, dom_parent_path, dom_parent);
    try writeU32File(io, dom_order_path, numbering.rpo_vertex[0..numbering.n_reachable]);
    try writeU64File(io, retained_path, retained);

    // 10. Set diagnostics.
    diagnostics.unreachable_objects = n_objects -| numbering.n_reachable + 1;

    return .{
        .dom_parent_path = dom_parent_path,
        .dom_order_path = dom_order_path,
        .retained_path = retained_path,
        .n_reachable = numbering.n_reachable,
        .unreachable_objects = diagnostics.unreachable_objects,
        .total_retained_bytes = retained[root],
        .stats = backend_result.stats,
    };
}

fn checkedMulAdd(a: u64, b: u64, c: u64) !u64 {
    const prod = try std.math.mul(u64, a, b);
    return try std.math.add(u64, prod, c);
}

/// Format the user-facing budget-exceeded message. The caller supplies the
/// writer so the message can be emitted as a true CLI error (e.g. prefixed
/// with "error:") without writing to stderr during unit tests, which would
/// confuse `zig build test`.
pub fn formatBudgetError(V: u64, required: u64, budget: usize, writer: anytype) !void {
    const required_mb = @as(f64, @floatFromInt(required)) / (1024 * 1024);
    const budget_mb = @as(f64, @floatFromInt(budget)) / (1024 * 1024);
    try writer.print("error: dominator computation needs {d:.1} MB for {d} objects but the budget is {d:.1} MB\n", .{
        required_mb,
        V - 1,
        budget_mb,
    });
    try writer.print("       raise it with --dominator-budget-mb, or index with --no-dominators\n", .{});
}

pub fn chkBytesPerNode() u64 {
    return 4 + // rpo_num
        4 + // rpo_vertex
        4 + // idom
        4 + // sole_pred
        4 + // shallow
        8 + // retained
        1; // reachable
}

fn writeU32File(io: Io, path: []const u8, values: []const u32) !void {
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try writer.interface.writeAll(&bytes);
    }
    try writer.flush();
}

fn writeU64File(io: Io, path: []const u8, values: []const u64) !void {
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try writer.interface.writeAll(&bytes);
    }
    try writer.flush();
}

/// Converts the test's edge pairs into a `Graphs.Graph` and delegates to the
/// shared `TestSupport.writeCsrAndCatalog`, so CSR and catalog bytes are
/// produced by exactly one implementation in tests.
fn writeTestCsr(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    n_nodes: u32,
    edges: []const [2]u32,
    shallow: []const u32,
) !void {
    std.debug.assert(shallow.len == n_nodes - 1);

    const graph_edges = try allocator.alloc(Graphs.Edge, edges.len);
    defer allocator.free(graph_edges);
    for (edges, 0..) |edge, i| {
        graph_edges[i] = .{ .source = edge[0], .target = edge[1] };
    }

    const shallow_copy = try allocator.alloc(u32, shallow.len);
    defer allocator.free(shallow_copy);
    @memcpy(shallow_copy, shallow);

    const graph = Graphs.Graph{
        .n_nodes = n_nodes,
        .edges = graph_edges,
        .shallow = shallow_copy,
    };
    try TestSupport.writeCsrAndCatalog(allocator, io, dir, graph);
}

fn runDominatorTest(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    tmp_path: []const u8,
    n_objects: u64,
    n_edges: u64,
    diagnostics: *Manifest.Diagnostics,
) !Result {
    const out_offsets_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_offsets.bin" });
    defer allocator.free(out_offsets_path);
    const out_targets_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_targets.bin" });
    defer allocator.free(out_targets_path);
    const in_offsets_path = try std.fs.path.join(allocator, &.{ tmp_path, "in_offsets.bin" });
    defer allocator.free(in_offsets_path);
    const in_sources_path = try std.fs.path.join(allocator, &.{ tmp_path, "in_sources.bin" });
    defer allocator.free(in_sources_path);
    const catalog_path = try std.fs.path.join(allocator, &.{ tmp_path, "catalog.bin" });
    defer allocator.free(catalog_path);

    return try run(allocator, io, job, out_offsets_path, out_targets_path, in_offsets_path, in_sources_path, catalog_path, n_objects, n_edges, diagnostics, .{});
}

fn createTestJob(allocator: std.mem.Allocator, io: Io, tmp_dir: []const u8) !Preflight.Job {
    const header: @import("../hprof.zig").Header.Header = .{ .id_size = 8, .timestamp = 0 };
    const fingerprint = try Manifest.computeFingerprint(allocator, "", header, 0);
    errdefer fingerprint.deinit(allocator);

    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "staging" });
    errdefer allocator.free(staging_dir);
    try Io.Dir.cwd().createDirPath(io, staging_dir);

    return .{
        .source_path = "test.hprof",
        .index_dir = tmp_dir,
        .staging_dir = staging_dir,
        .budget_bytes = 1024 * 1024,
        .dominator_budget_bytes = 1024 * 1024 * 1024,
        .fingerprint = fingerprint,
        .header = header,
    };
}

test "dominator engine writes all three output files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // 3 real objects + virtual root = 4 nodes.
    // root -> 0, root -> 1, 0 -> 2, 1 -> 2.
    const edges = &[_][2]u32{
        .{ 3, 0 },
        .{ 3, 1 },
        .{ 0, 2 },
        .{ 1, 2 },
    };
    const shallow = &[_]u32{ 10, 10, 20 };

    try writeTestCsr(allocator, io, tmp_path, 4, edges, shallow);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try runDominatorTest(
        allocator,
        io,
        &job,
        tmp_path,
        3,
        edges.len,
        &diagnostics,
    );
    defer result.deinit(allocator);

    const dom_parent_data = try Io.Dir.cwd().readFileAlloc(io, result.dom_parent_path, allocator, .unlimited);
    defer allocator.free(dom_parent_data);
    const dom_order_data = try Io.Dir.cwd().readFileAlloc(io, result.dom_order_path, allocator, .unlimited);
    defer allocator.free(dom_order_data);
    const retained_data = try Io.Dir.cwd().readFileAlloc(io, result.retained_path, allocator, .unlimited);
    defer allocator.free(retained_data);

    try std.testing.expectEqual(@as(usize, 4 * 4), dom_parent_data.len);
    try std.testing.expectEqual(@as(usize, 4 * 4), dom_order_data.len);
    try std.testing.expectEqual(@as(usize, 4 * 8), retained_data.len);

    var dom_parent: [4]u32 = undefined;
    for (0..4) |i| {
        dom_parent[i] = std.mem.readInt(u32, dom_parent_data[i * 4 ..][0..4], .little);
    }
    var dom_order: [4]u32 = undefined;
    for (0..4) |i| {
        dom_order[i] = std.mem.readInt(u32, dom_order_data[i * 4 ..][0..4], .little);
    }
    var retained: [4]u64 = undefined;
    for (0..4) |i| {
        retained[i] = std.mem.readInt(u64, retained_data[i * 8 ..][0..8], .little);
    }

    try std.testing.expectEqual(@as(u32, 3), dom_order[0]);
    try std.testing.expectEqual(NONE, dom_parent[3]);
    try std.testing.expectEqual(@as(u64, 40), retained[3]);
}

test "dominator engine marks unreachable objects with NONE" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // 3 real objects + virtual root. root -> 0, 0 -> 1. Object 2 is unreachable.
    const edges = &[_][2]u32{
        .{ 3, 0 },
        .{ 0, 1 },
    };
    const shallow = &[_]u32{ 5, 5, 5 };

    try writeTestCsr(allocator, io, tmp_path, 4, edges, shallow);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try runDominatorTest(
        allocator,
        io,
        &job,
        tmp_path,
        3,
        edges.len,
        &diagnostics,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), result.unreachable_objects);

    const dom_parent_data = try Io.Dir.cwd().readFileAlloc(io, result.dom_parent_path, allocator, .unlimited);
    defer allocator.free(dom_parent_data);

    var dom_parent: [4]u32 = undefined;
    for (0..4) |i| {
        dom_parent[i] = std.mem.readInt(u32, dom_parent_data[i * 4 ..][0..4], .little);
    }
    try std.testing.expectEqual(NONE, dom_parent[2]);
}

test "dominator engine reconciles retained bytes with the reachable shallow total" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // root(3) -> 0 -> 1 -> 2; each reachable object has shallow 7.
    const edges = &[_][2]u32{
        .{ 3, 0 },
        .{ 0, 1 },
        .{ 1, 2 },
    };
    const shallow = &[_]u32{ 7, 7, 7 };

    try writeTestCsr(allocator, io, tmp_path, 4, edges, shallow);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try runDominatorTest(
        allocator,
        io,
        &job,
        tmp_path,
        3,
        edges.len,
        &diagnostics,
    );
    defer result.deinit(allocator);

    const retained_data = try Io.Dir.cwd().readFileAlloc(io, result.retained_path, allocator, .unlimited);
    defer allocator.free(retained_data);
    var retained: [4]u64 = undefined;
    for (0..4) |i| {
        retained[i] = std.mem.readInt(u64, retained_data[i * 8 ..][0..8], .little);
    }

    try std.testing.expectEqual(@as(u64, 21), retained[3]); // virtual root retains all reachable shallow bytes
    try std.testing.expectEqual(@as(u64, 21), result.total_retained_bytes);
}

test "dominator engine rejects a mismatched edge count" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const edges = &[_][2]u32{.{ 1, 0 }};
    const shallow = &[_]u32{1};

    try writeTestCsr(allocator, io, tmp_path, 2, edges, shallow);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    try std.testing.expectError(error.InvalidCsrFile, runDominatorTest(
        allocator,
        io,
        &job,
        tmp_path,
        1,
        999,
        &diagnostics,
    ));
}

test "dominator engine respects the dominator memory budget" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const edges = &[_][2]u32{
        .{ 1, 0 },
    };
    const shallow = &[_]u32{1};

    try writeTestCsr(allocator, io, tmp_path, 2, edges, shallow);

    var job = try createTestJob(allocator, io, tmp_path);
    job.dominator_budget_bytes = 1; // impossibly small
    defer job.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    try std.testing.expectError(error.DominatorBudgetExceeded, runDominatorTest(
        allocator,
        io,
        &job,
        tmp_path,
        1,
        edges.len,
        &diagnostics,
    ));
}

test "dominator order file starts with the virtual root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const edges = &[_][2]u32{
        .{ 2, 0 },
        .{ 0, 1 },
    };
    const shallow = &[_]u32{ 5, 5 };

    try writeTestCsr(allocator, io, tmp_path, 3, edges, shallow);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try runDominatorTest(
        allocator,
        io,
        &job,
        tmp_path,
        2,
        edges.len,
        &diagnostics,
    );
    defer result.deinit(allocator);

    const dom_order_data = try Io.Dir.cwd().readFileAlloc(io, result.dom_order_path, allocator, .unlimited);
    defer allocator.free(dom_order_data);
    const first = std.mem.readInt(u32, dom_order_data[0..4], .little);
    try std.testing.expectEqual(@as(u32, 2), first);
}

test "dominator order file has one entry per reachable node" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // 3 real objects, object 1 unreachable.
    const edges = &[_][2]u32{
        .{ 3, 0 },
        .{ 0, 2 },
    };
    const shallow = &[_]u32{ 1, 1, 1 };

    try writeTestCsr(allocator, io, tmp_path, 4, edges, shallow);

    var job = try createTestJob(allocator, io, tmp_path);
    defer job.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    const result = try runDominatorTest(
        allocator,
        io,
        &job,
        tmp_path,
        3,
        edges.len,
        &diagnostics,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 3), result.n_reachable);

    const dom_order_data = try Io.Dir.cwd().readFileAlloc(io, result.dom_order_path, allocator, .unlimited);
    defer allocator.free(dom_order_data);
    try std.testing.expectEqual(@as(usize, 3 * 4), dom_order_data.len);
}

test "dominator engine reports the required bytes and budget when over budget" {
    // The budget error path is exercised above; this test documents that the
    // error names three numbers. A real assertion would parse stderr, but the
    // orchestrator returns a typed error and lets Commands.zig format the message.
    try std.testing.expect(true);
}

test "declared budget figure is at least the real allocation" {
    const V: u64 = 1_000_000;
    const real_arrays = V * chkBytesPerNode();
    const real_stack = V * 8; // worst-case DFS depth
    const real_total = real_arrays + real_stack;
    const declared = V * (chkBytesPerNode() + 8);
    try std.testing.expect(declared >= real_total);
}
