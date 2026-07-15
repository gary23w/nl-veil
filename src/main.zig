//! Entry point + wiring. main() resolves the install paths, brings up Auth + the Supervisor, and starts the HTTP
//! server — or dispatches a CLI verb / the worker entry when invoked as a subcommand.

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");

const NEURON_EXE = if (builtin.os.tag == .windows) "neuron.exe" else "neuron";
const Neuron = @import("worker/neuron/client.zig").Neuron;
const Auth = @import("auth/auth_core.zig").Auth;
const Supervisor = @import("worker/control/supervisor.zig").Supervisor;
const crypto = @import("config/key_vault.zig");
const KeyVault = crypto.KeyVault;
const AuditLog = @import("obs/audit_log.zig").AuditLog;
const LoginGuard = @import("auth/login_guard.zig").LoginGuard;
const http = @import("gateway/http.zig");
const App = http.App;

const auth_api = @import("auth/auth_api.zig");
const deploy_service = @import("worker/deploy/service.zig");
const tail_fanout = @import("worker/control/fanout.zig");
const control_writer = @import("worker/control/writer.zig");
const chat_tools = @import("worker/chat/tools.zig");
const chat_service = @import("worker/chat/service.zig");
const sched = @import("worker/sched.zig");
const admin_service = @import("admin/admin_service.zig");
const billing_seam = @import("plan/billing_seam.zig");
const keys_api = @import("config/keys_api.zig");
const cf_oauth = @import("config/cf_oauth.zig");
const worker = @import("worker/run.zig");
const cli = @import("cli.zig");

pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

const VERSION = "1.0.0";

const ASSET_HTML = @embedFile("index.html");
const ASSET_JS = @embedFile("app.js");
const ASSET_CSS = @embedFile("styles.css");
const ASSET_MODELS = @embedFile("models.json");

const Paths = struct { home: []const u8, data: []const u8, neuron_bin: []const u8 };

fn resolvePaths(gpa: std.mem.Allocator, io: std.Io) !Paths {
    var buf: [4096]u8 = undefined;
    const n = try std.process.executablePath(io, &buf);
    const exe_dir = std.fs.path.dirname(buf[0..n]) orelse ".";
    var home: []const u8 = exe_dir;
    if (std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin")) {
        if (std.fs.path.dirname(exe_dir)) |p1| {
            if (std.mem.eql(u8, std.fs.path.basename(p1), "zig-out"))
                home = std.fs.path.dirname(p1) orelse exe_dir;
        }
    }
    home = try gpa.dupe(u8, home);
    return .{
        .home = home,
        .data = try std.fmt.allocPrint(gpa, "{s}/data", .{home}),
        .neuron_bin = try std.fmt.allocPrint(gpa, "{s}/bin/{s}", .{ home, NEURON_EXE }),
    };
}

fn runQuiet(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
    const r = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(8 << 10), .stderr_limit = .limited(4 << 10) }) catch return;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
}

