//! `veil --tater` — the terminal door to TATER-TOTS (config/cf_tot.zig): autonomous goal loops that run in the user's own
//! Cloudflare account, with no human in them.
//!
//!   veil --tater                            the roster: every tot, its state, its goal
//!   veil --tater deploy "<goal>" [flags]    deploy one (the first is always named Gary)
//!       --name N  --charter "..."  --model @cf/...  --pace SECONDS (5 and up)  --size MINDS
//!       --calls PER_DAY | unlimited
//!       --budget N  --forever      --local   (let it queue jobs for the veil on THIS machine; deployment only)
//!       --garrett                  (Agent Garrett's security tools on its belt; Settings must have deployed the agent)
//!   veil --tater tell <name> "<text>"       a command (/goal ..., /pause, /queue ...) or a message for its inbox
//!   veil --tater watch <name>               follow its events
//!   veil --tater set <name> [flags]         --model --pace --size --calls --charter --pause --resume --posture --leash --garrett on|off
//!   veil --tater guard <name> ...           what it watches every heartbeat without a model (its /guard command)
//!   veil --tater verify <run>               check a run's evidence chain: every mirrored event hashed to the one before
//!   veil --tater garrett [launch|rm|password]  Agent Garrett: the blue-team agent a chat, a swarm or a tot can use over MCP
//!   veil --tater pad ["<text>" | --clear]   read the scratchpad the tots share, write to it, or empty it
//!   veil --tater rm <name>                  delete one tot
//!   veil --tater teardown --yes             remove the runtime and every tot from the Cloudflare account
//!
//! Every verb is one call to the local server, which relays to the runtime. Nothing here talks to Cloudflare.
//! `verify` is the one verb that computes anything: it recomputes the runtime's evidence chain (Chain, chainHash)
//! over the rows the server reads from the run's own events.jsonl, so a tampered file is caught on this machine.

const std = @import("std");
const cli = @import("../cli.zig");
const bu = @import("../worker/browser/util.zig"); // sleepMs: an OS sleep, never io.sleep
const Ctx = cli.Ctx;
const out = cli.out;

const USAGE =
    \\usage: veil --tater                              list your tater-tots
    \\       veil --tater deploy "<goal>" [--name N] [--charter "..."] [--model @cf/...] [--pace SECONDS]
    \\                       [--size MINDS] [--calls PER_DAY] [--budget N] [--forever] [--local]
    \\                       [--posture defend] [--leash SECONDS] [--garrett]
    \\       veil --tater tell <name> "<text>"         /goal <text>, /goal stop, /queue <goal>, /pause, /resume, or a message
    \\       veil --tater watch <name>                 follow its events
    \\       veil --tater set <name> [--model M] [--pace S] [--size N] [--calls N] [--charter "..."] [--pause|--resume]
    \\                       [--posture defend|normal] [--leash SECONDS|off] [--garrett on|off]
    \\       veil --tater guard <name>                 what it watches every heartbeat, with no model
    \\       veil --tater guard <name> add <https://...> [--text "words on the page"] [--status N] [--every S] [--pin]
    \\       veil --tater guard <name> add dns:<host> [--type A|AAAA|NS|MX|TXT|CNAME|CAA|SOA] [--every S]
    \\       veil --tater guard <name> rm <target|#n> | clear
    \\       veil --tater verify <run>                 check a run's evidence chain (a run: <name>-<YYYYMMDD-HHMMSS>)
    \\       veil --tater garrett [launch|rm|password] Agent Garrett: the blue-team agent chats, swarms and tater-tots can use over MCP
    \\       veil --tater pad ["<text>" | --clear]     the scratchpad the tater-tots share (--clear empties it)
    \\       veil --tater limit [N]                    how many this account may run (24 by default; 1 to 1000)
    \\       veil --tater rm <name>                    delete one tater-tot
    \\       veil --tater key brave <key>              a search key for the tater-tots (google, google_cx too; --remove)
    \\       veil --tater key alert <https://...>      the guard's webhook (a Discord or Slack webhook URL works as it is)
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
    posture: []const u8 = "",
    watch: i64 = 0,
    guard_tripped: i64 = 0,
    garrett: bool = false, // its verbs are on this tot's belt (asked for, and the account has the agent)
    garrett_on: bool = false, // asked for (the deploy box, --garrett, /garrett on)
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
    var wb: [40]u8 = undefined;
    const guard_col: []const u8 = if (h.watch > 0) (std.fmt.bufPrint(&wb, "  guard {d}{s}", .{ h.watch, if (h.guard_tripped > 0) " TRIPPED" else "" }) catch "") else "";
    return std.fmt.bufPrint(buf, "{s: <12} {s: <8} {d}/{d} minds  {s}{s}{s}{s}{s}  {s}  {s}", .{
        h.name, h.state, h.minds, h.size, calls, if (h.local) "  +this machine" else "", if (std.mem.eql(u8, h.posture, "defend")) "  DEFEND" else "", if (h.garrett_on) "  +garrett" else "", guard_col, goal, g.text[0..@min(g.text.len, 70)],
    }) catch h.name;
}

