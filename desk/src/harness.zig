//! harness.zig — the desk's picture of the web veil's worker harness (the user's "veil-web" Worker; the server side
//! is src/config/cf_harness.zig, the harness cloud/veil-web/veil-web.js).
//!
//! Pure data and parsing, like tots.zig: the harness's status, its job queue, its schedules and one job's outcome as
//! fixed-size values the Store holds under its one lock, the readers that fill them from the server's JSON, and the
//! writer for a queued job's request body. The poller calls the readers; main.zig draws the rows. No I/O here.

const std = @import("std");
const tots = @import("tots.zig"); // put / putText: one line, or text with its line breaks, into a fixed field

pub const MAX_JOBS = 72; // rows the tab holds, newest first (the harness keeps 16 waiting and 50 finished)
pub const MAX_SCHED = 12; // the harness keeps at most 12 schedules
pub const ID_MAX = 32; // the server refuses a longer job id
pub const RESULT_MAX = 6000; // characters of a job's result the tab keeps; a longer one ends in "..."
pub const TASK_MAX = 3000; // bytes of a task the desk queues: it rides a Command's text to the poller

/// GET /api/v1/harness, reduced.
pub const Status = struct {
    connected: bool = false, // logged in with Cloudflare
    reachable: bool = false, // a harness answered
    local: bool = false, // the owner allowed the harness's local jobs onto this machine (the server keeps the choice)
    local_waiting: u32 = 0, // local jobs on the harness that have not ended
    node: [NODE_ID_MAX]u8 = [_]u8{0} ** NODE_ID_MAX, // this machine's id on the mesh ("" until the harness has answered)
    node_len: u8 = 0,
    url: [120]u8 = [_]u8{0} ** 120,
    url_len: u8 = 0,
    err: [200]u8 = [_]u8{0} ** 200, // why there is no harness, in the server's or the harness's words
    err_len: u8 = 0,
    version: [8]u8 = [_]u8{0} ** 8,
    version_len: u8 = 0,
    default_model: [96]u8 = [_]u8{0} ** 96, // what a job queued with no model runs on
    default_model_len: u8 = 0,
    calls: u32 = 0, // model calls today (UTC)
    calls_max: u32 = 0,
    waiting: u32 = 0,
    running: u32 = 0,
    queue_max: u32 = 0,

    pub fn urlStr(s: *const Status) []const u8 {
        return s.url[0..s.url_len];
    }
    pub fn nodeStr(s: *const Status) []const u8 {
        return s.node[0..s.node_len];
    }
    pub fn errStr(s: *const Status) []const u8 {
        return s.err[0..s.err_len];
    }
    pub fn versionStr(s: *const Status) []const u8 {
        return s.version[0..s.version_len];
    }
    pub fn defaultModelStr(s: *const Status) []const u8 {
        return s.default_model[0..s.default_model_len];
    }
};

/// One row of the harness's queue.
pub const Job = struct {
    id: [ID_MAX]u8 = [_]u8{0} ** ID_MAX,
    id_len: u8 = 0,
    task: [160]u8 = [_]u8{0} ** 160, // the harness's own one-line preview
    task_len: u8 = 0,
    state: [12]u8 = [_]u8{0} ** 12, // queued / running / done / failed
    state_len: u8 = 0,
    note: [200]u8 = [_]u8{0} ** 200, // why it is waiting, when it is
    note_len: u8 = 0,
    created: i64 = 0, // ms
    finished: i64 = 0, // ms; 0 while it is not
    scheduled: bool = false, // a schedule queued it
    local: bool = false, // a job for the owner's machine: the harness does not run it

    pub fn idStr(j: *const Job) []const u8 {
        return j.id[0..j.id_len];
    }
    pub fn taskStr(j: *const Job) []const u8 {
        return j.task[0..j.task_len];
    }
    pub fn stateStr(j: *const Job) []const u8 {
        return j.state[0..j.state_len];
    }
    pub fn noteStr(j: *const Job) []const u8 {
        return j.note[0..j.note_len];
    }
    /// Still in the queue: a cancel stops it, where a finished job's is a delete.
    pub fn active(j: *const Job) bool {
        return activeState(j.stateStr());
    }
};

pub const MAX_NODES = 16; // the harness lists at most 16 nodes
pub const NODE_ID_MAX = 32;

