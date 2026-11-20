//! Progress reporting for long-running CLI operations.
//!
//! When stderr is a terminal, this module renders a one-line progress bar with
//! a checkpoint label (e.g., "[=====>                         ] [1/9] scanning
//! heap dump"). On non-TTY output it prints plain checkpoint lines instead, so
//! progress can be captured in logs.
//!
//! An optional event callback can be supplied to receive the same progress
//! events that drive the TTY bar. This is used by the MCP server to emit
//! `notifications/progress` messages while still allowing the existing
//! command code to render progress for CLI users.
const std = @import("std");
const Io = std.Io;
const Cli = @import("Cli.zig");

/// A single progress event emitted whenever the current step, label,
/// finished state, or intra-step position changes.
pub const Event = struct {
    current_step: usize,
    total_steps: usize,
    label: []const u8,
    finished: bool,
    message: ?[]const u8,
    /// Position within the current step, 0..1, when the running stage can
    /// report it (e.g. scanned bytes of total); null on step boundaries.
    fraction: ?f64 = null,
};

/// Optional callback that receives progress events. `ctx` is the opaque
/// pointer supplied when the reporter was created.
pub const Callback = *const fn (ctx: ?*anyopaque, event: Event) void;

pub const Progress = struct {
    stderr: *Io.Writer,
    io: Io,
    is_tty: bool,
    colors: bool,
    total_steps: usize,
    current_step: usize,
    label: []const u8,
    /// Intra-step position reported by the running stage; null between
    /// step boundaries.
    fraction: ?f64,
    /// Command-wide percent of the last fraction emission, used to
    /// throttle setFraction to at most one line per whole percent.
    last_fraction_pct: f64,
    disabled: bool,
    finished: bool,
    on_event: ?Callback,
    on_event_ctx: ?*anyopaque,

    const bar_width = 30;
    const fill_char = "=";
    const head_char = ">";
    const empty_char = " ";
    /// Minimum command-wide percent between two fraction emissions, so
    /// piped output stays compact no matter how often the stage reports
    /// its position.
    const fraction_emit_step = 1.0;

    /// A sub-range of the current step's 0..1 window. Stages hand these
    /// to helpers (external sorts, merge-joins) so intra-step positions
    /// from nested phases stay monotonic within the step.
    pub const Span = struct {
        lo: f64 = 0,
        hi: f64 = 1,
    };

    pub const Options = struct {
        total_steps: usize,
        is_tty: bool,
        colors: bool,
        disabled: bool = false,
        on_event: ?Callback = null,
        on_event_ctx: ?*anyopaque = null,
    };

    /// Start progress reporting. The initial label is "starting...".
    pub fn start(stderr: *Io.Writer, io: Io, options: Options) Progress {
        var progress: Progress = .{
            .stderr = stderr,
            .io = io,
            .is_tty = options.is_tty,
            .colors = options.colors,
            .total_steps = options.total_steps,
            .current_step = 0,
            .label = "starting...",
            .fraction = null,
            .last_fraction_pct = -1,
            .disabled = options.disabled,
            .finished = false,
            .on_event = options.on_event,
            .on_event_ctx = options.on_event_ctx,
        };
        if (!options.disabled) {
            progress.render();
            progress.emitEvent();
        }
        return progress;
    }

    /// Advance to the next step and change the label.
    pub fn nextStep(self: *Progress, label: []const u8) void {
        if (self.disabled or self.finished) return;
        self.current_step += 1;
        self.label = label;
        self.fraction = null;
        self.last_fraction_pct = -1;
        self.render();
        self.emitEvent();
    }

    /// Update the label of the current step without advancing.
    pub fn setLabel(self: *Progress, label: []const u8) void {
        if (self.disabled or self.finished) return;
        self.label = label;
        self.fraction = null;
        self.last_fraction_pct = -1;
        self.render();
        self.emitEvent();
    }

    /// Report intra-step progress as a 0..1 position within the current
    /// step; the running stage calls this as it advances (e.g. scanned
    /// bytes of total). The position folds into the command-wide percent
    /// shown by the bar, throttled to one emission per whole percent so
    /// piped output stays compact.
    pub fn setFraction(self: *Progress, fraction: f64) void {
        if (self.disabled or self.finished) return;
        const clamped = @min(@max(fraction, 0.0), 1.0);
        self.fraction = clamped;
        const pct = self.overallPercent();
        if (pct - self.last_fraction_pct < fraction_emit_step) return;
        self.last_fraction_pct = pct;
        self.render();
        self.emitEvent();
    }

    /// Command-wide completion percent: step k of N with intra-step
    /// fraction f is (k + f) / N, matching the step-boundary convention
    /// where reaching step k means k of N steps are complete. Clamps to
    /// the [0, 1] window around step 0 and the final step.
    fn overallPercent(self: *Progress) f64 {
        if (self.total_steps == 0) return 0;
        const total: f64 = @floatFromInt(self.total_steps);
        const step: f64 = @floatFromInt(self.current_step);
        const frac = self.fraction orelse 0;
        const overall = @min(@max((step + frac) / total, 0.0), 1.0);
        return overall * 100.0;
    }

    /// Refresh the display. This is a no-op for the bar-based progress
    /// reporter because the bar advances only on step changes.
    pub fn tick(self: *Progress) void {
        if (self.disabled or self.finished or !self.is_tty) return;
        // Re-render so the line stays visible on slow terminals, but the bar
        // only advances when nextStep is called.
        self.render();
        self.emitEvent();
    }

    /// Stop progress reporting and optionally print a final message.
    /// If `message` is null, the line is cleared.
    pub fn stop(self: *Progress, message: ?[]const u8) void {
        if (self.disabled) return;
        self.finished = true;
        if (self.is_tty) {
            self.clearLine();
            if (message) |m| {
                self.stderr.print("{s}\n", .{m}) catch {};
            }
        } else if (message) |m| {
            self.stderr.print("{s}\n", .{m}) catch {};
        }
        self.emitEventFinal(message);
    }

    fn emitEvent(self: *Progress) void {
        if (self.on_event) |cb| {
            cb(self.on_event_ctx, .{
                .current_step = self.current_step,
                .total_steps = self.total_steps,
                .label = self.label,
                .finished = self.finished,
                .message = null,
                .fraction = self.fraction,
            });
        }
    }

    fn emitEventFinal(self: *Progress, message: ?[]const u8) void {
        if (self.on_event) |cb| {
            cb(self.on_event_ctx, .{
                .current_step = self.current_step,
                .total_steps = self.total_steps,
                .label = self.label,
                .finished = self.finished,
                .message = message,
                .fraction = self.fraction,
            });
        }
    }

    fn render(self: *Progress) void {
        if (self.is_tty) {
            self.clearLine();
            self.writeBar();
            self.stderr.writeAll(" ") catch {};
            self.writeLabel();
            self.stderr.writeAll("\r") catch {};
            self.stderr.flush() catch {};
        } else {
            self.writeCheckpoint();
        }
    }

    fn writeBar(self: *Progress) void {
        const filled: usize = if (self.total_steps == 0)
            0
        else
            @intFromFloat(self.overallPercent() * 0.01 * @as(f64, @floatFromInt(bar_width)));
        const clamped_filled = @min(filled, bar_width);

        if (self.colors) {
            self.stderr.writeAll("\x1b[1m[") catch {};
        } else {
            self.stderr.writeAll("[") catch {};
        }

        var i: usize = 0;
        while (i < clamped_filled) : (i += 1) {
            self.stderr.writeAll(fill_char) catch {};
        }
        if (self.current_step < self.total_steps and clamped_filled < bar_width) {
            self.stderr.writeAll(head_char) catch {};
            i += 1;
        }
        while (i < bar_width) : (i += 1) {
            self.stderr.writeAll(empty_char) catch {};
        }

        if (self.colors) {
            self.stderr.writeAll("]\x1b[0m") catch {};
        } else {
            self.stderr.writeAll("]") catch {};
        }
    }

    fn writeLabel(self: *Progress) void {
        if (self.colors) {
            self.stderr.print("\x1b[36m[{d}/{d}]\x1b[0m {s}", .{ self.current_step, self.total_steps, self.label }) catch {};
        } else {
            self.stderr.print("[{d}/{d}] {s}", .{ self.current_step, self.total_steps, self.label }) catch {};
        }
    }

    fn writeCheckpoint(self: *Progress) void {
        self.writeBar();
        self.stderr.writeAll(" ") catch {};
        if (self.fraction != null) {
            // Intra-step positions carry the command-wide percent so
            // consumers can interpolate within the step.
            const pct: u32 = @intFromFloat(@round(self.overallPercent()));
            self.stderr.print("[{d}/{d}] {s} {d}%\n", .{ self.current_step, self.total_steps, self.label, pct }) catch {};
        } else {
            self.stderr.print("[{d}/{d}] {s}\n", .{ self.current_step, self.total_steps, self.label }) catch {};
        }
        self.stderr.flush() catch {};
    }

    fn clearLine(self: *Progress) void {
        self.stderr.writeAll("\x1b[2K\r") catch {};
    }
};

