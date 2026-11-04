//! MCP tool definitions and dispatch for hunt.
//!
//! Each tool maps to an existing hunt command. Tool handlers either invoke the
//! public command functions in `Commands.zig` or use the lower-level query
//! engine directly. All output is captured as a JSON string and returned to the
//! MCP server, which wraps it in MCP `text` content.
const std = @import("std");
const Io = std.Io;

const Config = @import("Config.zig").Config;
const Commands = @import("Commands.zig");
const Overview = @import("Overview.zig");
const Manifest = @import("index/Manifest.zig");
const IndexReader = @import("index/IndexReader.zig");
const ThreadQuery = @import("index/ThreadQuery.zig");
const Regex = @import("Regex.zig");
const Progress = @import("Progress.zig");

pub const ErrorInfo = struct {
    message: []const u8,
    error_type: []const u8,
    suggestion: ?[]const u8 = null,
};

pub const Result = union(enum) {
    success: []const u8,
    failure: ErrorInfo,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        switch (self) {
            .success => |s| allocator.free(s),
            .failure => {},
        }
    }
};

pub const ProgressPair = struct {
    callback: ?Progress.Callback = null,
    ctx: ?*anyopaque = null,
};

pub const DispatchOptions = struct {
    index_progress: ProgressPair = .{},
    overview_progress: ProgressPair = .{},
};

