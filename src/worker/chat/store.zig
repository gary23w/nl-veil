//! store.zig — Gary's 4tope as the conversation's memory: the store, and the prompt that is unfolded from it.
//!
//! Conversation context is captured and retrieved directly.
//! Conversation context is captured and retrieved directly.
//! context". The first implementation (v1.1.16 to v1.1.22) used the net to PACKAGE a carry when a turn's working
//! context had to be compressed. This module is the design as framed: nothing is compressed and nothing is carried.
//!
//!   * CAPTURE as the chat runs. Every message of every turn — the ask that opened it, each step with its calls,
//!     each tool result as the model saw it, each answer — is appended to `{conv}/graph.jsonl` the moment it
//!     exists, stamped with its turn (`_t`) and a conversation-wide id (`_n`). Each tool result's payload also
//!     goes into neuron-db as a document scope of its own (`<scope>__n<id>`, one fact per line) in one import per
//!     step, so the raw output is searchable (`context --across`) and readable (`read`) there too. A result that
//!     looks like a credential is withheld from both (the gate).
//!   * THE GRAPH is the whole stored conversation read as one DAG (net.Graph.fromSpanWith .store): every edge the
//!     one-turn net already records, plus long-range links from any step, ask or answer to the earlier nodes that
//!     share a RARE word with it — the retrieval half.
//!   * EVERY PROMPT IS UNFOLDED, not carried (the default; NL_CONTEXT=fold restores the fold). A request is the turn's
//!     assembled prefix, then ONE system message holding the net unfolded from where the work stands over the whole
//!     store under a budget, then the newest KEEP_ROUNDS rounds verbatim. The prompt stays the same size at turn 5
//!     and at turn 5,000; nothing older is summarized, it is either near enough to be shown or recallable by id.
//!
//! Positions in conv_buf are tracked by MESSAGE COUNT, never by byte offset: a reasoning-echo heal rewrites the
//! buffer in place (offsets move, the count does not), the recall overlay is appended and removed around each
//! call, and a fold (the default path) replaces messages — after which the engine resyncs the count.

const std = @import("std");
const dag = @import("net.zig");
const http = @import("../../gateway/http.zig");

pub const FILE = "graph.jsonl";

/// What introduces the net in a request. Third person and explicit about provenance, like every engine block.
pub const NET_HEAD = "WORK SO FAR (Gary's 4tope: this conversation's earlier asks, answers and tool results, laid out from where the work stands; every line is verbatim from the conversation's store, and recall_node with an n<id> returns that node whole):\n";

/// The newest rounds a request carries verbatim after the net (a round opens with an assistant message).
pub const KEEP_ROUNDS: usize = 2;
/// One tool result's payload as a neuron-db document: at most this much of it, cut into lines of at most
/// DOC_LINE_MAX bytes, at most DOC_LINES_MAX lines.
pub const DOC_MAX: usize = 16 * 1024;
pub const DOC_LINE_MAX: usize = 400;
pub const DOC_LINES_MAX: usize = 400;

/// What may be stored of a tool result: all of it, all of it but no neuron-db document (memory output re-observed
/// would launder other scopes' facts), or nothing but a stub (a credential-shaped result must never recirculate).
pub const Gate = enum { keep, no_docs, withhold };
pub const GateFn = *const fn (name: []const u8, head: []const u8) Gate;

const WITHHELD = "(withheld from the conversation store: the result looked like a credential)";
const NONE_OBJS: usize = std.math.maxInt(usize);
const MARK = "{\"role\":\"";

/// One message object of a comma-joined message buffer (`{...},{...}` as conv_buf holds them).
pub const Obj = struct { start: usize, end: usize };

/// Walk the message objects of `items` in order. The first may sit at offset 0; every later one follows a comma.
/// A content string can never contain `,{"role":"` unescaped, so the boundaries are exact.
pub const ObjIter = struct {
    items: []const u8,
    at: usize = 0,
    pub fn next(it: *ObjIter) ?Obj {
        if (it.at >= it.items.len) return null;
        const start = if (it.at == 0 and std.mem.startsWith(u8, it.items, MARK))
            0
        else blk: {
            const c = std.mem.indexOfPos(u8, it.items, it.at, "," ++ MARK) orelse return null;
            break :blk c + 1;
        };
        const end = std.mem.indexOfPos(u8, it.items, start + MARK.len, "," ++ MARK) orelse it.items.len;
        it.at = end;
        return .{ .start = start, .end = end };
    }
};

