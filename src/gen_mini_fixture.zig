const std = @import("std");
const HprofBuilder = @import("tests/HprofBuilder.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();
    var b = HprofBuilder.Builder.init(allocator, 4);
    defer b.deinit();
    const Id = HprofBuilder.Id;
    _ = Id;

    try b.header(0x123456789);
    try b.utf8(0x100, "Node");
    try b.utf8(0x101, "f");
    try b.utf8(0x102, "Data");
    try b.utf8(0x103, "payload");
    try b.utf8(0x104, "java/lang/Object");
    try b.loadClass(1, 0x10000, 0x100);
    try b.loadClass(2, 0x10001, 0x102);

    var heap = try b.heapDump();
    _ = try heap.rootUnknown(0x2000);
    _ = try heap.classDump(.{
        .class_id = 0x10000,
        .super_class_id = 0,
        .instance_size = 8,
        .instance_fields = &.{
            .{ .name_id = 0x101, .type = .object },
        },
    });
    _ = try heap.classDump(.{
        .class_id = 0x10001,
        .super_class_id = 0,
        .instance_size = 4,
        .instance_fields = &.{
            .{ .name_id = 0x103, .type = .object },
        },
    });
    // A(0x2000, Node 8B) -> B(0x2001, Node 8B) -> C(0x2002, Data 4B); D(0x2003) unreachable.
    _ = try heap.instanceDump(0x2000, 0x10000, &[_]u8{ 0x00, 0x00, 0x20, 0x01 });
    _ = try heap.instanceDump(0x2001, 0x10000, &[_]u8{ 0x00, 0x00, 0x20, 0x02 });
    _ = try heap.instanceDump(0x2002, 0x10001, &[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    _ = try heap.instanceDump(0x2003, 0x10001, &[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    heap.end();

    const bytes = try b.finish();
    defer allocator.free(bytes);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var write_buf: [65536]u8 = undefined;
    const file = try std.Io.Dir.cwd().createFile(io, "/tmp/opencode/mini.hprof", .{});
    defer file.close(io);
    var writer: std.Io.File.Writer = .init(file, io, &write_buf);
    try writer.interface.writeAll(bytes);
    try writer.flush();
    std.debug.print("wrote {d} bytes\n", .{bytes.len});
}
