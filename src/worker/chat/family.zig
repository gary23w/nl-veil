//! family.zig — a conversation FAMILY read as one view: the primary chat and its sub-chats ("<root>__s1" ..
//! "<root>__s<MAX_BRANCHES>", see paths.zig), each member with its status, its title and its newest answer.
//!
//! READ-ONLY and pure. It is handed an allocator, io, the user's chat base ("{data}/u{uid}/_chat") and a liveness
//! probe, never a Store or a Mem, and it opens files for reading only: nothing here can write a conversation, a
//! graph or a memory scope. The test at the bottom holds that to the source.
//!
//! What it reads, all bounded:
//!   * messages.jsonl: ONE head+tail read (context.readHeadTail). Line 1 is the member's title (the first user
//!     message, by construction); the newest assistant line in the tail is its answer, the engine's plan rows passed
//!     over. Line 1 is also read to its end for the member's epoch (memberEpoch, up to EPOCH_LINE_MAX).
//!   * events.jsonl: its tail only (EVENTS_TAIL_BYTES), for the status.
//! A line counts only when it is whole (its '\n' is inside the window), starts with its writer's own prefix and
//! parses (std.json.validate). A torn line, or a window that starts mid-line, is skipped, never half-read.
//!
//! Status, decided in this order:
//!   running      the engine's turn table holds a slot for this member (asked FIRST, before any file is read)
//!   finished     the newest whole frame is the closing {"kind":"done"} and that turn wrote no error frame
//!   failed       the same, but that turn wrote an {"kind":"error"} frame. done closes EVERY exit path of a turn,
//!                so done alone cannot tell the two apart.
//!   interrupted  whole frames after the newest done, and no turn running: the turn never closed
//!   empty        neither file holds a byte (a dir POST /control made, a branch opened and never used)
//!   unknown      everything else: messages with no events (an R2 restore brings messages.jsonl back without
//!                events.jsonl), an events tail with no whole frame in it, or a file that could not be read
//! Known limits, not hidden:
//!   * the engine releases a turn's slot just before it writes done, so for that instant a member reads
//!     `interrupted`; the next read says `finished` or `failed`.
//!   * the newest turn's error frame is looked for inside the events tail only. An error followed by more than
//!     EVENTS_TAIL_BYTES of frames before its done reads as `finished`.
//!   * readers take no lock against the engine's writers.

const std = @import("std");
const http = @import("../../gateway/http.zig");
const cctx = @import("context.zig");
const cpaths = @import("paths.zig");
const net = @import("net.zig"); // Gary's 4tope: each member's net is built from its own store alone (Pool)

/// The conversation id ceiling: safeSeg's cap and the engine's turn-table slot width.
pub const ID_MAX: usize = 64;
/// The primary plus every sub-chat slot paths.zig allows.
pub const MEMBERS_MAX: usize = 1 + @as(usize, cpaths.MAX_BRANCHES);
/// How much of events.jsonl the status reads, from the end. A starting bound, not a measurement.
pub const EVENTS_TAIL_BYTES: usize = 64 * 1024;
/// A member's title, clipped as the conversation list clips its titles (service.listConvs) and as the family block
/// clips a branch's title.
pub const TITLE_MAX: usize = 80;
/// A member's newest answer, clipped as the family block clips the primary's latest progress.
pub const ANSWER_MAX: usize = 500;

/// The prefix every messages.jsonl line starts with (engine appendMsg).
const MSG_MARK = "{\"role\":\"";
/// The prefix every events.jsonl frame starts with (engine emitEvent / emitKV).
const EVENT_MARK = "{\"kind\":\"";

pub const Status = enum { running, finished, failed, interrupted, empty, unknown };

/// Is a member's turn running right now? The engine's isTurnLiveFor; tests hand in a stand-in.
pub const LiveFn = *const fn (io: std.Io, conv: []const u8, uid: u64) bool;

/// An opt-in flag's value read as on or off: on when set, non-empty, not starting with '0' and not "off". The rule
/// the engine reads NL_TOOL_MAP with, so every opt-in flag answers the same way. Unset is off.
pub fn flagOn(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len > 0 and v[0] != '0' and !std.ascii.eqlIgnoreCase(v, "off");
}

/// NL_FAMILY_NET: what of the other members' 4topes rides in this conversation's net. `on` carries their asks,
/// answers and tool results; `results` carries their tool results only, never a member's words.
pub const NetMode = enum { off, on, results };

/// NL_FAMILY_NET read as its three states: "results" (any case) is `results`, any other opt-in value is `on`, and
/// unset or off is `off`.
pub fn netMode(value: ?[]const u8) NetMode {
    const v = value orelse return .off;
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \r\n\t"), "results")) return .results;
    return if (flagOn(v)) .on else .off;
}

/// Every family flag, read from one environment. Each is default OFF and gates only its own piece, so the decision a
/// turn makes from a flag is this struct's field and can be tested with the flag unset.
pub const Flags = struct {
    /// NL_FAMILY_VIEW: GET /api/v1/chat/convs/:id/family answers (and the desk polls it)
    view: bool = false,
    /// NL_FAMILY_STATUS: the family block carries each member's status
    status: bool = false,
    /// NL_FAMILY_NET: the other members' 4topes ride in this conversation's net
    net: NetMode = .off,
    /// NL_FAMILY_MSG: the family ledger and the tools that message, ask or steer a member
    msg: bool = false,

    pub fn read(env: ?*const std.process.Environ.Map) Flags {
        const e = env orelse return .{};
        return .{
            .view = flagOn(e.get("NL_FAMILY_VIEW")),
            .status = flagOn(e.get("NL_FAMILY_STATUS")),
            .net = netMode(e.get("NL_FAMILY_NET")),
            .msg = flagOn(e.get("NL_FAMILY_MSG")),
        };
    }
};

/// The family root of `conv`: the primary itself, or a sub-chat's primary. null for an id no family can hold: an
/// empty or over-long id, or a branch of a branch (the turn gate refuses those).
pub fn familyRoot(conv: []const u8) ?[]const u8 {
    if (conv.len == 0 or conv.len > ID_MAX) return null;
    const root = cpaths.branchRoot(conv);
    if (cpaths.branchParts(root) != null) return null;
    return root;
}

/// Member `n`'s conversation id: `root` for n == 0, "<root>__s<n>" for 1..MAX_BRANCHES. null past MAX_BRANCHES, or
/// when the id would pass ID_MAX bytes. A built id is read back through paths.branchParts before it is returned, so
/// every id this hands out is one each other resolver parses the same way.
pub fn memberId(buf: *[ID_MAX]u8, root: []const u8, n: u8) ?[]const u8 {
    if (root.len == 0 or root.len > ID_MAX) return null;
    if (n == 0) {
        @memcpy(buf[0..root.len], root);
        return buf[0..root.len];
    }
    if (n > cpaths.MAX_BRANCHES) return null;
    const id = std.fmt.bufPrint(buf, "{s}__s{d}", .{ root, n }) catch return null; // past ID_MAX bytes
    const bp = cpaths.branchParts(id) orelse return null;
    if (bp.n != n or !std.mem.eql(u8, bp.parent, root)) return null;
    return id;
}

pub const Member = struct {
    /// the member's conversation id (the root, or "<root>__s<N>"). gpa-owned.
    conv: []u8,
    status: Status,
    /// the first user message, clipped to TITLE_MAX; "" when line 1 is not one. gpa-owned.
    title: []u8,
    /// the newest assistant message in the tail, clipped to ANSWER_MAX; "" when none. With the ledger on
    /// (answersFromLog) a sub-chat's is its newest done record's answer instead. gpa-owned.
    answer: []u8,
    /// its epoch (memberEpoch), null when it has no whole line 1
    epoch: ?[EPOCH_LEN]u8 = null,
};

pub const Family = struct {
    gpa: std.mem.Allocator,
    /// the primary's conversation id. gpa-owned.
    root: []u8,
    /// the primary first, then each sub-chat whose dir exists, in slot order
    members: std.ArrayListUnmanaged(Member) = .empty,

    pub fn deinit(f: *Family) void {
        for (f.members.items) |m| {
            f.gpa.free(m.conv);
            f.gpa.free(m.title);
            f.gpa.free(m.answer);
        }
        f.members.deinit(f.gpa);
        f.gpa.free(f.root);
    }
};

/// Read the family `conv` belongs to, under `chat_base` ("{data}/u{uid}/_chat"). null when `conv` has no family
/// root or the root's conversation dir does not exist. A sub-chat slot whose dir does not exist is not a member.
pub fn load(gpa: std.mem.Allocator, io: std.Io, chat_base: []const u8, uid: u64, conv: []const u8, live: LiveFn) !?Family {
    const root = familyRoot(conv) orelse return null;
    var fam: Family = .{ .gpa = gpa, .root = try gpa.dupe(u8, root) };
    errdefer fam.deinit();
    var n: u8 = 0;
    while (n <= cpaths.MAX_BRANCHES) : (n += 1) {
        var ib: [ID_MAX]u8 = undefined;
        const id = memberId(&ib, root, n) orelse continue;
        const dir = try std.fmt.allocPrint(gpa, "{s}/convs/{s}", .{ chat_base, id });
        defer gpa.free(dir);
        std.Io.Dir.cwd().access(io, dir, .{}) catch {
            if (n == 0) {
                fam.deinit();
                return null;
            }
            continue;
        };
        try fam.members.ensureUnusedCapacity(gpa, 1);
        fam.members.appendAssumeCapacity(try readMember(gpa, io, dir, id, uid, live));
    }
    return fam;
}

/// One member, read from its conversation dir.
fn readMember(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, id: []const u8, uid: u64, live: LiveFn) !Member {
    // The turn table FIRST. Read after the files, a turn that closes in between would leave a tail with no done
    // and a table with no slot, and read as interrupted when it finished.
    const running = live(io, id, uid);

    const mpath = try std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{dir});
    defer gpa.free(mpath);
    const epath = try std.fmt.allocPrint(gpa, "{s}/events.jsonl", .{dir});
    defer gpa.free(epath);

    const head_buf = try gpa.alloc(u8, cctx.HEAD_READ_BYTES);
    defer gpa.free(head_buf);
    const tail_buf = try gpa.alloc(u8, cctx.HEAD_READ_BYTES);
    defer gpa.free(tail_buf);
    const msg_bytes = fileBytes(io, mpath);
    const ht: ?cctx.HeadTail = if ((msg_bytes orelse 0) > 0) cctx.readHeadTail(io, mpath, head_buf, tail_buf) else null;

    const title = try titleOf(gpa, if (ht) |h| h.head else "");
    errdefer gpa.free(title);
    const answer = try answerOf(gpa, if (ht) |h| h.tail else "");
    errdefer gpa.free(answer);

    const status: Status = if (running) .running else filesStatus(gpa, io, msg_bytes, epath);
    var eb: [EPOCH_LEN]u8 = undefined;
    const epoch: ?[EPOCH_LEN]u8 = if (memberEpoch(gpa, io, dir, &eb)) |e| e[0..EPOCH_LEN].* else null;
    const conv = try gpa.dupe(u8, id);
    return .{ .conv = conv, .status = status, .title = title, .answer = answer, .epoch = epoch };
}

/// A member's status from its files alone (no turn running): see the module doc.
fn filesStatus(gpa: std.mem.Allocator, io: std.Io, msg_bytes: ?u64, epath: []const u8) Status {
    const mb = msg_bytes orelse return .unknown;
    const eb = fileBytes(io, epath) orelse return .unknown;
    if (mb == 0 and eb == 0) return .empty;
    if (eb == 0) return .unknown; // messages with no events: an R2 restore, or events.jsonl lost
    const tail = readTail(gpa, io, epath, EVENTS_TAIL_BYTES) orelse return .unknown;
    defer gpa.free(tail);
    return eventsStatus(gpa, tail) orelse .unknown;
}

/// The status a member's turn ended with, read once its done frame is written and its slot released (the engine's
/// done record, NL_FAMILY_MSG).
pub fn doneStatus(gpa: std.mem.Allocator, io: std.Io, member_dir: []const u8) Status {
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{member_dir}) catch return .unknown;
    defer gpa.free(mpath);
    const epath = std.fmt.allocPrint(gpa, "{s}/events.jsonl", .{member_dir}) catch return .unknown;
    defer gpa.free(epath);
    return filesStatus(gpa, io, fileBytes(io, mpath), epath);
}

/// The status an events tail shows by itself, or null when it holds no whole frame. Pure.
pub fn eventsStatus(gpa: std.mem.Allocator, tail: []const u8) ?Status {
    var it = Lines{ .gpa = gpa, .window = tail, .mark = EVENT_MARK };
    var any = false;
    var err_in_turn = false;
    var after_done = false;
    var at_done: Status = .finished;
    while (it.next()) |line| {
        any = true;
        const kind = frameKind(line);
        if (std.mem.eql(u8, kind, "done")) {
            at_done = if (err_in_turn) .failed else .finished;
            err_in_turn = false;
            after_done = false;
        } else {
            if (std.mem.eql(u8, kind, "error")) err_in_turn = true;
            after_done = true;
        }
    }
    if (!any) return null;
    return if (after_done) .interrupted else at_done;
}

