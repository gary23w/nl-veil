//! The worker's LLM client. The Zig control plane has no HTTPS client, and an LLM call is network-bound
//! (seconds), so we shell out to curl — its overhead is noise next to the model latency. The API key is
//! passed via a curl config file (-K), so it never appears on the process argv.
//!
//! Two entry points: chat() for a one-shot system+user completion, and complete() for the agentic tool loop
//! (a pre-built messages array + a tools array → content OR parsed tool_calls).
const std = @import("std");

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
    return isOllama(base_url) and isThinking(model);
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

/// One-shot system+user completion → the assistant text.
pub fn chat(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, model: []const u8, system: []const u8, user: []const u8, max_tokens: u32) Reply {
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return oom(gpa);
    jstr(gpa, &msgs, system) catch return oom(gpa);
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return oom(gpa);
    jstr(gpa, &msgs, user) catch return oom(gpa);
    msgs.appendSlice(gpa, "}") catch return oom(gpa);
    const mt = effTokens(base_url, model, max_tokens);
    const body = std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"max_tokens\":{d}}}", .{ model, msgs.items, mt }) catch return oom(gpa);
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

fn ollamaNativeBody(gpa: std.mem.Allocator, model: []const u8, messages_json: []const u8, tools_json: []const u8, np: u32, ctx: u32, temp_frag: []const u8) ![]u8 {
    return if (tools_json.len > 0)
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"tools\":[{s}],\"stream\":false,\"options\":{{\"num_predict\":{d},\"num_ctx\":{d}{s}}}}}", .{ model, messages_json, tools_json, np, ctx, temp_frag })
    else
        std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\",\"messages\":[{s}],\"stream\":false,\"options\":{{\"num_predict\":{d},\"num_ctx\":{d}{s}}}}}", .{ model, messages_json, np, ctx, temp_frag });
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
    return .{ .content = content, .reasoning = reasoning, .calls = calls.toOwnedSlice(gpa) catch &.{}, .ok = true };
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
    const ver = blk: {
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
        }
    }
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
        } = &.{},
        usage: ?struct { prompt_tokens: u64 = 0, completion_tokens: u64 = 0 } = null,
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
    return .{ .content = content, .reasoning = reasoning, .calls = calls.toOwnedSlice(gpa) catch &.{}, .ok = true };
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
    parseShowCaps("<html>404</html>"); // a hosted endpoint answering garbage must change nothing
    try std.testing.expect(!caps.caps_listed);
    try std.testing.expectEqual(@as(u32, 0), caps.ctx_tokens);
}
