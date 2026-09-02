//! cftools.zig — the CLOUDFLARE TOOL BELT: what the veil can do with a connected Cloudflare account.
//!
//! A login (src/config/cf_oauth.zig) connects the USER'S own account, never ours — so once they connect,
//! the assistant should be able to BUILD ON IT, not just run inference against it. These tools are the
//! difference between "Cloudflare is where my model runs" and "Cloudflare is where my app lives": write
//! a Worker and ship it to a live URL, keep state in R2 / D1 / KV, and reach anything else on the REST
//! surface through one generic escape hatch.
//!
//! CREDENTIALS. Nothing here resolves a token: the chat surfaces resolve ONE per turn (cf_oauth
//! .resolveToken, which auto-refreshes) and hand the pair down on ToolCtx as cf_token + cf_account.
//! Blank ⇒ the whole family is unadvertised AND refuses, so a swarm mind, the CLI and any non-chat
//! caller are structurally unable to touch the user's cloud — the same shape `durable_path` uses to
//! keep user credentials out of the hive.
//!
//! SCOPES ARE THE USER'S TO GIVE. The registered OAuth client may ASK for build-and-deploy permissions
//! (Workers, Pages, D1, KV, R2, Queues, Vectorize, Routes, Tail) on top of the identity + Workers AI
//! minimum, but the deploy half is declared OPTIONAL: a user who only wants chat declines it on the
//! consent screen and still logs in. A declined scope is not a crash — Cloudflare refuses the call and
//! `answer()` hands the model Cloudflare's own words, which is exactly the sentence a user needs to see.
//! Deliberately never requested at all: DNS, zones, security posture, billing, memberships. A tool here
//! can ship an app and spend the user's money; it cannot repoint their domain or disable their WAF.
//!
//! TRANSPORT. curl, exactly as cf_oauth does it, and for the same reason: the bearer rides a curl config
//! file (-K) and request bodies ride a scratch file, so no secret and no payload ever lands on the argv
//! where another process could read it off the process table.

const std = @import("std");

/// Per-call context — the slice of ToolCtx this module needs, passed explicitly so cftools never has to
/// import tools.zig (which imports this file).
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Scratch dir for curl body/config files — the run dir, which is per-run and already private.
    scratch: []const u8,
    /// Jail for file arguments. A tool may only read/write inside it (see safeRel).
    workdir: []const u8,
    token: []const u8,
    account: []const u8,
    /// The v4 root every URL below hangs off. Defaults to the real API; a caller may substitute a
    /// LOOPBACK stand-in (main.zig honours NL_CF_API_ROOT only for 127.0.0.1/localhost) so the belt
    /// can be driven by scripts/sim/cfworld.py without touching an account. Never anything else: the
    /// OAuth token is minted for api.cloudflare.com, and any other host would simply be handed it.
    api_root: []const u8 = API,
};

/// The Cloudflare v4 API root. The one host the bearer may be sent to — see Ctx.api_root for the only
/// exception, and isLoopbackRoot for the rule that keeps it an exception.
pub const API = "https://api.cloudflare.com/client/v4";

/// True for a root a stand-in may live on: plain http on the loopback address, nothing else. This is the
/// gate main.zig applies to NL_CF_API_ROOT, and the reason an override can never leak the token — the
/// only place it can be pointed is a process on the same machine as the user.
pub fn isLoopbackRoot(root: []const u8) bool {
    if (root.len < 18 or root.len > 200) return false;
    const ok = std.mem.startsWith(u8, root, "http://127.0.0.1:") or std.mem.startsWith(u8, root, "http://localhost:");
    if (!ok) return false;
    for (root) |c| if (c <= 0x20 or c == '@' or c == '\\' or c == '#' or c == '?') return false;
    return std.mem.indexOfPos(u8, root, 7, "://") == null;
}

const MAX_BODY = 8 << 20; // response cap — a listing or a script, never a data lake
const MAX_UPLOAD = 24 << 20; // one object/script upload; R2's REST cap is far higher, this is ours

