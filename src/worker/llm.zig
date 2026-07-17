//! The worker's LLM client. Transport splits by destination: a loopback plain-http backend (a local
//! Ollama) uses the in-process raw-socket client (httpc.zig) — no curl child (Defender kills those), no
//! scratch files. A hosted backend needs TLS, which the Zig control plane lacks in-process, so those calls
//! shell out to curl; the API key rides a curl config file (-K) so it never appears on the process argv.
//!
//! Two entry points: chat() for a one-shot system+user completion, and complete() for the agentic tool loop
//! (a pre-built messages array + a tools array → content OR parsed tool_calls).
const std = @import("std");
const httpc = @import("httpc.zig");
const rate = @import("rate.zig");

pub const Reply = struct {
    content: []u8,
    ok: bool,
};

/// PROCESS-WIDE TOKEN METER. The provider reports exact prompt/completion token counts in every response's
/// `usage` block; we fold them in at the single call choke-point (completeBody) for REAL per-round/run cost.
/// Atomic because minds call concurrently. One worker = one swarm = one process.
pub var tokens_in: std.atomic.Value(u64) = .init(0);
pub var tokens_out: std.atomic.Value(u64) = .init(0);
pub var tokens_in_free: std.atomic.Value(u64) = .init(0);
pub var tokens_out_free: std.atomic.Value(u64) = .init(0);
pub var calls_made: std.atomic.Value(u64) = .init(0);
/// Of tokens_in, how many the provider served from its prompt cache (OpenAI usage.prompt_tokens_details.
/// cached_tokens — billed at a steep discount). A run whose cached share is ~0 is re-sending the same
/// prompt prefix uncached every call.
pub var tokens_cached: std.atomic.Value(u64) = .init(0);

pub const TokUsage = struct { in: u64, out: u64, cached: u64 = 0 };

/// Per-THREAD token totals (paid + free summed). Each chat turn runs on its OWN detached thread (spawnTurn), so a
/// thread-local total read as a delta across the turn is exactly THAT turn's usage — correct even when several
/// conversations' turns run concurrently (the process-global atomics above would cross-count them).
threadlocal var tl_tokens_in: u64 = 0;
threadlocal var tl_tokens_out: u64 = 0;
threadlocal var tl_tokens_cached: u64 = 0;

/// Add one call's tokens to the calling thread's running total (called at each usage-fold site, beside the atomics).
fn meterTL(in: u64, out: u64, cached: u64) void {
    tl_tokens_in += in;
    tl_tokens_out += out;
    tl_tokens_cached += cached;
}

/// Snapshot the CALLING THREAD's token totals. A chat turn reads it before + after its work and reports the
/// delta as that turn's usage.
pub fn tokensSnapshot() TokUsage {
    return .{ .in = tl_tokens_in, .out = tl_tokens_out, .cached = tl_tokens_cached };
}

pub const Caps = struct {
    probed: bool = false,
    ollama_native: bool = false,
    reasoning: bool = false,
    /// From /api/show model_info "<arch>.context_length": the model's REAL maximum context window. 0 = unknown.
    ctx_tokens: u32 = 0,
    /// capabilities[] from /api/show parsed OK — when true, `tools`/`thinking` are authoritative and replace
    /// the model-NAME heuristics entirely.
    caps_listed: bool = false,
    tools: bool = false,
    thinking: bool = false,
    /// From /api/show model_info "general.parameter_count" — a measured tier prior (0 = unknown).
    param_count: u64 = 0,
    /// One-shot startup probe: can this backend PARSE a file-sized tool call? Ollama's chat templates on some
    /// small non-thinking models return a large call as raw text / a parse error — every full-file write_file
    /// would be lost. Defaults to trusted; only clear parse-failure evidence flips it (the runtime adaptive
    /// fence flip is the safety net for anything the probe misses).
    tools_ok_large: bool = true,
    /// HOSTED (OpenAI-style) backends: does a chat completion carrying a tools array come back as STRUCTURED
    /// tool_calls, or does the model emit the call as text markup (e.g. DeepSeek's ｜DSML｜ emission)? Measured
    /// by a real startup completion, cached per model. Defaults to trusted; only clear text-emission evidence flips it.
    tools_native_ok: bool = true,
};
var caps: Caps = .{};

pub fn capsSnapshot() Caps {
    return caps;
}

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    args: []u8,
};

pub const Step = struct {
    content: []u8,
    reasoning: []u8,
    calls: []ToolCall,
    ok: bool,
    // The provider CUT this reply at the output-token limit (done_reason/finish_reason == "length").
    // Load-bearing for the narrated-write salvage: a fenced file body inside a cut reply is INCOMPLETE
    // even though it reads as a clean prefix, so committing it silently ships a truncated deliverable.
    truncated: bool = false,

    pub fn deinit(self: *Step, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
        gpa.free(self.reasoning);
        for (self.calls) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
            gpa.free(c.args);
        }
        gpa.free(self.calls);
    }
};

/// A LOCAL model endpoint (Ollama / LM Studio / llama.cpp on this machine) — detected from the base_url. Local
/// inference is much SLOWER (seconds–minutes, CPU/partial-GPU) and never rate-limits, so the client must NOT
/// use the short hosted timeout + transient-retry; and a THINKING model spends part of its token budget on
/// hidden reasoning, so tiny max_tokens calls return empty.
pub fn isLocal(base_url: []const u8) bool {
    return std.mem.indexOf(u8, base_url, "localhost") != null or
        std.mem.indexOf(u8, base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, base_url, "0.0.0.0") != null or
        std.mem.indexOf(u8, base_url, "[::1]") != null;
}
fn isOllama(base_url: []const u8) bool {
    if (caps.probed) return caps.ollama_native;
    return isLocal(base_url) and std.mem.indexOf(u8, base_url, "11434") != null;
}
/// Floor on max_tokens for a LOCAL **thinking** model: its hidden reasoning eats the budget before the answer,
/// so a small-budget call would come back empty. Give those calls room to think AND answer.
const LOCAL_MIN_TOKENS: u32 = 2048;
const NATIVE_THINK_TOKENS: u32 = 24576;
const NATIVE_CTX: u32 = 32768;

/// Is this a THINKING/reasoning model (hidden chain-of-thought before the answer)? Only those need the token
/// floor. A plain relay model answers fine at a small max_tokens — and flooring it to 2048 forces it to GENERATE
/// 2048 tokens for a small task, a multi-minute stall. So the floor is gated on the model, not just "is it local".
fn isThinking(model: []const u8) bool {
    if (caps.probed and caps.caps_listed) return caps.thinking or caps.reasoning;
    if (caps.probed and caps.ollama_native) return caps.reasoning;
    var buf: [64]u8 = undefined;
    const n = @min(model.len, buf.len);
    for (model[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const m = buf[0..n];
    return std.mem.indexOf(u8, m, "r1") != null or std.mem.indexOf(u8, m, "qwq") != null or
        std.mem.indexOf(u8, m, "o1") != null or std.mem.indexOf(u8, m, "o3") != null or
        std.mem.indexOf(u8, m, "think") != null or std.mem.indexOf(u8, m, "reason") != null or
        std.mem.indexOf(u8, m, "deepseek-r") != null or std.mem.indexOf(u8, m, "gpt-oss") != null or
        std.mem.indexOf(u8, m, "gpt-5") != null or std.mem.indexOf(u8, m, "o4") != null;
}

pub fn fenceWrites(base_url: []const u8, model: []const u8) bool {
    if (!isOllama(base_url)) {
        // hosted OpenAI-style backend: fence ONLY on measured text-emission evidence (unprobed → trust the
        // native channel; the runtime adaptive flip covers whatever the probe misses)
        return caps.probed and !caps.tools_native_ok;
    }
    if (isThinking(model)) return true;
    // a probed backend that cannot parse file-sized tool calls gets fenced writes from round 1
    return caps.probed and caps.caps_listed and !caps.tools_ok_large;
}

/// The effective max_tokens: a LOCAL thinking model gets the floor (room to reason); everything else (hosted, or
/// a local NON-thinking relay) uses the caller's value verbatim, so the relay generates only what it needs.
fn effTokens(base_url: []const u8, model: []const u8, max_tokens: u32) u32 {
    return if (isLocal(base_url) and isThinking(model)) @max(max_tokens, LOCAL_MIN_TOKENS) else max_tokens;
}

/// POST a fully-formed request body to {base_url}/chat/completions. Returns the raw response JSON (caller
/// frees) or an error message (ok=false). The key rides in a curl config file, never on the argv. `tag`
/// makes the scratch request/config files per-caller so concurrent minds don't clobber each other.
fn post(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, body: []const u8) Reply {
    const url = std.fmt.allocPrint(gpa, "{s}/chat/completions", .{trimSlash(base_url)}) catch return oom(gpa);
    defer gpa.free(url);
    // HOSTED-provider pacing: honor any active per-host 429 cooldown + the optional RPM cap before sending.
    // Local backends never rate-limit, so they skip it (and keep their long, retry-free timeout).
    if (!isLocal(base_url)) rate.acquire(io, base_url);
    return postUrl(gpa, io, run_dir, tag, url, key, body, isLocal(base_url));
}

fn postUrl(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, url: []const u8, key: []const u8, body: []const u8, local: bool) Reply {
    // Loopback plain-http (a local Ollama): in-process socket. No curl child, none of the scratch files
    // below — the key and body never touch disk or an argv on this path. Mirrors curl semantics: any HTTP
    // status with a body is returned ok=true (callers parse {"error":...} out of the JSON).
    if (httpc.parseLoopbackUrl(url)) |t| {
        switch (httpc.request(io, gpa, .{
            .method = "POST",
            .port = t.port,
            .path = if (t.path.len > 0) t.path else "/",
            .bearer = key,
            .body = body,
            .timeout_s = if (local) 240 else 90,
            .cap = 8 << 20,
        })) {
            .ok => |resp| return .{ .content = resp.body, .ok = true },
            .refused => return err(gpa, "connect refused — is the local model server running?"),
            .timed_out => return err(gpa, "local model call timed out"),
            .failed => return err(gpa, "local model call failed (connection dropped mid-reply)"),
        }
    }
    const reqpath = std.fmt.allocPrint(gpa, "{s}/.llmreq{s}{s}.json", .{ run_dir, if (tag.len > 0) "-" else "", tag }) catch return oom(gpa);
    defer gpa.free(reqpath);
    const cfgpath = std.fmt.allocPrint(gpa, "{s}/.curlcfg{s}{s}", .{ run_dir, if (tag.len > 0) "-" else "", tag }) catch return oom(gpa);
    defer gpa.free(cfgpath);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = reqpath, .data = body }) catch return err(gpa, "could not write llm request");
    const cfg = std.fmt.allocPrint(gpa, "header = \"Authorization: Bearer {s}\"\nheader = \"Content-Type: application/json\"\n", .{key}) catch return oom(gpa);
    defer gpa.free(cfg);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgpath, .data = cfg }) catch return err(gpa, "could not write curl config");

    const data_at = std.fmt.allocPrint(gpa, "@{s}", .{reqpath}) catch return oom(gpa);
    defer gpa.free(data_at);
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    av.appendSlice(gpa, &.{ "curl", "-sS", "--max-time", if (local) "240" else "90" }) catch return oom(gpa);
    if (!local) av.appendSlice(gpa, &.{ "--retry", "1", "--retry-delay", "1", "--retry-connrefused", "--retry-all-errors", "--retry-max-time", "3" }) catch return oom(gpa);
    av.appendSlice(gpa, &.{ "-K", cfgpath, "--data-binary", data_at, url }) catch return oom(gpa);
    const run = std.process.run(gpa, io, .{ .argv = av.items, .stdout_limit = .limited(8 << 20) }) catch return err(gpa, "curl failed to run");
    defer gpa.free(run.stderr);
    if (run.term != .exited or run.term.exited != 0) {
        defer gpa.free(run.stdout);
        return err(gpa, std.fmt.allocPrint(gpa, "curl exit: {s}", .{run.stderr[0..@min(run.stderr.len, 200)]}) catch "curl nonzero exit");
    }
    return .{ .content = run.stdout, .ok = true };
}

/// One-shot system+user completion → the assistant text. Uses the backend's default sampling.
pub fn chat(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, model: []const u8, system: []const u8, user: []const u8, max_tokens: u32) Reply {
    return chatTemp(gpa, io, run_dir, tag, base_url, key, model, system, user, max_tokens, -1);
}

/// As `chat`, but PINS the sampling temperature. `temperature < 0` omits it (backend default = `chat`).
/// The mechanical classifiers (the emotional-flare read, the constitution screens) pass 0 so their verdicts
/// are DETERMINISTIC: the same hive state yields the same label instead of resampling a fresh emotion.
pub fn chatTemp(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, model: []const u8, system: []const u8, user: []const u8, max_tokens: u32, temperature: f32) Reply {
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return oom(gpa);
    jstr(gpa, &msgs, system) catch return oom(gpa);
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return oom(gpa);
    jstr(gpa, &msgs, user) catch return oom(gpa);
    msgs.appendSlice(gpa, "}") catch return oom(gpa);
    const mt = effTokens(base_url, model, max_tokens);
    const temp_frag = tempFragOwned(gpa, io, model, temperature); // learned-quirk aware (Kimi temp=1, etc.)
    defer gpa.free(temp_frag);
    const body = std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}]{s},\"max_tokens\":{d}}}", .{ model, msgs.items, temp_frag, mt }) catch return oom(gpa);
    defer gpa.free(body);
    var s = completeBody(gpa, io, run_dir, tag, base_url, key, body);
    defer s.deinit(gpa);
    if (!s.ok) return err(gpa, s.content);
    return .{ .content = gpa.dupe(u8, s.content) catch return oom(gpa), .ok = true };
}

/// The agentic step: `messages_json` is the inside of "messages":[ … ] (caller-built, grows each turn);
/// `tools_json` is the inside of "tools":[ … ]. Returns the assistant content OR parsed tool_calls.
pub fn complete(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, model: []const u8, messages_json: []const u8, tools_json: []const u8, max_tokens: u32, temperature: f32) Step {
    if (isOllama(base_url)) return completeOllamaNative(gpa, io, run_dir, tag, base_url, key, model, messages_json, tools_json, max_tokens, temperature);
    const mt = effTokens(base_url, model, max_tokens);
    const temp_frag = tempFragOwned(gpa, io, model, temperature); // learned-quirk aware (Kimi temp=1, etc.)
    defer gpa.free(temp_frag);
    const body = if (tools_json.len > 0)
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"tools\":[{s}]{s},\"max_tokens\":{d}}}", .{ model, messages_json, tools_json, temp_frag, mt }) catch return stepErr(gpa, "oom")
    else
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}]{s},\"max_tokens\":{d}}}", .{ model, messages_json, temp_frag, mt }) catch return stepErr(gpa, "oom");
    defer gpa.free(body);
    return completeBody(gpa, io, run_dir, tag, base_url, key, body);
}

