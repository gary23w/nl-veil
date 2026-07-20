//! Deploy + swarm-lifecycle HTTP handlers — the validate → run_dir + swarm.json → spawn pipeline, plus cast/run and the file/bundle/archive endpoints.

const std = @import("std");
const httpz = @import("httpz");

const log = std.log.scoped(.billing);
const http = @import("../../gateway/http.zig");
const ent = @import("../../plan/entitlements.zig");
const neurons = @import("../../plan/neurons.zig");
const crypto = @import("../../config/key_vault.zig");
const cf_oauth = @import("../../config/cf_oauth.zig");
const modelcfg = @import("modelcfg"); // a MODULE (src/worker/modelcfg.zig) — shared with the compiled-in desk
const tail_fanout = @import("../control/fanout.zig");
const cpaths = @import("../chat/paths.zig"); // conv → build-tree mapping (scheduled runs → _sched/{task}/runs/)
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
    // NEWS DESK — when true the swarm runs in discourse mode and composes a grounded, screened briefing each
    // round; `post` (default on) additionally publishes it to a public Telegraph page.
    publish: bool = false,
    post: bool = true,
    // CAST marker — set by the /cast path (quick strike AND sustained "continuous" casts) so the worker
    // terminates at completed/graduated instead of evolveGoal-chaining to a new self-chosen goal. A plain
    // /deploy or /run swarm leaves it false and keeps the full autonomy chain.
    cast: bool = false,
    // DECLARED DELIVERABLES — the caller (the chat's veil composing a cast) names the exact output files;
    // the worker adopts them verbatim as the blueprint instead of guessing from goal prose. Comma or
    // newline separated. The MODEL reasons about what the deliverables are; the engine just carries them.
    files: []const u8 = "",
    minds: []MindSpec,
};

const Spawned = struct { id: []const u8, state: []const u8, minds: usize, run_dir: []const u8 };

/// Response-decoupled result of a deploy/cast so the same validate→manifest→spawn core serves BOTH the HTTP
/// handlers (which translate a `.fail` through badReq/capErr/serverErr) and the in-process server chat turn
/// (the veil casting its own swarm). `msg` lives in the arena the caller passed.
pub const FailKind = enum { bad_request, capped, server_error };
pub const DeployOutcome = union(enum) {
    ok: Spawned,
    fail: struct { kind: FailKind, msg: []const u8 },
};
fn failBad(msg: []const u8) DeployOutcome {
    return .{ .fail = .{ .kind = .bad_request, .msg = msg } };
}
fn failCap(msg: []const u8) DeployOutcome {
    return .{ .fail = .{ .kind = .capped, .msg = msg } };
}
fn failSrv(msg: []const u8) DeployOutcome {
    return .{ .fail = .{ .kind = .server_error, .msg = msg } };
}
/// Send a `.fail` outcome through the matching HTTP helper (bad_request→400, capped→429, server_error→500).
fn sendFail(res: *httpz.Response, f: anytype) !void {
    switch (f.kind) {
        .bad_request => try badReq(res, f.msg),
        .capped => try capErr(res, f.msg),
        .server_error => try serverErr(res, f.msg),
    }
}

pub fn deploy(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const body = (try req.json(DeployReq)) orelse return badReq(res, "bad body");
    // A raw /deploy request never picks its own run_dir — that would be a path-traversal hole. Only the cast
    // path (below) supplies a server-sanitized build dir so a chat cast lands in the chat's conversation folder.
    switch (deploySwarm(app, res.arena, u, body, "")) {
        .ok => |sp| {
            res.status = 201;
            try res.json(.{ .ok = true, .id = sp.id, .state = sp.state, .minds = sp.minds }, .{});
        },
        .fail => |f| try sendFail(res, f),
    }
}