/// One mirrored event as `verify` reads it: the fields the chain covers, and the chain fields themselves. A row an
/// older runtime wrote has neither `prev` nor `hash`.
pub const ChainEvent = struct { seq: u64 = 0, t: i64 = 0, kind: []const u8 = "", text: []const u8 = "", prev: ?[]const u8 = null, hash: ?[]const u8 = null };
const ChainEvents = struct { ok: bool = false, err: []const u8 = "", events: []const ChainEvent = &.{} };

/// The evidence chain exactly as cloud/tot.js chainHash writes it: SHA-256 of "<prev>\n<seq>\n<t>\n<kind>\n<text>",
/// as 64 hex characters. Pure.
pub fn chainHash(prev: []const u8, seq: u64, t: i64, kind: []const u8, text: []const u8, hex: *[64]u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var nb: [24]u8 = undefined;
    h.update(prev);
    h.update("\n");
    h.update(std.fmt.bufPrint(&nb, "{d}", .{seq}) catch "");
    h.update("\n");
    h.update(std.fmt.bufPrint(&nb, "{d}", .{t}) catch "");
    h.update("\n");
    h.update(kind);
    h.update("\n");
    h.update(text);
    var dig: [32]u8 = undefined;
    h.final(&dig);
    hex.* = std.fmt.bytesToHex(dig, .lower);
    return hex;
}

/// Walks a run's rows oldest first: a signed row must hash as written and point at the signed row before it; an
/// unsigned row (an older runtime's) is counted, not judged. The first signed row's `prev` is taken as given: it
/// is the anchor. Pure.
pub const Chain = struct {
    signed: u64 = 0,
    unsigned: u64 = 0,
    first_seq: u64 = 0,
    last_seq: u64 = 0,
    last_hash: [64]u8 = [_]u8{'0'} ** 64,
    linked: bool = false,
    broken_seq: u64 = 0,
    why: []const u8 = "",

    /// False once the chain is broken; `broken_seq` and `why` say where and how.
    pub fn step(c: *Chain, e: ChainEvent) bool {
        if (c.broken_seq != 0) return false;
        const hash = e.hash orelse {
            c.unsigned += 1;
            return true;
        };
        if (hash.len != 64) {
            c.unsigned += 1;
            return true;
        }
        const prev = e.prev orelse "";
        if (c.linked and !std.mem.eql(u8, prev, &c.last_hash)) {
            c.broken_seq = e.seq;
            c.why = "it does not follow the signed event before it: a row between them is missing, or this one is not from this run";
            return false;
        }
        var hb: [64]u8 = undefined;
        if (!std.mem.eql(u8, chainHash(prev, e.seq, e.t, e.kind, e.text, &hb), hash)) {
            c.broken_seq = e.seq;
            c.why = "its hash does not match its text: the row was altered";
            return false;
        }
        @memcpy(&c.last_hash, hash);
        c.linked = true;
        if (c.signed == 0) c.first_seq = e.seq;
        c.last_seq = e.seq;
        c.signed += 1;
        return true;
    }
};

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

