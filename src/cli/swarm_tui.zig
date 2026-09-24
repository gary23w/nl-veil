//! `veil --swarm "<goal>"` — cast a swarm and watch it work from the terminal, with one line into the whole hive.
//!
//! The screen: a top bar (goal, round, score, cost, elapsed); on the RIGHT one panel per mind — its name and role,
//! the tool it is on, the last result — that lights up when a new act lands, and under them the files the swarm has
//! touched so far; on the LEFT the broker chat: what you type goes to the swarm's one voice (control op `veil`, which
//! answers in first person and hands the instruction to every mind), and the swarm's replies, mind-to-operator
//! messages, goal changes and completion arrive as lines. `/stop`, `/goal <text>`, `/say <text>`, `/quit`.
//!
//! Nothing here is configured: the panels come from the `started` roster and the `cast_plan` roles, the files from
//! the `files` events and the write/edit acts. The screen is redrawn only when something changed (or a flash
//! expires), so an idle swarm costs nothing. The swarm needs no human: it runs continuous by default and the TUI
//! leaves when the run's `stopped` event lands (`cast --follow` waited for a `done` no swarm ever writes).
//!
//! Layout: `Model` + `applyEvent` (the reducer over events.jsonl lines) and `render` (a frame of ANSI text for a
//! given size) are pure and unit-tested; `Term` (raw mode, size, alternate screen) and the loop in `cmd` are the
//! thin I/O shell around them. Operator messages reach the minds at the swarm's next round boundary (run.zig drains
//! control.jsonl at round end), so a reply takes a round or two; the chat says so once.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const Ctx = cli.Ctx;
const bu = @import("../worker/browser/util.zig"); // sleepMs: an OS sleep, never io.sleep

// ------------------------------------------------------------------------------------------ the model

pub const MAX_MINDS = 8;
pub const MAX_FILES = 24;
pub const MAX_CHAT = 120;

pub const Status = enum { idle, thinking, working, done };

fn Str(comptime n: usize) type {
    return struct {
        buf: [n]u8 = [_]u8{0} ** n,
        len: u16 = 0,
        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            const k = clipUtf8(s, n);
            @memcpy(self.buf[0..k], s[0..k]);
            self.len = @intCast(k);
        }
        pub fn str(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
        pub fn eql(self: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, self.str(), s);
        }
    };
}

/// The longest prefix of `s` that fits `max` bytes without splitting a UTF-8 sequence. Pure.
fn clipUtf8(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var k = max;
    while (k > 0 and (s[k] & 0xC0) == 0x80) : (k -= 1) {}
    return k;
}

pub const Mind = struct {
    name: Str(24) = .{},
    role: Str(48) = .{},
    tool: Str(32) = .{},
    args: Str(120) = .{},
    result: Str(200) = .{},
    status: Status = .idle,
    round: u32 = 0,
    acts: u32 = 0,
    changed_ms: i64 = 0,
};

pub const Touched = struct {
    path: Str(64) = .{},
    by: Str(24) = .{},
    changed_ms: i64 = 0,
};

pub const Who = enum { you, veil, mind, system };

pub const ChatLine = struct {
    who: Who = .system,
    from: Str(24) = .{},
    text: Str(400) = .{},
    round: u32 = 0,
};

pub const Model = struct {
    id: Str(96) = .{},
    goal: Str(400) = .{},
    phase: Str(24) = .{},
    round: u32 = 0,
    passed: u32 = 0,
    total: u32 = 0,
    pct: u32 = 0,
    calls: u64 = 0,
    tok_in: u64 = 0,
    tok_out: u64 = 0,
    started_ms: i64 = 0,
    done: bool = false,
    done_reason: Str(40) = .{},
    minds: [MAX_MINDS]Mind = [_]Mind{.{}} ** MAX_MINDS,
    mind_n: usize = 0,
    files: [MAX_FILES]Touched = [_]Touched{.{}} ** MAX_FILES,
    file_n: usize = 0,
    chat: [MAX_CHAT]ChatLine = [_]ChatLine{.{}} ** MAX_CHAT,
    chat_head: usize = 0, // ring: next slot to write
    chat_n: usize = 0,
    said_latency_note: bool = false,

    pub fn mind(self: *Model, name: []const u8) ?*Mind {
        for (self.minds[0..self.mind_n]) |*m| if (m.name.eql(name)) return m;
        if (self.mind_n >= MAX_MINDS or name.len == 0) return null;
        self.minds[self.mind_n] = .{};
        self.minds[self.mind_n].name.set(name);
        self.mind_n += 1;
        return &self.minds[self.mind_n - 1];
    }

    pub fn say(self: *Model, who: Who, from: []const u8, text: []const u8) void {
        const t = std.mem.trim(u8, text, " \r\n\t");
        if (t.len == 0) return;
        var l: ChatLine = .{ .who = who, .round = self.round };
        l.from.set(from);
        l.text.set(t);
        self.chat[self.chat_head] = l;
        self.chat_head = (self.chat_head + 1) % MAX_CHAT;
        if (self.chat_n < MAX_CHAT) self.chat_n += 1;
    }

    /// The i-th chat line from the oldest kept (0) to the newest (chat_n-1).
    pub fn chatAt(self: *const Model, i: usize) *const ChatLine {
        const start = (self.chat_head + MAX_CHAT - self.chat_n) % MAX_CHAT;
        return &self.chat[(start + i) % MAX_CHAT];
    }

    pub fn touch(self: *Model, path: []const u8, by: []const u8, now_ms: i64) void {
        const p = std.mem.trim(u8, path, " \"");
        if (p.len == 0) return;
        // most recent first: move an existing entry to the front, else insert at the front
        var at: usize = self.file_n;
        for (self.files[0..self.file_n], 0..) |*f, i| if (f.path.eql(p)) {
            at = i;
            break;
        };
        if (at == self.file_n) {
            if (self.file_n < MAX_FILES) self.file_n += 1 else at = MAX_FILES - 1;
        }
        var k = at;
        while (k > 0) : (k -= 1) self.files[k] = self.files[k - 1];
        self.files[0] = .{ .changed_ms = now_ms };
        self.files[0].path.set(p);
        self.files[0].by.set(by);
    }
};

/// One string field of a JSON event line into `buf` (unescaped), "" when absent. Allocates transiently.
fn field(gpa: std.mem.Allocator, line: []const u8, key: []const u8, buf: []u8) []const u8 {
    const v = cli.jsonStr(gpa, line, key) orelse return "";
    defer gpa.free(v);
    const k = clipUtf8(v, buf.len);
    @memcpy(buf[0..k], v[0..k]);
    return buf[0..k];
}

