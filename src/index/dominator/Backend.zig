//! Backend interface for dominator computation.
const std = @import("std");
const CsrView = @import("CsrView.zig").CsrView;

pub const Algorithm = enum { chk, lt };

/// Parses a user-facing algorithm name ("chk" | "lt"). Returns null for any
/// other spelling so the CLI can report the raw input.
pub fn parseAlgorithm(name: []const u8) ?Algorithm {
    if (std.mem.eql(u8, name, "chk")) return .chk;
    if (std.mem.eql(u8, name, "lt")) return .lt;
    return null;
}

pub const Stats = struct {
    iterations: u32 = 0,
    nodes_changed: u64 = 0,
    edges_processed: u64 = 0,
    intersect_steps_total: u64 = 0,
    intersect_steps_max: u32 = 0,
    shortcut_nodes: u64 = 0,
    // --- Lengauer-Tarjan counters ---
    eval_calls: u64 = 0,
    /// Pointer hops taken by eval's iterative path compression. The classic
    /// bound is O(E log V) total; per-call it is bounded by the DFS depth.
    compress_steps: u64 = 0,
    compress_steps_max: u32 = 0,
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
    /// Reverse-postorder slot -> ordinal. Always present.
    rpo_vertex: []u32,
    /// Reachability bitset over ordinals; see `Numbering.reachable`.
    reachable: []u8,
    // --- Reverse-postorder products (CHK only) ---
    /// Ordinal -> reverse-postorder slot. Empty when the LT backend runs.
    rpo_num: []u32 = &.{},
    // --- DFS-tree products (LT only) ---
    /// Ordinal -> preorder slot (NONE when unreachable). Empty when the CHK
    /// backend runs.
    dfn: []u32 = &.{},
    /// Preorder slot -> ordinal. Empty when the CHK backend runs.
    dfn_vertex: []u32 = &.{},
    /// Preorder slot -> parent's preorder slot (NONE for the virtual root).
    /// Empty when the CHK backend runs.
    parent: []u32 = &.{},
    /// Maximum DFS-tree depth reached by the numbering pass. The LT backend
    /// uses it to bound eval's path-compression buffer; 0 means unset.
    max_dfs_depth: u32 = 0,
    // --- Backend options ---
    options: Options,
    // --- CSR views ---
    out_edges: *const CsrView,
    in_edges: *const CsrView,

    /// True iff ordinal `v` is reachable from the virtual root.
    pub inline fn isReachable(self: *const Context, v: u32) bool {
        return (self.reachable[v >> 3] & (@as(u8, 1) << @intCast(v & 7))) != 0;
    }
};

pub const Backend = struct {
    name: Algorithm,
    /// Computes the immediate dominator of every reachable node.
    compute: *const fn (ctx: *const Context) anyerror!Result,
};

pub const Options = struct {
    algorithm: Algorithm = .chk,
    max_iterations: u32 = 64,
    use_shortcut: bool = true,
};
