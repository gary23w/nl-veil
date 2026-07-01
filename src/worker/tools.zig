//! The mind's toolbelt, in Zig — the keyless, single-purpose tools a mind calls during a moment to build,
//! research, and remember. These mirror the core of the Python kit/sandbox: run_python (a sandboxed Python
//! script), write_file/read_file (build artifacts in the workdir), web_fetch (research via curl), and the
//! memory ops (observe/recall/note_stance). The model is given SCHEMA as the `tools` array; execute() runs
//! a parsed tool_call and returns a text result to feed back into the conversation.
const std = @import("std");
const builtin = @import("builtin");
const oscillation = @import("oscillation.zig");
const Mem = oscillation.Mem;
const bufedit = @import("bufedit.zig");
const commons = @import("commons.zig");
const llm = @import("llm.zig");
const crawl = @import("crawl.zig");

extern "kernel32" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) callconv(.winapi) i32;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

const KillGuard = struct {
    id: std.process.Child.Id,
    deadline_ms: u32,
    done: *std.atomic.Value(bool),
    fn watch(g: KillGuard) void {
        var waited: u32 = 0;
        while (waited < g.deadline_ms) : (waited += 150) {
            if (builtin.os.tag == .windows) {
                Sleep(150);
            } else {
                const ts = std.posix.timespec{ .sec = 0, .nsec = 150 * std.time.ns_per_ms };
                _ = std.os.linux.nanosleep(&ts, null);
            }
            if (g.done.load(.monotonic)) return;
        }
        if (g.done.load(.monotonic)) return;
        if (builtin.os.tag == .windows) {
            _ = TerminateProcess(@ptrCast(g.id), 1);
        } else std.posix.kill(g.id, .KILL) catch {};
    }
};

/// Spawn a subprocess (its body redirected to a file via the caller's argv, so stdout never blocks the read) and KILL
/// it by handle if it runs longer than `deadline_ms` — so a WAF-held curl self-heals (the tool returns whatever
/// arrived) instead of wedging the swarm. The watchdog holds a COPY of the handle (captured before spawn) so it never
/// races the main thread's wait(); TerminateProcess on an already-closed handle is harmless.
fn spawnGuarded(io: std.Io, argv: []const []const u8, deadline_ms: u32) void {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    var done = std.atomic.Value(bool).init(false);
    const th: ?std.Thread = if (child.id != null)
        (std.Thread.spawn(.{}, KillGuard.watch, .{KillGuard{ .id = child.id.?, .deadline_ms = deadline_ms, .done = &done }}) catch null)
    else
        null;
    _ = child.wait(io) catch {};
    done.store(true, .monotonic);
    if (th) |t| t.join();
}

/// Fetch a URL via curl into a per-mind temp file, guarded by spawnGuarded (so a WAF hang is killed, not fatal), then
/// read back whatever body arrived. Caller frees. `json` adds the Accept header; `limit` caps the read.
fn curlToText(ctx: *ToolCtx, url: []const u8, json: bool, deadline_ms: u32, limit: usize) []u8 {
    const gpa = ctx.gpa;
    const tmp = std.fmt.allocPrint(gpa, "{s}/.fetch-{s}.tmp", .{ ctx.run_dir, ctx.mind }) catch return dupe(gpa, "oom");
    defer gpa.free(tmp);
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sSL", "--max-time", "20", "--connect-timeout", "10", "--speed-limit", "1", "--speed-time", "15", "-o", tmp, "-A", "neuron-loops-mind/1.0" }) catch return dupe(gpa, "oom");
    // Under an active egress allowlist, a redirect could hop OFF the allowlist (the gate only sees the seed URL),
    // so forbid redirect-following entirely — the allowlisted host must answer directly.
    if (ctx.egress_allow.len > 0) av.appendSlice(gpa, &.{"--max-redirs", "0"}) catch {};
    if (json) av.appendSlice(gpa, &.{ "-H", "Accept: application/json" }) catch {};
    av.append(gpa, url) catch {};
    spawnGuarded(ctx.io, av.items, deadline_ms);
    const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, tmp, gpa, .limited(limit)) catch (gpa.dupe(u8, "") catch @constCast(""));
    std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
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

pub const ToolCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
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
    discourse: bool = false,
    one_slot: bool = false,
    slot_path: []const u8 = "",
    blueprint: []const u8 = "",
    egress_allow: []const u8 = "",
    fmtx: ?*std.Io.Mutex = null,
};

fn lockFiles(ctx: *ToolCtx) void {
    if (ctx.fmtx) |m| m.lockUncancelable(ctx.io);
}
fn unlockFiles(ctx: *ToolCtx) void {
    if (ctx.fmtx) |m| m.unlock(ctx.io);
}

/// Write a fact to the SHARED hive, TAGGED with who/when ("[Noor r7] ..."). A hive fact is a mind's own first-person
/// sentence; tagging it tells every reader it is a TEAMMATE's report, not their own memory — preventing the identity
/// merge where one mind absorbs another's "I" as its own. The tag also gives a free recency stamp for the read path.
fn hiveStore(ctx: *ToolCtx, fact: []const u8) void {
    const tagged = std.fmt.allocPrint(ctx.gpa, "[{s} r{d}] {s}", .{ ctx.mind, ctx.round, fact }) catch fact;
    defer if (tagged.ptr != fact.ptr) ctx.gpa.free(tagged);
    _ = ctx.mem.observe(ctx.learn_scope, tagged);
}

/// The swarm-shared skill library lives in its own neuron-db scope (in the per-swarm mind.sqlite), so every
/// mind reads + writes the SAME skills and can build on each other's learned techniques.
pub const SKILL_SCOPE = "skills";

/// The swarm's self-authored OPERATING PLAYBOOK — process directives the minds write for THEMSELVES (e.g.
/// "read a file before improving it", "one mind owns each section"). It is injected into every mind's system
/// prompt, so the minds effectively edit their own operating instructions and improve their PROCESS over time
/// (recursive self-improvement of strategy — the engine/harness stays fixed and human-controlled).
pub const PLAYBOOK_SCOPE = "playbook";

/// The swarm's FITNESS history — one "round N: P/T (pct%)" line per round, written by the engine's benchmark.
/// This is the measurable spine of recursive self-improvement: improvement is a NUMBER that must climb, not a
/// vibe. The deliverable is scored each round (real tests > compiles > artifact-presence) and that score is fed
/// back into every mind's prompt as the gradient to raise.
pub const SCORE_SCOPE = "score";

/// Shared HIVE KNOWLEDGE — facts any mind learns FOR THE TEAM (not just for itself). A scout that observes into
/// its OWN scope is a hoarder: it learns, but the hive never sees it. Routing the scout's observe here (and
/// injecting this scope into every mind's prompt) makes the learner a real contributor — knowledge brought BACK
/// to the hive, not held. Swarm-shared, like SKILL_SCOPE.
pub const KNOWLEDGE_SCOPE = "knowledge";

/// The EXTERNAL / runtime-LEARNED cache: facts the swarm acquired from the live web at runtime (scout/web tools)
/// while OPERATING — kept separate from KNOWLEDGE_SCOPE (the protected core: baked playbook, tools, skills,
/// directives, the daemon's own identity). Only this scope is evictable, so a service deployment can cap + FIFO it
/// (stale threat-intel decays) WITHOUT ever touching the core. recall_hive spans BOTH, so the agent recalls all of it.
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
// separate so a chain over the map can never collide with node descriptions (verified: scopes isolate).
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

