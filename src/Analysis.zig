//! HPROF analysis and overview commands.
const std = @import("std");
const hprof = @import("hprof.zig");
const Regex = @import("Regex.zig");
const IndexTypes = @import("IndexTypes.zig");
const Threads = @import("Threads.zig");

pub const ClassInfo = IndexTypes.ClassInfo;
pub const LoadClassEntry = IndexTypes.LoadClassEntry;

pub const HistogramEntry = struct {
    count: u64,
    bytes: u64,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    id_size: u32,

    // String table: id -> UTF-8 bytes.
    utf8: std.AutoHashMap(hprof.Id, []const u8),
    // class object id -> class name id (from LOAD_CLASS).
    class_names: std.AutoHashMap(hprof.Id, hprof.Id),
    // class object id -> class dump metadata.
    classes: std.AutoHashMap(hprof.Id, IndexTypes.ClassInfo),
    // class serial -> load class entry.
    loaded: std.AutoHashMap(u32, IndexTypes.LoadClassEntry),
    // Heap-derived threads.
    thread_index: Threads.ThreadIndex,
    // class object id -> aggregate histogram.
    histogram: std.AutoHashMap(hprof.Id, HistogramEntry),
    // primitive type -> aggregate histogram for primitive arrays.
    prim_histogram: std.AutoHashMap(hprof.PrimitiveType, HistogramEntry),
    // Unique class loader ids encountered in class dumps.
    classloaders: std.AutoHashMap(hprof.Id, void),

    timestamp: u64,
    total_objects: u64,
    total_arrays: u64,
    total_heap_bytes: u64,
    total_classloaders: u32,
    class_loader_cache: std.AutoHashMap(hprof.Id, bool),

    pub fn init(allocator: std.mem.Allocator, id_size: u32, timestamp: u64) Index {
        return .{
            .allocator = allocator,
            .id_size = id_size,
            .timestamp = timestamp,
            .utf8 = std.AutoHashMap(hprof.Id, []const u8).init(allocator),
            .class_names = std.AutoHashMap(hprof.Id, hprof.Id).init(allocator),
            .classes = std.AutoHashMap(hprof.Id, IndexTypes.ClassInfo).init(allocator),
            .loaded = std.AutoHashMap(u32, IndexTypes.LoadClassEntry).init(allocator),
            .thread_index = Threads.ThreadIndex.init(allocator, id_size),
            .histogram = std.AutoHashMap(hprof.Id, HistogramEntry).init(allocator),
            .prim_histogram = std.AutoHashMap(hprof.PrimitiveType, HistogramEntry).init(allocator),
            .classloaders = std.AutoHashMap(hprof.Id, void).init(allocator),
            .class_loader_cache = std.AutoHashMap(hprof.Id, bool).init(allocator),
            .total_objects = 0,
            .total_arrays = 0,
            .total_heap_bytes = 0,
            .total_classloaders = 0,
        };
    }

    pub fn deinit(self: *Index) void {
        var utf8_it = self.utf8.iterator();
        while (utf8_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.utf8.deinit();
        self.class_names.deinit();
        self.classes.deinit();
        self.loaded.deinit();
        self.thread_index.deinit();
        self.histogram.deinit();
        self.prim_histogram.deinit();
        self.classloaders.deinit();
        self.class_loader_cache.deinit();
    }

    pub fn addUtf8(self: *Index, id: hprof.Id, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        const old = self.utf8.fetchPut(id, copy) catch |err| {
            self.allocator.free(copy);
            return err;
        };
        if (old) |kv| {
            self.allocator.free(kv.value);
        }
    }

    pub fn addTopLevelRecord(self: *Index, record: hprof.Record) !void {
        switch (record) {
            .utf8 => |u| {
                try self.addUtf8(u.id, u.bytes);
            },
            .load_class => |lc| {
                try self.loaded.put(lc.serial, .{
                    .class_id = lc.class_id,
                    .name_id = lc.name_id,
                });
                try self.class_names.put(lc.class_id, lc.name_id);
            },
            .unload_class => |uc| {
                if (self.loaded.fetchRemove(uc.serial)) |kv| {
                    _ = self.class_names.remove(kv.value.class_id);
                }
            },
            .frame => |frame| {
                try self.thread_index.addFrame(frame);
            },
            .trace => |trace| {
                try self.thread_index.addTrace(trace);
            },
            .start_thread => {},
            .heap_dump => |heap_reader| {
                var hr = heap_reader;
                while (try hr.next()) |heap_record| {
                    try self.addHeapRecord(heap_record);
                }
            },
            .heap_dump_segment => |heap_reader| {
                var hr = heap_reader;
                while (try hr.next()) |heap_record| {
                    try self.addHeapRecord(heap_record);
                }
            },
            else => {},
        }
    }

    fn isClassLoader(self: *Index, class_id: hprof.Id) bool {
        const cache_result = self.class_loader_cache.get(class_id);
        if (cache_result) |res| return res;

        var is_loader = false;
        var current_id = class_id;
        while (current_id != 0) {
            if (self.class_names.get(current_id)) |name_id| {
                if (self.utf8.get(name_id)) |name| {
                    if (std.mem.eql(u8, name, "java/lang/ClassLoader")) {
                        is_loader = true;
                        break;
                    }
                }
            }
            if (self.classes.get(current_id)) |ci| {
                current_id = ci.super_class_id;
            } else {
                break;
            }
        }

        self.class_loader_cache.put(class_id, is_loader) catch {};
        return is_loader;
    }

    pub fn addHeapRecord(self: *Index, heap_record: hprof.HeapRecord) !void {
        switch (heap_record) {
            .gc_class_dump => |cd| {
                try self.classes.put(cd.class_id, .{
                    .super_class_id = cd.super_class_id,
                    .instance_size = cd.instance_size,
                    .class_loader_id = cd.class_loader_id,
                    .instance_fields_raw = cd.instance_fields_raw,
                });
                try self.classloaders.put(cd.class_loader_id, {});
            },
            .gc_instance_dump => |id| {
                const size = id.bytes.len;
                try self.addHistogram(id.class_id, 1, size);
                self.total_objects += 1;
                self.total_heap_bytes += size;
                try self.thread_index.addInstance(id, self.threadContext());
                if (self.isClassLoader(id.class_id)) {
                    self.total_classloaders += 1;
                }
            },
            .gc_obj_array_dump => |oa| {
                const size = @as(usize, oa.element_count) * self.id_size;
                try self.addHistogram(oa.class_id, 1, size);
                self.total_objects += 1;
                self.total_arrays += 1;
                self.total_heap_bytes += size;
            },
            .gc_prim_array_dump => |pa| {
                const size = pa.bytes.len;
                try self.addPrimHistogram(pa.element_type, 1, size);
                self.total_objects += 1;
                self.total_arrays += 1;
                self.total_heap_bytes += size;
                if (pa.element_type == .char or pa.element_type == .byte) {
                    try self.thread_index.addPrimArray(pa);
                }
            },
            .gc_root_thread_object => |root| {
                try self.thread_index.addRoot(root.thread_object_id, root.thread_serial, root.stack_trace_serial);
            },
            else => {},
        }
    }

    pub fn threadContext(self: *const Index) Threads.Context {
        return .{
            .allocator = self.allocator,
            .id_size = self.id_size,
            .utf8 = &self.utf8,
            .class_names = &self.class_names,
            .classes = &self.classes,
            .loaded = &self.loaded,
        };
    }

    fn addHistogram(self: *Index, class_id: hprof.Id, count: u64, bytes: u64) !void {
        const result = try self.histogram.getOrPut(class_id);
        if (result.found_existing) {
            result.value_ptr.*.count += count;
            result.value_ptr.*.bytes += bytes;
        } else {
            result.value_ptr.* = .{ .count = count, .bytes = bytes };
        }
    }

    fn addPrimHistogram(self: *Index, element_type: hprof.PrimitiveType, count: u64, bytes: u64) !void {
        const result = try self.prim_histogram.getOrPut(element_type);
        if (result.found_existing) {
            result.value_ptr.*.count += count;
            result.value_ptr.*.bytes += bytes;
        } else {
            result.value_ptr.* = .{ .count = count, .bytes = bytes };
        }
    }

    pub fn classCount(self: *const Index) u32 {
        return @intCast(self.loaded.count());
    }

    pub fn threadCount(self: *const Index) u32 {
        return self.thread_index.threadCount();
    }

    pub fn classloaderCount(self: *const Index) u32 {
        return self.total_classloaders;
    }

    pub fn decodeClassName(self: *const Index, class_id: hprof.Id) std.mem.Allocator.Error![]const u8 {
        if (self.class_names.get(class_id)) |name_id| {
            return self.decodeClassNameById(name_id);
        }
        return try std.fmt.allocPrint(self.allocator, "<unknown:0x{x}>", .{class_id});
    }

    pub fn decodeClassNameById(self: *const Index, name_id: hprof.Id) std.mem.Allocator.Error![]const u8 {
        if (self.utf8.get(name_id)) |bytes| {
            return decodeDescriptor(self.allocator, bytes);
        }
        return try std.fmt.allocPrint(self.allocator, "<unknown:0x{x}>", .{name_id});
    }
};

pub fn buildIndex(allocator: std.mem.Allocator, reader: *hprof.Reader) !Index {
    var index = Index.init(allocator, reader.id_size, reader.timestamp);
    errdefer index.deinit();
    while (try reader.next()) |record| {
        try index.addTopLevelRecord(record);
    }
    try index.thread_index.finish();
    return index;
}

pub fn printInfo(index: *const Index, writer: anytype) !void {
    try writer.print("Header:\n", .{});
    try writer.print("  id_size:    {d} bytes\n", .{index.id_size});
    try writer.print("  timestamp:  {d}\n", .{index.timestamp});
    try writer.print("\n", .{});
    try writer.print("Summary:\n", .{});
    try writer.print("  total objects:  {d}\n", .{index.total_objects});
    try writer.print("  classloaders:   {d}\n", .{index.classloaderCount()});
    try writer.print("  classes:        {d}\n", .{index.classCount()});
    try writer.print("  arrays:         {d}\n", .{index.total_arrays});
    try writer.print("  threads:        {d}\n", .{index.threadCount()});
    try writer.print("  heap bytes:     {d}\n", .{index.total_heap_bytes});
}

const HistItem = struct {
    name: []const u8,
    count: u64,
    bytes: u64,
};

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

pub fn printHistogram(index: *const Index, writer: anytype, options: HistogramOptions) !void {
    var items = std.ArrayList(HistItem).empty;
    defer {
        for (items.items) |item| {
            index.allocator.free(item.name);
        }
        items.deinit(index.allocator);
    }

    var class_it = index.histogram.iterator();
    while (class_it.next()) |entry| {
        const class_id = entry.key_ptr.*;
        const he = entry.value_ptr.*;
        const name = try index.decodeClassName(class_id);
        if (histogramItemMatches(name, he, options)) {
            try items.append(index.allocator, .{ .name = name, .count = he.count, .bytes = he.bytes });
        } else {
            index.allocator.free(name);
        }
    }

    var prim_it = index.prim_histogram.iterator();
    while (prim_it.next()) |entry| {
        const element_type = entry.key_ptr.*;
        const he = entry.value_ptr.*;
        const name = try std.fmt.allocPrint(index.allocator, "{s}[]", .{primitiveTypeName(element_type) orelse "?"});
        if (histogramItemMatches(name, he, options)) {
            try items.append(index.allocator, .{ .name = name, .count = he.count, .bytes = he.bytes });
        } else {
            index.allocator.free(name);
        }
    }

    if (options.sort_by_instances) {
        std.mem.sort(HistItem, items.items, {}, compareHistByInstances);
    } else {
        std.mem.sort(HistItem, items.items, {}, compareHistByBytes);
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

fn compareHistByBytes(_: void, a: HistItem, b: HistItem) bool {
    if (a.bytes != b.bytes) {
        return a.bytes > b.bytes;
    }
    if (a.count != b.count) {
        return a.count > b.count;
    }
    return std.mem.lessThan(u8, a.name, b.name);
}

fn compareHistByInstances(_: void, a: HistItem, b: HistItem) bool {
    if (a.count != b.count) {
        return a.count > b.count;
    }
    if (a.bytes != b.bytes) {
        return a.bytes > b.bytes;
    }
    return std.mem.lessThan(u8, a.name, b.name);
}

const ClassItem = struct {
    name: []const u8,
    superclass: []const u8,
    instance_size: u64,
    superclass_owned: bool,
};

fn compareClassBySize(_: void, a: ClassItem, b: ClassItem) bool {
    if (a.instance_size != b.instance_size) {
        return a.instance_size > b.instance_size;
    }
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn printClasses(index: *const Index, writer: anytype, options: ClassOptions) !void {
    var items = std.ArrayList(ClassItem).empty;
    defer {
        for (items.items) |item| {
            index.allocator.free(item.name);
            if (item.superclass_owned) {
                index.allocator.free(item.superclass);
            }
        }
        items.deinit(index.allocator);
    }

    var it = index.loaded.iterator();
    while (it.next()) |entry| {
        const lc = entry.value_ptr.*;
        const class_name = try index.decodeClassNameById(lc.name_id);
        errdefer index.allocator.free(class_name);

        var superclass_name: []const u8 = "(none)";
        var superclass_owned = false;
        var instance_size: u64 = 0;
        if (index.classes.get(lc.class_id)) |ci| {
            instance_size = ci.instance_size;
        }

        if (!classItemMatches(class_name, instance_size, options)) {
            index.allocator.free(class_name);
            continue;
        }

        if (index.classes.get(lc.class_id)) |ci| {
            if (ci.super_class_id != 0) {
                if (index.decodeClassName(ci.super_class_id)) |sn| {
                    superclass_name = sn;
                    superclass_owned = true;
                } else |_| {}
            }
        }

        try items.append(index.allocator, .{
            .name = class_name,
            .superclass = superclass_name,
            .instance_size = instance_size,
            .superclass_owned = superclass_owned,
        });
    }

    std.mem.sort(ClassItem, items.items, {}, compareClassBySize);

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

pub fn printThreads(index: *const Index, writer: anytype) !void {
    try index.thread_index.print(writer, index.threadContext());
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

test "decodeDescriptor converts class and array descriptors" {
    const allocator = std.testing.allocator;
    {
        const s = try decodeDescriptor(allocator, "java/lang/Object");
        defer allocator.free(s);
        try std.testing.expectEqualStrings("java.lang.Object", s);
    }
    {
        const s = try decodeDescriptor(allocator, "[Ljava/lang/String;");
        defer allocator.free(s);
        try std.testing.expectEqualStrings("java.lang.String[]", s);
    }
    {
        const s = try decodeDescriptor(allocator, "[I");
        defer allocator.free(s);
        try std.testing.expectEqualStrings("int[]", s);
    }
    {
        const s = try decodeDescriptor(allocator, "[[B");
        defer allocator.free(s);
        try std.testing.expectEqualStrings("byte[][]", s);
    }
}

fn makeTestIndex(allocator: std.mem.Allocator) !Index {
    var index = Index.init(allocator, 4, 123456789);
    errdefer index.deinit();

    // UTF-8 strings.
    try index.addUtf8(1, "java/lang/Object");
    try index.addUtf8(2, "java/lang/String");
    try index.addUtf8(3, "[Ljava/lang/String;");
    try index.addUtf8(4, "java/lang/Thread");
    try index.addUtf8(5, "java/lang/Thread$FieldHolder");
    try index.addUtf8(10, "main");
    try index.addUtf8(11, "main-group");
    try index.addUtf8(12, "system");
    try index.addUtf8(20, "name");
    try index.addUtf8(21, "tid");
    try index.addUtf8(22, "holder");
    try index.addUtf8(23, "priority");
    try index.addUtf8(24, "daemon");
    try index.addUtf8(25, "threadStatus");
    try index.addUtf8(26, "value");
    try index.addUtf8(27, "coder");

    // Loaded classes.
    try index.addTopLevelRecord(.{ .load_class = .{
        .serial = 1,
        .class_id = 100,
        .stack_trace_serial = 0,
        .name_id = 1,
    } });
    try index.addTopLevelRecord(.{ .load_class = .{
        .serial = 2,
        .class_id = 200,
        .stack_trace_serial = 0,
        .name_id = 2,
    } });
    try index.addTopLevelRecord(.{ .load_class = .{
        .serial = 3,
        .class_id = 300,
        .stack_trace_serial = 0,
        .name_id = 3,
    } });
    try index.addTopLevelRecord(.{ .load_class = .{
        .serial = 4,
        .class_id = 400,
        .stack_trace_serial = 0,
        .name_id = 4,
    } });
    try index.addTopLevelRecord(.{ .load_class = .{
        .serial = 5,
        .class_id = 500,
        .stack_trace_serial = 0,
        .name_id = 5,
    } });

    // Class dumps.
    try index.addHeapRecord(.{ .gc_class_dump = .{
        .class_id = 100,
        .stack_trace_serial = 0,
        .super_class_id = 0,
        .class_loader_id = 0,
        .signers_id = 0,
        .protection_domain_id = 0,
        .reserved1 = 0,
        .reserved2 = 0,
        .instance_size = 8,
        .constant_pool_raw = &[_]u8{ 0, 0 },
        .static_fields_raw = &[_]u8{ 0, 0 },
        .instance_fields_raw = &[_]u8{ 0, 0 },
    } });
    // java.lang.String: value (object), coder (byte)
    try index.addHeapRecord(.{
        .gc_class_dump = .{
            .class_id = 200,
            .stack_trace_serial = 0,
            .super_class_id = 100,
            .class_loader_id = 0,
            .signers_id = 0,
            .protection_domain_id = 0,
            .reserved1 = 0,
            .reserved2 = 0,
            .instance_size = 24,
            .constant_pool_raw = &[_]u8{ 0, 0 },
            .static_fields_raw = &[_]u8{ 0, 0 },
            .instance_fields_raw = &[_]u8{
                0, 2, // 2 fields
                0, 0, 0, 26, @intFromEnum(hprof.PrimitiveType.object), // value
                0, 0, 0, 27, @intFromEnum(hprof.PrimitiveType.byte), // coder
            },
        },
    });
    try index.addHeapRecord(.{ .gc_class_dump = .{
        .class_id = 300,
        .stack_trace_serial = 0,
        .super_class_id = 0,
        .class_loader_id = 0,
        .signers_id = 0,
        .protection_domain_id = 0,
        .reserved1 = 0,
        .reserved2 = 0,
        .instance_size = 12,
        .constant_pool_raw = &[_]u8{ 0, 0 },
        .static_fields_raw = &[_]u8{ 0, 0 },
        .instance_fields_raw = &[_]u8{ 0, 0 },
    } });
    // java.lang.Thread: name (object), tid (long), holder (object)
    try index.addHeapRecord(.{
        .gc_class_dump = .{
            .class_id = 400,
            .stack_trace_serial = 0,
            .super_class_id = 100,
            .class_loader_id = 0,
            .signers_id = 0,
            .protection_domain_id = 0,
            .reserved1 = 0,
            .reserved2 = 0,
            .instance_size = 32,
            .constant_pool_raw = &[_]u8{ 0, 0 },
            .static_fields_raw = &[_]u8{ 0, 0 },
            .instance_fields_raw = &[_]u8{
                0, 3, // 3 fields
                0, 0, 0, 20, @intFromEnum(hprof.PrimitiveType.object), // name
                0, 0, 0, 21, @intFromEnum(hprof.PrimitiveType.long), // tid
                0, 0, 0, 22, @intFromEnum(hprof.PrimitiveType.object), // holder
            },
        },
    });
    // java.lang.Thread$FieldHolder: group, task, stackSize, priority, daemon, threadStatus
    try index.addHeapRecord(.{
        .gc_class_dump = .{
            .class_id = 500,
            .stack_trace_serial = 0,
            .super_class_id = 100,
            .class_loader_id = 0,
            .signers_id = 0,
            .protection_domain_id = 0,
            .reserved1 = 0,
            .reserved2 = 0,
            .instance_size = 32,
            .constant_pool_raw = &[_]u8{ 0, 0 },
            .static_fields_raw = &[_]u8{ 0, 0 },
            .instance_fields_raw = &[_]u8{
                0, 6, // 6 fields
                0, 0, 0, 20, @intFromEnum(hprof.PrimitiveType.object), // group (reuse name id)
                0, 0, 0, 20, @intFromEnum(hprof.PrimitiveType.object), // task
                0, 0, 0, 20, @intFromEnum(hprof.PrimitiveType.long), // stackSize
                0, 0, 0, 23, @intFromEnum(hprof.PrimitiveType.int), // priority
                0, 0, 0, 24, @intFromEnum(hprof.PrimitiveType.boolean), // daemon
                0, 0, 0, 25, @intFromEnum(hprof.PrimitiveType.int), // threadStatus
            },
        },
    });

    // Thread root.
    try index.addHeapRecord(.{ .gc_root_thread_object = .{
        .thread_object_id = 1001,
        .thread_serial = 1,
        .stack_trace_serial = 0,
    } });

    // Instances and arrays.
    try index.addHeapRecord(.{ .gc_instance_dump = .{
        .object_id = 1005,
        .stack_trace_serial = 0,
        .class_id = 100,
        .bytes = "aaaa",
    } });
    // java.lang.Thread instance: name=1002, tid=42, holder=1004
    var thread_bytes: [16]u8 = undefined;
    std.mem.writeInt(u32, thread_bytes[0..4], 1002, .big);
    std.mem.writeInt(i64, thread_bytes[4..12], 42, .big);
    std.mem.writeInt(u32, thread_bytes[12..16], 1004, .big);
    try index.addHeapRecord(.{ .gc_instance_dump = .{
        .object_id = 1001,
        .stack_trace_serial = 0,
        .class_id = 400,
        .bytes = &thread_bytes,
    } });
    // java.lang.String instance: value=1003, coder=0
    try index.addHeapRecord(.{
        .gc_instance_dump = .{
            .object_id = 1002,
            .stack_trace_serial = 0,
            .class_id = 200,
            .bytes = &[_]u8{ 0, 0, 0x03, 0xeb, 0 }, // value id 1003 (0x3eb) big-endian, coder 0
        },
    });
    // FieldHolder: group=0, task=0, stackSize=0, priority=5, daemon=false, threadStatus=RUNNABLE(0x4)
    var holder_bytes: [25]u8 = undefined;
    std.mem.writeInt(u32, holder_bytes[0..4], 0, .big);
    std.mem.writeInt(u32, holder_bytes[4..8], 0, .big);
    std.mem.writeInt(i64, holder_bytes[8..16], 0, .big);
    std.mem.writeInt(i32, holder_bytes[16..20], 5, .big);
    holder_bytes[20] = 0;
    std.mem.writeInt(i32, holder_bytes[21..25], 0x4, .big);
    try index.addHeapRecord(.{ .gc_instance_dump = .{
        .object_id = 1004,
        .stack_trace_serial = 0,
        .class_id = 500,
        .bytes = &holder_bytes,
    } });
    // char[] for "main".
    try index.addHeapRecord(.{ .gc_prim_array_dump = .{
        .array_id = 1003,
        .stack_trace_serial = 0,
        .element_type = .char,
        .element_count = 4,
        .bytes = &[_]u8{ 0, 'm', 0, 'a', 0, 'i', 0, 'n' },
    } });
    try index.addHeapRecord(.{ .gc_obj_array_dump = .{
        .array_id = 2001,
        .stack_trace_serial = 0,
        .element_count = 3,
        .class_id = 300,
        .elements_raw = "xxxxxxxxxxxx",
    } });
    try index.addHeapRecord(.{ .gc_prim_array_dump = .{
        .array_id = 2002,
        .stack_trace_serial = 0,
        .element_type = .int,
        .element_count = 5,
        .bytes = "xxxxxxxxxxxxxxxxxxxx",
    } });

    try index.thread_index.finish();
    return index;
}

test "info prints header and summary totals" {
    const allocator = std.testing.allocator;
    var index = try makeTestIndex(allocator);
    defer index.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try printInfo(&index, &buf);
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "id_size:    4 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "timestamp:  123456789") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "total objects:  7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "classloaders:   0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "classes:        5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "arrays:         3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "threads:        1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "heap bytes:     90") != null);
}

test "histogram prints class-level aggregates sorted by bytes" {
    const allocator = std.testing.allocator;
    var index = try makeTestIndex(allocator);
    defer index.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try printHistogram(&index, &buf, .{ .limit = 100 });
    const output = buf.items;

    // int[] has 20 bytes and should appear before java.lang.String[] (12 bytes).
    const int_array_pos = std.mem.indexOf(u8, output, "int[]").?;
    const string_array_pos = std.mem.indexOf(u8, output, "java.lang.String[]").?;
    try std.testing.expect(int_array_pos < string_array_pos);
    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.Object") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.String") != null);
}

test "histogram prints class-level aggregates sorted by instances" {
    const allocator = std.testing.allocator;
    var index = try makeTestIndex(allocator);
    defer index.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try printHistogram(&index, &buf, .{ .limit = 100, .sort_by_instances = true });
    const output = buf.items;

    const string_pos = std.mem.indexOf(u8, output, "\njava.lang.String,").?;
    const string_array_pos = std.mem.indexOf(u8, output, "\njava.lang.String[],").?;
    try std.testing.expect(string_array_pos < string_pos);
}

test "histogram filters rows before sorting and limiting" {
    const allocator = std.testing.allocator;
    var index = try makeTestIndex(allocator);
    defer index.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try printHistogram(&index, &buf, .{
        .limit = 100,
        .match_pattern = ".*\\[\\]$",
        .exclude_pattern = "String\\[\\]$",
        .min_bytes = 20,
    });
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "int[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.String[]") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.Object") == null);
}

test "classes prints loaded class names, superclasses and instance sizes" {
    const allocator = std.testing.allocator;
    var index = try makeTestIndex(allocator);
    defer index.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try printClasses(&index, &buf, .{ .limit = 100 });
    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.Object") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.String") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.String[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(none)") != null);
}

test "classes filters rows before sorting and limiting" {
    const allocator = std.testing.allocator;
    var index = try makeTestIndex(allocator);
    defer index.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try printClasses(&index, &buf, .{
        .limit = 100,
        .match_pattern = "^java\\.lang\\.",
        .exclude_pattern = "String\\[\\]$",
        .min_instance_size = 9,
    });
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.String,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "java.lang.String[]") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\njava.lang.Object,") == null);
}

