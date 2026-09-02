//! Cloudflare Tunnel — this veil, reachable at a Cloudflare URL, through the user's OWN account.
//!
//! One switch. Behind it: the official `cloudflared` connector (found on PATH, or fetched once from
//! Cloudflare's GitHub release into {data}/bin and hash-logged), a NAMED tunnel provisioned on the signed-in
//! account through the v4 API (tunnel → remotely-managed ingress → a CNAME on one of the account's zones → a
//! Cloudflare Access application that admits only the login's own email), and the connector running as a
//! managed child with the tunnel token in its ENVIRONMENT — never on an argv, never in a file. An account
//! with no zone gets a quick tunnel (a temporary trycloudflare.com address) and the status says so.
//!
//! SECURITY — what makes exposing a local server acceptable, and where each rule lives:
//!   * owner-only. The switch is behind requireAdmin and provisions for the owner's login only. A tunnel
//!     exposes the whole server, so no ordinary user may open one; non-owners see the state, never the switch.
//!   * registration closed. turnOn refuses while open registration is on, and auth_api refuses registration
//!     for ANY request that arrived through a proxy or tunnel, whatever the flag says.
//!   * no loopback trust for tunneled traffic. cloudflared connects from 127.0.0.1, so every "is this caller
//!     local?" decision (the browser relay's `pair`) now also requires the request NOT to carry the headers a
//!     tunnel or proxy adds (http.viaProxy), and the login guard buckets on Cf-Connecting-Ip instead of the one
//!     loopback peer every remote visitor would otherwise share.
//!   * the token stays sealed. The tunnel token lives in the vault under its own provider name, reaches
//!     cloudflared through its environment, and is never logged; the state file holds ids and names only.
//!   * Access in front when the account allows it. With a Zero Trust organization present, the hostname gets an
//!     Access application whose only policy admits the login's email: Cloudflare's own login page stands between
//!     the internet and this server's. Without one, the veil's rate-limited login is the gate — and the status
//!     line says which of the two it is, so nobody mistakes one for the other.
//!   * off means off. The child is killed and reaped; `delete` also removes the DNS record, the Access app and
//!     the tunnel from the account.
//!
//! The switch position is persisted: a tunnel left on comes back on at the next boot, and NL_TUNNEL=1 (or
//! `--tunnel`) turns it on at boot for a server that was configured by hand. Either way the URL is logged.
const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const App = http.App;
const cf_oauth = @import("cf_oauth.zig");
const modelpull = @import("../worker/modelpull.zig");
const requireUser = http.requireUser;
const requireAdmin = http.requireAdmin;
const badReq = http.badReq;
const log = std.log.scoped(.cf_tunnel);

/// The vault provider name the tunnel token is sealed under (one per user, like the OAuth bundle).
pub const TOKEN_PROVIDER = "cf-tunnel";
const RELEASE_BASE = "https://github.com/cloudflare/cloudflared/releases/latest/download/";
const STATE_FILE = "cf_tunnel.json";
const LOG_FILE = "cf_tunnel.log";
/// cloudflared's own line for a connector that is serving — the moment the URL is real.
const LIVE_MARK = "Registered tunnel connection";
/// How long a connector may take to register before the switch is declared failed.
const START_BUDGET_S: i64 = 90;
const LOG_CAP: usize = 512 * 1024;

/// Everything the account side knows about this server's tunnel. Ids and names only — the token is in the
/// vault, and this file is readable by anything that can read the data dir.
pub const State = struct {
    want_on: bool = false,
    mode: []const u8 = "", // "named" | "quick"
    tunnel_id: []const u8 = "",
    tunnel_name: []const u8 = "",
    zone_id: []const u8 = "",
    zone_name: []const u8 = "",
    hostname: []const u8 = "",
    dns_record_id: []const u8 = "",
    access_app_id: []const u8 = "",
    access_policy_id: []const u8 = "",
    url: []const u8 = "",
    binary: []const u8 = "",
    binary_sha256: []const u8 = "",
    last_error: []const u8 = "",
    created_at: i64 = 0,
};

pub const Phase = enum { off, installing, provisioning, starting, live, err };

/// The one live connector this process runs (a tunnel exposes the whole server, so there is one).
const Live = struct {
    phase: Phase = .off,
    uid: u64 = 0,
    child: ?std.process.Child = null,
    started_at: i64 = 0,
    busy: bool = false,
    access: bool = false,
    url: [200]u8 = undefined,
    url_len: usize = 0,
    err: [200]u8 = undefined,
    err_len: usize = 0,
    mode: [8]u8 = undefined,
    mode_len: usize = 0,
};
var live: Live = .{};
var mu: std.Io.Mutex = .init;
var exited = std.atomic.Value(bool).init(false);
var environ_ptr: ?*const std.process.Environ.Map = null;
var server_port: u16 = 8787;

/// main() hands over the process environment (the connector inherits it plus TUNNEL_TOKEN) and the port
/// the ingress must point at. Called once, before any route can fire.
pub fn configure(environ: *const std.process.Environ.Map, port: u16) void {
    environ_ptr = environ;
    server_port = port;
}

