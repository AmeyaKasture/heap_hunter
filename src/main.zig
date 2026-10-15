const std = @import("std");
const Io = std.Io;

const build_options = @import("build_options");
const heaphunter = @import("heaphunter");
const MemTracker = @import("MemTracker.zig");
const log = @import("log");

pub const std_options: std.Options = .{
    .log_level = log.level,
    .allow_stack_tracing = build_options.stack_traces,
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    var tracker: MemTracker.Tracker = .{ .child = arena };
    const tracked = tracker.allocator();
    const args = try init.minimal.args.toSlice(tracked);
    const io = init.io;

    errdefer |err| {
        log.traceError(err);
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    const command = if (args.len > 1) args[1] else "<none>";
    log.debug("hunt startup: {d} args, command={s}", .{ args.len, command });

    log.debug("dispatching to runCli", .{});
    const result = heaphunter.runCli(tracked, init.io, args, stdout_writer, stderr_writer, init.environ_map);
    stderr_writer.flush() catch {};
    if (result) |_| {
        log.debug("runCli completed successfully", .{});
    } else |err| {
        if (heaphunter.Cli.isUserError(err)) {
            log.debug("runCli returned user error: {s}", .{@errorName(err)});
            stderr_writer.flush() catch {};
            std.process.exit(1);
        }
        log.err("runCli returned unexpected error: {s}", .{@errorName(err)});
        return @as(anyerror!void, err);
    }

    try stdout_writer.flush();
    try stderr_writer.flush();
}
