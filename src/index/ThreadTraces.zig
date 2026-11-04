//! Thread stack-trace metadata for the persistent index.
//!
//! This module implements both:
//!
//!   1. A collector used by the Stage 1 scanner to capture top-level
//!      `FRAME`, `TRACE`, and thread-object GC root records, and
//!   2. The binary file format for `thread_traces.bin`, the small index
//!      file that stores resolved frame metadata (class/method/source
//!      names), trace -> frame mappings, and thread-object -> stack-trace
//!      serial mappings.
//!
//! Full thread objects, field holders, and name strings are NOT stored here;
//! they are decoded on demand from the original source dump at query time
//! (see `ThreadQuery.zig`). Keeping this file small means indexing stays
//! allocation-bounded while thread queries still show full stack traces.
//!
//! File layout (all little-endian):
//!
//!   header (24 bytes):
//!     magic:    4 bytes "HTHR"
//!     version:  u16
//!     reserved: u16 (zero)
//!     n_strings:      u32
//!     n_frames:       u32
//!     n_traces:       u32
//!     n_thread_roots: u32
//!
//!   strings (repeated `n_strings` times):
//!     len:   u32
//!     bytes: u8[len]
//!
//!   frames (repeated `n_frames` times, 24 bytes each):
//!     frame_id:         u64
//!     class_name_idx:   u32  (index into strings)
//!     method_name_idx:  u32  (index into strings)
//!     source_name_idx:  u32  (index into strings)
//!     line_number:      i32
//!
//!   traces (repeated `n_traces` times):
//!     serial:        u32
//!     thread_serial: u32
//!     frame_count:   u32
//!     frame_indices: u32[frame_count]  (indices into frames; 0xFFFFFFFF
//!                                      marks a frame missing from the
//!                                      frame table)
//!
//!   thread_roots (repeated `n_thread_roots` times, 16 bytes each):
//!     thread_object_id:   u64
//!     thread_serial:      u32
//!     stack_trace_serial: u32
const std = @import("std");
const Io = std.Io;
const hprof = @import("../hprof.zig");

pub const Error = error{
    InvalidThreadTracesFile,
    OutOfMemory,
    WriteFailed,
};

pub const magic = [4]u8{ 'H', 'T', 'R', 'C' };
pub const format_version: u16 = 1;
pub const header_size: usize = 4 + 2 + 2 + 4 + 4 + 4 + 4;
pub const frame_record_size: usize = 8 + 4 + 4 + 4 + 4;
pub const thread_root_record_size: usize = 16;

/// Sentinel for a trace frame that had no matching FRAME record.
pub const missing_frame_index: u32 = 0xFFFFFFFF;

/// One resolved stack frame as stored in the file. Frame strings are
/// borrowed slices into the parsed data buffer (see `Parsed`).
pub const FrameEntry = struct {
    frame_id: hprof.Id,
    class_name: []const u8,
    method_name: []const u8,
    source_name: []const u8,
    line_number: i32,
};

/// One `STACK_TRACE` record as stored in the file. `frame_indices` is a
/// borrowed slice into the parsed data buffer.
pub const TraceEntry = struct {
    serial: u32,
    thread_serial: u32,
    frame_indices: []const u32,
};

/// Mapping from a thread object to its recorded stack trace.
pub const ThreadRoot = struct {
    thread_object_id: hprof.Id,
    thread_serial: u32,
    stack_trace_serial: u32,
};

// ─────────────────────────────────────────────────────────────────────────────
// Collector (index-time)
// ─────────────────────────────────────────────────────────────────────────────

/// Raw trace captured during scanning: frame ids in declaration order,
/// resolved to indices only when the file is serialized.
const RawTrace = struct {
    thread_serial: u32,
    frame_ids: []const hprof.Id,
};

