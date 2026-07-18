//! Build script — produces the `veil` binary: ONE self-contained app. The desktop GUI (desk/src/*) is
//! compiled INTO it and runs in-process, so the release bundle is a single executable with no veil-desk.exe
//! beside it.
//!
//! `-Dapp=false` builds the SERVER-ONLY binary: no raylib module, no lazyDependency fetch, nothing that
//! touches GL/X11 — that is the build for a headless host or CI box. The default (`-Dapp=true`) is the
//! shipping app. desk/ keeps its own build.zig and still produces a standalone veil-desk for development
//! (`cd desk && zig build`, or `zig build desk` from here).

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast by DEFAULT — and this time the code actually does it. `standardOptimizeOption` with a
    // preferred mode only applies that preference when `--release` is passed with NO value, so a bare
    // `zig build` shipped a DEBUG binary while this comment claimed otherwise, `--release=small` was a
    // silent no-op (byte-identical to fast), and `-Doptimize=ReleaseSmall` errored "invalid option".
    // Switching on b.release_mode ourselves fixes all three: bare build = ReleaseFast (the engine's hot
    // paths — BM25 page fitting, salvage scans, VCS merges, atlas matching — run 5-20x slower in Debug),
    // `--release=small` reaches ReleaseSmall, and devs keep `zig build -Doptimize=Debug`.
    // NOTE: `-Doptimize=` is only accepted when no `--release=` flag is present (they are the same knob).
    const optimize: std.builtin.OptimizeMode = switch (b.release_mode) {
        .off => b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast,
        .any, .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };

    // Debug info / PDB is ~16MB beside a 5.5MB exe — three quarters of the shipped bytes, for symbols no
    // end user can act on. Strip by default for every release mode; a dev debugging a crash keeps symbols
    // automatically via -Doptimize=Debug, or forces them back with -Dstrip=false.
    // (In Zig 0.16 `strip` is a MODULE property, not a Compile field — it goes into createModule below.)
    const strip = b.option(bool, "strip", "omit debug info / PDB (default: on for release)") orelse (optimize != .Debug);

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    // THE model catalog, as a first-class MODULE rather than a relative-path import.
    //
    // It has to be a module now that the desk sources are compiled into this binary: desk/src/catalog.zig has
    // always imported "modelcfg", and a source file may belong to exactly ONE module — so leaving
    // src/worker/modelcfg.zig as a plain `@import("../modelcfg.zig")` inside the root module while also
    // handing it to the desk is a hard compile error ("file exists in modules 'root' and 'modelcfg'").
    // One module, imported by name from both sides, is also just the honest description: the server and the
    // desk read the SAME comptime-parsed models.yaml.
    const modelcfg = b.createModule(.{
        .root_source_file = b.path("src/worker/modelcfg.zig"),
        .target = target,
        .optimize = optimize,
    });
    modelcfg.addAnonymousImport("models.yaml", .{ .root_source_file = b.path("models.yaml") });

    const exe = b.addExecutable(.{
        .name = "veil",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    // Emit each function/data symbol into its own section so the linker can drop the unreachable ones.
    // Worth ~2% on its own; free, and it compounds with ReleaseSmall.
    exe.link_function_sections = true;
    exe.link_data_sections = true;
    exe.link_gc_sections = true;
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe.root_module.addAnonymousImport("index.html", .{ .root_source_file = b.path("web/public/index.html") });
    exe.root_module.addAnonymousImport("app.js", .{ .root_source_file = b.path("web/public/app.js") });
    exe.root_module.addAnonymousImport("styles.css", .{ .root_source_file = b.path("web/public/styles.css") });
    exe.root_module.addAnonymousImport("models.json", .{ .root_source_file = b.path("web/public/models.json") });
    exe.root_module.addImport("modelcfg", modelcfg);

    // ---- the desktop GUI, compiled IN (one binary) ----
    // Was: shell out to desk/'s own `zig build` and ship a second veil-desk.exe that the server SPAWNED.
    // Now: desk/src/main.zig is imported as the module "desk" and src/main.zig calls desk.runApp() on the
    // MAIN thread (raylib's window/event loop is main-thread-only), with httpz listening on a background
    // thread. No child process, no second executable in the bundle.
    const with_app = b.option(bool, "app", "compile the desktop GUI into `veil` and run it in-process (default true; -Dapp=false = server-only, no raylib/GL)") orelse true;
    // Resolved only when the app is wanted, so -Dapp=false never fetches raylib at all (.lazy in the .zon).
    const raylib_dep: ?*std.Build.Dependency = if (with_app) b.lazyDependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    // If the lazy fetch has not landed yet, lazyDependency returns null and the build system re-runs this
    // script after fetching. Track the ACTUAL outcome (not the request) so build_options.gui can never claim
    // a GUI that has no module behind it — that mismatch would be a confusing @import("desk") failure.
    const gui = with_app and raylib_dep != null;

    const build_options = b.addOptions();
    build_options.addOption(bool, "gui", gui);
    exe.root_module.addImport("build_options", build_options.createModule());

    if (raylib_dep) |raylib| {
        const desk_mod = b.createModule(.{
            .root_source_file = b.path("desk/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        });
        desk_mod.addImport("raylib", raylib.module("raylib"));
        desk_mod.addImport("modelcfg", modelcfg);
        addDeskAssets(b, desk_mod);

        exe.root_module.addImport("desk", desk_mod);
        exe.root_module.linkLibrary(raylib.artifact("raylib"));
        // desk/src/main.zig runs on std.heap.c_allocator, and raylib is a C library: the merged binary links
        // libc. (The server-only build does not.)
        exe.root_module.link_libc = true;
    }
    // DELIBERATELY NOT `exe.subsystem = .Windows`, even though desk/build.zig sets it for veil-desk. `veil`
    // is also the CLI: a GUI-subsystem binary makes cmd.exe/PowerShell stop waiting for it and throws away
    // its stdout even when redirected, gutting every CLI verb. The double-click console is already solved a
    // better way — see detachOwnConsole in src/main.zig, which relaunches windowless ONLY when no shell is
    // attached to the console.
    b.installArtifact(exe);

    // ---- veil-desk, standalone (development only; NOT part of the bundle) ----
    // desk/ is still its own package with its own build.zig + raylib dep, so `zig build desk` shells out to
    // it. Wrapped to ALWAYS exit 0 — a headless box that can't link GL/X11 must not fail this build. On
    // Windows the extra `\"` around zig_exe double-quoted under cmd /C's own quote rules (the classic
    // argv-quoting trap) — the zig path has no spaces here, so pass it bare and let `& exit /b 0` force
    // success. Nothing depends on this step: the shipped `veil` no longer looks for a veil-desk binary.
    const zig_exe = b.graph.zig_exe;
    const desk_cmd = if (builtin.os.tag == .windows)
        b.addSystemCommand(&.{ "cmd", "/C", b.fmt("{s} build & exit /b 0", .{zig_exe}) })
    else
        b.addSystemCommand(&.{ "sh", "-c", b.fmt("'{s}' build || true", .{zig_exe}) });
    desk_cmd.setCwd(b.path("desk"));
    desk_cmd.setName("build veil-desk standalone (best-effort)");
    const desk_step = b.step("desk", "Build the standalone veil-desk binary (dev only — the app GUI is compiled into `veil`)");
    desk_step.dependOn(&desk_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the veil hive-mind control plane");
    run_step.dependOn(&run_cmd.step);

    // ---- unit tests ----
    // src/tests.zig references every test-bearing file; a bare `zig test src/worker/run.zig` only collects
    // the tests reachable from run.zig and silently skips the rest of the suite. Tests build Debug on
    // purpose: the exe defaults to ReleaseFast, which strips the safety checks tests exist to exercise.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    tests.root_module.addImport("httpz", httpz.module("httpz"));
    tests.root_module.addImport("modelcfg", modelcfg); // the catalog module carries its own models.yaml embed
    // The suite is server-side only and never links raylib, so it always sees gui=false — a test module that
    // pulled the GUI in would need GL on every CI box, which is exactly what -Dapp=false exists to avoid.
    const test_options = b.addOptions();
    test_options.addOption(bool, "gui", false);
    tests.root_module.addImport("build_options", test_options.createModule());
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_tests.step);

    // modelcfg is its OWN module, and `zig test` only collects test blocks from files inside the module
    // it is rooted at — so `_ = @import("modelcfg")` in src/tests.zig references the catalog but does NOT
    // run its tests. Promoting the file to a module therefore silently dropped 8 tests (the models.yaml
    // parse and the whole senseModel tier suite) while the runner still reported "All tests passed".
    // A module needs its own test artifact; this is that artifact.
    const modelcfg_tests = b.addTest(.{ .root_module = modelcfg });
    test_step.dependOn(&b.addRunArtifact(modelcfg_tests).step);
}

/// Register the desk's bundled art + type as anonymous imports so desk/src/assets.zig can @embedFile them.
/// MUST mirror desk/build.zig's helper of the same name — the desk sources are shared between this merged
/// build and the standalone veil-desk build, and a missing embed name is a compile error in assets.zig.
///
/// These are compiled in, not shipped alongside: the desk used to load each one from a CWD-relative path, so
/// a released bundle (whose CWD is wherever the user launched it) missed every probe and silently fell back
/// to a generic tray icon, a procedural bust, and Comic Sans. See desk/src/assets.zig.
fn addDeskAssets(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("desk_icon16_png", .{ .root_source_file = b.path("desk/assets/icon16x16.png") });
    mod.addAnonymousImport("desk_icon48_png", .{ .root_source_file = b.path("desk/assets/icon48x48.png") });
    mod.addAnonymousImport("desk_opendyslexic_regular_ttf", .{ .root_source_file = b.path("desk/assets/fonts/OpenDyslexic3-Regular.ttf") });
    mod.addAnonymousImport("desk_opendyslexic_bold_ttf", .{ .root_source_file = b.path("desk/assets/fonts/OpenDyslexic3-Bold.ttf") });
}