/// Tool metadata used for the `tools/list` MCP method. Each entry includes a
/// JSON Schema describing the accepted arguments.
pub const tool_definitions = .{
    .{
        .name = "analyze_heap_dump",
        .description = "Index a Java HPROF heap dump and build the overview cache. This is the first tool to call when working with a new dump.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .hprof_path = .{ .type = "string", .description = "Path to the .hprof file." },
                .index_dir = .{ .type = "string", .description = "Directory where the index will be written. Defaults to the config value or <base>/<stem>.idx/." },
                .sorting_budget_mb = .{ .type = "integer", .description = "Memory budget in megabytes for external sorting." },
                .force = .{ .type = "boolean", .description = "Rebuild the index even if a matching index already exists." },
                .no_progress = .{ .type = "boolean", .description = "Suppress progress notifications." },
            },
            .required = .{"hprof_path"},
        },
    },
    .{
        .name = "heap_info",
        .description = "Show HPROF header and a high-level summary of the dump (requires overview cache).",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the overview cache." },
            },
            .required = .{"index_dir"},
        },
    },
    .{
        .name = "heap_histogram",
        .description = "Return a class-level histogram of instance counts and shallow heap (requires overview cache).",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the overview cache." },
                .limit = .{ .type = "integer", .description = "Limit output to the top N rows.", .default = 15 },
                .sort_instances = .{ .type = "boolean", .description = "Sort by instance count descending instead of shallow bytes." },
                .match = .{ .type = "string", .description = "Include only class names matching the regex." },
                .exclude = .{ .type = "string", .description = "Omit class names matching the regex." },
                .min_bytes = .{ .type = "integer", .description = "Include only rows with at least n shallow bytes." },
                .min_instances = .{ .type = "integer", .description = "Include only rows with at least n instances." },
            },
            .required = .{"index_dir"},
        },
    },
    .{
        .name = "heap_classes",
        .description = "Return loaded class metadata with names, superclasses, and instance sizes (requires overview cache).",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the overview cache." },
                .limit = .{ .type = "integer", .description = "Limit output to the top N rows.", .default = 15 },
                .match = .{ .type = "string", .description = "Include only class names matching the regex." },
                .exclude = .{ .type = "string", .description = "Omit class names matching the regex." },
                .min_instance_size = .{ .type = "integer", .description = "Include only classes with at least n bytes per instance." },
            },
            .required = .{"index_dir"},
        },
    },
    .{
        .name = "find_objects",
        .description = "List object IDs whose class name matches a regex.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the heap index." },
                .class_regex = .{ .type = "string", .description = "Regular expression matching class names." },
                .limit = .{ .type = "integer", .description = "Maximum number of objects to return.", .default = 100 },
                .offset = .{ .type = "integer", .description = "Skip the first n matching objects.", .default = 0 },
                .reverse = .{ .type = "boolean", .description = "Return results in descending ordinal order." },
            },
            .required = .{ "index_dir", "class_regex" },
        },
    },
    .{
        .name = "sample_objects",
        .description = "Decode sample objects whose class name matches a regex.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the heap index." },
                .class_regex = .{ .type = "string", .description = "Regular expression matching class names." },
                .limit = .{ .type = "integer", .description = "Maximum number of objects to decode.", .default = 100 },
                .offset = .{ .type = "integer", .description = "Skip the first n matching objects.", .default = 0 },
                .reverse = .{ .type = "boolean", .description = "Decode results in descending ordinal order." },
            },
            .required = .{ "index_dir", "class_regex" },
        },
    },
    .{
        .name = "get_object",
        .description = "Decode a single object by its raw ID with typed field values (\"type\" + \"value\"); java.lang.String instances include their decoded \"string\" text, and char[]/byte[] arrays include a text \"preview\".",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the heap index." },
                .id = .{ .type = "string", .description = "Object ID, e.g. 0x3000." },
            },
            .required = .{ "index_dir", "id" },
        },
    },
    .{
        .name = "refs_from",
        .description = "List outgoing references from an object.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the heap index." },
                .id = .{ .type = "string", .description = "Source object ID." },
                .limit = .{ .type = "integer", .description = "Maximum number of references to return.", .default = 64 },
                .offset = .{ .type = "integer", .description = "Skip the first n references.", .default = 0 },
            },
            .required = .{ "index_dir", "id" },
        },
    },
    .{
        .name = "refs_to",
        .description = "List incoming references to an object.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the heap index." },
                .id = .{ .type = "string", .description = "Target object ID." },
                .limit = .{ .type = "integer", .description = "Maximum number of references to return.", .default = 64 },
                .offset = .{ .type = "integer", .description = "Skip the first n references.", .default = 0 },
            },
            .required = .{ "index_dir", "id" },
        },
    },
    .{
        .name = "list_threads",
        .description = "List threads with names, states, priorities, daemon flags, and stack traces decoded on demand from the dump.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the heap index." },
            },
            .required = .{"index_dir"},
        },
    },
    .{
        .name = "find_roots",
        .description = "Find the shortest path from an object to a GC root.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the heap index." },
                .id = .{ .type = "string", .description = "Object ID to trace." },
                .max_visited = .{ .type = "integer", .description = "Maximum nodes to visit during the search.", .default = 1_000_000 },
            },
            .required = .{ "index_dir", "id" },
        },
    },
    .{
        .name = "reference_tree",
        .description = "Perform a bounded reference tree expansion from an object.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .index_dir = .{ .type = "string", .description = "Directory containing the heap index." },
                .id = .{ .type = "string", .description = "Root object ID." },
                .direction = .{ .type = "string", .description = "Traverse outbound ('from') or inbound ('to') references.", .default = "from" },
                .depth = .{ .type = "integer", .description = "Maximum depth of the expansion.", .default = 4 },
                .max_nodes = .{ .type = "integer", .description = "Maximum nodes to include in the tree.", .default = 256 },
            },
            .required = .{ "index_dir", "id" },
        },
    },
};

/// Dispatch an MCP tool call to the appropriate handler.
pub fn dispatch(
    allocator: std.mem.Allocator,
    io: Io,
    config_load: *Config.LoadResult,
    name: []const u8,
    arguments: std.json.Value,
    options: DispatchOptions,
) !Result {
    if (std.mem.eql(u8, name, "analyze_heap_dump")) {
        return try analyzeHeapDump(allocator, io, config_load, arguments, options);
    } else if (std.mem.eql(u8, name, "heap_info")) {
        return try heapInfo(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "heap_histogram")) {
        return try heapHistogram(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "heap_classes")) {
        return try heapClasses(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "find_objects")) {
        return try findObjects(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "sample_objects")) {
        return try sampleObjects(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "get_object")) {
        return try getObject(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "refs_from")) {
        return try refsFrom(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "refs_to")) {
        return try refsTo(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "list_threads")) {
        return try listThreads(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "find_roots")) {
        return try findRoots(allocator, io, arguments);
    } else if (std.mem.eql(u8, name, "reference_tree")) {
        return try referenceTree(allocator, io, arguments);
    } else {
        return Result{ .failure = .{
            .message = "Unknown tool",
            .error_type = "UnknownTool",
            .suggestion = "Use tools/list to see available tools.",
        } };
    }
}

