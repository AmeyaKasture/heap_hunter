//! Overview cache: aggregates and formatted output for the overview commands.
const std = @import("std");
const Io = std.Io;
const hprof = @import("hprof.zig");
const Regex = @import("Regex.zig");
const Analysis = @import("Analysis.zig");
const Manifest = @import("index/Manifest.zig");
const Scanner = @import("index/Scanner.zig");
const log = @import("log");

pub const HistogramOptions = struct {
    limit: usize = 15,
    view: bool = false,
    sort_by_instances: bool = false,
    match_pattern: ?[]const u8 = null,
    exclude_pattern: ?[]const u8 = null,
    min_bytes: u64 = 0,
    min_instances: u64 = 0,
};

pub const ClassOptions = struct {
    limit: usize = 15,
    view: bool = false,
    match_pattern: ?[]const u8 = null,
    exclude_pattern: ?[]const u8 = null,
    min_instance_size: u64 = 0,
};

pub fn validateHistogramOptions(options: HistogramOptions) Regex.Error!void {
    if (options.match_pattern) |pattern| try Regex.validate(pattern);
    if (options.exclude_pattern) |pattern| try Regex.validate(pattern);
}

pub fn validateClassOptions(options: ClassOptions) Regex.Error!void {
    if (options.match_pattern) |pattern| try Regex.validate(pattern);
    if (options.exclude_pattern) |pattern| try Regex.validate(pattern);
}

pub const HistogramEntry = struct {
    name: []const u8,
    count: u64,
    bytes: u64,
};

pub const ClassEntry = struct {
    name: []const u8,
    superclass: []const u8,
    instance_size: u64,
};

pub const FrameEntry = struct {
    class_name: []const u8,
    method: []const u8,
    source: []const u8,
    line_number: i32,
};

pub const ThreadEntry = struct {
    name: []const u8,
    state: []const u8,
    priority: i32,
    daemon: bool,
    tid: i64,
    virtual: bool,
    stack_frames: []const FrameEntry,
};

pub const Summary = struct {
    id_size: u32,
    timestamp: u64,
    total_objects: u64,
    total_arrays: u64,
    total_heap_bytes: u64,
    class_count: u32,
    thread_count: u32,
    classloader_count: u32,
};

pub const OverviewData = struct {
    allocator: std.mem.Allocator,
    summary: Summary,
    histogram: []const HistogramEntry,
    primitive_histogram: []const HistogramEntry,
    classes: []const ClassEntry,
    threads: []const ThreadEntry,

    pub fn deinit(self: *OverviewData) void {
        for (self.histogram) |entry| {
            self.allocator.free(entry.name);
        }
        self.allocator.free(self.histogram);

        for (self.primitive_histogram) |entry| {
            self.allocator.free(entry.name);
        }
        self.allocator.free(self.primitive_histogram);

        for (self.classes) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.superclass);
        }
        self.allocator.free(self.classes);

        for (self.threads) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.state);
            for (entry.stack_frames) |frame| {
                self.allocator.free(frame.class_name);
                self.allocator.free(frame.method);
                self.allocator.free(frame.source);
            }
            self.allocator.free(entry.stack_frames);
        }
        self.allocator.free(self.threads);
    }
};

pub fn buildFromDump(allocator: std.mem.Allocator, reader: *hprof.Reader) !OverviewData {
    var index = try Analysis.buildIndex(allocator, reader);
    defer index.deinit();
    return try buildFromAnalysis(allocator, &index);
}

pub const IndexBuildError = error{
    MissingIndexFile,
    CorruptIndexFile,
    OutOfMemory,
};

