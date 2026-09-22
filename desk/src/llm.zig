//! llm.zig — the desktop's chat-model client. ONE interface (base_url + key + model, OpenAI-compatible
//! /chat/completions) behind which every provider plugs: local Ollama, a BYOK cloud provider, or a custom
//! endpoint URL. Transport mirrors the engine's convention (src/worker/llm.zig): the key rides in the curl
//! config curl reads from its stdin (`-K -`), so it is never on the argv and never on disk, the body in a
//! request file, and curl does the HTTP — TLS for hosted providers without betting on std.http in this Zig.
//! Streaming is filesystem-first: curl -N writes the SSE stream to a scratch file and the chat thread TAILS
//! it, appending deltas to the Store. Runs on the CHAT thread only.

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
// connect, where the code is 000). It lets poll() distinguish a dead endpoint / HTTP error from a slow-but-alive
// one in a single tick instead of blindly waiting out the first-byte ceiling. A curl that exits without writing
// it (one that fails before its transfer, or is killed) poll() learns of from curlExited instead.
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
    /// Frees the buffers and resets the Stream. End the call first (finish/abort): this has no io, so a
    /// curl still running here keeps going, writing into the sink.
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
/// How far past TOTAL_TIMEOUT_S (curl's own --max-time) checkTimeouts lets a call run before it ends the call itself.
const TOTAL_TIMEOUT_SLACK_S = 15;

// ---- the API key ----

/// The most config bytes a call hands curl (keyToCurl). A child's stdin pipe holds that many with no reader: Zig 0.16
/// creates the Windows pipe with a 4096-byte quota, and a Linux pipe holds 64 KB. So start() hands curl its key without
/// ever waiting on it, however slow curl is to start, and even if it dies before it reads (measured 2026-09-17: 4096
/// bytes into a suspended child returned in 0 ms; 4097 waited for the child to read). The chat thread must never
/// block. A config is two header lines around the key, so only a key over ~4 KB is refused.
const KEY_CFG_MAX = 4096;

// The four below MIRROR src/worker/llm.zig's strayCfgByte / cfgHeader / cfgEscape / chatCfg — the desk is its own
// module and shares no source with the server, as KEY_CFG_MAX and keyToCurl above already do. A fix to either copy
// belongs in both.

/// Where `value` holds a byte a curl config value cannot carry, and which byte: `at` is its index. Enough for a message
/// that tells the user where to look without quoting any of the key (chat.zig), and the shape gitvc's strayTokenByte
/// answers a GitHub token in.
pub const StrayCfgByte = struct { at: usize, byte: u8 };

/// The first byte of `value` that a curl config value cannot carry — below 0x20, or DEL — or null when every byte can.
/// curl puts a header value on the wire as it reads it, so a line break would split the header, and NUL or 0x1A would
/// cut the config short whatever the escaping (cfgEscape). Every other byte rides escaped, which is the shape an API
/// key needs: keys are not one charset (`sk-…`, `hf_…`, a custom URL's own), so an allowlist would refuse real ones.
/// pub: chat.zig refuses such a key at the Settings pane too, rather than saving one every call then refuses.
pub fn strayCfgByte(value: []const u8) ?StrayCfgByte {
    for (value, 0..) |c, i| if (c < 0x20 or c == 0x7F) return .{ .at = i, .byte = c };
    return null;
}

/// Append `header = "<name><value>"` to a curl config. False, with nothing appended, for a value holding a byte
/// strayCfgByte refuses.
///
/// THE REFUSAL is what stops a value adding an option, and the escaping is what keeps the value well formed. curl's
/// config is line-oriented, so only a line feed or CR can begin a line of its own, and strayCfgByte has already
/// refused both by the time cfgEscape runs. What escaping the rest buys is a value that survives as itself: an
/// unescaped `"` would end this value early and leave the rest of it as a bare word on the same line, which curl
/// rejects or folds into the header — a malformed request, not an injected one.
fn cfgHeader(gpa: std.mem.Allocator, cfg: *std.ArrayListUnmanaged(u8), comptime name: []const u8, value: []const u8) error{OutOfMemory}!bool {
    if (strayCfgByte(value) != null) return false;
    try cfg.appendSlice(gpa, "header = \"" ++ name);
    try cfgEscape(gpa, cfg, value);
    try cfg.appendSlice(gpa, "\"\n");
    return true;
}

/// `value` as the inside of a quoted curl config value, the way curl's config reader unquotes it: `\\` and `\"` for
/// themselves, `\t` `\n` `\r` `\v` for tab, line feed, CR and VT. The escapes keep a value ONE value. A raw `"` ends
/// it, and a raw line feed ends the line, after which curl reads the rest as more options: a value could add a header,
/// or a second URL, and curl dials that URL with this config's bearer too (measured on curl 8.5, 8.17 and 8.21). NUL
/// and 0x1A have no escape: curl stops reading a line at NUL, and on Windows it reads its config in text mode, where
/// 0x1A ends it. cfgHeader refuses both.
fn cfgEscape(gpa: std.mem.Allocator, cfg: *std.ArrayListUnmanaged(u8), value: []const u8) error{OutOfMemory}!void {
    for (value) |c| switch (c) {
        '\\' => try cfg.appendSlice(gpa, "\\\\"),
        '"' => try cfg.appendSlice(gpa, "\\\""),
        '\t' => try cfg.appendSlice(gpa, "\\t"),
        '\n' => try cfg.appendSlice(gpa, "\\n"),
        '\r' => try cfg.appendSlice(gpa, "\\r"),
        0x0B => try cfg.appendSlice(gpa, "\\v"),
        // every other byte reads back as itself: the rest of the range below 0x20, and 0x7F-0xFF (all three curls)
        else => try cfg.append(gpa, c),
    };
}

/// The config a chat call hands curl over its stdin (keyToCurl): the bearer, when there is a key, escaped so the KEY
/// STAYS ONE HEADER VALUE, and the JSON content type. `error.StrayKeyByte` for a key cfgHeader refuses — unescaped, a
/// `"` in a key would end the value and a line feed the line, and curl would read the rest of the key as more options:
/// a second `url =`, which it dials carrying this bearer, or a `data-binary = "@<path>"`, which uploads that file. The
/// key comes from the user (the Settings pane's Save, `::key`) and nothing else holds it to a charset. Caller frees.
fn chatCfg(gpa: std.mem.Allocator, key: []const u8) error{ OutOfMemory, StrayKeyByte }![]u8 {
    var cfg: std.ArrayListUnmanaged(u8) = .empty;
    errdefer cfg.deinit(gpa);
    if (key.len > 0) {
        if (!try cfgHeader(gpa, &cfg, "Authorization: Bearer ", key)) return error.StrayKeyByte;
    }
    try cfg.appendSlice(gpa, "header = \"Content-Type: application/json\"\n");
    return cfg.toOwnedSlice(gpa);
}

