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
const toolperf = @import("worker/chat/toolperf.zig");

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
        "sync-read", "sync-manifest", "rag",    "themes",  "plugins",   "plug",
        "model",
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
    if (std.mem.eql(u8, sub, "doctor") or std.mem.eql(u8, sub, "health")) return cmdDoctor(ctx, args);
    if (std.mem.eql(u8, sub, "desktop") or std.mem.eql(u8, sub, "desk")) return cmdDesktop(ctx);
    if (std.mem.eql(u8, sub, "exec-tool")) return exec_tool.cmd(ctx, args);
    if (std.mem.eql(u8, sub, "sync-manifest")) return exec_tool.cmdSyncManifest(ctx, args);
    if (std.mem.eql(u8, sub, "sync-read")) return exec_tool.cmdSyncRead(ctx, args);
    if (std.mem.eql(u8, sub, "rag")) return cmdRag(ctx, args);
    if (std.mem.eql(u8, sub, "themes")) return cmdThemes(ctx, args);
    if (std.mem.eql(u8, sub, "plugins") or std.mem.eql(u8, sub, "plug")) return cmdPlugins(ctx, args);
    if (std.mem.eql(u8, sub, "model")) return cmdModel(ctx, args);
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

fn cmdDoctor(ctx: *Ctx, args: []const []const u8) u8 {
    var runtime = false;
    for (args) |a| if (std.mem.eql(u8, a, "--runtime")) {
        runtime = true;
    };
    out("veil doctor\n", .{});
    out("  data dir : {s}\n", .{ctx.data});
    out("  token    : {s}\n", .{if (ctx.token_len > 0) "loaded (.desktop_key)" else "MISSING — start the server once to mint it"});
    var rc: u8 = 1;
    if (serverUp(ctx)) {
        rc = 0;
        if (call(ctx, "GET", "/api/v1/fleet", null, 4, false)) |resp| {
            defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
            out("  server   : UP on :{d}\n", .{ctx.port});
            if (jsonStr(ctx.gpa, resp.body, "version")) |v| {
                defer ctx.gpa.free(v);
                out("  version  : {s}\n", .{v});
            }
            out("  fleet    : {s}\n", .{resp.body[0..@min(resp.body.len, 200)]});
        } else |_| {
            out("  server   : up on :{d}\n", .{ctx.port});
        }
    } else {
        out("  server   : DOWN on :{d} (run `veil` to start it)\n", .{ctx.port});
    }
    if (runtime) runtimeReport(ctx);
    return rc;
}

/// One bucket of `u*/_metrics/llm.jsonl` rows, keyed either by model or by call label.
const MetricStat = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    nlen: usize = 0,
    turns: u64 = 0,
    calls: u64 = 0,
    tin: u64 = 0,
    tout: u64 = 0,
    tcached: u64 = 0,
    ms: u64 = 0,
};

/// Both foldings of the same rows: per MODEL (what it costs) and per LABEL (which call spends it).
pub const MetricAgg = struct {
    models: [24]MetricStat = [_]MetricStat{.{}} ** 24,
    nmodels: usize = 0,
    roles: [24]MetricStat = [_]MetricStat{.{}} ** 24,
    nroles: usize = 0,
};

fn bucketFor(list: []MetricStat, n: *usize, key: []const u8) ?*MetricStat {
    if (key.len == 0 or key.len > 64) return null;
    for (list[0..n.*]) |*cand| {
        if (std.mem.eql(u8, cand.name[0..cand.nlen], key)) return cand;
    }
    if (n.* >= list.len) return null; // more distinct keys than buckets: fold what fits, drop the tail
    list[n.*].nlen = key.len;
    @memcpy(list[n.*].name[0..key.len], key);
    defer n.* += 1;
    return &list[n.*];
}

