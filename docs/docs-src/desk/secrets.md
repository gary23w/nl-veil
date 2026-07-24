# secrets

**File:** `desk/src/secrets.zig`  
**Module:** `desk`  
**Description:** At-rest storage for the chat API keys and the GitHub PAT — plaintext files inside the user-private, git-untracked data dir, with a one-time auto-unseal migration for legacy DPAPI blobs.

---

## Purpose Summary

veil-desk is a LOCAL, single-user, login-gated app, so its secrets are deliberately kept as PLAINTEXT inside the untracked `<data>/` sidecar dir: the trust boundary is the OS login, not per-secret encryption. Plaintext-local is a feature — it lets the veil READ its own GitHub token (to curl or set a remote URL) instead of it being locked in an opaque blob it can't use. Each cloud/BYOK provider keeps its OWN key file keyed by catalog slug, so saving a DeepSeek key never overwrites the OpenAI one. Older builds DPAPI-sealed these files; loading transparently unseals such a legacy blob ONCE and rewrites it as plaintext.

## Key Exports

- `save(io, gpa, dir, key)` / `load(io, gpa, dir, out)` — the legacy single shared chat-key file (`chat_key` / `chat_key.bin`); an empty key deletes the file, load returns the byte length (0 = none/unreadable)
- `saveFor(io, gpa, dir, slug, key)` / `loadFor(io, gpa, dir, slug, out)` — PER-PROVIDER keys at `<dir>/chat_key_<slug>[.bin]`; `slug` is the provider's stable catalog id ("deepseek", "workers-ai", "custom"), filesystem-safe by construction
- `migrateLegacy(io, gpa, dir, slug, out)` — one-time upgrade: move the old single global key to the provider it was actually used for, delete the legacy file, and leave every OTHER provider correctly empty
- `savePat(io, gpa, dir, pat)` / `loadPat(io, gpa, dir, out)` — the GitHub PAT (`github_pat[.bin]`), stored plaintext-local exactly like the chat keys

## Dependencies

- `std` (`std.Io` file I/O) and `builtin` (per-OS filename selection)
- `log.zig` — trace/info/err logging
- Windows `crypt32.CryptUnprotectData` + `kernel32.LocalFree` — UNSEAL ONLY, for the legacy migration; the module never seals anything

## Usage Context

Runs on the CHAT thread, which owns the io handle for all chat-side storage. `chat.zig` calls `saveFor`/`loadFor` around BYOK key entry (falling back to `migrateLegacy` on the first load of the base slot) and `savePat`/`loadPat` for the GitHub PAT; `store.zig` keeps key bytes in memory only and never writes them to settings.json. Nothing here ever reaches a repo-tracked file.

## Notable Implementation Details

- Storage is plaintext on ALL OSes now. The only cryptography left is the auto-unseal migration in the load path: on Windows a file's bytes are first offered to `CryptUnprotectData` — a legacy sealed blob unseals and is rewritten as plaintext (best-effort) so future loads read it directly; a plaintext file fails the unseal (DPAPI blobs are structured) and falls through unchanged.
- The Windows filenames keep their historical `.bin` suffix precisely so old sealed files still resolve and get migrated.
- Failure model is non-throwing: bool/usize returns, empty-key deletion swallows errors, loads cap reads at 4 KiB and truncate into the caller's fixed buffer; loaded values are whitespace-trimmed.
- Tests pin the plaintext round-trip + empty-key removal, per-provider isolation (a provider never given a key reads empty), and that `migrateLegacy` moves the shared key to the CURRENT provider only and consumes the legacy file.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
