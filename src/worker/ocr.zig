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