fn isEngineVoice(mind: []const u8) bool {
    for ([_][]const u8{ "engine", "veil", "orchestrator", "bench", "judge", "retro" }) |v| if (std.mem.eql(u8, mind, v)) return true;
    return false;
}

/// Fold one events.jsonl line into the model. Unknown kinds are ignored. Pure but for transient allocation.
pub fn applyEvent(m: *Model, gpa: std.mem.Allocator, line: []const u8, now_ms: i64) void {
    var kb: [24]u8 = undefined;
    const kind = field(gpa, line, "kind", &kb);
    if (kind.len == 0) return;
    var b1: [400]u8 = undefined;
    var b2: [400]u8 = undefined;
    var b3: [600]u8 = undefined;
    if (std.mem.eql(u8, kind, "started")) {
        const g = field(gpa, line, "goal", &b1);
        if (g.len > 0) m.goal.set(g);
        // the roster: "minds":[{"name":"nova"},...]
        if (std.mem.indexOf(u8, line, "\"minds\":[")) |at| {
            var i = at;
            while (std.mem.indexOfPos(u8, line, i, "\"name\":\"")) |p| {
                const s = p + "\"name\":\"".len;
                const e = std.mem.indexOfScalarPos(u8, line, s, '"') orelse break;
                _ = m.mind(line[s..e]);
                i = e;
            }
        }
        m.say(.system, "", "swarm started");
    } else if (std.mem.eql(u8, kind, "intent")) {
        const brief = field(gpa, line, "brief", &b3);
        if (brief.len > 0) m.say(.veil, "veil", brief);
    } else if (std.mem.eql(u8, kind, "round")) {
        m.round = @intCast(cli.jsonNum(line, "round"));
    } else if (std.mem.eql(u8, kind, "score")) {
        m.passed = @intCast(cli.jsonNum(line, "passed"));
        m.total = @intCast(cli.jsonNum(line, "total"));
        m.pct = @intCast(cli.jsonNum(line, "pct"));
    } else if (std.mem.eql(u8, kind, "cost")) {
        m.calls += cli.jsonNum(line, "calls");
        m.tok_in = cli.jsonNum(line, "total_in");
        m.tok_out = cli.jsonNum(line, "total_out");
    } else if (std.mem.eql(u8, kind, "phase")) {
        m.phase.set(field(gpa, line, "phase", &b1));
    } else if (std.mem.eql(u8, kind, "act")) {
        var mb: [24]u8 = undefined;
        const who = field(gpa, line, "mind", &mb);
        var tb: [40]u8 = undefined;
        const tool = field(gpa, line, "tool", &tb);
        const args = field(gpa, line, "args", &b2);
        const result = field(gpa, line, "result", &b3);
        const round: u32 = @intCast(cli.jsonNum(line, "round"));
        if (isEngineVoice(who)) {
            if (std.mem.eql(u8, tool, "cast_plan")) {
                // "nova=scout (scout) | ada=implementer (implementer)"
                var it = std.mem.splitSequence(u8, result, "|");
                while (it.next()) |part| {
                    const p = std.mem.trim(u8, part, " ");
                    const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
                    if (m.mind(p[0..eq])) |md| md.role.set(std.mem.trim(u8, p[eq + 1 ..], " "));
                }
            } else if (std.mem.eql(u8, tool, "lineage") or std.mem.eql(u8, tool, "complete") or std.mem.eql(u8, tool, "judge_done")) {
                m.say(.system, "", if (args.len > 0 and std.mem.eql(u8, tool, "lineage")) args else result);
            }
            return;
        }
        const md = m.mind(who) orelse return;
        md.round = round;
        if (std.mem.eql(u8, tool, "thinking")) {
            if (std.mem.eql(u8, args, "starting")) {
                md.status = .thinking;
                if (md.role.len == 0 and result.len > 0) md.role.set(result);
                md.changed_ms = now_ms;
            }
            return; // the model's own text is not an act
        }
        // a real tool call
        md.status = .working;
        md.acts += 1;
        md.changed_ms = now_ms;
        md.tool.set(tool);
        md.args.set(args);
        md.result.set(result);
        if (std.mem.eql(u8, tool, "write_file") or std.mem.eql(u8, tool, "edit_file") or std.mem.eql(u8, tool, "hashline_edit") or std.mem.eql(u8, tool, "delete_file")) {
            var pb: [64]u8 = undefined;
            const path = field(gpa, args, "path", &pb);
            if (path.len > 0) m.touch(path, who, now_ms);
        } else if (std.mem.eql(u8, tool, "send_message")) {
            var tob: [24]u8 = undefined;
            const to = field(gpa, args, "to", &tob);
            if (std.mem.eql(u8, to, "operator") or std.mem.eql(u8, to, "veil")) {
                var txb: [400]u8 = undefined;
                const text = field(gpa, args, "text", &txb);
                if (text.len > 0) m.say(.mind, who, text);
            }
        }
    } else if (std.mem.eql(u8, kind, "tick")) {
        var mb: [24]u8 = undefined;
        if (m.mind(field(gpa, line, "mind", &mb))) |md| {
            md.status = .done;
            md.round = @intCast(cli.jsonNum(line, "round"));
            md.changed_ms = now_ms;
        }
    } else if (std.mem.eql(u8, kind, "mind_msg")) {
        var fb: [24]u8 = undefined;
        var tob: [24]u8 = undefined;
        const frm = field(gpa, line, "frm", &fb);
        const to = field(gpa, line, "to", &tob);
        const text = field(gpa, line, "text", &b3);
        const for_us = std.mem.eql(u8, to, "operator") or std.mem.eql(u8, to, "all") or std.mem.eql(u8, frm, "veil");
        if (for_us and !std.mem.eql(u8, frm, "operator")) m.say(if (std.mem.eql(u8, frm, "veil")) .veil else .mind, frm, text);
    } else if (std.mem.eql(u8, kind, "veil_msg")) {
        var fb: [24]u8 = undefined;
        const frm = field(gpa, line, "frm", &fb);
        if (std.mem.eql(u8, frm, "veil")) m.say(.veil, "veil", field(gpa, line, "text", &b3));
    } else if (std.mem.eql(u8, kind, "control")) {
        m.say(.system, "", "the swarm has taken your message");
    } else if (std.mem.eql(u8, kind, "goal") or std.mem.eql(u8, kind, "resumed")) {
        const g = field(gpa, line, "goal", &b1);
        if (g.len > 0) {
            m.goal.set(g);
            m.say(.system, "", std.fmt.bufPrint(&b3, "goal is now: {s}", .{g}) catch g);
        }
    } else if (std.mem.eql(u8, kind, "complete")) {
        const reason = field(gpa, line, "reason", &b1);
        m.say(.system, "", std.fmt.bufPrint(&b3, "complete ({s}) at {d}% - finishing", .{ reason, cli.jsonNum(line, "pct") }) catch "complete");
    } else if (std.mem.eql(u8, kind, "synthesis")) {
        m.say(.system, "", "final report written: work/synthesis.md");
    } else if (std.mem.eql(u8, kind, "files")) {
        // "files":["a.py","b.py"]
        if (std.mem.indexOf(u8, line, "\"files\":[")) |at| {
            var i = at + "\"files\":[".len;
            while (i < line.len and line[i] != ']') {
                const q1 = std.mem.indexOfScalarPos(u8, line, i, '"') orelse break;
                const q2 = std.mem.indexOfScalarPos(u8, line, q1 + 1, '"') orelse break;
                if (q1 > (std.mem.indexOfScalarPos(u8, line, i, ']') orelse line.len)) break;
                m.touch(line[q1 + 1 .. q2], "", 0); // no flash: a roll-up, not a fresh edit
                i = q2 + 1;
            }
        }
    } else if (std.mem.eql(u8, kind, "stopped")) {
        m.done = true;
        m.done_reason.set(field(gpa, line, "reason", &b1));
        m.say(.system, "", std.fmt.bufPrint(&b3, "swarm stopped: {s} after {d} round(s)", .{ m.done_reason.str(), cli.jsonNum(line, "rounds") }) catch "swarm stopped");
    }
}

