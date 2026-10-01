//! cf_hot.zig — HOTS: autonomous technicians that run the veil's goal loop in the user's own Cloudflare account.
//!
//! WHAT: a hot (Human Overview Technician) is the goal loop of worker/chat/goal.zig with no human in it and no
//! machine of the user's under it. It lives in one Worker script ("veil-hots") this file uploads into the
//! account behind "Log in with Cloudflare": each hot is a Durable Object whose alarm runs one iteration
//! (pick -> do -> measure -> record -> learn), and whose model calls go through the account's own AI binding.
//! The runtime is cloud/hot.js, embedded here and uploaded as it is; its header says what a hot can do. Beside it
//! goes cloud/hot_py.py, a second Worker ("veil-hots-py") that runs a hot's Python, and the upload asks for
//! Cloudflare's browser binding: both are optional, and an account that refuses one gets a hot without it.
//! An account holds at most MAX_HOTS of them, and the first is always named PRIMARY.
//!
//! HOW: the same OAuth token the chat turns use (workers-scripts.write) uploads the script, enables its
//! workers.dev address and sets ONE secret on it: the token every later call carries. That token is never
//! stored: it is derived from the server key, the user, the account and a generation counter (hotToken), so
//! the state file ({data}/u{uid}/cf_hots.json) holds an address and a hash, nothing a reader could use.
//! After that this file is a relay: the desk and `veil hot` ask this server, and this server asks
//! the Worker - roster, deploy, command, settings, events, the shared scratchpad, delete.
//!
//! THE OWNER'S MACHINE: a hot deployed with `local` (a checkbox at deployment, never changeable later) may
//! queue jobs for the veil here. Nothing listens at home for them: bgLoop polls each approved hot's queue and
//! runs a job as an unattended chat turn - the same entry points a scheduled task uses (worker/sched.zig) - in
//! a conversation named for the job, then posts the turn's final answer back. The approval is recorded HERE
//! (State.local): a runtime that claimed the grant for itself would still find no bridge.
//!
//!   GET    /api/v1/hots                  roster + deployment status
//!   POST   /api/v1/hots                  deploy one (uploads the runtime first when it is absent or older)
//!   DELETE /api/v1/hots                  remove the runtime and every hot from the account
//!   DELETE /api/v1/hots/:name            delete one hot; deleting the LAST one also removes the Worker
//!   GET    /api/v1/hots/:name/events     its event tail (?after=N)
//!   POST   /api/v1/hots/:name/command    a command or a message ("/goal ...", "/pause", plain words)
//!   POST   /api/v1/hots/:name/config     settings: model, pace_s, size, daily_calls, charter, paused
//!   GET    /api/v1/hots/pad              the scratchpad the account's hots share (?after=N)
//!   POST   /api/v1/hots/pad              write to it
//!   POST   /api/v1/hots/pad/clear        empty it (the local copy is kept as _hots/scratchpad-<when>.md)
//!
//! THE LOCAL FOLDER: every deployment of a hot is mirrored into {data}/u<uid>/_hots/<name>-<deployed>/ (events.log
//! to tail, events.jsonl, status.json, notes/), with the shared scratchpad at _hots/scratchpad.md. See mirrorHot.
//!
//! Every route is admin-gated, like the scheduled tasks: a hot with the owner's machine runs full-tool turns.

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const cf_oauth = @import("cf_oauth.zig");
const chat_engine = @import("../worker/chat/engine.zig");
const bu = @import("../worker/browser/util.zig"); // sleepMs: a raw-thread sleep, no Io park
const modelcfg = @import("modelcfg");
const fakehttp = @import("../worker/fakehttp.zig"); // TEST ONLY: the stand-in Cloudflare API and hot runtime
const App = http.App;
const badReq = http.badReq;
const log = std.log.scoped(.cf_hot);

/// The runtime, uploaded as it is (cloud/hot.js; build.zig hands it over by this name).
const HOT_JS = @embedFile("hot.js");
/// The Python a hot runs: a second Worker, reached from the runtime through a service binding (cloud/hot_py.py).
const HOT_PY = @embedFile("hot_py.py");

pub const SCRIPT = "veil-hots";
pub const PY_SCRIPT = "veil-hots-py";
const PY_MODULE = "hot_py.py";
pub const MAX_HOTS: usize = 3; // hot.js enforces it; a test below holds the two to one number
pub const PRIMARY = "Gary";
const MODULE = "hot.js";
const COMPAT_DATE = "2025-09-01";
const MIGRATION_TAG = "v1";
const STATE_FILE = "cf_hots.json";
const NAME_MAX = 24;
/// How often the bridge asks each approved hot for jobs.
const BRIDGE_EVERY_MS: u64 = 20_000;

// ---------------------------------------------------------------------------------- per-user state file

/// What this server remembers about a user's hots. No secret: the runtime's token is derived (hotToken).
const State = struct {
    account: []const u8 = "", // the Cloudflare account the runtime was uploaded to
    url: []const u8 = "", // https://veil-hots.<subdomain>.workers.dev
    script_hash: []const u8 = "", // the hot.js that is up there (scriptHash)
    token_gen: u32 = 0, // bumped to rotate the runtime's token
    deployed_at: i64 = 0,
    python: bool = false, // the runtime has its Python Worker bound (run_python, skills)
    browser: bool = false, // the runtime has Cloudflare's browser bound (browser_*)
    tools_note: []const u8 = "", // why one of them is missing, in Cloudflare's words
    local: []const []const u8 = &.{}, // hots the owner allowed onto this machine, by name
    last_error: []const u8 = "",
};

fn statePath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ STATE_FILE, .{ app.data, uid }) catch null;
}

/// The stored state, or defaults. Everything is allocated in `a`.
fn readState(app: *App, uid: u64, a: std.mem.Allocator) State {
    var pb: [700]u8 = undefined;
    const path = statePath(app, uid, &pb) orelse return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(64 << 10)) catch return .{};
    return std.json.parseFromSliceLeaky(State, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

fn writeState(app: *App, uid: u64, st: State) void {
    var db: [700]u8 = undefined;
    if (std.fmt.bufPrint(&db, "{s}/u{d}", .{ app.data, uid })) |dir| {
        _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    } else |_| {}
    var pb: [700]u8 = undefined;
    const path = statePath(app, uid, &pb) orelse return;
    const json = std.json.Stringify.valueAlloc(app.gpa, st, .{ .whitespace = .indent_1 }) catch return;
    defer app.gpa.free(json);
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = json }) catch {};
}

fn nowS(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

// ---------------------------------------------------------------------------------- names, token, address

/// A hot's name: 1-24 of [A-Za-z0-9_-], starting with a letter. The same rule hot.js applies (validName): the
/// name becomes a URL segment there and part of a conversation id here.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > NAME_MAX or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

/// The bearer the runtime answers to, as 64 hex characters. Derived, so it is never written anywhere on this
/// machine: HMAC-SHA256 under the server key of the user, the account and the generation.
fn hotToken(app: *App, uid: u64, account: []const u8, gen: u32, out: *[64]u8) []const u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var h = Hmac.init(&app.server_key);
    var nb: [48]u8 = undefined;
    h.update("veil-hot-token");
    h.update(std.fmt.bufPrint(&nb, "\x00u{d}\x00g{d}\x00", .{ uid, gen }) catch "");
    h.update(account);
    var mac: [Hmac.mac_length]u8 = undefined;
    h.final(&mac);
    out.* = std.fmt.bytesToHex(mac, .lower);
    return out;
}

/// Which hot.js this binary carries, as 16 hex characters.
fn scriptHash(out: *[16]u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(HOT_JS);
    h.update("\x00");
    h.update(HOT_PY);
    var dig: [32]u8 = undefined;
    h.final(&dig);
    out.* = std.fmt.bytesToHex(dig[0..8].*, .lower);
    return out;
}

/// The runtime's address carries the token on every call, so it is one of two things: a workers.dev address over
/// https, or - only while the Cloudflare API itself is pointed at a loopback stand-in (NL_CF_API_ROOT, tests) -
/// a loopback address. A state file edited to name any other host gets no call.
fn allowedUrl(app: *App, url: []const u8) bool {
    if (url.len < 12 or url.len > 200) return false;
    for (url) |c| if (c <= 0x20 or c == '@' or c == '\\' or c == '#' or c == '?' or c == 0x7F) return false;
    if (std.mem.startsWith(u8, url, "https://")) {
        const host = url["https://".len..];
        return std.mem.endsWith(u8, host, ".workers.dev") and std.mem.indexOfScalar(u8, host, '/') == null and std.mem.indexOfScalar(u8, host, ':') == null;
    }
    const loop = std.mem.startsWith(u8, app.cf_api_root, "http://127.0.0.1:") or std.mem.startsWith(u8, app.cf_api_root, "http://localhost:");
    if (!loop or !std.mem.startsWith(u8, url, "http://127.0.0.1:")) return false;
    for (url["http://127.0.0.1:".len..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// ---------------------------------------------------------------------------------- the Cloudflare API

const Envelope = struct {
    success: bool = false,
    errors: []const struct { code: i64 = 0, message: []const u8 = "" } = &.{},
};

/// The first error of a v4 reply, "" when it succeeded.
fn firstError(a: std.mem.Allocator, raw: []const u8) []const u8 {
    const p = std.json.parseFromSliceLeaky(Envelope, a, raw, .{ .ignore_unknown_fields = true }) catch return "unreadable reply from the Cloudflare API";
    if (p.success) return "";
    if (p.errors.len == 0) return "the Cloudflare API refused the request";
    return p.errors[0].message;
}

fn explain(a: std.mem.Allocator, what: []const u8, msg: []const u8) []const u8 {
    const perm = std.mem.indexOf(u8, msg, "Authentication error") != null or std.mem.indexOf(u8, msg, "insufficient") != null or
        std.mem.indexOf(u8, msg, "not authorized") != null or std.mem.indexOf(u8, msg, "permission") != null;
    if (perm)
        return std.fmt.allocPrint(a, "{s}: your Cloudflare login has not granted the Workers permission - Disconnect and log in with Cloudflare again to grant it", .{what}) catch what;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ what, msg }) catch what;
}

/// One v4 call, the reply copied into `a`.
fn api(app: *App, a: std.mem.Allocator, method: []const u8, url: []const u8, body: []const u8, bearer: []const u8, content_type: []const u8) ?[]u8 {
    const raw = cf_oauth.apiCall(app, method, url, body, bearer, content_type) orelse return null;
    defer app.gpa.free(raw);
    return a.dupe(u8, raw) catch null;
}

/// Which optional bindings an upload asks for. The runtime works without either; each is one family of tools.
const Extras = struct { python: bool, browser: bool };

/// The script upload: a multipart body of the metadata and the module. The metadata names the AI binding and the
/// object class, and KEEPS the secret already on the script - the token is set by its own small call (putSecret),
/// so it is never part of a body that has to ride a file. `fresh` adds the migration that creates the class,
/// which Cloudflare accepts exactly once per script. `x` adds the Python Worker (a service binding, PY) and
/// Cloudflare's browser (BROWSER).
fn uploadBody(a: std.mem.Allocator, boundary: []const u8, fresh: bool, x: Extras) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\nContent-Type: application/json\r\n\r\n", .{boundary});
    try out.appendSlice(a, "{\"main_module\":\"" ++ MODULE ++ "\",\"compatibility_date\":\"" ++ COMPAT_DATE ++ "\"," ++
        "\"bindings\":[{\"type\":\"ai\",\"name\":\"AI\"},{\"type\":\"durable_object_namespace\",\"name\":\"HOT\",\"class_name\":\"Hot\"}");
    if (x.python) try out.appendSlice(a, ",{\"type\":\"service\",\"name\":\"PY\",\"service\":\"" ++ PY_SCRIPT ++ "\"}");
    if (x.browser) try out.appendSlice(a, ",{\"type\":\"browser\",\"name\":\"BROWSER\"}");
    try out.appendSlice(a, "],\"keep_bindings\":[\"secret_text\"]");
    if (fresh) try out.appendSlice(a, ",\"migrations\":{\"new_tag\":\"" ++ MIGRATION_TAG ++ "\",\"new_sqlite_classes\":[\"Hot\"]}");
    try out.print(a, "}}\r\n--{s}\r\nContent-Disposition: form-data; name=\"" ++ MODULE ++ "\"; filename=\"" ++ MODULE ++ "\"\r\nContent-Type: application/javascript+module\r\n\r\n", .{boundary});
    try out.appendSlice(a, HOT_JS);
    try out.print(a, "\r\n--{s}--\r\n", .{boundary});
    return out.items;
}

