//! cli.zig — the `veil` command-line client. Every subcommand is a thin call to the LOCAL server's
//! /api/v1/* over the in-process httpc socket client (no curl, no argv secrets); the server is the one
//! daemon that owns swarms, the chat brain, and scheduled tasks. This is the surface that retires the old
//! Python launcher (deploy.py) and fleet tool (hub.py): the same verbs, but backed by the running server
//! instead of a second, file-convention control plane.
//!
//! Auth: the server drops an admin API key at {data}/.desktop_key on any localhost bind (preloadDesktopKey);
//! the CLI reads it and sends it as the bearer — zero-prompt on the same machine, exactly like veil-desk.
//!
//! Server lifecycle: a CLI verb that needs the server auto-starts it (detached) and waits for /health when
//! nothing is listening, so `veil cast …` just works from a cold machine. Bare `veil` (no subcommand) still
//! falls through to booting the server in the foreground — the daemon form is unchanged.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const httpc = @import("worker/httpc.zig");
const exec_tool = @import("cli/exec_tool.zig");
const cync = @import("worker/chat/sync.zig");

const VEIL_EXE = if (builtin.os.tag == .windows) "veil.exe" else "veil";

/// Everything a subcommand needs: the resolved data dir (for the bearer key), the server port, and io/gpa.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    data: []const u8,
    home: []const u8,
    port: u16,
    environ: *std.process.Environ.Map,
    token_buf: [128]u8 = undefined,
    token_len: usize = 0,

    fn token(self: *Ctx) []const u8 {
        return self.token_buf[0..self.token_len];
    }

    /// Load the admin key the server dropped at {data}/.desktop_key. Empty when absent (server never ran on
    /// this data dir yet) — callers that need auth surface a clear message rather than a bare 401.
    fn loadToken(self: *Ctx) void {
        var pb: [600]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.desktop_key", .{self.data}) catch return;
        const raw = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(256)) catch return;
        defer self.gpa.free(raw);
        const key = std.mem.trim(u8, raw, " \r\n\t");
        const n = @min(key.len, self.token_buf.len);
        @memcpy(self.token_buf[0..n], key[0..n]);
        self.token_len = n;
    }
};

/// True when `sub` is a CLI verb the dispatcher handles (so main.zig can fall through to the server boot for
/// anything else, keeping bare `veil` = run the daemon). Kept in sync with `dispatch` below.
pub fn isCommand(sub: []const u8) bool {
    const verbs = [_][]const u8{
        "cast",      "deploy",        "list",   "ls",      "ps",        "stop",
        "rm",        "delete",        "events", "logs",    "watch",     "chat",
        "sched",     "hub",           "doctor", "health",  "desktop",   "desk",
        "help",      "--help",        "-h",     "version", "--version", "exec-tool",
        "sync-read", "sync-manifest", "rag",
    };
    for (verbs) |v| if (std.mem.eql(u8, sub, v)) return true;
    return false;
}

/// Run one CLI subcommand and return its process exit code. `args` is the argv AFTER the verb (e.g. for
/// `veil cast "goal" --minutes 5` it is {"goal","--minutes","5"}). Never boots the server in-process — a verb
/// that needs it talks over HTTP (auto-starting a detached daemon first).
pub fn dispatch(ctx: *Ctx, sub: []const u8, args: []const []const u8) u8 {
    stdout_io = ctx.io;
    ctx.loadToken();
    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h"))
        return cmdHelp();
    if (std.mem.eql(u8, sub, "version") or std.mem.eql(u8, sub, "--version"))
        return cmdVersion(ctx);
    if (std.mem.eql(u8, sub, "cast")) return cmdCast(ctx, args);
    if (std.mem.eql(u8, sub, "deploy")) return cmdCast(ctx, args); // one-liner ≈ a continuous cast (see cmdCast)
    if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "ls") or std.mem.eql(u8, sub, "ps"))
        return cmdList(ctx);
    if (std.mem.eql(u8, sub, "stop")) return cmdStop(ctx, args);
    if (std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "delete")) return cmdRm(ctx, args);
    if (std.mem.eql(u8, sub, "events") or std.mem.eql(u8, sub, "logs") or std.mem.eql(u8, sub, "watch"))
        return cmdEvents(ctx, args);
    if (std.mem.eql(u8, sub, "chat")) return cmdChat(ctx, args);
    if (std.mem.eql(u8, sub, "sched")) return cmdSched(ctx, args);
    if (std.mem.eql(u8, sub, "hub")) return cmdHub(ctx, args);
    if (std.mem.eql(u8, sub, "doctor") or std.mem.eql(u8, sub, "health")) return cmdDoctor(ctx);
    if (std.mem.eql(u8, sub, "desktop") or std.mem.eql(u8, sub, "desk")) return cmdDesktop(ctx);
    if (std.mem.eql(u8, sub, "exec-tool")) return exec_tool.cmd(ctx, args);
    if (std.mem.eql(u8, sub, "sync-manifest")) return exec_tool.cmdSyncManifest(ctx, args);
    if (std.mem.eql(u8, sub, "sync-read")) return exec_tool.cmdSyncRead(ctx, args);
    if (std.mem.eql(u8, sub, "rag")) return cmdRag(ctx, args);
    std.debug.print("unknown command '{s}' — run `veil help`\n", .{sub});
    return 1;
}

// ------------------------------------------------------------------------------- HTTP plumbing

const HttpErr = error{ Unreachable, ServerError };

/// One authenticated request to the local server. On a connect-refused it auto-starts the daemon once and
/// retries, so any verb works from cold. Returns the gpa-owned response (caller frees body) or an error.
fn call(ctx: *Ctx, method: []const u8, path: []const u8, body: ?[]const u8, timeout_s: u32, autostart: bool) HttpErr!httpc.Resp {
    var started = false;
    while (true) {
        switch (httpc.request(ctx.io, ctx.gpa, .{
            .method = method,
            .port = ctx.port,
            .path = path,
            .bearer = ctx.token(),
            .body = body,
            .timeout_s = timeout_s,
        })) {
            .ok => |resp| return resp,
            .refused => {
                if (autostart and !started) {
                    started = true;
                    if (ensureServer(ctx)) continue else return HttpErr.Unreachable;
                }
                return HttpErr.Unreachable;
            },
            .timed_out => return HttpErr.Unreachable,
            .failed => return HttpErr.ServerError,
        }
    }
}

/// GET /api/v1/health with a short ceiling — the liveness probe both `doctor` and autostart use.
fn serverUp(ctx: *Ctx) bool {
    switch (httpc.request(ctx.io, ctx.gpa, .{ .method = "GET", .port = ctx.port, .path = "/api/v1/health", .timeout_s = 3 })) {
        .ok => |resp| {
            if (resp.body.len > 0) ctx.gpa.free(resp.body);
            return resp.status == 200;
        },
        else => return false,
    }
}

