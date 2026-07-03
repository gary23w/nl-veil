//! llm.zig — the desktop's chat-model client. ONE interface (base_url + key + model, OpenAI-compatible
//! /chat/completions) behind which every provider plugs: local Ollama, a BYOK cloud provider, or a custom
//! endpoint URL. Transport mirrors the ENGINE's own convention (src/worker/llm.zig): the key rides in a
//! curl CONFIG FILE (never on argv), the body in a request file, and curl does the HTTP — which buys TLS
//! for the hosted providers without betting on std.http in this Zig. Streaming is filesystem-first like
//! the rest of veil-desk: curl -N writes the SSE stream to a scratch file and the chat thread TAILS it,
//! appending deltas to the Store as they land. Runs on the CHAT thread only.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = @import("log.zig");

/// The one provider shape. Chat settings (local / BYOK / custom) all resolve to this.
pub const Provider = struct {
    base_url: []const u8, // ".../v1" root; /chat/completions is appended
    key: []const u8, // empty = no Authorization header content (local)
    model: []const u8,
};

/// The REAL process environment for an Io instance that spawns children. Threaded.init defaults to
/// `.empty`, and a child with an empty env block can't even init Winsock on Windows (curl dies with
/// "service provider could not be loaded") — so any Io that runs curl MUST carry this. On Windows the
/// global block reads the live PEB; on POSIX we hand over libc's environ (raylib links libc everywhere).
pub fn osEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

pub const Stream = struct {
    child: ?std.process.Child = null,
    out_path: [300]u8 = [_]u8{0} ** 300,
    out_path_len: u16 = 0,
    offset: usize = 0, // bytes of the SSE file already consumed
    carry: [4096]u8 = [_]u8{0} ** 4096, // partial trailing line between polls
    carry_len: usize = 0,
    saw_sse: bool = false, // first chunk decided: SSE stream vs plain JSON body
    saw_any: bool = false,
    done: bool = false,
    failed: bool = false,
    err: [200]u8 = [_]u8{0} ** 200,
    err_len: u8 = 0,
    content: std.ArrayListUnmanaged(u8) = .empty, // accumulated assistant text (gpa-owned)
    started_s: i64 = 0,
    last_growth_s: i64 = 0,

    pub fn errStr(s: *const Stream) []const u8 {
        return s.err[0..s.err_len];
    }
    pub fn outPath(s: *const Stream) []const u8 {
        return s.out_path[0..s.out_path_len];
    }
    pub fn deinit(s: *Stream, gpa: std.mem.Allocator) void {
        s.content.deinit(gpa);
        s.* = .{};
    }
};

const FIRST_BYTE_TIMEOUT_S = 150; // a cold local 20B can take >1min to first token
const STALL_TIMEOUT_S = 120;
const TOTAL_TIMEOUT_S = 420;

fn setErr(s: *Stream, msg: []const u8) void {
    const n = @min(msg.len, s.err.len);
    @memcpy(s.err[0..n], msg[0..n]);
    s.err_len = @intCast(n);
    s.failed = true;
    s.done = true;
}

