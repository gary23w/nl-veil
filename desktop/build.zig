//! Build script — produces `veil-desk`, the native desktop dashboard for nl-veil.
//! Cross-platform via raylib (win/linux/mac); the tray + toast layer is per-OS (src/tray.zig).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "veil-desk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("raylib", raylib_dep.module("raylib"));
    exe.root_module.linkLibrary(raylib_dep.artifact("raylib"));
    // GUI subsystem on Windows release builds: no console window behind the dashboard.
    if (target.result.os.tag == .windows and optimize != .Debug) exe.subsystem = .Windows;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run veil-desk");
    run_step.dependOn(&run_cmd.step);
}