/// The Python Worker's upload: its metadata (the python_workers flag is what makes a .py module a Worker) and the
/// module. It has no bindings, no secret and no public address; only the runtime's service binding reaches it.
fn pyUploadBody(a: std.mem.Allocator, boundary: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\nContent-Type: application/json\r\n\r\n", .{boundary});
    try out.appendSlice(a, "{\"main_module\":\"" ++ PY_MODULE ++ "\",\"compatibility_date\":\"" ++ COMPAT_DATE ++ "\",\"compatibility_flags\":[\"python_workers\"]}");
    try out.print(a, "\r\n--{s}\r\nContent-Disposition: form-data; name=\"" ++ PY_MODULE ++ "\"; filename=\"" ++ PY_MODULE ++ "\"\r\nContent-Type: text/x-python\r\n\r\n", .{boundary});
    try out.appendSlice(a, HOT_PY);
    try out.print(a, "\r\n--{s}--\r\n", .{boundary});
    return out.items;
}

const Tok = struct { key: []const u8, account_id: []const u8 };

/// Where the uploaded runtime answers: the account's workers.dev address. While the Cloudflare API is a loopback
/// stand-in (NL_CF_API_ROOT, the simulation suite, the tests below) the stand-in plays the account, so it plays
/// the account's workers.dev too: the runtime's address is the stand-in's own origin.
fn runtimeUrl(app: *App, a: std.mem.Allocator, sub: []const u8) ?[]const u8 {
    const root = app.cf_api_root;
    inline for (.{ "http://127.0.0.1:", "http://localhost:" }) |loop| {
        if (std.mem.startsWith(u8, root, loop)) {
            const rest = root[loop.len..];
            const port = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
            return std.fmt.allocPrint(a, "http://127.0.0.1:{s}", .{port}) catch null;
        }
    }
    return std.fmt.allocPrint(a, "https://" ++ SCRIPT ++ ".{s}.workers.dev", .{sub}) catch null;
}

/// Make sure the account runs THIS binary's hot.js, and that `st` knows its address. Costs no call when the
/// state already names this account and this script. Returns what went wrong in words a user can act on, or
/// null; `uploaded` says whether a script went up just now (its address can take a few seconds to answer).
fn ensureRuntime(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State, uploaded: *bool) ?[]const u8 {
    uploaded.* = false;
    var hb: [16]u8 = undefined;
    const want = scriptHash(&hb);
    if (st.url.len > 0 and std.mem.eql(u8, st.account, tok.account_id) and std.mem.eql(u8, st.script_hash, want)) return null;
    const root = app.cf_api_root;
    const acct = tok.account_id;
    if (acct.len == 0) return "your Cloudflare login names no account - Disconnect and log in with Cloudflare again";

    // The account's workers.dev subdomain: the runtime's address hangs off it.
    const sub_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/subdomain", .{ root, acct }) catch return "out of memory";
    const sub_raw = api(app, a, "GET", sub_url, "", tok.key, "") orelse return "could not reach the Cloudflare API";
    const Sub = struct { result: ?struct { subdomain: []const u8 = "" } = null };
    const sub = blk: {
        const p = std.json.parseFromSliceLeaky(Sub, a, sub_raw, .{ .ignore_unknown_fields = true }) catch break :blk "";
        break :blk if (p.result) |r| r.subdomain else "";
    };
    if (sub.len == 0) {
        const msg = firstError(a, sub_raw);
        if (msg.len > 0 and std.mem.indexOf(u8, msg, "subdomain") == null) return explain(a, "workers.dev address", msg);
        return "this Cloudflare account has no workers.dev subdomain yet - open Workers & Pages in the Cloudflare dashboard once (it offers one), then deploy again";
    }
    for (sub) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return "the account's workers.dev subdomain is not a name this server can use";

    // Is the script already there? Its class migration applies once, so a second upload must not carry it.
    const script_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ SCRIPT, .{ root, acct }) catch return "out of memory";
    const settings_url = std.fmt.allocPrint(a, "{s}/settings", .{script_url}) catch return "out of memory";
    const exists = if (api(app, a, "GET", settings_url, "", tok.key, "")) |r| firstError(a, r).len == 0 else false;

    var bb: [8]u8 = undefined;
    app.io.random(&bb);
    const boundary = std.fmt.allocPrint(a, "----veilhot{s}", .{std.fmt.bytesToHex(bb, .lower)}) catch return "out of memory";
    const ctype = std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary}) catch return "out of memory";
    // The Python Worker first: the runtime binds to it by name, so it has to exist. An account that does not take
    // it (or the browser, below) still gets a hot - without that family of tools, and told why.
    var note: []const u8 = "";
    const py_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ PY_SCRIPT, .{ root, acct }) catch return "out of memory";
    const py_body = pyUploadBody(a, boundary) catch return "out of memory";
    var python = false;
    if (api(app, a, "PUT", py_url, py_body, tok.key, ctype)) |r| {
        const e = firstError(a, r);
        python = e.len == 0;
        if (!python) note = std.fmt.allocPrint(a, "Python is off: {s}", .{e}) catch "Python is off";
    } else note = "Python is off: the Cloudflare API did not answer its upload";

    // The runtime, asking for everything first. The settings read above is only a hint (a login may lack its
    // scope), so each set of bindings is tried with and without the class migration; the first upload Cloudflare
    // takes wins, and the first refusal of all is the one reported when none does.
    const wants = [_]Extras{
        .{ .python = python, .browser = true },
        .{ .python = python, .browser = false },
        .{ .python = false, .browser = false },
    };
    var up_err: []const u8 = "";
    var got: ?Extras = null;
    ladder: for (wants, 0..) |x, wi| {
        if (wi == 2 and !python) break; // the same upload as the one before it
        var refusal: []const u8 = "";
        for ([_]bool{ !exists, exists }) |fresh| {
            const body = uploadBody(a, boundary, fresh, x) catch return "out of memory";
            const up = api(app, a, "PUT", script_url, body, tok.key, ctype) orelse return "could not reach the Cloudflare API to upload the hot runtime";
            const e = firstError(a, up);
            if (e.len == 0) {
                got = x;
                break :ladder;
            }
            if (refusal.len == 0) refusal = e;
        }
        if (up_err.len == 0) up_err = refusal;
        if (x.browser and note.len < 200) note = std.fmt.allocPrint(a, "{s}{s}the browser is off: {s}", .{ note, if (note.len > 0) "; " else "", refusal }) catch note;
    }
    const have = got orelse return explain(a, "uploading the hot runtime", up_err);
    st.python = have.python;
    st.browser = have.browser;
    st.tools_note = if (have.python and have.browser) "" else note;

    // Its token, as a secret binding. A small JSON body: it rides curl's stdin with the bearer, never a file.
    var tb: [64]u8 = undefined;
    const token = hotToken(app, uid, acct, st.token_gen, &tb);
    const secret_url = std.fmt.allocPrint(a, "{s}/secrets", .{script_url}) catch return "out of memory";
    const secret_body = std.fmt.allocPrint(a, "{{\"name\":\"HOT_TOKEN\",\"text\":\"{s}\",\"type\":\"secret_text\"}}", .{token}) catch return "out of memory";
    const sec = api(app, a, "PUT", secret_url, secret_body, tok.key, "application/json") orelse return "could not reach the Cloudflare API to set the hot runtime's token";
    const sec_err = firstError(a, sec);
    if (sec_err.len > 0) return explain(a, "setting the hot runtime's token", sec_err);

    // Its workers.dev route. Best effort: a script that had it on keeps it on.
    const route_url = std.fmt.allocPrint(a, "{s}/subdomain", .{script_url}) catch return "out of memory";
    _ = api(app, a, "POST", route_url, "{\"enabled\":true}", tok.key, "application/json");

    st.account = acct;
    st.url = runtimeUrl(app, a, sub) orelse return "out of memory";
    st.script_hash = a.dupe(u8, want) catch return "out of memory";
    st.deployed_at = nowS(app.io);
    st.last_error = "";
    uploaded.* = true;
    log.info("hot runtime uploaded for u{d}: {s} ({s})", .{ uid, st.url, want });
    return null;
}

