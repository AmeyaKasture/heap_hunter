//! heap hunter core library and CLI logic.
const std = @import("std");
const Io = std.Io;

const build_options = @import("build_options");
const hprof = @import("hprof.zig");
const log = @import("log");

pub const std_options: std.Options = .{
    .log_level = log.level,
    .allow_stack_tracing = build_options.stack_traces,
};

const Analysis = @import("Analysis.zig");
const Regex = @import("Regex.zig");
const Manifest = @import("index/Manifest.zig");
const IndexReader = @import("index/IndexReader.zig");
const Overview = @import("Overview.zig");
const Config = @import("Config.zig").Config;
const Progress = @import("Progress.zig");
pub const Cli = @import("Cli.zig");
const Commands = @import("Commands.zig");
const Mcp = @import("Mcp.zig");

pub fn runCli(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    environ_map: ?*std.process.Environ.Map,
) anyerror!void {
    errdefer |err| {
        log.traceError(err);
    }

    log.debug("runCli: {d} args", .{args.len});

    var config_path: ?[]const u8 = null;
    var command_index: usize = 1;
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--config")) {
        config_path = args[2];
        command_index = 3;
    }

    log.debug("runCli: config_path={?s}, command_index={d}", .{ config_path, command_index });

    if (args.len <= command_index) {
        log.debug("no command provided, printing global help", .{});
        try Cli.printGlobalHelp(stdout);
        return;
    }

    const command = args[command_index];
    log.debug("runCli: command={s}", .{command});

    if (Cli.isHelpFlag(command)) {
        log.debug("printing global help", .{});
        try Cli.printGlobalHelp(stdout);
        return;
    }
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        log.debug("printing version", .{});
        try Cli.printVersion(stdout);
        return;
    }

    log.debug("loading configuration", .{});
    const config_load = try Config.loadWithResult(allocator, io, config_path, environ_map);
    defer config_load.deinit(allocator);
    log.debug("configuration loaded, candidates_checked={d}", .{config_load.candidates_checked.len});

    var shifted_args: std.ArrayList([:0]const u8) = .empty;
    defer shifted_args.deinit(allocator);
    try shifted_args.append(allocator, args[0]);
    try shifted_args.append(allocator, args[command_index]);
    try shifted_args.appendSlice(allocator, args[command_index + 1 ..]);
    const shifted = try shifted_args.toOwnedSlice(allocator);
    defer allocator.free(shifted);

    if (std.mem.eql(u8, command, "index")) {
        log.debug("dispatching to runIndexCommand", .{});
        return Commands.runIndexCommand(allocator, io, shifted, stdout, stderr, config_load, null, null);
    }

    if (std.mem.eql(u8, command, "overview")) {
        log.debug("dispatching to runOverviewCommand", .{});
        return Commands.runOverviewCommand(allocator, io, shifted, stdout, stderr, config_load, null, null);
    }

    if (std.mem.eql(u8, command, "mcp")) {
        log.debug("dispatching to runMcp", .{});
        return runMcp(allocator, io, shifted, config_load);
    }

    if (std.mem.eql(u8, command, "objects") or
        std.mem.eql(u8, command, "sample"))
    {
        log.debug("dispatching to runObjectsCommand ({s})", .{command});
        return runObjectsCommand(allocator, io, command, shifted, stdout, stderr, config_load);
    }

    if (std.mem.eql(u8, command, "object") or
        std.mem.eql(u8, command, "refs-from") or
        std.mem.eql(u8, command, "refs-to") or
        std.mem.eql(u8, command, "roots") or
        std.mem.eql(u8, command, "tree"))
    {
        log.debug("dispatching to runQueryCommand ({s})", .{command});
        return runQueryCommand(allocator, io, command, shifted, stdout, stderr, config_load);
    }

    const is_histogram = std.mem.eql(u8, command, "histogram");
    const is_classes = std.mem.eql(u8, command, "classes");
    const is_info = std.mem.eql(u8, command, "info");
    if (!is_histogram and !is_classes and !is_info) {
        try Cli.printError(stderr, "unknown command: {s}", .{command});
        try stderr.writeAll("\n");
        try Cli.printGlobalHelp(stderr);
        return error.UnknownCommand;
    }

    if (shifted.len >= 3 and Cli.isHelpFlag(shifted[2])) {
        try Cli.printCommandHelp(stdout, command);
        return;
    }

    var show_banner = !is_histogram and !is_classes;
    var histogram_options = Overview.HistogramOptions{};
    var class_options = Overview.ClassOptions{};
    var index_dir_opt: ?[]const u8 = null;

    const usage = if (is_histogram)
        "hunt histogram [file.hprof] [options]"
    else if (is_classes)
        "hunt classes [file.hprof] [options]"
    else
        "hunt info [file.hprof] [options]";

    var dump_path_opt: ?[]const u8 = null;

    var i: usize = 2;
    while (i < shifted.len) : (i += 1) {
        const arg = shifted[i];
        if (Cli.isHelpFlag(arg)) {
            try Cli.printCommandHelp(stdout, command);
            return;
        } else if (std.mem.eql(u8, arg, "--index-dir")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, shifted, i);
            i += 1;
            index_dir_opt = value;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--limit")) {
            const limit_str = try Cli.expectNextArg(stderr, command, usage, arg, shifted, i);
            i += 1;
            histogram_options.limit = try Cli.parseUnsigned(usize, stderr, command, usage, arg, limit_str);
            class_options.limit = histogram_options.limit;
        } else if (std.mem.startsWith(u8, arg, "-l")) {
            const limit_str = arg[2..];
            histogram_options.limit = try Cli.parseUnsigned(usize, stderr, command, usage, arg, limit_str);
            class_options.limit = histogram_options.limit;
        } else if (std.mem.eql(u8, arg, "--view")) {
            histogram_options.view = true;
            class_options.view = true;
            show_banner = true;
        } else if (std.mem.eql(u8, arg, "--sort-instances") or std.mem.eql(u8, arg, "-s")) {
            histogram_options.sort_by_instances = true;
        } else if (std.mem.eql(u8, arg, "--match") or std.mem.eql(u8, arg, "--exclude") or std.mem.eql(u8, arg, "--min-bytes") or std.mem.eql(u8, arg, "--min-instances") or std.mem.eql(u8, arg, "--min-instance-size")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, shifted, i);
            i += 1;
            if (std.mem.eql(u8, arg, "--match")) {
                histogram_options.match_pattern = value;
                class_options.match_pattern = value;
            } else if (std.mem.eql(u8, arg, "--exclude")) {
                histogram_options.exclude_pattern = value;
                class_options.exclude_pattern = value;
            } else if (std.mem.eql(u8, arg, "--min-bytes")) {
                histogram_options.min_bytes = try Cli.parseUnsigned(u64, stderr, command, usage, arg, value);
            } else if (std.mem.eql(u8, arg, "--min-instances")) {
                histogram_options.min_instances = try Cli.parseUnsigned(u64, stderr, command, usage, arg, value);
            } else {
                class_options.min_instance_size = try Cli.parseUnsigned(u64, stderr, command, usage, arg, value);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try Cli.printUnknownOption(stderr, command, usage, arg);
            return error.InvalidArgument;
        } else {
            if (dump_path_opt == null and std.mem.endsWith(u8, arg, ".hprof")) {
                dump_path_opt = arg;
            } else {
                try Cli.printError(stderr, "unexpected positional argument: {s}", .{arg});
                return error.InvalidArgument;
            }
        }
    }

    const uses_histogram_only_options = histogram_options.sort_by_instances or histogram_options.min_bytes != 0 or histogram_options.min_instances != 0;
    const uses_class_only_options = class_options.min_instance_size != 0;
    const uses_shared_filter_options = histogram_options.match_pattern != null or histogram_options.exclude_pattern != null;
    if ((uses_histogram_only_options and !is_histogram) or (uses_class_only_options and !is_classes) or (uses_shared_filter_options and !is_histogram and !is_classes)) {
        try Cli.printError(stderr, "filtering and sorting options are only supported for histogram or classes as applicable", .{});
        return error.InvalidArgument;
    }

    if (is_histogram) {
        Overview.validateHistogramOptions(histogram_options) catch {
            try Cli.printError(stderr, "invalid regular expression in --match or --exclude", .{});
            return error.InvalidArgument;
        };
    } else if (is_classes) {
        Overview.validateClassOptions(class_options) catch {
            try Cli.printError(stderr, "invalid regular expression in --match or --exclude", .{});
            return error.InvalidArgument;
        };
    }

    var index_dir_owned = false;
    const index_dir = (try Commands.resolveIndexDir(allocator, config_load, index_dir_opt, dump_path_opt, &index_dir_owned)) orelse {
        try Cli.printMissingConfig(stderr, config_load.candidates_checked, config_load.explicit_path);
        return error.InvalidArgument;
    };
    defer if (index_dir_owned) allocator.free(index_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest = Manifest.IndexManifest.parseFromFile(allocator, io, manifest_path) catch |err| {
        try Cli.printError(stderr, "failed to read manifest: {s}", .{@errorName(err)});
        return @as(anyerror!void, err);
    };
    defer manifest.deinit(allocator);

    var overview_data = Overview.readCache(allocator, io, index_dir, &manifest.fingerprint) catch |err| {
        switch (err) {
            error.CacheMissing => try Cli.printError(stderr, "overview cache not found; run 'hunt overview <file.hprof> --index-dir {s}'", .{index_dir}),
            error.CacheFingerprintMismatch => try Cli.printError(stderr, "overview cache is stale; run 'hunt overview <file.hprof> --index-dir {s} --force'", .{index_dir}),
            error.CacheCorrupt => try Cli.printError(stderr, "overview cache is corrupt; run 'hunt overview <file.hprof> --index-dir {s} --force'", .{index_dir}),
            error.CacheVersionMismatch => try Cli.printError(stderr, "overview cache version mismatch; run 'hunt overview <file.hprof> --index-dir {s} --force'", .{index_dir}),
            else => try Cli.printError(stderr, "failed to read overview cache: {s}", .{@errorName(err)}),
        }
        return @as(anyerror!void, err);
    };
    defer overview_data.deinit();

    if (show_banner) {
        try Cli.printHeading(stdout, "hunt - Java HPROF heap dump analyzer");
    }

    if (std.mem.eql(u8, command, "info")) {
        try stdout.print("\n", .{});
        return Overview.printInfo(&overview_data, stdout);
    }
    if (std.mem.eql(u8, command, "histogram")) {
        if (show_banner) {
            try stdout.print("\n", .{});
        }
        return Overview.printHistogram(&overview_data, stdout, histogram_options);
    }
    if (std.mem.eql(u8, command, "classes")) {
        if (show_banner) {
            try stdout.print("\n", .{});
        }
        return Overview.printClasses(&overview_data, stdout, class_options);
    }

    unreachable;
}

