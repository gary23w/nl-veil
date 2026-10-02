//! `veil --tater` — the terminal door to TATER-TOTS (config/cf_tot.zig): autonomous goal loops that run in the user's own
//! Cloudflare account, with no human in them.
//!
//!   veil --tater                            the roster: every tot, its state, its goal
//!   veil --tater deploy "<goal>" [flags]    deploy one (the first is always named Gary)
//!       --name N  --charter "..."  --model @cf/...  --pace SECONDS (5 and up)  --size MINDS
//!       --calls PER_DAY | unlimited
//!       --budget N  --forever      --local   (let it queue jobs for the veil on THIS machine; deployment only)
//!   veil --tater tell <name> "<text>"       a command (/goal ..., /pause, /queue ...) or a message for its inbox
//!   veil --tater watch <name>               follow its events
//!   veil --tater set <name> [flags]         --model --pace --size --calls --charter --pause --resume
//!   veil --tater pad ["<text>" | --clear]   read the scratchpad the tots share, write to it, or empty it
//!   veil --tater rm <name>                  delete one tot
//!   veil --tater teardown --yes             remove the runtime and every tot from the Cloudflare account
//!
//! Every verb is one call to the local server, which relays to the runtime. Nothing here talks to Cloudflare.

const std = @import("std");
const cli = @import("../cli.zig");
const bu = @import("../worker/browser/util.zig"); // sleepMs: an OS sleep, never io.sleep
const Ctx = cli.Ctx;
const out = cli.out;

const USAGE =
    \\usage: veil --tater                              list your tater-tots
    \\       veil --tater deploy "<goal>" [--name N] [--charter "..."] [--model @cf/...] [--pace SECONDS]
    \\                       [--size MINDS] [--calls PER_DAY] [--budget N] [--forever] [--local]
    \\       veil --tater tell <name> "<text>"         /goal <text>, /goal stop, /queue <goal>, /pause, /resume, or a message
    \\       veil --tater watch <name>                 follow its events
    \\       veil --tater set <name> [--model M] [--pace S] [--size N] [--calls N] [--charter "..."] [--pause|--resume]
    \\       veil --tater pad ["<text>" | --clear]     the scratchpad the tater-tots share (--clear empties it)
    \\       veil --tater rm <name>                    delete one tater-tot
    \\       veil --tater key brave <key>              a search key for the tater-tots (google, google_cx too; --remove)
    \\       veil --tater teardown --yes               remove the runtime and every tater-tot from the account
    \\       (veil tater ... and veil --tater ... do the same)
    \\
;

const Goal = struct { text: []const u8 = "", status: []const u8 = "", iteration: i64 = 0, improved: i64 = 0, budget: i64 = 0, forever: bool = false };
const Tot = struct {
    name: []const u8 = "",
    state: []const u8 = "",
    model: []const u8 = "",
    minds: i64 = 0,
    size: i64 = 0,
    pace_s: i64 = 0,
    calls_today: i64 = 0,
    daily_calls: i64 = 0,
    local: bool = false,
    goal: ?Goal = null,
};
const Roster = struct { ok: bool = false, err: []const u8 = "", connected: bool = false, deployed: bool = false, reachable: bool = false, max: i64 = 0, python: bool = false, browser: bool = false, neuron: bool = false, tools_note: []const u8 = "", last_error: []const u8 = "", tots: []const Tot = &.{} };
const Event = struct { seq: u64 = 0, kind: []const u8 = "", text: []const u8 = "" };
const Events = struct { ok: bool = false, err: []const u8 = "", seq: u64 = 0, events: []const Event = &.{} };
const PadEntry = struct { seq: u64 = 0, from: []const u8 = "", text: []const u8 = "" };
const Pad = struct { ok: bool = false, err: []const u8 = "", entries: []const PadEntry = &.{} };
const Answer = struct { ok: bool = false, err: []const u8 = "", reply: []const u8 = "", tot: ?Tot = null };

