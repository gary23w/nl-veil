//! The mind's toolbelt, in Zig — the keyless, single-purpose tools a mind calls during a moment to build,

const std = @import("std");
const builtin = @import("builtin");
const Mem = @import("memory.zig").Mem;
const commons = @import("commons.zig");

extern "kernel32" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) callconv(.winapi) i32;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

const KillGuard = struct {
    id: std.process.Child.Id,
    deadline_ms: u32,
    done: *std.atomic.Value(bool),
    fn watch(g: KillGuard) void {
        var waited: u32 = 0;
        while (waited < g.deadline_ms) : (waited += 150) {
            if (builtin.os.tag == .windows) Sleep(150) else std.posix.nanosleep(0, 150 * std.time.ns_per_ms);
            if (g.done.load(.monotonic)) return;
        }
        if (g.done.load(.monotonic)) return;
        if (builtin.os.tag == .windows) {
            _ = TerminateProcess(@ptrCast(g.id), 1);
        } else std.posix.kill(g.id, 9) catch {};
    }
};

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

fn curlToText(ctx: *ToolCtx, url: []const u8, json: bool, deadline_ms: u32, limit: usize) []u8 {
    const gpa = ctx.gpa;
    const tmp = std.fmt.allocPrint(gpa, "{s}/.fetch-{s}.tmp", .{ ctx.run_dir, ctx.mind }) catch return dupe(gpa, "oom");
    defer gpa.free(tmp);
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sSL", "--max-time", "20", "--connect-timeout", "10", "--speed-limit", "1", "--speed-time", "15", "-o", tmp, "-A", "neuron-loops-mind/1.0" }) catch return dupe(gpa, "oom");
    if (json) av.appendSlice(gpa, &.{ "-H", "Accept: application/json" }) catch {};
    av.append(gpa, url) catch {};
    spawnGuarded(ctx.io, av.items, deadline_ms);
    const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, tmp, gpa, .limited(limit)) catch (gpa.dupe(u8, "") catch @constCast(""));
    std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
    return raw;
}

pub const ToolCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    run_dir: []const u8,
    workdir: []const u8,
    scope: []const u8,
    mind: []const u8,
    round: u32,
    mem: Mem,
    files_written: *u32,
    observed: *u32,
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
    one_slot: bool = false,
    slot_path: []const u8 = "",
    fmtx: ?*std.Io.Mutex = null,
};

fn lockFiles(ctx: *ToolCtx) void {
    if (ctx.fmtx) |m| m.lockUncancelable(ctx.io);
}
fn unlockFiles(ctx: *ToolCtx) void {
    if (ctx.fmtx) |m| m.unlock(ctx.io);
}

fn hiveStore(ctx: *ToolCtx, fact: []const u8) void {
    const tagged = std.fmt.allocPrint(ctx.gpa, "[{s} r{d}] {s}", .{ ctx.mind, ctx.round, fact }) catch fact;
    defer if (tagged.ptr != fact.ptr) ctx.gpa.free(tagged);
    _ = ctx.mem.observe(KNOWLEDGE_SCOPE, tagged);
}

pub const SKILL_SCOPE = "skills";

pub const PLAYBOOK_SCOPE = "playbook";

pub const SCORE_SCOPE = "score";

pub const KNOWLEDGE_SCOPE = "knowledge";

pub const VERIFIED_SCOPE = "verified";

pub const GAP_SCOPE = "gaps";

pub const PROPOSAL_SCOPE = "proposals";

pub const SIM_SCOPE = "simulations";

pub const EPISODE_SCOPE = "episodes";
pub const STRATEGY_SCOPE = "strategy";
pub const ARCH_SCOPE = "architecture";

pub const CURRICULUM_SCOPE = "curriculum";

pub const CANARY_SCOPE = "canary";

pub const AUTONOMY_SCOPE = "autonomy";

pub const SPACE_SCOPE = "space";

