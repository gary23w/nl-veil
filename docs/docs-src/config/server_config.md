# server_config

**File:** `src/config/server_config.zig`  
**Module:** `config`  
**Description:** The handful of settings a server admin owns, changeable while running — today the default model trio every web user falls back to, plus the browser-family preference.

---

## Purpose Summary

This started as `NL_DEFAULT_MODEL` / `NL_DEFAULT_BASE_URL` read once at boot — right for provisioning a container, wrong for a person (exact model-id strings, a launch-script edit, and a restart to change a dropdown's worth of state). Now the env vars SEED the config the first time only; after that the admin sets it from the web UI and it persists to `{data}/server-config.json` — plain JSON on purpose, so an operator with no UI access can still read and edit it, and a backup makes its contents obvious. Three roles mirror the per-user trio (coding is the fallback for thinking/prompting, exactly as ModelTrio.pick resolves them), and an orthogonal browser-family preference feeds headless-browser discovery.

## Key Exports

- `ServerConfig` — the mutex-guarded config: `init`, `defaults` (allocating snapshot), `set` (coding role only), `setAll` (all three roles), `setBrowser`, `load`
- `ServerConfig.Defaults` — the snapshot struct; empty strings mean "no default set" (callers treat that as "the user must choose")
- `MODEL_MAX` / `BASE_MAX` / `BROWSER_MAX` — the fixed buffer sizes (160 / 256 / 16)

## Dependencies

- `../worker/browser/launch.zig` — every browser-preference change is published to `launch.setPreferredBrowser`, because `discover()` is reached with only an env map and keeps a process-global copy

## Usage Context

Constructed and `load`ed in main.zig; `gateway/http.zig` re-exports the type and holds the instance on `App`. Read on EVERY chat turn from httpz worker threads while an admin may be writing from another — which is the whole design constraint.

## Notable Implementation Details

- Concurrency: fixed-size buffers behind a mutex, copied in and out — no slice handed out that could dangle when the value changes underneath a request, and no allocation on the read path (`defaults` copies into the caller's allocator; `defaultsRaw` is the internal lock-and-slice form).
- `check` rejects rather than truncates (TooLong / BadInput on quotes and control bytes): a silently clipped model id would fail later as a confusing provider 404 instead of an error where it was typed.
- The env is a SEED, not an override: once the file exists, a stale `NL_DEFAULT_MODEL` in some launch script must not silently win on restart and undo the admin.
- The browser preference is orthogonal by contract — `setAll` never touches it, `setBrowser` never touches the models — and normalizes to `"" | "chrome" | "edge" | "chromium"`; junk degrades to `""` (the Edge-first default order) rather than persisting. It is a NAME preference, never a path (an arbitrary executable stays the `NL_BROWSER_BIN` operator escape).
- A failed save never fails the request; the value is already live in memory.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
