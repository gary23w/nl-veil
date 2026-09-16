//! Cloudflare Tunnel — this veil, reachable at a Cloudflare URL, through the user's OWN account.
//!
//! One switch. Behind it: the official `cloudflared` connector (found on PATH, or fetched once from
//! Cloudflare's GitHub release into {data}/bin and hash-logged) running as a managed child. BY DEFAULT the
//! address is CONFIDENTIAL: a quick tunnel, a random unlisted trycloudflare.com hostname that changes on every
//! start and puts no record on any domain the user owns — the veil is a personal harness, and a URL nobody can
//! guess or look up is the right default for one. Only when the user asks for "use my domain" is a NAMED tunnel
//! provisioned on the signed-in account through the v4 API (tunnel → remotely-managed ingress → a CNAME on one
//! of the account's zones → a Cloudflare Access application that admits only the login's own email), with the
//! tunnel token in the connector's ENVIRONMENT — never on an argv, never in a file.
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
const fakehttp = @import("../worker/fakehttp.zig"); // TEST ONLY: the stand-in v4 API the provisioning tests dial
const requireUser = http.requireUser;
const requireAdmin = http.requireAdmin;
const badReq = http.badReq;
const log = std.log.scoped(.cf_tunnel);

/// The vault provider name the tunnel token is sealed under (one per user, like the OAuth bundle).
pub const TOKEN_PROVIDER = "cf-tunnel";
const RELEASE_BASE = "https://github.com/cloudflare/cloudflared/releases/latest/download/";
const STATE_FILE = "cf_tunnel.json";
const LOG_FILE = "cf_tunnel.log";
const PID_FILE = "cf_tunnel.pid";
/// cloudflared's own line for a connector that is serving — the moment the URL is real.
const LIVE_MARK = "Registered tunnel connection";
/// How long a connector may take to register before the switch is declared failed.
const START_BUDGET_S: i64 = 90;
/// How long the URL is held back waiting for Cloudflare's resolver to publish the fresh hostname.
const PUBLISH_BUDGET_S: i64 = 90;
/// Cloudflare's public DNS-over-HTTPS endpoint, asked DIRECTLY so the machine's own resolver never sees the
/// name before it exists (see awaitPublished).
const DOH_URL = "https://cloudflare-dns.com/dns-query";
const LOG_CAP: usize = 512 * 1024;

/// Everything the account side knows about this server's tunnel. Ids and names only — the token is in the
/// vault, and this file is readable by anything that can read the data dir.
pub const State = struct {
    want_on: bool = false,
    /// The user's choice: false (default) = a confidential trycloudflare.com address; true = a hostname on one
    /// of the account's zones (`want_hostname`, or veil.<first zone> when blank).
    use_domain: bool = false,
    want_hostname: []const u8 = "",
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

pub const Phase = enum { off, installing, provisioning, starting, publishing, live, err };

/// The one live connector this process runs (a tunnel exposes the whole server, so there is one).
const Live = struct {
    phase: Phase = .off,
    uid: u64 = 0,
    child: ?std.process.Child = null,
    started_at: i64 = 0,
    busy: bool = false,
    access: bool = false,
    /// Whether Cloudflare's resolver had published the hostname when the URL was shown (see awaitPublished).
    published: bool = false,
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
        .publishing => "publishing",
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

fn pidPath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ PID_FILE, .{ app.data, uid }) catch null;
}

/// A hostname the user typed: lowercase letters, digits, dots and hyphens, at least one dot, no oddities.
fn hostnameOk(h: []const u8) bool {
    if (h.len < 3 or h.len > 253 or h[0] == '.' or h[h.len - 1] == '.' or h[0] == '-') return false;
    var dots: usize = 0;
    for (h) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.';
        if (!ok) return false;
        if (c == '.') dots += 1;
    }
    return dots >= 1 and std.mem.indexOf(u8, h, "..") == null;
}

