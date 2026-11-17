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
    const raylib_lib = raylib_dep.artifact("raylib");
    if (target.result.os.tag == .windows)
        guardWindowsGlfw(b, raylib_lib, "src/veil_glfw_focus.h");
    exe.root_module.linkLibrary(raylib_lib);
    // GUI subsystem on Windows release builds: no console window behind the dashboard.
    if (target.result.os.tag == .windows and optimize != .Debug) exe.subsystem = .Windows;
    // The Windows FILE icon — same resource the merged `veil` binary embeds (see the root build.zig), so a
    // standalone veil-desk.exe is branded identically wherever it sits on disk.
    if (target.result.os.tag == .windows) exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/veil.rc") });
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
    // The SERVER's conversation -> build-tree mapping (src/worker/chat/paths.zig), wired into the tests ONLY:
    // chat.zig's buildRelFor is its local twin, and a test holds the two to the same answers, so the tree the
    // desk runs delegated tools and writes pushed files in cannot drift from the server's again.
    const chatpaths = b.createModule(.{
        .root_source_file = b.path("../src/worker/chat/paths.zig"),
        .target = target,
        .optimize = .Debug,
    });
    tests.root_module.addImport("chatpaths", chatpaths);
    // tests.zig pulls theme.zig, which reaches assets.zig — the test module needs the same embeds or the
    // @embedFile names do not resolve.
    addDeskAssets(b, tests.root_module);
    tests.root_module.linkLibrary(raylib_lib);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run veil-desk unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Splice the guard into the bundled GLFW translation unit after GLFW has
/// configured the Win32 headers. Keep the fetched Raylib package immutable.
pub fn guardWindowsGlfw(b: *std.Build, raylib_lib: *std.Build.Step.Compile, header: []const u8) void {
    const module = raylib_lib.root_module;
    for (module.link_objects.items, 0..) |link, link_index| {
        if (link != .c_source_files) continue;
        const sources = link.c_source_files;
        for (sources.files, 0..) |file, i| {
            if (!std.mem.eql(u8, std.fs.path.basename(file), "rglfw.c")) continue;
            const original_path = sources.root.path(b, file).getPath(b);
            const original = std.Io.Dir.cwd().readFileAlloc(b.graph.io, original_path, b.allocator, .limited(64 * 1024)) catch
                @panic("could not read Raylib's bundled GLFW source");
            const include = "#include \"external/glfw/src/win32_window.c\"";
            const offset = std.mem.indexOf(u8, original, include) orelse
                @panic("could not find the bundled GLFW Win32 implementation");
            const guarded =
                \\#include "veil_glfw_focus.h"
                \\#include "external/glfw/src/win32_window.c"
                \\#undef GetActiveWindow
            ;
            const patched = std.mem.concat(b.allocator, u8, &.{
                original[0..offset],
                guarded,
                original[offset + include.len ..],
            }) catch @panic("out of memory adding the GLFW focus guard");
            const flags = std.mem.concat(b.allocator, []const u8, &.{ sources.flags, &.{
                "-I",
                std.fs.path.dirname(original_path).?,
                "-I",
                std.fs.path.dirname(b.path(header).getPath(b)).?,
            } }) catch @panic("out of memory adding the GLFW include paths");
            if (sources.files.len == 1) {
                _ = module.link_objects.orderedRemove(link_index);
            } else {
                sources.files = std.mem.concat(b.allocator, []const u8, &.{
                    sources.files[0..i],
                    sources.files[i + 1 ..],
                }) catch @panic("out of memory separating the GLFW translation unit");
            }
            module.addCSourceFile(.{
                .file = b.addWriteFiles().add("veil-rglfw.c", patched),
                .flags = flags,
                .language = sources.language,
            });
            return;
        }
    }
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
    mod.addAnonymousImport("desk_roles_json", .{ .root_source_file = b.path("roles.json") }); // the prebuilt chat-role catalog (src/roles.zig)
}