/// Start the server detached and wait (up to ~15 s) for /health. Returns true once it answers. Idempotent —
/// a second CLI invocation that finds it already up returns immediately. Best-effort spawn: a missing binary
/// or a display-less box just fails the wait, and the caller reports "server unreachable".
fn ensureServer(ctx: *Ctx) bool {
    if (serverUp(ctx)) return true;
    var eb: [700]u8 = undefined;
    const exe = std.fmt.bufPrint(&eb, "{s}/zig-out/bin/{s}", .{ ctx.home, VEIL_EXE }) catch return false;
    const bundle = std.fmt.bufPrint(eb[350..], "{s}/{s}", .{ ctx.home, VEIL_EXE }) catch return false;
    const bin = if (std.Io.Dir.cwd().access(ctx.io, exe, .{})) |_| exe else |_| bundle;
    out("starting the veil server on :{d}...\n", .{ctx.port});
    // --server-only: a bare `veil` now also opens the desk (the one-click default), which a CLI verb must never
    // do — `veil chat` auto-starting the server should not pop a GUI window.
    _ = std.process.spawn(ctx.io, .{ .argv = &.{ bin, "--server-only" }, .cwd = .{ .path = ctx.home }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    var tries: u32 = 0;
    while (tries < 30) : (tries += 1) {
        ctx.io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
        if (serverUp(ctx)) {
            ctx.loadToken(); // the server just minted/refreshed .desktop_key on boot — pick it up
            return true;
        }
    }
    return false;
}

fn unreachable_msg(ctx: *Ctx) u8 {
    std.debug.print("no veil server on :{d} and it could not be started. Run `veil` (no arguments) in the repo to boot it.\n", .{ctx.port});
    return 1;
}

// ------------------------------------------------------------------------------- commands

fn cmdVersion(ctx: *Ctx) u8 {
    const resp = call(ctx, "GET", "/api/v1/health", null, 3, false) catch {
        out("veil (server not running)\n", .{});
        return 0;
    };
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (jsonStr(ctx.gpa, resp.body, "version")) |v| {
        defer ctx.gpa.free(v);
        out("veil {s}\n", .{v});
    } else out("veil\n", .{});
    return 0;
}

fn cmdDoctor(ctx: *Ctx) u8 {
    out("veil doctor\n", .{});
    out("  data dir : {s}\n", .{ctx.data});
    out("  token    : {s}\n", .{if (ctx.token_len > 0) "loaded (.desktop_key)" else "MISSING — start the server once to mint it"});
    if (serverUp(ctx)) {
        const resp = call(ctx, "GET", "/api/v1/fleet", null, 4, false) catch {
            out("  server   : up on :{d}\n", .{ctx.port});
            return 0;
        };
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        out("  server   : UP on :{d}\n", .{ctx.port});
        if (jsonStr(ctx.gpa, resp.body, "version")) |v| {
            defer ctx.gpa.free(v);
            out("  version  : {s}\n", .{v});
        }
        out("  fleet    : {s}\n", .{resp.body[0..@min(resp.body.len, 200)]});
        return 0;
    }
    out("  server   : DOWN on :{d} (run `veil` to start it)\n", .{ctx.port});
    return 1;
}

/// `veil cast <goal> [--minutes N] [--minds N] [--model M] [--provider P] [--base-url U] [--key K]
///                    [--style S] [--name N] [--continuous] [--offline] [--follow]`
/// POST /api/v1/cast — the swarm door. `deploy` aliases here with --continuous implied (a sustained hive).
fn cmdCast(ctx: *Ctx, args: []const []const u8) u8 {
    var goal: []const u8 = "";
    var minutes: []const u8 = "";
    var minds: []const u8 = "";
    var model: []const u8 = "";
    var provider: []const u8 = "";
    var base_url: []const u8 = "";
    var key: []const u8 = "";
    var style: []const u8 = "";
    var name: []const u8 = "";
    var mode: []const u8 = "";
    var lineage: []const u8 = "";
    var offline = false;
    var follow = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (flagVal(args, &i, a, "--minutes")) |v| minutes = v else if (flagVal(args, &i, a, "--minds")) |v| minds = v else if (flagVal(args, &i, a, "--model")) |v| model = v else if (flagVal(args, &i, a, "--provider")) |v| provider = v else if (flagVal(args, &i, a, "--base-url")) |v| base_url = v else if (flagVal(args, &i, a, "--key")) |v| key = v else if (flagVal(args, &i, a, "--style")) |v| style = v else if (flagVal(args, &i, a, "--name")) |v| name = v else if (flagVal(args, &i, a, "--lineage")) |v| lineage = v else if (std.mem.eql(u8, a, "--continuous")) {
            mode = "continuous";
        } else if (std.mem.eql(u8, a, "--offline")) {
            offline = true;
        } else if (std.mem.eql(u8, a, "--follow") or std.mem.eql(u8, a, "-f")) {
            follow = true;
        } else if (a.len > 0 and a[0] != '-' and goal.len == 0) {
            goal = a;
        }
    }
    if (goal.len == 0) {
        out("usage: veil cast \"<goal>\" [--minutes N] [--minds N] [--model M] [--provider P] [--lineage <id>] [--continuous] [--follow]\n", .{});
        return 1;
    }
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    defer jb.deinit(ctx.gpa);
    jb.appendSlice(ctx.gpa, "{\"goal\":") catch return 1;
    jstr(ctx.gpa, &jb, goal);
    if (minutes.len > 0) appendNum(ctx.gpa, &jb, "minutes", minutes);
    if (minds.len > 0) appendNum(ctx.gpa, &jb, "minds", minds);
    if (model.len > 0) appendStr(ctx.gpa, &jb, "model", model);
    if (provider.len > 0) appendStr(ctx.gpa, &jb, "provider", provider);
    if (base_url.len > 0) appendStr(ctx.gpa, &jb, "base_url", base_url);
    if (key.len > 0) appendStr(ctx.gpa, &jb, "api_key", key);
    if (style.len > 0) appendStr(ctx.gpa, &jb, "style", style);
    if (name.len > 0) appendStr(ctx.gpa, &jb, "name", name);
    if (mode.len > 0) appendStr(ctx.gpa, &jb, "mode", mode);
    if (lineage.len > 0) appendStr(ctx.gpa, &jb, "lineage", lineage);
    jb.appendSlice(ctx.gpa, "}") catch return 1;

    const resp = call(ctx, "POST", "/api/v1/cast", jb.items, 30, true) catch return unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200 and resp.status != 201) {
        std.debug.print("cast rejected (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 300)] });
        return 1;
    }
    const id = jsonStr(ctx.gpa, resp.body, "id") orelse {
        std.debug.print("cast accepted but no id in reply: {s}\n", .{resp.body[0..@min(resp.body.len, 200)]});
        return 0;
    };
    defer ctx.gpa.free(id);
    out("cast deployed: {s}\n", .{id});
    out("  watch:  veil events {s} --follow\n", .{id});
    out("  stop:   veil stop {s}\n", .{id});
    if (follow) return followEvents(ctx, id);
    return 0;
}

fn cmdList(ctx: *Ctx) u8 {
    const resp = call(ctx, "GET", "/api/v1/swarms", null, 6, true) catch return unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) {
        std.debug.print("list failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 200)] });
        return 1;
    }
    // The response is a JSON array of swarm objects. Rather than a full parse, walk each {…} and pull the
    // fields we print — the same string-aware object walk the desk uses, tolerant of field order.
    var count: usize = 0;
    var it = JsonObjs.init(resp.body);
    out("{s: <18}  {s: <9}  {s: <8}  {s}\n", .{ "ID", "STATE", "MINDS", "GOAL" });
    while (it.next()) |obj| {
        const id = jsonStr(ctx.gpa, obj, "id") orelse continue;
        defer ctx.gpa.free(id);
        const state = jsonStr(ctx.gpa, obj, "state") orelse ctx.gpa.dupe(u8, "?") catch continue;
        defer ctx.gpa.free(state);
        const goal = jsonStr(ctx.gpa, obj, "goal") orelse ctx.gpa.dupe(u8, "") catch continue;
        defer ctx.gpa.free(goal);
        const minds = jsonNum(obj, "minds");
        out("{s: <18}  {s: <9}  {d: <8}  {s}\n", .{ id[0..@min(id.len, 18)], state[0..@min(state.len, 9)], minds, goal[0..@min(goal.len, 60)] });
        count += 1;
    }
    if (count == 0) out("(no swarms — deploy one with `veil cast \"<goal>\"`)\n", .{});
    return 0;
}

fn cmdStop(ctx: *Ctx, args: []const []const u8) u8 {
    if (args.len == 0) {
        out("usage: veil stop <id>\n", .{});
        return 1;
    }
    var pb: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/swarms/{s}/control", .{args[0]}) catch return 1;
    const resp = call(ctx, "POST", path, "{\"op\":\"stop\"}", 8, true) catch return unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status == 200 or resp.status == 202) {
        out("stop requested for {s}\n", .{args[0]});
        return 0;
    }
    std.debug.print("stop failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 200)] });
    return 1;
}

fn cmdRm(ctx: *Ctx, args: []const []const u8) u8 {
    if (args.len == 0) {
        out("usage: veil rm <id>\n", .{});
        return 1;
    }
    var pb: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/swarms/{s}", .{args[0]}) catch return 1;
    const resp = call(ctx, "DELETE", path, null, 15, true) catch return unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status == 200) {
        out("removed {s}\n", .{args[0]});
        return 0;
    }
    std.debug.print("remove failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 200)] });
    return 1;
}

fn cmdEvents(ctx: *Ctx, args: []const []const u8) u8 {
    var id: []const u8 = "";
    var follow = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--follow") or std.mem.eql(u8, a, "-f")) follow = true else if (a.len > 0 and a[0] != '-' and id.len == 0) id = a;
    }
    if (id.len == 0) {
        out("usage: veil events <id> [--follow]\n", .{});
        return 1;
    }
    if (follow) return followEvents(ctx, id);
    // one-shot: dump what's there and return
    var pb: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/swarms/{s}/events?from=0", .{id}) catch return 1;
    const resp = call(ctx, "GET", path, null, 8, true) catch return unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) {
        std.debug.print("events failed (HTTP {d})\n", .{resp.status});
        return 1;
    }
    out("{s}\n", .{resp.body});
    return 0;
}