/// Build overview data from an existing index directory.
///
/// This is the fast, large-dump-safe path: `catalog.bin` is memory-mapped and
/// scanned once, `classes.bin` and `prim_histogram.bin` are small files, and
/// no source HPROF record decoding is performed. Thread details are not
/// currently stored in the index, so `threads` is left empty.
pub fn buildFromIndex(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    manifest: *const Manifest.IndexManifest,
) IndexBuildError!OverviewData {
    const catalog_path = try std.fs.path.join(allocator, &.{ index_dir, "catalog.bin" });
    defer allocator.free(catalog_path);
    const classes_path = try std.fs.path.join(allocator, &.{ index_dir, "classes.bin" });
    defer allocator.free(classes_path);
    const prim_histogram_path = try std.fs.path.join(allocator, &.{ index_dir, "prim_histogram.bin" });
    defer allocator.free(prim_histogram_path);

    const dir = Io.Dir.cwd();

    // Memory-map catalog.bin so huge dumps do not require a full heap copy.
    var catalog_file = dir.openFile(io, catalog_path, .{}) catch |err| {
        log.err("failed to open catalog.bin: {s}", .{@errorName(err)});
        return error.MissingIndexFile;
    };
    defer catalog_file.close(io);
    const catalog_len = catalog_file.length(io) catch |err| {
        log.err("failed to stat catalog.bin: {s}", .{@errorName(err)});
        return error.MissingIndexFile;
    };
    var catalog_mm = Io.File.MemoryMap.create(io, catalog_file, .{
        .len = catalog_len,
        .protection = .{ .read = true, .write = false },
        .populate = false,
    }) catch |err| {
        log.err("failed to map catalog.bin: {s}", .{@errorName(err)});
        return error.MissingIndexFile;
    };
    defer catalog_mm.destroy(io);
    const catalog_data = catalog_mm.memory;

    if (catalog_data.len % Scanner.catalog_row_size != 0) {
        log.err("catalog.bin size is not a multiple of row size", .{});
        return error.CorruptIndexFile;
    }

    // classes.bin is small relative to the dump; read it whole.
    const classes_data = dir.readFileAlloc(io, classes_path, allocator, .unlimited) catch |err| {
        log.err("failed to read classes.bin: {s}", .{@errorName(err)});
        return error.MissingIndexFile;
    };
    defer allocator.free(classes_data);

    var class_table = try parseClassesBin(allocator, classes_data);
    defer {
        allocator.free(class_table.ids);
        for (class_table.names) |name| allocator.free(name);
        allocator.free(class_table.names);
        allocator.free(class_table.super_ids);
        allocator.free(class_table.instance_sizes);
        class_table.index.deinit();
    }
    // prim_histogram.bin is tiny.
    const prim_data = dir.readFileAlloc(io, prim_histogram_path, allocator, .unlimited) catch |err| {
        log.err("failed to read prim_histogram.bin: {s}", .{@errorName(err)});
        return error.MissingIndexFile;
    };
    defer allocator.free(prim_data);

    const prim_histogram = try parsePrimHistogram(allocator, prim_data);
    defer allocator.free(prim_histogram);

    const HistValue = struct {
        count: u64,
        bytes: u64,
    };
    var hist_map = std.AutoHashMap(u64, HistValue).init(allocator);
    defer hist_map.deinit();

    var total_objects: u64 = 0;
    var total_arrays: u64 = 0;
    var total_heap_bytes: u64 = 0;

    const n_rows = catalog_data.len / Scanner.catalog_row_size;
    var row_idx: usize = 0;
    while (row_idx < n_rows) : (row_idx += 1) {
        const row = Scanner.readCatalogRow(catalog_data[row_idx * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size]) catch {
            return error.CorruptIndexFile;
        };

        switch (row.kind) {
            .instance, .object_array => {
                const result = try hist_map.getOrPut(row.class_raw_id);
                if (result.found_existing) {
                    result.value_ptr.*.count += 1;
                    result.value_ptr.*.bytes += row.shallow_size;
                } else {
                    result.value_ptr.* = .{ .count = 1, .bytes = row.shallow_size };
                }
                total_objects += 1;
                total_heap_bytes += row.shallow_size;
                if (row.kind == .object_array) {
                    total_arrays += 1;
                }
            },
            .primitive_array => {
                // Aggregated from prim_histogram.bin; just count summary totals.
                total_objects += 1;
                total_arrays += 1;
                total_heap_bytes += row.shallow_size;
            },
            .class => {},
        }
    }

    var hist_items = std.ArrayList(HistogramEntry).empty;
    defer {
        for (hist_items.items) |item| allocator.free(item.name);
        hist_items.deinit(allocator);
    }

    var it = hist_map.iterator();
    while (it.next()) |entry| {
        const name = try classNameForId(allocator, class_table, entry.key_ptr.*);
        errdefer allocator.free(name);
        try hist_items.append(allocator, .{
            .name = name,
            .count = entry.value_ptr.*.count,
            .bytes = entry.value_ptr.*.bytes,
        });
    }
    std.mem.sort(HistogramEntry, hist_items.items, {}, compareHistByBytes);

    var class_items = std.ArrayList(ClassEntry).empty;
    defer {
        for (class_items.items) |item| {
            allocator.free(item.name);
            allocator.free(item.superclass);
        }
        class_items.deinit(allocator);
    }

    for (class_table.ids, class_table.names, class_table.super_ids, class_table.instance_sizes) |_, name, super_id, size| {
        const class_name = try decodeDescriptor(allocator, name);
        errdefer allocator.free(class_name);
        const super_name = if (super_id == 0)
            try allocator.dupe(u8, "(none)")
        else
            try classNameForId(allocator, class_table, super_id);
        errdefer allocator.free(super_name);
        try class_items.append(allocator, .{
            .name = class_name,
            .superclass = super_name,
            .instance_size = size,
        });
    }
    std.mem.sort(ClassEntry, class_items.items, {}, compareClassBySize);

    const classloader_count = try computeClassloaderCount(allocator, class_table, catalog_data);

    return .{
        .allocator = allocator,
        .summary = .{
            .id_size = manifest.fingerprint.id_size,
            .timestamp = manifest.fingerprint.hprof_timestamp,
            .total_objects = total_objects,
            .total_arrays = total_arrays,
            .total_heap_bytes = total_heap_bytes,
            .class_count = @intCast(class_table.ids.len),
            .thread_count = 0,
            .classloader_count = classloader_count,
        },
        .histogram = try hist_items.toOwnedSlice(allocator),
        .primitive_histogram = prim_histogram,
        .classes = try class_items.toOwnedSlice(allocator),
        .threads = &.{},
    };
}

const ClassTable = struct {
    ids: []const u64,
    names: []const []const u8,
    super_ids: []const u64,
    instance_sizes: []const u32,
    index: std.AutoHashMap(u64, usize),
};

