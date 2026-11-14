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
const Dominator = @import("index/Dominator.zig");
const Manifest = @import("index/Manifest.zig");
const Overview = @import("Overview.zig");
const IndexReader = @import("index/IndexReader.zig");

pub const IndexOptions = struct {
    hprof_path: []const u8,
    index_dir: ?[]const u8 = null,
    sorting_budget_mb: ?u32 = null,
    force: bool = false,
    no_progress: bool = false,
    compute_dominators: bool = true,
    dominator_budget_mb: ?u32 = null,
};

pub const OverviewOptions = struct {
    hprof_path: []const u8,
    index_dir: ?[]const u8 = null,
    force: bool = false,
    no_progress: bool = false,
};

pub fn runIndexCommand(
    allocator: std.mem.Allocator,
    io: Io,
    options: IndexOptions,
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

    const path = options.hprof_path;
    const index_dir_opt = options.index_dir;
    const sorting_budget_mb = options.sorting_budget_mb orelse config.sortingBudgetMb();
    const compute_dominators = options.compute_dominators;
    const dominator_budget_mb = options.dominator_budget_mb orelse config.dominatorBudgetMb();
    const force = options.force;
    const no_progress = options.no_progress;

    log.debug("runIndexCommand starting", .{});
    log.debug("index options: path={s}, index_dir={?s}, sorting_budget_mb={d}, force={}", .{ path, index_dir_opt, sorting_budget_mb, force });

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
        .dominator_budget_mb = dominator_budget_mb,
        .compute_dominators = compute_dominators,
        .force = force,
    }, stderr);

    var escaped_index_dir_buf: Io.Writer.Allocating = .init(allocator);
    defer escaped_index_dir_buf.deinit();
    try jsonEscapeString(&escaped_index_dir_buf.writer, index_dir);
    const escaped_index_dir = escaped_index_dir_buf.writer.buffer[0..escaped_index_dir_buf.writer.end];

    const n_progress_steps: u32 = if (compute_dominators) 10 else 9;
    var progress = Progress.createEx(stderr, io, n_progress_steps, no_progress, on_progress, on_progress_ctx);
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

            var dominator_n_reachable: u64 = 0;
            var dominator_total_retained: u64 = 0;
            if (compute_dominators) {
                progress.nextStep("computing dominators");
                log.debug("stage: computing dominators", .{});
                const V = catalog_result.n_objects + 1;
                const required_conservative: u64 = @intCast(@as(u128, Dominator.chkBytesPerNode()) * V + 8 * V);
                var dominator_result = stageTimed(io, "dominators", &elapsed, Dominator.run(
                    allocator,
                    io,
                    job,
                    csr_result.out_offsets_path,
                    csr_result.out_targets_path,
                    csr_result.in_offsets_path,
                    csr_result.in_sources_path,
                    catalog_result.catalog_path,
                    catalog_result.n_objects,
                    join_result.n_edges,
                    &scan_result.diagnostics,
                    .{},
                ) catch |err| {
                    if (err == error.DominatorBudgetExceeded) {
                        Dominator.formatBudgetError(V, required_conservative, job.dominator_budget_bytes, stderr) catch {};
                        try stderr.flush();
                    }
                    return @as(anyerror!void, err);
                });
                defer dominator_result.deinit(allocator);
                dominator_n_reachable = dominator_result.n_reachable;
                dominator_total_retained = dominator_result.total_retained_bytes;
            }

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
                compute_dominators,
                stderr,
            ));
            log.debug("stage: validate complete", .{});

            var manifest = Manifest.IndexManifest{
                .format_version = 2,
                .fingerprint = try job.fingerprint.clone(allocator),
                .n_objects = n_objects,
                .n_edges = n_edges,
                .virtual_root_ordinal = @intCast(virtual_root_ordinal),
                .diagnostics = scan_result.diagnostics,
                .source_path = try allocator.dupe(u8, path),
                .has_dominators = compute_dominators,
                .n_dominator_nodes = dominator_n_reachable,
                .retained_total_bytes = dominator_total_retained,
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
            try stdout.print("{{\"status\":\"complete\",\"index_dir\":\"{s}\",\"n_objects\":{d},\"n_classes\":{d},\"n_edges\":{d},\"n_roots\":{d},\"virtual_root_ordinal\":{d},\"has_dominators\":{},\"n_dominator_nodes\":{d},\"retained_total_bytes\":{d},\"diagnostics\":{{\"duplicate_object_ids\":{d},\"skipped_constant_pool_refs\":{d},\"dangling_source_edges\":{d},\"dangling_target_edges\":{d},\"missing_superclass\":{d},\"superclass_cycle\":{d},\"unknown_root_kind\":{d},\"missing_layout\":{d},\"dangling_root_targets\":{d},\"unreachable_objects\":{d}}},\"elapsed_ms\":{{\"scan\":{d},\"sort_catalog\":{d},\"layouts\":{d},\"emit_edges\":{d},\"join\":{d},\"csr\":{d},\"dominators\":{d},\"validate\":{d},\"publish\":{d}}},\"index_bytes\":{d}}}\n", .{
                escaped_index_dir,
                n_objects,
                n_classes,
                n_edges,
                n_roots,
                virtual_root_ordinal,
                compute_dominators,
                dominator_n_reachable,
                dominator_total_retained,
                scan_result.diagnostics.duplicate_object_ids,
                scan_result.diagnostics.skipped_constant_pool_refs,
                scan_result.diagnostics.dangling_source_edges,
                scan_result.diagnostics.dangling_target_edges,
                scan_result.diagnostics.missing_superclass,
                scan_result.diagnostics.superclass_cycle,
                scan_result.diagnostics.unknown_root_kind,
                scan_result.diagnostics.missing_layout,
                scan_result.diagnostics.dangling_root_targets,
                scan_result.diagnostics.unreachable_objects,
                elapsed.scan,
                elapsed.sort_catalog,
                elapsed.layouts,
                elapsed.emit_edges,
                elapsed.join,
                elapsed.csr,
                elapsed.dominators,
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
    options: OverviewOptions,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    config_load: Config.LoadResult,
    on_progress: ?Progress.Callback,
    on_progress_ctx: ?*anyopaque,
) anyerror!void {
    errdefer |err| {
        log.traceError(err);
    }

    log.debug("runOverviewCommand starting", .{});

    const path = options.hprof_path;
    const index_dir_opt = options.index_dir;
    const force = options.force;
    const no_progress = options.no_progress;

    log.debug("overview options: path={s}, index_dir={?s}, force={}", .{ path, index_dir_opt, force });

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

/// Parse CLI argv into IndexOptions. `args` must include the program name at
/// index 0 and the command at index 1 (i.e. the shifted form produced by runCli).
pub fn parseIndexArgs(
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) anyerror!IndexOptions {
    const usage = "hunt index <file.hprof> [options]";
    const command = "index";

    var path_opt: ?[]const u8 = null;
    var index_dir_opt: ?[]const u8 = null;
    var sorting_budget_mb: ?u32 = null;
    var dominator_budget_mb: ?u32 = null;
    var compute_dominators = true;
    var force = false;
    var no_progress = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (Cli.isHelpFlag(arg)) {
            try Cli.printCommandHelp(stdout, command);
            return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--index-dir")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            index_dir_opt = value;
        } else if (std.mem.eql(u8, arg, "--sorting-budget-mb")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            sorting_budget_mb = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--dominator-budget-mb")) {
            const value = try Cli.expectNextArg(stderr, command, usage, arg, args, i);
            i += 1;
            dominator_budget_mb = try Cli.parseUnsigned(u32, stderr, command, usage, arg, value);
        } else if (std.mem.eql(u8, arg, "--no-dominators")) {
            compute_dominators = false;
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

    return .{
        .hprof_path = path,
        .index_dir = index_dir_opt,
        .sorting_budget_mb = sorting_budget_mb,
        .force = force,
        .no_progress = no_progress,
        .compute_dominators = compute_dominators,
        .dominator_budget_mb = dominator_budget_mb,
    };
}

/// Parse CLI argv into OverviewOptions. `args` must include the program name at
/// index 0 and the command at index 1 (i.e. the shifted form produced by runCli).
pub fn parseOverviewArgs(
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) anyerror!OverviewOptions {
    const usage = "hunt overview <file.hprof> [options]";
    const command = "overview";

    var path_opt: ?[]const u8 = null;
    var index_dir_opt: ?[]const u8 = null;
    var force = false;
    var no_progress = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (Cli.isHelpFlag(arg)) {
            try Cli.printCommandHelp(stdout, command);
            return error.InvalidArgument;
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

    return .{
        .hprof_path = path,
        .index_dir = index_dir_opt,
        .force = force,
        .no_progress = no_progress,
    };
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

/// Print the immediate dominator and retained size for a single object.
pub fn runDominatorCommand(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    source_override: ?[]const u8,
    raw_id: u64,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    var reader = try IndexReader.open(allocator, io, index_dir, source_override);
    defer reader.deinit();

    if (!reader.manifest.has_dominators) {
        try Cli.printError(stderr, "index was built without dominators; re-index with dominators enabled", .{});
        return error.NoRetainedData;
    }

    const id_str = try std.fmt.allocPrint(allocator, "0x{x}", .{raw_id});
    defer allocator.free(id_str);

    const ordinal = reader.ordinalForRawId(raw_id) orelse {
        try Cli.printError(stderr, "object id not found in index: {s}", .{id_str});
        return error.ObjectNotFound;
    };

    const dom_parent = reader.domParent(ordinal);
    const retained = reader.retainedBytes(ordinal);

    try stdout.writeAll("{\n");
    try stdout.print("  \"id\": \"{s}\",\n", .{id_str});
    try stdout.print("  \"ordinal\": {d},\n", .{ordinal});
    try stdout.writeAll("  \"dominator\": ");
    if (dom_parent) |p| {
        const parent_raw_id = reader.rawIdForOrdinal(p) orelse 0;
        try IndexReader.writeRawIdOrNull(stdout, parent_raw_id);
    } else {
        try stdout.writeAll("null");
    }
    try stdout.writeAll(",\n");
    try stdout.print("  \"retained_bytes\": {d}\n", .{retained});
    try stdout.writeAll("}\n");
    try stdout.flush();
}

pub const DominatorTreeOptions = struct {
    depth: ?u32 = null,
    max_nodes: ?u32 = null,
};

/// Walk the immediate-dominator chain starting at `start`, appending each
/// ordinal to `chain` until the top of the reachable graph is reached or a
/// bound cuts the walk short.
///
/// `parent` returns the immediate dominator of an ordinal, or `null` when the
/// ordinal has none (the top of the reachable graph, or an unreachable node).
///
/// Returns true when a bound cut the chain short. A chain that ends naturally
/// is not truncated, so a caller can distinguish "the bound stopped the walk"
/// from "the chain really was this short".
///
/// The bound semantics match `hunt tree`: `--depth N` follows at most N
/// dominator links, yielding at most N + 1 nodes, and `--max-nodes N` yields
/// at most N nodes. When both are given, the tighter bound wins.
fn collectDominatorChain(
    allocator: std.mem.Allocator,
    chain: *std.ArrayList(u32),
    start: u32,
    options: DominatorTreeOptions,
    context: anytype,
) !bool {
    const parent = struct {
        fn get(ctx: @TypeOf(context), ordinal: u32) ?u32 {
            return ctx.parent(ordinal);
        }
    }.get;

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    var current: ?u32 = start;
    var depth_remaining: ?u32 = options.depth;

    while (current) |node| {
        if (seen.contains(node)) break; // safety break on cycles
        try seen.put(node, {});

        if (options.max_nodes) |max| {
            if (chain.items.len >= max) {
                // The chain continues past the bound, so it is truncated.
                return true;
            }
        }
        try chain.append(allocator, node);

        const parent_ordinal = parent(context, node);
        if (depth_remaining) |dr| {
            if (dr == 0) {
                // The chain continues past the bound, so it is truncated.
                return parent_ordinal != null;
            }
            depth_remaining = dr - 1;
        }

        current = parent_ordinal;
    }

    return false;
}

/// Print the dominator chain from an object up to the top of the reachable graph.
/// The chain ends at a real object (the dominator tree is rooted at the virtual
/// root, but the virtual root itself carries no retained size and is not
/// emitted as a node).
///
/// The chain may be shortened by `--depth` or `--max-nodes`. When that happens
/// the output carries `"truncated": true`, matching the convention used by
/// `hunt roots`, so a caller can tell a cut chain from a naturally short one.
pub fn runDominatorTreeCommand(
    allocator: std.mem.Allocator,
    io: Io,
    index_dir: []const u8,
    source_override: ?[]const u8,
    raw_id: u64,
    options: DominatorTreeOptions,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    var reader = try IndexReader.open(allocator, io, index_dir, source_override);
    defer reader.deinit();

    if (!reader.manifest.has_dominators) {
        try Cli.printError(stderr, "index was built without dominators; re-index with dominators enabled", .{});
        return error.NoRetainedData;
    }

    const id_str = try std.fmt.allocPrint(allocator, "0x{x}", .{raw_id});
    defer allocator.free(id_str);

    const start_ordinal = reader.ordinalForRawId(raw_id) orelse {
        try Cli.printError(stderr, "object id not found in index: {s}", .{id_str});
        return error.ObjectNotFound;
    };

    // Collect the chain from start up to the top of the reachable graph
    // (or an unreachable node, which has no dominator), honouring depth and
    // max_nodes bounds exactly like hunt tree.
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);

    const lookup = struct {
        reader: *const IndexReader.Reader,

        fn parent(self: @This(), ordinal: u32) ?u32 {
            return self.reader.domParent(ordinal);
        }
    }{ .reader = &reader };
    const truncated = try collectDominatorChain(
        allocator,
        &chain,
        start_ordinal,
        options,
        lookup,
    );

    try stdout.writeAll("{\n");
    try stdout.print("  \"id\": \"{s}\",\n", .{id_str});
    try stdout.print("  \"ordinal\": {d},\n", .{start_ordinal});
    try stdout.print("  \"truncated\": {},\n", .{truncated});
    try stdout.writeAll("  \"path\": [\n");

    for (chain.items, 0..) |node, i| {
        const node_raw_id = reader.rawIdForOrdinal(node) orelse 0;
        const retained = reader.retainedBytes(node);
        try stdout.writeAll("    {\n");
        try stdout.print("      \"ordinal\": {d},\n", .{node});
        try stdout.writeAll("      \"id\": ");
        try IndexReader.writeRawIdOrNull(stdout, node_raw_id);
        try stdout.writeAll(",\n");
        try stdout.print("      \"retained_bytes\": {d}\n", .{retained});
        try stdout.writeAll("    }");
        if (i + 1 < chain.items.len) try stdout.writeAll(",");
        try stdout.writeAll("\n");
    }

    try stdout.writeAll("  ]\n");
    try stdout.writeAll("}\n");
    try stdout.flush();
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
    dominators: i64 = 0,
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

/// A dominator chain fixture: node `i` is dominated by node `i + 1`, and the
/// last node has no dominator (it is the top of the reachable graph).
const ChainFixture = struct {
    /// The immediate dominator of `ordinal`, or null at the top of the chain.
    fn parent(ordinal: u32) ?u32 {
        return if (ordinal >= 4) null else ordinal + 1;
    }
};

/// Collect a chain into `chain` and report whether a bound truncated it.
fn collectForTest(
    allocator: std.mem.Allocator,
    chain: *std.ArrayList(u32),
    start: u32,
    options: DominatorTreeOptions,
) !bool {
    return collectDominatorChain(allocator, chain, start, options, ChainFixture);
}

test "dominator chain without bounds reaches the top of the graph" {
    const allocator = std.testing.allocator;

    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    const truncated = try collectForTest(allocator, &chain, 0, .{});

    try std.testing.expectEqual(@as(usize, 5), chain.items.len);
    try std.testing.expectEqual(@as(u32, 0), chain.items[0]);
    try std.testing.expectEqual(@as(u32, 4), chain.items[4]);
    // The chain ended naturally, so it was not truncated.
    try std.testing.expect(!truncated);
}

test "dominator chain depth bound cuts the chain and reports truncation" {
    const allocator = std.testing.allocator;

    // Depth 2 follows two links, yielding three nodes out of five.
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    const truncated = try collectForTest(allocator, &chain, 0, .{ .depth = 2 });

    try std.testing.expectEqual(@as(usize, 3), chain.items.len);
    try std.testing.expect(truncated);
}

test "dominator chain depth bound that reaches the top is not truncated" {
    const allocator = std.testing.allocator;

    // Depth 4 reaches the last node of a five-node chain, so nothing is hidden.
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    const truncated = try collectForTest(allocator, &chain, 0, .{ .depth = 4 });

    try std.testing.expectEqual(@as(usize, 5), chain.items.len);
    try std.testing.expect(!truncated);
}

test "dominator chain max-nodes bound cuts the chain and reports truncation" {
    const allocator = std.testing.allocator;

    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    const truncated = try collectForTest(allocator, &chain, 0, .{ .max_nodes = 2 });

    try std.testing.expectEqual(@as(usize, 2), chain.items.len);
    try std.testing.expect(truncated);
}

test "dominator chain max-nodes bound that covers the chain is not truncated" {
    const allocator = std.testing.allocator;

    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    const truncated = try collectForTest(allocator, &chain, 0, .{ .max_nodes = 5 });

    try std.testing.expectEqual(@as(usize, 5), chain.items.len);
    try std.testing.expect(!truncated);
}

test "dominator chain max-nodes of zero yields an empty chain" {
    const allocator = std.testing.allocator;

    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    const truncated = try collectForTest(allocator, &chain, 0, .{ .max_nodes = 0 });

    try std.testing.expectEqual(@as(usize, 0), chain.items.len);
    try std.testing.expect(truncated);
}

test "dominator chain starting at the top is a single node and is not truncated" {
    const allocator = std.testing.allocator;

    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    const truncated = try collectForTest(allocator, &chain, 4, .{});

    try std.testing.expectEqual(@as(usize, 1), chain.items.len);
    try std.testing.expect(!truncated);
}

test "dominator chain applies the tighter of the two bounds" {
    const allocator = std.testing.allocator;

    // Depth 2 allows three nodes, max-nodes 2 allows two; the tighter wins.
    var chain = std.ArrayList(u32).empty;
    defer chain.deinit(allocator);
    const truncated = try collectForTest(allocator, &chain, 0, .{ .depth = 2, .max_nodes = 2 });

    try std.testing.expectEqual(@as(usize, 2), chain.items.len);
    try std.testing.expect(truncated);
}
