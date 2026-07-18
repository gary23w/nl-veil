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

    // The SHARED model catalog: the server's src/worker/modelcfg.zig, comptime-parsing the repo-root
    // models.yaml (registered as its anonymous import). catalog.zig imports "modelcfg" so every desk model
    // menu reads the SAME source of truth the server does. A fresh module per build target keeps its
    // comptime-parsed data local to this package.
    const modelcfg = b.createModule(.{
        .root_source_file = b.path("../src/worker/modelcfg.zig"),
        .target = target,
        .optimize = optimize,
    });
    modelcfg.addAnonymousImport("models.yaml", .{ .root_source_file = b.path("../models.yaml") });

    const exe = b.addExecutable(.{
        .name = "veil-desk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("raylib", raylib_dep.module("raylib"));
    exe.root_module.addImport("modelcfg", modelcfg);
    addDeskAssets(b, exe.root_module);
    exe.root_module.linkLibrary(raylib_dep.artifact("raylib"));
    // GUI subsystem on Windows release builds: no console window behind the dashboard.
    if (target.result.os.tag == .windows and optimize != .Debug) exe.subsystem = .Windows;
    // Per-function/data sections + --gc-sections: let the linker drop code and constants nothing reaches.
    // MEASURED on this target (x86_64-windows, ReleaseSafe): exactly 0 bytes — the COFF link already drops
    // whatever these would, so do NOT expect them to offset the embedded assets here. Kept only because
    // they cost nothing to carry and do pay off on ELF targets. Purely a link-time size knob: no codegen
    // or safety change, so ReleaseSafe's bounds checks (see above) are untouched.
    exe.link_function_sections = true;
    exe.link_data_sections = true;
    exe.link_gc_sections = true;
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
    tests.root_module.addImport("modelcfg", modelcfg);
    // tests.zig pulls theme.zig, which reaches assets.zig — the test module needs the same embeds or the
    // @embedFile names do not resolve.
    addDeskAssets(b, tests.root_module);
    tests.root_module.linkLibrary(raylib_dep.artifact("raylib"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run veil-desk unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Register the bundled art + type as anonymous imports so src/assets.zig can @embedFile them.
///
/// These MUST be compiled in, not shipped alongside: the desk used to load each one from a CWD-relative
/// path, so a released bundle (whose CWD is wherever the user launched it) missed every probe and silently
/// fell back to a generic tray icon, a procedural bust, and Comic Sans. Shipping an assets/ dir does not
/// fix that — the paths resolve against the working directory, not the exe. See src/assets.zig.
///
/// Deliberately NOT here: the regular UI/mono faces. They resolve absolute system font paths that already
/// work in a bundle; embedding them would add megabytes for no behavioural gain.
fn addDeskAssets(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("desk_icon16_png", .{ .root_source_file = b.path("assets/icon16x16.png") });
    mod.addAnonymousImport("desk_icon48_png", .{ .root_source_file = b.path("assets/icon48x48.png") });
    mod.addAnonymousImport("desk_opendyslexic_regular_ttf", .{ .root_source_file = b.path("assets/fonts/OpenDyslexic3-Regular.ttf") });
    mod.addAnonymousImport("desk_opendyslexic_bold_ttf", .{ .root_source_file = b.path("assets/fonts/OpenDyslexic3-Bold.ttf") });
}