fn parseClassesBin(allocator: std.mem.Allocator, data: []const u8) IndexBuildError!ClassTable {
    var ids = std.ArrayList(u64).empty;
    defer ids.deinit(allocator);
    var names = std.ArrayList([]const u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var super_ids = std.ArrayList(u64).empty;
    defer super_ids.deinit(allocator);
    var instance_sizes = std.ArrayList(u32).empty;
    defer instance_sizes.deinit(allocator);

    var offset: usize = 0;
    while (offset < data.len) {
        if (offset + 24 > data.len) return error.CorruptIndexFile;
        const class_id = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;
        const super_class_id = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;
        const instance_size = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        const name_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        if (offset + name_len > data.len) return error.CorruptIndexFile;
        const raw_name = data[offset..][0..name_len];
        offset += name_len;
        const name = try allocator.dupe(u8, raw_name);
        errdefer allocator.free(name);
        try ids.append(allocator, class_id);
        try names.append(allocator, name);
        try super_ids.append(allocator, super_class_id);
        try instance_sizes.append(allocator, instance_size);
    }

    var index = std.AutoHashMap(u64, usize).init(allocator);
    errdefer index.deinit();
    for (ids.items, 0..) |id, i| {
        try index.put(id, i);
    }

    return .{
        .ids = try ids.toOwnedSlice(allocator),
        .names = try names.toOwnedSlice(allocator),
        .super_ids = try super_ids.toOwnedSlice(allocator),
        .instance_sizes = try instance_sizes.toOwnedSlice(allocator),
        .index = index,
    };
}

fn classNameForId(allocator: std.mem.Allocator, class_table: ClassTable, class_id: u64) IndexBuildError![]const u8 {
    if (class_table.index.get(class_id)) |idx| {
        const raw = class_table.names[idx];
        return try decodeDescriptor(allocator, raw);
    }
    return try std.fmt.allocPrint(allocator, "<unknown:0x{x}>", .{class_id});
}

/// Walk the superclass chain for `class_id` and return true if any class in the
/// chain has the raw name `java/lang/ClassLoader`. Results are cached per class.
fn isClassLoaderClass(
    class_table: ClassTable,
    class_id: u64,
    cache: *std.AutoHashMap(u64, bool),
) IndexBuildError!bool {
    if (cache.get(class_id)) |cached| return cached;

    var cur: u64 = class_id;
    while (cur != 0) {
        if (class_table.index.get(cur)) |idx| {
            if (std.mem.eql(u8, class_table.names[idx], "java/lang/ClassLoader")) {
                try cache.put(class_id, true);
                return true;
            }
            cur = class_table.super_ids[idx];
        } else {
            break;
        }
    }

    try cache.put(class_id, false);
    return false;
}

/// Count instance rows in `catalog_data` whose class is `java.lang.ClassLoader`
/// or a subclass. This mirrors `Analysis.isClassLoader` but uses only the
/// published index files.
fn computeClassloaderCount(
    allocator: std.mem.Allocator,
    class_table: ClassTable,
    catalog_data: []const u8,
) IndexBuildError!u32 {
    var cache = std.AutoHashMap(u64, bool).init(allocator);
    defer cache.deinit();

    var count: u32 = 0;
    const n_rows = catalog_data.len / Scanner.catalog_row_size;
    var row_idx: usize = 0;
    while (row_idx < n_rows) : (row_idx += 1) {
        const row = Scanner.readCatalogRow(catalog_data[row_idx * Scanner.catalog_row_size ..][0..Scanner.catalog_row_size]) catch {
            return error.CorruptIndexFile;
        };
        if (row.kind != .instance) continue;
        if (try isClassLoaderClass(class_table, row.class_raw_id, &cache)) {
            count += 1;
        }
    }
    return count;
}

fn parsePrimHistogram(allocator: std.mem.Allocator, data: []const u8) IndexBuildError![]HistogramEntry {
    if (data.len < 4) return &[_]HistogramEntry{};
    const n = std.mem.readInt(u32, data[0..4], .little);
    const expected_len = 4 + @as(usize, n) * Scanner.prim_histogram_entry_size;
    if (data.len != expected_len) return error.CorruptIndexFile;

    var items = std.ArrayList(HistogramEntry).empty;
    errdefer {
        for (items.items) |item| allocator.free(item.name);
        items.deinit(allocator);
    }

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const offset = 4 + @as(usize, i) * Scanner.prim_histogram_entry_size;
        const entry = Scanner.readPrimHistogramEntry(data[offset..][0..Scanner.prim_histogram_entry_size]) catch |err| switch (err) {
            error.InvalidPrimitiveType => return error.CorruptIndexFile,
        };
        const name = try std.fmt.allocPrint(allocator, "{s}[]", .{primitiveTypeName(entry.element_type) orelse "?"});
        errdefer allocator.free(name);
        try items.append(allocator, .{
            .name = name,
            .count = entry.count,
            .bytes = entry.bytes,
        });
    }
    std.mem.sort(HistogramEntry, items.items, {}, compareHistByBytes);
    return try items.toOwnedSlice(allocator);
}

fn buildFromAnalysis(allocator: std.mem.Allocator, index: *const Analysis.Index) !OverviewData {
    var hist_items = std.ArrayList(HistogramEntry).empty;
    defer hist_items.deinit(allocator);
    errdefer {
        for (hist_items.items) |item| allocator.free(item.name);
    }

    var class_it = index.histogram.iterator();
    while (class_it.next()) |entry| {
        const name = try index.decodeClassName(entry.key_ptr.*);
        errdefer allocator.free(name);
        try hist_items.append(allocator, .{
            .name = name,
            .count = entry.value_ptr.count,
            .bytes = entry.value_ptr.bytes,
        });
    }
    std.mem.sort(HistogramEntry, hist_items.items, {}, compareHistByBytes);

    var prim_hist_items = std.ArrayList(HistogramEntry).empty;
    defer prim_hist_items.deinit(allocator);
    errdefer {
        for (prim_hist_items.items) |item| allocator.free(item.name);
    }

    var prim_it = index.prim_histogram.iterator();
    while (prim_it.next()) |entry| {
        const name = try std.fmt.allocPrint(allocator, "{s}[]", .{primitiveTypeName(entry.key_ptr.*) orelse "?"});
        errdefer allocator.free(name);
        try prim_hist_items.append(allocator, .{
            .name = name,
            .count = entry.value_ptr.count,
            .bytes = entry.value_ptr.bytes,
        });
    }
    std.mem.sort(HistogramEntry, prim_hist_items.items, {}, compareHistByBytes);

    var class_items = std.ArrayList(ClassEntry).empty;
    defer class_items.deinit(allocator);
    errdefer {
        for (class_items.items) |item| {
            allocator.free(item.name);
            allocator.free(item.superclass);
        }
    }

    var it = index.loaded.iterator();
    while (it.next()) |entry| {
        const lc = entry.value_ptr.*;
        const class_name = try index.decodeClassNameById(lc.name_id);
        errdefer allocator.free(class_name);

        var superclass_name: []const u8 = try allocator.dupe(u8, "(none)");
        var instance_size: u64 = 0;
        if (index.classes.get(lc.class_id)) |ci| {
            instance_size = ci.instance_size;
            if (ci.super_class_id != 0) {
                if (index.decodeClassName(ci.super_class_id)) |sn| {
                    allocator.free(superclass_name);
                    superclass_name = sn;
                } else |_| {}
            }
        }

        try class_items.append(allocator, .{
            .name = class_name,
            .superclass = superclass_name,
            .instance_size = instance_size,
        });
    }
    std.mem.sort(ClassEntry, class_items.items, {}, compareClassBySize);

    var thread_items = std.ArrayList(ThreadEntry).empty;
    defer thread_items.deinit(allocator);
    errdefer {
        for (thread_items.items) |item| {
            allocator.free(item.name);
            allocator.free(item.state);
            for (item.stack_frames) |frame| {
                allocator.free(frame.class_name);
                allocator.free(frame.method);
                allocator.free(frame.source);
            }
            allocator.free(item.stack_frames);
        }
    }

    const ctx = index.threadContext();
    for (index.thread_index.threads.items) |t| {
        var frames = std.ArrayList(FrameEntry).empty;
        defer frames.deinit(allocator);
        errdefer {
            for (frames.items) |frame| {
                allocator.free(frame.class_name);
                allocator.free(frame.method);
                allocator.free(frame.source);
            }
        }

        if (index.thread_index.traces.get(t.stack_trace_serial)) |trace| {
            for (trace.frames) |fid| {
                if (index.thread_index.frames.get(fid)) |frame| {
                    const class_name = try index.thread_index.formatFrameClassName(ctx, frame.class_serial);
                    errdefer allocator.free(class_name);
                    const method = index.utf8.get(frame.method_name_id) orelse "<?>";
                    const source = index.utf8.get(frame.source_file_name_id) orelse "<?>";
                    const method_copy = try allocator.dupe(u8, method);
                    errdefer allocator.free(method_copy);
                    const source_copy = try allocator.dupe(u8, source);
                    errdefer allocator.free(source_copy);
                    try frames.append(allocator, .{
                        .class_name = class_name,
                        .method = method_copy,
                        .source = source_copy,
                        .line_number = frame.line_number,
                    });
                }
            }
        }

        const name = try allocator.dupe(u8, t.name);
        errdefer allocator.free(name);
        const state = try allocator.dupe(u8, t.state);
        errdefer allocator.free(state);
        try thread_items.append(allocator, .{
            .name = name,
            .state = state,
            .priority = t.priority,
            .daemon = t.daemon,
            .tid = t.tid,
            .virtual = t.virtual,
            .stack_frames = try frames.toOwnedSlice(allocator),
        });
    }

    return .{
        .allocator = allocator,
        .summary = .{
            .id_size = index.id_size,
            .timestamp = index.timestamp,
            .total_objects = index.total_objects,
            .total_arrays = index.total_arrays,
            .total_heap_bytes = index.total_heap_bytes,
            .class_count = index.classCount(),
            .thread_count = index.threadCount(),
            .classloader_count = index.classloaderCount(),
        },
        .histogram = try hist_items.toOwnedSlice(allocator),
        .primitive_histogram = try prim_hist_items.toOwnedSlice(allocator),
        .classes = try class_items.toOwnedSlice(allocator),
        .threads = try thread_items.toOwnedSlice(allocator),
    };
}

