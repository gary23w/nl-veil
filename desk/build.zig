//! Build script — produces `veil-desk`, the native desktop dashboard for nl-veil.
//! Cross-platform via raylib (win/linux/mac); the tray + toast layer is per-OS (src/tray.zig).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default ReleaseSafe, NOT Debug (standardOptimizeOption only applies its preferred mode when --release is
    // passed, so plain `zig build` was quietly shipping Debug: unoptimized text-measure loops pinned a core just
    // drawing a long chat message). ReleaseSafe keeps bounds checks — a snapshot-buffer overrun already crashed
    // the client once, and Fast would have turned that into silent memory corruption. -Doptimize=Debug for dev.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimize mode (default ReleaseSafe)") orelse .ReleaseSafe;

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

    // ---- unit tests ----
    // src/tests.zig references every test-bearing desk file; without a build-graph test step these tests
    // were not runnable at all (chat.zig pulls theme.zig → raylib, so a bare `zig test src/chat.zig` cannot
    // compile). Debug on purpose: tests want every safety check; ReleaseSafe is a shipping concern.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    tests.root_module.addImport("raylib", raylib_dep.module("raylib"));
    tests.root_module.linkLibrary(raylib_dep.artifact("raylib"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run veil-desk unit tests");
    test_step.dependOn(&run_tests.step);
}
