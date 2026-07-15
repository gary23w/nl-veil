//! netcli.zig — a deliberately tiny HTTP/1.1 client for the LOCAL veil server (127.0.0.1). Only the few
//! actions that genuinely require the running server go through here: an unauthenticated GET /api/v1/fleet
//! for the dashboard counters, and authenticated POST/DELETE to deploy/cast/remove a swarm. Everything the
//! console/chat/stop needs comes from the filesystem (scan.zig).
//!
//! Transport is httpc.zig (in-process sockets with real HTTP framing and a hard timeout ceiling), so a
//! wedged/slow server surfaces as a clean null — the caller shows "server unreachable" rather than hanging
//! the chat turn that fired the request — and nothing secret ever touches an argv.

const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");
const httpc = @import("httpc.zig");

pub const Resp = httpc.Resp;

// A momentarily starved server pool (a stranded keep-alive/SSE thread freeing within tens of ms) accepts the
// TCP connection but closes without a full reply. That's transient, not "server down", so retry it a couple
// times for IDEMPOTENT requests before giving up.
const MAX_ATTEMPTS = 3;

/// One HTTP round-trip to the local veil server. `timeout_s` is a hard ceiling on the whole round trip:
/// a healthy localhost server answers in milliseconds, so a call that hits the ceiling means the server is
/// wedged/slow — we return null and let the caller report it rather than blocking the thread indefinitely.
/// Transient failures are retried for GET/DELETE; a POST is tried once (an empty reply might mean the server
/// already processed it, and a retry would deploy a duplicate swarm).
fn httpReq(io: Io, gpa: std.mem.Allocator, method: []const u8, port: u16, path: []const u8, token: []const u8, body_json: ?[]const u8, timeout_s: u32) ?Resp {
    log.trace("netcli.httpReq {s} {s} timeout={d}s has_body={}", .{ method, path, timeout_s, body_json != null });

    // POST has side effects (deploy/cast); only idempotent GET/DELETE are retried on a transient failure.
    const idempotent = !std.mem.eql(u8, method, "POST");
    var attempt: u8 = 0;
    while (attempt < MAX_ATTEMPTS) : (attempt += 1) {
        if (attempt > 0) {
            // Linear backoff (120ms, 240ms): long enough for a starved worker thread to free, short enough
            // that a healthy call (which never reaches here) is unaffected.
            io.sleep(.{ .nanoseconds = @as(u64, attempt) * 120 * std.time.ns_per_ms }, .awake) catch {};
        }

        // `Connection: close` (inside httpc): the poller opens a fresh connection every few seconds, so we
        // want the server to CLOSE each one right after replying rather than hold it half-open (keep-alive ->
        // CLOSE_WAIT pile-up that exhausts a small local server).
        switch (httpc.request(io, gpa, .{
            .method = method,
            .port = port,
            .path = path,
            .bearer = token,
            .body = body_json,
            .timeout_s = timeout_s,
        })) {
            .ok => |resp| {
                log.dbg("http: {s} {s} -> {d} ({d}b)", .{ method, path, resp.status, resp.body.len });
                return resp;
            },
            // nothing listening: the server really is down — fail fast, retrying won't help
            .refused => {
                log.err("http: {s} {s} connect refused — server not running", .{ method, path });
                return null;
            },
            // hard ceiling hit: the server is wedged; retrying just multiplies the stall — fail fast
            .timed_out => {
                log.warn("http: {s} {s} timed out after {d}s — server wedged/slow", .{ method, path, timeout_s });
                return null;
            },
            // reset/short reply/unparseable: a starved pool freeing in tens of ms — worth a retry
            .failed => log.warn("http: {s} {s} did not complete — server busy (attempt {d}/{d})", .{ method, path, attempt + 1, MAX_ATTEMPTS }),
        }

        if (!idempotent) return null; // side-effecting POST: one shot only, never retry
    }
    log.err("http: {s} {s} failed after {d} attempts — server busy or down", .{ method, path, MAX_ATTEMPTS });
    return null;
}

/// GET /api/v1/fleet — unauthenticated; returns the raw JSON body for the caller to scan. Short timeout:
/// the poller calls this on every refresh, so a slow server must not stall the poller for long.
pub fn fleet(io: Io, gpa: std.mem.Allocator, port: u16) ?Resp {
    log.trace("netcli.fleet port={d}", .{port});
    return httpReq(io, gpa, "GET", port, "/api/v1/fleet", "", null, 6);
}

