//! Deploy + swarm-lifecycle HTTP handlers — the validate → run_dir + swarm.json → spawn pipeline, plus the

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const ent = @import("../plan/entitlements.zig");
const neurons = @import("../plan/neurons.zig");
const crypto = @import("../config/key_vault.zig");
const tail_fanout = @import("tail_fanout.zig");
const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;
const capErr = http.capErr;
const notFound = http.notFound;
const unauth = http.unauth;
const serverErr = http.serverErr;
const jstr = http.jstr;

const MindSpec = struct { name: []const u8, role: []const u8 = "", duty: []const u8 = "", lead: bool = false };
const DeployReq = struct {
    name: []const u8,
    model: []const u8 = "mock",
    provider: []const u8 = "mock",
    stack: []const u8 = "static",
    style: []const u8 = "auto",
    mode: []const u8 = "continuous",
    goal: []const u8 = "",
    api_key: []const u8 = "",
    base_url: []const u8 = "",
    minutes: u32 = 0,
    encrypt: bool = false,
    gateway_model: []const u8 = "",
    gateway_base_url: []const u8 = "",
    gateway_key: []const u8 = "",
    veil_population: bool = false,
    // RSI dials — the same knobs the deploy wizard writes into swarm.json. Defaults match the worker's
    // Manifest defaults, so an old client that omits them behaves exactly as before.
    autonomy: []const u8 = "full", // "full" | "bounded"
    internet: bool = true,
    gap_assess: bool = true,
    breakout: bool = false,
    observe_psyche: bool = false,
    // CAST marker — set by the /cast path (quick strike AND sustained "continuous" casts) so the worker
    // terminates at completed/graduated instead of evolveGoal-chaining to a new self-chosen goal. A plain
    // /deploy or /run swarm leaves it false and keeps the full autonomy chain.
    cast: bool = false,
    minds: []MindSpec,
};

const Spawned = struct { id: []const u8, state: []const u8, minds: usize, run_dir: []const u8 };

pub fn deploy(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const body = (try req.json(DeployReq)) orelse return badReq(res, "bad body");
    // A raw /deploy request never picks its own run_dir — that would be a path-traversal hole. Only the cast
    // path (below) supplies a server-sanitized build dir so a chat cast lands in the chat's conversation folder.
    const sp = (try deployCore(app, res, u, body, "")) orelse return;
    res.status = 201;
    try res.json(.{ .ok = true, .id = sp.id, .state = sp.state, .minds = sp.minds }, .{});
}

