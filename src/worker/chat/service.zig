//! Read-only conversation routes — the server-side twin of the swarm run-dir HTTP surface, but for the
//! veil-desk chat brain's per-conversation store. A conversation `{conv}` lives at
//!
//!     {data}/u{uid}/_chat/convs/{safeSeg(conv)}/
//!         messages.jsonl   // one JSON object per line: {role,content,kind,ts}
//!         events.jsonl     // SSE frames, the SAME per-line JSON shape swarm events.jsonl uses
//!
//! The read routes only READ (and DELETE) that tree — no turn loop, no LLM, no live SSE stream. Every read path
//! degrades gracefully when the store is empty: a missing convs root → empty list, a missing conv dir → 404, a
//! missing messages.jsonl/events.jsonl → empty body. Ownership is STRUCTURAL: every path is built
//! from the authenticated user's own uid (`u{uid}`), so a caller can only ever reach its own conversations —
//! the per-uid prefix IS the `owner.uid != u.id` check the swarm routes make against the registry.
//!
//!   GET    /api/v1/chat/convs            -> {ok:true, convs:[{id,title,updated,msgs}]}
//!   GET    /api/v1/chat/convs/:id        -> {ok:true, id, messages:[{role,content,kind,ts}]}   (404 if absent)
//!   DELETE /api/v1/chat/convs/:id        -> {ok:true}                                          (404 if absent)
//!   GET    /api/v1/chat/convs/:id/events?from=N -> events.jsonl cursor poll (X-Next-Offset out) — swarmEvents twin

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../../gateway/http.zig");
const cf_oauth = @import("../../config/cf_oauth.zig");
const chat_engine = @import("engine.zig");
const llm = @import("../llm.zig");
const modelcfg = @import("modelcfg");

/// The reserved uid for INSTANCE-WIDE credentials. Real accounts start at 1 (auth_core.next_id), so 0
/// can never collide with one, and the shared key reuses the per-user vault's sealing and scoping
/// wholesale instead of inventing a second secret store.
pub const SERVER_KEY_UID: u64 = 0;
const cpaths = @import("paths.zig");
const tools = @import("../tools.zig");

const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const notFound = http.notFound;

/// Resolve ONE role's (base_url, api_key) when the client sends a BLANK key. Two fallbacks, in order:
///
///   1. Cloudflare OAuth — the endpoint or model names Workers AI, so swap in the user's auto-refreshed
///      token + authoritative account base.
///   2. The BYOK vault — the base URL matches a catalog provider, so look that provider's sealed key up
///      for THIS user (deploy/service.zig:189 has always done this for swarms; chat never did).
///
/// (2) is what lets a browser run a hosted turn at all. The desk can hold a key in its own settings and
/// paste it into the request; a web client must not — a key in localStorage is a key in every XSS. So the
/// browser sends the endpoint and nothing else, and the key stays server-side in the per-user vault.
/// A non-blank key always wins: an explicitly-supplied key is the caller's stated intent.
fn resolveRole(app: *App, uid: u64, arena: std.mem.Allocator, base_url: []const u8, model: []const u8, api_key: []const u8) struct { base: []const u8, key: []const u8 } {
    if (api_key.len != 0) return .{ .base = base_url, .key = api_key };

    const looks_cf = std.mem.indexOf(u8, base_url, "api.cloudflare.com") != null and std.mem.indexOf(u8, base_url, "/ai/") != null;
    if (looks_cf or std.mem.startsWith(u8, model, "@cf/")) {
        if (cf_oauth.resolveToken(app, uid, arena)) |cf| return .{ .base = cf.base_url, .key = cf.key };
    }

    if (modelcfg.providerForBase(base_url)) |prov| {
        if (app.vault.resolve(uid, prov, arena)) |rk| {
            // The vault may carry its own base (a custom endpoint stored with the key). Prefer it only
            // when the caller left the base blank — otherwise the caller's endpoint stands.
            const base = if (base_url.len == 0 and rk.base_url.len != 0) rk.base_url else base_url;
            return .{ .base = base, .key = rk.key };
        }
        // SHARED SERVER KEY. uid 0 is a reserved namespace no account can hold (auth_core's next_id
        // starts at 1), so the admin's instance-wide key lives in the same sealed vault under the same
        // scheme as everyone else's. It is the LAST resort: a user's own key always wins, so an account
        // that brings its own billing is never silently switched onto the admin's.
        //
        // The trade is deliberate and worth stating: once this is set, every user's turns spend the
        // admin's credit. That is exactly what a LAN or family install wants — nobody should have to
        // hold an API key to use the thing — and exactly what a public deployment must think about.
        if (app.vault.resolve(SERVER_KEY_UID, prov, arena)) |sk| {
            const base = if (base_url.len == 0 and sk.base_url.len != 0) sk.base_url else base_url;
            return .{ .base = base, .key = sk.key };
        }
    }

    return .{ .base = base_url, .key = api_key };
}