/// One veil of the account, as the harness lists it: a machine or a browser tab on the mesh.
pub const Node = struct {
    id: [NODE_ID_MAX]u8 = [_]u8{0} ** NODE_ID_MAX,
    id_len: u8 = 0,
    name: [48]u8 = [_]u8{0} ** 48,
    name_len: u8 = 0,
    kind: [8]u8 = [_]u8{0} ** 8, // desk / server / web
    kind_len: u8 = 0,
    os: [24]u8 = [_]u8{0} ** 24,
    os_len: u8 = 0,
    version: [24]u8 = [_]u8{0} ** 24,
    version_len: u8 = 0,
    mcp: [120]u8 = [_]u8{0} ** 120, // its MCP servers' names, space separated
    mcp_len: u8 = 0,
    runs: bool = false, // it runs work sent to it (its owner's switch)
    browser: bool = false, // a web veil with the browser link on
    garrett: bool = false,
    online: bool = false,
    waiting: u32 = 0, // jobs addressed to it that have not ended
    ago_s: u32 = 0, // seconds since it last said it was here

    pub fn idStr(n: *const Node) []const u8 {
        return n.id[0..n.id_len];
    }
    pub fn nameStr(n: *const Node) []const u8 {
        return n.name[0..n.name_len];
    }
    pub fn kindStr(n: *const Node) []const u8 {
        return n.kind[0..n.kind_len];
    }
    pub fn osStr(n: *const Node) []const u8 {
        return n.os[0..n.os_len];
    }
    pub fn versionStr(n: *const Node) []const u8 {
        return n.version[0..n.version_len];
    }
    pub fn mcpStr(n: *const Node) []const u8 {
        return n.mcp[0..n.mcp_len];
    }
};

/// A node id as the server accepts one: 8 to 32 lower-case letters and digits.
pub fn validNode(id: []const u8) bool {
    if (id.len < 8 or id.len > NODE_ID_MAX) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
    return true;
}

/// Read a GET /api/v1/harness/nodes reply. How many, or null for anything that is not that reply.
pub fn parseNodes(gpa: std.mem.Allocator, body: []const u8, out: *[MAX_NODES]Node) ?usize {
    const JN = struct { id: []const u8 = "", name: []const u8 = "", kind: []const u8 = "", os: []const u8 = "", version: []const u8 = "", runs: bool = false, browser: bool = false, garrett: bool = false, mcp: []const []const u8 = &.{}, seen: i64 = 0, online: bool = false, waiting: i64 = 0 };
    const J = struct { ok: bool = false, now: i64 = 0, nodes: []const JN = &.{} };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    if (!p.value.ok) return null;
    var n: usize = 0;
    for (p.value.nodes) |j| {
        if (n == MAX_NODES) break;
        if (!validNode(j.id)) continue; // an id the server would refuse cannot be sent to
        var r: Node = .{ .runs = j.runs, .browser = j.browser, .garrett = j.garrett, .online = j.online, .waiting = u32of(j.waiting), .ago_s = u32of(@divTrunc(p.value.now - j.seen, 1000)) };
        r.id_len = @intCast(tots.put(&r.id, j.id));
        r.name_len = @intCast(tots.put(&r.name, j.name));
        r.kind_len = @intCast(tots.put(&r.kind, j.kind));
        r.os_len = @intCast(tots.put(&r.os, j.os));
        r.version_len = @intCast(tots.put(&r.version, j.version));
        var m: usize = 0;
        for (j.mcp) |nm| {
            if (nm.len == 0 or m + nm.len + 1 > r.mcp.len) continue;
            if (m > 0) {
                r.mcp[m] = ' ';
                m += 1;
            }
            m += tots.put(r.mcp[m..], nm);
        }
        r.mcp_len = @intCast(m);
        out[n] = r;
        n += 1;
    }
    return n;
}

/// {"task": ..., "node": ...}: the body of POST /api/v1/harness/jobs for a job sent to one node of the mesh.
pub fn sendBody(buf: []u8, task: []const u8, node: []const u8) ?[]const u8 {
    if (!validNode(node)) return null;
    var w = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(.{ .task = task, .node = node }, .{}, &w) catch return null;
    return w.buffered();
}

pub fn activeState(state: []const u8) bool {
    return std.mem.eql(u8, state, "queued") or std.mem.eql(u8, state, "running");
}

/// One of the harness's schedules.
pub const Sched = struct {
    id: [ID_MAX]u8 = [_]u8{0} ** ID_MAX,
    id_len: u8 = 0,
    task: [160]u8 = [_]u8{0} ** 160,
    task_len: u8 = 0,
    every_s: u32 = 0,
    next: i64 = 0, // ms
    runs: u32 = 0,

    pub fn taskStr(s: *const Sched) []const u8 {
        return s.task[0..s.task_len];
    }
};

/// One job whole, reduced to what the tab shows: how it ended and what it said.
pub const Detail = struct {
    id: [ID_MAX]u8 = [_]u8{0} ** ID_MAX,
    id_len: u8 = 0,
    state: [12]u8 = [_]u8{0} ** 12,
    state_len: u8 = 0,
    model: [96]u8 = [_]u8{0} ** 96,
    model_len: u8 = 0,
    task: [1200]u8 = [_]u8{0} ** 1200,
    task_len: u16 = 0,
    text: [RESULT_MAX]u8 = [_]u8{0} ** RESULT_MAX, // its result, or its error when it failed
    text_len: u16 = 0,
    failed: bool = false,
    calls: u32 = 0, // model calls it made
    rounds: u32 = 0, // tool calls it made
    files: u32 = 0, // files it wrote (kept on the harness)

    pub fn idStr(d: *const Detail) []const u8 {
        return d.id[0..d.id_len];
    }
    pub fn stateStr(d: *const Detail) []const u8 {
        return d.state[0..d.state_len];
    }
    pub fn modelStr(d: *const Detail) []const u8 {
        return d.model[0..d.model_len];
    }
    pub fn taskStr(d: *const Detail) []const u8 {
        return d.task[0..d.task_len];
    }
    pub fn textStr(d: *const Detail) []const u8 {
        return d.text[0..d.text_len];
    }
};