fn analyzeHeapDump(
    allocator: std.mem.Allocator,
    io: Io,
    config_load: *Config.LoadResult,
    arguments: std.json.Value,
    options: DispatchOptions,
) !Result {
    const hprof_path = getRequiredString(arguments, "hprof_path") orelse return Result{
        .failure = .{
            .message = "Missing required argument: hprof_path",
            .error_type = "InvalidArgument",
        },
    };

    const index_dir = getOptionalString(arguments, "index_dir");
    const sorting_budget_mb = getOptionalU32(arguments, "sorting_budget_mb");
    const force = getOptionalBool(arguments, "force");
    const no_progress = getOptionalBool(arguments, "no_progress");

    const stderr_file = Io.File.stderr();
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(stderr_file, io, &stderr_buf);
    defer stderr_writer.flush() catch {};
    const stderr = &stderr_writer.interface;

    var index_output = Io.Writer.Allocating.init(allocator);
    defer index_output.deinit();

    Commands.runIndexCommand(
        allocator,
        io,
        .{
            .hprof_path = hprof_path,
            .index_dir = index_dir,
            .sorting_budget_mb = sorting_budget_mb,
            .force = force orelse false,
            .no_progress = no_progress orelse false,
        },
        &index_output.writer,
        stderr,
        config_load.*,
        options.index_progress.callback,
        options.index_progress.ctx,
    ) catch |err| {
        return mapError(err, "Index stage failed");
    };

    // Always rebuild the overview cache so analyze_heap_dump is idempotent.
    var overview_output = Io.Writer.Allocating.init(allocator);
    defer overview_output.deinit();

    Commands.runOverviewCommand(
        allocator,
        io,
        .{
            .hprof_path = hprof_path,
            .index_dir = index_dir,
            .force = true,
            .no_progress = no_progress orelse false,
        },
        &overview_output.writer,
        stderr,
        config_load.*,
        options.overview_progress.callback,
        options.overview_progress.ctx,
    ) catch |err| {
        return mapError(err, "Overview stage failed");
    };

    const combined = try combineOutputs(
        allocator,
        index_output.writer.buffer[0..index_output.writer.end],
        overview_output.writer.buffer[0..overview_output.writer.end],
    );
    return Result{ .success = combined };
}

fn combineOutputs(allocator: std.mem.Allocator, index_json: []const u8, overview_json: []const u8) ![]const u8 {
    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;
    try writer.writeAll("{\"status\":\"complete\",\"index\":");
    try writer.writeAll(index_json);
    try writer.writeAll(",\"overview\":");
    try writer.writeAll(overview_json);
    try writer.writeAll("}");
    return try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]);
}

fn writeJsonString(writer: *Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 32) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
    try writer.writeByte('"');
}

fn heapInfo(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    const index_dir = getRequiredString(arguments, "index_dir") orelse return Result{
        .failure = .{
            .message = "Missing required argument: index_dir",
            .error_type = "InvalidArgument",
        },
    };

    var data = try loadOverviewData(allocator, io, index_dir);
    defer data.deinit();

    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;
    try writer.writeAll("{");
    try writer.print("\"id_size\":{d},", .{data.summary.id_size});
    try writer.print("\"timestamp\":{d},", .{data.summary.timestamp});
    try writer.print("\"total_objects\":{d},", .{data.summary.total_objects});
    try writer.print("\"total_arrays\":{d},", .{data.summary.total_arrays});
    try writer.print("\"total_heap_bytes\":{d},", .{data.summary.total_heap_bytes});
    try writer.print("\"class_count\":{d},", .{data.summary.class_count});
    try writer.print("\"thread_count\":{d},", .{data.summary.thread_count});
    try writer.print("\"classloader_count\":{d}", .{data.summary.classloader_count});
    try writer.writeAll("}");
    return Result{ .success = try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]) };
}

