//! Process-global browser-session registry. A session is stateful and must survive across many tool calls
//! (navigate → read → click → …), but tools.execute() runs per-call with a fresh ToolCtx — so sessions live
//! HERE, keyed by run_dir. run_dir is per-user on the chat surface (`.../u{uid}/_chat/...`) and per-run for a
//! cast, so a keyed session never crosses tenants or runs. All ops serialize on ONE mutex: a browser drives a
//! single page and a cast's minds call concurrently. Enable/gating lives at the tools.zig call sites
//! (NL_BROWSER_DRIVER); this module is pure session plumbing.
//!
//! Each op returns a gpa-owned JSON result string ready to hand back as the tool result (caller frees). A
//! browser process is heavy (~1-2s to launch), so the session is opened lazily on first use and reused; the
//! registry caps live sessions and closes the least-recently-used one on overflow. closeAll() is the teardown
//! hook a long-lived host (worker/server) calls on shutdown so no headless browser is orphaned.

const std = @import("std");
const session = @import("session.zig");
const launch = @import("launch.zig");
const ext = @import("ext.zig");
const Session = session.Session;

const log = std.log.scoped(.browser);

pub const Error = session.Error;

const MAX_SESSIONS = 4;

const Entry = struct {
    key: []u8, // gpa-owned run_dir
    sess: Session,
    last_used: i64,
    headful: bool = false, // whether this session's browser is visible (vs headless)
    // Captured page events, held HERE because draining the session is destructive: browser_console and
    // browser_network are two readers of one stream, and whichever ran first would otherwise consume the
    // other's events. Both drain into this, then read their own slice out of it.
    events: std.ArrayListUnmanaged(u8) = .empty, // NDJSON of raw CDP event frames
    dropped: u32 = 0, // events lost to a buffer cap, anywhere along the path
};

/// Cap on the per-session event store. Beyond this the OLDEST whole lines are discarded — a developer asking
/// what just happened wants the most recent traffic, not the first 512KB of a page's lifetime.
const EVENTS_KEEP: usize = 512 << 10;

var g_mu: std.Io.Mutex = .init;
var g_slots: [MAX_SESSIONS]?Entry = .{null} ** MAX_SESSIONS;

/// Whether the browser should be VISIBLE (headful) vs headless. This is a CLIENT selection: the desk writes
/// `{TEMP}/nl-veil-browser.json` = {"headful":bool} from its Settings toggle, and the daemon reads it per
/// session-open so a toggle takes effect on the next session without an env change. NL_BROWSER_HEADFUL overrides.
fn wantHeadful(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("NL_BROWSER_HEADFUL")) |v| {
        if (v.len > 0) return !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false");
    }
    const base = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR") orelse return false;
    const path = std.fmt.allocPrint(gpa, "{s}/nl-veil-browser.json", .{base}) catch return false;
    defer gpa.free(path);
    const txt = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024)) catch return false;
    defer gpa.free(txt);
    const P = struct { headful: bool = false };
    const p = std.json.parseFromSlice(P, gpa, txt, .{ .ignore_unknown_fields = true }) catch return false;
    defer p.deinit();
    return p.value.headful;
}

/// Is the browser EXTENSION the transport for this session? True when a live, un-paused extension is polling
/// and the operator hasn't opted out with NL_BROWSER_EXT=0.
///
/// This is the fallback seam the whole feature hangs on: when the user's browser is there, drive it (their
/// logins, their profile, a human present to answer a verification prompt); when it isn't — a headless server,
/// a swarm run, the browser closed — nothing changes and we launch our own as before.
fn useExt(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("NL_BROWSER_EXT")) |v| {
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false")) return false;
    }
    return ext.available(gpa, io, env);
}

/// Open a fresh session for `key`. Prefers the user's own browser via the extension; otherwise launches one in
/// the requested headful/headless mode. The launched profile (+ its live DevToolsActivePort file) MUST live on
/// local disk, never OneDrive (sync locks/delays it → PortTimeout), keyed by a hash of run_dir for per-run
/// isolation. An extension session needs none of that — there is no profile of ours involved.
fn openSession(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, headful: bool) Error!Session {
    if (useExt(gpa, io, env)) {
        if (Session.openExt(gpa, io, env)) |s| {
            log.info("browser: session for {s} is driving the user's own browser (extension)", .{key});
            return s;
        } else |e| {
            // The extension said it was there and then failed to open a tab (worker evicted mid-request, a
            // chrome:// page in the way, debugger already attached by DevTools). Falling through to our own
            // browser is strictly better than failing the tool call.
            log.warn("browser: extension present but could not open a tab ({s}) — falling back to a launched browser", .{@errorName(e)});
        }
    }
    const tmp_base = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR");
    const profile = if (tmp_base) |tb|
        std.fmt.allocPrint(gpa, "{s}/nl-veil-cdp/{x}", .{ tb, std.hash.Wyhash.hash(0, key) }) catch return error.OutOfMemory
    else
        std.fmt.allocPrint(gpa, "{s}/.browser-profile", .{key}) catch return error.OutOfMemory;
    defer gpa.free(profile);
    return Session.open(gpa, io, env, .{ .user_data_dir = profile, .headless = !headful });
}

/// Find the live session for `key`, or open one. Caller holds g_mu. If a live session's visibility mode no
/// longer matches the current client selection, it is closed and reopened so the toggle takes effect. Returns
/// a pointer into the fixed slot array (stable while the slot is occupied).
fn ensure(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8) Error!*Session {
    const e = try ensureEntry(gpa, io, env, key);
    return &e.sess;
}