pub const MAX_CONVS = 60; // harness chats the tab lists, newest first (the harness keeps up to 200)
pub const CONV_ID_MAX = 24;
pub const CHAT_TEXT = 12000; // characters of a chat's transcript the tab keeps: its END when it is longer

/// One chat the harness keeps (the web veil's conversations).
pub const Conv = struct {
    id: [CONV_ID_MAX]u8 = [_]u8{0} ** CONV_ID_MAX,
    id_len: u8 = 0,
    title: [120]u8 = [_]u8{0} ** 120,
    title_len: u8 = 0,
    at: i64 = 0, // ms

    pub fn idStr(c: *const Conv) []const u8 {
        return c.id[0..c.id_len];
    }
    pub fn titleStr(c: *const Conv) []const u8 {
        return c.title[0..c.title_len];
    }
};

/// One harness chat as a transcript to read: who spoke, then what they said.
pub const Chat = struct {
    id: [CONV_ID_MAX]u8 = [_]u8{0} ** CONV_ID_MAX,
    id_len: u8 = 0,
    title: [120]u8 = [_]u8{0} ** 120,
    title_len: u8 = 0,
    msgs: u32 = 0, // how many messages the chat has
    files: u32 = 0, // how many files it carries (kept on the harness)
    cut: bool = false, // the transcript's start was left out
    text: [CHAT_TEXT]u8 = [_]u8{0} ** CHAT_TEXT,
    text_len: u16 = 0,

    pub fn idStr(c: *const Chat) []const u8 {
        return c.id[0..c.id_len];
    }
    pub fn titleStr(c: *const Chat) []const u8 {
        return c.title[0..c.title_len];
    }
    pub fn textStr(c: *const Chat) []const u8 {
        return c.text[0..c.text_len];
    }
};

/// A chat id as the harness accepts one: 6 to 24 lower-case letters and digits.
pub fn validConvId(id: []const u8) bool {
    if (id.len < 6 or id.len > CONV_ID_MAX) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
    return true;
}

/// Read a GET /api/v1/harness/convs reply (the harness lists newest first). How many, or null for anything else.
pub fn parseConvs(gpa: std.mem.Allocator, body: []const u8, out: *[MAX_CONVS]Conv) ?usize {
    const JC = struct { id: []const u8 = "", title: []const u8 = "", at: i64 = 0 };
    const J = struct { ok: bool = false, convs: []const JC = &.{} };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    if (!p.value.ok) return null;
    var n: usize = 0;
    for (p.value.convs) |j| {
        if (n == MAX_CONVS) break;
        if (!validConvId(j.id)) continue;
        var c: Conv = .{ .at = j.at };
        c.id_len = @intCast(tots.put(&c.id, j.id));
        c.title_len = @intCast(tots.put(&c.title, j.title));
        out[n] = c;
        n += 1;
    }
    return n;
}

/// Read a GET /api/v1/harness/convs/:id reply into a transcript. A message that is not text (or has none) is
/// skipped. False (and `out` untouched) for anything that is not that reply.
pub fn parseChat(gpa: std.mem.Allocator, body: []const u8, out: *Chat) bool {
    const JM = struct { role: []const u8 = "", content: std.json.Value = .null };
    const JC = struct { id: []const u8 = "", title: []const u8 = "", msgs: []const JM = &.{}, files: std.json.Value = .null };
    const J = struct { ok: bool = false, conv: ?JC = null };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer p.deinit();
    const j = p.value.conv orelse return false;
    if (!p.value.ok or !validConvId(j.id)) return false;
    var all: std.ArrayListUnmanaged(u8) = .empty;
    defer all.deinit(gpa);
    for (j.msgs) |m| {
        if (m.content != .string or m.content.string.len == 0) continue;
        const who = if (std.mem.eql(u8, m.role, "user")) "You" else if (std.mem.eql(u8, m.role, "assistant")) "Veil" else if (std.mem.eql(u8, m.role, "error")) "Error" else continue;
        if (all.items.len > 0) all.appendSlice(gpa, "\n\n") catch return false;
        all.appendSlice(gpa, who) catch return false;
        all.appendSlice(gpa, ":\n") catch return false;
        for (m.content.string) |ch| {
            if (ch == '\r') continue;
            all.append(gpa, if (ch == '\t') ' ' else ch) catch return false;
        }
    }
    var c: Chat = .{ .msgs = @intCast(@min(j.msgs.len, std.math.maxInt(u32))) };
    c.id_len = @intCast(tots.put(&c.id, j.id));
    c.title_len = @intCast(tots.put(&c.title, j.title));
    if (j.files == .object) c.files = @intCast(@min(j.files.object.count(), std.math.maxInt(u32)));
    // a long chat keeps its END: the last CHAT_TEXT bytes, from a character boundary
    var from: usize = if (all.items.len > CHAT_TEXT) all.items.len - CHAT_TEXT else 0;
    while (from < all.items.len and (all.items[from] & 0xC0) == 0x80) from += 1;
    c.cut = from > 0;
    const tail = all.items[from..];
    @memcpy(c.text[0..tail.len], tail);
    c.text_len = @intCast(tail.len);
    out.* = c;
    return true;
}

