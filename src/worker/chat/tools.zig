//! Shared tool endpoint — ONE HTTP surface that both the desktop chat and any external client
//! call to run a SINGLE tool exactly the way a hive mind would. Mind tools (web_search, web_fetch,
//! recall_hive, observe, …) dispatch straight to the worker's `tools.execute()` through a minimal
//! ToolCtx; orchestration verbs (list_swarms / stop_swarm / kill_swarm / swarm_status / swarm_findings)
//! wrap the supervisor + run-dir so a chat can drive its own swarms. Hive and chat share this ONE
//! registry — as the tool set grows, both surfaces grow with it.
//!
//!   POST /api/v1/chat/tool
//!     { "tool":"web_search",     "args":"{\"query\":\"...\"}" }   // args = JSON string, tool-call style
//!     { "tool":"stop_swarm",     "id":"<swarm-id>" }              // cooperative (next turn boundary)
//!     { "tool":"kill_swarm",     "id":"<swarm-id>" }              // hard-kill; run dir kept
//!     { "tool":"swarm_status",   "id":"<swarm-id>" }              // state/pid/round/phase/budget
//!     { "tool":"swarm_findings", "id":"<swarm-id>" }
//!   (swarm ids resolve as EITHER the registry key or the run-dir basename)
//!   -> { "ok":true, "tool":"...", "result":"..." }               // mind tool
//!   -> { "ok":true, "tool":"list_swarms", "swarms":[ … ] }       // orchestration

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../../gateway/http.zig");
const tools = @import("../tools.zig");
const osc = @import("../oscillation.zig");
const sup_mod = @import("../control/supervisor.zig"); // readTail (bounded event-log reads for swarm_status)
const cpaths = @import("paths.zig"); // conv → build-tree mapping (scheduled runs live under _sched/{task}/runs/)

const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const notFound = http.notFound;
const serverErr = http.serverErr;
const unauth = http.unauth;

// Serializes edit_file's swarm micro-VCS commits (vcs.zig) across concurrent /api/v1/chat/tool requests IN
// THIS gateway process. A live hive cast building in the SAME conversation dir runs as a SEPARATE worker
// process with its OWN such mutex (see run.zig's files_mtx) — the two lock domains can't rendezvous across a
// process boundary, so a genuinely-simultaneous chat-edit and hive-edit to the same file has a narrow
// (microseconds) race window between commitEdit's HEAD-read and its atomic write. Both sides still rebase
// their ops onto whatever HEAD they read and land it via a same-dir atomic rename — edits route through the
// SAME version-control mechanic the swarm's own minds use.
var chat_vcs_mtx: std.Io.Mutex = .init;

const ToolReq = struct {
    tool: []const u8 = "",
    args: []const u8 = "{}", // JSON *string* (tool-call convention), passed verbatim to tools.execute
    id: []const u8 = "", // convenience for orchestration verbs (also parsed out of args)
    dir: []const u8 = "", // conversation id → a per-conversation build workdir (sanitized server-side)
};

// FULL TOOL CONVERGENCE — the chat AI gets the SAME tool surface a hive mind has. The tools
// route to the identical tools.execute() the swarm uses; they split by RISK, not by capability:
//
// SAFE_TOOLS run for ANY authed user — research + memory + persona + coordination + files. The file tools are
// confined by tools.safeRel to the per-conversation workdir; the rest write only into the chat's own run_dir /
// memory DB, or degrade gracefully with no swarm context (probe → "no spatial grid", send_message → a note).
const SAFE_TOOLS = [_][]const u8{
    "web_search",   "web_fetch",   "fetch_json",    "read_url",  "deep_crawl",
    "recall_hive",  "recall",      "observe",       "share",     "note_stance",
    "save_skill",   "journal",     "set_directive", "add_task",  "complete_task",
    "send_message", "probe",       "write_file",    "edit_file", "read_file",
    "list_dir",     "delete_file",
};

// ADMIN_TOOLS are the powerful ones — arbitrary code exec, HOST control, engine self-modification, tool
// authoring, egress, aggressive recon. Casts run these but pass deployCore's entitlement gates; this endpoint
// has none and serves "any external client", so gate them to ADMINS. The desktop is admin on localhost, so it
// gets the FULL hive-mind surface; a hosted non-admin tenant gets the safe subset.
const ADMIN_TOOLS = [_][]const u8{
    "run_python",      "run_tests",        "patch_system", "make_tool",     "propose_change",
    "simulate_change", "stage_delivery",   "osint_scan",   "host_status",   "host_command",
    "host_explore",    "browser_navigate", "browser_read", "browser_click", "browser_type",
    "browser_eval",    "browser_close",    "pixel_ingest", "pixel_capture", "pixel_search",
    "mcp_discover",    "mcp_call",
};

