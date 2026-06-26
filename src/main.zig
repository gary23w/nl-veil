//! Entry point + wiring. main() resolves the install paths, brings up Auth + the Supervisor, builds the

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");

const NEURON_EXE = if (builtin.os.tag == .windows) "neuron.exe" else "neuron";
const Neuron = @import("orchestrate/neuron_client.zig").Neuron;
const Auth = @import("auth/auth_core.zig").Auth;
const Supervisor = @import("orchestrate/supervisor.zig").Supervisor;
const crypto = @import("config/key_vault.zig");
const KeyVault = crypto.KeyVault;
const AuditLog = @import("obs/audit_log.zig").AuditLog;
const LoginGuard = @import("auth/login_guard.zig").LoginGuard;
const http = @import("gateway/http.zig");
const App = http.App;

const auth_api = @import("auth/auth_api.zig");
const deploy_service = @import("orchestrate/deploy_service.zig");
const tail_fanout = @import("orchestrate/tail_fanout.zig");
const control_writer = @import("orchestrate/control_writer.zig");
const admin_service = @import("admin/admin_service.zig");
const billing_seam = @import("plan/billing_seam.zig");
const keys_api = @import("config/keys_api.zig");
const worker = @import("worker/run.zig");

pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

const VERSION = "0.2.0";

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

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
        }
    } else |_| {}

    var paths = try resolvePaths(gpa, io);
    if (init.environ_map.get("NEURON_LOOPS_DATA")) |d| {
        if (d.len > 0) paths.data = try gpa.dupe(u8, d);
    }
    _ = std.Io.Dir.cwd().createDirPathStatus(io, paths.data, .default_dir) catch {};

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
    var app = App{ .gpa = gpa, .io = io, .auth = &auth, .sup = &sup, .audit = &audit, .login_guard = &login_guard, .vault = &vault, .data = paths.data, .server_key = sup.server_key, .open_registration = open_reg, .cf_account_id = cf_account, .workers_ai_token = wai_token, .retention_days = retention_days, .production = production, .ledger = &ledger, .keys = &api_keys };
    std.debug.print("billing: {s} (NL_PRODUCTION)\n", .{if (production) "PRODUCTION — non-admins metered by neuron plan" else "BETA — unmetered full use"});
    if (!open_reg) std.debug.print("registration: CLOSED (private beta) — set NL_OPEN_REGISTRATION=1 to open public signups\n", .{});
    if (cf_account.len > 0 and wai_token.len > 0) std.debug.print("Workers AI: ENABLED (backbone) — provider \"workers-ai\" runs on the Cloudflare account's inference endpoint\n", .{}) else std.debug.print("Workers AI: not configured (set NL_CF_ACCOUNT_ID + NL_WORKERS_AI_TOKEN to enable the backbone)\n", .{});

    const port: u16 = 8787;
    var server = try httpz.Server(*App).init(io, gpa, .{ .address = if (bind_all) .all(port) else .localhost(port) }, &app);
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
    router.post("/api/v1/swarms", deploy_service.deploy, .{});
    router.post("/api/v1/swarms/resolve", deploy_service.resolve, .{});
    router.get("/api/v1/swarms", deploy_service.listSwarms, .{});
    router.post("/api/v1/keys", keys_api.putKey, .{});
    router.get("/api/v1/keys", keys_api.listKeys, .{});
    router.delete("/api/v1/keys/:provider", keys_api.delKey, .{});
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
    router.delete("/api/v1/swarms/:id", deploy_service.swarmDelete, .{});
    router.post("/api/v1/billing/checkout", billing_seam.billingCheckout, .{});
    router.get("/api/v1/admin/users", admin_service.adminUsers, .{});
    router.post("/api/v1/admin/billing", deploy_service.adminBilling, .{});
    router.post("/api/v1/admin/users/moderate", admin_service.adminModerate, .{});
    router.get("/api/v1/admin/swarms", admin_service.adminSwarms, .{});
    router.delete("/api/v1/admin/swarms/:id", admin_service.adminKill, .{});
    router.get("/api/v1/admin/audit", admin_service.adminAudit, .{});

    std.debug.print("neuron-loops {s} on http://127.0.0.1:{d}  home={s}  ({d} users, {d} swarms re-adopted)\n", .{ VERSION, port, paths.home, auth.userCount(), readopted });
    try server.listen();
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