fn completeOllamaNative(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, model: []const u8, messages_json: []const u8, tools_json: []const u8, max_tokens: u32, temperature: f32) Step {
    const np: u32 = if (isThinking(model)) @max(max_tokens, NATIVE_THINK_TOKENS) else max_tokens;
    const temp_frag = tempFragOwned(gpa, io, model, temperature); // learned-quirk aware
    defer gpa.free(temp_frag);
    var root = trimSlash(base_url);
    if (std.mem.endsWith(u8, root, "/v1")) root = root[0 .. root.len - 3];
    const url = std.fmt.allocPrint(gpa, "{s}/api/chat", .{root}) catch return stepErr(gpa, "oom");
    defer gpa.free(url);
    const body = ollamaNativeBody(gpa, model, messages_json, tools_json, np, effectiveCtx(), temp_frag) catch return stepErr(gpa, "oom");
    defer gpa.free(body);
    const r = postUrl(gpa, io, run_dir, tag, url, key, body, true);
    if (!r.ok) return .{ .content = r.content, .reasoning = gpa.dupe(u8, "") catch @constCast(""), .calls = &.{}, .ok = false };
    defer gpa.free(r.content);
    return parseOllamaNative(gpa, base_url, r.content);
}

/// The num_ctx actually requested: never MORE than the model's probed maximum (asking beyond it is silently
/// clamped or errors depending on backend), and never more than the engine budget (NATIVE_CTX). Unprobed
/// keeps the engine budget verbatim.
fn effectiveCtx() u32 {
    return if (caps.ctx_tokens > 0) @min(NATIVE_CTX, caps.ctx_tokens) else NATIVE_CTX;
}

// keep_alive "2m": once the worker exits, the local model is released a couple minutes later instead of
// Ollama's 5-min default. During the run, every request resets the timer, so it stays loaded.
const OLLAMA_KEEP_ALIVE = "2m";
fn ollamaNativeBody(gpa: std.mem.Allocator, model: []const u8, messages_json: []const u8, tools_json: []const u8, np: u32, ctx: u32, temp_frag: []const u8) ![]u8 {
    return if (tools_json.len > 0)
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"tools\":[{s}],\"stream\":false,\"keep_alive\":\"{s}\",\"options\":{{\"num_predict\":{d},\"num_ctx\":{d}{s}}}}}", .{ model, messages_json, tools_json, OLLAMA_KEEP_ALIVE, np, ctx, temp_frag })
    else
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":false,\"keep_alive\":\"{s}\",\"options\":{{\"num_predict\":{d},\"num_ctx\":{d}{s}}}}}", .{ model, messages_json, OLLAMA_KEEP_ALIVE, np, ctx, temp_frag });
}

fn parseOllamaNative(gpa: std.mem.Allocator, base_url: []const u8, raw: []const u8) Step {
    const Resp = struct {
        message: ?struct {
            content: ?[]const u8 = null,
            thinking: ?[]const u8 = null,
            tool_calls: ?[]const struct {
                function: struct { name: []const u8 = "", arguments: std.json.Value = .null },
            } = null,
        } = null,
        done_reason: ?[]const u8 = null,
        eval_count: ?u64 = 0,
        prompt_eval_count: ?u64 = 0,
        @"error": ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Resp, gpa, raw, .{ .ignore_unknown_fields = true }) catch
        return stepErr(gpa, std.fmt.allocPrint(gpa, "bad Ollama response: {s}", .{raw[0..@min(raw.len, 300)]}) catch "unparseable response");
    defer parsed.deinit();
    if (parsed.value.eval_count) |ec| {
        if (isLocal(base_url)) {
            _ = tokens_in_free.fetchAdd(parsed.value.prompt_eval_count orelse 0, .monotonic);
            _ = tokens_out_free.fetchAdd(ec, .monotonic);
        } else {
            _ = tokens_in.fetchAdd(parsed.value.prompt_eval_count orelse 0, .monotonic);
            _ = tokens_out.fetchAdd(ec, .monotonic);
        }
        meterTL(parsed.value.prompt_eval_count orelse 0, ec, 0);
        _ = calls_made.fetchAdd(1, .monotonic);
    }
    if (parsed.value.@"error") |e| return stepErr(gpa, std.fmt.allocPrint(gpa, "provider error: {s}", .{e}) catch "provider error");
    const msg = parsed.value.message orelse return stepErr(gpa, "no message in Ollama response");

    var calls: std.ArrayListUnmanaged(ToolCall) = .empty;
    if (msg.tool_calls) |tcs| {
        for (tcs) |tc| {
            const args = std.json.Stringify.valueAlloc(gpa, tc.function.arguments, .{}) catch continue;
            calls.append(gpa, .{
                .id = gpa.dupe(u8, "") catch {
                    gpa.free(args);
                    continue;
                },
                .name = gpa.dupe(u8, tc.function.name) catch {
                    gpa.free(args);
                    continue;
                },
                .args = args,
            }) catch {
                gpa.free(args);
            };
        }
    }
    const content = gpa.dupe(u8, msg.content orelse "") catch return stepErr(gpa, "oom");
    const reasoning = gpa.dupe(u8, msg.thinking orelse "") catch return stepErr(gpa, "oom");
    const trunc = if (parsed.value.done_reason) |dr| std.mem.eql(u8, dr, "length") else false;
    return .{ .content = content, .reasoning = reasoning, .calls = calls.toOwnedSlice(gpa) catch &.{}, .ok = true, .truncated = trunc };
}

fn parseOllamaVersion(raw: []const u8) bool {
    const V = struct { version: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(V, std.heap.page_allocator, raw, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    const v = parsed.value.version orelse return false;
    return v.len > 0;
}

fn responseHasReasoning(raw: []const u8) bool {
    const R = struct {
        message: ?struct {
            thinking: ?[]const u8 = null,
            reasoning: ?[]const u8 = null,
        } = null,
        reasoning_content: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(R, std.heap.page_allocator, raw, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    if (parsed.value.message) |msg| {
        if (msg.thinking) |t| if (t.len > 0) return true;
        if (msg.reasoning) |r| if (r.len > 0) return true;
    }
    if (parsed.value.reasoning_content) |rc| if (rc.len > 0) return true;
    return false;
}

pub fn probeCapabilities(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, base_url: []const u8, key: []const u8, model: []const u8) void {
    var host = trimSlash(base_url);
    if (std.mem.endsWith(u8, host, "/v1")) host = host[0 .. host.len - 3];

    const ver_url = std.fmt.allocPrint(gpa, "{s}/api/version", .{host}) catch return;
    defer gpa.free(ver_url);
    const ver: ?[]u8 = blk: {
        // loopback (the common local-Ollama case): in-process socket, no curl child
        if (httpc.parseLoopbackUrl(ver_url)) |t| {
            switch (httpc.request(io, gpa, .{
                .method = "GET",
                .port = t.port,
                .path = if (t.path.len > 0) t.path else "/",
                .timeout_s = 5,
                .cap = 64 << 10,
            })) {
                .ok => |resp| break :blk resp.body,
                else => break :blk null,
            }
        }
        // non-loopback base (hosted/remote): curl still carries the TLS
        const run = std.process.run(gpa, io, .{
            .argv = &.{ "curl", "-sS", "--max-time", "5", ver_url },
            .stdout_limit = .limited(64 << 10),
        }) catch break :blk null;
        gpa.free(run.stderr);
        if (run.term != .exited or run.term.exited != 0) {
            gpa.free(run.stdout);
            break :blk null;
        }
        break :blk run.stdout;
    };
    if (ver == null) return;
    const ver_body = ver.?;
    defer gpa.free(ver_body);

    caps.ollama_native = parseOllamaVersion(ver_body);
    caps.probed = true;

    if (caps.ollama_native) {
        // /api/show is the backend's own capability record: capabilities[] ("tools"/"thinking") replaces the
        // model-NAME heuristics, and model_info's "<arch>.context_length" bounds num_ctx so the engine never
        // requests a window the model cannot serve. Cheap (no model load) and exact.
        const show_url = std.fmt.allocPrint(gpa, "{s}/api/show", .{host}) catch return;
        defer gpa.free(show_url);
        var sbody: std.ArrayListUnmanaged(u8) = .empty;
        defer sbody.deinit(gpa);
        sbody.appendSlice(gpa, "{\"model\":") catch return;
        jstr(gpa, &sbody, model) catch return;
        sbody.appendSlice(gpa, "}") catch return;
        const sr = postUrl(gpa, io, run_dir, "probe-show", show_url, key, sbody.items, true);
        if (sr.ok) parseShowCaps(sr.content);
        gpa.free(sr.content);
    }

    // LARGE-TOOL-CALL PROBE: only the ambiguous case is probed (native + tools listed + non-thinking) —
    // thinking models already get fenced writes, and a model without the tools capability never sends
    // structured calls. The verdict is a MODEL property, so it is CACHED across runs (the echo round-trip
    // costs ~75s on a slow local model); a runtime-observed wall overwrites a false pass via
    // recordLargeToolWall — measured behavior always outranks the synthetic probe.
    if (caps.ollama_native and caps.caps_listed and caps.tools and !caps.thinking) {
        if (cachedLargeVerdict(gpa, io, run_dir, model)) |v| {
            caps.tools_ok_large = v;
        } else {
            caps.tools_ok_large = probeLargeToolCall(gpa, io, run_dir, host, key, model);
            storeLargeVerdict(gpa, io, run_dir, model, caps.tools_ok_large);
        }
    }

    if (!caps.ollama_native) {
        // OpenAI-style hosted backend: measure whether a tools-array completion comes back as STRUCTURED
        // tool_calls or as text markup (DeepSeek-style emission). The fence decision must ride measured
        // transport behavior, never the provider's name. Cached per model, same trust bias as the
        // large-call probe: only clear text-emission flips it.
        var kb: [160]u8 = undefined;
        const nkey = std.fmt.bufPrint(&kb, "native:{s}", .{model}) catch model;
        if (cachedLargeVerdict(gpa, io, run_dir, nkey)) |v| {
            caps.tools_native_ok = v;
        } else {
            caps.tools_native_ok = probeHostedToolCall(gpa, io, run_dir, base_url, key, model);
            storeLargeVerdict(gpa, io, run_dir, nkey, caps.tools_native_ok);
        }
        return;
    }

    if (caps.ollama_native and caps.caps_listed) {
        caps.reasoning = caps.thinking; // authoritative record — no need to load the model just to ask it
    } else if (caps.ollama_native) {
        const chat_url = std.fmt.allocPrint(gpa, "{s}/api/chat", .{host}) catch return;
        defer gpa.free(chat_url);
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(gpa);
        msg.appendSlice(gpa, "{\"role\":\"user\",\"content\":") catch return;
        jstr(gpa, &msg, "Reply with the single word ok.") catch return;
        msg.appendSlice(gpa, "}") catch return;
        const body = std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":false,\"options\":{{\"num_predict\":64}}}}", .{ model, msg.items }) catch return;
        defer gpa.free(body);
        const r = postUrl(gpa, io, run_dir, "probe", chat_url, key, body, true);
        if (r.ok) {
            defer gpa.free(r.content);
            if (responseHasReasoning(r.content)) caps.reasoning = true;
        } else {
            gpa.free(r.content);
        }
    }
}

/// Fold an /api/show response into the caps record. capabilities[] is the authoritative tools/thinking
/// classification; model_info's "<arch>.context_length" is the model's real maximum window — the rope-scaling
/// "…original_context_length" sibling (the PRE-scaling window) is ignored.
fn parseShowCaps(raw: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;
    if (root.get("capabilities")) |cv| {
        if (cv == .array) {
            caps.caps_listed = true;
            for (cv.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.eql(u8, item.string, "tools")) caps.tools = true;
                if (std.mem.eql(u8, item.string, "thinking")) caps.thinking = true;
            }
        }
    }
    if (root.get("model_info")) |mv| {
        if (mv == .object) {
            var it = mv.object.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (!std.mem.endsWith(u8, k, ".context_length")) continue;
                if (std.mem.endsWith(u8, k, ".original_context_length")) continue;
                if (e.value_ptr.* == .integer and e.value_ptr.*.integer > 0)
                    caps.ctx_tokens = std.math.cast(u32, e.value_ptr.*.integer) orelse std.math.maxInt(u32);
            }
            if (mv.object.get("general.parameter_count")) |pv| {
                if (pv == .integer and pv.integer > 0) caps.param_count = @intCast(pv.integer);
            }
        }
    }
}

/// The probe-verdict cache lives NEXT TO the run dirs (one backend serves many runs): `<run_dir>/../probe-cache.tsv`,
/// one `model\t0|1` line per model. A miss means "probe it"; the runtime fence flip rewrites a false pass to 0.
fn probeCachePath(gpa: std.mem.Allocator, run_dir: []const u8) ?[]u8 {
    return std.fmt.allocPrint(gpa, "{s}/../probe-cache.tsv", .{run_dir}) catch null;
}

fn cachedLargeVerdict(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, model: []const u8) ?bool {
    const p = probeCachePath(gpa, run_dir) orelse return null;
    defer gpa.free(p);
    const data = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 << 10)) catch return null;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        var f = std.mem.splitScalar(u8, ln, '\t');
        const m = f.next() orelse continue;
        if (!std.mem.eql(u8, m, model)) continue;
        const v = f.next() orelse continue;
        return std.mem.eql(u8, std.mem.trim(u8, v, " \r"), "1");
    }
    return null;
}

fn storeLargeVerdict(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, model: []const u8, ok: bool) void {
    const p = probeCachePath(gpa, run_dir) orelse return;
    defer gpa.free(p);
    const data = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 << 10)) catch "";
    defer if (data.len > 0) gpa.free(data);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        if (std.mem.trim(u8, ln, " \r").len == 0) continue;
        var f = std.mem.splitScalar(u8, ln, '\t');
        const m = f.next() orelse continue;
        if (std.mem.eql(u8, m, model)) continue; // replaced below
        out.appendSlice(gpa, ln) catch return;
        out.append(gpa, '\n') catch return;
    }
    out.appendSlice(gpa, model) catch return;
    out.append(gpa, '\t') catch return;
    out.appendSlice(gpa, if (ok) "1" else "0") catch return;
    out.append(gpa, '\n') catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = out.items }) catch {};
}

/// The RUNTIME fence flip observed a real large-tool-call wall the startup probe missed. Persist the verdict
/// (a model property) so every FUTURE run of this model fences from round 1 instead of re-learning it. The
/// native-transport verdict is flipped + persisted too: on a hosted backend the wall IS the evidence that
/// structured tool_calls cannot be trusted, and fenceWrites' hosted branch reads tools_native_ok.
pub fn recordLargeToolWall(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, model: []const u8) void {
    caps.tools_ok_large = false;
    caps.tools_native_ok = false;
    storeLargeVerdict(gpa, io, run_dir, model, false);
    var kb: [160]u8 = undefined;
    if (std.fmt.bufPrint(&kb, "native:{s}", .{model})) |nkey| {
        storeLargeVerdict(gpa, io, run_dir, nkey, false);
    } else |_| {}
}

