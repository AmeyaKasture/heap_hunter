//! Stage 8: validate structural invariants of the staged index before publication.
//!
//! After Stages 1–7 have produced the staged index files, this module runs a
//! battery of checks to ensure the files are internally consistent and match
//! the expected pipeline counts. If any check fails, publication is aborted
//! and the staging directory is left intact for diagnosis.
//!
//! The checks cover:
//!   1. All expected staged files exist and are readable.
//!   2. `catalog.bin` is sorted, unique, and contains the expected row/class counts.
//!   3. `classes.bin` is sorted and parseable.
//!   4. `fields.bin` is parseable and its class count matches.
//!   5. CSR offset files are monotone, start at 0, and end at `n_edges`.
//!   6. CSR adjacency files contain exactly `n_edges` in-range ordinals.
//!   7. `roots.bin` contains exactly `n_roots` in-range ordinals.
//!   8. `thread_traces.bin` is parseable and structurally valid.
//!   9. Dominator files (when present) are internally consistent.
//!
//! Checks are independent per-file tasks. All file opening, mapping, and
//! reading happens on the calling thread before dispatch, so worker threads
//! are pure-memory scanners over the mapped slices and never touch the shared
//! `Io` context, the `stderr` writer, or the global profiling state. Tasks are
//! LPT-balanced by their known byte sizes across at most one worker thread
//! per check. Each task captures its first failure (error value plus a
//! one-line message) without printing; after all workers join, the earliest
//! failure in the fixed check order is printed and returned, so parallel and
//! sequential runs produce identical diagnostics for the same index.
//!
//! Validation remains streaming: each file is memory-mapped (or read, for
//! `thread_traces.bin`) and scanned once. No index file is loaded into the
//! heap in its entirety, so validation honors the same sorting-budget
//! contract as the rest of the pipeline; demand paging keeps resident memory
//! bounded by the pages each scan actually touches.
const std = @import("std");
const Io = std.Io;
const Scanner = @import("Scanner.zig");
const Csr = @import("Csr.zig");
const ThreadTraces = @import("ThreadTraces.zig");
const Cli = @import("../Cli.zig");
const profiling = @import("profiling");

/// Errors that can be returned by the validation pipeline.
pub const Error = error{
    /// A structural invariant does not hold (e.g., wrong row count, unsorted IDs).
    InvariantViolation,
    /// An expected staged file is missing or unreadable.
    MissingFile,
    /// `catalog.bin` has the wrong size or malformed rows.
    InvalidCatalogFile,
    /// An offsets file has the wrong size or non-monotone entries.
    InvalidOffsetFile,
    /// An adjacency file has the wrong size or out-of-range ordinals.
    InvalidAdjacencyFile,
    /// `classes.bin` has the wrong size or malformed records.
    InvalidClassesFile,
    /// `fields.bin` has the wrong size or malformed records.
    InvalidFieldsFile,
    /// `roots.bin` has the wrong size or malformed records.
    InvalidRootsFile,
    /// `thread_traces.bin` is malformed (bad magic/version or truncated).
    InvalidThreadTracesFile,
    OutOfMemory,
    WriteFailed,
};

/// The set of files that must exist in the staging directory before validation
/// can proceed. These are the files that `Publish.zig` will move into the final
/// index directory.
const expected_files = &[_][]const u8{
    "catalog.bin",
    "classes.bin",
    "fields.bin",
    "out_offsets.bin",
    "out_targets.bin",
    "in_offsets.bin",
    "in_sources.bin",
    "roots.bin",
    "prim_histogram.bin",
    "thread_traces.bin",
};

/// Independent per-file check that can run in parallel with the others.
const TaskKind = enum {
    catalog,
    classes,
    fields,
    out_offsets,
    in_offsets,
    out_targets,
    in_sources,
    roots,
    thread_traces,
    dominators,
};

/// Maximum number of tasks in one validation run.
const max_tasks = 10;

/// Maximum number of files a single task scans: the `dominators` task maps
/// `dom_parent.bin`, `dom_order.bin`, `retained.bin`, and re-maps `catalog.bin`.
const max_task_maps = 4;

/// A read-only memory map of a file plus its exposed byte slice.
/// The underlying file handle is kept open until the map is destroyed; this
/// matches the pattern used elsewhere in the indexer and avoids destroying a
/// map after its file has been closed.
const MappedFile = struct {
    file: Io.File,
    mm: Io.File.MemoryMap,
    data: []const u8,
};

/// One scheduled validation check plus its captured result.
///
/// The main thread opens and maps (or reads) every file before workers are
/// spawned; the `datas` slices then alias the maps and are only read by the
/// scanners. A task records at most one failure: `err` plus a preformatted
/// one-line message, so workers never write to the shared `stderr` writer.
const Task = struct {
    kind: TaskKind,
    /// Expected object/class/edge/root counts for the per-kind invariants.
    n_objects: u64 = 0,
    n_classes: u64 = 0,
    n_edges: u64 = 0,
    n_roots: u64 = 0,
    /// Total graph nodes including the virtual root.
    n_nodes: u64 = 0,
    virtual_root_ordinal: u64 = 0,
    /// Estimated bytes scanned, used to LPT-balance parallel workers.
    est_bytes: u64 = 0,
    /// Files mapped by the main thread; null slots are empty files.
    maps: [max_task_maps]?MappedFile = .{ null, null, null, null },
    /// Slices exposed to the scanners; aliases into `maps` or empty.
    datas: [max_task_maps][]const u8 = .{ &[_]u8{}, &[_]u8{}, &[_]u8{}, &[_]u8{} },
    /// `thread_traces.bin` is read (not mapped) into this buffer up front.
    traces_buf: ?[]u8 = null,
    /// First failure, captured without touching shared stderr.
    err: ?Error = null,
    msg_buf: [192]u8 = undefined,
    msg_len: usize = 0,
};

/// Staged-file name for each task kind (used in failure messages).
fn fileName(kind: TaskKind) []const u8 {
    return switch (kind) {
        .catalog => "catalog.bin",
        .classes => "classes.bin",
        .fields => "fields.bin",
        .out_offsets => "out_offsets.bin",
        .in_offsets => "in_offsets.bin",
        .out_targets => "out_targets.bin",
        .in_sources => "in_sources.bin",
        .roots => "roots.bin",
        .thread_traces => "thread_traces.bin",
        .dominators => "dominators",
    };
}