/// `run_dir_override`, when non-empty, replaces the default `{data}/u{uid}/{id}` run_dir. The swarm id stays a
/// fresh random hex (URLs + supervisor tracking key off it), but the on-disk run_dir — and therefore the
/// worker's `{run_dir}/work` build dir — is redirected to a caller-chosen, already-sanitized absolute path.
/// This is how a chat cast builds IN the chat's conversation dir instead of its own throwaway folder.
fn deployCore(app: *App, res: *httpz.Response, u: http.User, body: DeployReq, run_dir_override: []const u8) !?Spawned {
    const e = ent.entitlements(u.plan, app.auth.isAdmin(u));
    if (body.minds.len == 0) {
        try badReq(res, "a swarm needs at least 1 mind");
        return null;
    }
    if (body.minds.len > e.per_swarm_minds) {
        try capErr(res, try std.fmt.allocPrint(res.arena, "a single swarm is capped at {d} minds on your plan", .{e.per_swarm_minds}));
        return null;
    }
    if (body.encrypt and !e.encrypted) {
        try capErr(res, "encrypted minds are an admin feature");
        return null;
    }
    if (app.sup.liveMindsForUser(u.id) + body.minds.len > e.max_minds) {
        try capErr(res, "that would exceed your plan's live-mind limit — stop a swarm or upgrade to Pro");
        return null;
    }
    if (app.sup.activeSwarmsForUser(u.id) >= e.max_swarms) {
        try capErr(res, "your plan's concurrent-swarm limit is reached — stop one or upgrade to Pro");
        return null;
    }
    if (http.metered(app, u)) {
        if (app.ledger) |l| if (!l.hasBalance(u.id, u.plan)) {
            try capErr(res, "you're out of neurons for this billing period — upgrade your plan or add a top-up to run more swarms");
            return null;
        };
    }
    {
        const lb = body.base_url;
        const local_model = std.mem.eql(u8, body.provider, "ollama") or std.mem.indexOf(u8, lb, "localhost") != null or std.mem.indexOf(u8, lb, "127.0.0.1") != null;
        if (local_model and !app.auth.isAdmin(u)) {
            try capErr(res, "local models (Ollama) are admin-only and don't run in the hosted environment — choose Cloudflare Workers AI or bring your own API key");
            return null;
        }
    }

    var rnd: [8]u8 = undefined;
    app.io.random(&rnd);
    const id = try std.fmt.allocPrint(res.arena, "{s}", .{std.fmt.bytesToHex(rnd, .lower)});
    // run_dir is the override (a chat conversation dir) when the cast asked to build in place, else the default
    // per-swarm folder. Either way `{run_dir}/work` is the deliverable dir the worker uses — the worker needs no
    // change, it just inherits whichever run_dir we spawn it with.
    const run_dir = if (run_dir_override.len > 0)
        try res.arena.dupe(u8, run_dir_override)
    else
        try std.fmt.allocPrint(res.arena, "{s}/u{d}/{s}", .{ app.data, u.id, id });
    const workdir = try std.fmt.allocPrint(res.arena, "{s}/work", .{run_dir});

    // RE-CAST HYGIENE: a cast into a chat conversation dir REUSES the previous cast's run_dir
    // (`_chat/builds/{conv}`), so its lifecycle files are still on disk. A leftover STOP would stop the new
    // worker at its first boundary check, a leftover DONE would read the fresh spawn as already-finished,
    // and the old events.jsonl would splice two runs into one stream. Reset lifecycle metadata ONLY —
    // never work/ or any other user file — BEFORE the manifest write + spawn.
    if (run_dir_override.len > 0) resetCastLifecycle(app, res.arena, run_dir);

    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, workdir, .default_dir) catch {};
    for (body.minds) |m| {
        const md = try std.fmt.allocPrint(res.arena, "{s}/minds/{s}", .{ run_dir, m.name });
        _ = std.Io.Dir.cwd().createDirPathStatus(app.io, md, .default_dir) catch {};
    }

    var eff_key: []const u8 = body.api_key;
    var eff_base: []const u8 = body.base_url;
    var eff_model: []const u8 = body.model;
    const wants_cf_ai = std.mem.eql(u8, body.provider, "workers-ai") or std.mem.eql(u8, body.provider, "cloudflare");
    // A client can BYO Cloudflare by sending the fully-resolved account URL + its own token. If it doesn't
    // (base is the "cloudflare" sentinel or still carries the "{account}" placeholder), fall back to this
    // server's own configured Workers AI credentials — so a missing account id never yields a broken URL.
    const cf_base_ok = std.mem.startsWith(u8, body.base_url, "http") and std.mem.indexOf(u8, body.base_url, "{account}") == null;
    if (wants_cf_ai and (body.api_key.len == 0 or !cf_base_ok)) {
        if (!e.workers_ai) {
            try capErr(res, "Workers AI is not enabled for your account");
            return null;
        }
        if (app.cf_account_id.len == 0 or app.workers_ai_token.len == 0) {
            try serverErr(res, "Workers AI is not configured on this server (set NL_CF_ACCOUNT_ID + NL_WORKERS_AI_TOKEN)");
            return null;
        }
        eff_base = try std.fmt.allocPrint(res.arena, "https://api.cloudflare.com/client/v4/accounts/{s}/ai/v1", .{app.cf_account_id});
        eff_key = app.workers_ai_token;
        if (eff_model.len == 0 or !std.mem.startsWith(u8, eff_model, "@cf/")) eff_model = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
    } else if (eff_key.len == 0) {
        if (app.vault.resolve(u.id, body.provider, res.arena)) |rk| {
            eff_key = rk.key;
            if (rk.base_url.len > 0) eff_base = rk.base_url;
        }
    }

    var mani: std.ArrayListUnmanaged(u8) = .empty;
    defer mani.deinit(app.gpa);
    try mani.appendSlice(app.gpa, "{\"swarm\":");
    try jstr(app.gpa, &mani, body.name);
    try mani.appendSlice(app.gpa, ",\"provider\":");
    try jstr(app.gpa, &mani, body.provider);
    try mani.appendSlice(app.gpa, ",\"base_url\":");
    try jstr(app.gpa, &mani, eff_base);
    try mani.appendSlice(app.gpa, ",\"model\":");
    try jstr(app.gpa, &mani, eff_model);
    try mani.appendSlice(app.gpa, ",\"style\":");
    try jstr(app.gpa, &mani, body.style);
    try mani.appendSlice(app.gpa, ",\"mode\":");
    try jstr(app.gpa, &mani, body.mode);
    try mani.appendSlice(app.gpa, ",\"stack\":");
    try jstr(app.gpa, &mani, body.stack);
    try mani.appendSlice(app.gpa, ",\"workdir\":");
    try jstr(app.gpa, &mani, workdir);
    try mani.appendSlice(app.gpa, ",\"goal\":");
    try jstr(app.gpa, &mani, body.goal);
    const mline = try std.fmt.allocPrint(res.arena, ",\"minutes\":{d}", .{body.minutes});
    try mani.appendSlice(app.gpa, mline);
    if (body.gateway_model.len > 0) {
        try mani.appendSlice(app.gpa, ",\"gateway_model\":");
        try jstr(app.gpa, &mani, body.gateway_model);
    }
    if (body.gateway_base_url.len > 0) {
        try mani.appendSlice(app.gpa, ",\"gateway_base_url\":");
        try jstr(app.gpa, &mani, body.gateway_base_url);
    }
    if (body.gateway_key.len > 0) {
        try mani.appendSlice(app.gpa, ",\"gateway_key\":");
        try jstr(app.gpa, &mani, body.gateway_key);
    }
    if (body.veil_population) try mani.appendSlice(app.gpa, ",\"veil_population\":true");
    // RSI dials — write them explicitly so the manifest carries the same knobs the wizard sets (and the
    // desktop Deploy form can toggle). Autonomy is a string; the rest are bools the worker reads verbatim.
    try mani.appendSlice(app.gpa, ",\"autonomy\":");
    try jstr(app.gpa, &mani, if (std.mem.eql(u8, body.autonomy, "bounded")) "bounded" else "full");
    try mani.appendSlice(app.gpa, if (body.internet) ",\"internet\":true" else ",\"internet\":false");
    try mani.appendSlice(app.gpa, if (body.gap_assess) ",\"gap_assess\":true" else ",\"gap_assess\":false");
    if (body.breakout) try mani.appendSlice(app.gpa, ",\"breakout\":true");
    if (body.observe_psyche) try mani.appendSlice(app.gpa, ",\"observe_psyche\":true");
    // the worker's terminate-don't-chain gate (a sustained cast is mode="continuous", so mode can't carry it)
    if (body.cast) try mani.appendSlice(app.gpa, ",\"cast\":true");
    if (body.encrypt and e.encrypted) try mani.appendSlice(app.gpa, ",\"encrypted\":true");
    try mani.appendSlice(app.gpa, ",\"minds\":[");
    for (body.minds, 0..) |m, i| {
        if (i > 0) try mani.append(app.gpa, ',');
        try mani.appendSlice(app.gpa, "{\"name\":");
        try jstr(app.gpa, &mani, m.name);
        try mani.appendSlice(app.gpa, ",\"role\":");
        try jstr(app.gpa, &mani, m.role);
        try mani.appendSlice(app.gpa, ",\"duty\":");
        try jstr(app.gpa, &mani, m.duty);
        if (m.lead) try mani.appendSlice(app.gpa, ",\"lead\":true");
        try mani.append(app.gpa, '}');
    }
    try mani.appendSlice(app.gpa, "]}");

    const mani_path = try std.fmt.allocPrint(res.arena, "{s}/swarm.json", .{run_dir});
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = mani_path, .data = mani.items }) catch {
        try serverErr(res, "could not write manifest");
        return null;
    };

    if (eff_key.len > 0) {
        var kbuf: std.ArrayListUnmanaged(u8) = .empty;
        defer kbuf.deinit(app.gpa);
        try kbuf.appendSlice(app.gpa, "NL_LLM_KEY=");
        try kbuf.appendSlice(app.gpa, eff_key);
        try kbuf.append(app.gpa, '\n');
        if (eff_base.len > 0) {
            try kbuf.appendSlice(app.gpa, "NL_LLM_BASE_URL=");
            try kbuf.appendSlice(app.gpa, eff_base);
            try kbuf.append(app.gpa, '\n');
        }
        if (body.encrypt and e.encrypted) {
            const sealed = crypto.seal(app.gpa, app.io, app.server_key, kbuf.items) catch {
                try serverErr(res, "could not seal keys");
                return null;
            };
            defer app.gpa.free(sealed);
            const kpath = try std.fmt.allocPrint(res.arena, "{s}/keys.env.enc", .{run_dir});
            std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = kpath, .data = sealed }) catch {};
        } else {
            const kpath = try std.fmt.allocPrint(res.arena, "{s}/keys.env", .{run_dir});
            std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = kpath, .data = kbuf.items }) catch {};
        }
    }

    const sw = app.sup.spawn(u.id, id, body.name, run_dir, eff_model, body.minds.len) catch {
        try serverErr(res, "could not spawn worker");
        return null;
    };
    return .{ .id = sw.id, .state = @tagName(sw.state), .minds = sw.minds, .run_dir = run_dir };
}

