//! Read-only conversation routes — the server-side twin of the swarm run-dir HTTP surface, but for the
//! veil-desk chat brain's per-conversation store. A conversation `{conv}` lives at
//!
//!     {data}/u{uid}/_chat/convs/{safeSeg(conv)}/
//!         messages.jsonl   // one JSON object per line: {role,content,kind,ts}
//!         events.jsonl     // SSE frames, the SAME per-line JSON shape swarm events.jsonl uses
//!
//! These four handlers only READ (and DELETE) that tree — no turn loop, no LLM, no live SSE stream, no
//! message writes; those land in later phases that populate the store. Until a writer phase lands the tree
//! is EMPTY, so every read path degrades gracefully: a missing convs root → empty list, a missing conv dir
//! → 404, a missing messages.jsonl/events.jsonl → empty body. Ownership is STRUCTURAL: every path is built
//! from the authenticated user's own uid (`u{uid}`), so a caller can only ever reach its own conversations —
//! the per-uid prefix IS the `owner.uid != u.id` check the swarm routes make against the registry.
//!
//!   GET    /api/v1/chat/convs            -> {ok:true, convs:[{id,title,updated,msgs}]}
//!   GET    /api/v1/chat/convs/:id        -> {ok:true, id, messages:[{role,content,kind,ts}]}   (404 if absent)
//!   DELETE /api/v1/chat/convs/:id        -> {ok:true}                                          (404 if absent)
//!   GET    /api/v1/chat/convs/:id/events?from=N -> events.jsonl cursor poll (X-Next-Offset out) — swarmEvents twin

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const chat_engine = @import("chat_engine.zig");

const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const notFound = http.notFound;

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

    // No convs dir yet (the store is empty until a writer phase lands) → return an empty list, never crash.
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
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, ev_path, res.arena, .limited(4 << 20)) catch "";
    var from: usize = 0;
    const q = try req.query();
    if (q.get("from") orelse q.get("offset")) |fs| from = std.fmt.parseInt(usize, fs, 10) catch 0;
    const slice = if (from <= data.len) data[from..] else data[0..0];
    res.header("X-Next-Offset", try std.fmt.allocPrint(res.arena, "{d}", .{data.len}));
    res.content_type = .EVENTS;
    res.body = slice;
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
    // ADMIN-ONLY for now. runTurn hands the model the FULL tool surface (incl. code-exec / host / engine
    // self-mod), and tools.execute does not gate by role — so until per-role SAFE-only tool access lands (strip
    // admin tools from the schema + gate execution, mirroring chat_tools' SAFE/ADMIN split), restrict the whole
    // turn to admins. This matches local-first: the desktop is admin on localhost, the intended user.
    if (!app.auth.isAdmin(u)) {
        res.status = 403;
        return res.json(.{ .ok = false, .err = "the server chat backend is admin-only for now" }, .{});
    }
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);

    const Body = struct {
        text: []const u8 = "",
        base_url: []const u8 = "",
        model: []const u8 = "",
        api_key: []const u8 = "",
    };
    const b = (try req.json(Body)) orelse return badReq(res, "bad body");
    const text = std.mem.trim(u8, b.text, " \r\n\t");
    if (text.len == 0) return badReq(res, "text is required");

    // ONE in-flight turn per conversation. A turn does an unlocked read-modify-write of messages.jsonl / context.json
    // on a detached thread, so a second concurrent turn for the same conv would lost-update the durable log. Reject
    // the racing request with 409 (the desk cleanly falls back to its local engine on a non-2xx; a raw API client
    // can retry). Claiming here (not inside spawnTurn) lets us answer 409 before persisting anything.
    if (!chat_engine.tryBeginTurn(app.io, seg)) {
        res.status = 409;
        return res.json(.{ .ok = false, .err = "a turn is already running for this conversation" }, .{});
    }

    // Fire the turn on a background thread and return 202 AT ONCE, so the desk streams the turn's event frames
    // live via /events instead of blocking its poll until the whole (possibly multi-step) turn finishes — the
    // "shows only 'server thinking'" symptom. The turn writes frames to events.jsonl as it runs. spawnTurn owns
    // releasing the per-conv slot (via turnThread / its inline paths) on every completion path.
    chat_engine.spawnTurn(app, u.id, seg, b.base_url, b.api_key, b.model, text);

    res.status = 202;
    const events_url = try std.fmt.allocPrint(res.arena, "/api/v1/chat/convs/{s}/events?from=0", .{seg});
    try res.json(.{ .ok = true, .conv = seg, .turn = "running", .events_url = events_url }, .{});
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
