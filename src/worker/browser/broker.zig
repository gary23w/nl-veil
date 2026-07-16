//! Loopback broker — the bridge that lets a sandboxed make_tool Python body drive the in-process browser
//! primitives, so RSI can INVENT browser-driven tools (Feature 2, task 3) the same way it invents any tool.
//!
//! An authored tool runs as a Python subprocess with API keys blanked and no egress helpers injected, but it
//! CAN reach 127.0.0.1 with urllib — so it composes the primitives by POSTing {token,key,action,params} here,
//! mirroring the existing host_command broker pattern. make_tool itself is untouched; runAuthored (tools.zig)
//! injects a `browser()` Python helper + the broker url/token into the child env ONLY when NL_BROWSER_DRIVER is
//! enabled. The broker binds loopback-only and checks a per-process token, so nothing off-box can reach it, and
//! it keys sessions by the tool's run_dir — the SAME key the mind's own browser_* tools use, so an invented
//! tool and its author share ONE browser session.
//!
//! It is a tiny single-request-at-a-time HTTP/1.1 server on a dedicated thread (browser ops serialize in the
//! manager anyway). Port 0 gives no way to read the assigned port back from std.Io.net.Server, so it scans a
//! small high-port range and uses the first that binds.

const std = @import("std");
const Io = std.Io;
const browser_mgr = @import("manager.zig");
const mcp_discovery = @import("../mcp/discovery.zig");

const log = std.log.scoped(.browser);

const PORT_LO: u16 = 43110;
const PORT_HI: u16 = 43142;

var g_mu: std.Io.Mutex = .init;
var g_started = false;
var g_port: u16 = 0;
var g_token: [32]u8 = undefined; // hex
var g_gpa: std.mem.Allocator = undefined;
var g_io: Io = undefined;
var g_env: *const std.process.Environ.Map = undefined;

pub const Info = struct { port: u16, token: []const u8 };

/// Lazily start the broker (idempotent, process-global). Returns its port + token, or null if it could not
/// bind any port in the range. The manager ops it dispatches to use `gpa`/`io`/`env`, so those are pinned here.
pub fn ensure(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) ?Info {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    if (g_started) return .{ .port = g_port, .token = &g_token };

    var seed: u64 = @intFromPtr(env) ^ 0x5DEECE66D;
    fillHex(&g_token, &seed);

    var port = PORT_LO;
    const server: Io.net.Server = while (port <= PORT_HI) : (port += 1) {
        const addr = Io.net.IpAddress{ .ip4 = .loopback(port) };
        break Io.net.IpAddress.listen(&addr, io, .{ .mode = .stream, .protocol = .tcp }) catch continue;
    } else {
        log.warn("browser broker: no free port in {d}..{d}", .{ PORT_LO, PORT_HI });
        return null;
    };

    g_gpa = gpa;
    g_io = io;
    g_env = env;
    g_port = port;
    g_started = true;

    const boxed = gpa.create(Io.net.Server) catch return null;
    boxed.* = server;
    _ = std.Thread.spawn(.{}, acceptLoop, .{boxed}) catch {
        log.warn("browser broker: could not spawn accept thread", .{});
        return null;
    };
    log.info("browser broker listening on 127.0.0.1:{d}", .{port});
    return .{ .port = g_port, .token = &g_token };
}

fn acceptLoop(server: *Io.net.Server) void {
    while (true) {
        var conn = server.accept(g_io) catch continue;
        handle(&conn);
        conn.close(g_io);
    }
}

const ReqBody = struct {
    token: []const u8 = "",
    key: []const u8 = "",
    action: []const u8 = "",
    params: std.json.Value = .null,
};

