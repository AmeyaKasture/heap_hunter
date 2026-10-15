//! Generic external sorter for fixed-width binary records.
//!
//! Sorts a file of `record_size`-byte records using a bounded in-memory budget.
//! Records are opaque bytes; ordering is determined by a caller-supplied
//! comparator over `[]const u8` record slices.
const std = @import("std");
const Io = std.Io;

pub const Options = struct {
    /// Size of each record in bytes. Must be greater than zero.
    record_size: usize,

    /// Approximate in-memory budget in bytes for each sort/merge pass.
    budget_bytes: usize,

    /// Maximum number of runs merged in a single pass. When the number of
    /// runs exceeds this, merging proceeds in multiple passes.
    max_fanout: usize = 64,
};

pub const Error = error{
    /// The input file length is not a multiple of `record_size`.
    InvalidRecordFile,
};

/// Sort the file at `input_path` and write the result to `output_path`.
///
/// `lessThan(context, a, b)` must return `true` when record `a` is ordered
/// before record `b`. Both `a` and `b` are exactly `options.record_size`
/// bytes long.
///
/// The output file is created (or truncated) at `output_path`. Temporary
/// files are written alongside `output_path` and removed before returning,
/// including on error.
pub fn sort(
    io: Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    options: Options,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), []const u8, []const u8) bool,
) !void {
    std.debug.assert(options.record_size > 0);
    const record_size = options.record_size;

    const dir = Io.Dir.cwd();
    var input_file = try dir.openFile(io, input_path, .{});
    defer input_file.close(io);

    const input_len = try input_file.length(io);
    if (input_len % record_size != 0) {
        return error.InvalidRecordFile;
    }

    // Fast path: the whole input fits in the budget (or is empty).
    if (input_len <= options.budget_bytes) {
        return sortInMemory(io, allocator, input_file, input_len, output_path, record_size, context, lessThan);
    }

    // External sort: generate sorted runs, then merge them.
    const staging_dir = try createStagingDir(io, allocator, output_path);
    defer {
        dir.deleteTree(io, staging_dir) catch {};
        allocator.free(staging_dir);
    }

    var input_mm = try Io.File.MemoryMap.create(io, input_file, .{
        .len = input_len,
        .protection = .{ .read = true, .write = false },
    });
    defer input_mm.destroy(io);

    const runs = try generateRuns(io, allocator, input_mm.memory, staging_dir, record_size, options.budget_bytes, context, lessThan);
    defer {
        for (runs) |run_path| {
            allocator.free(run_path);
        }
        allocator.free(runs);
    }

    try mergeRuns(io, allocator, runs, output_path, record_size, options.max_fanout, context, lessThan);
}

fn SortContext(comptime C: type, comptime lt: fn (C, []const u8, []const u8) bool) type {
    return struct {
        buf: []const u8,
        record_size: usize,
        context: C,

        pub fn less(self: @This(), a: usize, b: usize) bool {
            const rec_a = self.buf[a * self.record_size ..][0..self.record_size];
            const rec_b = self.buf[b * self.record_size ..][0..self.record_size];
            return lt(self.context, rec_a, rec_b);
        }
    };
}

fn sortInMemory(
    io: Io,
    allocator: std.mem.Allocator,
    input_file: Io.File,
    input_len: usize,
    output_path: []const u8,
    record_size: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), []const u8, []const u8) bool,
) !void {
    if (input_len == 0) {
        const out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
        out_file.close(io);
        return;
    }

    var input_mm = try Io.File.MemoryMap.create(io, input_file, .{
        .len = input_len,
        .protection = .{ .read = true, .write = false },
    });
    defer input_mm.destroy(io);

    const n_records = input_len / record_size;
    const indices = try allocator.alloc(usize, n_records);
    defer allocator.free(indices);
    for (0..n_records) |i| indices[i] = i;

    const C = @TypeOf(context);
    const ctx = SortContext(C, lessThan){
        .buf = input_mm.memory,
        .record_size = record_size,
        .context = context,
    };
    std.mem.sort(usize, indices, ctx, SortContext(C, lessThan).less);

    var out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buf: [65536]u8 = undefined;
    var out_writer: Io.File.Writer = .init(out_file, io, &out_buf);
    const out = &out_writer.interface;

    for (indices) |idx| {
        try out.writeAll(input_mm.memory[idx * record_size ..][0..record_size]);
    }
    try out_writer.flush();
}