pub fn runMcp(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const [:0]const u8,
    config_load: Config.LoadResult,
) anyerror!void {
    _ = args;
    log.debug("runMcp starting", .{});

    var mcp_config_load = config_load;
    var server = Mcp.Server.init(allocator, io, &mcp_config_load);
    try server.run();
}

fn runQueryCommand(
    allocator: std.mem.Allocator,
    io: Io,
    command: []const u8,
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    config_load: Config.LoadResult,
) anyerror!void {
    errdefer |err| {
        log.traceError(err);
    }

    log.debug("runQueryCommand: command={s}", .{command});

    var usage_buf: [128]u8 = undefined;
    const usage = if (std.mem.eql(u8, command, "object"))
        "hunt object [file.hprof] <id> [options]"
    else
        try std.fmt.bufPrint(&usage_buf, "hunt {s} [file.hprof] <id> [options]", .{command});

    var id_opt: ?[]const u8 = null;
    var index_dir_opt: ?[]const u8 = null;
    var dump_path_opt: ?[]const u8 = null;
    var source_override: ?[]const u8 = null;
    var refs_opts: IndexReader.RefsOptions = .{};
    var roots_opts: IndexReader.RootsOptions = .{};
    var tree_opts: IndexReader.TreeOptions = .{};

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (Cli.isHelpFlag(arg)) {
            try Cli.printCommandHelp(stdout, command);
            return;
        } else if (std.mem.eql(u8, arg, "--index-dir")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            index_dir_opt = value;
        } else if (std.mem.eql(u8, arg, "--source")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            source_override = value;
        } else if (std.mem.eql(u8, arg, "--offset")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            refs_opts.offset = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            refs_opts.limit = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--max-visited")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            roots_opts.max_visited = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--direction")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            tree_opts.direction = value;
        } else if (std.mem.eql(u8, arg, "--depth")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            tree_opts.depth = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--max-nodes")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            tree_opts.max_nodes = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try Cli.printUnknownOption(stderr, command, usage, arg);
            return error.InvalidArgument;
        } else {
            if (dump_path_opt == null and std.mem.endsWith(u8, arg, ".hprof")) {
                dump_path_opt = arg;
            } else if (id_opt == null) {
                id_opt = arg;
            } else {
                try Cli.printError(stderr, "multiple id arguments specified", .{});
                return error.InvalidArgument;
            }
        }
    }

    const id_str = id_opt orelse {
        try Cli.printMissingArgument(stderr, command, usage, "missing required argument <id>", .{});
        return error.InvalidArgument;
    };
    const raw_id = IndexReader.parseRawId(id_str) catch {
        try Cli.printInvalidValue(stderr, command, usage, "<id>", id_str, "an object id such as 0x3000");
        return error.InvalidArgument;
    };
    log.debug("query args parsed: id={s}, raw_id={x}, index_dir={?s}", .{ id_str, raw_id, index_dir_opt });

    var index_dir_owned = false;
    const index_dir = (try Commands.resolveIndexDir(allocator, config_load, index_dir_opt, dump_path_opt, &index_dir_owned)) orelse {
        try Cli.printMissingConfig(stderr, config_load.candidates_checked, config_load.explicit_path);
        return error.InvalidArgument;
    };
    defer if (index_dir_owned) allocator.free(index_dir);

    log.debug("query: loading index from {s}", .{index_dir});

    var progress = Progress.create(stderr, io, 1, false);
    defer progress.stop(null);
    progress.nextStep("loading index");

    var reader = IndexReader.open(allocator, io, index_dir, source_override) catch |err| {
        log.err("failed to open index: {s}", .{@errorName(err)});
        try Cli.printError(stderr, "failed to open index: {s}", .{@errorName(err)});
        return @as(anyerror!void, err);
    };
    progress.stop("index loaded");
    log.debug("query: index loaded", .{});
    defer reader.deinit();

    if (std.mem.eql(u8, command, "object")) {
        const ordinal = reader.ordinalForRawId(raw_id) orelse {
            try Cli.printError(stderr, "object id not found in index: {s}", .{id_str});
            return error.ObjectNotFound;
        };
        var view = try reader.decodeObject(ordinal);
        defer view.deinit(allocator);
        try IndexReader.writeObjectView(stdout, view);
    } else if (std.mem.eql(u8, command, "refs-from")) {
        try IndexReader.writeRefsFrom(&reader, stdout, raw_id, refs_opts);
    } else if (std.mem.eql(u8, command, "refs-to")) {
        try IndexReader.writeRefsTo(&reader, stdout, raw_id, refs_opts);
    } else if (std.mem.eql(u8, command, "roots")) {
        try IndexReader.writeRoots(&reader, stdout, raw_id, roots_opts);
    } else if (std.mem.eql(u8, command, "tree")) {
        try IndexReader.writeTree(&reader, stdout, raw_id, tree_opts);
    } else {
        unreachable;
    }

    try stdout.flush();
}