/// As `ensure`, but hands back the whole registry entry — the console/network tools need its event store,
/// not just the session.
fn ensureEntry(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8) Error!*Entry {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const headful = wantHeadful(gpa, io, env);
    var free_i: ?usize = null;
    var lru_i: usize = 0;
    var lru_ts: i64 = std.math.maxInt(i64);
    for (&g_slots, 0..) |*slot, i| {
        if (slot.*) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                // An EXTENSION session has no visibility mode to toggle — it is a tab in a window the user
                // already has open — so the headful check must not churn it. It IS reopened when the
                // extension goes away (browser closed mid-session), which is what makes the fallback live
                // rather than a one-shot decision made when the session first opened.
                const stale_ext = e.sess.isExt() and !useExt(gpa, io, env);
                if (stale_ext or (!e.sess.isExt() and e.headful != headful)) {
                    log.info("browser: reopening session for {s} (headful={}, ext_gone={})", .{ key, headful, stale_ext });
                    e.sess.close();
                    e.sess = try openSession(gpa, io, env, key, headful);
                    e.headful = headful;
                }
                e.last_used = now;
                return e;
            }
            if (e.last_used < lru_ts) {
                lru_ts = e.last_used;
                lru_i = i;
            }
        } else if (free_i == null) {
            free_i = i;
        }
    }
    // No existing session for this key: pick a free slot, else evict the LRU one.
    const idx = free_i orelse blk: {
        if (g_slots[lru_i]) |*e| {
            log.info("browser: evicting LRU session for {s}", .{e.key});
            e.sess.close();
            e.events.deinit(gpa);
            gpa.free(e.key);
            g_slots[lru_i] = null;
        }
        break :blk lru_i;
    };
    const key_dup = gpa.dupe(u8, key) catch return error.OutOfMemory;
    errdefer gpa.free(key_dup);
    const sess = try openSession(gpa, io, env, key, headful);
    g_slots[idx] = .{ .key = key_dup, .sess = sess, .last_used = now, .headful = headful };
    log.info("browser: opened session for {s} (headful={})", .{ key, headful });
    return &g_slots[idx].?;
}

// ------------------------------------------------------------------------------ console + network capture
//
// What a developer opens DevTools for, minus the DevTools. Both tools read ONE captured stream: pull whatever
// the session has buffered into the entry's store, then return the slice each cares about. The store is what
// makes them independent — `browser_console` must not eat the events `browser_network` is about to be asked
// for, and a drain is destructive.
//
// Every path here reports what it could NOT see. A silently-truncated console is worse than no console: it
// reads as "your page is fine" when the answer is "I stopped looking".

/// Pull anything new out of the session into `e.events`, trimming the store from the FRONT (oldest whole
/// lines) when it outgrows the cap. Caller holds g_mu.
fn pumpEvents(gpa: std.mem.Allocator, e: *Entry) void {
    const d = e.sess.drainEvents() catch return;
    defer gpa.free(d.ndjson);
    e.dropped +|= d.dropped;
    if (d.ndjson.len == 0) return;
    e.events.appendSlice(gpa, d.ndjson) catch {
        e.dropped +|= 1;
        return;
    };
    if (e.events.items.len <= EVENTS_KEEP) return;
    // Drop from the front, on a line boundary, so the store stays parseable NDJSON rather than starting
    // mid-object. Counting these as `dropped` is the honesty the header describes.
    const overflow = e.events.items.len - EVENTS_KEEP;
    const cut = (std.mem.indexOfScalarPos(u8, e.events.items, overflow, '\n') orelse (e.events.items.len - 1)) + 1;
    for (e.events.items[0..cut]) |c| {
        if (c == '\n') e.dropped +|= 1;
    }
    std.mem.copyForwards(u8, e.events.items, e.events.items[cut..]);
    e.events.items.len -= cut;
}

/// One captured line, decoded far enough to classify and format it. Fields not present in a given event kind
/// are simply empty — no per-event struct zoo for what is ultimately a log line.
const Ev = struct {
    method: []const u8 = "",
    params: std.json.Value = .null,
};

fn evParam(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn evStr(v: std.json.Value, key: []const u8) []const u8 {
    return switch (evParam(v, key) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn evNum(v: std.json.Value, key: []const u8) i64 {
    return switch (evParam(v, key) orelse return 0) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

/// Flatten a Runtime.consoleAPICalled `args` array into the text a human would have seen in the console.
fn consoleText(gpa: std.mem.Allocator, params: std.json.Value) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const args = switch (evParam(params, "args") orelse std.json.Value{ .null = {} }) {
        .array => |a| a,
        else => return out.toOwnedSlice(gpa) catch @constCast(""),
    };
    for (args.items) |a| {
        if (out.items.len > 0) out.append(gpa, ' ') catch break;
        // `value` for primitives, `description` for objects/errors (which is where a stack trace lives).
        const v = evParam(a, "value");
        const piece: []const u8 = if (v) |vv| switch (vv) {
            .string => |s| s,
            else => std.json.Stringify.valueAlloc(gpa, vv, .{}) catch "",
        } else evStr(a, "description");
        if (piece.len > 0) out.appendSlice(gpa, piece) catch break;
        if (v) |vv| switch (vv) {
            .string => {},
            else => gpa.free(@constCast(piece)),
        };
    }
    return out.toOwnedSlice(gpa) catch @constCast("");
}

/// The console side of the capture: console.* calls, uncaught exceptions, and browser log entries.
pub fn console(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, max: usize) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const e = try ensureEntry(gpa, io, env, key);
    pumpEvents(gpa, e);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":true,\"entries\":[") catch return error.OutOfMemory;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, e.events.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or n >= max) continue;
        const p = std.json.parseFromSlice(Ev, gpa, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        const m = p.value.method;
        var level: []const u8 = "";
        var text: []u8 = @constCast("");
        var owned = false;
        if (std.mem.eql(u8, m, "Runtime.consoleAPICalled")) {
            level = evStr(p.value.params, "type"); // log | warn | error | info | debug
            text = consoleText(gpa, p.value.params);
            owned = true;
        } else if (std.mem.eql(u8, m, "Runtime.exceptionThrown")) {
            level = "exception";
            const det = evParam(p.value.params, "exceptionDetails") orelse std.json.Value{ .null = {} };
            const desc = evStr(evParam(det, "exception") orelse std.json.Value{ .null = {} }, "description");
            text = gpa.dupe(u8, if (desc.len > 0) desc else evStr(det, "text")) catch continue;
            owned = true;
        } else if (std.mem.eql(u8, m, "Log.entryAdded")) {
            const entry = evParam(p.value.params, "entry") orelse std.json.Value{ .null = {} };
            level = evStr(entry, "level");
            text = gpa.dupe(u8, evStr(entry, "text")) catch continue;
            owned = true;
        } else continue;
        defer if (owned) gpa.free(text);
        if (text.len == 0 and level.len == 0) continue;
        const tj = std.json.Stringify.valueAlloc(gpa, text, .{}) catch continue;
        defer gpa.free(tj);
        const seg = std.fmt.allocPrint(gpa, "{s}{{\"level\":\"{s}\",\"text\":{s}}}", .{ if (n > 0) "," else "", level, tj }) catch continue;
        defer gpa.free(seg);
        out.appendSlice(gpa, seg) catch continue;
        n += 1;
    }
    const tail = std.fmt.allocPrint(gpa, "],\"count\":{d},\"dropped\":{d}{s}}}", .{
        n,
        e.dropped,
        if (e.dropped > 0) ",\"note\":\"some events were dropped over the capture cap — this view is partial\"" else "",
    }) catch return error.OutOfMemory;
    defer gpa.free(tail);
    out.appendSlice(gpa, tail) catch return error.OutOfMemory;
    return out.toOwnedSlice(gpa) catch error.OutOfMemory;
}