// ------------------------------------------------------------------------------------------ the frame

const ESC = "\x1b";
const RESET = ESC ++ "[0m";
const DIM = ESC ++ "[2m";
const BOLD = ESC ++ "[1m";
const REV = ESC ++ "[7m";
const CYAN = ESC ++ "[36m";
const MAGENTA = ESC ++ "[35m";
const GREEN = ESC ++ "[32m";
const YELLOW = ESC ++ "[33m";
pub const FLASH_MS: i64 = 1500;

/// Builds one screen row: text is clipped to the row's remaining columns (one column per codepoint), ANSI codes
/// take none, and `finish` pads to the full width so no stale cell survives a redraw.
const Row = struct {
    out: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    width: usize,
    used: usize = 0,

    fn code(self: *Row, c: []const u8) void {
        self.out.appendSlice(self.gpa, c) catch {};
    }
    fn text(self: *Row, s: []const u8) void {
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (self.used >= self.width) return;
            if (cp.len == 1 and cp[0] < 0x20) {
                self.out.append(self.gpa, ' ') catch {};
            } else self.out.appendSlice(self.gpa, cp) catch {};
            self.used += 1;
        }
    }
    fn finish(self: *Row) void {
        while (self.used < self.width) : (self.used += 1) self.out.append(self.gpa, ' ') catch {};
        self.out.appendSlice(self.gpa, RESET) catch {};
    }
};

/// Visible width in columns of a rendered row (ANSI CSI sequences stripped, one column per codepoint). Pure.
pub fn visibleWidth(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) : (i += 1) {}
            i += 1;
            continue;
        }
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += l;
        n += 1;
    }
    return n;
}

fn statusGlyph(s: Status) []const u8 {
    return switch (s) {
        .idle => "○",
        .thinking => "◐",
        .working => "●",
        .done => "✓",
    };
}

