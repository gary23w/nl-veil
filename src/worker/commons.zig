//! Commons — the swarm's shared message bus (messages.jsonl) + event-sourced task board (tasks.jsonl), kept
//! byte-compatible with the Python Commons so the existing swarm-chat pane (mind_msg) + board render
//! identically.
//!
//! CONCURRENCY CONTRACT: minds run their moments CONCURRENTLY in one worker process (run.zig launches them
//! into one Io.Group), so this module owns a process-wide mutex and every public entry point takes it —
//! the read-modify-write cycles here (line index, task id, whole-file append) are only atomic under it.
//! Callers may additionally hold files_mtx around these calls; the lock order is files_mtx → commons_mtx,
//! never the reverse. (This header used to claim "minds run sequentially, so plain read+append is safe";
//! that stopped being true when moments went concurrent, and the one call site that reached the bus without
//! files_mtx could silently lose a message line.)
//!
//! The BOARD is the swarm's coordination forum, and it folds to real state, not counts: every task is
//! add → (claim) → done, a claim is EXCLUSIVE (first claimant wins, later claims are refused with the
//! owner's name), and boardView() renders the fold for a mind's prompt — so who-is-doing-what is something
//! a mind reads, not something it re-derives from prose. Identical minds making identical choices is the
//! documented failure mode of multi-agent runs; a visible claim ledger is the mechanical antidote.
const std = @import("std");
const llm = @import("llm.zig");

/// One lock for both ledgers: bus and board writes are rare and small, and a single order-free mutex
/// cannot deadlock against itself. lockUncancelable — ledger writes must not be torn by cancellation.
var commons_mtx: std.Io.Mutex = .init;

fn readAll(gpa: std.mem.Allocator, io: std.Io, path: []const u8) []u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch (gpa.dupe(u8, "") catch @constCast(""));
}

fn appendLocked(gpa: std.mem.Allocator, io: std.Io, path: []const u8, line: []const u8) void {
    const existing = readAll(gpa, io, path);
    defer gpa.free(existing);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, existing) catch return;
    buf.appendSlice(gpa, line) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch {};
}

fn countLines(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Post a bus message: {"i":N,"round":R,"from":frm,"to":to,"kind":"msg","text":text}.
pub fn sendMessage(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, frm: []const u8, to: []const u8, text: []const u8, round: u32) void {
    const path = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{run_dir}) catch return;
    defer gpa.free(path);
    commons_mtx.lockUncancelable(io);
    defer commons_mtx.unlock(io);
    const existing = readAll(gpa, io, path);
    defer gpa.free(existing);
    const i = countLines(existing);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    if (std.fmt.allocPrint(gpa, "{{\"i\":{d},\"round\":{d},\"from\":", .{ i, round })) |head| {
        defer gpa.free(head);
        line.appendSlice(gpa, head) catch return;
    } else |_| return;
    llm.jstr(gpa, &line, frm) catch return;
    line.appendSlice(gpa, ",\"to\":") catch return;
    llm.jstr(gpa, &line, if (to.len > 0) to else "all") catch return;
    line.appendSlice(gpa, ",\"kind\":\"msg\",\"text\":") catch return;
    llm.jstr(gpa, &line, text) catch return;
    line.appendSlice(gpa, "}\n") catch return;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, existing) catch return;
    buf.appendSlice(gpa, line.items) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch {};
}

/// Recent messages addressed to `me` (or broadcast), not its own — for injecting into the moment prompt.
/// Returns a newline-joined text block (caller frees).
pub fn inbox(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, me: []const u8, limit: usize) []u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{run_dir}) catch return gpa.dupe(u8, "") catch @constCast("");
    defer gpa.free(path);
    commons_mtx.lockUncancelable(io);
    const data = readAll(gpa, io, path);
    commons_mtx.unlock(io);
    defer gpa.free(data);
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    const M = struct { from: []const u8 = "", to: []const u8 = "", text: []const u8 = "" };
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (std.mem.eql(u8, p.value.from, me)) continue;
        if (!std.mem.eql(u8, p.value.to, me) and !std.mem.eql(u8, p.value.to, "all")) continue;
        lines.append(gpa, std.fmt.allocPrint(gpa, "{s}: {s}", .{ p.value.from, p.value.text }) catch continue) catch {};
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const start = if (lines.items.len > limit) lines.items.len - limit else 0;
    for (lines.items[start..]) |l| {
        out.appendSlice(gpa, l) catch {};
        out.append(gpa, '\n') catch {};
        gpa.free(l);
    }
    for (lines.items[0..start]) |l| gpa.free(l);
    return out.toOwnedSlice(gpa) catch gpa.dupe(u8, "") catch @constCast("");
}

