//! tots.zig — the desk's picture of the user's TOTS (autonomous goal loops in their Cloudflare account; the
//! server side is src/config/cf_tot.zig, the runtime cloud/tot.js).
//!
//! Pure data and parsing: the roster rows, the event tail and the shared scratchpad as fixed-size values the
//! Store can hold under its one lock, the readers that fill them from the server's JSON, and the writer for a
//! deployment's request body. The poller calls the readers; main.zig draws the rows. No I/O here.
//!
//! A tot's events are kept as Ev: the colour key the swarm console uses (`kind`), the event's own kind (`label`),
//! the goal iteration it belongs to (`round`), a one-line `brief` the console shows, whether it went well (`ok`),
//! and its whole text with its line breaks, shown when the row is opened. A text longer than the tab keeps ends
//! in "..."; the tot's local folder (events.log) has every event whole.

const std = @import("std");

pub const MAX_TOTS = 3; // the account limit; the server and the runtime enforce it, the tab only draws to it
pub const MAX_PAD = 12; // newest scratchpad entries shown
pub const NAME_MAX = 24;
pub const EV_TEXT = 2200; // characters of an event the tab keeps: a tool row (args + result) whole
pub const PAD_TEXT = 600; // characters of a scratchpad entry the tab keeps

/// One event of the selected tot, as the console draws it.
pub const Ev = struct {
    seq: u64 = 0,
    round: i64 = -1,
    kind: [12]u8 = [_]u8{0} ** 12, // the colour key (kindColor)
    kind_len: u8 = 0,
    label: [12]u8 = [_]u8{0} ** 12, // the event's own kind: pick, act, verdict, lesson...
    label_len: u8 = 0,
    text: [EV_TEXT]u8 = [_]u8{0} ** EV_TEXT,
    text_len: u16 = 0,
    brief: [200]u8 = [_]u8{0} ** 200, // the one line the console shows for this event
    brief_len: u8 = 0,
    ok: bool = true, // false: it went wrong (an error, a failed tool call); the console marks the row

    pub fn briefStr(e: *const Ev) []const u8 {
        return e.brief[0..e.brief_len];
    }
    /// Whether opening the row shows more than its brief does.
    pub fn hasMore(e: *const Ev) bool {
        return e.text_len > e.brief_len or std.mem.indexOfScalar(u8, e.textStr(), '\n') != null;
    }
    pub fn kindStr(e: *const Ev) []const u8 {
        return e.kind[0..e.kind_len];
    }
    pub fn labelStr(e: *const Ev) []const u8 {
        return e.label[0..e.label_len];
    }
    pub fn textStr(e: *const Ev) []const u8 {
        return e.text[0..e.text_len];
    }
};

pub const Row = struct {
    name: [NAME_MAX]u8 = [_]u8{0} ** NAME_MAX,
    name_len: u8 = 0,
    state: [12]u8 = [_]u8{0} ** 12, // working / roaming / resting / paused / unreachable
    state_len: u8 = 0,
    model: [96]u8 = [_]u8{0} ** 96,
    model_len: u8 = 0,
    goal: [240]u8 = [_]u8{0} ** 240,
    goal_len: u8 = 0,
    goal_status: [12]u8 = [_]u8{0} ** 12, // active / achieved / plateau / budget / stopped
    goal_status_len: u8 = 0,
    iteration: u32 = 0,
    improved: u32 = 0,
    budget: u32 = 0, // 0 = no limit
    forever: bool = false,
    minds: u32 = 0,
    size: u32 = 0,
    pace_s: u32 = 0,
    calls_today: u32 = 0,
    daily_calls: u32 = 0,
    queue: u32 = 0,
    lessons: u32 = 0,
    local: bool = false, // may queue jobs for the veil on the owner's machine
    paused: bool = false,
    folder: [160]u8 = [_]u8{0} ** 160, // its local folder, relative to the data dir ("" until the server names one)
    folder_len: u8 = 0,

    pub fn folderStr(r: *const Row) []const u8 {
        return r.folder[0..r.folder_len];
    }
    pub fn nameStr(r: *const Row) []const u8 {
        return r.name[0..r.name_len];
    }
    pub fn stateStr(r: *const Row) []const u8 {
        return r.state[0..r.state_len];
    }
    pub fn modelStr(r: *const Row) []const u8 {
        return r.model[0..r.model_len];
    }
    pub fn goalStr(r: *const Row) []const u8 {
        return r.goal[0..r.goal_len];
    }
    pub fn goalStatusStr(r: *const Row) []const u8 {
        return r.goal_status[0..r.goal_status_len];
    }
};

