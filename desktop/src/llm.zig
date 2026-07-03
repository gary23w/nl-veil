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

// curl appends this + the 3-digit HTTP code to the stream file after the transfer ends (even on a failed
// connect, where the code is 000). It is our only observable "curl exited" signal — Child has no
// non-blocking wait — and lets poll() distinguish a dead endpoint / HTTP error from a slow-but-alive one
// in a single tick instead of blindly waiting out the first-byte ceiling.
const STAT_MARK = "\n__VEILSTAT__";

pub const Stream = struct {
    child: ?std.process.Child = null,
    out_path: [300]u8 = [_]u8{0} ** 300,
    out_path_len: u16 = 0,
    offset: usize = 0, // bytes of the stream file already consumed
    carry: std.ArrayListUnmanaged(u8) = .empty, // partial trailing line held between polls (grows as needed)
    native: bool = false, // Ollama native /api/chat (NDJSON lines), not OpenAI SSE
    saw_sse: bool = false, // first chunk decided: SSE stream vs plain JSON body
    saw_any: bool = false,
    done: bool = false,
    failed: bool = false,
    err: [200]u8 = [_]u8{0} ** 200,
    err_len: u8 = 0,
    content: std.ArrayListUnmanaged(u8) = .empty, // accumulated assistant text (gpa-owned)
    reasoning: std.ArrayListUnmanaged(u8) = .empty, // the model's thinking channel (reasoning models)
    started_s: i64 = 0,
    last_growth_s: i64 = 0,

    pub fn errStr(s: *const Stream) []const u8 {
        return s.err[0..s.err_len];
    }
    pub fn reasoningStr(s: *const Stream) []const u8 {
        return s.reasoning.items;
    }
    pub fn outPath(s: *const Stream) []const u8 {
        return s.out_path[0..s.out_path_len];
    }
    pub fn deinit(s: *Stream, gpa: std.mem.Allocator) void {
        s.content.deinit(gpa);
        s.reasoning.deinit(gpa);
        s.carry.deinit(gpa);
        s.* = .{};
    }
};

// Generous by design: a cold local 20B takes >1min to load, reasoning models think in long silent
// gaps between deltas, and while a cast is running the chat call sits in the SAME local backend queue
// behind the swarm's generations (measured minutes on one GPU). Failing fast here read as "the model
// fails after a while" — the honest behavior is a long leash + a live status line, not an error.
const FIRST_BYTE_TIMEOUT_S = 300;
const FIRST_BYTE_PATIENT_S = 900; // while a cast runs: queued-behind-the-hive is normal, not a failure
const STALL_TIMEOUT_S = 300;
const TOTAL_TIMEOUT_S = 900;

// MUST equal the engine's NATIVE_CTX (src/worker/llm.zig). In Ollama a different num_ctx is a different
// runner: without parity every chat↔swarm alternation forces a full model reload (measured tens of
// seconds on a 20B), starving the chat AND slowing the cast. Same ctx → one shared runner, plain queueing.
const OLLAMA_NUM_CTX: u32 = 32768;
const OLLAMA_NUM_PREDICT: u32 = 8192; // room for hidden reasoning + the answer on thinking models

fn isLocalOllama(u: []const u8) bool {
    const local = std.mem.indexOf(u8, u, "127.0.0.1") != null or std.mem.indexOf(u8, u, "localhost") != null;
    return local and std.mem.indexOf(u8, u, "11434") != null;
}