/// Create a progress reporter for a command with the given number of steps.
/// If `disabled` is true, progress is suppressed entirely.
pub fn create(stderr: *Io.Writer, io: Io, total_steps: usize, disabled: bool) Progress {
    return createEx(stderr, io, total_steps, disabled, null, null);
}

/// Like `create`, but also receives an optional callback that is invoked on
/// every progress event. The callback can be used by non-CLI consumers (e.g.
/// the MCP server) to forward progress to another channel.
pub fn createEx(
    stderr: *Io.Writer,
    io: Io,
    total_steps: usize,
    disabled: bool,
    on_event: ?Callback,
    on_event_ctx: ?*anyopaque,
) Progress {
    return Progress.start(stderr, io, .{
        .total_steps = total_steps,
        .is_tty = Cli.isStderrTty(io),
        .colors = Cli.colorsEnabled(),
        .disabled = disabled,
        .on_event = on_event,
        .on_event_ctx = on_event_ctx,
    });
}

const testing = std.testing;

test "non-TTY checkpoints carry intra-step percent, throttled per percent" {
    var buf: [4096]u8 = undefined;
    var stderr: Io.Writer = Io.Writer.fixed(&buf);
    var p = Progress.start(&stderr, testing.io, .{
        .total_steps = 9,
        .is_tty = false,
        .colors = false,
    });
    p.nextStep("scanning heap dump");

    // Step 1 of 9 at half position is (1 + 0.5)/9 ≈ 16.7% → prints 17%.
    p.setFraction(0.5);
    // Still inside the same whole percent → suppressed.
    p.setFraction(0.52);
    // 0.75 is (1 + 0.75)/9 ≈ 19.4% → prints 19%.
    p.setFraction(0.75);

    const out = stderr.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "[1/9] scanning heap dump\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "scanning heap dump 17%\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "scanning heap dump 19%\n") != null);
    // One boundary line plus two fraction emissions, nothing for the
    // suppressed call.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "scanning heap dump"));
}