/// The network side: requests issued, responses received, and — the ones that matter most for debugging —
/// requests that FAILED.
pub fn network(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, max: usize, failures_only: bool) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const e = try ensureEntry(gpa, io, env, key);
    pumpEvents(gpa, e);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":true,\"requests\":[") catch return error.OutOfMemory;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, e.events.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or n >= max) continue;
        const p = std.json.parseFromSlice(Ev, gpa, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        const m = p.value.method;

        var kind: []const u8 = "";
        var url: []const u8 = "";
        var method_s: []const u8 = "";
        var stat: i64 = 0;
        var err_text: []const u8 = "";
        if (std.mem.eql(u8, m, "Network.requestWillBeSent")) {
            if (failures_only) continue;
            kind = "request";
            const rq = evParam(p.value.params, "request") orelse std.json.Value{ .null = {} };
            url = evStr(rq, "url");
            method_s = evStr(rq, "method");
        } else if (std.mem.eql(u8, m, "Network.responseReceived")) {
            const rs = evParam(p.value.params, "response") orelse std.json.Value{ .null = {} };
            stat = evNum(rs, "status");
            if (failures_only and stat < 400) continue;
            kind = "response";
            url = evStr(rs, "url");
        } else if (std.mem.eql(u8, m, "Network.loadingFailed")) {
            kind = "failed";
            err_text = evStr(p.value.params, "errorText");
        } else continue;

        const uj = std.json.Stringify.valueAlloc(gpa, url, .{}) catch continue;
        defer gpa.free(uj);
        const ej = std.json.Stringify.valueAlloc(gpa, err_text, .{}) catch continue;
        defer gpa.free(ej);
        const seg = std.fmt.allocPrint(gpa, "{s}{{\"kind\":\"{s}\",\"method\":\"{s}\",\"url\":{s},\"status\":{d},\"error\":{s}}}", .{ if (n > 0) "," else "", kind, method_s, uj, stat, ej }) catch continue;
        defer gpa.free(seg);
        out.appendSlice(gpa, seg) catch continue;
        n += 1;
    }
    const tail = std.fmt.allocPrint(gpa, "],\"count\":{d},\"dropped\":{d}{s}}}", .{
        n,
        e.dropped,
        if (e.dropped > 0) ",\"note\":\"some events were dropped over the capture cap — this view is partial\"" else "",
    }) catch return error.OutOfMemory;
    defer gpa.free(tail);
    out.appendSlice(gpa, tail) catch return error.OutOfMemory;
    return out.toOwnedSlice(gpa) catch error.OutOfMemory;
}

/// Navigate the session for `key` to `url`; returns {"ok":true,"url":..,"title":..}.
pub fn navigate(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, url: []const u8) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    const final = try s.navigate(url);
    defer gpa.free(final);
    const title = s.evaluate("document.title") catch (gpa.dupe(u8, "") catch return error.OutOfMemory);
    defer gpa.free(title);
    log.info("browser: navigated {s} -> {s}", .{ key, final });
    // `transport` is reported on purpose: "extension" means this ran in the user's own signed-in browser and
    // they can see it happening, "launched" means a private throwaway profile that is logged out of
    // everything. That difference explains most of what a model would otherwise find baffling about a page.
    return std.json.Stringify.valueAlloc(gpa, .{
        .ok = true,
        .url = final,
        .title = title,
        .transport = if (s.isExt()) "extension" else "launched",
    }, .{}) catch error.OutOfMemory;
}

