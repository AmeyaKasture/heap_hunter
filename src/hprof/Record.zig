//! HPROF top-level record types and decoder.
const Types = @import("Types.zig");
const HeapDump = @import("HeapDump.zig");
const Cursor = Types.Cursor;
const Error = Types.Error;
const Id = Types.Id;

pub const Utf8 = struct {
    id: Id,
    bytes: []const u8,
};

pub const LoadClass = struct {
    serial: u32,
    class_id: Id,
    stack_trace_serial: u32,
    name_id: Id,
};

pub const UnloadClass = struct {
    serial: u32,
};

pub const HeapSummary = struct {
    live_bytes: u32,
    live_instances: u32,
    bytes_allocated: u64,
    instances_allocated: u64,
};

pub const StartThread = struct {
    serial: u32,
    thread_id: Id,
    stack_trace_serial: u32,
    name_id: Id,
    group_name_id: Id,
    parent_group_name_id: Id,
};

pub const EndThread = struct {
    serial: u32,
};

pub const ControlSettings = struct {
    flags: u32,
    stack_trace_depth: u16,
};

pub const Frame = struct {
    id: Id,
    method_name_id: Id,
    method_signature_id: Id,
    source_file_name_id: Id,
    class_serial: u32,
    line_number: i32,
};

pub const Trace = struct {
    serial: u32,
    thread_serial: u32,
    frame_count: u32,
    raw: []const u8,
};

pub const Record = union(Types.RecordTag) {
    utf8: Utf8,
    load_class: LoadClass,
    unload_class: UnloadClass,
    frame: Frame,
    trace: Trace,
    alloc_sites: []const u8,
    heap_summary: HeapSummary,
    start_thread: StartThread,
    end_thread: EndThread,
    heap_dump: HeapDump.Reader,
    cpu_samples: []const u8,
    control_settings: ControlSettings,
    heap_dump_segment: HeapDump.Reader,
    heap_dump_end: void,
};

pub fn decode(tag: Types.RecordTag, body: []const u8, id_size: u32) Error!Record {
    return decodeWithOffset(tag, body, id_size, 0);
}

pub fn decodeWithOffset(tag: Types.RecordTag, body: []const u8, id_size: u32, body_offset: usize) Error!Record {
    var c = Cursor.init(body);
    switch (tag) {
        .utf8 => {
            const id = try c.readId(id_size);
            const bytes = c.buf[c.pos..];
            return .{ .utf8 = .{ .id = id, .bytes = bytes } };
        },
        .load_class => {
            return .{ .load_class = .{
                .serial = try c.readU4(),
                .class_id = try c.readId(id_size),
                .stack_trace_serial = try c.readU4(),
                .name_id = try c.readId(id_size),
            } };
        },
        .unload_class => {
            return .{ .unload_class = .{ .serial = try c.readU4() } };
        },
        .frame => {
            return .{ .frame = .{
                .id = try c.readId(id_size),
                .method_name_id = try c.readId(id_size),
                .method_signature_id = try c.readId(id_size),
                .source_file_name_id = try c.readId(id_size),
                .class_serial = try c.readU4(),
                .line_number = try c.readI4(),
            } };
        },
        .trace => {
            return .{ .trace = .{
                .serial = try c.readU4(),
                .thread_serial = try c.readU4(),
                .frame_count = try c.readU4(),
                .raw = c.buf[c.pos..],
            } };
        },
        .alloc_sites => {
            return .{ .alloc_sites = body };
        },
        .heap_summary => {
            return .{ .heap_summary = .{
                .live_bytes = try c.readU4(),
                .live_instances = try c.readU4(),
                .bytes_allocated = try c.readU8(),
                .instances_allocated = try c.readU8(),
            } };
        },
        .start_thread => {
            return .{ .start_thread = .{
                .serial = try c.readU4(),
                .thread_id = try c.readId(id_size),
                .stack_trace_serial = try c.readU4(),
                .name_id = try c.readId(id_size),
                .group_name_id = try c.readId(id_size),
                .parent_group_name_id = try c.readId(id_size),
            } };
        },
        .end_thread => {
            return .{ .end_thread = .{ .serial = try c.readU4() } };
        },
        .heap_dump => {
            return .{ .heap_dump = HeapDump.Reader.initWithOffset(body, id_size, body_offset) };
        },
        .cpu_samples => {
            return .{ .cpu_samples = body };
        },
        .control_settings => {
            return .{ .control_settings = .{
                .flags = try c.readU4(),
                .stack_trace_depth = try c.readU2(),
            } };
        },
        .heap_dump_segment => {
            return .{ .heap_dump_segment = HeapDump.Reader.initWithOffset(body, id_size, body_offset) };
        },
        .heap_dump_end => {
            return .{ .heap_dump_end = {} };
        },
    }
}
