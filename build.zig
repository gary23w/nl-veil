//! Build script — produces the `veil` binary (the hive-mind engine). Desktop is opt-in: pass
//! `-Ddesktop=true` to also build veil-desk (desktop/) and run the server in desktop-host mode.
//! Headless/CI boxes can keep the default server-only build and never touch raylib's GL/X11 libs.

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
    // models.yaml — THE model catalog (src/worker/modelcfg.zig @embedFile's it). Registered on the root
    // module so the embed resolves; the desk build and both test modules register their own copy too.
    exe.root_module.addAnonymousImport("models.yaml", .{ .root_source_file = b.path("models.yaml") });
    b.installArtifact(exe);

    // ---- veil-desk (desktop dashboard) ----
    // It's a separate package (desktop/ has its own build.zig.zon + raylib dep), so we shell out to its
    // own `zig build` rather than pull raylib into this graph. Wrapped to ALWAYS exit 0 — a headless box
    // that can't link GL/X11 must not fail the server build; the desktop binary just won't be produced.
    // Wrap so a failed desktop build (headless box, no GL/X11) can't fail the server build. On Windows the
    // extra `\"` around zig_exe double-quoted under cmd /C's own quote rules (the classic argv-quoting
    // trap) — the zig path has no spaces here, so pass it bare and let `& exit /b 0` force success.
    const zig_exe = b.graph.zig_exe;
    const desk_cmd = if (builtin.os.tag == .windows)
        b.addSystemCommand(&.{ "cmd", "/C", b.fmt("{s} build & exit /b 0", .{zig_exe}) })
    else
        b.addSystemCommand(&.{ "sh", "-c", b.fmt("'{s}' build || true", .{zig_exe}) });
    desk_cmd.setCwd(b.path("desk"));
    desk_cmd.setName("build veil-desk (best-effort)");
    const desk_step = b.step("desk", "Build the veil-desk desktop dashboard");
    desk_step.dependOn(&desk_cmd.step);

    const with_desk = b.option(bool, "desk", "also build veil-desk + run server with --desk (default false)") orelse false;
    if (with_desk) b.getInstallStep().dependOn(&desk_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (with_desk) run_cmd.addArg("--desk");
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
    tests.root_module.addAnonymousImport("models.yaml", .{ .root_source_file = b.path("models.yaml") }); // modelcfg tests @embedFile it
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_tests.step);
}
