//! OCR (vision-as-text) — extract the text of a RASTER image via the OS's BUILT-IN OCR engine. A dropped or
//! pasted screenshot has no DOM, so unlike a rendered browser tile its text can't come from the page. Per-OS:
//!   • Windows → Windows.Media.Ocr through a tiny WinRT PowerShell shim (zero install on Win10/11).
//!   • macOS   → the Vision framework (VNRecognizeTextRequest) through a tiny Swift shim run with `swift`.
//! Both are free, offline, and private (NO model ever sees the pixels — the Pixel-RAG promise). This module is
//! deliberately the OS-NATIVE tier only; when it returns "" (Linux, or a box missing the engine/toolchain) the
//! CALLER falls back to a vision-capable model (see pixelrag.ingestImage → llm.visionExtract) so extraction still
//! works on ANY machine.
//!
//! Best-effort everywhere: a spawn failure or non-zero exit returns "" so an attachment can never wedge a chat
//! turn. Each shim is written once per run dir (idempotent) and re-used.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.ocr);

/// The verified WinRT OCR shim. [System.IO.Path]::GetFullPath is REQUIRED — WinRT's GetFileFromPathAsync rejects
/// forward-slash / relative paths, and our tile paths are built with forward slashes. Emits the recognized lines
/// as UTF-8 to stdout, one per line.
const OCR_PS1 =
    \\param([Parameter(Mandatory=$true)][string]$Path)
    \\$ErrorActionPreference='Stop'
    \\Add-Type -AssemblyName System.Runtime.WindowsRuntime
    \\$asTaskGeneric=([System.WindowsRuntimeSystemExtensions].GetMethods()|?{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'})[0]
    \\function Await($t,$rt){$m=$asTaskGeneric.MakeGenericMethod($rt);$nt=$m.Invoke($null,@($t));try{$nt.Wait(-1)|Out-Null}catch{throw $_.Exception.InnerException.InnerException};$nt.Result}
    \\[Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]|Out-Null
    \\[Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]|Out-Null
    \\[Windows.Storage.StorageFile,Windows.Foundation,ContentType=WindowsRuntime]|Out-Null
    \\$full=[System.IO.Path]::GetFullPath($Path)
    \\$f=Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
    \\$s=Await ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    \\$d=Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
    \\$b=Await ($d.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    \\$e=[Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    \\if($null -eq $e){Write-Error 'no OCR language';exit 3}
    \\$r=Await ($e.RecognizeAsync($b)) ([Windows.Media.Ocr.OcrResult])
    \\[Console]::OutputEncoding=[Text.Encoding]::UTF8
    \\($r.Lines | %{$_.Text}) -join "`n"
;

/// The macOS Vision shim (compiled + run on demand by `swift`). VNRecognizeTextRequest is the OS's built-in text
/// recognizer; needs the Xcode command-line tools (`swift`) — present on any dev Mac, and installable with
/// `xcode-select --install`, no App Store. Best-effort: on any error it exits non-zero and the caller falls back.
const OCR_SWIFT =
    \\import Foundation
    \\import Vision
    \\import AppKit
    \\let a = CommandLine.arguments
    \\guard a.count > 1, let img = NSImage(contentsOfFile: a[1]),
    \\      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(2) }
    \\let req = VNRecognizeTextRequest()
    \\req.recognitionLevel = .accurate
    \\req.usesLanguageCorrection = true
    \\let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    \\do { try handler.perform([req]) } catch { exit(3) }
    \\let lines = (req.results ?? []).compactMap { ($0 as? VNRecognizedTextObservation)?.topCandidates(1).first?.string }
    \\print(lines.joined(separator: "\n"))
;

fn empty(gpa: std.mem.Allocator) []u8 {
    return gpa.dupe(u8, "") catch @constCast("");
}

fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

/// Extract the text of the PNG at `png_abs_path` (an ABSOLUTE path) using the OS OCR engine. Returns owned text
/// (caller frees); "" on any failure or on non-Windows. `run_dir` roots the `.pixelrag/ocr.ps1` shim.
pub fn extractImageText(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, run_dir: []const u8, png_abs_path: []const u8) []u8 {
    _ = environ; // the shim inherits the process environment; kept for signature symmetry with pixelrag ingest
    return switch (builtin.os.tag) {
        .windows => extractWin(gpa, io, run_dir, png_abs_path),
        .macos => extractMac(gpa, io, run_dir, png_abs_path),
        else => empty(gpa), // no built-in OS OCR (Linux etc.) — the caller falls back to a vision model
    };
}

/// Write `shim` into <run_dir>/.pixelrag/<name> once (idempotent), returning the owned absolute-ish path (caller
/// frees), or null on an allocation failure. Shared by the Windows + macOS shims.
fn writeShimOnce(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, name: []const u8, shim: []const u8) ?[]u8 {
    const dir = std.fmt.allocPrint(gpa, "{s}/.pixelrag", .{run_dir}) catch return null;
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch return null;
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| {} else |_| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = shim }) catch {};
    }
    return path;
}