/// Does `bytes` parse as one JSON value? An allocation failure counts as no: nothing unchecked is stored.
fn parses(gpa: std.mem.Allocator, bytes: []const u8) bool {
    return std.json.validate(gpa, bytes) catch false;
}

pub fn countObjects(items: []const u8) usize {
    var it = ObjIter{ .items = items };
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    /// the neuron-db scope the raw documents hang off (`<scope>__n<id>`): the conversation's memory scope
    scope: []u8,
    gate: GateFn,
    /// earlier turns' stored objects, comma-joined, exactly as loaded
    past: std.ArrayListUnmanaged(u8) = .empty,
    past_nodes: u32 = 0,
    /// this turn's stored objects, comma-joined, and for each the conv_buf message index it was captured from
    /// (PREFIX_OBJ for the ask, which lives in the prefix, never in the span)
    cur: std.ArrayListUnmanaged(u8) = .empty,
    cur_obj: std.ArrayListUnmanaged(usize) = .empty,
    next_id: u64 = 1,
    /// this turn's number once captureAsk ran (1-based)
    turn: u32 = 0,
    /// messages in conv_buf's assembled prefix (NONE_OBJS until setPrefix: nothing is captured before that)
    prefix_objs: usize = NONE_OBJS,
    /// conv_buf messages accounted for (captured or deliberately skipped)
    captured_objs: usize = 0,
    /// asks and answers of this turn and later ride in the recency window verbatim (assembleHistory sets it)
    dialog_before_turn: u32 = std.math.maxInt(u32),
    calls: std.ArrayListUnmanaged(Call) = .empty,
    /// pending neuron-db document lines (`{"scope":…,"fact":…}` per line) not yet imported
    docs: std.ArrayListUnmanaged(u8) = .empty,
    /// what the last assemble did, for the engine's trace
    last_net_bytes: usize = 0,
    last_nodes: usize = 0,
    /// messages capture refused because they do not parse, and how many of those the engine has announced
    refused: usize = 0,
    refused_told: usize = 0,
    /// graph.jsonl lines init skipped because they do not parse (a torn append)
    torn: usize = 0,

    const Call = struct { id: []u8, name: []u8 };
    pub const PREFIX_OBJ: usize = std.math.maxInt(usize);

    pub fn init(gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8, scope: []const u8, gate: GateFn) !Store {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ conv_dir, FILE });
        errdefer gpa.free(path);
        const sc = try gpa.dupe(u8, scope);
        errdefer gpa.free(sc);
        var s: Store = .{ .gpa = gpa, .io = io, .path = path, .scope = sc, .gate = gate };
        errdefer s.deinit();
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30)) catch return s;
        defer gpa.free(raw);
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |l| {
            const line = std.mem.trim(u8, l, " \r\t");
            if (!std.mem.startsWith(u8, line, MARK)) continue;
            // A line that does not parse is a torn append (a crash mid-write) or damage from elsewhere: skipped, never
            // fed to the graph, where one unterminated string would swallow every node stored after it.
            if (!parses(gpa, line)) {
                s.torn += 1;
                continue;
            }
            try s.past.append(gpa, ',');
            try s.past.appendSlice(gpa, line);
            s.past_nodes += 1;
            if (stampVal(line, "_n")) |id| s.next_id = @max(s.next_id, id + 1);
            if (std.mem.indexOf(u8, line, "\"_k\":\"ask\"") != null) s.turn += 1;
        }
        return s;
    }

    pub fn deinit(s: *Store) void {
        for (s.calls.items) |c| {
            s.gpa.free(c.id);
            s.gpa.free(c.name);
        }
        s.calls.deinit(s.gpa);
        s.past.deinit(s.gpa);
        s.cur.deinit(s.gpa);
        s.cur_obj.deinit(s.gpa);
        s.docs.deinit(s.gpa);
        s.gpa.free(s.path);
        s.gpa.free(s.scope);
    }

    /// The turn's assembled prefix is everything in conv_buf now: capture starts after it.
    pub fn setPrefix(s: *Store, items: []const u8) void {
        s.prefix_objs = countObjects(items);
        s.captured_objs = s.prefix_objs;
    }

    /// conv_buf was rewritten (a fold, a roll): its current messages are accounted for, nothing re-captured.
    pub fn resync(s: *Store, items: []const u8) void {
        if (s.prefix_objs == NONE_OBJS) return;
        s.captured_objs = @max(countObjects(items), s.prefix_objs);
    }

    /// The user message that opens this turn: a new turn number, stored as the turn's ask.
    pub fn captureAsk(s: *Store, text: []const u8) void {
        s.turn += 1;
        var obj: std.ArrayListUnmanaged(u8) = .empty;
        defer obj.deinit(s.gpa);
        obj.appendSlice(s.gpa, "{\"role\":\"user\",\"content\":") catch return;
        http.jstr(s.gpa, &obj, text) catch return;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.gpa);
        s.stampInto(&out, obj.items, true) catch return;
        s.keep(out.items, PREFIX_OBJ) catch return;
        out.append(s.gpa, '\n') catch return;
        http.appendFile(s.io, s.gpa, s.path, out.items) catch {};
    }

    /// Store every conv_buf message past what is accounted for: steps, results, answers, drive and steer messages.
    /// System messages are the engine's own (overlay, ground-truth splices, stop notes) and are not stored. A tool
    /// result passes the gate; a kept one also queues its payload as a neuron-db document (takeDocs).
    pub fn capture(s: *Store, items: []const u8) void {
        if (s.prefix_objs == NONE_OBJS) return;
        var lines: std.ArrayListUnmanaged(u8) = .empty;
        defer lines.deinit(s.gpa);
        var it = ObjIter{ .items = items };
        var k: usize = 0;
        while (it.next()) |o| : (k += 1) {
            if (k < s.captured_objs) continue;
            const obj = std.mem.trimEnd(u8, items[o.start..o.end], " \r\n\t");
            if (obj.len < 2) continue;
            const role = dag.jsonStr(obj, "role");
            if (std.mem.eql(u8, role, "system")) continue;
            // A MESSAGE THAT DOES NOT PARSE IS NEVER STORED. conv_buf can hold one: conv cf5c78765 (2026-10-16) had its
            // turn brief cut mid-string by a fold at a stale byte offset, and every request after it was unparsable.
            // Stored, it would outlive that buffer in graph.jsonl and corrupt every later turn's graph. Refused and
            // counted instead, so the engine says so: one cut short of its brace, and one whose braces close over a
            // broken string alike.
            if (obj[obj.len - 1] != '}' or !parses(s.gpa, obj)) {
                s.refused += 1;
                std.log.warn("store: refused a {s} message that does not parse as JSON ({d} bytes)", .{ if (role.len > 0) role else "?", obj.len });
                continue;
            }
            const before = lines.items.len;
            if (std.mem.eql(u8, role, "assistant")) {
                s.noteCalls(obj);
                s.stampInto(&lines, obj[0 .. obj.len - 1], false) catch continue;
            } else if (std.mem.eql(u8, role, "tool")) {
                const id = dag.jsonStr(obj, "tool_call_id");
                const name = s.callName(id);
                const raw = dag.jsonStr(obj, "content");
                var hb: [512]u8 = undefined;
                const head = unescapeInto(&hb, raw);
                switch (s.gate(name, head)) {
                    .withhold => {
                        var w: std.ArrayListUnmanaged(u8) = .empty;
                        defer w.deinit(s.gpa);
                        w.appendSlice(s.gpa, "{\"role\":\"tool\",\"tool_call_id\":\"") catch continue;
                        w.appendSlice(s.gpa, id) catch continue;
                        w.appendSlice(s.gpa, "\",\"content\":\"" ++ WITHHELD ++ "\"") catch continue;
                        s.stampInto(&lines, w.items, false) catch continue;
                    },
                    .keep, .no_docs => |g| {
                        if (g == .keep) s.queueDoc(s.next_id, raw);
                        s.stampInto(&lines, obj[0 .. obj.len - 1], false) catch continue;
                    },
                }
            } else if (std.mem.eql(u8, role, "user")) {
                s.stampInto(&lines, obj[0 .. obj.len - 1], false) catch continue;
            } else continue;
            // the stamped line just written, kept for this turn's graph
            s.keep(lines.items[before..], k) catch {};
            lines.append(s.gpa, '\n') catch {};
        }
        s.captured_objs = @max(k, s.captured_objs);
        if (lines.items.len > 0) http.appendFile(s.io, s.gpa, s.path, lines.items) catch {};
    }

    /// The queued neuron-db document lines, or null when none are pending. gpa-owned.
    pub fn takeDocs(s: *Store) ?[]u8 {
        if (s.docs.items.len == 0) return null;
        return s.docs.toOwnedSlice(s.gpa) catch null;
    }

    /// THE REQUEST, UNFOLDED: conv_buf's assembled prefix, then one system message with the net unfolded over the
    /// whole store from where the work stands (under `budget` bytes), then the newest KEEP_ROUNDS rounds verbatim.
    /// The caller captures first, so everything before the live rounds is in the store. gpa-owned.
    pub fn assemble(s: *Store, items: []const u8, budget: usize) ![]u8 {
        const gpa = s.gpa;
        const cut = s.cuts(items);
        var span: std.ArrayListUnmanaged(u8) = .empty;
        defer span.deinit(gpa);
        try span.ensureTotalCapacity(gpa, s.past.items.len + s.cur.items.len);
        span.appendSliceAssumeCapacity(s.past.items);
        span.appendSliceAssumeCapacity(s.cur.items);
        var tail_from: u32 = dag.Graph.NONE;
        for (s.cur_obj.items, 0..) |ci, j| if (ci != PREFIX_OBJ and ci >= cut.live_obj) {
            tail_from = s.past_nodes + @as(u32, @intCast(j));
            break;
        };
        var net: []u8 = &.{};
        defer if (net.len > 0) gpa.free(net);
        if (span.items.len > 0) {
            var g = try dag.Graph.fromSpanWith(gpa, span.items, .{ .store = true });
            defer g.deinit();
            s.last_nodes = g.nodes.items.len;
            net = try g.unfoldWith(gpa, budget, "", .{ .tail_from = tail_from, .dialog = true, .no_next = true, .ids = true, .dialog_before_turn = s.dialog_before_turn });
        }
        s.last_net_bytes = net.len;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, items[0..cut.prefix_end]);
        if (net.len > 0) {
            var content: std.ArrayListUnmanaged(u8) = .empty;
            defer content.deinit(gpa);
            try content.appendSlice(gpa, NET_HEAD);
            try content.appendSlice(gpa, net);
            try out.appendSlice(gpa, ",{\"role\":\"system\",\"content\":");
            try http.jstr(gpa, &out, content.items);
            try out.append(gpa, '}');
        }
        try out.appendSlice(gpa, items[cut.live_start..]);
        return out.toOwnedSlice(gpa);
    }

    /// Where the prefix ends (the comma before the span's first message, or the end) and where the live rounds
    /// begin (the comma before the KEEP_ROUNDS-th last assistant message of the span, or the span's start), with the
    /// live start's message index.
    pub const Cuts = struct { prefix_end: usize, live_start: usize, live_obj: usize };
    pub fn cuts(s: *const Store, items: []const u8) Cuts {
        const pobjs = if (s.prefix_objs == NONE_OBJS) countObjects(items) else s.prefix_objs;
        var it = ObjIter{ .items = items };
        var k: usize = 0;
        var prefix_end: usize = items.len;
        var asst: [KEEP_ROUNDS]struct { at: usize, k: usize } = undefined;
        var na: usize = 0;
        while (it.next()) |o| : (k += 1) {
            if (k < pobjs) continue;
            const comma = if (o.start > 0) o.start - 1 else 0;
            if (k == pobjs) prefix_end = comma;
            if (std.mem.startsWith(u8, items[o.start..], "{\"role\":\"assistant\"")) {
                // a ring of the newest KEEP_ROUNDS assistant messages
                if (na < KEEP_ROUNDS) {
                    asst[na] = .{ .at = comma, .k = k };
                    na += 1;
                } else {
                    std.mem.copyForwards(@TypeOf(asst[0]), asst[0 .. KEEP_ROUNDS - 1], asst[1..KEEP_ROUNDS]);
                    asst[KEEP_ROUNDS - 1] = .{ .at = comma, .k = k };
                }
            }
        }
        if (na < KEEP_ROUNDS) return .{ .prefix_end = prefix_end, .live_start = prefix_end, .live_obj = pobjs };
        return .{ .prefix_end = prefix_end, .live_start = asst[0].at, .live_obj = asst[0].k };
    }

    fn keep(s: *Store, line: []const u8, conv_obj: usize) !void {
        try s.cur.append(s.gpa, ',');
        try s.cur.appendSlice(s.gpa, line);
        try s.cur_obj.append(s.gpa, conv_obj);
    }

    /// `obj` without its closing brace, then this turn's stamps and a fresh id.
    fn stampInto(s: *Store, out: *std.ArrayListUnmanaged(u8), obj: []const u8, ask: bool) !void {
        try out.appendSlice(s.gpa, obj);
        try out.print(s.gpa, ",\"_t\":{d},\"_n\":{d}{s}}}", .{ s.turn, s.next_id, if (ask) ",\"_k\":\"ask\"" else "" });
        s.next_id += 1;
    }

    fn noteCalls(s: *Store, obj: []const u8) void {
        const key = "\"tool_calls\":[";
        const start = std.mem.indexOf(u8, obj, key) orelse return;
        var at = start + key.len;
        while (std.mem.indexOfPos(u8, obj, at, "{\"id\":\"")) |cs| {
            const ce = std.mem.indexOfPos(u8, obj, cs, "}}") orelse obj.len;
            const call = obj[cs..@min(obj.len, ce + 2)];
            at = @max(cs + 1, ce);
            const id = dag.jsonStr(call, "id");
            if (id.len == 0) continue;
            const idc = s.gpa.dupe(u8, id) catch return;
            const namec = s.gpa.dupe(u8, dag.jsonStr(call, "name")) catch {
                s.gpa.free(idc);
                return;
            };
            s.calls.append(s.gpa, .{ .id = idc, .name = namec }) catch {
                s.gpa.free(idc);
                s.gpa.free(namec);
                return;
            };
        }
    }

    fn callName(s: *const Store, id: []const u8) []const u8 {
        var i = s.calls.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, s.calls.items[i].id, id)) return s.calls.items[i].name;
        }
        return "";
    }

    /// A tool result's payload as document lines for `<scope>__n<id>`: the result unescaped with its newlines, its
    /// payload field when it is a JSON envelope (net.payloadOf), cut into lines of at most DOC_LINE_MAX bytes.
    fn queueDoc(s: *Store, id: u64, raw: []const u8) void {
        const gpa = s.gpa;
        const text = unescapeAlloc(gpa, raw, DOC_MAX) catch return;
        defer gpa.free(text);
        const pay = dag.payloadOf(text);
        const inner: ?[]u8 = if (pay.ptr == text.ptr and pay.len == text.len) null else (unescapeAlloc(gpa, pay, DOC_MAX) catch null);
        defer if (inner) |b| gpa.free(b);
        const body = inner orelse text;
        var scope_buf: [256]u8 = undefined;
        const doc_scope = std.fmt.bufPrint(&scope_buf, "{s}__n{d}", .{ s.scope, id }) catch return;
        var n: usize = 0;
        var ls = std.mem.splitScalar(u8, body, '\n');
        while (ls.next()) |l| {
            var rest = std.mem.trim(u8, l, " \r\t");
            while (rest.len > 0 and n < DOC_LINES_MAX) {
                var take: usize = @min(rest.len, DOC_LINE_MAX);
                if (take < rest.len) {
                    if (std.mem.lastIndexOfScalar(u8, rest[0..take], ' ')) |sp| {
                        if (sp > DOC_LINE_MAX / 2) take = sp;
                    }
                    while (take > 0 and (rest[take] & 0xC0) == 0x80) take -= 1;
                }
                const piece = std.mem.trim(u8, rest[0..take], " ");
                rest = std.mem.trimStart(u8, rest[take..], " ");
                if (piece.len == 0) continue;
                s.docs.appendSlice(gpa, "{\"scope\":") catch return;
                http.jstr(gpa, &s.docs, doc_scope) catch return;
                s.docs.appendSlice(gpa, ",\"fact\":") catch return;
                http.jstr(gpa, &s.docs, piece) catch return;
                s.docs.appendSlice(gpa, "}\n") catch return;
                n += 1;
            }
            if (n >= DOC_LINES_MAX) break;
        }
    }
};