pub const PadRow = struct {
    from: [NAME_MAX + 8]u8 = [_]u8{0} ** (NAME_MAX + 8), // "Gary/m2"
    from_len: u8 = 0,
    text: [PAD_TEXT]u8 = [_]u8{0} ** PAD_TEXT,
    text_len: u16 = 0,

    pub fn fromStr(r: *const PadRow) []const u8 {
        return r.from[0..r.from_len];
    }
    pub fn textStr(r: *const PadRow) []const u8 {
        return r.text[0..r.text_len];
    }
};

/// GET /api/v1/tots, reduced.
pub const Roster = struct {
    connected: bool = false, // logged in with Cloudflare
    deployed: bool = false, // the runtime is in the account
    reachable: bool = false, // and it answered
    current: bool = true, // it runs this build's tot.js
    python: bool = false, // the tots can run Python (and keep skills)
    browser: bool = false, // the tots can drive a browser
    neuron: bool = false, // the tots have neuron-db: recall by meaning, stances, a mood
    note: [200]u8 = [_]u8{0} ** 200, // why one of those is missing, in Cloudflare's words
    note_len: u8 = 0,
    n: usize = 0,
    rows: [MAX_TOTS]Row = [_]Row{.{}} ** MAX_TOTS,
    err: [200]u8 = [_]u8{0} ** 200, // the last deployment error, in the server's words
    err_len: u8 = 0,

    pub fn errStr(r: *const Roster) []const u8 {
        return r.err[0..r.err_len];
    }
    pub fn noteStr(r: *const Roster) []const u8 {
        return r.note[0..r.note_len];
    }
};

/// Copy `src` into a fixed field as ONE line: line breaks and tabs become spaces, the cut lands on a UTF-8
/// boundary. Returns the length kept.
fn put(dst: []u8, src: []const u8) usize {
    var n = @min(src.len, dst.len);
    while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
    for (src[0..n], 0..) |c, i| dst[i] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
    return n;
}

