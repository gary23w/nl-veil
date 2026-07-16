//! Minimal MCP (Model Context Protocol) client — JSON-RPC 2.0 over a stdio transport, so RSI can find and USE
//! the AI-ready apps / MCP servers already installed on the user's machine (see CLIENT_DRIVER_MCP_BLUEPRINT.md).
//! One-shot per call: spawn the server command, do the `initialize` handshake, run one `tools/list` or
//! `tools/call`, and close. Stateless tool calls don't need a persistent connection; a kill watchdog bounds a
//! hung server. HTTP/SSE transport is a follow-on (stdio is what OS-installed MCP servers use).

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.mcp);

extern "kernel32" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) callconv(.winapi) i32;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// Kill the child if the op runs past its deadline (a wedged MCP server must not hang the tool). Mirrors
/// tools.zig's spawnGuarded watchdog.
const KillGuard = struct {
    id: std.process.Child.Id,
    deadline_ms: u32,
    done: *std.atomic.Value(bool),
    fn watch(g: KillGuard) void {
        var waited: u32 = 0;
        while (waited < g.deadline_ms) : (waited += 150) {
            if (builtin.os.tag == .windows) {
                Sleep(150);
            } else {
                const ts = std.posix.timespec{ .sec = 0, .nsec = 150 * std.time.ns_per_ms };
                _ = std.os.linux.nanosleep(&ts, null);
            }
            if (g.done.load(.monotonic)) return;
        }
        if (g.done.load(.monotonic)) return;
        if (builtin.os.tag == .windows) {
            _ = TerminateProcess(@ptrCast(g.id), 1);
        } else std.posix.kill(g.id, .KILL) catch {};
    }
};

pub const EnvPair = struct { k: []const u8, v: []const u8 };

pub const Server = struct {
    command: []const u8,
    args: []const []const u8 = &.{},
    env_extra: []const EnvPair = &.{},
};

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast("{\"ok\":false}");
}