fn createStagingDir(io: Io, allocator: std.mem.Allocator, output_path: []const u8) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const staging_dir = try std.fmt.allocPrint(allocator, "{s}.extsort-{s}", .{ output_path, suffix[0..] });
    errdefer allocator.free(staging_dir);
    try Io.Dir.cwd().createDirPath(io, staging_dir);
    return staging_dir;
}

fn generateRuns(
    io: Io,
    allocator: std.mem.Allocator,
    input: []const u8,
    staging_dir: []const u8,
    record_size: usize,
    budget_bytes: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), []const u8, []const u8) bool,
) ![]const []const u8 {
    const n_records = input.len / record_size;
    if (n_records == 0) {
        return &[_][]const u8{};
    }

    // Account for the index array overhead so a chunk stays roughly within
    // the requested memory budget.
    const chunk_records = @max(budget_bytes / (record_size + @sizeOf(usize)), 1);
    const chunk_bytes = chunk_records * record_size;
    const n_runs = (n_records + chunk_records - 1) / chunk_records;

    const runs = try allocator.alloc([]const u8, n_runs);
    @memset(runs, "");
    errdefer {
        for (runs) |run_path| {
            if (run_path.len != 0) {
                Io.Dir.cwd().deleteFile(io, run_path) catch {};
                allocator.free(run_path);
            }
        }
        allocator.free(runs);
    }

    const indices = try allocator.alloc(usize, chunk_records);
    defer allocator.free(indices);

    const C = @TypeOf(context);
    const Less = SortContext(C, lessThan);

    var offset: usize = 0;
    var run_idx: usize = 0;
    while (offset < input.len) : (run_idx += 1) {
        const end = @min(offset + chunk_bytes, input.len);
        const chunk = input[offset..end];
        const chunk_n = chunk.len / record_size;

        for (0..chunk_n) |i| indices[i] = i;

        const ctx = Less{
            .buf = chunk,
            .record_size = record_size,
            .context = context,
        };
        std.mem.sort(usize, indices[0..chunk_n], ctx, Less.less);

        const run_path = try std.fmt.allocPrint(allocator, "{s}/run-{d}", .{ staging_dir, run_idx });
        runs[run_idx] = run_path;

        var out_file = try Io.Dir.cwd().createFile(io, run_path, .{});
        defer out_file.close(io);
        var out_buf: [65536]u8 = undefined;
        var out_writer: Io.File.Writer = .init(out_file, io, &out_buf);
        const out = &out_writer.interface;

        for (0..chunk_n) |i| {
            const rec_idx = indices[i];
            try out.writeAll(chunk[rec_idx * record_size ..][0..record_size]);
        }
        try out_writer.flush();

        offset = end;
    }

    return runs;
}

fn mergeRuns(
    io: Io,
    allocator: std.mem.Allocator,
    runs: []const []const u8,
    output_path: []const u8,
    record_size: usize,
    max_fanout: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), []const u8, []const u8) bool,
) !void {
    if (runs.len == 0) {
        const out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
        out_file.close(io);
        return;
    }
    std.debug.assert(max_fanout >= 2);
    if (runs.len <= max_fanout) {
        return mergeRunGroup(io, allocator, runs, output_path, record_size, context, lessThan);
    }

    // Multi-pass merge: repeatedly merge groups of `max_fanout` runs until
    // the remaining set is small enough for the final merge.
    const staging_parent = std.fs.path.dirname(output_path) orelse ".";
    var current: []const []const u8 = runs;
    var current_owned = false;
    defer if (current_owned) {
        for (current) |p| {
            Io.Dir.cwd().deleteFile(io, p) catch {};
            allocator.free(p);
        }
        allocator.free(current);
    };

    var pass: usize = 0;
    while (current.len > max_fanout) : (pass += 1) {
        const n_groups = (current.len + max_fanout - 1) / max_fanout;
        const next = try allocator.alloc([]const u8, n_groups);
        @memset(next, "");
        errdefer {
            for (next) |p| {
                if (p.len != 0) {
                    Io.Dir.cwd().deleteFile(io, p) catch {};
                    allocator.free(p);
                }
            }
            allocator.free(next);
        }

        for (0..n_groups) |g| {
            const start = g * max_fanout;
            const end = @min(start + max_fanout, current.len);
            const group = current[start..end];

            const out_path = try std.fmt.allocPrint(allocator, "{s}/.merge-{d}-{d}", .{ staging_parent, pass, g });
            next[g] = out_path;
            try mergeRunGroup(io, allocator, group, out_path, record_size, context, lessThan);
        }

        if (current_owned) {
            for (current) |p| {
                Io.Dir.cwd().deleteFile(io, p) catch {};
                allocator.free(p);
            }
            allocator.free(current);
        }
        current = next;
        current_owned = true;
    }

    try mergeRunGroup(io, allocator, current, output_path, record_size, context, lessThan);
}