// ------------------------------------------------------------------------------------ path safety

/// The one rule for every file argument: a RELATIVE path inside the workdir. No absolute paths, no
/// drive letters, no "..", no leading slash. A tool that ships files to the internet must never be
/// able to name ~/.ssh/id_rsa, so this is checked before the path is joined, not after.
pub fn safeRel(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > 400) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    if (std.mem.indexOf(u8, rel, "..") != null) return false;
    if (rel.len > 1 and rel[1] == ':') return false; // C:\...
    for (rel) |c| if (c < 0x20) return false;
    return true;
}

fn joinWork(ctx: Ctx, rel: []const u8, buf: []u8) ?[]const u8 {
    if (!safeRel(rel)) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ ctx.workdir, rel }) catch null;
}

// ------------------------------------------------------------------------------------ transport

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast(s[0..0]);
}

/// One outbound HTTPS call. `extra` carries additional curl argv (multipart -F parts, say) that is safe
/// to expose — never a secret. The bearer always rides the -K config file. Returns the response body.
fn call(ctx: Ctx, method: []const u8, url: []const u8, body: []const u8, content_type: []const u8, extra: []const []const u8) ?[]u8 {
    const gpa = ctx.gpa;
    var sfx: [8]u8 = undefined;
    ctx.io.random(&sfx);
    const tag = std.fmt.bytesToHex(sfx, .lower);

    var body_pb: [700]u8 = undefined;
    var cfg_pb: [700]u8 = undefined;
    const body_path = std.fmt.bufPrint(&body_pb, "{s}/.cfapi-body-{s}", .{ ctx.scratch, tag }) catch return null;
    const cfg_path = std.fmt.bufPrint(&cfg_pb, "{s}/.cfapi-cfg-{s}", .{ ctx.scratch, tag }) catch return null;
    var wrote_body = false;
    var wrote_cfg = false;
    defer if (wrote_body) std.Io.Dir.cwd().deleteFile(ctx.io, body_path) catch {};
    defer if (wrote_cfg) std.Io.Dir.cwd().deleteFile(ctx.io, cfg_path) catch {};

    if (body.len > 0) {
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = body_path, .data = body }) catch return null;
        wrote_body = true;
    }
    {
        var cfg: std.ArrayListUnmanaged(u8) = .empty;
        defer cfg.deinit(gpa);
        cfg.appendSlice(gpa, "silent\nshow-error\n") catch return null;
        cfg.appendSlice(gpa, "header = \"Authorization: Bearer ") catch return null;
        cfg.appendSlice(gpa, ctx.token) catch return null;
        cfg.appendSlice(gpa, "\"\n") catch return null;
        if (body.len > 0 and content_type.len > 0) {
            cfg.appendSlice(gpa, "header = \"Content-Type: ") catch return null;
            cfg.appendSlice(gpa, content_type) catch return null;
            cfg.appendSlice(gpa, "\"\n") catch return null;
        }
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = cfg_path, .data = cfg.items }) catch return null;
        wrote_cfg = true;
    }

    var data_at_buf: [710]u8 = undefined;
    const data_at = std.fmt.bufPrint(&data_at_buf, "@{s}", .{body_path}) catch return null;
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sS", "--max-time", "120", "-X", method, "-K", cfg_path }) catch return null;
    if (body.len > 0) av.appendSlice(gpa, &.{ "--data-binary", data_at }) catch return null;
    av.appendSlice(gpa, extra) catch return null;
    av.append(gpa, url) catch return null;

    const run = std.process.run(gpa, ctx.io, .{ .argv = av.items, .stdout_limit = .limited(MAX_BODY) }) catch return null;
    gpa.free(run.stderr);
    if (run.stdout.len == 0) {
        gpa.free(run.stdout);
        return null;
    }
    return run.stdout;
}