/// One roster row. Pure.
pub fn rosterLine(buf: []u8, h: Tot) []const u8 {
    const g: Goal = h.goal orelse .{};
    var gb: [80]u8 = undefined;
    const goal: []const u8 = if (g.text.len == 0) "(no goal: roaming)" else std.fmt.bufPrint(&gb, "{s} {d}/{d}{s}", .{ g.status, g.improved, g.iteration, if (g.forever) " forever" else "" }) catch "";
    var cb: [32]u8 = undefined;
    const calls: []const u8 = if (h.daily_calls > 0) (std.fmt.bufPrint(&cb, "{d}/{d} calls", .{ h.calls_today, h.daily_calls }) catch "") else (std.fmt.bufPrint(&cb, "{d} calls, no limit", .{h.calls_today}) catch "");
    return std.fmt.bufPrint(buf, "{s: <12} {s: <8} {d}/{d} minds  {s}{s}  {s}  {s}", .{
        h.name, h.state, h.minds, h.size, calls, if (h.local) "  +this machine" else "", goal, g.text[0..@min(g.text.len, 70)],
    }) catch h.name;
}

/// One event as a terminal line: the kind in a fixed column, the text with its line breaks kept. Pure.
pub fn eventLine(a: std.mem.Allocator, e: Event) []const u8 {
    return std.fmt.allocPrint(a, "{s: <8} {s}", .{ e.kind[0..@min(e.kind.len, 8)], e.text }) catch e.text;
}

fn fail(what: []const u8, status: u16, body: []const u8, a: std.mem.Allocator) u8 {
    const E = struct { err: []const u8 = "" };
    const e = std.json.parseFromSliceLeaky(E, a, body, .{ .ignore_unknown_fields = true }) catch E{};
    std.debug.print("{s} failed (HTTP {d}): {s}\n", .{ what, status, if (e.err.len > 0) e.err else body[0..@min(body.len, 200)] });
    return 1;
}

/// `--calls unlimited` (or infinite, none, 0) is no limit on model calls: the wire value is 0.
fn callsArg(v: []const u8) []const u8 {
    for ([_][]const u8{ "unlimited", "infinite", "infinity", "none", "off" }) |w| if (std.ascii.eqlIgnoreCase(v, w)) return "0";
    return v;
}

/// `,"a":1,"b":2` (what cli.appendStr / appendNum build) as the object `{"a":1,"b":2}`.
fn object(a: std.mem.Allocator, fields: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(a, "{{{s}}}", .{if (fields.len > 0) fields[1..] else fields}) catch null;
}

pub fn cmd(ctx: *Ctx, args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const verb = if (args.len > 0) args[0] else "ls";
    const rest = if (args.len > 0) args[1..] else args;
    if (std.mem.eql(u8, verb, "ls") or std.mem.eql(u8, verb, "list")) return list(ctx, a);
    if (std.mem.eql(u8, verb, "deploy")) return deploy(ctx, a, rest);
    if (std.mem.eql(u8, verb, "tell")) return tell(ctx, a, rest);
    if (std.mem.eql(u8, verb, "watch") or std.mem.eql(u8, verb, "events")) return watch(ctx, a, rest);
    if (std.mem.eql(u8, verb, "set")) return set(ctx, a, rest);
    if (std.mem.eql(u8, verb, "pad")) return pad(ctx, a, rest);
    if (std.mem.eql(u8, verb, "rm") or std.mem.eql(u8, verb, "delete")) return rm(ctx, a, rest);
    if (std.mem.eql(u8, verb, "teardown")) return teardown(ctx, a, rest);
    if (std.mem.eql(u8, verb, "key")) return key(ctx, a, rest);
    out(USAGE, .{});
    return 1;
}

