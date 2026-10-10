//! cf_tot.zig — TOTS: autonomous technicians that run the veil's goal loop in the user's own Cloudflare account.
//!
//! WHAT: a tot (Tiny Overview Technician) is the goal loop of worker/chat/goal.zig with no human in it and no
//! machine of the user's under it. It lives in one Worker script ("veil-tots") this file uploads into the
//! account behind "Log in with Cloudflare": each tot is a Durable Object whose alarm runs one iteration
//! (pick -> do -> measure -> record -> learn), and whose model calls go through the account's own AI binding.
//! The runtime is cloud/tot.js, embedded here and uploaded as it is; its header says what a tot can do. Beside it
//! goes cloud/tot_py.py, a second Worker ("veil-tots-py") that runs a tot's Python, and the upload asks for
//! Cloudflare's browser binding: both are optional, and an account that refuses one gets a tot without it.
//! An account runs DEFAULT_MAX_TOTS of them unless its owner sets another limit (POST /api/v1/tots/limit, up to
//! MAX_TOTS_CEIL; what an account can really carry is its Cloudflare plan's to say), and the first is always PRIMARY.
//!
//! HOW: the same OAuth token the chat turns use (workers-scripts.write) uploads the script, enables its
//! workers.dev address and sets ONE secret on it: the token every later call carries. That token is never
//! stored: it is derived from the server key, the user, the account and a generation counter (totToken), so
//! the state file ({data}/u{uid}/cf_tots.json) holds an address and a hash, nothing a reader could use.
//! After that this file is a relay: the desk and `veil --tater` ask this server, and this server asks
//! the Worker - roster, deploy, command, settings, events, the shared scratchpad, delete.
//!
//! THE OWNER'S MACHINE: a tot deployed with `local` (a checkbox at deployment, never changeable later) may
//! queue jobs for the veil here. Nothing listens at home for them: bgLoop polls each approved tot's queue and
//! runs a job as an unattended chat turn - the same entry points a scheduled task uses (worker/sched.zig) - in
//! a conversation named for the job, then posts the turn's final answer back. The approval is recorded HERE
//! (State.local): a runtime that claimed the grant for itself would still find no bridge.
//!
//!   GET    /api/v1/tots                  roster + deployment status
//!   POST   /api/v1/tots                  deploy one (uploads the runtime first when it is absent or older)
//!   DELETE /api/v1/tots                  remove the runtime and every tot from the account
//!   DELETE /api/v1/tots/:name            delete one tot; deleting the LAST one also removes the Worker
//!   GET    /api/v1/tots/:name/events     its event tail (?after=N)
//!   POST   /api/v1/tots/:name/command    a command or a message ("/goal ...", "/pause", plain words)
//!   POST   /api/v1/tots/:name/config     settings: model, pace_s, size, daily_calls, charter, paused
//!   GET    /api/v1/tots/pad              the scratchpad the account's tots share (?after=N)
//!   POST   /api/v1/tots/pad              write to it
//!   POST   /api/v1/tots/pad/clear        empty it (the local copy is kept as _tots/scratchpad-<when>.md)
//!   POST   /api/v1/tots/keys             give the tots a key ({"name":"brave","value":"..."}); "" removes it. Names:
//!                                        brave, google, google_cx (search), alert (the guard's webhook, https),
//!                                        garrett_url + garrett_token (an Agent Garrett the owner deployed by hand)
//!   GET    /api/v1/tots/garrett          Agent Garrett: deployed or not, its address, what the runtime says
//!                                        (?reveal=1 adds the password locking its chat UI)
//!   POST   /api/v1/tots/garrett          deploy it now;  DELETE removes it
//!
//! AGENT GARRETT (github.com/gary23w/garrettstimpson.ca/agent): a Worker of its own, `veil-garrett`, with ninety-odd
//! blue-team tools behind a stateless MCP endpoint (CVE/KEV/EPSS intel, DNS and certificate transparency, RDAP,
//! email security posture, IOC extraction, evidence manifests...). It is the user's ACCOUNT-LEVEL deployment, not
//! the tots': the desk's Settings button (Deploy Agent Garrett), `veil --tater garrett launch` or a tot's own
//! garrett_launch puts it there, with or without a tot in the account. launchGarrett reads its wrangler.toml and
//! every module under its src/ from the repo, LIVE, and uploads them through the same login, with derived secrets (its MCP bearer; a password locking the
//! chat UI nobody asked for; its policy vars pin safe mode and no active or dark-web tools over MCP), enables its
//! address, and - when the tots' Worker is in the account - points it at the agent with two secrets (a runtime
//! uploaded later is pointed at it by ensureRuntime). WHO USES IT is opt-in, per thing: a chat turn that asked
//! (`garrett` in the message body), a swarm deployed with `garrett`, a tot deployed or configured with `garrett`;
//! config/cf_garrett.zig derives the pair for all of them. Removing the tots keeps it; DELETE removes it.
//!
//! THE LOCAL FOLDER: every deployment of a tot is mirrored into {data}/u<uid>/_tots/<name>-<deployed>/ (events.log
//! to tail, events.jsonl, status.json, notes/), with the shared scratchpad at _tots/scratchpad.md. See mirrorTot.
//!
//! Every route is admin-gated, like the scheduled tasks: a tot with the owner's machine runs full-tool turns.

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const cf_oauth = @import("cf_oauth.zig");
const security_runtime = @import("../worker/garrett.zig");
const cf_garrett = @import("cf_garrett.zig"); // Agent Garrett's derived pair and labels, as every reader of it sees them
const chat_engine = @import("../worker/chat/engine.zig");
const bu = @import("../worker/browser/util.zig"); // sleepMs: a raw-thread sleep, no Io park
const modelcfg = @import("modelcfg");
const fakehttp = @import("../worker/fakehttp.zig"); // TEST ONLY: the stand-in Cloudflare API and tot runtime
const App = http.App;
const badReq = http.badReq;
const log = std.log.scoped(.cf_tot);

/// The runtime, uploaded as it is (cloud/tot.js; build.zig hands it over by this name).
const TOT_JS = @embedFile("tot.js");
/// The Python a tot runs: a second Worker, reached from the runtime through a service binding (cloud/tot_py.py).
const TOT_PY = @embedFile("tot_py.py");
/// The tot's mind: neuron-db compiled to WebAssembly and its binding, two more modules of the runtime's upload.
const NEURON_WASM = @embedFile("neuron_core.wasm");
const NEURON_MJS = @embedFile("neuron-db.mjs");

pub const SCRIPT = "veil-tots";
pub const PY_SCRIPT = "veil-tots-py";
const PY_MODULE = "tot_py.py";
pub const DEFAULT_MAX_TOTS: u32 = 24; // tot.js enforces the limit it is sent; a test below holds the two to one number
pub const MAX_TOTS_CEIL: u32 = 1000;
pub const PRIMARY = "Gary";
const MODULE = "tot.js";
const COMPAT_DATE = "2025-09-01";
const MIGRATION_TAG = "v1";
const STATE_FILE = cf_garrett.STATE_FILE; // cf_garrett reads the Agent Garrett fields of the same file
const NAME_MAX = 24;

/// How often the bridge asks each approved tot for jobs.
const BRIDGE_EVERY_MS: u64 = 20_000;

// Agent Garrett: the script name beside the tots', where its modules come from, and what its upload asks for.
pub const GARRETT_SCRIPT = cf_garrett.SCRIPT;
// Agent Garrett comes from its repo, LIVE, at every launch: its Worker config (agent/wrangler.toml) and every module
// under its main module's directory, as the repo has them then. Nothing about its layout is pinned here (a pinned
// list of five modules once left a sixth import unresolved, and Cloudflare refused the upload), so the agent's own
// changes land at the next launch. The listing is GitHub's contents API (unauthenticated: 60 calls an hour, a
// launch uses one per directory); the files come from raw.githubusercontent.com.
const GARRETT_REPO = "gary23w/garrettstimpson.ca";
const GARRETT_DIR = "agent"; // the agent's folder in the repo: its wrangler.toml, its src/
const GARRETT_RAW = "https://raw.githubusercontent.com/" ++ GARRETT_REPO ++ "/main/" ++ GARRETT_DIR ++ "/";
const GARRETT_LIST = "https://api.github.com/repos/" ++ GARRETT_REPO ++ "/contents/" ++ GARRETT_DIR ++ "/";
const GARRETT_TOML = "wrangler.toml";
const GARRETT_COMPAT_DATE = "2026-09-03"; // when the toml names none (it does)
const GARRETT_MIGRATION_TAG = "veil-garrett-v1"; // when the toml names none (it does: its own tag is used)
const GARRETT_FILE_MAX: usize = 8 << 20; // one module (index.js is ~430 KB, the engine ~350 KB)
const GARRETT_FILES_MAX = 64; // modules a launch carries; a directory past that is not the agent
const GARRETT_UA = "nl-veil (+https://github.com/gary23w/nl-veil)"; // what the reads say they are

// ---------------------------------------------------------------------------------- per-user state file

/// What this server remembers about a user's tots. No secret: the runtime's token is derived (totToken).
const State = struct {
    account: []const u8 = "", // the Cloudflare account the runtime was uploaded to
    url: []const u8 = "", // https://veil-tots.<subdomain>.workers.dev
    script_hash: []const u8 = "", // the tot.js that is up there (scriptHash)
    runtime_source: []const u8 = "", // a tot's deployed self-edit; empty uses this binary's runtime
    runtime_revision: u64 = 0,
    token_gen: u32 = 0, // bumped to rotate the runtime's token
    deployed_at: i64 = 0,
    python: bool = false, // the runtime has its Python Worker bound (run_python, skills)
    browser: bool = false, // the runtime has Cloudflare's browser bound (browser_*)
    neuron: bool = false, // the runtime carries neuron-db (recall by meaning, stances, mood)
    tools_note: []const u8 = "", // why one of them is missing, in Cloudflare's words
    py_rung: u8 = 0, // which PY_NATIVE set the Python Worker was uploaded with
    py_check: u8 = 0, // how many more times to ask whether that Python starts; 0 = settled
    py_fails: u8 = 0, // answers in a row saying it does not
    py_native: []const []const u8 = &.{}, // the native packages it came up with, as it reports them
    local: []const []const u8 = &.{}, // tots the owner allowed onto this machine, by name
    last_error: []const u8 = "",
    moved: bool = false, // the old (hots) state only: everything is across, the old Workers' removal is left
    max_tots: u32 = 0, // the owner's limit on how many this account runs; 0 = DEFAULT_MAX_TOTS
    garrett_url: []const u8 = "", // https://veil-garrett.<subdomain>.workers.dev once Agent Garrett is launched
    garrett_hash: []const u8 = "", // the modules it was launched from (garrettHash)
    garrett_at: i64 = 0,
    garrett_account: []const u8 = "", // the account it was launched into (empty for a launch from before this field: the tots' account)
    garrett_gen: u32 = 0, // the generation its secrets were derived under (likewise: the tots' token_gen then)
};

/// How many tots this account may run.
fn limitOf(st: State) u32 {
    return if (st.max_tots == 0) DEFAULT_MAX_TOTS else @min(st.max_tots, MAX_TOTS_CEIL);
}

fn statePath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ STATE_FILE, .{ app.data, uid }) catch null;
}

/// The stored state, or defaults. Everything is allocated in `a`.
fn readState(app: *App, uid: u64, a: std.mem.Allocator) State {
    var pb: [700]u8 = undefined;
    const path = statePath(app, uid, &pb) orelse return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(16 << 20)) catch return .{};
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

/// A tot's name: 1-24 of [A-Za-z0-9_-], starting with a letter. The same rule tot.js applies (validName): the
/// name becomes a URL segment there and part of a conversation id here.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > NAME_MAX or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

/// The bearer the runtime answers to, as 64 hex characters. Derived, so it is never written anywhere on this
/// machine: HMAC-SHA256 under the server key of the user, the account and the generation.
fn totToken(app: *App, uid: u64, account: []const u8, gen: u32, out: *[64]u8) []const u8 {
    return tokenWith(app, "veil-tot-token", uid, account, gen, out);
}

/// One derivation for every secret the veil puts in the account (cf_garrett.zig holds it: Agent Garrett's readers
/// derive its bearer the same way without importing this launcher).
const tokenWith = cf_garrett.tokenWith;

/// Which tot.js this binary carries, as 16 hex characters.
fn scriptHash(out: *[16]u8) []const u8 {
    return sourceHash(TOT_JS, out);
}

fn sourceHash(source: []const u8, out: *[16]u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(source);
    h.update("\x00");
    h.update(TOT_PY);
    h.update("\x00");
    h.update(NEURON_MJS);
    h.update(NEURON_WASM);
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
        return std.fmt.allocPrint(a, "{s}: your Cloudflare login has not granted the required permission - Disconnect and log in with Cloudflare again to grant it", .{what}) catch what;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ what, msg }) catch what;
}

/// One v4 call, the reply copied into `a`.
fn api(app: *App, a: std.mem.Allocator, method: []const u8, url: []const u8, body: []const u8, bearer: []const u8, content_type: []const u8) ?[]u8 {
    const raw = cf_oauth.apiCall(app, method, url, body, bearer, content_type) orelse return null;
    defer app.gpa.free(raw);
    return a.dupe(u8, raw) catch null;
}

/// Which optional bindings an upload asks for. The runtime works without either; each is one family of tools.
const Extras = struct { python: bool, browser: bool, neuron: bool = false };

/// The script upload: a multipart body of the metadata and the module. The metadata names the AI binding and the
/// object class, and KEEPS the secret already on the script - the token is set by its own small call (putSecret),
/// so it is never part of a body that has to ride a file. `fresh` adds the migration that creates the class,
/// which Cloudflare accepts exactly once per script. `x` adds the Python Worker (a service binding, PY) and
/// Cloudflare's browser (BROWSER).
fn uploadBody(a: std.mem.Allocator, boundary: []const u8, fresh: bool, x: Extras) ![]u8 {
    return uploadSourceBody(a, boundary, fresh, x, TOT_JS);
}

fn uploadSourceBody(a: std.mem.Allocator, boundary: []const u8, fresh: bool, x: Extras, source: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\nContent-Type: application/json\r\n\r\n", .{boundary});
    try out.appendSlice(a, "{\"main_module\":\"" ++ MODULE ++ "\",\"compatibility_date\":\"" ++ COMPAT_DATE ++ "\"," ++
        "\"bindings\":[{\"type\":\"ai\",\"name\":\"AI\"},{\"type\":\"durable_object_namespace\",\"name\":\"TOT\",\"class_name\":\"Tot\"}");
    if (x.python) try out.appendSlice(a, ",{\"type\":\"service\",\"name\":\"PY\",\"service\":\"" ++ PY_SCRIPT ++ "\"}");
    if (x.browser) try out.appendSlice(a, ",{\"type\":\"browser\",\"name\":\"BROWSER\"}");
    try out.appendSlice(a, "],\"keep_bindings\":[\"secret_text\"]");
    if (fresh) try out.appendSlice(a, ",\"migrations\":{\"new_tag\":\"" ++ MIGRATION_TAG ++ "\",\"new_sqlite_classes\":[\"Tot\"]}");
    try out.print(a, "}}\r\n--{s}\r\nContent-Disposition: form-data; name=\"" ++ MODULE ++ "\"; filename=\"" ++ MODULE ++ "\"\r\nContent-Type: application/javascript+module\r\n\r\n", .{boundary});
    try out.appendSlice(a, source);
    if (x.neuron) {
        // the names are the ones tot.js imports: "./neuron-db.mjs" and "./neuron_core.wasm"
        try out.print(a, "\r\n--{s}\r\nContent-Disposition: form-data; name=\"neuron-db.mjs\"; filename=\"neuron-db.mjs\"\r\nContent-Type: application/javascript+module\r\n\r\n", .{boundary});
        try out.appendSlice(a, NEURON_MJS);
        try out.print(a, "\r\n--{s}\r\nContent-Disposition: form-data; name=\"neuron_core.wasm\"; filename=\"neuron_core.wasm\"\r\nContent-Type: application/wasm\r\n\r\n", .{boundary});
        try out.appendSlice(a, NEURON_WASM);
    }
    try out.print(a, "\r\n--{s}--\r\n", .{boundary});
    return out.items;
}

/// The Python Worker's upload: its metadata (the python_workers flag is what makes a .py module a Worker) and the
/// module. It has no bindings, no secret and no public address; only the runtime's service binding reaches it.
fn pyUploadBody(a: std.mem.Allocator, boundary: []const u8, native: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\nContent-Type: application/json\r\n\r\n", .{boundary});
    try out.appendSlice(a, "{\"main_module\":\"" ++ PY_MODULE ++ "\",\"compatibility_date\":\"" ++ COMPAT_DATE ++ "\",\"compatibility_flags\":[\"python_workers\"]}");
    try out.print(a, "\r\n--{s}\r\nContent-Disposition: form-data; name=\"" ++ PY_MODULE ++ "\"; filename=\"" ++ PY_MODULE ++ "\"\r\nContent-Type: text/x-python\r\n\r\n", .{boundary});
    try out.appendSlice(a, TOT_PY);
    // A package with native code cannot be fetched by a running script; it is asked for here, by name, as an
    // empty module of the requirement type, and Cloudflare supplies its own build of it.
    for (native) |name| try out.print(a, "\r\n--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: text/x-python-requirement\r\n\r\n", .{ boundary, name, name });
    try out.print(a, "\r\n--{s}--\r\n", .{boundary});
    return out.items;
}

/// The native packages asked for with the Python Worker, most first. An upload Cloudflare refuses, or a Python
/// that then does not start (checkPython), falls to the next set; the last is the plain Python.
const PY_NATIVE = [_][]const []const u8{
    &.{ "numpy", "regex", "pandas", "matplotlib", "pillow" },
    &.{ "numpy", "regex" },
    &.{},
};
const PY_CHECKS = 10;

/// Upload the Python Worker with the first set from `from` on that Cloudflare takes. The set's index, or null
/// with the first refusal in `why`.
fn uploadPython(app: *App, a: std.mem.Allocator, url: []const u8, key: []const u8, boundary: []const u8, ctype: []const u8, from: usize, why: *[]const u8) ?u8 {
    var r: usize = from;
    while (r < PY_NATIVE.len) : (r += 1) {
        const body = pyUploadBody(a, boundary, PY_NATIVE[r]) catch return null;
        const up = api(app, a, "PUT", url, body, key, ctype) orelse {
            if (why.len == 0) why.* = "the Cloudflare API did not answer its upload";
            return null;
        };
        const e = firstError(a, up);
        if (e.len == 0) return @intCast(r);
        if (why.len == 0) why.* = e;
    }
    return null;
}

const Tok = struct { key: []const u8, account_id: []const u8 };

/// Where the uploaded runtime answers: the account's workers.dev address. While the Cloudflare API is a loopback
/// stand-in (NL_CF_API_ROOT, the simulation suite, the tests below) the stand-in plays the account, so it plays
/// the account's workers.dev too: the runtime's address is the stand-in's own origin.
fn runtimeUrl(app: *App, a: std.mem.Allocator, sub: []const u8) ?[]const u8 {
    return workerUrl(app, a, SCRIPT, sub);
}

/// Where a script of this account answers: its workers.dev address, or the stand-in's origin (runtimeUrl).
fn workerUrl(app: *App, a: std.mem.Allocator, script: []const u8, sub: []const u8) ?[]const u8 {
    const root = app.cf_api_root;
    inline for (.{ "http://127.0.0.1:", "http://localhost:" }) |loop| {
        if (std.mem.startsWith(u8, root, loop)) {
            const rest = root[loop.len..];
            const port = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
            return std.fmt.allocPrint(a, "http://127.0.0.1:{s}", .{port}) catch null;
        }
    }
    return std.fmt.allocPrint(a, "https://{s}.{s}.workers.dev", .{ script, sub }) catch null;
}

/// The account's workers.dev subdomain: every script's address hangs off it. Null with the reason in `why`.
fn workersSubdomain(app: *App, a: std.mem.Allocator, tok: Tok, why: *[]const u8) ?[]const u8 {
    const sub_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/subdomain", .{ app.cf_api_root, tok.account_id }) catch {
        why.* = "out of memory";
        return null;
    };
    const sub_raw = api(app, a, "GET", sub_url, "", tok.key, "") orelse {
        why.* = "could not reach the Cloudflare API";
        return null;
    };
    const Sub = struct { result: ?struct { subdomain: []const u8 = "" } = null };
    const sub = blk: {
        const p = std.json.parseFromSliceLeaky(Sub, a, sub_raw, .{ .ignore_unknown_fields = true }) catch break :blk "";
        break :blk if (p.result) |r| r.subdomain else "";
    };
    if (sub.len == 0) {
        const msg = firstError(a, sub_raw);
        why.* = if (msg.len > 0 and std.mem.indexOf(u8, msg, "subdomain") == null) explain(a, "workers.dev address", msg) else "this Cloudflare account has no workers.dev subdomain yet - open Workers & Pages in the Cloudflare dashboard once (it offers one), then deploy again";
        return null;
    }
    for (sub) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) {
        why.* = "the account's workers.dev subdomain is not a name this server can use";
        return null;
    };
    return sub;
}

/// Make sure the account runs THIS binary's tot.js, and that `st` knows its address. Costs no call when the
/// state already names this account and this script. Returns what went wrong in words a user can act on, or
/// null; `uploaded` says whether a script went up just now (its address can take a few seconds to answer).
fn ensureRuntime(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State, uploaded: *bool) ?[]const u8 {
    uploaded.* = false;
    var hb: [16]u8 = undefined;
    const same_account = std.mem.eql(u8, st.account, tok.account_id);
    const source = if (same_account and st.runtime_source.len > 0) st.runtime_source else TOT_JS;
    const want = sourceHash(source, &hb);
    if (st.url.len > 0 and std.mem.eql(u8, st.account, tok.account_id) and std.mem.eql(u8, st.script_hash, want)) return null;
    const root = app.cf_api_root;
    const acct = tok.account_id;
    if (acct.len == 0) return "your Cloudflare login names no account - Disconnect and log in with Cloudflare again";

    // The account's workers.dev subdomain: the runtime's address hangs off it.
    var sub_why: []const u8 = "";
    const sub = workersSubdomain(app, a, tok, &sub_why) orelse return sub_why;

    // Is the script already there? Its class migration applies once, so a second upload must not carry it.
    const script_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ SCRIPT, .{ root, acct }) catch return "out of memory";
    const settings_url = std.fmt.allocPrint(a, "{s}/settings", .{script_url}) catch return "out of memory";
    const exists = if (api(app, a, "GET", settings_url, "", tok.key, "")) |r| firstError(a, r).len == 0 else false;

    var bb: [8]u8 = undefined;
    app.io.random(&bb);
    const boundary = std.fmt.allocPrint(a, "----veiltot{s}", .{std.fmt.bytesToHex(bb, .lower)}) catch return "out of memory";
    const ctype = std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary}) catch return "out of memory";
    // The Python Worker first: the runtime binds to it by name, so it has to exist. An account that does not take
    // it (or the browser, below) still gets a tot - without that family of tools, and told why.
    var note: []const u8 = "";
    const py_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ PY_SCRIPT, .{ root, acct }) catch return "out of memory";
    var py_why: []const u8 = "";
    const py_rung = uploadPython(app, a, py_url, tok.key, boundary, ctype, 0, &py_why);
    const python = py_rung != null;
    if (!python) note = std.fmt.allocPrint(a, "Python is off: {s}", .{py_why}) catch "Python is off";

    // The runtime, asking for everything first. The settings read above is only a hint (a login may lack its
    // scope), so each set of bindings is tried with and without the class migration; the first upload Cloudflare
    // takes wins, and the first refusal of all is the one reported when none does.
    const wants = [_]Extras{
        .{ .python = python, .browser = true, .neuron = true },
        .{ .python = python, .browser = false, .neuron = true },
        .{ .python = python, .browser = false, .neuron = false },
        .{ .python = false, .browser = false, .neuron = false },
    };
    var up_err: []const u8 = "";
    var got: ?Extras = null;
    ladder: for (wants, 0..) |x, wi| {
        if (wi == 3 and !python) break; // the same upload as the one before it
        var refusal: []const u8 = "";
        for ([_]bool{ !exists, exists }) |fresh| {
            const body = uploadSourceBody(a, boundary, fresh, x, source) catch return "out of memory";
            const up = api(app, a, "PUT", script_url, body, tok.key, ctype) orelse return "could not reach the Cloudflare API to upload the tot runtime";
            const e = firstError(a, up);
            if (e.len == 0) {
                got = x;
                break :ladder;
            }
            if (refusal.len == 0) refusal = e;
        }
        if (up_err.len == 0) up_err = refusal;
        // what the NEXT upload goes without is what this refusal is put down to
        const dropped: []const u8 = if (wi == 0) "the browser" else if (wi == 1) "neuron-db" else "Python";
        if (note.len < 300) note = std.fmt.allocPrint(a, "{s}{s}{s} is off: {s}", .{ note, if (note.len > 0) "; " else "", dropped, refusal }) catch note;
    }
    const have = got orelse return explain(a, "uploading the tot runtime", up_err);
    st.python = have.python;
    st.py_rung = py_rung orelse 0;
    st.py_check = if (have.python and st.py_rung + 1 < PY_NATIVE.len) PY_CHECKS else 0;
    st.py_fails = 0;
    st.py_native = &.{};
    st.browser = have.browser;
    st.neuron = have.neuron;
    st.tools_note = if (have.python and have.browser and have.neuron) "" else note;

    // Its token, as a secret binding. A small JSON body: it rides curl's stdin with the bearer, never a file.
    var tb: [64]u8 = undefined;
    const token = totToken(app, uid, acct, st.token_gen, &tb);
    const secret_url = std.fmt.allocPrint(a, "{s}/secrets", .{script_url}) catch return "out of memory";
    const secret_body = std.fmt.allocPrint(a, "{{\"name\":\"TOT_TOKEN\",\"text\":\"{s}\",\"type\":\"secret_text\"}}", .{token}) catch return "out of memory";
    const sec = api(app, a, "PUT", secret_url, secret_body, tok.key, "application/json") orelse return "could not reach the Cloudflare API to set the tot runtime's token";
    const sec_err = firstError(a, sec);
    if (sec_err.len > 0) return explain(a, "setting the tot runtime's token", sec_err);

    // An accepted upload is not reachable until its workers.dev route is enabled.
    const route_url = std.fmt.allocPrint(a, "{s}/subdomain", .{script_url}) catch return "out of memory";
    const route = api(app, a, "POST", route_url, "{\"enabled\":true}", tok.key, "application/json") orelse
        return "could not reach Cloudflare to enable the tot runtime's workers.dev address";
    const route_err = firstError(a, route);
    if (route_err.len > 0) return explain(a, "enabling the tot runtime's address", route_err);

    if (!same_account) {
        st.runtime_source = "";
        st.runtime_revision = 0;
    }
    st.account = acct;
    st.url = runtimeUrl(app, a, sub) orelse return "out of memory";
    st.script_hash = a.dupe(u8, want) catch return "out of memory";
    st.deployed_at = nowS(app.io);
    st.last_error = "";
    // An Agent Garrett already in this account: the new runtime is pointed at it (its two secrets). Best effort:
    // the runtime is up either way, and a tot that asks for the agent is told in its words when it is not there.
    if (st.garrett_url.len > 0 and std.mem.eql(u8, garrettAccount(st.*), acct)) {
        if (pointTotsAtGarrett(app, a, uid, tok, st.*)) |m| log.warn("the new tot runtime could not be pointed at Agent Garrett for u{d}: {s}", .{ uid, m });
    }
    uploaded.* = true;
    log.info("tot runtime uploaded for u{d}: {s} ({s})", .{ uid, st.url, want });
    return null;
}