/// Snapshot the interactive elements (refs) plus a clipped page-text excerpt — and, deterministically (so a
/// disabled user's success never depends on the model *noticing*), weave in Pixel RAG and CAPTCHA handling:
///   - STRONG challenge (a real CAPTCHA/interstitial in the DOM) → return a handoff payload, NOT an actionable
///     read; the agent must relay it to the human. We never auto-solve or bypass verification.
///   - thin/canvas/SPA page (little DOM text) → also render screenshot tiles and splice a `visual` block with
///     tile paths + recovered leaf text, so the agent can still act when the DOM read is empty.
///   - SUSPECTED challenge (text-only signal) → non-blocking `challenge` marker, normal read otherwise.
/// `key` is the run_dir (tiles land under it, same convention as pixelrag). Everything is one coherent JSON.
pub fn read(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    const snap = try s.snapshot();

    // Decision signals emitted by SNAPSHOT_JS (kind/url copied out before the parse arena is freed).
    const Ch = struct { detected: bool = false, confidence: []const u8 = "none", kind: []const u8 = "unknown" };
    const Sig = struct { textLen: u32 = 0, visualScore: f64 = 0, url: []const u8 = "", challenge: Ch = .{} };
    var text_len: u32 = 0;
    var vscore: f64 = 0;
    var strong = false;
    var suspected = false;
    var kind_buf: [32]u8 = undefined;
    var kind: []const u8 = "unknown";
    var url_buf: [2048]u8 = undefined;
    var cur_url: []const u8 = "";
    if (std.json.parseFromSlice(Sig, gpa, snap, .{ .ignore_unknown_fields = true })) |sp| {
        defer sp.deinit();
        text_len = sp.value.textLen;
        vscore = sp.value.visualScore;
        strong = sp.value.challenge.detected and std.mem.eql(u8, sp.value.challenge.confidence, "strong");
        suspected = sp.value.challenge.detected and std.mem.eql(u8, sp.value.challenge.confidence, "suspected");
        const kl = @min(sp.value.challenge.kind.len, kind_buf.len);
        @memcpy(kind_buf[0..kl], sp.value.challenge.kind[0..kl]);
        kind = kind_buf[0..kl];
        const ul = @min(sp.value.url.len, url_buf.len);
        @memcpy(url_buf[0..ul], sp.value.url[0..ul]);
        cur_url = url_buf[0..ul];
    } else |_| {}

    // 1. STRONG challenge → hand off to the human (never solve). Replaces the normal read.
    if (strong) {
        gpa.free(snap);
        return challengePayload(gpa, io, env, s, key, cur_url, kind);
    }

    // 2. Visual fallback trigger (default ON — it's assistive tech; NL_BROWSER_PIXEL_FALLBACK=0 disables).
    if (!envFalse(env, "NL_BROWSER_PIXEL_FALLBACK")) {
        const text_min = envU32(env, "NL_READ_TEXT_MIN", 80); // genuinely-blank/unhydrated shells run well under this; a real small page (example.com ~127) does not
        const text_rich = envU32(env, "NL_READ_TEXT_RICH", 600);
        var reason: []const u8 = "";
        if (text_len < text_min) {
            reason = "sparse_text"; // blank / unhydrated SPA / challenge shell — little to no readable text
        } else if (vscore >= 0.60 and text_len < text_rich) {
            reason = "canvas_heavy"; // a canvas/map/whiteboard dominates the viewport with little DOM text
        }
        if (reason.len > 0) {
            if (tileCurrentVisual(gpa, io, s, key, cur_url, reason, 3)) |visual| {
                defer gpa.free(visual);
                return spliceField(gpa, snap, "visual", visual); // frees snap on success
            } else |_| {}
        }
    }

    // 3. SUSPECTED challenge → non-blocking marker; the normal read still returns.
    if (suspected) {
        const marker = std.fmt.allocPrint(gpa, "{{\"detected\":true,\"confidence\":\"suspected\",\"kind\":\"{s}\",\"note\":\"possible human-verification prompt on this page — mention it to the user; do not attempt to bypass it\"}}", .{kind}) catch return snap;
        defer gpa.free(marker);
        return spliceField(gpa, snap, "challenge", marker);
    }
    return snap;
}

fn envU32(env: *const std.process.Environ.Map, name: []const u8, dflt: u32) u32 {
    const v = env.get(name) orelse return dflt;
    return std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10) catch dflt;
}

fn envFalse(env: *const std.process.Environ.Map, name: []const u8) bool {
    const v = env.get(name) orelse return false;
    return std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false");
}

/// Splice `"field": value_json` into the snapshot object `snap` (a JSON object string) — strip the trailing
/// '}', append `,"field":<value>}`. Frees `snap`, returns the new gpa-owned string. If `snap` isn't a '}'-
/// terminated object it's returned unchanged (caller still owns/frees `value_json`).
fn spliceField(gpa: std.mem.Allocator, snap: []u8, field: []const u8, value_json: []const u8) []u8 {
    const trimmed = std.mem.trim(u8, snap, " \r\n\t");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '}') return snap;
    const out = std.fmt.allocPrint(gpa, "{s},\"{s}\":{s}}}", .{ trimmed[0 .. trimmed.len - 1], field, value_json }) catch return snap;
    gpa.free(snap);
    return out;
}

/// Tile the CURRENTLY loaded page (no navigate — unlike renderTiles) into up to `max` screenshot tiles written
/// under `{run_dir}/.pixelrag/_read/{hash}/`, returning a `visual` block: tile image PATHS (never inline base64
/// — that would blow the model's context) + per-tile leaf-text excerpts + a recovered_text roll-up. Errors if
/// nothing could be captured (caller then returns the plain snapshot).
fn tileCurrentVisual(gpa: std.mem.Allocator, io: std.Io, s: *Session, run_dir: []const u8, url: []const u8, reason: []const u8, max: u32) Error![]u8 {
    const h = std.hash.Wyhash.hash(0, url);
    const dir = std.fmt.allocPrint(gpa, "{s}/.pixelrag/_read/{x}", .{ run_dir, h }) catch return error.OutOfMemory;
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};

    const tile_h: i64 = 1600;
    var doc_w: f64 = 1280;
    var doc_h: i64 = tile_h;
    const metrics = s.pageMetrics() catch (gpa.dupe(u8, "{}") catch return error.OutOfMemory);
    defer gpa.free(metrics);
    if (std.json.parseFromSlice(struct { w: f64 = 1280, h: f64 = 0 }, gpa, metrics, .{ .ignore_unknown_fields = true })) |mp| {
        defer mp.deinit();
        if (mp.value.w > 0) doc_w = mp.value.w;
        if (mp.value.h > 0) doc_h = @intFromFloat(mp.value.h);
    } else |_| {}

    const n: u32 = @min(max, @as(u32, @intCast(@max(1, @divTrunc(doc_h + tile_h - 1, tile_h)))));
    var tiles_json: std.ArrayListUnmanaged(u8) = .empty;
    defer tiles_json.deinit(gpa);
    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(gpa);
    var i: u32 = 0;
    var written: u32 = 0;
    while (i < n) : (i += 1) {
        const y0: i64 = @as(i64, i) * tile_h;
        const h_px = @min(tile_h, doc_h - y0);
        if (h_px <= 0) break;
        const b64 = s.screenshotClipBase64(0, @floatFromInt(y0), doc_w, @floatFromInt(h_px)) catch continue;
        defer gpa.free(b64);
        const png = decodeB64(gpa, b64) catch continue;
        defer gpa.free(png);
        const full = std.fmt.allocPrint(gpa, "{s}/tile_{d}.png", .{ dir, i }) catch continue;
        defer gpa.free(full);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = png }) catch continue;
        const band = s.bandText(y0, y0 + tile_h) catch (gpa.dupe(u8, "") catch continue);
        defer gpa.free(band);
        const excerpt = if (band.len > 400) band[0..400] else band;
        const ej = std.json.Stringify.valueAlloc(gpa, excerpt, .{}) catch continue;
        defer gpa.free(ej);
        const item = std.fmt.allocPrint(gpa, "{s}{{\"index\":{d},\"image\":\".pixelrag/_read/{x}/tile_{d}.png\",\"excerpt\":{s}}}", .{ if (written > 0) "," else "", i, h, i, ej }) catch continue;
        defer gpa.free(item);
        tiles_json.appendSlice(gpa, item) catch {};
        if (recovered.items.len < 3000 and band.len > 0) {
            if (recovered.items.len > 0) recovered.append(gpa, ' ') catch {};
            recovered.appendSlice(gpa, band) catch {};
        }
        written += 1;
    }
    if (written == 0) return error.Protocol;
    const rec_slice = recovered.items[0..@min(recovered.items.len, 3000)];
    const rec = std.json.Stringify.valueAlloc(gpa, rec_slice, .{}) catch (gpa.dupe(u8, "\"\"") catch return error.OutOfMemory);
    defer gpa.free(rec);
    return std.fmt.allocPrint(gpa, "{{\"fallback\":true,\"reason\":\"{s}\",\"tiles\":[{s}],\"recovered_text\":{s},\"note\":\"Plain read returned little text, so the page was rendered to screenshot tiles. Excerpts are leaf-level text; the images are on disk for a vision pass. If you still can't act, describe the screenshot to the user or call pixel_ingest for a fuller searchable index.\"}}", .{ reason, tiles_json.items, rec }) catch error.OutOfMemory;
}