const RunState = struct {
    data: []const u8,
    cursor: usize,
};

fn MergeHeapContext(comptime C: type, comptime lt: fn (C, []const u8, []const u8) bool) type {
    return struct {
        runs: []RunState,
        record_size: usize,
        context: C,

        pub fn less(self: @This(), a: usize, b: usize) bool {
            const run_a = self.runs[a];
            const run_b = self.runs[b];
            const rec_a = run_a.data[run_a.cursor..][0..self.record_size];
            const rec_b = run_b.data[run_b.cursor..][0..self.record_size];
            return lt(self.context, rec_a, rec_b);
        }
    };
}

fn mergeRunGroup(
    io: Io,
    allocator: std.mem.Allocator,
    run_paths: []const []const u8,
    output_path: []const u8,
    record_size: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), []const u8, []const u8) bool,
) !void {
    if (run_paths.len == 0) {
        const out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
        out_file.close(io);
        return;
    }

    const files = try allocator.alloc(Io.File, run_paths.len);
    var files_open: usize = 0;
    defer {
        for (files[0..files_open]) |*file| file.close(io);
        allocator.free(files);
    }

    const mmaps = try allocator.alloc(Io.File.MemoryMap, run_paths.len);
    var mmaps_created: usize = 0;
    defer {
        for (mmaps[0..mmaps_created]) |*mm| mm.destroy(io);
        allocator.free(mmaps);
    }

    const runs = try allocator.alloc(RunState, run_paths.len);
    defer allocator.free(runs);

    for (run_paths, 0..) |path, i| {
        files[i] = try Io.Dir.cwd().openFile(io, path, .{});
        files_open += 1;

        const len = try files[i].length(io);
        if (len % record_size != 0) {
            return error.InvalidRecordFile;
        }

        mmaps[i] = try Io.File.MemoryMap.create(io, files[i], .{
            .len = len,
            .protection = .{ .read = true, .write = false },
        });
        mmaps_created += 1;
        try mmaps[i].read(io);

        runs[i] = .{ .data = mmaps[i].memory, .cursor = 0 };
    }



    var out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buf: [65536]u8 = undefined;
    var out_writer: Io.File.Writer = .init(out_file, io, &out_buf);
    const out = &out_writer.interface;

    const C = @TypeOf(context);
    const HeapCtx = MergeHeapContext(C, lessThan);
    const heap_ctx = HeapCtx{
        .runs = runs,
        .record_size = record_size,
        .context = context,
    };
    var heap = BinaryHeap(usize, HeapCtx, HeapCtx.less).init(allocator, heap_ctx);
    defer heap.deinit(allocator);

    for (runs, 0..) |*run, i| {
        if (run.data.len > 0) {
            try heap.add(allocator, i);
        }
    }

    while (heap.len() > 0) {
        const idx = heap.removeMin();
        const run = &runs[idx];
        try out.writeAll(run.data[run.cursor..][0..record_size]);
        run.cursor += record_size;
        if (run.cursor < run.data.len) {
            try heap.add(allocator, idx);
        }
    }

    try out_writer.flush();
}

