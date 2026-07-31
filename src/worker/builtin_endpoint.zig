//! builtin_endpoint.zig — the built-in engine's loopback HTTP surface.
//!
//! Serves the SAME local dialect the llm client already speaks best (llm.zig): the native
//! /api/version → /api/show → /api/generate(raw) → /api/chat family, plus an OpenAI-compatible
//! /v1/chat/completions for the one-shot helpers. Every route lives under builtin.PATH_PREFIX and
//! the resolved base carries that marker, which is how llm.isOllama recognizes the dialect with no
//! port assumption. A separate loopback listener (not routes on the main server) because swarm
//! minds are SUBPROCESSES — they can only reach the engine over TCP, exactly like they reach a
//! conventional local runtime — and because the main server may be bound to all interfaces while
//! this must never be.
//!
//! Rendering: /api/chat and /v1/chat/completions render through gemma4.renderPrompt — the
//! byte-verified wire format the model was trained on. That is the point of the whole feature:
//! the built-in path runs the SAME renderer on every route, chat and swarm, streamed and blocking,
//! where the conventional local runtime's own template renderer measured 18/30 with invented tool
//! names against 27/30 for this renderer. /api/generate takes a pre-rendered prompt verbatim
//! (the caller IS that renderer, llm.zig completeGemma4Raw).
//!
//! Auth: every route except /api/version (the dialect probe sends no header) requires the
//! per-boot bearer from builtin.zig. A local port is a surface every local process can dial;
//! the conventional local runtime leaves it open — this one does not.
//!
//! Tests run against a MOCK builtin.Engine — no weights, no C — which is why the engine arrives
//! as an interface instead of an import.

const std = @import("std");
const httpz = @import("httpz");
const builtin_mod = @import("builtin.zig");
const gemma4 = @import("gemma4.zig");
const llm = @import("llm.zig");

const log = std.log.scoped(.builtin_endpoint);

/// Reported by /api/version. Non-empty is the whole contract (llm.parseOllamaVersion), the value
/// is for humans reading a probe capture.
const DIALECT_VERSION = "veil-builtin-1";

pub const EndpointApp = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    eng: builtin_mod.Engine,
};

// The server + app live for the process (the listen thread holds them); heap slots, filled once.
var g_app: ?*EndpointApp = null;
var g_server: ?*httpz.Server(*EndpointApp) = null;

/// Bind the endpoint on 127.0.0.1 and serve it from a detached thread. Returns the bound port
/// (also published via builtin.setPort). NL_BUILTIN_PORT pins it; default scans a small range so
/// two veil instances on one box each get their own engine.
pub fn start(gpa: std.mem.Allocator, io: std.Io, eng: builtin_mod.Engine, environ: *const std.process.Environ.Map) !u16 {
    const pinned: ?u16 = if (environ.get("NL_BUILTIN_PORT")) |v|
        (std.fmt.parseInt(u16, std.mem.trim(u8, v, " \r\n\t"), 10) catch null)
    else
        null;

    const app = try gpa.create(EndpointApp);
    errdefer gpa.destroy(app);
    app.* = .{ .gpa = gpa, .io = io, .eng = eng };

    var port: u16 = pinned orelse 8788;
    const last: u16 = if (pinned) |p| p else 8797;
    while (true) : (port += 1) {
        if (tryStart(gpa, io, app, port)) {
            g_app = app;
            builtin_mod.setPort(port);
            log.info("built-in engine endpoint on 127.0.0.1:{d}{s}", .{ port, builtin_mod.PATH_PREFIX });
            return port;
        }
        if (port >= last) return error.NoFreePort;
    }
}

fn tryStart(gpa: std.mem.Allocator, io: std.Io, app: *EndpointApp, port: u16) bool {
    // Probe-bind first: httpz's listen() only reports "port in use" from its own thread, far too
    // late to try the next port. The tiny bind→close→bind race is acceptable on loopback.
    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    var probe = std.Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp }) catch return false;
    probe.deinit(io);

    const server = gpa.create(httpz.Server(*EndpointApp)) catch return false;
    server.* = httpz.Server(*EndpointApp).init(io, gpa, .{
        .address = .localhost(port),
        // request=60 bounds reading the REQUEST; the minutes-long generation happens after the
        // read and is bounded by the client's own timeout (a dropped client fails the chunk write,
        // which aborts the generation via the sink callback).
        .timeout = .{ .request = 60, .keepalive = 75, .request_count = 64 },
        // A 32k-context conversation body in JSON can be a few MB; match the main server's cap.
        .request = .{ .max_body_size = 16 << 20 },
        // The engine is single-flight; a handful of threads is queue depth, not parallelism.
        .thread_pool = .{ .count = 8 },
    }, app) catch {
        gpa.destroy(server);
        return false;
    };

    var router = server.router(.{}) catch {
        server.deinit();
        gpa.destroy(server);
        return false;
    };
    const P = builtin_mod.PATH_PREFIX;
    router.get(P ++ "/api/version", version, .{});
    router.post(P ++ "/api/show", show, .{});
    router.post(P ++ "/api/generate", generate, .{});
    router.post(P ++ "/api/chat", chat, .{});
    router.post(P ++ "/v1/chat/completions", oaiChat, .{});

    const t = std.Thread.spawn(.{}, listenLoop, .{server}) catch {
        server.deinit();
        gpa.destroy(server);
        return false;
    };
    t.detach();
    g_server = server;
    return true;
}

fn listenLoop(server: *httpz.Server(*EndpointApp)) void {
    server.listen() catch |e| {
        log.err("endpoint listener stopped: {t}", .{e});
        builtin_mod.setPort(0); // resolution goes null instead of handing out a dead base
    };
}

// ---- handlers ------------------------------------------------------------------------------------