fn list(ctx: *Ctx, a: std.mem.Allocator) u8 {
    const resp = cli.call(ctx, "GET", "/api/v1/tots", null, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater list", resp.status, resp.body, a);
    const r = std.json.parseFromSliceLeaky(Roster, a, resp.body, .{ .ignore_unknown_fields = true }) catch return fail("--tater list", resp.status, resp.body, a);
    if (!r.connected) out("not connected to Cloudflare: log in with Cloudflare in the desk (Settings > Models) first\n", .{});
    if (!r.deployed) {
        out("(no tater-tots - deploy the first with `veil --tater deploy \"<goal>\"`; it will be named Gary)\n", .{});
        if (r.last_error.len > 0) out("last deployment error: {s}\n", .{r.last_error});
        return 0;
    }
    if (!r.reachable) out("the tot runtime did not answer (a new deployment can take a minute)\n", .{});
    for (r.tots) |h| {
        var b: [400]u8 = undefined;
        out("{s}\n", .{rosterLine(&b, h)});
    }
    if (r.tots.len == 0 and r.reachable) out("(no tater-tots - deploy the first with `veil --tater deploy \"<goal>\"`)\n", .{});
    if (r.reachable) out("tools: files, web search, web fetch, HTTP, memory, plan, swarm{s}{s}{s}\n", .{ if (r.python) ", Python + skills" else "", if (r.browser) ", browser" else "", if (r.neuron) ", neuron-db mind" else "" });
    if (r.tools_note.len > 0) out("{s}\n", .{r.tools_note});
    return 0;
}

fn deploy(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    var goal: []const u8 = "";
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (cli.flagVal(args, &i, x, "--name")) |v| cli.appendStr(a, &jb, "name", v) else if (cli.flagVal(args, &i, x, "--charter")) |v| cli.appendStr(a, &jb, "charter", v) else if (cli.flagVal(args, &i, x, "--model")) |v| cli.appendStr(a, &jb, "model", v) else if (cli.flagVal(args, &i, x, "--pace")) |v| cli.appendNum(a, &jb, "pace_s", v) else if (cli.flagVal(args, &i, x, "--size")) |v| cli.appendNum(a, &jb, "size", v) else if (cli.flagVal(args, &i, x, "--calls")) |v| cli.appendNum(a, &jb, "daily_calls", callsArg(v)) else if (cli.flagVal(args, &i, x, "--budget")) |v| cli.appendNum(a, &jb, "budget", v) else if (std.mem.eql(u8, x, "--forever")) {
            jb.appendSlice(a, ",\"forever\":true") catch return 1;
        } else if (std.mem.eql(u8, x, "--local")) {
            jb.appendSlice(a, ",\"local\":true") catch return 1;
        } else if (x.len > 0 and x[0] != '-' and goal.len == 0) {
            goal = x;
        } else {
            out(USAGE, .{});
            return 1;
        }
    }
    cli.appendStr(a, &jb, "goal", goal);
    const body = object(a, jb.items) orelse return 1;
    out("deploying (the first deployment uploads the runtime into your Cloudflare account; it can take a minute)...\n", .{});
    const resp = cli.call(ctx, "POST", "/api/v1/tots", body, 120, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 201) return fail("--tater deploy", resp.status, resp.body, a);
    const r = std.json.parseFromSliceLeaky(Answer, a, resp.body, .{ .ignore_unknown_fields = true }) catch Answer{};
    const h: Tot = r.tot orelse .{};
    out("{s} is deployed and working. `veil --tater watch {s}` follows it; `veil --tater tell {s} \"...\"` talks to it.\n", .{ h.name, h.name, h.name });
    if (h.local) out("{s} may queue jobs for the veil on this machine; they run while this server is up.\n", .{h.name});
    return 0;
}

fn tell(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 2) {
        out(USAGE, .{});
        return 1;
    }
    const text = std.mem.join(a, " ", args[1..]) catch return 1;
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    jb.appendSlice(a, "{\"text\":") catch return 1;
    cli.jstr(a, &jb, text);
    jb.append(a, '}') catch return 1;
    const path = std.fmt.allocPrint(a, "/api/v1/tots/{s}/command", .{args[0]}) catch return 1;
    const resp = cli.call(ctx, "POST", path, jb.items, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater tell", resp.status, resp.body, a);
    const r = std.json.parseFromSliceLeaky(Answer, a, resp.body, .{ .ignore_unknown_fields = true }) catch Answer{};
    out("{s}\n", .{r.reply});
    return 0;
}