/// Kick off one streaming chat completion. `messages_json` is the inside of "messages":[ … ] (caller-built
/// and escaped). Scratch files live under `dir` (the .veil-desk sidecar). Returns false on spawn failure.
pub fn start(s: *Stream, io: Io, gpa: std.mem.Allocator, dir: []const u8, prov: Provider, messages_json: []const u8, max_tokens: u32, now_s: i64) bool {
    s.* = .{ .started_s = now_s, .last_growth_s = now_s };

    const url = std.fmt.allocPrint(gpa, "{s}/chat/completions", .{trimSlash(prov.base_url)}) catch return false;
    defer gpa.free(url);
    const reqpath = std.fmt.allocPrint(gpa, "{s}/.chatreq.json", .{dir}) catch return false;
    defer gpa.free(reqpath);
    const cfgpath = std.fmt.allocPrint(gpa, "{s}/.chatcurlcfg", .{dir}) catch return false;
    defer gpa.free(cfgpath);
    const outpath = std.fmt.allocPrint(gpa, "{s}/.chatstream.sse", .{dir}) catch return false;
    defer gpa.free(outpath);
    {
        const n = @min(outpath.len, s.out_path.len);
        @memcpy(s.out_path[0..n], outpath[0..n]);
        s.out_path_len = @intCast(n);
    }
    // stale stream from the previous turn must not be re-read as fresh deltas
    Io.Dir.cwd().deleteFile(io, outpath) catch {};

    const body = std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":true,\"max_tokens\":{d}}}", .{ prov.model, messages_json, max_tokens }) catch return false;
    defer gpa.free(body);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = reqpath, .data = body }) catch {
        log.err("chat llm: cannot write request file", .{});
        return false;
    };
    // Engine convention: the key lives in a curl config file, never on the argv (visible in process lists).
    const cfg = if (prov.key.len > 0)
        std.fmt.allocPrint(gpa, "header = \"Authorization: Bearer {s}\"\nheader = \"Content-Type: application/json\"\n", .{prov.key}) catch return false
    else
        gpa.dupe(u8, "header = \"Content-Type: application/json\"\n") catch return false;
    defer gpa.free(cfg);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgpath, .data = cfg }) catch {
        log.err("chat llm: cannot write curl config", .{});
        return false;
    };

    const data_at = std.fmt.allocPrint(gpa, "@{s}", .{reqpath}) catch return false;
    defer gpa.free(data_at);
    var tt_buf: [16]u8 = undefined;
    const tt = std.fmt.bufPrint(&tt_buf, "{d}", .{TOTAL_TIMEOUT_S}) catch "420";
    const argv: []const []const u8 = &.{ "curl", "-sS", "-N", "--max-time", tt, "-K", cfgpath, "--data-binary", data_at, "-o", outpath, url };
    s.child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch |e| {
        log.err("chat llm: curl spawn failed: {t}", .{e});
        return false;
    };
    log.info("chat llm: -> {s} model={s} body={d}b key={d}b", .{ url, prov.model, body.len, prov.key.len });
    return true;
}

/// Tail the stream file: consume any new bytes, folding deltas into s.content. Call ~10x/sec while a turn
/// is in flight; `s.done` flips when the reply is complete (or failed — check s.failed / errStr()).
pub fn poll(s: *Stream, io: Io, gpa: std.mem.Allocator, now_s: i64) void {
    if (s.done) return;
    const data = Io.Dir.cwd().readFileAlloc(io, s.outPath(), gpa, .limited(8 << 20)) catch {
        // file not created yet — curl still connecting (or it died before writing)
        checkTimeouts(s, io, now_s);
        return;
    };
    defer gpa.free(data);
    if (data.len > s.offset) {
        consume(s, gpa, data[s.offset..]);
        s.offset = data.len;
        s.last_growth_s = now_s;
    } else if (s.saw_any and !s.saw_sse) {
        // plain-JSON body (backend ignored stream:true): complete once the object closes + carries a
        // terminal key — brace-end alone can be a partial write.
        tryWholeJson(s, gpa, data);
        if (!s.done) checkTimeouts(s, io, now_s);
        return;
    }
    if (!s.done) checkTimeouts(s, io, now_s);
}

fn checkTimeouts(s: *Stream, io: Io, now_s: i64) void {
    const first_to = !s.saw_any and now_s - s.started_s > FIRST_BYTE_TIMEOUT_S;
    const stall_to = s.saw_any and now_s - s.last_growth_s > STALL_TIMEOUT_S;
    const total_to = now_s - s.started_s > TOTAL_TIMEOUT_S + 15;
    if (first_to or stall_to or total_to) {
        abort(s, io);
        setErr(s, if (first_to) "no response from the model endpoint — check the provider settings" else "the model stream stalled");
    }
}

/// Feed newly-arrived bytes through the SSE/JSON state machine.
fn consume(s: *Stream, gpa: std.mem.Allocator, new_bytes: []const u8) void {
    if (!s.saw_any) {
        // decide the framing on the first non-whitespace bytes
        const t = std.mem.trimStart(u8, new_bytes, " \r\n\t");
        if (t.len == 0) return;
        s.saw_any = true;
        s.saw_sse = std.mem.startsWith(u8, t, "data:") or std.mem.startsWith(u8, t, "event:") or std.mem.startsWith(u8, t, ":");
    }
    if (!s.saw_sse) {
        // non-SSE: buffer everything into carry? bodies can exceed carry — accumulate into content-side
        // scratch instead: stash raw JSON in `content` temporarily is wrong. Simplest: whole-body parse
        // happens in poll() from the full file; here just note growth.
        return;
    }
    // SSE: process complete lines; keep the trailing partial in carry.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, s.carry[0..s.carry_len]) catch return;
    buf.appendSlice(gpa, new_bytes) catch return;
    var rest: []const u8 = buf.items;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = std.mem.trimEnd(u8, rest[0..nl], "\r");
        rest = rest[nl + 1 ..];
        handleSseLine(s, gpa, line);
        if (s.done) return;
    }
    s.carry_len = @min(rest.len, s.carry.len);
    @memcpy(s.carry[0..s.carry_len], rest[0..s.carry_len]);
}