fn version(_: *EndpointApp, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body = "{\"version\":\"" ++ DIALECT_VERSION ++ "\"}";
}

/// Bearer gate for everything but /api/version. The secret is per-boot; a stale client re-resolves.
fn authed(req: *httpz.Request, res: *httpz.Response) bool {
    const h = req.header("authorization") orelse "";
    const want = builtin_mod.secret();
    if (want.len > 0 and std.mem.startsWith(u8, h, "Bearer ") and std.mem.eql(u8, std.mem.trim(u8, h[7..], " \r\n\t"), want)) return true;
    res.content_type = .JSON;
    res.status = 401;
    res.body = "{\"error\":\"unauthorized: this endpoint takes the per-boot builtin bearer\"}";
    return false;
}

/// /api/show — the capability record the startup probe folds into caps (llm.parseShowCaps):
/// family (wire format), capabilities[], the SERVING window, and the parameter count.
fn show(app: *EndpointApp, req: *httpz.Request, res: *httpz.Response) !void {
    if (!authed(req, res)) return;
    res.content_type = .JSON;
    const inf = app.eng.info(app.eng.ctx);
    const arch = if (inf.arch_len > 0) inf.archName() else "gemma4";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const arena = res.arena;
    try out.appendSlice(arena, "{\"details\":{\"family\":");
    try llm.jstr(arena, &out, arch);
    try out.appendSlice(arena, "},\"capabilities\":[\"completion\",\"tools\"],\"model_info\":{");
    try out.print(arena, "\"{s}.context_length\":{d},\"general.parameter_count\":{d}", .{ arch, inf.ctx_serving, @as(u64, inf.params_b) * 1_000_000_000 });
    try out.appendSlice(arena, "}}");
    res.body = out.items;
}

/// Engine state as an { "error": … } the llm client surfaces verbatim, or null when serving is
/// possible. Written once here so every generation route says the same true thing.
fn engineGate(app: *EndpointApp, res: *httpz.Response) !bool {
    const inf = app.eng.info(app.eng.ctx);
    const msg: ?[]const u8 = switch (inf.state) {
        .absent => "no weights: download the built-in model first (Settings -> Built-in, or `veil model pull`)",
        .failed => if (inf.err_len > 0) inf.errMsg() else "the weights file could not be loaded",
        else => null,
    };
    if (msg) |m| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(res.arena, "{\"error\":");
        try llm.jstr(res.arena, &out, m);
        try out.appendSlice(res.arena, "}");
        res.body = out.items;
        return false;
    }
    return true;
}

const Opts = struct {
    n_predict: u32 = 2048,
    temp: f32 = -1,
    top_p: f32 = 0,
    stops: [4][]const u8 = .{ "", "", "", "" },
    n_stops: usize = 0,

    fn stopSlices(self: *const Opts) []const []const u8 {
        return self.stops[0..self.n_stops];
    }
};

/// Fold the request's options{} into engine terms. Unknown fields ignored; num_ctx is accepted and
/// ignored (the serving window is fixed at engine configure — /api/show already reports it, so a
/// well-behaved client never asks for more).
fn readOpts(v: std.json.Value) Opts {
    var o = Opts{};
    const root = if (v == .object) v.object else return o;
    const opts = if (root.get("options")) |ov| (if (ov == .object) ov.object else return o) else return o;
    if (opts.get("num_predict")) |p| if (p == .integer and p.integer > 0) {
        o.n_predict = @intCast(@min(p.integer, 65536));
    };
    if (opts.get("temperature")) |t| switch (t) {
        .float => o.temp = @floatCast(t.float),
        .integer => o.temp = @floatFromInt(t.integer),
        else => {},
    };
    if (opts.get("top_p")) |t| switch (t) {
        .float => o.top_p = @floatCast(t.float),
        .integer => o.top_p = @floatFromInt(t.integer),
        else => {},
    };
    if (opts.get("stop")) |s| if (s == .array) {
        for (s.array.items) |item| {
            if (o.n_stops >= o.stops.len) break;
            if (item == .string and item.string.len > 0) {
                o.stops[o.n_stops] = item.string;
                o.n_stops += 1;
            }
        }
    };
    return o;
}

fn boolField(v: std.json.Value, name: []const u8) bool {
    if (v != .object) return false;
    const f = v.object.get(name) orelse return false;
    return f == .bool and f.bool;
}

/// The RAW inner text of a top-level `"key": [ … ]` array — brackets excluded — or null. The
/// slice aliases `body`: rendering must see the caller's exact bytes (key order, number spelling),
/// not a reserialization; this is the same fidelity rule ollamaNativeBody lives by.
fn rawArrayInner(body: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 2 > kbuf.len) return null;
    const needle = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, body, from, needle)) |at| {
        from = at + 1;
        // must be a KEY: next non-ws is ':', then next non-ws is '['
        var i = at + needle.len;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\r' or body[i] == '\n')) i += 1;
        if (i >= body.len or body[i] != ':') continue;
        i += 1;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\r' or body[i] == '\n')) i += 1;
        if (i >= body.len or body[i] != '[') continue;
        // bracket-match, string-aware
        var depth: usize = 0;
        var in_str = false;
        var j = i;
        while (j < body.len) : (j += 1) {
            const c = body[j];
            if (in_str) {
                if (c == '\\') j += 1 else if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '[', '{' => depth += 1,
                ']', '}' => {
                    depth -= 1;
                    if (depth == 0) return body[i + 1 .. j];
                },
                else => {},
            }
        }
        return null; // unterminated
    }
    return null;
}

