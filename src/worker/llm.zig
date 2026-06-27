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

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    args: []u8,
};

pub const Step = struct {
    content: []u8,
    calls: []ToolCall,
    ok: bool,

    pub fn deinit(self: *Step, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
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
/// Floor on max_tokens for a LOCAL **thinking** model: its hidden reasoning eats the budget before the answer, so a
/// 160-token retro/gap call would come back empty. Give those calls room to think AND answer.
const LOCAL_MIN_TOKENS: u32 = 2048;

/// Is this a THINKING/reasoning model (hidden chain-of-thought before the answer)? Only those need the token floor.
/// A plain relay model (llama3.1, qwen-instruct, mistral, gemma, phi) answers fine at a small max_tokens — and
/// flooring IT to 2048 forces it to GENERATE 2048 tokens for a 200-token task, which turned the local relay into a
/// multi-minute stall. So the floor must be gated on the model, not just on "is it local".
fn isThinking(model: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(model.len, buf.len);
    for (model[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const m = buf[0..n];
    return std.mem.indexOf(u8, m, "r1") != null or std.mem.indexOf(u8, m, "qwq") != null or
        std.mem.indexOf(u8, m, "o1") != null or std.mem.indexOf(u8, m, "o3") != null or
        std.mem.indexOf(u8, m, "think") != null or std.mem.indexOf(u8, m, "reason") != null or
        std.mem.indexOf(u8, m, "deepseek-r") != null;
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
    const reqpath = std.fmt.allocPrint(gpa, "{s}/.llmreq{s}{s}.json", .{ run_dir, if (tag.len > 0) "-" else "", tag }) catch return oom(gpa);
    defer gpa.free(reqpath);
    const cfgpath = std.fmt.allocPrint(gpa, "{s}/.curlcfg{s}{s}", .{ run_dir, if (tag.len > 0) "-" else "", tag }) catch return oom(gpa);
    defer gpa.free(cfgpath);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = reqpath, .data = body }) catch return err(gpa, "could not write llm request");
    const cfg = std.fmt.allocPrint(gpa, "header = \"Authorization: Bearer {s}\"\nheader = \"Content-Type: application/json\"\n", .{key}) catch return oom(gpa);
    defer gpa.free(cfg);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgpath, .data = cfg }) catch return err(gpa, "could not write curl config");

    const url = std.fmt.allocPrint(gpa, "{s}/chat/completions", .{trimSlash(base_url)}) catch return oom(gpa);
    defer gpa.free(url);
    const data_at = std.fmt.allocPrint(gpa, "@{s}", .{reqpath}) catch return oom(gpa);
    defer gpa.free(data_at);
    var av: std.ArrayListUnmanaged([]const u8) = .empty;
    defer av.deinit(gpa);
    const local = isLocal(base_url);
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

fn completeBody(gpa: std.mem.Allocator, io: std.Io, run_dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, body: []const u8) Step {
    const r = post(gpa, io, run_dir, tag, base_url, key, body);
    if (!r.ok) return .{ .content = r.content, .calls = &.{}, .ok = false };
    defer gpa.free(r.content);

    const Resp = struct {
        choices: []const struct {
            message: struct {
                content: ?[]const u8 = null,
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
    return .{ .content = content, .calls = calls.toOwnedSlice(gpa) catch &.{}, .ok = true };
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
    return .{ .content = gpa.dupe(u8, msg) catch @constCast("error"), .calls = &.{}, .ok = false };
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
