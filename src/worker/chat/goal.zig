//! GOAL MODE — the auto-loop, given a goal it keeps, a record of what it tried, and a measure of whether it helped.
//!
//! The afk tier proved the idea (a loop that writes its own next step and keeps going) and showed what it lacked:
//! no stored goal (the "goal" was whatever the first message said), no record of iterations (so the picker could
//! only avoid repeating the LAST step), no measure of whether a step improved anything (so "next best" was a
//! guess), and no reason to stop except a text match on DONE or the human. This file is those four things:
//!
//!   goal.json       one per conversation: the goal's text, status, budget, optional check command, the iteration
//!                   counters and the best measured score
//!   goal_log.jsonl  one row per iteration: the step taken, the outcome (improved / same / regressed), the evidence
//!   /goal ...       the command, parsed at the head of every chat turn, so the desk, the web app and `veil chat`
//!                   all have it: `/goal <text> [--forever] [--budget N]`, `/goal` (status), `/goal stop`,
//!                   `/goal resume`, `/goal budget N`, `/goal check <command>`, `/goal forever`
//!
//! One iteration is pick -> do -> measure -> record. The PICK question shows the log and asks for the best
//! improvement not yet tried. The MEASURE is a judge that reads the iteration's real tool results (never the
//! assistant's claims) and answers IMPROVED / SAME / REGRESSED with a score when a tool printed one; when two
//! scores exist the comparison is the engine's own arithmetic, not the judge's word. The loop STOPS on its own
//! when the goal is achieved, when the budget is spent, or on a PLATEAU (three iterations in a row that improved
//! nothing) - the end state afk never had. A `--forever` goal (and the afk toggle, which now means exactly that)
//! keeps the old promise: no finish line, no plateau stop, only the human ends it.
//!
//! Everything here is pure or plain file I/O; the model calls and the turn loop stay in engine.zig.

const std = @import("std");

/// Consecutive non-improving iterations that end a finite goal loop.
pub const PLATEAU: u32 = 3;
/// Iterations a finite goal may spend unless `--budget` / `/goal budget` says otherwise.
pub const BUDGET_DEFAULT: u32 = 25;
/// The most iterations one turn walks, whatever the budget (a turn is also bounded by its token ceiling).
pub const TURN_STEPS_MAX: u32 = 200;

pub const Status = enum { active, achieved, plateau, budget, stopped };
pub const Outcome = enum { improved, same, regressed };

pub const Goal = struct {
    text: []const u8 = "",
    status: Status = .active,
    forever: bool = false,
    budget: u32 = BUDGET_DEFAULT, // total iterations; 0 = unlimited
    check: []const u8 = "", // a command whose output measures the goal; "" = the judge reads what ran
    iteration: u32 = 0,
    improved: u32 = 0,
    flat: u32 = 0, // consecutive iterations that did not improve
    best_num: i64 = -1, // best measured score, best_num/best_den; den <= 0 = nothing measured yet
    best_den: i64 = 0,
    created: i64 = 0,
};

pub const Verdict = struct {
    outcome: Outcome = .same,
    num: i64 = -1,
    den: i64 = 0, // <= 0 = the judge found no score
    evidence: []const u8 = "",
};

pub const Row = struct {
    i: u32 = 0,
    t: i64 = 0,
    outcome: Outcome = .same,
    step: []const u8 = "",
    evidence: []const u8 = "",
    num: i64 = -1,
    den: i64 = 0,
};

// ------------------------------------------------------------------------------------------ the command

pub const Start = struct { text: []const u8, forever: bool = false, budget: ?u32 = null, check: []const u8 = "" };
pub const Cmd = union(enum) {
    none,
    status,
    stop,
    go_on, // /goal resume
    forever_on,
    start: Start,
    budget: u32,
    check: []const u8,
};

fn isAny(s: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    return false;
}