/// Error captured when a task's file cannot be opened or mapped.
fn fileMapError(kind: TaskKind) Error {
    return switch (kind) {
        .catalog => error.InvalidCatalogFile,
        .classes => error.InvalidClassesFile,
        .fields => error.InvalidFieldsFile,
        .out_offsets, .in_offsets => error.InvalidOffsetFile,
        .out_targets, .in_sources => error.InvalidAdjacencyFile,
        .roots => error.InvalidRootsFile,
        .thread_traces => error.InvalidThreadTracesFile,
        .dominators => error.MissingFile,
    };
}

/// Profiling span label for each task kind. Only the sequential path opens
/// spans; workers never touch the global profiling state.
fn spanLabel(comptime kind: TaskKind) []const u8 {
    return switch (kind) {
        .catalog => "catalog",
        .classes => "classes",
        .fields => "fields",
        .out_offsets => "out_offsets",
        .in_offsets => "in_offsets",
        .out_targets => "out_targets",
        .in_sources => "in_sources",
        .roots => "roots",
        .thread_traces => "thread_traces",
        .dominators => "dominators",
    };
}

/// Record `err` as the task's failure together with a one-line message. The
/// message is only formatted into the task's private buffer; the main thread
/// prints it after the workers join. Returns `err` so callers can write
/// `return taskFail(...)`.
fn taskFail(t: *Task, err: Error, comptime fmt: []const u8, args: anytype) Error {
    t.err = err;
    const printed = std.fmt.bufPrint(&t.msg_buf, fmt, args) catch {
        // All messages are short and statically formatted; this only fires
        // if the buffer is too small. Fall back to the generic report.
        t.msg_len = 0;
        return err;
    };
    t.msg_len = printed.len;
    return err;
}

/// Print a task's captured failure message (or a generic fallback when the
/// specific message did not fit) to `stderr`. Called at most once per
/// validation run, on the main thread, after the workers have joined.
fn reportTaskFailure(stderr: *Io.Writer, t: *const Task) !void {
    if (t.msg_len > 0) {
        try Cli.printError(stderr, "{s}", .{t.msg_buf[0..t.msg_len]});
    } else {
        try Cli.printError(stderr, "index validation failed: {s} validation failed", .{fileName(t.kind)});
    }
}

/// Open `path`, memory-map it read-only, and return the file handle, map, and
/// its data. If the file is empty, returns `null` so callers can treat it as
/// an empty slice without attempting a zero-length mmap. A failure message is
/// captured into `t` and `err` is returned. Only the main thread calls this.
fn mapTaskFile(
    io: Io,
    t: *Task,
    path: []const u8,
    name: []const u8,
    err: Error,
) Error!?MappedFile {
    const dir = Io.Dir.cwd();
    var file = dir.openFile(io, path, .{}) catch |open_err| {
        return taskFail(t, err, "index validation failed: failed to open '{s}': {s}", .{ name, @errorName(open_err) });
    };
    const len = file.length(io) catch |len_err| {
        file.close(io);
        return taskFail(t, err, "index validation failed: failed to read size of '{s}': {s}", .{ name, @errorName(len_err) });
    };
    if (len == 0) {
        file.close(io);
        return null;
    }

    const mm = Io.File.MemoryMap.create(io, file, .{
        .len = len,
        .protection = .{ .read = true, .write = false },
        // Demand paging: index files are validated with a streaming scan and
        // can be larger than RAM.
        .populate = false,
    }) catch |map_err| {
        file.close(io);
        return taskFail(t, err, "index validation failed: failed to map '{s}': {s}", .{ name, @errorName(map_err) });
    };
    return .{ .file = file, .mm = mm, .data = mm.memory };
}

/// Store a successfully mapped file in the task's next slot and expose its
/// data slice to the scanners.
fn storeMappedFile(t: *Task, slot: usize, mapped: MappedFile) void {
    t.maps[slot] = mapped;
    t.datas[slot] = mapped.data;
}

/// Open, map, or read the task's files on the main thread so that workers
/// only scan in-memory slices. Every failure is captured into the task; the
/// returned error is the captured one and may be ignored by the caller.
fn mapTaskFiles(allocator: std.mem.Allocator, io: Io, staging_dir: []const u8, t: *Task) Error!void {
    switch (t.kind) {
        .dominators => {
            const dom_files = [_][]const u8{ "dom_parent.bin", "dom_order.bin", "retained.bin" };
            for (dom_files, 0..) |name, slot| {
                const path = std.fs.path.join(allocator, &.{ staging_dir, name }) catch {
                    t.err = error.OutOfMemory;
                    return error.OutOfMemory;
                };
                defer allocator.free(path);
                const mapped = mapTaskFile(io, t, path, name, error.MissingFile) catch |e| return e;
                if (mapped) |m| storeMappedFile(t, slot, m);
            }
            if (t.maps[0] == null or t.maps[1] == null or t.maps[2] == null) {
                return taskFail(t, error.MissingFile, "index validation failed: missing dominator file", .{});
            }
            const catalog_path = std.fs.path.join(allocator, &.{ staging_dir, "catalog.bin" }) catch {
                t.err = error.OutOfMemory;
                return error.OutOfMemory;
            };
            defer allocator.free(catalog_path);
            const catalog_mapped = mapTaskFile(io, t, catalog_path, "catalog.bin", error.InvalidCatalogFile) catch |e| return e;
            if (catalog_mapped) |m| storeMappedFile(t, 3, m);
        },
        .thread_traces => {
            const path = std.fs.path.join(allocator, &.{ staging_dir, fileName(t.kind) }) catch {
                t.err = error.OutOfMemory;
                return error.OutOfMemory;
            };
            defer allocator.free(path);
            // thread_traces.bin is bounded by the thread/frame counts, so it
            // is read in full instead of mapped.
            const data = Io.Dir.cwd().readFileAlloc(io, path, std.heap.smp_allocator, .unlimited) catch {
                return taskFail(t, error.InvalidThreadTracesFile, "index validation failed: thread_traces.bin is unreadable", .{});
            };
            t.traces_buf = data;
        },
        else => {
            const path = std.fs.path.join(allocator, &.{ staging_dir, fileName(t.kind) }) catch {
                t.err = error.OutOfMemory;
                return error.OutOfMemory;
            };
            defer allocator.free(path);
            const mapped = mapTaskFile(io, t, path, fileName(t.kind), fileMapError(t.kind)) catch |e| return e;
            if (mapped) |m| storeMappedFile(t, 0, m);
        },
    }
}