/// A frame's kind: the string after EVENT_MARK (the engine's kinds are bare words, never escaped).
fn frameKind(line: []const u8) []const u8 {
    const rest = line[EVENT_MARK.len..];
    const q = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..q];
}

const Msg = struct { role: []const u8 = "", content: []const u8 = "" };

/// Line 1's content, clipped to TITLE_MAX, when line 1 is a whole user message; "" otherwise (line 1 is the first
/// user message by construction, so anything else abstains). gpa-owned.
fn titleOf(gpa: std.mem.Allocator, head: []const u8) ![]u8 {
    const nl = std.mem.indexOfScalar(u8, head, '\n') orelse return gpa.dupe(u8, "");
    var it = Lines{ .gpa = gpa, .window = head[0 .. nl + 1], .mark = MSG_MARK };
    const line = it.next() orelse return gpa.dupe(u8, "");
    const p = std.json.parseFromSlice(Msg, gpa, line, .{ .ignore_unknown_fields = true }) catch return gpa.dupe(u8, "");
    defer p.deinit();
    if (!std.mem.eql(u8, p.value.role, "user")) return gpa.dupe(u8, "");
    return clipUtf8(gpa, p.value.content, TITLE_MAX);
}

/// The engine's own rows a member's answer is never taken from: the plan it shows before the work (engine
/// emitPlanMessage) and the note a finished plan closes on (engine emitPlanClosing). engine.zig's family test holds
/// both to the engine's source.
pub const PLAN_HEAD_NOTE = "Here's my plan:\n";
pub const PLAN_DONE_NOTE = "Plan complete — worked all ";

/// The newest assistant message with content among the whole lines of `tail`, clipped to ANSWER_MAX; "" when there
/// is none. The engine's plan rows (PLAN_HEAD_NOTE, PLAN_DONE_NOTE) are passed over. gpa-owned.
fn answerOf(gpa: std.mem.Allocator, tail: []const u8) ![]u8 {
    var it = Lines{ .gpa = gpa, .window = tail, .mark = MSG_MARK ++ "assistant\"" };
    var best: []u8 = try gpa.dupe(u8, "");
    errdefer gpa.free(best);
    while (it.next()) |line| {
        const p = std.json.parseFromSlice(Msg, gpa, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (p.value.content.len == 0) continue;
        if (std.mem.startsWith(u8, p.value.content, PLAN_HEAD_NOTE) or std.mem.startsWith(u8, p.value.content, PLAN_DONE_NOTE)) continue;
        const clipped = try clipUtf8(gpa, p.value.content, ANSWER_MAX);
        gpa.free(best);
        best = clipped;
    }
    return best;
}

/// The byte length of the file at `path`: 0 when it does not exist, null when it exists but cannot be stat'ed.
fn fileBytes(io: std.Io, path: []const u8) ?u64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |e| return switch (e) {
        error.FileNotFound => 0,
        else => null,
    };
    return st.size;
}

/// The last `max` bytes of the file at `path` (all of it when smaller), or null when it cannot be read. gpa-owned.
fn readTail(gpa: std.mem.Allocator, io: std.Io, path: []const u8, max: usize) ?[]u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const size: usize = std.math.cast(usize, f.length(io) catch return null) orelse return null;
    const want = @min(size, max);
    const buf = gpa.alloc(u8, want) catch return null;
    const got = f.readPositionalAll(io, buf, size - want) catch {
        gpa.free(buf);
        return null;
    };
    if (got == buf.len) return buf;
    return gpa.realloc(buf, got) catch {
        gpa.free(buf);
        return null;
    };
}

/// The whole lines of `window` that start with `mark` and parse as JSON. A line counts only when its '\n' is inside
/// the window, so a torn last line is skipped. A first line cut off by a window that starts mid-line cannot start
/// with the mark either: the writers' marks open a line and never occur unescaped inside one.
const Lines = struct {
    gpa: std.mem.Allocator,
    window: []const u8,
    mark: []const u8,
    at: usize = 0,

    fn next(it: *Lines) ?[]const u8 {
        while (std.mem.indexOfScalarPos(u8, it.window, it.at, '\n')) |nl| {
            const line = std.mem.trimEnd(u8, it.window[it.at..nl], "\r");
            it.at = nl + 1;
            if (!std.mem.startsWith(u8, line, it.mark)) continue;
            if (!(std.json.validate(it.gpa, line) catch false)) continue;
            return line;
        }
        return null;
    }
};

/// `s` cut to at most `max` bytes on a character boundary, with every byte that is not part of a valid UTF-8
/// sequence replaced by '?', so what jstr writes is always well-formed. gpa-owned.
fn clipUtf8(gpa: std.mem.Allocator, s: []const u8, max: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        const ok = n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n]);
        const w: usize = if (ok) n else 1;
        if (out.items.len + w > max) break;
        if (ok) try out.appendSlice(gpa, s[i .. i + n]) else try out.append(gpa, '?');
        i += w;
    }
    return out.toOwnedSlice(gpa);
}

/// The family as the wire carries it: flat scalars only, every string through http.jstr, and each member named by
/// its conversation id, never by a label ("main", "s2") a client would have to parse:
///   {"ok":true,"root":"<id>","members":[{"conv":"<id>","status":"<word>","title":"..","answer":".."},..]}
pub fn familyJson(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fam: *const Family) !void {
    return familyJsonLog(gpa, out, fam, null);
}

/// The ledger's newest records the route carries (NL_FAMILY_MSG). A starting bound, not a measurement.
pub const LOG_ROUTE_MAX: usize = 20;

/// The epochs of a loaded family's members, by slot.
pub fn epochsOf(fam: *const Family) Epochs {
    var ep: Epochs = @splat(null);
    for (fam.members.items) |m| {
        const slot: u8 = if (cpaths.branchParts(m.conv)) |bp| bp.n else 0;
        ep[slot] = m.epoch;
    }
    return ep;
}

/// With the ledger on: each sub-chat's answer is the one its newest current done record carries (the answer its turn
/// settled on, written by the engine), when that record has one; otherwise it stays the file's.
pub fn answersFromLog(gpa: std.mem.Allocator, fam: *Family, log: *const Log) !void {
    const ep = epochsOf(fam);
    for (fam.members.items) |*m| {
        if (cpaths.branchParts(m.conv) == null) continue;
        var i = log.recs.len;
        while (i > 0) {
            i -= 1;
            const r = &log.recs[i];
            if (!std.mem.eql(u8, r.kind, "done") or !std.mem.eql(u8, r.from, m.conv) or !recCurrent(r, &ep)) continue;
            if (r.text.len == 0) break;
            const a = try clipUtf8(gpa, r.text, ANSWER_MAX);
            gpa.free(m.answer);
            m.answer = a;
            break;
        }
    }
}

/// familyJson, and with a ledger (NL_FAMILY_MSG) its newest LOG_ROUTE_MAX current records (routeWanted) after the
/// members, oldest first, each a flat object:
/// `"log":[{"seq":N,"kind":"..","from":"<id>","to":"<id>","text":"..","re":M,"status":".."}]`.
pub fn familyJsonLog(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fam: *const Family, log: ?*const Log) !void {
    try familyJsonMembers(gpa, out, fam);
    if (log) |l| {
        try out.appendSlice(gpa, ",\"log\":[");
        const ep = epochsOf(fam);
        var from = l.recs.len;
        var n: usize = 0;
        while (from > 0 and n < LOG_ROUTE_MAX) {
            from -= 1;
            if (routeWanted(&l.recs[from], &ep)) n += 1;
        }
        var i: usize = 0;
        for (l.recs[from..]) |r| {
            if (!routeWanted(&r, &ep)) continue;
            defer i += 1;
            if (i > 0) try out.append(gpa, ',');
            try out.print(gpa, "{{\"seq\":{d},\"kind\":", .{r.seq});
            try http.jstr(gpa, out, r.kind);
            try out.appendSlice(gpa, ",\"from\":");
            try http.jstr(gpa, out, r.from);
            try out.appendSlice(gpa, ",\"to\":");
            try http.jstr(gpa, out, r.to);
            try out.appendSlice(gpa, ",\"text\":");
            try http.jstr(gpa, out, r.text);
            try out.print(gpa, ",\"re\":{d},\"status\":", .{r.re});
            try http.jstr(gpa, out, r.status);
            try out.append(gpa, '}');
        }
        try out.append(gpa, ']');
    }
    try out.append(gpa, '}');
}

fn familyJsonMembers(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fam: *const Family) !void {
    try out.appendSlice(gpa, "{\"ok\":true,\"root\":");
    try http.jstr(gpa, out, fam.root);
    try out.appendSlice(gpa, ",\"members\":[");
    for (fam.members.items, 0..) |m, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"conv\":");
        try http.jstr(gpa, out, m.conv);
        try out.appendSlice(gpa, ",\"status\":");
        try http.jstr(gpa, out, @tagName(m.status));
        try out.appendSlice(gpa, ",\"title\":");
        try http.jstr(gpa, out, m.title);
        try out.appendSlice(gpa, ",\"answer\":");
        try http.jstr(gpa, out, m.answer);
        try out.append(gpa, '}');
    }
    try out.append(gpa, ']');
}

// ---- THE FAMILY IN A MEMBER'S NET (NL_FAMILY_NET) --------------------------------------------------------------
// Each OTHER member's 4tope is built from that member's own store alone (its own graph.jsonl, its own net.Graph), so
// its frontier, thread, rounds, call ids and supersession never mix with this conversation's. A few of its nodes are
// taken as candidates and the graph is freed; the conversation's net then carries them in one capped, labelled section
// (store.zig assemble, through Store.family). A carried line names its node by a QUALIFIED id, `s2.n17@1a2b3c4d`: the
// member's slot (`main` is the primary), the node's `_n` in that member's store, and the member's EPOCH.

/// What introduces the family section, inside the same system message as the conversation's own net.
pub const FAMILY_HEAD = "FROM THIS CHAT'S FAMILY (Gary's 4tope of the OTHER conversations of this family, each built from that conversation's own store alone; every line is that member's work, not this conversation's, and recall_node with a line's id, as in s2.n17@1a2b3c4d, returns that node whole):\n";
/// How much of a member's graph.jsonl the pool reads, from the end. A starting bound, not a measurement.
pub const GRAPH_TAIL_BYTES: usize = 256 * 1024;
/// How often the pool re-reads its members during a turn. A starting value, not a measurement.
pub const REFRESH_MS: i64 = 15_000;
/// One carried line's text: the net's own excerpt length.
pub const LINE_TEXT_MAX: usize = net.EXCERPT_MAX;
/// A line's call head (`read_file {"path":..}`).
const LINE_HEAD_MAX: usize = 200;
/// Candidates kept per member: the critical chain, the ruled-out results, and the results a cue word can link.
const CHAIN_MAX: usize = 6;
const DEAD_MAX: usize = 3;
const LINK_MAX: usize = 24;
/// How much of a linkable result is kept to find a cue word in.
const LINK_TEXT_MAX: usize = 2048;
pub const EPOCH_LEN: usize = 8;

/// May a member's tool result ride in another conversation's net? The engine hands in its own store gate (memory
/// echoes, credential-shaped heads), so nothing is decided twice.
pub const KeepFn = *const fn (name: []const u8, head: []const u8) bool;

/// How far into messages.jsonl memberEpoch looks for line 1's end: well past the server's 16 MiB request body cap,
/// with room for the escaping a stored line adds. A line 1 longer than this gives no epoch.
const EPOCH_LINE_MAX: usize = 64 * 1024 * 1024;

/// A member's EPOCH: 8 hex digits of the hash of its messages.jsonl line 1, the first user message with its
/// second-resolution timestamp. Line 1 never changes over a conversation's life, and a slot deleted and minted again
/// starts with a new line 1, so a QID or a ledger record taken from a member before a delete and a re-mint is refused
/// afterwards instead of naming the new conversation. Line 1 is read in chunks to its '\n' (up to EPOCH_LINE_MAX) and
/// hashed as it is read, so a long first message has an epoch like any other. null when the member has no whole line 1.
pub fn memberEpoch(gpa: std.mem.Allocator, io: std.Io, member_dir: []const u8, out: *[EPOCH_LEN]u8) ?[]const u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{member_dir}) catch return null;
    defer gpa.free(path);
    const buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return null;
    defer gpa.free(buf);
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var h = std.hash.Wyhash.init(0);
    var at: usize = 0;
    var len: usize = 0; // bytes hashed: line 1 without its trailing '\r's
    var crs: usize = 0; // '\r's held back: they are part of the line only when more of it follows
    while (at < EPOCH_LINE_MAX) {
        const n = f.readPositionalAll(io, buf, at) catch return null;
        if (n == 0) return null; // no '\n' yet: line 1 is not whole
        const nl = std.mem.indexOfScalar(u8, buf[0..n], '\n');
        const seg = buf[0 .. nl orelse n];
        const body = std.mem.trimEnd(u8, seg, "\r");
        if (body.len > 0) {
            while (crs > 0) : (crs -= 1) h.update("\r");
            h.update(body);
            len += body.len;
        }
        crs += seg.len - body.len;
        if (nl != null) {
            if (len == 0) return null;
            const v: u32 = @truncate(h.final());
            return std.fmt.bufPrint(out, "{x:0>8}", .{v}) catch null;
        }
        at += n;
    }
    return null;
}

