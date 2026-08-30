//! cf_r2.zig — the Cloudflare R2 chat/data backup for a "Log in with Cloudflare" user.
//!
//! WHAT: a signed-in user's conversations and durable data are mirrored INTO THEIR OWN Cloudflare
//! account — a bucket the veil creates for them ("nl-veil") on first login, objects written with the
//! same OAuth token the chat turns already use. R2's free tier (10 GB, zero egress) means even a free
//! Cloudflare account can hold years of transcripts; the data also stays local — this is a copy, not
//! a move, and nothing here ever deletes a local file.
//!
//! HOW: the Cloudflare REST API, not S3 — POST /accounts/{id}/r2/buckets to create, PUT
//! /accounts/{id}/r2/buckets/{b}/objects/{key} to upload — because REST takes the same Bearer token
//! the vault already holds (S3 would need separate R2 access keys the user never pasted). Requires
//! the workers-r2.write OAuth scope, and R2 activated on the account (a one-time checkout on
//! Cloudflare's side, free tier included); when either is missing the sync records WHY in its status
//! and stays quiet — login itself never depends on this module succeeding.
//!
//! WHEN: a successful OAuth callback kicks the first sync (cf_oauth.callback), and every status poll
//! from a connected client re-arms a throttled background pass (maybeAutoSync, 15-min cadence) — so
//! backup rides the polling that already exists instead of needing its own daemon. "Sync now" is a
//! POST away. Each pass is INCREMENTAL: a jsonl manifest of relpath -> size uploaded lasts across
//! restarts, and only files whose size moved re-upload (the tree is append-heavy jsonl, where any
//! change moves the size).
//!
//! WHAT SYNCS: per-conversation messages.jsonl / context.json / brief.json / plan.jsonl / files.jsonl,
//! and the durable memories. NOT events.jsonl (huge, replayable), NOT build workdirs (that is code,
//! and it can be gigabytes), NOT anything from the sealed vault, and NOT the scheduled-task
//! definitions ({data}/u{uid}/_sched/*.json): the ON-DISK task files carry the REAL per-task
//! api_key/think_api_key/prompt_api_key (sched.zig redacts them only on the HTTP surface — "stored
//! api_key NEVER leaves the server"), so uploading them verbatim would ship pasted provider secrets
//! into the bucket. Task definitions can join the backup only via a redacted re-encode.

const std = @import("std");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const cf_oauth = @import("cf_oauth.zig");
const App = http.App;
const requireUser = http.requireUser;
const badReq = http.badReq;

/// One bucket name for every user: the bucket lives in the USER'S Cloudflare account, so the account
/// boundary is the isolation. Object keys are still prefixed u{uid}/ so two veil accounts sharing one
/// Cloudflare account (a team box) never collide.
pub const BUCKET = "nl-veil";

const STATE_FILE = ".cf_r2.json"; // {data}/u{uid}/.cf_r2.json — status the UIs read
const MANIFEST_FILE = ".cf_r2_manifest.jsonl"; // relpath -> size at last successful upload
const AUTO_SYNC_S: i64 = 900; // background cadence once any client is polling status
const MAX_FILE_BYTES: u64 = 8 << 20; // one object cap (REST upload limit is 300 MB; chats never near it)
const MAX_PASS_FILES: usize = 32; // per-pass upload caps: a huge backlog drains over
const MAX_PASS_BYTES: u64 = 32 << 20; // several passes instead of camping a thread

// ---------------------------------------------------------------------------------- per-user state file

const State = struct {
    auto: bool = true, // auto-backup on status polls; "Sync now" always works
    bucket_ok: bool = false, // bucket confirmed present (sticky — clears only on error 100xx re-create)
    last_sync: i64 = 0, // when a pass last RAN
    last_ok: i64 = 0, // when a pass last finished with zero failures
    files: u64 = 0, // manifest totals after the last pass
    bytes: u64 = 0,
    pending: bool = false, // a pass hit its upload caps with work left over
    skipped: u64 = 0, // candidates over MAX_FILE_BYTES this pass — backed up STALE, and the card says so
    last_error: []const u8 = "",
};

