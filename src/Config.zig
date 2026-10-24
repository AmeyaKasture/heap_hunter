//! Heap Hunter user configuration loaded from a JSON config file.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

pub const Candidate = struct {
    env_var: []const u8,
    dir_components: []const []const u8,
    file_name: []const u8,
};

/// Default platform-specific config file search order.
pub fn defaultConfigCandidates(os_tag: std.Target.Os.Tag) []const Candidate {
    if (os_tag == .windows) {
        return &.{
            .{ .env_var = "APPDATA", .dir_components = &[_][]const u8{"hunt"}, .file_name = "config.json" },
            .{ .env_var = "USERPROFILE", .dir_components = &[_][]const u8{".hunt"}, .file_name = "config.json" },
        };
    }
    return &.{
        .{ .env_var = "XDG_CONFIG_HOME", .dir_components = &[_][]const u8{"hunt"}, .file_name = "config.json" },
        .{ .env_var = "HOME", .dir_components = &[_][]const u8{ ".config", "hunt" }, .file_name = "config.json" },
        .{ .env_var = "HOME", .dir_components = &[_][]const u8{".hunt"}, .file_name = "config.json" },
    };
}

pub const Config = struct {
    /// Default base directory for indexes. For commands that take a heapdump
    /// file (`index`, `overview`), this is treated as a base directory and the
    /// actual index directory is derived as `<base>/<stem>.idx/`. For query
    /// commands that do not take a dump file, this value is used literally.
    @"index-dir": ?[]const u8 = null,

    /// Default sorting budget in megabytes for the index command. This bounds
    /// the working memory used by the external sort that produces the sorted
    /// object catalog; it is not the total RSS of the process.
    @"sorting-budget-mb": ?u32 = null,

    pub const default_sorting_budget_mb: u32 = 4096;

    pub fn indexDir(self: Config) ?[]const u8 {
        return self.@"index-dir";
    }

    pub fn sortingBudgetMb(self: Config) u32 {
        return self.@"sorting-budget-mb" orelse default_sorting_budget_mb;
    }

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        if (self.@"index-dir") |p| allocator.free(p);
    }

    pub const LoadError = error{
        ConfigNotFound,
        OutOfMemory,
    };

    pub const LoadResult = struct {
        config: Config = .{},
        /// The path that was actually loaded, or null if no config file was found.
        loaded_path: ?[]const u8 = null,
        /// The explicit path passed by the user via `--config`, if any.
        explicit_path: ?[]const u8 = null,
        /// The default candidate paths that were checked when no explicit path was given.
        candidates_checked: []const []const u8 = &.{},
        /// True if a config file was found and loaded.
        config_found: bool = false,

        /// Free the loaded_path, candidates_checked arrays, and the config.
        pub fn deinit(self: *const LoadResult, allocator: std.mem.Allocator) void {
            if (self.loaded_path) |p| allocator.free(p);
            for (self.candidates_checked) |c| allocator.free(c);
            allocator.free(self.candidates_checked);
            self.config.deinit(allocator);
        }
    };

    /// Standard sample config file contents shown to the user when a config file
    /// is required but not found.
    pub const sample_config_template =
        \\{
        \\  "index-dir": "/path/to/hunt/indexes",
        \\  "sorting-budget-mb": 4096
        \\}
        \\
        \\For index/overview commands, index-dir is used as a base directory:
        \\  <index-dir>/<stem>.idx/
        \\For query commands, index-dir is used literally.
        \\
        \\You can also override the config path with --config <file>.
    ;

    /// Load the config file. If `config_path` is provided, that file is loaded
    /// and a missing file is an error (error.ConfigNotFound). Otherwise, the
    /// default config locations are checked in order and the first one that exists
    /// is loaded. If no config file exists, an empty config is returned.
    ///
    /// The caller owns the returned Config and must call `Config.deinit`. The
    /// LoadResult helper is also owned by the caller.
    pub fn loadWithResult(
        allocator: std.mem.Allocator,
        io: Io,
        config_path: ?[]const u8,
        environ_map: ?*std.process.Environ.Map,
    ) !LoadResult {
        var result: LoadResult = .{};
        errdefer result.deinit(allocator);

        const path = if (config_path) |p| p else blk: {
            const candidates = try resolveConfigPathCandidates(allocator, io, environ_map);
            result.candidates_checked = candidates.checked;
            if (candidates.found) |resolved| {
                result.loaded_path = resolved;
                result.config_found = true;
                break :blk resolved;
            }
            return .{ .config = .{}, .candidates_checked = try dupeStringSlice(allocator, candidates.checked) };
        };

        result.explicit_path = config_path;
        result.loaded_path = try allocator.dupe(u8, path);
        result.config_found = true;

        const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.ConfigNotFound,
            else => return err,
        };
        defer allocator.free(data);

        const parsed = try std.json.parseFromSlice(Config, allocator, data, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var config: Config = .{};
        if (parsed.value.@"index-dir") |p| {
            config.@"index-dir" = try allocator.dupe(u8, p);
        }
        if (parsed.value.@"sorting-budget-mb") |mb| {
            config.@"sorting-budget-mb" = mb;
        }
        result.config = config;
        return result;
    }

    /// Convenience wrapper around `loadWithResult` that returns only the Config.
    /// Only use this when the caller does not need to report missing default
    /// config paths to the user.
    pub fn load(
        allocator: std.mem.Allocator,
        io: Io,
        config_path: ?[]const u8,
        environ_map: ?*std.process.Environ.Map,
    ) !Config {
        var lr = try loadWithResult(allocator, io, config_path, environ_map);
        const config = lr.config;
        lr.config = .{};
        lr.deinit(allocator);
        return config;
    }

    fn dupeStringSlice(allocator: std.mem.Allocator, slice: []const []const u8) ![]const []const u8 {
        const result = try allocator.alloc([]const u8, slice.len);
        errdefer allocator.free(result);
        for (slice, 0..) |s, i| {
            result[i] = try allocator.dupe(u8, s);
        }
        return result;
    }

    pub const Candidates = struct {
        /// Paths that were checked, whether they exist or not. Owned by the caller.
        checked: []const []const u8,
        /// The first existing candidate, or null if none were found.
        found: ?[]const u8,
    };

    /// Resolve the default config path using XDG conventions. Returns the path to
    /// the first existing candidate, or null if none exist. The caller owns the
    /// returned path.
    pub fn resolveConfigPath(
        allocator: std.mem.Allocator,
        io: Io,
        environ_map: ?*std.process.Environ.Map,
    ) !?[]const u8 {
        const candidates = try resolveConfigPathCandidates(allocator, io, environ_map);
        defer {
            for (candidates.checked) |c| allocator.free(c);
            allocator.free(candidates.checked);
        }
        if (candidates.found) |found| {
            return try allocator.dupe(u8, found);
        }
        return null;
    }

    pub fn resolveConfigPathCandidates(
        allocator: std.mem.Allocator,
        io: Io,
        environ_map: ?*std.process.Environ.Map,
    ) !Candidates {
        return resolveConfigPathCandidatesForOs(allocator, io, environ_map, builtin.os.tag);
    }

    pub fn resolveConfigPathCandidatesForOs(
        allocator: std.mem.Allocator,
        io: Io,
        environ_map: ?*std.process.Environ.Map,
        os_tag: std.Target.Os.Tag,
    ) !Candidates {
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (paths.items) |p| allocator.free(p);
            paths.deinit(allocator);
        }

        const map = environ_map orelse return .{ .checked = try paths.toOwnedSlice(allocator), .found = null };

        const candidates = defaultConfigCandidates(os_tag);
        for (candidates) |candidate| {
            const base = map.get(candidate.env_var) orelse continue;
            const dir = try std.fs.path.join(allocator, candidate.dir_components);
            defer allocator.free(dir);
            const path = try std.fs.path.join(allocator, &.{ base, dir, candidate.file_name });
            try paths.append(allocator, path);
            if (try fileExists(io, path)) {
                return .{ .checked = try paths.toOwnedSlice(allocator), .found = path };
            }
        }
        return .{ .checked = try paths.toOwnedSlice(allocator), .found = null };
    }

    /// Derive the index directory for a heapdump file from a configured base
    /// directory. The dump's basename (without a trailing `.hprof` extension) is
    /// used to create a `<stem>.idx` subdirectory under `base_dir`.
    pub fn deriveIndexDir(allocator: std.mem.Allocator, base_dir: []const u8, dump_path: []const u8) ![]const u8 {
        const basename = std.fs.path.basename(dump_path);
        const stem = if (std.mem.endsWith(u8, basename, ".hprof"))
            basename[0 .. basename.len - 6]
        else
            basename;
        const sub_name = try std.fmt.allocPrint(allocator, "{s}.idx", .{stem});
        defer allocator.free(sub_name);
        return try std.fs.path.join(allocator, &.{ base_dir, sub_name });
    }
};