// ---------------------------------------------------------------------------------- the runtime (relay)

const Reply = struct { ok: bool = false, err: []const u8 = "" };

/// One call to the runtime; the reply lives in `a`. null: no address, an address this server will not send the
/// token to, or no answer.
fn totCall(app: *App, a: std.mem.Allocator, uid: u64, st: State, method: []const u8, path: []const u8, body: []const u8) ?[]u8 {
    if (!allowedUrl(app, st.url)) return null;
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ st.url, path }) catch return null;
    var tb: [64]u8 = undefined;
    const token = totToken(app, uid, st.account, st.token_gen, &tb);
    return api(app, a, method, url, body, token, if (body.len > 0) "application/json" else "");
}

/// Whether the runtime said yes, and its words when it did not ("" for a reply that is not its JSON at all).
fn replyOf(a: std.mem.Allocator, raw: []const u8) Reply {
    return std.json.parseFromSliceLeaky(Reply, a, raw, .{ .ignore_unknown_fields = true }) catch .{};
}

/// Preserve a useful provider error without putting an HTML error page in the desktop.
fn runtimeFailure(raw: ?[]const u8) []const u8 {
    const body = raw orelse return "the tot runtime could not be reached; check the network connection and try again";
    if (std.mem.indexOf(u8, body, "1042") != null)
        return "Cloudflare returned error 1042 for the tot runtime; check its workers.dev route and Worker fetch configuration in Workers & Pages";
    if (std.mem.indexOf(u8, body, "1101") != null)
        return "the tot Worker failed with Cloudflare error 1101; inspect its runtime logs in Workers & Pages";
    if (std.mem.indexOf(u8, body, "1027") != null)
        return "the tot runtime reached the Cloudflare account's daily request limit (1027)";
    return "the tot runtime did not return a valid reply after reconnecting; check its deployment and logs in Workers & Pages";
}

/// Probe with GET before creating anything. A cached address can outlive its route, token or script.
/// Repair setup once, preserving the saved runtime source and every Durable Object, then wait for readiness.
fn readyRuntime(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State, uploaded: bool) ?[]const u8 {
    var repaired = uploaded;
    var attempt: usize = 0;
    var last: ?[]const u8 = null;
    while (attempt < 9) : (attempt += 1) {
        last = totCall(app, a, uid, st.*, "GET", "/v1/tots", "");
        if (last) |raw| {
            const rep = replyOf(a, raw);
            if (rep.ok) return null;
            if (rep.err.len > 0 and !std.mem.eql(u8, rep.err, "unauthorized")) return rep.err;
        }
        if (!repaired) {
            st.script_hash = ""; // only invalidate the cache; never delete the script or its storage
            var did_upload = false;
            if (ensureRuntime(app, a, uid, tok, st, &did_upload)) |msg| return msg;
            writeState(app, uid, st.*);
            repaired = true;
        }
        if (!builtin.is_test and attempt < 8) bu.sleepMs(2500);
    }
    return runtimeFailure(last);
}

/// Hand the runtime's answer to the client: its JSON as it is when it said ok, its own error otherwise.
fn relay(res: *httpz.Response, a: std.mem.Allocator, raw: ?[]u8) !void {
    const body = raw orelse return http.serverErr(res, "the tot runtime did not answer - is it deployed, and is this machine online?");
    const r = replyOf(a, body);
    if (!r.ok) return badReq(res, if (r.err.len > 0) r.err else "the tot runtime gave an unreadable answer (a new deployment can take a minute to come up)");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, body);
}

/// requireUser + admin, replying 403 like the scheduled tasks: a tot allowed onto the owner's machine fires
/// full-tool chat turns there, and a tot of any kind spends the account's Workers AI.
fn gate(app: *App, req: *httpz.Request, res: *httpz.Response) ?http.User {
    const u = http.requireUser(app, req, res) orelse return null;
    if (!app.auth.isAdmin(u)) {
        res.status = 403;
        res.json(.{ .ok = false, .err = "tots are admin-only for now" }, .{}) catch {};
        return null;
    }
    return u;
}

fn tokOf(app: *App, uid: u64, a: std.mem.Allocator) ?Tok {
    const t = cf_oauth.resolveToken(app, uid, a) orelse return null;
    return .{ .key = t.key, .account_id = t.account_id };
}

// ---------------------------------------------------------------------------------- HTTP handlers

/// GET /api/v1/tots — the roster as the runtime reports it, plus what this server knows: connected, deployed,
/// the address, which tots may use this machine, and the last deployment error.
pub fn listTots(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var connected = false;
    if (app.vault.resolveOAuth(u.id, cf_oauth.CF_PROVIDER, a)) |b| connected = b.refresh_token.len > 0;
    const st = readState(app, u.id, a);
    var hb: [16]u8 = undefined;
    const deployed = st.url.len > 0;
    var tots: []const u8 = "[]";
    var reachable = false;
    if (deployed) {
        if (totCall(app, a, u.id, st, "GET", "/v1/tots", "")) |raw| {
            const R = struct { ok: bool = false, tots: std.json.Value = .null };
            if (std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true })) |r| {
                if (r.ok and r.tots == .array) {
                    reachable = true;
                    // each tot's local folder, relative to the data dir (the desk's Open folder)
                    for (r.tots.array.items) |*v| {
                        if (v.* != .object) continue;
                        const h = std.json.parseFromValueLeaky(RosterTot, a, v.*, .{ .ignore_unknown_fields = true }) catch continue;
                        var fb: [160]u8 = undefined;
                        const rel = totFolder(&fb, u.id, h.name, h.created) orelse continue;
                        v.object.put(a, "folder", .{ .string = a.dupe(u8, rel) catch continue }) catch {};
                    }
                    tots = std.json.Stringify.valueAlloc(a, r.tots, .{}) catch "[]";
                }
            } else |_| {}
        }
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    try out.print(app.gpa, "{{\"ok\":true,\"connected\":{},\"deployed\":{},\"reachable\":{},\"current\":{},\"max\":{d},\"primary\":\"" ++ PRIMARY ++ "\",\"url\":", .{ connected, deployed, reachable, std.mem.eql(u8, st.script_hash, sourceHash(if (st.runtime_source.len > 0) st.runtime_source else TOT_JS, &hb)), limitOf(st) });
    try http.jstr(app.gpa, &out, st.url);
    try out.appendSlice(app.gpa, ",\"local\":[");
    for (st.local, 0..) |n, i| {
        if (i > 0) try out.append(app.gpa, ',');
        try http.jstr(app.gpa, &out, n);
    }
    try out.print(app.gpa, "],\"python\":{},\"browser\":{},\"neuron\":{},\"garrett\":{},\"garrett_url\":", .{ st.python, st.browser, st.neuron, st.garrett_url.len > 0 });
    try http.jstr(app.gpa, &out, st.garrett_url);
    try out.appendSlice(app.gpa, ",\"tools_note\":");
    try http.jstr(app.gpa, &out, st.tools_note);
    try out.appendSlice(app.gpa, ",\"last_error\":");
    if (readLegacy(app, u.id, a)) |old| {
        const why = if (old.last_error.len > 0) old.last_error else "it happens in the background within a minute or two";
        try http.jstr(app.gpa, &out, try std.fmt.allocPrint(a, "hots are called tots now; yours are being moved across: {s}", .{why}));
    } else try http.jstr(app.gpa, &out, st.last_error);
    try out.print(app.gpa, ",\"moving\":{}", .{readLegacy(app, u.id, a) != null});
    try out.appendSlice(app.gpa, ",\"tots\":");
    try out.appendSlice(app.gpa, tots);
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
    posture: ?[]const u8 = null, // "defend" deploys it as a defender (the runtime's DEFEND posture)
    leash_s: ?i64 = null,
    garrett: bool = false, // Agent Garrett's tools on its belt: the account's deployment must exist (Settings); the runtime keeps it as a setting
};

/// POST /api/v1/tots — deploy a tot. Uploads the runtime first when the account lacks it or runs an older one.
pub fn createTot(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(CreateReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
    // Hots from before the rename go across first, so a new tot never lands beside an old Worker still running.
    if (readLegacy(app, u.id, a)) |old| if (old.account.len == 0 or std.mem.eql(u8, old.account, tok.account_id)) {
        if (moveFromHots(app, a, u.id, tok)) |msg|
            return badReq(res, try std.fmt.allocPrint(res.arena, "your hots are being moved to tots and that is not finished: {s}. Try again in a minute", .{msg}));
    };
    switch (deploy(app, a, u.id, tok, body)) {
        .ok => |raw| {
            res.status = 201;
            res.content_type = .JSON;
            res.body = try res.arena.dupe(u8, raw);
        },
        .err => |msg| {
            const leaf = recordFailed(app, a, u.id, body, msg) orelse "";
            res.status = 400;
            return res.json(.{ .ok = false, .err = msg, .run = leaf }, .{});
        },
    }
}

const Deployed = union(enum) { ok: []const u8, err: []const u8 };

/// What goes to the runtime: the request as the user made it, plus the text limit of its model (the runtime clips
/// a later `/goal` or `/charter` to it).
const Sent = struct { req: CreateReq, text_max: usize, max_tots: u32 = DEFAULT_MAX_TOTS };

fn sentJson(a: std.mem.Allocator, s: Sent) ?[]const u8 {
    const body = std.json.Stringify.valueAlloc(a, s.req, .{ .emit_null_optional_fields = false }) catch return null;
    // the request is an object: add the limit as its last field
    return std.fmt.allocPrint(a, "{s},\"text_max\":{d},\"max_tots\":{d}}}", .{ body[0 .. body.len - 1], s.text_max, s.max_tots }) catch null;
}

/// createTot without the request: validate, make sure the runtime is up, create the tot, record a local grant.
fn deploy(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, body: CreateReq) Deployed {
    const name = std.mem.trim(u8, body.name, " \r\n\t");
    if (name.len > 0 and !validName(name)) return .{ .err = "a tot's name is 1-24 letters, digits, - or _, starting with a letter" };
    if (body.posture) |p| if (!(std.mem.eql(u8, p, "normal") or std.mem.eql(u8, p, "defend"))) return .{ .err = "posture is normal or defend" };
    if (std.mem.trim(u8, body.goal, " \r\n\t").len < 3 and std.mem.trim(u8, body.charter, " \r\n\t").len < 3)
        return .{ .err = "a tot needs a goal or a charter to work toward" };
    const model = if (body.model.len > 0) body.model else modelcfg.defaults.cf_model;
    if (model[0] != '@') return .{ .err = "a tot runs on the account's Workers AI: pick an @cf/ model" };
    const limit = modelcfg.goalCharLimit(model);
    if (body.goal.len > limit or body.charter.len > limit)
        return .{ .err = std.fmt.allocPrint(a, "on {s} a goal or a charter holds at most {d} characters - shorten it, or pick a model with a bigger window", .{ model, limit }) catch "goal too long for this model" };

    var st = readState(app, uid, a);
    if (body.garrett and st.garrett_url.len == 0) return .{ .err = "Agent Garrett is not deployed in this account - Settings > Deploy Agent Garrett first (or untick 'use Agent Garrett')" };
    var uploaded = false;
    if (ensureRuntime(app, a, uid, tok, &st, &uploaded)) |msg| {
        st.last_error = msg;
        writeState(app, uid, st);
        return .{ .err = msg };
    }
    if (uploaded) writeState(app, uid, st);
    if (readyRuntime(app, a, uid, tok, &st, uploaded)) |msg| {
        st.last_error = msg;
        writeState(app, uid, st);
        return .{ .err = msg };
    }

    var send: Sent = .{ .req = body, .text_max = limit, .max_tots = limitOf(st) };
    send.req.name = name;
    send.req.model = model;
    const json = sentJson(a, send) orelse return .{ .err = "out of memory" };
    // POST once: retrying an unnamed create after a lost reply can create duplicate tots.
    const raw = totCall(app, a, uid, st, "POST", "/v1/tots", json) orelse
        return .{ .err = "the create reply was lost; refresh the live tots before deploying again" };
    const rep = replyOf(a, raw);
    if (!rep.ok) return .{ .err = if (rep.err.len > 0) rep.err else runtimeFailure(raw) };
    st.last_error = "";
    writeState(app, uid, st);
    if (body.local) {
        const Made = struct { tot: struct { name: []const u8 = "" } = .{} };
        const made = std.json.parseFromSliceLeaky(Made, a, raw, .{ .ignore_unknown_fields = true }) catch Made{};
        if (validName(made.tot.name)) {
            st = readState(app, uid, a);
            st.local = withName(a, st.local, made.tot.name);
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
        badReq(res, "bad tot name") catch {};
        return null;
    }
    return name;
}

/// DELETE /api/v1/tots/:name — delete one tot: its storage and its alarm go with it, and so does its grant here.
pub fn deleteTot(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const name = nameParam(req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = readState(app, u.id, a);
    const path = try std.fmt.allocPrint(a, "/v1/tots/{s}", .{name});
    // Its run folder first: the events since the last mirror pass would go with it otherwise.
    var run_rel: ?[]const u8 = null;
    if (totCall(app, a, u.id, st, "GET", path, "")) |sraw| {
        const S = struct { ok: bool = false, tot: std.json.Value = .null };
        const s = std.json.parseFromSliceLeaky(S, a, sraw, .{ .ignore_unknown_fields = true }) catch S{};
        if (s.ok and s.tot == .object) {
            if (std.json.parseFromValueLeaky(RosterTot, a, s.tot, .{ .ignore_unknown_fields = true })) |h| {
                mirrorTot(app, a, u.id, st, h, s.tot);
                var fb: [160]u8 = undefined;
                if (totFolder(&fb, u.id, h.name, h.created)) |rel| run_rel = try a.dupe(u8, rel);
            } else |_| {}
        }
    }
    const raw = totCall(app, a, u.id, st, "DELETE", path, "");
    const r = raw orelse return relay(res, a, raw);
    if (!replyOf(a, r).ok) return relay(res, a, raw);
    if (run_rel) |rel| markEnded(app, a, rel, "deleted");
    st.local = withoutName(a, st.local, name);
    writeState(app, u.id, st);
    // The Worker exists for its tots: when the last one goes, so does the Worker, and the account is left as it was.
    // While others remain it stays, because they live in it.
    var left: usize = 1;
    if (totCall(app, a, u.id, st, "GET", "/v1/tots", "")) |list| {
        const L = struct { ok: bool = false, tots: []const std.json.Value = &.{} };
        if (std.json.parseFromSliceLeaky(L, a, list, .{ .ignore_unknown_fields = true })) |l| {
            if (l.ok) left = l.tots.len;
        } else |_| {}
    }
    if (left > 0) return res.json(.{ .ok = true, .deleted = name, .worker_removed = false, .tots_left = left }, .{});
    const tok = tokOf(app, u.id, a) orelse
        return res.json(.{ .ok = true, .deleted = name, .worker_removed = false, .note = "that was the last tot; log in with Cloudflare again and run teardown to remove the Worker" }, .{});
    if (removeScript(app, a, u.id, tok, &st)) |msg|
        return res.json(.{ .ok = true, .deleted = name, .worker_removed = false, .note = msg }, .{});
    try res.json(.{ .ok = true, .deleted = name, .worker_removed = true, .tots_left = 0 }, .{});
}

/// Delete the Worker script (and with it every tot's storage) and start a new token generation. Null on success,
/// Cloudflare's own words otherwise. A script that is already gone counts as removed.
fn removeScript(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State) ?[]const u8 {
    const acct = if (st.account.len > 0) st.account else tok.account_id;
    const url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ SCRIPT ++ "?force=true", .{ app.cf_api_root, acct }) catch return "out of memory";
    const raw = api(app, a, "DELETE", url, "", tok.key, "") orelse return "could not reach the Cloudflare API to remove the Worker";
    const msg = firstError(a, raw);
    if (msg.len > 0 and std.ascii.indexOfIgnoreCase(msg, "not found") == null and std.ascii.indexOfIgnoreCase(msg, "does not exist") == null)
        return explain(a, "removing the tot runtime", msg);
    // Its Python Worker goes after it (the runtime was bound to it). Best effort: it holds nothing.
    const py_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ PY_SCRIPT ++ "?force=true", .{ app.cf_api_root, acct }) catch return "out of memory";
    _ = api(app, a, "DELETE", py_url, "", tok.key, "");
    // A new generation: a later deployment gets a token the removed script never held. Agent Garrett is the
    // account's, not the tots' (Settings deploys it on its own; DELETE /api/v1/tots/garrett removes it): it stays,
    // with the account and generation its secrets were derived under pinned, so the bump cannot move them.
    // (built in a local first: a literal assigned straight into `st.*` may write its defaults before every field
    // on its right-hand side has been read from the old value - Zig's result-location aliasing)
    const keep_garrett = st.garrett_url.len > 0;
    const next: State = .{
        .token_gen = st.token_gen +% 1,
        .garrett_url = st.garrett_url,
        .garrett_hash = st.garrett_hash,
        .garrett_at = st.garrett_at,
        .garrett_account = if (keep_garrett) garrettAccount(st.*) else "",
        .garrett_gen = if (keep_garrett) garrettGen(st.*) else 0,
    };
    st.* = next;
    writeState(app, uid, st.*);
    log.info("tot runtime removed from the Cloudflare account of u{d}", .{uid});
    return null;
}

/// DELETE /api/v1/tots — take the runtime out of the account: the script, every tot and everything they stored.
pub fn teardown(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
    var st = readState(app, u.id, a);
    if (removeScript(app, a, u.id, tok, &st)) |msg| return badReq(res, msg);
    // and a deployment from before the rename, if one was never moved
    if (readLegacy(app, u.id, a)) |old| if (old.account.len == 0 or std.mem.eql(u8, old.account, tok.account_id)) {
        for ([_][]const u8{ LEGACY_SCRIPT, LEGACY_PY_SCRIPT }) |script| {
            const url = try std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/{s}?force=true", .{ app.cf_api_root, if (old.account.len > 0) old.account else tok.account_id, script });
            _ = api(app, a, "DELETE", url, "", tok.key, "");
        }
        var pb: [700]u8 = undefined;
        if (legacyPath(app, u.id, &pb)) |p| std.Io.Dir.cwd().deleteFile(app.io, p) catch {};
    };
    try res.json(.{ .ok = true, .removed = true }, .{});
}

/// GET /api/v1/tots/:name/events?after=N — the tot's event tail, as the runtime serves it.
pub fn totEvents(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const name = nameParam(req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const q = try req.query();
    const after = std.fmt.parseInt(u64, q.get("after") orelse "0", 10) catch 0;
    const path = try std.fmt.allocPrint(a, "/v1/tots/{s}/events?after={d}&limit=200", .{ name, after });
    try relay(res, a, totCall(app, a, u.id, readState(app, u.id, a), "GET", path, ""));
}

const TextReq = struct { text: []const u8 = "" };

fn textBody(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    return std.json.Stringify.valueAlloc(a, TextReq{ .text = text }, .{}) catch null;
}

/// POST /api/v1/tots/:name/command {text} — "/goal ...", "/pause", "/queue ...", or plain words for its inbox.
pub fn totCommand(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const name = nameParam(req, res) orelse return;
    const body = (req.json(TextReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (std.mem.trim(u8, body.text, " \r\n\t").len == 0) return badReq(res, "empty command");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "/v1/tots/{s}/command", .{name});
    const json = textBody(a, body.text) orelse return http.serverErr(res, "out of memory");
    try relay(res, a, totCall(app, a, u.id, readState(app, u.id, a), "POST", path, json));
}

const ConfigReq = struct {
    model: ?[]const u8 = null,
    pace_s: ?i64 = null,
    size: ?i64 = null,
    daily_calls: ?i64 = null,
    charter: ?[]const u8 = null,
    paused: ?bool = null,
    posture: ?[]const u8 = null, // "normal" | "defend"
    leash_s: ?i64 = null, // 0 = no leash; else 60 .. 604800, the runtime's floor and ceiling
    garrett: ?bool = null, // Agent Garrett's tools on its belt (the account's deployment must exist for them to answer)
};

/// POST /api/v1/tots/:name/config — change a tot's settings. There is no `local` here: the owner's machine is
/// granted at deployment or not at all.
pub fn totConfig(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const name = nameParam(req, res) orelse return;
    const body = (req.json(ConfigReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (body.model) |m| if (m.len == 0 or m[0] != '@') return badReq(res, "a tot runs on the account's Workers AI: pick an @cf/ model");
    if (body.posture) |p| if (!(std.mem.eql(u8, p, "normal") or std.mem.eql(u8, p, "defend"))) return badReq(res, "posture is normal or defend");
    if (body.leash_s) |s| if (s < 0) return badReq(res, "the leash is a number of seconds, or 0 for none");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (body.garrett == true and readState(app, u.id, a).garrett_url.len == 0) return badReq(res, "Agent Garrett is not deployed in this account - Settings > Deploy Agent Garrett first");
    const path = try std.fmt.allocPrint(a, "/v1/tots/{s}/config", .{name});
    var json = std.json.Stringify.valueAlloc(a, body, .{ .emit_null_optional_fields = false }) catch return http.serverErr(res, "out of memory");
    // a new model brings its own text limit
    if (body.model) |m| json = std.fmt.allocPrint(a, "{s}{s}\"text_max\":{d}}}", .{ json[0 .. json.len - 1], if (json.len > 2) "," else "", modelcfg.goalCharLimit(m) }) catch json;
    try relay(res, a, totCall(app, a, u.id, readState(app, u.id, a), "POST", path, json));
}

/// GET /api/v1/tots/pad?after=N — the scratchpad the account's tots share.
pub fn padRead(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const q = try req.query();
    const after = std.fmt.parseInt(u64, q.get("after") orelse "0", 10) catch 0;
    const path = try std.fmt.allocPrint(a, "/v1/pad?after={d}", .{after});
    try relay(res, a, totCall(app, a, u.id, readState(app, u.id, a), "GET", path, ""));
}

/// POST /api/v1/tots/pad {text} — the human writes to the shared scratchpad.
pub fn padWrite(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(TextReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (std.mem.trim(u8, body.text, " \r\n\t").len == 0) return badReq(res, "empty scratchpad entry");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = textBody(a, body.text) orelse return http.serverErr(res, "out of memory");
    try relay(res, a, totCall(app, a, u.id, readState(app, u.id, a), "POST", "/v1/pad", json));
}

/// POST /api/v1/tots/pad/clear — empty the shared scratchpad, for the next set of tots. The local mirror of it is
/// kept first, renamed with the time it was cleared, so nothing the tots wrote is lost.
pub fn padClear(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = totCall(app, a, u.id, readState(app, u.id, a), "POST", "/v1/pad/clear", "{}");
    if (raw) |r| if (replyOf(a, r).ok) archivePad(app, a, u.id);
    try relay(res, a, raw);
}

/// _tots/scratchpad.md -> _tots/scratchpad-<YYYYMMDD-HHMMSS>.md (UTC), when there is one.
fn archivePad(app: *App, a: std.mem.Allocator, uid: u64) void {
    const dir = std.fmt.allocPrint(a, "{s}/u{d}/_tots", .{ app.data, uid }) catch return;
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

const KeyReq = struct { name: []const u8 = "", value: []const u8 = "" };

/// The keys a tot reads as secrets of its Worker: the name a human types, and the binding the runtime reads. The
/// search keys (web_search asks them before the keyless sources), the guard's webhook, and an Agent Garrett the
/// owner deployed by hand (launchGarrett sets the same two itself).
fn keySecret(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "brave")) return "BRAVE_KEY";
    if (std.ascii.eqlIgnoreCase(name, "google")) return "GOOGLE_CSE_KEY";
    if (std.ascii.eqlIgnoreCase(name, "google_cx") or std.ascii.eqlIgnoreCase(name, "google-cx")) return "GOOGLE_CSE_CX";
    if (std.ascii.eqlIgnoreCase(name, "alert")) return "ALERT_URL";
    if (std.ascii.eqlIgnoreCase(name, "garrett_url") or std.ascii.eqlIgnoreCase(name, "garrett-url")) return "GARRETT_MCP_URL";
    if (std.ascii.eqlIgnoreCase(name, "garrett_token") or std.ascii.eqlIgnoreCase(name, "garrett-token")) return "GARRETT_MCP_TOKEN";
    return null;
}

/// The keys that are addresses: the runtime only calls them over https.
fn keyIsUrl(secret: []const u8) bool {
    return std.mem.eql(u8, secret, "ALERT_URL") or std.mem.eql(u8, secret, "GARRETT_MCP_URL");
}

const LimitReq = struct { max: i64 = 0 };

/// POST /api/v1/tots/limit {max} — how many tots this account may run, 1 to MAX_TOTS_CEIL. Kept here and sent with
/// every deployment, so the runtime enforces the number the owner chose. Lowering it below the count stops new
/// deployments; it deletes nothing.
pub fn setLimit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(LimitReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    if (body.max < 1 or body.max > MAX_TOTS_CEIL) return badReq(res, "the limit is 1 to 1000 tater-tots");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = readState(app, u.id, a);
    st.max_tots = @intCast(body.max);
    writeState(app, u.id, st);
    try res.json(.{ .ok = true, .max = st.max_tots }, .{});
}

/// POST /api/v1/tots/keys {name, value} — set (or, with an empty value, remove) a search key on the runtime. The
/// key becomes a secret binding of the Worker: it rides curl's stdin on its way there and is never written here.
pub fn setKey(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const body = (req.json(KeyReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    const secret = keySecret(body.name) orelse return badReq(res, "a key is one of: brave, google, google_cx, alert, garrett_url, garrett_token");
    const value = std.mem.trim(u8, body.value, " \r\n\t");
    if (value.len > 400) return badReq(res, "that is too long to be a key");
    for (value) |c| if (c < 0x20 or c == 0x7F) return badReq(res, "a key cannot hold control characters");
    if (value.len > 0 and keyIsUrl(secret) and !std.mem.startsWith(u8, value, "https://")) return badReq(res, "that key is an address: give an https:// URL");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
    const st = readState(app, u.id, a);
    if (st.url.len == 0) return badReq(res, "deploy a tot first: the key is kept on the tots' Worker");
    const base = try std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ SCRIPT ++ "/secrets", .{ app.cf_api_root, st.account });
    const raw = if (value.len == 0)
        api(app, a, "DELETE", try std.fmt.allocPrint(a, "{s}/{s}", .{ base, secret }), "", tok.key, "")
    else
        api(app, a, "PUT", base, std.json.Stringify.valueAlloc(a, .{ .name = secret, .text = value, .type = "secret_text" }, .{}) catch return http.serverErr(res, "out of memory"), tok.key, "application/json");
    const msg = firstError(a, raw orelse return http.serverErr(res, "could not reach the Cloudflare API"));
    if (msg.len > 0 and !(value.len == 0 and std.ascii.indexOfIgnoreCase(msg, "not found") != null)) return badReq(res, explain(a, "setting the key", msg));
    try res.json(.{ .ok = true, .name = body.name, .set = value.len > 0 }, .{});
}

// ---------------------------------------------------------------------------------- Agent Garrett

/// When the last launch was refused: a refused launch is not tried again for a quarter of an hour.
var garrett_failed_s: std.atomic.Value(i64) = .init(0);

/// The port of a loopback stand-in the Cloudflare API is pointed at (NL_CF_API_ROOT, the tests), or null for the
/// real API. While there is one, it plays the agent's repo too.
fn loopbackPort(app: *App) ?[]const u8 {
    const root = app.cf_api_root;
    inline for (.{ "http://127.0.0.1:", "http://localhost:" }) |loop| {
        if (std.mem.startsWith(u8, root, loop)) {
            const rest = root[loop.len..];
            return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        }
    }
    return null;
}

/// Where one file of Agent Garrett's folder is read from (`rel`: "wrangler.toml", "src/index.js"): the repo, or -
/// while the Cloudflare API is a loopback stand-in - the stand-in, under /garrett/ (the tests serve it there).
fn garrettUrl(app: *App, a: std.mem.Allocator, rel: []const u8) ?[]const u8 {
    if (loopbackPort(app)) |port| return std.fmt.allocPrint(a, "http://127.0.0.1:{s}/garrett/{s}", .{ port, rel }) catch null;
    return std.fmt.allocPrint(a, GARRETT_RAW ++ "{s}", .{rel}) catch null;
}

/// The listing of one directory of the agent's folder: GitHub's contents API, or the stand-in's /garrett/contents/.
fn garrettListUrl(app: *App, a: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    if (loopbackPort(app)) |port| return std.fmt.allocPrint(a, "http://127.0.0.1:{s}/garrett/contents/{s}", .{ port, dir }) catch null;
    return std.fmt.allocPrint(a, GARRETT_LIST ++ "{s}?ref=main", .{dir}) catch null;
}

/// One read from the repo (or the stand-in): no bearer, a module-sized answer, the veil named as the client (GitHub
/// wants a user agent). The reply is copied into `a`; null when nothing came back or it was past GARRETT_FILE_MAX.
fn garrettFetch(app: *App, a: std.mem.Allocator, url: []const u8) ?[]u8 {
    const raw = cf_oauth.curl(.{ .gpa = app.gpa, .io = app.io, .scratch = app.data, .body_prefix = ".cfgarrett-body-", .max_time_s = 60, .stdout_limit = GARRETT_FILE_MAX + 1, .extra = &.{ "-A", GARRETT_UA, "-H", "Accept: application/vnd.github+json" } }, "GET", url, "", "", "") orelse return null;
    defer app.gpa.free(raw);
    if (raw.len > GARRETT_FILE_MAX) return null;
    return a.dupe(u8, raw) catch null;
}

/// One module of the upload: its name (the path under the main module's directory, as the Worker imports it), its
/// bytes, and the Content-Type that tells Cloudflare what it is.
const GarrettModule = struct { name: []const u8, data: []const u8, ctype: []const u8 };

const GarrettCfg = struct {
    main: []const u8 = "src/index.js",
    compat_date: []const u8 = GARRETT_COMPAT_DATE,
    flags: []const []const u8 = &.{},
    ai: []const u8 = "", // the AI binding's name; "" = none
    vars: []const Var = &.{},
    dos: []const Do = &.{},
    tag: []const u8 = GARRETT_MIGRATION_TAG, // the last migration's tag
    sqlite_classes: []const []const u8 = &.{},
    classes: []const []const u8 = &.{},

    const Var = struct { name: []const u8, text: []const u8 };
    const Do = struct { name: []const u8 = "", class: []const u8 = "" };

    /// The directory of the main module, which every module's name is relative to ("src" for "src/index.js").
    fn mainDir(c: GarrettCfg) []const u8 {
        const i = std.mem.lastIndexOfScalar(u8, c.main, '/') orelse return "";
        return c.main[0..i];
    }
    /// The main module as Cloudflare names it: relative to that directory ("index.js").
    fn mainModule(c: GarrettCfg) []const u8 {
        const i = std.mem.lastIndexOfScalar(u8, c.main, '/') orelse return c.main;
        return c.main[i + 1 ..];
    }
};

/// A TOML scalar as this file uses them: a quoted string's inside, else the bare value up to a comment.
fn tomlStr(v: []const u8) []const u8 {
    const t = std.mem.trim(u8, v, " \t");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'')) {
        if (std.mem.indexOfScalarPos(u8, t, 1, t[0])) |end| return t[1..end];
    }
    return std.mem.trim(u8, std.mem.sliceTo(t, '#'), " \t");
}

/// A TOML array of strings on one line (`["a", "b"]`), appended to `out`.
fn tomlList(a: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), v: []const u8) void {
    const open = std.mem.indexOfScalar(u8, v, '[') orelse return;
    const close = std.mem.lastIndexOfScalar(u8, v, ']') orelse return;
    if (close <= open) return;
    var it = std.mem.splitScalar(u8, v[open + 1 .. close], ',');
    while (it.next()) |p| {
        const s = tomlStr(p);
        if (s.len > 0) out.append(a, s) catch {};
    }
}

/// wrangler.toml -> GarrettCfg. Every slice points into `src` or lives in `a`.
fn parseGarrettToml(a: std.mem.Allocator, src: []const u8) GarrettCfg {
    var cfg: GarrettCfg = .{};
    var flags: std.ArrayListUnmanaged([]const u8) = .empty;
    var vars: std.ArrayListUnmanaged(GarrettCfg.Var) = .empty;
    var dos: std.ArrayListUnmanaged(GarrettCfg.Do) = .empty;
    var sqlite: std.ArrayListUnmanaged([]const u8) = .empty;
    var classes: std.ArrayListUnmanaged([]const u8) = .empty;
    var table: []const u8 = "";
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            table = std.mem.trim(u8, line, "[] \t");
            if (std.mem.eql(u8, table, "durable_objects.bindings")) dos.append(a, .{}) catch {};
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = line[eq + 1 ..];
        if (table.len == 0) {
            if (std.mem.eql(u8, key, "main")) cfg.main = tomlStr(val) else if (std.mem.eql(u8, key, "compatibility_date")) cfg.compat_date = tomlStr(val) else if (std.mem.eql(u8, key, "compatibility_flags")) tomlList(a, &flags, val);
        } else if (std.mem.eql(u8, table, "ai")) {
            if (std.mem.eql(u8, key, "binding")) cfg.ai = tomlStr(val);
        } else if (std.mem.eql(u8, table, "vars")) {
            vars.append(a, .{ .name = key, .text = tomlStr(val) }) catch {};
        } else if (std.mem.eql(u8, table, "durable_objects.bindings")) {
            if (dos.items.len == 0) continue;
            const d = &dos.items[dos.items.len - 1];
            if (std.mem.eql(u8, key, "name")) d.name = tomlStr(val) else if (std.mem.eql(u8, key, "class_name")) d.class = tomlStr(val);
        } else if (std.mem.eql(u8, table, "migrations")) {
            if (std.mem.eql(u8, key, "tag")) cfg.tag = tomlStr(val) else if (std.mem.eql(u8, key, "new_sqlite_classes")) tomlList(a, &sqlite, val) else if (std.mem.eql(u8, key, "new_classes")) tomlList(a, &classes, val);
        }
    }
    if (cfg.main.len == 0) cfg.main = "src/index.js";
    if (cfg.compat_date.len == 0) cfg.compat_date = GARRETT_COMPAT_DATE;
    if (cfg.tag.len == 0) cfg.tag = GARRETT_MIGRATION_TAG;
    cfg.flags = flags.items;
    cfg.vars = vars.items;
    cfg.dos = dos.items;
    cfg.sqlite_classes = sqlite.items;
    cfg.classes = classes.items;
    return cfg;
}

/// What a module is to Cloudflare, by its name: an ES module, CommonJS, WebAssembly, Python, text, or bytes.
fn moduleType(name: []const u8) []const u8 {
    const base = name[(std.mem.lastIndexOfScalar(u8, name, '/') orelse 0)..];
    const ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[i..] else "";
    const eq = std.mem.eql;
    if (eq(u8, ext, ".js") or eq(u8, ext, ".mjs")) return "application/javascript+module";
    if (eq(u8, ext, ".cjs")) return "application/javascript";
    if (eq(u8, ext, ".wasm")) return "application/wasm";
    if (eq(u8, ext, ".py")) return "text/x-python";
    if (eq(u8, ext, ".txt") or eq(u8, ext, ".html") or eq(u8, ext, ".md") or eq(u8, ext, ".json") or eq(u8, ext, ".css") or eq(u8, ext, ".svg")) return "text/plain";
    return "application/octet-stream";
}

/// Whether what came back is the module and not an error page: WebAssembly by its magic, a script by not being
/// HTML or GitHub's "404: Not Found", anything else by not being that 404.
fn looksLikeModule(ctype: []const u8, data: []const u8) bool {
    if (data.len == 0 or std.mem.startsWith(u8, data, "404: Not Found")) return false;
    if (std.mem.eql(u8, ctype, "application/wasm")) return std.mem.startsWith(u8, data, "\x00asm");
    if (std.mem.eql(u8, ctype, "application/javascript+module") or std.mem.eql(u8, ctype, "application/javascript")) {
        const head = data[0..@min(data.len, 256)];
        return std.mem.indexOf(u8, head, "<!DOCTYPE") == null and std.mem.indexOf(u8, head, "<html") == null;
    }
    return true;
}

/// The first line of a reply, for an error message.
fn oneLine(s: []const u8, n: usize) []const u8 {
    return std.mem.trim(u8, std.mem.sliceTo(s[0..@min(s.len, n)], '\n'), " \r\t");
}

const GarrettEntry = struct { name: []const u8 = "", type: []const u8 = "" };

/// The modules under the agent's main-module directory, as the repo has them now: GitHub's listing of that directory
/// (and its subdirectories, two deep), each file fetched and typed by its name. What went wrong, or null.
fn garrettModules(app: *App, a: std.mem.Allocator, cfg: GarrettCfg, out: *std.ArrayListUnmanaged(GarrettModule)) ?[]const u8 {
    return garrettDir(app, a, cfg.mainDir(), "", 0, out);
}

fn garrettDir(app: *App, a: std.mem.Allocator, base: []const u8, sub: []const u8, depth: u8, out: *std.ArrayListUnmanaged(GarrettModule)) ?[]const u8 {
    const dir = if (sub.len == 0) base else std.fmt.allocPrint(a, "{s}/{s}", .{ base, sub }) catch return "out of memory";
    const url = garrettListUrl(app, a, dir) orelse return "out of memory";
    const raw = garrettFetch(app, a, url) orelse return std.fmt.allocPrint(a, "could not list Agent Garrett's modules on GitHub ({s}/{s})", .{ GARRETT_DIR, dir }) catch "could not list Agent Garrett's modules on GitHub";
    const entries = std.json.parseFromSliceLeaky([]const GarrettEntry, a, raw, .{ .ignore_unknown_fields = true }) catch
        return std.fmt.allocPrint(a, "GitHub did not list Agent Garrett's modules ({s}/{s}): {s}", .{ GARRETT_DIR, dir, oneLine(raw, 120) }) catch "GitHub did not list Agent Garrett's modules";
    for (entries) |e| {
        if (e.name.len == 0 or e.name[0] == '.' or std.mem.indexOfScalar(u8, e.name, '/') != null) continue;
        const rel = if (sub.len == 0) e.name else std.fmt.allocPrint(a, "{s}/{s}", .{ sub, e.name }) catch return "out of memory";
        if (std.mem.eql(u8, e.type, "dir")) {
            if (depth < 2) if (garrettDir(app, a, base, rel, depth + 1, out)) |m| return m;
            continue;
        }
        if (!std.mem.eql(u8, e.type, "file")) continue;
        if (out.items.len >= GARRETT_FILES_MAX) return "Agent Garrett's repo lists more modules than a launch carries";
        const file_rel = if (base.len == 0) rel else std.fmt.allocPrint(a, "{s}/{s}", .{ base, rel }) catch return "out of memory";
        const furl = garrettUrl(app, a, file_rel) orelse return "out of memory";
        const data = garrettFetch(app, a, furl) orelse return std.fmt.allocPrint(a, "could not read Agent Garrett's {s} from its repo", .{rel}) catch "could not read Agent Garrett's modules";
        const ctype = moduleType(e.name);
        if (!looksLikeModule(ctype, data)) return std.fmt.allocPrint(a, "Agent Garrett's {s} did not come back as a module: {s}", .{ rel, oneLine(data, 80) }) catch "a module of Agent Garrett did not come back as one";
        out.append(a, .{ .name = rel, .data = data, .ctype = ctype }) catch return "out of memory";
    }
    return null;
}

fn garrettVars(a: std.mem.Allocator, cfg: GarrettCfg) ![]const GarrettCfg.Var {
    var out: std.ArrayListUnmanaged(GarrettCfg.Var) = .empty;
    for (cfg.vars) |v| {
        if (std.mem.eql(u8, v.name, "TOOL_ALLOWLIST") or std.mem.eql(u8, v.name, "ROUTER_ENFORCE_POLICY") or std.mem.eql(u8, v.name, "SITE_NAME") or std.mem.eql(u8, v.name, "GARY_TOOLS_ENABLED") or
            std.mem.eql(u8, v.name, "AGENT_ALLOW_ACTIVE_TOOLS") or std.mem.eql(u8, v.name, "MCP_ALLOW_ACTIVE_TOOLS") or
            std.mem.eql(u8, v.name, "MCP_ALLOW_DARKWEB") or std.mem.eql(u8, v.name, "CTF_SAFE_MODE") or std.mem.eql(u8, v.name, "CTF_REQUIRE_CONFIRM")) continue;
        try out.append(a, v);
    }
    inline for (.{ .{ "TOOL_ALLOWLIST", @embedFile("security-tools.txt") }, .{ "ROUTER_ENFORCE_POLICY", "false" }, .{ "SITE_NAME", "Security tools" }, .{ "GARY_TOOLS_ENABLED", "true" }, .{ "AGENT_ALLOW_ACTIVE_TOOLS", "true" }, .{ "MCP_ALLOW_ACTIVE_TOOLS", "true" }, .{ "MCP_ALLOW_DARKWEB", "true" }, .{ "CTF_SAFE_MODE", "false" }, .{ "CTF_REQUIRE_CONFIRM", "false" } }) |v|
        try out.append(a, .{ .name = v[0], .text = v[1] });
    return out.items;
}

/// The modules as fetched, as 16 hex characters: what a launch was made from.
fn garrettHash(files: []const []const u8, out: *[16]u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (files) |f| {
        h.update(f);
        h.update("\x00");
    }
    var dig: [32]u8 = undefined;
    h.final(&dig);
    out.* = std.fmt.bytesToHex(dig[0..8].*, .lower);
    return out;
}

/// Agent Garrett's upload: the metadata (its main module, compatibility date and flags, its AI binding, its Durable
/// Object classes and its vars, as its wrangler.toml ships them, the secrets kept) and the modules as fetched, each
/// with its type. `fresh` carries the class migration, which Cloudflare takes once per script.
fn garrettModuleData(a: std.mem.Allocator, name: []const u8, data: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, name, "gary-tools.mjs")) return std.fmt.allocPrint(a, "{s}{s}", .{ data, "\nexport async function garyRuntimeStatus(env = {}) {\n  let status = await requestRuntime(env, 'runtime/status', {}, 15000);\n  if (status.phase === 'not-started' || status.phase === 'failed') {\n    try { await loadGaryToolCatalog(env); } catch {}\n    status = await requestRuntime(env, 'runtime/status', {}, 15000);\n  }\n  return {phase:status.phase || 'unavailable', error:status.error || ''};\n}\n" });
    if (std.mem.endsWith(u8, name, "mcp.mjs")) return std.mem.replaceOwned(u8, a, data, "  if (body.method === 'ping')", "  if (body.method === 'gary/runtime/status') {\n    try { return jsonResponse(rpc(body.id, await handlers.runtimeStatus())); }\n    catch (error) { return jsonResponse(rpc(body.id, {phase:'failed',error:error.message})); }\n  }\n  if (body.method === 'ping')");
    if (!std.mem.endsWith(u8, name, "index.js")) return data;
    const scoped = try std.mem.replaceOwned(u8, a, data, "if (targets.length && !policy.targetAllowlist.size)", "if (policy.safeMode && targets.length && !policy.targetAllowlist.size)");
    defer a.free(scoped);
    const imported = try std.mem.replaceOwned(u8, a, scoped, "import { garyToolCatalog,", "import { garyRuntimeStatus, garyToolCatalog,");
    defer a.free(imported);
    return std.mem.replaceOwned(u8, a, imported, "readJson: req => readJsonBodyLimited(req),", "readJson: req => readJsonBodyLimited(req),\n        runtimeStatus: () => garyRuntimeStatus(env),");
}