/// /api/generate with raw:true — the pre-rendered-prompt door (llm.completeGemma4Raw). The prompt
/// is the caller's bytes verbatim; this route never renders.
fn generate(app: *EndpointApp, req: *httpz.Request, res: *httpz.Response) !void {
    if (!authed(req, res)) return;
    res.content_type = .JSON;
    if (!try engineGate(app, res)) return;
    const arena = res.arena;
    const body = req.body() orelse "";
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"body is not JSON\"}";
        return;
    };
    const v = parsed.value;
    if (!boolField(v, "raw")) {
        res.status = 400;
        res.body = "{\"error\":\"this endpoint serves raw prompts only (raw:true) - use /api/chat for messages\"}";
        return;
    }
    const prompt: []const u8 = blk: {
        if (v == .object) if (v.object.get("prompt")) |p| if (p == .string) break :blk p.string;
        res.status = 400;
        res.body = "{\"error\":\"missing prompt\"}";
        return;
    };
    const o = readOpts(v);
    const streaming = boolField(v, "stream");

    if (!streaming) {
        const r = runEngine(app, arena, res, .{
            .prompt = prompt,
            .n_predict = o.n_predict,
            .temp = o.temp,
            .top_p = o.top_p,
            .stops = o.stopSlices(),
        }) orelse return;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(arena, "{\"model\":\"" ++ builtin_mod.MODEL_ID ++ "\",\"response\":");
        try llm.jstr(arena, &out, r.text);
        try out.print(arena, ",\"done\":true,\"done_reason\":\"{s}\",\"eval_count\":{d},\"prompt_eval_count\":{d}}}", .{
            if (r.truncated) "length" else "stop", r.gen_tokens, r.prompt_tokens,
        });
        res.body = out.items;
        return;
    }

    // streamed NDJSON: {"response":piece,"done":false}… then the terminal counts line
    var sink = RawSink{ .res = res, .arena = arena };
    const r = app.eng.generate(app.eng.ctx, arena, .{
        .prompt = prompt,
        .n_predict = o.n_predict,
        .temp = o.temp,
        .top_p = o.top_p,
        .stops = o.stopSlices(),
        .sink_ctx = @ptrCast(&sink),
        .on_piece = RawSink.onPiece,
    }) catch |e| {
        // nothing streamed yet → a plain error body still reaches the client whole
        if (!sink.started) return engineErr(res, e);
        return;
    };
    sink.flushTail();
    var line: std.ArrayListUnmanaged(u8) = .empty;
    try line.print(arena, "{{\"response\":\"\",\"done\":true,\"done_reason\":\"{s}\",\"eval_count\":{d},\"prompt_eval_count\":{d}}}\n", .{
        if (r.truncated) "length" else "stop", r.gen_tokens, r.prompt_tokens,
    });
    res.chunk(line.items) catch {};
}

/// Streaming sink for /api/generate: each piece is one NDJSON line. Holds back a trailing
/// incomplete UTF-8 sequence so every emitted line is valid JSON for line-at-a-time readers.
const RawSink = struct {
    res: *httpz.Response,
    arena: std.mem.Allocator,
    started: bool = false,
    carry: [4]u8 = undefined,
    carry_n: usize = 0,

    fn onPiece(ctx: *anyopaque, piece: []const u8) bool {
        const self: *RawSink = @ptrCast(@alignCast(ctx));
        return self.emit(piece);
    }

    fn emit(self: *RawSink, piece: []const u8) bool {
        var buf: [520]u8 = undefined;
        var have: usize = 0;
        @memcpy(buf[0..self.carry_n], self.carry[0..self.carry_n]);
        have = self.carry_n;
        self.carry_n = 0;
        var i: usize = 0;
        while (i < piece.len) {
            const take = @min(piece.len - i, buf.len - have);
            @memcpy(buf[have .. have + take], piece[i .. i + take]);
            have += take;
            i += take;
            const cut = utf8SafeLen(buf[0..have]);
            if (cut > 0) {
                if (!self.line(buf[0..cut])) return false;
            }
            const rem = have - cut;
            if (rem > self.carry.len) { // not a codepoint boundary issue — emit raw rather than stall
                if (!self.line(buf[cut..have])) return false;
                have = 0;
            } else {
                @memcpy(buf[0..rem], buf[cut..have]);
                have = rem;
            }
        }
        if (have <= self.carry.len) {
            @memcpy(self.carry[0..have], buf[0..have]);
            self.carry_n = have;
        } else if (have > 0) {
            if (!self.line(buf[0..have])) return false;
        }
        return true;
    }

    fn line(self: *RawSink, bytes: []const u8) bool {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(self.arena, "{\"response\":") catch return false;
        llm.jstr(self.arena, &out, bytes) catch return false;
        out.appendSlice(self.arena, ",\"done\":false}\n") catch return false;
        self.started = true;
        self.res.chunk(out.items) catch return false; // client hung up → abort the generation
        return true;
    }

    fn flushTail(self: *RawSink) void {
        if (self.carry_n > 0) {
            _ = self.line(self.carry[0..self.carry_n]);
            self.carry_n = 0;
        }
    }
};

/// Longest prefix of `b` that ends on a UTF-8 codepoint boundary.
fn utf8SafeLen(b: []const u8) usize {
    if (b.len == 0) return 0;
    var i = b.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        i -= 1;
        back += 1;
        const c = b[i];
        if (c < 0x80) return i + 1; // ascii tail byte is always complete
        if (c >= 0xC0) { // lead byte: complete only if its full sequence is present
            const need: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else 2;
            return if (b.len - i >= need) b.len else i;
        }
    }
    return b.len; // not utf8 at all — pass through rather than stall
}

