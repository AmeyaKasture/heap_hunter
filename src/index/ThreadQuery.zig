//! On-demand thread listing built from thread stack-trace metadata plus the
//! original source dump.
//!
//! The index stores only a small `thread_traces.bin` file with resolved stack
//! frames and thread-object mappings (see `ThreadTraces.zig`). This module
//! joins that metadata with per-thread GC roots in `roots.bin` and decodes the
//! live `java.lang.Thread`, `Thread$FieldHolder`, and name `String` objects
//! from the source dump via `IndexReader`.
//!
//! Frame strings are borrowed from the reader's parsed metadata; the reader
//! must outlive the returned `ThreadList`.
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");
const IndexReader = @import("IndexReader.zig");
const ThreadTraces = @import("ThreadTraces.zig");
const Threads = @import("../Threads.zig");

/// One decoded stack frame. Strings are borrowed from the reader.
pub const FrameView = struct {
    class_name: []const u8,
    method: []const u8,
    source: []const u8,
    line_number: i32,
};

/// One decoded thread. `name` is an owned copy; frame strings are borrowed
/// from the reader.
pub const ThreadView = struct {
    raw_id: hprof.Id,
    thread_serial: u32,
    name: []const u8, // owned
    state: []const u8, // borrowed static string
    priority: i32,
    daemon: bool,
    tid: i64,
    is_virtual: bool,
    stack_frames: []FrameView, // owned; strings borrowed from reader
};

/// The built thread list plus whatever storage it borrows.
pub const ThreadList = struct {
    allocator: std.mem.Allocator,
    threads: []ThreadView,

    pub fn deinit(self: *ThreadList) void {
        for (self.threads) |thread| {
            self.allocator.free(thread.name);
            self.allocator.free(thread.stack_frames);
        }
        self.allocator.free(self.threads);
    }
};

pub const Error = error{ OutOfMemory, InvalidSourceOffset, SourceNotAvailable };

/// Build the thread list. Iterates thread-object GC roots in `roots.bin`
/// order (which matches the heap-dump scan order of the thread objects).
pub fn build(allocator: std.mem.Allocator, reader: *const IndexReader.Reader) !ThreadList {
    var items = std.ArrayList(ThreadView).empty;
    errdefer {
        for (items.items) |thread| {
            allocator.free(thread.name);
            allocator.free(thread.stack_frames);
        }
        items.deinit(allocator);
    }

    const thread_object_root_kind = @intFromEnum(hprof.HeapSubtag.gc_root_thread_object);

    var seen_ordinals = std.AutoHashMap(u32, void).init(allocator);
    defer seen_ordinals.deinit();

    var i: u32 = 0;
    while (i < reader.rootCount()) : (i += 1) {
        const root = reader.rootRecordAt(i);
        if (root.root_kind != thread_object_root_kind) continue;

        const gop = try seen_ordinals.getOrPut(root.target_ordinal);
        if (gop.found_existing) continue;

        const raw_id = reader.rawIdForOrdinal(root.target_ordinal) orelse continue;

        const tt_root = reader.threadTraceRoot(raw_id);
        const thread_serial = if (tt_root) |r| r.thread_serial else root.thread_serial;

        var view = reader.decodeObject(root.target_ordinal) catch |err| switch (err) {
            error.InvalidSourceOffset, error.ObjectNotFound => continue,
            else => return err,
        };
        defer view.deinit(allocator);

        const fields = switch (view.payload) {
            .instance => |f| f,
            else => continue,
        };

        const is_virtual = isVirtualThreadOrSubclass(reader, view.class_raw_id);

        // Thread object fields.
        var name_id: hprof.Id = 0;
        var holder_id: hprof.Id = 0;
        var tid: i64 = 0;
        var virtual_state: i32 = -1;
        for (fields) |*f| {
            if (std.mem.eql(u8, f.name, "name")) {
                if (f.ref) |r| name_id = r.raw_id;
            } else if (std.mem.eql(u8, f.name, "holder")) {
                if (f.ref) |r| holder_id = r.raw_id;
            } else if (std.mem.eql(u8, f.name, "tid")) {
                if (f.primitive) |p| {
                    if (p == .long) tid = p.long;
                }
            } else if (is_virtual and std.mem.eql(u8, f.name, "state")) {
                if (f.primitive) |p| {
                    if (p == .int) virtual_state = p.int;
                }
            }
        }

        // FieldHolder fields (priority, daemon, threadStatus).
        var state: []const u8 = "unknown";
        var priority: i32 = 0;
        var daemon = false;
        if (holder_id != 0) {
            if (try decodeHolderFields(allocator, reader, holder_id)) |holder| {
                priority = holder.priority;
                daemon = holder.daemon;
                if (holder.thread_status >= 0) {
                    state = Threads.platformStateString(holder.thread_status);
                }
            }
        }

        if (is_virtual and virtual_state >= 0) {
            state = Threads.virtualStateString(virtual_state);
        }

        // Stack frames from the indexed trace metadata.
        const frames: []FrameView = blk: {
            if (tt_root) |r| {
                if (try buildFrames(allocator, reader, r.stack_trace_serial)) |built| {
                    break :blk built;
                }
            }
            break :blk try allocator.alloc(FrameView, 0);
        };
        errdefer allocator.free(frames);

        const name = try decodeStringText(allocator, reader, name_id);
        errdefer allocator.free(name);

        try items.append(allocator, .{
            .raw_id = raw_id,
            .thread_serial = thread_serial,
            .name = name,
            .state = state,
            .priority = priority,
            .daemon = daemon,
            .tid = tid,
            .is_virtual = is_virtual,
            .stack_frames = frames,
        });
    }

    return .{
        .allocator = allocator,
        .threads = try items.toOwnedSlice(allocator),
    };
}