/// Reset a reused run dir's LIFECYCLE files before a re-cast spawns into it: drop STOP/DONE/control.jsonl/
/// worker.pid and rotate events.jsonl to events.prev.jsonl (replacing any older rotation, so exactly one
/// previous run stays inspectable). Deliberately narrower than supervisor.cleanCastMeta — that also deletes
/// swarm.json (fine, deploy rewrites it) but ALSO mind.sqlite, the minds/ dirs, and .usage; a re-cast should
/// KEEP the conversation's accumulated hive memory. Never touches work/ or any other user file.
fn resetCastLifecycle(app: *App, arena: std.mem.Allocator, run_dir: []const u8) void {
    const drops = [_][]const u8{ "STOP", "DONE", "control.jsonl", "worker.pid" };
    for (drops) |f| {
        const p = std.fmt.allocPrint(arena, "{s}/{s}", .{ run_dir, f }) catch continue;
        std.Io.Dir.cwd().deleteFile(app.io, p) catch {};
    }
    const ev = std.fmt.allocPrint(arena, "{s}/events.jsonl", .{run_dir}) catch return;
    const prev = std.fmt.allocPrint(arena, "{s}/events.prev.jsonl", .{run_dir}) catch return;
    std.Io.Dir.cwd().deleteFile(app.io, prev) catch {};
    std.Io.Dir.cwd().rename(ev, std.Io.Dir.cwd(), prev, app.io) catch {};
}