/// Sanitize a conversation id into ONE safe path segment (alnum / - / _ only, no separators, no "..",
/// bounded). Empty / unsafe → "". Mirrors chat_tools.safeSeg verbatim so a conv addressed here resolves to
/// the SAME `{data}/u{uid}/_chat/...{seg}` tree the chat build tools + a cast for that conversation use.
fn safeSeg(id: []const u8) []const u8 {
    const t = std.mem.trim(u8, id, " \r\n\t");
    if (t.len == 0 or t.len > 64) return "";
    for (t) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return "";
    }
    return t;
}

/// GET /api/v1/chat/convs — list this user's conversations. Scans `{data}/u{uid}/_chat/convs/*/`, deriving
/// {id,title,updated,msgs} from each conv's messages.jsonl (title = first message's content preview; updated
/// = latest `ts` seen; msgs = non-empty line count), all defaulting gracefully. Missing convs root → [].
pub fn listConvs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const root = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat/convs", .{ app.data, u.id });

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"ok\":true,\"convs\":[");

    // No convs dir yet → return an empty list, never crash.
    if (std.Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(app.io);
        var it = dir.iterate();
        var n: usize = 0;
        while (it.next(app.io) catch null) |ent| {
            if (ent.kind != .directory) continue;
            const seg = safeSeg(ent.name);
            if (seg.len == 0) continue; // stray/unsafe dir name — skip it, don't surface it

            // messages.jsonl is the conv's metadata source; absent (dir created but not yet written) → defaults.
            const mpath = std.fmt.allocPrint(res.arena, "{s}/{s}/messages.jsonl", .{ root, seg }) catch continue;
            const data = std.Io.Dir.cwd().readFileAlloc(app.io, mpath, res.arena, .limited(8 << 20)) catch "";

            var msgs: usize = 0;
            var updated: i64 = 0;
            var title: []const u8 = "";
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |raw| {
                const ln = std.mem.trim(u8, raw, " \r\t");
                if (ln.len == 0) continue;
                msgs += 1;
                if (jsonNumField(ln, "ts")) |t| {
                    if (t > updated) updated = t;
                }
                if (title.len == 0) {
                    const c = jsonField(ln, "content");
                    if (c.len > 0) title = clipUtf8(c, 80);
                }
            }
            if (title.len == 0) title = seg; // no messages yet → the id is the fallback title

            if (n > 0) try arr.append(app.gpa, ',');
            try arr.appendSlice(app.gpa, "{\"id\":");
            try http.jstr(app.gpa, &arr, seg);
            try arr.appendSlice(app.gpa, ",\"title\":");
            try http.jstr(app.gpa, &arr, title);
            const tail = try std.fmt.allocPrint(res.arena, ",\"updated\":{d},\"msgs\":{d}}}", .{ updated, msgs });
            try arr.appendSlice(app.gpa, tail);
            n += 1;
        }
    } else |_| {}

    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