/// Tail a swarm's events.jsonl by advancing the byte cursor (the same protocol the desk poller uses). Prints
/// new bytes as they arrive; ends on a {done} frame or Ctrl-C. Bounded per-poll; a slow server just paces it.
fn followEvents(ctx: *Ctx, id: []const u8) u8 {
    var from: usize = 0;
    var idle: u32 = 0;
    while (idle < 600) { // ~5 min of pure silence ends the follow (a live turn resets idle on any byte)
        var pb: [200]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/api/v1/swarms/{s}/events?from={d}", .{ id, from }) catch return 1;
        const resp = call(ctx, "GET", path, null, 8, false) catch {
            ctx.io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
            idle += 1;
            continue;
        };
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status == 200 and resp.body.len > 0) {
            out("{s}", .{resp.body});
            from += resp.body.len;
            idle = 0;
            if (std.mem.indexOf(u8, resp.body, "\"kind\":\"done\"") != null) {
                out("\n[done]\n", .{});
                return 0;
            }
        } else {
            idle += 1;
        }
        ctx.io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
    }
    return 0;
}

/// `veil sched [list|add|rm|run] …` — scheduled tasks (admin-gated on the server). `add` takes the same fields
/// the desk builder posts; the common forms are documented in the usage string.
fn cmdSched(ctx: *Ctx, args: []const []const u8) u8 {
    const verb = if (args.len > 0) args[0] else "list";
    if (std.mem.eql(u8, verb, "list") or std.mem.eql(u8, verb, "ls")) {
        const resp = call(ctx, "GET", "/api/v1/sched", null, 6, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status == 403) {
            std.debug.print("scheduled tasks are admin-only — the CLI needs the admin .desktop_key\n", .{});
            return 1;
        }
        if (resp.status != 200) {
            std.debug.print("sched list failed (HTTP {d})\n", .{resp.status});
            return 1;
        }
        var it = JsonObjs.init(resp.body);
        out("{s: <28}  {s: <7}  {s: <6}  {s}\n", .{ "ID", "KIND", "RUNS", "NAME" });
        var any = false;
        while (it.next()) |obj| {
            const tid = jsonStr(ctx.gpa, obj, "id") orelse continue;
            defer ctx.gpa.free(tid);
            const kind = jsonStr(ctx.gpa, obj, "kind") orelse ctx.gpa.dupe(u8, "?") catch continue;
            defer ctx.gpa.free(kind);
            const nm = jsonStr(ctx.gpa, obj, "name") orelse ctx.gpa.dupe(u8, "") catch continue;
            defer ctx.gpa.free(nm);
            out("{s: <28}  {s: <7}  {d: <6}  {s}\n", .{ tid[0..@min(tid.len, 28)], kind[0..@min(kind.len, 7)], jsonNum(obj, "runs"), nm });
            any = true;
        }
        if (!any) out("(no scheduled tasks — add one with `veil sched add …`)\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, verb, "run")) {
        if (args.len < 2) {
            out("usage: veil sched run <id>\n", .{});
            return 1;
        }
        var pb: [200]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/api/v1/sched/{s}/run", .{args[1]}) catch return 1;
        const resp = call(ctx, "POST", path, "{}", 8, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status == 200) {
            if (jsonStr(ctx.gpa, resp.body, "conv")) |c| {
                defer ctx.gpa.free(c);
                out("ran now → conversation {s}\n", .{c});
            } else out("ran now\n", .{});
            return 0;
        }
        std.debug.print("run failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 200)] });
        return 1;
    }
    if (std.mem.eql(u8, verb, "rm") or std.mem.eql(u8, verb, "delete")) {
        if (args.len < 2) {
            out("usage: veil sched rm <id>\n", .{});
            return 1;
        }
        var pb: [200]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/api/v1/sched/{s}", .{args[1]}) catch return 1;
        const resp = call(ctx, "DELETE", path, null, 8, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        out("{s}\n", .{if (resp.status == 200) "deleted" else "delete failed"});
        return if (resp.status == 200) 0 else 1;
    }
    if (std.mem.eql(u8, verb, "add") or std.mem.eql(u8, verb, "create")) {
        var name: []const u8 = "";
        var prompt: []const u8 = "";
        var kind: []const u8 = "daily";
        var every: []const u8 = "";
        var at_hm: []const u8 = "";
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (flagVal(args, &i, a, "--name")) |v| name = v else if (flagVal(args, &i, a, "--prompt")) |v| prompt = v else if (flagVal(args, &i, a, "--kind")) |v| kind = v else if (flagVal(args, &i, a, "--every")) |v| every = v else if (flagVal(args, &i, a, "--at")) |v| at_hm = v;
        }
        if (name.len == 0 or prompt.len == 0) {
            out("usage: veil sched add --name N --prompt \"...\" [--kind once|every|daily] [--every MIN] [--at HH:MM]\n", .{});
            return 1;
        }
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(ctx.gpa);
        jb.appendSlice(ctx.gpa, "{\"name\":") catch return 1;
        jstr(ctx.gpa, &jb, name);
        appendStr(ctx.gpa, &jb, "prompt", prompt);
        appendStr(ctx.gpa, &jb, "kind", kind);
        if (every.len > 0) appendNum(ctx.gpa, &jb, "every_min", every);
        if (at_hm.len > 0) appendStr(ctx.gpa, &jb, "hm", at_hm);
        jb.appendSlice(ctx.gpa, ",\"enabled\":true}") catch return 1;
        const resp = call(ctx, "POST", "/api/v1/sched", jb.items, 8, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status == 201) {
            if (jsonStr(ctx.gpa, resp.body, "id")) |tid| {
                defer ctx.gpa.free(tid);
                out("scheduled task created: {s}\n", .{tid});
            }
            return 0;
        }
        std.debug.print("create failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 200)] });
        return 1;
    }
    out("usage: veil sched [list|add|run|rm] …\n", .{});
    return 1;
}

/// `veil desktop` — open the app window.
///
/// Used to locate and spawn a SEPARATE veil-desk binary (probing desk/zig-out/bin, then the bundle dir). That
/// binary is no longer part of a release: the GUI is compiled into this executable and a bare `veil` runs it
/// in-process. So the verb now relaunches THIS executable in app mode, which is the same thing a double-click
/// does — one binary, one code path. It stays a distinct verb because `veil desktop` reads clearly in scripts
/// and docs, and because the plain `veil` form is easy to miss.
fn cmdDesktop(ctx: *Ctx) u8 {
    var eb: [4096]u8 = undefined;
    const n = std.process.executablePath(ctx.io, &eb) catch {
        std.debug.print("could not resolve this executable's path — run `veil` on its own to open the app\n", .{});
        return 1;
    };
    // Detached, exactly like the old spawn: the CLI returns immediately and the app owns its own lifetime.
    // No ensureServer here — app mode brings its own server up in-process (and binds the same port, so an
    // already-running server would make the new instance's listen fail rather than double-bind).
    _ = std.process.spawn(ctx.io, .{ .argv = &.{eb[0..n]}, .cwd = .{ .path = ctx.home }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {
        std.debug.print("could not launch the desktop\n", .{});
        return 1;
    };
    out("launched the veil desktop\n", .{});
    return 0;
}

fn cmdHelp() u8 {
    out(
        \\veil — the local agentic swarm + chat control plane
        \\
        \\USAGE
        \\  veil                         open the app: desktop window + its server, in ONE process
        \\  veil --server-only           run the server alone (headless hosts, service managers)
        \\  veil <command> [args]        talk to the running server (auto-starts it if needed)
        \\
        \\SWARMS
        \\  cast "<goal>" [flags]        deploy a swarm to work a goal
        \\      --minutes N  --minds N  --model M  --provider P  --base-url U  --key K
        \\      --style S  --name N  --continuous  --offline  --follow
        \\      --lineage <id>           persist this swarm's memory under <id> so re-casts COMPOUND (get better over time)
        \\  deploy "<goal>" [flags]      alias for cast --continuous (a sustained hive)
        \\  list | ls                    list your swarms
        \\  stop <id>                    ask a swarm to stop
        \\  rm <id>                      stop and remove a swarm
        \\  events <id> [--follow]       stream a swarm's event log
        \\
        \\CHAT (the server-side veil brain)
        \\  chat [conv]                  interactive chat; steer/stop a running turn inline
        \\
        \\MODEL TRIO (environment, read by `veil chat`)
        \\  Every LLM call carries a role, and each role can run on a different model. Set what you want;
        \\  a role left blank falls back to the SERVER's model for that role if the host published one, and
        \\  to coding otherwise — a plain NL_LLM_* setup still works, but on someone else's server your
        \\  unset roles may run on their choice. A role counts as set only with BOTH a model and a base
        \\  URL; filling one without the other falls back as if you had filled neither.
        \\  coding     the agentic step — streams the reply you read, carries the tool calls. Long prompts,
        \\             every turn. This is the one that has to be good.
        \\             NL_LLM_MODEL  NL_LLM_BASE_URL  NL_LLM_KEY
        \\  thinking   plan, reflect, compact, ctxsum, summary, lesson. `plan` is short and carries the
        \\             judgment; compact/ctxsum are long and mechanical. Only the planning half repays a
        \\             bigger model — the rest is bulk transcript compression.
        \\             NL_LLM_THINK_MODEL  NL_LLM_THINK_BASE_URL  NL_LLM_THINK_KEY
        \\  prompting  one line per drive step — the auto-loop's next step, web-search query rewrites, the
        \\             recovery instruction when a turn is stuck. Short prompts, many calls; small is fine.
        \\             NL_LLM_PROMPT_MODEL  NL_LLM_PROMPT_BASE_URL  NL_LLM_PROMPT_KEY
        \\  These affect `veil chat` only. `cast` takes its model on the command line (--model/--base-url/
        \\  --key — coding only); a task made by `sched add` carries no trio and runs single-model.
        \\
        \\SCHEDULED TASKS
        \\  sched list                   list scheduled tasks
        \\  sched add --name N --prompt "..." [--kind once|every|daily] [--every MIN] [--at HH:MM]
        \\  sched run <id>               run a task now
        \\  sched rm <id>                delete a task
        \\
        \\FLEET
        \\  hub                          fleet console across many veils (see `veil hub help`)
        \\
        \\KNOWLEDGE (local pack corpus — built-in RAG)
        \\  rag status                   is a local knowledge mirror active? (NL_RAG_DIR / <data>/_rag / vendor/nl-rag)
        \\  rag sync --from <clone>      copy a corpus checkout into this app's data dir for offline built-in RAG
        \\      --tier atlas|facts|full  manifest only | +INDEX+distilled facts (default) | +every pack page
        \\      --dest <dir>             sync somewhere else (e.g. vendor/nl-rag inside a source tree, pre-build)
        \\      --include-auto           also copy machine-grown packs (off-topic risk; off by default)
        \\  rag ingest <file>            absorb a LOCAL book/doc/notes into the hive as recallable facts (offline)
        \\      --scope S --name L --cap N --db <hive.sqlite>
        \\
        \\MISC
        \\  doctor                       check server + token health
        \\  desktop                      open the app window (same as a bare `veil`, but detached)
        \\  version                      print the server version
        \\
    , .{});
    return 0;
}

/// `veil rag …` — the local knowledge-corpus mirror: report what a worker would adopt, or sync a corpus
/// checkout into place. Pure-local (no server round-trip): the mirror is a filesystem contract shared by
/// every process on this data dir.
fn cmdRag(ctx: *Ctx, args: []const []const u8) u8 {
    const ragmirror = @import("worker/ragmirror.zig");
    var sub: []const u8 = "status";
    var saw_sub = false;
    var from: []const u8 = "";
    var dest: []const u8 = "";
    var tier_s: []const u8 = "facts";
    var include_auto = false;
    var path: []const u8 = ""; // ingest: the local file/dir to absorb
    var scope: []const u8 = "knowledge";
    var db: []const u8 = "";
    var name: []const u8 = "";
    var cap: u32 = 20000;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--from") and i + 1 < args.len) {
            i += 1;
            from = args[i];
        } else if (std.mem.eql(u8, a, "--dest") and i + 1 < args.len) {
            i += 1;
            dest = args[i];
        } else if (std.mem.eql(u8, a, "--tier") and i + 1 < args.len) {
            i += 1;
            tier_s = args[i];
        } else if (std.mem.eql(u8, a, "--include-auto")) {
            include_auto = true;
        } else if (std.mem.eql(u8, a, "--scope") and i + 1 < args.len) {
            i += 1;
            scope = args[i];
        } else if (std.mem.eql(u8, a, "--db") and i + 1 < args.len) {
            i += 1;
            db = args[i];
        } else if (std.mem.eql(u8, a, "--name") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, a, "--cap") and i + 1 < args.len) {
            i += 1;
            cap = std.fmt.parseInt(u32, args[i], 10) catch cap;
        } else if (a.len > 0 and a[0] != '-') {
            if (!saw_sub) {
                sub = a;
                saw_sub = true;
            } else if (path.len == 0) path = a;
        }
    }
    if (std.mem.eql(u8, sub, "ingest") or std.mem.eql(u8, sub, "absorb")) return cmdRagIngest(ctx, path, scope, db, name, cap);
    if (std.mem.eql(u8, sub, "sync")) {
        if (from.len == 0) {
            out("rag sync needs --from <path to a corpus checkout> (git clone https://github.com/gary23w/nl-rag)\n", .{});
            return 1;
        }
        const tier: ragmirror.SyncTier = if (std.mem.eql(u8, tier_s, "atlas")) .atlas else if (std.mem.eql(u8, tier_s, "full")) .full else .facts;
        const dflt = std.fmt.allocPrint(ctx.gpa, "{s}/_rag", .{ctx.data}) catch return 1;
        defer ctx.gpa.free(dflt);
        const d = if (dest.len > 0) dest else dflt;
        out("syncing corpus ({s} tier{s}): {s} -> {s} ...\n", .{ tier_s, if (include_auto) ", incl. machine-grown" else "", from, d });
        const st = ragmirror.syncFrom(ctx.gpa, ctx.io, from, d, tier, include_auto) catch |e| {
            out("sync failed: {t}\n", .{e});
            return 1;
        };
        out("synced {d} domains, {d} files, {d:.1} MB", .{ st.domains, st.files, @as(f64, @floatFromInt(st.bytes)) / (1024.0 * 1024.0) });
        if (st.missing > 0) out(" ({d} listed domains had no pack files at the source)", .{st.missing});
        out("\nworkers + server adopt it automatically (checked before every pack fetch): {s}\n", .{d});
        return 0;
    }
    if (std.mem.eql(u8, sub, "status")) {
        if (ragmirror.initAt(ctx.gpa, ctx.io, ctx.environ, ctx.data)) {
            out("knowledge mirror: {s}\natlas extension: +{d} domains beyond the compiled table\n", .{ ragmirror.root(), @import("worker/locs/atlas.zig").extension().len });
        } else {
            out("no local knowledge mirror.\nchecked: NL_RAG_DIR, {s}/_rag, vendor/nl-rag\nget one:  git clone https://github.com/gary23w/nl-rag && veil rag sync --from nl-rag\n", .{ctx.data});
        }
        return 0;
    }
    out("usage: veil rag [status] | veil rag sync --from <dir> [--tier atlas|facts|full] [--dest <dir>] [--include-auto]\n         | veil rag ingest <file> [--scope knowledge] [--name <label>] [--cap N] [--db <hive.sqlite>]\n", .{});
    return 1;
}

/// `veil rag ingest <file>` — absorb a LOCAL text file into the knowledge hive as recallable facts,
/// offline (no internet, no rag repo, no LLM). Deterministic distillation → neuron import. The default db
/// is the local user's chat hive, so the desk chat's recall_hive surfaces the absorbed facts immediately.
fn cmdRagIngest(ctx: *Ctx, path: []const u8, scope: []const u8, db_in: []const u8, name_in: []const u8, cap: u32) u8 {
    const osc = @import("worker/oscillation.zig");
    const ragingest = @import("worker/ragingest.zig");
    const tools_mod = @import("worker/tools.zig");
    if (path.len == 0) {
        out("rag ingest needs a file path: veil rag ingest C:/books/mybook.txt\n", .{});
        return 1;
    }
    const neuron_exe = if (builtin.os.tag == .windows) "neuron.exe" else "neuron";
    const neuron_bin = std.fmt.allocPrint(ctx.gpa, "{s}/bin/{s}", .{ ctx.home, neuron_exe }) catch return 1;
    defer ctx.gpa.free(neuron_bin);
    // default target = the local user's chat hive (uid 1), the store the desk chat recalls from
    const db = if (db_in.len > 0) db_in else (std.fmt.allocPrint(ctx.gpa, "{s}/u1/_chat/hive.sqlite", .{ctx.data}) catch return 1);
    defer if (db_in.len == 0) ctx.gpa.free(@constCast(db));
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(64 << 20)) catch {
        out("could not read {s} (missing, unreadable, or larger than 64MB)\n", .{path});
        return 1;
    };
    defer ctx.gpa.free(text);
    if (std.mem.indexOfScalar(u8, text[0..@min(text.len, 4096)], 0) != null) {
        out("{s} looks binary (PDF/EPUB/DOCX?). Convert it to text first (e.g. pdftotext book.pdf book.txt), then: veil rag ingest book.txt\n", .{path});
        return 1;
    }
    var lb: [96]u8 = undefined;
    const label = if (name_in.len > 0) name_in else ragingest.labelFromPath(path, &lb);
    // default target = the document's OWN knowledge__doc-<slug> sub-scope (same policy as the absorb
    // tool): scope = document identity, read_doc pages it in order, across-recall reaches it from the
    // base hive, and one book can never evict the shared knowledge scope. --scope still overrides.
    var scb: [96]u8 = undefined;
    const target = if (std.mem.eql(u8, scope, "knowledge"))
        ragingest.docScope(tools_mod.KNOWLEDGE_SCOPE, label, &scb)
    else
        scope;
    const mem = osc.Mem.init(ctx.gpa, ctx.io, neuron_bin, db);
    out("absorbing {s} ({d} KB) into scope '{s}' ...\n", .{ label, text.len / 1024, target });
    const st = ragingest.ingestText(mem, ctx.io, ctx.gpa, ctx.data, text, label, target, cap);
    if (st.stored == 0 and st.facts == 0) {
        out("no facts distilled — the file has little clean prose (a code file, a table dump, or already-structured data). Nothing was stored.\n", .{});
        return 1;
    }
    if (st.stored == 0 and st.facts > 0) {
        out("distilled {d} facts but stored 0 — the neuron store could not be written. Check the neuron binary at {s} (or pass --db to a writable hive).\n", .{ st.facts, neuron_bin });
        return 1;
    }
    if (st.evicted > 0)
        out("WARNING: the scope hit its fact cap and evicted {d} oldest fact(s) during the load — only the tail is retained. Raise --cap / use a dedicated --scope.\n", .{st.evicted});
    out("absorbed {s}: {d} facts distilled, {d} stored into '{s}' ({s}).\nrecall them:  veil chat  →  \"what does {s} say about <topic>?\"  (or recall_hive; whole-document work: read_doc)\n", .{ label, st.facts, st.stored, target, db, label });
    return 0;
}

// cmdChat + cmdHub are substantial enough to live in their own files (kept here as thin entry points).
const chat_cli = @import("cli/chat.zig");
const hub_cli = @import("cli/hub.zig");
fn cmdChat(ctx: *Ctx, args: []const []const u8) u8 {
    return chat_cli.run(ctx, args, call, followConv, ensureServer, unreachable_msg);
}
fn cmdHub(ctx: *Ctx, args: []const []const u8) u8 {
    return hub_cli.run(ctx, args, call);
}

// re-exports the chat subcommand needs (it lives in a sibling file but drives the same HTTP path)
pub const CallFn = *const fn (ctx: *Ctx, method: []const u8, path: []const u8, body: ?[]const u8, timeout_s: u32, autostart: bool) HttpErr!httpc.Resp;
pub const HttpError = HttpErr;

/// Tail a CHAT conversation's events.jsonl (the /chat/convs/:id/events cursor) rendering the human-relevant
/// frames — used by the interactive chat after a send. Returns when a {done} frame lands.
pub fn followConv(ctx: *Ctx, conv: []const u8) void {
    var from: usize = 0;
    var idle: u32 = 0;
    while (idle < 600) {
        var pb: [220]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/api/v1/chat/convs/{s}/events?from={d}", .{ conv, from }) catch return;
        const resp = call(ctx, "GET", path, null, 8, false) catch {
            ctx.io.sleep(.{ .nanoseconds = 300 * std.time.ns_per_ms }, .awake) catch {};
            idle += 1;
            continue;
        };
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status == 200 and resp.body.len > 0) {
            // One events page is capped at 512KB server-side, so the body can end MID-LINE. Advancing
            // `from` over those partial bytes would consume that frame without ever parsing it — and a
            // dropped tool_request leaves the turn blocked forever on a result nobody will post. So only
            // consume up to the last COMPLETE line and re-read the torn tail whole on the next poll.
            const nl_end = if (resp.body[resp.body.len - 1] == '\n')
                resp.body.len
            else if (std.mem.lastIndexOfScalar(u8, resp.body, '\n')) |nl| nl + 1 else 0;
            // A single line bigger than a whole page can never complete by re-reading; take it as-is
            // rather than re-poll the same offset forever making no progress.
            const use = if (nl_end == 0 and resp.body.len >= (512 << 10)) resp.body else resp.body[0..nl_end];
            if (use.len > 0) {
                renderConvFrames(ctx, use);
                runDelegatedTools(ctx, conv, use); // CLIENT MODE: execute any tool_request the server sent
                from += use.len;
                idle = 0;
                if (std.mem.indexOf(u8, use, "\"kind\":\"done\"") != null) return;
            } else idle += 1; // only a partial line has arrived — nothing consumed, nothing rendered
        } else idle += 1;
        ctx.io.sleep(.{ .nanoseconds = 250 * std.time.ns_per_ms }, .awake) catch {};
    }
}