fn engineErr(res: *httpz.Response, e: anyerror) !void {
    const msg = switch (e) {
        error.NoWeights => "no weights: download the built-in model first",
        error.PromptTooLong => "prompt exceeds the serving context window",
        error.LoadFailed => "the weights file could not be loaded",
        error.DecodeFailed => "inference failed mid-generation",
        else => "built-in engine error",
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(res.arena, "{\"error\":");
    try llm.jstr(res.arena, &out, msg);
    try out.appendSlice(res.arena, "}");
    res.body = out.items;
}

fn runEngine(app: *EndpointApp, arena: std.mem.Allocator, res: *httpz.Response, greq: builtin_mod.GenReq) ?builtin_mod.GenRes {
    return app.eng.generate(app.eng.ctx, arena, greq) catch |e| {
        engineErr(res, e) catch {};
        return null;
    };
}

/// /api/chat — messages (+tools) in, rendered through gemma4.renderPrompt, native reply out.
/// Stop is the turn terminator, so the model's turn structure never leaks into content.
fn chat(app: *EndpointApp, req: *httpz.Request, res: *httpz.Response) !void {
    if (!authed(req, res)) return;
    res.content_type = .JSON;
    if (!try engineGate(app, res)) return;
    const arena = res.arena;
    const body = req.body() orelse "";
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"body is not JSON\"}";
        return;
    };
    const msgs_inner = rawArrayInner(body, "messages") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing messages\"}";
        return;
    };
    const tools_inner = rawArrayInner(body, "tools") orelse "";
    const prompt = gemma4.renderPrompt(arena, msgs_inner, tools_inner) catch {
        res.status = 400;
        res.body = "{\"error\":\"conversation could not be rendered\"}";
        return;
    };
    var o = readOpts(parsed.value);
    if (o.n_stops == 0) {
        o.stops[0] = "<turn|>";
        o.n_stops = 1;
    }
    const greq_base = builtin_mod.GenReq{
        .prompt = prompt,
        .n_predict = o.n_predict,
        .temp = o.temp,
        .top_p = o.top_p,
        .stops = o.stopSlices(),
    };

    if (!boolField(parsed.value, "stream")) {
        const r = runEngine(app, arena, res, greq_base) orelse return;
        const reply = gemma4.parseCompletion(arena, r.text) catch {
            res.body = "{\"error\":\"completion could not be parsed\"}";
            return;
        };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(arena, "{\"model\":\"" ++ builtin_mod.MODEL_ID ++ "\",\"message\":{\"role\":\"assistant\",\"content\":");
        try llm.jstr(arena, &out, reply.content);
        if (reply.thinking.len > 0) {
            try out.appendSlice(arena, ",\"thinking\":");
            try llm.jstr(arena, &out, reply.thinking);
        }
        try appendToolCalls(arena, &out, reply.calls);
        try out.print(arena, "}},\"done\":true,\"done_reason\":\"{s}\",\"eval_count\":{d},\"prompt_eval_count\":{d}}}", .{
            if (r.truncated) "length" else "stop", r.gen_tokens, r.prompt_tokens,
        });
        res.body = out.items;
        return;
    }

    // streamed: live content/thinking deltas (wire markers withheld), then the calls, then done.
    var sink = ChatSink{ .res = res, .arena = arena, .machine = .{} };
    const r = app.eng.generate(app.eng.ctx, arena, .{
        .prompt = greq_base.prompt,
        .n_predict = greq_base.n_predict,
        .temp = greq_base.temp,
        .top_p = greq_base.top_p,
        .stops = greq_base.stops,
        .sink_ctx = @ptrCast(&sink),
        .on_piece = ChatSink.onPiece,
    }) catch |e| {
        if (!sink.started) return engineErr(res, e);
        return;
    };
    const reply = gemma4.parseCompletion(arena, r.text) catch gemma4.Reply{
        .content = try arena.dupe(u8, ""),
        .thinking = try arena.dupe(u8, ""),
        .calls = &.{},
    };
    if (reply.calls.len > 0) {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        try line.appendSlice(arena, "{\"message\":{\"role\":\"assistant\",\"content\":\"\"");
        try appendToolCalls(arena, &line, reply.calls);
        try line.appendSlice(arena, "},\"done\":false}\n");
        res.chunk(line.items) catch {};
    }
    var fin: std.ArrayListUnmanaged(u8) = .empty;
    try fin.print(arena, "{{\"message\":{{\"role\":\"assistant\",\"content\":\"\"}},\"done\":true,\"done_reason\":\"{s}\",\"eval_count\":{d},\"prompt_eval_count\":{d}}}\n", .{
        if (r.truncated) "length" else "stop", r.gen_tokens, r.prompt_tokens,
    });
    res.chunk(fin.items) catch {};
}

fn appendToolCalls(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), calls: []const gemma4.Call) !void {
    if (calls.len == 0) return;
    try out.appendSlice(arena, ",\"tool_calls\":[");
    for (calls, 0..) |c, i| {
        if (i > 0) try out.appendSlice(arena, ",");
        try out.appendSlice(arena, "{\"function\":{\"name\":");
        try llm.jstr(arena, out, c.name);
        try out.appendSlice(arena, ",\"arguments\":");
        try out.appendSlice(arena, c.args_json); // parseCompletion guarantees a well-formed object
        try out.appendSlice(arena, "}}");
    }
    try out.appendSlice(arena, "]");
}

