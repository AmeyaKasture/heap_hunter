//! Stage 2: sort the catalog by raw ID, deduplicate, and persist classes.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const Manifest = @import("Manifest.zig");
const Preflight = @import("Preflight.zig");
const Scanner = @import("Scanner.zig");
const ExtSort = @import("ExtSort.zig");

pub const catalog_row_size = Scanner.catalog_row_size;

pub const Result = struct {
    catalog_path: []const u8,
    n_objects: u64,

    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.catalog_path);
    }
};

const max_object_count = @as(u64, std.math.maxInt(u32)) - 1;

fn catalogLessThan(_: void, a: []const u8, b: []const u8) bool {
    const a_id = std.mem.readInt(u64, a[0..8], .little);
    const b_id = std.mem.readInt(u64, b[0..8], .little);
    return a_id < b_id;
}

/// Sort `catalog.unsorted` by raw ID, remove duplicate raw IDs (keeping the
/// first occurrence), and write `catalog.bin`. Returns the path to the sorted
/// catalog and the unique object count. Updates `diagnostics` with the number
/// of dropped duplicates.
pub fn sortAndDedupe(
    allocator: std.mem.Allocator,
    io: Io,
    job: *const Preflight.Job,
    unsorted_path: []const u8,
    diagnostics: *Manifest.Diagnostics,
) !Result {
    const sorted_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "catalog.sorted" });
    defer allocator.free(sorted_path);

    try ExtSort.sortStreaming(io, allocator, unsorted_path, sorted_path, .{
        .record_size = catalog_row_size,
        .budget_bytes = job.budget_bytes,
    }, null, {}, catalogLessThan);

    const catalog_path = try std.fs.path.join(allocator, &.{ job.staging_dir, "catalog.bin" });
    errdefer allocator.free(catalog_path);

    const dir = Io.Dir.cwd();
    var sorted_file = try dir.openFile(io, sorted_path, .{});
    defer sorted_file.close(io);

    const sorted_len = try sorted_file.length(io);
    if (sorted_len % catalog_row_size != 0) {
        return error.InvalidCatalogFile;
    }

    var sorted_mm = try Io.File.MemoryMap.create(io, sorted_file, .{
        .len = sorted_len,
        .protection = .{ .read = true, .write = false },
    });
    defer sorted_mm.destroy(io);

    var catalog_file = try dir.createFile(io, catalog_path, .{});
    defer catalog_file.close(io);
    var catalog_buf: [65536]u8 = undefined;
    var catalog_file_writer: Io.File.Writer = .init(catalog_file, io, &catalog_buf);
    const catalog_writer = &catalog_file_writer.interface;

    const n_records = sorted_len / catalog_row_size;
    var n_written: u64 = 0;
    var duplicate_count: u64 = 0;
    var last_id: u64 = 0;

    var i: usize = 0;
    while (i < n_records) : (i += 1) {
        const record = sorted_mm.memory[i * catalog_row_size ..][0..catalog_row_size];
        const raw_id = std.mem.readInt(u64, record[0..8], .little);
        if (i > 0 and raw_id == last_id) {
            duplicate_count += 1;
            continue;
        }
        last_id = raw_id;
        try catalog_writer.writeAll(record);
        n_written += 1;
    }

    try catalog_file_writer.flush();

    if (n_written >= max_object_count) {
        return error.TooManyObjects;
    }

    diagnostics.duplicate_object_ids = duplicate_count;

    return .{
        .catalog_path = catalog_path,
        .n_objects = n_written,
    };
}

const ClassRecord = struct {
    class_id: hprof.Id,
    super_class_id: hprof.Id,
    instance_size: u32,
    name: []const u8,

    fn less(_: void, a: ClassRecord, b: ClassRecord) bool {
        return a.class_id < b.class_id;
    }
};