// ------------------------------------------------------------------------------------------ small helpers
fn nowS(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn phaseName(p: Phase) []const u8 {
    return switch (p) {
        .off => "off",
        .installing => "installing",
        .provisioning => "provisioning",
        .starting => "starting",
        .live => "live",
        .err => "error",
    };
}

fn setPhase(io: std.Io, p: Phase) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    live.phase = p;
}

fn setErr(io: std.Io, msg: []const u8) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    live.phase = .err;
    const n = @min(msg.len, live.err.len);
    @memcpy(live.err[0..n], msg[0..n]);
    live.err_len = n;
}

fn setUrl(io: std.Io, url: []const u8) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const n = @min(url.len, live.url.len);
    @memcpy(live.url[0..n], url[0..n]);
    live.url_len = n;
}

fn userDir(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}", .{ app.data, uid }) catch null;
}

fn statePath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ STATE_FILE, .{ app.data, uid }) catch null;
}

fn logPath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ LOG_FILE, .{ app.data, uid }) catch null;
}

pub fn readState(app: *App, uid: u64, a: std.mem.Allocator) State {
    var pb: [700]u8 = undefined;
    const path = statePath(app, uid, &pb) orelse return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(64 * 1024)) catch return .{};
    return std.json.parseFromSliceLeaky(State, a, data, .{ .ignore_unknown_fields = true }) catch .{};
}

fn writeState(app: *App, uid: u64, st: State) void {
    var db: [700]u8 = undefined;
    if (userDir(app, uid, &db)) |dir| _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    var pb: [700]u8 = undefined;
    const path = statePath(app, uid, &pb) orelse return;
    const json = std.json.Stringify.valueAlloc(app.gpa, st, .{ .whitespace = .indent_1 }) catch return;
    defer app.gpa.free(json);
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = json }) catch {};
}

/// A short random hex suffix for names that must not collide (tunnel names, fallback hostnames).
fn hex4(io: std.Io, buf: *[8]u8) []const u8 {
    var raw: [4]u8 = undefined;
    io.random(&raw);
    const h = std.fmt.bytesToHex(raw, .lower);
    @memcpy(buf[0..8], h[0..8]);
    return buf[0..8];
}

// ------------------------------------------------------------------------------------------ the API
fn apiJson(app: *App, method: []const u8, url: []const u8, body: []const u8, bearer: []const u8) ?[]u8 {
    return cf_oauth.apiCall(app, method, url, body, bearer, "application/json");
}

const Envelope = struct {
    success: bool = false,
    errors: []const struct { code: i64 = 0, message: []const u8 = "" } = &.{},
};

/// The first error message of a v4 envelope, or "" when it succeeded / could not be read.
fn firstError(a: std.mem.Allocator, raw: []const u8) []const u8 {
    const p = std.json.parseFromSliceLeaky(Envelope, a, raw, .{ .ignore_unknown_fields = true }) catch return "unreadable reply from the Cloudflare API";
    if (p.success) return "";
    if (p.errors.len == 0) return "the Cloudflare API refused the request";
    return p.errors[0].message;
}

/// A refusal that means the login never granted the tunnel scopes — the one error a user can fix.
fn isPermissionError(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "Authentication error") != null or std.mem.indexOf(u8, msg, "insufficient") != null or
        std.mem.indexOf(u8, msg, "not authorized") != null or std.mem.indexOf(u8, msg, "permission") != null;
}

fn explain(a: std.mem.Allocator, what: []const u8, msg: []const u8) []const u8 {
    if (isPermissionError(msg))
        return std.fmt.allocPrint(a, "{s}: your Cloudflare login has not granted the tunnel permissions (Cloudflare Tunnel, DNS, Zone, Access) - Disconnect and log in with Cloudflare again to grant them", .{what}) catch what;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ what, msg }) catch what;
}

// ------------------------------------------------------------------------------------------ the connector
/// Where a fetched connector lives: {data}/bin/cloudflared[.exe].
fn binDir(app: *App, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/bin", .{app.data}) catch null;
}

fn localBinary(app: *App, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/bin/cloudflared{s}", .{ app.data, if (builtin.os.tag == .windows) ".exe" else "" }) catch null;
}

