//! Root module for the developer-only benchmark executable.
const Bench = @import("index/dominator/Bench.zig");

pub fn main(init: @import("std").process.Init) !void {
    try Bench.main(init);
}