/// Unmap and close the task's files and free its traces buffer. Only called
/// on the main thread after all workers have joined.
fn cleanupTask(io: Io, t: *Task) void {
    for (&t.maps) |*m| {
        if (m.*) |*mapped| {
            mapped.mm.destroy(io);
            mapped.file.close(io);
        }
    }
    if (t.traces_buf) |buf| std.heap.smp_allocator.free(buf);
}

/// Validate all structural invariants of the staged index. Any failure prints
/// a one-line error to `stderr` and returns `error.InvariantViolation` (or a
/// more specific file-format error). On success the staged files are
/// guaranteed to be internally consistent and safe to publish.
///
/// `n_objects` is the number of unique rows in `catalog.bin`. The virtual
/// root ordinal is `n_objects` and every edge endpoint must be `<= n_objects`.
///
/// Per-file checks run as parallel tasks on multi-core hosts (at most one
/// worker thread per task, LPT-balanced by file size). The reported failure
/// is always the earliest one in the fixed check order, so diagnostics match
/// the sequential path exactly. Missing files are caught first, on the
/// calling thread, before any task is prepared.
pub fn validate(
    allocator: std.mem.Allocator,
    io: Io,
    staging_dir: []const u8,
    n_objects: u64,
    n_edges: u64,
    n_roots: u64,
    n_classes: u64,
    has_dominators: bool,
    stderr: *Io.Writer,
) Error!void {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return validateWithWorkers(
        allocator,
        io,
        staging_dir,
        n_objects,
        n_edges,
        n_roots,
        n_classes,
        has_dominators,
        stderr,
        cpu_count,
    );
}

/// `validate` with an explicit worker count, mirroring the dispatch contract
/// of the scan and edge-emission stages: `n_workers <= 1` runs every check
/// sequentially on the calling thread; more workers fan the per-file tasks
/// out over threads. Exposed so tests can exercise both paths
/// deterministically regardless of host CPU count.
pub fn validateWithWorkers(
    allocator: std.mem.Allocator,
    io: Io,
    staging_dir: []const u8,
    n_objects: u64,
    n_edges: u64,
    n_roots: u64,
    n_classes: u64,
    has_dominators: bool,
    stderr: *Io.Writer,
    n_workers: usize,
) Error!void {
    // 1. Every expected file exists and is readable.
    for (expected_files) |name| {
        const path = try std.fs.path.join(allocator, &.{ staging_dir, name });
        defer allocator.free(path);
        _ = fileSize(io, path) catch |err| {
            try Cli.printError(stderr, "index validation failed: missing or unreadable staged file '{s}': {s}", .{ name, @errorName(err) });
            return error.MissingFile;
        };
    }

    const virtual_root_ordinal = n_objects;
    const n_nodes = n_objects + 1;

    // 2. Build the task list in the fixed check order.
    var tasks: [max_tasks]Task = undefined;
    var n_tasks: usize = 0;

    tasks[n_tasks] = .{
        .kind = .catalog,
        .n_objects = n_objects,
        .n_classes = n_classes,
        .est_bytes = n_objects * Scanner.catalog_row_size,
    };
    n_tasks += 1;
    tasks[n_tasks] = .{ .kind = .classes, .n_classes = n_classes };
    n_tasks += 1;
    tasks[n_tasks] = .{ .kind = .fields, .n_classes = n_classes };
    n_tasks += 1;
    tasks[n_tasks] = .{
        .kind = .out_offsets,
        .n_nodes = n_nodes,
        .n_edges = n_edges,
        .est_bytes = (n_nodes + 1) * 8,
    };
    n_tasks += 1;
    tasks[n_tasks] = .{
        .kind = .in_offsets,
        .n_nodes = n_nodes,
        .n_edges = n_edges,
        .est_bytes = (n_nodes + 1) * 8,
    };
    n_tasks += 1;
    tasks[n_tasks] = .{
        .kind = .out_targets,
        .n_edges = n_edges,
        .virtual_root_ordinal = virtual_root_ordinal,
        .est_bytes = n_edges * 4,
    };
    n_tasks += 1;
    tasks[n_tasks] = .{
        .kind = .in_sources,
        .n_edges = n_edges,
        .virtual_root_ordinal = virtual_root_ordinal,
        .est_bytes = n_edges * 4,
    };
    n_tasks += 1;
    tasks[n_tasks] = .{
        .kind = .roots,
        .n_roots = n_roots,
        .virtual_root_ordinal = virtual_root_ordinal,
        .est_bytes = n_roots * Csr.roots_bin_record_size,
    };
    n_tasks += 1;
    tasks[n_tasks] = .{ .kind = .thread_traces };
    n_tasks += 1;
    if (has_dominators) {
        // dom_parent (4B) + retained (8B) + dom_order (<=4B) per node, plus a
        // re-scan of catalog.bin for the retained-size reconciliation.
        tasks[n_tasks] = .{
            .kind = .dominators,
            .n_objects = n_objects,
            .n_nodes = n_nodes,
            .est_bytes = n_nodes * 16 + n_objects * Scanner.catalog_row_size,
        };
        n_tasks += 1;
    }

    defer {
        for (tasks[0..n_tasks]) |*t| cleanupTask(io, t);
    }

    // 3. Open, map, or read every task's files here, on the calling thread.
    //    Failures are captured per task, so the returned error is redundant.
    for (tasks[0..n_tasks]) |*t| {
        if (t.err == null) mapTaskFiles(allocator, io, staging_dir, t) catch {};
    }

    // 4. Run the checks, then report the earliest failure in check order so
    //    parallel and sequential runs print identical diagnostics.
    try dispatchTasks(allocator, io, tasks[0..n_tasks], @min(n_workers, n_tasks));

    for (tasks[0..n_tasks]) |*t| {
        if (t.err) |err| {
            try reportTaskFailure(stderr, t);
            return err;
        }
    }
}