/// One stored node, the whole line, by its id — what recall_node returns. Null when the store has no such node.
/// gpa-owned.
pub fn nodeLine(gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8, id: u64) ?[]u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ conv_dir, FILE }) catch return null;
    defer gpa.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30)) catch return null;
    defer gpa.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |l| {
        const line = std.mem.trim(u8, l, " \r\t");
        if ((stampVal(line, "_n") orelse continue) == id) return gpa.dupe(u8, line) catch null;
    }
    return null;
}

/// The integer value of a stamp (`"_n":123`) in a stored line, from its LAST occurrence (the stamps close the line,
/// so a content string that happens to spell one cannot shadow them).
fn stampVal(line: []const u8, key: []const u8) ?u64 {
    var kb: [16]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.lastIndexOf(u8, line, k) orelse return null;
    var i = at + k.len;
    const start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, line[start..i], 10) catch null;
}

/// Unescape a raw JSON string (as a message holds it) into `buf`, newlines kept, as much as fits.
fn unescapeInto(buf: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len and n < buf.len) : (i += 1) {
        var c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            c = switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b', 'f' => ' ',
                'u' => blk: {
                    i += @min(4, raw.len - i - 1);
                    break :blk '?';
                },
                else => raw[i],
            };
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn unescapeAlloc(gpa: std.mem.Allocator, raw: []const u8, max: usize) ![]u8 {
    const buf = try gpa.alloc(u8, @min(raw.len, max));
    errdefer gpa.free(buf);
    const got = unescapeInto(buf, raw);
    return gpa.realloc(buf, got.len);
}