fn handleSseLine(s: *Stream, gpa: std.mem.Allocator, line: []const u8) void {
    if (!std.mem.startsWith(u8, line, "data:")) return;
    const payload = std.mem.trim(u8, line[5..], " ");
    if (payload.len == 0) return;
    if (std.mem.eql(u8, payload, "[DONE]")) {
        s.done = true;
        return;
    }
    if (extractErr(payload)) |msg| {
        var mb: [200]u8 = undefined;
        const n = @min(msg.len, mb.len);
        @memcpy(mb[0..n], msg[0..n]);
        setErr(s, mb[0..n]);
        return;
    }
    // {"choices":[{"delta":{"content":"..."}}]} — role-only/finish chunks have no content key
    if (jsonUnescape(gpa, payload, "content")) |piece| {
        defer gpa.free(piece);
        s.content.appendSlice(gpa, piece) catch {};
    }
}

/// Non-stream fallback: the whole body is one JSON object. Only accept it once a terminal key is present
/// so a half-written file doesn't parse as a truncated answer.
fn tryWholeJson(s: *Stream, gpa: std.mem.Allocator, data: []const u8) void {
    const t = std.mem.trim(u8, data, " \r\n\t");
    if (t.len < 2 or t[t.len - 1] != '}') return;
    const terminal = std.mem.indexOf(u8, t, "\"finish_reason\"") != null or
        std.mem.indexOf(u8, t, "\"usage\"") != null or
        std.mem.indexOf(u8, t, "\"done\":true") != null or
        std.mem.indexOf(u8, t, "\"error\"") != null;
    if (!terminal) return;
    if (extractErr(t)) |msg| {
        var mb: [200]u8 = undefined;
        const n = @min(msg.len, mb.len);
        @memcpy(mb[0..n], msg[0..n]);
        setErr(s, mb[0..n]);
        return;
    }
    if (jsonUnescape(gpa, t, "content")) |piece| {
        defer gpa.free(piece);
        s.content.clearRetainingCapacity();
        s.content.appendSlice(gpa, piece) catch {};
        s.done = true;
    }
}

/// Error bodies: {"error":{"message":"..."}} or {"error":"..."}. Returns a slice into a static buffer.
var err_scratch: [200]u8 = undefined;
fn extractErr(obj: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, obj, "\"error\"") orelse return null;
    _ = at;
    if (jsonStrInto(obj, "message", &err_scratch)) |m| return m;
    // "error":"plain string"
    const needle = "\"error\":";
    const ei = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = ei + needle.len;
    while (i < obj.len and obj[i] == ' ') i += 1;
    if (i < obj.len and obj[i] == '"') {
        i += 1;
        var w: usize = 0;
        while (i < obj.len and obj[i] != '"' and w < err_scratch.len) : (i += 1) {
            err_scratch[w] = obj[i];
            w += 1;
        }
        return err_scratch[0..w];
    }
    return "model endpoint returned an error";
}

/// Bounded no-unescape string read (for small fields like error messages).
fn jsonStrInto(obj: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const at = std.mem.indexOf(u8, obj, kbuf[0 .. 3 + key.len]) orelse return null;
    var i = at + key.len + 3;
    while (i < obj.len and obj[i] == ' ') i += 1;
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    var w: usize = 0;
    while (i < obj.len and obj[i] != '"' and w < out.len) : (i += 1) {
        if (obj[i] == '\\') i += 1; // skip escapes coarsely for display strings
        if (i < obj.len) {
            out[w] = obj[i];
            w += 1;
        }
    }
    return out[0..w];
}

