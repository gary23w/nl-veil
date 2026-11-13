//! cf_harness.zig — the web veil's worker harness, reached from this server.
//!
//! WHAT: the browser chat (docs/chat) works through one Worker in the user's own Cloudflare account, "veil-web"
//! (cloud/veil-web/veil-web.js). It keeps a FIFO job queue, schedules, chats, usage and limits. This file lets the
//! desk and the local web app see that same queue: it finds the user's harness and relays a small set of calls to it.
//!
//! HOW: the harness obeys any Cloudflare OAuth access token that belongs to the account owning its workers.dev name
//! (its `owner` check). This server already holds that login (cf_oauth.resolveToken), so there is no new credential
//! and nothing to paste: the account's workers.dev subdomain comes from the Cloudflare API (cf_tot.workersSubdomain),
//! the harness is `https://veil-web.<subdomain>.workers.dev`, and every call carries the login as its bearer.
//! Calls go from this machine straight to the user's Worker; nothing sits between.
//!
//! WHERE THE TOKEN MAY GO: only to `https://veil-web.<name>.workers.dev`, or - only while the Cloudflare API itself is
//! a loopback stand-in (NL_CF_API_ROOT, the tests below) - to that loopback (harnessUrlOk). The address is remembered
//! in {data}/u{uid}/cf_harness.json once the harness has answered there; a file edited to name another host gets no
//! call. The file holds an account id and an address, no secret.
//!
//!   GET    /api/v1/harness                connected? the address, reachable?, and the harness's own status
//!   GET    /api/v1/harness/jobs           the queue, oldest first
//!   POST   /api/v1/harness/jobs           queue a job  {task, model?}  (model: a Workers AI id; the default otherwise)
//!   GET    /api/v1/harness/jobs/:id       one job whole (its rounds, files, result)
//!   DELETE /api/v1/harness/jobs/:id       cancel or delete one
//!   GET    /api/v1/harness/schedules      the harness's schedules
//!   POST   /api/v1/harness/local          {on}: allow, or stop allowing, the harness's local jobs onto this machine
//!   GET    /api/v1/harness/convs          the chats the harness keeps (the web veil's), newest first
//!   GET    /api/v1/harness/convs/:id      one of them whole
//!   POST   /api/v1/harness/convs          {conv}: copy one of this server's conversations up to the harness
//!   GET    /api/v1/harness/nodes          the mesh: every veil of the account that told the harness it is here
//!   DELETE /api/v1/harness/nodes/:id      have the harness forget one
//!   POST   /api/v1/harness/node           {name}: what the owner calls this machine on the mesh
//!   GET    /api/v1/harness/settings       the account's shared settings {name: {v, at}}
//!   POST   /api/v1/harness/settings       {set?: {name: value}, del?: [name]}
//!   POST   /api/v1/harness/share          bring the Agent Garrett connection level with the harness's, now
//!
//! THE MESH: a machine whose harness has answered gets an id (16 random hex characters, kept in the state file with
//! a name) and tells the harness it is here on every pass of the harness thread: its name, kind, operating system,
//! version, whether it runs work sent to it (the local-jobs switch), whether it has Agent Garrett, and the NAMES of
//! its MCP servers. A job may be addressed to one node; this machine asks for its own and the unaddressed ones,
//! never another's. A chat turn of a non-sandboxed user logged in with Cloudflare gets three verbs (MESH_SCHEMA):
//! mesh_inventory, mesh_run and mesh_result. The work a node does for another is the same unattended turn a local
//! job always was, behind the same owner's switch on the machine that runs it.
//!
//! CHATS: reading is a relay. PUSHING copies a conversation this server holds ({data}/u{uid}/_chat/convs/<id>) to the
//! harness as the web veil's chat shape: its user and assistant messages as text, in order. Engine rows, tool rows
//! and the conversation's work folder are not sent (the harness chat's `files` is left empty). The harness id is
//! derived from the conversation's id (pushId), so pushing again replaces the same chat; the harness keeps its own
//! copy when that one is newer and says so (`stale`). Nothing is pushed unless asked, and nothing comes down into
//! this server's conversations.
//!
//! THE OWNER'S MACHINE: a job queued on the harness with `local: true` is not run in the cloud; it waits for this
//! machine. Nothing listens here for it. Once the owner has allowed it (POST /api/v1/harness/local, recorded in the
//! state file HERE, off until then), bgLoop asks the harness for its local jobs every BRIDGE_EVERY_MS and runs each as
//! an unattended chat turn - the entry points a scheduled task and a tot's job use - in a conversation named for the
//! job ("harness_<job id>"), one at a time, then posts the turn's final answer back. Whoever holds the account's
//! Cloudflare login can queue such a job, and the turn has this machine's tools: that is what the switch grants.
//!
//! Every route is admin-gated, like the tots: a queued job spends the account's Workers AI, and a local one runs
//! full-tool turns here.

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const cf_oauth = @import("cf_oauth.zig");
const cf_tot = @import("cf_tot.zig"); // the account's workers.dev subdomain and the address rule, kept once
const cf_garrett = @import("cf_garrett.zig"); // this server's Agent Garrett connection, shared through the harness
const mcp_discovery = @import("../worker/mcp/discovery.zig"); // the names of this machine's MCP servers
const chat_engine = @import("../worker/chat/engine.zig");
const bu = @import("../worker/browser/util.zig"); // sleepMs: a raw-thread sleep, no Io park
const modelcfg = @import("modelcfg");
const fakehttp = @import("../worker/fakehttp.zig"); // TEST ONLY: the stand-in Cloudflare API and harness
const App = http.App;
const badReq = http.badReq;
const Tok = cf_tot.Tok;
const log = std.log.scoped(.cf_harness);

pub const SCRIPT = "veil-web"; // veil-web.js SELF_SCRIPT, and the name in cloud/veil-web/wrangler.jsonc
const STATE_FILE = "cf_harness.json";
pub const TASK_MAX = 8000; // veil-web.js refuses a longer task; refused here first, without a call
const JOB_ID_MAX = 32;
/// One job whole can be 1.5 MB (veil-web.js JOB_BYTES_MAX); cf_oauth.apiCall stops at 1 MiB.
const REPLY_MAX: usize = 4 << 20;
/// How often the bridge asks an allowed harness for local jobs (the tots' bridge keeps the same pace).
const BRIDGE_EVERY_MS: u64 = 20_000;
/// A harness whose address is not known (never found, or forgotten when it stopped answering) is looked for again
/// only every this many bridge passes: 5 minutes.
const REDISCOVER_EVERY_TICKS: u32 = 15;
const CONV_PREFIX = "harness_";
/// What goes back as a job's result; veil-web.js keeps 10000 characters of it (RESULT_MAX).
const RESULT_BYTES: usize = 10000;

// ---------------------------------------------------------------------------------- per-user state file

/// Where this user's harness answered last, and whether its local jobs may run on this machine. No secret.
const State = struct {
    account: []const u8 = "", // the Cloudflare account the address belongs to
    url: []const u8 = "", // https://veil-web.<subdomain>.workers.dev
    local: bool = false, // the owner allowed the harness's local jobs onto this machine (setLocal)
    node: []const u8 = "", // this machine's id on the mesh: 16 hex characters, made once (ensureNode)
    name: []const u8 = "", // what the owner calls this machine; the computer's own name until they say (setNode)
    garrett_at: i64 = 0, // the harness's Agent Garrett connection this server last took or gave, by its time there
};

fn statePath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ STATE_FILE, .{ app.data, uid }) catch null;
}

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

/// Forget the address; the owner's choice about this machine stays.
fn forgetUrl(app: *App, uid: u64, st: State) void {
    var keep = st;
    keep.account = "";
    keep.url = "";
    writeState(app, uid, keep);
}

// ---------------------------------------------------------------------------------- the address and the call

/// An address the login may be sent to: the harness's own workers.dev name over https, or the loopback stand-in
/// cf_tot.allowedUrl admits while the Cloudflare API is one too.
fn harnessUrlOk(app: *App, url: []const u8) bool {
    if (!cf_tot.allowedUrl(app, url)) return false;
    if (std.mem.startsWith(u8, url, "https://")) return std.mem.startsWith(u8, url, "https://" ++ SCRIPT ++ ".");
    return true;
}

/// A job or schedule id as the harness makes them (base 36 and hex): it becomes a URL segment.
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > JOB_ID_MAX) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
    return true;
}

/// What a call to the harness came to: its JSON as it sent it, or why there is none.
const Out = union(enum) {
    ok: []const u8,
    /// The harness answered and refused, in its own words.
    refused: []const u8,
    /// No harness was reached: no workers.dev subdomain, no answer, or an answer that is not the harness's.
    unreachable_: []const u8,
};

const Reply = struct { ok: bool = false, err: []const u8 = "" };

/// Where this user's harness is: the remembered address while it belongs to this account, else the account's
/// workers.dev subdomain asked of Cloudflare. `cached` says which. Null with the reason in `why`.
fn locate(app: *App, a: std.mem.Allocator, st: State, tok: Tok, cached: *bool, why: *[]const u8) ?[]const u8 {
    cached.* = false;
    if (tok.account_id.len == 0) {
        why.* = "your Cloudflare login names no account - Disconnect and log in with Cloudflare again";
        return null;
    }
    if (st.url.len > 0 and std.mem.eql(u8, st.account, tok.account_id) and harnessUrlOk(app, st.url)) {
        cached.* = true;
        return st.url;
    }
    const sub = cf_tot.workersSubdomain(app, a, tok, why) orelse return null;
    const url = cf_tot.workerUrl(app, a, SCRIPT, sub) orelse {
        why.* = "out of memory";
        return null;
    };
    if (!harnessUrlOk(app, url)) {
        why.* = "the harness's address is not one this server sends a login to";
        return null;
    }
    return url;
}

/// One call to the user's harness with their Cloudflare login. Everything lives in `a`. An address is remembered
/// only once the harness has answered there, and forgotten when a remembered one stops answering as a harness.
fn harnessCall(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, method: []const u8, path: []const u8, body: []const u8, url_out: ?*[]const u8) Out {
    var cached = false;
    var why: []const u8 = "";
    const st = readState(app, uid, a);
    const base = locate(app, a, st, tok, &cached, &why) orelse return .{ .unreachable_ = why };
    if (url_out) |u| u.* = base;
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ base, path }) catch return .{ .unreachable_ = "out of memory" };
    const opts: cf_oauth.CurlOpts = .{ .gpa = app.gpa, .io = app.io, .scratch = app.data, .body_prefix = ".cfharness-body-", .max_time_s = 30, .stdout_limit = REPLY_MAX };
    const raw_gpa = cf_oauth.curl(opts, method, url, body, tok.key, if (body.len > 0) "application/json" else "");
    const raw: []const u8 = if (raw_gpa) |r| blk: {
        defer app.gpa.free(r);
        break :blk a.dupe(u8, r) catch return .{ .unreachable_ = "out of memory" };
    } else "";
    const parsed: ?Reply = if (raw.len == 0) null else std.json.parseFromSliceLeaky(Reply, a, raw, .{ .ignore_unknown_fields = true }) catch null;
    const rep = parsed orelse {
        if (cached) forgetUrl(app, uid, st);
        return .{ .unreachable_ = std.fmt.allocPrint(a, "no veil-web harness answered at {s}", .{base}) catch "no veil-web harness answered" };
    };
    if (!cached) {
        var keep = readState(app, uid, a); // read again: a slow call may have outlived a change to the switch
        keep.account = tok.account_id;
        keep.url = base;
        writeState(app, uid, keep);
    }
    if (rep.ok) return .{ .ok = raw };
    return .{ .refused = if (rep.err.len > 0) rep.err else "the harness refused the request" };
}

