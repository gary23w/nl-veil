# builtin

**File:** `src/worker/builtin.zig`  
**Module:** `worker`  
**Description:** Shared state + contracts for the BUILT-IN model engine — the sentinel base, the per-boot bearer, the weights store, and the C-free `Engine` interface everything else plugs into.

---

## Purpose Summary

The server can serve `the-veil-12b` itself, in-process, from a GGUF weights file on disk — no separate local model runtime. This module is the C-free heart of that feature: the catalog's `builtin` provider carries the SENTINEL base (`builtin`), and deploy/chat resolution swaps it here for the live loopback engine endpoint plus a per-boot bearer (the same server-side trick as the `cloudflare` sentinel). The weights store ({data}/models, `NL_MODELS_DIR` override) is scanned deterministically — a model-id-named gguf beats other ggufs, lexical order breaks ties — and a cloud-synced store path raises a warning surfaced in status, because multi-GB weights inside OneDrive/Dropbox churn forever.

## Key Exports

- `SENTINEL` / `PATH_PREFIX` / `MODEL_ID` / `HF_REPO` — the feature's fixed points
- `Engine` / `GenReq` / `GenRes` / `Info` — the engine interface (llamaeng implements it with the embedded inference library; tests implement it with a mock, which is why it lives here, C-free)
- `init` / `rescan` — boot + store re-election
- `isSentinelBase` / `resolve` — the resolution primitives the choke points call
- `setPort` / `port` / `secret` / `modelsDir` / `modelPath` / `syncedDirWarning`

## Dependencies

- `std` only — deliberately importable from every resolution site without dragging C or httpz.

## Usage Context

main.zig boots it right after the data root exists; deploy/service.zig and chat/service.zig resolve through it; builtin_endpoint.zig reports its port in; modelpull.zig fills the store it describes.
