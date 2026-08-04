//! Build script — produces the `veil` binary: ONE self-contained app. The desktop GUI (desk/src/*) is
//! compiled INTO it and runs in-process, so the release bundle is a single executable with no veil-desk.exe
//! beside it.
//!
//! `-Dapp=false` builds the SERVER-ONLY binary: no raylib module, no raylib fetch, nothing that touches
//! GL/X11 — that is the build for a headless host or CI box. It does NOT imply a lean build: -Dbuiltin and
//! -Dvulkan default TRUE independently, so `-Dapp=false` alone still fetches llama.cpp, the Khronos headers
//! and ~50MB of pre-built Vulkan shaders. This line previously said "no lazyDependency fetch" flatly, which
//! reads as "server-only needs nothing from the network" and is why a CI failure on exactly those two
//! downloads looked like a broken build. Add -Dbuiltin=false for the genuinely lean, no-network build
//! (that is what scripts/check.sh's server-only gate does). The default (`-Dapp=true`) is the
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
    // The Windows FILE icon (Explorer, shortcuts, pinned taskbar entries). setWindowIcon only dresses a
    // running window, so without this resource the shipped veil.exe sat on disk wearing the generic
    // executable glyph. Windows-only: .rc is a Windows resource format and resinator only runs for it.
    if (target.result.os.tag == .windows) exe.root_module.addWin32ResourceFile(.{ .file = b.path("desk/assets/veil.rc") });

    // ---- embedded Lua 5.4 (the plugin/theme runtime) ----
    // vendor/lua is compiled straight into the binary; src/plug/lua.zig binds it. This is what makes
    // themes and plugins (src/plug/*) load. libc comes along with it (the server-only build otherwise
    // does not link libc — Lua needs it, so addLua sets it).
    addLua(b, exe.root_module);

    // ---- the BUILT-IN model engine (embedded inference; -Dbuiltin, default true) ----
    // The plug-and-play tier: the server serves the-veil-12b itself from a downloaded GGUF, no
    // separate local model runtime. Same compile-the-C-in pattern as Lua above, but the ~15MB of
    // ggml+llama source arrives as a LAZY hash-pinned dependency (like raylib for -Dapp) instead of
    // living in vendor/ — the repo stays light and `-Dbuiltin=false` never even fetches it.
    // build_options.builtin gates the ONE construction site (main.zig); everything else about the
    // feature (endpoint, downloader, catalog entry) compiles in every build and simply resolves
    // "unavailable" when this is off.
    const with_builtin = b.option(bool, "builtin", "compile the built-in model engine into `veil` (default true; -Dbuiltin=false = lean build, the builtin provider reports unavailable)") orelse true;
    const llama_dep: ?*std.Build.Dependency = if (with_builtin) b.lazyDependency("llama_cpp", .{}) else null;
    const builtin_on = with_builtin and llama_dep != null;
    // The GPU tier: the Vulkan backend compiled in, shaders from the pre-generated artifact (no
    // Vulkan SDK at build), loader dlopen'd at run (no GPU = clean CPU fallback). Off on macOS
    // (no native Vulkan there — Apple silicon's fast unified-memory CPU path serves until a Metal
    // tier exists). -Dvulkan=false keeps the small binary: the shader payload is ~50MB of exe.
    const with_vulkan = b.option(bool, "vulkan", "compile the GPU (Vulkan) backend into the built-in engine (default true off macOS; adds ~50MB of embedded shaders)") orelse true;
    const want_vk = builtin_on and with_vulkan and target.result.os.tag != .macos;
    const vk_headers: ?*std.Build.Dependency = if (want_vk) b.lazyDependency("vulkan_headers", .{}) else null;
    const spv_headers: ?*std.Build.Dependency = if (want_vk) b.lazyDependency("spirv_headers", .{}) else null;
    const vk_shaders: ?*std.Build.Dependency = if (want_vk) b.lazyDependency("veil_vulkan_shaders", .{}) else null;
    const vulkan_on = want_vk and vk_headers != null and spv_headers != null and vk_shaders != null;
    if (llama_dep) |lc| addLlamaCpp(b, exe.root_module, lc, target, vulkan_on);
    if (vulkan_on) addVulkan(b, exe.root_module, llama_dep.?, vk_headers.?, spv_headers.?, vk_shaders.?, target);

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
    build_options.addOption(bool, "builtin", builtin_on);
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

        // LINUX: hand the final link to the SYSTEM linker instead of LLD.
        //
        // raylib does the right thing — it calls linkSystemLibrary("GL"/"X11"/"Xrandr"/…) — but Zig 0.16
        // resolves those to absolute paths and archives them INTO libraylib.a, so the static library ends up
        // carrying `/usr/lib/x86_64-linux-gnu/libGL.so` as an archive MEMBER. LLD only warns about that
        // ("neither ET_REL nor LLVM bitcode") and links fine, but Zig promotes any unexpected LLD stderr to
        // a hard error, so `zig build` printed a compile failure while still exiting 0. That took down the
        // linux-x86_64 release bundle as well as the --full acceptance gate; it was invisible for a while
        // because check.sh read the zero exit as success (fixed separately).
        //
        // The system linker accepts a .so sitting in an archive without editorialising, which is all that is
        // needed here. Scoped as tightly as it can be: Linux only, GUI build only. Windows and macOS keep
        // LLD, and -Dapp=false never reaches this block because it links no raylib at all. ubuntu-latest
        // ships cc, and the workflow already installs the GL/X11 dev packages this needs.
        if (target.result.os.tag == .linux) exe.use_lld = false;
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
    // The SAME web assets the exe embeds (above). Without these the test module cannot even name
    // ASSET_HTML/ASSET_JS — `@embedFile("index.html")` fails to resolve — so no test could assert
    // anything about the shipped page. It went unnoticed because Zig's analysis is lazy: main.zig
    // compiles fine under test right up until some test actually REFERENCES one of these consts,
    // which nothing did until the homepage-route audit. Same lazy-collection trap as the tests that
    // silently never ran (ledger 0029), wearing different clothes. (0077)
    inline for (.{ "index.html", "app.js", "styles.css", "models.json" }) |asset| {
        tests.root_module.addAnonymousImport(asset, .{ .root_source_file = b.path("web/public/" ++ asset) });
    }
    addLua(b, tests.root_module); // src/plug/* tests bind the embedded Lua
    // The suite is server-side only and never links raylib, so it always sees gui=false — a test module that
    // pulled the GUI in would need GL on every CI box, which is exactly what -Dapp=false exists to avoid.
    const test_options = b.addOptions();
    test_options.addOption(bool, "gui", false);
    // Tests never compile the inference library: builtin_endpoint/builtin/modelpull test against a
    // MOCK engine, and llamaeng.zig's externs stay unreferenced when this is false.
    test_options.addOption(bool, "builtin", false);
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