/// Add a task event: {"type":"add","id":N,"by":by,"assignee":assignee,"task":task[,"file":file]}.
/// The id is assigned and the event appended under ONE lock hold, so two concurrent adds can never mint
/// the same id. `file` names the task's deliverable when the planner knows it — a STRUCTURED claim
/// target, so exclusivity never has to be re-parsed out of prose.
pub fn addTaskFile(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, by: []const u8, assignee: []const u8, task: []const u8, file: []const u8) u32 {
    const path = std.fmt.allocPrint(gpa, "{s}/tasks.jsonl", .{run_dir}) catch return 0;
    defer gpa.free(path);
    commons_mtx.lockUncancelable(io);
    defer commons_mtx.unlock(io);
    const id = nextTaskIdLocked(gpa, io, run_dir);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    if (std.fmt.allocPrint(gpa, "{{\"type\":\"add\",\"id\":{d},\"by\":", .{id})) |head| {
        defer gpa.free(head);
        line.appendSlice(gpa, head) catch return id;
    } else |_| return id;
    llm.jstr(gpa, &line, by) catch return id;
    line.appendSlice(gpa, ",\"assignee\":") catch return id;
    llm.jstr(gpa, &line, if (assignee.len > 0) assignee else "all") catch return id;
    line.appendSlice(gpa, ",\"task\":") catch return id;
    llm.jstr(gpa, &line, task) catch return id;
    if (file.len > 0) {
        line.appendSlice(gpa, ",\"file\":") catch return id;
        llm.jstr(gpa, &line, file) catch return id;
    }
    line.appendSlice(gpa, "}\n") catch return id;
    appendLocked(gpa, io, path, line.items);
    return id;
}

pub fn addTask(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, by: []const u8, assignee: []const u8, task: []const u8) u32 {
    return addTaskFile(gpa, io, run_dir, by, assignee, task, "");
}

pub fn completeTask(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, id: u32, by: []const u8, result: []const u8) void {
    const path = std.fmt.allocPrint(gpa, "{s}/tasks.jsonl", .{run_dir}) catch return;
    defer gpa.free(path);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    if (std.fmt.allocPrint(gpa, "{{\"type\":\"done\",\"id\":{d},\"by\":", .{id})) |head| {
        defer gpa.free(head);
        line.appendSlice(gpa, head) catch return;
    } else |_| return;
    llm.jstr(gpa, &line, by) catch return;
    line.appendSlice(gpa, ",\"result\":") catch return;
    llm.jstr(gpa, &line, result) catch return;
    line.appendSlice(gpa, "}\n") catch return;
    commons_mtx.lockUncancelable(io);
    defer commons_mtx.unlock(io);
    appendLocked(gpa, io, path, line.items);
}

/// Outcome of a claim attempt — orthogonal outcomes reported independently, never folded into one bool:
/// a refusal because someone owns it and a refusal because the id is nonsense need different replies.
pub const Claim = union(enum) {
    ok,
    already: []u8, // gpa-owned owner name — caller frees
    done_already,
    no_such,
};