/// Hand a spawned curl its config (`header = "Authorization: Bearer <key>"` ...) over stdin, `-K -` on its argv, and
/// close the pipe. The key never touches disk. A config FILE sat in the caller's scratch dir, inside the data dir: a
/// folder that is often synced, where a sync client could upload it while the call ran (a streamed call can run 15
/// minutes), and deleting a synced file sends the cloud copy to the recycle bin rather than removing it. curl reads
/// the config to EOF before it dials (curl 8.5, 8.17 and 8.21 all wait for the close), so the close is what starts the
/// call. `cfg` fits the pipe (KEY_CFG_MAX), so this never waits on curl. False when curl is already gone: the write
/// fails instead of blocking (PIPE_CLOSING on Windows; EPIPE on POSIX, where Io.Threaded's SIGPIPE handler turns the
/// signal into an error). The caller's reap then kills and reaps it.
fn keyToCurl(io: Io, child: *std.process.Child, cfg: []const u8) bool {
    std.debug.assert(cfg.len <= KEY_CFG_MAX);
    const pipe = child.stdin orelse return false;
    child.stdin = null; // closed here, so Child.kill never closes it a second time
    defer pipe.close(io);
    pipe.writeStreamingAll(io, cfg) catch return false;
    return true;
}

/// The name curl configs had on disk in the builds that handed curl its key in a FILE. Builds before 2026-09-17
/// wrote exactly this name, one per scratch dir, and never deleted it. The builds after them named one per call
/// (`-{16 hex}`) and deleted it when the call ended, so only a desk killed mid-call left one. No build since writes
/// a config (keyToCurl); the chat thread's key sweep removes the ones those builds left.
const KEY_CFG = ".chatcurlcfg";

/// Whether a file `name` is a curl config an older desk build wrote: a call's own, or the one fixed name.
pub fn isKeyCfgName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, KEY_CFG)) return false;
    return name.len == KEY_CFG.len or name[KEY_CFG.len] == '-';
}

/// How long after its last write a curl config counts as stranded (sweepKeyCfgs). A config lived as long as its
/// call, and checkTimeouts ends every call by TOTAL_TIMEOUT_S + TOTAL_TIMEOUT_SLACK_S, so an older one was left by a
/// desk that died mid-call, or by a build before 2026-09-17. A younger one may belong to a live call of an older desk
/// build on the same data dir, whose curl has not read it yet, and a sweep must never take that one.
pub const KEY_CFG_STALE_S: i64 = 20 * 60;

/// Remove the stranded curl configs at the top level of `dir_path`: files isKeyCfgName names that were last
/// written more than KEY_CFG_STALE_S before `now_ns`. Nothing below the top level is read. Returns how many it
/// removed.
pub fn sweepKeyCfgs(io: Io, gpa: std.mem.Allocator, dir_path: []const u8, now_ns: i96) usize {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    // Names first, THEN deletes: a dir changed mid-iteration can skip an entry.
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        // Anything but a dir. Zig lists every Windows reparse point as a symlink, and a synced folder's
        // placeholder file can be one.
        if (ent.kind == .directory or !isKeyCfgName(ent.name)) continue;
        const dup = gpa.dupe(u8, ent.name) catch continue;
        names.append(gpa, dup) catch {
            gpa.free(dup);
            continue;
        };
    }
    const stale_ns = @as(i96, KEY_CFG_STALE_S) * std.time.ns_per_s;
    var removed: usize = 0;
    for (names.items) |n| {
        const st = dir.statFile(io, n, .{ .follow_symlinks = false }) catch continue;
        if (now_ns - st.mtime.nanoseconds <= stale_ns) continue;
        dir.deleteFile(io, n) catch continue;
        removed += 1;
    }
    return removed;
}

/// The program start() runs. TEST ONLY: under `zig build test` start() runs `test_curl` instead, so a test can
/// name a program no PATH holds and reach the exit where curl never launches. A shipped build always runs CURL.
const CURL = "curl";
var test_curl: []const u8 = CURL;

/// TEST ONLY: start() runs this right before it spawns curl, once the request body and the stream sink are on disk.
/// A test can take the body away there, so curl fails at startup: exit 26, and nothing on its stdout, not even -w's
/// end marker. A shipped build never reads it.
var test_before_curl: ?*const fn () void = null;

// MUST equal the engine's NATIVE_CTX (src/worker/llm.zig). In Ollama a different num_ctx is a different
// runner: without parity every chat↔swarm alternation forces a full model reload (measured tens of
// seconds on a 20B), starving the chat AND slowing the cast. Same ctx → one shared runner, plain queueing.
const OLLAMA_NUM_CTX: u32 = 32768;
const OLLAMA_NUM_PREDICT: u32 = 8192; // room for hidden reasoning + the answer on thinking models
// Auto-unload idle local models. A partly-CPU model (gpt-oss:20b doesn't fully fit most GPUs) keeps
// Ollama's llama-server busy-spinning several cores WHILE LOADED — even when you're not using it. keep_alive
// resets on every request, so an active back-and-forth never reloads; only true idle (~2 min with no
// messages) releases the model and stops the spin. BYOK/cloud never loads a local model, so this is moot there.
const OLLAMA_KEEP_ALIVE = "2m";

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
    log.trace("llm.setErr {s}", .{msg});
    const n = @min(msg.len, s.err.len);
    @memcpy(s.err[0..n], msg[0..n]);
    s.err_len = @intCast(n);
    s.failed = true;
    s.done = true;
}