/// Cloudflare wraps every v4 answer in {success, errors[], result}. Pull the first error message out so a
/// failure reaches the model as Cloudflare's own words ("R2 subscription required", "insufficient
/// permissions") rather than as a shrug — the model can act on the former and only apologises for the
/// latter. This is also how a DECLINED optional scope surfaces: as the reason, not as a mystery.
fn errOf(gpa: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const R = struct {
        success: bool = false,
        errors: []const struct { code: i64 = 0, message: []const u8 = "" } = &.{},
    };
    const p = std.json.parseFromSlice(R, gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    if (p.value.success) return null;
    if (p.value.errors.len == 0) return null;
    return gpa.dupe(u8, p.value.errors[0].message) catch null;
}

/// The shared shape of a REST answer: Cloudflare's error text when it failed, else the raw body (the
/// model reads the JSON — it is better at that than any summary this layer could invent).
fn answer(ctx: Ctx, raw: ?[]u8, what: []const u8) []u8 {
    const gpa = ctx.gpa;
    const body = raw orelse return std.fmt.allocPrint(gpa, "{s}: could not reach the Cloudflare API (offline, or curl is missing)", .{what}) catch dupe(gpa, "cloudflare unreachable");
    defer gpa.free(body);
    if (errOf(gpa, body)) |msg| {
        defer gpa.free(msg);
        return std.fmt.allocPrint(gpa, "{s} FAILED — Cloudflare says: {s}", .{ what, msg }) catch dupe(gpa, "cloudflare error");
    }
    return dupe(gpa, body);
}

// ------------------------------------------------------------------------------------ the tools

/// PUT a Worker script and turn on its workers.dev route, so the reply is a URL the user can open.
/// Modules format (main_module), which is what every current Worker template ships.
fn deployWorker(ctx: Ctx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { name: []const u8 = "", file: []const u8 = "", compatibility_date: []const u8 = "2026-01-01" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const name = std.mem.trim(u8, p.value.name, " \r\n\t");
    const file = std.mem.trim(u8, p.value.file, " \r\n\t");
    if (name.len == 0 or file.len == 0) return dupe(gpa, "cf_deploy_worker needs name and file");
    // A script name lands in a URL and a hostname — keep it to what Cloudflare accepts there.
    if (name.len > 63) return dupe(gpa, "worker name is too long");
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return dupe(gpa, "worker name must be lowercase letters, digits, - or _");
    }
    var fb: [900]u8 = undefined;
    const full = joinWork(ctx, file, &fb) orelse return dupe(gpa, "file must be a relative path inside the workspace");
    const st = std.Io.Dir.cwd().statFile(ctx.io, full, .{}) catch return std.fmt.allocPrint(gpa, "no such file in the workspace: {s}", .{file}) catch dupe(gpa, "no such file");
    if (st.size > MAX_UPLOAD) return dupe(gpa, "worker script is too large to upload");

    // multipart: a metadata part naming the entry module, and the module itself. The file path is not a
    // secret, so it may ride the argv; the token still does not (it is in the -K config).
    var meta_b: [400]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_b, "metadata={{\"main_module\":\"worker.mjs\",\"compatibility_date\":\"{s}\"}};type=application/json", .{p.value.compatibility_date}) catch return dupe(gpa, "oom");
    var part_b: [980]u8 = undefined;
    const part = std.fmt.bufPrint(&part_b, "worker.mjs=@{s};type=application/javascript+module", .{full}) catch return dupe(gpa, "oom");
    var url_b: [400]u8 = undefined;
    const url = std.fmt.bufPrint(&url_b, "{s}/accounts/{s}/workers/scripts/{s}", .{ ctx.api_root, ctx.account, name }) catch return dupe(gpa, "oom");

    const raw = call(ctx, "PUT", url, "", "", &.{ "-F", meta, "-F", part });
    const body = raw orelse return dupe(gpa, "deploy: could not reach the Cloudflare API");
    defer gpa.free(body);
    if (errOf(gpa, body)) |msg| {
        defer gpa.free(msg);
        return std.fmt.allocPrint(gpa, "deploy FAILED — Cloudflare says: {s}", .{msg}) catch dupe(gpa, "deploy failed");
    }

    // Uploaded. Enable the workers.dev route and resolve the account's subdomain so the answer is a URL
    // rather than "it worked, go find it". Both legs are best-effort: the script IS deployed either way.
    var sub_url_b: [400]u8 = undefined;
    if (std.fmt.bufPrint(&sub_url_b, "{s}/accounts/{s}/workers/scripts/{s}/subdomain", .{ ctx.api_root, ctx.account, name })) |su| {
        if (call(ctx, "POST", su, "{\"enabled\":true}", "application/json", &.{})) |r| gpa.free(r);
    } else |_| {}
    var acct_sub: []const u8 = "";
    var sub_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&sub_url_b, "{s}/accounts/{s}/workers/subdomain", .{ ctx.api_root, ctx.account })) |su| {
        if (call(ctx, "GET", su, "", "", &.{})) |r| {
            defer gpa.free(r);
            const S = struct { result: struct { subdomain: []const u8 = "" } = .{} };
            if (std.json.parseFromSlice(S, gpa, r, .{ .ignore_unknown_fields = true })) |sp| {
                defer sp.deinit();
                const s = sp.value.result.subdomain;
                if (s.len > 0 and s.len < sub_buf.len) {
                    @memcpy(sub_buf[0..s.len], s);
                    acct_sub = sub_buf[0..s.len];
                }
            } else |_| {}
        }
    } else |_| {}

    if (acct_sub.len > 0)
        return std.fmt.allocPrint(gpa, "deployed {s} — live at https://{s}.{s}.workers.dev (the first request may take a few seconds)", .{ name, name, acct_sub }) catch dupe(gpa, "deployed");
    return std.fmt.allocPrint(gpa, "deployed {s} to the account. The workers.dev subdomain could not be read — its URL is on the Cloudflare dashboard.", .{name}) catch dupe(gpa, "deployed");
}