/// Word-wrap `s` into lines of at most `w` columns, calling `emit` for each. Pure.
fn wrapLines(s: []const u8, w: usize, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const u8) void) void {
    if (w == 0) return;
    var rest = s;
    while (rest.len > 0) {
        if (rest.len <= w) {
            emit(ctx, rest);
            return;
        }
        var cut = clipUtf8(rest, w);
        if (std.mem.lastIndexOfScalar(u8, rest[0..cut], ' ')) |sp| {
            if (sp > w / 3) cut = sp;
        }
        emit(ctx, rest[0..cut]);
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
}

pub const Frame = struct {
    cursor_row: usize = 1,
    cursor_col: usize = 1,
};

/// Render the whole screen for a `w` x `h` terminal into `out`: home, every row padded, cursor placed on the input
/// line. Returns where the cursor belongs. Pure over the model and the input text.
pub fn render(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), m: *const Model, input: []const u8, w: usize, h: usize, now_ms: i64) Frame {
    out.appendSlice(gpa, ESC ++ "[?25l" ++ ESC ++ "[H") catch {};
    if (w < 20 or h < 8) {
        var r = Row{ .out = out, .gpa = gpa, .width = w };
        r.text("terminal too small");
        r.finish();
        return .{};
    }
    const body_top: usize = 2;
    const body_h: usize = h - 4; // top bar 2 + input 1 + hint 1
    const two_col = w >= 70;
    const lw: usize = if (two_col) @max(32, w * 45 / 100) else w;
    const rw: usize = if (two_col) w - lw - 1 else 0;

    // ---- top bar
    {
        var r = Row{ .out = out, .gpa = gpa, .width = w };
        var b: [200]u8 = undefined;
        const elapsed_s: i64 = if (m.started_ms > 0) @divTrunc(now_ms - m.started_ms, 1000) else 0;
        r.code(BOLD);
        r.text(" veil swarm ");
        r.code(RESET ++ DIM);
        r.text(m.id.str());
        r.code(RESET);
        r.text(std.fmt.bufPrint(&b, "  round {d}", .{m.round}) catch "");
        if (m.total > 0) r.text(std.fmt.bufPrint(&b, "  score {d}/{d} ({d}%)", .{ m.passed, m.total, m.pct }) catch "");
        if (m.phase.len > 0) r.text(std.fmt.bufPrint(&b, "  {s}", .{m.phase.str()}) catch "");
        r.text(std.fmt.bufPrint(&b, "  {d} calls  {d}k in / {d}k out  {d}:{d:0>2}", .{ m.calls, m.tok_in / 1000, m.tok_out / 1000, @divTrunc(elapsed_s, 60), @mod(elapsed_s, 60) }) catch "");
        if (m.done) {
            r.code(YELLOW);
            r.text("  stopped");
            r.code(RESET);
        }
        r.finish();
        out.appendSlice(gpa, "\r\n") catch {};
        var r2 = Row{ .out = out, .gpa = gpa, .width = w };
        r2.code(DIM);
        r2.text(" goal: ");
        r2.code(RESET);
        r2.text(m.goal.str());
        r2.finish();
        out.appendSlice(gpa, "\r\n") catch {};
    }

    // ---- body rows: left chat (wrapped, newest at the bottom) and right panels, composed row by row
    // right side content, precomputed as fixed rows
    const RightRow = struct { a: []const u8 = "", b: []const u8 = "", style: []const u8 = "", flash: bool = false };
    var right: [80]RightRow = undefined;
    var rn: usize = 0;
    var scratch: [80][160]u8 = undefined;
    if (two_col) {
        const per_mind: usize = 4;
        const files_rows: usize = if (m.file_n > 0) @min(m.file_n + 1, 8) else 0;
        const minds_fit: usize = if (body_h > files_rows) @min(m.mind_n, (body_h - files_rows) / per_mind) else 0;
        for (m.minds[0..minds_fit]) |*md| {
            const flash = md.changed_ms > 0 and now_ms - md.changed_ms < FLASH_MS;
            right[rn] = .{ .a = std.fmt.bufPrint(&scratch[rn], "{s} {s}", .{ statusGlyph(md.status), md.name.str() }) catch "", .b = md.role.str(), .style = BOLD, .flash = flash };
            rn += 1;
            right[rn] = .{ .a = std.fmt.bufPrint(&scratch[rn], "  {s} {s}", .{ md.tool.str(), md.args.str() }) catch "", .style = CYAN, .flash = flash };
            rn += 1;
            const res = md.result.str();
            const c1 = clipUtf8(res, rw -| 4);
            right[rn] = .{ .a = std.fmt.bufPrint(&scratch[rn], "  {s}", .{res[0..c1]}) catch "", .style = DIM, .flash = flash };
            rn += 1;
            right[rn] = .{ .a = std.fmt.bufPrint(&scratch[rn], "  {s}", .{std.mem.trimStart(u8, res[c1..][0..clipUtf8(res[c1..], rw -| 4)], " ")}) catch "", .style = DIM, .flash = flash };
            rn += 1;
        }
        if (files_rows > 0 and rn + files_rows <= right.len) {
            right[rn] = .{ .a = std.fmt.bufPrint(&scratch[rn], "files touched ({d})", .{m.file_n}) catch "", .style = BOLD };
            rn += 1;
            for (m.files[0 .. files_rows - 1]) |*f| {
                right[rn] = .{ .a = std.fmt.bufPrint(&scratch[rn], "  {s}", .{f.path.str()}) catch "", .b = f.by.str(), .style = GREEN, .flash = f.changed_ms > 0 and now_ms - f.changed_ms < FLASH_MS };
                rn += 1;
            }
        }
    }
    // left side: wrap the chat, keep the newest body_h rows
    const Wrapped = struct { who: Who, from: []const u8, text: []const u8, first: bool };
    var left: [400]Wrapped = undefined;
    var ln: usize = 0;
    const text_w = lw -| 2;
    var ci: usize = 0;
    while (ci < m.chat_n and ln < left.len) : (ci += 1) {
        const c = m.chatAt(ci);
        const Emit = struct {
            rows: *[400]Wrapped,
            n: *usize,
            c: *const ChatLine,
            first: bool = true,
            fn put(self: *@This(), piece: []const u8) void {
                if (self.n.* >= self.rows.len) return;
                self.rows[self.n.*] = .{ .who = self.c.who, .from = self.c.from.str(), .text = piece, .first = self.first };
                self.n.* += 1;
                self.first = false;
            }
        };
        var em = Emit{ .rows = &left, .n = &ln, .c = c };
        const prefix_w: usize = if (c.who == .system) 0 else @min(c.from.len + 2, 14);
        wrapLines(c.text.str(), text_w -| prefix_w, &em, Emit.put);
    }
    const lfrom = if (ln > body_h) ln - body_h else 0;

    var row: usize = 0;
    while (row < body_h) : (row += 1) {
        var r = Row{ .out = out, .gpa = gpa, .width = w };
        r.text(" ");
        const li = lfrom + row;
        if (li < ln) {
            const L = left[li];
            const tag: []const u8 = switch (L.who) {
                .you => "you: ",
                .veil => "veil: ",
                .mind => "",
                .system => "· ",
            };
            const col: []const u8 = switch (L.who) {
                .you => CYAN,
                .veil => MAGENTA,
                .mind => GREEN,
                .system => DIM,
            };
            var pb: [32]u8 = undefined;
            const shown_tag: []const u8 = if (L.who == .mind) (std.fmt.bufPrint(&pb, "{s}: ", .{L.from}) catch "") else tag;
            if (L.first) {
                r.code(col);
                r.text(shown_tag);
                r.code(RESET);
            } else {
                var k: usize = 0;
                while (k < @min(shown_tag.len, 14)) : (k += 1) r.text(" ");
            }
            if (L.who == .system) r.code(DIM);
            r.text(L.text);
            r.code(RESET);
        }
        if (two_col) {
            while (r.used < lw) r.text(" ");
            r.code(DIM);
            r.text("│");
            r.code(RESET);
            if (row < rn) {
                const rr = right[row];
                if (rr.flash) r.code(REV);
                r.code(rr.style);
                r.text(" ");
                r.text(rr.a);
                if (rr.b.len > 0) {
                    r.code(RESET);
                    if (rr.flash) r.code(REV);
                    r.code(DIM);
                    r.text("  ");
                    r.text(rr.b);
                }
                r.code(RESET);
                if (rr.flash) {
                    r.code(REV);
                    while (r.used < w) r.text(" ");
                    r.code(RESET);
                }
            }
        }
        r.finish();
        out.appendSlice(gpa, "\r\n") catch {};
    }

    // ---- input + hint
    {
        var r = Row{ .out = out, .gpa = gpa, .width = w };
        r.code(BOLD ++ CYAN);
        r.text(" > ");
        r.code(RESET);
        // keep the caret visible: show the tail of a long line
        const room = w -| 4;
        const tail = if (input.len > room) input[input.len - clipUtf8(input, room) ..] else input;
        r.text(tail);
        const cur_col = r.used + 1;
        r.finish();
        out.appendSlice(gpa, "\r\n") catch {};
        var r2 = Row{ .out = out, .gpa = gpa, .width = w -| 1 }; // never write the last cell of the last row
        r2.code(DIM);
        r2.text(if (m.done) " the swarm has stopped - Enter or /quit to leave" else " Enter speaks to the whole swarm   /stop   /goal <text>   /say <text>   /quit (the swarm keeps running)");
        r2.finish();
        _ = body_top;
        return .{ .cursor_row = h - 1, .cursor_col = cur_col };
    }
}