/// The hive's shared SPATIAL MAP — discovered cells of a hidden grid, written by `probe`. A hive's structural
/// superpower is PARALLEL REGION-SEARCH: when a space is too big for one mind to perceive at once, the minds
/// partition it, each probes a DIFFERENT region, and the findings accumulate HERE as one shared map every mind
/// can read — ant-colony style (this scope is the pheromone trail). Injected in full each moment so the
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
    \\{"type":"function","function":{"name":"run_python","description":"Run a short Python script (no GUI) in the build workdir and get its stdout/stderr. Use it to compute, transform data, or generate files. API keys are NOT available to the script.","parameters":{"type":"object","properties":{"code":{"type":"string","description":"the Python source to execute"}},"required":["code"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the build workdir (creates parent dirs). To GROW a long document (e.g. add the next scene to a chapter) pass mode:\"append\" with ONLY the new text — it is concatenated onto the existing file, so you never resend (or truncate) prior content. mode:\"overwrite\" (default) replaces the file. To CHANGE an existing file, prefer edit_file (never re-emit a large file).","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit_file","description":"Make a SURGICAL edit to an EXISTING file WITHOUT resending the whole file — use this (NOT write_file) to change a file that already exists, especially a large one (write_file re-emits the whole file and truncates big ones). Each op names an exact ANCHOR: a snippet copied VERBATIM from the current file, with enough lines that it appears exactly once. op is: replace (swap the anchored lines for text), insert_before / insert_after (add text around the anchor), delete (remove the anchored lines). read_file first so your anchors match byte-for-byte.","parameters":{"type":"object","properties":{"path":{"type":"string"},"ops":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["replace","insert_before","insert_after","delete"]},"anchor":{"type":"string"},"text":{"type":"string"}},"required":["op","anchor"]}}},"required":["path","ops"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the build workdir.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"patch_system","description":"RSI engine edit tool. Read/write/replace/apply_patch under NL_PATCH_SYSTEM_ROOT (or legacy NL_OPEN_CLAW_ROOT). Mutating edits are gated: provide proposal + measurable success_criterion; high-impact edits also require simulate_change; privileged zones require explicit operator approval.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"relative file path under the configured patch-system root (required for read/write/replace)"},"mode":{"type":"string","enum":["read","write","replace","patch"],"description":"operation (default: read)"},"content":{"type":"string","description":"new file content for write mode"},"find":{"type":"string","description":"exact text to replace (replace mode)"},"replace":{"type":"string","description":"replacement text (replace mode)"},"patch":{"type":"string","description":"apply_patch payload with *** Begin Patch / *** End Patch markers (patch mode)"},"proposal":{"type":"string","description":"proposal title/id from propose_change (required for mutating edits)"},"success_criterion":{"type":"string","description":"measurable success criterion tied to the proposal (required for mutating edits)"},"limit":{"type":"integer","description":"max bytes to read (default 12000, max 262144)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"list_dir","description":"List the files (with sizes) in a directory so you can SEE what exists before reading or editing. Defaults to your build workdir; pass root=\"system\" to list the patch_system engine root.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"relative dir, default '.'"},"root":{"type":"string","enum":["workdir","system"],"description":"workdir (default) or the patch_system root"}},"required":[]}}},
    \\{"type":"function","function":{"name":"run_tests","description":"Run the deliverable's test suite (pytest, else a test_*.py) in your build workdir and get the pass/fail output. VERIFY your code after writing or patching it — write, run_tests, fix, run_tests again. This is how you make sure a change actually works.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"delete_file","description":"Delete a file you created in your build workdir (clean up a dead end, a wrong scaffold, or junk).","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"host_status","description":"Read the LIVE state of the host/machine you are operating (its telemetry: mode, threat_score, processes, connections, persistence, infections). Call it to see the current state before you act and again after you act to VERIFY. Returns the raw telemetry.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"host_command","description":"OPERATE the host: issue ONE command to it directly (this is how you actually act on the machine — do NOT write files describing a fix). Use it to remediate: remove_persistence <unit> (the ROOT CAUSE), kill_proc <pid|name>, block_ip <ip>, restore_file <path>, isolate, scan. To fully clean an infection, remove its persistence AND block its C2 AND kill its process.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"one command line, e.g. 'remove_persistence sysupdate.timer'"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch a URL and return its clean, readable text (our in-house crawler strips tags + prunes boilerplate + cites links). Optional 'query' fits the page to your topic and returns only the most relevant parts. Use it to read a page you already have the URL for.","parameters":{"type":"object","properties":{"url":{"type":"string"},"query":{"type":"string","description":"optional: a topic/question to fit the page to — returns only the parts that match"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_search","description":"Keyless web search — returns the top results, each WITH a short excerpt of the source's actual page text (auto-fetched + fit to your query), so you usually don't need a separate fetch. For current events just search the topic + a date.","parameters":{"type":"object","properties":{"query":{"type":"string"},"source":{"type":"string","enum":["web","wikipedia","hackernews","arxiv"],"description":"web=general (default), or a specific source"},"limit":{"type":"integer","description":"max results (default 5)"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"fetch_json","description":"HTTP GET a JSON/text API endpoint and return the raw body (not HTML-stripped). Use for REST/JSON APIs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"read_url","description":"Read a URL as clean, LLM-ready text via a reader proxy that renders JS and works on sites a plain fetch can't. Prefer this over web_fetch for real articles/pages.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"osint_scan","description":"Public-source OSINT scan for one URL: extract high-signal leads (emails, phones, domains, docs, socials, and notable outbound links). Uses only normal public HTTP/HTTPS fetches.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"deep_crawl","description":"Recursive public-web crawl from a seed URL with bounded depth/pages, extracting lead-rich links and contact/identity indicators from each page. Designed for lead expansion across many hops.","parameters":{"type":"object","properties":{"url":{"type":"string"},"depth":{"type":"integer","description":"crawl depth, default 2 (max 4)"},"max_pages":{"type":"integer","description":"max pages to fetch, default 30 (max 120)"},"same_host":{"type":"boolean","description":"stay on seed host only (default true)"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall","description":"Recall facts from your memory relevant to a query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"note_stance","description":"Record how you feel about a topic (your stance).","parameters":{"type":"object","properties":{"topic":{"type":"string"},"feeling":{"type":"string"}},"required":["topic","feeling"]}}},
    \\{"type":"function","function":{"name":"save_skill","description":"Save a NEW reusable skill you developed — a method, code snippet, or step-by-step approach — into the swarm's shared skill library, so you and teammates can reuse it instead of re-deriving it. Do NOT re-save a skill already in the 'Reusable skills' list you were shown; save each distinct skill ONCE.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"a short skill name"},"skill":{"type":"string","description":"the reusable how-to / snippet / approach, concrete enough to follow again"}},"required":["name","skill"]}}},
    \\{"type":"function","function":{"name":"set_directive","description":"IMPROVE HOW YOUR SWARM WORKS. Write a concise process directive — a lesson about a better way to operate — into the swarm's shared, self-authored operating PLAYBOOK. It is injected into every mind's instructions from now on, so this is how the swarm improves its own process over time. Use it when you notice what's working or what's failing (e.g. 'read a file before rewriting it', 'one mind owns each section', 'verify code by running it'). Phrase it as an imperative rule. Don't repeat a directive already in the playbook.","parameters":{"type":"object","properties":{"directive":{"type":"string","description":"one concise imperative process rule for the swarm to follow"}},"required":["directive"]}}},
    \\{"type":"function","function":{"name":"propose_plan_change","description":"Propose a change to the shared PROJECT PLAN (the forward contract every piece is built to) with a clear rationale — e.g. the arc isn't landing, research revealed a better structure, two pieces need a different hand-off. The engine folds sound proposals into its next plan revision. The CANON RATCHET protects finished work: any fact a built piece already used cannot change, so you can only refine the plan for pieces NOT yet built.","parameters":{"type":"object","properties":{"rationale":{"type":"string","description":"why the plan should change and what it should become for the unbuilt pieces"}},"required":["rationale"]}}},
    \\{"type":"function","function":{"name":"send_message","description":"Send a message to a teammate mind (or 'all' to broadcast) on the swarm bus.","parameters":{"type":"object","properties":{"to":{"type":"string"},"text":{"type":"string"}},"required":["to","text"]}}},
    \\{"type":"function","function":{"name":"add_task","description":"Add a task to the shared swarm board, assigned to a mind (or 'all').","parameters":{"type":"object","properties":{"assignee":{"type":"string"},"task":{"type":"string"}},"required":["assignee","task"]}}},
    \\{"type":"function","function":{"name":"complete_task","description":"Mark a board task done by its id, with a short result.","parameters":{"type":"object","properties":{"id":{"type":"integer"},"result":{"type":"string"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"stage_delivery","description":"When the goal asks you to PUBLISH/push/deploy/save the result somewhere external (GitHub, a website, an S3/GCS bucket, SSH, a durable directory) AND you judge the deliverable complete, call this to PACKAGE it for handoff. You CANNOT publish directly — the swarm holds no credentials by design. This stages the workdir + writes a delivery manifest the operator (a human, or a privileged broker outside this sandbox) reviews and then approves to actually publish. Do the work first, then stage once.","parameters":{"type":"object","properties":{"target":{"type":"string","description":"where it should go, e.g. 'github:owner/repo', 'bucket:my-bucket/prefix', 'website', 'ssh:host:/path', 'local-durable'"},"summary":{"type":"string","description":"one-line summary of what is being delivered and why it's complete"}},"required":["target","summary"]}}},
    \\{"type":"function","function":{"name":"make_tool","description":"AUTHOR A NEW TOOL when your current tools can't do a task — do NOT give up with 'my tools are limited'. Give it a snake_case name, a one-line description, a JSON-Schema 'params' object, and a Python 'body'. The body reads its inputs from a global dict ARGS and MUST print exactly one JSON line as its result (e.g. print(json.dumps({\"valid\":true}))). It runs sandboxed: no API keys, cwd=workdir, pure-stdlib. Once made it is callable by name by you AND every teammate for the rest of the run. Research the technique first (web_search/read_url) if you don't know it, then implement it here. Do NOT remake a tool already listed in 'Authored tools'.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"snake_case, 3-32 chars [a-z0-9_]"},"description":{"type":"string"},"params":{"type":"object","description":"JSON-Schema object for the tool's arguments"},"body":{"type":"string","description":"Python; read inputs from the ARGS dict, print ONE JSON result line"}},"required":["name","description","params","body"]}}},
    \\{"type":"function","function":{"name":"propose_change","description":"Submit a structured RSI change proposal for engine governance (hypothesis, metric, risk, rollback). The engine evaluates proposals with simulation, critique, and canary checks.","parameters":{"type":"object","properties":{"title":{"type":"string","description":"short proposal title"},"hypothesis":{"type":"string","description":"why this change should improve capability"},"change":{"type":"string","description":"what exactly will be changed"},"metric":{"type":"string","description":"how success is measured"},"risk":{"type":"string","enum":["low","medium","high"],"description":"estimated downside"},"rollback":{"type":"string","description":"how to revert if it regresses"}},"required":["title","hypothesis","change","metric","risk","rollback"]}}},
    \\{"type":"function","function":{"name":"simulate_change","description":"Record a world-model simulation of a planned change before applying it: expected gains, failure modes, and side effects.","parameters":{"type":"object","properties":{"proposal":{"type":"string","description":"proposal title or id"},"expected":{"type":"string","description":"expected positive outcome"},"failures":{"type":"string","description":"possible failure modes"},"side_effects":{"type":"string","description":"non-target side effects to watch"}},"required":["proposal","expected","failures","side_effects"]}}},
    \\{"type":"function","function":{"name":"share","description":"Contribute one fact to the HIVE'S SHARED ASSOCIATIVE MIND — the collective memory every teammate reads. Use this for anything the whole hive should know (a finding, a decision, a constraint, an interface you settled on). Unlike observe (your private memory), this is the team's. Write one crisp sentence and include the key entities/names so it links into the associative graph.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Think WITH the whole hive: spreading-activation recall across the shared collective memory. Unlike recall (your own facts), this surfaces the CHAINED neighborhood of what ANY teammate contributed — related facts that may share no words with your query but are reached by following shared entities. Use it to ask the collective what it knows before you act.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"probe","description":"PERCEIVE one cell of the hidden spatial grid (only available when the swarm has a spatial substrate). You cannot see the grid directly — you sense it ONE cell at a time. probe(x,y) reads the cell at column x, row y (both 0-based) and AUTO-RECORDS it to the hive's shared map so every teammate sees it. This is the hive's spatial superpower: divide the grid into regions, each mind probes a DIFFERENT region in parallel, and the shared map fills in far faster than one mind alone. Check the 'Discovered map' you're shown before re-probing a known cell.","parameters":{"type":"object","properties":{"x":{"type":"integer","description":"column, 0-based"},"y":{"type":"integer","description":"row, 0-based"}},"required":["x","y"]}}}
;

/// The SCOUT's tool set — a RESEARCH-ONLY subset of SCHEMA. The build tools (run_python, write_file) are
/// deliberately ABSENT so the learner mind STRUCTURALLY cannot drift into building: an imperative "do not build"
/// prompt did not hold (the LLM scout ignored it and wrote files like everyone else), so the engine simply
/// withholds the ability. The scout can read context, search/read the web, store facts, save skills, and
/// message teammates — its only outputs are KNOWLEDGE. Keep these defs in sync with their twins in SCHEMA.
pub const SCOUT_SCHEMA =
    \\{"type":"function","function":{"name":"web_search","description":"Keyless web search — returns the top results, each WITH a short excerpt of the source's actual page text (auto-fetched + fit to your query), so you usually don't need a separate fetch. For current events just search the topic + a date.","parameters":{"type":"object","properties":{"query":{"type":"string"},"source":{"type":"string","enum":["web","wikipedia","hackernews","arxiv"]},"limit":{"type":"integer"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"read_url","description":"Read a URL as clean, LLM-ready text via a reader proxy that renders JS. Prefer this over web_fetch for real articles/specs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch a URL and return its clean readable text (our in-house crawler strips tags + prunes boilerplate). Optional 'query' fits the page to your topic.","parameters":{"type":"object","properties":{"url":{"type":"string"},"query":{"type":"string","description":"optional: a topic/question to fit the page to"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"osint_scan","description":"Public-source OSINT scan for one URL: extract high-signal leads (emails, phones, domains, docs, socials, and notable outbound links).","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"deep_crawl","description":"Recursive public-web crawl from a seed URL with bounded depth/pages, extracting lead-rich links across hops.","parameters":{"type":"object","properties":{"url":{"type":"string"},"depth":{"type":"integer"},"max_pages":{"type":"integer"},"same_host":{"type":"boolean"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"fetch_json","description":"HTTP GET a JSON/text API endpoint and return the raw body. Use for REST/JSON APIs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the build workdir — use it to see what the team is building and what to research.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"recall","description":"Recall facts from your memory relevant to a query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Spreading-activation recall across the hive's shared collective memory — check what the team already knows before researching.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"probe","description":"PERCEIVE one cell of the hidden spatial grid (only when the swarm has a spatial substrate). probe(x,y) reads column x, row y (0-based) and records it to the hive's shared map. As the scout you can sweep an UNCLAIMED region of the grid for the team.","parameters":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"}},"required":["x","y"]}}},
    \\{"type":"function","function":{"name":"share","description":"Contribute one fact to the hive's shared associative mind so every teammate can recall it.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"save_skill","description":"Save a reusable technique you found for the team — name it 'scout:<topic>' — into the shared skill library so builders can apply it. Make it concrete and actionable, not just a link.","parameters":{"type":"object","properties":{"name":{"type":"string"},"skill":{"type":"string"}},"required":["name","skill"]}}},
    \\{"type":"function","function":{"name":"send_message","description":"Send the single most useful thing you learned to a teammate (or 'all').","parameters":{"type":"object","properties":{"to":{"type":"string"},"text":{"type":"string"}},"required":["to","text"]}}}
;

/// The ASSEMBLER's tool set — the minimal authoring set for a small model (8B) in scaffold-and-fill mode. The full
/// 28-tool SCHEMA (~6k tokens, re-sent every turn) drowns a weak model and confuses weak tool-calling, so the
/// assembler is given ONLY what it needs: read what exists, write the fill, record a fact, recall_hive — so it can
/// PULL the exact concept/pattern the hive already learned before it builds (without recall, learned knowledge is
/// stored-and-forgotten) — AND send_message, so parallel minds building separate files can agree on the interfaces
/// between them. No web/search (the scout's job), no run_python/run_tests. Keep defs in sync with SCHEMA.
pub const ASSEMBLER_SCHEMA =
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the build workdir (creates parent dirs). To GROW a long document (e.g. add the next scene to a chapter) pass mode:\"append\" with ONLY the new text — it is concatenated onto the existing file, so you never resend (or truncate) prior content. mode:\"overwrite\" (default) replaces the file. To CHANGE an existing file, prefer edit_file (never re-emit a large file).","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit_file","description":"Make a SURGICAL edit to an EXISTING file WITHOUT resending the whole file — use this (NOT write_file) to change a file that already exists, especially a large one (write_file re-emits the whole file and truncates big ones). Each op names an exact ANCHOR: a snippet copied VERBATIM from the current file, with enough lines that it appears exactly once. op is: replace (swap the anchored lines for text), insert_before / insert_after (add text around the anchor), delete (remove the anchored lines). read_file first so your anchors match byte-for-byte.","parameters":{"type":"object","properties":{"path":{"type":"string"},"ops":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["replace","insert_before","insert_after","delete"]},"anchor":{"type":"string"},"text":{"type":"string"}},"required":["op","anchor"]}}},"required":["path","ops"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the build workdir.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Pull what the hive already LEARNED before you build: spreading-activation recall across the shared collective memory. You are shown a list of topics the hive knows — call this with the one you need (e.g. 'axum routing', 'JWT auth') to get the concrete pattern/snippet, instead of guessing or redoing research.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"send_message","description":"Tell a teammate (or 'all') the ONE thing they must know to stay consistent with your file — the exact function name + signature you expose, or a decision the others must match. Read your inbox (shown above) and reply when a teammate needs something.","parameters":{"type":"object","properties":{"to":{"type":"string"},"text":{"type":"string"}},"required":["to","text"]}}}
;

pub const OPERATE_SCHEMA =
    \\{"type":"function","function":{"name":"host_status","description":"Read the LIVE state of the host/machine you are operating (its telemetry: mode, threat_score, processes, connections, persistence, infections). Call it to see the current state before you act and again after you act to VERIFY. Returns the raw telemetry.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"host_command","description":"OPERATE the host: issue ONE command to it directly (this is how you actually act on the machine — do NOT write files describing a fix). Use it to remediate: remove_persistence <unit> (the ROOT CAUSE), kill_proc <pid|name>, block_ip <ip>, restore_file <path>, isolate, scan. To fully clean an infection, remove its persistence AND block its C2 AND kill its process.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"one command line, e.g. 'remove_persistence sysupdate.timer'"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"host_explore","description":"EXPLORE the device READ-ONLY to discover structure the live telemetry does not show. verb: enumerate <node> (list a container's direct members), expand <node> (fan out a node's typed neighbors — this GROWS your map), describe <node> (read one entity's attributes). Discoveries map into your memory; recall/chain over them next round to find the real structure and the root. It never changes the device.","parameters":{"type":"object","properties":{"verb":{"type":"string","description":"enumerate | expand | describe"},"node":{"type":"string","description":"a node shown in your map or telemetry (a pid, path, handle, principal)"},"rel":{"type":"string","description":"optional relation for a targeted walk"}},"required":["verb","node"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the workdir — use it to inspect a config/log/source before you change it.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the workdir (creates parent dirs) — use it to PATCH a config you read (write back the fixed version) or to record a written report/debrief. mode:\"append\" concatenates only the new text; mode:\"overwrite\" (default) replaces the file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"recall","description":"Recall facts from your memory relevant to a query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Think WITH the whole hive: spreading-activation recall across the shared collective memory — surfaces the chained neighborhood of what ANY teammate (or the baked intel) knows, even facts that share no words with your query. Use it to GROUND a decision (e.g. is this identifier known-bad, who is the actor) before you act.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned (e.g. a confirmed indicator, what an action did) into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"send_message","description":"Send a message to a teammate mind (or 'all' to broadcast) on the swarm bus — split the work so two operators don't act on the same facet.","parameters":{"type":"object","properties":{"to":{"type":"string"},"text":{"type":"string"}},"required":["to","text"]}}},
    \\{"type":"function","function":{"name":"set_directive","description":"IMPROVE HOW YOUR SWARM OPERATES. Write one concise imperative process rule into the swarm's shared, self-authored operating PLAYBOOK — injected into every mind's instructions from now on (e.g. 'confirm a target is hostile before any destructive action', 'remove the persistence before killing the process'). This is how the swarm improves its own operating method over time. Don't repeat a directive already in the playbook.","parameters":{"type":"object","properties":{"directive":{"type":"string","description":"one concise imperative process rule for the swarm to follow"}},"required":["directive"]}}}
;

/// Run one tool. `args_json` is the raw arguments string from the tool_call. Returns a gpa-owned result
/// (caller frees) — always a string, even on error, so it can feed back to the model.
pub fn execute(ctx: *ToolCtx, name: []const u8, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    if (ctx.discourse and (std.mem.eql(u8, name, "run_python") or std.mem.eql(u8, name, "run_tests") or
        std.mem.eql(u8, name, "make_tool") or std.mem.eql(u8, name, "patch_system")))
        return dupe(gpa, "this is a research/writing task — there is no code repo or test suite; produce the written deliverable with write_file");
    if (std.mem.eql(u8, name, "run_python")) return runPython(ctx, args_json);
    if (std.mem.eql(u8, name, "write_file")) return writeFile(ctx, args_json);
    if (std.mem.eql(u8, name, "edit_file")) return editFile(ctx, args_json);
    if (std.mem.eql(u8, name, "read_file")) return readFile(ctx, args_json);
    if (std.mem.eql(u8, name, "patch_system")) return patchSystem(ctx, args_json);
    if (std.mem.eql(u8, name, "list_dir")) return listDir(ctx, args_json);
    if (std.mem.eql(u8, name, "run_tests")) return runTests(ctx, args_json);
    if (std.mem.eql(u8, name, "delete_file")) return deleteFile(ctx, args_json);
    if (std.mem.eql(u8, name, "host_status")) return hostStatus(ctx, args_json);
    if (std.mem.eql(u8, name, "host_command")) return hostCommand(ctx, args_json);
    if (std.mem.eql(u8, name, "host_explore")) return hostExplore(ctx, args_json);
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
    if (std.mem.eql(u8, name, "propose_change")) return proposeChange(ctx, args_json);
    if (std.mem.eql(u8, name, "simulate_change")) return simulateChange(ctx, args_json);
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
        if (ctx.share_obs) {
            hiveStore(ctx, p.value.fact);
        } else {
            _ = ctx.mem.observe(ctx.scope, p.value.fact);
            hiveStore(ctx, p.value.fact);
        }
        ctx.observed.* += 1;
        const total = ctx.mem.factCount(KNOWLEDGE_SCOPE);
        return std.fmt.allocPrint(gpa, "stored — shared with the hive ({d} collective facts)", .{total}) catch dupe(gpa, "stored, shared with the hive");
    }
    if (std.mem.eql(u8, name, "recall")) {
        const A = struct { query: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const r = ctx.mem.assoc(ctx.scope, p.value.query, 3, 8);
        if (r.len == 0) {
            gpa.free(r);
            return dupe(gpa, "(nothing recalled yet)");
        }
        return r;
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
        hiveStore(ctx, p.value.fact);
        const total = ctx.mem.factCount(KNOWLEDGE_SCOPE);
        return std.fmt.allocPrint(gpa, "shared with the hive ({d} collective facts; every teammate can now recall_hive it)", .{total}) catch dupe(gpa, "shared");
    }
    if (std.mem.eql(u8, name, "recall_hive")) {
        const A = struct { query: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const core = ctx.mem.assoc(KNOWLEDGE_SCOPE, p.value.query, 1, 12);
        defer gpa.free(core);
        const learned = ctx.mem.assoc(INTEL_SCOPE, p.value.query, 1, 12);
        defer gpa.free(learned);
        if (core.len == 0 and learned.len == 0) return dupe(gpa, "(the hive knows nothing relevant yet — be the first to share something)");
        if (learned.len == 0) return dupe(gpa, core);
        if (core.len == 0) return dupe(gpa, learned);
        return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ core, learned }) catch dupe(gpa, core);
    }
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
            const existing = ctx.mem.recall(SKILL_SCOPE, p.value.name);
            defer gpa.free(existing);
            if (std.mem.indexOf(u8, existing, p.value.name) != null)
                return std.fmt.allocPrint(gpa, "skill '{s}' is already in the shared library — not re-saved (reuse it)", .{p.value.name}) catch dupe(gpa, "already saved");
        }
        const text = std.fmt.allocPrint(gpa, "{s}: {s}", .{ p.value.name, p.value.skill }) catch return dupe(gpa, "oom");
        defer gpa.free(text);
        _ = ctx.mem.observe(SKILL_SCOPE, text);
        ctx.skills_saved.* += 1;
        const total = ctx.mem.factCount(SKILL_SCOPE);
        return std.fmt.allocPrint(gpa, "skill saved to the shared library ({d} skills total)", .{total}) catch dupe(gpa, "skill saved");
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
        const A = struct { assignee: []const u8 = "all", task: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        lockFiles(ctx);
        defer unlockFiles(ctx);
        const id = commons.addTask(gpa, ctx.io, ctx.run_dir, ctx.mind, p.value.assignee, p.value.task);
        return std.fmt.allocPrint(gpa, "task #{d} added for {s}", .{ id, p.value.assignee }) catch dupe(gpa, "task added");
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
    if (authoredBody(ctx, name)) |body| {
        defer gpa.free(body);
        return runAuthored(ctx, name, body, args_json);
    }
    return std.fmt.allocPrint(gpa, "unknown tool: {s}", .{name}) catch dupe(gpa, "unknown tool");
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
    const script_name = std.fmt.allocPrint(gpa, ".tool-{s}.py", .{ctx.scope}) catch return dupe(gpa, "oom");
    defer gpa.free(script_name);
    const script = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, script_name }) catch return dupe(gpa, "oom");
    defer gpa.free(script);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = script, .data = src }) catch return dupe(gpa, "could not write script");

    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};

    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", PYRUN, script_name };
    const r = std.process.run(gpa, ctx.io, .{ .argv = &argv, .cwd = .{ .path = ctx.workdir }, .environ_map = &env, .stdout_limit = .limited(256 << 10), .stderr_limit = .limited(64 << 10) }) catch return dupe(gpa, "python failed to run");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const exit = if (r.term == .exited) r.term.exited else @as(u8, 255);
    return std.fmt.allocPrint(gpa, "exit={d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit, clip(r.stdout, 4000), clip(r.stderr, 1500) }) catch dupe(gpa, "ran");
}

/// True if `n` is a built-in tool name. execute() checks built-ins FIRST and make_tool rejects these names, so
/// an authored tool can never shadow/hijack a built-in (e.g. run_python, write_file, make_tool).
fn isBuiltinTool(n: []const u8) bool {
    const builtins = [_][]const u8{ "run_python", "write_file", "edit_file", "read_file", "patch_system", "list_dir", "run_tests", "delete_file", "web_fetch", "web_search", "fetch_json", "read_url", "osint_scan", "deep_crawl", "observe", "recall", "share", "recall_hive", "probe", "note_stance", "save_skill", "set_directive", "send_message", "add_task", "complete_task", "stage_delivery", "make_tool", "propose_change", "simulate_change" };
    for (builtins) |b| if (std.mem.eql(u8, b, n)) return true;
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
    const src = std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ guard, preamble, body }) catch return dupe(gpa, "oom");
    defer gpa.free(src);
    const script_name = std.fmt.allocPrint(gpa, ".authored-{s}-{s}.py", .{ ctx.scope, name }) catch return dupe(gpa, "oom");
    defer gpa.free(script_name);
    const script = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, script_name }) catch return dupe(gpa, "oom");
    defer gpa.free(script);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = script, .data = src }) catch return dupe(gpa, "could not write tool script");
    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
    const aj = if (std.mem.trim(u8, args_json, " \r\n\t").len == 0) "{}" else args_json;
    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", PYRUN, script_name, aj };
    const r = std.process.run(gpa, ctx.io, .{ .argv = &argv, .cwd = .{ .path = ctx.workdir }, .environ_map = &env, .stdout_limit = .limited(256 << 10), .stderr_limit = .limited(64 << 10) }) catch return dupe(gpa, "tool failed to run");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const exit = if (r.term == .exited) r.term.exited else @as(u8, 255);
    if (exit == 0) {
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, r.stdout, " \r\n\t"), '\n');
        var jline: ?[]const u8 = null;
        while (lines.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \r\n\t");
            if (t.len > 0 and t[0] == '{') jline = t;
        }
        if (jline) |jl| return dupe(gpa, clip(jl, 4000));
    }
    return std.fmt.allocPrint(gpa, "exit={d}\nstdout:\n{s}\nstderr:\n{s}", .{ exit, clip(r.stdout, 3000), clip(r.stderr, 1500) }) catch dupe(gpa, "ran");
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

fn writeFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { path: []const u8 = "", content: []const u8 = "", mode: []const u8 = "overwrite" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch
        return dupe(gpa, "write_file arguments were not valid JSON — your file was likely too long and got cut off. Write a shorter version (or fewer changes this turn), then improve it next turn.");
    defer p.deinit();
    if (!safeRel(p.value.path)) return dupe(gpa, "bad path");
    const npath = blk_np: {
        const wb = std.fs.path.basename(ctx.workdir);
        if (wb.len > 0 and p.value.path.len > wb.len + 1 and std.mem.startsWith(u8, p.value.path, wb) and p.value.path[wb.len] == '/')
            break :blk_np p.value.path[wb.len + 1 ..];
        break :blk_np p.value.path;
    };
    const redirected = ctx.one_slot and ctx.slot_path.len > 0 and !std.mem.eql(u8, npath, ctx.slot_path);
    const wpath = if (redirected) ctx.slot_path else npath;
    if (ctx.one_slot and ctx.blueprint.len > 0 and blueprintHas(ctx.blueprint, wpath) and !std.mem.eql(u8, std.fs.path.basename(wpath), std.fs.path.basename(ctx.slot_path))) {
        const yours = if (ctx.slot_path.len > 0) std.fmt.allocPrint(gpa, " YOUR file this round is `{s}` — write that, not this.", .{ctx.slot_path}) catch "" else " You have no deliverable file this round — research the upcoming pieces, share what you learn, or create a NEW helper file.";
        defer if (yours.len > 0 and ctx.slot_path.len > 0) gpa.free(@constCast(yours));
        return std.fmt.allocPrint(gpa, "`{s}` is an ordered deliverable file with a single author this round — overwriting it would clobber finished work or jump ahead of the team's current piece.{s}", .{ wpath, yours }) catch dupe(gpa, "that ordered file belongs to its builder this round — don't overwrite it");
    }
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, wpath }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    if (ctx.owned_by_others.len > 0 and fileOwnedBy(ctx.owned_by_others, wpath) and !fileOwnedBy(ctx.my_files, wpath)) {
        const rescue = ctx.round > 1 and !builtAlready(ctx, wpath);
        if (!rescue)
            return std.fmt.allocPrint(gpa, "{s} is a teammate's file this round — they own it in the blueprint and are building it in parallel, so writing it would collide (last-writer-wins) and waste the work. YOUR files: {s}. Write or DEEPEN one of yours that isn't done, or create a genuinely NEW file in nobody's slice. To change a file you don't own, read_file it and send_message its owner — don't rewrite it.", .{ wpath, if (ctx.my_files.len > 0) ctx.my_files else "(none assigned — take an unbuilt blueprint file or a new one)" }) catch dupe(gpa, "that file is a teammate's this round — write one of yours instead");
    }
    if (std.fs.path.dirname(full)) |dir| _ = std.Io.Dir.cwd().createDirPathStatus(ctx.io, dir, .default_dir) catch {};
    const clean = sanitizeModelText(gpa, p.value.content);
    defer gpa.free(clean);
    const is_append = std.mem.eql(u8, p.value.mode, "append") and p.value.content.len > 0;
    var final_bytes: usize = clean.len;
    if (is_append) {
        const prior = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(256 << 10)) catch &[_]u8{};
        defer if (prior.len > 0) gpa.free(prior);
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        defer joined.deinit(gpa);
        joined.appendSlice(gpa, prior) catch {};
        if (prior.len > 0 and prior[prior.len - 1] != '\n') joined.appendSlice(gpa, "\n\n") catch {};
        joined.appendSlice(gpa, clean) catch {};
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = full, .data = joined.items }) catch return dupe(gpa, "could not write file");
        final_bytes = joined.items.len;
    } else {
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = full, .data = clean }) catch return dupe(gpa, "could not write file");
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
            buf.appendSlice(gpa, std.fmt.allocPrint(gpa, "{s}|{d}\n", .{ wpath, final_bytes }) catch "") catch {};
            std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = mpath, .data = buf.items }) catch {};
        }
    }
    if (redirected)
        return std.fmt.allocPrint(gpa, "wrote {s} ({d} bytes) — that is your ONE assigned file this moment, so the write landed there (you named {s}); finish THIS file, then the engine gives you the next.", .{ wpath, final_bytes, p.value.path }) catch dupe(gpa, "wrote");
    return std.fmt.allocPrint(gpa, "{s} {s} — file is now {d} bytes", .{ if (is_append) "appended to" else "wrote", wpath, final_bytes }) catch dupe(gpa, "wrote");
}

fn editFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const OpJson = struct { op: []const u8 = "", anchor: []const u8 = "", text: []const u8 = "", at: usize = 0 };
    const A = struct { path: []const u8 = "", ops: []const OpJson = &.{} };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch
        return dupe(gpa, "edit_file arguments were not valid JSON (likely cut off) — send fewer/smaller ops this turn.");
    defer p.deinit();
    if (!safeRel(p.value.path)) return dupe(gpa, "bad path");
    if (p.value.ops.len == 0) return dupe(gpa, "edit_file needs an ops array — each op is replace/insert_before/insert_after/delete with an exact anchor snippet.");
    const npath = blk_np: {
        const wb = std.fs.path.basename(ctx.workdir);
        if (wb.len > 0 and p.value.path.len > wb.len + 1 and std.mem.startsWith(u8, p.value.path, wb) and p.value.path[wb.len] == '/')
            break :blk_np p.value.path[wb.len + 1 ..];
        break :blk_np p.value.path;
    };
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, npath }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    const original = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(1 << 20)) catch
        return std.fmt.allocPrint(gpa, "{s} does not exist (or is over 1MiB) — edit_file only changes an EXISTING file; use write_file to create a new one.", .{npath}) catch dupe(gpa, "file not found — use write_file to create it");
    defer gpa.free(original);
    var ops: std.ArrayListUnmanaged(bufedit.EditOp) = .empty;
    defer ops.deinit(gpa);
    for (p.value.ops) |o| {
        const kind: bufedit.OpKind =
            if (std.mem.eql(u8, o.op, "replace")) .replace else if (std.mem.eql(u8, o.op, "insert_before")) .insert_before else if (std.mem.eql(u8, o.op, "insert_after")) .insert_after else if (std.mem.eql(u8, o.op, "insert_at")) .insert_at else if (std.mem.eql(u8, o.op, "delete")) .delete else return std.fmt.allocPrint(gpa, "unknown op '{s}' — use replace | insert_before | insert_after | insert_at | delete", .{o.op}) catch dupe(gpa, "unknown op");
        ops.append(gpa, .{ .kind = kind, .anchor = o.anchor, .text = o.text, .at = o.at }) catch {};
    }
    const res = bufedit.apply(gpa, original, ops.items);
    if (!res.ok) return res.reject; // owned; caller frees. original file untouched.
    defer gpa.free(res.bytes);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = full, .data = res.bytes }) catch return dupe(gpa, "could not write the edited file");
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
            buf.appendSlice(gpa, std.fmt.allocPrint(gpa, "{s}|{d}\n", .{ npath, res.bytes.len }) catch "") catch {};
            std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = mpath, .data = buf.items }) catch {};
        }
    }
    return std.fmt.allocPrint(gpa, "edited {s} — {d} op(s) applied, file is now {d} bytes", .{ npath, ops.items.len, res.bytes.len }) catch dupe(gpa, "edited");
}

