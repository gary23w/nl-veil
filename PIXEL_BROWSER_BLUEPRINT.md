# Pixel RAG + RSI Browser Control — Design Blueprint

Status: **IMPLEMENTED + VERIFIED (2026-07-16). Both features build and pass end-to-end smokes.**

## Implementation summary (what shipped)

New module `src/worker/browser/`:
- `launch.zig` — discover Edge/Chrome (NL_BROWSER_BIN → known paths → App Paths registry), spawn headless
  with an OS-assigned port, read `DevToolsActivePort`.
- `cdp.zig` — a self-contained minimal RFC-6455 WebSocket client over `std.Io.net` + a synchronous CDP
  request/response layer. **The vendored websocket.zig client was NOT usable** — it is a blocking raw-socket
  impl whose read path uses `std.posix.poll`, absent from this Zig's Windows ws2_32, so it does not compile
  here; hand-rolling stayed on the app's `std.Io` model like `httpc.zig`.
- `session.zig` — one browser session (process + CDP + attached page): navigate / evaluate / snapshot(refs) /
  clickRef / typeRef / screenshot / **tiling primitives** (pageMetrics, screenshotClipBase64, bandText). Closes
  via `Browser.close` (reliable — headless Edge daemonizes). `veil browser-smoke <url>` exercises it.
- `manager.zig` — process-global session registry keyed by run_dir (per-user/per-run isolation), mutex-
  serialized, LRU-capped, `closeAll` teardown; `renderTiles` for Pixel RAG.
- `broker.zig` — loopback HTTP broker (token-gated, 127.0.0.1 only) so a sandboxed make_tool Python body drives
  the primitives via a `browser()` helper — the RSI bridge.

Feature 2 (browser control): `browser_navigate/read/click/type/eval/close` built-in tools in `tools.zig`
(`BROWSER_SCHEMA`, `browserDispatch`, `isBuiltinTool`), gated by `NL_BROWSER_DRIVER` + offline flag +
`NL_BROWSER_ALLOWLIST` (reuses the existing `egressAllowed` matcher), admin-only on the chat surface
(`chat/tools.zig ADMIN_TOOLS`), injected into the mind/chat schema only when enabled. `runAuthored` injects the
`browser()` helper + broker env when enabled — **make_tool itself unchanged**.

Feature 1 (Pixel RAG Phase A): `pixelrag.zig` + `pixel_ingest`/`pixel_search` tools. Render→tile→index: tiles
are PNGs under `{run_dir}/.pixelrag/{doc}/`, tile band-text is stored in neuron-db AND a per-run manifest
(`index.jsonl`) that pixel_search reads + lexically scores (neuron's `export` reflows long facts across lines,
so it is unreliable as the Phase-A index — the manifest is the source of truth). Returns tile image path +
excerpt + score.

**Verified:** `browser-smoke` (launch→navigate→snapshot→PNG), `browser-flow-smoke` (navigate→read→close with
session persistence; gate on/off; allowlist block), `browser-invent-smoke` (make_tool registers a browser tool →
invoking it drives the browser via the broker), `pixel-smoke` (ingest example.com → 2 tiles → search returns the
matching tile). One gotcha fixed: the browser profile + live `DevToolsActivePort` must live on local `TEMP`, not
under OneDrive (OneDrive sync locks/delays them → intermittent PortTimeout).

**Follow-ups (not in this build):** wire tool invention/execution into the hash-chained `obs/audit_log.zig`
(currently the trail is `std.log(.browser)` + the worker's events.jsonl `w.act` rows — the AuditLog pointer does
not reach `execute()`); Pixel RAG **Phase B** (feed tile images to a vision model — needs the image-message
plumbing in `llm.zig`/`engine.zig` + a vision model); the `NL_PIXELRAG_EMBED_URL` embedding index; server-side
session teardown on shutdown (worker teardown is wired via `closeAll`; the server process leaks on hard kill).

---

### Locked decisions (from the design gate)

### Locked decisions (from the design gate)
1. **F1 retrieval:** vision-as-text into neuron-db is the default; the multimodal-embedding
   endpoint ships as an opt-in swappable stage behind `NL_PIXELRAG_EMBED_URL`.
2. **Vision model:** **deferred.** Feature 1 ships **Phase A (text-only)** first — captions/OCR via
   existing text models, `pixel_search` returns text + image paths. Phase B (real image-to-model
   plumbing + a vision model) comes after and is out of scope for this build.
3. **F2 invention:** **loopback broker bridge.** `make_tool` stays unchanged; invented Python
   bodies reach browser primitives via a `127.0.0.1` endpoint (host_command-style broker).