pub const TOOL_SCOPE = "tools";
pub const MAX_TOOLS = 16;
pub const MAX_TOOL_BODY = 8 * 1024;
pub const MAX_TOOL_PARAMS = 4 * 1024;

pub const SCHEMA =
    \\{"type":"function","function":{"name":"run_python","description":"Run a short Python script (no GUI) in the build workdir and get its stdout/stderr. Use it to compute, transform data, or generate files. API keys are NOT available to the script.","parameters":{"type":"object","properties":{"code":{"type":"string","description":"the Python source to execute"}},"required":["code"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the build workdir (creates parent dirs). To GROW a long document (e.g. add the next scene to a chapter) pass mode:\"append\" with ONLY the new text — it is concatenated onto the existing file, so you never resend (or truncate) prior content. mode:\"overwrite\" (default) replaces the file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the build workdir.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"patch_system","description":"RSI engine edit tool. Read/write/replace/apply_patch under NL_PATCH_SYSTEM_ROOT (or legacy NL_OPEN_CLAW_ROOT). Mutating edits are gated: provide proposal + measurable success_criterion; high-impact edits also require simulate_change; privileged zones require explicit operator approval.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"relative file path under the configured patch-system root (required for read/write/replace)"},"mode":{"type":"string","enum":["read","write","replace","patch"],"description":"operation (default: read)"},"content":{"type":"string","description":"new file content for write mode"},"find":{"type":"string","description":"exact text to replace (replace mode)"},"replace":{"type":"string","description":"replacement text (replace mode)"},"patch":{"type":"string","description":"apply_patch payload with *** Begin Patch / *** End Patch markers (patch mode)"},"proposal":{"type":"string","description":"proposal title/id from propose_change (required for mutating edits)"},"success_criterion":{"type":"string","description":"measurable success criterion tied to the proposal (required for mutating edits)"},"limit":{"type":"integer","description":"max bytes to read (default 12000, max 262144)"}},"required":[]}}},
    \\{"type":"function","function":{"name":"list_dir","description":"List the files (with sizes) in a directory so you can SEE what exists before reading or editing. Defaults to your build workdir; pass root=\"system\" to list the patch_system engine root.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"relative dir, default '.'"},"root":{"type":"string","enum":["workdir","system"],"description":"workdir (default) or the patch_system root"}},"required":[]}}},
    \\{"type":"function","function":{"name":"run_tests","description":"Run the deliverable's test suite (pytest, else a test_*.py) in your build workdir and get the pass/fail output. VERIFY your code after writing or patching it — write, run_tests, fix, run_tests again. This is how you make sure a change actually works.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"delete_file","description":"Delete a file you created in your build workdir (clean up a dead end, a wrong scaffold, or junk).","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"host_status","description":"Read the LIVE state of the host/machine you are operating (its telemetry: mode, threat_score, processes, connections, persistence, infections). Call it to see the current state before you act and again after you act to VERIFY. Returns the raw telemetry.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"host_command","description":"OPERATE the host: issue ONE command to it directly (this is how you actually act on the machine - do NOT write files describing a fix). Use it to remediate: remove_persistence <unit> (the ROOT CAUSE), kill_proc <pid|name>, block_ip <ip>, restore_file <path>, isolate, scan. To fully clean an infection, remove its persistence AND block its C2 AND kill its process.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"one command line, e.g. 'remove_persistence sysupdate.timer'"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"HTTP GET a URL and return its readable text content (HTML tags stripped, truncated). Use it to read a page you already have the URL for.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_search","description":"Keyless web search — find URLs + snippets for a query. Use this FIRST to discover sources, then web_fetch the best result.","parameters":{"type":"object","properties":{"query":{"type":"string"},"source":{"type":"string","enum":["web","wikipedia","hackernews","arxiv"],"description":"web=general (default), or a specific source"},"limit":{"type":"integer","description":"max results (default 5)"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"fetch_json","description":"HTTP GET a JSON/text API endpoint and return the raw body (not HTML-stripped). Use for REST/JSON APIs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"read_url","description":"Read a URL as clean, LLM-ready text via a reader proxy that renders JS and works on sites a plain fetch can't. Prefer this over web_fetch for real articles/pages.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"osint_scan","description":"Public-source OSINT scan for one URL: extract high-signal leads (emails, phones, domains, docs, socials, and notable outbound links). Uses only normal public HTTP/HTTPS fetches.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"deep_crawl","description":"Recursive public-web crawl from a seed URL with bounded depth/pages, extracting lead-rich links and contact/identity indicators from each page. Designed for lead expansion across many hops.","parameters":{"type":"object","properties":{"url":{"type":"string"},"depth":{"type":"integer","description":"crawl depth, default 2 (max 4)"},"max_pages":{"type":"integer","description":"max pages to fetch, default 30 (max 120)"},"same_host":{"type":"boolean","description":"stay on seed host only (default true)"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall","description":"Recall facts from your memory relevant to a query.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"note_stance","description":"Record how you feel about a topic (your stance).","parameters":{"type":"object","properties":{"topic":{"type":"string"},"feeling":{"type":"string"}},"required":["topic","feeling"]}}},
    \\{"type":"function","function":{"name":"save_skill","description":"Save a NEW reusable skill you developed — a method, code snippet, or step-by-step approach — into the swarm's shared skill library, so you and teammates can reuse it instead of re-deriving it. Do NOT re-save a skill already in the 'Reusable skills' list you were shown; save each distinct skill ONCE.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"a short skill name"},"skill":{"type":"string","description":"the reusable how-to / snippet / approach, concrete enough to follow again"}},"required":["name","skill"]}}},
    \\{"type":"function","function":{"name":"set_directive","description":"IMPROVE HOW YOUR SWARM WORKS. Write a concise process directive — a lesson about a better way to operate — into the swarm's shared, self-authored operating PLAYBOOK. It is injected into every mind's instructions from now on, so this is how the swarm improves its own process over time. Use it when you notice what's working or what's failing (e.g. 'read a file before rewriting it', 'one mind owns each section', 'verify code by running it'). Phrase it as an imperative rule. Don't repeat a directive already in the playbook.","parameters":{"type":"object","properties":{"directive":{"type":"string","description":"one concise imperative process rule for the swarm to follow"}},"required":["directive"]}}},
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

pub const SCOUT_SCHEMA =
    \\{"type":"function","function":{"name":"web_search","description":"Keyless web search — find URLs + snippets for a query. Use this FIRST to discover sources, then read_url the best result.","parameters":{"type":"object","properties":{"query":{"type":"string"},"source":{"type":"string","enum":["web","wikipedia","hackernews","arxiv"]},"limit":{"type":"integer"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"read_url","description":"Read a URL as clean, LLM-ready text via a reader proxy that renders JS. Prefer this over web_fetch for real articles/specs.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"HTTP GET a URL and return its readable text content (HTML stripped).","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
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

pub const ASSEMBLER_SCHEMA =
    \\{"type":"function","function":{"name":"write_file","description":"Write a UTF-8 text file at a relative path inside the build workdir (creates parent dirs). To GROW a long document (e.g. add the next scene to a chapter) pass mode:\"append\" with ONLY the new text — it is concatenated onto the existing file, so you never resend (or truncate) prior content. mode:\"overwrite\" (default) replaces the file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["overwrite","append"]}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file (relative path) from the build workdir.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"observe","description":"Store one concrete fact you learned into your long-term memory.","parameters":{"type":"object","properties":{"fact":{"type":"string"}},"required":["fact"]}}},
    \\{"type":"function","function":{"name":"recall_hive","description":"Pull what the hive already LEARNED before you build: spreading-activation recall across the shared collective memory. You are shown a list of topics the hive knows — call this with the one you need (e.g. 'axum routing', 'JWT auth') to get the concrete pattern/snippet, instead of guessing or redoing research.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}
;

pub fn execute(ctx: *ToolCtx, name: []const u8, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    if (std.mem.eql(u8, name, "run_python")) return runPython(ctx, args_json);
    if (std.mem.eql(u8, name, "write_file")) return writeFile(ctx, args_json);
    if (std.mem.eql(u8, name, "read_file")) return readFile(ctx, args_json);
    if (std.mem.eql(u8, name, "patch_system")) return patchSystem(ctx, args_json);
    if (std.mem.eql(u8, name, "list_dir")) return listDir(ctx, args_json);
    if (std.mem.eql(u8, name, "run_tests")) return runTests(ctx, args_json);
    if (std.mem.eql(u8, name, "delete_file")) return deleteFile(ctx, args_json);
    if (std.mem.eql(u8, name, "host_status")) return hostStatus(ctx, args_json);
    if (std.mem.eql(u8, name, "host_command")) return hostCommand(ctx, args_json);
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
        hiveStore(ctx, p.value.fact);
        const total = ctx.mem.factCount(KNOWLEDGE_SCOPE);
        return std.fmt.allocPrint(gpa, "shared with the hive ({d} collective facts; every teammate can now recall_hive it)", .{total}) catch dupe(gpa, "shared");
    }
    if (std.mem.eql(u8, name, "recall_hive")) {
        const A = struct { query: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
        const r = ctx.mem.assoc(KNOWLEDGE_SCOPE, p.value.query, 1, 12);
        if (r.len == 0) {
            gpa.free(r);
            return dupe(gpa, "(the hive knows nothing relevant yet — be the first to share something)");
        }
        return r;
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
    if (std.mem.eql(u8, name, "send_message")) {
        const A = struct { to: []const u8 = "all", text: []const u8 = "" };
        const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
        defer p.deinit();
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

fn isBuiltinTool(n: []const u8) bool {
    const builtins = [_][]const u8{ "run_python", "write_file", "read_file", "patch_system", "list_dir", "run_tests", "delete_file", "web_fetch", "web_search", "fetch_json", "read_url", "osint_scan", "deep_crawl", "observe", "recall", "share", "recall_hive", "probe", "note_stance", "save_skill", "set_directive", "send_message", "add_task", "complete_task", "stage_delivery", "make_tool", "propose_change", "simulate_change" };
    for (builtins) |b| if (std.mem.eql(u8, b, n)) return true;
    return false;
}

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
    const redirected = ctx.one_slot and ctx.slot_path.len > 0 and !std.mem.eql(u8, p.value.path, ctx.slot_path);
    const wpath = if (redirected) ctx.slot_path else p.value.path;
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

fn readFile(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { path: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!safeRel(p.value.path)) return dupe(gpa, "bad path");
    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.workdir, p.value.path }) catch return dupe(gpa, "oom");
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

// ---- OPERATE a live host: read its telemetry and issue remediation commands over a file bus ----

fn hostStatus(ctx: *ToolCtx, args_json: []const u8) []u8 {
    _ = args_json;
    const gpa = ctx.gpa;
    const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{ctx.workdir}) catch return dupe(gpa, "oom");
    defer gpa.free(tp);
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, tp, gpa, .limited(8192)) catch
        dupe(gpa, "no telemetry.json on the bus - no machine is attached to this run");
}

/// IPv4 address with the :port stripped (everything before the first ':'), so "185.143.220.7:3333" and
/// "185.143.220.7" compare equal.
fn bareIp(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, ':')) |i| s[0..i] else s;
}

/// TARGET GUARD: a verb that names a specific threat (block_ip / kill_proc / remove_persistence) must point at a
/// target that EXISTS in the host's live telemetry. A target is valid if it is a REAL connection/process - NOT only
/// a host-FLAGGED one (requiring the flag would defeat DETECTION, where the agent identifies a stealth implant by
/// cross-referencing threat-intel). The guard still rejects HALLUCINATED targets that appear nowhere in telemetry,
/// listing the real ones to steer the model. Fail-open if no machine is attached. Returns an owned rejection or null.
fn targetGuard(ctx: *ToolCtx, verb: []const u8, target: []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    const is_ip = std.mem.eql(u8, verb, "block_ip");
    const is_proc = std.mem.eql(u8, verb, "kill_proc");
    const is_pers = std.mem.eql(u8, verb, "remove_persistence");
    if (!is_ip and !is_proc and !is_pers) return null; // host-wide verbs (isolate/scan/...) need no target
    const tp = std.fmt.allocPrint(gpa, "{s}/telemetry.json", .{ctx.workdir}) catch return null;
    defer gpa.free(tp);
    const tel = std.Io.Dir.cwd().readFileAlloc(ctx.io, tp, gpa, .limited(16384)) catch return null; // no machine -> allow
    defer gpa.free(tel);
    const Proc = struct { name: []const u8 = "", pid: i64 = 0, suspicious: bool = false };
    const Conn = struct { ip: []const u8 = "", c2: bool = false };
    const Pers = struct { name: []const u8 = "" };
    const Tel = struct { processes: []const Proc = &.{}, connections: []const Conn = &.{}, persistence: []const Pers = &.{} };
    const parsed = std.json.parseFromSlice(Tel, gpa, tel, .{ .ignore_unknown_fields = true }) catch return null; // unparseable -> allow
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
    } else { // remove_persistence
        for (t.persistence) |x| {
            add(gpa, &list, x.name);
            if (std.mem.eql(u8, x.name, target)) known = true;
        }
    }
    if (known) return null;
    return std.fmt.allocPrint(gpa, "rejected: '{s} {s}' - '{s}' appears NOWHERE in this host's live telemetry (a hallucinated target). Real {s} targets on the host right now: [{s}]. Reissue host_command against one that actually exists.", .{ verb, target, target, verb, list.items }) catch dupe(gpa, "rejected: target appears nowhere in telemetry");
}

fn hostCommand(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { command: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const cmd = std.mem.trim(u8, p.value.command, " \r\n\t");
    if (cmd.len == 0) return dupe(gpa, "no command given");
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    const verb = it.next() orelse "";
    // allowlist the verb - the agent OPERATES the host, it cannot inject an arbitrary line (defensive remediation only)
    const allowed = [_][]const u8{ "kill_proc", "block_ip", "remove_persistence", "restore_file", "isolate", "quarantine", "unisolate", "resume", "scan", "status", "safe_mode", "heater", "drive", "task_restart", "mutex_inherit" };
    var ok = false;
    for (allowed) |a| {
        if (std.mem.eql(u8, verb, a)) {
            ok = true;
            break;
        }
    }
    if (!ok) return std.fmt.allocPrint(gpa, "rejected: '{s}' is not an allowed host command", .{verb}) catch dupe(gpa, "rejected");
    // the target must be a real indicator in live telemetry (blocks hallucinated targets; steers the model right)
    const target = std.mem.trim(u8, cmd[@min(verb.len + 1, cmd.len)..], " \t");
    if (targetGuard(ctx, verb, target)) |rej| return rej;
    const cp = std.fmt.allocPrint(gpa, "{s}/commands.jsonl", .{ctx.workdir}) catch return dupe(gpa, "oom");
    defer gpa.free(cp);
    const prior = std.Io.Dir.cwd().readFileAlloc(ctx.io, cp, gpa, .limited(256 << 10)) catch &[_]u8{};
    defer if (prior.len > 0) gpa.free(prior);
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(gpa);
    joined.appendSlice(gpa, prior) catch {};
    if (prior.len > 0 and prior[prior.len - 1] != '\n') joined.appendSlice(gpa, "\n") catch {};
    joined.appendSlice(gpa, cmd) catch {};
    joined.appendSlice(gpa, "\n") catch {};
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = cp, .data = joined.items }) catch return dupe(gpa, "could not write to the command bus");
    return std.fmt.allocPrint(gpa, "issued to host: {s}", .{cmd}) catch dupe(gpa, "issued");
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

fn webFetch(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { url: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!urlAllowed(p.value.url)) return dupe(gpa, "blocked url (only public http/https; no local/internal hosts)");
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
    const raw = curlToText(ctx, p.value.url, true, 26000, 512 << 10);
    defer gpa.free(raw);
    if (raw.len == 0) return dupe(gpa, "(fetch returned nothing or timed out — try another source)");
    return dupe(gpa, clip(raw, 2200));
}

fn readUrl(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { url: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (!urlAllowed(p.value.url)) return dupe(gpa, "blocked url (only public http/https; no local/internal hosts)");
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

fn webSearch(ctx: *ToolCtx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { query: []const u8 = "", source: []const u8 = "web", limit: u32 = 5 };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    if (std.mem.trim(u8, p.value.query, " \r\n\t").len == 0) return dupe(gpa, "empty query");
    const lim = if (p.value.limit == 0 or p.value.limit > 10) 5 else p.value.limit;
    var lbuf: [8]u8 = undefined;
    const ls = std.fmt.bufPrint(&lbuf, "{d}", .{lim}) catch "5";

    var env = ctx.environ.clone(gpa) catch return dupe(gpa, "oom");
    defer env.deinit();
    inline for (.{ "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "NL_BROKER_AUTH" }) |k| env.put(k, "") catch {};

    const py = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ py, "-c", SEARCH_PY, p.value.source, p.value.query, ls };
    const r = std.process.run(gpa, ctx.io, .{ .argv = &argv, .environ_map = &env, .stdout_limit = .limited(256 << 10), .stderr_limit = .limited(8 << 10) }) catch return dupe(gpa, "search failed to run");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (std.mem.trim(u8, r.stdout, " \r\n\t").len == 0)
        return std.fmt.allocPrint(gpa, "(no results: {s})", .{clip(std.mem.trim(u8, r.stderr, " \r\n\t"), 200)}) catch dupe(gpa, "(no results)");
    return dupe(gpa, clip(r.stdout, 4000));
}

const SEARCH_PY =
    \\import sys,json,re,html,os,urllib.parse,urllib.request
    \\src,q,lim=(sys.argv[1] or "web"),sys.argv[2],int(sys.argv[3])
    \\def g(u,t=20,ua="neuron-loops-mind/1.0"):
    \\    rq=urllib.request.Request(u,headers={"User-Agent":ua,"Accept":"*/*"})
    \\    return urllib.request.urlopen(rq,timeout=t).read().decode("utf-8","replace")
    \\o=[]
    \\try:
    \\ if src=="wikipedia":
    \\    d=json.loads(g("https://en.wikipedia.org/w/api.php?action=opensearch&format=json&limit=%d&search=%s"%(lim,urllib.parse.quote(q))))
    \\    for t,ds,l in zip(d[1],d[2],d[3]): o.append({"title":t,"url":l,"snippet":ds})
    \\ elif src in ("hackernews","hn"):
    \\    d=json.loads(g("https://hn.algolia.com/api/v1/search?query=%s"%urllib.parse.quote(q)))
    \\    for h in d.get("hits",[])[:lim]: o.append({"title":h.get("title") or h.get("story_title") or "","url":h.get("url") or ("https://news.ycombinator.com/item?id=%s"%h.get("objectID")),"snippet":(h.get("story_text") or "")[:160]})
    \\ elif src=="arxiv":
    \\    x=g("http://export.arxiv.org/api/query?search_query=all:%s&max_results=%d"%(urllib.parse.quote(q),lim))
    \\    for m in re.findall(r"<entry>(.*?)</entry>",x,re.S)[:lim]:
    \\        t=re.search(r"<title>(.*?)</title>",m,re.S); l=re.search(r"<id>(.*?)</id>",m,re.S); s=re.search(r"<summary>(.*?)</summary>",m,re.S)
    \\        o.append({"title":(t.group(1).strip() if t else ""),"url":(l.group(1).strip() if l else ""),"snippet":(re.sub(r"\s+"," ",s.group(1)).strip()[:200] if s else "")})
    \\ else:
    \\    sx=os.environ.get("NL_SEARXNG_URL","").rstrip("/")
    \\    if sx:
    \\        try:
    \\            d=json.loads(g(sx+"/search?format=json&q=%s"%urllib.parse.quote(q)))
    \\            for r in d.get("results",[])[:lim]: o.append({"title":r.get("title",""),"url":r.get("url",""),"snippet":(r.get("content") or "")[:160]})
    \\        except Exception as e: sys.stderr.write("searxng:"+str(e))
    \\    if not o:
    \\        try:
    \\            hd={"Content-Type":"application/json","User-Agent":"neuron-loops-mind/1.0"}
    \\            fk=os.environ.get("NL_FIRECRAWL_KEY","")
    \\            if fk: hd["Authorization"]="Bearer "+fk
    \\            rq=urllib.request.Request("https://api.firecrawl.dev/v2/search",data=json.dumps({"query":q,"limit":lim}).encode(),headers=hd)
    \\            d=json.loads(urllib.request.urlopen(rq,timeout=20).read().decode("utf-8","replace"))
    \\            web=(d.get("data") or {}).get("web") if isinstance(d.get("data"),dict) else d.get("data")
    \\            for r in (web or [])[:lim]: o.append({"title":r.get("title",""),"url":r.get("url",""),"snippet":(r.get("description") or "")[:160]})
    \\        except Exception as e: sys.stderr.write("firecrawl:"+str(e))
    \\    if not o:
    \\        try:
    \\            h=g("https://r.jina.ai/https://duckduckgo.com/html/?q=%s"%urllib.parse.quote(q),t=25,ua="Mozilla/5.0")
    \\            for title,link in re.findall(r'##\s*\[(.*?)\]\((https://duckduckgo\.com/l/\?uddg=[^)]+)\)',h,re.S):
    \\                real=urllib.parse.parse_qs(urllib.parse.urlparse(link.replace("&amp;","&")).query).get("uddg",[""])[0]
    \\                t2=re.sub(r"\s+"," ",re.sub("<[^>]+>","",title)).strip()
    \\                if t2 and real: o.append({"title":html.unescape(t2),"url":real,"snippet":""})
    \\                if len(o)>=lim: break
    \\        except Exception as e: sys.stderr.write("jina:"+str(e))
    \\    if not o:
    \\        d=json.loads(g("https://en.wikipedia.org/w/api.php?action=opensearch&format=json&limit=%d&search=%s"%(lim,urllib.parse.quote(q))))
    \\        for t,ds,l in zip(d[1],d[2],d[3]): o.append({"title":t,"url":l,"snippet":ds})
    \\except Exception as e:
    \\    sys.stderr.write(str(e))
    \\print("\n".join("- %s\n  %s\n  %s"%(r["title"],r["url"],r.get("snippet","")) for r in o[:lim]))
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
    \\        pct=min(99,int(sc*100/len(docs))) if docs else 0
    \\        out({"status":"ok","passed":pct,"total":100,"failures":[],"tier":3})
    \\    out({"status":"no-tests"})
    \\except Exception as e:
    \\    out({"status":"error","msg":str(e)[:120]})
;

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
    \\    if not cands: out({"status":"no-server"})
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
fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}
fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast("error");
}
