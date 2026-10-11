//! veil sentry — the sentry on this machine from the terminal: what it sees, what it found, what it blocks.
//!
//!   veil sentry                         status: on/off, posture, host firewall, counts, open findings
//!   veil sentry on | off                start / stop watching (observe posture; nothing on the host changes)
//!   veil sentry scan                    inventory now: every listener with its process, then new findings
//!   veil sentry findings [--all] [--since N] [--min low|medium|high]
//!   veil sentry inventory [--connections] [--persistence]
//!   veil sentry rules                   the policy, and whether each rule is on the host
//!   veil sentry block <port> [--udp] [--out] [--remote IP|CIDR] [--program PATH] [--note "..."] [--id SLUG]
//!   veil sentry allow <port> [same flags]
//!   veil sentry rm <id>
//!   veil sentry posture observe|enforce  enforce applies the policy to the host firewall (needs admin/root)
//!   veil sentry auto-block on|off        enforce only: quarantine a new network-reachable listener on sight
//!   veil sentry every <seconds>          scan cadence (15..3600)
//!   veil sentry allow-port <port> | disallow-port <port>
//!   veil sentry baseline                 accept everything seen so far as this machine's normal
//!   veil sentry ack                      mark the findings reviewed
//!
//! Every verb is one authenticated call to the local server's /api/v1/sentry routes (admin-gated there); this
//! file only shapes requests and prints replies.

const std = @import("std");
const cli = @import("../cli.zig");

const Ctx = cli.Ctx;
const out = cli.out;

pub fn cmd(ctx: *Ctx, args: []const []const u8) u8 {
    const verb = if (args.len > 0) args[0] else "status";
    if (std.mem.eql(u8, verb, "status")) return status(ctx);
    if (std.mem.eql(u8, verb, "on")) return setJson(ctx, "{\"enabled\":true}");
    if (std.mem.eql(u8, verb, "off")) return setJson(ctx, "{\"enabled\":false}");
    if (std.mem.eql(u8, verb, "scan")) return scan(ctx);
    if (std.mem.eql(u8, verb, "findings")) return findings(ctx, args[1..]);
    if (std.mem.eql(u8, verb, "inventory")) return inventory(ctx, args[1..]);
    if (std.mem.eql(u8, verb, "rules")) return rules(ctx);
    if (std.mem.eql(u8, verb, "block") or std.mem.eql(u8, verb, "allow")) return addRule(ctx, verb, args[1..]);
    if (std.mem.eql(u8, verb, "rm") or std.mem.eql(u8, verb, "remove")) return rmRule(ctx, args[1..]);
    if (std.mem.eql(u8, verb, "posture")) {
        if (args.len < 2 or !(std.mem.eql(u8, args[1], "observe") or std.mem.eql(u8, args[1], "enforce"))) {
            out("usage: veil sentry posture observe|enforce\n", .{});
            return 1;
        }
        var b: [64]u8 = undefined;
        return setJson(ctx, std.fmt.bufPrint(&b, "{{\"posture\":\"{s}\"}}", .{args[1]}) catch return 1);
    }
    if (std.mem.eql(u8, verb, "auto-block")) {
        if (args.len < 2 or !(std.mem.eql(u8, args[1], "on") or std.mem.eql(u8, args[1], "off"))) {
            out("usage: veil sentry auto-block on|off\n", .{});
            return 1;
        }
        return setJson(ctx, if (std.mem.eql(u8, args[1], "on")) "{\"auto_block\":true}" else "{\"auto_block\":false}");
    }
    if (std.mem.eql(u8, verb, "every")) {
        const n = if (args.len > 1) (std.fmt.parseInt(u32, args[1], 10) catch 0) else 0;
        if (n == 0) {
            out("usage: veil sentry every <seconds>   (15..3600)\n", .{});
            return 1;
        }
        var b: [64]u8 = undefined;
        return setJson(ctx, std.fmt.bufPrint(&b, "{{\"every_s\":{d}}}", .{n}) catch return 1);
    }
    if (std.mem.eql(u8, verb, "allow-port") or std.mem.eql(u8, verb, "disallow-port")) {
        const n = if (args.len > 1) (std.fmt.parseInt(u16, args[1], 10) catch 0) else 0;
        if (n == 0) {
            out("usage: veil sentry {s} <port>\n", .{verb});
            return 1;
        }
        var b: [64]u8 = undefined;
        return setJson(ctx, std.fmt.bufPrint(&b, "{{\"{s}\":{d}}}", .{ if (verb[0] == 'a') "allow_port" else "disallow_port", n }) catch return 1);
    }
    if (std.mem.eql(u8, verb, "baseline")) return setJson(ctx, "{\"baseline\":true}");
    if (std.mem.eql(u8, verb, "ack")) return setJson(ctx, "{\"ack\":true}");
    out("usage: veil sentry [status|on|off|scan|findings|inventory|rules|block|allow|rm|posture|auto-block|every|allow-port|disallow-port|baseline|ack]\n", .{});
    return 1;
}