/// Compile the embedded inference library (the lazy `llama_cpp` dependency) into `mod`, CPU
/// backend only, plus the veil_ll_* C shim (src/worker/llamashim.c) that src/worker/llamaeng.zig
/// binds. Mirrors the library's own CPU build recipe: base + backend registry + one CPU variant
/// with the x86-64 AVX2 baseline (its default x64 release configuration) or the arm sources on
/// aarch64; anything else falls back to the generic kernels. C++17 with exceptions (the library
/// throws), UBSan off for the same reason as Lua below: its intentional aliasing is not ours to trap.
fn addLlamaCpp(b: *std.Build, mod: *std.Build.Module, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, vulkan: bool) void {
    mod.link_libc = true;
    mod.link_libcpp = true;

    for ([_][]const u8{ "include", "ggml/include", "ggml/src", "ggml/src/ggml-cpu", "src" }) |p|
        mod.addIncludePath(dep.path(p));

    // NDEBUG unconditionally: the library's asserts abort the whole server process, and the Debug
    // builds of THIS repo are for debugging veil, not ggml.
    const common = [_][]const u8{
        "-DNDEBUG",
        "-DGGML_VERSION=\"b10205\"",
        "-DGGML_COMMIT=\"b10205\"",
        "-DGGML_USE_CPU",
        "-fno-sanitize=undefined",
    };
    var cflags_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var cxxflags_list: std.ArrayListUnmanaged([]const u8) = .empty;
    cflags_list.appendSlice(b.allocator, &common) catch @panic("oom");
    cflags_list.append(b.allocator, "-std=c11") catch @panic("oom");
    cxxflags_list.appendSlice(b.allocator, &common) catch @panic("oom");
    cxxflags_list.append(b.allocator, "-std=c++17") catch @panic("oom");
    // glibc hides the affinity/clock/getline family behind _GNU_SOURCE; the library's own build
    // defines it on Linux, so the cross-compiled server target needs it too (mac and windows
    // compile clean without extra feature macros).
    if (target.result.os.tag == .linux) {
        cflags_list.append(b.allocator, "-D_GNU_SOURCE") catch @panic("oom");
        cxxflags_list.append(b.allocator, "-D_GNU_SOURCE") catch @panic("oom");
    }
    // the backend REGISTRY (ggml-backend-reg.cpp) only registers what this define admits — it must
    // ride every ggml unit whenever the Vulkan tier is compiled in (addVulkan adds the backend itself)
    if (vulkan) {
        cflags_list.append(b.allocator, "-DGGML_USE_VULKAN") catch @panic("oom");
        cxxflags_list.append(b.allocator, "-DGGML_USE_VULKAN") catch @panic("oom");
    }
    const cflags = cflags_list.items;
    const cxxflags = cxxflags_list.items;

    const arch = target.result.cpu.arch;
    const arch_flags: []const []const u8 = if (arch == .x86_64)
        &.{ "-msse4.2", "-mf16c", "-mfma", "-mbmi2", "-mavx", "-mavx2", "-DGGML_SSE42", "-DGGML_F16C", "-DGGML_FMA", "-DGGML_BMI2", "-DGGML_AVX", "-DGGML_AVX2" }
    else if (arch == .aarch64)
        &.{}
    else
        &.{"-DGGML_CPU_GENERIC"};

    // ---- ggml base + backend registry ----
    mod.addCSourceFiles(.{
        .root = dep.path("ggml/src"),
        .files = &.{ "ggml.c", "ggml-alloc.c", "ggml-quants.c" },
        .flags = cflags,
    });
    mod.addCSourceFiles(.{
        .root = dep.path("ggml/src"),
        .files = &.{ "ggml.cpp", "ggml-backend.cpp", "ggml-backend-meta.cpp", "ggml-backend-dl.cpp", "ggml-backend-reg.cpp", "ggml-opt.cpp", "ggml-threading.cpp", "gguf.cpp" },
        .flags = cxxflags,
    });

    // ---- the CPU backend, single variant ----
    const cpu_extra = [_][]const u8{ "-DGGML_USE_LLAMAFILE", "-DGGML_USE_CPU_REPACK" };
    addCFiles(b, mod, dep.path("ggml/src/ggml-cpu"), &.{ "ggml-cpu.c", "quants.c" }, cflags, arch_flags, &cpu_extra);
    addCFiles(b, mod, dep.path("ggml/src/ggml-cpu"), &.{ "ggml-cpu.cpp", "repack.cpp", "hbm.cpp", "traits.cpp", "binary-ops.cpp", "unary-ops.cpp", "vec.cpp", "ops.cpp", "amx/amx.cpp", "amx/mmq.cpp", "llamafile/sgemm.cpp" }, cxxflags, arch_flags, &cpu_extra);
    if (arch == .x86_64) {
        addCFiles(b, mod, dep.path("ggml/src/ggml-cpu"), &.{"arch/x86/quants.c"}, cflags, arch_flags, &cpu_extra);
        addCFiles(b, mod, dep.path("ggml/src/ggml-cpu"), &.{"arch/x86/repack.cpp"}, cxxflags, arch_flags, &cpu_extra);
    } else if (arch == .aarch64) {
        addCFiles(b, mod, dep.path("ggml/src/ggml-cpu"), &.{"arch/arm/quants.c"}, cflags, arch_flags, &cpu_extra);
        addCFiles(b, mod, dep.path("ggml/src/ggml-cpu"), &.{"arch/arm/repack.cpp"}, cxxflags, arch_flags, &cpu_extra);
    }

    // ---- llama ----
    mod.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &llama_sources,
        .flags = cxxflags,
    });
    // src/models/*.cpp (one graph per architecture, ~140 files) — enumerated from the fetched tree
    // at configure time, so a pin bump that adds a model never needs a hand-edit here.
    const io = b.graph.io;
    const models_dir = dep.path("src/models").getPath3(b, null);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var d = models_dir.root_dir.handle.openDir(io, models_dir.subPathOrDot(), .{ .iterate = true }) catch @panic("llama_cpp dependency: src/models missing");
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch @panic("llama_cpp dependency: src/models unreadable")) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".cpp")) continue;
        names.append(b.allocator, b.dupe(e.name)) catch @panic("oom");
    }
    mod.addCSourceFiles(.{
        .root = dep.path("src/models"),
        .files = names.items,
        .flags = cxxflags,
    });

    // ---- the veil_ll_* shim ----
    mod.addCSourceFiles(.{
        .root = b.path("src/worker"),
        .files = &.{"llamashim.c"},
        .flags = cflags,
    });
}