/// PURE fold of an llm.jsonl body into `agg` (row shape documented in worker/metrics.zig). Split out of
/// runtimeReport so it can be TESTED: the report writes to stdout, so while this lived inline nothing
/// could assert a single number it printed and an arithmetic regression would have been invisible to the
/// oracle. Malformed rows are SKIPPED, not fatal — one corrupt line must not blank the whole report.
fn foldMetricsJsonl(gpa: std.mem.Allocator, body: []const u8, agg: *MetricAgg) void {
    var lit = std.mem.splitScalar(u8, body, '\n');
    while (lit.next()) |raw_ln| {
        const ln = std.mem.trim(u8, raw_ln, " \r\t");
        if (ln.len == 0) continue;
        const R = struct { model: []const u8 = "", role: []const u8 = "", calls: u64 = 0, in: u64 = 0, out: u64 = 0, cached: u64 = 0, ms: u64 = 0 };
        const p = std.json.parseFromSlice(R, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (bucketFor(&agg.models, &agg.nmodels, p.value.model)) |st| {
            st.turns += 1;
            st.calls += p.value.calls;
            st.tin += p.value.in;
            st.tout += p.value.out;
            st.tcached += p.value.cached;
            st.ms += p.value.ms;
        }
        if (bucketFor(&agg.roles, &agg.nroles, p.value.role)) |rt| {
            rt.turns += 1;
            rt.calls += p.value.calls;
            rt.tin += p.value.in;
            rt.tout += p.value.out;
            rt.tcached += p.value.cached;
            rt.ms += p.value.ms;
        }
    }
}

/// `doctor --runtime` — the app's own runtime ledgers folded into one operator-readable health view:
/// the engine's LEARNED tool behavior (toolperf digest), schedule fail-streaks (the outcome ledger
/// on each task file), and a per-model LLM usage rollup. Reads {data} directly on purpose — the
/// report works with the server down, and nothing here re-derives what the engine already learned.
fn runtimeReport(ctx: *Ctx) void {
    const gpa = ctx.gpa;
    out("  -- runtime --\n", .{});

    // Tools: reuse the engine's own digest (EWMA latency + fail rates; only NOTABLE tools appear).
    // null filter: the operator's report speaks for the whole machine, not one turn's advertised belt.
    if (toolperf.digest(gpa, ctx.io, ctx.data, null)) |d| {
        defer gpa.free(d);
        out("  tools    : {s}\n", .{d});
    } else {
        out("  tools    : nothing notable (no slow or flaky tools with enough samples)\n", .{});
    }

    var root = std.Io.Dir.cwd().openDir(ctx.io, ctx.data, .{ .iterate = true }) catch {
        out("  sched    : (data dir unreadable)\n", .{});
        return;
    };
    defer root.close(ctx.io);

    // Schedules: last_status + fail_streak straight off each task file.
    var tasks: u32 = 0;
    var streaks: u32 = 0;
    var it = root.iterate();
    while (it.next(ctx.io) catch null) |ent| {
        if (ent.kind != .directory or ent.name.len < 2 or ent.name[0] != 'u') continue;
        var pb: [700]u8 = undefined;
        const sd = std.fmt.bufPrint(&pb, "{s}/{s}/_sched", .{ ctx.data, ent.name }) catch continue;
        var dir = std.Io.Dir.cwd().openDir(ctx.io, sd, .{ .iterate = true }) catch continue;
        defer dir.close(ctx.io);
        var fit = dir.iterate();
        while (fit.next(ctx.io) catch null) |f| {
            if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".json")) continue;
            var fpb: [900]u8 = undefined;
            const fp = std.fmt.bufPrint(&fpb, "{s}/{s}", .{ sd, f.name }) catch continue;
            const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, fp, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(raw);
            const T = struct { last_status: []const u8 = "", fail_streak: i64 = 0 };
            const p = std.json.parseFromSlice(T, gpa, raw, .{ .ignore_unknown_fields = true }) catch continue;
            defer p.deinit();
            tasks += 1;
            if (p.value.fail_streak > 0) {
                streaks += 1;
                out("  sched    : {s}/{s} fail_streak={d} last={s}\n", .{ ent.name, f.name[0 .. f.name.len - 5], p.value.fail_streak, p.value.last_status[0..@min(p.value.last_status.len, 80)] });
            }
        }
    }
    if (streaks == 0) out("  sched    : {d} task(s), no fail streaks\n", .{tasks});

    // Models: fold u*/_metrics/llm.jsonl (shape documented in worker/metrics.zig) per model.
    var agg: MetricAgg = .{};
    // The SAME rows also carry `role` (the call's label: chat, plan, summary, arbiter, ...) and
    // `cached`. Both were parsed away here, which left the two questions you actually ask when a bill
    // looks wrong unanswerable from the report: WHICH call is spending it, and is the provider's
    // prompt cache working at all. metrics.zig writes `cached` precisely so the second one can be
    // answered "from our own meters", and llm.zig folds three provider dialects to get it — the data
    // reached disk and stopped one layer short of a reader. A chat turn fires one `chat` stream plus
    // up to a dozen auxiliary calls (plan, recon, arbiter, stuck, reflect, ctxsum, compact...), so a
    // per-model total cannot tell you that, say, `plan` is a third of the spend. (Ledger 0079.)

    const metrics = @import("worker/metrics.zig"); // owns the rotation bound AND the read limit; they pair
    var it2 = root.iterate();
    while (it2.next(ctx.io) catch null) |ent| {
        if (ent.kind != .directory or ent.name.len < 2 or ent.name[0] != 'u') continue;
        var pb: [700]u8 = undefined;
        const mp = std.fmt.bufPrint(&pb, "{s}/{s}/_metrics/llm.jsonl", .{ ctx.data, ent.name }) catch continue;
        // Only a MISSING ledger is silent. Any other error means this user's spend is absent from the
        // totals below, and a quiet `continue` would print them as though they were complete — worse,
        // if every user failed the report would claim "no llm.jsonl yet" about files that DO exist.
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, mp, gpa, .limited(metrics.LLM_READ_LIMIT)) catch |e| {
            if (e != error.FileNotFound) out("  models   : {s}/_metrics/llm.jsonl unreadable ({t}) — EXCLUDED from the totals below\n", .{ ent.name, e });
            continue;
        };
        defer gpa.free(data);
        foldMetricsJsonl(gpa, data, &agg);
    }
    if (agg.nmodels == 0) {
        out("  models   : no llm.jsonl yet (served chat turns write it)\n", .{});
        return;
    }
    for (agg.models[0..agg.nmodels]) |*st| {
        // cache% is the share of INPUT tokens the provider served from its prompt cache. Near zero on
        // a hosted model means the prompt is being re-prefilled every call — the exact failure the
        // stable-prefix contracts in engine.zig and run.zig exist to prevent, and until now it was
        // measured, written to disk, and never shown to anyone.
        const cache_pct: u64 = if (st.tin > 0) st.tcached * 100 / st.tin else 0;
        out("  model    : {s} — {d} turn-rows, {d} calls, {d}k in / {d}k out, {d}% cached, avg {d}ms/row\n", .{
            st.name[0..st.nlen], st.turns, st.calls, st.tin / 1000, st.tout / 1000, cache_pct,
            if (st.turns > 0) st.ms / st.turns else 0,
        });
    }

    // Per-label spend, biggest first: the actionable view. `chat` is the answer the user waited for;
    // everything else is the engine deciding, and an auxiliary call that rivals `chat` is the first
    // place to look for a cheap pre-gate (planWorthwhile is the pattern — an inference-free predicate
    // that skips the round-trip entirely).
    var total_in: u64 = 0;
    for (agg.roles[0..agg.nroles]) |*r| total_in += r.tin;
    var shown: usize = 0;
    while (shown < agg.nroles and shown < 8) : (shown += 1) {
        var best: usize = shown;
        for (agg.roles[shown..agg.nroles], shown..) |*cand, idx| {
            if (cand.tin + cand.tout > agg.roles[best].tin + agg.roles[best].tout) best = idx;
        }
        if (best != shown) {
            const tmp = agg.roles[shown];
            agg.roles[shown] = agg.roles[best];
            agg.roles[best] = tmp;
        }
        const r = &agg.roles[shown];
        const share: u64 = if (total_in > 0) r.tin * 100 / total_in else 0;
        const rc: u64 = if (r.tin > 0) r.tcached * 100 / r.tin else 0;
        out("  call     : {s} — {d} calls, {d}k in / {d}k out, {d}% of input, {d}% cached\n", .{
            r.name[0..r.nlen], r.calls, r.tin / 1000, r.tout / 1000, share, rc,
        });
    }
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