/// List R2 buckets, or the objects inside one.
fn r2List(ctx: Ctx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { bucket: []const u8 = "", prefix: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const bucket = std.mem.trim(u8, p.value.bucket, " \r\n\t");
    if (bucket.len > 0 and !safeRel(bucket)) return dupe(gpa, "bad bucket name");
    var url_b: [700]u8 = undefined;
    const url = if (bucket.len == 0)
        std.fmt.bufPrint(&url_b, "{s}/accounts/{s}/r2/buckets", .{ ctx.api_root, ctx.account }) catch return dupe(gpa, "oom")
    else
        std.fmt.bufPrint(&url_b, "{s}/accounts/{s}/r2/buckets/{s}/objects?per_page=100&prefix={s}", .{ ctx.api_root, ctx.account, bucket, p.value.prefix }) catch return dupe(gpa, "oom");
    return answer(ctx, call(ctx, "GET", url, "", "", &.{}), "r2 list");
}

/// Upload one workspace file (or inline text) to an R2 bucket.
fn r2Put(ctx: Ctx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { bucket: []const u8 = "", key: []const u8 = "", file: []const u8 = "", text: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const bucket = std.mem.trim(u8, p.value.bucket, " \r\n\t");
    const key = std.mem.trim(u8, p.value.key, " \r\n\t");
    if (bucket.len == 0 or key.len == 0) return dupe(gpa, "cf_r2_put needs bucket and key");
    if (!safeRel(bucket)) return dupe(gpa, "bad bucket name");
    if (!safeRel(key)) return dupe(gpa, "object key must look like a relative path (no .., no leading /)");

    var data: []u8 = &.{};
    var owned = false;
    defer if (owned) gpa.free(data);
    if (p.value.file.len > 0) {
        var fb: [900]u8 = undefined;
        const full = joinWork(ctx, std.mem.trim(u8, p.value.file, " \r\n\t"), &fb) orelse return dupe(gpa, "file must be a relative path inside the workspace");
        data = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, gpa, .limited(MAX_UPLOAD)) catch return dupe(gpa, "could not read that file from the workspace");
        owned = true;
    } else {
        data = @constCast(p.value.text);
    }
    if (data.len == 0) return dupe(gpa, "nothing to upload — give either file or text");

    var url_b: [700]u8 = undefined;
    const url = std.fmt.bufPrint(&url_b, "{s}/accounts/{s}/r2/buckets/{s}/objects/{s}", .{ ctx.api_root, ctx.account, bucket, key }) catch return dupe(gpa, "oom");
    const raw = call(ctx, "PUT", url, data, "application/octet-stream", &.{});
    const body = raw orelse return dupe(gpa, "r2 put: could not reach the Cloudflare API");
    defer gpa.free(body);
    if (errOf(gpa, body)) |msg| {
        defer gpa.free(msg);
        return std.fmt.allocPrint(gpa, "r2 put FAILED — Cloudflare says: {s}", .{msg}) catch dupe(gpa, "r2 put failed");
    }
    return std.fmt.allocPrint(gpa, "uploaded {d} bytes to r2://{s}/{s}", .{ data.len, bucket, key }) catch dupe(gpa, "uploaded");
}

/// Download an R2 object into the workspace.
fn r2Get(ctx: Ctx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { bucket: []const u8 = "", key: []const u8 = "", file: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const bucket = std.mem.trim(u8, p.value.bucket, " \r\n\t");
    const key = std.mem.trim(u8, p.value.key, " \r\n\t");
    if (bucket.len == 0 or key.len == 0) return dupe(gpa, "cf_r2_get needs bucket and key");
    if (!safeRel(bucket)) return dupe(gpa, "bad bucket name");
    if (!safeRel(key)) return dupe(gpa, "object key must look like a relative path");
    const rel = if (p.value.file.len > 0) std.mem.trim(u8, p.value.file, " \r\n\t") else key;
    var fb: [900]u8 = undefined;
    const full = joinWork(ctx, rel, &fb) orelse return dupe(gpa, "file must be a relative path inside the workspace");

    var url_b: [700]u8 = undefined;
    const url = std.fmt.bufPrint(&url_b, "{s}/accounts/{s}/r2/buckets/{s}/objects/{s}", .{ ctx.api_root, ctx.account, bucket, key }) catch return dupe(gpa, "oom");
    const raw = call(ctx, "GET", url, "", "", &.{}) orelse return dupe(gpa, "r2 get: could not reach the Cloudflare API");
    defer gpa.free(raw);
    // A miss comes back as the v4 error envelope; a hit is the object's own bytes.
    if (errOf(gpa, raw)) |msg| {
        defer gpa.free(msg);
        return std.fmt.allocPrint(gpa, "r2 get FAILED — Cloudflare says: {s}", .{msg}) catch dupe(gpa, "r2 get failed");
    }
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = full, .data = raw }) catch return dupe(gpa, "could not write that file into the workspace");
    return std.fmt.allocPrint(gpa, "wrote {d} bytes to {s} (from r2://{s}/{s})", .{ raw.len, rel, bucket, key }) catch dupe(gpa, "downloaded");
}