fn heapHistogram(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    const index_dir = getRequiredString(arguments, "index_dir") orelse return Result{
        .failure = .{
            .message = "Missing required argument: index_dir",
            .error_type = "InvalidArgument",
        },
    };

    var data = try loadOverviewData(allocator, io, index_dir);
    defer data.deinit();

    var options = Overview.HistogramOptions{};
    if (getOptionalU64(arguments, "limit")) |v| options.limit = @intCast(v);
    if (getOptionalBool(arguments, "sort_instances")) |v| options.sort_by_instances = v;
    if (getOptionalString(arguments, "match")) |v| options.match_pattern = v;
    if (getOptionalString(arguments, "exclude")) |v| options.exclude_pattern = v;
    if (getOptionalU64(arguments, "min_bytes")) |v| options.min_bytes = v;
    if (getOptionalU64(arguments, "min_instances")) |v| options.min_instances = v;

    if (options.match_pattern != null or options.exclude_pattern != null) {
        Overview.validateHistogramOptions(options) catch return Result{
            .failure = .{
                .message = "Invalid regular expression in match or exclude",
                .error_type = "InvalidArgument",
            },
        };
    }

    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;

    var filtered: std.ArrayList(Overview.HistogramEntry) = .empty;
    defer filtered.deinit(allocator);

    for (data.histogram) |entry| {
        if (histogramEntryMatches(entry.name, entry, options)) {
            try filtered.append(allocator, .{ .name = entry.name, .count = entry.count, .bytes = entry.bytes });
        }
    }
    for (data.primitive_histogram) |entry| {
        if (histogramEntryMatches(entry.name, entry, options)) {
            try filtered.append(allocator, .{ .name = entry.name, .count = entry.count, .bytes = entry.bytes });
        }
    }

    if (options.sort_by_instances) {
        std.mem.sort(Overview.HistogramEntry, filtered.items, {}, sortHistByInstances);
    } else {
        std.mem.sort(Overview.HistogramEntry, filtered.items, {}, sortHistByBytes);
    }

    try writer.writeAll("[");
    const count = @min(filtered.items.len, options.limit);
    for (filtered.items[0..count], 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"class\":");
        try writeJsonString(writer, entry.name);
        try writer.print(",\"instances\":{d},\"shallow_bytes\":{d}", .{ entry.count, entry.bytes });
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
    return Result{ .success = try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]) };
}

fn heapClasses(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    const index_dir = getRequiredString(arguments, "index_dir") orelse return Result{
        .failure = .{
            .message = "Missing required argument: index_dir",
            .error_type = "InvalidArgument",
        },
    };

    var data = try loadOverviewData(allocator, io, index_dir);
    defer data.deinit();

    var options = Overview.ClassOptions{};
    if (getOptionalU64(arguments, "limit")) |v| options.limit = @intCast(v);
    if (getOptionalString(arguments, "match")) |v| options.match_pattern = v;
    if (getOptionalString(arguments, "exclude")) |v| options.exclude_pattern = v;
    if (getOptionalU64(arguments, "min_instance_size")) |v| options.min_instance_size = v;

    if (options.match_pattern != null or options.exclude_pattern != null) {
        Overview.validateClassOptions(options) catch return Result{
            .failure = .{
                .message = "Invalid regular expression in match or exclude",
                .error_type = "InvalidArgument",
            },
        };
    }

    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;

    var filtered: std.ArrayList(Overview.ClassEntry) = .empty;
    defer filtered.deinit(allocator);

    for (data.classes) |entry| {
        if (classEntryMatches(entry.name, entry.instance_size, options)) {
            try filtered.append(allocator, .{ .name = entry.name, .superclass = entry.superclass, .instance_size = entry.instance_size });
        }
    }

    std.mem.sort(Overview.ClassEntry, filtered.items, {}, sortClassBySize);

    try writer.writeAll("[");
    const count = @min(filtered.items.len, options.limit);
    for (filtered.items[0..count], 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"class\":");
        try writeJsonString(writer, entry.name);
        try writer.writeAll(",\"superclass\":");
        try writeJsonString(writer, entry.superclass);
        try writer.print(",\"instance_size\":{d}", .{entry.instance_size});
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
    return Result{ .success = try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]) };
}