/// CLIENT MODE: the server delegated tool calls back to us. Run each with the shared executor (in this
/// process, so file/shell/code act on the user's machine) and post the result so the blocked turn continues.
/// Also materializes {kind:"file_sync"} frames — a finished hive's output pushed down so it exists HERE —
/// in the same ordered pass, so a synced file always lands before the delegated tool that reads it.
fn runDelegatedTools(ctx: *Ctx, conv: []const u8, bytes: []const u8) void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const ln = std.mem.trim(u8, line, " \r\t");
        if (ln.len == 0) continue;
        const kind = jsonStr(ctx.gpa, ln, "kind") orelse continue;
        defer ctx.gpa.free(kind);
        if (std.mem.eql(u8, kind, "file_sync")) {
            applyFileSync(ctx, ln);
            continue;
        }
        if (std.mem.eql(u8, kind, "sync_request")) {
            // workdir-sync manifest exchange (see worker/chat/sync.zig): answer with the manifest of this cwd
            // — or, for a sync_dir projection, of the frame's ABSOLUTE `root` on this machine — plus the probe
            // echo so the server can diff (or detect a shared disk) instead of transferring blind. An unsafe
            // root answers an EMPTY manifest, never a substitute directory.
            const id = jsonStr(ctx.gpa, ln, "id") orelse continue;
            defer ctx.gpa.free(id);
            const root = jsonStr(ctx.gpa, ln, "root");
            defer if (root) |r| ctx.gpa.free(r);
            var bad_root = false;
            const wd: []const u8 = if (root) |r| blk: {
                if (!cync.safeRoot(r)) {
                    bad_root = true;
                    break :blk ".";
                }
                std.debug.print("  [projecting {s} for the server...]\n", .{r});
                break :blk r;
            } else ".";
            const resp = if (bad_root) (ctx.gpa.dupe(u8, "{\"probe\":\"\",\"files\":[]}") catch continue) else cync.manifestResponse(ctx.gpa, ctx.io, wd);
            defer ctx.gpa.free(resp);
            postToolResult(ctx, conv, id, resp);
            continue;
        }
        if (std.mem.eql(u8, kind, "file_pull")) {
            // the server wants these files (for a hive, or a sync_dir projection) — send only what it asked for
            const id = jsonStr(ctx.gpa, ln, "id") orelse continue;
            defer ctx.gpa.free(id);
            const root = jsonStr(ctx.gpa, ln, "root");
            defer if (root) |r| ctx.gpa.free(r);
            var bad_root = false;
            const wd: []const u8 = if (root) |r| blk: {
                if (!cync.safeRoot(r)) {
                    bad_root = true;
                    break :blk ".";
                }
                break :blk r;
            } else ".";
            std.debug.print("  [sending files to the server...]\n", .{});
            const resp = if (bad_root) (ctx.gpa.dupe(u8, "{\"files\":[]}") catch continue) else cync.readResponse(ctx.gpa, ctx.io, wd, ln);
            defer ctx.gpa.free(resp);
            postToolResult(ctx, conv, id, resp);
            continue;
        }
        if (!std.mem.eql(u8, kind, "tool_request")) continue;
        const id = jsonStr(ctx.gpa, ln, "id") orelse continue;
        defer ctx.gpa.free(id);
        const tool = jsonStr(ctx.gpa, ln, "tool") orelse continue;
        defer ctx.gpa.free(tool);
        const args = jsonStr(ctx.gpa, ln, "args") orelse ctx.gpa.dupe(u8, "{}") catch continue;
        defer ctx.gpa.free(args);
        std.debug.print("\n  [running {s} on this machine...]\n", .{tool});
        postToolAck(ctx, conv, id); // pickup signal: the server's short no-ack window ends here, and the
        //                             full tool patience starts (the CLI runs the tool synchronously below)
        const result = exec_tool.runTool(ctx, ".", tool, args); // workdir = the CLI's current directory
        defer ctx.gpa.free(result);
        postToolResult(ctx, conv, id, result);
    }
}