/// Run SQL against a D1 database, by database id.
fn d1Query(ctx: Ctx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { database_id: []const u8 = "", sql: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const db = std.mem.trim(u8, p.value.database_id, " \r\n\t");
    const sql = std.mem.trim(u8, p.value.sql, " \r\n\t");
    if (sql.len == 0) return dupe(gpa, "cf_d1_query needs sql");
    if (db.len == 0) return dupe(gpa, "cf_d1_query needs database_id — list them with cf_api GET /accounts/{account_id}/d1/database");
    if (!safeRel(db)) return dupe(gpa, "bad database_id");

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(gpa);
    body.appendSlice(gpa, "{\"sql\":") catch return dupe(gpa, "oom");
    // valueAlloc is the codebase's JSON-escape of choice (tools.zig uses it the same way): SQL text
    // carries quotes and newlines, and hand-concatenating it would build a torn request body.
    const sql_json = std.json.Stringify.valueAlloc(gpa, sql, .{}) catch return dupe(gpa, "oom");
    defer gpa.free(sql_json);
    body.appendSlice(gpa, sql_json) catch return dupe(gpa, "oom");
    body.append(gpa, '}') catch return dupe(gpa, "oom");

    var url_b: [700]u8 = undefined;
    const url = std.fmt.bufPrint(&url_b, "{s}/accounts/{s}/d1/database/{s}/query", .{ ctx.api_root, ctx.account, db }) catch return dupe(gpa, "oom");
    return answer(ctx, call(ctx, "POST", url, body.items, "application/json", &.{}), "d1 query");
}

/// The escape hatch: any Cloudflare v4 endpoint the grant covers. Everything the named tools above do
/// not — Pages projects, KV namespaces, Queues, Vectorize, routes, tail, Workers AI inference — is one
/// of these calls, so the belt stays small while the reach stays whole.
fn genericApi(ctx: Ctx, args_json: []const u8) []u8 {
    const gpa = ctx.gpa;
    const A = struct { method: []const u8 = "GET", path: []const u8 = "", body: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args_json, .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    var path = std.mem.trim(u8, p.value.path, " \r\n\t");
    if (path.len == 0) return dupe(gpa, "cf_api needs a path, e.g. /accounts/{account_id}/d1/database");
    if (path[0] != '/') return dupe(gpa, "path must start with /");
    // No scheme, no host, no credential smuggling: the path is appended to the v4 root and nothing else.
    // Without this a "path" of "//evil.example/x" or "https://evil.example/x" would send the user's
    // bearer token to someone else's server.
    if (path.len > 1 and path[1] == '/') return dupe(gpa, "path must be a bare /... path on api.cloudflare.com");
    if (std.mem.indexOf(u8, path, "://") != null or std.mem.indexOfScalar(u8, path, '@') != null) return dupe(gpa, "path must be a bare /... path on api.cloudflare.com");
    for (path) |c| if (c < 0x20 or c == ' ') return dupe(gpa, "path must not contain spaces or control characters");

    // {account_id} is the placeholder the model reaches for most; substitute it rather than making it
    // re-derive an id it was never told.
    var sub: std.ArrayListUnmanaged(u8) = .empty;
    defer sub.deinit(gpa);
    const ph = "{account_id}";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, path, i, ph)) |at| {
        sub.appendSlice(gpa, path[i..at]) catch return dupe(gpa, "oom");
        sub.appendSlice(gpa, ctx.account) catch return dupe(gpa, "oom");
        i = at + ph.len;
    }
    if (sub.items.len > 0) {
        sub.appendSlice(gpa, path[i..]) catch return dupe(gpa, "oom");
        path = sub.items;
    }

    const method = if (p.value.method.len > 0) p.value.method else "GET";
    if (method.len > 6) return dupe(gpa, "method must be GET, POST, PUT, PATCH or DELETE");
    const known = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE" };
    var ok = false;
    for (known) |m| {
        if (std.ascii.eqlIgnoreCase(m, method)) ok = true;
    }
    if (!ok) return dupe(gpa, "method must be GET, POST, PUT, PATCH or DELETE");

    var url_b: [900]u8 = undefined;
    const url = std.fmt.bufPrint(&url_b, "{s}{s}", .{ ctx.api_root, path }) catch return dupe(gpa, "path too long");
    var mbuf: [8]u8 = undefined;
    const mup = std.ascii.upperString(mbuf[0..method.len], method);
    return answer(ctx, call(ctx, mup, url, p.value.body, "application/json", &.{}), "cf_api");
}

