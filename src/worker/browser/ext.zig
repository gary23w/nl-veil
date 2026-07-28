//! The browser-EXTENSION transport: a CDP relay through a Chrome/Edge extension the user already has open.
//!
//! WHY THIS EXISTS. The original driver (launch.zig + cdp.zig) spawns its OWN browser on a throwaway temp
//! profile. That profile is logged out of everything, which is why launch.zig carries 300 lines of Edge-sync
//! suppression, `seedProfile`, first-run flags and `navigator.webdriver` scrubbing: all of it is the cost of
//! not being the user's real browser. Attaching to the browser they are ALREADY signed into removes the whole
//! category — their cookies, their sessions, their extensions, and a human sitting right there to answer a
//! human-verification prompt.
//!
//! WHAT THE EXTENSION IS. Deliberately as close to nothing as possible: it relays {method, params} to
//! `chrome.debugger.sendCommand` and posts the reply back. It holds NO automation logic — no snapshot script,
//! no ref model, no click heuristics. Those stay in session.zig and are shipped to the page inside
//! `Runtime.evaluate` payloads, so changing SNAPSHOT_JS never means reinstalling an extension. (MV3 forbids
//! `executeScript({code})`, but the debugger protocol evaluates freely, which is exactly why the relay is a
//! debugger relay and not a content script.) It also means input is TRUSTED: `Input.dispatchMouseEvent` and
//! `Input.insertText` through chrome.debugger are the same real events session.zig already relies on, not the
//! `isTrusted:false` synthetics a content script is limited to.
//!
//! TRANSPORT. The extension polls US; we never dial it. An MV3 service worker cannot listen for connections,
//! and an in-flight `fetch` is what keeps it alive. So: GET /poll long-polls for the next command batch, POST
//! /result returns each answer. No websocket — the vendored websocket.zig client does not build on this
//! Windows Zig (its read path wants std.posix.poll), and a long poll needs nothing that isn't already here.
//!
//! CONCURRENCY. Commands are parked in a fixed slot table; `call` blocks the caller's thread on util.sleepMs
//! until the extension delivers or the deadline passes. Callers run on httpz request workers, worker threads
//! and the exec-tool thread — none of them Io-managed tasks — so this must never touch io.sleep (see util.zig).
//!
//! ONE EXTENSION, MANY PROCESSES. The extension pairs with the SERVER, but the browser tools do not all run
//! there: the desk delegates each one to a fresh `veil exec-tool` subprocess, which forwards to the per-machine
//! `local-host` daemon (host.zig) so a session survives between calls. Those are different processes, and this
//! module's connection state is process-global — so without a bridge the daemon would see no extension and
//! quietly launch its own browser, which is exactly the bug this half of the file exists to prevent.
//!
//! The bridge is the same idiom host.zig already uses for the daemon: at boot the server writes {port, token}
//! to a discovery file on LOCAL temp (never OneDrive). Any other veil process reads it and proxies `available`
//! and `call` back to the server over loopback. The server itself never proxies — it IS the host.

const std = @import("std");
const util = @import("util.zig");
const httpc = @import("../httpc.zig");

const log = std.log.scoped(.browser);

pub const Error = error{ NotConnected, Timeout, ExtError, OutOfMemory };

/// How long after its last poll/heartbeat a connected extension is still considered live. The extension
/// re-polls immediately after each 25s long poll returns, so a gap this size means it is genuinely gone
/// (browser closed, worker evicted, machine asleep) rather than merely between polls.
pub const LIVE_TTL_MS: i64 = 40_000;

/// Long-poll ceiling. Under Chrome's MV3 rules a pending fetch holds the service worker awake, and 25s stays
/// clear of the 30s idle-eviction line with room for the round trip.
pub const POLL_MAX_MS: i64 = 25_000;

const MAX_SLOTS = 32;
const TOKEN_LEN = 32;