/// GET /api/v1/chat/convs/:id — the full message log for one conversation. Reads messages.jsonl and passes
/// each stored line through VERBATIM (it is already a `{role,content,kind,ts}` JSON object the writer emitted,
/// same as swarmEvents streams events.jsonl lines untouched). 404 if the conv dir doesn't exist.
pub fn getConv(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);
    const dir = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat/convs/{s}", .{ app.data, u.id, seg });
    std.Io.Dir.cwd().access(app.io, dir, .{}) catch return notFound(res);

    const mpath = try std.fmt.allocPrint(res.arena, "{s}/messages.jsonl", .{dir});
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, mpath, res.arena, .limited(8 << 20)) catch "";

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"ok\":true,\"id\":");
    try http.jstr(app.gpa, &arr, seg);
    // `live` = a turn is executing for this conv RIGHT NOW (the engine's per-conv turn table). The desk uses
    // it to ATTACH its live event poller when opening a server-born run (a scheduled task's conversation) —
    // without it the view was a frozen snapshot while the run streamed server-side.
    try arr.appendSlice(app.gpa, if (chat_engine.isTurnLive(app.io, seg)) ",\"live\":true" else ",\"live\":false");
    try arr.appendSlice(app.gpa, ",\"messages\":[");
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue; // skip blank lines; each remaining line is one stored message object
        if (n > 0) try arr.append(app.gpa, ',');
        try arr.appendSlice(app.gpa, ln);
        n += 1;
    }
    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

/// DELETE /api/v1/chat/convs/:id — remove one conversation's whole tree. Twin of deploy_service.swarmDelete:
/// the path is resolved under the authenticated user's OWN `u{uid}` prefix, so a caller can only ever delete
/// its own conversation (structural ownership — no cross-user id is expressible). 404 if the conv is absent.
pub fn deleteConv(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);
    const dir = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat/convs/{s}", .{ app.data, u.id, seg });
    std.Io.Dir.cwd().access(app.io, dir, .{}) catch return notFound(res);
    std.Io.Dir.cwd().deleteTree(app.io, dir) catch {};
    try res.json(.{ .ok = true }, .{});
}