// ---------------------------------------------------------------------------------- the runtime (relay)

const Reply = struct { ok: bool = false, err: []const u8 = "" };

/// One call to the runtime; the reply lives in `a`. null: no address, an address this server will not send the
/// token to, or no answer.
fn hotCall(app: *App, a: std.mem.Allocator, uid: u64, st: State, method: []const u8, path: []const u8, body: []const u8) ?[]u8 {
    if (!allowedUrl(app, st.url)) return null;
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ st.url, path }) catch return null;
    var tb: [64]u8 = undefined;
    const token = hotToken(app, uid, st.account, st.token_gen, &tb);
    return api(app, a, method, url, body, token, if (body.len > 0) "application/json" else "");
}

/// Whether the runtime said yes, and its words when it did not ("" for a reply that is not its JSON at all).
fn replyOf(a: std.mem.Allocator, raw: []const u8) Reply {
    return std.json.parseFromSliceLeaky(Reply, a, raw, .{ .ignore_unknown_fields = true }) catch .{};
}

/// Hand the runtime's answer to the client: its JSON as it is when it said ok, its own error otherwise.
fn relay(res: *httpz.Response, a: std.mem.Allocator, raw: ?[]u8) !void {
    const body = raw orelse return http.serverErr(res, "the hot runtime did not answer - is it deployed, and is this machine online?");
    const r = replyOf(a, body);
    if (!r.ok) return badReq(res, if (r.err.len > 0) r.err else "the hot runtime gave an unreadable answer (a new deployment can take a minute to come up)");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, body);
}

/// requireUser + admin, replying 403 like the scheduled tasks: a hot allowed onto the owner's machine fires
/// full-tool chat turns there, and a hot of any kind spends the account's Workers AI.
fn gate(app: *App, req: *httpz.Request, res: *httpz.Response) ?http.User {
    const u = http.requireUser(app, req, res) orelse return null;
    if (!app.auth.isAdmin(u)) {
        res.status = 403;
        res.json(.{ .ok = false, .err = "hots are admin-only for now" }, .{}) catch {};
        return null;
    }
    return u;
}

fn tokOf(app: *App, uid: u64, a: std.mem.Allocator) ?Tok {
    const t = cf_oauth.resolveToken(app, uid, a) orelse return null;
    return .{ .key = t.key, .account_id = t.account_id };
}

// ---------------------------------------------------------------------------------- HTTP handlers

/// GET /api/v1/hots — the roster as the runtime reports it, plus what this server knows: connected, deployed,
/// the address, which hots may use this machine, and the last deployment error.
pub fn listHots(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var connected = false;
    if (app.vault.resolveOAuth(u.id, cf_oauth.CF_PROVIDER, a)) |b| connected = b.refresh_token.len > 0;
    const st = readState(app, u.id, a);
    var hb: [16]u8 = undefined;
    const deployed = st.url.len > 0;
    var hots: []const u8 = "[]";
    var reachable = false;
    if (deployed) {
        if (hotCall(app, a, u.id, st, "GET", "/v1/hots", "")) |raw| {
            const R = struct { ok: bool = false, hots: std.json.Value = .null };
            if (std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true })) |r| {
                if (r.ok and r.hots == .array) {
                    reachable = true;
                    // each hot's local folder, relative to the data dir (the desk's Open folder)
                    for (r.hots.array.items) |*v| {
                        if (v.* != .object) continue;
                        const h = std.json.parseFromValueLeaky(RosterHot, a, v.*, .{ .ignore_unknown_fields = true }) catch continue;
                        var fb: [160]u8 = undefined;
                        const rel = hotFolder(&fb, u.id, h.name, h.created) orelse continue;
                        v.object.put(a, "folder", .{ .string = a.dupe(u8, rel) catch continue }) catch {};
                    }
                    hots = std.json.Stringify.valueAlloc(a, r.hots, .{}) catch "[]";
                }
            } else |_| {}
        }
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    try out.print(app.gpa, "{{\"ok\":true,\"connected\":{},\"deployed\":{},\"reachable\":{},\"current\":{},\"max\":{d},\"primary\":\"" ++ PRIMARY ++ "\",\"url\":", .{ connected, deployed, reachable, std.mem.eql(u8, st.script_hash, scriptHash(&hb)), MAX_HOTS });
    try http.jstr(app.gpa, &out, st.url);
    try out.appendSlice(app.gpa, ",\"local\":[");
    for (st.local, 0..) |n, i| {
        if (i > 0) try out.append(app.gpa, ',');
        try http.jstr(app.gpa, &out, n);
    }
    try out.print(app.gpa, "],\"python\":{},\"browser\":{},\"tools_note\":", .{ st.python, st.browser });
    try http.jstr(app.gpa, &out, st.tools_note);
    try out.appendSlice(app.gpa, ",\"last_error\":");
    try http.jstr(app.gpa, &out, st.last_error);
    try out.appendSlice(app.gpa, ",\"hots\":");
    try out.appendSlice(app.gpa, hots);
    try out.append(app.gpa, '}');
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, out.items);
}

const CreateReq = struct {
    name: []const u8 = "",
    goal: []const u8 = "",
    charter: []const u8 = "",
    model: []const u8 = "",
    pace_s: ?i64 = null,
    size: ?i64 = null,
    daily_calls: ?i64 = null,
    budget: ?i64 = null,
    forever: bool = false,
    local: bool = false, // the owner's-machine checkbox: only ever granted here, at deployment
};

/// POST /api/v1/hots — deploy a hot. Uploads the runtime first when the account lacks it or runs an older one.
pub fn createHot(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(CreateReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
    switch (deploy(app, a, u.id, tok, body)) {
        .ok => |raw| {
            res.status = 201;
            res.content_type = .JSON;
            res.body = try res.arena.dupe(u8, raw);
        },
        .err => |msg| return badReq(res, msg),
    }
}

const Deployed = union(enum) { ok: []const u8, err: []const u8 };

/// What goes to the runtime: the request as the user made it, plus the text limit of its model (the runtime clips
/// a later `/goal` or `/charter` to it).
const Sent = struct { req: CreateReq, text_max: usize };

fn sentJson(a: std.mem.Allocator, s: Sent) ?[]const u8 {
    const body = std.json.Stringify.valueAlloc(a, s.req, .{ .emit_null_optional_fields = false }) catch return null;
    // the request is an object: add the limit as its last field
    return std.fmt.allocPrint(a, "{s},\"text_max\":{d}}}", .{ body[0 .. body.len - 1], s.text_max }) catch null;
}

/// createHot without the request: validate, make sure the runtime is up, create the hot, record a local grant.
fn deploy(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, body: CreateReq) Deployed {
    const name = std.mem.trim(u8, body.name, " \r\n\t");
    if (name.len > 0 and !validName(name)) return .{ .err = "a hot's name is 1-24 letters, digits, - or _, starting with a letter" };
    if (std.mem.trim(u8, body.goal, " \r\n\t").len < 3 and std.mem.trim(u8, body.charter, " \r\n\t").len < 3)
        return .{ .err = "a hot needs a goal or a charter to work toward" };
    const model = if (body.model.len > 0) body.model else modelcfg.defaults.cf_model;
    if (model[0] != '@') return .{ .err = "a hot runs on the account's Workers AI: pick an @cf/ model" };
    const limit = modelcfg.goalCharLimit(model);
    if (body.goal.len > limit or body.charter.len > limit)
        return .{ .err = std.fmt.allocPrint(a, "on {s} a goal or a charter holds at most {d} characters - shorten it, or pick a model with a bigger window", .{ model, limit }) catch "goal too long for this model" };

    var st = readState(app, uid, a);
    var uploaded = false;
    if (ensureRuntime(app, a, uid, tok, &st, &uploaded)) |msg| {
        st.last_error = msg;
        writeState(app, uid, st);
        return .{ .err = msg };
    }
    if (uploaded) writeState(app, uid, st);

    var send: Sent = .{ .req = body, .text_max = limit };
    send.req.name = name;
    send.req.model = model;
    const json = sentJson(a, send) orelse return .{ .err = "out of memory" };
    // A workers.dev address that was enabled a moment ago answers with Cloudflare's own page for a few seconds.
    var attempt: usize = 0;
    const raw = while (true) : (attempt += 1) {
        if (hotCall(app, a, uid, st, "POST", "/v1/hots", json)) |r| {
            const rep = replyOf(a, r);
            if (rep.ok) break r;
            if (rep.err.len > 0) return .{ .err = a.dupe(u8, rep.err) catch "the hot runtime refused" };
        }
        if (!uploaded or attempt >= 8) return .{ .err = "the hot runtime did not answer - a new deployment can take a minute to come up; deploy again" };
        if (!builtin.is_test) bu.sleepMs(2500);
    };
    if (body.local) {
        const Made = struct { hot: struct { name: []const u8 = "" } = .{} };
        const made = std.json.parseFromSliceLeaky(Made, a, raw, .{ .ignore_unknown_fields = true }) catch Made{};
        if (validName(made.hot.name)) {
            st = readState(app, uid, a);
            st.local = withName(a, st.local, made.hot.name);
            writeState(app, uid, st);
        }
    }
    return .{ .ok = raw };
}

fn withName(a: std.mem.Allocator, list: []const []const u8, name: []const u8) []const []const u8 {
    for (list) |n| if (std.ascii.eqlIgnoreCase(n, name)) return list;
    const out = a.alloc([]const u8, list.len + 1) catch return list;
    @memcpy(out[0..list.len], list);
    out[list.len] = name;
    return out;
}

fn withoutName(a: std.mem.Allocator, list: []const []const u8, name: []const u8) []const []const u8 {
    const out = a.alloc([]const u8, list.len) catch return list;
    var n: usize = 0;
    for (list) |x| if (!std.ascii.eqlIgnoreCase(x, name)) {
        out[n] = x;
        n += 1;
    };
    return out[0..n];
}

/// The :name of a route, or null after answering 400.
fn nameParam(req: *httpz.Request, res: *httpz.Response) ?[]const u8 {
    const name = req.param("name") orelse "";
    if (!validName(name)) {
        badReq(res, "bad hot name") catch {};
        return null;
    }
    return name;
}

/// DELETE /api/v1/hots/:name — delete one hot: its storage and its alarm go with it, and so does its grant here.
pub fn deleteHot(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const name = nameParam(req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = readState(app, u.id, a);
    const path = try std.fmt.allocPrint(a, "/v1/hots/{s}", .{name});
    const raw = hotCall(app, a, u.id, st, "DELETE", path, "");
    const r = raw orelse return relay(res, a, raw);
    if (!replyOf(a, r).ok) return relay(res, a, raw);
    st.local = withoutName(a, st.local, name);
    writeState(app, u.id, st);
    // The Worker exists for its hots: when the last one goes, so does the Worker, and the account is left as it was.
    // While others remain it stays, because they live in it.
    var left: usize = 1;
    if (hotCall(app, a, u.id, st, "GET", "/v1/hots", "")) |list| {
        const L = struct { ok: bool = false, hots: []const std.json.Value = &.{} };
        if (std.json.parseFromSliceLeaky(L, a, list, .{ .ignore_unknown_fields = true })) |l| {
            if (l.ok) left = l.hots.len;
        } else |_| {}
    }
    if (left > 0) return res.json(.{ .ok = true, .deleted = name, .worker_removed = false, .hots_left = left }, .{});
    const tok = tokOf(app, u.id, a) orelse
        return res.json(.{ .ok = true, .deleted = name, .worker_removed = false, .note = "that was the last hot; log in with Cloudflare again and run teardown to remove the Worker" }, .{});
    if (removeScript(app, a, u.id, tok, &st)) |msg|
        return res.json(.{ .ok = true, .deleted = name, .worker_removed = false, .note = msg }, .{});
    try res.json(.{ .ok = true, .deleted = name, .worker_removed = true, .hots_left = 0 }, .{});
}

/// Delete the Worker script (and with it every hot's storage) and start a new token generation. Null on success,
/// Cloudflare's own words otherwise. A script that is already gone counts as removed.
fn removeScript(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State) ?[]const u8 {
    const acct = if (st.account.len > 0) st.account else tok.account_id;
    const url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ SCRIPT ++ "?force=true", .{ app.cf_api_root, acct }) catch return "out of memory";
    const raw = api(app, a, "DELETE", url, "", tok.key, "") orelse return "could not reach the Cloudflare API to remove the Worker";
    const msg = firstError(a, raw);
    if (msg.len > 0 and std.ascii.indexOfIgnoreCase(msg, "not found") == null and std.ascii.indexOfIgnoreCase(msg, "does not exist") == null)
        return explain(a, "removing the hot runtime", msg);
    // Its Python Worker goes after it (the runtime was bound to it). Best effort: it holds nothing.
    const py_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ PY_SCRIPT ++ "?force=true", .{ app.cf_api_root, acct }) catch return "out of memory";
    _ = api(app, a, "DELETE", py_url, "", tok.key, "");
    // A new generation: a later deployment gets a token the removed script never held.
    st.* = .{ .token_gen = st.token_gen +% 1 };
    writeState(app, uid, st.*);
    log.info("hot runtime removed from the Cloudflare account of u{d}", .{uid});
    return null;
}