/// One real chat completion against a HOSTED OpenAI-style backend carrying a minimal tools array: does the
/// call come back as structured tool_calls? Trust-biased like probeLargeToolCall — a network flake, an
/// unrelated provider error, or a model that just answers in prose stays trusted; ONLY the clear failure
/// signature (the tool call emitted as text/markup in `content`) reports false.
fn probeHostedToolCall(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, base_url: []const u8, key: []const u8, model: []const u8) bool {
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    defer msg.deinit(gpa);
    msg.appendSlice(gpa, "{\"role\":\"user\",\"content\":") catch return true;
    jstr(gpa, &msg, "Call the write_file tool exactly once: path=\"probe.txt\", content=\"probe ok\". Do not reply with prose.") catch return true;
    msg.appendSlice(gpa, "}") catch return true;
    const tool_def = "{\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"description\":\"write a file\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}}";
    // temperature 0: measure the backend's MODAL behavior, not a sampling coin-flip. max_tokens leaves
    // room for a hosted reasoning model to think before the call (hidden reasoning eats the budget).
    const body = std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"tools\":[{s}],\"temperature\":0,\"max_tokens\":2048}}", .{ model, msg.items, tool_def }) catch return true;
    defer gpa.free(body);
    const r = post(gpa, io, run_dir, "probe-native", base_url, key, body);
    defer gpa.free(r.content);
    if (!r.ok) return true; // transport flake ≠ text-emission evidence
    return hostedToolCallVerdict(r.content);
}

fn hostedToolCallVerdict(raw: []const u8) bool {
    const Resp = struct {
        choices: []const struct {
            message: struct {
                content: ?[]const u8 = null,
                tool_calls: ?[]const struct {
                    function: struct { name: []const u8 = "", arguments: []const u8 = "" },
                } = null,
            },
        } = &.{},
        @"error": ?struct { message: []const u8 = "" } = null,
    };
    const parsed = std.json.parseFromSlice(Resp, std.heap.page_allocator, raw, .{ .ignore_unknown_fields = true }) catch return true;
    defer parsed.deinit();
    if (parsed.value.@"error") |e| {
        var buf: [300]u8 = undefined;
        const n = @min(e.message.len, buf.len);
        for (e.message[0..n], 0..) |c, j| buf[j] = std.ascii.toLower(c);
        const low = buf[0..n];
        // an error naming the tool-call machinery is transport evidence; busy/billing/quota is not
        if (std.mem.indexOf(u8, low, "tool") != null or std.mem.indexOf(u8, low, "pars") != null) return false;
        return true;
    }
    if (parsed.value.choices.len == 0) return true;
    const m = parsed.value.choices[0].message;
    if (m.tool_calls) |tcs| {
        if (tcs.len > 0) return true; // structured — the native channel works
    }
    const c = m.content orelse return true;
    // the failure signature: the CALL itself emitted as text/markup instead of a tool_calls entry
    if (std.mem.indexOf(u8, c, "write_file") != null and
        (std.mem.indexOfScalar(u8, c, '{') != null or std.mem.indexOf(u8, c, "<invoke") != null or std.mem.indexOf(u8, c, "tool_calls>") != null)) return false;
    return true;
}

/// Ask the model to echo a file-sized payload through ONE write_file call, and judge whether the backend
/// returned it as a STRUCTURED tool call. The bias is trust: only clear parse-failure evidence (an error
/// naming the tool-call parse, or the call emitted as raw text) reports false; the runtime adaptive fence
/// flip covers whatever the probe misses.
fn probeLargeToolCall(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, host: []const u8, key: []const u8, model: []const u8) bool {
    const chat_url = std.fmt.allocPrint(gpa, "{s}/api/chat", .{host}) catch return true;
    defer gpa.free(chat_url);
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(gpa);
    var lb: [96]u8 = undefined;
    var i: u32 = 1;
    while (i <= 56) : (i += 1) { // ~3.6KB — the size class where the parser wall was observed (~4KB)
        const ln = std.fmt.bufPrint(&lb, "line {d:0>3}: the quick brown fox jumps over the lazy dog 0123456789\n", .{i}) catch break;
        payload.appendSlice(gpa, ln) catch return true;
    }
    var umsg: std.ArrayListUnmanaged(u8) = .empty;
    defer umsg.deinit(gpa);
    umsg.appendSlice(gpa, "Call the write_file tool exactly once: path=\"probe.txt\", content = EXACTLY the text between <BEGIN> and <END>, all lines verbatim. Do not reply with prose.\n<BEGIN>\n") catch return true;
    umsg.appendSlice(gpa, payload.items) catch return true;
    umsg.appendSlice(gpa, "<END>") catch return true;
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    defer msg.deinit(gpa);
    msg.appendSlice(gpa, "{\"role\":\"user\",\"content\":") catch return true;
    jstr(gpa, &msg, umsg.items) catch return true;
    msg.appendSlice(gpa, "}") catch return true;
    const tool_def = "{\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"description\":\"write a file\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}}";
    // temperature 0: measure the backend's MODAL behavior, not a sampling coin-flip (at the default temperature
    // the same model alternates between a structured call and the text-emission failure).
    const body = std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"tools\":[{s}],\"stream\":false,\"options\":{{\"num_predict\":2048,\"temperature\":0}}}}", .{ model, msg.items, tool_def }) catch return true;
    defer gpa.free(body);
    const r = postUrl(gpa, io, run_dir, "probe-write", chat_url, key, body, true);
    defer gpa.free(r.content);
    if (!r.ok) return true; // network flake ≠ parser wall
    return largeToolCallVerdict(r.content);
}

fn largeToolCallVerdict(raw: []const u8) bool {
    const Resp = struct {
        message: ?struct {
            content: ?[]const u8 = null,
            tool_calls: ?[]const struct {
                function: struct { name: []const u8 = "", arguments: std.json.Value = .null },
            } = null,
        } = null,
        @"error": ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Resp, std.heap.page_allocator, raw, .{ .ignore_unknown_fields = true }) catch return true;
    defer parsed.deinit();
    if (parsed.value.@"error") |e| {
        var buf: [300]u8 = undefined;
        const n = @min(e.len, buf.len);
        for (e[0..n], 0..) |c, j| buf[j] = std.ascii.toLower(c);
        const low = buf[0..n];
        if (std.mem.indexOf(u8, low, "tool") != null or std.mem.indexOf(u8, low, "pars") != null or std.mem.indexOf(u8, low, "closing") != null) return false;
        return true; // an unrelated error (busy/oom) is not parser evidence
    }
    const m = parsed.value.message orelse return true;
    if (m.tool_calls) |tcs| {
        if (tcs.len > 0) return true; // the backend parsed the large call — trustworthy
    }
    const c = m.content orelse return true;
    // the failure signature: the CALL itself came back as raw text instead of a structured tool_calls entry
    if (std.mem.indexOf(u8, c, "write_file") != null and std.mem.indexOfScalar(u8, c, '{') != null) return false;
    return true;
}

// ---- SELF-HEALING provider quirks -----------------------------------------------------------------------
// Some BYOK models reject a request PARAMETER our default request carries — e.g. Kimi's kimi-k3 accepts only
// temperature=1, and some reasoning models reject `temperature` outright. On such a provider error we read
// the constraint out of the error text, rewrite the request to satisfy it, retry ONCE, and LEARN the quirk
// (per model, process-global) so every later request pre-applies it and never pays the failed round-trip
// again. A GENERAL mechanism seeded with the temperature rules — add detectQuirk cases as constraints surface.

const TempRule = enum { keep, force, drop };
const Quirk = struct { temp: TempRule = .keep, temp_val: f32 = 1.0 };

const QuirkSlot = struct { hash: u64 = 0, q: Quirk = .{} };
var quirk_tbl: [128]QuirkSlot = @splat(.{});
var quirk_mtx: std.Io.Mutex = .init;

fn learnQuirk(io: std.Io, model: []const u8, q: Quirk) void {
    if (model.len == 0) return;
    const h = std.hash.Wyhash.hash(0x9e37, model);
    quirk_mtx.lockUncancelable(io);
    defer quirk_mtx.unlock(io);
    for (&quirk_tbl) |*e| if (e.hash == h) {
        e.q = q;
        return;
    };
    for (&quirk_tbl) |*e| if (e.hash == 0) {
        e.* = .{ .hash = h, .q = q };
        return;
    };
    quirk_tbl[0] = .{ .hash = h, .q = q }; // table full — recycle slot 0 rather than lose the newest lesson
}

fn quirkFor(io: std.Io, model: []const u8) Quirk {
    if (model.len == 0) return .{};
    const h = std.hash.Wyhash.hash(0x9e37, model);
    quirk_mtx.lockUncancelable(io);
    defer quirk_mtx.unlock(io);
    for (&quirk_tbl) |*e| if (e.hash == h) return e.q;
    return .{};
}

/// Read a PARAM-CONSTRAINT quirk out of a provider's error message (case-insensitive). null = not a
/// constraint we know how to heal. Seeded with the temperature rules: the observed Kimi "only 1 is allowed"
/// case (pin to 1) and the common reasoning-model "temperature unsupported" case (drop it). Pure — tested.
fn detectQuirk(msg: []const u8) ?Quirk {
    var lb: [220]u8 = undefined;
    const n = @min(msg.len, lb.len);
    const m = std.ascii.lowerString(lb[0..n], msg[0..n]);
    if (std.mem.indexOf(u8, m, "temperature") == null) return null;
    // pinned to a value: "only 1 is allowed", "must be 1", "only the default (1)", "equal to 1". Trailing
    // spaces on the "1" tokens keep them from matching "10"/"1.5" etc. (a word boundary without a regex).
    if (std.mem.indexOf(u8, m, "1 is allowed") != null or std.mem.indexOf(u8, m, "only 1 ") != null or
        std.mem.indexOf(u8, m, "must be 1 ") != null or std.mem.indexOf(u8, m, "must be 1.") != null or
        std.mem.indexOf(u8, m, "default (1)") != null or std.mem.indexOf(u8, m, "equal to 1") != null)
        return .{ .temp = .force, .temp_val = 1.0 };
    // rejected OUTRIGHT (not a range/clamp constraint): "does not support temperature", "temperature is not
    // supported", "unsupported". Deliberately NOT "cannot"/"not allowed" — those also phrase clamp limits
    // ("temperature cannot exceed 2"), where dropping the field is the wrong (and permanently-learned) fix.
    if (std.mem.indexOf(u8, m, "not support") != null or std.mem.indexOf(u8, m, "unsupported") != null or
        std.mem.indexOf(u8, m, "does not accept") != null)
        return .{ .temp = .drop };
    return null;
}

/// The model id inside a request body (`"model":"…"`), or null. Pure — tested.
fn bodyModel(body: []const u8) ?[]const u8 {
    const k = "\"model\":\"";
    const s = (std.mem.indexOf(u8, body, k) orelse return null) + k.len;
    const e = std.mem.indexOfScalarPos(u8, body, s, '"') orelse return null;
    return body[s..e];
}

/// Rewrite `body` to satisfy `q`; gpa-owned new body, or null when nothing would change (so no wasted
/// retry). Pure string surgery on the engine-built JSON (its shape is predictable). Tested.
fn applyQuirk(gpa: std.mem.Allocator, body: []const u8, q: Quirk) ?[]u8 {
    switch (q.temp) {
        .keep => return null,
        .force => {
            var vb: [24]u8 = undefined;
            // whole numbers clean ("1" not "1.00" — some providers demand exactly "1"). The >=0 and <1e6
            // bounds keep @intFromFloat from panicking in ReleaseSafe on a negative/huge value (matches
            // tempFragOwned); today temp_val is only ever 1.0, but a future detectQuirk case might differ.
            const vs = if (q.temp_val == @floor(q.temp_val) and q.temp_val >= 0 and q.temp_val < 1_000_000)
                std.fmt.bufPrint(&vb, "{d}", .{@as(u64, @intFromFloat(q.temp_val))}) catch return null
            else
                std.fmt.bufPrint(&vb, "{d:.2}", .{q.temp_val}) catch return null;
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(gpa); // frees the buffer on an early `return null`; toOwnedSlice empties `out` first, so success frees nothing
            if (std.mem.indexOf(u8, body, "\"temperature\":")) |ti| {
                const after = ti + "\"temperature\":".len;
                var e = after;
                while (e < body.len and body[e] != ',' and body[e] != '}') e += 1;
                if (std.mem.eql(u8, body[after..e], vs)) return null; // already the required value
                out.appendSlice(gpa, body[0..after]) catch return null;
                out.appendSlice(gpa, vs) catch return null;
                out.appendSlice(gpa, body[e..]) catch return null;
            } else {
                const close = std.mem.lastIndexOfScalar(u8, body, '}') orelse return null;
                out.appendSlice(gpa, body[0..close]) catch return null;
                out.appendSlice(gpa, ",\"temperature\":") catch return null;
                out.appendSlice(gpa, vs) catch return null;
                out.appendSlice(gpa, body[close..]) catch return null;
            }
            return out.toOwnedSlice(gpa) catch null;
        },
        .drop => {
            const ti = std.mem.indexOf(u8, body, "\"temperature\":") orelse return null; // nothing to drop
            var start = ti;
            var e = ti + "\"temperature\":".len;
            while (e < body.len and body[e] != ',' and body[e] != '}') e += 1;
            if (start > 0 and body[start - 1] == ',') {
                start -= 1; // consume the leading comma with the field
            } else if (e < body.len and body[e] == ',') {
                e += 1; // temperature was first → consume the trailing comma instead
            }
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(gpa); // frees the buffer on an early `return null`; toOwnedSlice empties `out` first, so success frees nothing
            out.appendSlice(gpa, body[0..start]) catch return null;
            out.appendSlice(gpa, body[e..]) catch return null;
            return out.toOwnedSlice(gpa) catch null;
        },
    }
}

/// On a provider error, try to heal a PARAM constraint: detect it, rewrite + retry ONCE, and learn the quirk
/// so future requests pre-apply it. Returns the healed Step, or null when the error is not a quirk we can fix.
fn healParamError(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, body: []const u8, err_text: []const u8) ?Step {
    const q = detectQuirk(err_text) orelse return null;
    const healed = applyQuirk(gpa, body, q) orelse return null;
    defer gpa.free(healed);
    if (bodyModel(body)) |m| learnQuirk(io, m, q); // remember for every future request to this model
    return completeBodyH(gpa, io, run_dir, tag, base_url, key, healed, false); // retry once, never re-heal
}

/// Effective temperature for `model` after any LEARNED quirk (<0 ⇒ omit the field).
fn effTemp(io: std.Io, model: []const u8, temperature: f32) f32 {
    const q = quirkFor(io, model);
    return switch (q.temp) {
        .force => q.temp_val,
        .drop => -1,
        .keep => temperature,
    };
}

/// Build the `,"temperature":N` body fragment for `model`, applying any learned quirk and emitting whole
/// numbers cleanly (some providers reject "1.00" where they demand exactly "1"). gpa-owned + freeable;
/// empty slice = omit the field (caller passed <0, or the model is known to reject temperature).
fn tempFragOwned(gpa: std.mem.Allocator, io: std.Io, model: []const u8, temperature: f32) []u8 {
    const t = effTemp(io, model, temperature);
    if (t < 0) return gpa.dupe(u8, "") catch @constCast("");
    var vb: [24]u8 = undefined;
    const vs = if (t == @floor(t) and t >= 0 and t < 1_000_000)
        std.fmt.bufPrint(&vb, "{d}", .{@as(u64, @intFromFloat(t))}) catch "1"
    else
        std.fmt.bufPrint(&vb, "{d:.2}", .{t}) catch "1";
    return std.fmt.allocPrint(gpa, ",\"temperature\":{s}", .{vs}) catch (gpa.dupe(u8, "") catch @constCast(""));
}