/// GET /api/v1/chat/convs/:id/events?from=N — verbatim twin of tail_fanout.swarmEvents over the conv's
/// events.jsonl: byte-offset cursor `from` in, whole-file length back out via X-Next-Offset, EVENTS content
/// type. 404 if the conv dir is absent; a conv with no events.jsonl yet streams an empty body.
pub fn convEvents(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);
    const dir = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat/convs/{s}", .{ app.data, u.id, seg });
    std.Io.Dir.cwd().access(app.io, dir, .{}) catch return notFound(res);

    const ev_path = try std.fmt.allocPrint(res.arena, "{s}/events.jsonl", .{dir});
    var from: usize = 0;
    const q = try req.query();
    if (q.get("from") orelse q.get("offset")) |fs| from = std.fmt.parseInt(usize, fs, 10) catch 0;
    // SIZE PROBE (from == max u64): answer the events file's TOTAL length as tiny JSON instead of a body.
    // The desk baselines its server-turn watch at the TAIL with this — transferring the whole backlog broke
    // on long conversations (the desk HTTP client caps one response at 1MB, so a from=0 fetch of a bigger
    // file could NEVER complete; the silently-0 cursor then replayed history as live delegations — the
    // tool-bridge bug). An older desk never sends the sentinel; an older server treats it as past-the-end
    // and returns an empty 200, which the new desk detects and falls back from. Probe answers 200 even for
    // a not-yet-written events file (len 0) — the conv-dir 404 above still gates unknown conversations.
    if (from == std.math.maxInt(u64)) {
        var size: usize = 0;
        if (std.Io.Dir.cwd().openFile(app.io, ev_path, .{})) |f| {
            defer f.close(app.io);
            size = std.math.cast(usize, f.length(app.io) catch 0) orelse 0;
        } else |_| {}
        return res.json(.{ .ok = true, .len = size }, .{});
    }
    // POSITIONAL read from the client's cursor `from` — NOT the whole file. A persistent afk turn appends
    // events.jsonl indefinitely; reading the whole file under a fixed cap returns EMPTY once it crosses the cap.
    // The file only grows, so `from` stays valid; one poll's payload is bounded (the desk catches up across polls
    // by advancing its cursor).
    var body: []const u8 = "";
    var next_off: usize = from;
    if (std.Io.Dir.cwd().openFile(app.io, ev_path, .{})) |f| {
        defer f.close(app.io);
        const size: usize = std.math.cast(usize, f.length(app.io) catch 0) orelse 0;
        if (size > from) {
            // PAGE bound UNDER the desk httpc's 1MB response cap (was 8MB — a burst bigger than the client
            // could swallow wedged its poll forever: the delta only grows). Catch-up pages across polls.
            const want = @min(size - from, 512 << 10);
            if (res.arena.alloc(u8, want)) |buf| {
                const n = f.readPositionalAll(app.io, buf, from) catch 0;
                body = buf[0..n];
                next_off = from + n;
            } else |_| {} // OOM → empty this poll; the client re-polls (cursor unchanged)
        }
    } else |_| {} // no events.jsonl yet → empty body (a fresh conv)
    res.header("X-Next-Offset", try std.fmt.allocPrint(res.arena, "{d}", .{next_off}));
    // .TEXT, deliberately NOT .EVENTS: this is a BOUNDED poll body, not an SSE stream. httpz omits
    // Content-Length on an EMPTY .EVENTS response (SSE framing = "body ends at close"), so every quiet-window
    // poll from a keep-alive client (the web UI, curl, any stock HTTP lib) hung until the 60s idle reaper cut
    // the socket — measured 5–60s per empty poll. .TEXT frames empty bodies as Content-Length: 0.
    res.content_type = .TEXT;
    res.body = body;
}