// ---------------------------------------------------------------------------------------------------- tests

const tt = std.testing;

fn testGate(name: []const u8, head: []const u8) Gate {
    if (std.mem.eql(u8, name, "get_credential")) return .withhold;
    if (std.mem.indexOf(u8, head, "api_key") != null) return .withhold;
    if (std.mem.eql(u8, name, "recall")) return .no_docs;
    return .keep;
}

/// A conv_buf the way runTurn builds one: a system prefix and a history, then this turn's span.
fn testPrefix(b: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !void {
    try b.appendSlice(gpa, "{\"role\":\"system\",\"content\":\"you are the veil\"}");
    try b.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"Read the alpha ledger.\"}");
}

fn testRound(b: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, id: []const u8, name: []const u8, path: []const u8, result: []const u8) !void {
    try b.print(gpa, ",{{\"role\":\"assistant\",\"content\":\"Calling {s}.\",\"tool_calls\":[{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{{\\\"path\\\":\\\"{s}\\\"}}\"}}}}]}}", .{ name, id, name, path });
    try b.print(gpa, ",{{\"role\":\"tool\",\"tool_call_id\":\"{s}\",\"content\":\"{s}\"}}", .{ id, result });
}

test "capture stores each message once, stamped, withholds a credential, queues documents, and survives a reload" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "zig-store-capture-tmp";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try Store.init(gpa, io, dir, "chat:c1", testGate);
    defer s.deinit();
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    try testPrefix(&b, gpa);
    s.captureAsk("Read the alpha ledger.");
    s.setPrefix(b.items);
    try testRound(&b, gpa, "c1", "read_file", "ledger/alpha.md", "line one of alpha\\nline two: zebracorn42 holds 1180");
    try testRound(&b, gpa, "c2", "get_credential", "github", "ghp_secretvalue");
    s.capture(b.items);
    // a second capture with nothing new stores nothing more
    s.capture(b.items);
    // the overlay (a system message) is never stored
    try b.appendSlice(gpa, ",{\"role\":\"system\",\"content\":\"memory overlay\"}");
    s.capture(b.items);
    try tt.expectEqual(@as(u32, 1), s.turn);
    try tt.expectEqual(@as(usize, 5), s.cur_obj.items.len); // ask + 2 steps + 2 results
    try tt.expect(std.mem.indexOf(u8, s.cur.items, "ghp_secretvalue") == null);
    try tt.expect(std.mem.indexOf(u8, s.cur.items, WITHHELD) != null);
    try tt.expect(std.mem.indexOf(u8, s.cur.items, "memory overlay") == null);
    try tt.expect(std.mem.indexOf(u8, s.cur.items, "\"_t\":1,\"_n\":1,\"_k\":\"ask\"}") != null);
    // the kept result was queued as a document of its own, one fact per line; the withheld one was not
    const docs = s.takeDocs().?;
    defer gpa.free(docs);
    try tt.expect(std.mem.indexOf(u8, docs, "{\"scope\":\"chat:c1__n3\",\"fact\":\"line one of alpha\"}\n") != null);
    try tt.expect(std.mem.indexOf(u8, docs, "{\"scope\":\"chat:c1__n3\",\"fact\":\"line two: zebracorn42 holds 1180\"}\n") != null);
    try tt.expect(std.mem.indexOf(u8, docs, "secretvalue") == null);
    try tt.expect(s.takeDocs() == null);
    // a reload sees the same store: five nodes, turn 1, the next id after them
    var r = try Store.init(gpa, io, dir, "chat:c1", testGate);
    defer r.deinit();
    try tt.expectEqual(@as(u32, 5), r.past_nodes);
    try tt.expectEqual(@as(u32, 1), r.turn);
    try tt.expectEqual(@as(u64, 6), r.next_id);
    // and a node comes back whole by its id
    const line = nodeLine(gpa, io, dir, 3).?;
    defer gpa.free(line);
    try tt.expect(std.mem.indexOf(u8, line, "zebracorn42") != null);
    try tt.expect(nodeLine(gpa, io, dir, 99) == null);
}