/// ".../v1" (any trailing slashes) → the server root, for native endpoint building.
fn ollamaRoot(u: []const u8) []const u8 {
    var v = trimSlash(u);
    if (std.mem.endsWith(u8, v, "/v1")) v = v[0 .. v.len - 3];
    return trimSlash(v);
}

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
    const native = isLocalOllama(prov.base_url);
    s.* = .{ .started_s = now_s, .last_growth_s = now_s, .native = native };

    const url = if (native)
        std.fmt.allocPrint(gpa, "{s}/api/chat", .{ollamaRoot(prov.base_url)}) catch return false
    else
        std.fmt.allocPrint(gpa, "{s}/chat/completions", .{trimSlash(prov.base_url)}) catch return false;
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

    // Local Ollama uses the NATIVE /api/chat, STREAMING (NDJSON) so the reply types out token-by-token
    // and the reasoning shows line-by-line. Reasoning models (gpt-oss) sometimes route a reply through
    // Ollama's harmony "commentary" channel, which its incremental tool-call parser then chokes on
    // ("error parsing tool call: ... 'C'"); handleStreamLine RECOVERS the raw text from that error rather
    // than failing. num_ctx matches the engine so chat + swarm share one runner (no reload thrash).
    const body = if (native)
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":true,\"options\":{{\"num_ctx\":{d},\"num_predict\":{d}}}}}", .{ prov.model, messages_json, OLLAMA_NUM_CTX, OLLAMA_NUM_PREDICT }) catch return false
    else
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":true,\"max_tokens\":{d}}}", .{ prov.model, messages_json, max_tokens }) catch return false;
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
    const tt = std.fmt.bufPrint(&tt_buf, "{d}", .{TOTAL_TIMEOUT_S}) catch "900";
    // The stream sink (curl's stdout). createFile(truncate) clears any prior turn's stream — the
    // stale-replay guard is now a truncation we own, not a swallowed deleteFile. Created last so no
    // earlier error path leaks the handle.
    var sink = Io.Dir.cwd().createFile(io, outpath, .{ .truncate = true }) catch |e| {
        log.err("chat llm: cannot create stream sink: {t}", .{e});
        return false;
    };
    // -w appends STAT_MARK + the HTTP code after the transfer (000 on a failed connect) so poll() can see
    // curl exit; --connect-timeout bounds a black-hole endpoint even when nothing is listening slowly.
    const argv: []const []const u8 = &.{ "curl", "-sS", "-N", "--connect-timeout", "20", "--max-time", tt, "-K", cfgpath, "--data-binary", data_at, "-w", STAT_MARK ++ "%{http_code}", url };
    s.child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = sink },
        .stderr = .ignore,
        .create_no_window = true,
    }) catch |e| {
        sink.close(io);
        log.err("chat llm: curl spawn failed: {t}", .{e});
        return false;
    };
    sink.close(io); // curl holds its own inherited handle; we read the file back independently
    log.info("chat llm: -> {s} model={s} native={} body={d}b key={d}b", .{ url, prov.model, native, body.len, prov.key.len });
    return true;
}

/// Tail the stream file: consume any new bytes, folding deltas into s.content. Call ~10x/sec while a turn
/// is in flight; `s.done` flips when the reply is complete (or failed — check s.failed / errStr()).
/// `patient` = a cast is running on the same backend, so a long silent wait is queueing, not death.
pub fn poll(s: *Stream, io: Io, gpa: std.mem.Allocator, now_s: i64, patient: bool) void {
    if (s.done) return;
    const data = Io.Dir.cwd().readFileAlloc(io, s.outPath(), gpa, .limited(8 << 20)) catch {
        // file not created yet — curl still connecting (or it died before writing)
        checkTimeouts(s, io, now_s, patient);
        return;
    };
    defer gpa.free(data);

    // curl appends STAT_MARK + a 3-digit HTTP code once the transfer ends. Split it off so it never
    // reaches the line parser, and use it as the "curl exited" signal. A partial marker (split across
    // polls) simply isn't matched yet — we act only once the full 3-digit code is present.
    var body = data;
    var stat: ?[]const u8 = null;
    if (std.mem.lastIndexOf(u8, data, STAT_MARK)) |m| {
        const after = data[m + STAT_MARK.len ..];
        if (after.len >= 3) {
            body = data[0..m];
            stat = after[0..3];
        }
    }

    if (body.len > s.offset) {
        consume(s, gpa, body[s.offset..]);
        s.offset = body.len;
        s.last_growth_s = now_s;
    } else if (stat == null and s.saw_any and !s.saw_sse and !s.native) {
        // plain-JSON body (backend ignored stream:true): complete once the object closes + carries a
        // terminal key — brace-end alone can be a partial write.
        tryWholeJson(s, gpa, body);
        if (!s.done) checkTimeouts(s, io, now_s, patient);
        return;
    }
    if (s.done) return;

    // curl has EXITED — resolve from the HTTP code now instead of waiting out the first-byte ceiling.
    // This is what turns a typo'd endpoint / dead port / HTML 502 from a 5–15 minute blind wait into an
    // immediate, accurate error. Native uses the ollama-aware finish (content+thinking+recovery backstop).
    if (stat) |code| {
        if (s.native) finishNativeWhole(s, io, gpa, code, body) else finishBySentinel(s, io, gpa, code, body);
        return;
    }
    checkTimeouts(s, io, now_s, patient);
}