fn failed(ctx: *Ctx, what: []const u8, resp: anytype) u8 {
    _ = ctx;
    if (resp.status == 401 or resp.status == 403) {
        std.debug.print("{s}: the sentry is admin-only (HTTP {d})\n", .{ what, resp.status });
    } else if (resp.status == 503) {
        std.debug.print("{s}: this server has no sentry (HTTP 503)\n", .{what});
    } else {
        std.debug.print("{s} failed (HTTP {d}): {s}\n", .{ what, resp.status, resp.body[0..@min(resp.body.len, 300)] });
    }
    return 1;
}

fn status(ctx: *Ctx) u8 {
    const resp = cli.call(ctx, "GET", "/api/v1/sentry", null, 20, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return failed(ctx, "sentry status", resp);
    printStatus(ctx, resp.body);
    printFindings(ctx, resp.body, "open findings");
    return 0;
}

fn setJson(ctx: *Ctx, body: []const u8) u8 {
    const resp = cli.call(ctx, "POST", "/api/v1/sentry/set", body, 90, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return failed(ctx, "sentry set", resp);
    printStatus(ctx, resp.body);
    return 0;
}

fn scan(ctx: *Ctx) u8 {
    const resp = cli.call(ctx, "POST", "/api/v1/sentry/scan", "{}", 180, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return failed(ctx, "sentry scan", resp);
    printStatus(ctx, resp.body);
    const inv = cli.call(ctx, "GET", "/api/v1/sentry/inventory", null, 20, false) catch return 0;
    defer if (inv.body.len > 0) ctx.gpa.free(inv.body);
    if (inv.status == 200) printInventory(ctx, inv.body, true, false, false);
    printFindings(ctx, resp.body, "open findings");
    return 0;
}

fn findings(ctx: *Ctx, args: []const []const u8) u8 {
    var all = false;
    var since: []const u8 = "0";
    var min: []const u8 = "info";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--all")) all = true else if (cli.flagVal(args, &i, a, "--since")) |v| since = v else if (cli.flagVal(args, &i, a, "--min")) |v| min = v;
    }
    var pb: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/sentry/findings?since={s}&min={s}&limit=200&all={s}", .{ since, min, if (all) "1" else "0" }) catch return 1;
    const resp = cli.call(ctx, "GET", path, null, 20, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return failed(ctx, "sentry findings", resp);
    printFindings(ctx, resp.body, if (all) "findings" else "open findings");
    return 0;
}

fn inventory(ctx: *Ctx, args: []const []const u8) u8 {
    var conns = false;
    var persist = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--connections")) conns = true else if (std.mem.eql(u8, a, "--persistence")) persist = true;
    }
    const resp = cli.call(ctx, "GET", "/api/v1/sentry/inventory", null, 20, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return failed(ctx, "sentry inventory", resp);
    printInventory(ctx, resp.body, true, conns, persist);
    return 0;
}

fn rules(ctx: *Ctx) u8 {
    const resp = cli.call(ctx, "GET", "/api/v1/sentry/rules", null, 20, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) return failed(ctx, "sentry rules", resp);
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, resp.body, .{}) catch return 1;
    defer parsed.deinit();
    const root = objOf(parsed.value) orelse return 1;
    out("posture: {s}\n", .{strOf(root.get("posture"))});
    const arr = root.get("rules") orelse return 0;
    if (arr != .array or arr.array.items.len == 0) {
        out("(no rules — add one with `veil sentry block <port>`)\n", .{});
        return 0;
    }
    for (arr.array.items) |v| {
        const r = objOf(v) orelse continue;
        out("  {s:<26} {s:<5} {s:<3} {s:<3} port {d:<5} {s}{s} {s}{s}\n", .{ strOf(r.get("id")), strOf(r.get("action")), strOf(r.get("direction")), strOf(r.get("protocol")), intOf(r.get("port")), if (strOf(r.get("remote")).len > 0) "remote " else "", strOf(r.get("remote")), if (boolOf(r.get("on_host"))) "[on host] " else "", strOf(r.get("note")) });
    }
    return 0;
}

fn addRule(ctx: *Ctx, action: []const u8, args: []const []const u8) u8 {
    if (args.len == 0) {
        out("usage: veil sentry {s} <port> [--udp] [--out] [--remote IP|CIDR] [--program PATH] [--note \"...\"] [--id SLUG]\n", .{action});
        return 1;
    }
    const port = std.fmt.parseInt(u16, args[0], 10) catch 0;
    var proto: []const u8 = "tcp";
    var dir: []const u8 = "in";
    var remote: []const u8 = "";
    var program: []const u8 = "";
    var note: []const u8 = "";
    var id: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--udp")) proto = "udp" else if (std.mem.eql(u8, a, "--any")) proto = "any" else if (std.mem.eql(u8, a, "--out")) dir = "out" else if (cli.flagVal(args, &i, a, "--remote")) |v| remote = v else if (cli.flagVal(args, &i, a, "--program")) |v| program = v else if (cli.flagVal(args, &i, a, "--note")) |v| note = v else if (cli.flagVal(args, &i, a, "--id")) |v| id = v;
    }
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    defer jb.deinit(ctx.gpa);
    jb.appendSlice(ctx.gpa, "{\"action\":") catch return 1;
    cli.jstr(ctx.gpa, &jb, action);
    cli.appendStr(ctx.gpa, &jb, "direction", dir);
    cli.appendStr(ctx.gpa, &jb, "protocol", proto);
    var nb: [8]u8 = undefined;
    cli.appendNum(ctx.gpa, &jb, "port", std.fmt.bufPrint(&nb, "{d}", .{port}) catch "0");
    if (remote.len > 0) cli.appendStr(ctx.gpa, &jb, "remote", remote);
    if (program.len > 0) cli.appendStr(ctx.gpa, &jb, "program", program);
    if (note.len > 0) cli.appendStr(ctx.gpa, &jb, "note", note);
    if (id.len > 0) cli.appendStr(ctx.gpa, &jb, "id", id);
    jb.append(ctx.gpa, '}') catch return 1;
    const resp = cli.call(ctx, "POST", "/api/v1/sentry/rules", jb.items, 60, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 201) return failed(ctx, "sentry rule", resp);
    const rid = cli.jsonStr(ctx.gpa, resp.body, "id") orelse return 0;
    defer ctx.gpa.free(rid);
    const posture = cli.jsonStr(ctx.gpa, resp.body, "posture");
    defer if (posture) |p| ctx.gpa.free(p);
    const err = cli.jsonStr(ctx.gpa, resp.body, "last_error");
    defer if (err) |e| ctx.gpa.free(e);
    const enforcing = posture != null and std.mem.eql(u8, posture.?, "enforce");
    out("rule {s} added ({s} {s} {s} port {d}{s}{s}): {s}\n", .{ rid, action, dir, proto, port, if (remote.len > 0) " remote " else "", remote, if (!enforcing) "recorded; `veil sentry posture enforce` applies the policy to the host firewall" else if (err != null and err.?.len > 0) err.? else "applied to the host firewall" });
    return 0;
}

fn rmRule(ctx: *Ctx, args: []const []const u8) u8 {
    if (args.len == 0) {
        out("usage: veil sentry rm <id>\n", .{});
        return 1;
    }
    var pb: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/sentry/rules/{s}", .{args[0]}) catch return 1;
    const resp = cli.call(ctx, "DELETE", path, null, 60, true) catch return cli.unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status == 404) {
        out("no rule named {s}\n", .{args[0]});
        return 1;
    }
    if (resp.status != 200) return failed(ctx, "sentry rm", resp);
    out("rule {s} removed\n", .{args[0]});
    return 0;
}