const HolderFields = struct {
    priority: i32,
    daemon: bool,
    /// -1 when no `threadStatus` field was present.
    thread_status: i32,
};

fn decodeHolderFields(
    allocator: std.mem.Allocator,
    reader: *const IndexReader.Reader,
    holder_id: hprof.Id,
) !?HolderFields {
    const ordinal = reader.ordinalForRawId(holder_id) orelse return null;
    var view = reader.decodeObject(ordinal) catch |err| switch (err) {
        error.InvalidSourceOffset, error.SourceNotAvailable, error.ObjectNotFound => return null,
        else => return err,
    };
    defer view.deinit(allocator);

    const fields = switch (view.payload) {
        .instance => |f| f,
        else => return null,
    };

    var result = HolderFields{ .priority = 0, .daemon = false, .thread_status = -1 };
    for (fields) |*f| {
        if (std.mem.eql(u8, f.name, "priority")) {
            if (f.primitive) |p| {
                if (p == .int) result.priority = p.int;
            }
        } else if (std.mem.eql(u8, f.name, "daemon")) {
            if (f.primitive) |p| {
                if (p == .boolean) result.daemon = p.boolean;
            }
        } else if (std.mem.eql(u8, f.name, "threadStatus")) {
            if (f.primitive) |p| {
                if (p == .int) result.thread_status = p.int;
            }
        }
    }
    return result;
}

/// Decode the frames of the stack trace with `serial`. Returns null when the
/// trace is not recorded; frames missing from the frame table are skipped.
fn buildFrames(
    allocator: std.mem.Allocator,
    reader: *const IndexReader.Reader,
    serial: u32,
) !?[]FrameView {
    const trace = reader.traceBySerial(serial) orelse return null;

    var frames = std.ArrayList(FrameView).empty;
    errdefer frames.deinit(allocator);

    for (trace.frame_indices) |frame_idx| {
        if (frame_idx == ThreadTraces.missing_frame_index) {
            try frames.append(allocator, .{
                .class_name = "<unknown>",
                .method = "<unknown>",
                .source = "<?>",
                .line_number = -1,
            });
            continue;
        }
        const frame = reader.frameAt(frame_idx);
        try frames.append(allocator, .{
            .class_name = frame.class_name,
            .method = frame.method_name,
            .source = frame.source_name,
            .line_number = frame.line_number,
        });
    }

    return try frames.toOwnedSlice(allocator);
}