// ------------------------------------------------------------------------------------ dispatch + schema

/// Route a `cf_` call. Returns null for a name this family does not own, so the caller falls through to
/// its own chain (recipes, authored tools) exactly as it does for an unknown verb.
pub fn dispatch(ctx: Ctx, name: []const u8, args_json: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, name, "cf_")) return null;
    if (ctx.token.len == 0 or ctx.account.len == 0)
        return dupe(ctx.gpa, "not connected to Cloudflare — the user connects an account in Settings, then these tools work against it");
    if (std.mem.eql(u8, name, "cf_deploy_worker")) return deployWorker(ctx, args_json);
    if (std.mem.eql(u8, name, "cf_r2_list")) return r2List(ctx, args_json);
    if (std.mem.eql(u8, name, "cf_r2_put")) return r2Put(ctx, args_json);
    if (std.mem.eql(u8, name, "cf_r2_get")) return r2Get(ctx, args_json);
    if (std.mem.eql(u8, name, "cf_d1_query")) return d1Query(ctx, args_json);
    if (std.mem.eql(u8, name, "cf_api")) return genericApi(ctx, args_json);
    return dupe(ctx.gpa, "unknown cf_ tool — the family is cf_deploy_worker, cf_r2_list, cf_r2_put, cf_r2_get, cf_d1_query, cf_api");
}