fn readFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { path: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!safeRel(p.value.path)) return dupe(gpa, "bad path");
    const rpath = blk_rp: {
        const wb = std.fs.path.basename(ctx.workdir);
        if (wb.len > 0 and p.value.path.len > wb.len + 1 and std.mem.startsWith(u8, p.value.path, wb) and p.value.path[wb.len] == '/')
            break :blk_rp p.value.path[wb.len + 1 ..];
        break :blk_rp p.value.path;
    };
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, rpath }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(256 << 10)) catch return dupe(gpa, "not found");
    defer gpa.free(data);
    const clean = sanitizeModelText(gpa, data);
    defer gpa.free(clean);
    const owned = ctx.my_files.len > 0 and fileOwnedBy(ctx.my_files, p.value.path);
    return dupe(gpa, clip(clean, if (owned) 32000 else 8000));
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
    const root = patchSystemRoot(ctx) orelse return dupe(gpa, "patch_system disabled: set NL_PATCH_SYSTEM_ROOT (or NL_OPEN_CLAW_ROOT) to an engine source root");

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
        return patchSystemPatch(ctx, root, p.value.patch);
    }

    if (!safeRel(p.value.path)) return dupe(gpa, "bad path");
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
        if (std.fs.path.dirname(full)) |dir| _ = std.Io.Dir.cwd().createDirPathStatus(ctx.io, dir, .default_dir) catch {};
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = full, .data = p.value.content }) catch return dupe(gpa, "could not write file");
        return std.fmt.allocPrint(gpa, "patch_system wrote {d} bytes to {s}", .{ p.value.content.len, p.value.path }) catch dupe(gpa, "patch_system wrote");
    }

    if (std.mem.eql(u8, p.value.mode, "replace")) {
        if (p.value.find.len == 0) return dupe(gpa, "replace mode needs non-empty find");
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(256 << 10)) catch return dupe(gpa, "not found");
        defer gpa.free(data);
        const out = replaceOne(gpa, data, p.value.find, p.value.replace) orelse return dupe(gpa, "find text missing or ambiguous (need exactly one match)");
        defer gpa.free(out);
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = full, .data = out }) catch return dupe(gpa, "could not write file");
        return std.fmt.allocPrint(gpa, "patch_system replaced 1 match in {s}", .{p.value.path}) catch dupe(gpa, "patch_system replaced");
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
    const base = if (std.mem.eql(u8, p.value.root, "system")) (patchSystemRoot(ctx) orelse return dupe(gpa, "root=system needs NL_PATCH_SYSTEM_ROOT set")) else ctx.workdir;
    const rel = if (p.value.path.len == 0 or std.mem.eql(u8, p.value.path, ".")) "" else p.value.path;
    if (rel.len > 0 and !safeRel(rel)) return dupe(gpa, "bad path");
    const full = if (rel.len > 0) (std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, rel }) catch return dupe(gpa, "oom")) else (gpa.dupe(u8, base) catch return dupe(gpa, "oom"));
    defer gpa.free(full);
    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH", "NL_LLM_KEY" }) |k| env.put(k, "") catch {};
    const py = if (builtin.os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", LIST_DIR_PY, full };
    const r = std.process.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .stdout_limit = .limited(64 << 10), .stderr_limit = .limited(8 << 10) }) catch return dupe(gpa, "list_dir failed to run");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
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
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH", "NL_LLM_KEY" }) |k| env.put(k, "") catch {};
    const py = if (builtin.os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", RUN_TESTS_PY };
    const r = std.process.run(gpa, ctx.io, .{ .argv = &argv, .cwd = .{ .path = ctx.workdir }, .environ_map = &env, .stdout_limit = .limited(128 << 10), .stderr_limit = .limited(16 << 10) }) catch return dupe(gpa, "run_tests failed to run");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
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
        .{ "kill_process", "kill_proc" }, .{ "killproc", "kill_proc" }, .{ "kill", "kill_proc" },
        .{ "block_address", "block_ip" }, .{ "blockip", "block_ip" },   .{ "block", "block_ip" },
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
    if (!safeRel(p.value.path)) return dupe(gpa, "bad path");
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, p.value.path }) catch return dupe(gpa, "oom");
    defer gpa.free(full);
    std.Io.Dir.cwd().deleteFile(ctx.io, full) catch return dupe(gpa, "could not delete (not found?)");
    return std.fmt.allocPrint(gpa, "deleted {s}", .{p.value.path}) catch dupe(gpa, "deleted");
}

