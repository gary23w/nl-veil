//! chat_plan.zig — the veil's DURABLE PLAN-BOARD.
//!
//! When the veil is given a non-trivial task, its first move is to decompose it into a list of subtasks, each
//! tagged with a triage ROUTE: "hive" (delegate to a swarm), "research" (learn/RAG first), or "inline" (build it
//! itself) — and, alongside the list, an ACCEPTANCE CONTRACT (Brief: objective / done_when / watch_for) stating
//! what "done" means before any work starts. This module is the pure data layer for that plan: parse the
//! decomposition and the contract the model returns, persist
//! the task list to plan.jsonl, and walk it deterministically. The drive loop (chat_engine) executes one pending
//! task per step and marks it done — turning the prompt-level "plan then triage" posture into tracked structure
//! that survives across turns (a follow-up "continue" resumes the pending tasks).
//!
//! Pure + std-only so the parsing / status / selection logic is unit-tested directly.

const std = @import("std");

/// Cap on subtasks in one plan — a runaway decomposition can't mint an unbounded board. A plan longer than this
/// is truncated (the caller logs it); the tail can be re-planned after the first pass.
pub const MAX_TASKS: usize = 32;

/// The three triage routes. Stored as short strings for JSON round-tripping; normalizeRoute maps anything else.
pub const ROUTE_HIVE = "hive";
pub const ROUTE_RESEARCH = "research";
pub const ROUTE_INLINE = "inline";

pub const STATUS_PENDING = "pending";
pub const STATUS_ACTIVE = "active";
pub const STATUS_DONE = "done";

pub const Task = struct {
    text: []u8, // the subtask description (gpa-owned)
    route: []u8, // "hive" | "research" | "inline" (gpa-owned)
    status: []u8, // "pending" | "active" | "done" (gpa-owned)
    swarm_id: []u8, // the swarm cast for this task, or "" (gpa-owned)
    // The checkable condition that ends THIS subtask, in the planner's own words, or "" (gpa-owned). A model
    // that omits it leaves "" — the caller falls back to its generic closing line, which is the old behaviour.
    done_when: []u8 = &.{},
    // The tool the planner expects this subtask to use, in its own words, or "" (gpa-owned). The planner sees
    // the whole belt ONCE while decomposing, so it can suggest the fit cheaply; carried into the drive step as
    // a hint (never a constraint — the model may pick another tool if the work turns out different).
    tool_hint: []u8 = &.{},
};

pub fn freeTasks(gpa: std.mem.Allocator, tasks: []Task) void {
    for (tasks) |t| {
        gpa.free(t.text);
        gpa.free(t.route);
        gpa.free(t.status);
        gpa.free(t.swarm_id);
        gpa.free(t.done_when);
        gpa.free(t.tool_hint);
    }
    gpa.free(tasks);
}

/// How many done_when / watch_for lines one brief may carry. A brief rides in EVERY inference of the turn (it is
/// injected below the compaction floor), so an over-eager planner must not be able to mint an unbounded preamble.
pub const MAX_BRIEF_ITEMS: usize = 8;

/// The turn's ACCEPTANCE CONTRACT — what the thinking model decided "done" means before any coding work started.
/// Separate from the task list because it is turn-level, not per-subtask: the objective the whole plan serves, the
/// conditions that must hold at the end, and the failure modes the planner already anticipated. Every field is
/// optional by construction: a planner that returns only {"plan":[…]} yields an EMPTY brief and the turn behaves
/// exactly as it did before briefs existed.
pub const Brief = struct {
    objective: []u8 = &.{}, // one-sentence acceptance statement (gpa-owned)
    done_when: [][]u8 = &.{}, // checkable end conditions (gpa-owned, each item gpa-owned)
    watch_for: [][]u8 = &.{}, // known failure modes (gpa-owned, each item gpa-owned)

    /// Nothing worth injecting — the caller skips the whole brief message rather than emitting an empty header.
    pub fn isEmpty(self: Brief) bool {
        return self.objective.len == 0 and self.done_when.len == 0 and self.watch_for.len == 0;
    }

    pub fn deinit(self: *Brief, gpa: std.mem.Allocator) void {
        gpa.free(self.objective);
        freeLines(gpa, self.done_when);
        freeLines(gpa, self.watch_for);
        self.* = .{};
    }
};

fn freeLines(gpa: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| gpa.free(l);
    gpa.free(lines);
}

