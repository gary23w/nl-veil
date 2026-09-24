//! Lineage HTTP handlers — what a lineage has learned, and the review of what it proposed.
//!
//!   GET  /api/v1/lineages                   this account's lineages with their live and quarantined counts
//!   GET  /api/v1/lineages/:id               one lineage: the same counts plus its cast history (history.jsonl)
//!   GET  /api/v1/lineages/:id/proposals     the quarantined proposals, one row per stored line
//!   POST /api/v1/lineages/:id/proposals     {"scope","text","action":"accept"|"reject"} — proposals.decide
//!
//! A lineage lives at {data}/u{uid}/_lineage/<slug>/mind.sqlite (lineage.zig), so the account is part of the
//! path and the slug cannot climb out of it. These handlers only READ an existing lineage; none of them
//! creates one.

const std = @import("std");
const httpz = @import("httpz");

const http = @import("../../gateway/http.zig");
const osc = @import("../oscillation.zig");
const tools = @import("../tools.zig");
const lineage = @import("../lineage.zig");
const proposals = @import("../proposals.zig");
const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const notFound = http.notFound;
const serverErr = http.serverErr;
const jstr = http.jstr;

/// At most this many lineages are counted per listing: each count is a neuron subprocess.
const LIST_MAX = 32;
/// The newest casts a detail returns.
const HISTORY_MAX = 100;

/// The lineage's history.jsonl body ("" when it has none yet). Caller frees a non-empty result.
fn readHistory(app: *App, gpa: std.mem.Allocator, db: []const u8) []const u8 {
    var pb: [1024]u8 = undefined;
    const path = lineage.historyPath(&pb, db) orelse return "";
    return std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(4 << 20)) catch "";
}

/// Rows in a history body.
fn castCount(body: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| {
        if (std.mem.trim(u8, l, " \r\t").len > 1) n += 1;
    }
    return n;
}

fn writeCounts(out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, mem: osc.Mem, casts: usize) !void {
    var pending: u32 = 0;
    for (proposals.SOURCES) |s| pending += mem.factCount(s.scope);
    try out.print(arena, ",\"lessons\":{d},\"facts\":{d},\"skills\":{d},\"playbook\":{d},\"pending\":{d},\"rejected\":{d},\"casts\":{d}", .{
        mem.factCount(tools.LESSON_SCOPE),
        mem.factCount(tools.FACT_SCOPE),
        mem.factCount(tools.SKILL_SCOPE),
        mem.factCount(tools.PLAYBOOK_SCOPE),
        pending,
        mem.factCount(tools.PROPOSAL_REJECTED_SCOPE),
        casts,
    });
}

fn userRoot(app: *App, arena: std.mem.Allocator, uid: u64) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/u{d}", .{ app.data, uid });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    return if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| st.size > 0 else |_| false;
}

/// The existing lineage db the request names, or null after answering 404/400.
fn lineageDb(app: *App, req: *httpz.Request, res: *httpz.Response, uid: u64) !?[]u8 {
    const id = req.param("id") orelse {
        try badReq(res, "no lineage id");
        return null;
    };
    const root = try userRoot(app, res.arena, uid);
    const db = lineage.dbPathIn(res.arena, root, id) orelse {
        try badReq(res, "empty lineage id");
        return null;
    };
    if (!fileExists(app.io, db)) {
        try notFound(res);
        return null;
    }
    return db;
}

pub fn listLineages(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const root = try userRoot(app, res.arena, u.id);
    const ldir = try std.fmt.allocPrint(res.arena, "{s}/_lineage", .{root});
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(res.arena, "{\"lineages\":[");
    var n: usize = 0;
    if (std.Io.Dir.cwd().openDir(app.io, ldir, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |ent| {
            if (n >= LIST_MAX) break;
            if (ent.kind != .directory and ent.kind != .unknown) continue;
            const db = try std.fmt.allocPrint(res.arena, "{s}/{s}/mind.sqlite", .{ ldir, ent.name });
            if (!fileExists(app.io, db)) continue;
            const mem = osc.Mem.init(app.gpa, app.io, app.sup.neuron_bin, db);
            const hist = readHistory(app, app.gpa, db);
            defer if (hist.len > 0) app.gpa.free(hist);
            if (n > 0) try out.append(res.arena, ',');
            try out.appendSlice(res.arena, "{\"id\":");
            try jstr(res.arena, &out, ent.name);
            try writeCounts(&out, res.arena, mem, castCount(hist));
            try out.append(res.arena, '}');
            n += 1;
        }
    } else |_| {}
    try out.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = out.items;
}

pub fn lineageDetail(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const db = (try lineageDb(app, req, res, u.id)) orelse return;
    const mem = osc.Mem.init(app.gpa, app.io, app.sup.neuron_bin, db);
    const hist = readHistory(app, app.gpa, db);
    defer if (hist.len > 0) app.gpa.free(hist);
    const arr = try lineage.historyArray(res.arena, hist, HISTORY_MAX);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(res.arena, "{\"id\":");
    var sb: [96]u8 = undefined;
    try jstr(res.arena, &out, lineage.slug(req.param("id") orelse "", &sb));
    try writeCounts(&out, res.arena, mem, castCount(hist));
    try out.appendSlice(res.arena, ",\"history\":");
    try out.appendSlice(res.arena, arr);
    try out.append(res.arena, '}');
    res.content_type = .JSON;
    res.body = out.items;
}

pub fn listProposals(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const db = (try lineageDb(app, req, res, u.id)) orelse return;
    const mem = osc.Mem.init(app.gpa, app.io, app.sup.neuron_bin, db);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(res.arena, "{\"proposals\":[");
    var n: usize = 0;
    for (proposals.SOURCES) |s| {
        const body = mem.list(s.scope);
        defer app.gpa.free(body);
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (n > 0) try out.append(res.arena, ',');
            try out.appendSlice(res.arena, "{\"scope\":");
            try jstr(res.arena, &out, s.scope);
            try out.appendSlice(res.arena, ",\"kind\":");
            try jstr(res.arena, &out, s.kind);
            try out.appendSlice(res.arena, ",\"text\":");
            try jstr(res.arena, &out, line);
            try out.append(res.arena, '}');
            n += 1;
        }
    }
    try out.appendSlice(res.arena, "]}");
    res.content_type = .JSON;
    res.body = out.items;
}