/// Write one server-pushed hive file into the CLI's workdir (the same "." the delegated tools run in).
fn applyFileSync(ctx: *Ctx, line: []const u8) void {
    const path = jsonStr(ctx.gpa, line, "path") orelse return;
    defer ctx.gpa.free(path);
    if (!cync.safeSyncPath(path)) return;
    const content = jsonStr(ctx.gpa, line, "content") orelse return;
    defer ctx.gpa.free(content);
    if (std.fs.path.dirname(path)) |parent| _ = std.Io.Dir.cwd().createDirPathStatus(ctx.io, parent, .default_dir) catch {};
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = content }) catch return;
    std.debug.print("  [synced {s} from the hive — {d}b]\n", .{ path, content.len });
}

/// POST {"id":..,"ack":true} — tell the blocked server turn its tool was picked up and is running here, so
/// its fast "no client attached" window doesn't fire while a slow tool works. Best-effort.
fn postToolAck(ctx: *Ctx, conv: []const u8, id: []const u8) void {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(ctx.gpa);
    body.appendSlice(ctx.gpa, "{\"id\":") catch return;
    jstr(ctx.gpa, &body, id);
    body.appendSlice(ctx.gpa, ",\"ack\":true}") catch return;
    var pb: [220]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/chat/convs/{s}/tool_result", .{conv}) catch return;
    const resp = call(ctx, "POST", path, body.items, 8, false) catch return;
    if (resp.body.len > 0) ctx.gpa.free(resp.body);
}