fn BinaryHeap(comptime T: type, comptime C: type, comptime lessThan: fn (C, T, T) bool) type {
    return struct {
        items: std.ArrayList(T),
        context: C,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, context: C) Self {
            _ = allocator;
            return .{
                .items = std.ArrayList(T).empty,
                .context = context,
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }

        fn len(self: Self) usize {
            return self.items.items.len;
        }

        fn add(self: *Self, allocator: std.mem.Allocator, item: T) !void {
            try self.items.append(allocator, item);
            self.siftUp(self.items.items.len - 1);
        }

        fn removeMin(self: *Self) T {
            const items = self.items.items;
            const root = items[0];
            const last = items[items.len - 1];
            self.items.items.len -= 1;
            if (self.items.items.len > 0) {
                self.items.items[0] = last;
                self.siftDown(0);
            }
            return root;
        }

        fn siftUp(self: *Self, start: usize) void {
            const items = self.items.items;
            const item = items[start];
            var i = start;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (lessThan(self.context, item, items[parent])) {
                    items[i] = items[parent];
                    i = parent;
                } else {
                    break;
                }
            }
            items[i] = item;
        }

        fn siftDown(self: *Self, start: usize) void {
            const items = self.items.items;
            const item = items[start];
            var i = start;
            while (true) {
                const left = i * 2 + 1;
                if (left >= items.len) break;
                const right = left + 1;
                var smallest = left;
                if (right < items.len and lessThan(self.context, items[right], items[left])) smallest = right;
                if (!lessThan(self.context, items[smallest], item)) break;
                items[i] = items[smallest];
                i = smallest;
            }
            items[i] = item;
        }
    };
}

fn lexLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn testSortCase(
    allocator: std.mem.Allocator,
    io: Io,
    record_size: usize,
    count: usize,
    budget_bytes: usize,
    max_fanout: usize,
) !void {
    const input_len = record_size * count;
    const input = try allocator.alloc(u8, input_len);
    defer allocator.free(input);

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rnd = prng.random();

    for (0..count) |i| {
        const rec = input[i * record_size ..][0..record_size];
        rnd.bytes(rec[0 .. record_size - @sizeOf(u32)]);
        std.mem.writeInt(u32, rec[record_size - @sizeOf(u32) ..][0..@sizeOf(u32)], @intCast(i), .little);
    }

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const input_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "input.bin" });
    defer allocator.free(input_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = input });

    const output_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "output.bin" });
    defer allocator.free(output_path);

    // Reference: sort records in memory using the same comparator.
    var reference = try allocator.dupe(u8, input);
    defer allocator.free(reference);

    const RefCtx = struct {
        buf: []u8,
        rs: usize,
        fn less(ctx: @This(), a: usize, b: usize) bool {
            const rec_a = ctx.buf[a * ctx.rs ..][0..ctx.rs];
            const rec_b = ctx.buf[b * ctx.rs ..][0..ctx.rs];
            return std.mem.order(u8, rec_a, rec_b) == .lt;
        }
    };

    const ref_indices = try allocator.alloc(usize, count);
    defer allocator.free(ref_indices);
    for (0..count) |i| ref_indices[i] = i;
    const ref_ctx = RefCtx{ .buf = reference, .rs = record_size };
    std.mem.sort(usize, ref_indices, ref_ctx, RefCtx.less);

    var reference_sorted = try allocator.alloc(u8, input_len);
    defer allocator.free(reference_sorted);
    for (0..count) |i| {
        const src = ref_indices[i] * record_size;
        const dst = i * record_size;
        @memcpy(reference_sorted[dst..][0..record_size], reference[src..][0..record_size]);
    }

    try sort(io, allocator, input_path, output_path, .{
        .record_size = record_size,
        .budget_bytes = budget_bytes,
        .max_fanout = max_fanout,
    }, {}, lexLess);

    const output = try Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(input_len + 1));
    defer allocator.free(output);

    try std.testing.expectEqual(input_len, output.len);
    try std.testing.expectEqualSlices(u8, reference_sorted, output);
}

test "external sort property test" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cases = .{
        .{ .rs = 8, .count = 0, .budget = 1024, .fanout = 64 },
        .{ .rs = 8, .count = 1, .budget = 1024, .fanout = 64 },
        .{ .rs = 8, .count = 100, .budget = 4096, .fanout = 64 },
        .{ .rs = 16, .count = 500, .budget = 4096, .fanout = 64 },
        .{ .rs = 32, .count = 200, .budget = 1024, .fanout = 64 },
        .{ .rs = 5, .count = 100, .budget = 3, .fanout = 64 },
        .{ .rs = 8, .count = 400, .budget = 1600, .fanout = 64 },
        .{ .rs = 8, .count = 401, .budget = 1600, .fanout = 64 },
        .{ .rs = 8, .count = 100, .budget = 80, .fanout = 2 },
    };

    inline for (cases) |case| {
        try testSortCase(allocator, io, case.rs, case.count, case.budget, case.fanout);
    }
}