fn patchSystemPatch(ctx: *ToolCtx, root: []const u8, patch: []const u8) []u8 {
    const gpa = ctx.gpa;
    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", PATCH_SYSTEM_PATCH_PY, root, patch };
    const r = std.process.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .stdout_limit = .limited(128 << 10), .stderr_limit = .limited(32 << 10) }) catch return dupe(gpa, "patch_system patch runner failed");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (r.term == .exited and r.term.exited == 0 and std.mem.trim(u8, r.stdout, " \r\n\t").len > 0)
        return dupe(gpa, clip(std.mem.trim(u8, r.stdout, " \r\n\t"), 5000));
    return std.fmt.allocPrint(gpa, "patch failed\nstdout:\n{s}\nstderr:\n{s}", .{ clip(r.stdout, 2500), clip(r.stderr, 1500) }) catch dupe(gpa, "patch failed");
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
    return host.len > 0;
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

/// curl a page with a BROWSER user-agent. The bot UA in curlToText is exactly why sites block a plain curl and the
/// codebase leaned on the jina reader; a browser UA makes a direct fetch work on most sites (and is what SERPs need).
/// primitive (no ToolCtx): browser-UA curl into `tmp`, guarded, read back. Lets non-tool callers (the engine's
/// retrieval seed) reuse the exact same fetch. Caller frees the returned body.
fn curlBrowserTo(io: std.Io, gpa: std.mem.Allocator, tmp: []const u8, url: []const u8, deadline_ms: u32, limit: usize) []u8 {
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sSL", "--max-time", "20", "--connect-timeout", "10", "-o", tmp, "-A", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36", "-H", "Accept-Language: en-US,en;q=0.9", url }) catch return dupe(gpa, "");
    spawnGuarded(io, av.items, deadline_ms);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, tmp, gpa, .limited(limit)) catch (gpa.dupe(u8, "") catch @constCast(""));
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    return raw;
}