/// A member's slot by its label: "main" is 0, "s1".."s5" are 1..MAX_BRANCHES. null for anything else.
pub fn labelSlot(label: []const u8) ?u8 {
    if (std.mem.eql(u8, label, "main")) return 0;
    if (label.len != 2 or label[0] != 's') return null;
    if (label[1] < '1' or label[1] > '0' + cpaths.MAX_BRANCHES) return null;
    return label[1] - '0';
}

/// The label of slot `slot` ("main", "s1".."s5").
pub fn slotLabel(buf: *[4]u8, slot: u8) []const u8 {
    if (slot == 0) return "main";
    return std.fmt.bufPrint(buf, "s{d}", .{slot}) catch "";
}

/// A qualified node id, split: `s2.n17@1a2b3c4d` (the epoch may be missing, which recall refuses).
pub const Qid = struct { slot: u8, id: u64, epoch: []const u8 };

/// Read a QID; null for anything that is not one (a bare `n17` or `17` is the caller's own node, not a QID).
pub fn parseQid(s: []const u8) ?Qid {
    const t = std.mem.trim(u8, s, " ");
    const dot = std.mem.indexOfScalar(u8, t, '.') orelse return null;
    const slot = labelSlot(t[0..dot]) orelse return null;
    var rest = t[dot + 1 ..];
    if (rest.len < 2 or rest[0] != 'n') return null;
    rest = rest[1..];
    const at = std.mem.indexOfScalar(u8, rest, '@');
    const digits = if (at) |a| rest[0..a] else rest;
    const id = std.fmt.parseInt(u64, digits, 10) catch return null;
    if (id == 0) return null;
    return .{ .slot = slot, .id = id, .epoch = if (at) |a| rest[a + 1 ..] else "" };
}

/// What a family recall answered: the member's conv id and the node's stored line (both gpa-owned), or why not.
pub const Recalled = union(enum) {
    node: struct { conv: []u8, line: []u8 },
    refused: []const u8,

    pub fn deinit(r: Recalled, gpa: std.mem.Allocator) void {
        switch (r) {
            .node => |n| {
                gpa.free(n.conv);
                gpa.free(n.line);
            },
            .refused => {},
        }
    }
};

/// recall_node for ANOTHER member: node `id` of the member at `slot`, from the caller's own family only. The member dir
/// is built from the caller's own convs root (the parent of `conv_dir`) and the caller's family root, so no other
/// account's or family's store is expressible. The member's current epoch must equal `epoch`; the node is the LAST
/// whole, validated line of its graph.jsonl stamped `"_n":id`.
pub fn recallMember(gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8, slot: u8, id: u64, epoch: []const u8) Recalled {
    const cut = std.mem.lastIndexOfAny(u8, conv_dir, "/\\") orelse return .{ .refused = "the caller's conversation dir has no parent" };
    const convs_root = conv_dir[0..cut];
    const self_conv = conv_dir[cut + 1 ..];
    const root = familyRoot(self_conv) orelse return .{ .refused = "this conversation belongs to no family" };
    var ib: [ID_MAX]u8 = undefined;
    const mid = memberId(&ib, root, slot) orelse return .{ .refused = "that slot is not a member of this family" };
    if (std.mem.eql(u8, mid, self_conv)) return .{ .refused = "that is this conversation itself: pass the bare n<id>" };
    const mdir = std.fmt.allocPrint(gpa, "{s}/{s}", .{ convs_root, mid }) catch return .{ .refused = "out of memory" };
    defer gpa.free(mdir);
    std.Io.Dir.cwd().access(io, mdir, .{}) catch return .{ .refused = "no such member: that sub-chat does not exist" };
    if (epoch.len == 0) return .{ .refused = "pass the member's epoch with the id (the part after @, as the FAMILY lines show it)" };
    var eb: [EPOCH_LEN]u8 = undefined;
    const now = memberEpoch(gpa, io, mdir, &eb) orelse return .{ .refused = "that member has no first message, so no epoch to check the id against" };
    if (!std.mem.eql(u8, now, epoch)) return .{ .refused = "that member's epoch has changed: the slot was deleted and holds another conversation now, so the id names nothing of it" };
    const line = memberNode(gpa, io, mdir, id) orelse return .{ .refused = "no such node in that member's store" };
    const conv = gpa.dupe(u8, mid) catch {
        gpa.free(line);
        return .{ .refused = "out of memory" };
    };
    return .{ .node = .{ .conv = conv, .line = line } };
}

/// Node `id` of a member's store: the LAST whole, validated graph.jsonl line stamped `"_n":id`. gpa-owned, or null.
pub fn memberNode(gpa: std.mem.Allocator, io: std.Io, member_dir: []const u8, id: u64) ?[]u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/graph.jsonl", .{member_dir}) catch return null;
    defer gpa.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30)) catch return null;
    defer gpa.free(raw);
    var it = Lines{ .gpa = gpa, .window = raw, .mark = MSG_MARK };
    var best: ?[]const u8 = null;
    while (it.next()) |line| {
        if ((net.jsonUint(line, "_n") orelse 0) == id) best = line;
    }
    return gpa.dupe(u8, best orelse return null) catch null;
}

// ---- THE FAMILY LEDGER, READ (NL_FAMILY_MSG; famlog.zig is its one writer) -------------------------------------

/// The ledger's file, in the primary's conversation dir. famlog.zig takes its name from here.
pub const LOG_FILE = "family.jsonl";
const LOG_MARK = "{\"seq\":";
/// How much of the ledger's end a reader reads. A starting bound, not a measurement.
pub const LOG_TAIL_BYTES: usize = 64 * 1024;
/// One ledger line as a model reads it (an answer is worth more room than a tool excerpt). A starting bound.
const LEDGER_TEXT_MAX: usize = 600;

/// What introduces the ledger lines in a member's net.
pub const LEDGER_HEAD = "FAMILY LEDGER (what this family's other conversations sent this one, newest last; each line names its sender and is that sender's words, not this conversation's and not the user's):\n";

pub const LogRec = struct {
    seq: u64 = 0,
    ts: i64 = 0,
    kind: []const u8 = "",
    from: []const u8 = "",
    from_epoch: []const u8 = "",
    to: []const u8 = "",
    to_epoch: []const u8 = "",
    text: []const u8 = "",
    re: u64 = 0,
    status: []const u8 = "",
};

/// Each slot's current epoch (index = slot; null: no member there, or it has no whole line 1 yet).
pub const Epochs = [MEMBERS_MAX]?[EPOCH_LEN]u8;

/// The current epoch of every slot of the family `root`, its members under `convs_dir` ("{chat_base}/convs").
pub fn familyEpochs(gpa: std.mem.Allocator, io: std.Io, convs_dir: []const u8, root: []const u8) Epochs {
    var ep: Epochs = @splat(null);
    var n: u8 = 0;
    while (n <= cpaths.MAX_BRANCHES) : (n += 1) {
        var ib: [ID_MAX]u8 = undefined;
        const id = memberId(&ib, root, n) orelse continue;
        const dir = std.fmt.allocPrint(gpa, "{s}/{s}", .{ convs_dir, id }) catch continue;
        defer gpa.free(dir);
        var eb: [EPOCH_LEN]u8 = undefined;
        if (memberEpoch(gpa, io, dir, &eb)) |e| ep[n] = e[0..EPOCH_LEN].*;
    }
    return ep;
}

/// Is `r` about the family's sub-chats as they stand NOW? Every sub-chat it names, as sender or receiver, must still
/// hold the epoch the record was written with; a record naming a sub-chat that is gone, or one whose slot holds
/// another conversation since, is history. The primary is not checked: the ledger lives in its dir and goes with it.
/// An open record carries no sub-chat epoch (it is written before the new sub-chat has its first line), so it is
/// never current: it stays in the file for the record and reaches no reader.
pub fn recCurrent(r: *const LogRec, ep: *const Epochs) bool {
    for ([_][2][]const u8{ .{ r.from, r.from_epoch }, .{ r.to, r.to_epoch } }) |side| {
        const bp = cpaths.branchParts(side[0]) orelse continue;
        const cur = ep[bp.n] orelse return false;
        if (!std.mem.eql(u8, side[1], &cur)) return false;
    }
    return true;
}

pub const Log = struct {
    arena: std.heap.ArenaAllocator,
    recs: []LogRec = &.{},

    pub fn deinit(l: *Log) void {
        l.arena.deinit();
    }
};