/// POST the delegated tool's result back to the blocked server turn.
fn postToolResult(ctx: *Ctx, conv: []const u8, id: []const u8, result: []const u8) void {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(ctx.gpa);
    body.appendSlice(ctx.gpa, "{\"id\":") catch return;
    jstr(ctx.gpa, &body, id);
    body.appendSlice(ctx.gpa, ",\"result\":") catch return;
    jstr(ctx.gpa, &body, result);
    body.append(ctx.gpa, '}') catch return;
    var pb: [220]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/chat/convs/{s}/tool_result", .{conv}) catch return;
    const resp = call(ctx, "POST", path, body.items, 8, false) catch return;
    if (resp.body.len > 0) ctx.gpa.free(resp.body);
}

/// Render the chat event frames a terminal cares about: assistant tokens (streamed inline), tool starts, and
/// status lines. Reasoning/usage/message-echo frames are skipped to keep the transcript readable.
fn renderConvFrames(ctx: *Ctx, bytes: []const u8) void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const ln = std.mem.trim(u8, line, " \r\t");
        if (ln.len == 0) continue;
        const kind = jsonStr(ctx.gpa, ln, "kind") orelse continue;
        defer ctx.gpa.free(kind);
        if (std.mem.eql(u8, kind, "token")) {
            if (jsonStr(ctx.gpa, ln, "delta")) |d| {
                defer ctx.gpa.free(d);
                out("{s}", .{d}); // the reply itself — stdout, so piping a chat turn captures it
            }
        } else if (std.mem.eql(u8, kind, "tool")) {
            if (jsonStr(ctx.gpa, ln, "tool")) |tname| {
                defer ctx.gpa.free(tname);
                const state = jsonStr(ctx.gpa, ln, "state") orelse ctx.gpa.dupe(u8, "") catch continue;
                defer ctx.gpa.free(state);
                std.debug.print("\n  [{s} {s}]\n", .{ tname, state });
            }
        } else if (std.mem.eql(u8, kind, "status")) {
            if (jsonStr(ctx.gpa, ln, "text")) |txt| {
                defer ctx.gpa.free(txt);
                std.debug.print("\n  · {s}\n", .{txt});
            }
        }
    }
}

