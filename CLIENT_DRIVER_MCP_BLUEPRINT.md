# Client-Side Driver + OS MCP Discovery — Design Blueprint (round 2)

Status: **IMPLEMENTED + VERIFIED (2026-07-16).** Extends the server-side browser driver
(`PIXEL_BROWSER_BLUEPRINT.md`) to run on the CLIENT by default, controlled from the server, and adds OS-level
MCP / AI-app discovery for RSI.

## What shipped (round 2)
- **`src/worker/browser/host.zig`** — `veil local-host` daemon: owns the client's browser (+ pixel render)
  sessions behind the loopback broker, publishes `{port,token}` to `%TEMP%/nl-veil-localhost.json`, idle-exits
  after 5 min. Client helpers `ensure()` (read file / lazily spawn the daemon) + `forward()` (POST a command to
  it). **No desk changes** — `exec-tool` transparently routes to the daemon.
- **Client-by-default routing** on the existing `ctx.roam` flag (`tools.zig` `browserOp`): roam ⇒ daemon-
  forward (drives the USER's browser, one session across the desk's subprocess-per-call delegation); non-roam ⇒
  in-process manager (server/swarm/CLI-direct). `manager.dispatch` is the ONE action set all three paths funnel
  through. Pixel render also routes to the daemon via a `rendertiles` action; indexing stays client-side.
- **`src/worker/mcp/client.zig`** — minimal MCP JSON-RPC client over stdio (spawn → `initialize` →
  `notifications/initialized` → `tools/list` / `tools/call`), kill-watchdog bounded.
- **`src/worker/mcp/discovery.zig`** — scans Claude Desktop / Cursor / VS Code config files + probes local AI
  ports (Ollama :11434, LM Studio :1234, …); never returns env secrets. `mcp_discover` / `mcp_call` built-in
  tools (gated `NL_MCP`, admin-classified on chat), self-contained one-shot so they work client or server.
- **RSI bridge:** `runAuthored` injects a `browser()` and/or `mcp()`/`mcp_find()` Python helper (per the
  NL_BROWSER_DRIVER / NL_MCP gates) pointing at the same broker; the broker routes `mcp_*` actions to the
  discovery layer. make_tool unchanged — an invented tool can drive the browser AND installed MCP servers.
- **Prompt:** `browser_navigate`'s description now says it drives the user's OWN machine's browser and to reach
  for it when crawling can't get the data (emergent "start a local system + drive it").

## Verified end-to-end
- `browser_navigate` + `browser_read` as **two separate exec-tool processes** share ONE browser via the daemon.
- Client-side `pixel_ingest` renders on the daemon, indexes locally; `pixel_search` reads it back.
- MCP client protocol (mock server: tools/list + tools/call); config scan finds a configured server, connects,
  lists tools, and `mcp_call` invokes it; `make_tool` → invoke → `mcp()` → broker → MCP server round-trips.

## Deferred (follow-ups, not in this build)
- HTTP/SSE MCP transport (stdio covers OS-installed servers; `mcp_call` reports http servers as unsupported).
- Persistent daemon-hosted MCP connections (currently one-shot spawn per `mcp_call`).
- Hash-chained `obs/audit_log.zig` wiring (trail today = `std.log(.browser/.mcp)` + events.jsonl `w.act` rows).