/// Write `classes.bin` from the in-memory class table. Returns the path to the
/// written file. Records are sorted by `class_raw_id`.
pub fn writeClasses(
    allocator: std.mem.Allocator,
    io: Io,
    staging_dir: []const u8,
    class_table: *const Scanner.ClassTable,
) ![]const u8 {
    const classes_path = try std.fs.path.join(allocator, &.{ staging_dir, "classes.bin" });
    errdefer allocator.free(classes_path);

    var list = std.ArrayList(ClassRecord).empty;
    defer list.deinit(allocator);

    var it = class_table.classes.iterator();
    while (it.next()) |entry| {
        const class_id = entry.key_ptr.*;
        const class_entry = entry.value_ptr.*;
        const name = class_table.className(class_id) orelse "";
        try list.append(allocator, .{
            .class_id = class_id,
            .super_class_id = class_entry.super_class_id,
            .instance_size = class_entry.instance_size,
            .name = name,
        });
    }

    std.mem.sort(ClassRecord, list.items, {}, ClassRecord.less);

    const dir = Io.Dir.cwd();
    var classes_file = try dir.createFile(io, classes_path, .{});
    defer classes_file.close(io);
    var classes_buf: [65536]u8 = undefined;
    var classes_file_writer: Io.File.Writer = .init(classes_file, io, &classes_buf);
    const classes_writer = &classes_file_writer.interface;

    for (list.items) |rec| {
        var header: [24]u8 = undefined;
        std.mem.writeInt(u64, header[0..8], rec.class_id, .little);
        std.mem.writeInt(u64, header[8..16], rec.super_class_id, .little);
        std.mem.writeInt(u32, header[16..20], rec.instance_size, .little);
        std.mem.writeInt(u32, header[20..24], @intCast(rec.name.len), .little);
        try classes_writer.writeAll(&header);
        if (rec.name.len > 0) {
            try classes_writer.writeAll(rec.name);
        }
    }

    try classes_file_writer.flush();

    return classes_path;
}

/// Binary search a sorted `catalog.bin` byte slice for `raw_id`. Returns the
/// ordinal (row index) or `null` if not found.
pub fn ordinalForRawId(catalog_data: []const u8, raw_id: u64) ?u32 {
    if (catalog_data.len % catalog_row_size != 0) return null;
    const n = catalog_data.len / catalog_row_size;
    if (n == 0) return null;

    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const mid_id = std.mem.readInt(u64, catalog_data[mid * catalog_row_size ..][0..8], .little);
        if (mid_id < raw_id) {
            lo = mid + 1;
        } else if (mid_id > raw_id) {
            hi = mid;
        } else {
            return @intCast(mid);
        }
    }
    return null;
}

fn createTestJob(
    allocator: std.mem.Allocator,
    io: Io,
    source_data: []const u8,
    tmp_dir: []const u8,
) !Preflight.Job {
    const header = try hprof.Header.parse(source_data);
    const fingerprint = try Manifest.computeFingerprint(allocator, source_data, header, 0);
    const staging_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "staging" });
    try Io.Dir.cwd().createDirPath(io, staging_dir);
    return .{
        .source_path = "test.hprof",
        .index_dir = tmp_dir,
        .staging_dir = staging_dir,

        .budget_bytes = 1024 * 1024,
        .fingerprint = fingerprint,
        .header = header,
    };
}

test "sortAndDedupe removes duplicate raw IDs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.loadClass(1, 0x2000, 0x1000);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 8,
    });
    _ = try heap.instanceDump(0x3000, 0x2000, &[_]u8{0} ** 8);
    _ = try heap.instanceDump(0x3000, 0x2000, &[_]u8{0} ** 8);
    _ = try heap.instanceDump(0x4000, 0x2000, &[_]u8{0} ** 8);
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var scan_result = try Scanner.run(allocator, io, &job, bytes, null);
    defer scan_result.deinit(allocator);

    var diagnostics: Manifest.Diagnostics = .{};
    var result = try sortAndDedupe(allocator, io, &job, scan_result.catalog_path, &diagnostics);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 3), result.n_objects);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.duplicate_object_ids);

    const catalog_data = try Io.Dir.cwd().readFileAlloc(io, result.catalog_path, allocator, .limited(4096));
    defer allocator.free(catalog_data);

    try std.testing.expectEqual(@as(usize, 3 * catalog_row_size), catalog_data.len);

    const row0 = try Scanner.readCatalogRow(catalog_data[0..catalog_row_size]);
    const row1 = try Scanner.readCatalogRow(catalog_data[catalog_row_size..][0..catalog_row_size]);
    const row2 = try Scanner.readCatalogRow(catalog_data[2 * catalog_row_size ..][0..catalog_row_size]);

    try std.testing.expectEqual(@as(hprof.Id, 0x2000), row0.raw_id);
    try std.testing.expectEqual(@as(hprof.Id, 0x3000), row1.raw_id);
    try std.testing.expectEqual(@as(hprof.Id, 0x4000), row2.raw_id);
}