fn completeBody(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, body: []const u8) Step {
    return completeBodyH(gpa, io, run_dir, tag, base_url, key, body, true);
}

fn completeBodyH(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, body: []const u8, heal_ok: bool) Step {
    const t0 = std.Io.Timestamp.now(io, .real).nanoseconds;
    const r = post(gpa, io, run_dir, tag, base_url, key, body);
    const call_ms = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - t0, std.time.ns_per_ms);
    if (!r.ok) {
        // HTTP-level error (some providers return the constraint here, not in a JSON error field) — try to heal.
        if (heal_ok) {
            if (healParamError(gpa, io, run_dir, tag, base_url, key, body, r.content)) |s| {
                gpa.free(r.content);
                return s;
            }
        }
        return .{ .content = r.content, .reasoning = gpa.dupe(u8, "") catch @constCast(""), .calls = &.{}, .ok = false };
    }
    defer gpa.free(r.content);

    const Resp = struct {
        choices: []const struct {
            message: struct {
                content: ?[]const u8 = null,
                reasoning: ?[]const u8 = null,
                reasoning_content: ?[]const u8 = null,
                tool_calls: ?[]const struct {
                    id: []const u8 = "",
                    function: struct { name: []const u8 = "", arguments: []const u8 = "" },
                } = null,
            },
            finish_reason: ?[]const u8 = null,
        } = &.{},
        // Cache-hit reporting is provider-dialect: OpenAI nests usage.prompt_tokens_details.cached_tokens;
        // DeepSeek reports top-level usage.prompt_cache_hit_tokens; Moonshot/Kimi top-level usage.cached_tokens.
        // Parse all three so "is provider prompt caching actually working?" is answerable from our own meters.
        usage: ?struct {
            prompt_tokens: u64 = 0,
            completion_tokens: u64 = 0,
            prompt_cache_hit_tokens: u64 = 0,
            cached_tokens: u64 = 0,
            prompt_tokens_details: ?struct { cached_tokens: u64 = 0 } = null,
        } = null,
        @"error": ?struct { message: []const u8 = "" } = null,
    };
    const parsed = std.json.parseFromSlice(Resp, gpa, r.content, .{ .ignore_unknown_fields = true }) catch
        return stepErr(gpa, std.fmt.allocPrint(gpa, "bad LLM response: {s}", .{r.content[0..@min(r.content.len, 300)]}) catch "unparseable response");
    defer parsed.deinit();
    if (parsed.value.usage) |u| {
        const nested: u64 = if (u.prompt_tokens_details) |d| d.cached_tokens else 0;
        const cached = @max(nested, @max(u.prompt_cache_hit_tokens, u.cached_tokens));
        if (isLocal(base_url)) {
            _ = tokens_in_free.fetchAdd(u.prompt_tokens, .monotonic);
            _ = tokens_out_free.fetchAdd(u.completion_tokens, .monotonic);
        } else {
            _ = tokens_in.fetchAdd(u.prompt_tokens, .monotonic);
            _ = tokens_out.fetchAdd(u.completion_tokens, .monotonic);
            _ = tokens_cached.fetchAdd(cached, .monotonic);
        }
        meterTL(u.prompt_tokens, u.completion_tokens, cached);
        _ = calls_made.fetchAdd(1, .monotonic);
        // WHERE THE SECONDS GO — one line per completed call: purpose tag, provider latency, and the token
        // split (cached = the provider-cache share of `in`). This is the flight recorder for "some models
        // run incredibly slow": provider wall-time per call vs. our own engine gaps between the lines.
        std.log.info("llm[{s}] {d}ms in={d} (cached {d}) out={d}", .{ tag, call_ms, u.prompt_tokens, cached, u.completion_tokens });
    } else {
        std.log.info("llm[{s}] {d}ms (no usage in response)", .{ tag, call_ms });
    }
    if (parsed.value.@"error") |e| {
        // a JSON error field (HTTP 200 with an {"error":…} body, as Kimi returns) — try to heal the constraint.
        if (heal_ok) {
            if (healParamError(gpa, io, run_dir, tag, base_url, key, body, e.message)) |s| return s;
        }
        return stepErr(gpa, std.fmt.allocPrint(gpa, "provider error: {s}", .{e.message}) catch "provider error");
    }
    if (parsed.value.choices.len == 0) return stepErr(gpa, "no choices in LLM response");
    const msg = parsed.value.choices[0].message;

    var calls: std.ArrayListUnmanaged(ToolCall) = .empty;
    if (msg.tool_calls) |tcs| {
        for (tcs) |tc| {
            calls.append(gpa, .{
                .id = gpa.dupe(u8, tc.id) catch continue,
                .name = gpa.dupe(u8, tc.function.name) catch continue,
                .args = gpa.dupe(u8, tc.function.arguments) catch continue,
            }) catch {};
        }
    }
    const content = gpa.dupe(u8, msg.content orelse "") catch return stepErr(gpa, "oom");
    const reasoning = gpa.dupe(u8, msg.reasoning orelse msg.reasoning_content orelse "") catch return stepErr(gpa, "oom");
    const trunc = if (parsed.value.choices[0].finish_reason) |fr| std.mem.eql(u8, fr, "length") else false;
    return .{ .content = content, .reasoning = reasoning, .calls = calls.toOwnedSlice(gpa) catch &.{}, .ok = true, .truncated = trunc };
}

// ============================================================================
// STREAMING (chat only) — an ADDITIVE path parallel to complete(); complete() / completeBody() /
// completeOllamaNative() above are UNTOUCHED. Asks the backend for "stream":true, curl-streams the SSE
// (hosted) / NDJSON (Ollama native) response to a scratch file that we TAIL line-by-line, firing on_delta
// for each content/reasoning chunk, and accumulates the full content + reasoning (+ tool_calls) into the
// SAME Step complete() returns. ANY streaming trouble (spawn/setup failure, an error line, a body that
// never streamed, or a hosted SSE tool call whose fragments can't be reassembled) FALLS BACK to complete():
// the turn still works, it just doesn't type out.
// ============================================================================

/// Which channel a streamed delta belongs to. `.content` is the visible reply; `.reasoning`
/// is the hidden thinking channel (reasoning models).
/// .tool_progress carries a short human line ("writing index.html — 12 KB...") fired every ~TP_NOTIFY_BYTES
/// while a hosted stream composes a tool call's arguments — the ONE generation phase with no content/reasoning
/// deltas, which otherwise leaves the user staring at a silent status for the whole compose (observed: a 27s+
/// write_file with nothing on screen but "writing...").
pub const DeltaKind = enum { content, reasoning, tool_progress };

const STREAM_STAT = "\n__VEILSTAT__"; // curl -w appends this + the 3-digit HTTP code once the transfer ends

/// The HTTP status curl appended as "\n__VEILSTAT__<code>" at the very end of the sink file (null if absent). A
/// small POSITIONAL tail read — the sentinel is the last ~16 bytes, and the stream body can be many MB, so this
/// must not read the whole file. statFile for the size (a fresh handle's length() reads 0 on Windows/Io).
fn trailingStatusCode(io: std.Io, path: []const u8) ?u16 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    const size: usize = std.math.cast(usize, st.size) orelse return null;
    if (size == 0) return null;
    const want = @min(size, @as(usize, 128));
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [128]u8 = undefined;
    const n = f.readPositionalAll(io, buf[0..want], size - want) catch return null;
    const tail = buf[0..n];
    const at = std.mem.lastIndexOf(u8, tail, "__VEILSTAT__") orelse return null;
    const after = tail[at + "__VEILSTAT__".len ..];
    var end: usize = 0;
    while (end < after.len and std.ascii.isDigit(after[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u16, after[0..end], 10) catch null;
}

/// A hosted (OpenAI/DeepSeek) SSE tool call assembled across streamed deltas. The first delta for an `index`
/// carries id + function.name (+ maybe an args head); later deltas append raw fragments to `args`. Assembling
/// these lets a hosted tool-calling step return its call(s) FROM THE STREAM instead of paying a second
/// complete() inference to reparse.
const ToolAccum = struct {
    index: i64,
    id: std.ArrayListUnmanaged(u8) = .empty,
    name: std.ArrayListUnmanaged(u8) = .empty,
    args: std.ArrayListUnmanaged(u8) = .empty,
    fn deinit(a: *ToolAccum, gpa: std.mem.Allocator) void {
        a.id.deinit(gpa);
        a.name.deinit(gpa);
        a.args.deinit(gpa);
    }
};

/// Emit one .tool_progress line per this many streamed tool-args bytes (~2-4 updates on a typical 20KB
/// write_file — enough to show life without spamming status frames).
const TP_NOTIFY_BYTES: usize = 6 << 10;

// REASONING-CHANNEL DEGENERATION armor. Reasoning models sometimes loop mid-think, emitting one sentence
// over and over (observed live: ~30 identical lines filling the chat). The model usually recovers, so the
// stream filter shows the first few repeats, condenses the rest behind one marker, and resumes live the
// moment the loop breaks — every client sees a clean stream because the frames themselves are filtered. A
// loop that runs absurdly long never recovers usefully: the circuit breaker kills the generation (the caller
// gets the partial and the drive loop takes another run) instead of paying for tokens forever.
const RSN_REPEAT_SHOW: usize = 3; // identical lines shown live before the condenser engages
const RSN_LINE_FORCE: usize = 512; // a newline-less "line" is force-completed at this length so loops without \n still compare
const RSN_REPEAT_ABORT: usize = 120; // consecutive repeats that trip the circuit breaker
const RSN_LOOP_ABORT_BYTES: usize = 48 << 10; // or this many swallowed loop bytes

/// Human verb for a composing tool call's progress line.
fn toolVerb(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "write_file")) return "writing";
    if (std.mem.eql(u8, name, "edit_file")) return "editing";
    if (std.mem.eql(u8, name, "read_file")) return "preparing to read";
    if (name.len == 0) return "composing a tool call";
    return "composing";
}

/// Pull the "path" value out of a PARTIALLY-streamed args JSON head (path is emitted before the big content
/// value in practice). Display-only best effort: looks in the first 300 bytes, takes the raw span to the next
/// quote (an escaped path would clip — fine for a status line).
fn argsPathHead(args: []const u8) ?[]const u8 {
    const head = args[0..@min(args.len, 300)];
    const at = std.mem.indexOf(u8, head, "\"path\"") orelse return null;
    var i = at + "\"path\"".len;
    while (i < head.len and (head[i] == ' ' or head[i] == ':' or head[i] == '\t')) i += 1;
    if (i >= head.len or head[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < head.len and head[i] != '"' and head[i] != '\\') i += 1;
    if (i <= start) return null;
    return head[start..i];
}

const StreamState = struct {
    native: bool,
    ctx: *anyopaque,
    on_delta: *const fn (ctx: *anyopaque, kind: DeltaKind, text: []const u8) void,
    content: std.ArrayListUnmanaged(u8) = .empty,
    reasoning: std.ArrayListUnmanaged(u8) = .empty,
    carry: std.ArrayListUnmanaged(u8) = .empty, // partial trailing line held between polls
    tool_line: std.ArrayListUnmanaged(u8) = .empty, // the native NDJSON line that carried tool_calls (owned)
    tool_accum: std.ArrayListUnmanaged(ToolAccum) = .empty, // hosted SSE tool calls assembled by index (see ToolAccum)
    tp_total: usize = 0, // total tool-args bytes streamed so far (drives the .tool_progress throttle)
    tp_notified: usize = 0, // tp_total at the last .tool_progress notification
    rsn_line: std.ArrayListUnmanaged(u8) = .empty, // current (partial) reasoning line being assembled
    rsn_last: std.ArrayListUnmanaged(u8) = .empty, // last completed reasoning line (loop comparison target)
    rsn_repeats: usize = 0, // consecutive completed lines identical to rsn_last
    rsn_suppress: bool = false, // inside a detected loop: swallow instead of forward
    rsn_looped: usize = 0, // bytes swallowed while suppressing (circuit-breaker budget)
    runaway: bool = false, // the loop tripped the circuit breaker — the poll loop aborts the generation
    saw_tool_calls: bool = false,
    truncated: bool = false,
    failed: bool = false,
    done: bool = false,
    metered: bool = false,
    p_in: u64 = 0,
    p_out: u64 = 0,
    p_cached: u64 = 0,

    fn deinit(st: *StreamState, gpa: std.mem.Allocator) void {
        st.content.deinit(gpa);
        st.reasoning.deinit(gpa);
        st.carry.deinit(gpa);
        st.tool_line.deinit(gpa);
        st.rsn_line.deinit(gpa);
        st.rsn_last.deinit(gpa);
        for (st.tool_accum.items) |*a| a.deinit(gpa);
        st.tool_accum.deinit(gpa);
    }
    /// Merge one streamed hosted tool-call fragment (from an SSE delta) into the accumulator, keyed by `index`.
    fn accumToolCall(st: *StreamState, gpa: std.mem.Allocator, index: i64, id: ?[]const u8, name: ?[]const u8, args: ?[]const u8) void {
        st.saw_tool_calls = true;
        var slot: *ToolAccum = for (st.tool_accum.items) |*a| {
            if (a.index == index) break a;
        } else blk: {
            st.tool_accum.append(gpa, .{ .index = index }) catch return;
            break :blk &st.tool_accum.items[st.tool_accum.items.len - 1];
        };
        if (id) |v| if (v.len > 0 and slot.id.items.len == 0) slot.id.appendSlice(gpa, v) catch {};
        if (name) |v| if (v.len > 0 and slot.name.items.len == 0) slot.name.appendSlice(gpa, v) catch {};
        if (args) |v| {
            slot.args.appendSlice(gpa, v) catch {};
            st.tp_total += v.len;
        }
        // PROGRESS: while a big tool call composes (a 20KB write_file takes many seconds with ZERO content
        // deltas), tell the consumer what's being written every ~TP_NOTIFY_BYTES so the user isn't staring at
        // a silent status. The consumer surfaces it as a status line, never as transcript content.
        if (st.tp_total - st.tp_notified >= TP_NOTIFY_BYTES) {
            st.tp_notified = st.tp_total;
            var lb: [200]u8 = undefined;
            const verb = toolVerb(slot.name.items);
            const line = if (argsPathHead(slot.args.items)) |p|
                std.fmt.bufPrint(&lb, "{s} {s} — {d} KB...", .{ verb, p[0..@min(p.len, 120)], st.tp_total / 1024 }) catch return
            else
                std.fmt.bufPrint(&lb, "{s} — {d} KB...", .{ verb, st.tp_total / 1024 }) catch return;
            st.on_delta(st.ctx, .tool_progress, line);
        }
    }
    /// Emit one non-empty delta (borrowed — the callback copies it) and accumulate it. Reasoning routes
    /// through the degeneration filter; content passes straight through.
    fn fire(st: *StreamState, gpa: std.mem.Allocator, kind: DeltaKind, text: []const u8) void {
        if (text.len == 0) return;
        if (kind == .reasoning) return st.fireReasoning(gpa, text);
        st.forward(gpa, kind, text);
    }

    /// The raw emit: callback + accumulate. st.reasoning mirrors what was FORWARDED (the condensed stream),
    /// so every downstream consumer of the assembled reasoning — the engine's non-streamed fallback emit
    /// included — inherits the filtering.
    fn forward(st: *StreamState, gpa: std.mem.Allocator, kind: DeltaKind, text: []const u8) void {
        if (text.len == 0) return;
        st.on_delta(st.ctx, kind, text);
        switch (kind) {
            .content => st.content.appendSlice(gpa, text) catch {},
            .reasoning => st.reasoning.appendSlice(gpa, text) catch {},
            .tool_progress => {}, // status-only; emitted directly from accumToolCall, never accumulated
        }
    }

    /// DEGENERATION FILTER: assemble reasoning deltas into lines; identical consecutive lines forward live
    /// only up to RSN_REPEAT_SHOW, then a single "(reasoning repeating — condensed…)" marker replaces the
    /// loop; the first differing line ends suppression and is forwarded whole (it streamed while swallowed).
    fn fireReasoning(st: *StreamState, gpa: std.mem.Allocator, text: []const u8) void {
        var rest = text;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const take = if (nl) |i| i + 1 else rest.len;
            const chunk = rest[0..take];
            rest = rest[take..];
            st.rsn_line.appendSlice(gpa, std.mem.trimEnd(u8, chunk, "\n")) catch {};
            if (!st.rsn_suppress and st.rsn_repeats < RSN_REPEAT_SHOW) {
                st.forward(gpa, .reasoning, chunk); // normal case: live type-out, fragment granularity
            } else {
                st.rsn_looped += chunk.len;
                if (st.rsn_repeats >= RSN_REPEAT_ABORT or st.rsn_looped >= RSN_LOOP_ABORT_BYTES) st.runaway = true;
            }
            if (nl != null or st.rsn_line.items.len > RSN_LINE_FORCE) st.reasoningLineDone(gpa);
        }
    }

    fn reasoningLineDone(st: *StreamState, gpa: std.mem.Allocator) void {
        defer st.rsn_line.clearRetainingCapacity();
        const line = std.mem.trim(u8, st.rsn_line.items, " \r\t");
        if (line.len == 0) return; // blank lines neither extend nor break a loop
        if (std.mem.eql(u8, line, st.rsn_last.items)) {
            st.rsn_repeats += 1;
            if (!st.rsn_suppress and st.rsn_repeats >= RSN_REPEAT_SHOW) {
                st.rsn_suppress = true;
                st.forward(gpa, .reasoning, "\n(reasoning repeating - condensed...)\n");
            }
            return;
        }
        st.rsn_last.clearRetainingCapacity();
        st.rsn_last.appendSlice(gpa, line) catch {};
        st.rsn_repeats = 0;
        if (st.rsn_suppress) {
            st.rsn_suppress = false;
            st.rsn_looped = 0;
            // this line broke the loop but streamed while swallowed — forward it whole so the resume is seamless
            st.forward(gpa, .reasoning, line);
            st.forward(gpa, .reasoning, "\n");
        }
    }
};