/// Run the tasks: `n_workers <= 1` scans each task in order on the calling
/// thread (with per-task profiling spans); otherwise the tasks are
/// LPT-partitioned by estimated bytes and each bucket runs on its own
/// thread. Failures are captured into the tasks, never printed from here.
fn dispatchTasks(allocator: std.mem.Allocator, io: Io, tasks: []Task, n_workers: usize) Error!void {
    if (n_workers <= 1) {
        for (tasks) |*t| {
            if (t.err != null) return;
            runTaskProfiled(io, t);
            if (t.err != null) return;
        }
        return;
    }

    const buckets = try partitionTasksLPT(allocator, tasks, n_workers);
    defer {
        for (buckets) |*b| b.deinit(allocator);
        allocator.free(buckets);
    }

    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(allocator);
    var n_joined: usize = 0;
    // Join exactly once: threads appended after a spawn but before an
    // append failure are joined inline; threads already joined on the
    // normal path are excluded here via `n_joined`.
    errdefer for (threads.items[n_joined..]) |t| t.join();
    for (buckets) |*b| {
        if (b.items.len == 0) continue;
        const thread = std.Thread.spawn(.{}, workerRun, .{b.items}) catch {
            // Spawning failed (e.g. the process hit its thread limit);
            // degrade gracefully by scanning this bucket inline.
            workerRun(b.items);
            continue;
        };
        threads.append(allocator, thread) catch |e| {
            thread.join();
            return e;
        };
    }
    for (threads.items[n_joined..]) |t| {
        t.join();
        n_joined += 1;
    }
}

/// Longest-processing-time-first partition over tasks: tasks are sorted by
/// estimated bytes (descending, original index ascending on ties) and each
/// goes to the currently lightest worker bucket. Deterministic for a given
/// task list; each bucket preserves the sorted order. Caller owns the
/// returned buckets.
fn partitionTasksLPT(allocator: std.mem.Allocator, tasks: []Task, n_workers: usize) Error![]std.ArrayList(*Task) {
    var loads = try allocator.alloc(u64, n_workers);
    defer allocator.free(loads);
    @memset(loads, 0);

    const order = try allocator.alloc(usize, tasks.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    const SortCtx = struct {
        tasks: []const Task,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            if (ctx.tasks[a].est_bytes != ctx.tasks[b].est_bytes)
                return ctx.tasks[a].est_bytes > ctx.tasks[b].est_bytes;
            return a < b;
        }
    };
    std.mem.sort(usize, order, SortCtx{ .tasks = tasks }, SortCtx.lessThan);

    const buckets = try allocator.alloc(std.ArrayList(*Task), n_workers);
    errdefer {
        for (buckets) |*b| b.deinit(allocator);
        allocator.free(buckets);
    }
    for (buckets) |*b| b.* = .empty;
    for (order) |i| {
        var min_i: usize = 0;
        for (1..n_workers) |w| {
            if (loads[w] < loads[min_i]) min_i = w;
        }
        try buckets[min_i].append(allocator, &tasks[i]);
        loads[min_i] += tasks[i].est_bytes;
    }
    return buckets;
}

/// Worker entry point: scan each task in the bucket, capturing failures.
fn workerRun(bucket: []const *Task) void {
    for (bucket) |t| {
        if (t.err != null) continue;
        runTask(t);
    }
}

/// Scan one task, capturing any failure into the task.
fn runTask(t: *Task) void {
    validateTask(t) catch |e| {
        // taskFail already recorded specific failures; keep the first one.
        if (t.err == null) t.err = e;
    };
}

/// Sequential variant that also opens the per-task profiling spans. Only the
/// calling thread may touch the global profiling state.
fn runTaskProfiled(io: Io, t: *Task) void {
    switch (t.kind) {
        inline else => |kind| {
            var span = profiling.begin(io, spanLabel(kind));
            defer span.end(io);
            runTask(t);
        },
    }
}

/// Dispatch one task to its per-kind scanner.
fn validateTask(t: *Task) Error!void {
    switch (t.kind) {
        .catalog => try validateCatalog(t),
        .classes => try validateClasses(t),
        .fields => try validateFields(t),
        .out_offsets, .in_offsets => try validateOffsets(t),
        .out_targets, .in_sources => try validateAdjacency(t),
        .roots => try validateRoots(t),
        .thread_traces => try validateThreadTraces(t),
        .dominators => try validateDominators(t),
    }
}

/// Validate the three optional dominator files.
///
/// Checks:
///   * All three files exist.
///   * `dom_parent.bin` size == n_nodes * 4.
///   * `retained.bin` size == n_nodes * 8.
///   * `dom_order.bin` size % 4 == 0 and n_reachable = size / 4.
///   * Every dom_parent entry is NONE or < V, and no self-domination except root.
///   * retained[v] >= shallow[v] for every real object.
///   * retained[root] == sum of shallow over reachable real objects.
///   * dom_order entries are distinct, in range, and dom_order[0] is the virtual root.
fn validateDominators(t: *Task) Error!void {
    const allocator = std.heap.smp_allocator;
    const dp = t.datas[0];
    const dor = t.datas[1];
    const ret = t.datas[2];
    const catalog_data = t.datas[3];

    const n_nodes = t.n_nodes;
    const n_objects = t.n_objects;

    if (dp.len != n_nodes * 4) {
        return taskFail(t, error.InvariantViolation, "index validation failed: dom_parent.bin has unexpected size", .{});
    }
    if (ret.len != n_nodes * 8) {
        return taskFail(t, error.InvariantViolation, "index validation failed: retained.bin has unexpected size", .{});
    }
    if (dor.len % 4 != 0) {
        return taskFail(t, error.InvariantViolation, "index validation failed: dom_order.bin has unexpected size", .{});
    }
    const n_reachable = dor.len / 4;
    const virtual_root = n_nodes - 1;

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    var i: usize = 0;
    while (i < n_nodes) : (i += 1) {
        const parent = std.mem.readInt(u32, dp[i * 4 ..][0..4], .little);
        if (parent == std.math.maxInt(u32)) continue;
        if (parent >= n_nodes) {
            return taskFail(t, error.InvariantViolation, "index validation failed: dom_parent.bin contains an out-of-range ordinal", .{});
        }
        if (parent == i) {
            return taskFail(t, error.InvariantViolation, "index validation failed: dom_parent.bin contains a self-domination", .{});
        }
    }

    i = 0;
    while (i < n_reachable) : (i += 1) {
        const ord = std.mem.readInt(u32, dor[i * 4 ..][0..4], .little);
        if (ord >= n_nodes) {
            return taskFail(t, error.InvariantViolation, "index validation failed: dom_order.bin contains an out-of-range ordinal", .{});
        }
        if (i == 0 and ord != virtual_root) {
            return taskFail(t, error.InvariantViolation, "index validation failed: dom_order.bin does not start with the virtual root", .{});
        }
        const gop = try seen.getOrPut(@intCast(ord));
        if (gop.found_existing) {
            return taskFail(t, error.InvariantViolation, "index validation failed: dom_order.bin contains a duplicate ordinal", .{});
        }
    }

    // Guard the row slicing below: the dedicated catalog task reports size
    // problems first, but parallel dispatch must not panic on a truncated
    // or empty catalog.
    if (catalog_data.len < n_objects * Scanner.catalog_row_size) {
        return taskFail(t, error.InvalidCatalogFile, "index validation failed: catalog.bin has an unexpected size", .{});
    }

    var reachable_shallow_sum: u64 = 0;
    i = 0;
    while (i < n_objects) : (i += 1) {
        const row = Scanner.readCatalogRow(catalog_data[i * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size]) catch {
            return taskFail(t, error.InvalidCatalogFile, "index validation failed: catalog.bin row is malformed", .{});
        };
        const retained = std.mem.readInt(u64, ret[i * 8 ..][0..8], .little);
        if (retained < row.shallow_size) {
            return taskFail(t, error.InvariantViolation, "index validation failed: retained.bin entry is smaller than shallow size", .{});
        }
        if (seen.contains(@intCast(i))) {
            reachable_shallow_sum += row.shallow_size;
        }
    }

    const root_retained = std.mem.readInt(u64, ret[virtual_root * 8 ..][0..8], .little);
    if (root_retained != reachable_shallow_sum) {
        return taskFail(t, error.InvariantViolation, "index validation failed: retained[root] does not reconcile with reachable shallow total", .{});
    }
}