/// POST /api/v1/swarms — the full deploy the Deploy button fires. `token` (if non-empty) is the bearer key;
/// with no token the server 401s and the caller surfaces "connect a token in Settings".
pub fn deploy(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, body_json: []const u8) ?Resp {
    log.trace("netcli.deploy port={d} body_len={d}", .{ port, body_json.len });
    return httpReq(io, gpa, "POST", port, "/api/v1/swarms", token, body_json, 15);
}

/// POST /api/v1/cast — the chat's cast door: a small {goal, provider, model, ...} body deploys a bounded
/// swarm with the SERVER's cast defaults and returns {ok,id,...} at once. Bounded so a slow server can never
/// freeze the chat turn that fired the cast.
pub fn cast(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, body_json: []const u8) ?Resp {
    log.trace("netcli.cast port={d} body_len={d}", .{ port, body_json.len });
    return httpReq(io, gpa, "POST", port, "/api/v1/cast", token, body_json, 15);
}

/// POST /api/v1/chat/tool — run ONE shared tool (mind tool or orchestration verb) exactly the way a
/// hive mind would. body_json = {"tool":..,"args":<json-string>,"id":..}. Generous timeout: a web_search
/// mind tool can spend ~30s fetching before it answers.
pub fn chatTool(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, body_json: []const u8) ?Resp {
    log.trace("netcli.chatTool port={d} body_len={d}", .{ port, body_json.len });
    return httpReq(io, gpa, "POST", port, "/api/v1/chat/tool", token, body_json, 45);
}

/// POST /api/v1/chat/convs/<conv>/messages — run ONE server-side chat turn for this conversation.
/// body_json = {"text":..,"base_url":..,"model":..,"api_key":..}. The turn runs
/// SYNCHRONOUSLY server-side, so this blocks until it finishes or the ceiling is hit — the turn's frames are
/// written to the conv's events.jsonl incrementally either way, and chatEvents renders them. `conv` is the
/// safeSeg-clean conversation id (no URL-escaping needed). Generous ceiling: a full agentic turn (several tool
/// calls) can run well past a single tool's time.
pub fn chatSend(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, conv: []const u8, body_json: []const u8) ?Resp {
    log.trace("netcli.chatSend port={d} conv={s} body_len={d}", .{ port, conv, body_json.len });
    var pbuf: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/chat/convs/{s}/messages", .{conv}) catch return null;
    return httpReq(io, gpa, "POST", port, path, token, body_json, 180);
}

/// GET /api/v1/chat/convs/<conv>/events?from=<from> — byte-cursor poll over the conv's events.jsonl: returns the
/// bytes from offset `from` to end (so the NEXT offset = from + returned_body.len). Idempotent + short ceiling:
/// the desk poller calls this ~1Hz while a server turn runs, so a slow server must not stall it for long.
pub fn chatEvents(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, conv: []const u8, from: usize) ?Resp {
    log.trace("netcli.chatEvents port={d} conv={s} from={d}", .{ port, conv, from });
    var pbuf: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/chat/convs/{s}/events?from={d}", .{ conv, from }) catch return null;
    return httpReq(io, gpa, "GET", port, path, token, null, 8);
}

/// POST /api/v1/chat/convs/<conv>/control — write a cooperative control op (e.g. {"op":"stop"}) the running
/// server turn reads BETWEEN steps + before each inference. Fire-and-return; the turn aborts at its next check.
pub fn chatControl(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, conv: []const u8, body_json: []const u8) ?Resp {
    log.trace("netcli.chatControl port={d} conv={s}", .{ port, conv });
    var pbuf: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/chat/convs/{s}/control", .{conv}) catch return null;
    return httpReq(io, gpa, "POST", port, path, token, body_json, 8);
}

/// GET /api/v1/chat/convs — the SERVER's conversation list (scheduled_* runs live only there). Short
/// ceiling: the chat worker folds this into its ~5s sidebar refresh, so a slow server must not stall it.
pub fn chatConvs(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8) ?Resp {
    log.trace("netcli.chatConvs port={d}", .{port});
    return httpReq(io, gpa, "GET", port, "/api/v1/chat/convs", token, null, 6);
}

/// GET /api/v1/chat/convs/<conv> — one server conversation's full message log ({role,content,kind,ts}
/// objects), fetched once to mirror a server-born conv into the local chats dir when it's selected.
pub fn chatConv(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, conv: []const u8) ?Resp {
    log.trace("netcli.chatConv port={d} conv={s}", .{ port, conv });
    var pbuf: [200]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/chat/convs/{s}", .{conv}) catch return null;
    return httpReq(io, gpa, "GET", port, path, token, null, 8);
}

