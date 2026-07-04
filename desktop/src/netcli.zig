//! netcli.zig — a deliberately tiny HTTP/1.1 client for the LOCAL veil server (127.0.0.1). Only the few
//! actions that genuinely require the running server go through here: an unauthenticated GET /api/v1/fleet
//! for the dashboard counters, and authenticated POST/DELETE to deploy/cast/remove a swarm. Everything the
//! console/chat/stop needs comes from the filesystem (scan.zig).
//!
//! It shells out to `curl` (the same dependency llm.zig already uses) rather than a hand-rolled socket
//! read. WHY: the previous raw-socket client read the response to end-of-stream with NO time bound, trusting
//! the server to close the connection after `Connection: close`. When the httpz server instead keeps the
//! socket alive (or stalls under load), that read blocked FOREVER — and since the chat fires a cast through
//! here, a wedged/slow server would freeze the whole chat turn (the "casting hangs" bug). curl parses the
//! real HTTP framing (Content-Length/chunked) and `--max-time` is a hard ceiling, so a slow or wedged
//! server now surfaces as a clean null (caller shows "server unreachable") instead of an infinite hang.

const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");

pub const Resp = struct {
    status: u16 = 0,
    body: []u8 = &.{}, // gpa-owned; caller frees when len>0
};

// curl -w marker: the HTTP status is appended after the body on its own line so we can split it off. The
// token is unlikely to appear in a JSON body; we match the LAST occurrence to be safe.
const STAT_MARK = "\n__NCSTAT__";
const STAT_FMT = STAT_MARK ++ "%{http_code}";

// A momentarily starved server pool (a stranded keep-alive/SSE thread freeing within tens of ms) accepts the
// TCP connection but closes without a full reply — curl reports that as a fast non-zero exit (empty reply /
// recv error), i.e. the classic status 000. That's transient, not "server down", so retry it a couple times
// for IDEMPOTENT requests before giving up.
const MAX_ATTEMPTS = 3;

/// One HTTP round-trip to the local veil server via curl. `timeout_s` is a hard ceiling (curl --max-time):
/// a healthy localhost server answers in milliseconds, so a call that hits the ceiling means the server is
/// wedged/slow — we return null and let the caller report it rather than blocking the thread indefinitely.
/// Transient failures are retried for GET/DELETE; a POST is tried once (an empty reply might mean the server
/// already processed it, and a retry would deploy a duplicate swarm).
fn curlReq(io: Io, gpa: std.mem.Allocator, method: []const u8, port: u16, path: []const u8, token: []const u8, body_json: ?[]const u8, timeout_s: []const u8) ?Resp {
    var url_buf: [320]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path }) catch return null;
    var auth_buf: [220]u8 = undefined;
    const auth: []const u8 = if (token.len > 0)
        (std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{token}) catch return null)
    else
        "";

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    // `--no-keepalive` + `Connection: close`: the poller opens a fresh connection every few seconds, so we
    // want the server to CLOSE each one right after replying rather than hold it half-open (keep-alive ->
    // CLOSE_WAIT pile-up that exhausts a small local server). Restores what the old raw-socket client did.
    argv.appendSlice(gpa, &.{ "curl", "-sS", "--no-keepalive", "--max-time", timeout_s, "-X", method, "-H", "Connection: close" }) catch return null;
    if (auth.len > 0) argv.appendSlice(gpa, &.{ "-H", auth }) catch return null;
    if (body_json) |b| argv.appendSlice(gpa, &.{ "-H", "Content-Type: application/json", "--data-binary", b }) catch return null;
    argv.appendSlice(gpa, &.{ "-w", STAT_FMT, url }) catch return null;

    // POST has side effects (deploy/cast) — an empty reply could mean the server already ran it, so retrying
    // could deploy a duplicate. Only GET/DELETE (idempotent) are retried on a transient failure.
    const idempotent = !std.mem.eql(u8, method, "POST");
    var attempt: u8 = 0;
    while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
        if (attempt > 0) {
            // Linear backoff (120ms, 240ms): long enough for a starved worker thread to free, short enough
            // that a healthy call (which never reaches here) is unaffected.
            io.sleep(.{ .nanoseconds = @as(u64, attempt) * 120 * std.time.ns_per_ms }, .awake) catch {};
        }

        const res = std.process.run(gpa, io, .{ .argv = argv.items, .stdout_limit = .limited(1 << 20) }) catch |e| {
            log.err("http: curl {s} {s} spawn failed: {t}", .{ method, path, e });
            return null; // curl itself won't spawn — retrying won't help
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        if (res.term == .exited and res.term.exited == 0) {
            const out = res.stdout;
            if (std.mem.lastIndexOf(u8, out, STAT_MARK)) |mark| {
                const code = std.mem.trim(u8, out[mark + STAT_MARK.len ..], " \r\n\t");
                const status = std.fmt.parseInt(u16, code, 10) catch 0;
                if (status != 0) {
                    const body = gpa.dupe(u8, out[0..mark]) catch return null;
                    log.dbg("http: {s} {s} -> {d} ({d}b)", .{ method, path, status, body.len });
                    return .{ .status = status, .body = body };
                }
            }
            log.warn("http: {s} {s} — no status in {d}b reply (attempt {d}/{d})", .{ method, path, out.len, attempt + 1, MAX_ATTEMPTS });
        } else {
            const curl_exit: i64 = if (res.term == .exited) res.term.exited else -1;
            // curl 7 = couldn't connect (nothing listening): the server really is down — fail fast.
            // curl 28 = --max-time hit: the server is wedged; retrying just multiplies the stall — fail fast.
            if (curl_exit == 7) {
                log.err("http: curl {s} {s} connect refused (exit 7) — server not running", .{ method, path });
                return null;
            }
            if (curl_exit == 28) {
                log.warn("http: curl {s} {s} timed out (exit 28) — server wedged/slow", .{ method, path });
                return null;
            }
            log.warn("http: curl {s} {s} did not complete (exit {any}) — server busy (attempt {d}/{d})", .{ method, path, res.term, attempt + 1, MAX_ATTEMPTS });
        }

        if (!idempotent) return null; // side-effecting POST: one shot only, never retry
    }
    log.err("http: {s} {s} failed after {d} attempts — server busy or down", .{ method, path, MAX_ATTEMPTS });
    return null;
}

