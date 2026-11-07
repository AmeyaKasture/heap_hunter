//! Integration tests that exercise the full parse -> index -> analysis flow
//! against real HPROF fixture files.
const std = @import("std");
const hprof = @import("../hprof.zig");
const Analysis = @import("../Analysis.zig");

fn loadIndex(allocator: std.mem.Allocator, relative_path: []const u8) !Analysis.Index {
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    var file = try dir.openFile(io, relative_path, .{});
    defer file.close(io);

    const file_len = try file.length(io);
    var mm = try std.Io.File.MemoryMap.create(io, file, .{
        .len = file_len,
        .protection = .{ .read = true, .write = false },
    });
    defer mm.destroy(io);

    var reader = try hprof.Reader.init(mm.memory);
    return try Analysis.buildIndex(allocator, &reader);
}

test "buildIndex finds heap-derived threads in real Java 21 dump" {
    const allocator = std.heap.page_allocator;
    var index = try loadIndex(allocator, "fixtures/heapforge.hprof");
    defer index.deinit();
}
