//! Wrapping allocator that tracks net heap bytes requested through it.
//!
//! The count is "net requested bytes": allocations increment, frees decrement,
//! and resizes adjust by the size delta. It intentionally does *not* count
//! memory-mapped files or allocations made through unrelated allocators.
const std = @import("std");

pub const Tracker = struct {
    /// The underlying allocator that actually performs allocations.
    child: std.mem.Allocator,

    /// Net number of bytes currently requested through this tracker.
    /// This is a logical count, not RSS or allocator-held memory.
    bytes_used: usize = 0,

    pub fn allocator(self: *Tracker) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocImpl,
                .resize = resizeImpl,
                .remap = remapImpl,
                .free = freeImpl,
            },
        };
    }

    fn allocImpl(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const ptr = self.child.vtable.alloc(self.child.ptr, len, ptr_align, ret_addr);
        if (ptr != null) self.bytes_used += len;
        return ptr;
    }

    fn resizeImpl(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const ok = self.child.vtable.resize(self.child.ptr, buf, buf_align, new_len, ret_addr);
        if (ok) {
            if (new_len > buf.len) {
                self.bytes_used += new_len - buf.len;
            } else if (new_len < buf.len) {
                self.bytes_used -= buf.len - new_len;
            }
        }
        return ok;
    }

    fn remapImpl(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const ptr = self.child.vtable.remap(self.child.ptr, buf, buf_align, new_len, ret_addr);
        if (ptr != null) {
            if (new_len > buf.len) {
                self.bytes_used += new_len - buf.len;
            } else if (new_len < buf.len) {
                self.bytes_used -= buf.len - new_len;
            }
        }
        return ptr;
    }

    fn freeImpl(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, buf, buf_align, ret_addr);
        self.bytes_used -= buf.len;
    }
};
