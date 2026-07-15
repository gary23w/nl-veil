//! cli/hub.zig — `veil hub`, the fleet console. The old hub.py aggregated many machines over a bespoke sealed
//! channel that bypassed the server entirely and drove deploy.py's local functions. This reimplements the
//! console over the server API: the running veil server already aggregates every swarm a user owns
//! (/api/v1/fleet, /api/v1/swarms), so the single-instance operations — roster, broadcast a directive to all
//! swarms, stop the whole fleet — are API-backed and honest. Cross-machine aggregation (hub.py's multi-node
//! roster) needs a dedicated server fleet endpoint and is intentionally left as a documented follow-up rather
//! than a second, out-of-band control plane.

const std = @import("std");
const cli = @import("../cli.zig");

const Ctx = cli.Ctx;

pub fn run(ctx: *Ctx, args: []const []const u8, call: cli.CallFn) u8 {
    const verb = if (args.len > 0) args[0] else "roster";

    if (std.mem.eql(u8, verb, "help")) return help();

    if (std.mem.eql(u8, verb, "roster") or std.mem.eql(u8, verb, "ls") or std.mem.eql(u8, verb, "fleet")) {
        return roster(ctx, call);
    }

    if (std.mem.eql(u8, verb, "all") or std.mem.eql(u8, verb, "say") or std.mem.eql(u8, verb, "goal")) {
        // broadcast a directive to every swarm: `veil hub all "<text>"` steers each; `goal` sets the goal.
        if (args.len < 2) {
            std.debug.print("usage: veil hub {s} \"<text>\"\n", .{verb});
            return 1;
        }
        const text = args[1];
        const op: []const u8 = if (std.mem.eql(u8, verb, "goal")) "set_goal" else "say";
        return broadcast(ctx, call, op, text);
    }

    if (std.mem.eql(u8, verb, "stopall")) {
        return broadcast(ctx, call, "stop", "");
    }

    std.debug.print("unknown hub command '{s}' — run `veil hub help`\n", .{verb});
    return 1;
}

fn roster(ctx: *Ctx, call: cli.CallFn) u8 {
    const fl = call(ctx, "GET", "/api/v1/fleet", null, 6, true) catch {
        std.debug.print("no veil server — run `veil` to start it\n", .{});
        return 1;
    };
    defer if (fl.body.len > 0) ctx.gpa.free(fl.body);
    cli.out("FLEET  {s}\n\n", .{fl.body[0..@min(fl.body.len, 200)]});

    const resp = call(ctx, "GET", "/api/v1/swarms", null, 6, true) catch {
        std.debug.print("(could not list swarms)\n", .{});
        return 1;
    };
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) {
        std.debug.print("roster failed (HTTP {d})\n", .{resp.status});
        return 1;
    }
    var it = cli.JsonObjs.init(resp.body);
    cli.out("{s: <18}  {s: <9}  {s: <6}  {s}\n", .{ "ID", "STATE", "MINDS", "GOAL" });
    var any = false;
    while (it.next()) |obj| {
        const id = cli.jsonStr(ctx.gpa, obj, "id") orelse continue;
        defer ctx.gpa.free(id);
        const state = cli.jsonStr(ctx.gpa, obj, "state") orelse ctx.gpa.dupe(u8, "?") catch continue;
        defer ctx.gpa.free(state);
        const goal = cli.jsonStr(ctx.gpa, obj, "goal") orelse ctx.gpa.dupe(u8, "") catch continue;
        defer ctx.gpa.free(goal);
        cli.out("{s: <18}  {s: <9}  {d: <6}  {s}\n", .{ id[0..@min(id.len, 18)], state[0..@min(state.len, 9)], cli.jsonNum(obj, "minds"), goal[0..@min(goal.len, 56)] });
        any = true;
    }
    if (!any) cli.out("(the fleet is empty)\n", .{});
    return 0;
}

/// Fan a control op out to every swarm the server lists. Returns 0 if all accepted, 1 if any failed. Used by
/// `hub all` (say), `hub goal` (set_goal), and `hub stopall` (stop).
fn broadcast(ctx: *Ctx, call: cli.CallFn, op: []const u8, text: []const u8) u8 {
    const resp = call(ctx, "GET", "/api/v1/swarms", null, 6, true) catch {
        std.debug.print("no veil server — run `veil` to start it\n", .{});
        return 1;
    };
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) {
        std.debug.print("could not list swarms (HTTP {d})\n", .{resp.status});
        return 1;
    }
    // build the control body once (op + optional text)
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(ctx.gpa);
    body.appendSlice(ctx.gpa, "{\"op\":") catch return 1;
    jstr(ctx.gpa, &body, op);
    if (text.len > 0) {
        body.appendSlice(ctx.gpa, ",\"text\":") catch return 1;
        jstr(ctx.gpa, &body, text);
    }
    body.appendSlice(ctx.gpa, "}") catch return 1;

    var sent: usize = 0;
    var failed: usize = 0;
    var it = cli.JsonObjs.init(resp.body);
    while (it.next()) |obj| {
        const id = cli.jsonStr(ctx.gpa, obj, "id") orelse continue;
        defer ctx.gpa.free(id);
        var pb: [200]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/api/v1/swarms/{s}/control", .{id}) catch continue;
        const cr = call(ctx, "POST", path, body.items, 8, false) catch {
            failed += 1;
            continue;
        };
        if (cr.body.len > 0) ctx.gpa.free(cr.body);
        if (cr.status == 200 or cr.status == 202) sent += 1 else failed += 1;
    }
    cli.out("broadcast {s}: {d} sent, {d} failed\n", .{ op, sent, failed });
    return if (failed == 0) 0 else 1;
}

fn help() u8 {
    cli.out(
        \\veil hub — fleet console (the running server aggregates all your swarms)
        \\
        \\  veil hub                 roster: fleet summary + every swarm's state
        \\  veil hub all "<text>"    broadcast a directive (say) to every swarm
        \\  veil hub goal "<text>"   set a new goal on every swarm
        \\  veil hub stopall         stop every swarm
        \\
        \\Cross-machine aggregation (many veils, one console) is a planned server endpoint;
        \\today the console operates the local server's fleet.
        \\
    , .{});
    return 0;
}

fn jstr(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    list.append(gpa, '"') catch return;
    for (s) |c| switch (c) {
        '"' => list.appendSlice(gpa, "\\\"") catch return,
        '\\' => list.appendSlice(gpa, "\\\\") catch return,
        '\n' => list.appendSlice(gpa, "\\n") catch return,
        else => list.append(gpa, c) catch return,
    };
    list.append(gpa, '"') catch return;
}