test "external sort rejects misaligned input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const input_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "input.bin" });
    defer allocator.free(input_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = "1234567" });

    const output_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "output.bin" });
    defer allocator.free(output_path);

    const result = sort(io, allocator, input_path, output_path, .{
        .record_size = 4,
        .budget_bytes = 1024,
    }, {}, lexLess);

    try std.testing.expectError(error.InvalidRecordFile, result);
}

test "external sort small deterministic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const input_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "input.bin" });
    defer allocator.free(input_path);
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "output.bin" });
    defer allocator.free(output_path);

    var input: [32]u8 = undefined;
    for (0..8) |i| {
        input[i * 4 + 0] = @intCast(8 - i);
        input[i * 4 + 1] = 0;
        input[i * 4 + 2] = 0;
        input[i * 4 + 3] = @intCast(i);
    }

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = &input });

    try sort(io, allocator, input_path, output_path, .{
        .record_size = 4,
        .budget_bytes = 8,
    }, {}, lexLess);

    const output = try Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(100));
    defer allocator.free(output);

    var expected: [32]u8 = undefined;
    for (0..8) |i| {
        expected[i * 4 + 0] = @intCast(i + 1);
        expected[i * 4 + 1] = 0;
        expected[i * 4 + 2] = 0;
        expected[i * 4 + 3] = @intCast(7 - i);
    }
    try std.testing.expectEqualSlices(u8, &expected, output);
}

test "external sort removes staging directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const input_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "input.bin" });
    defer allocator.free(input_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = "\x03\x02\x01\x00\x07\x06\x05\x04" });

    const output_name = "output.bin";
    const output_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], output_name });
    defer allocator.free(output_path);

    try sort(io, allocator, input_path, output_path, .{
        .record_size = 4,
        .budget_bytes = 4,
    }, {}, lexLess);

    var dir = try Io.Dir.cwd().openDir(io, tmp_path_z[0..tmp_path_z.len], .{ .iterate = true });
    defer dir.close(io);
    var found_staging = false;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const prefix = try std.fmt.allocPrint(allocator, "{s}.extsort-", .{output_name});
        defer allocator.free(prefix);
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            found_staging = true;
            break;
        }
    }
    try std.testing.expect(!found_staging);
}

test "external sort removes multi-pass merge intermediates" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const record_size: usize = 16;
    const count: usize = 1000;
    const input = try allocator.alloc(u8, count * record_size);
    defer allocator.free(input);

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rnd = prng.random();
    for (0..count) |i| {
        const rec = input[i * record_size ..][0..record_size];
        rnd.bytes(rec[0 .. record_size - @sizeOf(u32)]);
        std.mem.writeInt(u32, rec[record_size - @sizeOf(u32) ..][0..@sizeOf(u32)], @intCast(i), .little);
    }

    const input_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "input.bin" });
    defer allocator.free(input_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = input });

    const output_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "output.bin" });
    defer allocator.free(output_path);

    try sort(io, allocator, input_path, output_path, .{
        .record_size = record_size,
        .budget_bytes = 64,
        .max_fanout = 2,
    }, {}, lexLess);

    const output = try Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(input.len + 1));
    defer allocator.free(output);
    try std.testing.expectEqual(input.len, output.len);

    var i: usize = 1;
    while (i < count) : (i += 1) {
        const a = output[(i - 1) * record_size ..][0..record_size];
        const b = output[i * record_size ..][0..record_size];
        try std.testing.expect(std.mem.order(u8, a, b) != .gt);
    }

    var dir = try Io.Dir.cwd().openDir(io, tmp_path_z[0..tmp_path_z.len], .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".merge-"));
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// Streaming merge implementation (memory-bounded alternative to mergeRuns)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-run state used by the streaming merger.
const StreamingRun = struct {
    file: Io.File,
    /// Current byte offset into the run file (advances by record_size each pop).
    offset: u64,
    /// Heap-owned buffer holding the current record for this run.
    buf: []u8,
};

fn StreamingHeapContext(comptime C: type, comptime lt: fn (C, []const u8, []const u8) bool) type {
    return struct {
        runs: []StreamingRun,
        context: C,

        pub fn less(self: @This(), a: usize, b: usize) bool {
            return lt(self.context, self.runs[a].buf, self.runs[b].buf);
        }
    };
}