test "assemble: the prefix, one net of the earlier work with ids, then the newest rounds verbatim" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "zig-store-assemble-tmp";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try Store.init(gpa, io, dir, "chat:c2", testGate);
    defer s.deinit();
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    try testPrefix(&b, gpa);
    s.captureAsk("Read the alpha ledger.");
    s.setPrefix(b.items);
    const prefix_len = b.items.len;
    try testRound(&b, gpa, "c1", "read_file", "ledger/alpha.md", "alpha: zebracorn42 holds 1180");
    try testRound(&b, gpa, "c2", "read_file", "ledger/beta.md", "beta: quokkaplex holds 75");
    try testRound(&b, gpa, "c3", "read_file", "ledger/gamma.md", "gamma: the last part");
    s.capture(b.items);
    const req = try s.assemble(b.items, 4000);
    defer gpa.free(req);
    // the prefix is untouched and first
    try tt.expect(std.mem.startsWith(u8, req, b.items[0..prefix_len]));
    // then the net, as one system message, carrying the oldest round with its id
    const net_at = std.mem.indexOf(u8, req, "WORK SO FAR (Gary's 4tope").?;
    try tt.expect(net_at > prefix_len);
    try tt.expect(std.mem.indexOf(u8, req, "n3 read_file {\\\"path\\\":\\\"ledger/alpha.md\\\"}: alpha: zebracorn42 holds 1180") != null);
    // the newest KEEP_ROUNDS rounds ride verbatim after it, and only there
    const beta = std.mem.indexOf(u8, req, ",{\"role\":\"assistant\",\"content\":\"Calling read_file.\",\"tool_calls\":[{\"id\":\"c2\"").?;
    try tt.expect(beta > net_at);
    try tt.expect(std.mem.endsWith(u8, req, "\"content\":\"gamma: the last part\"}"));
    try tt.expectEqual(@as(usize, 1), std.mem.count(u8, req, "quokkaplex holds 75"));
    // and the whole request is still one well-formed message list
    var wrapped: std.ArrayListUnmanaged(u8) = .empty;
    defer wrapped.deinit(gpa);
    try wrapped.append(gpa, '[');
    try wrapped.appendSlice(gpa, req);
    try wrapped.append(gpa, ']');
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, wrapped.items, .{});
    defer parsed.deinit();
    try tt.expectEqual(@as(usize, 2 + 1 + 4), parsed.value.array.items.len);
}