4. **Build order:** shared `browser/` layer (smoke-tested) → Feature 2 primitives + bridge →
   Feature 1 Phase A.

Two features that both plug into nl-veil's existing RSI/cast architecture. They share one
piece of new infrastructure (a CDP browser session), which is the headline design decision:
**build one browser layer, not two.**

---

## 0. What already exists (grounding, verified this session)

- **RSI invents tools** via `make_tool` (`src/worker/tools.zig:407` schema, `:810-852` handler).
  An invented tool is a **pure-stdlib Python body** that reads a global `ARGS` dict and prints
  one JSON line. Registered as a data record `name \x1f params \x1f base64(body)` into the hive
  `tools` scope (`neuron-db`), schema synthesized per-mind at `src/worker/run.zig:8771`, dispatched
  via fall-through in `execute()` after built-ins (`tools.zig:909`, `:936`). Sandboxed by `PYRUN`
  with a 25s cap, API keys blanked, `webbrowser`/`os.startfile` neutered (`tools.zig:936-968`).
  **A make_tool body cannot call registry tools in-process — it can only shell out / hit loopback.**
- **Built-in primitives** (what minds compose today): `web_fetch`, `read_url`, `fetch_json`,
  `deep_crawl`, `run_python`, file ops, memory ops (`observe`/`recall`/`recall_hive`),
  `host_command` (sim), `patch_system`. All engine-provided branches in `tools.zig:execute()`.
- **Casts** are `(mode, style)` strings, not an enum — dispatched in `run.zig:918-945`, defaults set
  in `deploy/service.zig:castSwarm()`. Adding a "type" = new branch there + a synthesis path.
- **Retrieval is lexical-first** with a **256-d random-indexing** semantic fallback inside neuron-db
  (Rust `semantic.rs`), plus an **LLM listwise reranker** (`src/worker/rerank.zig`). **No external
  embedding model, no FAISS, no dense neural embeddings anywhere in nl-veil.**
- **Zero image plumbing.** Tool results and message `content` are plain JSON *strings* everywhere
  (`engine.zig:2374`, `llm.zig`). No provider carries image parts. No server-side PNG decoder
  (raylib is desk-only). Neither desk nor web renders model-facing images.
- **Reusable pillars:** vendored `httpz.websocket.Client` (CDP over ws, no build change),
  `supervisor.zig` spawn/track/kill pattern, `createDirPathStatus` + `data/u{uid}/…` layout,
  `NL_`-env runtime gating, `httpc.zig` (loopback plain-HTTP, raw sockets).
- **Machine:** Edge 150 present at `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`
  with an App Paths registry entry — discoverable, **no install needed**.

---

## 1. Shared infrastructure — ONE browser session layer

**Both features need a headless Chromium/Edge driven over the Chrome DevTools Protocol (CDP).**
Build it once:

```
src/worker/browser/
  launch.zig    // discover Edge/Chrome (App Paths registry → known paths), spawn headless,
                //   track Child + write browser.pid, kill via child.kill()/taskkill /T,
                //   reconcile — copied shape from control/supervisor.zig
  cdp.zig       // CDP JSON-RPC framing over httpz.websocket.Client; read ws endpoint from
                //   {user-data-dir}/DevToolsActivePort; correlate id→response; event pump
  session.zig   // high-level surface both features call:
                //   navigate(url), captureScreenshot(clip?) -> base64 PNG,
                //   evaluate(js) -> json, snapshotAXTree() -> aria/DOM tree,
                //   dispatchMouse/Key(...), setDeviceMetrics(w,h,dpr)
```

- **Launch flags:** `--headless=new --remote-debugging-port=0 --user-data-dir={run}/…/cdp
  --no-first-run --no-default-browser-check`. Port 0 = OS-assigned; read the real ws URL from the
  `DevToolsActivePort` file the browser writes (avoids a fixed-port collision).
- **Discovery order:** `HKLM\...\App Paths\msedge.exe` → `%ProgramFiles(x86)%\...\msedge.exe`
  → `chrome.exe` fallbacks → `NL_BROWSER_BIN` override. Never bundle a browser.
- **Lifecycle:** one long-lived session per feature-run, jailed to `data/u{uid}/_browser/…`,
  killed on run teardown exactly like a swarm worker (`supervisor.zig:330` `child.kill`,
  `killByPidFile` fallback, `taskkill /F /T` for the tree at `run.zig:6005`).

**This is the "don't build two" flag.** Feature 1's `render` stage = `session.captureScreenshot`
over a tiling loop. Feature 2's primitives = `session.navigate/evaluate/dispatch*`. Same session.zig.

---

## 2. Feature 1 — Pixel RAG (screenshot → data retrieval)

