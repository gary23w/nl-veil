//! runner.zig — the location-agnostic EXECUTION surface the chat engine holds instead of calling netcli (or,
//! later, spawning shell) directly. The engine reaches the outside world ONLY through a Runner, so when the
//! chat brain later moves in-process into the backend, only the Runner implementation changes — no engine edits.
//!
//! `LocalRunner` forwards each verb verbatim to the loopback server via netcli, reading the CURRENT port +
//! bearer token from the shared store on each call (settings can change at runtime, so it can't be cached).
//! A future RemoteRunner (cloud backend delegating to a desk-agent) or in-process ServerRunner (brain moved
//! server-side) implements the same VTable.

const std = @import("std");
const Io = std.Io;
const netcli = @import("netcli.zig");
const store_mod = @import("store.zig");

pub const Resp = netcli.Resp; // = httpc.Resp { status: u16, body: []const u8 }

pub const Runner = struct {
    ctx: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        /// POST /api/v1/chat/tool — execute one build/file/web tool; returns the server reply (null = unreachable).
        runTool: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, body_json: []const u8) ?Resp,
        /// POST /api/v1/cast — deploy a swarm; returns the server reply (null = unreachable).
        cast: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, body_json: []const u8) ?Resp,
        /// POST /api/v1/chat/convs/<conv>/messages — run ONE server-side chat turn.
        chatSend: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp,
        /// GET /api/v1/chat/convs/<conv>/events?from=N — byte-cursor poll over the conv's turn frames.
        chatEvents: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, from: usize) ?Resp,
        /// POST /api/v1/chat/convs/<conv>/control — a cooperative control op (e.g. {"op":"stop"}) the turn reads.
        chatControl: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp,
        /// GET /api/v1/chat/convs — the server's conversation list (merged into the sidebar).
        chatConvs: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator) ?Resp,
        /// GET /api/v1/chat/convs/<conv> — one server conversation's message log (mirrored on select).
        chatConv: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8) ?Resp,
        /// DELETE /api/v1/chat/convs/<conv> — remove a conversation server-side (else it re-merges).
        chatDelete: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8) ?Resp,
        /// POST /api/v1/chat/convs/<conv>/tool_result — client-mode: return a delegated tool's result to the turn.
        chatToolResult: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp,
    };

    pub fn runTool(self: Runner, io: Io, gpa: std.mem.Allocator, body_json: []const u8) ?Resp {
        return self.vt.runTool(self.ctx, io, gpa, body_json);
    }
    pub fn cast(self: Runner, io: Io, gpa: std.mem.Allocator, body_json: []const u8) ?Resp {
        return self.vt.cast(self.ctx, io, gpa, body_json);
    }
    pub fn chatSend(self: Runner, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp {
        return self.vt.chatSend(self.ctx, io, gpa, conv, body_json);
    }
    pub fn chatEvents(self: Runner, io: Io, gpa: std.mem.Allocator, conv: []const u8, from: usize) ?Resp {
        return self.vt.chatEvents(self.ctx, io, gpa, conv, from);
    }
    pub fn chatControl(self: Runner, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp {
        return self.vt.chatControl(self.ctx, io, gpa, conv, body_json);
    }
    pub fn chatConvs(self: Runner, io: Io, gpa: std.mem.Allocator) ?Resp {
        return self.vt.chatConvs(self.ctx, io, gpa);
    }
    pub fn chatConv(self: Runner, io: Io, gpa: std.mem.Allocator, conv: []const u8) ?Resp {
        return self.vt.chatConv(self.ctx, io, gpa, conv);
    }
    pub fn chatDelete(self: Runner, io: Io, gpa: std.mem.Allocator, conv: []const u8) ?Resp {
        return self.vt.chatDelete(self.ctx, io, gpa, conv);
    }
    pub fn chatToolResult(self: Runner, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp {
        return self.vt.chatToolResult(self.ctx, io, gpa, conv, body_json);
    }
};

// ------------------------------------------------------------------ LocalRunner (today's behavior, verbatim)

const local_vtable = Runner.VTable{ .runTool = localRunTool, .cast = localCast, .chatSend = localChatSend, .chatEvents = localChatEvents, .chatControl = localChatControl, .chatConvs = localChatConvs, .chatConv = localChatConv, .chatDelete = localChatDelete, .chatToolResult = localChatToolResult };

/// A Runner backed by the loopback server. `ctx` is the shared Store — the live port + bearer token are read
/// from it on each call (the settings can change at runtime), exactly as the old call sites did.
pub fn local(store: *store_mod.Store) Runner {
    return .{ .ctx = @ptrCast(store), .vt = &local_vtable };
}

const PortTok = struct { port: u16, tok: []const u8 };

/// Snapshot the current server port + bearer token under the store lock into `tokb`.
fn portToken(store: *store_mod.Store, tokb: []u8) PortTok {
    store.lock();
    defer store.unlock();
    const n = @min(store.settings.token_len, tokb.len);
    @memcpy(tokb[0..n], store.settings.token[0..n]);
    return .{ .port = store.settings.port, .tok = tokb[0..n] };
}

fn localRunTool(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, body_json: []const u8) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.chatTool(io, gpa, pt.port, pt.tok, body_json);
}

fn localCast(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, body_json: []const u8) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.cast(io, gpa, pt.port, pt.tok, body_json);
}