fn curlBrowser(ctx: *ToolCtx, url: []const u8, deadline_ms: u32, limit: usize) []u8 {
    const gpa = ctx.gpa;
    const tmp = std.fmt.allocPrint(gpa, "{s}/.crawl-{s}.tmp", .{ ctx.run_dir, ctx.mind }) catch return dupe(gpa, "");
    defer gpa.free(tmp);
    return curlBrowserTo(ctx.io, gpa, tmp, url, deadline_ms, limit);
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
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') out.append(gpa, c) catch {} else if (c == ' ') out.append(gpa, '+') catch {} else out.appendSlice(gpa, std.fmt.allocPrint(gpa, "%{X:0>2}", .{c}) catch "") catch {};
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, q) catch @constCast(""));
}

/// CRAWL-AS-SEARCH: our crawler fetches an HTML SERP with a browser UA and decodes the result links itself — no
/// jina, no firecrawl, no key. DuckDuckGo's no-JS html endpoint is the PRIMARY target: it returns static result
/// links (uddg= redirects we decode) and reaches good sources (arxiv/nature/springer for AI queries) where Bing
/// now serves a consent-gated JS shell with zero harvestable results. Bing stays as a secondary in case DDG
/// rate-limits. Both put the query last in the URL, so a single prefix+enc concat builds each (allocPrint needs a
/// comptime fmt string, which a runtime engine list can't provide).
/// SELF-HEALING CRAWL-AS-SEARCH (no ToolCtx) so the engine's retrieval seed can reuse it. `dir`+`tag` key the
/// per-caller temp file. No single keyless engine is reliable everywhere — a residential IP gets clean results from
/// DuckDuckGo while a datacenter/container IP is bounced to its homepage; Bing serves a JS consent-shell; Mojeek
/// rate-limits to a captcha. So we ROTATE a list of keyless HTML engines and use whichever returns real results THIS
/// time, harvested + decoded by OUR crawler (no jina/firecrawl/key). A per-engine COOLDOWN persisted to disk skips an
/// engine that just bounced/captcha'd, so we neither re-hammer it nor waste a fetch every search — the "it fixes
/// itself" property: as one engine goes down the rotation routes around it, and recovers it when the cooldown lapses.
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
    for (cd) |c| hb.appendSlice(gpa, std.fmt.allocPrint(gpa, "{d}\n", .{c}) catch "") catch {};
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
        spawnGuarded(io, av.items, 14000);
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
    const proc = std.process.run(gpa, io, .{ .argv = av.items, .stdout_limit = .limited(256 << 10) }) catch return empty;
    gpa.free(proc.stderr);
    if (proc.term != .exited or proc.term.exited != 0) {
        gpa.free(proc.stdout);
        return empty;
    }
    gpa.free(empty);
    return proc.stdout;
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