fn compareHistByBytes(_: void, a: HistogramEntry, b: HistogramEntry) bool {
    if (a.bytes != b.bytes) return a.bytes > b.bytes;
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn compareHistByInstances(_: void, a: HistogramEntry, b: HistogramEntry) bool {
    if (a.count != b.count) return a.count > b.count;
    if (a.bytes != b.bytes) return a.bytes > b.bytes;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn compareClassBySize(_: void, a: ClassEntry, b: ClassEntry) bool {
    if (a.instance_size != b.instance_size) return a.instance_size > b.instance_size;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn histogramItemMatches(name: []const u8, entry: HistogramEntry, options: HistogramOptions) bool {
    if (entry.bytes < options.min_bytes or entry.count < options.min_instances) return false;
    if (options.match_pattern) |pattern| {
        if (!Regex.matches(pattern, name)) return false;
    }
    if (options.exclude_pattern) |pattern| {
        if (Regex.matches(pattern, name)) return false;
    }
    return true;
}

fn classItemMatches(name: []const u8, instance_size: u64, options: ClassOptions) bool {
    if (instance_size < options.min_instance_size) return false;
    if (options.match_pattern) |pattern| {
        if (!Regex.matches(pattern, name)) return false;
    }
    if (options.exclude_pattern) |pattern| {
        if (Regex.matches(pattern, name)) return false;
    }
    return true;
}

pub fn printInfo(data: *const OverviewData, writer: anytype) !void {
    try writer.print("Header:\n", .{});
    try writer.print("  id_size:    {d} bytes\n", .{data.summary.id_size});
    try writer.print("  timestamp:  {d}\n", .{data.summary.timestamp});
    try writer.print("\n", .{});
    try writer.print("Summary:\n", .{});
    try writer.print("  total objects:  {d}\n", .{data.summary.total_objects});
    try writer.print("  classloaders:   {d}\n", .{data.summary.classloader_count});
    try writer.print("  classes:        {d}\n", .{data.summary.class_count});
    try writer.print("  arrays:         {d}\n", .{data.summary.total_arrays});
    try writer.print("  threads:        {d}\n", .{data.summary.thread_count});
    try writer.print("  heap bytes:     {d}\n", .{data.summary.total_heap_bytes});
}

pub fn printHistogram(data: *const OverviewData, writer: anytype, options: HistogramOptions) !void {
    var items = std.ArrayList(HistogramEntry).empty;
    defer {
        for (items.items) |item| {
            data.allocator.free(item.name);
        }
        items.deinit(data.allocator);
    }

    for (data.histogram) |entry| {
        const name = try data.allocator.dupe(u8, entry.name);
        errdefer data.allocator.free(name);
        if (histogramItemMatches(name, entry, options)) {
            try items.append(data.allocator, .{ .name = name, .count = entry.count, .bytes = entry.bytes });
        } else {
            data.allocator.free(name);
        }
    }

    for (data.primitive_histogram) |entry| {
        const name = try data.allocator.dupe(u8, entry.name);
        errdefer data.allocator.free(name);
        if (histogramItemMatches(name, entry, options)) {
            try items.append(data.allocator, .{ .name = name, .count = entry.count, .bytes = entry.bytes });
        } else {
            data.allocator.free(name);
        }
    }

    if (options.sort_by_instances) {
        std.mem.sort(HistogramEntry, items.items, {}, compareHistByInstances);
    } else {
        std.mem.sort(HistogramEntry, items.items, {}, compareHistByBytes);
    }

    const print_count = @min(items.items.len, options.limit);

    if (options.view) {
        try writer.print("{s: <48} {s: >16} {s: >20}\n", .{ "Class", "Instances", "Shallow Bytes" });
        try writer.print("{s}\n", .{"-" ** 86});
        for (items.items[0..print_count]) |item| {
            try writer.print("{s: <48} {d: >16} {d: >20}\n", .{ item.name, item.count, item.bytes });
        }
    } else {
        try writer.print("Class,Instances,Shallow Bytes\n", .{});
        for (items.items[0..print_count]) |item| {
            try writer.print("{s},{d},{d}\n", .{ item.name, item.count, item.bytes });
        }
    }
}

pub fn printClasses(data: *const OverviewData, writer: anytype, options: ClassOptions) !void {
    var items = std.ArrayList(ClassEntry).empty;
    defer {
        for (items.items) |item| {
            data.allocator.free(item.name);
            data.allocator.free(item.superclass);
        }
        items.deinit(data.allocator);
    }

    for (data.classes) |entry| {
        const name = try data.allocator.dupe(u8, entry.name);
        errdefer data.allocator.free(name);
        const superclass = try data.allocator.dupe(u8, entry.superclass);
        errdefer data.allocator.free(superclass);
        if (classItemMatches(name, entry.instance_size, options)) {
            try items.append(data.allocator, .{ .name = name, .superclass = superclass, .instance_size = entry.instance_size });
        } else {
            data.allocator.free(name);
            data.allocator.free(superclass);
        }
    }

    std.mem.sort(ClassEntry, items.items, {}, compareClassBySize);

    const print_count = @min(items.items.len, options.limit);

    if (options.view) {
        try writer.print("{s: <50} {s: <50} {s: >14}\n", .{ "Class", "Superclass", "Instance Size" });
        try writer.print("{s}\n", .{"-" ** 114});
        for (items.items[0..print_count]) |item| {
            try writer.print("{s: <50} {s: <50} {d: >14}\n", .{ item.name, item.superclass, item.instance_size });
        }
    } else {
        try writer.print("Class,Superclass,Instance Size\n", .{});
        for (items.items[0..print_count]) |item| {
            try writer.print("{s},{s},{d}\n", .{ item.name, item.superclass, item.instance_size });
        }
    }
}

pub fn printThreads(data: *const OverviewData, writer: anytype) !void {
    for (data.threads) |t| {
        if (t.virtual) {
            try writer.print("Thread: {s} (virtual)\n", .{t.name});
        } else {
            try writer.print("Thread: {s}\n", .{t.name});
        }
        try writer.print("  State:    {s}\n", .{t.state});
        try writer.print("  Priority: {d}\n", .{t.priority});
        try writer.print("  Daemon:   {s}\n", .{if (t.daemon) "true" else "false"});
        try writer.print("  TID:      {d}\n", .{t.tid});

        if (t.stack_frames.len > 0) {
            try writer.print("  Stack trace:\n", .{});
            for (t.stack_frames) |frame| {
                if (frame.line_number < 0) {
                    try writer.print("    at {s}.{s}({s})\n", .{ frame.class_name, frame.method, frame.source });
                } else {
                    try writer.print("    at {s}.{s}({s}:{d})\n", .{ frame.class_name, frame.method, frame.source, frame.line_number });
                }
            }
        } else {
            try writer.print("  Stack trace: <none>\n", .{});
        }
        try writer.print("\n", .{});
    }
}

fn decodeDescriptor(allocator: std.mem.Allocator, descriptor: []const u8) std.mem.Allocator.Error![]const u8 {
    var dims: usize = 0;
    var i: usize = 0;
    while (i < descriptor.len and descriptor[i] == '[') : (i += 1) {
        dims += 1;
    }

    if (dims == 0) {
        return try replaceSlashes(allocator, descriptor);
    }

    const base = descriptor[i..];
    const base_name = if (base.len > 1 and base[0] == 'L')
        base[1 .. base.len - 1]
    else
        primitiveTypeCodeName(base[0]) orelse base;

    const result_len = base_name.len + dims * 2;
    var result = try allocator.alloc(u8, result_len);
    @memcpy(result[0..base_name.len], base_name);
    var j: usize = base_name.len;
    for (0..dims) |_| {
        result[j] = '[';
        result[j + 1] = ']';
        j += 2;
    }
    for (result, 0..) |c, k| {
        if (c == '/') result[k] = '.';
    }
    return result;
}

fn replaceSlashes(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    var result = try allocator.dupe(u8, s);
    for (result, 0..) |c, i| {
        if (c == '/') result[i] = '.';
    }
    return result;
}

fn primitiveTypeCodeName(code: u8) ?[]const u8 {
    return switch (code) {
        'B' => "byte",
        'C' => "char",
        'D' => "double",
        'F' => "float",
        'I' => "int",
        'J' => "long",
        'S' => "short",
        'Z' => "boolean",
        else => null,
    };
}

fn primitiveTypeName(ty: hprof.PrimitiveType) ?[]const u8 {
    return switch (ty) {
        .boolean => "boolean",
        .char => "char",
        .double => "double",
        .float => "float",
        .byte => "byte",
        .short => "short",
        .int => "int",
        .long => "long",
        else => null,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Binary cache format
// ─────────────────────────────────────────────────────────────────────────────

const magic = "POVW";
const version: u32 = 1;

const Error = error{
    CacheCorrupt,
    CacheVersionMismatch,
    CacheFingerprintMismatch,
    CacheMissing,
    OutOfMemory,
};

pub fn cachePath(allocator: std.mem.Allocator, index_dir: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ index_dir, "overview.bin" });
}

pub fn writeCache(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    fingerprint: *const Manifest.Fingerprint,
    data: *const OverviewData,
) !void {
    const path = try cachePath(allocator, index_dir);
    defer allocator.free(path);

    const dir = Io.Dir.cwd();
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);

    var buf: [65536]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buf);
    const writer = &file_writer.interface;

    try writer.writeAll(magic);
    try writeU32(writer, version);

    try writeString(writer, fingerprint.hash_algorithm);
    try writeString(writer, fingerprint.hash_value);
    try writeU64(writer, fingerprint.file_length);
    try writeU64(writer, fingerprint.hprof_timestamp);
    try writeU32(writer, fingerprint.id_size);

    try writeSummary(writer, data.summary);
    try writeHistogram(writer, data.histogram);
    try writeHistogram(writer, data.primitive_histogram);
    try writeClasses(writer, data.classes);
    try writeThreads(writer, data.threads);

    try file_writer.flush();
}

pub fn readCache(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    fingerprint: *const Manifest.Fingerprint,
) !OverviewData {
    const path = try cachePath(allocator, index_dir);
    defer allocator.free(path);

    const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.CacheMissing,
        else => return err,
    };
    defer allocator.free(data);

    var cursor = CacheCursor.init(data);

    const file_magic = try cursor.readBytes(4);
    if (!std.mem.eql(u8, file_magic, magic)) return error.CacheCorrupt;

    const file_version = try cursor.readU32();
    if (file_version != version) return error.CacheVersionMismatch;

    const hash_algorithm = try cursor.readString(allocator);
    defer allocator.free(hash_algorithm);
    const hash_value = try cursor.readString(allocator);
    defer allocator.free(hash_value);
    const file_length = try cursor.readU64();
    const hprof_timestamp = try cursor.readU64();
    const id_size = try cursor.readU32();

    if (!std.mem.eql(u8, hash_algorithm, fingerprint.hash_algorithm) or
        !std.mem.eql(u8, hash_value, fingerprint.hash_value) or
        file_length != fingerprint.file_length or
        hprof_timestamp != fingerprint.hprof_timestamp or
        id_size != fingerprint.id_size)
    {
        return error.CacheFingerprintMismatch;
    }

    const summary = try cursor.readSummary();
    const histogram = try cursor.readHistogram(allocator);
    const primitive_histogram = try cursor.readHistogram(allocator);
    const classes = try cursor.readClasses(allocator);
    const threads = try cursor.readThreads(allocator);

    if (!cursor.isEmpty()) return error.CacheCorrupt;

    return .{
        .allocator = allocator,
        .summary = summary,
        .histogram = histogram,
        .primitive_histogram = primitive_histogram,
        .classes = classes,
        .threads = threads,
    };
}