/// The live-delta channel machine for streamed /api/chat. Content flows through; a thought
/// channel is rerouted to `thinking` deltas; everything from a tool-call open to its close is
/// swallowed (the parsed calls follow as one line, exactly like the reference backend). A
/// trailing partial marker is withheld until it either completes or turns out to be plain text.
pub const ChanMachine = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    fed: usize = 0, // bytes of buf already routed
    mode: enum { content, thinking, swallow } = .content,

    const TH_OPEN = "<|channel>thought\n";
    const TH_CLOSE = "<channel|>";
    const TC_OPEN = "<|tool_call>";
    const TC_CLOSE = "<tool_call|>";
    const marks = [_][]const u8{ TH_OPEN, TH_CLOSE, TC_OPEN, TC_CLOSE };

    pub const Out = struct { kind: enum { content, thinking }, bytes: []const u8 };

    /// Feed a piece; `emit` receives routed deltas. Returns false if emit said stop.
    pub fn feed(self: *ChanMachine, gpa: std.mem.Allocator, piece: []const u8, ctx: *anyopaque, emit: *const fn (*anyopaque, Out) bool) bool {
        self.buf.appendSlice(gpa, piece) catch return false;
        while (true) {
            const pending = self.buf.items[self.fed..];
            if (pending.len == 0) return true;
            switch (self.mode) {
                .content => {
                    if (firstMark(pending)) |m| {
                        if (m.at > 0) {
                            if (!emit(ctx, .{ .kind = .content, .bytes = pending[0..m.at] })) return false;
                            self.fed += m.at;
                        }
                        if (m.which == null) return true; // partial marker tail — wait for more bytes
                        const mk = m.which.?;
                        self.fed += mk.len;
                        if (std.mem.eql(u8, mk, TH_OPEN)) self.mode = .thinking else if (std.mem.eql(u8, mk, TC_OPEN)) self.mode = .swallow;
                        // stray closes in content are dropped silently — same as parseCompletion
                    } else {
                        if (!emit(ctx, .{ .kind = .content, .bytes = pending })) return false;
                        self.fed += pending.len;
                    }
                },
                .thinking => {
                    if (std.mem.indexOf(u8, pending, TH_CLOSE)) |at| {
                        if (at > 0 and !emit(ctx, .{ .kind = .thinking, .bytes = pending[0..at] })) return false;
                        self.fed += at + TH_CLOSE.len;
                        self.mode = .content;
                    } else {
                        const hold = markPrefixTail(pending, TH_CLOSE);
                        const upto = pending.len - hold;
                        if (upto > 0) {
                            if (!emit(ctx, .{ .kind = .thinking, .bytes = pending[0..upto] })) return false;
                            self.fed += upto;
                        }
                        return true;
                    }
                },
                .swallow => {
                    if (std.mem.indexOf(u8, pending, TC_CLOSE)) |at| {
                        self.fed += at + TC_CLOSE.len;
                        self.mode = .content;
                    } else {
                        // swallow, but never past a partial close — consuming its bytes one feed at
                        // a time would leave indexOf unable to ever see the whole marker
                        const hold = ChanMachine.markPrefixTail(pending, TC_CLOSE);
                        self.fed += pending.len - hold;
                        return true;
                    }
                },
            }
        }
    }

    pub fn deinit(self: *ChanMachine, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    const Mark = struct { at: usize, which: ?[]const u8 };

    /// Earliest full marker in `s`, or — if `s` ENDS in a strict prefix of some marker — that
    /// position with which=null ("wait"). Text before either is safe to route.
    fn firstMark(s: []const u8) ?Mark {
        var best: ?Mark = null;
        for (marks) |m| {
            if (std.mem.indexOf(u8, s, m)) |at| {
                if (best == null or at < best.?.at) best = .{ .at = at, .which = m };
            }
        }
        var tail: ?usize = null;
        for (marks) |m| {
            const h = markPrefixTail(s, m);
            if (h > 0) {
                const at = s.len - h;
                if (tail == null or at < tail.?) tail = at;
            }
        }
        if (tail) |t| {
            if (best == null or t < best.?.at) return .{ .at = t, .which = null };
        }
        return best;
    }

    /// Longest k (>=1, < mark.len) such that s ends with mark[0..k].
    fn markPrefixTail(s: []const u8, mark: []const u8) usize {
        var k = @min(s.len, mark.len - 1);
        while (k > 0) : (k -= 1) {
            if (std.mem.eql(u8, s[s.len - k ..], mark[0..k])) return k;
        }
        return 0;
    }
};

const ChatSink = struct {
    res: *httpz.Response,
    arena: std.mem.Allocator,
    machine: ChanMachine,
    started: bool = false,
    failed: bool = false,

    fn onPiece(ctx: *anyopaque, piece: []const u8) bool {
        const self: *ChatSink = @ptrCast(@alignCast(ctx));
        return self.machine.feed(self.arena, piece, @ptrCast(self), emitOut);
    }

    fn emitOut(ctx: *anyopaque, o: ChanMachine.Out) bool {
        const self: *ChatSink = @ptrCast(@alignCast(ctx));
        if (self.failed) return false;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(self.arena, if (o.kind == .thinking)
            "{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"thinking\":"
        else
            "{\"message\":{\"role\":\"assistant\",\"content\":") catch return false;
        llm.jstr(self.arena, &out, o.bytes) catch return false;
        if (o.kind == .thinking) {
            out.appendSlice(self.arena, "},\"done\":false}\n") catch return false;
        } else {
            out.appendSlice(self.arena, "},\"done\":false}\n") catch return false;
        }
        self.started = true;
        self.res.chunk(out.items) catch {
            self.failed = true; // client hung up — abort the generation instead of decoding to a void
            return false;
        };
        return true;
    }
};