/// Full JSON string unescape for "key":"…" (handles \n \t \" \\ and \uXXXX incl. surrogate pairs) —
/// deltas AND whole non-stream bodies go through this, so it allocates. Caller frees. Pub because the
/// chat thread reuses it to parse stored conversation lines (same escaping rules).
pub fn jsonUnescape(gpa: std.mem.Allocator, obj: []const u8, key: []const u8) ?[]u8 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const at = std.mem.indexOf(u8, obj, kbuf[0 .. 3 + key.len]) orelse return null;
    var i = at + key.len + 3;
    while (i < obj.len and obj[i] == ' ') i += 1;
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    while (i < obj.len) {
        const c = obj[i];
        if (c == '"') break;
        if (c != '\\') {
            out.append(gpa, c) catch return null;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= obj.len) break;
        const e = obj[i];
        i += 1;
        switch (e) {
            'n' => out.append(gpa, '\n') catch return null,
            't' => out.append(gpa, '\t') catch return null,
            'r' => {},
            'b', 'f' => {},
            'u' => {
                if (i + 4 > obj.len) break;
                var cp: u21 = std.fmt.parseInt(u16, obj[i .. i + 4], 16) catch 0;
                i += 4;
                // surrogate pair → single codepoint
                if (cp >= 0xD800 and cp <= 0xDBFF and i + 6 <= obj.len and obj[i] == '\\' and obj[i + 1] == 'u') {
                    const lo = std.fmt.parseInt(u16, obj[i + 2 .. i + 6], 16) catch 0;
                    if (lo >= 0xDC00 and lo <= 0xDFFF) {
                        cp = 0x10000 + ((@as(u21, @intCast(cp)) - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    }
                }
                var ub: [4]u8 = undefined;
                const un = std.unicode.utf8Encode(cp, &ub) catch 1;
                out.appendSlice(gpa, ub[0..un]) catch return null;
            },
            else => out.append(gpa, e) catch return null,
        }
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Kill the curl child (timeout / user abort). Child.kill terminates, reaps and cleans up in one call
/// (idempotent) — calling wait() after it would assert on the cleared handle.
pub fn abort(s: *Stream, io: Io) void {
    if (s.child) |*c| {
        c.kill(io);
        s.child = null;
    }
}

/// Reap the child after a normal completion (it has already exited once [DONE]/body landed).
pub fn finish(s: *Stream, io: Io) void {
    if (s.child) |*c| {
        if (c.id != null) {
            _ = c.wait(io) catch {};
        }
        s.child = null;
    }
}

fn trimSlash(u: []const u8) []const u8 {
    var v = u;
    while (v.len > 0 and v[v.len - 1] == '/') v = v[0 .. v.len - 1];
    return v;
}

// ---- tests: the parser is pure over byte chunks, so it tests without any network ----

test "sse deltas accumulate across split chunks and [DONE] completes" {
    const gpa = std.testing.allocator;
    var s: Stream = .{};
    defer s.deinit(gpa);
    s.started_s = 0;
    consume(&s, gpa, "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"cont");
    try std.testing.expectEqualStrings("Hel", s.content.items);
    consume(&s, gpa, "ent\":\"lo \\u2014 world\"}}]}\n\ndata: [DONE]\n");
    try std.testing.expect(s.done);
    try std.testing.expect(!s.failed);
    try std.testing.expectEqualStrings("Hello \xe2\x80\x94 world", s.content.items);
}

test "sse error body fails the stream with the message" {
    const gpa = std.testing.allocator;
    var s: Stream = .{};
    defer s.deinit(gpa);
    consume(&s, gpa, "data: {\"error\":{\"message\":\"invalid api key\",\"code\":401}}\n");
    try std.testing.expect(s.done and s.failed);
    try std.testing.expectEqualStrings("invalid api key", s.errStr());
}

test "whole-json fallback needs a terminal key and extracts content" {
    const gpa = std.testing.allocator;
    var s: Stream = .{};
    defer s.deinit(gpa);
    s.saw_any = true;
    s.saw_sse = false;
    tryWholeJson(&s, gpa, "{\"choices\":[{\"message\":{\"content\":\"partial\"}}"); // no close/terminal
    try std.testing.expect(!s.done);
    tryWholeJson(&s, gpa, "{\"choices\":[{\"message\":{\"content\":\"full answer\"},\"finish_reason\":\"stop\"}],\"usage\":{}}");
    try std.testing.expect(s.done and !s.failed);
    try std.testing.expectEqualStrings("full answer", s.content.items);
}

test "unescape handles quotes, newlines and surrogate pairs" {
    const gpa = std.testing.allocator;
    const got = jsonUnescape(gpa, "{\"content\":\"a \\\"q\\\" b\\nc \\ud83d\\ude00\"}", "content").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a \"q\" b\nc \xf0\x9f\x98\x80", got);
}
