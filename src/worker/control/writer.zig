//! Control writer — POST /swarms/:id/control: `stop` acts immediately, every other op is appended to the worker's control.jsonl.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../../gateway/http.zig");
const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const notFound = http.notFound;
const unauth = http.unauth;
const serverErr = http.serverErr;
const jstr = http.jstr;
const appendFile = http.appendFile;

const ControlReq = struct { op: []const u8, to: []const u8 = "all", text: []const u8 = "", goal: []const u8 = "" };

/// Render one control-bus line: the JSON object plus the trailing newline that `worker/run.zig`'s `drainControl`
/// splits the file on. Lifted verbatim out of `swarmControl` (same bytes, same order) so the wire shape can be
/// pinned by a test without standing up an HTTP request. Every field goes through `jstr`, so a quote or a newline
/// in operator text cannot break one op into two lines. `to` rides along only with `text` (the reader's `answer`
/// op needs both); `goal` only when non-empty.
fn controlLine(gpa: std.mem.Allocator, line: *std.ArrayListUnmanaged(u8), op: []const u8, to: []const u8, text: []const u8, goal: []const u8) !void {
    try line.appendSlice(gpa, "{\"op\":");
    try jstr(gpa, line, op);
    if (text.len > 0) {
        try line.appendSlice(gpa, ",\"to\":");
        try jstr(gpa, line, to);
        try line.appendSlice(gpa, ",\"text\":");
        try jstr(gpa, line, text);
    }
    if (goal.len > 0) {
        try line.appendSlice(gpa, ",\"goal\":");
        try jstr(gpa, line, goal);
    }
    try line.appendSlice(gpa, "}\n");
}

pub fn swarmControl(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    const body = (try req.json(ControlReq)) orelse return badReq(res, "bad body");

    if (std.mem.eql(u8, body.op, "stop")) {
        app.sup.stop(id);
        try res.json(.{ .ok = true, .stopped = true }, .{});
        return;
    }
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(app.gpa);
    try controlLine(app.gpa, &line, body.op, body.to, body.text, body.goal);
    const ctl_path = try std.fmt.allocPrint(res.arena, "{s}/control.jsonl", .{sw.run_dir});
    appendFile(app.io, res.arena, ctl_path, line.items) catch return serverErr(res, "could not write control");
    try res.json(.{ .ok = true }, .{});
}

// ---------------------------------------------------------------------------
// tests — the control-bus wire contract, on a real file
//
// The bus is a two-process contract with no shared type: this file appends bytes, and `worker/run.zig`'s
// `drainControl` — in another process, at another time — splits them on '\n' and parses each line. So the tests
// assert against the READER's view, not the writer's: `DrainedOp` below is `drainControl`'s local struct copied
// field-for-field, and the line walk mirrors its split/trim/skip-blank loop. Asserting on a struct this file
// owned would keep passing while the two halves drifted apart, which is the only failure that matters here.
// ---------------------------------------------------------------------------

/// `drainControl`'s per-line parse struct (src/worker/run.zig), copied field-for-field. Kept in the reader's
/// shape — including the fields this writer never emits — because the point is what the DRAINING side sees.
const DrainedOp = struct {
    op: []const u8 = "",
    to: []const u8 = "",
    id: []const u8 = "",
    text: []const u8 = "",
    goal: []const u8 = "",
    answered: u8 = 0,
    steer: u8 = 0,
    reply: []const u8 = "",
    directive: []const u8 = "",
};

/// One `op` string per control line at or past `cursor`, walked exactly as `drainControl` walks it: split on
/// '\n', trim " \r\t", skip blanks, parse with `ignore_unknown_fields`. A line the reader cannot parse is
/// skipped there (`catch continue`) and so is missing here — which is how a corrupted line shows up as a
/// failed assertion instead of a silent pass. Caller frees the list and every op string.
fn drainOpsForTest(gpa: std.mem.Allocator, data: []const u8, cursor: usize) !std.ArrayListUnmanaged([]const u8) {
    var ops: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (ops.items) |o| gpa.free(o);
        ops.deinit(gpa);
    }
    if (data.len <= cursor) return ops;
    var it = std.mem.splitScalar(u8, data[cursor..], '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(DrainedOp, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        try ops.append(gpa, try gpa.dupe(u8, p.value.op));
    }
    return ops;
}

fn freeOps(gpa: std.mem.Allocator, ops: *std.ArrayListUnmanaged([]const u8)) void {
    for (ops.items) |o| gpa.free(o);
    ops.deinit(gpa);
}