/// Copy `src` into a fixed field KEEPING its line breaks (the tab wraps them): CRs dropped, tabs become spaces, the
/// cut lands on a UTF-8 boundary and a cut text ends in "...". Returns the length kept.
fn putText(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    var cut = false;
    for (src) |c| {
        if (c == '\r') continue;
        if (n == dst.len) {
            cut = true;
            break;
        }
        dst[n] = if (c == '\t') ' ' else c;
        n += 1;
    }
    if (!cut) return n;
    n = dst.len - 3;
    while (n > 0 and (dst[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[n .. n + 3], "...");
    return n + 3;
}

fn u32of(v: i64) u32 {
    return @intCast(std.math.clamp(v, 0, std.math.maxInt(u32)));
}

const JGoal = struct { text: []const u8 = "", status: []const u8 = "", iteration: i64 = 0, improved: i64 = 0, budget: i64 = 0, forever: bool = false };
const JTot = struct {
    name: []const u8 = "",
    state: []const u8 = "",
    model: []const u8 = "",
    minds: i64 = 0,
    size: i64 = 0,
    pace_s: i64 = 0,
    calls_today: i64 = 0,
    daily_calls: i64 = 0,
    queue: i64 = 0,
    lessons: i64 = 0,
    local: bool = false,
    paused: bool = false,
    folder: []const u8 = "",
    goal: ?JGoal = null,
};
const JRoster = struct { ok: bool = false, connected: bool = false, deployed: bool = false, reachable: bool = false, current: bool = true, python: bool = false, browser: bool = false, neuron: bool = false, tools_note: []const u8 = "", last_error: []const u8 = "", tots: []const JTot = &.{} };

fn rowOf(h: JTot) Row {
    var r: Row = .{};
    r.name_len = @intCast(put(&r.name, h.name));
    r.state_len = @intCast(put(&r.state, h.state));
    r.model_len = @intCast(put(&r.model, h.model));
    if (h.goal) |g| {
        r.goal_len = @intCast(put(&r.goal, g.text));
        r.goal_status_len = @intCast(put(&r.goal_status, g.status));
        r.iteration = u32of(g.iteration);
        r.improved = u32of(g.improved);
        r.budget = u32of(g.budget);
        r.forever = g.forever;
    }
    r.minds = u32of(h.minds);
    r.size = u32of(h.size);
    r.pace_s = u32of(h.pace_s);
    r.calls_today = u32of(h.calls_today);
    r.daily_calls = u32of(h.daily_calls);
    r.queue = u32of(h.queue);
    r.lessons = u32of(h.lessons);
    r.local = h.local;
    r.paused = h.paused;
    if (h.folder.len <= r.folder.len and std.mem.indexOf(u8, h.folder, "..") == null) r.folder_len = @intCast(put(&r.folder, h.folder));
    return r;
}

/// Read a GET /api/v1/tots reply. False (and `out` untouched) for anything that is not that reply.
pub fn parseRoster(gpa: std.mem.Allocator, body: []const u8, out: *Roster) bool {
    const p = std.json.parseFromSlice(JRoster, gpa, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer p.deinit();
    if (!p.value.ok) return false;
    var r: Roster = .{ .connected = p.value.connected, .deployed = p.value.deployed, .reachable = p.value.reachable, .current = p.value.current, .python = p.value.python, .browser = p.value.browser, .neuron = p.value.neuron };
    r.err_len = @intCast(put(&r.err, p.value.last_error));
    r.note_len = @intCast(put(&r.note, p.value.tools_note));
    for (p.value.tots) |h| {
        if (r.n >= MAX_TOTS) break;
        if (h.name.len == 0 or h.name.len > NAME_MAX) continue;
        r.rows[r.n] = rowOf(h);
        r.n += 1;
    }
    out.* = r;
    return true;
}

/// A {ok, tot:{...}} reply (deploy, command, settings): the one row it carries, or null.
pub fn parseTot(gpa: std.mem.Allocator, body: []const u8) ?Row {
    const J = struct { ok: bool = false, tot: ?JTot = null };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    const h = p.value.tot orelse return null;
    if (!p.value.ok or h.name.len == 0 or h.name.len > NAME_MAX) return null;
    return rowOf(h);
}

/// The swarm console colours a row by its kind; a tot's kinds borrow the colours that mean the same thing there.
fn consoleKind(kind: []const u8, outcome: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "verdict")) return if (std.mem.eql(u8, outcome, "improved")) "score" else if (std.mem.eql(u8, outcome, "regressed")) "stopped" else "cost";
    if (std.mem.eql(u8, kind, "error")) return "stopped";
    if (std.mem.eql(u8, kind, "goal") or std.mem.eql(u8, kind, "say")) return "goal";
    if (std.mem.eql(u8, kind, "human") or std.mem.eql(u8, kind, "reply") or std.mem.eql(u8, kind, "inbox")) return "tick";
    if (std.mem.eql(u8, kind, "lesson")) return "cost";
    return kind;
}

/// Append the events of a GET /api/v1/tots/:name/events reply that are newer than `last_seq` to `evs[0..n]`,
/// dropping the oldest rows when the tail is full. Returns the new count; `last_seq` moves to the newest seen.
pub fn appendEvents(gpa: std.mem.Allocator, body: []const u8, evs: []Ev, n: usize, last_seq: *u64) usize {
    const JEv = struct { seq: u64 = 0, kind: []const u8 = "", text: []const u8 = "", brief: []const u8 = "", ok: ?bool = null, i: i64 = -1, outcome: []const u8 = "" };
    const J = struct { ok: bool = false, events: []const JEv = &.{} };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return n;
    defer p.deinit();
    if (!p.value.ok) return n;
    var count = @min(n, evs.len);
    for (p.value.events) |e| {
        if (e.seq <= last_seq.*) continue;
        last_seq.* = e.seq;
        if (count == evs.len) {
            std.mem.copyForwards(Ev, evs[0 .. evs.len - 1], evs[1..]);
            count -= 1;
        }
        var ev: Ev = .{ .seq = e.seq, .round = e.i };
        ev.kind_len = @intCast(put(&ev.kind, consoleKind(e.kind, e.outcome)));
        ev.label_len = @intCast(put(&ev.label, e.kind));
        ev.text_len = @intCast(putText(&ev.text, e.text));
        // an older runtime sends no brief: the text's first line stands in for it
        const first_line = std.mem.sliceTo(std.mem.trimStart(u8, e.text, " \r\n\t"), '\n');
        ev.brief_len = @intCast(put(&ev.brief, if (e.brief.len > 0) e.brief else first_line));
        ev.ok = e.ok orelse (!std.mem.eql(u8, e.kind, "error") and std.mem.indexOf(u8, first_line, "-> ERROR") == null and std.mem.indexOf(u8, first_line, "-> FAILED") == null);
        evs[count] = ev;
        count += 1;
    }
    return count;
}

/// The newest MAX_PAD entries of a GET /api/v1/tots/pad reply, oldest first. Returns how many.
pub fn parsePad(gpa: std.mem.Allocator, body: []const u8, out: *[MAX_PAD]PadRow) usize {
    const JE = struct { from: []const u8 = "", text: []const u8 = "" };
    const J = struct { ok: bool = false, entries: []const JE = &.{} };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch return 0;
    defer p.deinit();
    if (!p.value.ok) return 0;
    const es = p.value.entries;
    const from = if (es.len > MAX_PAD) es.len - MAX_PAD else 0;
    for (es[from..], 0..) |e, i| {
        out[i] = .{};
        out[i].from_len = @intCast(put(&out[i].from, e.from));
        out[i].text_len = @intCast(putText(&out[i].text, e.text));
    }
    return es.len - from;
}

/// The deploy form, as the server's POST /api/v1/tots reads it. Field names are the wire contract (CreateReq).
pub const Form = struct {
    name: []const u8 = "",
    goal: []const u8 = "",
    charter: []const u8 = "",
    model: []const u8 = "",
    pace_s: i64 = 600,
    size: i64 = 3,
    daily_calls: i64 = 400,
    budget: ?i64 = null,
    forever: bool = false,
    local: bool = false,
};

/// The deployment's JSON body in `buf`, or null when it does not fit.
pub fn deployBody(buf: []u8, f: Form) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(f, .{ .emit_null_optional_fields = false }, &w) catch return null;
    return w.buffered();
}

