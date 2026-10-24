//! Progress reporting for long-running CLI operations.
//!
//! When stderr is a terminal, this module renders a one-line progress bar with
//! a checkpoint label (e.g., "[=====>                         ] [1/9] scanning
//! heap dump"). On non-TTY output it prints plain checkpoint lines instead, so
//! progress can be captured in logs.
const std = @import("std");
const Io = std.Io;
const Cli = @import("Cli.zig");

pub const Progress = struct {
    stderr: *Io.Writer,
    io: Io,
    is_tty: bool,
    colors: bool,
    total_steps: usize,
    current_step: usize,
    label: []const u8,
    disabled: bool,
    finished: bool,

    const bar_width = 30;
    const fill_char = "=";
    const head_char = ">";
    const empty_char = " ";

    pub const Options = struct {
        total_steps: usize,
        is_tty: bool,
        colors: bool,
        disabled: bool = false,
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
            .disabled = options.disabled,
            .finished = false,
        };
        if (!options.disabled) {
            progress.render();
        }
        return progress;
    }

    /// Advance to the next step and change the label.
    pub fn nextStep(self: *Progress, label: []const u8) void {
        if (self.disabled or self.finished) return;
        self.current_step += 1;
        self.label = label;
        self.render();
    }

    /// Update the label of the current step without advancing.
    pub fn setLabel(self: *Progress, label: []const u8) void {
        if (self.disabled or self.finished) return;
        self.label = label;
        self.render();
    }

    /// Refresh the display. This is a no-op for the bar-based progress
    /// reporter because the bar advances only on step changes.
    pub fn tick(self: *Progress) void {
        if (self.disabled or self.finished or !self.is_tty) return;
        // Re-render so the line stays visible on slow terminals, but the bar
        // only advances when nextStep is called.
        self.render();
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
            (self.current_step * bar_width) / self.total_steps;
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
        self.stderr.print("[{d}/{d}] {s}\n", .{ self.current_step, self.total_steps, self.label }) catch {};
        self.stderr.flush() catch {};
    }

    fn clearLine(self: *Progress) void {
        self.stderr.writeAll("\x1b[2K\r") catch {};
    }
};

/// Create a progress reporter for a command with the given number of steps.
/// If `disabled` is true, progress is suppressed entirely.
pub fn create(stderr: *Io.Writer, io: Io, total_steps: usize, disabled: bool) Progress {
    return Progress.start(stderr, io, .{
        .total_steps = total_steps,
        .is_tty = Cli.isStderrTty(io),
        .colors = Cli.colorsEnabled(),
        .disabled = disabled,
    });
}