/// Kick off one streaming chat completion. `messages_json` is the inside of "messages":[ … ] (caller-built
/// and escaped). Scratch files live under `dir` (the .veil-desk sidecar). Returns false when the call cannot
/// start: a scratch file or the spawn failed, curl was gone before it read its config, or the key is one curl's
/// config cannot carry — a key holding a control byte (chatCfg) or one too long to hand curl (KEY_CFG_MAX).
pub fn start(s: *Stream, io: Io, gpa: std.mem.Allocator, dir: []const u8, prov: Provider, messages_json: []const u8, max_tokens: u32, now_s: i64) bool {
    log.trace("llm.start dir={s} model={s} msgs_len={d} max_tokens={d}", .{ dir, prov.model, messages_json.len, max_tokens });
    // ONE CALL PER STREAM. A start over a call that was never ended ends it here: its curl is killed and
    // reaped. Resetting the struct alone would drop that child, and its curl would write on into the sink this
    // call truncates below.
    reap(s, io);
    const native = isLocalOllama(prov.base_url);
    s.* = .{ .started_s = now_s, .last_growth_s = now_s, .native = native };

    // Engine convention: the key is never on the argv (visible in process lists), and it is never in a file either:
    // curl reads its config from stdin (keyToCurl). Built first, so a key curl's config cannot carry — one that could
    // add curl an option of its own (chatCfg), or one too long for the pipe — refuses the call before it writes a thing.
    const cfg = chatCfg(gpa, prov.key) catch |e| {
        // The reason, never the key: this line goes to the desk log.
        if (e == error.StrayKeyByte) log.err("chat llm: the API key holds a control byte, which a curl config value cannot carry — the call is refused", .{});
        return false;
    };
    defer gpa.free(cfg);
    if (cfg.len > KEY_CFG_MAX) {
        log.err("chat llm: the API key is too long to hand curl (a {d}-byte config; the pipe takes {d})", .{ cfg.len, KEY_CFG_MAX });
        return false;
    }

    const url = if (native)
        std.fmt.allocPrint(gpa, "{s}/api/chat", .{ollamaRoot(prov.base_url)}) catch return false
    else
        std.fmt.allocPrint(gpa, "{s}/chat/completions", .{trimSlash(prov.base_url)}) catch return false;
    defer gpa.free(url);
    const reqpath = std.fmt.allocPrint(gpa, "{s}/.chatreq.json", .{dir}) catch return false;
    defer gpa.free(reqpath);
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
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":true,\"keep_alive\":\"{s}\",\"options\":{{\"num_ctx\":{d},\"num_predict\":{d}}}}}", .{ prov.model, messages_json, OLLAMA_KEEP_ALIVE, OLLAMA_NUM_CTX, OLLAMA_NUM_PREDICT }) catch return false
    else
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":true,\"max_tokens\":{d}}}", .{ prov.model, messages_json, max_tokens }) catch return false;
    defer gpa.free(body);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = reqpath, .data = body }) catch {
        log.err("chat llm: cannot write request file", .{});
        return false;
    };

    const data_at = std.fmt.allocPrint(gpa, "@{s}", .{reqpath}) catch return false;
    defer gpa.free(data_at);
    var tt_buf: [16]u8 = undefined;
    const tt = std.fmt.bufPrint(&tt_buf, "{d}", .{TOTAL_TIMEOUT_S}) catch "900";
    // The stream sink (curl's stdout). createFile(truncate) clears any prior turn's stream (the
    // stale-replay guard). Closed on every return; curl holds its own inherited handle, and we read the file
    // back independently.
    var sink = Io.Dir.cwd().createFile(io, outpath, .{ .truncate = true }) catch |e| {
        log.err("chat llm: cannot create stream sink: {t}", .{e});
        return false;
    };
    defer sink.close(io);
    if (builtin.is_test) if (test_before_curl) |f| f();

    // -w appends STAT_MARK + the HTTP code after the transfer (000 on a failed connect) so poll() can see
    // curl exit; --connect-timeout bounds a black-hole endpoint even when nothing is listening slowly.
    const argv: []const []const u8 = &.{ if (builtin.is_test) test_curl else CURL, "-sS", "-N", "--connect-timeout", "20", "--max-time", tt, "-K", "-", "--data-binary", data_at, "-w", STAT_MARK ++ "%{http_code}", url };
    s.child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .{ .file = sink },
        .stderr = .ignore,
        .create_no_window = true,
    }) catch |e| {
        log.err("chat llm: curl spawn failed: {t}", .{e});
        return false;
    };
    // curl waits on its stdin for the config before it dials, so this is what starts the call, and it returns at
    // once whatever curl does (KEY_CFG_MAX).
    if (!keyToCurl(io, &s.child.?, cfg)) {
        log.err("chat llm: curl exited before it read its config", .{});
        reap(s, io);
        return false;
    }
    log.info("chat llm: -> {s} model={s} native={} body={d}b key={d}b", .{ url, prov.model, native, body.len, prov.key.len });
    return true;
}

const winproc = if (builtin.os.tag == .windows) struct {
    const STILL_ACTIVE: u32 = 259;
    extern "kernel32" fn GetExitCodeProcess(h: *anyopaque, code: *u32) callconv(.c) c_int;
} else struct {};

/// Whether a call's curl has exited, asked without blocking: std.process has no non-blocking wait. `code` gets
/// curl's exit code when the OS reports one. The twin of chat.zig procExited and of the engine's curlExited
/// (src/worker/llm.zig).
///
/// Windows reads the exit code off the process handle and leaves the handle to Child.kill (reap), which reaps an
/// exited child as it always has. A failed read counts as still running, so poll() waits on the end marker and the
/// ceilings as before rather than cut a live reply short. POSIX can only tell by reaping (waitpid WNOHANG), and then
/// clears the Child the way Child.wait does, so reap()'s Child.kill returns at once. Left set, kill() would signal a
/// pid that is no longer this process's child: ESRCH, which std counts as a programmer bug and panics on in Debug.
fn curlExited(io: Io, child: *std.process.Child, code: *?u32) bool {
    const id = child.id orelse return true;
    if (builtin.os.tag == .windows) {
        var c: u32 = 0;
        if (winproc.GetExitCodeProcess(id, &c) == 0 or c == winproc.STILL_ACTIVE) return false;
        code.* = c;
        return true;
    } else {
        var status: c_int = 0;
        const r = std.c.waitpid(id, &status, std.c.W.NOHANG);
        if (r == 0) return false; // still running
        if (r < 0 and std.posix.errno(r) != .CHILD) return false; // interrupted: ask again next poll
        if (r > 0 and std.posix.W.IFEXITED(@bitCast(status))) code.* = std.posix.W.EXITSTATUS(@bitCast(status));
        for ([_]*?Io.File{ &child.stdin, &child.stdout, &child.stderr }) |pipe| {
            if (pipe.*) |f| f.close(io);
            pipe.* = null;
        }
        child.id = null;
        return true;
    }
}

/// curl has exited without writing its end marker, so nothing more will reach the sink: it failed before its transfer
/// (a request body it cannot open exits 26 with an empty stdout), or something outside the desk killed it. Ends the
/// call now, failed, instead of leaving it to a ceiling minutes later.
fn endCurlGone(s: *Stream, io: Io, exit_code: ?u32) void {
    log.warn("chat llm: curl exited without its end marker (exit {?d}, {d} bytes streamed)", .{ exit_code, s.offset });
    abort(s, io); // reap: on Windows the probe left the handle to Child.kill
    const when = if (s.saw_any) "partway through the reply" else "before the model endpoint answered";
    var eb: [200]u8 = undefined;
    const msg = if (exit_code) |c|
        std.fmt.bufPrint(&eb, "curl exited (code {d}) {s}", .{ c, when }) catch "curl exited early"
    else
        std.fmt.bufPrint(&eb, "curl stopped running {s}", .{when}) catch "curl stopped running";
    setErr(s, msg);
}