/// Run `argv` (bounded stdout), returning its trimmed stdout; "" on a spawn failure or a non-zero exit.
fn runArgv(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, label: []const u8) []u8 {
    const res = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20) }) catch return empty(gpa);
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const exit = if (res.term == .exited) res.term.exited else @as(u8, 255);
    if (exit != 0) {
        log.info("OCR {s} failed (exit={d}): {s}", .{ label, exit, clip(res.stderr, 200) });
        return empty(gpa);
    }
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \r\n\t")) catch empty(gpa);
}

/// Windows built-in OCR (Windows.Media.Ocr) via the one-time WinRT PowerShell shim. Mirrors supervisor.zig's
/// `powershell -File <script> <args>` std.process.run shape.
fn extractWin(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, png_abs_path: []const u8) []u8 {
    const ps1 = writeShimOnce(gpa, io, run_dir, "ocr.ps1", OCR_PS1) orelse return empty(gpa);
    defer gpa.free(ps1);
    const argv = [_][]const u8{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, "-Path", png_abs_path };
    return runArgv(gpa, io, &argv, "win");
}

/// macOS built-in OCR (Vision, VNRecognizeTextRequest) via the one-time Swift shim run with `swift`. Best-effort:
/// if the Xcode command-line tools aren't installed (`swift` missing) or Vision errors, `swift` exits non-zero
/// and this returns "" — the caller then falls back to a vision model.
fn extractMac(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, png_abs_path: []const u8) []u8 {
    const swift = writeShimOnce(gpa, io, run_dir, "ocr.swift", OCR_SWIFT) orelse return empty(gpa);
    defer gpa.free(swift);
    const argv = [_][]const u8{ "swift", swift, png_abs_path };
    return runArgv(gpa, io, &argv, "mac");
}

// ---------------------------------------------------------------------------
// tests — the contract here is DEGRADATION, not recognition. Every path that cannot produce text
// (no engine, no toolchain, an unreadable image, a shim that dies mid-page) has to hand the caller
// an empty but freeable string, because that "" is the signal pixelrag.ingestImage reads to fall
// back to a vision model; an error escaping this module would wedge the chat turn the attachment
// arrived on instead. Recognition ITSELF is deliberately not asserted — that would be testing
// Windows.Media.Ocr and Vision, not this file.
//
// See harness/TESTING.md (Spawning a real subprocess): the empty-child-environment trap, and
// probing with a real round trip rather than "did it spawn".
// ---------------------------------------------------------------------------