/// `run_dir_override`, when non-empty, replaces the default `{data}/u{uid}/{id}` run_dir. The swarm id stays a
/// fresh random hex (URLs + supervisor tracking key off it), but the on-disk run_dir — and therefore the
/// worker's `{run_dir}/work` build dir — is redirected to a caller-chosen, already-sanitized absolute path.
/// This is how a chat cast builds IN the chat's conversation dir instead of its own throwaway folder.
/// Response-decoupled deploy core: validate → run_dir + swarm.json → spawn. Returns a DeployOutcome the caller
/// renders (HTTP handlers via sendFail; the chat turn reads .ok/.fail directly). All
/// short-lived allocations use `arena` (HTTP passes res.arena; the chat turn passes a per-cast ArenaAllocator).
pub fn deploySwarm(app: *App, arena: std.mem.Allocator, u: http.User, body: DeployReq, run_dir_override: []const u8) DeployOutcome {
    const e = ent.entitlements(u.plan, app.auth.isAdmin(u));
    if (body.minds.len == 0) return failBad("a swarm needs at least 1 mind");
    if (body.minds.len > e.per_swarm_minds)
        return failCap(std.fmt.allocPrint(arena, "a single swarm is capped at {d} minds on your plan", .{e.per_swarm_minds}) catch "minds cap exceeded");
    if (body.encrypt and !e.encrypted) return failCap("encrypted minds are an admin feature");
    if (app.sup.liveMindsForUser(u.id) + body.minds.len > e.max_minds)
        return failCap("that would exceed your plan's live-mind limit — stop a swarm or upgrade to Pro");
    if (app.sup.activeSwarmsForUser(u.id) >= e.max_swarms)
        return failCap("your plan's concurrent-swarm limit is reached — stop one or upgrade to Pro");
    if (http.metered(app, u)) {
        if (app.ledger) |l| if (!l.hasBalance(u.id, u.plan))
            return failCap("you're out of neurons for this billing period — upgrade your plan or add a top-up to run more swarms");
    }
    // A cast targets a LOCAL model when the provider is ollama OR the base_url names a loopback host. This set
    // MUST match the worker's isLocal() (src/worker/llm.zig): a host the worker treats as local but the gate
    // misses is a privilege gap — a non-admin reaching the host's loopback. 0.0.0.0 and [::1] were the gap.
    const local_model = std.mem.eql(u8, body.provider, "ollama") or
        std.mem.indexOf(u8, body.base_url, "localhost") != null or
        std.mem.indexOf(u8, body.base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, body.base_url, "0.0.0.0") != null or
        std.mem.indexOf(u8, body.base_url, "[::1]") != null;
    if (local_model and !app.auth.isAdmin(u))
        return failCap("local models (Ollama) are admin-only and don't run in the hosted environment — choose Cloudflare Workers AI or bring your own API key");

    var rnd: [8]u8 = undefined;
    app.io.random(&rnd);
    const id = std.fmt.allocPrint(arena, "{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return failSrv("out of memory");
    // run_dir is the override (a chat conversation dir) when the cast asked to build in place, else the default
    // per-swarm folder. Either way `{run_dir}/work` is the deliverable dir the worker uses — the worker needs no
    // change, it just inherits whichever run_dir we spawn it with.
    const run_dir = (if (run_dir_override.len > 0)
        arena.dupe(u8, run_dir_override)
    else
        std.fmt.allocPrint(arena, "{s}/u{d}/{s}", .{ app.data, u.id, id })) catch return failSrv("out of memory");
    const workdir = std.fmt.allocPrint(arena, "{s}/work", .{run_dir}) catch return failSrv("out of memory");

    // RE-CAST HYGIENE: a cast into a chat conversation dir REUSES the previous cast's run_dir
    // (`_chat/builds/{conv}`), so its lifecycle files are still on disk. A leftover STOP would stop the new
    // worker at its first boundary check, a leftover DONE would read the fresh spawn as already-finished,
    // and the old events.jsonl would splice two runs into one stream. Reset lifecycle metadata ONLY —
    // never work/ or any other user file — BEFORE the manifest write + spawn.
    if (run_dir_override.len > 0) resetCastLifecycle(app, arena, run_dir);

    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, workdir, .default_dir) catch {};
    for (body.minds) |m| {
        const md = std.fmt.allocPrint(arena, "{s}/minds/{s}", .{ run_dir, m.name }) catch return failSrv("out of memory");
        _ = std.Io.Dir.cwd().createDirPathStatus(app.io, md, .default_dir) catch {};
    }

    var eff_key: []const u8 = body.api_key;
    var eff_base: []const u8 = body.base_url;
    var eff_model: []const u8 = body.model;

    // PROVIDER DERIVATION. A cast may name only a model (CLI `veil cast … --model deepseek-v4-flash`) or
    // nothing at all. Without this it defaulted to "workers-ai" and never resolved the caller's stored key —
    // so an explicit --model and the server's own published default were both silently ignored, and every
    // keyless cast dead-ended at "Workers AI needs a Cloudflare login". Resolve in priority order; each rung
    // is a KNOWN fact, never a guess (providerForModel/providerForBase return null rather than mis-attribute):
    //   1. explicit provider — respect it
    //   2. the model's catalog provider — a named model implies its provider
    //   3. the base_url's catalog provider — a known endpoint implies its provider
    //   4. the server's published default model, and its provider + base
    //   5. workers-ai — the keyless server-creds fallback, only when nothing above resolved
    var eff_provider = body.provider;
    if (eff_provider.len == 0) {
        if (modelcfg.providerForModel(body.model)) |pv| {
            eff_provider = pv;
        } else if (modelcfg.providerForBase(body.base_url)) |pv| {
            eff_provider = pv;
        } else {
            const sd = app.cfg.defaults(arena); // .model/.base_url are the CODING-role (default) pair
            if (sd.model.len > 0) if (modelcfg.providerForModel(sd.model)) |pv| {
                eff_provider = pv;
                if (eff_model.len == 0) eff_model = sd.model;
                if (eff_base.len == 0) eff_base = sd.base_url;
            };
        }
        if (eff_provider.len == 0) eff_provider = "workers-ai";
    }

    const wants_cf_ai = std.mem.eql(u8, eff_provider, "workers-ai") or std.mem.eql(u8, eff_provider, "cloudflare");
    // A client can BYO Cloudflare by sending the fully-resolved account URL + its own token. If it doesn't
    // (base is the "cloudflare" sentinel or still carries the "{account}" placeholder), fall back to this
    // server's own configured Workers AI credentials — so a missing account id never yields a broken URL.
    const cf_base_ok = std.mem.startsWith(u8, eff_base, "http") and std.mem.indexOf(u8, eff_base, "{account}") == null;
    if (wants_cf_ai and (eff_key.len == 0 or !cf_base_ok)) {
        if (!e.workers_ai) return failCap("Workers AI is not enabled for your account");
        // Prefer this user's own Cloudflare login (OAuth) — a per-user token + account, auto-refreshed. Falls
        // back to the server-wide NL_CF_* credentials only when the user hasn't logged in.
        if (cf_oauth.resolveToken(app, u.id, arena)) |cf| {
            eff_base = cf.base_url;
            eff_key = cf.key;
        } else if (app.cf_account_id.len == 0 or app.workers_ai_token.len == 0) {
            return failSrv("Workers AI needs a Cloudflare login (Settings → Log in with Cloudflare) or server NL_CF_ACCOUNT_ID + NL_WORKERS_AI_TOKEN");
        } else {
            eff_base = std.fmt.allocPrint(arena, "https://api.cloudflare.com/client/v4/accounts/{s}/ai/v1", .{app.cf_account_id}) catch return failSrv("out of memory");
            eff_key = app.workers_ai_token;
        }
        if (eff_model.len == 0 or !std.mem.startsWith(u8, eff_model, "@cf/")) eff_model = modelcfg.defaults.cf_model;
    } else if (eff_key.len == 0) {
        // Resolve a stored BYOK key. Safe when the caller gave NO endpoint (pick-a-provider flow) OR when the
        // endpoint they gave is one this catalog RECOGNISES — providerForBase only matches a known host, so a
        // custom/unknown endpoint still resolves to null and is never handed another provider's key. This is
        // what makes `--base-url https://api.deepseek.com/v1` (no key) work: the base identifies the provider,
        // and the sealed deepseek key is pulled for it. The old guard required a blank base and so silently
        // dropped the key whenever a base was supplied.
        const known_base = eff_base.len == 0 or modelcfg.providerForBase(eff_base) != null;
        if (known_base) if (app.vault.resolve(u.id, eff_provider, arena)) |rk| {
            eff_key = rk.key;
            if (eff_base.len == 0 and rk.base_url.len > 0) eff_base = rk.base_url;
        };
    }
    // A local-provider cast with no explicit base_url must resolve to the local Ollama, NEVER the worker's
    // OpenAI fallback (run.zig defaults an empty base to api.openai.com — and with a server-env OPENAI/ANTHROPIC
    // key the worker inherits, that becomes real egress). The desk always sends a base; a direct /cast API
    // caller may not.
    if (local_model and eff_base.len == 0) eff_base = "http://127.0.0.1:11434/v1";

    const mani_items = buildManifest(arena, body, eff_provider, workdir, eff_base, eff_model, body.encrypt and e.encrypted) catch return failSrv("out of memory");
    const mani_path = std.fmt.allocPrint(arena, "{s}/swarm.json", .{run_dir}) catch return failSrv("out of memory");
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = mani_path, .data = mani_items }) catch return failSrv("could not write manifest");

    if (eff_key.len > 0)
        writeKeysEnv(app, arena, run_dir, eff_key, eff_base, body.encrypt and e.encrypted) catch return failSrv("could not prepare keys");

    const sw = app.sup.spawn(u.id, id, body.name, run_dir, eff_model, body.minds.len) catch return failSrv("could not spawn worker");
    return .{ .ok = .{ .id = sw.id, .state = @tagName(sw.state), .minds = sw.minds, .run_dir = run_dir } };
}