/// The belt entries, appended ONLY when a turn carries Cloudflare credentials (engine.zig buildTurnTools).
/// Six defs, deliberately: five verbs for what a build actually does, and one escape hatch that reaches
/// the rest of the API rather than paying belt bytes for forty near-identical wrappers.
pub const SCHEMA =
    \\{"type":"function","function":{"name":"cf_deploy_worker","description":"Deploy a JavaScript Worker to the user's own Cloudflare account and return its live https URL. The file must be an ES module in the workspace exporting `export default { async fetch(request, env, ctx) {...} }`. Re-deploying the same name replaces it.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"worker name: lowercase letters, digits, - or _ ; becomes the subdomain"},"file":{"type":"string","description":"workspace-relative path to the module, e.g. worker.mjs"},"compatibility_date":{"type":"string","description":"optional, defaults to a current date"}},"required":["name","file"]}}},
    \\{"type":"function","function":{"name":"cf_r2_list","description":"List the user's R2 buckets, or the objects inside one bucket.","parameters":{"type":"object","properties":{"bucket":{"type":"string","description":"omit to list buckets; give a bucket name to list its objects"},"prefix":{"type":"string","description":"optional key prefix filter"}}}}},
    \\{"type":"function","function":{"name":"cf_r2_put","description":"Upload a workspace file (or inline text) to an R2 bucket - object storage in the user's own account, with free egress.","parameters":{"type":"object","properties":{"bucket":{"type":"string"},"key":{"type":"string","description":"object key, path-like"},"file":{"type":"string","description":"workspace-relative file to upload"},"text":{"type":"string","description":"inline content, used when file is omitted"}},"required":["bucket","key"]}}},
    \\{"type":"function","function":{"name":"cf_r2_get","description":"Download an R2 object into the workspace.","parameters":{"type":"object","properties":{"bucket":{"type":"string"},"key":{"type":"string"},"file":{"type":"string","description":"workspace-relative destination; defaults to the key"}},"required":["bucket","key"]}}},
    \\{"type":"function","function":{"name":"cf_d1_query","description":"Run SQL against one of the user's D1 (serverless SQLite) databases. List databases first with cf_api GET /accounts/{account_id}/d1/database.","parameters":{"type":"object","properties":{"database_id":{"type":"string"},"sql":{"type":"string","description":"one statement, or several separated by ;"}},"required":["database_id","sql"]}}},
    \\{"type":"function","function":{"name":"cf_api","description":"Call any Cloudflare v4 API endpoint the login covers: Pages projects, KV namespaces, Queues, Vectorize indexes, Worker routes and logs, Workers AI inference. Write {account_id} in the path and it is filled in. Example: POST /accounts/{account_id}/pages/projects.","parameters":{"type":"object","properties":{"method":{"type":"string","description":"GET, POST, PUT, PATCH or DELETE"},"path":{"type":"string","description":"bare path starting with /, e.g. /accounts/{account_id}/d1/database"},"body":{"type":"string","description":"JSON request body for POST/PUT/PATCH"}},"required":["path"]}}}
;

// ---------------------------------------------------------------------------
// tests — see harness/TESTING.md. The properties worth pinning are the ones a wrong edit would make
// silently dangerous: the path jail, the URL jail, and the refusal when no account is connected.
// ---------------------------------------------------------------------------

test "safeRel refuses anything that escapes the workspace" {
    try std.testing.expect(safeRel("worker.mjs"));
    try std.testing.expect(safeRel("src/index.js"));
    try std.testing.expect(!safeRel(""));
    try std.testing.expect(!safeRel("/etc/passwd"));
    try std.testing.expect(!safeRel("\\\\server\\share"));
    try std.testing.expect(!safeRel("../../.ssh/id_rsa"));
    try std.testing.expect(!safeRel("C:/Windows/System32/config/SAM"));
    try std.testing.expect(!safeRel("a\x00b"));
}

test "dispatch: only the cf_ family, and never without a connected account" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // a name this family does not own falls through to the caller's own chain
    const other = dispatch(.{ .gpa = gpa, .io = io, .scratch = ".", .workdir = ".", .token = "t", .account = "a" }, "read_file", "{}");
    try std.testing.expect(other == null);

    // and with no credentials every cf_ verb refuses BEFORE it can build a request
    const refused = dispatch(.{ .gpa = gpa, .io = io, .scratch = ".", .workdir = ".", .token = "", .account = "" }, "cf_deploy_worker", "{}").?;
    defer gpa.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "not connected") != null);
}