/// Captures FRAME / TRACE / thread-object root records during the Stage 1
/// scan. The scanner resolves names and serializes the collected data to
/// `thread_traces.bin` after the heap walk completes.
pub const Collector = struct {
    allocator: std.mem.Allocator,
    frames: std.AutoHashMap(hprof.Id, hprof.Frame),
    traces: std.AutoHashMap(u32, RawTrace),
    thread_roots: std.AutoHashMap(hprof.Id, ThreadRoot),

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{
            .allocator = allocator,
            .frames = std.AutoHashMap(hprof.Id, hprof.Frame).init(allocator),
            .traces = std.AutoHashMap(u32, RawTrace).init(allocator),
            .thread_roots = std.AutoHashMap(hprof.Id, ThreadRoot).init(allocator),
        };
    }

    pub fn deinit(self: *Collector) void {
        var it = self.traces.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.frame_ids);
        }
        self.traces.deinit();
        self.frames.deinit();
        self.thread_roots.deinit();
    }

    /// Capture a top-level `FRAME` record.
    pub fn addFrame(self: *Collector, frame: hprof.Frame) !void {
        try self.frames.put(frame.id, frame);
    }

    /// Capture a top-level `TRACE` record, decoding its frame-id list.
    pub fn addTrace(self: *Collector, trace: hprof.Trace, id_size: u32) Error!void {
        const frame_ids = try self.allocator.alloc(hprof.Id, trace.frame_count);
        errdefer self.allocator.free(frame_ids);

        var cursor = hprof.Cursor.init(trace.raw);
        for (0..trace.frame_count) |i| {
            frame_ids[i] = cursor.readId(id_size) catch return error.InvalidThreadTracesFile;
        }

        const old = self.traces.fetchPut(trace.serial, .{
            .thread_serial = trace.thread_serial,
            .frame_ids = frame_ids,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (old) |kv| {
            self.allocator.free(kv.value.frame_ids);
        }
    }

    /// Capture a `GC_ROOT_THREAD_OBJECT` sub-record's stack-trace mapping.
    pub fn addThreadRoot(
        self: *Collector,
        thread_object_id: hprof.Id,
        thread_serial: u32,
        stack_trace_serial: u32,
    ) !void {
        try self.thread_roots.put(thread_object_id, .{
            .thread_object_id = thread_object_id,
            .thread_serial = thread_serial,
            .stack_trace_serial = stack_trace_serial,
        });
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Serialization (index-time)
// ─────────────────────────────────────────────────────────────────────────────

/// A frame whose names have already been resolved against the class table.
/// String slices are borrowed for the duration of the `serialize` call.
pub const ResolvedFrame = struct {
    frame_id: hprof.Id,
    class_name: []const u8,
    method_name: []const u8,
    source_name: []const u8,
    line_number: i32,
};

/// A trace whose frame ids have already been mapped to frame-table indices.
/// `frame_indices` is borrowed for the duration of the `serialize` call.
pub const TraceOut = struct {
    serial: u32,
    thread_serial: u32,
    frame_indices: []const u32,
};

const Interner = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(u32),
    strings: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) Interner {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(u32).init(allocator),
            .strings = std.ArrayList([]const u8).empty,
        };
    }

    fn deinit(self: *Interner) void {
        self.map.deinit();
        self.strings.deinit(self.allocator);
    }

    fn intern(self: *Interner, s: []const u8) !u32 {
        if (self.map.get(s)) |idx| {
            return idx;
        }
        const idx = @as(u32, @intCast(self.strings.items.len));
        // The map holds borrowed key slices for the lifetime of this call;
        // serialize copies the referenced bytes out to the writer immediately.
        try self.map.put(s, idx);
        try self.strings.append(self.allocator, s);
        return idx;
    }
};