fn toolSafe(name: []const u8) bool {
    for (SAFE_TOOLS) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

fn toolAdminOnly(name: []const u8) bool {
    for (ADMIN_TOOLS) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

/// Sanitize a conversation id into a single safe path segment for the build workdir (no separators, no "..",
/// bounded length). Empty / unsafe → "" so the caller falls back to the shared workdir.
fn safeSeg(id: []const u8) []const u8 {
    const t = std.mem.trim(u8, id, " \r\n\t");
    if (t.len == 0 or t.len > 64) return "";
    for (t) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return "";
    }
    return t;
}

/// The swarm id the caller means: explicit top-level `id`, else the "id" field parsed out of `args`.
fn argId(body: ToolReq) []const u8 {
    const t = std.mem.trim(u8, body.id, " \r\n\t");
    if (t.len > 0) return t;
    return jsonField(body.args, "id");
}

pub fn chatTool(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    // a malformed body must come back as a readable 400 the calling model can react to — propagating the
    // parse error would turn one bad byte into an opaque 500
    const body = (req.json(ToolReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    const tool = std.mem.trim(u8, body.tool, " \r\n\t");
    if (tool.len == 0) return badReq(res, "missing tool");

    // --- orchestration tools (wrap the supervisor + run dir) -------------------------------
    if (std.mem.eql(u8, tool, "list_swarms")) return listSwarms(app, u.id, res);
    if (std.mem.eql(u8, tool, "stop_swarm")) return stopSwarm(app, u.id, argId(body), res);
    if (std.mem.eql(u8, tool, "kill_swarm")) return killSwarm(app, u.id, argId(body), res);
    if (std.mem.eql(u8, tool, "swarm_status")) return swarmStatus(app, u.id, argId(body), res);
    if (std.mem.eql(u8, tool, "swarm_findings")) return findings(app, u.id, argId(body), res);

    // --- the full hive-mind tool surface (the same executor the hive uses) -----------------
    // SAFE tools run for any authed user; ADMIN tools (code-exec, host control, engine self-mod, egress) are
    // admin-only — the desktop is admin on localhost, so it gets the complete swarm surface.
    const safe = toolSafe(tool);
    const admin_only = toolAdminOnly(tool);
    if (!safe and !admin_only) return badReq(res, "unknown or disallowed tool");
    const is_admin = app.auth.isAdmin(u);
    if (admin_only and !is_admin) {
        res.status = 403;
        try res.json(.{ .ok = false, .err = "this tool is admin-only on the chat surface (code-exec / host / engine / egress)" }, .{});
        return;
    }
    // The desktop is admin on localhost — this endpoint runs the tool on the USER'S OWN machine, so an admin
    // caller gets the roam privilege (the same one `veil exec-tool` grants): absolute-path reads and, crucially,
    // the browser/pixel/mcp tools authorize on roam instead of a server env flag. This is the local-chat path.
    return runMindTool(app, u.id, tool, body.args, safeSeg(body.dir), is_admin, res);
}

// ----- orchestration -------------------------------------------------------------------------

fn listSwarms(app: *App, uid: u64, res: *httpz.Response) !void {
    const swarms = try app.sup.listForUser(uid);
    defer app.gpa.free(swarms);
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"ok\":true,\"tool\":\"list_swarms\",\"swarms\":[");
    for (swarms, 0..) |s, i| {
        if (i > 0) try arr.append(app.gpa, ',');
        // name/model are user/config-influenced — escape them, or a quote/backslash breaks the response.
        try arr.appendSlice(app.gpa, "{\"id\":\"");
        try appendEsc(app.gpa, &arr, s.id);
        try arr.appendSlice(app.gpa, "\",\"name\":\"");
        try appendEsc(app.gpa, &arr, s.name);
        try arr.appendSlice(app.gpa, "\",\"model\":\"");
        try appendEsc(app.gpa, &arr, s.model);
        const tail = try std.fmt.allocPrint(res.arena, "\",\"minds\":{d},\"state\":\"{s}\"}}", .{ s.minds, @tagName(s.state) });
        try arr.appendSlice(app.gpa, tail);
    }
    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

fn stopSwarm(app: *App, uid: u64, id: []const u8, res: *httpz.Response) !void {
    if (id.len == 0) return badReq(res, "stop_swarm needs an id");
    const sw = app.sup.resolve(id) orelse return notFound(res);
    if (sw.uid != uid) return unauth(res);
    app.sup.stop(sw.id);
    // Honest response: the STOP file is COOPERATIVE — the worker acts on it at its next turn/round
    // boundary, so the state is "stopping" until the supervisor confirms the process is gone.
    try res.json(.{ .ok = true, .tool = "stop_swarm", .requested = true, .id = id, .state = "stopping", .note = "stop requested (cooperative; takes effect at the next turn boundary) — check swarm_status to confirm, or kill_swarm to force" }, .{});
}

fn killSwarm(app: *App, uid: u64, id: []const u8, res: *httpz.Response) !void {
    if (id.len == 0) return badReq(res, "kill_swarm needs an id");
    const sw = app.sup.resolve(id) orelse return notFound(res);
    if (sw.uid != uid) return unauth(res);
    _ = app.sup.kill(sw.id);
    try res.json(.{ .ok = true, .tool = "kill_swarm", .requested = true, .id = id, .state = "stopping", .note = "hard-kill requested (STOP written + worker process terminated); the run dir and its findings are kept — the supervisor confirms the death shortly" }, .{});
}

/// swarm_status — everything a chat model needs to answer "why is it still running": supervisor state,
/// the live-pid verdict, round/phase/pct parsed from a BOUNDED tail of events.jsonl (last 64KB — never a
/// whole multi-MB log), elapsed seconds vs the manifest's minutes budget, and the last lifecycle event.
fn swarmStatus(app: *App, uid: u64, id: []const u8, res: *httpz.Response) !void {
    if (id.len == 0) return badReq(res, "swarm_status needs an id");
    const sw = app.sup.resolve(id) orelse return notFound(res);
    if (sw.uid != uid) return unauth(res);
    const pid_st = app.sup.pidStatus(sw.run_dir);

    // minutes budget straight from the manifest; elapsed from the supervisor's created stamp (spawn time
    // for a live cast; adoption time for a re-adopted dir — approximate there, exact where it matters)
    var minutes: u32 = 0;
    {
        const mp = try std.fmt.allocPrint(res.arena, "{s}/swarm.json", .{sw.run_dir});
        if (std.Io.Dir.cwd().readFileAlloc(app.io, mp, res.arena, .limited(256 << 10))) |mtxt| {
            const M = struct { minutes: u32 = 0 };
            if (std.json.parseFromSliceLeaky(M, res.arena, mtxt, .{ .ignore_unknown_fields = true })) |mv| minutes = mv.minutes else |_| {}
        } else |_| {}
    }
    const now = std.Io.Timestamp.now(app.io, .real).toSeconds();
    const elapsed: i64 = @max(0, now - sw.created);

    // bounded tail of the event log — round / phase / pct + the last lifecycle event (goal/complete/stopped)
    var round: i64 = 0;
    var phase: []const u8 = "";
    var pct_now: i64 = -1;
    var pct_best: i64 = -1;
    var last_kind: []const u8 = "";
    var last_text: []const u8 = "";
    {
        const ev_path = try std.fmt.allocPrint(res.arena, "{s}/events.jsonl", .{sw.run_dir});
        const tail_buf = try res.arena.alloc(u8, 64 << 10);
        var tail: []const u8 = sup_mod.readTail(app.io, ev_path, tail_buf) orelse "";
        if (tail.len == tail_buf.len) {
            // clipped mid-line: drop the partial first line so field parses never read torn JSON
            if (std.mem.indexOfScalar(u8, tail, '\n')) |nl| tail = tail[nl + 1 ..];
        }
        var it = std.mem.splitScalar(u8, tail, '\n');
        while (it.next()) |raw| {
            const ln = std.mem.trim(u8, raw, " \r\t");
            if (ln.len < 8) continue;
            const kind = jsonField(ln, "kind");
            if (kind.len == 0) continue;
            if (jsonNumField(ln, "round")) |r| {
                if (r > round) round = r;
            }
            if (std.mem.eql(u8, kind, "phase")) {
                phase = jsonField(ln, "phase");
                if (jsonNumField(ln, "now")) |v| pct_now = v;
                if (jsonNumField(ln, "best")) |v| pct_best = v;
            } else if (std.mem.eql(u8, kind, "started") or std.mem.eql(u8, kind, "goal") or std.mem.eql(u8, kind, "resumed")) {
                last_kind = kind;
                last_text = jsonField(ln, "goal");
            } else if (std.mem.eql(u8, kind, "complete") or std.mem.eql(u8, kind, "stopped")) {
                last_kind = kind;
                last_text = jsonField(ln, "reason");
            }
        }
    }
    const lt = try res.arena.dupe(u8, clip(last_text, 300));
    scrubUtf8(lt); // event text may clip mid-multibyte; res.json requires valid UTF-8

    try res.json(.{
        .ok = true,
        .tool = "swarm_status",
        .id = id,
        .state = @tagName(sw.state),
        .pid = pid_st.pid,
        .pid_alive = pid_st.alive,
        .round = round,
        .phase = phase,
        .pct_now = pct_now,
        .pct_best = pct_best,
        .elapsed_s = elapsed,
        .budget_minutes = minutes,
        .over_budget = minutes > 0 and elapsed > @as(i64, minutes) * 60,
        .last_event = last_kind,
        .last_event_text = lt,
    }, .{});
}

fn findings(app: *App, uid: u64, id: []const u8, res: *httpz.Response) !void {
    if (id.len == 0) return badReq(res, "swarm_findings needs an id");
    const sw = app.sup.resolve(id) orelse return notFound(res);
    if (sw.uid != uid) return unauth(res);
    // Prefer the lead synthesis; fall back to the tail of the raw event log.
    const syn_path = try std.fmt.allocPrint(res.arena, "{s}/work/synthesis.md", .{sw.run_dir});
    var text: []const u8 = "";
    if (std.Io.Dir.cwd().readFileAlloc(app.io, syn_path, res.arena, .limited(256 << 10))) |c| {
        scrubUtf8(c); // file content may not be valid UTF-8; res.json requires it
        text = c;
    } else |_| {
        const ev_path = try std.fmt.allocPrint(res.arena, "{s}/events.jsonl", .{sw.run_dir}); // events.jsonl lives at the run_dir ROOT (synthesis.md is under work/)
        if (std.Io.Dir.cwd().readFileAlloc(app.io, ev_path, res.arena, .limited(512 << 10))) |c| {
            scrubUtf8(c);
            // No synthesis yet (a still-running cast): distill the readable research narrative from the events
            // — the goal + each mind's per-round monologue — instead of dumping raw telemetry JSON at the model.
            const digest = digestEvents(res.arena, c);
            text = if (digest.len > 0) digest else tailLines(c, 6000);
        } else |_| {
            text = "(no findings yet — the swarm has not written a synthesis or events)";
        }
    }
    try res.json(.{ .ok = true, .tool = "swarm_findings", .id = id, .state = @tagName(sw.state), .findings = text }, .{});
}

// ----- mind tools ----------------------------------------------------------------------------

fn runMindTool(app: *App, uid: u64, tool: []const u8, args: []const u8, conv: []const u8, roam: bool, res: *httpz.Response) !void {
    const environ = app.sup.parent_env orelse return serverErr(res, "server env unavailable");
    // Per-user scratch + memory DB so observe/share/recall_hive on the chat surface never cross accounts
    // (the endpoint is multi-tenant on the productized server). Isolation is by the per-uid DB FILE — NOT by
    // scope: recall_hive reads the fixed KNOWLEDGE/INTEL/SKILL scopes, so overriding learn_scope would just
    // make observe write somewhere recall_hive never looks (a stored-and-forgotten fact). Keep both default.
    const base = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat", .{ app.data, uid });
    // A per-conversation build workdir keeps each chat's files apart (and matches the dir the desktop cd's its
    // console into); no/blank conv id falls back to the shared _chat/work. `conv` is already safeSeg'd.
    // `run_root` is deliberately the SAME dir a cast for this conversation spawns with as its run_dir
    // (`.../builds/{conv}`, worker builds in `{run_dir}/work`) — so the chat's OWN build tools and a hive cast
    // co-edit ONE tree, and vcs.zig's `.vcs` history for that tree lives in the SAME place the worker process
    // would put it.
    // (A SCHEDULED run's conv redirects into its task's permanent _sched/{task}/runs/{stamp} tree — paths.zig.)
    var rrb: [700]u8 = undefined;
    const run_root = if (conv.len > 0)
        try res.arena.dupe(u8, cpaths.buildRootFromChatBase(&rrb, base, conv))
    else
        base;
    if (conv.len > 0 and run_root.len == 0) return serverErr(res, "could not resolve the build workdir");
    const workdir = try std.fmt.allocPrint(res.arena, "{s}/work", .{run_root});
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, workdir, .default_dir) catch {};
    // data-relative form the desktop can cd its console into (shared filesystem, same machine)
    var wrb: [256]u8 = undefined;
    const workdir_rel = if (conv.len > 0)
        try std.fmt.allocPrint(res.arena, "{s}/work", .{cpaths.buildRootRel(&wrb, uid, conv)})
    else
        try std.fmt.allocPrint(res.arena, "u{d}/_chat/work", .{uid});
    const db = try std.fmt.allocPrint(res.arena, "{s}/hive.sqlite", .{base});

    // Per-CONVERSATION memory scope, matching the server drive loop's ToolCtx byte-for-byte: the engine's
    // turn-start recall and tool-finding observes use "chat:{conv}", so the model-facing recall/observe
    // tools must read/write the SAME partition — with the old shared "chat" scope the two memory loops
    // never met (the model could not recall what the engine observed for this conversation, and vice
    // versa). recall_hive still reads the fixed KNOWLEDGE/INTEL/SKILL scopes; a blank conv keeps "chat".
    const mem_scope = if (conv.len > 0)
        try std.fmt.allocPrint(res.arena, "chat:{s}", .{conv})
    else
        "chat";

    // The executor increments these; the chat surface ignores them (one shared sink is fine).
    var counters = [_]u32{0} ** 5;
    var ctx = tools.ToolCtx{
        .gpa = app.gpa,
        .io = app.io,
        .environ = environ,
        .run_dir = run_root,
        .workdir = workdir,
        .scope = mem_scope,
        .mind = "chat",
        .round = 0,
        // Same cross-conversation guard as the server drive loop's ctx: this db is the per-user chat hive,
        // so a delegated observe must not globalize conversation-local project state either.
        .hive_guard = true,
        // Same durable store as the engine ctx — a desk-delegated get_credential resolves identically.
        .durable_path = std.fmt.allocPrint(res.arena, "{s}/.veil-desk/memories.jsonl", .{app.data}) catch "",
        .mem = blk_mem: {
            var m = osc.Mem.init(app.gpa, app.io, app.sup.neuron_bin, db);
            m.trust = true; // trust-weighted assoc ranking, matching the server drive loop's Mem
            break :blk_mem m;
        },
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        .fmtx = &chat_vcs_mtx,
        .vcs_enabled = conv.len > 0, // route edit_file through the swarm's micro-VCS on a real per-conversation build
        .roam = roam, // admin-on-localhost: this runs on the user's own machine (browser/pixel/mcp authorize on roam)
    };
    const result = tools.execute(&ctx, tool, args);
    // A tool result can carry arbitrary bytes (web_fetch/read_url page text) — httpz res.json requires valid
    // UTF-8, so scrub invalid sequences to U+FFFD-as-'?' in place before serializing. Guard the free: an OOM
    // dupe() fallback in execute() can hand back a static "" (len 0) that must NOT be freed.
    scrubUtf8(result);
    defer if (result.len > 0) app.gpa.free(result);
    // workdir_rel lets the desktop cd its micro-console into the SAME folder the build tools write to, so the
    // user + the AI share one working directory.
    try res.json(.{ .ok = true, .tool = tool, .result = result, .workdir = workdir_rel }, .{});
}

/// Distill a still-running cast's events.jsonl into the readable research narrative a chat can summarize: the
/// goal + each mind's per-round monologue (its own account of what it found), skipping pure telemetry (growth,
/// cost, capacity, the giant tick trace/stored arrays). Returns "" if nothing useful was found (caller falls
/// back to the raw tail). Output is UTF-8-scrubbed so it is always safe for res.json.
fn digestEvents(arena: std.mem.Allocator, raw: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len < 8) continue;
        const kind = jsonField(line, "kind");
        if (std.mem.eql(u8, kind, "started")) {
            if (jsonStrArena(arena, line, "goal")) |g| {
                out.appendSlice(arena, "Goal: ") catch {};
                out.appendSlice(arena, clip(g, 400)) catch {};
                out.append(arena, '\n') catch {};
            }
        } else if (std.mem.eql(u8, kind, "tick")) {
            const mono = jsonStrArena(arena, line, "monologue") orelse continue;
            const t = std.mem.trim(u8, mono, " \r\n\t");
            if (t.len < 8) continue;
            out.appendSlice(arena, "\n• ") catch {};
            out.appendSlice(arena, jsonField(line, "mind")) catch {};
            out.appendSlice(arena, ": ") catch {};
            out.appendSlice(arena, clip(t, 700)) catch {};
            out.append(arena, '\n') catch {};
        }
        if (out.items.len > 8000) break; // enough for the model to summarize
    }
    scrubUtf8(out.items); // clips above may split a multibyte char
    return out.items;
}

fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

/// Extract a JSON string value for `key`, UNESCAPING into a fresh arena allocation (\n \t \r \" \\ \/ and, best-
/// effort, \uXXXX -> space). Unbounded + escape-aware, unlike jsonField. Returns null if the key is absent.
fn jsonStrArena(arena: std.mem.Allocator, s: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [48]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, s, needle) orelse return null;
    var i = at + needle.len;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i >= s.len or s[i] != '"') return null;
    i += 1;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    while (i < s.len) {
        const c = s[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < s.len) {
            const e = s[i + 1];
            i += 2;
            out.append(arena, switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 8,
                'f' => 12,
                'u' => blk: {
                    if (i + 4 <= s.len) i += 4;
                    break :blk ' ';
                },
                else => e,
            }) catch return out.items;
            continue;
        }
        out.append(arena, c) catch return out.items;
        i += 1;
    }
    return out.items;
}

/// Replace each byte that is not part of a valid UTF-8 sequence with '?' (in place, length-preserving), so
/// arbitrary tool output always serializes as conformant JSON.
fn scrubUtf8(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const n = std.unicode.utf8ByteSequenceLength(buf[i]) catch {
            buf[i] = '?';
            i += 1;
            continue;
        };
        if (i + n > buf.len) {
            buf[i] = '?';
            i += 1;
            continue;
        }
        if (std.unicode.utf8Decode(buf[i .. i + n])) |_| {
            i += n;
        } else |_| {
            buf[i] = '?';
            i += 1;
        }
    }
}