// ------------------------------------------------------------------------------- small helpers

// Captured once in dispatch. Results print to STDOUT so they survive a pipe (`veil ls | grep`,
// `veil events <id> > log`); errors and usage notes stay on std.debug.print's stderr. Threading io
// through ~50 pure-output call sites buys nothing in a single-threaded CLI, hence the file-scope copy.
var stdout_io: ?std.Io = null;

pub fn out(comptime fmt: []const u8, args: anytype) void {
    const io = stdout_io orelse return std.debug.print(fmt, args);
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch {};
}

/// `--flag value` reader: if `a == flag`, advance `*i` past the value and return it (empty when it's the last
/// token). Also accepts `--flag=value`. Returns null when `a` isn't this flag.
fn flagVal(args: []const []const u8, i: *usize, a: []const u8, flag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, a, flag)) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            return args[i.*];
        }
        return "";
    }
    if (a.len > flag.len + 1 and std.mem.startsWith(u8, a, flag) and a[flag.len] == '=')
        return a[flag.len + 1 ..];
    return null;
}

fn jstr(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    list.append(gpa, '"') catch return;
    for (s) |c| switch (c) {
        '"' => list.appendSlice(gpa, "\\\"") catch return,
        '\\' => list.appendSlice(gpa, "\\\\") catch return,
        '\n' => list.appendSlice(gpa, "\\n") catch return,
        '\r' => list.appendSlice(gpa, "\\r") catch return,
        '\t' => list.appendSlice(gpa, "\\t") catch return,
        else => list.append(gpa, c) catch return,
    };
    list.append(gpa, '"') catch return;
}