/// Serialize the thread trace metadata to `writer`.
///
/// `frames` must already be sorted by `frame_id` and every frame referenced
/// by `traces.frame_indices` must satisfy `index < frames.len`.
pub fn serialize(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    frames: []const ResolvedFrame,
    traces: []const TraceOut,
    thread_roots: []const ThreadRoot,
) Error!void {
    var interner = Interner.init(allocator);
    defer interner.deinit();

    // Intern all frame strings first so indices are stable.
    for (frames) |frame| {
        _ = try interner.intern(frame.class_name);
        _ = try interner.intern(frame.method_name);
        _ = try interner.intern(frame.source_name);
    }

    try writeBytes(writer, &magic);
    try writeU16(writer, format_version);
    try writeU16(writer, 0); // reserved
    try writeU32(writer, @intCast(interner.strings.items.len));
    try writeU32(writer, @intCast(frames.len));
    try writeU32(writer, @intCast(traces.len));
    try writeU32(writer, @intCast(thread_roots.len));

    for (interner.strings.items) |s| {
        try writeU32(writer, @intCast(s.len));
        try writer.writeAll(s);
    }

    for (frames) |frame| {
        try writeU64(writer, frame.frame_id);
        try writeU32(writer, try interner.intern(frame.class_name));
        try writeU32(writer, try interner.intern(frame.method_name));
        try writeU32(writer, try interner.intern(frame.source_name));
        try writeI32(writer, frame.line_number);
    }

    for (traces) |trace| {
        try writeU32(writer, trace.serial);
        try writeU32(writer, trace.thread_serial);
        try writeU32(writer, @intCast(trace.frame_indices.len));
        for (trace.frame_indices) |idx| {
            try writeU32(writer, idx);
        }
    }

    for (thread_roots) |root| {
        try writeU64(writer, root.thread_object_id);
        try writeU32(writer, root.thread_serial);
        try writeU32(writer, root.stack_trace_serial);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Parsing (query-time and validation)
// ─────────────────────────────────────────────────────────────────────────────

/// A decoded view of `thread_traces.bin`. Owns a copy of the file bytes plus
/// per-section lookup arrays; string and index slices borrow from `data`.
pub const Parsed = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    /// String table; entries borrow from `data`.
    strings: [][]const u8,
    frames: []FrameEntry,
    traces: []TraceEntry,
    thread_roots: []ThreadRoot,
    trace_by_serial: std.AutoHashMap(u32, usize),
    root_by_object: std.AutoHashMap(hprof.Id, usize),

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.data);
        self.allocator.free(self.strings);
        self.allocator.free(self.frames);
        for (self.traces) |trace| {
            self.allocator.free(trace.frame_indices);
        }
        self.allocator.free(self.traces);
        self.allocator.free(self.thread_roots);
        self.trace_by_serial.deinit();
        self.root_by_object.deinit();
    }

    /// Parse and structurally validate a `thread_traces.bin` buffer.
    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) Error!Parsed {
        return parseOwnedBytes(allocator, raw);
    }

    /// An empty, deinit-able placeholder for when no metadata is loaded yet.
    pub fn empty(allocator: std.mem.Allocator) Parsed {
        return .{
            .allocator = allocator,
            .data = &.{},
            .strings = &.{},
            .frames = &.{},
            .traces = &.{},
            .thread_roots = &.{},
            .trace_by_serial = std.AutoHashMap(u32, usize).init(allocator),
            .root_by_object = std.AutoHashMap(hprof.Id, usize).init(allocator),
        };
    }
};