/// The body of POST /v1/jobs, or the reason there is none: checked here so a bad request costs no call.
fn queueBody(a: std.mem.Allocator, task_in: []const u8, model_in: []const u8, why: *[]const u8) ?[]const u8 {
    return queueBodyFor(a, task_in, model_in, "", "", why);
}

/// The same, for a job addressed to one node of the mesh (`node`, "" = the cloud runs it) and saying which node
/// asked (`from`, "" = not said).
fn queueBodyFor(a: std.mem.Allocator, task_in: []const u8, model_in: []const u8, node: []const u8, from: []const u8, why: *[]const u8) ?[]const u8 {
    const task = std.mem.trim(u8, task_in, " \t\r\n");
    if (task.len == 0 or task.len > TASK_MAX) {
        why.* = "task must be 1 to 8000 characters";
        return null;
    }
    const model = if (model_in.len > 0) model_in else modelcfg.defaults.cf_model;
    if (model[0] != '@') {
        why.* = "model must be a Workers AI model id";
        return null;
    }
    if (node.len > 0 and !validNode(node)) {
        why.* = "that is not a node id: ask for the nodes first";
        return null;
    }
    const made = if (node.len == 0)
        std.json.Stringify.valueAlloc(a, .{ .task = task, .model = model }, .{})
    else if (validNode(from))
        std.json.Stringify.valueAlloc(a, .{ .task = task, .model = model, .node = node, .from = from }, .{})
    else
        std.json.Stringify.valueAlloc(a, .{ .task = task, .model = model, .node = node }, .{});
    return made catch {
        why.* = "out of memory";
        return null;
    };
}

// ---------------------------------------------------------------------------------- HTTP handlers

fn gate(app: *App, req: *httpz.Request, res: *httpz.Response) ?http.User {
    const u = http.requireUser(app, req, res) orelse return null;
    if (!app.auth.isAdmin(u)) {
        res.status = 403;
        res.json(.{ .ok = false, .err = "the harness is admin-only for now" }, .{}) catch {};
        return null;
    }
    return u;
}

fn tokOf(app: *App, uid: u64, a: std.mem.Allocator) ?Tok {
    const t = cf_oauth.resolveToken(app, uid, a) orelse return null;
    return .{ .key = t.key, .account_id = t.account_id };
}

/// The harness's answer to the client: its JSON as it is, its own refusal as a 400, no harness as a 502.
fn relay(res: *httpz.Response, out: Out) !void {
    switch (out) {
        .ok => |raw| {
            res.content_type = .JSON;
            res.body = try res.arena.dupe(u8, raw);
        },
        .refused => |msg| try badReq(res, msg),
        .unreachable_ => |msg| {
            res.status = 502;
            try res.json(.{ .ok = false, .err = msg }, .{});
        },
    }
}

/// The JSON of GET /api/v1/harness for one login. `tok` null: not logged in with Cloudflare.
fn statusJson(app: *App, a: std.mem.Allocator, uid: u64, tok: ?Tok) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var url: []const u8 = "";
    var err: []const u8 = "";
    var harness: []const u8 = "null";
    if (tok) |t| switch (harnessCall(app, a, uid, t, "GET", "/v1/status", "", &url)) {
        .ok => |raw| harness = raw,
        .refused => |m| err = m,
        .unreachable_ => |m| err = m,
    };
    var st = readState(app, uid, a);
    // a machine whose harness answered is on the mesh from here on: it gets its id now, and the harness thread
    // says it is here on its next pass
    if (!std.mem.eql(u8, harness, "null")) ensureNode(app, uid, a, &st);
    try out.print(a, "{{\"ok\":true,\"connected\":{},\"reachable\":{},\"local\":{},\"node\":", .{ tok != null, !std.mem.eql(u8, harness, "null"), st.local });
    try http.jstr(a, &out, st.node);
    try out.appendSlice(a, ",\"name\":");
    try http.jstr(a, &out, st.name);
    try out.appendSlice(a, ",\"url\":");
    try http.jstr(a, &out, url);
    try out.appendSlice(a, ",\"err\":");
    try http.jstr(a, &out, err);
    try out.appendSlice(a, ",\"default_model\":");
    try http.jstr(a, &out, modelcfg.defaults.cf_model);
    try out.appendSlice(a, ",\"harness\":");
    try out.appendSlice(a, harness);
    try out.append(a, '}');
    return out.items;
}

/// GET /api/v1/harness — whether this login reaches a harness, where, and the harness's own status (its version,
/// usage, limits, queue and schedule counts) as it reports it.
pub fn status(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try statusJson(app, a, u.id, tokOf(app, u.id, a));
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, body);
}

const NOT_CONNECTED = "not connected to Cloudflare - log in with Cloudflare first";

/// GET /api/v1/harness/jobs — the queue as the harness keeps it, oldest first.
pub fn listJobs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    try relay(res, harnessCall(app, a, u.id, tok, "GET", "/v1/jobs", "", null));
}

const QueueReq = struct { task: []const u8 = "", model: []const u8 = "", node: []const u8 = "" };

/// POST /api/v1/harness/jobs — queue a job on the harness.
pub fn queueJob(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(QueueReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const sent = queueBodyFor(a, body.task, body.model, body.node, readState(app, u.id, a).node, &why) orelse return badReq(res, why);
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    try relay(res, harnessCall(app, a, u.id, tok, "POST", "/v1/jobs", sent, null));
}

fn oneJob(app: *App, u: http.User, req: *httpz.Request, res: *httpz.Response, method: []const u8) !void {
    const id = req.param("id") orelse return badReq(res, "missing job id");
    if (!validId(id)) return badReq(res, "bad job id");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    const path = try std.fmt.allocPrint(a, "/v1/jobs/{s}", .{id});
    try relay(res, harnessCall(app, a, u.id, tok, method, path, "", null));
}

/// GET /api/v1/harness/jobs/:id — one job whole.
pub fn getJob(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return; // here, not in oneJob: the router audit reads one hop
    return oneJob(app, u, req, res, "GET");
}

/// DELETE /api/v1/harness/jobs/:id — cancel a waiting or running job, or delete a finished one.
pub fn cancelJob(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    return oneJob(app, u, req, res, "DELETE");
}

/// GET /api/v1/harness/schedules — the harness's schedules.
pub fn listSchedules(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    try relay(res, harnessCall(app, a, u.id, tok, "GET", "/v1/schedules", "", null));
}

const LocalReq = struct { on: bool = false };

/// POST /api/v1/harness/local {on} — allow the harness's local jobs onto this machine, or stop allowing them. The
/// choice is kept in this server's state file; the harness is not told and cannot set it.
pub fn setLocal(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(LocalReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    var st = readState(app, u.id, arena.allocator());
    st.local = body.on;
    writeState(app, u.id, st);
    try res.json(.{ .ok = true, .local = st.local }, .{});
}

// ---------------------------------------------------------------------------------- chats

const CONV_BYTES_MAX: usize = 1_500_000; // veil-web.js CONV_BYTES_MAX: one conversation the harness keeps
const TITLE_MAX: usize = 80; // what this server's own conversation list shows of a first message

/// A chat id as the harness accepts one: 6 to 24 lower-case letters and digits.
fn validConvId(id: []const u8) bool {
    if (id.len < 6 or id.len > 24) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
    return true;
}

/// One of this server's conversation ids: a safe path segment (chat/service.zig safeSeg's rule).
fn validLocalConv(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

/// The harness id a pushed conversation gets: "d" and 20 hex characters of a hash of its id here. The same
/// conversation always lands on the same harness chat, so pushing again replaces it.
fn pushId(out: *[21]u8, conv: []const u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("veil-desk-conv\x00");
    h.update(conv);
    var dig: [32]u8 = undefined;
    h.final(&dig);
    out[0] = 'd';
    out[1..21].* = std.fmt.bytesToHex(dig[0..10].*, .lower);
    return out;
}

const Pushed = struct { body: []const u8, msgs: usize };

/// The harness chat for one of this server's conversations: {title, at, msgs, files} as JSON. Null with the reason.
fn pushBody(app: *App, a: std.mem.Allocator, uid: u64, conv: []const u8, why: *[]const u8) ?Pushed {
    const path = std.fmt.allocPrint(a, "{s}/u{d}/_chat/convs/{s}/messages.jsonl", .{ app.data, uid, conv }) catch return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(8 << 20)) catch {
        why.* = "this server holds no such conversation";
        return null;
    };
    const Msg = struct { role: []const u8, content: []const u8 };
    var msgs: std.ArrayListUnmanaged(Msg) = .empty;
    var last_ts: i64 = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (t.len == 0 or t[0] != '{') continue;
        const P = struct { role: []const u8 = "", content: []const u8 = "", kind: []const u8 = "", ts: i64 = 0 };
        const p = std.json.parseFromSliceLeaky(P, a, t, .{ .ignore_unknown_fields = true }) catch continue;
        const spoken = std.mem.eql(u8, p.role, "user") or std.mem.eql(u8, p.role, "assistant");
        if (!spoken or p.content.len == 0 or std.mem.eql(u8, p.kind, "engine")) continue; // the engine's own rows are not the chat
        msgs.append(a, .{ .role = p.role, .content = p.content }) catch return null;
        if (p.ts > last_ts) last_ts = p.ts;
    }
    if (msgs.items.len == 0) {
        why.* = "that conversation has no messages to push";
        return null;
    }
    // the title this server's own list shows: the first message, one line, cut
    const title = a.dupe(u8, clipUtf8(msgs.items[0].content, TITLE_MAX)) catch return null;
    for (title) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    const at_ms: i64 = if (last_ts > 0) last_ts * 1000 else std.Io.Timestamp.now(app.io, .real).toSeconds() * 1000;
    const body = std.json.Stringify.valueAlloc(a, .{ .title = title, .at = at_ms, .msgs = msgs.items, .files = struct {}{} }, .{}) catch return null;
    if (body.len > CONV_BYTES_MAX) {
        why.* = "this conversation is larger than one the harness keeps (1.5 MB)";
        return null;
    }
    return .{ .body = body, .msgs = msgs.items.len };
}

/// What a push came to, as the route's JSON; or the harness's refusal.
fn pushAs(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, conv: []const u8) union(enum) { ok: []const u8, out: Out } {
    var why: []const u8 = "";
    const p = pushBody(app, a, uid, conv, &why) orelse return .{ .out = .{ .refused = why } };
    var ib: [21]u8 = undefined;
    const id = pushId(&ib, conv);
    const path = std.fmt.allocPrint(a, "/v1/convs/{s}", .{id}) catch return .{ .out = .{ .unreachable_ = "out of memory" } };
    const raw = switch (harnessCall(app, a, uid, tok, "POST", path, p.body, null)) {
        .ok => |r| r,
        else => |o| return .{ .out = o },
    };
    const R = struct { stale: bool = false };
    const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch R{};
    const json = std.fmt.allocPrint(a, "{{\"ok\":true,\"id\":\"{s}\",\"msgs\":{d},\"stale\":{}}}", .{ id, p.msgs, r.stale }) catch return .{ .out = .{ .unreachable_ = "out of memory" } };
    return .{ .ok = json };
}

/// GET /api/v1/harness/convs — the chats the harness keeps, newest first.
pub fn listConvs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    try relay(res, harnessCall(app, a, u.id, tok, "GET", "/v1/convs", "", null));
}