/// DELETE /api/v1/hots — take the runtime out of the account: the script, every hot and everything they stored.
pub fn teardown(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
    var st = readState(app, u.id, a);
    if (removeScript(app, a, u.id, tok, &st)) |msg| return badReq(res, msg);
    try res.json(.{ .ok = true, .removed = true }, .{});
}

/// GET /api/v1/hots/:name/events?after=N — the hot's event tail, as the runtime serves it.
pub fn hotEvents(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const name = nameParam(req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const q = try req.query();
    const after = std.fmt.parseInt(u64, q.get("after") orelse "0", 10) catch 0;
    const path = try std.fmt.allocPrint(a, "/v1/hots/{s}/events?after={d}&limit=200", .{ name, after });
    try relay(res, a, hotCall(app, a, u.id, readState(app, u.id, a), "GET", path, ""));
}

const TextReq = struct { text: []const u8 = "" };

fn textBody(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    return std.json.Stringify.valueAlloc(a, TextReq{ .text = text }, .{}) catch null;
}

/// POST /api/v1/hots/:name/command {text} — "/goal ...", "/pause", "/queue ...", or plain words for its inbox.
pub fn hotCommand(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const name = nameParam(req, res) orelse return;
    const body = (req.json(TextReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (std.mem.trim(u8, body.text, " \r\n\t").len == 0) return badReq(res, "empty command");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "/v1/hots/{s}/command", .{name});
    const json = textBody(a, body.text) orelse return http.serverErr(res, "out of memory");
    try relay(res, a, hotCall(app, a, u.id, readState(app, u.id, a), "POST", path, json));
}

const ConfigReq = struct {
    model: ?[]const u8 = null,
    pace_s: ?i64 = null,
    size: ?i64 = null,
    daily_calls: ?i64 = null,
    charter: ?[]const u8 = null,
    paused: ?bool = null,
};

/// POST /api/v1/hots/:name/config — change a hot's settings. There is no `local` here: the owner's machine is
/// granted at deployment or not at all.
pub fn hotConfig(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const name = nameParam(req, res) orelse return;
    const body = (req.json(ConfigReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (body.model) |m| if (m.len == 0 or m[0] != '@') return badReq(res, "a hot runs on the account's Workers AI: pick an @cf/ model");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "/v1/hots/{s}/config", .{name});
    var json = std.json.Stringify.valueAlloc(a, body, .{ .emit_null_optional_fields = false }) catch return http.serverErr(res, "out of memory");
    // a new model brings its own text limit
    if (body.model) |m| json = std.fmt.allocPrint(a, "{s}{s}\"text_max\":{d}}}", .{ json[0 .. json.len - 1], if (json.len > 2) "," else "", modelcfg.goalCharLimit(m) }) catch json;
    try relay(res, a, hotCall(app, a, u.id, readState(app, u.id, a), "POST", path, json));
}

/// GET /api/v1/hots/pad?after=N — the scratchpad the account's hots share.
pub fn padRead(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const q = try req.query();
    const after = std.fmt.parseInt(u64, q.get("after") orelse "0", 10) catch 0;
    const path = try std.fmt.allocPrint(a, "/v1/pad?after={d}", .{after});
    try relay(res, a, hotCall(app, a, u.id, readState(app, u.id, a), "GET", path, ""));
}

/// POST /api/v1/hots/pad {text} — the human writes to the shared scratchpad.
pub fn padWrite(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(TextReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (std.mem.trim(u8, body.text, " \r\n\t").len == 0) return badReq(res, "empty scratchpad entry");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = textBody(a, body.text) orelse return http.serverErr(res, "out of memory");
    try relay(res, a, hotCall(app, a, u.id, readState(app, u.id, a), "POST", "/v1/pad", json));
}

/// POST /api/v1/hots/pad/clear — empty the shared scratchpad, for the next set of hots. The local mirror of it is
/// kept first, renamed with the time it was cleared, so nothing the hots wrote is lost.
pub fn padClear(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = hotCall(app, a, u.id, readState(app, u.id, a), "POST", "/v1/pad/clear", "{}");
    if (raw) |r| if (replyOf(a, r).ok) archivePad(app, a, u.id);
    try relay(res, a, raw);
}

/// _hots/scratchpad.md -> _hots/scratchpad-<YYYYMMDD-HHMMSS>.md (UTC), when there is one.
fn archivePad(app: *App, a: std.mem.Allocator, uid: u64) void {
    const dir = std.fmt.allocPrint(a, "{s}/u{d}/_hots", .{ app.data, uid }) catch return;
    const cur = std.fmt.allocPrint(a, "{s}/scratchpad.md", .{dir}) catch return;
    const body = std.Io.Dir.cwd().readFileAlloc(app.io, cur, a, .limited(16 << 20)) catch return;
    var tb: [24]u8 = undefined;
    const stamp = stampStr(&tb, std.Io.Timestamp.now(app.io, .real).toMilliseconds());
    var nb: [24]u8 = undefined;
    var n: usize = 0;
    for (stamp) |c| if (std.ascii.isDigit(c)) {
        nb[n] = c;
        n += 1;
        if (n == 8) {
            nb[n] = '-';
            n += 1;
        }
    };
    const old = std.fmt.allocPrint(a, "{s}/scratchpad-{s}.md", .{ dir, nb[0..n] }) catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = old, .data = body }) catch return;
    std.Io.Dir.cwd().deleteFile(app.io, cur) catch {};
}

// ---------------------------------------------------------------------------------- the owner's machine

const Job = struct { id: []const u8 = "", t: i64 = 0, instruction: []const u8 = "" };
const Jobs = struct { ok: bool = false, model: []const u8 = "", jobs: []const Job = &.{} };

/// The conversation one job runs in: "hot_<name>_<job id>_<queued at, seconds>". The stamp keeps a job of a hot
/// that was deleted and deployed again under the same name out of the old hot's conversation.
fn jobConv(buf: *[64]u8, name: []const u8, job: Job) ?[]const u8 {
    if (!validName(name) or job.id.len == 0 or job.id.len > 12) return null;
    for (job.id) |c| if (!std.ascii.isAlphanumeric(c)) return null;
    var lb: [NAME_MAX]u8 = undefined;
    return std.fmt.bufPrint(buf, "hot_{s}_{s}_{d}", .{ std.ascii.lowerString(&lb, name), job.id, @divTrunc(@max(job.t, 0), 1000) }) catch null;
}

/// What the unattended turn is told: the hot's instruction, then who sent it and how the turn must end.
fn jobText(a: std.mem.Allocator, name: []const u8, instruction: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(a,
        \\{s}
        \\
        \\--- HOT JOB CONTEXT (engine-authored) ---
        \\This job was sent by {s}, a hot: an autonomous technician that works for this machine's owner from their Cloudflare account. The owner allowed it to use this machine when deploying it. Nobody is watching this turn: do the work with your tools, never ask a question and wait, and end with a plain report of what was done and what the tool results showed. Your final message is sent back to {s} as the job's result.
    , .{ instruction, name, name }) catch null;
}

/// The conversation's newest assistant message (in `a`), or null. `started` reports whether the conversation
/// has any message at all: a job whose turn ran and left no answer is a failure, not a job still to run.
fn lastAssistant(app: *App, a: std.mem.Allocator, uid: u64, conv: []const u8, started: *bool) ?[]const u8 {
    started.* = false;
    const path = std.fmt.allocPrint(a, "{s}/u{d}/_chat/convs/{s}/messages.jsonl", .{ app.data, uid, conv }) catch return null;
    const body = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(8 << 20)) catch return null;
    var out: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (t.len == 0 or t[0] != '{') continue;
        started.* = true;
        const P = struct { role: []const u8 = "", content: []const u8 = "" };
        const p = std.json.parseFromSliceLeaky(P, a, t, .{ .ignore_unknown_fields = true }) catch continue;
        if (std.mem.eql(u8, p.role, "assistant") and p.content.len > 0) out = p.content;
    }
    return out;
}