fn localChatSend(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.chatSend(io, gpa, pt.port, pt.tok, conv, body_json);
}

fn localChatEvents(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, from: usize) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.chatEvents(io, gpa, pt.port, pt.tok, conv, from);
}

fn localChatControl(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.chatControl(io, gpa, pt.port, pt.tok, conv, body_json);
}

fn localChatConvs(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.chatConvs(io, gpa, pt.port, pt.tok);
}

fn localChatConv(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.chatConv(io, gpa, pt.port, pt.tok, conv);
}

fn localChatDelete(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.chatConvDelete(io, gpa, pt.port, pt.tok, conv);
}

fn localChatToolResult(ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp {
    const store: *store_mod.Store = @ptrCast(@alignCast(ctx));
    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    return netcli.chatToolResult(io, gpa, pt.port, pt.tok, conv, body_json);
}

// ---------------------------------------------------------------------------
// tests — nine hand-written wrappers forwarding into a nine-entry vtable is the shape where a
// copy-paste slip is invisible: every type still checks, nothing crashes, and the engine simply
// makes the WRONG request (chatConv fetching the whole list, chatDelete hitting control). It is
// the same failure class chat/trio_routing_test.zig guards for the model trio, and the same fix —
// prove the mapping rather than trusting it. A recording fake stands in for the server, so these
// need no io of their own. See harness/TESTING.md.
// ---------------------------------------------------------------------------

const Rec = struct {
    called: []const u8 = "",
    conv: []const u8 = "",
    body: []const u8 = "",
    from: usize = 0,
};

fn rec(ctx: *anyopaque) *Rec {
    return @ptrCast(@alignCast(ctx));
}

fn fRunTool(ctx: *anyopaque, _: Io, _: std.mem.Allocator, body: []const u8) ?Resp {
    const r = rec(ctx);
    r.called = "runTool";
    r.body = body;
    return null;
}
fn fCast(ctx: *anyopaque, _: Io, _: std.mem.Allocator, body: []const u8) ?Resp {
    const r = rec(ctx);
    r.called = "cast";
    r.body = body;
    return null;
}
fn fChatSend(ctx: *anyopaque, _: Io, _: std.mem.Allocator, conv: []const u8, body: []const u8) ?Resp {
    const r = rec(ctx);
    r.called = "chatSend";
    r.conv = conv;
    r.body = body;
    return null;
}
fn fChatEvents(ctx: *anyopaque, _: Io, _: std.mem.Allocator, conv: []const u8, from: usize) ?Resp {
    const r = rec(ctx);
    r.called = "chatEvents";
    r.conv = conv;
    r.from = from;
    return null;
}
fn fChatControl(ctx: *anyopaque, _: Io, _: std.mem.Allocator, conv: []const u8, body: []const u8) ?Resp {
    const r = rec(ctx);
    r.called = "chatControl";
    r.conv = conv;
    r.body = body;
    return null;
}
fn fChatConvs(ctx: *anyopaque, _: Io, _: std.mem.Allocator) ?Resp {
    const r = rec(ctx);
    r.called = "chatConvs";
    return null;
}
fn fChatConv(ctx: *anyopaque, _: Io, _: std.mem.Allocator, conv: []const u8) ?Resp {
    const r = rec(ctx);
    r.called = "chatConv";
    r.conv = conv;
    return null;
}
fn fChatDelete(ctx: *anyopaque, _: Io, _: std.mem.Allocator, conv: []const u8) ?Resp {
    const r = rec(ctx);
    r.called = "chatDelete";
    r.conv = conv;
    return null;
}
fn fChatToolResult(ctx: *anyopaque, _: Io, _: std.mem.Allocator, conv: []const u8, body: []const u8) ?Resp {
    const r = rec(ctx);
    r.called = "chatToolResult";
    r.conv = conv;
    r.body = body;
    return null;
}

const fake_vtable = Runner.VTable{
    .runTool = fRunTool,
    .cast = fCast,
    .chatSend = fChatSend,
    .chatEvents = fChatEvents,
    .chatControl = fChatControl,
    .chatConvs = fChatConvs,
    .chatConv = fChatConv,
    .chatDelete = fChatDelete,
    .chatToolResult = fChatToolResult,
};

test "every Runner verb reaches its OWN vtable slot, with its arguments intact" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r: Rec = .{};
    const run = Runner{ .ctx = @ptrCast(&r), .vt = &fake_vtable };

    // Each call carries a DISTINCT conv and body, so a wrapper that forwards into a neighbouring
    // slot — or swaps conv and body — shows up as a mismatch rather than as a passing test.
    _ = run.runTool(io, gpa, "{\"tool\":\"t\"}");
    try std.testing.expectEqualStrings("runTool", r.called);
    try std.testing.expectEqualStrings("{\"tool\":\"t\"}", r.body);

    _ = run.cast(io, gpa, "{\"goal\":\"g\"}");
    try std.testing.expectEqualStrings("cast", r.called);
    try std.testing.expectEqualStrings("{\"goal\":\"g\"}", r.body);

    _ = run.chatSend(io, gpa, "conv-send", "{\"m\":1}");
    try std.testing.expectEqualStrings("chatSend", r.called);
    try std.testing.expectEqualStrings("conv-send", r.conv);
    try std.testing.expectEqualStrings("{\"m\":1}", r.body);

    _ = run.chatEvents(io, gpa, "conv-events", 4242);
    try std.testing.expectEqualStrings("chatEvents", r.called);
    try std.testing.expectEqualStrings("conv-events", r.conv);
    try std.testing.expectEqual(@as(usize, 4242), r.from); // the byte cursor, not silently zeroed

    _ = run.chatControl(io, gpa, "conv-ctl", "{\"op\":\"stop\"}");
    try std.testing.expectEqualStrings("chatControl", r.called);
    try std.testing.expectEqualStrings("conv-ctl", r.conv);
    try std.testing.expectEqualStrings("{\"op\":\"stop\"}", r.body);

    _ = run.chatConvs(io, gpa);
    try std.testing.expectEqualStrings("chatConvs", r.called);

    _ = run.chatConv(io, gpa, "conv-one");
    try std.testing.expectEqualStrings("chatConv", r.called); // NOT chatConvs — the near-miss pair
    try std.testing.expectEqualStrings("conv-one", r.conv);

    _ = run.chatDelete(io, gpa, "conv-del");
    try std.testing.expectEqualStrings("chatDelete", r.called);
    try std.testing.expectEqualStrings("conv-del", r.conv);

    _ = run.chatToolResult(io, gpa, "conv-res", "{\"result\":\"ok\"}");
    try std.testing.expectEqualStrings("chatToolResult", r.called);
    try std.testing.expectEqualStrings("conv-res", r.conv);
    try std.testing.expectEqualStrings("{\"result\":\"ok\"}", r.body);
}