/// Compile the Vulkan backend + the pre-generated shader units into `mod`. The shader artifact was
/// generated with EXACTLY the GLSLC_SUPPORT define set below — the backend's #ifdefs must agree
/// with what the shaders actually contain, so these stay a matched pair with the release asset.
/// No import library: the backend's dynamic dispatcher dlopens the platform's Vulkan loader at
/// runtime, so a machine with no GPU (or no loader at all) boots normally and serves CPU.
fn addVulkan(b: *std.Build, mod: *std.Build.Module, llama: *std.Build.Dependency, headers: *std.Build.Dependency, spirv: *std.Build.Dependency, shaders: *std.Build.Dependency, target: std.Build.ResolvedTarget) void {
    mod.addIncludePath(headers.path("include"));
    mod.addIncludePath(spirv.path("include")); // spirv/unified1/spirv.hpp
    mod.addIncludePath(shaders.path("")); // the generated ggml-vulkan-shaders.hpp

    const flags = [_][]const u8{
        "-std=c++17",
        "-DNDEBUG",
        "-fno-sanitize=undefined",
        "-DGGML_USE_VULKAN",
        "-DGGML_VULKAN_COOPMAT_GLSLC_SUPPORT",
        "-DGGML_VULKAN_COOPMAT2_GLSLC_SUPPORT",
        "-DGGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT",
        "-DGGML_VULKAN_BFLOAT16_GLSLC_SUPPORT",
    };
    mod.addCSourceFiles(.{
        .root = llama.path("ggml/src/ggml-vulkan"),
        .files = &.{"ggml-vulkan.cpp"},
        .flags = &flags,
    });

    // every pre-generated shader unit in the artifact (one per upstream .comp source)
    const io = b.graph.io;
    const sdir = shaders.path("").getPath3(b, null);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var d = sdir.root_dir.handle.openDir(io, sdir.subPathOrDot(), .{ .iterate = true }) catch @panic("veil_vulkan_shaders artifact unreadable");
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch @panic("veil_vulkan_shaders artifact unreadable")) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".cpp")) continue;
        names.append(b.allocator, b.dupe(e.name)) catch @panic("oom");
    }
    if (names.items.len == 0) @panic("veil_vulkan_shaders artifact contains no shader units");
    mod.addCSourceFiles(.{
        .root = shaders.path(""),
        .files = names.items,
        .flags = &flags,
    });

    // the vkloader shim: the 3 symbols ggml-vulkan calls directly, forwarded to a lazily-dlopen'd
    // loader so the binary has NO load-time Vulkan dependency (see the file header). Vulkan headers
    // for the PFN typedefs; libdl on linux for dlopen.
    mod.addCSourceFiles(.{
        .root = b.path("src/worker"),
        .files = &.{"vkloader.c"},
        .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
    });
    if (target.result.os.tag == .linux) mod.linkSystemLibrary("dl", .{});
}