/// Dupe up to MAX_BRIEF_ITEMS non-empty, trimmed lines. Any allocation failure just shortens the list — a brief is
/// additive context, never a reason to fail the turn.
fn dupeLines(gpa: std.mem.Allocator, src: []const []const u8) [][]u8 {
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    defer list.deinit(gpa);
    for (src) |raw| {
        if (list.items.len >= MAX_BRIEF_ITEMS) break;
        const t = std.mem.trim(u8, raw, " \r\n\t");
        if (t.len == 0) continue;
        const d = gpa.dupe(u8, t) catch break;
        list.append(gpa, d) catch {
            gpa.free(d);
            break;
        };
    }
    if (list.items.len == 0) return &.{};
    return list.toOwnedSlice(gpa) catch &.{};
}

/// Normalize a model-supplied route to one of the three canonical values (unknown → inline, the safe default:
/// the veil does it itself rather than spuriously delegating).
pub fn normalizeRoute(r: []const u8) []const u8 {
    const t = std.mem.trim(u8, r, " \r\n\t\"'");
    if (std.ascii.eqlIgnoreCase(t, ROUTE_HIVE) or std.ascii.eqlIgnoreCase(t, "delegate") or std.ascii.eqlIgnoreCase(t, "swarm")) return ROUTE_HIVE;
    if (std.ascii.eqlIgnoreCase(t, ROUTE_RESEARCH) or std.ascii.eqlIgnoreCase(t, "learn") or std.ascii.eqlIgnoreCase(t, "rag")) return ROUTE_RESEARCH;
    return ROUTE_INLINE;
}

fn mkTask(gpa: std.mem.Allocator, text: []const u8, route: []const u8, status: []const u8, swarm_id: []const u8, done_when: []const u8, tool_hint: []const u8) !Task {
    const tx = try gpa.dupe(u8, text);
    errdefer gpa.free(tx);
    const rt = try gpa.dupe(u8, normalizeRoute(route));
    errdefer gpa.free(rt);
    const st = try gpa.dupe(u8, status);
    errdefer gpa.free(st);
    const sw = try gpa.dupe(u8, swarm_id);
    errdefer gpa.free(sw);
    const dw = try gpa.dupe(u8, std.mem.trim(u8, done_when, " \r\n\t"));
    errdefer gpa.free(dw);
    const hint = try gpa.dupe(u8, std.mem.trim(u8, tool_hint, " \r\n\t"));
    return .{ .text = tx, .route = rt, .status = st, .swarm_id = sw, .done_when = dw, .tool_hint = hint };
}

fn freeTask(gpa: std.mem.Allocator, t: Task) void {
    gpa.free(t.text);
    gpa.free(t.route);
    gpa.free(t.status);
    gpa.free(t.swarm_id);
    gpa.free(t.done_when);
    gpa.free(t.tool_hint);
}

/// Parse the model's decomposition reply — `{"plan":[{"task":"…","route":"…","done_when":"…"}, …]}` — into a
/// fresh pending task list (capped at MAX_TASKS). A `{"plan":[]}` (or unparseable / no tasks) returns an EMPTY
/// slice, the caller's signal to run a normal single-step turn instead of a board. Never errors: any trouble →
/// empty (degrade to the normal turn).
///
/// TWO-SHOT PARSE. `done_when` is the newer field, and std.json type-errors a KNOWN field of the wrong shape even
/// under ignore_unknown_fields — a planner that emits `"done_when":["a","b"]` on a row would otherwise take the
/// WHOLE board down to empty. So a failed strict parse retries with the original two-field row: the plan degrades
/// to what it always was rather than vanishing.
pub fn parseDecomposition(gpa: std.mem.Allocator, json: []const u8) []Task {
    const Row = struct { task: []const u8 = "", route: []const u8 = ROUTE_INLINE, done_when: []const u8 = "", tool_hint: []const u8 = "" };
    const Doc = struct { plan: []const Row = &.{} };
    if (std.json.parseFromSlice(Doc, gpa, json, .{ .ignore_unknown_fields = true })) |parsed| {
        defer parsed.deinit();
        return collectRows(gpa, parsed.value.plan);
    } else |_| {}
    const Legacy = struct { task: []const u8 = "", route: []const u8 = ROUTE_INLINE };
    const LegacyDoc = struct { plan: []const Legacy = &.{} };
    const lp = std.json.parseFromSlice(LegacyDoc, gpa, json, .{ .ignore_unknown_fields = true }) catch return &.{};
    defer lp.deinit();
    var list: std.ArrayListUnmanaged(Task) = .empty;
    defer list.deinit(gpa);
    for (lp.value.plan) |row| {
        if (list.items.len >= MAX_TASKS) break;
        const text = std.mem.trim(u8, row.task, " \r\n\t");
        if (text.len == 0) continue;
        const t = mkTask(gpa, text, row.route, STATUS_PENDING, "", "", "") catch break;
        list.append(gpa, t) catch {
            freeTask(gpa, t);
            break;
        };
    }
    if (list.items.len == 0) return &.{};
    return list.toOwnedSlice(gpa) catch &.{};
}