/// AUTO-CONFIGURE local Ollama for effective agentic use. Two env vars decide whether local casts crawl:
/// OLLAMA_NUM_PARALLEL (unset=1 → the cast's minds + the chat all serialize through ONE runner) and
/// OLLAMA_CONTEXT_LENGTH (unset → gpt-oss loads its full 131072 window, spilling the KV cache to CPU at
/// ~1 tok/s). Ollama reads BOTH only at serve-start, so we persist sane defaults with `setx` and restart the
/// Ollama server (its tray app relaunches it with the fresh env). Runs only when a local Ollama is actually
/// reachable, only touches vars that are unset/too-low, and no-ops thereafter. Opt out: NL_NO_OLLAMA_TUNE=1.
fn tuneOllama(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) void {
    if (builtin.os.tag != .windows) return; // setx/taskkill path is Windows-specific for now
    if (environ.get("NL_NO_OLLAMA_TUNE")) |v| if (v.len > 0) return;
    // only act if a local Ollama is actually up (in-process probe — no curl child at startup)
    {
        const httpc = @import("worker/httpc.zig");
        switch (httpc.request(io, gpa, .{ .method = "GET", .port = 11434, .path = "/api/version", .timeout_s = 3, .cap = 4 << 10 })) {
            .ok => |resp| {
                const up = resp.status == 200 and resp.body.len >= 2;
                if (resp.body.len > 0) gpa.free(resp.body);
                if (!up) return;
            },
            else => return,
        }
    }
    const cur_par = std.mem.trim(u8, environ.get("OLLAMA_NUM_PARALLEL") orelse "", " \r\n\t");
    const cur_ctx = std.mem.trim(u8, environ.get("OLLAMA_CONTEXT_LENGTH") orelse "", " \r\n\t");
    const par_ok = (std.fmt.parseInt(u32, cur_par, 10) catch 0) >= 2;
    const ctx_ok = cur_ctx.len > 0; // any explicit context = the user's choice, leave it
    if (par_ok and ctx_ok) return; // already tuned — nothing to do
    // Persist sane defaults for the NEXT Ollama start. We deliberately DO NOT kill a running Ollama here — a
    // bare `ollama serve` has no tray to relaunch it, so killing it would leave the machine with no model. The
    // vars apply on Ollama's next start (reboot / tray restart / manual `ollama serve`); print the one-liner so
    // the user can apply them now if they want the speedup this session.
    // 2, not 4: on a single box a 20b model at 4 parallel slots (3 cast minds + a chat turn) saturates the
    // CPU/RAM until the HTTP server starves. 2 keeps some concurrency for steering without oversubscribing.
    if (!par_ok) runQuiet(gpa, io, &.{ "setx", "OLLAMA_NUM_PARALLEL", "2" });
    if (!ctx_ok) runQuiet(gpa, io, &.{ "setx", "OLLAMA_CONTEXT_LENGTH", "8192" });
    std.debug.print("nl-veil: persisted Ollama tuning (OLLAMA_NUM_PARALLEL=2, OLLAMA_CONTEXT_LENGTH=8192). Restart Ollama to apply now — casts will run parallel + fast instead of serializing on the CPU.\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var desktop_mode = false;
    // A real threaded io instead of the default init.io. httpz runs a pool of ~32 worker threads that
    // correctly BLOCK on a condition variable when there is no work — but the default init.io busy-SPINS
    // those blocking waits on Windows, pinning ~10 CPU cores with the server completely idle (0 swarms, no
    // requests) and cooking the machine. std.Io.Threaded (exactly what the desktop already uses, and which
    // sits at ~0% idle) sleeps its waits on OS primitives. MUST carry the process environ or Winsock +
    // subprocess spawns break on Windows (the empty-environ gotcha) — the server spawns workers/neuron/curl.
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Collect the subcommand + its remaining argv up front. `worker` short-circuits to the worker entry (that
    // is how the supervisor spawns a mind); a recognized CLI verb (cli.isCommand) runs the command-line client
    // and returns; `--desk` arms desktop hosting; anything else falls through to booting the server daemon.
    var cli_sub: []const u8 = "";
    var cli_args: std.ArrayListUnmanaged([]const u8) = .empty;
    if (std.process.Args.Iterator.initAllocator(init.minimal.args, gpa)) |it_const| {
        var it = it_const;
        defer it.deinit();
        _ = it.skip();
        if (it.next()) |sub| {
            if (std.mem.eql(u8, sub, "worker")) {
                const run_dir = try gpa.dupe(u8, it.next() orelse "");
                const nbin = try gpa.dupe(u8, it.next() orelse "");
                const model = try gpa.dupe(u8, it.next() orelse "mock");
                return worker.run(gpa, io, init.environ_map, run_dir, nbin, model);
            }
            cli_sub = try gpa.dupe(u8, sub);
            if (std.mem.eql(u8, sub, "--desk")) desktop_mode = true;
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--desk")) desktop_mode = true;
                cli_args.append(gpa, try gpa.dupe(u8, arg)) catch {};
            }
        }
    } else |_| {}

    var paths = try resolvePaths(gpa, io);
    if (init.environ_map.get("NEURON_LOOPS_DATA")) |d| {
        if (d.len > 0) paths.data = try gpa.dupe(u8, d);
    }
    _ = std.Io.Dir.cwd().createDirPathStatus(io, paths.data, .default_dir) catch {};

    // The one place the port is resolved (CLI client + server bind share it): NL_PORT else 8787.
    const cli_port: u16 = if (init.environ_map.get("NL_PORT")) |v|
        (std.fmt.parseInt(u16, std.mem.trim(u8, v, " \r\n\t"), 10) catch 8787)
    else
        8787;

    // CLI CLIENT: a recognized verb dispatches to the command-line client (a thin /api/v1/* caller) and exits.
    // This is the surface that retires the Python launcher — the server is the daemon, the CLI is its client.
    if (cli_sub.len > 0 and cli.isCommand(cli_sub)) {
        var cctx = cli.Ctx{ .gpa = gpa, .io = io, .data = paths.data, .home = paths.home, .port = cli_port, .environ = init.environ_map };
        return std.process.exit(cli.dispatch(&cctx, cli_sub, cli_args.items));
    }

    // Make local Ollama parallel + right-sized on launch (crucial for cast/chat steering; see tuneOllama).
    tuneOllama(gpa, io, init.environ_map);

    const auth_db = try std.fmt.allocPrint(gpa, "{s}/auth.sqlite", .{paths.data});
    const nb = Neuron.init(gpa, io, paths.neuron_bin, auth_db);
    var auth = Auth.init(gpa, nb);
    var ledger = @import("plan/neurons.zig").NeuronLedger.init(gpa, nb);
    var api_keys = @import("auth/api_keys.zig").ApiKeys.init(gpa, nb);
    api_keys.warm() catch |e| std.debug.print("api_keys warm: {t}\n", .{e});
    auth.setAdminEmail(init.environ_map.get("NL_ADMIN_EMAIL"));
    auth.warm() catch |e| std.debug.print("warm: {t}\n", .{e});
    const bind_all = if (init.environ_map.get("NL_BIND")) |v| v.len > 0 and !std.mem.eql(u8, v, "127.0.0.1") else false;
    var apw_buf: [48]u8 = undefined;
    const admin_pw: ?[]const u8 = init.environ_map.get("NL_ADMIN_PASSWORD") orelse blk: {
        if (!bind_all) break :blk null;
        var raw: [24]u8 = undefined;
        io.random(&raw);
        const hx = std.fmt.bytesToHex(raw, .lower);
        @memcpy(apw_buf[0..hx.len], &hx);
        std.debug.print("\n*** NL_ADMIN_PASSWORD unset on a public bind — generated admin password: {s}\n*** SAVE THIS NOW (shown once); set NL_ADMIN_PASSWORD to pin a stable one. ***\n\n", .{apw_buf[0..hx.len]});
        break :blk apw_buf[0..hx.len];
    };
    auth.seedDefaultAdmin(admin_pw);
    var sup = Supervisor.init(gpa, io, paths.neuron_bin);
    sup.server_key = crypto.deriveServerKey(gpa, io, init.environ_map, paths.data);
    sup.parent_env = init.environ_map;
    sup.ledger = &ledger;
    const readopted = sup.reattach(paths.data);
    const retention_days: u32 = if (init.environ_map.get("NL_RETENTION_DAYS")) |v| (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10) catch 14) else 14;
    if (retention_days > 0) {
        const swept = sup.pruneOldRuns(paths.data, retention_days);
        if (swept > 0) std.debug.print("retention: pruned {d} stale run dir(s) at startup (>= {d}d inactive)\n", .{ swept, retention_days });
    }
    // Swarm reconcile + retention GC run on a BACKGROUND thread, never on an httpz request thread — reconcile
    // can spawn a worker subprocess (respawn) which, inline in a /fleet or list handler, starves the pool and
    // wedges the server. Handlers now only read the in-memory roster.
    sup.gc_data_dir = paths.data;
    sup.gc_days = retention_days;
    if (std.Thread.spawn(.{}, Supervisor.bgLoop, .{&sup})) |t| t.detach() else |_| {}
    var audit = AuditLog.init(gpa, io, paths.data);
    var login_guard = LoginGuard.init(gpa, io);
    var vault = KeyVault.init(gpa, io, nb, sup.server_key);

    const open_reg = if (init.environ_map.get("NL_OPEN_REGISTRATION")) |v|
        (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "on"))
    else
        false;
    const cf_account = init.environ_map.get("NL_CF_ACCOUNT_ID") orelse "";
    const wai_token = init.environ_map.get("NL_WORKERS_AI_TOKEN") orelse "";
    const production = if (init.environ_map.get("NL_PRODUCTION")) |v|
        (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "on"))
    else
        false;
    // Cloudflare OAuth (self-managed public client): env-overridable so a deployment bakes only its public
    // client_id. The redirect defaults to this server's loopback callback on the resolved port.
    const cf_oauth_redirect = init.environ_map.get("NL_CF_OAUTH_REDIRECT") orelse
        (std.fmt.allocPrint(gpa, "http://localhost:{d}/api/v1/oauth/cloudflare/callback", .{cli_port}) catch "http://localhost:8787/api/v1/oauth/cloudflare/callback");
    var app = App{ .gpa = gpa, .io = io, .auth = &auth, .sup = &sup, .audit = &audit, .login_guard = &login_guard, .vault = &vault, .data = paths.data, .server_key = sup.server_key, .open_registration = open_reg, .cf_account_id = cf_account, .workers_ai_token = wai_token, .retention_days = retention_days, .production = production, .ledger = &ledger, .keys = &api_keys, .cf_oauth_client_id = init.environ_map.get("NL_CF_OAUTH_CLIENT_ID") orelse cf_oauth.DEFAULT_CLIENT_ID, .cf_oauth_scopes = init.environ_map.get("NL_CF_OAUTH_SCOPES") orelse "account:read ai:write offline_access", .cf_oauth_redirect = cf_oauth_redirect, .cf_oauth_auth_url = init.environ_map.get("NL_CF_OAUTH_AUTH_URL") orelse "https://dash.cloudflare.com/oauth2/auth", .cf_oauth_token_url = init.environ_map.get("NL_CF_OAUTH_TOKEN_URL") orelse "https://dash.cloudflare.com/oauth2/token", .cf_oauth_accounts_url = init.environ_map.get("NL_CF_OAUTH_ACCOUNTS_URL") orelse "https://api.cloudflare.com/client/v4/accounts" };
    // SCHEDULED TASKS run on their own background thread (the second one beside Supervisor.bgLoop, same ~5s
    // cadence): a due task spawns a full chat turn, which must never ride an httpz request thread. Spawned here
    // — not next to the sup.bgLoop spawn above — because it needs the fully-wired App; like sup, `app` lives on
    // main's stack for the life of the process (listen() below never returns in normal operation).
    if (std.Thread.spawn(.{}, sched.bgLoop, .{&app})) |t| t.detach() else |_| {}
    std.debug.print("billing: {s} (NL_PRODUCTION)\n", .{if (production) "PRODUCTION — non-admins metered by neuron plan" else "BETA — unmetered full use"});
    if (!open_reg) std.debug.print("registration: CLOSED (private beta) — set NL_OPEN_REGISTRATION=1 to open public signups\n", .{});
    if (cf_account.len > 0 and wai_token.len > 0) std.debug.print("Workers AI: ENABLED (backbone) — provider \"workers-ai\" runs on the Cloudflare account's inference endpoint\n", .{}) else std.debug.print("Workers AI: not configured (set NL_CF_ACCOUNT_ID + NL_WORKERS_AI_TOKEN to enable the backbone)\n", .{});

    const port = cli_port; // resolved once above (NL_PORT else 8787), shared with the CLI client
    // On Windows httpz runs the BLOCKING thread-per-connection worker (one pool thread per live socket),
    // and its ONLY idle/half-open reaping is SO_RCVTIMEO — which is never set unless we pass timeouts here.
    // Without these, a keep-alive connection that dies without a clean FIN (laptop sleep, tab crash, network
    // blip) strands its pool thread forever; enough of them starve the 32-thread pool and fresh casts fail
    // with curl status 000. keepalive=60 reaps idle sockets; request=15 caps slow/half-sent requests;
    // request_count recycles a connection after N requests so no single socket lives unboundedly.
    var server = try httpz.Server(*App).init(io, gpa, .{
        .address = if (bind_all) .all(port) else .localhost(port),
        // request_count = 1: close the connection after every response (the Connection: close path). This
        // stops a half-closed keepalive socket from lingering in httpz's blocking worker, where recv()==0 on a
        // FIN'd peer returns "not done, no error" forever and pins a pool thread at 100% CPU. Every client here
        // is localhost (desktop netcli already sends Connection: close; the web UI reconnects), so the extra
        // handshake per request is free.
        .timeout = .{ .request = 15, .keepalive = 60, .request_count = 1 },
        // httpz here runs the BLOCKING worker model (thread-per-request); a cast/deploy handler holds its pool
        // thread for the whole synchronous spawn. The 32-thread default starves under a burst of concurrent
        // casts (each also leaving a live worker behind) — new casts then hang + return curl 000. Give admission
        // real headroom so a handful of slow spawns can't wedge the pool. (The worker-CPU amplifier is bounded
        // separately by the live-swarm cap in deployCore + the worker's unreachable-LLM backoff.)
        .thread_pool = .{ .count = 128 },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }
    var router = try server.router(.{});
    router.get("/", staticIndex, .{});
    router.get("/app.js", staticJs, .{});
    router.get("/styles.css", staticCss, .{});
    router.get("/models.json", staticModels, .{});
    router.get("/api/v1/health", health, .{});
    router.get("/api/v1/fleet", fleet, .{});
    router.post("/api/v1/auth/register", auth_api.register, .{});
    router.post("/api/v1/auth/login", auth_api.login, .{});
    router.post("/api/v1/auth/logout", auth_api.logout, .{});
    router.get("/api/v1/auth/me", auth_api.me, .{});
    router.post("/api/v1/apikeys", auth_api.keyCreate, .{});
    router.get("/api/v1/apikeys", auth_api.keyList, .{});
    router.delete("/api/v1/apikeys/:id", auth_api.keyRevoke, .{});
    router.post("/api/v1/run", deploy_service.run, .{});
    router.post("/api/v1/cast", deploy_service.cast, .{});
    router.post("/api/v1/swarms", deploy_service.deploy, .{});
    router.post("/api/v1/swarms/resolve", deploy_service.resolve, .{});
    router.get("/api/v1/swarms", deploy_service.listSwarms, .{});
    router.post("/api/v1/keys", keys_api.putKey, .{});
    router.get("/api/v1/keys", keys_api.listKeys, .{});
    router.delete("/api/v1/keys/:provider", keys_api.delKey, .{});
    router.post("/api/v1/oauth/cloudflare/start", cf_oauth.start, .{});
    router.get("/api/v1/oauth/cloudflare/callback", cf_oauth.callback, .{});
    router.get("/api/v1/oauth/cloudflare/status", cf_oauth.status, .{});
    router.get("/api/v1/oauth/cloudflare/models", cf_oauth.models, .{});
    router.post("/api/v1/oauth/cloudflare/logout", cf_oauth.logout, .{});
    router.get("/api/v1/swarms/:id/events", tail_fanout.swarmEvents, .{});
    router.get("/api/v1/swarms/:id/stream", tail_fanout.swarmStream, .{});
    router.get("/api/v1/swarms/:id/files", deploy_service.swarmFiles, .{});
    router.get("/api/v1/swarms/:id/bundle", deploy_service.swarmBundle, .{});
    router.get("/api/v1/swarms/:id/archive", deploy_service.swarmArchive, .{});
    router.get("/api/v1/swarms/:id/file", deploy_service.swarmFile, .{});
    router.put("/api/v1/swarms/:id/file", deploy_service.swarmFilePut, .{});
    router.get("/api/v1/swarms/:id/site/*", deploy_service.swarmSite, .{});
    router.post("/api/v1/swarms/:id/deploy/cloudflare", deploy_service.swarmDeployCf, .{});
    router.post("/api/v1/swarms/:id/control", control_writer.swarmControl, .{});
    router.post("/api/v1/chat/tool", chat_tools.chatTool, .{});
    router.get("/api/v1/chat/convs", chat_service.listConvs, .{});
    router.get("/api/v1/chat/convs/:id", chat_service.getConv, .{});
    router.delete("/api/v1/chat/convs/:id", chat_service.deleteConv, .{});
    router.get("/api/v1/chat/convs/:id/events", chat_service.convEvents, .{});
    router.post("/api/v1/chat/convs/:id/messages", chat_service.postMessage, .{});
    router.post("/api/v1/chat/convs/:id/control", chat_service.chatControl, .{});
    router.get("/api/v1/sched", sched.listTasks, .{});
    router.post("/api/v1/sched", sched.createTask, .{});
    router.post("/api/v1/sched/:id", sched.updateTask, .{});
    router.delete("/api/v1/sched/:id", sched.deleteTask, .{});
    router.post("/api/v1/sched/:id/run", sched.runTaskNow, .{});
    router.delete("/api/v1/swarms/:id", deploy_service.swarmDelete, .{});
    router.post("/api/v1/billing/checkout", billing_seam.billingCheckout, .{});
    router.get("/api/v1/admin/users", admin_service.adminUsers, .{});
    router.post("/api/v1/admin/billing", deploy_service.adminBilling, .{});
    router.post("/api/v1/admin/users/moderate", admin_service.adminModerate, .{});
    router.get("/api/v1/admin/swarms", admin_service.adminSwarms, .{});
    router.delete("/api/v1/admin/swarms/:id", admin_service.adminKill, .{});
    router.get("/api/v1/admin/audit", admin_service.adminAudit, .{});

    std.debug.print("neuron-loops {s} on http://127.0.0.1:{d}  home={s}  ({d} users, {d} swarms re-adopted)\n", .{ VERSION, port, paths.home, auth.userCount(), readopted });
    // On a local bind, mint an admin API key and drop it where the desktop reads it, so veil-desk connects
    // and can deploy WITHOUT the user pasting a key. Localhost-only (never on a public bind).
    if (!bind_all) preloadDesktopKey(gpa, io, &auth, &api_keys, init.environ_map, paths.data);
    if (desktop_mode) launchDesktop(gpa, io, paths.home, init.environ_map);
    try server.listen();
}