fn postResult(app: *App, a: std.mem.Allocator, uid: u64, st: State, name: []const u8, job_id: []const u8, ok: bool, result: []const u8) void {
    const path = std.fmt.allocPrint(a, "/v1/hots/{s}/jobs/{s}", .{ name, job_id }) catch return;
    const clipped = result[0..@min(result.len, 6000)];
    const json = std.json.Stringify.valueAlloc(a, .{ .ok = ok, .result = clipped }, .{}) catch return;
    _ = hotCall(app, a, uid, st, "POST", path, json);
}

/// One approved hot, one pass: answer the jobs whose turn has ended, and start the next one. One job runs at a
/// time per hot. Returns how many turns it started.
fn bridgeHot(app: *App, a: std.mem.Allocator, uid: u64, st: State, name: []const u8) usize {
    const raw = hotCall(app, a, uid, st, "GET", std.fmt.allocPrint(a, "/v1/hots/{s}/jobs", .{name}) catch return 0, "") orelse return 0;
    const jobs = std.json.parseFromSliceLeaky(Jobs, a, raw, .{ .ignore_unknown_fields = true }) catch return 0;
    if (!jobs.ok) return 0;
    var lb: [NAME_MAX]u8 = undefined;
    var pb: [40]u8 = undefined;
    const prefix = std.fmt.bufPrint(&pb, "hot_{s}_", .{std.ascii.lowerString(&lb, name)}) catch return 0;
    var started: usize = 0;
    for (jobs.jobs) |job| {
        var cb: [64]u8 = undefined;
        const conv = jobConv(&cb, name, job) orelse {
            postResult(app, a, uid, st, name, job.id, false, "this machine could not name a conversation for the job");
            continue;
        };
        if (chat_engine.isTurnLive(app.io, conv)) continue; // still working
        var began = false;
        if (lastAssistant(app, a, uid, conv, &began)) |answer| {
            postResult(app, a, uid, st, name, job.id, true, answer);
            continue;
        }
        if (began) {
            postResult(app, a, uid, st, name, job.id, false, "the run on the owner's machine ended without an answer");
            continue;
        }
        var live: [64]u8 = undefined;
        if (started > 0 or chat_engine.liveTurnWithPrefix(app.io, prefix, &live) != null) continue; // one at a time
        if (launchJob(app, a, uid, name, conv, jobs.model, job.instruction)) started += 1;
    }
    return started;
}

/// Start the unattended chat turn for one job, on the owner's Cloudflare login and the hot's own model.
fn launchJob(app: *App, a: std.mem.Allocator, uid: u64, name: []const u8, conv: []const u8, model: []const u8, instruction: []const u8) bool {
    const cf = cf_oauth.resolveToken(app, uid, a) orelse return false; // logged out: the job waits
    const text = jobText(a, name, instruction) orelse return false;
    const trio: chat_engine.ModelTrio = .{ .coding = .{ .base_url = cf.base_url, .key = cf.key, .model = if (model.len > 0 and model[0] == '@') model else modelcfg.defaults.cf_model } };
    if (!chat_engine.tryBeginTurn(app.io, conv)) return false;
    // loop=1: the drive loop carries the turn to a finished answer with nobody there, as a scheduled run does.
    chat_engine.spawnTurn(app, uid, conv, trio, text, 1, false, "", false, false);
    log.info("hot {s}: job started on this machine in conversation {s}", .{ name, conv });
    return true;
}

// ---------------------------------------------------------------------------------- the local folder
//
// Every hot a user deploys gets a folder on this machine, one per deployment ("run"), that this server keeps
// up to date from the runtime: {data}/u<uid>/_hots/<name>-<deployed, UTC>/ holds
//   events.log     one readable line per event (tail it), events.jsonl the same events as the runtime wrote them,
//   status.json    the hot's latest status, notes/   the hot's own notes, one file each,
// and {data}/u<uid>/_hots/scratchpad.md is the scratchpad the account's hots share. The desk's Open folder button
// opens a hot's folder. A pass asks only for what moved (the roster carries each hot's event seq and notes
// revision, and the pad's seq), so an idle hot costs one roster call a minute. A hot that is deleted keeps its
// folder: it is the user's record of the run.

const MIRROR_EVERY_TICKS: u32 = 3; // one mirror pass every third bridge tick (60 s)
const EVENTS_PAGE: u32 = 500;
const PAGES_MAX: usize = 8; // a pass reads at most this many pages per hot; the next pass continues

/// Where one deployment of a hot is mirrored, relative to the data dir: u<uid>/_hots/<name>-<YYYYMMDD-HHMMSS>.
pub fn hotFolder(buf: []u8, uid: u64, name: []const u8, created_ms: i64) ?[]const u8 {
    if (!validName(name) or created_ms <= 0) return null;
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(created_ms, 1000)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "u{d}/_hots/{s}-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        uid, name, yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch null;
}

const Cursor = struct { seq: u64 = 0, notes_rev: u64 = 0, notes_t: i64 = 0, pad_seq: u64 = 0 };

fn readCursor(app: *App, a: std.mem.Allocator, dir: []const u8) Cursor {
    const path = std.fmt.allocPrint(a, "{s}/.mirror.json", .{dir}) catch return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(4096)) catch return .{};
    return std.json.parseFromSliceLeaky(Cursor, a, data, .{ .ignore_unknown_fields = true }) catch .{};
}

fn writeCursor(app: *App, a: std.mem.Allocator, dir: []const u8, c: Cursor) void {
    const path = std.fmt.allocPrint(a, "{s}/.mirror.json", .{dir}) catch return;
    const body = std.json.Stringify.valueAlloc(a, c, .{}) catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = body }) catch {};
}

fn appendTo(app: *App, a: std.mem.Allocator, path: []const u8, data: []const u8) void {
    if (data.len > 0) http.appendFile(app.io, a, path, data) catch {};
}

/// "2026-10-01 12:00:01" (UTC) for a ms stamp. Pure.
fn stampStr(buf: []u8, ms: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, @divTrunc(ms, 1000))) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch "";
}

const Ev = struct { seq: u64 = 0, t: i64 = 0, kind: []const u8 = "", text: []const u8 = "", i: ?i64 = null };

/// One event as a line of events.log: "<UTC time>  r<i>  <kind>  <text>", the text's own line breaks indented
/// under it so a tail stays readable. Pure but for allocation.
fn logLine(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), e: Ev) !void {
    var tb: [24]u8 = undefined;
    var ib: [12]u8 = undefined;
    const iter: []const u8 = if (e.i) |i| (std.fmt.bufPrint(&ib, "r{d}", .{i}) catch "") else "";
    try out.print(a, "{s}  {s: <4} {s: <8} ", .{ stampStr(&tb, e.t), iter, e.kind[0..@min(e.kind.len, 8)] });
    var it = std.mem.splitScalar(u8, e.text, '\n');
    var first = true;
    while (it.next()) |ln| {
        if (!first) try out.appendSlice(a, "\n                                   ");
        try out.appendSlice(a, std.mem.trimEnd(u8, ln, "\r"));
        first = false;
    }
    try out.append(a, '\n');
}

/// A note's name as a file name here: the runtime's own rule, and never "." or "..".
fn noteFileOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

const RosterHot = struct { name: []const u8 = "", created: i64 = 0, seq: u64 = 0, notes_rev: u64 = 0 };

/// Bring one hot's folder up to date.
fn mirrorHot(app: *App, a: std.mem.Allocator, uid: u64, st: State, h: RosterHot, status: std.json.Value) void {
    var fb: [160]u8 = undefined;
    const rel = hotFolder(&fb, uid, h.name, h.created) orelse return;
    const dir = std.fmt.allocPrint(a, "{s}/{s}", .{ app.data, rel }) catch return;
    const notes_dir = std.fmt.allocPrint(a, "{s}/notes", .{dir}) catch return;
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, notes_dir, .default_dir) catch return;
    if (std.json.Stringify.valueAlloc(a, status, .{ .whitespace = .indent_2 })) |body| {
        const sp = std.fmt.allocPrint(a, "{s}/status.json", .{dir}) catch return;
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = sp, .data = body }) catch {};
    } else |_| {}
    var cur = readCursor(app, a, dir);

    // events, oldest first, from where the folder left off
    const jl = std.fmt.allocPrint(a, "{s}/events.jsonl", .{dir}) catch return;
    const lg = std.fmt.allocPrint(a, "{s}/events.log", .{dir}) catch return;
    var page: usize = 0;
    while (h.seq > cur.seq and page < PAGES_MAX) : (page += 1) {
        const path = std.fmt.allocPrint(a, "/v1/hots/{s}/events?after={d}&limit={d}&forward=1", .{ h.name, cur.seq, EVENTS_PAGE }) catch break;
        const raw = hotCall(app, a, uid, st, "GET", path, "") orelse break;
        const R = struct { ok: bool = false, events: []const std.json.Value = &.{} };
        const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch break;
        if (!r.ok or r.events.len == 0) break;
        var jout: std.ArrayListUnmanaged(u8) = .empty;
        var lout: std.ArrayListUnmanaged(u8) = .empty;
        const before = cur.seq;
        for (r.events) |v| {
            const e = std.json.parseFromValueLeaky(Ev, a, v, .{ .ignore_unknown_fields = true }) catch continue;
            if (e.seq <= cur.seq) continue;
            cur.seq = e.seq;
            const line = std.json.Stringify.valueAlloc(a, v, .{}) catch continue;
            jout.appendSlice(a, line) catch {};
            jout.append(a, '\n') catch {};
            logLine(a, &lout, e) catch {};
        }
        appendTo(app, a, jl, jout.items);
        appendTo(app, a, lg, lout.items);
        if (cur.seq == before) break;
    }

    // notes: what changed since the newest stamp held; then drop the files of notes the hot deleted
    if (h.notes_rev != cur.notes_rev) notes: {
        var names: []const []const u8 = &.{};
        var pages: usize = 0;
        while (pages < PAGES_MAX) : (pages += 1) {
            const path = std.fmt.allocPrint(a, "/v1/hots/{s}/notes?after={d}", .{ h.name, cur.notes_t }) catch break :notes;
            const raw = hotCall(app, a, uid, st, "GET", path, "") orelse break :notes;
            const N = struct { name: []const u8 = "", t: i64 = 0, text: []const u8 = "" };
            const R = struct { ok: bool = false, more: bool = false, notes: []const N = &.{}, names: []const []const u8 = &.{} };
            const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch break :notes;
            if (!r.ok) break :notes;
            names = r.names;
            for (r.notes) |n| {
                cur.notes_t = @max(cur.notes_t, n.t);
                if (!noteFileOk(n.name)) continue;
                const np = std.fmt.allocPrint(a, "{s}/{s}", .{ notes_dir, n.name }) catch continue;
                std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = np, .data = n.text }) catch {};
            }
            if (!r.more) break;
        }
        if (std.Io.Dir.cwd().openDir(app.io, notes_dir, .{ .iterate = true })) |d_const| {
            var d = d_const;
            defer d.close(app.io);
            var gone: std.ArrayListUnmanaged([]const u8) = .empty;
            var it = d.iterate();
            while (it.next(app.io) catch null) |ent| {
                if (ent.kind != .file) continue;
                const keep = for (names) |n| {
                    if (std.mem.eql(u8, n, ent.name)) break true;
                } else false;
                if (!keep) gone.append(a, a.dupe(u8, ent.name) catch continue) catch {};
            }
            for (gone.items) |n| d.deleteFile(app.io, n) catch {};
        } else |_| {}
        cur.notes_rev = h.notes_rev;
    }
    writeCursor(app, a, dir, cur);
}