const Slot = struct {
    id: u64 = 0,
    state: enum { free, queued, sent, done } = .free,
    method: []u8 = &.{},
    params: []u8 = &.{},
    session_id: []u8 = &.{}, // "" = browser-level (no tab)
    reply: []u8 = &.{}, // gpa-owned; the CDP `result` object on success, a message on failure
    failed: bool = false,
    gpa: std.mem.Allocator = undefined,

    fn clear(self: *Slot) void {
        if (self.state == .free) return;
        const gpa = self.gpa;
        gpa.free(self.method);
        gpa.free(self.params);
        gpa.free(self.session_id);
        if (self.reply.len > 0) gpa.free(self.reply);
        self.* = .{};
    }
};

var g_mu: std.Io.Mutex = .init;
var g_slots: [MAX_SLOTS]Slot = @splat(.{});
var g_next_id: u64 = 1;

var g_token: [TOKEN_LEN]u8 = undefined;
var g_token_set: bool = false;
var g_last_seen_ms: i64 = 0;
var g_paused: bool = false;
var g_browser_buf: [24]u8 = undefined;
var g_browser_len: usize = 0;
var g_ver_buf: [24]u8 = undefined;
var g_ver_len: usize = 0;

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

// ------------------------------------------------------------------------------------------ pairing + status

fn fillHex(out: []u8, seed: *u64) void {
    const hexd = "0123456789abcdef";
    var i: usize = 0;
    while (i < out.len) {
        seed.* +%= 0x9E3779B97F4A7C15;
        var z = seed.*;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        var b: usize = 0;
        while (b < 16 and i < out.len) : (b += 1) {
            out[i] = hexd[(z >> @intCast(b * 4)) & 0xF];
            i += 1;
        }
    }
}

/// Mint (once) and return this process's pairing token. NOT a cryptographic secret and not treated as one:
/// pairing is reachable only from loopback (see ext_api.pair), so the token's job is to stop a page in the
/// user's own browser from guessing its way onto the relay, not to survive an attacker who is already on the
/// box. Same construction the loopback broker uses — std.crypto.random is absent in this Zig.
pub fn ensureToken(io: std.Io) []const u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    if (!g_token_set) {
        var seed: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        seed ^= @intFromPtr(&g_slots[0]);
        fillHex(&g_token, &seed);
        g_token_set = true;
    }
    return &g_token;
}

fn allHex(s: []const u8) bool {
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// Persist the pairing token across restarts. Called ONCE at server boot with the data dir, before any
/// pair/poll route can serve.
///
/// The token is per-MACHINE, but ensureToken mints it per-PROCESS. A server restart — which happens on every
/// rebuild — therefore mints a fresh token and orphans an extension still holding the old one: it polls,
/// tokenOk fails with 401 "pair first", and the user sees "won't connect" with nothing to act on. pair()'s
/// own doc already promises "re-pairing after a restart never orphans a live extension"; that was only true
/// WITHIN one process. Loading a saved token (or minting and saving one) makes it true across restarts too,
/// so the extension the user paired once stays paired.
///
/// NOT a secret — see ensureToken: loopback-only, and an attacker who can read this file is already on the
/// box, which the token was never meant to defend against. Same class as host.zig's {port,token} file.
pub fn loadOrMintToken(io: std.Io, gpa: std.mem.Allocator, data_dir: []const u8) void {
    const path = std.fmt.allocPrint(gpa, "{s}/.veil-ext-token", .{data_dir}) catch return;
    defer gpa.free(path);

    var tok: [TOKEN_LEN]u8 = undefined;
    var have = false;
    // Reuse a well-formed token from a previous run; a missing / corrupt / wrong-length file falls through
    // to minting a fresh one. readFileAlloc errors past its limit rather than truncating, so 256 > TOKEN_LEN
    // is safe and a bloated file reads as an error → re-mint, never a silent partial token.
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256))) |buf| {
        defer gpa.free(buf);
        const t = std.mem.trim(u8, buf, " \r\n\t");
        if (t.len == TOKEN_LEN and allHex(t)) {
            @memcpy(&tok, t[0..TOKEN_LEN]);
            have = true;
        }
    } else |_| {}

    if (!have) {
        var seed: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        seed ^= @intFromPtr(&g_slots[0]);
        fillHex(&tok, &seed);
        // Best-effort: a read-only data dir just degrades to today's per-process behaviour, no worse.
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &tok }) catch {};
    }

    // First writer wins: ensureToken may have already minted one if a pair arrived during boot. The `if`
    // guard means this can never clobber a token an extension might already be authenticating against.
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    if (!g_token_set) {
        @memcpy(&g_token, &tok);
        g_token_set = true;
    }
}