/// The ledger's records within its last `max_bytes`, oldest first: whole, validated lines only. An empty log when the
/// family has no ledger.
pub fn readLog(gpa: std.mem.Allocator, io: std.Io, primary_dir: []const u8, max_bytes: usize) !Log {
    var log: Log = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer log.deinit();
    const a = log.arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/" ++ LOG_FILE, .{primary_dir});
    const tail = readTail(a, io, path, max_bytes) orelse return log;
    var list: std.ArrayListUnmanaged(LogRec) = .empty;
    var it = Lines{ .gpa = a, .window = tail, .mark = LOG_MARK };
    while (it.next()) |line| {
        const r = std.json.parseFromSliceLeaky(LogRec, a, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (r.seq == 0) continue;
        try list.append(a, r);
    }
    log.recs = list.items;
    return log;
}

/// Does record `i` of `l` go to `self` now? It must be addressed to `self`, be current (recCurrent), and be of a kind
/// its receiver acts on: a sub-chat gets the primary's steers and questions, the primary its sub-chats' results,
/// answers and the engine's done notes. A steer or a question is SPENT once a turn of `self` has ended after it (its
/// done record follows it), and a question also once `self` answered it, so neither is put to `self` again.
fn ledgerWanted(l: *const Log, i: usize, self: []const u8, ep: *const Epochs) bool {
    const r = &l.recs[i];
    if (!std.mem.eql(u8, r.to, self) or !recCurrent(r, ep)) return false;
    for ([_][]const u8{ "result", "answer", "done" }) |k| if (std.mem.eql(u8, r.kind, k)) return true;
    const ask = std.mem.eql(u8, r.kind, "question");
    if (!ask and !std.mem.eql(u8, r.kind, "steer")) return false;
    for (l.recs[i + 1 ..]) |*later| {
        if (!std.mem.eql(u8, later.from, self) or !recCurrent(later, ep)) continue;
        if (std.mem.eql(u8, later.kind, "done")) return false;
        if (ask and later.re == r.seq and std.mem.eql(u8, later.kind, "answer")) return false;
    }
    return true;
}

/// The route's view of the ledger: its current records (recCurrent), open records left out.
pub fn routeWanted(r: *const LogRec, ep: *const Epochs) bool {
    return !std.mem.eql(u8, r.kind, "open") and recCurrent(r, ep);
}

/// `- ledger #12 s2 done [finished]: ...`, `- ledger #9 s2 answers #7: ...`, `- ledger #5 main asks: ...`.
fn ledgerLine(gpa: std.mem.Allocator, line: *std.ArrayListUnmanaged(u8), r: *const LogRec) !void {
    var lb: [4]u8 = undefined;
    const from_slot: u8 = if (cpaths.branchParts(r.from)) |bp| bp.n else 0;
    try line.print(gpa, "- ledger #{d} {s} ", .{ r.seq, slotLabel(&lb, from_slot) });
    if (std.mem.eql(u8, r.kind, "done")) {
        try line.print(gpa, "done [{s}]", .{if (r.status.len > 0) r.status else "unknown"});
    } else if (std.mem.eql(u8, r.kind, "answer")) {
        try line.print(gpa, "answers #{d}", .{r.re});
    } else if (std.mem.eql(u8, r.kind, "question")) {
        try line.print(gpa, "asks (answer it with report_to_primary, re {d})", .{r.seq});
    } else if (std.mem.eql(u8, r.kind, "steer")) {
        try line.appendSlice(gpa, "steers");
    } else {
        try line.appendSlice(gpa, r.kind);
    }
    try line.appendSlice(gpa, ": ");
    const text = try clipUtf8(gpa, r.text, LEDGER_TEXT_MAX);
    defer gpa.free(text);
    // one line: the record's own newlines fold to spaces
    for (text) |c| try line.append(gpa, if (c == '\n' or c == '\r') ' ' else c);
    if (text.len < r.text.len) try line.appendSlice(gpa, "...");
    try line.append(gpa, '\n');
}

const CandKind = enum { answer, ask, chain, link, dead };
const Cand = struct { kind: CandKind, nid: u64, head: []const u8, text: []const u8 };

/// One other member, as the pool holds it: its candidates (in the member's arena) and what it was read at.
const PoolMember = struct {
    conv: []u8,
    slot: u8,
    epoch: [EPOCH_LEN]u8,
    /// graph.jsonl's size when read: a grown file is read again, a shrunk one means deleted and minted again
    size: u64,
    arena: std.heap.ArenaAllocator,
    cands: std.ArrayListUnmanaged(Cand) = .empty,

    fn deinit(m: *PoolMember, gpa: std.mem.Allocator) void {
        m.cands.deinit(gpa);
        m.arena.deinit();
        gpa.free(m.conv);
    }
};

/// The other members of a turn's family, each read into candidates from its own 4tope (NL_FAMILY_NET), and the
/// family ledger's records addressed to this conversation (NL_FAMILY_MSG). Loaded once per turn, refreshed at most
/// every REFRESH_MS, rendered into the net on every request. With `mode` off only the ledger is read.
pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    chat_base: []u8,
    self: []u8,
    root: []u8,
    mode: NetMode,
    keep: KeepFn,
    /// NL_FAMILY_MSG: the ledger rides too
    ledger: bool = false,
    log: ?Log = null,
    log_size: u64 = 0,
    /// every slot's epoch at the last scan (ledger on): which records are current, and whose
    epochs: Epochs = @splat(null),
    members: std.ArrayListUnmanaged(PoolMember) = .empty,
    /// slots dropped this turn (their store shrank, their epoch changed, or their dir went): never read again this turn
    gone: [MEMBERS_MAX]bool = @splat(false),
    refreshed_ms: i64 = 0,
    /// what the last render did, for the engine's trace and the plumbing measurement
    last_lines: usize = 0,
    last_bytes: usize = 0,
    last_skipped: usize = 0,
    last_ledger_lines: usize = 0,
    /// members read (and read again) so far
    loads: usize = 0,

    /// null when `conv` has no family root. `ledger` also reads the family ledger; `mode` off reads it alone.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, chat_base: []const u8, conv: []const u8, mode: NetMode, keep: KeepFn, now_ms: i64, ledger: bool) !?Pool {
        const root = familyRoot(conv) orelse return null;
        var p: Pool = .{ .gpa = gpa, .io = io, .chat_base = try gpa.dupe(u8, chat_base), .self = &.{}, .root = &.{}, .mode = mode, .keep = keep, .ledger = ledger };
        errdefer p.deinit();
        p.self = try gpa.dupe(u8, conv);
        p.root = try gpa.dupe(u8, root);
        p.scan();
        p.refreshed_ms = now_ms;
        return p;
    }

    pub fn deinit(p: *Pool) void {
        for (p.members.items) |*m| m.deinit(p.gpa);
        p.members.deinit(p.gpa);
        if (p.log) |*l| l.deinit();
        p.gpa.free(p.chat_base);
        if (p.self.len > 0) p.gpa.free(p.self);
        if (p.root.len > 0) p.gpa.free(p.root);
    }

    /// Read the members again when REFRESH_MS has passed since the last read.
    pub fn refresh(p: *Pool, now_ms: i64) void {
        if (now_ms - p.refreshed_ms < REFRESH_MS) return;
        p.refreshed_ms = now_ms;
        p.scan();
    }

    fn find(p: *const Pool, slot: u8) ?usize {
        for (p.members.items, 0..) |m, i| if (m.slot == slot) return i;
        return null;
    }

    fn drop(p: *Pool, i: usize) void {
        var m = p.members.orderedRemove(i);
        p.gone[m.slot] = true;
        m.deinit(p.gpa);
    }

    /// Every other member: a new dir is read, a grown store is read again, and a member whose store shrank, whose
    /// epoch changed or whose dir went is dropped for the rest of the turn.
    fn scan(p: *Pool) void {
        if (p.ledger) p.scanLog();
        if (p.mode == .off) return;
        var n: u8 = 0;
        while (n <= cpaths.MAX_BRANCHES) : (n += 1) {
            if (p.gone[n]) continue;
            var ib: [ID_MAX]u8 = undefined;
            const id = memberId(&ib, p.root, n) orelse continue;
            if (std.mem.eql(u8, id, p.self)) continue;
            const dir = std.fmt.allocPrint(p.gpa, "{s}/convs/{s}", .{ p.chat_base, id }) catch continue;
            defer p.gpa.free(dir);
            const have = p.find(n);
            std.Io.Dir.cwd().access(p.io, dir, .{}) catch {
                if (have) |i| p.drop(i);
                continue;
            };
            var eb: [EPOCH_LEN]u8 = undefined;
            const ep = memberEpoch(p.gpa, p.io, dir, &eb) orelse continue; // no first message yet: nothing to address
            const gpath = std.fmt.allocPrint(p.gpa, "{s}/graph.jsonl", .{dir}) catch continue;
            defer p.gpa.free(gpath);
            const size = fileBytes(p.io, gpath) orelse continue;
            if (have) |i| {
                const m = &p.members.items[i];
                if (size < m.size or !std.mem.eql(u8, &m.epoch, ep)) {
                    p.drop(i);
                    continue;
                }
                if (size == m.size) continue;
                const fresh = p.loadMember(id, n, ep, size, gpath) catch continue;
                m.deinit(p.gpa);
                m.* = fresh;
            } else {
                const fresh = p.loadMember(id, n, ep, size, gpath) catch continue;
                p.members.append(p.gpa, fresh) catch {
                    var f = fresh;
                    f.deinit(p.gpa);
                };
            }
        }
    }

    /// Every slot's epoch, and the ledger again when it changed size (it only grows; a family deleted and minted
    /// again starts a new one). The epochs are read on every scan: a sub-chat can be deleted and opened again without
    /// the ledger growing.
    fn scanLog(p: *Pool) void {
        if (std.fmt.allocPrint(p.gpa, "{s}/convs", .{p.chat_base})) |convs| {
            defer p.gpa.free(convs);
            p.epochs = familyEpochs(p.gpa, p.io, convs, p.root);
        } else |_| {}
        const path = std.fmt.allocPrint(p.gpa, "{s}/convs/{s}/" ++ LOG_FILE, .{ p.chat_base, p.root }) catch return;
        defer p.gpa.free(path);
        const size = fileBytes(p.io, path) orelse return;
        if (p.log != null and size == p.log_size) return;
        const dir = path[0 .. path.len - LOG_FILE.len - 1];
        const fresh = readLog(p.gpa, p.io, dir, LOG_TAIL_BYTES) catch return;
        if (p.log) |*l| l.deinit();
        p.log = fresh;
        p.log_size = size;
    }

    /// One member's candidates, from the bounded tail of its own graph.jsonl built into its own net.Graph.
    fn loadMember(p: *Pool, id: []const u8, slot: u8, epoch: []const u8, size: u64, gpath: []const u8) !PoolMember {
        const gpa = p.gpa;
        var m: PoolMember = .{ .conv = try gpa.dupe(u8, id), .slot = slot, .epoch = undefined, .size = size, .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer m.deinit(gpa);
        @memcpy(&m.epoch, epoch[0..EPOCH_LEN]);
        p.loads += 1;
        if (size == 0) return m;
        const tail = readTail(gpa, p.io, gpath, GRAPH_TAIL_BYTES) orelse return m;
        defer gpa.free(tail);
        var span: std.ArrayListUnmanaged(u8) = .empty;
        defer span.deinit(gpa);
        var it = Lines{ .gpa = gpa, .window = tail, .mark = MSG_MARK };
        while (it.next()) |line| {
            if (span.items.len > 0) try span.append(gpa, ',');
            try span.appendSlice(gpa, line);
        }
        if (span.items.len == 0) return m;
        var g = net.Graph.fromSpanWith(gpa, span.items, .{ .store = true }) catch return m;
        defer g.deinit();
        const a = m.arena.allocator();
        const nodes = g.nodes.items;
        const used = try gpa.alloc(bool, nodes.len);
        defer gpa.free(used);
        @memset(used, false);
        // the member's newest answer and newest ask (`on` only: `results` never carries a member's words)
        if (p.mode == .on) {
            inline for (.{ CandKind.answer, CandKind.ask }) |want| {
                var i = nodes.len;
                while (i > 0) {
                    i -= 1;
                    const nd = nodes[i];
                    if (!net.isDialog(nd) or nd.nid == 0 or nd.text.len == 0) continue;
                    const is_ask = nd.kind == .user;
                    if (is_ask != (want == .ask)) continue;
                    try m.cands.append(gpa, .{ .kind = want, .nid = nd.nid, .head = if (is_ask) "asked" else "answered", .text = try clipUtf8(a, nd.text, LINE_TEXT_MAX) });
                    used[i] = true;
                    break;
                }
            }
        }
        // what the member's own frontier rests on: its critical chain's live results
        const chain = g.criticalChain(gpa) catch &.{};
        defer if (chain.len > 0) gpa.free(chain);
        var nc: usize = 0;
        for (chain) |ci| {
            if (nc >= CHAIN_MAX) break;
            const nd = nodes[ci];
            if (!p.carriable(nd) or nd.dead) continue;
            try m.cands.append(gpa, .{ .kind = .chain, .nid = nd.nid, .head = try resultHead(a, nd), .text = try clipUtf8(a, nd.text, LINE_TEXT_MAX) });
            used[ci] = true;
            nc += 1;
        }
        // its newest ruled-out calls, then its newest other live results (linked by the cue at render time)
        var nd_dead: usize = 0;
        var nd_link: usize = 0;
        var i = nodes.len;
        while (i > 0) {
            i -= 1;
            const nd = nodes[i];
            if (used[i] or !p.carriable(nd)) continue;
            if (nd.dead) {
                if (nd_dead >= DEAD_MAX) continue;
                try m.cands.append(gpa, .{ .kind = .dead, .nid = nd.nid, .head = try resultHead(a, nd), .text = try clipUtf8(a, nd.text, LINE_TEXT_MAX) });
                nd_dead += 1;
            } else {
                if (nd_link >= LINK_MAX) continue;
                try m.cands.append(gpa, .{ .kind = .link, .nid = nd.nid, .head = try resultHead(a, nd), .text = try clipUtf8(a, nd.text, LINK_TEXT_MAX) });
                nd_link += 1;
            }
        }
        return m;
    }

    /// A result another conversation may see: a stored, live result with a tool name (a window-edge result whose call
    /// fell outside the tail has none) that the engine's gate keeps (no memory echo, no credential-shaped head).
    fn carriable(p: *const Pool, nd: net.Node) bool {
        if (nd.kind != .result or nd.nid == 0 or nd.name.len == 0 or nd.superseded) return false;
        return p.keep(nd.name, nd.text[0..@min(nd.text.len, 512)]);
    }

    /// The section: FAMILY_HEAD, then the members' lines ROUND-ROBIN (one line of each member in turn, so a later
    /// member is never starved by an earlier one's), each member's in its own order: its answer and ask, its chain, its
    /// results that share a distinctive word with `cue` (most shared first), its ruled-out calls. A line that does not
    /// fit under `cap` is skipped and counted; nothing is written when no line fits. Every byte is valid UTF-8.
    pub fn render(p: *Pool, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cue: []const u8, cap: usize) !void {
        p.last_lines = 0;
        p.last_bytes = 0;
        p.last_skipped = 0;
        p.last_ledger_lines = 0;
        const start = out.items.len;
        // THE LEDGER FIRST, up to half the cap: what was sent to this conversation is what it most needs to see
        var used: usize = 0;
        if (p.log) |*l| used = try p.renderLedger(gpa, out, l, cap / 2);
        if (p.members.items.len == 0 or cap <= used + FAMILY_HEAD.len) {
            p.last_bytes = out.items.len - start;
            return;
        }
        try p.renderMembers(gpa, out, cue, cap - used);
        p.last_bytes = out.items.len - start;
    }

    /// The newest ledger records that go to this conversation now (ledgerWanted) that fit `cap` (head included),
    /// oldest first. Returns the bytes written.
    fn renderLedger(p: *Pool, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), l: *const Log, cap: usize) !usize {
        if (cap <= LEDGER_HEAD.len) return 0;
        var lines: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (lines.items) |x| gpa.free(x);
            lines.deinit(gpa);
        }
        var room = cap - LEDGER_HEAD.len;
        var i = l.recs.len;
        while (i > 0) {
            i -= 1;
            if (!ledgerWanted(l, i, p.self, &p.epochs)) continue;
            var line: std.ArrayListUnmanaged(u8) = .empty;
            errdefer line.deinit(gpa);
            try ledgerLine(gpa, &line, &l.recs[i]);
            if (line.items.len > room) {
                line.deinit(gpa);
                p.last_skipped += 1;
                continue;
            }
            room -= line.items.len;
            // room in `lines` first: once toOwnedSlice has moved the line out, nothing may fail before it is held
            try lines.ensureUnusedCapacity(gpa, 1);
            lines.appendAssumeCapacity(try line.toOwnedSlice(gpa));
        }
        if (lines.items.len == 0) return 0;
        const before = out.items.len;
        try out.appendSlice(gpa, LEDGER_HEAD);
        var k = lines.items.len;
        while (k > 0) {
            k -= 1;
            try out.appendSlice(gpa, lines.items[k]);
        }
        p.last_ledger_lines = lines.items.len;
        return out.items.len - before;
    }

    /// The members' lines under FAMILY_HEAD (see render).
    fn renderMembers(p: *Pool, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cue: []const u8, cap: usize) !void {
        if (cap <= FAMILY_HEAD.len) return;
        var toks_buf: [32][]const u8 = undefined;
        const toks = toks_buf[0..net.distinctiveTokens(cue, &toks_buf)];
        // each member's queue, in its own order
        var queues: [MEMBERS_MAX]std.ArrayListUnmanaged(Pick) = @splat(.empty);
        defer for (&queues) |*q| q.deinit(gpa);
        for (p.members.items, 0..) |*m, mi| {
            if (mi >= MEMBERS_MAX) break;
            const q = &queues[mi];
            for (m.cands.items) |*c| if (c.kind == .answer or c.kind == .ask or c.kind == .chain) try q.append(gpa, .{ .c = c });
            const link_from = q.items.len;
            for (m.cands.items) |*c| if (c.kind == .link) {
                var score: usize = 0;
                var focus: usize = std.math.maxInt(usize);
                for (toks) |t| if (std.ascii.indexOfIgnoreCase(c.text, t) orelse std.ascii.indexOfIgnoreCase(c.head, t)) |at| {
                    score += 1;
                    if (std.ascii.indexOfIgnoreCase(c.text, t) != null) focus = @min(focus, at);
                };
                if (score > 0) try q.append(gpa, .{ .c = c, .score = score, .focus = focus });
            };
            std.mem.sort(Pick, q.items[link_from..], {}, struct {
                fn more(_: void, x: Pick, y: Pick) bool {
                    return x.score > y.score;
                }
            }.more);
            for (m.cands.items) |*c| if (c.kind == .dead) try q.append(gpa, .{ .c = c });
        }
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(gpa);
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(gpa);
        const room = cap - FAMILY_HEAD.len;
        var round: usize = 0;
        while (true) : (round += 1) {
            var any = false;
            for (p.members.items, 0..) |*m, mi| {
                if (mi >= MEMBERS_MAX or round >= queues[mi].items.len) continue;
                any = true;
                line.clearRetainingCapacity();
                try renderLine(gpa, &line, m, queues[mi].items[round]);
                if (body.items.len + line.items.len > room) {
                    p.last_skipped += 1;
                    continue;
                }
                try body.appendSlice(gpa, line.items);
                p.last_lines += 1;
            }
            if (!any) break;
        }
        if (p.last_lines == 0) return;
        try out.appendSlice(gpa, FAMILY_HEAD);
        try out.appendSlice(gpa, body.items);
    }
};

