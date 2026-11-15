//! Compile-time-gated timing instrumentation for development and testing.
//!
//! Enabled by building with `-Dprofile` (on by default for Debug builds and
//! stripped from release binaries entirely). When `build_enabled` is false,
//! every API call compiles to a no-op and none of the timing state is emitted.
//!
//! Usage:
//!
//!     var span = profiling.begin(io, "scan");
//!     defer span.end(io);
//!
//! For per-record accumulation inside hot loops, keep one `Acc` per bucket at
//! the phase scope and start/stop it around each record:
//!
//!     var acc: profiling.Acc = .{};
//!     while (nextRecord()) |rec| {
//!         acc.start(io, "instances");
//!         defer acc.stop(io);
//!         ...
//!     }
//!
//! Results are printed as an indented tree to stderr via `printTimings`.
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

/// Comptime kill switch: false in release builds, where all instrumentation
/// is dead-code-eliminated and the `--profile` flag does not exist.
pub const build_enabled: bool = build_options.profile;

/// Runtime toggle, controlled by the `--profile` CLI flag (only meaningful
/// when `build_enabled` is true).
var enabled: bool = false;

const max_records = 128;
const max_depth = 16;

const Kind = enum { span, acc };

const Record = struct {
    label: []const u8,
    kind: Kind,
    parent: ?u16 = null,
    ns: u64 = 0,
    count: u64 = 0,
};

var records: [max_records]Record = undefined;
var n_records: usize = 0;

/// Index stack of currently open spans (into `records`).
var span_stack: [max_depth]u16 = undefined;
var depth: usize = 0;

pub fn setEnabled(v: bool) void {
    if (!build_enabled) return;
    enabled = v;
    if (v) reset();
}

pub fn isEnabled() bool {
    return build_enabled and enabled;
}

pub fn reset() void {
    if (!build_enabled) return;
    n_records = 0;
    depth = 0;
}

pub const Span = struct {
    idx: u16 = 0,
    start_ns: i128 = 0,
    active: bool = false,
    pushed: bool = false,

    pub fn end(self: *Span, io: Io) void {
        if (!build_enabled) return;
        if (!self.active) return;
        const end_ns = Io.Timestamp.now(io, .awake).nanoseconds;
        const delta_ns: u64 = @intCast(@max(end_ns - self.start_ns, 0));
        records[self.idx].ns += delta_ns;
        if (self.pushed and depth > 0) depth -= 1;
        self.active = false;
    }
};

/// Opens a timed span. Close it with `defer span.end(io)`.
pub fn begin(io: Io, comptime label: []const u8) Span {
    if (!build_enabled) return .{};
    if (!enabled) return .{};

    const parent: ?u16 = if (depth > 0) span_stack[depth - 1] else null;
    const idx = findOrAdd(label, .span, parent) orelse return .{};
    var pushed = false;
    if (depth < max_depth) {
        span_stack[depth] = idx;
        depth += 1;
        pushed = true;
    }
    return .{
        .idx = idx,
        .start_ns = Io.Timestamp.now(io, .awake).nanoseconds,
        .active = true,
        .pushed = pushed,
    };
}

/// Accumulator bucket for repeated sub-phases inside hot loops. The record
/// index is cached after the first `start`, so steady-state cost is one
/// timestamp pair per record.
pub const Acc = struct {
    idx: u16 = 0,
    start_ns: i128 = 0,
    active: bool = false,
    registered: bool = false,

    pub fn start(self: *Acc, io: Io, comptime label: []const u8) void {
        if (!build_enabled or !enabled) return;
        if (!self.registered) {
            const parent: ?u16 = if (depth > 0) span_stack[depth - 1] else null;
            self.idx = findOrAdd(label, .acc, parent) orelse return;
            self.registered = true;
        }
        self.start_ns = Io.Timestamp.now(io, .awake).nanoseconds;
        self.active = true;
    }

    pub fn stop(self: *Acc, io: Io) void {
        if (!build_enabled) return;
        if (!self.active) return;
        const end_ns = Io.Timestamp.now(io, .awake).nanoseconds;
        const delta_ns: u64 = @intCast(@max(end_ns - self.start_ns, 0));
        records[self.idx].ns += delta_ns;
        records[self.idx].count += 1;
        self.active = false;
    }
};

fn findOrAdd(label: []const u8, kind: Kind, parent: ?u16) ?u16 {
    for (records[0..n_records], 0..) |rec, i| {
        if (rec.kind == kind and rec.parent == parent and std.mem.eql(u8, rec.label, label)) {
            return @intCast(i);
        }
    }
    if (n_records >= max_records) return null;
    records[n_records] = .{ .label = label, .kind = kind, .parent = parent };
    n_records += 1;
    return @intCast(n_records - 1);
}

/// Prints the collected timings as an indented tree, plus a TOTAL row over
/// top-level spans, to `writer`. No-op when profiling is disabled.
pub fn printTimings(writer: *Io.Writer) !void {
    if (!build_enabled) return;
    if (!isEnabled() or n_records == 0) return;

    try writer.writeAll("timings:\n");
    for (records[0..n_records]) |rec| {
        try writer.print("  {s}{s}", .{ indentOf(rec), rec.label });
        if (rec.kind == .acc and rec.count > 0) {
            try writer.print(" (x{d})", .{rec.count});
        }
        try writer.print(": {d} ms\n", .{rec.ns / std.time.ns_per_ms});
    }

    var total: u64 = 0;
    for (records[0..n_records]) |rec| {
        if (rec.parent == null and rec.kind == .span) total += rec.ns;
    }
    if (total > 0) {
        try writer.print("  total: {d} ms\n", .{total / std.time.ns_per_ms});
    }
}

fn indentOf(rec: Record) []const u8 {
    const spaces_per_level = 2;
    var level: usize = 0;
    var p = rec.parent;
    while (p) |parent_idx| {
        level += 1;
        p = records[parent_idx].parent;
    }
    return (" " ** (max_depth * spaces_per_level))[0 .. level * spaces_per_level];
}