/// Decode the text of a `java.lang.String` object. Unresolvable ids yield
/// `"<unresolved>"` rather than an error, mirroring the scanner-side behavior.
fn decodeStringText(allocator: std.mem.Allocator, reader: *const IndexReader.Reader, raw_id: hprof.Id) ![]u8 {
    const fallback = "<unresolved>";
    if (raw_id == 0) return allocator.dupe(u8, fallback);
    const ordinal = reader.ordinalForRawId(raw_id) orelse return allocator.dupe(u8, fallback);

    var view = reader.decodeObject(ordinal) catch return allocator.dupe(u8, fallback);
    defer view.deinit(allocator);

    if (view.string) |s| {
        return allocator.dupe(u8, s);
    }
    return allocator.dupe(u8, fallback);
}

fn isVirtualThreadOrSubclass(reader: *const IndexReader.Reader, class_id: hprof.Id) bool {
    var cur = class_id;
    while (cur != 0) {
        if (std.mem.eql(u8, reader.className(cur), "java/lang/VirtualThread")) return true;
        const info = reader.classInfo(cur) orelse break;
        cur = info.super_class_id;
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Output
// ─────────────────────────────────────────────────────────────────────────────

/// Plain-text output matching the historical overview thread listing.
pub fn print(list: *const ThreadList, writer: *Io.Writer) !void {
    for (list.threads) |thread| {
        if (thread.is_virtual) {
            try writer.print("Thread: {s} (virtual)\n", .{thread.name});
        } else {
            try writer.print("Thread: {s}\n", .{thread.name});
        }
        try writer.print("  State:    {s}\n", .{thread.state});
        try writer.print("  Priority: {d}\n", .{thread.priority});
        try writer.print("  Daemon:   {s}\n", .{if (thread.daemon) "true" else "false"});
        try writer.print("  TID:      {d}\n", .{thread.tid});

        if (thread.stack_frames.len > 0) {
            try writer.writeAll("  Stack trace:\n");
            for (thread.stack_frames) |frame| {
                if (frame.line_number < 0) {
                    try writer.print("    at {s}.{s}({s})\n", .{ frame.class_name, frame.method, frame.source });
                } else {
                    try writer.print("    at {s}.{s}({s}:{d})\n", .{ frame.class_name, frame.method, frame.source, frame.line_number });
                }
            }
        } else {
            try writer.writeAll("  Stack trace: <none>\n");
        }
        try writer.writeAll("\n");
    }
}

/// JSON output: `{ "threads": [ ... ] }`.
pub fn writeJson(list: *const ThreadList, writer: *Io.Writer) !void {
    try writer.writeAll("{\"threads\":[");
    for (list.threads, 0..) |thread, i| {
        if (i > 0) try writer.writeByte(',');
        try writeThreadJson(writer, thread);
    }
    try writer.writeAll("]}\n");
}

fn writeThreadJson(writer: *Io.Writer, thread: ThreadView) !void {
    try writer.writeAll("{\"id\":\"0x");
    try writer.print("{x}", .{thread.raw_id});
    try writer.writeAll("\",\"thread_serial\":");
    try writer.print("{d}", .{thread.thread_serial});
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, thread.name);
    try writer.writeAll(",\"state\":");
    try writeJsonString(writer, thread.state);
    try writer.print(",\"priority\":{d}", .{thread.priority});
    try writer.print(",\"daemon\":{}", .{thread.daemon});
    try writer.print(",\"tid\":{d}", .{thread.tid});
    try writer.print(",\"virtual\":{}", .{thread.is_virtual});
    try writer.writeAll(",\"stack_frames\":[");
    for (thread.stack_frames, 0..) |frame, fi| {
        if (fi > 0) try writer.writeByte(',');
        try writer.writeAll("{\"class_name\":");
        try writeJsonString(writer, frame.class_name);
        try writer.writeAll(",\"method\":");
        try writeJsonString(writer, frame.method);
        try writer.writeAll(",\"source\":");
        try writeJsonString(writer, frame.source);
        try writer.print(",\"line_number\":{d}}}", .{frame.line_number});
    }
    try writer.writeAll("]}");
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
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}