/// GET /api/v1/sched — the scheduled-task list (admin-gated: a non-admin token 403s and the caller
/// surfaces it). Short ceiling: the poller refreshes this every few seconds beside the fleet poll.
pub fn schedList(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8) ?Resp {
    log.trace("netcli.schedList port={d}", .{port});
    return httpReq(io, gpa, "GET", port, "/api/v1/sched", token, null, 6);
}

/// POST /api/v1/sched — create one scheduled task. `body_json` is the complete task the UI built
/// (name/prompt/details/kind/at/every_min/hm/enabled + the provider snapshot incl. api_key, which the
/// server stores write-only). One shot like every POST here — a duplicate task beats a lost one never.
pub fn schedCreate(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, body_json: []const u8) ?Resp {
    log.trace("netcli.schedCreate port={d} body_len={d}", .{ port, body_json.len });
    return httpReq(io, gpa, "POST", port, "/api/v1/sched", token, body_json, 15);
}

/// POST /api/v1/sched/<id> — update any subset of a task's fields (commonly {"enabled":false}).
pub fn schedUpdate(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, id: []const u8, body_json: []const u8) ?Resp {
    log.trace("netcli.schedUpdate port={d} id={s}", .{ port, id });
    var pbuf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/sched/{s}", .{id}) catch return null;
    return httpReq(io, gpa, "POST", port, path, token, body_json, 15);
}

/// DELETE /api/v1/sched/<id> — remove one scheduled task.
pub fn schedDelete(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, id: []const u8) ?Resp {
    log.trace("netcli.schedDelete port={d} id={s}", .{ port, id });
    var pbuf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/sched/{s}", .{id}) catch return null;
    return httpReq(io, gpa, "DELETE", port, path, token, null, 15);
}

/// POST /api/v1/sched/<id>/run — fire one task NOW; the server answers {ok,conv:"scheduled_..."}. The
/// body is an empty object (the server wants none, but a bodyless POST is ambiguous to some stacks).
pub fn schedRun(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, id: []const u8) ?Resp {
    log.trace("netcli.schedRun port={d} id={s}", .{ port, id });
    var pbuf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/sched/{s}/run", .{id}) catch return null;
    return httpReq(io, gpa, "POST", port, path, token, "{}", 15);
}

/// DELETE /api/v1/swarms/<id> — the server stops the worker and removes its run dir. Needs the bearer key.
pub fn delete(io: Io, gpa: std.mem.Allocator, port: u16, token: []const u8, id: []const u8) ?Resp {
    log.trace("netcli.delete port={d} id={s}", .{ port, id });
    var pbuf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/api/v1/swarms/{s}", .{id}) catch return null;
    return httpReq(io, gpa, "DELETE", port, path, token, null, 15);
}

test "netcli round-trips in-process against a running server (best-effort, skips if down)" {
    // Requires: a veil server on :8787 + a valid key at ../data/.desktop_key. If either is missing this
    // returns early (harmless). Proves the raw-socket client returns a bounded result and never hangs.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const raw = Io.Dir.cwd().readFileAlloc(io, "../data/.desktop_key", std.testing.allocator, .limited(256)) catch {
        std.debug.print("\n[netcli test] no ../data/.desktop_key — start a server first; skipping\n", .{});
        return;
    };
    defer std.testing.allocator.free(raw);
    const key = std.mem.trim(u8, raw, " \r\n\t");

    // GET /fleet — unauth; proves the client talks and returns (bounded by the timeout either way)
    if (fleet(io, std.testing.allocator, 8787)) |fr| {
        defer if (fr.body.len > 0) std.testing.allocator.free(fr.body);
        std.debug.print("\n[netcli test] fleet status={d} body={s}\n", .{ fr.status, fr.body[0..@min(fr.body.len, 100)] });
        try std.testing.expect(fr.status > 0);
    } else {
        std.debug.print("\n[netcli test] fleet: no response (server down/slow) — bounded, not a hang\n", .{});
    }

    // POST /cast — the exact door the chat uses; a mock provider keeps it instant and cheap
    const body = "{\"provider\":\"mock\",\"model\":\"mock\",\"minutes\":1,\"api_key\":\"\",\"goal\":\"netcli in-process round-trip test\"}";
    if (cast(io, std.testing.allocator, 8787, key, body)) |cr| {
        defer if (cr.body.len > 0) std.testing.allocator.free(cr.body);
        std.debug.print("[netcli test] CAST status={d} body={s}\n", .{ cr.status, cr.body[0..@min(cr.body.len, 160)] });
        try std.testing.expect(cr.status == 200 or cr.status == 201);
    } else {
        std.debug.print("[netcli test] CAST: no response (server down/slow) — bounded, not a hang\n", .{});
    }
}