// ------------------------------------------------------------------------------------------- printing

fn printStatus(ctx: *Ctx, body: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch return;
    defer parsed.deinit();
    const o = objOf(parsed.value) orelse return;
    const on = boolOf(o.get("enabled"));
    out("sentry      : {s}  posture {s}  auto-block {s}  every {d}s  ({s})\n", .{ if (on) "ON" else "off", strOf(o.get("posture")), if (boolOf(o.get("auto_block"))) "on" else "off", intOf(o.get("every_s")), strOf(o.get("platform")) });
    out("host firewall: {s}{s}\n", .{ strOf(o.get("firewall")), if (!boolOf(o.get("enforce_supported"))) "  (enforcement not supported here)" else if (!boolOf(o.get("enforce_ok"))) "  (enforce FAILED — see last error)" else "" });
    const scans = intOf(o.get("scans"));
    if (scans > 0) {
        out("last scan   : {d} listeners ({d} bound to network addresses), {d} connections, {d} startup/scheduled entries, {d} scans\n", .{ intOf(o.get("listeners")), intOf(o.get("exposed")), intOf(o.get("connections")), intOf(o.get("persistence")), scans });
    } else out("last scan   : none yet\n", .{});
    out("rules       : {d} in the policy, {d} on the host; baseline {d} entries\n", .{ intOf(o.get("rules")), intOf(o.get("applied")), intOf(o.get("baseline")) });
    out("findings    : {d} open ({d} high), {d} total\n", .{ intOf(o.get("findings_open")), intOf(o.get("findings_high_open")), intOf(o.get("findings_total")) });
    const err = strOf(o.get("last_error"));
    if (err.len > 0) out("last error  : {s}\n", .{err});
}