fn parseOwnedBytes(allocator: std.mem.Allocator, raw: []const u8) Error!Parsed {
    const invalid = error.InvalidThreadTracesFile;

    if (raw.len < header_size) return invalid;
    if (!std.mem.eql(u8, raw[0..4], &magic)) return invalid;
    const version = std.mem.readInt(u16, raw[4..6], .little);
    if (version != format_version) return invalid;
    const n_strings = std.mem.readInt(u32, raw[8..12], .little);
    const n_frames = std.mem.readInt(u32, raw[12..16], .little);
    const n_traces = std.mem.readInt(u32, raw[16..20], .little);
    const n_thread_roots = std.mem.readInt(u32, raw[20..24], .little);

    const data = try allocator.dupe(u8, raw);
    errdefer allocator.free(data);

    // Strings.
    var offset: usize = header_size;
    const strings = try allocator.alloc([]const u8, n_strings);
    var n_strings_read: usize = 0;
    errdefer allocator.free(strings);
    for (0..n_strings) |i| {
        if (offset + 4 > data.len) return invalid;
        const len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        if (offset + len > data.len) return invalid;
        strings[i] = data[offset..][0..len];
        offset += len;
        n_strings_read = i + 1;
    }

    // Frames.
    if (offset + n_frames * frame_record_size > data.len) return invalid;
    const frames = try allocator.alloc(FrameEntry, n_frames);
    var n_frames_read: usize = 0;
    errdefer allocator.free(frames);
    for (0..n_frames) |i| {
        const frame_id = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;
        const class_idx = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        const method_idx = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        const source_idx = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        const line_number: i32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;
        if (class_idx >= n_strings_read or method_idx >= n_strings_read or source_idx >= n_strings_read) return invalid;
        frames[i] = .{
            .frame_id = frame_id,
            .class_name = strings[class_idx],
            .method_name = strings[method_idx],
            .source_name = strings[source_idx],
            .line_number = line_number,
        };
        n_frames_read = i + 1;
    }

    // Traces.
    var n_traces_read: usize = 0;
    const traces = try allocator.alloc(TraceEntry, n_traces);
    errdefer {
        for (traces[0..n_traces_read]) |t| allocator.free(t.frame_indices);
        allocator.free(traces);
    }
    for (0..n_traces) |i| {
        if (offset + 12 > data.len) return invalid;
        const serial = std.mem.readInt(u32, data[offset..][0..4], .little);
        const thread_serial = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
        const frame_count = std.mem.readInt(u32, data[offset + 8 ..][0..4], .little);
        offset += 12;
        if (offset + frame_count * 4 > data.len) return invalid;
        const indices = try allocator.alloc(u32, frame_count);
        errdefer allocator.free(indices);
        for (0..frame_count) |j| {
            const idx = std.mem.readInt(u32, data[offset + j * 4 ..][0..4], .little);
            if (idx != missing_frame_index and idx >= n_frames_read) return invalid;
            indices[j] = idx;
        }
        offset += frame_count * 4;
        traces[i] = .{
            .serial = serial,
            .thread_serial = thread_serial,
            .frame_indices = indices,
        };
        n_traces_read = i + 1;
    }

    // Thread roots.
    if (offset + n_thread_roots * thread_root_record_size > data.len) return invalid;
    const thread_roots = try allocator.alloc(ThreadRoot, n_thread_roots);
    var n_roots_read: usize = 0;
    errdefer allocator.free(thread_roots);
    for (0..n_thread_roots) |i| {
        const thread_object_id = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;
        const thread_serial = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        const stack_trace_serial = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        thread_roots[i] = .{
            .thread_object_id = thread_object_id,
            .thread_serial = thread_serial,
            .stack_trace_serial = stack_trace_serial,
        };
        n_roots_read = i + 1;
    }

    // Lookup indices.
    var trace_by_serial = std.AutoHashMap(u32, usize).init(allocator);
    errdefer trace_by_serial.deinit();
    for (traces, 0..) |trace, i| {
        try trace_by_serial.put(trace.serial, i);
    }
    var root_by_object = std.AutoHashMap(hprof.Id, usize).init(allocator);
    errdefer root_by_object.deinit();
    for (thread_roots[0..n_roots_read], 0..) |root, i| {
        try root_by_object.put(root.thread_object_id, i);
    }

    return .{
        .allocator = allocator,
        .data = data,
        .strings = strings,
        .frames = frames,
        .traces = traces,
        .thread_roots = thread_roots,
        .trace_by_serial = trace_by_serial,
        .root_by_object = root_by_object,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn writeBytes(writer: *Io.Writer, bytes: []const u8) Error!void {
    writer.writeAll(bytes) catch return error.WriteFailed;
}

fn writeU16(writer: *Io.Writer, v: u16) Error!void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try writeBytes(writer, &buf);
}

fn writeU32(writer: *Io.Writer, v: u32) Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try writeBytes(writer, &buf);
}

fn writeU64(writer: *Io.Writer, v: u64) Error!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try writeBytes(writer, &buf);
}

fn writeI32(writer: *Io.Writer, v: i32) Error!void {
    try writeU32(writer, @bitCast(v));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

fn serializeToString(
    allocator: std.mem.Allocator,
    frames: []const ResolvedFrame,
    traces: []const TraceOut,
    thread_roots: []const ThreadRoot,
) ![]u8 {
    var buf: Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try serialize(allocator, &buf.writer, frames, traces, thread_roots);
    return try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]);
}