fn runObjectsCommand(
    allocator: std.mem.Allocator,
    io: Io,
    command: []const u8,
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    config_load: Config.LoadResult,
) anyerror!void {
    errdefer |err| {
        log.traceError(err);
    }

    log.debug("runObjectsCommand: command={s}", .{command});

    var usage_buf: [128]u8 = undefined;
    const usage = try std.fmt.bufPrint(&usage_buf, "hunt {s} [file.hprof] <class-regex> [options]", .{command});

    var pattern_opt: ?[]const u8 = null;
    var index_dir_opt: ?[]const u8 = null;
    var dump_path_opt: ?[]const u8 = null;
    var source_override: ?[]const u8 = null;
    var opts: IndexReader.ObjectsOptions = .{};

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (Cli.isHelpFlag(arg)) {
            try Cli.printCommandHelp(stdout, command);
            return;
        } else if (std.mem.eql(u8, arg, "--index-dir")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            index_dir_opt = value;
        } else if (std.mem.eql(u8, arg, "--source")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            source_override = value;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            opts.limit = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--offset")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            opts.offset = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            opts.reverse = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try Cli.printUnknownOption(stderr, command, usage, arg);
            return error.InvalidArgument;
        } else {
            if (dump_path_opt == null and std.mem.endsWith(u8, arg, ".hprof")) {
                dump_path_opt = arg;
            } else if (pattern_opt == null) {
                pattern_opt = arg;
            } else {
                try Cli.printError(stderr, "multiple class pattern arguments specified", .{});
                return error.InvalidArgument;
            }
        }
    }

    const pattern = pattern_opt orelse {
        try Cli.printMissingArgument(stderr, command, usage, "missing required argument <class-regex>", .{});
        return error.InvalidArgument;
    };
    log.debug("objects args parsed: pattern={s}, index_dir={?s}", .{ pattern, index_dir_opt });

    var index_dir_owned = false;
    const index_dir = (try Commands.resolveIndexDir(allocator, config_load, index_dir_opt, dump_path_opt, &index_dir_owned)) orelse {
        try Cli.printMissingConfig(stderr, config_load.candidates_checked, config_load.explicit_path);
        return error.InvalidArgument;
    };
    defer if (index_dir_owned) allocator.free(index_dir);

    Regex.validate(pattern) catch {
        try Cli.printError(stderr, "invalid regular expression in class pattern: {s}", .{pattern});
        return error.InvalidArgument;
    };

    log.debug("objects: loading index from {s}", .{index_dir});

    var progress = Progress.create(stderr, io, 1, false);
    defer progress.stop(null);
    progress.nextStep("loading index");

    var reader = IndexReader.open(allocator, io, index_dir, source_override) catch |err| {
        log.err("failed to open index: {s}", .{@errorName(err)});
        try Cli.printError(stderr, "failed to open index: {s}", .{@errorName(err)});
        return @as(anyerror!void, err);
    };
    progress.stop("index loaded");
    log.debug("objects: index loaded", .{});
    defer reader.deinit();

    if (std.mem.eql(u8, command, "objects")) {
        try IndexReader.writeObjectsList(&reader, stdout, pattern, opts);
    } else if (std.mem.eql(u8, command, "sample")) {
        try IndexReader.writeSampleList(&reader, stdout, pattern, opts);
    } else {
        unreachable;
    }

    try stdout.flush();
}