/// The shared scratchpad as {data}/u<uid>/_hots/scratchpad.md, rewritten when its seq moves.
fn mirrorPad(app: *App, a: std.mem.Allocator, uid: u64, st: State, pad_seq: u64) void {
    const dir = std.fmt.allocPrint(a, "{s}/u{d}/_hots", .{ app.data, uid }) catch return;
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch return;
    var cur = readCursor(app, a, dir);
    if (cur.pad_seq == pad_seq) return;
    const raw = hotCall(app, a, uid, st, "GET", "/v1/pad?after=0", "") orelse return;
    const E = struct { seq: u64 = 0, t: i64 = 0, from: []const u8 = "", text: []const u8 = "" };
    const R = struct { ok: bool = false, entries: []const E = &.{} };
    const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch return;
    if (!r.ok) return;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(a, "# Shared scratchpad\n\nWhat the hots of this account leave for each other (and what you add from the desk or `veil hot pad`). The newest 200 entries, oldest first; rewritten as it changes.\n\n") catch return;
    for (r.entries) |e| {
        var tb: [24]u8 = undefined;
        out.print(a, "## {d}. {s} - {s} UTC\n\n{s}\n\n", .{ e.seq, e.from, stampStr(&tb, e.t), e.text }) catch return;
    }
    const path = std.fmt.allocPrint(a, "{s}/scratchpad.md", .{dir}) catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch return;
    cur.pad_seq = pad_seq;
    writeCursor(app, a, dir, cur);
}

/// One mirror pass for a user: the roster, then each hot's folder, then the scratchpad.
fn mirrorUser(app: *App, a: std.mem.Allocator, uid: u64, st: State) void {
    const raw = hotCall(app, a, uid, st, "GET", "/v1/hots", "") orelse return;
    const R = struct { ok: bool = false, pad_seq: u64 = 0, hots: []const std.json.Value = &.{} };
    const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch return;
    if (!r.ok) return;
    for (r.hots) |v| {
        const h = std.json.parseFromValueLeaky(RosterHot, a, v, .{ .ignore_unknown_fields = true }) catch continue;
        if (h.created > 0) mirrorHot(app, a, uid, st, h, v);
    }
    mirrorPad(app, a, uid, st, r.pad_seq);
}

/// A runtime uploaded by an older veil is replaced by this one's when the account is the one it is in. The hots
/// keep their storage; only the code changes.
fn upgradeRuntime(app: *App, a: std.mem.Allocator, uid: u64, st: *State) void {
    var hb: [16]u8 = undefined;
    if (st.url.len == 0 or std.mem.eql(u8, st.script_hash, scriptHash(&hb))) return;
    const tok = tokOf(app, uid, a) orelse return;
    if (!std.mem.eql(u8, tok.account_id, st.account)) return; // logged into another account: leave that one alone
    // A refused update is not tried again for a quarter of an hour: the hots keep running on what they have.
    const now = nowS(app.io);
    if (now - upgrade_failed_s.load(.monotonic) < 900) return;
    var uploaded = false;
    if (ensureRuntime(app, a, uid, tok, st, &uploaded)) |msg| {
        st.last_error = msg;
        upgrade_failed_s.store(now, .monotonic);
        log.warn("hot runtime for u{d} could not be updated: {s}", .{ uid, msg });
    }
    writeState(app, uid, st.*);
}

var upgrade_failed_s: std.atomic.Value(i64) = .init(0);

/// One pass over every user with hots: run the jobs of those allowed onto this machine, and (when `mirror`) bring
/// each hot's local folder up to date, first replacing a runtime an older veil uploaded.
fn tick(app: *App, mirror: bool) void {
    var backend_on = true; // VEIL_CHAT_BACKEND=0 switches the served chat turn off, and the jobs with it
    if (app.sup.parent_env) |env| if (env.get("VEIL_CHAT_BACKEND")) |v| {
        if (std.mem.eql(u8, std.mem.trim(u8, v, " \r\n\t"), "0")) backend_on = false;
    };
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var root = std.Io.Dir.cwd().openDir(app.io, app.data, .{ .iterate = true }) catch return;
    defer root.close(app.io);
    var it = root.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (ent.kind != .directory or ent.name.len < 2 or ent.name[0] != 'u') continue;
        const uid = std.fmt.parseInt(u64, ent.name[1..], 10) catch continue;
        var st = readState(app, uid, a);
        if (st.url.len == 0) continue;
        // Admin only, as the routes are: a state file is just a file, and it must not start full-tool turns
        // for an account that could not have deployed a hot.
        const owner = app.auth.userById(uid) orelse continue;
        if (!app.auth.isAdmin(owner)) continue;
        if (mirror) {
            upgradeRuntime(app, a, uid, &st);
            mirrorUser(app, a, uid, st);
        }
        if (backend_on) for (st.local) |name| if (validName(name)) {
            _ = bridgeHot(app, a, uid, st, name);
        };
    }
}

/// The hots thread: for the life of the process, a pass every BRIDGE_EVERY_MS, mirroring every third. A raw thread,
/// so a raw sleep.
pub fn bgLoop(app: *App) void {
    var n: u32 = 0;
    while (true) : (n +%= 1) {
        var slept: u64 = 0;
        while (slept < BRIDGE_EVERY_MS) : (slept += 100) bu.sleepMs(100);
        tick(app, n % MIRROR_EVERY_TICKS == 0);
    }
}

// ---------------------------------------------------------------------------
// tests — see harness/TESTING.md. The Cloudflare API and the runtime are one fakehttp stand-in; the runtime's own
// behaviour is tested where it runs (cloud/hot.test.mjs, under node).
// ---------------------------------------------------------------------------

const tt = std.testing;

fn curlRuns(gpa: std.mem.Allocator, io: std.Io) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "curl", "--version" }, .stdout_limit = .limited(16 << 10) }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

test "every hot route is gated: an anonymous caller gets 401 and nothing runs" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cfhot-gate-tmp");
    defer ta.deinit();
    inline for (.{ listHots, createHot, deleteHot, teardown, hotEvents, hotCommand, hotConfig, padRead, padWrite, padClear }) |h| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.param("name", "Gary");
        web.json(.{ .goal = "watch the tide tables", .text = "/pause" });
        try h(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
}

test "the runtime and this server agree: the limit, the primary's name, the goal loop's stop rules, the default model" {
    const goal = @import("../worker/chat/goal.zig");
    var b: [96]u8 = undefined;
    try tt.expect(std.mem.indexOf(u8, HOT_JS, try std.fmt.bufPrint(&b, "export const MAX_HOTS = {d};", .{MAX_HOTS})) != null);
    try tt.expect(std.mem.indexOf(u8, HOT_JS, "export const PRIMARY = \"" ++ PRIMARY ++ "\";") != null);
    try tt.expect(std.mem.indexOf(u8, HOT_JS, try std.fmt.bufPrint(&b, "export const PLATEAU = {d};", .{goal.PLATEAU})) != null);
    try tt.expect(std.mem.indexOf(u8, HOT_JS, try std.fmt.bufPrint(&b, "export const BUDGET_DEFAULT = {d};", .{goal.BUDGET_DEFAULT})) != null);
    try tt.expect(std.mem.indexOf(u8, HOT_JS, try std.fmt.bufPrint(&b, "model: \"{s}\",", .{modelcfg.defaults.cf_model})) != null);
    try tt.expect(std.mem.indexOf(u8, HOT_JS, "export class Hot ") != null); // the class the upload's binding names
    try tt.expectEqual(@as(usize, 3), MAX_HOTS);
    try tt.expectEqualStrings("Gary", PRIMARY);
}

test "names: the rule a URL segment and a conversation id both need" {
    try tt.expect(validName("Gary") and validName("ada-2") and validName("a_b"));
    try tt.expect(!validName("") and !validName("9lives") and !validName("a b") and !validName("a/b") and !validName("pad?x"));
    try tt.expect(!validName("a" ** 25) and validName("a" ** 24));
    var cb: [64]u8 = undefined;
    try tt.expectEqualStrings("hot_gary_j12_1790000000", jobConv(&cb, "Gary", .{ .id = "j12", .t = 1790000000123 }).?);
    try tt.expect(jobConv(&cb, "Gary", .{ .id = "../x", .t = 1 }) == null);
    try tt.expect(jobConv(&cb, "Gary", .{ .id = "", .t = 1 }) == null);
    // the longest name and id still fit a conversation id (64)
    try tt.expect(jobConv(&cb, "a" ** 24, .{ .id = "j12345678901", .t = 9_999_999_999_999 }).?.len <= 64);
}