/// Constant-time-ish token check. Length-first so a short token can never index past the buffer.
pub fn tokenOk(io: std.Io, tok: []const u8) bool {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    if (!g_token_set or tok.len != TOKEN_LEN) return false;
    var diff: u8 = 0;
    for (tok, g_token) |a, b| diff |= a ^ b;
    return diff == 0;
}

/// Record that the extension is alive, and which browser it is. Called from every poll and heartbeat.
pub fn heartbeat(io: std.Io, browser: []const u8, version: []const u8, paused: bool) void {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    g_last_seen_ms = nowMs(io);
    g_paused = paused;
    if (browser.len > 0) {
        g_browser_len = @min(browser.len, g_browser_buf.len);
        @memcpy(g_browser_buf[0..g_browser_len], browser[0..g_browser_len]);
    }
    if (version.len > 0) {
        g_ver_len = @min(version.len, g_ver_buf.len);
        @memcpy(g_ver_buf[0..g_ver_len], version[0..g_ver_len]);
    }
}

/// Drop the connection state — the extension said goodbye, or was unpaired. Queued work is failed rather than
/// left to time out one slow deadline at a time.
pub fn disconnect(io: std.Io) void {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    g_last_seen_ms = 0;
    for (&g_slots) |*s| {
        if (s.state == .queued or s.state == .sent) {
            s.reply = s.gpa.dupe(u8, "browser extension disconnected") catch &.{};
            s.failed = true;
            s.state = .done;
        }
    }
}

pub const Status = struct {
    connected: bool,
    paused: bool,
    browser: []const u8,
    version: []const u8,
    idle_ms: i64,
};

pub fn status(io: std.Io) Status {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const idle = if (g_last_seen_ms == 0) std.math.maxInt(i64) else nowMs(io) - g_last_seen_ms;
    return .{
        .connected = g_last_seen_ms != 0 and idle < LIVE_TTL_MS,
        .paused = g_paused,
        .browser = g_browser_buf[0..g_browser_len],
        .version = g_ver_buf[0..g_ver_len],
        .idle_ms = if (idle == std.math.maxInt(i64)) -1 else idle,
    };
}

/// Local-only view: is an extension polling THIS process? `available` is what callers should ask.
fn localAvailable(io: std.Io) bool {
    const st = status(io);
    return st.connected and !st.paused;
}

/// The routing predicate: is there a live, un-paused extension to drive — here or on the server this machine
/// is running? This is what makes the extension path OPTIONAL: manager.openSession asks, and falls back to
/// launching its own browser when the answer is no. A PAUSED extension answers false, so the popup's pause
/// toggle degrades to the old behaviour rather than breaking browsing.
pub fn available(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    if (g_is_host) return localAvailable(io);
    return remoteLive(gpa, io, env);
}

// ------------------------------------------------------------------------------------------ cross-process

var g_is_host: bool = false; // this process owns the relay (the server) and must never proxy to itself
var g_remote_checked_ms: i64 = 0;
var g_remote_live: bool = false;

/// Where the server advertises its relay. LOCAL temp only — OneDrive locks and delays it, the same trap
/// host.zig's discovery file documents.
fn discoveryPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]u8 {
    const base = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR") orelse ".";
    return std.fmt.allocPrint(gpa, "{s}/nl-veil-browser-ext.json", .{base}) catch null;
}

/// Called once by the server at boot, when it knows its own port: mint the token and publish {port, token} so
/// every other veil process on this machine can reach the extension through it.
pub fn becomeHost(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, port: u16) void {
    const token = ensureToken(io);
    g_is_host = true;
    const path = discoveryPath(gpa, env) orelse return;
    defer gpa.free(path);
    const body = std.fmt.allocPrint(gpa, "{{\"port\":{d},\"token\":\"{s}\"}}", .{ port, token }) catch return;
    defer gpa.free(body);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch |e| {
        log.warn("browser ext: could not publish the relay ({s}) — only this process will see the extension", .{@errorName(e)});
        return;
    };
}

const Disc = struct { port: u16 = 0, token: []const u8 = "" };