fn statePath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ STATE_FILE, .{ app.data, uid }) catch null;
}

fn manifestPath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/" ++ MANIFEST_FILE, .{ app.data, uid }) catch null;
}

/// The stored state, or defaults when none exists yet. Strings are duped into `alloc`.
fn readState(app: *App, uid: u64, alloc: std.mem.Allocator) State {
    var pb: [600]u8 = undefined;
    const path = statePath(app, uid, &pb) orelse return .{};
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(16384)) catch return .{};
    defer app.gpa.free(raw);
    const parsed = std.json.parseFromSlice(State, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    var s = parsed.value;
    s.last_error = alloc.dupe(u8, s.last_error) catch "";
    return s;
}

fn writeState(app: *App, uid: u64, s: State) void {
    var pb: [600]u8 = undefined;
    const path = statePath(app, uid, &pb) orelse return;
    var db: [600]u8 = undefined;
    if (std.fmt.bufPrint(&db, "{s}/u{d}", .{ app.data, uid })) |dir| {
        _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    } else |_| {}
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    out.print(app.gpa, "{{\"auto\":{},\"bucket_ok\":{},\"last_sync\":{d},\"last_ok\":{d},\"files\":{d},\"bytes\":{d},\"pending\":{},\"skipped\":{d},\"last_error\":", .{ s.auto, s.bucket_ok, s.last_sync, s.last_ok, s.files, s.bytes, s.pending, s.skipped }) catch return;
    http.jstr(app.gpa, &out, s.last_error) catch return;
    out.append(app.gpa, '}') catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch {};
}

// ---------------------------------------------------------------------------------- singleflight + throttle

/// One sync per user at a time, and a small in-memory last-kick table so a 2s status poll costs no
/// file reads between auto passes. Slots, not a map: the working set is "users with a client open".
const SLOTS = 8;
var guard_mtx: std.Io.Mutex = .init;
var busy_uids: [SLOTS]u64 = @splat(0);
var kick_uids: [SLOTS]u64 = @splat(0);
var kick_at: [SLOTS]i64 = @splat(0);