/// Claim a task EXCLUSIVELY: {"type":"claim","id":N,"by":by}. The fold decides — first claim wins, and
/// the losing mind is told who won so it picks other work instead of duplicating. Assigned tasks count
/// as pre-claimed by their assignee (an explicit assignment IS a claim).
pub fn claimTask(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, id: u32, by: []const u8) Claim {
    const path = std.fmt.allocPrint(gpa, "{s}/tasks.jsonl", .{run_dir}) catch return .no_such;
    defer gpa.free(path);
    commons_mtx.lockUncancelable(io);
    defer commons_mtx.unlock(io);
    const rows = boardStateLocked(gpa, io, run_dir);
    defer freeRows(gpa, rows);
    for (rows) |r| {
        if (r.id != id) continue;
        switch (r.state) {
            .done => return .done_already,
            .claimed => {
                if (std.mem.eql(u8, r.owner, by)) return .ok; // idempotent re-claim of your own task
                return .{ .already = gpa.dupe(u8, r.owner) catch return .no_such };
            },
            .open => {
                var line: std.ArrayListUnmanaged(u8) = .empty;
                defer line.deinit(gpa);
                if (std.fmt.allocPrint(gpa, "{{\"type\":\"claim\",\"id\":{d},\"by\":", .{id})) |head| {
                    defer gpa.free(head);
                    line.appendSlice(gpa, head) catch return .no_such;
                } else |_| return .no_such;
                llm.jstr(gpa, &line, by) catch return .no_such;
                line.appendSlice(gpa, "}\n") catch return .no_such;
                appendLocked(gpa, io, path, line.items);
                return .ok;
            },
        }
    }
    return .no_such;
}

pub const TaskState = enum { open, claimed, done };
pub const TaskRow = struct {
    id: u32,
    state: TaskState,
    owner: []u8, // "" when nobody owns it; gpa-owned
    task: []u8, // gpa-owned
    file: []u8, // "" when the task names no deliverable; gpa-owned
};

pub fn freeRows(gpa: std.mem.Allocator, rows: []TaskRow) void {
    for (rows) |r| {
        gpa.free(r.owner);
        gpa.free(r.task);
        gpa.free(r.file);
    }
    gpa.free(rows);
}

/// Fold tasks.jsonl into per-task state. An `assignee` other than "all" pre-claims the task for that
/// mind; the first `claim` wins an open task; `done` closes it whatever its claim state (the closer
/// becomes the owner when nobody claimed — done work is attributed, not orphaned).
pub fn boardState(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8) []TaskRow {
    commons_mtx.lockUncancelable(io);
    defer commons_mtx.unlock(io);
    return boardStateLocked(gpa, io, run_dir);
}

fn boardStateLocked(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8) []TaskRow {
    const none: []TaskRow = &.{};
    const path = std.fmt.allocPrint(gpa, "{s}/tasks.jsonl", .{run_dir}) catch return none;
    defer gpa.free(path);
    const data = readAll(gpa, io, path);
    defer gpa.free(data);
    var rows: std.ArrayListUnmanaged(TaskRow) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    const E = struct { type: []const u8 = "", id: u32 = 0, by: []const u8 = "", assignee: []const u8 = "", task: []const u8 = "", file: []const u8 = "" };
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(E, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        const e = p.value;
        if (std.mem.eql(u8, e.type, "add")) {
            const assigned = e.assignee.len > 0 and !std.mem.eql(u8, e.assignee, "all");
            rows.append(gpa, .{
                .id = e.id,
                .state = if (assigned) .claimed else .open,
                .owner = gpa.dupe(u8, if (assigned) e.assignee else "") catch continue,
                .task = gpa.dupe(u8, e.task) catch continue,
                .file = gpa.dupe(u8, e.file) catch continue,
            }) catch continue;
        } else if (std.mem.eql(u8, e.type, "claim")) {
            for (rows.items) |*r| {
                if (r.id == e.id and r.state == .open) {
                    gpa.free(r.owner);
                    r.owner = gpa.dupe(u8, e.by) catch break;
                    r.state = .claimed;
                    break;
                }
            }
        } else if (std.mem.eql(u8, e.type, "done")) {
            for (rows.items) |*r| {
                if (r.id == e.id and r.state != .done) {
                    r.state = .done;
                    if (r.owner.len == 0) {
                        gpa.free(r.owner);
                        r.owner = gpa.dupe(u8, e.by) catch break;
                    }
                    break;
                }
            }
        }
    }
    return rows.toOwnedSlice(gpa) catch none;
}

