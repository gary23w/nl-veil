//! Commons — the swarm's shared message bus (messages.jsonl) + event-sourced task board (tasks.jsonl), kept

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

pub fn sendMessage(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, frm: []const u8, to: []const u8, text: []const u8, round: u32) void {
    const path = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{run_dir}) catch return;
    defer gpa.free(path);
    const existing = readAll(gpa, io, path);
    defer gpa.free(existing);
    const i = countLines(existing);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    line.appendSlice(gpa, std.fmt.allocPrint(gpa, "{{\"i\":{d},\"round\":{d},\"from\":", .{ i, round }) catch return) catch return;
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

pub fn addTask(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, by: []const u8, assignee: []const u8, task: []const u8) u32 {
    const path = std.fmt.allocPrint(gpa, "{s}/tasks.jsonl", .{run_dir}) catch return 0;
    defer gpa.free(path);
    const id = nextTaskId(gpa, io, run_dir);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    line.appendSlice(gpa, std.fmt.allocPrint(gpa, "{{\"type\":\"add\",\"id\":{d},\"by\":", .{id}) catch return id) catch return id;
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
    line.appendSlice(gpa, std.fmt.allocPrint(gpa, "{{\"type\":\"done\",\"id\":{d},\"by\":", .{id}) catch return) catch return;
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