/// What a chat message asks of goal mode. `.none` for anything that is not a `/goal` command. A start's text is
/// built in `buf` (flags removed); every other slice borrows from `text`. Pure.
pub fn parseCommand(text: []const u8, buf: []u8) Cmd {
    const t = std.mem.trim(u8, text, " \r\n\t");
    if (!std.mem.startsWith(u8, t, "/goal")) return .none;
    const rest = t["/goal".len..];
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\n' and rest[0] != '\t') return .none; // "/goals", "/goalpost"
    const r = std.mem.trim(u8, rest, " \r\n\t");
    if (r.len == 0 or isAny(r, &.{ "status", "show", "?" })) return .status;
    if (isAny(r, &.{ "stop", "off", "clear", "cancel", "pause", "end" })) return .stop;
    if (isAny(r, &.{ "resume", "continue", "go", "on" })) return .go_on;
    if (isAny(r, &.{ "forever", "--forever" })) return .forever_on;
    if (std.ascii.startsWithIgnoreCase(r, "budget ")) {
        const n = std.fmt.parseInt(u32, std.mem.trim(u8, r["budget ".len..], " \t"), 10) catch return .status;
        return .{ .budget = n };
    }
    if (std.ascii.startsWithIgnoreCase(r, "check ")) {
        const c = std.mem.trim(u8, r["check ".len..], " \t`");
        return if (c.len == 0) .status else .{ .check = c };
    }
    // a new goal: the text, minus its flags. `--check` takes the REST of the line (a command has spaces).
    var s: Start = .{ .text = "" };
    var body = r;
    if (std.mem.indexOf(u8, r, "--check ")) |at| {
        if (at == 0 or r[at - 1] == ' ') {
            s.check = std.mem.trim(u8, r[at + "--check ".len ..], " \t`");
            body = r[0..at];
        }
    }
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, body, ' ');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "--forever")) {
            s.forever = true;
            continue;
        }
        if (std.mem.eql(u8, tok, "--budget")) {
            if (it.next()) |v| s.budget = std.fmt.parseInt(u32, v, 10) catch s.budget;
            continue;
        }
        if (n + tok.len + 1 > buf.len) break;
        if (n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n .. n + tok.len], tok);
        n += tok.len;
    }
    if (n < 3) return .status; // "/goal --forever" with no text is a question, not a goal
    s.text = buf[0..n];
    return .{ .start = s };
}

// ------------------------------------------------------------------------------------------ the stored goal

/// The conversation's goal for one turn: loaded from goal.json, changed, saved. Its strings live in its arena.
pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    g: ?Goal = null,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        _ = gpa; // the arena remembers its own backing allocator; the parameter keeps call sites uniform
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }
    fn alloc(self: *State, gpa: std.mem.Allocator) std.mem.Allocator {
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(gpa);
        return self.arena.?.allocator();
    }
    pub fn isActive(self: *const State) bool {
        return if (self.g) |g| g.status == .active and g.text.len > 0 else false;
    }

    pub fn load(self: *State, gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8) void {
        var pb: [900]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/goal.json", .{conv_dir}) catch return;
        const body = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10)) catch return;
        defer gpa.free(body);
        self.g = std.json.parseFromSliceLeaky(Goal, self.alloc(gpa), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    }

    pub fn save(self: *const State, gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8) void {
        const g = self.g orelse return;
        var pb: [900]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/goal.json", .{conv_dir}) catch return;
        const body = std.json.Stringify.valueAlloc(gpa, g, .{ .whitespace = .indent_2 }) catch return;
        defer gpa.free(body);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch {};
    }

    /// Begin a new goal (replacing any old one; its log is kept, the counters restart).
    pub fn start(self: *State, gpa: std.mem.Allocator, text: []const u8, forever: bool, budget: ?u32, now: i64) void {
        const a = self.alloc(gpa);
        self.g = .{
            .text = a.dupe(u8, std.mem.trim(u8, text, " \r\n\t")) catch "",
            .forever = forever,
            .budget = budget orelse (if (forever) 0 else BUDGET_DEFAULT),
            .created = now,
        };
    }

    pub fn setCheck(self: *State, gpa: std.mem.Allocator, cmd: []const u8) void {
        if (self.g) |*g| g.check = self.alloc(gpa).dupe(u8, cmd) catch g.check;
    }

    /// Iterations this turn may still walk.
    pub fn stepsLeft(self: *const State) usize {
        const g = self.g orelse return 1;
        if (g.budget == 0) return TURN_STEPS_MAX;
        return @max(1, @min(TURN_STEPS_MAX, g.budget -| g.iteration));
    }

    /// Fold one measured iteration into the goal and its log. Returns why the loop must stop now, or null.
    pub fn record(self: *State, gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8, step: []const u8, v: Verdict, now: i64) ?Status {
        const g = if (self.g) |*x| x else return null;
        const outcome = decide(g.*, v);
        g.iteration += 1;
        if (outcome == .improved) {
            g.improved += 1;
            g.flat = 0;
        } else g.flat += 1;
        if (v.den > 0 and (g.best_den <= 0 or v.num * g.best_den > g.best_num * v.den)) {
            g.best_num = v.num;
            g.best_den = v.den;
        }
        appendRow(gpa, io, conv_dir, .{ .i = g.iteration, .t = now, .outcome = outcome, .step = clip(step, 300), .evidence = clip(v.evidence, 240), .num = v.num, .den = v.den });
        var stop: ?Status = null;
        if (!g.forever and g.flat >= PLATEAU) stop = .plateau;
        if (stop == null and g.budget > 0 and g.iteration >= g.budget) stop = .budget;
        if (stop) |s| g.status = s;
        self.save(gpa, io, conv_dir);
        return stop;
    }

    pub fn finish(self: *State, gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8, why: Status) void {
        if (self.g) |*g| g.status = why;
        self.save(gpa, io, conv_dir);
    }

    /// Apply a non-start command and write the reply the user reads into `buf`.
    pub fn apply(self: *State, gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8, cmd: Cmd, buf: []u8) []const u8 {
        if (self.g == null) return "No goal is set for this conversation. Start one with: /goal <what to achieve>  (add --forever to run until you stop it, --budget N to cap the iterations)";
        const g = &self.g.?;
        switch (cmd) {
            .stop => if (g.status == .active) {
                g.status = .stopped; // a goal that already ended keeps the reason it ended
            },
            .forever_on => {
                g.forever = true;
                if (g.status != .stopped) g.status = .active;
            },
            .budget => |n| {
                g.budget = n;
                if (g.status == .budget and (n == 0 or n > g.iteration)) g.status = .active;
            },
            .check => |c| self.setCheck(gpa, c),
            else => {},
        }
        self.save(gpa, io, conv_dir);
        return statusText(buf, self.g.?);
    }
};

fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var k = max;
    while (k > 0 and (s[k] & 0xC0) == 0x80) : (k -= 1) {}
    return s[0..k];
}

/// The final outcome of an iteration: when this iteration and an earlier one both carry a score, the comparison
/// is arithmetic (num/den against the best so far); otherwise the judge's word stands. Pure.
pub fn decide(g: Goal, v: Verdict) Outcome {
    if (v.den > 0 and g.best_den > 0) {
        const cur = v.num * g.best_den;
        const best = g.best_num * v.den;
        return if (cur > best) .improved else if (cur < best) .regressed else .same;
    }
    return v.outcome;
}

// ------------------------------------------------------------------------------------------ the log

fn appendRow(gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8, row: Row) void {
    var pb: [900]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/goal_log.jsonl", .{conv_dir}) catch return;
    const line = std.json.Stringify.valueAlloc(gpa, row, .{}) catch return;
    defer gpa.free(line);
    const old = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch &[_]u8{};
    defer if (old.len > 0) gpa.free(old);
    const all = std.mem.concat(gpa, u8, &.{ old, line, "\n" }) catch return;
    defer gpa.free(all);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = all }) catch {};
}

/// The newest `max` iterations as text the picker reads, oldest first:
///   "  4. improved: <step> (<evidence>) [12/14]". "" when there are none. Caller frees a non-empty result.
pub fn logTail(gpa: std.mem.Allocator, io: std.Io, conv_dir: []const u8, max: usize) []u8 {
    var pb: [900]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/goal_log.jsonl", .{conv_dir}) catch return &[_]u8{};
    const body = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return &[_]u8{};
    defer gpa.free(body);
    return formatLog(gpa, body, max);
}