test "step boundaries clear the intra-step fraction" {
    var buf: [4096]u8 = undefined;
    var stderr: Io.Writer = Io.Writer.fixed(&buf);
    var p = Progress.start(&stderr, testing.io, .{
        .total_steps = 2,
        .is_tty = false,
        .colors = false,
    });
    p.nextStep("first");
    p.setFraction(0.5);
    p.nextStep("second");

    const out = stderr.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "[2/2] second\n") != null);
    // The boundary line carries no percent suffix and the 0.5 position of
    // step 1 does not leak into step 2.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "second %"));
}

test "fraction events are forwarded to the event callback" {
    const Capture = struct {
        last_fraction: ?f64 = null,

        fn onEvent(ctx: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.last_fraction = event.fraction;
        }
    };
    var capture = Capture{};
    var buf: [4096]u8 = undefined;
    var stderr: Io.Writer = Io.Writer.fixed(&buf);
    var p = Progress.start(&stderr, testing.io, .{
        .total_steps = 4,
        .is_tty = false,
        .colors = false,
        .on_event = Capture.onEvent,
        .on_event_ctx = &capture,
    });
    p.nextStep("scanning heap dump");
    try testing.expect(capture.last_fraction == null);
    p.setFraction(0.5);
    try testing.expect(capture.last_fraction != null);
    try testing.expectApproxEqAbs(@as(f64, 0.5), capture.last_fraction.?, 1e-9);
}
