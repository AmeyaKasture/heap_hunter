//! Hunt command implementations shared by the CLI and the MCP server.
const std = @import("std");
const Io = std.Io;

const hprof = @import("hprof.zig");
const log = @import("log");

const Config = @import("Config.zig").Config;
const Progress = @import("Progress.zig");
const Cli = @import("Cli.zig");
const Preflight = @import("index/Preflight.zig");
const Scanner = @import("index/Scanner.zig");
const CatalogSorter = @import("index/CatalogSorter.zig");
const Layouts = @import("index/Layouts.zig");
const EdgeEmitter = @import("index/EdgeEmitter.zig");
const Join = @import("index/Join.zig");
const Csr = @import("index/Csr.zig");
const Validate = @import("index/Validate.zig");
const Publish = @import("index/Publish.zig");
const Manifest = @import("index/Manifest.zig");
const Overview = @import("Overview.zig");

pub fn runIndexCommand(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    config_load: Config.LoadResult,
    on_progress: ?Progress.Callback,
    on_progress_ctx: ?*anyopaque,
) anyerror!void {
    errdefer |err| {
        log.traceError(err);
    }

    const config = config_load.config;
    defer stderr.flush() catch {};

    const usage = "hunt index <file.hprof> [options]";
    const command = "index";

    log.debug("runIndexCommand starting", .{});

    var path_opt: ?[]const u8 = null;
    var index_dir_opt: ?[]const u8 = null;
    var sorting_budget_mb: u32 = config.sortingBudgetMb();
    var force = false;
    var no_progress = false;

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
        } else if (std.mem.eql(u8, arg, "--sorting-budget-mb")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            sorting_budget_mb = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--no-progress")) {
            no_progress = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try Cli.printUnknownOption(stderr, command, usage, arg);
            return error.InvalidArgument;
        } else {
            if (path_opt != null) {
                try Cli.printError(stderr, "multiple file arguments specified", .{});
                return error.InvalidArgument;
            }
            path_opt = arg;
        }
    }

    const path = path_opt orelse {
        try Cli.printMissingArgument(stderr, command, usage, "missing required argument <file.hprof>", .{});
        return error.InvalidArgument;
    };

    log.debug("index args parsed: path={s}, index_dir={?s}, sorting_budget_mb={d}, force={}", .{ path, index_dir_opt, sorting_budget_mb, force });

    var index_dir_owned = false;
    const index_dir = (try resolveIndexDir(allocator, config_load, index_dir_opt, path, &index_dir_owned)) orelse {
        try Cli.printMissingConfig(stderr, config_load.candidates_checked, config_load.explicit_path);
        return error.InvalidArgument;
    };
    defer if (index_dir_owned) allocator.free(index_dir);

    log.debug("resolved index_dir={s}", .{index_dir});

    if (force) {
        log.debug("force enabled, deleting old staging directories", .{});
        deleteOldStagingDirs(allocator, io, index_dir, stderr);
    }

    log.debug("running preflight", .{});
    const preflight_result = try Preflight.run(allocator, io, path, index_dir, .{
        .sorting_budget_mb = sorting_budget_mb,
        .force = force,
    }, stderr);

    var escaped_index_dir_buf: Io.Writer.Allocating = .init(allocator);
    defer escaped_index_dir_buf.deinit();
    try jsonEscapeString(&escaped_index_dir_buf.writer, index_dir);
    const escaped_index_dir = escaped_index_dir_buf.writer.buffer[0..escaped_index_dir_buf.writer.end];

    var progress = Progress.createEx(stderr, io, 9, no_progress, on_progress, on_progress_ctx);
    defer progress.stop(null);

    switch (preflight_result) {
        .reused => {
            log.debug("preflight: reusing existing index", .{});
            progress.stop("reusing existing index");
            try stdout.print("{{\"status\":\"reused\",\"index_dir\":\"{s}\"}}\n", .{escaped_index_dir});
        },
        .job => |*job| {
            log.debug("preflight: starting new index job, staging_dir={s}", .{job.staging_dir});
            defer job.deinit(allocator);
            // Ensure the staging directory is removed on any failure path.
            errdefer {
                Io.Dir.cwd().deleteTree(io, job.staging_dir) catch {};
            }

            var source_file = try Io.Dir.cwd().openFile(io, path, .{});
            defer source_file.close(io);
            const source_len = try source_file.length(io);
            log.debug("opened source file, len={d}", .{source_len});
            var source_mm = try Io.File.MemoryMap.create(io, source_file, .{
                .len = source_len,
                .protection = .{ .read = true, .write = false },
            });
            defer source_mm.destroy(io);

            var elapsed = std.mem.zeroes(StageTimings);

            progress.nextStep("scanning heap dump");
            log.debug("stage: scanning heap dump", .{});
            var scan_result = stageTimed(io, "scan", &elapsed, try Scanner.run(allocator, io, job, source_mm.memory, &progress));
            defer scan_result.deinit(allocator);
            log.debug("stage: scan complete, n_objects approx {d}, diagnostics={any}", .{ scan_result.diagnostics.duplicate_object_ids, scan_result.diagnostics });

            progress.nextStep("sorting catalog");
            log.debug("stage: sorting catalog", .{});
            var catalog_result = stageTimed(io, "sort_catalog", &elapsed, CatalogSorter.sortAndDedupe(
                allocator,
                io,
                job,
                scan_result.catalog_path,
                &scan_result.diagnostics,
            ) catch |err| switch (err) {
                error.TooManyObjects => {
                    try Cli.printError(stderr, "too many objects to index (>= u32.max - 1)", .{});
                    return @as(anyerror!void, err);
                },
                else => return @as(anyerror!void, err),
            });
            defer catalog_result.deinit(allocator);
            log.debug("stage: sort_catalog complete, n_objects={d}", .{catalog_result.n_objects});

            const classes_path = try CatalogSorter.writeClasses(
                allocator,
                io,
                job.staging_dir,
                &scan_result.class_table,
            );
            defer allocator.free(classes_path);
            log.debug("stage: classes written to {s}", .{classes_path});

            progress.nextStep("building layouts");
            log.debug("stage: building layouts", .{});
            var layout_table = stageTimed(io, "layouts", &elapsed, try Layouts.writeFields(
                allocator,
                io,
                job.staging_dir,
                &scan_result.class_table,
                job.header.id_size,
                &scan_result.diagnostics,
            ));
            defer layout_table.deinit();
            log.debug("stage: layouts complete, n_classes={d}", .{layout_table.layouts.len});

            progress.nextStep("emitting edges");
            log.debug("stage: emitting edges", .{});
            var edge_result = stageTimed(io, "emit_edges", &elapsed, try EdgeEmitter.run(
                allocator,
                io,
                job,
                source_mm.memory,
                &layout_table,
                &scan_result.diagnostics,
            ));
            defer edge_result.deinit(allocator);
            log.debug("stage: emit_edges complete", .{});

            progress.nextStep("resolving references");
            log.debug("stage: resolving references", .{});
            var join_result = stageTimed(io, "join", &elapsed, try Join.run(
                allocator,
                io,
                job,
                edge_result.edges_path,
                catalog_result.catalog_path,
                catalog_result.n_objects,
                &scan_result.diagnostics,
            ));
            defer join_result.deinit(allocator);
            log.debug("stage: join complete, n_edges={d}", .{join_result.n_edges});

            progress.nextStep("building graph");
            log.debug("stage: building graph", .{});
            var csr_result = stageTimed(io, "csr", &elapsed, try Csr.run(
                allocator,
                io,
                job,
                join_result.resolved_path,
                scan_result.roots_path,
                catalog_result.catalog_path,
                catalog_result.n_objects,
                join_result.n_edges,
                scan_result.n_roots,
                &scan_result.diagnostics,
            ));
            defer csr_result.deinit(allocator);
            log.debug("stage: csr complete, n_roots={d}", .{csr_result.n_roots});

            const n_classes = layout_table.layouts.len;
            const n_objects = catalog_result.n_objects;
            const n_edges = join_result.n_edges;
            const n_roots = csr_result.n_roots;
            const virtual_root_ordinal = n_objects;

            progress.nextStep("validating index");
            log.debug("stage: validating index", .{});
            stageTimed(io, "validate", &elapsed, try Validate.validate(
                allocator,
                io,
                job.staging_dir,
                n_objects,
                n_edges,
                n_roots,
                n_classes,
                stderr,
            ));
            log.debug("stage: validate complete", .{});

            var manifest = Manifest.IndexManifest{
                .format_version = 1,
                .fingerprint = try job.fingerprint.clone(allocator),
                .n_objects = n_objects,
                .n_edges = n_edges,
                .virtual_root_ordinal = @intCast(virtual_root_ordinal),
                .diagnostics = scan_result.diagnostics,
                .source_path = try allocator.dupe(u8, path),
            };
            defer manifest.deinit(allocator);

            progress.nextStep("publishing index");
            log.debug("stage: publishing index", .{});
            const publish_result = stageTimed(io, "publish", &elapsed, try Publish.publish(
                allocator,
                io,
                job.staging_dir,
                index_dir,
                &manifest,
                stderr,
            ));
            // publish_result.files aliases manifest.files; manifest.deinit frees them.

            progress.stop("index complete");
            log.debug("index complete: n_objects={d}, n_classes={d}, n_edges={d}, n_roots={d}", .{ n_objects, n_classes, n_edges, n_roots });
            try stdout.print("{{\"status\":\"complete\",\"index_dir\":\"{s}\",\"n_objects\":{d},\"n_classes\":{d},\"n_edges\":{d},\"n_roots\":{d},\"virtual_root_ordinal\":{d},\"diagnostics\":{{\"duplicate_object_ids\":{d},\"skipped_constant_pool_refs\":{d},\"dangling_source_edges\":{d},\"dangling_target_edges\":{d},\"missing_superclass\":{d},\"superclass_cycle\":{d},\"unknown_root_kind\":{d},\"missing_layout\":{d},\"dangling_root_targets\":{d}}},\"elapsed_ms\":{{\"scan\":{d},\"sort_catalog\":{d},\"layouts\":{d},\"emit_edges\":{d},\"join\":{d},\"csr\":{d},\"validate\":{d},\"publish\":{d}}},\"index_bytes\":{d}}}\n", .{
                escaped_index_dir,
                n_objects,
                n_classes,
                n_edges,
                n_roots,
                virtual_root_ordinal,
                scan_result.diagnostics.duplicate_object_ids,
                scan_result.diagnostics.skipped_constant_pool_refs,
                scan_result.diagnostics.dangling_source_edges,
                scan_result.diagnostics.dangling_target_edges,
                scan_result.diagnostics.missing_superclass,
                scan_result.diagnostics.superclass_cycle,
                scan_result.diagnostics.unknown_root_kind,
                scan_result.diagnostics.missing_layout,
                scan_result.diagnostics.dangling_root_targets,
                elapsed.scan,
                elapsed.sort_catalog,
                elapsed.layouts,
                elapsed.emit_edges,
                elapsed.join,
                elapsed.csr,
                elapsed.validate,
                elapsed.publish,
                publish_result.index_bytes,
            });
        },
    }
}