/// GET /api/v1/harness/convs/:id — one harness chat whole.
pub fn getConv(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "missing chat id");
    if (!validConvId(id)) return badReq(res, "bad chat id");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    const path = try std.fmt.allocPrint(a, "/v1/convs/{s}", .{id});
    try relay(res, harnessCall(app, a, u.id, tok, "GET", path, "", null));
}

const PushReq = struct { conv: []const u8 = "" };

/// POST /api/v1/harness/convs {conv} — copy one of this server's conversations up to the harness. Answers
/// {ok, id, msgs, stale}: the harness chat's id, how many messages went, and whether the harness kept a newer copy.
pub fn pushConv(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(PushReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (!validLocalConv(body.conv)) return badReq(res, "bad conversation id");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    switch (pushAs(app, a, u.id, tok, body.conv)) {
        .ok => |json| {
            res.content_type = .JSON;
            res.body = try res.arena.dupe(u8, json);
        },
        .out => |o| try relay(res, o),
    }
}

// ---------------------------------------------------------------------------------- the mesh

/// What this process is, as it tells the harness: main.zig sets both before the harness thread starts.
pub var node_kind: []const u8 = "server"; // "desk" when this process has the desk window
pub var node_version: []const u8 = "";

const NODE_NAME_MAX: usize = 48; // veil-web.js keeps this much of a node's name

/// A node id as the harness accepts one: 8 to 32 lower-case letters and digits.
fn validNode(id: []const u8) bool {
    if (id.len < 8 or id.len > 32) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
    return true;
}

/// The computer's own name, as its environment gives it; "veil" when it gives none.
fn machineName(app: *App) []const u8 {
    if (app.sup.parent_env) |env| {
        for ([_][]const u8{ "COMPUTERNAME", "HOSTNAME", "HOST" }) |k| if (env.get(k)) |v| {
            const t = std.mem.trim(u8, v, " \r\n\t");
            if (t.len > 0) return clipUtf8(t, NODE_NAME_MAX);
        };
    }
    return "veil";
}

/// Give this machine its id on the mesh, once: 16 random hex characters kept in the state file, with the
/// computer's own name beside it until the owner names it. The id says nothing about the machine.
fn ensureNode(app: *App, uid: u64, a: std.mem.Allocator, st: *State) void {
    if (validNode(st.node)) return;
    var r: [8]u8 = undefined;
    app.io.random(&r);
    st.node = a.dupe(u8, &std.fmt.bytesToHex(r, .lower)) catch return;
    if (st.name.len == 0) st.name = a.dupe(u8, machineName(app)) catch "veil";
    writeState(app, uid, st.*);
}

/// The names of this machine's MCP servers (the config files mcp_discover reads), space separated, read again
/// every 5 minutes by the harness thread. Names only: the inventory says which machine has which server.
var mcp_names_buf: [600]u8 = undefined;
var mcp_names_len: std.atomic.Value(usize) = .init(0);

fn refreshMcpNames(app: *App) void {
    const env = app.sup.parent_env orelse return;
    const raw = mcp_discovery.discoverAll(app.gpa, app.io, env);
    defer app.gpa.free(raw);
    const Found = struct { mcp_servers: []const struct { name: []const u8 = "" } = &.{} };
    const p = std.json.parseFromSlice(Found, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return;
    defer p.deinit();
    var n: usize = 0;
    var kept: usize = 0;
    for (p.value.mcp_servers) |sv| {
        if (sv.name.len == 0 or sv.name.len > 32 or kept >= 16) continue;
        if (n + sv.name.len + 1 > mcp_names_buf.len) break;
        if (n > 0) {
            mcp_names_buf[n] = ' ';
            n += 1;
        }
        @memcpy(mcp_names_buf[n..][0..sv.name.len], sv.name);
        n += sv.name.len;
        kept += 1;
    }
    mcp_names_len.store(n, .release);
}

/// What this machine tells the harness about itself: POST /v1/nodes/<id>.
fn nodeBody(app: *App, a: std.mem.Allocator, uid: u64, st: State) ?[]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, mcp_names_buf[0..mcp_names_len.load(.acquire)], ' ');
    while (it.next()) |nm| names.append(a, a.dupe(u8, nm) catch continue) catch {};
    return std.json.Stringify.valueAlloc(a, .{
        .name = if (st.name.len > 0) clipUtf8(st.name, NODE_NAME_MAX) else "veil",
        .kind = node_kind,
        .os = @tagName(builtin.os.tag),
        .version = node_version,
        .runs = st.local,
        .garrett = cf_garrett.connected(app, uid, a),
        .mcp = names.items,
    }, .{}) catch null;
}

/// Say this machine is here. An older harness has no such route and answers a refusal, which is dropped.
fn announce(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: State) void {
    if (!validNode(st.node)) return;
    const body = nodeBody(app, a, uid, st) orelse return;
    const path = std.fmt.allocPrint(a, "/v1/nodes/{s}", .{st.node}) catch return;
    _ = harnessCall(app, a, uid, tok, "POST", path, body, null);
}

/// GET /api/v1/harness/nodes — every node of the mesh as the harness lists them. `status` says which is this one.
pub fn listNodes(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    // say it first, so the list this machine asks for has this machine in it, as it is now
    var st = readState(app, u.id, a);
    ensureNode(app, u.id, a, &st);
    announce(app, a, u.id, tok, st);
    try relay(res, harnessCall(app, a, u.id, tok, "GET", "/v1/nodes", "", null));
}

/// DELETE /api/v1/harness/nodes/:id — have the harness forget a node (one that is still running says it is here
/// again on its next pass).
pub fn forgetNode(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "missing node id");
    if (!validNode(id)) return badReq(res, "bad node id");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    const path = try std.fmt.allocPrint(a, "/v1/nodes/{s}", .{id});
    try relay(res, harnessCall(app, a, u.id, tok, "DELETE", path, "", null));
}

const NodeReq = struct { name: []const u8 = "" };

/// POST /api/v1/harness/node {name} — what the owner calls this machine on the mesh.
pub fn setNode(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(NodeReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    const name = std.mem.trim(u8, body.name, " \t\r\n");
    if (name.len == 0 or name.len > NODE_NAME_MAX) return badReq(res, "a machine's name is 1 to 48 characters");
    for (name) |c| if (c < 0x20) return badReq(res, "a machine's name is one line");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = readState(app, u.id, a);
    ensureNode(app, u.id, a, &st);
    st.name = name;
    writeState(app, u.id, st);
    if (tokOf(app, u.id, a)) |tok| announce(app, a, u.id, tok, st);
    try res.json(.{ .ok = true, .node = st.node, .name = st.name }, .{});
}

// ---------------------------------------------------------------------------------- shared settings

const SETTINGS_BODY_MAX: usize = 64 << 10;

/// GET /api/v1/harness/settings — the account's shared settings as the harness keeps them: {name: {v, at}}.
pub fn getSettings(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    try relay(res, harnessCall(app, a, u.id, tok, "GET", "/v1/settings", "", null));
}

/// POST /api/v1/harness/settings {set?: {name: value}, del?: [name]} — write shared settings. The body must be a
/// JSON object of at most 64 KB; the harness checks the names and the values and answers every setting it keeps.
pub fn putSettings(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = req.body() orelse return badReq(res, "bad body");
    if (body.len > SETTINGS_BODY_MAX) return badReq(res, "settings body too large");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return badReq(res, "malformed JSON body");
    if (parsed != .object) return badReq(res, "malformed JSON body");
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    try relay(res, harnessCall(app, a, u.id, tok, "POST", "/v1/settings", body, null));
}

// ---------------------------------------------------------------------------------- shared connections

const Shared = struct {
    ok: bool = false,
    garrett: ?struct { url: []const u8 = "", token: []const u8 = "", tools: usize = 0, at: i64 = 0 } = null,
};

/// What bringing the Agent Garrett connection level came to.
const GarrettSync = enum { none, same, pushed, pulled, differs, unreachable_ };

/// Bring this server's Agent Garrett connection and the harness's level, so every veil of the account uses the
/// same one. Only the hosted agent's key travels (cf_garrett.validKey at cf_garrett.MCP_URL); an agent of the
/// owner's own stays where it was set up.
///   - connected here, nothing on the harness: the key is given to the harness, which checks it with the agent.
///   - nothing here, a key on the harness: it is taken, once per connection the harness holds (its `at`). A
///     disconnect made here afterwards is therefore not undone by the next pass; a NEW key on the harness is taken.
///   - both hold a key and they differ: nothing is changed.
fn syncGarrett(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok) GarrettSync {
    const raw = switch (harnessCall(app, a, uid, tok, "GET", "/v1/share", "", null)) {
        .ok => |r| r,
        else => return .unreachable_, // an older harness (no such route), or none answering
    };
    const shared = std.json.parseFromSliceLeaky(Shared, a, raw, .{ .ignore_unknown_fields = true }) catch return .unreachable_;
    const here = cf_garrett.managedFor(app, uid, a);
    const mine: []const u8 = if (here.creds) |c| c.token else "";
    const theirs: []const u8 = if (shared.garrett) |g| (if (cf_garrett.validKey(g.token) and std.mem.eql(u8, g.url, cf_garrett.MCP_URL)) g.token else "") else "";
    const their_at: i64 = if (shared.garrett) |g| g.at else 0;
    var st = readState(app, uid, a);
    if (mine.len > 0 and theirs.len > 0) {
        if (!std.mem.eql(u8, mine, theirs)) return .differs;
        if (st.garrett_at != their_at) {
            st.garrett_at = their_at;
            writeState(app, uid, st);
        }
        return .same;
    }
    if (mine.len > 0) {
        if (shared.garrett != null) return .differs; // the harness holds an agent of the owner's own: left alone
        const body = std.json.Stringify.valueAlloc(a, .{ .key = mine }, .{}) catch return .none;
        switch (harnessCall(app, a, uid, tok, "POST", "/v1/garrett", body, null)) {
            .ok => {},
            else => return .none, // the harness could not verify it with the agent: nothing kept there
        }
        // remember which connection this is, so a later disconnect here is not undone by it
        const again = harnessCall(app, a, uid, tok, "GET", "/v1/share", "", null);
        if (again == .ok) {
            const sh: ?Shared = std.json.parseFromSliceLeaky(Shared, a, again.ok, .{ .ignore_unknown_fields = true }) catch null;
            if (sh) |v| if (v.garrett) |g| {
                st.garrett_at = g.at;
                writeState(app, uid, st);
            };
        }
        return .pushed;
    }
    if (theirs.len == 0 or their_at == st.garrett_at) return .none;
    cf_garrett.saveManaged(app, uid, theirs, if (shared.garrett) |g| g.tools else 0) catch return .none;
    st.garrett_at = their_at;
    writeState(app, uid, st);
    log.info("harness: took the account's Agent Garrett connection from the harness", .{});
    return .pulled;
}

/// POST /api/v1/harness/share — bring the Agent Garrett connection level with the harness's now (the harness
/// thread does the same every 5 minutes). Answers what happened; never the key.
pub fn share(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, NOT_CONNECTED);
    const what = syncGarrett(app, a, u.id, tok);
    if (what == .unreachable_) {
        res.status = 502;
        return res.json(.{ .ok = false, .err = "no harness that shares connections answered (it needs version 10 or newer)" }, .{});
    }
    try res.json(.{ .ok = true, .garrett = @tagName(what) }, .{});
}