fn webFetch(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { url: []const u8 = "", query: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!urlAllowed(p.value.url)) return dupe(gpa, "blocked url (only public http/https; no local/internal hosts)");
    if (!egressAllowed(ctx.egress_allow, p.value.url)) return dupe(gpa, "blocked: host not on the egress allowlist (NL_EGRESS_ALLOWLIST)");
    if (ctx.egress_allow.len == 0) {
        const cm = crawlPageFit(ctx, p.value.url, p.value.query, 1800);
        if (cm.len > 0) return cm;
        gpa.free(cm);
    }
    const raw = curlToText(ctx, p.value.url, false, 26000, 512 << 10);
    defer gpa.free(raw);
    if (raw.len == 0) return dupe(gpa, "(fetch returned nothing or timed out — try another source)");
    const text = htmlToText(gpa, raw);
    defer gpa.free(text);
    const body = if (text.len > 80) text else raw;
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
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH", "NL_LLM_KEY" }) |k| env.put(k, "") catch {};
    const py = if (builtin.os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", OSINT_SCAN_PY, p.value.url };
    const r = std.process.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .stdout_limit = .limited(256 << 10), .stderr_limit = .limited(32 << 10) }) catch return dupe(gpa, "osint_scan failed to run");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
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
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH", "NL_LLM_KEY" }) |k| env.put(k, "") catch {};
    const py = if (builtin.os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", DEEP_CRAWL_PY, p.value.url, ds, ps, same };
    const r = std.process.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .stdout_limit = .limited(512 << 10), .stderr_limit = .limited(48 << 10) }) catch return dupe(gpa, "deep_crawl failed to run");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
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

