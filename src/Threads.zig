//! Heap-derived thread discovery and printing.
const std = @import("std");
const hprof = @import("hprof.zig");
const IndexTypes = @import("IndexTypes.zig");

pub const Thread = struct {
    object_id: hprof.Id,
    serial: u32,
    name: []const u8,
    name_object_id: hprof.Id,
    state: []const u8,
    priority: i32,
    daemon: bool,
    tid: i64,
    virtual: bool,
    stack_trace_serial: u32,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    id_size: u32,
    utf8: *const std.AutoHashMap(hprof.Id, []const u8),
    class_names: *const std.AutoHashMap(hprof.Id, hprof.Id),
    classes: *const std.AutoHashMap(hprof.Id, IndexTypes.ClassInfo),
    loaded: *const std.AutoHashMap(u32, IndexTypes.LoadClassEntry),
};

const ThreadRoot = struct {
    serial: u32,
    stack_trace_serial: u32,
};

const TraceInfo = struct {
    thread_serial: u32,
    frames: []const hprof.Id,
};

const StringInfo = struct {
    array_id: hprof.Id,
    coder: ?u8,
};

const PrimArrayInfo = struct {
    element_type: hprof.PrimitiveType,
    bytes: []const u8,
};

const FieldValue = struct {
    name: []const u8,
    value: hprof.Value,
};

const PendingInstance = struct {
    class_id: hprof.Id,
    bytes: []const u8,
};