test "basic sanity" {
    std.testing.refAllDecls(Analysis);
}

test "index command publishes complete index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    // Build a tiny synthetic HPROF file.
    var b = @import("tests/HprofBuilder.zig").Builder.init(allocator, 4);
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
    _ = try heap.instanceDump(0x3000, 0x2001, &[_]u8{0} ** 16);
    heap.end();
    const dump_bytes = try b.finish();
    defer allocator.free(dump_bytes);

    const dump_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "test.hprof" });
    defer allocator.free(dump_path_tmp);
    const dump_path = try allocator.dupeZ(u8, dump_path_tmp);
    defer allocator.free(dump_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });

    const index_dir_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir_tmp);
    const index_dir = try allocator.dupeZ(u8, index_dir_tmp);
    defer allocator.free(index_dir);

    const stdout_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stdout.txt" });
    defer allocator.free(stdout_path_tmp);
    const stdout_path = try allocator.dupeZ(u8, stdout_path_tmp);
    defer allocator.free(stdout_path);

    var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer stdout_file.close(io);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const stderr_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stderr.txt" });
    defer allocator.free(stderr_path_tmp);
    const stderr_path = try allocator.dupeZ(u8, stderr_path_tmp);
    defer allocator.free(stderr_path);

    var stderr_file = try Io.Dir.cwd().createFile(io, stderr_path, .{});
    defer stderr_file.close(io);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(stderr_file, io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = &[_][:0]const u8{
        "hunt",
        "index",
        dump_path,
        "--index-dir",
        index_dir,
    };

    try runCli(allocator, io, args, stdout, stderr, null);
    try stdout_writer.flush();

    const output = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
    defer allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "{\"status\":\"complete\""));

    // Verify manifest and final index files exist.
    const manifest_path = try std.fs.path.join(allocator, &.{ index_dir_tmp, "manifest.json" });
    defer allocator.free(manifest_path);
    try std.testing.expect(fileExists(io, manifest_path));

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
    };
    for (expected_files) |name| {
        const path = try std.fs.path.join(allocator, &.{ index_dir_tmp, name });
        defer allocator.free(path);
        try std.testing.expect(fileExists(io, path));
    }

    // Re-running without --force should report the index as reused.
    var stdout_file2 = try Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer stdout_file2.close(io);
    var stdout_buf2: [4096]u8 = undefined;
    var stdout_writer2: Io.File.Writer = .init(stdout_file2, io, &stdout_buf2);

    try runCli(allocator, io, args, &stdout_writer2.interface, stderr, null);
    try stdout_writer2.flush();

    const output2 = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
    defer allocator.free(output2);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, output2, "\n"), "{\"status\":\"reused\""));
}

fn fileExists(io: Io, path: []const u8) bool {
    const dir = Io.Dir.cwd();
    var file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

test "overview builds from index and reports classloader count" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    // Build a tiny synthetic HPROF with a ClassLoader subclass instance.
    var b = @import("tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();
    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "java/lang/ClassLoader");
    try b.utf8(0x1002, "com/example/MyLoader");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);
    try b.loadClass(3, 0x2002, 0x1002);
    var heap = try b.heapDump();
    _ = try heap.classDump(.{
        .class_id = 0x2000,
        .instance_size = 8,
    });
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 16,
    });
    _ = try heap.classDump(.{
        .class_id = 0x2002,
        .super_class_id = 0x2001,
        .instance_size = 16,
    });
    _ = try heap.instanceDump(0x3000, 0x2002, &[_]u8{0} ** 16);
    heap.end();
    const dump_bytes = try b.finish();
    defer allocator.free(dump_bytes);

    const dump_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "test.hprof" });
    defer allocator.free(dump_path_tmp);
    const dump_path = try allocator.dupeZ(u8, dump_path_tmp);
    defer allocator.free(dump_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });

    const index_dir_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir_tmp);
    const index_dir = try allocator.dupeZ(u8, index_dir_tmp);
    defer allocator.free(index_dir);

    const stdout_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stdout.txt" });
    defer allocator.free(stdout_path_tmp);
    const stdout_path = try allocator.dupeZ(u8, stdout_path_tmp);
    defer allocator.free(stdout_path);

    const stderr_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stderr.txt" });
    defer allocator.free(stderr_path_tmp);
    const stderr_path = try allocator.dupeZ(u8, stderr_path_tmp);
    defer allocator.free(stderr_path);

    var stderr_file = try Io.Dir.cwd().createFile(io, stderr_path, .{});
    defer stderr_file.close(io);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(stderr_file, io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Run index.
    {
        var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
        defer stdout_file.close(io);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);

        const args = &[_][:0]const u8{
            "hunt",
            "index",
            dump_path,
            "--index-dir",
            index_dir,
        };
        try runCli(allocator, io, args, &stdout_writer.interface, stderr, null);
        try stdout_writer.flush();

        const output = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
        defer allocator.free(output);
        try std.testing.expect(std.mem.startsWith(u8, output, "{\"status\":\"complete\""));
    }

    // Run overview.
    {
        var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
        defer stdout_file.close(io);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);

        const args = &[_][:0]const u8{
            "hunt",
            "overview",
            dump_path,
            "--index-dir",
            index_dir,
        };
        try runCli(allocator, io, args, &stdout_writer.interface, stderr, null);
        try stdout_writer.flush();

        const output = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
        defer allocator.free(output);
        try std.testing.expect(std.mem.startsWith(u8, output, "{\"status\":\"complete\""));
    }

    // Verify overview.bin exists.
    const overview_path = try std.fs.path.join(allocator, &.{ index_dir_tmp, "overview.bin" });
    defer allocator.free(overview_path);
    try std.testing.expect(fileExists(io, overview_path));

    // Run info and check classloader count.
    {
        var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
        defer stdout_file.close(io);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);

        const args = &[_][:0]const u8{
            "hunt",
            "info",
            dump_path,
            "--index-dir",
            index_dir,
        };
        try runCli(allocator, io, args, &stdout_writer.interface, stderr, null);
        try stdout_writer.flush();

        const output = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
        defer allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "classloaders:   1") != null);
    }
}