const RunReq = struct {
    goal: []const u8 = "",
    model: []const u8 = "",
    provider: []const u8 = "",
    minds: u32 = 0,
    minutes: u32 = 0,
    style: []const u8 = "auto",
    stack: []const u8 = "general",
    mode: []const u8 = "continuous",
    name: []const u8 = "",
    api_key: []const u8 = "",
    base_url: []const u8 = "",
    gateway_model: []const u8 = "",
};

pub fn run(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const rq = (try req.json(RunReq)) orelse return badReq(res, "bad body");
    if (std.mem.trim(u8, rq.goal, " \r\n\t").len == 0) return badReq(res, "a goal is required, e.g. {\"goal\":\"build a CLI todo app\"}");
    const e = ent.entitlements(u.plan, app.auth.isAdmin(u));
    var n: usize = if (rq.minds == 0) 1 else rq.minds;
    if (n > e.per_swarm_minds) n = e.per_swarm_minds;
    if (n == 0) n = 1;
    const names = [_][]const u8{ "nova", "ada", "rex", "lux", "sol" };
    const minds = try res.arena.alloc(MindSpec, n);
    // UNIQUE names past the first 5 (a big cast can line up to 30) — `i % len` would repeat "nova/ada/…" and two
    // minds with the same name collide on their minds/<name> dir + per-mind memory scope.
    for (minds, 0..) |*m, i| {
        const nm = if (i < names.len) names[i] else try std.fmt.allocPrint(res.arena, "mind{d}", .{i + 1});
        m.* = .{ .name = nm, .role = if (i == 0) "Lead" else "Maker", .duty = "build", .lead = i == 0 };
    }
    var sfx: [3]u8 = undefined;
    app.io.random(&sfx);
    const name = if (rq.name.len > 0) rq.name else try std.fmt.allocPrint(res.arena, "run-{s}", .{std.fmt.bytesToHex(sfx, .lower)});
    const body = DeployReq{
        .name = name,
        .provider = if (rq.provider.len > 0) rq.provider else "workers-ai",
        .model = rq.model,
        .stack = rq.stack,
        .style = rq.style,
        .mode = rq.mode,
        .goal = rq.goal,
        .api_key = rq.api_key,
        .base_url = rq.base_url,
        .minutes = rq.minutes,
        .gateway_model = rq.gateway_model,
        .minds = minds,
    };
    const sp = (try deployCore(app, res, u, body, "")) orelse return;
    if (req.header("accept") orelse req.header("Accept")) |acc| {
        if (std.mem.indexOf(u8, acc, "text/event-stream") != null)
            return tail_fanout.startStream(app, res, sp.id, sp.run_dir);
    }
    res.status = 201;
    try res.json(.{
        .ok = true,
        .id = sp.id,
        .state = sp.state,
        .minds = sp.minds,
        .stream_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/stream", .{sp.id}),
        .events_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/events", .{sp.id}),
        .files_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/files", .{sp.id}),
        .bundle_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/bundle", .{sp.id}),
        .archive_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/archive", .{sp.id}),
        .control_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/control", .{sp.id}),
    }, .{});
}

/// CAST — the hive as a sub-agent, over HTTP. One small body casts a bounded swarm at a goal and returns
/// the run id at once; the caller (veil-desk chat, another AI, a script) then watches events/control like
/// any swarm. This is the server-side twin of the CLI's `veil cast`: the SERVER owns the cast defaults
/// (short time budget, 3 minds, full-autonomy research/build dials) so every client casts the same way.
const CastReq = struct {
    goal: []const u8 = "",
    minutes: u32 = 8, // a cast is time-budgeted by default, not until-stopped
    minds: u32 = 3,
    provider: []const u8 = "",
    model: []const u8 = "",
    api_key: []const u8 = "",
    base_url: []const u8 = "",
    gateway_model: []const u8 = "",
    style: []const u8 = "auto",
    name: []const u8 = "",
    mode: []const u8 = "", // "" / "cast" = fast one-shot strike; "continuous" = a sustained long-term hivemind
    dir: []const u8 = "", // chat conversation id → build IN that chat's dir (so the cast + chat share files)
};