/// POST /api/v1/chat/convs/:id/messages — run ONE server-side agentic turn for this conversation. ON by default
/// (kill switch VEIL_CHAT_BACKEND=0); a disabled backend returns 501, which the desk treats as a fall-back signal.
/// The turn runs SYNCHRONOUSLY (it blocks this httpz worker thread, exactly as a cast/deploy does); progress is
/// written to the conv's messages.jsonl + events.jsonl, which the P0-4 read routes (getConv / convEvents) serve.
pub fn postMessage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // KILL SWITCH — before auth, parsing, anything. DEFAULT ON: the server chat turn runs unless VEIL_CHAT_BACKEND
    // is explicitly "0". A definitive 501 here is just one of the signals the desk uses to fall back to its own
    // local engine, so disabling the backend cleanly degrades to local chat rather than breaking it.
    const disabled = if (app.sup.parent_env) |env| blk: {
        const v = env.get("VEIL_CHAT_BACKEND") orelse break :blk false;
        break :blk std.mem.eql(u8, std.mem.trim(u8, v, " \r\n\t"), "0");
    } else false;
    if (disabled) {
        res.status = 501;
        return res.json(.{ .ok = false, .err = "chat backend disabled" }, .{});
    }

    const u = requireUser(app, req, res) orelse return;
    // OPEN TO EVERY AUTHED USER. This used to 403 non-admins, because runTurn handed the model the full
    // tool surface and tools.execute did not gate by role — the whole turn was blocked as the blunt way
    // to avoid that. The gate now exists: engine's ToolCtx carries `caps`, and a non-admin turn runs
    // .sandboxed — files jailed to the conversation workdir, research, and the entire hive-memory
    // surface, with code execution, host control, engine self-mod, tool authoring, browser/MCP drive,
    // casting and scheduling all refused at tools.execute and orchTool.
    //
    // Two things had to be true before this line could change, and both are (see the commit that
    // introduced them): the durable memory store is per-uid, so a turn's system prompt no longer carries
    // another user's credentials; and the sandbox check is an ALLOWLIST, because execute() falls through
    // to runAuthored for unknown names and a denylist would be defeated by make_tool.
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);

    const Body = struct {
        text: []const u8 = "",
        base_url: []const u8 = "",
        model: []const u8 = "",
        api_key: []const u8 = "",
        // MODEL TRIO (optional): per-role overrides for the "thinking" (planning + context housekeeping —
        // plan/reflect/summary/ctxsum/compact/lesson) and "prompting" (the auto-loop self-prompt-back drive)
        // calls. Absent/empty ⇒ that role falls back to the base (coding) triple above, so a single-model
        // client sends none of these and behaves exactly as before the trio.
        think_base_url: []const u8 = "",
        think_model: []const u8 = "",
        think_api_key: []const u8 = "",
        prompt_base_url: []const u8 = "",
        prompt_model: []const u8 = "",
        prompt_api_key: []const u8 = "",
        // AUTO-LOOP mode the desk armed for this conversation: 0=off (a normal bounded turn), 1=on (drive toward the
        // goal until DONE / no-progress / cap), 2=afk (persistent — never accept DONE, only Stop ends it). Absent =
        // 0. The server drive loop owns the loop now, so the desk stops running its own local loop for served convs.
        loop: u8 = 0,
        // CLIENT MODE: a desk/CLI turn sets this so the brain DELEGATES tool calls back to the client's harness
        // (file/shell/code run on the USER's machine) instead of executing in the server's sandbox. Absent =
        // false ⇒ server-side execution, exactly as a hive/API turn runs today.
        tool_client: bool = false,
        // ATTACHED IMAGE (v1 = ONE image): STANDARD base64 (std.base64.standard, no "data:" prefix) of the raw
        // PNG bytes of an image the user attached this turn. Absent/"" ⇒ no attachment. The engine OCRs it to
        // text (vision-as-text; no vision model sees pixels) and injects that as grounded context.
        image_b64: []const u8 = "",
    };
    const b = (try req.json(Body)) orelse return badReq(res, "bad body");
    const text = std.mem.trim(u8, b.text, " \r\n\t");
    if (text.len == 0) return badReq(res, "text is required");
    const loop_mode: u8 = switch (b.loop) {
        0, 1, 2 => b.loop,
        else => 0,
    }; // only the known tiers; garbage → OFF (never the most-expensive afk tier)

    // ONE in-flight turn per conversation. A turn does an unlocked read-modify-write of messages.jsonl / context.json
    // on a detached thread, so a second concurrent turn for the same conv would lost-update the durable log. Reject
    // the racing request with 409 (the desk cleanly falls back to its local engine on a non-2xx; a raw API client
    // can retry). Claiming here (not inside spawnTurn) lets us answer 409 before persisting anything.
    if (!chat_engine.tryBeginTurn(app.io, seg)) {
        res.status = 409;
        return res.json(.{ .ok = false, .err = "a turn is already running for this conversation" }, .{});
    }

    // BLANK-KEY RESOLUTION: a role sent with an empty key is resolved server-side — Cloudflare OAuth for a
    // Workers AI endpoint, otherwise this user's sealed BYOK vault entry for whichever catalog provider the
    // base URL belongs to. That is what lets a browser run a hosted turn without ever holding a key. Each of
    // the three roles resolves independently (a user can point prompting at CF and coding at BYOK).
    // SERVER DEFAULT: fill a blank coding model from the host's configuration before anything else
    // looks at it. Applied all-or-nothing on the pair — a model from the default paired with a base URL
    // the user happened to type (or vice versa) is a combination nobody chose, and it fails as a 404
    // that reads like a broken model. Only the coding role is defaulted; thinking/prompting already
    // fall back to coding inside ModelTrio.pick.
    const sd = app.cfg.defaults(res.arena);
    const use_default = b.model.len == 0 and b.base_url.len == 0 and sd.model.len > 0;
    const c_model = if (use_default) sd.model else b.model;
    const c_base = if (use_default) sd.base_url else b.base_url;
    // The server's trio applies per role, and only where the client sent nothing. An admin can
    // therefore publish a full coding/thinking/prompting split for everyone, or just a coding model —
    // an unset server role falls through to the server's coding model in ModelTrio.pick, exactly as an
    // unset user role does.
    const t_model = if (b.think_model.len == 0 and use_default) sd.think_model else b.think_model;
    const t_base = if (b.think_base_url.len == 0 and use_default) sd.think_base_url else b.think_base_url;
    const p_model = if (b.prompt_model.len == 0 and use_default) sd.prompt_model else b.prompt_model;
    const p_base = if (b.prompt_base_url.len == 0 and use_default) sd.prompt_base_url else b.prompt_base_url;

    const cc = resolveRole(app, u.id, res.arena, c_base, c_model, b.api_key);
    const eff_base = cc.base;
    const eff_key = cc.key;
    const tc = resolveRole(app, u.id, res.arena, t_base, t_model, b.think_api_key);
    const pc = resolveRole(app, u.id, res.arena, p_base, p_model, b.prompt_api_key);
    // The base (coding) triple is always populated; thinking/prompting stay empty when the client didn't send
    // them and fall back to coding inside the engine (ModelTrio.pick). The local-admission gate keys on the
    // coding/base backend only (below) — a mixed setup with a local secondary role is a documented limitation.
    const trio: chat_engine.ModelTrio = .{
        .coding = .{ .base_url = eff_base, .key = eff_key, .model = c_model },
        .thinking = .{ .base_url = tc.base, .key = tc.key, .model = t_model },
        .prompting = .{ .base_url = pc.base, .key = pc.key, .model = p_model },
    };

    // LOCAL-MODEL ADMISSION: a hosted backend fans out up to MAX_ACTIVE_TURNS, but a local model is one process
    // that can't parallelize — admit at most this machine's local budget at a time. Checked AFTER the per-conv
    // claim, so on rejection we must release that claim before returning 409. Hosted turns skip this entirely.
    const is_local = llm.isLocal(eff_base);
    if (is_local and !chat_engine.tryClaimLocal(app)) {
        chat_engine.endTurn(app.io, seg); // give back the per-conv slot tryBeginTurn just took
        res.status = 409;
        const msg = try std.fmt.allocPrint(res.arena, "local model busy — this machine's budget of {d} concurrent local chat(s) is full. Finish or stop one, or use a hosted/BYOK model for unlimited parallel chats.", .{chat_engine.localChatBudget(app)});
        return res.json(.{ .ok = false, .err = msg }, .{});
    }

    // Fire the turn on a background thread and return 202 AT ONCE, so the desk streams the turn's event frames
    // live via /events instead of blocking its poll until the whole (possibly multi-step) turn finishes. The turn
    // writes frames to events.jsonl as it runs. spawnTurn owns releasing the per-conv slot (via turnThread / its
    // inline paths) on every completion path.
    chat_engine.spawnTurn(app, u.id, seg, trio, text, loop_mode, b.tool_client, b.image_b64);

    res.status = 202;
    const events_url = try std.fmt.allocPrint(res.arena, "/api/v1/chat/convs/{s}/events?from=0", .{seg});
    try res.json(.{ .ok = true, .conv = seg, .turn = "running", .events_url = events_url }, .{});
}