test "index command reuses existing index on fixture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const source_path = "test_hprofs/heapforge.hprof";

    const index_dir_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir_tmp);
    const index_dir = try allocator.dupeZ(u8, index_dir_tmp);
    defer allocator.free(index_dir);

    const stdout_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stdout.txt" });
    defer allocator.free(stdout_path_tmp);
    const stdout_path = try allocator.dupeZ(u8, stdout_path_tmp);
    defer allocator.free(stdout_path);

    const stderr_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stderr.txt" });
    defer allocator.free(stderr_path_tmp);
    const stderr_path = try allocator.dupeZ(u8, stderr_path_tmp);
    defer allocator.free(stderr_path);

    const args = &[_][:0]const u8{
        "hunt",
        "index",
        source_path,
        "--index-dir",
        index_dir,
    };

    // First run: build the index.
    {
        var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
        defer stdout_file.close(io);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);

        var stderr_file = try Io.Dir.cwd().createFile(io, stderr_path, .{});
        defer stderr_file.close(io);
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer: Io.File.Writer = .init(stderr_file, io, &stderr_buf);

        try runCli(allocator, io, args, &stdout_writer.interface, &stderr_writer.interface, null);
        try stdout_writer.flush();

        const output = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
        defer allocator.free(output);
        try std.testing.expect(std.mem.startsWith(u8, output, "{\"status\":\"complete\""));
    }

    // Verify manifest exists.
    const manifest_path = try std.fs.path.join(allocator, &.{ index_dir_tmp, "manifest.json" });
    defer allocator.free(manifest_path);
    try std.testing.expect(fileExists(io, manifest_path));

    // Second run: should reuse.
    {
        var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
        defer stdout_file.close(io);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);

        var stderr_file = try Io.Dir.cwd().createFile(io, stderr_path, .{});
        defer stderr_file.close(io);
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer: Io.File.Writer = .init(stderr_file, io, &stderr_buf);

        try runCli(allocator, io, args, &stdout_writer.interface, &stderr_writer.interface, null);
        try stdout_writer.flush();

        const output = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
        defer allocator.free(output);
        try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, output, "\n"), "{\"status\":\"reused\""));
    }
}