fn watch(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 1) {
        out(USAGE, .{});
        return 1;
    }
    var after: u64 = 0;
    var misses: usize = 0;
    while (true) {
        var pass = std.heap.ArenaAllocator.init(ctx.gpa);
        defer pass.deinit();
        const pa = pass.allocator();
        const path = std.fmt.allocPrint(pa, "/api/v1/tots/{s}/events?after={d}", .{ args[0], after }) catch return 1;
        const resp = cli.call(ctx, "GET", path, null, 40, after == 0) catch {
            if (after == 0) return cli.unreachable_msg(ctx);
            misses += 1;
            if (misses > 20) return 1;
            bu.sleepMs(3000);
            continue;
        };
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) {
            if (after == 0) return fail("--tater watch", resp.status, resp.body, a);
        } else if (std.json.parseFromSliceLeaky(Events, pa, resp.body, .{ .ignore_unknown_fields = true })) |r| {
            misses = 0;
            for (r.events) |e| {
                out("{s}\n", .{eventLine(pa, e)});
                after = @max(after, e.seq);
            }
        } else |_| {}
        bu.sleepMs(3000);
    }
}

fn set(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 2) {
        out(USAGE, .{});
        return 1;
    }
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (cli.flagVal(args, &i, x, "--model")) |v| cli.appendStr(a, &jb, "model", v) else if (cli.flagVal(args, &i, x, "--charter")) |v| cli.appendStr(a, &jb, "charter", v) else if (cli.flagVal(args, &i, x, "--pace")) |v| cli.appendNum(a, &jb, "pace_s", v) else if (cli.flagVal(args, &i, x, "--size")) |v| cli.appendNum(a, &jb, "size", v) else if (cli.flagVal(args, &i, x, "--calls")) |v| cli.appendNum(a, &jb, "daily_calls", callsArg(v)) else if (std.mem.eql(u8, x, "--pause")) {
            jb.appendSlice(a, ",\"paused\":true") catch return 1;
        } else if (std.mem.eql(u8, x, "--resume")) {
            jb.appendSlice(a, ",\"paused\":false") catch return 1;
        } else {
            out(USAGE, .{});
            return 1;
        }
    }
    const body = object(a, jb.items) orelse return 1;
    const path = std.fmt.allocPrint(a, "/api/v1/tots/{s}/config", .{args[0]}) catch return 1;
    const resp = cli.call(ctx, "POST", path, body, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater set", resp.status, resp.body, a);
    const r = std.json.parseFromSliceLeaky(Answer, a, resp.body, .{ .ignore_unknown_fields = true }) catch Answer{};
    var b: [400]u8 = undefined;
    out("{s}\n", .{rosterLine(&b, r.tot orelse .{})});
    return 0;
}

fn pad(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--clear")) {
        const resp = cli.call(ctx, "POST", "/api/v1/tots/pad/clear", "{}", 40, true) catch return cli.unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) return fail("--tater pad --clear", resp.status, resp.body, a);
        out("the scratchpad is empty (this machine kept a copy in _tots/)\n", .{});
        return 0;
    }
    if (args.len > 0) {
        const text = std.mem.join(a, " ", args) catch return 1;
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        jb.appendSlice(a, "{\"text\":") catch return 1;
        cli.jstr(a, &jb, text);
        jb.append(a, '}') catch return 1;
        const resp = cli.call(ctx, "POST", "/api/v1/tots/pad", jb.items, 40, true) catch return cli.unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) return fail("--tater pad", resp.status, resp.body, a);
        out("written\n", .{});
        return 0;
    }
    const resp = cli.call(ctx, "GET", "/api/v1/tots/pad", null, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater pad", resp.status, resp.body, a);
    const r = std.json.parseFromSliceLeaky(Pad, a, resp.body, .{ .ignore_unknown_fields = true }) catch Pad{};
    for (r.entries) |e| out("{d}. {s}: {s}\n", .{ e.seq, e.from, e.text });
    if (r.entries.len == 0) out("(the scratchpad is empty)\n", .{});
    return 0;
}