/// POST /api/v1/chat/convs/:id/tool_result — a CLIENT-MODE turn delegated a tool to the client; the client runs
/// it with its harness and posts the result here. Appended to tool_results.jsonl, which the blocked turn reads
/// by call id and feeds back into the model. Body: {"id":"<call id>","result":"<tool output>"} — or
/// {"id":"<call id>","ack":true}, the pickup/heartbeat signal a client posts while its tool is still running so
/// the awaiting turn keeps its patience (see engine.awaitClientResult) instead of timing out a slow-but-alive tool.
pub fn toolResult(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);
    const Body = struct { id: []const u8 = "", result: []const u8 = "", ack: bool = false };
    const b = (try req.json(Body)) orelse return badReq(res, "bad body");
    if (b.id.len == 0) return badReq(res, "tool call id required");
    const dir = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat/convs/{s}", .{ app.data, u.id, seg });
    const path = try std.fmt.allocPrint(res.arena, "{s}/tool_results.jsonl", .{dir});
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(app.gpa);
    try line.appendSlice(app.gpa, "{\"id\":");
    try http.jstr(app.gpa, &line, b.id);
    if (b.ack) {
        // an ack line deliberately carries NO "result" key — the waiter counts it, never consumes it
        try line.appendSlice(app.gpa, ",\"ack\":true}\n");
    } else {
        try line.appendSlice(app.gpa, ",\"result\":");
        try http.jstr(app.gpa, &line, b.result);
        try line.appendSlice(app.gpa, "}\n");
    }
    http.appendFile(app.io, app.gpa, path, line.items) catch return http.serverErr(res, "could not record tool result");
    try res.json(.{ .ok = true }, .{});
}