/// Append newly-arrived stream bytes; process every COMPLETE line (SSE or NDJSON), keep the trailing
/// partial line in `carry` for the next feed. Each line is a whole JSON object (SSE `data: {…}` payload or
/// one NDJSON object), so std.json parses it directly — no partial-fragment hand-parsing.
fn feedStream(st: *StreamState, gpa: std.mem.Allocator, new_bytes: []const u8) void {
    st.carry.appendSlice(gpa, new_bytes) catch return;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, st.carry.items, start, '\n')) |nl| {
        const line = std.mem.trimEnd(u8, st.carry.items[start..nl], "\r");
        handleStreamLine(st, gpa, line);
        start = nl + 1;
        if (st.done) break;
    }
    if (start > 0) {
        const rem = st.carry.items.len - start;
        if (rem > 0) std.mem.copyForwards(u8, st.carry.items[0..rem], st.carry.items[start..]);
        st.carry.shrinkRetainingCapacity(rem);
    }
}

fn handleStreamLine(st: *StreamState, gpa: std.mem.Allocator, line: []const u8) void {
    if (st.native) handleNativeStreamLine(st, gpa, line) else handleSseStreamLine(st, gpa, line);
}

/// Move `buf[from..]` to the front, shrink, and return the new length. Used by the streaming poll loop to keep only
/// the still-unfed carry (a straddled end-marker prefix) in the accumulator between polls.
fn keepFront(buf: *std.ArrayListUnmanaged(u8), from: usize) usize {
    const rem = buf.items.len - from;
    if (from > 0 and rem > 0) std.mem.copyForwards(u8, buf.items[0..rem], buf.items[from..]);
    buf.shrinkRetainingCapacity(rem);
    return rem;
}

/// Longest k (>=1) such that the last k bytes of `buf` equal `mark[0..k]` — i.e. `buf` ends in a strict prefix of
/// `mark`. Returns 0 if none. The streaming loop holds these bytes back so a curl `-w` end-marker straddling a read
/// boundary is never fed to feedStream as body (which would resurface as a garbage trailing line).
fn markPrefixSuffix(buf: []const u8, mark: []const u8) usize {
    var k = @min(buf.len, mark.len - 1);
    while (k > 0) : (k -= 1) {
        if (std.mem.eql(u8, buf[buf.len - k ..], mark[0..k])) return k;
    }
    return 0;
}