/// Validate `thread_traces.bin` by parsing the pre-read buffer; the parser
/// performs full structural validation (magic, version, section sizes,
/// index bounds).
fn validateThreadTraces(t: *Task) Error!void {
    const allocator = std.heap.smp_allocator;
    const data = t.traces_buf orelse &[_]u8{};

    var parsed = ThreadTraces.Parsed.parse(allocator, data) catch {
        return taskFail(t, error.InvalidThreadTracesFile, "index validation failed: thread_traces.bin is malformed", .{});
    };
    defer parsed.deinit();
}

/// Return the size of `path` in bytes, or propagate the underlying I/O error.
fn fileSize(io: Io, path: []const u8) !u64 {
    const dir = Io.Dir.cwd();
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    return try file.length(io);
}

/// Validate `catalog.bin`.
///
/// Checks:
///   * File size is a multiple of `Scanner.catalog_row_size`.
///   * Row count equals `n_objects`.
///   * `raw_id` values are strictly increasing.
///   * Kind byte is in the valid range.
///   * Number of class rows equals `n_classes`.
fn validateCatalog(t: *Task) Error!void {
    const data = t.datas[0];

    if (data.len % Scanner.catalog_row_size != 0) {
        return taskFail(t, error.InvalidCatalogFile, "index validation failed: catalog.bin has an unexpected size", .{});
    }

    const n_rows = data.len / Scanner.catalog_row_size;
    if (n_rows != t.n_objects) {
        return taskFail(t, error.InvariantViolation, "index validation failed: catalog.bin has an unexpected number of rows", .{});
    }

    var class_count: u64 = 0;
    var last_id: u64 = 0;
    var i: usize = 0;
    while (i < n_rows) : (i += 1) {
        const row = data[i * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size];
        const raw_id = std.mem.readInt(u64, row[0..8], .little);
        const kind_byte = row[28];

        // CatalogKind values are 0..3; anything else is corrupt.
        if (kind_byte > 3) {
            return taskFail(t, error.InvalidCatalogFile, "index validation failed: catalog.bin contains an invalid row", .{});
        }
        if (kind_byte == 3) {
            class_count += 1;
        }

        // Raw IDs must be strictly sorted so that ordinals are stable and
        // binary search in later stages works.
        if (i > 0) {
            if (raw_id <= last_id) {
                return taskFail(t, error.InvariantViolation, "index validation failed: catalog.bin rows are not sorted", .{});
            }
        }
        last_id = raw_id;
    }

    if (class_count != t.n_classes) {
        return taskFail(t, error.InvariantViolation, "index validation failed: catalog.bin class count does not match expected value", .{});
    }
}

/// Validate `classes.bin`.
///
/// Checks:
///   * Records are parseable: class ID, superclass ID, instance size, name length,
///     and name bytes all fit inside the file.
///   * Class IDs are strictly increasing.
///   * Record count equals `n_classes`.
fn validateClasses(t: *Task) Error!void {
    const data = t.datas[0];

    var offset: usize = 0;
    var count: u64 = 0;
    var last_id: u64 = 0;
    while (offset < data.len) {
        if (offset + 24 > data.len) {
            return taskFail(t, error.InvalidClassesFile, "index validation failed: classes.bin is truncated", .{});
        }
        const class_id = std.mem.readInt(u64, data[offset..][0..8], .little);
        const name_len = std.mem.readInt(u32, data[offset + 20 ..][0..4], .little);
        if (offset + 24 + name_len > data.len) {
            return taskFail(t, error.InvalidClassesFile, "index validation failed: classes.bin is truncated", .{});
        }
        if (count > 0 and class_id <= last_id) {
            return taskFail(t, error.InvariantViolation, "index validation failed: classes.bin is not sorted", .{});
        }
        last_id = class_id;
        offset += 24 + name_len;
        count += 1;
    }

    if (count != t.n_classes) {
        return taskFail(t, error.InvariantViolation, "index validation failed: classes.bin has an unexpected number of records", .{});
    }
}

