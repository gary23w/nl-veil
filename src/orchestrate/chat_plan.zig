//! chat_plan.zig — the veil's DURABLE PLAN-BOARD.
//!
//! When the veil is given a non-trivial task, its first move is to decompose it into a list of subtasks, each
//! tagged with a triage ROUTE: "hive" (delegate to a swarm), "research" (learn/RAG first), or "inline" (build it
//! itself). This module is the pure data layer for that plan: parse the decomposition the model returns, persist
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
};

pub fn freeTasks(gpa: std.mem.Allocator, tasks: []Task) void {
    for (tasks) |t| {
        gpa.free(t.text);
        gpa.free(t.route);
        gpa.free(t.status);
        gpa.free(t.swarm_id);
    }
    gpa.free(tasks);
}

/// Normalize a model-supplied route to one of the three canonical values (unknown → inline, the safe default:
/// the veil does it itself rather than spuriously delegating).
pub fn normalizeRoute(r: []const u8) []const u8 {
    const t = std.mem.trim(u8, r, " \r\n\t\"'");
    if (std.ascii.eqlIgnoreCase(t, ROUTE_HIVE) or std.ascii.eqlIgnoreCase(t, "delegate") or std.ascii.eqlIgnoreCase(t, "swarm")) return ROUTE_HIVE;
    if (std.ascii.eqlIgnoreCase(t, ROUTE_RESEARCH) or std.ascii.eqlIgnoreCase(t, "learn") or std.ascii.eqlIgnoreCase(t, "rag")) return ROUTE_RESEARCH;
    return ROUTE_INLINE;
}

fn mkTask(gpa: std.mem.Allocator, text: []const u8, route: []const u8, status: []const u8, swarm_id: []const u8) !Task {
    const tx = try gpa.dupe(u8, text);
    errdefer gpa.free(tx);
    const rt = try gpa.dupe(u8, normalizeRoute(route));
    errdefer gpa.free(rt);
    const st = try gpa.dupe(u8, status);
    errdefer gpa.free(st);
    const sw = try gpa.dupe(u8, swarm_id);
    return .{ .text = tx, .route = rt, .status = st, .swarm_id = sw };
}

/// Parse the model's decomposition reply — `{"plan":[{"task":"…","route":"hive|research|inline"}, …]}` — into a
/// fresh pending task list (capped at MAX_TASKS). A `{"plan":[]}` (or unparseable / no tasks) returns an EMPTY
/// slice, the caller's signal to run a normal single-step turn instead of a board. Never errors: any trouble →
/// empty (degrade to the normal turn).
pub fn parseDecomposition(gpa: std.mem.Allocator, json: []const u8) []Task {
    const Row = struct { task: []const u8 = "", route: []const u8 = ROUTE_INLINE };
    const Doc = struct { plan: []const Row = &.{} };
    const parsed = std.json.parseFromSlice(Doc, gpa, json, .{ .ignore_unknown_fields = true }) catch return &.{};
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(Task) = .empty;
    defer list.deinit(gpa);
    for (parsed.value.plan) |row| {
        if (list.items.len >= MAX_TASKS) break;
        const text = std.mem.trim(u8, row.task, " \r\n\t");
        if (text.len == 0) continue;
        const t = mkTask(gpa, text, row.route, STATUS_PENDING, "") catch break;
        list.append(gpa, t) catch {
            gpa.free(t.text);
            gpa.free(t.route);
            gpa.free(t.status);
            gpa.free(t.swarm_id);
            break;
        };
    }
    if (list.items.len == 0) return &.{};
    return list.toOwnedSlice(gpa) catch &.{};
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
    const Row = struct { task: []const u8 = "", route: []const u8 = ROUTE_INLINE, status: []const u8 = STATUS_PENDING, swarm_id: []const u8 = "" };
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
        const t = mkTask(gpa, p.value.task, p.value.route, p.value.status, p.value.swarm_id) catch break;
        list.append(gpa, t) catch {
            gpa.free(t.text);
            gpa.free(t.route);
            gpa.free(t.status);
            gpa.free(t.swarm_id);
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