const Pick = struct { c: *const Cand, score: usize = 0, focus: usize = std.math.maxInt(usize) };

/// A result's call head, `name args`, clipped.
fn resultHead(a: std.mem.Allocator, nd: net.Node) ![]const u8 {
    const joined = if (nd.args.len > 0) try std.fmt.allocPrint(a, "{s} {s}", .{ nd.name, nd.args }) else nd.name;
    return clipUtf8(a, joined, LINE_HEAD_MAX);
}

/// `- s2.n17@1a2b3c4d read_file {"path":..}: text` (a ruled-out call says ` -> `, a dialog node `asked:`/`answered:`).
/// A cue-linked result whose matching word sits past the line's length shows the window around that word.
fn renderLine(gpa: std.mem.Allocator, line: *std.ArrayListUnmanaged(u8), m: *const PoolMember, pick: Pick) !void {
    var lb: [4]u8 = undefined;
    try line.print(gpa, "- {s}.n{d}@{s} {s}{s}", .{ slotLabel(&lb, m.slot), pick.c.nid, &m.epoch, pick.c.head, if (pick.c.kind == .dead) " -> " else ": " });
    var text = pick.c.text;
    var lead = false;
    if (pick.c.kind == .link and pick.focus != std.math.maxInt(usize) and pick.focus + 40 > LINE_TEXT_MAX) {
        var from = pick.focus -| (LINE_TEXT_MAX / 3);
        while (from < text.len and (text[from] & 0xC0) == 0x80) from += 1; // start on a character
        text = text[from..];
        lead = from > 0;
    }
    var end = @min(text.len, LINE_TEXT_MAX);
    while (end < text.len and end > 0 and (text[end] & 0xC0) == 0x80) end -= 1; // end on a character
    if (lead) try line.appendSlice(gpa, "...");
    try line.appendSlice(gpa, text[0..end]);
    if (end < text.len) try line.appendSlice(gpa, "...");
    try line.append(gpa, '\n');
}

// ---- tests ----

const tt = std.testing;

test "member ids are paths.zig's own: every slot parses back to its root and number, and nothing past the grammar is a member" {
    var b: [ID_MAX]u8 = undefined;
    try tt.expectEqualStrings("c42", memberId(&b, "c42", 0).?);
    var n: u8 = 1;
    while (n <= cpaths.MAX_BRANCHES) : (n += 1) {
        const id = memberId(&b, "c42", n).?;
        const bp = cpaths.branchParts(id).?;
        try tt.expectEqualStrings("c42", bp.parent);
        try tt.expectEqual(n, bp.n);
        try tt.expectEqualStrings("c42", cpaths.branchRoot(id));
        try tt.expectEqualStrings("c42", familyRoot(id).?);
        // the memory side reads the same family: the member's scope reroots to the primary's
        var sb: [80]u8 = undefined;
        try tt.expectEqualStrings("chat:c42", cpaths.scopeFamilyBase(try std.fmt.bufPrint(&sb, "chat:{s}", .{id})));
    }
    // one past the last slot is no member, and paths.zig agrees it is no branch
    try tt.expect(memberId(&b, "c42", cpaths.MAX_BRANCHES + 1) == null);
    var pb: [ID_MAX]u8 = undefined;
    try tt.expect(cpaths.branchParts(try std.fmt.bufPrint(&pb, "c42__s{d}", .{cpaths.MAX_BRANCHES + 1})) == null);
    try tt.expectEqual(@as(usize, 1) + cpaths.MAX_BRANCHES, MEMBERS_MAX);
    // the 64-byte ceiling: a 60-byte root's branch ids just fit, a 61-byte root's would not
    try tt.expectEqual(ID_MAX, memberId(&b, "a" ** 60, 1).?.len);
    try tt.expect(memberId(&b, "a" ** 61, 1) == null);
    try tt.expectEqualStrings("a" ** 61, memberId(&b, "a" ** 61, 0).?);
    try tt.expect(memberId(&b, "a" ** 65, 0) == null);
    try tt.expect(memberId(&b, "", 0) == null);
}

test "family roots: a sub-chat's primary, a primary itself, and no family for a branch of a branch" {
    try tt.expectEqualStrings("c42", familyRoot("c42").?);
    try tt.expectEqualStrings("c42", familyRoot("c42__s5").?);
    // out of range, so an ordinary conversation as paths.zig reads it, and so the root of its own family
    try tt.expect(cpaths.branchParts("c42__s9") == null);
    try tt.expectEqualStrings("c42__s9", familyRoot("c42__s9").?);
    // nested: paths.zig parses it (parent "a__s1"), the turn gate refuses it, and so does the family view
    try tt.expectEqualStrings("a__s1", cpaths.branchParts("a__s1__s2").?.parent);
    try tt.expect(familyRoot("a__s1__s2") == null);
    try tt.expect(familyRoot("") == null);
    try tt.expect(familyRoot("a" ** 65) == null);
}

test "an opt-in flag is off unless set to something that does not start with 0 and is not off: the NL_TOOL_MAP rule" {
    try tt.expect(!flagOn(null));
    for ([_][]const u8{ "", "0", "00", "0x", "off", "OFF", "Off" }) |v| try tt.expect(!flagOn(v));
    // the rule is the engine's, word for word, so "false" reads as on here as it does for NL_TOOL_MAP
    for ([_][]const u8{ "1", "on", "yes", "true", "2", "false" }) |v| try tt.expect(flagOn(v));
}

test "every family flag is off with nothing set, each reads only its own variable, and NL_FAMILY_NET has three states" {
    const gpa = tt.allocator;
    try tt.expectEqual(Flags{}, Flags.read(null));
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try tt.expectEqual(Flags{}, Flags.read(&env));
    try env.put("NL_FAMILY_STATUS", "1");
    try tt.expectEqual(Flags{ .status = true }, Flags.read(&env));
    try env.put("NL_FAMILY_STATUS", "0");
    try env.put("NL_FAMILY_VIEW", "on");
    try env.put("NL_FAMILY_MSG", "yes");
    try env.put("NL_FAMILY_NET", "Results");
    try tt.expectEqual(Flags{ .view = true, .msg = true, .net = .results }, Flags.read(&env));
    try tt.expectEqual(NetMode.off, netMode(null));
    for ([_][]const u8{ "", "0", "off" }) |v| try tt.expectEqual(NetMode.off, netMode(v));
    for ([_][]const u8{ "1", "on" }) |v| try tt.expectEqual(NetMode.on, netMode(v));
    for ([_][]const u8{ "results", "RESULTS", " results\n" }) |v| try tt.expectEqual(NetMode.results, netMode(v));
}

test "the events tail alone: done closes a turn, an error frame in that turn makes it failed, frames after done mean it never closed" {
    const gpa = tt.allocator;
    const D = "{\"kind\":\"done\"}\n";
    const E = "{\"kind\":\"error\",\"err\":\"provider said no\"}\n";
    const S = "{\"kind\":\"status\",\"text\":\"thinking\"}\n";
    const U = "{\"kind\":\"usage\",\"tokens_in\":1,\"tokens_out\":2,\"text\":\"1 tokens in · 2 out\"}\n";
    try tt.expectEqual(Status.finished, eventsStatus(gpa, S ++ U ++ D).?);
    try tt.expectEqual(Status.failed, eventsStatus(gpa, S ++ E ++ U ++ D).?);
    // an earlier turn's error does not follow the next turn, and a later turn's error is its own
    try tt.expectEqual(Status.finished, eventsStatus(gpa, S ++ E ++ D ++ S ++ U ++ D).?);
    try tt.expectEqual(Status.failed, eventsStatus(gpa, S ++ D ++ S ++ E ++ D).?);
    // a turn that opened after the last done and never closed, and a tail with no done in it at all
    try tt.expectEqual(Status.interrupted, eventsStatus(gpa, S ++ D ++ S).?);
    try tt.expectEqual(Status.interrupted, eventsStatus(gpa, S ++ U).?);
    // a torn last line (its '\n' not written yet) is no frame: the done before it decides
    try tt.expectEqual(Status.finished, eventsStatus(gpa, S ++ D ++ "{\"kind\":\"sta").?);
    // nor is a line that does not parse, or one that is not a frame
    try tt.expectEqual(Status.finished, eventsStatus(gpa, S ++ D ++ "{\"kind\":\"status\",\"text\":\"broken}\n").?);
    try tt.expectEqual(Status.finished, eventsStatus(gpa, S ++ D ++ "[1,2]\n").?);
    // a window that starts mid-line skips the cut line, whatever it held
    try tt.expectEqual(Status.finished, eventsStatus(gpa, E[3..] ++ U ++ D).?);
    // no whole frame at all
    try tt.expect(eventsStatus(gpa, "") == null);
    try tt.expect(eventsStatus(gpa, "{\"kind\":\"done\"}") == null);
    try tt.expect(eventsStatus(gpa, "not a frame\n") == null);
}

test "clipUtf8 never splits a character, and nothing that is not UTF-8 gets through" {
    const gpa = tt.allocator;
    const Case = struct { in: []const u8, max: usize, want: []const u8 };
    for ([_]Case{
        .{ .in = "h\xc3\xa9llo", .max = 2, .want = "h" }, // a two-byte character fits whole or not at all
        .{ .in = "h\xc3\xa9llo", .max = 3, .want = "h\xc3\xa9" },
        .{ .in = "abc", .max = 10, .want = "abc" },
        .{ .in = "a\xffb", .max = 10, .want = "a?b" }, // a stray byte
        .{ .in = "a\xc3", .max = 10, .want = "a?" }, // a sequence cut off at the end
        .{ .in = "\xed\xa0\x80z", .max = 10, .want = "???z" }, // an encoded surrogate is not UTF-8
        .{ .in = "\xe2\x82\xacuro", .max = 2, .want = "" },
    }) |c| {
        const got = try clipUtf8(gpa, c.in, c.max);
        defer gpa.free(got);
        try tt.expectEqualStrings(c.want, got);
        try tt.expect(std.unicode.utf8ValidateSlice(got));
    }
}