fn errJson(gpa: std.mem.Allocator, msg: []const u8) []u8 {
    return std.fmt.allocPrint(gpa, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch dupe(gpa, "{\"ok\":false}");
}

/// List a stdio server's tools: returns the `result` of tools/list (gpa-owned JSON), or a JSON error.
pub fn listStdio(gpa: std.mem.Allocator, io: std.Io, base_env: *const std.process.Environ.Map, srv: Server, timeout_s: u32) []u8 {
    return oneShot(gpa, io, base_env, srv, "tools/list", "{}", timeout_s);
}

/// Call a tool on a stdio server: `arguments_json` is the tool's arguments object. Returns the tools/call
/// `result` (gpa-owned JSON) or a JSON error.
pub fn callStdio(gpa: std.mem.Allocator, io: std.Io, base_env: *const std.process.Environ.Map, srv: Server, tool: []const u8, arguments_json: []const u8) []u8 {
    const args = if (std.mem.trim(u8, arguments_json, " \r\n\t").len == 0) "{}" else arguments_json;
    const name_lit = std.json.Stringify.valueAlloc(gpa, tool, .{}) catch return errJson(gpa, "oom");
    defer gpa.free(name_lit);
    const params = std.fmt.allocPrint(gpa, "{{\"name\":{s},\"arguments\":{s}}}", .{ name_lit, args }) catch return errJson(gpa, "oom");
    defer gpa.free(params);
    return oneShot(gpa, io, base_env, srv, "tools/call", params, 60);
}

fn oneShot(gpa: std.mem.Allocator, io: std.Io, base_env: *const std.process.Environ.Map, srv: Server, method: []const u8, params_json: []const u8, timeout_s: u32) []u8 {
    if (srv.command.len == 0) return errJson(gpa, "server has no stdio command");

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.append(gpa, srv.command) catch return errJson(gpa, "oom");
    argv.appendSlice(gpa, srv.args) catch return errJson(gpa, "oom");

    var env = base_env.clone(gpa) catch return errJson(gpa, "oom");
    defer env.deinit();
    env.put("PYTHONUTF8", "1") catch {};
    for (srv.env_extra) |e| env.put(e.k, e.v) catch {};

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = &env,
        .create_no_window = true,
    }) catch return errJson(gpa, "could not launch MCP server (command not found?)");

    // Watchdog: kill the child if it runs past the deadline.
    var done = std.atomic.Value(bool).init(false);
    const th: ?std.Thread = if (child.id != null)
        (std.Thread.spawn(.{}, KillGuard.watch, .{KillGuard{ .id = child.id.?, .deadline_ms = timeout_s * 1000, .done = &done }}) catch null)
    else
        null;
    defer {
        done.store(true, .monotonic);
        if (th) |t| t.join();
    }

    const stdin = child.stdin orelse return finish(gpa, io, &child, errJson(gpa, "no stdin pipe"));
    const stdout = child.stdout orelse return finish(gpa, io, &child, errJson(gpa, "no stdout pipe"));
    var wbuf: [16 << 10]u8 = undefined;
    var rbuf: [1 << 20]u8 = undefined; // MCP tools/list + tools/call results can be large
    var wr = stdin.writerStreaming(io, &wbuf);
    var rd = stdout.readerStreaming(io, &rbuf);
    const w = &wr.interface;
    const r = &rd.interface;

    // 1) initialize
    const init_req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"nl-veil\",\"version\":\"1.0\"}}}";
    if (!sendMsg(w, init_req)) return finish(gpa, io, &child, errJson(gpa, "MCP write failed"));
    const init_res = recvResult(gpa, r, 1) orelse return finish(gpa, io, &child, errJson(gpa, "MCP initialize failed / not an MCP server"));
    gpa.free(init_res);

    // 2) initialized notification (no response)
    _ = sendMsg(w, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");

    // 3) the actual method
    const req = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json }) catch return finish(gpa, io, &child, errJson(gpa, "oom"));
    defer gpa.free(req);
    if (!sendMsg(w, req)) return finish(gpa, io, &child, errJson(gpa, "MCP write failed"));
    const result = recvResult(gpa, r, 2) orelse return finish(gpa, io, &child, errJson(gpa, "MCP server returned an error or no result"));

    return finish(gpa, io, &child, result);
}

/// Close stdin (signals the server to exit), reap the child, return `result`.
fn finish(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child, result: []u8) []u8 {
    _ = gpa;
    if (child.stdin) |sin| {
        sin.close(io);
        child.stdin = null;
    }
    child.kill(io); // terminates + reaps (harmless if already exited)
    return result;
}

fn sendMsg(w: *std.Io.Writer, msg: []const u8) bool {
    w.writeAll(msg) catch return false;
    w.writeAll("\n") catch return false;
    w.flush() catch return false;
    return true;
}

/// Read JSON-RPC lines until the reply with `id` arrives; return its `result` re-stringified (gpa-owned), or
/// null on a JSON-RPC error / stream close. Interleaved notifications (no id) and mismatched ids are skipped.
fn recvResult(gpa: std.mem.Allocator, r: *std.Io.Reader, id: i64) ?[]u8 {
    while (true) {
        const line = (r.takeDelimiter('\n') catch return null) orelse return null;
        const t = std.mem.trim(u8, line, " \r\n\t");
        if (t.len == 0 or t[0] != '{') continue;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, t, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const idv = obj.get("id") orelse continue; // a notification
        const got: i64 = switch (idv) {
            .integer => |i| i,
            else => continue,
        };
        if (got != id) continue;
        if (obj.get("error")) |ev| {
            const es = std.json.Stringify.valueAlloc(gpa, ev, .{}) catch "";
            defer if (es.len > 0) gpa.free(es);
            log.warn("mcp rpc error on id {d}: {s}", .{ id, es });
            return null;
        }
        const res = obj.get("result") orelse std.json.Value{ .null = {} };
        return std.json.Stringify.valueAlloc(gpa, res, .{}) catch null;
    }
}
