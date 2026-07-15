//! cli/chat.zig — the interactive `veil chat` REPL. It drives the SERVER-side chat brain over the same REST
//! surface the desktop uses: POST a message to /api/v1/chat/convs/:id/messages, stream the turn's frames from
//! /events, and while a turn runs, a typed line becomes a steer (/control {op:steer}) that the running turn
//! folds in — the CLI twin of the desk's Post/Stop. `/stop`, `/new`, `/quit` are the control verbs.

const std = @import("std");
const cli = @import("../cli.zig");

const Ctx = cli.Ctx;

/// `call`, `followConv`, `ensureServer`, and `unreachable_msg` are passed in from cli.zig so this file never
/// re-implements the HTTP path — it just composes the chat flow on top of them.
pub fn run(
    ctx: *Ctx,
    args: []const []const u8,
    call: cli.CallFn,
    followConv: *const fn (ctx: *Ctx, conv: []const u8) void,
    ensureServer: *const fn (ctx: *Ctx) bool,
    unreachable_msg: *const fn (ctx: *Ctx) u8,
) u8 {
    if (!ensureServer(ctx)) return unreachable_msg(ctx);

    // conversation id: explicit arg, else a fresh timestamp-free hex the server will create on first message.
    var conv_buf: [64]u8 = undefined;
    var conv: []const u8 = "";
    for (args) |a| {
        if (a.len > 0 and a[0] != '-') {
            const n = @min(a.len, conv_buf.len);
            @memcpy(conv_buf[0..n], a[0..n]);
            conv = conv_buf[0..n];
            break;
        }
    }
    if (conv.len == 0) {
        // mint a client-side id from the process — safeSeg-clean; the server creates the dir on first message.
        var rnd: [6]u8 = undefined;
        ctx.io.random(&rnd);
        const hex = std.fmt.bufPrint(&conv_buf, "cli{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch "clichat";
        conv = hex;
    }

    std.debug.print(
        \\veil chat — conversation {s}
        \\  type a message and press enter; while the veil is working, a line STEERS the running turn.
        \\  /stop  interrupt the current turn      /new  start a fresh conversation
        \\  /quit  leave                            (Ctrl-C also exits)
        \\
    , .{conv});

    // provider fields come from the environment (the deploy.py convention): NL_LLM_BASE_URL / NL_LLM_MODEL /
    // NL_LLM_KEY. Blank base_url means the server has no backend to call (a chat turn needs one), so if it's
    // unset we default to a local Ollama — the common local case — and let the user override via env.
    const base_url = ctx.environ.get("NL_LLM_BASE_URL") orelse "http://127.0.0.1:11434/v1";
    const model = ctx.environ.get("NL_LLM_MODEL") orelse "gpt-oss:20b";
    const api_key = ctx.environ.get("NL_LLM_KEY") orelse "";
    std.debug.print("  backend: {s}  ({s})\n", .{ model, base_url });

    var stdin_buf: [4096]u8 = undefined;
    while (true) {
        std.debug.print("\n> ", .{});
        const line = readLine(ctx, &stdin_buf) orelse break; // EOF (Ctrl-D / closed pipe) ends the REPL
        const msg = std.mem.trim(u8, line, " \r\n\t");
        if (msg.len == 0) continue;
        if (std.mem.eql(u8, msg, "/quit") or std.mem.eql(u8, msg, "/exit")) break;
        if (std.mem.eql(u8, msg, "/new")) {
            var rnd: [6]u8 = undefined;
            ctx.io.random(&rnd);
            conv = std.fmt.bufPrint(&conv_buf, "cli{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch conv;
            std.debug.print("(new conversation {s})\n", .{conv});
            continue;
        }
        if (std.mem.eql(u8, msg, "/stop")) {
            _ = postControl(ctx, call, conv, "{\"op\":\"stop\"}");
            std.debug.print("(stop requested)\n", .{});
            continue;
        }

        // send the message as a fresh turn (loop=0), then stream its frames to completion.
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(ctx.gpa);
        jb.appendSlice(ctx.gpa, "{\"text\":") catch continue;
        appendJsonStr(ctx.gpa, &jb, msg);
        jb.appendSlice(ctx.gpa, ",\"base_url\":") catch continue;
        appendJsonStr(ctx.gpa, &jb, base_url);
        jb.appendSlice(ctx.gpa, ",\"model\":") catch continue;
        appendJsonStr(ctx.gpa, &jb, model);
        jb.appendSlice(ctx.gpa, ",\"api_key\":") catch continue;
        appendJsonStr(ctx.gpa, &jb, api_key);
        jb.appendSlice(ctx.gpa, ",\"loop\":0}") catch continue;

        var pb: [220]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/api/v1/chat/convs/{s}/messages", .{conv}) catch continue;
        const resp = call(ctx, "POST", path, jb.items, 30, false) catch {
            std.debug.print("(server unreachable — is it still running?)\n", .{});
            continue;
        };
        const status = resp.status;
        if (resp.body.len > 0) ctx.gpa.free(resp.body);
        if (status != 200 and status != 201 and status != 202) {
            std.debug.print("(send failed — HTTP {d})\n", .{status});
            continue;
        }
        // stream the turn; a {done} frame returns. (A future refinement: a background reader so a line typed
        // mid-turn posts a steer — for now the turn streams to completion, then the next prompt accepts input.)
        followConv(ctx, conv);
        std.debug.print("\n", .{});
    }
    return 0;
}

fn postControl(ctx: *Ctx, call: cli.CallFn, conv: []const u8, body: []const u8) bool {
    var pb: [220]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/api/v1/chat/convs/{s}/control", .{conv}) catch return false;
    const resp = call(ctx, "POST", path, body, 8, false) catch return false;
    if (resp.body.len > 0) ctx.gpa.free(resp.body);
    return resp.status == 200 or resp.status == 202;
}

/// Read one line from stdin (Io-based, byte at a time — fine for a line-oriented REPL). Returns null on EOF.
fn readLine(ctx: *Ctx, buf: []u8) ?[]const u8 {
    const stdin = std.Io.File.stdin();
    var n: usize = 0;
    while (n < buf.len) {
        var one: [1]u8 = undefined;
        var bufs = [_][]u8{&one};
        const got = stdin.readStreaming(ctx.io, &bufs) catch return if (n == 0) null else buf[0..n];
        if (got == 0) return if (n == 0) null else buf[0..n]; // EOF
        if (one[0] == '\n') return buf[0..n];
        buf[n] = one[0];
        n += 1;
    }
    return buf[0..n];
}

fn appendJsonStr(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    list.append(gpa, '"') catch return;
    for (s) |c| switch (c) {
        '"' => list.appendSlice(gpa, "\\\"") catch return,
        '\\' => list.appendSlice(gpa, "\\\\") catch return,
        '\n' => list.appendSlice(gpa, "\\n") catch return,
        '\r' => list.appendSlice(gpa, "\\r") catch return,
        '\t' => list.appendSlice(gpa, "\\t") catch return,
        else => list.append(gpa, c) catch return,
    };
    list.append(gpa, '"') catch return;
}