/// Memory-bounded merge of a group of run files.
///
/// Instead of memory-mapping every file, each run is read one record at a time
/// using positional reads.  The total heap-allocated record storage is:
///
///   `run_paths.len × record_size`
///
/// which is always bounded by `fanout × record_size` ≤ `budget_bytes`.
fn mergeRunGroupStreaming(
    io: Io,
    allocator: std.mem.Allocator,
    run_paths: []const []const u8,
    output_path: []const u8,
    record_size: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), []const u8, []const u8) bool,
) !void {
    if (run_paths.len == 0) {
        const out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
        out_file.close(io);
        return;
    }

    const sr = try allocator.alloc(StreamingRun, run_paths.len);
    var sr_open: usize = 0;
    defer {
        for (sr[0..sr_open]) |*r| r.file.close(io);
        for (sr) |r| allocator.free(r.buf);
        allocator.free(sr);
    }

    // Open each run and eagerly read its first record.
    for (run_paths, 0..) |path, i| {
        const buf = try allocator.alloc(u8, record_size);
        sr[i] = .{ .file = undefined, .offset = 0, .buf = buf };
        sr[i].file = try Io.Dir.cwd().openFile(io, path, .{});
        sr_open += 1;
    }

    var out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buf: [65536]u8 = undefined;
    var out_writer: Io.File.Writer = .init(out_file, io, &out_buf);
    const out = &out_writer.interface;

    const C = @TypeOf(context);
    const Ctx = StreamingHeapContext(C, lessThan);
    const heap_ctx = Ctx{ .runs = sr, .context = context };
    var heap = BinaryHeap(usize, Ctx, Ctx.less).init(allocator, heap_ctx);
    defer heap.deinit(allocator);

    // Prime the heap: push runs that have at least one record.
    for (sr, 0..) |*r, i| {
        const n = try r.file.readPositionalAll(io, r.buf, r.offset);
        if (n == record_size) {
            r.offset += record_size;
            try heap.add(allocator, i);
        }
        // If n < record_size the run file is empty – leave it out of the heap.
    }

    while (heap.len() > 0) {
        const idx = heap.removeMin();
        const r = &sr[idx];
        try out.writeAll(r.buf);
        // Advance and attempt to read the next record.
        const n = try r.file.readPositionalAll(io, r.buf, r.offset);
        if (n == record_size) {
            r.offset += record_size;
            try heap.add(allocator, idx);
        }
        // Otherwise this run is exhausted – leave it out of the heap.
    }

    try out_writer.flush();
}

/// Merge a collection of sorted run files using bounded streaming reads.
///
/// Operates the same as `mergeRuns` but calls `mergeRunGroupStreaming` instead
/// of `mergeRunGroup`, so the merge phase never memory-maps any file.
fn mergeRunsStreaming(
    io: Io,
    allocator: std.mem.Allocator,
    runs: []const []const u8,
    output_path: []const u8,
    record_size: usize,
    max_fanout: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), []const u8, []const u8) bool,
) !void {
    if (runs.len == 0) {
        const out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
        out_file.close(io);
        return;
    }
    std.debug.assert(max_fanout >= 2);
    if (runs.len <= max_fanout) {
        return mergeRunGroupStreaming(io, allocator, runs, output_path, record_size, context, lessThan);
    }

    const staging_parent = std.fs.path.dirname(output_path) orelse ".";
    var current: []const []const u8 = runs;
    var current_owned = false;
    defer if (current_owned) {
        for (current) |p| {
            Io.Dir.cwd().deleteFile(io, p) catch {};
            allocator.free(p);
        }
        allocator.free(current);
    };

    var pass: usize = 0;
    while (current.len > max_fanout) : (pass += 1) {
        const n_groups = (current.len + max_fanout - 1) / max_fanout;
        const next = try allocator.alloc([]const u8, n_groups);
        @memset(next, "");
        errdefer {
            for (next) |p| {
                if (p.len != 0) {
                    Io.Dir.cwd().deleteFile(io, p) catch {};
                    allocator.free(p);
                }
            }
            allocator.free(next);
        }

        for (0..n_groups) |g| {
            const start = g * max_fanout;
            const end = @min(start + max_fanout, current.len);
            const group = current[start..end];
            const out_path = try std.fmt.allocPrint(allocator, "{s}/.merge-stream-{d}-{d}", .{ staging_parent, pass, g });
            next[g] = out_path;
            try mergeRunGroupStreaming(io, allocator, group, out_path, record_size, context, lessThan);
        }

        if (current_owned) {
            for (current) |p| {
                Io.Dir.cwd().deleteFile(io, p) catch {};
                allocator.free(p);
            }
            allocator.free(current);
        }
        current = next;
        current_owned = true;
    }

    try mergeRunGroupStreaming(io, allocator, current, output_path, record_size, context, lessThan);
}