/// Is `host` the zone's apex or a name under it? Matched at a label boundary, never as a bare suffix:
/// `veil.badexample.com` is not on `example.com`.
fn onZone(host: []const u8, zone: []const u8) bool {
    if (zone.len == 0) return false;
    if (std.mem.eql(u8, host, zone)) return true;
    return host.len > zone.len + 1 and std.mem.endsWith(u8, host, zone) and host[host.len - zone.len - 1] == '.';
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
/// One v4 call. The reply is copied into `a` and curl's gpa copy freed here: the ids parsed out of a reply point
/// INTO its bytes (std.json leaves an unescaped string where it found it), so the reply must live exactly as long
/// as the state those ids are written to - the caller's arena.
fn apiJson(app: *App, a: std.mem.Allocator, method: []const u8, url: []const u8, body: []const u8, bearer: []const u8) ?[]u8 {
    const raw = cf_oauth.apiCall(app, method, url, body, bearer, "application/json") orelse return null;
    defer app.gpa.free(raw);
    return a.dupe(u8, raw) catch null;
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

    // ---- 1. the zone: the one the requested hostname belongs to (the most specific, when one zone sits inside
    // another), else the account's first. A hostname on no zone of this account is an error the user can act
    // on, never a silent fallback.
    if (st.zone_id.len == 0 or (st.want_hostname.len > 0 and !onZone(st.want_hostname, st.zone_name))) {
        const url = std.fmt.allocPrint(a, "{s}/zones?account.id={s}&status=active&per_page=50", .{ root, acct }) catch return null;
        const raw = apiJson(app, a, "GET", url, "", tok.key) orelse {
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
            st.last_error = "this Cloudflare account has no domain (zone) - add one, or switch off 'use my domain' for a confidential address";
            return null;
        }
        var pick: ?usize = null;
        if (st.want_hostname.len > 0) {
            for (z.result, 0..) |zn, i| {
                if (onZone(st.want_hostname, zn.name) and (pick == null or zn.name.len > z.result[pick.?].name.len)) pick = i;
            }
            if (pick == null) {
                st.last_error = std.fmt.allocPrint(a, "{s} is not on any domain of this Cloudflare account ({d} zone(s) checked)", .{ st.want_hostname, z.result.len }) catch "the hostname is not on any domain of this account";
                return null;
            }
        } else pick = 0;
        // A MOVE to another zone. The old hostname's DNS record and Access app live on the old zone, and nothing
        // would ever name them again: they come off the account before the zone id they are filed under goes.
        retireHostname(app, a, st, tok);
        st.zone_id = z.result[pick.?].id;
        st.zone_name = z.result[pick.?].name;
        st.hostname = "";
    }

    // ---- 2. the tunnel itself
    if (st.tunnel_id.len == 0) {
        var hb: [8]u8 = undefined;
        st.tunnel_name = std.fmt.allocPrint(a, "veil-{s}", .{hex4(app.io, &hb)}) catch return null;
        const url = std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel", .{ root, acct }) catch return null;
        const body = std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"config_src\":\"cloudflare\"}}", .{st.tunnel_name}) catch return null;
        const raw = apiJson(app, a, "POST", url, body, tok.key) orelse {
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

    // ---- 3. a hostname: the one asked for, else veil.<zone>, else veil-<hex>.<zone> when that is taken
    if (st.hostname.len == 0) {
        const want = if (st.want_hostname.len > 0) st.want_hostname else (std.fmt.allocPrint(a, "veil.{s}", .{st.zone_name}) catch return null);
        const url = std.fmt.allocPrint(a, "{s}/zones/{s}/dns_records?name={s}", .{ root, st.zone_id, want }) catch return null;
        var taken = false;
        var ours: []const u8 = ""; // a record for `want` that already points at this tunnel, from an earlier run
        if (apiJson(app, a, "GET", url, "", tok.key)) |raw| {
            const D = struct { success: bool = false, result: []const struct { id: []const u8 = "", content: []const u8 = "" } = &.{} };
            if (std.json.parseFromSliceLeaky(D, a, raw, .{ .ignore_unknown_fields = true })) |d| {
                for (d.result) |rec| {
                    if (std.mem.indexOf(u8, rec.content, st.tunnel_id) != null) ours = rec.id else taken = true;
                }
            } else |_| {}
        }
        // A HOSTNAME CHANGE: tunnelSet clears the hostname when the request moves, so ids still in the state
        // belong to the OLD name, and steps 5 and 6 create a record and an Access app only where no id is held.
        // Unless the lookup just found that very record under the new name (the name did not really change),
        // both come off the account here - the old name stops pointing at this tunnel, and the new one gets its
        // own record and its own Access app instead of borrowing the old name's.
        if (st.dns_record_id.len > 0 or st.access_app_id.len > 0) {
            const same = !taken and ours.len > 0 and std.mem.eql(u8, ours, st.dns_record_id);
            if (!same) retireHostname(app, a, st, tok);
        }
        if (taken) {
            var hb: [8]u8 = undefined;
            st.hostname = std.fmt.allocPrint(a, "veil-{s}.{s}", .{ hex4(app.io, &hb)[0..4], st.zone_name }) catch return null;
        } else {
            st.hostname = want;
            if (ours.len > 0) st.dns_record_id = ours;
        }
    }

    // ---- 4. ingress: the hostname → this server, everything else → 404
    {
        const url = std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel/{s}/configurations", .{ root, acct, st.tunnel_id }) catch return null;
        const body = std.fmt.allocPrint(a, "{{\"config\":{{\"ingress\":[{{\"hostname\":\"{s}\",\"service\":\"http://127.0.0.1:{d}\"}},{{\"service\":\"http_status:404\"}}]}}}}", .{ st.hostname, server_port }) catch return null;
        const raw = apiJson(app, a, "PUT", url, body, tok.key) orelse {
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
        const raw = apiJson(app, a, "POST", url, body, tok.key) orelse {
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
        const oraw = apiJson(app, a, "GET", ourl, "", tok.key) orelse break :access;
        const O = struct { success: bool = false, result: ?struct { auth_domain: []const u8 = "" } = null };
        const o = std.json.parseFromSliceLeaky(O, a, oraw, .{ .ignore_unknown_fields = true }) catch break :access;
        if (!o.success or o.result == null or o.result.?.auth_domain.len == 0) break :access;
        // ZONE-level Access apps: the login carries zone-access.* (the account-level access.* ids are not
        // grantable to this client - probed live), and a named tunnel always has a zone.
        const aurl = std.fmt.allocPrint(a, "{s}/zones/{s}/access/apps", .{ root, st.zone_id }) catch break :access;
        const abody = std.fmt.allocPrint(a, "{{\"name\":\"veil ({s})\",\"domain\":\"{s}\",\"type\":\"self_hosted\",\"session_duration\":\"24h\",\"app_launcher_visible\":false}}", .{ st.hostname, st.hostname }) catch break :access;
        const araw = apiJson(app, a, "POST", aurl, abody, tok.key) orelse break :access;
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
        const praw = apiJson(app, a, "POST", purl, eb.items, tok.key) orelse break :access;
        const pp = std.json.parseFromSliceLeaky(A, a, praw, .{ .ignore_unknown_fields = true }) catch break :access;
        if (pp.success and pp.result != null) st.access_policy_id = pp.result.?.id;
    }

    // ---- 7. the connector's token
    const turl = std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel/{s}/token", .{ root, acct, st.tunnel_id }) catch return null;
    const traw = apiJson(app, a, "GET", turl, "", tok.key) orelse {
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

/// Take the current hostname off the account: its Access application, then its DNS record, both filed under
/// `st.zone_id`. Best-effort like `deprovision` - a refusal is logged with the API's words and never stops the
/// caller - and the ids are forgotten either way, so provisioning makes both anew for whatever name comes next.
fn retireHostname(app: *App, a: std.mem.Allocator, st: *State, tok: Tok) void {
    const root = app.cf_api_root;
    if (st.zone_id.len > 0) {
        if (st.access_app_id.len > 0) {
            if (std.fmt.allocPrint(a, "{s}/zones/{s}/access/apps/{s}", .{ root, st.zone_id, st.access_app_id })) |u| {
                const msg = if (apiJson(app, a, "DELETE", u, "", tok.key)) |r| firstError(a, r) else "could not reach the Cloudflare API";
                if (msg.len > 0) log.warn("the Access application {s} was not removed from the account ({s})", .{ st.access_app_id, msg });
            } else |_| {}
        }
        if (st.dns_record_id.len > 0) {
            if (std.fmt.allocPrint(a, "{s}/zones/{s}/dns_records/{s}", .{ root, st.zone_id, st.dns_record_id })) |u| {
                const msg = if (apiJson(app, a, "DELETE", u, "", tok.key)) |r| firstError(a, r) else "could not reach the Cloudflare API";
                if (msg.len > 0) log.warn("the DNS record {s} was not removed from the account ({s})", .{ st.dns_record_id, msg });
            } else |_| {}
        }
    }
    st.dns_record_id = "";
    st.access_app_id = "";
    st.access_policy_id = "";
}

/// Tear the account side down (delete). Best-effort, in dependency order; the state is cleared regardless.
fn deprovision(app: *App, a: std.mem.Allocator, st: *State, tok: Tok) void {
    retireHostname(app, a, st, tok);
    const root = app.cf_api_root;
    const acct = tok.account_id;
    if (st.tunnel_id.len > 0) {
        if (std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel/{s}/connections", .{ root, acct, st.tunnel_id })) |u| {
            _ = apiJson(app, a, "DELETE", u, "", tok.key);
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/accounts/{s}/cfd_tunnel/{s}", .{ root, acct, st.tunnel_id })) |u| {
            _ = apiJson(app, a, "DELETE", u, "", tok.key);
        } else |_| {}
    }
    st.* = .{};
}

// ------------------------------------------------------------------------------------------ the child
/// The hostname the world will ask DNS for: the named hostname, or the quick tunnel's trycloudflare host.
fn publicHost(st: *const State) []const u8 {
    if (std.mem.eql(u8, st.mode, "named") and st.hostname.len > 0) return st.hostname;
    return hostOf(st.url);
}

/// Does Cloudflare Access stand in front of the address being served? Only a named tunnel's hostname has an
/// Access application. A quick tunnel keeps the named ids in its state for the next "use my domain" flip, and
/// they say nothing about a trycloudflare.com address, so a policy id alone must never claim protection.
fn accessGuarded(st: *const State) bool {
    return std.mem.eql(u8, st.mode, "named") and st.access_policy_id.len > 0;
}

/// `https://host[/...]` -> `host`; "" when there is no host.
fn hostOf(url: []const u8) []const u8 {
    const rest = if (std.mem.startsWith(u8, url, "https://")) url["https://".len..] else if (std.mem.startsWith(u8, url, "http://")) url["http://".len..] else url;
    const end = std.mem.indexOfAny(u8, rest, "/:?#") orelse rest.len;
    return rest[0..end];
}

/// The dns-json verdict: NOERROR (Status 0) with at least one answer means published. NXDOMAIN is Status 3.
fn dohSaysPublished(a: std.mem.Allocator, body: []const u8) bool {
    const Reply = struct { Status: i64 = -1, Answer: ?[]const struct { data: []const u8 = "" } = null };
    const rep = std.json.parseFromSliceLeaky(Reply, a, body, .{ .ignore_unknown_fields = true }) catch return false;
    if (rep.Status != 0) return false;
    const ans = rep.Answer orelse return false;
    return ans.len > 0;
}

/// Ask Cloudflare's own resolver (DNS over HTTPS) whether `host` is published. Never the machine's resolver.
fn publishedAtCloudflare(app: *App, a: std.mem.Allocator, host: []const u8) bool {
    const url = std.fmt.allocPrint(a, DOH_URL ++ "?name={s}&type=A", .{host}) catch return false;
    const r = std.process.run(app.gpa, app.io, .{ .argv = &.{ "curl", "-sS", "--max-time", "10", "-H", "accept: application/dns-json", url }, .stdout_limit = .limited(16 << 10) }) catch return false;
    defer app.gpa.free(r.stdout);
    defer app.gpa.free(r.stderr);
    if (!(r.term == .exited and r.term.exited == 0)) return false;
    return dohSaysPublished(a, r.stdout);
}

/// Wait, up to PUBLISH_BUDGET_S, for Cloudflare's resolver to publish the hostname. Returns whether it did;
/// after the budget the URL is shown anyway, flagged `published:false`.
///
/// WHY: a quick tunnel's hostname is minted when the connector registers and reaches Cloudflare's
/// authoritative servers some seconds later. Any query from this network in that window - the owner's
/// browser, a phone on the same wifi - gets NXDOMAIN from the local resolver, which then caches the miss
/// for trycloudflare.com's negative TTL: 1800 seconds. Measured on the dev machine: a probe 4 s after
/// registration left the address unreachable for half an hour; the next address, published 9 s in and
/// asked by nobody until then, resolved everywhere at once. So nothing asks until Cloudflare says yes.
fn awaitPublished(app: *App, a: std.mem.Allocator, host: []const u8) bool {
    if (host.len == 0) return false;
    const t0 = nowS(app.io);
    while (nowS(app.io) - t0 < PUBLISH_BUDGET_S) {
        if (exited.load(.monotonic)) return false;
        if (publishedAtCloudflare(app, a, host)) return true;
        app.io.sleep(.{ .nanoseconds = 3000 * std.time.ns_per_ms }, .awake) catch {};
    }
    return false;
}

fn waiter(io: std.Io) void {
    if (live.child) |*c| {
        _ = c.wait(io) catch {};
    }
    exited.store(true, .monotonic);
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (live.phase == .live or live.phase == .starting or live.phase == .publishing) {
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
    var pb2: [700]u8 = undefined;
    const pidp = pidPath(app, uid, &pb2) orelse return "data dir path too long";
    std.Io.Dir.cwd().deleteFile(io, pidp) catch {};
    argv.appendSlice(app.gpa, &.{ st.binary, "tunnel", "--no-autoupdate", "--logfile", logp, "--pidfile", pidp }) catch return "oom";
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

/// The connector's pid from its pidfile, or null.
fn readPid(app: *App, uid: u64) ?u32 {
    var pb: [700]u8 = undefined;
    const pidp = pidPath(app, uid, &pb) orelse return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, pidp, app.gpa, .limited(64)) catch return null;
    defer app.gpa.free(raw);
    return std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \r\n\t"), 10) catch null;
}

/// Is a process with this pid alive? tasklist on Windows, kill -0 elsewhere.
fn pidAlive(app: *App, pid: u32) bool {
    var b: [24]u8 = undefined;
    const ps = std.fmt.bufPrint(&b, "{d}", .{pid}) catch return false;
    if (builtin.os.tag == .windows) {
        var fb: [40]u8 = undefined;
        const filt = std.fmt.bufPrint(&fb, "PID eq {d}", .{pid}) catch return false;
        const r = std.process.run(app.gpa, app.io, .{ .argv = &.{ "tasklist", "/FI", filt, "/NH" }, .stdout_limit = .limited(8 << 10) }) catch return false;
        defer app.gpa.free(r.stdout);
        defer app.gpa.free(r.stderr);
        return std.mem.indexOf(u8, r.stdout, "cloudflared") != null;
    }
    return runs(app, &.{ "kill", "-0", ps });
}

/// OFF MEANS OFF, VERIFIED. Zig's Windows kill issues NtTerminateProcess and ignores a refusal; observed live,
/// "off" was reported while the connector kept serving the URL. So the stop kills by PID from the pidfile
/// (taskkill /T /F, or kill -TERM then -KILL), keeps the in-process kill as well, and then POLLS until the
/// process is gone. Returns the pid still alive, or null when the connector is verifiably dead.
fn killChild(app: *App, uid: u64) ?u32 {
    const io = app.io;
    const pid = readPid(app, uid);
    mu.lockUncancelable(io);
    if (live.child) |*c| c.kill(io);
    mu.unlock(io);
    if (pid) |p| {
        var b: [24]u8 = undefined;
        const ps = std.fmt.bufPrint(&b, "{d}", .{p}) catch "0";
        if (builtin.os.tag == .windows) {
            _ = runs(app, &.{ "taskkill", "/PID", ps, "/T", "/F" });
        } else {
            _ = runs(app, &.{ "kill", "-TERM", ps });
        }
    }
    var still: ?u32 = null;
    if (pid) |p| {
        var tries: usize = 0;
        while (tries < 50 and pidAlive(app, p)) : (tries += 1) {
            if (tries == 20 and builtin.os.tag != .windows) {
                var b: [24]u8 = undefined;
                _ = runs(app, &.{ "kill", "-KILL", std.fmt.bufPrint(&b, "{d}", .{p}) catch "0" });
            }
            io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
        if (pidAlive(app, p)) still = p;
    }
    var waited: usize = 0;
    while (!exited.load(.monotonic) and live.child != null and waited < 30) : (waited += 1) io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    live.child = null;
    live.url_len = 0;
    if (still == null) {
        var pb: [700]u8 = undefined;
        if (pidPath(app, uid, &pb)) |pp| std.Io.Dir.cwd().deleteFile(io, pp) catch {};
    }
    return still;
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

    // a connector left over from a previous server instance must not run beside the new one
    if (readPid(app, uid)) |old| if (pidAlive(app, old)) {
        _ = killChild(app, uid);
    };

    setPhase(io, .provisioning);
    var token: ?[]const u8 = null;
    if (st.use_domain) {
        st.mode = "named";
        if (provisionNamed(app, a, uid, &st, .{ .key = tok.key, .base_url = tok.base_url, .account_id = tok.account_id }, prof.email)) |t| {
            token = t;
            app.vault.put(uid, TOKEN_PROVIDER, t, "") catch |e| log.warn("tunnel token could not be sealed into the vault ({t}); it is not persisted", .{e});
        } else {
            if (st.last_error.len == 0) st.last_error = "provisioning the tunnel on your account failed";
            writeState(app, uid, st);
            setErr(io, st.last_error);
            return;
        }
    } else {
        // THE DEFAULT: a confidential address. No tunnel, no DNS, nothing on any domain the user owns - a
        // random trycloudflare.com hostname that only the owner is ever shown, and that changes each start.
        st.mode = "quick";
        st.url = "";
    }
    writeState(app, uid, st);

    if (startChild(app, a, uid, &st, token)) |err| {
        _ = killChild(app, uid);
        st.last_error = err;
        writeState(app, uid, st);
        setErr(io, err);
        return;
    }
    writeState(app, uid, st);
    // HOLD THE ADDRESS BACK until Cloudflare's own resolver publishes it. The first DNS query from this
    // network decides whether the URL works for the next half hour (see awaitPublished) - so nothing, not
    // the status poll, not the owner's browser, gets to ask before Cloudflare answers.
    setPhase(io, .publishing);
    const published = awaitPublished(app, a, publicHost(&st));
    if (exited.load(.monotonic)) {
        st.last_error = "cloudflared exited while the address was being published - see cf_tunnel.log in the user's data dir";
        writeState(app, uid, st);
        setErr(io, st.last_error);
        return;
    }
    {
        mu.lockUncancelable(io);
        defer mu.unlock(io);
        live.phase = .live;
        live.published = published;
        live.access = accessGuarded(&st);
        const ml = @min(st.mode.len, live.mode.len);
        @memcpy(live.mode[0..ml], st.mode[0..ml]);
        live.mode_len = ml;
    }
    setUrl(io, st.url);
    log.info("Cloudflare tunnel: {s}  ({s}{s}{s})", .{ st.url, if (std.mem.eql(u8, st.mode, "quick")) "confidential address" else st.hostname, if (accessGuarded(&st)) ", Access: owner only" else ", veil login only", if (published) "" else "; NOT yet published by Cloudflare's resolver - give it a minute" });
}

/// Stop the connector; with `delete`, also remove the tunnel, its DNS record and its Access app from the
/// account and forget the sealed token.
pub fn turnOff(app: *App, uid: u64, delete: bool) void {
    const io = app.io;
    const still = killChild(app, uid);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = readState(app, uid, a);
    st.want_on = false;
    st.last_error = "";
    if (still) |p| {
        // never say "off" over a connector that is still serving the URL
        st.last_error = std.fmt.allocPrint(a, "could not stop cloudflared (pid {d}) - end that process yourself; the URL stays reachable until it is gone", .{p}) catch "could not stop cloudflared";
        writeState(app, uid, st);
        setErr(io, st.last_error);
        return;
    }
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

/// Stop the connector when the server shuts down in order, so it does not outlive the server it proxies to.
/// main calls it when the desk window closes (app mode) and when `listen` returns (server-only). The switch
/// position is left alone: a tunnel that was on comes back at the next boot. A server that is KILLED runs none
/// of this; its connector is reaped by the next turnOn through the pidfile, or, in app mode on Windows, dies with
/// the kill-on-close job the whole process tree lives in (unless NL_NO_JOB_OBJECT is set).
pub fn shutdown(app: *App) void {
    mu.lockUncancelable(app.io);
    const uid = live.uid;
    mu.unlock(app.io);
    if (uid != 0) _ = killChild(app, uid);
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
    var published = false;
    {
        mu.lockUncancelable(app.io);
        defer mu.unlock(app.io);
        phase = live.phase;
        published = live.published;
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
    try out.print(app.gpa, "{{\"ok\":true,\"connected\":{},\"admin\":{},\"state\":\"{s}\",\"on\":{},\"busy\":{},\"live\":{},\"published\":{},\"access\":{},\"since\":{d},\"open_registration\":{},\"use_domain\":{},\"url\":", .{ connected, admin, phaseName(phase), st.want_on, busy, phase == .live, phase == .live and published, access, since, app.open_registration, st.use_domain });
    try http.jstr(app.gpa, &out, url);
    try out.appendSlice(app.gpa, ",\"want_hostname\":");
    try http.jstr(app.gpa, &out, if (admin) st.want_hostname else "");
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

const SetReq = struct { on: bool, delete: bool = false, use_domain: ?bool = null, hostname: ?[]const u8 = null };

/// POST /api/v1/oauth/cloudflare/tunnel {on[, delete]} — the switch. Owner only. Answers at once; the work
/// runs on its own thread and the status poll reports the phases and then the URL.
pub fn tunnelSet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireAdmin(app, req, res) orelse return;
    const body = (req.json(SetReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (body.on) {
        if (app.open_registration) return badReq(res, "open registration is on: close it (NL_OPEN_REGISTRATION=0) before exposing this server");
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (cf_oauth.resolveToken(app, u.id, a) == null) return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
        // the choice rides with the flip and is remembered: confidential (default) or one of the user's domains
        var st = readState(app, u.id, a);
        var changed = false;
        if (body.use_domain) |ud| {
            changed = changed or ud != st.use_domain;
            st.use_domain = ud;
        }
        if (body.hostname) |h| {
            const t = std.mem.trim(u8, h, " \r\n\t");
            if (t.len > 0 and !hostnameOk(t)) return badReq(res, "hostname must be lowercase letters, digits, dots and hyphens, like veil.example.com");
            if (!std.mem.eql(u8, t, st.want_hostname)) {
                changed = true;
                st.want_hostname = t;
                st.hostname = ""; // re-derive the effective hostname from the new request
            }
        }
        writeState(app, u.id, st);
        {
            mu.lockUncancelable(app.io);
            defer mu.unlock(app.io);
            if (live.busy) return badReq(res, "a switch flip is already in progress");
            // ALREADY ON with the same choice: say so, do not restart it. A restart would mint a new address
            // and drop every open session for nothing - and the old URL was on display while it happened.
            const running = live.phase == .live or live.phase == .starting or live.phase == .publishing;
            if (running and !changed) {
                try res.json(.{ .ok = true, .on = true, .state = phaseName(live.phase), .already = true }, .{});
                return;
            }
            live.phase = .installing;
            live.err_len = 0;
            live.url_len = 0; // nothing of the previous address may show while the next one is minted
            live.published = false;
            live.access = false; // nor its protection: turnOn says again once the new address is live
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
// state file round-trips its defaults, the token never appears in the state, Access is never claimed for an
// address it does not guard, and - against a stand-in API (worker/fakehttp.zig) - a hostname change moves the
// DNS record and the Access app with it.
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

test "the resolver verdict: published means NOERROR with an answer; NXDOMAIN and empty answers are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(dohSaysPublished(a, "{\"Status\":0,\"TC\":false,\"Question\":[{\"name\":\"x.trycloudflare.com\",\"type\":1}],\"Answer\":[{\"name\":\"x.trycloudflare.com\",\"type\":1,\"TTL\":300,\"data\":\"104.16.230.132\"}]}"));
    try std.testing.expect(!dohSaysPublished(a, "{\"Status\":3,\"TC\":false,\"Question\":[{\"name\":\"x.trycloudflare.com\",\"type\":1}],\"Authority\":[{\"name\":\"trycloudflare.com\",\"type\":6,\"TTL\":1800,\"data\":\"soa\"}]}"));
    try std.testing.expect(!dohSaysPublished(a, "{\"Status\":0,\"Answer\":[]}"));
    try std.testing.expect(!dohSaysPublished(a, "not json"));
    try std.testing.expectEqualStrings("a-b-c.trycloudflare.com", hostOf("https://a-b-c.trycloudflare.com"));
    try std.testing.expectEqualStrings("veil.example.com", hostOf("https://veil.example.com/api/v1/health"));
    try std.testing.expectEqualStrings("", hostOf(""));
    // the quick tunnel asks for ITS host even when a named hostname lingers from an earlier provision
    var st: State = .{ .mode = "quick", .hostname = "veil.example.com", .url = "https://q.trycloudflare.com" };
    try std.testing.expectEqualStrings("q.trycloudflare.com", publicHost(&st));
    st.mode = "named";
    try std.testing.expectEqualStrings("veil.example.com", publicHost(&st));
}

test "state round-trips through its JSON with defaults, and carries no token field" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(State, gpa, "{\"want_on\":true,\"hostname\":\"veil.example.com\"}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.want_on);
    try std.testing.expectEqualStrings("veil.example.com", parsed.value.hostname);
    try std.testing.expectEqualStrings("", parsed.value.tunnel_id);
    try std.testing.expect(!@hasField(State, "token"));
    try std.testing.expect(!parsed.value.use_domain); // confidential by default
    try std.testing.expect(releaseAsset() != null or builtin.os.tag == .freestanding);
    try std.testing.expect(hostnameOk("veil.example.com"));
    try std.testing.expect(hostnameOk("veil-2.sub.example.co.uk"));
    try std.testing.expect(!hostnameOk("Veil.example.com"));
    try std.testing.expect(!hostnameOk("localhost"));
    try std.testing.expect(!hostnameOk("a..b"));
    try std.testing.expect(!hostnameOk("-x.example.com"));
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

test "Access is claimed only for a named tunnel's hostname, and a hostname is on a zone only at a label boundary" {
    // a quick tunnel started after a named one: the named policy id is still in the state, and guards nothing here
    var st: State = .{ .mode = "quick", .url = "https://q.trycloudflare.com", .hostname = "veil.example.com", .access_app_id = "app-1", .access_policy_id = "pol-1" };
    try std.testing.expect(!accessGuarded(&st));
    st.mode = "named";
    try std.testing.expect(accessGuarded(&st));
    st.access_policy_id = ""; // an app whose policy was never made admits nobody, but it is not "owner only" either
    try std.testing.expect(!accessGuarded(&st));

    try std.testing.expect(onZone("veil.example.com", "example.com"));
    try std.testing.expect(onZone("example.com", "example.com"));
    try std.testing.expect(onZone("a.b.example.co.uk", "example.co.uk"));
    try std.testing.expect(!onZone("veil.badexample.com", "example.com")); // a suffix, not a subdomain
    try std.testing.expect(!onZone("example.com.evil.net", "example.com"));
    try std.testing.expect(!onZone("veil.example.com", ""));
}

/// TEST ONLY. The replies every provisioning scenario below shares.
const StandIn = struct {
    const w = fakehttp.wire;
    const deleted = w("{\"success\":true,\"errors\":[],\"result\":{\"id\":\"gone\"}}");
    const ingress = w("{\"success\":true,\"errors\":[],\"result\":{}}");
    const token = w("{\"success\":true,\"errors\":[],\"result\":\"tunnel-token\"}");
    const no_records = w("{\"success\":true,\"errors\":[],\"result\":[]}");
    /// What a route the scenario did not expect gets - including GET access/organizations where a scenario
    /// lists no route for it, which reads exactly like an account without a Zero Trust organization.
    const refused = w("{\"success\":false,\"errors\":[{\"code\":7003,\"message\":\"no such route in the stand-in\"}]}");
};

test "a hostname change on the same zone retires the old DNS record and Access app and provisions both for the new name" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftun-rename-tmp");
    defer ta.deinit();
    if (!runs(&ta.app, &.{ "curl", "--version" })) return error.SkipZigTest; // every v4 call rides curl

    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/zones/z1/dns_records?name=chat.example.com", .reply = StandIn.no_records },
        .{ .method = "DELETE", .path = "/zones/z1/access/apps/app-old", .reply = StandIn.deleted },
        .{ .method = "DELETE", .path = "/zones/z1/dns_records/rec-old", .reply = StandIn.deleted },
        .{ .method = "PUT", .path = "/cfd_tunnel/t1/configurations", .reply = StandIn.ingress },
        .{ .method = "POST", .path = "/zones/z1/dns_records", .reply = w("{\"success\":true,\"errors\":[],\"result\":{\"id\":\"rec-new\"}}") },
        .{ .method = "GET", .path = "/accounts/acct/access/organizations", .reply = w("{\"success\":true,\"errors\":[],\"result\":{\"auth_domain\":\"team.cloudflareaccess.com\"}}") },
        .{ .method = "POST", .path = "/access/apps/app-new/policies", .reply = w("{\"success\":true,\"errors\":[],\"result\":{\"id\":\"pol-new\"}}") },
        .{ .method = "POST", .path = "/zones/z1/access/apps", .reply = w("{\"success\":true,\"errors\":[],\"result\":{\"id\":\"app-new\"}}") },
        .{ .method = "GET", .path = "/cfd_tunnel/t1/token", .reply = StandIn.token },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.refused);
    var running = true;
    defer if (running) srv.stop();
    var rb: [64]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // What tunnelSet leaves when chat.example.com replaces veil.example.com: the hostname cleared, every id kept.
    var st: State = .{ .use_domain = true, .want_hostname = "chat.example.com", .mode = "named", .tunnel_id = "t1", .zone_id = "z1", .zone_name = "example.com", .dns_record_id = "rec-old", .access_app_id = "app-old", .access_policy_id = "pol-old" };
    const token = provisionNamed(&ta.app, arena.allocator(), 1, &st, .{ .key = "k", .base_url = "", .account_id = "acct" }, "owner@example.com");
    srv.stop();
    running = false;

    try std.testing.expectEqualStrings("tunnel-token", token orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("chat.example.com", st.hostname);
    try std.testing.expectEqualStrings("https://chat.example.com", st.url);
    // The new name has a record and an Access app of its own. Before, both ids survived the change: no CNAME
    // was made for chat.example.com, and the status claimed Access for a name no Access app covered.
    try std.testing.expectEqualStrings("rec-new", st.dns_record_id);
    try std.testing.expectEqualStrings("app-new", st.access_app_id);
    try std.testing.expectEqualStrings("pol-new", st.access_policy_id);
    try std.testing.expect(accessGuarded(&st));
    // the old name came off the account before the new record was made, and the zone was not listed again
    const retired = srv.firstCall("DELETE", "/zones/z1/dns_records/rec-old") orelse return error.TestUnexpectedResult;
    try std.testing.expect(srv.firstCall("DELETE", "/zones/z1/access/apps/app-old") != null);
    try std.testing.expect(retired < (srv.firstCall("POST", "/zones/z1/dns_records") orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(usize, 0), srv.countCalls("GET", "/zones?"));
}

test "a move to another zone retires the old name on the OLD zone, and asking by name for the hostname in use changes nothing" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftun-move-tmp");
    defer ta.deinit();
    if (!runs(&ta.app, &.{ "curl", "--version" })) return error.SkipZigTest;
    const w = fakehttp.wire;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tok: Tok = .{ .key = "k", .base_url = "", .account_id = "acct" };
    var rb: [64]u8 = undefined;

    // ---- veil.example.com -> veil.other.org, a zone of its own on the same account (no Zero Trust org)
    {
        const routes = [_]fakehttp.Route{
            .{ .method = "GET", .path = "/zones?account.id=acct", .reply = w("{\"success\":true,\"errors\":[],\"result\":[{\"id\":\"z1\",\"name\":\"example.com\"},{\"id\":\"z2\",\"name\":\"other.org\"}]}") },
            .{ .method = "DELETE", .path = "/zones/z1/access/apps/app-old", .reply = StandIn.deleted },
            .{ .method = "DELETE", .path = "/zones/z1/dns_records/rec-old", .reply = StandIn.deleted },
            .{ .method = "GET", .path = "/zones/z2/dns_records?name=veil.other.org", .reply = StandIn.no_records },
            .{ .method = "PUT", .path = "/cfd_tunnel/t1/configurations", .reply = StandIn.ingress },
            .{ .method = "POST", .path = "/zones/z2/dns_records", .reply = w("{\"success\":true,\"errors\":[],\"result\":{\"id\":\"rec-2\"}}") },
            .{ .method = "GET", .path = "/cfd_tunnel/t1/token", .reply = StandIn.token },
        };
        var srv: fakehttp.Server = undefined;
        try srv.startRouted(io, &routes, StandIn.refused);
        var running = true;
        defer if (running) srv.stop();
        ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
        var st: State = .{ .use_domain = true, .want_hostname = "veil.other.org", .mode = "named", .tunnel_id = "t1", .zone_id = "z1", .zone_name = "example.com", .hostname = "", .dns_record_id = "rec-old", .access_app_id = "app-old", .access_policy_id = "pol-old" };
        const token = provisionNamed(&ta.app, arena.allocator(), 1, &st, tok, "owner@example.com");
        srv.stop();
        running = false;

        try std.testing.expect(token != null);
        try std.testing.expectEqualStrings("z2", st.zone_id);
        try std.testing.expectEqualStrings("other.org", st.zone_name);
        try std.testing.expectEqualStrings("veil.other.org", st.hostname);
        try std.testing.expectEqualStrings("rec-2", st.dns_record_id);
        // the old zone's Access app is gone and the new zone has none: the status must not claim one
        try std.testing.expectEqualStrings("", st.access_app_id);
        try std.testing.expect(!accessGuarded(&st));
        try std.testing.expectEqual(@as(usize, 2), srv.countCalls("DELETE", "/zones/z1/"));
        try std.testing.expectEqual(@as(usize, 0), srv.countCalls("DELETE", "/zones/z2/"));
    }

    // ---- want_hostname moved from "" to veil.example.com, the name the tunnel already has: nothing churns
    {
        const routes = [_]fakehttp.Route{
            .{ .method = "GET", .path = "/zones/z1/dns_records?name=veil.example.com", .reply = w("{\"success\":true,\"errors\":[],\"result\":[{\"id\":\"rec-1\",\"content\":\"t1.cfargotunnel.com\"}]}") },
            .{ .method = "PUT", .path = "/cfd_tunnel/t1/configurations", .reply = StandIn.ingress },
            .{ .method = "GET", .path = "/cfd_tunnel/t1/token", .reply = StandIn.token },
        };
        var srv: fakehttp.Server = undefined;
        try srv.startRouted(io, &routes, StandIn.refused);
        var running = true;
        defer if (running) srv.stop();
        ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
        var st: State = .{ .use_domain = true, .want_hostname = "veil.example.com", .mode = "named", .tunnel_id = "t1", .zone_id = "z1", .zone_name = "example.com", .hostname = "", .dns_record_id = "rec-1", .access_app_id = "app-1", .access_policy_id = "pol-1" };
        const token = provisionNamed(&ta.app, arena.allocator(), 1, &st, tok, "owner@example.com");
        srv.stop();
        running = false;

        try std.testing.expect(token != null);
        try std.testing.expectEqualStrings("veil.example.com", st.hostname);
        try std.testing.expectEqualStrings("rec-1", st.dns_record_id);
        try std.testing.expectEqualStrings("app-1", st.access_app_id);
        try std.testing.expectEqualStrings("pol-1", st.access_policy_id);
        try std.testing.expectEqual(@as(usize, 0), srv.countCalls("DELETE", ""));
        try std.testing.expectEqual(@as(usize, 0), srv.countCalls("POST", ""));
    }
}