fn readHost(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?struct { port: u16, token: [TOKEN_LEN]u8 } {
    const path = discoveryPath(gpa, env) orelse return null;
    defer gpa.free(path);
    const txt = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch return null;
    defer gpa.free(txt);
    const p = std.json.parseFromSlice(Disc, gpa, txt, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    // A half-written or stale file must read as ABSENT, never as a half-valid port/token: the caller would
    // otherwise send browser traffic somewhere arbitrary. Same discipline as host.zig's readInfo.
    if (p.value.port == 0 or p.value.token.len != TOKEN_LEN) return null;
    var tok: [TOKEN_LEN]u8 = undefined;
    @memcpy(&tok, p.value.token[0..TOKEN_LEN]);
    return .{ .port = p.value.port, .token = tok };
}

/// Ask the server whether its extension is live. Cached briefly: this is consulted on every session ensure,
/// and a loopback round trip per browser op is pure overhead when the answer changes on a human timescale.
fn remoteLive(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    const now = nowMs(io);
    if (now - g_remote_checked_ms < 2000) return g_remote_live;
    g_remote_checked_ms = now;
    g_remote_live = false;

    const h = readHost(gpa, io, env) orelse return false;
    const body = std.fmt.allocPrint(gpa, "{{\"token\":\"{s}\"}}", .{h.token}) catch return false;
    defer gpa.free(body);
    switch (httpc.request(io, gpa, .{ .method = "POST", .port = h.port, .path = "/api/v1/browser/ext/live", .body = body, .timeout_s = 3, .cap = 4 << 10 })) {
        .ok => |resp| {
            defer if (resp.body.len > 0) gpa.free(resp.body);
            const R = struct { connected: bool = false, paused: bool = true };
            const p = std.json.parseFromSlice(R, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch return false;
            defer p.deinit();
            g_remote_live = p.value.connected and !p.value.paused;
            return g_remote_live;
        },
        else => return false,
    }
}

/// Run one command on the server's extension, from a process that is not the server.
fn remoteCall(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, method: []const u8, params_json: []const u8, session_id: ?[]const u8, timeout_ms: u32) Error![]u8 {
    const h = readHost(gpa, io, env) orelse return error.NotConnected;
    const sid = if (session_id) |s|
        std.json.Stringify.valueAlloc(gpa, s, .{}) catch return error.OutOfMemory
    else
        (gpa.dupe(u8, "null") catch return error.OutOfMemory);
    defer gpa.free(sid);
    const body = std.fmt.allocPrint(gpa, "{{\"token\":\"{s}\",\"method\":\"{s}\",\"params\":{s},\"sessionId\":{s},\"timeout_ms\":{d}}}", .{ h.token, method, params_json, sid, timeout_ms }) catch return error.OutOfMemory;
    defer gpa.free(body);

    // The HTTP timeout must outlast the command's own deadline, or a slow-but-succeeding navigate is killed
    // by the transport rather than by its own budget.
    const secs: u32 = @intCast(@min(@as(u64, 300), (@as(u64, if (timeout_ms == 0) 30_000 else timeout_ms) / 1000) + 10));
    switch (httpc.request(io, gpa, .{ .method = "POST", .port = h.port, .path = "/api/v1/browser/ext/relay", .body = body, .timeout_s = secs, .cap = 48 << 20 })) {
        .ok => |resp| {
            defer if (resp.body.len > 0) gpa.free(resp.body);
            const R = struct { ok: bool = false, result: ?std.json.Value = null, err: []const u8 = "" };
            const p = std.json.parseFromSlice(R, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch return error.ExtError;
            defer p.deinit();
            if (!p.value.ok) {
                if (p.value.err.len > 0) log.warn("browser ext (relayed): {s} failed: {s}", .{ method, p.value.err });
                return error.ExtError;
            }
            const v = p.value.result orelse return gpa.dupe(u8, "{}") catch error.OutOfMemory;
            return std.json.Stringify.valueAlloc(gpa, v, .{}) catch error.OutOfMemory;
        },
        else => return error.NotConnected,
    }
}

// ------------------------------------------------------------------------------------------ the caller side

/// Issue one CDP command through the extension and wait for its reply. Returns the `result` object as a
/// gpa-owned JSON string, exactly like cdp.callTimeout, so Session cannot tell the two transports apart.
/// `session_id` is the extension's tab handle (see openTab); null addresses the extension itself.
///
/// In a process that is not the server, this hops through the server's relay — the extension is attached
/// there, and only there.
pub fn call(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, method: []const u8, params_json: []const u8, session_id: ?[]const u8, timeout_ms: u32) Error![]u8 {
    if (!g_is_host) return remoteCall(gpa, io, env, method, params_json, session_id, timeout_ms);
    return callLocal(gpa, io, method, params_json, session_id, timeout_ms);
}

/// The in-process path: park the command in a slot and wait for the extension's poll to take it.
pub fn callLocal(gpa: std.mem.Allocator, io: std.Io, method: []const u8, params_json: []const u8, session_id: ?[]const u8, timeout_ms: u32) Error![]u8 {
    if (!localAvailable(io)) return error.NotConnected;
    const params = if (std.mem.trim(u8, params_json, " \r\n\t").len == 0) "{}" else params_json;

    const idx = try park(gpa, io, method, params, session_id orelse "");
    const budget: i64 = if (timeout_ms == 0) 30_000 else @intCast(timeout_ms);
    const deadline = nowMs(io) + budget;

    while (true) {
        g_mu.lockUncancelable(io);
        if (g_slots[idx].state == .done) {
            const failed = g_slots[idx].failed;
            const reply = g_slots[idx].reply;
            g_slots[idx].reply = &.{}; // hand ownership to the caller before clear() frees it
            g_slots[idx].clear();
            g_mu.unlock(io);
            if (failed) {
                if (reply.len > 0) {
                    log.warn("browser ext: {s} failed: {s}", .{ method, reply });
                    gpa.free(reply);
                }
                return error.ExtError;
            }
            return reply;
        }
        g_mu.unlock(io);

        if (nowMs(io) >= deadline) {
            g_mu.lockUncancelable(io);
            g_slots[idx].clear();
            g_mu.unlock(io);
            return error.Timeout;
        }
        // The extension answers a queued command within one poll round trip; 15ms keeps a click feeling
        // immediate without spinning a core while a 30s navigate runs.
        util.sleepMs(15);
    }
}

fn park(gpa: std.mem.Allocator, io: std.Io, method: []const u8, params: []const u8, session_id: []const u8) Error!usize {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (&g_slots, 0..) |*s, i| {
        if (s.state != .free) continue;
        const m = gpa.dupe(u8, method) catch return error.OutOfMemory;
        errdefer gpa.free(m);
        const p = gpa.dupe(u8, params) catch return error.OutOfMemory;
        errdefer gpa.free(p);
        const sid = gpa.dupe(u8, session_id) catch return error.OutOfMemory;
        s.* = .{ .id = g_next_id, .state = .queued, .method = m, .params = p, .session_id = sid, .gpa = gpa };
        g_next_id += 1;
        return i;
    }
    // Every slot busy means 32 browser commands are in flight at once, which the manager's single mutex makes
    // impossible in practice — so this is a leak/stuck-slot signal, not backpressure to wait on.
    log.warn("browser ext: command table full, dropping {s}", .{method});
    return error.NotConnected;
}

// ------------------------------------------------------------------------------------------ the extension side

/// Long-poll: hand the extension every queued command, waiting up to `wait_ms` for one to appear. Returns a
/// gpa-owned JSON array `[{id,method,params,sessionId}, …]` — empty when the wait expires, which is a normal
/// idle answer and not an error.
pub fn takeCommands(gpa: std.mem.Allocator, io: std.Io, wait_ms: i64) []u8 {
    const deadline = nowMs(io) + @min(wait_ms, POLL_MAX_MS);
    while (true) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.append(gpa, '[') catch return dupe(gpa, "[]");
        var n: usize = 0;

        g_mu.lockUncancelable(io);
        for (&g_slots) |*s| {
            if (s.state != .queued) continue;
            const sid = if (s.session_id.len > 0)
                std.fmt.allocPrint(gpa, "\"{s}\"", .{s.session_id}) catch continue
            else
                dupe(gpa, "null");
            defer gpa.free(sid);
            const seg = std.fmt.allocPrint(gpa, "{s}{{\"id\":{d},\"method\":\"{s}\",\"params\":{s},\"sessionId\":{s}}}", .{ if (n > 0) "," else "", s.id, s.method, s.params, sid }) catch continue;
            defer gpa.free(seg);
            out.appendSlice(gpa, seg) catch continue;
            s.state = .sent;
            n += 1;
        }
        g_mu.unlock(io);

        out.append(gpa, ']') catch {
            out.deinit(gpa);
            return dupe(gpa, "[]");
        };
        if (n > 0) return out.toOwnedSlice(gpa) catch dupe(gpa, "[]");
        out.deinit(gpa);

        if (nowMs(io) >= deadline) return dupe(gpa, "[]");
        util.sleepMs(50);
    }
}

/// The extension's answer to command `id`. `payload` is the CDP `result` object on success, or an error
/// message when `failed`. Returns false if no slot is waiting (a late reply after a timeout — dropped).
pub fn deliver(gpa: std.mem.Allocator, io: std.Io, id: u64, payload: []const u8, failed: bool) bool {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (&g_slots) |*s| {
        if (s.state != .sent and s.state != .queued) continue;
        if (s.id != id) continue;
        s.reply = gpa.dupe(u8, payload) catch &.{};
        s.failed = failed;
        s.state = .done;
        return true;
    }
    return false;
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast("");
}

// ---------------------------------------------------------------------------
// tests — this module is the SEAM between an untrusted-ish local extension and a browser session the rest of
// the app drives. Two properties carry everything: (1) a command's lifecycle is airtight — parked, taken
// exactly once, delivered to the right waiter, freed on every exit path including timeout; (2) liveness is
// honest, because `available()` deciding wrong is precisely how a user ends up with no browser at all
// (says connected, isn't) or a silently-ignored extension (says gone, isn't). No browser needed for any of it.
// ---------------------------------------------------------------------------

/// TEST ONLY. Wipe the process-global state so tests do not inherit each other's slots. Also marks this
/// process the HOST, which is what the tests are about: the in-process relay the server runs. The proxy half
/// (a daemon reaching this server over loopback) is covered by ext_api's route tests plus the live end-to-end
/// smoke — asserting it here would mean standing up a second server inside a unit test.
fn resetForTest(io: std.Io) void {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (&g_slots) |*s| s.clear();
    g_next_id = 1;
    g_last_seen_ms = 0;
    g_paused = false;
    g_token_set = false;
    g_browser_len = 0;
    g_ver_len = 0;
    g_is_host = true;
    g_remote_checked_ms = 0;
    g_remote_live = false;
}

/// TEST ONLY. An empty environment: the host path never reads it, and passing it keeps the tests on the
/// PUBLIC entry points rather than the internal local-only ones.
fn testEnv(gpa: std.mem.Allocator) std.process.Environ.Map {
    return std.process.Environ.Map.init(gpa);
}

test "liveness is honest: absent, live, stale and paused are four different answers" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    resetForTest(io);
    defer resetForTest(io);
    var env = testEnv(gpa);
    defer env.deinit();

    // Never seen: not connected, and idle_ms says "no reading" rather than an enormous number.
    try std.testing.expect(!available(gpa, io, &env));
    try std.testing.expect(!status(io).connected);
    try std.testing.expectEqual(@as(i64, -1), status(io).idle_ms);

    // A poll just landed.
    heartbeat(io, "edge", "0.1.0", false);
    try std.testing.expect(available(gpa, io, &env));
    const st = status(io);
    try std.testing.expect(st.connected);
    try std.testing.expectEqualStrings("edge", st.browser);
    try std.testing.expectEqualStrings("0.1.0", st.version);

    // PAUSED is connected-but-not-available: the popup toggle must degrade to the launcher fallback, not
    // report the extension gone (which would hide it from the status UI) and not keep driving it.
    heartbeat(io, "edge", "0.1.0", true);
    try std.testing.expect(status(io).connected);
    try std.testing.expect(!available(gpa, io, &env));

    // STALE: last seen further back than the TTL. Forced directly — sleeping 40s in a test is not a test.
    g_mu.lockUncancelable(io);
    g_paused = false;
    g_last_seen_ms = nowMs(io) - (LIVE_TTL_MS + 1000);
    g_mu.unlock(io);
    try std.testing.expect(!available(gpa, io, &env));
    try std.testing.expect(!status(io).connected);

    // ...and an explicit goodbye is indistinguishable from never-seen.
    heartbeat(io, "chrome", "0.1.0", false);
    try std.testing.expect(available(gpa, io, &env));
    disconnect(io);
    try std.testing.expect(!available(gpa, io, &env));
}

test "a command round-trips: parked, taken once, delivered to its waiter" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    resetForTest(io);
    defer resetForTest(io);
    var env = testEnv(gpa);
    defer env.deinit();
    heartbeat(io, "chrome", "0.1.0", false);

    const idx = try park(gpa, io, "Runtime.evaluate", "{\"expression\":\"1+1\"}", "42");

    // The poll sees it exactly once — a second poll must NOT hand the same command out again, or a click
    // dispatches twice.
    const batch = takeCommands(gpa, io, 0);
    defer gpa.free(batch);
    try std.testing.expect(std.mem.indexOf(u8, batch, "\"Runtime.evaluate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, batch, "\"sessionId\":\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, batch, "\"id\":1") != null);
    const again = takeCommands(gpa, io, 0);
    defer gpa.free(again);
    try std.testing.expectEqualStrings("[]", again);

    // Delivery wakes THAT slot.
    try std.testing.expect(deliver(gpa, io, 1, "{\"result\":{\"value\":2}}", false));
    g_mu.lockUncancelable(io);
    const done = g_slots[idx].state == .done;
    g_mu.unlock(io);
    try std.testing.expect(done);

    // A reply for an id nobody is waiting on is dropped, not misrouted onto another slot.
    try std.testing.expect(!deliver(gpa, io, 9999, "{}", false));

    g_mu.lockUncancelable(io);
    g_slots[idx].clear();
    g_mu.unlock(io);
}

test "call: a delivered reply is returned verbatim, and an extension error surfaces as an error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    resetForTest(io);
    defer resetForTest(io);
    var env = testEnv(gpa);
    defer env.deinit();
    heartbeat(io, "chrome", "0.1.0", false);

    // The extension side runs on its own thread, as it does in production (an httpz worker answering /result
    // while a tool thread blocks in call()).
    const Answer = struct {
        fn go(a: std.mem.Allocator, i: std.Io, id: u64, payload: []const u8, failed: bool) void {
            var tries: u32 = 0;
            while (tries < 400) : (tries += 1) {
                if (deliver(a, i, id, payload, failed)) return;
                util.sleepMs(5);
            }
        }
    };

    {
        const th = try std.Thread.spawn(.{}, Answer.go, .{ gpa, io, @as(u64, 1), "{\"value\":2}", false });
        defer th.join();
        const got = try call(gpa, io, &env, "Runtime.evaluate", "{\"expression\":\"1+1\"}", "42", 5000);
        defer gpa.free(got);
        try std.testing.expectEqualStrings("{\"value\":2}", got);
    }
    {
        const th = try std.Thread.spawn(.{}, Answer.go, .{ gpa, io, @as(u64, 2), "no tab attached", true });
        defer th.join();
        try std.testing.expectError(error.ExtError, call(gpa, io, &env, "Input.dispatchMouseEvent", "{}", "42", 5000));
    }

    // Both slots must be back to free — a leaked slot is invisible until the 33rd command of the session.
    g_mu.lockUncancelable(io);
    var busy: usize = 0;
    for (&g_slots) |*s| {
        if (s.state != .free) busy += 1;
    }
    g_mu.unlock(io);
    try std.testing.expectEqual(@as(usize, 0), busy);
}