/// {"conv": ...}: the body of POST /api/v1/harness/convs, which copies one of the server's conversations up.
pub fn pushBody(buf: []u8, conv: []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(.{ .conv = conv }, .{}, &w) catch return null;
    return w.buffered();
}

fn u32of(v: i64) u32 {
    return @intCast(std.math.clamp(v, 0, std.math.maxInt(u32)));
}

/// A job or schedule id as the server accepts one in a path: lower-case letters and digits, 1 to ID_MAX.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > ID_MAX) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
    return true;
}

/// Read a GET /api/v1/harness reply. False (and `out` untouched) for anything that is not that reply.
pub fn parseStatus(gpa: std.mem.Allocator, body: []const u8, out: *Status) bool {
    const JH = struct {
        version: []const u8 = "",
        usage: struct { calls: i64 = 0 } = .{},
        limits: struct { calls_max: i64 = 0 } = .{},
        queue: struct { waiting: i64 = 0, running: i64 = 0, max: i64 = 0, local: i64 = 0 } = .{},
    };
    const J = struct { ok: bool = false, connected: bool = false, reachable: bool = false, local: bool = false, node: []const u8 = "", url: []const u8 = "", err: []const u8 = "", default_model: []const u8 = "", harness: ?JH = null };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer p.deinit();
    const v = p.value;
    if (!v.ok) return false;
    var s: Status = .{ .connected = v.connected, .reachable = v.reachable and v.harness != null, .local = v.local };
    s.url_len = @intCast(tots.put(&s.url, v.url));
    if (validNode(v.node)) s.node_len = @intCast(tots.put(&s.node, v.node));
    s.err_len = @intCast(tots.put(&s.err, v.err));
    s.default_model_len = @intCast(tots.put(&s.default_model, v.default_model));
    if (v.harness) |h| {
        s.version_len = @intCast(tots.put(&s.version, h.version));
        s.calls = u32of(h.usage.calls);
        s.calls_max = u32of(h.limits.calls_max);
        s.waiting = u32of(h.queue.waiting);
        s.running = u32of(h.queue.running);
        s.queue_max = u32of(h.queue.max);
        s.local_waiting = u32of(h.queue.local);
    }
    out.* = s;
    return true;
}

/// Read a GET /api/v1/harness/jobs reply into `out`, NEWEST first (the harness lists oldest first; past MAX_JOBS the
/// oldest are the ones left out). How many, or null for anything that is not that reply.
pub fn parseJobs(gpa: std.mem.Allocator, body: []const u8, out: *[MAX_JOBS]Job) ?usize {
    const JJ = struct { id: []const u8 = "", task: []const u8 = "", state: []const u8 = "", note: []const u8 = "", created: i64 = 0, finished: i64 = 0, schedule: []const u8 = "", local: bool = false };
    const J = struct { ok: bool = false, jobs: []const JJ = &.{} };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    if (!p.value.ok) return null;
    var n: usize = 0;
    var i = p.value.jobs.len;
    while (i > 0 and n < MAX_JOBS) {
        i -= 1;
        const j = p.value.jobs[i];
        if (!validId(j.id)) continue; // an id the server would refuse cannot be opened or cancelled
        var r: Job = .{ .created = j.created, .finished = j.finished, .scheduled = j.schedule.len > 0, .local = j.local };
        r.id_len = @intCast(tots.put(&r.id, j.id));
        r.task_len = @intCast(tots.put(&r.task, j.task));
        r.state_len = @intCast(tots.put(&r.state, j.state));
        r.note_len = @intCast(tots.put(&r.note, j.note));
        out[n] = r;
        n += 1;
    }
    return n;
}

/// Read a GET /api/v1/harness/schedules reply. How many, or null for anything that is not that reply.
pub fn parseScheds(gpa: std.mem.Allocator, body: []const u8, out: *[MAX_SCHED]Sched) ?usize {
    const JS = struct { id: []const u8 = "", task: []const u8 = "", every_s: i64 = 0, next: i64 = 0, runs: i64 = 0 };
    const J = struct { ok: bool = false, schedules: []const JS = &.{} };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    if (!p.value.ok) return null;
    var n: usize = 0;
    for (p.value.schedules) |j| {
        if (n == MAX_SCHED) break;
        if (j.id.len == 0 or j.id.len > ID_MAX) continue;
        var r: Sched = .{ .every_s = u32of(j.every_s), .next = j.next, .runs = u32of(j.runs) };
        r.id_len = @intCast(tots.put(&r.id, j.id));
        r.task_len = @intCast(tots.put(&r.task, j.task));
        out[n] = r;
        n += 1;
    }
    return n;
}