test "ordinalForRawId hit and miss" {
    var rows: [4][catalog_row_size]u8 = undefined;
    for (&rows, 0..) |*row, i| {
        const raw_id: u64 = @as(u64, @intCast(i * 2)) + 10; // 10, 12, 14, 16
        std.mem.writeInt(u64, row[0..8], raw_id, .little);
        @memset(row[8..], 0);
    }

    var buf: [4 * catalog_row_size]u8 = undefined;
    for (0..4) |i| {
        @memcpy(buf[i * catalog_row_size ..][0..catalog_row_size], &rows[i]);
    }

    try std.testing.expectEqual(@as(?u32, 0), ordinalForRawId(&buf, 10));
    try std.testing.expectEqual(@as(?u32, 2), ordinalForRawId(&buf, 14));
    try std.testing.expectEqual(@as(?u32, null), ordinalForRawId(&buf, 11));
    try std.testing.expectEqual(@as(?u32, null), ordinalForRawId(&buf, 100));
}

test "writeClasses emits sorted class records" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var b = @import("../tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "com/shop/User");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 16,
    });
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 8,
    });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    const job = try createTestJob(allocator, io, bytes, tmp_path_z[0..tmp_path_z.len]);
    defer job.deinit(allocator);

    var scan_result = try Scanner.run(allocator, io, &job, bytes, null);
    defer scan_result.deinit(allocator);

    const classes_path = try writeClasses(allocator, io, job.staging_dir, &scan_result.class_table);
    defer allocator.free(classes_path);

    const data = try Io.Dir.cwd().readFileAlloc(io, classes_path, allocator, .limited(4096));
    defer allocator.free(data);

    var offset: usize = 0;

    const class0 = std.mem.readInt(u64, data[offset..][0..8], .little);
    offset += 8;
    const super0 = std.mem.readInt(u64, data[offset..][0..8], .little);
    offset += 8;
    const size0 = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    const name_len0 = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    const name0 = data[offset..][0..name_len0];
    offset += name_len0;

    try std.testing.expectEqual(@as(hprof.Id, 0x2000), class0);
    try std.testing.expectEqual(@as(hprof.Id, 0), super0);
    try std.testing.expectEqual(@as(u32, 8), size0);
    try std.testing.expectEqual(@as(u32, 16), name_len0);
    try std.testing.expectEqualStrings("java/lang/Object", name0);

    const class1 = std.mem.readInt(u64, data[offset..][0..8], .little);
    offset += 8;
    const super1 = std.mem.readInt(u64, data[offset..][0..8], .little);
    offset += 8;
    const size1 = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    const name_len1 = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    const name1 = data[offset..][0..name_len1];
    offset += name_len1;

    try std.testing.expectEqual(@as(hprof.Id, 0x2001), class1);
    try std.testing.expectEqual(@as(hprof.Id, 0x2000), super1);
    try std.testing.expectEqual(@as(u32, 16), size1);
    try std.testing.expectEqual(@as(u32, 13), name_len1);
    try std.testing.expectEqualStrings("com/shop/User", name1);

    try std.testing.expectEqual(offset, data.len);
}

test "fixture catalog count stable after sort and dedupe" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const fixtures = .{
        "test_hprofs/heapforge.hprof",
        "test_hprofs/heapforge_classloaders.hprof",
        "test_hprofs/heapforge_threads.hprof",
    };

    inline for (fixtures) |fixture_path| {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(tmp_path_z);

        const source_data = try Io.Dir.cwd().readFileAlloc(io, fixture_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(source_data);

        var analysis_reader = try hprof.Reader.init(source_data);
        var analysis_index = try @import("../Analysis.zig").buildIndex(allocator, &analysis_reader);
        defer analysis_index.deinit();

        const job = try createTestJob(allocator, io, source_data, tmp_path_z[0..tmp_path_z.len]);
        defer job.deinit(allocator);

        var scan_result = try Scanner.run(allocator, io, &job, source_data, null);
        defer scan_result.deinit(allocator);

        var diagnostics: Manifest.Diagnostics = .{};
    var result = try sortAndDedupe(allocator, io, &job, scan_result.catalog_path, &diagnostics);
        defer result.deinit(allocator);

        const expected = analysis_index.total_objects + analysis_index.classes.count();
        try std.testing.expectEqual(expected, result.n_objects);
        try std.testing.expectEqual(@as(u64, 0), diagnostics.duplicate_object_ids);
    }
}
