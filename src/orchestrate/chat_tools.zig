//! Shared tool endpoint — ONE HTTP surface that both the desktop chat and any external client
//! call to run a SINGLE tool exactly the way a hive mind would. Mind tools (web_search, web_fetch,
//! recall_hive, observe, …) dispatch straight to the worker's `tools.execute()` through a minimal
//! ToolCtx; orchestration verbs (list_swarms / stop_swarm / swarm_findings) wrap the supervisor +
//! run-dir so a chat can drive its own swarms. Hive and chat share this ONE registry — as the tool
//! set grows, both surfaces grow with it (the user's ask: "add a single chat endpoint api to the
//! server side tools … then as we scale tools both hive and chat share the same").
//!
//!   POST /api/v1/chat/tool
//!     { "tool":"web_search",     "args":"{\"query\":\"...\"}" }   // args = JSON string, tool-call style
//!     { "tool":"stop_swarm",     "id":"<swarm-id>" }
//!     { "tool":"swarm_findings", "id":"<swarm-id>" }
//!   -> { "ok":true, "tool":"...", "result":"..." }               // mind tool
//!   -> { "ok":true, "tool":"list_swarms", "swarms":[ … ] }       // orchestration

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const tools = @import("../worker/tools.zig");
const osc = @import("../worker/oscillation.zig");

const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const notFound = http.notFound;
const serverErr = http.serverErr;
const unauth = http.unauth;

const ToolReq = struct {
    tool: []const u8 = "",
    args: []const u8 = "{}", // JSON *string* (tool-call convention), passed verbatim to tools.execute
    id: []const u8 = "", // convenience for orchestration verbs (also parsed out of args)
};

// Read-only / research / memory tools a chat turn may run in-process. Mutating + host + code-exec
// tools (write_file, edit_file, run_python, host_*, patch_system, send_message) are deliberately
// excluded: a chat tool call is not a sandboxed mind moment. Orchestration verbs are handled ahead
// of this list. Grow this set as shared, side-effect-safe tools land.
const MIND_ALLOW = [_][]const u8{
    "web_search", "web_fetch",  "fetch_json", "read_url",
    "recall_hive", "observe",   "share",      "deep_crawl",
};

fn mindAllowed(name: []const u8) bool {
    for (MIND_ALLOW) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

/// The swarm id the caller means: explicit top-level `id`, else the "id" field parsed out of `args`.
fn argId(body: ToolReq) []const u8 {
    const t = std.mem.trim(u8, body.id, " \r\n\t");
    if (t.len > 0) return t;
    return jsonField(body.args, "id");
}

pub fn chatTool(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const body = (try req.json(ToolReq)) orelse return badReq(res, "bad body");
    const tool = std.mem.trim(u8, body.tool, " \r\n\t");
    if (tool.len == 0) return badReq(res, "missing tool");

    // --- orchestration tools (wrap the supervisor + run dir) -------------------------------
    if (std.mem.eql(u8, tool, "list_swarms")) return listSwarms(app, u.id, res);
    if (std.mem.eql(u8, tool, "stop_swarm")) return stopSwarm(app, u.id, argId(body), res);
    if (std.mem.eql(u8, tool, "swarm_findings")) return findings(app, u.id, argId(body), res);

    // --- mind tools (the same executor the hive uses) --------------------------------------
    if (!mindAllowed(tool)) return badReq(res, "unknown or disallowed tool");
    return runMindTool(app, u.id, tool, body.args, res);
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
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != uid) return unauth(res);
    app.sup.stop(id);
    try res.json(.{ .ok = true, .tool = "stop_swarm", .stopped = true, .id = id }, .{});
}

fn findings(app: *App, uid: u64, id: []const u8, res: *httpz.Response) !void {
    if (id.len == 0) return badReq(res, "swarm_findings needs an id");
    const sw = app.sup.get(id) orelse return notFound(res);
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

fn runMindTool(app: *App, uid: u64, tool: []const u8, args: []const u8, res: *httpz.Response) !void {
    const environ = app.sup.parent_env orelse return serverErr(res, "server env unavailable");
    // Per-user scratch + memory DB so observe/share/recall_hive on the chat surface never cross accounts
    // (the endpoint is multi-tenant on the productized server). Isolation is by the per-uid DB FILE — NOT by
    // scope: recall_hive reads the fixed KNOWLEDGE/INTEL/SKILL scopes, so overriding learn_scope would just
    // make observe write somewhere recall_hive never looks (a stored-and-forgotten fact). Keep both default.
    const base = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat", .{ app.data, uid });
    const workdir = try std.fmt.allocPrint(res.arena, "{s}/work", .{base});
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, workdir, .default_dir) catch {};
    const db = try std.fmt.allocPrint(res.arena, "{s}/hive.sqlite", .{base});

    // The executor increments these; the chat surface ignores them (one shared sink is fine).
    var counters = [_]u32{0} ** 5;
    var ctx = tools.ToolCtx{
        .gpa = app.gpa,
        .io = app.io,
        .environ = environ,
        .run_dir = base,
        .workdir = workdir,
        .scope = "chat",
        .mind = "chat",
        .round = 0,
        .mem = osc.Mem.init(app.gpa, app.io, app.sup.neuron_bin, db),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
    };
    const result = tools.execute(&ctx, tool, args);
    // A tool result can carry arbitrary bytes (web_fetch/read_url page text) — httpz res.json requires valid
    // UTF-8, so scrub invalid sequences to U+FFFD-as-'?' in place before serializing. Guard the free: an OOM
    // dupe() fallback in execute() can hand back a static "" (len 0) that must NOT be freed.
    scrubUtf8(result);
    defer if (result.len > 0) app.gpa.free(result);
    try res.json(.{ .ok = true, .tool = tool, .result = result }, .{});
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

/// Last `max` bytes of `s`, snapped forward to the next line boundary so we never emit a half line.
fn tailLines(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var start = s.len - max;
    while (start < s.len and s[start] != '\n') : (start += 1) {}
    if (start < s.len) start += 1;
    return s[start..];
}