/// Read a GET /api/v1/harness/jobs/:id reply. False (and `out` untouched) for anything that is not that reply.
pub fn parseJob(gpa: std.mem.Allocator, body: []const u8, out: *Detail) bool {
    const JJ = struct {
        id: []const u8 = "",
        task: []const u8 = "",
        model: []const u8 = "",
        state: []const u8 = "",
        result: []const u8 = "",
        @"error": []const u8 = "",
        calls: i64 = 0,
        rounds: std.json.Value = .null,
        files: std.json.Value = .null,
    };
    const J = struct { ok: bool = false, job: ?JJ = null };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer p.deinit();
    const j = p.value.job orelse return false;
    if (!p.value.ok or !validId(j.id)) return false;
    var d: Detail = .{ .calls = u32of(j.calls) };
    d.id_len = @intCast(tots.put(&d.id, j.id));
    d.state_len = @intCast(tots.put(&d.state, j.state));
    d.model_len = @intCast(tots.put(&d.model, j.model));
    d.task_len = @intCast(tots.putText(&d.task, j.task));
    d.failed = std.mem.eql(u8, j.state, "failed");
    d.text_len = @intCast(tots.putText(&d.text, if (d.failed and j.@"error".len > 0) j.@"error" else j.result));
    if (j.rounds == .array) d.rounds = @intCast(@min(j.rounds.array.items.len, std.math.maxInt(u32)));
    if (j.files == .object) d.files = @intCast(@min(j.files.object.count(), std.math.maxInt(u32)));
    out.* = d;
    return true;
}

/// The body of POST /api/v1/harness/jobs in `buf`, or null when it does not fit. An empty model is left out: the
/// server then sends its default.
pub fn queueBody(buf: []u8, task: []const u8, model: []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (model.len > 0)
        std.json.Stringify.value(.{ .task = task, .model = model }, .{}, &w) catch return null
    else
        std.json.Stringify.value(.{ .task = task }, .{}, &w) catch return null;
    return w.buffered();
}

/// "every 5m" / "every 2h" / "every 3d" for a schedule's repeat.
pub fn everyStr(buf: []u8, every_s: u32) []const u8 {
    if (every_s >= 86400 and every_s % 86400 == 0) return std.fmt.bufPrint(buf, "every {d}d", .{every_s / 86400}) catch "";
    if (every_s >= 3600 and every_s % 3600 == 0) return std.fmt.bufPrint(buf, "every {d}h", .{every_s / 3600}) catch "";
    if (every_s >= 60 and every_s % 60 == 0) return std.fmt.bufPrint(buf, "every {d}m", .{every_s / 60}) catch "";
    return std.fmt.bufPrint(buf, "every {d}s", .{every_s}) catch "";
}

const tt = std.testing;

test "harness: the status reads the server's reply; no harness keeps the reason; anything else is refused" {
    const up =
        \\{"ok":true,"connected":true,"reachable":true,"local":true,"url":"https://veil-web.acme.workers.dev","err":"","default_model":"@cf/x/y","harness":{"ok":true,"version":"5","ai":true,"account":"acct","limits":{"calls_max":400,"bytes_max":209715200,"storage_max":67108864},"usage":{"day":"2026-11-13","calls":41,"bytes":9000},"storage_bytes":1200,"queue":{"waiting":2,"running":1,"max":16,"kept":9,"keep":50,"local":1},"schedules":{"count":1,"max":12,"shortest_s":300}}}
    ;
    var s: Status = .{};
    try tt.expect(parseStatus(tt.allocator, up, &s));
    try tt.expect(s.connected and s.reachable);
    try tt.expectEqualStrings("https://veil-web.acme.workers.dev", s.urlStr());
    try tt.expectEqualStrings("5", s.versionStr());
    try tt.expect(s.local);
    try tt.expectEqual(@as(u32, 1), s.local_waiting);
    try tt.expectEqualStrings("@cf/x/y", s.defaultModelStr());
    try tt.expectEqual(@as(u32, 41), s.calls);
    try tt.expectEqual(@as(u32, 400), s.calls_max);
    try tt.expectEqual(@as(u32, 2), s.waiting);
    try tt.expectEqual(@as(u32, 1), s.running);
    try tt.expectEqual(@as(u32, 16), s.queue_max);

    const down =
        \\{"ok":true,"connected":true,"reachable":false,"url":"https://veil-web.acme.workers.dev","err":"no veil-web harness answered at https://veil-web.acme.workers.dev","default_model":"@cf/x/y","harness":null}
    ;
    try tt.expect(parseStatus(tt.allocator, down, &s));
    try tt.expect(s.connected and !s.reachable and !s.local); // a reply without the switch reads as off
    try tt.expect(std.mem.startsWith(u8, s.errStr(), "no veil-web harness answered"));
    try tt.expectEqual(@as(u32, 0), s.calls_max);

    const before = s;
    try tt.expect(!parseStatus(tt.allocator, "{\"ok\":false,\"err\":\"the harness is admin-only for now\"}", &s));
    try tt.expect(!parseStatus(tt.allocator, "<html>", &s));
    try tt.expectEqualStrings(before.errStr(), s.errStr());
}