/// logTail over the file's text. Pure but for allocation.
pub fn formatLog(gpa: std.mem.Allocator, body: []const u8, max: usize) []u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| {
        if (std.mem.trim(u8, l, " \r\t").len > 2) lines.append(gpa, l) catch return &[_]u8{};
    }
    const from = if (lines.items.len > max) lines.items.len - max else 0;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for (lines.items[from..]) |l| {
        const r = std.json.parseFromSliceLeaky(Row, arena.allocator(), l, .{ .ignore_unknown_fields = true }) catch continue;
        out.print(gpa, "  {d}. {s}: {s}", .{ r.i, @tagName(r.outcome), clip(r.step, 200) }) catch break;
        if (r.evidence.len > 0) out.print(gpa, " ({s})", .{clip(r.evidence, 140)}) catch break;
        if (r.den > 0) out.print(gpa, " [{d}/{d}]", .{ r.num, r.den }) catch break;
        out.append(gpa, '\n') catch break;
    }
    return out.toOwnedSlice(gpa) catch &[_]u8{};
}

// ------------------------------------------------------------------------------------------ the prompts

/// The pick question: the log, and the best improvement not yet in it. A finite goal may answer DONE; a forever
/// goal has no finished state. `memory_rule` is the engine's standing rule that a memory change is never a step.
pub fn pickQuestion(buf: []u8, g: Goal, log: []const u8, memory_rule: []const u8) []const u8 {
    var cb: [400]u8 = undefined;
    const check: []const u8 = if (g.check.len > 0) (std.fmt.bufPrint(&cb, " End the instruction with: then run `{s}` and report its output.", .{clip(g.check, 300)}) catch "") else "";
    const tail: []const u8 = if (g.forever)
        "There is no finished state here and DONE is not an answer: when the obvious work is done, name the most valuable hardening, verification or extension not yet tried. Reply with ONLY that instruction."
    else
        "Reply with ONLY that instruction, or reply exactly DONE if the goal is fully achieved and a tool result in the conversation shows it.";
    return std.fmt.bufPrint(buf,
        \\This is a GOAL LOOP: every iteration makes ONE improvement toward the goal, and the engine then measures whether it helped.
        \\ITERATIONS SO FAR (never repeat one; if one regressed, undoing or fixing it may be the best next step):
        \\{s}
        \\What is the single BEST next improvement - the one most likely to move the goal forward - that is NOT in that list? Prefer a step whose effect a tool can show (a test, a build, a command's output, a measured number). A CLAIM OF WORK IS NOT WORK. {s}.{s} {s}
    , .{ if (log.len > 0) clip(log, 3000) else "  (none yet)\n", memory_rule, check, tail }) catch "What is the single best next improvement toward the goal that has not been tried? Reply with ONLY that instruction, or exactly DONE.";
}

pub const JUDGE_SYSTEM =
    "You grade ONE iteration of an autonomous improvement loop from the tail of its transcript. Tool rows are REAL " ++
    "results (exit codes, test counts, command output, file writes); the assistant's prose is only a claim. Decide " ++
    "whether THIS iteration moved the goal forward, using tool results alone. IMPROVED needs a tool result showing " ++
    "that something now works, exists, or measures better than before. A change with nothing run to show its " ++
    "effect is SAME. A new failure, a broken build, or a worse measurement is REGRESSED. Do not call tools.";

/// The judge's one-line answer format. `check` names the command whose output is the measure, when the goal has one.
pub fn judgeQuestion(buf: []u8, goal_text: []const u8, check: []const u8) []const u8 {
    var cb: [420]u8 = undefined;
    const c: []const u8 = if (check.len > 0) (std.fmt.bufPrint(&cb, " The goal's measure is the output of `{s}`: read the score from its latest result.", .{clip(check, 300)}) catch "") else "";
    return std.fmt.bufPrint(buf,
        \\The goal: {s}
        \\Grade the LAST iteration.{s} Reply with exactly one line:
        \\IMPROVED | score: <passed>/<total> | evidence: <the tool result that shows it, in a few words>
        \\using SAME or REGRESSED in place of IMPROVED when that is the truth, and `score: none` when no tool result in this iteration printed a count that measures the goal (tests passed, checks green, items done out of a total).
    , .{ clip(goal_text, 500), c }) catch "Reply with one line: IMPROVED | SAME | REGRESSED, then | score: <n>/<m> or none | evidence: <tool result>";
}

/// Parse the judge's line. Anything unreadable is SAME with no score, so a confused judge can never count as
/// progress. `evid` receives the evidence text. Pure.
pub fn parseVerdict(reply: []const u8, evid: []u8) Verdict {
    var v: Verdict = .{};
    var up_buf: [64]u8 = undefined;
    const head = std.mem.trim(u8, reply, " \r\n\t`*\"'-");
    const up = std.ascii.upperString(&up_buf, head[0..@min(head.len, up_buf.len)]);
    if (std.mem.startsWith(u8, up, "IMPROVED")) v.outcome = .improved else if (std.mem.startsWith(u8, up, "REGRESSED")) v.outcome = .regressed else v.outcome = .same;
    if (indexOfIgnoreCase(reply, "score:")) |at| {
        const s = std.mem.trimStart(u8, reply[at + "score:".len ..], " \t");
        var i: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i > 0 and i < s.len and s[i] == '/') {
            var j = i + 1;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            const num = std.fmt.parseInt(i64, s[0..i], 10) catch -1;
            const den = std.fmt.parseInt(i64, s[i + 1 .. j], 10) catch 0;
            if (num >= 0 and den > 0 and num <= den) {
                v.num = num;
                v.den = den;
            }
        }
    }
    if (indexOfIgnoreCase(reply, "evidence:")) |at| {
        const e = std.mem.trim(u8, reply[at + "evidence:".len ..], " \r\n\t");
        const line = if (std.mem.indexOfScalar(u8, e, '\n')) |nl| e[0..nl] else e;
        const n = clip(line, evid.len).len;
        @memcpy(evid[0..n], line[0..n]);
        v.evidence = evid[0..n];
    }
    return v;
}