/// TEST ONLY. The REAL process environment, exactly as main.zig builds it. `std.Io.Threaded.init(gpa, .{})`
/// hands children an EMPTY one, and a child that comes up with no PATH and no SystemRoot never spawns at
/// all — which is precisely the answer these tests exist to tell apart from "this box has no OCR engine".
fn testEnviron() std.process.Environ {
    return if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

/// TEST ONLY. Presence as a bool: `access` names its "absent" error differently per backend, and every
/// caller below only ever asks the yes/no question.
fn shimPresent(io: std.Io, path: []const u8) bool {
    return if (std.Io.Dir.cwd().access(io, path, .{})) |_| true else |_| false;
}

test "the shim is written once per run dir and is never rewritten under a running extraction" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-ocr-shim-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {}; // a previous crash may have left it
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // Both backends share this writer, and both shims must be able to live in one run dir: a machine
    // that is re-used across OSes (a synced data dir) must not have one clobber the other.
    inline for (.{ .{ "ocr.ps1", OCR_PS1 }, .{ "ocr.swift", OCR_SWIFT } }) |pair| {
        const name, const shim = pair;

        const p1 = writeShimOnce(gpa, io, root, name, shim) orelse return error.ShimWriteFailed;
        defer gpa.free(p1);
        try std.testing.expectEqualStrings(root ++ "/.pixelrag/" ++ name, p1);

        const written = try std.Io.Dir.cwd().readFileAlloc(io, p1, gpa, .limited(64 << 10));
        defer gpa.free(written);
        try std.testing.expectEqualStrings(shim, written); // byte-exact: a truncated shim would just fail forever

        // ONCE means once. Prove it by making the on-disk copy differ from the constant: if the second
        // call rewrote the file, the marker would be gone. (This is not pedantry — the shim is re-derived
        // on every single image, and a rewrite races the powershell/swift process already reading it.)
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p1, .data = "# EDITED-IN-PLACE" });
        const p2 = writeShimOnce(gpa, io, root, name, shim) orelse return error.ShimWriteFailed;
        defer gpa.free(p2);
        try std.testing.expectEqualStrings(p1, p2); // and the path it hands back is stable
        const after = try std.Io.Dir.cwd().readFileAlloc(io, p2, gpa, .limited(64 << 10));
        defer gpa.free(after);
        try std.testing.expectEqualStrings("# EDITED-IN-PLACE", after);
    }
}

test "runArgv: a missing tool, and a tool that prints and then fails, are both just empty text" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-ocr-run-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // Two stand-in shims with the same SHAPE as the real ones (an interpreter running a script this
    // module wrote): one that succeeds, one that writes a partial answer to stdout and then fails —
    // which is what a real OCR shim does when the engine dies part-way through a page.
    const win = builtin.os.tag == .windows;
    const ok_path = if (win) root ++ "\\ok.cmd" else root ++ "/ok.sh";
    const bad_path = if (win) root ++ "\\bad.cmd" else root ++ "/bad.sh";
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ok_path,
        .data = if (win) "@echo off\r\necho   ocr-probe  \r\n" else "echo '  ocr-probe  '\n",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = bad_path,
        .data = if (win) "@echo off\r\necho partial-page\r\nexit /b 3\r\n" else "echo partial-page\nexit 3\n",
    });
    const ok_argv: []const []const u8 = if (win) &.{ "cmd", "/d", "/c", ok_path } else &.{ "sh", ok_path };
    const bad_argv: []const []const u8 = if (win) &.{ "cmd", "/d", "/c", bad_path } else &.{ "sh", bad_path };

    // PROBE with a real round trip. Under an empty child environment even a working shell fails to
    // spawn, and then every assertion below would pass for the wrong reason — "" for all three.
    const good = runArgv(gpa, io, ok_argv, "probe");
    defer gpa.free(good);
    if (good.len == 0) return error.SkipZigTest; // no usable shell on this box; nothing below would mean anything
    try std.testing.expectEqualStrings("ocr-probe", good); // and stdout comes back TRIMMED, exactly

    // A tool that is not installed at all — the macOS-without-Xcode case, and every Linux box. The
    // caller must not be able to tell this apart from "the image had no text in it".
    const missing = runArgv(gpa, io, &.{ "nlveil-no-such-ocr-engine-9f3c1a", ok_path }, "missing");
    defer gpa.free(missing);
    try std.testing.expectEqualStrings("", missing);

    // A tool that runs, emits something, and then exits non-zero. The EXIT CODE decides: a partial
    // stdout must never be handed back as recognized text, or a half-OCR'd page enters the chat as
    // if it were the whole thing.
    const bad = runArgv(gpa, io, bad_argv, "failing");
    defer gpa.free(bad);
    try std.testing.expectEqualStrings("", bad);
}

