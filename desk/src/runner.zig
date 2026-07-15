//! runner.zig — the location-agnostic EXECUTION surface the chat engine holds instead of calling netcli (or,
//! later, spawning shell) directly. The engine reaches the outside world ONLY through a Runner, so when the
//! chat brain later moves in-process into the backend, only the Runner implementation changes — no engine edits.
//!
//! P0 scope: the two SYNCHRONOUS server verbs (runTool, cast). `LocalRunner` forwards them verbatim to the
//! loopback server via netcli, reading the CURRENT port + bearer token from the shared store on each call
//! (faithful to how the call sites read them today — settings can change at runtime). A future RemoteRunner
//! (cloud backend delegating to a desk-agent) or in-process ServerRunner (brain moved server-side) implements
//! the same VTable. The async shell lifecycle is a later increment (P0-2), not part of this interface yet.

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
        /// POST /api/v1/chat/convs/<conv>/messages — run ONE server-side chat turn (brain-in-backend; P0-6).
        chatSend: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp,
        /// GET /api/v1/chat/convs/<conv>/events?from=N — byte-cursor poll over the conv's turn frames.
        chatEvents: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, from: usize) ?Resp,
        /// POST /api/v1/chat/convs/<conv>/control — a cooperative control op (e.g. {"op":"stop"}) the turn reads.
        chatControl: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8, body_json: []const u8) ?Resp,
        /// GET /api/v1/chat/convs — the server's conversation list (merged into the sidebar).
        chatConvs: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator) ?Resp,
        /// GET /api/v1/chat/convs/<conv> — one server conversation's message log (mirrored on select).
        chatConv: *const fn (ctx: *anyopaque, io: Io, gpa: std.mem.Allocator, conv: []const u8) ?Resp,
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
};

// ------------------------------------------------------------------ LocalRunner (today's behavior, verbatim)

const local_vtable = Runner.VTable{ .runTool = localRunTool, .cast = localCast, .chatSend = localChatSend, .chatEvents = localChatEvents, .chatControl = localChatControl, .chatConvs = localChatConvs, .chatConv = localChatConv };

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