/// Tail the stream file: consume any new bytes, folding deltas into s.content. Call ~10x/sec while a turn
/// is in flight; `s.done` flips when the reply is complete (or failed — check s.failed / errStr()).
/// `patient` = a cast is running on the same backend, so a long silent wait is queueing, not death.
///
/// CURL'S EXIT ENDS THE CALL TOO, marker or not. A curl that exits without its end marker (it failed before its
/// transfer, or was killed) writes nothing more, and waiting on the marker alone held such a call for
/// FIRST_BYTE_TIMEOUT_S, FIRST_BYTE_PATIENT_S or STALL_TIMEOUT_S. So each poll asks curlExited BEFORE it reads: once
/// curl is gone, that read holds every byte curl wrote, and a read without the marker ends the call.
pub fn poll(s: *Stream, io: Io, gpa: std.mem.Allocator, now_s: i64, patient: bool) void {
    if (s.done) return;
    // Asked before the read, never after it (CURL'S EXIT above). A Stream with no Child has no curl to wait on.
    var exit_code: ?u32 = null;
    const curl_gone = if (s.child) |*c| curlExited(io, c, &exit_code) else true;
    const data = Io.Dir.cwd().readFileAlloc(io, s.outPath(), gpa, .limited(8 << 20)) catch |e| {
        // start() creates the sink before curl starts. With the sink gone and curl gone too, nothing will ever
        // write to it. Any other failed read (a sink too big to read whole) leaves the call to its ceilings.
        if (curl_gone and e == error.FileNotFound) {
            endCurlGone(s, io, exit_code);
            return;
        }
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
        if (s.done) return;
        if (curl_gone) endCurlGone(s, io, exit_code) else checkTimeouts(s, io, now_s, patient);
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
    // curl has exited WITHOUT the marker: this read was its last word.
    if (curl_gone) {
        endCurlGone(s, io, exit_code);
        return;
    }
    checkTimeouts(s, io, now_s, patient);
}

/// Ollama non-streaming: parse the one complete response object. Extracts message.content (the answer)
/// and message.thinking (the reasoning), and RECOVERS the model's text when Ollama's gpt-oss harmony
/// parser fails with "error parsing tool call: raw='...'" — that raw IS the intended reply.
fn finishNativeWhole(s: *Stream, io: Io, gpa: std.mem.Allocator, code: []const u8, body: []const u8) void {
    log.trace("llm.finishNativeWhole code={s} body_len={d}", .{ code, body.len });
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
    log.trace("llm.finishBySentinel code={s} body_len={d}", .{ code, body.len });
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
    if (s.reasoning.items.len == 0) {
        if (jsonUnescape(gpa, body, "reasoning_content") orelse jsonUnescape(gpa, body, "reasoning")) |th| {
            defer gpa.free(th);
            s.reasoning.appendSlice(gpa, th) catch {};
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
    const total_to = now_s - s.started_s > TOTAL_TIMEOUT_S + TOTAL_TIMEOUT_SLACK_S;
    if (first_to or stall_to or total_to) {
        log.trace("llm.checkTimeouts firing: first={} stall={} total={} elapsed_s={d}", .{ first_to, stall_to, total_to, now_s - s.started_s });
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
    } else if (jsonUnescape(gpa, payload, "reasoning_content")) |th| {
        // SSE reasoning deltas: {"delta":{"reasoning_content":"..."}} (DeepSeek-style) or
        // {"delta":{"reasoning":"..."}} (OpenRouter/HF-style). Same channel as NDJSON "thinking" — without
        // this, every non-Ollama backend silently DROPPED its reasoning stream (empty thinking preview,
        // empty reflect trace). The exact-key match ("reasoning":) can't false-fire on "reasoning_content".
        defer gpa.free(th);
        s.reasoning.appendSlice(gpa, th) catch {};
    } else if (jsonUnescape(gpa, payload, "reasoning")) |th| {
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
    if (jsonUnescape(gpa, t, "reasoning_content") orelse jsonUnescape(gpa, t, "reasoning")) |th| {
        defer gpa.free(th);
        s.reasoning.clearRetainingCapacity();
        s.reasoning.appendSlice(gpa, th) catch {};
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
    log.trace("llm.abort has_child={}", .{s.child != null});
    reap(s, io);
}

/// Reap the child after a completion. `done` already means the content is complete, so we KILL rather
/// than wait(): a blocking wait would hang the whole chat thread (up to the --max-time ceiling) if the
/// endpoint holds the SSE connection open past its application-level [DONE] sentinel. kill() terminates
/// AND reaps in one idempotent call, so a normally-exited curl is just reaped and a lingering one is cut.
pub fn finish(s: *Stream, io: Io) void {
    log.trace("llm.finish content_len={d} reasoning_len={d} failed={}", .{ s.content.items.len, s.reasoning.items.len, s.failed });
    reap(s, io);
}

/// End the call: kill and reap curl. Every way a call ends comes here (finish after [DONE] or an error line,
/// abort from poll's exit sentinel, a timeout, a Stop, desk shutdown, start over an unended call, and a start
/// whose curl never took its config). Nothing of the key is left to clean up: it only ever went to curl's stdin.
/// Idempotent.
fn reap(s: *Stream, io: Io) void {
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

// ---- a call's key never touches disk ----
//
// curl reads a desk call's key from its stdin (keyToCurl). The files a call does write, the request body and the
// stream sink, sit in a scratch dir inside the data dir, which is often a synced folder. A curl config FILE there
// held the key for the whole call (a streamed call can run 15 minutes), so a sync client could upload it mid-call, and
// deleting a synced file only moves the cloud copy to the recycle bin. Builds before 2026-09-17 never deleted theirs
// at all: a names-only listing of a live data dir found three, a month old. These tests drive the REAL curl child
// through start/poll/finish/abort against a stand-in on 127.0.0.1, look through the scratch dir while the call is in
// flight (MidCall), and read back every file the call left once it has ended.

/// The tests' waits: a plain-thread sleep that never parks on the Io runtime (see nap.zig).
const nap = @import("nap.zig");

/// Never a real credential; distinctive, so a byte search for it is exact.
const TEST_KEY = "nlk_desk-chat-scratch-test-key-4b1d-not-a-real-credential";
const TEST_MSGS = "{\"role\":\"user\",\"content\":\"hi\"}";
const TEST_SSE = "data: {\"choices\":[{\"delta\":{\"content\":\"streamed\"}}]}\n\ndata: [DONE]\n\n";
/// A clean streamed answer: "streamed", then [DONE].
const TEST_ANSWER = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\n\r\n{s}", .{ TEST_SSE.len, TEST_SSE });

/// TEST ONLY (pub for the poller's HTTP tests too). A model endpoint on 127.0.0.1, at a port the OS assigns (a fixed port is shared rather than exclusive
/// on Windows, and a wildcard listen raises a Windows Firewall prompt). It reads each request whole and keeps the
/// first, and runs `look` if it has one: the call is in flight, curl waiting on the reply. Then it answers `reply`
/// and closes, or, with `hold`, answers `reply` (often nothing) and holds the connection open until stop(): an
/// endpoint still working on the call.
pub const Standin = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,
    reply: []const u8,
    hold: bool,
    look: ?*const fn () void,
    closing: std.atomic.Value(bool),
    /// Requests read whole (and looked at) so far. The first is in `req` once this is 1, and nothing writes `req`
    /// after that.
    seen: std.atomic.Value(u32),
    req: [16 << 10]u8,
    req_len: usize,
    thread: std.Thread,

    /// Starts in place: the serve thread holds a pointer to the struct, so it must not be copied.
    pub fn start(sv: *Standin, io: Io, reply: []const u8, hold: bool) !void {
        return sv.startWatched(io, reply, hold, null);
    }

    /// `start`, with `look` run on the serve thread for each request between its arrival and the reply.
    fn startWatched(sv: *Standin, io: Io, reply: []const u8, hold: bool, look: ?*const fn () void) !void {
        const addr = Io.net.IpAddress{ .ip4 = .loopback(0) };
        sv.server = Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp }) catch return error.SkipZigTest; // no loopback listener on this box
        sv.io = io;
        sv.port = sv.server.socket.address.getPort();
        sv.reply = reply;
        sv.hold = hold;
        sv.look = look;
        sv.closing = .init(false);
        sv.seen = .init(0);
        sv.req_len = 0;
        sv.thread = std.Thread.spawn(.{}, serve, .{sv}) catch |e| {
            sv.server.deinit(io);
            return e;
        };
    }

    fn serve(sv: *Standin) void {
        while (true) {
            const conn = sv.server.accept(sv.io) catch return;
            defer conn.close(sv.io);
            if (sv.closing.load(.acquire)) return; // stop()'s wake-up dial
            const first = sv.seen.load(.acquire) == 0;
            var rbuf: [4 << 10]u8 = undefined;
            var rd = conn.reader(sv.io, &rbuf);
            var clen: usize = 0;
            while (true) {
                const line = (rd.interface.takeDelimiter('\n') catch break) orelse break;
                if (first) {
                    sv.keep(line);
                    sv.keep("\n");
                }
                if (contentLength(line)) |n| clen = n;
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            }
            if (clen > 0) {
                var body: [8 << 10]u8 = undefined;
                const n = @min(clen, body.len);
                if (rd.interface.readSliceAll(body[0..n])) {
                    if (first) sv.keep(body[0..n]);
                } else |_| {}
            }
            // Before `seen` counts it, so a test that awaits the request finds the look done too.
            if (sv.look) |f| f();
            _ = sv.seen.fetchAdd(1, .release);
            var wbuf: [8 << 10]u8 = undefined;
            var wr = conn.writer(sv.io, &wbuf);
            wr.interface.writeAll(sv.reply) catch {};
            wr.interface.flush() catch {};
            if (sv.hold) {
                while (!sv.closing.load(.acquire)) nap.ms(5);
                return;
            }
        }
    }

    fn keep(sv: *Standin, bytes: []const u8) void {
        const n = @min(bytes.len, sv.req.len - sv.req_len);
        @memcpy(sv.req[sv.req_len..][0..n], bytes[0..n]);
        sv.req_len += n;
    }

    /// Waits up to ~30 s for `n` requests to arrive whole: a curl that read its config and sent its call.
    pub fn awaitSeen(sv: *const Standin, n: u32) !void {
        var waited: u32 = 0;
        while (sv.seen.load(.acquire) < n) : (waited += 1) {
            if (waited >= 3000) return error.StandinNeverCalled;
            nap.ms(10);
        }
    }

    /// The first request, head and body. Complete once awaitSeen(1) has returned.
    pub fn request(sv: *const Standin) []const u8 {
        return sv.req[0..sv.req_len];
    }

    /// Releases a held connection too. Dials its own port once, so a serve loop parked in accept wakes and exits.
    pub fn stop(sv: *Standin) void {
        sv.closing.store(true, .release);
        const addr = Io.net.IpAddress{ .ip4 = .loopback(sv.port) };
        if (Io.net.IpAddress.connect(&addr, sv.io, .{ .mode = .stream })) |c| c.close(sv.io) else |_| {}
        sv.thread.join();
        sv.server.deinit(sv.io);
    }

    /// `Content-Length: N` -> N, in any letter case. Anything else -> null.
    fn contentLength(line: []const u8) ?usize {
        const k = "content-length:";
        if (line.len <= k.len) return null;
        for (line[0..k.len], k) |a, b| if (std.ascii.toLower(a) != b) return null;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[k.len..], " \t\r"), 10) catch null;
    }
};

/// Polls a started call to its end as the chat thread does, with the clock held at the call's start. poll takes
/// the time as a parameter, so no timeout fires: only the endpoint's answer, or curl exiting, ends the call.
fn pollToEnd(s: *Stream, io: Io, gpa: std.mem.Allocator) !void {
    var waited: u32 = 0;
    while (!s.done) : (waited += 1) {
        if (waited >= 3000) { // ~30 s
            // Neither an answer nor curl's exit ended it. A curl that exits before any transfer writes nothing, not
            // even -w's end marker (a request body it cannot open exits 26 with an empty stdout), so poll() has to
            // see that exit for itself (curlExited).
            std.debug.print("\nthe call never ended: no answer, and no sign that curl exited (saw_any={})\n", .{s.saw_any});
            return error.CallNeverEnded;
        }
        poll(s, io, gpa, s.started_s, false);
        if (!s.done) nap.ms(10);
    }
}

/// Fails if any file in `dir_path` is a curl config or holds `key`. Returns how many files it read.
fn expectNoKeyOnDisk(gpa: std.mem.Allocator, io: Io, dir_path: []const u8, key: []const u8) !usize {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var files: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .file) continue;
        files += 1;
        if (isKeyCfgName(ent.name)) {
            std.debug.print("\na curl config is on disk after its call: {s}/{s}\n", .{ dir_path, ent.name });
            return error.KeyScratchLeft;
        }
        const data = try dir.readFileAlloc(io, ent.name, gpa, .limited(4 << 20));
        defer gpa.free(data);
        if (std.mem.indexOf(u8, data, key) != null) {
            std.debug.print("\nthe API key is on disk after its call: {s}/{s}\n", .{ dir_path, ent.name });
            return error.KeyOnDisk;
        }
    }
    return files;
}