/// Validate `fields.bin`.
///
/// Checks:
///   * File is parseable as a sequence of class records.
///   * Each class record has a `class_raw_id` and `field_count`.
///   * Each field record fits inside the file.
///   * Class record count equals `n_classes`.
///
/// Field names and types are not fully decoded here; structural consistency is
/// enough because the query-time reader will detect malformed field data.
fn validateFields(t: *Task) Error!void {
    const data = t.datas[0];

    var offset: usize = 0;
    var class_count: u64 = 0;
    while (offset < data.len) {
        if (offset + 12 > data.len) {
            return taskFail(t, error.InvalidFieldsFile, "index validation failed: fields.bin is truncated", .{});
        }
        // class_raw_id u64 + field_count u32
        const field_count = std.mem.readInt(u32, data[offset + 8 ..][0..4], .little);
        offset += 12;

        var field_idx: u32 = 0;
        while (field_idx < field_count) : (field_idx += 1) {
            if (offset + 2 > data.len) {
                return taskFail(t, error.InvalidFieldsFile, "index validation failed: fields.bin is truncated", .{});
            }
            const name_len = std.mem.readInt(u16, data[offset..][0..2], .little);
            // name_len u16 + name bytes + type u8 + byte_offset u32 + declaring_class_raw_id u64
            if (offset + 2 + name_len + 13 > data.len) {
                return taskFail(t, error.InvalidFieldsFile, "index validation failed: fields.bin is truncated", .{});
            }
            offset += 2 + name_len + 13;
        }
        class_count += 1;
    }

    if (class_count != t.n_classes) {
        return taskFail(t, error.InvariantViolation, "index validation failed: fields.bin has an unexpected number of class records", .{});
    }
}

/// Validate a CSR offsets file (`out_offsets.bin` or `in_offsets.bin`).
///
/// Checks:
///   * File size is a multiple of 8 bytes.
///   * Entry count equals `n_nodes + 1`.
///   * First entry is 0.
///   * Entries are monotone non-decreasing.
///   * Last entry equals `n_edges`.
fn validateOffsets(t: *Task) Error!void {
    const name = fileName(t.kind);
    const data = t.datas[0];

    if (data.len % 8 != 0) {
        return taskFail(t, error.InvalidOffsetFile, "index validation failed: {s} has an unexpected size", .{name});
    }

    const n_entries = data.len / 8;
    if (n_entries != t.n_nodes + 1) {
        return taskFail(t, error.InvariantViolation, "index validation failed: {s} has an unexpected number of entries", .{name});
    }

    var last: u64 = 0;
    var i: usize = 0;
    while (i < n_entries) : (i += 1) {
        const value = std.mem.readInt(u64, data[i * 8 ..][0..8], .little);
        if (i == 0 and value != 0) {
            return taskFail(t, error.InvariantViolation, "index validation failed: {s} starts with a non-zero value", .{name});
        }
        if (value < last) {
            return taskFail(t, error.InvariantViolation, "index validation failed: {s} is not monotone", .{name});
        }
        last = value;
    }

    if (last != t.n_edges) {
        return taskFail(t, error.InvariantViolation, "index validation failed: {s} ends with an unexpected value", .{name});
    }
}

/// Validate a CSR adjacency file (`out_targets.bin` or `in_sources.bin`).
///
/// Checks:
///   * File size is a multiple of 4 bytes.
///   * Entry count equals `n_edges`.
///   * Every ordinal is `<= virtual_root_ordinal`.
fn validateAdjacency(t: *Task) Error!void {
    const name = fileName(t.kind);
    const data = t.datas[0];

    if (data.len % 4 != 0) {
        return taskFail(t, error.InvalidAdjacencyFile, "index validation failed: {s} has an unexpected size", .{name});
    }

    const n_entries = data.len / 4;
    if (n_entries != t.n_edges) {
        return taskFail(t, error.InvariantViolation, "index validation failed: {s} has an unexpected number of entries", .{name});
    }

    var i: usize = 0;
    while (i < n_entries) : (i += 1) {
        const value = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        if (value > t.virtual_root_ordinal) {
            return taskFail(t, error.InvariantViolation, "index validation failed: {s} contains an invalid ordinal", .{name});
        }
    }
}

/// Validate `roots.bin`.
///
/// Checks:
///   * File size is a multiple of `Csr.roots_bin_record_size`.
///   * Record count equals `n_roots`.
///   * Every `target_ordinal` is `<= virtual_root_ordinal`.
fn validateRoots(t: *Task) Error!void {
    const data = t.datas[0];

    if (data.len % Csr.roots_bin_record_size != 0) {
        return taskFail(t, error.InvalidRootsFile, "index validation failed: roots.bin has an unexpected size", .{});
    }

    const n_entries = data.len / Csr.roots_bin_record_size;
    if (n_entries != t.n_roots) {
        return taskFail(t, error.InvariantViolation, "index validation failed: roots.bin has an unexpected number of records", .{});
    }

    var i: usize = 0;
    while (i < n_entries) : (i += 1) {
        const rec = Csr.readRootRecord(data[i * Csr.roots_bin_record_size ..][0..Csr.roots_bin_record_size]);
        if (rec.target_ordinal > t.virtual_root_ordinal) {
            return taskFail(t, error.InvariantViolation, "index validation failed: roots.bin contains an invalid ordinal", .{});
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Create a synthetic `catalog.bin` file in `dir` from in-memory rows.
fn createSyntheticCatalog(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    rows: []const Scanner.CatalogRow,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "catalog.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (rows) |row| {
        try Scanner.writeCatalogRow(&writer.interface, row);
    }
    try writer.flush();
}

/// Create a synthetic CSR offsets file in `dir` with the given name.
fn createSyntheticOffsets(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
    offsets: []const u64,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (offsets) |off| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, off, .little);
        try writer.interface.writeAll(&bytes);
    }
    try writer.flush();
}

/// Create a synthetic CSR adjacency file in `dir` with the given name.
fn createSyntheticAdjacency(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
    values: []const u32,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |v| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, v, .little);
        try writer.interface.writeAll(&bytes);
    }
    try writer.flush();
}

/// In-memory representation of a resolved root for test fixtures.
const SyntheticRoot = struct {
    target_ordinal: u32,
    root_kind: u8,
    thread_serial: u32,
};

/// Create a synthetic `roots.bin` file in `dir` from in-memory roots.
fn createSyntheticRoots(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    roots: []const SyntheticRoot,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "roots.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (roots) |r| {
        try Csr.writeRootRecord(&writer.interface, .{
            .target_ordinal = r.target_ordinal,
            .root_kind = r.root_kind,
            .thread_serial = r.thread_serial,
        });
    }
    try writer.flush();
}

/// In-memory representation of a classes.bin record for test fixtures.
const SyntheticClass = struct {
    class_id: u64,
    super_id: u64,
    instance_size: u32,
    name: []const u8,
};

