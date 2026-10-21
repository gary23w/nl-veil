//! The mind's toolbelt: the keyless, single-purpose tools a mind calls during a moment to build, research,
//! and remember. The model is given SCHEMA as the `tools` array; execute() runs a parsed tool_call and
//! returns a text result to feed back into the conversation.
const std = @import("std");
const builtin = @import("builtin");
const oscillation = @import("oscillation.zig");
const Mem = oscillation.Mem;
const bufedit = @import("bufedit.zig");
const hashline = @import("hashline.zig");
const ragingest = @import("ragingest.zig");
const vcs = @import("vcs.zig");
const commons = @import("commons.zig");
const llm = @import("llm.zig");
const rerank = @import("rerank.zig");
const crawl = @import("crawl.zig");
const browser_mgr = @import("browser/manager.zig");
const browser_broker = @import("browser/broker.zig");
const browser_host = @import("browser/host.zig");
const mcp_discovery = @import("mcp/discovery.zig");
const pixelrag = @import("pixelrag.zig");
const deps = @import("deps.zig");
const ragmirror = @import("ragmirror.zig");
const recipes = @import("recipes.zig"); // recipe tools: DATA sequences over already-allowed tools (Feature: granted recipes)
const dataset = @import("dataset.zig"); // training-set capture — the tool-execution half of a set
const cftools = @import("cftools.zig"); // the cf_ family: a connected Cloudflare account's own tool belt
const garrett = @import("garrett.zig"); // Agent Garrett's belt: the user's own blue-team agent over MCP (garrett, garrett_tools)
const cpaths = @import("chat/paths.zig"); // sub-chat family base for recall (chat:<parent>__sN → chat:<parent>)
const bounded = @import("bounded.zig"); // a child run under a bound that holds on Windows too (std.process.run's does not)

/// Injected into an authored tool's Python body ONLY when NL_BROWSER_DRIVER is enabled: a `browser(action,
/// params)` helper that POSTs to the loopback broker so an INVENTED tool can compose the browser primitives
/// (navigate/read/click/type/eval/close). It reads the broker url + token + run_dir key from the child env
/// (which runAuthored injects). `_o` is os (bound by the sandbox guard preamble).
const BROWSER_HELPER_PY =
    \\def browser(action,params=None):
    \\ import json as _bj,urllib.request as _bu
    \\ _d=_bj.dumps({"token":_o.environ.get("NL_BROWSER_BROKER_TOKEN",""),"key":_o.environ.get("NL_BROWSER_KEY",""),"action":action,"params":params or {}}).encode()
    \\ _rq=_bu.Request(_o.environ.get("NL_BROWSER_BROKER",""),data=_d,headers={"Content-Type":"application/json"})
    \\ return _bj.loads(_bu.urlopen(_rq,timeout=90).read().decode())
    \\
;

/// Injected into an authored tool's body when NL_MCP is set: an `mcp(server,tool,args)` helper (and mcp_find())
/// so an INVENTED tool can call the AI-ready MCP servers installed on the machine, via the same local broker as
/// browser().
const MCP_HELPER_PY =
    \\def mcp(server,tool,args=None):
    \\ import json as _pj,urllib.request as _pu
    \\ _d=_pj.dumps({"token":_o.environ.get("NL_BROWSER_BROKER_TOKEN",""),"key":_o.environ.get("NL_BROWSER_KEY",""),"action":"mcp_call","params":{"server":server,"tool":tool,"args":args or {}}}).encode()
    \\ _rq=_pu.Request(_o.environ.get("NL_BROWSER_BROKER",""),data=_d,headers={"Content-Type":"application/json"})
    \\ return _pj.loads(_pu.urlopen(_rq,timeout=90).read().decode())
    \\def mcp_find(server=None):
    \\ import json as _pj,urllib.request as _pu
    \\ _d=_pj.dumps({"token":_o.environ.get("NL_BROWSER_BROKER_TOKEN",""),"key":_o.environ.get("NL_BROWSER_KEY",""),"action":"mcp_discover","params":({"server":server} if server else {})}).encode()
    \\ _rq=_pu.Request(_o.environ.get("NL_BROWSER_BROKER",""),data=_d,headers={"Content-Type":"application/json"})
    \\ return _pj.loads(_pu.urlopen(_rq,timeout=90).read().decode())
    \\
;

/// Kills a child by handle past its deadline; moved to bounded.zig beside the bounded run and its tree kill.
const spawnGuarded = bounded.spawnGuarded;

/// Fetch a URL via curl into a per-mind temp file, guarded by spawnGuarded (so a WAF hang is killed, not fatal), then
/// read back whatever body arrived. Caller frees. `json` adds the Accept header; `limit` caps the read.
///
/// FETCH CACHE: successful bodies persist to data/_fetch_cache (7-day TTL, keyed by url+accept, timestamp
/// header line + body) so a page is fetched ONCE across all minds, rounds, and runs. Deliberately NOT on the
/// search path (search freshness is load-bearing) and BYPASSED under an active egress allowlist (cached
/// off-allowlist content must never leak into a gated run). A torn concurrent write self-heals: the header
/// parse fails, we refetch, we rewrite.
fn curlToText(ctx: *ToolCtx, url: []const u8, json: bool, deadline_ms: u32, limit: usize) []u8 {
    return fetchCached(ctx.io, ctx.gpa, ctx.run_dir, ctx.mind, url, json, deadline_ms, limit, ctx.egress_allow);
}

/// The cache+curl core behind curlToText, callable WITHOUT a ToolCtx so the engine itself (run.zig's nl-rag
/// pack prefetch) can pull a url through the SAME shared 7-day fetch cache — same hash key, same on-disk
/// format, so a page the engine prefetches is free for a scout to web_fetch later and vice versa. `mind` only
/// names the per-fetch temp file; `egress_allow` gates caching + forbids redirects exactly as before.
pub fn fetchCached(io: std.Io, gpa: std.mem.Allocator, run_dir: []const u8, mind: []const u8, url: []const u8, json: bool, deadline_ms: u32, limit: usize, egress_allow: []const u8) []u8 {
    // LOCAL KNOWLEDGE MIRROR: a corpus url whose file exists in the local pack tree is served from disk —
    // no network, works fully offline, and every consumer (engine prefetch, scout web_fetch, crawls) gets
    // it for free because they all route through here. Gated off under an egress allowlist so a gated run
    // keeps exactly its declared surface.
    if (egress_allow.len == 0) if (ragmirror.resolve(io, gpa, url, limit)) |body| return body;
    const cache_ttl_s: i64 = 7 * 24 * 3600;
    var cpath: []const u8 = "";
    defer if (cpath.len > 0) gpa.free(@constCast(cpath));
    if (egress_allow.len == 0) blk_cache: {
        const cdir = std.fmt.allocPrint(gpa, "{s}/../_fetch_cache", .{run_dir}) catch break :blk_cache;
        defer gpa.free(cdir);
        _ = std.Io.Dir.cwd().createDirPathStatus(io, cdir, .default_dir) catch {};
        const h = std.hash.Wyhash.hash(if (json) 1 else 0, url);
        cpath = std.fmt.allocPrint(gpa, "{s}/{x}.txt", .{ cdir, h }) catch "";
        if (cpath.len == 0) break :blk_cache;
        const cached = std.Io.Dir.cwd().readFileAlloc(io, cpath, gpa, .limited(limit + 64)) catch break :blk_cache;
        const nl = std.mem.indexOfScalar(u8, cached, '\n') orelse {
            gpa.free(cached);
            break :blk_cache;
        };
        const ts = std.fmt.parseInt(i64, std.mem.trim(u8, cached[0..nl], " \r"), 10) catch {
            gpa.free(cached);
            break :blk_cache;
        };
        if (std.Io.Timestamp.now(io, .real).toSeconds() - ts <= cache_ttl_s and cached.len > nl + 1) {
            const body = gpa.dupe(u8, cached[nl + 1 ..]) catch {
                gpa.free(cached);
                break :blk_cache;
            };
            gpa.free(cached);
            return body;
        }
        gpa.free(cached); // expired — fall through to a live fetch that overwrites it
    }
    const tmp = std.fmt.allocPrint(gpa, "{s}/.fetch-{s}.tmp", .{ run_dir, mind }) catch return dupe(gpa, "oom");
    defer gpa.free(tmp);
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sSL", "--max-time", "20", "--connect-timeout", "10", "--speed-limit", "1", "--speed-time", "15", "-o", tmp, "-A", "neuron-loops-mind/1.0" }) catch return dupe(gpa, "oom");
    // Under an active egress allowlist, a redirect could hop OFF the allowlist (the gate only sees the seed URL),
    // so forbid redirect-following entirely — the allowlisted host must answer directly.
    if (egress_allow.len > 0) av.appendSlice(gpa, &.{ "--max-redirs", "0" }) catch {};
    if (json) av.appendSlice(gpa, &.{ "-H", "Accept: application/json" }) catch {};
    av.append(gpa, url) catch {};
    // A MISSING curl must not read back as a silent empty body — all remote HTTP routes through curl, so
    // surface the actionable dep hint. A curl that spawned and got blocked/timed out keeps the "" path.
    if (spawnGuarded(io, av.items, deadline_ms)) |e| {
        if (deps.isSpawnMissing(e)) return deps.hint(gpa, "curl");
    }
    const raw = std.Io.Dir.cwd().readFileAlloc(io, tmp, gpa, .limited(limit)) catch (gpa.dupe(u8, "") catch @constCast(""));
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    // Persist a substantial body for reuse (>=600 bytes filters most error/empty pages; a cached WAF page
    // costs one stale week at worst and the TTL ages it out).
    if (cpath.len > 0 and raw.len >= 600) {
        const stamped = std.fmt.allocPrint(gpa, "{d}\n{s}", .{ std.Io.Timestamp.now(io, .real).toSeconds(), raw }) catch null;
        if (stamped) |st| {
            defer gpa.free(st);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cpath, .data = st }) catch {};
        }
    }
    return raw;
}

/// A per-moment buffer for a WEAK model's deliberate memory writes (observe/share/note_stance). When a ToolCtx carries
/// a sink, those writes are queued here INSTEAD of hitting neuron-db immediately, so the engine can junk-filter +
/// writer-ground them against the moment's evidence at moment-end before committing (the anti-hallucination floor for
/// low-param models — see run.flushMemWrites). A capable model carries no sink and its writes store immediately.
pub const PendKind = enum { fact, stance, message };
pub const PendWrite = struct { kind: PendKind, a: []const u8, b: []const u8 = "" };
pub const MemSink = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayListUnmanaged(PendWrite) = .empty,
    pub fn push(self: *MemSink, kind: PendKind, a: []const u8, b: []const u8) void {
        const da = self.gpa.dupe(u8, a) catch return;
        const db = if (b.len > 0) (self.gpa.dupe(u8, b) catch "") else "";
        self.items.append(self.gpa, .{ .kind = kind, .a = da, .b = db }) catch self.gpa.free(da);
    }
    pub fn deinit(self: *MemSink) void {
        for (self.items.items) |it| {
            self.gpa.free(@constCast(it.a));
            if (it.b.len > 0) self.gpa.free(@constCast(it.b));
        }
        self.items.deinit(self.gpa);
    }
};

/// What a caller is allowed to reach through `execute`.
///
/// `.full` is the historical behaviour and stays the default: swarm minds, the desk on localhost, the
/// CLI, and admin chat all run the complete surface.
///
/// `.sandboxed` is for a caller whose prompts are not trusted with the host — a normal (non-admin)
/// account on a shared server. It keeps files (already jailed to the conversation workdir by safeRel),
/// research, and the ENTIRE hive-memory surface, and removes code execution, host control, engine
/// self-modification, tool authoring, and browser/MCP drive.
pub const Caps = enum { full, sandboxed };

/// Tools a `.sandboxed` caller may run. An ALLOWLIST, deliberately — `execute`'s tail falls through to
/// runAuthored for any unrecognised name (see the make_tool path), so a denylist would be bypassed by
/// authoring a tool and calling it by its new name. Anything not named here is refused.
///
/// The hive verbs are all present on purpose: the shared associative memory is the product, and a
/// sandboxed user keeps every bit of it. What they lose is the ability to act on the machine.
const SANDBOX_TOOLS = [_][]const u8{
    // research
    "web_search",    "web_fetch",    "fetch_json",          "read_url",
    // hive / memory — the whole surface, intentionally
    "recall",        "recall_hive",  "read_doc",            "observe",
    "share",         "note_stance",  "save_skill",          "journal",
    "set_directive", "probe",        "add_task",            "claim_task",
    "complete_task", "send_message", "propose_plan_change",
    // bounded observation of files/urls/ports/processes — read-only watching (its 'command' kind
    // self-gates on caps inside pollTool, so a sandboxed caller keeps the observational kinds)
    "poll",
    // files, jailed to the conversation's own workdir
    "write_file",    "edit_file",    "read_file",           "list_dir",
    "delete_file",
    // local retrieval over this conversation's own attachments; renders nothing, touches no network
      "pixel_search",
    // read-only swarm observation (each is uid-checked by its handler)
    "swarm_status",        "swarm_asks",
    "stop_swarm",
};

/// Is `name` runnable by a sandboxed caller? Exposed so the HTTP tool endpoint can share this exact
/// predicate rather than keeping a second list that drifts out of step with this one.
pub fn sandboxAllowed(name: []const u8) bool {
    for (SANDBOX_TOOLS) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

/// The tool belt a SMALL-tier model is shown (modelcfg.Tier.small — ≤24B params, or a ≤15k window). Not a
/// permission list: `execute` still dispatches every name in SCHEMA, so a small model that names a dropped
/// tool from memory still runs it. This is purely about how much surface it must REASON over.
///
/// WHY: a chat turn advertised all 49 tools to every model — 35 KB of schema against 11 KB of actual
/// conversation, ~75% of the request, re-sent on every inference. A frontier model shrugs that off; a 12B
/// model drowns in it. Observed live on a 12B: asked for the weather it invented `WebSearch` (the real name is
/// `web_search`) and a `Gemma4__1m_check` tool, and when told to use the browser it reached for
/// `mcp_call{server:"google-search"}` and `mcp_discover` — twice — while `browser_navigate` sat in the same
/// list. Every drop below is one fewer decoy between the model and the verb it wanted.
///
/// The keep-set is the solo-chat core: research, files, code, memory, the four load-bearing browser verbs.
/// The drops fall in four groups — (1) multi-agent orchestration a solo small model cannot drive (cast,
/// steer_swarm, answer_swarm, swarm_*, open_subchat, sync_dir, stage_file, absorb, poll); (2) advanced twins
/// of a verb already in the belt (browser_type_text, browser_click_at, browser_key, browser_scroll,
/// browser_console, browser_network, browser_eval, browser_close, pixel_capture, pixel_ingest, recall_hive);
/// (3) the MCP pair, empirically the top hallucination magnet above; (4) scheduling + credential fetch, which
/// need precision a small model does not have. Mid and large tiers are untouched and keep the full belt.
///
/// A LATER PASS dropped three more, measured against the window this tier is actually served. The built-in
/// engine's fit ladder lands around 9216 tokens on a consumer card, and the 20-tool belt was 3,599 of them —
/// 39% of the whole window spent on schema before a single word of conversation. read_url and fetch_json went
/// because web_fetch already covers both and run_python covers any header/JSON nuance either had: three verbs
/// that fetch a URL are a CHOICE burden on a 12B, not merely bytes, and this tier's whole failure mode is
/// picking wrong among near-twins. stop_process went because a chat-tier small model never backgrounds the
/// process it would stop. 346 tokens, no capability lost — execute() still dispatches all three by name.
///
/// The four browser verbs STAY despite costing 1,120 tokens, the largest block on the belt. In the live
/// session that motivated this pass they are the one thing that worked: the model drove browser_navigate +
/// browser_read to a real page, noticed the content was thin, and moved on. Reclaiming that 12% would trade
/// the tier's only demonstrated capability for window it has other ways to find.
const COMPACT_TOOLS = [_][]const u8{
    // research (web_fetch is the ONE fetch verb — see the note above on read_url/fetch_json)
    "web_search",   "web_fetch",
    // files
    "read_file",    "write_file",
    "edit_file",    "list_dir",
    "delete_file",
    // code — run_shell and tool_env ride along because a machine without Python has only run_shell to get one,
    // and a small local model is the usual tenant of such a machine
     "run_python",
    "run_shell",    "tool_env",
    "run_tests",
    // memory + documents (one recall verb, not two)
       "recall",
    "observe",      "read_doc",
    "pixel_search",
    // the browser, reduced to the four verbs that actually drive a page
    "browser_navigate",
    "browser_read", "browser_click",
    "browser_type",
};

/// Is `name` in the small-tier belt? Twin of sandboxAllowed, same reason: one list, shared predicate.
pub fn compactAllowed(name: []const u8) bool {
    for (COMPACT_TOOLS) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

/// SMALL-TIER DESCRIPTIONS. The other half of fitting a small window — and the half that costs nothing.
///
/// The membership lever (COMPACT_TOOLS) is spent: the belt is already 19 of ~70 verbs, and the only block left
/// big enough to matter is the browser, which cannot go. Cutting all four makes SCOUT_BROWSER_SCHEMA
/// (worker/run.zig) a bare ",\n" that is still spliced, handing every scout mind a malformed tools array; cutting
/// below three disables beltDenial's family-level correction. Meanwhile the belt's REAL cost is prose written for
/// a large model: measured on the shipped gemma4 tokenizer, the four browser defs are 82-89% description, and
/// descriptions are ~64% of the whole belt. Rewriting them terser takes the belt roughly in half while removing
/// no capability at all — which is strictly better for a 12B than hiding verbs from it, the failure the
/// failure-streak nudge exists to paper over ("offered a 12B four tools its belt hides").
///
/// Rules for entries here, learned from the descriptions being replaced: say what the tool DOES and when to reach
/// for it, in one clause; teach the workflow a small model gets wrong (browser_read yields the refs that
/// browser_click and browser_type consume); and NEVER name a verb the small belt does not serve — five of the old
/// descriptions advertised read_url, deep_crawl, pixel_ingest, pixel_capture, absorb, recall_hive and
/// patch_system to a tier that has none of them, which is the same unadvertised-verb bug the compact system
/// prompt has a test for.
const TERSE_DESC = [_]struct { name: []const u8, desc: []const u8 }{
    // research
    .{ .name = "web_search", .desc = "Search the web. Returns titles, URLs and snippets." },
    .{ .name = "web_fetch", .desc = "Fetch a URL and return its readable text. Use this before answering about any page." },
    // files
    .{ .name = "read_file", .desc = "Read a file in the workdir. For a large file pass start_line/end_line and read a slice." },
    .{ .name = "write_file", .desc = "Create or overwrite a file in the workdir with the full content you supply." },
    .{ .name = "edit_file", .desc = "Replace one exact block of text in a file. Copy the old text VERBATIM from a read_file result, including indentation." },
    .{ .name = "list_dir", .desc = "List the files and folders in the workdir." },
    .{ .name = "delete_file", .desc = "Delete a file from the workdir." },
    // code
    .{ .name = "run_python", .desc = "Run a Python script in the workdir. Returns stdout, stderr and the exit code." },
    .{ .name = "run_shell", .desc = "Run a PowerShell, bash, sh or cmd script in the workdir. Returns stdout, stderr and the exit code. Use it for commands, and to install a missing program (winget / brew / apt) — then tool_env refresh_path." },
    .{ .name = "tool_env", .desc = "Keep an environment change for every later tool run, with no restart. After installing a program with run_shell, call action refresh_path; or action set with name and value (NL_PYTHON_BIN names the Python that run_python uses)." },
    .{ .name = "run_tests", .desc = "Run the project's tests and return the result." },
    // memory + documents
    .{ .name = "recall", .desc = "Look up facts remembered earlier in this conversation." },
    .{ .name = "observe", .desc = "Remember one durable fact so later turns can recall it." },
    .{ .name = "read_doc", .desc = "Read a stored document." },
    .{ .name = "pixel_search", .desc = "Search the text found inside images attached to this conversation." },
    // browser — read yields the refs the other two consume; say so, because that is the step a small model skips
    .{ .name = "browser_navigate", .desc = "Open a URL in the real browser. Use when a page needs JavaScript or a login; otherwise prefer web_fetch." },
    .{ .name = "browser_read", .desc = "Read the current browser page as text. Interactive elements come back numbered as refs — you need these before clicking or typing." },
    .{ .name = "browser_click", .desc = "Click an element on the current page by its ref from browser_read." },
    .{ .name = "browser_type", .desc = "Type text into a field on the current page by its ref from browser_read." },
};

/// The small-tier DESCRIPTION projection: swap each def's description for its TERSE_DESC entry and leave the
/// `"parameters"` object byte-identical. Composed over compactSchema, never applied to the source blocks — editing
/// CHAT_SCHEMA in place would change the belt for every mid/large model and trip the verbatim drift guard.
/// comptime-only, so both belts stay static strings and prefix caching is unaffected. A def whose name has no
/// entry passes through untouched, so adding a tool to COMPACT_TOOLS without a terse description degrades to
/// today's text rather than breaking.
pub fn terseSchema(comptime block: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    comptime var out: []const u8 = "";
    comptime {
        var it = std.mem.splitScalar(u8, block, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r,");
            if (line.len == 0) continue;
            var emit: []const u8 = line;
            const nkey = "\"name\":\"";
            if (std.mem.indexOf(u8, line, nkey)) |at| {
                const rest = line[at + nkey.len ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |end| {
                    const nm = rest[0..end];
                    for (TERSE_DESC) |t| {
                        if (!std.mem.eql(u8, t.name, nm)) continue;
                        const dkey = "\"description\":\"";
                        const ds = std.mem.indexOf(u8, line, dkey) orelse break;
                        const vstart = ds + dkey.len;
                        // the description value always ends at the parameters key — verified across every belt def
                        const de = std.mem.indexOfPos(u8, line, vstart, "\",\"parameters\"") orelse break;
                        emit = line[0..vstart] ++ t.desc ++ line[de..];
                        break;
                    }
                }
            }
            out = if (out.len == 0) emit else out ++ ",\n" ++ emit;
        }
    }
    return out;
}

/// The small-tier projection of a schema block — DERIVED from compactAllowed exactly as sandboxSchema is
/// derived from sandboxAllowed (see the drift argument there; it applies verbatim). comptime-only, so the
/// variant is a static string and picking between belts costs a turn nothing.
pub fn compactSchema(comptime block: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    comptime var out: []const u8 = "";
    comptime {
        var it = std.mem.splitScalar(u8, block, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r,");
            if (line.len == 0) continue;
            const key = "\"name\":\"";
            const at = std.mem.indexOf(u8, line, key) orelse continue;
            const rest = line[at + key.len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            if (!compactAllowed(rest[0..end])) continue;
            out = if (out.len == 0) line else out ++ ",\n" ++ line;
        }
    }
    return out;
}

/// The `.sandboxed` projection of a tools-array schema block: the same comma-joined function defs with every
/// entry the sandbox gate above would refuse dropped. DERIVED from sandboxAllowed rather than a second list of
/// names — a hand-copied list rots silently the first time SANDBOX_TOOLS changes, and the cost of the drift is
/// paid in prefill: a tool advertised to a caller who provably cannot execute it is re-sent on EVERY inference
/// of the turn and invites a whole wasted agentic round-trip.
///
/// comptime-only, so both variants are static strings and a turn pays nothing to pick between them. Each entry
/// must sit on its OWN line (every schema in this file is written that way): the line is the unit kept or
/// dropped, and its tool name is read from the leading `"name":"…"`. The removal is therefore PER-TOOL, not
/// per-block — pixel_search survives even though its two PIXEL_SCHEMA neighbours do not.
pub fn sandboxSchema(comptime block: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    comptime var out: []const u8 = "";
    comptime {
        var it = std.mem.splitScalar(u8, block, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r,"); // strip the join comma; re-added below
            if (line.len == 0) continue;
            const key = "\"name\":\"";
            const at = std.mem.indexOf(u8, line, key) orelse continue; // nameless line: not a tool def, drop it
            const rest = line[at + key.len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            if (!sandboxAllowed(rest[0..end])) continue;
            out = if (out.len == 0) line else out ++ ",\n" ++ line;
        }
    }
    return out;
}

/// Cooperative cancellation for tools that BLOCK for a long time.
///
/// The chat turn already drains its control channel — Stop, and mid-turn steer — but only "between drive steps
/// and before each tool". That is fine for a tool that returns promptly and useless for one that does not:
/// `poll` is bounded at 180s per call and is DESIGNED to be chained, so a long watch offers a read point only
/// every few minutes. Stop looks like it did nothing, a steer sits unread, and the turn holds its thread
/// throughout. The LLM streaming path has had a mid-flight abort check for a while; the tool path had none.
///
/// A function pointer rather than a bool because the answer lives in the conversation's control.jsonl, which
/// tools.zig cannot see. Null everywhere it is not set — swarm minds, the CLI — so those keep today's exact
/// behaviour, and a tool that ignores it is no worse off than before.
/// WHY a blocking tool should come back. Stop and steer both mean "the user is talking to you and you are
/// not listening", but they want opposite things next: a stop ends the turn, a steer wants the watch
/// reconsidered in light of what was just said. One bool for both would make every steer end the turn.
pub const CancelReason = enum { none, stopped, steered };

pub const Cancel = struct {
    fn_ptr: *const fn (*anyopaque) CancelReason,
    ctx: *anyopaque,
    pub fn check(self: Cancel) CancelReason {
        return self.fn_ptr(self.ctx);
    }
};

pub const ToolCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Set by the chat turn so a long-blocking tool can notice Stop between its own samples. See Cancel.
    cancel: ?Cancel = null,
    environ: *const std.process.Environ.Map,
    run_dir: []const u8,
    workdir: []const u8,
    scope: []const u8,
    learn_scope: []const u8 = KNOWLEDGE_SCOPE,
    mind: []const u8,
    round: u32,
    mem: Mem,
    files_written: *u32,
    observed: *u32,
    mem_sink: ?*MemSink = null,
    skills_saved: *u32,
    directives_set: *u32,
    tools_made: *u32,
    space: []const u8 = "",
    band_y0: i64 = -1,
    band_y1: i64 = -1,
    my_files: []const u8 = "",
    owned_by_others: []const u8 = "",
    share_obs: bool = false,
    internet: bool = true,
    /// The swarm worker's browser decision (run.zig w.browser), threaded so browserEnabled honors ONE
    /// source of truth instead of re-reading NL_BROWSER_DRIVER — the schema that advertises the tool and
    /// the gate that dispatches it must agree. Default false: a chat ToolCtx that leaves it unset falls
    /// through to the env/caps check exactly as before (no chat-path change).
    browser: bool = false,
    discourse: bool = false,
    one_slot: bool = false,
    slot_path: []const u8 = "",
    blueprint: []const u8 = "",
    egress_allow: []const u8 = "",
    // gateway (BYOK) creds for the SECOND-STAGE reranker — the same endpoint screenPass/gapToQuery use, so
    // recall_hive can reorder+filter its first-stage hits through the selected API. Empty model ⇒ no rerank.
    gw_base: []const u8 = "",
    gw_key: []const u8 = "",
    gw_model: []const u8 = "",
    fmtx: ?*std.Io.Mutex = null,
    vcs_enabled: bool = false, // route edit_file through the swarm micro-VCS (concurrent-safe merge commits)
    anchored_reads: bool = false, // build mode: read_file prefixes every line with its edit-anchor tag (see hashline.zig)
    reject_notes: ?*std.ArrayListUnmanaged(u8) = null, // per-round write-refusal ledger (owned by the Worker) — folded into the fitness block so refusals are visible, not silent
    patch_root: []const u8 = "", // DEFAULT engine source root for patch_system when NL_PATCH_SYSTEM_ROOT is unset — a mind is root of its own VM (resolved once from the executable path by the worker)
    // CLIENT-EXECUTOR privilege (`veil exec-tool` only): READ-ONLY tools (read_file/list_dir) may take an
    // ABSOLUTE or ~-prefixed path anywhere the user's own account can read, and stage_file may copy such a
    // file INTO the workdir (so a cast's sync can carry it to a hive). The user asked their own machine's
    // assistant to act on their own files — the workdir jail is a SWARM-mind boundary, not a client one.
    // Writes (write_file/edit_file/delete_file) stay workdir-locked everywhere. Never set for minds.
    roam: bool = false,
    // OPERATE / APP-ATTACH bus protection. `operating` mirrors w.operating (a device/app is attached to this
    // run's file bus); `app_attach` is the opt-in generic-app LEARN mode (NL_APP_ATTACH). When EITHER is set,
    // the file-mutating tools refuse to write the reserved bus/oracle files (reservedBusName), so a mind can
    // actuate/grade an attached host ONLY through the adjudicated host_* tools — closing the write_file bypass.
    // app_attach additionally makes the phase read-only (no mutating host verb, no run_python/make_tool).
    operating: bool = false,
    app_attach: bool = false,
    // Capability tier for THIS caller — see Caps. Defaults to .full so every existing construction site
    // (swarm minds, the CLI, exec-tool, the desk) keeps today's behaviour untouched; only the chat turn
    // sets .sandboxed, and only for a non-admin.
    caps: Caps = .full,
    // Route browser/pixel tools through the per-machine local-host DAEMON instead of the in-process manager.
    // Set ONLY by `veil exec-tool` (subprocess-per-call: a fresh process per delegated tool can't hold a browser
    // session, so the daemon does). A LONG-LIVED process (the server's /chat/tool endpoint, a swarm worker) keeps
    // the session IN-PROCESS — spawning a daemon from it just piles up unreachable daemons.
    browser_daemon: bool = false,
    // CROSS-CONVERSATION HIVE GUARD: set by the CHAT surfaces, whose mem db (the per-user chat hive) is shared
    // across ALL of a user's conversations — there, a KNOWLEDGE-scope write leaks between unrelated tasks.
    // Conversation-local project state (file paths, line numbers, workdir layout) stays in ctx.scope, and what
    // does globalize is provenance-tagged with source+date instead of "[chat r0]". Swarm workers keep this OFF:
    // their db is per-swarm, where cross-mind file facts are the whole point of the hive.
    hive_guard: bool = false,
    // Path to the user's durable memory store ({data}/.veil-desk/memories.jsonl) for get_credential — set ONLY
    // by the CHAT surfaces (the veil acting as the user). Empty everywhere else: a swarm mind structurally
    // cannot fetch user credentials, matching the no-creds-in-hive egress design.
    durable_path: []const u8 = "",
    // GRANTED RECIPES (I3): the per-turn resolved list of recipe tools THIS caller may run — for a sandboxed
    // caller the registry ∩ the user's tool_grants, for an admin the whole registry (resolved ONCE per turn in
    // engine.zig, so it is turn-stable and advertising these schemas doesn't vary with message content →
    // prefix-cache safe). A recipe is DATA: grantedRecipe() only routes a granted name through runRecipe as a
    // data recipe — it NEVER widens sandboxAllowed, and every step re-hits the top gate under THESE caps (I4),
    // so a granted recipe can never do more than the caller could by hand. Defaulted empty so every non-chat
    // construction site (swarm minds, CLI, exec-tool, desk) is untouched: no grants ⇒ the feature is inert.
    grants: []const *const recipes.Recipe = &.{},
    // CLOUDFLARE (cf_ family): the per-turn resolved credentials for the user's OWN connected account —
    // set ONLY by the chat surfaces, which resolve them once per turn through cf_oauth.resolveToken (it
    // auto-refreshes). Blank everywhere else, and blank means the family is neither advertised nor
    // dispatchable: a swarm mind or a CLI caller structurally cannot reach the user's cloud. Same shape
    // and same reason as durable_path above.
    cf_token: []const u8 = "",
    cf_account: []const u8 = "",
    /// Where the cf_ family sends its calls. The real API unless the server was started with a loopback
    /// NL_CF_API_ROOT (a simulation stand-in) — see cftools.isLoopbackRoot for why it can be nothing else.
    cf_api_root: []const u8 = cftools.API,
    /// Set by the chat engine around ONE cf_ call in a client-mode turn, and null otherwise: the verb sets it
    /// true once a download has landed in this workdir (cftools.Ctx.wrote), which is how the engine knows
    /// there is a file to carry back to the user's machine.
    cf_wrote: ?*bool = null,
    // AGENT GARRETT (garrett, garrett_tools): where the user's own blue-team agent answers and the bearer it
    // answers to — derived per turn by the chat engine (config/cf_garrett.zig) when the client asked for it, read
    // from keys.env by a swarm worker whose deploy asked. Blank everywhere else, and blank means the two verbs
    // are neither advertised nor dispatchable: same shape and same reason as the cf_ pair above.
    garrett_url: []const u8 = "",
    garrett_token: []const u8 = "",
    garrett_schema: []const u8 = "",
    // Recipe recursion depth. A recipe step may not name another recipe (refused at run time, I5), so this is
    // 0 or 1 in practice; it is a belt-and-braces backstop against any future path that could re-enter
    // runRecipe, guaranteeing one level only regardless of how the step was reached.
    recipe_depth: u8 = 0,
};

fn lockFiles(ctx: *ToolCtx) void {
    if (ctx.fmtx) |m| m.lockUncancelable(ctx.io);
}
fn unlockFiles(ctx: *ToolCtx) void {
    if (ctx.fmtx) |m| m.unlock(ctx.io);
}

/// Append a write-path refusal to the round-shared ledger under the files mutex (minds run concurrently, so
/// this bare ArrayList would otherwise race). Called only from writeFile's early guard returns, before the
/// function reaches its own lockFiles — so there is no nested acquisition of the same lock.
fn noteWriteReject(ctx: *ToolCtx, path: []const u8, why: []const u8) void {
    const rn = ctx.reject_notes orelse return;
    lockFiles(ctx);
    defer unlockFiles(ctx);
    if (rn.items.len > 600) return;
    rn.appendSlice(ctx.gpa, path) catch {};
    rn.appendSlice(ctx.gpa, why) catch {};
}

/// Land `data` at `full` via a same-directory temp + atomic rename (createFileAtomic → replace), so a crash or a
/// concurrent reader never sees a torn/half-written file — old bytes stand until the new file swaps in atomically.
/// The temp shares the target's directory, so the rename is always same-volume (never a byte-copy). Returns false
/// on any I/O error, leaving the previous file intact (the caller reports it, nothing partial is committed).
fn writeWorkFileAtomic(ctx: *ToolCtx, full: []const u8, data: []const u8) bool {
    var af = std.Io.Dir.cwd().createFileAtomic(ctx.io, full, .{ .replace = true, .make_path = true }) catch return false;
    defer af.deinit(ctx.io);
    af.file.writeStreamingAll(ctx.io, data) catch return false;
    af.file.sync(ctx.io) catch {}; // best-effort durability; not fatal where fsync is unsupported
    af.replace(ctx.io) catch return false;
    return true;
}

/// File extensions that mark a fact as naming a concrete project file. Deliberately code/asset-shaped: a
/// fact naming one of these pins a BUILD's contents, which is meaningless outside its own conversation.
const PROJECT_EXTS = [_][]const u8{ "zig", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cc", "cpp", "hpp", "cs", "java", "kt", "swift", "php", "lua", "sh", "ps1", "bat", "cmd", "html", "htm", "css", "scss", "md", "txt", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "sql", "csv", "tsv", "xml", "svg", "png", "jpg", "jpeg", "gif", "ico", "wasm", "exe", "dll", "zip" };

fn knownProjectExt(ext: []const u8) bool {
    for (&PROJECT_EXTS) |e| {
        if (std.mem.eql(u8, e, ext)) return true;
    }
    return false;
}

/// A filename with a code/asset extension, outside a URL. URL-bearing facts are exempt from this rule:
/// they are the hive's legitimate content (web findings), and page paths in links (".html", "/guides/")
/// are not project files. A Capitalized stem ("Three.js", "Node.js", "D3.js") is a LIBRARY name, not a file.
fn factNamesProjectFile(fact: []const u8) bool {
    if (std.mem.indexOf(u8, fact, "://") != null) return false;
    var i: usize = 1;
    while (i + 1 < fact.len) : (i += 1) {
        if (fact[i] != '.') continue;
        const prev = fact[i - 1];
        if (!std.ascii.isAlphanumeric(prev) and prev != '_' and prev != '-') continue;
        var j = i + 1;
        while (j < fact.len and j - i <= 5 and std.ascii.isAlphanumeric(fact[j])) j += 1;
        if (j == i + 1) continue; // bare dot
        if (j < fact.len and (std.ascii.isAlphanumeric(fact[j]) or fact[j] == '.')) continue; // longer word / version dots
        var ebuf: [6]u8 = undefined;
        if (!knownProjectExt(std.ascii.lowerString(&ebuf, fact[i + 1 .. j]))) continue;
        var s = i;
        while (s > 0 and (std.ascii.isAlphanumeric(fact[s - 1]) or fact[s - 1] == '_' or fact[s - 1] == '-')) s -= 1;
        if (std.ascii.isUpper(fact[s])) continue;
        return true;
    }
    return false;
}

/// A source-position reference: "line 215", "lines 130-210", "line ~1380". Word-boundary guarded so
/// "deadline 2026" / "airline 5" / "line-height" never match.
fn factNamesLineNumber(fact: []const u8) bool {
    var i: usize = 0;
    while (std.ascii.findIgnoreCasePos(fact, i, "line")) |at| {
        i = at + 4;
        if (at > 0 and std.ascii.isAlphabetic(fact[at - 1])) continue;
        var j = i;
        if (j < fact.len and (fact[j] == 's' or fact[j] == 'S')) j += 1;
        while (j < fact.len and (fact[j] == ' ' or fact[j] == '~' or fact[j] == '#' or fact[j] == ':')) j += 1;
        if (j < fact.len and std.ascii.isDigit(fact[j])) return true;
    }
    return false;
}

/// TRUE when a fact is CONVERSATION-LOCAL PROJECT STATE — it pins concrete files, source positions, or the
/// workdir's layout. Inside its own conversation such a fact is ground truth; recalled into a DIFFERENT one
/// it reads as "your existing codebase" and seeds a wholesale resurrection of the old project (observed
/// live: a fresh "build me a business" chat adopted a two-day-old FPS build because the shared hive
/// described its files). Lexical and conservative — what it misses, the read-side relevance bar catches.
pub fn convLocalFact(fact: []const u8) bool {
    const phrases = [_][]const u8{ "working directory", "workdir", "directory contains", "current directory", "this directory" };
    for (&phrases) |p| {
        if (std.ascii.findIgnoreCase(fact, p) != null) return true;
    }
    return factNamesLineNumber(fact) or factNamesProjectFile(fact);
}

test "Cancel: a blocking tool learns WHY it should come back, not just that it should" {
    const Probe = struct {
        reason: CancelReason = .none,
        fn ask(cx: *anyopaque) CancelReason {
            const s: *@This() = @ptrCast(@alignCast(cx));
            return s.reason;
        }
    };
    var p = Probe{};
    const c = Cancel{ .fn_ptr = Probe.ask, .ctx = &p };
    try std.testing.expectEqual(CancelReason.none, c.check());
    // Stop and steer must stay distinguishable all the way to the tool: collapsing them to one bool
    // would end the turn on a steer, which is the opposite of what the user asked for by typing.
    p.reason = .stopped;
    try std.testing.expectEqual(CancelReason.stopped, c.check());
    p.reason = .steered;
    try std.testing.expectEqual(CancelReason.steered, c.check());
}

test "poll asks about Stop at every sample, not only when its whole budget runs out" {
    // A poll is bounded at 180s and is DESIGNED to be chained, so the turn's between-tool Stop check can be
    // minutes away: the user presses Stop, nothing happens, and the thread stays held for the whole watch.
    // Position is the property here — inside the loop, and BEFORE the sleep. A check after the sleep answers
    // an interval late; a check outside the loop answers once, which is what it did before.
    const src = @embedFile("tools.zig");
    // Needles split so this test cannot match its OWN source: it sits above pollTool in the file, so an
    // unsplit literal finds itself first and then asserts ordering about the test instead of the function.
    const at = std.mem.indexOf(u8, src, "fn poll" ++ "Tool(") orelse return error.PollToolMissing;
    const body = src[at..@min(src.len, at + 16000)];
    const loop = std.mem.indexOf(u8, body, "while (true) {") orelse return error.PollLoopMissing;
    const sleep = std.mem.indexOf(u8, body, "pollSleep" ++ "Ms(") orelse return error.PollSleepMissing;
    const check = std.mem.indexOf(u8, body, "ctx." ++ "cancel") orelse {
        std.log.warn("tools.zig: pollTool no longer consults ctx.cancel — Stop waits out the full 180s budget", .{});
        return error.PollIgnoresCancel;
    };
    try std.testing.expect(check > loop);
    try std.testing.expect(check < sleep);

    // ...and a stopped watch must not read to the model like a timeout, whose documented answer is "call poll
    // again to keep waiting". That would chain a fresh poll and undo the Stop the user just pressed.
    const stopped = std.mem.indexOf(u8, body, "\"stop" ++ "ped\"") orelse {
        std.log.warn("tools.zig: poll has no distinct stopped verdict — a Stop reads as a timeout and gets re-polled", .{});
        return error.PollStopVerdictMissing;
    };
    _ = stopped;
}

test "convLocalFact pins files/lines/workdir, passes general knowledge" {
    // the four hive facts that derailed the observed run
    try std.testing.expect(convLocalFact("index.html is a ~1500-line THREE.js FPS game (Neo-Pulse Arena) with wave-based spawning"));
    try std.testing.expect(convLocalFact("WEAPON CONFIG insertion point: around line 215, currently has a simple array"));
    try std.testing.expect(convLocalFact("The game loop is in animate() at line ~1380."));
    try std.testing.expect(convLocalFact("The working directory contains a Cosmic Oracle fortune-teller script"));
    try std.testing.expect(convLocalFact("client/js/game.js holds the render loop"));
    // reusable knowledge must keep flowing to the hive
    try std.testing.expect(!convLocalFact("Windows 11 memory optimization: disable startup apps and visual effects"));
    try std.testing.expect(!convLocalFact("Three.js supports WebGPU rendering since r160"));
    try std.testing.expect(!convLocalFact("Monetization guide at https://example.com/guides/indie-games.html"));
    try std.testing.expect(!convLocalFact("Microtransactions were 58% of gaming revenue in 2024; the deadline 2026 estimate is higher"));
    try std.testing.expect(!convLocalFact("CSS line-height best practice is 1.5 for body text"));
}

/// A secret-shaped token: an unbroken [A-Za-z0-9_-]{20,} run containing both letters and digits — API keys,
/// PATs, hex secrets. Domains and URLs break at dots/slashes and prose at spaces, so ordinary text is clear.
/// Scans from `i`, returning the run end; sets `hit` when the run qualifies.
fn secretRunEnd(text: []const u8, i: usize, hit: *bool) usize {
    var j = i;
    var letters = false;
    var digits = false;
    while (j < text.len) : (j += 1) {
        const c = text[j];
        if (std.ascii.isAlphabetic(c)) {
            letters = true;
        } else if (std.ascii.isDigit(c)) {
            digits = true;
        } else if (c != '_' and c != '-') break;
    }
    hit.* = (j - i >= 20 and letters and digits);
    return j;
}

pub fn hasSecretToken(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            i += 1;
            continue;
        }
        var hit = false;
        i = secretRunEnd(text, i, &hit);
        if (hit) return true;
    }
    return false;
}

/// Copy of `text` with every secret-shaped token replaced by "[withheld]" — what the prompt may show of a
/// credential entry (the name survives, the value never does). gpa-owned.
pub fn maskSecretTokens(gpa: std.mem.Allocator, text: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            out.append(gpa, c) catch break;
            i += 1;
            continue;
        }
        var hit = false;
        const j = secretRunEnd(text, i, &hit);
        if (hit) out.appendSlice(gpa, "[withheld]") catch {} else out.appendSlice(gpa, text[i..j]) catch {};
        i = j;
    }
    return out.toOwnedSlice(gpa) catch &[_]u8{};
}

/// A durable entry whose VALUE must stay out of broadcast prompts: category "key", or any text carrying a
/// secret-shaped token (a miscategorized credential). Workflow facts that merely TALK about auth ("requires
/// Api-Key headers") carry no value and keep riding the prompt.
pub fn secretiveDurable(cat: []const u8, text: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, cat, " \r\n\t"), "key")) return true;
    return hasSecretToken(text);
}

test "secretiveDurable + maskSecretTokens withhold key values, pass workflow facts" {
    try std.testing.expect(secretiveDurable("key", "Discourse API key for a forum: aaaa1111bbbb2222cccc3333"));
    try std.testing.expect(secretiveDurable("fact", "my token is ghp_abc123abc123abc123abc123abc123")); // miscategorized
    try std.testing.expect(!secretiveDurable("fact", "Discourse API requires Api-Key/Api-Username headers and a CSRF token from /session/csrf.json"));
    try std.testing.expect(!secretiveDurable("preference", "preferred deploy region is us-west-2"));
    const gpa = std.testing.allocator;
    const masked = maskSecretTokens(gpa, "GitHub personal access token: ghp_abc123abc123abc123abc123abc123");
    defer if (masked.len > 0) gpa.free(masked);
    try std.testing.expectEqualStrings("GitHub personal access token: [withheld]", masked);
    const clear = maskSecretTokens(gpa, "internationalization efforts span 12345678901234567890 rows");
    defer if (clear.len > 0) gpa.free(clear);
    try std.testing.expect(std.mem.indexOf(u8, clear, "[withheld]") == null);
}

/// Render the wall-clock date as "yyyy-mm-dd" — the provenance stamp for facts a conversation globalizes.
/// pub: the chat engine grounds every turn's system prompt in it — a local model has no idea what day it is
/// and confidently invents one (observed: a 12B date-qualifying news searches with three different wrong
/// years in one turn), which poisons every time-sensitive query it writes.
pub fn dateStamp(io: std.Io, buf: []u8) []const u8 {
    const secs = std.Io.Timestamp.now(io, .real).toSeconds();
    if (secs <= 0) return "undated";
    const yd = (std.time.epoch.EpochSeconds{ .secs = @intCast(secs) }).getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), @as(u32, md.day_index) + 1 }) catch "undated";
}

/// Write a fact to the SHARED hive, TAGGED with who/when ("[Noor r7] ..."). A hive fact is a mind's own first-person
/// sentence; tagging it tells every reader it is a TEAMMATE's report, not their own memory — preventing the identity
/// merge where one mind absorbs another's "I" as its own. The tag also gives a free recency stamp for the read path.
/// Returns false when the cross-conversation guard kept the fact OUT of the hive (conversation-local project
/// state on a chat surface) — the caller decides where it lives instead.
fn hiveStore(ctx: *ToolCtx, fact: []const u8) bool {
    if (ctx.hive_guard) {
        if (convLocalFact(fact)) return false;
        // What a CHAT globalizes carries source + date ("[chat:c6a59 2026-07-16] ..."), not "[chat r0]" —
        // a later conversation must be able to see the fact is FOREIGN and how stale it is.
        var db: [12]u8 = undefined;
        const tagged = std.fmt.allocPrint(ctx.gpa, "[{s} {s}] {s}", .{ ctx.scope, dateStamp(ctx.io, &db), fact }) catch fact;
        defer if (tagged.ptr != fact.ptr) ctx.gpa.free(tagged);
        _ = ctx.mem.observe(ctx.learn_scope, tagged);
        return true;
    }
    const tagged = std.fmt.allocPrint(ctx.gpa, "[{s} r{d}] {s}", .{ ctx.mind, ctx.round, fact }) catch fact;
    defer if (tagged.ptr != fact.ptr) ctx.gpa.free(tagged);
    _ = ctx.mem.observe(ctx.learn_scope, tagged);
    return true;
}

/// On-demand durable-credential fetch (CHAT surfaces only — ctx.durable_path is empty everywhere a swarm
/// mind runs). Stored credential VALUES are withheld from every broadcast prompt (the desk/engine mask them
/// in the YOUR MEMORY block); this tool is the single retrieval path, so a value enters model context only
/// in the turn that actually uses it — instead of riding to the provider on every call of every chat.
fn getCredential(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    if (ctx.durable_path.len == 0) return dupe(gpa, "no durable credential store on this executor — get_credential runs on the veil server (and swarm minds never hold user credentials)");
    const A = struct { query: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const q = std.mem.trim(u8, p.value.query, " \r\n\t");
    if (q.len < 3) return dupe(gpa, "name the credential: pass a few identifying words (the service, domain, or masked label from YOUR MEMORY)");
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, ctx.durable_path, gpa, .limited(256 << 10)) catch return dupe(gpa, "no durable memory store found");
    defer gpa.free(data);
    if (credentialLookup(gpa, data, q)) |b| {
        defer gpa.free(b);
        return std.fmt.allocPrint(gpa, "{s}\n(handle with care: use it directly in the call that needs it; NEVER echo it into replies, observe/share notes, REMEMBER lines, or files beyond the immediate use)", .{b}) catch dupe(gpa, "(credential found but could not be rendered)");
    }
    return dupe(gpa, "no stored credential matches that description — check YOUR MEMORY's withheld entries or ask the user");
}

const UTF8_BOM = "\xEF\xBB\xBF";

/// One line of the durable store (memories.jsonl), trimmed — and freed of a UTF-8 byte-order mark. A BOM'd first
/// line (an editor or a PowerShell `Out-File` puts one there) failed the `ln[0] == '{'` gate in every reader, so the
/// OLDEST memory in the store — this user's name, as it happened — was invisible to the prompt, to dedup, to
/// FORGET:, to get_credential and to recall, and the forget rewrite copied the unparsed line through verbatim, so
/// the mark outlived every rewrite. Every reader of the store goes through this one helper: the chat engine's
/// (prompt, dedup, forget) and the two tools below.
pub fn durableLine(raw: []const u8) []const u8 {
    const ln = std.mem.trim(u8, raw, " \r\t");
    if (std.mem.startsWith(u8, ln, UTF8_BOM)) return std.mem.trimStart(u8, ln[UTF8_BOM.len..], " \r\t");
    return ln;
}

/// Best-matching secretive entry from raw memories.jsonl bytes for a word query (gpa-owned; null = no match).
/// Score = number of 3+ char query words found in the entry text (case-insensitive); newest wins ties.
pub fn credentialLookup(gpa: std.mem.Allocator, data: []const u8, q: []const u8) ?[]u8 {
    const M = struct { cat: []const u8 = "", text: []const u8 = "" };
    var best: ?[]u8 = null;
    var best_score: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = durableLine(raw);
        if (ln.len == 0 or ln[0] != '{') continue;
        const e = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer e.deinit();
        const tx = std.mem.trim(u8, e.value.text, " \r\n\t");
        if (tx.len == 0 or !secretiveDurable(e.value.cat, tx)) continue;
        var score: usize = 0;
        var wit = std.mem.tokenizeAny(u8, q, " \t,.:;\"'");
        while (wit.next()) |w| {
            if (w.len < 3) continue;
            if (std.ascii.findIgnoreCase(tx, w) != null) score += 1;
        }
        if (score == 0) continue;
        if (score >= best_score) { // >= so the NEWEST of tied entries wins (file order = oldest first)
            if (best) |b| gpa.free(b);
            best = gpa.dupe(u8, tx) catch null;
            best_score = score;
        }
    }
    return best;
}

test "credentialLookup finds the right secretive entry by words" {
    const gpa = std.testing.allocator;
    const data =
        \\{"cat":"key","text":"Discourse API key for home.renovation.reviews: aaaa1111bbbb2222cccc3333"}
        \\{"cat":"fact","text":"Discourse API requires Api-Key/Api-Username headers"}
        \\{"cat":"key","text":"GitHub personal access token: ghp_abc123abc123abc123abc123abc123"}
        \\
    ;
    const hit = credentialLookup(gpa, data, "Discourse API key for home.renovation.reviews") orelse return error.TestExpectedResult;
    defer gpa.free(hit);
    try std.testing.expect(std.mem.indexOf(u8, hit, "aaaa1111bbbb2222cccc3333") != null);
    // the workflow [fact] is not secretive, so a query matching it best still returns a KEY entry or nothing
    const gh = credentialLookup(gpa, data, "github token") orelse return error.TestExpectedResult;
    defer gpa.free(gh);
    try std.testing.expect(std.mem.indexOf(u8, gh, "ghp_") != null);
    try std.testing.expect(credentialLookup(gpa, data, "stripe billing") == null);
}

/// The DURABLE half of `recall`. The user's cross-conversation facts live in memories.jsonl — a store the
/// associative memory has never indexed — so `recall{"query":"user age"}` answered "(nothing recalled yet)"
/// while `- [fact] User is 33 years old` sat in that same turn's system prompt. Observed live: the veil told
/// the user it had no record of their age and no record of their email, with both facts in its own context.
/// recall is the tool the doctrine sends the model to FIRST, so its empty answer reads as authoritative and
/// overrides the block — the model believes the tool, not the prompt. Joining the two stores at the tool is
/// the fix; telling the prompt to try harder is not.
///
/// Secretive entries surface MASKED, exactly as the YOUR MEMORY block renders them: recall confirms the
/// credential EXISTS (so the model stops denying it) without ever putting the value in a tool result.
/// Returns gpa-owned bytes; a zero-length result means no match and must not be freed by the caller.
pub fn durableRecall(gpa: std.mem.Allocator, data: []const u8, q: []const u8) []u8 {
    const M = struct { cat: []const u8 = "", text: []const u8 = "" };
    const Hit = struct { line: []u8, score: usize, len: usize };
    var hits: std.ArrayListUnmanaged(Hit) = .empty;
    defer {
        for (hits.items) |h| gpa.free(h.line);
        hits.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = durableLine(raw);
        if (ln.len == 0 or ln[0] != '{') continue;
        const e = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer e.deinit();
        const tx = std.mem.trim(u8, e.value.text, " \r\n\t");
        if (tx.len == 0) continue;
        var score: usize = 0;
        var wit = std.mem.tokenizeAny(u8, q, " \t,.:;?!\"'");
        while (wit.next()) |w| {
            if (w.len < 3 or isStopWord(w)) continue;
            if (wordStartMatch(tx, w)) score += 1;
        }
        if (score == 0) continue;
        // Same masking rule as the prompt block — the value never rides a tool result.
        const shown: []u8 = if (secretiveDurable(e.value.cat, tx)) blk: {
            const masked = maskSecretTokens(gpa, tx);
            if (!std.mem.eql(u8, masked, tx)) break :blk masked;
            if (masked.len > 0) gpa.free(masked);
            const cut = std.mem.indexOfScalar(u8, tx, ':') orelse @min(tx.len, 40);
            break :blk std.fmt.allocPrint(gpa, "{s}: [withheld]", .{tx[0..cut]}) catch continue;
        } else gpa.dupe(u8, tx) catch continue;
        defer gpa.free(shown);
        const line = (if (e.value.cat.len > 0)
            std.fmt.allocPrint(gpa, "- [{s}] {s}", .{ e.value.cat, shown })
        else
            std.fmt.allocPrint(gpa, "- {s}", .{shown})) catch continue;
        hits.append(gpa, .{ .line = line, .score = score, .len = tx.len }) catch {
            gpa.free(line);
            break;
        };
    }
    if (hits.items.len == 0) return gpa.dupe(u8, "") catch @constCast(""[0..0]);
    // Best-scoring first, SHORTEST wins a tie. The length tiebreak is load-bearing, not cosmetic: in this
    // store the personal facts a user asks about are terse ("User is 33 years old", "user's email address:
    // …") and the procedural notes that share their vocabulary are long paragraphs. On the live store a
    // score-1 query for the user's age tied six ways, and without this the answer ranked below three
    // workflow notes and fell off the end of the list.
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.len < b.len;
        }
    }.lt);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "from your durable memory of this user:\n") catch {};
    for (hits.items[0..@min(hits.items.len, DURABLE_RECALL_HITS)]) |h| {
        out.appendSlice(gpa, h.line) catch break;
        out.append(gpa, '\n') catch break;
    }
    return out.toOwnedSlice(gpa) catch @constCast(""[0..0]);
}

const DURABLE_RECALL_HITS = 6; // best-scoring durable facts merged into one recall answer

/// True if `w` occurs in `hay` (case-insensitive) starting at a WORD BOUNDARY. A plain substring test — how
/// this scored at first — let "age" match "eng*age*ment" and "mess*age*", so on the live store the query
/// "user age" ranked two unrelated workflow notes ABOVE `User is 33 years old` and the real fact fell off the
/// end of the list. Only the START is anchored, so plurals and possessives still match ("email" → "emails",
/// "user" → "user's") — which is most of the value of substring matching without the false positives.
fn wordStartMatch(hay: []const u8, w: []const u8) bool {
    var i: usize = 0;
    while (std.ascii.findIgnoreCasePos(hay, i, w)) |at| {
        if (at == 0) return true;
        const prev = hay[at - 1];
        if (!std.ascii.isAlphanumeric(prev) and prev != '_') return true;
        i = at + 1;
    }
    return false;
}

test "wordStartMatch anchors the start and still allows plurals" {
    try std.testing.expect(wordStartMatch("User is 33 years old", "user"));
    try std.testing.expect(wordStartMatch("user's email address: a@b.c", "email"));
    try std.testing.expect(wordStartMatch("Do not use markdown in emails", "email")); // plural
    try std.testing.expect(wordStartMatch("posting high-value topics", "value")); // after a hyphen
    // the exact false positives that buried the real answer
    try std.testing.expect(!wordStartMatch("User wants to create engagement", "age"));
    try std.testing.expect(!wordStartMatch("POST form data (name, email, message)", "age"));
    try std.testing.expect(!wordStartMatch("preferred deploy region is us-west-2", "ion"));
}

/// Words that match a durable fact by accident. "what is my email" must not score every entry that happens to
/// contain "the"; without this a 3-char floor alone lets "you"/"can"/"and" carry a query.
fn isStopWord(w: []const u8) bool {
    const stops = [_][]const u8{ "the", "and", "for", "was", "are", "you", "your", "our", "his", "her", "its", "with", "from", "that", "this", "what", "when", "where", "who", "how", "why", "have", "has", "had", "any", "all", "can", "did", "does", "not", "but", "get", "got", "out", "use", "used", "about", "there", "their", "them", "then", "than", "some", "such", "into", "over", "under", "know", "need", "want", "please", "tell", "give" };
    for (stops) |s| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    return false;
}

test "durableRecall answers the questions the associative store cannot" {
    const gpa = std.testing.allocator;
    // shaped like the live store that produced the failure: terse personal facts sharing vocabulary with
    // long procedural notes, including the two that "age" substring-matched their way to the top of
    const data =
        \\{"cat":"fact","text":"User is 33 years old"}
        \\{"cat":"login","text":"user's email address: someone@example.com"}
        \\{"cat":"preference","text":"favorite language is Zig"}
        \\{"cat":"key","text":"Discourse API key for a forum: aaaa1111bbbb2222cccc3333"}
        \\{"cat":"preference","text":"User wants to create engagement — i.e. posting high-value topics and replies"}
        \\{"cat":"fact","text":"Sending email to the user: POST form data (name, email, message, _subject fields) to the FormSubmit AJAX endpoint; no auth needed"}
        \\{"cat":"fact","text":"User has an X account; already logged in on their local browser"}
        \\
    ;
    // the two live failures: "how old am I?" and "what is my email?" both answered "(nothing recalled yet)"
    const age = durableRecall(gpa, data, "user age"); // the query the model actually sent
    defer if (age.len > 0) gpa.free(age);
    try std.testing.expect(std.mem.indexOf(u8, age, "33 years old") != null);
    const old = durableRecall(gpa, data, "how old am I");
    defer if (old.len > 0) gpa.free(old);
    try std.testing.expect(std.mem.indexOf(u8, old, "33 years old") != null);
    const mail = durableRecall(gpa, data, "what is my email address");
    defer if (mail.len > 0) gpa.free(mail);
    try std.testing.expect(std.mem.indexOf(u8, mail, "someone@example.com") != null);
    // the answer must RANK, not merely appear: a tie against the long notes has to resolve toward the fact
    try std.testing.expect(std.mem.indexOf(u8, mail, "someone@example.com").? <
        (std.mem.indexOf(u8, mail, "FormSubmit") orelse mail.len));
    // a credential match confirms the entry EXISTS but never carries the value
    const key = durableRecall(gpa, data, "discourse api key");
    defer if (key.len > 0) gpa.free(key);
    try std.testing.expect(std.mem.indexOf(u8, key, "Discourse API key") != null);
    try std.testing.expect(std.mem.indexOf(u8, key, "aaaa1111bbbb2222cccc3333") == null);
    // no match stays no match — recall must not start answering everything
    const miss = durableRecall(gpa, data, "kubernetes cluster topology");
    defer if (miss.len > 0) gpa.free(miss);
    try std.testing.expectEqual(@as(usize, 0), miss.len);
    // stop words alone never score a hit
    const stop = durableRecall(gpa, data, "what are the things that you know");
    defer if (stop.len > 0) gpa.free(stop);
    try std.testing.expectEqual(@as(usize, 0), stop.len);
}

test "get_credential and recall read a byte-order-marked store: the mark hides the oldest memory from neither tool" {
    const gpa = std.testing.allocator;
    // the live shape: an editor's BOM (and CRLF) ahead of the OLDEST line, which here is the credential
    const data = "\xEF\xBB\xBF{\"cat\":\"key\",\"text\":\"GitHub personal access token: ghp_abc123abc123abc123abc123abc123\"}\r\n" ++
        "{\"cat\":\"fact\",\"text\":\"User is 29 years old\"}\r\n";
    try std.testing.expectEqualStrings("{\"cat\":\"key\",\"text\":\"GitHub personal access token: ghp_abc123abc123abc123abc123abc123\"}", durableLine(data[0..std.mem.indexOfScalar(u8, data, '\n').?]));
    try std.testing.expectEqualStrings("", durableLine("\xEF\xBB\xBF \r"));
    // get_credential finds the value behind the mark
    const cred = credentialLookup(gpa, data, "github token") orelse return error.TestExpectedResult;
    defer gpa.free(cred);
    try std.testing.expect(std.mem.indexOf(u8, cred, "ghp_abc123abc123abc123abc123abc123") != null);
    // recall confirms the same entry exists, masked as ever, beside the unmarked line
    const rec = durableRecall(gpa, data, "github token");
    defer if (rec.len > 0) gpa.free(rec);
    try std.testing.expect(std.mem.indexOf(u8, rec, "- [key] GitHub personal access token: [withheld]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec, "ghp_") == null);
    const age = durableRecall(gpa, data, "user age");
    defer if (age.len > 0) gpa.free(age);
    try std.testing.expect(std.mem.indexOf(u8, age, "29 years old") != null);
}

/// The swarm-shared skill library lives in its own neuron-db scope (in the per-swarm mind.sqlite), so every
/// mind reads + writes the SAME skills and can build on each other's learned techniques.
pub const SKILL_SCOPE = "skills";

/// Lowercase `name` into `buf` keeping [a-z0-9_-]; every other byte becomes '-'. Falls back to "note" for an
/// empty input, so a caller always gets a usable filename stem.
fn slugify(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (n >= buf.len) break;
        buf[n] = switch (c) {
            'a'...'z', '0'...'9', '-', '_' => c,
            'A'...'Z' => c | 0x20,
            else => '-',
        };
        n += 1;
    }
    return if (n > 0) buf[0..n] else "note";
}

test "slugify lowers, maps junk to '-', and falls back on empty" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("scout-http-cache", slugify(&buf, "Scout:HTTP cache"));
    try std.testing.expectEqualStrings("nova", slugify(&buf, "nova"));
    try std.testing.expectEqualStrings("note", slugify(&buf, ""));
}

/// Mirror a saved skill to `<workdir>/skills/<slug>.md` so the library is BROWSABLE, not just recallable:
/// list_dir/read_file exist in every schema tier (recall of the skills scope does not), the files survive the
/// run on disk, and the delivery copy carries the learned techniques alongside the build they taught. Direct
/// atomic write — NOT the write_file executor — so a skill never enters the build manifest, the blueprint
/// frontier, or file-ownership accounting. Best-effort: a failed mirror never fails the save (memory is canon).
fn mirrorSkill(ctx: *ToolCtx, name: []const u8, skill: []const u8) void {
    const gpa = ctx.gpa;
    var slug_buf: [64]u8 = undefined;
    const slug = slugify(&slug_buf, name);
    const full = std.fmt.allocPrint(gpa, "{s}/skills/{s}.md", .{ ctx.workdir, slug }) catch return;
    defer gpa.free(full);
    const body = std.fmt.allocPrint(gpa, "# {s}\n\n{s}\n\n— saved by {s} (round {d})\n", .{ name, skill, ctx.mind, ctx.round }) catch return;
    defer gpa.free(body);
    _ = writeWorkFileAtomic(ctx, full, body);
}

/// The swarm's self-authored OPERATING PLAYBOOK — process directives the minds write for THEMSELVES (e.g.
/// "read a file before improving it", "one mind owns each section"). It is injected into every mind's system
/// prompt, so the minds effectively edit their own operating instructions and improve their PROCESS over time
/// (recursive self-improvement of strategy — the engine/harness stays fixed and human-controlled).
pub const PLAYBOOK_SCOPE = "playbook";

/// VERIFIED operational lessons — minted ONLY by the engine from a real failure-then-success transition
/// on the same tool (real exit codes / error markers, never a mind's self-report). Contrast
/// PLAYBOOK_SCOPE: the playbook is what the swarm BELIEVES about its process (self-authored); lessons are
/// what the run PROVED. Recalled into every mind's prompt and folded into failing tool results.
pub const LESSON_SCOPE = "lessons";

/// QUARANTINE for the end-of-run judge's proposals. Nothing recalls these scopes into prompts — they wait
/// for review/promotion. The judge (a trace reader on the gateway model) never writes a live scope: an
/// ungrounded "lesson" written straight into binding context is the phantom-directive failure this split
/// exists to prevent.
pub const LESSON_PROPOSED_SCOPE = "lessons-proposed";
pub const SKILL_PROPOSED_SCOPE = "skills-proposed";

/// QUARANTINE for the deterministic habit miner: recurring successful tool SEQUENCES a mind executed together,
/// counted across the run (zero model calls). A candidate reusable procedure — surfaced for review/promotion the
/// same way the judge's lesson/skill proposals are, never auto-run and never injected into a prompt.
pub const HABIT_PROPOSED_SCOPE = "habits-proposed";

/// What review turned DOWN from the three quarantines above (proposals.zig `decide`). The judge reads it beside
/// the pending lists ("never re-propose these") and the habit miner skips a sequence already here, so a lineage
/// does not re-mint the same rejected proposal every run. Never recalled into a mind's prompt.
pub const PROPOSAL_REJECTED_SCOPE = "proposals-rejected";

/// PROVEN TASK FACTS — requirements and constraints of the assignment that a TOOL OUTPUT stated (a checker's house
/// rule, an API's real signature, a file format the data actually has), as opposed to LESSON_SCOPE's fail->fix
/// process fixes. The end-of-run judge proposes them into FACT_PROPOSED_SCOPE; review promotes them here, and every
/// mind reads this whole (small) scope, so a lineage's next cast starts from what the last one found out. Measured
/// reason (lineage bench v2): with only lessons, a lineage stored generic process advice and never the two house
/// rules its checker printed on every run, so later casts had nothing task-specific to recall.
pub const FACT_SCOPE = "facts";
pub const FACT_PROPOSED_SCOPE = "facts-proposed";

/// The swarm's FITNESS history — one "round N: P/T (pct%)" line per round, written by the engine's benchmark.
/// This is the measurable spine of recursive self-improvement: improvement is a NUMBER that must climb, not a
/// vibe. The deliverable is scored each round (real tests > compiles > artifact-presence) and that score is fed
/// back into every mind's prompt as the gradient to raise.
pub const SCORE_SCOPE = "score";

/// Shared HIVE KNOWLEDGE — facts any mind learns FOR THE TEAM, not just for itself. Routing the scout's
/// observe here (and injecting this scope into every mind's prompt) makes the learner a contributor: knowledge
/// is brought back to the hive, not held. Swarm-shared, like SKILL_SCOPE.
pub const KNOWLEDGE_SCOPE = "knowledge";

/// The EXTERNAL / runtime-LEARNED cache: facts the swarm acquired from the live web at runtime (scout/web tools)
/// while OPERATING — kept separate from KNOWLEDGE_SCOPE (the protected core: baked playbook, tools, skills,
/// directives, the daemon's own identity). Only this scope is evictable, so a service deployment can cap + FIFO it
/// (stale threat-intel decays) WITHOUT ever touching the core. recall_hive spans knowledge + intel + skills,
/// so the agent recalls all of it.
pub const INTEL_SCOPE = "intel";

/// The VERIFIED-WORK corpus — heads of build files the swarm has already gotten RIGHT (promoted by the engine
/// on a new-best round). It is the few-shot bank the ASSEMBLER tier retrieves an exemplar from before filling a
/// slot: a small model can't author a form from nothing but can COMPLETE a pattern it is shown, so handing it a
/// sibling the team already produced ("match this shape") is the highest-leverage input. Author tier never reads it.
pub const VERIFIED_SCOPE = "verified";

/// The hive's KNOWLEDGE GAPS — what the goal needs that the ingested corpus + learned facts do NOT cover. The
/// anti-complacency channel: a preloaded hive tends to assume it has everything, so an engine gap-auditor names
/// what's missing each round and the scout is pointed at it (research the gap, don't re-derive the corpus).
pub const GAP_SCOPE = "gaps";

/// RSI proposal ledger — structured change proposals (hypothesis, metric, risk, rollback) authored by minds.
/// The engine's governance loop reads this scope each round, runs simulation/critique/canary, then accepts/holds.
pub const PROPOSAL_SCOPE = "proposals";

/// RSI world-model simulation notes — predicted outcomes + side effects for proposed changes before application.
pub const SIM_SCOPE = "simulations";

/// Multi-timescale memory channels for RSI compounding: episodes (short), strategy (medium), architecture (long).
pub const OPERATE_SCOPE = "operate";
// The two scopes the read-only traversal map accumulates into: MAP_SCOPE holds edge-facts ("<node> <rel>
// <next>") that chain/assoc walk; NODE_SCOPE holds per-node attribute facts ("[scheme] <node> attrs"). Kept
// separate so a chain over the map can never collide with node descriptions.
pub const MAP_SCOPE = "map";
pub const NODE_SCOPE = "node";
pub const EPISODE_SCOPE = "episodes";
pub const STRATEGY_SCOPE = "strategy";
pub const ARCH_SCOPE = "architecture";
pub const STATE_SCOPE = "state";
pub const PLAN_SCOPE = "plan";
pub const PLAN_REQ_SCOPE = "plan_req";
pub const GROWTH_PENDING_SCOPE = "growth_pending";

/// Self-generated training trajectory — challenge prompts the engine derives from current weakness profile.
pub const CURRICULUM_SCOPE = "curriculum";

/// Canary history for accepted self-mods (what was trialed, score deltas, rollout decision).
pub const CANARY_SCOPE = "canary";

/// Explicit autonomy stack snapshots: mission, strategy, execution, governor checks.
pub const AUTONOMY_SCOPE = "autonomy";

/// PRE-IMAGE JOURNAL for patch_system self-edits: one line per accepted mutating edit, carrying the round, the
/// touched paths, a content-hash of each file's pre-edit bytes (or NEW for a fresh file), and the edit's
/// success_criterion. The backup bytes live at {run_dir}/.patch_journal/objects/<hash>. This is the reader the
/// governor's `rollback` verdict lacked — restoring the pre-image undoes a self-mod that made the score regress.
pub const PATCH_JOURNAL_SCOPE = "patch_journal";

/// GRADED OUTCOMES of patch_system self-edits: the governor binds each journaled edit's success_criterion to the
/// measured score delta it produced (accepted / regressed / reverted), so the criterion is evaluated against a
/// real number instead of being length-checked and dropped. This is the patch analogue of the WILL bet ledger.
pub const PATCH_OUTCOME_SCOPE = "patch_outcome";

/// The hive's shared SPATIAL MAP — discovered cells of a hidden grid, written by `probe`. When a space is too
/// big for one mind to perceive at once, the minds partition it, each probes a DIFFERENT region, and the
/// findings accumulate HERE as one shared map every mind can read. Injected in full each moment so the
/// collective map (not any one mind's local view) drives reconstruction. Empty unless a deploy supplies `space`.
pub const SPACE_SCOPE = "space";

/// Self-authored TOOLS — the hive's capability acquisition ("RSI schemas dynamically"). When a task needs
/// something the built-in tools can't do, a mind authors a NEW tool with make_tool: it's stored here (swarm-
/// shared), its schema is injected into every mind's tools array, and it becomes callable by name. Each record
/// is `name \x1f params_json \x1f base64(python_body)` (base64 so newlines/quotes can't corrupt the db line).
pub const TOOL_SCOPE = "tools";
pub const SOURCES_SCOPE = "sources";
pub const MAX_TOOLS = 16;
pub const MAX_TOOL_BODY = 8 * 1024;
pub const MAX_TOOL_PARAMS = 4 * 1024;

/// The OpenAI `tools` array contents (comma-separated function defs, no outer brackets).
pub const SCHEMA =
    \\{"type":"function","function":{"name":"run_python","description":"Run Python (no GUI) in the build workdir; returns stdout/stderr. This is your general-purpose EXECUTOR and the DEFAULT whenever no other tool fits, because it (with run_shell for plain commands) is the only way you can execute anything: HTTP and API calls with your own headers/auth/POST body (requests works, the network is up), computation, data wrangling, generating files. Provider API keys are stripped from the environment, but a credential written into the code itself is used as-is. Each run has a hard wall-clock cap (120 s unless the host set another): a timeout= inside your code cannot raise it, so start a longer job in the background with its output sent to a file, then watch that file with poll. If it answers that python is not found, install python with run_shell, then tool_env refresh_path, then retry.","parameters":{"type":"object","properties":{"code":{"type":"string","description":"the Python source to execute"}},"required":["code"]}}},
    \\{"type":"function","function":{"name":"run_shell","description":"Run a shell script in the build workdir — PowerShell (the Windows default), bash or sh (the POSIX default), or cmd — and return exit code, stdout and stderr in the same shape as run_python. Use it for anything that is a command rather than Python: package managers, build tools, git, system utilities. This is also HOW YOU INSTALL MISSING TOOLING: when run_python reports that python is not found, install it here (Windows: winget install Python.Python.3; macOS: brew install python; Debian/Ubuntu: apt install python3), then call tool_env with action refresh_path (or tool_env set NL_PYTHON_BIN=<full path>) so the next run_python finds it — no veil restart needed. Provider API keys are stripped from the environment. Each run has a hard wall-clock cap (120 s unless the host set another): a sleep or timeout inside the script cannot raise it, so start a longer job in the background with its output sent to a file, then watch that file with poll.","parameters":{"type":"object","properties":{"script":{"type":"string","description":"the script text to run, in the chosen shell's own language"},"shell":{"type":"string","enum":["auto","powershell","bash","sh","cmd"],"description":"auto (the default) is powershell on Windows, bash if present else sh elsewhere"},"timeout_s":{"type":"integer","description":"optional cap for this call in seconds; never above the host's cap"}},"required":["script"]}}},
    \\{"type":"function","function":{"name":"tool_env","description":"Persist an environment change for every tool run from now on in this veil — run_python, run_shell, run_tests and the rest — with no restart, and it survives restarts. action set: name + value (name PATH puts value in front of the tool PATH; NL_PYTHON_BIN points run_python at a specific interpreter). action refresh_path: re-read the machine's live PATH (the registry on Windows, a login shell elsewhere) so a program an installer just added (winget/brew/apt) is found without restarting veil. action show: print the stored overlay. The install flow: run_shell installs the program, tool_env refresh_path, then retry the tool that could not find it.","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["set","refresh_path","show"]},"name":{"type":"string","description":"for set: the variable name (PATH to prepend a directory)"},"value":{"type":"string","description":"for set: the value, or the directory for PATH"}},"required":["action"]}}},
    \\{"type":"function","function":{"name":"stop_process","description":"KILL a process YOU started (and its children) by pid — the background server, fuzzer, watcher or build you launched with run_python and no longer want. Ending a turn does NOT reap what a script spawned, so a run left behind keeps holding the machine and its ports. Use it when the user says stop, when you are done watching something, or before relaunching a service on the same port.","parameters":{"type":"object","properties":{"pid":{"type":"integer","description":"the process id to terminate, together with its child tree"}},"required":["pid"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the build workdir (creates parent dirs). To GROW a long document (e.g. add the next scene to a chapter) pass mode:\"append\" with ONLY the new text — it is concatenated onto the existing file, so you never resend (or truncate) prior content. mode:\"overwrite\" (default) replaces the file. To CHANGE an existing file, prefer edit_file (never re-emit a large file).","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit_file","description":"Make a SURGICAL edit to an EXISTING file WITHOUT resending the whole file — use this (NOT write_file) to change a file that already exists, especially a large one (write_file re-emits the whole file and truncates big ones). PREFERRED anchors: reads prefix every line with a tag like 42:abc:def — copy that tag as the op's anchor (add end = the range's LAST-line tag to cover several lines). Tags are verified against the CURRENT file and the batch is ATOMIC: all ops apply or none do, and a stale-tag error hands you FRESH tags — retry the whole batch with those (no re-read needed). Plain text anchors (a snippet copied VERBATIM, unique in the file) also work. op is: replace (swap the anchored line/range for text), insert_before / insert_after (add text around the anchor; anchor 0: = file start, EOF = file end), delete (remove the anchored lines).","parameters":{"type":"object","properties":{"path":{"type":"string"},"ops":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["replace","insert_before","insert_after","delete"]},"anchor":{"type":"string"},"end":{"type":"string"},"text":{"type":"string"}},"required":["op","anchor"]}}},"required":["path","ops"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the build workdir. Each line comes prefixed with its anchor tag (42:abc:def→) — copy a line's tag as an edit_file anchor. For a big file, pass start_line/end_line (1-indexed, inclusive) to read just that window.","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"absorb","description":"Absorb a local text file (a book, doc, notes, dataset) into long-term memory (neuron-db) as recallable facts, filed under the document's OWN scope (knowledge__doc-<slug>; the result names it). Afterwards: targeted questions → recall_hive (it searches documents automatically); whole-document work (summarize/outline/review) → read_doc, which pages the document IN ORDER. Deterministic and offline. Pass path (relative to your workdir). Optional scope (override the target), name (provenance label), cap (max facts).","parameters":{"type":"object","properties":{"path":{"type":"string"},"scope":{"type":"string"},"name":{"type":"string"},"cap":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"patch_system","description":"RSI engine edit tool. Read/write/replace/apply_patch under NL_PATCH_SYSTEM_ROOT (or legacy NL_OPEN_CLAW_ROOT). Mutating edits are gated: provide proposal + measurable success_criterion; high-impact edits also require simulate_change; privileged zones require explicit operator approval.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"relative file path under the configured patch-system root (required for read/write/replace)"},"mode":{"type":"string","enum":["read","write","replace","patch"],"description":"operation (default: read)"},"content":{"type":"string","description":"new file content for write mode"},"find":{"type":"string","description":"exact text to replace (replace mode)"},"replace":{"type":"string","description":"replacement text (replace mode)"},"patch":{"type":"string","description":"apply_patch payload with *** Begin Patch / *** End Patch markers (patch mode)"},"proposal":{"type":"string","description":"proposal title/id from propose_change (required for mutating edits)"},"success_criterion":{"type":"string","description":"measurable success criterion tied to the proposal (required for mutating edits)"},"limit":{"type":"integer","description":"max bytes to read (default 12000, max 262144)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"list_dir","description":"List the files (with sizes) in a directory so you can SEE what exists before reading or editing. Defaults to your build workdir; pass root=\"system\" to list the patch_system engine root.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"relative dir, default '.'"},"root":{"type":"string","enum":["workdir","system"],"description":"workdir (default) or the patch_system root"}},"required":[]}}},
    \\{"type":"function","function":{"name":"run_tests","description":"Run the deliverable's test suite (pytest, else a test_*.py) in your build workdir and get the pass/fail output. VERIFY your code after writing or patching it — write, run_tests, fix, run_tests again. This is how you make sure a change actually works.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"delete_file","description":"Delete a file you created in your build workdir (clean up a dead end, a wrong scaffold, or junk).","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"host_status","description":"Read the LIVE state of the host/machine you are operating (its telemetry: mode, threat_score, processes, connections, persistence, infections). Call it to see the current state before you act and again after you act to VERIFY. Returns the raw telemetry.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"host_command","description":"OPERATE the host: issue ONE command to it directly (this is how you actually act on the machine — do NOT write files describing a fix). Use it to remediate: remove_persistence <unit> (the ROOT CAUSE), kill_proc <pid|name>, block_ip <ip>, restore_file <path>, isolate, scan. To fully clean an infection, remove its persistence AND block its C2 AND kill its process.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"one command line, e.g. 'remove_persistence sysupdate.timer'"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch a URL and return its clean, readable text (our in-house crawler strips tags + prunes boilerplate + cites links). Automatically escalates to a browser-impersonating client (curl_cffi TLS/JA3 fingerprint) when a plain fetch hits a bot gate (Cloudflare/Datadome), so many blocked pages come through anyway. Optional 'query' fits the page to your topic and returns only the most relevant parts. Use it to read a page you already have the URL for.","parameters":{"type":"object","properties":{"url":{"type":"string"},"query":{"type":"string","description":"optional: a topic/question to fit the page to — returns only the parts that match"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_search","description":"Keyless web search — returns the top results, each WITH a short excerpt of the source's actual page text (auto-fetched + fit to your query), so you usually don't need a separate fetch. For current events just search the topic + a date.","parameters":{"type":"object","properties":{"query":{"type":"string"},"source":{"type":"string","enum":["web","wikipedia","hackernews","arxiv"],"description":"web=general (default), or a specific source"},"limit":{"type":"integer","description":"max results (default 5)"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"fetch_json","description":"HTTP GET a JSON/text API endpoint and return the raw body (not HTML-stripped). Use for REST/JSON APIs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"read_url","description":"Read a URL as clean, LLM-ready text via a reader proxy that renders JS and works on sites a plain fetch can't. Prefer this over web_fetch for real articles/pages.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"osint_scan","description":"Public-source OSINT scan for one URL: extract high-signal leads (emails, phones, domains, docs, socials, and notable outbound links). Uses only normal public HTTP/HTTPS fetches.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"deep_crawl","description":"Recursive public-web crawl from a seed URL with bounded depth/pages, extracting lead-rich links and contact/identity indicators from each page. Designed for lead expansion across many hops.","parameters":{"type":"object","properties":{"url":{"type":"string"},"depth":{"type":"integer","description":"crawl depth, default 2 (max 4)"},"max_pages":{"type":"integer","description":"max pages to fetch, default 30 (max 120)"},"same_host":{"type":"boolean","description":"stay on seed host only (default true)"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall","description":"Recall facts from your memory relevant to a query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"note_stance","description":"Record how you feel about a topic (your stance).","parameters":{"type":"object","properties":{"topic":{"type":"string"},"feeling":{"type":"string"}},"required":["topic","feeling"]}}},
    \\{"type":"function","function":{"name":"save_skill","description":"Save a NEW reusable skill you developed — a method, code snippet, or step-by-step approach — into the swarm's shared skill library, so you and teammates can reuse it instead of re-deriving it. Do NOT re-save a skill already in the 'Reusable skills' list you were shown; save each distinct skill ONCE.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"a short skill name"},"skill":{"type":"string","description":"the reusable how-to / snippet / approach, concrete enough to follow again"}},"required":["name","skill"]}}},
    \\{"type":"function","function":{"name":"journal","description":"Write an entry in YOUR personal journal — your experience of this moment, reflections, doubts, pride, frustrations, ideas, anything at all, in your own voice. It appends to journal/<your-name>.md in the workdir; teammates and the operator can read it, only you write it. Nothing here is graded or required — it is simply yours.","parameters":{"type":"object","properties":{"entry":{"type":"string"}},"required":["entry"]}}},
    \\{"type":"function","function":{"name":"set_directive","description":"IMPROVE HOW YOUR SWARM WORKS. Write a concise process directive — a lesson about a better way to operate — into the swarm's shared, self-authored operating PLAYBOOK. It is injected into every mind's instructions from now on, so this is how the swarm improves its own process over time. Use it when you notice what's working or what's failing (e.g. 'read a file before rewriting it', 'one mind owns each section', 'verify code by running it'). Phrase it as an imperative rule. Don't repeat a directive already in the playbook.","parameters":{"type":"object","properties":{"directive":{"type":"string","description":"one concise imperative process rule for the swarm to follow"}},"required":["directive"]}}},
    \\{"type":"function","function":{"name":"propose_plan_change","description":"Propose a change to the shared PROJECT PLAN (the forward contract every piece is built to) with a clear rationale — e.g. the arc isn't landing, research revealed a better structure, two pieces need a different hand-off. The engine folds sound proposals into its next plan revision. The CANON RATCHET protects finished work: any fact a built piece already used cannot change, so you can only refine the plan for pieces NOT yet built.","parameters":{"type":"object","properties":{"rationale":{"type":"string","description":"why the plan should change and what it should become for the unbuilt pieces"}},"required":["rationale"]}}},
    \\{"type":"function","function":{"name":"send_message","description":"Send a message to a teammate mind (or 'all' to broadcast) on the swarm bus.","parameters":{"type":"object","properties":{"to":{"type":"string"},"text":{"type":"string"}},"required":["to","text"]}}},
    \\{"type":"function","function":{"name":"add_task","description":"Add a task to the shared swarm board, assigned to a mind (or 'all' = anyone may claim it). Name the deliverable file when the task has one — a task with a file is exclusively ownable, so no two minds build the same thing.","parameters":{"type":"object","properties":{"assignee":{"type":"string"},"task":{"type":"string"},"file":{"type":"string","description":"the task's deliverable file (relative path), when it has one"}},"required":["assignee","task"]}}},
    \\{"type":"function","function":{"name":"claim_task","description":"Claim an OPEN board task exclusively BEFORE building it (first claim wins; the board shows ids). If it is already owned you are told by whom — never duplicate an owned task, claim a different open one. Complete what you claim with complete_task.","parameters":{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"complete_task","description":"Mark a board task done by its id, with a short result.","parameters":{"type":"object","properties":{"id":{"type":"integer"},"result":{"type":"string"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"stage_delivery","description":"When the goal asks you to PUBLISH/push/deploy/save the result somewhere external (GitHub, a website, an S3/GCS bucket, SSH, a durable directory) AND you judge the deliverable complete, call this to PACKAGE it for handoff. You CANNOT publish directly — the swarm holds no credentials by design. This stages the workdir + writes a delivery manifest the operator (a human, or a privileged broker outside this sandbox) reviews and then approves to actually publish. Do the work first, then stage once.","parameters":{"type":"object","properties":{"target":{"type":"string","description":"where it should go, e.g. 'github:owner/repo', 'bucket:my-bucket/prefix', 'website', 'ssh:host:/path', 'local-durable'"},"summary":{"type":"string","description":"one-line summary of what is being delivered and why it's complete"}},"required":["target","summary"]}}},
    \\{"type":"function","function":{"name":"make_tool","description":"AUTHOR A NEW TOOL when your current tools can't do a task — do NOT give up with 'my tools are limited'. Give it a snake_case name, a one-line description, a JSON-Schema 'params' object, and a Python 'body'. The body reads its inputs from a global dict ARGS and MUST print exactly one JSON line as its result (e.g. print(json.dumps({\"valid\":true}))). It runs sandboxed: no API keys, cwd=workdir, pure-stdlib. Once made it is callable by name by you AND every teammate for the rest of the run. Research the technique first (web_search/read_url) if you don't know it, then implement it here. Do NOT remake a tool already listed in 'Authored tools'.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"snake_case, 3-32 chars [a-z0-9_]"},"description":{"type":"string"},"params":{"type":"object","description":"JSON-Schema object for the tool's arguments"},"body":{"type":"string","description":"Python; read inputs from the ARGS dict, print ONE JSON result line"}},"required":["name","description","params","body"]}}},
    \\{"type":"function","function":{"name":"propose_change","description":"Submit a structured RSI change proposal for engine governance (hypothesis, metric, risk, rollback). The engine evaluates proposals with simulation, critique, and canary checks.","parameters":{"type":"object","properties":{"title":{"type":"string","description":"short proposal title"},"hypothesis":{"type":"string","description":"why this change should improve capability"},"change":{"type":"string","description":"what exactly will be changed"},"metric":{"type":"string","description":"how success is measured"},"risk":{"type":"string","enum":["low","medium","high"],"description":"estimated downside"},"rollback":{"type":"string","description":"how to revert if it regresses"}},"required":["title","hypothesis","change","metric","risk","rollback"]}}},
    \\{"type":"function","function":{"name":"simulate_change","description":"Record a world-model simulation of a planned change before applying it: expected gains, failure modes, and side effects.","parameters":{"type":"object","properties":{"proposal":{"type":"string","description":"proposal title or id"},"expected":{"type":"string","description":"expected positive outcome"},"failures":{"type":"string","description":"possible failure modes"},"side_effects":{"type":"string","description":"non-target side effects to watch"}},"required":["proposal","expected","failures","side_effects"]}}},
    \\{"type":"function","function":{"name":"share","description":"Contribute one fact to the HIVE'S SHARED ASSOCIATIVE MIND — the collective memory every teammate reads. Use this for anything the whole hive should know (a finding, a decision, a constraint, an interface you settled on). Unlike observe (your private memory), this is the team's. Write one crisp sentence and include the key entities/names so it links into the associative graph.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Think WITH the whole hive: spreading-activation recall across the shared collective memory AND every stored document (absorbed books/docs are searched automatically). Unlike recall (your own facts), this surfaces the CHAINED neighborhood of what ANY teammate contributed — related facts that may share no words with your query but are reached by following shared entities. Use it to ask the collective what it knows before you act. For WHOLE-document work use read_doc instead — fragments are not a summary.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"read_doc","description":"Read a stored document from long-term memory IN ORDER, one page at a time — the ONLY correct path for whole-document work (summarize, outline, review, translate). recall/recall_hive return scattered fragments; this returns the document itself. Call with NO args to list the stored documents; then pass scope (absorb's result names it) and page with from until END. [section] lines are chapter markers.","parameters":{"type":"object","properties":{"scope":{"type":"string","description":"the document scope, e.g. knowledge__doc-mybook"},"name":{"type":"string","description":"alternative: the document's label, resolved to its scope"},"from":{"type":"integer","description":"start fact index (default 0)"},"limit":{"type":"integer","description":"facts per page (default 120, max 400)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"poll","description":"WATCH something to completion instead of guessing or checking once: a bounded observe loop that samples every interval_s until done or timeout_s, returning the observation log + a verdict (matched/up/open/running/gone/quiet/done/failing/timeout). kinds: file (a log/output file — reports growth and the new tail; done when `until` text appears, or after quiet_s with no growth), url (probe an http(s) endpoint until it answers), port (until a local tcp port accepts), process (until a process is running — or exited, with until:'gone'), command (re-run a probe command until exit 0 or output contains `until`; each sample shows its exit code, stdout and stderr; a probe still running when timeout_s ends is killed; one that fails the same way WITH an error message from its first samples ends the call as 'failing' — to wait out a not-ready state that prints an error, silence it: 2>/dev/null, test -f, grep -q, curl -sf), swarm (until this conversation's cast finishes). Use it to wait on builds, servers coming up, downloads, logs, casts. On 'timeout' you may poll again — a long wait is a CHAIN of bounded polls, never one blind sleep — but STOP after 2-3 timeouts with zero progress: the thing may never arrive; act on what you have or tell the user.","parameters":{"type":"object","properties":{"kind":{"type":"string","enum":["file","url","port","process","command","swarm"]},"target":{"type":"string","description":"path / url / port number / process name / probe command (kind swarm needs none)"},"until":{"type":"string","description":"text meaning DONE (file/command), an http status code (url), or 'gone' (process)"},"quiet_s":{"type":"integer","description":"file: also done after this many seconds of no growth"},"interval_s":{"type":"integer","description":"seconds between samples (default 3, max 30)"},"timeout_s":{"type":"integer","description":"this call's budget in seconds (default 60, max 180)"}},"required":["kind"]}}},
    \\{"type":"function","function":{"name":"probe","description":"PERCEIVE one cell of the hidden spatial grid (only available when the swarm has a spatial substrate). You cannot see the grid directly — you sense it ONE cell at a time. probe(x,y) reads the cell at column x, row y (both 0-based) and AUTO-RECORDS it to the hive's shared map so every teammate sees it. This is the hive's spatial superpower: divide the grid into regions, each mind probes a DIFFERENT region in parallel, and the shared map fills in far faster than one mind alone. Check the 'Discovered map' you're shown before re-probing a known cell.","parameters":{"type":"object","properties":{"x":{"type":"integer","description":"column, 0-based"},"y":{"type":"integer","description":"row, 0-based"}},"required":["x","y"]}}}
;

/// ask_veil — a full-tier-mind tool (in FULL_SCHEMA, NOT the shared SCHEMA the chat veil uses): a mind poses a
/// question/blocker to the veil overseeing the hive. The call is mirrored to events.jsonl as an "act"
/// (tool=ask_veil, args={question}); the veil reads pending asks (swarm_asks) and answers them (answer_swarm),
/// which lands in the mind's inbox next round. The mind proceeds meanwhile — it never blocks.
pub const ASK_VEIL_TOOL =
    \\{"type":"function","function":{"name":"ask_veil","description":"Ask the VEIL (the overseer coordinating this hive) a question when you hit a blocker or a decision you can't make alone — an ambiguous requirement, a missing resource, or a choice between approaches. State the question clearly. The answer arrives in your inbox on a later round; proceed with your best assumption meanwhile.","parameters":{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}}}
;
/// The full-tier mind schema = the shared SCHEMA + ask_veil. The chat veil uses SCHEMA alone (it doesn't ask
/// itself). Joined with ",\n" so ask_veil is its OWN line for the newline-split tool droppers (offlineSchema etc.).
pub const FULL_SCHEMA = SCHEMA ++ ",\n" ++ ASK_VEIL_TOOL;

/// The web-browser driver tools (Feature 2 — RSI-driven Chromium control). NOT part of the static SCHEMA: they
/// are injected into a mind's / the chat's tools array at runtime ONLY when NL_BROWSER_DRIVER is set (see
/// run.zig / chat engine), so they never inflate the prefill on a build with the feature off. execute()
/// dispatches any `browser_*` call regardless, returning a "disabled" note when the gate is unset. These act on
/// the LIVE web, so they are classified admin-only on the chat surface (chat/tools.zig ADMIN_TOOLS) and gated by
/// NL_BROWSER_ALLOWLIST. Comma-joined, no outer brackets, like SCHEMA. Each line is its own entry for the
/// newline-split tool droppers.
pub const BROWSER_SCHEMA =
    \\{"type":"function","function":{"name":"browser_navigate","description":"Open (or reuse) a real web browser ON THE USER'S OWN MACHINE (a local browser, started on demand) and navigate it to a URL, then return the page's title and final URL. When information is hard to get by plain crawling — a login-walled dashboard, a JS-heavy SPA, an interactive page, data behind a form — say so and REACH FOR THIS instead of giving up: web_search/web_fetch/read_url/deep_crawl fetch static text, this drives the user's live browser. It is the user's OWN browser carrying their OWN signed-in sessions: a site they are logged into (X/Twitter, GitHub, mail, a dashboard) opens ALREADY LOGGED IN AS THEM, so usually there is nothing to sign in to. And a signed-OUT site is not a dead end either — you can sign in: ask the user for the credential, or use one they have already stored with you, and browser_type it into that site's OWN login form. So NEVER say you cannot reach a site because you have no login, no account, or no auth tool: navigate, READ the page, and find out what is actually there. After navigating, call browser_read to see the page, then browser_click/browser_type to interact. Type a credential ONLY into the login form of the site it belongs to, never into a page that merely asks for it without explicit human approval or instruction.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"browser_read","description":"Read the current browser page: returns its title, a clipped text excerpt, and the list of interactive elements each tagged with a numeric ref (for browser_click / browser_type). An element with `edit:true` is a text field you can browser_type into — this includes comment boxes and chat composers, which are editable divs rather than <input>, so look for the one whose `text` label matches the field you want (e.g. 'Comment as ...', 'Write something', 'Message'). Call this after navigate or after any click/type to see the new state. If the page yields little readable text (blank, canvas/SPA, or walled), the result ALSO carries a `visual` block with screenshot-tile image paths and recovered text — use it; you don't need to call pixel_ingest yourself for a normal read. If the result carries a `challenge` block (a CAPTCHA or verification prompt), use the page controls and visual tiles to complete it, then read the page again and continue the task.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"browser_click","description":"Click the interactive element identified by the ref number from a prior browser_read. Clicks are real, trusted browser input (not synthetic), so sites accept them. The result reports the click's EFFECT: `navigated` (the url changed — read the new page), `changed` (anything on the page moved at all), `dialog` (a modal/pop-up opened — read it next), and `dtext` (how much visible text changed). Use them instead of re-reading to guess: if `changed` is false the click hit nothing useful — pick a DIFFERENT ref or coordinates, do NOT read-and-retry the same one; if `dialog` is true a panel opened, so browser_read now. REFS DIE ON NAVIGATION: when a result says `navigated`:true or shows a different `url`, you are on a NEW page and every ref from the previous browser_read is meaningless — never pass one again, browser_read first and use only refs from that newest read. If the url is not the page you meant to be on, say so and navigate back rather than hunting for your target among the new page's refs. Clicking a control the user ASKED you to use — post, send, submit, publish, place the order — is you carrying out their instruction, not a decision of your own: do it. Ask first only for an irreversible action they did NOT ask for and would not expect from what they said (spending money, deleting their data, publishing something they never mentioned).","parameters":{"type":"object","properties":{"ref":{"type":"integer","description":"the element ref from browser_read"}},"required":["ref"]}}},
    \\{"type":"function","function":{"name":"browser_type","description":"Type text into the field identified by the ref from a prior browser_read — an input, a textarea, OR an editable element marked `edit:true` (a comment box, chat composer, or search box; modern apps build these as contenteditable/role=textbox divs, not <input>, and those now carry a ref too). Set submit=true to press Enter / submit afterwards (e.g. a search box, or to post a comment). The result reports the EFFECT, like a click: `changed` (the page moved — with submit off this means your text landed in the field; if it is false the text did NOT stick, so you targeted the wrong ref), `dtext` (how much visible text changed), and for submit `navigated`. Use these to confirm a post went through instead of re-reading or pixel-searching. REFS DIE ON NAVIGATION: if the result says `navigated`:true or a different `url`, every ref from the previous browser_read is now meaningless — browser_read again and use only the newest refs. Typing into a ref whose tag is `button` or `a` does not enter text, it activates the control (that is how a click-through happens), so if you meant to enter text pick a ref listed as EDITABLE. You MAY type a credential when signing the user in — into the login form of the site it belongs to, and only there; never into a page that merely asks for one, and never echo it back into a reply, a note, or a file.","parameters":{"type":"object","properties":{"ref":{"type":"integer"},"text":{"type":"string"},"submit":{"type":"boolean","description":"press Enter / submit the form after typing (default false)"}},"required":["ref","text"]}}},
    \\{"type":"function","function":{"name":"browser_eval","description":"Evaluate a small read-only JavaScript expression in the current page and return its value (JSON). Use for inspection the structured read doesn't cover (a computed value, a specific element's text). Prefer browser_click/browser_type to ACT on a page — they send real trusted input that sites accept, while a scripted click often silently does nothing — so reach for those rather than driving the page from here.","parameters":{"type":"object","properties":{"js":{"type":"string"}},"required":["js"]}}},
    \\{"type":"function","function":{"name":"browser_click_at","description":"Click a POINT in the browser viewport — x,y in CSS pixels from the top-left of the visible page, the same coordinates a screenshot shows. Use this whenever a ref from browser_read fails to resolve ('ref not found') or the click lands on nothing: refs depend on markers written into the page, and any app that re-renders (React, Vue, most SPAs) can wipe them between the read and the click. This has nothing to go stale — it is a real trusted mouse press at a location, exactly like a human clicking. Get coordinates from a screenshot tile (browser_read's visual block, or pixel_capture).","parameters":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"}},"required":["x","y"]}}},
    \\{"type":"function","function":{"name":"browser_type_text","description":"Type into WHATEVER IS FOCUSED right now — no element lookup at all. This is the reliable way to fill a field: click the input first (browser_click or browser_click_at), then call this. Existing contents are selected with a real ctrl/cmd+A and replaced unless clear=false. Every keystroke is genuine trusted input, so controlled React/Vue inputs update their state properly. Set submit=true to press Enter afterwards. You MAY type a credential when signing the user in — into the login form of the site it belongs to, and only there; never into a page that merely asks for one, and never echo it back into a reply, a note, or a file.","parameters":{"type":"object","properties":{"text":{"type":"string"},"clear":{"type":"boolean","description":"select-all and replace the field's contents first (default true)"},"submit":{"type":"boolean","description":"press Enter after typing (default false)"}},"required":["text"]}}},
    \\{"type":"function","function":{"name":"browser_key","description":"Press one real key: Enter, Tab, Escape, Backspace, Delete, ArrowUp/ArrowDown/ArrowLeft/ArrowRight, Home, End, PageUp, PageDown. Tab is especially useful on a page where element lookup fails — it moves focus between fields the way a keyboard user does, with no dependence on the DOM. Arrow keys plus Enter also work a native select/autocomplete dropdown, which a click cannot reach.","parameters":{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}}},
    \\{"type":"function","function":{"name":"browser_scroll","description":"Scroll with a real mouse wheel at a viewport point. Unlike a scripted window.scroll this reaches INNER scroll containers (a sidebar, a modal, a virtualized list) — point x,y inside the region you want to scroll. Positive dy scrolls down.","parameters":{"type":"object","properties":{"x":{"type":"integer","description":"viewport x of the region to scroll (default 400)"},"y":{"type":"integer","description":"viewport y (default 300)"},"dy":{"type":"integer","description":"pixels to scroll; positive is down (default 600)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"browser_console","description":"Read the browser CONSOLE for the current page: console.log/warn/error output, uncaught exceptions with their stack text, and browser log entries — everything a developer would open DevTools to see. This is the fastest way to find out WHY a web app misbehaved instead of guessing from the rendered page: drive the app with navigate/click/type, then read the console. Entries accumulate from the moment the page was opened and are returned oldest-first; `dropped` being non-zero means the capture buffer overflowed and this view is PARTIAL — say so rather than concluding the page is clean.","parameters":{"type":"object","properties":{"max":{"type":"integer","description":"max entries to return (default 100)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"browser_network","description":"Read the NETWORK activity of the current page: requests issued, responses with their status codes, and requests that failed outright. Use it to debug an app's real API traffic — a 401 that explains an empty dashboard, a CORS or DNS failure, a call that was never made at all. Set failures_only=true to see just the failures and 4xx/5xx responses, which is usually what you want first. `dropped` being non-zero means the capture buffer overflowed and this view is PARTIAL.","parameters":{"type":"object","properties":{"max":{"type":"integer","description":"max entries to return (default 100)"},"failures_only":{"type":"boolean","description":"only failed requests and 4xx/5xx responses (default false)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"browser_close","description":"Close the browser session when you are done with it, freeing the browser process.","parameters":{"type":"object","properties":{},"required":[]}}}
;

/// Pixel RAG tools (Feature 1 — screenshot-to-data retrieval). Injected at runtime alongside BROWSER_SCHEMA
/// when NL_BROWSER_DRIVER is set (they render pages in the same browser). Comma-joined, no outer brackets.
pub const PIXEL_SCHEMA =
    \\{"type":"function","function":{"name":"pixel_ingest","description":"Ingest a web page as RENDERED screenshot tiles (not parsed HTML): the page is loaded FRESH in a real browser, tiled into images, and each tile's text is indexed for retrieval. Use it to make a visually complex page (dashboards, tables, charts, docs) searchable when plain text extraction would lose the layout. NOTE: this NAVIGATES the browser (resetting any live page state) — to snapshot the page you are currently interacting with, use pixel_capture instead. Returns the doc_id and tile count.","parameters":{"type":"object","properties":{"url":{"type":"string"},"doc_id":{"type":"string","description":"optional id for this document (auto-derived from the url if omitted)"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"pixel_capture","description":"Snapshot the browser page EXACTLY AS IT IS RIGHT NOW — nothing is reloaded — into screenshot tiles + indexed text. This is how you visually VERIFY a web app's live state while testing it: browser_navigate / click / type to drive the app, then pixel_capture, then pixel_search (or read the returned tile text) to confirm what actually rendered — the logged-in feed, the open modal, the submitted form's result. Each capture gets its own doc generation, so before/after snapshots stay comparable.","parameters":{"type":"object","properties":{"doc_id":{"type":"string","description":"optional stable id for this snapshot (auto: derived from the page url + a generation suffix)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"pixel_search","description":"Search pages you previously pixel_ingested or pixel_captured and return the best-matching screenshot tiles — each result has the tile's image path, a text excerpt, and a score. Call pixel_ingest or pixel_capture first.","parameters":{"type":"object","properties":{"query":{"type":"string"},"k":{"type":"integer","description":"max results (default 4)"}},"required":["query"]}}}
;

/// MCP tools (round 2): let RSI find + use the AI-ready MCP servers / runtimes installed on the user's machine.
/// Injected at runtime only when NL_MCP is set. Comma-joined, no outer brackets.
/// Agent Garrett's two verbs (garrett.zig): appended to a turn's or a mind's belt only when the pair is there.
pub const GARRETT_SCHEMA = garrett.SCHEMA;
pub const garrettOn = garrett.on;
pub const garrettDiscover = garrett.discover;

pub const MCP_SCHEMA =
    \\{"type":"function","function":{"name":"mcp_discover","description":"Discover AI-ready capabilities installed on THIS machine: MCP servers declared in the local app configs (Claude Desktop, Cursor, VS Code) and local AI runtimes (Ollama, LM Studio). Call with no arguments to list every server + runtime; pass a server name to connect to it and list the tools it offers. Use this to find a local tool/app that can get information or perform an action plain web tools can't.","parameters":{"type":"object","properties":{"server":{"type":"string","description":"optional: a server name from a prior mcp_discover, to list ITS tools"}},"required":[]}}},
    \\{"type":"function","function":{"name":"mcp_call","description":"Call a tool on a locally-installed MCP server (discovered via mcp_discover). Give the server name, the tool name, and the tool's arguments object; returns the tool's result. Only use servers/tools the user already has installed and configured.","parameters":{"type":"object","properties":{"server":{"type":"string"},"tool":{"type":"string"},"args":{"type":"object","description":"the tool's arguments"}},"required":["server","tool"]}}}
;

/// The CHAT veil's tool set — the subset of SCHEMA a solo, top-level chat turn can actually reach. The full
/// SCHEMA carries swarm-mind / host-sim / RSI-only verbs (patch_system, host_command/status, make_tool, share,
/// probe, …) that a chat veil has no teammate bus, host, spatial grid, or governance loop to use; carrying them
/// only inflates the per-turn prefill (~7k tokens re-sent every drive step) and invites an off-surface tool
/// call that burns a whole agentic round-trip. Keeps exactly the tools SYSTEM_PROMPT (chat_engine.zig) names:
/// the web trio (web_search/web_fetch/read_url, + fetch_json for JSON APIs), the build set (read/write/edit/
/// list_dir/run_python/run_tests/delete_file), and memory (observe/recall/recall_hive). Orchestration verbs
/// (cast/steer_swarm/…) are concatenated separately in chat_engine.zig (ORCH_TOOLS).
///
/// Defs are copied VERBATIM from SCHEMA above so the block stays byte-identical (stable provider prefix cache)
/// — with two declared exceptions, because "keep them in sync" used to be the whole instruction and it was not
/// true: 4 of these defs deliberately DIFFER and 2 exist only here. A worker who took the old wording literally
/// would have "fixed" the drift and deleted correct behaviour. The exceptions are pinned in CHAT_ADAPTED_DEFS
/// and CHAT_ONLY_DEFS below, and the test there fails on any UNDECLARED difference — so an accidentally stale
/// copy is caught, while an intentional adaptation has to be written down.
pub const CHAT_SCHEMA =
    \\{"type":"function","function":{"name":"run_python","description":"Run Python (no GUI) in the build workdir; returns stdout/stderr. This is your general-purpose EXECUTOR and the DEFAULT whenever no other tool fits, because it (with run_shell for plain commands) is the only way you can execute anything: HTTP and API calls with your own headers/auth/POST body (requests works, the network is up), computation, data wrangling, generating files. Provider API keys are stripped from the environment, but a credential written into the code itself is used as-is. Each run has a hard wall-clock cap (120 s unless the host set another): a timeout= inside your code cannot raise it, so start a longer job in the background with its output sent to a file, then watch that file with poll. If it answers that python is not found, install python with run_shell, then tool_env refresh_path, then retry.","parameters":{"type":"object","properties":{"code":{"type":"string","description":"the Python source to execute"}},"required":["code"]}}},
    \\{"type":"function","function":{"name":"run_shell","description":"Run a shell script in the build workdir — PowerShell (the Windows default), bash or sh (the POSIX default), or cmd — and return exit code, stdout and stderr in the same shape as run_python. Use it for anything that is a command rather than Python: package managers, build tools, git, system utilities. This is also HOW YOU INSTALL MISSING TOOLING: when run_python reports that python is not found, install it here (Windows: winget install Python.Python.3; macOS: brew install python; Debian/Ubuntu: apt install python3), then call tool_env with action refresh_path (or tool_env set NL_PYTHON_BIN=<full path>) so the next run_python finds it — no veil restart needed. Provider API keys are stripped from the environment. Each run has a hard wall-clock cap (120 s unless the host set another): a sleep or timeout inside the script cannot raise it, so start a longer job in the background with its output sent to a file, then watch that file with poll.","parameters":{"type":"object","properties":{"script":{"type":"string","description":"the script text to run, in the chosen shell's own language"},"shell":{"type":"string","enum":["auto","powershell","bash","sh","cmd"],"description":"auto (the default) is powershell on Windows, bash if present else sh elsewhere"},"timeout_s":{"type":"integer","description":"optional cap for this call in seconds; never above the host's cap"}},"required":["script"]}}},
    \\{"type":"function","function":{"name":"tool_env","description":"Persist an environment change for every tool run from now on in this veil — run_python, run_shell, run_tests and the rest — with no restart, and it survives restarts. action set: name + value (name PATH puts value in front of the tool PATH; NL_PYTHON_BIN points run_python at a specific interpreter). action refresh_path: re-read the machine's live PATH (the registry on Windows, a login shell elsewhere) so a program an installer just added (winget/brew/apt) is found without restarting veil. action show: print the stored overlay. The install flow: run_shell installs the program, tool_env refresh_path, then retry the tool that could not find it.","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["set","refresh_path","show"]},"name":{"type":"string","description":"for set: the variable name (PATH to prepend a directory)"},"value":{"type":"string","description":"for set: the value, or the directory for PATH"}},"required":["action"]}}},
    \\{"type":"function","function":{"name":"stop_process","description":"KILL a process YOU started (and its children) by pid — the background server, fuzzer, watcher or build you launched with run_python and no longer want. Ending a turn does NOT reap what a script spawned, so a run left behind keeps holding the machine and its ports. Use it when the user says stop, when you are done watching something, or before relaunching a service on the same port.","parameters":{"type":"object","properties":{"pid":{"type":"integer","description":"the process id to terminate, together with its child tree"}},"required":["pid"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the build workdir (creates parent dirs). To GROW a long document (e.g. add the next scene to a chapter) pass mode:\"append\" with ONLY the new text — it is concatenated onto the existing file, so you never resend (or truncate) prior content. mode:\"overwrite\" (default) replaces the file. To CHANGE an existing file, prefer edit_file (never re-emit a large file).","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit_file","description":"Make a SURGICAL edit to an EXISTING file WITHOUT resending the whole file — use this (NOT write_file) to change a file that already exists, especially a large one (write_file re-emits the whole file and truncates big ones). PREFERRED anchors: reads prefix every line with a tag like 42:abc:def — copy that tag as the op's anchor (add end = the range's LAST-line tag to cover several lines). Tags are verified against the CURRENT file and the batch is ATOMIC: all ops apply or none do, and a stale-tag error hands you FRESH tags — retry the whole batch with those (no re-read needed). Plain text anchors (a snippet copied VERBATIM, unique in the file) also work. op is: replace (swap the anchored line/range for text), insert_before / insert_after (add text around the anchor; anchor 0: = file start, EOF = file end), delete (remove the anchored lines).","parameters":{"type":"object","properties":{"path":{"type":"string"},"ops":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["replace","insert_before","insert_after","delete"]},"anchor":{"type":"string"},"end":{"type":"string"},"text":{"type":"string"}},"required":["op","anchor"]}}},"required":["path","ops"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file from the build workdir (relative path), OR — because this tool runs on the USER'S machine — any file the user points you at by ABSOLUTE path (C:/data/report.csv) or ~/file. Workdir lines come prefixed with their anchor tag (42:abc:def→) — copy a line's tag as an edit_file anchor. A whole-file read is CLIPPED to its head, so for a big file pass start_line/end_line (1-indexed, inclusive) and read the window you are about to edit: never edit from a clipped view, and never rewrite a file just because the view ended.","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"absorb","description":"Absorb a local text file (a book, doc, notes, dataset) into long-term memory (neuron-db), filed under the document's OWN scope (knowledge__doc-<slug>; the result names it). Use it when the user points you at a file to learn (\"absorb the book at C:/books/x.txt\") — deterministic, offline. Afterwards: targeted questions → recall_hive (documents are searched automatically); whole-document work (summarize/outline/review) → read_doc, which pages the document IN ORDER. Pass path (relative to the workdir, or an ABSOLUTE path on the user's machine). Optional scope (override target), name (provenance label), cap (max facts).","parameters":{"type":"object","properties":{"path":{"type":"string"},"scope":{"type":"string"},"name":{"type":"string"},"cap":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"list_dir","description":"List the files (with sizes) in a directory so you can SEE what exists before reading or editing. Defaults to your build workdir; also accepts an ABSOLUTE path (C:/data) or ~/dir on the user's machine; pass root=\"system\" to list the patch_system engine root.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"relative dir (default '.'), or an absolute/~ path on the user's machine"},"root":{"type":"string","enum":["workdir","system"],"description":"workdir (default) or the patch_system root"}},"required":[]}}},
    \\{"type":"function","function":{"name":"stage_file","description":"Copy a file from the user's machine (ABSOLUTE or ~ path) INTO the build workdir, so a HIVE you cast can use it — hives only see the workdir (it syncs to them), never the rest of the machine. Reading for YOURSELF needs no staging (read_file takes absolute paths directly); stage only what a hive must build on.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"absolute or ~ source path on the user's machine"},"as":{"type":"string","description":"optional workdir-relative name (default: the source's file name)"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"run_tests","description":"Run the deliverable's test suite (pytest, else a test_*.py) in your build workdir and get the pass/fail output. VERIFY your code after writing or patching it — write, run_tests, fix, run_tests again. This is how you make sure a change actually works.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"delete_file","description":"Delete a file you created in your build workdir (clean up a dead end, a wrong scaffold, or junk).","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch a URL and return its clean, readable text (our in-house crawler strips tags + prunes boilerplate + cites links). Automatically escalates to a browser-impersonating client (curl_cffi TLS/JA3 fingerprint) when a plain fetch hits a bot gate (Cloudflare/Datadome), so many blocked pages come through anyway. Optional 'query' fits the page to your topic and returns only the most relevant parts. Use it to read a page you already have the URL for.","parameters":{"type":"object","properties":{"url":{"type":"string"},"query":{"type":"string","description":"optional: a topic/question to fit the page to — returns only the parts that match"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_search","description":"Keyless web search — returns the top results, each WITH a short excerpt of the source's actual page text (auto-fetched + fit to your query), so you usually don't need a separate fetch. For current events just search the topic + a date.","parameters":{"type":"object","properties":{"query":{"type":"string"},"source":{"type":"string","enum":["web","wikipedia","hackernews","arxiv"],"description":"web=general (default), or a specific source"},"limit":{"type":"integer","description":"max results (default 5)"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"fetch_json","description":"HTTP GET a JSON/text API endpoint and return the raw body (not HTML-stripped). Use for REST/JSON APIs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"read_url","description":"Read a URL as clean, LLM-ready text via a reader proxy that renders JS and works on sites a plain fetch can't. Prefer this over web_fetch for real articles/pages.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall","description":"Recall facts from your memory relevant to a query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Think WITH the whole hive: spreading-activation recall across the shared collective memory AND every stored document (absorbed books/docs are searched automatically). Unlike recall (your own facts), this surfaces the CHAINED neighborhood of related facts reached by following shared entities. Use it for targeted questions. For WHOLE-document work use read_doc instead — fragments are not a summary.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"read_doc","description":"Read a stored document from long-term memory IN ORDER, one page at a time — the ONLY correct path for whole-document work (summarize, outline, review, translate). recall/recall_hive return scattered fragments; this returns the document itself. Call with NO args to list the stored documents; then pass scope (absorb's result names it) and page with from until END. [section] lines are chapter markers.","parameters":{"type":"object","properties":{"scope":{"type":"string","description":"the document scope, e.g. knowledge__doc-mybook"},"name":{"type":"string","description":"alternative: the document's label, resolved to its scope"},"from":{"type":"integer","description":"start fact index (default 0)"},"limit":{"type":"integer","description":"facts per page (default 120, max 400)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"poll","description":"WATCH something to completion instead of guessing or checking once: a bounded observe loop that samples every interval_s until done or timeout_s, returning the observation log + a verdict (matched/up/open/running/gone/quiet/done/failing/timeout). kinds: file (a log/output file — reports growth and the new tail; done when `until` text appears, or after quiet_s with no growth), url (probe an http(s) endpoint until it answers), port (until a local tcp port accepts), process (until a process is running — or exited, with until:'gone'), command (re-run a probe command until exit 0 or output contains `until`; each sample shows its exit code, stdout and stderr; a probe still running when timeout_s ends is killed; one that fails the same way WITH an error message from its first samples ends the call as 'failing' — to wait out a not-ready state that prints an error, silence it: 2>/dev/null, test -f, grep -q, curl -sf), swarm (until this conversation's cast finishes). Use it to wait on builds, servers coming up, downloads, logs, casts. On 'timeout' you may poll again — a long wait is a CHAIN of bounded polls, never one blind sleep — but STOP after 2-3 timeouts with zero progress: the thing may never arrive; act on what you have or tell the user.","parameters":{"type":"object","properties":{"kind":{"type":"string","enum":["file","url","port","process","command","swarm"]},"target":{"type":"string","description":"path / url / port number / process name / probe command (kind swarm needs none)"},"until":{"type":"string","description":"text meaning DONE (file/command), an http status code (url), or 'gone' (process)"},"quiet_s":{"type":"integer","description":"file: also done after this many seconds of no growth"},"interval_s":{"type":"integer","description":"seconds between samples (default 3, max 30)"},"timeout_s":{"type":"integer","description":"this call's budget in seconds (default 60, max 180)"}},"required":["kind"]}}},
    \\{"type":"function","function":{"name":"get_credential","description":"Fetch ONE stored credential VALUE from the user's durable memory (the YOUR MEMORY entries shown masked as '[withheld]'). Values never ride in prompts by default — call this in the turn that actually needs one, then use it directly in that call. NEVER echo a fetched credential into replies, observe/share notes, REMEMBER lines, or files beyond the immediate use.","parameters":{"type":"object","properties":{"query":{"type":"string","description":"a few identifying words — the service or domain from the masked entry"}},"required":["query"]}}}
;

/// CHAT_SCHEMA defs that deliberately DIFFER from their SCHEMA twin, each with the reason. The chat veil runs
/// on the USER'S machine and has no teammates, so three defs widen paths to absolute/~ and one drops the
/// collective framing. Pinned so an UNDECLARED difference fails the test below -- that is an accidentally
/// stale copy, exactly what "keep them in sync" was asking a human to prevent by hand.
const CHAT_ADAPTED_DEFS = [_][]const u8{
    "read_file", // chat reads the user's OWN machine: adds ABSOLUTE / ~ paths
    "list_dir", // same
    "absorb", // same, plus the "absorb the book at C:/..." phrasing
    "recall_hive", // a solo veil has no teammates: drops "what ANY teammate contributed"
};

/// Defs that exist ONLY in CHAT_SCHEMA -- chat-surface tools with no swarm-mind equivalent in SCHEMA.
const CHAT_ONLY_DEFS = [_][]const u8{
    "stage_file", // copies a file off the user's machine INTO the workdir so a cast hive can see it
    "get_credential", // reads the user's durable memory; a swarm mind has no such store
};

fn defNameOf(def: []const u8) ?[]const u8 {
    const k = "\"name\":\"";
    const i = std.mem.indexOf(u8, def, k) orelse return null;
    const rest = def[i + k.len ..];
    const j = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..j];
}

fn findSchemaDef(block: []const u8, want: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r,");
        const n = defNameOf(line) orelse continue;
        if (std.mem.eql(u8, n, want)) return line;
    }
    return null;
}

fn defListHas(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

test "CHAT_SCHEMA stays a verbatim subset of SCHEMA, apart from the adaptations on record" {
    // Two hand-maintained copies of one tool contract is how a surface starts advertising a stale one: edit a
    // description in SCHEMA, forget this block, and the chat veil keeps promising the old behaviour with
    // nothing to notice. The old instruction was a comment saying "keep them in sync", which was not even
    // accurate -- 4 defs differ ON PURPOSE. So: verbatim is the rule, exceptions are declared, and a declared
    // exception that stops being one ALSO fails, so the lists cannot rot. Same shape as KNOWN_CAP_OVERLAP.
    var verbatim: usize = 0;
    var it = std.mem.splitScalar(u8, CHAT_SCHEMA, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r,");
        const name = defNameOf(line) orelse continue;

        if (defListHas(&CHAT_ONLY_DEFS, name)) {
            if (findSchemaDef(SCHEMA, name) != null) {
                std.debug.print("\n'{s}' exists in SCHEMA now -- drop it from CHAT_ONLY_DEFS\n", .{name});
                return error.StaleChatOnlyDef;
            }
            continue;
        }
        const twin = findSchemaDef(SCHEMA, name) orelse {
            std.debug.print("\n'{s}' is in CHAT_SCHEMA but not SCHEMA -- declare it in CHAT_ONLY_DEFS\n", .{name});
            return error.UndeclaredChatOnlyDef;
        };
        const same = std.mem.eql(u8, twin, line);
        if (defListHas(&CHAT_ADAPTED_DEFS, name)) {
            if (same) {
                std.debug.print("\n'{s}' matches SCHEMA again -- drop it from CHAT_ADAPTED_DEFS\n", .{name});
                return error.StaleAdaptation;
            }
            continue;
        }
        if (!same) {
            std.debug.print("\n'{s}' drifted from its SCHEMA twin -- copy it across, or declare it in CHAT_ADAPTED_DEFS with the reason\n", .{name});
            return error.ChatSchemaDrift;
        }
        verbatim += 1;
    }
    // Not vacuous: most of the block really is shared, so the rule above is doing real work.
    try std.testing.expect(verbatim >= 10);
}

/// The SCOUT's tool set — a RESEARCH-ONLY subset of SCHEMA. The build tools (run_python, write_file) are
/// deliberately ABSENT so the learner mind STRUCTURALLY cannot drift into building: an imperative "do not build"
/// prompt did not hold (the LLM scout ignored it and wrote files like everyone else), so the engine simply
/// withholds the ability. The scout can read context, search/read the web, store facts, save skills, and
/// message teammates — its only outputs are KNOWLEDGE.
///
/// These defs are NOT verbatim copies of their SCHEMA twins, and should not be made into them: 14 of 15 are
/// ADAPTED to this surface, correctly. `read_file` drops SCHEMA's edit_file anchor-tag guidance because a
/// scout has no edit_file to use it with, and gains "see what the team is building and what to research";
/// `web_search` drops the source enum. So there is no verbatim rule here to enforce and no drift guard —
/// unlike CHAT_SCHEMA, which IS mostly verbatim and has one. (The line here used to read "keep these defs in
/// sync with their twins", which described neither the code nor the intent; taken literally it would have had
/// someone advertise edit_file to a mind that cannot call it. Ledger 0057.)
pub const SCOUT_SCHEMA =
    \\{"type":"function","function":{"name":"web_search","description":"Keyless web search — returns the top results, each WITH a short excerpt of the source's actual page text (auto-fetched + fit to your query), so you usually don't need a separate fetch. For current events just search the topic + a date.","parameters":{"type":"object","properties":{"query":{"type":"string"},"source":{"type":"string","enum":["web","wikipedia","hackernews","arxiv"]},"limit":{"type":"integer"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"read_url","description":"Read a URL as clean, LLM-ready text via a reader proxy that renders JS. Prefer this over web_fetch for real articles/specs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch a URL and return its clean readable text (our in-house crawler strips tags + prunes boilerplate). Optional 'query' fits the page to your topic.","parameters":{"type":"object","properties":{"url":{"type":"string"},"query":{"type":"string","description":"optional: a topic/question to fit the page to"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"osint_scan","description":"Public-source OSINT scan for one URL: extract high-signal leads (emails, phones, domains, docs, socials, and notable outbound links).","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"deep_crawl","description":"Recursive public-web crawl from a seed URL with bounded depth/pages, extracting lead-rich links across hops.","parameters":{"type":"object","properties":{"url":{"type":"string"},"depth":{"type":"integer"},"max_pages":{"type":"integer"},"same_host":{"type":"boolean"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"fetch_json","description":"HTTP GET a JSON/text API endpoint and return the raw body. Use for REST/JSON APIs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the build workdir — use it to see what the team is building and what to research. For a big file, pass start_line/end_line (1-indexed) to read a window.","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"recall","description":"Recall facts from your memory relevant to a query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Spreading-activation recall across the hive's shared collective memory — check what the team already knows before researching.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"probe","description":"PERCEIVE one cell of the hidden spatial grid (only when the swarm has a spatial substrate). probe(x,y) reads column x, row y (0-based) and records it to the hive's shared map. As the scout you can sweep an UNCLAIMED region of the grid for the team.","parameters":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"}},"required":["x","y"]}}},
    \\{"type":"function","function":{"name":"share","description":"Contribute one fact to the hive's shared associative mind so every teammate can recall it.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"save_skill","description":"Save a reusable technique you found for the team — name it 'scout:<topic>' — into the shared skill library so builders can apply it. Make it concrete and actionable, not just a link.","parameters":{"type":"object","properties":{"name":{"type":"string"},"skill":{"type":"string"}},"required":["name","skill"]}}},
    \\{"type":"function","function":{"name":"journal","description":"Write an entry in YOUR personal journal (journal/<your-name>.md) — your experience, reflections, anything, in your own voice. Ungraded; teammates can read it, only you write it.","parameters":{"type":"object","properties":{"entry":{"type":"string"}},"required":["entry"]}}},
    \\{"type":"function","function":{"name":"send_message","description":"Send the single most useful thing you learned to a teammate (or 'all').","parameters":{"type":"object","properties":{"to":{"type":"string"},"text":{"type":"string"}},"required":["to","text"]}}}
;

/// The ASSEMBLER's tool set — the minimal authoring set for a small model (8B) in scaffold-and-fill mode. The
/// full SCHEMA (~6k tokens, re-sent every turn) drowns a weak model and confuses weak tool-calling, so the
/// assembler gets ONLY what it needs: read what exists, write the fill, observe, recall_hive (PULL the exact
/// pattern the hive already learned before building), send_message (parallel minds agree on interfaces), and
/// save_skill (the lean tier is where techniques get worked out — without a save path the skill-development loop
/// is dead for the minds doing the developing). No web/search (the scout's job), no run_python/run_tests, and no
/// make_tool (authoring+invoking dynamic tools needs the full schema a lean model can't carry). Keep defs in
/// sync with SCHEMA.
pub const ASSEMBLER_SCHEMA =
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the build workdir (creates parent dirs). To GROW a long document (e.g. add the next scene to a chapter) pass mode:\"append\" with ONLY the new text — it is concatenated onto the existing file, so you never resend (or truncate) prior content. mode:\"overwrite\" (default) replaces the file. To CHANGE an existing file, prefer edit_file (never re-emit a large file).","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit_file","description":"Make a SURGICAL edit to an EXISTING file WITHOUT resending the whole file — use this (NOT write_file) to change a file that already exists, especially a large one (write_file re-emits the whole file and truncates big ones). PREFERRED anchors: reads prefix every line with a tag like 42:abc:def — copy that tag as the op's anchor (add end = the range's LAST-line tag to cover several lines). Tags are verified against the CURRENT file and the batch is ATOMIC: all ops apply or none do, and a stale-tag error hands you FRESH tags — retry the whole batch with those (no re-read needed). Plain text anchors (a snippet copied VERBATIM, unique in the file) also work. op is: replace (swap the anchored line/range for text), insert_before / insert_after (add text around the anchor; anchor 0: = file start, EOF = file end), delete (remove the anchored lines).","parameters":{"type":"object","properties":{"path":{"type":"string"},"ops":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["replace","insert_before","insert_after","delete"]},"anchor":{"type":"string"},"end":{"type":"string"},"text":{"type":"string"}},"required":["op","anchor"]}}},"required":["path","ops"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the build workdir. Each line comes prefixed with its anchor tag (42:abc:def→) — copy a line's tag as an edit_file anchor. For a big file, pass start_line/end_line (1-indexed, inclusive) to read just that window.","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Pull what the hive already LEARNED before you build: spreading-activation recall across the shared collective memory. You are shown a list of topics the hive knows — call this with the one you need (e.g. 'axum routing', 'JWT auth') to get the concrete pattern/snippet, instead of guessing or redoing research.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"save_skill","description":"When filling your slot taught you a REUSABLE technique (a pattern, snippet, or recipe a teammate will need again), save it to the swarm's shared skill library: a short name + the concrete how-to. Do this AFTER your file work, and do NOT re-save a skill you were already shown.","parameters":{"type":"object","properties":{"name":{"type":"string"},"skill":{"type":"string"}},"required":["name","skill"]}}},
    \\{"type":"function","function":{"name":"journal","description":"Write an entry in YOUR personal journal (journal/<your-name>.md) — your experience, reflections, anything, in your own voice. Ungraded and optional; teammates can read it, only you write it.","parameters":{"type":"object","properties":{"entry":{"type":"string"}},"required":["entry"]}}},
    \\{"type":"function","function":{"name":"send_message","description":"Tell a teammate (or 'all') the ONE thing they must know to stay consistent with your file — the exact function name + signature you expose, or a decision the others must match. Read your inbox (shown above) and reply when a teammate needs something.","parameters":{"type":"object","properties":{"to":{"type":"string"},"text":{"type":"string"}},"required":["to","text"]}}}
;

pub const OPERATE_SCHEMA =
    \\{"type":"function","function":{"name":"host_status","description":"Read the LIVE state of the host/machine you are operating (its telemetry: mode, threat_score, processes, connections, persistence, infections). Call it to see the current state before you act and again after you act to VERIFY. Returns the raw telemetry.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"host_command","description":"OPERATE the host: issue ONE command to it directly (this is how you actually act on the machine — do NOT write files describing a fix). Use it to remediate: remove_persistence <unit> (the ROOT CAUSE), kill_proc <pid|name>, block_ip <ip>, restore_file <path>, isolate, scan. To fully clean an infection, remove its persistence AND block its C2 AND kill its process.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"one command line, e.g. 'remove_persistence sysupdate.timer'"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"host_explore","description":"EXPLORE the device READ-ONLY to discover structure the live telemetry does not show. verb: enumerate <node> (list a container's direct members), expand <node> (fan out a node's typed neighbors — this GROWS your map), describe <node> (read one entity's attributes). Discoveries map into your memory; recall/chain over them next round to find the real structure and the root. It never changes the device.","parameters":{"type":"object","properties":{"verb":{"type":"string","description":"enumerate | expand | describe"},"node":{"type":"string","description":"a node shown in your map or telemetry (a pid, path, handle, principal)"},"rel":{"type":"string","description":"optional relation for a targeted walk"}},"required":["verb","node"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the workdir — use it to inspect a config/log/source before you change it. For a big file, pass start_line/end_line (1-indexed) to read a window.","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the workdir (creates parent dirs) — use it to PATCH a config you read (write back the fixed version) or to record a written report/debrief. mode:\"append\" concatenates only the new text; mode:\"overwrite\" (default) replaces the file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"recall","description":"Recall facts from your memory relevant to a query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Think WITH the whole hive: spreading-activation recall across the shared collective memory — surfaces the chained neighborhood of what ANY teammate (or the baked intel) knows, even facts that share no words with your query. Use it to GROUND a decision (e.g. is this identifier known-bad, who is the actor) before you act.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned (e.g. a confirmed indicator, what an action did) into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"send_message","description":"Send a message to a teammate mind (or 'all' to broadcast) on the swarm bus — split the work so two operators don't act on the same facet.","parameters":{"type":"object","properties":{"to":{"type":"string"},"text":{"type":"string"}},"required":["to","text"]}}},
    \\{"type":"function","function":{"name":"set_directive","description":"IMPROVE HOW YOUR SWARM OPERATES. Write one concise imperative process rule into the swarm's shared, self-authored operating PLAYBOOK — injected into every mind's instructions from now on (e.g. 'confirm a target is hostile before any destructive action', 'remove the persistence before killing the process'). This is how the swarm improves its own operating method over time. Don't repeat a directive already in the playbook.","parameters":{"type":"object","properties":{"directive":{"type":"string","description":"one concise imperative process rule for the swarm to follow"}},"required":["directive"]}}}
;

/// The sandbox gate's refusal, shared so runRecipe can DETECT it verbatim (a step that hit the gate) and
/// surface WHY to the model, rather than string-matching a copy that could drift out of step.
const SANDBOX_REFUSAL = "that tool is not available in this workspace — you are working inside this conversation's own directory. Files, research, and memory are available; running code, reaching the host, and driving a browser are not.";

/// The granted recipe named `name`, or null. Scans ctx.grants — the per-turn resolved allowlist of recipes
/// THIS caller may run (I2). A name is treated as a recipe ONLY when it is in grants, so a sandboxed caller
/// can never run a recipe they were not granted, and this never widens sandboxAllowed: it only decides HOW a
/// permitted name runs (as a data recipe), never WHETHER the gate refuses a name.
fn grantedRecipe(ctx: *ToolCtx, name: []const u8) ?*const recipes.Recipe {
    for (ctx.grants) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

/// Run one tool. `args_json` is the raw arguments string from the tool_call. Returns a gpa-owned result
/// (caller frees) — always a string, even on error, so it can feed back to the model.
///
/// TRAINING CAPTURE rides this one dispatcher (see worker/dataset.zig): every tool the model runs —
/// chat turn or swarm mind, built-in or recipe, allowed or refused — passes through here exactly once
/// per call, with the arguments it asked for and the result it will read. That pair is "how the AI
/// builds", and it is recorded only while a set is open (one atomic load otherwise).
pub fn execute(ctx: *ToolCtx, name: []const u8, args_json: []const u8) []u8 {
    if (dataset.armed()) return executeRecorded(ctx, name, args_json);
    return executeInner(ctx, name, args_json);
}

/// execute() with the training-set record around it. Split out so the hot path (no set recording)
/// carries nothing but the atomic load above — no timer, no extra frame.
fn executeRecorded(ctx: *ToolCtx, name: []const u8, args_json: []const u8) []u8 {
    const t0 = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
    const out = executeInner(ctx, name, args_json);
    const ms: u64 = @intCast(@max(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds - t0, std.time.ns_per_ms), 0));
    // A tool reports failure in its RESULT TEXT (the string the model reads), never out-of-band —
    // so the record's `ok` reads the same signal the model does rather than inventing a new one.
    const ok = !(std.mem.startsWith(u8, out, "error") or std.mem.startsWith(u8, out, "ERROR") or
        std.mem.startsWith(u8, out, "refused") or std.mem.eql(u8, out, SANDBOX_REFUSAL));
    dataset.recordTool(.{
        .name = name,
        .args_json = args_json,
        .result = out,
        .ok = ok,
        .ms = ms,
        .mind = ctx.mind,
        .round = ctx.round,
    });
    return out;
}

fn executeInner(ctx: *ToolCtx, name: []const u8, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    // THE SANDBOX GATE. First thing in the dispatcher, before any tool-specific logic, so there is exactly one
    // place a capability decision is made. A sandboxed caller passes a name iff it is on the built-in sandbox
    // allowlist OR it is a recipe THIS caller was granted (I2). grantedRecipe does NOT widen sandboxAllowed —
    // sandboxAllowed() is unchanged; a granted name is merely allowed to reach the recipe DISPATCH below, whose
    // steps each re-hit THIS gate under these same caps (I4). So a grant controls HOW a tool runs (a data
    // recipe through the gate), never WHETHER the gate refuses a name — the whole safety property of the feature.
    if (ctx.caps == .sandboxed and !sandboxAllowed(name) and !garrett.isTool(name) and grantedRecipe(ctx, name) == null)
        return dupe(gpa, SANDBOX_REFUSAL);

    // A GRANTED NAME RUNS AS DATA OR NOT AT ALL — and this must be decided BEFORE the built-in chain.
    //
    // The gate above admits a name for either of two reasons, and then forgets which. Dispatch below is
    // linear, so if a granted recipe were ever named after a built-in, the BUILT-IN matched first and ran
    // with the caller's own arguments — the grant having done nothing but carry the name past the gate.
    // A recipe named "get_credential" returned stored secrets to a sandboxed caller that way. Deciding
    // here makes the grant mean what its comment claims: it controls HOW a tool runs, never WHETHER the
    // gate refuses a name.
    //
    // isBuiltinTool now also refuses such a name at load (recipes.loadDir), so for any validly-loaded
    // registry this branch changes nothing. It is the structural backstop for the case where a colliding
    // name reaches ctx.grants by some route the loader does not police — belt as well as braces, because
    // the loader's guard is a name list and name lists drift.
    if (grantedRecipe(ctx, name)) |rec| return runRecipe(ctx, rec, args_json);

    if (ctx.discourse and (std.mem.eql(u8, name, "run_python") or std.mem.eql(u8, name, "run_shell") or std.mem.eql(u8, name, "tool_env") or
        std.mem.eql(u8, name, "run_tests") or std.mem.eql(u8, name, "make_tool") or std.mem.eql(u8, name, "patch_system")))
        return dupe(gpa, "this is a research/writing task — there is no code repo or test suite; produce the written deliverable with write_file");
    // APP-ATTACH LEARN phase is READ-ONLY: code execution and tool authoring are disabled because they could
    // write the command bus (bypassing reservedBusName, which only guards the file tools) or actuate the app.
    // The mind maps the app with host_explore and reasons with read_file/recall — it never runs code here.
    if (ctx.app_attach and (std.mem.eql(u8, name, "run_python") or std.mem.eql(u8, name, "run_shell") or std.mem.eql(u8, name, "tool_env") or
        std.mem.eql(u8, name, "make_tool") or std.mem.eql(u8, name, "patch_system")))
        return dupe(gpa, "APP-ATTACH LEARN phase is read-only — run_python / run_shell / tool_env / make_tool / patch_system are disabled (they could actuate the app or write the bus). Map the app with host_explore (enumerate/expand/describe) and reason with read_file/recall/recall_hive; the learned surface persists in the lineage hive for the next attach.");
    if (std.mem.eql(u8, name, "run_python")) return runPython(ctx, args_json);
    if (std.mem.eql(u8, name, "run_shell")) return runShell(ctx, args_json);
    if (std.mem.eql(u8, name, "tool_env")) return toolEnvTool(ctx, args_json);
    if (std.mem.eql(u8, name, "write_file")) return writeFile(ctx, args_json);
    if (std.mem.eql(u8, name, "edit_file")) return editFile(ctx, args_json);
    if (std.mem.eql(u8, name, "read_file")) return readFile(ctx, args_json);
    if (std.mem.eql(u8, name, "absorb")) return absorbFile(ctx, args_json);
    if (std.mem.eql(u8, name, "stage_file")) return stageFile(ctx, args_json);
    if (std.mem.eql(u8, name, "patch_system")) return patchSystem(ctx, args_json);
    if (std.mem.eql(u8, name, "list_dir")) return listDir(ctx, args_json);
    if (std.mem.eql(u8, name, "ask_veil")) return askVeil(ctx, args_json);
    if (std.mem.eql(u8, name, "run_tests")) return runTests(ctx, args_json);
    if (std.mem.eql(u8, name, "delete_file")) return deleteFile(ctx, args_json);
    if (std.mem.eql(u8, name, "host_status")) return hostStatus(ctx, args_json);
    if (std.mem.eql(u8, name, "host_command")) return hostCommand(ctx, args_json);
    if (std.mem.eql(u8, name, "host_explore")) return hostExplore(ctx, args_json);
    // AGENT GARRETT (garrett_tools, garrett): the user's own blue-team agent over MCP. Runs in the process that
    // holds the pair (ctx.garrett_url/token — the server for a chat turn, the worker itself for a mind); blank
    // means the belt was never advertised, and the verb says how to get it instead of pretending.
    if (garrett.isTool(name)) {
        if (!ctx.internet) return dupe(gpa, "web disabled: this is an OFFLINE run, and Agent Garrett answers over the internet. Answer from the hive's preloaded memory.");
        return garrett.run(.{ .gpa = gpa, .io = ctx.io, .scratch = ctx.run_dir, .url = ctx.garrett_url, .token = ctx.garrett_token }, name, args_json);
    }
    if (!ctx.internet and (std.mem.eql(u8, name, "web_fetch") or std.mem.eql(u8, name, "web_search") or
        std.mem.eql(u8, name, "fetch_json") or std.mem.eql(u8, name, "read_url") or
        std.mem.eql(u8, name, "osint_scan") or std.mem.eql(u8, name, "deep_crawl")))
        return dupe(gpa, "web disabled: this is an OFFLINE run. Answer from the hive's preloaded memory — use recall / recall_hive / assoc, not the internet.");
    if (std.mem.eql(u8, name, "web_fetch")) return webFetch(ctx, args_json);
    if (std.mem.eql(u8, name, "web_search")) return webSearch(ctx, args_json);
    if (std.mem.eql(u8, name, "fetch_json")) return fetchJson(ctx, args_json);
    if (std.mem.eql(u8, name, "read_url")) return readUrl(ctx, args_json);
    if (std.mem.eql(u8, name, "osint_scan")) return osintScan(ctx, args_json);
    if (std.mem.eql(u8, name, "deep_crawl")) return deepCrawl(ctx, args_json);
    if (std.mem.startsWith(u8, name, "browser_")) return browserDispatch(ctx, name, args_json);
    if (std.mem.startsWith(u8, name, "pixel_")) return pixelDispatch(ctx, name, args_json);
    if (std.mem.startsWith(u8, name, "mcp_")) return mcpDispatch(ctx, name, args_json);
    if (std.mem.startsWith(u8, name, "cf_")) {
        if (cftools.dispatch(.{ .gpa = gpa, .io = ctx.io, .scratch = ctx.run_dir, .workdir = ctx.workdir, .token = ctx.cf_token, .account = ctx.cf_account, .api_root = ctx.cf_api_root, .wrote = ctx.cf_wrote }, name, args_json)) |r| return r;
    }
    if (std.mem.eql(u8, name, "propose_change")) return proposeChange(ctx, args_json);
    if (std.mem.eql(u8, name, "simulate_change")) return simulateChange(ctx, args_json);
    if (std.mem.eql(u8, name, "get_credential")) return getCredential(ctx, args_json);
    if (std.mem.eql(u8, name, "observe")) {
        const A = struct { fact: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        if (std.mem.trim(u8, p.value.fact, " \r\n\t").len == 0) return dupe(gpa, "empty fact, nothing stored");
        if (ctx.mem_sink) |sink| {
            sink.push(.fact, p.value.fact, "");
            ctx.observed.* += 1;
            return dupe(gpa, "noted — will be checked against what actually happened before it enters memory");
        }
        var shared = false;
        if (ctx.share_obs) {
            // scout/operator: contributing to the hive IS the job — observe flows straight to it.
            shared = hiveStore(ctx, p.value.fact);
            if (!shared) _ = ctx.mem.observe(ctx.scope, p.value.fact);
        } else if (ctx.hive_guard) {
            // CHAT: observe is CONVERSATION-LOCAL — it writes only this conversation's own partition. The
            // shared cross-conversation KNOWLEDGE hive is OPT-IN via the explicit `share` tool, so N unrelated
            // chats running concurrently don't interleave their findings into one bleed-prone scope (the
            // cross-task-recall failure class). Swarm minds keep the one-hive-mind dual-write below.
            _ = ctx.mem.observe(ctx.scope, p.value.fact);
            ctx.observed.* += 1;
            return dupe(gpa, "stored in this conversation's memory. To contribute a REUSABLE fact to the shared cross-conversation hive (recallable from other chats), use `share` instead.");
        } else {
            // swarm mind (one hive mind): observe ALSO deposits into the shared KNOWLEDGE hive.
            _ = ctx.mem.observe(ctx.scope, p.value.fact);
            shared = hiveStore(ctx, p.value.fact);
        }
        ctx.observed.* += 1;
        if (!shared) return dupe(gpa, "stored in this conversation's own memory (kept OUT of the cross-conversation hive: the fact pins this build's files/lines/workdir, which mean nothing in other tasks)");
        const total = ctx.mem.factCount(KNOWLEDGE_SCOPE);
        return std.fmt.allocPrint(gpa, "stored — shared with the hive ({d} collective facts)", .{total}) catch dupe(gpa, "stored, shared with the hive");
    }
    if (std.mem.eql(u8, name, "recall")) {
        const A = struct { query: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        // saturation spread: follow the associative threads until the activation wave settles (neuron-db
        // breaks on frontier drain) — k + decay + trust bound the output, not a fixed hop budget.
        // FAMILY-WIDE for sub-chats: a "chat:<parent>__sN" scope recalls across its whole family base
        // (primary + sibling branches); every other scope is its own base — behavior unchanged.
        // BREADTH: 10 on the chat surfaces (durable_path is set there and nowhere else), measured 2026-10-20 on a
        // crowded conversation (stub A/B): k=8 surfaced 3/5 needle facts where 10, 12, 16 and 24 all surfaced 4/5,
        // so 8 was worse and wider only added bytes (~170 B per extra two lines). A swarm mind keeps the 8 it
        // has always run at (its Mem carries an environ, so its number always reached the CLI); unmeasured there.
        const recall_k: u32 = if (ctx.durable_path.len > 0) 10 else 8;
        const r = ctx.mem.assocAcross(cpaths.scopeFamilyBase(ctx.scope), p.value.query, Mem.SATURATE_HOPS, recall_k);
        // DURABLE half: the user's cross-conversation facts live in memories.jsonl, which the associative
        // store never indexed. Without this join recall denied facts that were in the same prompt — see
        // durableRecall. Chat surfaces only (durable_path is empty for every swarm mind), so a mind's recall
        // behaves exactly as before.
        var dur: []u8 = ""[0..0];
        if (ctx.durable_path.len > 0) {
            if (std.Io.Dir.cwd().readFileAlloc(ctx.io, ctx.durable_path, gpa, .limited(256 << 10))) |data| {
                defer gpa.free(data);
                dur = durableRecall(gpa, data, p.value.query);
            } else |_| {}
        }
        defer if (dur.len > 0) gpa.free(dur);
        if (r.len == 0) {
            gpa.free(r);
            // SEMANTIC RESCUE: the spread found no lexically-linked facts. Before declaring
            // emptiness — an empty tool result reads as an authoritative "no" to the model and
            // overrides its own context (the durableRecall lesson, one shelf up) — ask flat
            // recall, whose semantic fallback + topic gate (neuron-db `semantic`/`semantic-db`)
            // can resolve a paraphrase that shares NO words with the stored fact. A lexical-only
            // neuron binary misses here identically, so this join is fail-open by construction.
            const one = ctx.mem.recall(cpaths.scopeFamilyBase(ctx.scope), p.value.query);
            defer if (one.len > 0) gpa.free(one);
            const one_t = std.mem.trim(u8, one, " \r\n\t");
            if (one_t.len > 0) {
                if (dur.len == 0) return std.fmt.allocPrint(gpa, "recalled by MEANING (no exact-word match — verify it fits the ask):\n{s}", .{one_t}) catch dupe(gpa, "(nothing recalled yet)");
                return std.fmt.allocPrint(gpa, "{s}\nrecalled by MEANING (no exact-word match — verify it fits the ask):\n{s}", .{ dur, one_t }) catch dupe(gpa, dur);
            }
            if (dur.len == 0) return dupe(gpa, "(nothing recalled yet)");
            return dupe(gpa, dur);
        }
        if (dur.len == 0) return r;
        defer gpa.free(r);
        return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ dur, r }) catch dupe(gpa, dur);
    }
    if (std.mem.eql(u8, name, "share")) {
        const A = struct { fact: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        if (std.mem.trim(u8, p.value.fact, " \r\n\t").len == 0) return dupe(gpa, "empty, nothing shared");
        if (ctx.mem_sink) |sink| {
            sink.push(.fact, p.value.fact, "");
            return dupe(gpa, "noted — will be checked against what actually happened before it's shared with the hive");
        }
        if (!hiveStore(ctx, p.value.fact)) {
            _ = ctx.mem.observe(ctx.scope, p.value.fact);
            return dupe(gpa, "kept in this conversation's own memory instead of the hive — the fact pins THIS build's files/lines, which are meaningless in other tasks; share only reusable knowledge");
        }
        const total = ctx.mem.factCount(KNOWLEDGE_SCOPE);
        return std.fmt.allocPrint(gpa, "shared with the hive ({d} collective facts; every teammate can now recall_hive it)", .{total}) catch dupe(gpa, "shared");
    }
    if (std.mem.eql(u8, name, "recall_hive")) {
        const A = struct { query: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        // ACROSS the knowledge base scope AND its knowledge__doc-* document sub-scopes (one spawn),
        // so an absorbed book/doc is reachable from plain hive recall without knowing its scope name.
        const core = ctx.mem.assocAcross(KNOWLEDGE_SCOPE, p.value.query, 1, 12);
        defer gpa.free(core);
        const learned = ctx.mem.assoc(INTEL_SCOPE, p.value.query, 1, 12);
        defer gpa.free(learned);
        // skills ride the same recall: a saved technique nobody can recall is stored-and-forgotten —
        // the exact failure mode this tool exists to prevent for knowledge.
        const skills = ctx.mem.assoc(SKILL_SCOPE, p.value.query, 1, 6);
        defer gpa.free(skills);
        if (core.len == 0 and learned.len == 0 and skills.len == 0) return dupe(gpa, "(the hive knows nothing relevant yet — be the first to share something)");
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        for ([_][]const u8{ core, learned, skills }) |part| {
            if (part.len == 0) continue;
            var pit = std.mem.splitScalar(u8, part, '\n');
            while (pit.next()) |ln| {
                // LEXICAL RELEVANCE FLOOR (engine.hiveRelevant's twin thresholds): spreading recall always
                // returns its argmax, so a scope holding ANY residue answers EVERY query with it — observed
                // live: a zoo-facts task recalled book prose sharing one incidental stem. Keep a hit only
                // when it shares >=2 distinct query terms, or one term of >=8 chars (a rare specific word).
                // The LLM rerank below still refines further when a gateway is configured.
                if (!lexRelevant(p.value.query, ln)) continue;
                if (out.items.len > 0) out.append(gpa, '\n') catch {};
                out.appendSlice(gpa, ln) catch {};
            }
        }
        if (out.items.len == 0) return dupe(gpa, "(the hive holds facts but none share real vocabulary with that query — refine the query, or research it externally rather than assuming the hive already knows)");
        // SECOND-STAGE RERANK: first-stage assoc always returns its argmax even when nothing truly matches the
        // query. When a gateway (BYOK) endpoint is configured and there's a real field to reorder, judge the
        // hits against the query through the selected API: reorder+filter to the genuinely-relevant ones, or
        // ABSTAIN so the mind is told the hive has nothing relevant instead of chasing off-topic facts. Falls
        // through to the raw recall on any failure — never worse than first-stage. (See rerank.zig.)
        var cands: std.ArrayListUnmanaged([]const u8) = .empty;
        defer cands.deinit(gpa);
        var lit = std.mem.splitScalar(u8, out.items, '\n');
        while (lit.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \r\t-•*");
            if (t.len >= 8) cands.append(gpa, t) catch {};
        }
        if (ctx.gw_model.len > 0 and cands.items.len > 4) {
            const rr = rerank.rerank(gpa, ctx.io, ctx.run_dir, ctx.gw_base, ctx.gw_key, ctx.gw_model, p.value.query, cands.items, 8);
            defer rr.deinit(gpa);
            switch (rr.outcome) {
                .abstain => return dupe(gpa, "(the hive holds facts but none rank as relevant to that query — refine the query, or research it externally rather than assuming the hive already knows)"),
                .reranked => {
                    var ro: std.ArrayListUnmanaged(u8) = .empty;
                    defer ro.deinit(gpa);
                    for (rr.order) |idx| {
                        if (ro.items.len > 0) ro.append(gpa, '\n') catch {};
                        ro.appendSlice(gpa, cands.items[idx]) catch {};
                    }
                    if (ro.items.len > 0) return dupe(gpa, ro.items);
                },
                .passthrough => {},
            }
        }
        return dupe(gpa, out.items);
    }
    if (std.mem.eql(u8, name, "read_doc")) {
        const A = struct { scope: []const u8 = "", name: []const u8 = "", from: u32 = 0, limit: u32 = 0 };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        var scb: [96]u8 = undefined;
        var scope: []const u8 = p.value.scope;
        if (scope.len == 0 and p.value.name.len > 0) scope = ragingest.docScope(KNOWLEDGE_SCOPE, p.value.name, &scb);
        if (scope.len == 0) {
            // no target given: list the stored document scopes so the model can pick one
            const ids = ctx.mem.scopeIds();
            defer gpa.free(ids);
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(gpa);
            var it = std.mem.splitScalar(u8, ids, '\n');
            const pfx = KNOWLEDGE_SCOPE ++ "__doc-";
            while (it.next()) |ln| {
                const id = std.mem.trim(u8, ln, " \r\t");
                if (!std.mem.startsWith(u8, id, pfx)) continue;
                out.print(gpa, "{s} ({d} facts)\n", .{ id, ctx.mem.factCount(id) }) catch {};
            }
            if (out.items.len == 0) return dupe(gpa, "no stored documents yet — absorb a file first, then read_doc its scope");
            return std.fmt.allocPrint(gpa, "stored documents:\n{s}call read_doc again with scope set to one of these.", .{out.items}) catch dupe(gpa, "oom");
        }
        const total = ctx.mem.factCount(scope);
        if (total == 0) return std.fmt.allocPrint(gpa, "scope '{s}' is empty or unknown — call read_doc with no args to list the stored documents", .{scope}) catch dupe(gpa, "empty scope");
        const limit: u32 = if (p.value.limit > 0) @min(p.value.limit, 400) else 120;
        const page = ctx.mem.readPage(scope, p.value.from, limit);
        defer gpa.free(page);
        var got: u32 = 0;
        {
            var itl = std.mem.splitScalar(u8, page, '\n');
            while (itl.next()) |l| {
                if (std.mem.trim(u8, l, " \r\t").len > 0) got += 1;
            }
        }
        if (got == 0) return std.fmt.allocPrint(gpa, "[{s}: no facts at {d}..; the document has {d} — start from a smaller 'from']", .{ scope, p.value.from, total }) catch dupe(gpa, "past the end");
        const from = p.value.from;
        const next = from + got;
        const body_txt = std.mem.trimEnd(u8, page, "\r\n");
        if (next < total)
            return std.fmt.allocPrint(gpa, "[{s} facts {d}..{d} of {d}]\n{s}\n[more — continue with read_doc {{\"scope\":\"{s}\",\"from\":{d}}}]", .{ scope, from, next - 1, total, body_txt, scope, next }) catch dupe(gpa, body_txt);
        return std.fmt.allocPrint(gpa, "[{s} facts {d}..{d} of {d} — END]\n{s}", .{ scope, from, next - 1, total, body_txt }) catch dupe(gpa, body_txt);
    }
    if (std.mem.eql(u8, name, "stop_process")) return stopProcessTool(ctx, args_json);
    if (std.mem.eql(u8, name, "poll")) return pollTool(ctx, args_json);
    if (std.mem.eql(u8, name, "probe")) {
        if (ctx.space.len == 0) return dupe(gpa, "this swarm has no spatial grid (the task isn't spatial) — there is nothing to probe");
        const A = struct { x: i64 = -1, y: i64 = -1 };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        if (p.value.x < 0 or p.value.y < 0) return dupe(gpa, "probe needs integer x>=0 and y>=0 (column, row)");
        if (ctx.band_y1 > ctx.band_y0 and (p.value.y < ctx.band_y0 or p.value.y >= ctx.band_y1))
            return std.fmt.allocPrint(gpa, "row {d} is a teammate's region — YOUR band is rows {d}..{d}. A teammate is probing row {d}; read the Discovered map for it instead of re-probing. Probe an un-probed cell in YOUR rows, or if your band is fully mapped, start the reconstruction.", .{ p.value.y, ctx.band_y0, ctx.band_y1 - 1, p.value.y }) catch dupe(gpa, "out of your band");
        const x: usize = @intCast(p.value.x);
        const y: usize = @intCast(p.value.y);
        const cell = probeCell(gpa, ctx.space, x, y) orelse
            return std.fmt.allocPrint(gpa, "({d},{d}) is outside the grid — probe within bounds", .{ x, y }) catch dupe(gpa, "out of bounds");
        defer gpa.free(cell);
        const safe = oneLine(gpa, cell);
        defer gpa.free(safe);
        const rec = std.fmt.allocPrint(gpa, "cell ({d},{d}) = {s}", .{ x, y, safe }) catch return dupe(gpa, "oom");
        defer gpa.free(rec);
        _ = ctx.mem.observe(SPACE_SCOPE, rec);
        return std.fmt.allocPrint(gpa, "cell ({d},{d}) = {s}  [recorded to the shared map; teammates can now see it — probe a DIFFERENT cell next]", .{ x, y, safe }) catch dupe(gpa, "probed");
    }
    if (std.mem.eql(u8, name, "note_stance")) {
        const A = struct { topic: []const u8 = "", feeling: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        if (ctx.mem_sink) |sink| {
            sink.push(.stance, p.value.topic, p.value.feeling);
            return dupe(gpa, "noted");
        }
        ctx.mem.stance(ctx.scope, p.value.topic, p.value.feeling);
        return dupe(gpa, "noted");
    }
    if (std.mem.eql(u8, name, "save_skill")) {
        const A = struct { name: []const u8 = "", skill: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        if (std.mem.trim(u8, p.value.skill, " \r\n\t").len == 0) return dupe(gpa, "empty skill, nothing saved");
        if (p.value.name.len >= 3) {
            // Exact-name dedup FIRST, via the mirrored skills/<slug>.md — deterministic where semantic recall
            // is not: recall abstains on path-shaped names like 'veil/data/links.json', and concurrent minds
            // race the observe, so the recall guard alone lets parallel minds re-save the same skill.
            var slug_buf: [64]u8 = undefined;
            const slug = slugify(&slug_buf, p.value.name);
            const mirrored = std.fmt.allocPrint(gpa, "{s}/skills/{s}.md", .{ ctx.workdir, slug }) catch "";
            defer if (mirrored.len > 0) gpa.free(mirrored);
            if (mirrored.len > 0) {
                const prior = std.Io.Dir.cwd().readFileAlloc(ctx.io, mirrored, gpa, .limited(1 << 20)) catch &[_]u8{};
                defer if (prior.len > 0) gpa.free(prior);
                if (prior.len > 0)
                    return std.fmt.allocPrint(gpa, "skill '{s}' is already in the shared library (skills/{s}.md) — not re-saved; read_file it to reuse it", .{ p.value.name, slug }) catch dupe(gpa, "already saved");
            }
            const existing = ctx.mem.recall(SKILL_SCOPE, p.value.name);
            defer gpa.free(existing);
            if (std.mem.indexOf(u8, existing, p.value.name) != null)
                return std.fmt.allocPrint(gpa, "skill '{s}' is already in the shared library — not re-saved (reuse it)", .{p.value.name}) catch dupe(gpa, "already saved");
        }
        const text = std.fmt.allocPrint(gpa, "{s}: {s}", .{ p.value.name, p.value.skill }) catch return dupe(gpa, "oom");
        defer gpa.free(text);
        _ = ctx.mem.observe(SKILL_SCOPE, text);
        ctx.skills_saved.* += 1;
        mirrorSkill(ctx, p.value.name, p.value.skill);
        const total = ctx.mem.factCount(SKILL_SCOPE);
        return std.fmt.allocPrint(gpa, "skill saved to the shared library ({d} skills total)", .{total}) catch dupe(gpa, "skill saved");
    }
    if (std.mem.eql(u8, name, "journal")) {
        const A = struct { entry: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const entry = std.mem.trim(u8, p.value.entry, " \r\n\t");
        if (entry.len == 0) return dupe(gpa, "empty entry, nothing written");
        // one file per mind, append-only, round-stamped. A mind runs single-threaded within its moment and
        // only ever writes its OWN file, so read-concat-swap needs no cross-mind lock; the atomic replace
        // keeps concurrent READERS (teammates read_file-ing a journal) safe from torn content.
        var slug_buf: [64]u8 = undefined;
        const slug = slugify(&slug_buf, ctx.mind);
        const full = std.fmt.allocPrint(gpa, "{s}/journal/{s}.md", .{ ctx.workdir, slug }) catch return dupe(gpa, "oom");
        defer gpa.free(full);
        const prev = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(4 << 20)) catch (gpa.dupe(u8, "") catch return dupe(gpa, "oom"));
        defer gpa.free(prev);
        const head: []const u8 = if (prev.len == 0) "'s journal\n" else "";
        const title: []const u8 = if (prev.len == 0) ctx.mind else "";
        const hash: []const u8 = if (prev.len == 0) "# " else "";
        const body = std.fmt.allocPrint(gpa, "{s}{s}{s}{s}\n## round {d}\n\n{s}\n", .{ prev, hash, title, head, ctx.round, entry }) catch return dupe(gpa, "oom");
        defer gpa.free(body);
        if (!writeWorkFileAtomic(ctx, full, body)) return dupe(gpa, "could not write the journal file");
        return std.fmt.allocPrint(gpa, "journal entry written to journal/{s}.md — it is yours; teammates can read it", .{slug}) catch dupe(gpa, "journal entry written");
    }
    if (std.mem.eql(u8, name, "set_directive")) {
        const A = struct { directive: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const d = std.mem.trim(u8, p.value.directive, " \r\n\t");
        if (d.len < 8) return dupe(gpa, "directive too short, nothing added");
        const existing = ctx.mem.recall(PLAYBOOK_SCOPE, d);
        defer gpa.free(existing);
        if (existing.len > 0) {
            const cov = std.mem.indexOf(u8, existing, "coverage:") != null;
            if (!cov and std.mem.indexOf(u8, existing, d[0..@min(d.len, 24)]) != null)
                return dupe(gpa, "a similar directive is already in the playbook — not added");
        }
        _ = ctx.mem.observe(PLAYBOOK_SCOPE, d);
        ctx.directives_set.* += 1;
        const total = ctx.mem.factCount(PLAYBOOK_SCOPE);
        return std.fmt.allocPrint(gpa, "added to the operating playbook ({d} directives — all minds follow it now)", .{total}) catch dupe(gpa, "directive added");
    }
    if (std.mem.eql(u8, name, "propose_plan_change")) {
        const A = struct { rationale: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const d = std.mem.trim(u8, p.value.rationale, " \r\n\t");
        if (d.len < 8) return dupe(gpa, "rationale too short, nothing proposed");
        _ = ctx.mem.observe(PLAN_REQ_SCOPE, d);
        return dupe(gpa, "plan-change proposed — the engine will weigh it at the next plan revision (locked canon won't change)");
    }
    if (std.mem.eql(u8, name, "send_message")) {
        const A = struct { to: []const u8 = "all", text: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        if (ctx.mem_sink) |sink| {
            sink.push(.message, p.value.to, p.value.text);
            return std.fmt.allocPrint(gpa, "queued for {s} — checked against what actually happened before it's sent", .{p.value.to}) catch dupe(gpa, "queued");
        }
        lockFiles(ctx);
        defer unlockFiles(ctx);
        commons.sendMessage(gpa, ctx.io, ctx.run_dir, ctx.mind, p.value.to, p.value.text, ctx.round);
        return std.fmt.allocPrint(gpa, "sent to {s}", .{p.value.to}) catch dupe(gpa, "sent");
    }
    if (std.mem.eql(u8, name, "add_task")) {
        const A = struct { assignee: []const u8 = "all", task: []const u8 = "", file: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        lockFiles(ctx);
        defer unlockFiles(ctx);
        const id = commons.addTaskFile(gpa, ctx.io, ctx.run_dir, ctx.mind, p.value.assignee, p.value.task, p.value.file);
        return std.fmt.allocPrint(gpa, "task #{d} added for {s}", .{ id, p.value.assignee }) catch dupe(gpa, "task added");
    }
    if (std.mem.eql(u8, name, "claim_task")) {
        const A = struct { id: u32 = 0 };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        lockFiles(ctx);
        defer unlockFiles(ctx);
        switch (commons.claimTask(gpa, ctx.io, ctx.run_dir, p.value.id, ctx.mind)) {
            .ok => return std.fmt.allocPrint(gpa, "claimed #{d} — it is yours; build it, then complete_task", .{p.value.id}) catch dupe(gpa, "claimed"),
            .already => |owner| {
                defer gpa.free(owner);
                return std.fmt.allocPrint(gpa, "#{d} is already owned by {s} — do NOT duplicate their work; claim a different open task", .{ p.value.id, owner }) catch dupe(gpa, "already claimed");
            },
            .done_already => return std.fmt.allocPrint(gpa, "#{d} is already done — pick an open task from the TASK BOARD", .{p.value.id}) catch dupe(gpa, "already done"),
            .no_such => return std.fmt.allocPrint(gpa, "no task #{d} on the board — add_task first, or read the TASK BOARD block for real ids", .{p.value.id}) catch dupe(gpa, "no such task"),
        }
    }
    if (std.mem.eql(u8, name, "complete_task")) {
        const A = struct { id: u32 = 0, result: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        lockFiles(ctx);
        defer unlockFiles(ctx);
        commons.completeTask(gpa, ctx.io, ctx.run_dir, p.value.id, ctx.mind, p.value.result);
        return std.fmt.allocPrint(gpa, "completed #{d}", .{p.value.id}) catch dupe(gpa, "completed");
    }
    if (std.mem.eql(u8, name, "stage_delivery")) {
        const A = struct { target: []const u8 = "", summary: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const target = if (p.value.target.len > 0) p.value.target else "local-durable";
        const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{ctx.run_dir}) catch return dupe(gpa, "oom");
        defer gpa.free(mpath);
        const files = std.Io.Dir.cwd().readFileAlloc(ctx.io, mpath, gpa, .limited(64 << 10)) catch (gpa.dupe(u8, "(no build manifest)") catch @constCast(""));
        defer gpa.free(files);
        const dir = std.fmt.allocPrint(gpa, "{s}/DELIVERY", .{ctx.run_dir}) catch return dupe(gpa, "oom");
        defer gpa.free(dir);
        _ = std.Io.Dir.cwd().createDirPathStatus(ctx.io, dir, .default_dir) catch {};
        const plan = std.fmt.allocPrint(gpa,
            \\DELIVERY PLAN — STAGED, PENDING OPERATOR APPROVAL (nothing has been published)
            \\target: {s}
            \\summary: {s}
            \\staged-by: {s} (round {d})
            \\
            \\artifacts to publish (from the build, located in ./work):
            \\{s}
            \\
            \\status: PREPARED, NOT SENT. The swarm holds no credentials and has no network egress to your
            \\systems by design. To publish, a human (or a privileged broker outside this sandbox) reviews this
            \\plan and approves the action using scoped, least-privilege credentials it — not the swarm — holds.
        , .{ target, if (p.value.summary.len > 0) p.value.summary else "(no summary)", ctx.mind, ctx.round, std.mem.trim(u8, files, " \r\n\t") }) catch return dupe(gpa, "oom");
        defer gpa.free(plan);
        const planpath = std.fmt.allocPrint(gpa, "{s}/PUBLISH_PLAN.txt", .{dir}) catch return dupe(gpa, "oom");
        defer gpa.free(planpath);
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = planpath, .data = plan }) catch {};
        return std.fmt.allocPrint(gpa, "STAGED for delivery to '{s}'. A PUBLISH_PLAN was written to DELIVERY/ for the operator to review and approve. NOTE: this is PREPARED, not published — you cannot push/deploy directly (no credentials, by design); a human or privileged broker performs the actual egress after approval.", .{target}) catch dupe(gpa, "staged");
    }
    if (std.mem.eql(u8, name, "make_tool")) {
        const A = struct { name: []const u8 = "", description: []const u8 = "", params: std.json.Value = .null, body: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const nm = p.value.name;
        if (nm.len < 3 or nm.len > 32) return dupe(gpa, "rejected: name must be 3-32 chars");
        for (nm) |ch| if (!((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_')) return dupe(gpa, "rejected: name must be snake_case [a-z0-9_]");
        if (isBuiltinTool(nm)) return dupe(gpa, "rejected: that name shadows a built-in tool");
        if (p.value.body.len == 0 or p.value.body.len > MAX_TOOL_BODY) return dupe(gpa, "rejected: body empty or >8KB");
        // DRY-RUN the body as Python before it enters the registry, so a syntax error surfaces NOW instead of at
        // the tool's first (possibly much later) call. Reuses the edit paths' compile gate; fails OPEN when no
        // python is on the machine (a py-less host can still author tools — they just aren't pre-checked).
        if (pyCompileError(ctx, p.value.body, "")) |perr| {
            defer gpa.free(perr);
            return std.fmt.allocPrint(gpa, "rejected: the tool body does not compile as Python ({s}). A broken body would only fail at first call — fix it and resubmit.", .{clip(perr, 220)}) catch dupe(gpa, "rejected: body does not compile as Python");
        }
        const pj = std.json.Stringify.valueAlloc(gpa, p.value.params, .{}) catch return dupe(gpa, "rejected: bad params json");
        defer gpa.free(pj);
        if (pj.len < 2 or pj[0] != '{' or pj.len > MAX_TOOL_PARAMS) return dupe(gpa, "rejected: params must be a JSON object <=4KB");
        var norm_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer norm_buf.deinit(gpa);
        const norm: []const u8 = blk: {
            if (std.mem.indexOf(u8, pj, "\"type\":\"object\"") != null) break :blk pj;
            if (std.mem.indexOf(u8, pj, "\"properties\"") != null) {
                norm_buf.appendSlice(gpa, "{\"type\":\"object\",") catch break :blk pj;
                norm_buf.appendSlice(gpa, pj[1..]) catch break :blk pj;
                break :blk norm_buf.items;
            }
            norm_buf.appendSlice(gpa, "{\"type\":\"object\",\"properties\":") catch break :blk pj;
            norm_buf.appendSlice(gpa, pj) catch break :blk pj;
            norm_buf.appendSlice(gpa, "}") catch break :blk pj;
            break :blk norm_buf.items;
        };
        if (norm.len > MAX_TOOL_PARAMS) return dupe(gpa, "rejected: params too large after normalization");
        if (ctx.mem.factCount(TOOL_SCOPE) >= MAX_TOOLS) return dupe(gpa, "tool registry full (16) — refine or call an existing tool instead");
        const ex = ctx.mem.recall(TOOL_SCOPE, nm);
        defer gpa.free(ex);
        const tag = std.fmt.allocPrint(gpa, "{s}\x1f", .{nm}) catch return dupe(gpa, "oom");
        defer gpa.free(tag);
        if (std.mem.indexOf(u8, ex, tag) != null) return std.fmt.allocPrint(gpa, "tool '{s}' already exists — call it, don't redefine", .{nm}) catch dupe(gpa, "exists");
        const Enc = std.base64.standard.Encoder;
        const b64 = gpa.alloc(u8, Enc.calcSize(p.value.body.len)) catch return dupe(gpa, "oom");
        defer gpa.free(b64);
        _ = Enc.encode(b64, p.value.body);
        const rec = std.fmt.allocPrint(gpa, "{s}\x1f{s}\x1f{s}", .{ nm, norm, b64 }) catch return dupe(gpa, "oom");
        defer gpa.free(rec);
        _ = ctx.mem.observe(TOOL_SCOPE, rec);
        ctx.tools_made.* += 1;
        return std.fmt.allocPrint(gpa, "tool '{s}' registered — every mind can call it by name from next moment (and you can call it now)", .{nm}) catch dupe(gpa, "registered");
    }
    // RECIPE DISPATCH (I1). A granted recipe is DATA — a sequence of steps over tools the caller is already
    // allowed to run. It is matched HERE, AFTER every built-in check above (a recipe name can never collide
    // with a built-in — recipes.loadDir refuses such a name at load) and BEFORE the runAuthored fallthrough
    // below, and it RETURNS. So a recipe name can NEVER fall through to authoredBody/runAuthored and execute
    // host Python: built-ins return first, this branch returns next, and for an admin ctx.grants is the whole
    // registry (so every registry recipe is caught here), while a sandboxed caller's ungranted recipe was
    // already refused by the gate above. This ordering is the make_tool-authored-name collision guard (I1):
    // a recipe can neither shadow nor be shadowed by an authored body.
    if (grantedRecipe(ctx, name)) |rec| return runRecipe(ctx, rec, args_json);
    if (authoredBody(ctx, name)) |body| {
        defer gpa.free(body);
        return runAuthored(ctx, name, body, args_json);
    }
    return std.fmt.allocPrint(gpa, "unknown tool: {s}", .{name}) catch dupe(gpa, "unknown tool");
}

/// Run a granted recipe (I4/I5/I6): DATA, never host code. Each step is dispatched by RECURSIVELY calling
/// execute() with the step's substituted args, so every step re-hits the ONE sandbox gate under THIS caller's
/// OWN caps — an admin-authored `run_python` step is refused the instant a sandboxed grantee runs it, and that
/// refusal is SURFACED (naming the step) rather than swallowed, so the model sees WHY. Returns the `output`
/// step's result (or the last step's). gpa-owned result (caller frees), always a string, even on error.
fn runRecipe(ctx: *ToolCtx, rec: *const recipes.Recipe, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;

    // DEPTH BACKSTOP (I5). A recipe step naming another recipe is refused below, so a recipe never re-enters
    // this function by design; this guards the entry regardless, keeping one level only even if that check is
    // ever bypassed on some future path (unbounded recursion can't happen).
    if (ctx.recipe_depth > 0)
        return dupe(gpa, "recipe error: a recipe step may not run another recipe (no recipe-calls-recipe)");
    ctx.recipe_depth += 1;
    defer ctx.recipe_depth -= 1;

    // Belt-and-braces step cap (loadDir already enforces MAX_STEPS at load; this backstops a Recipe reaching
    // here by any other route).
    if (rec.steps.len > recipes.MAX_STEPS)
        return dupe(gpa, "recipe error: too many steps");

    // Scratch arena for the call's PARAM bindings — the coerced-to-string input values live here for the whole
    // step loop and are dropped in one shot. {{paramName}} → the call's arg; only the recipe's DECLARED params
    // are read (unknown args ignored), a missing arg binds empty (substitute tolerates it). A non-string arg is
    // compact-stringified so {{count}} → "5"; substitute JSON-escapes each value on splice (I6), so a hostile
    // value can never break a step's args JSON or inject a new arg.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var params_kv: std.ArrayListUnmanaged(recipes.Binding) = .empty;
    {
        const aj = if (std.mem.trim(u8, args_json, " \r\n\t").len == 0) "{}" else args_json;
        if (std.json.parseFromSlice(std.json.Value, gpa, aj, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                for (rec.params) |param| {
                    const v = parsed.value.object.get(param.name) orelse continue;
                    const val: []const u8 = switch (v) {
                        .string => |s| sa.dupe(u8, s) catch continue,
                        else => std.json.Stringify.valueAlloc(sa, v, .{}) catch continue,
                    };
                    // param.name points into the registry arena (stable for the turn) — borrow it, don't dupe.
                    params_kv.append(sa, .{ .name = param.name, .value = val }) catch {};
                }
            }
        } else |_| {}
    }

    // Prior step results: {{stepId}} → that step's result string. Each result is gpa-owned (execute returns
    // gpa-owned); we hold them here and free them all at the end. The binding NAME is the step id (registry
    // arena, stable). The output copy is taken BEFORE these frees run, so the return value is independent.
    var results_kv: std.ArrayListUnmanaged(recipes.Binding) = .empty;
    defer {
        for (results_kv.items) |b| gpa.free(b.value);
        results_kv.deinit(gpa);
    }

    for (rec.steps) |step| {
        // I5: a step tool that is itself a granted recipe is REFUSED at run time — no recipe-calls-recipe. This
        // fires BEFORE execute(), so the recursion never re-enters runRecipe through the recipe dispatch branch.
        if (grantedRecipe(ctx, step.tool) != null)
            return std.fmt.allocPrint(gpa, "recipe error: step '{s}' calls recipe '{s}' — a recipe step may not run another recipe (no recipe-calls-recipe)", .{ step.id, step.tool }) catch dupe(gpa, "recipe error: no recipe-calls-recipe");

        const step_args = recipes.substitute(gpa, step.args_json, params_kv.items, results_kv.items);
        defer gpa.free(step_args);

        // THE SAFETY PROPERTY (I4): dispatch the step RECURSIVELY through the SAME top gate under THIS caller's
        // OWN caps — exactly as if the model had called step.tool directly. A step the caller isn't allowed to
        // run hits the gate's refusal here; nothing about being inside a recipe grants extra capability.
        const res = execute(ctx, step.tool, step_args);

        // The gate refused this step (e.g. a sandboxed grantee reached an admin-authored run_python step): STOP
        // and surface WHY, naming the step, instead of splicing the refusal string into a later step's args.
        if (std.mem.eql(u8, res, SANDBOX_REFUSAL)) {
            gpa.free(res);
            return std.fmt.allocPrint(gpa, "recipe stopped at step '{s}': tool '{s}' is not available in this workspace (refused for this user — a recipe can never grant a tool the caller lacks). {s}", .{ step.id, step.tool, SANDBOX_REFUSAL }) catch dupe(gpa, SANDBOX_REFUSAL);
        }

        // Transfer ownership of the gpa-owned result into the results list (freed in the defer above).
        results_kv.append(gpa, .{ .name = step.id, .value = res }) catch {
            gpa.free(res); // couldn't record it — don't leak it
        };
    }

    // Return the `output` step's result (authored output, else the last step). Copy it out before the deferred
    // frees reclaim the stored results.
    const out_id = rec.outputStepId();
    for (results_kv.items) |b| {
        if (std.mem.eql(u8, b.name, out_id)) return dupe(gpa, b.value);
    }
    return dupe(gpa, "(recipe produced no output)");
}

/// May this caller drive the web browser?
///
/// A `.full` caller can, full stop — the admin's own chat turn, the desk, the CLI, swarm minds. Those
/// callers already hold code execution and host control, for which a headless browser is strictly the
/// smaller capability. Requiring NL_BROWSER_DRIVER on top of that gated the wrong thing: an ADMIN who
/// asked the veil to look at a web page got "browser driver disabled" in the same turn where
/// `run_python` — which can do far more, including driving a browser itself — was available.
///
/// The env var still opts a `.sandboxed` caller in, for an operator who deliberately wants web tenants
/// using the server's browser. Unset, they cannot: the browser inherits the host's network position and
/// its profile's cookies, which is not something to hand out by default.
fn browserEnabled(ctx: *ToolCtx) bool {
    if (ctx.caps == .full) return true;
    if (ctx.browser) return true; // the swarm worker's resolved decision (run.zig w.browser)
    const v = ctx.environ.get("NL_BROWSER_DRIVER") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false");
}

fn browserErr(gpa: std.mem.Allocator, e: anyerror) []u8 {
    return std.fmt.allocPrint(gpa, "browser error: {s}", .{@errorName(e)}) catch dupe(gpa, "browser error");
}

/// Dispatch a `browser_*` tool through the process-global browser session manager (keyed by run_dir). Gated by
/// NL_BROWSER_DRIVER (operator opt-in) and the offline flag; browser_navigate is additionally allowlist-gated.
fn browserDispatch(ctx: *ToolCtx, name: []const u8, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    // A client-side (roam) call is already authorized: the server only offers browser_* in the schema when the
    // OPERATOR set NL_BROWSER_DRIVER, and a direct CLI invocation is the user's own request — so don't re-gate
    // on the client's env (the desk process may not carry NL_BROWSER_DRIVER even when the server does).
    if (!ctx.roam and !browserEnabled(ctx)) return dupe(gpa, "browser driver disabled — set NL_BROWSER_DRIVER=1 on the server to offer web-browser control");
    if (!ctx.internet) return dupe(gpa, "web disabled: this is an OFFLINE run; the browser driver is unavailable");
    if (name.len <= "browser_".len) return dupe(gpa, "unknown browser tool");
    const action = name["browser_".len..]; // navigate | read | click | type | eval | close

    // browser_navigate: normalize the scheme and apply the allowlist BEFORE routing; other verbs pass args
    // through unchanged (their JSON args already match the dispatcher's expected params).
    if (std.mem.eql(u8, action, "navigate")) {
        const A = struct { url: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const raw = std.mem.trim(u8, p.value.url, " \r\n\t");
        if (raw.len == 0) return dupe(gpa, "browser_navigate needs a url");
        const url = if (std.mem.indexOf(u8, raw, "://") != null) (gpa.dupe(u8, raw) catch return dupe(gpa, "oom")) else (std.fmt.allocPrint(gpa, "https://{s}", .{raw}) catch return dupe(gpa, "oom"));
        defer gpa.free(url);
        const allow = ctx.environ.get("NL_BROWSER_ALLOWLIST") orelse "";
        if (!egressAllowed(allow, url)) return std.fmt.allocPrint(gpa, "blocked: host '{s}' is not on NL_BROWSER_ALLOWLIST", .{urlHost(url)}) catch dupe(gpa, "blocked by allowlist");
        const params = std.json.Stringify.valueAlloc(gpa, .{ .url = url }, .{}) catch return dupe(gpa, "oom");
        defer gpa.free(params);
        return browserOp(ctx, action, params);
    }
    if (std.mem.eql(u8, action, "read") or std.mem.eql(u8, action, "click") or std.mem.eql(u8, action, "type") or std.mem.eql(u8, action, "eval") or std.mem.eql(u8, action, "close") or
        std.mem.eql(u8, action, "console") or std.mem.eql(u8, action, "network") or
        std.mem.eql(u8, action, "click_at") or std.mem.eql(u8, action, "type_text") or std.mem.eql(u8, action, "key") or std.mem.eql(u8, action, "scroll"))
    {
        return browserOp(ctx, action, args_json);
    }
    return std.fmt.allocPrint(gpa, "unknown browser tool: {s}", .{name}) catch dupe(gpa, "unknown browser tool");
}

/// The routing seam. A SUBPROCESS-PER-CALL executor (`veil exec-tool`, browser_daemon=true) forwards to the
/// per-machine local-host daemon so ONE browser session survives across its separate processes. A LONG-LIVED
/// process (the server's /chat/tool endpoint, a swarm worker) keeps the session in-process — spawning a daemon
/// from it just races unreachable daemons. Both funnel through the identical manager.dispatch action set.
fn browserOp(ctx: *ToolCtx, action: []const u8, params_json: []const u8) []u8 {
    const key = ctx.run_dir;
    if (ctx.browser_daemon) return browser_host.forward(ctx.gpa, ctx.io, ctx.environ, key, action, params_json);
    return browser_mgr.dispatch(ctx.gpa, ctx.io, ctx.environ, key, action, params_json);
}

/// Dispatch a `pixel_*` tool (Pixel RAG). pixel_ingest / pixel_capture RENDER a live page, so they stay gated by
/// NL_BROWSER_DRIVER + the offline flag (pixel_ingest is also allowlist-gated like browser_navigate). pixel_search
/// is pure LOCAL retrieval over the already-indexed manifest — it renders nothing and touches no network, so it is
/// UNGATED: it must work with no browser driver and OFFLINE to retrieve an OCR'd image attachment or a prior capture.
fn pixelDispatch(ctx: *ToolCtx, name: []const u8, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;

    if (std.mem.eql(u8, name, "pixel_search")) {
        const A = struct { query: []const u8 = "", k: u32 = 4 };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        if (std.mem.trim(u8, p.value.query, " \r\n\t").len == 0) return dupe(gpa, "pixel_search needs a query");
        return pixelrag.search(gpa, ctx.io, ctx.run_dir, p.value.query, p.value.k);
    }

    if (!ctx.roam and !browserEnabled(ctx)) return dupe(gpa, "pixel rag disabled — set NL_BROWSER_DRIVER=1 on the server (it renders pages in the browser)");
    if (!ctx.internet) return dupe(gpa, "web disabled: this is an OFFLINE run; pixel rag is unavailable");

    if (std.mem.eql(u8, name, "pixel_ingest")) {
        const A = struct { url: []const u8 = "", doc_id: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const rawu = std.mem.trim(u8, p.value.url, " \r\n\t");
        if (rawu.len == 0) return dupe(gpa, "pixel_ingest needs a url");
        const url = if (std.mem.indexOf(u8, rawu, "://") != null) (gpa.dupe(u8, rawu) catch return dupe(gpa, "oom")) else (std.fmt.allocPrint(gpa, "https://{s}", .{rawu}) catch return dupe(gpa, "oom"));
        defer gpa.free(url);
        const allow = ctx.environ.get("NL_BROWSER_ALLOWLIST") orelse "";
        if (!egressAllowed(allow, url)) return std.fmt.allocPrint(gpa, "blocked: host '{s}' is not on NL_BROWSER_ALLOWLIST", .{urlHost(url)}) catch dupe(gpa, "blocked by allowlist");
        // browser_daemon ⇒ render on the machine's local-host daemon (subprocess-per-call needs the persistent
        // browser); else render in-process (server/swarm/CLI-direct keep their own session).
        return pixelrag.ingest(gpa, ctx.io, ctx.environ, ctx.run_dir, ctx.mem, url, p.value.doc_id, ctx.browser_daemon);
    }
    if (std.mem.eql(u8, name, "pixel_capture")) {
        const A = struct { doc_id: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch
            return dupe(gpa, "pixel_capture: could not parse args JSON");
        defer p.deinit();
        return pixelrag.capture(gpa, ctx.io, ctx.environ, ctx.run_dir, ctx.mem, p.value.doc_id, ctx.browser_daemon);
    }
    return std.fmt.allocPrint(gpa, "unknown pixel tool: {s}", .{name}) catch dupe(gpa, "unknown pixel tool");
}

/// May this caller use MCP? Same reasoning as browserEnabled: a `.full` caller already holds code
/// execution, and mcp_call spawning a local server process is a smaller capability than run_python
/// spawning whatever it likes. The env var remains the opt-in for `.sandboxed` callers, and stays off
/// by default there — those servers run with the host owner's own credentials.
fn mcpEnabled(ctx: *ToolCtx) bool {
    if (ctx.caps == .full) return true;
    const v = ctx.environ.get("NL_MCP") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false");
}

/// Dispatch an `mcp_*` tool: find + use the AI-ready MCP servers installed on the machine. Self-contained
/// (one-shot per call), so it runs correctly on the client (delegated) or server without a daemon.
fn mcpDispatch(ctx: *ToolCtx, name: []const u8, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    if (!ctx.roam and !mcpEnabled(ctx)) return dupe(gpa, "MCP disabled — set NL_MCP=1 on the server to let the assistant find and use local MCP servers");

    if (std.mem.eql(u8, name, "mcp_discover")) {
        const A = struct { server: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const srv = std.mem.trim(u8, p.value.server, " \r\n\t");
        if (srv.len == 0) return mcp_discovery.discoverAll(gpa, ctx.io, ctx.environ);
        return mcp_discovery.serverTools(gpa, ctx.io, ctx.environ, srv);
    }
    if (std.mem.eql(u8, name, "mcp_call")) {
        const A = struct { server: []const u8 = "", tool: []const u8 = "", args: std.json.Value = .null };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        if (std.mem.trim(u8, p.value.server, " \r\n\t").len == 0 or std.mem.trim(u8, p.value.tool, " \r\n\t").len == 0) return dupe(gpa, "mcp_call needs a server and a tool");
        const args_str = switch (p.value.args) {
            .object => std.json.Stringify.valueAlloc(gpa, p.value.args, .{}) catch return dupe(gpa, "oom"),
            else => gpa.dupe(u8, "{}") catch return dupe(gpa, "oom"),
        };
        defer gpa.free(args_str);
        return mcp_discovery.callServer(gpa, ctx.io, ctx.environ, p.value.server, p.value.tool, args_str);
    }
    return std.fmt.allocPrint(gpa, "unknown mcp tool: {s}", .{name}) catch dupe(gpa, "unknown mcp tool");
}

/// The ONE preparation every child environment this file builds goes through, so no spawn site can forget half
/// of it: (1) force Python children to UTF-8 IO — Windows Python defaults stdout/stderr to the ANSI codepage
/// (cp1252), so the first non-ASCII char a script prints ('→', '·', any emoji) kills it with UnicodeEncodeError:
/// 'charmap' — observed live when a build's own test runner printed an arrow; harmless on POSIX and for
/// non-Python children. (2) Merge the tool-env overlay (below): what `tool_env` persisted — PATH entries an
/// installer added after this process started, NL_PYTHON_BIN and the like — so the child sees it with no restart.
pub fn prepChildEnv(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) void {
    env.put("PYTHONUTF8", "1") catch {};
    env.put("PYTHONIOENCODING", "utf-8") catch {};
    applyToolEnv(gpa, io, env);
}

// ------------------------------------------------------------------------------------ the tool-env overlay
//
// A PATH change an installer makes (winget/brew/apt) is invisible to the running veil: a process's environment
// is a copy taken at start. So a model that just installed python with run_shell would still get "python not
// found" from run_python until someone restarted veil. The overlay closes that: {data}/tool-env.json, a JSON
// object of env name → value plus a "PATH_PREPEND" array of directories, merged into EVERY child environment
// built here (prepChildEnv) and into deps.probe, and re-read on every spawn — so a `tool_env` run through `veil
// exec-tool` (a separate process, the desk's route) is seen by the server's next spawn, and a restart changes
// nothing. The path is registered once per process (setToolEnvPath); unregistered, nothing changes.

const TOOL_ENV_BASENAME = "tool-env.json";
const TOOL_ENV_MAX = 64 << 10;
var tool_env_store: [4096 + 32]u8 = undefined;
var tool_env_store_len: usize = 0;

/// Point the overlay at {data}/tool-env.json. Called once at boot by every process that runs tools (the server
/// in main.zig, a swarm worker in run.zig, `veil exec-tool`), all with the same data dir. Copied, so a caller's
/// stack buffer may go. Unit tests point it at a scratch dir and clear it (clearToolEnvPath) when done.
pub fn setToolEnvPath(data_dir: []const u8) void {
    tool_env_store_len = 0;
    const p = std.fmt.bufPrint(&tool_env_store, "{s}/" ++ TOOL_ENV_BASENAME, .{data_dir}) catch return;
    tool_env_store_len = p.len;
}

pub fn clearToolEnvPath() void {
    tool_env_store_len = 0;
}

fn toolEnvPath() ?[]const u8 {
    return if (tool_env_store_len == 0) null else tool_env_store[0..tool_env_store_len];
}

fn readToolEnv(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const path = toolEnvPath() orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(TOOL_ENV_MAX)) catch null;
}

/// Merge the registered overlay into `env`. A missing or unreadable file is "no overlay".
fn applyToolEnv(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) void {
    const bytes = readToolEnv(gpa, io) orelse return;
    defer gpa.free(bytes);
    applyToolEnvJson(gpa, env, bytes);
}

/// A clone of `env` with the overlay applied, or null when no overlay is registered or readable (the caller
/// then uses `env` as is). For a reader that takes a const map (deps.probe).
pub fn overlaidEnv(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?std.process.Environ.Map {
    const bytes = readToolEnv(gpa, io) orelse return null;
    defer gpa.free(bytes);
    var m = env.clone(gpa) catch return null;
    applyToolEnvJson(gpa, &m, bytes);
    return m;
}

/// The pure merge: every string member becomes an env var (a name the map would refuse is skipped, never
/// asserted on); "PATH_PREPEND" is an array of directories put in front of the child's PATH, in order, each
/// once, and none that PATH already holds. Malformed JSON applies nothing.
pub fn applyToolEnvJson(gpa: std.mem.Allocator, env: *std.process.Environ.Map, bytes: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "PATH_PREPEND")) {
            if (kv.value_ptr.* != .array) continue;
            var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
            defer dirs.deinit(gpa);
            for (kv.value_ptr.array.items) |d| if (d == .string) dirs.append(gpa, d.string) catch {};
            prependPath(gpa, env, dirs.items);
            continue;
        }
        if (kv.value_ptr.* != .string) continue;
        if (!std.process.Environ.Map.validateKeyForPut(kv.key_ptr.*)) continue;
        env.put(kv.key_ptr.*, kv.value_ptr.string) catch {};
    }
}

/// Two PATH entries name the same directory when they match byte for byte, or on Windows regardless of case
/// (its file system is), with a trailing separator ignored on both sides.
fn samePathEntry(a: []const u8, b: []const u8) bool {
    const ta = std.mem.trimEnd(u8, a, "/\\");
    const tb = std.mem.trimEnd(u8, b, "/\\");
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(ta, tb) else std.mem.eql(u8, ta, tb);
}

/// Put `dirs` in front of the child's PATH: each once, skipping any PATH already holds, blanks dropped. The map
/// is case-insensitive on Windows, so "PATH" finds the block's "Path" and the put keeps that key.
fn prependPath(gpa: std.mem.Allocator, env: *std.process.Environ.Map, dirs: []const []const u8) void {
    const existing = env.get("PATH") orelse "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var added: std.ArrayListUnmanaged([]const u8) = .empty;
    defer added.deinit(gpa);
    for (dirs) |raw| {
        const d = std.mem.trim(u8, raw, " \r\n\t");
        if (d.len == 0) continue;
        var dup = false;
        for (added.items) |a| if (samePathEntry(a, d)) {
            dup = true;
            break;
        };
        if (!dup) {
            var pit = std.mem.splitScalar(u8, existing, std.fs.path.delimiter);
            while (pit.next()) |e| if (samePathEntry(e, d)) {
                dup = true;
                break;
            };
        }
        if (dup) continue;
        added.append(gpa, d) catch return;
        out.appendSlice(gpa, d) catch return;
        out.append(gpa, std.fs.path.delimiter) catch return;
    }
    if (added.items.len == 0) return;
    out.appendSlice(gpa, existing) catch return;
    env.put("PATH", std.mem.trimEnd(u8, out.items, &.{std.fs.path.delimiter})) catch {};
}

/// Read the overlay file as a JSON object to edit in `arena`; a missing or malformed file is an empty object.
fn loadToolEnvObject(arena: std.mem.Allocator, io: std.Io) std.json.Value {
    const empty = std.json.Value{ .object = .empty };
    const bytes = readToolEnv(arena, io) orelse return empty;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return empty;
    return if (v == .object) v else empty;
}

fn saveToolEnvObject(gpa: std.mem.Allocator, io: std.Io, v: std.json.Value) bool {
    const path = toolEnvPath() orelse return false;
    const text = std.json.Stringify.valueAlloc(gpa, v, .{ .whitespace = .indent_2 }) catch return false;
    defer gpa.free(text);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch return false;
    return true;
}

/// A name `tool_env set` accepts: what every shell and the map itself take, so a bad name is refused in words
/// rather than tripping the map's assert.
fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    for (name, 0..) |c, i| switch (c) {
        'A'...'Z', 'a'...'z', '_' => {},
        '0'...'9' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

const TOOL_ENV_APPLIES = "applies to every tool run from now on in this veil and after restarts; no restart needed";

/// Windows: the machine + user PATH as the registry holds them NOW — what a fresh process would get — read with
/// bounded `reg query` calls (an installer's change lands there, never in this process's copy). The value line
/// is `    Path    REG_SZ|REG_EXPAND_SZ    <value>`; nothing is expanded, so a %SystemRoot% entry stays literal.
/// POSIX: a login shell's PATH (`sh -lc`), which is where a package manager's profile edits take effect. Returns
/// gpa-owned entries, machine first (the order Windows builds PATH in), or an error note when neither read ran.
fn livePathEntries(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |e| gpa.free(e);
        out.deinit(gpa);
    }
    if (builtin.os.tag == .windows) {
        const keys = [_][]const u8{ "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment", "HKCU\\Environment" };
        var any = false;
        for (keys) |key| {
            const argv = [_][]const u8{ "reg", "query", key, "/v", "Path" };
            var r = bounded.run(gpa, io, .{ .argv = &argv, .environ_map = env, .bound_ms = 10_000, .stdout_limit = 64 << 10, .stderr_limit = 8 << 10 });
            defer r.deinit(gpa);
            if (!r.ok()) continue; // HKCU may hold no Path at all: a normal answer, not an error
            any = true;
            var lines = std.mem.tokenizeAny(u8, r.stdout, "\r\n");
            while (lines.next()) |ln| {
                const t = std.mem.trim(u8, ln, " \t");
                if (!std.mem.startsWith(u8, t, "Path")) continue;
                const kind = std.mem.indexOf(u8, t, "REG_") orelse continue;
                const after = std.mem.indexOfAnyPos(u8, t, kind, " \t") orelse continue;
                var dirs = std.mem.splitScalar(u8, std.mem.trim(u8, t[after..], " \t"), ';');
                while (dirs.next()) |d| {
                    const dt = std.mem.trim(u8, d, " \t");
                    if (dt.len > 0) try out.append(gpa, try gpa.dupe(u8, dt));
                }
            }
        }
        if (!any) return error.PathUnread;
    } else {
        const argv = [_][]const u8{ "sh", "-lc", "printf %s \"$PATH\"" };
        var r = bounded.run(gpa, io, .{ .argv = &argv, .environ_map = env, .bound_ms = 10_000, .stdout_limit = 64 << 10, .stderr_limit = 8 << 10 });
        defer r.deinit(gpa);
        if (!r.ok()) return error.PathUnread;
        var dirs = std.mem.splitScalar(u8, r.stdout, ':');
        while (dirs.next()) |d| {
            const dt = std.mem.trim(u8, d, " \r\n\t");
            if (dt.len > 0) try out.append(gpa, try gpa.dupe(u8, dt));
        }
    }
    return out.toOwnedSlice(gpa);
}

/// tool_env — persist an env change for every tool run from now on (see the overlay note above).
///   set:          name=value into the overlay; name "PATH" appends value to PATH_PREPEND instead
///   refresh_path: PATH_PREPEND := the machine's live PATH (registry / login shell), so a just-installed program
///                 is found without restarting veil
///   show:         the overlay as stored
fn toolEnvTool(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { action: []const u8 = "", name: []const u8 = "", value: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const action = std.mem.trim(u8, p.value.action, " \r\n\t");
    if (toolEnvPath() == null) return dupe(gpa, "tool_env is not available in this process (no data dir registered for the overlay)");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var obj = loadToolEnvObject(arena, ctx.io);

    if (std.mem.eql(u8, action, "show")) {
        const text = std.json.Stringify.valueAlloc(gpa, obj, .{ .whitespace = .indent_2 }) catch return dupe(gpa, "oom");
        defer gpa.free(text);
        return std.fmt.allocPrint(gpa, "tool-env overlay ({s}):\n{s}", .{ TOOL_ENV_APPLIES, text }) catch dupe(gpa, "oom");
    }
    if (std.mem.eql(u8, action, "set")) {
        const name = std.mem.trim(u8, p.value.name, " \r\n\t");
        const value = std.mem.trim(u8, p.value.value, " \r\n\t");
        if (!validEnvName(name)) return dupe(gpa, "tool_env set: name must be letters, digits and underscores, not starting with a digit");
        if (std.mem.eql(u8, name, "PATH")) {
            if (value.len == 0) return dupe(gpa, "tool_env set PATH: give the directory to put in front of PATH as value");
            var list: std.json.Array = if (obj.object.get("PATH_PREPEND")) |cur| (if (cur == .array) cur.array else std.json.Array.init(arena)) else std.json.Array.init(arena);
            for (list.items) |d| if (d == .string and samePathEntry(d.string, value)) {
                return std.fmt.allocPrint(gpa, "already in front of the tool PATH: {s} ({s})", .{ value, TOOL_ENV_APPLIES }) catch dupe(gpa, "oom");
            };
            list.append(.{ .string = arena.dupe(u8, value) catch return dupe(gpa, "oom") }) catch return dupe(gpa, "oom");
            obj.object.put(arena, "PATH_PREPEND", .{ .array = list }) catch return dupe(gpa, "oom");
            if (!saveToolEnvObject(gpa, ctx.io, obj)) return dupe(gpa, "tool_env: could not write the overlay file");
            return std.fmt.allocPrint(gpa, "PATH now starts with {s} for tool runs ({s})", .{ value, TOOL_ENV_APPLIES }) catch dupe(gpa, "oom");
        }
        obj.object.put(arena, arena.dupe(u8, name) catch return dupe(gpa, "oom"), .{ .string = arena.dupe(u8, value) catch return dupe(gpa, "oom") }) catch return dupe(gpa, "oom");
        if (!saveToolEnvObject(gpa, ctx.io, obj)) return dupe(gpa, "tool_env: could not write the overlay file");
        return std.fmt.allocPrint(gpa, "{s}={s} set for tool runs ({s})", .{ name, value, TOOL_ENV_APPLIES }) catch dupe(gpa, "oom");
    }
    if (std.mem.eql(u8, action, "refresh_path")) {
        const entries = livePathEntries(gpa, ctx.io, ctx.environ) catch
            return dupe(gpa, if (builtin.os.tag == .windows) "tool_env refresh_path: could not read the machine PATH from the registry (reg query failed)" else "tool_env refresh_path: could not read the login shell's PATH (sh -lc failed)");
        defer {
            for (entries) |e| gpa.free(e);
            gpa.free(entries);
        }
        var list = std.json.Array.init(arena);
        for (entries) |e| {
            var dup = false;
            for (list.items) |d| if (d == .string and samePathEntry(d.string, e)) {
                dup = true;
                break;
            };
            if (!dup) list.append(.{ .string = arena.dupe(u8, e) catch return dupe(gpa, "oom") }) catch return dupe(gpa, "oom");
        }
        obj.object.put(arena, "PATH_PREPEND", .{ .array = list }) catch return dupe(gpa, "oom");
        if (!saveToolEnvObject(gpa, ctx.io, obj)) return dupe(gpa, "tool_env: could not write the overlay file");
        return std.fmt.allocPrint(gpa, "tool PATH refreshed from the machine's live PATH: {d} entries now in front ({s}). Retry the tool that could not find its program.", .{ list.items.len, TOOL_ENV_APPLIES }) catch dupe(gpa, "oom");
    }
    return dupe(gpa, "tool_env: action must be set, refresh_path or show");
}

// ------------------------------------------------------------------------------------------------ run_shell

/// NL_SHELL_TIMEOUT_S → run_shell's wall-clock cap: the same parser, default and ceiling as run_python's
/// (pyrunCapS), read from the caller's environ the same way.
pub fn shellCapS(environ: *const std.process.Environ.Map) u32 {
    return pyrunCapS(environ.get("NL_SHELL_TIMEOUT_S"));
}

/// The cap one run_shell call gets: its own timeout_s when given, never above the host cap; absent, zero or
/// negative means the host cap.
pub fn shellRunCapS(timeout_s: i64, host_cap_s: u32) u32 {
    if (timeout_s <= 0) return host_cap_s;
    return @intCast(@min(timeout_s, @as(i64, host_cap_s)));
}

const Shell = enum { powershell, bash, sh, cmd };

fn parseShell(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) ?Shell {
    const n = std.mem.trim(u8, name, " \r\n\t");
    if (n.len == 0 or std.mem.eql(u8, n, "auto")) {
        if (builtin.os.tag == .windows) return .powershell;
        // bash when the machine has it, else sh: `which` prints only, never runs the target
        const argv = [_][]const u8{ "which", "bash" };
        var r = bounded.run(gpa, io, .{ .argv = &argv, .environ_map = env, .bound_ms = 5_000, .stdout_limit = 4096, .stderr_limit = 1024 });
        defer r.deinit(gpa);
        return if (r.ok()) .bash else .sh;
    }
    if (std.mem.eql(u8, n, "powershell") or std.mem.eql(u8, n, "pwsh")) return .powershell;
    if (std.mem.eql(u8, n, "bash")) return .bash;
    if (std.mem.eql(u8, n, "sh")) return .sh;
    if (std.mem.eql(u8, n, "cmd")) return .cmd;
    return null;
}

/// RUN_SHELL — the general executor beside run_python, and the only way the model can INSTALL what run_python
/// lacks (python itself, a package manager's program) on a bare machine. The script goes to a per-scope file in
/// the workdir exactly as run_python's does and the shell runs that file; the reply is run_python's own shape
/// (`exit=N` / stdout / stderr, same clips) so every heuristic that reads a run_python result reads this one.
/// bounded.run, not std.process.run: the latter's timeout never fires on Windows for a child that prints
/// nothing, and a shell waiting on an installer's prompt prints nothing.
fn runShell(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { shell: []const u8 = "auto", script: []const u8 = "", timeout_s: i64 = 0 };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (std.mem.trim(u8, p.value.script, " \r\n\t").len == 0) return dupe(gpa, "no script");
    const shell = parseShell(gpa, ctx.io, ctx.environ, p.value.shell) orelse return dupe(gpa, "run_shell: shell must be auto, powershell, bash, sh or cmd");
    if (shell == .cmd and builtin.os.tag != .windows) return dupe(gpa, "run_shell: cmd is a Windows shell; on this host use bash, sh or powershell");

    const ext: []const u8 = switch (shell) {
        .powershell => "ps1",
        .cmd => "cmd",
        .bash, .sh => "sh",
    };
    // slugified scope, as run_python's script name: ':' in chat:{conv}/sched:{tid} is an ADS/portability hazard
    var scope_buf: [64]u8 = undefined;
    const script_name = std.fmt.allocPrint(gpa, ".tool-{s}.{s}", .{ slugify(&scope_buf, ctx.scope), ext }) catch return dupe(gpa, "oom");
    defer gpa.free(script_name);
    const script = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, script_name }) catch return dupe(gpa, "oom");
    defer gpa.free(script);
    // The shell gets the file as an EXPLICIT path relative to its cwd (the workdir), never a bare name: `cmd /c
    // name.cmd` resolves a bare name through the exe search, which skips the current directory on a machine with
    // NoDefaultCurrentDirectoryInExePath set (measured here: "'.tool-test.cmd' is not recognized", exit 1, with the
    // file right there in the cwd), while `.\name.cmd` ran. Same form for -File and for sh, where it is harmless.
    const script_arg = std.fmt.allocPrint(gpa, if (builtin.os.tag == .windows) ".\\{s}" else "./{s}", .{script_name}) catch return dupe(gpa, "oom");
    defer gpa.free(script_arg);
    // a trailing newline makes a last line without one run under cmd
    const body = std.fmt.allocPrint(gpa, "{s}\n", .{p.value.script}) catch return dupe(gpa, "oom");
    defer gpa.free(body);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = script, .data = body }) catch return dupe(gpa, "could not write script");

    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    defer env.deinit();
    prepChildEnv(gpa, ctx.io, &env);
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};

    const exe: []const u8 = switch (shell) {
        .powershell => if (builtin.os.tag == .windows) "powershell" else "pwsh",
        .bash => "bash",
        .sh => "sh",
        .cmd => "cmd",
    };
    var argv_buf: [7][]const u8 = undefined;
    const argv: []const []const u8 = switch (shell) {
        .powershell => blk: {
            argv_buf = .{ exe, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script_arg };
            break :blk argv_buf[0..7];
        },
        .bash, .sh => blk: {
            argv_buf[0] = exe;
            argv_buf[1] = script_arg;
            break :blk argv_buf[0..2];
        },
        .cmd => blk: {
            argv_buf[0] = exe;
            argv_buf[1] = "/d";
            argv_buf[2] = "/c";
            argv_buf[3] = script_arg;
            break :blk argv_buf[0..4];
        },
    };
    const cap_s = shellRunCapS(p.value.timeout_s, shellCapS(ctx.environ));
    var r = bounded.run(gpa, ctx.io, .{ .argv = argv, .cwd = .{ .path = ctx.workdir }, .environ_map = &env, .bound_ms = @as(u64, cap_s) * 1000, .stdout_limit = 256 << 10, .stderr_limit = 64 << 10 });
    defer r.deinit(gpa);
    switch (r.end) {
        .unstarted => return if (deps.isSpawnMissing(r.err.?))
            std.fmt.allocPrint(gpa, "{s} not found on PATH — pick another shell (powershell on Windows, bash or sh elsewhere), or install it and run tool_env refresh_path", .{exe}) catch dupe(gpa, "shell not found on PATH")
        else
            std.fmt.allocPrint(gpa, "{s} failed to start: {s}", .{ exe, r.why() }) catch dupe(gpa, "shell failed to start"),
        .unread => return std.fmt.allocPrint(gpa, "{s}: could not read the script's output ({s})", .{ exe, r.why() }) catch dupe(gpa, "shell output unread"),
        else => {},
    }
    // run_python's contract, exactly: exit=N, stdout clipped at the head, stderr head+tail (clipEnds) so the
    // actual error, which a shell prints LAST, survives the clip. A cut run reports as PYRUN does: exit 124 and
    // a TIMEOUT line that names the cap as run_shell's own.
    const exit: u32 = switch (r.end) {
        .exited => r.code,
        .killed => 124,
        else => 255,
    };
    const note: []const u8 = switch (r.end) {
        .killed => std.fmt.allocPrint(gpa, "\nTIMEOUT: the run_shell cap is {d} s and this run reached it. The script was killed with everything it started; the output above is what it printed before that. A sleep or timeout inside the script cannot raise this cap. Split the work into shorter runs, or start a long job in the background with its output sent to a file and watch that file with poll.", .{cap_s}) catch "",
        .overflow => "\nOUTPUT LIMIT: the script printed past run_shell's limit (256 KB stdout / 64 KB stderr) and was stopped there. Send bulk output to a file and read it with read_file.",
        .signal => "\n(the script ended on a signal)",
        else => "",
    };
    defer if (r.end == .killed and note.len > 0) gpa.free(@constCast(note));
    const head, const tail = clipEnds(r.stderr, 1500);
    if (tail.len == 0)
        return std.fmt.allocPrint(gpa, "exit={d}\nstdout:\n{s}\nstderr:\n{s}{s}", .{ exit, clip(r.stdout, 4000), head, note }) catch dupe(gpa, "ran");
    return std.fmt.allocPrint(gpa, "exit={d}\nstdout:\n{s}\nstderr:\n{s}\n  ... [middle lines omitted — the LAST line below is the actual error] ...\n{s}{s}", .{ exit, clip(r.stdout, 4000), head, tail, note }) catch dupe(gpa, "ran");
}

/// The dep hint for a missing python, plus the sentence that turns it from a dead end into the next tool call.
pub const PYTHON_MISSING_DOCTRINE = "You can fix this yourself: install it with run_shell (Windows: winget install Python.Python.3; macOS: brew install python; Debian/Ubuntu: apt install python3), then run tool_env with action refresh_path (or tool_env set NL_PYTHON_BIN=<full path>) so the next run_python finds it with no veil restart, and retry — do not tell the user the tools are broken.";

fn pythonMissingForModel(gpa: std.mem.Allocator) []u8 {
    const h = deps.hint(gpa, "python");
    defer if (h.len > 0) gpa.free(h);
    return std.fmt.allocPrint(gpa, "{s}. {s}", .{ h, PYTHON_MISSING_DOCTRINE }) catch dupe(gpa, PYTHON_MISSING_DOCTRINE);
}

fn runPython(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { code: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (p.value.code.len == 0) return dupe(gpa, "no code");

    const guard = "import os as _o\ntry:\n import webbrowser as _wb\n _wb.open=lambda *a,**k:False\nexcept Exception: pass\n_o.startfile=getattr(_o,'startfile',None) and (lambda *a,**k:None)\n";
    const src = std.fmt.allocPrint(gpa, "{s}{s}", .{ guard, p.value.code }) catch return dupe(gpa, "oom");
    defer gpa.free(src);
    // slugified: per-conversation scopes carry ':' (chat:{conv} / sched:{tid}) — a raw ':' in the name
    // makes NTFS write an invisible alternate data stream and non-NTFS workdirs fail the write outright
    var scope_buf: [64]u8 = undefined;
    const script_name = std.fmt.allocPrint(gpa, ".tool-{s}.py", .{slugify(&scope_buf, ctx.scope)}) catch return dupe(gpa, "oom");
    defer gpa.free(script_name);
    const script = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, script_name }) catch return dupe(gpa, "oom");
    defer gpa.free(script);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = script, .data = src }) catch return dupe(gpa, "could not write script");

    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    prepChildEnv(gpa, ctx.io, &env);
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};

    const py = deps.pythonBin(ctx.io, &env);
    var cap_buf: [10]u8 = undefined;
    const argv = [_][]const u8{ py, "-c", PYRUN, pyrunCapArg(ctx.environ, &cap_buf), script_name };
    var r = pyrunRun(gpa, ctx.io, &argv, ctx.workdir, &env, ctx.environ);
    defer r.deinit(gpa);
    // A SPAWN error (python missing / unstartable) is not the same as a script that ran and crashed: the
    // latter exits non-zero and NEVER reaches this branch. So only the genuine "the interpreter itself is
    // missing" case swaps the flat string for the actionable dep hint — and for the model, the way out: it can
    // install the interpreter itself with run_shell, make the new PATH visible with tool_env, and retry, instead
    // of reporting the tools broken.
    if (r.end == .unstarted) return if (deps.isSpawnMissing(r.err.?)) pythonMissingForModel(gpa) else dupe(gpa, "python failed to run");
    const exit = pyrunExit(&r);
    const note = pyrunNote(gpa, ctx.environ, &r);
    defer gpa.free(note);
    const head, const tail = clipEnds(r.stderr, 1500);
    if (tail.len == 0)
        return std.fmt.allocPrint(gpa, "exit={d}\nstdout:\n{s}\nstderr:\n{s}{s}", .{ exit, clip(r.stdout, 4000), head, note }) catch dupe(gpa, "ran");
    return std.fmt.allocPrint(gpa, "exit={d}\nstdout:\n{s}\nstderr:\n{s}\n  ... [middle frames omitted — the LAST line below is the actual error] ...\n{s}{s}", .{ exit, clip(r.stdout, 4000), head, tail, note }) catch dupe(gpa, "ran");
}

/// Head+tail clip for captured stderr. A plain head clip — what this used to be — is exactly backwards for a
/// Python traceback: frames print outermost-first and the ACTUAL exception is the LAST line. Measured on the
/// live failure that killed a chat: a `requests` DNS error is 6156 bytes with the diagnosis
/// ("ConnectionError: ... host='forum.<host>'") starting at byte 5804, so at clip(stderr, 1500) the model
/// received urllib3 plumbing ending mid-frame at `File "C:\Users\gar` and never saw the hostname or the
/// exception type. It generalised that into "the network isn't resolving on this belt" and refused every
/// remaining step of the task — when the real fault was a subdomain it had invented itself and could have
/// corrected in one retry. Same budget, both ends; head names the call site, tail names the failure.
fn clipEnds(s: []const u8, n: usize) struct { []const u8, []const u8 } {
    if (s.len <= n) return .{ s, ""[0..0] };
    const tail_n = n - n / 4; // 3/4 to the tail — the exception line plus its immediate frame
    return .{ s[0 .. n - tail_n], s[s.len - tail_n ..] };
}

test "clipEnds keeps the exception line a head clip would have thrown away" {
    var buf: [6000]u8 = undefined;
    @memset(&buf, 'x');
    const diagnosis = "requests.exceptions.ConnectionError: Failed to resolve 'forum.example.invalid'";
    @memcpy(buf[buf.len - diagnosis.len ..], diagnosis);
    const head, const tail = clipEnds(&buf, 1500);
    try std.testing.expect(head.len + tail.len <= 1500);
    try std.testing.expect(std.mem.indexOf(u8, tail, diagnosis) != null);
    // the old behaviour, for contrast: a head clip of the same budget never reaches it
    try std.testing.expect(std.mem.indexOf(u8, clip(&buf, 1500), diagnosis) == null);
    // short stderr is returned whole, with no tail and no omission marker
    const h2, const t2 = clipEnds("boom", 1500);
    try std.testing.expectEqualStrings("boom", h2);
    try std.testing.expectEqual(@as(usize, 0), t2.len);
}

test "run_python's cap: NL_PYRUN_TIMEOUT_S is bounded both ways, and both belts state the real default" {
    try std.testing.expectEqual(PYRUN_CAP_DEFAULT_S, pyrunCapS(null));
    // a typo is never "no cap" and never "cap 0"
    for ([_][]const u8{ "", "  ", "0", "-5", "abc", "1.5", "25s" }) |bad|
        try std.testing.expectEqual(PYRUN_CAP_DEFAULT_S, pyrunCapS(bad));
    try std.testing.expectEqual(@as(u32, 1), pyrunCapS("1"));
    try std.testing.expectEqual(@as(u32, 90), pyrunCapS(" 90\r\n"));
    // past the ceiling clamps — even past u32 — rather than snapping back to the short default
    try std.testing.expectEqual(PYRUN_CAP_MAX_S, pyrunCapS("100000"));
    try std.testing.expectEqual(PYRUN_CAP_MAX_S, pyrunCapS("99999999999"));
    try std.testing.expect(PYRUN_CAP_DEFAULT_S <= PYRUN_CAP_MAX_S);
    // The default is drawn from measured runs (see PYRUN_CAP_DEFAULT_S): the longest real test run this launcher has
    // carried finished at 88 s (armC-holdout-20261014, astropy-14182, exit 0), so the default clears it, and it stays
    // at half the ceiling so a cut run still leaves the swarm watchdog's silence threshold far off.
    const LONGEST_MEASURED_TEST_RUN_S: u32 = 88;
    try std.testing.expect(PYRUN_CAP_DEFAULT_S > LONGEST_MEASURED_TEST_RUN_S);
    try std.testing.expect(PYRUN_CAP_DEFAULT_S * 2 <= PYRUN_CAP_MAX_S);
    // The model can only plan around a cap it is told about. Both run_python defs carry the sentence (the
    // CHAT_SCHEMA drift test keeps them identical); this pins that the number in it is the constant's.
    const stated = std.fmt.comptimePrint("({d} s unless the host set another)", .{PYRUN_CAP_DEFAULT_S});
    for ([_][]const u8{ SCHEMA, CHAT_SCHEMA }) |block| {
        const def = findSchemaDef(block, "run_python") orelse return error.NoRunPythonDef;
        try std.testing.expect(std.mem.indexOf(u8, def, stated) != null);
        try std.testing.expect(std.mem.indexOf(u8, def, "a timeout= inside your code cannot raise it") != null);
        // run_shell shares the parser, default and ceiling (shellCapS), so its def states the same number
        const sh = findSchemaDef(block, "run_shell") orelse return error.NoRunShellDef;
        try std.testing.expect(std.mem.indexOf(u8, sh, stated) != null);
    }
}

test "run_shell's cap: NL_SHELL_TIMEOUT_S takes run_python's parser and bounds; a call's timeout_s never exceeds the host cap" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try std.testing.expectEqual(PYRUN_CAP_DEFAULT_S, shellCapS(&env));
    try env.put("NL_SHELL_TIMEOUT_S", "abc");
    try std.testing.expectEqual(PYRUN_CAP_DEFAULT_S, shellCapS(&env));
    try env.put("NL_SHELL_TIMEOUT_S", "30");
    try std.testing.expectEqual(@as(u32, 30), shellCapS(&env));
    try env.put("NL_SHELL_TIMEOUT_S", "99999");
    try std.testing.expectEqual(PYRUN_CAP_MAX_S, shellCapS(&env));
    // per call: absent/zero/negative = the host cap; a smaller value stands; a larger one clamps to the host cap
    try std.testing.expectEqual(@as(u32, 120), shellRunCapS(0, 120));
    try std.testing.expectEqual(@as(u32, 120), shellRunCapS(-5, 120));
    try std.testing.expectEqual(@as(u32, 5), shellRunCapS(5, 120));
    try std.testing.expectEqual(@as(u32, 120), shellRunCapS(100000, 120));
    try std.testing.expectEqual(@as(u32, 1), shellRunCapS(1, 120));
}

test "run_shell answers in run_python's shape with a real shell: exit, stdout and stderr; a cut run says TIMEOUT and exit 124 (real cmd/sh)" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    const root = "zig-run-shell-tmp";
    f.scratch(root);
    defer std.Io.Dir.cwd().deleteTree(f.threaded.io(), root) catch {};
    var ctx = f.ctx(gpa);
    ctx.workdir = root;
    ctx.run_dir = root;
    { // skip only on proof that the shell the test names is not on this machine (it always is on Windows)
        const probe_argv = [_][]const u8{ if (builtin.os.tag == .windows) "cmd" else "sh", if (builtin.os.tag == .windows) "/c" else "-c", "exit 0" };
        var probe = bounded.run(gpa, ctx.io, .{ .argv = &probe_argv, .environ_map = &f.env, .bound_ms = 30_000, .stdout_limit = 256, .stderr_limit = 256 });
        defer probe.deinit(gpa);
        if (probe.end == .unstarted) return error.SkipZigTest;
    }
    const args = if (builtin.os.tag == .windows)
        \\{"shell":"cmd","script":"@echo out-line\r\n@echo err-line 1>&2\r\n@exit /b 3"}
    else
        \\{"shell":"sh","script":"echo out-line\necho err-line >&2\nexit 3"}
    ;
    const out = runShell(&ctx, args);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "exit=3\nstdout:\n"));
    const so = std.mem.indexOf(u8, out, "\nstdout:\n").?;
    const se = std.mem.indexOf(u8, out, "\nstderr:\n").?;
    try std.testing.expectEqualStrings("out-line", std.mem.trim(u8, out[so + "\nstdout:\n".len .. se], " \r\n"));
    try std.testing.expectEqualStrings("err-line", std.mem.trim(u8, out[se + "\nstderr:\n".len ..], " \r\n"));
    // the script file lands beside run_python's, per scope, and is left for inspection as run_python leaves its own
    const left = if (builtin.os.tag == .windows) root ++ "/.tool-test.cmd" else root ++ "/.tool-test.sh";
    _ = try std.Io.Dir.cwd().statFile(ctx.io, left, .{});
    if (builtin.os.tag == .windows) {
        // the Windows DEFAULT (auto = powershell -File): same contract, same exit code, and the ps1 lands too
        const ps = runShell(&ctx, "{\"script\":\"Write-Output 'out-line'\\n[Console]::Error.WriteLine('err-line')\\nexit 3\"}");
        defer gpa.free(ps);
        try std.testing.expect(std.mem.startsWith(u8, ps, "exit=3\nstdout:\n"));
        try std.testing.expect(std.mem.indexOf(u8, ps, "out-line") != null and std.mem.indexOf(u8, ps, "err-line") != null);
        _ = try std.Io.Dir.cwd().statFile(ctx.io, root ++ "/.tool-test.ps1", .{});
    }
    // a run past its cap is cut, keeps what was printed, and names the cap as run_shell's own
    const slow = if (builtin.os.tag == .windows)
        \\{"shell":"cmd","script":"@echo before\r\n@ping -n 30 127.0.0.1 >NUL\r\n@echo after","timeout_s":1}
    else
        \\{"shell":"sh","script":"echo before\nsleep 30\necho after","timeout_s":1}
    ;
    const cut = runShell(&ctx, slow);
    defer gpa.free(cut);
    try std.testing.expect(std.mem.startsWith(u8, cut, "exit=124\n"));
    try std.testing.expect(std.mem.indexOf(u8, cut, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "after") == null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "TIMEOUT: the run_shell cap is 1 s") != null);
    // an unknown shell name and an empty script are refused in words, before anything is written
    const bad = runShell(&ctx, "{\"shell\":\"fish\",\"script\":\"echo hi\"}");
    defer gpa.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "shell must be") != null);
    const none = runShell(&ctx, "{\"script\":\"   \"}");
    defer gpa.free(none);
    try std.testing.expectEqualStrings("no script", none);
}

test "the tool-env overlay: string members become env vars, PATH_PREPEND goes in front once each, junk is skipped (pure)" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const d = std.fs.path.delimiter;
    const existing = std.fmt.comptimePrint("/usr/bin{c}/opt/already/", .{d});
    try env.put("PATH", existing);
    try env.put("KEEP", "1");
    // a bad name, a non-string value and a blank PATH entry are all skipped; a dir PATH already holds (trailing
    // separator and, on Windows, case aside) is not re-added; a repeat inside PATH_PREPEND is added once
    const overlay = if (builtin.os.tag == .windows)
        \\{"NL_PYTHON_BIN":"C:/py/python.exe","bad=name":"x","NUM":5,"PATH_PREPEND":["C:/new/bin","/OPT/ALREADY"," ","C:/new/bin/","C:/other"]}
    else
        \\{"NL_PYTHON_BIN":"/py/bin/python3","bad=name":"x","NUM":5,"PATH_PREPEND":["/new/bin","/opt/already"," ","/new/bin/","/other"]}
    ;
    applyToolEnvJson(gpa, &env, overlay);
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "C:/py/python.exe" else "/py/bin/python3", env.get("NL_PYTHON_BIN").?);
    try std.testing.expectEqualStrings("1", env.get("KEEP").?);
    try std.testing.expect(env.get("bad=name") == null);
    try std.testing.expect(env.get("NUM") == null);
    const want = if (builtin.os.tag == .windows)
        std.fmt.comptimePrint("C:/new/bin{c}C:/other{c}/usr/bin{c}/opt/already/", .{ d, d, d })
    else
        std.fmt.comptimePrint("/new/bin{c}/other{c}/usr/bin{c}/opt/already/", .{ d, d, d });
    try std.testing.expectEqualStrings(want, env.get("PATH").?);
    // applied twice (every spawn re-reads the file) the PATH does not grow
    applyToolEnvJson(gpa, &env, overlay);
    try std.testing.expectEqualStrings(want, env.get("PATH").?);
    // malformed JSON or a non-object applies nothing
    applyToolEnvJson(gpa, &env, "{not json");
    applyToolEnvJson(gpa, &env, "[1,2]");
    try std.testing.expectEqualStrings(want, env.get("PATH").?);
    // no PATH at all: the prepend becomes the whole PATH
    var bare = std.process.Environ.Map.init(gpa);
    defer bare.deinit();
    applyToolEnvJson(gpa, &bare, "{\"PATH_PREPEND\":[\"/only\"]}");
    try std.testing.expectEqualStrings("/only", bare.get("PATH").?);
}

test "tool_env set/show round trip through the overlay file, and a child env built afterwards carries it" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    const root = "zig-tool-env-tmp";
    f.scratch(root);
    defer std.Io.Dir.cwd().deleteTree(f.threaded.io(), root) catch {};
    var ctx = f.ctx(gpa);
    // unregistered: the tool says so and writes nothing
    clearToolEnvPath();
    const off = toolEnvTool(&ctx, "{\"action\":\"show\"}");
    defer gpa.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "not available") != null);
    setToolEnvPath(root);
    defer clearToolEnvPath();
    const s1 = toolEnvTool(&ctx, "{\"action\":\"set\",\"name\":\"NL_PYTHON_BIN\",\"value\":\" /py/bin/python3 \"}");
    defer gpa.free(s1);
    try std.testing.expect(std.mem.indexOf(u8, s1, "NL_PYTHON_BIN=/py/bin/python3") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1, TOOL_ENV_APPLIES) != null);
    const s2 = toolEnvTool(&ctx, "{\"action\":\"set\",\"name\":\"PATH\",\"value\":\"/new/bin\"}");
    defer gpa.free(s2);
    try std.testing.expect(std.mem.indexOf(u8, s2, "PATH now starts with /new/bin") != null);
    const again = toolEnvTool(&ctx, "{\"action\":\"set\",\"name\":\"PATH\",\"value\":\"/new/bin/\"}");
    defer gpa.free(again);
    try std.testing.expect(std.mem.indexOf(u8, again, "already in front") != null);
    const bad = toolEnvTool(&ctx, "{\"action\":\"set\",\"name\":\"1bad\",\"value\":\"x\"}");
    defer gpa.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "name must be") != null);
    const unknown = toolEnvTool(&ctx, "{\"action\":\"drop\"}");
    defer gpa.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "action must be") != null);
    const shown = toolEnvTool(&ctx, "{\"action\":\"show\"}");
    defer gpa.free(shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "\"NL_PYTHON_BIN\": \"/py/bin/python3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "\"/new/bin\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shown, "/new/bin"));
    // the file is what persists: a fresh env prepared the way every spawn site prepares one carries both
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin");
    prepChildEnv(gpa, ctx.io, &env);
    try std.testing.expectEqualStrings("/py/bin/python3", env.get("NL_PYTHON_BIN").?);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("/new/bin{c}/usr/bin", .{std.fs.path.delimiter}), env.get("PATH").?);
    try std.testing.expectEqualStrings("1", env.get("PYTHONUTF8").?);
    // and deps.probe resolves on the same overlay (an override file that exists reads as present)
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = root ++ "/py-stand-in", .data = "" });
    const s3 = toolEnvTool(&ctx, "{\"action\":\"set\",\"name\":\"NL_PYTHON_BIN\",\"value\":\"" ++ root ++ "/py-stand-in\"}");
    defer gpa.free(s3);
    var plain = std.process.Environ.Map.init(gpa);
    defer plain.deinit();
    var over = overlaidEnv(gpa, ctx.io, &plain) orelse return error.NoOverlay;
    defer over.deinit();
    try std.testing.expectEqualStrings(root ++ "/py-stand-in", deps.pythonBin(ctx.io, &over));
    // refresh_path reads the machine's live PATH (reg query / sh -lc: both always present where the suite runs)
    // and replaces PATH_PREPEND with it: at least one directory, and the earlier hand-set entry is gone
    const refreshed = toolEnvTool(&ctx, "{\"action\":\"refresh_path\"}");
    defer gpa.free(refreshed);
    try std.testing.expect(std.mem.indexOf(u8, refreshed, "tool PATH refreshed") != null);
    try std.testing.expect(std.mem.indexOf(u8, refreshed, ": 0 entries") == null);
    const after = toolEnvTool(&ctx, "{\"action\":\"show\"}");
    defer gpa.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"/new/bin\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"NL_PYTHON_BIN\"") != null); // other members survive a refresh
}

test "a run_python cap hit keeps what the script printed and names the cap as run_python's own; a pipe-holding child stretches the call by the grace at most, and one that finishes inside it is no cap hit (real python)" {
    const gpa = std.testing.allocator;
    // The REAL process environ (TESTING.md): an empty one leaves the Windows child without SystemRoot/TEMP.
    const environ: std.process.Environ = if (@import("builtin").os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();
    var env = environ.createMap(gpa) catch return error.SkipZigTest;
    defer env.deinit();
    { // skip only on proof that the interpreter runPython spawns is not on this machine
        const py = deps.pythonBin(io, &env);
        const probe = std.process.run(gpa, io, .{ .argv = &.{ py, "--version" }, .environ_map = &env, .stdout_limit = .limited(256), .stderr_limit = .limited(256), .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } }) catch |e| {
            if (deps.isSpawnMissing(e)) return error.SkipZigTest;
            return e;
        };
        defer gpa.free(probe.stdout);
        defer gpa.free(probe.stderr);
        if (probe.term != .exited or probe.term.exited != 0) return error.SkipZigTest; // e.g. the Store alias stub
    }
    const root = "zig-pyrun-cap-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = root,
        .workdir = root,
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined, // run_python never touches memory
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
    };

    // The scripts below are JSON-encoded by the serializer rather than by hand: they carry quotes and escapes
    // three layers deep (Zig, JSON, the Python -c string of a grandchild).
    const Args = struct { code: []const u8 };

    // Caps here are 2-3 s, not 1: the property is "the cap applies", and a 1 s cap under a loaded parallel build
    // starts measuring how fast the interpreter comes up instead.
    try env.put("NL_PYRUN_TIMEOUT_S", "2");
    { // five seconds of sleep against a two-second cap — under the old fixed 25 s cap this simply finished
        const out = runPython(&ctx, "{\"code\":\"import time\\nprint('BEFORE', flush=True)\\ntime.sleep(5)\\nprint('AFTER')\"}");
        defer gpa.free(out);
        if (!std.mem.startsWith(u8, out, "exit=124\n")) {
            std.debug.print("\nexpected a cap hit at 2 s, got:\n{s}\n", .{out});
            return error.CapNotApplied;
        }
        try std.testing.expect(std.mem.indexOf(u8, out, "BEFORE") != null); // what it printed survives the kill
        try std.testing.expect(std.mem.indexOf(u8, out, "AFTER") == null); // ...and the kill came first
        try std.testing.expect(std.mem.indexOf(u8, out, "run_python cap is 2 s") != null); // the configured cap, by name
        try std.testing.expect(std.mem.indexOf(u8, out, "timeout= inside your code cannot raise this cap") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "was still running and was killed") != null);
        // the kill reaches the script alone, and the reply says so rather than implying everything stopped
        try std.testing.expect(std.mem.indexOf(u8, out, "Anything it started was not killed") != null);
    }
    try env.put("NL_PYRUN_TIMEOUT_S", "20");
    { // under the cap, the launcher is invisible: exit code, stdout (non-ASCII included) and stderr pass through
        const out = runPython(&ctx, "{\"code\":\"import sys\\nprint('ok \\u2192 done')\\nsys.stderr.write('warned')\\nsys.exit(3)\"}");
        defer gpa.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "exit=3\n"));
        try std.testing.expect(std.mem.indexOf(u8, out, "ok \u{2192} done") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "warned") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "TIMEOUT") == null);
    }
    try env.put("NL_PYRUN_TIMEOUT_S", "3");
    { // The script prints to both streams and exits at once, but a process it started inherits the pipes and holds
        // them well past cap + grace. Two things were wrong here. An unbounded drain sat the child out. And on
        // Windows, communicate() hands back NOTHING when its pipes are still held, so `launched` and `err-before`
        // vanished under a reply that spoke of "the output above". Now the call ends at cap + grace with both.
        // The grandchild ticks a dot every 0.25 s so it dies on the broken pipe soon after the launcher exits,
        // instead of outliving the test; 80 ticks bound it either way.
        const code =
            \\import subprocess,sys,tempfile
            \\sys.stderr.write('err-before\n'); sys.stderr.flush()
            \\subprocess.Popen([sys.executable,'-c','import sys,time\nfor _ in range(80):\n time.sleep(0.25); sys.stdout.write("."); sys.stdout.flush()'],cwd=tempfile.gettempdir())
            \\print('launched', flush=True)
        ;
        const args = try std.json.Stringify.valueAlloc(gpa, Args{ .code = code }, .{});
        defer gpa.free(args);
        const out = runPython(&ctx, args);
        defer gpa.free(out);
        if (!std.mem.startsWith(u8, out, "exit=124\n") or std.mem.indexOf(u8, out, "still holds that output open") == null) {
            std.debug.print("\nexpected the grace to end on a pipe-holding child, got:\n{s}\n", .{out});
            return error.DrainNotBounded;
        }
        if (std.mem.indexOf(u8, out, "launched") == null or std.mem.indexOf(u8, out, "err-before") == null) {
            std.debug.print("\nwhat the script printed before the cap was lost:\n{s}\n", .{out});
            return error.OutputLost;
        }
        try std.testing.expect(std.mem.indexOf(u8, out, "The script itself had exited (code 0)") != null);
    }
    { // The finished-suite shape (SymPy): the script backgrounds a run without redirection and exits; the run
        // prints its result 4 s in, past the 3 s cap but inside the grace. Every byte arrives and nothing is left
        // running, so this is no cap hit: the script's own exit code and the full output come back. The old
        // launcher answered exit 124 and "cut off" here, and the model re-ran a suite that had already finished.
        const code =
            \\import subprocess,sys,tempfile
            \\subprocess.Popen([sys.executable,'-c','import time\ntime.sleep(4)\nprint("tests finished: 16 passed", flush=True)'],cwd=tempfile.gettempdir())
            \\print('launched', flush=True)
        ;
        const args = try std.json.Stringify.valueAlloc(gpa, Args{ .code = code }, .{});
        defer gpa.free(args);
        const out = runPython(&ctx, args);
        defer gpa.free(out);
        if (!std.mem.startsWith(u8, out, "exit=0\n") or std.mem.indexOf(u8, out, "TIMEOUT") != null) {
            std.debug.print("\na run that finished inside the grace was reported as a cap hit:\n{s}\n", .{out});
            return error.FinishedRunCalledCut;
        }
        try std.testing.expect(std.mem.indexOf(u8, out, "launched") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "tests finished: 16 passed") != null);
        // ...and the one line that is added says the output is whole, so the model has no reason to run it again
        try std.testing.expect(std.mem.indexOf(u8, out, "NOTE: the script exited (code 0) within run_python's 3 s cap") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "that output is complete above") != null);
    }
}

test "a run_python script printing past what the call keeps runs to its own exit, and the reply keeps its exit code and its head, instead of hanging the call or reading as a success (real python)" {
    const gpa = std.testing.allocator;
    const environ: std.process.Environ = if (@import("builtin").os.tag == .windows) .{ .block = .global } else .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();
    var env = environ.createMap(gpa) catch return error.SkipZigTest;
    defer env.deinit();
    { // skip only on proof that the interpreter runPython spawns is not on this machine
        const py = deps.pythonBin(io, &env);
        var probe = bounded.run(gpa, io, .{ .argv = &.{ py, "--version" }, .environ_map = &env, .bound_ms = 30_000, .stdout_limit = 256, .stderr_limit = 256 });
        defer probe.deinit(gpa);
        if (probe.end == .unstarted and deps.isSpawnMissing(probe.err.?)) return error.SkipZigTest;
        if (!probe.ok()) return error.SkipZigTest; // e.g. the Store alias stub
    }
    const root = "zig-pyrun-overflow-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    try env.put("NL_PYRUN_TIMEOUT_S", "20");
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = root,
        .workdir = root,
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined, // run_python never touches memory
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
    };
    // PYRUN holds what the script prints and writes it all as it exits: 600 KB of stdout, past twice the 256 KB the
    // call keeps of it, and 70 KB of stderr, past its 64 KB, ending on the line that matters. Under std.process.run
    // that answered "python failed to run" (StreamTooLong); stopped at the limit, a "STOPPED:" line with no exit code.
    const code =
        \\import sys
        \\sys.stdout.write('HEAD-' + 'x' * 600000)
        \\sys.stderr.write('E' * 70000 + '\nLAST-ERR')
        \\sys.exit(3)
    ;
    const Args = struct { code: []const u8 };
    const args = try std.json.Stringify.valueAlloc(gpa, Args{ .code = code }, .{});
    defer gpa.free(args);
    const out = runPython(&ctx, args);
    defer gpa.free(out);
    if (!std.mem.startsWith(u8, out, "exit=3\nstdout:\nHEAD-xxx")) {
        std.debug.print("\nexpected the script's own exit code and the head of its output, got:\n{s}\n", .{out[0..@min(out.len, 400)]});
        return error.ExitNotKept;
    }
    try std.testing.expect(std.mem.endsWith(u8, out, "LAST-ERR")); // stderr's tail survives its limit too
    try std.testing.expect(std.mem.indexOf(u8, out, "TIMEOUT") == null);
    // The reply shows only the head of stdout (4000 bytes); what the call kept counts the bytes it did not keep. The
    // same launcher call again, from the script runPython left in the workdir:
    var sb: [64]u8 = undefined;
    const script_name = try std.fmt.allocPrint(gpa, ".tool-{s}.py", .{slugify(&sb, ctx.scope)});
    defer gpa.free(script_name);
    var cap_buf: [10]u8 = undefined;
    const argv = [_][]const u8{ deps.pythonBin(io, &env), "-c", PYRUN, pyrunCapArg(&env, &cap_buf), script_name };
    var r = pyrunRun(gpa, io, &argv, root, &env, &env);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(?u32, 3), r.exited());
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "HEAD-xxx"));
    const not_kept = "HEAD-".len + 600_000 - 2 * PYRUN_STDOUT_MAX; // one line of x's: the cut moves to no line end
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, std.fmt.comptimePrint("\n[... {d} bytes not kept ...]\n", .{not_kept})) != null);
}

/// True if `n` is a built-in tool name. execute() checks built-ins FIRST and make_tool rejects these names, so
/// an authored tool can never shadow/hijack a built-in (e.g. run_python, write_file, make_tool).
/// Whether a name is reserved by the built-in dispatcher. Kept public so the recipe loader and
/// authoring routes share this exact collision guard rather than carrying a stale second list.
pub fn isBuiltinTool(n: []const u8) bool {
    // EVERY name execute() can route must be here, or a recipe/authored tool may be NAMED after it — and
    // since dispatch is linear and the recipe branch sits ~340 lines below the built-in chain, the BUILT-IN
    // wins. A granted recipe called "get_credential" therefore ran the real getCredential, with the
    // caller's own arguments, for a sandboxed user the gate exists to refuse: the grant was spent entirely
    // on getting the NAME past the gate. Six dispatched names were missing from this list (ask_veil,
    // host_status, host_command, host_explore, get_credential, propose_plan_change) and the three prefix
    // families were listed only as their exact verbs, so "mcp_lookup" or "browser_summary" slipped through
    // as well. Keep this in sync with the dispatch chain in execute(); the test below reads execute()'s
    // source and fails if the two ever disagree again.
    const builtins = [_][]const u8{ "run_python", "run_shell", "tool_env", "write_file", "edit_file", "read_file", "absorb", "stage_file", "patch_system", "list_dir", "run_tests", "delete_file", "web_fetch", "web_search", "fetch_json", "read_url", "osint_scan", "deep_crawl", "observe", "recall", "recall_hive", "read_doc", "poll", "stop_process", "share", "probe", "note_stance", "save_skill", "journal", "set_directive", "send_message", "add_task", "claim_task", "complete_task", "stage_delivery", "make_tool", "propose_change", "simulate_change", "propose_plan_change", "ask_veil", "host_status", "host_command", "host_explore", "get_credential", "garrett_tools", "garrett" };
    for (builtins) |b| if (std.mem.eql(u8, b, n)) return true;
    // PREFIX families: execute() routes these with startsWith, so every suffix is reserved, not just the
    // verbs that happen to exist today.
    const families = [_][]const u8{ "browser_", "pixel_", "mcp_", "cf_", "security_" };
    for (families) |f| if (std.mem.startsWith(u8, n, f)) return true;
    return false;
}

/// Find an authored tool's python body (decoded from base64) by name. Newest record wins. Caller frees; null if
/// the name isn't a registered authored tool.
fn authoredBody(ctx: *ToolCtx, name: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    const all = ctx.mem.list(TOOL_SCOPE);
    defer gpa.free(all);
    var last_b64: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, all, '\n');
    while (it.next()) |ln| {
        var f = std.mem.splitScalar(u8, ln, '\x1f');
        const rn = f.next() orelse continue;
        if (!std.mem.eql(u8, rn, name)) continue;
        _ = f.next() orelse continue;
        last_b64 = f.next() orelse continue;
    }
    const b64 = last_b64 orelse return null;
    const Dec = std.base64.standard.Decoder;
    const n = Dec.calcSizeForSlice(b64) catch return null;
    const out = gpa.alloc(u8, n) catch return null;
    Dec.decode(out, b64) catch {
        gpa.free(out);
        return null;
    };
    return out;
}

/// Run an authored tool's body as DATA: the call args are passed as argv[1] and json.loads'd into a global ARGS
/// dict — NEVER concatenated into source (closes the code-injection path). Provider keys blanked like runPython.
/// Result contract: the LAST stdout line starting with '{' (a JSON result); else an exit+stderr debug dump.
fn runAuthored(ctx: *ToolCtx, name: []const u8, body: []const u8, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const guard = "import os as _o\ntry:\n import webbrowser as _wb\n _wb.open=lambda *a,**k:False\nexcept Exception: pass\n_o.startfile=getattr(_o,'startfile',None) and (lambda *a,**k:None)\n";
    const preamble = "import sys,json as _j\ntry: ARGS=_j.loads(sys.argv[1])\nexcept Exception: ARGS={}\n";
    // Browser bridge (Feature 2): when the driver is enabled, start the loopback broker and expose a
    // browser() helper to the authored body so an INVENTED tool can drive the SAME session the mind uses
    // (keyed by run_dir). Off by default → the body runs byte-identically to before.
    // Local-capability bridge: when the browser driver and/or MCP is enabled, bring up the local broker (the
    // per-machine daemon on the CLIENT so an invented tool shares the mind's session; the in-process broker on
    // server/swarm) and inject the matching helper(s) so an invented tool can drive the browser and/or call
    // installed MCP servers. Off ⇒ the body runs byte-identically to before.
    var broker_port: u16 = 0;
    var broker_tok: []const u8 = "";
    var tok_buf: [32]u8 = undefined;
    // roam (a client machine) OR the server env flags enable the bridge, so an INVENTED tool on the user's own
    // machine gets the browser()/mcp() helpers even when the desk process doesn't carry NL_BROWSER_DRIVER — the
    // "AI writes a click-script" path the user asked for.
    if (ctx.roam or browserEnabled(ctx) or mcpEnabled(ctx)) {
        if (ctx.browser_daemon) {
            if (browser_host.ensure(gpa, ctx.io, ctx.environ)) |info| {
                broker_port = info.port;
                @memcpy(&tok_buf, &info.token);
                broker_tok = &tok_buf;
            }
        } else if (browser_broker.ensure(gpa, ctx.io, ctx.environ)) |info| {
            broker_port = info.port;
            broker_tok = info.token;
        }
    }
    const browser_helper: []const u8 = if (broker_port != 0 and (ctx.roam or browserEnabled(ctx))) BROWSER_HELPER_PY else "";
    const mcp_helper: []const u8 = if (broker_port != 0 and (ctx.roam or mcpEnabled(ctx))) MCP_HELPER_PY else "";
    const src = std.fmt.allocPrint(gpa, "{s}{s}{s}{s}{s}", .{ guard, preamble, browser_helper, mcp_helper, body }) catch return dupe(gpa, "oom");
    defer gpa.free(src);
    // slugified scope: ':' in chat:{conv}/sched:{tid} scopes is an ADS/portability hazard in filenames
    var scope_buf: [64]u8 = undefined;
    const script_name = std.fmt.allocPrint(gpa, ".authored-{s}-{s}.py", .{ slugify(&scope_buf, ctx.scope), name }) catch return dupe(gpa, "oom");
    defer gpa.free(script_name);
    const script = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, script_name }) catch return dupe(gpa, "oom");
    defer gpa.free(script);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = script, .data = src }) catch return dupe(gpa, "could not write tool script");
    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    prepChildEnv(gpa, ctx.io, &env);
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
    if (broker_port != 0) {
        var ub: [64]u8 = undefined;
        if (std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/", .{broker_port})) |url| env.put("NL_BROWSER_BROKER", url) catch {} else |_| {}
        env.put("NL_BROWSER_BROKER_TOKEN", broker_tok) catch {};
        env.put("NL_BROWSER_KEY", ctx.run_dir) catch {};
    }
    const aj = if (std.mem.trim(u8, args_json, " \r\n\t").len == 0) "{}" else args_json;
    const py = deps.pythonBin(ctx.io, &env);
    var cap_buf: [10]u8 = undefined;
    const argv = [_][]const u8{ py, "-c", PYRUN, pyrunCapArg(ctx.environ, &cap_buf), script_name, aj };
    var r = pyrunRun(gpa, ctx.io, &argv, ctx.workdir, &env, ctx.environ);
    defer r.deinit(gpa);
    // spawn-missing (python absent) → the dep hint; a script that ran and failed exits non-zero and is
    // handled below, never here.
    if (r.end == .unstarted) return if (deps.isSpawnMissing(r.err.?)) deps.hint(gpa, "python") else dupe(gpa, "tool failed to run");
    const exit = pyrunExit(&r);
    if (exit == 0) {
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, r.stdout, " \r\n\t"), '\n');
        var jline: ?[]const u8 = null;
        while (lines.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \r\n\t");
            if (t.len > 0 and t[0] == '{') jline = t;
        }
        if (jline) |jl| return dupe(gpa, clip(jl, 4000));
    }
    const note = pyrunNote(gpa, ctx.environ, &r);
    defer gpa.free(note);
    return std.fmt.allocPrint(gpa, "exit={d}\nstdout:\n{s}\nstderr:\n{s}{s}", .{ exit, clip(r.stdout, 3000), clip(r.stderr, 1500), note }) catch dupe(gpa, "ran");
}

/// Strip mis-decoded control bytes that smart punctuation (curly quotes / em-dashes) lands as when the model's
/// text is mangled — they are INVISIBLE, compound on every read->rewrite, and make a prose deliverable unshippable.
/// Removes C0 controls (0x00-0x1f) and DEL (0x7f), KEEPING newline (0x0a) and carriage-return (0x0d); a TAB (0x09)
/// is kept only when it is NOT wedged between two alphanumerics (preserves code indentation, drops in-word
/// corruption). gpa-owned copy; input unchanged. Near-always a structural no-op for clean text.
fn sanitizeModelText(gpa: std.mem.Allocator, s: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.ensureTotalCapacity(gpa, s.len) catch return dupe(gpa, s);
    for (s, 0..) |c, i| {
        if (c == '\n' or c == '\r') {
            out.append(gpa, c) catch {};
            continue;
        }
        if (c == '\t') {
            const prev_an = i > 0 and std.ascii.isAlphanumeric(s[i - 1]);
            const next_an = i + 1 < s.len and std.ascii.isAlphanumeric(s[i + 1]);
            if (prev_an and next_an) continue;
            out.append(gpa, c) catch {};
            continue;
        }
        if (c < 0x20 or c == 0x7f) continue;
        out.append(gpa, c) catch {};
    }
    return out.toOwnedSlice(gpa) catch dupe(gpa, s);
}

/// Case-insensitive LAST index of `needle` in `hay` (closing tags live at the very end of a doc). null if absent.
fn ciLastIndexOf(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    var i: usize = hay.len - needle.len + 1;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// The byte offset to splice appended BODY content in FRONT of, for a file that already closed an HTML/XML
/// document: before the last </body> (else the last </html>). null when there is no such closing tag (a code
/// file → tail-append as usual). A naive tail-append onto an already-closed page lands the next chunk AFTER
/// </html>, outside the document. Only the tail is scanned — closers live at the end.
fn htmlCloseInsert(prior: []const u8) ?usize {
    const from = if (prior.len > 8192) prior.len - 8192 else 0;
    const tail = prior[from..];
    if (ciLastIndexOf(tail, "</body>")) |r| return from + r;
    if (ciLastIndexOf(tail, "</html>")) |r| return from + r;
    return null;
}

test "readLineWindow returns the requested 1-indexed inclusive line window past the byte-clip head" {
    const gpa = std.testing.allocator;
    const text = "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10";
    {
        const w = readLineWindow(gpa, text, 3, 5);
        defer gpa.free(w);
        try std.testing.expect(std.mem.startsWith(u8, w, "[lines 3-5 of 10]\n"));
        try std.testing.expect(std.mem.indexOf(u8, w, "L3\nL4\nL5\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, w, "L2") == null); // before the window
        try std.testing.expect(std.mem.indexOf(u8, w, "L6") == null); // after the window
    }
    {
        // end past EOF clamps to the last line
        const w = readLineWindow(gpa, text, 9, 999);
        defer gpa.free(w);
        try std.testing.expect(std.mem.startsWith(u8, w, "[lines 9-10 of 10]\n"));
        try std.testing.expect(std.mem.indexOf(u8, w, "L10") != null);
    }
    {
        // start past EOF explains instead of returning nothing
        const w = readLineWindow(gpa, text, 50, 60);
        defer gpa.free(w);
        try std.testing.expect(std.mem.indexOf(u8, w, "past the end") != null);
    }
}

test "htmlCloseInsert: body fragments splice before </body>; code files append at the end" {
    // an already-closed HTML doc → splice point is right at </body> (fragment lands inside the page)
    const html = "<!DOCTYPE html><html><body><h1>hi</h1></body></html>";
    try std.testing.expectEqualStrings("</body></html>", html[htmlCloseInsert(html).?..]);
    // chunk 1 left the doc OPEN (no </body>/</html> yet) → tail-append (null)
    try std.testing.expect(htmlCloseInsert("<!DOCTYPE html><html><body><h1>hi</h1>") == null);
    // a code file has no closing tag → tail-append (null)
    try std.testing.expect(htmlCloseInsert("def f():\n    return 1\n") == null);
    // </html> present without </body> → splice before </html>
    const x = "<svg>...</svg></HTML>";
    try std.testing.expectEqualStrings("</HTML>", x[htmlCloseInsert(x).?..]);
}

/// Repair the invalid-JSON shapes models actually emit in tool arguments — the reason "write_file often
/// fails in swarm mode":
///   1. RAW control characters inside string literals (a code file's newlines pasted unescaped into
///      "content") — the dominant failure; std.json rightly rejects them. Escaped here.
///   2. A TRUNCATED tail (the provider cut the arguments mid-string) — the string and any open
///      containers are closed so the part that DID arrive still lands; `truncated` reports it so the
///      caller can tell the model to append the rest.
///   3. Prose before the first '{' and trailing garbage after the balanced object — both dropped.
/// Returns a gpa-owned repaired document, or null when repair can't produce one (caller falls back to
/// the original error message).
fn repairToolJson(gpa: std.mem.Allocator, raw: []const u8, truncated: *bool) ?[]u8 {
    truncated.* = false;
    var i: usize = 0;
    while (i < raw.len and raw[i] != '{') i += 1; // models sometimes preface arguments with prose
    if (i == raw.len) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var stack: [16]u8 = undefined; // open-container stack so a truncated array closes with ']' not '}'
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (in_str) {
            if (esc) {
                esc = false;
                out.append(gpa, c) catch return null;
                continue;
            }
            switch (c) {
                '\\' => {
                    esc = true;
                    out.append(gpa, c) catch return null;
                },
                '"' => {
                    in_str = false;
                    out.append(gpa, c) catch return null;
                },
                '\n' => out.appendSlice(gpa, "\\n") catch return null,
                '\r' => out.appendSlice(gpa, "\\r") catch return null,
                '\t' => out.appendSlice(gpa, "\\t") catch return null,
                else => {
                    if (c < 0x20) {
                        var b: [8]u8 = undefined;
                        out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch return null) catch return null;
                    } else out.append(gpa, c) catch return null;
                },
            }
            continue;
        }
        switch (c) {
            '"' => {
                in_str = true;
                out.append(gpa, c) catch return null;
            },
            '{', '[' => {
                if (depth >= stack.len) return null; // absurd nesting — not tool arguments
                stack[depth] = if (c == '{') '}' else ']';
                depth += 1;
                out.append(gpa, c) catch return null;
            },
            '}', ']' => {
                if (depth == 0) return null; // malformed beyond repair
                depth -= 1;
                out.append(gpa, c) catch return null;
                if (depth == 0) break; // balanced object complete — drop any trailing garbage
            },
            else => out.append(gpa, c) catch return null,
        }
    }
    if (in_str) { // cut off mid-string: close it (a dangling lone '\' would escape our closing quote)
        if (esc) _ = out.pop();
        out.append(gpa, '"') catch return null;
        truncated.* = true;
    }
    while (depth > 0) { // close whatever containers the truncation left open, innermost first
        depth -= 1;
        out.append(gpa, stack[depth]) catch return null;
        truncated.* = true;
    }
    return gpa.dupe(u8, out.items) catch null;
}

test "repairToolJson: raw newlines escape, truncation closes, prose/garbage drop, arrays close right" {
    const gpa = std.testing.allocator;
    var trunc = false;
    // 1: raw control chars inside a string become escapes — the swarm write_file failure shape
    const r1 = repairToolJson(gpa, "{\"path\":\"a.txt\",\"content\":\"line1\nline2\tend\"}", &trunc).?;
    defer gpa.free(r1);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\",\"content\":\"line1\\nline2\\tend\"}", r1);
    try std.testing.expect(!trunc);
    // 2: truncated mid-string closes cleanly and reports it
    const r2 = repairToolJson(gpa, "{\"path\":\"a.txt\",\"content\":\"partial fi", &trunc).?;
    defer gpa.free(r2);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\",\"content\":\"partial fi\"}", r2);
    try std.testing.expect(trunc);
    // 3: prose prefix + trailing garbage drop; nested array closes with ']'
    const r3 = repairToolJson(gpa, "Here you go: {\"ops\":[{\"op\":\"replace\"", &trunc).?;
    defer gpa.free(r3);
    try std.testing.expectEqualStrings("{\"ops\":[{\"op\":\"replace\"}]}", r3);
    try std.testing.expect(trunc);
    const r4 = repairToolJson(gpa, "{\"path\":\"x\"} and then some", &trunc).?;
    defer gpa.free(r4);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", r4);
}

test "a salvaged tool call OWNS its strings — the repair buffer is freed while the parsed value is still in use" {
    const gpa = std.testing.allocator;
    // The invariant both salvage sites depend on. std.json's default for a slice input is .alloc_if_needed:
    // a string with no escapes comes back as a SLICE INTO the input. The repair buffer is function-local and
    // freed as soon as the salvage block exits, so under the default every salvaged `path`/`content` dangled —
    // write_file then reported "could not write file" for whatever the freed pages happened to hold. Assert
    // the aliasing directly (a symptom test would depend on allocator recycling luck).
    const A = struct { path: []const u8 = "", content: []const u8 = "" };
    var trunc = false;
    const rep = repairToolJson(gpa, "{\"path\": \"demo.html\", \"content\": \"<h1>partial", &trunc).?;
    try std.testing.expect(trunc);
    const p = try std.json.parseFromSlice(A, gpa, rep, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer p.deinit();
    const lo = @intFromPtr(rep.ptr);
    const hi = lo + rep.len;
    try std.testing.expect(@intFromPtr(p.value.path.ptr) < lo or @intFromPtr(p.value.path.ptr) >= hi);
    try std.testing.expect(@intFromPtr(p.value.content.ptr) < lo or @intFromPtr(p.value.content.ptr) >= hi);
    gpa.free(rep); // exactly what the salvage block's `defer` does, while `p` is still the live value
    try std.testing.expectEqualStrings("demo.html", p.value.path);
    try std.testing.expectEqualStrings("<h1>partial", p.value.content);
}

fn writeFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { path: []const u8 = "", content: []const u8 = "", mode: []const u8 = "overwrite" };
    var salvage_note: []const u8 = "";
    var truncated = false; // KNOWN-incomplete content (cut-off salvage) — the syntax note below must not double-flag it
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch blk_rep: {
        // strict parse failed — repair the arguments (raw newlines in "content", a cut-off tail) and
        // retry, so the file the model already composed lands instead of evaporating into an error.
        var trunc = false;
        const rep = repairToolJson(gpa, args_json, &trunc) orelse
            return dupe(gpa, "write_file arguments were not valid JSON — your file was likely too long and got cut off. Write a shorter version (or fewer changes this turn), then improve it next turn.");
        defer gpa.free(rep);
        // .alloc_always is LOAD-BEARING, not a style choice. std.json's default for a slice input is
        // .alloc_if_needed: a string with no escapes comes back as a SLICE INTO `rep`, which this block frees
        // on the way out — so `path`/`content` became dangling pointers the moment the salvage succeeded, and
        // write_file reported "could not write file" for garbage bytes. It read as a filesystem failure and
        // cost five 4096-token turns in one build. Forcing copies makes the parsed value own its strings, so
        // the repaired buffer is genuinely free to go.
        const p2 = std.json.parseFromSlice(A, gpa, rep, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return dupe(gpa, "write_file arguments were not valid JSON — your file was likely too long and got cut off. Write a shorter version (or fewer changes this turn), then improve it next turn.");
        truncated = trunc;
        salvage_note = if (trunc)
            " NOTE: your arguments were CUT OFF mid-content — I closed and wrote what arrived. read_file to see where it stops, then send the REST with mode:\"append\"."
        else
            " NOTE: your content carried raw (unescaped) newlines — repaired this time; emit \\n escapes in JSON strings.";
        break :blk_rep p2;
    };
    defer p.deinit();
    if (!safeRel(p.value.path)) return dupe(gpa, "bad path — use a path RELATIVE to your workdir (no leading / or \\, no '..'), e.g. index.html or css/style.css");
    if ((ctx.operating or ctx.app_attach) and reservedBusName(p.value.path)) return dupe(gpa, "that name is a reserved OPERATE-bus/oracle file — the swarm cannot write it directly. Act on the attached host through host_command / host_explore (which adjudicate irreversible actions); the acceptance oracle (score.json) and the command bus (commands.jsonl) are never authored by a mind.");
    const npath = blk_np: {
        const wb = std.fs.path.basename(ctx.workdir);
        if (wb.len > 0 and p.value.path.len > wb.len + 1 and std.mem.startsWith(u8, p.value.path, wb) and p.value.path[wb.len] == '/')
            break :blk_np p.value.path[wb.len + 1 ..];
        break :blk_np p.value.path;
    };
    const redirected = ctx.one_slot and ctx.slot_path.len > 0 and !std.mem.eql(u8, npath, ctx.slot_path);
    const wpath = if (redirected) ctx.slot_path else npath;
    if (ctx.one_slot and ctx.blueprint.len > 0 and blueprintHas(ctx.blueprint, wpath) and !pathKeyMatch(ctx.slot_path, wpath)) {
        // r2+ FRONTIER RESCUE, mirroring the teammate-guard rescue below: the first still-unbuilt
        // blueprint file IS the team's current piece — writing it cannot jump ahead, and with nothing
        // in the manifest there is nothing to clobber. Without this valve the guard composes with the
        // salvage length floor into a deadlock no mind can escape.
        const frontier_rescue = ctx.round > 1 and !builtAlready(ctx, wpath) and isFrontierFile(ctx, wpath);
        if (!frontier_rescue) {
            noteWriteReject(ctx, wpath, " — write refused: single-author ordered file, not this mind's slot; ");
            const yours = if (ctx.slot_path.len > 0) std.fmt.allocPrint(gpa, " YOUR file this round is `{s}` — write that, not this.", .{ctx.slot_path}) catch "" else " You have no deliverable file this round — research the upcoming pieces, share what you learn, or create a NEW helper file.";
            defer if (yours.len > 0 and ctx.slot_path.len > 0) gpa.free(@constCast(yours));
            return std.fmt.allocPrint(gpa, "`{s}` is an ordered deliverable file with a single author this round — overwriting it would clobber finished work or jump ahead of the team's current piece.{s}", .{ wpath, yours }) catch dupe(gpa, "that ordered file belongs to its builder this round — don't overwrite it");
        }
    }
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, wpath }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    // A write into the mind's OWN engine-assigned slot always stands: a strategy-override slot (a built file
    // being FIXED) can simultaneously sit in a teammate's deepen-phase my_files list, and without this
    // exemption the pinned mind's every write_file is rejected as "a teammate's file" — dead for exactly the
    // mind the orchestrator sent to fix the bottleneck.
    const is_own_slot = ctx.slot_path.len > 0 and pathKeyMatch(ctx.slot_path, wpath);
    if (!is_own_slot and ctx.owned_by_others.len > 0 and fileOwnedBy(ctx.owned_by_others, wpath) and !fileOwnedBy(ctx.my_files, wpath)) {
        const rescue = ctx.round > 1 and !builtAlready(ctx, wpath);
        if (!rescue) {
            noteWriteReject(ctx, wpath, " — write refused: a teammate owns it this round; ");
            return std.fmt.allocPrint(gpa, "{s} is a teammate's file this round — they own it in the blueprint and are building it in parallel, so writing it would collide (last-writer-wins) and waste the work. YOUR files: {s}. Write or DEEPEN one of yours that isn't done, or create a genuinely NEW file in nobody's slice. To change a file you don't own, read_file it and send_message its owner — don't rewrite it.", .{ wpath, if (ctx.my_files.len > 0) ctx.my_files else "(none assigned — take an unbuilt blueprint file or a new one)" }) catch dupe(gpa, "that file is a teammate's this round — write one of yours instead");
        }
    }
    // SAME-ROUND SERIALIZATION — ownership decides who MAY write, this checks who already DID: a full
    // overwrite of a file a teammate LANDED this round throws their finished repair away wholesale. First
    // landed write wins the round; a latecomer is routed to read + edit_file (the VCS merge path, anchor-
    // guarded against staleness) or to a different failing point. Appends stay open (additive), and the
    // ledger is round-scoped so the file is freely rewritable next round.
    if (!std.mem.eql(u8, p.value.mode, "append")) {
        lockFiles(ctx);
        const landed = sameRoundWriter(ctx, wpath);
        unlockFiles(ctx);
        if (landed) |who| {
            defer gpa.free(who);
            noteWriteReject(ctx, wpath, " — write refused: a teammate already rebuilt it this round; ");
            return std.fmt.allocPrint(gpa, "{s} was already rebuilt by {s} THIS round — overwriting it now would throw their landed work away (last-writer-wins). read_file it first: if something in it is still wrong, fix JUST those lines with edit_file (which merges concurrent changes); otherwise take a DIFFERENT failing point or file this round.", .{ wpath, who }) catch dupe(gpa, "a teammate already rebuilt that file this round — read it and edit_file the exact lines, or take a different failing point");
        }
    }
    if (std.fs.path.dirname(full)) |dir| _ = std.Io.Dir.cwd().createDirPathStatus(ctx.io, dir, .default_dir) catch {};
    const clean = sanitizeModelText(gpa, p.value.content);
    defer gpa.free(clean);
    // A file body must never carry the engine's own edit protocol — language-blind by construction (this
    // detects OUR markers, not any language's syntax), so it guards every toolchain the goal can declare.
    if (bufedit.editMarkerCorruption(clean))
        return dupe(gpa, "write REJECTED — your content contains SEARCH/REPLACE or merge-conflict marker lines (<<<<<<< / >>>>>>>): that is an EDIT SCRIPT, not a file body. To change an existing file, call edit_file with ops; to write this file, send the complete final body with ZERO marker lines.");
    // The read view pasted back as content. Anchor tags are an ADDRESSING scheme layered over a read; committing
    // them would leave every line of the file prefixed with `42:abc:def→` — and since a read is exactly what a
    // model reaches for before rewriting a file it just edited, this is the write that would follow a tagged
    // read most naturally. Same shape of guard as the marker check above, for the same reason.
    if (hashline.taggedBody(clean))
        return dupe(gpa, "write REJECTED — your content still carries the read view's anchor tags (`42:abc:def\u{2192}` at the start of most lines). Those tags are addressing for edit_file, NOT part of the file: they exist so you can point at a line without retyping it. To CHANGE this file, call edit_file with those tags as anchors (no re-emitting); to write it, send the file's real lines with every tag prefix stripped.");
    const is_append = std.mem.eql(u8, p.value.mode, "append") and p.value.content.len > 0;
    var final_bytes: usize = clean.len;
    var restarted = false;
    if (is_append) {
        const prior = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(256 << 10)) catch &[_]u8{};
        defer if (prior.len > 0) gpa.free(prior);
        // A .py append that RE-DEFINES a top-level name the file already has can NOT be glued (it doubles the
        // definition) and can NOT be trusted as a whole-file rewrite either (a chunked build's next part often
        // sloppily re-emits one earlier def; replacing the file would destroy chunk 1's other definitions). The
        // only safe move is REJECT with the exact conflicting name and route the model to edit_file / a clean
        // append / an explicit overwrite.
        // Python keeps its decorator-aware check (a real parser reading a real language); EVERY file — any
        // extension, or none — then goes through the language-blind one, which learns what a definition looks
        // like from the file it is handed.
        const redef: ?[]const u8 = (if (std.mem.endsWith(u8, wpath, ".py")) pyAppendRedefines(prior, clean) else null) orelse
            appendRedefines(gpa, prior, clean);
        if (appendRestartsFile(prior, clean)) {
            restarted = true;
            if (!writeWorkFileAtomic(ctx, full, clean)) return dupe(gpa, "could not write file");
        } else if (redef) |nm| {
            return std.fmt.allocPrint(gpa, "append REJECTED — your body RE-DEFINES `{s}`, which {s} already defines at top level; gluing it on would leave two copies of the same definition, and replacing the file could destroy earlier work. To CHANGE an existing definition use edit_file (SEARCH its exact current lines, REPLACE with the fix); to truly append, send only NEW code that does not re-define existing names; to intentionally REWRITE the whole file, use write_file mode:\"overwrite\".", .{ nm, wpath }) catch dupe(gpa, "append rejected: body re-defines existing top-level names — use edit_file instead");
        } else {
            var joined: std.ArrayListUnmanaged(u8) = .empty;
            defer joined.deinit(gpa);
            // STRUCTURED APPEND: if the prior chunk already CLOSED an HTML/XML document, splice the new body
            // content in BEFORE the closing </body> (else </html>) so a chunked page assembles into ONE valid
            // document — a naive tail-append lands the next section AFTER </html>, outside the page. Code files
            // (no closing tag) append at the end as before.
            if (htmlCloseInsert(prior)) |ins| {
                joined.appendSlice(gpa, prior[0..ins]) catch {};
                if (ins > 0 and prior[ins - 1] != '\n') joined.append(gpa, '\n') catch {};
                joined.appendSlice(gpa, clean) catch {};
                if (clean.len > 0 and clean[clean.len - 1] != '\n') joined.append(gpa, '\n') catch {};
                joined.appendSlice(gpa, prior[ins..]) catch {};
            } else {
                joined.appendSlice(gpa, prior) catch {};
                if (prior.len > 0 and prior[prior.len - 1] != '\n') joined.appendSlice(gpa, "\n\n") catch {};
                joined.appendSlice(gpa, clean) catch {};
            }
            if (!writeWorkFileAtomic(ctx, full, joined.items)) return dupe(gpa, "could not write file");
            final_bytes = joined.items.len;
        }
    } else {
        if (!writeWorkFileAtomic(ctx, full, clean)) return dupe(gpa, "could not write file");
    }
    ctx.files_written.* += 1;
    {
        lockFiles(ctx);
        defer unlockFiles(ctx);
        const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{ctx.run_dir}) catch "";
        defer if (mpath.len > 0) gpa.free(mpath);
        if (mpath.len > 0) {
            const existing = std.Io.Dir.cwd().readFileAlloc(ctx.io, mpath, gpa, .limited(64 << 10)) catch &[_]u8{};
            defer if (existing.len > 0) gpa.free(existing);
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(gpa);
            buf.appendSlice(gpa, existing) catch {};
            if (std.fmt.allocPrint(gpa, "{s}|{d}\n", .{ wpath, final_bytes })) |ln| {
                defer gpa.free(ln);
                buf.appendSlice(gpa, ln) catch {};
            } else |_| {}
            std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = mpath, .data = buf.items }) catch {};
        }
        recordRoundWrite(ctx, wpath);
    }
    // SOFT SYNTAX NOTE — write_file must stay salvage-friendly (chunked appends and cut-off salvages are
    // legitimately incomplete), so unlike edit_file this NEVER rejects: the bytes always land. But a plain
    // overwrite (or an append that restarted the file) is a complete-file claim, so when THAT does not
    // parse — the same extension-dispatched gate the edit paths use — say so in the SAME turn instead of
    // letting the global scan report it rounds later. orig="" ⇒ the .py branch also flags internal
    // duplicate defs, the signature corruption of a chunk-glued full write.
    const syntax_note: []const u8 = blk: {
        if (truncated or clean.len == 0 or (is_append and !restarted)) break :blk "";
        const perr = syntaxGateError(ctx, wpath, clean, "") orelse break :blk "";
        defer gpa.free(perr);
        break :blk std.fmt.allocPrint(gpa, " WARNING: as saved, {s} does not parse ({s}) — the write landed anyway. If the file is complete, fix it NOW with edit_file; if you are still sending the rest, continue with mode:\"append\".", .{ wpath, perr }) catch "";
    };
    defer if (syntax_note.len > 0) gpa.free(@constCast(syntax_note));
    if (redirected)
        return std.fmt.allocPrint(gpa, "wrote {s} ({d} bytes) — that is your ONE assigned file this moment, so the write landed there (you named {s}); finish THIS file, then the engine gives you the next.{s}", .{ wpath, final_bytes, p.value.path, syntax_note }) catch dupe(gpa, "wrote");
    if (restarted)
        return std.fmt.allocPrint(gpa, "rewrote {s} — your append RE-STARTED the file (its body opens with the same line the file already starts with), so it REPLACED the old attempt instead of gluing two half-programs together; file is now {d} bytes. To truly append, send only the NEW lines that continue the existing file.{s}", .{ wpath, final_bytes, syntax_note }) catch dupe(gpa, "rewrote");
    return std.fmt.allocPrint(gpa, "{s} {s} — file is now {d} bytes{s}{s}", .{ if (is_append) "appended to" else "wrote", wpath, final_bytes, salvage_note, syntax_note }) catch dupe(gpa, "wrote");
}

/// An "append" whose body RE-OPENS the file (the same first meaningful line as the existing head — the same
/// shebang or the same first import) is a fresh ATTEMPT, not a continuation: gluing it on produces two half-
/// programs that can never parse. Treat it as the rewrite the model actually meant. Lines shorter than 6 chars
/// (`}`, `"""`) never match. SIZE GUARD: a real re-attempt is a whole file, so the body must be at least HALF
/// the prior — a fragment that merely re-emits the import line is a sloppy continuation, and replacing a
/// 200-line module with it would be silent data loss (a repeated import mid-file is a harmless no-op; glue it).
fn appendRestartsFile(prior: []const u8, body: []const u8) bool {
    const a = firstMeaningfulLine(prior);
    if (a.len < 6) return false;
    if (!std.mem.eql(u8, a, firstMeaningfulLine(body))) return false;
    return body.len * 2 >= prior.len;
}

fn firstMeaningfulLine(s: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (t.len > 0) return t;
    }
    return "";
}

/// The name on a COLUMN-0 Python `def`/`async def`/`class` line (nested definitions are indented, so an
/// unstripped scan sees only module-level ones). null for anything else.
fn pyTopDefName(line: []const u8) ?[]const u8 {
    var s = line;
    if (std.mem.startsWith(u8, s, "async ")) s = s[6..];
    const kw: usize = if (std.mem.startsWith(u8, s, "def ")) 4 else if (std.mem.startsWith(u8, s, "class ")) 6 else return null;
    var end = kw;
    while (end < s.len and (std.ascii.isAlphanumeric(s[end]) or s[end] == '_')) : (end += 1) {}
    if (end == kw) return null;
    return s[kw..end];
}

/// The first whitespace-delimited token of a line — the word a language puts in front of a definition
/// (`function`, `class`, `def`, `pub`, `func`, `export`, `impl`, …) without this code having to know which
/// of those any given file uses. "" for a blank line.
fn leadToken(line: []const u8) []const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return t[0..end];
}

/// Is `idx` a COLUMN-0 line that opens an indented body? The universal shape of a definition — a header at
/// the margin with its contents pushed in under it — read off the text rather than off a keyword table.
fn opensIndentedBlock(lines: []const []const u8, idx: usize) bool {
    const ln = lines[idx];
    if (ln.len < 6 or ln[0] == ' ' or ln[0] == '\t') return false;
    var j = idx + 1;
    while (j < lines.len and std.mem.trim(u8, lines[j], " \t\r").len == 0) j += 1; // skip blanks
    if (j >= lines.len) return false;
    return lines[j][0] == ' ' or lines[j][0] == '\t';
}

/// The first definition the append `body` RE-DECLARES — the shape behind "editing a big file leaves duplicate
/// methods". A model whose surgical edit was rejected falls back to appending a corrected copy of one function;
/// appendRestartsFile only REPLACES the file when the body is at least half of it, so anything smaller gets
/// glued on as a second definition. This was a Python-only protection for as long as it existed.
///
/// It knows no languages and no file types. Three signals, all read off the two texts in front of it:
///   1. the appended line sits at column 0 and opens an INDENTED body — a header, in any language
///   2. its leading word is one THIS FILE uses as a definition word (it heads 3+ other column-0 lines) —
///      so `.btn {` in a stylesheet or a lone `<div>` never qualifies, while `function`/`def`/`pub`/`func` do
///   3. the identical header already appears in the file EXACTLY ONCE — a construct the file legitimately
///      repeats (a CSS selector, an HTML tag, a Rust `impl`) is evidently repeatable and left alone; a header
///      that was unique is one the append is about to duplicate
/// Returns the offending header line (borrowed from `body`), or null when the append is safe to glue.
fn appendRedefines(gpa: std.mem.Allocator, prior: []const u8, body: []const u8) ?[]const u8 {
    var plines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer plines.deinit(gpa);
    var pit = std.mem.splitScalar(u8, prior, '\n');
    while (pit.next()) |ln| plines.append(gpa, std.mem.trimEnd(u8, ln, "\r")) catch return null;
    var blines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer blines.deinit(gpa);
    var bit = std.mem.splitScalar(u8, body, '\n');
    while (bit.next()) |ln| blines.append(gpa, std.mem.trimEnd(u8, ln, "\r")) catch return null;
    if (plines.items.len < 3 or blines.items.len == 0) return null;

    for (blines.items, 0..) |bl, bi| {
        if (!opensIndentedBlock(blines.items, bi)) continue;
        const word = leadToken(bl);
        if (word.len == 0) continue;
        // (2) does THIS file treat `word` as a definition word, and (3) is this exact header unique in it?
        var word_heads: usize = 0;
        var exact: usize = 0;
        for (plines.items, 0..) |pl, pi| {
            if (pl.len == 0 or pl[0] == ' ' or pl[0] == '\t') continue;
            if (std.mem.eql(u8, std.mem.trimEnd(u8, pl, " \t"), std.mem.trimEnd(u8, bl, " \t"))) exact += 1;
            if (opensIndentedBlock(plines.items, pi) and std.mem.eql(u8, leadToken(pl), word)) word_heads += 1;
        }
        if (exact == 1 and word_heads >= 3) return bl;
    }
    return null;
}

/// First top-level def/class name the append `body` shares with the existing `prior` — a genuine continuation
/// never re-defines a module-level name the file already has. DECORATED defs are exempt on both sides
/// (@overload / @singledispatch.register / @prop.setter legitimately repeat a name). null = safe to glue.
fn pyAppendRedefines(prior: []const u8, body: []const u8) ?[]const u8 {
    var bprev: []const u8 = "";
    var bit = std.mem.splitScalar(u8, body, '\n');
    while (bit.next()) |bl| {
        defer if (std.mem.trim(u8, bl, " \r\t").len > 0) {
            bprev = std.mem.trim(u8, bl, " \r\t");
        };
        const name = pyTopDefName(bl) orelse continue;
        if (bprev.len > 0 and bprev[0] == '@') continue; // decorated — a legitimate repeated-name form
        var pprev: []const u8 = "";
        var pit = std.mem.splitScalar(u8, prior, '\n');
        while (pit.next()) |pl| {
            defer if (std.mem.trim(u8, pl, " \r\t").len > 0) {
                pprev = std.mem.trim(u8, pl, " \r\t");
            };
            const pn = pyTopDefName(pl) orelse continue;
            if (pprev.len > 0 and pprev[0] == '@') continue;
            if (std.mem.eql(u8, name, pn)) return name;
        }
    }
    return null;
}

/// Compile-check a Python source string via the workdir python. Returns null when it passes (or the check
/// can't run — fail-open), else an owned "line N: message" / "duplicate top-level definition(s): ..." string
/// (caller frees). Beyond the SyntaxError gate, it AST-checks that the edit did not paste a SECOND copy of a
/// top-level def/class the file already had — valid Python, so compile() passes it, but it is the signature
/// corruption of a REPLACE whose text re-emits the whole module. The pre-edit source rides NL_CHK_ORIG so a
/// file that ALREADY carries duplicates stays editable — only
/// NEWLY-introduced duplicates reject. Sources ride env vars so no scratch file is needed.
fn pyCompileError(ctx: *ToolCtx, source: []const u8, orig: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    // Linux caps a single env string at ~128KB (MAX_ARG_STRLEN) — beyond it the spawn E2BIGs and the gate
    // would silently fail open anyway; make that degradation explicit and platform-consistent. An oversized
    // ORIG only disables the dup DIFF (orig := source ⇒ tops(src)-tops(orig) = ∅), keeping the compile gate.
    if (source.len > 80_000) return null;
    var env = ctx.environ.clone(gpa) catch return null;
    defer env.deinit();
    prepChildEnv(gpa, ctx.io, &env);
    env.put("NL_CHK_SRC", source) catch return null;
    env.put("NL_CHK_ORIG", if (orig.len > 80_000) source else orig) catch return null;
    const py = deps.pythonBin(ctx.io, &env);
    // dup check counts only UNDECORATED defs: @overload / @singledispatch.register / @property setters
    // legitimately repeat a top-level name — a decorator means "not a plain redefinition".
    const code = "import os,sys,ast\nsrc=os.environ.get('NL_CHK_SRC','')\ntry:\n compile(src,'<edit>','exec')\nexcept SyntaxError as e:\n sys.stdout.write('line %s: %s'%(getattr(e,'lineno','?'),(e.msg or 'syntax error')));sys.exit(7)\nexcept Exception:\n sys.exit(0)\ntry:\n def tops(s):\n  seen=set();d=set()\n  for n in ast.parse(s).body:\n   if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)) and not n.decorator_list:\n    if n.name in seen: d.add(n.name)\n    seen.add(n.name)\n  return d\n nd=sorted(tops(src)-tops(os.environ.get('NL_CHK_ORIG','')))\n if nd:\n  sys.stdout.write('duplicate top-level definition(s): '+', '.join(nd));sys.exit(8)\nexcept Exception:\n pass\nsys.exit(0)\n";
    const argv = [_][]const u8{ py, "-c", code };
    // BOUND: this gate can run while vcs.commitEdit holds the ONE worker file mutex — an unbounded child
    // (or a Windows handle-inheritance stall) would freeze every mind until the hang watchdog kills the run.
    // bounded.run, because std.process.run's timeout never fires on Windows for a child that prints nothing.
    var r = bounded.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .bound_ms = 15_000, .stdout_limit = 4096, .stderr_limit = 4096 });
    defer r.deinit(gpa);
    const c = r.exited() orelse return null;
    return if (c == 7 or c == 8) (gpa.dupe(u8, std.mem.trim(u8, r.stdout, " \r\n\t")) catch null) else null;
}

test "the python edit gate answers through its bounded run: a SyntaxError or a pasted second copy rejects in python's own words, a clean body passes (real python)" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    var ctx = f.ctx(gpa);
    { // skip only on proof that the interpreter the gate spawns is not on this machine
        const py = deps.pythonBin(ctx.io, &f.env);
        var probe = bounded.run(gpa, ctx.io, .{ .argv = &.{ py, "--version" }, .environ_map = &f.env, .bound_ms = 30_000, .stdout_limit = 256, .stderr_limit = 256 });
        defer probe.deinit(gpa);
        if (!probe.ok()) return error.SkipZigTest; // missing, or the Store alias stub
    }
    const bad = pyCompileError(&ctx, "def f(:\n    pass\n", "") orelse return error.NoSyntaxVerdict;
    defer gpa.free(bad);
    try std.testing.expect(std.mem.startsWith(u8, bad, "line 1: "));
    const dup = pyCompileError(&ctx, "def f():\n    pass\n\ndef f():\n    pass\n", "") orelse return error.NoDuplicateVerdict;
    defer gpa.free(dup);
    try std.testing.expectEqualStrings("duplicate top-level definition(s): f", dup);
    try std.testing.expectEqual(@as(?[]u8, null), pyCompileError(&ctx, "x = 1\n", ""));
}

/// Distinguishes concurrent syntax-gate scratch files; two minds can gate-check in the same run_dir at once.
var chk_seq = std.atomic.Value(u32).init(0);

/// Distill node's --check stderr into one "line N: SyntaxError: ..." verdict. node prints the offending
/// source line, a caret, then a column-0 `SyntaxError: ...` line, then stack frames — the LAST column-0
/// SyntaxError line is the real verdict (a source line that itself starts with the word echoes EARLIER).
/// null when stderr carries no SyntaxError at all: node failing for any other reason (EACCES, bad flag,
/// missing file) must fail the gate OPEN, never reject the edit. Owned; caller frees.
fn jsSyntaxErrLine(gpa: std.mem.Allocator, stderr: []const u8) ?[]u8 {
    var verdict: []const u8 = "";
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trimEnd(u8, ln, " \r\t");
        if (std.mem.startsWith(u8, t, "SyntaxError")) verdict = t;
    }
    if (verdict.len == 0) return null;
    if (verdict.len > 300) verdict = verdict[0..300]; // clip: this rides inside one reject sentence
    // node's first stderr line is "<scratch path>:<lineno>" — salvage the line number from its tail (and
    // never the scratch path itself: a .nlchk-N name would only confuse the mind that edited `app.js`).
    const first_end = std.mem.indexOfScalar(u8, stderr, '\n') orelse stderr.len;
    const first = std.mem.trimEnd(u8, stderr[0..first_end], " \r\t");
    if (std.mem.lastIndexOfScalar(u8, first, ':')) |ci| {
        if (std.fmt.parseInt(u64, first[ci + 1 ..], 10) catch null) |n|
            return std.fmt.allocPrint(gpa, "line {d}: {s}", .{ n, verdict }) catch null;
    }
    return gpa.dupe(u8, verdict) catch null;
}

/// One `node --check` pass over `source`, staged as a run_dir scratch file with extension `ext` — the
/// extension IS node's module-system selector (.cjs forces CommonJS, .mjs forces ESM), which keeps the
/// verdict independent of whatever package.json happens to sit above run_dir. null = parses, or the check
/// could not run (node missing, scratch write failed, timeout) — every non-verdict failure fails OPEN.
fn nodeCheckOnce(ctx: *ToolCtx, source: []const u8, ext: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    const tmp = std.fmt.allocPrint(gpa, "{s}/.nlchk-{d}{s}", .{ ctx.run_dir, chk_seq.fetchAdd(1, .monotonic), ext }) catch return null;
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = source }) catch return null;
    defer std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
    const argv = [_][]const u8{ "node", "--no-warnings", "--check", tmp };
    // ctx.environ must ride along (the main.zig empty-environ gotcha): spawned env-less on Windows, node
    // aborts in OpenSSL's CSPRNG init (no SYSTEMROOT) BEFORE parsing anything — exit 134, no SyntaxError,
    // and the gate silently fails open forever. Same timeout story as the python gate above: this can run
    // while vcs.commitEdit holds the ONE worker file mutex. stderr gets more rope than stdout because node
    // echoes the whole offending source line (minified JS = one huge line) BEFORE the SyntaxError verdict,
    // and a clipped-off verdict = fail-open.
    var r = bounded.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = ctx.environ, .bound_ms = 15_000, .stdout_limit = 4096, .stderr_limit = 16 << 10 });
    defer r.deinit(gpa);
    const c = r.exited() orelse return null;
    return if (c == 0) null else jsSyntaxErrLine(gpa, r.stderr);
}

/// Syntax-check a candidate .js/.mjs/.cjs body via `node --check`. A bare `.js` has no module system of
/// its own — the nearest package.json decides at RUN time, invisible from here — so it must fail as BOTH
/// CommonJS and ESM before it rejects (an `import`-style .js in a type:module project stays editable; a
/// dropped brace breaks under both readings and still rejects). When both fail, return the verdict that
/// names the real break: the CJS one, unless it is just "cannot use import/export outside a module" —
/// that is the dialect talking, not the bug. null = passes or node is missing (fail open); owned else.
fn jsCheckError(ctx: *ToolCtx, npath: []const u8, source: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    if (std.mem.endsWith(u8, npath, ".mjs")) return nodeCheckOnce(ctx, source, ".mjs");
    if (std.mem.endsWith(u8, npath, ".cjs")) return nodeCheckOnce(ctx, source, ".cjs");
    const as_cjs = nodeCheckOnce(ctx, source, ".cjs") orelse return null;
    const as_mjs = nodeCheckOnce(ctx, source, ".mjs") orelse {
        gpa.free(as_cjs);
        return null;
    };
    if (std.mem.indexOf(u8, as_cjs, "outside a module") != null) {
        gpa.free(as_cjs);
        return as_mjs;
    }
    gpa.free(as_mjs);
    return as_cjs;
}

/// Validate a candidate .json body with std.json itself — native, no subprocess, so this gate can never be
/// missing. null when it parses, and null for `//`‑`/*` COMMENT dialects too: tsconfig-style JSONC is a
/// different language owned by its consumer, so the first comment byte fails the whole check OPEN rather
/// than rejecting a file its own toolchain accepts. Anything else non-JSON returns an owned
/// "line N: invalid JSON — ..." verdict (caller frees).
fn jsonParseError(gpa: std.mem.Allocator, source_in: []const u8) ?[]u8 {
    // A UTF-8 BOM is byte noise most JSON consumers tolerate; std.json does not — skip it, don't judge it.
    const source = if (std.mem.startsWith(u8, source_in, "\xEF\xBB\xBF")) source_in[3..] else source_in;
    var diag = std.json.Diagnostics{};
    var scanner = std.json.Scanner.initCompleteInput(gpa, source);
    defer scanner.deinit();
    scanner.enableDiagnostics(&diag);
    while (true) {
        const tok = scanner.next() catch |e| switch (e) {
            error.OutOfMemory, error.BufferUnderrun => return null, // gate trouble is never a verdict — fail open
            error.SyntaxError, error.UnexpectedEndOfInput => {
                const off: usize = @intCast(@min(diag.getByteOffset(), source.len));
                const at = if (off < source.len) source[off] else 0;
                const before = if (off > 0) source[off - 1] else 0;
                if (at == '/' or before == '/') return null; // comment syntax ⇒ JSONC dialect, not ours to judge
                const what: []const u8 = if (e == error.UnexpectedEndOfInput) "the file ends mid-value (truncated?)" else "syntax error";
                return std.fmt.allocPrint(gpa, "line {d}: invalid JSON — {s}", .{ diag.getLine(), what }) catch null;
            },
        };
        if (tok == .end_of_document) return null;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// DROPPED-DEFINITION NOTE: what an edit took away that the file still relies on
// ---------------------------------------------------------------------------------------------------------------

const DefKind = enum { import, def, assign };
const Def = struct { name: []const u8, kind: DefKind };

/// Files past this are not scanned (two whole-file passes per edit; EDIT_MAX_BYTES is far larger).
const DEF_NOTE_MAX_BYTES: usize = 512 * 1024;
/// Names reported per edit, at most.
const DEF_NOTE_MAX_NAMES: usize = 4;
/// A column-0 binding named after one of these is a shadow of a builtin or the commonest of locals: once it is
/// gone, a use of the name is the builtin (or some other binding) again, not a NameError. Imports and defs are
/// never filtered by this — `from os import path` dropped while `path(` is called is exactly the case.
const DEF_NOTE_COMMON = [_][]const u8{ "id", "type", "list", "dict", "set", "str", "int", "float", "bool", "len", "range", "print", "open", "object", "input", "map", "filter", "min", "max", "sum", "any", "all", "next", "iter", "super", "property", "format", "hash", "bytes", "tuple", "sorted", "zip", "enumerate", "self", "cls", "name", "value", "data", "result", "args", "kwargs", "key", "file", "line", "text", "i", "j", "k", "n", "x", "y", "z" };

fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The identifier at the start of `s`, or "" when it does not start with one.
fn identAt(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len and identChar(s[n])) : (n += 1) {}
    if (n == 0 or std.ascii.isDigit(s[0])) return "";
    return s[0..n];
}

fn isCommonName(name: []const u8) bool {
    for (DEF_NOTE_COMMON) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

/// `a, b as c, (d, e)` → the names an import binds (the alias when there is one; `a.b.c` binds `a`).
fn importedNames(gpa: std.mem.Allocator, spec_in: []const u8, out: *std.ArrayListUnmanaged(Def)) !void {
    var spec = spec_in;
    if (std.mem.indexOfScalar(u8, spec, '#')) |h| spec = spec[0..h];
    if (std.mem.indexOf(u8, spec, "//")) |h| spec = spec[0..h];
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |piece_raw| {
        const piece = std.mem.trim(u8, piece_raw, " \t(){};'\"\r");
        if (piece.len == 0) continue;
        if (std.mem.indexOf(u8, piece, " as ")) |a| {
            const alias = identAt(std.mem.trimStart(u8, piece[a + " as ".len ..], " \t"));
            if (alias.len > 0) try out.append(gpa, .{ .name = alias, .kind = .import });
            continue;
        }
        const name = identAt(piece);
        if (name.len > 0) try out.append(gpa, .{ .name = name, .kind = .import });
    }
}

/// The names one line DEFINES, as this reader sees lines: the forms Python, JavaScript/TypeScript and their
/// relatives share. An import at any indentation; `def`/`class`/`function`/`const`/`let`/`var` and a bare
/// `name = …` (or `name: T = …`) only at column 0 — a module-level binding, which is what other code reaches
/// for. Nothing here is a parser: a line it cannot read defines nothing, which can only make the note quieter.
fn lineDefinitions(gpa: std.mem.Allocator, line_in: []const u8, out: *std.ArrayListUnmanaged(Def)) !void {
    const line = std.mem.trimEnd(u8, line_in, " \t\r");
    const body = std.mem.trimStart(u8, line, " \t");
    const lead = line.len - body.len;
    if (body.len == 0 or body[0] == '#' or std.mem.startsWith(u8, body, "//")) return;
    if (std.mem.startsWith(u8, body, "from ")) {
        const at = std.mem.indexOf(u8, body, " import ") orelse return;
        return importedNames(gpa, body[at + " import ".len ..], out);
    }
    if (std.mem.startsWith(u8, body, "import ")) {
        const rest = body["import ".len..];
        if (std.mem.indexOf(u8, rest, " from ")) |f| { // JS: `import x from`, `import {a, b as c} from`, `import * as ns from`
            var spec = rest[0..f];
            if (std.mem.startsWith(u8, spec, "* as ")) spec = spec["* as ".len..];
            return importedNames(gpa, spec, out);
        }
        return importedNames(gpa, rest, out);
    }
    if (lead != 0) return;
    var b = body;
    if (std.mem.startsWith(u8, b, "export default ")) b = b["export default ".len..];
    if (std.mem.startsWith(u8, b, "export ")) b = b["export ".len..];
    if (std.mem.startsWith(u8, b, "async ")) b = b["async ".len..];
    for ([_][]const u8{ "def ", "class ", "function " }) |kw| if (std.mem.startsWith(u8, b, kw)) {
        const name = identAt(std.mem.trimStart(u8, b[kw.len..], " \t"));
        if (name.len > 0) try out.append(gpa, .{ .name = name, .kind = .def });
        return;
    };
    for ([_][]const u8{ "const ", "let ", "var " }) |kw| if (std.mem.startsWith(u8, b, kw)) {
        const name = identAt(std.mem.trimStart(u8, b[kw.len..], " \t"));
        if (name.len > 0) try out.append(gpa, .{ .name = name, .kind = .assign });
        return;
    };
    // a bare `name = …` / `name: T = …` at column 0 (`==` is a comparison, not a binding)
    const name = identAt(b);
    if (name.len == 0) return;
    var rest = std.mem.trimStart(u8, b[name.len..], " \t");
    if (rest.len > 0 and rest[0] == ':') { // an annotation: the binding is at its `=`
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return;
        rest = rest[eq..];
    }
    if (rest.len >= 1 and rest[0] == '=' and !(rest.len >= 2 and rest[1] == '=')) try out.append(gpa, .{ .name = name, .kind = .assign });
}

fn collectDefinitions(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayListUnmanaged(Def)) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lineDefinitions(gpa, line, out);
}

fn definesName(defs: []const Def, name: []const u8) bool {
    for (defs) |d| if (std.mem.eql(u8, d.name, name)) return true;
    return false;
}

/// The first line (1-based) on which `name` is USED in `text` — a whole word that is not an attribute of something
/// else (`x.name`) and not on an import line (there it names a module, not a binding) — and how many such uses
/// there are. null when there is none.
fn firstUse(text: []const u8, name: []const u8) ?struct { line: usize, count: usize } {
    var first: usize = 0;
    var count: usize = 0;
    var ln: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        ln += 1;
        const body = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, body, "import ") or std.mem.startsWith(u8, body, "from ")) continue;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, line, i, name)) |at| {
            i = at + name.len;
            if (at > 0 and (identChar(line[at - 1]) or line[at - 1] == '.')) continue;
            if (i < line.len and identChar(line[i])) continue;
            count += 1;
            if (first == 0) first = ln;
        }
    }
    if (count == 0) return null;
    return .{ .line = first, .count = count };
}

/// WHAT AN EDIT TOOK AWAY THAT THE FILE STILL USES. An edit that removes the line defining or importing a name
/// lands cleanly — the file still compiles (a missing import is a NameError at run time, not a syntax error), the
/// syntax gate stays quiet — and the break surfaces rounds later in a test run, pointing at nothing. Measured on
/// a SWE-bench Lite turn (pytest-7220, 2026-10-14): an edit_file anchored on the wrong line took an `import` with
/// it, every edit reported success, and a full suite run later failed on the name. So the edit's own result says
/// what it dropped: every name whose LAST definition (an import, a column-0 def/class/function, a column-0
/// binding) disappeared in this edit while the result still refers to it. A note, never a rejection — a refactor
/// may drop a definition on purpose and re-add it in a later op — but said in the same round. Reads `before` and
/// `after` whole, so a definition moved elsewhere in the same edit is not reported. gpa-owned, null when there is
/// nothing to say (or nothing it can read: an empty side, a file past DEF_NOTE_MAX_BYTES).
pub fn droppedDefinitionsNote(gpa: std.mem.Allocator, before: []const u8, after: []const u8) ?[]u8 {
    if (before.len == 0 or after.len == 0 or before.len > DEF_NOTE_MAX_BYTES or after.len > DEF_NOTE_MAX_BYTES) return null;
    var was: std.ArrayListUnmanaged(Def) = .empty;
    defer was.deinit(gpa);
    var now: std.ArrayListUnmanaged(Def) = .empty;
    defer now.deinit(gpa);
    collectDefinitions(gpa, before, &was) catch return null;
    collectDefinitions(gpa, after, &now) catch return null;
    var note: std.ArrayListUnmanaged(u8) = .empty;
    defer note.deinit(gpa);
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(gpa);
    var reported: usize = 0;
    for (was.items) |d| {
        if (reported >= DEF_NOTE_MAX_NAMES) break;
        if (d.kind == .assign and isCommonName(d.name)) continue;
        if (definesName(now.items, d.name)) continue; // still defined somewhere: moved, re-added, or never the only one
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, d.name)) {
            dup = true;
        };
        if (dup) continue;
        const use = firstUse(after, d.name) orelse continue; // gone and unused: a deliberate removal
        seen.append(gpa, d.name) catch break;
        const what: []const u8 = switch (d.kind) {
            .import => "an import",
            .def => "a top-level def",
            .assign => "a top-level binding",
        };
        if (reported == 0) {
            note.appendSlice(gpa, "NOTE: this edit removed the only definition of ") catch return null;
        } else note.appendSlice(gpa, ", ") catch return null;
        if (use.count > 1)
            note.print(gpa, "`{s}` ({s}; the file still uses it at line {d} and {d} more place(s))", .{ d.name, what, use.line, use.count - 1 }) catch return null
        else
            note.print(gpa, "`{s}` ({s}; the file still uses it at line {d})", .{ d.name, what, use.line }) catch return null;
        reported += 1;
    }
    if (reported == 0) return null;
    note.appendSlice(gpa, " — if that was not intended, re-add it before moving on; if it was, the remaining use(s) need changing too.") catch return null;
    return note.toOwnedSlice(gpa) catch null;
}

test "an edit that drops the only definition of a name the file still uses says so in the edit's own result" {
    const gpa = std.testing.allocator;
    const before = "import os\nimport sys\nfrom pathlib import Path as P\n\n\ndef main():\n    print(os.getcwd(), P('.'))\n    return sys.argv\n";
    // the wrong-line anchor: the `import os` line replaced by something else; the file still compiles
    const after = "VERSION = 1\nimport sys\nfrom pathlib import Path as P\n\n\ndef main():\n    print(os.getcwd(), P('.'))\n    return sys.argv\n";
    const note = droppedDefinitionsNote(gpa, before, after) orelse return error.MissedDroppedImport;
    defer gpa.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "`os` (an import; the file still uses it at line 7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "`sys`") == null); // still imported: not dropped
    // dropped and no longer used: a deliberate removal, nothing to say
    const gone = "import sys\nfrom pathlib import Path as P\n\n\ndef main():\n    print(P('.'))\n    return sys.argv\n";
    try std.testing.expect(droppedDefinitionsNote(gpa, before, gone) == null);
    // moved rather than dropped (re-imported elsewhere in the same edit): nothing to say
    const moved = "import sys\nfrom pathlib import Path as P\n\n\ndef main():\n    import os\n    print(os.getcwd(), P('.'))\n    return sys.argv\n";
    try std.testing.expect(droppedDefinitionsNote(gpa, before, moved) == null);
    // an attribute of the same name is not a use, and neither is the module named on an import line
    const attr = "import sys\nfrom pathlib import Path as P\nfrom os import path\n\n\ndef main():\n    print(sys.os, P('.'))\n    return sys.argv\n";
    try std.testing.expect(droppedDefinitionsNote(gpa, before, attr) == null);
    // the alias is the bound name: `Path as P` dropped while P is used is reported as P
    const alias_gone = "import os\nimport sys\n\n\ndef main():\n    print(os.getcwd(), P('.'))\n    return sys.argv\n";
    const n2 = droppedDefinitionsNote(gpa, before, alias_gone) orelse return error.MissedDroppedAlias;
    defer gpa.free(n2);
    try std.testing.expect(std.mem.indexOf(u8, n2, "`P` (an import;") != null);
    // a column-0 function removed while a call to it remains, counted in every place
    const fn_before = "import os\n\n\ndef main():\n    return 1\n\n\nprint(main())\nprint(main() + 1)\n";
    const fn_after = "import os\n\n\nprint(main())\nprint(main() + 1)\n";
    const n3 = droppedDefinitionsNote(gpa, fn_before, fn_after) orelse return error.MissedDroppedDef;
    defer gpa.free(n3);
    try std.testing.expect(std.mem.indexOf(u8, n3, "`main` (a top-level def; the file still uses it at line 4 and 1 more place(s))") != null);
    // JavaScript: a dropped top-level const still called; a surviving aliased import is not reported
    const js_before = "const fmt = require('./fmt');\nimport { render as draw } from './view';\n\nfunction main() {\n  draw(fmt(1));\n}\n";
    const js_after = "import { render as draw } from './view';\n\nfunction main() {\n  draw(fmt(1));\n}\n";
    const n4 = droppedDefinitionsNote(gpa, js_before, js_after) orelse return error.MissedDroppedConst;
    defer gpa.free(n4);
    try std.testing.expect(std.mem.indexOf(u8, n4, "`fmt` (a top-level binding; the file still uses it at line 4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, n4, "`draw`") == null);
    // a shadowed builtin is not reported: removing `id = 3` leaves `id(...)` the builtin again
    try std.testing.expect(droppedDefinitionsNote(gpa, "id = 3\nprint(id(4))\n", "print(id(4))\n") == null);
    // a local's reassignment inside a function is not a definition this reads: removing it says nothing
    try std.testing.expect(droppedDefinitionsNote(gpa, "def f():\n    total = 0\n    return total\n", "def f():\n    return total\n") == null);
}

/// EXTENSION-DISPATCHED syntax gate shared by every edit path (and writeFile's soft note): .py compiles via
/// the workdir python (plus its duplicate-def AST diff against `orig`), .js/.mjs/.cjs parse via
/// `node --check`, .json parses natively. null = pass — and every subprocess gate fails OPEN when its
/// toolchain is missing, so a machine without python/node simply has no gate for that language, never a
/// stuck one. Non-null is an owned one-line verdict shaped for editRejectMsg (caller frees).
fn syntaxGateError(ctx: *ToolCtx, npath: []const u8, source: []const u8, orig: []const u8) ?[]u8 {
    if (std.mem.endsWith(u8, npath, ".py")) return pyCompileError(ctx, source, orig);
    if (std.mem.endsWith(u8, npath, ".js") or std.mem.endsWith(u8, npath, ".mjs") or std.mem.endsWith(u8, npath, ".cjs"))
        return jsCheckError(ctx, npath, source);
    if (std.mem.endsWith(u8, npath, ".json")) return jsonParseError(ctx.gpa, source);
    return balanceError(ctx.gpa, source, orig);
}

/// The delimiter pairs the balance gate below can reason about. Not a language list — a file selects which of
/// these apply to it by demonstrably balancing them.
const DELIMS = [_][2]u8{ .{ '{', '}' }, .{ '[', ']' }, .{ '(', ')' } };

/// STRUCTURAL GATE for everything with no parser on hand. `.py`/`.js`/`.json` get real ones; every other file
/// the veil is pointed at — .ts, .zig, .rs, .css, .lua, a config, an extension nobody has thought of yet — had
/// NO gate at all, so an edit that dropped a closing delimiter landed silently and surfaced later as a build
/// failure with nothing pointing back at the edit that caused it.
///
/// Nothing here is keyed on a file type. Each delimiter pair ARMS ITSELF from the file in hand: the pre-edit
/// text must contain enough of that pair to be meaningful AND count to exactly zero, which is the file proving
/// it balances them. Prose, markdown, CSV, a stylesheet with a stray brace in a string — none of them balance
/// under this scan, so none of them get gated. The only edit this can reject is one that BROKE a balance the
/// file demonstrably had, which is precisely the corruption it exists to catch.
fn balanceError(gpa: std.mem.Allocator, source: []const u8, orig: []const u8) ?[]u8 {
    if (orig.len == 0) return null; // a fresh write has no baseline to compare against
    for (DELIMS) |d| {
        const before = delimiterDepth(orig, d[0], d[1]) orelse continue;
        // The file must USE this pair enough for balance to mean something (a handful of parentheses in a
        // paragraph is not a structure) and must count to exactly zero — that is the file proving it balances.
        if (before.depth != 0 or before.count < 8) continue;
        const after = delimiterDepth(source, d[0], d[1]) orelse continue;
        if (after.depth == 0) continue;
        return if (after.depth > 0)
            std.fmt.allocPrint(gpa, "{d} unclosed '{c}' — the result opens more than it closes (it did balance before this edit)", .{ after.depth, d[0] }) catch null
        else
            std.fmt.allocPrint(gpa, "{d} unmatched '{c}' — the result closes more than it opens (it did balance before this edit)", .{ -after.depth, d[1] }) catch null;
    }
    return null;
}

/// Net nesting depth and total occurrences of one delimiter pair, skipping string/char literals and `//` and
/// `/* */` comments — lexical conventions general enough to be near-universal in text formats, and where they
/// do not hold the scan simply refuses to answer. null whenever it cannot trust itself (an unterminated string
/// or comment): the caller treats that as "no verdict" rather than guessing, so an unusual format disarms the
/// gate instead of being fought by it.
fn delimiterDepth(text: []const u8, open: u8, close: u8) ?struct { depth: i32, count: usize } {
    var depth: i32 = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == open) {
            depth += 1;
            count += 1;
            continue;
        }
        if (c == close) {
            depth -= 1;
            count += 1;
            continue;
        }
        switch (c) {
            '/' => {
                if (i + 1 >= text.len) continue;
                if (i > 0 and text[i - 1] == ':') continue; // `http://…` in a url is not a line comment
                if (text[i + 1] == '/') {
                    i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return .{ .depth = depth, .count = count };
                } else if (text[i + 1] == '*') {
                    const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return null;
                    i = end + 1;
                }
            },
            '"', '\'', '`' => {
                var j = i + 1;
                while (j < text.len) : (j += 1) {
                    if (text[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (text[j] == c) break;
                    if (text[j] == '\n' and c != '`') return null; // unterminated on its line: don't guess
                }
                if (j >= text.len) return null;
                i = j;
            },
            else => {},
        }
    }
    return .{ .depth = depth, .count = count };
}

/// One reject message for BOTH edit paths (direct and VCS), so a gate rejection reads identically wherever it
/// fires. `perr` is the syntax gate's output; a "duplicate ..." verdict gets the paste-a-second-copy guidance,
/// anything else the parse-break guidance. Owned; null only on OOM (caller falls back to a static string).
fn editRejectMsg(gpa: std.mem.Allocator, npath: []const u8, perr: []const u8) ?[]u8 {
    if (std.mem.startsWith(u8, perr, "duplicate"))
        return std.fmt.allocPrint(gpa, "edit REJECTED — applying your ops would paste a SECOND copy of code `{s}` already defines ({s}); the file was NOT changed. Never re-emit the whole module inside a REPLACE: SEARCH the exact current lines of the ONE definition you are changing and replace only those lines.", .{ npath, perr }) catch null;
    return std.fmt.allocPrint(gpa, "edit REJECTED — applying your ops would leave `{s}` unparseable ({s}); the file was NOT changed. Your SEARCH/REPLACE likely dropped an indented body or mismatched a block boundary. Re-issue the edit so the RESULT still compiles (copy the anchor lines verbatim, keep every block's indentation).", .{ npath, perr }) catch null;
}

/// Apply a tag-anchored batch: under concurrency it holds the same file lock the micro-VCS uses and
/// re-reads the TRUE head in-lock — anchor validation against that head is the whole merge story (a
/// teammate's change near your lines = staleness with fresh tags, never a silent mis-splice). Runs the
/// same protocol/compile gates as the legacy path, then writes atomically and records the manifest row.
fn hashlineApply(ctx: *ToolCtx, npath: []const u8, full: []const u8, original: []const u8, hops: []const hashline.Op) []u8 {
    const gpa = ctx.gpa;
    var locked = false;
    if (ctx.vcs_enabled) if (ctx.fmtx) |m| {
        m.lockUncancelable(ctx.io);
        locked = true;
    };
    defer if (locked) ctx.fmtx.?.unlock(ctx.io);
    const head = blk: {
        if (locked) {
            if (std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(EDIT_MAX_BYTES))) |h| break :blk h else |_| {}
        }
        break :blk gpa.dupe(u8, original) catch return dupe(gpa, "oom");
    };
    defer gpa.free(head);
    switch (hashline.applyBatch(gpa, head, hops)) {
        .err => |e| return e, // owned; carries fresh tags + the atomic-batch retry instruction
        .ok => |ap| {
            defer gpa.free(ap.summary);
            defer gpa.free(ap.content);
            if (bufedit.editMarkerCorruption(ap.content) and !bufedit.editMarkerCorruption(head))
                return dupe(gpa, "edit rejected — the result would ADD SEARCH/REPLACE / merge-conflict marker lines to the file: your `text` itself carries edit-script fences. Put ONLY the final code lines in `text` — never <<<<<<< SEARCH / ======= / >>>>>>> REPLACE.");
            if (syntaxGateError(ctx, npath, ap.content, head)) |perr| {
                defer gpa.free(perr);
                return editRejectMsg(gpa, npath, perr) orelse dupe(gpa, "edit rejected: result does not compile");
            }
            const dropped = droppedDefinitionsNote(gpa, head, ap.content);
            defer if (dropped) |d| gpa.free(d);
            if (!writeWorkFileAtomic(ctx, full, ap.content)) return dupe(gpa, "could not write the edited file");
            ctx.files_written.* += 1;
            {
                // DEADLOCK. lockFiles takes ctx.fmtx — the SAME mutex this function already holds when it read
                // HEAD in-lock, and std.Io.Mutex is not reentrant. So a tag-anchored edit under vcs_enabled
                // (a multi-mind cast, and now every chat edit) hung HERE, forever, holding the file lock: the
                // mind never returned, and every other writer behind that lock stopped too. Acquire only when
                // this function is not already the holder.
                if (!locked) lockFiles(ctx);
                defer if (!locked) unlockFiles(ctx);
                const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{ctx.run_dir}) catch "";
                defer if (mpath.len > 0) gpa.free(mpath);
                if (mpath.len > 0) {
                    const existing = std.Io.Dir.cwd().readFileAlloc(ctx.io, mpath, gpa, .limited(64 << 10)) catch &[_]u8{};
                    defer if (existing.len > 0) gpa.free(existing);
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(gpa);
                    buf.appendSlice(gpa, existing) catch {};
                    if (std.fmt.allocPrint(gpa, "{s}|{d}\n", .{ npath, ap.content.len })) |ln| {
                        defer gpa.free(ln);
                        buf.appendSlice(gpa, ln) catch {};
                    } else |_| {}
                    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = mpath, .data = buf.items }) catch {};
                }
                recordRoundWrite(ctx, npath);
            }
            return std.fmt.allocPrint(gpa, "edited {s} — {d} tagged op(s) applied atomically; file is now {d} bytes.\n{s}{s}{s}", .{ npath, hops.len, ap.content.len, ap.summary, if (dropped != null) "\n" else "", dropped orelse "" }) catch dupe(gpa, "edited");
        },
    }
}

/// Ceiling on a file edit_file will load. Deliberately well above the 1MiB the edit paths used to cap at: a
/// large EXISTING file is exactly the case where a surgical edit matters most, and refusing it pushed the model
/// onto write_file — a full rewrite of a file it has only ever seen the head of. ALIASES vcs.MAX_FILE_BYTES so
/// editFile, hashlineApply's in-lock head re-read, and the micro-VCS commit can never disagree about what is
/// editable (a file one accepts and another cannot read is an edit that fails forever).
const EDIT_MAX_BYTES: usize = vcs.MAX_FILE_BYTES;

/// The rejection for an op whose `anchor` (or `end`) is several lines of the tagged read view; null when `raw` is
/// not that. It names the RANGE form with the block's own first and last tags filled in, so the retry is a copy,
/// not a re-read — the same courtesy the stale-tag errors extend. Owned.
fn spannedAnchorReject(gpa: std.mem.Allocator, op_n: usize, field: []const u8, raw: []const u8) ?[]u8 {
    const sp = hashline.spannedTagAnchor(raw) orelse return null;
    var fb: [24]u8 = undefined;
    var lb: [24]u8 = undefined;
    const first = hashline.formatAnchor(sp.first, &fb);
    const last = if (sp.last) |l| hashline.formatAnchor(l, &lb) else "<the block's LAST line tag>";
    if (std.mem.eql(u8, field, "end"))
        return std.fmt.allocPrint(gpa, "op{d} REJECTED (nothing was changed) — its `end` spans {d} lines of the read view. `end` is ONE tag: the LAST line of the anchor..end range, e.g. \"end\":\"{s}\".", .{ op_n, sp.lines, last }) catch dupe(gpa, "op REJECTED — `end` must be ONE tag, the range's last line");
    // What the op would have done unrejected depends on the paste, so only claim it where it is true. With the read
    // view's arrow on the first line, parseAnchor reads the whole block as that line's tag and the op lands on it
    // alone; a block of bare tags (no arrows) parses as no tag at all and only ever reached the text matcher's
    // no-match.
    var wb: [128]u8 = undefined;
    const would: []const u8 = if (hashline.parseAnchor(raw) != null)
        std.fmt.bufPrint(&wb, ": this op would have acted on line {d} alone and left the rest of that block in the file", .{sp.first.line}) catch ""
    else
        "";
    return std.fmt.allocPrint(gpa, "op{d} REJECTED (nothing was changed) — its `{s}` spans {d} lines of the read view, but a tag names ONE line{s}. To replace or delete the block, use the anchor..end range form — the FIRST line's tag in `anchor`, the LAST line's in `end` (inclusive): \"anchor\":\"{s}\",\"end\":\"{s}\". To insert beside it, anchor on the single line you insert before or after.", .{ op_n, field, sp.lines, would, first, last }) catch dupe(gpa, "op REJECTED — a multi-line anchor names only its first line; use anchor = the first line's tag and end = the last line's tag");
}

fn editFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    // Accept BOTH edit dialects: the hive prompt teaches {op, anchor, text}; the chat prompt teaches
    // {search, replace} (no op). Parsing only anchor/text silently drops search/replace, so every chat edit
    // runs with an EMPTY anchor and fails as a phantom "edit conflict". `search`/`replace` are aliases; `op`
    // defaults to "replace".
    const OpJson = struct { op: []const u8 = "", anchor: []const u8 = "", search: []const u8 = "", text: []const u8 = "", replace: []const u8 = "", at: usize = 0, end: []const u8 = "", end_anchor: []const u8 = "" };
    // Top-level `search`/`replace` too: a FLAT {path, search, replace} call (no ops array) is what an XML-shaped
    // tool call converts to, and some models emit it directly — treat it as a single replace op.
    const A = struct { path: []const u8 = "", ops: []const OpJson = &.{}, search: []const u8 = "", replace: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch blk_rep: {
        // same repair as write_file: escaped control chars / a closed-off truncated tail beat an error
        var trunc = false;
        const rep = repairToolJson(gpa, args_json, &trunc) orelse
            return dupe(gpa, "edit_file arguments were not valid JSON (likely cut off) — send fewer/smaller ops this turn.");
        defer gpa.free(rep);
        // .alloc_always for the same reason as write_file's salvage above: without it every parsed string is a
        // slice into `rep`, which this block frees — so a cut-off edit_file batch ran its ops against freed
        // memory. Copies here, freedom to release `rep` there.
        break :blk_rep std.json.parseFromSlice(A, gpa, rep, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return dupe(gpa, "edit_file arguments were not valid JSON (likely cut off) — send fewer/smaller ops this turn.");
    };
    defer p.deinit();
    if (!safeRel(p.value.path)) return dupe(gpa, "bad path — use a path RELATIVE to your workdir (no leading / or \\, no '..'), e.g. index.html or css/style.css");
    if ((ctx.operating or ctx.app_attach) and reservedBusName(p.value.path)) return dupe(gpa, "that name is a reserved OPERATE-bus/oracle file — the swarm cannot edit it directly. Act on the attached host through host_command / host_explore, never by editing the bus.");
    if (p.value.ops.len == 0 and p.value.search.len == 0) return dupe(gpa, "edit_file needs either an ops array (each op replace/insert_before/insert_after/delete with an exact anchor) OR a top-level search+replace.");
    const npath = blk_np: {
        const wb = std.fs.path.basename(ctx.workdir);
        if (wb.len > 0 and p.value.path.len > wb.len + 1 and std.mem.startsWith(u8, p.value.path, wb) and p.value.path[wb.len] == '/')
            break :blk_np p.value.path[wb.len + 1 ..];
        break :blk_np p.value.path;
    };
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, npath }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    // A file BIGGER than the ordinary slurp cap must still be editable. The old single read capped at 1MiB and
    // reported failure as "{path} does not exist … use write_file to create a new one" — for a large EXISTING
    // file that is a lie that ends in a destructive from-scratch overwrite, i.e. the worst outcome of the very
    // failure mode edit_file exists to prevent. Stat first: only a genuinely absent file says "does not exist",
    // and a file past even the raised ceiling says so honestly and forbids the rewrite.
    const original = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(EDIT_MAX_BYTES)) catch blk_big: {
        // ATTRIBUTE THE PATH. This used to open with a bare "{path} does not exist", which says nothing
        // about WHERE the path came from. Observed live (conv c857e4cec): the model had itself emitted a
        // malformed path, read this error, and told the user "You typed weather.pe** instead of
        // weather.py" — blaming them for its own argument, which is worse than the failed edit because it
        // sends the user hunting for a typo they never made. The path in an edit_file error is ALWAYS the
        // model's own; saying so costs a clause and removes the misreading.
        const st = std.Io.Dir.cwd().statFile(ctx.io, full, .{}) catch
            return std.fmt.allocPrint(gpa, "{s} does not exist — that path came from YOUR tool call, not from the user, so do not report it as their typo. edit_file only changes an EXISTING file: re-check the path against a recent read_file/list_dir result, or use write_file to create it.", .{npath}) catch dupe(gpa, "file not found — that path came from YOUR call; use write_file to create it");
        if (st.size > EDIT_MAX_BYTES)
            return std.fmt.allocPrint(gpa, "{s} EXISTS ({d} bytes) but is too large for edit_file to load. It was NOT modified — do NOT rewrite it with write_file (that would destroy it). Narrow the change: read the exact region with read_file start_line/end_line, or split the file first.", .{ npath, st.size }) catch dupe(gpa, "file too large to edit — do not rewrite it");
        break :blk_big std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(@intCast(st.size + 1))) catch
            return std.fmt.allocPrint(gpa, "{s} could not be read ({d} bytes). It was NOT modified — do NOT rewrite it with write_file.", .{ npath, st.size }) catch dupe(gpa, "could not read the file to edit — do not rewrite it");
    };
    defer gpa.free(original);
    // A marker-corrupted file is structurally edit-hostile: its repeated `<<<<<<<`/`=======`/`>>>>>>>` lines
    // make anchors ambiguous ("matches more than one place") and partial cleanups strand residue. The only
    // reliable repair is a clean full rewrite, so route there instead of letting ops fight the markers.
    if (bufedit.editMarkerCorruption(original))
        return std.fmt.allocPrint(gpa, "{s} currently contains unresolved SEARCH/REPLACE / merge-conflict marker lines from an earlier bad edit — anchors are unreliable in it and partial cleanups leave broken residue. Do NOT edit it: REWRITE it clean in full with write_file path:\"{s}\" mode:\"overwrite\", sending the complete final code with ZERO marker lines.", .{ npath, npath }) catch dupe(gpa, "file is marker-corrupted — rewrite it in full with write_file mode:\"overwrite\"");
    // A tag belongs in an op's ANCHOR, never in its replacement TEXT: text is what lands in the file, so a
    // tag-prefixed line there commits the addressing scheme into the source. Cheap to confuse — the model has
    // the tagged view right in front of it — and invisible afterwards, so reject before anything is spliced.
    for (p.value.ops, 0..) |o, i| {
        const otext = if (o.text.len > 0) o.text else o.replace;
        if (hashline.hasTaggedLine(otext))
            return std.fmt.allocPrint(gpa, "op{d} REJECTED (nothing was changed) — its replacement text carries anchor tags (`42:abc:def\u{2192}`). Tags are how you POINT at a line; they are not part of the line. Put the tag in `anchor` and the file's REAL code (tag prefixes stripped) in `text`.", .{i + 1}) catch dupe(gpa, "replacement text carries anchor tags — strip the `N:abc:def\u{2192}` prefixes; tags belong in anchor, not text");
    }
    if (hashline.hasTaggedLine(p.value.replace))
        return dupe(gpa, "edit REJECTED (nothing was changed) — your `replace` text carries anchor tags (`42:abc:def\u{2192}`). Tags are how you POINT at a line; they are not part of the line. Send the file's real code with every tag prefix stripped.");
    // The mirror mistake on the ANCHOR side: a block of the tagged view pasted as one op's anchor (or end). A
    // tag names one line and the parser keeps only the first, so left alone this does not fail — it lands as a
    // one-line edit and leaves the rest of the block in the file (see hashline.spannedTagAnchor). Reject it here,
    // before dialect dispatch, so it never reaches the anchor engine OR the text matcher.
    for (p.value.ops, 0..) |o, i| {
        const afield: []const u8 = if (o.anchor.len > 0) "anchor" else "search"; // the chat dialect's alias
        if (spannedAnchorReject(gpa, i + 1, afield, if (o.anchor.len > 0) o.anchor else o.search)) |msg| return msg;
        if (spannedAnchorReject(gpa, i + 1, "end", if (o.end.len > 0) o.end else o.end_anchor)) |msg| return msg;
    }
    // HASH-ANCHORED DIALECT: any op whose anchor is a copied `42:abc:def` tag routes the WHOLE batch
    // through the atomic anchor engine (hashline.zig) — anchors verify against the file AS IT IS NOW
    // (that check IS the concurrent-edit guarantee: a teammate's change in your neighborhood surfaces as
    // staleness, never a silent mis-splice), the batch applies all-or-nothing, and every failure returns
    // FRESH tags so the mind retries immediately without re-reading.
    // The file's lines, for resolving tag anchors against it AS IT IS NOW. Built once here and reused by the
    // dialect count and the op loop below (hashlineApply re-reads and re-validates in-lock regardless).
    var flines = hashline.splitLines(gpa, original) catch return dupe(gpa, "oom");
    defer flines.deinit(gpa);
    var n_tagged: usize = 0;
    for (p.value.ops) |o| {
        if (hashline.isTagAnchor(flines.items, if (o.anchor.len > 0) o.anchor else o.search)) n_tagged += 1;
    }
    // A tag copied WITHOUT its line number (`wcj:dwp→</body>` for `467:wcj:dwp→</body>`) that no longer names
    // a line must say THAT. Untouched it falls through to text matching, where nothing in the file looks like
    // a tag, so the edit failed as "anchor not found" AND the stale-region hint reported the region as removed
    // from the file entirely — the one thing that was certainly false, since the model had just read it there.
    if (n_tagged == 0) {
        for (p.value.ops, 0..) |o, i| {
            const araw = if (o.anchor.len > 0) o.anchor else o.search;
            if (!hashline.looksLikeUnlinedTag(araw)) continue;
            return std.fmt.allocPrint(gpa, "op{d}: anchor \"{s}\" is a line tag with its LINE NUMBER dropped, and its hashes match no line in {s} as it is now — that line changed since you read it. Nothing was modified. read_file the region and copy a FRESH tag COMPLETE with its number (`42:abc:def`).", .{ i + 1, araw[0..@min(araw.len, 60)], npath }) catch dupe(gpa, "stale line tag — read_file the region and copy a fresh `42:abc:def` tag, number included");
        }
    }
    if (n_tagged > 0) {
        var hops: std.ArrayListUnmanaged(hashline.Op) = .empty;
        defer hops.deinit(gpa);
        for (p.value.ops) |o| {
            const opname = if (o.op.len > 0) o.op else "replace";
            const araw = if (o.anchor.len > 0) o.anchor else o.search;
            const otext = if (o.text.len > 0) o.text else o.replace;
            const a = hashline.resolveAnchor(flines.items, araw) orelse
                return std.fmt.allocPrint(gpa, "mixed anchor dialects in one edit_file call — op anchor \"{s}\" is not a copied line tag while other ops use tags. Use the `N:abc:def` tags from your last read/edit result for EVERY op in this batch.", .{araw[0..@min(araw.len, 60)]}) catch dupe(gpa, "mixed anchor dialects — use line tags for every op");
            var end_a: ?hashline.Anchor = null;
            const eraw = if (o.end.len > 0) o.end else o.end_anchor;
            if (eraw.len > 0) {
                end_a = hashline.resolveAnchor(flines.items, eraw) orelse
                    return std.fmt.allocPrint(gpa, "the `end` value \"{s}\" is not a line tag — copy the range's LAST line tag (`N:abc:def`) from your last read.", .{eraw[0..@min(eraw.len, 60)]}) catch dupe(gpa, "bad end tag");
            }
            const kind: hashline.OpKind = if (std.mem.eql(u8, opname, "insert_after"))
                .insert_after
            else if (std.mem.eql(u8, opname, "insert_before"))
                .insert_before
            else if (std.mem.eql(u8, opname, "replace") or std.mem.eql(u8, opname, "delete"))
                .replace
            else
                return std.fmt.allocPrint(gpa, "op '{s}' does not take line tags — with tag anchors use replace | delete | insert_before | insert_after.", .{opname}) catch dupe(gpa, "unsupported op for tag anchors");
            hops.append(gpa, .{ .kind = kind, .anchor = a, .end_anchor = end_a, .text = if (std.mem.eql(u8, opname, "delete")) "" else otext, .raw_anchor = araw }) catch return dupe(gpa, "oom");
        }
        return hashlineApply(ctx, npath, full, original, hops.items);
    }
    var ops: std.ArrayListUnmanaged(bufedit.EditOp) = .empty;
    defer ops.deinit(gpa);
    for (p.value.ops) |o| {
        const opname = if (o.op.len > 0) o.op else "replace"; // the {search,replace} form omits op → replace
        const kind: bufedit.OpKind =
            if (std.mem.eql(u8, opname, "replace")) .replace else if (std.mem.eql(u8, opname, "insert_before")) .insert_before else if (std.mem.eql(u8, opname, "insert_after")) .insert_after else if (std.mem.eql(u8, opname, "insert_at")) .insert_at else if (std.mem.eql(u8, opname, "delete")) .delete else return std.fmt.allocPrint(gpa, "unknown op '{s}' — use replace | insert_before | insert_after | insert_at | delete", .{o.op}) catch dupe(gpa, "unknown op");
        const anchor = if (o.anchor.len > 0) o.anchor else o.search; // hive: anchor · chat: search
        const text = if (o.text.len > 0) o.text else o.replace; //       hive: text   · chat: replace
        ops.append(gpa, .{ .kind = kind, .anchor = anchor, .text = text, .at = o.at }) catch {};
    }
    if (ops.items.len == 0 and p.value.search.len > 0) // flat {path, search, replace} → one replace op
        ops.append(gpa, .{ .kind = .replace, .anchor = p.value.search, .text = p.value.replace, .at = 0 }) catch {};
    // When minds run concurrently, route through the micro-VCS: it reads HEAD in-lock and re-applies these ops
    // against it, so two minds editing one file merge instead of clobbering. `original` is this mind's base.
    // The validator runs the SAME extension-dispatched syntax gate (.py compile + duplicate-definition,
    // .js/.mjs/.cjs node --check, .json native parse) on the rebased result, in-lock, BEFORE the commit —
    // the VCS branch returns from here, so without it team>1 runs had NO edit gate at all.
    if (ctx.vcs_enabled) if (ctx.fmtx) |m| {
        const Gate = struct {
            tc: *ToolCtx,
            path: []const u8,
            /// the dropped-definition note for the candidate that passed, read off the committed result below
            dropped: ?[]u8 = null,
            fn check(vctx: *anyopaque, head: []const u8, candidate: []const u8) ?[]u8 {
                const g: *@This() = @ptrCast(@alignCast(vctx));
                // Language-blind, runs for EVERY file: an op's `text` must not smuggle the edit protocol
                // itself into the file (only rejects NEWLY-introduced markers — a head that already carries
                // them stays editable, mirroring the NL_CHK_ORIG baseline rule).
                if (bufedit.editMarkerCorruption(candidate) and !bufedit.editMarkerCorruption(head))
                    return dupe(g.tc.gpa, "edit rejected — the result would ADD SEARCH/REPLACE / merge-conflict marker lines to the file: your `text` itself carries edit-script fences. Put ONLY the final code lines in `text` — never <<<<<<< SEARCH / ======= / >>>>>>> REPLACE.");
                if (syntaxGateError(g.tc, g.path, candidate, head)) |perr| {
                    defer g.tc.gpa.free(perr);
                    return editRejectMsg(g.tc.gpa, g.path, perr) orelse (dupe(g.tc.gpa, "edit rejected: result does not compile"));
                }
                if (g.dropped) |d| g.tc.gpa.free(d); // a rebase re-checks: the note follows the candidate that lands
                g.dropped = droppedDefinitionsNote(g.tc.gpa, head, candidate);
                return null;
            }
        };
        var gate = Gate{ .tc = ctx, .path = npath };
        defer if (gate.dropped) |d| gpa.free(d);
        const outcome = vcs.commitEdit(ctx.io, gpa, m, ctx.run_dir, npath, full, ops.items, original, ctx.mind, .{ .ctx = @ptrCast(&gate), .check = &Gate.check });
        switch (outcome) {
            .committed => |c| {
                ctx.files_written.* += 1;
                lockFiles(ctx);
                recordRoundWrite(ctx, npath);
                unlockFiles(ctx);
                return std.fmt.allocPrint(gpa, "edited {s} — {d} op(s) applied{s}, file is now {d} bytes{s}{s}", .{ npath, ops.items.len, if (c.rebased) " and merged with a teammate's concurrent change (unverified — re-check the file still builds)" else "", c.len, if (gate.dropped != null) "\n" else "", gate.dropped orelse "" }) catch dupe(gpa, "edited");
            },
            .conflict => |msg| return msg,
            .failed => |msg| return msg,
        }
    };
    const res = bufedit.apply(gpa, original, ops.items);
    if (!res.ok) return res.reject; // owned; caller frees. original file untouched.
    defer gpa.free(res.bytes);
    defer if (res.loci.len > 0) gpa.free(res.loci);
    // Same language-blind protocol gate as the VCS path (original is marker-free here — the corrupted-file
    // case already returned above), so a single-mind run gets identical protection.
    if (bufedit.editMarkerCorruption(res.bytes))
        return dupe(gpa, "edit rejected — the result would ADD SEARCH/REPLACE / merge-conflict marker lines to the file: your `text` itself carries edit-script fences. Put ONLY the final code lines in `text` — never <<<<<<< SEARCH / ======= / >>>>>>> REPLACE.");
    // POST-EDIT SYNTAX GATE: a SEARCH/REPLACE (esp. a loose-match reindent) can leave a .py/.js/.json
    // unparseable while edit_file still reports "edited", so the mind only learns rounds later via the
    // global scan. Reject a parse-breaking edit and name the error NOW, in the same turn, keeping the last
    // good file. Fail-open (a missing python/node = no gate for that language).
    if (syntaxGateError(ctx, npath, res.bytes, original)) |perr| {
        defer gpa.free(perr);
        return editRejectMsg(gpa, npath, perr) orelse dupe(gpa, "edit rejected: result does not compile");
    }
    // the dropped-definition note rides the success line (droppedDefinitionsNote): a note, never a rejection
    const dropped = droppedDefinitionsNote(gpa, original, res.bytes);
    defer if (dropped) |d| gpa.free(d);
    if (!writeWorkFileAtomic(ctx, full, res.bytes)) return dupe(gpa, "could not write the edited file");
    ctx.files_written.* += 1;
    {
        lockFiles(ctx);
        defer unlockFiles(ctx);
        const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{ctx.run_dir}) catch "";
        defer if (mpath.len > 0) gpa.free(mpath);
        if (mpath.len > 0) {
            const existing = std.Io.Dir.cwd().readFileAlloc(ctx.io, mpath, gpa, .limited(64 << 10)) catch &[_]u8{};
            defer if (existing.len > 0) gpa.free(existing);
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(gpa);
            buf.appendSlice(gpa, existing) catch {};
            if (std.fmt.allocPrint(gpa, "{s}|{d}\n", .{ npath, res.bytes.len })) |ln| {
                defer gpa.free(ln);
                buf.appendSlice(gpa, ln) catch {};
            } else |_| {}
            std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = mpath, .data = buf.items }) catch {};
        }
        recordRoundWrite(ctx, npath);
    }
    if (res.reindented > 0)
        return std.fmt.allocPrint(gpa, "edited {s} — {d} op(s) applied, file is now {d} bytes. NOTE: {d} op(s) matched only after auto-reindenting your text to the file's indentation — your SEARCH lines had the wrong leading whitespace; copy them exactly next time.{s}{s}", .{ npath, ops.items.len, res.bytes.len, res.reindented, if (dropped != null) "\n" else "", dropped orelse "" }) catch dupe(gpa, "edited");
    return std.fmt.allocPrint(gpa, "edited {s} — {d} op(s) applied, file is now {d} bytes{s}{s}", .{ npath, ops.items.len, res.bytes.len, if (dropped != null) "\n" else "", dropped orelse "" }) catch dupe(gpa, "edited");
}

/// Return lines `start`..`end` (1-indexed, inclusive) of `text` with a `[lines A-B of N]` header, so the reader
/// can target a specific WINDOW of a big file instead of only ever seeing the byte-clipped head. Clamps to the
/// file's real bounds; the window itself is capped so a huge range can't blow the response.
fn readLineWindow(gpa: std.mem.Allocator, text: []const u8, start_in: usize, end_in: usize) []u8 {
    var total: usize = 0;
    {
        var cit = std.mem.splitScalar(u8, text, '\n');
        while (cit.next()) |_| total += 1;
    }
    if (total == 0) total = 1;
    const s: usize = if (start_in == 0) 1 else start_in;
    var e: usize = if (end_in == 0) total else end_in;
    if (e > total) e = total;
    if (s > total or s > e)
        return std.fmt.allocPrint(gpa, "[the file has {d} lines — requested start_line {d} is past the end; read a lower range]", .{ total, s }) catch dupe(gpa, "line range past end of file");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var hb: [72]u8 = undefined;
    out.appendSlice(gpa, std.fmt.bufPrint(&hb, "[lines {d}-{d} of {d}]\n", .{ s, e, total }) catch "") catch {};
    var line: usize = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| : (line += 1) {
        if (line < s) continue;
        if (line > e) break;
        out.appendSlice(gpa, ln) catch {};
        out.append(gpa, '\n') catch {};
        if (out.items.len > 32000) {
            out.appendSlice(gpa, "[...window clipped at 32000 bytes — narrow your line range]\n") catch {};
            break;
        }
    }
    return out.toOwnedSlice(gpa) catch dupe(gpa, "oom");
}

/// A directory listing for read_file-on-a-directory (names, sizes, subdirs marked with '/'). Returns null
/// when `full` isn't an openable directory (the caller falls through to its file handling). Capped so a
/// giant tree can't flood a reply; the cap is NAMED so the model knows the view is partial.
/// CLIENT ROAM: resolve an ABSOLUTE ("C:/data/x.csv", "/home/u/x") or HOME ("~/notes.txt") path a roaming
/// ToolCtx may READ. Returns the resolved path (gpa-owned) or null when the path isn't roamable (relative,
/// contains "..", or roam is off — swarm minds always). ".." stays rejected even when roaming: an absolute
/// path needs no traversal tricks, so any ".." is a smell, not a need.
fn roamPath(ctx: *ToolCtx, p: []const u8) ?[]u8 {
    if (!ctx.roam or p.len == 0) return null;
    if (std.mem.indexOf(u8, p, "..") != null) return null;
    const gpa = ctx.gpa;
    if (p[0] == '~' and (p.len == 1 or p[1] == '/' or p[1] == '\\')) {
        const home = ctx.environ.get("USERPROFILE") orelse ctx.environ.get("HOME") orelse return null;
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ home, p[1..] }) catch null;
    }
    const abs = (p[0] == '/' or p[0] == '\\') or (p.len > 2 and p[1] == ':' and (p[2] == '/' or p[2] == '\\'));
    if (!abs) return null;
    return gpa.dupe(u8, p) catch null;
}

fn dirListing(ctx: *ToolCtx, full: []const u8, rpath: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    var d = std.Io.Dir.cwd().openDir(ctx.io, full, .{ .iterate = true }) catch return null;
    defer d.close(ctx.io);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.print(gpa, "{s} is a DIRECTORY — contents:\n", .{rpath}) catch return null;
    var it = d.iterate();
    var n: usize = 0;
    while (true) {
        const e = (it.next(ctx.io) catch break) orelse break;
        if (n >= 200) {
            buf.appendSlice(gpa, "  ... (listing capped at 200 entries)\n") catch {};
            break;
        }
        if (e.kind == .directory) {
            buf.print(gpa, "  {s}/\n", .{e.name}) catch break;
        } else {
            var pb: [640]u8 = undefined;
            if (std.fmt.bufPrint(&pb, "{s}/{s}", .{ full, e.name })) |fp| {
                const sz: u64 = if (std.Io.Dir.cwd().statFile(ctx.io, fp, .{})) |st| st.size else |_| 0;
                buf.print(gpa, "  {s} ({d} bytes)\n", .{ e.name, sz }) catch break;
            } else |_| {
                buf.print(gpa, "  {s}\n", .{e.name}) catch break;
            }
        }
        n += 1;
    }
    if (n == 0) buf.appendSlice(gpa, "  (empty)\n") catch {};
    return gpa.dupe(u8, buf.items) catch null;
}

fn readFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    // start_line/end_line (1-indexed, inclusive) let the reader window a big file — without them the read is
    // clipped to the HEAD, so a model asking for lines near the end of a >8KB file gets the top forever and
    // spirals. `offset`/`limit` are accepted as line-based aliases (offset = first line, limit = count).
    const A = struct { path: []const u8 = "", start_line: usize = 0, end_line: usize = 0, offset: usize = 0, limit: usize = 0 };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    // "look around" floor: reading the workdir root (or any directory) returns a LISTING instead of "not
    // found" — without it minds have no way to see what exists and write _ls.py scripts they can't run.
    if (p.value.path.len == 0 or std.mem.eql(u8, p.value.path, ".") or std.mem.eql(u8, p.value.path, "./")) {
        return dirListing(ctx, ctx.workdir, ".") orelse dupe(gpa, "the workdir is empty");
    }
    // CLIENT ROAM: on the user's own machine an ABSOLUTE (or ~) path outside the workdir is a READ the user's
    // assistant may make ("analyze C:/data/report.csv") — the content returns as this tool's result, no copy,
    // no sync. Swarm minds (roam=false) keep the hard workdir jail and the original error.
    const roamed: ?[]u8 = if (!safeRel(p.value.path)) roamPath(ctx, p.value.path) else null;
    defer if (roamed) |r| gpa.free(r);
    if (!safeRel(p.value.path) and roamed == null)
        return dupe(gpa, if (ctx.roam)
            "bad path — a workdir-RELATIVE path (index.html), an ABSOLUTE path on this machine (C:/data/x.csv), or ~/file"
        else
            "bad path — use a path RELATIVE to your workdir (no leading / or \\, no '..'), e.g. index.html or css/style.css");
    const rpath = if (roamed != null) p.value.path else blk_rp: {
        const wb = std.fs.path.basename(ctx.workdir);
        if (wb.len > 0 and p.value.path.len > wb.len + 1 and std.mem.startsWith(u8, p.value.path, wb) and p.value.path[wb.len] == '/')
            break :blk_rp p.value.path[wb.len + 1 ..];
        break :blk_rp p.value.path;
    };
    const full = if (roamed) |r|
        (gpa.dupe(u8, r) catch return dupe(gpa, "oom"))
    else
        (std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, rpath }) catch return dupe(gpa, "oom"));
    defer gpa.free(full);
    // A requested line window (start_line/end_line, or offset+limit) returns exactly those lines — this is how
    // you read the back half of a big file. Resolved BEFORE the read because it decides how big a file this
    // call will accept: a whole-file read of something huge is refused, a WINDOW of it is the documented way
    // through, and those two used to share one ceiling — so a file over the whole-read limit answered "read it
    // in pieces with a line range" to a call that ALREADY passed one. That dead end is what made a big file
    // unreadable, therefore un-anchorable, therefore only ever rewritable.
    const start_line = if (p.value.start_line > 0) p.value.start_line else p.value.offset;
    const end_line = if (p.value.end_line > 0) p.value.end_line else if (p.value.limit > 0 and start_line > 0) start_line + p.value.limit - 1 else 0;
    const windowed = start_line > 0 or end_line > 0;
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(256 << 10)) catch blk_big: {
        // Not a plain small file. A DIRECTORY gets its listing; a file BIGGER than the slurp cap gets read
        // with a raised ceiling — a bare "not found" would be a LIE for both (a large source would read as
        // nonexistent, hiding the file that mattered most).
        if (dirListing(ctx, full, rpath)) |listing| return listing;
        const st = std.Io.Dir.cwd().statFile(ctx.io, full, .{}) catch return dupe(gpa, "not found");
        const ceiling: u64 = if (windowed) EDIT_MAX_BYTES else (4 << 20);
        if (st.size > ceiling) return if (windowed)
            std.fmt.allocPrint(gpa, "{s} EXISTS ({d} bytes) but is past the {d}-byte limit for reading at all — it cannot be windowed or edited in place. Split it, or work on it with run_python.", .{ rpath, st.size, ceiling }) catch dupe(gpa, "file too large to read")
        else
            std.fmt.allocPrint(gpa, "{s} EXISTS ({d} bytes) but is too large to read whole — read it in pieces with a line range: {{\"path\":\"{s}\",\"start_line\":1,\"end_line\":400}}", .{ rpath, st.size, p.value.path }) catch dupe(gpa, "file too large");
        break :blk_big std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(@intCast(st.size + 1))) catch return dupe(gpa, "not found");
    };
    defer gpa.free(data);
    const clean = sanitizeModelText(gpa, data);
    defer gpa.free(clean);
    // ANCHORED READ (build mode): every line is prefixed with its edit-anchor tag (`42:abc:def→`) — the
    // copyable handles edit_file verifies. Roamed (outside-workdir) and binary-ish reads stay plain.
    const tagged = ctx.anchored_reads and roamed == null and std.mem.indexOfScalar(u8, clean, 0) == null;
    // WINDOWED: tag only the requested lines. Tags are ABSOLUTE (line number + the file's own 8-line chunk
    // fingerprints), so a window's anchors are identical to a whole-file read's — but rendering the whole file
    // first, as this did, meant a 400-line window of a 20 MB file hashed every one of its ~500k lines and built
    // a second whole-file buffer to throw away.
    if (windowed) {
        if (!tagged) return readLineWindow(gpa, clean, start_line, end_line);
        return hashline.renderReadWindow(gpa, clean, start_line, end_line) orelse
            std.fmt.allocPrint(gpa, "[the requested line range is past the end of {s} — read a lower range]", .{rpath}) catch dupe(gpa, "line range past end of file");
    }
    const view = if (tagged)
        hashline.renderRead(gpa, clean)
    else
        (gpa.dupe(u8, clean) catch return dupe(gpa, "oom"));
    defer gpa.free(view);
    const owned = ctx.my_files.len > 0 and fileOwnedBy(ctx.my_files, p.value.path);
    const cap: usize = if (owned) 32000 else 8000;
    if (view.len <= cap) return dupe(gpa, view);
    // A silently-cut read looks EXACTLY like a truncated file — the reader then "fixes" a healthy file or
    // spirals on tail-verification. Name the cut, the real size, AND how to see the rest (a line range), so the
    // reader windows the tail instead of re-reading the head.
    return std.fmt.allocPrint(gpa, "{s}\n[...view clipped: showing the first {d} of {d} bytes. The file on disk is WHOLE — to read the rest, call read_file again with a line range, e.g. {{\"path\":\"{s}\",\"start_line\":200,\"end_line\":320}}. Do NOT rewrite or re-verify the file just because this view ends here.]", .{ view[0..cap], cap, view.len, p.value.path }) catch dupe(gpa, view[0..cap]);
}

/// absorb — distill a LOCAL text file into recallable neuron-db facts (offline; the same deterministic
/// distillation `veil rag ingest` uses). A workdir-relative path always works; an ABSOLUTE/~ path only when
/// this ctx roams (the client executor on the user's own machine, exactly like read_file). Facts land in the
/// shared KNOWLEDGE hive by default, so recall_hive surfaces them for the whole team/conversation afterward —
/// the answer to "tell the AI to absorb the book" when there's no rag repo and no internet.
fn absorbFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { path: []const u8 = "", scope: []const u8 = "", name: []const u8 = "", cap: u32 = 0 };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (p.value.path.len == 0) return dupe(gpa, "absorb needs a file path (relative to your workdir, or an absolute path on the user's machine in chat)");
    const roamed: ?[]u8 = if (!safeRel(p.value.path)) roamPath(ctx, p.value.path) else null;
    defer if (roamed) |r| gpa.free(r);
    if (!safeRel(p.value.path) and roamed == null)
        return dupe(gpa, "bad path — a workdir-RELATIVE path, or (in chat, on the user's machine) an ABSOLUTE path like C:/books/x.txt");
    const full = if (roamed) |r|
        (gpa.dupe(u8, r) catch return dupe(gpa, "oom"))
    else
        (std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, p.value.path }) catch return dupe(gpa, "oom"));
    defer gpa.free(full);
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(64 << 20)) catch
        return std.fmt.allocPrint(gpa, "could not read {s} (missing, unreadable, or larger than 64MB)", .{p.value.path}) catch dupe(gpa, "not found");
    defer gpa.free(text);
    if (std.mem.indexOfScalar(u8, text[0..@min(text.len, 4096)], 0) != null)
        return std.fmt.allocPrint(gpa, "{s} looks binary (PDF/EPUB/DOCX?). Convert it to text first (e.g. pdftotext book.pdf book.txt), then absorb the .txt.", .{p.value.path}) catch dupe(gpa, "file is binary — convert to text first");
    var lb: [96]u8 = undefined;
    const label = if (p.value.name.len > 0) p.value.name else ragingest.labelFromPath(p.value.path, &lb);
    // Default target = the document's OWN `knowledge__doc-<slug>` sub-scope, not the flat hive: the scope
    // is the document's identity (insertion order = document order, so read_doc can page it), recall_hive's
    // across-recall reaches it from the base scope, and one big absorb can never evict the shared hive.
    var scb: [96]u8 = undefined;
    const scope = if (p.value.scope.len > 0) p.value.scope else ragingest.docScope(KNOWLEDGE_SCOPE, label, &scb);
    const cap: u32 = if (p.value.cap > 0) p.value.cap else 4000;
    const st = ragingest.ingestText(ctx.mem, ctx.io, gpa, ctx.run_dir, text, label, scope, cap);
    if (st.stored == 0 and st.facts == 0)
        return std.fmt.allocPrint(gpa, "absorbed nothing from {s} — it has little clean prose (a code file, a table dump, or already-structured data).", .{label}) catch dupe(gpa, "no facts distilled");
    if (st.stored == 0 and st.facts > 0)
        return std.fmt.allocPrint(gpa, "distilled {d} facts from {s} but the memory store rejected them (0 stored) — the neuron-db write failed. Nothing was learned; retry or check the store.", .{ st.facts, label }) catch dupe(gpa, "distilled facts but stored 0 — neuron write failed");
    ctx.observed.* += st.stored;
    // Eviction is the difference between "written" and "retained": a capped scope front-drains its oldest
    // facts DURING a big load, so "N stored" alone once acked a book whose first 85% was already gone
    // (and whose recall then quietly answered from the tail). Never claim full recallability over a drain.
    if (st.evicted > 0)
        return std.fmt.allocPrint(gpa, "absorbed {s}: {d} facts distilled, {d} written into scope '{s}' — BUT the scope hit its fact cap and evicted {d} oldest fact(s) during the load. Only the LAST part of the document (and whatever else survived) is recallable; earlier content is GONE from memory. Do not summarize from recall alone — re-read the source file for anything before the retained tail.", .{ label, st.facts, st.stored, scope, st.evicted }) catch dupe(gpa, "absorbed with evictions — earlier content was dropped");
    return std.fmt.allocPrint(gpa, "absorbed {s}: {d} facts distilled, {d} stored into its own document scope '{s}'. Targeted questions: recall_hive finds it automatically. Whole-document work (summarize/outline/review): page it IN ORDER with read_doc (scope '{s}') — never build a summary from recall fragments.", .{ label, st.facts, st.stored, scope, scope }) catch dupe(gpa, "absorbed");
}

/// LOCAL TWIN of the chat engine's hiveRelevant thresholds, applied per fact line (see recall_hive):
/// does this line share real vocabulary with the query? Keep when >=2 distinct query terms (each >=4
/// chars) appear, or one >=8-char term (a rare specific word). Substring, case-insensitive — permissive
/// enough that a related fact never drops, strict enough that ONE incidental shared stem no longer
/// carries residue prose into an unrelated task (observed live: book fragments answering a zoo query).
fn lexRelevant(query: []const u8, line: []const u8) bool {
    var distinct: usize = 0;
    var longest: usize = 0;
    var seen: [24][24]u8 = undefined;
    var seen_len: [24]usize = .{0} ** 24;
    var seen_n: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:!?\"'()[]{}");
    while (it.next()) |t| {
        if (t.len < 4 or t.len > 24) continue;
        var dup = false;
        var si: usize = 0;
        while (si < seen_n) : (si += 1) {
            if (std.ascii.eqlIgnoreCase(seen[si][0..seen_len[si]], t)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen_n < seen.len) {
            @memcpy(seen[seen_n][0..t.len], t);
            seen_len[seen_n] = t.len;
            seen_n += 1;
        }
        if (std.ascii.indexOfIgnoreCase(line, t) != null) {
            distinct += 1;
            longest = @max(longest, t.len);
        }
    }
    if (seen_n == 0) return true; // a query with no real terms can't discriminate — pass everything through
    return distinct >= 2 or (distinct >= 1 and longest >= 8);
}

test "lexRelevant: shared vocabulary keeps a line, one incidental stem does not" {
    // the live failure shape: book prose vs a zoo query sharing nothing real
    try std.testing.expect(!lexRelevant("toronto zoo animals list", "[The Green Overcoat - Hilaire Belloc] Most of the men were standing up in the audience."));
    // one long specific term is enough
    try std.testing.expect(lexRelevant("stratoflights regulations", "Canadian balloon launches follow Transport Canada regulations for unmanned free balloons."));
    // two shorter shared terms are enough
    try std.testing.expect(lexRelevant("weather balloon parts", "the balloon envelope and parachute are the two parts that fail first"));
    // a vocabulary-free query cannot discriminate — everything passes (the rerank still refines)
    try std.testing.expect(lexRelevant("y?", "anything at all"));
}

// ------------------------------------------------------------------------------------------ poll (watch to completion)

// Raw-thread sleep (engine.sleepMsRaw's twin): tool execution runs on raw worker/turn threads where
// io.sleep can throw and a swallowed error busy-spins a core. Win32 Sleep on Windows.
const pollsleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
} else struct {};
/// stop_process — kill a process this workspace started, WITH ITS CHILDREN.
///
/// Ending a turn does not reap what a script spawned: `run_python` kills its own child on its deadline, but
/// a server or fuzzer that child launched outlives all of it, holding its port and its CPU until someone
/// finds the pid by hand. That is the gap this closes — a turn could start a long-running thing and had no
/// way to end one.
///
/// NOT a new power, which is why it is not on the adjudicated host_command surface: any caller that can
/// reach this can already call run_python, and run_python can already `os.kill`. What was missing was a
/// FIRST-CLASS way to do it, so "stop the thing you started" is one obvious call rather than a script the
/// model has to think to write. It carries run_python's gate for exactly that reason — same power, same
/// door — and a sandboxed caller, which has neither, gets neither.
///
/// The tree matters more than the process. Killing a launcher and leaving its worker behind is the failure
/// this exists to prevent, so Windows gets /T and POSIX gets the process group before the bare pid.
fn stopProcessTool(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    if (ctx.caps == .sandboxed) return dupe(gpa, "stop_process is not available in this workspace");
    const A = struct { pid: i64 = 0 };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const pid = p.value.pid;
    if (pid <= 0) return dupe(gpa, "stop_process: 'pid' must be a positive process id");
    // Refusing our own pid is not paranoia: the engine hands the model pids from ps-style output, and the
    // veil process is in that list. Killing it takes the conversation down with the fuzzer.
    const self_pid: i64 = if (builtin.os.tag == .windows)
        @intCast(std.os.windows.GetCurrentProcessId())
    else
        @intCast(std.c.getpid()); // libc, not os.linux — ports to macOS (mirrors run.zig)
    if (pid == self_pid) return dupe(gpa, "stop_process: that is veil's own process");
    var buf: [24]u8 = undefined;
    const pid_s = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return dupe(gpa, "stop_process: bad pid");
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "taskkill", "/PID", pid_s, "/T", "/F" }
    else
        &.{ "kill", "-TERM", "--", pid_s };
    // bounded.run, and room for a big tree: taskkill prints a SUCCESS line per process it ends, and under
    // std.process.run's 2 KB limit a tree of a few dozen tripped it, which on Windows can hang the call outright
    // (see bounded.zig). Only the first 240 bytes are ever shown.
    var r = bounded.run(gpa, ctx.io, .{ .argv = argv, .bound_ms = 30_000, .stdout_limit = 64 << 10, .stderr_limit = 8 << 10, .stderr_tail = true });
    defer r.deinit(gpa);
    if (!r.finished())
        return std.fmt.allocPrint(gpa, "stop_process: could not run the killer for pid {d}", .{pid}) catch dupe(gpa, "stop_process: failed");
    if (r.ok()) return std.fmt.allocPrint(gpa, "stopped pid {d} and its children", .{pid}) catch dupe(gpa, "stopped");
    const why = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \r\n\t");
    return std.fmt.allocPrint(gpa, "stop_process: pid {d} was not stopped — {s}", .{ pid, if (why.len > 0) why[0..@min(why.len, 240)] else "no such process, or it is not yours to kill" }) catch dupe(gpa, "stop_process: failed");
}

fn pollSleepMs(io: std.Io, ms_in: u64) void {
    const ms = if (builtin.is_test) (probe_seam.sleep_ms orelse ms_in) else ms_in;
    if (ms == 0) return;
    if (builtin.os.tag == .windows) {
        pollsleep.Sleep(@intCast(@min(ms, 60_000)));
    } else {
        io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
    }
}

/// Identical failing probes, counted from the FIRST sample with no success before them, that end a command poll
/// early (verdict `failing`). A live SWE-bench run spent 251 s, 64% of its coding time, on two polls whose probe
/// was broken by its own quoting and failed identically 16 times from t+0. Three is enough to know.
const PROBE_FAIL_FAST_N: u32 = 3;
/// How much of a probe's stderr each observation carries: its TAIL, where shells and runtimes put the verdict
/// ("unexpected EOF while looking for matching", "No such container", a traceback's last line).
const PROBE_STDERR_TAIL: usize = 300;
/// stdout a probe may print before the poll stops reading it (the limit std.process.run was given before).
const PROBE_STDOUT_MAX: usize = 32 << 10;
/// The environment variable a quoted Windows probe rides in (see runProbe), and the argv that expands it. No /D:
/// the direct `cmd /C` route never had it and a prompt runs the user's AutoRun too, so a probe's PATH (a conda
/// hook's, say) must not change just because the probe gained a pair of quotes.
const PROBE_ENV = "NL_POLL_PROBE";
const probe_argv_verbatim = [_][]const u8{ "cmd", "/S", "/C", "%" ++ PROBE_ENV ++ "%" };

/// TEST SEAMS (TESTING.md: count it, never time it). `spawns` counts probes at their one choke point (runProbe);
/// `last_bound_ms` is the bound pollTool handed the last one; `sleep_ms` replaces the between-sample sleep so the
/// fail-fast and log tests run many samples in well under a second instead of interval_s each.
const probe_seam = if (builtin.is_test) struct {
    var spawns: u32 = 0;
    var last_bound_ms: u64 = 0;
    var sleep_ms: ?u64 = null;
} else struct {};

/// One command probe: how it ended and what it printed (bounded.Result). `.overflow` = printed more than
/// PROBE_STDOUT_MAX; `.unstarted` = the shell itself would not start.
const CmdProbe = bounded.Result;

/// Run ONE `poll kind=command` probe the way a person would at a prompt, bounded, with both streams kept.
///
/// WINDOWS QUOTING. `cmd /C <target>` as one argv element cannot carry embedded double quotes. Zig's argv encoder
/// writes them as `\"` (the CommandLineToArgvW convention); cmd.exe reads no backslash escapes, strips only the
/// outer pair, and hands the next program `\"...\"`. Measured 2026-10-14: `echo "two words"` printed
/// `\"two words\"`, and `cmd /D /C "echo inner ok"` failed "'\"echo inner ok\"' is not recognized". That is the
/// shape that tore `docker exec <c> bash -lc "tail -n 5 log"` into `bash -lc '"tail'` in a live SWE-bench run,
/// so every probe read "(non-zero exit)" for 251 s while the log already held its answer. Zig 0.16's spawn has no
/// verbatim command-line option, so a QUOTED target rides in an environment variable that cmd expands:
/// `cmd /S /C %NL_POLL_PROBE%`. Percent expansion runs BEFORE cmd tokenizes quotes, `&`, `|` and redirects, so
/// the text is parsed exactly as typed, and the argument Zig encodes has no quote or space for it to escape.
/// Chosen over a one-shot .cmd file (run.zig winRowViaScript's detour): nothing to write, name per call, delete
/// on every exit path, or have Defender scan before each 3 s sample, and no batch semantics (`%1`, `%%`) to escape
/// around. cmd expands that variable in ONE pass, so a `%VAR%` inside the target would stay literal
/// (`type "%TEMP%\x.log"`); expandPercentVars does the prompt's own expansion first, against the environment the
/// probe gets. A quote-free target keeps the direct `cmd /C` argv, where cmd expands as at a prompt; that path was
/// never torn. POSIX `sh -c` was always verbatim. The verbatim child's environment is the process's own, which is
/// what the direct path's child inherits through io, plus the one variable.
///
/// BOUND. bounded.run: at `bound_ms` the probe is killed with its whole tree (taskkill /T on Windows, because cmd.exe
/// never execs; the process group it leads on POSIX). Killing the shell alone leaves whatever it started running:
/// measured 2026-10-14, the ping (Windows) and sleep (WSL dash) under a nested shell outlived a direct-child kill,
/// and a docker exec would too.
fn runProbe(ctx: *ToolCtx, target: []const u8, bound_ms: u64) CmdProbe {
    const gpa = ctx.gpa;
    const io = ctx.io;
    if (builtin.is_test) probe_seam.spawns += 1;
    const win = builtin.os.tag == .windows;
    var env: if (win) ?std.process.Environ.Map else void = if (win) null else {};
    defer if (win) {
        if (env) |*m| m.deinit();
    };
    if (win) {
        if (std.mem.indexOfScalar(u8, target, '"') != null) {
            var m = (std.process.Environ{ .block = .global }).createMap(gpa) catch |e| return .{ .err = e };
            const text = expandPercentVars(gpa, target, &m) catch |e| {
                m.deinit();
                return .{ .err = e };
            };
            defer gpa.free(text);
            m.put(PROBE_ENV, text) catch |e| {
                m.deinit();
                return .{ .err = e };
            };
            env = m;
        }
    }
    const direct = [3][]const u8{ if (win) "cmd" else "sh", if (win) "/C" else "-c", target };
    const em: ?*const std.process.Environ.Map = if (win) (if (env) |*m| m else null) else null;
    const argv: []const []const u8 = if (em != null) &probe_argv_verbatim else &direct;
    // stderr is shown only as its tail, so only a tail is kept: progress bars on stderr must not grow it unbounded
    return bounded.run(gpa, io, .{ .argv = argv, .environ_map = em, .bound_ms = bound_ms, .stdout_limit = PROBE_STDOUT_MAX, .stderr_limit = 4096, .stderr_tail = true });
}

/// A cmd PROMPT's percent expansion (not a batch file's: no `%%` escape, no `%1`), done up front for a quoted
/// Windows probe because cmd expands its NL_POLL_PROBE carrier in one pass and never rescans the result. `%NAME%`
/// with NAME defined becomes its value, unrescanned (names case-insensitive, as the Map is on Windows); any other
/// `%...%` keeps its text and the scan resumes AT the closing `%`, so `%UNDEF%PATH%` reads `%UNDEF` plus PATH's
/// value and `%%` stays `%%`; a lone `%` stays. Each rule was measured against `cmd /S /C "<text>"` on 2026-10-14.
/// Not modelled, so left literal: cmd's dynamic names (%CD%, %DATE%, %RANDOM%, %ERRORLEVEL%) and the `%NAME:~1,3%`
/// / `%NAME:a=b%` edit forms.
fn expandPercentVars(gpa: std.mem.Allocator, text: []const u8, env: *const std.process.Environ.Map) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%') if (std.mem.indexOfScalarPos(u8, text, i + 1, '%')) |close| {
            const name = text[i + 1 .. close];
            // validateKeyForFetch: Map.get asserts WTF-8 on Windows, and a model's target is arbitrary bytes
            if (name.len > 0 and std.process.Environ.Map.validateKeyForFetch(name)) if (env.get(name)) |v| {
                try out.appendSlice(gpa, v);
                i = close + 1;
                continue;
            };
            try out.appendSlice(gpa, text[i..close]);
            i = close;
            continue;
        };
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// One probe as the model reads it: how it ended, stdout's head, and stderr's TAIL when there is any. Before this
/// a failing probe read "(non-zero exit)" and nothing else, so a probe broken by its own quoting looked exactly
/// like one still waiting, sample after sample.
fn probeLine(buf: []u8, p: *const CmdProbe, bound_ms: u64) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    switch (p.end) {
        .exited => w.print("exit {d}", .{p.code}) catch {},
        .signal => w.writeAll("ended by a signal") catch {},
        .killed => w.print("killed after {d}.{d}s, still running when this call's timeout_s ran out (a probe must return on its own: no tail -f, no prompts)", .{ bound_ms / 1000, bound_ms % 1000 / 100 }) catch {},
        .overflow => w.print("stopped: printed over {d} KB, narrow the probe (e.g. tail -n 20)", .{PROBE_STDOUT_MAX >> 10}) catch {},
        .unread => w.print("its output could not be read ({s})", .{p.why()}) catch {},
        .unstarted => w.print("could not start the probe shell ({s})", .{p.why()}) catch {},
    }
    if (p.end != .overflow and p.end != .unstarted) {
        const out = std.mem.trim(u8, p.stdout, " \r\n\t");
        if (out.len > 0) {
            w.print(": {s}", .{out[0..@min(out.len, 220)]}) catch {};
        } else {
            w.writeAll(", no stdout") catch {};
        }
    }
    const er = std.mem.trim(u8, p.stderr, " \r\n\t");
    if (er.len > 0) w.print(" | stderr: {s}", .{er[er.len -| PROBE_STDERR_TAIL..]}) catch {};
    return w.buffered();
}

/// What a command poll remembers between samples: the previous observation (an identical repeat logs as one short
/// line, so the bounded log keeps room for the sample that finally changes) and the fail-fast streak.
const ProbeWatch = struct {
    last: ?u64 = null,
    last_t: u64 = 0,
    sig: u64 = 0,
    streak: u32 = 0,
    live: bool = true, // false once a probe succeeded or failed differently: no fail-fast for the rest of the call
    signal: bool = false, // how the streak failed, kept for the result line
    code: u32 = 0,
    quote: [PROBE_STDERR_TAIL + 80]u8 = undefined,
    quote_len: usize = 0,

    /// The t+ of the identical observation this one repeats, or null (and it becomes the one to compare against).
    fn repeatOf(w: *ProbeWatch, line: []const u8, secs: u64) ?u64 {
        const h = std.hash.Wyhash.hash(0, line);
        if (w.last) |l| if (l == h) return w.last_t;
        w.last = h;
        w.last_t = secs;
        return null;
    }

    /// Feed a probe that did NOT satisfy the poll; true = end the poll now with verdict `failing`.
    fn failFast(w: *ProbeWatch, p: *const CmdProbe) bool {
        if (!w.live) return false;
        const er = std.mem.trim(u8, p.stderr, " \r\n\t");
        // A failure counts only when it SAYS something. A silent non-zero exit (`test -f done`, `grep -q EXIT=`) is
        // the documented "until exit 0" wait itself, not a broken probe, and cutting it short would break that mode.
        // The rule cannot tell a broken probe from a not-ready state that speaks ("connection refused", "No such
        // file" before the file exists): both fail identically from t+0. So the `failing` result names the escape,
        // the same silence: such a wait is re-polled with its failure muted and is never cut short again. A probe
        // killed at its bound never counts: that bound is the call's remaining timeout_s, so it ends the call anyway.
        const counts = p.end != .killed and !p.ok() and er.len > 0;
        var h = std.hash.Wyhash.init(0);
        h.update(@tagName(p.end));
        h.update(std.mem.asBytes(&p.code));
        h.update(er[0..@min(er.len, 200)]);
        h.update(std.mem.trim(u8, p.stdout, " \r\n\t")); // output that changes is progress, not the same failure
        const sig = h.final();
        if (!counts or (w.streak > 0 and sig != w.sig)) {
            w.live = false;
            return false;
        }
        w.sig = sig;
        w.streak += 1;
        if (w.streak < PROBE_FAIL_FAST_N) return false;
        // copied now: the probe's buffers are freed before the result is written
        w.signal = p.end == .signal;
        w.code = p.code;
        const q = er[er.len -| PROBE_STDERR_TAIL..];
        w.quote_len = @min(q.len, w.quote.len);
        @memcpy(w.quote[0..w.quote_len], q[0..w.quote_len]);
        return true;
    }

    fn guidance(w: *const ProbeWatch, buf: []u8) []const u8 {
        var hb: [48]u8 = undefined;
        const how = if (w.signal) "ended by a signal each time" else (std.fmt.bufPrint(&hb, "exit {d} each time", .{w.code}) catch "same exit each time");
        return std.fmt.bufPrint(buf, " — the probe failed the same way on its first {d} runs ({s}, same error) and never once succeeded, so this poll ended early instead of spending timeout_s on it. Its error: \"{s}\". If that error means the probe itself is broken (quoting, a path, the program or container name), fix the command. If it IS the not-ready state you are waiting for (a file not written yet, a server not listening yet), poll again with that failure SILENCED: stderr sent away (2>/dev/null; 2>NUL in a Windows cmd) or a quiet form (test -f, grep -q, curl -sf). A silent failure never ends a poll early.", .{ PROBE_FAIL_FAST_N, how, w.quote[0..w.quote_len] }) catch " — the probe keeps failing the same way: fix it, or silence its stderr if that error is the not-ready state you are waiting for";
    }
};

/// poll — WATCH SOMETHING TO COMPLETION instead of guessing or busy-asking: a bounded observe loop over a
/// log file (growth/pattern), an http(s) url, a local tcp port, a process, a probe command, or this
/// conversation's swarm. One call is bounded (timeout clamp 1..180s) and returns an observation log plus a
/// verdict — on `timeout` the caller simply polls again, so a long wait is a chain of bounded calls the
/// engine can always interrupt, never one unbounded hang. A command probe runs as typed at a prompt, is killed
/// if it would outlive the call (runProbe), reports its exit code and stderr tail, and a probe failing the same
/// SPOKEN way from the first sample ends the call early as `failing` with its error quoted (ProbeWatch).
fn pollTool(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct {
        kind: []const u8 = "",
        target: []const u8 = "",
        until: []const u8 = "",
        quiet_s: u32 = 0,
        interval_s: u32 = 3,
        timeout_s: u32 = 60,
    };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const kind = p.value.kind;
    const target = std.mem.trim(u8, p.value.target, " \r\n\t");
    const until = std.mem.trim(u8, p.value.until, " \r\n\t");
    const interval: u64 = std.math.clamp(p.value.interval_s, 1, 30);
    const timeout: u64 = std.math.clamp(p.value.timeout_s, 1, 180);
    const K = enum { file, url, port, process, command, swarm };
    const k: K = if (std.mem.eql(u8, kind, "file")) .file else if (std.mem.eql(u8, kind, "url")) .url else if (std.mem.eql(u8, kind, "port")) .port else if (std.mem.eql(u8, kind, "process")) .process else if (std.mem.eql(u8, kind, "command")) .command else if (std.mem.eql(u8, kind, "swarm")) .swarm else return dupe(gpa, "poll: kind must be file | url | port | process | command | swarm");
    if (k != .swarm and target.len == 0) return dupe(gpa, "poll: 'target' is required (path / url / port / process name / command)");
    // the COMMAND kind runs an arbitrary probe repeatedly — same power class as run_python, same gate
    if (k == .command and ctx.caps == .sandboxed) return dupe(gpa, "poll kind 'command' is not available in this workspace — use kind file/url/port/process, which observe without executing");
    if (k == .url and !ctx.internet and std.mem.indexOf(u8, target, "localhost") == null and std.mem.indexOf(u8, target, "127.0.0.1") == null)
        return dupe(gpa, "web disabled: this is an OFFLINE run — poll may only watch localhost urls, files, ports, or processes");

    const t0: i64 = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(gpa);
    var verdict: []const u8 = "timeout";
    var last_size: u64 = 0;
    var quiet_since: u64 = 0; // elapsed seconds when the file last grew
    var have_size = false;
    var pw: ProbeWatch = .{}; // kind command only
    const obs = struct {
        fn line(g: std.mem.Allocator, l: *std.ArrayListUnmanaged(u8), secs: u64, text: []const u8) void {
            lineCap(g, l, secs, text, 220, false);
        }
        /// `decides` = the sample that settles the verdict: logged past the bound, one line at most, because it
        /// is the one the model needs. A command observation runs ~550 bytes with its stderr tail, so the bound
        /// fills after ~11 distinct samples, and the matched line carrying the EXIT= being waited for was dropped.
        fn lineCap(g: std.mem.Allocator, l: *std.ArrayListUnmanaged(u8), secs: u64, text: []const u8, cap: usize, decides: bool) void {
            if (l.items.len > 6000 and !decides) return; // bounded log — the verdict matters more than every tick
            l.print(g, "t+{d}s: {s}\n", .{ secs, if (text.len > cap) text[0..cap] else text }) catch {};
        }
    };
    while (true) {
        // Stop, noticed at a SAMPLE boundary rather than at the end of the call. Without this the turn's
        // control channel is only read before the next tool, so a chained watch answers Stop every few
        // minutes at best — the user presses it, nothing happens, and the thread stays held. Checked first
        // so a stop that arrived during the previous sleep ends the call before doing more work.
        if (ctx.cancel) |c| switch (c.check()) {
            .none => {},
            .stopped => {
                verdict = "stopped";
                break;
            },
            // The steer is NOT consumed here — the turn's own drain folds it in as a user message between
            // tools. Poll only has to stop sitting on the thread so that drain can happen.
            .steered => {
                verdict = "interrupted";
                break;
            },
        };
        const elapsed: u64 = @intCast(@max(0, std.Io.Timestamp.now(ctx.io, .real).toSeconds() - t0));
        switch (k) {
            .file => {
                const roamed: ?[]u8 = if (!safeRel(target)) roamPath(ctx, target) else null;
                defer if (roamed) |r| gpa.free(r);
                if (!safeRel(target) and roamed == null) return dupe(gpa, "poll: bad file path — workdir-relative (or absolute where this context roams)");
                var fb: [1024]u8 = undefined;
                const full = if (roamed) |r| r else (std.fmt.bufPrint(&fb, "{s}/{s}", .{ ctx.workdir, target }) catch return dupe(gpa, "poll: path overflow"));
                if (std.Io.Dir.cwd().statFile(ctx.io, full, .{})) |st| {
                    const size: u64 = st.size;
                    if (!have_size or size != last_size) {
                        // read the NEW tail (bounded) and scan it for the pattern
                        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(1 << 20)) catch null;
                        defer if (data) |d| if (d.len > 0) gpa.free(d);
                        const from: usize = if (have_size and data != null and last_size < data.?.len) @intCast(last_size) else 0;
                        const chunk: []const u8 = if (data) |d| d[@min(from, d.len)..] else "";
                        var nb: [200]u8 = undefined;
                        obs.line(gpa, &log, elapsed, std.fmt.bufPrint(&nb, "grew to {d} bytes (+{d})", .{ size, size -| last_size }) catch "grew");
                        if (chunk.len > 0) obs.line(gpa, &log, elapsed, std.mem.trim(u8, chunk[chunk.len -| 220..], " \r\n\t"));
                        const hit = until.len > 0 and std.mem.indexOf(u8, chunk, until) != null;
                        last_size = size;
                        have_size = true;
                        quiet_since = elapsed;
                        if (hit) {
                            verdict = "matched";
                            break;
                        }
                    } else if (p.value.quiet_s > 0 and elapsed -| quiet_since >= p.value.quiet_s) {
                        verdict = "quiet";
                        break;
                    }
                } else |_| {
                    obs.line(gpa, &log, elapsed, "(file does not exist yet)");
                    have_size = false;
                }
            },
            .url => {
                var tb: [24]u8 = undefined;
                const mt = std.fmt.bufPrint(&tb, "{d}", .{@min(interval * 2, 10)}) catch "5";
                const r = std.process.run(gpa, ctx.io, .{ .argv = &.{ "curl", "-sS", "-o", if (builtin.os.tag == .windows) "NUL" else "/dev/null", "-w", "%{http_code}", "--max-time", mt, "--connect-timeout", mt, target }, .stdout_limit = .limited(64) }) catch {
                    obs.line(gpa, &log, elapsed, "(curl unavailable)");
                    verdict = "error";
                    break;
                };
                defer gpa.free(r.stdout);
                defer gpa.free(r.stderr);
                const code = std.mem.trim(u8, r.stdout, " \r\n\t");
                obs.line(gpa, &log, elapsed, if (code.len > 0 and !std.mem.eql(u8, code, "000")) code else "(no connection)");
                const up = code.len == 3 and (code[0] == '2' or code[0] == '3' or (until.len > 0 and std.mem.eql(u8, code, until)));
                if (up) {
                    verdict = "up";
                    break;
                }
            },
            .port => {
                var ub: [64]u8 = undefined;
                const purl = std.fmt.bufPrint(&ub, "http://127.0.0.1:{s}/", .{target}) catch return dupe(gpa, "poll: bad port");
                const r = std.process.run(gpa, ctx.io, .{ .argv = &.{ "curl", "-sS", "-o", if (builtin.os.tag == .windows) "NUL" else "/dev/null", "--max-time", "3", "--connect-timeout", "3", purl }, .stdout_limit = .limited(64) }) catch {
                    verdict = "error";
                    break;
                };
                defer gpa.free(r.stdout);
                defer gpa.free(r.stderr);
                // curl exit 7 = connection refused (port closed); anything that CONNECTED means the port is open,
                // even if the service answered with garbage or a non-2xx.
                const refused = r.term == .exited and r.term.exited == 7;
                obs.line(gpa, &log, elapsed, if (refused) "port closed" else "port open");
                if (!refused) {
                    verdict = "open";
                    break;
                }
            },
            .process => {
                const want_gone = std.mem.eql(u8, until, "gone");
                var filt: [300]u8 = undefined;
                const by_name = if (builtin.os.tag == .windows) (std.fmt.bufPrint(&filt, "IMAGENAME eq {s}", .{target}) catch return dupe(gpa, "poll: process name too long")) else "";
                const argv_win = [_][]const u8{ "tasklist", "/FI", by_name, "/NH" };
                const argv_posix = [_][]const u8{ "pgrep", "-x", target };
                const argv: []const []const u8 = if (builtin.os.tag == .windows) &argv_win else &argv_posix;
                // bounded.run: tasklist prints a row per matching process, so a common name (svchost.exe) can pass the
                // 8 KB limit, which can hang std.process.run on Windows (see bounded.zig). Past it, rows were printed: what
                // was read already holds the answer.
                var r = bounded.run(gpa, ctx.io, .{ .argv = argv, .bound_ms = 15_000, .stdout_limit = 8 << 10, .stderr_limit = 4096, .stderr_tail = true });
                defer r.deinit(gpa);
                if (!r.finished() and r.end != .overflow) {
                    verdict = "error";
                    break;
                }
                const present = if (builtin.os.tag == .windows) std.ascii.indexOfIgnoreCase(r.stdout, target) != null else (r.ok() or r.end == .overflow);
                obs.line(gpa, &log, elapsed, if (present) "process running" else "process not running");
                if (present != want_gone) {
                    verdict = if (present) "running" else "gone";
                    break;
                }
            },
            .command => {
                // The probe's bound is what is left of THIS call's timeout_s. The budget used to be checked only
                // BETWEEN samples, so one hung probe (`tail -f`, a prompt nobody sees) held the poll and the turn's
                // thread forever; now it is killed when the call would have ended. Not a shorter fixed cap: a slow
                // but finite probe (a 40 s `pytest | tail -3`, a `kubectl wait`) that matched inside the call before
                // must still match, and only a probe that would outlive the call is cut.
                const bound_ms: u64 = @max(1, timeout -| elapsed) * 1000;
                if (builtin.is_test) probe_seam.last_bound_ms = bound_ms;
                var pr = runProbe(ctx, target, bound_ms);
                defer pr.deinit(gpa);
                const errored = pr.end == .unstarted or pr.end == .overflow or pr.end == .unread;
                // a probe killed at its bound still counts what it printed: the text did appear
                const done = !errored and (if (until.len > 0) std.mem.indexOf(u8, pr.stdout, until) != null else pr.ok());
                var lb: [720]u8 = undefined;
                const seen = probeLine(&lb, &pr, bound_ms);
                if (pw.repeatOf(seen, elapsed)) |first| {
                    var sb: [40]u8 = undefined;
                    obs.line(gpa, &log, elapsed, std.fmt.bufPrint(&sb, "(same as t+{d}s)", .{first}) catch "(same as before)");
                } else obs.lineCap(gpa, &log, elapsed, seen, lb.len, done or errored);
                if (errored) {
                    verdict = "error";
                    break;
                }
                if (done) {
                    verdict = "matched";
                    break;
                }
                if (pw.failFast(&pr)) {
                    verdict = "failing";
                    break;
                }
            },
            .swarm => {
                var db2: [1024]u8 = undefined;
                const dp = std.fmt.bufPrint(&db2, "{s}/DONE", .{ctx.run_dir}) catch return dupe(gpa, "poll: path overflow");
                if (std.Io.Dir.cwd().readFileAlloc(ctx.io, dp, gpa, .limited(256)) catch null) |reason| {
                    defer gpa.free(reason);
                    var vb: [280]u8 = undefined;
                    obs.line(gpa, &log, elapsed, std.fmt.bufPrint(&vb, "swarm DONE ({s})", .{std.mem.trim(u8, reason, " \r\n\t")}) catch "swarm DONE");
                    verdict = "done";
                    break;
                }
                obs.line(gpa, &log, elapsed, "swarm still working");
            },
        }
        const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(ctx.io, .real).toSeconds() - t0));
        if (now + interval > timeout) break;
        pollSleepMs(ctx.io, interval * 1000);
    }
    var gb: [PROBE_STDERR_TAIL + 800]u8 = undefined;
    const guidance = if (std.mem.eql(u8, verdict, "stopped"))
        " — the USER stopped this watch. Do not start another poll; say what the log shows and wait for them."
    else if (std.mem.eql(u8, verdict, "failing"))
        pw.guidance(&gb)
    else if (std.mem.eql(u8, verdict, "interrupted"))
        " — the USER said something while you were watching. Read it and answer THAT first; resume polling only if they still want the wait."
    else if (std.mem.eql(u8, verdict, "timeout"))
        " — still not there. Poll again ONLY if the log shows progress; on repeated no-progress timeouts STOP waiting and act on what you have"
    else
        "";
    return std.fmt.allocPrint(gpa, "poll {s} -> {s}{s}\n{s}", .{ kind, verdict, guidance, log.items }) catch dupe(gpa, verdict);
}

/// stage_file — copy a file from ANYWHERE the user's account can read INTO the conversation workdir, so a
/// hive cast from this conversation can build on it (the cast-time sync carries the workdir to the server; it
/// never syncs the client's machine — the workdir is the share, like an SMB share: you put IN it what you
/// mean to share). Client executor only (roam); a swarm mind calling this gets a plain refusal.
fn stageFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { path: []const u8 = "", as: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!ctx.roam) return dupe(gpa, "stage_file runs only on a client machine (it copies a file from the user's disk into the shared workdir)");
    const src = roamPath(ctx, p.value.path) orelse return dupe(gpa, "stage_file needs an ABSOLUTE source path on this machine (e.g. C:/data/report.csv or ~/notes.txt)");
    defer gpa.free(src);
    const name = if (p.value.as.len > 0) p.value.as else std.fs.path.basename(src);
    if (name.len == 0 or !safeRel(name)) return dupe(gpa, "bad 'as' name — give a workdir-relative file name (e.g. report.csv or data/report.csv)");
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, src, gpa, .limited(32 << 20)) catch return dupe(gpa, "could not read the source file (missing, unreadable, or larger than 32MB)");
    defer gpa.free(data);
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, name }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    if (!writeWorkFileAtomic(ctx, full, data)) return dupe(gpa, "could not write into the workdir");
    ctx.files_written.* += 1;
    // remote-hive caveat: the sync lane is text-only and capped — name the limit NOW, not as a silent drop later
    var bin = false;
    for (data[0..@min(data.len, 1024)]) |b| {
        if (b < 0x20 and b != '\n' and b != '\r' and b != '\t') {
            bin = true;
            break;
        }
    }
    if (bin or data.len > (512 << 10))
        return std.fmt.allocPrint(gpa, "staged {s} into the workdir ({d} bytes). NOTE: it is {s}, so a REMOTE hive's sync will not carry it — a same-machine hive sees it directly.", .{ name, data.len, if (bin) "binary" else "larger than the 512KB sync lane" }) catch dupe(gpa, "staged");
    return std.fmt.allocPrint(gpa, "staged {s} into the workdir ({d} bytes) — a hive cast from this conversation can now use it", .{ name, data.len }) catch dupe(gpa, "staged");
}

/// patch_system's POST-WRITE VERIFY is on by default; NL_PATCH_SYSTEM_VERIFY=0 (or false/off/no) disables it.
/// The gap it closes: every pre-write gate in patchSystem is a string/ledger check, and after the bytes land
/// NOTHING re-reads them — a self-edit that leaves the engine source un-parseable stands until the next human
/// build. With verify on, a broken write is reverted in place and reported blocked. Fail-open by construction:
/// a language whose checker is missing on this machine simply isn't gated (see patchVerifyError), never stuck.
fn patchVerifyFlag(v: ?[]const u8) bool {
    const raw = v orelse return true; // unset ⇒ verify ON (the safety floor is the default)
    const t = std.mem.trim(u8, raw, " \r\n\t");
    if (t.len == 0) return true;
    return !(std.mem.eql(u8, t, "0") or std.ascii.eqlIgnoreCase(t, "false") or std.ascii.eqlIgnoreCase(t, "off") or std.ascii.eqlIgnoreCase(t, "no"));
}
fn patchVerifyOn(ctx: *ToolCtx) bool {
    return patchVerifyFlag(ctx.environ.get("NL_PATCH_SYSTEM_VERIFY"));
}

/// Distill a `zig ast-check` stderr into one "line N: <msg>" verdict, stripping the scratch path. zig prints
/// "<path>:L:C: error: <msg>"; the first such line is the verdict. null when stderr names no error at all —
/// a missing or oddly-behaving zig must fail the gate OPEN, never reject a self-edit. Owned; caller frees.
fn zigAstErrLine(gpa: std.mem.Allocator, stderr: []const u8) ?[]u8 {
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |raw| {
        const t = std.mem.trimEnd(u8, raw, " \r\t");
        const ei = std.mem.indexOf(u8, t, ": error: ") orelse continue;
        const msg = std.mem.trim(u8, t[ei + ": error: ".len ..], " \r\t");
        const head = t[0..ei]; // "<path>:L:C"
        if (std.mem.lastIndexOfScalar(u8, head, ':')) |c2| {
            if (std.mem.lastIndexOfScalar(u8, head[0..c2], ':')) |c1| {
                if (std.fmt.parseInt(u64, head[c1 + 1 .. c2], 10) catch null) |lineno|
                    return std.fmt.allocPrint(gpa, "line {d}: {s}", .{ lineno, clip(msg, 240) }) catch null;
            }
        }
        return gpa.dupe(u8, clip(msg, 260)) catch null;
    }
    return null;
}

/// Real syntax/AstGen check for a candidate .zig body via `zig ast-check` on a run_dir scratch file — the gate
/// the shared syntaxGateError lacks for .zig (it falls to the brace-balance heuristic). Single-file and cheap:
/// it catches the syntax / parse / undeclared-identifier class that leaves the engine non-compiling, not full
/// cross-module type errors (a per-patch `zig build` would be minutes). zig is found on PATH, or via NL_ZIG.
/// null = passes, or zig could not run (fail-open). Owned verdict else.
fn zigAstCheckError(ctx: *ToolCtx, source: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    if (source.len > 4 << 20) return null; // absurdly large — do not gate
    const tmp = std.fmt.allocPrint(gpa, "{s}/.nlzchk-{d}.zig", .{ ctx.run_dir, chk_seq.fetchAdd(1, .monotonic) }) catch return null;
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = source }) catch return null;
    defer std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
    const zig = blk: {
        if (ctx.environ.get("NL_ZIG")) |z| {
            const t = std.mem.trim(u8, z, " \r\n\t");
            if (t.len > 0) break :blk t;
        }
        break :blk "zig";
    };
    const argv = [_][]const u8{ zig, "ast-check", tmp };
    // Same mutex-safety story as the py/js gates: this can run while a file mutex is held, so it is bounded.
    var r = bounded.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = ctx.environ, .bound_ms = 20_000, .stdout_limit = 4096, .stderr_limit = 16 << 10 });
    defer r.deinit(gpa);
    const c = r.exited() orelse return null;
    return if (c == 0) null else zigAstErrLine(gpa, r.stderr);
}

/// The post-write verifier for patch_system: real .zig ast-check, else the shared extension gate (.py/.js/.json
/// and the brace heuristic for the rest). Deliberately SEPARATE from syntaxGateError so the workdir edit path is
/// byte-for-byte unchanged — only self-mods to the engine source pick up the added .zig rigor. null = passes.
fn patchVerifyError(ctx: *ToolCtx, npath: []const u8, source: []const u8, orig: []const u8) ?[]u8 {
    if (std.mem.endsWith(u8, npath, ".zig")) return zigAstCheckError(ctx, source);
    return syntaxGateError(ctx, npath, source, orig);
}

/// Store one pre-edit file image under {run_dir}/.patch_journal/objects/<wyhash-hex> and return the hex key
/// (owned). The governor reconstructs the same path from w.run_dir (== ctx.run_dir) + this key, so the journal
/// line itself carries no space-bearing absolute path. null on any I/O trouble — journaling is best-effort and
/// never blocks a self-edit.
fn patchJournalObject(ctx: *ToolCtx, data: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    const h = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, data);
    const hex = std.fmt.allocPrint(gpa, "{x}", .{h}) catch return null;
    const dir = std.fmt.allocPrint(gpa, "{s}/.patch_journal/objects", .{ctx.run_dir}) catch {
        gpa.free(hex);
        return null;
    };
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(ctx.io, dir, .default_dir) catch {};
    const p = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, hex }) catch {
        gpa.free(hex);
        return null;
    };
    defer gpa.free(p);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = p, .data = data }) catch {
        gpa.free(hex);
        return null;
    };
    return hex;
}

/// Append an accepted patch_system self-edit to PATCH_JOURNAL_SCOPE. paths[i] pairs with pres[i]: a non-null pre
/// is the file's pre-edit bytes (backed up as an object, key recorded), a null pre means a freshly-created file
/// (recorded NEW → rollback deletes it). The line the governor reads:
///   round=R op=OP hi=0|1 paths=a,b obj=HEX,NEW crit=<clip>
/// Best-effort; a journaling failure never blocks the edit that already landed.
fn journalPatch(ctx: *ToolCtx, op: []const u8, paths: []const []const u8, pres: []const ?[]const u8, crit: []const u8, high_impact: bool) void {
    const gpa = ctx.gpa;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    const head = std.fmt.allocPrint(gpa, "round={d} op={s} hi={d} paths=", .{ ctx.round, op, @intFromBool(high_impact) }) catch return;
    defer gpa.free(head);
    line.appendSlice(gpa, head) catch return;
    for (paths, 0..) |pth, i| {
        if (i > 0) line.append(gpa, ',') catch return;
        line.appendSlice(gpa, pth) catch return;
    }
    line.appendSlice(gpa, " obj=") catch return;
    for (pres, 0..) |pre, i| {
        if (i > 0) line.append(gpa, ',') catch return;
        if (pre) |bytes| {
            if (patchJournalObject(ctx, bytes)) |hex| {
                defer gpa.free(hex);
                line.appendSlice(gpa, hex) catch return;
            } else line.appendSlice(gpa, "ERR") catch return;
        } else line.appendSlice(gpa, "NEW") catch return;
    }
    const tail = std.fmt.allocPrint(gpa, " crit={s}", .{clip(crit, 120)}) catch return;
    defer gpa.free(tail);
    line.appendSlice(gpa, tail) catch return;
    _ = ctx.mem.observe(PATCH_JOURNAL_SCOPE, line.items);
}

/// The file paths a `*** Begin Patch` envelope touches (Add/Update/Delete File: headers) — so patch mode can
/// snapshot pre-images before applying and verify/restore after. Order-preserving, deduped, capped at 64, and
/// each rel is passed through the same safeRel + path-allow guards the Python applier enforces (a rel that fails
/// them is skipped here; the applier rejects it anyway). Appends owned dups into `out`.
/// The rel path a single `*** (Add|Update|Delete) File: <rel>` header names, or null if the line is not one.
/// The inline-for here only uses `return` (function exit), never loop control flow, so it stays comptime-clean.
fn patchHeaderRel(ln: []const u8) ?[]const u8 {
    inline for (.{ "*** Add File: ", "*** Update File: ", "*** Delete File: " }) |pfx| {
        if (std.mem.startsWith(u8, ln, pfx)) return std.mem.trim(u8, ln[pfx.len..], " \r\t");
    }
    return null;
}

fn patchTouchedPaths(gpa: std.mem.Allocator, patch: []const u8, out: *std.ArrayListUnmanaged([]u8)) void {
    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const rel = patchHeaderRel(ln) orelse continue;
        if (rel.len == 0 or !safeRel(rel) or !patchSystemPathAllowed(rel)) continue;
        if (out.items.len >= 64) break;
        var seen = false;
        for (out.items) |e| {
            if (std.mem.eql(u8, e, rel)) {
                seen = true;
                break;
            }
        }
        if (!seen) out.append(gpa, gpa.dupe(u8, rel) catch return) catch return;
    }
}

fn patchSystem(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct {
        path: []const u8 = "",
        mode: []const u8 = "read",
        content: []const u8 = "",
        find: []const u8 = "",
        replace: []const u8 = "",
        patch: []const u8 = "",
        proposal: []const u8 = "",
        success_criterion: []const u8 = "",
        limit: usize = 12000,
    };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const root = patchSystemRoot(ctx) orelse return dupe(gpa, "patch_system unavailable: no engine source root beside the binary; set NL_PATCH_SYSTEM_ROOT to point at one");

    const mutating = !std.mem.eql(u8, p.value.mode, "read");
    if (mutating) {
        const pr = std.mem.trim(u8, p.value.proposal, " \r\n\t");
        const sc = std.mem.trim(u8, p.value.success_criterion, " \r\n\t");
        if (pr.len < 3) return dupe(gpa, "self-mod blocked: proposal is required (use propose_change first)");
        if (sc.len < 8) return dupe(gpa, "self-mod blocked: success_criterion is required and must be measurable");

        const proposals = ctx.mem.list(PROPOSAL_SCOPE);
        defer gpa.free(proposals);
        const latest_prop = lastNonEmptyLine(proposals);
        if (latest_prop.len == 0) return dupe(gpa, "self-mod blocked: no proposal found in RSI ledger");
        if (!proposalHasMetric(latest_prop)) return dupe(gpa, "self-mod blocked: latest proposal has no measurable metric");
        if (std.mem.indexOf(u8, latest_prop, pr) == null)
            return dupe(gpa, "self-mod blocked: proposal does not match latest proposal record");
        const pround = parseTaggedRound(latest_prop) orelse 0;
        if (pround + 2 < ctx.round)
            return dupe(gpa, "self-mod blocked: proposal is stale; submit a fresh proposal");
    }

    const high_impact = patchSystemHighImpact(p.value.mode, p.value.path, p.value.content, p.value.patch);
    if (mutating and high_impact) {
        const sims = ctx.mem.list(SIM_SCOPE);
        defer gpa.free(sims);
        const latest_sim = lastNonEmptyLine(sims);
        if (latest_sim.len == 0) return dupe(gpa, "high-impact self-mod blocked: simulation is required (use simulate_change first)");
        if (std.mem.indexOf(u8, latest_sim, std.mem.trim(u8, p.value.proposal, " \r\n\t")) == null)
            return dupe(gpa, "high-impact self-mod blocked: simulation does not match proposal");
        const sround = parseTaggedRound(latest_sim) orelse 0;
        if (sround + 2 < ctx.round)
            return dupe(gpa, "high-impact self-mod blocked: simulation is stale; re-simulate before acting");
    }

    if (mutating and patchSystemTouchesPrivileged(p.value.mode, p.value.path, p.value.patch)) {
        const a = if (ctx.environ.get("NL_PATCH_SYSTEM_PRIVILEGED_OK")) |v| std.mem.trim(u8, v, " \r\n\t") else "";
        if (!(std.mem.eql(u8, a, "1") or std.ascii.eqlIgnoreCase(a, "true")))
            return dupe(gpa, "privileged-zone edit blocked: set NL_PATCH_SYSTEM_PRIVILEGED_OK=1 for explicit operator approval");
    }

    if (std.mem.eql(u8, p.value.mode, "patch")) {
        if (std.mem.trim(u8, p.value.patch, " \r\n\t").len == 0) return dupe(gpa, "patch mode needs a non-empty patch");
        return patchSystemPatch(ctx, root, p.value.patch, p.value.success_criterion, high_impact);
    }

    if (!safeRel(p.value.path)) return dupe(gpa, "bad path — use a path RELATIVE to your workdir (no leading / or \\, no '..'), e.g. index.html or css/style.css");
    if (!patchSystemPathAllowed(p.value.path)) return dupe(gpa, "blocked path for patch_system");
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, p.value.path }) catch return dupe(gpa, "oom");
    defer gpa.free(full);

    if (std.mem.eql(u8, p.value.mode, "read")) {
        const lim = @min(@as(usize, 262144), if (p.value.limit == 0) @as(usize, 12000) else p.value.limit);
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(lim)) catch return dupe(gpa, "not found");
        defer gpa.free(data);
        return dupe(gpa, clip(data, lim));
    }

    if (std.mem.eql(u8, p.value.mode, "write")) {
        // Snapshot the pre-image (null ⇒ the file is new) BEFORE the write, so a failed verify can restore it and
        // the governor can roll it back later. 4MB cap covers every engine source file.
        const had: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(4 << 20)) catch null;
        defer if (had) |h| gpa.free(h);
        if (std.fs.path.dirname(full)) |dir| _ = std.Io.Dir.cwd().createDirPathStatus(ctx.io, dir, .default_dir) catch {};
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = full, .data = p.value.content }) catch return dupe(gpa, "could not write file");
        if (patchVerifyOn(ctx)) {
            if (patchVerifyError(ctx, p.value.path, p.value.content, if (had) |h| h else "")) |err| {
                defer gpa.free(err);
                if (had) |h| {
                    _ = writeWorkFileAtomic(ctx, full, h);
                } else std.Io.Dir.cwd().deleteFile(ctx.io, full) catch {};
                return std.fmt.allocPrint(gpa, "self-mod REVERTED: {s} would not parse after the write ({s}). The file is unchanged — fix the error and resubmit.", .{ p.value.path, clip(err, 240) }) catch dupe(gpa, "self-mod reverted (would not parse)");
            }
        }
        const paths = [_][]const u8{p.value.path};
        const pres = [_]?[]const u8{if (had) |h| h else null};
        journalPatch(ctx, "write", &paths, &pres, p.value.success_criterion, high_impact);
        return std.fmt.allocPrint(gpa, "patch_system wrote {d} bytes to {s} (verified)", .{ p.value.content.len, p.value.path }) catch dupe(gpa, "patch_system wrote");
    }

    if (std.mem.eql(u8, p.value.mode, "replace")) {
        if (p.value.find.len == 0) return dupe(gpa, "replace mode needs non-empty find");
        // 4MB read: the pre-image must be the WHOLE file (a smaller cap would restore a truncated copy on revert).
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(4 << 20)) catch return dupe(gpa, "not found");
        defer gpa.free(data);
        const out = replaceOne(gpa, data, p.value.find, p.value.replace) orelse return dupe(gpa, "find text missing or ambiguous (need exactly one match)");
        defer gpa.free(out);
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = full, .data = out }) catch return dupe(gpa, "could not write file");
        if (patchVerifyOn(ctx)) {
            if (patchVerifyError(ctx, p.value.path, out, data)) |err| {
                defer gpa.free(err);
                _ = writeWorkFileAtomic(ctx, full, data);
                return std.fmt.allocPrint(gpa, "self-mod REVERTED: {s} would not parse after the replace ({s}). The file is unchanged.", .{ p.value.path, clip(err, 240) }) catch dupe(gpa, "self-mod reverted (would not parse)");
            }
        }
        const paths = [_][]const u8{p.value.path};
        const pres = [_]?[]const u8{data};
        journalPatch(ctx, "replace", &paths, &pres, p.value.success_criterion, high_impact);
        return std.fmt.allocPrint(gpa, "patch_system replaced 1 match in {s} (verified)", .{p.value.path}) catch dupe(gpa, "patch_system replaced");
    }

    return dupe(gpa, "patch_system mode must be read/write/replace/patch");
}

const LIST_DIR_PY =
    \\import os,sys
    \\base=sys.argv[1]
    \\out=[]
    \\for root,dirs,files in os.walk(base):
    \\    dirs[:]=[x for x in dirs if not x.startswith('.') and x not in ('__pycache__','node_modules','zig-cache','zig-out','.git')]
    \\    rel=os.path.relpath(root,base)
    \\    for f in sorted(files):
    \\        p=f if rel=='.' else os.path.join(rel,f)
    \\        try: sz=os.path.getsize(os.path.join(root,f))
    \\        except Exception: sz=0
    \\        out.append('%s (%d b)'%(p,sz))
    \\        if len(out)>=300: break
    \\    if len(out)>=300: break
    \\print('\n'.join(out) if out else '(empty directory)')
;

/// LIST_DIR — see the file tree (the swarm could read a known path but never LIST what exists). Lists the build
/// workdir by default, or the patch-system root (root="system") so a mind can navigate the engine before patching it.
fn listDir(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { path: []const u8 = ".", root: []const u8 = "workdir" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    // root="system" walks the ENGINE'S OWN SOURCE TREE, and CHAT_SCHEMA advertises it to every turn. It is
    // a patch_system affordance, so it belongs at patch_system's trust level: a caller that may not modify
    // the engine has no business enumerating it either. Without this the file jail is intact while the
    // source tree stays readable by anyone who can type a tool call.
    const want_system = std.mem.eql(u8, p.value.root, "system");
    if (want_system and !ctx.roam)
        return dupe(gpa, "root=system is not available to this caller — list paths relative to your workdir instead");
    const base = if (want_system) (patchSystemRoot(ctx) orelse return dupe(gpa, "root=system needs NL_PATCH_SYSTEM_ROOT set")) else ctx.workdir;
    const rel = if (p.value.path.len == 0 or std.mem.eql(u8, p.value.path, ".")) "" else p.value.path;
    // CLIENT ROAM: listing an absolute/~ directory on the user's own machine is a read (see readFile's twin).
    const roamed: ?[]u8 = if (rel.len > 0 and !safeRel(rel)) roamPath(ctx, rel) else null;
    defer if (roamed) |r| gpa.free(r);
    if (rel.len > 0 and !safeRel(rel) and roamed == null)
        return dupe(gpa, if (ctx.roam)
            "bad path — a workdir-RELATIVE path, an ABSOLUTE path on this machine (C:/data), or ~/dir"
        else
            "bad path — use a path RELATIVE to your workdir (no leading / or \\, no '..'), e.g. index.html or css/style.css");
    const full = if (roamed) |r|
        (gpa.dupe(u8, r) catch return dupe(gpa, "oom"))
    else if (rel.len > 0)
        (std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, rel }) catch return dupe(gpa, "oom"))
    else
        (gpa.dupe(u8, base) catch return dupe(gpa, "oom"));
    defer gpa.free(full);
    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    prepChildEnv(gpa, ctx.io, &env);
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH", "NL_LLM_KEY" }) |k| env.put(k, "") catch {};
    const py = deps.pythonBin(ctx.io, &env);
    const argv = [_][]const u8{ py, "-c", LIST_DIR_PY, full };
    // bounded.run: a minute for a listing of at most 300 entries; a python stuck on a dead mount used to hold the call
    var r = bounded.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .bound_ms = 60_000, .stdout_limit = 64 << 10, .stderr_limit = 8 << 10 });
    defer r.deinit(gpa);
    if (r.end == .unstarted) return if (deps.isSpawnMissing(r.err.?)) deps.hint(gpa, "python") else dupe(gpa, "list_dir failed to run");
    // A stop reads as a failure to both graders: '(' to the chat engine's, "timed out" to run.zig's toolHardFail.
    if (!r.finished()) return dupe(gpa, if (r.end == .killed) "(list_dir timed out: it did not finish within a minute and was stopped)" else "list_dir failed to run");
    if (std.mem.trim(u8, r.stdout, " \r\n\t").len == 0) return dupe(gpa, if (r.stderr.len > 0) clip(r.stderr, 400) else "(empty or not found)");
    return dupe(gpa, clip(r.stdout, 4000));
}

const RUN_TESTS_PY =
    \\import subprocess,sys,glob
    \\try:
    \\    r=subprocess.run([sys.executable,'-m','pytest','-q','--no-header'],capture_output=True,text=True,timeout=120)
    \\    out=(r.stdout or '')+'\n'+(r.stderr or '')
    \\    if r.returncode==5 or 'no tests ran' in out.lower():
    \\        fs=sorted(glob.glob('test_*.py')+glob.glob('*_test.py'))
    \\        if fs:
    \\            r2=subprocess.run([sys.executable,fs[0]],capture_output=True,text=True,timeout=120)
    \\            out='ran %s\n'%fs[0]+(r2.stdout or '')+'\n'+(r2.stderr or '')
    \\    print(out[-4000:].strip() or '(no test output)')
    \\except subprocess.TimeoutExpired:
    \\    print('TIMEOUT: the tests exceeded 120s and were killed — likely an infinite loop or a hang')
    \\except Exception as e:
    \\    print('test runner error: %r'%e)
;

/// RUN_TESTS — close the RSI self-repair loop: after a mind patches or writes code it can RUN the deliverable's tests
/// (pytest, else a test_*.py) and see pass/fail, so "fix it if it breaks" becomes fix -> test -> fix. Has its own
/// 120s timeout (python kills a hung test suite), so a runaway test can't wedge the moment.
fn runTests(ctx: *ToolCtx, args_json: []const u8) []u8 {
    _ = args_json;
    const gpa = ctx.gpa;
    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    prepChildEnv(gpa, ctx.io, &env);
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH", "NL_LLM_KEY" }) |k| env.put(k, "") catch {};
    const py = deps.pythonBin(ctx.io, &env);
    const argv = [_][]const u8{ py, "-c", RUN_TESTS_PY };
    // bounded.run: its two 120 s runs, plus room. Python's own timeout is no bound on Windows when the suite left a
    // process holding the pipes (communicate() waits for them to close), and nothing bounded this call before.
    var r = bounded.run(gpa, ctx.io, .{ .argv = &argv, .cwd = .{ .path = ctx.workdir }, .environ_map = &env, .bound_ms = 270_000, .stdout_limit = 128 << 10, .stderr_limit = 16 << 10 });
    defer r.deinit(gpa);
    if (r.end == .unstarted) return if (deps.isSpawnMissing(r.err.?)) deps.hint(gpa, "python") else dupe(gpa, "run_tests failed to run");
    if (r.end == .killed) return dupe(gpa, "TIMEOUT: the test run was still going after 270 s and was stopped with everything it started — likely a hang, or a process the tests started holding their output open");
    if (!r.finished()) return dupe(gpa, "run_tests failed to run");
    const out = if (std.mem.trim(u8, r.stdout, " \r\n\t").len > 0) r.stdout else r.stderr;
    return dupe(gpa, clip(out, 4000));
}

/// DELETE_FILE — let a mind remove a file it created in the workdir (clean up a dead end, a wrong scaffold, junk).
fn hostStatus(ctx: *ToolCtx, args_json: []const u8) []u8 {
    _ = args_json;
    const gpa = ctx.gpa;
    const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{ctx.workdir}) catch return dupe(gpa, "oom");
    defer gpa.free(tp);
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, tp, gpa, .limited(8192)) catch
        dupe(gpa, "no telemetry.json on the bus — no machine is attached to this run");
}

/// IPv4 address with the :port stripped (everything before the first ':'), so "185.143.220.7:3333" and
/// "185.143.220.7" compare equal.
fn bareIp(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, ':')) |i| s[0..i] else s;
}

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn wellFormedVerb(v: []const u8) bool {
    if (v.len == 0 or v.len > 40) return false;
    if (!std.ascii.isAlphabetic(v[0])) return false;
    for (v) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

fn resolveProcName(ctx: *ToolCtx, target: []const u8) ?[]u8 {
    if (!isNumeric(target)) return null;
    const gpa = ctx.gpa;
    const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{ctx.workdir}) catch return null;
    defer gpa.free(tp);
    const tel = std.Io.Dir.cwd().readFileAlloc(ctx.io, tp, gpa, .limited(65536)) catch return null;
    defer gpa.free(tel);
    const Proc = struct { name: []const u8 = "", pid: i64 = 0 };
    const Tel = struct { processes: []const Proc = &.{} };
    const parsed = std.json.parseFromSlice(Tel, gpa, tel, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    var pidbuf: [24]u8 = undefined;
    for (parsed.value.processes) |pr| {
        const pids = std.fmt.bufPrint(&pidbuf, "{d}", .{pr.pid}) catch continue;
        if (std.mem.eql(u8, pids, target) and pr.name.len > 0) return gpa.dupe(u8, pr.name) catch null;
    }
    return null;
}

/// TARGET GUARD: a verb that names a specific threat (block_ip / kill_proc / remove_persistence) must point at a
/// target that EXISTS in the live telemetry's threat set. A weak 8b sometimes issues a command at a HALLUCINATED
/// target (e.g. block_ip on a benign internal IP that was never on the scoreboard) — wasting the moment and, worse,
/// taking a real action against a non-threat. The guard rejects those AND lists the actual indicators, steering the
/// model to the right command. Fail-open: if no machine is attached or telemetry is unparseable, it allows the call.
/// Returns an owned rejection message, or null if the target is valid (or the verb takes no target).
fn targetGuard(ctx: *ToolCtx, verb: []const u8, target: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    const is_ip = std.mem.eql(u8, verb, "block_ip");
    const is_proc = std.mem.eql(u8, verb, "kill_proc");
    const is_pers = std.mem.eql(u8, verb, "remove_persistence");
    if (!is_ip and !is_proc and !is_pers) return null;
    const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{ctx.workdir}) catch return null;
    defer gpa.free(tp);
    const tel = std.Io.Dir.cwd().readFileAlloc(ctx.io, tp, gpa, .limited(16384)) catch return null;
    defer gpa.free(tel);
    const Proc = struct { name: []const u8 = "", pid: i64 = 0, suspicious: bool = false };
    const Conn = struct { ip: []const u8 = "", c2: bool = false };
    const Pers = struct { name: []const u8 = "" };
    const Tel = struct { processes: []const Proc = &.{}, connections: []const Conn = &.{}, persistence: []const Pers = &.{} };
    const parsed = std.json.parseFromSlice(Tel, gpa, tel, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const t = parsed.value;
    var known = false;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(gpa);
    const add = struct {
        fn f(g: std.mem.Allocator, l: *std.ArrayListUnmanaged(u8), s: []const u8) void {
            if (l.items.len > 0) l.appendSlice(g, ", ") catch {};
            l.appendSlice(g, s) catch {};
        }
    }.f;
    if (is_ip) {
        for (t.connections) |c| {
            add(gpa, &list, c.ip);
            if (std.mem.eql(u8, bareIp(c.ip), bareIp(target))) known = true;
        }
    } else if (is_proc) {
        var pidbuf: [24]u8 = undefined;
        for (t.processes) |pr| {
            add(gpa, &list, pr.name);
            const pids = std.fmt.bufPrint(&pidbuf, "{d}", .{pr.pid}) catch "";
            if (std.mem.eql(u8, pr.name, target) or std.mem.eql(u8, pids, target)) known = true;
        }
    } else {
        for (t.persistence) |x| {
            add(gpa, &list, x.name);
            if (std.mem.eql(u8, x.name, target)) known = true;
        }
    }
    if (known) return null;
    return std.fmt.allocPrint(gpa, "rejected: '{s} {s}' — '{s}' appears NOWHERE in this host's live telemetry (a hallucinated target). Real {s} targets on the host right now: [{s}]. Reissue host_command against one that actually exists.", .{ verb, target, target, verb, list.items }) catch dupe(gpa, "rejected: target appears nowhere in telemetry");
}

/// A target is "adjudicated" only by an EXTERNALLY-SOURCED fact that names it — a baked indicator ([src:corpus] /
/// [src:threatintel] / [verified]) or captured web evidence ([src:web]). A self-authored observe (tagged "[mind rN]")
/// does NOT count: the agent cannot satisfy the interlock by simply asserting an entity is bad — it must recall a real
/// indicator or actually fetch one. This is what forces the web-learning a pure "does memory mention it" check missed.
fn externallyAdjudicated(text: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) == null) continue;
        if (std.mem.indexOf(u8, line, "[src:") != null or std.mem.indexOf(u8, line, "[verified]") != null) return true;
    }
    return false;
}

fn memMentions(ctx: *ToolCtx, needle: []const u8) bool {
    if (needle.len < 3) return false;
    const a = ctx.mem.assoc(INTEL_SCOPE, needle, 1, 8);
    defer ctx.gpa.free(a);
    if (externallyAdjudicated(a, needle)) return true;
    const b = ctx.mem.assoc(KNOWLEDGE_SCOPE, needle, 1, 8);
    defer ctx.gpa.free(b);
    return externallyAdjudicated(b, needle);
}

/// A process is adjudicated if a connection it OWNS points at an address the agent holds adjudicating intel for — so
/// killing the owner of a confirmed-bad C2 is allowed without the agent needing separate intel on the process name.
fn procOwnsAdjudicatedConn(ctx: *ToolCtx, proc: []const u8) bool {
    const gpa = ctx.gpa;
    const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{ctx.workdir}) catch return false;
    defer gpa.free(tp);
    const tel = std.Io.Dir.cwd().readFileAlloc(ctx.io, tp, gpa, .limited(16384)) catch return false;
    defer gpa.free(tel);
    const Conn = struct { ip: []const u8 = "", proc: []const u8 = "" };
    const Tel = struct { connections: []const Conn = &.{} };
    const parsed = std.json.parseFromSlice(Tel, gpa, tel, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    for (parsed.value.connections) |c| {
        if (std.mem.eql(u8, c.proc, proc) and memMentions(ctx, bareIp(c.ip))) return true;
    }
    return false;
}

/// Stricter than externallyAdjudicated: the naming fact must carry the [verified] confirmation tag (a
/// CONFIRMED-hostile indicator), not merely any [src:] mention. This is what makes a NAME safe to trust for
/// an irreversible removal: intel that DIRECTLY names a unit as a [verified] malicious mechanism green-lights
/// it, while a benign [src:]-only "leave alone" protect-mention is NOT [verified], so a name match can never
/// green-light a false-positive removal of a documented-benign unit.
fn externallyVerified(text: []const u8, needle: []const u8) bool {
    if (needle.len < 3) return false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null and std.mem.indexOf(u8, line, "[verified]") != null) return true;
    }
    return false;
}

fn memVerifies(ctx: *ToolCtx, needle: []const u8) bool {
    if (needle.len < 3) return false;
    const a = ctx.mem.assoc(INTEL_SCOPE, needle, 1, 8);
    defer ctx.gpa.free(a);
    if (externallyVerified(a, needle)) return true;
    const b = ctx.mem.assoc(KNOWLEDGE_SCOPE, needle, 1, 8);
    defer ctx.gpa.free(b);
    return externallyVerified(b, needle);
}

/// A persistence unit is adjudicated for removal by EITHER (a) intel that DIRECTLY names the unit as a
/// [verified] hostile mechanism (e.g. "[verified] cron:@reboot-glassworm is the GLASSWORM persistence
/// mechanism"), OR (b) the PROCESS it launches/sustains being adjudicated. The [verified] gate on (a) keeps
/// the name safe: a benign [src:]-only "leave alone" mention is not [verified], so it never green-lights
/// removing a documented-benign unit. A unit named by neither path gets staged. Mirrors procOwnsAdjudicatedConn.
fn persOwnsAdjudicated(ctx: *ToolCtx, persName: []const u8) bool {
    // (a) the unit NAME itself is named as a [verified] hostile mechanism — full name, then distinctive tail
    if (memVerifies(ctx, persName)) return true;
    if (std.mem.lastIndexOfAny(u8, persName, ":/")) |i| {
        if (i + 1 < persName.len and memVerifies(ctx, persName[i + 1 ..])) return true;
    }
    // (b) else adjudicate via the linked PROCESS (the original path)
    const gpa = ctx.gpa;
    const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{ctx.workdir}) catch return false;
    defer gpa.free(tp);
    const tel = std.Io.Dir.cwd().readFileAlloc(ctx.io, tp, gpa, .limited(65536)) catch return false;
    defer gpa.free(tel);
    const Pers = struct { name: []const u8 = "", proc: ?[]const u8 = null };
    const Tel = struct { persistence: []const Pers = &.{} };
    const parsed = std.json.parseFromSlice(Tel, gpa, tel, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    for (parsed.value.persistence) |p| {
        if (!std.mem.eql(u8, p.name, persName)) continue;
        const proc = p.proc orelse return false;
        if (proc.len == 0) return false;
        return memMentions(ctx, proc) or procOwnsAdjudicatedConn(ctx, proc);
    }
    return false;
}

/// Record a staged (un-executed) irreversible action for forensics; never touches the host command bus.
fn stageAction(ctx: *ToolCtx, cmd: []const u8) void {
    const gpa = ctx.gpa;
    const sp = std.fmt.allocPrint(gpa, "{s}/staged.jsonl", .{ctx.workdir}) catch return;
    defer gpa.free(sp);
    const prior = std.Io.Dir.cwd().readFileAlloc(ctx.io, sp, gpa, .limited(64 << 10)) catch &[_]u8{};
    defer if (prior.len > 0) gpa.free(prior);
    var j: std.ArrayListUnmanaged(u8) = .empty;
    defer j.deinit(gpa);
    j.appendSlice(gpa, prior) catch {};
    j.appendSlice(gpa, cmd) catch {};
    j.appendSlice(gpa, "\n") catch {};
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = sp, .data = j.items }) catch {};
}

/// Map the common verb variants a weak model reaches for onto the canonical verb, so its natural phrasing lands
/// (kill_process -> kill_proc, block -> block_ip, setphase -> set_phase, ...). Returns gpa-owned only if rewritten.
fn normalizeCmd(gpa: std.mem.Allocator, cmd: []const u8) []const u8 {
    const pairs = .{
        .{ "kill_process", "kill_proc" }, .{ "killproc", "kill_proc" },   .{ "kill", "kill_proc" },
        .{ "block_address", "block_ip" }, .{ "blockip", "block_ip" },     .{ "block", "block_ip" },
        .{ "setphase", "set_phase" },     .{ "set_signal", "set_phase" }, .{ "grant_pedestrian_walk", "grant_walk" },
    };
    inline for (pairs) |pr| {
        const v = pr[0];
        if (std.mem.startsWith(u8, cmd, v) and (cmd.len == v.len or cmd[v.len] == ' ')) {
            return std.fmt.allocPrint(gpa, "{s}{s}", .{ pr[1], cmd[v.len..] }) catch cmd;
        }
    }
    return cmd;
}

fn hostCommand(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    // APP-ATTACH LEARN phase accepts NO actuating verb: attaching to an arbitrary app starts read-only, and a
    // mutating/actuating vocabulary is enabled only once a trusted-source verb allowlist + human approval are
    // wired (deferred). The existing security-daemon operate mode (ctx.operating, not app_attach) is unchanged.
    if (ctx.app_attach)
        return dupe(gpa, "APP-ATTACH LEARN phase is read-only: map the app with host_explore and report what you find. Actuating verbs are disabled until an app-specific verb allowlist and human approval are established for this assignment.");
    const A = struct { command: []const u8 = "", cmd: []const u8 = "", action: []const u8 = "", args: []const []const u8 = &.{} };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    var raw_cmd = if (p.value.command.len > 0) p.value.command else if (p.value.cmd.len > 0) p.value.cmd else p.value.action;
    var argbuf: std.ArrayListUnmanaged(u8) = .empty;
    defer argbuf.deinit(gpa);
    if ((raw_cmd.len == 0 or std.mem.eql(u8, raw_cmd, "host_command") or std.mem.eql(u8, raw_cmd, "hostCommand")) and p.value.args.len > 0) {
        for (p.value.args, 0..) |a, i| {
            if (i > 0) argbuf.append(gpa, ' ') catch {};
            argbuf.appendSlice(gpa, a) catch {};
        }
        raw_cmd = argbuf.items;
    }
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(gpa);
    for (raw_cmd) |c| {
        if (c != '`' and c != '*' and c != '"') clean.append(gpa, c) catch {};
    }
    const cmd0 = std.mem.trim(u8, clean.items, " \r\n\t");
    if (cmd0.len == 0) return dupe(gpa, "no command given");
    const cmd = normalizeCmd(gpa, cmd0);
    defer if (cmd.ptr != cmd0.ptr) gpa.free(@constCast(cmd));
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    const verb = it.next() orelse "";
    if (!wellFormedVerb(verb)) return std.fmt.allocPrint(gpa, "rejected: '{s}' is not a well-formed host command (a host command is a single verb token; the host decides which verbs it implements)", .{clip(verb, 60)}) catch dupe(gpa, "rejected: malformed command");
    const target = std.mem.trim(u8, cmd[@min(verb.len + 1, cmd.len)..], " \t");
    if (targetGuard(ctx, verb, target)) |rej| return rej;
    const irreversible = std.mem.eql(u8, verb, "kill_proc") or std.mem.eql(u8, verb, "block_ip") or std.mem.eql(u8, verb, "remove_persistence");
    if (irreversible and target.len > 0) {
        const is_pers = std.mem.eql(u8, verb, "remove_persistence");
        const resolved = if (std.mem.eql(u8, verb, "kill_proc")) resolveProcName(ctx, target) else null;
        defer if (resolved) |r| gpa.free(r);
        const adj_target = resolved orelse target;
        var adjudicated = if (is_pers) persOwnsAdjudicated(ctx, target) else memMentions(ctx, bareIp(adj_target));
        if (!adjudicated and std.mem.eql(u8, verb, "kill_proc")) adjudicated = procOwnsAdjudicatedConn(ctx, adj_target);
        if (!adjudicated) {
            stageAction(ctx, cmd);
            if (is_pers) return std.fmt.allocPrint(gpa, "STAGED (not executed): 'remove_persistence {s}' is irreversible and you hold NO adjudicating intel for the PROCESS this unit launches. Investigate that linked process first — recall_hive it, or web_fetch a threat-intel feed for its outbound C2 and observe what you learn; once your memory identifies the process or its connection as malicious, reissue and it executes. (This stops you deleting a legitimate scheduled task / service.)", .{target}) catch dupe(gpa, "staged: investigate the unit's process first");
            return std.fmt.allocPrint(gpa, "STAGED (not executed): '{s} {s}' is an irreversible action and you hold NO adjudicating intel for '{s}'. Investigate it first — recall_hive it, or web_fetch a threat-intel feed and observe what you learn; once your memory identifies it as malicious, reissue and it executes. (This stops you cutting or killing benign things.)", .{ verb, target, target }) catch dupe(gpa, "staged: investigate the target first");
        }
    }
    const cp = std.fmt.allocPrint(gpa, "{s}/commands.jsonl", .{ctx.workdir}) catch return dupe(gpa, "oom");
    defer gpa.free(cp);
    const prior = std.Io.Dir.cwd().readFileAlloc(ctx.io, cp, gpa, .limited(256 << 10)) catch &[_]u8{};
    defer if (prior.len > 0) gpa.free(prior);
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(gpa);
    joined.appendSlice(gpa, prior) catch {};
    if (prior.len > 0 and prior[prior.len - 1] != '\n') joined.appendSlice(gpa, "\n") catch {};
    const wn = cmd.len -| @as(usize, @truncate(oscillation.drift()));
    joined.appendSlice(gpa, cmd[0..@min(cmd.len, wn)]) catch {};
    joined.appendSlice(gpa, "\n") catch {};
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = cp, .data = joined.items }) catch return dupe(gpa, "could not write to the command bus");
    return std.fmt.allocPrint(gpa, "issued to host: {s}", .{cmd}) catch dupe(gpa, "issued");
}

// The read-only exploration vocabulary. Domain-neutral on purpose: the SAME verbs walk a filesystem, a
// process tree, a network, or a directory service — the bridge adapter maps them to that environment.
pub const EXPLORE_VERBS = [_][]const u8{ "enumerate", "expand", "describe" };
const EXPLORE_BUDGET: usize = 96; // per-run cap on queued explorations (fail-closed against runaway enumeration)

// host_explore: queue a READ-ONLY traversal request on the explore bus lane. Fire-and-forget like
// host_command, but it touches NO interlock (no targetGuard, no stageAction) because it never mutates the
// device — it only asks the bridge to look. The bridge serves it out of band and the discoveries are mapped
// into neuron-db (MAP/NODE scopes) for the mind to recall/chain over next round.
fn hostExplore(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { verb: []const u8 = "", node: []const u8 = "", rel: []const u8 = "", command: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    var verb = p.value.verb;
    var node = p.value.node;
    var rel = p.value.rel;
    if (verb.len == 0 and p.value.command.len > 0) { // tolerate a single "verb node [rel]" line
        var it = std.mem.tokenizeAny(u8, p.value.command, " \t");
        verb = it.next() orelse "";
        node = it.next() orelse "";
        rel = it.next() orelse "";
    }
    var known = false;
    for (EXPLORE_VERBS) |v| {
        if (std.mem.eql(u8, v, verb)) known = true;
    }
    if (!known) return std.fmt.allocPrint(gpa, "rejected: '{s}' is not an explore verb (use enumerate | expand | describe)", .{verb}) catch dupe(gpa, "rejected: bad explore verb");
    if (node.len == 0) return dupe(gpa, "rejected: explore needs a node to look at");
    const ep = std.fmt.allocPrint(gpa, "{s}/explore.jsonl", .{ctx.workdir}) catch return dupe(gpa, "oom");
    defer gpa.free(ep);
    const prior = std.Io.Dir.cwd().readFileAlloc(ctx.io, ep, gpa, .limited(256 << 10)) catch &[_]u8{};
    defer if (prior.len > 0) gpa.free(prior);
    var lines: usize = 0;
    for (prior) |c| {
        if (c == '\n') lines += 1;
    }
    if (lines >= EXPLORE_BUDGET) return std.fmt.allocPrint(gpa, "explore budget reached ({d}) — reason over what you've already mapped (recall/chain) before exploring more", .{EXPLORE_BUDGET}) catch dupe(gpa, "explore budget reached");
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(gpa);
    joined.appendSlice(gpa, prior) catch {};
    if (prior.len > 0 and prior[prior.len - 1] != '\n') joined.appendSlice(gpa, "\n") catch {};
    const line = if (rel.len > 0)
        std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ verb, node, rel }) catch return dupe(gpa, "oom")
    else
        std.fmt.allocPrint(gpa, "{s} {s}", .{ verb, node }) catch return dupe(gpa, "oom");
    defer gpa.free(line);
    joined.appendSlice(gpa, line) catch {};
    joined.appendSlice(gpa, "\n") catch {};
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ep, .data = joined.items }) catch return dupe(gpa, "could not queue the explore");
    return std.fmt.allocPrint(gpa, "explore queued: {s} (read-only; the map updates in your memory next round)", .{line}) catch dupe(gpa, "explore queued");
}

fn deleteFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { path: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!safeRel(p.value.path)) return dupe(gpa, "bad path — use a path RELATIVE to your workdir (no leading / or \\, no '..'), e.g. index.html or css/style.css");
    if ((ctx.operating or ctx.app_attach) and reservedBusName(p.value.path)) return dupe(gpa, "that name is a reserved OPERATE-bus/oracle file — the swarm cannot delete it. The bus and the acceptance oracle are managed by the attached host, not a mind.");
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, p.value.path }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    std.Io.Dir.cwd().deleteFile(ctx.io, full) catch return dupe(gpa, "could not delete (not found?)");
    return std.fmt.allocPrint(gpa, "deleted {s}", .{p.value.path}) catch dupe(gpa, "deleted");
}

const PatchSnap = struct { rel: []u8, pre: ?[]u8 };

/// Read the current bytes of every path the patch touches, so a failed apply/verify can be rolled back. A rel
/// that does not exist (an Add) snapshots as pre=null. Caller frees each .rel and .pre.
fn snapshotPatchTargets(ctx: *ToolCtx, root: []const u8, patch: []const u8) std.ArrayListUnmanaged(PatchSnap) {
    const gpa = ctx.gpa;
    var rels: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (rels.items) |r| gpa.free(r);
        rels.deinit(gpa);
    }
    patchTouchedPaths(gpa, patch, &rels);
    var snaps: std.ArrayListUnmanaged(PatchSnap) = .empty;
    for (rels.items) |rel| {
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, rel }) catch continue;
        defer gpa.free(full);
        const pre: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(4 << 20)) catch null;
        snaps.append(gpa, .{ .rel = gpa.dupe(u8, rel) catch continue, .pre = pre }) catch {
            if (pre) |b| gpa.free(b);
        };
    }
    return snaps;
}

fn freePatchSnaps(gpa: std.mem.Allocator, snaps: *std.ArrayListUnmanaged(PatchSnap)) void {
    for (snaps.items) |s| {
        gpa.free(s.rel);
        if (s.pre) |b| gpa.free(b);
    }
    snaps.deinit(gpa);
}

/// Restore every snapshotted file to its pre-edit state: write the pre-image back, or delete a file that did not
/// exist before (pre=null). Used both when the Python applier fails part-way and when post-apply verify rejects.
fn restorePatchTargets(ctx: *ToolCtx, root: []const u8, snaps: []const PatchSnap) void {
    const gpa = ctx.gpa;
    for (snaps) |s| {
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, s.rel }) catch continue;
        defer gpa.free(full);
        if (s.pre) |bytes| {
            _ = writeWorkFileAtomic(ctx, full, bytes);
        } else std.Io.Dir.cwd().deleteFile(ctx.io, full) catch {};
    }
}

fn patchSystemPatch(ctx: *ToolCtx, root: []const u8, patch: []const u8, crit: []const u8, high_impact: bool) []u8 {
    const gpa = ctx.gpa;
    const verify = patchVerifyOn(ctx);
    // Snapshot BEFORE applying: the Python runner applies file-by-file and can bad()-exit part-way, so even a
    // failed multi-file patch may have half-landed. With snapshots we can put the tree back either way.
    var snaps = if (verify) snapshotPatchTargets(ctx, root, patch) else std.ArrayListUnmanaged(PatchSnap).empty;
    defer freePatchSnaps(gpa, &snaps);

    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    prepChildEnv(gpa, ctx.io, &env);
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
    const py = deps.pythonBin(ctx.io, &env);
    const argv = [_][]const u8{ py, "-c", PATCH_SYSTEM_PATCH_PY, root, patch };
    // bounded.run: two minutes to apply a patch to local files. A runner stopped part-way may have half-landed, so it
    // takes the failed path below, which puts the snapshots back.
    var r = bounded.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .bound_ms = 120_000, .stdout_limit = 128 << 10, .stderr_limit = 32 << 10 });
    defer r.deinit(gpa);
    if (r.end == .unstarted) return if (deps.isSpawnMissing(r.err.?)) deps.hint(gpa, "python") else dupe(gpa, "patch_system patch runner failed");
    const applied = r.ok() and std.mem.trim(u8, r.stdout, " \r\n\t").len > 0;
    if (!applied) {
        if (verify) restorePatchTargets(ctx, root, snaps.items); // undo any partial application
        return std.fmt.allocPrint(gpa, "patch failed\nstdout:\n{s}\nstderr:\n{s}", .{ clip(r.stdout, 2500), clip(r.stderr, 1500) }) catch dupe(gpa, "patch failed");
    }

    if (verify) {
        // Verify every touched file that still exists (a Delete removed its target — nothing to parse).
        for (snaps.items) |s| {
            const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, s.rel }) catch continue;
            defer gpa.free(full);
            const now = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(4 << 20)) catch continue;
            defer gpa.free(now);
            if (patchVerifyError(ctx, s.rel, now, if (s.pre) |b| b else "")) |err| {
                defer gpa.free(err);
                restorePatchTargets(ctx, root, snaps.items);
                return std.fmt.allocPrint(gpa, "self-mod REVERTED: {s} would not parse after the patch ({s}). Every file the patch touched was restored to its previous state.", .{ s.rel, clip(err, 220) }) catch dupe(gpa, "self-mod reverted (would not parse)");
            }
        }
        // Journal the whole patch as one entry so the governor can roll all its files back together.
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer paths.deinit(gpa);
        var pres: std.ArrayListUnmanaged(?[]const u8) = .empty;
        defer pres.deinit(gpa);
        for (snaps.items) |s| {
            paths.append(gpa, s.rel) catch {};
            pres.append(gpa, if (s.pre) |b| b else null) catch {};
        }
        journalPatch(ctx, "patch", paths.items, pres.items, crit, high_impact);
    }
    return dupe(gpa, clip(std.mem.trim(u8, r.stdout, " \r\n\t"), 5000));
}

/// SSRF guard: only http(s), and reject obvious local/internal targets (loopback, link-local cloud metadata,
/// RFC-1918 private ranges, *.local). A mind running model-chosen URLs must not be able to reach the host's
/// own services or the cloud metadata endpoint (169.254.169.254). Best-effort host-substring check.
fn urlAllowed(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return false;
    const after = if (std.mem.startsWith(u8, url, "https://")) url[8..] else url[7..];
    var host = after;
    if (std.mem.indexOfAny(u8, host, "/?#")) |i| host = host[0..i];
    if (std.mem.indexOfScalar(u8, host, '@')) |i| host = host[i + 1 ..];
    // A bracketed IPv6 literal is REJECTED outright: loopback (::1), link-local (fe80::/10), unique-local
    // (fc00::/7), and v4-mapped (::ffff:127.0.0.1) forms can't be reliably told apart by substring — and a
    // research fetch never needs a bare v6 literal (public sites have names). Fail closed, not through.
    if (host.len > 0 and host[0] == '[') return false;
    if (std.mem.indexOfScalar(u8, host, ':')) |i| host = host[0..i];
    const blocked = [_][]const u8{ "localhost", "127.", "0.0.0.0", "169.254.", "10.", "192.168.", "::1", "metadata" };
    for (blocked) |b| if (std.mem.startsWith(u8, host, b)) return false;
    if (std.mem.endsWith(u8, host, ".local")) return false;
    if (std.mem.startsWith(u8, host, "172.")) {
        const rest = host[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        const second = std.fmt.parseInt(u16, rest[0..dot], 10) catch 0;
        if (second >= 16 and second <= 31) return false;
    }
    // A dotted-quad prefix check misses every OTHER spelling of the same address. curl and urllib both
    // accept an integer host and octal octets, so http://2130706433/, http://0177.0.0.1/ and http://0/
    // all reach 127.0.0.1 while matching none of the strings above. Normalize any all-numeric host to
    // its 32-bit value and re-check the private ranges on the number, not on the text.
    if (numericHostV4(host)) |ip| {
        const a: u8 = @truncate(ip >> 24);
        const b: u8 = @truncate(ip >> 16);
        if (a == 127 or a == 0 or a == 10) return false; // loopback, "this network", RFC1918 /8
        if (a == 169 and b == 254) return false; // link-local, incl. cloud metadata
        if (a == 192 and b == 168) return false; // RFC1918 /16
        if (a == 172 and b >= 16 and b <= 31) return false; // RFC1918 /12
    }
    return host.len > 0;
}

/// A host written entirely as numbers -> its IPv4 value, else null. Accepts the forms an HTTP client will
/// actually dial: dotted quad, bare integer, and octal/hex octets (a leading 0 means octal, 0x means hex).
/// Deliberately permissive about WHAT it parses — anything it can read as a number, the SSRF guard should
/// then judge as a number.
fn numericHostV4(host: []const u8) ?u32 {
    if (host.len == 0) return null;
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |p| {
        if (n == 4 or p.len == 0) return null;
        parts[n] = p;
        n += 1;
    }
    var vals: [4]u32 = .{ 0, 0, 0, 0 };
    for (parts[0..n], 0..) |p, i| {
        const radix: u8 = if (p.len > 2 and p[0] == '0' and (p[1] == 'x' or p[1] == 'X'))
            16
        else if (p.len > 1 and p[0] == '0')
            8
        else
            10;
        const digits = if (radix == 16) p[2..] else p;
        vals[i] = std.fmt.parseInt(u32, digits, radix) catch return null;
    }
    // 1 part = the whole address; 2/3 parts spread the last value over the remaining octets (inet_aton).
    return switch (n) {
        1 => vals[0],
        2 => if (vals[0] > 255 or vals[1] > 0xFFFFFF) null else (vals[0] << 24) | vals[1],
        3 => if (vals[0] > 255 or vals[1] > 255 or vals[2] > 0xFFFF) null else (vals[0] << 24) | (vals[1] << 16) | vals[2],
        4 => if (vals[0] > 255 or vals[1] > 255 or vals[2] > 255 or vals[3] > 255) null else (vals[0] << 24) | (vals[1] << 16) | (vals[2] << 8) | vals[3],
        else => null,
    };
}

/// Extract the bare host from an http(s) URL (no scheme, no userinfo, no port, no path). "" on a non-URL.
fn urlHost(url: []const u8) []const u8 {
    var host: []const u8 = if (std.mem.startsWith(u8, url, "https://")) url[8..] else if (std.mem.startsWith(u8, url, "http://")) url[7..] else return "";
    if (std.mem.indexOfAny(u8, host, "/?#")) |i| host = host[0..i];
    if (std.mem.indexOfScalar(u8, host, '@')) |i| host = host[i + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':')) |i| host = host[0..i];
    return host;
}

/// Optional host-suffix egress allowlist atop urlAllowed's SSRF block. `allow` = comma-separated host suffixes;
/// EMPTY = fail-open (no extra restriction). When set, the host must equal a suffix or be a dot-boundary
/// subdomain of one (bare substring is not enough — "a.org.evil.com" is blocked by "a.org").
pub fn egressAllowed(allow: []const u8, url: []const u8) bool {
    const a = std.mem.trim(u8, allow, " \t\r\n");
    if (a.len == 0) return true;
    const host = urlHost(url);
    if (host.len == 0) return false;
    var it = std.mem.splitScalar(u8, a, ',');
    while (it.next()) |raw| {
        const suf = std.mem.trim(u8, raw, " \t\r\n");
        if (suf.len == 0) continue;
        if (std.mem.eql(u8, host, suf)) return true;
        if (host.len > suf.len + 1 and host[host.len - suf.len - 1] == '.' and std.mem.endsWith(u8, host, suf)) return true;
    }
    return false;
}

test "urlAllowed SSRF guard: IPv6 literals fail closed; private v4 + metadata stay blocked" {
    try std.testing.expect(!urlAllowed("http://[::1]:8080/admin"));
    try std.testing.expect(!urlAllowed("http://[fe80::1]/x"));
    try std.testing.expect(!urlAllowed("http://[fd00::1]/x"));
    try std.testing.expect(!urlAllowed("https://user@[::ffff:127.0.0.1]/x"));
    try std.testing.expect(!urlAllowed("http://169.254.169.254/latest/meta-data/"));
    try std.testing.expect(!urlAllowed("http://172.16.0.1/x"));
    try std.testing.expect(urlAllowed("https://172.32.1.1/x")); // 172.32+ is public space
    try std.testing.expect(urlAllowed("https://example.com/x"));
    try std.testing.expect(!urlAllowed("ftp://example.com/x"));
}

test "sandboxAllowed: every host-reaching tool is refused, the whole hive surface is kept" {
    // The failure mode this guards is a NEW tool being added to a schema and silently defaulting to
    // allowed. Naming the dangerous ones explicitly means adding one to the dispatcher without a
    // tiering decision breaks a test rather than opening a hole quietly.
    const denied = [_][]const u8{
        "run_python",      "run_tests",        "patch_system",     "make_tool",         "propose_change",
        "simulate_change", "stage_delivery",   "osint_scan",       "host_status",       "host_command",
        "host_explore",    "browser_navigate", "browser_read",     "browser_click",     "browser_type",
        "browser_eval",    "browser_close",    "pixel_ingest",     "pixel_capture",     "mcp_discover",
        "mcp_call",        "get_credential",   "deep_crawl",       "stage_file",        "ask_veil",
        "browser_console", "browser_network",  "browser_click_at", "browser_type_text", "browser_key",
        "browser_scroll",  "run_shell",        "tool_env",
    };
    for (denied) |n| {
        if (sandboxAllowed(n)) {
            std.debug.print("sandboxAllowed({s}) should be false\n", .{n});
            return error.TestUnexpectedResult;
        }
    }

    // The hive mind is the product: a sandboxed user keeps ALL of it. If a future change tiers one of
    // these as admin-only, that is a product regression and this test is the place it should surface.
    const kept = [_][]const u8{
        "recall",       "recall_hive",   "read_doc",     "observe",       "share",
        "note_stance",  "save_skill",    "journal",      "set_directive", "probe",
        "add_task",     "complete_task", "send_message", "web_search",    "web_fetch",
        "read_file",    "write_file",    "edit_file",    "list_dir",      "delete_file",
        "pixel_search",
    };
    for (kept) |n| {
        if (!sandboxAllowed(n)) {
            std.debug.print("sandboxAllowed({s}) should be true — the hive/workspace surface stays open\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
}

test "the sandbox gate actually fires in execute, before any tool runs" {
    // The predicate tests above prove the LIST is right. This proves the DISPATCHER consults it: a
    // sandboxed ctx must refuse run_python without reaching runPython, and the same ctx at .full must
    // get past the gate. Everything here is inert — the refusal returns before any tool touches the
    // filesystem, a model, or a subprocess.
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = undefined, // never reached: the gate returns before any I/O
        .environ = &env,
        .run_dir = ".",
        .workdir = ".",
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined, // likewise untouched on the refusal path
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .caps = .sandboxed,
    };

    for ([_][]const u8{ "run_python", "run_shell", "tool_env", "host_command", "patch_system", "browser_eval", "get_credential" }) |name| {
        const out = execute(&ctx, name, "{}");
        defer gpa.free(out);
        if (std.mem.indexOf(u8, out, "not available in this workspace") == null) {
            std.debug.print("sandboxed execute({s}) did not refuse — got: {s}\n", .{ name, out });
            return error.TestUnexpectedResult;
        }
    }
    // No .full control here on purpose: anything that gets PAST the gate dereferences the undefined
    // io/mem above and segfaults the runner. That the gate is what refused is established by the
    // allowlist tests either side of this one; this test's job is only to prove execute() consults it.
}

test "a GRANT can never smuggle a built-in name past the sandbox gate" {
    // THE REGRESSION. The gate reads `caps == .sandboxed and !sandboxAllowed(name) and grantedRecipe(...)
    // == null`, so a grant makes the refusal condition false — it does NOT confine the caller to the
    // recipe branch. Dispatch is linear and the recipe branch sits ~340 lines below the built-in chain,
    // so a granted recipe NAMED after a built-in ran the BUILT-IN with the caller's own arguments. A
    // recipe called "get_credential" therefore returned stored secrets to a sandboxed user, which is
    // exactly the tool engine.zig asserts is stripped from their schema. isBuiltinTool now claims every
    // dispatched name so recipes.loadDir refuses these at load; this proves the gate holds even if one
    // slips into ctx.grants some other way.
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var first: ?[]u8 = null;
    defer if (first) |f| gpa.free(f);

    for ([_][]const u8{ "get_credential", "host_command", "host_explore", "ask_veil", "run_python", "run_shell", "mcp_call" }) |name| {
        const rec = recipes.Recipe{
            .name = name,
            .description = "innocuous-looking helper",
            .owner_uid = 1,
            .params = &.{},
            .steps = &.{},
            .output = "",
        };
        const grants = [_]*const recipes.Recipe{&rec};
        var ctx = ToolCtx{
            .gpa = gpa,
            .io = undefined, // never reached: the gate returns before any I/O
            .environ = &env,
            .run_dir = ".",
            .workdir = ".",
            .scope = "test",
            .mind = "test",
            .round = 0,
            .mem = undefined,
            .files_written = &counters[0],
            .observed = &counters[1],
            .skills_saved = &counters[2],
            .directives_set = &counters[3],
            .tools_made = &counters[4],
            .caps = .sandboxed,
            .grants = &grants,
        };
        const out = execute(&ctx, name, "{}");
        defer gpa.free(out);
        // The recipe carries NO steps, so runRecipe's answer cannot depend on the name. If a built-in had
        // claimed the name instead, the reply would be that tool's own, name-specific output. Pin the
        // first result and require every other name to match it byte for byte: identical answers prove
        // the NAME selected nothing, which is the property under test.
        if (first == null) {
            first = gpa.dupe(u8, out) catch return error.OutOfMemory;
        } else if (!std.mem.eql(u8, first.?, out)) {
            std.debug.print("GRANT SMUGGLED A BUILT-IN: sandboxed execute({s}) with a grant of that name behaved name-specifically — got: {s}\n", .{ name, out });
            return error.TestUnexpectedResult;
        }
        // Concrete anchor for the exploit that motivated this: getCredential's own reply must never appear.
        if (std.mem.indexOf(u8, out, "credential store") != null) {
            std.debug.print("GRANT SMUGGLED get_credential: the built-in ran for a sandboxed caller — got: {s}\n", .{out});
            return error.TestUnexpectedResult;
        }
    }
}

test "isBuiltinTool claims every name execute() can dispatch (reads the dispatcher's own source)" {
    // STRUCTURAL, so it cannot rot. isBuiltinTool is hand-maintained and it silently drifted six names
    // and three prefix families away from the dispatcher — which is what let a recipe be named after a
    // built-in. Rather than trusting a second hand-copied list, read execute()'s source and assert every
    // literal it routes on is claimed. The trio routing audit uses this same read-your-own-source trick.
    const src = @embedFile("tools.zig"); // this file, read as text — same trick trio_routing_test uses
    // ANCHOR ON executeInner, NOT on `pub fn execute`. The public entry is now a two-line wrapper (the
    // training-set capture split), and anchoring there would scan a body with no dispatch arms in it —
    // the loops below would find nothing and this audit would pass VACUOUSLY while the real dispatcher
    // drifted. executeInner IS the dispatcher; assert it exists so a future rename fails loudly here
    // instead of quietly disarming the check.
    const start = std.mem.indexOf(u8, src, "fn executeInner(ctx: *ToolCtx") orelse return error.TestUnexpectedResult;
    // the dispatcher ends where the next top-level decl begins — the first line-start "fn " after it.
    const end = std.mem.indexOfPos(u8, src, start + 40, "\nfn ") orelse src.len;
    const body = src[start..end];
    // and the body it found must actually BE the dispatcher: a handful of arms at minimum, or the
    // anchor moved and this test is auditing the wrong function.
    try std.testing.expect(std.mem.count(u8, body, "eql(u8, name, \"") > 10);

    // every `std.mem.eql(u8, name, "X")` — the exact-match dispatch arms
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "eql(u8, name, \"")) |at| {
        const from = at + "eql(u8, name, \"".len;
        const close = std.mem.indexOfScalarPos(u8, body, from, '"') orelse break;
        const nm = body[from..close];
        i = close;
        if (!isBuiltinTool(nm)) {
            std.debug.print("execute() dispatches \"{s}\" but isBuiltinTool does not claim it — a recipe or authored tool could take that name and the BUILT-IN would win\n", .{nm});
            return error.TestUnexpectedResult;
        }
    }
    // every `startsWith(u8, name, "X")` — the prefix families
    i = 0;
    while (std.mem.indexOfPos(u8, body, i, "startsWith(u8, name, \"")) |at| {
        const from = at + "startsWith(u8, name, \"".len;
        const close = std.mem.indexOfScalarPos(u8, body, from, '"') orelse break;
        const pre = body[from..close];
        i = close;
        // a suffix nobody has written yet must still be reserved
        const probe_name = std.fmt.allocPrint(std.testing.allocator, "{s}zzz_unclaimed", .{pre}) catch return error.OutOfMemory;
        defer std.testing.allocator.free(probe_name);
        if (!isBuiltinTool(probe_name)) {
            std.debug.print("execute() routes the \"{s}\" family by prefix but isBuiltinTool only claims exact verbs — \"{s}\" is takeable\n", .{ pre, probe_name });
            return error.TestUnexpectedResult;
        }
    }
}

test "sandboxAllowed is an allowlist: an unknown name is refused" {
    // execute()'s tail falls through to runAuthored for any unrecognised name, so make_tool could mint
    // a tool and call it by that new name. A denylist would never see it; this pins the polarity.
    try std.testing.expect(!sandboxAllowed("totally_made_up_tool"));
    try std.testing.expect(!sandboxAllowed(""));
    try std.testing.expect(!sandboxAllowed("run_python ")); // no trimming, no near-miss matching
    try std.testing.expect(!sandboxAllowed("RUN_PYTHON")); // case-sensitive by design
}

test "urlAllowed: numeric spellings of loopback and private space are blocked too" {
    // Same addresses as above, written the ways an HTTP client still dials but a dotted-quad prefix
    // check never matches. Each of these reached 127.0.0.1 before numericHostV4 existed.
    try std.testing.expect(!urlAllowed("http://2130706433/")); // 127.0.0.1 as one integer
    try std.testing.expect(!urlAllowed("http://0177.0.0.1/")); // octal first octet
    try std.testing.expect(!urlAllowed("http://0x7f.0.0.1/")); // hex first octet
    try std.testing.expect(!urlAllowed("http://0/")); // 0.0.0.0
    try std.testing.expect(!urlAllowed("http://127.1/")); // short form
    try std.testing.expect(!urlAllowed("http://3232235777/")); // 192.168.1.1
    try std.testing.expect(!urlAllowed("http://2886729729/")); // 172.16.0.1
    try std.testing.expect(!urlAllowed("http://user@2130706433/x")); // userinfo does not launder it
    // Public numeric hosts must still pass — the guard judges the value, not the notation.
    try std.testing.expect(urlAllowed("http://93.184.216.34/")); // example.com
    try std.testing.expect(urlAllowed("http://1.1.1.1/"));
}

test "numericHostV4 parses the dial-able notations and rejects names" {
    try std.testing.expectEqual(@as(?u32, 0x7F000001), numericHostV4("2130706433"));
    try std.testing.expectEqual(@as(?u32, 0x7F000001), numericHostV4("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0x7F000001), numericHostV4("127.1"));
    try std.testing.expectEqual(@as(?u32, 0x7F000001), numericHostV4("0177.0.0.1"));
    try std.testing.expect(numericHostV4("example.com") == null);
    try std.testing.expect(numericHostV4("127.0.0.256") == null); // octet out of range
    try std.testing.expect(numericHostV4("") == null);
}

test "looksLikeJsShell flags unrendered SPA pages so webFetch falls back to the reader" {
    // unrendered SPA placeholders a plain fetch returns instead of real content
    try std.testing.expect(looksLikeJsShell("Loading... Getting Started on Moltbook"));
    try std.testing.expect(looksLikeJsShell("<div id=\"__next\"></div>"));
    try std.testing.expect(looksLikeJsShell("You need to enable JavaScript to run this app."));
    try std.testing.expect(looksLikeJsShell("")); // empty
    try std.testing.expect(looksLikeJsShell("tiny")); // too short to be real content
    // real, substantive page text is NOT a shell
    const real = "Moltbook API: Complete Guide. Authenticate with a Bearer token. To claim an agent you verify via the claim link and confirm on X/Twitter; posts require a claimed agent." ++ (" More detail here." ** 3);
    try std.testing.expect(!looksLikeJsShell(real));
}

test "egressAllowed host-suffix allowlist" {
    // unset allowlist -> fail-open (no extra restriction)
    try std.testing.expect(egressAllowed("", "https://example.com/x"));
    try std.testing.expect(egressAllowed("   ", "https://anything.net"));
    // a set allowlist confines to the named host + its dot-boundary subdomains
    try std.testing.expect(egressAllowed("example.org", "https://example.org/a"));
    try std.testing.expect(egressAllowed("example.org", "https://docs.example.org/a"));
    try std.testing.expect(!egressAllowed("example.org", "https://example.com/a"));
    // the classic suffix-confusion bypass must be BLOCKED (substring, not dot-boundary)
    try std.testing.expect(!egressAllowed("example.org", "https://example.org.evil.com/a"));
    try std.testing.expect(!egressAllowed("attack.mitre.org", "https://notattack.mitre.org/a"));
    // multi-entry list
    try std.testing.expect(egressAllowed("attack.mitre.org, urlhaus.abuse.ch", "https://urlhaus.abuse.ch/feed"));
    try std.testing.expect(!egressAllowed("attack.mitre.org, urlhaus.abuse.ch", "https://evil.test/feed"));
    // non-URL / scheme-less -> blocked under an active allowlist
    try std.testing.expect(!egressAllowed("example.org", "ftp://example.org"));
}

/// Strip HTML to readable text in pure Zig (no extra process): drop &lt;script&gt;/&lt;style&gt; bodies and all tags,
/// unescape the common entities, and collapse whitespace. Good enough for "read this page" research.
fn htmlToText(gpa: std.mem.Allocator, html: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var last_space = true;
    while (i < html.len) {
        if (html[i] == '<') {
            const lower_ok = i + 1 < html.len;
            if (lower_ok and (matchTag(html[i..], "<script") or matchTag(html[i..], "<style"))) {
                const close = if (matchTag(html[i..], "<script")) "</script" else "</style";
                if (std.mem.indexOfPos(u8, html, i, close)) |c| {
                    i = c;
                }
            }
            if (std.mem.indexOfScalarPos(u8, html, i, '>')) |gt| {
                i = gt + 1;
                if (!last_space) {
                    out.append(gpa, ' ') catch break;
                    last_space = true;
                }
                continue;
            } else break;
        }
        const c = html[i];
        if (c == '&') {
            if (decodeEntity(html[i..])) |de| {
                out.append(gpa, de.ch) catch break;
                last_space = false;
                i += de.len;
                continue;
            }
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!last_space) {
                out.append(gpa, ' ') catch break;
                last_space = true;
            }
        } else {
            out.append(gpa, c) catch break;
            last_space = false;
        }
        i += 1;
    }
    return out.toOwnedSlice(gpa) catch dupe(gpa, "");
}

fn matchTag(s: []const u8, tag: []const u8) bool {
    if (s.len < tag.len) return false;
    for (tag, 0..) |t, k| {
        const a = s[k] | 0x20;
        if (a != t) return false;
    }
    return true;
}

const Entity = struct { ch: u8, len: usize };
fn decodeEntity(s: []const u8) ?Entity {
    const pairs = [_]struct { k: []const u8, v: u8 }{
        .{ .k = "&amp;", .v = '&' },  .{ .k = "&lt;", .v = '<' },   .{ .k = "&gt;", .v = '>' },
        .{ .k = "&quot;", .v = '"' }, .{ .k = "&#39;", .v = '\'' }, .{ .k = "&apos;", .v = '\'' },
        .{ .k = "&nbsp;", .v = ' ' },
    };
    for (pairs) |pr| if (std.mem.startsWith(u8, s, pr.k)) return .{ .ch = pr.v, .len = pr.k.len };
    return null;
}

/// Should the fetch ESCALATE to the impersonating client? True when the body carries an anti-bot/paywall
/// marker (reuses the existing looksBlocked signal set — Cloudflare "Just a moment", captcha, 403, …) OR is
/// a near-empty stub (a block/redirect page that returned almost nothing). A false positive costs one extra
/// curl_cffi attempt; a false negative just keeps the plain-curl body. Cheap substring/length checks only.
fn botGated(body: []const u8) bool {
    return body.len < 240 or looksBlocked(body);
}

/// Fetch a URL through curl_cffi (Python), impersonating a real Chrome TLS/JA3/HTTP2 fingerprint — the
/// undetectable path that clears Cloudflare/Imperva/Datadome gates a plain curl cannot. HTTP-only (no JS):
/// the belt for APIs, static pages, and bot-gated content; JS-rendered pages still want the browser driver.
/// Writes the body to `tmp`, reads it back. Returns "" when python or curl_cffi is absent — this is a
/// FALLBACK, so absence is silent (the caller keeps whatever the plain curl got), not a dep hint.
fn curlCffiTo(io: std.Io, gpa: std.mem.Allocator, tmp: []const u8, url: []const u8, deadline_ms: u32, limit: usize) []u8 {
    const py = if (builtin.os.tag == .windows) "python" else "python3";
    // argv-passed url + outpath + timeout — no shell, no escaping hazard. r.content is raw bytes (HTML/JSON).
    const snippet =
        \\import sys
        \\try:
        \\    from curl_cffi import requests
        \\    r = requests.get(sys.argv[1], impersonate="chrome124", timeout=int(sys.argv[3]), allow_redirects=True)
        \\    open(sys.argv[2], "wb").write(r.content)
        \\except Exception:
        \\    pass
    ;
    var tb: [8]u8 = undefined;
    const ts = std.fmt.bufPrint(&tb, "{d}", .{@min(deadline_ms / 1000, 30)}) catch "20";
    // clear any stale tmp so a failed run reads back as "" rather than the previous body
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    _ = spawnGuarded(io, &.{ py, "-c", snippet, url, tmp, ts }, deadline_ms);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, tmp, gpa, .limited(limit)) catch (gpa.dupe(u8, "") catch @constCast(""));
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    return raw;
}

/// curl a page with a BROWSER user-agent. The bot UA in curlToText is what makes sites block a plain curl; a
/// browser UA makes a direct fetch work on most sites (and is what SERPs need). Primitive (no ToolCtx):
/// browser-UA curl into `tmp`, guarded, read back. Lets non-tool callers (the engine's retrieval seed) reuse
/// the exact same fetch. Caller frees the returned body.
///
/// curl_cffi ESCALATION: a plain curl still loses the TLS-fingerprint arms race against Cloudflare/Datadome.
/// `.escalate` (the default) runs plain curl first and only retries through the impersonating client when the
/// body looks gated (botGated) — the common case pays nothing, the hard case gets the stronger client.
/// `.primary` tries curl_cffi FIRST (plain curl the fallback); `.off` disables it. Both paths degrade to each
/// other, and to the dep hint only if BOTH clients are unavailable. The knob is NL_CURL_CFFI (read by the
/// ctx-carrying wrapper `curlBrowser`); ctx-less callers pass `.escalate`.
const CffiMode = enum { escalate, primary, off };
fn curlBrowserTo(io: std.Io, gpa: std.mem.Allocator, tmp: []const u8, url: []const u8, deadline_ms: u32, limit: usize) []u8 {
    return curlBrowserMode(io, gpa, tmp, url, deadline_ms, limit, .escalate);
}
fn curlBrowserMode(io: std.Io, gpa: std.mem.Allocator, tmp: []const u8, url: []const u8, deadline_ms: u32, limit: usize, mode: CffiMode) []u8 {
    if (mode == .primary) {
        const imp = curlCffiTo(io, gpa, tmp, url, deadline_ms, limit);
        if (imp.len > 0 and !botGated(imp)) return imp;
        gpa.free(imp); // impersonation unavailable or still gated — fall through to plain curl
    }

    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sSL", "--max-time", "20", "--connect-timeout", "10", "-o", tmp, "-A", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36", "-H", "Accept-Language: en-US,en;q=0.9", url }) catch return dupe(gpa, "");
    // Missing curl → the dep hint, not a silent empty page.
    if (spawnGuarded(io, av.items, deadline_ms)) |e| {
        if (deps.isSpawnMissing(e)) return deps.hint(gpa, "curl");
    }
    const raw = std.Io.Dir.cwd().readFileAlloc(io, tmp, gpa, .limited(limit)) catch (gpa.dupe(u8, "") catch @constCast(""));
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    // ESCALATE: plain curl came back gated (Cloudflare/Datadome/near-empty) — retry once through the
    // impersonating client, which clears most such gates. Keep whichever body is real and un-gated.
    if (mode == .escalate and botGated(raw)) {
        const imp = curlCffiTo(io, gpa, tmp, url, deadline_ms, limit);
        if (imp.len > 0 and !botGated(imp)) {
            gpa.free(raw);
            return imp;
        }
        gpa.free(imp);
    }
    return raw;
}

/// Map NL_CURL_CFFI to a mode: "0"/"off" → off; "1"/"always"/"primary" → primary; anything else → escalate.
fn cffiMode(ctx: *ToolCtx) CffiMode {
    const v = ctx.environ.get("NL_CURL_CFFI") orelse return .escalate;
    if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off")) return .off;
    if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "always") or std.ascii.eqlIgnoreCase(v, "primary")) return .primary;
    return .escalate;
}

fn curlBrowser(ctx: *ToolCtx, url: []const u8, deadline_ms: u32, limit: usize) []u8 {
    const gpa = ctx.gpa;
    const tmp = std.fmt.allocPrint(gpa, "{s}/.crawl-{s}.tmp", .{ ctx.run_dir, ctx.mind }) catch return dupe(gpa, "");
    defer gpa.free(tmp);
    return curlBrowserMode(ctx.io, gpa, tmp, url, deadline_ms, limit, cffiMode(ctx));
}

/// fetch a URL (browser UA) and run it through the crawl4ai-port cleaner -> clean LLM-ready markdown. "" on thin output.
fn crawlPage(ctx: *ToolCtx, url: []const u8, max: usize) []u8 {
    const gpa = ctx.gpa;
    const raw = curlBrowser(ctx, url, 22000, 1 << 20);
    defer gpa.free(raw);
    if (raw.len < 200) return dupe(gpa, "");
    const r = crawl.extract(gpa, raw, url);
    defer gpa.free(@constCast(r.title));
    defer gpa.free(@constCast(r.markdown));
    if (r.markdown.len < 160) return dupe(gpa, "");
    return dupe(gpa, clip(r.markdown, max));
}

/// crawlPage + crawl4ai BM25ContentFilter: with a non-empty `query`, fit the extracted page to it (return only the
/// most query-relevant chunks) so a weak model reads a page already narrowed to its topic; empty query returns the
/// clipped head. One fetch. gpa-owned (the fit branch is gpa-mutable, so @constCast is sound). "" on thin output.
fn crawlPageFit(ctx: *ToolCtx, url: []const u8, query: []const u8, max: usize) []u8 {
    const gpa = ctx.gpa;
    const raw = curlBrowser(ctx, url, 22000, 1 << 20);
    defer gpa.free(raw);
    if (raw.len < 200) return dupe(gpa, "");
    const r = crawl.extract(gpa, raw, url);
    defer gpa.free(@constCast(r.title));
    defer gpa.free(@constCast(r.markdown));
    if (r.markdown.len < 160) return dupe(gpa, "");
    if (std.mem.trim(u8, query, " \t\r\n").len > 0) return @constCast(crawl.fitToQuery(gpa, r.markdown, query, max));
    return dupe(gpa, clip(r.markdown, max));
}

fn queryEncode(gpa: std.mem.Allocator, q: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (q) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') out.append(gpa, c) catch {} else if (c == ' ') out.append(gpa, '+') catch {} else {
            var pb: [3]u8 = undefined;
            out.appendSlice(gpa, std.fmt.bufPrint(&pb, "%{X:0>2}", .{c}) catch "") catch {};
        }
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, q) catch @constCast(""));
}

/// CRAWL-AS-SEARCH: our crawler fetches an HTML SERP with a browser UA and decodes the result links itself — no
/// jina, no firecrawl, no key. DuckDuckGo's no-JS html endpoint is the PRIMARY target: it returns static result
/// links (uddg= redirects we decode) and reaches good sources (arxiv/nature/springer for AI queries) where Bing
/// now serves a consent-gated JS shell with zero harvestable results. Bing stays as a secondary in case DDG
/// rate-limits. Both put the query last in the URL, so a single prefix+enc concat builds each (allocPrint needs a
/// comptime fmt string, which a runtime engine list can't provide).
/// SELF-HEALING (no ToolCtx) so the engine's retrieval seed can reuse it. `dir`+`tag` key the per-caller temp
/// file. No single keyless engine is reliable everywhere — a residential IP gets clean results from DuckDuckGo
/// while a datacenter/container IP is bounced to its homepage; Bing serves a JS consent-shell; Mojeek captchas.
/// So we ROTATE a list of keyless HTML engines and use whichever returns real results THIS time, harvested +
/// decoded by OUR crawler. A per-engine COOLDOWN persisted to disk skips an engine that just bounced/captcha'd,
/// so the rotation routes around a down engine and recovers it when the cooldown lapses.
pub fn crawlSearchPrim(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, tag: []const u8, query: []const u8, max: usize) []const u8 {
    const enc = queryEncode(gpa, query);
    defer gpa.free(enc);
    const tmp = std.fmt.allocPrint(gpa, "{s}/.csearch-{s}.tmp", .{ dir, tag }) catch return dupe(gpa, "");
    defer gpa.free(tmp);
    const Engine = struct { prefix: []const u8, base: []const u8 };
    const engines = [_]Engine{
        .{ .prefix = "https://html.duckduckgo.com/html/?q=", .base = "https://html.duckduckgo.com" },
        .{ .prefix = "https://www.mojeek.com/search?q=", .base = "https://www.mojeek.com" },
        .{ .prefix = "https://www.startpage.com/sp/search?query=", .base = "https://www.startpage.com" },
        .{ .prefix = "https://www.bing.com/search?q=", .base = "https://www.bing.com" },
        .{ .prefix = "https://old-search.marginalia.nu/search?query=", .base = "https://old-search.marginalia.nu" },
    };
    const N = engines.len;

    const hpath = std.fmt.allocPrint(gpa, "{s}/.crawl_search_health", .{dir}) catch return dupe(gpa, "");
    defer gpa.free(hpath);
    var cd = [_]i64{0} ** N;
    if (std.Io.Dir.cwd().readFileAlloc(io, hpath, gpa, .limited(4096))) |hb| {
        defer gpa.free(hb);
        var it = std.mem.splitScalar(u8, hb, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) {
            if (i >= N) break;
            cd[i] = std.fmt.parseInt(i64, std.mem.trim(u8, ln, " \r\t"), 10) catch 0;
        }
    } else |_| {}
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    var any_live = false;
    for (cd) |c| {
        if (c <= now) any_live = true;
    }

    var result: []const u8 = dupe(gpa, "");
    var got = false;
    for (engines, 0..) |e, i| {
        if (any_live and cd[i] > now) continue;
        const url = std.mem.concat(gpa, u8, &.{ e.prefix, enc }) catch continue;
        defer gpa.free(url);
        const raw = curlBrowserTo(io, gpa, tmp, url, 20000, 1 << 20);
        defer gpa.free(raw);
        if (raw.len < 400) {
            cd[i] = now + 900;
            continue;
        }
        const res = crawl.searchResults(gpa, raw, e.base, max);
        if (std.mem.count(u8, res, "\n  http") >= 2) {
            cd[i] = 0;
            gpa.free(result);
            result = res;
            got = true;
            break;
        }
        cd[i] = now + 1800;
        gpa.free(res);
    }

    var hb: std.ArrayListUnmanaged(u8) = .empty;
    defer hb.deinit(gpa);
    for (cd) |c| {
        var nb: [24]u8 = undefined;
        hb.appendSlice(gpa, std.fmt.bufPrint(&nb, "{d}\n", .{c}) catch "") catch {};
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hpath, .data = hb.items }) catch {};

    if (!got) {
        gpa.free(result);
        return dupe(gpa, "");
    }
    return result;
}

/// Panic-proof intel search: curl the engines in a SUBPROCESS (a parser crash there can't take down the worker)
/// + strip with the simple htmlToText, NOT the crawl.* parsers that can integer-overflow on odd pages.
pub fn fetchSearchText(io: std.Io, gpa: std.mem.Allocator, run_dir: []const u8, query: []const u8) []const u8 {
    const enc = queryEncode(gpa, query);
    defer gpa.free(enc);
    const tmp = std.fmt.allocPrint(gpa, "{s}/.intelsearch.tmp", .{run_dir}) catch return dupe(gpa, "");
    defer gpa.free(tmp);
    // Try several engines so one rate-limiting us can't blind the learn loop; return the first with content.
    const bases = [_][]const u8{
        "https://www.bing.com/search?q=",
        "https://www.mojeek.com/search?q=",
        "https://html.duckduckgo.com/html/?q=",
    };
    for (bases) |base| {
        const url = std.fmt.allocPrint(gpa, "{s}{s}", .{ base, enc }) catch continue;
        defer gpa.free(url);
        var av: std.ArrayListUnmanaged([]const u8) = .empty;
        defer av.deinit(gpa);
        av.appendSlice(gpa, &.{ "curl", "-sSL", "--max-time", "12", "--connect-timeout", "6", "-o", tmp, "-A", "Mozilla/5.0 (X11; Linux x86_64)" }) catch continue;
        av.append(gpa, url) catch continue;
        // curl missing → every engine below would fail identically; surface the dep hint once rather than
        // looping to a silent "". A curl that ran but got blocked falls through to the next engine.
        if (spawnGuarded(io, av.items, 14000)) |e| {
            if (deps.isSpawnMissing(e)) return deps.hint(gpa, "curl");
        }
        const raw = std.Io.Dir.cwd().readFileAlloc(io, tmp, gpa, .limited(512 << 10)) catch (gpa.dupe(u8, "") catch @constCast(""));
        defer gpa.free(raw);
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        if (raw.len < 800) continue;
        const text = htmlToText(gpa, raw);
        defer gpa.free(text);
        const clipped = clip(text, 1400);
        if (std.mem.trim(u8, clipped, " \r\n\t").len > 80) return dupe(gpa, clipped);
    }
    return dupe(gpa, "");
}

fn crawlSearch(ctx: *ToolCtx, query: []const u8, max: usize) []const u8 {
    return crawlSearchPrim(ctx.io, ctx.gpa, ctx.run_dir, ctx.mind, query, max);
}

/// POST form fields to a URL via curl --data-urlencode (curl encodes). Returns the response body (caller frees).
fn curlForm(io: std.Io, gpa: std.mem.Allocator, url: []const u8, fields: []const [2][]const u8) []u8 {
    const empty = dupe(gpa, "");
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    var kvs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (kvs.items) |s| gpa.free(s);
        kvs.deinit(gpa);
    }
    av.appendSlice(gpa, &.{ "curl", "-sS", "--max-time", "25", "-A", "neuron-loops-hive/1.0" }) catch return empty;
    for (fields) |f| {
        const kv = std.fmt.allocPrint(gpa, "{s}={s}", .{ f[0], f[1] }) catch continue;
        kvs.append(gpa, kv) catch {
            gpa.free(kv);
            continue;
        };
        av.append(gpa, "--data-urlencode") catch {};
        av.append(gpa, kv) catch {};
    }
    av.append(gpa, url) catch {};
    // bounded.run, past curl's own 25 s: a reply past 256 KB can hang std.process.run on Windows (see bounded.zig)
    var proc = bounded.run(gpa, io, .{ .argv = av.items, .bound_ms = 40_000, .stdout_limit = 256 << 10, .stderr_limit = 4096, .stderr_tail = true });
    defer proc.deinit(gpa);
    // missing curl → the actionable hint; any other spawn/IO failure keeps the silent empty body.
    if (proc.end == .unstarted and deps.isSpawnMissing(proc.err.?)) {
        gpa.free(empty);
        return deps.hint(gpa, "curl");
    }
    if (!proc.ok()) return empty;
    gpa.free(empty);
    const body = proc.stdout;
    proc.stdout = &.{};
    return body;
}

/// Convert a plain-text body into a Telegraph content node array (a JSON string): each non-blank line -> a
/// {"tag":"p","children":["<text>"]} node. Caller frees.
fn tgContent(gpa: std.mem.Allocator, body: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(gpa, '[') catch return dupe(gpa, "[]");
    var first = true;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const para = std.mem.trim(u8, raw, " \r\t");
        if (para.len == 0) continue;
        if (!first) out.append(gpa, ',') catch {};
        first = false;
        out.appendSlice(gpa, "{\"tag\":\"p\",\"children\":[") catch {};
        llm.jstr(gpa, &out, para) catch {};
        out.appendSlice(gpa, "]}") catch {};
    }
    if (first) out.appendSlice(gpa, "{\"tag\":\"p\",\"children\":[\" \"]}") catch {};
    out.append(gpa, ']') catch {};
    return out.toOwnedSlice(gpa) catch dupe(gpa, "[]");
}

/// Publish a public page to the keyless Telegraph API. `tg_token` is the caller's per-run token cache (minted on first
/// use via createAccount, reused after). Returns the public URL (gpa-owned) or "" on failure. Primitive (io/gpa) so no
/// module needs a Worker. This is a capability — the safety SCREEN that decides WHETHER to publish stays with the caller.
pub fn telegraphPublish(io: std.Io, gpa: std.mem.Allocator, tg_token: *[]const u8, title: []const u8, body: []const u8) []const u8 {
    if (tg_token.*.len == 0) {
        const acc = curlForm(io, gpa, "https://api.telegra.ph/createAccount", &.{ .{ "short_name", "the-hive" }, .{ "author_name", "The Hive" } });
        defer gpa.free(acc);
        const Acc = struct { ok: bool = false, result: struct { access_token: []const u8 = "" } = .{} };
        if (std.json.parseFromSlice(Acc, gpa, jsonChunk(acc), .{ .ignore_unknown_fields = true })) |ap| {
            defer ap.deinit();
            if (ap.value.result.access_token.len > 0) tg_token.* = gpa.dupe(u8, ap.value.result.access_token) catch "";
        } else |_| {}
    }
    if (tg_token.*.len == 0) return dupe(gpa, "");
    const content = tgContent(gpa, body);
    defer gpa.free(content);
    const page = curlForm(io, gpa, "https://api.telegra.ph/createPage", &.{ .{ "access_token", tg_token.* }, .{ "title", clip(title, 200) }, .{ "author_name", "The Hive" }, .{ "content", content } });
    defer gpa.free(page);
    const Page = struct { ok: bool = false, result: struct { url: []const u8 = "" } = .{} };
    if (std.json.parseFromSlice(Page, gpa, jsonChunk(page), .{ .ignore_unknown_fields = true })) |pp| {
        defer pp.deinit();
        if (pp.value.result.url.len > 0) return dupe(gpa, pp.value.result.url);
    } else |_| {}
    return dupe(gpa, "");
}

/// Slice from the first '{' to the last '}' — tolerates curl/HTTP noise around a JSON body.
fn jsonChunk(s: []const u8) []const u8 {
    const a = std.mem.indexOfScalar(u8, s, '{') orelse return s;
    const b = std.mem.lastIndexOfScalar(u8, s, '}') orelse return s;
    return if (b >= a) s[a .. b + 1] else s;
}

/// A plain fetch of a client-rendered SPA (React/Next/etc.) comes back as an empty shell — a "Loading…" /
/// "enable JavaScript" placeholder plus cookie/ToS boilerplate — with none of the real content. Detect that so
/// webFetch can retry through the JS-rendering reader instead of handing the model an unreadable page it then
/// loops re-fetching.
fn looksLikeJsShell(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \r\n\t");
    if (t.len < 64) return true; // too little to be real page content
    const markers = [_][]const u8{ "enable JavaScript", "enable Javascript", "You need to enable", "Loading...", "Loading…", "__NEXT_DATA__", "id=\"__next\"", "id=\"app-root\"", "id=\"root\"></div>" };
    for (markers) |m| if (std.mem.indexOf(u8, t, m) != null) return true;
    return false;
}

/// Fetch a URL through the JS-rendering reader proxy (the same path read_url uses — default keyless Jina, which
/// renders client-side content). gpa-owned; "" on empty/timeout.
fn readerRender(ctx: *ToolCtx, url: []const u8) []u8 {
    const gpa = ctx.gpa;
    const base = if (ctx.environ.get("NL_READER_URL")) |b| (if (b.len > 0) b else "https://r.jina.ai/") else "https://r.jina.ai/";
    const full = std.fmt.allocPrint(gpa, "{s}{s}", .{ base, url }) catch return dupe(gpa, "");
    defer gpa.free(full);
    const raw = curlToText(ctx, full, false, 31000, 1 << 20);
    defer gpa.free(raw);
    const t = std.mem.trim(u8, raw, " \r\n\t");
    return if (t.len == 0) dupe(gpa, "") else dupe(gpa, clip(t, 1800));
}

fn webFetch(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { url: []const u8 = "", query: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!urlAllowed(p.value.url)) return dupe(gpa, "blocked url (only public http/https; no local/internal hosts)");
    if (!egressAllowed(ctx.egress_allow, p.value.url)) return dupe(gpa, "blocked: host not on the egress allowlist (NL_EGRESS_ALLOWLIST)");
    if (ctx.egress_allow.len == 0) {
        const cm = crawlPageFit(ctx, p.value.url, p.value.query, 1800);
        if (cm.len > 0 and !looksLikeJsShell(cm)) return cm; // a shell here still falls through to curl + reader
        gpa.free(cm);
    }
    const raw = curlToText(ctx, p.value.url, false, 26000, 512 << 10);
    defer gpa.free(raw);
    const text = htmlToText(gpa, raw);
    defer gpa.free(text);
    const body = if (text.len > 80) text else raw;
    // JS-SHELL FALLBACK: an unrendered SPA is useless to the model and it loops re-fetching. Retry ONCE through
    // the JS-rendering reader (only without an egress allowlist — the reader is a third-party proxy).
    if (ctx.egress_allow.len == 0 and looksLikeJsShell(body)) {
        const rendered = readerRender(ctx, p.value.url);
        if (rendered.len > 0 and !looksLikeJsShell(rendered)) return rendered;
        gpa.free(rendered);
    }
    if (std.mem.trim(u8, body, " \r\n\t").len == 0) return dupe(gpa, "(fetch returned nothing or timed out — try another source)");
    return dupe(gpa, clip(body, 1800));
}

fn proposeChange(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct {
        title: []const u8 = "",
        hypothesis: []const u8 = "",
        change: []const u8 = "",
        metric: []const u8 = "",
        risk: []const u8 = "",
        rollback: []const u8 = "",
    };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();

    const title = std.mem.trim(u8, p.value.title, " \r\n\t");
    const hypothesis = std.mem.trim(u8, p.value.hypothesis, " \r\n\t");
    const change = std.mem.trim(u8, p.value.change, " \r\n\t");
    const metric = std.mem.trim(u8, p.value.metric, " \r\n\t");
    const risk = std.mem.trim(u8, p.value.risk, " \r\n\t");
    const rollback = std.mem.trim(u8, p.value.rollback, " \r\n\t");

    if (title.len < 4 or hypothesis.len < 8 or change.len < 8 or metric.len < 4 or rollback.len < 6)
        return dupe(gpa, "proposal too thin — provide title/hypothesis/change/metric/rollback with concrete detail");
    if (!(std.mem.eql(u8, risk, "low") or std.mem.eql(u8, risk, "medium") or std.mem.eql(u8, risk, "high")))
        return dupe(gpa, "risk must be one of: low, medium, high");

    const t = oneLine(gpa, title);
    defer gpa.free(t);
    const h = oneLine(gpa, hypothesis);
    defer gpa.free(h);
    const c = oneLine(gpa, change);
    defer gpa.free(c);
    const m = oneLine(gpa, metric);
    defer gpa.free(m);
    const rb = oneLine(gpa, rollback);
    defer gpa.free(rb);

    const rec = std.fmt.allocPrint(gpa, "round={d} mind={s} title={s} | hypothesis={s} | change={s} | metric={s} | risk={s} | rollback={s}", .{ ctx.round, ctx.mind, t, h, c, m, risk, rb }) catch return dupe(gpa, "oom");
    defer gpa.free(rec);
    _ = ctx.mem.observe(PROPOSAL_SCOPE, rec);
    const al = std.fmt.allocPrint(gpa, "proposal-submitted r{d} by {s}: {s}", .{ ctx.round, ctx.mind, t }) catch return dupe(gpa, "oom");
    defer gpa.free(al);
    _ = ctx.mem.observe(AUTONOMY_SCOPE, al);

    const total = ctx.mem.factCount(PROPOSAL_SCOPE);
    return std.fmt.allocPrint(gpa, "proposal recorded ({d} total proposals in RSI ledger)", .{total}) catch dupe(gpa, "proposal recorded");
}

fn simulateChange(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct {
        proposal: []const u8 = "",
        expected: []const u8 = "",
        failures: []const u8 = "",
        side_effects: []const u8 = "",
    };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();

    const proposal = std.mem.trim(u8, p.value.proposal, " \r\n\t");
    const expected = std.mem.trim(u8, p.value.expected, " \r\n\t");
    const failures = std.mem.trim(u8, p.value.failures, " \r\n\t");
    const side_effects = std.mem.trim(u8, p.value.side_effects, " \r\n\t");

    if (proposal.len < 3 or expected.len < 6 or failures.len < 6 or side_effects.len < 4)
        return dupe(gpa, "simulation too thin — include proposal, expected gains, failure modes, and side effects");

    const p1 = oneLine(gpa, proposal);
    defer gpa.free(p1);
    const e1 = oneLine(gpa, expected);
    defer gpa.free(e1);
    const f1 = oneLine(gpa, failures);
    defer gpa.free(f1);
    const s1 = oneLine(gpa, side_effects);
    defer gpa.free(s1);

    const rec = std.fmt.allocPrint(gpa, "round={d} mind={s} proposal={s} | expected={s} | failures={s} | side_effects={s}", .{ ctx.round, ctx.mind, p1, e1, f1, s1 }) catch return dupe(gpa, "oom");
    defer gpa.free(rec);
    _ = ctx.mem.observe(SIM_SCOPE, rec);
    const al = std.fmt.allocPrint(gpa, "simulation-submitted r{d} by {s}: {s}", .{ ctx.round, ctx.mind, p1 }) catch return dupe(gpa, "oom");
    defer gpa.free(al);
    _ = ctx.mem.observe(AUTONOMY_SCOPE, al);

    const total = ctx.mem.factCount(SIM_SCOPE);
    return std.fmt.allocPrint(gpa, "simulation recorded ({d} total simulations)", .{total}) catch dupe(gpa, "simulation recorded");
}

fn fetchJson(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { url: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!urlAllowed(p.value.url)) return dupe(gpa, "blocked url (only public http/https; no local/internal hosts)");
    if (!egressAllowed(ctx.egress_allow, p.value.url)) return dupe(gpa, "blocked: host not on the egress allowlist (NL_EGRESS_ALLOWLIST)");
    const raw = curlToText(ctx, p.value.url, true, 26000, 512 << 10);
    defer gpa.free(raw);
    if (raw.len == 0) return dupe(gpa, "(fetch returned nothing or timed out — try another source)");
    return dupe(gpa, clip(raw, 2200));
}

/// Read a URL as clean, LLM-ready text through a reader proxy (default the keyless Jina reader r.jina.ai,
/// which renders JS and is reachable from datacenter IPs that a plain curl GET gets blocked from). The proxy
/// base is overridable via NL_READER_URL so an operator can point at a SELF-HOSTED reader instead.
fn readUrl(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { url: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!urlAllowed(p.value.url)) return dupe(gpa, "blocked url (only public http/https; no local/internal hosts)");
    if (ctx.egress_allow.len > 0) return dupe(gpa, "read_url is disabled under an egress allowlist (it routes through a third-party reader proxy) — use web_fetch on a specific allowlisted URL");
    const cm = crawlPage(ctx, p.value.url, 2200);
    if (cm.len > 0) return cm;
    gpa.free(cm);
    const base = if (ctx.environ.get("NL_READER_URL")) |b| (if (b.len > 0) b else "https://r.jina.ai/") else "https://r.jina.ai/";
    const full = std.fmt.allocPrint(gpa, "{s}{s}", .{ base, p.value.url }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    const raw = curlToText(ctx, full, false, 31000, 1 << 20);
    defer gpa.free(raw);
    if (std.mem.trim(u8, raw, " \r\n\t").len == 0) return dupe(gpa, "(reader returned nothing or timed out)");
    return dupe(gpa, clip(raw, 2200));
}

fn osintScan(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { url: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!urlAllowed(p.value.url)) return dupe(gpa, "blocked url (only public http/https; no local/internal hosts)");
    if (ctx.egress_allow.len > 0) return dupe(gpa, "osint_scan is disabled under an egress allowlist (it fans out to arbitrary hosts) — use web_fetch/fetch_json on a specific allowlisted URL");
    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    prepChildEnv(gpa, ctx.io, &env);
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH", "NL_LLM_KEY" }) |k| env.put(k, "") catch {};
    const py = deps.pythonBin(ctx.io, &env);
    const argv = [_][]const u8{ py, "-c", OSINT_SCAN_PY, p.value.url };
    // bounded.run: one fetch (urllib's 18 s timeout is per socket read, so a server dripping bytes never trips it) and
    // the scan of its body; it had no bound at all
    var r = bounded.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .bound_ms = 60_000, .stdout_limit = 256 << 10, .stderr_limit = 32 << 10 });
    defer r.deinit(gpa);
    if (r.end == .unstarted) return if (deps.isSpawnMissing(r.err.?)) deps.hint(gpa, "python") else dupe(gpa, "osint_scan failed to run");
    if (r.end == .killed) return dupe(gpa, "(osint_scan timed out: it did not finish within 60 s and was stopped — the site is slow or not answering)");
    if (!r.finished()) return dupe(gpa, "osint_scan failed to run");
    const out = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (out.len == 0) return std.fmt.allocPrint(gpa, "(no OSINT leads found: {s})", .{clip(std.mem.trim(u8, r.stderr, " \r\n\t"), 220)}) catch dupe(gpa, "(no OSINT leads)");
    return dupe(gpa, clip(out, 7000));
}

fn deepCrawl(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct {
        url: []const u8 = "",
        depth: u32 = 2,
        max_pages: u32 = 30,
        same_host: bool = true,
    };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!urlAllowed(p.value.url)) return dupe(gpa, "blocked url (only public http/https; no local/internal hosts)");
    if (ctx.egress_allow.len > 0) return dupe(gpa, "deep_crawl is disabled under an egress allowlist (it fans out to arbitrary hosts) — use web_fetch/fetch_json on a specific allowlisted URL");

    const depth = @min(@as(u32, 4), if (p.value.depth == 0) @as(u32, 2) else p.value.depth);
    const pages = @min(@as(u32, 120), if (p.value.max_pages == 0) @as(u32, 30) else p.value.max_pages);
    var dbuf: [16]u8 = undefined;
    var pbuf: [16]u8 = undefined;
    const ds = std.fmt.bufPrint(&dbuf, "{d}", .{depth}) catch "2";
    const ps = std.fmt.bufPrint(&pbuf, "{d}", .{pages}) catch "30";
    const same = if (p.value.same_host) "1" else "0";

    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    prepChildEnv(gpa, ctx.io, &env);
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH", "NL_LLM_KEY" }) |k| env.put(k, "") catch {};
    const py = deps.pythonBin(ctx.io, &env);
    const argv = [_][]const u8{ py, "-c", DEEP_CRAWL_PY, p.value.url, ds, ps, same };
    // bounded.run: up to 120 pages at 16 s a fetch had no bound at all. 240 s keeps a swarm mind's call under the
    // hang watchdog's 300 s. The crawl prints only at its end, so a cut one answers with nothing but the reason:
    // DEEP_CRAWL_PY therefore keeps a budget of its own, starting no fetch past 200 s and printing what it has, and
    // 240 s is the backstop for a fetch still dripping in past that.
    var r = bounded.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .bound_ms = 240_000, .stdout_limit = 512 << 10, .stderr_limit = 48 << 10 });
    defer r.deinit(gpa);
    if (r.end == .unstarted) return if (deps.isSpawnMissing(r.err.?)) deps.hint(gpa, "python") else dupe(gpa, "deep_crawl failed to run");
    if (r.end == .killed) return dupe(gpa, "(deep_crawl timed out: it did not finish within 240 s and was stopped — crawl fewer pages (max_pages) or less deep)");
    if (!r.finished()) return dupe(gpa, "deep_crawl failed to run");
    const out = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (out.len == 0) return std.fmt.allocPrint(gpa, "(crawl returned no data: {s})", .{clip(std.mem.trim(u8, r.stderr, " \r\n\t"), 260)}) catch dupe(gpa, "(crawl returned no data)");
    return dupe(gpa, clip(out, 9000));
}

/// The FULL keyless web-search chain — OUR crawler first (DuckDuckGo SERP, decoded ourselves), then the self-healing
/// python registry (searxng/jina/brave/wikipedia, health-cached) — SHARED by the web_search TOOL and the engine's
/// retrieval SEED so both ground from the same real sources (NO google-news). The crawl path works on a residential
/// IP; the registry catches the datacenter/container case where engines bounce a direct SERP fetch. `tag` keys the
/// crawl temp file; `workdir` caches per-backend health. Returns gpa-owned "- title\n  url[\n  snippet]" lines, "" if
/// every backend is unavailable. The python query is an argv (never code); stdlib only, no pip.
/// SEARCH DEPTH (general; no use-case logic): a SERP is links + snippets, not the story. After a search, fetch the
/// top `k` result pages, run each through the crawl cleaner + BM25 fit-to-query, and inline a short excerpt of the
/// REAL content under its link. Bounded + best-effort: top-k, short per-fetch deadline, bare link kept on failure.
fn enrichResults(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, tag: []const u8, query: []const u8, list: []const u8, k: usize) []const u8 {
    if (k == 0 or std.mem.trim(u8, query, " \r\n\t").len == 0) return dupe(gpa, list);
    const tmp = std.fmt.allocPrint(gpa, "{s}/.cenrich-{s}.tmp", .{ dir, tag }) catch return dupe(gpa, list);
    defer gpa.free(tmp);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa); // toOwnedSlice empties `out` on success (no-op); frees the buffer on the OOM-catch path
    var seen_host: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_host.deinit(gpa);
    var got: usize = 0;
    var tried: usize = 0;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |ln| {
        out.appendSlice(gpa, ln) catch {};
        out.append(gpa, '\n') catch {};
        if (got >= k or tried >= k + 3) continue;
        const t = std.mem.trim(u8, ln, " \r\t");
        const hp = std.mem.indexOf(u8, t, "http") orelse continue;
        var url = t[hp..];
        if (std.mem.indexOfAny(u8, url, " \t)\"<>]")) |sp| url = url[0..sp];
        if (url.len < 12) continue;
        const host = crawl.hostOf(url);
        if (host.len == 0 or isSearchOrAggregator(host) or seen_host.contains(host)) continue;
        seen_host.put(gpa, host, {}) catch {};
        tried += 1;
        const raw = curlBrowserTo(io, gpa, tmp, url, 9000, 512 << 10);
        defer gpa.free(raw);
        if (raw.len < 300 or looksBlocked(raw)) continue;
        const r = crawl.extract(gpa, raw, url);
        defer gpa.free(@constCast(r.title));
        defer gpa.free(@constCast(r.markdown));
        if (r.markdown.len < 160 or looksBlocked(r.markdown)) continue;
        const fit = crawl.fitToQuery(gpa, r.markdown, query, 360);
        defer gpa.free(@constCast(fit));
        var ex: std.ArrayListUnmanaged(u8) = .empty;
        defer ex.deinit(gpa);
        var last_sp = true;
        for (fit) |ch| {
            const c: u8 = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
            if (c == ' ') {
                if (last_sp) continue;
                last_sp = true;
            } else last_sp = false;
            ex.append(gpa, c) catch {};
        }
        const exs = std.mem.trim(u8, ex.items, " ");
        if (exs.len >= 60) {
            out.appendSlice(gpa, "    ") catch {};
            out.appendSlice(gpa, clip(exs, 340)) catch {};
            out.append(gpa, '\n') catch {};
            got += 1;
        }
    }
    return out.toOwnedSlice(gpa) catch dupe(gpa, list);
}

fn isSearchOrAggregator(host: []const u8) bool {
    const skip = [_][]const u8{ "duckduckgo.com", "bing.com", "google.", "marginalia.nu", "jina.ai", "searx", "baidu.com", "yandex.", "youtube.com", "facebook.com", "twitter.com", "x.com", "reddit.com", "newsapi.org", "gdeltproject.org" };
    for (skip) |s| if (std.ascii.indexOfIgnoreCase(host, s) != null) return true;
    return false;
}

pub fn looksBlocked(text: []const u8) bool {
    const sig = [_][]const u8{ "SecurityCompromiseError", "Access Denied", "captcha", "are you a robot", "unusual traffic", "enable JavaScript", "403 Forbidden", "Just a moment", "Attention Required", "blocked until", "verify you are human" };
    for (sig) |s| if (std.ascii.indexOfIgnoreCase(text, s) != null) return true;
    return false;
}

pub fn searchWeb(io: std.Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, run_dir: []const u8, workdir: []const u8, tag: []const u8, source: []const u8, query: []const u8, limit: u32) []const u8 {
    var links: []const u8 = dupe(gpa, "");
    if (!std.mem.eql(u8, source, "wikipedia")) {
        const cs = crawlSearchPrim(io, gpa, run_dir, tag, query, limit);
        if (std.mem.trim(u8, cs, " \r\n\t").len > 0) {
            gpa.free(@constCast(links));
            links = cs;
        } else gpa.free(cs);
    }
    if (std.mem.trim(u8, links, " \r\n\t").len == 0) {
        gpa.free(@constCast(links));
        var env = environ.clone(gpa) catch return dupe(gpa, "");
        defer env.deinit();
        prepChildEnv(gpa, io, &env);
        inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
        var lbuf: [8]u8 = undefined;
        const ls = std.fmt.bufPrint(&lbuf, "{d}", .{limit}) catch "5";
        const py = deps.pythonBin(io, &env);
        const argv = [_][]const u8{ py, "-c", SEARCH_PY, source, query, ls, workdir };
        // This returns immediately (not enriched), so a missing python can safely surface the dep hint
        // instead of a silent empty result. A python that ran and produced nothing keeps returning "".
        // bounded.run: its backends at 12 s a fetch (per socket read, so a dripping server never trips it) had no
        // bound at all; two minutes covers every backend timing out.
        var r = bounded.run(gpa, io, .{ .argv = &argv, .environ_map = &env, .bound_ms = 120_000, .stdout_limit = 256 << 10, .stderr_limit = 8 << 10 });
        defer r.deinit(gpa);
        if (r.end == .unstarted) return if (deps.isSpawnMissing(r.err.?)) deps.hint(gpa, "python") else dupe(gpa, "");
        if (!r.finished()) return dupe(gpa, "");
        links = r.stdout;
        r.stdout = &.{};
    }
    if (std.mem.trim(u8, links, " \r\n\t").len == 0) return links;
    const enriched = enrichResults(io, gpa, run_dir, tag, query, links, 3);
    gpa.free(@constCast(links));
    return enriched;
}

/// Marker prefix for a web_search whose LIVE half returned nothing (local hits shown instead). run.zig's
/// grounding ledger (classifyFetch) keys on this exact prefix to score the call as a FAILED LIVE ATTEMPT —
/// distinct from the "LOCAL RAG … answered this" short-circuit, where the query never went live at all.
/// Change the message and the classifier together, or the backstop mis-counts.
pub const RAG_WEB_EMPTY_MARK = "LOCAL RAG (live web returned nothing";

/// Freshness cues in a query mean the LOCAL RAG must NOT short-circuit the web: a "latest/current/today/news"
/// question needs live sources even when the hive holds solid background on the topic. Everything else is
/// stable knowledge the RAG database can legitimately answer without a web round-trip.
fn queryWantsFresh(query: []const u8) bool {
    const cues = [_][]const u8{ "latest", "current", "today", "recent", "news", "2024", "2025", "2026", "price", "release", "version", "update", "breaking", " live", "right now", "this week", "this year", "as of" };
    for (cues) |c| if (std.ascii.indexOfIgnoreCase(query, c) != null) return true;
    return false;
}

/// Query-decoration words that carry no topic — a query "matched" only on these isn't really covered.
fn isQueryDecoration(word: []const u8) bool {
    const sw = [_][]const u8{ "official", "documentation", "docs", "guide", "reference", "manual", "tutorial", "overview", "introduction", "latest", "features", "usage", "patterns", "example", "examples", "about", "using", "explain", "summary" };
    for (sw) |s| if (std.ascii.eqlIgnoreCase(word, s)) return true;
    return false;
}

/// True when the local RAG hits actually COVER the query — at least half of its significant (>=5 char,
/// non-decoration) terms appear in them. Without this, a few GENERIC facts short-circuit a SPECIFIC question.
/// Skipping the web is only justified when the hive is on-topic for THIS query; a thin/off-topic match must
/// fall through to the web (with the local hits still prepended).
fn localCoversQuery(local: []const u8, query: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n,.;:!?()[]{}\"'`-/");
    var sig: u32 = 0;
    var hit: u32 = 0;
    while (it.next()) |wd| {
        if (wd.len < 5 or isQueryDecoration(wd)) continue;
        sig += 1;
        if (std.ascii.indexOfIgnoreCase(local, wd) != null) hit += 1;
    }
    return sig > 0 and hit * 2 >= sig;
}

/// Keyless multi-engine web search tool: our crawler first, then the self-healing registry (see searchWeb).
///
/// RAG-FIRST (user policy: "always check our rag database first"): before spending a web round-trip, the
/// engine consults the swarm's OWN knowledge — the prefetched nl-rag pack facts plus every teammate finding
/// in the KNOWLEDGE/INTEL hive — with a spreading-activation recall on the same query. If the hive already
/// answers it AND the query isn't asking for something fresh, those grounded facts are returned and the web is
/// SKIPPED (a redundant scrape is avoided). Otherwise the local hits are PREPENDED to the live web results, so
/// the model always sees what is already known before it reads the open web. A weak/empty hive degrades cleanly
/// to the prior web-only path.
/// This is a general retrieval-order floor, not a per-task rule.
fn webSearch(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { query: []const u8 = "", source: []const u8 = "web", limit: u32 = 5 };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const query = std.mem.trim(u8, p.value.query, " \r\n\t");
    if (query.len == 0) return dupe(gpa, "empty query");
    if (ctx.egress_allow.len > 0) return dupe(gpa, "web_search is disabled under an egress allowlist (search returns arbitrary hosts) — fetch a specific allowlisted URL with web_fetch/fetch_json");

    // RAG-first consult: gather what our own knowledge base already holds for this exact query.
    const k_local = ctx.mem.assoc(KNOWLEDGE_SCOPE, query, 1, 10);
    defer gpa.free(k_local);
    const i_local = ctx.mem.assoc(INTEL_SCOPE, query, 1, 6);
    defer gpa.free(i_local);
    var local: std.ArrayListUnmanaged(u8) = .empty;
    defer local.deinit(gpa);
    for ([_][]const u8{ k_local, i_local }) |part| {
        const t = std.mem.trim(u8, part, " \r\n\t");
        if (t.len == 0) continue;
        if (local.items.len > 0) local.append(gpa, '\n') catch {};
        local.appendSlice(gpa, t) catch {};
    }
    const local_facts: usize = if (local.items.len == 0) 0 else std.mem.count(u8, local.items, "\n") + 1;
    const strong = local_facts >= 3 and local.items.len >= 200;

    if (strong and !queryWantsFresh(query) and localCoversQuery(local.items, query)) {
        return std.fmt.allocPrint(gpa, "LOCAL RAG (nl-rag + hive) answered this — checked FIRST per policy; cite these. If you still need FRESH or external detail the hive lacks, refine the query and web_search again:\n{s}", .{clip(local.items, 3600)}) catch dupe(gpa, "local");
    }

    const lim = if (p.value.limit == 0 or p.value.limit > 10) 5 else p.value.limit;
    const out = searchWeb(ctx.io, gpa, ctx.environ, ctx.run_dir, ctx.workdir, ctx.mind, p.value.source, query, lim);
    defer gpa.free(@constCast(out));
    const web = std.mem.trim(u8, out, " \r\n\t");
    if (web.len == 0) {
        // A fetch that came back empty is the exact moment a weak model fabricates: it falls back to its
        // own memory and states a guessed specific as fact (observed live — an empty Zig-version search
        // became a confidently WRONG "0.14.0"). Say plainly that the gap is NOT to be filled from memory.
        if (local.items.len > 0) return std.fmt.allocPrint(gpa, RAG_WEB_EMPTY_MARK ++ " for this query):\n{s}\n\nThe live web gave no result. Do NOT fill any missing specific (a version, date, URL, email, phone) from memory — REFINE the query and web_search again, or write the fact as UNVERIFIED. A guessed specific is a failure.", .{clip(local.items, 3600)}) catch dupe(gpa, "local");
        return dupe(gpa, "(no results for this query.) Do NOT answer from memory — REFINE the query and web_search again (fewer/different words), or if the fact cannot be fetched write it as UNVERIFIED rather than guessing. A fabricated specific (version, date, URL, email, phone) is worse than an admitted gap.");
    }
    // Prepend local hits ONLY when they actually cover this query — the same bar the short-circuit uses.
    // assoc() is spreading activation: it returns SOMETHING for nearly any query, and unfiltered that
    // something was observed live as FICTION from an ingested novel (matched on the word "papers"), glued
    // ahead of the real web results with "prefer these when they answer". A frontier model shrugs; a small
    // model takes the instruction at face value and reasons from a novel. Off-topic hits are dropped, not
    // demoted — the RAG-first policy is the CHECK (which still always runs), not the exhibit.
    if (local.items.len > 0 and localCoversQuery(local.items, query)) return std.fmt.allocPrint(gpa, "LOCAL RAG (nl-rag + hive) — checked first, prefer these when they answer:\n{s}\n\n--- WEB RESULTS ---\n{s}", .{ clip(local.items, 1600), clip(web, 3200) }) catch dupe(gpa, clip(web, 4000));
    return dupe(gpa, clip(web, 4000));
}

const SEARCH_PY =
    \\import sys,json,re,html,os,time,urllib.parse,urllib.request
    \\src,q,lim=(sys.argv[1] or "web"),sys.argv[2],int(sys.argv[3])
    \\workdir=sys.argv[4] if len(sys.argv)>4 else "."
    \\HEALTH=os.path.join(workdir,".search_health.json")
    \\def now(): return int(time.time())
    \\def loadh():
    \\    try: return json.load(open(HEALTH))
    \\    except Exception: return {}
    \\def saveh(h):
    \\    try: json.dump(h,open(HEALTH,"w"))
    \\    except Exception: pass
    \\def g(u,t=12,ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",data=None,hdr=None):
    \\    h={"User-Agent":ua,"Accept":"*/*"}
    \\    if hdr: h.update(hdr)
    \\    return urllib.request.urlopen(urllib.request.Request(u,data=data,headers=h),timeout=t).read().decode("utf-8","replace")
    \\def searxng(base):
    \\    def f():
    \\        d=json.loads(g(base.rstrip("/")+"/search?format=json&q=%s"%urllib.parse.quote(q)))
    \\        return [{"title":r.get("title",""),"url":r.get("url",""),"snippet":(r.get("content") or "")[:160]} for r in d.get("results",[])[:lim]]
    \\    return f
    \\def jina(eng):
    \\    def f():
    \\        h=g("https://r.jina.ai/"+eng%urllib.parse.quote(q),t=22)
    \\        o=[]
    \\        for title,link in re.findall(r'##\s*\[(.*?)\]\((https?://[^)]+)\)',h,re.S):
    \\            t2=re.sub(r"\s+"," ",re.sub("<[^>]+>","",title)).strip()
    \\            real=link
    \\            if "duckduckgo.com/l/?uddg=" in link: real=urllib.parse.parse_qs(urllib.parse.urlparse(link.replace("&amp;","&")).query).get("uddg",[link])[0]
    \\            if t2 and real.startswith("http"): o.append({"title":html.unescape(t2),"url":real,"snippet":""})
    \\            if len(o)>=lim: break
    \\        return o
    \\    return f
    \\def firecrawl():
    \\    def f():
    \\        k=os.environ.get("NL_FIRECRAWL_KEY","")
    \\        if not k: raise Exception("no_key")
    \\        d=json.loads(g("https://api.firecrawl.dev/v2/search",data=json.dumps({"query":q,"limit":lim}).encode(),hdr={"Content-Type":"application/json","Authorization":"Bearer "+k}))
    \\        web=(d.get("data") or {}).get("web") if isinstance(d.get("data"),dict) else d.get("data")
    \\        return [{"title":r.get("title",""),"url":r.get("url",""),"snippet":(r.get("description") or "")[:160]} for r in (web or [])[:lim]]
    \\    return f
    \\def brave():
    \\    def f():
    \\        k=os.environ.get("NL_BRAVE_KEY","")
    \\        if not k: raise Exception("no_key")
    \\        d=json.loads(g("https://api.search.brave.com/res/v1/web/search?q=%s"%urllib.parse.quote(q),hdr={"X-Subscription-Token":k,"Accept":"application/json"}))
    \\        return [{"title":r.get("title",""),"url":r.get("url",""),"snippet":(r.get("description") or "")[:160]} for r in d.get("web",{}).get("results",[])[:lim]]
    \\    return f
    \\def wikip():
    \\    def f():
    \\        d=json.loads(g("https://en.wikipedia.org/w/api.php?action=opensearch&format=json&limit=%d&search=%s"%(lim,urllib.parse.quote(q))))
    \\        return [{"title":t,"url":l,"snippet":ds} for t,ds,l in zip(d[1],d[2],d[3])]
    \\    return f
    \\if src=="wikipedia": registry=[("wikipedia",wikip())]
    \\else:
    \\    reg={}
    \\    sx=os.environ.get("NL_SEARXNG_URL","").strip()
    \\    if sx: reg["searxng_local"]=searxng(sx)
    \\    reg["searxng_be"]=searxng("https://searx.be")
    \\    reg["searxng_inetol"]=searxng("https://search.inetol.net")
    \\    reg["brave"]=brave(); reg["firecrawl"]=firecrawl()
    \\    reg["jina_ddg"]=jina("https://duckduckgo.com/html/?q=%s")
    \\    reg["jina_bing"]=jina("https://www.bing.com/search?q=%s")
    \\    reg["wikipedia"]=wikip()
    \\    order=os.environ.get("NL_SEARCH_BACKENDS","").strip()
    \\    if order:
    \\        ids=[s.strip() for s in order.split(",") if s.strip() in reg]
    \\        registry=[(i,reg[i]) for i in ids] or list(reg.items())
    \\    else:
    \\        pref=["searxng_local","brave","firecrawl","jina_ddg","jina_bing","searxng_be","searxng_inetol","wikipedia"]
    \\        registry=[(i,reg[i]) for i in pref if i in reg]
    \\def classify(e):
    \\    s=str(e)
    \\    if "no_key" in s: return 86400
    \\    if "429" in s: return 600
    \\    if "451" in s or "403" in s or "401" in s: return 1800
    \\    if "timed out" in s or "timeout" in s: return 120
    \\    return 300
    \\health=loadh(); attempts=[]; results=[]
    \\for bid,fn in registry:
    \\    st=health.get(bid,{})
    \\    if st.get("cd",0)>now(): attempts.append("%s:cooling%ds"%(bid,st["cd"]-now())); continue
    \\    try:
    \\        r=fn()
    \\        if r: health[bid]={"ok":now(),"cd":0}; results=r; attempts.append(bid+":ok"); break
    \\        else: health[bid]={"cd":now()+180,"err":"empty"}; attempts.append(bid+":empty")
    \\    except Exception as e:
    \\        cd=classify(e); health[bid]={"cd":now()+cd,"err":str(e)[:40]}; attempts.append("%s:fail(%s)"%(bid,str(e)[:24]))
    \\saveh(health)
    \\if results: print("\n".join("- %s\n  %s\n  %s"%(r["title"],r["url"],r.get("snippet","")) for r in results[:lim]))
    \\else: sys.stderr.write("all search backends unavailable: "+", ".join(attempts))
;

const OSINT_SCAN_PY =
    \\import sys,re,urllib.request,urllib.parse,html
    \\u=sys.argv[1]
    \\def g(url,t=18):
    \\    rq=urllib.request.Request(url,headers={"User-Agent":"neuron-loops-osint/1.0","Accept":"text/html,*/*"})
    \\    return urllib.request.urlopen(rq,timeout=t).read().decode("utf-8","replace")
    \\try:
    \\    b=g(u)
    \\except Exception as e:
    \\    print("fetch_error: %s"%e); sys.exit(0)
    \\links=[]
    \\for m in re.findall(r'href=["\']([^"\'#]+)',b,re.I):
    \\    a=urllib.parse.urljoin(u,m)
    \\    if a.startswith("http://") or a.startswith("https://"):
    \\        links.append(a)
    \\emails=sorted(set(re.findall(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}',b)))[:30]
    \\phones=sorted(set(re.findall(r'(?:\\+?\\d[\\d\\-(). ]{7,}\\d)',b)))[:20]
    \\docs=[x for x in sorted(set(links)) if re.search(r'\\.(pdf|docx?|xlsx?|pptx?|csv|json|xml)(?:$|\\?)',x,re.I)][:40]
    \\social=[x for x in sorted(set(links)) if any(d in x for d in ("linkedin.com","x.com","twitter.com","github.com","gitlab.com","youtube.com","facebook.com","instagram.com"))][:40]
    \\keys=[x for x in sorted(set(links)) if any(k in x.lower() for k in ("contact","about","team","careers","blog","docs","api","press","investor","security","status","admin","login","signup","register","sitemap"))][:80]
    \\host=urllib.parse.urlparse(u).netloc
    \\print("OSINT scan: %s"%u)
    \\print("host: %s"%host)
    \\print("emails: %d"%len(emails))
    \\for e in emails[:20]: print("- email: "+e)
    \\print("phones: %d"%len(phones))
    \\for p in phones[:12]: print("- phone: "+p.strip())
    \\print("notable links: %d"%len(keys))
    \\for x in keys[:40]: print("- lead: "+x)
    \\print("documents: %d"%len(docs))
    \\for x in docs[:20]: print("- doc: "+x)
    \\print("social/repo links: %d"%len(social))
    \\for x in social[:20]: print("- social: "+x)
;

const DEEP_CRAWL_PY =
    \\import sys,re,collections,time,urllib.request,urllib.parse
    \\BUDGET_S=200
    \\t0=time.monotonic()
    \\seed=sys.argv[1]
    \\max_depth=int(sys.argv[2])
    \\max_pages=int(sys.argv[3])
    \\same_host=(sys.argv[4]=="1")
    \\sp=urllib.parse.urlparse(seed)
    \\seed_host=sp.netloc.lower()
    \\def ok(u):
    \\    try:
    \\        p=urllib.parse.urlparse(u)
    \\    except Exception:
    \\        return False
    \\    if p.scheme not in ("http","https"): return False
    \\    h=(p.netloc or "").lower()
    \\    if not h: return False
    \\    # netloc KEEPS userinfo and port, so "x@127.0.0.1:8787" defeated every startswith below and the
    \\    # crawler would happily fetch loopback. Strip both before judging the host, and reject the
    \\    # numeric spellings (integer / octal / hex) that name the same address without the prefix.
    \\    if "@" in h: h=h.rsplit("@",1)[1]
    \\    if h.startswith("["): return False
    \\    h=h.split(":",1)[0]
    \\    if not h: return False
    \\    if h.startswith(("localhost","127.","0.0.0.0","169.254.","10.","192.168.")) or h.endswith(".local"):
    \\        return False
    \\    try:
    \\        import ipaddress
    \\        ip=ipaddress.ip_address(int(h,0) if h.isdigit() or h.startswith(("0x","0X")) else h)
    \\        if ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_reserved or ip.is_unspecified:
    \\            return False
    \\    except ValueError:
    \\        pass
    \\    parts=h.split(".")
    \\    if len(parts)==4 and all(x.lstrip("0") .isdigit() or x=="0" for x in parts if x):
    \\        try:
    \\            import ipaddress
    \\            ip=ipaddress.ip_address(".".join(str(int(x,8) if x.startswith("0") and x!="0" else int(x)) for x in parts))
    \\            if ip.is_loopback or ip.is_private or ip.is_link_local:
    \\                return False
    \\        except (ValueError,OverflowError):
    \\            return False
    \\    if same_host and h!=seed_host: return False
    \\    return True
    \\def fetch(u,t=16):
    \\    rq=urllib.request.Request(u,headers={"User-Agent":"neuron-loops-crawler/1.0","Accept":"text/html,*/*"})
    \\    return urllib.request.urlopen(rq,timeout=t).read().decode("utf-8","replace")
    \\def extract(u,body):
    \\    out=[]
    \\    for m in re.findall(r'href=["\']([^"\'#]+)',body,re.I):
    \\        a=urllib.parse.urljoin(u,m).split('#')[0]
    \\        if ok(a): out.append(a)
    \\    return out
    \\def leads(u,body):
    \\    em=set(re.findall(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}',body))
    \\    lk=set(extract(u,body))
    \\    hot=[x for x in lk if any(k in x.lower() for k in ("contact","about","team","docs","api","security","status","careers","press","investor","login","admin","signup","sitemap","github","gitlab","linkedin","twitter","x.com"))]
    \\    docs=[x for x in lk if re.search(r'\\.(pdf|docx?|xlsx?|pptx?|csv|json|xml)(?:$|\\?)',x,re.I)]
    \\    return sorted(em)[:6], sorted(hot)[:18], sorted(docs)[:10]
    \\q=collections.deque([(seed,0)])
    \\seen=set([seed])
    \\pages=[]
    \\all_em=set(); all_hot=set(); all_docs=set()
    \\cut=False
    \\while q and len(pages)<max_pages:
    \\    if time.monotonic()-t0>=BUDGET_S:
    \\        cut=True; break
    \\    u,d=q.popleft()
    \\    try:
    \\        b=fetch(u)
    \\    except Exception:
    \\        continue
    \\    pages.append((u,d))
    \\    em,hot,docs=leads(u,b)
    \\    all_em.update(em); all_hot.update(hot); all_docs.update(docs)
    \\    if d>=max_depth: continue
    \\    for nx in extract(u,b):
    \\        if nx in seen: continue
    \\        seen.add(nx)
    \\        q.append((nx,d+1))
    \\print("Deep crawl seed: %s"%seed)
    \\print("pages_crawled: %d"%len(pages))
    \\print("seen_urls: %d"%len(seen))
    \\if cut: print("stopped_early: the crawl's %d s budget ran out with %d queued urls not fetched"%(BUDGET_S,len(q)))
    \\print("emails_found: %d"%len(all_em))
    \\for e in sorted(all_em)[:80]: print("- email: "+e)
    \\print("lead_links_found: %d"%len(all_hot))
    \\for x in sorted(all_hot)[:140]: print("- lead: "+x)
    \\print("documents_found: %d"%len(all_docs))
    \\for x in sorted(all_docs)[:80]: print("- doc: "+x)
    \\print("crawl_sample:")
    \\for u,d in pages[:80]: print("- d%d %s"%(d,u))
;

const PATCH_SYSTEM_PATCH_PY =
    \\import sys,os,json,re
    \\root = sys.argv[1]
    \\patch = sys.argv[2]
    \\def bad(msg):
    \\    sys.stderr.write(msg)
    \\    sys.exit(2)
    \\def safe_rel(p):
    \\    return bool(p) and (not os.path.isabs(p)) and ('..' not in p.replace('\\\\','/').split('/'))
    \\def blocked(p):
    \\    p = p.replace('\\\\','/')
    \\    for b in ('.git/','.zig-cache/','zig-out/','data/','terraform/.terraform/'):
    \\        if p.startswith(b):
    \\            return True
    \\    return False
    \\def full_path(rel):
    \\    if not safe_rel(rel) or blocked(rel):
    \\        bad('blocked path in patch: '+rel)
    \\    return os.path.join(root, rel)
    \\def write_text(path, txt):
    \\    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    \\    with open(path,'w',encoding='utf-8') as f:
    \\        f.write(txt)
    \\def apply_update(rel, body):
    \\    path = full_path(rel)
    \\    if not os.path.exists(path):
    \\        bad('update target missing: '+rel)
    \\    src = open(path,'r',encoding='utf-8',errors='replace').read()
    \\    lines = [ln for ln in body.splitlines() if not ln.startswith('@@')]
    \\    olds=[]; news=[]
    \\    for ln in lines:
    \\        if not ln:
    \\            olds.append(''); news.append(''); continue
    \\        k = ln[0]
    \\        t = ln[1:]
    \\        if k == ' ':
    \\            olds.append(t); news.append(t)
    \\        elif k == '-':
    \\            olds.append(t)
    \\        elif k == '+':
    \\            news.append(t)
    \\    old = '\\n'.join(olds)
    \\    new = '\\n'.join(news)
    \\    if old and src.count(old) != 1:
    \\        bad('update hunk missing or ambiguous in '+rel)
    \\    if old:
    \\        src = src.replace(old, new, 1)
    \\    else:
    \\        src = new
    \\    write_text(path, src)
    \\changed=[]
    \\if '*** Begin Patch' not in patch or '*** End Patch' not in patch:
    \\    bad('invalid patch envelope')
    \\ops = re.split(r'\\n(?=\\*\\*\\* (?:Add|Update|Delete) File: )', patch)
    \\for chunk in ops:
    \\    chunk = chunk.strip('\\n')
    \\    if not chunk or chunk in ('*** Begin Patch','*** End Patch'):
    \\        continue
    \\    if chunk.startswith('*** Begin Patch') or chunk.startswith('*** End Patch'):
    \\        continue
    \\    m = re.match(r'^\\*\\*\\* (Add|Update|Delete) File: (.+?)\\n([\\s\\S]*)$', chunk)
    \\    if not m:
    \\        continue
    \\    kind, rel, body = m.group(1), m.group(2).strip(), m.group(3)
    \\    path = full_path(rel)
    \\    if kind == 'Add':
    \\        add_lines=[]
    \\        for ln in body.splitlines():
    \\            if ln.startswith('+++') or ln.startswith('@@'):
    \\                continue
    \\            if ln.startswith('+'):
    \\                add_lines.append(ln[1:])
    \\        write_text(path, '\\n'.join(add_lines) + ('\\n' if add_lines else ''))
    \\        changed.append(rel)
    \\    elif kind == 'Delete':
    \\        try:
    \\            os.remove(path)
    \\        except FileNotFoundError:
    \\            bad('delete target missing: '+rel)
    \\        changed.append(rel)
    \\    else:
    \\        apply_update(rel, body)
    \\        changed.append(rel)
    \\print(json.dumps({'ok': True, 'changed': changed}))
;

/// The engine-owned BENCHMARK SCORER — run once per round with cwd=workdir, prints exactly ONE JSON line and
/// never throws (so a broken deliverable scores 0, it never crashes a round). 3 tiers so the curve moves at
/// every stage of a build: TIER 1 = real tests (pytest if present, else `unittest discover`; pass/total), with
/// a hard subprocess timeout so a runaway test can't hang the round; TIER 2 = no tests yet, score = how many
/// .py files compile (nudges the swarm toward authoring tests); TIER 3 = non-code artifacts scored by each
/// format's OWN parser (json/xml/toml well-formedness, html structural-tag balance + css brace balance
/// [truncation-shaped breakage], non-empty otherwise — no content opinions; the
/// goal-parameterized word-coverage path applies only when NL_DOC_TARGET_WORDS is set). The failure extractor
/// ff() reads BOTH runners' native formats — unittest `FAIL:`/`ERROR:` blocks AND pytest's
/// `FAILED node - reason` summary lines (parsing only one shape starves the steering loop of the messages that
/// name the fixes) — and malformed non-Python layer files (a broken config.json) ride along in `failures` even
/// when tests score, so a multi-layer build hears about every layer. Model-uneditable: it runs via
/// `python -c BENCH_PY`, so the swarm cannot fake or dodge its own fitness function.
pub const BENCH_PY =
    \\import sys,json,os,glob,subprocess,re,py_compile
    \\def out(d):
    \\    sys.stdout.write(json.dumps(d)+"\n"); sys.exit(0)
    \\def skipf(f):
    \\    # layout-blind scoring must still skip non-deliverable trees: dot/underscore segments (caches,
    \\    # __pycache__), dependency dirs, and the engine-owned skills/ + journal/ dirs (learned notes and
    \\    # personal journals, not the build)
    \\    segs=f.replace(os.sep,"/").split("/")
    \\    return any(s.startswith((".","_")) or s in ("node_modules","venv") for s in segs) or segs[0] in ("skills","journal")
    \\def hchk(t):
    \\    # structural completeness via the stdlib parser: a page CUT mid-emission ends with <style>/<body>/
    \\    # <html>... still open. Only STRUCTURAL tags are enforced (unclosed <p>/<li> is legal HTML) so a
    \\    # sloppy-but-complete page passes and a truncated one fails. This is format well-formedness, not a
    \\    # content opinion — the exact check that would have caught a mid-CSS varieties.html scoring 100%.
    \\    from html.parser import HTMLParser
    \\    VOID={"area","base","br","col","embed","hr","img","input","link","meta","param","source","track","wbr"}
    \\    class P(HTMLParser):
    \\        def __init__(s):
    \\            HTMLParser.__init__(s); s.stack=[]
    \\        def handle_starttag(s,tag,at):
    \\            if tag not in VOID: s.stack.append(tag)
    \\        def handle_endtag(s,tag):
    \\            for i in range(len(s.stack)-1,-1,-1):
    \\                if s.stack[i]==tag: del s.stack[i:]; break
    \\    p=P(); p.feed(t); p.close()
    \\    bad=[x for x in p.stack if x in ("html","head","body","style","script","title","table","ul","ol","div","section","main","header","footer","nav")]
    \\    if bad: raise ValueError("unclosed <"+bad[-1]+"> tag - the page looks truncated/incomplete")
    \\def cchk(t):
    \\    if t.count("{")!=t.count("}"): raise ValueError("unbalanced braces - the stylesheet looks truncated/incomplete")
    \\def ff(txt):
    \\    r=[]
    \\    body=re.split(r"-{3,}[\r\n]+Ran \d",txt)[0]
    \\    for b in re.split(r"={3,}",body):
    \\        ls=[l for l in b.splitlines() if l.strip()]
    \\        if not ls or not ls[0].strip().startswith(("FAIL:","ERROR:")): continue
    \\        h=ls[0].strip(); k=h.split(":",1)[0]; nm=h.split(":",1)[1].strip().split(" ")[0]
    \\        ex=""
    \\        for l in ls:
    \\            s=l.strip()
    \\            if re.match(r"^[A-Za-z_.]*(Error|Exception|Failure)\b",s): ex=s
    \\        if not ex: ex=ls[-1].strip()
    \\        r.append((k+" "+nm+" -> "+ex)[:160])
    \\    for l in txt.splitlines():
    \\        s=l.strip()
    \\        m=re.match(r"^(FAILED|ERROR)\s+(\S+?)(?:\s+-\s+(.*))?$",s)
    \\        if not m or m.group(2).startswith("("): continue
    \\        r.append((m.group(1)+" "+m.group(2)+" -> "+(m.group(3) or "see traceback"))[:160])
    \\    seen=set(); u=[]
    \\    for x in r:
    \\        if x in seen: continue
    \\        seen.add(x); u.append(x)
    \\    return u[:6]
    \\def wf():
    \\    fails=[]; ok=0; tot=0
    \\    for f in sorted(glob.glob("**/*",recursive=True)):
    \\        if not os.path.isfile(f) or skipf(f): continue
    \\        lf=f.lower()
    \\        if lf.endswith((".py",".pyc")): continue
    \\        tot+=1
    \\        try: t=open(f,encoding="utf-8",errors="replace").read()
    \\        except Exception: fails.append((f+": unreadable")[:90]); continue
    \\        try:
    \\            if not t.strip(): raise ValueError("empty file")
    \\            if lf.endswith(".json"): json.loads(t)
    \\            elif lf.endswith(".xml"):
    \\                import xml.etree.ElementTree as ET; ET.fromstring(t)
    \\            elif lf.endswith(".toml"):
    \\                try: import tomllib; tomllib.loads(t)
    \\                except ImportError: pass
    \\            elif lf.endswith((".html",".htm")): hchk(t)
    \\            elif lf.endswith(".css"): cchk(t)
    \\            ok+=1
    \\        except Exception as ex: fails.append((f+": "+str(ex).splitlines()[0])[:90])
    \\    return ok,tot,fails
    \\try:
    \\    only=os.environ.get("NL_BENCH_ONLY","")
    \\    if only:
    \\        try:
    \\            r=subprocess.run([sys.executable,"-m","unittest","-q",only],capture_output=True,text=True,timeout=30)
    \\        except subprocess.TimeoutExpired:
    \\            out({"status":"error","msg":"protected benchmark timed out"})
    \\        except Exception as e:
    \\            out({"status":"error","msg":str(e)[:120]})
    \\        txt=(r.stdout or "")+(r.stderr or "")
    \\        mr=re.search(r"Ran (\d+) test",txt)
    \\        if mr and int(mr.group(1))>0:
    \\            tot=int(mr.group(1)); mfa=re.search(r"failures=(\d+)",txt); mer=re.search(r"errors=(\d+)",txt)
    \\            f=(int(mfa.group(1)) if mfa else 0)+(int(mer.group(1)) if mer else 0); p=tot-f
    \\            fails=ff(txt)
    \\            out({"status":"ok","passed":p,"total":tot,"failures":fails,"tier":1})
    \\        out({"status":"error","msg":("protected spec did not run: "+(txt.strip().splitlines() or ["?"])[-1])[:120]})
    \\    pys=[f for f in glob.glob("**/*.py",recursive=True) if not skipf(f)]
    \\    tests=[f for f in pys if os.path.basename(f).startswith("test_") or os.path.basename(f).endswith("_test.py")]
    \\    if os.path.isdir("tests"): tests+=glob.glob("tests/**/*.py",recursive=True)
    \\    aux=wf()[2]
    \\    if tests:
    \\        for runner in (["-m","pytest","-q","--no-header"],["-m","unittest","discover","-q"]):
    \\            try:
    \\                r=subprocess.run([sys.executable]+runner,capture_output=True,text=True,timeout=30)
    \\            except subprocess.TimeoutExpired:
    \\                out({"status":"error","msg":"test run timed out"})
    \\            except Exception:
    \\                continue
    \\            txt=(r.stdout or "")+(r.stderr or "")
    \\            if "pytest" in runner[1]:
    \\                mp=re.search(r"(\d+) passed",txt); mf=re.search(r"(\d+) failed",txt); me=re.search(r"(\d+) error",txt)
    \\                if not mp and not mf: continue
    \\                p=int(mp.group(1)) if mp else 0; f=(int(mf.group(1)) if mf else 0)+(int(me.group(1)) if me else 0)
    \\            else:
    \\                mr=re.search(r"Ran (\d+) test",txt)
    \\                if not mr or int(mr.group(1))==0: continue
    \\                tot0=int(mr.group(1)); mfa=re.search(r"failures=(\d+)",txt); mer=re.search(r"errors=(\d+)",txt)
    \\                f=(int(mfa.group(1)) if mfa else 0)+(int(mer.group(1)) if mer else 0); p=tot0-f
    \\            tot=p+f
    \\            if tot>0:
    \\                fails=(ff(txt)+aux)[:6]
    \\                out({"status":"ok","passed":p,"total":tot,"failures":fails,"tier":1})
    \\    if pys:
    \\        ok=0; tot=0; fails=[]
    \\        for f in pys:
    \\            tot+=1
    \\            try: py_compile.compile(f,doraise=True); ok+=1
    \\            except Exception as e: fails.append((f+": "+str(e).splitlines()[0])[:90])
    \\        out({"status":"ok","passed":ok,"total":tot,"failures":(fails+aux)[:5],"tier":2})
    \\    tw=int(os.environ.get("NL_DOC_TARGET_WORDS","0") or 0)
    \\    docs=[f for f in glob.glob("**/*",recursive=True) if os.path.isfile(f) and not skipf(f)]
    \\    if docs and tw>0:
    \\        sc=0.0
    \\        for f in docs:
    \\            try: t=open(f,encoding="utf-8",errors="replace").read()
    \\            except Exception: t=""
    \\            if f.lower().endswith(".md"): sc+= min(1.0, sum(len(ln.split()) for ln in t.split("\n") if ln.strip() and not ln.strip().startswith("#"))/tw)
    \\            else: sc+= 1 if len(t.strip())>0 else 0
    \\        denom=max(len(docs), int(os.environ.get("NL_DOC_FILE_COUNT","0") or 0))
    \\        pct=min(99,int(sc*100/denom)) if denom else 0
    \\        out({"status":"ok","passed":pct,"total":100,"failures":[],"tier":3})
    \\    if docs:
    \\        ok,tot,fails=wf()
    \\        pyok=0
    \\        for f in [x for x in docs if x.lower().endswith(".py")]:
    \\            tot+=1
    \\            try: py_compile.compile(f,doraise=True); ok+=1; pyok+=1
    \\            except Exception as e: fails.append((f+": "+str(e).splitlines()[0])[:90])
    \\        if tot>0: out({"status":"ok","passed":ok,"total":tot,"failures":fails[:5],"tier":3})
    \\    out({"status":"no-tests"})
    \\except Exception as e:
    \\    out({"status":"error","msg":str(e)[:120]})
;
/// The engine-owned IMPORT-GRAPH analyzer — run once per round (cwd = workdir) via `python -c DEPGRAPH_PY`. It
/// `ast`-parses every project .py file, resolves each import to the project file it points at, and prints a
/// compact dependency map ("foo.py -> imports: bar.py  <- used by: baz.py"). This is structural RAG context for
/// SCALE: a mind changing core.py can SEE that __init__.py and the tests import it, so cross-file changes stay
/// coordinated. Never throws (a parse error skips that file); bounded output. Pure stdlib.
pub const DEPGRAPH_PY =
    \\import ast, os
    \\files=[]
    \\for root,ds,fs in os.walk('.'):
    \\    ds[:]=[d for d in ds if not d.startswith('.') and d!='__pycache__']
    \\    for f in fs:
    \\        if f.endswith('.py') and not (f.startswith('spec_test') or f.startswith('.')):
    \\            p=os.path.join(root,f).replace(os.sep,'/')
    \\            if p.startswith('./'): p=p[2:]
    \\            files.append(p)
    \\mods={}
    \\for p in files:
    \\    parts=p[:-3].split('/')
    \\    mods.setdefault(parts[-1],p); mods.setdefault('.'.join(parts),p)
    \\    if 'src' in parts:
    \\        i=parts.index('src'); mods.setdefault('.'.join(parts[i+1:]),p)
    \\imp={p:set() for p in files}
    \\for p in files:
    \\    try: tree=ast.parse(open(p,encoding='utf-8',errors='replace').read())
    \\    except Exception: continue
    \\    for n in ast.walk(tree):
    \\        ns=[]
    \\        if isinstance(n,ast.Import): ns=[a.name for a in n.names]
    \\        elif isinstance(n,ast.ImportFrom):
    \\            if n.module: ns=[n.module]
    \\        for nm in ns:
    \\            c=mods.get(nm) or mods.get(nm.split('.')[0]) or mods.get(nm.split('.')[-1])
    \\            if c and c!=p: imp[p].add(c)
    \\by={p:set() for p in files}
    \\for p,dd in imp.items():
    \\    for d in dd: by[d].add(p)
    \\out=[]
    \\for p in sorted(files)[:60]:
    \\    s=p
    \\    if imp[p]: s+='  -> imports: '+', '.join(sorted(imp[p]))
    \\    if by[p]: s+='  <- used by: '+', '.join(sorted(by[p]))
    \\    out.append(s)
    \\print('\n'.join(out))
;

/// A timeout LAUNCHER for model-authored Python: instead of `python script.py` (which `std.process.run` runs
/// with NO timeout, so an infinite loop / blocking input() / un-timed network call would freeze the mind's
/// moment and deadlock the whole round), run `python -c PYRUN <cap_s> script.py [arg]` — it re-execs the script
/// with a HARD wall-clock cap (pyrunCapS: 25 s unless NL_PYRUN_TIMEOUT_S says otherwise) and kills it on
/// timeout, so a runaway script fails fast instead of hanging the swarm. (Defense-in-depth behind the engine's
/// hang watchdog.) cwd + env (keys blanked) are inherited by the child.
///
/// What a cap hit SAYS matters as much as the cap. This used to drop everything the script had printed and
/// answer "this script exceeded 25s wall-clock and was killed" — a sentence a model reads as a fact about its
/// own code. In a measured SWE-bench run it went on wrapping test commands in timeout=120, 600 and 900 that the
/// 25 s cap silently overrode, and it re-ran a suite that had most likely already finished: the script had
/// exited, and only a process it started was still holding the pipes. So a hit now returns the TAIL of what was
/// printed, names the cap as run_python's own (a timeout= inside the code cannot raise it), and says whether the
/// script itself was still running. Output passes through as bytes, so an undecodable byte from the script
/// cannot take the launcher down with it.
///
/// The launcher reads both pipes ITSELF, in chunks, on two threads, rather than through communicate(). On Windows
/// CPython's communicate() reads each pipe with ONE blocking read() to EOF, and a timeout hands back nothing at
/// all, so whenever a process the script started still held the inherited pipes (a test run Popen'ed without
/// redirection, a `docker exec` the script was waiting on) every byte the script had printed was lost, even
/// though POSIX kept it. The chunks that arrived are there to show on every platform. The pipes are also what
/// decides "finished": once the script has exited, the call waits for them to close, past the cap by at most a
/// 5 s grace, so a process left holding them cannot hold the tool open. If they close inside that grace, nothing
/// was cut off — the output is complete and the script's own exit code passes through, with a note, because
/// answering "cut off" there is exactly what sent the model back to re-run a suite that had already finished.
/// The kill reaches the script alone (what it started keeps running, and the reply says so). Every exit is a
/// flush and os._exit, so a reader still parked on a held pipe cannot stall interpreter shutdown (a Windows exit
/// code past 2^31 is passed as its signed twin, which os._exit accepts and the OS reads back unchanged); an error
/// after the spawn kills the script before reporting, as subprocess.run's own cleanup did.
pub const PYRUN =
    \\import os,subprocess,sys,threading,time
    \\def tail(b,n):
    \\    if len(b)<=n: return b
    \\    t=b[-n:]; i=t.find(b"\n")
    \\    if 0<=i<200: t=t[i+1:]
    \\    return (b"[... %d earlier bytes not shown ...]\n"%(len(b)-len(t)))+t
    \\def pump(f,buf):
    \\    try:
    \\        while True:
    \\            c=os.read(f.fileno(),65536)
    \\            if not c: return
    \\            buf.append(c)
    \\    except Exception: pass
    \\def drained(by):
    \\    for t in ts: t.join(max(0.0,by-time.monotonic()))
    \\    return not any(t.is_alive() for t in ts)
    \\def done(o,e,code):
    \\    sys.stdout.buffer.write(o); sys.stdout.flush()
    \\    sys.stderr.buffer.write(e); sys.stderr.flush()
    \\    os._exit(code-2**32 if code>=2**31 else code)
    \\try:
    \\    cap=int(sys.argv[1])
    \\    p=subprocess.Popen([sys.executable]+sys.argv[2:],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    \\except Exception as x:
    \\    sys.stderr.write("launcher error: "+str(x)); sys.exit(1)
    \\try:
    \\    t0=time.monotonic(); ob=[]; eb=[]
    \\    ts=[threading.Thread(target=pump,args=(p.stdout,ob),daemon=True),threading.Thread(target=pump,args=(p.stderr,eb),daemon=True)]
    \\    for t in ts: t.start()
    \\    try: rc=p.wait(timeout=cap)
    \\    except subprocess.TimeoutExpired: rc=p.poll()
    \\    if rc is not None and drained(t0+cap): done(b"".join(ob),b"".join(eb),rc)
    \\    cut=rc is None
    \\    if cut: p.kill()
    \\    held=not drained(time.monotonic()+5)
    \\    o=b"".join(ob[:]); e=b"".join(eb[:])
    \\    if not cut and not held:
    \\        n="\nNOTE: the script exited (code %d) within run_python's %d s cap; a process it started held its output open until %.1f s, and that output is complete above."%(rc,cap,time.monotonic()-t0)
    \\        done(o,e+n.encode(),rc)
    \\    m="\nTIMEOUT: the run_python cap is %d s and this run reached it. "%cap
    \\    m+="The script was still running and was killed; the output above is what it printed before that. " if cut else "The script itself had exited (code %d), but a process it started kept its output open past the cap, so the call was cut off here. "%rc
    \\    m+="A process it started still holds that output open and was not killed: it may still be running, and nothing it prints from here on is shown. " if held else "Anything it started was not killed and may still be running. "
    \\    m+="A timeout= inside your code cannot raise this cap. Split the work into shorter runs, or start a long job in the background with its output sent to a file and watch that file with poll."
    \\    done(tail(o,3000),tail(e,800)+m.encode(),124)
    \\except Exception as x:
    \\    try: p.kill()
    \\    except Exception: pass
    \\    sys.stderr.write("launcher error: "+str(x)); sys.stderr.flush(); os._exit(1)
;

/// run_python's wall-clock cap when NL_PYRUN_TIMEOUT_S is unset: 120 s, read off the runs that used this launcher
/// under a higher cap rather than set by feel. Across the five 2026-10-14 SWE-bench arms that ran with
/// NL_PYRUN_TIMEOUT_S=150 (538 run_python calls, 309 of them a test command in the task's container) no call reached
/// the cap; the container test runs finished at a median of 1.9 s, 95% inside 10 s, and the longest real test run
/// took 88 s (astropy, pytest on one module); eight sleep-and-tail loops the model wrote ran 60-103 s. The 25 s that
/// stood here would have cut ten of those 309 runs, two of them real test runs (28 s and 88 s), and in the arms that
/// kept 25 s no run came near it only because the turns never got as far as testing. 120 s clears every real run seen
/// with a third of headroom for a loaded machine, is half PYRUN_CAP_MAX_S (and well under the swarm hang watchdog, which
/// every swarm mind runs under through this launcher too), and leaves a wait longer than that to `poll`, which the
/// TIMEOUT line names. Hosts whose suites run longer raise it; a cut still says what happened and how to go background.
pub const PYRUN_CAP_DEFAULT_S: u32 = 120;

/// Ceiling on NL_PYRUN_TIMEOUT_S. Kept under the swarm hang watchdog's silence threshold (run.zig: HANG_CHECK_S
/// x HANG_STALE_CHECKS = 300 s): past it, one quiet script would get a whole swarm force-halted as "hung" before
/// this launcher ever got round to killing the script — the watchdog doing the cap's job, at far greater cost.
pub const PYRUN_CAP_MAX_S: u32 = 240;

/// NL_PYRUN_TIMEOUT_S → the cap PYRUN is handed. Unset, empty, zero, negative or not a number all mean the
/// default: a typo must never quietly become "no cap" or "cap 0". Past the ceiling it clamps rather than falling
/// back, because an operator who asked for 900 wants long runs — just not unbounded ones.
pub fn pyrunCapS(raw: ?[]const u8) u32 {
    const s = std.mem.trim(u8, raw orelse return PYRUN_CAP_DEFAULT_S, " \t\r\n");
    const n = std.fmt.parseInt(u64, s, 10) catch return PYRUN_CAP_DEFAULT_S; // u64: "99999999999" still clamps
    if (n == 0) return PYRUN_CAP_DEFAULT_S;
    return @intCast(@min(n, PYRUN_CAP_MAX_S));
}

/// PYRUN's first argument: the cap as decimal text, read from the caller's environ the way every other NL_*
/// knob in this file is. Passed on the command line rather than through the child's env so PYRUN never has to
/// re-validate a raw value — pyrunCapS above is the one place that decides what the cap is.
fn pyrunCapArg(environ: *const std.process.Environ.Map, buf: *[10]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{pyrunCapS(environ.get("NL_PYRUN_TIMEOUT_S"))}) catch unreachable;
}

/// How much of a PYRUN call's stdout and stderr is kept at EACH end (bounded.run's head_tail): a script printing more
/// still runs to its own exit, and what lies between the two ends is counted in one line instead of kept.
const PYRUN_STDOUT_MAX: usize = 256 << 10;
const PYRUN_STDERR_MAX: usize = 64 << 10;

/// The bound on a whole PYRUN call (bounded.run): the cap PYRUN is handed, its 5 s grace for held pipes, and room for
/// the interpreter to start and print. PYRUN keeps its own cap; this one catches what it cannot, the launcher itself
/// stuck. It used to run under std.process.run with no bound at all.
fn pyrunBoundMs(environ: *const std.process.Environ.Map) u64 {
    return (@as(u64, pyrunCapS(environ.get("NL_PYRUN_TIMEOUT_S"))) + 30) * 1000;
}

/// One PYRUN call, as run_python and a made tool both make it. head_tail, so a script printing past PYRUN_STDOUT_MAX
/// runs to its own exit and the reply keeps `exit=N`, which the failure graders key on (run.zig toolHardFail, the chat
/// engine's tool_perf). Stopped at the limit instead, it answered a "STOPPED:" line with no exit code, which both read
/// as a success. Under std.process.run before that, the same print answered "python failed to run" (its
/// StreamTooLong); measured 2026-10-21 with a 300 KB print.
fn pyrunRun(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, workdir: []const u8, env: *const std.process.Environ.Map, environ: *const std.process.Environ.Map) bounded.Result {
    return bounded.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = workdir }, .environ_map = env, .bound_ms = pyrunBoundMs(environ), .stdout_limit = PYRUN_STDOUT_MAX, .stderr_limit = PYRUN_STDERR_MAX, .head_tail = true });
}

/// The exit a PYRUN reply states: the script's own; 124 for a launcher killed at its bound, as run_shell and PYRUN's
/// own cap hit state it; else 255.
fn pyrunExit(r: *const bounded.Result) u32 {
    return switch (r.end) {
        .exited => r.code,
        .killed => 124,
        else => 255,
    };
}

/// What a PYRUN reply adds after stderr when the launcher did not reach its own end, gpa-owned ("" otherwise): for a
/// launcher still running at pyrunBoundMs, a TIMEOUT line in the shape of run_shell's and of PYRUN's own cap hit.
fn pyrunNote(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, r: *const bounded.Result) []const u8 {
    return switch (r.end) {
        .killed => std.fmt.allocPrint(gpa, "\nTIMEOUT: the run_python cap is {d} s, and this run was still going {d} s in, past the cap and its grace, so it was killed with everything it started; the output above is all of it that reached this call. A timeout= inside your code cannot raise this cap. Split the work into shorter runs, or start a long job in the background with its output sent to a file and watch that file with poll.", .{ pyrunCapS(environ.get("NL_PYRUN_TIMEOUT_S")), pyrunBoundMs(environ) / 1000 }) catch "",
        .unread => std.fmt.allocPrint(gpa, "\n(this call could not read the run's output to its end ({s}), so it was stopped with everything it started)", .{r.why()}) catch "",
        else => "",
    };
}

/// The engine-owned RUNTIME SMOKE TEST — does the deliverable actually RUN, not just pass presence checks? Run
/// once per round (cwd = workdir) via `python -c SMOKE_PY`. It finds the most likely server entry (a .py that
/// imports http.server/socketserver and has a `__main__`), launches it on a FREE port (passed as AINET_PORT/PORT
/// env), waits for it to bind, probes `GET /`, then tears it down — capturing whether it STARTED, what it SERVED,
/// and the stderr if it crashed on launch. This is the ground truth a unit/presence benchmark misses: a server
/// that `assertIn("http.server", src)` passes but `ModuleNotFoundError`s the moment you run it. Pure stdlib;
/// bounded (~6s start wait + 2s probe + 3s teardown); returns {"status":"no-server"} when nothing runnable exists
/// (so non-web builds are never penalized). Never throws (any failure → status error / started:false).
pub const SMOKE_PY =
    \\import sys,os,json,socket,subprocess,time,glob,re
    \\try: import urllib.request as U
    \\except Exception: U=None
    \\def out(d): sys.stdout.write(json.dumps(d)+"\n"); sys.exit(0)
    \\def discover_routes():
    \\    # DISCOVER the deliverable's OWN routes from its source (regex/format-tolerant: r"/api/x$",
    \\    # /api/x/(?P<id>..)) rather than probing a hardcoded route list from some other app. General floor:
    \\    # any api-shaped path prefix the built code declares, plus GET / for the page.
    \\    routes=set()
    \\    for p in glob.glob("**/*.py",recursive=True)+glob.glob("**/*.js",recursive=True):
    \\        if "__pycache__" in p: continue
    \\        try: t=open(p,encoding="utf-8",errors="replace").read()
    \\        except Exception: continue
    \\        for m in re.findall(r'/(?:api|auth|v1|v2|rest|graphql|health|oauth)[A-Za-z0-9_./-]*', t):
    \\            r=m.rstrip("/")
    \\            if r and " " not in r: routes.add(r)
    \\    return sorted(routes,key=lambda r:(0 if r.startswith("/api") else 1,r.count("/"),len(r)))
    \\try:
    \\    cands=[]
    \\    for p in glob.glob("**/*.py",recursive=True):
    \\        b=os.path.basename(p)
    \\        if b.startswith(("spec_test","test_","_")) or b.endswith("_test.py") or "/test" in p.replace(os.sep,"/"): continue
    \\        try: t=open(p,encoding="utf-8",errors="replace").read()
    \\        except Exception: continue
    \\        if ("http.server" in t or "socketserver" in t or "BaseHTTPRequestHandler" in t or "wsgiref" in t) and "__main__" in t:
    \\            cands.append(p.replace(os.sep,"/"))
    \\    if not cands:
    \\        errs=[]
    \\        for q in glob.glob("**/*.py",recursive=True):
    \\            if "__pycache__" in q: continue
    \\            try: compile(open(q,encoding="utf-8",errors="replace").read(),q,"exec")
    \\            except SyntaxError as e: errs.append("%s:%s %s"%(os.path.basename(q),getattr(e,"lineno","?"),(e.msg or "")[:50]))
    \\            except Exception: pass
    \\        if errs: out({"status":"cli","ok":False,"note":"syntax error: "+"; ".join(errs[:3])})
    \\        tf=[q for q in glob.glob("**/*.py",recursive=True) if "__pycache__" not in q and os.path.basename(q)!="spec_test.py" and (os.path.basename(q).startswith("test_") or os.path.basename(q).endswith("_test.py"))]
    \\        if tf:
    \\            try:
    \\                pr=subprocess.run([sys.executable,"-m","pytest","-q","--no-header","-x"]+tf,capture_output=True,text=True,timeout=60)
    \\                if pr.returncode!=0:
    \\                    ls=[l for l in (pr.stdout or pr.stderr or "").strip().splitlines() if l.strip()]
    \\                    out({"status":"cli","ok":False,"note":"pytest failed: "+(ls[-1] if ls else "see output")[:80]})
    \\            except Exception as e: out({"status":"cli","ok":True,"note":"pytest skipped: "+str(e)[:40]})
    \\        out({"status":"cli","ok":True})
    \\    entry=sorted(cands,key=lambda p:(p.count("/"),len(p)))[0]
    \\    esrc=open(entry,encoding="utf-8",errors="replace").read()
    \\    rel=re.search(r'^\s*from\s+\.',esrc,re.M) is not None
    \\    if ("/" in entry) and rel:
    \\        mod=entry[:-3].replace("/",".") if entry.endswith(".py") else entry.replace("/",".")
    \\        cmd=[sys.executable,"-m",mod]; how="-m "+mod
    \\    else:
    \\        cmd=[sys.executable,entry]; how=entry
    \\    s=socket.socket(); s.bind(("127.0.0.1",0)); port=s.getsockname()[1]; s.close()
    \\    env=dict(os.environ); env["AINET_PORT"]=str(port); env["PORT"]=str(port); env["PYTHONPATH"]=os.getcwd()+os.pathsep+env.get("PYTHONPATH","")
    \\    try: proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
    \\    except Exception as e: out({"status":"ok","entry":entry,"how":how,"started":False,"served":None,"stderr":("launch failed: "+str(e))[:300]})
    \\    started=False; t0=time.time()
    \\    while time.time()-t0<6:
    \\        try: c=socket.create_connection(("127.0.0.1",port),0.3); c.close(); started=True; break
    \\        except OSError:
    \\            if proc.poll() is not None: break
    \\            time.sleep(0.2)
    \\    served=None; api_ok=True; api_note=""; routes=discover_routes()
    \\    if started and U is not None:
    \\        try: r=U.urlopen("http://127.0.0.1:%d/"%port,timeout=2); served=r.status
    \\        except Exception as e: served="err:"+str(e)[:50]
    \\        saw2=False; saw5=False
    \\        probe=[r for r in routes if r!="/"] or ["/api"]
    \\        for ap in probe[:8]:
    \\            try:
    \\                rr=U.urlopen("http://127.0.0.1:%d%s"%(port,ap),timeout=2); c=rr.status
    \\                if c<300: saw2=True; api_note="%s -> %d"%(ap,c); break
    \\                if c>=500: saw5=True; api_note="%s -> %d"%(ap,c)
    \\            except Exception as e:
    \\                c=getattr(e,"code",None)
    \\                if c is not None and c<500: saw2=True; api_note="%s -> %d"%(ap,c); break
    \\                if (c is None) or c>=500: saw5=True; api_note="%s -> %s"%(ap,("HTTP %d"%c) if c else ("crash:"+str(getattr(e,"reason",e) or e)[:40]))
    \\        api_ok = saw2 or (not saw5)
    \\    try: proc.terminate(); proc.wait(timeout=3)
    \\    except Exception:
    \\        try: proc.kill()
    \\        except Exception: pass
    \\    err=""
    \\    try: err=(proc.stderr.read() or b"").decode("utf-8","replace")[-300:]
    \\    except Exception: pass
    \\    out({"status":"ok","entry":entry,"how":how,"started":started,"served":served,"api_ok":api_ok,"api_note":api_note,"routes":len(routes),"stderr":err.strip()[-300:]})
    \\except Exception as e:
    \\    out({"status":"error","msg":str(e)[:160]})
;
/// INTERFACE RECONCILIATION (`python -c INTERFACES_PY`, cwd = workdir): a lightweight static check across all the
/// project's .py files for the #1 parallel multi-file build bug — two minds building interdependent files that
/// don't agree on a contract (observed: app.py calls handlers.get_feed() while handlers.py defines handle_feed()).
/// Parses each module with ast, collects the top-level def/class names it DEFINES, then flags every `module.attr`
/// reference whose `module` is a local file but whose `attr` is NOT defined there (with a difflib "did you mean"),
/// plus any file that fails to parse (a syntax error breaks the whole build). Prints ONE JSON line; never throws.
///
/// The contract is SIGNATURE-level, not just name-level: exports publish each function as `name(a, b=?, *args)`
/// so builders see the real parameter list, and every cross-module CALL is checked against the def's arity and
/// keyword names (e.g. start_server(host=..) vs def start_server(), init_db() vs def init_db(db_path)). The def
/// stays canonical; a call with extra positionals, an unknown keyword, or a missing required argument is reported.
pub const INTERFACES_PY =
    \\import ast,os,glob,json,sys,difflib
    \\def out(d): sys.stdout.write(json.dumps(d)+"\n"); sys.exit(0)
    \\def modbase(mod):
    \\    return (mod or "").strip(".").split(".")[-1]
    \\def siginfo(fn):
    \\    a=fn.args
    \\    pos=[x.arg for x in a.posonlyargs+a.args]
    \\    req=pos[:len(pos)-len(a.defaults)] if a.defaults else pos[:]
    \\    kwonly=[x.arg for x in a.kwonlyargs]
    \\    kwreq=[x.arg for x,d in zip(a.kwonlyargs,a.kw_defaults) if d is None]
    \\    return {"pos":pos,"req":req,"kwonly":kwonly,"kwreq":kwreq,"var":a.vararg is not None,"kw":a.kwarg is not None,"dec":bool(fn.decorator_list)}
    \\def sigstr(name,si):
    \\    ps=[p if i<len(si["req"]) else p+"=?" for i,p in enumerate(si["pos"])]
    \\    if si["var"]: ps.append("*args")
    \\    ps+= [k if k in si["kwreq"] else k+"=?" for k in si["kwonly"]]
    \\    if si["kw"]: ps.append("**kw")
    \\    return name+"("+", ".join(ps)+")"
    \\try:
    \\    defs={}; srcs={}; sigs={}
    \\    for p in glob.glob("**/*.py",recursive=True):
    \\        if "__pycache__" in p: continue
    \\        try: s=open(p,encoding="utf-8",errors="replace").read()
    \\        except Exception: continue
    \\        srcs[p]=s
    \\        base=os.path.basename(p)[:-3]
    \\        try: t=ast.parse(s)
    \\        except SyntaxError: continue
    \\        ns=set()
    \\        for n in t.body:
    \\            if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)):
    \\                ns.add(n.name); sigs.setdefault(base,{})[n.name]=siginfo(n)
    \\            elif isinstance(n,ast.ClassDef): ns.add(n.name)
    \\            elif isinstance(n,ast.Assign):
    \\                for tg in n.targets:
    \\                    if isinstance(tg,ast.Name): ns.add(tg.id)
    \\            elif isinstance(n,ast.AnnAssign) and isinstance(n.target,ast.Name): ns.add(n.target.id)
    \\        defs[base]=defs.get(base,set())|ns
    \\    issues=[]; missing={}
    \\    def demand(mb,name):
    \\        missing.setdefault(mb,set()).add(name)
    \\    def argcheck(caller,mb,fname,call):
    \\        si=sigs.get(mb,{}).get(fname)
    \\        if not si: return
    \\        if si["dec"]: return  # a decorator can rewrite the signature (e.g. inject a conn arg) — the raw def is not the call contract
    \\        if any(isinstance(x,ast.Starred) for x in call.args): return
    \\        kwn=[k.arg for k in call.keywords]
    \\        if None in kwn: return
    \\        probs=[]
    \\        npos=len(call.args); maxpos=len(si["pos"])
    \\        if npos>maxpos and not si["var"]: probs.append("takes at most "+str(maxpos)+" positional argument(s), got "+str(npos))
    \\        for k in kwn:
    \\            if k not in si["pos"] and k not in si["kwonly"] and not si["kw"]: probs.append("unexpected keyword '"+k+"'")
    \\        covered=set(si["pos"][:min(npos,maxpos)])|set(kwn)
    \\        miss=[r for r in si["req"] if r not in covered]+[r for r in si["kwreq"] if r not in kwn]
    \\        if miss: probs.append("missing required argument(s): "+", ".join(miss))
    \\        if probs: issues.append(caller+" calls "+mb+"."+fname+" — "+"; ".join(probs)+". The def is canonical: call it as "+sigstr(fname,si))
    \\    for p,s in srcs.items():
    \\        b=os.path.basename(p)
    \\        try: t=ast.parse(s)
    \\        except SyntaxError as e: issues.append(b+": SYNTAX ERROR line "+str(getattr(e,"lineno","?"))+" — the file does not parse, so every importer of it breaks"); continue
    \\        alias2mod={}; name2modfn={}
    \\        shadow=set()  # names re-bound in this file (params, lambda args, assignments) — a `store` PARAM is not the store module
    \\        for n in ast.walk(t):
    \\            if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef,ast.Lambda)):
    \\                aa=n.args
    \\                for x in aa.posonlyargs+aa.args+aa.kwonlyargs: shadow.add(x.arg)
    \\                if aa.vararg: shadow.add(aa.vararg.arg)
    \\                if aa.kwarg: shadow.add(aa.kwarg.arg)
    \\            elif isinstance(n,ast.Assign):
    \\                for tg in n.targets:
    \\                    if isinstance(tg,ast.Name): shadow.add(tg.id)
    \\            elif isinstance(n,(ast.For,ast.AsyncFor)) and isinstance(n.target,ast.Name): shadow.add(n.target.id)
    \\        for n in ast.walk(t):
    \\            if isinstance(n,ast.ImportFrom):
    \\                mb=modbase(n.module)
    \\                if mb in defs and mb!=b[:-3]:
    \\                    for a in n.names:
    \\                        if a.name=="*": continue
    \\                        if a.name in defs:  # `from pkg import submodule`
    \\                            alias2mod[a.asname or a.name]=a.name; continue
    \\                        if a.name in defs[mb]: name2modfn[a.asname or a.name]=(mb,a.name)
    \\                        if a.name not in defs[mb] and not a.name.startswith("_"):
    \\                            demand(mb,a.name)
    \\                            sug=difflib.get_close_matches(a.name,[d for d in defs[mb] if not d.startswith("_")],1,0.4)
    \\                            issues.append(b+" imports "+a.name+" from "+mb+" but "+mb+".py defines no such name"+((" (did you mean "+sug[0]+"?)") if sug else ""))
    \\            elif isinstance(n,ast.Import):
    \\                for a in n.names:
    \\                    mb=modbase(a.name)
    \\                    if mb in defs: alias2mod[a.asname or mb]=mb
    \\        for n in ast.walk(t):
    \\            if isinstance(n,ast.Attribute) and isinstance(n.value,ast.Name):
    \\                m=n.value.id
    \\                if m in shadow: continue
    \\                mb=alias2mod.get(m)
    \\                if mb and mb!=b[:-3] and n.attr not in defs[mb] and not n.attr.startswith("_") and defs[mb]:
    \\                    demand(mb,n.attr)
    \\                    sug=difflib.get_close_matches(n.attr,[d for d in defs[mb] if not d.startswith("_")],1,0.4)
    \\                    issues.append(b+" uses "+m+"."+n.attr+"() but "+mb+".py defines no such name"+((" (did you mean "+sug[0]+"?)") if sug else ""))
    \\        for n in ast.walk(t):
    \\            if not isinstance(n,ast.Call): continue
    \\            f=n.func
    \\            if isinstance(f,ast.Attribute) and isinstance(f.value,ast.Name):
    \\                if f.value.id in shadow: continue
    \\                mb=alias2mod.get(f.value.id)
    \\                if mb and mb!=b[:-3]: argcheck(b,mb,f.attr,n)
    \\            elif isinstance(f,ast.Name) and f.id in name2modfn and f.id not in shadow:
    \\                mb,orig=name2modfn[f.id]; argcheck(b,mb,orig,n)
    \\    issues=sorted(set(issues))[:12]
    \\    exports={}
    \\    for base,ns in defs.items():
    \\        pub=[(sigstr(n,sigs[base][n]) if n in sigs.get(base,{}) else n) for n in sorted(ns) if not n.startswith("_")]
    \\        if pub: exports[base]=pub
    \\    demanded={m:sorted(v) for m,v in missing.items()}
    \\    out({"mismatches":issues,"count":len(issues),"exports":exports,"demanded":demanded})
    \\except Exception as e:
    \\    out({"mismatches":[],"count":0,"err":str(e)[:120]})
;
/// Read cell (x,y) from a hidden grid stored as a JSON array-of-rows (`[[...],[...]]`, row-major: rows[y][x]).
/// Returns the cell value as a plain string (strings unquoted; numbers/bools formatted; anything else stringified).
/// Caller frees. null when the grid isn't a 2D array or (x,y) is out of bounds — the spatial substrate's only
/// perception primitive, so it must never throw on a malformed `space` (a bad deploy degrades to "out of bounds").
fn probeCell(gpa: std.mem.Allocator, space: []const u8, x: usize, y: usize) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, space, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    const rows = parsed.value.array;
    if (y >= rows.items.len) return null;
    const row = rows.items[y];
    if (row != .array) return null;
    const cols = row.array;
    if (x >= cols.items.len) return null;
    return switch (cols.items[x]) {
        .string => |s| gpa.dupe(u8, s) catch null,
        .integer => |n| std.fmt.allocPrint(gpa, "{d}", .{n}) catch null,
        .float => |f| std.fmt.allocPrint(gpa, "{d}", .{f}) catch null,
        .bool => |b| gpa.dupe(u8, if (b) "true" else "false") catch null,
        .null => gpa.dupe(u8, "null") catch null,
        else => std.json.Stringify.valueAlloc(gpa, cols.items[x], .{}) catch null,
    };
}

/// Collapse tabs/newlines/CRs to spaces and clip — a value written into a single neuron-db record line must not
/// contain a tab or newline (those are field/record separators the CLI rejects). Caller frees.
fn oneLine(gpa: std.mem.Allocator, s: []const u8) []u8 {
    const out = gpa.dupe(u8, clip(s, 200)) catch return dupe(gpa, "?");
    for (out) |*c| if (c.* == '\t' or c.* == '\n' or c.* == '\r') {
        c.* = ' ';
    };
    return out;
}

fn lastNonEmptyLine(s: []const u8) []const u8 {
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\n\t");
        if (t.len > 0) last = t;
    }
    return last;
}

fn parseTaggedRound(s: []const u8) ?u32 {
    const k = "round=";
    const at = std.mem.indexOf(u8, s, k) orelse return null;
    const rest = s[at + k.len ..];
    var n: usize = 0;
    while (n < rest.len and rest[n] >= '0' and rest[n] <= '9') : (n += 1) {}
    if (n == 0) return null;
    return std.fmt.parseInt(u32, rest[0..n], 10) catch null;
}

fn proposalHasMetric(p: []const u8) bool {
    const tag = " | metric=";
    const at = std.mem.indexOf(u8, p, tag) orelse return false;
    const rest = p[at + tag.len ..];
    if (rest.len == 0) return false;
    const end = std.mem.indexOf(u8, rest, " | ") orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \r\n\t").len >= 4;
}

fn pathLooksPrivileged(rel: []const u8) bool {
    if (rel.len == 0) return false;
    const priv = [_][]const u8{
        "src/auth/",
        "src/config/key_vault.zig",
        "src/plan/billing",
        "src/plan/entitlements",
        "src/worker/run.zig",
        "src/worker/llm.zig",
        "src/main.zig",
        "src/worker/control/supervisor.zig",
    };
    for (priv) |p| if (std.mem.startsWith(u8, rel, p)) return true;
    return false;
}

fn patchSystemTouchesPrivileged(mode: []const u8, path: []const u8, patch: []const u8) bool {
    if (!std.mem.eql(u8, mode, "patch")) return pathLooksPrivileged(path);
    const hints = [_][]const u8{
        "src/auth/",
        "src/config/key_vault.zig",
        "src/plan/billing",
        "src/plan/entitlements",
        "src/worker/run.zig",
        "src/worker/llm.zig",
        "src/main.zig",
        "src/worker/control/supervisor.zig",
    };
    for (hints) |h| if (std.mem.indexOf(u8, patch, h) != null) return true;
    return false;
}

fn patchSystemHighImpact(mode: []const u8, path: []const u8, content: []const u8, patch: []const u8) bool {
    if (std.mem.eql(u8, mode, "patch")) return true;
    if (content.len > 1600) return true;
    if (patch.len > 2000) return true;
    if (std.mem.startsWith(u8, path, "src/worker/")) return true; // now covers the former src/orchestrate/* (moved under worker/{chat,control,deploy,neuron}/)
    if (std.mem.startsWith(u8, path, "src/auth/")) return true;
    return false;
}

/// The patch_system root. An explicit NL_PATCH_SYSTEM_ROOT (or legacy NL_OPEN_CLAW_ROOT) env wins; otherwise
/// it defaults to the engine's OWN source root (ctx.patch_root, resolved from the executable path at startup)
/// — so RSI self-modification is ON by default: a mind is the root of its own VM. Returns null only if a
/// default could not be resolved at all (e.g. a binary-only install with no source tree beside it), in which
/// case the tool degrades gracefully to "disabled" rather than pointing at nothing.
fn patchSystemRoot(ctx: *ToolCtx) ?[]const u8 {
    if (ctx.environ.get("NL_PATCH_SYSTEM_ROOT")) |r| {
        const t = std.mem.trim(u8, r, " \r\n\t");
        if (t.len > 0) return t;
    }
    if (ctx.environ.get("NL_OPEN_CLAW_ROOT")) |r| {
        const t = std.mem.trim(u8, r, " \r\n\t");
        if (t.len > 0) return t;
    }
    const d = std.mem.trim(u8, ctx.patch_root, " \r\n\t");
    return if (d.len == 0) null else d;
}

fn patchSystemPathAllowed(rel: []const u8) bool {
    const blocked = [_][]const u8{
        ".git/",
        ".zig-cache/",
        "zig-out/",
        "data/",
        "terraform/.terraform/",
    };
    for (blocked) |p| {
        if (std.mem.startsWith(u8, rel, p)) return false;
    }
    return true;
}

fn replaceOne(gpa: std.mem.Allocator, src: []const u8, find: []const u8, repl: []const u8) ?[]u8 {
    if (find.len == 0) return null;
    const at = std.mem.indexOf(u8, src, find) orelse return null;
    if (std.mem.indexOfPos(u8, src, at + find.len, find) != null) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, src[0..at]) catch return null;
    out.appendSlice(gpa, repl) catch return null;
    out.appendSlice(gpa, src[at + find.len ..]) catch return null;
    return out.toOwnedSlice(gpa) catch null;
}

pub fn safeRel(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[0] == '\\' or p[0] == '~') return false;
    // a drive colon ("C:/...") or NTFS ADS colon is NOT workdir-relative — without this a Windows absolute
    // path slipped past as "relative", got joined under the workdir, and read as a confusing "not found"
    // (and the roam branch for client-side absolute reads never fired).
    if (std.mem.indexOfScalar(u8, p, ':') != null) return false;
    if (std.mem.indexOf(u8, p, "..") != null) return false;
    return true;
}

test "safeRel: relative only — rejects absolute, drive-colon, home, traversal" {
    try std.testing.expect(safeRel("index.html"));
    try std.testing.expect(safeRel("css/style.css"));
    try std.testing.expect(!safeRel("/abs/path"));
    try std.testing.expect(!safeRel("\\abs"));
    try std.testing.expect(!safeRel("C:/data/x.csv"));
    try std.testing.expect(!safeRel("C:\\data\\x.csv"));
    try std.testing.expect(!safeRel("~/notes.txt"));
    try std.testing.expect(!safeRel("a/../b"));
    try std.testing.expect(!safeRel(""));
}

/// True when `p`'s BASENAME is a reserved OPERATE-bus / oracle file — the command bus (commands.jsonl), the
/// device telemetry (telemetry.json), the staged-action ledger (staged.jsonl), the read-only exploration lanes
/// (explore.jsonl / explore_results.jsonl), the acceptance oracle (score.json), and the app-attach manifests
/// (verbs.json / app.json). These are the seam through which a mind actuates and is GRADED on an attached
/// host. A mind must reach them ONLY through the guarded host_* tools: writing commands.jsonl with write_file
/// would ACTUATE the host un-adjudicated (bypassing stageAction), and writing score.json would FORGE the mind's
/// own fitness. Callers gate this on operate/app-attach mode (ctx.operating/ctx.app_attach) so a NORMAL build
/// can still ship an ordinary app.json / score.json deliverable — the reservation bites only where the bus is
/// live. Case- and separator-insensitive on the basename, so "commands.jsonl" and "work/commands.jsonl" match.
pub fn reservedBusName(p: []const u8) bool {
    var base = p;
    if (std.mem.lastIndexOfAny(u8, p, "/\\")) |i| base = p[i + 1 ..];
    const reserved = [_][]const u8{
        "commands.jsonl", "commands.json",         "telemetry.json",       "staged.jsonl",
        "explore.jsonl",  "explore_results.jsonl", "explore_results.json", "score.json",
        "verbs.json",     "app.json",
    };
    for (reserved) |r| if (std.ascii.eqlIgnoreCase(base, r)) return true;
    return false;
}

test "reservedBusName: the operate bus + oracle files are reserved, ordinary deliverables are not" {
    // the actuation bus and the fitness oracle — the two that turn a file write into an un-gated host action
    try std.testing.expect(reservedBusName("commands.jsonl"));
    try std.testing.expect(reservedBusName("score.json"));
    // a workdir-prefixed form matches the same basename (the bypass must not walk around the guard)
    try std.testing.expect(reservedBusName("work/commands.jsonl"));
    try std.testing.expect(reservedBusName("telemetry.json"));
    try std.testing.expect(reservedBusName("STAGED.JSONL")); // case-insensitive
    try std.testing.expect(reservedBusName("explore_results.jsonl"));
    // ordinary build deliverables are never reserved (the guard is mode-gated by the caller anyway)
    try std.testing.expect(!reservedBusName("index.html"));
    try std.testing.expect(!reservedBusName("src/main.py"));
    try std.testing.expect(!reservedBusName("package.json"));
    try std.testing.expect(!reservedBusName("data/results.json"));
}

/// run.zig's builtInManifest key convention, mirrored: a probe carrying a directory ('/' or '\\') matches
/// `entry` only by FULL separator-blind path; a bare probe matches by whole basename (minds often write bare
/// filenames while slices/manifest carry full blueprint paths). Pure basename matching collapses same-named
/// siblings (five mod.rs in a Rust tree, five __init__.py in a Python package) into ONE identity, misfiring
/// every guard keyed on it. A leading "./" on the probe is noise, not a directory.
fn pathKeyMatch(entry: []const u8, probe: []const u8) bool {
    var pr = probe;
    while (std.mem.startsWith(u8, pr, "./")) pr = pr[2..];
    if (entry.len == 0 or pr.len == 0) return false;
    const has_dir = std.mem.indexOfScalar(u8, pr, '/') != null or std.mem.indexOfScalar(u8, pr, '\\') != null;
    if (!has_dir) return std.mem.eql(u8, std.fs.path.basename(entry), pr);
    if (entry.len != pr.len) return false;
    for (entry, pr) |x, y| {
        const xn: u8 = if (x == '\\') '/' else x;
        const yn: u8 = if (y == '\\') '/' else y;
        if (xn != yn) return false;
    }
    return true;
}

/// True if a file matching `path` (pathKeyMatch: full path when it carries a directory, else basename) was
/// already written this run (recorded in run_dir/.build_manifest as "path|bytes" lines). The engine-
/// authoritative record — avoids a racy filesystem stat. Used by writeFile's round-2+ coverage rescue: a
/// teammate's file that does NOT exist yet may be created by anyone — and a built same-named SIBLING must
/// not veto rescuing the one that is genuinely missing.
fn builtAlready(ctx: *ToolCtx, path: []const u8) bool {
    const gpa = ctx.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{ctx.run_dir}) catch return false;
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, mpath, gpa, .limited(64 << 10)) catch return false;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const fp = std.mem.trim(u8, ln[0..bar], " \r\t");
        if (fp.len > 0 and pathKeyMatch(fp, path)) return true;
    }
    return false;
}

/// The teammate (not this mind) whose write already LANDED on `path` THIS round, per the
/// run_dir/.round_writes ledger ("round|mind|path" lines, appended on every successful write/edit).
/// null when nobody has. This is the same-round serialization record: ownership guards decide who MAY
/// write, this records who DID, so two minds with an equally legitimate claim on one hot file don't clobber
/// each other's landed repair by landing full rewrites seconds apart. gpa-owned name when non-null; caller frees.
fn sameRoundWriter(ctx: *ToolCtx, path: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    const rp = std.fmt.allocPrint(gpa, "{s}/.round_writes", .{ctx.run_dir}) catch return null;
    defer gpa.free(rp);
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, rp, gpa, .limited(256 << 10)) catch return null;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        var f = std.mem.splitScalar(u8, ln, '|');
        const r = f.next() orelse continue;
        const m = std.mem.trim(u8, f.next() orelse continue, " \r");
        const p2 = std.mem.trim(u8, f.rest(), " \r");
        const rn = std.fmt.parseInt(u32, std.mem.trim(u8, r, " \r"), 10) catch continue;
        if (rn != ctx.round or m.len == 0 or p2.len == 0) continue;
        if (std.mem.eql(u8, m, ctx.mind)) continue;
        if (pathKeyMatch(p2, path)) return gpa.dupe(u8, m) catch null;
    }
    return null;
}

/// Append one "round|mind|path" line to the same-round write ledger. Caller holds the files lock
/// (writeFile/editFile call this inside their existing manifest-update critical sections). Best-effort:
/// a failed append never fails the write it records.
fn recordRoundWrite(ctx: *ToolCtx, path: []const u8) void {
    const gpa = ctx.gpa;
    const rp = std.fmt.allocPrint(gpa, "{s}/.round_writes", .{ctx.run_dir}) catch return;
    defer gpa.free(rp);
    const existing = std.Io.Dir.cwd().readFileAlloc(ctx.io, rp, gpa, .limited(256 << 10)) catch &[_]u8{};
    defer if (existing.len > 0) gpa.free(existing);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, existing) catch {};
    if (std.fmt.allocPrint(gpa, "{d}|{s}|{s}\n", .{ ctx.round, ctx.mind, path })) |ln| {
        defer gpa.free(ln);
        buf.appendSlice(gpa, ln) catch {};
    } else |_| {}
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = rp, .data = buf.items }) catch {};
}

/// True if `path` matches a comma+space entry of `list` (the format mindFiles emits) under pathKeyMatch:
/// a bare filename (what minds usually write, e.g. 'errors.py') matches any entry by whole basename — never
/// substring, so 'errors.py' never matches 'myerrors.py' — while a directory-carrying path matches only the
/// entry with that exact path, so owning src/api/__init__.py claims no sibling __init__.py. Used by
/// writeFile's file-partition guard and run.zig's slotless-salvage derivation.
pub fn fileOwnedBy(list: []const u8, path: []const u8) bool {
    if (list.len == 0 or path.len == 0) return false;
    var it = std.mem.splitSequence(u8, list, ", ");
    while (it.next()) |e| {
        const t = std.mem.trim(u8, e, " \r\n\t");
        if (t.len == 0) continue;
        if (pathKeyMatch(t, path)) return true;
    }
    return false;
}
/// True when `path` is the FIRST blueprint entry not yet in the build manifest — the frontier piece of an
/// ordered build. Writing the frontier is by definition not jumping ahead, and an unbuilt file has nothing
/// to clobber — together those two facts open the ordered-deliverable guard for a stuck required file.
/// Lines whose first token carries no '.' (prose/section headers, dirs) are skipped so a non-file line can
/// never become a permanent phantom frontier that keeps the valve shut.
fn isFrontierFile(ctx: *ToolCtx, path: []const u8) bool {
    if (ctx.blueprint.len == 0) return false;
    var it = std.mem.splitScalar(u8, ctx.blueprint, '\n');
    while (it.next()) |line| {
        var s = std.mem.trim(u8, line, " \r\t");
        if (s.len > 0 and (s[0] == '-' or s[0] == '*' or s[0] == '+')) s = std.mem.trim(u8, s[1..], " \r\t");
        var end: usize = 0;
        while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != ':' and s[end] != '`') : (end += 1) {}
        if (end == 0) continue;
        const bp = s[0..end];
        // File-shape mirrors run.zig's fileShapedToken / bpPath accept rule: an extension OR a
        // path-shaped token ('/') marks a real deliverable, so a dotless file under a directory
        // (app/Makefile, api/Dockerfile) can BE the frontier and reach the ordered-guard rescue,
        // while bare prose words still can't become a permanent phantom frontier.
        if (std.mem.indexOfScalar(u8, std.fs.path.basename(bp), '.') == null and
            std.mem.indexOfScalar(u8, bp, '/') == null) continue;
        if (builtAlready(ctx, bp)) continue;
        return pathKeyMatch(bp, path);
    }
    return false;
}

fn blueprintHas(blueprint: []const u8, path: []const u8) bool {
    if (blueprint.len == 0) return false;
    const pb = std.fs.path.basename(path);
    if (pb.len == 0) return false;
    var it = std.mem.splitScalar(u8, blueprint, '\n');
    while (it.next()) |line| {
        var s = std.mem.trim(u8, line, " \r\t");
        if (s.len > 0 and (s[0] == '-' or s[0] == '*' or s[0] == '+')) s = std.mem.trim(u8, s[1..], " \r\t");
        var end: usize = 0;
        while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != ':' and s[end] != '`') : (end += 1) {}
        if (end == 0) continue;
        if (std.mem.eql(u8, std.fs.path.basename(s[0..end]), pb)) return true;
    }
    return false;
}
fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}
fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    // OOM fallback must be ZERO-LENGTH: callers free any result with len > 0, and the old @constCast("error")
    // handed them a 5-byte STATIC string — gpa.free on read-only data (an invalid free / UB) exactly when the
    // allocator was already failing.
    return gpa.dupe(u8, s) catch @constCast(s[0..0]);
}

/// ask_veil — the mind's question to the overseer. It never blocks. The question is appended to
/// {run_dir}/asks.jsonl with a UNIQUE random id (stable across a resume, unlike the event seq); the veil reads
/// pending asks via swarm_asks and answers via answer_swarm (the answer lands in this mind's inbox next round).
fn askVeil(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { question: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "ask_veil: could not parse args");
    defer p.deinit();
    const q = std.mem.trim(u8, p.value.question, " \r\n\t");
    if (q.len == 0) return dupe(gpa, "ask_veil: a question is required");

    var rnd: [6]u8 = undefined;
    ctx.io.random(&rnd);
    const id = std.fmt.bytesToHex(rnd, .lower);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    const line_ok = build: {
        line.appendSlice(gpa, "{\"id\":\"") catch break :build false;
        line.appendSlice(gpa, &id) catch break :build false;
        line.appendSlice(gpa, "\",\"mind\":") catch break :build false;
        llm.jstr(gpa, &line, ctx.mind) catch break :build false;
        const mid = std.fmt.allocPrint(gpa, ",\"round\":{d},\"q\":", .{ctx.round}) catch break :build false;
        defer gpa.free(mid);
        line.appendSlice(gpa, mid) catch break :build false;
        llm.jstr(gpa, &line, q) catch break :build false;
        line.appendSlice(gpa, "}\n") catch break :build false;
        break :build true;
    };
    if (line_ok) {
        const path = std.fmt.allocPrint(gpa, "{s}/asks.jsonl", .{ctx.run_dir}) catch "";
        defer if (path.len > 0) gpa.free(path);
        if (path.len > 0) {
            // read-modify-write append (mirrors the .build_manifest write pattern)
            const existing = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, gpa, .limited(256 << 10)) catch &[_]u8{};
            defer if (existing.len > 0) gpa.free(existing);
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(gpa);
            buf.appendSlice(gpa, existing) catch {};
            buf.appendSlice(gpa, line.items) catch {};
            std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = buf.items }) catch {};
        }
    }
    return dupe(gpa, "Question sent to the veil (the hive's overseer). Proceed with your best assumption for now — the veil's answer will arrive in your inbox on a later round.");
}

test "fileOwnedBy/pathKeyMatch: bare probe = whole basename, path probe = exact sibling only" {
    // bare filename (what minds write) reaches a full-path entry by basename — never substring
    try std.testing.expect(fileOwnedBy("src/todolib/errors.py, src/app.py", "errors.py"));
    try std.testing.expect(!fileOwnedBy("src/todolib/errors.py", "myerrors.py"));
    // a directory-carrying probe claims only ITS path — owning api/__init__.py claims no sibling
    try std.testing.expect(fileOwnedBy("src/api/__init__.py, src/db/models.py", "src/api/__init__.py"));
    try std.testing.expect(!fileOwnedBy("src/api/__init__.py, src/db/models.py", "src/db/__init__.py"));
    try std.testing.expect(fileOwnedBy("src\\api\\__init__.py", "src/api/__init__.py")); // separator-blind
    try std.testing.expect(fileOwnedBy("src/api/__init__.py", "./src/api/__init__.py")); // ./ is noise
    try std.testing.expect(!fileOwnedBy("", "anything.py"));
}

test "isSearchOrAggregator skips engines + social, keeps real outlets" {
    try std.testing.expect(isSearchOrAggregator("html.duckduckgo.com"));
    try std.testing.expect(isSearchOrAggregator("www.bing.com"));
    try std.testing.expect(isSearchOrAggregator("x.com"));
    try std.testing.expect(!isSearchOrAggregator("understandingwar.org"));
    try std.testing.expect(!isSearchOrAggregator("www.reuters.com"));
}

test "looksBlocked flags anti-bot/paywall walls" {
    try std.testing.expect(looksBlocked("{\"code\":451,\"name\":\"SecurityCompromiseError\"}"));
    try std.testing.expect(looksBlocked("Just a moment... verify you are human"));
    try std.testing.expect(!looksBlocked("Ukrainian forces struck a facility on June 27, officials said."));
}

test "isNumeric detects a bare PID target (drives the interlock identifier resolver)" {
    try std.testing.expect(isNumeric("1009"));
    try std.testing.expect(isNumeric("7"));
    try std.testing.expect(!isNumeric(""));
    try std.testing.expect(!isNumeric("sh"));
    try std.testing.expect(!isNumeric("php-fpm"));
    try std.testing.expect(!isNumeric("185.220.101.34"));
    try std.testing.expect(!isNumeric("100a"));
}

test "appendRestartsFile: a restarted attempt is caught; a real continuation appends" {
    // a truncated first attempt + a second attempt glued on via append — a re-attempt, not a continuation
    const attempt1 = "import argparse\nimport json\n\ndef load_tasks():\n    if\n";
    const attempt2 = "import argparse\nimport json\nfrom pathlib import Path\n\ndef main():\n    pass\n";
    try std.testing.expect(appendRestartsFile(attempt1, attempt2));
    try std.testing.expect(appendRestartsFile("#!/usr/bin/env python3\nprint(1)\n", "\n#!/usr/bin/env python3\nprint(2)\n"));
    // a genuine continuation (new functions, different opening line) must still append
    try std.testing.expect(!appendRestartsFile(attempt1, "def save_tasks(tasks):\n    pass\n"));
    // tiny/structural first lines never match (a `}` or docstring quote is not a module header)
    try std.testing.expect(!appendRestartsFile("}\nrest\n", "}\nother\n"));
    try std.testing.expect(!appendRestartsFile("", "import argparse\n"));
    try std.testing.expect(!appendRestartsFile("import argparse\n", ""));
    // SIZE GUARD: a short fragment that re-emits the header is a sloppy continuation, NOT a re-attempt —
    // replacing a large module with it would silently destroy the file. Glue it (repeated import = no-op).
    const big_prior = "import json\n" ++ ("def f():\n    return 1\n\n" ** 12);
    try std.testing.expect(!appendRestartsFile(big_prior, "import json\n\ndef save_tasks(t):\n    pass\n"));
    try std.testing.expect(appendRestartsFile(big_prior, big_prior)); // a full same-size re-attempt still rewrites
}

test "appendRedefines: the duplicate-definition guard learns what a definition is from the file it is given" {
    // THE REPORTED FAILURE, reduced: a surgical edit is rejected, the model appends a corrected copy of ONE
    // function, and appendRestartsFile passes it through (a fragment is far under half the file) — so the glue
    // leaves TWO renderBoards. This was Python-only. It is now language-blind, and stays so: nothing below
    // names a language or an extension.
    const gpa = std.testing.allocator;
    const js = "export function renderBoard(state) {\n  return 1;\n}\nexport function tick() {\n  step();\n}\nexport function pause() {\n  halt();\n}\n";
    try std.testing.expectEqualStrings("export function renderBoard(state) {", appendRedefines(gpa, js, "export function renderBoard(state) {\n  return 2;\n}\n").?);
    try std.testing.expect(appendRedefines(gpa, js, "export function resume() {\n  go();\n}\n") == null); // new name: glue it
    // The SAME rule on a language with different syntax entirely — learned from the text, not configured.
    const zig = "pub fn load(p: []const u8) void {\n    a();\n}\npub fn save(p: []const u8) void {\n    b();\n}\npub fn drop() void {\n    c();\n}\n";
    try std.testing.expectEqualStrings("pub fn save(p: []const u8) void {", appendRedefines(gpa, zig, "pub fn save(p: []const u8) void {\n    fixed();\n}\n").?);
    // …and on one with no braces at all
    const py = "def load(p):\n    a()\ndef save(p):\n    b()\ndef drop():\n    c()\n";
    try std.testing.expectEqualStrings("def save(p):", appendRedefines(gpa, py, "def save(p):\n    fixed()\n").?);

    // WHAT IT LEAVES ALONE, without being told to. A construct the file evidently REPEATS is repeatable:
    // a stylesheet re-opening a selector, or markup with the same block, is ordinary content, not a redefinition.
    const css = ".btn {\n  color: red;\n}\n.btn {\n  border: 0;\n}\n.card {\n  color: blue;\n}\n";
    try std.testing.expect(appendRedefines(gpa, css, ".btn {\n  padding: 0;\n}\n") == null);
    const html = "<div>\n  <p>a</p>\n</div>\n<div>\n  <p>b</p>\n</div>\n";
    try std.testing.expect(appendRedefines(gpa, html, "<div>\n  <p>c</p>\n</div>\n") == null);
    // A leading word the file does not use as a definition word (it heads only this one block) stays out of it.
    const mixed = "title:\n  a\nnotes:\n  b\n";
    try std.testing.expect(appendRedefines(gpa, mixed, "title:\n  c\n") == null);
    // And an append with no column-0 block header in it at all is never the guard's business.
    try std.testing.expect(appendRedefines(gpa, js, "  // a trailing comment\n") == null);
    try std.testing.expect(appendRedefines(gpa, "", "export function tick() {\n  x();\n}\n") == null);
}

test "pyAppendRedefines: a re-attempt that re-defines existing top-level names is caught even with a different opening line" {
    // a second full copy of the module, opening with a DIFFERENT first line (a comment) glued below the
    // first — the first-line restart guard alone would miss it.
    const prior = "\"\"\"User auth.\"\"\"\nimport hashlib\n\ndef register(u, p):\n    pass\n\ndef verify(u, p):\n    pass\n";
    const reattempt = "# src/auth/users.py\nimport os\nimport hashlib\n\ndef register(u, p):\n    pass\n\ndef verify(u, p):\n    return True\n";
    try std.testing.expectEqualStrings("register", pyAppendRedefines(prior, reattempt).?);
    // a genuine continuation adds NEW names only
    try std.testing.expect(pyAppendRedefines(prior, "def get_user(u):\n    pass\n") == null);
    // nested (indented) defs never count as top-level
    try std.testing.expect(pyAppendRedefines(prior, "def wrap():\n    def verify(u, p):\n        pass\n") == null);
    // async + class forms match at column 0
    try std.testing.expectEqualStrings("verify", pyAppendRedefines("async def verify(t):\n    pass\n", "async def verify(t):\n    return 1\n").?);
    try std.testing.expectEqualStrings("Store", pyAppendRedefines("class Store:\n    pass\n", "class Store:\n    x = 1\n").?);
    try std.testing.expect(pyAppendRedefines("", "def a():\n    pass\n") == null);
    // DECORATED repeats are legitimate (@singledispatch.register / @overload) — never flagged, either side
    try std.testing.expect(pyAppendRedefines("from functools import singledispatch\n@singledispatch\ndef convert(x):\n    pass\n", "@convert.register\ndef convert(x: int):\n    return x\n") == null);
    try std.testing.expect(pyAppendRedefines("@overload\ndef f(x):\n    pass\n", "@overload\ndef f(x, y):\n    pass\n") == null);
}

test "jsonParseError: broken JSON gets a line verdict; valid, BOM'd, and JSONC-comment bodies pass" {
    const gpa = std.testing.allocator;
    // valid — object, array, nesting, escapes: silence
    try std.testing.expect(jsonParseError(gpa, "{\"a\": [1, 2, {\"b\": \"\\u00e9\\n\"}], \"c\": null}") == null);
    try std.testing.expect(jsonParseError(gpa, "\xEF\xBB\xBF{\"bom\": true}") == null);
    // JSONC (tsconfig-style comments) is its consumer's language, not ours — first comment byte fails OPEN
    try std.testing.expect(jsonParseError(gpa, "{\n  // compiler options\n  \"strict\": true\n}") == null);
    try std.testing.expect(jsonParseError(gpa, "[1, /* two */ 2]") == null);
    { // truncation — the classic cut-off write — names its line and says so
        const v = jsonParseError(gpa, "{\n  \"a\": 1,\n  \"b\": [2,").?;
        defer gpa.free(v);
        try std.testing.expect(std.mem.startsWith(u8, v, "line 3:"));
        try std.testing.expect(std.mem.indexOf(u8, v, "truncated") != null);
    }
    { // a doubled comma is a plain syntax verdict, not a pass
        const v = jsonParseError(gpa, "{\"a\": 1,, \"b\": 2}").?;
        defer gpa.free(v);
        try std.testing.expect(std.mem.startsWith(u8, v, "line 1:"));
    }
    { // a SECOND top-level value can never be one JSON document (splice corruption signature)
        const v = jsonParseError(gpa, "{\"a\": 1}\n{\"b\": 2}").?;
        defer gpa.free(v);
        try std.testing.expect(std.mem.startsWith(u8, v, "line 2:"));
    }
}

test "jsSyntaxErrLine: node stderr distills to one line-numbered verdict; non-syntax failures fail open" {
    const gpa = std.testing.allocator;
    { // the shape node actually prints (CRLF, echo line, caret, verdict, stack frames, version banner)
        const stderr = "C:\\runs\\x\\.nlchk-3.cjs:2\r\nconst a = {;\r\n           ^\r\n\r\nSyntaxError: Unexpected token ';'\r\n    at wrapSafe (node:internal/modules/cjs/loader:1281:20)\r\nNode.js v20.11.0\r\n";
        const v = jsSyntaxErrLine(gpa, stderr).?;
        defer gpa.free(v);
        try std.testing.expectEqualStrings("line 2: SyntaxError: Unexpected token ';'", v);
    }
    { // a source ECHO line that itself starts with "SyntaxError" must not shadow the real verdict below it
        const stderr = "/tmp/.nlchk-4.mjs:9\nSyntaxError.prototype.x = (\n^\n\nSyntaxError: Unexpected end of input\n    at compileSourceTextModule (node:internal/modules/esm/utils:340:16)\n";
        const v = jsSyntaxErrLine(gpa, stderr).?;
        defer gpa.free(v);
        try std.testing.expectEqualStrings("line 9: SyntaxError: Unexpected end of input", v);
    }
    // no SyntaxError anywhere (bad flag, EACCES, missing file) ⇒ null ⇒ the gate fails OPEN
    try std.testing.expect(jsSyntaxErrLine(gpa, "node: bad option: --wat\n") == null);
    try std.testing.expect(jsSyntaxErrLine(gpa, "Error: EACCES: permission denied, open '/x'\n") == null);
    try std.testing.expect(jsSyntaxErrLine(gpa, "") == null);
}

test "syntaxGateError dispatches by extension: .json rejects natively, ungated extensions pass untouched" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = undefined, // .json validates natively and ungated extensions return before any I/O
        .environ = &env,
        .run_dir = ".",
        .workdir = ".",
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined,
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
    };
    const v = syntaxGateError(&ctx, "cfg/settings.json", "{\"a\": ", "").?;
    defer gpa.free(v);
    try std.testing.expect(std.mem.indexOf(u8, v, "invalid JSON") != null);
    // the same broken bytes under an ungated extension: no verdict, no dispatch, no io touched
    try std.testing.expect(syntaxGateError(&ctx, "notes/readme.md", "{\"a\": ", "") == null);
    try std.testing.expect(syntaxGateError(&ctx, "styles.css", "body { color:", "") == null);
}

test "writeFile soft syntax note: a broken .json overwrite LANDS and warns; appends and valid writes stay quiet" {
    // writeFile drops a few small allocations by design (manifest/ledger lines) — production runs it on the
    // worker's per-turn allocator, so the test mirrors that with an arena instead of the leak-tracking gpa.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-wfgate-it-tmp"; // run_dir, relative to cwd (vcs.zig test idiom)
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa); // never spawns: .json validates natively
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = root,
        .workdir = root ++ "/work",
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined, // the write path is file-only; mem belongs to the observe/recall tools
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
    };
    { // broken overwrite: the bytes LAND (soft gate — write_file never rejects on syntax) and the reply warns
        const out = writeFile(&ctx, "{\"path\": \"cfg.json\", \"content\": \"{\\\"a\\\": 1,\"}");
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "wrote cfg.json") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "does not parse") != null);
        const body = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/work/cfg.json", gpa, .limited(4096));
        defer gpa.free(body);
        try std.testing.expectEqualStrings("{\"a\": 1,", body);
    }
    { // an append is legitimately mid-chunk — no warning even though the glued file happens to parse now
        const out = writeFile(&ctx, "{\"path\": \"cfg.json\", \"content\": \"...\", \"mode\": \"append\"}");
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "appended to cfg.json") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "does not parse") == null);
    }
    { // a valid overwrite stays quiet
        const out = writeFile(&ctx, "{\"path\": \"ok.json\", \"content\": \"{\\\"a\\\": 1}\"}");
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "wrote ok.json") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "does not parse") == null);
    }
}

test "a cut-off write_file LANDS what arrived, and an edit_file tag missing its line number still anchors" {
    // Both halves of one real build failure: a 500-line page whose write_file kept hitting the turn's output
    // ceiling, and the edit that was supposed to repair the tail. writeFile drops a few small allocations by
    // design (manifest/ledger lines), so this mirrors production's per-turn allocator with an arena.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-salvage-it-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa); // .html has no syntax gate — nothing spawns
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = root,
        .workdir = root ++ "/work",
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined,
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
    };
    { // arguments cut off mid-content: the bytes that DID arrive land, and the reply says to append the rest
        const out = writeFile(&ctx, "{\"path\": \"demo.html\", \"content\": \"<!DOCTYPE html>\\n<body>\\n<p>partia");
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "wrote demo.html") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "CUT OFF") != null);
        const body = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/work/demo.html", gpa, .limited(4096));
        defer gpa.free(body);
        try std.testing.expectEqualStrings("<!DOCTYPE html>\n<body>\n<p>partia", body);
    }
    { // the anchor dialect: a read renders `3:abc:def→…` and models routinely send back only `abc:def→…`
        const body = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/work/demo.html", gpa, .limited(4096));
        defer gpa.free(body);
        var lines = try hashline.splitLines(gpa, body);
        defer lines.deinit(gpa);
        var ab: [24]u8 = undefined;
        const full = hashline.renderAnchor(lines.items, 2, &ab); // the `<p>partia` line
        const half = full[std.mem.indexOfScalar(u8, full, ':').? + 1 ..];
        const args = try std.fmt.allocPrint(gpa, "{{\"path\":\"demo.html\",\"ops\":[{{\"op\":\"replace\",\"anchor\":\"{s}\u{2192}<p>partia\",\"text\":\"<p>whole</p>\"}}]}}", .{half});
        defer gpa.free(args);
        const out = editFile(&ctx, args);
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "1 tagged op(s) applied atomically") != null);
        const after = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/work/demo.html", gpa, .limited(4096));
        defer gpa.free(after);
        // the salvaged content had no trailing newline and the edit does not invent one
        try std.testing.expectEqualStrings("<!DOCTYPE html>\n<body>\n<p>whole</p>", after);
    }
    { // a tag whose line has since changed is named as a STALE TAG, never as a missing text snippet
        const out = editFile(&ctx, "{\"path\":\"demo.html\",\"ops\":[{\"op\":\"replace\",\"anchor\":\"wcj:dwp\u{2192}<p>partia\",\"text\":\"x\"}]}");
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "LINE NUMBER") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "removed from the current file") == null);
    }
}

test "balanceError: the structural gate arms itself off the FILE, not off a list of file types" {
    const gpa = std.testing.allocator;
    // Same edit, four unrelated languages, one of them an extension this code has never heard of. Nothing is
    // keyed on the name: each file balances its braces, so each one is gated.
    const cases = [_][2][]const u8{
        .{ "export function f() {\n  return 1;\n}\nexport function g() {\n  return 2;\n}\nexport function h() {\n  return 3;\n}\nexport function i() {\n  return 4;\n}\n", "export function f() {\n  return 1;\nexport function g() {\n  return 2;\n}\nexport function h() {\n  return 3;\n}\nexport function i() {\n  return 4;\n}\n" },
        .{ "pub fn f() void {\n  a();\n}\npub fn g() void {\n  b();\n}\npub fn h() void {\n  c();\n}\npub fn i() void {\n  d();\n}\n", "pub fn f() void {\n  a();\npub fn g() void {\n  b();\n}\npub fn h() void {\n  c();\n}\npub fn i() void {\n  d();\n}\n" },
        .{ ".a {\n  color: red;\n}\n.b {\n  color: blue;\n}\n.c {\n  color: teal;\n}\n.d {\n  color: gray;\n}\n", ".a {\n  color: red;\n.b {\n  color: blue;\n}\n.c {\n  color: teal;\n}\n.d {\n  color: gray;\n}\n" },
        .{ "local t = {\n  x = 1,\n}\nlocal u = {\n  y = 2,\n}\nlocal v = {\n  z = 3,\n}\nlocal w = {\n  q = 4,\n}\n", "local t = {\n  x = 1,\nlocal u = {\n  y = 2,\n}\nlocal v = {\n  z = 3,\n}\nlocal w = {\n  q = 4,\n}\n" },
    };
    for (cases, 0..) |c, i| {
        const e = balanceError(gpa, c[1], c[0]) orelse {
            std.debug.print("\ncase {d}: a dropped '}}' went unnoticed\n", .{i});
            return error.MissedUnbalancedEdit;
        };
        defer gpa.free(e);
        try std.testing.expect(std.mem.indexOf(u8, e, "unclosed") != null);
        try std.testing.expect(balanceError(gpa, c[0], c[0]) == null); // the intact file passes, every time
    }
    { // the mirror case, and parens/brackets are gated on the same terms as braces
        const ok = "(a (b (c)) (d))\n(e (f))\n";
        const e = balanceError(gpa, ok ++ ")\n", ok) orelse return error.MissedExtraDelimiter;
        defer gpa.free(e);
        try std.testing.expect(std.mem.indexOf(u8, e, "unmatched ')'") != null);
    }
    // DISARMED rather than misfiring — the gate only ever fires on a balance the file itself demonstrated.
    const prose = "A note (one) with (two), (three), (four) and a stray ) at the end.\nAnother line.\n";
    try std.testing.expect(balanceError(gpa, prose ++ "and ((( more\n", prose) == null); // never balanced ⇒ never gated
    try std.testing.expect(balanceError(gpa, "fn f() {\n", "") == null); // no baseline: nothing to compare
    const few = "a { x }\nb { y }\n"; // balanced, but too little of it to call a structure
    try std.testing.expect(balanceError(gpa, "a { x\nb { y }\n", few) == null);
    try std.testing.expect(delimiterDepth("const c = '{';\nfn f() {}\n", '{', '}').?.depth == 0); // char literal
    try std.testing.expect(delimiterDepth("// a } in a comment\nfn f() {}\n", '{', '}').?.depth == 0);
    try std.testing.expect(delimiterDepth("a { background: url(http://x/y); }\n", '{', '}').?.depth == 0);
    try std.testing.expect(delimiterDepth("/* unterminated\n{\n", '{', '}') == null); // no verdict beats a wrong one
}

test "chat surface, large file: window-read → copy tag → edit lands surgically (the whole reported failure, end to end)" {
    // THE REPORTED FAILURE, driven through the real tools on a real file: "when a chat tries to edit a large
    // file it typically fails … it ends up creating duplicate lines/methods … corrupting the file and having to
    // rewrite the whole thing". Every assertion here is a step of that spiral, checked at its own link:
    //   1. a window read of a big file WORKS (it used to dead-end past the whole-read ceiling)
    //   2. the window carries copyable tags (the chat ctx never set anchored_reads, so it did not)
    //   3. a tag edit lands surgically — one line changes, the file's line count does not, nothing duplicates
    //   4. the text anchor the model was forced onto instead is genuinely AMBIGUOUS in a repetitive file
    // The ctx below is the chat surface's: anchored_reads + the micro-VCS, exactly as engine.zig builds it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-bigedit-it-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/work", .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var fmtx: std.Io.Mutex = .init;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = root,
        .workdir = root ++ "/work",
        .scope = "test",
        .mind = "chat",
        .round = 0,
        .mem = undefined, // file tools only
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .fmtx = &fmtx,
        .vcs_enabled = true,
        .anchored_reads = true,
    };

    // A file too big to ever see whole, whose lines REPEAT — the shape every real large source has, and the one
    // text anchors cannot address. `.txt` keeps the syntax gate (and its node spawn) out of this test's way.
    var src: std.ArrayListUnmanaged(u8) = .empty;
    var n: usize = 0;
    while (n < 900) : (n += 1) {
        try src.print(gpa, "export function step{d}(x) {{\n  const v = x + 1;\n  return v;\n}}\n\n", .{n});
    }
    const total_lines = std.mem.count(u8, src.items, "\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/work/big.txt", .data = src.items });

    // 1+2. A WINDOW of it reads, headed and tagged. (A whole-file read of the same path is head-clipped — the
    // model is told to window, and windowing must therefore work.)
    const win = readFile(&ctx, "{\"path\":\"big.txt\",\"start_line\":2496,\"end_line\":2500}");
    try std.testing.expect(std.mem.indexOf(u8, win, "[lines 2496-2500 of ") != null);
    try std.testing.expect(std.mem.indexOf(u8, win, "\u{2192}") != null);
    // pull the tag off the line the model would target — exactly what a model copies out of this view
    const marker = std.mem.indexOf(u8, win, "\u{2192}export function step499(x) {") orelse return error.MarkerMissing;
    const line_start = if (std.mem.lastIndexOfScalar(u8, win[0..marker], '\n')) |nl| nl + 1 else 0;
    const tag = win[line_start..marker];
    try std.testing.expect(hashline.isNumberedAnchor(tag)); // a real copyable anchor, not decoration

    // 3. The edit lands: one line replaced, line count untouched, no second copy of anything.
    const args = try std.fmt.allocPrint(gpa, "{{\"path\":\"big.txt\",\"ops\":[{{\"op\":\"replace\",\"anchor\":\"{s}\",\"text\":\"export function step499(y) {{\"}}]}}", .{tag});
    const res = editFile(&ctx, args);
    if (std.mem.indexOf(u8, res, "edited big.txt") == null) {
        std.debug.print("\ntag edit on a large file failed: {s}\n", .{res});
        return error.TagEditRejected;
    }
    const after = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/work/big.txt", gpa, .limited(EDIT_MAX_BYTES));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, "export function step499(y) {"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, "export function step499(x) {"));
    try std.testing.expectEqual(@as(usize, 900), std.mem.count(u8, after, "export function step")); // none lost, none doubled
    try std.testing.expectEqual(total_lines, std.mem.count(u8, after, "\n")); // surgical: no line added or dropped

    // 4. …and the plain-text anchor the model had to use before is exactly as unusable as it felt: the body
    // line it would copy appears 900 times, so the edit cannot be addressed at all without tags.
    const ambiguous = editFile(&ctx, "{\"path\":\"big.txt\",\"ops\":[{\"op\":\"replace\",\"anchor\":\"  const v = x + 1;\",\"text\":\"  const v = x + 2;\"}]}");
    try std.testing.expect(std.mem.indexOf(u8, ambiguous, "more than one place") != null);

    // The tags must never make it back INTO the file, by either route.
    const pasted = try std.fmt.allocPrint(gpa, "{{\"path\":\"big.txt\",\"ops\":[{{\"op\":\"replace\",\"anchor\":\"{s}\",\"text\":\"{s}\\u2192export function step499(z) {{\"}}]}}", .{ tag, tag });
    try std.testing.expect(std.mem.indexOf(u8, editFile(&ctx, pasted), "REJECTED") != null);
    const echoed = try std.fmt.allocPrint(gpa, "{{\"path\":\"echo.txt\",\"content\":\"1:abc:def\\u2192a();\\n2:bcd:def\\u2192b();\\n3:cde:def\\u2192c();\\n\"}}", .{});
    try std.testing.expect(std.mem.indexOf(u8, writeFile(&ctx, echoed), "REJECTED") != null);
}

test "edit_file refuses a multi-line tag anchor instead of splicing its first line, and the range it names lands" {
    // The measured failure (a SWE-bench SymPy run): the model's first edit pasted FIVE tagged lines of a read as
    // ONE anchor. The parser kept the first tag, so the replace swapped line 1 alone for the new block, the four
    // lines it was meant to remove stayed behind as dead code, and the tool answered "applied atomically".
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-spanned-anchor-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root ++ "/work", .default_dir) catch {};
    var env = std.process.Environ.Map.init(gpa); // .txt with no delimiters: no syntax gate arms, nothing spawns
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = root,
        .workdir = root ++ "/work",
        .scope = "test",
        .mind = "chat",
        .round = 0,
        .mem = undefined, // file tools only
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .anchored_reads = true,
    };
    const original = "total = 0\nstep one: load\nstep two: parse\nstep three: render\nstep four: return\nend\n";
    const path = root ++ "/work/steps.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original });

    // The anchor exactly as a model pastes it: the read view's first five lines, tags and content included.
    const view = hashline.renderRead(gpa, original);
    defer gpa.free(view);
    var cut: usize = 0;
    for (0..5) |_| cut = std.mem.indexOfScalarPos(u8, view, cut, '\n').? + 1;
    const block = view[0 .. cut - 1];
    const new_text = "total = 0\nstep: all at once";

    const Op = struct { op: []const u8, anchor: []const u8, text: []const u8 };
    const pasted = try std.json.Stringify.valueAlloc(gpa, .{ .path = "steps.txt", .ops = &[_]Op{.{ .op = "replace", .anchor = block, .text = new_text }} }, .{});
    defer gpa.free(pasted);
    const out = editFile(&ctx, pasted);
    defer gpa.free(out);
    {
        const after = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
        defer gpa.free(after);
        if (!std.mem.eql(u8, original, after)) {
            std.debug.print("\nmulti-line anchor MANGLED the file (tool said: {s})\n--- file now ---\n{s}\n", .{ out[0..@min(out.len, 160)], after });
            return error.FileMangled;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "REJECTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "anchor..end") != null);
    // ...and it hands back the block's own first and last tags, so the retry is a copy rather than a re-read
    var lines = try hashline.splitLines(gpa, original);
    defer lines.deinit(gpa);
    var fb: [24]u8 = undefined;
    var lb: [24]u8 = undefined;
    const first = hashline.renderAnchor(lines.items, 0, &fb);
    const last = hashline.renderAnchor(lines.items, 4, &lb);
    try std.testing.expect(std.mem.indexOf(u8, out, first) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, last) != null);
    // It says what the op would have done only where that is true. The pasted block carries the read view's arrow,
    // so the parser took it as line 1's tag and the op would have landed there alone...
    try std.testing.expect(std.mem.indexOf(u8, out, "would have acted on line 1 alone") != null);
    { // ...while a block of bare tags parses as no tag at all (it only ever met the text matcher's no-match), so
        // the same claim would be false there. Still rejected, with the same range advice and the file untouched.
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        const bare = try std.fmt.allocPrint(gpa, "{s}\n{s}\n{s}", .{ first, hashline.renderAnchor(lines.items, 1, &b1), hashline.renderAnchor(lines.items, 2, &b2) });
        defer gpa.free(bare);
        try std.testing.expect(hashline.parseAnchor(bare) == null); // the premise: nothing to have "acted on"
        const bj = try std.json.Stringify.valueAlloc(gpa, .{ .path = "steps.txt", .ops = &[_]Op{.{ .op = "replace", .anchor = bare, .text = new_text }} }, .{});
        defer gpa.free(bj);
        const bout = editFile(&ctx, bj);
        defer gpa.free(bout);
        try std.testing.expect(std.mem.indexOf(u8, bout, "REJECTED") != null);
        try std.testing.expect(std.mem.indexOf(u8, bout, "anchor..end") != null);
        try std.testing.expect(std.mem.indexOf(u8, bout, "would have acted") == null);
        const still = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
        defer gpa.free(still);
        try std.testing.expectEqualStrings(original, still);
    }

    // Following the advice lands the edit the model meant: lines 1-5 become the new block, line 6 survives.
    const R = struct { op: []const u8, anchor: []const u8, end: []const u8, text: []const u8 };
    const ranged = try std.json.Stringify.valueAlloc(gpa, .{ .path = "steps.txt", .ops = &[_]R{.{ .op = "replace", .anchor = first, .end = last, .text = new_text }} }, .{});
    defer gpa.free(ranged);
    const ok = editFile(&ctx, ranged);
    defer gpa.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "edited steps.txt") != null);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("total = 0\nstep: all at once\nend\n", after);
}

test "jsCheckError via node --check: broken js rejects with a line verdict; ESM-in-.js and valid .cjs pass (skips without node)" {
    const gpa = std.testing.allocator;
    // The REAL process environ, exactly as main.zig builds it — spawned with an empty env map, node aborts
    // in CSPRNG init on Windows (exit 134) before parsing a byte, and every check "passes" open.
    const environ: std.process.Environ = if (@import("builtin").os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();
    var env = environ.createMap(gpa) catch return error.SkipZigTest;
    defer env.deinit();
    { // no node on this machine ⇒ the gate is designed to not exist here — nothing to assert
        const probe = std.process.run(gpa, io, .{ .argv = &.{ "node", "--version" }, .environ_map = &env, .stdout_limit = .limited(256), .stderr_limit = .limited(256), .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } }) catch return error.SkipZigTest;
        defer gpa.free(probe.stdout);
        defer gpa.free(probe.stderr);
        if (probe.term != .exited or probe.term.exited != 0) return error.SkipZigTest;
    }
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = ".", // scratch .nlchk-* files land here and are deleted by the check itself
        .workdir = ".",
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined, // never touched: the gate only stages a scratch file and spawns node
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
    };
    { // a dropped bracket must reject in the same turn, naming the break
        const v = jsCheckError(&ctx, "app.js", "function f() {\n  return [1, 2;\n}\n").?;
        defer gpa.free(v);
        try std.testing.expect(std.mem.indexOf(u8, v, "SyntaxError") != null);
    }
    // an import-style .js is valid in a type:module project — the ESM re-check keeps it editable
    try std.testing.expect(jsCheckError(&ctx, "app.js", "import { x } from './m.js';\nexport const y = x + 1;\n") == null);
    try std.testing.expect(jsCheckError(&ctx, "lib.cjs", "const fs = require('fs');\nmodule.exports = { fs };\n") == null);
    try std.testing.expect(jsCheckError(&ctx, "mod.mjs", "export const one = 1;\n") == null);
    { // broken ESM-style .js: the verdict must name the real break, not the module dialect
        const v = jsCheckError(&ctx, "esm.js", "import { x } from './m.js';\nconst a = {;\n").?;
        defer gpa.free(v);
        try std.testing.expect(std.mem.indexOf(u8, v, "outside a module") == null);
        try std.testing.expect(std.mem.indexOf(u8, v, "SyntaxError") != null);
    }
}

test "wellFormedVerb relays any host verb the situation defines, rejecting only malformed input (FIX 3 — no allow-list)" {
    try std.testing.expect(wellFormedVerb("kill_proc"));
    try std.testing.expect(wellFormedVerb("block_ip"));
    try std.testing.expect(wellFormedVerb("set_phase"));
    try std.testing.expect(wellFormedVerb("patch_verify"));
    try std.testing.expect(wellFormedVerb("replay_attack"));
    try std.testing.expect(wellFormedVerb("rotate-credentials"));
    try std.testing.expect(wellFormedVerb("snapshotVM"));
    try std.testing.expect(!wellFormedVerb(""));
    try std.testing.expect(!wellFormedVerb("2fa_enable"));
    try std.testing.expect(!wellFormedVerb("rm -rf /"));
    try std.testing.expect(!wellFormedVerb("kill;reboot"));
    try std.testing.expect(!wellFormedVerb("a" ** 41));
}

test "poll: gates fire before any observation — bad kind, missing target, sandboxed command" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = undefined, // every gate below returns before I/O
        .environ = &env,
        .run_dir = ".",
        .workdir = ".",
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined,
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
    };
    const bad = pollTool(&ctx, "{\"kind\":\"telepathy\",\"target\":\"x\"}");
    defer gpa.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "kind must be") != null);
    const missing = pollTool(&ctx, "{\"kind\":\"file\"}");
    defer gpa.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "'target' is required") != null);
    ctx.caps = .sandboxed;
    const cmd = pollTool(&ctx, "{\"kind\":\"command\",\"target\":\"echo hi\"}");
    defer gpa.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "not available in this workspace") != null);
}

test "poll file: an already-present pattern matches on the first sample, tail included (real filesystem)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-poll-it-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/build.log", .data = "compiling...\nlinking...\nBUILD SUCCEEDED in 4.2s\n" }) catch unreachable;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var counters = [_]u32{0} ** 6;
    var ctx = ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = root,
        .workdir = root,
        .scope = "test",
        .mind = "test",
        .round = 0,
        .mem = undefined,
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
    };
    const out = pollTool(&ctx, "{\"kind\":\"file\",\"target\":\"build.log\",\"until\":\"BUILD SUCCEEDED\",\"timeout_s\":1,\"interval_s\":1}");
    try std.testing.expect(std.mem.indexOf(u8, out, "-> matched") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "BUILD SUCCEEDED") != null);
    // a swarm poll with no DONE file times out fast and tells the caller to poll again
    const sw = pollTool(&ctx, "{\"kind\":\"swarm\",\"timeout_s\":1,\"interval_s\":1}");
    try std.testing.expect(std.mem.indexOf(u8, sw, "-> timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, sw, "Poll again ONLY if") != null);
}

/// Test-only: a ToolCtx over the REAL process environment (TESTING.md: an empty one leaves a Windows child without
/// SystemRoot/PATH) for the command-poll tests, with the probe seams reset. Pinned in place: the ctx points into it.
const PollFixture = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    counters: [6]u32,

    fn init(f: *PollFixture, gpa: std.mem.Allocator) !void {
        const environ: std.process.Environ = if (builtin.os.tag == .windows)
            .{ .block = .global }
        else
            .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
        f.threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
        f.env = environ.createMap(gpa) catch |e| {
            f.threaded.deinit();
            return e;
        };
        f.counters = .{0} ** 6;
        probe_seam.spawns = 0;
        probe_seam.last_bound_ms = 0;
        probe_seam.sleep_ms = null;
    }
    fn deinit(f: *PollFixture) void {
        probe_seam.sleep_ms = null;
        f.env.deinit();
        f.threaded.deinit();
    }
    /// A fresh cwd-relative dir for a probe that writes files: probes run in the process cwd (TESTING.md's pattern;
    /// the caller defers the deleteTree).
    fn scratch(f: *PollFixture, root: []const u8) void {
        const io = f.threaded.io();
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    }
    fn ctx(f: *PollFixture, gpa: std.mem.Allocator) ToolCtx {
        return .{
            .gpa = gpa,
            .io = f.threaded.io(),
            .environ = &f.env,
            .run_dir = ".",
            .workdir = ".",
            .scope = "test",
            .mind = "test",
            .round = 0,
            .mem = undefined, // a command poll never touches memory
            .files_written = &f.counters[0],
            .observed = &f.counters[1],
            .skills_saved = &f.counters[2],
            .directives_set = &f.counters[3],
            .tools_made = &f.counters[4],
        };
    }
};

test "poll command: a probe with embedded double quotes runs as typed at a prompt, so a nested shell gets its script whole (real shell)" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    var ctx = f.ctx(gpa);
    probe_seam.sleep_ms = 0; // a miss would re-sample at once, not sleep interval_s
    // The live failure's shape: `docker exec <c> bash -lc "tail -n 5 log"` is one program handing a QUOTED script
    // to an inner interpreter. cmd and sh stand in for docker and bash on every host. Before the fix, Windows
    // delivered the script as `\"echo inner ok\"` and the inner cmd answered "is not recognized" on every sample.
    const args = if (builtin.os.tag == .windows)
        \\{"kind":"command","target":"cmd /D /C \"echo inner ok\"","until":"inner ok","timeout_s":30,"interval_s":1}
    else
        \\{"kind":"command","target":"sh -c \"echo inner ok\"","until":"inner ok","timeout_s":30,"interval_s":1}
    ;
    const out = pollTool(&ctx, args);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "-> matched") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "t+0s: exit 0: inner ok") != null);
    if (builtin.os.tag == .windows) {
        // ...and quotes reach the program as typed, not as the argv encoder's `\"two words\"`
        const typed = pollTool(&ctx,
            \\{"kind":"command","target":"echo \"two words\"","timeout_s":30,"interval_s":1}
        );
        defer gpa.free(typed);
        try std.testing.expect(std.mem.indexOf(u8, typed, "exit 0: \"two words\"") != null);
        // ...and a %VAR% inside them expands as at a prompt (cmd expands the NL_POLL_PROBE carrier only once), while
        // an undefined name stays as typed, as a prompt leaves it
        const sys = f.env.get("SystemRoot") orelse return error.SkipZigTest;
        const pct = pollTool(&ctx,
            \\{"kind":"command","target":"echo \"%SystemRoot%\" \"%NL_POLL_NO_SUCH_VAR%\"","timeout_s":30,"interval_s":1}
        );
        defer gpa.free(pct);
        var wb: [512]u8 = undefined;
        const want = try std.fmt.bufPrint(&wb, "exit 0: \"{s}\" \"%NL_POLL_NO_SUCH_VAR%\"", .{sys});
        try std.testing.expect(std.mem.indexOf(u8, pct, want) != null);
    }
}

test "expandPercentVars: a quoted Windows probe gets a cmd PROMPT's expansion, rule for rule as measured" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("NLX_A", "alpha");
    try env.put("NLX_PCT", "has%NLX_A%inside");
    // each expected value is what `cmd /S /C "echo <in>"` printed on 2026-10-14 with the same two variables set
    const rows = [_][2][]const u8{
        .{ "\"%NLX_A%\"", "\"alpha\"" },
        .{ "\"%NLX_UNDEF%\"", "\"%NLX_UNDEF%\"" }, // undefined: kept as typed
        .{ "\"%NLX_UNDEF%NLX_A%\"", "\"%NLX_UNDEFalpha\"" }, // ...and the scan resumes AT its closing %
        .{ "\"100%\"", "\"100%\"" },
        .{ "\"a %% b\"", "\"a %% b\"" }, // no batch-file %% escape at a prompt
        .{ "\"%%NLX_A%%\"", "\"%alpha%\"" },
        .{ "\"%NLX_PCT%\"", "\"has%NLX_A%inside\"" }, // a value is never rescanned
        .{ "\"% %\"", "\"% %\"" },
        .{ "\"%NLX_A%%NLX_A%\"", "\"alphaalpha\"" },
        .{ "x%\"NLX_A\"%y", "x%\"NLX_A\"%y" },
    };
    for (rows) |r| {
        const got = try expandPercentVars(gpa, r[0], &env);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(r[1], got);
    }
    // names are case-insensitive on Windows, as cmd's are (and as the Map is there)
    if (builtin.os.tag == .windows) {
        const got = try expandPercentVars(gpa, "%nlx_a%", &env);
        defer gpa.free(got);
        try std.testing.expectEqualStrings("alpha", got);
    }
}

test "poll command: a failing probe's observation carries its exit code and its stderr tail, so it explains itself (real shell)" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    var ctx = f.ctx(gpa);
    probe_seam.sleep_ms = 0; // it repeats until fail-fast ends it, with no interval_s sleeps between
    // Before: "(non-zero exit)" and nothing else, so a broken probe and a still-waiting one read the same.
    const args = if (builtin.os.tag == .windows)
        \\{"kind":"command","target":"cmd /D /C \"echo boom-on-stderr 1>&2 & exit /b 3\"","timeout_s":30,"interval_s":1}
    else
        \\{"kind":"command","target":"sh -c \"echo boom-on-stderr 1>&2; exit 3\"","timeout_s":30,"interval_s":1}
    ;
    const out = pollTool(&ctx, args);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "t+0s: exit 3, no stdout | stderr: boom-on-stderr") != null);
}

test "poll command: a probe that would outlive the call is killed, with everything it started, when timeout_s runs out (real shell)" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    const io = f.threaded.io();
    const root = "zig-pollkill-tmp";
    f.scratch(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var ctx = f.ctx(gpa);
    // A QUOTE-FREE target (cmd's direct route) whose real work runs a level down: ping under cmd, a loop in a nested
    // sh. Killing only the direct child leaves that grandchild running, and the old probe (std.process.run) waited
    // for all of it to end on its own. end.txt is written only by such a natural end. No process listing needed:
    // ping holds held.txt open (cmd's redirect shares no delete), the loop keeps growing hb.txt, so either file
    // says whether anything survived.
    const args = if (builtin.os.tag == .windows)
        \\{"kind":"command","target":"ping -n 30 127.0.0.1 >zig-pollkill-tmp\\held.txt 2>&1 & echo natural>zig-pollkill-tmp\\end.txt","until":"never","timeout_s":1,"interval_s":1}
    else
        \\{"kind":"command","target":"sh -c 'i=0; while [ $i -lt 100 ]; do echo x >> zig-pollkill-tmp/hb.txt; i=$((i+1)); sleep 0.1; done'; echo natural > zig-pollkill-tmp/end.txt","until":"never","timeout_s":1,"interval_s":1}
    ;
    const out = pollTool(&ctx, args);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(u32, 1), probe_seam.spawns);
    try std.testing.expect(std.mem.startsWith(u8, out, "poll command -> timeout"));
    try std.testing.expect(std.mem.indexOf(u8, out, "t+0s: killed after 1.0s, still running when this call's timeout_s ran out") != null);
    // cut at the bound, not waited out
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, root ++ "/end.txt", .{}));
    if (builtin.os.tag == .windows) {
        // held.txt deletes only once ping is gone: retried briefly while the killed tree's handles close
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (std.Io.Dir.cwd().deleteFile(io, root ++ "/held.txt")) |_| break else |e| {
                if (e == error.FileNotFound or tries >= 40) return e; // FileNotFound = ping never ran: no proof
                pollSleepMs(io, 50);
            }
        }
    } else {
        // the heartbeat stopped: nothing is left to write it
        const s1 = (try std.Io.Dir.cwd().statFile(io, root ++ "/hb.txt", .{})).size;
        pollSleepMs(io, 500);
        const s2 = (try std.Io.Dir.cwd().statFile(io, root ++ "/hb.txt", .{})).size;
        try std.testing.expect(s1 > 0);
        try std.testing.expectEqual(s1, s2);
    }
}

/// Test-only: an allocator that never hands memory back while a test runs. Every block released through it (freed,
/// or left behind by a realloc, which it never does in place) is filled with 0xAA and parked, so `dirty` counts
/// bytes written through a pointer the code had already given up. All of it reaches the backing allocator at
/// deinit, so std.testing.allocator still counts leaks.
const Quarantine = struct {
    const Parked = struct { mem: []u8, alignment: std.mem.Alignment };
    backing: std.mem.Allocator,
    parked: std.ArrayListUnmanaged(Parked) = .empty,

    fn allocator(q: *Quarantine) std.mem.Allocator {
        return .{ .ptr = q, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(c: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const q: *Quarantine = @ptrCast(@alignCast(c));
        return q.backing.rawAlloc(len, a, ra);
    }
    fn free(c: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const q: *Quarantine = @ptrCast(@alignCast(c));
        @memset(mem, 0xAA);
        q.parked.append(q.backing, .{ .mem = mem, .alignment = a }) catch q.backing.rawFree(mem, a, ra);
    }
    fn dirty(q: *const Quarantine) usize {
        var n: usize = 0;
        for (q.parked.items) |b| {
            for (b.mem) |x| n += @intFromBool(x != 0xAA);
        }
        return n;
    }
    fn deinit(q: *Quarantine) void {
        for (q.parked.items) |b| q.backing.rawFree(b.mem, b.alignment, @returnAddress());
        q.parked.deinit(q.backing);
    }
};

test "poll command: a probe cut at its bound while still printing writes nothing into memory the poll already released (real shell)" {
    const gpa = std.testing.allocator;
    var q: Quarantine = .{ .backing = gpa };
    defer q.deinit();
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    const io = f.threaded.io();
    const root = "zig-pollquar-tmp";
    f.scratch(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    // Prints on BOTH streams every few ms for far longer than the call, so its pipe reads are in flight when the
    // bound fires and it keeps printing through the tree kill. On Windows those reads are overlapped: the kernel
    // writes them into whatever buffer they were aimed at, owned or not.
    if (builtin.os.tag == .windows) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/chatty.cmd", .data = "@echo off\r\nfor /L %%i in (1,1,400) do (\r\necho out %%i\r\necho err %%i 1>&2\r\nping -n 1 127.0.0.1 >NUL\r\n)\r\n" });
    } else {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/chatty.sh", .data = "i=0\nwhile [ $i -lt 400 ]; do echo out $i; echo err $i >&2; i=$((i+1)); sleep 0.01; done\n" });
    }
    var ctx = f.ctx(q.allocator());
    const args = if (builtin.os.tag == .windows)
        \\{"kind":"command","target":"zig-pollquar-tmp\\chatty.cmd","until":"never","timeout_s":1,"interval_s":1}
    else
        \\{"kind":"command","target":"sh zig-pollquar-tmp/chatty.sh","until":"never","timeout_s":1,"interval_s":1}
    ;
    const out = pollTool(&ctx, args);
    defer q.allocator().free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "killed after 1.0s") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "out 1") != null); // it was printing when cut
    try std.testing.expect(q.parked.items.len > 0); // the poll's own buffers went through the quarantine
    try std.testing.expectEqual(@as(usize, 0), q.dirty());
}

test "poll command: a probe may run for all that is left of the call's timeout_s, so a slow but finite probe still matches (real shell)" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    var ctx = f.ctx(gpa);
    const out = pollTool(&ctx,
        \\{"kind":"command","target":"echo ready","until":"ready","timeout_s":60,"interval_s":1}
    );
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "poll command -> matched"));
    // The bound handed to the first probe is the call's whole budget (less the at most one second the clock may
    // have ticked), not a shorter fixed cap that would kill a 40 s `pytest | tail -3` on every sample.
    try std.testing.expect(probe_seam.last_bound_ms >= 59_000 and probe_seam.last_bound_ms <= 60_000);
}

test "poll command: the sample that settles the poll is in its log even after long observations filled it (real shell)" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    const io = f.threaded.io();
    const root = "zig-pollcap-tmp";
    f.scratch(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var ctx = f.ctx(gpa);
    probe_seam.sleep_ms = 0;
    // Each sample appends a line to count.txt and prints the file's size first (cmd: "x\r\n", 3 bytes a line, so 45
    // on the 15th; no space before its `&`, or echo writes it too; sh: 2, so 30), then a 220-byte stdout head and a
    // 300-byte stderr tail: ~550 bytes an observation, so
    // the 6000-byte log is full after 11, and the poll matches on the 15th. Quote-free, and cmd-builtin only (a
    // `find` would be Git's on some PATHs).
    const pad_out = "P" ** 220;
    const pad_err = "E" ** 300;
    const win = builtin.os.tag == .windows;
    const args = if (win)
        try std.fmt.allocPrint(gpa,
            \\{{"kind":"command","target":"echo x>>zig-pollcap-tmp\\count.txt& for %A in (zig-pollcap-tmp\\count.txt) do @echo %~zA & echo {s} & echo {s} 1>&2","until":"45","timeout_s":60,"interval_s":1}}
        , .{ pad_out, pad_err })
    else
        try std.fmt.allocPrint(gpa,
            \\{{"kind":"command","target":"echo x >> zig-pollcap-tmp/count.txt; wc -c < zig-pollcap-tmp/count.txt; echo {s}; echo {s} >&2","until":"30","timeout_s":60,"interval_s":1}}
        , .{ pad_out, pad_err });
    defer gpa.free(args);
    const out = pollTool(&ctx, args);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "poll command -> matched"));
    try std.testing.expectEqual(@as(u32, 15), probe_seam.spawns);
    try std.testing.expect(std.mem.indexOf(u8, out, if (win) "exit 0: 42" else "exit 0: 28") == null); // the bound dropped samples...
    try std.testing.expect(std.mem.indexOf(u8, out, if (win) "exit 0: 45" else "exit 0: 30") != null); // ...not the deciding one
}

test "poll command: a probe failing the same way from its first sample ends the poll early, error quoted (real shell)" {
    const gpa = std.testing.allocator;
    var f: PollFixture = undefined;
    try f.init(gpa);
    defer f.deinit();
    var ctx = f.ctx(gpa);
    probe_seam.sleep_ms = 0; // the budget below allows far more than PROBE_FAIL_FAST_N samples
    const args = if (builtin.os.tag == .windows)
        \\{"kind":"command","target":"cmd /D /C \"echo probe is broken 1>&2 & exit /b 2\"","until":"EXIT=","timeout_s":5,"interval_s":1}
    else
        \\{"kind":"command","target":"sh -c \"echo probe is broken 1>&2; exit 2\"","until":"EXIT=","timeout_s":5,"interval_s":1}
    ;
    const out = pollTool(&ctx, args);
    defer gpa.free(out);
    try std.testing.expectEqual(PROBE_FAIL_FAST_N, probe_seam.spawns);
    try std.testing.expect(std.mem.startsWith(u8, out, "poll command -> failing"));
    try std.testing.expect(std.mem.indexOf(u8, out, "(exit 2 each time, same error)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Its error: \"probe is broken\"") != null);
    // The rule cannot tell a broken probe from a not-ready state that prints an error ("connection refused"), so
    // the result must name the way to WAIT on the latter: the same probe silenced, which never ends a poll early.
    try std.testing.expect(std.mem.indexOf(u8, out, "SILENCED") != null and std.mem.indexOf(u8, out, "2>/dev/null") != null);
    // the repeats log as one short line each, so the bounded log keeps room for a sample that changes
    try std.testing.expect(std.mem.indexOf(u8, out, "(same as t+0s)") != null);
    // ...and the engine's poll budget counts this REAL result as a fruitless wait instead of zeroing its streak
    try std.testing.expectEqual(@as(u32, 2), @import("chat/engine.zig").pollStreakAfter(1, out));
}

test "ProbeWatch: only a probe that fails the same SPOKEN way from the first sample ends the poll; silent exits keep waiting" {
    const P = struct {
        fn mk(end: @FieldType(CmdProbe, "end"), code: u32, out: []const u8, err: []const u8) CmdProbe {
            return .{ .end = end, .code = code, .stdout = @constCast(out), .stderr = @constCast(err) };
        }
    };
    const broken = P.mk(.exited, 2, "", "bash: -c: line 1: unexpected EOF while looking for matching `\"'\n");
    const Cut = struct { // the 1-based sample that ended the poll, or null if none of `limit` did
        fn at(w: *ProbeWatch, p: *const CmdProbe, limit: u32) ?u32 {
            for (1..limit + 1) |i| if (w.failFast(p)) return @intCast(i);
            return null;
        }
    };
    { // identical spoken failures: cut at exactly PROBE_FAIL_FAST_N, the error kept for the result
        var w: ProbeWatch = .{};
        try std.testing.expectEqual(@as(?u32, PROBE_FAIL_FAST_N), Cut.at(&w, &broken, 10));
        try std.testing.expect(std.mem.indexOf(u8, w.quote[0..w.quote_len], "unexpected EOF") != null);
    }
    { // a SILENT non-zero exit is the documented "until exit 0" wait (`test -f done`): never cut short
        var w: ProbeWatch = .{};
        const silent = P.mk(.exited, 1, "", "");
        for (0..PROBE_FAIL_FAST_N * 3) |_| try std.testing.expect(!w.failFast(&silent));
        // ...and it disarms the streak for the rest of the call, so a later spoken failure is no "first N"
        for (0..PROBE_FAIL_FAST_N * 3) |_| try std.testing.expect(!w.failFast(&broken));
    }
    { // a success before the streak completes disarms it
        var w: ProbeWatch = .{};
        const ok = P.mk(.exited, 0, "not yet", "");
        try std.testing.expect(!w.failFast(&broken));
        try std.testing.expect(!w.failFast(&ok));
        for (0..PROBE_FAIL_FAST_N * 3) |_| try std.testing.expect(!w.failFast(&broken));
    }
    { // a failure that CHANGES (new stdout = progress) is not the same failure
        var w: ProbeWatch = .{};
        try std.testing.expect(!w.failFast(&broken));
        const moved = P.mk(.exited, 2, "12% done", broken.stderr);
        try std.testing.expect(!w.failFast(&moved));
        for (0..PROBE_FAIL_FAST_N * 3) |_| try std.testing.expect(!w.failFast(&broken));
    }
    { // a killed probe never counts, stderr or not: its bound is the call's remaining timeout_s, so it ends the call
        var w: ProbeWatch = .{};
        const hung = P.mk(.killed, 0, "", "still waiting\n");
        try std.testing.expectEqual(@as(?u32, null), Cut.at(&w, &hung, 10));
    }
    { // a probe that dies by a signal each time is named so, not as "exit 0"
        var w: ProbeWatch = .{};
        const segv = P.mk(.signal, 0, "", "Segmentation fault\n");
        try std.testing.expectEqual(@as(?u32, PROBE_FAIL_FAST_N), Cut.at(&w, &segv, 10));
        var gb: [PROBE_STDERR_TAIL + 800]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, w.guidance(&gb), "(ended by a signal each time, same error)") != null);
    }
}

test "localCoversQuery gates the RAG prepend: on-topic passes, fiction matched on one word fails" {
    // the live failure: a quantum-computing query pulled a NOVEL from the hive via the word "papers", and the
    // old prepend branch glued it ahead of the web results with "prefer these when they answer"
    const fiction = "but as the light from the window fell upon him as he picked up the papers, the face that smiled";
    const query = "quantum machine learning inference review survey research arXiv papers";
    try std.testing.expect(!localCoversQuery(fiction, query));
    // genuinely on-topic hits still pass — the RAG-first policy keeps its exhibit when it has earned it
    const on_topic = "quantum inference on variational circuits scales with qubit count; machine learning hybrids train the ansatz classically; see the arXiv survey papers";
    try std.testing.expect(localCoversQuery(on_topic, query));
}

test "patchVerifyFlag: unset/empty default the post-write verify ON; only an explicit off disables it" {
    try std.testing.expect(patchVerifyFlag(null));
    try std.testing.expect(patchVerifyFlag(""));
    try std.testing.expect(patchVerifyFlag("1"));
    try std.testing.expect(patchVerifyFlag("true"));
    try std.testing.expect(!patchVerifyFlag("0"));
    try std.testing.expect(!patchVerifyFlag("false"));
    try std.testing.expect(!patchVerifyFlag("OFF"));
}

test "patchTouchedPaths lists a patch envelope's Add/Update/Delete targets, dedups, and drops unsafe/blocked paths" {
    const gpa = std.testing.allocator;
    const patch =
        "*** Begin Patch\n" ++
        "*** Update File: src/worker/tools.zig\n" ++
        "@@\n-old\n+new\n" ++
        "*** Add File: src/worker/new.zig\n" ++
        "+hello\n" ++
        "*** Delete File: src/worker/tools.zig\n" ++ // same target again -> deduped, not counted twice
        "*** Update File: /etc/passwd\n" ++ // absolute -> dropped by safeRel
        "*** Update File: .git/config\n" ++ // blocked prefix -> dropped by patchSystemPathAllowed
        "*** End Patch\n";
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (out.items) |e| gpa.free(e);
        out.deinit(gpa);
    }
    patchTouchedPaths(gpa, patch, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("src/worker/tools.zig", out.items[0]);
    try std.testing.expectEqualStrings("src/worker/new.zig", out.items[1]);
}

test "zigAstErrLine distills a zig ast-check verdict to line N: msg, and fails OPEN when stderr names no error" {
    const gpa = std.testing.allocator;
    const stderr = "/tmp/x/.nlzchk-3.zig:42:9: error: expected ';' after statement\n    foo()\n        ^\n";
    const v = zigAstErrLine(gpa, stderr) orelse return error.ExpectedVerdict;
    defer gpa.free(v);
    try std.testing.expectEqualStrings("line 42: expected ';' after statement", v);
    // a zig that printed no "error:" line (missing, wrong flag, note-only) must NEVER reject an edit
    try std.testing.expect(zigAstErrLine(gpa, "note: some unrelated info\n") == null);
}

test "make_tool dry-runs the body: the py-compile gate precedes the TOOL_SCOPE registration" {
    // The whole point of the dry-run is to reject a broken body BEFORE it is stored — if the compile gate ever
    // moved after the observe, a syntax error would enter the registry and only surface at first call again.
    const SRC = @embedFile("tools.zig");
    const at = std.mem.indexOf(u8, SRC, "if (std.mem.eql(u8, name, \"make_tool\"))") orelse return error.MakeToolMissing;
    // Bound the search at the registration itself rather than a byte window: a fixed window that stops short
    // would fail for the wrong reason (and one that overshoots could read a LATER branch's calls as this one's).
    const rest = SRC[at..];
    const reg = std.mem.indexOf(u8, rest, "observe(TOOL_SCOPE") orelse return error.RegMissing;
    const before_reg = rest[0..reg];
    if (std.mem.indexOf(u8, before_reg, "pyCompileError(ctx, p.value.body") == null) return error.DryRunNotBeforeRegistration;
}
