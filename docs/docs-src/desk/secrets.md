# secrets

**File:** `desk/src/secrets.zig`  
**Module:** `desk`  
**Description:** secrets.zig provides save/load of the veil-desk BYOK chat API key to the untracked .veil-desk data dir, sealing it with Windows DPAPI (current-user scope) and falling back to a plain user-private file on POSIX.

---

## Purpose Summary

Handles at-rest protection of the single chat API key (BYOK) for the veil-desk native desktop app. On Windows it seals the key with DPAPI (CryptProtectData, current-user scope) so the on-disk blob is useless on another account/machine; on POSIX it writes a plain file inside the already user-private data dir, mirroring how the server keeps its own .desktop_key. The key is never written to a repo-tracked file — it lives only under the untracked <data>/.veil-desk sidecar dir.

## Key Exports

- `save(io, gpa, dir, key) bool` — persists `key` under `dir`; on Windows seals via CryptProtectData to `chat_key.bin`, on POSIX writes plaintext to `chat_key`. An empty `key` deletes the stored secret (best-effort, ignoring delete errors) and returns true.
- `load(io, gpa, dir, out) usize` — reads the stored key into caller-provided `out`, returns bytes written (0 = none stored / unreadable / DPAPI unseal failed); on Windows unseals via CryptUnprotectData, on POSIX trims surrounding whitespace. Truncates to `out.len` via @min.

## Dependencies

- std (std.Io for file IO, std.mem.Allocator, std.fmt.allocPrint, std.mem.trim)
- builtin (compile-time builtin.os.tag == .windows branch selection)
- log.zig (trace/warn/err logging)
- Windows crypt32.dll: CryptProtectData / CryptUnprotectData (extern, .winapi callconv)
- Windows kernel32.dll: LocalFree (frees the DPAPI-allocated output blob)

## Usage Context

Called on the CHAT thread, which owns the io handle for all chat-side storage (per the module header). Invoked when the user sets or clears their BYOK chat API key (save) and to restore it (load). The `dir` argument is the .veil-desk sidecar directory. This is the desktop-side counterpart to the server's .desktop_key handling; the two share the same trust assumption that the data dir is user-private.

## Notable Implementation Details

Platform split is compile-time via `builtin.os.tag == .windows`, and the on-disk filename differs by platform (FILE_WIN "chat_key.bin" vs FILE_POSIX "chat_key") — a blob written on one OS is not read by the other. DPAPI is called through hand-declared extern structs/functions: DATA_BLOB is `extern struct { cbData: u32, pbData: ?[*]u8 }`, and both crypt calls pass CRYPTPROTECT_UI_FORBIDDEN (0x1) so they never pop a UI prompt (safe for a headless/background thread). On save, `in_blob.pbData` is a `@constCast` of the caller's key pointer (DPAPI won't mutate it); the sealed output blob is allocated by Windows and freed with LocalFree via `defer` — not the Zig allocator. Failure model is intentionally lossy and non-throwing: every function returns bool/usize (never an error union), a failed CryptUnprotectData returns 0 with a warn logged ("blob from another account?" — the expected outcome when the file is copied to a different Windows user), a failed CryptProtectData logs an err and returns false, and empty-key deletion swallows deleteFile errors. `load` reads with a hard `.limited(4 << 10)` = 4 KiB cap on readFileAlloc, and both load paths copy at most `out.len` bytes into the fixed caller buffer via `@min`, silently truncating an oversized key. POSIX load trims " \r\n\t" around the value; Windows load does not trim (the sealed plaintext is exact bytes). `path()` builds "<dir>/<name>" with allocPrint and returns null on OOM, which the callers treat as save=false / load=0. The bundled test exercises the full round-trip plus empty-key removal against a real temp dir using std.Io.Threaded.

---

*Documentation generated for nl-veil — desk/secrets.zig source analysis.*