/// Build the swarm.json manifest bytes into `arena` (freed with the arena).
fn buildManifest(arena: std.mem.Allocator, body: DeployReq, eff_provider: []const u8, workdir: []const u8, eff_base: []const u8, eff_model: []const u8, encrypted: bool) ![]u8 {
    var mani: std.ArrayListUnmanaged(u8) = .empty;
    try mani.appendSlice(arena, "{\"swarm\":");
    try jstr(arena, &mani, body.name);
    try mani.appendSlice(arena, ",\"provider\":");
    try jstr(arena, &mani, eff_provider); // the DERIVED provider, so swarm.json records what actually ran
    try mani.appendSlice(arena, ",\"base_url\":");
    try jstr(arena, &mani, eff_base);
    try mani.appendSlice(arena, ",\"model\":");
    try jstr(arena, &mani, eff_model);
    try mani.appendSlice(arena, ",\"style\":");
    try jstr(arena, &mani, body.style);
    try mani.appendSlice(arena, ",\"mode\":");
    try jstr(arena, &mani, body.mode);
    try mani.appendSlice(arena, ",\"stack\":");
    try jstr(arena, &mani, body.stack);
    try mani.appendSlice(arena, ",\"workdir\":");
    try jstr(arena, &mani, workdir);
    try mani.appendSlice(arena, ",\"goal\":");
    try jstr(arena, &mani, body.goal);
    const mline = try std.fmt.allocPrint(arena, ",\"minutes\":{d}", .{body.minutes});
    try mani.appendSlice(arena, mline);
    if (body.gateway_model.len > 0) {
        try mani.appendSlice(arena, ",\"gateway_model\":");
        try jstr(arena, &mani, body.gateway_model);
    }
    if (body.gateway_base_url.len > 0) {
        try mani.appendSlice(arena, ",\"gateway_base_url\":");
        try jstr(arena, &mani, body.gateway_base_url);
    }
    if (body.gateway_key.len > 0) {
        try mani.appendSlice(arena, ",\"gateway_key\":");
        try jstr(arena, &mani, body.gateway_key);
    }
    if (body.veil_population) try mani.appendSlice(arena, ",\"veil_population\":true");
    // RSI dials — write them explicitly so the manifest carries the same knobs the wizard sets (and the
    // desktop Deploy form can toggle). Autonomy is a string; the rest are bools the worker reads verbatim.
    try mani.appendSlice(arena, ",\"autonomy\":");
    try jstr(arena, &mani, if (std.mem.eql(u8, body.autonomy, "bounded")) "bounded" else "full");
    try mani.appendSlice(arena, if (body.internet) ",\"internet\":true" else ",\"internet\":false");
    try mani.appendSlice(arena, if (body.gap_assess) ",\"gap_assess\":true" else ",\"gap_assess\":false");
    if (body.breakout) try mani.appendSlice(arena, ",\"breakout\":true");
    if (body.observe_psyche) try mani.appendSlice(arena, ",\"observe_psyche\":true");
    // NEWS DESK dials — publish gates the discourse/briefing path; post gates the actual Telegraph egress
    // (default on, so "publish without post" is grounded-and-screened-to-disk only). Only emit when publishing.
    if (body.publish) {
        try mani.appendSlice(arena, ",\"publish\":true");
        try mani.appendSlice(arena, if (body.post) ",\"post\":true" else ",\"post\":false");
    }
    // the worker's terminate-don't-chain gate (a sustained cast is mode="continuous", so mode can't carry it)
    if (body.cast) try mani.appendSlice(arena, ",\"cast\":true");
    if (body.files.len > 0) {
        try mani.appendSlice(arena, ",\"files\":");
        try jstr(arena, &mani, body.files);
    }
    if (encrypted) try mani.appendSlice(arena, ",\"encrypted\":true");
    try mani.appendSlice(arena, ",\"minds\":[");
    for (body.minds, 0..) |m, i| {
        if (i > 0) try mani.append(arena, ',');
        try mani.appendSlice(arena, "{\"name\":");
        try jstr(arena, &mani, m.name);
        try mani.appendSlice(arena, ",\"role\":");
        try jstr(arena, &mani, m.role);
        try mani.appendSlice(arena, ",\"duty\":");
        try jstr(arena, &mani, m.duty);
        if (m.lead) try mani.appendSlice(arena, ",\"lead\":true");
        try mani.append(arena, '}');
    }
    try mani.appendSlice(arena, "]}");
    return mani.items;
}