/// Ollama non-streaming: parse the one complete response object. Extracts message.content (the answer)
/// and message.thinking (the reasoning), and RECOVERS the model's text when Ollama's gpt-oss harmony
/// parser fails with "error parsing tool call: raw='...'" — that raw IS the intended reply.
fn finishNativeWhole(s: *Stream, io: Io, gpa: std.mem.Allocator, code: []const u8, body: []const u8) void {
    abort(s, io); // reap the (already-exited) child
    if (s.done) return;
    // Ollama surfaces server-side failures as a top-level {"error":"..."}.
    if (jsonUnescape(gpa, body, "error")) |emsg| {
        defer gpa.free(emsg);
        if (recoverToolCallRaw(emsg)) |raw| {
            s.content.appendSlice(gpa, raw) catch {};
            s.done = true;
            return;
        }
        var eb: [200]u8 = undefined;
        const n = @min(emsg.len, eb.len);
        @memcpy(eb[0..n], emsg[0..n]);
        setErr(s, eb[0..n]);
        return;
    }
    // Backstop only — streaming already accumulated content/thinking via handleStreamLine. Extract from
    // the whole body ONLY if nothing streamed (e.g. done:true never arrived), so we never duplicate a
    // delta already in the buffer. On a normal stream, s.content is non-empty here and we just complete.
    if (s.content.items.len == 0 and s.reasoning.items.len == 0) {
        if (jsonUnescape(gpa, body, "thinking")) |th| {
            defer gpa.free(th);
            s.reasoning.appendSlice(gpa, th) catch {};
        }
        if (jsonUnescape(gpa, body, "content")) |c| {
            defer gpa.free(c);
            s.content.appendSlice(gpa, c) catch {};
        }
    }
    if (s.content.items.len > 0 or s.reasoning.items.len > 0) {
        s.done = true;
        return;
    }
    // no content, no thinking, no error — fall back to the HTTP code
    if (std.mem.eql(u8, code, "000")) {
        setErr(s, "could not reach the model endpoint — is Ollama running?");
    } else if (code.len > 0 and code[0] != '2') {
        var eb: [200]u8 = undefined;
        setErr(s, std.fmt.bufPrint(&eb, "Ollama returned HTTP {s}: {s}", .{ code, errBodyHead(body) }) catch "Ollama error");
    } else {
        setErr(s, "the model returned an empty response");
    }
}

/// From an Ollama "error parsing tool call: raw='<text>', err=..." message, recover the `<text>` — that is
/// the model's actual output that the harmony tool-call parser choked on. Returns null if not that error.
fn recoverToolCallRaw(emsg: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, emsg, "parsing tool call") == null) return null;
    const key = "raw='";
    const at = std.mem.indexOf(u8, emsg, key) orelse return null;
    const from = at + key.len;
    if (from > emsg.len) return null;
    const tail = emsg[from..];
    // the raw is terminated by "', err=" (preferred) or the last single-quote
    const end = std.mem.indexOf(u8, tail, "', err=") orelse (std.mem.lastIndexOfScalar(u8, tail, '\'') orelse tail.len);
    return tail[0..end];
}