/// The board rendered for a mind's prompt, open/claimed work first, bounded by `cap` bytes. Done rows
/// collapse into one summary line — a mind coordinating on live work does not need the graveyard.
pub fn boardView(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, cap: usize) []u8 {
    const empty: []u8 = gpa.dupe(u8, "") catch @constCast("");
    const rows = boardState(gpa, io, run_dir);
    defer freeRows(gpa, rows);
    if (rows.len == 0) return empty;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "TASK BOARD (claim_task before you build; a claim is exclusive):\n") catch return empty;
    var done_n: u32 = 0;
    for (rows) |r| {
        if (r.state == .done) {
            done_n += 1;
            continue;
        }
        if (out.items.len >= cap) break;
        var hb: [16]u8 = undefined;
        out.appendSlice(gpa, std.fmt.bufPrint(&hb, "  #{d} ", .{r.id}) catch break) catch break;
        switch (r.state) {
            .open => out.appendSlice(gpa, "[open] ") catch break,
            .claimed => {
                out.appendSlice(gpa, "[claimed by ") catch break;
                out.appendSlice(gpa, r.owner) catch break;
                out.appendSlice(gpa, "] ") catch break;
            },
            .done => unreachable,
        }
        out.appendSlice(gpa, r.task[0..@min(r.task.len, 140)]) catch break;
        if (r.file.len > 0) {
            out.appendSlice(gpa, " -> ") catch break;
            out.appendSlice(gpa, r.file) catch break;
        }
        out.append(gpa, '\n') catch break;
    }
    if (done_n > 0) {
        var db: [40]u8 = undefined;
        out.appendSlice(gpa, std.fmt.bufPrint(&db, "  ({d} task(s) already done)\n", .{done_n}) catch "") catch {};
    }
    return out.toOwnedSlice(gpa) catch empty;
}

fn nextTaskIdLocked(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8) u32 {
    const path = std.fmt.allocPrint(gpa, "{s}/tasks.jsonl", .{run_dir}) catch return 0;
    defer gpa.free(path);
    const data = readAll(gpa, io, path);
    defer gpa.free(data);
    var adds: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| if (std.mem.indexOf(u8, ln, "\"type\":\"add\"") != null) {
        adds += 1;
    };
    return adds;
}

pub const Board = struct { done: u32, open: u32 };

/// Fold the task events into done/open counts (a `done` event closes a prior `add`).
pub fn board(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8) Board {
    const path = std.fmt.allocPrint(gpa, "{s}/tasks.jsonl", .{run_dir}) catch return .{ .done = 0, .open = 0 };
    defer gpa.free(path);
    commons_mtx.lockUncancelable(io);
    const data = readAll(gpa, io, path);
    commons_mtx.unlock(io);
    defer gpa.free(data);
    var adds: u32 = 0;
    var dones: u32 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "\"type\":\"add\"") != null) adds += 1;
        if (std.mem.indexOf(u8, ln, "\"type\":\"done\"") != null) dones += 1;
    }
    return .{ .done = dones, .open = if (adds > dones) adds - dones else 0 };
}

test "bus: delivery is to-me-or-broadcast, never my own; limit keeps the newest (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-commons-bus-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    sendMessage(gpa, io, root, "alpha", "", "hello everyone", 1); // empty `to` = broadcast
    sendMessage(gpa, io, root, "beta", "alpha", "direct to alpha", 1);
    sendMessage(gpa, io, root, "alpha", "beta", "from me", 2);
    sendMessage(gpa, io, root, "gamma", "delta", "not for alpha", 2);

    const in_alpha = inbox(gpa, io, root, "alpha", 10);
    defer gpa.free(in_alpha);
    try std.testing.expectEqualStrings("beta: direct to alpha\n", in_alpha);

    const in_beta = inbox(gpa, io, root, "beta", 10);
    defer gpa.free(in_beta);
    try std.testing.expectEqualStrings("alpha: hello everyone\nalpha: from me\n", in_beta);

    const newest = inbox(gpa, io, root, "beta", 1);
    defer gpa.free(newest);
    try std.testing.expectEqualStrings("alpha: from me\n", newest);
}

test "bus: quotes and newlines in a message survive the JSON round trip (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-commons-esc-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    sendMessage(gpa, io, root, "quoter", "", "say \"hi\"\nline2", 1);
    const got = inbox(gpa, io, root, "reader", 10);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("quoter: say \"hi\"\nline2\n", got);
}