// ---------------------------------------------------------------------------------- the chat's mesh tools

/// The three verbs a chat turn gets while its user is logged in with Cloudflare and is not sandboxed
/// (engine.zig buildTurnTools / orchTool).
pub const MESH_SCHEMA =
    \\{"type":"function","function":{"name":"mesh_inventory","description":"List every veil logged in to the user's Cloudflare account (their mesh): this machine, their other computers and their open web veil tabs. For each: id, name, kind (desk, server or web), operating system, version, whether it is online now, whether it runs work sent to it, whether it has a controllable browser, whether it has Agent Garrett, the MCP servers it has, and how many jobs wait for it. Call this before mesh_run, and whenever the user asks what is connected or which machine is which.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"mesh_run","description":"Send a task to ONE other veil of the user's mesh, to be done there with that veil's own tools and files (a desktop veil runs it as a full unattended chat turn on that computer; a web veil runs it in its tab, with its browser tools when it has them). The task must stand on its own: the other veil sees only this text. Returns a job id at once; the work takes a while, so ask mesh_result for the outcome. Only a node whose inventory line says it runs work will take it.","parameters":{"type":"object","properties":{"node":{"type":"string","description":"The node's id or its exact name, from mesh_inventory."},"task":{"type":"string","description":"What to do there, complete and self-contained, and what to report back."},"model":{"type":"string","description":"Optional Workers AI model id (starts with @) for the other veil to use; the default model when left out."}},"required":["node","task"]}}},
    \\{"type":"function","function":{"name":"mesh_result","description":"The state of a job sent with mesh_run and, once it has ended, what the other veil reported. States: queued (not taken yet), running, done, failed, cancelled.","parameters":{"type":"object","properties":{"job":{"type":"string","description":"The job id mesh_run returned."}},"required":["job"]}}}
;

pub fn isMeshTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "mesh_inventory") or std.mem.eql(u8, name, "mesh_run") or std.mem.eql(u8, name, "mesh_result");
}

const MeshNode = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    kind: []const u8 = "",
    os: []const u8 = "",
    version: []const u8 = "",
    runs: bool = false,
    browser: bool = false,
    garrett: bool = false,
    mcp: []const []const u8 = &.{},
    seen: i64 = 0,
    online: bool = false,
    waiting: i64 = 0,
};
const MeshNodes = struct { ok: bool = false, now: i64 = 0, nodes: []const MeshNode = &.{} };

/// The inventory as the model reads it: one line a node, this machine marked.
fn inventoryText(a: std.mem.Allocator, self: []const u8, m: MeshNodes) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (m.nodes.len == 0) return "the mesh is empty: no veil of this account has told the harness it is here yet";
    out.print(a, "{d} node(s) on this account's mesh. Each line: id | name | kind | os | version | online | runs work | browser | Agent Garrett | MCP servers | jobs waiting\n", .{m.nodes.len}) catch return "out of memory";
    for (m.nodes) |n| {
        const me = self.len > 0 and std.mem.eql(u8, n.id, self);
        out.print(a, "{s} | {s}{s} | {s} | {s} | {s} | ", .{ n.id, n.name, if (me) " (THIS machine)" else "", n.kind, if (n.os.len > 0) n.os else "-", if (n.version.len > 0) n.version else "-" }) catch break;
        if (n.online) out.appendSlice(a, "online") catch break else out.print(a, "offline, last seen {d} s ago", .{@divTrunc(@max(m.now - n.seen, 0), 1000)}) catch break;
        out.print(a, " | {s} | {s} | {s} | ", .{ if (n.runs) "runs work" else "does not run work (its owner switch is off)", if (n.browser) "browser" else "no browser", if (n.garrett) "Garrett" else "no Garrett" }) catch break;
        if (n.mcp.len == 0) out.appendSlice(a, "-") catch break;
        for (n.mcp, 0..) |nm, i| out.print(a, "{s}{s}", .{ if (i > 0) " " else "", nm }) catch break;
        out.print(a, " | {d}\n", .{n.waiting}) catch break;
    }
    return out.items;
}

/// The node `want` names: its id, or its name when exactly one node has it (letter case ignored).
fn findNode(m: MeshNodes, want: []const u8) ?MeshNode {
    for (m.nodes) |n| if (std.mem.eql(u8, n.id, want)) return n;
    var hit: ?MeshNode = null;
    for (m.nodes) |n| if (std.ascii.eqlIgnoreCase(n.name, want)) {
        if (hit != null) return null; // two machines share the name: the id must be given
        hit = n;
    };
    return hit;
}

const MeshArgs = struct { node: []const u8 = "", task: []const u8 = "", model: []const u8 = "", job: []const u8 = "" };
const MeshJob = struct { ok: bool = false, id: []const u8 = "", job: ?struct { state: []const u8 = "", result: []const u8 = "", @"error": []const u8 = "", note: []const u8 = "", node: []const u8 = "" } = null };

fn outText(a: std.mem.Allocator, what: []const u8, out: Out) []const u8 {
    return switch (out) {
        .ok => |r| r,
        .refused => |m| std.fmt.allocPrint(a, "{s}: the harness refused ({s})", .{ what, m }) catch "the harness refused",
        .unreachable_ => |m| std.fmt.allocPrint(a, "{s}: no harness was reached ({s})", .{ what, m }) catch "no harness was reached",
    };
}

/// One mesh verb for a chat turn, with `tok` the turn's user's Cloudflare login. The text is in `a`.
fn meshRun(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, name: []const u8, args_json: []const u8) []const u8 {
    const args = std.json.parseFromSliceLeaky(MeshArgs, a, if (args_json.len > 0) args_json else "{}", .{ .ignore_unknown_fields = true }) catch return "bad arguments: send a JSON object";
    var st = readState(app, uid, a);
    if (std.mem.eql(u8, name, "mesh_result")) {
        if (!validId(args.job)) return "give the job id mesh_run returned";
        const path = std.fmt.allocPrint(a, "/v1/jobs/{s}", .{args.job}) catch return "out of memory";
        const got = harnessCall(app, a, uid, tok, "GET", path, "", null);
        if (got != .ok) return outText(a, "mesh_result", got);
        const j = std.json.parseFromSliceLeaky(MeshJob, a, got.ok, .{ .ignore_unknown_fields = true }) catch return "the harness's answer could not be read";
        const job = j.job orelse return "no such job";
        if (std.mem.eql(u8, job.state, "done")) return std.fmt.allocPrint(a, "job {s}: done. The other veil reported:\n{s}", .{ args.job, job.result }) catch "out of memory";
        if (std.mem.eql(u8, job.state, "failed")) return std.fmt.allocPrint(a, "job {s}: failed. {s}", .{ args.job, job.@"error" }) catch "out of memory";
        return std.fmt.allocPrint(a, "job {s}: {s}{s}{s}. Not ended yet: ask again later.", .{ args.job, job.state, if (job.note.len > 0) " - " else "", job.note }) catch "out of memory";
    }
    // the other two start from the list, with this machine in it as it is now
    ensureNode(app, uid, a, &st);
    announce(app, a, uid, tok, st);
    const got = harnessCall(app, a, uid, tok, "GET", "/v1/nodes", "", null);
    if (got != .ok) return outText(a, name, got);
    const m = std.json.parseFromSliceLeaky(MeshNodes, a, got.ok, .{ .ignore_unknown_fields = true }) catch return "the harness's answer could not be read";
    if (std.mem.eql(u8, name, "mesh_inventory")) return inventoryText(a, st.node, m);

    const node = findNode(m, std.mem.trim(u8, args.node, " \t\r\n")) orelse return "no node has that id, or more than one has that name: call mesh_inventory and give the id";
    if (std.mem.eql(u8, node.id, st.node)) return "that is THIS machine: do the work here with your own tools instead of sending it to yourself";
    if (!node.runs) return std.fmt.allocPrint(a, "{s} does not run work sent to it: its owner has not switched that on there (on a desktop veil: Tasks > Web harness > run the harness's local jobs on this machine)", .{node.name}) catch "that node does not run work";
    var why: []const u8 = "";
    const body = queueBodyFor(a, args.task, args.model, node.id, st.node, &why) orelse return why;
    const sent = harnessCall(app, a, uid, tok, "POST", "/v1/jobs", body, null);
    if (sent != .ok) return outText(a, "mesh_run", sent);
    const q = std.json.parseFromSliceLeaky(MeshJob, a, sent.ok, .{ .ignore_unknown_fields = true }) catch return "the harness's answer could not be read";
    return std.fmt.allocPrint(a, "queued as job {s} for {s} ({s}){s}. It runs there unattended; call mesh_result with the job id for the outcome.", .{ q.id, node.name, node.id, if (node.online) "" else ". That node is OFFLINE now: the job waits until it is back" }) catch "queued";
}