fn nowS(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn sfAcquire(io: std.Io, uid: u64) bool {
    guard_mtx.lockUncancelable(io);
    defer guard_mtx.unlock(io);
    var free: ?usize = null;
    for (busy_uids, 0..) |b, i| {
        if (b == uid) return false;
        if (b == 0 and free == null) free = i;
    }
    const slot = free orelse return false; // table full: skip this pass rather than queue
    busy_uids[slot] = uid;
    return true;
}

fn sfRelease(io: std.Io, uid: u64) void {
    guard_mtx.lockUncancelable(io);
    defer guard_mtx.unlock(io);
    for (&busy_uids) |*b| if (b.* == uid) {
        b.* = 0;
    };
}

fn sfBusy(io: std.Io, uid: u64) bool {
    guard_mtx.lockUncancelable(io);
    defer guard_mtx.unlock(io);
    for (busy_uids) |b| if (b == uid) return true;
    return false;
}

/// True once per AUTO_SYNC_S per uid — the caller only proceeds (and only touches disk) on true.
fn throttlePassed(io: std.Io, uid: u64) bool {
    const now = nowS(io);
    guard_mtx.lockUncancelable(io);
    defer guard_mtx.unlock(io);
    var free: usize = 0;
    var oldest: i64 = std.math.maxInt(i64);
    for (kick_uids, 0..) |k, i| {
        if (k == uid) {
            if (now - kick_at[i] < AUTO_SYNC_S) return false;
            kick_at[i] = now;
            return true;
        }
        if (kick_at[i] < oldest) {
            oldest = kick_at[i];
            free = i;
        }
    }
    kick_uids[free] = uid;
    kick_at[free] = now;
    return true;
}

// ---------------------------------------------------------------------------------- kicking a background pass

const Ctx = struct { app: *App, uid: u64 };

fn syncThread(ctx: *Ctx) void {
    const app = ctx.app;
    const uid = ctx.uid;
    app.gpa.destroy(ctx);
    syncUser(app, uid);
}

/// Run a sync for `uid` on a detached thread, now. Used by the OAuth callback (first provision) and
/// the "Sync now" route. Never blocks the caller; overlapping kicks collapse in the singleflight.
pub fn kickSync(app: *App, uid: u64) void {
    const ctx = app.gpa.create(Ctx) catch return;
    ctx.* = .{ .app = app, .uid = uid };
    if (std.Thread.spawn(.{}, syncThread, .{ctx})) |t| t.detach() else |_| app.gpa.destroy(ctx);
}

/// The throttled auto-backup heartbeat: called from every connected status poll; runs a real pass at
/// most every AUTO_SYNC_S, and only when the user hasn't switched auto off. The in-memory throttle is
/// the cheap first gate; the state file's own last_sync is the durable second one — it is what keeps
/// a slot-table eviction (9+ connected users) or a restart from turning every poll into a full pass.
pub fn maybeAutoSync(app: *App, uid: u64) void {
    if (!throttlePassed(app.io, uid)) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const st = readState(app, uid, arena.allocator());
    if (!st.auto) return;
    if (nowS(app.io) - st.last_sync < AUTO_SYNC_S) return;
    kickSync(app, uid);
}

// ---------------------------------------------------------------------------------- Cloudflare R2 REST

const ApiResp = struct {
    success: bool = false,
    errors: []const struct { code: i64 = 0, message: []const u8 = "" } = &.{},
};

fn parseResp(app: *App, raw: []const u8, alloc: std.mem.Allocator) ?struct { success: bool, code: i64, message: []const u8 } {
    const parsed = std.json.parseFromSlice(ApiResp, app.gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.errors.len > 0) {
        return .{ .success = parsed.value.success, .code = parsed.value.errors[0].code, .message = alloc.dupe(u8, parsed.value.errors[0].message) catch "" };
    }
    return .{ .success = parsed.value.success, .code = 0, .message = "" };
}

/// Make sure the user's backup bucket exists: confirm with a GET, else create it. Sticky on success.
/// On failure records the API's own words (most commonly: R2 not activated on the account) so the
/// status card can tell the user exactly what to click on Cloudflare's side.
fn ensureBucket(app: *App, st: *State, account: []const u8, bearer: []const u8, alloc: std.mem.Allocator) bool {
    if (st.bucket_ok) return true;
    var ub: [700]u8 = undefined;
    const url = std.fmt.bufPrint(&ub, "{s}/{s}/r2/buckets/" ++ BUCKET, .{ app.cf_oauth_accounts_url, account }) catch return false;
    if (cf_oauth.apiCall(app, "GET", url, "", bearer, "")) |raw| {
        defer app.gpa.free(raw);
        if (parseResp(app, raw, alloc)) |r| if (r.success) {
            st.bucket_ok = true;
            st.last_error = "";
            return true;
        };
    }
    const curl = std.fmt.bufPrint(&ub, "{s}/{s}/r2/buckets", .{ app.cf_oauth_accounts_url, account }) catch return false;
    const raw = cf_oauth.apiCall(app, "POST", curl, "{\"name\":\"" ++ BUCKET ++ "\"}", bearer, "application/json") orelse {
        st.last_error = "could not reach the Cloudflare R2 API";
        return false;
    };
    defer app.gpa.free(raw);
    const r = parseResp(app, raw, alloc) orelse {
        st.last_error = "unreadable answer from the Cloudflare R2 API";
        return false;
    };
    // 10004: a bucket by this name already exists (owned by this account) — that IS the bucket.
    if (r.success or r.code == 10004) {
        st.bucket_ok = true;
        st.last_error = "";
        return true;
    }
    st.last_error = if (r.message.len > 0)
        std.fmt.allocPrint(alloc, "R2 bucket: {s}", .{r.message}) catch "R2 bucket create failed"
    else
        "R2 bucket create failed (is R2 activated on your Cloudflare account?)";
    return false;
}

/// PUT one object. The key is u{uid}/{rel} — slashes are sent literally, exactly as the API expects.
fn putObject(app: *App, account: []const u8, bearer: []const u8, uid: u64, rel: []const u8, data: []const u8) bool {
    var ub: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(&ub, "{s}/{s}/r2/buckets/" ++ BUCKET ++ "/objects/u{d}/{s}", .{ app.cf_oauth_accounts_url, account, uid, rel }) catch return false;
    const raw = cf_oauth.apiCall(app, "PUT", url, data, bearer, "application/octet-stream") orelse return false;
    defer app.gpa.free(raw);
    var scratch = std.heap.ArenaAllocator.init(app.gpa);
    defer scratch.deinit();
    const r = parseResp(app, raw, scratch.allocator()) orelse return false;
    return r.success;
}

// ---------------------------------------------------------------------------------- what syncs

/// A relpath may become part of an unencoded URL and an object key: keep it to the same conservative
/// charset the conv ids already satisfy, and never let a separator trick through. Rejecting an odd
/// name skips ONE file, silently — the safe direction for a backup.
fn keySafe(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > 512) return false;
    if (rel[0] == '/' or rel[rel.len - 1] == '/') return false;
    if (std.mem.indexOf(u8, rel, "..") != null) return false;
    for (rel) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '/';
        if (!ok) return false;
    }
    return true;
}