/// TEST ONLY. Looks through one scratch dir for TEST_KEY while a call is in flight, at the two moments a config file
/// was always on disk: right after start() returns (`look`: curl runs with its key) and at the stand-in (`onWire`:
/// curl connected and waiting on the reply). Counts its looks, so a test can show they ran, and keeps the first file
/// found holding the key, named like a config, or unreadable.
const MidCall = struct {
    var io_: Io = undefined;
    var dir: []const u8 = "";
    var looks: std.atomic.Value(u32) = .init(0);
    var on_wire: std.atomic.Value(u32) = .init(0);
    var found: std.atomic.Value(u32) = .init(0);
    var found_name: [128]u8 = undefined;
    var found_len: usize = 0;

    fn arm(io: Io, dir_path: []const u8) void {
        io_ = io;
        dir = dir_path;
        looks.store(0, .monotonic);
        on_wire.store(0, .monotonic);
        found.store(0, .monotonic);
        found_len = 0;
    }
    /// The stand-in's hook (Standin.startWatched).
    fn onWire() void {
        _ = on_wire.fetchAdd(1, .monotonic);
        look();
    }
    fn look() void {
        _ = looks.fetchAdd(1, .monotonic);
        var d = Io.Dir.cwd().openDir(io_, dir, .{ .iterate = true }) catch return note("<the dir would not open>");
        defer d.close(io_);
        var it = d.iterate();
        while (true) {
            const next = it.next(io_) catch return note("<the dir would not list>");
            const ent = next orelse break;
            if (ent.kind != .file) continue;
            const holds = if (isKeyCfgName(ent.name)) true else if (d.readFileAlloc(io_, ent.name, std.testing.allocator, .limited(4 << 20))) |data| blk: {
                defer std.testing.allocator.free(data);
                break :blk std.mem.indexOf(u8, data, TEST_KEY) != null;
            } else |_| true; // a file the look cannot read is one it cannot clear
            if (holds) note(ent.name);
        }
    }
    /// Keeps the first name a look could not clear.
    fn note(name: []const u8) void {
        if (found.fetchAdd(1, .monotonic) > 0) return;
        found_len = @min(name.len, found_name.len);
        @memcpy(found_name[0..found_len], name[0..found_len]);
    }
    /// Fails if a look found the key (or could not rule it out), or if the looks did not run: `wire` requests the
    /// stand-in answered, plus the test's own look after start(). Read only once the stand-in has stopped (its serve
    /// thread looks too).
    fn expectClean(wire: u32) !void {
        if (found.load(.monotonic) > 0) {
            std.debug.print("\nthe API key was on disk while its call ran: {s}/{s}\n", .{ dir, found_name[0..found_len] });
            return error.KeyOnDiskMidCall;
        }
        if (on_wire.load(.monotonic) < wire or looks.load(.monotonic) < wire + 1) {
            std.debug.print("\nthe mid-call looks did not run: {d} in all, {d} on the wire (want {d})\n", .{ looks.load(.monotonic), on_wire.load(.monotonic), wire });
            return error.MidCallLooksMissing;
        }
    }
};

