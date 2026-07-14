//! The worker's LLM client. Transport is split by destination: a LOOPBACK plain-http backend (a local
//! Ollama) goes through the in-process raw-socket client (httpc.zig) — no curl child for Defender's
//! behavior/ML models to kill, no scratch files, no per-call process cost. A hosted backend needs TLS,
//! which the Zig control plane doesn't have in-process yet, so those calls still shell out to curl —
//! its overhead is noise next to the model latency, and the API key rides a curl config file (-K), so
//! it never appears on the process argv.
//!
//! Two entry points: chat() for a one-shot system+user completion, and complete() for the agentic tool loop
//! (a pre-built messages array + a tools array → content OR parsed tool_calls).
const std = @import("std");
const httpc = @import("httpc.zig");

pub const Reply = struct {
    content: []u8,
    ok: bool,
};

/// PROCESS-WIDE TOKEN METER. The provider reports exact prompt/completion token counts in every response's
/// `usage` block; we accumulate them here at the single call choke-point (completeBody) so the engine can report
/// REAL cost per round/run instead of guessing from request byte sizes (which are noisy — a moment's last request
/// depends on how many tool turns it ran). Atomic because minds call concurrently. One worker = one swarm = one process.
pub var tokens_in: std.atomic.Value(u64) = .init(0);
pub var tokens_out: std.atomic.Value(u64) = .init(0);
pub var tokens_in_free: std.atomic.Value(u64) = .init(0);
pub var tokens_out_free: std.atomic.Value(u64) = .init(0);
pub var calls_made: std.atomic.Value(u64) = .init(0);
/// Of tokens_in, how many the provider served from its prompt cache (OpenAI usage.prompt_tokens_details.
/// cached_tokens — billed at a steep discount). Measuring this is what makes prompt-prefix churn VISIBLE:
/// a run whose cached share is ~0 is paying full price for re-sending the same doctrine every call.
pub var tokens_cached: std.atomic.Value(u64) = .init(0);

pub const Caps = struct {
    probed: bool = false,
    ollama_native: bool = false,
    reasoning: bool = false,
    /// From /api/show model_info "<arch>.context_length": the model's REAL maximum context window. 0 = unknown.
    ctx_tokens: u32 = 0,
    /// capabilities[] from /api/show parsed OK — when true, `tools`/`thinking` are authoritative and replace
    /// the model-NAME heuristics entirely (a new model needs no code change to be classified correctly).
    caps_listed: bool = false,
    tools: bool = false,
    thinking: bool = false,
    /// From /api/show model_info "general.parameter_count" — a measured tier prior (0 = unknown).
    param_count: u64 = 0,
    /// One-shot startup probe: can this backend PARSE a file-sized tool call? Ollama's chat templates on some
    /// small non-thinking models return a large call as raw text / a parse error — every full-file write_file
    /// would be lost. Defaults to trusted; only clear parse-failure evidence flips it (the runtime adaptive
    /// fence flip remains the safety net for anything the probe misses).
    tools_ok_large: bool = true,
    /// HOSTED (OpenAI-style) backends: does a chat completion carrying a tools array come back as STRUCTURED
    /// tool_calls, or does the model emit the call as text markup (DeepSeek's ｜DSML｜ emission — observed
    /// live as tool_writes=0 with every file riding the narrated-write salvage)? Measured by a real startup
    /// completion, cached per model. Defaults to trusted; only clear text-emission evidence flips it.
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
    // even though it reads as a clean prefix — committing it silently was the truncated-deliverable bug
    // (a mid-CSS varieties.html scored 100% and finalized the cast).
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
/// inference behaves differently from a hosted API: it is much SLOWER (seconds–minutes, CPU/partial-GPU) and it
/// never rate-limits, so the client must NOT use the short hosted timeout + transient-retry, and a THINKING model
/// (e.g. DeepSeek-R1) spends part of its token budget on hidden reasoning — so tiny max_tokens calls return empty.
fn isLocal(base_url: []const u8) bool {
    return std.mem.indexOf(u8, base_url, "localhost") != null or
        std.mem.indexOf(u8, base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, base_url, "0.0.0.0") != null or
        std.mem.indexOf(u8, base_url, "[::1]") != null;
}
fn isOllama(base_url: []const u8) bool {
    if (caps.probed) return caps.ollama_native;
    return isLocal(base_url) and std.mem.indexOf(u8, base_url, "11434") != null;
}
/// Floor on max_tokens for a LOCAL **thinking** model: its hidden reasoning eats the budget before the answer, so a
/// 160-token retro/gap call would come back empty. Give those calls room to think AND answer.
const LOCAL_MIN_TOKENS: u32 = 2048;
const NATIVE_THINK_TOKENS: u32 = 24576;
const NATIVE_CTX: u32 = 32768;

/// Is this a THINKING/reasoning model (hidden chain-of-thought before the answer)? Only those need the token floor.
/// A plain relay model (llama3.1, qwen-instruct, mistral, gemma, phi) answers fine at a small max_tokens — and
/// flooring IT to 2048 forces it to GENERATE 2048 tokens for a 200-token task, which turned the local relay into a
/// multi-minute stall. So the floor must be gated on the model, not just on "is it local".
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
        // hosted OpenAI-style backend: fence ONLY on measured text-emission evidence from the startup
        // probe (structured tool_calls confirmed or unprobed → trust the native channel; the runtime
        // adaptive flip still covers whatever the probe misses)
        return caps.probed and !caps.tools_native_ok;
    }
    if (isThinking(model)) return true;
    // a probed backend that cannot parse file-sized tool calls gets fenced writes from round 1
    return caps.probed and caps.caps_listed and !caps.tools_ok_large;
}