/// Ollama native /api/chat NDJSON: {"message":{"content":"…","thinking":"…","tool_calls":[…]},"done":bool,…}.
fn handleNativeStreamLine(st: *StreamState, gpa: std.mem.Allocator, line: []const u8) void {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] != '{') return;
    const P = struct {
        message: ?struct {
            content: ?[]const u8 = null,
            thinking: ?[]const u8 = null,
            reasoning: ?[]const u8 = null,
            tool_calls: ?[]const std.json.Value = null,
        } = null,
        done: bool = false,
        done_reason: ?[]const u8 = null,
        eval_count: ?u64 = null,
        prompt_eval_count: ?u64 = null,
        @"error": ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(P, gpa, t, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    if (parsed.value.@"error") |_| {
        st.failed = true;
        st.done = true;
        return;
    }
    if (parsed.value.message) |m| {
        if (m.thinking) |th| st.fire(gpa, .reasoning, th);
        if (m.reasoning) |r| st.fire(gpa, .reasoning, r);
        if (m.content) |c| st.fire(gpa, .content, c);
        if (m.tool_calls) |tcs| {
            if (tcs.len > 0) {
                // Ollama emits the parsed tool_calls array complete in a single NDJSON line — capture that
                // line; parseNativeToolCalls reconstructs the calls at the end.
                st.saw_tool_calls = true;
                st.tool_line.clearRetainingCapacity();
                st.tool_line.appendSlice(gpa, t) catch {};
            }
        }
    }
    if (parsed.value.eval_count) |ec| {
        st.p_out = ec;
        st.p_in = parsed.value.prompt_eval_count orelse 0;
        st.metered = true;
    }
    if (parsed.value.done_reason) |dr| {
        if (std.mem.eql(u8, dr, "length")) st.truncated = true;
    }
    if (parsed.value.done) st.done = true;
}

/// OpenAI SSE: `data: {"choices":[{"delta":{"content":"…","reasoning":"…"}}]}` and `data: [DONE]`.
/// `stream_options.include_usage` makes the final `data:` chunk carry a `usage` block for the token meter.
fn handleSseStreamLine(st: *StreamState, gpa: std.mem.Allocator, line: []const u8) void {
    if (!std.mem.startsWith(u8, line, "data:")) return;
    const payload = std.mem.trim(u8, line[5..], " \t\r");
    if (payload.len == 0) return;
    if (std.mem.eql(u8, payload, "[DONE]")) {
        st.done = true;
        return;
    }
    if (payload[0] != '{') return;
    const P = struct {
        choices: []const struct {
            delta: ?struct {
                content: ?[]const u8 = null,
                reasoning: ?[]const u8 = null,
                reasoning_content: ?[]const u8 = null,
                // Streamed hosted tool calls arrive as fragments: the first for an `index` carries id + name,
                // later ones append raw `arguments` string pieces. Typed so we can ASSEMBLE (not just flag) them.
                tool_calls: ?[]const struct {
                    index: i64 = 0,
                    id: ?[]const u8 = null,
                    function: ?struct { name: ?[]const u8 = null, arguments: ?[]const u8 = null } = null,
                } = null,
            } = null,
            finish_reason: ?[]const u8 = null,
        } = &.{},
        usage: ?struct {
            prompt_tokens: u64 = 0,
            completion_tokens: u64 = 0,
            prompt_cache_hit_tokens: u64 = 0, // DeepSeek's dialect
            cached_tokens: u64 = 0, // Moonshot/Kimi's dialect
            prompt_tokens_details: ?struct { cached_tokens: u64 = 0 } = null,
        } = null,
        @"error": ?struct { message: []const u8 = "" } = null,
    };
    const parsed = std.json.parseFromSlice(P, gpa, payload, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    if (parsed.value.@"error") |_| {
        st.failed = true;
        st.done = true;
        return;
    }
    for (parsed.value.choices) |ch| {
        if (ch.delta) |d| {
            if (d.reasoning) |r| st.fire(gpa, .reasoning, r);
            if (d.reasoning_content) |r| st.fire(gpa, .reasoning, r);
            if (d.content) |c| st.fire(gpa, .content, c);
            if (d.tool_calls) |tcs| {
                for (tcs) |tc| {
                    const fname = if (tc.function) |f| f.name else null;
                    const fargs = if (tc.function) |f| f.arguments else null;
                    st.accumToolCall(gpa, tc.index, tc.id, fname, fargs);
                }
            }
        }
        if (ch.finish_reason) |fr| {
            if (std.mem.eql(u8, fr, "length")) st.truncated = true;
            if (std.mem.eql(u8, fr, "tool_calls")) st.saw_tool_calls = true;
        }
    }
    if (parsed.value.usage) |u| {
        st.p_in = u.prompt_tokens;
        st.p_out = u.completion_tokens;
        const nested: u64 = if (u.prompt_tokens_details) |dd| dd.cached_tokens else 0;
        st.p_cached = @max(nested, @max(u.prompt_cache_hit_tokens, u.cached_tokens));
        st.metered = true;
    }
}

/// Reconstruct the native tool call(s) from the captured NDJSON line — arguments re-serialized to a JSON
/// string, exactly like parseOllamaNative. Empty slice on none/unparseable → caller falls back to complete().
fn parseNativeToolCalls(gpa: std.mem.Allocator, raw: []const u8) []ToolCall {
    const Resp = struct {
        message: ?struct {
            tool_calls: ?[]const struct {
                function: struct { name: []const u8 = "", arguments: std.json.Value = .null },
            } = null,
        } = null,
    };
    const parsed = std.json.parseFromSlice(Resp, gpa, raw, .{ .ignore_unknown_fields = true }) catch return &.{};
    defer parsed.deinit();
    const msg = parsed.value.message orelse return &.{};
    const tcs = msg.tool_calls orelse return &.{};
    var calls: std.ArrayListUnmanaged(ToolCall) = .empty;
    for (tcs) |tc| {
        const args = std.json.Stringify.valueAlloc(gpa, tc.function.arguments, .{}) catch continue;
        calls.append(gpa, .{
            .id = gpa.dupe(u8, "") catch {
                gpa.free(args);
                continue;
            },
            .name = gpa.dupe(u8, tc.function.name) catch {
                gpa.free(args);
                continue;
            },
            .args = args,
        }) catch {
            gpa.free(args);
        };
    }
    return calls.toOwnedSlice(gpa) catch &.{};
}

fn freeCalls(gpa: std.mem.Allocator, calls: []ToolCall) void {
    for (calls) |c| {
        gpa.free(c.id);
        gpa.free(c.name);
        gpa.free(c.args);
    }
    gpa.free(calls);
}

/// Build ToolCall[] from the hosted SSE fragments assembled in st.tool_accum (see ToolAccum). A fragment with no
/// function name is dropped (unusable); empty arguments become "{}". Owned slice (freeCalls to release); empty on
/// none, so streamAttempt falls back to complete() to reparse. id + name + args carried through verbatim (id
/// matters for the hosted tool-result correlation the agentic loop builds).
fn reconstructSseToolCalls(gpa: std.mem.Allocator, st: *const StreamState) []ToolCall {
    var calls: std.ArrayListUnmanaged(ToolCall) = .empty;
    for (st.tool_accum.items) |a| {
        if (a.name.items.len == 0) continue; // no function name → not a usable call
        const args_src = if (a.args.items.len > 0) a.args.items else "{}";
        // The streamed path TRUSTS these bytes, so validate the assembled arguments are WELL-FORMED JSON. A
        // garbled assembly — e.g. a non-spec provider that omits `index` and folds two parallel calls onto one
        // slot, concatenating their args into invalid JSON — is dropped, so the step falls back to complete()
        // rather than executing a tool with corrupt args.
        if (!(std.json.validate(gpa, args_src) catch false)) continue;
        const args = gpa.dupe(u8, args_src) catch continue;
        const name = gpa.dupe(u8, a.name.items) catch {
            gpa.free(args);
            continue;
        };
        const id = gpa.dupe(u8, a.id.items) catch {
            gpa.free(args);
            gpa.free(name);
            continue;
        };
        calls.append(gpa, .{ .id = id, .name = name, .args = args }) catch {
            gpa.free(args);
            gpa.free(name);
            gpa.free(id);
        };
    }
    return calls.toOwnedSlice(gpa) catch &.{};
}

/// Fold a streamed step's token counts into the process meters — the SAME local/hosted split completeBody
/// and parseOllamaNative use, so streamed chat steps still contribute to REAL cost reporting.
fn meterStream(st: *const StreamState, local: bool) void {
    if (!st.metered) return;
    if (local) {
        _ = tokens_in_free.fetchAdd(st.p_in, .monotonic);
        _ = tokens_out_free.fetchAdd(st.p_out, .monotonic);
    } else {
        _ = tokens_in.fetchAdd(st.p_in, .monotonic);
        _ = tokens_out.fetchAdd(st.p_out, .monotonic);
        _ = tokens_cached.fetchAdd(st.p_cached, .monotonic);
    }
    meterTL(st.p_in, st.p_out, st.p_cached);
    _ = calls_made.fetchAdd(1, .monotonic);
    // the streamed twin of completeBodyH's flight-recorder line (latency reads off the log timestamps here)
    std.log.info("llm[stream] in={d} (cached {d}) out={d}", .{ st.p_in, st.p_cached, st.p_out });
}

/// STREAMING agentic step (chat only). Same request as complete() but "stream":true; curl streams the
/// response to a scratch file that we tail, firing on_delta(ctx, .content|.reasoning, chunk) for each delta
/// and accumulating the full Step (content + reasoning + tool_calls). ANY failure — or a case we can't stream
/// cleanly — FALLS BACK to complete(), and on_delta never fires. The returned Step is caller-owned
/// (step.deinit) and identical in shape to complete()'s.
pub fn completeStream(
    gpa: std.mem.Allocator,
    io: std.Io,
    run_dir: []const u8,
    tag: []const u8,
    base_url: []const u8,
    key: []const u8,
    model: []const u8,
    messages_json: []const u8,
    tools_json: []const u8,
    max_tokens: u32,
    temperature: f32,
    ctx: *anyopaque,
    on_delta: *const fn (ctx: *anyopaque, kind: DeltaKind, text: []const u8) void,
    // Optional cooperative ABORT: the poll loop calls this with `ctx`; returning true kills the curl child and
    // returns the PARTIAL stream immediately (NOT a fallback to complete(), which would re-run the whole
    // inference). This is what lets a chat Stop interrupt a long in-flight streaming reply promptly instead of
    // waiting out the whole generation. null ⇒ never aborts.
    should_abort: ?*const fn (ctx: *anyopaque) bool,
) Step {
    return streamAttempt(gpa, io, run_dir, tag, base_url, key, model, messages_json, tools_json, max_tokens, temperature, ctx, on_delta, should_abort) orelse
        complete(gpa, io, run_dir, tag, base_url, key, model, messages_json, tools_json, max_tokens, temperature);
}

/// The streaming body. Returns a Step on a clean stream, or null to signal "fall back to complete()".
fn streamAttempt(
    gpa: std.mem.Allocator,
    io: std.Io,
    run_dir: []const u8,
    tag: []const u8,
    base_url: []const u8,
    key: []const u8,
    model: []const u8,
    messages_json: []const u8,
    tools_json: []const u8,
    max_tokens: u32,
    temperature: f32,
    ctx: *anyopaque,
    on_delta: *const fn (ctx: *anyopaque, kind: DeltaKind, text: []const u8) void,
    should_abort: ?*const fn (ctx: *anyopaque) bool,
) ?Step {
    const native = isOllama(base_url);
    const local = isLocal(base_url);

    // ---- URL (native /api/chat, else OpenAI /chat/completions) ----
    const url = blk: {
        if (native) {
            var root = trimSlash(base_url);
            if (std.mem.endsWith(u8, root, "/v1")) root = root[0 .. root.len - 3];
            break :blk std.fmt.allocPrint(gpa, "{s}/api/chat", .{root}) catch return null;
        }
        break :blk std.fmt.allocPrint(gpa, "{s}/chat/completions", .{trimSlash(base_url)}) catch return null;
    };
    defer gpa.free(url);

    // ---- body: the SAME shape complete() builds, plus "stream":true (and, on the hosted path,
    // stream_options.include_usage so the terminal chunk still carries the token meter). ----
    const temp_frag = tempFragOwned(gpa, io, model, temperature); // learned-quirk aware (streamed path)
    defer gpa.free(temp_frag);

    const body = blk: {
        if (native) {
            const np: u32 = if (isThinking(model)) @max(max_tokens, NATIVE_THINK_TOKENS) else max_tokens;
            const ctxw = effectiveCtx();
            break :blk (if (tools_json.len > 0)
                std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"tools\":[{s}],\"stream\":true,\"keep_alive\":\"{s}\",\"options\":{{\"num_predict\":{d},\"num_ctx\":{d}{s}}}}}", .{ model, messages_json, tools_json, OLLAMA_KEEP_ALIVE, np, ctxw, temp_frag })
            else
                std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":true,\"keep_alive\":\"{s}\",\"options\":{{\"num_predict\":{d},\"num_ctx\":{d}{s}}}}}", .{ model, messages_json, OLLAMA_KEEP_ALIVE, np, ctxw, temp_frag })) catch return null;
        }
        const mt = effTokens(base_url, model, max_tokens);
        break :blk (if (tools_json.len > 0)
            std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"tools\":[{s}],\"stream\":true,\"stream_options\":{{\"include_usage\":true}}{s},\"max_tokens\":{d}}}", .{ model, messages_json, tools_json, temp_frag, mt })
        else
            std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":true,\"stream_options\":{{\"include_usage\":true}}{s},\"max_tokens\":{d}}}", .{ model, messages_json, temp_frag, mt })) catch return null;
    };
    defer gpa.free(body);

    // ---- scratch files (per-tag, so concurrent callers don't clobber) ----
    const reqpath = std.fmt.allocPrint(gpa, "{s}/.streamreq{s}{s}.json", .{ run_dir, if (tag.len > 0) "-" else "", tag }) catch return null;
    defer gpa.free(reqpath);
    const cfgpath = std.fmt.allocPrint(gpa, "{s}/.streamcfg{s}{s}", .{ run_dir, if (tag.len > 0) "-" else "", tag }) catch return null;
    defer gpa.free(cfgpath);
    const outpath = std.fmt.allocPrint(gpa, "{s}/.stream{s}{s}.sse", .{ run_dir, if (tag.len > 0) "-" else "", tag }) catch return null;
    defer gpa.free(outpath);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = reqpath, .data = body }) catch return null;
    // Engine convention: the key rides a curl config file (-K), never the argv.
    const cfg = if (key.len > 0)
        std.fmt.allocPrint(gpa, "header = \"Authorization: Bearer {s}\"\nheader = \"Content-Type: application/json\"\n", .{key}) catch return null
    else
        gpa.dupe(u8, "header = \"Content-Type: application/json\"\n") catch return null;
    defer gpa.free(cfg);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgpath, .data = cfg }) catch return null;

    const data_at = std.fmt.allocPrint(gpa, "@{s}", .{reqpath}) catch return null;
    defer gpa.free(data_at);

    // HOSTED-provider pacing: honor any active per-host 429 cooldown + the optional RPM cap before this request
    // reaches the wire. Local backends never rate-limit. (A fallback to complete() re-paces at its own post().)
    if (!local) rate.acquire(io, base_url);

    const stream_max_s: u32 = if (local) 240 else 90; // parity with post()/postUrl's --max-time
    var tt_buf: [16]u8 = undefined;
    const tt = std.fmt.bufPrint(&tt_buf, "{d}", .{stream_max_s}) catch "240";

    var sink = std.Io.Dir.cwd().createFile(io, outpath, .{ .truncate = true }) catch return null;
    // -w appends STREAM_STAT + the HTTP code after the transfer so the tail loop sees curl exit.
    const argv: []const []const u8 = &.{ "curl", "-sS", "-N", "--connect-timeout", "20", "--max-time", tt, "-K", cfgpath, "--data-binary", data_at, "-w", STREAM_STAT ++ "%{http_code}", url };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = sink },
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {
        sink.close(io);
        return null;
    };
    sink.close(io); // curl holds its own inherited handle; we read the file back independently
    defer child.kill(io); // kill terminates AND reaps in one idempotent call (mirrors desk.finish)

    var st = StreamState{ .native = native, .ctx = ctx, .on_delta = on_delta };
    defer st.deinit(gpa);

    // ---- tail the sink until curl exits (STAT sentinel) or the stream self-completes ----
    // POSITIONAL read from a byte cursor — NOT a whole-file re-read every poll. curl only ever APPENDS to the
    // .sse scratch, so a growing `offset` stays valid; each poll reads just the new bytes into a reused buffer
    // and feeds them to feedStream (which keeps its own partial-line carry). This is O(total_bytes), not the old
    // O(final_size^2) read+rescan, and it has no fixed size cap: a native reasoning stream at NATIVE_THINK_TOKENS
    // can exceed 8MB, which the old readFileAlloc misread as "file not created yet" → spin to the wall and return
    // a silently truncated partial. curl -w appends "\n__VEILSTAT__<http_code>"; we scan for the core MARK
    // "__VEILSTAT__" (never present in SSE/NDJSON data) so a body-terminating '\n' feeds with zero delay, and
    // hold back only a trailing suffix that is a strict prefix of MARK (a sentinel straddling a read boundary).
    const MARK = "__VEILSTAT__";
    const read_cap: usize = 256 << 10;
    const rbuf = gpa.alloc(u8, read_cap) catch return null;
    defer gpa.free(rbuf);
    var vbuf: std.ArrayListUnmanaged(u8) = .empty; // holds only the still-unfed carry (a straddled MARK prefix)
    defer vbuf.deinit(gpa);
    var offset: usize = 0;
    var last_fed: u8 = 0; // last body byte handed to feedStream — the left-context for a marker landing at vbuf[0]
    var aborted = false;
    var sentinel = false;
    const wall: i64 = @as(i64, stream_max_s) + 30;
    const t0 = std.Io.Timestamp.now(io, .real).toSeconds();
    while (true) {
        // COOPERATIVE ABORT (chat Stop): kill the in-flight stream promptly instead of waiting out generation. We
        // still feed whatever already arrived (st holds it), so the user keeps the streamed text.
        if (should_abort) |ab| if (ab(ctx)) {
            aborted = true;
            break;
        };
        // CIRCUIT BREAKER: a reasoning loop past the runaway thresholds never recovers usefully — stop paying
        // for its tokens. Same partial-return path as a user Stop; the drive loop simply takes another run.
        if (st.runaway) {
            std.log.scoped(.llm).warn("stream: reasoning runaway ({d} repeats, {d} looped bytes) — aborting the generation", .{ st.rsn_repeats, st.rsn_looped });
            aborted = true;
            break;
        }
        var f = std.Io.Dir.cwd().openFile(io, outpath, .{}) catch {
            // file not created yet — curl still connecting (or it died before writing)
            if (std.Io.Timestamp.now(io, .real).toSeconds() - t0 > wall) break;
            io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {}; // 20ms: pick up new stream bytes fast for the desk's ~30Hz poll
            continue;
        };
        {
            defer f.close(io);
            // Read ACTUAL bytes from the cursor — do NOT gate on f.length(): on Windows a freshly-opened read
            // handle's length does not reflect curl's in-progress appends from the OTHER process (the metadata
            // lags the write), so gating on it stalls the stream until curl exits — the reply then lands
            // all-at-once and, with st.content still empty, falls back to complete() (no live tokens). A regular
            // file's positional read returns 0 at EOF and never blocks; more than rbuf.len pending just drains
            // across the next polls.
            const n = f.readPositionalAll(io, rbuf, offset) catch 0;
            if (n > 0) {
                vbuf.appendSlice(gpa, rbuf[0..n]) catch {};
                offset += n;
            }
        }
        // resolve vbuf (== last poll's carry ++ this poll's new bytes): feed body up to curl's end-marker, hold
        // back a straddled marker prefix. curl's real marker is ALWAYS newline-anchored ("\n__VEILSTAT__<code>")
        // and last in the file, so we treat a MARK match as the sentinel only when the byte before it is '\n'
        // (from this window, else `last_fed` — the byte fed in a prior poll). A bare "__VEILSTAT__" the model
        // itself emits sits inside a JSON string (never preceded by a raw '\n'), so it feeds as ordinary body
        // instead of silently truncating the reply.
        if (vbuf.items.len > 0) {
            var did_sentinel = false;
            if (std.mem.lastIndexOf(u8, vbuf.items, MARK)) |m| { // last occurrence — curl's marker is always last in the file
                const anchor: u8 = if (m > 0) vbuf.items[m - 1] else last_fed;
                if (anchor == '\n') {
                    if (m > 0) last_fed = vbuf.items[m - 1];
                    feedStream(&st, gpa, vbuf.items[0..m]); // body up to the marker (its anchoring '\n' at m-1 included)
                    if (vbuf.items.len - (m + MARK.len) >= 3) {
                        sentinel = true; // full marker + 3-digit http code present → curl finished
                    } else {
                        _ = keepFront(&vbuf, m); // marker present but the code hasn't fully landed — hold it, wait
                    }
                    did_sentinel = true;
                }
            }
            if (!did_sentinel) {
                // no newline-anchored marker → all body except a trailing suffix that is a strict prefix of MARK (a
                // real, newline-anchored marker straddling the next read boundary; a body '__VEILSTAT__' feeds through).
                const keep = vbuf.items.len - markPrefixSuffix(vbuf.items, MARK);
                if (keep > 0) {
                    last_fed = vbuf.items[keep - 1];
                    feedStream(&st, gpa, vbuf.items[0..keep]);
                }
                _ = keepFront(&vbuf, keep);
            }
        }
        if (st.done or sentinel) {
            // flush a final line that arrived without a trailing newline (native's last object can)
            if (!st.done and st.carry.items.len > 0) {
                const line = std.mem.trimEnd(u8, st.carry.items, "\r\n");
                if (line.len > 0) handleStreamLine(&st, gpa, line);
            }
            break;
        }
        if (std.Io.Timestamp.now(io, .real).toSeconds() - t0 > wall) break;
        io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {}; // 20ms: pick up new stream bytes fast for the desk's ~30Hz poll
    }

    // PROVIDER BACK-OFF: curl appended "\n__VEILSTAT__<code>" with the final HTTP status. On 429/503, record a
    // per-host cooldown so EVERY concurrent turn to this provider backs off together instead of retrying in
    // lockstep (and so the complete() fallback below waits it out). Hosted only; a clean 2xx sets nothing.
    if (!local) {
        if (trailingStatusCode(io, outpath)) |code| {
            if (code == 429 or code == 503) rate.note429(io, base_url, 0);
        }
    }

    // ABORTED mid-stream (chat Stop): return whatever already streamed as a partial Step — do NOT fall back to
    // complete() (that re-runs the whole inference, defeating the abort) and do NOT take the empty→null path
    // below. ok=true with partial (possibly empty) content; the caller's next stop check commits this.
    if (aborted) {
        const c_owned = gpa.dupe(u8, st.content.items) catch return null;
        const r_owned = gpa.dupe(u8, st.reasoning.items) catch {
            gpa.free(c_owned);
            return null;
        };
        return .{ .content = c_owned, .reasoning = r_owned, .calls = &.{}, .ok = true, .truncated = st.truncated };
    }

    // ---- decide: return a clean streamed Step, or null → complete() reparses authoritatively ----
    if (st.failed) return null; // an error line — let complete() surface the exact error

    if (st.saw_tool_calls) {
        // Assemble the call(s) FROM THE STREAM — native from the single captured NDJSON line, hosted from the
        // per-index SSE fragments (ToolAccum). Returning them here avoids a second complete() inference just to
        // reparse the call.
        const calls = if (native) parseNativeToolCalls(gpa, st.tool_line.items) else reconstructSseToolCalls(gpa, &st);
        if (calls.len > 0) {
            const c_owned = gpa.dupe(u8, st.content.items) catch {
                freeCalls(gpa, calls);
                return null;
            };
            const r_owned = gpa.dupe(u8, st.reasoning.items) catch {
                gpa.free(c_owned);
                freeCalls(gpa, calls);
                return null;
            };
            meterStream(&st, local);
            return .{ .content = c_owned, .reasoning = r_owned, .calls = calls, .ok = true, .truncated = st.truncated };
        }
        freeCalls(gpa, calls); // couldn't reconstruct (native miss, or hosted fragments with no usable name) → complete()
        return null;
    }

    if (st.content.items.len == 0 and st.reasoning.items.len == 0) return null; // nothing streamed → complete()

    const c_owned = gpa.dupe(u8, st.content.items) catch return null;
    const r_owned = gpa.dupe(u8, st.reasoning.items) catch {
        gpa.free(c_owned);
        return null;
    };
    meterStream(&st, local);
    return .{ .content = c_owned, .reasoning = r_owned, .calls = &.{}, .ok = true, .truncated = st.truncated };
}