var body_head_buf: [160]u8 = undefined;
/// A one-line, printable head of an error body (HTML page / JSON error) for the user-facing message.
fn errBodyHead(body: []const u8) []const u8 {
    const t = std.mem.trim(u8, body, " \r\n\t");
    var w: usize = 0;
    var i: usize = 0;
    while (i < t.len and w < body_head_buf.len) : (i += 1) {
        const c = t[i];
        body_head_buf[w] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
        w += 1;
    }
    return body_head_buf[0..w];
}

/// curl has exited (its STAT sentinel is on disk). Reap it and decide the turn's outcome from the HTTP
/// code + whatever body arrived. `code` is the 3-digit string ("000" on a failed connect).
fn finishBySentinel(s: *Stream, io: Io, gpa: std.mem.Allocator, code: []const u8, body: []const u8) void {
    abort(s, io); // reap the (already-exited) child
    if (s.done) return;
    // If the framed parse produced nothing, try a direct whole-body content extraction — a backend that
    // answered as one non-stream JSON object despite stream:true. curl is done, so the body is complete.
    if (s.content.items.len == 0) {
        if (jsonUnescape(gpa, body, "content")) |piece| {
            defer gpa.free(piece);
            s.content.appendSlice(gpa, piece) catch {};
        }
    }
    if ((code.len > 0 and code[0] == '2') or s.content.items.len > 0) {
        if (s.content.items.len > 0) {
            s.done = true;
        } else {
            setErr(s, "the model endpoint returned an empty response");
        }
        return;
    }
    if (std.mem.eql(u8, code, "000")) {
        setErr(s, "could not reach the model endpoint — check the provider URL, port, and API key");
        return;
    }
    var eb: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&eb, "model endpoint error (HTTP {s}): {s}", .{ code, errBodyHead(body) }) catch
        (std.fmt.bufPrint(&eb, "model endpoint error (HTTP {s})", .{code}) catch "model endpoint error");
    setErr(s, msg);
}

fn checkTimeouts(s: *Stream, io: Io, now_s: i64, patient: bool) void {
    const first_allow: i64 = if (patient) FIRST_BYTE_PATIENT_S else FIRST_BYTE_TIMEOUT_S;
    const first_to = !s.saw_any and now_s - s.started_s > first_allow;
    const stall_to = s.saw_any and now_s - s.last_growth_s > STALL_TIMEOUT_S;
    const total_to = now_s - s.started_s > TOTAL_TIMEOUT_S + 15;
    if (first_to or stall_to or total_to) {
        abort(s, io);
        var eb: [200]u8 = undefined;
        const msg = if (first_to)
            std.fmt.bufPrint(&eb, "no response from the model endpoint after {d}s — check the provider settings", .{now_s - s.started_s}) catch "no response from the model endpoint"
        else if (stall_to)
            std.fmt.bufPrint(&eb, "the model stream went silent for {d}s", .{now_s - s.last_growth_s}) catch "the model stream stalled"
        else
            std.fmt.bufPrint(&eb, "the reply exceeded the {d}s ceiling", .{@as(i64, TOTAL_TIMEOUT_S)}) catch "the reply took too long";
        setErr(s, msg);
    }
}