fn runs(app: *App, argv: []const []const u8) bool {
    const r = std.process.run(app.gpa, app.io, .{ .argv = argv, .stdout_limit = .limited(16 << 10) }) catch return false;
    app.gpa.free(r.stdout);
    app.gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

/// The release asset for this OS/arch, or null on a platform Cloudflare does not ship for.
fn releaseAsset() ?[]const u8 {
    const arch = builtin.cpu.arch;
    return switch (builtin.os.tag) {
        .windows => switch (arch) {
            .x86_64 => "cloudflared-windows-amd64.exe",
            .x86 => "cloudflared-windows-386.exe",
            else => null,
        },
        .linux => switch (arch) {
            .x86_64 => "cloudflared-linux-amd64",
            .aarch64 => "cloudflared-linux-arm64",
            .x86 => "cloudflared-linux-386",
            .arm => "cloudflared-linux-arm",
            else => null,
        },
        .macos => switch (arch) {
            .x86_64 => "cloudflared-darwin-amd64.tgz",
            .aarch64 => "cloudflared-darwin-arm64.tgz",
            else => null,
        },
        else => null,
    };
}

/// The cloudflared to run: on PATH, or already fetched, or fetched now from Cloudflare's GitHub release
/// (TLS via curl, hash recorded in the state and the log). Returns the path, or an error message.
fn ensureBinary(app: *App, a: std.mem.Allocator, st: *State) union(enum) { path: []const u8, fail: []const u8 } {
    if (runs(app, &.{ "cloudflared", "--version" })) return .{ .path = "cloudflared" };
    var lb: [700]u8 = undefined;
    const local = localBinary(app, &lb) orelse return .{ .fail = "data dir path too long" };
    if (std.Io.Dir.cwd().statFile(app.io, local, .{})) |_| {
        return .{ .path = a.dupe(u8, local) catch local };
    } else |_| {}
    const asset = releaseAsset() orelse return .{ .fail = "cloudflared has no release for this platform - install it yourself and put it on PATH" };
    var db: [700]u8 = undefined;
    const dir = binDir(app, &db) orelse return .{ .fail = "data dir path too long" };
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    const url = std.fmt.allocPrint(a, RELEASE_BASE ++ "{s}", .{asset}) catch return .{ .fail = "oom" };
    const is_tgz = std.mem.endsWith(u8, asset, ".tgz");
    const dest = if (is_tgz) (std.fmt.allocPrint(a, "{s}/cloudflared.tgz", .{dir}) catch return .{ .fail = "oom" }) else local;
    log.info("fetching the Cloudflare Tunnel connector from {s}", .{url});
    if (!runs(app, &.{ "curl", "-sSL", "--fail", "--connect-timeout", "20", "--retry", "2", "--retry-delay", "2", "-o", dest, url }))
        return .{ .fail = "could not download cloudflared from Cloudflare's GitHub release (offline? curl missing?) - install it yourself and put it on PATH" };
    if (is_tgz) {
        if (!runs(app, &.{ "tar", "-xzf", dest, "-C", dir })) return .{ .fail = "could not unpack the cloudflared release archive" };
        std.Io.Dir.cwd().deleteFile(app.io, dest) catch {};
    }
    if (builtin.os.tag != .windows) _ = runs(app, &.{ "chmod", "+x", local });
    var hx: [64]u8 = undefined;
    if (modelpull.sha256HexOfFile(app.io, local, &hx)) |h| {
        st.binary_sha256 = a.dupe(u8, h) catch "";
        log.info("cloudflared fetched: {s} sha256={s}", .{ local, h });
    }
    if (!runs(app, &.{ local, "--version" })) return .{ .fail = "the fetched cloudflared does not run on this machine" };
    return .{ .path = a.dupe(u8, local) catch local };
}

// ------------------------------------------------------------------------------------------ provisioning
const Tok = struct { key: []const u8, base_url: []const u8, account_id: []const u8 };

/// Create (or reuse) the named tunnel, point it at this server, give it a hostname on one of the account's
/// zones, and put Access in front when the account has a Zero Trust organization. Returns the tunnel token
/// on success (caller seals it), or null with st.last_error set. Every step is idempotent against the ids
/// already in `st`, so a second flip reuses what the first one made.
fn provisionNamed(app: *App, a: std.mem.Allocator, uid: u64, st: *State, tok: Tok, email: []const u8) ?[]const u8 {
    _ = uid; // the state is already this user's; kept in the signature for symmetry with startChild
    const root = app.cf_api_root;
    const acct = tok.account_id;

    // ---- 1. a zone to live on. None → quick tunnel (the caller handles it).
    if (st.zone_id.len == 0) {
        const url = std.fmt.allocPrint(a, "{s}/zones?account.id={s}&status=active&per_page=50", .{ root, acct }) catch return null;
        const raw = apiJson(app, "GET", url, "", tok.key) orelse {
            st.last_error = "could not reach the Cloudflare API";
            return null;
        };
        const Z = struct { success: bool = false, result: []const struct { id: []const u8 = "", name: []const u8 = "" } = &.{} };
        const z = std.json.parseFromSliceLeaky(Z, a, raw, .{ .ignore_unknown_fields = true }) catch {
            st.last_error = "unreadable zone list from the Cloudflare API";
            return null;
        };
        if (!z.success) {
            st.last_error = explain(a, "listing your zones failed", firstError(a, raw));
            return null;
        }
        if (z.result.len == 0) {
            st.mode = "quick";
            return null; // not an error: the caller falls back to a quick tunnel
        }
        st.zone_id = z.result[0].id;
        st.zone_name = z.result[0].name;
    }

    // ---- 2. the tunnel itself
    if (st.tunnel_id.len == 0) {
        var hb: [8]u8 = undefined;
        st.tunnel_name = std.fmt.allocPrint(a, "veil-{s}", .{hex4(app.io, &hb)}) catch return null;
        const url = std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel", .{ root, acct }) catch return null;
        const body = std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"config_src\":\"cloudflare\"}}", .{st.tunnel_name}) catch return null;
        const raw = apiJson(app, "POST", url, body, tok.key) orelse {
            st.last_error = "could not reach the Cloudflare API";
            return null;
        };
        const T = struct { success: bool = false, result: ?struct { id: []const u8 = "" } = null };
        const t = std.json.parseFromSliceLeaky(T, a, raw, .{ .ignore_unknown_fields = true }) catch {
            st.last_error = "unreadable tunnel reply from the Cloudflare API";
            return null;
        };
        if (!t.success or t.result == null or t.result.?.id.len == 0) {
            st.last_error = explain(a, "creating the tunnel failed", firstError(a, raw));
            return null;
        }
        st.tunnel_id = t.result.?.id;
        st.created_at = nowS(app.io);
    }

    // ---- 3. a hostname: veil.<zone>, or veil-<hex>.<zone> when that name is taken by something else
    if (st.hostname.len == 0) {
        const want = std.fmt.allocPrint(a, "veil.{s}", .{st.zone_name}) catch return null;
        const url = std.fmt.allocPrint(a, "{s}/zones/{s}/dns_records?name={s}", .{ root, st.zone_id, want }) catch return null;
        var taken = false;
        if (apiJson(app, "GET", url, "", tok.key)) |raw| {
            const D = struct { success: bool = false, result: []const struct { id: []const u8 = "", content: []const u8 = "" } = &.{} };
            if (std.json.parseFromSliceLeaky(D, a, raw, .{ .ignore_unknown_fields = true })) |d| {
                for (d.result) |rec| {
                    if (std.mem.indexOf(u8, rec.content, st.tunnel_id) != null) {
                        st.dns_record_id = rec.id; // ours from an earlier run
                    } else taken = true;
                }
            } else |_| {}
        }
        if (taken) {
            var hb: [8]u8 = undefined;
            st.hostname = std.fmt.allocPrint(a, "veil-{s}.{s}", .{ hex4(app.io, &hb)[0..4], st.zone_name }) catch return null;
        } else st.hostname = want;
    }

    // ---- 4. ingress: the hostname → this server, everything else → 404
    {
        const url = std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel/{s}/configurations", .{ root, acct, st.tunnel_id }) catch return null;
        const body = std.fmt.allocPrint(a, "{{\"config\":{{\"ingress\":[{{\"hostname\":\"{s}\",\"service\":\"http://127.0.0.1:{d}\"}},{{\"service\":\"http_status:404\"}}]}}}}", .{ st.hostname, server_port }) catch return null;
        const raw = apiJson(app, "PUT", url, body, tok.key) orelse {
            st.last_error = "could not reach the Cloudflare API";
            return null;
        };
        const msg = firstError(a, raw);
        if (msg.len > 0) {
            st.last_error = explain(a, "configuring the tunnel's ingress failed", msg);
            return null;
        }
    }

    // ---- 5. DNS: hostname → <tunnel>.cfargotunnel.com, proxied
    if (st.dns_record_id.len == 0) {
        const url = std.fmt.allocPrint(a, "{s}/zones/{s}/dns_records", .{ root, st.zone_id }) catch return null;
        const body = std.fmt.allocPrint(a, "{{\"type\":\"CNAME\",\"name\":\"{s}\",\"content\":\"{s}.cfargotunnel.com\",\"proxied\":true,\"ttl\":1,\"comment\":\"veil tunnel\"}}", .{ st.hostname, st.tunnel_id }) catch return null;
        const raw = apiJson(app, "POST", url, body, tok.key) orelse {
            st.last_error = "could not reach the Cloudflare API";
            return null;
        };
        const R = struct { success: bool = false, result: ?struct { id: []const u8 = "" } = null };
        const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch {
            st.last_error = "unreadable DNS reply from the Cloudflare API";
            return null;
        };
        if (!r.success or r.result == null) {
            st.last_error = explain(a, "creating the DNS record failed", firstError(a, raw));
            return null;
        }
        st.dns_record_id = r.result.?.id;
    }
    st.url = std.fmt.allocPrint(a, "https://{s}", .{st.hostname}) catch return null;
    st.mode = "named";

    // ---- 6. Access in front: only the login's own email may pass. Best-effort — an account without a
    // Zero Trust organization simply reports "protected by your veil login" instead.
    if (st.access_app_id.len == 0 and email.len > 0) access: {
        const ourl = std.fmt.allocPrint(a, "{s}/accounts/{s}/access/organizations", .{ root, acct }) catch break :access;
        const oraw = apiJson(app, "GET", ourl, "", tok.key) orelse break :access;
        const O = struct { success: bool = false, result: ?struct { auth_domain: []const u8 = "" } = null };
        const o = std.json.parseFromSliceLeaky(O, a, oraw, .{ .ignore_unknown_fields = true }) catch break :access;
        if (!o.success or o.result == null or o.result.?.auth_domain.len == 0) break :access;
        // ZONE-level Access apps: the login carries zone-access.* (the account-level access.* ids are not
        // grantable to this client - probed live), and a named tunnel always has a zone.
        const aurl = std.fmt.allocPrint(a, "{s}/zones/{s}/access/apps", .{ root, st.zone_id }) catch break :access;
        const abody = std.fmt.allocPrint(a, "{{\"name\":\"veil ({s})\",\"domain\":\"{s}\",\"type\":\"self_hosted\",\"session_duration\":\"24h\",\"app_launcher_visible\":false}}", .{ st.hostname, st.hostname }) catch break :access;
        const araw = apiJson(app, "POST", aurl, abody, tok.key) orelse break :access;
        const A = struct { success: bool = false, result: ?struct { id: []const u8 = "" } = null };
        const ap = std.json.parseFromSliceLeaky(A, a, araw, .{ .ignore_unknown_fields = true }) catch break :access;
        if (!ap.success or ap.result == null) {
            log.warn("Access application not created ({s}) - the tunnel is protected by the veil login only", .{firstError(a, araw)});
            break :access;
        }
        st.access_app_id = ap.result.?.id;
        const purl = std.fmt.allocPrint(a, "{s}/zones/{s}/access/apps/{s}/policies", .{ root, st.zone_id, st.access_app_id }) catch break :access;
        var eb: std.ArrayListUnmanaged(u8) = .empty;
        eb.appendSlice(a, "{\"name\":\"owner only\",\"decision\":\"allow\",\"precedence\":1,\"include\":[{\"email\":{\"email\":") catch break :access;
        http.jstr(a, &eb, email) catch break :access;
        eb.appendSlice(a, "}}]}") catch break :access;
        const praw = apiJson(app, "POST", purl, eb.items, tok.key) orelse break :access;
        const pp = std.json.parseFromSliceLeaky(A, a, praw, .{ .ignore_unknown_fields = true }) catch break :access;
        if (pp.success and pp.result != null) st.access_policy_id = pp.result.?.id;
    }

    // ---- 7. the connector's token
    const turl = std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel/{s}/token", .{ root, acct, st.tunnel_id }) catch return null;
    const traw = apiJson(app, "GET", turl, "", tok.key) orelse {
        st.last_error = "could not reach the Cloudflare API";
        return null;
    };
    const K = struct { success: bool = false, result: []const u8 = "" };
    const k = std.json.parseFromSliceLeaky(K, a, traw, .{ .ignore_unknown_fields = true }) catch {
        st.last_error = "unreadable token reply from the Cloudflare API";
        return null;
    };
    if (!k.success or k.result.len == 0) {
        st.last_error = explain(a, "fetching the tunnel token failed", firstError(a, traw));
        return null;
    }
    return k.result;
}