fn collectRows(gpa: std.mem.Allocator, rows: anytype) []Task {
    var list: std.ArrayListUnmanaged(Task) = .empty;
    defer list.deinit(gpa);
    for (rows) |row| {
        if (list.items.len >= MAX_TASKS) break;
        const text = std.mem.trim(u8, row.task, " \r\n\t");
        if (text.len == 0) continue;
        const t = mkTask(gpa, text, row.route, STATUS_PENDING, "", row.done_when, row.tool_hint) catch break;
        list.append(gpa, t) catch {
            freeTask(gpa, t);
            break;
        };
    }
    if (list.items.len == 0) return &.{};
    return list.toOwnedSlice(gpa) catch &.{};
}

/// Parse the turn-level acceptance contract out of the SAME decomposition reply. Deliberately a SEPARATE parse
/// from parseDecomposition: a malformed brief must not cost the caller its plan, and a malformed plan must not
/// cost it the brief. Missing fields ⇒ empty, never an error.
pub fn parseBrief(gpa: std.mem.Allocator, json: []const u8) Brief {
    const Doc = struct {
        objective: []const u8 = "",
        done_when: []const []const u8 = &.{},
        watch_for: []const []const u8 = &.{},
    };
    const parsed = std.json.parseFromSlice(Doc, gpa, json, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    const obj = std.mem.trim(u8, parsed.value.objective, " \r\n\t");
    return .{
        .objective = gpa.dupe(u8, obj) catch &.{},
        .done_when = dupeLines(gpa, parsed.value.done_when),
        .watch_for = dupeLines(gpa, parsed.value.watch_for),
    };
}

/// The brief as one JSON object — what the caller persists beside plan.jsonl so a "continue" turn resumes under
/// the SAME acceptance contract it was planned against. gpa-owned.
pub fn formatBrief(gpa: std.mem.Allocator, b: Brief) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"objective\":");
    try appendJsonString(gpa, &out, b.objective);
    try out.appendSlice(gpa, ",\"done_when\":");
    try appendJsonArray(gpa, &out, b.done_when);
    try out.appendSlice(gpa, ",\"watch_for\":");
    try appendJsonArray(gpa, &out, b.watch_for);
    try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
}

/// One plan.jsonl line for `task`: {"task":..,"route":..,"status":..,"swarm_id":..}. gpa-owned (no trailing \n).
pub fn formatPlanLine(gpa: std.mem.Allocator, task: Task) ![]u8 {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    errdefer l.deinit(gpa);
    try l.appendSlice(gpa, "{\"task\":");
    try appendJsonString(gpa, &l, task.text);
    try l.appendSlice(gpa, ",\"route\":");
    try appendJsonString(gpa, &l, task.route);
    try l.appendSlice(gpa, ",\"status\":");
    try appendJsonString(gpa, &l, task.status);
    try l.appendSlice(gpa, ",\"swarm_id\":");
    try appendJsonString(gpa, &l, task.swarm_id);
    try l.appendSlice(gpa, ",\"done_when\":");
    try appendJsonString(gpa, &l, task.done_when);
    try l.appendSlice(gpa, ",\"tool_hint\":");
    try appendJsonString(gpa, &l, task.tool_hint);
    try l.append(gpa, '}');
    return l.toOwnedSlice(gpa);
}