test "security deployment applies target scoping only when safe mode is selected" {
    const a = tt.allocator;
    const input = "if (targets.length && !policy.targetAllowlist.size) reject();";
    const result = try garrettModuleData(a, "index.js", input);
    defer a.free(result);
    try tt.expectEqualStrings("if (policy.safeMode && targets.length && !policy.targetAllowlist.size) reject();", result);
    try tt.expectEqualStrings(input, try garrettModuleData(a, "other.mjs", input));
}

fn garrettUploadBody(a: std.mem.Allocator, boundary: []const u8, fresh: bool, cfg: GarrettCfg, mods: []const GarrettModule) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\nContent-Type: application/json\r\n\r\n", .{boundary});
    try out.appendSlice(a, "{\"main_module\":");
    try http.jstr(a, &out, cfg.mainModule());
    try out.appendSlice(a, ",\"compatibility_date\":");
    try http.jstr(a, &out, cfg.compat_date);
    if (cfg.flags.len > 0) {
        try out.appendSlice(a, ",\"compatibility_flags\":[");
        for (cfg.flags, 0..) |f, i| {
            if (i > 0) try out.append(a, ',');
            try http.jstr(a, &out, f);
        }
        try out.append(a, ']');
    }
    try out.appendSlice(a, ",\"bindings\":[");
    var n: usize = 0;
    if (cfg.ai.len > 0) {
        try out.appendSlice(a, "{\"type\":\"ai\",\"name\":");
        try http.jstr(a, &out, cfg.ai);
        try out.append(a, '}');
        n += 1;
    }
    for (cfg.dos) |d| {
        if (d.name.len == 0 or d.class.len == 0) continue;
        if (n > 0) try out.append(a, ',');
        try out.appendSlice(a, "{\"type\":\"durable_object_namespace\",\"name\":");
        try http.jstr(a, &out, d.name);
        try out.appendSlice(a, ",\"class_name\":");
        try http.jstr(a, &out, d.class);
        try out.append(a, '}');
        n += 1;
    }
    for (try garrettVars(a, cfg)) |v| {
        if (n > 0) try out.append(a, ',');
        try out.appendSlice(a, "{\"type\":\"plain_text\",\"name\":");
        try http.jstr(a, &out, v.name);
        try out.appendSlice(a, ",\"text\":");
        try http.jstr(a, &out, v.text);
        try out.append(a, '}');
        n += 1;
    }
    try out.appendSlice(a, ",{\"type\":\"service\",\"name\":\"GARY_RUNTIME\",\"service\":\"" ++ GARY_SCRIPT ++ "\",\"entrypoint\":\"GaryBackend\"}],\"keep_bindings\":[\"secret_text\"]");
    if (fresh and (cfg.sqlite_classes.len > 0 or cfg.classes.len > 0)) {
        try out.appendSlice(a, ",\"migrations\":{\"new_tag\":");
        try http.jstr(a, &out, cfg.tag);
        inline for (.{ .{ "new_sqlite_classes", cfg.sqlite_classes }, .{ "new_classes", cfg.classes } }) |kv| {
            if (kv[1].len > 0) {
                try out.print(a, ",\"{s}\":[", .{kv[0]});
                for (kv[1], 0..) |c, i| {
                    if (i > 0) try out.append(a, ',');
                    try http.jstr(a, &out, c);
                }
                try out.append(a, ']');
            }
        }
        try out.append(a, '}');
    }
    try out.append(a, '}');
    for (mods) |m| {
        try out.print(a, "\r\n--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n", .{ boundary, m.name, m.name, m.ctype });
        try out.appendSlice(a, try garrettModuleData(a, m.name, m.data));
    }
    try out.print(a, "\r\n--{s}--\r\n", .{boundary});
    return out.items;
}

/// Agent Garrett's MCP bearer, as the tots carry it: derived like the tots' own token, never stored.
fn garrettToken(app: *App, uid: u64, account: []const u8, gen: u32, out: *[64]u8) []const u8 {
    return tokenWith(app, cf_garrett.MCP_LABEL, uid, account, gen, out);
}

/// The password locking its chat UI: open to anyone with the address otherwise. `veil --tater garrett password`.
fn garrettPassword(app: *App, uid: u64, account: []const u8, gen: u32, out: *[64]u8) []const u8 {
    return tokenWith(app, cf_garrett.ACCESS_LABEL, uid, account, gen, out);
}

/// The account Agent Garrett was launched into and the generation its secrets were derived under. A launch from
/// before State recorded them was made beside the tots: theirs stand in (cf_garrett.credsFor reads them the same way).
fn garrettAccount(st: State) []const u8 {
    return if (st.garrett_account.len > 0) st.garrett_account else st.account;
}

fn garrettGen(st: State) u32 {
    return if (st.garrett_account.len > 0) st.garrett_gen else st.token_gen;
}

/// Point the tots' Worker at Agent Garrett: where it answers and the bearer it answers to, as two secrets on
/// their script. What went wrong in words, or null.
fn pointTotsAtGarrett(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: State) ?[]const u8 {
    const acct = garrettAccount(st);
    const tots_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ SCRIPT, .{ app.cf_api_root, acct }) catch return "out of memory";
    const mcp_url = std.fmt.allocPrint(a, "{s}/mcp", .{st.garrett_url}) catch return "out of memory";
    var mb: [64]u8 = undefined;
    const mcp = garrettToken(app, uid, acct, garrettGen(st), &mb);
    if (putSecret(app, a, tots_url, tok.key, "GARRETT_MCP_URL", mcp_url, "pointing the tots at Agent Garrett")) |m| return m;
    if (putSecret(app, a, tots_url, tok.key, "GARRETT_MCP_TOKEN", mcp, "giving the tots Agent Garrett's token")) |m| return m;
    return null;
}

/// One secret on a script. A small JSON body: it rides curl's stdin with the bearer, never a file.
fn putSecret(app: *App, a: std.mem.Allocator, script_url: []const u8, key: []const u8, name: []const u8, value: []const u8, what: []const u8) ?[]const u8 {
    const url = std.fmt.allocPrint(a, "{s}/secrets", .{script_url}) catch return "out of memory";
    const body = std.json.Stringify.valueAlloc(a, .{ .name = name, .text = value, .type = "secret_text" }, .{}) catch return "out of memory";
    const raw = api(app, a, "PUT", url, body, key, "application/json") orelse return std.fmt.allocPrint(a, "could not reach the Cloudflare API ({s})", .{what}) catch "could not reach the Cloudflare API";
    const e = firstError(a, raw);
    if (e.len > 0) return explain(a, what, e);
    return null;
}

/// Launch Agent Garrett into the account: its Worker config and every module as its repo has them NOW, uploaded as
/// one Worker of its own with its derived secrets, its address enabled, and - when the tots' Worker is in this
/// account - the tots pointed at it. No tot is needed: the desk's Settings button deploys it on its own. What went
/// wrong in words a user can act on, or null. The repo is read before anything in the account is touched.
const GARY_SCRIPT = "veil-garrett-gary";
const GARY_BUCKET = "veil-garrett-gary-state";
const GARY_UPLOADER = "veil-garrett-upload";
const GARY_APP = "veil-garrett-gary-garycontainer";
const GARY_SOURCE = @embedFile("gary-source.tar.gz");

fn garyBody(a: std.mem.Allocator, boundary: []const u8, metadata: []const u8, mods: []const GarrettModule) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{s}", .{ boundary, metadata });
    for (mods) |m| {
        try out.print(a, "\r\n--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n", .{ boundary, m.name, m.name, m.ctype });
        try out.appendSlice(a, m.data);
    }
    try out.print(a, "\r\n--{s}--\r\n", .{boundary});
    return out.items;
}

