//! Guard for the memory-mapping policy.
//!
//! Zig 0.16 defaults `Io.File.MemoryMap.Options.populate` to `true`, which
//! maps the file with `MAP_POPULATE` and faults in *every* page up front.
//! For a heap dump larger than RAM (the 20 GB fixture on a 15 GB box) that
//! costs a full-file read before any work starts, and it evicts everything
//! else from the page cache.
//!
//! Policy applied across the codebase:
//!
//!   * `.populate = false` — demand paging. Used for every mapping that is
//!     scanned sequentially, is probed randomly but may exceed RAM, or is
//!     only partially read: source dumps, index files, catalogs, edge
//!     files, sort runs. The kernel's readahead already streams sequential
//!     reads efficiently, and prefaulting a file larger than RAM is waste.
//!   * `.populate = true` — prefault. Used only where the mapping is
//!     bounded by an explicit memory budget *and* accessed through a random
//!     pattern, so that prefaulting replaces random I/O with a single
//!     sequential read.
//!
//! Every mapping call site must state its choice explicitly, so that a
//! future Zig default change, or a copy-paste of a call site, cannot
//! silently reintroduce a full-file prefault.
const std = @import("std");
const Io = std.Io;

/// Bytes of source scanned after a mapping call in which the options struct
/// literal must appear.
const options_window_bytes = 1024;

/// Largest source file the policy check will read.
const max_source_bytes = 16 * 1024 * 1024;

/// The needle is assembled at runtime so that this file does not match
/// itself.
const mapping_call_needle = "MemoryMap" ++ ".create";

/// Locate the `src` directory of this project. The test binary is normally
/// run from the build root, but fall back to the path of this source file so
/// the check also works when the binary is invoked directly.
fn findSourceRoot(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    const cwd = Io.Dir.cwd();
    if (cwd.openDir(io, "src", .{ .iterate = true })) |dir| {
        dir.close(io);
        return allocator.dupe(u8, "src");
    } else |_| {}

    // <root>/src/tests/mapping_policy.zig -> <root>/src
    const self_path = @src().file;
    const tests_dir = std.fs.path.dirname(self_path) orelse return error.SourceTreeNotFound;
    const src_dir = std.fs.path.dirname(tests_dir) orelse return error.SourceTreeNotFound;
    return allocator.dupe(u8, src_dir);
}

/// True when the options struct literal that follows a mapping call sets
/// `.populate` explicitly.
fn hasPopulateOption(text: []const u8, call_at: usize) bool {
    const window_end = @min(text.len, call_at + options_window_bytes);
    const window = text[call_at..window_end];
    return std.mem.indexOf(u8, window, ".populate = ") != null;
}

test "every memory mapping states its populate choice explicitly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const root = try findSourceRoot(allocator, io);
    defer allocator.free(root);

    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var found: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const text = entry.dir.readFileAlloc(
            io,
            entry.basename,
            allocator,
            .limited(max_source_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                std.debug.print("{s}: source file is too large to check\n", .{entry.basename});
                return err;
            },
            else => return err,
        };
        defer allocator.free(text);

        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, text, search_from, mapping_call_needle)) |at| {
            search_from = at + 1;
            found += 1;
            if (!hasPopulateOption(text, at)) {
                std.debug.print(
                    "{s}: memory mapping without an explicit .populate option\n",
                    .{entry.basename},
                );
                return error.MissingPopulateOption;
            }
        }
    }

    // Guard against the check silently passing because the search pattern
    // stopped matching anything.
    try std.testing.expect(found > 0);
}