test "title and answer: line 1 only if it is a user message, the newest whole assistant line, clipped" {
    const gpa = tt.allocator;
    const t1 = try titleOf(gpa, "{\"role\":\"user\",\"content\":\"Map the harbour charts.\",\"kind\":\"user\",\"ts\":1}\n{\"role\":\"user\",\"content\":\"later\",\"kind\":\"user\",\"ts\":2}\n");
    defer gpa.free(t1);
    try tt.expectEqualStrings("Map the harbour charts.", t1);
    // line 1 is not the first user message: abstain, never reach for a later line
    const t2 = try titleOf(gpa, "{\"role\":\"assistant\",\"content\":\"hello\",\"kind\":\"veil\",\"ts\":1}\n{\"role\":\"user\",\"content\":\"later\",\"kind\":\"user\",\"ts\":2}\n");
    defer gpa.free(t2);
    try tt.expectEqualStrings("", t2);
    // a first line longer than the head read has no '\n' in the head: no title
    const t3 = try titleOf(gpa, "{\"role\":\"user\",\"content\":\"a very long pas");
    defer gpa.free(t3);
    try tt.expectEqualStrings("", t3);
    const long = "{\"role\":\"user\",\"content\":\"" ++ "x" ** 200 ++ "\",\"kind\":\"user\",\"ts\":1}\n";
    const t4 = try titleOf(gpa, long);
    defer gpa.free(t4);
    try tt.expectEqual(TITLE_MAX, t4.len);

    // the answer: the newest assistant line with content; a cut first line and a torn last line are not lines
    const tail = "nt\":\"cut off\",\"kind\":\"veil\",\"ts\":1}\n" ++
        "{\"role\":\"assistant\",\"content\":\"the older answer\",\"kind\":\"veil\",\"ts\":2}\n" ++
        "{\"role\":\"assistant\",\"content\":\"the newest answer\",\"kind\":\"veil\",\"ts\":3}\n" ++
        "{\"role\":\"assistant\",\"content\":\"\",\"kind\":\"veil\",\"ts\":4}\n" ++
        "{\"role\":\"user\",\"content\":\"thanks\",\"kind\":\"user\",\"ts\":5}\n" ++
        "{\"role\":\"assistant\",\"content\":\"half writ";
    const a1 = try answerOf(gpa, tail);
    defer gpa.free(a1);
    try tt.expectEqualStrings("the newest answer", a1);
    const a2 = try answerOf(gpa, "{\"role\":\"user\",\"content\":\"only a question\",\"kind\":\"user\",\"ts\":1}\n");
    defer gpa.free(a2);
    try tt.expectEqualStrings("", a2);
    const big = "{\"role\":\"assistant\",\"content\":\"" ++ "y" ** 900 ++ "\",\"kind\":\"veil\",\"ts\":1}\n";
    const a3 = try answerOf(gpa, big);
    defer gpa.free(a3);
    try tt.expectEqual(ANSWER_MAX, a3.len);
    // the engine's own plan rows are no answer: the plan shown before the work, the note a finished plan closes on
    const planned = "{\"role\":\"assistant\",\"content\":\"Here's my plan:\\n1. [ ] (code) chart it\",\"kind\":\"veil\",\"ts\":1}\n" ++
        "{\"role\":\"assistant\",\"content\":\"The chart is drawn.\",\"kind\":\"veil\",\"ts\":2}\n" ++
        "{\"role\":\"assistant\",\"content\":\"" ++ PLAN_DONE_NOTE ++ "1 subtasks.\",\"kind\":\"veil\",\"ts\":3}\n";
    const a4 = try answerOf(gpa, planned);
    defer gpa.free(a4);
    try tt.expectEqualStrings("The chart is drawn.", a4);
    const a5 = try answerOf(gpa, planned[0 .. std.mem.indexOfScalar(u8, planned, '\n').? + 1]);
    defer gpa.free(a5);
    try tt.expectEqualStrings("", a5);
}

fn liveS1For7(io: std.Io, conv: []const u8, uid: u64) bool {
    _ = io;
    return uid == 7 and std.mem.endsWith(u8, conv, "__s1");
}

fn putFile(io: std.Io, dir: []const u8, name: []const u8, data: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
    var pb: [256]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name }), .data = data });
}

test "load: each member's own status, title and answer, read from its own dir, and only the slots that exist" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const top = "zig-family-load-tmp";
    const base = top ++ "/u7/_chat";
    const cv = base ++ "/convs/";
    std.Io.Dir.cwd().deleteTree(io, top) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, top) catch {};

    const D = "{\"kind\":\"done\"}\n";
    const S = "{\"kind\":\"status\",\"text\":\"thinking\"}\n";
    const ask = struct {
        fn line(comptime text: []const u8) []const u8 {
            return "{\"role\":\"user\",\"content\":\"" ++ text ++ "\",\"kind\":\"user\",\"ts\":1}\n";
        }
        fn answer(comptime text: []const u8) []const u8 {
            return "{\"role\":\"assistant\",\"content\":\"" ++ text ++ "\",\"kind\":\"veil\",\"ts\":2}\n";
        }
    };
    // the primary finished; its newest answer sits past a messages file longer than one tail read
    try putFile(io, cv ++ "fam", "messages.jsonl", comptime (ask.line("Map the harbour charts.") ++ (ask.answer("filler") ** 300) ++ ask.answer("Charted the north quay.")));
    try putFile(io, cv ++ "fam", "events.jsonl", S ++ D);
    // s1 holds a slot in the turn table (the stand-in says so for uid 7)
    try putFile(io, cv ++ "fam__s1", "messages.jsonl", comptime (ask.line("Check the south quay depths.")));
    try putFile(io, cv ++ "fam__s1", "events.jsonl", S);
    // s2's turn wrote an error frame before its done
    try putFile(io, cv ++ "fam__s2", "messages.jsonl", comptime (ask.line("Sound the channel.") ++ ask.answer("first pass")));
    try putFile(io, cv ++ "fam__s2", "events.jsonl", S ++ "{\"kind\":\"error\",\"err\":\"provider said no\"}\n" ++ D);
    // s3 is the dir POST /control leaves: a control line, no messages, no events
    try putFile(io, cv ++ "fam__s3", "control.jsonl", "{\"op\":\"stop\"}\n");
    // s4 came back from an R2 restore: messages and no events
    try putFile(io, cv ++ "fam__s4", "messages.jsonl", comptime (ask.line("Restored branch.") ++ ask.answer("restored answer")));
    // s5's turn opened after its last done and never closed
    try putFile(io, cv ++ "fam__s5", "messages.jsonl", comptime (ask.line("Walk the breakwater.")));
    try putFile(io, cv ++ "fam__s5", "events.jsonl", S ++ D ++ S);
    // past the grammar, and a nested id: never members
    try putFile(io, cv ++ "fam__s6", "messages.jsonl", comptime (ask.line("not a branch")));
    try putFile(io, cv ++ "fam__s1__s2", "messages.jsonl", comptime (ask.line("nested")));

    const Want = struct { conv: []const u8, status: Status, title: []const u8, answer: []const u8 };
    const want = [_]Want{
        .{ .conv = "fam", .status = .finished, .title = "Map the harbour charts.", .answer = "Charted the north quay." },
        .{ .conv = "fam__s1", .status = .running, .title = "Check the south quay depths.", .answer = "" },
        .{ .conv = "fam__s2", .status = .failed, .title = "Sound the channel.", .answer = "first pass" },
        .{ .conv = "fam__s3", .status = .empty, .title = "", .answer = "" },
        .{ .conv = "fam__s4", .status = .unknown, .title = "Restored branch.", .answer = "restored answer" },
        .{ .conv = "fam__s5", .status = .interrupted, .title = "Walk the breakwater.", .answer = "" },
    };
    // asked from the primary or from any member, it is the same family
    for ([_][]const u8{ "fam", "fam__s3", "fam__s5" }) |asked| {
        var fam = (try load(gpa, io, base, 7, asked, liveS1For7)).?;
        defer fam.deinit();
        try tt.expectEqualStrings("fam", fam.root);
        try tt.expectEqual(want.len, fam.members.items.len);
        for (want, fam.members.items) |w, m| {
            errdefer std.debug.print("member {s}: {t} \"{s}\" \"{s}\"\n", .{ m.conv, m.status, m.title, m.answer });
            try tt.expectEqualStrings(w.conv, m.conv);
            try tt.expectEqual(w.status, m.status);
            try tt.expectEqualStrings(w.title, m.title);
            try tt.expectEqualStrings(w.answer, m.answer);
        }
    }
    // another account's turn table entry is not this one's: s1 reads from its files (a turn that never closed)
    {
        var fam = (try load(gpa, io, base, 8, "fam", liveS1For7)).?;
        defer fam.deinit();
        try tt.expectEqual(Status.interrupted, fam.members.items[1].status);
    }
    // no family: a nested id, a primary with no dir
    try tt.expect((try load(gpa, io, base, 7, "fam__s1__s2", liveS1For7)) == null);
    try tt.expect((try load(gpa, io, base, 7, "absent", liveS1For7)) == null);
    try tt.expect((try load(gpa, io, base, 7, "absent__s1", liveS1For7)) == null);
}

test "familyJson: flat scalars, every string escaped, members named by their conversation ids" {
    const gpa = tt.allocator;
    var fam: Family = .{ .gpa = gpa, .root = try gpa.dupe(u8, "c42") };
    defer fam.deinit();
    try fam.members.ensureTotalCapacity(gpa, 2);
    fam.members.appendAssumeCapacity(.{ .conv = try gpa.dupe(u8, "c42"), .status = .finished, .title = try gpa.dupe(u8, "say \"hi\"\n"), .answer = try gpa.dupe(u8, "back\\slash\ttab") });
    fam.members.appendAssumeCapacity(.{ .conv = try gpa.dupe(u8, "c42__s2"), .status = .running, .title = try gpa.dupe(u8, ""), .answer = try gpa.dupe(u8, "\x01") });
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try familyJson(gpa, &out, &fam);
    try tt.expectEqualStrings("{\"ok\":true,\"root\":\"c42\",\"members\":[" ++
        "{\"conv\":\"c42\",\"status\":\"finished\",\"title\":\"say \\\"hi\\\"\\n\",\"answer\":\"back\\\\slash\\ttab\"}," ++
        "{\"conv\":\"c42__s2\",\"status\":\"running\",\"title\":\"\",\"answer\":\"\\u0001\"}]}", out.items);
    const p = try std.json.parseFromSlice(std.json.Value, gpa, out.items, .{});
    defer p.deinit();
    try tt.expectEqual(@as(usize, 2), p.value.object.get("members").?.array.items.len);
}

test "qualified ids: a member, a node and an epoch; anything else is no QID" {
    const q = parseQid("s2.n17@1a2b3c4d").?;
    try tt.expectEqual(@as(u8, 2), q.slot);
    try tt.expectEqual(@as(u64, 17), q.id);
    try tt.expectEqualStrings("1a2b3c4d", q.epoch);
    try tt.expectEqual(@as(u8, 0), parseQid("main.n12@ffffffff").?.slot);
    try tt.expectEqualStrings("", parseQid("s1.n3").?.epoch); // parsed, and recall refuses it for the missing epoch
    for ([_][]const u8{ "n17", "17", "s2.17@x", "s6.n1@x", "s0.n1@x", "main.n0@x", "x2.n1@x", "s2.nx@y", "" }) |bad| {
        errdefer std.debug.print("read as a QID: {s}\n", .{bad});
        try tt.expect(parseQid(bad) == null);
    }
    var lb: [4]u8 = undefined;
    var n: u8 = 0;
    while (n <= cpaths.MAX_BRANCHES) : (n += 1) try tt.expectEqual(n, labelSlot(slotLabel(&lb, n)).?);
    try tt.expect(labelSlot("s6") == null);
    try tt.expect(labelSlot("Main") == null);
}

/// A member's graph.jsonl in the store's own stamped shape (store.zig stampInto), raw so the nested JSON reads plainly.
const S1_GRAPH =
    \\{"role":"user","content":"Read the alpha ledger.","_t":1,"_n":1,"_k":"ask"}
    \\{"role":"assistant","content":"Calling read_file.","tool_calls":[{"id":"c1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"ledger/alpha.md\"}"}}],"_t":1,"_n":2}
    \\{"role":"tool","tool_call_id":"c1","content":"alpha: zebracorn42 holds 1180","_t":1,"_n":3}
    \\{"role":"assistant","content":"Calling recall.","tool_calls":[{"id":"c2","type":"function","function":{"name":"recall","arguments":"{\"q\":\"alpha\"}"}}],"_t":1,"_n":4}
    \\{"role":"tool","tool_call_id":"c2","content":"recalled: a fact from another scope","_t":1,"_n":5}
    \\{"role":"assistant","content":"Calling read_file.","tool_calls":[{"id":"c3","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"keys.env\"}"}}],"_t":1,"_n":6}
    \\{"role":"tool","tool_call_id":"c3","content":"api_key=sk-not-a-real-key","_t":1,"_n":7}
    \\{"role":"assistant","content":"The alpha ledger shows zebracorn42 holding 1180.","_t":1,"_n":8}
    \\
