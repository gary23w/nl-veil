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
- `durableLine(raw)` — one line of the user's durable memory store (`memories.jsonl`), trimmed and freed of a UTF-8 byte-order mark. Every reader of that store goes through it: `credentialLookup` (get_credential), `durableRecall` (recall's durable half) and the chat engine's prompt, dedup and forget paths. Behind a mark, the oldest memory was invisible to all of them

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
- Child processes get a `KillGuard` watchdog that terminates them at the deadline (`spawnGuarded`, now in `bounded.zig`). The syntax gates (`pyCompileError`, `nodeCheckOnce`, `zigAstCheckError`) run through `bounded.run`, whose 15-20 s bound holds on Windows for a child that prints nothing; `std.process.run`'s `.timeout` did not.
- `run_python` and authored tools run through the `PYRUN` launcher, which re-execs the script under a hard wall-clock cap: `pyrunCapS` reads `NL_PYRUN_TIMEOUT_S` (default `PYRUN_CAP_DEFAULT_S` = 120 s, read off the measured runs in its doc comment: across 538 `run_python` calls under a 150 s cap none reached it, 95% of container test runs finished inside 10 s and the longest real test run took 88 s, so the default clears every real run seen and stays at half the ceiling; zero, empty or junk fall back to it; above `PYRUN_CAP_MAX_S` = 240 s, kept under the swarm hang watchdog's 300 s, it clamps). Both run_python schema defs state the cap. The launcher reads both pipes itself, in chunks on two threads (CPython's Windows `communicate()` hands back nothing when a timeout finds its pipes still held), so a cap hit returns exit 124 with the tails of what the script printed on every platform, plus a line that names the cap as run_python's own (a `timeout=` in the script cannot raise it), says whether the script was still running, and says that what it started was not killed. A process that inherited the script's pipes gets at most a 5 s grace past the cap, so it cannot hold the call open; if the script had exited and the pipes close inside that grace, nothing was cut off, and the script's own exit code and full output pass through with a one-line NOTE instead of a cap hit.
- `poll` kind `command` runs each probe through `runProbe`. On Windows a target with embedded double quotes rides in the `NL_POLL_PROBE` environment variable and runs as `cmd /S /C %NL_POLL_PROBE%`, so cmd parses it exactly as typed at a prompt: Zig's argv encoder writes embedded quotes as `\"`, which cmd does not read, and `docker exec <c> bash -lc "tail -n 5 log"` reached bash torn on every sample of a live SWE-bench run. cmd expands that carrier in one pass, so `expandPercentVars` first applies a prompt's own `%VAR%` expansion (measured rule for rule: an undefined name stays as typed; cmd's dynamic names and the `%VAR:~..%` edit forms are not modelled). A quote-free target keeps the direct `cmd /C` argv, and POSIX `sh -c` is unchanged. A probe may run for whatever is left of the call's `timeout_s`; it runs through `bounded.run`, so one still running then is killed with its whole tree (`taskkill /T` on Windows, the probe's own process group on POSIX, which also means a terminal's Ctrl-C no longer reaches it), and on Windows its pending pipe reads are cancelled too, because Zig 0.16's batch cancel otherwise waits for the pipe to close. The output is COPIED out of the read buffers, never `toOwnedSlice`d: on Windows a killed probe's overlapped reads are still aimed at them, and only the reader's deinit drains those before freeing. Every observation reads `exit N: <stdout head>` plus ` | stderr: <last 300 bytes>` when there is any, an identical repeat logs as `(same as t+Xs)`, and the observation that settles the verdict is logged even past the 6000-byte log bound. A probe that fails the same way, with something on stderr, on its first `PROBE_FAIL_FAST_N` (3) samples ends the call early with verdict `failing` and its error quoted. A silent non-zero exit (`test -f`, `grep -q`) never counts, since that is the documented "until exit 0" wait, and the `failing` result offers it as the way to wait on a not-ready state that prints an error (the rule cannot tell that from a broken probe). The chat engine's poll budget (`pollStreakAfter`) counts `failing` like `timeout`.
- `edit_file` rejects an op whose `anchor` (or `end`) is several lines of the tagged read view, before dialect dispatch and with the file untouched, naming the `anchor`..`end` range form with the block's real first and last tags (`hashline.spannedTagAnchor`). Left alone, a block pasted with the read view's arrows parsed as its first line and replaced only that line; a block of bare tags parsed as no tag at all and failed in the text matcher, so the rejection claims "would have acted on line N alone" only for the first shape.
- A test reads the dispatcher's own source to assert `isBuiltinTool` claims every name `execute()` can dispatch, so the two can't drift.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*

## Security tools in v1.1.12

The reserved `security_` family and `garrett_tools`/`garrett` wrappers dispatch through `worker/garrett.zig`. Opted-in contexts carry the user’s MCP URL and token plus the discovered typed catalogue. Security tools run in that authenticated cloud deployment, remain unavailable without its credential pair, and require an online run.

[Security deployment and use guide](../guide/security-tools.md).