fn writeSummary(writer: *Io.Writer, summary: Summary) !void {
    try writeU32(writer, summary.id_size);
    try writeU64(writer, summary.timestamp);
    try writeU64(writer, summary.total_objects);
    try writeU64(writer, summary.total_arrays);
    try writeU64(writer, summary.total_heap_bytes);
    try writeU32(writer, summary.class_count);
    try writeU32(writer, summary.thread_count);
    try writeU32(writer, summary.classloader_count);
}

fn writeHistogram(writer: *Io.Writer, entries: []const HistogramEntry) !void {
    try writeU32(writer, @intCast(entries.len));
    for (entries) |entry| {
        try writeString(writer, entry.name);
        try writeU64(writer, entry.count);
        try writeU64(writer, entry.bytes);
    }
}

fn writeClasses(writer: *Io.Writer, entries: []const ClassEntry) !void {
    try writeU32(writer, @intCast(entries.len));
    for (entries) |entry| {
        try writeString(writer, entry.name);
        try writeString(writer, entry.superclass);
        try writeU64(writer, entry.instance_size);
    }
}

fn writeThreads(writer: *Io.Writer, entries: []const ThreadEntry) !void {
    try writeU32(writer, @intCast(entries.len));
    for (entries) |entry| {
        try writeString(writer, entry.name);
        try writeString(writer, entry.state);
        try writeI32(writer, entry.priority);
        try writeU8(writer, if (entry.daemon) 1 else 0);
        try writeI64(writer, entry.tid);
        try writeU8(writer, if (entry.virtual) 1 else 0);
        try writeU32(writer, @intCast(entry.stack_frames.len));
        for (entry.stack_frames) |frame| {
            try writeString(writer, frame.class_name);
            try writeString(writer, frame.method);
            try writeString(writer, frame.source);
            try writeI32(writer, frame.line_number);
        }
    }
}