;
const S2_GRAPH =
    \\{"role":"user","content":"Find the tide tables.","_t":1,"_n":1,"_k":"ask"}
    \\{"role":"assistant","content":"Calling read_file.","tool_calls":[{"id":"d1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"tides/missing.md\"}"}}],"_t":1,"_n":2}
    \\{"role":"tool","tool_call_id":"d1","content":"ERROR: no such file tides/missing.md","_t":1,"_n":3}
    \\{"role":"assistant","content":"Calling web_search.","tool_calls":[{"id":"d2","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"harbour tide tables\"}"}}],"_t":1,"_n":4}
    \\{"role":"tool","tool_call_id":"d2","content":"tide tables: high water 06:12, low water 12:31","_t":1,"_n":5}
    \\
;

fn testKeep(name: []const u8, head: []const u8) bool {
    return !std.mem.eql(u8, name, "recall") and std.mem.indexOf(u8, head, "api_key") == null;
}

fn putMember(io: std.Io, base: []const u8, id: []const u8, line1: []const u8, graph: []const u8) !void {
    var db: [160]u8 = undefined;
    const d = try std.fmt.bufPrint(&db, "{s}/convs/{s}", .{ base, id });
    try putFile(io, d, "messages.jsonl", line1);
    try putFile(io, d, "graph.jsonl", graph);
}

test "a member's epoch is its first line's, and recall reaches a member's node only by its own id at its own epoch" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const top = "zig-family-recall-tmp";
    const base = top ++ "/u7/_chat";
    std.Io.Dir.cwd().deleteTree(io, top) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, top) catch {};
    const L1 = "{\"role\":\"user\",\"content\":\"Read the alpha ledger.\",\"kind\":\"user\",\"ts\":100}\n";
    try putMember(io, base, "fam", "{\"role\":\"user\",\"content\":\"Map the harbour.\",\"kind\":\"user\",\"ts\":50}\n", "");
    // s1: the node stored twice (a later copy wins) and once more as a torn line that must not count
    try putMember(io, base, "fam__s1", L1, S1_GRAPH ++ "{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"alpha: the later copy\",\"_t\":1,\"_n\":3}\n" ++ "{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"torn\",\"_t\":1,\"_n\":3");
    var eb: [EPOCH_LEN]u8 = undefined;
    const ep = memberEpoch(gpa, io, base ++ "/convs/fam__s1", &eb).?;
    var want: [EPOCH_LEN]u8 = undefined;
    _ = try std.fmt.bufPrint(&want, "{x:0>8}", .{@as(u32, @truncate(std.hash.Wyhash.hash(0, L1[0 .. L1.len - 1])))});
    try tt.expectEqualStrings(&want, ep);
    var ep_copy: [EPOCH_LEN]u8 = undefined;
    @memcpy(&ep_copy, ep);

    const me = base ++ "/convs/fam";
    {
        const r = recallMember(gpa, io, me, 1, 3, &ep_copy);
        defer r.deinit(gpa);
        try tt.expectEqualStrings("fam__s1", r.node.conv);
        try tt.expect(std.mem.indexOf(u8, r.node.line, "the later copy") != null);
    }
    for ([_]struct { slot: u8, id: u64, epoch: []const u8, why: []const u8 }{
        .{ .slot = 0, .id = 1, .epoch = &ep_copy, .why = "this conversation itself" },
        .{ .slot = 4, .id = 1, .epoch = &ep_copy, .why = "does not exist" },
        .{ .slot = 1, .id = 3, .epoch = "", .why = "epoch" },
        .{ .slot = 1, .id = 3, .epoch = "deadbeef", .why = "epoch has changed" },
        .{ .slot = 1, .id = 99, .epoch = &ep_copy, .why = "no such node" },
    }) |c| {
        const r = recallMember(gpa, io, me, c.slot, c.id, c.epoch);
        defer r.deinit(gpa);
        errdefer std.debug.print("slot {d} id {d} epoch {s}: {any}\n", .{ c.slot, c.id, c.epoch, r });
        try tt.expect(std.mem.indexOf(u8, r.refused, c.why) != null);
    }
    // the slot deleted and minted again: same slot, same node id, a new first line, so the old QID is refused
    try putMember(io, base, "fam__s1", "{\"role\":\"user\",\"content\":\"Read the alpha ledger.\",\"kind\":\"user\",\"ts\":900}\n", S1_GRAPH);
    {
        const r = recallMember(gpa, io, me, 1, 3, &ep_copy);
        defer r.deinit(gpa);
        try tt.expect(std.mem.indexOf(u8, r.refused, "epoch has changed") != null);
    }
    // a member with no whole first line has no epoch
    try putFile(io, base ++ "/convs/fam__s2", "messages.jsonl", "{\"role\":\"user\",\"content\":\"half");
    try tt.expect(memberEpoch(gpa, io, base ++ "/convs/fam__s2", &eb) == null);
}

test "the family pool: each member's own 4tope, round-robin under the cap, memory echoes and credentials kept out, every line a resolvable QID" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const top = "zig-family-pool-tmp";
    const base = top ++ "/u7/_chat";
    std.Io.Dir.cwd().deleteTree(io, top) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, top) catch {};
    try putMember(io, base, "fam", "{\"role\":\"user\",\"content\":\"Map the harbour.\",\"kind\":\"user\",\"ts\":50}\n", "");
    try putMember(io, base, "fam__s1", "{\"role\":\"user\",\"content\":\"Read the alpha ledger.\",\"kind\":\"user\",\"ts\":100}\n", S1_GRAPH);
    try putMember(io, base, "fam__s2", "{\"role\":\"user\",\"content\":\"Find the tide tables.\",\"kind\":\"user\",\"ts\":200}\n", S2_GRAPH);
    // s4 holds only an ask so far; its store will shrink under the same first line
    try putMember(io, base, "fam__s4", "{\"role\":\"user\",\"content\":\"Chart the reef.\",\"kind\":\"user\",\"ts\":400}\n", "{\"role\":\"user\",\"content\":\"Chart the reef.\",\"_t\":1,\"_n\":1,\"_k\":\"ask\"}\n");

    var pool = (try Pool.init(gpa, io, base, "fam", .on, testKeep, 0, false)).?;
    defer pool.deinit();
    try tt.expectEqual(@as(usize, 3), pool.members.items.len);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try pool.render(gpa, &out, "check the tide tables against zebracorn42", 4096);
    const sec = out.items;
    errdefer std.debug.print("\n--- section ---\n{s}\n---\n", .{sec});
    try tt.expect(std.mem.startsWith(u8, sec, FAMILY_HEAD));
    try tt.expect(std.unicode.utf8ValidateSlice(sec));
    var e1: [EPOCH_LEN]u8 = undefined;
    var e2: [EPOCH_LEN]u8 = undefined;
    const ep1 = memberEpoch(gpa, io, base ++ "/convs/fam__s1", &e1).?;
    const ep2 = memberEpoch(gpa, io, base ++ "/convs/fam__s2", &e2).?;
    var lb: [128]u8 = undefined;
    // s1's answer and its read, s2's linked result and its ruled-out call, each under its own member's id and epoch
    try tt.expect(std.mem.indexOf(u8, sec, try std.fmt.bufPrint(&lb, "- s1.n8@{s} answered: The alpha ledger shows zebracorn42 holding 1180.\n", .{ep1})) != null);
    try tt.expect(std.mem.indexOf(u8, sec, try std.fmt.bufPrint(&lb, "- s1.n3@{s} read_file {{\"path\":\"ledger/alpha.md\"}}: alpha: zebracorn42 holds 1180\n", .{ep1})) != null);
    try tt.expect(std.mem.indexOf(u8, sec, try std.fmt.bufPrint(&lb, "- s2.n5@{s} web_search {{\"query\":\"harbour tide tables\"}}: tide tables: high water", .{ep2})) != null);
    try tt.expect(std.mem.indexOf(u8, sec, try std.fmt.bufPrint(&lb, "- s2.n3@{s} read_file {{\"path\":\"tides/missing.md\"}} -> ERROR: no such file", .{ep2})) != null);
    // a memory echo and a credential-shaped result never cross into another conversation
    try tt.expect(std.mem.indexOf(u8, sec, "recalled:") == null);
    try tt.expect(std.mem.indexOf(u8, sec, "sk-not-a-real-key") == null);
    // round-robin: the first two lines are one of each member's
    const first = sec[FAMILY_HEAD.len..];
    try tt.expect(std.mem.startsWith(u8, first, "- s1."));
    const second = first[std.mem.indexOfScalar(u8, first, '\n').? + 1 ..];
    try tt.expect(std.mem.startsWith(u8, second, "- s2."));
    // every line's QID resolves to that very node
    {
        const r = recallMember(gpa, io, base ++ "/convs/fam", 2, 5, ep2);
        defer r.deinit(gpa);
        try tt.expect(std.mem.indexOf(u8, r.node.line, "high water 06:12") != null);
    }
    try tt.expectEqual(pool.last_bytes, sec.len);

    // results mode carries no member's words
    {
        var rp = (try Pool.init(gpa, io, base, "fam", .results, testKeep, 0, false)).?;
        defer rp.deinit();
        var ro: std.ArrayListUnmanaged(u8) = .empty;
        defer ro.deinit(gpa);
        try rp.render(gpa, &ro, "zebracorn42", 4096);
        try tt.expect(std.mem.indexOf(u8, ro.items, "answered:") == null);
        try tt.expect(std.mem.indexOf(u8, ro.items, "asked:") == null);
        try tt.expect(std.mem.indexOf(u8, ro.items, "zebracorn42 holds 1180") != null);
    }
    // a tight cap: fewer lines, the rest counted as skipped, and never past the cap
    {
        var co: std.ArrayListUnmanaged(u8) = .empty;
        defer co.deinit(gpa);
        try pool.render(gpa, &co, "zebracorn42", FAMILY_HEAD.len + 160);
        try tt.expect(co.items.len <= FAMILY_HEAD.len + 160);
        try tt.expect(pool.last_lines >= 1);
        try tt.expect(pool.last_skipped >= 1);
        // a cap the head alone fills writes nothing at all
        var none: std.ArrayListUnmanaged(u8) = .empty;
        defer none.deinit(gpa);
        try pool.render(gpa, &none, "zebracorn42", FAMILY_HEAD.len);
        try tt.expectEqual(@as(usize, 0), none.items.len);
    }

    // a refresh: s1 grew (read again), s2 was deleted and minted again with a BIGGER store (dropped for the turn on its
    // epoch alone), s4's store shrank under the same first line (dropped on its size alone), s3 appeared (read)
    try putMember(io, base, "fam__s1", "{\"role\":\"user\",\"content\":\"Read the alpha ledger.\",\"kind\":\"user\",\"ts\":100}\n", S1_GRAPH ++
        \\{"role":"assistant","content":"Calling read_file.","tool_calls":[{"id":"c9","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"ledger/beta.md\"}"}}],"_t":2,"_n":9}
        \\{"role":"tool","tool_call_id":"c9","content":"beta: quokkaplex holds 75","_t":2,"_n":10}
        \\
    );
    try putMember(io, base, "fam__s2", "{\"role\":\"user\",\"content\":\"Find the tide tables.\",\"kind\":\"user\",\"ts\":999}\n", S2_GRAPH ++ S2_GRAPH);
    try putMember(io, base, "fam__s4", "{\"role\":\"user\",\"content\":\"Chart the reef.\",\"kind\":\"user\",\"ts\":400}\n", "");
    try putMember(io, base, "fam__s3", "{\"role\":\"user\",\"content\":\"Walk the breakwater.\",\"kind\":\"user\",\"ts\":300}\n", S2_GRAPH);
    const loads = pool.loads;
    pool.refresh(REFRESH_MS - 1); // too soon: nothing re-read
    try tt.expectEqual(loads, pool.loads);
    pool.refresh(REFRESH_MS);
    try tt.expectEqual(@as(usize, 2), pool.members.items.len);
    try tt.expect(pool.gone[2]);
    try tt.expect(pool.gone[4]);
    try tt.expectEqual(@as(u8, 1), pool.members.items[0].slot);
    try tt.expectEqual(@as(u8, 3), pool.members.items[1].slot);
    out.clearRetainingCapacity();
    try pool.render(gpa, &out, "quokkaplex", 4096);
    try tt.expect(std.mem.indexOf(u8, out.items, "beta: quokkaplex holds 75") != null);
    try tt.expect(std.mem.indexOf(u8, out.items, "- s2.") == null);
    try tt.expect(std.mem.indexOf(u8, out.items, "- s4.") == null);
    try tt.expect(std.mem.indexOf(u8, out.items, "- s3.") != null);
    // a family of one has no section
    var lone = (try Pool.init(gpa, io, base, "solo", .on, testKeep, 0, false)).?;
    defer lone.deinit();
    var lo: std.ArrayListUnmanaged(u8) = .empty;
    defer lo.deinit(gpa);
    try lone.render(gpa, &lo, "x", 4096);
    try tt.expectEqual(@as(usize, 0), lo.items.len);
    try tt.expect((try Pool.init(gpa, io, base, "a__s1__s2", .on, testKeep, 0, false)) == null);
}