test "threads prints heap-derived thread details" {
    const allocator = std.testing.allocator;
    var index = try makeTestIndex(allocator);
    defer index.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try printThreads(&index, &buf);
    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "Thread: main") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "State:    RUNNABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Priority: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Daemon:   false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "TID:      42") != null);
}

test "buildIndex scans a synthetic HPROF file" {
    const allocator = std.testing.allocator;
    const id_size: u32 = 4;
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    // Header.
    @memcpy(buf[pos .. pos + hprof.Header.magic.len], hprof.Header.magic);
    pos += hprof.Header.magic.len;
    buf[pos] = 0;
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], id_size, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;

    // UTF8 record for class name.
    buf[pos] = @intFromEnum(hprof.RecordTag.utf8);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;
    const name = "java/lang/Object";
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(id_size + name.len), .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .big);
    pos += 4;
    @memcpy(buf[pos .. pos + name.len], name);
    pos += name.len;

    // LOAD_CLASS record.
    buf[pos] = @intFromEnum(hprof.RecordTag.load_class);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 16, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 100, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .big);
    pos += 4;

    // HEAP_DUMP with class dump and instance dump.
    buf[pos] = @intFromEnum(hprof.RecordTag.heap_dump);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;
    const heap_body_start = pos;
    pos += 4;

    // GC_CLASS_DUMP for java.lang.Object.
    buf[pos] = @intFromEnum(hprof.HeapSubtag.gc_class_dump);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 100, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // super
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // loader
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // signers
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // protection domain
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // reserved1
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // reserved2
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 8, .big); // instance size
    pos += 4;
    std.mem.writeInt(u16, buf[pos..][0..2], 0, .big); // cp count
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], 0, .big); // static fields count
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], 0, .big); // instance fields count
    pos += 2;

    // GC_INSTANCE_DUMP.
    buf[pos] = @intFromEnum(hprof.HeapSubtag.gc_instance_dump);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], 1001, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 100, .big);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 4, .big);
    pos += 4;
    @memcpy(buf[pos .. pos + 4], "aaaa");
    pos += 4;

    const heap_body_len = pos - heap_body_start - 4;
    std.mem.writeInt(u32, buf[heap_body_start..][0..4], @intCast(heap_body_len), .big);

    var reader = try hprof.Reader.init(buf[0..pos]);
    var index = try buildIndex(allocator, &reader);
    defer index.deinit();

    try std.testing.expectEqual(@as(u32, 1), index.classCount());
    try std.testing.expectEqual(@as(u64, 1), index.total_objects);
    try std.testing.expectEqual(@as(u64, 4), index.total_heap_bytes);
}

