//! Shared index types used by Analysis and Threads.
const hprof = @import("hprof.zig");

pub const ClassInfo = struct {
    super_class_id: hprof.Id,
    instance_size: u32,
    class_loader_id: hprof.Id,
    instance_fields_raw: []const u8,
};

pub const LoadClassEntry = struct {
    class_id: hprof.Id,
    name_id: hprof.Id,
};