fn histogramEntryMatches(name: []const u8, entry: Overview.HistogramEntry, options: Overview.HistogramOptions) bool {
    if (entry.bytes < options.min_bytes or entry.count < options.min_instances) return false;
    if (options.match_pattern) |pattern| if (!Regex.matches(pattern, name)) return false;
    if (options.exclude_pattern) |pattern| if (Regex.matches(pattern, name)) return false;
    return true;
}

fn classEntryMatches(name: []const u8, instance_size: u64, options: Overview.ClassOptions) bool {
    if (instance_size < options.min_instance_size) return false;
    if (options.match_pattern) |pattern| if (!Regex.matches(pattern, name)) return false;
    if (options.exclude_pattern) |pattern| if (Regex.matches(pattern, name)) return false;
    return true;
}

fn sortHistByBytes(_: void, a: Overview.HistogramEntry, b: Overview.HistogramEntry) bool {
    if (a.bytes != b.bytes) return a.bytes > b.bytes;
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn sortHistByInstances(_: void, a: Overview.HistogramEntry, b: Overview.HistogramEntry) bool {
    if (a.count != b.count) return a.count > b.count;
    if (a.bytes != b.bytes) return a.bytes > b.bytes;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn sortClassBySize(_: void, a: Overview.ClassEntry, b: Overview.ClassEntry) bool {
    if (a.instance_size != b.instance_size) return a.instance_size > b.instance_size;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn loadOverviewData(allocator: std.mem.Allocator, io: Io, index_dir: []const u8) !Overview.OverviewData {
    const manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest = try Manifest.IndexManifest.parseFromFile(allocator, io, manifest_path);
    defer manifest.deinit(allocator);
    return try Overview.readCache(allocator, io, index_dir, &manifest.fingerprint);
}

fn listThreads(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    const index_dir = getRequiredString(arguments, "index_dir") orelse return Result{
        .failure = .{
            .message = "Missing required argument: index_dir",
            .error_type = "InvalidArgument",
        },
    };

    var reader = try IndexReader.open(allocator, io, index_dir, null);
    defer reader.deinit();

    var threads = try ThreadQuery.build(allocator, &reader);
    defer threads.deinit();

    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    try ThreadQuery.writeJson(&threads, &buf.writer);

    return Result{ .success = try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]) };
}

fn findObjects(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    return try runQueryTool(allocator, io, arguments, "objects");
}

fn sampleObjects(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    return try runQueryTool(allocator, io, arguments, "sample");
}

fn getObject(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    return try runQueryTool(allocator, io, arguments, "object");
}

fn refsFrom(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    return try runQueryTool(allocator, io, arguments, "refs-from");
}

fn refsTo(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    return try runQueryTool(allocator, io, arguments, "refs-to");
}

fn findRoots(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    return try runQueryTool(allocator, io, arguments, "roots");
}

fn referenceTree(allocator: std.mem.Allocator, io: Io, arguments: std.json.Value) !Result {
    return try runQueryTool(allocator, io, arguments, "tree");
}

fn runQueryTool(
    allocator: std.mem.Allocator,
    io: Io,
    arguments: std.json.Value,
    comptime tool: []const u8,
) !Result {
    const index_dir = getRequiredString(arguments, "index_dir") orelse return Result{
        .failure = .{
            .message = "Missing required argument: index_dir",
            .error_type = "InvalidArgument",
        },
    };

    var reader = try IndexReader.open(allocator, io, index_dir, null);
    defer reader.deinit();

    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    if (std.mem.eql(u8, tool, "objects")) {
        const pattern = getRequiredString(arguments, "class_regex") orelse return Result{
            .failure = .{
                .message = "Missing required argument: class_regex",
                .error_type = "InvalidArgument",
            },
        };
        try Regex.validate(pattern);
        var opts: IndexReader.ObjectsOptions = .{};
        if (getOptionalU32(arguments, "limit")) |v| opts.limit = v;
        if (getOptionalU32(arguments, "offset")) |v| opts.offset = v;
        if (getOptionalBool(arguments, "reverse")) |v| opts.reverse = v;
        try IndexReader.writeObjectsList(&reader, &buf.writer, pattern, opts);
    } else if (std.mem.eql(u8, tool, "sample")) {
        const pattern = getRequiredString(arguments, "class_regex") orelse return Result{
            .failure = .{
                .message = "Missing required argument: class_regex",
                .error_type = "InvalidArgument",
            },
        };
        try Regex.validate(pattern);
        var opts: IndexReader.ObjectsOptions = .{};
        if (getOptionalU32(arguments, "limit")) |v| opts.limit = v;
        if (getOptionalU32(arguments, "offset")) |v| opts.offset = v;
        if (getOptionalBool(arguments, "reverse")) |v| opts.reverse = v;
        try IndexReader.writeSampleList(&reader, &buf.writer, pattern, opts);
    } else if (std.mem.eql(u8, tool, "object")) {
        const id_str = getRequiredString(arguments, "id") orelse return Result{
            .failure = .{
                .message = "Missing required argument: id",
                .error_type = "InvalidArgument",
            },
        };
        const raw_id = try IndexReader.parseRawId(id_str);
        const ordinal = reader.ordinalForRawId(raw_id) orelse return Result{
            .failure = .{
                .message = "Object id not found in index",
                .error_type = "ObjectNotFound",
            },
        };
        var view = try reader.decodeObject(ordinal);
        defer view.deinit(allocator);
        try IndexReader.writeObjectView(&buf.writer, view);
    } else if (std.mem.eql(u8, tool, "refs-from")) {
        const raw_id = try parseRequiredId(arguments, "id");
        var opts: IndexReader.RefsOptions = .{};
        if (getOptionalU32(arguments, "limit")) |v| opts.limit = v;
        if (getOptionalU32(arguments, "offset")) |v| opts.offset = v;
        try IndexReader.writeRefsFrom(&reader, &buf.writer, raw_id, opts);
    } else if (std.mem.eql(u8, tool, "refs-to")) {
        const raw_id = try parseRequiredId(arguments, "id");
        var opts: IndexReader.RefsOptions = .{};
        if (getOptionalU32(arguments, "limit")) |v| opts.limit = v;
        if (getOptionalU32(arguments, "offset")) |v| opts.offset = v;
        try IndexReader.writeRefsTo(&reader, &buf.writer, raw_id, opts);
    } else if (std.mem.eql(u8, tool, "roots")) {
        const raw_id = try parseRequiredId(arguments, "id");
        var opts: IndexReader.RootsOptions = .{};
        if (getOptionalU32(arguments, "max_visited")) |v| opts.max_visited = v;
        try IndexReader.writeRoots(&reader, &buf.writer, raw_id, opts);
    } else if (std.mem.eql(u8, tool, "tree")) {
        const raw_id = try parseRequiredId(arguments, "id");
        var opts: IndexReader.TreeOptions = .{};
        if (getOptionalString(arguments, "direction")) |v| opts.direction = v;
        if (getOptionalU32(arguments, "depth")) |v| opts.depth = v;
        if (getOptionalU32(arguments, "max_nodes")) |v| opts.max_nodes = v;
        try IndexReader.writeTree(&reader, &buf.writer, raw_id, opts);
    }

    return Result{ .success = try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]) };
}