/// Fails unless the stand-in's first request carried the test key: curl read its config.
fn expectKeySent(sv: *const Standin) !void {
    if (std.mem.indexOf(u8, sv.request(), "Authorization: Bearer " ++ TEST_KEY) != null) return;
    std.debug.print("\nthe stand-in never saw the key:\n{s}\n", .{sv.request()});
    return error.KeyNeverSent;
}

test "a desk call never puts its key on disk: not while curl runs, and not after an answer, an HTTP error, a dead transfer, a Stop or a timeout" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-desk-llm-keyscratch-tmp";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    const oops = "{\"error\":{\"message\":\"boom\"}}";
    const End = enum { answer, http_error, dead, stop, timeout };
    const Case = struct { end: End, reply: []const u8 = "", hold: bool = false, err: []const u8 = "" };
    const cases = [_]Case{
        .{ .end = .answer, .reply = TEST_ANSWER },
        .{ .end = .http_error, .reply = std.fmt.comptimePrint("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ oops.len, oops }), .err = "boom" },
        // read, then closed with nothing said: curl exits 52, and poll sees HTTP 000 and reaps it
        .{ .end = .dead, .err = "could not reach" },
        // the endpoint has the call and is still working on it when the user presses Stop...
        .{ .end = .stop, .hold = true },
        // ...or when the first-byte ceiling passes (poll takes the clock as a parameter, so nothing waits it out)
        .{ .end = .timeout, .hold = true, .err = "no response" },
    };
    for (cases) |c| {
        var sv: Standin = undefined;
        try sv.startWatched(io, c.reply, c.hold, MidCall.onWire);
        var sv_up = true;
        defer if (sv_up) sv.stop();
        MidCall.arm(io, root);
        var s: Stream = .{};
        defer s.deinit(gpa);
        defer abort(&s, io); // an expectation that fails below must not leave curl running
        var ub: [64]u8 = undefined;
        const base = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/v1", .{sv.port});
        try std.testing.expect(start(&s, io, gpa, root, .{ .base_url = base, .key = TEST_KEY, .model = "keyscratch-model" }, TEST_MSGS, 16, Io.Timestamp.now(io, .real).toSeconds()));
        MidCall.look(); // the call is in flight: curl runs, and it has its key
        switch (c.end) {
            .answer, .http_error, .dead => {
                try pollToEnd(&s, io, gpa);
                finish(&s, io);
            },
            .stop => {
                try sv.awaitSeen(1);
                abort(&s, io);
            },
            .timeout => {
                try sv.awaitSeen(1);
                poll(&s, io, gpa, s.started_s + FIRST_BYTE_TIMEOUT_S + 1, false);
                try std.testing.expect(s.done);
                finish(&s, io);
            },
        }
        try std.testing.expect(s.child == null);
        if (c.end == .answer) {
            try std.testing.expect(!s.failed);
            try std.testing.expectEqualStrings("streamed", s.content.items);
        } else if (c.err.len > 0) {
            try std.testing.expect(s.failed);
            if (std.mem.indexOf(u8, s.errStr(), c.err) == null) {
                std.debug.print("\n[{t}] expected an error naming \"{s}\", got \"{s}\"\n", .{ c.end, c.err, s.errStr() });
                return error.WrongEnding;
            }
        }
        sv.stop();
        sv_up = false;
        // curl READ its config: the key reached the wire. A config that never got to curl would pass every disk check
        // below and fail every real call.
        try expectKeySent(&sv);
        // While the call ran, no file in the dir held the key: not once start() had returned, and not while the
        // stand-in held the request...
        try MidCall.expectClean(1);
        // ...nor once it ended. The request body and the stream sink stay, key-free, and nothing else: the count is
        // also the proof the scans looked where the call wrote.
        try std.testing.expectEqual(@as(usize, 2), try expectNoKeyOnDisk(gpa, io, root, TEST_KEY));
    }
}

test "a start over a call still running ends that call first, and the new call streams clean" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-desk-llm-keyscratch-restart-tmp";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    var busy: Standin = undefined; // has the first call and is still working on it
    try busy.start(io, "", true);
    defer busy.stop();
    var answering: Standin = undefined;
    try answering.start(io, TEST_ANSWER, false);
    defer answering.stop();
    var s: Stream = .{};
    defer s.deinit(gpa);
    defer abort(&s, io);

    const t0 = Io.Timestamp.now(io, .real).toSeconds();
    var ub1: [64]u8 = undefined;
    const busy_base = try std.fmt.bufPrint(&ub1, "http://127.0.0.1:{d}/v1", .{busy.port});
    try std.testing.expect(start(&s, io, gpa, root, .{ .base_url = busy_base, .key = TEST_KEY, .model = "first-call" }, TEST_MSGS, 16, t0));
    try busy.awaitSeen(1); // the first curl took its config and is waiting on the endpoint
    try expectKeySent(&busy);

    // No finish and no abort: the next call starts over the running one.
    var ub2: [64]u8 = undefined;
    const answering_base = try std.fmt.bufPrint(&ub2, "http://127.0.0.1:{d}/v1", .{answering.port});
    try std.testing.expect(start(&s, io, gpa, root, .{ .base_url = answering_base, .key = TEST_KEY, .model = "second-call" }, TEST_MSGS, 16, t0));

    // The second call streams clean: a first curl still alive would be writing into this same sink.
    try pollToEnd(&s, io, gpa);
    finish(&s, io);
    try std.testing.expect(!s.failed);
    try std.testing.expectEqualStrings("streamed", s.content.items);
    try std.testing.expectEqual(@as(usize, 2), try expectNoKeyOnDisk(gpa, io, root, TEST_KEY));
}

test "a start whose curl never launches leaves no key on disk" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-desk-llm-keyscratch-nocurl-tmp";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // curl missing from PATH: the call gets as far as its spawn, with its scratch written.
    test_curl = "nl-veil-test-no-such-curl";
    defer test_curl = CURL;
    var s: Stream = .{};
    defer s.deinit(gpa);
    try std.testing.expect(!start(&s, io, gpa, root, .{ .base_url = "http://127.0.0.1:9/v1", .key = TEST_KEY, .model = "keyscratch-model" }, TEST_MSGS, 16, 0));
    try std.testing.expect(s.child == null);
    // The request body and the sink are there (the call got as far as launching curl, in this dir), and nothing else.
    try std.testing.expectEqual(@as(usize, 2), try expectNoKeyOnDisk(gpa, io, root, TEST_KEY));
}

