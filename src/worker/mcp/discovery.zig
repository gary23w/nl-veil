//! Discover the AI-ready capabilities already installed on the user's machine (see
//! CLIENT_DRIVER_MCP_BLUEPRINT.md): MCP servers declared in the known config files (Claude Desktop, Cursor,
//! VS Code) plus local AI-runtime endpoints found by probing well-known ports (Ollama, LM Studio, …). This is
//! how the RSI system "finds" local AI apps; mcp/client.zig is how it "uses" them. Config scanning is
//! READ-ONLY and never returns env values (they may hold secrets) — only the server name, source, transport,
//! and command/url. `callServer`/`serverTools` connect to a named stdio server on demand.

const std = @import("std");
const httpc = @import("../httpc.zig");
const mcp = @import("client.zig");

const log = std.log.scoped(.mcp);

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    // OOM fallback is ZERO-LENGTH on purpose: callers free this result unconditionally, and a static non-empty
    // literal handed to gpa.free is an invalid free / UB. free() of an empty slice is a no-op (Allocator.free).
    return gpa.dupe(u8, s) catch @constCast("");
}
fn errJson(gpa: std.mem.Allocator, msg: []const u8) []u8 {
    return std.fmt.allocPrint(gpa, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch dupe(gpa, "{\"ok\":false}");
}

/// Candidate MCP config file paths for this OS (gpa-owned list; caller frees each + the slice).
fn configPaths(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) [][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    const add = struct {
        fn f(g: std.mem.Allocator, list: *std.ArrayListUnmanaged([]u8), base: ?[]const u8, rel: []const u8) void {
            const b = base orelse return;
            if (b.len == 0) return;
            const p = std.fmt.allocPrint(g, "{s}/{s}", .{ b, rel }) catch return;
            list.append(g, p) catch g.free(p);
        }
    }.f;
    const appdata = env.get("APPDATA");
    const local = env.get("LOCALAPPDATA");
    const home = env.get("USERPROFILE") orelse env.get("HOME");
    add(gpa, &out, appdata, "Claude/claude_desktop_config.json"); // Claude Desktop (Win)
    add(gpa, &out, appdata, "Code/User/mcp.json"); // VS Code user (Win)
    add(gpa, &out, home, ".cursor/mcp.json"); // Cursor global
    add(gpa, &out, home, ".vscode/mcp.json"); // VS Code (user home)
    add(gpa, &out, home, "Library/Application Support/Claude/claude_desktop_config.json"); // Claude Desktop (macOS)
    add(gpa, &out, home, ".config/Claude/claude_desktop_config.json"); // Claude Desktop (Linux)
    _ = local;
    return out.toOwnedSlice(gpa) catch &[_][]u8{};
}

fn freePaths(gpa: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// The server map object of one config Value ("mcpServers" for Claude/Cursor, "servers" for VS Code), or null.
fn serversObj(v: std.json.Value) ?std.json.ObjectMap {
    const root = switch (v) {
        .object => |o| o,
        else => return null,
    };
    if (root.get("mcpServers")) |m| switch (m) {
        .object => |o| return o,
        else => {},
    };
    if (root.get("servers")) |m| switch (m) {
        .object => |o| return o,
        else => {},
    };
    return null;
}

fn objStr(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (o.get(key) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

const Runtime = struct { name: []const u8, endpoint: []const u8, kind: []const u8, up: bool };

fn probePort(io: std.Io, gpa: std.mem.Allocator, port: u16, path: []const u8) bool {
    switch (httpc.request(io, gpa, .{ .method = "GET", .port = port, .path = path, .timeout_s = 2, .cap = 8 << 10 })) {
        .ok => |resp| {
            const up = resp.status > 0 and resp.status < 500;
            if (resp.body.len > 0) gpa.free(resp.body);
            return up;
        },
        else => return false,
    }
}

/// mcp_discover with no `server`: list all MCP servers from the config files + probe known local AI runtimes.
/// Read-only; spawns nothing.
pub fn discoverAll(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) []u8 {
    const Entry = struct { name: []const u8, source: []const u8, transport: []const u8, command: []const u8 = "", url: []const u8 = "" };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(gpa);
    var parseds: std.ArrayListUnmanaged(std.json.Parsed(std.json.Value)) = .empty;
    defer {
        for (parseds.items) |*pp| pp.deinit();
        parseds.deinit(gpa);
    }

    const paths = configPaths(gpa, env);
    defer freePaths(gpa, paths);
    for (paths) |path| {
        const txt = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(txt);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, txt, .{}) catch continue;
        const smap = serversObj(parsed.value) orelse {
            parsed.deinit();
            continue;
        };
        parseds.append(gpa, parsed) catch {
            parsed.deinit();
            continue;
        };
        var it = smap.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const spec = switch (kv.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            const cmd = objStr(spec, "command");
            const url = objStr(spec, "url");
            const transport = if (url.len > 0) "http" else "stdio";
            entries.append(gpa, .{ .name = name, .source = path, .transport = transport, .command = cmd, .url = url }) catch {};
        }
    }

    // Local AI-runtime probes (well-known ports) — usable AI-ready endpoints even without an MCP config.
    var runtimes: std.ArrayListUnmanaged(Runtime) = .empty;
    defer runtimes.deinit(gpa);
    if (probePort(io, gpa, 11434, "/api/version")) runtimes.append(gpa, .{ .name = "ollama", .endpoint = "http://127.0.0.1:11434", .kind = "ollama+openai", .up = true }) catch {};
    if (probePort(io, gpa, 1234, "/v1/models")) runtimes.append(gpa, .{ .name = "lm-studio", .endpoint = "http://127.0.0.1:1234", .kind = "openai-compatible", .up = true }) catch {};
    if (probePort(io, gpa, 8080, "/v1/models")) runtimes.append(gpa, .{ .name = "local-openai-8080", .endpoint = "http://127.0.0.1:8080", .kind = "openai-compatible", .up = true }) catch {};

    return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .mcp_servers = entries.items, .ai_runtimes = runtimes.items }, .{}) catch errJson(gpa, "oom");
}

/// Run `op` against the named stdio server: find it in the configs, build its launch spec (command/args/env),
/// and call the client. `tool` empty ⇒ tools/list; else tools/call with `args_json`.
fn withNamedServer(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8, tool: []const u8, args_json: []const u8) []u8 {
    const paths = configPaths(gpa, env);
    defer freePaths(gpa, paths);
    for (paths) |path| {
        const txt = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(txt);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, txt, .{}) catch continue;
        defer parsed.deinit();
        const smap = serversObj(parsed.value) orelse continue;
        const spec_v = smap.get(name) orelse continue;
        const spec = switch (spec_v) {
            .object => |o| o,
            else => continue,
        };
        const cmd = objStr(spec, "command");
        if (cmd.len == 0) {
            if (objStr(spec, "url").len > 0) return errJson(gpa, "that server uses the http transport, which is not yet supported (stdio only for now)");
            return errJson(gpa, "server has no command");
        }
        // args
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(gpa);
        if (spec.get("args")) |av| switch (av) {
            .array => |arr| for (arr.items) |it| switch (it) {
                .string => |s| args.append(gpa, s) catch {},
                else => {},
            },
            else => {},
        };
        // env
        var envp: std.ArrayListUnmanaged(mcp.EnvPair) = .empty;
        defer envp.deinit(gpa);
        if (spec.get("env")) |ev| switch (ev) {
            .object => |eo| {
                var eit = eo.iterator();
                while (eit.next()) |ekv| switch (ekv.value_ptr.*) {
                    .string => |s| envp.append(gpa, .{ .k = ekv.key_ptr.*, .v = s }) catch {},
                    else => {},
                };
            },
            else => {},
        };
        const srv = mcp.Server{ .command = cmd, .args = args.items, .env_extra = envp.items };
        if (tool.len == 0) return mcp.listStdio(gpa, io, env, srv, 30);
        return mcp.callStdio(gpa, io, env, srv, tool, args_json);
    }
    return errJson(gpa, "server not found in the local MCP config files");
}