fn trimSlash(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '/') s[0 .. s.len - 1] else s;
}
fn oom(gpa: std.mem.Allocator) Reply {
    return .{ .content = gpa.dupe(u8, "out of memory") catch @constCast("oom"), .ok = false };
}
fn err(gpa: std.mem.Allocator, msg: []const u8) Reply {
    return .{ .content = gpa.dupe(u8, msg) catch @constCast("error"), .ok = false };
}
fn stepErr(gpa: std.mem.Allocator, msg: []const u8) Step {
    return .{ .content = gpa.dupe(u8, msg) catch @constCast("error"), .reasoning = gpa.dupe(u8, "") catch @constCast(""), .calls = &.{}, .ok = false };
}

/// Append a JSON-escaped, quoted string. Multibyte runs are copied verbatim only when they decode as valid
/// UTF-8; any invalid, lone, or truncated byte is replaced with U+FFFD. This matters because the body is
/// shipped raw by `curl --data-binary`: a single bad byte makes it invalid UTF-8 and OpenAI answers
/// `400 ... error parsing the body`. Such bytes turn up when `max_tokens` truncates output mid-codepoint or a
/// tool result carries arbitrary bytes — both echoed back into the next request.
pub fn jstr(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try list.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try list.appendSlice(gpa, "\\\""),
                '\\' => try list.appendSlice(gpa, "\\\\"),
                '\n' => try list.appendSlice(gpa, "\\n"),
                '\r' => try list.appendSlice(gpa, "\\r"),
                '\t' => try list.appendSlice(gpa, "\\t"),
                else => if (c < 0x20) {
                    var b: [6]u8 = undefined;
                    try list.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
                } else try list.append(gpa, c),
            }
            i += 1;
            continue;
        }
        if (std.unicode.utf8ByteSequenceLength(c)) |len| {
            if (i + len <= s.len) {
                if (std.unicode.utf8Decode(s[i .. i + len])) |_| {
                    try list.appendSlice(gpa, s[i .. i + len]);
                    i += len;
                    continue;
                } else |_| {}
            }
        } else |_| {}
        try list.appendSlice(gpa, "\u{FFFD}");
        i += 1;
    }
    try list.append(gpa, '"');
}

test "self-healing quirks: detect temperature constraints, rewrite the body, extract the model" {
    const gpa = std.testing.allocator;

    // the observed Kimi error → pin temperature to 1
    const kimi = detectQuirk("invalid temperature: only 1 is allowed for this model").?;
    try std.testing.expectEqual(TempRule.force, kimi.temp);
    try std.testing.expectEqual(@as(f32, 1.0), kimi.temp_val);
    // a reasoning-model "unsupported" phrasing → drop temperature
    try std.testing.expectEqual(TempRule.drop, detectQuirk("temperature is not supported with this model").?.temp);
    // an unrelated error is not a quirk we heal
    try std.testing.expect(detectQuirk("rate limit exceeded, please retry") == null);
    try std.testing.expect(detectQuirk("context length exceeded") == null);
    // a CLAMP/RANGE constraint is NOT a drop: dropping temperature would be the wrong, permanently-learned
    // fix — surface it instead so the caller (or a future rule) handles the real bound.
    try std.testing.expect(detectQuirk("temperature cannot exceed 2") == null);
    try std.testing.expect(detectQuirk("temperature must be between 0 and 2") == null);
    // the value-pin tokens don't misfire on multi-digit values
    try std.testing.expect(detectQuirk("temperature: only 10 is the cap") == null);

    // FORCE rewrites the sent value to a CLEAN whole number (providers reject "1.00" where they want "1")
    const b1 = applyQuirk(gpa, "{\"model\":\"kimi-k3\",\"messages\":[],\"temperature\":0.50,\"max_tokens\":8}", kimi).?;
    defer gpa.free(b1);
    try std.testing.expectEqualStrings("{\"model\":\"kimi-k3\",\"messages\":[],\"temperature\":1,\"max_tokens\":8}", b1);
    // already at the required value → null (no wasted retry)
    try std.testing.expect(applyQuirk(gpa, "{\"model\":\"x\",\"temperature\":1,\"max_tokens\":8}", kimi) == null);
    // FORCE with no temperature field present → insert it before the closing brace
    const b2 = applyQuirk(gpa, "{\"model\":\"x\",\"max_tokens\":8}", kimi).?;
    defer gpa.free(b2);
    try std.testing.expectEqualStrings("{\"model\":\"x\",\"max_tokens\":8,\"temperature\":1}", b2);

    // DROP removes the field AND its leading comma
    const drop = Quirk{ .temp = .drop };
    const b3 = applyQuirk(gpa, "{\"model\":\"x\",\"messages\":[],\"temperature\":0.50,\"max_tokens\":8}", drop).?;
    defer gpa.free(b3);
    try std.testing.expectEqualStrings("{\"model\":\"x\",\"messages\":[],\"max_tokens\":8}", b3);
    // DROP when temperature is first → consumes the TRAILING comma instead
    const b4 = applyQuirk(gpa, "{\"temperature\":0.50,\"model\":\"x\"}", drop).?;
    defer gpa.free(b4);
    try std.testing.expectEqualStrings("{\"model\":\"x\"}", b4);
    // DROP with nothing to remove → null
    try std.testing.expect(applyQuirk(gpa, "{\"model\":\"x\",\"max_tokens\":8}", drop) == null);

    // the model id rides out of the request body for the learn step
    try std.testing.expectEqualStrings("kimi-k3", bodyModel("{\"model\":\"kimi-k3\",\"messages\":[]}").?);
    try std.testing.expect(bodyModel("{\"messages\":[]}") == null);
}

test "jstr sanitizes invalid UTF-8 and stays valid JSON" {
    const gpa = std.testing.allocator;
    const dirty = "ok\t\"q\\\" é中😀" ++ "\x80" ++ "x\xc3" ++ "\xff" ++ "\xc0\x80";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try jstr(gpa, &out, dirty);

    try std.testing.expect(std.unicode.utf8ValidateSlice(out.items));
    const doc = try std.fmt.allocPrint(gpa, "{{\"k\":{s}}}", .{out.items});
    defer gpa.free(doc);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, doc, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("k").? == .string);
    const v = parsed.value.object.get("k").?.string;
    try std.testing.expect(std.mem.startsWith(u8, v, "ok\t\"q\\\" é中😀"));
    try std.testing.expect(std.mem.indexOf(u8, v, "\u{FFFD}") != null);
}

test "parseOllamaNative re-serializes an arguments OBJECT into a JSON-string ToolCall" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"model":"gpt-oss:20b","message":{"role":"assistant","content":"","thinking":"I should write the file now.",
        \\"tool_calls":[{"function":{"name":"write_file","arguments":{"path":"x.py","content":"print(1)"}}}]},
        \\"done_reason":"stop","eval_count":42,"prompt_eval_count":100}
    ;
    var step = parseOllamaNative(gpa, "http://localhost:11434/v1", raw);
    defer step.deinit(gpa);
    try std.testing.expect(step.ok);
    try std.testing.expectEqual(@as(usize, 1), step.calls.len);
    try std.testing.expectEqualStrings("write_file", step.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, step.calls[0].args, "x.py") != null);
    const ap = try std.json.parseFromSlice(std.json.Value, gpa, step.calls[0].args, .{});
    defer ap.deinit();
    try std.testing.expectEqualStrings("x.py", ap.value.object.get("path").?.string);
    try std.testing.expectEqualStrings("print(1)", ap.value.object.get("content").?.string);
    try std.testing.expectEqualStrings("I should write the file now.", step.reasoning);
}

test "parseOllamaNative content-only (no tool call) returns text and no calls" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"model":"gpt-oss:20b","message":{"role":"assistant","content":"the answer is 391"},
        \\"done_reason":"stop","eval_count":7,"prompt_eval_count":20}
    ;
    var step = parseOllamaNative(gpa, "http://localhost:11434/v1", raw);
    defer step.deinit(gpa);
    try std.testing.expect(step.ok);
    try std.testing.expectEqual(@as(usize, 0), step.calls.len);
    try std.testing.expectEqualStrings("the answer is 391", step.content);
    try std.testing.expectEqualStrings("", step.reasoning);
    try std.testing.expect(!step.truncated); // done_reason "stop" = a complete emission
}

test "parseOllamaNative flags a length-cut reply as truncated (the committed-partial-file signal)" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"model":"gpt-oss:20b","message":{"role":"assistant","content":"index.html\n```html\n<!DOCTYPE html>\n<style>.page { margin-"},
        \\"done_reason":"length","eval_count":8192,"prompt_eval_count":900}
    ;
    var step = parseOllamaNative(gpa, "http://localhost:11434/v1", raw);
    defer step.deinit(gpa);
    try std.testing.expect(step.ok);
    try std.testing.expect(step.truncated);
}

test "parseOllamaVersion: an Ollama /api/version shape -> true, a hosted 404/error -> false" {
    try std.testing.expect(parseOllamaVersion("{\"version\":\"0.5.7\"}"));
    try std.testing.expect(!parseOllamaVersion("{\"error\":{\"message\":\"Unknown request URL: GET /api/version\",\"type\":\"invalid_request_error\"}}"));
    try std.testing.expect(!parseOllamaVersion("{\"version\":\"\"}"));
    try std.testing.expect(!parseOllamaVersion("<html><body>404 Not Found</body></html>"));
}

test "responseHasReasoning: an /api/chat msg with thinking -> true, content-only -> false" {
    try std.testing.expect(responseHasReasoning("{\"message\":{\"content\":\"ok\",\"thinking\":\"I should answer ok.\"}}"));
    try std.testing.expect(responseHasReasoning("{\"message\":{\"content\":\"ok\",\"reasoning\":\"some chain\"}}"));
    try std.testing.expect(responseHasReasoning("{\"reasoning_content\":\"x\",\"message\":{\"content\":\"ok\"}}"));
    try std.testing.expect(!responseHasReasoning("{\"message\":{\"content\":\"the answer is 391\"}}"));
    try std.testing.expect(!responseHasReasoning("{\"message\":{\"content\":\"ok\",\"thinking\":\"\"}}"));
    try std.testing.expect(!responseHasReasoning("not json"));
}

test "probe-first override: a probed cap wins over the port/name heuristics; unprobed falls back" {
    const saved = caps;
    defer caps = saved;

    caps = .{};
    try std.testing.expect(isOllama("http://localhost:11434/v1"));
    try std.testing.expect(!isOllama("http://localhost:1234/v1"));
    try std.testing.expect(isThinking("gpt-oss:20b"));
    try std.testing.expect(!isThinking("llama3.1:8b"));

    caps = .{ .probed = true, .ollama_native = true, .reasoning = false };
    try std.testing.expect(isOllama("http://localhost:9999/v1"));
    try std.testing.expect(!isThinking("gpt-oss:20b"));
    caps.reasoning = true;
    try std.testing.expect(isThinking("some-unlisted-model"));

    caps = .{ .probed = true, .ollama_native = false, .reasoning = false };
    try std.testing.expect(!isOllama("http://localhost:11434/v1"));
    try std.testing.expect(isThinking("o1-preview"));
    try std.testing.expect(!isThinking("gpt-4o"));

    // capabilities[] from /api/show outranks both the name heuristics and the reasoning probe
    caps = .{ .probed = true, .ollama_native = true, .caps_listed = true, .thinking = false, .reasoning = false };
    try std.testing.expect(!isThinking("gpt-oss:20b")); // the name says thinking; the capability record says no
    caps.thinking = true;
    try std.testing.expect(isThinking("llama3.1:8b")); // and vice versa
}

test "ollamaNativeBody pins num_ctx in the options (titan1 truncation fix)" {
    const gpa = std.testing.allocator;
    const with_tools = try ollamaNativeBody(gpa, "gpt-oss:20b", "{\"role\":\"user\"}", "{\"name\":\"write_file\"}", 24576, 32768, ",\"temperature\":0.70");
    defer gpa.free(with_tools);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "\"num_ctx\":32768") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "\"num_predict\":24576") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_tools, "\"tools\":") != null);

    const no_tools = try ollamaNativeBody(gpa, "gpt-oss:20b", "{\"role\":\"user\"}", "", 24576, 32768, "");
    defer gpa.free(no_tools);
    try std.testing.expect(std.mem.indexOf(u8, no_tools, "\"num_ctx\":32768") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_tools, "\"tools\":") == null);
    try std.testing.expectEqual(@as(u32, 32768), NATIVE_CTX);
}

test "effectiveCtx: the probed model maximum bounds num_ctx; unprobed keeps the engine budget" {
    const saved = caps;
    defer caps = saved;

    caps = .{};
    try std.testing.expectEqual(NATIVE_CTX, effectiveCtx());
    caps.ctx_tokens = 8192; // a genuinely small model must not be asked for a 32k window
    try std.testing.expectEqual(@as(u32, 8192), effectiveCtx());
    caps.ctx_tokens = 131072; // a huge model still gets only the engine budget
    try std.testing.expectEqual(NATIVE_CTX, effectiveCtx());
}

test "parseShowCaps: capabilities[] + context_length parsed; rope original_context_length ignored" {
    const saved = caps;
    defer caps = saved;

    caps = .{};
    parseShowCaps("{\"capabilities\":[\"completion\",\"tools\"],\"model_info\":{\"llama.context_length\":131072,\"llama.embedding_length\":4096}}");
    try std.testing.expect(caps.caps_listed);
    try std.testing.expect(caps.tools);
    try std.testing.expect(!caps.thinking);
    try std.testing.expectEqual(@as(u32, 131072), caps.ctx_tokens);

    caps = .{};
    parseShowCaps("{\"capabilities\":[\"completion\",\"tools\",\"thinking\"],\"model_info\":{\"gptoss.context_length\":131072,\"gptoss.rope.scaling.original_context_length\":4096}}");
    try std.testing.expect(caps.thinking);
    try std.testing.expectEqual(@as(u32, 131072), caps.ctx_tokens); // NOT the 4096 pre-rope-scaling window

    caps = .{};
    parseShowCaps("{\"capabilities\":[\"completion\",\"tools\"],\"model_info\":{\"llama.context_length\":131072,\"general.parameter_count\":8030261312}}");
    try std.testing.expectEqual(@as(u64, 8030261312), caps.param_count);

    caps = .{};
    parseShowCaps("<html>404</html>"); // a hosted endpoint answering garbage must change nothing
    try std.testing.expect(!caps.caps_listed);
    try std.testing.expectEqual(@as(u32, 0), caps.ctx_tokens);
}