fn printFindings(ctx: *Ctx, body: []const u8, title: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch return;
    defer parsed.deinit();
    const o = objOf(parsed.value) orelse return;
    const arr = o.get("findings") orelse return;
    if (arr != .array) return;
    if (arr.array.items.len == 0) {
        out("{s}: none\n", .{title});
        return;
    }
    out("{s}:\n", .{title});
    for (arr.array.items) |v| {
        const f = objOf(v) orelse continue;
        var tb: [24]u8 = undefined;
        out("  #{d:<5} {s:<6} {s:<16} {s}  {s}\n", .{ intOf(f.get("seq")), strOf(f.get("severity")), strOf(f.get("kind")), stamp(&tb, intOf(f.get("ts"))), strOf(f.get("text")) });
    }
}

fn printInventory(ctx: *Ctx, body: []const u8, listeners: bool, conns: bool, persist: bool) void {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch return;
    defer parsed.deinit();
    const o = objOf(parsed.value) orelse return;
    if (listeners) if (o.get("listeners")) |arr| if (arr == .array) {
        out("listening ({d}):\n", .{arr.array.items.len});
        for (arr.array.items) |v| {
            const l = objOf(v) orelse continue;
            out("  {s:<4} {s:>24}:{d:<6} {s:<8} pid {d:<7} {s}{s}\n", .{ strOf(l.get("proto")), strOf(l.get("addr")), intOf(l.get("port")), if (boolOf(l.get("exposed"))) "NETWORK" else "local", intOf(l.get("pid")), strOf(l.get("name")), if (boolOf(l.get("own"))) "  (the veil)" else "" });
        }
    };
    if (conns) if (o.get("connections")) |arr| if (arr == .array) {
        out("established ({d}):\n", .{arr.array.items.len});
        for (arr.array.items) |v| {
            const c = objOf(v) orelse continue;
            out("  {s:<4} -> {s:>24}:{d:<6} {s:<8} pid {d:<7} {s}\n", .{ strOf(c.get("proto")), strOf(c.get("remote")), intOf(c.get("port")), if (boolOf(c.get("public"))) "internet" else "local", intOf(c.get("pid")), strOf(c.get("name")) });
        }
    };
    if (persist) if (o.get("persistence")) |arr| if (arr == .array) {
        out("startup / scheduled ({d}):\n", .{arr.array.items.len});
        for (arr.array.items) |v| if (v == .string) out("  {s}\n", .{v.string});
    };
}

fn objOf(v: std.json.Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}
fn strOf(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}
fn intOf(v: ?std.json.Value) i64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}
fn boolOf(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return x == .bool and x.bool;
}

/// "MM-DD HH:MM" UTC from epoch seconds.
fn stamp(buf: []u8, ts: i64) []const u8 {
    if (ts <= 0) return "";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ md.month.numeric(), @as(u32, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
}

// ================================================================================================= tests

test "the verb table: every documented verb is dispatched, and the usage line names them" {
    const src = @embedFile("sentry.zig");
    const verbs = [_][]const u8{ "status", "on", "off", "scan", "findings", "inventory", "rules", "block", "allow", "rm", "posture", "auto-block", "every", "allow-port", "disallow-port", "baseline", "ack" };
    const usage_at = std.mem.indexOf(u8, src, "usage: veil sentry [status|") orelse return error.TestUnexpectedResult;
    const usage_line = src[usage_at .. usage_at + (std.mem.indexOfScalarPos(u8, src, usage_at, '\n') orelse src.len)];
    for (verbs) |v| {
        var nb: [48]u8 = undefined;
        const needle = try std.fmt.bufPrint(&nb, "std.mem.eql(u8, verb, \"{s}\")", .{v});
        try std.testing.expect(std.mem.indexOf(u8, src, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, usage_line, v) != null);
    }
}

test "stamp renders epoch seconds as MM-DD HH:MM" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("10-11 14:05", stamp(&b, 1791727500)); // 2026-10-11T14:05:00Z
    try std.testing.expectEqualStrings("", stamp(&b, 0));
}
