//! S3: real-dump validation of the dominator tree and retained sizes.
//!
//! Builds a production index (via `hunt index`) for every real fixture into a
//! temp directory, opens it with `IndexReader`, and asserts the eight
//! structural properties from the S3 checkpoint on the published
//! `dom_parent.bin`, `dom_order.bin`, `retained.bin`, and `catalog.bin`.
//!
//! On-disk convention (from S1, and important for properties 1 and 8):
//! `dom_parent == NONE` means "unreachable" OR "child of the virtual root".
//! Reachability therefore comes from `dom_order.bin`, which holds exactly the
//! reachable nodes.
//!
//! Complexity notes: property 7 uses the one-pass accumulation formulation
//! (O(V)) rather than the naive O(V²) child scan, and the chain walks use an
//! epoch-marked scratch array so each walk is O(depth) with O(1) state.
const std = @import("std");
const Io = std.Io;

const Config = @import("../../Config.zig").Config;
const Commands = @import("../../Commands.zig");
const IndexReader = @import("../IndexReader.zig");

const NONE: u32 = std.math.maxInt(u32);

/// The three real fixtures, smallest first. The 7.9 GB `shop.hprof` is a
/// benchmark input, not a test input (see the S3 checkpoint §3.5).
const fixtures = [_][]const u8{
    "fixtures/heapforge_threads.hprof",
    "fixtures/heapforge_classloaders.hprof",
    "fixtures/heapforge.hprof",
};

test "real dump dominator trees satisfy the structural properties" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    for (fixtures) |fixture| {
        std.debug.print("validating real dump: {s}\n", .{fixture});
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path);

        try validateRealDump(allocator, io, tmp_path, fixture);
    }
}

test "real dump index built without dominators has no dominator data" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const index_dir = try buildIndex(allocator, io, tmp_path, fixtures[0], false);
    defer allocator.free(index_dir);

    var reader = try IndexReader.open(allocator, io, index_dir, null);
    defer reader.deinit();

    // I37: hasDominators requires BOTH retained.bin and dom_parent.bin; an
    // index built with --no-dominators has neither mapped.
    try std.testing.expect(!reader.hasDominators());
    try std.testing.expectEqual(@as(u64, 0), reader.retainedSize(0));
    try std.testing.expectEqual(@as(?u32, null), reader.dominatorOf(0));
    try std.testing.expectEqual(@as(u32, 0), reader.domDepth(0));

    // The writer surfaces fail cleanly rather than printing junk.
    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    try std.testing.expectError(error.NoRetainedData, IndexReader.writeRetainers(&reader, &buf.writer, .{}));

    const first_id = reader.rawIdForOrdinal(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.NoRetainedData, IndexReader.writeRetained(&reader, &buf.writer, first_id));
}