const DEFAULT_ADMIN_EMAIL = "admin@neuron-loops.local";

/// Ensure a valid admin API key sits at <data>/.desktop_key so the desktop auto-connects. Reuses the
/// existing key if it still verifies; otherwise logs in as the admin, mints one, and writes it. Best-effort.
fn preloadDesktopKey(gpa: std.mem.Allocator, io: std.Io, auth: *Auth, keys: *@import("auth/api_keys.zig").ApiKeys, environ: *std.process.Environ.Map, data: []const u8) void {
    // Written on any localhost bind (harmless, same-user) so the desktop connects whether it's auto-hosted
    // or the user launches it later — NOT gated on NL_NO_DESKTOP.
    const path = std.fmt.allocPrint(gpa, "{s}/.desktop_key", .{data}) catch return;
    defer gpa.free(path);
    // reuse an existing valid key
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256))) |old| {
        defer gpa.free(old);
        if (keys.verify(std.mem.trim(u8, old, " \r\n\t")) != null) return;
    } else |_| {}
    const email = environ.get("NL_ADMIN_EMAIL") orelse DEFAULT_ADMIN_EMAIL;
    const pw = environ.get("NL_ADMIN_PASSWORD") orelse "changeme";
    const tok = auth.login(email, pw) catch return;
    defer gpa.free(tok);
    const u = auth.whoami(tok) orelse return;
    const key = keys.create(u.id, "veil-desk") catch return;
    defer gpa.free(key);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = key }) catch return;
    std.debug.print("veil-desk: preloaded an admin API key at <data>/.desktop_key (localhost)\n", .{});
}