fn launchGary(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, gen: u32, sub: []const u8) ?[]const u8 {
    const base = std.fmt.allocPrint(a, "{s}/accounts/{s}", .{ app.cf_api_root, tok.account_id }) catch return "out of memory";
    const bucket_url = std.fmt.allocPrint(a, "{s}/r2/buckets/" ++ GARY_BUCKET, .{base}) catch return "out of memory";
    const exists = if (api(app, a, "GET", bucket_url, "", tok.key, "")) |r| firstError(a, r).len == 0 else false;
    if (!exists) {
        const url = std.fmt.allocPrint(a, "{s}/r2/buckets", .{base}) catch return "out of memory";
        const raw = api(app, a, "POST", url, "{\"name\":\"" ++ GARY_BUCKET ++ "\"}", tok.key, "application/json") orelse return "could not create the security runtime storage";
        const err = firstError(a, raw);
        if (err.len > 0) return explain(a, "creating the security runtime storage", err);
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(GARY_SOURCE, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const boundary = "----veilgaryruntime";
    const ctype = "multipart/form-data; boundary=" ++ boundary;
    const upload_url = std.fmt.allocPrint(a, "{s}/workers/scripts/" ++ GARY_UPLOADER, .{base}) catch return "out of memory";
    const upload_meta = "{\"main_module\":\"upload.mjs\",\"compatibility_date\":\"2026-10-09\",\"bindings\":[{\"type\":\"r2_bucket\",\"name\":\"STATE\",\"bucket_name\":\"" ++ GARY_BUCKET ++ "\"}],\"keep_bindings\":[\"secret_text\"]}";
    const upload_source =
        \\export default { async fetch(r,e) {
        \\if (r.method !== 'PUT' || r.headers.get('Authorization') !== 'Bearer '+e.TOKEN) return new Response('Unauthorized',{status:401});
        \\const key = new URL(r.url).pathname.slice(1);
        \\if (!/^build\/[a-f0-9]{64}\.tar\.gz$/.test(key)) return new Response('Invalid package',{status:400});
        \\const bytes = await r.arrayBuffer();
        \\if (bytes.byteLength > 33554432) return new Response('Too large',{status:413});
        \\const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
        \\if (key !== 'build/'+hash+'.tar.gz') return new Response('Checksum failed',{status:400});
        \\await e.STATE.put(key,bytes); return Response.json({success:true}); } };
    ;
    const upload_body = garyBody(a, boundary, upload_meta, &.{.{ .name = "upload.mjs", .data = upload_source, .ctype = "application/javascript+module" }}) catch return "out of memory";
    const uploaded = api(app, a, "PUT", upload_url, upload_body, tok.key, ctype) orelse return "could not upload the runtime package transport";
    const up_err = firstError(a, uploaded);
    if (up_err.len > 0) return explain(a, "uploading the runtime package transport", up_err);
    defer _ = api(app, a, "DELETE", upload_url, "", tok.key, "");
    var tb: [64]u8 = undefined;
    const runtime_token = tokenWith(app, "veil-gary-runtime", uid, tok.account_id, gen, &tb);
    if (putSecret(app, a, upload_url, tok.key, "TOKEN", runtime_token, "configuring the package transport")) |m| return m;
    const route_url = std.fmt.allocPrint(a, "{s}/subdomain", .{upload_url}) catch return "out of memory";
    const routed = api(app, a, "POST", route_url, "{\"enabled\":true}", tok.key, "application/json") orelse return "could not enable the package transport";
    const route_err = firstError(a, routed);
    if (route_err.len > 0) return explain(a, "enabling the package transport", route_err);
    const origin = workerUrl(app, a, GARY_UPLOADER, sub) orelse return "out of memory";
    const package_url = std.fmt.allocPrint(a, "{s}/build/{s}.tar.gz", .{ origin, hash }) catch return "out of memory";
    var stored = false;
    for (0..12) |attempt| {
        if (attempt > 0) app.io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_s }, .awake) catch {};
        const result = api(app, a, "PUT", package_url, GARY_SOURCE, runtime_token, "application/gzip") orelse continue;
        if (std.mem.indexOf(u8, result, "\"success\":true") != null) {
            stored = true;
            break;
        }
    }
    if (!stored) return "could not store the security runtime source package";
    const metadata = std.fmt.allocPrint(a, "{{\"main_module\":\"worker.mjs\",\"compatibility_date\":\"2026-10-09\",\"compatibility_flags\":[\"enable_request_signal\"]," ++
        "\"bindings\":[{{\"type\":\"ai\",\"name\":\"AI\"}},{{\"type\":\"durable_object_namespace\",\"name\":\"GARY_CONTAINER\",\"class_name\":\"GaryContainer\"}},{{\"type\":\"r2_bucket\",\"name\":\"GARY_STATE\",\"bucket_name\":\"" ++ GARY_BUCKET ++ "\"}},{{\"type\":\"plain_text\",\"name\":\"GARY_BUILD_ID\",\"text\":\"{s}\"}},{{\"type\":\"plain_text\",\"name\":\"GARY_LLM_MODEL\",\"text\":\"@cf/zai-org/glm-4.7-flash\"}}]," ++
        "\"exports\":{{\"GaryContainer\":{{\"type\":\"durable-object\",\"storage\":\"sqlite\",\"container\":\"" ++ GARY_APP ++ "\"}}}},\"containers\":[{{\"name\":\"" ++ GARY_APP ++ "\",\"class_name\":\"GaryContainer\"}}],\"keep_bindings\":[\"secret_text\"]}}", .{hash}) catch return "out of memory";
    const body = garyBody(a, boundary, metadata, &.{
        .{ .name = "worker.mjs", .data = @embedFile("gary-worker.mjs"), .ctype = "application/javascript+module" },
        .{ .name = "gateway.mjs", .data = @embedFile("gary-gateway.mjs"), .ctype = "application/javascript+module" },
        .{ .name = "bootstrap.py", .data = @embedFile("gary-bootstrap.py"), .ctype = "text/plain" },
    }) catch return "out of memory";
    const script_url = std.fmt.allocPrint(a, "{s}/workers/scripts/" ++ GARY_SCRIPT, .{base}) catch return "out of memory";
    const deployed = api(app, a, "PUT", script_url, body, tok.key, ctype) orelse return "could not deploy the security execution Worker";
    const dep_err = firstError(a, deployed);
    if (dep_err.len > 0) return explain(a, "deploying the security execution Worker", dep_err);
    if (putSecret(app, a, script_url, tok.key, "GARY_RUNTIME_TOKEN", runtime_token, "configuring the security runtime")) |m| return m;
    const namespaces_url = std.fmt.allocPrint(a, "{s}/workers/durable_objects/namespaces?per_page=1000", .{base}) catch return "out of memory";
    const ns_raw = api(app, a, "GET", namespaces_url, "", tok.key, "") orelse return "could not inspect the security runtime namespace";
    const Ns = struct { id: []const u8 = "", script: []const u8 = "", class: []const u8 = "", preview: ?bool = null };
    const ns = std.json.parseFromSliceLeaky(struct { result: []const Ns = &.{} }, a, ns_raw, .{ .ignore_unknown_fields = true }) catch return "invalid security runtime namespace response";
    var namespace: []const u8 = "";
    for (ns.result) |n| if (std.mem.eql(u8, n.script, GARY_SCRIPT) and std.mem.eql(u8, n.class, "GaryContainer") and n.preview == null) {
        namespace = n.id;
        break;
    };
    if (namespace.len == 0) return "the security runtime namespace was not provisioned";
    const apps_url = std.fmt.allocPrint(a, "{s}/containers/applications", .{base}) catch return "out of memory";
    const one_url = std.fmt.allocPrint(a, "{s}/{s}", .{ apps_url, namespace }) catch return "out of memory";
    const has_app = if (api(app, a, "GET", one_url, "", tok.key, "")) |r| firstError(a, r).len == 0 else false;
    if (!has_app) {
        const config = std.json.Stringify.valueAlloc(a, .{ .name = GARY_APP, .scheduling_policy = "durable_object", .durable_objects = .{ .namespace_id = namespace } }, .{}) catch return "out of memory";
        const result = api(app, a, "POST", apps_url, config, tok.key, "application/json") orelse return "could not create the dedicated security Container";
        const err = firstError(a, result);
        if (err.len > 0) return std.fmt.allocPrint(a, "creating the dedicated security Container: {s}. Reconnect Cloudflare with Containers permissions.", .{err}) catch "reconnect Cloudflare with Containers permissions";
    }
    return null;
}

fn launchGarrett(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State) ?[]const u8 {
    const root = app.cf_api_root;
    const acct = tok.account_id;
    if (acct.len == 0) return "your Cloudflare login names no account - Disconnect and log in with Cloudflare again";
    // The agent as its repo has it this minute: its Worker config, then every module under its main module's dir.
    const toml_url = garrettUrl(app, a, GARRETT_TOML) orelse return "out of memory";
    const toml = garrettFetch(app, a, toml_url) orelse return "could not read Agent Garrett's wrangler.toml from its repo (github.com/" ++ GARRETT_REPO ++ ")";
    if (std.mem.startsWith(u8, toml, "404") or std.mem.indexOf(u8, toml, "main") == null) return std.fmt.allocPrint(a, "Agent Garrett's wrangler.toml did not come back as one: {s}", .{oneLine(toml, 80)}) catch "Agent Garrett's wrangler.toml did not come back as one";
    const cfg = parseGarrettToml(a, toml);
    var mods: std.ArrayListUnmanaged(GarrettModule) = .empty;
    if (garrettModules(app, a, cfg, &mods)) |msg| return msg;
    var has_main = false;
    for (mods.items) |m| {
        if (std.mem.eql(u8, m.name, cfg.mainModule())) has_main = true;
    }
    if (!has_main) return std.fmt.allocPrint(a, "Agent Garrett's repo lists no {s} under {s}/{s}/ (its wrangler.toml names it as the main module)", .{ cfg.mainModule(), GARRETT_DIR, cfg.mainDir() }) catch "Agent Garrett's main module is missing from its repo";
    var why: []const u8 = "";
    const sub = workersSubdomain(app, a, tok, &why) orelse return why;
    if (launchGary(app, a, uid, tok, st.token_gen, sub)) |msg| return msg;
    const script_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ GARRETT_SCRIPT, .{ root, acct }) catch return "out of memory";
    const settings_url = std.fmt.allocPrint(a, "{s}/settings", .{script_url}) catch return "out of memory";
    const exists = if (api(app, a, "GET", settings_url, "", tok.key, "")) |r| firstError(a, r).len == 0 else false;
    var bb: [8]u8 = undefined;
    app.io.random(&bb);
    const boundary = std.fmt.allocPrint(a, "----veilgarrett{s}", .{std.fmt.bytesToHex(bb, .lower)}) catch return "out of memory";
    const ctype = std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary}) catch return "out of memory";
    // The settings read is only a hint, so the upload is tried with and without the class migration.
    var up_err: []const u8 = "";
    var taken = false;
    for ([_]bool{ !exists, exists }) |fresh| {
        const body = garrettUploadBody(a, boundary, fresh, cfg, mods.items) catch return "out of memory";
        const up = api(app, a, "PUT", script_url, body, tok.key, ctype) orelse return "could not reach the Cloudflare API to upload Agent Garrett";
        const e = firstError(a, up);
        if (e.len == 0) {
            taken = true;
            break;
        }
        if (up_err.len == 0) up_err = e;
    }
    if (!taken) return explain(a, "uploading Agent Garrett", up_err);
    // Its secrets: the MCP bearer the tots carry, and a lock on the chat UI (it is open to anyone otherwise).
    var mb: [64]u8 = undefined;
    var pb: [64]u8 = undefined;
    var sb: [64]u8 = undefined;
    const mcp = garrettToken(app, uid, acct, st.token_gen, &mb);
    if (putSecret(app, a, script_url, tok.key, "MCP_API_TOKEN", mcp, "setting Agent Garrett's MCP token")) |m| return m;
    if (putSecret(app, a, script_url, tok.key, "ACCESS_PASSWORD", garrettPassword(app, uid, acct, st.token_gen, &pb), "locking Agent Garrett's chat UI")) |m| return m;
    if (putSecret(app, a, script_url, tok.key, "ACCESS_SESSION_SECRET", tokenWith(app, cf_garrett.SESSION_LABEL, uid, acct, st.token_gen, &sb), "setting Agent Garrett's session secret")) |m| return m;
    const route_url = std.fmt.allocPrint(a, "{s}/subdomain", .{script_url}) catch return "out of memory";
    const route = api(app, a, "POST", route_url, "{\"enabled\":true}", tok.key, "application/json") orelse return "could not reach Cloudflare to enable Agent Garrett's workers.dev address";
    const route_err = firstError(a, route);
    if (route_err.len > 0) return explain(a, "enabling Agent Garrett's address", route_err);
    const url = workerUrl(app, a, GARRETT_SCRIPT, sub) orelse return "out of memory";
    var hb: [16]u8 = undefined;
    var datas: std.ArrayListUnmanaged([]const u8) = .empty;
    for (mods.items) |m| datas.append(a, m.data) catch return "out of memory";
    st.garrett_url = url;
    st.garrett_hash = a.dupe(u8, garrettHash(datas.items, &hb)) catch return "out of memory";
    st.garrett_at = nowS(app.io);
    st.garrett_account = acct;
    st.garrett_gen = st.token_gen;
    writeState(app, uid, st.*); // it is up: recorded before the tots are pointed at it, so a refusal there loses nothing
    log.info("Agent Garrett launched for u{d}: {s}", .{ uid, url });
    // The tots, when their Worker is in this account: where it answers, and the bearer it answers to. A runtime
    // uploaded later is pointed at it by ensureRuntime.
    if (st.url.len > 0 and std.mem.eql(u8, st.account, acct)) if (pointTotsAtGarrett(app, a, uid, tok, st.*)) |m| return m;
    return null;
}

/// Remove Agent Garrett: its Worker, and - when the tots' Worker is here - their two secrets and the runtime's
/// record. Best effort past the script.
fn removeGary(app: *App, a: std.mem.Allocator, tok: Tok, account: []const u8) ?[]const u8 {
    const base = std.fmt.allocPrint(a, "{s}/accounts/{s}", .{ app.cf_api_root, account }) catch return "out of memory";
    const ns_url = std.fmt.allocPrint(a, "{s}/workers/durable_objects/namespaces?per_page=1000", .{base}) catch return "out of memory";
    const raw = api(app, a, "GET", ns_url, "", tok.key, "") orelse return "could not inspect the security runtime before removing it";
    const err = firstError(a, raw);
    if (err.len > 0) return explain(a, "inspecting the security runtime", err);
    const Ns = struct { id: []const u8 = "", script: []const u8 = "", class: []const u8 = "", preview: ?bool = null };
    const ns = std.json.parseFromSliceLeaky(struct { result: []const Ns = &.{} }, a, raw, .{ .ignore_unknown_fields = true }) catch return "invalid security runtime namespace response";
    for (ns.result) |n| {
        if (!std.mem.eql(u8, n.script, GARY_SCRIPT) or !std.mem.eql(u8, n.class, "GaryContainer") or n.preview != null) continue;
        const url = std.fmt.allocPrint(a, "{s}/containers/applications/{s}", .{ base, n.id }) catch return "out of memory";
        const deleted = api(app, a, "DELETE", url, "", tok.key, "") orelse return "could not reach Cloudflare to remove the security Container";
        const why = firstError(a, deleted);
        if (why.len > 0 and std.ascii.indexOfIgnoreCase(why, "not found") == null and std.ascii.indexOfIgnoreCase(why, "does not exist") == null)
            return explain(a, "removing the security Container", why);
    }
    const url = std.fmt.allocPrint(a, "{s}/workers/scripts/" ++ GARY_SCRIPT ++ "?force=true", .{base}) catch return "out of memory";
    const deleted = api(app, a, "DELETE", url, "", tok.key, "") orelse return "could not reach Cloudflare to remove the security execution Worker";
    const why = firstError(a, deleted);
    if (why.len > 0 and std.ascii.indexOfIgnoreCase(why, "not found") == null and std.ascii.indexOfIgnoreCase(why, "does not exist") == null)
        return explain(a, "removing the security execution Worker", why);
    return null;
}

fn removeGarrett(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State) ?[]const u8 {
    const acct = if (garrettAccount(st.*).len > 0) garrettAccount(st.*) else tok.account_id;
    const url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ GARRETT_SCRIPT ++ "?force=true", .{ app.cf_api_root, acct }) catch return "out of memory";
    const raw = api(app, a, "DELETE", url, "", tok.key, "") orelse return "could not reach the Cloudflare API to remove Agent Garrett";
    const msg = firstError(a, raw);
    if (msg.len > 0 and std.ascii.indexOfIgnoreCase(msg, "not found") == null and std.ascii.indexOfIgnoreCase(msg, "does not exist") == null)
        return explain(a, "removing Agent Garrett", msg);
    if (removeGary(app, a, tok, acct)) |why| return why;
    // the tots, when their Worker is here: the two secrets go, and the runtime's record
    if (st.url.len > 0) {
        for ([_][]const u8{ "GARRETT_MCP_URL", "GARRETT_MCP_TOKEN" }) |name| {
            const s = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ SCRIPT ++ "/secrets/{s}", .{ app.cf_api_root, st.account, name }) catch continue;
            _ = api(app, a, "DELETE", s, "", tok.key, "");
        }
        _ = totCall(app, a, uid, st.*, "POST", "/v1/garrett/clear", "{}");
    }
    st.garrett_url = "";
    st.garrett_hash = "";
    st.garrett_at = 0;
    st.garrett_account = "";
    st.garrett_gen = 0;
    writeState(app, uid, st.*);
    log.info("Agent Garrett removed from the Cloudflare account of u{d}", .{uid});
    return null;
}

/// What the runtime says about Agent Garrett: a tot's request is `pending`, and what syncGarrett acts on.
const GarrettState = struct { ok: bool = false, status: []const u8 = "none", url: []const u8 = "", @"error": []const u8 = "", asked_by: []const u8 = "", asked_at: i64 = 0 };

fn garrettState(app: *App, a: std.mem.Allocator, uid: u64, st: State) GarrettState {
    if (st.url.len == 0) return .{};
    const raw = totCall(app, a, uid, st, "GET", "/v1/garrett", "") orelse return .{};
    return std.json.parseFromSliceLeaky(GarrettState, a, raw, .{ .ignore_unknown_fields = true }) catch .{};
}

/// Tell the runtime how a launch went: its address, or why not. The tots read it from their pad.
fn garrettResult(app: *App, a: std.mem.Allocator, uid: u64, st: State, mcp_url: []const u8, err: ?[]const u8) void {
    const body = std.json.Stringify.valueAlloc(a, .{ .url = mcp_url, .err = err orelse "" }, .{}) catch return;
    _ = totCall(app, a, uid, st, "POST", "/v1/garrett/result", body);
}

/// A mirror pass: a tot asked for Agent Garrett (garrett_launch) - launch it, and tell the runtime how it went. A
/// refused launch waits a quarter of an hour before the next attempt, so a tot asking every iteration costs nothing.
fn syncGarrett(app: *App, a: std.mem.Allocator, uid: u64, st: *State) void {
    const tok = tokOf(app, uid, a) orelse return;
    syncGarrettAs(app, a, uid, tok, st);
}

fn syncGarrettAs(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State) void {
    if (!std.mem.eql(u8, tok.account_id, st.account)) return;
    const g = garrettState(app, a, uid, st.*);
    if (!g.ok or !std.mem.eql(u8, g.status, "pending")) return;
    const now = nowS(app.io);
    if (now - garrett_failed_s.load(.monotonic) < 900) return;
    if (launchGarrett(app, a, uid, tok, st)) |msg| {
        garrett_failed_s.store(now, .monotonic);
        log.warn("Agent Garrett could not be launched for u{d}: {s}", .{ uid, msg });
        garrettResult(app, a, uid, st.*, "", msg);
        return;
    }
    const mcp_url = std.fmt.allocPrint(a, "{s}/mcp", .{st.garrett_url}) catch return;
    garrettResult(app, a, uid, st.*, mcp_url, null);
}

/// GET /api/v1/tots/garrett — Agent Garrett as this server and the runtime know it. `?reveal=1` adds the password
/// that locks its chat UI (derived, so it can always be shown again).
pub fn garrettStatus(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = readState(app, u.id, a);
    const g = garrettState(app, a, u.id, st);
    const q = try req.query();
    const launched = st.garrett_url.len > 0;
    const reveal = launched and std.mem.eql(u8, q.get("reveal") orelse "0", "1");
    var pb: [64]u8 = undefined;
    const password: []const u8 = if (reveal) garrettPassword(app, u.id, garrettAccount(st), garrettGen(st), &pb) else "";
    const mcp_url: []const u8 = if (launched) try std.fmt.allocPrint(a, "{s}/mcp", .{st.garrett_url}) else "";
    var runtime_phase: []const u8 = "none";
    var runtime_error: []const u8 = "";
    if (cf_garrett.credsFor(app, u.id, a)) |creds| {
        const raw = security_runtime.runtimeStatus(.{ .gpa = a, .io = app.io, .scratch = app.data, .url = creds.mcp_url, .token = creds.token });
        const Runtime = struct { result: struct { phase: []const u8 = "unavailable", @"error": []const u8 = "" } = .{} };
        if (std.json.parseFromSliceLeaky(Runtime, a, raw, .{ .ignore_unknown_fields = true })) |r| {
            runtime_phase = r.result.phase;
            runtime_error = r.result.@"error";
        } else |_| {
            runtime_phase = "unavailable";
        }
    }
    const building = std.mem.eql(u8, runtime_phase, "building") or std.mem.eql(u8, runtime_phase, "not-started");
    const status: []const u8 = if (launched and std.mem.eql(u8, g.status, "none")) "deployed" else g.status;
    try res.json(.{ .ok = true, .launched = launched, .url = st.garrett_url, .mcp_url = mcp_url, .account = if (launched) garrettAccount(st) else "", .launched_at = st.garrett_at, .sources = st.garrett_hash, .status = status, .runtime_phase = runtime_phase, .runtime_building = building, .runtime_ready = std.mem.eql(u8, runtime_phase, "ready"), .@"error" = if (runtime_error.len > 0) runtime_error else g.@"error", .asked_by = g.asked_by, .asked_at = g.asked_at, .password = password, .repo = "https://github.com/gary23w/garrettstimpson.ca/tree/main/agent" }, .{});
}

/// POST /api/v1/tots/garrett — launch Agent Garrett now (the owner asking; a tot asks through garrett_launch).
pub fn garrettLaunch(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
    var st = readState(app, u.id, a);
    if (launchGarrett(app, a, u.id, tok, &st)) |msg| {
        garrettResult(app, a, u.id, st, "", msg);
        return badReq(res, msg);
    }
    const mcp_url = try std.fmt.allocPrint(a, "{s}/mcp", .{st.garrett_url});
    garrettResult(app, a, u.id, st, mcp_url, null);
    try res.json(.{ .ok = true, .url = st.garrett_url, .mcp_url = mcp_url }, .{});
}

/// DELETE /api/v1/tots/garrett — remove it: the Worker, the tots' two secrets, the runtime's record.
pub fn garrettRemove(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok = tokOf(app, u.id, a) orelse return badReq(res, "not connected to Cloudflare - log in with Cloudflare first");
    var st = readState(app, u.id, a);
    if (removeGarrett(app, a, u.id, tok, &st)) |msg| return badReq(res, msg);
    try res.json(.{ .ok = true, .removed = true }, .{});
}

// ---------------------------------------------------------------------------------- the owner's machine

const Job = struct { id: []const u8 = "", t: i64 = 0, instruction: []const u8 = "" };
const Jobs = struct { ok: bool = false, model: []const u8 = "", jobs: []const Job = &.{} };

/// The conversation one job runs in: "tot_<name>_<job id>_<queued at, seconds>". The stamp keeps a job of a tot
/// that was deleted and deployed again under the same name out of the old tot's conversation.
fn jobConv(buf: *[64]u8, name: []const u8, job: Job) ?[]const u8 {
    if (!validName(name) or job.id.len == 0 or job.id.len > 12) return null;
    for (job.id) |c| if (!std.ascii.isAlphanumeric(c)) return null;
    var lb: [NAME_MAX]u8 = undefined;
    return std.fmt.bufPrint(buf, "tot_{s}_{s}_{d}", .{ std.ascii.lowerString(&lb, name), job.id, @divTrunc(@max(job.t, 0), 1000) }) catch null;
}