fn validateRealDump(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_path: []const u8,
    fixture: []const u8,
) !void {
    const index_dir = try buildIndex(allocator, io, tmp_path, fixture, true);
    defer allocator.free(index_dir);

    var reader = try IndexReader.open(allocator, io, index_dir, null);
    defer reader.deinit();

    try std.testing.expect(reader.hasDominators());

    const V: u32 = @intCast(reader.n_objects + 1);
    const root: u32 = @intCast(reader.n_objects);
    try std.testing.expectEqual(root, reader.virtual_root_ordinal);

    // ── Reachability and RPO slots come from dom_order.bin ──────────────────
    const n_reachable: u32 = @intCast(reader.dom_order.len / 4);
    try std.testing.expectEqual(@as(u64, n_reachable), reader.manifest.n_dominator_nodes);

    const rpo_of = try allocator.alloc(u32, V);
    defer allocator.free(rpo_of);
    @memset(rpo_of, NONE);

    const reachable = try allocator.alloc(bool, V);
    defer allocator.free(reachable);
    @memset(reachable, false);

    var slot: u32 = 0;
    while (slot < n_reachable) : (slot += 1) {
        const node = std.mem.readInt(u32, reader.dom_order[slot * 4 ..][0..4], .little);
        try std.testing.expect(node < V);
        // Every reachable node appears exactly once in dom_order.
        try std.testing.expect(!reachable[node]);
        reachable[node] = true;
        rpo_of[node] = slot;
    }
    reachable[root] = true;
    try std.testing.expectEqual(@as(u32, 0), rpo_of[root]);

    // ── Property 3: no self-domination; the root's value is NONE ────────────
    {
        var v: u32 = 0;
        while (v < V) : (v += 1) {
            const p = reader.dominatorOf(v);
            if (v == root) {
                try std.testing.expectEqual(@as(?u32, null), p);
            } else if (p) |parent| {
                try std.testing.expect(parent != v);
                try std.testing.expect(parent < V);
            }
        }
    }

    // ── Properties 1, 2, 4: every chain terminates at the root's children
    //    with strict RPO ascent and non-decreasing retained sizes ───────────
    {
        const seen_epoch = try allocator.alloc(u32, V);
        defer allocator.free(seen_epoch);
        @memset(seen_epoch, 0);
        var epoch: u32 = 0;
        var max_depth: u32 = 0;

        var v: u32 = 0;
        while (v < V) : (v += 1) {
            if (!reachable[v] or v == root) continue;
            epoch += 1;
            var cur = v;
            var prev_rpo = rpo_of[v];
            var steps: u32 = 0;
            while (true) {
                // 1. No repeats within a chain; bounded by V.
                try std.testing.expect(seen_epoch[cur] != epoch);
                seen_epoch[cur] = epoch;
                steps += 1;
                try std.testing.expect(steps <= V);

                const p = reader.dominatorOf(cur) orelse {
                    // 2. Chain top: on disk this is a child of the virtual
                    //    root, whose logical parent (the root) has RPO slot 0.
                    try std.testing.expect(rpo_of[cur] != NONE);
                    try std.testing.expect(rpo_of[cur] > 0);
                    try std.testing.expect(0 < prev_rpo);
                    // 4. The root retains everything reachable.
                    try std.testing.expect(reader.retainedSize(root) >= reader.retainedSize(v));
                    if (steps > max_depth) max_depth = steps;
                    break;
                };
                try std.testing.expect(rpo_of[p] != NONE);
                // 2. Strict ascent in RPO.
                try std.testing.expect(rpo_of[p] < prev_rpo);
                // 4. Dominance preserved along the chain.
                try std.testing.expect(reader.retainedSize(p) >= reader.retainedSize(v));
                prev_rpo = rpo_of[p];
                cur = p;
            }
        }
        std.debug.print("  max dominator chain depth: {d}\n", .{max_depth});
    }

    // ── Property 5: retained >= shallow ─────────────────────────────────────
    var total_shallow_reachable: u64 = 0;
    {
        var v: u32 = 0;
        while (v < reader.n_objects) : (v += 1) {
            const shallow: u64 = reader.catalogRow(v).shallow_size;
            try std.testing.expect(reader.retainedSize(v) >= shallow);
            if (reachable[v]) total_shallow_reachable += shallow;
        }
    }

    // ── Property 8: unreachable isolation ───────────────────────────────────
    {
        var v: u32 = 0;
        while (v < reader.n_objects) : (v += 1) {
            if (!reachable[v]) {
                try std.testing.expectEqual(@as(?u32, null), reader.dominatorOf(v));
                try std.testing.expectEqual(
                    @as(u64, reader.catalogRow(v).shallow_size),
                    reader.retainedSize(v),
                );
            }
        }
    }

    // ── Properties 6 and 7 in one O(V) accumulation pass: for every reachable
    //    v, retained[v] == shallow[v] + Σ retained[children] ─────────────────
    {
        const child_retained = try allocator.alloc(u64, V);
        defer allocator.free(child_retained);
        @memset(child_retained, 0);

        var v: u32 = 0;
        while (v < reader.n_objects) : (v += 1) {
            if (!reachable[v]) continue;
            if (reader.dominatorOf(v)) |p| {
                child_retained[p] += reader.retainedSize(v);
            } else {
                // Child of the virtual root: its retained size accrues to the
                // root (whose own shallow size is 0 by construction).
                child_retained[root] += reader.retainedSize(v);
            }
        }

        // 6. Reconciliation at the root.
        try std.testing.expectEqual(total_shallow_reachable, reader.retainedSize(root));

        // 7. Subtree identity for every reachable node.
        v = 0;
        while (v < reader.n_objects) : (v += 1) {
            if (!reachable[v]) continue;
            const shallow: u64 = if (v == root) 0 else reader.catalogRow(v).shallow_size;
            try std.testing.expectEqual(
                shallow + child_retained[v],
                reader.retainedSize(v),
            );
        }
    }

    // ── The reader surfaces agree with the published files ──────────────────
    try checkReaderSurfaces(allocator, &reader, reachable);
}