/// {"text": ...} for a command or a scratchpad entry.
pub fn textBody(buf: []u8, text: []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(.{ .text = text }, .{}, &w) catch return null;
    return w.buffered();
}

const tt = std.testing;

test "tots: the roster reads the server's reply into rows, one line per field, and refuses anything else" {
    const body =
        \\{"ok":true,"connected":true,"deployed":true,"reachable":true,"current":false,"max":3,"primary":"Gary","url":"https://veil-tots.acme.workers.dev","local":["Gary"],"python":true,"browser":false,"tools_note":"the browser is off: not enabled","last_error":"","tots":[{"name":"Gary","state":"working","model":"@cf/x/y","pace_s":600,"size":3,"minds":2,"daily_calls":400,"local":true,"charter":"","paused":false,"created":1,"goal":{"text":"map every\nharbour","status":"active","forever":true,"budget":0,"iteration":7,"improved":4,"flat":0,"best_num":-1,"best_den":0,"created":1},"queue":2,"lessons":5,"folder":"u1/_tots/Gary-20261001-120005","calls_today":41,"calls_total":900,"seq":88,"last_tick":1,"next_tick":2},{"name":"Ada","state":"unreachable"},{"name":"","state":"x"}]}
    ;
    var r: Roster = .{};
    try tt.expect(parseRoster(tt.allocator, body, &r));
    try tt.expect(r.connected and r.deployed and r.reachable and !r.current);
    try tt.expect(r.python and !r.browser);
    try tt.expectEqualStrings("the browser is off: not enabled", r.noteStr());
    try tt.expectEqual(@as(usize, 2), r.n); // the nameless row is dropped
    const g = &r.rows[0];
    try tt.expectEqualStrings("Gary", g.nameStr());
    try tt.expectEqualStrings("working", g.stateStr());
    try tt.expectEqualStrings("map every harbour", g.goalStr()); // one line
    try tt.expectEqualStrings("active", g.goalStatusStr());
    try tt.expect(g.forever and g.local and !g.paused);
    try tt.expectEqual(@as(u32, 7), g.iteration);
    try tt.expectEqual(@as(u32, 4), g.improved);
    try tt.expectEqual(@as(u32, 2), g.minds);
    try tt.expectEqual(@as(u32, 41), g.calls_today);
    try tt.expectEqual(@as(u32, 2), g.queue);
    try tt.expectEqualStrings("u1/_tots/Gary-20261001-120005", g.folderStr());
    try tt.expectEqualStrings("unreachable", r.rows[1].stateStr());
    try tt.expectEqual(@as(u8, 0), r.rows[1].goal_len);

    var keep: Roster = .{ .n = 1 };
    try tt.expect(!parseRoster(tt.allocator, "{\"ok\":false,\"err\":\"tots are admin-only for now\"}", &keep));
    try tt.expect(!parseRoster(tt.allocator, "<html>502</html>", &keep));
    try tt.expectEqual(@as(usize, 1), keep.n); // untouched
    try tt.expectEqualStrings("Gary", parseTot(tt.allocator, "{\"ok\":true,\"reply\":\"x\",\"tot\":{\"name\":\"Gary\",\"state\":\"paused\",\"paused\":true}}").?.nameStr());
    try tt.expect(parseTot(tt.allocator, "{\"ok\":false,\"err\":\"no such tot\"}") == null);
}