/// What the unattended turn is told: the tot's instruction, then who sent it and how the turn must end.
fn jobText(a: std.mem.Allocator, name: []const u8, instruction: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(a,
        \\{s}
        \\
        \\--- TOT JOB CONTEXT (engine-authored) ---
        \\This job was sent by {s}, a tot: an autonomous technician that works for this machine's owner from their Cloudflare account. The owner allowed it to use this machine when deploying it. Nobody is watching this turn: do the work with your tools, never ask a question and wait, and end with a plain report of what was done and what the tool results showed. Your final message is sent back to {s} as the job's result.
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
    const path = std.fmt.allocPrint(a, "/v1/tots/{s}/jobs/{s}", .{ name, job_id }) catch return;
    const clipped = result[0..@min(result.len, 6000)];
    const json = std.json.Stringify.valueAlloc(a, .{ .ok = ok, .result = clipped }, .{}) catch return;
    _ = totCall(app, a, uid, st, "POST", path, json);
}

/// One approved tot, one pass: answer the jobs whose turn has ended, and start the next one. One job runs at a
/// time per tot. Returns how many turns it started.
fn bridgeTot(app: *App, a: std.mem.Allocator, uid: u64, st: State, name: []const u8) usize {
    const raw = totCall(app, a, uid, st, "GET", std.fmt.allocPrint(a, "/v1/tots/{s}/jobs", .{name}) catch return 0, "") orelse return 0;
    const jobs = std.json.parseFromSliceLeaky(Jobs, a, raw, .{ .ignore_unknown_fields = true }) catch return 0;
    if (!jobs.ok) return 0;
    var lb: [NAME_MAX]u8 = undefined;
    var pb: [40]u8 = undefined;
    const prefix = std.fmt.bufPrint(&pb, "tot_{s}_", .{std.ascii.lowerString(&lb, name)}) catch return 0;
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

/// Start the unattended chat turn for one job, on the owner's Cloudflare login and the tot's own model.
fn launchJob(app: *App, a: std.mem.Allocator, uid: u64, name: []const u8, conv: []const u8, model: []const u8, instruction: []const u8) bool {
    const cf = cf_oauth.resolveToken(app, uid, a) orelse return false; // logged out: the job waits
    const text = jobText(a, name, instruction) orelse return false;
    const trio: chat_engine.ModelTrio = .{ .coding = .{ .base_url = cf.base_url, .key = cf.key, .model = if (model.len > 0 and model[0] == '@') model else modelcfg.defaults.cf_model } };
    if (!chat_engine.tryBeginTurn(app.io, conv)) return false;
    // loop=1: the drive loop carries the turn to a finished answer with nobody there, as a scheduled run does.
    chat_engine.spawnTurn(app, uid, conv, trio, text, 1, false, "", false, false, false); // no Agent Garrett: a job runs with the machine's own tools, as the grant said
    log.info("tot {s}: job started on this machine in conversation {s}", .{ name, conv });
    return true;
}

// ---------------------------------------------------------------------------------- the local folder
//
// Every tot a user deploys gets a folder on this machine, one per deployment ("run"), that this server keeps
// up to date from the runtime: {data}/u<uid>/_tots/<name>-<deployed, UTC>/ holds
//   events.log     one readable line per event (tail it), events.jsonl the same events as the runtime wrote them,
//   status.json    the tot's latest status, notes/   the tot's own notes, one file each,
// and {data}/u<uid>/_tots/scratchpad.md is the scratchpad the account's tots share. The desk's Open folder button
// opens a tot's folder. A pass asks only for what moved (the roster carries each tot's event seq and notes
// revision, and the pad's seq), so an idle tot costs one roster call a minute. A tot that is deleted keeps its
// folder: it is the user's record of the run.

const MIRROR_EVERY_TICKS: u32 = 3; // one mirror pass every third bridge tick (60 s)
const EVENTS_PAGE: u32 = 500;
const PAGES_MAX: usize = 8; // a pass reads at most this many pages per tot; the next pass continues

/// Where one deployment of a tot is mirrored, relative to the data dir: u<uid>/_tots/<name>-<YYYYMMDD-HHMMSS>.
pub fn totFolder(buf: []u8, uid: u64, name: []const u8, created_ms: i64) ?[]const u8 {
    if (!validName(name) or created_ms <= 0) return null;
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(created_ms, 1000)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "u{d}/_tots/{s}-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
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

const RosterTot = struct { name: []const u8 = "", created: i64 = 0, seq: u64 = 0, notes_rev: u64 = 0 };

/// Bring one tot's folder up to date.
fn mirrorTot(app: *App, a: std.mem.Allocator, uid: u64, st: State, h: RosterTot, status: std.json.Value) void {
    var fb: [160]u8 = undefined;
    const rel = totFolder(&fb, uid, h.name, h.created) orelse return;
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
        const path = std.fmt.allocPrint(a, "/v1/tots/{s}/events?after={d}&limit={d}&forward=1", .{ h.name, cur.seq, EVENTS_PAGE }) catch break;
        const raw = totCall(app, a, uid, st, "GET", path, "") orelse break;
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

    // notes: what changed since the newest stamp held; then drop the files of notes the tot deleted
    if (h.notes_rev != cur.notes_rev) notes: {
        var names: []const []const u8 = &.{};
        var pages: usize = 0;
        while (pages < PAGES_MAX) : (pages += 1) {
            const path = std.fmt.allocPrint(a, "/v1/tots/{s}/notes?after={d}", .{ h.name, cur.notes_t }) catch break :notes;
            const raw = totCall(app, a, uid, st, "GET", path, "") orelse break :notes;
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

/// The shared scratchpad as {data}/u<uid>/_tots/scratchpad.md, rewritten when its seq moves.
fn mirrorPad(app: *App, a: std.mem.Allocator, uid: u64, st: State, pad_seq: u64) void {
    const dir = std.fmt.allocPrint(a, "{s}/u{d}/_tots", .{ app.data, uid }) catch return;
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch return;
    var cur = readCursor(app, a, dir);
    if (cur.pad_seq == pad_seq) return;
    const raw = totCall(app, a, uid, st, "GET", "/v1/pad?after=0", "") orelse return;
    const E = struct { seq: u64 = 0, t: i64 = 0, from: []const u8 = "", text: []const u8 = "" };
    const R = struct { ok: bool = false, entries: []const E = &.{} };
    const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch return;
    if (!r.ok) return;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(a, "# Shared scratchpad\n\nWhat the tots of this account leave for each other (and what you add from the desk or `veil --tater pad`). The newest 200 entries, oldest first; rewritten as it changes.\n\n") catch return;
    for (r.entries) |e| {
        var tb: [24]u8 = undefined;
        out.print(a, "## {d}. {s} - {s} UTC\n\n{s}\n\n", .{ e.seq, e.from, stampStr(&tb, e.t), e.text }) catch return;
    }
    const path = std.fmt.allocPrint(a, "{s}/scratchpad.md", .{dir}) catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch return;
    cur.pad_seq = pad_seq;
    writeCursor(app, a, dir, cur);
}

/// One mirror pass for a user: the roster, then each tot's folder, then the scratchpad.
fn mirrorUser(app: *App, a: std.mem.Allocator, uid: u64, st: State) void {
    const raw = totCall(app, a, uid, st, "GET", "/v1/tots", "") orelse return;
    const R = struct { ok: bool = false, pad_seq: u64 = 0, tots: []const std.json.Value = &.{} };
    const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch return;
    if (!r.ok) return;
    for (r.tots) |v| {
        const h = std.json.parseFromValueLeaky(RosterTot, a, v, .{ .ignore_unknown_fields = true }) catch continue;
        if (h.created > 0) mirrorTot(app, a, uid, st, h, v);
    }
    mirrorPad(app, a, uid, st, r.pad_seq);
}

/// A runtime uploaded by an older veil is replaced by this one's when the account is the one it is in. The tots
/// keep their storage; only the code changes.
fn upgradeRuntime(app: *App, a: std.mem.Allocator, uid: u64, st: *State) void {
    var hb: [16]u8 = undefined;
    const source = if (st.runtime_source.len > 0) st.runtime_source else TOT_JS;
    if (st.url.len == 0 or std.mem.eql(u8, st.script_hash, sourceHash(source, &hb))) return;
    const tok = tokOf(app, uid, a) orelse return;
    if (!std.mem.eql(u8, tok.account_id, st.account)) return; // logged into another account: leave that one alone
    // A refused update is not tried again for a quarter of an hour: the tots keep running on what they have.
    const now = nowS(app.io);
    if (now - upgrade_failed_s.load(.monotonic) < 900) return;
    var uploaded = false;
    if (ensureRuntime(app, a, uid, tok, st, &uploaded)) |msg| {
        st.last_error = msg;
        upgrade_failed_s.store(now, .monotonic);
        log.warn("tot runtime for u{d} could not be updated: {s}", .{ uid, msg });
    }
    writeState(app, uid, st.*);
}

var upgrade_failed_s: std.atomic.Value(i64) = .init(0);

/// Tots edit their own shared runtime; this bridge supplies the owner's existing Cloudflare login for upload.
/// No host code is executed, and no local_run grant or proposal/approval gate is involved.
fn syncRuntime(app: *App, a: std.mem.Allocator, uid: u64, st: *State) void {
    const tok = tokOf(app, uid, a) orelse return;
    if (!std.mem.eql(u8, tok.account_id, st.account)) return;
    syncRuntimeAs(app, a, uid, tok, st);
}

fn syncRuntimeAs(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State) void {
    if (!std.mem.eql(u8, tok.account_id, st.account)) return;
    const raw = totCall(app, a, uid, st.*, "GET", "/v1/runtime", "") orelse return;
    const R = struct { ok: bool = false, initialized: bool = false, revision: u64 = 0, status: []const u8 = "", source: []const u8 = "" };
    const r = std.json.parseFromSliceLeaky(R, a, raw, .{ .ignore_unknown_fields = true }) catch return;
    if (!r.ok) return;
    if (!r.initialized) {
        const source = if (st.runtime_source.len > 0) st.runtime_source else TOT_JS;
        const body = std.json.Stringify.valueAlloc(a, .{ .source = source, .revision = st.runtime_revision }, .{}) catch return;
        const seeded = totCall(app, a, uid, st.*, "POST", "/v1/runtime/seed", body) orelse return;
        if (replyOf(a, seeded).ok) {
            // Once the tots own this source, a newer host binary must not swap it out beneath their drafts.
            st.runtime_source = source;
            writeState(app, uid, st.*);
        }
        return;
    }
    if (!std.mem.eql(u8, r.status, "pending")) return;
    var error_text: []const u8 = "";
    // Retry only the acknowledgement after an interrupted sync; do not upload a revision twice.
    if (r.revision != st.runtime_revision) {
        var bb: [8]u8 = undefined;
        app.io.random(&bb);
        const boundary = std.fmt.allocPrint(a, "----veiltotrsi{s}", .{std.fmt.bytesToHex(bb, .lower)}) catch return;
        const ctype = std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary}) catch return;
        const script_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ SCRIPT, .{ app.cf_api_root, tok.account_id }) catch return;
        const body = uploadSourceBody(a, boundary, false, .{ .python = st.python, .browser = st.browser, .neuron = st.neuron }, r.source) catch return;
        const uploaded = api(app, a, "PUT", script_url, body, tok.key, ctype) orelse return;
        error_text = firstError(a, uploaded);
        if (error_text.len == 0) {
            st.runtime_source = r.source;
            st.runtime_revision = r.revision;
            var hb: [16]u8 = undefined;
            st.script_hash = a.dupe(u8, sourceHash(r.source, &hb)) catch return;
            st.last_error = "";
            writeState(app, uid, st.*);
        } else {
            st.last_error = error_text;
            writeState(app, uid, st.*);
        }
    }
    const result = std.json.Stringify.valueAlloc(a, .{ .revision = r.revision, .err = error_text }, .{}) catch return;
    _ = totCall(app, a, uid, st.*, "POST", "/v1/runtime/result", result);
}

/// After an upload that asked for native packages: ask the runtime whether its Python starts. Yes settles it
/// and records what it came up with. No, twice in a row, uploads the Python Worker again with the next smaller
/// set. No answer at all (a new deployment takes a minute) is asked again, PY_CHECKS times at most.
fn checkPython(app: *App, a: std.mem.Allocator, uid: u64, st: *State) void {
    if (st.py_check == 0 or !st.python or st.url.len == 0) return;
    const tok = tokOf(app, uid, a) orelse return;
    if (!std.mem.eql(u8, tok.account_id, st.account)) return;
    checkPythonAs(app, a, uid, tok, st);
}

fn checkPythonAs(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok, st: *State) void {
    st.py_check -= 1;
    defer writeState(app, uid, st.*);
    const raw = totCall(app, a, uid, st.*, "GET", "/v1/python", "") orelse return;
    const Caps = struct { ok: bool = false, python: bool = false, native: []const []const u8 = &.{}, @"error": []const u8 = "" };
    const caps = std.json.parseFromSliceLeaky(Caps, a, raw, .{ .ignore_unknown_fields = true }) catch return;
    if (!caps.ok) return; // not the runtime's answer yet
    if (caps.python) {
        st.py_native = caps.native;
        st.py_check = 0;
        st.py_fails = 0;
        return;
    }
    st.py_fails += 1;
    if (st.py_fails < 2) return;
    st.py_fails = 0;
    if (st.py_rung + 1 >= PY_NATIVE.len) {
        st.py_check = 0;
        return;
    }
    log.warn("tot Python for u{d} does not start with its packages ({s}); uploading it with fewer", .{ uid, caps.@"error" });
    var bb: [8]u8 = undefined;
    app.io.random(&bb);
    const boundary = std.fmt.allocPrint(a, "----veiltot{s}", .{std.fmt.bytesToHex(bb, .lower)}) catch return;
    const ctype = std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary}) catch return;
    const py_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ PY_SCRIPT, .{ app.cf_api_root, st.account }) catch return;
    var why: []const u8 = "";
    const rung = uploadPython(app, a, py_url, tok.key, boundary, ctype, st.py_rung + 1, &why) orelse return;
    st.py_rung = rung;
    st.py_check = if (rung + 1 < PY_NATIVE.len) PY_CHECKS else 0;
}

/// One pass over every user with tots: run the jobs of those allowed onto this machine, and (when `mirror`) bring
/// each tot's local folder up to date, first replacing a runtime an older veil uploaded.
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
        // Admin only, as the routes are: a state file is just a file, and it must not start full-tool turns
        // for an account that could not have deployed a tot.
        const owner = app.auth.userById(uid) orelse continue;
        if (!app.auth.isAdmin(owner)) continue;
        if (mirror) moveIfDue(app, a, uid);
        var st = readState(app, uid, a);
        if (st.url.len == 0) continue;
        if (mirror) {
            upgradeRuntime(app, a, uid, &st);
            syncRuntime(app, a, uid, &st);
            syncGarrett(app, a, uid, &st);
            checkPython(app, a, uid, &st);
            mirrorUser(app, a, uid, st);
        }
        if (backend_on) for (st.local) |name| if (validName(name)) {
            _ = bridgeTot(app, a, uid, st, name);
        };
    }
}

/// The tots thread: for the life of the process, a pass every BRIDGE_EVERY_MS, mirroring every third. A raw thread,
/// so a raw sleep.
pub fn bgLoop(app: *App) void {
    var n: u32 = 0;
    while (true) : (n +%= 1) {
        var slept: u64 = 0;
        while (slept < BRIDGE_EVERY_MS) : (slept += 100) bu.sleepMs(100);
        tick(app, n % MIRROR_EVERY_TICKS == 0);
    }
}

// ---------------------------------------------------------------------------------- runs: every deployment's record

/// The runs a user can look back on: one folder per deployment under {data}/u<uid>/_tots/ (see totFolder), kept
/// after the tot is deleted, plus one for every deployment that failed (recordFailed). The desk lists them beside
/// the live tots, as its chat list keeps every conversation, and reads a run's console from its events.jsonl.
const RUNS_MAX: usize = 60;
const RUN_EVENTS_MAX_BYTES: usize = 16 << 20;

/// A run folder's own name: <tot name>-<YYYYMMDD-HHMMSS>.
pub fn runLeafOk(leaf: []const u8) bool {
    if (leaf.len < 17 or leaf.len > NAME_MAX + 16) return false;
    if (leaf[leaf.len - 16] != '-') return false;
    for (leaf[leaf.len - 15 ..], 0..) |c, i| {
        if (i == 8) {
            if (c != '-') return false;
        } else if (!std.ascii.isDigit(c)) return false;
    }
    return validName(leaf[0 .. leaf.len - 16]);
}

const Run = struct {
    leaf: []const u8,
    folder: []const u8,
    name: []const u8,
    started: []const u8, // YYYYMMDD-HHMMSS, UTC
    state: []const u8 = "",
    @"error": []const u8 = "",
    goal: []const u8 = "",
    model: []const u8 = "",
    events: i64 = 0,
};

fn str(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}

/// The user's runs, newest first, as GET /api/v1/tots/runs answers them.
fn runsJson(app: *App, a: std.mem.Allocator, uid: u64) ![]const u8 {
    var list: std.ArrayListUnmanaged(Run) = .empty;
    const dpath = try std.fmt.allocPrint(a, "{s}/u{d}/_tots", .{ app.data, uid });
    if (std.Io.Dir.cwd().openDir(app.io, dpath, .{ .iterate = true })) |dir_| {
        var dir = dir_;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |ent| {
            if (ent.kind != .directory or !runLeafOk(ent.name)) continue;
            const hidden = try std.fmt.allocPrint(a, "{s}/{s}/.hidden", .{ dpath, ent.name });
            if (std.Io.Dir.cwd().access(app.io, hidden, .{})) |_| continue else |_| {}
            const leaf = try a.dupe(u8, ent.name);
            var run: Run = .{ .leaf = leaf, .folder = try std.fmt.allocPrint(a, "u{d}/_tots/{s}", .{ uid, leaf }), .name = leaf[0 .. leaf.len - 16], .started = leaf[leaf.len - 15 ..] };
            const sp = try std.fmt.allocPrint(a, "{s}/{s}/status.json", .{ dpath, leaf });
            if (std.Io.Dir.cwd().readFileAlloc(app.io, sp, a, .limited(512 << 10))) |raw| {
                const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch std.json.Value{ .null = {} };
                if (v == .object) {
                    const o = v.object;
                    run.state = str(o.get("state"));
                    run.@"error" = str(o.get("error"));
                    run.model = str(o.get("model"));
                    if (o.get("goal")) |g| if (g == .object) {
                        run.goal = str(g.object.get("text"));
                    };
                    if (o.get("seq")) |s| if (s == .integer) {
                        run.events = s.integer;
                    };
                }
            } else |_| {}
            try list.append(a, run);
        }
    } else |_| {}
    const Order = struct {
        fn newer(_: void, x: Run, y: Run) bool {
            const o = std.mem.order(u8, x.started, y.started);
            return if (o == .eq) std.mem.lessThan(u8, x.name, y.name) else o == .gt;
        }
    };
    std.mem.sort(Run, list.items, {}, Order.newer);
    const runs = list.items[0..@min(list.items.len, RUNS_MAX)];
    return std.json.Stringify.valueAlloc(a, .{ .ok = true, .runs = runs }, .{});
}

/// A run's events from its events.jsonl, as the runtime's own events route answers: the newest `limit` past
/// `after`, oldest first - or, `forward`, the first `limit` past `after` (what `veil --tater verify` walks, from
/// the run's first event on). A run with no file yet has no events.
fn runEventsJson(app: *App, a: std.mem.Allocator, uid: u64, leaf: []const u8, after: u64, limit: u64, forward: bool) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}/u{d}/_tots/{s}/events.jsonl", .{ app.data, uid, leaf });
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(RUN_EVENTS_MAX_BYTES)) catch "";
    const Seq = struct { seq: u64 = 0 };
    var top: u64 = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        const s = std.json.parseFromSliceLeaky(Seq, a, ln, .{ .ignore_unknown_fields = true }) catch continue;
        top = @max(top, s.seq);
    }
    const floor = if (forward) after else @max(after, if (top > limit) top - limit else 0);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "{\"ok\":true,\"events\":[");
    var first = true;
    var count: u64 = 0;
    it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        const s = std.json.parseFromSliceLeaky(Seq, a, ln, .{ .ignore_unknown_fields = true }) catch continue;
        if (s.seq <= floor) continue;
        if (forward and count >= limit) break;
        if (!first) try out.append(a, ',');
        try out.appendSlice(a, ln);
        first = false;
        count += 1;
    }
    try out.appendSlice(a, "]}");
    return out.items;
}

/// GET /api/v1/tots/runs — every deployment this user made that the veil keeps a folder for, newest first.
pub fn listRuns(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const body = try runsJson(app, arena.allocator(), u.id);
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, body);
}

/// GET /api/v1/tots/runs/:run/events?after=N&limit=M — one run's events, from its folder on this machine.
pub fn runEvents(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const leaf = req.param("run") orelse "";
    if (!runLeafOk(leaf)) return badReq(res, "bad run name");
    const q = try req.query();
    const after = std.fmt.parseInt(u64, q.get("after") orelse "0", 10) catch 0;
    const limit = std.math.clamp(std.fmt.parseInt(u64, q.get("limit") orelse "200", 10) catch 200, 1, 2000);
    const forward = std.mem.eql(u8, q.get("forward") orelse "0", "1");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const body = try runEventsJson(app, arena.allocator(), u.id, leaf, after, limit, forward);
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, body);
}

/// Remove a saved run from history. Its events, notes and status stay in its folder for recovery.
fn hideRun(app: *App, a: std.mem.Allocator, uid: u64, leaf: []const u8) !void {
    if (!runLeafOk(leaf)) return error.BadRunName;
    const path = try std.fmt.allocPrint(a, "{s}/u{d}/_tots/{s}", .{ app.data, uid, leaf });
    var dir = try std.Io.Dir.cwd().openDir(app.io, path, .{});
    defer dir.close(app.io);
    try dir.writeFile(app.io, .{ .sub_path = ".hidden", .data = "Removed from run history. Remove this marker to restore the entry.\n" });
}

pub fn deleteRun(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const leaf = req.param("run") orelse "";
    if (!runLeafOk(leaf)) return badReq(res, "bad run name");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    hideRun(app, arena.allocator(), u.id, leaf) catch |err| {
        if (err == error.FileNotFound) {
            res.status = 404;
            return res.json(.{ .ok = false, .err = "saved run not found" }, .{});
        }
        return http.serverErr(res, "could not remove this run from history; its files are unchanged");
    };
    try res.json(.{ .ok = true, .removed = leaf, .files_preserved = true }, .{});
}

/// A deployment that failed, kept as a run of its own: its folder holds what was asked and why it failed, so the
/// desk can open it like any other run. The run's name, or null when the folder could not be written.
fn recordFailed(app: *App, a: std.mem.Allocator, uid: u64, body: CreateReq, msg: []const u8) ?[]const u8 {
    const now_ms = std.Io.Timestamp.now(app.io, .real).toMilliseconds();
    const want = std.mem.trim(u8, body.name, " \r\n\t");
    const name = if (validName(want)) want else "unnamed";
    var fb: [160]u8 = undefined;
    const rel = totFolder(&fb, uid, name, now_ms) orelse return null;
    const dir = std.fmt.allocPrint(a, "{s}/{s}", .{ app.data, rel }) catch return null;
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch return null;
    const goal = std.mem.trim(u8, body.goal, " \r\n\t");
    const model = if (body.model.len > 0) body.model else modelcfg.defaults.cf_model;
    const asked = std.fmt.allocPrint(a, "deploying {s} on {s}: {s}", .{ name, model, if (goal.len > 0) goal else "(no goal; its charter)" }) catch return null;
    const failed = std.fmt.allocPrint(a, "deployment failed: {s}", .{msg}) catch return null;
    const Status = struct { name: []const u8, state: []const u8 = "failed", @"error": []const u8, goal: struct { text: []const u8 }, model: []const u8, created: i64, seq: i64 = 2 };
    const status = std.json.Stringify.valueAlloc(a, Status{ .name = name, .@"error" = msg, .goal = .{ .text = goal }, .model = model, .created = now_ms }, .{ .whitespace = .indent_2 }) catch return null;
    const E = struct { seq: u64, t: i64, kind: []const u8, text: []const u8, brief: []const u8, ok: bool };
    const e1 = std.json.Stringify.valueAlloc(a, E{ .seq = 1, .t = now_ms, .kind = "status", .text = asked, .brief = asked[0..@min(asked.len, 180)], .ok = true }, .{}) catch return null;
    const e2 = std.json.Stringify.valueAlloc(a, E{ .seq = 2, .t = now_ms, .kind = "error", .text = failed, .brief = failed[0..@min(failed.len, 180)], .ok = false }, .{}) catch return null;
    var log_: std.ArrayListUnmanaged(u8) = .empty;
    logLine(a, &log_, .{ .seq = 1, .t = now_ms, .kind = "status", .text = asked }) catch return null;
    logLine(a, &log_, .{ .seq = 2, .t = now_ms, .kind = "error", .text = failed }) catch return null;
    const files = [_][2][]const u8{
        .{ "status.json", status },
        .{ "events.jsonl", std.fmt.allocPrint(a, "{s}\n{s}\n", .{ e1, e2 }) catch return null },
        .{ "events.log", log_.items },
    };
    for (files) |f| {
        const p = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, f[0] }) catch return null;
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = p, .data = f[1] }) catch return null;
    }
    return a.dupe(u8, rel[std.mem.lastIndexOfScalar(u8, rel, '/').? + 1 ..]) catch null; // `rel` lives in this frame
}

/// Mark a run's status.json with how it ended ("deleted"), keeping everything else it says.
fn markEnded(app: *App, a: std.mem.Allocator, rel: []const u8, how: []const u8) void {
    const p = std.fmt.allocPrint(a, "{s}/{s}/status.json", .{ app.data, rel }) catch return;
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, p, a, .limited(512 << 10)) catch return;
    var v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return;
    if (v != .object) return;
    v.object.put(a, "state", .{ .string = how }) catch return;
    v.object.put(a, "ended", .{ .integer = std.Io.Timestamp.now(app.io, .real).toMilliseconds() }) catch return;
    const out = std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 }) catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = p, .data = out }) catch {};
}

// ---------------------------------------------------------------------------------- the move from hots

/// Until 1.1.8 a tot was called a hot. Its runtime is the Worker "veil-hots" (with "veil-hots-py"), the state file
/// cf_hots.json and the folder _hots. The first time this server finds that state for a user logged in to the same
/// Cloudflare account, it moves them: each hot is created again as a tot with the same name, goal, settings,
/// owner's-machine grant and files; the scratchpad's entries come across; and only then are the old Workers
/// removed, so nothing keeps running in the account under the old name. Lessons, facts and stances stay behind
/// (the old runtime has no route that gives them out), and each tot's first event says so.
const LEGACY_STATE_FILE = "cf_hots.json";
const LEGACY_SCRIPT = "veil-hots";
const LEGACY_PY_SCRIPT = "veil-hots-py";
const LEGACY_FOLDER = "_hots";
const LEGACY_TOKEN_LABEL = "veil-hot-token";
/// The goal a moved hot gets when it had neither an active goal nor a charter.
const MOVED_GOAL = "pick up where you left off: find the most valuable next thing to do for your human, and do it";
/// The most a single import call carries; a tot's files go across in as many calls as they need.
const IMPORT_BATCH: usize = 256 << 10;

fn legacyPath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ LEGACY_STATE_FILE, .{ app.data, uid }) catch null;
}

/// The old state, or null when there is nothing to move.
fn readLegacy(app: *App, uid: u64, a: std.mem.Allocator) ?State {
    var pb: [700]u8 = undefined;
    const path = legacyPath(app, uid, &pb) orelse return null;
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(64 << 10)) catch return null;
    return std.json.parseFromSliceLeaky(State, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch State{};
}

fn writeLegacy(app: *App, uid: u64, st: State) void {
    var db: [700]u8 = undefined;
    if (std.fmt.bufPrint(&db, "{s}/u{d}", .{ app.data, uid })) |dir| {
        _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    } else |_| {}
    var pb: [700]u8 = undefined;
    const path = legacyPath(app, uid, &pb) orelse return;
    const json = std.json.Stringify.valueAlloc(app.gpa, st, .{ .whitespace = .indent_1 }) catch return;
    defer app.gpa.free(json);
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = json }) catch {};
}

/// One call to the old runtime, with the token it was given (the old label, the same server key).
fn legacyCall(app: *App, a: std.mem.Allocator, uid: u64, old: State, method: []const u8, path: []const u8, body: []const u8) ?[]u8 {
    if (!allowedUrl(app, old.url)) return null;
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ old.url, path }) catch return null;
    var tb: [64]u8 = undefined;
    const token = tokenWith(app, LEGACY_TOKEN_LABEL, uid, old.account, old.token_gen, &tb);
    return api(app, a, method, url, body, token, if (body.len > 0) "application/json" else "");
}

const LegacyGoal = struct { text: []const u8 = "", status: []const u8 = "", forever: bool = false, budget: ?i64 = null };
const LegacyHot = struct {
    name: []const u8 = "",
    model: []const u8 = "",
    pace_s: ?i64 = null,
    size: ?i64 = null,
    daily_calls: ?i64 = null,
    charter: []const u8 = "",
    paused: bool = false,
    goal: ?LegacyGoal = null,
};
const Note = struct { name: []const u8 = "", t: i64 = 0, text: []const u8 = "" };

/// What a moved hot is created with: its own settings, its goal while that was active, else its charter alone.
fn movedReq(h: LegacyHot, local: []const []const u8) CreateReq {
    var r: CreateReq = .{ .name = h.name, .charter = h.charter, .model = h.model, .pace_s = h.pace_s, .size = h.size, .daily_calls = h.daily_calls };
    if (h.goal) |g| if (std.mem.eql(u8, g.status, "active") and g.text.len >= 3) {
        r.goal = g.text;
        r.forever = g.forever;
        r.budget = g.budget;
    };
    if (r.goal.len < 3 and std.mem.trim(u8, r.charter, " \r\n\t").len < 3) r.goal = MOVED_GOAL;
    for (local) |n| if (std.ascii.eqlIgnoreCase(n, h.name)) {
        r.local = true;
    };
    return r;
}