fn rm(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 1) {
        out(USAGE, .{});
        return 1;
    }
    const path = std.fmt.allocPrint(a, "/api/v1/tots/{s}", .{args[0]}) catch return 1;
    const resp = cli.call(ctx, "DELETE", path, null, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater rm", resp.status, resp.body, a);
    const R = struct { worker_removed: bool = false, note: []const u8 = "" };
    const r = std.json.parseFromSliceLeaky(R, a, resp.body, .{ .ignore_unknown_fields = true }) catch R{};
    out("deleted {s}\n", .{args[0]});
    if (r.worker_removed) out("it was the last tot, so the veil-tots Worker is removed from your Cloudflare account too\n", .{});
    if (r.note.len > 0) out("{s}\n", .{r.note});
    return 0;
}

/// `veil --tater key brave|google|google_cx <value>` gives the tots a search key; `--remove` takes it away.
fn key(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 2) {
        out("usage: veil --tater key brave <key>        a Brave Search API key: web_search asks it first\n       veil --tater key google <key>  +  veil --tater key google_cx <engine id>\n       veil --tater key <name> --remove\n", .{});
        return 1;
    }
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    cli.appendStr(a, &jb, "name", args[0]);
    cli.appendStr(a, &jb, "value", if (std.mem.eql(u8, args[1], "--remove")) "" else args[1]);
    const body = object(a, jb.items) orelse return 1;
    const resp = cli.call(ctx, "POST", "/api/v1/tots/keys", body, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater key", resp.status, resp.body, a);
    out("{s} key {s}\n", .{ args[0], if (std.mem.eql(u8, args[1], "--remove")) "removed" else "set: every tot's web_search uses it from its next iteration" });
    return 0;
}

fn teardown(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 1 or !std.mem.eql(u8, args[0], "--yes")) {
        out("this removes the tot runtime, every tot and everything they stored from your Cloudflare account.\nrun `veil --tater teardown --yes` to do it.\n", .{});
        return 1;
    }
    const resp = cli.call(ctx, "DELETE", "/api/v1/tots", null, 60, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater teardown", resp.status, resp.body, a);
    out("the tot runtime is removed from the account\n", .{});
    return 0;
}

test "tot cli: a roster row reads the runtime's own status JSON, and an event keeps its text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\{"ok":true,"connected":true,"deployed":true,"reachable":true,"max":3,"tots":[{"name":"Gary","state":"working","model":"@cf/x/y","minds":2,"size":3,"pace_s":600,"calls_today":41,"daily_calls":400,"local":true,"unknown":1,"goal":{"text":"map every harbour","status":"active","iteration":7,"improved":4,"budget":0,"forever":true}},{"name":"Ada","state":"roaming","goal":null}]}
    ;
    const r = try std.json.parseFromSliceLeaky(Roster, a, body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 2), r.tots.len);
    var b: [400]u8 = undefined;
    const row = rosterLine(&b, r.tots[0]);
    try std.testing.expect(std.mem.startsWith(u8, row, "Gary "));
    try std.testing.expect(std.mem.indexOf(u8, row, "2/3 minds") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "41/400 calls  +this machine") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "active 4/7 forever  map every harbour") != null);
    try std.testing.expect(std.mem.indexOf(u8, rosterLine(&b, r.tots[1]), "(no goal: roaming)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rosterLine(&b, .{ .name = "Ada", .calls_today = 7, .daily_calls = 0 }), "7 calls, no limit") != null);
    try std.testing.expectEqualStrings("0", callsArg("Unlimited"));
    try std.testing.expectEqualStrings("250", callsArg("250"));
    const ev = try std.json.parseFromSliceLeaky(Events, a, "{\"ok\":true,\"seq\":2,\"events\":[{\"seq\":2,\"t\":1,\"kind\":\"verdict\",\"text\":\"improved [3/10]: saved\",\"i\":1}]}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("verdict  improved [3/10]: saved", eventLine(a, ev.events[0]));
}
