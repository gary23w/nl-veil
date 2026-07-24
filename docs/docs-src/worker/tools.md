# tools

**File:** `src/worker/tools.zig`  
**Module:** `worker`  
**Description:** The mind's toolbelt — the keyless, single-purpose tools a mind calls during a moment to build, research, and remember; the model receives a schema array and `execute()` runs each parsed tool_call into a text result.

---

## Purpose Summary

This is the tool layer between the model and the world. Schema constants (comma-joined OpenAI function defs) are handed to `llm.complete` as the `tools` array; when the model emits a tool_call, `execute()` dispatches it by name and always returns a gpa-owned string — even on error — so the result can feed back into the conversation. The built-in surface spans files (`read_file`/`write_file`/`edit_file`/`list_dir`/`delete_file`), code (`run_python`, `run_tests`), web (`web_search`, `web_fetch`, `read_url`, `fetch_json`, `deep_crawl`, `osint_scan`), memory (`observe`/`recall`/`share`/`recall_hive`/`absorb`/`read_doc`/`note_stance`), swarm coordination (`send_message`, `add_task`, `complete_task`, `journal`), self-improvement (`set_directive`, `save_skill`, `make_tool`, `propose_change`, `simulate_change`, `propose_plan_change`, `patch_system`), host operation (`host_status`/`host_command`/`host_explore`), watching (`poll`), spatial perception (`probe`), and delivery staging (`stage_delivery`). Keyless by design: API keys are never available to tool code, and publishing goes through an operator-approved `stage_delivery` manifest instead of credentials.

## Key Exports

- `execute(ctx, name, args_json)` — run one tool; result is always a string fed back to the model
- `ToolCtx` — the per-moment context: allocator, io, run_dir/workdir, memory scopes, mind name, round, `Mem`, counters, file-ownership lists, egress allowlist, optional `MemSink`, caps, grants
- `SCHEMA` / `FULL_SCHEMA` (= SCHEMA + `ASK_VEIL_TOOL`) — the shared mind tool defs; `CHAT_SCHEMA` (chat veil subset), `SCOUT_SCHEMA` (research-only, build tools structurally absent), `ASSEMBLER_SCHEMA` (lean set for small models), `OPERATE_SCHEMA` (host operation)
- `BROWSER_SCHEMA` / `PIXEL_SCHEMA` / `MCP_SCHEMA` — injected at runtime only under `NL_BROWSER_DRIVER` / `NL_MCP`, never in the static blocks
- `Caps` (`.full` / `.sandboxed`), `sandboxAllowed(name)`, `sandboxSchema(block)` — the sandbox allowlist gate and its comptime per-tool schema projection
- `MemSink` / `PendWrite` / `PendKind` — buffers a weak model's memory writes for moment-end junk-filtering instead of writing neuron-db immediately
- `fetchCached(...)` — the shared 7-day fetch cache + curl core (also serves the local rag mirror), shared by engine prefetch and mind fetches
- Scope constants — `SKILL_SCOPE`, `PLAYBOOK_SCOPE`, `LESSON_SCOPE`, `KNOWLEDGE_SCOPE`, `TOOL_SCOPE`, `MAP_SCOPE`, `PLAN_SCOPE`, … (the neuron-db scope names for each memory kind)
- Guards and helpers — `isBuiltinTool`, `egressAllowed`, `safeRel`, `reservedBusName`, `fileOwnedBy`, `convLocalFact`, `hasSecretToken`/`maskSecretTokens`/`credentialLookup`, `searchWeb`, `crawlSearchPrim`, `looksBlocked`

## Dependencies

- `worker/oscillation` — `Mem`, the neuron-db handle tools write/read through
- `worker/bufedit` + `worker/hashline` — the edit_file core (anchored ops, tag anchors)
- `worker/vcs` — merge law for concurrent file commits
- `worker/commons` — the send_message/add_task/complete_task handlers append to the swarm bus/board
- `worker/llm` + `worker/rerank` — model calls for helper passes, and the second-stage reranker recall_hive can route its first-stage hits through (ToolCtx carries the gateway creds)
- `worker/crawl` — HTML→markdown for web_fetch/web_search
- `worker/ragingest`, `worker/ragmirror`, `worker/pixelrag`, `worker/recipes`, `worker/deps`, `browser/*`, `mcp/discovery`, `chat/paths`

## Usage Context

The worker engine (`run.zig`) and the chat engine dispatch every parsed model tool_call through `execute()`; the schema constants are what those engines paste into the model's `tools` array (the chat engine concatenates its orchestration verbs separately). `fetchCached` is also called directly by the engine's nl-rag pack prefetch so prefetched pages and mind fetches share one cache.

## Notable Implementation Details

- The sandbox gate is an **allowlist**, deliberately: `execute()`'s tail falls through to running authored tools for any unrecognised name, so a denylist could be bypassed by authoring a tool under a new name. Tests pin that the gate fires inside `execute` before any tool runs and that a grant can never smuggle a built-in name past it.
- `make_tool` records authored tools in `TOOL_SCOPE` as `name \x1f params_json \x1f base64(python_body)` (max 16 tools, 8 KB bodies); bodies run sandboxed pure-stdlib Python with no API keys, and the `browser()`/`mcp()` helper preambles are injected only when the corresponding feature env is set.
- `fetchCached`: 7-day TTL cache keyed by url hash, bypassed entirely under an active egress allowlist (and redirects are forbidden there, since the gate only sees the seed URL); a local rag-mirror hit is served from disk with no network.
- SSRF/egress guards fail closed: private IPv4, metadata endpoints, numeric loopback spellings, and IPv6 literals are blocked (tested); `egressAllowed` is a host-suffix allowlist.
- Child processes get a `KillGuard` watchdog that terminates them at the deadline.
- A test reads the dispatcher's own source to assert `isBuiltinTool` claims every name `execute()` can dispatch, so the two can't drift.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