// ------------------------------------------------------------------------------------------ what the user reads

fn statusWord(s: Status) []const u8 {
    return switch (s) {
        .active => "active",
        .achieved => "achieved",
        .plateau => "ended: no further improvement found",
        .budget => "ended: budget spent",
        .stopped => "stopped",
    };
}

/// One line of goal status. Pure.
pub fn statusText(buf: []u8, g: Goal) []const u8 {
    var bb: [48]u8 = undefined;
    var sb: [48]u8 = undefined;
    var cb: [340]u8 = undefined;
    const budget: []const u8 = if (g.budget == 0) "no iteration limit" else (std.fmt.bufPrint(&bb, "of {d}", .{g.budget}) catch "");
    const score: []const u8 = if (g.best_den > 0) (std.fmt.bufPrint(&sb, ", best {d}/{d}", .{ g.best_num, g.best_den }) catch "") else "";
    const check: []const u8 = if (g.check.len > 0) (std.fmt.bufPrint(&cb, " Measured by `{s}`.", .{clip(g.check, 300)}) catch "") else "";
    return std.fmt.bufPrint(buf, "Goal ({s}{s}): {s}\nIteration {d} {s}, {d} improved{s}.{s}\n/goal stop ends it, /goal resume continues it, /goal budget N and /goal check <command> tune it.", .{
        statusWord(g.status), if (g.forever) ", runs until you stop it" else "", clip(g.text, 400), g.iteration, budget, g.improved, score, check,
    }) catch "goal status unavailable";
}

/// What the loop says when it ends on its own. Pure.
pub fn summaryText(buf: []u8, g: Goal, why: Status) []const u8 {
    var sb: [48]u8 = undefined;
    const score: []const u8 = if (g.best_den > 0) (std.fmt.bufPrint(&sb, " Best measured: {d}/{d}.", .{ g.best_num, g.best_den }) catch "") else "";
    const reason: []const u8 = switch (why) {
        .achieved => "the goal is achieved",
        .plateau => "the last three iterations improved nothing, so there was no better step to take",
        .budget => "its iteration budget is spent",
        .stopped => "it was stopped",
        .active => "the turn ended",
    };
    const next: []const u8 = switch (why) {
        .plateau => " Say what to try next, or /goal resume to let it look again.",
        .budget => " /goal budget N raises the limit and /goal resume continues.",
        else => "",
    };
    return std.fmt.bufPrint(buf, "Goal loop ended: {s}. {d} iteration(s), {d} improved.{s}{s}", .{ reason, g.iteration, g.improved, score, next }) catch "Goal loop ended.";
}

// ------------------------------------------------------------------------------------------ tests

const tt = std.testing;