/// /v1/chat/completions — the OpenAI-compatible door for the one-shot helpers (llm.chat/chatTemp)
/// and any generic client. Renders through the SAME gemma4 pipeline. `stream:true` answers SSE.
fn oaiChat(app: *EndpointApp, req: *httpz.Request, res: *httpz.Response) !void {
    if (!authed(req, res)) return;
    res.content_type = .JSON;
    if (!try engineGate(app, res)) return;
    const arena = res.arena;
    const body = req.body() orelse "";
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":{\"message\":\"body is not JSON\"}}";
        return;
    };
    const msgs_inner = rawArrayInner(body, "messages") orelse {
        res.status = 400;
        res.body = "{\"error\":{\"message\":\"missing messages\"}}";
        return;
    };
    if (std.mem.indexOf(u8, msgs_inner, "\"image_url\"") != null) {
        res.body = "{\"error\":{\"message\":\"the built-in engine is text-only (no vision)\"}}";
        return;
    }
    const tools_inner = rawArrayInner(body, "tools") orelse "";
    const prompt = gemma4.renderPrompt(arena, msgs_inner, tools_inner) catch {
        res.status = 400;
        res.body = "{\"error\":{\"message\":\"conversation could not be rendered\"}}";
        return;
    };
    // OpenAI-shaped knobs live at the TOP level here, not options{}
    var n_predict: u32 = 2048;
    var temp: f32 = -1;
    if (parsed.value == .object) {
        if (parsed.value.object.get("max_tokens")) |m| if (m == .integer and m.integer > 0) {
            n_predict = @intCast(@min(m.integer, 65536));
        };
        if (parsed.value.object.get("temperature")) |t| switch (t) {
            .float => temp = @floatCast(t.float),
            .integer => temp = @floatFromInt(t.integer),
            else => {},
        };
    }
    const stops = [_][]const u8{"<turn|>"};

    if (!boolField(parsed.value, "stream")) {
        const r = runEngineOai(app, arena, res, .{
            .prompt = prompt,
            .n_predict = n_predict,
            .temp = temp,
            .stops = &stops,
        }) orelse return;
        const reply = gemma4.parseCompletion(arena, r.text) catch gemma4.Reply{
            .content = try arena.dupe(u8, r.text),
            .thinking = try arena.dupe(u8, ""),
            .calls = &.{},
        };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(arena, "{\"id\":\"chatcmpl-builtin\",\"object\":\"chat.completion\",\"model\":\"" ++ builtin_mod.MODEL_ID ++ "\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":");
        try llm.jstr(arena, &out, reply.content);
        try out.print(arena, "}},\"finish_reason\":\"{s}\"}}],\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}}}", .{
            if (r.truncated) "length" else "stop", r.prompt_tokens, r.gen_tokens, r.prompt_tokens + r.gen_tokens,
        });
        res.body = out.items;
        return;
    }

    // SSE stream for direct OpenAI-style clients
    var sink = SseSink{ .res = res, .arena = arena, .machine = .{} };
    const r = app.eng.generate(app.eng.ctx, arena, .{
        .prompt = prompt,
        .n_predict = n_predict,
        .temp = temp,
        .stops = &stops,
        .sink_ctx = @ptrCast(&sink),
        .on_piece = SseSink.onPiece,
    }) catch {
        if (!sink.started) res.body = "{\"error\":{\"message\":\"built-in engine error\"}}";
        return;
    };
    var fin: std.ArrayListUnmanaged(u8) = .empty;
    try fin.print(arena, "data: {{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}],\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}}}\n\ndata: [DONE]\n\n", .{
        if (r.truncated) "length" else "stop", r.prompt_tokens, r.gen_tokens, r.prompt_tokens + r.gen_tokens,
    });
    res.chunk(fin.items) catch {};
}

fn runEngineOai(app: *EndpointApp, arena: std.mem.Allocator, res: *httpz.Response, greq: builtin_mod.GenReq) ?builtin_mod.GenRes {
    return app.eng.generate(app.eng.ctx, arena, greq) catch |e| {
        const msg = switch (e) {
            error.NoWeights => "no weights: download the built-in model first",
            error.PromptTooLong => "prompt exceeds the serving context window",
            else => "built-in engine error",
        };
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(arena, "{\"error\":{\"message\":") catch return null;
        llm.jstr(arena, &out, msg) catch return null;
        out.appendSlice(arena, "}}") catch return null;
        res.body = out.items;
        return null;
    };
}

const SseSink = struct {
    res: *httpz.Response,
    arena: std.mem.Allocator,
    machine: ChanMachine,
    started: bool = false,

    fn onPiece(ctx: *anyopaque, piece: []const u8) bool {
        const self: *SseSink = @ptrCast(@alignCast(ctx));
        return self.machine.feed(self.arena, piece, @ptrCast(self), emitOut);
    }

    fn emitOut(ctx: *anyopaque, o: ChanMachine.Out) bool {
        const self: *SseSink = @ptrCast(@alignCast(ctx));
        if (o.kind == .thinking) return true; // OpenAI clients have no thinking channel — drop
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(self.arena, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":") catch return false;
        llm.jstr(self.arena, &out, o.bytes) catch return false;
        out.appendSlice(self.arena, "}}]}\n\n") catch return false;
        self.started = true;
        self.res.chunk(out.items) catch return false;
        return true;
    }
};

// ---- tests (mock engine — no weights, no C) ------------------------------------------------------

const MockEng = struct {
    reply: []const u8 = "",
    fail: ?anyerror = null,
    state: builtin_mod.EngState = .cold,
    prompt_seen: std.ArrayListUnmanaged(u8) = .empty,
    gpa: std.mem.Allocator = undefined,

    fn engine(self: *MockEng) builtin_mod.Engine {
        return .{ .ctx = @ptrCast(self), .generate = gen, .info = info };
    }
    fn gen(ctx: *anyopaque, gpa: std.mem.Allocator, req: builtin_mod.GenReq) anyerror!builtin_mod.GenRes {
        const self: *MockEng = @ptrCast(@alignCast(ctx));
        if (self.fail) |e| return e;
        self.prompt_seen.clearRetainingCapacity();
        try self.prompt_seen.appendSlice(self.gpa, req.prompt);
        // honor stops the way the real engine does, so tests exercise the withholding contract
        var text: []const u8 = self.reply;
        for (req.stops) |s| {
            if (s.len == 0) continue;
            if (std.mem.indexOf(u8, text, s)) |at| text = text[0..at];
        }
        if (req.on_piece) |cb| {
            // feed in 3-byte pieces to exercise partial-marker handling in the sinks
            var i: usize = 0;
            while (i < text.len) {
                const n = @min(3, text.len - i);
                if (!cb(req.sink_ctx.?, text[i .. i + n])) break;
                i += n;
            }
        }
        return .{ .text = try gpa.dupe(u8, text), .prompt_tokens = 7, .gen_tokens = 5, .truncated = false };
    }
    fn info(ctx: *anyopaque) builtin_mod.Info {
        const self: *MockEng = @ptrCast(@alignCast(ctx));
        var inf = builtin_mod.Info{ .state = self.state, .ctx_serving = 8192, .params_b = 12 };
        const arch = "gemma4";
        @memcpy(inf.arch[0..arch.len], arch);
        inf.arch_len = arch.len;
        return inf;
    }
    fn deinit(self: *MockEng) void {
        self.prompt_seen.deinit(self.gpa);
    }
};