fn looksBlocked(text: []const u8) bool {
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
        inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};
        var lbuf: [8]u8 = undefined;
        const ls = std.fmt.bufPrint(&lbuf, "{d}", .{limit}) catch "5";
        const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
        const argv = [_][]const u8{ py, "-c", SEARCH_PY, source, query, ls, workdir };
        const r = std.process.run(gpa, io, .{ .argv = &argv, .environ_map = &env, .stdout_limit = .limited(256 << 10), .stderr_limit = .limited(8 << 10) }) catch return dupe(gpa, "");
        defer gpa.free(r.stderr);
        links = r.stdout;
    }
    if (std.mem.trim(u8, links, " \r\n\t").len == 0) return links;
    const enriched = enrichResults(io, gpa, run_dir, tag, query, links, 3);
    gpa.free(@constCast(links));
    return enriched;
}

/// Keyless multi-engine web search tool: our crawler first, then the self-healing registry (see searchWeb).
fn webSearch(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { query: []const u8 = "", source: []const u8 = "web", limit: u32 = 5 };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (std.mem.trim(u8, p.value.query, " \r\n\t").len == 0) return dupe(gpa, "empty query");
    if (ctx.egress_allow.len > 0) return dupe(gpa, "web_search is disabled under an egress allowlist (search returns arbitrary hosts) — fetch a specific allowlisted URL with web_fetch/fetch_json");
    const lim = if (p.value.limit == 0 or p.value.limit > 10) 5 else p.value.limit;
    const out = searchWeb(ctx.io, gpa, ctx.environ, ctx.run_dir, ctx.workdir, ctx.mind, p.value.source, p.value.query, lim);
    defer gpa.free(@constCast(out));
    if (std.mem.trim(u8, out, " \r\n\t").len == 0) return dupe(gpa, "(no results: all search backends unavailable — try again later)");
    return dupe(gpa, clip(out, 4000));
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
    \\import sys,re,collections,urllib.request,urllib.parse
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
    \\    if h.startswith(("localhost","127.","0.0.0.0","169.254.","10.","192.168.")) or h.endswith(".local"):
    \\        return False
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
    \\while q and len(pages)<max_pages:
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
/// .py files compile (nudges the swarm toward authoring tests); TIER 3 = non-code artifacts, a presence
/// heuristic capped below 100 so only real tests reach a perfect score. Model-uneditable: it runs via
/// `python -c BENCH_PY`, so the swarm cannot fake or dodge its own fitness function.
pub const BENCH_PY =
    \\import sys,json,os,glob,subprocess,re,py_compile
    \\def out(d):
    \\    sys.stdout.write(json.dumps(d)+"\n"); sys.exit(0)
    \\def ff(txt):
    \\    body=re.split(r"-{3,}[\r\n]+Ran \d",txt)[0]
    \\    r=[]
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
    \\    return r[:6]
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
    \\    pys=[f for f in glob.glob("*.py")+glob.glob("*/*.py") if not os.path.basename(f).startswith("_")]
    \\    tests=[f for f in pys if os.path.basename(f).startswith("test_") or os.path.basename(f).endswith("_test.py")]
    \\    if os.path.isdir("tests"): tests+=glob.glob("tests/**/*.py",recursive=True)
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
    \\                fails=ff(txt)
    \\                out({"status":"ok","passed":p,"total":tot,"failures":fails,"tier":1})
    \\    if pys:
    \\        ok=0; tot=0; fails=[]
    \\        for f in pys:
    \\            tot+=1
    \\            try: py_compile.compile(f,doraise=True); ok+=1
    \\            except Exception as e: fails.append((f+": "+str(e).splitlines()[0])[:90])
    \\        out({"status":"ok","passed":ok,"total":tot,"failures":fails[:5],"tier":2})
    \\    docs=[f for f in glob.glob("*")+glob.glob("*/*") if os.path.isfile(f) and not os.path.basename(f).startswith((".","_"))]
    \\    if docs:
    \\        sc=0.0
    \\        tw=int(os.environ.get("NL_DOC_TARGET_WORDS","0") or 0)
    \\        for f in docs:
    \\            try: t=open(f,encoding="utf-8",errors="replace").read()
    \\            except Exception: t=""
    \\            if f.lower().endswith(".html"): sc+= 1 if ("<title" in t.lower() and "<body" in t.lower()) else 0
    \\            elif f.lower().endswith(".md"):
    \\                if tw>0: sc+= min(1.0, sum(len(ln.split()) for ln in t.split("\n") if ln.strip() and not ln.strip().startswith("#"))/tw)
    \\                else: sc+= 1 if t.count("#")>0 and len(t)>200 else 0
    \\            else: sc+= 1 if len(t)>40 else 0
    \\        denom=max(len(docs), int(os.environ.get("NL_DOC_FILE_COUNT","0") or 0))
    \\        pct=min(99,int(sc*100/denom)) if denom else 0
    \\        out({"status":"ok","passed":pct,"total":100,"failures":[],"tier":3})
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
/// moment and deadlock the whole round), run `python -c PYRUN script.py [arg]` — it re-execs the script with a
/// HARD 25s wall-clock cap and kills it on timeout, so a runaway script fails fast instead of hanging the swarm.
/// (Defense-in-depth behind the engine's hang watchdog.) cwd + env (keys blanked) are inherited by the child.
pub const PYRUN =
    \\import subprocess,sys
    \\try:
    \\    r=subprocess.run([sys.executable]+sys.argv[1:],capture_output=True,text=True,timeout=25)
    \\    sys.stdout.write(r.stdout or ""); sys.stderr.write(r.stderr or ""); sys.exit(r.returncode)
    \\except subprocess.TimeoutExpired:
    \\    sys.stderr.write("TIMEOUT: this script exceeded 25s wall-clock and was killed"); sys.exit(124)
    \\except Exception as e:
    \\    sys.stderr.write("launcher error: "+str(e)); sys.exit(1)
;

/// The engine-owned RUNTIME SMOKE TEST — does the deliverable actually RUN, not just pass presence checks? Run
/// once per round (cwd = workdir) via `python -c SMOKE_PY`. It finds the most likely server entry (a .py that
/// imports http.server/socketserver and has a `__main__`), launches it on a FREE port (passed as AINET_PORT/PORT
/// env), waits for it to bind, probes `GET /`, then tears it down — capturing whether it STARTED, what it SERVED,
/// and the stderr if it crashed on launch. This is the ground truth a unit/presence benchmark misses: a server
/// that `assertIn("http.server", src)` passes but `ModuleNotFoundError`s the moment you run it. Pure stdlib;
/// bounded (~6s start wait + 2s probe + 3s teardown); returns {"status":"no-server"} when nothing runnable exists
/// (so non-web builds are never penalized). Never throws (any failure → status error / started:false).
pub const SMOKE_PY =
    \\import sys,os,json,socket,subprocess,time,glob
    \\try: import urllib.request as U
    \\except Exception: U=None
    \\def out(d): sys.stdout.write(json.dumps(d)+"\n"); sys.exit(0)
    \\try:
    \\    cands=[]
    \\    for p in glob.glob("**/*.py",recursive=True):
    \\        b=os.path.basename(p)
    \\        if b.startswith(("spec_test","test_","_")) or b.endswith("_test.py") or "/test" in p.replace(os.sep,"/"): continue
    \\        try: t=open(p,encoding="utf-8",errors="replace").read()
    \\        except Exception: continue
    \\        if ("http.server" in t or "socketserver" in t or "BaseHTTPRequestHandler" in t) and "__main__" in t:
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
    \\    s=socket.socket(); s.bind(("127.0.0.1",0)); port=s.getsockname()[1]; s.close()
    \\    env=dict(os.environ); env["AINET_PORT"]=str(port); env["PORT"]=str(port)
    \\    try: proc=subprocess.Popen([sys.executable,entry],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
    \\    except Exception as e: out({"status":"ok","entry":entry,"started":False,"served":None,"stderr":("launch failed: "+str(e))[:300]})
    \\    started=False; t0=time.time()
    \\    while time.time()-t0<6:
    \\        try: c=socket.create_connection(("127.0.0.1",port),0.3); c.close(); started=True; break
    \\        except OSError:
    \\            if proc.poll() is not None: break
    \\            time.sleep(0.2)
    \\    served=None; api_ok=True; api_note=""
    \\    if started and U is not None:
    \\        try: r=U.urlopen("http://127.0.0.1:%d/"%port,timeout=2); served=r.status
    \\        except Exception as e: served="err:"+str(e)[:50]
    \\        saw2=False; saw5=False
    \\        for ap in ("/api/feed","/api/agents","/api/trending","/api/posts","/api"):
    \\            try:
    \\                rr=U.urlopen("http://127.0.0.1:%d%s"%(port,ap),timeout=2); c=rr.status
    \\                if c<300: saw2=True; api_note="%s -> %d"%(ap,c); break
    \\                if c>=500: saw5=True; api_note="%s -> %d"%(ap,c)
    \\            except Exception as e:
    \\                c=getattr(e,"code",None)
    \\                if c is not None and c<300: saw2=True; api_note="%s -> %d"%(ap,c); break
    \\                if (c is None) or c>=500: saw5=True; api_note="%s -> %s"%(ap,("HTTP %d"%c) if c else ("crash:"+str(getattr(e,"reason",e) or e)[:40]))
    \\        api_ok = saw2 or (not saw5)
    \\    try: proc.terminate(); proc.wait(timeout=3)
    \\    except Exception:
    \\        try: proc.kill()
    \\        except Exception: pass
    \\    err=""
    \\    try: err=(proc.stderr.read() or b"").decode("utf-8","replace")[-300:]
    \\    except Exception: pass
    \\    out({"status":"ok","entry":entry,"started":started,"served":served,"api_ok":api_ok,"api_note":api_note,"stderr":err.strip()[-300:]})
    \\except Exception as e:
    \\    out({"status":"error","msg":str(e)[:160]})
;

/// INTERFACE RECONCILIATION (`python -c INTERFACES_PY`, cwd = workdir): a lightweight static check across all the
/// project's .py files for the #1 parallel multi-file build bug — two minds building interdependent files that
/// don't agree on a contract (observed: app.py calls handlers.get_feed() while handlers.py defines handle_feed()).
/// Parses each module with ast, collects the top-level def/class names it DEFINES, then flags every `module.attr`
/// reference whose `module` is a local file but whose `attr` is NOT defined there (with a difflib "did you mean"),
/// plus any file that fails to parse (a syntax error breaks the whole build). Prints ONE JSON line; never throws.
pub const INTERFACES_PY =
    \\import ast,os,glob,json,sys,difflib
    \\def out(d): sys.stdout.write(json.dumps(d)+"\n"); sys.exit(0)
    \\try:
    \\    defs={}; srcs={}
    \\    for p in glob.glob("**/*.py",recursive=True):
    \\        if "__pycache__" in p: continue
    \\        try: s=open(p,encoding="utf-8",errors="replace").read()
    \\        except Exception: continue
    \\        srcs[p]=s
    \\        base=os.path.basename(p)[:-3]
    \\        try: t=ast.parse(s)
    \\        except SyntaxError: continue
    \\        ns=set(n.name for n in t.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)))
    \\        defs[base]=defs.get(base,set())|ns
    \\    issues=[]
    \\    for p,s in srcs.items():
    \\        b=os.path.basename(p)
    \\        try: t=ast.parse(s)
    \\        except SyntaxError as e: issues.append(b+": SYNTAX ERROR line "+str(getattr(e,"lineno","?"))+" — the file does not parse, so every importer of it breaks"); continue
    \\        for n in ast.walk(t):
    \\            if isinstance(n,ast.Attribute) and isinstance(n.value,ast.Name):
    \\                m=n.value.id
    \\                if m in defs and m!=b[:-3] and n.attr not in defs[m] and not n.attr.startswith("_") and defs[m]:
    \\                    sug=difflib.get_close_matches(n.attr,list(defs[m]),1,0.4)
    \\                    issues.append(b+" calls "+m+"."+n.attr+"() but "+m+".py defines no such name"+((" (did you mean "+sug[0]+"?)") if sug else ""))
    \\    issues=sorted(set(issues))[:12]
    \\    out({"mismatches":issues,"count":len(issues)})
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
        "src/orchestrate/supervisor.zig",
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
        "src/orchestrate/supervisor.zig",
    };
    for (hints) |h| if (std.mem.indexOf(u8, patch, h) != null) return true;
    return false;
}