test "the ledger in a member's net: only what was sent to it, by the members as they stand, nothing spent, newest kept under the cap, oldest first, one line each" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const top = "zig-family-ledger-tmp";
    const base = top ++ "/u7/_chat";
    std.Io.Dir.cwd().deleteTree(io, top) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, top) catch {};
    try putMember(io, base, "fam", "{\"role\":\"user\",\"content\":\"Map the harbour.\",\"kind\":\"user\",\"ts\":50}\n", "");
    try putMember(io, base, "fam__s1", "{\"role\":\"user\",\"content\":\"Sound the channel.\",\"kind\":\"user\",\"ts\":60}\n", "");
    try putMember(io, base, "fam__s2", "{\"role\":\"user\",\"content\":\"Watch the tides.\",\"kind\":\"user\",\"ts\":70}\n", "");
    var b1: [EPOCH_LEN]u8 = undefined;
    var b2: [EPOCH_LEN]u8 = undefined;
    const e1 = memberEpoch(gpa, io, base ++ "/convs/fam__s1", &b1).?;
    const e2 = memberEpoch(gpa, io, base ++ "/convs/fam__s2", &b2).?;
    // #1 an open record (never current), #2 a question s1 answered (#3), #4 a steer a turn of s1 ended after (#5),
    // #6 a result from the s2 that held the slot before this one, #9 a steer to it, #10 a question s1 answered (#11)
    // with no turn of it ended since, #12 a record with no epoch, #13 torn
    const TEMPLATE =
        \\{"seq":1,"ts":1,"kind":"open","from":"fam","to":"fam__s1","text":"Sound the channel."}
        \\{"seq":2,"ts":2,"kind":"question","from":"fam","to":"fam__s1","to_epoch":"@E1@","text":"How deep?\nIn metres."}
        \\{"seq":3,"ts":3,"kind":"answer","from":"fam__s1","from_epoch":"@E1@","to":"fam","text":"12 m.","re":2}
        \\{"seq":4,"ts":4,"kind":"steer","from":"fam","to":"fam__s1","to_epoch":"@E1@","text":"Mind the shoals."}
        \\{"seq":5,"ts":5,"kind":"done","from":"fam__s1","from_epoch":"@E1@","to":"fam","text":"The channel is 12 m deep at low water.","status":"finished"}
        \\{"seq":6,"ts":6,"kind":"result","from":"fam__s2","from_epoch":"deadbeef","to":"fam","text":"Low water 00:40."}
        \\{"seq":7,"ts":7,"kind":"result","from":"fam__s2","from_epoch":"@E2@","to":"fam","text":"High water 06:12."}
        \\{"seq":8,"ts":8,"kind":"question","from":"fam","to":"fam__s1","to_epoch":"@E1@","text":"And at high water?"}
        \\{"seq":9,"ts":9,"kind":"steer","from":"fam","to":"fam__s2","to_epoch":"deadbeef","text":"Old steer."}
        \\{"seq":10,"ts":10,"kind":"question","from":"fam","to":"fam__s1","to_epoch":"@E1@","text":"Which buoy?"}
        \\{"seq":11,"ts":11,"kind":"answer","from":"fam__s1","from_epoch":"@E1@","to":"fam","text":"The red one.","re":10}
        \\{"seq":12,"ts":12,"kind":"answer","from":"fam__s1","to":"fam","text":"no epoch","re":8}
        \\{"seq":13,"ts":13,"kind":"answer","from":"fam__s1","from_epoch":"@E1@","to":"fam","text":"torn
    ;
    const t1 = try std.mem.replaceOwned(u8, gpa, TEMPLATE, "@E1@", e1);
    defer gpa.free(t1);
    const LOG = try std.mem.replaceOwned(u8, gpa, t1, "@E2@", e2);
    defer gpa.free(LOG);
    try putFile(io, base ++ "/convs/fam", LOG_FILE, LOG);
    {
        var log = try readLog(gpa, io, base ++ "/convs/fam", LOG_TAIL_BYTES);
        defer log.deinit();
        try tt.expectEqual(@as(usize, 12), log.recs.len); // the torn thirteenth is not a record yet
        try tt.expectEqualStrings("How deep?\nIn metres.", log.recs[1].text);
        try tt.expectEqual(@as(u64, 2), log.recs[2].re);
        try tt.expectEqualStrings(e1, log.recs[1].to_epoch);
        try tt.expectEqualStrings(e1, log.recs[2].from_epoch);
    }
    // the primary: its sub-chats' answer, done note and result, oldest first, under the ledger head; the old s2's
    // result and the record with no epoch are history
    var p = (try Pool.init(gpa, io, base, "fam", .off, testKeep, 0, true)).?;
    defer p.deinit();
    try tt.expectEqual(@as(usize, 0), p.members.items.len); // the net flag off: no member's 4tope is read
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try p.render(gpa, &out, "", 4096);
    try tt.expectEqualStrings(LEDGER_HEAD ++
        "- ledger #3 s1 answers #2: 12 m.\n" ++
        "- ledger #5 s1 done [finished]: The channel is 12 m deep at low water.\n" ++
        "- ledger #7 s2 result: High water 06:12.\n" ++
        "- ledger #11 s1 answers #10: The red one.\n", out.items);
    try tt.expectEqual(@as(usize, 4), p.last_ledger_lines);
    // the sub-chat: only the question still open, on one line, with how to answer it (#2 and #10 it answered, #4 a
    // turn of it ended after)
    var q = (try Pool.init(gpa, io, base, "fam__s1", .off, testKeep, 0, true)).?;
    defer q.deinit();
    out.clearRetainingCapacity();
    try q.render(gpa, &out, "", 4096);
    try tt.expectEqualStrings(LEDGER_HEAD ++ "- ledger #8 main asks (answer it with report_to_primary, re 8): And at high water?\n", out.items);
    // the new s2: nothing that was sent to the conversation that held its slot before
    var r2 = (try Pool.init(gpa, io, base, "fam__s2", .off, testKeep, 0, true)).?;
    defer r2.deinit();
    out.clearRetainingCapacity();
    try r2.render(gpa, &out, "", 4096);
    try tt.expectEqualStrings("", out.items);
    // a tight cap keeps the NEWEST records that fit, still oldest first
    out.clearRetainingCapacity();
    try p.render(gpa, &out, "", 2 * (LEDGER_HEAD.len + 45)); // room for the 42-byte line #11, not for #7 beside it
    try tt.expectEqualStrings(LEDGER_HEAD ++ "- ledger #11 s1 answers #10: The red one.\n", out.items);
    try tt.expect(p.last_skipped >= 1);
    // a record appended mid-turn shows once the pool refreshes
    const grown = try std.fmt.allocPrint(gpa, "{s}\",\"re\":2}}\n", .{LOG});
    defer gpa.free(grown);
    try putFile(io, base ++ "/convs/fam", LOG_FILE, grown);
    p.refresh(REFRESH_MS);
    out.clearRetainingCapacity();
    try p.render(gpa, &out, "", 4096);
    try tt.expect(std.mem.endsWith(u8, out.items, "- ledger #13 s1 answers #2: torn\n"));
    // the route's log: the current records, flat (open, the old s2's and the epoch-less ones left out), and each
    // sub-chat's answer from its newest done record
    {
        var fam = (try load(gpa, io, base, 7, "fam", liveS1For7)).?;
        defer fam.deinit();
        var log = try readLog(gpa, io, base ++ "/convs/fam", LOG_TAIL_BYTES);
        defer log.deinit();
        try answersFromLog(gpa, &fam, &log);
        try tt.expectEqualStrings("The channel is 12 m deep at low water.", fam.members.items[1].answer);
        var js: std.ArrayListUnmanaged(u8) = .empty;
        defer js.deinit(gpa);
        try familyJsonLog(gpa, &js, &fam, &log);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, js.items, .{});
        defer parsed.deinit();
        const arr = parsed.value.object.get("log").?.array.items;
        const want = [_]i64{ 2, 3, 4, 5, 7, 8, 10, 11, 13 };
        try tt.expectEqual(want.len, arr.len);
        for (want, arr) |w, x| try tt.expectEqual(w, x.object.get("seq").?.integer);
        try tt.expectEqualStrings("done", arr[3].object.get("kind").?.string);
        try tt.expectEqualStrings("finished", arr[3].object.get("status").?.string);
        // without a log the reply is the Phase 1 shape exactly: no "log" key
        js.clearRetainingCapacity();
        try familyJsonLog(gpa, &js, &fam, null);
        try tt.expect(std.mem.indexOf(u8, js.items, "\"log\"") == null);
    }
    // s2 deleted and opened again: its records drop at the next scan, though the ledger did not grow
    try putMember(io, base, "fam__s2", "{\"role\":\"user\",\"content\":\"Count the buoys.\",\"kind\":\"user\",\"ts\":80}\n", "");
    p.refresh(2 * REFRESH_MS);
    out.clearRetainingCapacity();
    try p.render(gpa, &out, "", 4096);
    try tt.expect(std.mem.indexOf(u8, out.items, "#7 s2") == null);
    try tt.expect(std.mem.indexOf(u8, out.items, "#5 s1 done") != null);
}

test "a member's epoch covers a first message longer than one read, and is the hash of the whole of line 1" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const top = "zig-family-epoch-long-tmp";
    std.Io.Dir.cwd().deleteTree(io, top) catch {};
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, top, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, top) catch {};
    // a pasted log of 40 KB as the first message: more than one HEAD_READ_BYTES read
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    try line.appendSlice(gpa, "{\"role\":\"user\",\"content\":\"");
    try line.appendNTimes(gpa, 'x', 40 * 1024);
    try line.appendSlice(gpa, "\",\"kind\":\"user\",\"ts\":90}");
    var file: std.ArrayListUnmanaged(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, line.items);
    try file.appendSlice(gpa, "\r\n{\"role\":\"assistant\",\"content\":\"ok\",\"kind\":\"veil\",\"ts\":91}\n");
    try putFile(io, top, "messages.jsonl", file.items);
    var eb: [EPOCH_LEN]u8 = undefined;
    const ep = memberEpoch(gpa, io, top, &eb) orelse return error.NoEpoch;
    var want: [EPOCH_LEN]u8 = undefined;
    const h: u32 = @truncate(std.hash.Wyhash.hash(0, line.items)); // the line, its '\r\n' not part of it
    try tt.expectEqualStrings(try std.fmt.bufPrint(&want, "{x:0>8}", .{h}), ep);
    // line 1 not yet whole: no epoch
    try putFile(io, top, "messages.jsonl", line.items);
    try tt.expect(memberEpoch(gpa, io, top, &eb) == null);
}

test "read-only by construction: the code above the tests writes nothing and imports no store, memory or engine" {
    // The literals are split so this test's own text cannot match them.
    const src = @embedFile("family.zig");
    const at = std.mem.indexOf(u8, src, "// ---" ++ "- tests ----") orelse return error.NoTestsMarker;
    const code = src[0..at];
    try tt.expect(std.mem.indexOf(u8, code, "pub fn " ++ "load(") != null); // the cut kept the code, not an empty head
    // the write calls a file or the file system offers (a file opened for writing, its writers, a copy, a truncate, a
    // rename, a link), and the imports of the store, the engine and the memory client
    for ([_][]const u8{
        "append" ++ "File",              "write" ++ "File",                       "create" ++ "File",               "create" ++ "Dir",
        "delete" ++ "Tree",              "delete" ++ "File",                      "delete" ++ "Dir",                "re" ++ "name(",
        "write" ++ "Positional",         "read_" ++ "write",                      "set" ++ "Timestamps",            "write_" ++ "only",
        "write" ++ "Streaming",          "write" ++ "All",                        "writer" ++ "(",                  "copy" ++ "File",
        "set" ++ "Length",               "sym" ++ "Link",                         "hard" ++ "Link",                 "@import(\"" ++ "store.zig\")",
        "@import(\"" ++ "engine.zig\")", "@import(\"../" ++ "oscillation.zig\")", "@import(\"" ++ "service.zig\")",
    }) |banned| {
        if (std.mem.indexOf(u8, code, banned)) |i| {
            std.debug.print("\nfamily.zig must stay read-only, and its code holds \"{s}\" at byte {d}\n", .{ banned, i });
            return error.FamilyViewNotReadOnly;
        }
    }
}