test "the runtime's token is derived, never stored: stable for one user+account+generation, different for any other" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    var ta = try http.testApp(gpa, threaded.io(), "zig-cfhot-token-tmp");
    defer ta.deinit();
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    try tt.expectEqualStrings(hotToken(&ta.app, 1, "acct", 0, &a), hotToken(&ta.app, 1, "acct", 0, &b));
    for (a) |c| try tt.expect(std.ascii.isHex(c));
    try tt.expect(!std.mem.eql(u8, hotToken(&ta.app, 1, "acct", 0, &a), hotToken(&ta.app, 2, "acct", 0, &b)));
    try tt.expect(!std.mem.eql(u8, hotToken(&ta.app, 1, "acct", 0, &a), hotToken(&ta.app, 1, "acct2", 0, &b)));
    try tt.expect(!std.mem.eql(u8, hotToken(&ta.app, 1, "acct", 0, &a), hotToken(&ta.app, 1, "acct", 1, &b)));
    ta.app.server_key = [_]u8{0x11} ** 32;
    try tt.expect(!std.mem.eql(u8, &a, hotToken(&ta.app, 1, "acct", 0, &b)));
}

test "the token only goes to a workers.dev address, or to loopback while the API itself is a loopback stand-in" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    var ta = try http.testApp(gpa, threaded.io(), "zig-cfhot-url-tmp");
    defer ta.deinit();
    const app = &ta.app;
    try tt.expect(allowedUrl(app, "https://veil-hots.acme.workers.dev"));
    try tt.expect(!allowedUrl(app, "http://veil-hots.acme.workers.dev")); // not https
    try tt.expect(!allowedUrl(app, "https://veil-hots.acme.workers.dev.evil.example"));
    try tt.expect(!allowedUrl(app, "https://evil.example/x.workers.dev"));
    try tt.expect(!allowedUrl(app, "https://user@veil-hots.acme.workers.dev"));
    try tt.expect(!allowedUrl(app, "https://evil.example:443#.workers.dev"));
    try tt.expect(!allowedUrl(app, "http://127.0.0.1:8790")); // the real API root: no loopback runtime
    try tt.expect(!allowedUrl(app, ""));
    app.cf_api_root = "http://127.0.0.1:8790/client/v4";
    try tt.expect(allowedUrl(app, "http://127.0.0.1:8791"));
    try tt.expect(!allowedUrl(app, "http://127.0.0.1:8791/x"));
    try tt.expect(!allowedUrl(app, "http://10.0.0.5:8791"));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try tt.expectEqualStrings("http://127.0.0.1:8790", runtimeUrl(app, arena.allocator(), "acme").?);
    app.cf_api_root = "https://api.cloudflare.com/client/v4";
    try tt.expectEqualStrings("https://veil-hots.acme.workers.dev", runtimeUrl(app, arena.allocator(), "acme").?);
}

test "the upload carries the bindings and keeps the secret; the class migration rides only a first upload" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try uploadBody(a, "----b", true, .{ .python = true, .browser = true });
    const again = try uploadBody(a, "----b", false, .{ .python = false, .browser = false });
    // the metadata part is JSON a real parser reads
    const meta_at = std.mem.indexOf(u8, first, "\r\n\r\n").? + 4;
    const meta = first[meta_at .. meta_at + std.mem.indexOf(u8, first[meta_at..], "\r\n").?];
    const M = struct {
        main_module: []const u8,
        compatibility_date: []const u8,
        bindings: []const struct { type: []const u8, name: []const u8, class_name: []const u8 = "", service: []const u8 = "" },
        keep_bindings: []const []const u8,
        migrations: ?struct { new_tag: []const u8, new_sqlite_classes: []const []const u8 } = null,
    };
    const m = try std.json.parseFromSliceLeaky(M, a, meta, .{});
    try tt.expectEqualStrings("hot.js", m.main_module);
    try tt.expectEqual(@as(usize, 4), m.bindings.len);
    try tt.expectEqualStrings("service", m.bindings[2].type);
    try tt.expectEqualStrings(PY_SCRIPT, m.bindings[2].service);
    try tt.expectEqualStrings("browser", m.bindings[3].type);
    const again_meta = again[0..std.mem.indexOf(u8, again, "Content-Type: application/javascript+module").?];
    try tt.expect(std.mem.indexOf(u8, again_meta, "\"service\"") == null and std.mem.indexOf(u8, again_meta, "\"browser\"") == null);
    // the Python Worker: the flag that makes a .py module a Worker, and the module as Python
    const py = try pyUploadBody(a, "----b");
    try tt.expect(std.mem.indexOf(u8, py, "\"compatibility_flags\":[\"python_workers\"]") != null);
    try tt.expect(std.mem.indexOf(u8, py, "Content-Type: text/x-python\r\n\r\n" ++ HOT_PY) != null);
    try tt.expect(std.mem.indexOf(u8, HOT_PY, "class Default(WorkerEntrypoint):") != null);
    try tt.expectEqualStrings("ai", m.bindings[0].type);
    try tt.expectEqualStrings("Hot", m.bindings[1].class_name);
    try tt.expectEqualStrings("secret_text", m.keep_bindings[0]);
    try tt.expectEqualStrings("Hot", m.migrations.?.new_sqlite_classes[0]);
    try tt.expect(std.mem.indexOf(u8, again, "migrations") == null);
    try tt.expect(std.mem.indexOf(u8, first, HOT_JS) != null);
    try tt.expect(std.mem.endsWith(u8, first, "\r\n------b--\r\n"));
    try tt.expect(std.mem.indexOf(u8, first, "HOT_TOKEN\",\"text\"") == null); // no secret in a body that rides a file
}

/// The stand-in's answers: the Cloudflare API on /client/v4, the runtime on /v1.
const StandIn = struct {
    const w = fakehttp.wire;
    const ok = w("{\"success\":true,\"errors\":[],\"result\":{}}");
    const subdomain = w("{\"success\":true,\"errors\":[],\"result\":{\"subdomain\":\"acme\"}}");
    const no_script = w("{\"success\":false,\"errors\":[{\"code\":10007,\"message\":\"This Worker does not exist on your account.\"}]}");
    const no_browser = w("{\"success\":false,\"errors\":[{\"code\":10021,\"message\":\"Browser Rendering is not enabled for this account.\"}]}");
    const made = w("{\"ok\":true,\"hot\":{\"name\":\"Gary\",\"state\":\"working\",\"local\":true}}");
    const full = w("{\"ok\":false,\"err\":\"this account already has 3 hots (the limit); delete one first\"}");
};