/// Write keys.env (or keys.env.enc when encrypted) for the worker. Only a SEAL failure is fatal (returns an
/// error the caller maps to a failure); a plaintext write error is best-effort silent.
fn writeKeysEnv(app: *App, arena: std.mem.Allocator, run_dir: []const u8, eff_key: []const u8, eff_base: []const u8, encrypted: bool) !void {
    var kbuf: std.ArrayListUnmanaged(u8) = .empty;
    try kbuf.appendSlice(arena, "NL_LLM_KEY=");
    try kbuf.appendSlice(arena, eff_key);
    try kbuf.append(arena, '\n');
    if (eff_base.len > 0) {
        try kbuf.appendSlice(arena, "NL_LLM_BASE_URL=");
        try kbuf.appendSlice(arena, eff_base);
        try kbuf.append(arena, '\n');
    }
    if (encrypted) {
        const sealed = try crypto.seal(app.gpa, app.io, app.server_key, kbuf.items);
        defer app.gpa.free(sealed);
        const kpath = try std.fmt.allocPrint(arena, "{s}/keys.env.enc", .{run_dir});
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = kpath, .data = sealed }) catch {};
    } else {
        const kpath = try std.fmt.allocPrint(arena, "{s}/keys.env", .{run_dir});
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = kpath, .data = kbuf.items }) catch {};
    }
}