test "control bus: each op's line is the exact shape run.zig's drainControl parses (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-ctlwriter-shape-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // The three shapes the handler can produce. `stop` never reaches the file in production (it acts
    // immediately), but `veil stop` via any other client writes exactly this, and the reader honors it.
    var say: std.ArrayListUnmanaged(u8) = .empty;
    defer say.deinit(gpa);
    try controlLine(gpa, &say, "say", "all", "focus on the parser", "");
    try std.testing.expectEqualStrings("{\"op\":\"say\",\"to\":\"all\",\"text\":\"focus on the parser\"}\n", say.items);

    var goal: std.ArrayListUnmanaged(u8) = .empty;
    defer goal.deinit(gpa);
    try controlLine(gpa, &goal, "set_goal", "all", "", "ship the parser");
    // `to` is written only alongside `text`, so a goal-only op carries no addressee at all.
    try std.testing.expectEqualStrings("{\"op\":\"set_goal\",\"goal\":\"ship the parser\"}\n", goal.items);

    var stop: std.ArrayListUnmanaged(u8) = .empty;
    defer stop.deinit(gpa);
    try controlLine(gpa, &stop, "stop", "all", "", "");
    try std.testing.expectEqualStrings("{\"op\":\"stop\"}\n", stop.items);

    const path = try std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{root});
    defer gpa.free(path);
    try appendFile(io, gpa, path, say.items);
    try appendFile(io, gpa, path, goal.items);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(data);

    // Reader side: the fields drainControl actually branches on must survive the trip. `say` needs a non-empty
    // `text` to be delivered at all; `set_goal` needs a non-empty `goal` — an op that parses but arrives with
    // the gate field empty is dropped on the floor, so both are asserted, not just the op name.
    var it = std.mem.splitScalar(u8, data, '\n');
    const l0 = std.mem.trim(u8, it.next().?, " \r\t");
    const p0 = try std.json.parseFromSlice(DrainedOp, gpa, l0, .{ .ignore_unknown_fields = true });
    defer p0.deinit();
    try std.testing.expectEqualStrings("say", p0.value.op);
    try std.testing.expectEqualStrings("all", p0.value.to);
    try std.testing.expectEqualStrings("focus on the parser", p0.value.text);

    const l1 = std.mem.trim(u8, it.next().?, " \r\t");
    const p1 = try std.json.parseFromSlice(DrainedOp, gpa, l1, .{ .ignore_unknown_fields = true });
    defer p1.deinit();
    try std.testing.expectEqualStrings("set_goal", p1.value.op);
    try std.testing.expectEqualStrings("ship the parser", p1.value.goal);
    try std.testing.expectEqualStrings("", p1.value.text);
}

test "control bus: a quote/newline/control byte in steer text stays ONE op — no smuggled second line (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-ctlwriter-esc-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // Operator text is arbitrary user input on its way to a file the worker parses line by line. The embedded
    // `}\n{"op":"stop"}` is the attack this escaping exists to stop: unescaped, drainControl's splitScalar
    // would see a SECOND line and wind the whole swarm down because someone typed it in a steer box.
    const nasty = "he said \"go\"}\n{\"op\":\"stop\"}\tand\\then\x01end";
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    try controlLine(gpa, &line, "say", "all", nasty, "a \"quoted\" goal\nsecond line");

    // Exactly one newline, and it is the terminator: the line is intact by construction, before any parse.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line.items, "\n"));
    try std.testing.expectEqual(@as(u8, '\n'), line.items[line.items.len - 1]);

    const path = try std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{root});
    defer gpa.free(path);
    try appendFile(io, gpa, path, line.items);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(data);

    var ops = try drainOpsForTest(gpa, data, 0);
    defer freeOps(gpa, &ops);
    try std.testing.expectEqual(@as(usize, 1), ops.items.len); // ONE op, not a say plus a smuggled stop
    try std.testing.expectEqualStrings("say", ops.items[0]);

    // ...and the operator's words reach the mind byte-for-byte, control byte and all.
    const p = try std.json.parseFromSlice(DrainedOp, gpa, std.mem.trim(u8, data, " \r\n\t"), .{ .ignore_unknown_fields = true });
    defer p.deinit();
    try std.testing.expectEqualStrings(nasty, p.value.text);
    try std.testing.expectEqualStrings("a \"quoted\" goal\nsecond line", p.value.goal);
}

test "control bus: ops accumulate in order, and a cursor drain sees only what is new (real filesystem)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-ctlwriter-order-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    const path = try std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{root});
    defer gpa.free(path);

    const writeOp = struct {
        fn go(g: std.mem.Allocator, i: std.Io, p: []const u8, op: []const u8, text: []const u8, goal: []const u8) !void {
            var l: std.ArrayListUnmanaged(u8) = .empty;
            defer l.deinit(g);
            try controlLine(g, &l, op, "all", text, goal);
            try appendFile(i, g, p, l.items);
        }
    }.go;

    // Each POST is an independent append into a file the worker may be reading concurrently: the bus must GROW,
    // never be rewritten. A writer that clobbered instead of appending would leave one line here, and a
    // byte-cursor reader that saw the file shrink would replay or skip ops.
    try writeOp(gpa, io, path, "say", "first", "");
    const after_first: usize = @intCast((try std.Io.Dir.cwd().statFile(io, path, .{})).size);
    try writeOp(gpa, io, path, "set_goal", "", "second");
    try writeOp(gpa, io, path, "stop", "", "");

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(data);

    var all = try drainOpsForTest(gpa, data, 0);
    defer freeOps(gpa, &all);
    try std.testing.expectEqual(@as(usize, 3), all.items.len);
    try std.testing.expectEqualStrings("say", all.items[0]);
    try std.testing.expectEqualStrings("set_goal", all.items[1]);
    try std.testing.expectEqualStrings("stop", all.items[2]); // arrival order, which is the order the worker applies

    // A worker that already drained the first op resumes at its cursor and must see the two NEW ops only —
    // re-delivering `say first` would re-inject the operator's words into a later round.
    var rest = try drainOpsForTest(gpa, data, after_first);
    defer freeOps(gpa, &rest);
    try std.testing.expectEqual(@as(usize, 2), rest.items.len);
    try std.testing.expectEqualStrings("set_goal", rest.items[0]);
    try std.testing.expectEqualStrings("stop", rest.items[1]);

    // Cursor at EOF: drainControl's `data.len <= cursor` early-out — nothing new, nothing replayed.
    var none = try drainOpsForTest(gpa, data, data.len);
    defer freeOps(gpa, &none);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}