/// `--garrett off` (or false, no, 0) takes Agent Garrett off a tot's belt; anything else puts it on.
fn garrettOff(v: []const u8) bool {
    for ([_][]const u8{ "off", "false", "no", "0" }) |w| if (std.ascii.eqlIgnoreCase(v, w)) return true;
    return false;
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
    if (std.mem.eql(u8, verb, "limit")) return limit(ctx, a, rest);
    if (std.mem.eql(u8, verb, "guard")) return guard(ctx, a, rest);
    if (std.mem.eql(u8, verb, "verify")) return verify(ctx, a, rest);
    if (std.mem.eql(u8, verb, "garrett")) return garrett(ctx, a, rest);
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
    out("{d} of {d} (`veil --tater limit N` changes the limit)\n", .{ r.tots.len, r.max });
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
        } else if (std.mem.eql(u8, x, "--garrett")) {
            jb.appendSlice(a, ",\"garrett\":true") catch return 1;
        } else if (cli.flagVal(args, &i, x, "--posture")) |v| {
            cli.appendStr(a, &jb, "posture", v);
        } else if (cli.flagVal(args, &i, x, "--leash")) |v| {
            cli.appendNum(a, &jb, "leash_s", leashArg(v));
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
    return command(ctx, a, args[0], text, "--tater tell");
}

/// One command or message to a tot, and its reply printed.
fn command(ctx: *Ctx, a: std.mem.Allocator, name: []const u8, text: []const u8, what: []const u8) u8 {
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    jb.appendSlice(a, "{\"text\":") catch return 1;
    cli.jstr(a, &jb, text);
    jb.append(a, '}') catch return 1;
    const path = std.fmt.allocPrint(a, "/api/v1/tots/{s}/command", .{name}) catch return 1;
    const resp = cli.call(ctx, "POST", path, jb.items, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail(what, resp.status, resp.body, a);
    const r = std.json.parseFromSliceLeaky(Answer, a, resp.body, .{ .ignore_unknown_fields = true }) catch Answer{};
    out("{s}\n", .{r.reply});
    return 0;
}

/// `veil --tater guard <name> [add|rm|clear ...]`: the words after the name are the tot's own /guard command. An
/// argument with spaces in it (a --text phrase the shell passed whole) is quoted again, so the runtime reads it as
/// one. Pure.
pub fn guardCommand(a: std.mem.Allocator, args: []const []const u8) ?[]const u8 {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    text.appendSlice(a, "/guard") catch return null;
    for (args) |x| {
        text.append(a, ' ') catch return null;
        if (std.mem.indexOfAny(u8, x, " \t") != null) {
            text.append(a, '"') catch return null;
            for (x) |c| text.append(a, if (c == '"') '\'' else c) catch return null;
            text.append(a, '"') catch return null;
        } else text.appendSlice(a, x) catch return null;
    }
    return text.items;
}

fn guard(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 1) {
        out(USAGE, .{});
        return 1;
    }
    return command(ctx, a, args[0], guardCommand(a, args[1..]) orelse return 1, "--tater guard");
}

/// `--leash off` (or none, no) is no leash: the wire value is 0.
fn leashArg(v: []const u8) []const u8 {
    for ([_][]const u8{ "off", "none", "no" }) |w| if (std.ascii.eqlIgnoreCase(v, w)) return "0";
    return v;
}