/// Reset a reused run dir's LIFECYCLE files before a re-cast spawns into it: drop STOP/DONE/control.jsonl/
/// worker.pid and rotate events.jsonl to events.prev.jsonl (replacing any older rotation, so exactly one
/// previous run stays inspectable). Deliberately narrower than supervisor.cleanCastMeta — that also deletes
/// swarm.json (fine, deploy rewrites it) but ALSO mind.sqlite, the minds/ dirs, and .usage; a re-cast should
/// KEEP the conversation's accumulated hive memory. Never touches work/ or any other user file.
fn resetCastLifecycle(app: *App, arena: std.mem.Allocator, run_dir: []const u8) void {
    const drops = [_][]const u8{ "STOP", "DONE", "control.jsonl", "worker.pid", "asks.jsonl", "veil_answered.jsonl" };
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
    // The gateway is a FULL provider triple, never just a model name: run.zig:749-750 falls gw_base back to
    // the primary base_url when it is blank, so a model-only gateway sends the gateway model's NAME to the
    // PRIMARY provider's endpoint — silently broken for any cross-provider pair. Carry all three or none.
    gateway_model: []const u8 = "",
    gateway_base_url: []const u8 = "",
    gateway_key: []const u8 = "",
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
        .provider = rq.provider, // "" is fine — deploySwarm derives it from the model/base/server-default (was forced to "workers-ai" here, which ignored an explicit --model and the server default)
        .model = rq.model,
        .stack = rq.stack,
        .style = rq.style,
        .mode = rq.mode,
        .goal = rq.goal,
        .api_key = rq.api_key,
        .base_url = rq.base_url,
        .minutes = rq.minutes,
        .gateway_model = rq.gateway_model,
        .gateway_base_url = rq.gateway_base_url,
        .gateway_key = rq.gateway_key,
        .minds = minds,
    };
    const sp = switch (deploySwarm(app, res.arena, u, body, "")) {
        .ok => |s| s,
        .fail => |f| return sendFail(res, f),
    };
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
pub const CastReq = struct {
    goal: []const u8 = "",
    minutes: u32 = 8, // a cast is time-budgeted by default, not until-stopped
    minds: u32 = 3,
    provider: []const u8 = "",
    model: []const u8 = "",
    api_key: []const u8 = "",
    base_url: []const u8 = "",
    // GATEWAY = the cheap/secondary provider the worker routes its MECHANICAL calls through (classify, digest,
    // screen, gap, rerank, retro — see run.zig's gw_base/gw_key/gateway_model call sites). All three fields or
    // none: a model-only gateway inherits the PRIMARY endpoint (run.zig:749-750) and posts the gateway model's
    // name to the wrong provider. This is where the chat turn's `prompting` role lands on a cast.
    gateway_model: []const u8 = "",
    gateway_base_url: []const u8 = "",
    gateway_key: []const u8 = "",
    style: []const u8 = "auto",
    name: []const u8 = "",
    mode: []const u8 = "", // "" / "cast" = fast one-shot strike; "continuous" = a sustained long-term hivemind
    dir: []const u8 = "", // chat conversation id → build IN that chat's dir (so the cast + chat share files)
    files: []const u8 = "", // DECLARED deliverables (comma/newline separated) — adopted verbatim as the blueprint
    publish: bool = false, // NEWS DESK: run as a research/briefing cast that posts a grounded, screened page to Telegraph
    post: bool = true, //     when publishing, actually post to Telegraph (false = grounded-and-screened to disk only)
};