test "harness: the queue is read newest first, one line per field, and a row the server could not address is dropped" {
    const body =
        \\{"ok":true,"jobs":[{"id":"mabc01","task":"read the\ntide tables","state":"done","created":1,"finished":9,"bytes":300,"note":"","schedule":""},{"id":"../x","task":"bad","state":"queued"},{"id":"mabc02","task":"watch the harbour","state":"running","created":2,"finished":0,"bytes":90,"note":"waiting: today's model-call budget (400) is spent","schedule":"s1x9"},{"id":"mabc03","task":"run my tests","state":"queued","created":3,"note":"waiting for the owner's machine","schedule":"","local":true}],"max":16}
    ;
    var rows: [MAX_JOBS]Job = undefined;
    try tt.expectEqual(@as(?usize, 3), parseJobs(tt.allocator, body, &rows));
    try tt.expectEqualStrings("mabc03", rows[0].idStr()); // newest first
    try tt.expect(rows[0].local and rows[0].active());
    try tt.expectEqualStrings("mabc02", rows[1].idStr());
    try tt.expectEqualStrings("running", rows[1].stateStr());
    try tt.expect(rows[1].active() and rows[1].scheduled and !rows[1].local);
    try tt.expect(std.mem.startsWith(u8, rows[1].noteStr(), "waiting: "));
    try tt.expectEqualStrings("mabc01", rows[2].idStr());
    try tt.expectEqualStrings("read the tide tables", rows[2].taskStr());
    try tt.expect(!rows[2].active() and !rows[2].scheduled);
    try tt.expectEqual(@as(i64, 9), rows[2].finished);
    try tt.expectEqual(@as(?usize, 0), parseJobs(tt.allocator, "{\"ok\":true,\"jobs\":[]}", &rows));
    try tt.expectEqual(@as(?usize, null), parseJobs(tt.allocator, "{\"ok\":false,\"err\":\"no veil-web harness answered\"}", &rows));
    try tt.expectEqual(@as(?usize, null), parseJobs(tt.allocator, "not json", &rows));

    // more jobs than the tab holds: the newest MAX_JOBS stay
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(tt.allocator);
    try big.appendSlice(tt.allocator, "{\"ok\":true,\"jobs\":[");
    for (0..MAX_JOBS + 5) |i| try big.print(tt.allocator, "{s}{{\"id\":\"j{d}\",\"state\":\"done\"}}", .{ if (i > 0) "," else "", i });
    try big.appendSlice(tt.allocator, "]}");
    try tt.expectEqual(@as(?usize, MAX_JOBS), parseJobs(tt.allocator, big.items, &rows));
    var nb: [8]u8 = undefined;
    try tt.expectEqualStrings(try std.fmt.bufPrint(&nb, "j{d}", .{MAX_JOBS + 4}), rows[0].idStr());
    try tt.expectEqualStrings("j5", rows[MAX_JOBS - 1].idStr());
}

test "harness: one job whole reduces to how it ended, what it said and what it used" {
    const done =
        \\{"ok":true,"job":{"id":"mabc01","task":"read the tide tables","model":"@cf/x/y","schedule":"","state":"done","created":1,"started":2,"finished":9,"rounds":[{"tool":"web_fetch","args":{"url":"https://example.test"},"result":"HTTP 200"},{"tool":"write_file","args":{"name":"tides.md"},"result":"wrote tides.md"}],"files":{"tides.md":"high 04:10"},"result":"High tide is at 04:10.\r\nLow at 10:32.","error":"","note":"","calls":3}}
    ;
    var d: Detail = .{};
    try tt.expect(parseJob(tt.allocator, done, &d));
    try tt.expectEqualStrings("mabc01", d.idStr());
    try tt.expectEqualStrings("done", d.stateStr());
    try tt.expectEqualStrings("@cf/x/y", d.modelStr());
    try tt.expectEqualStrings("read the tide tables", d.taskStr());
    try tt.expectEqualStrings("High tide is at 04:10.\nLow at 10:32.", d.textStr()); // line breaks kept, CR dropped
    try tt.expect(!d.failed);
    try tt.expectEqual(@as(u32, 3), d.calls);
    try tt.expectEqual(@as(u32, 2), d.rounds);
    try tt.expectEqual(@as(u32, 1), d.files);

    const failed =
        \\{"ok":true,"job":{"id":"mabc02","task":"t","model":"@cf/x/y","state":"failed","rounds":[],"files":{},"result":"","error":"stopped after 24 tool calls without finishing","calls":24}}
    ;
    try tt.expect(parseJob(tt.allocator, failed, &d));
    try tt.expect(d.failed);
    try tt.expectEqualStrings("stopped after 24 tool calls without finishing", d.textStr());

    // a result longer than the tab keeps ends in "..."
    var long: std.ArrayListUnmanaged(u8) = .empty;
    defer long.deinit(tt.allocator);
    try long.appendSlice(tt.allocator, "{\"ok\":true,\"job\":{\"id\":\"mabc03\",\"state\":\"done\",\"result\":\"");
    try long.appendNTimes(tt.allocator, 'x', RESULT_MAX + 100);
    try long.appendSlice(tt.allocator, "\"}}");
    try tt.expect(parseJob(tt.allocator, long.items, &d));
    try tt.expectEqual(@as(usize, RESULT_MAX), d.textStr().len);
    try tt.expect(std.mem.endsWith(u8, d.textStr(), "..."));

    const before = d;
    try tt.expect(!parseJob(tt.allocator, "{\"ok\":false,\"err\":\"no such job\"}", &d));
    try tt.expect(!parseJob(tt.allocator, "{\"ok\":true,\"job\":null}", &d));
    try tt.expectEqualStrings(before.idStr(), d.idStr());
}