/// mcp_discover with a `server`: connect to it and return its tools/list.
pub fn serverTools(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) []u8 {
    return withNamedServer(gpa, io, env, name, "", "{}");
}

/// mcp_call: run `tool` on the named stdio server with `arguments_json`.
pub fn callServer(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8, tool: []const u8, arguments_json: []const u8) []u8 {
    return withNamedServer(gpa, io, env, name, tool, arguments_json);
}

test "serversObj accepts both config shapes (mcpServers / servers) and rejects everything else" {
    const gpa = std.testing.allocator;
    // Claude/Cursor shape
    const claude = try std.json.parseFromSlice(std.json.Value, gpa, "{\"mcpServers\":{\"fs\":{\"command\":\"node\"}}}", .{});
    defer claude.deinit();
    try std.testing.expect(serversObj(claude.value).?.contains("fs"));
    // VS Code shape
    const vscode = try std.json.parseFromSlice(std.json.Value, gpa, "{\"servers\":{\"db\":{\"command\":\"psql\"}}}", .{});
    defer vscode.deinit();
    try std.testing.expect(serversObj(vscode.value).?.contains("db"));
    // no server map, or the key present but not an object → null (never a crash)
    const empty = try std.json.parseFromSlice(std.json.Value, gpa, "{\"other\":1}", .{});
    defer empty.deinit();
    try std.testing.expect(serversObj(empty.value) == null);
    const wrongtype = try std.json.parseFromSlice(std.json.Value, gpa, "{\"mcpServers\":\"nope\"}", .{});
    defer wrongtype.deinit();
    try std.testing.expect(serversObj(wrongtype.value) == null);
}

test "objStr returns the string value or an empty string for missing/mistyped keys" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"node\",\"port\":8080}", .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("node", objStr(o, "command"));
    try std.testing.expectEqualStrings("", objStr(o, "missing"));
    try std.testing.expectEqualStrings("", objStr(o, "port")); // present but an int, not a string
}