/// One full-page screenshot to disk for a challenge handoff. Returns the relative image path or null.
fn snapOneShot(gpa: std.mem.Allocator, io: std.Io, s: *Session, run_dir: []const u8, url: []const u8) ?[]u8 {
    const h = std.hash.Wyhash.hash(0, url);
    const dir = std.fmt.allocPrint(gpa, "{s}/.pixelrag/_read/{x}", .{ run_dir, h }) catch return null;
    defer gpa.free(dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    const b64 = s.screenshotBase64() catch return null;
    defer gpa.free(b64);
    const png = decodeB64(gpa, b64) catch return null;
    defer gpa.free(png);
    const full = std.fmt.allocPrint(gpa, "{s}/challenge.png", .{dir}) catch return null;
    defer gpa.free(full);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = png }) catch return null;
    return std.fmt.allocPrint(gpa, ".pixelrag/_read/{x}/challenge.png", .{h}) catch null;
}

/// Build the CAPTCHA/human-verification handoff payload: a screenshot for the human, the URL, and mode-correct
/// instructions. This is the accessibility-correct response — pause and ask the human — NOT an auto-solve.
fn challengePayload(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, s: *Session, run_dir: []const u8, url: []const u8, kind: []const u8) []u8 {
    const headful = wantHeadful(gpa, io, env);
    const title = s.evaluate("document.title") catch (gpa.dupe(u8, "") catch return dupe(gpa, "{\"challenge\":{\"detected\":true,\"confidence\":\"strong\"}}"));
    defer gpa.free(title);
    const shot = snapOneShot(gpa, io, s, run_dir, url);
    defer if (shot) |sp| gpa.free(sp);
    const url_j = std.json.Stringify.valueAlloc(gpa, url, .{}) catch (gpa.dupe(u8, "\"\"") catch return dupe(gpa, "{\"ok\":false}"));
    defer gpa.free(url_j);
    const title_j = std.json.Stringify.valueAlloc(gpa, title, .{}) catch (gpa.dupe(u8, "\"\"") catch return dupe(gpa, "{\"ok\":false}"));
    defer gpa.free(title_j);
    // Own-vs-static tracking so the defer never frees a non-heap literal (the else/OOM path leaves it "null").
    var shot_field: []const u8 = "null";
    var shot_owned = false;
    if (shot) |sp| {
        if (std.fmt.allocPrint(gpa, "\"{s}\"", .{sp})) |f| {
            shot_field = f;
            shot_owned = true;
        } else |_| {}
    }
    defer if (shot_owned) gpa.free(shot_field);
    const instr = if (headful)
        "This page is asking to verify you're human. The browser window is open on your screen — please complete the check yourself (checkbox or puzzle), then tell me to continue. I can't and won't solve it for you."
    else
        "This page needs a human-verification step and the browser is running hidden. Turn the browser window ON in Settings so you can solve it in place, or open this URL in your own browser, complete the check, and tell me to retry.";
    return std.fmt.allocPrint(gpa, "{{\"url\":{s},\"title\":{s},\"challenge\":{{\"detected\":true,\"kind\":\"{s}\",\"confidence\":\"strong\",\"action_required\":\"human\",\"headful\":{},\"screenshot\":{s},\"instructions\":\"{s}\",\"note\":\"Automation paused at a human-verification challenge. I will not bypass or auto-solve it — waiting for you.\"}}}}", .{ url_j, title_j, kind, headful, shot_field, instr }) catch dupe(gpa, "{\"challenge\":{\"detected\":true,\"confidence\":\"strong\"}}");
}

/// Visible page text (document.body.innerText), clipped browser-side to `max` chars.
pub fn pageText(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, max: usize) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    const expr = std.fmt.allocPrint(gpa, "(document.body?document.body.innerText:'').slice(0,{d})", .{max}) catch return error.OutOfMemory;
    defer gpa.free(expr);
    return s.evaluate(expr);
}

pub fn click(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, ref: u32) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    log.info("browser: click ref {d} on {s}", .{ ref, key });
    return s.clickRef(ref);
}

pub fn typeText(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, ref: u32, text: []const u8, submit: bool) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    log.info("browser: type into ref {d} on {s} (submit={})", .{ ref, key, submit });
    return s.typeRef(ref, text, submit);
}

/// Coordinate-native input — no element lookup, nothing written into the page. See session.zig's DOM-FREE
/// block for why these exist alongside the ref verbs.
pub fn clickAt(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, x: i64, y: i64) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    log.info("browser: click at ({d},{d}) on {s}", .{ x, y, key });
    return s.clickAt(x, y);
}

pub fn typeFocused(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, text: []const u8, clear: bool, submit: bool) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    return s.typeFocused(text, clear, submit);
}

pub fn pressKey(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, name: []const u8) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    try s.key(name);
    return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .key = name }, .{}) catch error.OutOfMemory;
}

pub fn scrollAt(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, x: i64, y: i64, dy: i64) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    return s.scrollAt(x, y, dy);
}

pub fn eval(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, js: []const u8) Error![]u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    return s.evaluate(js);
}