Same four stages as StarTrail-org/PixelRAG (render → embed/ingest → index → serve), each
independently callable, **but each stage mapped onto an nl-veil primitive instead of the Python/FAISS
stack.** The one place we deliberately diverge from PixelRAG is the "embed" stage — see the fork.

### 2a. render  (→ image tiles)
`session.navigate(url)` then tile the page: set viewport height, scroll by page-height steps,
`captureScreenshot` per step (or `clip` regions), overlap ~15% so nothing straddles a seam.
Persist tiles as `data/u{uid}/_pixelrag/{docId}/tile_{n}.png` — **base64 PNG stored as-is, never
decoded server-side** (avoids the missing-codec gap; the vision model consumes base64 directly).
PDFs: phase 2 — load `file:///…pdf` in the same headless viewer and tile-capture per page.

### 2b. ingest  (tile → recallable text)  ← the fork
nl-veil has no VL embedding model and no FAISS, and a local Qwen3-VL-Embedding-2B would violate
"no new manual install." **Recommended (default): vision-as-text.** Each tile is passed through a
vision-capable chat model (the same seam we add in §2f) that returns (a) a dense caption and
(b) verbatim OCR text. That text is what we retrieve over — playing to neuron-db's proven
lexical/random-index strength instead of bolting on a vector DB.

- **Alternative (heavier, opt-in):** a real multimodal-embedding endpoint (Voyage
  `voyage-multimodal-3`, Cohere embed-v3-image, or CF Workers AI) behind `NL_PIXELRAG_EMBED_URL`,
  writing vectors to a small local index. Keeps the stage independently swappable exactly like
  PixelRAG, but adds a provider dependency. **Not recommended for v1.**

### 2c. index  (build the recall structure)
Default path needs no new index: `observe(KNOWLEDGE_SCOPE-derived pixel scope, caption+ocr)` per
tile, tagged with `{docId, tileN, png path}`, via the existing `Mem.observe` → `neuron observe`
path (`oscillation.zig:331`). Retrieval structure = neuron-db itself. (Embedding alternative writes
its vectors here instead.)

### 2d. serve  (query → tiles)
New built-in tool **`pixel_search(query, k)`**: `Mem.recall`/`assoc` over the pixel scope →
optional `rerank.zig` listwise pass → return top-k `{caption, png path, score}`. Plus
**`pixel_ingest(url|path)`** to run render+ingest+index. Both are engine-provided branches in
`tools.zig:execute()` (mirrors `web_fetch`), added to `isBuiltinTool` + the schema constants.
Because they're built-ins, **RSI minds and the chat can already compose them today** — no
make_tool change required for Feature 1.

- Optional: a cast `style="visual"` that fans ingestion across many URLs (a scout-archetype swarm),
  added at `run.zig:918` + `castSwarm` defaults. Nice-to-have, not v1-critical.

### 2f. read-back  (tiles → model context)  ← the real new plumbing
Two phases so Feature 1 delivers value before the multimodal work lands:

- **Phase A (works today):** `pixel_search` returns caption + OCR text + png path in the result
  string. The model reasons over text; desk can render the png from the path.
- **Phase B (true pixel RAG):** attach the actual tile PNG to the model turn. Three seams the
  exploration pinned: the tool-result row (`engine.zig:~2374`), the message-body builder
  (`llm.zig` — emit an OpenAI `content:[{type:image_url,{url:"data:image/png;base64,…"}}]` array,
  or Ollama native `images:[base64]`; the provider split already exists at `llm.zig:247`), and a
  **vision-capable model** (none is wired today — see dependencies fork §4).

---

## 3. Feature 2 — RSI-driven browser control

**Goal:** RSI invents & registers browser-driven tools the *same way* it invents any tool today,
and those tools call into the new browser driver. Scoped to **browser-reachable web apps only** —
not a native-app controller.

### 3a. Primitives = new built-in tools (the "new infrastructure")
Add engine-provided branches in `tools.zig`, backed by `browser/session.zig`:

| tool | CDP under the hood |
|---|---|
| `browser_open(url)` / `browser_close` | session launch/navigate/teardown |
| `browser_navigate(url)` | `Page.navigate` |
| `browser_read()` | `Accessibility.getFullAXTree` / DOM snapshot → aria-tree text w/ ref ids |
| `browser_click(ref)` / `browser_type(ref, text)` | `Input.dispatch*` or `Runtime.evaluate` |
| `browser_eval(js)` | `Runtime.evaluate` (read-only inspection) |

Minds can drive the browser immediately by calling these in a moment — exactly like `web_fetch`.