test "call: no extension is a refusal, and a silent extension times out without stranding the slot" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    resetForTest(io);
    defer resetForTest(io);
    var env = testEnv(gpa);
    defer env.deinit();

    // Nothing connected: refused OUTRIGHT, never parked. This is the branch manager.openSession reads to
    // decide whether to fall back to launching its own browser, so it has to be immediate, not a timeout.
    try std.testing.expectError(error.NotConnected, call(gpa, io, &env, "Page.navigate", "{}", null, 1000));

    // Connected but not answering (worker evicted mid-command). The caller gets Timeout and the slot is
    // released — otherwise a wedged extension would burn one slot per command until the table filled.
    heartbeat(io, "chrome", "0.1.0", false);
    try std.testing.expectError(error.Timeout, call(gpa, io, &env, "Page.navigate", "{\"url\":\"about:blank\"}", null, 120));
    g_mu.lockUncancelable(io);
    var busy: usize = 0;
    for (&g_slots) |*s| {
        if (s.state != .free) busy += 1;
    }
    g_mu.unlock(io);
    try std.testing.expectEqual(@as(usize, 0), busy);
}

test "the pairing token is stable, and only the exact token opens the door" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    resetForTest(io);
    defer resetForTest(io);
    var env = testEnv(gpa);
    defer env.deinit();

    // Before minting, NOTHING authenticates — including the empty string, which is what an extension that
    // never paired actually sends.
    try std.testing.expect(!tokenOk(io, ""));
    try std.testing.expect(!tokenOk(io, "0123456789abcdef0123456789abcdef"));

    const t1 = ensureToken(io);
    try std.testing.expectEqual(@as(usize, TOKEN_LEN), t1.len);
    var copy: [TOKEN_LEN]u8 = undefined;
    @memcpy(&copy, t1);
    // Idempotent: a second pair request must not rotate the token out from under a live extension.
    try std.testing.expectEqualStrings(&copy, ensureToken(io));
    try std.testing.expect(tokenOk(io, &copy));

    // Length is checked FIRST — the comparison loop reads both buffers in lockstep, so a short token that
    // reached it would read past the caller's slice.
    try std.testing.expect(!tokenOk(io, copy[0 .. TOKEN_LEN - 1]));
    try std.testing.expect(!tokenOk(io, copy ++ "x"));
    var wrong: [TOKEN_LEN]u8 = copy;
    wrong[TOKEN_LEN - 1] = if (wrong[TOKEN_LEN - 1] == 'a') 'b' else 'a';
    try std.testing.expect(!tokenOk(io, &wrong)); // one byte off is off
}