fn parseRequiredId(arguments: std.json.Value, name: []const u8) !u64 {
    const id_str = getRequiredString(arguments, name) orelse return error.InvalidArgument;
    return IndexReader.parseRawId(id_str) catch return error.InvalidArgument;
}

fn getRequiredString(arguments: std.json.Value, name: []const u8) ?[]const u8 {
    if (arguments != .object) return null;
    const val = arguments.object.get(name) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getOptionalString(arguments: std.json.Value, name: []const u8) ?[]const u8 {
    return getRequiredString(arguments, name);
}

fn getOptionalU32(arguments: std.json.Value, name: []const u8) ?u32 {
    if (arguments != .object) return null;
    const val = arguments.object.get(name) orelse return null;
    switch (val) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) return @intCast(i),
        .float => |f| if (f >= 0 and f <= std.math.maxInt(u32)) return @intFromFloat(f),
        else => {},
    }
    return null;
}

fn getOptionalU64(arguments: std.json.Value, name: []const u8) ?u64 {
    if (arguments != .object) return null;
    const val = arguments.object.get(name) orelse return null;
    switch (val) {
        .integer => |i| if (i >= 0) return @intCast(i),
        else => {},
    }
    return null;
}

fn getOptionalBool(arguments: std.json.Value, name: []const u8) ?bool {
    if (arguments != .object) return null;
    const val = arguments.object.get(name) orelse return null;
    if (val != .bool) return null;
    return val.bool;
}