/// Sanitize a chat conversation id into ONE safe path segment (alnum / - / _ only, no separators, no "..",
/// bounded). Empty / unsafe → "" and the caller keeps the default throwaway run_dir. Mirrors chat_tools.safeSeg
/// so the cast's `{data}/u{uid}/_chat/builds/{seg}/work` matches the chat build tools' workdir exactly.
fn safeConv(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, raw, " \r\n\t");
    if (t.len == 0 or t.len > 64) return "";
    for (t) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return "";
    }
    return arena.dupe(u8, t) catch "";
}

pub fn cast(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const rq = (try req.json(CastReq)) orelse return badReq(res, "bad body");
    if (std.mem.trim(u8, rq.goal, " \r\n\t").len == 0) return badReq(res, "a goal is required, e.g. {\"goal\":\"research X and report findings\"}");
    const e = ent.entitlements(u.plan, app.auth.isAdmin(u));
    var n: usize = if (rq.minds == 0) 3 else rq.minds;
    if (n > e.per_swarm_minds) n = e.per_swarm_minds;
    if (n == 0) n = 1;
    const names = [_][]const u8{ "nova", "ada", "rex", "lux", "sol" };
    const minds = try res.arena.alloc(MindSpec, n);
    // UNIQUE names past the first 5 (a big cast can line up to 30) — `i % len` would repeat "nova/ada/…" and two
    // minds with the same name collide on their minds/<name> dir + per-mind memory scope.
    for (minds, 0..) |*m, i| {
        const nm = if (i < names.len) names[i] else try std.fmt.allocPrint(res.arena, "mind{d}", .{i + 1});
        m.* = .{ .name = nm, .role = if (i == 0) "Lead" else "Maker", .duty = "build", .lead = i == 0 };
    }
    var sfx: [3]u8 = undefined;
    app.io.random(&sfx);
    const name = if (rq.name.len > 0) rq.name else try std.fmt.allocPrint(res.arena, "cast-{s}", .{std.fmt.bytesToHex(sfx, .lower)});
    const body = DeployReq{
        .name = name,
        .provider = if (rq.provider.len > 0) rq.provider else "workers-ai",
        .model = rq.model,
        .stack = "general",
        // A cast is a FAST scatter-gather, not an 8-minute build loop. mode="cast" -> the engine's cast path:
        // the lead runs planCast once (assigning scouts that SEARCH, builders, QC, etc.), each mind runs ONE
        // bounded moment, then it stops and the caller (the chat collect turn, or the Deploy tab) synthesizes.
        // NOT "oneshot" — oneshot is the 3-turn edit path that skips planning, so a research cast never scouts.
        .style = if (rq.style.len > 0) rq.style else "investigate",
        // The AI can request a SUSTAINED hivemind (continuous mode) for a big multi-step task instead of the fast
        // one-shot strike — the difference is the engine loop keeps working for the whole budget vs stopping after
        // one moment. Everything else about a cast (planCast, roles, autonomy dials) is identical.
        .mode = if (std.mem.eql(u8, rq.mode, "continuous")) "continuous" else "cast",
        .goal = rq.goal,
        .api_key = rq.api_key,
        .base_url = rq.base_url,
        // Quick strike: hard-capped short so it finishes fast. Sustained hivemind: a real budget (default 20,
        // capped at 60) for work that genuinely needs the time.
        .minutes = if (std.mem.eql(u8, rq.mode, "continuous"))
            (if (rq.minutes == 0) 20 else @min(rq.minutes, 60))
        else
            (if (rq.minutes == 0) 4 else @min(rq.minutes, 4)),
        .gateway_model = rq.gateway_model,
        // DeployReq defaults already carry the cast dials: autonomy=full, internet+gap_assess on,
        // breakout/psyche off — the same posture the deploy wizard gives a research/build cast.
        // The cast MARK (both quick and continuous) makes the worker terminate at completed/graduated
        // instead of chaining to a new self-chosen goal — the caller is waiting to collect.
        .cast = true,
        .minds = minds,
    };
    // Build IN the chat's conversation dir when the caller named one, so the hive's `{run_dir}/work` is the SAME
    // folder the chat's own build tools (and the desktop console) use — the cast and the chat co-edit one tree
    // instead of the cast disappearing into a throwaway `{hex}/work`. Blank/unsafe conv → default per-swarm dir.
    const conv = safeConv(res.arena, rq.dir);
    const build_override = if (conv.len > 0)
        try std.fmt.allocPrint(res.arena, "{s}/u{d}/_chat/builds/{s}", .{ app.data, u.id, conv })
    else
        "";
    if (build_override.len > 0) {
        // The chat's build tools create `.../builds/{conv}/work`; the worker will create it too, but make the
        // parent now so the run_dir root (events.jsonl, swarm.json, minds/) has somewhere to land.
        _ = std.Io.Dir.cwd().createDirPathStatus(app.io, build_override, .default_dir) catch {};
    }
    const sp = (try deployCore(app, res, u, body, build_override)) orelse return;
    res.status = 201;
    try res.json(.{
        .ok = true,
        .id = sp.id,
        .state = sp.state,
        .minds = sp.minds,
        .events_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/events", .{sp.id}),
        .control_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/control", .{sp.id}),
        .files_url = try std.fmt.allocPrint(res.arena, "/api/v1/swarms/{s}/files", .{sp.id}),
    }, .{});
}