test "a message that does not parse is refused, the ones around it are stored, and a torn line is skipped on reload" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "zig-store-refuse-tmp";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try Store.init(gpa, io, dir, "chat:c3", testGate);
    defer s.deinit();
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    try testPrefix(&b, gpa);
    s.captureAsk("Read the alpha ledger.");
    s.setPrefix(b.items);
    try testRound(&b, gpa, "c1", "read_file", "a.md", "alpha: zebracorn42 holds 1180");
    // conv cf5c78765's shape: a message cut short of its closing quote, the next one spliced straight on
    try b.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"Work subtask 4: scaffold the project, or a d");
    // and one whose braces close over a broken string (an unescaped quote)
    try b.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"he said \"hi\"}");
    try testRound(&b, gpa, "c2", "read_file", "b.md", "beta: quokkaplex holds 75");
    s.capture(b.items);
    try tt.expectEqual(@as(usize, 2), s.refused);
    // the ask and both good rounds are stored; neither broken message is
    try tt.expectEqual(@as(usize, 5), s.cur_obj.items.len);
    try tt.expect(std.mem.indexOf(u8, s.cur.items, "or a d") == null);
    try tt.expect(std.mem.indexOf(u8, s.cur.items, "he said") == null);
    try tt.expect(std.mem.indexOf(u8, s.cur.items, "quokkaplex holds 75") != null);
    // capturing again refuses nothing new: the broken messages are accounted for
    s.capture(b.items);
    try tt.expectEqual(@as(usize, 2), s.refused);
    // every line on disk parses
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, dir ++ "/" ++ FILE, gpa, .limited(1 << 20));
    defer gpa.free(raw);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, "\n"), '\n');
    while (lines.next()) |l| try tt.expect(parses(gpa, l));
    // a torn append (a crash mid-write) is skipped on reload, and the good nodes all come back
    try http.appendFile(io, gpa, dir ++ "/" ++ FILE, "{\"role\":\"tool\",\"tool_call_id\":\"c9\",\"content\":\"half writ\n");
    var r = try Store.init(gpa, io, dir, "chat:c3", testGate);
    defer r.deinit();
    try tt.expectEqual(@as(usize, 1), r.torn);
    try tt.expectEqual(@as(u32, 5), r.past_nodes);
    var g = try dag.Graph.fromSpanWith(gpa, r.past.items, .{ .store = true });
    defer g.deinit();
    try tt.expectEqual(@as(usize, 5), g.nodes.items.len);
}

test "cuts count messages, not bytes: a heal that grows the prefix moves nothing" {
    const gpa = tt.allocator;
    var s: Store = .{ .gpa = gpa, .io = undefined, .path = &.{}, .scope = &.{}, .gate = testGate };
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    try testPrefix(&b, gpa);
    s.setPrefix(b.items);
    try testRound(&b, gpa, "c1", "read_file", "a.md", "aaa");
    const before = s.cuts(b.items);
    // a reasoning-echo heal rewrites the prefix's assistant messages in place: bytes move, the count does not
    var healed: std.ArrayListUnmanaged(u8) = .empty;
    defer healed.deinit(gpa);
    try healed.appendSlice(gpa, "{\"role\":\"system\",\"content\":\"you are the veil, healed and longer\"}");
    try healed.appendSlice(gpa, b.items[std.mem.indexOf(u8, b.items, ",{\"role\":\"user\"").?..]);
    const after = s.cuts(healed.items);
    try tt.expectEqual(before.live_obj, after.live_obj);
    try tt.expect(std.mem.startsWith(u8, healed.items[after.prefix_end..], ",{\"role\":\"assistant\""));
    try tt.expectEqual(after.prefix_end, after.live_start); // one round: all of it is live
}