/// POST /api/v1/chat/convs/:id/control — append a cooperative control op to the conv's control.jsonl. The running
/// server turn reads it between drive steps + before each tool: `{"op":"stop"}` ends the turn; `{"op":"steer",
/// "text":".."}` folds the user's mid-turn guidance in as a user message (posting to steer a running turn).
/// Structural ownership: the path is under the caller's own uid prefix.
pub fn chatControl(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);

    const Body = struct { op: []const u8 = "", text: []const u8 = "" };
    const b = (try req.json(Body)) orelse return badReq(res, "bad body");
    const op = std.mem.trim(u8, b.op, " \r\n\t");
    if (op.len == 0) return badReq(res, "op is required");

    const dir = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat/convs/{s}", .{ app.data, u.id, seg });
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    const path = try std.fmt.allocPrint(res.arena, "{s}/control.jsonl", .{dir});

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(app.gpa);
    try line.appendSlice(app.gpa, "{\"op\":");
    try http.jstr(app.gpa, &line, op);
    if (b.text.len > 0) { // a steer/say op carries the user's guidance text — persist it so the turn can fold it in
        try line.appendSlice(app.gpa, ",\"text\":");
        try http.jstr(app.gpa, &line, b.text);
    }
    try line.appendSlice(app.gpa, "}\n");
    http.appendFile(app.io, app.gpa, path, line.items) catch {};

    try res.json(.{ .ok = true }, .{});
}

// ----- tiny JSON field readers (flat, escape-naive — enough for the list preview) ------------

/// String value of a top-level "key" in a flat JSON object (returns a slice INTO `s`; "" if absent). Stops at
/// the first `"`, so an escaped quote inside a value clips the preview early — acceptable for a title preview.
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

/// Integer value of a top-level "key" in a flat JSON object (e.g. `"ts":1720000000`). null if absent/non-int.
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

/// Clip `s` to at most `max` bytes WITHOUT splitting a UTF-8 multibyte sequence (back off through any high
/// bytes at the tail). Keeps the body well-formed even though it's written raw (res.body, not res.json).
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    var n = @min(s.len, max);
    while (n > 0 and (s[n - 1] & 0x80) != 0) n -= 1;
    return s[0..n];
}

// ---- THE CONVERSATION'S FILES -------------------------------------------------------------------------
// A turn writes real files, and until now a web client had no way to see them: the desk browses the build
// tree directly off disk, which a browser cannot do. The swarm side has had /files and /file since the
// beginning; this is the same pair for a conversation. Ownership stays structural — the path is built from
// the authenticated uid, so a foreign conv id is not expressible rather than being checked and rejected.