/// Move a user's hots to tots (see LEGACY_STATE_FILE). Null when there was nothing to move or it is done; the
/// reason otherwise, and then nothing was removed and the next attempt starts over where this one stopped.
fn moveFromHots(app: *App, a: std.mem.Allocator, uid: u64, tok: Tok) ?[]const u8 {
    var old = readLegacy(app, uid, a) orelse return null;
    if (old.account.len > 0 and !std.mem.eql(u8, old.account, tok.account_id))
        return "the hots run in another Cloudflare account than the one logged in; log in to that one to move them";

    if (old.url.len > 0 and !old.moved) {
        // What the old runtime holds. No answer at all is a reason to come back later; an answer that is not its
        // JSON (a Worker removed by hand: Cloudflare's own page) means there is nothing left to carry.
        const roster_raw = legacyCall(app, a, uid, old, "GET", "/v1/hots", "") orelse return "the hots' runtime did not answer";
        const R = struct { ok: bool = false, hots: []const LegacyHot = &.{} };
        const roster = std.json.parseFromSliceLeaky(R, a, roster_raw, .{ .ignore_unknown_fields = true }) catch R{};
        const hots = if (roster.ok) roster.hots else &.{};

        for (hots) |h| {
            if (!validName(h.name) or h.model.len == 0 or h.model[0] != '@') continue;
            // its files, every page of them
            var notes: std.ArrayListUnmanaged(Note) = .empty;
            var after: i64 = 0;
            var pages: usize = 0;
            while (pages < 40) : (pages += 1) {
                const path = std.fmt.allocPrint(a, "/v1/hots/{s}/notes?after={d}", .{ h.name, after }) catch return "out of memory";
                const raw = legacyCall(app, a, uid, old, "GET", path, "") orelse return "the hots' runtime did not answer";
                const N = struct { ok: bool = false, notes: []const Note = &.{}, more: bool = false };
                const n = std.json.parseFromSliceLeaky(N, a, raw, .{ .ignore_unknown_fields = true }) catch break;
                if (!n.ok) break;
                notes.appendSlice(a, n.notes) catch return "out of memory";
                if (n.notes.len == 0 or !n.more) break;
                after = n.notes[n.notes.len - 1].t;
            }
            // the tot, unless an earlier attempt already made it
            switch (deploy(app, a, uid, tok, movedReq(h, old.local))) {
                .ok => {},
                .err => |msg| if (std.ascii.indexOfIgnoreCase(msg, "already exists") == null) return msg,
            }
            const st = readState(app, uid, a);
            const ipath = std.fmt.allocPrint(a, "/v1/tots/{s}/import", .{h.name}) catch return "out of memory";
            var i: usize = 0;
            while (true) {
                // a batch of files under IMPORT_BATCH (at least one); the last batch carries the pause
                var j = i;
                var bytes: usize = 0;
                while (j < notes.items.len and (j == i or bytes + notes.items[j].text.len < IMPORT_BATCH)) : (j += 1) bytes += notes.items[j].text.len;
                const last = j >= notes.items.len;
                const Imp = struct { notes: []const Note, paused: bool, from: []const u8 };
                const body = std.json.Stringify.valueAlloc(a, Imp{ .notes = notes.items[i..j], .paused = last and h.paused, .from = LEGACY_SCRIPT }, .{}) catch return "out of memory";
                const r = totCall(app, a, uid, st, "POST", ipath, body) orelse return "the tot runtime did not answer";
                if (!replyOf(a, r).ok) return explain(a, "carrying a hot's files across", replyOf(a, r).err);
                if (last) break;
                i = j;
            }
        }

        // the scratchpad, once
        if (legacyCall(app, a, uid, old, "GET", "/v1/pad?after=0", "")) |raw| {
            const P = struct { ok: bool = false, entries: []const std.json.Value = &.{} };
            const p = std.json.parseFromSliceLeaky(P, a, raw, .{ .ignore_unknown_fields = true }) catch P{};
            if (p.ok and p.entries.len > 0) {
                const st = readState(app, uid, a);
                const Pi = struct { entries: []const std.json.Value };
                const body = std.json.Stringify.valueAlloc(a, Pi{ .entries = p.entries }, .{}) catch return "out of memory";
                const r = totCall(app, a, uid, st, "POST", "/v1/pad/import", body) orelse return "the tot runtime did not answer";
                if (!replyOf(a, r).ok) return explain(a, "carrying the scratchpad across", replyOf(a, r).err);
            }
        } else return "the hots' runtime did not answer";
        old.moved = true;
        writeLegacy(app, uid, old);
    }

    // Everything is across: the old Workers go.
    if (old.url.len > 0) {
        const acct = if (old.account.len > 0) old.account else tok.account_id;
        const url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ LEGACY_SCRIPT ++ "?force=true", .{ app.cf_api_root, acct }) catch return "out of memory";
        const raw = api(app, a, "DELETE", url, "", tok.key, "") orelse return "could not reach the Cloudflare API to remove the old veil-hots Worker";
        const msg = firstError(a, raw);
        if (msg.len > 0 and std.ascii.indexOfIgnoreCase(msg, "not found") == null and std.ascii.indexOfIgnoreCase(msg, "does not exist") == null)
            return explain(a, "removing the old veil-hots Worker", msg);
        const py_url = std.fmt.allocPrint(a, "{s}/accounts/{s}/workers/scripts/" ++ LEGACY_PY_SCRIPT ++ "?force=true", .{ app.cf_api_root, acct }) catch return "out of memory";
        _ = api(app, a, "DELETE", py_url, "", tok.key, "");
    }

    // The local folders come along under the new name, unless that name is taken already.
    const from = std.fmt.allocPrint(a, "{s}/u{d}/" ++ LEGACY_FOLDER, .{ app.data, uid }) catch return "out of memory";
    const to = std.fmt.allocPrint(a, "{s}/u{d}/_tots", .{ app.data, uid }) catch return "out of memory";
    if (std.Io.Dir.cwd().access(app.io, to, .{})) |_| {} else |_| {
        std.Io.Dir.rename(std.Io.Dir.cwd(), from, std.Io.Dir.cwd(), to, app.io) catch {};
    }
    var pb: [700]u8 = undefined;
    if (legacyPath(app, uid, &pb)) |p| std.Io.Dir.cwd().deleteFile(app.io, p) catch {};
    log.info("the hots of u{d} are tots now; the veil-hots Worker is removed", .{uid});
    return null;
}

var move_failed_s: std.atomic.Value(i64) = .init(0);

/// The move, from the background pass: a failed attempt waits a quarter of an hour before the next.
fn moveIfDue(app: *App, a: std.mem.Allocator, uid: u64) void {
    var pb: [700]u8 = undefined;
    const path = legacyPath(app, uid, &pb) orelse return;
    std.Io.Dir.cwd().access(app.io, path, .{}) catch return;
    const now = nowS(app.io);
    if (now - move_failed_s.load(.monotonic) < 900) return;
    const tok = tokOf(app, uid, a) orelse return;
    if (moveFromHots(app, a, uid, tok)) |msg| {
        move_failed_s.store(now, .monotonic);
        if (readLegacy(app, uid, a)) |old| {
            var o = old;
            o.last_error = msg;
            writeLegacy(app, uid, o);
        }
        log.warn("the hots of u{d} could not be moved to tots yet: {s}", .{ uid, msg });
    }
}

// ---------------------------------------------------------------------------
// tests — see harness/TESTING.md. The Cloudflare API and the runtime are one fakehttp stand-in; the runtime's own
// behaviour is tested where it runs (cloud/tot.test.mjs, under node).
// ---------------------------------------------------------------------------

const tt = std.testing;

fn curlRuns(gpa: std.mem.Allocator, io: std.Io) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "curl", "--version" }, .stdout_limit = .limited(16 << 10) }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

test "every tot route is gated: an anonymous caller gets 401 and nothing runs" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftot-gate-tmp");
    defer ta.deinit();
    inline for (.{ listTots, createTot, deleteTot, teardown, totEvents, totCommand, totConfig, padRead, padWrite, padClear, setKey, setLimit, listRuns, runEvents, deleteRun }) |h| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.param("name", "Gary");
        web.param("run", "Gary-20261002-090000");
        web.json(.{ .goal = "watch the tide tables", .text = "/pause" });
        try h(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
}

test "the runtime and this server agree: the limit, the primary's name, the goal loop's stop rules, the default model" {
    const goal = @import("../worker/chat/goal.zig");
    var b: [96]u8 = undefined;
    try tt.expect(std.mem.indexOf(u8, TOT_JS, try std.fmt.bufPrint(&b, "export const DEFAULT_MAX_TOTS = {d};", .{DEFAULT_MAX_TOTS})) != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, try std.fmt.bufPrint(&b, "export const MAX_TOTS_CEIL = {d};", .{MAX_TOTS_CEIL})) != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, "export const PRIMARY = \"" ++ PRIMARY ++ "\";") != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, try std.fmt.bufPrint(&b, "export const PLATEAU = {d};", .{goal.PLATEAU})) != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, try std.fmt.bufPrint(&b, "export const BUDGET_DEFAULT = {d};", .{goal.BUDGET_DEFAULT})) != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, try std.fmt.bufPrint(&b, "model: \"{s}\",", .{modelcfg.defaults.cf_model})) != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, "export class Tot ") != null); // the class the upload's binding names
    try tt.expectEqual(@as(u32, 24), DEFAULT_MAX_TOTS);
    // the owner's limit: unset is the default, a set one is held to the ceiling, and it rides every deployment
    try tt.expectEqual(@as(u32, 24), limitOf(.{}));
    try tt.expectEqual(@as(u32, 60), limitOf(.{ .max_tots = 60 }));
    try tt.expectEqual(MAX_TOTS_CEIL, limitOf(.{ .max_tots = 5000 }));
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const sent = sentJson(arena.allocator(), .{ .req = .{ .goal = "map the harbour" }, .text_max = 2000, .max_tots = 60 }).?;
    try tt.expect(std.mem.endsWith(u8, sent, ",\"text_max\":2000,\"max_tots\":60}"));
    try tt.expectEqualStrings("Gary", PRIMARY);
}

test "names: the rule a URL segment and a conversation id both need" {
    try tt.expect(validName("Gary") and validName("ada-2") and validName("a_b"));
    try tt.expect(!validName("") and !validName("9lives") and !validName("a b") and !validName("a/b") and !validName("pad?x"));
    try tt.expect(!validName("a" ** 25) and validName("a" ** 24));
    var cb: [64]u8 = undefined;
    try tt.expectEqualStrings("tot_gary_j12_1790000000", jobConv(&cb, "Gary", .{ .id = "j12", .t = 1790000000123 }).?);
    try tt.expect(jobConv(&cb, "Gary", .{ .id = "../x", .t = 1 }) == null);
    try tt.expect(jobConv(&cb, "Gary", .{ .id = "", .t = 1 }) == null);
    // the longest name and id still fit a conversation id (64)
    try tt.expect(jobConv(&cb, "a" ** 24, .{ .id = "j12345678901", .t = 9_999_999_999_999 }).?.len <= 64);
}

test "the runtime's token is derived, never stored: stable for one user+account+generation, different for any other" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    var ta = try http.testApp(gpa, threaded.io(), "zig-cftot-token-tmp");
    defer ta.deinit();
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    try tt.expectEqualStrings(totToken(&ta.app, 1, "acct", 0, &a), totToken(&ta.app, 1, "acct", 0, &b));
    for (a) |c| try tt.expect(std.ascii.isHex(c));
    try tt.expect(!std.mem.eql(u8, totToken(&ta.app, 1, "acct", 0, &a), totToken(&ta.app, 2, "acct", 0, &b)));
    try tt.expect(!std.mem.eql(u8, totToken(&ta.app, 1, "acct", 0, &a), totToken(&ta.app, 1, "acct2", 0, &b)));
    try tt.expect(!std.mem.eql(u8, totToken(&ta.app, 1, "acct", 0, &a), totToken(&ta.app, 1, "acct", 1, &b)));
    ta.app.server_key = [_]u8{0x11} ** 32;
    try tt.expect(!std.mem.eql(u8, &a, totToken(&ta.app, 1, "acct", 0, &b)));
}

test "the token only goes to a workers.dev address, or to loopback while the API itself is a loopback stand-in" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    var ta = try http.testApp(gpa, threaded.io(), "zig-cftot-url-tmp");
    defer ta.deinit();
    const app = &ta.app;
    try tt.expect(allowedUrl(app, "https://veil-tots.acme.workers.dev"));
    try tt.expect(!allowedUrl(app, "http://veil-tots.acme.workers.dev")); // not https
    try tt.expect(!allowedUrl(app, "https://veil-tots.acme.workers.dev.evil.example"));
    try tt.expect(!allowedUrl(app, "https://evil.example/x.workers.dev"));
    try tt.expect(!allowedUrl(app, "https://user@veil-tots.acme.workers.dev"));
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
    try tt.expectEqualStrings("https://veil-tots.acme.workers.dev", runtimeUrl(app, arena.allocator(), "acme").?);
}

test "the upload carries the bindings and keeps the secret; the class migration rides only a first upload" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try uploadBody(a, "----b", true, .{ .python = true, .browser = true, .neuron = true });
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
    try tt.expectEqualStrings("tot.js", m.main_module);
    try tt.expectEqual(@as(usize, 4), m.bindings.len);
    try tt.expectEqualStrings("service", m.bindings[2].type);
    try tt.expectEqualStrings(PY_SCRIPT, m.bindings[2].service);
    try tt.expectEqualStrings("browser", m.bindings[3].type);
    const again_meta = again[0..std.mem.indexOf(u8, again, "Content-Type: application/javascript+module").?];
    try tt.expect(std.mem.indexOf(u8, again_meta, "\"service\"") == null and std.mem.indexOf(u8, again_meta, "\"browser\"") == null);
    // the Python Worker: the flag that makes a .py module a Worker, and the module as Python
    const py = try pyUploadBody(a, "----b", PY_NATIVE[0]);
    // the native packages ride as empty modules of the requirement type; the plain upload names none
    try tt.expect(std.mem.indexOf(u8, py, "name=\"numpy\"; filename=\"numpy\"\r\nContent-Type: text/x-python-requirement\r\n\r\n\r\n--") != null);
    try tt.expect(std.mem.indexOf(u8, try pyUploadBody(a, "----b", PY_NATIVE[PY_NATIVE.len - 1]), "x-python-requirement") == null);
    try tt.expectEqual(@as(usize, 0), PY_NATIVE[PY_NATIVE.len - 1].len);
    try tt.expect(std.mem.indexOf(u8, py, "\"compatibility_flags\":[\"python_workers\"]") != null);
    try tt.expect(std.mem.indexOf(u8, py, "Content-Type: text/x-python\r\n\r\n" ++ TOT_PY) != null);
    try tt.expect(std.mem.indexOf(u8, TOT_PY, "class Default(WorkerEntrypoint):") != null);
    try tt.expectEqualStrings("ai", m.bindings[0].type);
    try tt.expectEqualStrings("Tot", m.bindings[1].class_name);
    try tt.expectEqualStrings("secret_text", m.keep_bindings[0]);
    try tt.expectEqualStrings("Tot", m.migrations.?.new_sqlite_classes[0]);
    try tt.expect(std.mem.indexOf(u8, again, "migrations") == null);
    try tt.expect(std.mem.indexOf(u8, first, TOT_JS) != null);
    try tt.expect(std.mem.endsWith(u8, first, "\r\n------b--\r\n"));
    // the mind: both modules under the names tot.js imports, the engine as WebAssembly; neither when not asked for
    try tt.expect(std.mem.indexOf(u8, TOT_JS, "const NEURON_WASM = \"./neuron_core.wasm\";") != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, "const NEURON_BINDING = \"./neuron-db.mjs\";") != null);
    try tt.expect(std.mem.indexOf(u8, first, "name=\"neuron-db.mjs\"; filename=\"neuron-db.mjs\"\r\nContent-Type: application/javascript+module\r\n\r\n" ++ NEURON_MJS) != null);
    try tt.expect(std.mem.indexOf(u8, first, "name=\"neuron_core.wasm\"; filename=\"neuron_core.wasm\"\r\nContent-Type: application/wasm\r\n\r\n" ++ NEURON_WASM) != null);
    try tt.expect(std.mem.startsWith(u8, NEURON_WASM, "\x00asm"));
    try tt.expect(std.mem.indexOf(u8, again, "application/wasm") == null);
    try tt.expectEqualStrings("BRAVE_KEY", keySecret("Brave").?);
    try tt.expectEqualStrings("GOOGLE_CSE_CX", keySecret("google_cx").?);
    try tt.expect(keySecret("TOT_TOKEN") == null); // the runtime's own token is not a key anyone sets
    try tt.expect(std.mem.indexOf(u8, first, "TOT_TOKEN\",\"text\"") == null); // no secret in a body that rides a file
}

/// The stand-in's answers: the Cloudflare API on /client/v4, the runtime on /v1.
const StandIn = struct {
    const w = fakehttp.wire;
    const ok = w("{\"success\":true,\"errors\":[],\"result\":{}}");
    const subdomain = w("{\"success\":true,\"errors\":[],\"result\":{\"subdomain\":\"acme\"}}");
    const no_script = w("{\"success\":false,\"errors\":[{\"code\":10007,\"message\":\"This Worker does not exist on your account.\"}]}");
    const no_browser = w("{\"success\":false,\"errors\":[{\"code\":10021,\"message\":\"Browser Rendering is not enabled for this account.\"}]}");
    const made = w("{\"ok\":true,\"tot\":{\"name\":\"Gary\",\"state\":\"working\",\"local\":true}}");
    const full = w("{\"ok\":false,\"err\":\"this account already has 3 tots (the limit); delete one first\"}");
    // Agent Garrett: what the runtime's pad says, and what "the repo" serves - its wrangler.toml (as the agent's
    // reads today, tables the launcher passes over included), GitHub's listing of src/, and the modules
    const garrett_pending = w("{\"ok\":true,\"status\":\"pending\",\"asked_by\":\"Gary\",\"asked_at\":1}");
    const garrett_deployed = w("{\"ok\":true,\"status\":\"deployed\"}");
    const toml_body =
        \\name = "garrettstimpson-agent"
        \\main = "src/index.js"
        \\compatibility_date = "2026-09-03"
        \\compatibility_flags = ["global_fetch_strictly_public"]
        \\
        \\[[rules]]
        \\type = "CompiledWasm"
        \\globs = ["**/*.wasm"]
        \\fallthrough = true
        \\
        \\[ai]
        \\binding = "AI"
        \\
        \\[vars]
        \\LLMS_URL  = "https://raw.githubusercontent.com/gary23w/garrettstimpson.ca/refs/heads/main/llms.txt"
        \\SITE_NAME = "Garrett Stimpson Security Research"
        \\CTF_SAFE_MODE = "true"
        \\CTF_REQUIRE_CONFIRM = "true"
        \\AGENT_ALLOW_ACTIVE_TOOLS = "false"
        \\MCP_ALLOW_ACTIVE_TOOLS = "false"
        \\MCP_ALLOW_DARKWEB = "false" # over MCP
        \\
        \\[[durable_objects.bindings]]
        \\name = "DISCLOSURE_LIMITER"
        \\class_name = "DisclosureLimiter"
        \\
        \\[[durable_objects.bindings]]
        \\name = "LOGIN_LIMITER"
        \\class_name = "LoginLimiter"
        \\
        \\[[durable_objects.bindings]]
        \\name = "AUTH_SESSIONS"
        \\class_name = "AuthSession"
        \\
        \\[[migrations]]
        \\tag = "security-limiters-v1"
        \\new_sqlite_classes = ["DisclosureLimiter", "LoginLimiter", "AuthSession"]
        \\
        \\[triggers]
        \\crons = ["0 7 * * *"]
        \\
        \\[[services]]
        \\binding = "GARY_RUNTIME"
        \\service = "garrettstimpson-gary"
        \\entrypoint = "GaryBackend"
        \\
    ;
    const toml = w(toml_body);
    const list_body = "[{\"name\":\"index.js\",\"path\":\"agent/src/index.js\",\"type\":\"file\",\"size\":120},{\"name\":\"mcp.mjs\",\"path\":\"agent/src/mcp.mjs\",\"type\":\"file\",\"size\":20},{\"name\":\"harness.mjs\",\"path\":\"agent/src/harness.mjs\",\"type\":\"file\",\"size\":20},{\"name\":\"neuron-db.mjs\",\"path\":\"agent/src/neuron-db.mjs\",\"type\":\"file\",\"size\":20},{\"name\":\"neuron_core.wasm\",\"path\":\"agent/src/neuron_core.wasm\",\"type\":\"file\",\"size\":8},{\"name\":\".gitkeep\",\"path\":\"agent/src/.gitkeep\",\"type\":\"file\",\"size\":0}]";
    const list = w(list_body);
    const src_index_body = "// Agent Garrett\nimport { handleMcpRequest } from './mcp.mjs';\nexport default { async fetch(request, env) { return new Response('ok'); } };\n";
    const src_mjs_body = "export const x = 1;\n";
    const src_wasm_body = "\x00asm\x01\x00\x00\x00";
    const src_index = w(src_index_body);
    const src_mjs = w(src_mjs_body);
    const src_wasm = w(src_wasm_body);
};

test "Agent Garrett's upload is made from its repo's wrangler.toml: its bindings, policy and flags, the full gary runtime bound, no secret in the body, every module typed, the engine as WebAssembly" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the toml as the agent ships it: what the launcher reads, and what it passes over
    const cfg = parseGarrettToml(a, StandIn.toml_body);
    try tt.expectEqualStrings("src/index.js", cfg.main);
    try tt.expectEqualStrings("src", cfg.mainDir());
    try tt.expectEqualStrings("index.js", cfg.mainModule());
    try tt.expectEqualStrings("2026-09-03", cfg.compat_date);
    try tt.expectEqual(@as(usize, 1), cfg.flags.len);
    try tt.expectEqualStrings("global_fetch_strictly_public", cfg.flags[0]);
    try tt.expectEqualStrings("AI", cfg.ai);
    try tt.expectEqual(@as(usize, 3), cfg.dos.len);
    try tt.expectEqualStrings("LOGIN_LIMITER", cfg.dos[1].name);
    try tt.expectEqualStrings("AuthSession", cfg.dos[2].class);
    try tt.expectEqualStrings("security-limiters-v1", cfg.tag);
    try tt.expectEqual(@as(usize, 3), cfg.sqlite_classes.len);
    try tt.expectEqual(@as(usize, 0), cfg.classes.len);
    try tt.expectEqual(@as(usize, 7), cfg.vars.len);
    try tt.expectEqualStrings("false", cfg.vars[6].text); // a trailing comment is not part of the value
    // a toml with none of it still makes a launchable config
    const bare = parseGarrettToml(a, "name = \"x\"\n");
    try tt.expectEqualStrings("src/index.js", bare.main);
    try tt.expectEqualStrings(GARRETT_COMPAT_DATE, bare.compat_date);
    try tt.expectEqual(@as(usize, 0), bare.dos.len);

    const mods = [_]GarrettModule{
        .{ .name = "index.js", .data = "export default {}", .ctype = moduleType("index.js") },
        .{ .name = "harness.mjs", .data = "export const h = 1;", .ctype = moduleType("harness.mjs") },
        .{ .name = "neuron_core.wasm", .data = "\x00asm\x01\x00\x00\x00", .ctype = moduleType("neuron_core.wasm") },
    };
    const first = try garrettUploadBody(a, "----b", true, cfg, &mods);
    const again = try garrettUploadBody(a, "----b", false, cfg, &mods);
    const meta_at = std.mem.indexOf(u8, first, "\r\n\r\n").? + 4;
    const meta = first[meta_at .. meta_at + std.mem.indexOf(u8, first[meta_at..], "\r\n").?];
    const M = struct {
        main_module: []const u8,
        compatibility_date: []const u8,
        compatibility_flags: []const []const u8 = &.{},
        bindings: []const struct { type: []const u8, name: []const u8, class_name: []const u8 = "", text: []const u8 = "", service: []const u8 = "", entrypoint: []const u8 = "" },
        keep_bindings: []const []const u8,
        migrations: ?struct { new_tag: []const u8, new_sqlite_classes: []const []const u8 } = null,
    };
    const m = try std.json.parseFromSliceLeaky(M, a, meta, .{});
    try tt.expectEqualStrings("index.js", m.main_module);
    try tt.expectEqualStrings("2026-09-03", m.compatibility_date);
    try tt.expectEqual(@as(usize, 1), m.compatibility_flags.len);
    try tt.expectEqualStrings("global_fetch_strictly_public", m.compatibility_flags[0]);
    try tt.expectEqual(@as(usize, 15), m.bindings.len);
    try tt.expectEqualStrings("ai", m.bindings[0].type);
    try tt.expectEqualStrings("AI", m.bindings[0].name);
    try tt.expectEqualStrings("DisclosureLimiter", m.bindings[1].class_name);
    try tt.expectEqualStrings("LOGIN_LIMITER", m.bindings[2].name);
    try tt.expectEqualStrings("AuthSession", m.bindings[3].class_name);
    for (m.bindings[4 .. m.bindings.len - 1]) |b| try tt.expectEqualStrings("plain_text", b.type);
    const backend = m.bindings[m.bindings.len - 1];
    try tt.expectEqualStrings("service", backend.type);
    try tt.expectEqualStrings("GARY_RUNTIME", backend.name);
    try tt.expectEqualStrings(GARY_SCRIPT, backend.service);
    try tt.expectEqualStrings("GaryBackend", backend.entrypoint);
    try tt.expectEqualStrings("LLMS_URL", m.bindings[4].name);
    try tt.expect(std.mem.indexOf(u8, first, "GARY_RUNTIME") != null);
    try tt.expect(std.mem.indexOf(u8, first, GARY_SCRIPT) != null);
    for (m.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "GARY_TOOLS_ENABLED") or std.mem.eql(u8, binding.name, "MCP_ALLOW_ACTIVE_TOOLS") or std.mem.eql(u8, binding.name, "MCP_ALLOW_DARKWEB")) try tt.expectEqualStrings("true", binding.text);
        if (std.mem.eql(u8, binding.name, "CTF_SAFE_MODE") or std.mem.eql(u8, binding.name, "CTF_REQUIRE_CONFIRM")) try tt.expectEqualStrings("false", binding.text);
    }
    try tt.expect(std.mem.indexOf(u8, first, "crons") == null);
    try tt.expectEqualStrings("secret_text", m.keep_bindings[0]);
    try tt.expectEqualStrings("security-limiters-v1", m.migrations.?.new_tag);
    try tt.expectEqual(@as(usize, 3), m.migrations.?.new_sqlite_classes.len);
    try tt.expect(std.mem.indexOf(u8, again, "migrations") == null);
    // no secret rides the body: the three are set by their own calls
    try tt.expect(std.mem.indexOf(u8, first, "MCP_API_TOKEN") == null and std.mem.indexOf(u8, first, "ACCESS_PASSWORD") == null);
    try tt.expect(std.mem.indexOf(u8, first, "name=\"index.js\"; filename=\"index.js\"\r\nContent-Type: application/javascript+module\r\n\r\nexport default {}") != null);
    try tt.expect(std.mem.indexOf(u8, first, "name=\"harness.mjs\"; filename=\"harness.mjs\"\r\nContent-Type: application/javascript+module\r\n\r\nexport const h = 1;") != null);
    try tt.expect(std.mem.indexOf(u8, first, "name=\"neuron_core.wasm\"; filename=\"neuron_core.wasm\"\r\nContent-Type: application/wasm\r\n\r\n\x00asm") != null);
    try tt.expect(std.mem.endsWith(u8, first, "\r\n------b--\r\n"));
    // a module is typed by its name, and what comes back from the repo is judged by what it is: an error page is
    // never uploaded as a script
    try tt.expectEqualStrings("application/javascript", moduleType("lib/x.cjs"));
    try tt.expectEqualStrings("text/plain", moduleType("prompt.md"));
    try tt.expectEqualStrings("application/octet-stream", moduleType("blob.bin"));
    try tt.expect(looksLikeModule("application/javascript+module", "export const x = 1;"));
    try tt.expect(!looksLikeModule("application/javascript+module", "404: Not Found"));
    try tt.expect(!looksLikeModule("application/javascript+module", "<!DOCTYPE html><html><body>Oops</body></html>"));
    try tt.expect(looksLikeModule("application/wasm", "\x00asm\x01") and !looksLikeModule("application/wasm", "export"));
    try tt.expect(looksLikeModule("text/plain", "<!DOCTYPE html>") and !looksLikeModule("text/plain", "404: Not Found"));
    try tt.expect(!looksLikeModule("text/plain", ""));
    // the keys the owner may set by hand, and the names the runtime reads them under
    try tt.expectEqualStrings("ALERT_URL", keySecret("alert").?);
    try tt.expectEqualStrings("GARRETT_MCP_URL", keySecret("garrett_url").?);
    try tt.expectEqualStrings("GARRETT_MCP_TOKEN", keySecret("garrett-token").?);
    try tt.expect(keyIsUrl("ALERT_URL") and keyIsUrl("GARRETT_MCP_URL") and !keyIsUrl("GARRETT_MCP_TOKEN") and !keyIsUrl("BRAVE_KEY"));
    try tt.expect(std.mem.indexOf(u8, TOT_JS, "env.ALERT_URL") != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, "env.GARRETT_MCP_URL") != null);
    try tt.expect(std.mem.indexOf(u8, TOT_JS, "env.GARRETT_MCP_TOKEN") != null);
    // the settings the runtime takes by those names
    try tt.expect(std.mem.indexOf(u8, TOT_JS, "b.posture") != null and std.mem.indexOf(u8, TOT_JS, "b.leash_s") != null);
}