/// `veil --tater verify <run>`: walk the run's mirrored events from the first on, recomputing the chain.
fn verify(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 1) {
        out("usage: veil --tater verify <run>     a run is its folder under _tots/: <name>-<YYYYMMDD-HHMMSS>, as the desk's past runs list it\n", .{});
        return 1;
    }
    var chain: Chain = .{};
    var after: u64 = 0;
    var pages: usize = 0;
    var rows: u64 = 0;
    while (pages < 512) : (pages += 1) {
        var pass = std.heap.ArenaAllocator.init(ctx.gpa);
        defer pass.deinit();
        const pa = pass.allocator();
        const path = std.fmt.allocPrint(pa, "/api/v1/tots/runs/{s}/events?after={d}&limit=2000&forward=1", .{ args[0], after }) catch return 1;
        const resp = cli.call(ctx, "GET", path, null, 40, true) catch return cli.unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) return fail("--tater verify", resp.status, resp.body, a);
        const r = std.json.parseFromSliceLeaky(ChainEvents, pa, resp.body, .{ .ignore_unknown_fields = true }) catch return fail("--tater verify", resp.status, resp.body, a);
        if (!r.ok) return fail("--tater verify", resp.status, resp.body, a);
        if (r.events.len == 0) break;
        for (r.events) |e| {
            after = @max(after, e.seq);
            rows += 1;
            if (!chain.step(e)) break;
        }
        if (chain.broken_seq != 0) break;
    }
    if (chain.broken_seq != 0) {
        out("BROKEN at event {d}: {s}\n{d} signed event(s) verified before it ({d} unsigned).\n", .{ chain.broken_seq, chain.why, chain.signed, chain.unsigned });
        return 2;
    }
    if (rows == 0) {
        out("no events: is that the run's folder name? `veil --tater` lists the live ones; the desk's past runs show the rest.\n", .{});
        return 1;
    }
    if (chain.signed == 0) {
        out("no signed events: this run was written by a runtime from before the evidence chain ({d} unsigned event(s)).\n", .{chain.unsigned});
        return 1;
    }
    out("evidence chain intact: {d} signed event(s), seq {d} to {d}{s}.\nlast hash {s}\n", .{ chain.signed, chain.first_seq, chain.last_seq, if (chain.unsigned > 0) " (older unsigned events before them)" else "", chain.last_hash });
    return 0;
}