/// Count the entries in a comma/newline-separated declared-deliverables list (the workload-floor input).
fn declCount(files: []const u8) u32 {
    var n: u32 = 0;
    var it = std.mem.tokenizeAny(u8, files, ",\n\r");
    while (it.next()) |t| {
        if (std.mem.trim(u8, t, " \t`'\"").len >= 2) n += 1;
    }
    return n;
}

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
    switch (castSwarm(app, res.arena, u, rq)) {
        .ok => |sp| {
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
        },
        .fail => |f| try sendFail(res, f),
    }
}

/// The server-owned CAST pipeline: server cast defaults, mind naming, the workload-time floor, and the
/// conversation build-dir redirect — then deploySwarm. Response-decoupled so BOTH the HTTP cast route and the
/// in-process server chat turn (the veil casting its own swarm) call it.
pub fn castSwarm(app: *App, arena: std.mem.Allocator, u: http.User, rq: CastReq) DeployOutcome {
    if (std.mem.trim(u8, rq.goal, " \r\n\t").len == 0)
        return failBad("a goal is required, e.g. {\"goal\":\"research X and report findings\"}");
    const e = ent.entitlements(u.plan, app.auth.isAdmin(u));
    var n: usize = if (rq.minds == 0) 3 else rq.minds;
    if (n > e.per_swarm_minds) n = e.per_swarm_minds;
    if (n == 0) n = 1;
    const names = [_][]const u8{ "nova", "ada", "rex", "lux", "sol" };
    const minds = arena.alloc(MindSpec, n) catch return failSrv("out of memory");
    // UNIQUE names past the first 5 (a big cast can line up to 30) — `i % len` would repeat "nova/ada/…" and two
    // minds with the same name collide on their minds/<name> dir + per-mind memory scope.
    for (minds, 0..) |*m, i| {
        const nm = if (i < names.len) names[i] else (std.fmt.allocPrint(arena, "mind{d}", .{i + 1}) catch return failSrv("out of memory"));
        m.* = .{ .name = nm, .role = if (i == 0) "Lead" else "Maker", .duty = "build", .lead = i == 0 };
    }
    var sfx: [3]u8 = undefined;
    app.io.random(&sfx);
    const name = if (rq.name.len > 0) rq.name else (std.fmt.allocPrint(arena, "cast-{s}", .{std.fmt.bytesToHex(sfx, .lower)}) catch return failSrv("out of memory"));
    const body = DeployReq{
        .name = name,
        .provider = rq.provider, // "" is fine — deploySwarm derives it from the model/base/server-default (was forced to "workers-ai" here, which ignored an explicit --model and the server default)
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
        // capped at 60) for work that needs the time. WORKLOAD FLOOR: when the caller DECLARED the deliverables,
        // the time budget must fit the declared workload — a 2-minute strike against 14 declared files can't
        // finish. ~1 minute per 3 deliverables (a round lands ~3 files in ~1 min), floor 2, ceiling 20. The MODEL
        // declares the workload; the engine grants time proportional to it — a capacity fact, not a use-case condition.
        .minutes = blk_min: {
            const declared: u32 = if (rq.files.len > 0) declCount(rq.files) else 0;
            const wfloor: u32 = if (declared > 0) @min(20, @max(2, (declared + 2) / 3)) else 0;
            const base: u32 = if (std.mem.eql(u8, rq.mode, "continuous"))
                (if (rq.minutes == 0) 20 else @min(rq.minutes, 60))
            else
                (if (rq.minutes == 0) 4 else @min(rq.minutes, 4));
            break :blk_min @max(base, wfloor);
        },
        .gateway_model = rq.gateway_model,
        .gateway_base_url = rq.gateway_base_url,
        .gateway_key = rq.gateway_key,
        // DeployReq defaults already carry the cast dials: autonomy=full, internet+gap_assess on,
        // breakout/psyche off — the same posture the deploy wizard gives a research/build cast.
        // The cast MARK (both quick and continuous) makes the worker terminate at completed/graduated
        // instead of chaining to a new self-chosen goal — the caller is waiting to collect.
        .cast = true,
        .files = rq.files,
        // NEWS DESK: a publish cast runs discourse-mode (grounded briefing) and, with post on, posts to Telegraph.
        .publish = rq.publish,
        .post = rq.post,
        .minds = minds,
    };
    // Build IN the chat's conversation dir when the caller named one, so the hive's `{run_dir}/work` is the SAME
    // folder the chat's own build tools (and the desktop console) use — the cast and the chat co-edit one tree
    // instead of the cast disappearing into a throwaway `{hex}/work`. Blank/unsafe conv → default per-swarm dir.
    const conv = safeConv(arena, rq.dir);
    var brb: [256]u8 = undefined;
    const build_override = if (conv.len > 0)
        (std.fmt.allocPrint(arena, "{s}/{s}", .{ app.data, cpaths.buildRootRel(&brb, u.id, conv) }) catch return failSrv("out of memory"))
    else
        "";
    if (build_override.len > 0) {
        // The chat's build tools create `.../builds/{conv}/work`; the worker will create it too, but make the
        // parent now so the run_dir root (events.jsonl, swarm.json, minds/) has somewhere to land.
        _ = std.Io.Dir.cwd().createDirPathStatus(app.io, build_override, .default_dir) catch {};
    }
    return deploySwarm(app, arena, u, body, build_override);
}