fn addCFiles(b: *std.Build, mod: *std.Build.Module, root: std.Build.LazyPath, files: []const []const u8, base: []const []const u8, arch: []const []const u8, extra: []const []const u8) void {
    var flags: std.ArrayListUnmanaged([]const u8) = .empty;
    flags.appendSlice(b.allocator, base) catch @panic("oom");
    flags.appendSlice(b.allocator, arch) catch @panic("oom");
    flags.appendSlice(b.allocator, extra) catch @panic("oom");
    mod.addCSourceFiles(.{ .root = root, .files = files, .flags = flags.items });
}

const llama_sources = [_][]const u8{
    "llama-adapter.cpp",
    "llama-arch.cpp",
    "llama-batch.cpp",
    "llama-chat.cpp",
    "llama-context.cpp",
    "llama-cparams.cpp",
    "llama-grammar.cpp",
    "llama-graph.cpp",
    "llama-hparams.cpp",
    "llama-impl.cpp",
    "llama-io.cpp",
    "llama-kv-cache-dsa.cpp",
    "llama-kv-cache-dsv4.cpp",
    "llama-kv-cache-iswa.cpp",
    "llama-kv-cache.cpp",
    "llama-memory-hybrid-iswa.cpp",
    "llama-memory-hybrid.cpp",
    "llama-memory-recurrent.cpp",
    "llama-memory.cpp",
    "llama-mmap.cpp",
    "llama-model-loader.cpp",
    "llama-model-saver.cpp",
    "llama-model.cpp",
    "llama-quant.cpp",
    "llama-sampler.cpp",
    "llama-vocab.cpp",
    "llama.cpp",
    "unicode-data.cpp",
    "unicode.cpp",
};