/// The chat engine's entry (engine.zig orchTool): one mesh verb for `uid`, answered as text the model reads, owned
/// by app.gpa. Admin only, as the routes are: a job sent to another machine runs a full-tool turn there.
pub fn meshTool(app: *App, uid: u64, name: []const u8, args_json: []const u8) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = app.auth.userById(uid) orelse return app.gpa.dupe(u8, "the mesh is for the server's admin") catch null;
    if (!app.auth.isAdmin(owner)) return app.gpa.dupe(u8, "the mesh is for the server's admin") catch null;
    const tok = tokOf(app, uid, a) orelse return app.gpa.dupe(u8, NOT_CONNECTED) catch null;
    return app.gpa.dupe(u8, meshRun(app, a, uid, tok, name, args_json)) catch null;
}

// ---------------------------------------------------------------------------------- the owner's machine

const LocalJob = struct { id: []const u8 = "", t: i64 = 0, task: []const u8 = "", model: []const u8 = "" };
const LocalJobs = struct { ok: bool = false, jobs: []const LocalJob = &.{} };

/// The conversation one local job runs in: "harness_<job id>". The harness's ids are unique for its life.
fn jobConv(buf: *[64]u8, id: []const u8) ?[]const u8 {
    if (!validId(id)) return null;
    return std.fmt.bufPrint(buf, CONV_PREFIX ++ "{s}", .{id}) catch null;
}

/// What the unattended turn is told: the job's task, then where it came from and how the turn must end.
fn jobText(a: std.mem.Allocator, task: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(a,
        \\{s}
        \\
        \\--- HARNESS JOB CONTEXT (engine-authored) ---
        \\This job was queued on the owner's veil-web harness (a Worker in their own Cloudflare account) as a job for this machine, and the owner allowed such jobs to run here. Nobody is watching this turn: do the work with your tools, never ask a question and wait, and end with a plain report of what was done and what the tool results showed. Your final message is sent back to the harness as the job's result.
    , .{task}) catch null;
}

/// `s` cut to at most `max` bytes on a UTF-8 boundary.
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

fn postLocal(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, id: []const u8, json: []const u8) void {
    const path = std.fmt.allocPrint(a, "/v1/local/{s}", .{id}) catch return;
    _ = harnessCall(app, a, uid, tok, "POST", path, json, null);
}

fn postResult(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, id: []const u8, ok: bool, result: []const u8) void {
    const json = std.json.Stringify.valueAlloc(a, .{ .ok = ok, .result = clipUtf8(result, RESULT_BYTES) }, .{}) catch return;
    postLocal(app, a, uid, tok, id, json);
}

/// One allowed user, one pass: answer the local jobs whose turn has ended, and start the next one. One job runs at
/// a time. `base_url` is the login's Workers AI base ("" in a test that starts nothing). Returns how many turns it
/// started.
fn bridgeUser(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, base_url: []const u8, node: []const u8) usize {
    // with its id, this machine is handed the jobs addressed to it and the ones addressed to nobody; never another's
    const path = if (validNode(node)) (std.fmt.allocPrint(a, "/v1/local?node={s}", .{node}) catch return 0) else "/v1/local";
    const raw = switch (harnessCall(app, a, uid, tok, "GET", path, "", null)) {
        .ok => |r| r,
        else => return 0, // an older harness (no such route), or none answering
    };
    const jobs = std.json.parseFromSliceLeaky(LocalJobs, a, raw, .{ .ignore_unknown_fields = true }) catch return 0;
    if (!jobs.ok) return 0;
    var started: usize = 0;
    for (jobs.jobs) |job| {
        var cb: [64]u8 = undefined;
        const conv = jobConv(&cb, job.id) orelse continue; // an id that cannot be a path segment cannot be answered either
        if (chat_engine.isTurnLive(app.io, conv)) continue; // still working
        var began = false;
        if (cf_tot.lastAssistant(app, a, uid, conv, &began)) |answer| {
            postResult(app, a, uid, tok, job.id, true, answer);
            continue;
        }
        if (began) {
            postResult(app, a, uid, tok, job.id, false, "the run on the owner's machine ended without an answer");
            continue;
        }
        var live: [64]u8 = undefined;
        if (started > 0 or chat_engine.liveTurnWithPrefix(app.io, CONV_PREFIX, &live) != null) continue; // one at a time
        if (launchJob(app, a, uid, tok, base_url, conv, job)) started += 1;
    }
    return started;
}

/// Start the unattended chat turn for one local job, on the owner's Cloudflare login and the job's own model, and
/// tell the harness this machine has taken it.
fn launchJob(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, base_url: []const u8, conv: []const u8, job: LocalJob) bool {
    if (base_url.len == 0) return false;
    const text = jobText(a, job.task) orelse return false;
    const trio: chat_engine.ModelTrio = .{ .coding = .{ .base_url = base_url, .key = tok.key, .model = if (job.model.len > 0 and job.model[0] == '@') job.model else modelcfg.defaults.cf_model } };
    if (!chat_engine.tryBeginTurn(app.io, conv)) return false;
    // loop=1: the drive loop carries the turn to a finished answer with nobody there, as a scheduled run does.
    chat_engine.spawnTurn(app, uid, conv, trio, text, 1, false, "", false, false, false, null, null); // the same turn a tot's job gets (cf_tot.launchJob): the machine's own tools, no Agent Garrett
    postLocal(app, a, uid, tok, job.id, "{\"started\":true}");
    log.info("harness: local job {s} started on this machine in conversation {s}", .{ job.id, conv });
    return true;
}

/// One pass over every user whose machine is on the mesh: say it is here, and, where the owner allowed local jobs,
/// run them. `rediscover` (every 5 minutes): also look for a harness whose address is not known, read this
/// machine's MCP server names again, and bring the Agent Garrett connection level with the harness's.
fn tick(app: *App, rediscover: bool) void {
    if (app.sup.parent_env) |env| if (env.get("VEIL_CHAT_BACKEND")) |v| {
        if (std.mem.eql(u8, std.mem.trim(u8, v, " \r\n\t"), "0")) return; // the served chat turn is off, and the jobs with it
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
        // a user who never reached a harness from here has neither: no call is made for them
        if (!st.local and !validNode(st.node)) continue;
        if (st.url.len == 0 and !rediscover) continue;
        // Admin only, as the routes are: a state file is just a file, and it must not start full-tool turns for an
        // account that could not have set the switch.
        const owner = app.auth.userById(uid) orelse continue;
        if (!app.auth.isAdmin(owner)) continue;
        const cf = cf_oauth.resolveToken(app, uid, a) orelse continue; // logged out: the jobs wait
        const tok: Tok = .{ .key = cf.key, .account_id = cf.account_id };
        ensureNode(app, uid, a, &st);
        if (rediscover) refreshMcpNames(app);
        announce(app, a, uid, tok, st);
        if (rediscover) _ = syncGarrett(app, a, uid, tok);
        if (st.local) _ = bridgeUser(app, a, uid, tok, cf.base_url, st.node);
    }
}

/// The harness thread: for the life of the process, a pass every BRIDGE_EVERY_MS. A raw thread, so a raw sleep.
pub fn bgLoop(app: *App) void {
    var n: u32 = 0;
    while (true) : (n +%= 1) {
        var slept: u64 = 0;
        while (slept < BRIDGE_EVERY_MS) : (slept += 100) bu.sleepMs(100);
        tick(app, n % REDISCOVER_EVERY_TICKS == 0);
    }
}

// ---------------------------------------------------------------------------
// tests. The Cloudflare API and the harness are one fakehttp stand-in: they cover this relay, not veil-web.js.
// ---------------------------------------------------------------------------

const tt = std.testing;

fn curlRuns(gpa: std.mem.Allocator, io: std.Io) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "curl", "--version" }, .stdout_limit = .limited(16 << 10) }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

const StandIn = struct {
    const w = fakehttp.wire;
    const subdomain = w("{\"success\":true,\"errors\":[],\"result\":{\"subdomain\":\"acme\"}}");
    const status_ok = w("{\"ok\":true,\"version\":\"3\",\"queue\":{\"waiting\":1,\"running\":0}}");
    const jobs = w("{\"ok\":true,\"jobs\":[{\"id\":\"mabc12\",\"task\":\"read the tide tables\",\"state\":\"queued\"}],\"max\":16}");
    const queued = w("{\"ok\":true,\"id\":\"mabc13\",\"position\":2}");
    const full = "HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n{\"ok\":false,\"err\":\"the queue is full (16 jobs waiting); a job joins when one starts\"}";
    const deleted = w("{\"ok\":true,\"deleted\":\"mabc12\"}");
    const schedules = w("{\"ok\":true,\"schedules\":[],\"max\":12}");
    const unauthorized = "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n{\"ok\":false,\"err\":\"unauthorized: log in with the Cloudflare account that owns this Worker\"}";
    const no_worker = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\nerror code: 1042";
};

test "every harness route is gated: an anonymous caller gets 401 and nothing runs" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    var ta = try http.testApp(gpa, threaded.io(), "zig-cfharness-gate-tmp");
    defer ta.deinit();
    inline for (.{ status, listJobs, queueJob, getJob, cancelJob, listSchedules, setLocal, listConvs, getConv, pushConv, listNodes, forgetNode, setNode, getSettings, putSettings, share }) |h| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.param("id", "mabc12");
        web.json(.{ .task = "read the tide tables", .conv = "c6acfeae2" });
        try h(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
}

test "the login only goes to the harness's own workers.dev name, or to loopback while the API is a loopback stand-in" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    var ta = try http.testApp(gpa, threaded.io(), "zig-cfharness-url-tmp");
    defer ta.deinit();
    const app = &ta.app;
    try tt.expect(harnessUrlOk(app, "https://veil-web.acme.workers.dev"));
    try tt.expect(!harnessUrlOk(app, "https://veil-tots.acme.workers.dev")); // another Worker of the same account
    try tt.expect(!harnessUrlOk(app, "https://veil-web.acme.workers.dev.evil.example"));
    try tt.expect(!harnessUrlOk(app, "https://veil-web.acme.workers.dev/v1"));
    try tt.expect(!harnessUrlOk(app, "http://veil-web.acme.workers.dev"));
    try tt.expect(!harnessUrlOk(app, "http://127.0.0.1:8791")); // the real API root: no loopback harness
    app.cf_api_root = "http://127.0.0.1:8790/client/v4";
    try tt.expect(harnessUrlOk(app, "http://127.0.0.1:8791"));
    try tt.expect(validId("mabc12") and validId("s1x9") and !validId("") and !validId("../x") and !validId("A1") and !validId("a" ** 33));
}