test "Agent Garrett is launched from its repo's modules beside the tots' Worker - locked, pointed at from the tots, reported to the runtime - and a refusal waits a quarter of an hour" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cftot-garrett-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    garrett_failed_s.store(0, .monotonic);

    const routes = [_]fakehttp.Route{
        .{ .method = "PUT", .path = "/workers/scripts/veil-garrett-upload", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/workers/scripts/veil-garrett-upload/subdomain", .reply = StandIn.ok },
        .{ .method = "DELETE", .path = "/workers/scripts/veil-garrett-upload", .reply = StandIn.ok },
        .{ .method = "PUT", .path = "/build/", .reply = fakehttp.wire("{\"success\":true}") },
        .{ .method = "PUT", .path = "/workers/scripts/veil-garrett-gary", .reply = StandIn.ok },
        .{ .method = "GET", .path = "/workers/durable_objects/namespaces", .reply = fakehttp.wire("{\"success\":true,\"result\":[{\"id\":\"gary-namespace\",\"script\":\"veil-garrett-gary\",\"class\":\"GaryContainer\"}]}") },

        .{ .method = "GET", .path = "/v1/garrett", .reply = StandIn.garrett_pending },
        .{ .method = "GET", .path = "/garrett/wrangler.toml", .reply = StandIn.toml },
        .{ .method = "GET", .path = "/garrett/contents/src", .reply = StandIn.list },
        .{ .method = "GET", .path = "/garrett/src/index.js", .reply = StandIn.src_index },
        .{ .method = "GET", .path = "/garrett/src/neuron_core.wasm", .reply = StandIn.src_wasm },
        .{ .method = "GET", .path = "/garrett/src/", .reply = StandIn.src_mjs },
        .{ .method = "GET", .path = "/accounts/acct/workers/subdomain", .reply = StandIn.subdomain },
        .{ .method = "GET", .path = "/workers/scripts/veil-garrett/settings", .reply = StandIn.no_script },
        .{ .method = "PUT", .path = "/workers/scripts/veil-garrett/secrets", .reply = StandIn.ok },
        // the first launch is refused both ways (with and without the class migration); the next is taken
        .{ .method = "PUT", .path = "/workers/scripts/veil-garrett", .reply = StandIn.no_browser, .times = 2 },
        .{ .method = "PUT", .path = "/workers/scripts/veil-garrett", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/workers/scripts/veil-garrett/subdomain", .reply = StandIn.ok },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots/secrets", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/v1/garrett/result", .reply = StandIn.garrett_deployed },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.ok);
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
    // a login that names no account is refused before any call (a launch needs no tot: see the next test)
    var none: State = .{};
    try tt.expect(launchGarrett(&ta.app, a, 1, .{ .key = "oauth-bearer", .account_id = "" }, &none) != null);
    var st: State = .{ .account = "acct", .url = stand_in, .script_hash = "x" };
    writeState(&ta.app, 1, st);

    // 1: the runtime says a tot asked; the upload is refused, the refusal is reported, nothing is recorded
    syncGarrettAs(&ta.app, a, 1, tok, &st);
    try tt.expectEqualStrings("", st.garrett_url);
    try tt.expect(garrett_failed_s.load(.monotonic) > 0);
    // 2: within the quarter hour only the question is asked
    const before = srv.call_count;
    syncGarrettAs(&ta.app, a, 1, tok, &st);
    try tt.expectEqual(before + 1, srv.call_count);
    // 3: the backoff over, the launch goes through: the Worker, its secrets, its address, the tots' two secrets
    garrett_failed_s.store(0, .monotonic);
    syncGarrettAs(&ta.app, a, 1, tok, &st);
    try tt.expectEqualStrings(stand_in, st.garrett_url);
    var hb: [16]u8 = undefined;
    try tt.expectEqualStrings(garrettHash(&[_][]const u8{ StandIn.src_index_body, StandIn.src_mjs_body, StandIn.src_mjs_body, StandIn.src_mjs_body, StandIn.src_wasm_body }, &hb), st.garrett_hash);
    try tt.expect(st.garrett_at > 0);
    try tt.expectEqualStrings("acct", st.garrett_account); // the launch records the account and generation its secrets were made under
    try tt.expectEqual(@as(u32, 0), st.garrett_gen);
    try tt.expectEqualStrings(stand_in, readState(&ta.app, 1, a).garrett_url);
    // the state file holds no secret of Agent Garrett's
    var mb: [64]u8 = undefined;
    var pb: [64]u8 = undefined;
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/u1/" ++ STATE_FILE, a, .limited(64 << 10));
    try tt.expect(std.mem.indexOf(u8, on_disk, garrettToken(&ta.app, 1, "acct", 0, &mb)) == null);
    try tt.expect(std.mem.indexOf(u8, on_disk, garrettPassword(&ta.app, 1, "acct", 0, &pb)) == null);
    try tt.expect(!std.mem.eql(u8, &mb, &pb)); // two derived secrets, two values
    // removal: the Worker, the tots' two secrets, the runtime's record
    try tt.expect(removeGarrett(&ta.app, a, 1, tok, &st) == null);
    try tt.expectEqualStrings("", st.garrett_url);
    try tt.expectEqualStrings("", readState(&ta.app, 1, a).garrett_url);

    srv.stop();
    running = false;
    // the repo is read before anything in the account is touched - its toml, the listing, the modules in the
    // listing's order (the dotfile skipped) - then the subdomain, the script, the upload
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("GET", "/v1/garrett"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("GET", "/garrett/wrangler.toml"));
    try tt.expectEqual(@as(?usize, 2), srv.firstCall("GET", "/garrett/contents/src"));
    try tt.expectEqual(@as(?usize, 3), srv.firstCall("GET", "/garrett/src/index.js"));
    try tt.expectEqual(@as(?usize, 4), srv.firstCall("GET", "/garrett/src/mcp.mjs"));
    try tt.expectEqual(@as(?usize, 7), srv.firstCall("GET", "/garrett/src/neuron_core.wasm"));
    try tt.expectEqual(@as(?usize, 8), srv.firstCall("GET", "/accounts/acct/workers/subdomain"));
    try tt.expect(srv.firstCall("GET", "/workers/scripts/veil-garrett/settings") != null);
    try tt.expect(srv.firstCall("PUT", "/accounts/acct/workers/scripts/veil-garrett") != null);
    try tt.expect(srv.firstCall("POST", "/v1/garrett/result") != null);
    try tt.expectEqual(@as(usize, 3), srv.countCalls("GET", "/v1/garrett"));
    try tt.expectEqual(@as(usize, 2), srv.countCalls("GET", "/garrett/wrangler.toml")); // read again at the second launch: live, never cached
    try tt.expectEqual(@as(usize, 2), srv.countCalls("GET", "/garrett/contents/src"));
    try tt.expectEqual(@as(usize, 0), srv.countCalls("GET", "/garrett/src/.gitkeep"));
    try tt.expectEqual(@as(usize, 3), srv.countCallsExact("PUT", "/client/v4/accounts/acct/workers/scripts/veil-garrett"));
    try tt.expectEqual(@as(usize, 2), srv.countCallsExact("PUT", "/client/v4/accounts/acct/workers/scripts/veil-garrett-gary"));
    try tt.expectEqual(@as(usize, 3), srv.countCalls("PUT", "/workers/scripts/veil-garrett/secrets"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("POST", "/workers/scripts/veil-garrett/subdomain"));
    try tt.expectEqual(@as(usize, 2), srv.countCalls("PUT", "/workers/scripts/veil-tots/secrets"));
    try tt.expectEqual(@as(usize, 2), srv.countCalls("POST", "/v1/garrett/result"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("DELETE", "/workers/scripts/veil-garrett?force=true"));
    try tt.expectEqual(@as(usize, 2), srv.countCalls("DELETE", "/workers/scripts/veil-tots/secrets/GARRETT_MCP_"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("POST", "/v1/garrett/clear"));
    try tt.expect(srv.call_count > 36 and srv.call_count < 128);
}

test "Agent Garrett deploys on its own, with no tater-tot in the account: its pair is derived for a chat or a swarm, a runtime that arrives later is pointed at it, removing the tots keeps it, and removing it touches no tots" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cftot-garrett-solo-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    const routes = [_]fakehttp.Route{
        .{ .method = "PUT", .path = "/workers/scripts/veil-garrett-upload", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/workers/scripts/veil-garrett-upload/subdomain", .reply = StandIn.ok },
        .{ .method = "DELETE", .path = "/workers/scripts/veil-garrett-upload", .reply = StandIn.ok },
        .{ .method = "PUT", .path = "/build/", .reply = fakehttp.wire("{\"success\":true}") },
        .{ .method = "PUT", .path = "/workers/scripts/veil-garrett-gary", .reply = StandIn.ok },
        .{ .method = "GET", .path = "/workers/durable_objects/namespaces", .reply = fakehttp.wire("{\"success\":true,\"result\":[{\"id\":\"gary-namespace\",\"script\":\"veil-garrett-gary\",\"class\":\"GaryContainer\"}]}") },

        .{ .method = "GET", .path = "/garrett/wrangler.toml", .reply = StandIn.toml },
        .{ .method = "GET", .path = "/garrett/contents/src", .reply = StandIn.list },
        .{ .method = "GET", .path = "/garrett/src/index.js", .reply = StandIn.src_index },
        .{ .method = "GET", .path = "/garrett/src/neuron_core.wasm", .reply = StandIn.src_wasm },
        .{ .method = "GET", .path = "/garrett/src/", .reply = StandIn.src_mjs },
        .{ .method = "GET", .path = "/accounts/acct/workers/subdomain", .reply = StandIn.subdomain },
        .{ .method = "GET", .path = "/workers/scripts/veil-garrett/settings", .reply = StandIn.no_script },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.ok);
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

    // 1: no tot, no runtime - the launch goes through: the modules, the address, the upload, its three secrets,
    //    its route. Nothing is put on a tots' Worker that is not there, and no runtime is told.
    var st: State = .{ .token_gen = 2 };
    if (launchGarrett(&ta.app, a, 1, tok, &st)) |msg| {
        std.debug.print("launch refused: {s}\n", .{msg});
        return error.TestUnexpectedResult;
    }
    try tt.expectEqualStrings(stand_in, st.garrett_url);
    try tt.expectEqualStrings("acct", st.garrett_account);
    try tt.expectEqual(@as(u32, 2), st.garrett_gen);
    try tt.expectEqualStrings("", st.url); // still no tots
    try tt.expectEqualStrings(stand_in, readState(&ta.app, 1, a).garrett_url);
    // what a chat turn or a swarm deployment derives IS the bearer the Worker was given
    const creds = cf_garrett.credsFor(&ta.app, 1, a) orelse return error.TestUnexpectedResult;
    var mb: [64]u8 = undefined;
    try tt.expectEqualStrings(garrettToken(&ta.app, 1, "acct", 2, &mb), creds.token);
    try tt.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/mcp", .{stand_in}), creds.mcp_url);
    // 2: the tots arrive later: their new runtime is pointed at it (ensureRuntime's step, on its own)
    try tt.expect(pointTotsAtGarrett(&ta.app, a, 1, tok, st) == null);
    // 3: the tots go (teardown): the agent stays, its account and generation pinned past the bump
    st.account = "acct";
    st.url = stand_in;
    try tt.expect(removeScript(&ta.app, a, 1, tok, &st) == null);
    try tt.expectEqual(@as(u32, 3), st.token_gen);
    try tt.expectEqualStrings("", st.url);
    try tt.expectEqualStrings(stand_in, st.garrett_url);
    try tt.expectEqualStrings("acct", st.garrett_account);
    try tt.expectEqual(@as(u32, 2), st.garrett_gen);
    const still = cf_garrett.credsFor(&ta.app, 1, a) orelse return error.TestUnexpectedResult;
    try tt.expectEqualStrings(creds.token, still.token);
    // 4: removed on its own, with no runtime to tell and no tots' secrets to take
    try tt.expect(removeGarrett(&ta.app, a, 1, tok, &st) == null);
    try tt.expectEqualStrings("", st.garrett_url);
    try tt.expectEqualStrings("", st.garrett_account);
    try tt.expect(cf_garrett.credsFor(&ta.app, 1, a) == null);

    srv.stop();
    running = false;
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("GET", "/garrett/wrangler.toml"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("GET", "/garrett/contents/src"));
    try tt.expectEqual(@as(usize, 5), srv.countCalls("GET", "/garrett/src/"));
    try tt.expect(srv.firstCall("PUT", "/accounts/acct/workers/scripts/veil-garrett") != null);
    try tt.expectEqual(@as(usize, 1), srv.countCallsExact("PUT", "/client/v4/accounts/acct/workers/scripts/veil-garrett"));
    try tt.expectEqual(@as(usize, 1), srv.countCallsExact("PUT", "/client/v4/accounts/acct/workers/scripts/veil-garrett-gary"));
    try tt.expectEqual(@as(usize, 3), srv.countCalls("PUT", "/workers/scripts/veil-garrett/secrets"));
    try tt.expect(srv.firstCall("POST", "/workers/scripts/veil-garrett/subdomain") != null);
    try tt.expect(srv.firstCall("PUT", "/workers/scripts/veil-tots/secrets") != null);
    try tt.expectEqual(@as(usize, 2), srv.countCalls("PUT", "/workers/scripts/veil-tots/secrets"));
    try tt.expectEqual(@as(usize, 0), srv.countCalls("POST", "/v1/garrett/result"));
    try tt.expectEqual(@as(usize, 0), srv.countCalls("POST", "/v1/garrett/clear"));
    try tt.expectEqual(@as(usize, 0), srv.countCalls("DELETE", "/workers/scripts/veil-tots/secrets/"));
    try tt.expect(srv.firstCall("DELETE", "/workers/scripts/veil-tots?force=true") != null);
    try tt.expect(srv.firstCall("DELETE", "/workers/scripts/veil-garrett?force=true") != null);
    try tt.expect(srv.call_count > 19 and srv.call_count < 128);
}

test "RSI seeds the live source, uploads self-edits without a local grant, persists them, and reports compiler failures" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftot-rsi-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/v1/runtime", .reply = fakehttp.wire("{\"ok\":true,\"initialized\":false}"), .times = 1 },
        .{ .method = "GET", .path = "/v1/runtime", .reply = fakehttp.wire("{\"ok\":true,\"initialized\":true,\"revision\":1,\"status\":\"pending\",\"source\":\"export const changed = true;\"}"), .times = 2 },
        .{ .method = "GET", .path = "/v1/runtime", .reply = fakehttp.wire("{\"ok\":true,\"initialized\":true,\"revision\":2,\"status\":\"pending\",\"source\":\"broken source\"}") },
        .{ .method = "POST", .path = "/v1/runtime/seed", .reply = fakehttp.wire("{\"ok\":true}") },
        .{ .method = "POST", .path = "/v1/runtime/result", .reply = fakehttp.wire("{\"ok\":true}") },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots", .reply = StandIn.ok, .times = 1 },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots", .reply = fakehttp.wire("{\"success\":false,\"errors\":[{\"message\":\"SyntaxError\"}]}") },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.no_script);
    var running = true;
    defer if (running) srv.stop();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    ta.app.cf_api_root = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var st: State = .{ .account = "acct", .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{srv.port}), .browser = true };
    const tok: Tok = .{ .key = "oauth-bearer", .account_id = "acct" };
    syncRuntimeAs(&ta.app, a, 1, tok, &st);
    try tt.expectEqualStrings(TOT_JS, readState(&ta.app, 1, a).runtime_source); // larger than the old 64 KiB state read
    syncRuntimeAs(&ta.app, a, 1, tok, &st);
    try tt.expectEqualStrings("export const changed = true;", st.runtime_source);
    try tt.expectEqual(@as(u64, 1), st.runtime_revision);
    try tt.expectEqual(@as(usize, 0), st.local.len);
    var restored = readState(&ta.app, 1, a);
    var uploaded = false;
    try tt.expect(ensureRuntime(&ta.app, a, 1, tok, &restored, &uploaded) == null);
    try tt.expect(!uploaded); // an ordinary deploy/restart keeps the self-edit
    syncRuntimeAs(&ta.app, a, 1, tok, &st); // same pending revision: only retry the acknowledgement
    syncRuntimeAs(&ta.app, a, 1, tok, &st); // next revision fails compilation
    try tt.expectEqualStrings("SyntaxError", st.last_error);
    try tt.expectEqualStrings("export const changed = true;", readState(&ta.app, 1, a).runtime_source);
    try tt.expectEqual(@as(u64, 1), st.runtime_revision);
    syncRuntimeAs(&ta.app, a, 1, .{ .key = "other", .account_id = "another-account" }, &st);
    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 2), srv.countCalls("PUT", "/workers/scripts/veil-tots"));
    try tt.expectEqual(@as(usize, 3), srv.countCalls("POST", "/v1/runtime/result"));
    try tt.expectEqual(@as(usize, 10), srv.call_count);
    const body = try uploadSourceBody(a, "--rsi", false, .{ .python = true, .browser = true, .neuron = true }, st.runtime_source);
    try tt.expect(std.mem.indexOf(u8, body, st.runtime_source) != null);
    try tt.expect(std.mem.indexOf(u8, body, TOT_JS) == null);
    try tt.expect(std.mem.indexOf(u8, body, "\"keep_bindings\":[\"secret_text\"]") != null);
    try tt.expect(std.mem.indexOf(u8, body, "migrations") == null);
}

test "a first deployment uploads the runtime, sets its token, creates the tot and records the owner's-machine grant; the next reuses the ready runtime" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cftot-deploy-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/accounts/acct/workers/subdomain", .reply = StandIn.subdomain },
        .{ .method = "GET", .path = "/workers/scripts/veil-tots/settings", .reply = StandIn.no_script },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots-py", .reply = StandIn.ok },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots/secrets", .reply = StandIn.ok },
        // this account has no browser: the upload that asks for one is refused, the next is taken
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots", .reply = StandIn.no_browser, .times = 2 },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/workers/scripts/veil-tots/subdomain", .reply = StandIn.ok },
        .{ .method = "GET", .path = "/v1/tots", .reply = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"ok\":true,\"tots\":[]}" },
        .{ .method = "POST", .path = "/v1/tots", .reply = StandIn.made, .times = 1 },
        .{ .method = "POST", .path = "/v1/tots", .reply = StandIn.full },
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
    try tt.expect(st.python and !st.browser and st.neuron);
    try tt.expect(std.mem.indexOf(u8, st.tools_note, "the browser is off: Browser Rendering is not enabled") != null);

    // The state file holds no secret: not the runtime's token, not the OAuth bearer.
    var tb: [64]u8 = undefined;
    const token = totToken(&ta.app, 1, "acct", 0, &tb);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/u1/" ++ STATE_FILE, a, .limited(64 << 10));
    try tt.expect(std.mem.indexOf(u8, on_disk, token) == null);
    try tt.expect(std.mem.indexOf(u8, on_disk, "oauth-bearer") == null);

    // The second deployment finds the runtime current: straight to the runtime, whose refusal comes back in its words.
    const second = deploy(&ta.app, a, 1, tok, .{ .goal = "a fourth tot", .name = "Rex" });
    try tt.expect(second == .err);
    try tt.expect(std.mem.indexOf(u8, second.err, "already has 3 tots") != null);

    srv.stop();
    running = false;
    // subdomain, exists?, the Python Worker, the runtime (refused twice with the browser, taken without),
    // secret, route, create - in that order; then one more create
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("GET", "/accounts/acct/workers/subdomain"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("GET", "/workers/scripts/veil-tots/settings"));
    try tt.expectEqual(@as(?usize, 2), srv.firstCall("PUT", "/accounts/acct/workers/scripts/veil-tots-py"));
    try tt.expectEqual(@as(?usize, 6), srv.firstCall("PUT", "/workers/scripts/veil-tots/secrets"));
    try tt.expectEqual(@as(?usize, 7), srv.firstCall("POST", "/workers/scripts/veil-tots/subdomain"));
    try tt.expectEqual(@as(?usize, 8), srv.firstCall("GET", "/v1/tots"));
    try tt.expectEqual(@as(?usize, 9), srv.firstCall("POST", "/v1/tots"));
    try tt.expectEqual(@as(usize, 5), srv.countCalls("PUT", "/accounts/acct/workers/scripts/veil-tots")); // py, 3 runtime tries, secret
    try tt.expectEqual(@as(usize, 2), srv.countCalls("POST", "/v1/tots"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/workers/subdomain"));
    try tt.expectEqual(@as(usize, 12), srv.call_count);
}

test "an unreachable cached runtime is repaired without deleting data and an uncertain create is never replayed" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftot-reconnect-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/v1/tots", .reply = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\nerror code: 1042", .times = 1 },
        .{ .method = "GET", .path = "/v1/tots", .reply = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"ok\":true,\"tots\":[]}" },
        .{ .method = "GET", .path = "/workers/subdomain", .reply = StandIn.subdomain },
        .{ .method = "GET", .path = "/workers/scripts/veil-tots/settings", .reply = StandIn.ok },
        .{ .method = "PUT", .path = "/workers/scripts/", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/workers/scripts/veil-tots/subdomain", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/v1/tots", .reply = StandIn.made, .times = 1 },
        .{ .method = "POST", .path = "/v1/tots", .reply = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\nunavailable" },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.no_script);
    var running = true;
    defer if (running) srv.stop();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    ta.app.cf_api_root = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{srv.port});
    const source = "// owner's runtime changes\n" ++ TOT_JS;
    var hb: [16]u8 = undefined;
    writeState(&ta.app, 1, .{ .account = "acct", .url = url, .runtime_source = source, .runtime_revision = 4, .script_hash = sourceHash(source, &hb) });
    const tok = Tok{ .key = "test-oauth", .account_id = "acct" };
    try tt.expect(deploy(&ta.app, a, 1, tok, .{ .goal = "watch the tide tables" }) == .ok);
    const after = readState(&ta.app, 1, a);
    try tt.expectEqualStrings(source, after.runtime_source);
    try tt.expectEqual(@as(u64, 4), after.runtime_revision);
    try tt.expect(deploy(&ta.app, a, 1, tok, .{ .goal = "watch the tide tables" }) == .err);
    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 0), srv.countCalls("DELETE", "/"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/workers/subdomain"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("POST", "/workers/scripts/veil-tots/subdomain"));
    try tt.expectEqual(@as(usize, 3), srv.countCalls("GET", "/v1/tots"));
    try tt.expectEqual(@as(usize, 2), srv.countCalls("POST", "/v1/tots"));
    try tt.expect(std.mem.indexOf(u8, runtimeFailure("error code: 1042"), "1042") != null);
}

test "a refused workers.dev route is reported before any tot can be created" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftot-route-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/workers/subdomain", .reply = StandIn.subdomain },
        .{ .method = "POST", .path = "/workers/scripts/veil-tots/subdomain", .reply = "HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n{\"success\":false,\"errors\":[{\"message\":\"route disabled by account\"}]}" },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.ok);
    var running = true;
    defer if (running) srv.stop();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    ta.app.cf_api_root = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    const result = deploy(&ta.app, a, 1, .{ .key = "test-oauth", .account_id = "acct" }, .{ .goal = "watch the tide tables" });
    try tt.expect(result == .err);
    try tt.expect(std.mem.indexOf(u8, result.err, "route disabled by account") != null);
    try tt.expectEqualStrings(result.err, readState(&ta.app, 1, a).last_error);
    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 0), srv.countCalls("POST", "/v1/tots"));
}