fn handle(conn: *Io.net.Stream) void {
    const gpa = g_gpa;
    var rbuf: [8 << 10]u8 = undefined;
    var rd = conn.reader(g_io, &rbuf);
    const r = &rd.interface;

    // request line (ignored — only POST is used) then headers up to the blank line, capturing Content-Length
    _ = (r.takeDelimiter('\n') catch return) orelse return;
    var clen: usize = 0;
    while (true) {
        const line = (r.takeDelimiter('\n') catch return) orelse return;
        const t = std.mem.trim(u8, line, " \r\n");
        if (t.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(t, "content-length:")) {
            clen = std.fmt.parseInt(usize, std.mem.trim(u8, t["content-length:".len..], " "), 10) catch 0;
        }
    }
    if (clen == 0 or clen > (4 << 20)) return respond(conn, "{\"ok\":false,\"error\":\"bad length\"}");
    const body = gpa.alloc(u8, clen) catch return;
    defer gpa.free(body);
    r.readSliceAll(body) catch return respond(conn, "{\"ok\":false,\"error\":\"short body\"}");

    const parsed = std.json.parseFromSlice(ReqBody, gpa, body, .{ .ignore_unknown_fields = true }) catch
        return respond(conn, "{\"ok\":false,\"error\":\"bad json\"}");
    defer parsed.deinit();
    const rb = parsed.value;

    if (!std.mem.eql(u8, rb.token, &g_token)) return respond(conn, "{\"ok\":false,\"error\":\"bad token\"}");
    if (rb.key.len == 0) return respond(conn, "{\"ok\":false,\"error\":\"missing key\"}");

    // MCP actions (an invented tool's mcp() helper) go to the discovery/client layer; everything else is a
    // browser action funneled through the shared dispatcher (same path as the in-process tool + the daemon).
    if (std.mem.startsWith(u8, rb.action, "mcp")) {
        const result = mcpDispatch(gpa, rb);
        defer gpa.free(result);
        return respond(conn, result);
    }
    const pj = std.json.Stringify.valueAlloc(gpa, rb.params, .{}) catch return respond(conn, "{\"ok\":false,\"error\":\"bad params\"}");
    defer gpa.free(pj);
    const result = browser_mgr.dispatch(gpa, g_io, g_env, rb.key, rb.action, pj);
    defer gpa.free(result);
    respond(conn, result);
}

fn pStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        },
        else => null,
    };
}

/// Handle an mcp_call / mcp_discover request forwarded from an invented tool's mcp() helper. gpa-owned result.
fn mcpDispatch(gpa: std.mem.Allocator, rb: ReqBody) []u8 {
    const server = pStr(rb.params, "server") orelse "";
    if (std.mem.eql(u8, rb.action, "mcp_discover")) {
        if (server.len == 0) return mcp_discovery.discoverAll(gpa, g_io, g_env);
        return mcp_discovery.serverTools(gpa, g_io, g_env, server);
    }
    // mcp_call
    if (server.len == 0) return gpa.dupe(u8, "{\"ok\":false,\"error\":\"need server\"}") catch @constCast("{\"ok\":false}");
    const tool = pStr(rb.params, "tool") orelse return gpa.dupe(u8, "{\"ok\":false,\"error\":\"need tool\"}") catch @constCast("{\"ok\":false}");
    const args_v = switch (rb.params) {
        .object => |o| o.get("args") orelse std.json.Value{ .null = {} },
        else => std.json.Value{ .null = {} },
    };
    const args_json = std.json.Stringify.valueAlloc(gpa, args_v, .{}) catch return gpa.dupe(u8, "{\"ok\":false,\"error\":\"oom\"}") catch @constCast("{\"ok\":false}");
    defer gpa.free(args_json);
    return mcp_discovery.callServer(gpa, g_io, g_env, server, tool, args_json);
}

fn respond(conn: *Io.net.Stream, body: []const u8) void {
    var wbuf: [4 << 10]u8 = undefined;
    var wr = conn.writer(g_io, &wbuf);
    const w = &wr.interface;
    w.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
    w.writeAll(body) catch return;
    w.flush() catch {};
}

/// Fill `out` with lowercase hex from a splitmix64 stream (token need not be crypto-grade — it only separates
/// this process's broker from a stray local caller; the loopback bind is the real boundary).
fn fillHex(out: []u8, seed: *u64) void {
    const hexd = "0123456789abcdef";
    var i: usize = 0;
    while (i < out.len) {
        seed.* +%= 0x9E3779B97F4A7C15;
        var z = seed.*;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        var b: usize = 0;
        while (b < 16 and i < out.len) : (b += 1) {
            out[i] = hexd[(z >> @intCast(b * 4)) & 0xF];
            i += 1;
        }
    }
}