/// GET /api/v1/fleet — unauthenticated; returns the raw JSON body for the caller to scan. Short timeout:
/// the poller calls this on every refresh, so a slow server must not stall the poller for long.
pub fn fleet(io: Io, gpa: std.mem.Allocator, port: u16) ?Resp {
    return curlReq(io, gpa, "GET", port, "/api/v1/fleet", "", null, "6");
}

/// POST /api/v1/swarms — the full deploy the Deploy button fires. `token` (if non-empty) is the bearer key;
/// with no token the server 401s and the caller surfaces "connect a token in Settings".
pub fn deploy(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, body_json: []const u8) ?Resp {
    return curlReq(io, gpa, "POST", port, "/api/v1/swarms", token, body_json, "15");
}

/// POST /api/v1/cast — the chat's cast door: a small {goal, provider, model, ...} body deploys a bounded
/// swarm with the SERVER's cast defaults and returns {ok,id,...} at once. Bounded so a slow server can never
/// freeze the chat turn that fired the cast.
pub fn cast(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, body_json: []const u8) ?Resp {
    return curlReq(io, gpa, "POST", port, "/api/v1/cast", token, body_json, "15");
}

/// DELETE /api/v1/swarms/<id> — the server stops the worker and removes its run dir. Needs the bearer key.
pub fn delete(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, id: []const u8) ?Resp {
    var pbuf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/swarms/{s}", .{id}) catch return null;
    return curlReq(io, gpa, "DELETE", port, path, token, null, "15");
}

test "netcli round-trips through curl against a running server (best-effort, skips if down)" {
    // Requires: a veil server on :8787 + a valid key at ../data/.desktop_key. If either is missing this
    // returns early (harmless). Proves the curl client returns a bounded result and never hangs.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const raw = Io.Dir.cwd().readFileAlloc(io, "../data/.desktop_key", std.testing.allocator, .limited(256)) catch {
        std.debug.print("\n[netcli test] no ../data/.desktop_key — start a server first; skipping\n", .{});
        return;
    };
    defer std.testing.allocator.free(raw);
    const key = std.mem.trim(u8, raw, " \r\n\t");

    // GET /fleet — unauth; proves the client talks and returns (bounded by --max-time either way)
    if (fleet(io, std.testing.allocator, 8787)) |fr| {
        defer if (fr.body.len > 0) std.testing.allocator.free(fr.body);
        std.debug.print("\n[netcli test] fleet status={d} body={s}\n", .{ fr.status, fr.body[0..@min(fr.body.len, 100)] });
        try std.testing.expect(fr.status > 0);
    } else {
        std.debug.print("\n[netcli test] fleet: no response (server down/slow) — bounded, not a hang\n", .{});
    }

    // POST /cast — the exact door the chat uses; a mock provider keeps it instant and cheap
    const body = "{\"provider\":\"mock\",\"model\":\"mock\",\"minutes\":1,\"api_key\":\"\",\"goal\":\"netcli curl round-trip test\"}";
    if (cast(io, std.testing.allocator, 8787, key, body)) |cr| {
        defer if (cr.body.len > 0) std.testing.allocator.free(cr.body);
        std.debug.print("[netcli test] CAST status={d} body={s}\n", .{ cr.status, cr.body[0..@min(cr.body.len, 160)] });
        try std.testing.expect(cr.status == 200 or cr.status == 201);
    } else {
        std.debug.print("[netcli test] CAST: no response (server down/slow) — bounded, not a hang\n", .{});
    }
}
