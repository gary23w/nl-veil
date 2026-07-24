# sync

**File:** `src/worker/chat/sync.zig`  
**Module:** `worker/chat`  
**Description:** The conversation-workdir sync protocol's shared pieces, used by the server engine and every client — one implementation, no per-client twins.

---

## Purpose Summary

Rsync-lite over the existing delegation channel instead of a real file server (SMB/WebDAV would mean a new port, its own auth surface, OS mounts, and idle chatter). A sync happens only at the two moments state actually crosses the machine boundary — a cast needs the client's files (client→server), a finished hive's files need to reach the client (server→client) — and each moment costs one manifest round-trip plus only the files whose content hash differs. A same-disk install (desk + server sharing the data dir) is detected by a probe token in the manifest exchange and short-circuits to zero transfers. No daemon, no watcher, no polling: idle cost is exactly zero on both sides.

## Key Exports

- Caps: `FILE_CAP` (512 KiB per file — an oversized file is skipped, not clipped), `TOTAL_CAP` (4 MiB per batch), `MAX_FILES` (64), `MAX_DEPTH` (4), `PROBE_NAME` (`.sync_probe`).
- Wire shapes: `Entry` (`{p,s,h}` — path, size, FNV-1a-64 hex hash), `ManifestResp`, `PulledFile` (`{p,c}`), `PullResp`.
- `hashHex(bytes, out)` — FNV-1a 64 as 16 lowercase hex chars; non-crypto on purpose (drift detection between two copies of the user's own files, not an adversary — and it hashes at memory speed).
- `safeSyncPath(p)` — the shared checker every side applies: workdir-relative, forward slashes only, no `.`/`..` segments, no drive letters or ADS colons.
- `safeRoot(p)` — a rooted sync source (the sync_dir projection) must be an absolute client path with no traversal; the client only ever reads it.
- `isTextContent(data)` — text-only v1: a control byte beyond \n\r\t in the first KB marks a binary, skipped everywhere so both sides agree on the syncable set.
- `manifestResponse(gpa, io, workdir)` — the full sync_request answer `{"probe":...,"files":[...]}`; never errors (a missing workdir yields an empty manifest — a fresh client is valid).
- `readResponse(gpa, io, workdir, frame_json)` — answer a file_pull: read each sanitized, text-only, capped path into `{"files":[{p,c},...]}`; unknown/unsafe/oversized paths are silently skipped.

## Dependencies

- `../llm.zig` — `jstr` JSON-string escaping while building responses.

## Usage Context

The server engine (chat/engine.zig) drives the server side; the CLI calls these in-process (cli.zig); the desk spawns `veil sync-manifest` / `veil sync-read` (cli/exec_tool.zig), which call the same functions. Frames ride the existing events/tool_result channel: `sync_request` → manifest, `file_pull` → contents, `file_sync` → one pushed file.

## Notable Implementation Details

- Same-disk short-circuit: the server writes a random token to `.sync_probe` in *its* copy of the workdir right before a sync_request; a client that can see it echoes the content, proving both sides read the same directory. A present probe means the server never consults the file list, so `manifestResponse` skips the whole walk (reading + hashing every file) and returns an empty list. A rare stale probe merely degrades to re-pushing identical bytes — no data loss.
- The probe is an explicit read — dot files stay out of the manifest walk entirely.
- Both `manifestResponse` and `readResponse` enforce the shared budget (`TOTAL_CAP`) and entry ceiling while streaming JSON, so no batch can grow unbounded.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