pub const Tile = struct {
    index: u32,
    y: i64,
    png: []u8, // decoded PNG bytes, gpa-owned
    text: []u8, // gpa-owned band text
};

/// The tiling body shared by renderTiles (fresh navigation) and renderTilesCurrent (the page AS IS):
/// document metrics → bounded fixed-height clip screenshots, each paired with its band text. Caller holds
/// g_mu and frees the tiles (freeTiles).
fn tileNow(gpa: std.mem.Allocator, s: *Session, tile_h: i64, max_tiles: u32) Error![]Tile {
    // Full document height → number of tiles (bounded).
    var doc_w: f64 = 1280;
    var doc_h: i64 = tile_h;
    const metrics = s.pageMetrics() catch (gpa.dupe(u8, "{}") catch return error.OutOfMemory);
    defer gpa.free(metrics);
    if (std.json.parseFromSlice(struct { w: f64 = 1280, h: f64 = 0 }, gpa, metrics, .{ .ignore_unknown_fields = true })) |mp| {
        defer mp.deinit();
        if (mp.value.w > 0) doc_w = mp.value.w;
        if (mp.value.h > 0) doc_h = @intFromFloat(mp.value.h);
    } else |_| {}

    const n_tiles: u32 = @min(max_tiles, @as(u32, @intCast(@max(1, @divTrunc(doc_h + tile_h - 1, tile_h)))));
    var tiles: std.ArrayListUnmanaged(Tile) = .empty;
    errdefer {
        for (tiles.items) |t| {
            gpa.free(t.png);
            gpa.free(t.text);
        }
        tiles.deinit(gpa);
    }

    var i: u32 = 0;
    while (i < n_tiles) : (i += 1) {
        const y0: i64 = @as(i64, i) * tile_h;
        const h = @min(tile_h, doc_h - y0);
        if (h <= 0) break;
        const b64 = s.screenshotClipBase64(0, @floatFromInt(y0), doc_w, @floatFromInt(h)) catch continue;
        defer gpa.free(b64);
        const png = decodeB64(gpa, b64) catch continue;
        const text = s.bandText(y0, y0 + tile_h) catch (gpa.dupe(u8, "") catch {
            gpa.free(png);
            continue;
        });
        tiles.append(gpa, .{ .index = i, .y = y0, .png = png, .text = text }) catch {
            gpa.free(png);
            gpa.free(text);
            break;
        };
    }
    return tiles.toOwnedSlice(gpa) catch error.OutOfMemory;
}

/// Render `url` and tile the full page into fixed-height screenshot tiles, each paired with the visible text
/// in its band (Pixel RAG's render+ingest stage). Locks the session for the whole render so it is atomic vs
/// concurrent browser tool calls. Caller frees each tile's png+text and the returned slice (freeTiles).
pub fn renderTiles(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, url: []const u8, tile_h: i64, max_tiles: u32) Error![]Tile {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);

    const final = try s.navigate(url);
    gpa.free(final);

    const tiles = try tileNow(gpa, s, tile_h, max_tiles);
    log.info("browser: rendered {d} tile(s) for {s}", .{ tiles.len, url });
    return tiles;
}

pub const Snapshot = struct { url: []u8, tiles: []Tile };

/// Tile the session's CURRENT page — NO navigation, so the live state the preceding browser_* interactions
/// produced (SPA state, logged-in session, an open modal, half-filled form) is captured exactly as it stands.
/// This is the seam that makes the browser and Pixel RAG one instrument: interact, then capture what actually
/// rendered. Returns the page's current URL alongside the tiles (caller frees via freeSnapshot).
pub fn renderTilesCurrent(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, tile_h: i64, max_tiles: u32) Error!Snapshot {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const s = try ensure(gpa, io, env, key);
    const href = s.evaluate("location.href") catch (gpa.dupe(u8, "") catch return error.OutOfMemory);
    errdefer gpa.free(href);
    const tiles = try tileNow(gpa, s, tile_h, max_tiles);
    log.info("browser: snapshot {d} tile(s) of the current page {s}", .{ tiles.len, href });
    return .{ .url = href, .tiles = tiles };
}

pub fn freeSnapshot(gpa: std.mem.Allocator, snap: Snapshot) void {
    gpa.free(snap.url);
    freeTiles(gpa, snap.tiles);
}

pub fn freeTiles(gpa: std.mem.Allocator, tiles: []Tile) void {
    for (tiles) |t| {
        gpa.free(t.png);
        gpa.free(t.text);
    }
    gpa.free(tiles);
}

fn decodeB64(gpa: std.mem.Allocator, b64: []const u8) ![]u8 {
    const Dec = std.base64.standard.Decoder;
    const n = try Dec.calcSizeForSlice(b64);
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    try Dec.decode(out, b64);
    return out;
}

/// Close the session for `key` (if any). Returns {"ok":true,"closed":<bool>}.
pub fn closeKey(gpa: std.mem.Allocator, io: std.Io, key: []const u8) []u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (&g_slots) |*slot| {
        if (slot.*) |*e| if (std.mem.eql(u8, e.key, key)) {
            e.sess.close();
            e.events.deinit(gpa);
            gpa.free(e.key);
            slot.* = null;
            log.info("browser: closed session for {s}", .{key});
            return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"closed\":true}}", .{}) catch @constCast("");
        };
    }
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"closed\":false}}", .{}) catch @constCast("");
}

/// Teardown hook: close every live session. A long-lived host calls this on shutdown so no headless browser
/// is orphaned. gpa is the same allocator the sessions were opened with.
pub fn closeAll(gpa: std.mem.Allocator, io: std.Io) void {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (&g_slots) |*slot| {
        if (slot.*) |*e| {
            e.sess.close();
            e.events.deinit(gpa);
            gpa.free(e.key);
            slot.* = null;
        }
    }
}

// -------------------------------------------------- unified action dispatch (broker + in-process + daemon)

var g_last_activity: i64 = 0;

fn touch(io: std.Io) void {
    @atomicStore(i64, &g_last_activity, std.Io.Timestamp.now(io, .real).toSeconds(), .monotonic);
}

/// Seconds (real clock) of the last dispatch() call — the daemon uses this + liveCount for its idle-exit.
pub fn lastActivity() i64 {
    return @atomicLoad(i64, &g_last_activity, .monotonic);
}