const FILE_MAX = 2 << 20; // 2 MiB, matching the swarm route's per-file ceiling
const FILES_MAX = 400; // a listing is for browsing, not for mirroring a node_modules

/// Absolute "{root}/work" for one of THIS user's conversations, or "" if the id is unsafe.
fn convWorkDir(app: *App, arena: std.mem.Allocator, uid: u64, conv: []const u8, buf: []u8) []const u8 {
    const seg = safeSeg(conv);
    if (seg.len == 0) return "";
    const base = std.fmt.allocPrint(arena, "{s}/u{d}/_chat", .{ app.data, uid }) catch return "";
    const root = cpaths.buildRootFromChatBase(buf, base, seg);
    if (root.len == 0) return "";
    return std.fmt.allocPrint(arena, "{s}/work", .{root}) catch "";
}

/// GET /api/v1/chat/convs/:id/files — what this conversation has built. Walks {root}/work recursively and
/// returns relative paths with sizes. A conversation that has written nothing returns an empty list, not a
/// 404: "no files yet" is a normal state and the client should render it as one.
pub fn convFiles(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    var rb: [1024]u8 = undefined;
    const work = convWorkDir(app, res.arena, u.id, id, &rb);
    if (work.len == 0) return notFound(res);

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"ok\":true,\"files\":[");
    var n: usize = 0;
    var bytes: u64 = 0;

    if (std.Io.Dir.cwd().openDir(app.io, work, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(app.io);
        var walker = dir.walk(app.gpa) catch {
            try arr.appendSlice(app.gpa, "]}");
            res.content_type = .JSON;
            res.body = try res.arena.dupe(u8, arr.items);
            return;
        };
        defer walker.deinit();
        while (walker.next(app.io) catch null) |ent| {
            if (ent.kind != .file) continue;
            if (n >= FILES_MAX) break;
            const st = dir.statFile(app.io, ent.path, .{}) catch continue;
            if (n > 0) try arr.append(app.gpa, ',');
            try arr.appendSlice(app.gpa, "{\"path\":");
            // Normalize to forward slashes: the client uses this string as a query parameter and as a
            // display path, and a Windows walker hands back backslashes.
            const norm = try res.arena.dupe(u8, ent.path);
            for (norm) |*c| if (c.* == '\\') { c.* = '/'; };
            try http.jstr(app.gpa, &arr, norm);
            const tail = try std.fmt.allocPrint(res.arena, ",\"size\":{d}}}", .{st.size});
            try arr.appendSlice(app.gpa, tail);
            bytes += st.size;
            n += 1;
        }
    } else |_| {}

    const tail = try std.fmt.allocPrint(res.arena, "],\"n\":{d},\"bytes\":{d},\"truncated\":{}}}", .{ n, bytes, n >= FILES_MAX });
    try arr.appendSlice(app.gpa, tail);
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

/// GET /api/v1/chat/convs/:id/file?path=rel — one file's bytes, as text.
pub fn convFile(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const q = try req.query();
    const rel = q.get("path") orelse return badReq(res, "no path");
    // The SAME rule the tools use, deliberately: no absolute path, no drive letter, no "..". The swarm
    // route hand-rolls a weaker literal check; reusing tools.safeRel means one definition of "inside the
    // workspace" rather than two that can drift apart.
    if (!tools.safeRel(rel)) return badReq(res, "bad path");

    var rb: [1024]u8 = undefined;
    const work = convWorkDir(app, res.arena, u.id, id, &rb);
    if (work.len == 0) return notFound(res);
    const full = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ work, rel });
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, full, res.arena, .limited(FILE_MAX)) catch return notFound(res);
    res.content_type = .TEXT;
    res.body = data;
}