/// Tear the account side down (delete). Best-effort, in dependency order; the state is cleared regardless.
fn deprovision(app: *App, a: std.mem.Allocator, st: *State, tok: Tok) void {
    const root = app.cf_api_root;
    const acct = tok.account_id;
    if (st.access_app_id.len > 0) {
        if (std.fmt.allocPrint(a, "{s}/zones/{s}/access/apps/{s}", .{ root, st.zone_id, st.access_app_id })) |u| {
            if (apiJson(app, "DELETE", u, "", tok.key)) |r| app.gpa.free(r);
        } else |_| {}
    }
    if (st.dns_record_id.len > 0 and st.zone_id.len > 0) {
        if (std.fmt.allocPrint(a, "{s}/zones/{s}/dns_records/{s}", .{ root, st.zone_id, st.dns_record_id })) |u| {
            if (apiJson(app, "DELETE", u, "", tok.key)) |r| app.gpa.free(r);
        } else |_| {}
    }
    if (st.tunnel_id.len > 0) {
        if (std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel/{s}/connections", .{ root, acct, st.tunnel_id })) |u| {
            if (apiJson(app, "DELETE", u, "", tok.key)) |r| app.gpa.free(r);
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel/{s}", .{ root, acct, st.tunnel_id })) |u| {
            if (apiJson(app, "DELETE", u, "", tok.key)) |r| app.gpa.free(r);
        } else |_| {}
    }
    st.* = .{};
}