pub fn runOverviewCommand(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    config_load: Config.LoadResult,
    on_progress: ?Progress.Callback,
    on_progress_ctx: ?*anyopaque,
) anyerror!void {
    errdefer |err| {
        log.traceError(err);
    }

    const usage = "hunt overview <file.hprof> [options]";
    const command = "overview";

    log.debug("runOverviewCommand starting", .{});

    var path_opt: ?[]const u8 = null;
    var index_dir_opt: ?[]const u8 = null;
    var force = false;
    var no_progress = false;

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
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--no-progress")) {
            no_progress = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try Cli.printUnknownOption(stderr, command, usage, arg);
            return error.InvalidArgument;
        } else {
            if (path_opt != null) {
                try Cli.printError(stderr, "multiple file arguments specified", .{});
                return error.InvalidArgument;
            }
            path_opt = arg;
        }
    }

    const path = path_opt orelse {
        try Cli.printMissingArgument(stderr, command, usage, "missing required argument <file.hprof>", .{});
        return error.InvalidArgument;
    };

    log.debug("overview args parsed: path={s}, index_dir={?s}, force={}", .{ path, index_dir_opt, force });

    var index_dir_owned = false;
    const index_dir = (try resolveIndexDir(allocator, config_load, index_dir_opt, path, &index_dir_owned)) orelse {
        try Cli.printMissingConfig(stderr, config_load.candidates_checked, config_load.explicit_path);
        return error.InvalidArgument;
    };
    defer if (index_dir_owned) allocator.free(index_dir);

    log.debug("resolved index_dir={s}", .{index_dir});

    // Verify the source dump matches the index fingerprint. This only touches
    // the HPROF header and first/last 1 MiB, so it is fast for huge dumps.
    const dir = Io.Dir.cwd();
    var file = dir.openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try Cli.printError(stderr, "file not found: {s}", .{path});
        } else {
            try Cli.printError(stderr, "failed to open file {s}: {s}", .{ path, @errorName(err) });
        }
        return @as(anyerror!void, err);
    };
    defer file.close(io);

    const file_len = try file.length(io);
    if (file_len == 0) {
        try Cli.printError(stderr, "file is empty: {s}", .{path});
        return error.EmptyFile;
    }

    var mm = try Io.File.MemoryMap.create(io, file, .{
        .len = file_len,
        .protection = .{ .read = true, .write = false },
        .populate = false,
    });
    defer mm.destroy(io);

    const header = try hprof.Header.parse(mm.memory);
    const fp = try Manifest.computeFingerprint(allocator, mm.memory, header, 0);
    defer fp.deinit(allocator);

    const manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "manifest.json" });
    defer allocator.free(manifest_path);

    const manifest = Manifest.IndexManifest.parseFromFile(allocator, io, manifest_path) catch |err| {
        if (err == error.FileNotFound) {
            try Cli.printError(stderr, "index not found; run 'hunt index {s} --index-dir {s}' first", .{ path, index_dir });
        } else {
            try Cli.printError(stderr, "failed to read manifest: {s}", .{@errorName(err)});
        }
        return @as(anyerror!void, err);
    };
    defer manifest.deinit(allocator);

    if (!fp.eql(manifest.fingerprint)) {
        try Cli.printError(stderr, "HPROF fingerprint does not match the index in '{s}'", .{index_dir});
        return error.SourceFingerprintMismatch;
    }

    const cache_path = try Overview.cachePath(allocator, index_dir);
    defer allocator.free(cache_path);
    if (!force) {
        var exists = true;
        _ = Io.Dir.cwd().openFile(io, cache_path, .{}) catch |err| switch (err) {
            error.FileNotFound => exists = false,
            else => |e| return @as(anyerror!void, e),
        };
        if (exists) {
            try Cli.printError(stderr, "overview cache already exists; use --force to overwrite", .{});
            return error.InvalidArgument;
        }
    }

    var progress = Progress.createEx(stderr, io, 3, no_progress, on_progress, on_progress_ctx);
    defer progress.stop(null);

    progress.nextStep("reading index");
    log.debug("overview: reading index", .{});
    progress.nextStep("building overview");
    log.debug("overview: building overview", .{});
    var overview_data = try Overview.buildFromIndex(allocator, io, index_dir, &manifest);
    defer overview_data.deinit();

    progress.nextStep("writing cache");
    log.debug("overview: writing cache", .{});
    try Overview.writeCache(allocator, io, index_dir, &manifest.fingerprint, &overview_data);

    progress.stop("overview complete");
    log.debug("overview complete", .{});
    var escaped_index_dir_buf: Io.Writer.Allocating = .init(allocator);
    defer escaped_index_dir_buf.deinit();
    try jsonEscapeString(&escaped_index_dir_buf.writer, index_dir);
    const escaped_index_dir = escaped_index_dir_buf.writer.buffer[0..escaped_index_dir_buf.writer.end];

    try stdout.print("{{\"status\":\"complete\",\"index_dir\":\"{s}\",\"cache\":\"overview.bin\"}}\n", .{escaped_index_dir});
}