### 3b. How RSI *invents* a reusable browser tool  ← the fork
A `make_tool` body is sandboxed pure-Python and **can't call registry tools in-process**. Two ways
to let an invented higher-level tool (e.g. `export_dashboard_csv`) compose the primitives:

- **Recommended: loopback broker bridge.** Expose the browser-primitive surface on a loopback
  HTTP endpoint (the engine already speaks loopback plain-HTTP via `httpc.zig`). An invented Python
  body reaches it with `urllib` to `127.0.0.1`. **`make_tool` itself is unchanged** — this mirrors
  the existing `host_command` broker pattern, so invention/registration/audit stay identical to
  every other tool. The broker enforces the gate (§3c).
- **Alternative: new tool-kind in `make_tool`.** Allow a "composition/recipe" kind that references
  browser built-ins directly, touching the three known sites (registrar `tools.zig:810`,
  synth `run.zig:8771`, runner `tools.zig:936`). More faithful to "compose primitives," but it
  forks the invention path — heavier, and it's the parallel-system the brief warns against.

### 3c. Gating & audit (browser acts on the live web = high-risk)
Model it on `host_command`/`patch_system`, not on the ungated compute tools:
- Classify browser tools **ADMIN-only** (`chat/tools.zig:66` `ADMIN_TOOLS`) → admin/localhost surface
  only; hosted non-admin tenants can't reach them.
- **Feature off by default**, `NL_BROWSER_DRIVER=1` to enable (runtime gating per house convention).
- Navigation allowlist `NL_BROWSER_ALLOWLIST` mirroring `NL_EGRESS_ALLOWLIST` (`tools.zig:2593`).
- **Wire tool invention + each browser action into `src/obs/audit_log.zig`** (the hash-chained log,
  currently unused for tools) in addition to the existing `w.act` event rows — closes a real gap.
- **Hard boundary:** the driver must **never enter credentials/payment data and never click
  irreversible controls (submit/pay/delete) without explicit human approval.** These map to the
  session's prohibited/permission-required actions; the broker rejects them by default.

---

## 4. Module boundaries & new dependencies

**Fits existing boundaries** (no build.zig change for new `.zig` files — single-module `@import`):
- `src/worker/browser/{launch,cdp,session}.zig` — NEW shared layer (both features).
- `src/worker/pixelrag/{render,ingest,index,search}.zig` — NEW (Feature 1).
- `tools.zig` — new built-in branches (`pixel_*`, `browser_*`) + `isBuiltinTool` + schema consts.
- `chat/tools.zig` — add browser/`pixel_ingest` to `ADMIN_TOOLS`.
- `llm.zig` + `engine.zig` — image-content plumbing (Feature 1 Phase B only).
- Storage: `data/u{uid}/_pixelrag/…`, `data/u{uid}/_browser/…` via `createDirPathStatus`.

**New external dependencies:**
- **Crates/libs:** none. Reuse vendored `httpz.websocket.Client` (verified re-exported at
  `httpz.zig:5`, reachable via the existing `addImport("httpz",…)` — confirm resolves at impl time),
  neuron-db retrieval, `rerank.zig`, `httpc.zig`.
- **Binaries:** none bundled — headless Edge/Chrome already on the machine, discovered at runtime.
- **No FAISS, no PNG codec** (base64 passed through), no local VL embedding model in the default path.
- **The one genuine "needs a model":** Feature 1 read-back (§2f Phase B) and ingest captioning need a
  **vision-capable LLM**. None is wired. Choice is config, not a bundled install: BYOK OpenAI vision,
  local Ollama VL (llava/qwen2-vl), or CF Workers AI — gated by config presence like every other
  provider. Feature 1 Phase A (text captions/OCR + png paths) ships without it.

---

## 5. Open decisions for the gate

1. **F1 retrieval:** vision-as-text into neuron-db (recommended) vs true multimodal embeddings endpoint.
2. **F1 vision model** (ingest caption + read-back): BYOK OpenAI vs local Ollama VL vs defer to Phase A text-only first.
3. **F2 invention path:** loopback broker bridge, `make_tool` unchanged (recommended) vs new `make_tool` composition kind.
4. **Build order:** shared `browser/` layer first, then which feature — or both in parallel.

## 6. Proposed build order (pending #4)
1. `browser/{launch,cdp,session}.zig` + a smoke test (launch Edge headless, navigate, screenshot).
2. Feature 2 primitives (`browser_*` built-ins) + gating/audit — proves the session layer end-to-end.
3. Feature 2 RSI bridge (loopback broker) — RSI invents a browser tool.
4. Feature 1 render+ingest+index+`pixel_*` tools, Phase A (text).
5. Feature 1 Phase B image plumbing (`llm.zig`/`engine.zig`) once a vision model is chosen.