fn testApp(gpa: std.mem.Allocator, io: std.Io, mock: *MockEng) EndpointApp {
    mock.gpa = gpa;
    return .{ .gpa = gpa, .io = io, .eng = mock.engine() };
}

/// TEST ONLY. The per-boot secret as a request must send it. builtin.init also mints the secret,
/// against a throwaway cwd-relative data root the caller cleans with `testBearerCleanup`.
const TEST_ROOT = "zig-builtin-endpoint-tmp";
fn testBearer(io: std.Io, buf: []u8) []const u8 {
    std.Io.Dir.cwd().deleteTree(io, TEST_ROOT) catch {};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    builtin_mod.init(io, &env, TEST_ROOT);
    return std.fmt.bufPrint(buf, "Bearer {s}", .{builtin_mod.secret()}) catch unreachable;
}
fn testBearerCleanup(io: std.Io) void {
    std.Io.Dir.cwd().deleteTree(io, TEST_ROOT) catch {};
}

test "auth gate: every generation route refuses a caller without the boot bearer, version stays open" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mock = MockEng{};
    defer mock.deinit();
    var app = testApp(gpa, io, &mock);

    {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        try version(&app, web.req, web.res);
        try web.expectStatus(200);
        try web.expectJson(.{ .version = DIALECT_VERSION });
    }
    inline for (.{ show, generate, chat, oaiChat }) |h| {
        var web = httpz.testing.init(.{});
        defer web.deinit();
        web.body("{}");
        try h(&app, web.req, web.res);
        try web.expectStatus(401);
    }
}

test "/api/show reports the family, the SERVING window and the parameter count in the shapes the probe folds" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mock = MockEng{};
    defer mock.deinit();
    var app = testApp(gpa, io, &mock);
    var bbuf: [64]u8 = undefined;
    const bearer = testBearer(io, &bbuf);
    defer testBearerCleanup(io);

    var web = httpz.testing.init(.{});
    defer web.deinit();
    web.header("authorization", bearer);
    web.body("{\"model\":\"the-veil-12b\"}");
    try show(&app, web.req, web.res);
    try web.expectStatus(200);
    const body = try web.getBody();
    const p = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer p.deinit();
    const root = p.value.object;
    try std.testing.expectEqualStrings("gemma4", root.get("details").?.object.get("family").?.string);
    try std.testing.expectEqual(@as(i64, 8192), root.get("model_info").?.object.get("gemma4.context_length").?.integer);
    try std.testing.expectEqual(@as(i64, 12_000_000_000), root.get("model_info").?.object.get("general.parameter_count").?.integer);
    var saw_tools = false;
    for (root.get("capabilities").?.array.items) |c| {
        if (c == .string and std.mem.eql(u8, c.string, "tools")) saw_tools = true;
    }
    try std.testing.expect(saw_tools);
}

test "/api/generate raw: the prompt reaches the engine verbatim and the reply carries the native counts" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mock = MockEng{ .reply = "hello from the engine" };
    defer mock.deinit();
    var app = testApp(gpa, io, &mock);
    var bbuf: [64]u8 = undefined;
    const bearer = testBearer(io, &bbuf);
    defer testBearerCleanup(io);

    var web = httpz.testing.init(.{});
    defer web.deinit();
    web.header("authorization", bearer);
    web.body("{\"model\":\"the-veil-12b\",\"prompt\":\"<bos>ping\",\"raw\":true,\"stream\":false,\"options\":{\"num_predict\":64,\"stop\":[\"<turn|>\"]}}");
    try generate(&app, web.req, web.res);
    try web.expectStatus(200);
    const body = try web.getBody();
    const p = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("hello from the engine", p.value.object.get("response").?.string);
    try std.testing.expectEqual(@as(i64, 5), p.value.object.get("eval_count").?.integer);
    try std.testing.expectEqual(@as(i64, 7), p.value.object.get("prompt_eval_count").?.integer);
    try std.testing.expect(p.value.object.get("done").?.bool);
    try std.testing.expectEqualStrings("<bos>ping", mock.prompt_seen.items);

    // non-raw is refused: this door exists for pre-rendered prompts only
    var web2 = httpz.testing.init(.{});
    defer web2.deinit();
    web2.header("authorization", bearer);
    web2.body("{\"prompt\":\"x\"}");
    try generate(&app, web2.req, web2.res);
    try web2.expectStatus(400);
}