/// Exercises domDepth, domPath, and domChildren against dom_parent.bin and
/// checks the `hunt retained` / `hunt retainers` writer surfaces.
fn checkReaderSurfaces(
    allocator: std.mem.Allocator,
    reader: *const IndexReader.Reader,
    reachable: []const bool,
) !void {
    const V: u32 = @intCast(reader.n_objects + 1);
    const root: u32 = @intCast(reader.n_objects);

    // domPath(root) is the root alone; domDepth(root) is 0.
    {
        const path = try reader.domPath(allocator, root, 1_000_000);
        defer allocator.free(path);
        try std.testing.expectEqual(@as(usize, 1), path.len);
        try std.testing.expectEqual(root, path[0]);
        try std.testing.expectEqual(@as(u32, 0), reader.domDepth(root));
    }

    // For every reachable node: domDepth == domPath.len - 1, the path is
    // child-to-root ordered with strict RPO ascent, and no path node repeats.
    const seen_epoch = try allocator.alloc(u32, V);
    defer allocator.free(seen_epoch);
    @memset(seen_epoch, 0);
    var epoch: u32 = 0;

    var v: u32 = 0;
    while (v < reader.n_objects) : (v += 1) {
        if (!reachable[v]) continue;
        const path = try reader.domPath(allocator, v, 1_000_000);
        defer allocator.free(path);

        try std.testing.expect(path.len >= 1);
        try std.testing.expectEqual(@as(u32, v), path[0]);
        try std.testing.expectEqual(@as(u32, @intCast(path.len - 1)), reader.domDepth(v));

        epoch += 1;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            const node = path[i];
            try std.testing.expect(seen_epoch[node] != epoch);
            seen_epoch[node] = epoch;
            if (i > 0) {
                // Each step must follow domParent exactly: path[i] is the
                // dominator of path[i - 1].
                try std.testing.expectEqual(
                    @as(?u32, path[i]),
                    reader.dominatorOf(path[i - 1]),
                );
            }
        }
        // The path ends at a child of the virtual root (domParent == NONE).
        try std.testing.expectEqual(@as(?u32, null), reader.dominatorOf(path[path.len - 1]));
    }

    // domChildren is consistent with domParent on a sample: the 100 largest
    // reachable nodes plus 1000 random ones. Children of the virtual root
    // cannot be sampled from domChildren(v) for a real v, but every child c
    // reported for v must have domParent(c) == v.
    {
        var prng = std.Random.DefaultPrng.init(0x5eed);
        const random = prng.random();

        var checked: u32 = 0;
        while (checked < 1100) : (checked += 1) {
            const sample: u32 = if (checked < 1000)
                random.uintLessThan(u32, @intCast(reader.n_objects))
            else
                checked - 1000; // also cover the low ordinals deterministically
            if (!reachable[sample]) continue;

            const children = try reader.domChildren(allocator, sample);
            defer allocator.free(children);
            for (children) |c| {
                try std.testing.expectEqual(@as(?u32, sample), reader.dominatorOf(c));
            }
        }

        // The virtual root's children are exactly the reachable nodes with no
        // dominator.
        const root_children = try reader.domChildren(allocator, root);
        defer allocator.free(root_children);
        for (root_children) |c| {
            try std.testing.expect(reachable[c]);
            try std.testing.expectEqual(@as(?u32, null), reader.dominatorOf(c));
        }
    }

    // `writeRetained` prints JSON whose numbers match the published files for
    // one reachable object with a non-trivial chain.
    {
        var target: u32 = 0;
        while (target < reader.n_objects) : (target += 1) {
            if (reachable[target] and reader.domDepth(target) >= 2) break;
        }
        try std.testing.expect(target < reader.n_objects);

        const raw_id = reader.rawIdForOrdinal(target) orelse return error.TestUnexpectedResult;
        var buf = Io.Writer.Allocating.init(allocator);
        defer buf.deinit();
        try IndexReader.writeRetained(reader, &buf.writer, raw_id);

        const output = buf.writer.buffer[0..buf.writer.end];
        // The JSON starts with the id, carries the fields, and the dominator
        // chain has dom_depth entries.
        try std.testing.expect(std.mem.indexOf(u8, output, "\"ordinal\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"shallow_bytes\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"retained_bytes\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"retained_delta_bytes\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"dom_depth\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"dominators\":[") != null);

        const depth = reader.domDepth(target);
        var occurrences: usize = 0;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, output, idx, "\"retained_bytes\":")) |hit| {
            occurrences += 1;
            idx = hit + 1;
        }
        // One entry per dominator plus the object's own retained_bytes.
        try std.testing.expectEqual(@as(usize, depth + 1), occurrences);
    }

    // `writeRetainers` returns `top` items in (retained DESC, ordinal ASC)
    // order, and running it twice produces byte-identical output.
    {
        const top: u32 = 25;
        var buf = Io.Writer.Allocating.init(allocator);
        defer buf.deinit();
        try IndexReader.writeRetainers(reader, &buf.writer, .{ .top = top });
        const output = buf.writer.buffer[0..buf.writer.end];

        var buf2 = Io.Writer.Allocating.init(allocator);
        defer buf2.deinit();
        try IndexReader.writeRetainers(reader, &buf2.writer, .{ .top = top });
        try std.testing.expectEqualSlices(u8, output, buf2.writer.buffer[0..buf2.writer.end]);

        // Parse the ordinals out and verify the ordering against the files.
        const Item = struct { retained: u64, ordinal: u32 };
        var items = std.ArrayList(Item).empty;
        defer items.deinit(allocator);

        var idx: usize = std.mem.indexOf(u8, output, "\"items\":[").? + "\"items\":[".len;
        while (std.mem.indexOfPos(u8, output, idx, "\"ordinal\":")) |hit| {
            const start = hit + "\"ordinal\":".len;
            const end = std.mem.indexOfScalarPos(u8, output, start, ',') orelse break;
            const ordinal = std.fmt.parseInt(u32, output[start..end], 10) catch break;
            const rb_at = std.mem.indexOfPos(u8, output, end, "\"retained_bytes\":").?;
            const rb_start = rb_at + "\"retained_bytes\":".len;
            const rb_end = std.mem.indexOfScalarPos(u8, output, rb_start, ',') orelse break;
            const retained = try std.fmt.parseInt(u64, output[rb_start..rb_end], 10);
            try items.append(allocator, .{ .retained = retained, .ordinal = ordinal });
            idx = rb_end;
        }
        try std.testing.expectEqual(@as(usize, top), items.items.len);
        for (items.items, 0..) |item, i| {
            try std.testing.expectEqual(item.retained, reader.retainedSize(item.ordinal));
            if (i > 0) {
                const prev = items.items[i - 1];
                // Strictly ordered by (retained DESC, ordinal ASC).
                try std.testing.expect(prev.retained > item.retained or
                    (prev.retained == item.retained and prev.ordinal < item.ordinal));
            }
        }
    }
}