// ------------------------------------------------------------------------------------------ the child
fn waiter(io: std.Io) void {
    if (live.child) |*c| {
        _ = c.wait(io) catch {};
    }
    exited.store(true, .monotonic);
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (live.phase == .live or live.phase == .starting) {
        live.phase = .err;
        const m = "cloudflared exited - see cf_tunnel.log in the user's data dir";
        @memcpy(live.err[0..m.len], m);
        live.err_len = m.len;
    }
}

/// Spawn the connector and watch its log until it registers (named: the LIVE_MARK line; quick: the
/// trycloudflare address) or the budget runs out. Returns null on success, else the error.
fn startChild(app: *App, a: std.mem.Allocator, uid: u64, st: *State, token: ?[]const u8) ?[]const u8 {
    const io = app.io;
    var lb: [700]u8 = undefined;
    const logp = logPath(app, uid, &lb) orelse return "data dir path too long";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = logp, .data = "" }) catch {};
    var port_b: [40]u8 = undefined;
    const origin = std.fmt.bufPrint(&port_b, "http://127.0.0.1:{d}", .{server_port}) catch return "oom";
    const base = environ_ptr orelse return "the tunnel was not configured at boot (no environment)";
    var env = base.clone(app.gpa) catch return "oom";
    defer env.deinit();
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(app.gpa);
    argv.appendSlice(app.gpa, &.{ st.binary, "tunnel", "--no-autoupdate", "--logfile", logp }) catch return "oom";
    if (token) |t| {
        // THE TOKEN RIDES THE ENVIRONMENT. `--token` on the argv would show it to every process on the
        // machine (ps, Task Manager, the agent's own run_python); cloudflared reads TUNNEL_TOKEN itself.
        env.put("TUNNEL_TOKEN", t) catch return "oom";
        argv.append(app.gpa, "run") catch return "oom";
    } else {
        argv.appendSlice(app.gpa, &.{ "--url", origin }) catch return "oom";
    }
    exited.store(false, .monotonic);
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env,
        .create_no_window = true,
    }) catch return "could not start cloudflared";
    {
        mu.lockUncancelable(io);
        defer mu.unlock(io);
        live.child = child;
        live.started_at = nowS(io);
        live.uid = uid;
        live.phase = .starting;
    }
    child = undefined;
    const th = std.Thread.spawn(.{}, waiter, .{io}) catch null;
    if (th) |t| t.detach();

    // watch the log
    const t0 = nowS(io);
    while (nowS(io) - t0 < START_BUDGET_S) {
        if (exited.load(.monotonic)) break;
        if (std.Io.Dir.cwd().readFileAlloc(io, logp, a, .limited(LOG_CAP))) |text| {
            if (token != null) {
                if (std.mem.indexOf(u8, text, LIVE_MARK) != null) return null;
            } else if (std.mem.indexOf(u8, text, ".trycloudflare.com")) |at| {
                // walk back to the scheme, forward to the end of the host
                var s = at;
                while (s > 0 and text[s - 1] != ' ' and text[s - 1] != '|' and text[s - 1] != '"') : (s -= 1) {}
                var e = at;
                while (e < text.len and text[e] != ' ' and text[e] != '|' and text[e] != '"' and text[e] != '\n' and text[e] != '\r') : (e += 1) {}
                const url = text[s..e];
                if (std.mem.startsWith(u8, url, "https://")) {
                    st.url = a.dupe(u8, url) catch url;
                    return null;
                }
            }
            if (std.mem.indexOf(u8, text, "Unauthorized") != null or std.mem.indexOf(u8, text, "failed to run tunnel") != null or std.mem.indexOf(u8, text, "ERR ") != null and std.mem.indexOf(u8, text, "authenticat") != null) {
                return "cloudflared could not authenticate with this tunnel token - flip the switch off and on to re-provision";
            }
        } else |_| {}
        io.sleep(.{ .nanoseconds = 700 * std.time.ns_per_ms }, .awake) catch {};
    }
    if (exited.load(.monotonic)) return "cloudflared exited before registering - see cf_tunnel.log in the user's data dir";
    return "cloudflared did not register a connection within 90s - see cf_tunnel.log in the user's data dir";
}