/// Create a synthetic `classes.bin` file in `dir` from in-memory classes.
fn createSyntheticClasses(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    classes: []const SyntheticClass,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "classes.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (classes) |c| {
        var header: [24]u8 = undefined;
        std.mem.writeInt(u64, header[0..8], c.class_id, .little);
        std.mem.writeInt(u64, header[8..16], c.super_id, .little);
        std.mem.writeInt(u32, header[16..20], c.instance_size, .little);
        std.mem.writeInt(u32, header[20..24], @intCast(c.name.len), .little);
        try writer.interface.writeAll(&header);
        if (c.name.len > 0) {
            try writer.interface.writeAll(c.name);
        }
    }
    try writer.flush();
}

/// Create a synthetic `fields.bin` file with `class_count` empty class records.
fn createSyntheticFields(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    class_count: u64,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "fields.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);

    var i: u64 = 0;
    while (i < class_count) : (i += 1) {
        var class_header: [12]u8 = undefined;
        std.mem.writeInt(u64, class_header[0..8], i, .little);
        std.mem.writeInt(u32, class_header[8..12], 0, .little);
        try writer.interface.writeAll(&class_header);
    }
    try writer.flush();
}

/// Create a synthetic `prim_histogram.bin` file in `dir`.
fn createSyntheticPrimHistogram(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "prim_histogram.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, 0, .little);
    try writer.interface.writeAll(&count_buf);
    try writer.flush();
}

/// Create a synthetic (empty but valid) `thread_traces.bin` file in `dir`.
fn createSyntheticThreadTraces(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "thread_traces.bin" });
    defer allocator.free(path);

    const data = try allocator.alloc(u8, ThreadTraces.header_size);
    defer allocator.free(data);
    var fixed_writer = Io.Writer.fixed(data);
    try ThreadTraces.serialize(allocator, &fixed_writer, &.{}, &.{}, &.{});

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    try writer.interface.writeAll(data);
    try writer.flush();
}

/// Write raw `bytes` to `dir/name`; used to corrupt staged files in tests.
fn createRawFile(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
    bytes: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.flush();
}

/// Run `validate` on `dir` with the given counts and capture stderr to a buffer.
fn runValidate(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    n_objects: u64,
    n_edges: u64,
    n_roots: u64,
    n_classes: u64,
) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    try validate(allocator, io, dir, n_objects, n_edges, n_roots, n_classes, false, &stderr_writer.interface);
}

fn runValidateWithDominators(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    n_objects: u64,
    n_edges: u64,
    n_roots: u64,
    n_classes: u64,
) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    try validate(allocator, io, dir, n_objects, n_edges, n_roots, n_classes, true, &stderr_writer.interface);
}

/// Run `validateWithWorkers` on `dir` with an explicit worker count.
fn runValidateWorkers(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    n_objects: u64,
    n_edges: u64,
    n_roots: u64,
    n_classes: u64,
    has_dominators: bool,
    n_workers: usize,
) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    try validateWithWorkers(allocator, io, dir, n_objects, n_edges, n_roots, n_classes, has_dominators, &stderr_writer.interface, n_workers);
}

// A complete, valid staged directory passes all checks.
test "validate accepts consistent 2-node graph" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // 2 real objects, virtual root ordinal = 2.
    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });

    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{});
    try createSyntheticFields(allocator, io, tmp_path, 0);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 1, 1, 1 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 1, 1 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{1});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{0});

    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{
        .{ .target_ordinal = 0, .root_kind = 0x01, .thread_serial = 0 },
    });

    try runValidate(allocator, io, tmp_path, 2, 1, 1, 0);
}

// Non-increasing raw IDs in the catalog must be rejected.
test "validate rejects unsorted catalog" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });

    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 2, 0, 0, 1));
}

// Decreasing offset entries would break the CSR invariant; they must fail.
test "validate rejects non-monotone offsets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 1, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 1, 0, 0, 1));
}

// Ordinals greater than the virtual root ordinal are out of range.
test "validate rejects adjacency ordinal exceeding virtual root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 1 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 1 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{2}); // virtual root = 1, so 2 is invalid
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{0});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 1, 1, 0, 1));
}

// The catalog row count must equal n_objects.
test "validate rejects catalog row count mismatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 2, 0, 0, 1));
}

// The classes.bin record count must match the number of class rows in the catalog.
test "validate rejects classes.bin count mismatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .class },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
        .{ .class_id = 0x2000, .super_id = 0, .instance_size = 8, .name = "B" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 2);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    // n_classes claims 1, but catalog has 2 class rows and classes.bin has 2 records.
    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 2, 0, 0, 1));
}

// The roots.bin record count must match n_roots.
test "validate rejects roots.bin count mismatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{
        .{ .target_ordinal = 0, .root_kind = 0x01, .thread_serial = 0 },
    });

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 1, 0, 0, 1));
}

// Root target ordinals must also be in range.
test "validate rejects roots target ordinal exceeding virtual root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{
        .{ .target_ordinal = 2, .root_kind = 0x01, .thread_serial = 0 },
    });

    try std.testing.expectError(error.InvariantViolation, runValidate(allocator, io, tmp_path, 1, 0, 1, 1));
}

// A completely empty staging directory must fail the missing-file check.
test "validate detects missing staged file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try std.testing.expectError(error.MissingFile, runValidate(allocator, io, tmp_path, 0, 0, 0, 0));
}

fn createSyntheticDomParent(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    values: []const u32,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "dom_parent.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try writer.interface.writeAll(&b);
    }
    try writer.flush();
}

fn createSyntheticDomOrder(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    values: []const u32,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "dom_order.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try writer.interface.writeAll(&b);
    }
    try writer.flush();
}

fn createSyntheticRetained(
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    values: []const u64,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, "retained.bin" });
    defer allocator.free(path);

    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [65536]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &buf);
    for (values) |v| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try writer.interface.writeAll(&b);
    }
    try writer.flush();
}