// ----- tiny helpers --------------------------------------------------------------------------

/// Append `s` as the inside of a JSON string (no surrounding quotes), escaping ", \, and control chars.
fn appendEsc(gpa: std.mem.Allocator, arr: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try arr.appendSlice(gpa, "\\\""),
        '\\' => try arr.appendSlice(gpa, "\\\\"),
        '\n' => try arr.appendSlice(gpa, "\\n"),
        '\r' => try arr.appendSlice(gpa, "\\r"),
        '\t' => try arr.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [8]u8 = undefined;
            try arr.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch continue);
        } else try arr.append(gpa, c),
    };
}

/// String value of a top-level "key" in a flat JSON object — enough to pull an id out of a tool-call
/// args blob without a full parse. Returns "" if absent.
fn jsonField(s: []const u8, key: []const u8) []const u8 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return "";
    const kidx = std.mem.indexOf(u8, s, pat) orelse return "";
    var i = kidx + pat.len;
    while (i < s.len and (s[i] == ' ' or s[i] == ':' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len or s[i] != '"') return "";
    i += 1;
    const start = i;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    return s[start..i];
}

/// Integer value of a top-level "key" in a flat JSON object (e.g. `"round":12`). Returns null if absent
/// or not a plain integer. Companion to jsonField for the numeric event fields swarm_status reads.
fn jsonNumField(s: []const u8, key: []const u8) ?i64 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
    const kidx = std.mem.indexOf(u8, s, pat) orelse return null;
    var i = kidx + pat.len;
    while (i < s.len and (s[i] == ' ' or s[i] == ':' or s[i] == '\t')) : (i += 1) {}
    const start = i;
    if (i < s.len and s[i] == '-') i += 1;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(i64, s[start..i], 10) catch null;
}

/// Last `max` bytes of `s`, snapped forward to the next line boundary so we never emit a half line.
fn tailLines(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var start = s.len - max;
    while (start < s.len and s[start] != '\n') : (start += 1) {}
    if (start < s.len) start += 1;
    return s[start..];
}