test "getOptionalU32 accepts valid integer" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"limit\":100}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, 100), getOptionalU32(parsed.value, "limit"));
}

test "getOptionalU32 rejects negative integer" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"limit\":-1}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, null), getOptionalU32(parsed.value, "limit"));
}

test "getOptionalU32 rejects out-of-range integer" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"limit\":4294967296}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, null), getOptionalU32(parsed.value, "limit"));
}

test "getOptionalU32 rejects out-of-range float" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"limit\":1e20}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, null), getOptionalU32(parsed.value, "limit"));
}

test "getOptionalU64 accepts valid integer" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"bytes\":1000}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 1000), getOptionalU64(parsed.value, "bytes"));
}

test "getOptionalU64 rejects float" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"bytes\":1e10}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, null), getOptionalU64(parsed.value, "bytes"));
}

test "dispatch unknown tool returns failure" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    const result = try dispatch(allocator, std.testing.io, &config_load, "no_such_tool", parsed.value, .{});
    defer result.deinit(allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings("UnknownTool", result.failure.error_type);
}

test "dispatch analyze_heap_dump missing hprof_path returns failure" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    const result = try dispatch(allocator, std.testing.io, &config_load, "analyze_heap_dump", parsed.value, .{});
    defer result.deinit(allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings("InvalidArgument", result.failure.error_type);
}

test "dispatch analyze_heap_dump missing file returns failure" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"hprof_path\":\"/nonexistent/hunt/test/file.hprof\",\"index_dir\":\"/tmp/hunt-mcp-test-missing-file.idx\"}", .{});
    defer parsed.deinit();
    const result = try dispatch(allocator, std.testing.io, &config_load, "analyze_heap_dump", parsed.value, .{});
    defer result.deinit(allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings("FileNotFound", result.failure.error_type);
}

test "dispatch heap_info missing index_dir returns failure" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    const result = try dispatch(allocator, std.testing.io, &config_load, "heap_info", parsed.value, .{});
    defer result.deinit(allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings("InvalidArgument", result.failure.error_type);
}

test "dispatch heap_histogram missing index_dir returns failure" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    const result = try dispatch(allocator, std.testing.io, &config_load, "heap_histogram", parsed.value, .{});
    defer result.deinit(allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings("InvalidArgument", result.failure.error_type);
}

test "dispatch heap_classes missing index_dir returns failure" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    const result = try dispatch(allocator, std.testing.io, &config_load, "heap_classes", parsed.value, .{});
    defer result.deinit(allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings("InvalidArgument", result.failure.error_type);
}

fn mapError(err: anyerror, context: []const u8) Result {
    return Result{
        .failure = .{
            .message = context,
            .error_type = @errorName(err),
            .suggestion = errorSuggestion(err),
        },
    };
}

fn errorSuggestion(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.CacheMissing => "Run analyze_heap_dump for this heap dump first.",
        error.SourceFingerprintMismatch => "The HPROF file changed since indexing. Re-run analyze_heap_dump with --force.",
        error.FileNotFound => "Check that the file path is correct.",
        error.InvalidArgument => "Verify all required arguments are provided and valid.",
        else => null,
    };
}