const ResolveReq = struct { provider: []const u8 = "mock", model: []const u8 = "mock", minds: u32 = 1 };

pub fn resolve(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const body = (try req.json(ResolveReq)) orelse return badReq(res, "bad body");
    const e = ent.entitlements(u.plan, app.auth.isAdmin(u));
    const live = app.sup.liveMindsForUser(u.id);
    const active = app.sup.activeSwarmsForUser(u.id);
    const minds: usize = if (body.minds == 0) 1 else body.minds;
    const keyless = std.mem.eql(u8, body.provider, "mock") or std.mem.eql(u8, body.provider, "ollama") or
        std.mem.eql(u8, body.provider, "workers-ai") or std.mem.eql(u8, body.provider, "cloudflare");
    const has_key = app.vault.has(u.id, body.provider);
    const blocked: ?[]const u8 =
        if (minds > e.per_swarm_minds) "exceeds this plan's minds-per-swarm"
        else if (live + minds > e.max_minds) "would exceed your live-mind limit"
        else if (active >= e.max_swarms) "concurrent-swarm limit reached"
        else null;
    const ns: neurons.Status = if (app.ledger) |l| l.status(u.id, u.plan) else .{ .granted = 0, .used = 0, .balance = 0, .period_start = 0 };
    const out_of_neurons = http.metered(app, u) and ns.balance <= 0;
    try res.json(.{
        .ok = true,
        .allowed = blocked == null and !out_of_neurons,
        .blocked = if (out_of_neurons) "out of neurons — upgrade or add a top-up" else blocked,
        .plan = @tagName(u.plan),
        .per_swarm_minds = e.per_swarm_minds,
        .max_minds = e.max_minds,
        .max_swarms = e.max_swarms,
        .live_minds = live,
        .active_swarms = active,
        .has_key = has_key,
        .needs_key = !keyless and !has_key,
        .workers_ai = e.workers_ai,
        .cloudflare_deploy = e.cloudflare_deploy,
        .metered = http.metered(app, u),
        .neurons_granted = ns.granted,
        .neurons_used = ns.used,
        .neurons_balance = ns.balance,
    }, .{});
}

fn enforceBudget(app: *App) void {
    if (!app.production) return;
    const l = app.ledger orelse return;
    app.sup.meter();
    const uids = app.sup.runningUids(app.gpa);
    defer app.gpa.free(uids);
    for (uids) |uid| {
        const u = app.auth.userById(uid) orelse continue;
        if (app.auth.isAdmin(u)) continue;
        if (l.status(uid, u.plan).balance <= 0) {
            const paused = app.sup.pauseUserSwarms(uid);
            if (paused > 0) std.debug.print("billing: paused {d} swarm(s) for uid {d} — out of neurons\n", .{ paused, uid });
        }
    }
}

pub fn listSwarms(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    // (retention GC now runs on the supervisor's background thread, not on this request path)
    enforceBudget(app);
    const swarms = try app.sup.listForUser(u.id);
    defer app.gpa.free(swarms);
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"swarms\":[");
    for (swarms, 0..) |s, i| {
        if (i > 0) try arr.append(app.gpa, ',');
        const item = try std.fmt.allocPrint(res.arena, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\",\"minds\":{d},\"state\":\"{s}\",\"created\":{d},\"encrypted\":{}}}", .{ s.id, s.name, s.model, s.minds, @tagName(s.state), s.created, s.encrypted });
        try arr.appendSlice(app.gpa, item);
    }
    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

pub fn swarmFile(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    const q = try req.query();
    const rel = q.get("path") orelse return badReq(res, "no path");
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\' or std.mem.indexOf(u8, rel, "..") != null)
        return badReq(res, "bad path");
    const full = try std.fmt.allocPrint(res.arena, "{s}/work/{s}", .{ sw.run_dir, rel });
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, full, res.arena, .limited(2 << 20)) catch return notFound(res);
    res.content_type = .TEXT;
    res.body = data;
}

pub fn swarmFilePut(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    const q = try req.query();
    const rel = q.get("path") orelse return badReq(res, "no path");
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\' or std.mem.indexOf(u8, rel, "..") != null)
        return badReq(res, "bad path");
    const full = try std.fmt.allocPrint(res.arena, "{s}/work/{s}", .{ sw.run_dir, rel });
    if (std.fs.path.dirname(full)) |dir| _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    const body = req.body() orelse "";
    if (body.len > 4 << 20) return capErr(res, "file too large (4MB max)");
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = full, .data = body }) catch return serverErr(res, "could not write file");
    try res.json(.{ .ok = true, .path = rel, .bytes = body.len }, .{});
}