/// Sort the file at `input_path` and write the result to `output_path` using a
/// **memory-bounded streaming merge**.
///
/// Unlike `sort`, the merge phase never memory-maps run files.  Each run is
/// read one record at a time using positional reads, so the working-set for
/// the merge is at most `fanout × record_size` bytes regardless of run size.
///
/// ## Budget maths
///
/// The caller provides `budget_bytes` and optionally a `fanout` value.
///
/// If `fanout` is `null` the implementation derives the largest fanout that
/// keeps the merge within `budget_bytes`, but never less than 2:
///
/// ```
/// fanout = max(2, budget_bytes / record_size)
/// fanout = min(fanout, options.max_fanout)
/// ```
///
/// `options.max_fanout` is used as the hard upper bound on the derived fanout.
/// An explicit `fanout` value is currently used as-is and is *not* clamped to
/// `options.max_fanout`.
pub fn sortStreaming(
    io: Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    options: Options,
    /// Explicit fanout, or `null` to derive automatically from `budget_bytes`.
    fanout_opt: ?usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), []const u8, []const u8) bool,
) !void {
    std.debug.assert(options.record_size > 0);
    const record_size = options.record_size;

    const dir = Io.Dir.cwd();
    var input_file = try dir.openFile(io, input_path, .{});
    defer input_file.close(io);

    const input_len = try input_file.length(io);
    if (input_len % record_size != 0) return error.InvalidRecordFile;

    // Fast path: fits in memory.
    if (input_len <= options.budget_bytes) {
        return sortInMemory(io, allocator, input_file, input_len, output_path, record_size, context, lessThan);
    }

    // Derive fanout if not explicitly provided.  Fanout must be at least 2:
    // a value of 1 cannot reduce the number of runs during multi-pass merging
    // and would cause an infinite loop.
    const fanout: usize = fanout_opt orelse blk: {
        const derived = @max(options.budget_bytes / record_size, 2);
        break :blk @min(derived, options.max_fanout);
    };

    // Generate sorted runs (identical to original `sort`).
    const staging_dir = try createStagingDir(io, allocator, output_path);
    defer {
        dir.deleteTree(io, staging_dir) catch {};
        allocator.free(staging_dir);
    }

    var input_mm = try Io.File.MemoryMap.create(io, input_file, .{
        .len = input_len,
        .protection = .{ .read = true, .write = false },
    });
    defer input_mm.destroy(io);

    const runs = try generateRuns(io, allocator, input_mm.memory, staging_dir, record_size, options.budget_bytes, context, lessThan);
    defer {
        for (runs) |run_path| allocator.free(run_path);
        allocator.free(runs);
    }

    // Merge with bounded streaming reads.
    try mergeRunsStreaming(io, allocator, runs, output_path, record_size, fanout, context, lessThan);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests for sortStreaming
// ─────────────────────────────────────────────────────────────────────────────

fn testStreamingSortCase(
    allocator: std.mem.Allocator,
    io: Io,
    record_size: usize,
    count: usize,
    budget_bytes: usize,
    max_fanout: usize,
    fanout_opt: ?usize,
) !void {
    const input_len = record_size * count;
    const input = try allocator.alloc(u8, input_len);
    defer allocator.free(input);

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rnd = prng.random();
    for (0..count) |i| {
        const rec = input[i * record_size ..][0..record_size];
        rnd.bytes(rec[0 .. record_size - @sizeOf(u32)]);
        std.mem.writeInt(u32, rec[record_size - @sizeOf(u32) ..][0..@sizeOf(u32)], @intCast(i), .little);
    }

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const input_path = try std.fs.path.join(allocator, &.{ tmp_path, "input.bin" });
    defer allocator.free(input_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = input });

    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "output.bin" });
    defer allocator.free(output_path);

    // Reference: sort the same data using the original `sort`.
    const ref_output_path = try std.fs.path.join(allocator, &.{ tmp_path, "ref.bin" });
    defer allocator.free(ref_output_path);
    try sort(io, allocator, input_path, ref_output_path, .{
        .record_size = record_size,
        .budget_bytes = budget_bytes,
        .max_fanout = max_fanout,
    }, {}, lexLess);

    // Sort with the streaming implementation.
    try sortStreaming(io, allocator, input_path, output_path, .{
        .record_size = record_size,
        .budget_bytes = budget_bytes,
        .max_fanout = max_fanout,
    }, fanout_opt, {}, lexLess);

    const ref = try Io.Dir.cwd().readFileAlloc(io, ref_output_path, allocator, .limited(input_len + 1));
    defer allocator.free(ref);
    const got = try Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(input_len + 1));
    defer allocator.free(got);

    try std.testing.expectEqual(ref.len, got.len);
    try std.testing.expectEqualSlices(u8, ref, got);
}