pub fn liveCount(io: std.Io) usize {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    var n: usize = 0;
    for (g_slots) |s| {
        if (s != null) n += 1;
    }
    return n;
}

/// How long an untouched session (and its resident headless browser) may live before it is closed. Sessions
/// used to survive until the whole process exited — in the long-lived local-host daemon that meant every
/// abandoned session pinned an Edge forever AND held liveCount above 0, so the daemon's own idle-exit could
/// never fire. Generous: a mid-conversation pause must not lose the page, and a reopen only costs ~1 s.
pub const SESSION_IDLE_S: i64 = 600;

/// Close every session idle longer than `max_idle_s` and return the live count that remains. Called from the
/// daemon's watch loop (and at dispatch time), so abandoned sessions age out instead of piling up browsers.
pub fn sweepIdle(gpa: std.mem.Allocator, io: std.Io, max_idle_s: i64) usize {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    var live: usize = 0;
    for (&g_slots) |*slot| {
        if (slot.*) |*e| {
            if (now - e.last_used > max_idle_s) {
                log.info("browser: closing idle session for {s} ({d}s unused)", .{ e.key, now - e.last_used });
                e.sess.close();
                e.events.deinit(gpa);
                gpa.free(e.key);
                slot.* = null;
            } else live += 1;
        }
    }
    return live;
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    // OOM fallback is ZERO-LENGTH on purpose: callers free this result unconditionally, and a static non-empty
    // literal handed to gpa.free is an invalid free / UB. free() of an empty slice is a no-op (Allocator.free).
    return gpa.dupe(u8, s) catch @constCast("");
}

fn errJson(gpa: std.mem.Allocator, msg: []const u8) []u8 {
    return std.fmt.allocPrint(gpa, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch dupe(gpa, "{\"ok\":false}");
}

/// The ONE action dispatcher every surface funnels through: the in-process tool path (browserDispatch when
/// NOT roam), the loopback broker (make_tool bodies), and the local-host daemon (the client-delegated path).
/// `action` is the browser verb (navigate/read/pagetext/click/type/eval/close/ping); `params_json` is a JSON
/// object with its args. Always returns a gpa-owned JSON result string (errors become {"ok":false,"error":..}).
pub fn dispatch(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, action: []const u8, params_json: []const u8) []u8 {
    touch(io);
    if (std.mem.eql(u8, action, "ping")) return dupe(gpa, "{\"ok\":true,\"pong\":true}");
    _ = sweepIdle(gpa, io, SESSION_IDLE_S); // age out abandoned sessions before (possibly) opening a new one

    const pv = std.json.parseFromSlice(std.json.Value, gpa, if (params_json.len == 0) "{}" else params_json, .{}) catch
        return errJson(gpa, "bad params json");
    defer pv.deinit();
    const p = pv.value;

    if (std.mem.eql(u8, action, "navigate")) {
        const url = pStr(p, "url") orelse return errJson(gpa, "need url");
        return navigate(gpa, io, env, key, url) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "read")) {
        return read(gpa, io, env, key) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "pagetext")) {
        const max: usize = if (pInt(p, "max")) |m| @intCast(@max(0, m)) else 4000;
        return pageText(gpa, io, env, key, max) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "click")) {
        const ref = pInt(p, "ref") orelse return errJson(gpa, "need ref");
        return click(gpa, io, env, key, @intCast(@max(0, ref))) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "type")) {
        const ref = pInt(p, "ref") orelse return errJson(gpa, "need ref");
        return typeText(gpa, io, env, key, @intCast(@max(0, ref)), pStr(p, "text") orelse "", pBool(p, "submit")) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "eval")) {
        const js = pStr(p, "js") orelse return errJson(gpa, "need js");
        return eval(gpa, io, env, key, js) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "click_at")) {
        const x = pInt(p, "x") orelse return errJson(gpa, "need x");
        const y = pInt(p, "y") orelse return errJson(gpa, "need y");
        return clickAt(gpa, io, env, key, x, y) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "type_text")) {
        const clear = if (pHas(p, "clear")) pBool(p, "clear") else true;
        return typeFocused(gpa, io, env, key, pStr(p, "text") orelse "", clear, pBool(p, "submit")) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "key")) {
        const name = pStr(p, "key") orelse return errJson(gpa, "need key");
        return pressKey(gpa, io, env, key, name) catch errJson(gpa, "unknown key — use Enter, Tab, Escape, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp or PageDown");
    } else if (std.mem.eql(u8, action, "scroll")) {
        const dy: i64 = pInt(p, "dy") orelse 600;
        return scrollAt(gpa, io, env, key, pInt(p, "x") orelse 400, pInt(p, "y") orelse 300, dy) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "console")) {
        const max: usize = if (pInt(p, "max")) |m| @intCast(@max(1, @min(500, m))) else 100;
        return console(gpa, io, env, key, max) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "network")) {
        const max: usize = if (pInt(p, "max")) |m| @intCast(@max(1, @min(500, m))) else 100;
        return network(gpa, io, env, key, max, pBool(p, "failures_only")) catch |e| errJson(gpa, launch.errText(e));
    } else if (std.mem.eql(u8, action, "close")) {
        return closeKey(gpa, io, key);
    } else if (std.mem.eql(u8, action, "rendertiles")) {
        const url = pStr(p, "url") orelse return errJson(gpa, "need url");
        const th: i64 = pInt(p, "tile_h") orelse 1600;
        const mt: u32 = if (pInt(p, "max_tiles")) |m| @intCast(@max(1, @min(64, m))) else 12;
        return renderTilesJson(gpa, io, env, key, url, th, mt);
    } else if (std.mem.eql(u8, action, "rendertilescurrent")) {
        const th: i64 = pInt(p, "tile_h") orelse 1600;
        const mt: u32 = if (pInt(p, "max_tiles")) |m| @intCast(@max(1, @min(64, m))) else 12;
        return renderTilesCurrentJson(gpa, io, env, key, th, mt);
    }
    return errJson(gpa, "unknown action");
}