/// The per-conversation files worth keeping. events.jsonl is deliberately absent (see module doc).
const CONV_FILES = [_][]const u8{ "messages.jsonl", "context.json", "brief.json", "plan.jsonl", "files.jsonl" };

/// Collect every candidate relpath (relative to {data}/u{uid}) into `list` (arena-owned strings).
fn collectCandidates(app: *App, uid: u64, a: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    var pb: [700]u8 = undefined;
    // conversations
    if (std.fmt.bufPrint(&pb, "{s}/u{d}/_chat/convs", .{ app.data, uid })) |convs_root| {
        if (std.Io.Dir.cwd().openDir(app.io, convs_root, .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            defer dir.close(app.io);
            var it = dir.iterate();
            while (it.next(app.io) catch null) |ent| {
                if (ent.kind != .directory) continue;
                for (CONV_FILES) |f| {
                    const rel = std.fmt.allocPrint(a, "_chat/convs/{s}/{s}", .{ ent.name, f }) catch continue;
                    list.append(a, rel) catch return;
                }
            }
        } else |_| {}
    } else |_| {}
    // durable memories
    list.append(a, ".veil-desk/memories.jsonl") catch return;
    // NO _sched/*.json here — the on-disk task files hold real provider keys (see the module doc).
}

// ---------------------------------------------------------------------------------- the manifest

/// What the manifest remembers per file: the size at the last successful upload, and — for the
/// rewrite-in-place JSON files — a content hash, because a whole-file rewrite can land on the same
/// byte length and size alone would call it unchanged forever.
const ManEntry = struct { sz: u64 = 0, h: u64 = 0 };

/// relpath -> ManEntry, one JSON line each, arena-owned.
fn loadManifest(app: *App, uid: u64, a: std.mem.Allocator) std.StringHashMapUnmanaged(ManEntry) {
    var map: std.StringHashMapUnmanaged(ManEntry) = .empty;
    var pb: [600]u8 = undefined;
    const path = manifestPath(app, uid, &pb) orelse return map;
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(4 << 20)) catch return map;
    defer app.gpa.free(raw);
    const Line = struct { p: []const u8 = "", sz: u64 = 0, h: u64 = 0 };
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(Line, app.gpa, trimmed, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (parsed.value.p.len == 0) continue;
        const key = a.dupe(u8, parsed.value.p) catch continue;
        map.put(a, key, .{ .sz = parsed.value.sz, .h = parsed.value.h }) catch continue;
    }
    return map;
}