test "a queued job is checked before any call: the task's length, a Workers AI model, the default model when none is named" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    try tt.expect(queueBody(a, "  \n", "", &why) == null);
    try tt.expectEqualStrings("task must be 1 to 8000 characters", why);
    try tt.expect(queueBody(a, "x" ** (TASK_MAX + 1), "", &why) == null);
    try tt.expect(queueBody(a, "read the tide tables", "gpt-4o", &why) == null);
    try tt.expectEqualStrings("model must be a Workers AI model id", why);
    const sent = queueBody(a, "  say \"hi\"\n", "", &why).?;
    const P = struct { task: []const u8, model: []const u8 };
    const p = try std.json.parseFromSliceLeaky(P, a, sent, .{});
    try tt.expectEqualStrings("say \"hi\"", p.task);
    try tt.expectEqualStrings(modelcfg.defaults.cf_model, p.model);
    try tt.expect(p.model[0] == '@');
    try tt.expectEqualStrings("@cf/x/y", (try std.json.parseFromSliceLeaky(P, a, queueBody(a, "t", "@cf/x/y", &why).?, .{})).model);
}

test "the harness is found through the account's workers.dev subdomain, called with the login, and remembered once it answers" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfharness-find-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const bearer: []const []const u8 = &.{"Authorization: Bearer oauth-bearer"};
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/accounts/acct/workers/subdomain", .reply = StandIn.subdomain, .has = bearer },
        .{ .method = "GET", .path = "/v1/status", .reply = StandIn.status_ok, .has = bearer },
        .{ .method = "GET", .path = "/v1/jobs/mabc12", .reply = fakehttp.wire("{\"ok\":true,\"job\":{\"id\":\"mabc12\",\"result\":\"high tide 04:10\"}}"), .has = bearer },
        .{ .method = "GET", .path = "/v1/jobs", .reply = StandIn.jobs, .has = bearer },
        .{ .method = "POST", .path = "/v1/jobs", .reply = StandIn.queued, .times = 1, .has = &.{ "Authorization: Bearer oauth-bearer", "\"task\":\"read the tide tables\"", "\"model\":\"@cf/x/y\"" } },
        .{ .method = "POST", .path = "/v1/jobs", .reply = StandIn.full },
        .{ .method = "DELETE", .path = "/v1/jobs/mabc12", .reply = StandIn.deleted, .has = bearer },
        .{ .method = "GET", .path = "/v1/schedules", .reply = StandIn.schedules, .has = bearer },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.unauthorized);
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

    // not logged in: nothing is called
    const off = try statusJson(&ta.app, a, 1, null);
    try tt.expect(std.mem.indexOf(u8, off, "\"connected\":false,\"reachable\":false") != null);

    const S = struct { ok: bool, connected: bool, reachable: bool, url: []const u8, err: []const u8, default_model: []const u8, harness: ?struct { version: []const u8 = "", queue: struct { waiting: u32 = 0 } = .{} } };
    const s = try std.json.parseFromSliceLeaky(S, a, try statusJson(&ta.app, a, 1, tok), .{ .ignore_unknown_fields = true });
    try tt.expect(s.ok and s.connected and s.reachable);
    try tt.expectEqualStrings(stand_in, s.url); // the stand-in plays the account's workers.dev
    try tt.expectEqualStrings("", s.err);
    try tt.expectEqualStrings("3", s.harness.?.version);
    try tt.expectEqual(@as(u32, 1), s.harness.?.queue.waiting);
    try tt.expectEqualStrings(modelcfg.defaults.cf_model, s.default_model);

    // remembered: the account and the address, never the login
    const st = readState(&ta.app, 1, a);
    try tt.expectEqualStrings("acct", st.account);
    try tt.expectEqualStrings(stand_in, st.url);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/u1/" ++ STATE_FILE, a, .limited(64 << 10));
    try tt.expect(std.mem.indexOf(u8, on_disk, "oauth-bearer") == null);

    // the relayed calls come back as the harness's own JSON; its refusal in its own words
    const listed = harnessCall(&ta.app, a, 1, tok, "GET", "/v1/jobs", "", null);
    try tt.expect(listed == .ok and std.mem.indexOf(u8, listed.ok, "\"id\":\"mabc12\"") != null);
    var why: []const u8 = "";
    const body = queueBody(a, "read the tide tables", "@cf/x/y", &why).?;
    const first = harnessCall(&ta.app, a, 1, tok, "POST", "/v1/jobs", body, null);
    try tt.expect(first == .ok and std.mem.indexOf(u8, first.ok, "\"id\":\"mabc13\"") != null);
    const second = harnessCall(&ta.app, a, 1, tok, "POST", "/v1/jobs", body, null);
    try tt.expect(second == .refused);
    try tt.expect(std.mem.indexOf(u8, second.refused, "the queue is full") != null);
    const one = harnessCall(&ta.app, a, 1, tok, "GET", "/v1/jobs/mabc12", "", null);
    try tt.expect(one == .ok and std.mem.indexOf(u8, one.ok, "high tide 04:10") != null);
    try tt.expect(harnessCall(&ta.app, a, 1, tok, "DELETE", "/v1/jobs/mabc12", "", null) == .ok);
    try tt.expect(harnessCall(&ta.app, a, 1, tok, "GET", "/v1/schedules", "", null) == .ok);
    // a login the harness does not accept is refused by the harness, and says so
    const other = harnessCall(&ta.app, a, 1, .{ .key = "someone-else", .account_id = "acct" }, "GET", "/v1/jobs", "", null);
    try tt.expect(other == .refused and std.mem.startsWith(u8, other.refused, "unauthorized"));

    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/workers/subdomain")); // asked once, then remembered
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("GET", "/accounts/acct/workers/subdomain"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("GET", "/v1/status"));
    try tt.expectEqual(@as(usize, 2), srv.countCalls("POST", "/v1/jobs"));
    try tt.expectEqual(@as(usize, 9), srv.call_count);
}

test "no harness at the address: status says so, nothing is remembered, and a remembered address that stops answering is forgotten" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cfharness-absent-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/workers/subdomain", .reply = StandIn.subdomain },
        .{ .method = "GET", .path = "/v1/status", .reply = StandIn.no_worker, .times = 1 },
        .{ .method = "GET", .path = "/v1/status", .reply = StandIn.status_ok, .times = 1 },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.no_worker);
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok: Tok = .{ .key = "oauth-bearer", .account_id = "acct" };

    const absent = try statusJson(&ta.app, a, 1, tok);
    try tt.expect(std.mem.indexOf(u8, absent, "\"connected\":true,\"reachable\":false") != null);
    try tt.expect(std.mem.indexOf(u8, absent, "no veil-web harness answered at http://127.0.0.1:") != null);
    try tt.expect(std.mem.endsWith(u8, absent, ",\"harness\":null}"));
    try tt.expectEqualStrings("", readState(&ta.app, 1, a).url);

    const up = try statusJson(&ta.app, a, 1, tok); // it is there now
    try tt.expect(std.mem.indexOf(u8, up, "\"reachable\":true") != null);
    try tt.expect(readState(&ta.app, 1, a).url.len > 0);
    try tt.expect(harnessCall(&ta.app, a, 1, tok, "GET", "/v1/jobs", "", null) == .unreachable_); // and gone again
    try tt.expectEqualStrings("", readState(&ta.app, 1, a).url);

    // a state file naming another host, or another account's address, gets no call: the account is asked again
    writeState(&ta.app, 1, .{ .account = "acct", .url = "https://evil.example" });
    try tt.expect(harnessCall(&ta.app, a, 1, tok, "GET", "/v1/jobs", "", null) == .unreachable_);
    // a login that names no account is stopped before any call
    const none = harnessCall(&ta.app, a, 1, .{ .key = "oauth-bearer", .account_id = "" }, "GET", "/v1/jobs", "", null);
    try tt.expect(none == .unreachable_ and std.mem.indexOf(u8, none.unreachable_, "names no account") != null);

    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 3), srv.countCalls("GET", "/workers/subdomain")); // absent, present, and after the edited file
    try tt.expectEqual(@as(usize, 7), srv.call_count);
}

test "a local job's conversation, what its turn is told, and a result cut on a character boundary" {
    var cb: [64]u8 = undefined;
    try tt.expectEqualStrings("harness_mabc12", jobConv(&cb, "mabc12").?);
    try tt.expect(jobConv(&cb, "../x") == null and jobConv(&cb, "") == null);
    try tt.expect(jobConv(&cb, "a" ** JOB_ID_MAX).?.len <= 64);
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const text = jobText(arena.allocator(), "run the suite").?;
    try tt.expect(std.mem.startsWith(u8, text, "run the suite\n") and std.mem.indexOf(u8, text, "sent back to the harness") != null);
    try tt.expectEqualStrings("abc", clipUtf8("abc", 10));
    try tt.expectEqualStrings("ab", clipUtf8("ab\xc3\xa9", 3)); // never half of a two-byte character
    try tt.expectEqualStrings("ab\xc3\xa9", clipUtf8("ab\xc3\xa9z", 4));
}

test "the owner's switch is off until set, is kept in the state file, and survives a forgotten address" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    var ta = try http.testApp(gpa, threaded.io(), "zig-cfharness-switch-tmp");
    defer ta.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try tt.expect(!readState(&ta.app, 1, a).local);
    try tt.expect(std.mem.indexOf(u8, try statusJson(&ta.app, a, 1, null), "\"local\":false") != null);
    writeState(&ta.app, 1, .{ .account = "acct", .url = "https://veil-web.acme.workers.dev", .local = true });
    try tt.expect(std.mem.indexOf(u8, try statusJson(&ta.app, a, 1, null), "\"local\":true") != null);
    forgetUrl(&ta.app, 1, readState(&ta.app, 1, a));
    const st = readState(&ta.app, 1, a);
    try tt.expect(st.local);
    try tt.expectEqualStrings("", st.url);
}