/// Feed newly-arrived bytes through the stream state machine. Two line-framed shapes (OpenAI SSE
/// "data: {...}" and Ollama-native NDJSON "{...}") plus a whole-JSON fallback for non-streaming bodies.
fn consume(s: *Stream, gpa: std.mem.Allocator, new_bytes: []const u8) void {
    if (!s.saw_any) {
        // decide the framing on the first non-whitespace bytes
        const t = std.mem.trimStart(u8, new_bytes, " \r\n\t");
        if (t.len == 0) return;
        s.saw_any = true;
        s.saw_sse = std.mem.startsWith(u8, t, "data:") or std.mem.startsWith(u8, t, "event:") or std.mem.startsWith(u8, t, ":");
    }
    if (!s.saw_sse and !s.native) {
        // non-streaming body: whole-file parse happens in poll(); here just note growth.
        return;
    }
    // line-framed (SSE or NDJSON): process complete lines; keep the trailing partial in `carry`. The
    // carry is a growable list, NOT a fixed buffer — a single delta line longer than any fixed cap (a
    // backend that flushes a big chunk, or the whole completion, as one event) would otherwise have its
    // tail dropped and splice a hole into the JSON, corrupting the reply. Growing avoids that entirely.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, s.carry.items) catch return;
    buf.appendSlice(gpa, new_bytes) catch return;
    var consumed: usize = 0;
    var rest: []const u8 = buf.items;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = std.mem.trimEnd(u8, rest[0..nl], "\r");
        consumed += nl + 1;
        rest = rest[nl + 1 ..];
        handleStreamLine(s, gpa, line);
        if (s.done) {
            s.carry.clearRetainingCapacity();
            return;
        }
    }
    s.carry.clearRetainingCapacity();
    s.carry.appendSlice(gpa, buf.items[consumed..]) catch {};
}