// ------------------------------------------------------------------------------------------ input

pub const Cmd = union(enum) { veil: []const u8, say: []const u8, goal: []const u8, stop, quit, empty };

/// What a submitted line asks for. Pure.
pub fn classify(line: []const u8) Cmd {
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (t.len == 0) return .empty;
    if (std.mem.eql(u8, t, "/quit") or std.mem.eql(u8, t, "/q") or std.mem.eql(u8, t, "/exit")) return .quit;
    if (std.mem.eql(u8, t, "/stop")) return .stop;
    if (std.mem.startsWith(u8, t, "/goal ")) return .{ .goal = std.mem.trim(u8, t["/goal ".len..], " ") };
    if (std.mem.startsWith(u8, t, "/say ")) return .{ .say = std.mem.trim(u8, t["/say ".len..], " ") };
    return .{ .veil = t };
}

/// The typed line, edited byte by byte: printable UTF-8 appends, Backspace removes one codepoint, Enter submits,
/// and a CSI escape sequence (arrow keys) is swallowed whole. Pure.
pub const Line = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    esc: u8 = 0, // 0 none, 1 saw ESC, 2 inside CSI

    pub fn str(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }
    /// Returns true when the line was submitted (Enter).
    pub fn feed(self: *Line, b: u8) bool {
        switch (self.esc) {
            1 => {
                self.esc = if (b == '[' or b == 'O') 2 else 0;
                return false;
            },
            2 => {
                if (b >= 0x40 and b <= 0x7e) self.esc = 0;
                return false;
            },
            else => {},
        }
        switch (b) {
            0x1b => self.esc = 1,
            '\r', '\n' => return true,
            0x7f, 0x08 => {
                if (self.len > 0) {
                    self.len -= 1;
                    while (self.len > 0 and (self.buf[self.len] & 0xC0) == 0x80) self.len -= 1;
                }
            },
            0x15 => self.len = 0, // Ctrl-U clears
            else => if (b >= 0x20 and self.len < self.buf.len) {
                self.buf[self.len] = b;
                self.len += 1;
            },
        }
        return false;
    }
    pub fn clear(self: *Line) void {
        self.len = 0;
    }
};

// ------------------------------------------------------------------------------------------ the terminal

const Term = struct {
    io: std.Io,
    win_in_mode: u32 = 0,
    win_out_mode: u32 = 0,
    posix_saved: if (builtin.os.tag == .windows) void else ?std.posix.termios = if (builtin.os.tag == .windows) {} else null,
    entered: bool = false,

    const K = if (builtin.os.tag == .windows) struct {
        extern "kernel32" fn GetStdHandle(n: u32) callconv(.c) ?*anyopaque;
        extern "kernel32" fn GetConsoleMode(h: *anyopaque, mode: *u32) callconv(.c) i32;
        extern "kernel32" fn SetConsoleMode(h: *anyopaque, mode: u32) callconv(.c) i32;
        extern "kernel32" fn GetConsoleScreenBufferInfo(h: *anyopaque, info: *CSBI) callconv(.c) i32;
        const CSBI = extern struct { size: [2]i16, cursor: [2]i16, attrs: u16, win: [4]i16, max: [2]i16 };
        const STDIN: u32 = 0xFFFFFFF6;
        const STDOUT: u32 = 0xFFFFFFF5;
        const ENABLE_PROCESSED_INPUT: u32 = 0x1;
        const ENABLE_LINE_INPUT: u32 = 0x2;
        const ENABLE_ECHO_INPUT: u32 = 0x4;
        const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x200;
        const ENABLE_PROCESSED_OUTPUT: u32 = 0x1;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x4;
    } else struct {};

    fn enter(self: *Term) void {
        if (builtin.os.tag == .windows) {
            if (K.GetStdHandle(K.STDIN)) |h| {
                var mode: u32 = 0;
                if (K.GetConsoleMode(h, &mode) != 0) {
                    self.win_in_mode = mode;
                    _ = K.SetConsoleMode(h, (mode & ~(K.ENABLE_LINE_INPUT | K.ENABLE_ECHO_INPUT | K.ENABLE_PROCESSED_INPUT)) | K.ENABLE_VIRTUAL_TERMINAL_INPUT);
                }
            }
            if (K.GetStdHandle(K.STDOUT)) |h| {
                var mode: u32 = 0;
                if (K.GetConsoleMode(h, &mode) != 0) {
                    self.win_out_mode = mode;
                    _ = K.SetConsoleMode(h, mode | K.ENABLE_PROCESSED_OUTPUT | K.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
                }
            }
        } else {
            if (std.posix.tcgetattr(std.posix.STDIN_FILENO)) |t0| {
                self.posix_saved = t0;
                var t = t0;
                t.lflag.ICANON = false;
                t.lflag.ECHO = false;
                t.lflag.ISIG = false; // Ctrl-C arrives as a byte and leaves the screen cleanly
                t.lflag.IEXTEN = false;
                t.iflag.ICRNL = false;
                t.cc[@intFromEnum(std.posix.V.MIN)] = 1;
                t.cc[@intFromEnum(std.posix.V.TIME)] = 0;
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, t) catch {};
            } else |_| {}
        }
        cli.out(ESC ++ "[?1049h" ++ ESC ++ "[H" ++ ESC ++ "[2J", .{});
        self.entered = true;
    }

    fn leave(self: *Term) void {
        if (!self.entered) return;
        cli.out(ESC ++ "[?25h" ++ ESC ++ "[0m" ++ ESC ++ "[?1049l", .{});
        if (builtin.os.tag == .windows) {
            if (self.win_in_mode != 0) if (K.GetStdHandle(K.STDIN)) |h| {
                _ = K.SetConsoleMode(h, self.win_in_mode);
            };
            if (self.win_out_mode != 0) if (K.GetStdHandle(K.STDOUT)) |h| {
                _ = K.SetConsoleMode(h, self.win_out_mode);
            };
        } else if (self.posix_saved) |t| std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, t) catch {};
        self.entered = false;
    }

    /// Columns and rows of the terminal (80x24 when it cannot be asked).
    fn size(self: *Term) [2]usize {
        _ = self;
        if (builtin.os.tag == .windows) {
            if (K.GetStdHandle(K.STDOUT)) |h| {
                var info: K.CSBI = undefined;
                if (K.GetConsoleScreenBufferInfo(h, &info) != 0) {
                    const w: i32 = @as(i32, info.win[2]) - info.win[0] + 1;
                    const hh: i32 = @as(i32, info.win[3]) - info.win[1] + 1;
                    if (w > 0 and hh > 0) return .{ @intCast(w), @intCast(hh) };
                }
            }
        } else {
            var ws: std.posix.winsize = undefined;
            const rc = if (builtin.os.tag == .linux)
                std.os.linux.ioctl(std.posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws))
            else
                @as(usize, @bitCast(@as(isize, std.c.ioctl(std.posix.STDOUT_FILENO, std.c.T.IOCGWINSZ, @intFromPtr(&ws)))));
            if (rc == 0 and ws.col > 0 and ws.row > 0) return .{ ws.col, ws.row };
        }
        return .{ 80, 24 };
    }
};