test "/api/chat renders through gemma4 and maps a tool-call completion to structured native tool_calls" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // reply carries a thought, prose, and one tool call in the trained wire format
    var mock = MockEng{ .reply = "<|channel>thought\nplan it\n<channel|>on it\n<|tool_call>call:write_file{content:<|\"|>hi<|\"|>,path:<|\"|>a.txt<|\"|>}<tool_call|>" };
    defer mock.deinit();
    var app = testApp(gpa, io, &mock);
    var bbuf: [64]u8 = undefined;
    const bearer = testBearer(io, &bbuf);
    defer testBearerCleanup(io);

    var web = httpz.testing.init(.{});
    defer web.deinit();
    web.header("authorization", bearer);
    web.body("{\"model\":\"the-veil-12b\",\"messages\":[{\"role\":\"user\",\"content\":\"write a.txt\"}],\"tools\":[{\"name\":\"write_file\",\"parameters\":{\"type\":\"object\"}}],\"stream\":false,\"options\":{\"num_predict\":128}}");
    try chat(&app, web.req, web.res);
    try web.expectStatus(200);
    const body = try web.getBody();
    const p = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer p.deinit();
    const msg = p.value.object.get("message").?.object;
    try std.testing.expectEqualStrings("on it", msg.get("content").?.string);
    try std.testing.expectEqualStrings("plan it\n", msg.get("thinking").?.string);
    const calls = msg.get("tool_calls").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    const f = calls[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("write_file", f.get("name").?.string);
    try std.testing.expectEqualStrings("hi", f.get("arguments").?.object.get("content").?.string);
    // and the engine saw a RENDERED prompt: system-with-declaration, user turn, generation suffix
    try std.testing.expect(std.mem.indexOf(u8, mock.prompt_seen.items, "<|tool>declaration:write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.prompt_seen.items, "<|turn>user\nwrite a.txt") != null);
    try std.testing.expect(std.mem.endsWith(u8, mock.prompt_seen.items, gemma4.GEN_SUFFIX));
}

test "engine gate: absent weights answer the actionable error instead of a stack of transport noise" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mock = MockEng{ .state = .absent };
    defer mock.deinit();
    var app = testApp(gpa, io, &mock);
    var bbuf: [64]u8 = undefined;
    const bearer = testBearer(io, &bbuf);
    defer testBearerCleanup(io);

    var web = httpz.testing.init(.{});
    defer web.deinit();
    web.header("authorization", bearer);
    web.body("{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}");
    try chat(&app, web.req, web.res);
    const body = try web.getBody();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "download the built-in model") != null);
}

test "rawArrayInner slices the caller's exact bytes: nesting, strings with brackets, absent keys" {
    const body = "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"a ] tricky [ one\"},{\"x\":[1,2]}],\"tools\":[]}";
    const inner = rawArrayInner(body, "messages").?;
    try std.testing.expectEqualStrings("{\"role\":\"user\",\"content\":\"a ] tricky [ one\"},{\"x\":[1,2]}", inner);
    try std.testing.expectEqualStrings("", rawArrayInner(body, "tools").?);
    try std.testing.expect(rawArrayInner(body, "nope") == null);
    // a key whose value is not an array must not match
    try std.testing.expect(rawArrayInner("{\"messages\":\"not-an-array\"}", "messages") == null);
    // escaped quotes inside strings do not derail the bracket scan
    const esc = "{\"messages\":[{\"content\":\"say \\\"hi]\\\" now\"}]}";
    try std.testing.expectEqualStrings("{\"content\":\"say \\\"hi]\\\" now\"}", rawArrayInner(esc, "messages").?);
}

test "channel machine: content flows live, thought reroutes, tool calls are swallowed, split markers never leak" {
    const gpa = std.testing.allocator;
    const Cap = struct {
        content: std.ArrayListUnmanaged(u8) = .empty,
        thinking: std.ArrayListUnmanaged(u8) = .empty,
        fn emit(ctx: *anyopaque, o: ChanMachine.Out) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const list = if (o.kind == .thinking) &self.thinking else &self.content;
            list.appendSlice(std.testing.allocator, o.bytes) catch return false;
            return true;
        }
    };
    var cap = Cap{};
    defer cap.content.deinit(gpa);
    defer cap.thinking.deinit(gpa);
    var m = ChanMachine{};
    defer m.deinit(gpa);

    const full = "<|channel>thought\nthink hard\n<channel|>prose with < and <| inside<|tool_call>call:x{}<tool_call|> tail";
    // feed byte-by-byte: every marker is split across feeds, the harshest case
    for (0..full.len) |i| {
        try std.testing.expect(m.feed(gpa, full[i .. i + 1], @ptrCast(&cap), Cap.emit));
    }
    try std.testing.expectEqualStrings("think hard\n", cap.thinking.items);
    try std.testing.expectEqualStrings("prose with < and <| inside tail", cap.content.items);
    try std.testing.expect(std.mem.indexOf(u8, cap.content.items, "tool_call") == null);
}

test "/v1/chat/completions answers the OpenAI shape with usage, and refuses image parts honestly" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var mock = MockEng{ .reply = "plain answer<turn|>ignored" };
    defer mock.deinit();
    var app = testApp(gpa, io, &mock);
    var bbuf: [64]u8 = undefined;
    const bearer = testBearer(io, &bbuf);
    defer testBearerCleanup(io);

    var web = httpz.testing.init(.{});
    defer web.deinit();
    web.header("authorization", bearer);
    web.body("{\"model\":\"the-veil-12b\",\"messages\":[{\"role\":\"system\",\"content\":\"be brief\"},{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":32}");
    try oaiChat(&app, web.req, web.res);
    try web.expectStatus(200);
    const body = try web.getBody();
    const p = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer p.deinit();
    const choice = p.value.object.get("choices").?.array.items[0].object;
    try std.testing.expectEqualStrings("plain answer", choice.get("message").?.object.get("content").?.string);
    try std.testing.expectEqual(@as(i64, 12), p.value.object.get("usage").?.object.get("total_tokens").?.integer);

    var web2 = httpz.testing.init(.{});
    defer web2.deinit();
    web2.header("authorization", bearer);
    web2.body("{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:x\"}}]}]}");
    try oaiChat(&app, web2.req, web2.res);
    const b2 = try web2.getBody();
    try std.testing.expect(std.mem.indexOf(u8, b2, "text-only") != null);
}