## The directive (user, 2026-07-16)
> A server-side web driver is strenuous at scale ("a million people running a webdriver from the server won't
> work"). The driver should run CLIENT-side, controlled FROM the server: the user asks for info, the server
> judges it's hard to crawl, tells the client to start a local system, and drives it. Server-side driving stays
> only for **swarms** and **CLI runs**. Also: modern OSes ship MCPs / AI-ready apps — RSI should always be able
> to **find and use** those local AI-ready applications.

## What already exists (verified this session)
- **Delegation backbone.** A chat turn with `tool_client:true` (set by the desk + `veil chat`) makes the server
  brain DELEGATE every non-orchestration tool call to the client: it emits `{kind:"tool_request",id,tool,args}`
  to events.jsonl and BLOCKS, polling `tool_results.jsonl` by id (180s) — `engine.zig:2368-2369`,
  `delegateTool` `engine.zig:1822`. The client runs it through the ONE shared executor
  `exec_tool.runTool → tools.execute` with **`roam=true`** (`exec_tool.zig:18,47`) and POSTs `{id,result}` to
  `/tool_result`. **So `browser_*`/`pixel_*` ALREADY delegate to the client** — they're in the delegated bucket.
- **The crux to solve.** The desk runs each `tool_request` as a **fresh `veil exec-tool` subprocess**
  (`desk/src/chat.zig:1719-1760`) → my process-global browser session does NOT survive between `navigate` and
  `read`. The CLI path is **in-process** (`cli.zig:647`) so it persists there. Server/swarm keeps its
  long-lived in-process manager (already correct).
- **Execution-target signal already present:** `ctx.roam == true` ⇔ this tool is executing on the client.

## Round-2 design

### 1. Local-host daemon (solves the desk subprocess-per-call session gap)
A per-machine background process, `veil local-host`, that owns the stateful local resources a
subprocess-per-call client can't hold: **browser sessions** (the manager + CDP I already built) and (§4)
**MCP server connections**. It runs the existing loopback **broker** (`browser/broker.zig`) — extended with an
MCP surface — and writes `{port,token}` to a discovery file on LOCAL disk (`%TEMP%/nl-veil-localhost.json`, not
OneDrive — same lock lesson). Idle-exits after N minutes with no sessions.

**No desk changes needed.** When `veil exec-tool browser_*`/`pixel_*`/`mcp_*` runs with `roam=true`, its
dispatch **ensures the daemon is up** (reads the discovery file; spawns `veil local-host` detached + waits if
absent/dead) and **forwards** the command to the daemon's broker over loopback — instead of using the
in-process manager. Every `exec-tool` subprocess for a given conv thus shares ONE browser via the daemon. The
desk keeps shelling `exec-tool` exactly as today.

### 2. Execution-target routing (client-by-default)
The seam is `ctx.roam` in `tools.zig`:
- `roam == true` (client `exec-tool`): `browserDispatch`/`pixelDispatch`/`mcpDispatch` → **daemon-forward**.
- `roam == false` (server request, swarm worker, CLI-direct-server): **in-process manager** (as built).

So a desk/CLI chat drives the **user's** browser; a swarm or a server-side/CLI-direct run uses the server's.
This is the "client by default, server only for swarm/CLI" the directive asks for, keyed off the existing
roam flag — no new per-tool table, no protocol change (delegation already carries these tools to the client).

### 3. "Hard to crawl → start a local system → drive it" (emergent, not hardcoded)
Already falls out of §1–§2 + one system-prompt line: the model is told the browser tools drive the *user's own*
local browser (launched on demand) and to reach for them when `web_fetch`/`deep_crawl` can't get the data
(login-walled, JS-heavy, interactive). Model calls `browser_navigate` → server delegates → client's exec-tool
lazily starts the daemon+browser ("start a local system") → server drives turn-by-turn via delegated
`browser_read`/`click`/`type` ("I will drive it"). No use case is hardcoded (respects the no-hardcoded-use-case
rule); the behavior is the tool being client-delegated + a capability hint.

### 4. OS MCP / AI-app discovery + use (RSI finds and uses local AI-ready apps)
New client-side capability (runs under `roam`, since the configs/servers are on the user's machine):
- **`mcp/discovery.zig`** — enumerate locally available MCP servers + AI runtimes by scanning the known
  registration points: Claude Desktop `%APPDATA%/Claude/claude_desktop_config.json` (+ MSIX
  `%LOCALAPPDATA%/Packages/…/Claude/`), Cursor `~/.cursor/mcp.json` (+ project), VS Code `.vscode/mcp.json` /
  user `mcp.json`, the `.well-known/mcp/server.json` convention, plus known local AI ports (Ollama :11434,
  Foundry Local, etc.). Each entry: name + transport (`stdio {command,args,env}` or `http {url}`).
- **`mcp/client.zig`** — a JSON-RPC 2.0 MCP client (stdio: spawn the command, speak over stdin/stdout; HTTP+SSE
  for url servers). `initialize` → `notifications/initialized` → `tools/list` → `tools/call`. Same request/
  response shape as the CDP client already built.
- **Tools:** `mcp_discover` (list local MCP servers + their tools) and `mcp_call({server,tool,args})`. The
  daemon (§1) hosts the persistent stdio MCP server processes so a discovered server survives across the desk's
  subprocess-per-call calls, exactly like browser sessions.
- **RSI:** invented `make_tool` bodies compose `mcp_call`/`browser` via the daemon broker (the existing
  `browser()` helper generalizes to an `mcp()` helper). So RSI can "figure out" how to drive a discovered
  AI-ready app the same way it invents any tool. Gated + audited like the browser tools.

### 5. What stays server-side (unchanged)
Swarm minds (worker process) and CLI-direct / API turns (`tool_client:false`) keep the in-process manager. The
whole server-side implementation from round 1 is untouched; round 2 only adds the `roam`→daemon branch and the
MCP layer.

## New external dependencies
None. Reuses the CDP/browser layer + loopback broker + manager already built; the MCP client is new Zig
(JSON-RPC over stdio/HTTP), no crate. No bundled binaries. `mcp_*`/browser tools gated by `NL_BROWSER_DRIVER`
(and an `NL_MCP` gate for discovery), allowlisted, admin-classified on the chat surface as before.

## Open decisions (design gate)
1. **Daemon scope now:** browser-host only first, then add MCP — or build the daemon as a general local-capability
   host (browser + MCP) from the start?
2. **MCP discovery breadth:** config-file scan only, or also probe known local AI-runtime ports (Foundry Local,
   Ollama, etc.) as "AI-ready apps"?
3. **Routing default:** confirm browser/pixel/mcp should run **client-side whenever a client is attached**
   (`roam`/`tool_client`), server-side only for swarm + CLI-direct.
4. **Build order** once approved.

## Proposed build order (pending #4)
1. `local-host` daemon subcommand hosting the existing broker+manager + discovery file + idle-exit; `exec-tool`
   browser/pixel dispatch routes to it when `roam`. Verify the desk subprocess-per-call path now persists one
   browser across delegated calls.
2. System-prompt capability hint (§3) so the chat reaches for the client browser when crawling fails.
3. `mcp/client.zig` (stdio first) + `mcp/discovery.zig` + `mcp_discover`/`mcp_call` + daemon MCP hosting.
4. `mcp()` RSI helper + audit/gating; HTTP MCP transport; known-port AI-runtime probes.