/// The whole plan.jsonl body (one line per task) — what the caller writes to disk. gpa-owned.
pub fn formatPlan(gpa: std.mem.Allocator, tasks: []const Task) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (tasks) |t| {
        const line = try formatPlanLine(gpa, t);
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// Parse a persisted plan.jsonl back into a task list (for resuming across turns). Bad lines are skipped; a fully
/// unreadable file → empty. Capped at MAX_TASKS.
pub fn parsePlan(gpa: std.mem.Allocator, bytes: []const u8) []Task {
    const Row = struct { task: []const u8 = "", route: []const u8 = ROUTE_INLINE, status: []const u8 = STATUS_PENDING, swarm_id: []const u8 = "", done_when: []const u8 = "", tool_hint: []const u8 = "" };
    var list: std.ArrayListUnmanaged(Task) = .empty;
    defer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        if (list.items.len >= MAX_TASKS) break;
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(Row, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (std.mem.trim(u8, p.value.task, " \r\n\t").len == 0) continue;
        const t = mkTask(gpa, p.value.task, p.value.route, p.value.status, p.value.swarm_id, p.value.done_when, p.value.tool_hint) catch break;
        list.append(gpa, t) catch {
            freeTask(gpa, t);
            break;
        };
    }
    if (list.items.len == 0) return &.{};
    return list.toOwnedSlice(gpa) catch &.{};
}

/// Index of the first task that is not done (pending or active), or null when the whole plan is complete.
pub fn nextPending(tasks: []const Task) ?usize {
    for (tasks, 0..) |t, i| {
        if (!std.mem.eql(u8, t.status, STATUS_DONE)) return i;
    }
    return null;
}

pub fn allDone(tasks: []const Task) bool {
    return nextPending(tasks) == null;
}

pub fn doneCount(tasks: []const Task) usize {
    var n: usize = 0;
    for (tasks) |t| {
        if (std.mem.eql(u8, t.status, STATUS_DONE)) n += 1;
    }
    return n;
}

/// Replace a task's status in place (frees the old, dupes the new). Best-effort: on OOM the old status stays.
pub fn setStatus(gpa: std.mem.Allocator, task: *Task, status: []const u8) void {
    const s = gpa.dupe(u8, status) catch return;
    gpa.free(task.status);
    task.status = s;
}

/// Record the swarm cast for a task (route=hive). Best-effort.
pub fn setSwarmId(gpa: std.mem.Allocator, task: *Task, id: []const u8) void {
    const s = gpa.dupe(u8, id) catch return;
    gpa.free(task.swarm_id);
    task.swarm_id = s;
}

// ------------------------------------------------------------------------------------------- helpers

fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [8]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
        } else try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

fn appendJsonArray(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), items: []const []u8) !void {
    try out.append(gpa, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try out.append(gpa, ',');
        try appendJsonString(gpa, out, s);
    }
    try out.append(gpa, ']');
}

// ------------------------------------------------------------------------------------------- tests