fn sampleSerialized(allocator: std.mem.Allocator) ![]u8 {
    const frames = [_]ResolvedFrame{
        .{ .frame_id = 0x11, .class_name = "com.example.Foo", .method_name = "run", .source_name = "Foo.java", .line_number = 42 },
        .{ .frame_id = 0x12, .class_name = "java.lang.Thread", .method_name = "runWith", .source_name = "Thread.java", .line_number = 1596 },
    };
    const trace_indices = [_]u32{ 0, 1 };
    const traces = [_]TraceOut{
        .{ .serial = 7, .thread_serial = 3, .frame_indices = &trace_indices },
    };
    const thread_roots = [_]ThreadRoot{
        .{ .thread_object_id = 0xA000, .thread_serial = 3, .stack_trace_serial = 7 },
    };
    return serializeToString(allocator, &frames, &traces, &thread_roots);
}

test "serialize and parse round-trip" {
    const allocator = std.testing.allocator;
    const bytes = try sampleSerialized(allocator);
    defer allocator.free(bytes);

    var parsed = try Parsed.parse(allocator, bytes);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.frames.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.traces.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.thread_roots.len);

    const frame = parsed.frames[0];
    try std.testing.expectEqual(@as(hprof.Id, 0x11), frame.frame_id);
    try std.testing.expectEqualStrings("com.example.Foo", frame.class_name);
    try std.testing.expectEqualStrings("run", frame.method_name);
    try std.testing.expectEqualStrings("Foo.java", frame.source_name);
    try std.testing.expectEqual(@as(i32, 42), frame.line_number);

    const trace = parsed.trace_by_serial.get(7).?;
    try std.testing.expectEqual(@as(u32, 3), parsed.traces[trace].thread_serial);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, parsed.traces[trace].frame_indices);

    const root = parsed.root_by_object.get(0xA000).?;
    try std.testing.expectEqual(@as(u32, 7), parsed.thread_roots[root].stack_trace_serial);
}

test "empty metadata parses" {
    const allocator = std.testing.allocator;
    const bytes = try serializeToString(allocator, &.{}, &.{}, &.{});
    defer allocator.free(bytes);

    var parsed = try Parsed.parse(allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.frames.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.traces.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.thread_roots.len);
}

test "parse rejects bad magic" {
    const allocator = std.testing.allocator;
    const bytes = try sampleSerialized(allocator);
    defer allocator.free(bytes);

    var bad = try allocator.dupe(u8, bytes);
    defer allocator.free(bad);
    bad[0] = 'X';

    try std.testing.expectError(error.InvalidThreadTracesFile, Parsed.parse(allocator, bad));
}

test "parse rejects bad version" {
    const allocator = std.testing.allocator;
    const bytes = try sampleSerialized(allocator);
    defer allocator.free(bytes);

    var bad = try allocator.dupe(u8, bytes);
    defer allocator.free(bad);
    bad[4] = 99;

    try std.testing.expectError(error.InvalidThreadTracesFile, Parsed.parse(allocator, bad));
}

test "parse rejects truncated buffer" {
    const allocator = std.testing.allocator;
    const bytes = try sampleSerialized(allocator);
    defer allocator.free(bytes);

    try std.testing.expectError(error.InvalidThreadTracesFile, Parsed.parse(allocator, bytes[0..10]));
}

test "parse rejects out-of-range string index" {
    const allocator = std.testing.allocator;
    const bytes = try sampleSerialized(allocator);
    defer allocator.free(bytes);

    var bad = try allocator.dupe(u8, bytes);
    defer allocator.free(bad);
    // Setting n_strings to 0 makes the string walk read zero entries, so any
    // string index referenced by the frame records is out of range.
    std.mem.writeInt(u32, bad[8..12], 0, .little);

    try std.testing.expectError(error.InvalidThreadTracesFile, Parsed.parse(allocator, bad));
}

test "parse rejects out-of-range frame index in trace" {
    const allocator = std.testing.allocator;
    const frames = [_]ResolvedFrame{
        .{ .frame_id = 1, .class_name = "A", .method_name = "M", .source_name = "S.java", .line_number = 1 },
    };
    const bad_indices = [_]u32{5}; // n_frames == 1
    const traces = [_]TraceOut{
        .{ .serial = 1, .thread_serial = 1, .frame_indices = &bad_indices },
    };
    const bytes = try serializeToString(allocator, &frames, &traces, &.{});
    defer allocator.free(bytes);

    try std.testing.expectError(error.InvalidThreadTracesFile, Parsed.parse(allocator, bytes));
}