test "query commands run on a small synthetic index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    var b = @import("tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();

    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "Node");
    try b.utf8(0x1010, "next");
    try b.utf8(0x1011, "value");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{ .class_id = 0x2000, .instance_size = 0 });
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 8,
        .instance_fields = &.{
            .{ .name_id = 0x1010, .type = .object },
            .{ .name_id = 0x1011, .type = .int },
        },
    });

    var a_bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, a_bytes[0..4], 0x3001, .big);
    std.mem.writeInt(u32, a_bytes[4..8], 42, .big);
    var b_bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, b_bytes[0..4], 0, .big);
    std.mem.writeInt(u32, b_bytes[4..8], 7, .big);

    _ = try heap.instanceDump(0x3000, 0x2001, &a_bytes);
    _ = try heap.instanceDump(0x3001, 0x2001, &b_bytes);
    _ = try heap.rootUnknown(0x3000);
    heap.end();

    const dump_bytes = try b.finish();
    defer allocator.free(dump_bytes);

    const dump_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "test.hprof" });
    defer allocator.free(dump_path_tmp);
    const dump_path = try allocator.dupeZ(u8, dump_path_tmp);
    defer allocator.free(dump_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });

    const index_dir_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir_tmp);
    const index_dir = try allocator.dupeZ(u8, index_dir_tmp);
    defer allocator.free(index_dir);

    const stdout_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stdout.txt" });
    defer allocator.free(stdout_path_tmp);
    const stdout_path = try allocator.dupeZ(u8, stdout_path_tmp);
    defer allocator.free(stdout_path);

    const stderr_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stderr.txt" });
    defer allocator.free(stderr_path_tmp);
    const stderr_path = try allocator.dupeZ(u8, stderr_path_tmp);
    defer allocator.free(stderr_path);

    const index_args = &[_][:0]const u8{
        "hunt",
        "index",
        dump_path,
        "--index-dir",
        index_dir,
    };

    // Build the index.
    {
        var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
        defer stdout_file.close(io);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);
        var stderr_file = try Io.Dir.cwd().createFile(io, stderr_path, .{});
        defer stderr_file.close(io);
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer: Io.File.Writer = .init(stderr_file, io, &stderr_buf);
        try runCli(allocator, io, index_args, &stdout_writer.interface, &stderr_writer.interface, null);
        try stdout_writer.flush();
        const output = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
        defer allocator.free(output);
        try std.testing.expect(std.mem.startsWith(u8, output, "{\"status\":\"complete\""));
    }

    const helper = struct {
        fn runQuery(alloc: std.mem.Allocator, io_arg: Io, out_path: [:0]const u8, err_path: [:0]const u8, query_args: []const [:0]const u8) ![]const u8 {
            var stdout_file = try Io.Dir.cwd().createFile(io_arg, out_path, .{});
            defer stdout_file.close(io_arg);
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer: Io.File.Writer = .init(stdout_file, io_arg, &stdout_buf);
            var stderr_file = try Io.Dir.cwd().createFile(io_arg, err_path, .{});
            defer stderr_file.close(io_arg);
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer: Io.File.Writer = .init(stderr_file, io_arg, &stderr_buf);
            try runCli(alloc, io_arg, query_args, &stdout_writer.interface, &stderr_writer.interface, null);
            try stdout_writer.flush();
            return try Io.Dir.cwd().readFileAlloc(io_arg, out_path, alloc, .limited(4096));
        }
    };

    // object
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "object");
        try args.append(allocator, "0x3000");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"class\":\"Node\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"next\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"0x0000000000003001\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"value\":42") != null);
    }

    // refs-from
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "refs-from");
        try args.append(allocator, "0x3000");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"direction\":\"outbound\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003001\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"relation\":\"next\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"next_offset\":null") != null);
    }

    // refs-to
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "refs-to");
        try args.append(allocator, "0x3001");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"direction\":\"inbound\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003000\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"relation\":\"next\"") != null);
    }

    // roots
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "roots");
        try args.append(allocator, "0x3001");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"found\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"class\":\"virtual root\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003000\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003001\"") != null);
    }

    // tree
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "tree");
        try args.append(allocator, "0x3000");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"root\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"class\":\"Node\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"children\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003001\"") != null);
    }

    // objects
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "objects");
        try args.append(allocator, "Node");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"pattern\":\"Node\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003000\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003001\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"class\":\"Node\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"next_offset\":null") != null);
    }

    // objects with offset/limit and reverse
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "objects");
        try args.append(allocator, "Node");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        try args.append(allocator, "--offset");
        try args.append(allocator, "1");
        try args.append(allocator, "--limit");
        try args.append(allocator, "1");
        try args.append(allocator, "--reverse");
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003000\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"0x0000000000003001\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"reverse\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"next_offset\":2") != null);
    }

    // objects no-match
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "objects");
        try args.append(allocator, "Unknown");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"items\":[]") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"next_offset\":null") != null);
    }

    // sample
    {
        var args = std.ArrayList([:0]const u8).empty;
        defer args.deinit(allocator);
        try args.append(allocator, "hunt");
        try args.append(allocator, "sample");
        try args.append(allocator, "Node");
        try args.append(allocator, "--index-dir");
        try args.append(allocator, index_dir);
        try args.append(allocator, "--offset");
        try args.append(allocator, "1");
        try args.append(allocator, "--limit");
        try args.append(allocator, "1");
        const out = try helper.runQuery(allocator, io, stdout_path, stderr_path, args.items);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"class\":\"Node\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"next\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"value\":42") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"next_offset\":2") != null);
    }
}

test "overview command builds cache and overview commands read from it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    // Build a tiny synthetic HPROF file.
    var b = @import("tests/HprofBuilder.zig").Builder.init(allocator, 4);
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
    _ = try heap.instanceDump(0x3000, 0x2001, &[_]u8{0} ** 16);
    heap.end();
    const dump_bytes = try b.finish();
    defer allocator.free(dump_bytes);

    const dump_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "test.hprof" });
    defer allocator.free(dump_path_tmp);
    const dump_path = try allocator.dupeZ(u8, dump_path_tmp);
    defer allocator.free(dump_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });

    const index_dir_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir_tmp);
    const index_dir = try allocator.dupeZ(u8, index_dir_tmp);
    defer allocator.free(index_dir);

    const stdout_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stdout.txt" });
    defer allocator.free(stdout_path_tmp);
    const stdout_path = try allocator.dupeZ(u8, stdout_path_tmp);
    defer allocator.free(stdout_path);

    const stderr_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stderr.txt" });
    defer allocator.free(stderr_path_tmp);
    const stderr_path = try allocator.dupeZ(u8, stderr_path_tmp);
    defer allocator.free(stderr_path);

    const helper = struct {
        fn runCommand(alloc: std.mem.Allocator, io_arg: Io, out_path: [:0]const u8, err_path: [:0]const u8, cmd_args: []const [:0]const u8) ![]const u8 {
            var stdout_file = try Io.Dir.cwd().createFile(io_arg, out_path, .{});
            defer stdout_file.close(io_arg);
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer: Io.File.Writer = .init(stdout_file, io_arg, &stdout_buf);
            var stderr_file = try Io.Dir.cwd().createFile(io_arg, err_path, .{});
            defer stderr_file.close(io_arg);
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer: Io.File.Writer = .init(stderr_file, io_arg, &stderr_buf);
            try runCli(alloc, io_arg, cmd_args, &stdout_writer.interface, &stderr_writer.interface, null);
            try stdout_writer.flush();
            return try Io.Dir.cwd().readFileAlloc(io_arg, out_path, alloc, .limited(4096));
        }
    };

    // Build the index.
    {
        const index_args = &[_][:0]const u8{
            "hunt",
            "index",
            dump_path,
            "--index-dir",
            index_dir,
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, index_args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "{\"status\":\"complete\""));
    }

    // Build the overview cache.
    {
        const overview_args = &[_][:0]const u8{
            "hunt",
            "overview",
            dump_path,
            "--index-dir",
            index_dir,
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, overview_args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, out, "\n"), "{\"status\":\"complete\""));
        try std.testing.expect(std.mem.indexOf(u8, out, "\"cache\":\"overview.bin\"") != null);
    }

    // Query info from cache.
    {
        const info_args = &[_][:0]const u8{
            "hunt",
            "info",
            "--index-dir",
            index_dir,
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, info_args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "total objects:  1") != null);
        // classes.bin only contains classes with GC_CLASS_DUMP records; the fixture
        // only dumps com.shop.User, not java.lang.Object.
        try std.testing.expect(std.mem.indexOf(u8, out, "classes:        1") != null);
    }

    // Query histogram from cache.
    {
        const hist_args = &[_][:0]const u8{
            "hunt",
            "histogram",
            "--index-dir",
            index_dir,
            "-l",
            "10",
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, hist_args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "com.shop.User") != null);
    }

    // Query classes from cache.
    {
        const classes_args = &[_][:0]const u8{
            "hunt",
            "classes",
            "--index-dir",
            index_dir,
            "-l",
            "10",
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, classes_args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "com.shop.User") != null);
    }

    // Re-running overview without --force should error.
    {
        const overview_args = &[_][:0]const u8{
            "hunt",
            "overview",
            dump_path,
            "--index-dir",
            index_dir,
        };
        const result = helper.runCommand(allocator, io, stdout_path, stderr_path, overview_args);
        try std.testing.expectError(error.InvalidArgument, result);
    }

    // --force should overwrite.
    {
        const overview_args = &[_][:0]const u8{
            "hunt",
            "overview",
            dump_path,
            "--index-dir",
            index_dir,
            "--force",
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, overview_args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, out, "\n"), "{\"status\":\"complete\""));
        try std.testing.expect(std.mem.indexOf(u8, out, "\"cache\":\"overview.bin\"") != null);
    }
}