/// Compile the vendored Lua 5.4 core into `mod` and make its headers reachable. The plugin/theme
/// runtime (src/plug/lua.zig) declares the C API as externs, so no translate-c step is needed — just
/// the objects + libc. UBSan is disabled for these files: Lua's GC and VM do intentional
/// aliasing/overflow the standard C sanitizer flags, and they are not our bugs to trap.
fn addLua(b: *std.Build, mod: *std.Build.Module) void {
    const lua_sources = [_][]const u8{
        "lapi.c",    "lauxlib.c",  "lbaselib.c", "lcode.c",    "lcorolib.c", "lctype.c",
        "ldblib.c",  "ldebug.c",   "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
        "linit.c",   "liolib.c",   "llex.c",     "lmathlib.c", "lmem.c",     "loadlib.c",
        "lobject.c", "lopcodes.c", "loslib.c",   "lparser.c",  "lstate.c",   "lstring.c",
        "lstrlib.c", "ltablib.c",  "ltable.c",   "ltm.c",      "lundump.c",  "lutf8lib.c",
        "lvm.c",     "lzio.c",
    };
    mod.addCSourceFiles(.{
        .root = b.path("vendor/lua"),
        .files = &lua_sources,
        .flags = &.{ "-std=gnu99", "-fno-sanitize=undefined" },
    });
    mod.addIncludePath(b.path("vendor/lua"));
    mod.link_libc = true;
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