test "streaming sort: property test" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cases = .{
        .{ .rs = 8, .count = 0,   .budget = 1024, .fanout = 64, .fo = null },
        .{ .rs = 8, .count = 1,   .budget = 1024, .fanout = 64, .fo = null },
        .{ .rs = 8, .count = 100, .budget = 4096, .fanout = 64, .fo = null },
        .{ .rs = 16, .count = 500, .budget = 4096, .fanout = 64, .fo = null },
        .{ .rs = 32, .count = 200, .budget = 1024, .fanout = 64, .fo = null },
        // Small budget forces many runs with a tiny fanout derived automatically.
        .{ .rs = 5,  .count = 100, .budget = 12,   .fanout = 64, .fo = null },
        .{ .rs = 8,  .count = 400, .budget = 1600, .fanout = 64, .fo = null },
        .{ .rs = 8,  .count = 401, .budget = 1600, .fanout = 64, .fo = null },
        // Explicit fanout = 2 forces multi-pass merge.
        .{ .rs = 8,  .count = 100, .budget = 80,   .fanout = 2,  .fo = @as(?usize, 2) },
    };

    inline for (cases) |c| {
        try testStreamingSortCase(allocator, io, c.rs, c.count, c.budget, c.fanout, c.fo);
    }
}

test "streaming sort: output matches original sort" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const record_size: usize = 16;
    const count: usize = 1000;
    const input = try allocator.alloc(u8, count * record_size);
    defer allocator.free(input);

    var prng = std.Random.DefaultPrng.init(0xabcdef01);
    const rnd = prng.random();
    for (0..count) |i| {
        const rec = input[i * record_size ..][0..record_size];
        rnd.bytes(rec[0 .. record_size - @sizeOf(u32)]);
        std.mem.writeInt(u32, rec[record_size - @sizeOf(u32) ..][0..@sizeOf(u32)], @intCast(i), .little);
    }

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const input_path = try std.fs.path.join(allocator, &.{ tmp_path, "input.bin" });
    defer allocator.free(input_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = input });

    const out_stream = try std.fs.path.join(allocator, &.{ tmp_path, "out_stream.bin" });
    defer allocator.free(out_stream);
    const out_mmap = try std.fs.path.join(allocator, &.{ tmp_path, "out_mmap.bin" });
    defer allocator.free(out_mmap);

    try sort(io, allocator, input_path, out_mmap, .{ .record_size = record_size, .budget_bytes = 64, .max_fanout = 2 }, {}, lexLess);
    try sortStreaming(io, allocator, input_path, out_stream, .{ .record_size = record_size, .budget_bytes = 64, .max_fanout = 2 }, 2, {}, lexLess);

    const got_mmap = try Io.Dir.cwd().readFileAlloc(io, out_mmap, allocator, .limited(input.len + 1));
    defer allocator.free(got_mmap);
    const got_stream = try Io.Dir.cwd().readFileAlloc(io, out_stream, allocator, .limited(input.len + 1));
    defer allocator.free(got_stream);

    try std.testing.expectEqualSlices(u8, got_mmap, got_stream);
}

test "streaming sort: rejects misaligned input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const input_path = try std.fs.path.join(allocator, &.{ tmp_path, "input.bin" });
    defer allocator.free(input_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = "1234567" });

    const output_path = try std.fs.path.join(allocator, &.{ tmp_path, "output.bin" });
    defer allocator.free(output_path);

    const result = sortStreaming(io, allocator, input_path, output_path, .{
        .record_size = 4,
        .budget_bytes = 1024,
    }, null, {}, lexLess);

    try std.testing.expectError(error.InvalidRecordFile, result);
}