test "a first deployment uploads the runtime, sets its token, creates the hot and records the owner's-machine grant; the next costs one call" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfhot-deploy-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/accounts/acct/workers/subdomain", .reply = StandIn.subdomain },
        .{ .method = "GET", .path = "/workers/scripts/veil-hots/settings", .reply = StandIn.no_script },
        .{ .method = "PUT", .path = "/workers/scripts/veil-hots-py", .reply = StandIn.ok },
        .{ .method = "PUT", .path = "/workers/scripts/veil-hots/secrets", .reply = StandIn.ok },
        // this account has no browser: the upload that asks for one is refused, the next is taken
        .{ .method = "PUT", .path = "/workers/scripts/veil-hots", .reply = StandIn.no_browser, .times = 2 },
        .{ .method = "PUT", .path = "/workers/scripts/veil-hots", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/workers/scripts/veil-hots/subdomain", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/v1/hots", .reply = StandIn.made, .times = 1 },
        .{ .method = "POST", .path = "/v1/hots", .reply = StandIn.full },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.no_script);
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    const stand_in = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok: Tok = .{ .key = "oauth-bearer", .account_id = "acct" };

    // refused before any call: no goal, a bad name, a model Workers AI does not run
    try tt.expect(deploy(&ta.app, a, 1, tok, .{ .goal = "" }) == .err);
    try tt.expect(deploy(&ta.app, a, 1, tok, .{ .goal = "watch the tides", .name = "bad name" }) == .err);
    try tt.expect(deploy(&ta.app, a, 1, tok, .{ .goal = "watch the tides", .model = "gpt-4o" }) == .err);

    const first = deploy(&ta.app, a, 1, tok, .{ .goal = "watch the tide tables", .local = true, .pace_s = 120 });
    if (first == .err) std.debug.print("deploy refused: {s}\n", .{first.err});
    try tt.expect(first == .ok);
    const st = readState(&ta.app, 1, a);
    try tt.expectEqualStrings("acct", st.account);
    try tt.expectEqualStrings(stand_in, st.url); // the stand-in plays the account's workers.dev
    var hb: [16]u8 = undefined;
    try tt.expectEqualStrings(scriptHash(&hb), st.script_hash);
    try tt.expectEqual(@as(usize, 1), st.local.len);
    try tt.expectEqualStrings("Gary", st.local[0]);
    // Python went up and is bound; the browser was refused, and the state says why in Cloudflare's words
    try tt.expect(st.python and !st.browser);
    try tt.expect(std.mem.indexOf(u8, st.tools_note, "the browser is off: Browser Rendering is not enabled") != null);

    // The state file holds no secret: not the runtime's token, not the OAuth bearer.
    var tb: [64]u8 = undefined;
    const token = hotToken(&ta.app, 1, "acct", 0, &tb);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/u1/" ++ STATE_FILE, a, .limited(64 << 10));
    try tt.expect(std.mem.indexOf(u8, on_disk, token) == null);
    try tt.expect(std.mem.indexOf(u8, on_disk, "oauth-bearer") == null);

    // The second deployment finds the runtime current: straight to the runtime, whose refusal comes back in its words.
    const second = deploy(&ta.app, a, 1, tok, .{ .goal = "a fourth hot", .name = "Rex" });
    try tt.expect(second == .err);
    try tt.expect(std.mem.indexOf(u8, second.err, "already has 3 hots") != null);

    srv.stop();
    running = false;
    // subdomain, exists?, the Python Worker, the runtime (refused twice with the browser, taken without),
    // secret, route, create - in that order; then one more create
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("GET", "/accounts/acct/workers/subdomain"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("GET", "/workers/scripts/veil-hots/settings"));
    try tt.expectEqual(@as(?usize, 2), srv.firstCall("PUT", "/accounts/acct/workers/scripts/veil-hots-py"));
    try tt.expectEqual(@as(?usize, 6), srv.firstCall("PUT", "/workers/scripts/veil-hots/secrets"));
    try tt.expectEqual(@as(?usize, 7), srv.firstCall("POST", "/workers/scripts/veil-hots/subdomain"));
    try tt.expectEqual(@as(?usize, 8), srv.firstCall("POST", "/v1/hots"));
    try tt.expectEqual(@as(usize, 5), srv.countCalls("PUT", "/accounts/acct/workers/scripts/veil-hots")); // py, 3 runtime tries, secret
    try tt.expectEqual(@as(usize, 2), srv.countCalls("POST", "/v1/hots"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/workers/subdomain"));
    try tt.expectEqual(@as(usize, 10), srv.call_count);
}

test "the bridge posts a finished job's answer back, fails a run that left none, and never reruns either" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfhot-bridge-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    // j1's turn has answered; j2's ran and left only the user message.
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, root ++ "/u1/_chat/convs/hot_gary_j1_1790000000", .default_dir);
    _ = try cwd.createDirPathStatus(io, root ++ "/u1/_chat/convs/hot_gary_j2_1790000001", .default_dir);
    try cwd.writeFile(io, .{ .sub_path = root ++ "/u1/_chat/convs/hot_gary_j1_1790000000/messages.jsonl", .data = "{\"role\":\"user\",\"content\":\"run the suite\",\"kind\":\"\",\"ts\":1}\n{\"role\":\"assistant\",\"content\":\"working on it\",\"kind\":\"\",\"ts\":2}\n{\"role\":\"assistant\",\"content\":\"42 passed, 0 failed \\\"quoted\\\"\",\"kind\":\"\",\"ts\":3}\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/u1/_chat/convs/hot_gary_j2_1790000001/messages.jsonl", .data = "{\"role\":\"user\",\"content\":\"build it\",\"kind\":\"\",\"ts\":1}\n" });

    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/v1/hots/Gary/jobs", .reply = w("{\"ok\":true,\"model\":\"@cf/x/y\",\"jobs\":[{\"id\":\"j1\",\"t\":1790000000123,\"instruction\":\"run the suite\",\"status\":\"pending\"},{\"id\":\"j2\",\"t\":1790000001000,\"instruction\":\"build it\",\"status\":\"pending\"}]}") },
        .{ .method = "POST", .path = "/v1/hots/Gary/jobs/", .reply = w("{\"ok\":true}") },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, w("{\"ok\":false,\"err\":\"not found\"}"));
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    const st: State = .{ .account = "acct", .url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port}), .local = &.{"Gary"} };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try tt.expectEqual(@as(usize, 0), bridgeHot(&ta.app, a, 1, st, "Gary")); // nothing was started
    var began = false;
    try tt.expectEqualStrings("42 passed, 0 failed \"quoted\"", lastAssistant(&ta.app, a, 1, "hot_gary_j1_1790000000", &began).?);
    try tt.expect(lastAssistant(&ta.app, a, 1, "hot_gary_j9_1", &began) == null and !began);

    srv.stop();
    running = false;
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("GET", "/v1/hots/Gary/jobs"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("POST", "/v1/hots/Gary/jobs/j1"));
    try tt.expectEqual(@as(?usize, 2), srv.firstCall("POST", "/v1/hots/Gary/jobs/j2"));
    try tt.expectEqual(@as(usize, 3), srv.call_count);
    // What went back for j1 is the turn's last answer, as JSON a parser reads back whole. (fakehttp keeps the
    // FIRST request only, so the body is rebuilt the way postResult builds it.)
    const sent = try std.json.Stringify.valueAlloc(a, .{ .ok = true, .result = "42 passed, 0 failed \"quoted\"" }, .{});
    const back = try std.json.parseFromSliceLeaky(struct { ok: bool, result: []const u8 }, a, sent, .{});
    try tt.expectEqualStrings("42 passed, 0 failed \"quoted\"", back.result);
    const text = jobText(a, "Gary", "run the suite").?;
    try tt.expect(std.mem.startsWith(u8, text, "run the suite\n") and std.mem.indexOf(u8, text, "sent back to Gary") != null);
}

test "a grant list keeps one entry per hot, whatever the case, and drops it on delete" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l: []const []const u8 = &.{};
    l = withName(a, l, "Gary");
    l = withName(a, l, "gary");
    l = withName(a, l, "Ada");
    try tt.expectEqual(@as(usize, 2), l.len);
    l = withoutName(a, l, "GARY");
    try tt.expectEqual(@as(usize, 1), l.len);
    try tt.expectEqualStrings("Ada", l[0]);
}

test "each deployment of a hot has its own folder name: the name and when it was deployed, in UTC" {
    var b: [160]u8 = undefined;
    try tt.expectEqualStrings("u3/_hots/Gary-20261001-120005", hotFolder(&b, 3, "Gary", 1790856005123).?);
    try tt.expectEqualStrings("u3/_hots/Gary-20261001-120006", hotFolder(&b, 3, "Gary", 1790856006000).?); // a redeploy a second later is a new run
    try tt.expect(hotFolder(&b, 3, "../x", 1790856005123) == null);
    try tt.expect(hotFolder(&b, 3, "Gary", 0) == null); // an unreachable hot names no deployment
    try tt.expect(noteFileOk("findings.md") and !noteFileOk("..") and !noteFileOk("a/b") and !noteFileOk("a\\b") and !noteFileOk(""));
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try logLine(arena.allocator(), &out, .{ .seq = 4, .t = 1790856005123, .kind = "verdict", .text = "improved [3/10]\nsecond line", .i = 2 });
    try logLine(arena.allocator(), &out, .{ .seq = 5, .t = 1790856006000, .kind = "status", .text = "rested" });
    try tt.expectEqualStrings("2026-10-01 12:00:05  r2   verdict  improved [3/10]\n                                   second line\n2026-10-01 12:00:06       status   rested\n", out.items);
}

test "a mirror pass writes each hot's folder and the scratchpad, and the next pass asks only for what moved" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfhot-mirror-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/v1/hots/Gary/events?after=0&", .reply = w("{\"ok\":true,\"seq\":2,\"events\":[{\"seq\":1,\"t\":1790856005123,\"kind\":\"goal\",\"text\":\"map the harbours\"},{\"seq\":2,\"t\":1790856006000,\"kind\":\"pick\",\"text\":\"list them\",\"i\":1}]}") },
        .{ .method = "GET", .path = "/v1/hots/Gary/notes?after=0", .reply = w("{\"ok\":true,\"more\":false,\"names\":[\"harbours.md\"],\"notes\":[{\"name\":\"harbours.md\",\"t\":9,\"text\":\"# Harbours\\n- Tofino\"},{\"name\":\"../escape\",\"t\":10,\"text\":\"x\"}]}") },
        .{ .method = "GET", .path = "/v1/pad?after=0", .reply = w("{\"ok\":true,\"seq\":1,\"entries\":[{\"seq\":1,\"t\":1790856005123,\"from\":\"Gary\",\"text\":\"harbours are in note harbours.md\"}]}") },
        .{ .method = "GET", .path = "/v1/hots", .reply = w("{\"ok\":true,\"pad_seq\":1,\"hots\":[{\"name\":\"Gary\",\"state\":\"working\",\"created\":1790856005123,\"seq\":2,\"notes_rev\":1},{\"name\":\"Ada\",\"state\":\"unreachable\"}]}") },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, w("{\"ok\":false,\"err\":\"not found\"}"));
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    const st: State = .{ .account = "acct", .url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port}) };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    mirrorUser(&ta.app, a, 1, st);
    mirrorUser(&ta.app, a, 1, st); // nothing moved: one roster call, nothing else
    srv.stop();
    running = false;

    const dir = root ++ "/u1/_hots/Gary-20261001-120005";
    const cwd = std.Io.Dir.cwd();
    const lg = try cwd.readFileAlloc(io, dir ++ "/events.log", a, .limited(1 << 20));
    try tt.expectEqualStrings("2026-10-01 12:00:05       goal     map the harbours\n2026-10-01 12:00:06  r1   pick     list them\n", lg);
    const jl = try cwd.readFileAlloc(io, dir ++ "/events.jsonl", a, .limited(1 << 20));
    try tt.expectEqual(@as(usize, 2), std.mem.count(u8, jl, "\n"));
    try tt.expectEqualStrings("# Harbours\n- Tofino", try cwd.readFileAlloc(io, dir ++ "/notes/harbours.md", a, .limited(4096)));
    try tt.expect(std.mem.indexOf(u8, try cwd.readFileAlloc(io, dir ++ "/status.json", a, .limited(4096)), "\"working\"") != null);
    try tt.expect(std.mem.indexOf(u8, try cwd.readFileAlloc(io, root ++ "/u1/_hots/scratchpad.md", a, .limited(4096)), "harbours are in note harbours.md") != null);
    try tt.expectError(error.FileNotFound, cwd.statFile(io, root ++ "/u1/_hots/escape", .{})); // a note name never leaves notes/
    try tt.expectEqual(@as(usize, 2), srv.countCalls("GET", "/v1/hots?"[0..8]) - srv.countCalls("GET", "/v1/hots/")); // the two roster calls
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/v1/hots/Gary/events"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/v1/hots/Gary/notes"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/v1/pad"));
    try tt.expectEqual(@as(usize, 5), srv.call_count);
}

test "removing the Worker forgets the deployment, every grant to this machine, and the token the script held" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cfhot-dellast-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "DELETE", .path = "/workers/scripts/veil-hots?force=true", .reply = w("{\"success\":true,\"errors\":[],\"result\":null}") },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, w("{\"success\":false,\"errors\":[{\"code\":10007,\"message\":\"x\"}]}"));
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .account = "acct", .url = "http://127.0.0.1:1", .script_hash = "abc", .token_gen = 4, .local = &.{"Gary"} };
    writeState(&ta.app, 1, st);
    try tt.expectEqual(@as(?[]const u8, null), removeScript(&ta.app, a, 1, .{ .key = "k", .account_id = "acct" }, &st));
    srv.stop();
    running = false;
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-hots?force=true"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-hots-py?force=true")); // then its Python Worker
    const after = readState(&ta.app, 1, a);
    try tt.expectEqualStrings("", after.url); // forgotten: the next deploy uploads again
    try tt.expectEqual(@as(usize, 0), after.local.len); // no grant outlives its hot
    try tt.expectEqual(@as(u32, 5), after.token_gen); // and the removed script's token is never valid again
}