test "extractImageText picks one backend per OS and answers empty — never an error — for an image it cannot read" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const root = "zig-ocr-extract-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // macOS is skipped rather than faked: `swift <script>` COMPILES the Vision shim on every single
    // invocation (seconds per call), so running it here would tax the whole suite to re-prove what the
    // two tests above already cover for that arm — the shim write, and runArgv's spawn/exit degradation.
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    const out = extractImageText(gpa, io, &env, root, root ++ "/no-such-screenshot.png");
    defer gpa.free(out); // the answer is ALWAYS owned by the caller, "" included
    try std.testing.expectEqualStrings("", out);

    // Backend selection is deterministic per OS, and it leaves a trace: the Windows arm writes its
    // shim before it spawns anything, and a box with no built-in OCR must not so much as create the
    // directory — it falls straight through so pixelrag can reach for a vision model.
    const shim_dir = root ++ "/.pixelrag";
    if (builtin.os.tag == .windows) {
        try std.testing.expect(shimPresent(io, shim_dir ++ "/ocr.ps1"));
        try std.testing.expect(!shimPresent(io, shim_dir ++ "/ocr.swift")); // one backend, not both
    } else {
        try std.testing.expect(!shimPresent(io, shim_dir));
    }
}

test "the Windows shim binds exactly the flag extractWin passes it" {
    // One contract written twice in two languages: the PowerShell parameter name inside OCR_PS1, and
    // the flag in extractWin's argv. Rename either alone and NOTHING errors — powershell refuses to
    // bind, exits non-zero, runArgv maps that to "" like any other failure, and every screenshot on
    // every Windows box silently extracts nothing, forever. There is no runtime signal to assert
    // against, so re-derive the agreement from the source, the way trio_routing_test.zig audits
    // engine.zig. The needles are BUILT here so this file never carries them as literals.
    const gpa = std.testing.allocator;
    const src = @embedFile("ocr.zig");

    // The parameter the shim declares: param([Parameter(Mandatory=$true)][string]$NAME)
    const decl = "[string]$";
    const at = std.mem.indexOf(u8, OCR_PS1, decl) orelse return error.ShimDeclaresNoStringParameter;
    var end = at + decl.len;
    while (end < OCR_PS1.len and (std.ascii.isAlphanumeric(OCR_PS1[end]) or OCR_PS1[end] == '_')) end += 1;
    const name = OCR_PS1[at + decl.len .. end];
    try std.testing.expect(name.len > 0);

    const flag = try std.fmt.allocPrint(gpa, "\"-{s}\"", .{name});
    defer gpa.free(flag);
    try std.testing.expect(std.mem.indexOf(u8, src, flag) != null);

    // ...and that parameter has to be the value that actually reaches WinRT, through GetFullPath:
    // GetFileFromPathAsync rejects the forward-slash relative paths pixelrag builds its tiles with,
    // so dropping the resolve turns every real extraction into a silent "".
    const resolved = try std.fmt.allocPrint(gpa, "GetFullPath(${s})", .{name});
    defer gpa.free(resolved);
    try std.testing.expect(std.mem.indexOf(u8, OCR_PS1, resolved) != null);
}

test "the answer is always freeable, and a dying shim's stderr cannot flood the log" {
    const gpa = std.testing.allocator;

    // Every failure path returns empty(gpa) and the caller frees unconditionally, so the OOM fallback
    // (`catch @constCast("")`, memory this allocator never handed out) has to be freeable too. It is,
    // because a zero-length free returns before it touches the pointer — which is the only reason that
    // fallback is not a crash waiting for a low-memory box.
    const e = empty(gpa);
    defer gpa.free(e);
    try std.testing.expectEqual(@as(usize, 0), e.len);
    const oom_fallback: []u8 = @constCast("");
    gpa.free(oom_fallback);

    // clip bounds what a dying shim can push into the log; it must never over-read, at any n.
    const long = "x" ** 500;
    try std.testing.expectEqual(@as(usize, 200), clip(long, 200).len);
    try std.testing.expect(std.mem.startsWith(u8, long, clip(long, 200)));
    try std.testing.expectEqualStrings("short", clip("short", 200)); // shorter than the bound: untouched
    try std.testing.expectEqualStrings("", clip("short", 0));
    try std.testing.expectEqualStrings("", clip("", 200)); // n past the end is not an over-read
}
