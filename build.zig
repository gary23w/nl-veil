//! Build script — produces the `veil` binary (the hive-mind engine). Desktop is opt-in: pass
//! `-Ddesktop=true` to also build veil-desk (desktop/) and run the server in desktop-host mode.
//! Headless/CI boxes can keep the default server-only build and never touch raylib's GL/X11 libs.

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast by DEFAULT: this binary is what every user runs (deploy.py builds it with a bare
    // `zig build`), and the engine's hot paths — BM25 page fitting, salvage scans over long replies,
    // VCS merges, atlas matching on every fetch — run 5-20x slower in Debug. Developers still get a
    // debug build explicitly with `zig build -Doptimize=Debug`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

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
        }),
    });
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe.root_module.addAnonymousImport("index.html", .{ .root_source_file = b.path("web/public/index.html") });
    exe.root_module.addAnonymousImport("app.js", .{ .root_source_file = b.path("web/public/app.js") });
    exe.root_module.addAnonymousImport("styles.css", .{ .root_source_file = b.path("web/public/styles.css") });
    exe.root_module.addAnonymousImport("models.json", .{ .root_source_file = b.path("web/public/models.json") });
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
}