fn fileExists(io: Io, path: []const u8) !bool {
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

test "deriveIndexDir strips .hprof and appends .idx" {
    const allocator = std.testing.allocator;
    const result = try Config.deriveIndexDir(allocator, "temp", "/dumps/production-heap.hprof");
    defer allocator.free(result);
    const expected = try std.fs.path.join(allocator, &.{ "temp", "production-heap.idx" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "deriveIndexDir appends .idx for non-.hprof basenames" {
    const allocator = std.testing.allocator;
    const result = try Config.deriveIndexDir(allocator, "temp", "/dumps/my-dump");
    defer allocator.free(result);
    const expected = try std.fs.path.join(allocator, &.{ "temp", "my-dump.idx" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "Config defaults" {
    const config: Config = .{};
    try std.testing.expect(config.indexDir() == null);
    try std.testing.expectEqual(@as(u32, 4096), config.sortingBudgetMb());
}

test "Config JSON parsing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const json = "{\"index-dir\": \"temp/\", \"sorting-budget-mb\": 2048}";

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const config_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "config.json" });
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = json });

    const config = try Config.load(allocator, io, config_path, null);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("temp/", config.indexDir().?);
    try std.testing.expectEqual(@as(u32, 2048), config.sortingBudgetMb());
}

test "Config load ignores unknown fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const json = "{\"index-dir\": \"idx\", \"future-option\": true}";

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const config_path = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "config.json" });
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = json });

    const config = try Config.load(allocator, io, config_path, null);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("idx", config.indexDir().?);
    try std.testing.expectEqual(@as(u32, 4096), config.sortingBudgetMb());
}