test "goal: the /goal grammar - start with flags, status, stop, resume, budget, check, and what is not a command" {
    var b: [256]u8 = undefined;
    try tt.expectEqual(Cmd.none, parseCommand("make the tests pass", &b));
    try tt.expectEqual(Cmd.none, parseCommand("/goals are nice", &b));
    try tt.expectEqual(Cmd.status, parseCommand("/goal", &b));
    try tt.expectEqual(Cmd.status, parseCommand("  /goal status ", &b));
    try tt.expectEqual(Cmd.stop, parseCommand("/goal stop", &b));
    try tt.expectEqual(Cmd.go_on, parseCommand("/goal resume", &b));
    try tt.expectEqual(Cmd.forever_on, parseCommand("/goal forever", &b));
    try tt.expectEqual(@as(u32, 40), parseCommand("/goal budget 40", &b).budget);
    try tt.expectEqualStrings("pytest -q", parseCommand("/goal check `pytest -q`", &b).check);
    const s = parseCommand("/goal make every test pass --budget 12 and keep the API stable --forever", &b).start;
    try tt.expectEqualStrings("make every test pass and keep the API stable", s.text);
    try tt.expect(s.forever);
    try tt.expectEqual(@as(?u32, 12), s.budget);
    const withcheck = parseCommand("/goal fix the parser --budget 3 --check python test_calc.py -q", &b).start;
    try tt.expectEqualStrings("fix the parser", withcheck.text);
    try tt.expectEqualStrings("python test_calc.py -q", withcheck.check);
    try tt.expectEqual(@as(?u32, 3), withcheck.budget);
    const plain = parseCommand("/goal speed up the build", &b).start;
    try tt.expect(!plain.forever and plain.budget == null);
    try tt.expectEqual(Cmd.forever_on, parseCommand("/goal --forever", &b)); // alone, it changes the current goal
    try tt.expectEqual(Cmd.status, parseCommand("/goal --budget 5", &b)); // flags with no text are a question, not a goal
}

test "goal: a judge line parses to an outcome, a score and evidence; noise is SAME and never progress" {
    var e: [200]u8 = undefined;
    const a = parseVerdict("IMPROVED | score: 12/14 | evidence: pytest printed 12 passed, 2 failed", &e);
    try tt.expectEqual(Outcome.improved, a.outcome);
    try tt.expectEqual(@as(i64, 12), a.num);
    try tt.expectEqual(@as(i64, 14), a.den);
    try tt.expectEqualStrings("pytest printed 12 passed, 2 failed", a.evidence);
    const r = parseVerdict("**REGRESSED** | score: none | evidence: the build now fails", &e);
    try tt.expectEqual(Outcome.regressed, r.outcome);
    try tt.expect(r.den <= 0);
    try tt.expectEqual(Outcome.same, parseVerdict("I think it went well overall!", &e).outcome);
    try tt.expect(parseVerdict("IMPROVED | score: 15/14 | evidence: x", &e).den <= 0); // an impossible score is no score
}

test "goal: two scores are compared by arithmetic, whatever the judge said" {
    const g: Goal = .{ .best_num = 10, .best_den = 14 };
    try tt.expectEqual(Outcome.improved, decide(g, .{ .outcome = .same, .num = 12, .den = 14 }));
    try tt.expectEqual(Outcome.regressed, decide(g, .{ .outcome = .improved, .num = 9, .den = 14 }));
    try tt.expectEqual(Outcome.same, decide(g, .{ .outcome = .improved, .num = 20, .den = 28 })); // 20/28 == 10/14
    try tt.expectEqual(Outcome.improved, decide(g, .{ .outcome = .improved })); // no score: the judge's word
    try tt.expectEqual(Outcome.improved, decide(.{}, .{ .outcome = .improved, .num = 3, .den = 9 })); // first score is a baseline
}