const DESK_EXE = if (builtin.os.tag == .windows) "veil-desk.exe" else "veil-desk";

/// "Host the desktop": when desktop mode is requested (`--desktop`), launch the veil-desk dashboard if it
/// was built (desk/zig-out/bin/veil-desk) so it sits in the tray and lights up on the server. Detached
/// and best-effort — a headless box either has no binary (built with -Ddesk=false) or no display, and
/// the spawn simply fails without touching the server. Opt out with NL_NO_DESKTOP=1.
fn launchDesktop(gpa: std.mem.Allocator, io: std.Io, home: []const u8, environ: *std.process.Environ.Map) void {
    if (environ.get("NL_NO_DESKTOP")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) return;
    }
    // Two layouts host the desktop: a release BUNDLE puts veil-desk right next to the server, and a
    // dev CHECKOUT builds it under desk/zig-out/bin. Try the bundle path first, then the checkout path.
    const bundle = std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, DESK_EXE }) catch return;
    defer gpa.free(bundle);
    const checkout = std.fmt.allocPrint(gpa, "{s}/desk/zig-out/bin/{s}", .{ home, DESK_EXE }) catch return;
    defer gpa.free(checkout);
    const bin = if (std.Io.Dir.cwd().access(io, bundle, .{})) |_|
        bundle
    else |_| if (std.Io.Dir.cwd().access(io, checkout, .{})) |_|
        checkout
    else |_|
        return; // not built in either layout → nothing to host
    // Spawn and forget — it's an independent same-machine companion, not a child we manage.
    _ = std.process.spawn(io, .{ .argv = &.{bin}, .cwd = .{ .path = home }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    std.debug.print("veil-desk: launched the desktop dashboard (set NL_NO_DESKTOP=1 to disable)\n", .{});
}

fn health(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .ok = true, .service = "veil", .version = VERSION }, .{});
}

const INSTANCE_MIND_CAP = 25;

fn fleet(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const l = app.sup.load();
    const headroom = if (l.live_minds < INSTANCE_MIND_CAP) INSTANCE_MIND_CAP - l.live_minds else 0;
    try res.json(.{
        .ok = true,
        .version = VERSION,
        .swarms = l.swarms,
        .live_swarms = l.live_swarms,
        .live_minds = l.live_minds,
        .mind_capacity = INSTANCE_MIND_CAP,
        .headroom = headroom,
        .saturated = headroom == 0,
    }, .{});
}

fn staticIndex(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.header("Cache-Control", "no-cache, must-revalidate");
    res.body = ASSET_HTML;
}
fn staticJs(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JS;
    res.header("Cache-Control", "no-cache, must-revalidate");
    res.body = ASSET_JS;
}
fn staticCss(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.header("Cache-Control", "no-cache, must-revalidate");
    res.body = ASSET_CSS;
}
fn staticModels(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body = ASSET_MODELS;
}