test "harness: the schedules, and how a repeat reads" {
    const body =
        \\{"ok":true,"schedules":[{"id":"s1x9ab","task":"check the\tbuild","model":"@cf/x/y","every_s":3600,"next":1790000000000,"created":1,"runs":4,"last_job":"mabc01"},{"id":"","task":"nameless"}],"max":12}
    ;
    var rows: [MAX_SCHED]Sched = undefined;
    try tt.expectEqual(@as(?usize, 1), parseScheds(tt.allocator, body, &rows));
    try tt.expectEqualStrings("check the build", rows[0].taskStr());
    try tt.expectEqual(@as(u32, 3600), rows[0].every_s);
    try tt.expectEqual(@as(u32, 4), rows[0].runs);
    try tt.expectEqual(@as(?usize, null), parseScheds(tt.allocator, "{\"ok\":false}", &rows));
    var b: [24]u8 = undefined;
    try tt.expectEqualStrings("every 1h", everyStr(&b, 3600));
    try tt.expectEqualStrings("every 5m", everyStr(&b, 300));
    try tt.expectEqualStrings("every 2d", everyStr(&b, 172800));
    try tt.expectEqualStrings("every 90m", everyStr(&b, 5400));
    try tt.expectEqualStrings("every 45s", everyStr(&b, 45));
}

test "harness: a queued job's body is JSON the server's parser reads back; no model means the server's default" {
    var buf: [TASK_MAX * 2 + 200]u8 = undefined;
    const P = struct { task: []const u8, model: []const u8 = "" };
    const with = queueBody(&buf, "say \"hi\"\nthen stop", "@cf/x/y").?;
    const a = try std.json.parseFromSlice(P, tt.allocator, with, .{});
    defer a.deinit();
    try tt.expectEqualStrings("say \"hi\"\nthen stop", a.value.task);
    try tt.expectEqualStrings("@cf/x/y", a.value.model);
    const without = queueBody(&buf, "read the tide tables", "").?;
    try tt.expectEqualStrings("{\"task\":\"read the tide tables\"}", without);
    var small: [16]u8 = undefined;
    try tt.expect(queueBody(&small, "read the tide tables", "") == null);
    try tt.expect(validId("mabc01") and !validId("") and !validId("A1") and !validId("a/b") and !validId("a" ** (ID_MAX + 1)));
}

