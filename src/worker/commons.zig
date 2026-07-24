//! Commons — the swarm's shared message bus (messages.jsonl) + event-sourced task board (tasks.jsonl), kept
//! byte-compatible with the Python Commons so the existing swarm-chat pane (mind_msg) + board render
//! identically. Minds in a swarm run sequentially in one worker process, so plain read+append is safe.
const std = @import("std");
const llm = @import("llm.zig");

fn readAll(gpa: std.mem.Allocator, io: std.Io, path: []const u8) []u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch (gpa.dupe(u8, "") catch @constCast(""));
}

fn append(gpa: std.mem.Allocator, io: std.Io, path: []const u8, line: []const u8) void {
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
    const data = readAll(gpa, io, path);
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

/// Add a task event: {"type":"add","id":N,"by":by,"assignee":assignee,"task":task}.
pub fn addTask(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, by: []const u8, assignee: []const u8, task: []const u8) u32 {
    const path = std.fmt.allocPrint(gpa, "{s}/tasks.jsonl", .{run_dir}) catch return 0;
    defer gpa.free(path);
    const id = nextTaskId(gpa, io, run_dir);
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
    line.appendSlice(gpa, "}\n") catch return id;
    append(gpa, io, path, line.items);
    return id;
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
    append(gpa, io, path, line.items);
}

fn nextTaskId(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8) u32 {
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
    const data = readAll(gpa, io, path);
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
