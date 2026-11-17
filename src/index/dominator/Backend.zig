//! Backend interface for dominator computation.
const std = @import("std");
const CsrView = @import("CsrView.zig").CsrView;

pub const Algorithm = enum { chk };

pub const Stats = struct {
    iterations: u32 = 0,
    nodes_changed: u64 = 0,
    edges_processed: u64 = 0,
    intersect_steps_total: u64 = 0,
    intersect_steps_max: u32 = 0,
    shortcut_nodes: u64 = 0,
};

pub const Result = struct {
    /// Immediate dominator per node ordinal. NONE for unreachable nodes and
    /// for the virtual root (the on-disk value). Internally the backend uses
    /// root -> root; the orchestrator converts before writing.
    idom: []u32,
    stats: Stats,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    n_nodes: u32,
    root: u32,
    n_reachable: u32,
    // --- DFS products (shared) ---
    rpo_num: []u32,
    rpo_vertex: []u32,
    reachable: []bool,
    // --- Backend options ---
    options: Options,
    // --- CSR views ---
    out_edges: *const CsrView,
    in_edges: *const CsrView,
};

pub const Backend = struct {
    name: Algorithm,
    /// Computes the immediate dominator of every reachable node.
    compute: *const fn (ctx: *const Context) anyerror!Result,
};

/// Hard abort threshold for non-convergence, distinct from the G1 design
/// gate (10 iterations): the cap only fires when the sweep has stopped
/// making progress, never as a performance warning.
pub const default_max_iterations: u32 = 64;

pub const Options = struct {
    algorithm: Algorithm = .chk,
    max_iterations: u32 = default_max_iterations,
    use_shortcut: bool = true,
};