test "largeToolCallVerdict: a structured call trusts; a text-emitted call or a tool-parse error fences" {
    // the backend parsed the large call into tool_calls — the transport is trustworthy
    try std.testing.expect(largeToolCallVerdict("{\"message\":{\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"write_file\",\"arguments\":{\"path\":\"probe.txt\",\"content\":\"line 001 ...\"}}}]}}"));
    // the observed llama3.1:8b wall: Ollama's template errors on the large call
    try std.testing.expect(!largeToolCallVerdict("{\"error\":\"Value looks like object, but can't find closing '}' symbol\"}"));
    // the other wall shape: the call comes back as raw TEXT in content
    try std.testing.expect(!largeToolCallVerdict("{\"message\":{\"content\":\"{\\\"name\\\": \\\"write_file\\\", \\\"parameters\\\": {\\\"path\\\": \\\"probe.txt\\\", \\\"content\\\": \\\"line 001\\\"}}\"}}"));
    // inconclusive shapes stay trusted — the runtime adaptive flip is the safety net
    try std.testing.expect(largeToolCallVerdict("{\"message\":{\"content\":\"I wrote the file for you.\"}}"));
    try std.testing.expect(largeToolCallVerdict("{\"error\":\"model is out of memory\"}"));
    try std.testing.expect(largeToolCallVerdict("not json at all"));
}

test "fenceWrites: probed non-thinking model with a broken large-tool-call transport gets fenced from round 1" {
    const saved = caps;
    defer caps = saved;

    caps = .{ .probed = true, .ollama_native = true, .caps_listed = true, .tools = true, .thinking = false, .tools_ok_large = false };
    try std.testing.expect(fenceWrites("http://localhost:9999/v1", "llama3.1:8b"));
    caps.tools_ok_large = true;
    try std.testing.expect(!fenceWrites("http://localhost:9999/v1", "llama3.1:8b"));
    caps.thinking = true; // a thinking model is fenced regardless of the transport probe
    try std.testing.expect(fenceWrites("http://localhost:9999/v1", "whatever-model"));
}

test "hostedToolCallVerdict: structured call trusts; text-emitted markup fences; unrelated error trusts" {
    // the hosted backend returned a real structured tool_calls entry — the native channel works
    try std.testing.expect(hostedToolCallVerdict("{\"choices\":[{\"message\":{\"content\":\"\",\"tool_calls\":[{\"id\":\"1\",\"function\":{\"name\":\"write_file\",\"arguments\":\"{\\\"path\\\":\\\"probe.txt\\\"}\"}}]}}]}"));
    // the observed DeepSeek failure signature: the call emitted as DSML text markup in content
    try std.testing.expect(!hostedToolCallVerdict("{\"choices\":[{\"message\":{\"content\":\"\xef\xbd\x9cDSML\xef\xbd\x9ctool_calls><invoke name=\\\"write_file\\\"><parameter name=\\\"path\\\">probe.txt</parameter></invoke>\"}}]}"));
    // ...and the plain-JSON-in-prose shape
    try std.testing.expect(!hostedToolCallVerdict("{\"choices\":[{\"message\":{\"content\":\"{\\\"name\\\": \\\"write_file\\\", \\\"arguments\\\": {\\\"path\\\": \\\"probe.txt\\\"}}\"}}]}"));
    // inconclusive shapes stay trusted — an uncooperative model or a billing error is not transport evidence
    try std.testing.expect(hostedToolCallVerdict("{\"choices\":[{\"message\":{\"content\":\"I cannot write files.\"}}]}"));
    try std.testing.expect(hostedToolCallVerdict("{\"error\":{\"message\":\"insufficient balance\"}}"));
    try std.testing.expect(!hostedToolCallVerdict("{\"error\":{\"message\":\"tool call arguments failed to parse\"}}"));
    try std.testing.expect(hostedToolCallVerdict("not json at all"));
}

test "fenceWrites: hosted backend fences only on measured text-emission evidence" {
    const saved = caps;
    defer caps = saved;

    caps = .{}; // unprobed hosted backend → trust the native channel (today's behavior)
    try std.testing.expect(!fenceWrites("https://api.example.com/v1", "some-hosted-model"));
    caps = .{ .probed = true, .ollama_native = false, .tools_native_ok = false };
    try std.testing.expect(fenceWrites("https://api.example.com/v1", "some-hosted-model"));
    caps = .{ .probed = true, .ollama_native = false, .tools_native_ok = true };
    try std.testing.expect(!fenceWrites("https://api.example.com/v1", "some-hosted-model"));
}

// ---- streaming parser (pure over byte chunks — no network) ----

const StreamCapture = struct {
    content: std.ArrayListUnmanaged(u8) = .empty,
    reasoning: std.ArrayListUnmanaged(u8) = .empty,
    fn deinit(self: *StreamCapture, gpa: std.mem.Allocator) void {
        self.content.deinit(gpa);
        self.reasoning.deinit(gpa);
    }
    fn onDelta(cx: *anyopaque, kind: DeltaKind, text: []const u8) void {
        const self: *StreamCapture = @ptrCast(@alignCast(cx));
        const dst = switch (kind) {
            .content => &self.content,
            .reasoning => &self.reasoning,
            .tool_progress => return, // status-only signal; never part of the reply text
        };
        dst.appendSlice(std.testing.allocator, text) catch {};
    }
};

test "completeStream SSE parser: reasoning + content deltas fire on_delta, accumulate, and [DONE] completes" {
    const gpa = std.testing.allocator;
    var cap: StreamCapture = .{};
    defer cap.deinit(gpa);
    var st = StreamState{ .native = false, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer st.deinit(gpa);
    // reasoning first (thinking model), then the answer split mid-line across two feeds, then usage + [DONE]
    feedStream(&st, gpa, "data: {\"choices\":[{\"delta\":{\"reasoning\":\"think \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"cont");
    try std.testing.expectEqualStrings("Hel", st.content.items);
    feedStream(&st, gpa, "ent\":\"lo\"}}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":2}}\n\ndata: [DONE]\n");
    try std.testing.expect(st.done and !st.failed);
    try std.testing.expect(!st.saw_tool_calls);
    try std.testing.expectEqualStrings("Hello", st.content.items);
    try std.testing.expectEqualStrings("Hello", cap.content.items);
    try std.testing.expectEqualStrings("think ", st.reasoning.items);
    try std.testing.expectEqualStrings("think ", cap.reasoning.items);
    try std.testing.expect(st.metered and st.p_in == 11 and st.p_out == 2);
}

test "completeStream SSE parser: an error chunk fails the stream; finish_reason tool_calls flags fallback" {
    const gpa = std.testing.allocator;
    var cap: StreamCapture = .{};
    defer cap.deinit(gpa);
    var e = StreamState{ .native = false, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer e.deinit(gpa);
    feedStream(&e, gpa, "data: {\"error\":{\"message\":\"invalid api key\"}}\n");
    try std.testing.expect(e.failed and e.done);

    var t = StreamState{ .native = false, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer t.deinit(gpa);
    feedStream(&t, gpa, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"read_file\"}}]},\"finish_reason\":\"tool_calls\"}]}\n");
    try std.testing.expect(t.saw_tool_calls);
}

test "completeStream native parser: streams thinking + content, reconstructs a tool call, meters on done" {
    const gpa = std.testing.allocator;
    var cap: StreamCapture = .{};
    defer cap.deinit(gpa);
    var st = StreamState{ .native = true, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer st.deinit(gpa);
    feedStream(&st, gpa, "{\"message\":{\"role\":\"assistant\",\"thinking\":\"plan \",\"content\":\"\"},\"done\":false}\n");
    feedStream(&st, gpa, "{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"read_file\",\"arguments\":{\"path\":\"a.txt\"}}}]},\"done\":false}\n");
    feedStream(&st, gpa, "{\"message\":{\"content\":\"\"},\"done\":true,\"eval_count\":5,\"prompt_eval_count\":9}\n");
    try std.testing.expect(st.done and !st.failed and st.saw_tool_calls);
    try std.testing.expectEqualStrings("plan ", st.reasoning.items);
    try std.testing.expect(st.metered and st.p_out == 5 and st.p_in == 9);

    const calls = parseNativeToolCalls(gpa, st.tool_line.items);
    defer freeCalls(gpa, calls);
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("read_file", calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, calls[0].args, "a.txt") != null);
}

test "completeStream native parser: content-only reply accumulates and done:true completes" {
    const gpa = std.testing.allocator;
    var cap: StreamCapture = .{};
    defer cap.deinit(gpa);
    var st = StreamState{ .native = true, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer st.deinit(gpa);
    feedStream(&st, gpa, "{\"message\":{\"role\":\"assistant\",\"content\":\"Hi \"},\"done\":false}\n{\"message\":{\"content\":\"there\"},\"done\":true,\"eval_count\":3,\"prompt_eval_count\":7}\n");
    try std.testing.expect(st.done and !st.failed and !st.saw_tool_calls);
    try std.testing.expectEqualStrings("Hi there", st.content.items);
    try std.testing.expectEqualStrings("Hi there", cap.content.items);
}

test "completeStream SSE parser: hosted tool_calls assemble from streamed fragments (no complete() re-run)" {
    const gpa = std.testing.allocator;
    var cap: StreamCapture = .{};
    defer cap.deinit(gpa);
    var st = StreamState{ .native = false, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer st.deinit(gpa);
    // call 0 (web_search): id+name+empty args, then arguments in TWO fragments ({\"q\": | \"x\"}); one SSE line is
    // split mid-way across two feeds to exercise the partial-line carry. call 1 (read_file): whole. Then finish+DONE.
    feedStream(&st, gpa, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"web_search\",\"arguments\":\"\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"q\\\":\"}}]}}]}\n\ndata: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"argum");
    try std.testing.expect(st.saw_tool_calls);
    feedStream(&st, gpa, "ents\":\"\\\"x\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_b\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n");
    try std.testing.expect(st.done and !st.failed and st.saw_tool_calls);

    const calls = reconstructSseToolCalls(gpa, &st);
    defer freeCalls(gpa, calls);
    try std.testing.expectEqual(@as(usize, 2), calls.len);
    try std.testing.expectEqualStrings("web_search", calls[0].name);
    try std.testing.expectEqualStrings("call_a", calls[0].id);
    try std.testing.expectEqualStrings("{\"q\":\"x\"}", calls[0].args); // two arg fragments concatenated verbatim
    try std.testing.expectEqualStrings("read_file", calls[1].name);
    try std.testing.expectEqualStrings("call_b", calls[1].id);
    try std.testing.expect(std.mem.indexOf(u8, calls[1].args, "a.txt") != null);
}

test "reasoning degeneration: repeats condense behind one marker, resume live on loop exit" {
    const gpa = std.testing.allocator;
    var cap: StreamCapture = .{};
    defer cap.deinit(gpa);
    var st = StreamState{ .native = false, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer st.deinit(gpa);
    const L = "Let me search for the most recent stats - I need numbers.\n";
    // one original + 3 repeats forward live; the next 20 swallow behind the marker; then the loop breaks
    var i: usize = 0;
    while (i < 24) : (i += 1) st.fire(gpa, .reasoning, L);
    st.fire(gpa, .reasoning, "Found it - the CIFFC page has the numbers.\n");
    const seen = cap.reasoning.items;
    // the loop line appears exactly 4x (original + RSN_REPEAT_SHOW), not 24x
    var count: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, seen, from, "Let me search")) |at| {
        count += 1;
        from = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expect(std.mem.indexOf(u8, seen, "(reasoning repeating - condensed...)") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Found it - the CIFFC page has the numbers.") != null); // resumed
    try std.testing.expect(!st.runaway); // 24 repeats is a recoverable loop, not a runaway
    // st.reasoning (the assembled channel) carries the CONDENSED stream — downstream consumers inherit it
    try std.testing.expect(st.reasoning.items.len < 24 * L.len);
}

test "reasoning degeneration: fragment-split lines still detected; runaway trips the breaker" {
    const gpa = std.testing.allocator;
    var cap: StreamCapture = .{};
    defer cap.deinit(gpa);
    var st = StreamState{ .native = false, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer st.deinit(gpa);
    // deltas arrive as token-sized fragments — the line assembler must still see whole-line repeats
    var i: usize = 0;
    while (i < RSN_REPEAT_ABORT + 8) : (i += 1) {
        st.fire(gpa, .reasoning, "same ");
        st.fire(gpa, .reasoning, "thought");
        st.fire(gpa, .reasoning, "\n");
    }
    try std.testing.expect(st.runaway); // past the repeat threshold → the generation should be aborted
    var count: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, cap.reasoning.items, from, "same thought")) |at| {
        count += 1;
        from = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count); // display stayed condensed the whole way
}

test "tool-compose progress: .tool_progress fires past the byte threshold and names the path" {
    const gpa = std.testing.allocator;
    const Cap = struct {
        lines: std.ArrayListUnmanaged(u8) = .empty,
        fn onDelta(cx: *anyopaque, kind: DeltaKind, text: []const u8) void {
            if (kind != .tool_progress) return;
            const self: *@This() = @ptrCast(@alignCast(cx));
            self.lines.appendSlice(std.testing.allocator, text) catch {};
            self.lines.append(std.testing.allocator, '\n') catch {};
        }
    };
    var cap: Cap = .{};
    defer cap.lines.deinit(gpa);
    var st = StreamState{ .native = false, .ctx = &cap, .on_delta = Cap.onDelta };
    defer st.deinit(gpa);
    // head fragment carries the path; then pump > TP_NOTIFY_BYTES of content fragments → at least one progress line.
    st.accumToolCall(gpa, 0, "c0", "write_file", "{\"path\":\"index.html\",\"content\":\"");
    var i: usize = 0;
    while (i < (TP_NOTIFY_BYTES / 64) + 2) : (i += 1) st.accumToolCall(gpa, 0, null, null, "x" ** 64);
    try std.testing.expect(cap.lines.items.len > 0); // fired
    try std.testing.expect(std.mem.indexOf(u8, cap.lines.items, "writing index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.lines.items, "KB") != null);
}

test "argsPathHead: extracts the path from a partial args head, null when absent" {
    try std.testing.expectEqualStrings("index.html", argsPathHead("{\"path\":\"index.html\",\"content\":\"<!doct").?);
    try std.testing.expectEqualStrings("journal/a.md", argsPathHead("{ \"path\": \"journal/a.md\"").?);
    try std.testing.expect(argsPathHead("{\"query\":\"no path here\"}") == null);
    try std.testing.expect(argsPathHead("{\"path\":\"") == null); // value not started
}

test "reconstructSseToolCalls: a fragment with no name is dropped; empty args become {}" {
    const gpa = std.testing.allocator;
    var cap: StreamCapture = .{};
    defer cap.deinit(gpa);
    var st = StreamState{ .native = false, .ctx = &cap, .on_delta = StreamCapture.onDelta };
    defer st.deinit(gpa);
    // index 0 has a name but never any args; index 1 has args but NEVER a name (unusable → dropped).
    feedStream(&st, gpa, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c0\",\"function\":{\"name\":\"run_tests\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"{}\"}}]}}]}\n\ndata: [DONE]\n");
    const calls = reconstructSseToolCalls(gpa, &st);
    defer freeCalls(gpa, calls);
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("run_tests", calls[0].name);
    try std.testing.expectEqualStrings("{}", calls[0].args); // no args fragments → defaulted
}