const DecideReq = struct {
    scope: []const u8 = "",
    text: []const u8 = "",
    action: []const u8 = "",
};

pub fn decideProposal(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const body = (req.json(DecideReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    const accept = if (std.mem.eql(u8, body.action, "accept")) true else if (std.mem.eql(u8, body.action, "reject")) false else return badReq(res, "action must be accept or reject");
    if (proposals.sourceFor(body.scope) == null) return badReq(res, "scope is not a proposal quarantine");
    const db = (try lineageDb(app, req, res, u.id)) orelse return;
    const mem = osc.Mem.init(app.gpa, app.io, app.sup.neuron_bin, db);
    switch (proposals.decide(mem, body.scope, body.text, accept)) {
        .accepted => try res.json(.{ .ok = true, .outcome = "accepted" }, .{}),
        .rejected => try res.json(.{ .ok = true, .outcome = "rejected" }, .{}),
        .missing => {
            res.status = 404;
            try res.json(.{ .ok = false, .err = "no such pending proposal" }, .{});
        },
        .failed => try serverErr(res, "could not write the live scope; the proposal stays queued"),
    }
}

// ---------------------------------------------------------------------------
// tests — the same three guarantees as the deploy routes: nobody anonymous gets in, nobody reaches another
// account's lineage, and the id cannot name a path outside the account's own _lineage dir.
// ---------------------------------------------------------------------------

const Handler = *const fn (*App, *httpz.Request, *httpz.Response) anyerror!void;

const LINEAGE_ROUTES = [_]struct { name: []const u8, f: Handler }{
    .{ .name = "listLineages", .f = listLineages },
    .{ .name = "lineageDetail", .f = lineageDetail },
    .{ .name = "listProposals", .f = listProposals },
    .{ .name = "decideProposal", .f = decideProposal },
};

test "lineage routes: every pub route in this file is covered by the auth sweep" {
    const SRC = @embedFile("lineage_api.zig");
    var it = std.mem.splitScalar(u8, SRC, '\n');
    var found: usize = 0;
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "pub fn ")) continue;
        if (std.mem.indexOf(u8, line, "*httpz.Request") == null) continue;
        const open = std.mem.indexOfScalar(u8, line, '(') orelse continue;
        const name = line["pub fn ".len..open];
        found += 1;
        var listed = false;
        for (LINEAGE_ROUTES) |r| {
            if (std.mem.eql(u8, r.name, name)) listed = true;
        }
        if (!listed) {
            std.debug.print("\nroute '{s}' is not in LINEAGE_ROUTES — add it to the auth sweep\n", .{name});
            return error.UnsweptRoute;
        }
    }
    try std.testing.expectEqual(LINEAGE_ROUTES.len, found);
}

test "lineage routes: no route serves an anonymous caller" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-lineage-gate-tmp");
    defer ta.deinit();
    for (LINEAGE_ROUTES) |r| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.param("id", "whatever");
        try r.f(&ta.app, web.req, web.res);
        web.expectStatus(401) catch |e| {
            std.debug.print("\n{s} answered a stranger with {d}\n", .{ r.name, web.res.status });
            return e;
        };
    }
}