fn writeManifest(app: *App, uid: u64, map: *std.StringHashMapUnmanaged(ManEntry)) void {
    var pb: [600]u8 = undefined;
    const path = manifestPath(app, uid, &pb) orelse return;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    var it = map.iterator();
    while (it.next()) |e| {
        out.appendSlice(app.gpa, "{\"p\":") catch return;
        http.jstr(app.gpa, &out, e.key_ptr.*) catch return;
        out.print(app.gpa, ",\"sz\":{d},\"h\":{d}}}\n", .{ e.value_ptr.sz, e.value_ptr.h }) catch return;
    }
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// Does this file need content-hash change detection? The jsonl files are append-only (any change
/// moves the size); context.json and brief.json are rewritten whole and can keep their length.
fn needsHash(rel: []const u8) bool {
    return std.mem.endsWith(u8, rel, "/context.json") or std.mem.endsWith(u8, rel, "/brief.json");
}

// ---------------------------------------------------------------------------------- one sync pass

/// One incremental backup pass for `uid`. Runs on its own thread; everything is best-effort and the
/// outcome — including why nothing could run — lands in the state file the status route serves.
pub fn syncUser(app: *App, uid: u64) void {
    if (!sfAcquire(app.io, uid)) return;
    defer sfRelease(app.io, uid);

    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var st = readState(app, uid, a);
    st.last_sync = nowS(app.io);
    st.pending = false;

    const tok = cf_oauth.resolveToken(app, uid, a) orelse {
        st.last_error = "not connected to Cloudflare";
        writeState(app, uid, st);
        return;
    };
    if (!ensureBucket(app, &st, tok.account_id, tok.key, a)) {
        writeState(app, uid, st);
        return;
    }

    var man = loadManifest(app, uid, a);
    var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
    collectCandidates(app, uid, a, &candidates);

    var uploads: usize = 0;
    var pass_bytes: u64 = 0;
    var failures: usize = 0;
    var skipped_big: u64 = 0;
    for (candidates.items) |rel| {
        if (!keySafe(rel)) continue;
        var fb: [900]u8 = undefined;
        const full = std.fmt.bufPrint(&fb, "{s}/u{d}/{s}", .{ app.data, uid, rel }) catch continue;
        const fst = std.Io.Dir.cwd().statFile(app.io, full, .{}) catch continue; // absent → nothing to back up
        if (fst.size == 0) continue;
        if (fst.size > MAX_FILE_BYTES) {
            skipped_big += 1; // counted and surfaced — a frozen backup must not read as a healthy one
            continue;
        }
        const prev = man.get(rel);
        const hashed = needsHash(rel);
        // size-only fast path: append-heavy files whose size hasn't moved are unchanged
        if (!hashed) if (prev) |p| if (p.sz == fst.size) continue;
        if (uploads >= MAX_PASS_FILES or pass_bytes + fst.size > MAX_PASS_BYTES) {
            st.pending = true; // more work than one pass carries — the next pass continues
            continue;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(app.io, full, a, .limited(MAX_FILE_BYTES)) catch continue;
        var h: u64 = 0;
        if (hashed) {
            h = std.hash.Fnv1a_64.hash(data);
            if (prev) |p| if (p.sz == data.len and p.h == h) continue; // same length AND same content
        }
        if (putObject(app, tok.account_id, tok.key, uid, rel, data)) {
            const key = a.dupe(u8, rel) catch continue;
            man.put(a, key, .{ .sz = data.len, .h = h }) catch {};
            uploads += 1;
            pass_bytes += data.len;
        } else {
            failures += 1;
        }
    }

    if (uploads > 0) writeManifest(app, uid, &man);
    st.files = man.count();
    st.bytes = blk: {
        var sum: u64 = 0;
        var it = man.valueIterator();
        while (it.next()) |v| sum += v.sz;
        break :blk sum;
    };
    st.skipped = skipped_big;
    if (failures == 0) {
        st.last_ok = nowS(app.io);
        st.last_error = "";
    } else {
        st.last_error = std.fmt.allocPrint(a, "{d} upload(s) failed — will retry next pass", .{failures}) catch "some uploads failed";
    }
    // The pass owns everything in `st` EXCEPT the auto switch — the user may have flipped it while the
    // uploads ran (r2SetAuto writes the file mid-pass), and clobbering that choice would keep backing
    // up against an explicit opt-out. Re-read and keep theirs.
    st.auto = readState(app, uid, a).auto;
    writeState(app, uid, st);
}

// ---------------------------------------------------------------------------------- HTTP handlers

/// GET /api/v1/oauth/cloudflare/r2 — this user's backup status: connected, bucket, auto, last pass,
/// totals, and the last error in the API's own words. What every R2 card renders.
pub fn r2Status(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var connected = false;
    if (app.vault.resolveOAuth(u.id, cf_oauth.CF_PROVIDER, a)) |b| connected = b.refresh_token.len > 0;
    const st = readState(app, u.id, a);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(app.gpa);
    try out.print(app.gpa, "{{\"ok\":true,\"connected\":{},\"bucket\":\"" ++ BUCKET ++ "\",\"bucket_ok\":{},\"auto\":{},\"busy\":{},\"pending\":{},\"skipped\":{d},\"last_sync\":{d},\"last_ok\":{d},\"files\":{d},\"bytes\":{d},\"last_error\":", .{ connected, st.bucket_ok, st.auto, sfBusy(app.io, u.id), st.pending, st.skipped, st.last_sync, st.last_ok, st.files, st.bytes });
    try http.jstr(app.gpa, &out, st.last_error);
    try out.append(app.gpa, '}');
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, out.items);
}

/// POST /api/v1/oauth/cloudflare/r2/sync — run a backup pass now (bucket provision included).
pub fn r2SyncNow(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    var connected = false;
    if (app.vault.resolveOAuth(u.id, cf_oauth.CF_PROVIDER, arena.allocator())) |b| connected = b.refresh_token.len > 0;
    if (!connected) return badReq(res, "not connected to Cloudflare — log in first");
    kickSync(app, u.id);
    try res.json(.{ .ok = true, .started = true }, .{});
}

const AutoReq = struct { auto: bool };

/// POST /api/v1/oauth/cloudflare/r2/auto — flip the auto-backup switch for this user.
pub fn r2SetAuto(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = requireUser(app, req, res) orelse return;
    const body = (req.json(AutoReq) catch return badReq(res, "malformed JSON body")) orelse return badReq(res, "bad body");
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    var st = readState(app, u.id, arena.allocator());
    st.auto = body.auto;
    writeState(app, u.id, st);
    try res.json(.{ .ok = true, .auto = body.auto }, .{});
}

// ---------------------------------------------------------------------------
// tests — see harness/TESTING.md (Handlers).
// ---------------------------------------------------------------------------

test "every r2 route is gated: an anonymous caller gets 401 and nothing runs" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var ta = try http.testApp(gpa, io, "zig-cfr2-tmp");
    defer ta.deinit();

    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        try r2Status(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        try r2SyncNow(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.json(.{ .auto = false });
        try r2SetAuto(&ta.app, web.req, web.res);
        try web.expectStatus(401);
    }
}

test "keySafe: conservative charset, no traversal, no separator tricks" {
    try std.testing.expect(keySafe("_chat/convs/web-20260830/messages.jsonl"));
    try std.testing.expect(keySafe(".veil-desk/memories.jsonl"));
    try std.testing.expect(keySafe("_sched/task-1.json"));
    try std.testing.expect(!keySafe("")); // empty
    try std.testing.expect(!keySafe("/etc/passwd")); // absolute
    try std.testing.expect(!keySafe("a/../b")); // traversal
    try std.testing.expect(!keySafe("a\\b.jsonl")); // backslash is not a separator here
    try std.testing.expect(!keySafe("sp ace.json")); // whitespace never reaches a URL
    try std.testing.expect(!keySafe("q?x=1")); // query metachars stay out of object keys
    try std.testing.expect(!keySafe("trail/")); // no empty final segment
}

test "state round-trips through its JSON, defaults included" {
    const gpa = std.testing.allocator;
    // parse of a minimal blob keeps the defaults for absent fields
    const parsed = try std.json.parseFromSlice(State, gpa, "{\"last_sync\":42}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.auto); // default true — backup is on unless switched off
    try std.testing.expect(!parsed.value.bucket_ok);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.last_sync);
    try std.testing.expectEqualStrings("", parsed.value.last_error);
}
