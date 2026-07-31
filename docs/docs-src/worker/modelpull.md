# modelpull

**File:** `src/worker/modelpull.zig`  
**Module:** `worker`  
**Description:** Fills the built-in model's weights store: resolves the artifact live from the published repo, transfers with resume, verifies sha256 against the repo's own large-file record, and only then promotes into serving position. Also the no-download import door.

---

## Purpose Summary

The repo (`builtin.HF_REPO`) IS the manifest: the file list comes from its tree API and each artifact's sha256 from its large-file record, so whatever quant gets published verifies without a source change here. The election rule is pinned and pure: a `q4_k_m`-named gguf wins, else the largest, and a gguf with no large-file record is no candidate at all (nothing downloads unverified). Transfers land in a `.part`, hash-check, then rename — progress needs no side channel because the status read stats the `.part`. Transport mirrors llm.zig: loopback rides the in-process httpc client (which is how the end-to-end test runs against fakehttp), anything else is curl with `-C -` so resuming a 7GB file across restarts is curl's problem. `importLocal`/`startImport` copy an already-downloaded GGUF instead — auto-discovering the local runtime's content-addressed blob for this model and verifying it against the digest its own manifest declares.

## Key Exports

- `configure` / `status` / `startPull` / `cancel` — the pull lifecycle (`NL_MODEL_HOST` overrides the repo host for mirrors/tests)
- `startImport` / `importLocal` / `remove`
- `electFromTree` / `modelDigestFromManifest` / `sha256HexOfFile` — the pinned pure parts
- `on_store_change` — main wires it to re-point the engine after the store changes

## Dependencies

- `worker/httpc.zig` — loopback transport; `worker/builtin.zig` — the store; curl — TLS transfers

## Usage Context

Driven by the `/api/v1/models/builtin/*` routes (main.zig) and `veil model pull|import|cancel|rm`; the web Settings "Built-in model" panel renders its status.