const ResolveReq = struct { provider: []const u8 = "mock", model: []const u8 = "mock", minds: u32 = 1 };

pub fn resolve(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const body = (try req.json(ResolveReq)) orelse return badReq(res, "bad body");
    const e = ent.entitlements(u.plan, app.auth.isAdmin(u));
    const live = app.sup.liveMindsForUser(u.id);
    const active = app.sup.activeSwarmsForUser(u.id);
    const minds: usize = if (body.minds == 0) 1 else body.minds;
    // keyless providers come from the catalog (models.yaml keyless:true — mock/ollama/workers-ai); the
    // "cloudflare" sentinel is a server-side alias for workers-ai-with-server-creds, kept explicit.
    const keyless = modelcfg.isKeyless(body.provider) or std.mem.eql(u8, body.provider, "cloudflare");
    const has_key = app.vault.has(u.id, body.provider);
    const blocked: ?[]const u8 =
        if (minds > e.per_swarm_minds) "exceeds this plan's minds-per-swarm" else if (live + minds > e.max_minds) "would exceed your live-mind limit" else if (active >= e.max_swarms) "concurrent-swarm limit reached" else null;
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
            if (paused > 0) log.warn("paused {d} swarm(s) for uid {d} — out of neurons", .{ paused, uid });
        }
    }
}

pub fn listSwarms(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    // retention GC runs on the supervisor's background thread, not on this request path
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
    // registry keys it by the spawn-time hex id — get() would 404 the mismatch. Mutate via the swarm's OWN id.
    const sw = app.sup.resolve(id) orelse return notFound(res);
    if (sw.uid != u.id) return unauth(res);
    app.sup.remove(sw.id);
    try res.json(.{ .ok = true, .deleted = true }, .{});
}