test "lineage routes: review reaches only the caller's own lineage, and a decision lands in the store" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-lineage-tenant-tmp");
    defer ta.deinit();
    std.Io.Dir.cwd().access(io, ta.app.sup.neuron_bin, .{}) catch return error.SkipZigTest;

    ta.auth.register("one@example.test", "correct horse battery") catch return error.SkipZigTest;
    ta.auth.register("two@example.test", "correct horse battery") catch return error.SkipZigTest;
    const tok_one = ta.auth.login("one@example.test", "correct horse battery") catch return error.SkipZigTest;
    defer gpa.free(tok_one);
    const tok_two = ta.auth.login("two@example.test", "correct horse battery") catch return error.SkipZigTest;
    defer gpa.free(tok_two);
    const cookie_one = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{tok_one});
    defer gpa.free(cookie_one);
    const cookie_two = try std.fmt.allocPrint(gpa, http.COOKIE ++ "={s}", .{tok_two});
    defer gpa.free(cookie_two);
    const uid_one = (ta.auth.whoami(tok_one) orelse return error.TestUnexpectedResult).id;

    // account one's lineage "proj", holding one queued lesson
    const dir = try std.fmt.allocPrint(gpa, "zig-lineage-tenant-tmp/u{d}/_lineage/proj", .{uid_one});
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    const db = try std.fmt.allocPrint(gpa, "{s}/mind.sqlite", .{dir});
    defer gpa.free(db);
    const mem = osc.Mem.init(gpa, io, ta.app.sup.neuron_bin, db);
    const LESSON = "Run the formatter before the linter so the linter sees final code | evidence: rows 4 and 7";
    if (mem.observe(tools.LESSON_PROPOSED_SCOPE, LESSON) == 0) return error.SkipZigTest;

    // account two: the same id names ITS OWN (absent) lineage, so it is not found — never account one's
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_two);
        web.param("id", "proj");
        try listProposals(&ta.app, web.req, web.res);
        try web.expectStatus(404);
        try std.testing.expect(std.mem.indexOf(u8, web.res.body, "formatter") == null);
    }
    // a traversal-shaped id is slugged into a plain name inside the caller's own _lineage dir
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_two);
        const up = try std.fmt.allocPrint(gpa, "../u{d}/_lineage/proj", .{uid_one});
        defer gpa.free(up);
        web.param("id", up);
        try listProposals(&ta.app, web.req, web.res);
        try web.expectStatus(404);
    }
    // account one sees the proposal and the lineage count
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_one);
        web.param("id", "proj");
        try listProposals(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        try std.testing.expect(std.mem.indexOf(u8, web.res.body, "\"kind\":\"lesson\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, web.res.body, "formatter before the linter") != null);
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_one);
        try listLineages(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        try std.testing.expect(std.mem.indexOf(u8, web.res.body, "\"id\":\"proj\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, web.res.body, "\"pending\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, web.res.body, "\"casts\":0") != null);
    }
    // a finished cast's history row is served by the detail route, to the owner only
    {
        var hb: [512]u8 = undefined;
        const row = lineage.historyLine(&hb, .{ .t = 1, .run = "c1", .reason = "completed", .rounds = 2, .best_pct = 90, .calls = 9, .tok_in = 100, .tok_out = 10, .proposed = 1, .inherited = false });
        const hp = try std.fmt.allocPrint(gpa, "{s}/history.jsonl", .{dir});
        defer gpa.free(hp);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hp, .data = row });
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_one);
        web.param("id", "proj");
        try lineageDetail(&ta.app, web.req, web.res);
        try web.expectStatus(200);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, web.res.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("casts").?.integer);
        const h = parsed.value.object.get("history").?.array;
        try std.testing.expectEqual(@as(usize, 1), h.items.len);
        try std.testing.expectEqual(@as(i64, 90), h.items[0].object.get("best_pct").?.integer);
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_two);
        web.param("id", "proj");
        try lineageDetail(&ta.app, web.req, web.res);
        try web.expectStatus(404);
    }
    // account two cannot decide it
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_two);
        web.param("id", "proj");
        web.json(.{ .scope = tools.LESSON_PROPOSED_SCOPE, .text = LESSON, .action = "accept" });
        try decideProposal(&ta.app, web.req, web.res);
        try web.expectStatus(404);
    }
    // a bad action or a live scope is refused before the store is touched
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_one);
        web.param("id", "proj");
        web.json(.{ .scope = tools.LESSON_SCOPE, .text = LESSON, .action = "accept" });
        try decideProposal(&ta.app, web.req, web.res);
        try web.expectStatus(400);
    }
    // account one accepts it: it leaves the quarantine and is recallable from the live scope
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.header("cookie", cookie_one);
        web.param("id", "proj");
        web.json(.{ .scope = tools.LESSON_PROPOSED_SCOPE, .text = LESSON, .action = "accept" });
        try decideProposal(&ta.app, web.req, web.res);
        try web.expectStatus(200);
    }
    try std.testing.expectEqual(@as(u32, 0), mem.factCount(tools.LESSON_PROPOSED_SCOPE));
    const live = mem.list(tools.LESSON_SCOPE);
    defer gpa.free(live);
    try std.testing.expect(std.mem.indexOf(u8, live, "formatter before the linter") != null);
}