fn handleStreamLine(s: *Stream, gpa: std.mem.Allocator, line: []const u8) void {
    var payload: []const u8 = undefined;
    if (std.mem.startsWith(u8, line, "data:")) {
        payload = std.mem.trim(u8, line[5..], " ");
        if (payload.len == 0) return;
        if (std.mem.eql(u8, payload, "[DONE]")) {
            s.done = true;
            return;
        }
    } else if (s.native) {
        payload = std.mem.trim(u8, line, " ");
        if (payload.len == 0 or payload[0] != '{') return;
    } else return;

    // A gpt-oss harmony tool-call parse error ({"error":"error parsing tool call: raw='...'"}) carries the
    // model's real text — recover it (from the FULL, un-capped error string) instead of failing the turn.
    if (jsonUnescape(gpa, payload, "error")) |emsg| {
        defer gpa.free(emsg);
        if (recoverToolCallRaw(emsg)) |raw| {
            s.content.appendSlice(gpa, raw) catch {};
            s.done = true;
            return;
        }
        if (emsg.len > 0) {
            var mb: [200]u8 = undefined;
            const n = @min(emsg.len, mb.len);
            @memcpy(mb[0..n], emsg[0..n]);
            setErr(s, mb[0..n]);
            return;
        }
    }
    // nested error object (OpenAI-style {"error":{"message":...}})
    if (extractErr(payload)) |msg| {
        var mb: [200]u8 = undefined;
        const n = @min(msg.len, mb.len);
        @memcpy(mb[0..n], msg[0..n]);
        setErr(s, mb[0..n]);
        return;
    }
    // NDJSON reasoning deltas: {"message":{"thinking":"..."},...} while the model reasons (content empty).
    if (jsonUnescape(gpa, payload, "thinking")) |th| {
        defer gpa.free(th);
        s.reasoning.appendSlice(gpa, th) catch {};
    }
    // SSE: {"choices":[{"delta":{"content":"..."}}]} — role-only/finish chunks carry no content key.
    // NDJSON: {"message":{"role":"assistant","content":"..."},"done":false} … {"done":true,...} last.
    if (jsonUnescape(gpa, payload, "content")) |piece| {
        defer gpa.free(piece);
        s.content.appendSlice(gpa, piece) catch {};
    }
    if (s.native and std.mem.indexOf(u8, payload, "\"done\":true") != null) s.done = true;
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

/// A real error only. Shapes: {"error":null} (healthy — many OpenAI-compatible stacks include this on
/// SUCCESS), {"error":"msg"}, {"error":{"message":"..."}}. Keys the decision on the VALUE after
/// `"error":`, not the mere presence of the substring — so a healthy reply carrying "error":null is not
/// wrongly failed. Returns the message, or null when it is not an actual error.
var err_scratch: [200]u8 = undefined;
fn extractErr(obj: []const u8) ?[]const u8 {
    const needle = "\"error\":";
    const ei = std.mem.indexOf(u8, obj, needle) orelse return null;
    var i = ei + needle.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
    if (i >= obj.len) return null;
    switch (obj[i]) {
        'n' => return null, // "error":null → not an error
        '"' => { // "error":"message string"
            i += 1;
            var w: usize = 0;
            while (i < obj.len and obj[i] != '"' and w < err_scratch.len) : (i += 1) {
                if (obj[i] == '\\') {
                    i += 1;
                    if (i >= obj.len) break;
                }
                err_scratch[w] = obj[i];
                w += 1;
            }
            if (w == 0) return null; // "error":"" → empty, treat as non-error
            return err_scratch[0..w];
        },
        '{' => { // "error":{"message":"..."}
            if (jsonStrInto(obj[i..], "message", &err_scratch)) |m| {
                if (m.len > 0) return m;
            }
            return "model endpoint returned an error";
        },
        else => return null, // number / array / unexpected → not a surfaced string error
    }
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

/// Reap the child after a completion. `done` already means the content is complete, so we KILL rather
/// than wait(): a blocking wait would hang the whole chat thread (up to the --max-time ceiling) if the
/// endpoint holds the SSE connection open past its application-level [DONE] sentinel. kill() terminates
/// AND reaps in one idempotent call, so a normally-exited curl is just reaped and a lingering one is cut.
pub fn finish(s: *Stream, io: Io) void {
    if (s.child) |*c| {
        c.kill(io);
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

test "error:null is NOT treated as a failure (healthy replies pass through)" {
    const gpa = std.testing.allocator;
    // delta chunk carrying a benign error:null must still yield content, not abort
    var s: Stream = .{};
    defer s.deinit(gpa);
    consume(&s, gpa, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"error\":null}\n\ndata: [DONE]\n");
    try std.testing.expect(s.done and !s.failed);
    try std.testing.expectEqualStrings("hi", s.content.items);
    // extractErr shapes
    try std.testing.expect(extractErr("{\"error\":null}") == null);
    try std.testing.expect(extractErr("{\"error\":\"\"}") == null);
    try std.testing.expect(extractErr("{\"ok\":true}") == null);
    try std.testing.expectEqualStrings("bad key", extractErr("{\"error\":\"bad key\"}").?);
    try std.testing.expectEqualStrings("rate limited", extractErr("{\"error\":{\"message\":\"rate limited\"}}").?);
}

test "a >carry-size single SSE line survives a poll-boundary split without splicing" {
    const gpa = std.testing.allocator;
    var s: Stream = .{};
    defer s.deinit(gpa);
    // build a content string far larger than any old fixed carry (16KB), delivered as one data: line
    // split across two consume() calls at an arbitrary interior byte.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "data: {\"choices\":[{\"delta\":{\"content\":\"");
    var i: usize = 0;
    while (i < 40000) : (i += 1) try big.append(gpa, 'x');
    try big.appendSlice(gpa, "\"}}]}\n");
    const split = 5000; // mid-line
    consume(&s, gpa, big.items[0..split]);
    try std.testing.expect(s.content.items.len == 0); // line not yet complete
    consume(&s, gpa, big.items[split..]);
    try std.testing.expectEqual(@as(usize, 40000), s.content.items.len);
    for (s.content.items) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
}

test "finishBySentinel maps HTTP codes: 000 unreachable, 4xx error, 200 graceful" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // 000 — connect failed, no body
    {
        var s: Stream = .{};
        defer s.deinit(gpa);
        finishBySentinel(&s, io, gpa, "000", "");
        try std.testing.expect(s.failed);
        try std.testing.expect(std.mem.indexOf(u8, s.errStr(), "could not reach") != null);
    }
    // 404 — HTML error body surfaced
    {
        var s: Stream = .{};
        defer s.deinit(gpa);
        finishBySentinel(&s, io, gpa, "404", "404 page not found");
        try std.testing.expect(s.failed);
        try std.testing.expect(std.mem.indexOf(u8, s.errStr(), "404") != null);
    }
    // 200 with a non-stream JSON body — content extracted, graceful done
    {
        var s: Stream = .{};
        defer s.deinit(gpa);
        finishBySentinel(&s, io, gpa, "200", "{\"choices\":[{\"message\":{\"content\":\"final\"}}]}");
        try std.testing.expect(s.done and !s.failed);
        try std.testing.expectEqualStrings("final", s.content.items);
    }
}

test "native STREAMING NDJSON accumulates thinking then content, done:true completes" {
    const gpa = std.testing.allocator;
    var s: Stream = .{ .native = true };
    defer s.deinit(gpa);
    // reasoning deltas first (content empty), then the answer deltas, then the terminal line
    consume(&s, gpa, "{\"message\":{\"role\":\"assistant\",\"thinking\":\"Let me \",\"content\":\"\"},\"done\":false}\n");
    consume(&s, gpa, "{\"message\":{\"thinking\":\"think.\",\"content\":\"\"},\"done\":false}\n");
    try std.testing.expectEqualStrings("Let me think.", s.reasoningStr());
    try std.testing.expectEqualStrings("", s.content.items);
    consume(&s, gpa, "{\"message\":{\"thinking\":\"\",\"content\":\"Hi \"},\"done\":false}\n{\"message\":{\"content\":\"there\"},\"done\":true}\n");
    try std.testing.expect(s.done and !s.failed);
    try std.testing.expectEqualStrings("Hi there", s.content.items);
    try std.testing.expectEqualStrings("Let me think.", s.reasoningStr());
}

test "native STREAMING recovers a mid-stream tool-call error into content (uncapped)" {
    const gpa = std.testing.allocator;
    var s: Stream = .{ .native = true };
    defer s.deinit(gpa);
    // Ollama emits the harmony parse error as one NDJSON line; the raw is the model's real reply
    consume(&s, gpa, "{\"error\":\"error parsing tool call: raw='CAST: Search the web for the most recent global news stories and summarize the top items', err=invalid character 'C' looking for beginning of value\"}\n");
    try std.testing.expect(s.done and !s.failed);
    try std.testing.expectEqualStrings("CAST: Search the web for the most recent global news stories and summarize the top items", s.content.items);
}

test "native whole-object parse: content + thinking (reasoning)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s: Stream = .{ .native = true };
    defer s.deinit(gpa);
    finishNativeWhole(&s, io, gpa, "200", "{\"model\":\"gpt-oss:20b\",\"message\":{\"role\":\"assistant\",\"content\":\"The answer is 42.\",\"thinking\":\"User asks a question; compute it.\"},\"done\":true}");
    try std.testing.expect(s.done and !s.failed);
    try std.testing.expectEqualStrings("The answer is 42.", s.content.items);
    try std.testing.expectEqualStrings("User asks a question; compute it.", s.reasoningStr());
}

test "native recovers the raw text from a gpt-oss tool-call parse error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s: Stream = .{ .native = true };
    defer s.deinit(gpa);
    // Ollama's exact failure shape (with JSON-escaped newlines in the raw)
    finishNativeWhole(&s, io, gpa, "200", "{\"error\":\"error parsing tool call: raw='CAST: Gather current global news\\n\\nWant a summary?', err=invalid character 'C' looking for beginning of value\"}");
    try std.testing.expect(s.done and !s.failed);
    try std.testing.expectEqualStrings("CAST: Gather current global news\n\nWant a summary?", s.content.items);
    // recoverToolCallRaw only fires on that error, not arbitrary ones
    try std.testing.expect(recoverToolCallRaw("some other error") == null);
}

test "ollama root + local detection for native routing" {
    try std.testing.expect(isLocalOllama("http://127.0.0.1:11434/v1"));
    try std.testing.expect(isLocalOllama("http://localhost:11434/v1/"));
    try std.testing.expect(!isLocalOllama("https://api.openai.com/v1"));
    try std.testing.expectEqualStrings("http://127.0.0.1:11434", ollamaRoot("http://127.0.0.1:11434/v1/"));
    try std.testing.expectEqualStrings("http://127.0.0.1:11434", ollamaRoot("http://127.0.0.1:11434"));
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