/// Keys arrive on their own thread (a blocking one-byte read), into a small ring the loop drains.
const Keys = struct {
    mu: std.Io.Mutex = .init,
    ring: [256]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    io: std.Io,

    fn reader(self: *Keys) void {
        const stdin = std.Io.File.stdin();
        while (true) {
            var one: [1]u8 = undefined;
            var bufs = [_][]u8{&one};
            const got = stdin.readStreaming(self.io, &bufs) catch return;
            if (got == 0) return;
            self.mu.lockUncancelable(self.io);
            const next = (self.head + 1) % self.ring.len;
            if (next != self.tail) {
                self.ring[self.head] = one[0];
                self.head = next;
            }
            self.mu.unlock(self.io);
        }
    }
    fn pop(self: *Keys) ?u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.tail == self.head) return null;
        const b = self.ring[self.tail];
        self.tail = (self.tail + 1) % self.ring.len;
        return b;
    }
};

// ------------------------------------------------------------------------------------------ the verb

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn control(ctx: *Ctx, id: []const u8, body: []const u8) bool {
    var pb: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/swarms/{s}/control", .{id}) catch return false;
    const resp = cli.call(ctx, "POST", path, body, 8, false) catch return false;
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    return resp.status >= 200 and resp.status < 300;
}

/// `veil --swarm "<goal>" [--minds N] [--minutes N] [--model M] [--provider P] [--lineage <id>] [--once]`
/// (also `veil swarm ...`). Casts the goal as a CONTINUOUS swarm unless `--once`, then watches it from the terminal.
pub fn cmd(ctx: *Ctx, args: []const []const u8) u8 {
    var goal: []const u8 = "";
    var minutes: []const u8 = "";
    var minds: []const u8 = "";
    var model: []const u8 = "";
    var provider: []const u8 = "";
    var lineage: []const u8 = "";
    var once = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (cli.flagVal(args, &i, a, "--minutes")) |v| minutes = v else if (cli.flagVal(args, &i, a, "--minds")) |v| minds = v else if (cli.flagVal(args, &i, a, "--model")) |v| model = v else if (cli.flagVal(args, &i, a, "--provider")) |v| provider = v else if (cli.flagVal(args, &i, a, "--lineage")) |v| lineage = v else if (std.mem.eql(u8, a, "--once")) {
            once = true;
        } else if (a.len > 0 and a[0] != '-' and goal.len == 0) {
            goal = a;
        }
    }
    if (goal.len == 0) {
        cli.out("usage: veil --swarm \"<goal>\" [--minds N] [--minutes N] [--model M] [--provider P] [--lineage <id>] [--once]\n", .{});
        return 1;
    }
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    defer jb.deinit(ctx.gpa);
    jb.appendSlice(ctx.gpa, "{\"goal\":") catch return 1;
    cli.jstr(ctx.gpa, &jb, goal);
    if (minutes.len > 0) cli.appendNum(ctx.gpa, &jb, "minutes", minutes);
    if (minds.len > 0) cli.appendNum(ctx.gpa, &jb, "minds", minds);
    if (model.len > 0) cli.appendStr(ctx.gpa, &jb, "model", model);
    if (provider.len > 0) cli.appendStr(ctx.gpa, &jb, "provider", provider);
    if (lineage.len > 0) cli.appendStr(ctx.gpa, &jb, "lineage", lineage);
    if (!once) cli.appendStr(ctx.gpa, &jb, "mode", "continuous");
    jb.append(ctx.gpa, '}') catch return 1;
    const resp = cli.call(ctx, "POST", "/api/v1/cast", jb.items, 30, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200 and resp.status != 201) {
        std.debug.print("cast rejected (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 300)] });
        return 1;
    }
    const id = cli.jsonStr(ctx.gpa, resp.body, "id") orelse {
        std.debug.print("cast accepted but no id in reply: {s}\n", .{resp.body[0..@min(resp.body.len, 200)]});
        return 1;
    };
    defer ctx.gpa.free(id);

    var m: Model = .{};
    m.id.set(id);
    m.goal.set(goal);
    m.started_ms = nowMs(ctx.io);
    m.say(.system, "", "cast deployed - waiting for the swarm to start");

    var keys = Keys{ .io = ctx.io };
    const th = std.Thread.spawn(.{}, Keys.reader, .{&keys}) catch null;
    if (th) |t| t.detach();
    var term = Term{ .io = ctx.io };
    term.enter();
    defer term.leave();

    var line: Line = .{};
    var frame: std.ArrayListUnmanaged(u8) = .empty;
    defer frame.deinit(ctx.gpa);
    var pending: std.ArrayListUnmanaged(u8) = .empty; // a page can end mid-line; keep the tail for the next one
    defer pending.deinit(ctx.gpa);
    var from: usize = 0;
    var last_poll: i64 = 0;
    var last_size: [2]usize = .{ 0, 0 };
    var dirty = true;
    var done_at: i64 = 0;
    var gone = false;

    while (true) {
        const now = nowMs(ctx.io);
        // ---- events
        if (!m.done and now - last_poll >= 500) {
            last_poll = now;
            var pb: [200]u8 = undefined;
            if (std.fmt.bufPrint(&pb, "/api/v1/swarms/{s}/events?from={d}", .{ id, from })) |path| {
                if (cli.call(ctx, "GET", path, null, 8, false)) |r| {
                    defer if (r.body.len > 0) ctx.gpa.free(r.body);
                    if (r.status == 200 and r.body.len > 0) {
                        from += r.body.len;
                        pending.appendSlice(ctx.gpa, r.body) catch {};
                        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
                            applyEvent(&m, ctx.gpa, pending.items[0..nl], now);
                            std.mem.copyForwards(u8, pending.items, pending.items[nl + 1 ..]);
                            pending.items.len -= nl + 1;
                        }
                        dirty = true;
                    } else if (r.status == 404) {
                        gone = true;
                        m.done = true;
                        m.say(.system, "", "the swarm is gone from the server");
                        dirty = true;
                    }
                } else |_| {}
            } else |_| {}
            if (m.done and done_at == 0) done_at = now;
        }
        // ---- keys
        while (keys.pop()) |b| {
            if (b == 3) { // Ctrl-C: leave, the swarm keeps running
                term.leave();
                cli.out("left the swarm running: {s}\n  watch:  veil events {s} --follow\n  stop:   veil stop {s}\n", .{ id, id, id });
                return 0;
            }
            if (line.feed(b)) {
                const c = classify(line.str());
                switch (c) {
                    .empty => {},
                    .quit => {
                        term.leave();
                        if (!m.done) cli.out("left the swarm running: {s}\n  watch:  veil events {s} --follow\n  stop:   veil stop {s}\n", .{ id, id, id });
                        return 0;
                    },
                    .stop => {
                        m.say(.you, "", "/stop");
                        m.say(.system, "", if (control(ctx, id, "{\"op\":\"stop\"}")) "stop requested - the swarm finishes its round" else "stop request failed");
                    },
                    .goal => |g| {
                        var b2: std.ArrayListUnmanaged(u8) = .empty;
                        defer b2.deinit(ctx.gpa);
                        b2.appendSlice(ctx.gpa, "{\"op\":\"set_goal\",\"goal\":") catch {};
                        cli.jstr(ctx.gpa, &b2, g);
                        b2.append(ctx.gpa, '}') catch {};
                        m.say(.you, "", line.str());
                        m.say(.system, "", if (control(ctx, id, b2.items)) "new goal queued for the next round" else "could not send the goal");
                    },
                    .say, .veil => |text| {
                        var b2: std.ArrayListUnmanaged(u8) = .empty;
                        defer b2.deinit(ctx.gpa);
                        b2.appendSlice(ctx.gpa, if (c == .say) "{\"op\":\"say\",\"text\":" else "{\"op\":\"veil\",\"text\":") catch {};
                        cli.jstr(ctx.gpa, &b2, text);
                        b2.append(ctx.gpa, '}') catch {};
                        m.say(.you, "", text);
                        if (!control(ctx, id, b2.items)) {
                            m.say(.system, "", "could not reach the swarm");
                        } else if (!m.said_latency_note) {
                            m.said_latency_note = true;
                            m.say(.system, "", "the swarm reads this at its next round boundary; its answer lands here");
                        }
                    },
                }
                line.clear();
            }
            dirty = true;
        }
        // ---- size
        const sz = term.size();
        if (sz[0] != last_size[0] or sz[1] != last_size[1]) {
            last_size = sz;
            dirty = true;
            cli.out(ESC ++ "[2J", .{});
        }
        // ---- a flash that expires needs one more draw
        if (!dirty) {
            for (m.minds[0..m.mind_n]) |*md| if (md.changed_ms > 0 and now - md.changed_ms >= FLASH_MS and now - md.changed_ms < FLASH_MS + 120) {
                dirty = true;
            };
        }
        if (dirty) {
            frame.clearRetainingCapacity();
            const f = render(ctx.gpa, &frame, &m, line.str(), sz[0], sz[1], now);
            var cb: [24]u8 = undefined;
            frame.appendSlice(ctx.gpa, std.fmt.bufPrint(&cb, ESC ++ "[{d};{d}H" ++ ESC ++ "[?25h", .{ f.cursor_row, f.cursor_col }) catch "") catch {};
            cli.out("{s}", .{frame.items});
            dirty = false;
        }
        if (m.done and gone) break;
        bu.sleepMs(40);
    }
    term.leave();
    return 0;
}