test "a desk start with a key too long to hand curl refuses the call before it writes a file or dials" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-desk-llm-keyscratch-long-tmp";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // KEY_CFG_MAX bytes of key alone: with the config's two header lines around it, the config is longer than the pipe.
    const long_key = try gpa.alloc(u8, KEY_CFG_MAX);
    defer gpa.free(long_key);
    @memset(long_key, 'k');
    var sv: Standin = undefined;
    try sv.start(io, TEST_ANSWER, false);
    var sv_up = true;
    defer if (sv_up) sv.stop();
    var s: Stream = .{};
    defer s.deinit(gpa);
    defer abort(&s, io);
    var ub: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/v1", .{sv.port});
    const started = start(&s, io, gpa, root, .{ .base_url = base, .key = long_key, .model = "keyscratch-model" }, TEST_MSGS, 16, 0);
    sv.stop();
    sv_up = false;
    try std.testing.expect(!started);
    try std.testing.expect(s.child == null);
    try std.testing.expectEqual(@as(u32, 0), sv.seen.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), try expectNoKeyOnDisk(gpa, io, root, TEST_KEY)); // no body, no sink
}

test "a desk key that would add curl an option of its own never reaches curl, and a key of punctuation still does" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-desk-llm-keycfg-inject-tmp";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    var sv: Standin = undefined;
    try sv.start(io, TEST_ANSWER, false);
    var sv_up = true;
    defer if (sv_up) sv.stop();

    // Unescaped, this key's line feeds end the config's header line, and curl reads what follows as options of its
    // own: a second `url`, which it dials carrying the very bearer the config set, and a `#` commenting out the
    // stray closing quote. Aimed at the same stand-in, so the dial it would add is one this test can see.
    const injected = try std.fmt.allocPrint(gpa, "sk-inject\"\nurl = \"http://127.0.0.1:{d}/injected\"\n#", .{sv.port});
    defer gpa.free(injected);
    // The punctuation real keys carry, plus the two bytes a config value escapes. It must still reach the wire, byte
    // for byte: the guard refuses BYTES curl cannot carry, not shapes, because keys are not one charset.
    const punctuation = "sk-proj_a\"b\\c-d.e/f+g=h~i";
    var ub: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/v1", .{sv.port});

    var s: Stream = .{};
    defer s.deinit(gpa);
    defer abort(&s, io);

    // The injected key: refused before the spawn, so nothing dials — injected URL or real one — and no scratch lands.
    try std.testing.expect(!start(&s, io, gpa, root, .{ .base_url = base, .key = injected, .model = "keycfg-model" }, TEST_MSGS, 16, 0));
    try std.testing.expect(s.child == null);
    try std.testing.expectEqual(@as(u32, 0), sv.seen.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), try expectNoKeyOnDisk(gpa, io, root, injected)); // no body, no sink

    // The punctuation key: the call streams clean, and the header carries the key exactly as it was handed over.
    try std.testing.expect(start(&s, io, gpa, root, .{ .base_url = base, .key = punctuation, .model = "keycfg-model" }, TEST_MSGS, 16, 0));
    try pollToEnd(&s, io, gpa);
    finish(&s, io);
    sv.stop(); // joins the serve thread: request() is only complete once it has
    sv_up = false;
    try std.testing.expect(!s.failed);
    try std.testing.expectEqualStrings("streamed", s.content.items);
    try std.testing.expectEqual(@as(u32, 1), sv.seen.load(.acquire));
    if (std.mem.indexOf(u8, sv.request(), "Authorization: Bearer " ++ punctuation) == null) {
        std.debug.print("\nthe punctuation key did not reach the wire whole:\n{s}\n", .{sv.request()});
        return error.KeyChangedOnTheWire;
    }
}

test "the key guard refuses exactly the bytes a curl config value cannot carry, and no others" {
    // The RANGE, not a spelling. Below 0x20 and DEL are the bytes curl would either put on the wire as it read them,
    // splitting the header, or stop reading the config at; every other byte rides escaped, which is what an API key
    // needs, since keys are not one charset. A guard that refused more would refuse keys providers really issue —
    // and this is the predicate the Settings pane's Save uses too (chat.zig cmdSaveKey), so it is what a user meets.
    var one: [1]u8 = undefined;
    for (0..256) |b| {
        one[0] = @intCast(b);
        const stray = strayCfgByte(&one);
        if (b < 0x20 or b == 0x7F) try std.testing.expectEqual(@as(?StrayCfgByte, .{ .at = 0, .byte = one[0] }), stray) else try std.testing.expect(stray == null);
    }
    // It reports the FIRST stray byte and where it sits, in a key that otherwise looks ordinary...
    try std.testing.expectEqual(@as(?StrayCfgByte, .{ .at = 11, .byte = '\n' }), strayCfgByte("sk-proj_abc\nurl = \"http://127.0.0.1/x\""));
    // ...and the two bytes a config value escapes are not stray: cfgHeader carries them.
    try std.testing.expect(strayCfgByte("sk-proj_a\"b\\c") == null);
}

test "handing curl its key never waits on curl: the longest config a desk call sends goes whole into a child that never reads" {
    // start() hands curl its config on the chat thread, which must never block, so the write must return whatever
    // curl does: start slowly, hang, or die before it reads.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    // A child that never reads its stdin. On Windows, curl created suspended: its first instruction never runs.
    // Elsewhere, `sleep`: a suspended start there stops the whole process group, this test runner with it.
    const windows = builtin.os.tag == .windows;
    const argv: []const []const u8 = if (windows) &.{ CURL, "--version" } else &.{ "sleep", "30" };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore, .start_suspended = windows, .create_no_window = true }) catch return error.SkipZigTest; // no such program here
    defer child.kill(io);

    // A write that waits for a reader never returns here. The watchdog turns that hang into a failure: after a few
    // seconds it ends the child, which fails the write, and it says it had to.
    const Watchdog = struct {
        var done: std.atomic.Value(bool) = .init(false);
        var fired: std.atomic.Value(bool) = .init(false);
        fn run(id: std.process.Child.Id) void {
            var laps: u32 = 0;
            while (!done.load(.acquire) and laps < 500) : (laps += 1) nap.ms(10);
            if (done.load(.acquire)) return;
            fired.store(true, .release);
            if (builtin.os.tag == .windows) {
                _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
            } else {
                std.posix.kill(id, .KILL) catch {};
            }
        }
    };
    Watchdog.done.store(false, .release);
    Watchdog.fired.store(false, .release);
    const dog = try std.Thread.spawn(.{}, Watchdog.run, .{child.id.?});
    const cfg = try gpa.alloc(u8, KEY_CFG_MAX);
    defer gpa.free(cfg);
    @memset(cfg, 'k');
    const took = keyToCurl(io, &child, cfg);
    Watchdog.done.store(true, .release);
    dog.join();
    if (Watchdog.fired.load(.acquire)) {
        std.debug.print("\nhanding over a {d}-byte config waited on a child that never read it\n", .{cfg.len});
        return error.HandoffWaitedOnCurl;
    }
    try std.testing.expect(took);
    try std.testing.expect(child.stdin == null); // the handoff closed it, so Child.kill does not close it again
}