fn fnv1a(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn manifestList(app: *App, arena: std.mem.Allocator, run_dir: []const u8, paths: *std.ArrayListUnmanaged([]const u8), sizes: *std.ArrayListUnmanaged(u64)) void {
    const mpath = std.fmt.allocPrint(arena, "{s}/.build_manifest", .{run_dir}) catch return;
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, mpath, arena, .limited(256 << 10)) catch return;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        const bar = std.mem.indexOfScalar(u8, ln, '|') orelse continue;
        const path = ln[0..bar];
        if (path.len == 0) continue;
        const sz = std.fmt.parseInt(u64, std.mem.trim(u8, ln[bar + 1 ..], " \r\t"), 10) catch 0;
        var found = false;
        for (paths.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) {
            sizes.items[i] = sz;
            found = true;
            break;
        };
        if (!found) {
            paths.append(arena, path) catch {};
            sizes.append(arena, sz) catch {};
        }
    }
}

pub fn swarmFiles(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var sizes: std.ArrayListUnmanaged(u64) = .empty;
    manifestList(app, res.arena, sw.run_dir, &paths, &sizes);
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    try arr.appendSlice(res.arena, "{\"files\":[");
    var total: u64 = 0;
    for (paths.items, 0..) |p, i| {
        if (i > 0) try arr.append(res.arena, ',');
        total += sizes.items[i];
        var hash: u64 = 0;
        if (p.len > 0 and p[0] != '/' and p[0] != '\\' and std.mem.indexOf(u8, p, "..") == null) {
            if (std.fmt.allocPrint(res.arena, "{s}/work/{s}", .{ sw.run_dir, p })) |full| {
                if (std.Io.Dir.cwd().readFileAlloc(app.io, full, res.arena, .limited(2 << 20))) |c| hash = fnv1a(c) else |_| {}
            } else |_| {}
        }
        try arr.appendSlice(res.arena, "{\"path\":");
        try jstr(res.arena, &arr, p);
        try arr.appendSlice(res.arena, try std.fmt.allocPrint(res.arena, ",\"size\":{d},\"hash\":\"{x:0>16}\"}}", .{ sizes.items[i], hash }));
    }
    try arr.appendSlice(res.arena, try std.fmt.allocPrint(res.arena, "],\"n\":{d},\"bytes\":{d},\"state\":\"{s}\"}}", .{ paths.items.len, total, @tagName(sw.state) }));
    res.content_type = .JSON;
    res.body = arr.items;
}

pub fn swarmBundle(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var sizes: std.ArrayListUnmanaged(u64) = .empty;
    manifestList(app, res.arena, sw.run_dir, &paths, &sizes);
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    try arr.appendSlice(res.arena, "{\"files\":[");
    var budget: usize = 8 << 20;
    var n: usize = 0;
    var truncated = false;
    for (paths.items) |p| {
        if (p.len == 0 or p[0] == '/' or p[0] == '\\' or std.mem.indexOf(u8, p, "..") != null) continue;
        const full = std.fmt.allocPrint(res.arena, "{s}/work/{s}", .{ sw.run_dir, p }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(app.io, full, res.arena, .limited(2 << 20)) catch continue;
        if (content.len > budget) {
            truncated = true;
            break;
        }
        budget -= content.len;
        if (n > 0) try arr.append(res.arena, ',');
        try arr.appendSlice(res.arena, "{\"path\":");
        try jstr(res.arena, &arr, p);
        try arr.appendSlice(res.arena, ",\"content\":");
        try jstr(res.arena, &arr, content);
        try arr.append(res.arena, '}');
        n += 1;
    }
    try arr.appendSlice(res.arena, try std.fmt.allocPrint(res.arena, "],\"n\":{d},\"truncated\":{}}}", .{ n, truncated }));
    res.content_type = .JSON;
    res.body = arr.items;
}

fn tarAppend(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), path: []const u8, content: []const u8) void {
    var hdr = [_]u8{0} ** 512;
    if (path.len <= 100) {
        @memcpy(hdr[0..path.len], path);
    } else if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const pfx = path[0..slash];
        const nm = path[slash + 1 ..];
        if (pfx.len <= 155 and nm.len <= 100) {
            @memcpy(hdr[345 .. 345 + pfx.len], pfx);
            @memcpy(hdr[0..nm.len], nm);
        } else {
            const tail = path[path.len - 100 ..];
            @memcpy(hdr[0..100], tail);
        }
    } else {
        @memcpy(hdr[0..100], path[path.len - 100 ..]);
    }
    _ = std.fmt.bufPrint(hdr[100..107], "{o:0>7}", .{@as(u32, 0o644)}) catch {};
    _ = std.fmt.bufPrint(hdr[124..135], "{o:0>11}", .{content.len}) catch {};
    hdr[156] = '0';
    @memcpy(hdr[257..262], "ustar");
    hdr[263] = '0';
    hdr[264] = '0';
    @memset(hdr[148..156], ' ');
    var sum: u32 = 0;
    for (hdr) |b| sum += b;
    _ = std.fmt.bufPrint(hdr[148..154], "{o:0>6}", .{sum}) catch {};
    hdr[154] = 0;
    hdr[155] = ' ';
    out.appendSlice(arena, &hdr) catch {};
    out.appendSlice(arena, content) catch {};
    const rem = content.len % 512;
    if (rem != 0) out.appendNTimes(arena, 0, 512 - rem) catch {};
}