test "goal: the loop records iterations, stops on a plateau or the budget, and a forever goal does neither" {
    const gpa = tt.allocator;
    const io = tt.io;
    const dir = "zig-goal-tmp";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var st: State = .{};
    defer st.deinit(gpa);
    st.start(gpa, "  make every test pass ", false, 6, 100);
    try tt.expectEqualStrings("make every test pass", st.g.?.text);
    try tt.expect(st.isActive());
    try tt.expectEqual(@as(usize, 6), st.stepsLeft());
    try tt.expectEqual(@as(?Status, null), st.record(gpa, io, dir, "write the parser", .{ .outcome = .improved, .num = 4, .den = 10, .evidence = "4 passed" }, 101));
    try tt.expectEqual(@as(?Status, null), st.record(gpa, io, dir, "add the formatter", .{ .outcome = .improved, .num = 8, .den = 10, .evidence = "8 passed" }, 102));
    try tt.expectEqual(@as(?Status, null), st.record(gpa, io, dir, "rename a variable", .{ .outcome = .improved, .num = 8, .den = 10 }, 103)); // same score: not improved
    try tt.expectEqual(@as(u32, 1), st.g.?.flat);
    try tt.expectEqual(@as(?Status, null), st.record(gpa, io, dir, "reformat", .{ .outcome = .same }, 104));
    try tt.expectEqual(@as(?Status, .plateau), st.record(gpa, io, dir, "reformat again", .{ .outcome = .same }, 105));
    try tt.expectEqual(Status.plateau, st.g.?.status);
    try tt.expect(!st.isActive());
    try tt.expectEqual(@as(u32, 2), st.g.?.improved);
    try tt.expectEqual(@as(i64, 8), st.g.?.best_num);

    // it is on disk: a fresh State reads the same goal, and the log reads back as the picker's list
    var again: State = .{};
    defer again.deinit(gpa);
    again.load(gpa, io, dir);
    try tt.expectEqual(@as(u32, 5), again.g.?.iteration);
    try tt.expectEqualStrings("make every test pass", again.g.?.text);
    const log = logTail(gpa, io, dir, 3);
    defer gpa.free(log);
    try tt.expect(std.mem.indexOf(u8, log, "5. same: reformat again") != null);
    try tt.expect(std.mem.indexOf(u8, log, "write the parser") == null); // only the newest 3
    try tt.expect(std.mem.indexOf(u8, log, "3. same: rename a variable") != null);

    // commands: raising the budget reactivates a spent goal; stop ends it; status names the state
    var b: [900]u8 = undefined;
    var spent: State = .{};
    defer spent.deinit(gpa);
    spent.start(gpa, "tidy the repo", false, 1, 1);
    try tt.expectEqual(@as(?Status, .budget), spent.record(gpa, io, dir, "one step", .{ .outcome = .improved }, 2));
    _ = spent.apply(gpa, io, dir, .{ .budget = 5 }, &b);
    try tt.expect(spent.isActive());
    const reply = spent.apply(gpa, io, dir, .stop, &b);
    try tt.expect(std.mem.indexOf(u8, reply, "stopped") != null and std.mem.indexOf(u8, reply, "tidy the repo") != null);
    try tt.expect(!spent.isActive());

    // forever: no plateau, no default budget
    var fv: State = .{};
    defer fv.deinit(gpa);
    fv.start(gpa, "keep improving the docs", true, null, 1);
    var k: u32 = 0;
    while (k < 10) : (k += 1) try tt.expectEqual(@as(?Status, null), fv.record(gpa, io, dir, "a step", .{ .outcome = .same }, 2));
    try tt.expect(fv.isActive());
    try tt.expectEqual(@as(usize, TURN_STEPS_MAX), fv.stepsLeft());
}

test "goal: the pick question carries the log, offers DONE only to a finite goal, and names the check" {
    var b: [6000]u8 = undefined;
    const q = pickQuestion(&b, .{ .text = "x", .check = "pytest -q" }, "  1. improved: wrote the parser\n", "MEMORY RULE");
    try tt.expect(std.mem.indexOf(u8, q, "1. improved: wrote the parser") != null);
    try tt.expect(std.mem.indexOf(u8, q, "exactly DONE") != null);
    try tt.expect(std.mem.indexOf(u8, q, "then run `pytest -q`") != null);
    try tt.expect(std.mem.indexOf(u8, q, "MEMORY RULE") != null);
    const f = pickQuestion(&b, .{ .text = "x", .forever = true }, "", "M");
    try tt.expect(std.mem.indexOf(u8, f, "exactly DONE") == null);
    try tt.expect(std.mem.indexOf(u8, f, "(none yet)") != null);
    var sb: [400]u8 = undefined;
    const s = summaryText(&sb, .{ .iteration = 7, .improved = 4, .best_num = 12, .best_den = 14 }, .plateau);
    try tt.expect(std.mem.indexOf(u8, s, "7 iteration(s), 4 improved") != null and std.mem.indexOf(u8, s, "12/14") != null);
}