test "local jobs: an ended turn's answer goes back to the harness, a turn that left none is a failure, and nothing is started twice" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfharness-bridge-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    // h1's turn has answered; h2's ran and left only the user message.
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, root ++ "/u1/_chat/convs/harness_h1", .default_dir);
    _ = try cwd.createDirPathStatus(io, root ++ "/u1/_chat/convs/harness_h2", .default_dir);
    try cwd.writeFile(io, .{ .sub_path = root ++ "/u1/_chat/convs/harness_h1/messages.jsonl", .data = "{\"role\":\"user\",\"content\":\"run the suite\",\"kind\":\"\",\"ts\":1}\n{\"role\":\"assistant\",\"content\":\"working on it\",\"kind\":\"\",\"ts\":2}\n{\"role\":\"assistant\",\"content\":\"42 passed, 0 failed\",\"kind\":\"\",\"ts\":3}\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/u1/_chat/convs/harness_h2/messages.jsonl", .data = "{\"role\":\"user\",\"content\":\"build it\",\"kind\":\"\",\"ts\":1}\n" });

    const w = fakehttp.wire;
    const bearer: []const []const u8 = &.{"Authorization: Bearer oauth-bearer"};
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/v1/local", .reply = w("{\"ok\":true,\"jobs\":[{\"id\":\"h1\",\"t\":1790000000123,\"task\":\"run the suite\",\"model\":\"@cf/x/y\",\"state\":\"running\"},{\"id\":\"../x\",\"t\":1,\"task\":\"bad\",\"model\":\"@cf/x/y\",\"state\":\"queued\"},{\"id\":\"h2\",\"t\":1790000001000,\"task\":\"build it\",\"model\":\"@cf/x/y\",\"state\":\"running\"}]}"), .has = bearer },
        .{ .method = "POST", .path = "/v1/local/h1", .reply = w("{\"ok\":true,\"id\":\"h1\",\"state\":\"done\"}"), .has = &.{ "Authorization: Bearer oauth-bearer", "{\"ok\":true,\"result\":\"42 passed, 0 failed\"}" } },
        .{ .method = "POST", .path = "/v1/local/h2", .reply = w("{\"ok\":true,\"id\":\"h2\",\"state\":\"failed\"}"), .has = &.{ "Authorization: Bearer oauth-bearer", "\"ok\":false", "ended without an answer" } },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, w("{\"ok\":false,\"err\":\"not found\"}"));
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    writeState(&ta.app, 1, .{ .account = "acct", .url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port}), .local = true });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok: Tok = .{ .key = "oauth-bearer", .account_id = "acct" };
    try tt.expectEqual(@as(usize, 0), bridgeUser(&ta.app, a, 1, tok, "", "")); // nothing was started
    try tt.expect(readState(&ta.app, 1, a).local); // the answers left the switch as it was

    srv.stop();
    running = false;
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("GET", "/v1/local"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("POST", "/v1/local/h1"));
    try tt.expectEqual(@as(?usize, 2), srv.firstCall("POST", "/v1/local/h2"));
    try tt.expectEqual(@as(usize, 3), srv.call_count); // the id that is no path segment got no call
    try tt.expectEqual(@as(u32, 1), srv.used[1]); // h1's body was the turn's last answer, exactly
    try tt.expectEqual(@as(u32, 1), srv.used[2]); // h2's said it failed, and why
}

test "local jobs: a harness with no such route, or none answering, starts nothing and is asked once" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cfharness-oldharness-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &.{}, fakehttp.wire("{\"ok\":false,\"err\":\"not found\"}")); // a harness from before local jobs
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    writeState(&ta.app, 1, .{ .account = "acct", .url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port}), .local = true });
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try tt.expectEqual(@as(usize, 0), bridgeUser(&ta.app, a, 1, .{ .key = "oauth-bearer", .account_id = "acct" }, "", ""));
    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 1), srv.call_count);
}

test "a pushed conversation's harness id is derived, stable, and one the harness accepts; ids are checked both ways" {
    var a: [21]u8 = undefined;
    var b: [21]u8 = undefined;
    try tt.expectEqualStrings(pushId(&a, "c6acfeae2"), pushId(&b, "c6acfeae2"));
    try tt.expect(validConvId(pushId(&a, "c6acfeae2")) and a[0] == 'd');
    try tt.expect(!std.mem.eql(u8, pushId(&a, "c6acfeae2"), pushId(&b, "c6acfeae3")));
    try tt.expect(validConvId(pushId(&a, "scheduled_" ++ "x" ** 54))); // the longest id here still maps
    try tt.expect(validConvId("mabc12") and !validConvId("abc") and !validConvId("ABCDEF") and !validConvId("a" ** 25) and !validConvId("../etc"));
    try tt.expect(validLocalConv("c6acfeae2") and validLocalConv("scheduled_a-b_1") and !validLocalConv("") and !validLocalConv("../x") and !validLocalConv("a/b") and !validLocalConv("a" ** 65));
}

test "pushing a conversation sends its user and assistant text in order, without the engine's rows, and reports a newer harness copy" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cfharness-push-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, root ++ "/u1/_chat/convs/c6acfeae2", .default_dir);
    _ = try cwd.createDirPathStatus(io, root ++ "/u1/_chat/convs/cempty", .default_dir);
    try cwd.writeFile(io, .{ .sub_path = root ++ "/u1/_chat/convs/c6acfeae2/messages.jsonl", .data = "{\"role\":\"system\",\"content\":\"engine: the working context\",\"kind\":\"engine\",\"ts\":1790000000}\n" ++
        "{\"role\":\"user\",\"content\":\"when is\\nhigh tide \\\"today\\\"?\",\"kind\":\"user\",\"ts\":1790000001}\n" ++
        "{\"role\":\"assistant\",\"content\":\"\",\"kind\":\"veil\",\"ts\":1790000002}\n" ++
        "not json\n" ++
        "{\"role\":\"assistant\",\"content\":\"High tide is at 04:10.\",\"kind\":\"veil\",\"ts\":1790000009}\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/u1/_chat/convs/cempty/messages.jsonl", .data = "{\"role\":\"system\",\"content\":\"engine: nothing yet\",\"kind\":\"engine\",\"ts\":1}\n" });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const p = pushBody(&ta.app, a, 1, "c6acfeae2", &why).?;
    try tt.expectEqual(@as(usize, 2), p.msgs);
    const B = struct { title: []const u8, at: i64, msgs: []const struct { role: []const u8, content: []const u8 }, files: std.json.Value };
    const b = try std.json.parseFromSliceLeaky(B, a, p.body, .{});
    try tt.expectEqualStrings("when is high tide \"today\"?", b.title); // one line
    try tt.expectEqual(@as(i64, 1790000009000), b.at); // the last message, in ms
    try tt.expectEqualStrings("user", b.msgs[0].role);
    try tt.expectEqualStrings("when is\nhigh tide \"today\"?", b.msgs[0].content); // the message itself is whole
    try tt.expectEqualStrings("assistant", b.msgs[1].role);
    try tt.expectEqualStrings("High tide is at 04:10.", b.msgs[1].content);
    try tt.expect(b.files == .object and b.files.object.count() == 0);
    try tt.expect(pushBody(&ta.app, a, 1, "cempty", &why) == null);
    try tt.expectEqualStrings("that conversation has no messages to push", why);
    try tt.expect(pushBody(&ta.app, a, 1, "cnone", &why) == null);
    try tt.expectEqualStrings("this server holds no such conversation", why);
    try tt.expect(pushBody(&ta.app, a, 2, "c6acfeae2", &why) == null); // another user's conversation is not this user's to push

    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    var ib: [21]u8 = undefined;
    const id = pushId(&ib, "c6acfeae2");
    var pb: [40]u8 = undefined;
    const conv_path = try std.fmt.bufPrint(&pb, "/v1/convs/{s}", .{id});
    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "POST", .path = conv_path, .reply = w("{\"ok\":true,\"at\":1790000009000}"), .times = 1, .has = &.{ "Authorization: Bearer oauth-bearer", "\"msgs\":[{\"role\":\"user\"", "High tide is at 04:10." } },
        .{ .method = "POST", .path = conv_path, .reply = w("{\"ok\":true,\"stale\":true,\"at\":1790000099000}") },
        .{ .method = "GET", .path = "/v1/convs/mabc12", .reply = w("{\"ok\":true,\"conv\":{\"id\":\"mabc12\",\"title\":\"Tides\",\"at\":5,\"msgs\":[],\"files\":{}}}") },
        .{ .method = "GET", .path = "/v1/convs", .reply = w("{\"ok\":true,\"convs\":[{\"id\":\"mabc12\",\"title\":\"Tides\",\"at\":5,\"bytes\":90}],\"max\":200}") },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, w("{\"ok\":false,\"err\":\"not found\"}"));
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    writeState(&ta.app, 1, .{ .account = "acct", .url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port}) });
    const tok: Tok = .{ .key = "oauth-bearer", .account_id = "acct" };

    const first = pushAs(&ta.app, a, 1, tok, "c6acfeae2");
    try tt.expect(first == .ok);
    const R = struct { ok: bool, id: []const u8, msgs: usize, stale: bool };
    const r1 = try std.json.parseFromSliceLeaky(R, a, first.ok, .{});
    try tt.expect(r1.ok and !r1.stale and r1.msgs == 2);
    try tt.expectEqualStrings(id, r1.id);
    const second = pushAs(&ta.app, a, 1, tok, "c6acfeae2"); // the harness holds a newer copy and keeps it
    try tt.expect((try std.json.parseFromSliceLeaky(R, a, second.ok, .{})).stale);
    const none = pushAs(&ta.app, a, 1, tok, "cnone"); // nothing to send: no call
    try tt.expect(none == .out and none.out == .refused);
    const listed = harnessCall(&ta.app, a, 1, tok, "GET", "/v1/convs", "", null);
    try tt.expect(listed == .ok and std.mem.indexOf(u8, listed.ok, "\"title\":\"Tides\"") != null);
    try tt.expect(harnessCall(&ta.app, a, 1, tok, "GET", "/v1/convs/mabc12", "", null) == .ok);
    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 2), srv.countCalls("POST", "/v1/convs/"));
    try tt.expectEqual(@as(usize, 4), srv.call_count);
}

test "a machine's mesh id is made once, kept with its name, and survives a forgotten address; ids and addressed jobs are checked" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    var ta = try http.testApp(gpa, threaded.io(), "zig-cfharness-node-tmp");
    defer ta.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try tt.expect(validNode("desk0000aaaa1111") and validNode("abcdefgh") and !validNode("short") and !validNode("Desk0000aaaa1111") and !validNode("a" ** 33) and !validNode("../../etc/passwd"));

    writeState(&ta.app, 1, .{ .account = "acct", .url = "http://127.0.0.1:1", .local = true, .garrett_at = 7 });
    var st = readState(&ta.app, 1, a);
    ensureNode(&ta.app, 1, a, &st);
    try tt.expectEqual(@as(usize, 16), st.node.len);
    try tt.expect(validNode(st.node));
    try tt.expect(st.name.len > 0); // the computer's own name, or "veil"
    const first = try a.dupe(u8, st.node);
    var again = readState(&ta.app, 1, a);
    ensureNode(&ta.app, 1, a, &again);
    try tt.expectEqualStrings(first, again.node); // made once

    forgetUrl(&ta.app, 1, again);
    const kept = readState(&ta.app, 1, a);
    try tt.expectEqualStrings("", kept.url);
    try tt.expectEqualStrings(first, kept.node);
    try tt.expect(kept.local and kept.garrett_at == 7 and kept.name.len > 0);

    // what it says about itself
    node_kind = "desk";
    node_version = "9.9.9";
    defer node_kind = "server";
    defer node_version = "";
    var named = kept;
    named.name = "Office desk";
    const body = nodeBody(&ta.app, a, 1, named).?;
    try tt.expect(std.mem.indexOf(u8, body, "\"name\":\"Office desk\"") != null);
    try tt.expect(std.mem.indexOf(u8, body, "\"kind\":\"desk\"") != null);
    try tt.expect(std.mem.indexOf(u8, body, "\"version\":\"9.9.9\"") != null);
    try tt.expect(std.mem.indexOf(u8, body, "\"runs\":true") != null);
    try tt.expect(std.mem.indexOf(u8, body, "\"garrett\":false") != null);

    // an addressed job names its node and who asked; a bad node id costs no call
    var why: []const u8 = "";
    const q = queueBodyFor(a, "count the stock files", "@cf/x/y", "shop0000bbbb2222", first, &why).?;
    try tt.expect(std.mem.indexOf(u8, q, "\"node\":\"shop0000bbbb2222\"") != null);
    try tt.expect(std.mem.indexOf(u8, q, "\"from\":\"") != null);
    try tt.expect(queueBodyFor(a, "x", "@cf/x/y", "../x", first, &why) == null);
    try tt.expect(std.mem.indexOf(u8, queueBody(a, "x", "@cf/x/y", &why).?, "node") == null); // a cloud job says nothing of nodes
}