// A consistent set of dominator files passes validation.
test "validate accepts consistent dominator files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // 2 real objects + virtual root = 3 nodes.
    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{});
    try createSyntheticFields(allocator, io, tmp_path, 0);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    // Virtual root = 2, dom_order = [2, 0, 1], dom_parent = [NONE, NONE, NONE].
    const NONE_U32 = std.math.maxInt(u32);
    try createSyntheticDomParent(allocator, io, tmp_path, &[_]u32{ NONE_U32, NONE_U32, NONE_U32 });
    try createSyntheticDomOrder(allocator, io, tmp_path, &[_]u32{ 2, 0, 1 });
    try createSyntheticRetained(allocator, io, tmp_path, &[_]u64{ 8, 8, 16 });

    try runValidateWithDominators(allocator, io, tmp_path, 2, 0, 0, 0);
}

// dom_parent entries must not self-dominate.
test "validate rejects self-domination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{});
    try createSyntheticFields(allocator, io, tmp_path, 0);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);

    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    const NONE_U32 = std.math.maxInt(u32);
    try createSyntheticDomParent(allocator, io, tmp_path, &[_]u32{ 0, NONE_U32, NONE_U32 });
    try createSyntheticDomOrder(allocator, io, tmp_path, &[_]u32{ 1, 0 });
    try createSyntheticRetained(allocator, io, tmp_path, &[_]u64{ 8, 8, 8 });

    try std.testing.expectError(error.InvariantViolation, runValidateWithDominators(allocator, io, tmp_path, 1, 0, 0, 0));
}

// ─────────────────────────────────────────────────────────────────────────────
// Parallel dispatch tests
// ─────────────────────────────────────────────────────────────────────────────

// The parallel and sequential dispatch paths agree on a valid index.
test "parallel validation accepts consistent 2-node graph" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{});
    try createSyntheticFields(allocator, io, tmp_path, 0);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);
    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 1, 1, 1 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 1, 1 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{1});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{0});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{
        .{ .target_ordinal = 0, .root_kind = 0x01, .thread_serial = 0 },
    });

    try runValidateWorkers(allocator, io, tmp_path, 2, 1, 1, 0, false, 1);
    try runValidateWorkers(allocator, io, tmp_path, 2, 1, 1, 0, false, 4);
    // More workers than tasks exercises the worker-count cap.
    try runValidateWorkers(allocator, io, tmp_path, 2, 1, 1, 0, false, 16);
}

// A failure must be reported identically from the parallel path.
test "parallel validation rejects unsorted catalog" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{
        .{ .class_id = 0x1000, .super_id = 0, .instance_size = 8, .name = "A" },
    });
    try createSyntheticFields(allocator, io, tmp_path, 1);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);
    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    try std.testing.expectError(error.InvariantViolation, runValidateWorkers(allocator, io, tmp_path, 2, 0, 0, 1, false, 4));
}

// When several files are broken, the check that comes first in the fixed
// order must win in both dispatch modes, even though the parallel path runs
// every check.
test "parallel validation reports the earliest failing check" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    // Start from the consistent 2-node fixture.
    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{});
    try createSyntheticFields(allocator, io, tmp_path, 0);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);
    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 1, 1, 1 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 1, 1 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{1});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{0});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{
        .{ .target_ordinal = 0, .root_kind = 0x01, .thread_serial = 0 },
    });

    // Corrupt two later checks: classes.bin is truncated (InvalidClassesFile)
    // and thread_traces.bin holds garbage (InvalidThreadTracesFile). The
    // classes check comes first in the fixed order, so it must win.
    try createRawFile(allocator, io, tmp_path, "classes.bin", &([_]u8{0} ** 10));
    try createRawFile(allocator, io, tmp_path, "thread_traces.bin", &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });

    try std.testing.expectError(error.InvalidClassesFile, runValidateWorkers(allocator, io, tmp_path, 2, 1, 1, 0, false, 1));
    try std.testing.expectError(error.InvalidClassesFile, runValidateWorkers(allocator, io, tmp_path, 2, 1, 1, 0, false, 4));
}

// The pre-dispatch missing-file check fires identically on the parallel path.
test "parallel validation detects missing staged file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try std.testing.expectError(error.MissingFile, runValidateWorkers(allocator, io, tmp_path, 0, 0, 0, 0, false, 4));
}

// A consistent set of dominator files passes the parallel path too.
test "parallel validation accepts consistent dominator files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 0x2000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{});
    try createSyntheticFields(allocator, io, tmp_path, 0);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);
    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    const NONE_U32 = std.math.maxInt(u32);
    try createSyntheticDomParent(allocator, io, tmp_path, &[_]u32{ NONE_U32, NONE_U32, NONE_U32 });
    try createSyntheticDomOrder(allocator, io, tmp_path, &[_]u32{ 2, 0, 1 });
    try createSyntheticRetained(allocator, io, tmp_path, &[_]u64{ 8, 8, 16 });

    try runValidateWorkers(allocator, io, tmp_path, 2, 0, 0, 0, true, 4);
}

// Dominator invariant violations are caught on the parallel path as well.
test "parallel validation rejects self-domination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try createSyntheticCatalog(allocator, io, tmp_path, &[_]Scanner.CatalogRow{
        .{ .raw_id = 0x1000, .source_offset = 0, .class_raw_id = 0, .shallow_size = 8, .kind = .instance },
    });
    try createSyntheticClasses(allocator, io, tmp_path, &[_]SyntheticClass{});
    try createSyntheticFields(allocator, io, tmp_path, 0);
    try createSyntheticPrimHistogram(allocator, io, tmp_path);
    try createSyntheticThreadTraces(allocator, io, tmp_path);
    try createSyntheticOffsets(allocator, io, tmp_path, "out_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticOffsets(allocator, io, tmp_path, "in_offsets.bin", &[_]u64{ 0, 0, 0 });
    try createSyntheticAdjacency(allocator, io, tmp_path, "out_targets.bin", &[_]u32{});
    try createSyntheticAdjacency(allocator, io, tmp_path, "in_sources.bin", &[_]u32{});
    try createSyntheticRoots(allocator, io, tmp_path, &[_]SyntheticRoot{});

    const NONE_U32 = std.math.maxInt(u32);
    try createSyntheticDomParent(allocator, io, tmp_path, &[_]u32{ 0, NONE_U32, NONE_U32 });
    try createSyntheticDomOrder(allocator, io, tmp_path, &[_]u32{ 1, 0 });
    try createSyntheticRetained(allocator, io, tmp_path, &[_]u64{ 8, 8, 8 });

    try std.testing.expectError(error.InvariantViolation, runValidateWorkers(allocator, io, tmp_path, 1, 0, 0, 0, true, 4));
}