test "overview command requires an existing index" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    // Build a tiny synthetic HPROF file.
    var b = @import("tests/HprofBuilder.zig").Builder.init(allocator, 4);
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
    _ = try heap.instanceDump(0x3000, 0x2001, &[_]u8{0} ** 16);
    heap.end();
    const dump_bytes = try b.finish();
    defer allocator.free(dump_bytes);

    const dump_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "test.hprof" });
    defer allocator.free(dump_path_tmp);
    const dump_path = try allocator.dupeZ(u8, dump_path_tmp);
    defer allocator.free(dump_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });

    const index_dir_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "index" });
    defer allocator.free(index_dir_tmp);
    const index_dir = try allocator.dupeZ(u8, index_dir_tmp);
    defer allocator.free(index_dir);

    const stdout_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stdout.txt" });
    defer allocator.free(stdout_path_tmp);
    const stdout_path = try allocator.dupeZ(u8, stdout_path_tmp);
    defer allocator.free(stdout_path);

    const stderr_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stderr.txt" });
    defer allocator.free(stderr_path_tmp);
    const stderr_path = try allocator.dupeZ(u8, stderr_path_tmp);
    defer allocator.free(stderr_path);

    const overview_args = &[_][:0]const u8{
        "hunt",
        "overview",
        dump_path,
        "--index-dir",
        index_dir,
    };

    var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer stdout_file.close(io);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);
    var stderr_file = try Io.Dir.cwd().createFile(io, stderr_path, .{});
    defer stderr_file.close(io);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(stderr_file, io, &stderr_buf);

    const result = runCli(allocator, io, overview_args, &stdout_writer.interface, &stderr_writer.interface, null);
    try std.testing.expectError(error.FileNotFound, result);
}

test "index command uses config file as base directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    // Build a tiny synthetic HPROF file.
    var b = @import("tests/HprofBuilder.zig").Builder.init(allocator, 4);
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
    _ = try heap.instanceDump(0x3000, 0x2001, &[_]u8{0} ** 16);
    heap.end();
    const dump_bytes = try b.finish();
    defer allocator.free(dump_bytes);

    const dump_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "test.hprof" });
    defer allocator.free(dump_path_tmp);
    const dump_path = try allocator.dupeZ(u8, dump_path_tmp);
    defer allocator.free(dump_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });

    const base_dir = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "idx" });
    defer allocator.free(base_dir);
    const config_json = try std.fmt.allocPrint(allocator, "{{\"index-dir\": \"{s}\"}}", .{base_dir});
    defer allocator.free(config_json);

    const config_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "config.json" });
    defer allocator.free(config_path_tmp);
    const config_path = try allocator.dupeZ(u8, config_path_tmp);
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = config_json });

    const expected_index_dir = try std.fs.path.join(allocator, &.{ base_dir, "test.idx" });
    defer allocator.free(expected_index_dir);

    const stdout_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stdout.txt" });
    defer allocator.free(stdout_path_tmp);
    const stdout_path = try allocator.dupeZ(u8, stdout_path_tmp);
    defer allocator.free(stdout_path);

    const stderr_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stderr.txt" });
    defer allocator.free(stderr_path_tmp);
    const stderr_path = try allocator.dupeZ(u8, stderr_path_tmp);
    defer allocator.free(stderr_path);

    var stdout_file = try Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer stdout_file.close(io);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(stdout_file, io, &stdout_buf);

    var stderr_file = try Io.Dir.cwd().createFile(io, stderr_path, .{});
    defer stderr_file.close(io);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(stderr_file, io, &stderr_buf);

    const args = &[_][:0]const u8{
        "hunt",
        "--config",
        config_path,
        "index",
        dump_path,
    };

    try runCli(allocator, io, args, &stdout_writer.interface, &stderr_writer.interface, null);
    try stdout_writer.flush();

    const output = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
    defer allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "{\"status\":\"complete\""));
    try std.testing.expect(std.mem.indexOf(u8, output, "\"index_dir\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test.idx") != null);

    // Verify the derived index directory was created and contains the manifest.
    const manifest_path = try std.fs.path.join(allocator, &.{ expected_index_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    try std.testing.expect(fileExists(io, manifest_path));

    // Re-running should report the index as reused.
    var stdout_file2 = try Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer stdout_file2.close(io);
    var stdout_buf2: [4096]u8 = undefined;
    var stdout_writer2: Io.File.Writer = .init(stdout_file2, io, &stdout_buf2);

    try runCli(allocator, io, args, &stdout_writer2.interface, &stderr_writer.interface, null);
    try stdout_writer2.flush();

    const output2 = try Io.Dir.cwd().readFileAlloc(io, stdout_path, allocator, .limited(4096));
    defer allocator.free(output2);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, output2, "\n"), "{\"status\":\"reused\""));
    try std.testing.expect(std.mem.indexOf(u8, output2, "test.idx") != null);
}