test "parseDecomposition: parses tasks + routes; normalizes unknown route to inline; empty plan → empty" {
    const gpa = std.testing.allocator;
    const json =
        \\{"plan":[{"task":"research unique cat site ideas","route":"research"},{"task":"build the interactive site","route":"hive"},{"task":"polish + verify","route":"whatever"}]}
    ;
    const tasks = parseDecomposition(gpa, json);
    defer freeTasks(gpa, tasks);
    try std.testing.expectEqual(@as(usize, 3), tasks.len);
    try std.testing.expectEqualStrings("research unique cat site ideas", tasks[0].text);
    try std.testing.expectEqualStrings("research", tasks[0].route);
    try std.testing.expectEqualStrings("hive", tasks[1].route);
    try std.testing.expectEqualStrings("inline", tasks[2].route); // unknown → inline
    try std.testing.expectEqualStrings("pending", tasks[0].status);

    const empty = parseDecomposition(gpa, "{\"plan\":[]}");
    defer freeTasks(gpa, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const junk = parseDecomposition(gpa, "not json at all");
    defer freeTasks(gpa, junk);
    try std.testing.expectEqual(@as(usize, 0), junk.len);
}

test "plan.jsonl round-trips through formatPlan + parsePlan (incl. status + swarm_id)" {
    const gpa = std.testing.allocator;
    const src = parseDecomposition(gpa, "{\"plan\":[{\"task\":\"a\",\"route\":\"hive\"},{\"task\":\"b\",\"route\":\"inline\"}]}");
    defer freeTasks(gpa, src);
    // mutate: mark first done + attach a swarm id
    setStatus(gpa, &src[0], STATUS_DONE);
    setSwarmId(gpa, &src[0], "deadbeef");

    const body = try formatPlan(gpa, src);
    defer gpa.free(body);
    const back = parsePlan(gpa, body);
    defer freeTasks(gpa, back);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("a", back[0].text);
    try std.testing.expectEqualStrings("done", back[0].status);
    try std.testing.expectEqualStrings("deadbeef", back[0].swarm_id);
    try std.testing.expectEqualStrings("pending", back[1].status);
}

test "nextPending / allDone / doneCount walk the board" {
    const gpa = std.testing.allocator;
    const tasks = parseDecomposition(gpa, "{\"plan\":[{\"task\":\"a\",\"route\":\"inline\"},{\"task\":\"b\",\"route\":\"inline\"}]}");
    defer freeTasks(gpa, tasks);
    try std.testing.expectEqual(@as(?usize, 0), nextPending(tasks));
    try std.testing.expect(!allDone(tasks));
    setStatus(gpa, &tasks[0], STATUS_DONE);
    try std.testing.expectEqual(@as(?usize, 1), nextPending(tasks));
    try std.testing.expectEqual(@as(usize, 1), doneCount(tasks));
    setStatus(gpa, &tasks[1], STATUS_DONE);
    try std.testing.expectEqual(@as(?usize, null), nextPending(tasks));
    try std.testing.expect(allDone(tasks));
}

test "brief: parsed from the same reply, round-trips, and is EMPTY (never an error) when omitted" {
    const gpa = std.testing.allocator;
    const json =
        \\{"objective":"the site builds and serves","done_when":["npm run build exits 0","/ returns 200"," "],"watch_for":["missing imports"],"plan":[{"task":"scaffold","route":"inline","done_when":"index.html exists"}]}
    ;
    var b = parseBrief(gpa, json);
    defer b.deinit(gpa);
    try std.testing.expect(!b.isEmpty());
    try std.testing.expectEqualStrings("the site builds and serves", b.objective);
    try std.testing.expectEqual(@as(usize, 2), b.done_when.len); // the blank item is dropped
    try std.testing.expectEqualStrings("npm run build exits 0", b.done_when[0]);
    try std.testing.expectEqualStrings("missing imports", b.watch_for[0]);

    const body = try formatBrief(gpa, b);
    defer gpa.free(body);
    var back = parseBrief(gpa, body);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings(b.objective, back.objective);
    try std.testing.expectEqual(b.done_when.len, back.done_when.len);
    try std.testing.expectEqualStrings(b.done_when[1], back.done_when[1]);

    // the OLD schema (plan only) still parses into a usable plan, and yields an empty brief
    var none = parseBrief(gpa, "{\"plan\":[{\"task\":\"a\",\"route\":\"inline\"}]}");
    defer none.deinit(gpa);
    try std.testing.expect(none.isEmpty());
    var junk = parseBrief(gpa, "not json");
    defer junk.deinit(gpa);
    try std.testing.expect(junk.isEmpty());
}

test "per-task done_when parses, round-trips, and a wrong-shaped done_when still yields a plan" {
    const gpa = std.testing.allocator;
    const tasks = parseDecomposition(gpa, "{\"plan\":[{\"task\":\"a\",\"route\":\"hive\",\"done_when\":\"the files land\"},{\"task\":\"b\",\"route\":\"inline\"}]}");
    defer freeTasks(gpa, tasks);
    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("the files land", tasks[0].done_when);
    try std.testing.expectEqualStrings("", tasks[1].done_when); // omitted ⇒ empty, not an error

    const body = try formatPlan(gpa, tasks);
    defer gpa.free(body);
    const back = parsePlan(gpa, body);
    defer freeTasks(gpa, back);
    try std.testing.expectEqualStrings("the files land", back[0].done_when);

    // TWO-SHOT: an array-shaped row done_when type-errors the strict parse; the board must survive it
    const odd = parseDecomposition(gpa, "{\"plan\":[{\"task\":\"a\",\"route\":\"inline\",\"done_when\":[\"x\",\"y\"]}]}");
    defer freeTasks(gpa, odd);
    try std.testing.expectEqual(@as(usize, 1), odd.len);
    try std.testing.expectEqualStrings("a", odd[0].text);
    try std.testing.expectEqualStrings("", odd[0].done_when);
}

test "per-task tool_hint parses and round-trips; absent ⇒ empty" {
    const gpa = std.testing.allocator;
    const tasks = parseDecomposition(gpa, "{\"plan\":[{\"task\":\"write the config\",\"route\":\"inline\",\"tool_hint\":\"write_file\"},{\"task\":\"b\",\"route\":\"inline\"}]}");
    defer freeTasks(gpa, tasks);
    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualStrings("write_file", tasks[0].tool_hint);
    try std.testing.expectEqualStrings("", tasks[1].tool_hint); // omitted ⇒ empty
    const body = try formatPlan(gpa, tasks);
    defer gpa.free(body);
    const back = parsePlan(gpa, body);
    defer freeTasks(gpa, back);
    try std.testing.expectEqualStrings("write_file", back[0].tool_hint);
    try std.testing.expectEqualStrings("", back[1].tool_hint);
}

test "parseDecomposition caps at MAX_TASKS" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"plan\":[");
    var i: usize = 0;
    while (i < MAX_TASKS + 10) : (i += 1) {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, "{\"task\":\"t\",\"route\":\"inline\"}");
    }
    try buf.appendSlice(gpa, "]}");
    const tasks = parseDecomposition(gpa, buf.items);
    defer freeTasks(gpa, tasks);
    try std.testing.expectEqual(MAX_TASKS, tasks.len);
}