test "harness: its chats are listed as it lists them, and one reads as a transcript that keeps its end when long" {
    const list =
        \\{"ok":true,"convs":[{"id":"mabc1234","title":"Tide\ttimes","at":1790000009000,"bytes":300},{"id":"bad id","title":"x","at":1},{"id":"d0123456789abcdef0123","title":"when is high tide","at":1790000001000,"bytes":90}],"max":200}
    ;
    var rows: [MAX_CONVS]Conv = undefined;
    try tt.expectEqual(@as(?usize, 2), parseConvs(tt.allocator, list, &rows));
    try tt.expectEqualStrings("mabc1234", rows[0].idStr());
    try tt.expectEqualStrings("Tide times", rows[0].titleStr());
    try tt.expectEqual(@as(i64, 1790000009000), rows[0].at);
    try tt.expectEqualStrings("d0123456789abcdef0123", rows[1].idStr());
    try tt.expectEqual(@as(?usize, null), parseConvs(tt.allocator, "{\"ok\":false,\"err\":\"x\"}", &rows));

    const one =
        \\{"ok":true,"conv":{"id":"mabc1234","title":"Tide times","at":1790000009000,"msgs":[{"role":"user","content":"when is\r\nhigh tide?"},{"role":"assistant","content":"","tools":[{"name":"web_search"}]},{"role":"assistant","content":"At 04:10.","tools":[]},{"role":"error","content":"the model call failed"},{"role":"tool","content":"ignored"},{"role":"user","content":7}],"files":{"tides.md":"x","b.txt":"y"}}}
    ;
    const c = try tt.allocator.create(Chat);
    defer tt.allocator.destroy(c);
    c.* = .{};
    try tt.expect(parseChat(tt.allocator, one, c));
    try tt.expectEqualStrings("mabc1234", c.idStr());
    try tt.expectEqualStrings("Tide times", c.titleStr());
    try tt.expectEqualStrings("You:\nwhen is\nhigh tide?\n\nVeil:\nAt 04:10.\n\nError:\nthe model call failed", c.textStr());
    try tt.expectEqual(@as(u32, 6), c.msgs);
    try tt.expectEqual(@as(u32, 2), c.files);
    try tt.expect(!c.cut);

    var long: std.ArrayListUnmanaged(u8) = .empty;
    defer long.deinit(tt.allocator);
    try long.appendSlice(tt.allocator, "{\"ok\":true,\"conv\":{\"id\":\"mabc1234\",\"title\":\"t\",\"msgs\":[{\"role\":\"user\",\"content\":\"");
    try long.appendNTimes(tt.allocator, 'x', CHAT_TEXT + 500);
    try long.appendSlice(tt.allocator, "\"},{\"role\":\"assistant\",\"content\":\"the last word\"}],\"files\":{}}}");
    try tt.expect(parseChat(tt.allocator, long.items, c));
    try tt.expect(c.cut);
    try tt.expectEqual(@as(usize, CHAT_TEXT), c.textStr().len);
    try tt.expect(std.mem.endsWith(u8, c.textStr(), "Veil:\nthe last word"));

    const before_len = c.text_len;
    try tt.expect(!parseChat(tt.allocator, "{\"ok\":false,\"err\":\"no such conversation\"}", c));
    try tt.expect(!parseChat(tt.allocator, "{\"ok\":true,\"conv\":{\"id\":\"BAD\"}}", c));
    try tt.expectEqual(before_len, c.text_len);
    var pb: [96]u8 = undefined;
    try tt.expectEqualStrings("{\"conv\":\"c6acfeae2\"}", pushBody(&pb, "c6acfeae2").?);
    try tt.expect(validConvId("mabc1234") and !validConvId("abc") and !validConvId("a" ** 25) and !validConvId("ABCDEF1"));
}

test "the mesh's nodes are read with how long ago each was seen; a bad id is left out; a job sent to one names it" {
    const gpa = std.testing.allocator;
    const body = "{\"ok\":true,\"now\":1790000100000,\"online_ms\":90000,\"max\":16,\"nodes\":[" ++
        "{\"id\":\"desk0000aaaa1111\",\"name\":\"Office\",\"kind\":\"desk\",\"os\":\"windows\",\"version\":\"1.2.3\",\"runs\":true,\"browser\":false,\"garrett\":true,\"mcp\":[\"files\",\"git\"],\"first\":1,\"seen\":1790000099000,\"online\":true,\"waiting\":0}," ++
        "{\"id\":\"../x\",\"name\":\"bad\",\"kind\":\"desk\"}," ++
        "{\"id\":\"tab00000cccc3333\",\"name\":\"Laptop tab\",\"kind\":\"web\",\"browser\":true,\"seen\":1790000000000,\"online\":false,\"waiting\":2}]}";
    var rows: [MAX_NODES]Node = undefined;
    const n = parseNodes(gpa, body, &rows).?;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("Office", rows[0].nameStr());
    try std.testing.expectEqualStrings("files git", rows[0].mcpStr());
    try std.testing.expect(rows[0].runs and rows[0].garrett and rows[0].online and rows[0].ago_s == 1);
    try std.testing.expectEqualStrings("web", rows[1].kindStr());
    try std.testing.expect(rows[1].browser and !rows[1].runs and !rows[1].online and rows[1].waiting == 2 and rows[1].ago_s == 100);
    try std.testing.expect(parseNodes(gpa, "{\"ok\":false,\"err\":\"x\"}", &rows) == null);

    var st: Status = .{};
    try std.testing.expect(parseStatus(gpa, "{\"ok\":true,\"connected\":true,\"reachable\":true,\"local\":true,\"node\":\"desk0000aaaa1111\",\"name\":\"Office\",\"url\":\"https://veil-web.acme.workers.dev\",\"err\":\"\",\"default_model\":\"@cf/x/y\",\"harness\":{\"version\":\"9\"}}", &st));
    try std.testing.expectEqualStrings("desk0000aaaa1111", st.nodeStr());

    var bb: [200]u8 = undefined;
    try std.testing.expectEqualStrings("{\"task\":\"count the files\",\"node\":\"tab00000cccc3333\"}", sendBody(&bb, "count the files", "tab00000cccc3333").?);
    try std.testing.expect(sendBody(&bb, "x", "../x") == null);
}