test "cf_api refuses any path that could send the bearer token off Cloudflare" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ctx = Ctx{ .gpa = gpa, .io = io, .scratch = ".", .workdir = ".", .token = "secret", .account = "acct" };
    // Each of these would otherwise re-target the request at a host the token was not minted for.
    const bad = [_][]const u8{
        "{\"path\":\"https://evil.example/steal\"}",
        "{\"path\":\"//evil.example/steal\"}",
        "{\"path\":\"/x@evil.example/steal\"}",
        "{\"path\":\"/accounts /../x\"}",
        "{\"path\":\"no-leading-slash\"}",
        "{\"path\":\"\"}",
    };
    for (bad) |args| {
        const r = dispatch(ctx, "cf_api", args).?;
        defer gpa.free(r);
        // Refused before any request is built. Two wordings reach here — the shape complaint
        // ("path must be...") and the missing-argument one ("cf_api needs a path") — and what the
        // test pins is that NEITHER produced an API answer.
        const refused = std.mem.indexOf(u8, r, "path must") != null or std.mem.indexOf(u8, r, "needs a path") != null;
        if (!refused) std.debug.print("cf_api accepted a path it must refuse: {s} -> {s} ", .{ args, r });
        try std.testing.expect(refused);
    }
    // and an unusable method never reaches curl either
    const m = dispatch(ctx, "cf_api", "{\"path\":\"/user\",\"method\":\"CONNECT\"}").?;
    defer gpa.free(m);
    try std.testing.expect(std.mem.indexOf(u8, m, "method must") != null);
}

test "the belt schema is well-formed JSON and names exactly the dispatched verbs" {
    const gpa = std.testing.allocator;
    const wrapped = try std.fmt.allocPrint(gpa, "[{s}]", .{SCHEMA});
    defer gpa.free(wrapped);
    const p = try std.json.parseFromSlice(std.json.Value, gpa, wrapped, .{});
    defer p.deinit();
    const defs = p.value.array;
    // every advertised name must be one dispatch() actually routes, or the belt teaches a verb that
    // answers "unknown cf_ tool" — a wasted agentic round, every time.
    const routed = [_][]const u8{ "cf_deploy_worker", "cf_r2_list", "cf_r2_put", "cf_r2_get", "cf_d1_query", "cf_api" };
    try std.testing.expectEqual(routed.len, defs.items.len);
    for (defs.items) |d| {
        const nm = d.object.get("function").?.object.get("name").?.string;
        var found = false;
        for (routed) |r| {
            if (std.mem.eql(u8, r, nm)) found = true;
        }
        try std.testing.expect(found);
    }
}