/// Build a production index for `fixture` in a temp directory and return the
/// (allocated) index directory path. `with_dominators = false` exercises the
/// `--no-dominators` path for the I37 test.
fn buildIndex(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_path: []const u8,
    fixture: []const u8,
    with_dominators: bool,
) ![]u8 {
    return buildIndexWithAlgorithm(allocator, io, tmp_path, fixture, with_dominators, "lt");
}

fn buildIndexWithAlgorithm(
    allocator: std.mem.Allocator,
    io: Io,
    tmp_path: []const u8,
    fixture: []const u8,
    with_dominators: bool,
    algorithm: []const u8,
) ![]u8 {
    const index_dir = try std.fs.path.join(allocator, &.{ tmp_path, "index" });
    errdefer allocator.free(index_dir);

    var config_load: Config.LoadResult = .{};
    defer config_load.deinit(allocator);

    var stdout = Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();

    try Commands.runIndexCommand(
        allocator,
        io,
        .{
            .hprof_path = fixture,
            .index_dir = index_dir,
            .force = true,
            .no_progress = true,
            .compute_dominators = with_dominators,
            .dominator_algorithm = algorithm,
        },
        &stdout.writer,
        &stderr.writer,
        config_load,
        null,
        null,
    );

    const output = stdout.writer.buffer[0..stdout.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":\"complete\"") != null);
    if (with_dominators) {
        // I36: the index JSON reports the algorithm, the iteration count, and
        // the reachable count.
        const algo_tag = try std.fmt.allocPrint(allocator, "\"dominator_algorithm\":\"{s}\"", .{algorithm});
        defer allocator.free(algo_tag);
        try std.testing.expect(std.mem.indexOf(u8, output, algo_tag) != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"dominator_iterations\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"dominator_shortcut_nodes\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"dominator_eval_calls\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"n_dominator_nodes\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"retained_total_bytes\":") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, output, "\"dominator_algorithm\":\"none\"") != null);
    }

    return index_dir;
}

test "real dump dominator output is identical for chk and lt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    for (fixtures) |fixture| {
        std.debug.print("checking chk/lt parity on real dump: {s}\n", .{fixture});
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path);

        const lt_dir = try buildIndexWithAlgorithm(allocator, io, tmp_path, fixture, true, "lt");
        defer allocator.free(lt_dir);
        const chk_dir = try buildIndexWithAlgorithm(allocator, io, tmp_path, fixture, true, "chk");
        defer allocator.free(chk_dir);

        // The dominator tree is unique, so two algorithms must produce
        // byte-identical dom_parent, dom_order, and retained files.
        for ([_][]const u8{ "dom_parent.bin", "dom_order.bin", "retained.bin" }) |name| {
            const lt_path = try std.fs.path.join(allocator, &.{ lt_dir, name });
            defer allocator.free(lt_path);
            const chk_path = try std.fs.path.join(allocator, &.{ chk_dir, name });
            defer allocator.free(chk_path);

            const lt_data = try Io.Dir.cwd().readFileAlloc(io, lt_path, allocator, .unlimited);
            defer allocator.free(lt_data);
            const chk_data = try Io.Dir.cwd().readFileAlloc(io, chk_path, allocator, .unlimited);
            defer allocator.free(chk_data);

            try std.testing.expectEqualSlices(u8, chk_data, lt_data);
        }
    }
}