/// The effective max_tokens: a LOCAL thinking model gets the floor (room to reason); everything else (hosted, or a
/// local NON-thinking relay model) uses the caller's value verbatim — so the relay generates only what it needs.
fn effTokens(base_url: []const u8, model: []const u8, max_tokens: u32) u32 {
    return if (isLocal(base_url) and isThinking(model)) @max(max_tokens, LOCAL_MIN_TOKENS) else max_tokens;
}

/// POST a fully-formed request body to {base_url}/chat/completions. Returns the raw response JSON (caller
/// frees) or an error message (ok=false). The key rides in a curl config file, never on the argv. `tag`
/// makes the scratch request/config files per-caller (per-mind) so concurrent minds don't clobber each other.
fn post(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, body: []const u8) Reply {
    const url = std.fmt.allocPrint(gpa, "{s}/chat/completions", .{trimSlash(base_url)}) catch return oom(gpa);
    defer gpa.free(url);
    return postUrl(gpa, io, run_dir, tag, url, key, body, isLocal(base_url));
}

fn postUrl(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, url: []const u8, key: []const u8, body: []const u8, local: bool) Reply {
    // Loopback plain-http (a local Ollama): in-process socket. No curl child, and none of the scratch
    // files below — the key and body never touch disk or an argv on this path. Mirrors curl semantics:
    // any HTTP status with a body is returned ok=true (callers parse {"error":...} out of the JSON),
    // and the timeout matches the curl --max-time this path used.
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
/// are DETERMINISTIC: the same hive state yields the same label instead of resampling a fresh emotion — the
/// old default-temperature call let an identical round replay as intensity 4–9 across runs.
pub fn chatTemp(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, model: []const u8, system: []const u8, user: []const u8, max_tokens: u32, temperature: f32) Reply {
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return oom(gpa);
    jstr(gpa, &msgs, system) catch return oom(gpa);
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return oom(gpa);
    jstr(gpa, &msgs, user) catch return oom(gpa);
    msgs.appendSlice(gpa, "}") catch return oom(gpa);
    const mt = effTokens(base_url, model, max_tokens);
    const temp_frag = if (temperature >= 0)
        std.fmt.allocPrint(gpa, ",\"temperature\":{d:.2}", .{temperature}) catch return oom(gpa)
    else
        gpa.dupe(u8, "") catch return oom(gpa);
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
    const temp_frag = if (temperature >= 0)
        std.fmt.allocPrint(gpa, ",\"temperature\":{d:.2}", .{temperature}) catch return stepErr(gpa, "oom")
    else
        gpa.dupe(u8, "") catch return stepErr(gpa, "oom");
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
    const temp_frag = if (temperature >= 0)
        std.fmt.allocPrint(gpa, ",\"temperature\":{d:.2}", .{temperature}) catch return stepErr(gpa, "oom")
    else
        gpa.dupe(u8, "") catch return stepErr(gpa, "oom");
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
/// keeps the engine budget verbatim (the titan1 truncation fix).
fn effectiveCtx() u32 {
    return if (caps.ctx_tokens > 0) @min(NATIVE_CTX, caps.ctx_tokens) else NATIVE_CTX;
}

// keep_alive "2m": once a cast finishes and the worker exits, the local model is released a couple minutes
// later instead of Ollama's 5-min default — so a partly-CPU model stops spinning llama-server soon after the
// swarm is done. During the run, every request resets the timer, so it stays loaded.
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
        // requests a window the model cannot actually serve. Cheap (no model load) and exact.
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
    // structured calls at all. The verdict is a MODEL property, so it is CACHED across runs (the echo
    // round-trip costs ~75s of wall on a slow local model), and a runtime-observed wall overwrites a
    // false pass via recordLargeToolWall — measured behavior always outranks the synthetic probe.
    if (caps.ollama_native and caps.caps_listed and caps.tools and !caps.thinking) {
        if (cachedLargeVerdict(gpa, io, run_dir, model)) |v| {
            caps.tools_ok_large = v;
        } else {
            caps.tools_ok_large = probeLargeToolCall(gpa, io, run_dir, host, key, model);
            storeLargeVerdict(gpa, io, run_dir, model, caps.tools_ok_large);
        }
    }

    if (!caps.ollama_native) {
        // OpenAI-style hosted backend: measure whether a tools-array completion comes back as
        // STRUCTURED tool_calls or as text markup (DeepSeek-style emission). The fence decision must
        // ride measured transport behavior, never the provider's name. Cached per model (a model
        // property), same trust bias as the large-call probe: only clear text-emission flips it.
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
/// "…original_context_length" sibling (the PRE-scaling window, e.g. gpt-oss's 4096-of-131072) is ignored.
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

/// The RUNTIME fence flip observed a real large-tool-call wall the startup probe missed. Persist the verdict —
/// it is a model property — so every FUTURE run of this model fences from round 1 instead of re-learning it.
/// The native-transport verdict is flipped + persisted too: on a hosted backend the wall IS the evidence that
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

/// One real chat completion against a HOSTED OpenAI-style backend carrying a minimal tools array:
/// does the call come back as structured tool_calls? Trust-biased like probeLargeToolCall — a network
/// flake, an unrelated provider error, or a model that just answers in prose stays trusted; ONLY the
/// clear failure signature (the tool call emitted as text/markup in `content`) reports false.
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
/// naming the tool-call parse, or the call emitted as raw text) reports false — an uncooperative model or a
/// transport flake stays trusted, and the runtime adaptive fence flip covers whatever the probe misses.
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
    // temperature 0: the probe must measure the backend's MODAL behavior, not a sampling coin-flip — at the
    // default temperature the same model alternates between a structured call and the text-emission failure.
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

fn completeBody(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, body: []const u8) Step {
    const r = post(gpa, io, run_dir, tag, base_url, key, body);
    if (!r.ok) return .{ .content = r.content, .reasoning = gpa.dupe(u8, "") catch @constCast(""), .calls = &.{}, .ok = false };
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
        usage: ?struct { prompt_tokens: u64 = 0, completion_tokens: u64 = 0, prompt_tokens_details: ?struct { cached_tokens: u64 = 0 } = null } = null,
        @"error": ?struct { message: []const u8 = "" } = null,
    };
    const parsed = std.json.parseFromSlice(Resp, gpa, r.content, .{ .ignore_unknown_fields = true }) catch
        return stepErr(gpa, std.fmt.allocPrint(gpa, "bad LLM response: {s}", .{r.content[0..@min(r.content.len, 300)]}) catch "unparseable response");
    defer parsed.deinit();
    if (parsed.value.usage) |u| {
        if (isLocal(base_url)) {
            _ = tokens_in_free.fetchAdd(u.prompt_tokens, .monotonic);
            _ = tokens_out_free.fetchAdd(u.completion_tokens, .monotonic);
        } else {
            _ = tokens_in.fetchAdd(u.prompt_tokens, .monotonic);
            _ = tokens_out.fetchAdd(u.completion_tokens, .monotonic);
            if (u.prompt_tokens_details) |d| _ = tokens_cached.fetchAdd(d.cached_tokens, .monotonic);
        }
        _ = calls_made.fetchAdd(1, .monotonic);
    }
    if (parsed.value.@"error") |e| return stepErr(gpa, std.fmt.allocPrint(gpa, "provider error: {s}", .{e.message}) catch "provider error");
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
// STREAMING (chat only) — an ADDITIVE path parallel to complete(). The swarm's
// complete() / completeBody() / completeOllamaNative() above are UNTOUCHED. This variant
// asks the backend for "stream":true, curl-streams the SSE (hosted) / NDJSON (Ollama
// native) response to a scratch file that we TAIL line-by-line, firing on_delta for each
// incremental content/reasoning chunk, and accumulates the full content + reasoning
// (+ tool_calls) into the SAME Step complete() returns — so the agentic loop downstream is
// byte-identical. ANY streaming trouble (spawn/setup failure, an error line, a body that
// never streamed, or a hosted SSE tool call whose fragmented deltas aren't worth
// reassembling) transparently FALLS BACK to complete(): the turn still works, it just
// doesn't type out. This mirrors desk/src/llm.zig's transport (curl -N to a scratch file).
// ============================================================================

/// Which channel a streamed delta belongs to. `.content` is the visible reply; `.reasoning`
/// is the hidden thinking channel (reasoning models).
pub const DeltaKind = enum { content, reasoning };

const STREAM_STAT = "\n__VEILSTAT__"; // curl -w appends this + the 3-digit HTTP code once the transfer ends

const StreamState = struct {
    native: bool,
    ctx: *anyopaque,
    on_delta: *const fn (ctx: *anyopaque, kind: DeltaKind, text: []const u8) void,
    content: std.ArrayListUnmanaged(u8) = .empty,
    reasoning: std.ArrayListUnmanaged(u8) = .empty,
    carry: std.ArrayListUnmanaged(u8) = .empty, // partial trailing line held between polls
    tool_line: std.ArrayListUnmanaged(u8) = .empty, // the native NDJSON line that carried tool_calls (owned)
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
    }
    /// Emit one non-empty delta (borrowed — the callback copies it) and accumulate it.
    fn fire(st: *StreamState, gpa: std.mem.Allocator, kind: DeltaKind, text: []const u8) void {
        if (text.len == 0) return;
        st.on_delta(st.ctx, kind, text);
        switch (kind) {
            .content => st.content.appendSlice(gpa, text) catch {},
            .reasoning => st.reasoning.appendSlice(gpa, text) catch {},
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
                // Ollama emits the parsed tool_calls array complete in a single NDJSON line (arguments as a
                // whole JSON value) — capture that line; parseNativeToolCalls reconstructs the calls at the end.
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
                tool_calls: ?[]const std.json.Value = null,
            } = null,
            finish_reason: ?[]const u8 = null,
        } = &.{},
        usage: ?struct {
            prompt_tokens: u64 = 0,
            completion_tokens: u64 = 0,
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
                if (tcs.len > 0) st.saw_tool_calls = true;
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
        if (u.prompt_tokens_details) |dd| st.p_cached = dd.cached_tokens;
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
    _ = calls_made.fetchAdd(1, .monotonic);
}

/// STREAMING agentic step (chat only). Same request as complete() but "stream":true; curl streams the
/// response to a scratch file that we tail, firing on_delta(ctx, .content|.reasoning, chunk) for each
/// incremental delta and accumulating the full Step (content + reasoning + tool_calls). ANY failure — or a
/// case we can't stream cleanly (hosted SSE tool-call fragments) — FALLS BACK to complete(), and on_delta
/// simply never fires. The returned Step is caller-owned (step.deinit) and identical in shape to complete()'s.
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
) Step {
    return streamAttempt(gpa, io, run_dir, tag, base_url, key, model, messages_json, tools_json, max_tokens, temperature, ctx, on_delta) orelse
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
    const temp_frag = if (temperature >= 0)
        std.fmt.allocPrint(gpa, ",\"temperature\":{d:.2}", .{temperature}) catch return null
    else
        gpa.dupe(u8, "") catch return null;
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
    var offset: usize = 0;
    const wall: i64 = @as(i64, stream_max_s) + 30;
    const t0 = std.Io.Timestamp.now(io, .real).toSeconds();
    while (true) {
        const data = std.Io.Dir.cwd().readFileAlloc(io, outpath, gpa, .limited(8 << 20)) catch {
            // file not created yet — curl still connecting (or it died before writing)
            if (std.Io.Timestamp.now(io, .real).toSeconds() - t0 > wall) break;
            io.sleep(.{ .nanoseconds = 40 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        var body_bytes = data;
        var sentinel = false;
        if (std.mem.lastIndexOf(u8, data, STREAM_STAT)) |m| {
            const after = data[m + STREAM_STAT.len ..];
            if (after.len >= 3) {
                body_bytes = data[0..m];
                sentinel = true;
            }
        }
        if (body_bytes.len > offset) {
            feedStream(&st, gpa, body_bytes[offset..]);
            offset = body_bytes.len;
        }
        gpa.free(data);
        if (st.done or sentinel) {
            // flush a final line that arrived without a trailing newline (native's last object can)
            if (!st.done and st.carry.items.len > 0) {
                const line = std.mem.trimEnd(u8, st.carry.items, "\r\n");
                if (line.len > 0) handleStreamLine(&st, gpa, line);
            }
            break;
        }
        if (std.Io.Timestamp.now(io, .real).toSeconds() - t0 > wall) break;
        io.sleep(.{ .nanoseconds = 40 * std.time.ns_per_ms }, .awake) catch {};
    }

    // ---- decide: return a clean streamed Step, or null → complete() reparses authoritatively ----
    if (st.failed) return null; // an error line — let complete() surface the exact error

    if (st.saw_tool_calls) {
        if (native) {
            const calls = parseNativeToolCalls(gpa, st.tool_line.items);
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
            freeCalls(gpa, calls); // couldn't reconstruct — fall through to complete()
        }
        return null; // hosted SSE tool-call fragments (or a native miss): complete() reparses cleanly
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

/// Append a JSON-escaped, quoted string. Multibyte runs are copied verbatim only when they decode as
/// valid UTF-8; any invalid, lone, or truncated byte is replaced with U+FFFD. This matters because the
/// body is shipped raw by `curl --data-binary`: a single bad byte makes it invalid UTF-8 and OpenAI
/// answers `400 ... error parsing the body`. Such bytes turn up when `max_tokens` truncates model output
/// (or tool arguments) mid-codepoint, or when a tool result carries arbitrary bytes — both of which are
/// echoed back into the next request, producing the intermittent 400-then-recover we saw on live swarms.
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