fn appendStr(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), field: []const u8, val: []const u8) void {
    list.append(gpa, ',') catch return;
    jstr(gpa, list, field);
    list.append(gpa, ':') catch return;
    jstr(gpa, list, val);
}

/// Append `,"field":<val>` treating val as a raw NUMBER when it parses as one, else as a quoted string (so a
/// bad --minutes value degrades to a string the server rejects cleanly rather than producing invalid JSON).
fn appendNum(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), field: []const u8, val: []const u8) void {
    _ = std.fmt.parseInt(i64, val, 10) catch return appendStr(gpa, list, field, val);
    list.append(gpa, ',') catch return;
    jstr(gpa, list, field);
    list.append(gpa, ':') catch return;
    list.appendSlice(gpa, val) catch return;
}

/// Extract a string field's value from a flat JSON object (gpa-owned, unescaped enough for display). Null when
/// absent. String-aware: it finds `"field"` as a KEY (followed by `:`), not as a substring of some value.
pub fn jsonStr(gpa: std.mem.Allocator, json: []const u8, field: []const u8) ?[]u8 {
    const val = rawField(json, field) orelse return null;
    if (val.len == 0 or val[0] != '"') return null;
    var out_list: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 1;
    while (i < val.len) : (i += 1) {
        const c = val[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < val.len) {
            i += 1;
            const e = val[i];
            (out_list.append(gpa, switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => e,
            }) catch {
                out_list.deinit(gpa);
                return null;
            });
        } else out_list.append(gpa, c) catch {
            out_list.deinit(gpa);
            return null;
        };
    }
    return out_list.toOwnedSlice(gpa) catch null;
}

/// A numeric field's non-negative value (0 when absent / negative / non-numeric). Unsigned so a `{d:<N}`
/// width spec doesn't reserve a sign slot and print "+2" (Zig's signed-with-width behavior).
pub fn jsonNum(json: []const u8, field: []const u8) u64 {
    const val = rawField(json, field) orelse return 0;
    var end: usize = 0;
    while (end < val.len and std.ascii.isDigit(val[end])) end += 1;
    return std.fmt.parseInt(u64, val[0..end], 10) catch 0;
}

/// The raw bytes right after `"field":` (whitespace-trimmed) up to the object's logical end. Finds the field
/// as a real key: scans for `"field"` then requires the next non-space char to be `:`.
fn rawField(json: []const u8, field: []const u8) ?[]const u8 {
    var kbuf: [96]u8 = undefined;
    if (field.len + 2 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + field.len], field);
    kbuf[1 + field.len] = '"';
    const key = kbuf[0 .. field.len + 2];
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, json, search, key)) |pos| {
        var j = pos + key.len;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t')) j += 1;
        if (j < json.len and json[j] == ':') {
            j += 1;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t')) j += 1;
            return json[j..];
        }
        search = pos + key.len;
    }
    return null;
}

/// Iterate the objects INSIDE the first JSON array of `s` — i.e. the results array of a
/// `{"ok":true,"swarms":[{…},{…}]}` (or `"tasks":[…]`) envelope, or a bare `[{…},{…}]`. String-aware brace
/// matching so a `{` in a quoted value never opens a phantom object. On first call it seeks past the opening
/// `[`, then yields each brace-balanced `{…}` until the matching `]`. Objects nested inside a yielded object
/// are NOT re-yielded (a member's own array is skipped by the depth tracking). Yields each element slice.
pub const JsonObjs = struct {
    s: []const u8,
    i: usize = 0,
    started: bool = false,

    pub fn init(s: []const u8) JsonObjs {
        return .{ .s = s };
    }

    pub fn next(self: *JsonObjs) ?[]const u8 {
        if (!self.started) {
            // seek to the first '[' (the results array); if none, fall back to scanning from the start so a
            // bare object response still yields itself.
            var k: usize = 0;
            var in_s = false;
            var es = false;
            while (k < self.s.len) : (k += 1) {
                const c = self.s[k];
                if (in_s) {
                    if (es) es = false else if (c == '\\') es = true else if (c == '"') in_s = false;
                    continue;
                }
                if (c == '"') in_s = true else if (c == '[') break;
            }
            self.i = if (k < self.s.len) k + 1 else 0;
            self.started = true;
        }
        // find the next top-level '{' (stop at the array's closing ']' at this level)
        while (self.i < self.s.len and self.s[self.i] != '{') {
            if (self.s[self.i] == ']') return null;
            self.i += 1;
        }
        if (self.i >= self.s.len) return null;
        const start = self.i;
        var depth: usize = 0;
        var in_str = false;
        var esc = false;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (in_str) {
                if (esc) {
                    esc = false;
                } else if (c == '\\') {
                    esc = true;
                } else if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        self.i += 1;
                        return self.s[start..self.i];
                    }
                },
                else => {},
            }
        }
        return null;
    }
};

test "jsonStr pulls a key value, string-aware" {
    const gpa = std.testing.allocator;
    const j = "{\"id\":\"abc123\",\"goal\":\"build a {thing}\",\"minds\":3}";
    const id = jsonStr(gpa, j, "id").?;
    defer gpa.free(id);
    try std.testing.expectEqualStrings("abc123", id);
    const goal = jsonStr(gpa, j, "goal").?;
    defer gpa.free(goal);
    try std.testing.expectEqualStrings("build a {thing}", goal);
    try std.testing.expectEqual(@as(u64, 3), jsonNum(j, "minds"));
}

test "JsonObjs walks array objects inside an envelope, brace-in-string safe" {
    const arr = "{\"ok\":true,\"swarms\":[{\"id\":\"a\",\"goal\":\"x}y\"},{\"id\":\"b\"}]}";
    var it = JsonObjs.init(arr);
    const o1 = it.next().?; // first ELEMENT (the envelope's outer object is skipped — we start inside the array)
    try std.testing.expect(std.mem.indexOf(u8, o1, "\"id\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, o1, "\"ok\"") == null);
    const o2 = it.next().?;
    try std.testing.expect(std.mem.indexOf(u8, o2, "\"id\":\"b\"") != null);
    try std.testing.expect(it.next() == null);
}

test "JsonObjs on an empty results array yields nothing" {
    var it = JsonObjs.init("{\"ok\":true,\"tasks\":[]}");
    try std.testing.expect(it.next() == null);
}

test "flagVal reads space and equals forms" {
    const args = [_][]const u8{ "--minutes", "5", "--name=quick" };
    var i: usize = 0;
    try std.testing.expectEqualStrings("5", flagVal(&args, &i, args[0], "--minutes").?);
    i = 2;
    try std.testing.expectEqualStrings("quick", flagVal(&args, &i, args[2], "--name").?);
}