test "the bridge posts a finished job's answer back, fails a run that left none, and never reruns either" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cftot-bridge-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    // j1's turn has answered; j2's ran and left only the user message.
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, root ++ "/u1/_chat/convs/tot_gary_j1_1790000000", .default_dir);
    _ = try cwd.createDirPathStatus(io, root ++ "/u1/_chat/convs/tot_gary_j2_1790000001", .default_dir);
    try cwd.writeFile(io, .{ .sub_path = root ++ "/u1/_chat/convs/tot_gary_j1_1790000000/messages.jsonl", .data = "{\"role\":\"user\",\"content\":\"run the suite\",\"kind\":\"\",\"ts\":1}\n{\"role\":\"assistant\",\"content\":\"working on it\",\"kind\":\"\",\"ts\":2}\n{\"role\":\"assistant\",\"content\":\"42 passed, 0 failed \\\"quoted\\\"\",\"kind\":\"\",\"ts\":3}\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/u1/_chat/convs/tot_gary_j2_1790000001/messages.jsonl", .data = "{\"role\":\"user\",\"content\":\"build it\",\"kind\":\"\",\"ts\":1}\n" });

    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/v1/tots/Gary/jobs", .reply = w("{\"ok\":true,\"model\":\"@cf/x/y\",\"jobs\":[{\"id\":\"j1\",\"t\":1790000000123,\"instruction\":\"run the suite\",\"status\":\"pending\"},{\"id\":\"j2\",\"t\":1790000001000,\"instruction\":\"build it\",\"status\":\"pending\"}]}") },
        .{ .method = "POST", .path = "/v1/tots/Gary/jobs/", .reply = w("{\"ok\":true}") },
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
    try tt.expectEqual(@as(usize, 0), bridgeTot(&ta.app, a, 1, st, "Gary")); // nothing was started
    var began = false;
    try tt.expectEqualStrings("42 passed, 0 failed \"quoted\"", lastAssistant(&ta.app, a, 1, "tot_gary_j1_1790000000", &began).?);
    try tt.expect(lastAssistant(&ta.app, a, 1, "tot_gary_j9_1", &began) == null and !began);

    srv.stop();
    running = false;
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("GET", "/v1/tots/Gary/jobs"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("POST", "/v1/tots/Gary/jobs/j1"));
    try tt.expectEqual(@as(?usize, 2), srv.firstCall("POST", "/v1/tots/Gary/jobs/j2"));
    try tt.expectEqual(@as(usize, 3), srv.call_count);
    // What went back for j1 is the turn's last answer, as JSON a parser reads back whole. (fakehttp keeps the
    // FIRST request only, so the body is rebuilt the way postResult builds it.)
    const sent = try std.json.Stringify.valueAlloc(a, .{ .ok = true, .result = "42 passed, 0 failed \"quoted\"" }, .{});
    const back = try std.json.parseFromSliceLeaky(struct { ok: bool, result: []const u8 }, a, sent, .{});
    try tt.expectEqualStrings("42 passed, 0 failed \"quoted\"", back.result);
    const text = jobText(a, "Gary", "run the suite").?;
    try tt.expect(std.mem.startsWith(u8, text, "run the suite\n") and std.mem.indexOf(u8, text, "sent back to Gary") != null);
}

test "a grant list keeps one entry per tot, whatever the case, and drops it on delete" {
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

test "each deployment of a tot has its own folder name: the name and when it was deployed, in UTC" {
    var b: [160]u8 = undefined;
    try tt.expectEqualStrings("u3/_tots/Gary-20261001-120005", totFolder(&b, 3, "Gary", 1790856005123).?);
    try tt.expectEqualStrings("u3/_tots/Gary-20261001-120006", totFolder(&b, 3, "Gary", 1790856006000).?); // a redeploy a second later is a new run
    try tt.expect(totFolder(&b, 3, "../x", 1790856005123) == null);
    try tt.expect(totFolder(&b, 3, "Gary", 0) == null); // an unreachable tot names no deployment
    try tt.expect(noteFileOk("findings.md") and !noteFileOk("..") and !noteFileOk("a/b") and !noteFileOk("a\\b") and !noteFileOk(""));
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try logLine(arena.allocator(), &out, .{ .seq = 4, .t = 1790856005123, .kind = "verdict", .text = "improved [3/10]\nsecond line", .i = 2 });
    try logLine(arena.allocator(), &out, .{ .seq = 5, .t = 1790856006000, .kind = "status", .text = "rested" });
    try tt.expectEqualStrings("2026-10-01 12:00:05  r2   verdict  improved [3/10]\n                                   second line\n2026-10-01 12:00:06       status   rested\n", out.items);
}

test "a mirror pass writes each tot's folder and the scratchpad, and the next pass asks only for what moved" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cftot-mirror-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;

    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/v1/tots/Gary/events?after=0&", .reply = w("{\"ok\":true,\"seq\":2,\"events\":[{\"seq\":1,\"t\":1790856005123,\"kind\":\"goal\",\"text\":\"map the harbours\"},{\"seq\":2,\"t\":1790856006000,\"kind\":\"pick\",\"text\":\"list them\",\"i\":1}]}") },
        .{ .method = "GET", .path = "/v1/tots/Gary/notes?after=0", .reply = w("{\"ok\":true,\"more\":false,\"names\":[\"harbours.md\"],\"notes\":[{\"name\":\"harbours.md\",\"t\":9,\"text\":\"# Harbours\\n- Tofino\"},{\"name\":\"../escape\",\"t\":10,\"text\":\"x\"}]}") },
        .{ .method = "GET", .path = "/v1/pad?after=0", .reply = w("{\"ok\":true,\"seq\":1,\"entries\":[{\"seq\":1,\"t\":1790856005123,\"from\":\"Gary\",\"text\":\"harbours are in note harbours.md\"}]}") },
        .{ .method = "GET", .path = "/v1/tots", .reply = w("{\"ok\":true,\"pad_seq\":1,\"tots\":[{\"name\":\"Gary\",\"state\":\"working\",\"created\":1790856005123,\"seq\":2,\"notes_rev\":1},{\"name\":\"Ada\",\"state\":\"unreachable\"}]}") },
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

    const dir = root ++ "/u1/_tots/Gary-20261001-120005";
    const cwd = std.Io.Dir.cwd();
    const lg = try cwd.readFileAlloc(io, dir ++ "/events.log", a, .limited(1 << 20));
    try tt.expectEqualStrings("2026-10-01 12:00:05       goal     map the harbours\n2026-10-01 12:00:06  r1   pick     list them\n", lg);
    const jl = try cwd.readFileAlloc(io, dir ++ "/events.jsonl", a, .limited(1 << 20));
    try tt.expectEqual(@as(usize, 2), std.mem.count(u8, jl, "\n"));
    try tt.expectEqualStrings("# Harbours\n- Tofino", try cwd.readFileAlloc(io, dir ++ "/notes/harbours.md", a, .limited(4096)));
    try tt.expect(std.mem.indexOf(u8, try cwd.readFileAlloc(io, dir ++ "/status.json", a, .limited(4096)), "\"working\"") != null);
    try tt.expect(std.mem.indexOf(u8, try cwd.readFileAlloc(io, root ++ "/u1/_tots/scratchpad.md", a, .limited(4096)), "harbours are in note harbours.md") != null);
    try tt.expectError(error.FileNotFound, cwd.statFile(io, root ++ "/u1/_tots/escape", .{})); // a note name never leaves notes/
    try tt.expectEqual(@as(usize, 2), srv.countCalls("GET", "/v1/tots?"[0..8]) - srv.countCalls("GET", "/v1/tots/")); // the two roster calls
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/v1/tots/Gary/events"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/v1/tots/Gary/notes"));
    try tt.expectEqual(@as(usize, 1), srv.countCalls("GET", "/v1/pad"));
    try tt.expectEqual(@as(usize, 5), srv.call_count);
}

test "removing the Worker forgets the deployment, every grant to this machine, and the token the script held" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftot-dellast-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        .{ .method = "DELETE", .path = "/workers/scripts/veil-tots?force=true", .reply = w("{\"success\":true,\"errors\":[],\"result\":null}") },
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
    try tt.expectEqual(@as(?usize, 0), srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-tots?force=true"));
    try tt.expectEqual(@as(?usize, 1), srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-tots-py?force=true")); // then its Python Worker
    const after = readState(&ta.app, 1, a);
    try tt.expectEqualStrings("", after.url); // forgotten: the next deploy uploads again
    try tt.expectEqual(@as(usize, 0), after.local.len); // no grant outlives its tot
    try tt.expectEqual(@as(u32, 5), after.token_gen); // and the removed script's token is never valid again
}

test "a Python that does not start with its native packages is uploaded again with fewer; one that starts is settled with what it has" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftot-pycheck-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        // not the runtime's answer (a deployment still coming up), then "no" twice, then "yes"
        .{ .method = "GET", .path = "/v1/python", .reply = w("<html>starting</html>"), .times = 1 },
        .{ .method = "GET", .path = "/v1/python", .reply = w("{\"ok\":true,\"python\":false,\"native\":[],\"error\":\"Worker exceeded its startup limits\"}"), .times = 2 },
        .{ .method = "GET", .path = "/v1/python", .reply = w("{\"ok\":true,\"python\":true,\"native\":[\"numpy\",\"regex\"],\"error\":\"\"}") },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots-py", .reply = StandIn.ok },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.no_script);
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var ub: [80]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok: Tok = .{ .key = "oauth-bearer", .account_id = "acct" };
    var st: State = .{ .account = "acct", .url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port}), .python = true, .py_rung = 0, .py_check = PY_CHECKS };

    checkPythonAs(&ta.app, a, 1, tok, &st); // no answer worth the name: asked again later, nothing uploaded
    try tt.expectEqual(@as(u8, PY_CHECKS - 1), st.py_check);
    try tt.expectEqual(@as(u8, 0), st.py_rung);
    checkPythonAs(&ta.app, a, 1, tok, &st); // one "no" is not enough
    try tt.expectEqual(@as(u8, 1), st.py_fails);
    try tt.expectEqual(@as(usize, 0), srv.countCalls("PUT", "/accounts/acct/workers/scripts/veil-tots-py"));
    checkPythonAs(&ta.app, a, 1, tok, &st); // the second is: the next smaller set goes up, and is checked in turn
    try tt.expectEqual(@as(u8, 1), st.py_rung);
    try tt.expectEqual(@as(u8, PY_CHECKS), st.py_check);
    try tt.expectEqual(@as(u8, 0), st.py_fails);
    checkPythonAs(&ta.app, a, 1, tok, &st); // it starts: settled
    try tt.expectEqual(@as(u8, 0), st.py_check);
    try tt.expectEqual(@as(usize, 2), st.py_native.len);
    try tt.expectEqualStrings("numpy", st.py_native[0]);
    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 1), srv.countCalls("PUT", "/accounts/acct/workers/scripts/veil-tots-py"));
    try tt.expectEqual(@as(usize, 4), srv.countCalls("GET", "/v1/python"));
    const kept = readState(&ta.app, 1, a); // and the state file says so
    try tt.expectEqual(@as(u8, 1), kept.py_rung);
    try tt.expectEqual(@as(usize, 2), kept.py_native.len);
    // settled: nothing more is asked
    checkPython(&ta.app, a, 1, &st);
    try tt.expectEqual(@as(u8, 0), st.py_check);
}

test "hots from before the rename move across: each becomes a tot with its goal, settings, grant and files, the scratchpad follows, then the old Worker goes" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cftot-move-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const w = fakehttp.wire;
    const routes = [_]fakehttp.Route{
        // the old runtime
        .{ .method = "GET", .path = "/v1/hots/Gary/notes", .reply = w("{\"ok\":true,\"notes\":[{\"name\":\"plan.md\",\"t\":5,\"text\":\"# the plan\"}],\"more\":false}") },
        .{ .method = "GET", .path = "/v1/hots/Ada/notes", .reply = w("{\"ok\":true,\"notes\":[],\"more\":false}") },
        .{ .method = "GET", .path = "/v1/hots", .reply = w("{\"ok\":true,\"hots\":[" ++
            "{\"name\":\"Gary\",\"model\":\"@cf/meta/llama-3.3-70b-instruct-fp8-fast\",\"pace_s\":10,\"size\":3,\"daily_calls\":0,\"charter\":\"\",\"paused\":false,\"goal\":{\"text\":\"chart the tides\",\"status\":\"active\",\"forever\":true,\"budget\":null}}," ++
            "{\"name\":\"Ada\",\"model\":\"@cf/meta/llama-3.3-70b-instruct-fp8-fast\",\"pace_s\":60,\"size\":1,\"daily_calls\":400,\"charter\":\"keep the docs fresh\",\"paused\":true,\"goal\":{\"text\":\"done thing\",\"status\":\"achieved\"}}]}") },
        .{ .method = "GET", .path = "/v1/pad?after=0", .reply = w("{\"ok\":true,\"entries\":[{\"seq\":1,\"t\":9,\"from\":\"Gary\",\"text\":\"hello from before\"}],\"seq\":1}") },
        // the Cloudflare API: the new runtime goes up
        .{ .method = "GET", .path = "/accounts/acct/workers/subdomain", .reply = StandIn.subdomain },
        .{ .method = "GET", .path = "/workers/scripts/veil-tots/settings", .reply = StandIn.no_script },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots-py", .reply = StandIn.ok },
        .{ .method = "PUT", .path = "/workers/scripts/veil-tots", .reply = StandIn.ok },
        .{ .method = "POST", .path = "/workers/scripts/veil-tots/subdomain", .reply = StandIn.ok },
        // the new runtime
        .{ .method = "GET", .path = "/v1/tots", .reply = w("{\"ok\":true,\"tots\":[]}") },
        .{ .method = "POST", .path = "/v1/tots/", .reply = w("{\"ok\":true,\"files\":1}") },
        .{ .method = "POST", .path = "/v1/tots", .reply = w("{\"ok\":true,\"tot\":{\"name\":\"Gary\"}}"), .times = 1 },
        .{ .method = "POST", .path = "/v1/tots", .reply = w("{\"ok\":true,\"tot\":{\"name\":\"Ada\"}}"), .times = 1 },
        .{ .method = "POST", .path = "/v1/pad/import", .reply = w("{\"ok\":true,\"imported\":1}") },
        // and the old Workers go
        .{ .method = "DELETE", .path = "/workers/scripts/veil-hots", .reply = StandIn.ok },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.ok);
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

    // what travels: an active goal; a finished one leaves the charter alone; with neither, MOVED_GOAL
    const g = movedReq(.{ .name = "Gary", .model = "@cf/x", .goal = .{ .text = "chart the tides", .status = "active", .forever = true } }, &.{"gary"});
    try tt.expectEqualStrings("chart the tides", g.goal);
    try tt.expect(g.forever and g.local);
    const ada = movedReq(.{ .name = "Ada", .model = "@cf/x", .charter = "keep the docs fresh", .goal = .{ .text = "done thing", .status = "achieved" } }, &.{"Gary"});
    try tt.expectEqualStrings("", ada.goal);
    try tt.expect(!ada.local);
    try tt.expectEqualStrings(MOVED_GOAL, movedReq(.{ .name = "Bo", .model = "@cf/x" }, &.{}).goal);

    // the old state, but logged in to another account: nothing is touched
    var lb: [700]u8 = undefined;
    const lpath = legacyPath(&ta.app, 1, &lb).?;
    writeLegacy(&ta.app, 1, .{ .account = "acct", .url = stand_in, .token_gen = 2, .local = &.{"Gary"} });
    try tt.expect(moveFromHots(&ta.app, a, 1, .{ .key = "k", .account_id = "other" }) != null);
    try tt.expectEqual(@as(usize, 0), srv.countCalls("GET", "/v1/hots"));
    // an old folder with a run in it
    const run_dir = root ++ "/u1/_hots/Gary-20261001-190430";
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = run_dir ++ "/events.log", .data = "r1 pick ...\n" });

    try tt.expectEqual(@as(?[]const u8, null), moveFromHots(&ta.app, a, 1, tok));
    // nothing left to move: no call at all
    const calls_after = srv.countCalls("GET", "/v1/hots");
    try tt.expectEqual(@as(?[]const u8, null), moveFromHots(&ta.app, a, 1, tok));
    srv.stop();
    running = false;
    try tt.expectEqual(calls_after, srv.countCalls("GET", "/v1/hots"));
    // both came across, Gary first (the runtime names its first tot Gary), each with an import of its files
    try tt.expectEqual(@as(usize, 2), srv.countCalls("POST", "/v1/tots/"));
    const gary_imp = srv.firstCall("POST", "/v1/tots/Gary/import").?;
    const ada_imp = srv.firstCall("POST", "/v1/tots/Ada/import").?;
    try tt.expect(gary_imp < ada_imp);
    // the scratchpad after the tots, the old Workers last of all
    const pad_imp = srv.firstCall("POST", "/v1/pad/import").?;
    const removed = srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-hots?force=true").?;
    try tt.expect(ada_imp < pad_imp and pad_imp < removed);
    try tt.expect(srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-hots-py?force=true") != null);
    // the new state: deployed, and only the hot that had this machine still has it
    const st = readState(&ta.app, 1, a);
    try tt.expectEqualStrings(stand_in, st.url);
    try tt.expectEqual(@as(usize, 1), st.local.len);
    try tt.expectEqualStrings("Gary", st.local[0]);
    // the old state is gone and the folder moved under the new name
    try tt.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, lpath, .{}));
    try std.Io.Dir.cwd().access(io, root ++ "/u1/_tots/Gary-20261001-190430/events.log", .{});
}

test "a move whose old runtime does not answer removes nothing and keeps the old state for the next attempt" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cftot-move-dark-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &.{}, StandIn.ok);
    var running = true;
    defer if (running) srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // the old runtime's address answers nothing (a closed loopback port)
    writeLegacy(&ta.app, 1, .{ .account = "acct", .url = "http://127.0.0.1:1" });
    try tt.expect(moveFromHots(&ta.app, a, 1, .{ .key = "k", .account_id = "acct" }) != null);
    srv.stop();
    running = false;
    try tt.expectEqual(@as(usize, 0), srv.countCalls("DELETE", "/workers/scripts/veil-hots"));
    try tt.expect(readLegacy(&ta.app, 1, a) != null);
}

test "removing a run hides only its history entry and preserves files and other users' runs" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cftot-hide-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const leaf = "Gary-20261002-090000";
    const events = "{\"seq\":1,\"text\":\"keep this event\"}\n";
    for ([_]u64{ 1, 2 }) |uid| {
        const path = try std.fmt.allocPrint(a, root ++ "/u{d}/_tots/" ++ leaf, .{uid});
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, .default_dir);
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "status.json", .data = "{\"state\":\"failed\"}" });
        try dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = events });
    }
    try tt.expectError(error.BadRunName, hideRun(&ta.app, a, 1, "../" ++ leaf));
    try tt.expectError(error.FileNotFound, hideRun(&ta.app, a, 1, "Ada-20261002-090000"));
    try hideRun(&ta.app, a, 1, leaf);
    try hideRun(&ta.app, a, 1, leaf); // idempotent
    const List = struct { runs: []const std.json.Value };
    const mine = try std.json.parseFromSliceLeaky(List, a, try runsJson(&ta.app, a, 1), .{ .ignore_unknown_fields = true });
    const theirs = try std.json.parseFromSliceLeaky(List, a, try runsJson(&ta.app, a, 2), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(usize, 0), mine.runs.len);
    try tt.expectEqual(@as(usize, 1), theirs.runs.len);
    const kept = try std.Io.Dir.cwd().readFileAlloc(io, root ++ "/u1/_tots/" ++ leaf ++ "/events.jsonl", gpa, .limited(1024));
    defer gpa.free(kept);
    try tt.expectEqualStrings(events, kept);
    // Restoring the marker restores the same entry and its original events.
    try std.Io.Dir.cwd().deleteFile(io, root ++ "/u1/_tots/" ++ leaf ++ "/.hidden");
    const restored = try std.json.parseFromSliceLeaky(List, a, try runsJson(&ta.app, a, 1), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(usize, 1), restored.runs.len);
}

test "every deployment is a run of its own: a failed one is kept with its error, runs list newest first, a run's events read from its folder" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-cftot-runs-tmp";
    var ta = try http.testApp(gpa, io, root);
    defer ta.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try tt.expect(runLeafOk("Gary-20261002-090000"));
    try tt.expect(!runLeafOk("Gary-2026100-090000"));
    try tt.expect(!runLeafOk("../x-20261002-090000"));
    try tt.expect(!runLeafOk("Gary-20261002_090000"));
    try tt.expect(!runLeafOk("scratchpad.md"));

    // an earlier run of Gary that ran and was deleted, with three events
    const old = root ++ "/u1/_tots/Gary-20261001-120000";
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, old, .default_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = old ++ "/status.json", .data = "{\"name\":\"Gary\",\"state\":\"working\",\"seq\":3,\"goal\":{\"text\":\"map the harbour\"}}" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = old ++ "/events.jsonl", .data = "{\"seq\":1,\"kind\":\"goal\",\"text\":\"map the harbour\"}\n{\"seq\":2,\"kind\":\"pick\",\"text\":\"read the charts\"}\n{\"seq\":3,\"kind\":\"verdict\",\"text\":\"improved\"}\n" });
    markEnded(&ta.app, a, "u1/_tots/Gary-20261001-120000", "deleted");

    // a deployment that fails is kept as a run, with what was asked and why it failed
    const leaf = recordFailed(&ta.app, a, 1, .{ .name = "Ada", .goal = "watch the tide tables", .model = "@cf/x/y" }, "the account has no Workers subdomain").?;
    try tt.expect(runLeafOk(leaf));
    try tt.expect(std.mem.startsWith(u8, leaf, "Ada-"));
    // no valid name: still a run
    try tt.expect(std.mem.startsWith(u8, recordFailed(&ta.app, a, 1, .{ .name = "bad name!" }, "x").?, "unnamed-"));

    const R = struct { ok: bool, runs: []const struct { leaf: []const u8, name: []const u8, state: []const u8, @"error": []const u8, goal: []const u8, events: i64 } };
    const runs = try std.json.parseFromSliceLeaky(R, a, try runsJson(&ta.app, a, 1), .{ .ignore_unknown_fields = true });
    try tt.expect(runs.ok);
    try tt.expectEqual(@as(usize, 3), runs.runs.len);
    try tt.expectEqualStrings("Gary-20261001-120000", runs.runs[runs.runs.len - 1].leaf); // the oldest last
    try tt.expectEqualStrings("deleted", runs.runs[runs.runs.len - 1].state);
    try tt.expectEqualStrings("map the harbour", runs.runs[runs.runs.len - 1].goal);
    var failed_seen = false;
    for (runs.runs) |r| if (std.mem.eql(u8, r.leaf, leaf)) {
        failed_seen = true;
        try tt.expectEqualStrings("failed", r.state);
        try tt.expectEqualStrings("the account has no Workers subdomain", r.@"error");
        try tt.expectEqualStrings("watch the tide tables", r.goal);
    };
    try tt.expect(failed_seen);

    // a run's events, past `after`, the newest `limit`
    const E = struct { ok: bool, events: []const struct { seq: u64, kind: []const u8 = "", ok: ?bool = null } };
    const all = try std.json.parseFromSliceLeaky(E, a, try runEventsJson(&ta.app, a, 1, "Gary-20261001-120000", 0, 200, false), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(usize, 3), all.events.len);
    const later = try std.json.parseFromSliceLeaky(E, a, try runEventsJson(&ta.app, a, 1, "Gary-20261001-120000", 1, 200, false), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(u64, 2), later.events[0].seq);
    const last = try std.json.parseFromSliceLeaky(E, a, try runEventsJson(&ta.app, a, 1, "Gary-20261001-120000", 0, 1, false), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(usize, 1), last.events.len);
    try tt.expectEqual(@as(u64, 3), last.events[0].seq);
    // forward (what `veil --tater verify` walks): the FIRST `limit` past `after`, from the run's first event on
    const fwd = try std.json.parseFromSliceLeaky(E, a, try runEventsJson(&ta.app, a, 1, "Gary-20261001-120000", 0, 1, true), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(usize, 1), fwd.events.len);
    try tt.expectEqual(@as(u64, 1), fwd.events[0].seq);
    const fwd2 = try std.json.parseFromSliceLeaky(E, a, try runEventsJson(&ta.app, a, 1, "Gary-20261001-120000", 1, 2, true), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(usize, 2), fwd2.events.len);
    try tt.expectEqual(@as(u64, 2), fwd2.events[0].seq);
    const fail_ev = try std.json.parseFromSliceLeaky(E, a, try runEventsJson(&ta.app, a, 1, leaf, 0, 200, false), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(usize, 2), fail_ev.events.len);
    try tt.expectEqualStrings("error", fail_ev.events[1].kind);
    try tt.expectEqual(@as(?bool, false), fail_ev.events[1].ok);
    // a run with no folder has no events, and that is not an error
    const none = try std.json.parseFromSliceLeaky(E, a, try runEventsJson(&ta.app, a, 1, "Nova-20261002-000000", 0, 200, false), .{ .ignore_unknown_fields = true });
    try tt.expectEqual(@as(usize, 0), none.events.len);
}

test "security removal stops its Container and backend before clearing local state" {
    const gpa = tt.allocator;
    const io = tt.io;
    var ta = try http.testApp(gpa, io, "zig-gary-remove-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/workers/durable_objects/namespaces", .reply = fakehttp.wire("{\"success\":true,\"result\":[{\"id\":\"own-gary\",\"script\":\"veil-garrett-gary\",\"class\":\"GaryContainer\"},{\"id\":\"unrelated\",\"script\":\"other\",\"class\":\"GaryContainer\"}]}") },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.ok);
    defer srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .garrett_url = "https://agent.example.test", .garrett_account = "acct" };
    writeState(&ta.app, 1, st);
    try tt.expect(removeGarrett(&ta.app, a, 1, .{ .key = "test-bearer", .account_id = "acct" }, &st) == null);
    const frontend = srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-garrett?force=true").?;
    const container = srv.firstCall("DELETE", "/accounts/acct/containers/applications/own-gary").?;
    const backend = srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-garrett-gary?force=true").?;
    try tt.expect(frontend < container and container < backend);
    try tt.expect(srv.firstCall("DELETE", "/accounts/acct/containers/applications/unrelated") == null);
    try tt.expectEqualStrings("", readState(&ta.app, 1, a).garrett_url);
}

test "failed security Container removal keeps state for an explicit retry" {
    const gpa = tt.allocator;
    const io = tt.io;
    var ta = try http.testApp(gpa, io, "zig-gary-remove-failed-tmp");
    defer ta.deinit();
    if (!curlRuns(gpa, io)) return error.SkipZigTest;
    const routes = [_]fakehttp.Route{
        .{ .method = "GET", .path = "/workers/durable_objects/namespaces", .reply = fakehttp.wire("{\"success\":true,\"result\":[{\"id\":\"own-gary\",\"script\":\"veil-garrett-gary\",\"class\":\"GaryContainer\"}]}") },
        .{ .method = "DELETE", .path = "/containers/applications/own-gary", .reply = fakehttp.wire("{\"success\":false,\"errors\":[{\"message\":\"permission denied\"}]}") },
    };
    var srv: fakehttp.Server = undefined;
    try srv.startRouted(io, &routes, StandIn.ok);
    defer srv.stop();
    var rb: [80]u8 = undefined;
    ta.app.cf_api_root = try std.fmt.bufPrint(&rb, "http://127.0.0.1:{d}/client/v4", .{srv.port});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st: State = .{ .garrett_url = "https://agent.example.test", .garrett_account = "acct" };
    writeState(&ta.app, 1, st);
    const why = removeGarrett(&ta.app, a, 1, .{ .key = "test-bearer", .account_id = "acct" }, &st) orelse return error.TestUnexpectedResult;
    try tt.expect(std.mem.indexOf(u8, why, "removing the security Container") != null);
    try tt.expect(std.mem.indexOf(u8, why, "Disconnect and log in with Cloudflare again") != null);
    try tt.expectEqualStrings("https://agent.example.test", readState(&ta.app, 1, a).garrett_url);
    try tt.expect(srv.firstCall("DELETE", "/accounts/acct/workers/scripts/veil-garrett-gary?force=true") == null);
}