pub const ThreadIndex = struct {
    allocator: std.mem.Allocator,
    id_size: u32,

    frames: std.AutoHashMap(hprof.Id, hprof.Frame),
    traces: std.AutoHashMap(u32, TraceInfo),

    thread_roots: std.AutoHashMap(hprof.Id, ThreadRoot),
    threads: std.ArrayList(Thread),
    thread_by_object: std.AutoHashMap(hprof.Id, usize),

    holder_to_thread: std.AutoHashMap(hprof.Id, usize),
    pending_holders: std.AutoHashMap(hprof.Id, PendingInstance),

    string_values: std.AutoHashMap(hprof.Id, StringInfo),
    prim_arrays: std.AutoHashMap(hprof.Id, PrimArrayInfo),

    pub fn init(allocator: std.mem.Allocator, id_size: u32) ThreadIndex {
        return .{
            .allocator = allocator,
            .id_size = id_size,
            .frames = std.AutoHashMap(hprof.Id, hprof.Frame).init(allocator),
            .traces = std.AutoHashMap(u32, TraceInfo).init(allocator),
            .thread_roots = std.AutoHashMap(hprof.Id, ThreadRoot).init(allocator),
            .threads = std.ArrayList(Thread).empty,
            .thread_by_object = std.AutoHashMap(hprof.Id, usize).init(allocator),
            .holder_to_thread = std.AutoHashMap(hprof.Id, usize).init(allocator),
            .pending_holders = std.AutoHashMap(hprof.Id, PendingInstance).init(allocator),
            .string_values = std.AutoHashMap(hprof.Id, StringInfo).init(allocator),
            .prim_arrays = std.AutoHashMap(hprof.Id, PrimArrayInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ThreadIndex) void {
        self.frames.deinit();
        var trace_it = self.traces.iterator();
        while (trace_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.frames);
        }
        self.traces.deinit();
        self.thread_roots.deinit();
        for (self.threads.items) |t| {
            self.allocator.free(t.name);
        }
        self.threads.deinit(self.allocator);
        self.thread_by_object.deinit();
        self.holder_to_thread.deinit();
        var pending_it = self.pending_holders.iterator();
        while (pending_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.bytes);
        }
        self.pending_holders.deinit();
        self.string_values.deinit();
        self.prim_arrays.deinit();
    }

    pub fn addFrame(self: *ThreadIndex, frame: hprof.Frame) !void {
        try self.frames.put(frame.id, frame);
    }

    pub fn addTrace(self: *ThreadIndex, trace: hprof.Trace) !void {
        const frame_ids = try self.allocator.alloc(hprof.Id, trace.frame_count);
        var cursor = hprof.Cursor.init(trace.raw);
        for (0..trace.frame_count) |i| {
            frame_ids[i] = try cursor.readId(self.id_size);
        }
        try self.traces.put(trace.serial, .{
            .thread_serial = trace.thread_serial,
            .frames = frame_ids,
        });
    }

    pub fn addRoot(self: *ThreadIndex, thread_object_id: hprof.Id, thread_serial: u32, stack_trace_serial: u32) !void {
        try self.thread_roots.put(thread_object_id, .{
            .serial = thread_serial,
            .stack_trace_serial = stack_trace_serial,
        });
    }

    pub fn addPrimArray(self: *ThreadIndex, arr: hprof.PrimitiveArrayDump) !void {
        try self.prim_arrays.put(arr.array_id, .{
            .element_type = arr.element_type,
            .bytes = arr.bytes,
        });
    }

    pub fn addInstance(self: *ThreadIndex, inst: hprof.InstanceDump, ctx: Context) !void {
        if (self.thread_roots.contains(inst.object_id)) {
            const virtual = isVirtualThreadOrSubclass(ctx, inst.class_id);
            try self.parseThreadInstance(inst, ctx, virtual);
            return;
        }
        if (isFieldHolder(ctx, inst.class_id)) {
            try self.parseFieldHolder(inst, ctx);
            return;
        }
        if (isString(ctx, inst.class_id)) {
            try self.parseStringInstance(inst, ctx);
            return;
        }
    }

    pub fn finish(self: *ThreadIndex) !void {
        // Resolve any thread names that point at String objects.
        for (self.threads.items) |*t| {
            if (t.name_object_id != 0) {
                const resolved = try self.decodeString(t.name_object_id);
                self.allocator.free(t.name);
                t.name = resolved;
            }
        }

        // Discard pending holders that never found their thread.
        var pending_it = self.pending_holders.iterator();
        while (pending_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.bytes);
        }
        self.pending_holders.clearAndFree();
    }

    pub fn print(self: *const ThreadIndex, writer: anytype, ctx: Context) !void {
        for (self.threads.items) |t| {
            if (t.virtual) {
                try writer.print("Thread: {s} (virtual)\n", .{t.name});
            } else {
                try writer.print("Thread: {s}\n", .{t.name});
            }
            try writer.print("  State:    {s}\n", .{t.state});
            try writer.print("  Priority: {d}\n", .{t.priority});
            try writer.print("  Daemon:   {s}\n", .{if (t.daemon) "true" else "false"});
            try writer.print("  TID:      {d}\n", .{t.tid});

            if (self.traces.get(t.stack_trace_serial)) |trace| {
                try writer.print("  Stack trace:\n", .{});
                for (trace.frames) |fid| {
                    if (self.frames.get(fid)) |frame| {
                        const class_name = try self.formatFrameClassName(ctx, frame.class_serial);
                        defer self.allocator.free(class_name);
                        const method = ctx.utf8.get(frame.method_name_id) orelse "<?>";
                        const source = ctx.utf8.get(frame.source_file_name_id) orelse "<?>";
                        if (frame.line_number < 0) {
                            try writer.print("    at {s}.{s}({s})\n", .{ class_name, method, source });
                        } else {
                            try writer.print("    at {s}.{s}({s}:{d})\n", .{ class_name, method, source, frame.line_number });
                        }
                    } else {
                        try writer.print("    at <unknown frame 0x{x}>\n", .{fid});
                    }
                }
            } else {
                try writer.print("  Stack trace: <none>\n", .{});
            }
            try writer.print("\n", .{});
        }
    }

    pub fn threadCount(self: *const ThreadIndex) u32 {
        return @intCast(self.threads.items.len);
    }

    fn parseThreadInstance(self: *ThreadIndex, inst: hprof.InstanceDump, ctx: Context, virtual: bool) !void {
        const root = self.thread_roots.get(inst.object_id).?;
        const fields = try self.collectInstanceFields(ctx, inst.class_id, inst.bytes);
        defer self.allocator.free(fields);

        var name_id: hprof.Id = 0;
        var tid: i64 = 0;
        var holder_id: hprof.Id = 0;
        var virtual_state: i32 = -1;

        for (fields) |fv| {
            if (std.mem.eql(u8, fv.name, "name")) {
                if (fv.value == .object) name_id = fv.value.object;
            } else if (std.mem.eql(u8, fv.name, "tid")) {
                if (fv.value == .long) tid = fv.value.long;
            } else if (std.mem.eql(u8, fv.name, "holder")) {
                if (fv.value == .object) holder_id = fv.value.object;
            } else if (virtual and std.mem.eql(u8, fv.name, "state")) {
                if (fv.value == .int) virtual_state = fv.value.int;
            }
        }

        const state = if (virtual and virtual_state >= 0)
            virtualStateString(virtual_state)
        else
            "unknown";

        const idx = self.threads.items.len;
        try self.threads.append(self.allocator, .{
            .object_id = inst.object_id,
            .serial = root.serial,
            .name = try self.allocator.dupe(u8, "<unresolved>"),
            .name_object_id = name_id,
            .state = state,
            .priority = 0,
            .daemon = false,
            .tid = tid,
            .virtual = virtual,
            .stack_trace_serial = root.stack_trace_serial,
        });
        try self.thread_by_object.put(inst.object_id, idx);

        if (holder_id != 0) {
            if (self.pending_holders.fetchRemove(holder_id)) |kv| {
                const pending = kv.value;
                try self.applyFieldHolder(idx, pending.class_id, pending.bytes, ctx);
                self.allocator.free(pending.bytes);
            } else {
                try self.holder_to_thread.put(holder_id, idx);
            }
        }
    }

    fn parseFieldHolder(self: *ThreadIndex, inst: hprof.InstanceDump, ctx: Context) !void {
        if (self.holder_to_thread.get(inst.object_id)) |idx| {
            try self.applyFieldHolder(idx, inst.class_id, inst.bytes, ctx);
            return;
        }
        const copy = try self.allocator.dupe(u8, inst.bytes);
        try self.pending_holders.put(inst.object_id, .{
            .class_id = inst.class_id,
            .bytes = copy,
        });
    }

    fn applyFieldHolder(self: *ThreadIndex, idx: usize, class_id: hprof.Id, bytes: []const u8, ctx: Context) !void {
        const fields = try self.collectInstanceFields(ctx, class_id, bytes);
        defer self.allocator.free(fields);
        const t = &self.threads.items[idx];
        for (fields) |fv| {
            if (std.mem.eql(u8, fv.name, "priority")) {
                if (fv.value == .int) t.priority = fv.value.int;
            } else if (std.mem.eql(u8, fv.name, "daemon")) {
                if (fv.value == .boolean) t.daemon = fv.value.boolean;
            } else if (std.mem.eql(u8, fv.name, "threadStatus")) {
                if (fv.value == .int) t.state = platformStateString(fv.value.int);
            }
        }
    }

    fn parseStringInstance(self: *ThreadIndex, inst: hprof.InstanceDump, ctx: Context) !void {
        const fields = try self.collectInstanceFields(ctx, inst.class_id, inst.bytes);
        defer self.allocator.free(fields);
        var value_id: hprof.Id = 0;
        var coder: ?u8 = null;
        for (fields) |fv| {
            if (std.mem.eql(u8, fv.name, "value")) {
                if (fv.value == .object) value_id = fv.value.object;
            } else if (std.mem.eql(u8, fv.name, "coder")) {
                if (fv.value == .byte) coder = @intCast(@as(u8, @bitCast(fv.value.byte)));
            }
        }
        if (value_id != 0) {
            try self.string_values.put(inst.object_id, .{
                .array_id = value_id,
                .coder = coder,
            });
        }
    }

    fn collectInstanceFields(self: *ThreadIndex, ctx: Context, class_id: hprof.Id, bytes: []const u8) ![]FieldValue {
        var result = std.ArrayList(FieldValue).empty;
        errdefer result.deinit(self.allocator);

        // Collect field definitions from the object's class up through superclasses.
        var defs = std.ArrayList(struct { name: []const u8, ty: hprof.PrimitiveType }).empty;
        defer defs.deinit(self.allocator);

        var cur: hprof.Id = class_id;
        while (cur != 0) {
            const info = ctx.classes.get(cur) orelse break;
            var cursor = hprof.Cursor.init(info.instance_fields_raw);
            const count = cursor.readU2() catch break;
            for (0..count) |_| {
                const name_id = cursor.readId(ctx.id_size) catch break;
                const ty = hprof.readPrimitiveType(&cursor) catch break;
                const name = ctx.utf8.get(name_id) orelse "<?>";
                try defs.append(self.allocator, .{ .name = name, .ty = ty });
            }
            cur = info.super_class_id;
        }

        var value_cursor = hprof.Cursor.init(bytes);
        for (defs.items) |def| {
            const value = value_cursor.readValue(def.ty, ctx.id_size) catch break;
            try result.append(self.allocator, .{ .name = def.name, .value = value });
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn decodeString(self: *ThreadIndex, string_object_id: hprof.Id) std.mem.Allocator.Error![]const u8 {
        const info = self.string_values.get(string_object_id) orelse return self.allocator.dupe(u8, "<unresolved>");
        const arr = self.prim_arrays.get(info.array_id) orelse return self.allocator.dupe(u8, "<unresolved>");
        switch (arr.element_type) {
            .char => return decodeUtf16(self.allocator, arr.bytes, .big),
            .byte => {
                if (info.coder == 1) {
                    return decodeUtf16(self.allocator, arr.bytes, .little);
                }
                return decodeLatin1(self.allocator, arr.bytes);
            },
            else => return self.allocator.dupe(u8, "<unsupported string>"),
        }
    }

    pub fn formatFrameClassName(self: *const ThreadIndex, ctx: Context, class_serial: u32) std.mem.Allocator.Error![]const u8 {
        const load = ctx.loaded.get(class_serial) orelse {
            return try self.allocator.dupe(u8, "<?>");
        };
        const name_id = ctx.class_names.get(load.class_id) orelse {
            return try self.allocator.dupe(u8, "<?>");
        };
        const raw = ctx.utf8.get(name_id) orelse "<?>";
        return try replaceSlashes(self.allocator, raw);
    }
};

fn classNameRaw(ctx: Context, class_id: hprof.Id) ?[]const u8 {
    const name_id = ctx.class_names.get(class_id) orelse return null;
    return ctx.utf8.get(name_id);
}

fn isFieldHolder(ctx: Context, class_id: hprof.Id) bool {
    return std.mem.eql(u8, classNameRaw(ctx, class_id) orelse "", "java/lang/Thread$FieldHolder");
}

fn isString(ctx: Context, class_id: hprof.Id) bool {
    return std.mem.eql(u8, classNameRaw(ctx, class_id) orelse "", "java/lang/String");
}

fn isVirtualThreadOrSubclass(ctx: Context, class_id: hprof.Id) bool {
    var cur: hprof.Id = class_id;
    while (cur != 0) {
        if (std.mem.eql(u8, classNameRaw(ctx, cur) orelse "", "java/lang/VirtualThread")) return true;
        const info = ctx.classes.get(cur) orelse break;
        cur = info.super_class_id;
    }
    return false;
}

fn platformStateString(status: i32) []const u8 {
    // JVMTI thread state bits, with a simple ordinal fallback.
    if (status & 0x0002 != 0) return "TERMINATED";
    if (status & 0x0004 != 0) return "RUNNABLE";
    if (status & 0x0400 != 0) return "BLOCKED";
    if (status & 0x0010 != 0) return "WAITING";
    if (status & 0x0020 != 0) return "TIMED_WAITING";
    if (status & 0x0001 != 0) return "RUNNABLE";
    if (status == 0) return "NEW";
    if (status >= 0 and status <= 5) {
        const states = [_][]const u8{ "NEW", "RUNNABLE", "BLOCKED", "WAITING", "TIMED_WAITING", "TERMINATED" };
        return states[@intCast(status)];
    }
    return "unknown";
}

fn virtualStateString(state: i32) []const u8 {
    return switch (state) {
        0 => "NEW",
        1, 2, 3, 7 => "RUNNABLE",
        4, 5 => "WAITING",
        6 => "BLOCKED",
        8 => "TERMINATED",
        else => "unknown",
    };
}

fn replaceSlashes(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    var result = try allocator.dupe(u8, s);
    for (result, 0..) |c, i| {
        if (c == '/') result[i] = '.';
    }
    return result;
}

fn decodeLatin1(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, bytes.len);
    errdefer result.deinit(allocator);
    for (bytes) |b| {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(b, &buf) catch {
            try result.appendSlice(allocator, "?");
            continue;
        };
        try result.appendSlice(allocator, buf[0..len]);
    }
    return result.toOwnedSlice(allocator);
}

fn decodeUtf16(allocator: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian) std.mem.Allocator.Error![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i + 1 < bytes.len) {
        const cu = std.mem.readInt(u16, bytes[i .. i + 2][0..2], endian);
        i += 2;
        var codepoint: u21 = cu;
        if (cu >= 0xD800 and cu <= 0xDBFF) {
            if (i + 1 >= bytes.len) break;
            const low = std.mem.readInt(u16, bytes[i .. i + 2][0..2], endian);
            i += 2;
            if (low < 0xDC00 or low > 0xDFFF) continue;
            codepoint = 0x10000 + ((@as(u21, cu & 0x3FF) << 10) | @as(u21, low & 0x3FF));
        } else if (cu >= 0xDC00 and cu <= 0xDFFF) {
            continue;
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
            try result.appendSlice(allocator, "?");
            continue;
        };
        try result.appendSlice(allocator, buf[0..len]);
    }
    return result.toOwnedSlice(allocator);
}