fn killChild(io: std.Io) void {
    mu.lockUncancelable(io);
    const had = live.child != null;
    if (live.child) |*c| c.kill(io);
    mu.unlock(io);
    if (had) {
        // let the waiter observe the exit before the slot is cleared (bounded: kill reaps on its own)
        var waited: usize = 0;
        while (!exited.load(.monotonic) and waited < 50) : (waited += 1) io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    live.child = null;
    live.url_len = 0;
}

// ------------------------------------------------------------------------------------------ on / off
/// Bring the tunnel up for `uid` (the owner). Every refusal is a sentence the status shows.
pub fn turnOn(app: *App, uid: u64) void {
    const io = app.io;
    {
        mu.lockUncancelable(io);
        defer mu.unlock(io);
        if (live.busy) return;
        live.busy = true;
        live.err_len = 0;
    }
    defer {
        mu.lockUncancelable(io);
        live.busy = false;
        mu.unlock(io);
    }
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = readState(app, uid, a);
    st.want_on = true;
    st.last_error = "";

    if (app.open_registration) {
        st.last_error = "open registration is on: anyone who found the URL could create an account. Close it (NL_OPEN_REGISTRATION=0) and flip the switch again";
        writeState(app, uid, st);
        setErr(io, st.last_error);
        return;
    }
    const tok = cf_oauth.resolveToken(app, uid, a) orelse {
        st.last_error = "not connected to Cloudflare - log in with Cloudflare first";
        writeState(app, uid, st);
        setErr(io, st.last_error);
        return;
    };
    const prof = cf_oauth.readProfile(app, uid, a) orelse cf_oauth.Profile{};

    setPhase(io, .installing);
    switch (ensureBinary(app, a, &st)) {
        .path => |p| st.binary = p,
        .fail => |m| {
            st.last_error = m;
            writeState(app, uid, st);
            setErr(io, m);
            return;
        },
    }
    writeState(app, uid, st);

    setPhase(io, .provisioning);
    var token: ?[]const u8 = null;
    if (!std.mem.eql(u8, st.mode, "quick")) {
        if (provisionNamed(app, a, uid, &st, .{ .key = tok.key, .base_url = tok.base_url, .account_id = tok.account_id }, prof.email)) |t| {
            token = t;
            app.vault.put(uid, TOKEN_PROVIDER, t, "") catch |e| log.warn("tunnel token could not be sealed into the vault ({t}); it is not persisted", .{e});
        } else if (st.last_error.len > 0) {
            writeState(app, uid, st);
            setErr(io, st.last_error);
            return;
        }
        // a named tunnel that already exists: the token is in the vault from the first provisioning
        if (token == null and std.mem.eql(u8, st.mode, "named")) {
            if (app.vault.resolve(uid, TOKEN_PROVIDER, a)) |r| token = r.key;
        }
    }
    if (token == null and !std.mem.eql(u8, st.mode, "quick")) {
        st.last_error = "no tunnel token - flip the switch off and on to re-provision";
        writeState(app, uid, st);
        setErr(io, st.last_error);
        return;
    }
    if (std.mem.eql(u8, st.mode, "quick")) {
        st.url = "";
        st.hostname = "";
        log.warn("Cloudflare tunnel: the account has no zone (domain), so this is a QUICK tunnel with a temporary trycloudflare.com address and no Access policy - the veil login is the only gate", .{});
    }
    writeState(app, uid, st);

    if (startChild(app, a, uid, &st, token)) |err| {
        killChild(io);
        st.last_error = err;
        writeState(app, uid, st);
        setErr(io, err);
        return;
    }
    writeState(app, uid, st);
    {
        mu.lockUncancelable(io);
        defer mu.unlock(io);
        live.phase = .live;
        live.access = st.access_policy_id.len > 0;
        const ml = @min(st.mode.len, live.mode.len);
        @memcpy(live.mode[0..ml], st.mode[0..ml]);
        live.mode_len = ml;
    }
    setUrl(io, st.url);
    log.info("Cloudflare tunnel: {s}  ({s}{s})", .{ st.url, st.mode, if (st.access_policy_id.len > 0) ", Access: owner only" else ", veil login only" });
}

/// Stop the connector; with `delete`, also remove the tunnel, its DNS record and its Access app from the
/// account and forget the sealed token.
pub fn turnOff(app: *App, uid: u64, delete: bool) void {
    const io = app.io;
    killChild(io);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = readState(app, uid, a);
    st.want_on = false;
    st.last_error = "";
    if (delete) {
        if (cf_oauth.resolveToken(app, uid, a)) |tok| deprovision(app, a, &st, .{ .key = tok.key, .base_url = tok.base_url, .account_id = tok.account_id });
        app.vault.del(uid, TOKEN_PROVIDER);
        st = .{};
    }
    writeState(app, uid, st);
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    live.phase = .off;
    live.err_len = 0;
    live.url_len = 0;
    live.access = false;
}

fn onThread(app: *App, uid: u64) void {
    turnOn(app, uid);
}

// ------------------------------------------------------------------------------------------ boot
/// The owner: the first admin whose login is connected to Cloudflare.
fn ownerUid(app: *App) ?u64 {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const users = app.auth.listUsers(a) catch return null;
    for (users) |ui| {
        const u = app.auth.userById(ui.id) orelse continue;
        if (!app.auth.isAdmin(u)) continue;
        if (cf_oauth.readProfile(app, ui.id, a) != null) return ui.id;
    }
    return null;
}

fn bootThread(app: *App, forced: bool) void {
    app.io.sleep(.{ .nanoseconds = 1500 * std.time.ns_per_ms }, .awake) catch {};
    const uid = ownerUid(app) orelse {
        if (forced) log.warn("NL_TUNNEL is set but no admin login is connected to Cloudflare - log in with Cloudflare first, then flip the switch (or restart)", .{});
        return;
    };
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const st = readState(app, uid, arena.allocator());
    if (forced or st.want_on) {
        log.info("Cloudflare tunnel: bringing it up{s}", .{if (forced) " (NL_TUNNEL)" else " (the switch was left on)"});
        turnOn(app, uid);
    }
}

/// At boot: restore a switch that was left on, or force it on for NL_TUNNEL / --tunnel. Asynchronous — the
/// server must not wait on the Cloudflare API to start listening.
pub fn bootAsync(app: *App, forced: bool) void {
    const th = std.Thread.spawn(.{}, bootThread, .{ app, forced }) catch return;
    th.detach();
}

/// Stop the connector on shutdown so it never outlives the server it proxies to.
pub fn shutdown(app: *App) void {
    killChild(app.io);
}

// ------------------------------------------------------------------------------------------ routes
/// GET /api/v1/oauth/cloudflare/tunnel — the snapshot. Any logged-in user may look; only the owner sees the
/// switch enabled (admin:true), and a non-owner is never shown the URL of a server they do not own.
pub fn tunnelStatus(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const admin = app.auth.isAdmin(u);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var connected = false;
    if (app.vault.resolveOAuth(u.id, cf_oauth.CF_PROVIDER, a)) |b| connected = b.refresh_token.len > 0;
    const st = readState(app, u.id, a);
    var phase: Phase = .off;
    var url: []const u8 = "";
    var err: []const u8 = "";
    var access = false;
    var since: i64 = 0;
    var busy = false;
    {
        mu.lockUncancelable(app.io);
        defer mu.unlock(app.io);
        phase = live.phase;
        url = a.dupe(u8, live.url[0..live.url_len]) catch "";
        err = a.dupe(u8, live.err[0..live.err_len]) catch "";
        access = live.access;
        since = live.started_at;
        busy = live.busy;
    }
    if (err.len == 0) err = st.last_error;
    if (!admin) {
        url = "";
        err = "";
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    try out.print(app.gpa, "{{\"ok\":true,\"connected\":{},\"admin\":{},\"state\":\"{s}\",\"on\":{},\"busy\":{},\"live\":{},\"access\":{},\"since\":{d},\"open_registration\":{},\"url\":", .{ connected, admin, phaseName(phase), st.want_on, busy, phase == .live, access, since, app.open_registration });
    try http.jstr(app.gpa, &out, url);
    try out.appendSlice(app.gpa, ",\"hostname\":");
    try http.jstr(app.gpa, &out, if (admin) st.hostname else "");
    try out.appendSlice(app.gpa, ",\"mode\":");
    try http.jstr(app.gpa, &out, st.mode);
    try out.appendSlice(app.gpa, ",\"zone\":");
    try http.jstr(app.gpa, &out, if (admin) st.zone_name else "");
    try out.appendSlice(app.gpa, ",\"cloudflared\":");
    try http.jstr(app.gpa, &out, st.binary);
    try out.appendSlice(app.gpa, ",\"last_error\":");
    try http.jstr(app.gpa, &out, err);
    try out.append(app.gpa, '}');
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, out.items);
}

const SetReq = struct { on: bool, delete: bool = false };

/// POST /api/v1/oauth/cloudflare/tunnel {on[, delete]} — the switch. Owner only. Answers at once; the work
/// runs on its own thread and the status poll reports the phases and then the URL.
pub fn tunnelSet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireAdmin(app, req, res) orelse return;
    const body = (req.json(SetReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (body.on) {
        if (app.open_registration) return badReq(res, "open registration is on: close it (NL_OPEN_REGISTRATION=0) before exposing this server");
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        if (cf_oauth.resolveToken(app, u.id, arena.allocator()) == null) return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
        {
            mu.lockUncancelable(app.io);
            defer mu.unlock(app.io);
            if (live.busy) return badReq(res, "a switch flip is already in progress");
            live.phase = .installing;
            live.err_len = 0;
        }
        const th = std.Thread.spawn(.{}, onThread, .{ app, u.id }) catch {
            setErr(app.io, "could not start the tunnel worker thread");
            return badReq(res, "could not start the tunnel worker thread");
        };
        th.detach();
        try res.json(.{ .ok = true, .on = true, .state = "installing" }, .{});
        return;
    }
    turnOff(app, u.id, body.delete);
    try res.json(.{ .ok = true, .on = false, .state = "off", .deleted = body.delete }, .{});
}

// ---------------------------------------------------------------------------
// tests — see harness/TESTING.md (Handlers). The properties worth pinning: the routes are gated, the
// state file round-trips its defaults, and the token never appears in the state.
// ---------------------------------------------------------------------------

test "every tunnel route is gated: an anonymous caller gets 401 and nothing runs" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftun-tmp");
    defer ta.deinit();
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        try tunnelStatus(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.json(.{ .on = true });
        try tunnelSet(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
}

test "state round-trips through its JSON with defaults, and carries no token field" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(State, gpa, "{\"want_on\":true,\"hostname\":\"veil.example.com\"}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.want_on);
    try std.testing.expectEqualStrings("veil.example.com", parsed.value.hostname);
    try std.testing.expectEqualStrings("", parsed.value.tunnel_id);
    try std.testing.expect(!@hasField(State, "token"));
    try std.testing.expect(releaseAsset() != null or builtin.os.tag == .freestanding);
}

test "the permission explanation names the fix, other errors are quoted verbatim" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const perm = explain(a, "creating the tunnel failed", "Authentication error: insufficient permissions");
    try std.testing.expect(std.mem.indexOf(u8, perm, "log in with Cloudflare again") != null);
    const other = explain(a, "creating the tunnel failed", "tunnel name already exists");
    try std.testing.expectEqualStrings("creating the tunnel failed: tunnel name already exists", other);
    try std.testing.expectEqualStrings("", firstError(a, "{\"success\":true,\"errors\":[],\"result\":{}}"));
    try std.testing.expectEqualStrings("nope", firstError(a, "{\"success\":false,\"errors\":[{\"code\":1,\"message\":\"nope\"}]}"));
}