test "the local runner reads the CURRENT port and token, and never overruns the caller's buffer" {
    // Settings change at runtime (a user retypes the port, the server mints a new key), which is
    // why the local vtable re-reads the store on every call instead of caching — portToken is that
    // read, under the lock.
    const gpa = std.testing.allocator;
    var store = try gpa.create(store_mod.Store);
    defer gpa.destroy(store);
    store.* = .{};

    const tok = "nlk_a_test_bearer_token";
    @memcpy(store.settings.token[0..tok.len], tok);
    store.settings.token_len = @intCast(tok.len);
    store.settings.port = 9317;

    var tokb: [128]u8 = undefined;
    const pt = portToken(store, &tokb);
    try std.testing.expectEqual(@as(u16, 9317), pt.port);
    try std.testing.expectEqualStrings(tok, pt.tok);

    // A later change is seen by the next call — the property that makes caching wrong.
    store.settings.port = 8787;
    const pt2 = portToken(store, &tokb);
    try std.testing.expectEqual(@as(u16, 8787), pt2.port);

    // And a buffer smaller than the token truncates instead of overrunning.
    var tiny: [8]u8 = undefined;
    const pt3 = portToken(store, &tiny);
    try std.testing.expectEqual(@as(usize, 8), pt3.tok.len);
    try std.testing.expectEqualStrings(tok[0..8], pt3.tok);
}