test "the mesh from a chat turn: the inventory marks this machine, a task goes to the named node only if it runs work, and its result is read back" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cfharness-mesh-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    const w = fakehttp.wire;
    const bearer: []const []const u8 = &.{"Authorization: Bearer oauth-bearer"};
    const nodes = w("{\"ok\":true,\"now\":1790000100000,\"nodes\":[" ++
        "{\"id\":\"desk0000aaaa1111\",\"name\":\"Office\",\"kind\":\"desk\",\"os\":\"windows\",\"version\":\"1.2.3\",\"runs\":true,\"browser\":false,\"garrett\":true,\"mcp\":[\"files\",\"git\"],\"seen\":1790000099000,\"online\":true,\"waiting\":0}," ++
        "{\"id\":\"shop0000bbbb2222\",\"name\":\"Shop\",\"kind\":\"desk\",\"os\":\"linux\",\"version\":\"1.2.3\",\"runs\":true,\"browser\":false,\"garrett\":false,\"mcp\":[],\"seen\":1790000000000,\"online\":false,\"waiting\":2}," ++
        "{\"id\":\"tab00000cccc3333\",\"name\":\"Laptop tab\",\"kind\":\"web\",\"os\":\"\",\"version\":\"9\",\"runs\":false,\"browser\":true,\"garrett\":false,\"mcp\":[],\"seen\":1790000099500,\"online\":true,\"waiting\":0}]}");
    const routes = [_]fakehttp.Route{
        .{ .method = "POST", .path = "/v1/nodes/desk0000aaaa1111", .reply = w("{\"ok\":true,\"id\":\"desk0000aaaa1111\",\"nodes\":3}"), .has = &.{ "Authorization: Bearer oauth-bearer", "\"name\":\"Office\"", "\"runs\":true" } },
        .{ .method = "GET", .path = "/v1/nodes", .reply = nodes, .has = bearer },
        .{ .method = "POST", .path = "/v1/jobs", .reply = w("{\"ok\":true,\"id\":\"mjob77\",\"local\":true,\"node\":\"shop0000bbbb2222\",\"position\":1}"), .has = &.{ "Authorization: Bearer oauth-bearer", "\"task\":\"count the stock files\"", "\"node\":\"shop0000bbbb2222\"", "\"from\":\"desk0000aaaa1111\"" } },
        .{ .method = "GET", .path = "/v1/jobs/mjob77", .reply = w("{\"ok\":true,\"job\":{\"id\":\"mjob77\",\"state\":\"done\",\"result\":\"41 files\",\"error\":\"\",\"note\":\"\",\"node\":\"shop0000bbbb2222\"}}"), .has = bearer },
        .{ .method = "GET", .path = "/v1/jobs/mjob78", .reply = w("{\"ok\":true,\"job\":{\"id\":\"mjob78\",\"state\":\"queued\",\"result\":\"\",\"error\":\"\",\"note\":\"waiting for the owner's machine\"}}"), .has = bearer },
        .{ .method = "GET", .path = "/v1/local?node=desk0000aaaa1111", .reply = w("{\"ok\":true,\"jobs\":[]}"), .has = bearer },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, w("{\"ok\":false,\"err\":\"not found\"}"));
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    writeState(&ta.app, 1, .{ .account = "acct", .url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port}), .local = true, .node = "desk0000aaaa1111", .name = "Office" });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok: Tok = .{ .key = "oauth-bearer", .account_id = "acct" };

    const inv = meshRun(&ta.app, a, 1, tok, "mesh_inventory", "{}");
    try tt.expect(std.mem.indexOf(u8, inv, "3 node(s)") != null);
    try tt.expect(std.mem.indexOf(u8, inv, "desk0000aaaa1111 | Office (THIS machine) | desk | windows | 1.2.3 | online | runs work | no browser | Garrett | files git | 0") != null);
    try tt.expect(std.mem.indexOf(u8, inv, "shop0000bbbb2222 | Shop | desk | linux | 1.2.3 | offline, last seen 100 s ago | runs work") != null);
    try tt.expect(std.mem.indexOf(u8, inv, "tab00000cccc3333 | Laptop tab | web | - | 9 | online | does not run work") != null);

    // by name, letter case ignored; the offline node is told so
    const sent = meshRun(&ta.app, a, 1, tok, "mesh_run", "{\"node\":\"shop\",\"task\":\"count the stock files\"}");
    try tt.expect(std.mem.indexOf(u8, sent, "queued as job mjob77 for Shop (shop0000bbbb2222)") != null);
    try tt.expect(std.mem.indexOf(u8, sent, "OFFLINE") != null);
    // refused before any job is queued: this machine, a node that does not run work, a node nobody knows
    try tt.expect(std.mem.indexOf(u8, meshRun(&ta.app, a, 1, tok, "mesh_run", "{\"node\":\"desk0000aaaa1111\",\"task\":\"x\"}"), "THIS machine") != null);
    try tt.expect(std.mem.indexOf(u8, meshRun(&ta.app, a, 1, tok, "mesh_run", "{\"node\":\"Laptop tab\",\"task\":\"x\"}"), "does not run work") != null);
    try tt.expect(std.mem.indexOf(u8, meshRun(&ta.app, a, 1, tok, "mesh_run", "{\"node\":\"basement\",\"task\":\"x\"}"), "no node has that id") != null);

    try tt.expectEqualStrings("job mjob77: done. The other veil reported:\n41 files", meshRun(&ta.app, a, 1, tok, "mesh_result", "{\"job\":\"mjob77\"}"));
    try tt.expect(std.mem.indexOf(u8, meshRun(&ta.app, a, 1, tok, "mesh_result", "{\"job\":\"mjob78\"}"), "queued - waiting for the owner's machine. Not ended yet") != null);
    try tt.expect(std.mem.indexOf(u8, meshRun(&ta.app, a, 1, tok, "mesh_result", "{\"job\":\"../x\"}"), "give the job id") != null);

    // this machine asks for its own jobs by its id
    try tt.expectEqual(@as(usize, 0), bridgeUser(&ta.app, a, 1, tok, "", "desk0000aaaa1111"));

    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 1), srv.countCalls("POST", "/v1/jobs")); // one job, for the one node that could take it
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/v1/local?node=desk0000aaaa1111"));
    try tt.expect(isMeshTool("mesh_inventory") and isMeshTool("mesh_run") and isMeshTool("mesh_result") and !isMeshTool("mesh_") and !isMeshTool("cast"));
    inline for (.{ "mesh_inventory", "mesh_run", "mesh_result" }) |n| try tt.expect(std.mem.indexOf(u8, MESH_SCHEMA, "\"name\":\"" ++ n ++ "\"") != null);
}

test "the Agent Garrett connection is brought level: taken once from the harness, not taken again after a disconnect here, given when only this server has one" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cfharness-share-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    const w = fakehttp.wire;
    const key_a = "gtt_" ++ "a1" ** 32;
    const key_b = "gtt_" ++ "b2" ** 32;
    const bearer: []const []const u8 = &.{"Authorization: Bearer oauth-bearer"};
    const routes = [_]fakehttp.Route{
        // three passes see the harness holding key A (taken at 77); then it holds nothing; then key B (given by this server, at 90)
        .{ .method = "GET", .path = "/v1/share", .reply = w("{\"ok\":true,\"garrett\":{\"url\":\"" ++ cf_garrett.MCP_URL ++ "\",\"token\":\"" ++ key_a ++ "\",\"tools\":166,\"at\":77},\"mcp\":[]}"), .times = 3, .has = bearer },
        .{ .method = "GET", .path = "/v1/share", .reply = w("{\"ok\":true,\"garrett\":null,\"mcp\":[]}"), .times = 1, .has = bearer },
        .{ .method = "GET", .path = "/v1/share", .reply = w("{\"ok\":true,\"garrett\":{\"url\":\"" ++ cf_garrett.MCP_URL ++ "\",\"token\":\"" ++ key_b ++ "\",\"tools\":166,\"at\":90},\"mcp\":[]}"), .has = bearer },
        .{ .method = "POST", .path = "/v1/garrett", .reply = w("{\"ok\":true,\"version\":\"9\"}"), .has = &.{ "Authorization: Bearer oauth-bearer", "{\"key\":\"" ++ key_b ++ "\"}" } },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, w("{\"ok\":false,\"err\":\"not found\"}"));
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    writeState(&ta.app, 1, .{ .account = "acct", .url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port}) });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok: Tok = .{ .key = "oauth-bearer", .account_id = "acct" };

    // nothing here, key A on the harness: taken
    try tt.expectEqual(GarrettSync.pulled, syncGarrett(&ta.app, a, 1, tok));
    try tt.expectEqualStrings(key_a, cf_garrett.managedFor(&ta.app, 1, a).creds.?.token);
    try tt.expectEqual(@as(i64, 77), readState(&ta.app, 1, a).garrett_at);
    // both hold the same one
    try tt.expectEqual(GarrettSync.same, syncGarrett(&ta.app, a, 1, tok));
    // the owner disconnects here: the same harness connection is not taken a second time
    try cf_garrett.saveManaged(&ta.app, 1, "", 0);
    try tt.expectEqual(GarrettSync.none, syncGarrett(&ta.app, a, 1, tok));
    try tt.expect(cf_garrett.managedFor(&ta.app, 1, a).creds == null);
    // connected here with key B, nothing on the harness: given, and its time there remembered
    try cf_garrett.saveManaged(&ta.app, 1, key_b, 166);
    try tt.expectEqual(GarrettSync.pushed, syncGarrett(&ta.app, a, 1, tok));
    try tt.expectEqual(@as(i64, 90), readState(&ta.app, 1, a).garrett_at);

    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 1), srv.countCalls("POST", "/v1/garrett"));
    // the state file never holds a key
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, "zig-cfharness-share-tmp/u1/" ++ STATE_FILE, a, .limited(64 << 10));
    try tt.expect(std.mem.indexOf(u8, on_disk, "gtt_") == null);
}