test "board: ids count prior adds, done closes open, and an escaped \"type\":\"add\" in task TEXT is not an event (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-commons-board-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    try std.testing.expectEqual(@as(u32, 0), addTask(gpa, io, root, "lead", "", "t0"));
    try std.testing.expectEqual(@as(u32, 1), addTask(gpa, io, root, "lead", "beta", "t1"));
    try std.testing.expectEqual(Board{ .done = 0, .open = 2 }, board(gpa, io, root));

    completeTask(gpa, io, root, 0, "beta", "done t0");
    try std.testing.expectEqual(Board{ .done = 1, .open = 1 }, board(gpa, io, root));

    // The scans count event lines by the substring "type":"add" — a task TEXT quoting it arrives
    // jstr-escaped (\" everywhere), so it must count as ONE add (its own event), not two.
    try std.testing.expectEqual(@as(u32, 2), addTask(gpa, io, root, "lead", "", "mind the \"type\":\"add\" trap"));
    try std.testing.expectEqual(Board{ .done = 1, .open = 2 }, board(gpa, io, root));

    completeTask(gpa, io, root, 1, "beta", "done t1");
    completeTask(gpa, io, root, 2, "lead", "done trap");
    try std.testing.expectEqual(Board{ .done = 3, .open = 0 }, board(gpa, io, root));
}

test "claims: first wins, the loser learns the owner, re-claim is idempotent, done/no-such are distinct (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-commons-claim-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    _ = addTaskFile(gpa, io, root, "lead", "", "implement the game loop", "game.js");
    _ = addTask(gpa, io, root, "lead", "ada", "write styles"); // explicit assignment = pre-claimed

    try std.testing.expectEqual(Claim.ok, claimTask(gpa, io, root, 0, "nova"));
    try std.testing.expectEqual(Claim.ok, claimTask(gpa, io, root, 0, "nova")); // idempotent for the owner
    switch (claimTask(gpa, io, root, 0, "rex")) {
        .already => |owner| {
            defer gpa.free(owner);
            try std.testing.expectEqualStrings("nova", owner);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (claimTask(gpa, io, root, 1, "rex")) { // assigned to ada at add time
        .already => |owner| {
            defer gpa.free(owner);
            try std.testing.expectEqualStrings("ada", owner);
        },
        else => return error.TestUnexpectedResult,
    }

    completeTask(gpa, io, root, 0, "nova", "shipped");
    try std.testing.expectEqual(Claim.done_already, claimTask(gpa, io, root, 0, "rex"));
    try std.testing.expectEqual(Claim.no_such, claimTask(gpa, io, root, 99, "rex"));
}

test "boardState + boardView: the fold is per-task truth and the render leads with live work (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-commons-view-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    _ = addTaskFile(gpa, io, root, "lead", "", "scaffold the page", "index.html");
    _ = addTaskFile(gpa, io, root, "lead", "", "game loop", "game.js");
    _ = addTask(gpa, io, root, "lead", "", "smoke-test the build");
    try std.testing.expectEqual(Claim.ok, claimTask(gpa, io, root, 1, "ada"));
    completeTask(gpa, io, root, 0, "nova", "done");

    const rows = boardState(gpa, io, root);
    defer freeRows(gpa, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(TaskState.done, rows[0].state);
    try std.testing.expectEqualStrings("nova", rows[0].owner); // the closer is attributed
    try std.testing.expectEqual(TaskState.claimed, rows[1].state);
    try std.testing.expectEqualStrings("ada", rows[1].owner);
    try std.testing.expectEqualStrings("game.js", rows[1].file);
    try std.testing.expectEqual(TaskState.open, rows[2].state);
    try std.testing.expectEqualStrings("", rows[2].owner);

    const view = boardView(gpa, io, root, 4096);
    defer gpa.free(view);
    try std.testing.expect(std.mem.indexOf(u8, view, "#1 [claimed by ada] game loop -> game.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, view, "#2 [open] smoke-test the build") != null);
    try std.testing.expect(std.mem.indexOf(u8, view, "#0") == null); // done rows collapse…
    try std.testing.expect(std.mem.indexOf(u8, view, "(1 task(s) already done)") != null); // …into the summary
}