test "Config load resolves default path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const hunt_dir = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "hunt" });
    defer allocator.free(hunt_dir);
    try tmp_dir.dir.createDir(io, "hunt", .default_dir);

    const config_path = try std.fs.path.join(allocator, &.{ hunt_dir, "config.json" });
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "{\"index-dir\": \"resolved\"}" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", tmp_path_z[0..tmp_path_z.len]);

    const config = try Config.load(allocator, io, null, &env);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("resolved", config.indexDir().?);
    try std.testing.expectEqual(@as(u32, 4096), config.sortingBudgetMb());
}

test "resolveConfigPath prefers XDG_CONFIG_HOME" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const hunt_dir = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "hunt" });
    defer allocator.free(hunt_dir);
    try tmp_dir.dir.createDir(io, "hunt", .default_dir);

    const config_path = try std.fs.path.join(allocator, &.{ hunt_dir, "config.json" });
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "{\"index-dir\": \"xdg\"}" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", tmp_path_z[0..tmp_path_z.len]);

    const resolved = try Config.resolveConfigPath(allocator, io, &env);
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expectEqualStrings(config_path, resolved.?);
}

test "resolveConfigPath falls back to HOME/.config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const home = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "home" });
    defer allocator.free(home);
    try tmp_dir.dir.createDirPath(io, "home/.config/hunt");

    const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "hunt" });
    defer allocator.free(config_dir);

    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.json" });
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "{\"index-dir\": \"home\"}" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", home);

    const resolved = try Config.resolveConfigPath(allocator, io, &env);
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expectEqualStrings(config_path, resolved.?);
}

test "resolveConfigPathCandidatesForOs uses APPDATA on Windows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path_z = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path_z);

    const hunt_dir = try std.fs.path.join(allocator, &.{ tmp_path_z[0..tmp_path_z.len], "hunt" });
    defer allocator.free(hunt_dir);
    try tmp_dir.dir.createDir(io, "hunt", .default_dir);

    const config_path = try std.fs.path.join(allocator, &.{ hunt_dir, "config.json" });
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "{\"index-dir\": \"appdata\"}" });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("APPDATA", tmp_path_z[0..tmp_path_z.len]);

    const candidates = try Config.resolveConfigPathCandidatesForOs(allocator, io, &env, .windows);
    defer {
        for (candidates.checked) |c| allocator.free(c);
        allocator.free(candidates.checked);
    }

    try std.testing.expect(candidates.found != null);
    try std.testing.expectEqualStrings(config_path, candidates.found.?);
}