pub fn swarmArchive(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var sizes: std.ArrayListUnmanaged(u64) = .empty;
    manifestList(app, res.arena, sw.run_dir, &paths, &sizes);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (paths.items) |p| {
        if (p.len == 0 or p[0] == '/' or p[0] == '\\' or std.mem.indexOf(u8, p, "..") != null) continue;
        const full = std.fmt.allocPrint(res.arena, "{s}/work/{s}", .{ sw.run_dir, p }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(app.io, full, res.arena, .limited(8 << 20)) catch continue;
        tarAppend(res.arena, &out, p, content);
    }
    try out.appendNTimes(res.arena, 0, 1024);
    res.content_type = .BINARY;
    res.header("content-disposition", try std.fmt.allocPrint(res.arena, "attachment; filename=\"{s}.tar\"", .{id}));
    res.body = out.items;
}

pub fn swarmSite(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const prefix = "/api/v1/swarms/";
    const path = req.url.path;
    if (!std.mem.startsWith(u8, path, prefix)) return badReq(res, "bad path");
    const after = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return badReq(res, "bad path");
    const id = after[0..slash];
    const marker = "/site/";
    const rest = after[slash..];
    if (!std.mem.startsWith(u8, rest, marker)) return badReq(res, "bad path");
    var rel = rest[marker.len..];
    if (rel.len == 0) rel = "index.html";
    if (rel[0] == '/' or rel[0] == '\\' or std.mem.indexOf(u8, rel, "..") != null) return badReq(res, "bad path");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    const full = try std.fmt.allocPrint(res.arena, "{s}/work/{s}", .{ sw.run_dir, rel });
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, full, res.arena, .limited(8 << 20)) catch return notFound(res);
    res.content_type = httpz.ContentType.forExtension(std.fs.path.extension(rel));
    res.header("Cache-Control", "no-store");
    res.body = data;
}

pub fn swarmDeployCf(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const sw = app.sup.get(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    const project = try std.fmt.allocPrint(res.arena, "neuron-{s}", .{id});
    const command = try std.fmt.allocPrint(res.arena, "npx wrangler pages deploy \"{s}/work\" --project-name {s}", .{ sw.run_dir, project });
    try res.json(.{
        .ok = true,
        .plan = @tagName(u.plan),
        .paid = std.mem.eql(u8, @tagName(u.plan), "pro"),
        .project = project,
        .command = command,
        .note = "Paid plan: one click deploys to our Cloudflare account → live URL. Free plan: export the build and run this command with your own Cloudflare account.",
    }, .{});
}

const BillingReq = struct { email: []const u8, plan: []const u8 = "", topup: u64 = 0 };

pub fn adminBilling(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = http.requireAdmin(app, req, res) orelse return;
    const body = (try req.json(BillingReq)) orelse return badReq(res, "bad body");
    const want_plan = body.plan.len > 0;
    const want_topup = body.topup > 0;
    var plan_set = false;
    var topup_applied = false;
    if (want_plan) {
        const plan: ent.Plan = if (std.mem.eql(u8, body.plan, "max")) .max else if (std.mem.eql(u8, body.plan, "pro")) .pro else .free;
        plan_set = app.auth.setPlan(body.email, plan);
    }
    if (want_topup) {
        if (app.auth.idForEmail(body.email)) |uid| {
            if (app.ledger) |l| {
                l.addTopup(uid, body.topup);
                topup_applied = true;
            }
        }
    }
    const ok = (!want_plan or plan_set) and (!want_topup or topup_applied);
    const note: []const u8 = if (want_topup and !topup_applied and app.ledger == null)
        "neuron grants require production mode (NL_PRODUCTION); the ledger is off in beta"
    else if (!ok)
        "no such user"
    else
        "";
    res.status = if (ok) 200 else 409;
    try res.json(.{ .ok = ok, .plan_set = plan_set, .topup_applied = topup_applied, .note = note }, .{});
}

pub fn swarmDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    // resolve(), not get(): the desktop Swarm tab addresses a LIVE cast by its run-dir BASENAME while the
    // registry keys it by the spawn-time hex id — the mismatch 404'd every delete until a server restart
    // re-adopted the dir under its basename. Mutate via the swarm's OWN registry id.
    const sw = app.sup.resolve(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    app.sup.remove(sw.id);
    try res.json(.{ .ok = true, .deleted = true }, .{});
}
