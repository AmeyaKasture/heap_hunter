//! Thin logging wrapper that is compile-time gated via build options.
//!
//! Use this module for all diagnostic output. In production builds the
//! `-Dlog-level` and `-Dstack-traces` flags strip out the corresponding
//! code so no internal details are leaked.

const std = @import("std");
const build_options = @import("build_options");

pub const Level = std.log.Level;

/// Resolved log level from the build option. Kept in one place so the
/// generated options string is converted to the real `std.log.Level` type.
pub const level: Level = blk: {
    const s = build_options.log_level;
    break :blk std.meta.stringToEnum(Level, s) orelse {
        @compileError("unknown log level: " ++ s);
    };
};

// Re-export the standard log levels so callers can simply write
// `log.debug(...)` etc.
pub const err = std.log.err;
pub const warn = std.log.warn;
pub const info = std.log.info;
pub const debug = std.log.debug;
pub const scoped = std.log.scoped;

/// True when both debug logging and stack traces are enabled. Can be used
/// to guard extra-expensive diagnostic blocks that should be fully stripped
/// from release binaries.
pub const diagnostics_enabled = level == .debug and build_options.stack_traces;

/// Log an error together with its error-return trace, if stack traces are
/// enabled in the current build.
///
/// Typical usage inside a function that returns an error union:
///
///     errdefer |e| log.traceError(e);
///
pub fn traceError(e: anyerror) void {
    if (comptime !build_options.stack_traces) return;
    if (@import("builtin").is_test) return;

    // Use debug level so that diagnostic output does not fail tests that
    // intentionally exercise error paths.
    std.log.debug("error return trace for {s}:", .{@errorName(e)});
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpErrorReturnTrace(trace);
    }
}