test "tots: the event tail appends only what is new, keeps the newest when full, and colours by meaning" {
    var evs: [4]Ev = undefined;
    var last: u64 = 0;
    const first =
        \\{"ok":true,"seq":3,"events":[{"seq":1,"t":1,"kind":"goal","text":"map every harbour"},{"seq":2,"t":2,"kind":"pick","text":"list the\nharbours","i":1},{"seq":3,"t":3,"kind":"verdict","text":"improved [3/10]","i":1,"outcome":"improved"}]}
    ;
    var n = appendEvents(tt.allocator, first, &evs, 0, &last);
    try tt.expectEqual(@as(usize, 3), n);
    try tt.expectEqual(@as(u64, 3), last);
    try tt.expectEqualStrings("list the\nharbours", evs[1].textStr()); // the tab wraps; the break is kept
    try tt.expectEqualStrings("pick", evs[1].labelStr());
    try tt.expectEqual(@as(i64, 1), evs[1].round);
    try tt.expectEqual(@as(i64, -1), evs[0].round);
    try tt.expectEqualStrings("score", evs[2].kindStr()); // an improving verdict reads green, like a swarm's score
    // the same reply again adds nothing; an overlapping one adds only the new rows and drops the oldest
    n = appendEvents(tt.allocator, first, &evs, n, &last);
    try tt.expectEqual(@as(usize, 3), n);
    const more =
        \\{"ok":true,"seq":6,"events":[{"seq":3,"kind":"verdict","text":"x"},{"seq":4,"kind":"error","text":"AI is down"},{"seq":5,"kind":"lesson","text":"rule"},{"seq":6,"kind":"say","text":"done"}]}
    ;
    n = appendEvents(tt.allocator, more, &evs, n, &last);
    try tt.expectEqual(@as(usize, 4), n);
    try tt.expectEqual(@as(u64, 6), last);
    try tt.expectEqual(@as(u64, 3), evs[0].seq);
    try tt.expectEqual(@as(u64, 6), evs[3].seq);
    try tt.expectEqualStrings("stopped", evs[1].kindStr()); // an error reads red
    try tt.expectEqual(@as(usize, 4), appendEvents(tt.allocator, "not json", &evs, n, &last));
}