/// `veil --tater garrett [launch|rm|password]`: Agent Garrett, as the server sees it.
fn garrett(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    const G = struct { ok: bool = false, err: []const u8 = "", launched: bool = false, url: []const u8 = "", mcp_url: []const u8 = "", status: []const u8 = "", @"error": []const u8 = "", asked_by: []const u8 = "", password: []const u8 = "", sources: []const u8 = "" };
    const sub = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, sub, "launch")) {
        out("launching Agent Garrett into your Cloudflare account (its modules come from github.com/gary23w/garrettstimpson.ca; this can take a minute)...\n", .{});
        const resp = cli.call(ctx, "POST", "/api/v1/tots/garrett", "{}", 180, true) catch return cli.unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) return fail("--tater garrett launch", resp.status, resp.body, a);
        const r = std.json.parseFromSliceLeaky(G, a, resp.body, .{ .ignore_unknown_fields = true }) catch G{};
        out("Agent Garrett is up at {s}\nits MCP endpoint is {s}: a chat (`veil chat --garrett`, the desk's box), a swarm deployed with --garrett and a tater-tot deployed or set with --garrett reach it from now on (garrett_tools lists its tools).\nits chat UI is locked; `veil --tater garrett password` shows the password.\n", .{ r.url, r.mcp_url });
        return 0;
    }
    if (std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "remove")) {
        const resp = cli.call(ctx, "DELETE", "/api/v1/tots/garrett", null, 60, true) catch return cli.unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) return fail("--tater garrett rm", resp.status, resp.body, a);
        out("Agent Garrett is removed from the account; chats, swarms and tater-tots lose garrett and garrett_tools\n", .{});
        return 0;
    }
    if (sub.len > 0 and !std.mem.eql(u8, sub, "password") and !std.mem.eql(u8, sub, "status")) {
        out("usage: veil --tater garrett              where it is, what the runtime says\n       veil --tater garrett launch       deploy it into your Cloudflare account (no tater-tot needed)\n       veil --tater garrett password     the password locking its chat UI\n       veil --tater garrett rm           remove it\n", .{});
        return 1;
    }
    const reveal = std.mem.eql(u8, sub, "password");
    const resp = cli.call(ctx, "GET", if (reveal) "/api/v1/tots/garrett?reveal=1" else "/api/v1/tots/garrett", null, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater garrett", resp.status, resp.body, a);
    const r = std.json.parseFromSliceLeaky(G, a, resp.body, .{ .ignore_unknown_fields = true }) catch G{};
    if (!r.launched) {
        out("Agent Garrett is not deployed. `veil --tater garrett launch` (or Settings > Deploy Agent Garrett in the desk) puts it in your Cloudflare account; a tater-tot deployed with --garrett can ask for it too (garrett_launch).\n", .{});
        if (std.mem.eql(u8, r.status, "pending")) out("a tater-tot asked ({s}); your veil launches it within a minute while it is running.\n", .{r.asked_by});
        if (std.mem.eql(u8, r.status, "failed")) out("the last attempt failed: {s}\n", .{r.@"error"});
        return 1;
    }
    if (reveal) {
        out("{s}\n", .{r.password});
        return 0;
    }
    out("Agent Garrett: {s}\nMCP endpoint (chats, swarms and tater-tots that asked for it use it, with a bearer of its own): {s}\nruntime says: {s}\nmodules: {s}\nits chat UI is locked; `veil --tater garrett password` shows the password.\n", .{ r.url, r.mcp_url, r.status, r.sources });
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
        } else if (cli.flagVal(args, &i, x, "--posture")) |v| {
            cli.appendStr(a, &jb, "posture", v);
        } else if (cli.flagVal(args, &i, x, "--leash")) |v| {
            cli.appendNum(a, &jb, "leash_s", leashArg(v));
        } else if (cli.flagVal(args, &i, x, "--garrett")) |v| {
            jb.appendSlice(a, if (garrettOff(v)) ",\"garrett\":false" else ",\"garrett\":true") catch return 1;
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

/// `veil --tater limit [N]`: how many tater-tots this account may run (24 by default, 1 to 1000). What an account can
/// really carry is its Cloudflare plan's to say: each one is a Durable Object waking every few seconds.
fn limit(ctx: *Ctx, a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        const resp = cli.call(ctx, "GET", "/api/v1/tots", null, 40, true) catch return cli.unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) return fail("--tater limit", resp.status, resp.body, a);
        const r = std.json.parseFromSliceLeaky(Roster, a, resp.body, .{ .ignore_unknown_fields = true }) catch return fail("--tater limit", resp.status, resp.body, a);
        out("this account may run {d} tater-tots and runs {d}. `veil --tater limit N` sets 1 to 1000.\n", .{ r.max, r.tots.len });
        return 0;
    }
    const n = std.fmt.parseInt(u32, args[0], 10) catch {
        out("usage: veil --tater limit [N]     N is 1 to 1000\n", .{});
        return 1;
    };
    const body = std.fmt.allocPrint(a, "{{\"max\":{d}}}", .{n}) catch return 1;
    const resp = cli.call(ctx, "POST", "/api/v1/tots/limit", body, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater limit", resp.status, resp.body, a);
    out("this account may now run {d} tater-tots. Each one wakes every few seconds: your Cloudflare plan decides how many it really carries.\n", .{n});
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
        out("usage: veil --tater key brave <key>        a Brave Search API key: web_search asks it first\n       veil --tater key google <key>  +  veil --tater key google_cx <engine id>\n       veil --tater key alert <https://...>  the guard's webhook: a tripwire, a recovery, a leash land there (Discord/Slack URLs work as they are)\n       veil --tater key garrett_url <https://.../mcp>  +  veil --tater key garrett_token <token>   an Agent Garrett you deployed yourself\n       veil --tater key <name> --remove\n", .{});
        return 1;
    }
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    cli.appendStr(a, &jb, "name", args[0]);
    cli.appendStr(a, &jb, "value", if (std.mem.eql(u8, args[1], "--remove")) "" else args[1]);
    const body = object(a, jb.items) orelse return 1;
    const resp = cli.call(ctx, "POST", "/api/v1/tots/keys", body, 40, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return fail("--tater key", resp.status, resp.body, a);
    out("{s} key {s}\n", .{ args[0], if (std.mem.eql(u8, args[1], "--remove")) "removed" else "set: every tater-tot reads it from its next iteration" });
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

test "tot cli: the evidence chain is recomputed exactly as the runtime writes it; an altered or skipped row breaks it; a guard line is quoted for the runtime" {
    var hb: [64]u8 = undefined;
    // the vectors cloud/tot.test.mjs holds: the same bytes, the same digest
    const h1 = "ee277e3b7484a3200287ecddfb64a112c39df30eb1ea8a384c30cd634f265b35";
    try std.testing.expectEqualStrings(h1, chainHash("", 1, 1700000000000, "status", "Gary deployed", &hb));
    try std.testing.expectEqualStrings("a95660e7604f89bd2a16d1c3b088bd40d340180a7320eb8f09759853399e73fb", chainHash("a" ** 64, 2, 1700000001000, "pick", "look at the harbour\nthen the tide", &hb));
    var h2b: [64]u8 = undefined;
    const h2 = chainHash(h1, 2, 1700000001000, "pick", "look at the harbour\nthen the tide", &h2b);
    const row1: ChainEvent = .{ .seq = 1, .t = 1700000000000, .kind = "status", .text = "Gary deployed", .prev = "", .hash = h1 };
    var c: Chain = .{};
    try std.testing.expect(c.step(.{ .seq = 0, .t = 5, .kind = "status", .text = "from an older runtime" })); // unsigned: counted
    try std.testing.expect(c.step(row1));
    try std.testing.expect(c.step(.{ .seq = 2, .t = 1700000001000, .kind = "pick", .text = "look at the harbour\nthen the tide", .prev = h1, .hash = h2 }));
    try std.testing.expectEqual(@as(u64, 2), c.signed);
    try std.testing.expectEqual(@as(u64, 1), c.unsigned);
    try std.testing.expectEqual(@as(u64, 1), c.first_seq);
    try std.testing.expectEqual(@as(u64, 2), c.last_seq);
    try std.testing.expectEqualStrings(h2, &c.last_hash);
    var altered: Chain = .{};
    try std.testing.expect(altered.step(row1));
    try std.testing.expect(!altered.step(.{ .seq = 2, .t = 1700000001000, .kind = "pick", .text = "look at the harbour\nthen the tide (edited)", .prev = h1, .hash = h2 }));
    try std.testing.expectEqual(@as(u64, 2), altered.broken_seq);
    try std.testing.expect(std.mem.indexOf(u8, altered.why, "altered") != null);
    try std.testing.expect(!altered.step(row1)); // broken stays broken
    var skipped: Chain = .{};
    try std.testing.expect(skipped.step(row1));
    try std.testing.expect(!skipped.step(.{ .seq = 3, .t = 3, .kind = "act", .text = "x", .prev = "0" ** 64, .hash = "0" ** 64 }));
    try std.testing.expect(std.mem.indexOf(u8, skipped.why, "does not follow") != null);
    // the rows as the server's run-events route serves them parse into the same struct, extra fields and all
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const served = try std.json.parseFromSliceLeaky(ChainEvents, a, "{\"ok\":true,\"events\":[{\"seq\":1,\"t\":1700000000000,\"kind\":\"status\",\"text\":\"Gary deployed\",\"brief\":\"Gary deployed\",\"ok\":true,\"prev\":\"\",\"hash\":\"" ++ h1 ++ "\"}]}", .{ .ignore_unknown_fields = true });
    var parsed: Chain = .{};
    try std.testing.expect(parsed.step(served.events[0]));
    try std.testing.expectEqual(@as(u64, 1), parsed.signed);
    // `veil --tater guard Gary add https://x --text "status: OK" --every 60` becomes one /guard line the runtime parses
    try std.testing.expectEqualStrings("/guard add https://x --text \"status: OK\" --every 60", guardCommand(a, &.{ "add", "https://x", "--text", "status: OK", "--every", "60" }).?);
    try std.testing.expectEqualStrings("/guard", guardCommand(a, &.{}).?);
    try std.testing.expectEqualStrings("0", leashArg("OFF"));
    try std.testing.expectEqualStrings("3600", leashArg("3600"));
    var b: [400]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rosterLine(&b, .{ .name = "Ada", .posture = "defend", .watch = 3, .guard_tripped = 1 }), "DEFEND  guard 3 TRIPPED") != null);
    try std.testing.expect(std.mem.indexOf(u8, rosterLine(&b, .{ .name = "Ada", .watch = 2 }), "  guard 2  ") != null);
}