// ------------------------------------------------------------------------------------------ tests

const tt = std.testing;

test "swarm tui: the reducer builds panels, roles, files and chat from the event stream, and ends on stopped" {
    const gpa = tt.allocator;
    var m: Model = .{};
    applyEvent(&m, gpa, "{\"seq\":1,\"t\":1,\"kind\":\"started\",\"swarm\":\"x\",\"goal\":\"build money.py\",\"minds\":[{\"name\":\"nova\"},{\"name\":\"ada\"}]}", 1000);
    try tt.expectEqual(@as(usize, 2), m.mind_n);
    try tt.expectEqualStrings("build money.py", m.goal.str());
    applyEvent(&m, gpa, "{\"kind\":\"act\",\"mind\":\"orchestrator\",\"round\":1,\"tool\":\"cast_plan\",\"args\":\"\",\"result\":\"nova=scout (scout) | ada=implementer (implementer)\"}", 1000);
    try tt.expectEqualStrings("scout (scout)", m.minds[0].role.str());
    applyEvent(&m, gpa, "{\"kind\":\"round\",\"round\":1}", 1000);
    applyEvent(&m, gpa, "{\"kind\":\"act\",\"mind\":\"ada\",\"round\":1,\"tool\":\"thinking\",\"args\":\"starting\",\"result\":\"implementer\"}", 1000);
    try tt.expectEqual(Status.thinking, m.minds[1].status);
    applyEvent(&m, gpa, "{\"kind\":\"act\",\"mind\":\"ada\",\"round\":1,\"tool\":\"write_file\",\"args\":\"{\\\"path\\\": \\\"money.py\\\", \\\"content\\\": \\\"x\\\"}\",\"result\":\"wrote money.py - 40 bytes\"}", 2000);
    try tt.expectEqual(Status.working, m.minds[1].status);
    try tt.expectEqualStrings("write_file", m.minds[1].tool.str());
    try tt.expectEqual(@as(usize, 1), m.file_n);
    try tt.expectEqualStrings("money.py", m.files[0].path.str());
    try tt.expectEqualStrings("ada", m.files[0].by.str());
    try tt.expectEqual(@as(i64, 2000), m.files[0].changed_ms);
    // a mind's own text is not an act; a tick ends its round
    applyEvent(&m, gpa, "{\"kind\":\"act\",\"mind\":\"ada\",\"round\":1,\"tool\":\"thinking\",\"args\":\"I will now\",\"result\":\"\"}", 2100);
    try tt.expectEqualStrings("write_file", m.minds[1].tool.str());
    applyEvent(&m, gpa, "{\"kind\":\"tick\",\"mind\":\"ada\",\"round\":1,\"dt\":3}", 2200);
    try tt.expectEqual(Status.done, m.minds[1].status);
    // the swarm's voice and a mind's message to the operator reach the chat; a mind-to-mind message does not
    const before = m.chat_n;
    applyEvent(&m, gpa, "{\"kind\":\"veil_msg\",\"frm\":\"veil\",\"text\":\"We are on it.\",\"round\":1}", 2300);
    applyEvent(&m, gpa, "{\"kind\":\"mind_msg\",\"frm\":\"nova\",\"to\":\"operator\",\"text\":\"found the checker\",\"round\":1}", 2300);
    applyEvent(&m, gpa, "{\"kind\":\"mind_msg\",\"frm\":\"nova\",\"to\":\"ada\",\"text\":\"private\",\"round\":1}", 2300);
    try tt.expectEqual(before + 2, m.chat_n);
    try tt.expectEqual(Who.veil, m.chatAt(m.chat_n - 2).who);
    try tt.expectEqualStrings("found the checker", m.chatAt(m.chat_n - 1).text.str());
    applyEvent(&m, gpa, "{\"kind\":\"score\",\"round\":1,\"status\":\"ok\",\"passed\":7,\"total\":8,\"pct\":87,\"tier\":1}", 2400);
    applyEvent(&m, gpa, "{\"kind\":\"cost\",\"round\":1,\"in\":100,\"out\":10,\"calls\":4,\"total_in\":100,\"total_out\":10}", 2400);
    applyEvent(&m, gpa, "{\"kind\":\"files\",\"n\":2,\"bytes\":9,\"round\":1,\"files\":[\"money.py\",\"test_money.py\"]}", 2500);
    try tt.expectEqual(@as(usize, 2), m.file_n);
    try tt.expectEqual(@as(u32, 87), m.pct);
    try tt.expectEqual(@as(u64, 4), m.calls);
    try tt.expect(!m.done);
    applyEvent(&m, gpa, "{\"kind\":\"stopped\",\"reason\":\"completed\",\"rounds\":3}", 3000);
    try tt.expect(m.done);
    try tt.expectEqualStrings("completed", m.done_reason.str());
}

