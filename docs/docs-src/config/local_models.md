# local_models

**File:** `src/config/local_models.zig`  
**Module:** `config`  
**Description:** What Ollama on THIS machine actually has pulled — the server asks Ollama's own `/api/tags` so pickers stop offering models that were never downloaded.

---

## Purpose Summary

The shipped catalog (models.yaml → models.json) lists local models that are *worth* running, not ones that *are* installed; a picker built from it alone offers a model the machine never pulled, and the failure only surfaces on the first turn as a pull stall or a 404 that reads like an app bug. So the client asks the server, and the server asks Ollama: `GET /api/tags` is Ollama's list of locally pulled models, relayed as `{ok, reachable, port, installed:[...]}`. Unreachable is a normal answer — no Ollama, or not running — and reports `reachable:false` with an empty list rather than an error, because a hosted-only user is not misconfigured.

## Key Exports

- `list` — the `GET /api/v1/models/local` handler (auth-gated via `requireUser`)

## Dependencies

- `httpz` + `../gateway/http.zig` — `App`, `requireUser`, the response arena
- `../worker/httpc.zig` — the loopback socket client that dials Ollama

## Usage Context

Registered on the server router in main.zig as `/api/v1/models/local`; clients use it to mark which catalog models are actually installed.

## Notable Implementation Details

- Loopback only, by construction: `httpc.request` dials `127.0.0.1:<port>`, so this endpoint cannot be pointed at a remote host and become an SSRF lever.
- `?port=` overrides Ollama's default 11434 for a non-standard install, bounded to a real port number; anything else falls back to the default rather than erroring.
- 3-second timeout: a live Ollama answers `/api/tags` in milliseconds, and a picker must not hang on a dead port.
- Something answering on the port that is not Ollama (unparseable reply) reports reachable with nothing installed — more honest than a parse error the user can do nothing about.

---

*Case file grounded in the module's `//!` header and public API.*
