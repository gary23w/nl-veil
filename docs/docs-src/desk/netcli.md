# netcli

**File:** `desk/src/netcli.zig`  
**Module:** `desk`  
**Description:** In-process HTTP/1.1 client for the local veil server (127.0.0.1): unauthenticated fleet GET plus authenticated deploy/cast/chat-tool/delete calls, each raced against a hard timeout so a wedged server never hangs the UI.

---

## Purpose Summary

netcli.zig is the desk app's typed façade over the low-level httpc socket client for the handful of operations that genuinely require the running veil server. It centralizes per-endpoint timeouts, bearer-token passing, and — crucially — an idempotency-aware retry/triage policy that turns httpc's raw Result union into a simple `?Resp` the UI can act on. Everything the console/chat/stop features need is read from the filesystem (scan.zig); only fleet counters and swarm mutation go through here.

## Key Exports

- `Resp` — re-export of `httpc.Resp` (`status: u16`, `body: []u8`, gpa-owned; caller frees when `len>0`)
- `fleet(io, gpa, port) ?Resp` — unauthenticated GET /api/v1/fleet for dashboard counters; short 6s timeout (poller cadence)
- `deploy(io, gpa, port, token, body_json) ?Resp` — POST /api/v1/swarms, the full Deploy-button deploy; 15s; empty token → server 401
- `cast(io, gpa, port, token, body_json) ?Resp` — POST /api/v1/cast, the chat's bounded cast door; 15s
- `chatTool(io, gpa, port, token, body_json) ?Resp` — POST /api/v1/chat/tool, runs one shared mind/orchestration tool; generous 45s (a web_search tool can take ~30s)
- `delete(io, gpa, port, token, id) ?Resp` — DELETE /api/v1/swarms/<id> to stop+remove a swarm; 15s; path built in a fixed [160]u8 stack buffer

## Dependencies

- httpc.zig (httpc.request, Resp, and the Result union that drives triage; httpc is the actual socket/HTTP-framing/timeout engine)
- log.zig (trace/dbg/warn/err structured logging)
- std / std.Io (Io.sleep for backoff, allocator, string ops)

## Usage Context

Called from the veil-desk UI/poller layer. `fleet` fires on every poller refresh to populate dashboard counters; `deploy` backs the Deploy button; `cast` is the chat turn's cast door (bounded so a slow server can't freeze the turn); `chatTool` executes a single shared tool exactly as a hive mind would; `delete` stops/removes a swarm. Callers pass an `Io` and allocator, receive `?Resp`, and treat `null` as "server unreachable" (or, on deploy/cast with no token, "connect a token in Settings"). Callers own and must free `resp.body` when non-empty.

## Notable Implementation Details

The load-bearing logic is the retry/triage in the private `httpReq`, keyed off idempotency (`idempotent = method != "POST"`). It loops up to `MAX_ATTEMPTS = 3` with linear backoff (120ms, 240ms via `io.sleep`) and maps httpc's Result: `.ok` returns the Resp; `.refused` and `.timed_out` fail fast to null (server down / wedged — retrying only multiplies the stall); `.failed` (reset/short/unparseable reply, read as a momentarily starved server pool) is the only retryable case, and even then ONLY for GET/DELETE. A POST is one-shot: an empty reply might mean the server already processed the side effect, so a retry could deploy a duplicate swarm — after a `.failed` POST, `httpReq` returns null immediately. Timeouts are hard ceilings enforced inside httpc (round trip raced against an Io sleeper via Io.Select), not here; netcli just picks the per-endpoint budget (6/15/15/45/15s). Design constraint driving the whole file: this is the third-generation client — raw-socket-read-to-EOF hung the chat ("casting hangs"), the curl-subprocess fix leaked the bearer token + JSON body onto an argv and tripped Defender's ML kill heuristics, so this in-process version keeps curl's hard-ceiling semantics while keeping secrets off any command line. `delete` formats its path into a 160-byte stack buffer and returns null on bufPrint overflow (an over-long id is silently dropped). The bottom test is best-effort: it reads `../data/.desktop_key`, hits :8787, and skips harmlessly if the key or server is absent — asserting only that calls return bounded (never hang).

---

*Case file grounded in the module's `//!` header and public API.*