/// Pixel RAG's render stage as a dispatch action: render `url`, tile it, and return each tile as base64 PNG +
/// band text so a CLIENT-side pixel_ingest (running in a short-lived exec-tool subprocess) can get tiles from
/// the persistent daemon browser and do the indexing itself. gpa-owned JSON.
fn renderTilesJson(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, url: []const u8, tile_h: i64, max_tiles: u32) []u8 {
    const tiles = renderTiles(gpa, io, env, key, url, tile_h, max_tiles) catch |e| return errJson(gpa, launch.errText(e));
    defer freeTiles(gpa, tiles);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":true,\"tiles\":[") catch return errJson(gpa, "oom");
    const Enc = std.base64.standard.Encoder;
    for (tiles, 0..) |t, i| {
        if (i > 0) out.append(gpa, ',') catch break;
        const b64 = gpa.alloc(u8, Enc.calcSize(t.png.len)) catch break;
        defer gpa.free(b64);
        _ = Enc.encode(b64, t.png);
        const text_lit = std.json.Stringify.valueAlloc(gpa, t.text, .{}) catch (gpa.dupe(u8, "\"\"") catch break);
        defer gpa.free(text_lit);
        const seg = std.fmt.allocPrint(gpa, "{{\"index\":{d},\"y\":{d},\"png\":\"{s}\",\"text\":{s}}}", .{ t.index, t.y, b64, text_lit }) catch break;
        defer gpa.free(seg);
        out.appendSlice(gpa, seg) catch break;
    }
    out.appendSlice(gpa, "]}") catch return errJson(gpa, "oom");
    return out.toOwnedSlice(gpa) catch errJson(gpa, "oom");
}

/// The CURRENT-page render stage as a dispatch action (pixel_capture's daemon path): tile the page AS IS —
/// no navigation — and return the live URL + each tile as base64 PNG + band text, so a client-side capture
/// (short-lived exec-tool subprocess) snapshots the persistent daemon browser's real state. gpa-owned JSON.
fn renderTilesCurrentJson(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, key: []const u8, tile_h: i64, max_tiles: u32) []u8 {
    const snap = renderTilesCurrent(gpa, io, env, key, tile_h, max_tiles) catch |e| return errJson(gpa, launch.errText(e));
    defer freeSnapshot(gpa, snap);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const url_lit = std.json.Stringify.valueAlloc(gpa, snap.url, .{}) catch (gpa.dupe(u8, "\"\"") catch return errJson(gpa, "oom"));
    defer gpa.free(url_lit);
    out.appendSlice(gpa, "{\"ok\":true,\"url\":") catch return errJson(gpa, "oom");
    out.appendSlice(gpa, url_lit) catch return errJson(gpa, "oom");
    out.appendSlice(gpa, ",\"tiles\":[") catch return errJson(gpa, "oom");
    const Enc = std.base64.standard.Encoder;
    for (snap.tiles, 0..) |t, i| {
        if (i > 0) out.append(gpa, ',') catch break;
        const b64 = gpa.alloc(u8, Enc.calcSize(t.png.len)) catch break;
        defer gpa.free(b64);
        _ = Enc.encode(b64, t.png);
        const text_lit = std.json.Stringify.valueAlloc(gpa, t.text, .{}) catch (gpa.dupe(u8, "\"\"") catch break);
        defer gpa.free(text_lit);
        const seg = std.fmt.allocPrint(gpa, "{{\"index\":{d},\"y\":{d},\"png\":\"{s}\",\"text\":{s}}}", .{ t.index, t.y, b64, text_lit }) catch break;
        defer gpa.free(seg);
        out.appendSlice(gpa, seg) catch break;
    }
    out.appendSlice(gpa, "]}") catch return errJson(gpa, "oom");
    return out.toOwnedSlice(gpa) catch errJson(gpa, "oom");
}

fn pStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        },
        else => null,
    };
}

fn pInt(v: std.json.Value, key: []const u8) ?i64 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .integer => |i| i,
            else => null,
        },
        else => null,
    };
}

fn pBool(v: std.json.Value, key: []const u8) bool {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return false) {
            .bool => |b| b,
            else => false,
        },
        else => false,
    };
}

/// Whether the caller SUPPLIED a key at all — distinct from pBool's "false or missing". Needed where the
/// default is true (`clear`), so an explicit `clear:false` is not indistinguishable from silence.
fn pHas(v: std.json.Value, key: []const u8) bool {
    return switch (v) {
        .object => |o| o.get(key) != null,
        else => false,
    };
}

test "pStr/pInt/pBool read only their own JSON type; missing/mistyped keys degrade to null/false" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"url\":\"x\",\"ref\":7,\"submit\":true,\"n\":\"5\"}", .{});
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqualStrings("x", pStr(v, "url").?);
    try std.testing.expectEqual(@as(i64, 7), pInt(v, "ref").?);
    try std.testing.expect(pBool(v, "submit"));
    // absent key
    try std.testing.expect(pStr(v, "missing") == null);
    try std.testing.expect(pInt(v, "missing") == null);
    try std.testing.expect(!pBool(v, "missing"));
    // present but wrong type: "n" is a string, not an int — must not coerce
    try std.testing.expect(pInt(v, "n") == null);
    try std.testing.expect(pStr(v, "ref") == null);
    // a non-object root never panics
    const scalar = try std.json.parseFromSlice(std.json.Value, gpa, "42", .{});
    defer scalar.deinit();
    try std.testing.expect(pInt(scalar.value, "ref") == null);
}

test "spliceField appends a field, frees the input, and leaves a non-object untouched" {
    const gpa = std.testing.allocator;
    const snap = try gpa.dupe(u8, "{\"a\":1}");
    const out = spliceField(gpa, snap, "b", "2"); // frees snap, returns a fresh alloc
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}", out);
    // a value that isn't a '}'-terminated object is returned as-is (same backing slice, caller still frees once)
    const bad = try gpa.dupe(u8, "not json");
    const out2 = spliceField(gpa, bad, "b", "2");
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("not json", out2);
}

test "dupe OOM fallback is a zero-length slice that is safe to free (guards the browser result contract)" {
    // A real allocation succeeds and round-trips; the OOM path is exercised by the failing_allocator below.
    const ok = dupe(std.testing.allocator, "{\"ok\":true}");
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("{\"ok\":true}", ok);
    // Under OOM, dupe returns "" — freeing it (as every dispatch caller does) must be a no-op, not an invalid free.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const empty = dupe(fa.allocator(), "{\"ok\":false}");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    fa.allocator().free(empty); // would trip the allocator's invalid-free detection if it weren't zero-length
}