test "tots: a deployment body round-trips through a real parser, whatever the goal text holds" {
    var b: [2048]u8 = undefined;
    const goal = "watch \"tides\"\n\\ and {\"local\":true} \x01 report";
    const body = deployBody(&b, .{ .name = "Ada", .goal = goal, .model = "@cf/x/y", .pace_s = 120, .size = 4, .forever = true }).?;
    const P = struct { name: []const u8, goal: []const u8, charter: []const u8, model: []const u8, pace_s: i64, size: i64, daily_calls: i64, budget: ?i64 = null, forever: bool, local: bool };
    const p = try std.json.parseFromSlice(P, tt.allocator, body, .{}); // strict: no field the server does not know
    defer p.deinit();
    try tt.expectEqualStrings(goal, p.value.goal);
    try tt.expect(!p.value.local); // text inside the goal cannot grant the owner's machine
    try tt.expect(p.value.forever and p.value.budget == null);
    try tt.expectEqual(@as(i64, 120), p.value.pace_s);
    var small: [16]u8 = undefined;
    try tt.expect(deployBody(&small, .{ .goal = goal }) == null);
    const tb = textBody(&b, "/goal a \"b\"").?;
    const q = try std.json.parseFromSlice(struct { text: []const u8 }, tt.allocator, tb, .{});
    defer q.deinit();
    try tt.expectEqualStrings("/goal a \"b\"", q.value.text);
}

test "tots: the scratchpad keeps the newest entries, oldest first" {
    var out: [MAX_PAD]PadRow = undefined;
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    defer jb.deinit(tt.allocator);
    try jb.appendSlice(tt.allocator, "{\"ok\":true,\"seq\":20,\"entries\":[");
    for (0..20) |i| try jb.print(tt.allocator, "{s}{{\"seq\":{d},\"t\":1,\"from\":\"Gary\",\"text\":\"entry {d}\"}}", .{ if (i > 0) "," else "", i + 1, i + 1 });
    try jb.appendSlice(tt.allocator, "]}");
    const n = parsePad(tt.allocator, jb.items, &out);
    try tt.expectEqual(@as(usize, MAX_PAD), n);
    try tt.expectEqualStrings("entry 9", out[0].textStr());
    try tt.expectEqualStrings("entry 20", out[MAX_PAD - 1].textStr());
    try tt.expectEqualStrings("Gary", out[0].fromStr());
    try tt.expectEqual(@as(usize, 0), parsePad(tt.allocator, "{\"ok\":false}", &out));
}

test "tots: a long event keeps its line breaks and ends in ... where the tab cuts it" {
    var b: [10]u8 = undefined;
    try tt.expectEqualStrings("ab\ncd ef", b[0..putText(&b, "ab\r\ncd\tef")]);
    try tt.expectEqualStrings("abcdefg...", b[0..putText(&b, "abcdefghijklmnop")]);
    try tt.expectEqualStrings("abcdef...", b[0..putText(&b, "abcdef\xc3\xa9\xc3\xa9\xc3\xa9")]); // never half a character
}

test "tots: an event's brief is the runtime's, or its first line from an older one; a failed row is marked" {
    var evs: [8]Ev = undefined;
    var last: u64 = 0;
    const body =
        \\{"ok":true,"seq":4,"events":[{"seq":1,"kind":"act","text":"web_fetch {\"url\":\"ftp://x\"} -> ERROR: an http(s) URL is needed","brief":"web_fetch ftp://x -> ERROR: an http(s) URL is needed","ok":false},{"seq":2,"kind":"act","text":"write_file {\"name\":\"a.md\"} -> saved a.md\nline two","brief":"write_file a.md -> saved a.md","ok":true},{"seq":3,"kind":"act","text":"run_python {} -> FAILED\nTraceback"},{"seq":4,"kind":"status","text":"rested"}]}
    ;
    const n = appendEvents(tt.allocator, body, &evs, 0, &last);
    try tt.expectEqual(@as(usize, 4), n);
    try tt.expectEqualStrings("web_fetch ftp://x -> ERROR: an http(s) URL is needed", evs[0].briefStr());
    try tt.expect(!evs[0].ok and evs[0].hasMore()); // the full row has the arguments as sent
    try tt.expect(evs[1].ok and evs[1].hasMore());
    try tt.expectEqualStrings("run_python {} -> FAILED", evs[2].briefStr()); // no brief sent: the first line
    try tt.expect(!evs[2].ok); // and a failure is still seen as one
    try tt.expectEqualStrings("rested", evs[3].briefStr());
    try tt.expect(evs[3].ok and !evs[3].hasMore()); // nothing more to open
}