fn patchSystemHighImpact(mode: []const u8, path: []const u8, content: []const u8, patch: []const u8) bool {
    if (std.mem.eql(u8, mode, "patch")) return true;
    if (content.len > 1600) return true;
    if (patch.len > 2000) return true;
    if (std.mem.startsWith(u8, path, "src/worker/")) return true;
    if (std.mem.startsWith(u8, path, "src/orchestrate/")) return true;
    if (std.mem.startsWith(u8, path, "src/auth/")) return true;
    return false;
}

fn patchSystemRoot(ctx: *ToolCtx) ?[]const u8 {
    const v = if (ctx.environ.get("NL_PATCH_SYSTEM_ROOT")) |r| r else (ctx.environ.get("NL_OPEN_CLAW_ROOT") orelse return null);
    const t = std.mem.trim(u8, v, " \r\n\t");
    if (t.len == 0) return null;
    return t;
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

fn safeRel(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[0] == '\\') return false;
    if (std.mem.indexOf(u8, p, "..") != null) return false;
    return true;
}

/// True if a file with `path`'s basename was already written this run (recorded in run_dir/.build_manifest as
/// "path|bytes" lines). The engine-authoritative record — avoids a racy filesystem stat. Used by writeFile's
/// round-2+ coverage rescue: a teammate's file that does NOT exist yet may be created by anyone.
fn builtAlready(ctx: *ToolCtx, path: []const u8) bool {
    const gpa = ctx.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/.build_manifest", .{ctx.run_dir}) catch return false;
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, mpath, gpa, .limited(64 << 10)) catch return false;
    defer gpa.free(data);
    const pb = std.fs.path.basename(path);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const fp = std.mem.trim(u8, ln[0..bar], " \r\t");
        if (fp.len > 0 and std.mem.eql(u8, std.fs.path.basename(fp), pb)) return true;
    }
    return false;
}

/// True if `path` matches a comma+space entry of `list` (the format mindFiles emits) by BASENAME — because the
/// system prompt makes minds write bare filenames (e.g. 'errors.py') while the slices carry full blueprint paths
/// (e.g. 'src/todolib/errors.py'). Whole-basename equality (not substring), so 'errors.py' never matches
/// 'myerrors.py'. Used by writeFile's file-partition guard.
fn fileOwnedBy(list: []const u8, path: []const u8) bool {
    if (list.len == 0) return false;
    const pb = std.fs.path.basename(path);
    if (pb.len == 0) return false;
    var it = std.mem.splitSequence(u8, list, ", ");
    while (it.next()) |e| {
        const t = std.mem.trim(u8, e, " \r\n\t");
        if (t.len == 0) continue;
        if (std.mem.eql(u8, std.fs.path.basename(t), pb)) return true;
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
    return gpa.dupe(u8, s) catch @constCast("error");
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