test "the pairing token survives a restart, so a paired extension is not orphaned" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-ext-token-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // Process 1: no file yet → mint and persist. This is the token the user pairs the extension against.
    resetForTest(io);
    loadOrMintToken(io, gpa, root);
    var minted: [TOKEN_LEN]u8 = undefined;
    @memcpy(&minted, ensureToken(io));
    try std.testing.expect(tokenOk(io, &minted));

    // Process 2 — a server RESTART: resetForTest clears every process global (g_token_set included), exactly
    // as a fresh process would start. Before this fix loadOrMintToken did not exist and ensureToken would
    // mint a DIFFERENT token here, orphaning the extension. Now the persisted file is loaded, so the token
    // the extension still holds keeps authenticating.
    resetForTest(io);
    loadOrMintToken(io, gpa, root);
    try std.testing.expectEqualStrings(&minted, ensureToken(io));
    try std.testing.expect(tokenOk(io, &minted));

    // A corrupt / wrong-length file must NOT be adopted as the token — it falls through to a fresh mint
    // rather than handing out a truncated key that no extension could match.
    resetForTest(io);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/.veil-ext-token", .data = "short" });
    loadOrMintToken(io, gpa, root);
    try std.testing.expectEqual(@as(usize, TOKEN_LEN), ensureToken(io).len);
    try std.testing.expect(!tokenOk(io, "short"));

    resetForTest(io);
}

test "takeCommands: an idle poll returns an empty batch rather than blocking forever" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    resetForTest(io);
    defer resetForTest(io);
    var env = testEnv(gpa);
    defer env.deinit();

    const t0 = nowMs(io);
    const batch = takeCommands(gpa, io, 120);
    defer gpa.free(batch);
    const elapsed = nowMs(io) - t0;

    try std.testing.expectEqualStrings("[]", batch);
    try std.testing.expect(elapsed >= 60); // it really waited (a no-wait poll would hammer the server)
    try std.testing.expect(elapsed < 5000); // and the cap is milliseconds, not seconds
}
