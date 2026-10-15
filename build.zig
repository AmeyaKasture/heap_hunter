const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const log_level = b.option([]const u8, "log-level", "Minimum log level (err, warn, info, debug)") orelse switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe => "info",
        .ReleaseFast, .ReleaseSmall => "err",
    };

    const stack_traces = b.option(bool, "stack-traces", "Enable stack trace capture and dumping") orelse switch (optimize) {
        .Debug => true,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
    };

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "log_level", log_level);
    build_options.addOption(bool, "stack_traces", stack_traces);
    const build_options_mod = build_options.createModule();

    const log_mod = b.addModule("log", .{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const mod = b.addModule("heaphunter", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "log", .module = log_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "hunt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "heaphunter", .module = mod },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "log", .module = log_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run hunt");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
