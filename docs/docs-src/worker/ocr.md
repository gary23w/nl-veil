# ocr

**File:** `src/worker/ocr.zig`  
**Module:** `worker`  
**Description:** OCR (vision-as-text) — extract the text of a raster image via the OS's BUILT-IN OCR engine: Windows.Media.Ocr through a WinRT PowerShell shim on Windows, the Vision framework (VNRecognizeTextRequest) through a Swift shim on macOS.

---

## Purpose Summary

A dropped or pasted screenshot has no DOM, so unlike a rendered browser tile its text can't come from the page. This module extracts it with the OS's own OCR engine — free, offline, and private: NO model ever sees the pixels (the Pixel-RAG promise), and on Win10/11 it is zero-install. It is deliberately the OS-NATIVE tier only; when it returns "" (Linux, or a box missing the engine/toolchain) the CALLER falls back to a vision-capable model so extraction still works on any machine.

## Key Exports

- `extractImageText(gpa, io, environ, run_dir, png_abs_path)` — the whole surface: extract the text of the PNG at an ABSOLUTE path using the OS OCR engine; returns owned text, "" on any failure or on an OS with no built-in OCR

## Dependencies

- `std` + `builtin` only — the Windows and macOS shims are embedded source strings in this file, run via `std.process.run` (`powershell -NoProfile -ExecutionPolicy Bypass -File …` / `swift <shim> <path>`).

## Usage Context

Called by `worker/pixelrag.zig`'s `ingestImage` — the browser-free attachment path. Per the header, the fallback chain is explicit: this module first, and when it yields "" the caller goes to `llm.visionExtract` (pixelrag's vision-model OCR stand-in).

## Notable Implementation Details

- Best-effort everywhere: a spawn failure or non-zero exit returns "" so an attachment can never wedge a chat turn; shim stdout is bounded (1 MB).
- Each shim is written once per run dir under `.pixelrag/` (idempotent) and re-used; `environ` is unused (the shim inherits the process environment) but kept for signature symmetry with pixelrag ingest.
- The WinRT shim's `[System.IO.Path]::GetFullPath` is REQUIRED — WinRT's `GetFileFromPathAsync` rejects forward-slash / relative paths, and the tile paths are built with forward slashes. It emits recognized lines as UTF-8, one per line, and errors with exit 3 when no OCR language is installed.
- The macOS shim is compiled + run on demand by `swift` (needs the Xcode command-line tools — present on any dev Mac, installable with `xcode-select --install`, no App Store), uses `.accurate` recognition with language correction, and exits non-zero on any error so the caller falls back.

---

*Case file grounded in the module's `//!` header and public API.*