// ------------------------------------------------------------------------------- built-in model

/// `veil model status|pull|import|cancel|rm` — the CLI face of /api/v1/models/builtin. pull and
/// import kick a server-side background job and then POLL the status route, drawing progress until
/// the job lands; Ctrl-C only stops the drawing (the server finishes or resumes later).
fn cmdModel(ctx: *Ctx, args: []const []const u8) u8 {
    const sub = if (args.len > 0) args[0] else "status";
    if (std.mem.eql(u8, sub, "status")) return modelStatusOnce(ctx, true);
    if (std.mem.eql(u8, sub, "pull")) {
        const resp = call(ctx, "POST", "/api/v1/models/builtin/pull", "{}", 10, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) {
            std.debug.print("pull not started (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 300)] });
            return 1;
        }
        return modelWatch(ctx);
    }
    if (std.mem.eql(u8, sub, "import")) {
        var body_buf: [640]u8 = undefined;
        var body: []const u8 = "{}";
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (flagVal(args, &i, args[i], "--path")) |p| {
                var esc: [560]u8 = undefined;
                var n: usize = 0;
                for (p) |c| { // JSON-escape the path (backslashes on Windows)
                    if (n + 2 >= esc.len) break;
                    if (c == '\\' or c == '"') {
                        esc[n] = '\\';
                        n += 1;
                    }
                    esc[n] = c;
                    n += 1;
                }
                body = std.fmt.bufPrint(&body_buf, "{{\"path\":\"{s}\"}}", .{esc[0..n]}) catch "{}";
            }
        }
        const resp = call(ctx, "POST", "/api/v1/models/builtin/import", body, 10, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) {
            std.debug.print("import not started (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 300)] });
            return 1;
        }
        return modelWatch(ctx);
    }
    if (std.mem.eql(u8, sub, "cancel")) {
        const resp = call(ctx, "POST", "/api/v1/models/builtin/cancel", "{}", 10, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        out("cancel requested — the partial transfer stays for a later resume\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, sub, "check")) {
        const resp = call(ctx, "POST", "/api/v1/models/builtin/check", "{}", 10, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) {
            std.debug.print("check not started (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 300)] });
            return 1;
        }
        // the check is a network resolve (plus a one-time hash on an unmanaged store) — poll the
        // verdict out of status rather than pretending it was instant
        var waited: u32 = 0;
        while (waited < 120) : (waited += 1) {
            const sr = call(ctx, "GET", "/api/v1/models/builtin", null, 8, false) catch return unreachable_msg(ctx);
            defer if (sr.body.len > 0) ctx.gpa.free(sr.body);
            if (sr.status != 200) return 1;
            const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, sr.body, .{}) catch return 1;
            defer parsed.deinit();
            const o = if (parsed.value == .object) parsed.value.object else return 1;
            const us = if (o.get("update_state")) |v| (if (v == .string) v.string else "?") else "?";
            if (!std.mem.eql(u8, us, "checking")) {
                if (std.mem.eql(u8, us, "current")) {
                    out("up to date — the store serves the repo's current release\n", .{});
                    return 0;
                }
                if (std.mem.eql(u8, us, "update")) {
                    const f = if (o.get("update_file")) |v| (if (v == .string) v.string else "") else "";
                    const mb: i64 = if (o.get("update_mb")) |v| (if (v == .integer) v.integer else 0) else 0;
                    out("update available: {s} ({d} MB) — run `veil model pull` to install it\n", .{ f, mb });
                    return 0;
                }
                if (std.mem.eql(u8, us, "failed")) {
                    out("check failed — no network, or the repo has no published weights yet\n", .{});
                    return 1;
                }
                out("verdict: {s}\n", .{us});
                return 0;
            }
            ctx.io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .awake) catch {};
        }
        out("check is still running — `veil model status` will show the verdict\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, sub, "rm")) {
        const resp = call(ctx, "DELETE", "/api/v1/models/builtin", null, 10, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) {
            std.debug.print("rm failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 300)] });
            return 1;
        }
        out("weights removed\n", .{});
        return 0;
    }
    std.debug.print("unknown model subcommand '{s}' — status | pull | check | import [--path FILE] | cancel | rm\n", .{sub});
    return 1;
}

/// One status read, pretty-printed. Returns the process exit code (0 even for absent — status is a
/// report, not a failure).
fn modelStatusOnce(ctx: *Ctx, verbose: bool) u8 {
    const resp = call(ctx, "GET", "/api/v1/models/builtin", null, 8, true) catch return unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) {
        std.debug.print("status failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 300)] });
        return 1;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, resp.body, .{}) catch {
        std.debug.print("unparseable status reply\n", .{});
        return 1;
    };
    defer parsed.deinit();
    const o = if (parsed.value == .object) parsed.value.object else {
        std.debug.print("unparseable status reply\n", .{});
        return 1;
    };
    const state = if (o.get("state")) |v| (if (v == .string) v.string else "?") else "?";
    const compiled = if (o.get("compiled")) |v| (v == .bool and v.bool) else false;
    const model = if (o.get("model")) |v| (if (v == .string) v.string else "?") else "?";
    out("built-in model: {s}\n", .{model});
    out("  engine:  {s}{s}\n", .{ state, if (compiled) "" else "  (not compiled into this build: -Dbuiltin=false)" });
    if (o.get("path")) |v| if (v == .string and v.string.len > 0) out("  weights: {s}\n", .{v.string});
    if (o.get("err")) |v| if (v == .string and v.string.len > 0) out("  error:   {s}\n", .{v.string});
    if (verbose) {
        if (o.get("bytes_total")) |bt| if (bt == .integer and bt.integer > 0) {
            const done: i64 = if (o.get("bytes_done")) |bd| (if (bd == .integer) bd.integer else 0) else 0;
            out("  transfer: {d} / {d} MB\n", .{ @divTrunc(done, 1 << 20), @divTrunc(bt.integer, 1 << 20) });
        };
        if (o.get("synced_dir_warning")) |v| if (v == .bool and v.bool)
            out("  note: the models dir is under a cloud-synced folder — set NL_MODELS_DIR to a local path\n", .{});
    }
    return 0;
}

/// Poll status ~1Hz until the transfer lands; draw progress in place. The terminal states are the
/// exit code: done/cold/ready = 0, failed/cancelled = 1.
fn modelWatch(ctx: *Ctx) u8 {
    var last_pct: i64 = -1;
    while (true) {
        const resp = call(ctx, "GET", "/api/v1/models/builtin", null, 8, false) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status != 200) return 1;
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, resp.body, .{}) catch return 1;
        defer parsed.deinit();
        const o = if (parsed.value == .object) parsed.value.object else return 1;
        const state = if (o.get("state")) |v| (if (v == .string) v.string else "?") else "?";
        const pct: i64 = if (o.get("pct")) |v| (if (v == .integer) v.integer else 0) else 0;
        const done: i64 = if (o.get("bytes_done")) |v| (if (v == .integer) v.integer else 0) else 0;
        if (std.mem.eql(u8, state, "downloading") or std.mem.eql(u8, state, "importing")) {
            if (pct != last_pct) {
                out("\r{s}: {d}%  ({d} MB)      ", .{ state, pct, @divTrunc(done, 1 << 20) });
                last_pct = pct;
            }
        } else if (std.mem.eql(u8, state, "resolving") or std.mem.eql(u8, state, "verifying")) {
            out("\r{s}...                       ", .{state});
        } else {
            out("\n", .{});
            if (std.mem.eql(u8, state, "failed") or std.mem.eql(u8, state, "cancelled")) {
                const err = if (o.get("err")) |v| (if (v == .string) v.string else "") else "";
                out("{s}: {s}\n", .{ state, err });
                return 1;
            }
            out("done — the built-in engine now serves {s}\n", .{if (o.get("file")) |v| (if (v == .string) v.string else "") else ""});
            return 0;
        }
        ctx.io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .awake) catch {};
    }
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
        \\BUILT-IN MODEL (the-veil-12b served by the server itself — no external runtime)
        \\  model status                 weights + engine + any download in flight
        \\  model pull                   download the published weights (resumable, sha-verified)
        \\  model import [--path FILE]   copy an already-downloaded GGUF into the store instead
        \\                               (no --path: auto-import this machine's local-runtime copy)
        \\  model check                  is a newer release published? (compares shas; pull installs it)
        \\  model cancel                 cancel the running pull/import (the partial resumes later)
        \\  model rm                     remove the serving weights
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
        \\EXTENSIONS (themes + plugins — see PLUGINS.md)
        \\  themes [<id>]                list installed themes; an id prints that theme's 16-slot palette
        \\      --json                   dump the raw /api/v1/themes reply (PUBLIC — no auth needed)
        \\  plugins | plug               list loaded plugins (name, version, state, kind, #tools, error)
        \\      --json                   dump the raw /api/v1/plugins reply
        \\  plugins reload               rescan <data>/plugins + <data>/themes and swap the live registry (admin)
        \\
        \\MISC
        \\  doctor [--runtime]           check server + token health; --runtime folds the runtime
        \\                               ledgers into app health (learned tool behavior, schedule
        \\                               fail-streaks, per-model usage) — works with the server down
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

/// `veil themes [<id>] [--json]` — the theme registry (GET /api/v1/themes). That endpoint is PUBLIC, so this
/// needs no auth; the bearer is still sent when present and the server simply ignores it. Bare form prints a
/// table (id, name, mode, mono, builtin, accent = the `blue` slot); an id prints that one theme's full 16-slot
/// palette (slot + #hex per line); `--json` dumps the raw endpoint reply for scripts.
fn cmdThemes(ctx: *Ctx, args: []const []const u8) u8 {
    const theme = @import("plug/theme.zig"); // the FROZEN slot_names list, shared with the desk + web + endpoint
    var want_json = false;
    var id: []const u8 = "";
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) want_json = true else if (a.len > 0 and a[0] != '-' and id.len == 0) id = a;
    }
    const resp = call(ctx, "GET", "/api/v1/themes", null, 6, true) catch return unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status != 200) {
        std.debug.print("themes failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 200)] });
        return 1;
    }
    if (want_json) {
        out("{s}\n", .{resp.body});
        return 0;
    }
    // `veil themes <id>` — that one theme's full palette. Slot names only ever appear inside the nested
    // `colors` object, so a whole-object field lookup pulls each slot's hex cleanly.
    if (id.len > 0) {
        var it = JsonObjs.init(resp.body);
        while (it.next()) |obj| {
            const tid = jsonStr(ctx.gpa, obj, "id") orelse continue;
            defer ctx.gpa.free(tid);
            if (!std.mem.eql(u8, tid, id)) continue;
            const nm = jsonStr(ctx.gpa, obj, "name") orelse ctx.gpa.dupe(u8, "") catch return 1;
            defer ctx.gpa.free(nm);
            out("theme {s} — {s}\n", .{ tid, nm });
            out("  mode: {s}   mono: {s}   builtin: {s}\n", .{
                if (jsonBool(obj, "dark")) "dark" else "light",
                if (jsonBool(obj, "mono_ui")) "yes" else "no",
                if (jsonBool(obj, "builtin")) "yes" else "no",
            });
            for (theme.slot_names) |slot| {
                const hex = jsonStr(ctx.gpa, obj, slot) orelse ctx.gpa.dupe(u8, "?") catch continue;
                defer ctx.gpa.free(hex);
                out("  {s: <8}  {s}\n", .{ slot, hex });
            }
            return 0;
        }
        std.debug.print("no theme with id '{s}' — run `veil themes` to list them\n", .{id});
        return 1;
    }
    // the table
    var it = JsonObjs.init(resp.body);
    out("{s: <14}  {s: <18}  {s: <6}  {s: <5}  {s: <8}  {s}\n", .{ "ID", "NAME", "MODE", "MONO", "BUILTIN", "ACCENT" });
    var count: usize = 0;
    while (it.next()) |obj| {
        const tid = jsonStr(ctx.gpa, obj, "id") orelse continue;
        defer ctx.gpa.free(tid);
        const nm = jsonStr(ctx.gpa, obj, "name") orelse ctx.gpa.dupe(u8, "") catch continue;
        defer ctx.gpa.free(nm);
        const accent = jsonStr(ctx.gpa, obj, "blue") orelse ctx.gpa.dupe(u8, "") catch continue;
        defer ctx.gpa.free(accent);
        out("{s: <14}  {s: <18}  {s: <6}  {s: <5}  {s: <8}  {s}\n", .{
            tid[0..@min(tid.len, 14)],
            nm[0..@min(nm.len, 18)],
            if (jsonBool(obj, "dark")) "dark" else "light",
            if (jsonBool(obj, "mono_ui")) "yes" else "no",
            if (jsonBool(obj, "builtin")) "yes" else "no",
            accent,
        });
        count += 1;
    }
    if (count == 0) out("(no themes)\n", .{});
    return 0;
}

/// `veil plugins [reload] [--json]` (alias `plug`) — the extension registry. GET /api/v1/plugins requires an
/// authenticated user; the CLI sends the admin .desktop_key as its bearer, so it works wherever that key is
/// readable. A 401/403 (no local key, e.g. a remote host) prints a clear note and — for the read — exits
/// clean rather than dumping a bare status. `reload` (POST /api/v1/plugins/reload) is admin-only.
fn cmdPlugins(ctx: *Ctx, args: []const []const u8) u8 {
    var want_json = false;
    var do_reload = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) want_json = true else if (std.mem.eql(u8, a, "reload") or std.mem.eql(u8, a, "rescan")) do_reload = true;
    }
    if (do_reload) {
        const resp = call(ctx, "POST", "/api/v1/plugins/reload", "{}", 20, true) catch return unreachable_msg(ctx);
        defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (resp.status == 401 or resp.status == 403) {
            pluginsAuthNote(ctx);
            return 1; // the admin reload did not happen — a non-zero code so a script sees the failure
        }
        if (resp.status != 200) {
            std.debug.print("reload failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 200)] });
            return 1;
        }
        out("reloaded: {d} plugins, {d} themes\n", .{ jsonNum(resp.body, "plugins"), jsonNum(resp.body, "themes") });
        return 0;
    }
    const resp = call(ctx, "GET", "/api/v1/plugins", null, 6, true) catch return unreachable_msg(ctx);
    defer if (resp.body.len > 0) ctx.gpa.free(resp.body);
    if (resp.status == 401 or resp.status == 403) {
        pluginsAuthNote(ctx);
        return 0; // read-only query behind auth — exit clean (this just isn't the machine with the key)
    }
    if (resp.status != 200) {
        std.debug.print("plugins failed (HTTP {d}): {s}\n", .{ resp.status, resp.body[0..@min(resp.body.len, 200)] });
        return 1;
    }
    if (want_json) {
        out("{s}\n", .{resp.body});
        return 0;
    }
    var it = JsonObjs.init(resp.body);
    out("{s: <18}  {s: <9}  {s: <7}  {s: <7}  {s: <5}  {s}\n", .{ "NAME", "VERSION", "STATE", "KIND", "TOOLS", "ERROR" });
    var count: usize = 0;
    while (it.next()) |obj| {
        const nm = jsonStr(ctx.gpa, obj, "name") orelse continue;
        defer ctx.gpa.free(nm);
        const ver = jsonStr(ctx.gpa, obj, "version") orelse ctx.gpa.dupe(u8, "") catch continue;
        defer ctx.gpa.free(ver);
        const state = jsonStr(ctx.gpa, obj, "state") orelse ctx.gpa.dupe(u8, "?") catch continue;
        defer ctx.gpa.free(state);
        const kind = jsonStr(ctx.gpa, obj, "kind") orelse ctx.gpa.dupe(u8, "?") catch continue;
        defer ctx.gpa.free(kind);
        // The error column is only meaningful on a failed row; ok rows carry an empty string, so it prints blank.
        const err = jsonStr(ctx.gpa, obj, "error") orelse ctx.gpa.dupe(u8, "") catch continue;
        defer ctx.gpa.free(err);
        out("{s: <18}  {s: <9}  {s: <7}  {s: <7}  {d: <5}  {s}\n", .{
            nm[0..@min(nm.len, 18)],
            ver[0..@min(ver.len, 9)],
            state[0..@min(state.len, 7)],
            kind[0..@min(kind.len, 7)],
            jsonArrayLen(obj, "tools"),
            err[0..@min(err.len, 80)],
        });
        count += 1;
    }
    if (count == 0) out("(no plugins loaded — drop a *.lua in <data>/plugins, then `veil plugins reload`)\n", .{});
    return 0;
}

/// Explain a plugins 401/403: the read needs an authenticated session, which the CLI gets from the server's
/// local admin key. Tailored to whether a key was even found, so the fix is concrete.
fn pluginsAuthNote(ctx: *Ctx) void {
    if (ctx.token_len == 0)
        out("plugins need an authenticated session, but no admin key was found at {s}/.desktop_key. Start the server once on this machine (run `veil`) to mint it, then retry.\n", .{ctx.data})
    else
        out("plugins need an authenticated session and the local admin key at {s}/.desktop_key was not accepted. Run this on the machine that owns the server's session/key.\n", .{ctx.data});
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

/// The ONE JSON string escaper for the CLI — `cli/hub.zig` and `cli/chat.zig` call this instead of
/// keeping their own. There were three hand-rolled copies of these nine lines and TWO were missing
/// the `c < 0x20` arm below, which is exactly why this bug keeps returning: fixing one copy leaves
/// the others. (hub's broadcast died on a pasted CRLF; desk/main.jesc emitted raw control bytes;
/// this copy silently killed tool results.)
///
/// Bytes under 0x20 are not legal inside a JSON string. `postToolResult` puts a delegated tool's
/// arbitrary OUTPUT through here — compiler colour, a form feed, a stray NUL — so unescaped, the
/// body is malformed, the server's parser rejects it, and the blocked turn never receives its
/// result: a stall with nothing printed to explain it.
///
/// `gateway/http.jstr` stays separate on purpose — it returns an error union rather than swallowing,
/// and pulling the gateway into the CLI path to save nine lines would be the worse trade.
pub fn jstr(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    list.append(gpa, '"') catch return;
    for (s) |c| switch (c) {
        '"' => list.appendSlice(gpa, "\\\"") catch return,
        '\\' => list.appendSlice(gpa, "\\\\") catch return,
        '\n' => list.appendSlice(gpa, "\\n") catch return,
        '\r' => list.appendSlice(gpa, "\\r") catch return,
        '\t' => list.appendSlice(gpa, "\\t") catch return,
        else => if (c < 0x20) {
            var b: [6]u8 = undefined;
            list.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "") catch return;
        } else list.append(gpa, c) catch return,
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

/// A boolean field's value (false when absent / non-boolean). Reads the literal right after `"field":`.
fn jsonBool(json: []const u8, field: []const u8) bool {
    const val = rawField(json, field) orelse return false;
    return std.mem.startsWith(u8, val, "true");
}

/// Number of top-level elements in the JSON array at `field` (0 when absent or empty). String- and
/// nest-aware: separators inside nested strings/arrays/objects don't inflate the count — so a plugin's
/// `#tools` is read without materializing the array.
fn jsonArrayLen(json: []const u8, field: []const u8) usize {
    const val = rawField(json, field) orelse return 0;
    if (val.len == 0 or val[0] != '[') return 0;
    var i: usize = 1;
    var depth: usize = 1; // already inside the array's opening '['
    var in_str = false;
    var esc = false;
    var commas: usize = 0;
    var any = false;
    while (i < val.len) : (i += 1) {
        const c = val[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => {
                in_str = true;
                any = true;
            },
            '[', '{' => {
                depth += 1;
                any = true;
            },
            ']', '}' => {
                depth -= 1;
                if (depth == 0) break; // the array's own closing bracket
            },
            ',' => if (depth == 1) {
                commas += 1;
            },
            ' ', '\t', '\n', '\r' => {},
            else => any = true,
        }
    }
    return if (any) commas + 1 else 0;
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

test "jsonBool and jsonArrayLen read flat fields, nest- and string-safe" {
    const j = "{\"dark\":true,\"mono_ui\":false,\"tools\":[\"a\",\"b\",\"c\"]}";
    try std.testing.expect(jsonBool(j, "dark"));
    try std.testing.expect(!jsonBool(j, "mono_ui"));
    try std.testing.expect(!jsonBool(j, "absent"));
    try std.testing.expectEqual(@as(usize, 3), jsonArrayLen(j, "tools"));
    try std.testing.expectEqual(@as(usize, 0), jsonArrayLen(j, "absent"));
    try std.testing.expectEqual(@as(usize, 0), jsonArrayLen("{\"tools\":[]}", "tools"));
    // a comma inside a quoted element must not inflate the count
    try std.testing.expectEqual(@as(usize, 2), jsonArrayLen("{\"tools\":[\"a,b\",\"c\"]}", "tools"));
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

test "a tool result carrying a control byte still forms valid JSON" {
    // postToolResult sends a delegated tool's OUTPUT back to a blocked server turn. That output is
    // arbitrary program text — compiler colour, a form feed, a stray NUL — and bytes below 0x20 are
    // not legal inside a JSON string. Unescaped, the body is malformed, the server's parser rejects
    // it, and the turn never receives its result: a stall with nothing printed to explain it.
    const gpa = std.testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);

    const result = "build \x1b[31mfailed\x1b[0m\x0cpage2\x01";
    try body.appendSlice(gpa, "{\"id\":");
    jstr(gpa, &body, "call_7");
    try body.appendSlice(gpa, ",\"result\":");
    jstr(gpa, &body, result);
    try body.append(gpa, '}');

    // The real check: the server's parser must accept it, and the bytes must survive intact.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(result, parsed.value.object.get("result").?.string);
    try std.testing.expectEqualStrings("call_7", parsed.value.object.get("id").?.string);
}

test "isCommand lists every verb dispatch handles - or the verb boots the daemon instead" {
    // main.zig gates on this: `if (cli_sub.len > 0 and cli.isCommand(cli_sub))` dispatches, and ANYTHING
    // else falls through to booting the server. So a verb added to dispatch and forgotten here does not
    // error - `veil <verb>` silently starts the daemon instead of running the command. The header says
    // "Kept in sync with dispatch below", which is an instruction to a human; this reads the dispatch chain
    // out of the source and checks it (same approach as chat/trio_routing_test.zig and tools.zig's dispatch
    // audit). They agree today - this keeps them agreeing.
    const SRC = @embedFile("cli.zig");

    // Bound the scan to dispatch's own body: from `pub fn dispatch` to the next top-level function. Stopping
    // at the next `pub fn` alone is NOT enough - private `fn cmdRag` further down reuses a local named `sub`,
    // and a scan that runs into it reports four verbs that are really `veil rag` sub-verbs (ledger 0058).
    const start = std.mem.indexOf(u8, SRC, "pub fn dispatch").?;
    const rest = SRC[start + 5 ..];
    const a = std.mem.indexOf(u8, rest, "\nfn ");
    const b = std.mem.indexOf(u8, rest, "\npub fn ");
    const stop = if (a != null and b != null) @min(a.?, b.?) else (a orelse b.?);
    const body = rest[0..stop];

    const needle = "eql(u8, sub, \"";
    var i: usize = 0;
    var found: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, needle)) |at| {
        const vs = at + needle.len;
        const ve = vs + (std.mem.indexOfScalar(u8, body[vs..], '"') orelse break);
        const verb = body[vs..ve];
        i = ve;
        found += 1;
        if (!isCommand(verb)) {
            std.debug.print("\n'{s}' is dispatched but missing from isCommand - `veil {s}` would boot the daemon instead\n", .{ verb, verb });
            return error.UnreachableVerb;
        }
    }
    // Not vacuous: if the scan found nothing (dispatch refactored, needle changed), every assertion above
    // passed without testing anything - which is how this guard would rot silently.
    try std.testing.expect(found >= 25);
}

test "foldMetricsJsonl: both foldings of the same rows, and a corrupt line does not blank the report" {
    const gpa = std.testing.allocator;
    var agg: MetricAgg = .{};

    // Two turns of the same model: a `chat` stream that is mostly cache-served, plus two auxiliary
    // calls that are not. This is the shape the per-label view exists to expose.
    const body =
        \\{"ts":1,"role":"chat","model":"m1","base":"h","calls":3,"in":30000,"out":900,"cached":24000,"ms":3000}
        \\{"ts":1,"role":"plan","model":"m1","base":"h","calls":1,"in":12000,"out":300,"cached":0,"ms":900}
        \\
        \\{ this line is not json at all
        \\{"ts":2,"role":"chat","model":"m1","base":"h","calls":2,"in":20000,"out":600,"cached":16000,"ms":2000}
        \\{"ts":2,"role":"arbiter","model":"m2","base":"h","calls":1,"in":8000,"out":100,"cached":0,"ms":400}
    ;
    foldMetricsJsonl(gpa, body, &agg);

    // MODELS: m1 got 3 rows, m2 got 1. The corrupt line was skipped, not fatal.
    try std.testing.expectEqual(@as(usize, 2), agg.nmodels);
    const m1 = &agg.models[0];
    try std.testing.expectEqualStrings("m1", m1.name[0..m1.nlen]);
    try std.testing.expectEqual(@as(u64, 3), m1.turns);
    try std.testing.expectEqual(@as(u64, 6), m1.calls); // 3 + 1 + 2
    try std.testing.expectEqual(@as(u64, 62000), m1.tin); // 30000 + 12000 + 20000
    try std.testing.expectEqual(@as(u64, 40000), m1.tcached); // only the chat rows are cache-served

    // LABELS: the same rows folded the other way — this is the view that names the expensive call.
    try std.testing.expectEqual(@as(usize, 3), agg.nroles); // chat, plan, arbiter
    const chat = &agg.roles[0];
    try std.testing.expectEqualStrings("chat", chat.name[0..chat.nlen]);
    try std.testing.expectEqual(@as(u64, 50000), chat.tin);
    try std.testing.expectEqual(@as(u64, 40000), chat.tcached);
    // ...and the cache rate the report prints is derived from exactly these two numbers.
    try std.testing.expectEqual(@as(u64, 80), chat.tcached * 100 / chat.tin);
    const plan = &agg.roles[1];
    try std.testing.expectEqual(@as(u64, 0), plan.tcached); // 0% cached — the signal worth seeing

    // A row folds into BOTH views, so the two totals must reconcile. If they ever diverge, one of the
    // folds is dropping rows and every percentage printed from it is wrong.
    var model_in: u64 = 0;
    for (agg.models[0..agg.nmodels]) |*s| model_in += s.tin;
    var role_in: u64 = 0;
    for (agg.roles[0..agg.nroles]) |*s| role_in += s.tin;
    try std.testing.expectEqual(model_in, role_in);
}

test "foldMetricsJsonl: a row missing model or role folds into the view it can, and neither bucket overflows" {
    const gpa = std.testing.allocator;
    var agg: MetricAgg = .{};
    // metrics.zig writes an "other" reconciliation row; a future writer could omit a key entirely.
    // Neither should be counted twice nor abort the fold.
    foldMetricsJsonl(gpa, "{\"role\":\"chat\",\"in\":100}\n{\"model\":\"m1\",\"in\":200}\n", &agg);
    try std.testing.expectEqual(@as(usize, 1), agg.nmodels);
    try std.testing.expectEqual(@as(usize, 1), agg.nroles);
    try std.testing.expectEqual(@as(u64, 200), agg.models[0].tin);
    try std.testing.expectEqual(@as(u64, 100), agg.roles[0].tin);

    // More distinct keys than buckets: fold what fits and stop, rather than writing past the array.
    var many: MetricAgg = .{};
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..40) |i| try buf.print(gpa, "{{\"role\":\"r{d}\",\"model\":\"m{d}\",\"in\":1}}\n", .{ i, i });
    foldMetricsJsonl(gpa, buf.items, &many);
    try std.testing.expectEqual(@as(usize, 24), many.nroles);
    try std.testing.expectEqual(@as(usize, 24), many.nmodels);
}