/// Resolve the index directory for a command. Precedence:
/// 1. Explicit `--index-dir` value.
/// 2. A dump path positional argument combined with config `index-dir` as a
///    base directory, producing `<base>/<stem>.idx/`.
/// 3. Config `index-dir` used literally.
///
/// `out_owned` is set to true when the returned path is newly allocated and
/// must be freed by the caller.
pub fn resolveIndexDir(
    allocator: std.mem.Allocator,
    config_load: Config.LoadResult,
    index_dir_opt: ?[]const u8,
    dump_path_opt: ?[]const u8,
    out_owned: *bool,
) !?[]const u8 {
    if (index_dir_opt) |d| {
        out_owned.* = false;
        return d;
    }
    if (dump_path_opt) |dump_path| {
        if (config_load.config.indexDir()) |base| {
            out_owned.* = true;
            return try Config.deriveIndexDir(allocator, base, dump_path);
        }
    }
    if (config_load.config.indexDir()) |d| {
        out_owned.* = false;
        return d;
    }
    out_owned.* = false;
    return null;
}

fn deleteOldStagingDirs(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    stderr: *Io.Writer,
) void {
    var dir = Io.Dir.cwd().openDir(io, index_dir, .{}) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch |err| {
        Cli.printWarning(stderr, "failed to enumerate index directory for old staging dirs: {}", .{err}) catch {};
        return;
    }) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, ".staging-")) continue;

        const sub_path = std.fs.path.join(allocator, &.{ index_dir, entry.name }) catch continue;
        defer allocator.free(sub_path);

        Io.Dir.cwd().deleteTree(io, sub_path) catch |err| {
            Cli.printWarning(stderr, "failed to remove old staging directory {s}: {}", .{ entry.name, err }) catch {};
        };
    }
}

const StageTimings = struct {
    scan: i64 = 0,
    sort_catalog: i64 = 0,
    layouts: i64 = 0,
    emit_edges: i64 = 0,
    join: i64 = 0,
    csr: i64 = 0,
    validate: i64 = 0,
    publish: i64 = 0,
};

fn stageTimed(
    io: Io,
    comptime name: []const u8,
    timings: *StageTimings,
    result: anytype,
) @TypeOf(result) {
    const start_ns = Io.Timestamp.now(io, .awake).nanoseconds;
    const r = result;
    const end_ns = Io.Timestamp.now(io, .awake).nanoseconds;
    const delta_ns: i64 = @intCast(end_ns - start_ns);
    @field(timings, name) = @divTrunc(delta_ns, std.time.ns_per_ms);
    return r;
}

fn jsonEscapeString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