test "swarm tui: a frame fits the terminal at every size, names what matters, and one column below 70" {
    const gpa = tt.allocator;
    var m: Model = .{};
    m.id.set("abc123");
    m.goal.set("write a very long goal that certainly does not fit in one line of an eighty column terminal at all no");
    _ = m.mind("nova");
    m.minds[0].role.set("scout");
    m.minds[0].tool.set("web_search");
    m.minds[0].args.set("{\"q\": \"decimal rounding\"}");
    m.minds[0].result.set("3 results");
    m.minds[0].status = .working;
    m.minds[0].changed_ms = 900;
    m.touch("money.py", "ada", 950);
    var k: usize = 0;
    while (k < 40) : (k += 1) m.say(.veil, "veil", "a reply from the swarm that wraps across the chat column more than once for sure");
    m.say(.you, "", "make it faster");
    for ([_][2]usize{ .{ 100, 30 }, .{ 80, 24 }, .{ 60, 12 }, .{ 200, 50 }, .{ 25, 9 } }) |sz| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        const f = render(gpa, &out, &m, "hello swarm", sz[0], sz[1], 1000);
        try tt.expectEqual(sz[1] - 1, f.cursor_row);
        var rows: usize = 0;
        var it = std.mem.splitSequence(u8, out.items, "\r\n");
        while (it.next()) |row| : (rows += 1) {
            try tt.expect(visibleWidth(row) <= sz[0]);
        }
        try tt.expectEqual(sz[1], rows);
        try tt.expect(std.mem.indexOf(u8, out.items, "abc123") != null);
        try tt.expect(std.mem.indexOf(u8, out.items, "hello swarm") != null);
        try tt.expect(std.mem.indexOf(u8, out.items, "make it faster") != null);
        if (sz[0] >= 70) {
            try tt.expect(std.mem.indexOf(u8, out.items, "nova") != null);
            try tt.expect(std.mem.indexOf(u8, out.items, "money.py") != null);
            try tt.expect(std.mem.indexOf(u8, out.items, REV) != null); // the fresh act and file flash
        } else {
            try tt.expect(std.mem.indexOf(u8, out.items, "│") == null);
        }
    }
    // the flash is over FLASH_MS after the newest change (the file, at 950)
    var out2: std.ArrayListUnmanaged(u8) = .empty;
    defer out2.deinit(gpa);
    _ = render(gpa, &out2, &m, "", 100, 30, 950 + FLASH_MS + 1);
    try tt.expect(std.mem.indexOf(u8, out2.items, REV) == null);
}

test "swarm tui: the line editor and the command grammar" {
    var l: Line = .{};
    for ("\x1b[A") |b| try tt.expect(!l.feed(b)); // an arrow key is swallowed
    for ("hi there") |b| try tt.expect(!l.feed(b));
    _ = l.feed(0x7f);
    try tt.expectEqualStrings("hi ther", l.str());
    for ("é") |b| _ = l.feed(b);
    _ = l.feed(0x08);
    try tt.expectEqualStrings("hi ther", l.str()); // a backspace removes the whole codepoint
    try tt.expect(l.feed('\r'));
    try tt.expectEqual(Cmd.quit, classify("/quit"));
    try tt.expectEqual(Cmd.stop, classify(" /stop "));
    try tt.expectEqual(Cmd.empty, classify("   "));
    try tt.expectEqualStrings("finish faster", classify("/goal finish faster").goal);
    try tt.expectEqualStrings("hello", classify("/say hello").say);
    try tt.expectEqualStrings("how is it going?", classify("how is it going?").veil);
    try tt.expectEqual(@as(usize, 5), visibleWidth("\x1b[1m\x1b[36mhello\x1b[0m"));
}