test "positional dump path derives index directory from config base" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    // Build a tiny synthetic HPROF file with two linked Node objects.
    var b = @import("tests/HprofBuilder.zig").Builder.init(allocator, 4);
    defer b.deinit();
    try b.header(0);
    try b.utf8(0x1000, "java/lang/Object");
    try b.utf8(0x1001, "Node");
    try b.utf8(0x1010, "next");
    try b.utf8(0x1011, "value");
    try b.loadClass(1, 0x2000, 0x1000);
    try b.loadClass(2, 0x2001, 0x1001);

    var heap = try b.heapDump();
    _ = try heap.classDump(.{ .class_id = 0x2000, .instance_size = 0 });
    _ = try heap.classDump(.{
        .class_id = 0x2001,
        .super_class_id = 0x2000,
        .instance_size = 8,
        .instance_fields = &.{
            .{ .name_id = 0x1010, .type = .object },
            .{ .name_id = 0x1011, .type = .int },
        },
    });

    var a_bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, a_bytes[0..4], 0x3001, .big);
    std.mem.writeInt(u32, a_bytes[4..8], 42, .big);
    var b_bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, b_bytes[0..4], 0, .big);
    std.mem.writeInt(u32, b_bytes[4..8], 7, .big);

    _ = try heap.instanceDump(0x3000, 0x2001, &a_bytes);
    _ = try heap.instanceDump(0x3001, 0x2001, &b_bytes);
    _ = try heap.rootUnknown(0x3000);
    heap.end();
    const dump_bytes = try b.finish();
    defer allocator.free(dump_bytes);

    const dump_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "test.hprof" });
    defer allocator.free(dump_path_tmp);
    const dump_path = try allocator.dupeZ(u8, dump_path_tmp);
    defer allocator.free(dump_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dump_path, .data = dump_bytes });

    const base_dir = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "idx" });
    defer allocator.free(base_dir);
    const config_json = try std.fmt.allocPrint(allocator, "{{\"index-dir\": \"{s}\"}}", .{base_dir});
    defer allocator.free(config_json);

    const config_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "config.json" });
    defer allocator.free(config_path_tmp);
    const config_path = try allocator.dupeZ(u8, config_path_tmp);
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = config_json });

    const expected_index_dir = try std.fs.path.join(allocator, &.{ base_dir, "test.idx" });
    defer allocator.free(expected_index_dir);

    const stdout_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stdout.txt" });
    defer allocator.free(stdout_path_tmp);
    const stdout_path = try allocator.dupeZ(u8, stdout_path_tmp);
    defer allocator.free(stdout_path);

    const stderr_path_tmp = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "stderr.txt" });
    defer allocator.free(stderr_path_tmp);
    const stderr_path = try allocator.dupeZ(u8, stderr_path_tmp);
    defer allocator.free(stderr_path);

    const helper = struct {
        fn runCommand(alloc: std.mem.Allocator, io_arg: Io, out_path: [:0]const u8, err_path: [:0]const u8, command_args: []const [:0]const u8) ![]const u8 {
            var stdout_file = try Io.Dir.cwd().createFile(io_arg, out_path, .{});
            defer stdout_file.close(io_arg);
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer: Io.File.Writer = .init(stdout_file, io_arg, &stdout_buf);
            var stderr_file = try Io.Dir.cwd().createFile(io_arg, err_path, .{});
            defer stderr_file.close(io_arg);
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer: Io.File.Writer = .init(stderr_file, io_arg, &stderr_buf);
            try runCli(alloc, io_arg, command_args, &stdout_writer.interface, &stderr_writer.interface, null);
            try stdout_writer.flush();
            return try Io.Dir.cwd().readFileAlloc(io_arg, out_path, alloc, .limited(4096));
        }
    };

    // Index using positional dump path.
    {
        const args = &[_][:0]const u8{
            "hunt",
            "--config",
            config_path,
            "index",
            dump_path,
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "{\"status\":\"complete\""));
        try std.testing.expect(std.mem.indexOf(u8, out, expected_index_dir) != null);
    }

    // Overview using positional dump path.
    {
        const args = &[_][:0]const u8{
            "hunt",
            "--config",
            config_path,
            "overview",
            dump_path,
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "{\"status\":\"complete\""));
    }

    // Info using positional dump path.
    {
        const args = &[_][:0]const u8{
            "hunt",
            "--config",
            config_path,
            "info",
            dump_path,
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "total objects:  2") != null);
    }

    // Object query using positional dump path.
    {
        const args = &[_][:0]const u8{
            "hunt",
            "--config",
            config_path,
            "object",
            dump_path,
            "0x3000",
        };
        const out = try helper.runCommand(allocator, io, stdout_path, stderr_path, args);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"class\":\"Node\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"next\"") != null);
    }
}

test {
    _ = @import("index/ExtSort.zig");
    _ = @import("index/Scanner.zig");
    _ = @import("index/CatalogSorter.zig");
    _ = @import("index/Layouts.zig");
    _ = @import("index/EdgeEmitter.zig");
    _ = @import("index/Join.zig");
    _ = @import("index/Csr.zig");
    _ = @import("index/Validate.zig");
    _ = @import("index/Publish.zig");
    _ = @import("index/IndexReader.zig");
    _ = @import("Overview.zig");
    _ = @import("tests/HprofBuilder.zig");
    _ = @import("tests/integration.zig");
}

test {
    _ = @import("index/ExtSort.zig");
    _ = @import("index/Scanner.zig");
    _ = @import("index/CatalogSorter.zig");
    _ = @import("index/Layouts.zig");
    _ = @import("index/EdgeEmitter.zig");
    _ = @import("index/Join.zig");
    _ = @import("index/Csr.zig");
    _ = @import("Overview.zig");
    _ = @import("tests/HprofBuilder.zig");
    _ = @import("tests/integration.zig");
}