fn writeU8(writer: *Io.Writer, value: u8) !void {
    var buf = [1]u8{value};
    try writer.writeAll(&buf);
}

fn writeU32(writer: *Io.Writer, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeU64(writer: *Io.Writer, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeI32(writer: *Io.Writer, value: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeI64(writer: *Io.Writer, value: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeString(writer: *Io.Writer, value: []const u8) !void {
    try writeU32(writer, @intCast(value.len));
    try writer.writeAll(value);
}

const CacheCursor = struct {
    buf: []const u8,
    pos: usize,

    fn init(buf: []const u8) CacheCursor {
        return .{ .buf = buf, .pos = 0 };
    }

    fn isEmpty(self: *const CacheCursor) bool {
        return self.pos >= self.buf.len;
    }

    fn remaining(self: *const CacheCursor) usize {
        return self.buf.len - self.pos;
    }

    fn need(self: *const CacheCursor, n: usize) Error!void {
        if (self.remaining() < n) return error.CacheCorrupt;
    }

    fn readBytes(self: *CacheCursor, n: usize) Error![]const u8 {
        try self.need(n);
        const result = self.buf[self.pos..][0..n];
        self.pos += n;
        return result;
    }

    fn readU8(self: *CacheCursor) Error!u8 {
        try self.need(1);
        const value = self.buf[self.pos];
        self.pos += 1;
        return value;
    }

    fn readU32(self: *CacheCursor) Error!u32 {
        try self.need(4);
        const value = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }

    fn readU64(self: *CacheCursor) Error!u64 {
        try self.need(8);
        const value = std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }

    fn readI32(self: *CacheCursor) Error!i32 {
        try self.need(4);
        const value = std.mem.readInt(i32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }

    fn readI64(self: *CacheCursor) Error!i64 {
        try self.need(8);
        const value = std.mem.readInt(i64, self.buf[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }

    fn readString(self: *CacheCursor, allocator: std.mem.Allocator) Error![]const u8 {
        const len = try self.readU32();
        const bytes = try self.readBytes(len);
        return try allocator.dupe(u8, bytes);
    }

    fn readSummary(self: *CacheCursor) Error!Summary {
        return .{
            .id_size = try self.readU32(),
            .timestamp = try self.readU64(),
            .total_objects = try self.readU64(),
            .total_arrays = try self.readU64(),
            .total_heap_bytes = try self.readU64(),
            .class_count = try self.readU32(),
            .thread_count = try self.readU32(),
            .classloader_count = try self.readU32(),
        };
    }

    fn readHistogram(self: *CacheCursor, allocator: std.mem.Allocator) Error![]HistogramEntry {
        const n = try self.readU32();
        var items = std.ArrayList(HistogramEntry).empty;
        errdefer {
            for (items.items) |item| allocator.free(item.name);
            items.deinit(allocator);
        }
        for (0..n) |_| {
            const name = try self.readString(allocator);
            errdefer allocator.free(name);
            const count = try self.readU64();
            const bytes = try self.readU64();
            try items.append(allocator, .{ .name = name, .count = count, .bytes = bytes });
        }
        return try items.toOwnedSlice(allocator);
    }

    fn readClasses(self: *CacheCursor, allocator: std.mem.Allocator) Error![]ClassEntry {
        const n = try self.readU32();
        var items = std.ArrayList(ClassEntry).empty;
        errdefer {
            for (items.items) |item| {
                allocator.free(item.name);
                allocator.free(item.superclass);
            }
            items.deinit(allocator);
        }
        for (0..n) |_| {
            const name = try self.readString(allocator);
            errdefer allocator.free(name);
            const superclass = try self.readString(allocator);
            errdefer allocator.free(superclass);
            const instance_size = try self.readU64();
            try items.append(allocator, .{ .name = name, .superclass = superclass, .instance_size = instance_size });
        }
        return try items.toOwnedSlice(allocator);
    }

    fn readThreads(self: *CacheCursor, allocator: std.mem.Allocator) Error![]ThreadEntry {
        const n = try self.readU32();
        var items = std.ArrayList(ThreadEntry).empty;
        errdefer {
            for (items.items) |item| {
                allocator.free(item.name);
                allocator.free(item.state);
                for (item.stack_frames) |frame| {
                    allocator.free(frame.class_name);
                    allocator.free(frame.method);
                    allocator.free(frame.source);
                }
                allocator.free(item.stack_frames);
            }
            items.deinit(allocator);
        }
        for (0..n) |_| {
            const name = try self.readString(allocator);
            errdefer allocator.free(name);
            const state = try self.readString(allocator);
            errdefer allocator.free(state);
            const priority = try self.readI32();
            const daemon = (try self.readU8()) != 0;
            const tid = try self.readI64();
            const virtual = (try self.readU8()) != 0;
            const frame_count = try self.readU32();
            var frames = std.ArrayList(FrameEntry).empty;
            errdefer {
                for (frames.items) |frame| {
                    allocator.free(frame.class_name);
                    allocator.free(frame.method);
                    allocator.free(frame.source);
                }
                frames.deinit(allocator);
            }
            for (0..frame_count) |_| {
                const class_name = try self.readString(allocator);
                errdefer allocator.free(class_name);
                const method = try self.readString(allocator);
                errdefer allocator.free(method);
                const source = try self.readString(allocator);
                errdefer allocator.free(source);
                const line_number = try self.readI32();
                try frames.append(allocator, .{
                    .class_name = class_name,
                    .method = method,
                    .source = source,
                    .line_number = line_number,
                });
            }
            try items.append(allocator, .{
                .name = name,
                .state = state,
                .priority = priority,
                .daemon = daemon,
                .tid = tid,
                .virtual = virtual,
                .stack_frames = try frames.toOwnedSlice(allocator),
            });
        }
        return try items.toOwnedSlice(allocator);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "buildFromDump matches Analysis output on synthetic index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const index_dir = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir);

    try Io.Dir.cwd().createDirPath(io, index_dir);

    var data = try makeTestOverview(allocator);
    defer data.deinit();

    const fingerprint = Manifest.Fingerprint{
        .file_length = 1234,
        .hprof_timestamp = 42,
        .id_size = 4,
        .hash_algorithm = "fnv1a64",
        .hash_value = "deadbeefdeadbeef",
        .source_mtime = 0,
    };

    try writeCache(allocator, io, index_dir, &fingerprint, &data);

    var read_data = try readCache(allocator, io, index_dir, &fingerprint);
    defer read_data.deinit();

    try std.testing.expectEqual(data.summary, read_data.summary);
    try std.testing.expectEqual(data.histogram.len, read_data.histogram.len);
    try std.testing.expectEqual(data.primitive_histogram.len, read_data.primitive_histogram.len);
    try std.testing.expectEqual(data.classes.len, read_data.classes.len);
    try std.testing.expectEqual(data.threads.len, read_data.threads.len);

    for (data.histogram, read_data.histogram) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqual(a.count, b.count);
        try std.testing.expectEqual(a.bytes, b.bytes);
    }

    for (data.classes, read_data.classes) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualStrings(a.superclass, b.superclass);
        try std.testing.expectEqual(a.instance_size, b.instance_size);
    }

    for (data.threads, read_data.threads) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqual(a.priority, b.priority);
        try std.testing.expectEqual(a.tid, b.tid);
        try std.testing.expectEqual(a.stack_frames.len, b.stack_frames.len);
    }
}

test "readCache rejects stale fingerprint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const index_dir = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir);

    try Io.Dir.cwd().createDirPath(io, index_dir);

    var data = try makeTestOverview(allocator);
    defer data.deinit();

    const fingerprint = Manifest.Fingerprint{
        .file_length = 1234,
        .hprof_timestamp = 42,
        .id_size = 4,
        .hash_algorithm = "fnv1a64",
        .hash_value = "deadbeefdeadbeef",
        .source_mtime = 0,
    };

    try writeCache(allocator, io, index_dir, &fingerprint, &data);

    const stale = Manifest.Fingerprint{
        .file_length = 1234,
        .hprof_timestamp = 43,
        .id_size = 4,
        .hash_algorithm = "fnv1a64",
        .hash_value = "deadbeefdeadbeef",
        .source_mtime = 0,
    };

    const result = readCache(allocator, io, index_dir, &stale);
    try std.testing.expectError(error.CacheFingerprintMismatch, result);
}

test "isClassLoaderClass detects ClassLoader subclasses" {
    const allocator = std.testing.allocator;

    const ids = try allocator.dupe(u64, &[_]u64{ 1, 2, 3, 4 });
    defer allocator.free(ids);

    const names = try allocator.alloc([]const u8, 4);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    names[0] = try allocator.dupe(u8, "java/lang/ClassLoader");
    names[1] = try allocator.dupe(u8, "com/example/MyLoader");
    names[2] = try allocator.dupe(u8, "java/lang/Object");
    names[3] = try allocator.dupe(u8, "com/example/NotALoader");

    const super_ids = try allocator.dupe(u64, &[_]u64{ 0, 1, 0, 3 });
    defer allocator.free(super_ids);

    const instance_sizes = try allocator.dupe(u32, &[_]u32{ 8, 16, 8, 8 });
    defer allocator.free(instance_sizes);

    var index = std.AutoHashMap(u64, usize).init(allocator);
    defer index.deinit();
    for (ids, 0..) |id, i| try index.put(id, i);

    const class_table: ClassTable = .{
        .ids = ids,
        .names = names,
        .super_ids = super_ids,
        .instance_sizes = instance_sizes,
        .index = index,
    };

    var cache = std.AutoHashMap(u64, bool).init(allocator);
    defer cache.deinit();

    try std.testing.expect(try isClassLoaderClass(class_table, 1, &cache));
    try std.testing.expect(try isClassLoaderClass(class_table, 2, &cache));
    try std.testing.expect(!try isClassLoaderClass(class_table, 3, &cache));
    try std.testing.expect(!try isClassLoaderClass(class_table, 4, &cache));
    try std.testing.expect(!try isClassLoaderClass(class_table, 0xdeadbeef, &cache));
}

test "computeClassloaderCount counts ClassLoader instances in catalog" {
    const allocator = std.testing.allocator;

    const ids = try allocator.dupe(u64, &[_]u64{ 1, 2, 3 });
    defer allocator.free(ids);

    const names = try allocator.alloc([]const u8, 3);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    names[0] = try allocator.dupe(u8, "java/lang/ClassLoader");
    names[1] = try allocator.dupe(u8, "com/example/MyLoader");
    names[2] = try allocator.dupe(u8, "java/lang/Object");

    const super_ids = try allocator.dupe(u64, &[_]u64{ 0, 1, 0 });
    defer allocator.free(super_ids);

    const instance_sizes = try allocator.dupe(u32, &[_]u32{ 8, 16, 8 });
    defer allocator.free(instance_sizes);

    var index = std.AutoHashMap(u64, usize).init(allocator);
    defer index.deinit();
    for (ids, 0..) |id, i| try index.put(id, i);

    const class_table: ClassTable = .{
        .ids = ids,
        .names = names,
        .super_ids = super_ids,
        .instance_sizes = instance_sizes,
        .index = index,
    };

    // Three instance rows: one ClassLoader, one subclass, one plain object.
    var catalog = try allocator.alloc(u8, 3 * Scanner.catalog_row_size);
    defer allocator.free(catalog);
    @memset(catalog, 0);

    const rows = [_]Scanner.CatalogRow{
        .{ .raw_id = 10, .source_offset = 0, .class_raw_id = 1, .shallow_size = 8, .kind = .instance },
        .{ .raw_id = 11, .source_offset = 0, .class_raw_id = 2, .shallow_size = 16, .kind = .instance },
        .{ .raw_id = 12, .source_offset = 0, .class_raw_id = 3, .shallow_size = 8, .kind = .instance },
    };
    for (rows, 0..) |row, i| {
        std.mem.writeInt(u64, catalog[i * Scanner.catalog_row_size ..][0..8], row.raw_id, .little);
        std.mem.writeInt(u64, catalog[i * Scanner.catalog_row_size ..][8..16], row.source_offset, .little);
        std.mem.writeInt(u64, catalog[i * Scanner.catalog_row_size ..][16..24], row.class_raw_id, .little);
        std.mem.writeInt(u32, catalog[i * Scanner.catalog_row_size ..][24..28], row.shallow_size, .little);
        catalog[i * Scanner.catalog_row_size + 28] = @intFromEnum(row.kind);
    }

    const count = try computeClassloaderCount(allocator, class_table, catalog);
    try std.testing.expectEqual(@as(u32, 2), count);
}

fn makeTestOverview(allocator: std.mem.Allocator) !OverviewData {
    const hist = try allocator.alloc(HistogramEntry, 2);
    hist[0] = .{ .name = try allocator.dupe(u8, "java.lang.Object"), .count = 10, .bytes = 80 };
    hist[1] = .{ .name = try allocator.dupe(u8, "java.lang.String"), .count = 5, .bytes = 120 };

    const prim_hist = try allocator.alloc(HistogramEntry, 1);
    prim_hist[0] = .{ .name = try allocator.dupe(u8, "char[]"), .count = 3, .bytes = 24 };

    const classes = try allocator.alloc(ClassEntry, 2);
    classes[0] = .{ .name = try allocator.dupe(u8, "java.lang.Object"), .superclass = try allocator.dupe(u8, "(none)"), .instance_size = 8 };
    classes[1] = .{ .name = try allocator.dupe(u8, "java.lang.String"), .superclass = try allocator.dupe(u8, "java.lang.Object"), .instance_size = 24 };

    const frames = try allocator.alloc(FrameEntry, 1);
    frames[0] = .{
        .class_name = try allocator.dupe(u8, "java.lang.Thread"),
        .method = try allocator.dupe(u8, "run"),
        .source = try allocator.dupe(u8, "Thread.java"),
        .line_number = 42,
    };

    const threads = try allocator.alloc(ThreadEntry, 1);
    threads[0] = .{
        .name = try allocator.dupe(u8, "main"),
        .state = try allocator.dupe(u8, "RUNNABLE"),
        .priority = 5,
        .daemon = false,
        .tid = 1,
        .virtual = false,
        .stack_frames = frames,
    };

    return .{
        .allocator = allocator,
        .summary = .{
            .id_size = 4,
            .timestamp = 123456789,
            .total_objects = 20,
            .total_arrays = 3,
            .total_heap_bytes = 224,
            .class_count = 2,
            .thread_count = 1,
            .classloader_count = 0,
        },
        .histogram = hist,
        .primitive_histogram = prim_hist,
        .classes = classes,
        .threads = threads,
    };
}