test "the key sweep knows every config name older desk builds wrote, and its age floor outlives any call" {
    // The sweep finds strays by isKeyCfgName alone, so a config name it does not match is a key no sweep will ever
    // remove: the one fixed name builds before 2026-09-17 left in each dir, and the per-call names (`-{16 hex}`) the
    // builds after them left when a desk died mid-call.
    for ([_][]const u8{ ".chatcurlcfg", ".chatcurlcfg-0123456789abcdef", ".chatcurlcfg-fedcba9876543210" }) |n| {
        try std.testing.expect(isKeyCfgName(n));
    }
    // and nothing that carries no key, or only begins like a config
    for ([_][]const u8{ ".chatreq.json", ".chatstream.sse", ".chatcurlcfgrc", "chatcurlcfg-0123456789abcdef", ".ghcurlcfg", ".curlcfg-chat" }) |n| {
        try std.testing.expect(!isKeyCfgName(n));
    }
    // A config younger than the longest call may belong to one still running (an older desk build's, on this data dir).
    try std.testing.expect(KEY_CFG_STALE_S > TOTAL_TIMEOUT_S + TOTAL_TIMEOUT_SLACK_S);
}

// ---- a call whose curl dies ends when curl does ----
//
// Every transfer curl runs ends in -w's end marker, a failed one included (a refused connect leaves code 000). A curl
// that fails before its transfer writes nothing at all: a request body it cannot open exits 26 with an empty stdout
// (curl 8.5, 8.17 and 8.21, measured 2026-09-17). A curl killed from outside never writes the marker either. These
// tests drive the real curl child into both, against a stand-in on 127.0.0.1, and hand poll() a clock that never
// moves past the call's start, so no ceiling can end the call.

/// How a DeadCurl test's curl ends without writing its end marker.
const DeadCurl = enum {
    /// the call's request body is gone before its curl starts, so curl exits at startup without dialing
    body_gone,
    /// curl is killed while the endpoint has the call and is still working on it
    killed_waiting,
    /// curl is killed after part of the reply has streamed
    killed_streaming,
};

/// TEST ONLY. The `test_before_curl` hook of a DeadCurl.body_gone call: deletes the call's request body, and counts
/// the deletes, so a test can show the body really went.
const DropBody = struct {
    var io_: Io = undefined;
    var path_buf: [256]u8 = undefined;
    var path: []const u8 = "";
    var dropped: u32 = 0;

    /// Aims the hook at the request body start() writes into `root`.
    fn arm(io: Io, root: []const u8) !void {
        io_ = io;
        path = try std.fmt.bufPrint(&path_buf, "{s}/.chatreq.json", .{root});
        dropped = 0;
    }
    fn run() void {
        Io.Dir.cwd().deleteFile(io_, path) catch return;
        dropped += 1;
    }
};

/// TEST ONLY. Ends the call's curl the way something outside the desk would (an antivirus, the OOM killer, Task
/// Manager). The Stream keeps its Child, so only poll() can find out that curl is gone.
fn killCurlOutside(s: *const Stream) void {
    const id = (s.child orelse return).id orelse return;
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
    } else {
        std.posix.kill(id, .KILL) catch {};
    }
}

/// Runs one call in `root` whose curl ends `how`, polls it to its end with the clock held at its start, and checks
/// that it ended failed, with an error naming curl, and with what streamed before curl died still in the Stream.
fn expectDeadCurlCallEnds(gpa: std.mem.Allocator, io: Io, root: []const u8, how: DeadCurl) !void {
    const reply: []const u8 = switch (how) {
        // curl never dials: if it did after all, this clean answer comes back and the call does not fail
        .body_gone => TEST_ANSWER,
        .killed_waiting => "",
        // no Content-Length, so the body runs until the connection closes, and the stand-in holds it open
        .killed_streaming => "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\n",
    };
    var sv: Standin = undefined;
    try sv.start(io, reply, how != .body_gone);
    var sv_up = true;
    defer if (sv_up) sv.stop();
    var s: Stream = .{};
    defer s.deinit(gpa);
    defer abort(&s, io); // an expectation that fails below must not leave curl running

    try DropBody.arm(io, root);
    if (how == .body_gone) test_before_curl = DropBody.run;
    defer test_before_curl = null;

    var ub: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/v1", .{sv.port});
    try std.testing.expect(start(&s, io, gpa, root, .{ .base_url = base, .key = TEST_KEY, .model = "deadcurl-model" }, TEST_MSGS, 16, 0));
    switch (how) {
        .body_gone => {},
        .killed_waiting => {
            try sv.awaitSeen(1);
            killCurlOutside(&s);
        },
        .killed_streaming => {
            try sv.awaitSeen(1);
            var polls: u32 = 0;
            while (!s.saw_any and !s.done) : (polls += 1) {
                if (polls >= 3000) return error.ReplyNeverStreamed; // ~30 s
                poll(&s, io, gpa, s.started_s, false);
                nap.ms(10);
            }
            killCurlOutside(&s);
        },
    }
    try pollToEnd(&s, io, gpa);
    finish(&s, io);
    sv.stop();
    sv_up = false;

    try std.testing.expect(s.child == null);
    const want = if (how == .killed_streaming) "partway through the reply" else "before the model endpoint answered";
    if (!s.failed or std.mem.indexOf(u8, s.errStr(), "curl") == null or std.mem.indexOf(u8, s.errStr(), want) == null) {
        std.debug.print("\n[{t}] expected a failed call whose error names curl and \"{s}\": failed={}, error \"{s}\"\n", .{ how, want, s.failed, s.errStr() });
        return error.WrongEnding;
    }
    switch (how) {
        .body_gone => {
            // the call's own body went before its curl started, and curl never sent the call
            try std.testing.expectEqual(@as(u32, 1), DropBody.dropped);
            try std.testing.expectEqual(@as(u32, 0), sv.seen.load(.acquire));
        },
        .killed_waiting => try std.testing.expectEqual(@as(u32, 1), sv.seen.load(.acquire)),
        .killed_streaming => {
            try std.testing.expectEqual(@as(u32, 1), sv.seen.load(.acquire));
            try std.testing.expectEqualStrings("part", s.content.items);
        },
    }
}

test "a desk call whose curl dies without its end marker ends when curl does, not at the first-byte or stall ceiling" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-desk-llm-deadcurl-tmp";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // Every case runs, so one red run shows each way curl can die.
    var red: u32 = 0;
    for ([_]DeadCurl{ .body_gone, .killed_waiting, .killed_streaming }) |how| {
        expectDeadCurlCallEnds(gpa, io, root, how) catch |e| {
            std.debug.print("\n[{t}] {t}\n", .{ how, e });
            red += 1;
        };
    }
    try std.testing.expectEqual(@as(u32, 0), red);
}
