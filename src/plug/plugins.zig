//! plugins.zig — the veil plugin registry: user extensions loaded from `<data>/plugins/`, one
//! folder per plugin, each driven by a Lua manifest (`plugin.lua`) running in the lua.zig sandbox.
//!
//! What a plugin can do (the three hook families, all optional, all declared by the manifest):
//!   * TOOLING — `veil.tool{...}` registers a model-callable tool whose handler is a Lua function;
//!     `veil.mcp{command=...}` bridges an external MCP server's whole tool list (spawned per call
//!     via the existing src/worker/mcp stdio client). Plugin tools are advertised to the model as
//!     `plug_<plugin>_<tool>` alongside the built-ins and dispatched here instead of tools.zig.
//!   * POLICY — `veil.on_policy(fn)` sees every chat-surface tool call (uid, tool, args, conv,
//!     admin) BEFORE it runs and can deny it with a reason. First deny wins. A hook that errors
//!     FAILS OPEN (the call proceeds, loudly logged): a buggy plugin must not brick the app.
//!   * PROMPTS — `veil.on_prompt(fn)` returns extra system-prompt text for a turn. It rides the
//!     per-turn recall channel (never the stable prefix) so provider prompt-prefix caching is
//!     unharmed — see engine.zig's cache discipline notes.
//!
//! Threading: the registry is immutable after load. Each plugin owns ONE Lua state guarded by its
//! own mutex — chat turns run on many threads, so every entry into a plugin Vm serializes on that
//! plugin's lock (hooks are expected to be micro-functions; heavy work belongs in tools). Reload
//! is a whole-registry rebuild + pointer swap by the owner (main.zig); the old registry is
//! deliberately leaked, so in-flight turns keep reading a valid one (same contract as recipes).
//!
//! This module deliberately imports NO app modules except the mcp client — gateway/http.zig holds
//! a `?*Registry` field, so importing http here would cycle.

const std = @import("std");
const lua = @import("lua.zig");
const theme = @import("theme.zig");
const mcp = @import("../worker/mcp/client.zig");

const log = std.log.scoped(.plug);

pub const MAX_PLUGINS = 24;
pub const MAX_TOOLS_PER_PLUGIN = 16;
pub const NAME_MAX = 24;

pub const ToolKind = enum { script, mcp_bridge };

pub const PlugTool = struct {
    /// Full advertised name: "plug_<plugin>_<short>". Arena-owned.
    name: []const u8,
    short: []const u8,
    description: []const u8,
    /// OpenAI-style parameters object (JSON). Arena-owned.
    params_json: []const u8,
    kind: ToolKind,
    /// Lua registry ref of the handler (script kind), else NOREF.
    handler_ref: c_int = lua.NOREF,
};

pub const State = enum { ok, failed };

pub const Plugin = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    dir: []const u8 = "", // absolute-ish path under the data dir; arena-owned
    state: State = .ok,
    err: []const u8 = "",
    vm: ?*lua.Vm = null,
    // One lock per plugin Vm: chat turns run on many threads, so every host→Lua entry (hook or tool)
    // serializes here. std.Io.Mutex (not std.Thread.Mutex, which this Zig dropped) — locked with the
    // registry's io.
    mtx: std.Io.Mutex = .init,
    policy_ref: c_int = lua.NOREF,
    prompt_ref: c_int = lua.NOREF,
    tools: std.ArrayListUnmanaged(PlugTool) = .empty,
    mcp_srv: ?mcp.Server = null, // command/args/env arena-owned
    mcp_timeout_s: u32 = 20,
    /// true only while plugin.lua itself is executing — the veil.* registration API locks after.
    loading: bool = false,
    /// hook misfire counter, surfaced in /api/v1/plugins
    hook_errors: u32 = 0,
    reg: *Registry = undefined,
};

pub const LoadOptions = struct {
    /// Skip spawning MCP servers for tools/list at load (unit tests; offline boots still list the
    /// plugin as ok, with zero bridged tools and a note).
    skip_mcp_listing: bool = false,
};

pub const Registry = struct {
    arena_state: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    data_dir: []const u8 = "",
    plugins: []Plugin = &.{},
    /// The theme workspace, loaded alongside plugins so one reload refreshes both.
    themes: theme.ThemeSet = .{},
    /// ",\n{tool schema},\n{tool schema}" — ready to append to a turn's tools array. Arena-owned.
    schemas: []const u8 = "",

    pub fn count(reg: *const Registry) usize {
        return reg.plugins.len;
    }

    pub fn deinit(reg: *Registry) void {
        for (reg.plugins) |*p| {
            if (p.vm) |vm| vm.deinit();
            p.tools.deinit(reg.gpa);
        }
        var arena = reg.arena_state;
        const gpa = reg.gpa;
        arena.deinit();
        _ = gpa;
    }

    /// Find a plugin-owned tool by its full advertised name.
    pub fn findTool(reg: *Registry, name: []const u8) ?struct { p: *Plugin, t: *PlugTool } {
        if (!std.mem.startsWith(u8, name, "plug_")) return null;
        for (reg.plugins) |*p| {
            if (p.state != .ok) continue;
            for (p.tools.items) |*t| {
                if (std.mem.eql(u8, t.name, name)) return .{ .p = p, .t = t };
            }
        }
        return null;
    }

    pub fn ownsTool(reg: *Registry, name: []const u8) bool {
        return reg.findTool(name) != null;
    }

    /// Run every policy hook over this call. null ⇒ allowed. Otherwise a gpa-owned refusal string
    /// shaped like the engine's own refusals ("(...)"), ready to use as the tool result.
    pub fn policyGate(reg: *Registry, gpa: std.mem.Allocator, uid: u64, admin: bool, conv: []const u8, tool: []const u8, args_json: []const u8) ?[]u8 {
        for (reg.plugins) |*p| {
            if (p.state != .ok or p.policy_ref == lua.NOREF) continue;
            const vm = p.vm orelse continue;
            p.mtx.lockUncancelable(reg.io);
            defer p.mtx.unlock(reg.io);
            const L = vm.L;
            _ = lua.c.lua_rawgeti(L, lua.REGISTRYINDEX, p.policy_ref);
            lua.c.lua_createtable(L, 0, 5);
            lua.c.lua_pushinteger(L, @intCast(uid));
            lua.c.lua_setfield(L, -2, "uid");
            lua.c.lua_pushboolean(L, @intFromBool(admin));
            lua.c.lua_setfield(L, -2, "admin");
            lua.pushSlice(L, tool);
            lua.c.lua_setfield(L, -2, "tool");
            lua.pushSlice(L, args_json);
            lua.c.lua_setfield(L, -2, "args_json");
            lua.pushSlice(L, conv);
            lua.c.lua_setfield(L, -2, "conv");
            vm.callTop(1, 1) catch {
                p.hook_errors +|= 1;
                log.warn("plugin {s}: on_policy errored (fail-open): {s}", .{ p.name, vm.lastError() });
                continue;
            };
            // verdicts: nil/true ⇒ allow; false ⇒ deny; {allow=false, reason=...} ⇒ deny with reason
            var deny = false;
            var reason: []const u8 = "";
            var reason_buf: [200]u8 = undefined;
            switch (lua.c.lua_type(L, -1)) {
                lua.TNIL => {},
                lua.TBOOLEAN => deny = lua.c.lua_toboolean(L, -1) == 0,
                lua.TTABLE => {
                    const at = lua.c.lua_getfield(L, -1, "allow");
                    if (at == lua.TBOOLEAN and lua.c.lua_toboolean(L, -1) == 0) deny = true;
                    lua.pop(L, 1);
                    if (deny) {
                        if (lua.c.lua_getfield(L, -1, "reason") == lua.TSTRING) {
                            const r = lua.toString(L, -1) orelse "";
                            const n = @min(r.len, reason_buf.len);
                            @memcpy(reason_buf[0..n], r[0..n]);
                            reason = reason_buf[0..n];
                        }
                        lua.pop(L, 1);
                    }
                },
                else => {},
            }
            lua.pop(L, 1);
            if (deny) {
                const msg = if (reason.len > 0)
                    std.fmt.allocPrint(gpa, "(policy: plugin '{s}' denied this call: {s})", .{ p.name, reason })
                else
                    std.fmt.allocPrint(gpa, "(policy: plugin '{s}' denied this call)", .{p.name});
                return msg catch null;
            }
        }
        return null;
    }

    /// Collect every prompt hook's text for this turn. null when no plugin adds anything;
    /// otherwise gpa-owned plain text (caller wraps it into a system message). Clipped per plugin
    /// and overall — this rides in front of the recency window on every inference of the turn.
    pub fn promptText(reg: *Registry, gpa: std.mem.Allocator, uid: u64, admin: bool, conv: []const u8) ?[]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        for (reg.plugins) |*p| {
            if (p.state != .ok or p.prompt_ref == lua.NOREF) continue;
            const vm = p.vm orelse continue;
            p.mtx.lockUncancelable(reg.io);
            defer p.mtx.unlock(reg.io);
            const L = vm.L;
            _ = lua.c.lua_rawgeti(L, lua.REGISTRYINDEX, p.prompt_ref);
            lua.c.lua_createtable(L, 0, 3);
            lua.c.lua_pushinteger(L, @intCast(uid));
            lua.c.lua_setfield(L, -2, "uid");
            lua.c.lua_pushboolean(L, @intFromBool(admin));
            lua.c.lua_setfield(L, -2, "admin");
            lua.pushSlice(L, conv);
            lua.c.lua_setfield(L, -2, "conv");
            vm.callTop(1, 1) catch {
                p.hook_errors +|= 1;
                log.warn("plugin {s}: on_prompt errored (skipped): {s}", .{ p.name, vm.lastError() });
                continue;
            };
            if (lua.c.lua_type(L, -1) == lua.TSTRING) {
                if (lua.toString(L, -1)) |s| {
                    const clipped = s[0..@min(s.len, 1200)];
                    if (clipped.len > 0) {
                        if (out.items.len > 0) out.appendSlice(gpa, "\n\n") catch {};
                        out.print(gpa, "[plugin {s}]\n{s}", .{ p.name, clipped }) catch {};
                    }
                }
            }
            lua.pop(L, 1);
            if (out.items.len > 4000) break; // overall clip
        }
        if (out.items.len == 0) {
            out.deinit(gpa);
            return null;
        }
        return out.toOwnedSlice(gpa) catch {
            out.deinit(gpa);
            return null;
        };
    }

    /// Execute a plugin-owned tool. Always returns a gpa-owned string (the tool-result contract of
    /// tools.execute): plugin errors come back as "(...)" strings, never Zig errors.
    pub fn execTool(reg: *Registry, gpa: std.mem.Allocator, name: []const u8, args_json: []const u8) []u8 {
        const hit = reg.findTool(name) orelse
            return std.fmt.allocPrint(gpa, "(unknown plugin tool: {s})", .{name}) catch @constCast("");
        const p = hit.p;
        const t = hit.t;
        switch (t.kind) {
            .mcp_bridge => {
                const srv = p.mcp_srv orelse return std.fmt.allocPrint(gpa, "(plugin {s}: no MCP server configured)", .{p.name}) catch @constCast("");
                const env = reg.environ orelse return std.fmt.allocPrint(gpa, "(plugin {s}: server environment unavailable for MCP spawn)", .{p.name}) catch @constCast("");
                return mcp.callStdio(gpa, reg.io, env, srv, t.short, args_json);
            },
            .script => {
                const vm = p.vm orelse return std.fmt.allocPrint(gpa, "(plugin {s}: vm unavailable)", .{p.name}) catch @constCast("");
                p.mtx.lockUncancelable(reg.io);
                defer p.mtx.unlock(reg.io);
                const L = vm.L;
                _ = lua.c.lua_rawgeti(L, lua.REGISTRYINDEX, t.handler_ref);
                // args: parsed JSON object → Lua table (bad/empty JSON ⇒ empty table)
                var arena_state = std.heap.ArenaAllocator.init(gpa);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                const trimmed = std.mem.trim(u8, args_json, " \r\n\t");
                if (trimmed.len > 0) {
                    if (std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{})) |v| {
                        lua.pushJson(L, v);
                    } else |_| lua.c.lua_createtable(L, 0, 0);
                } else lua.c.lua_createtable(L, 0, 0);
                vm.callTop(1, 1) catch {
                    p.hook_errors +|= 1;
                    return std.fmt.allocPrint(gpa, "(plugin {s} tool {s} error: {s})", .{ p.name, t.short, vm.lastError() }) catch @constCast("");
                };
                defer lua.pop(L, 1);
                switch (lua.c.lua_type(L, -1)) {
                    lua.TSTRING => {
                        const s = lua.toString(L, -1) orelse "";
                        return gpa.dupe(u8, s) catch @constCast("");
                    },
                    lua.TNIL => return gpa.dupe(u8, "{\"ok\":true}") catch @constCast(""),
                    lua.TTABLE => {
                        const v = lua.luaToJson(arena, L, -1, 0) catch
                            return gpa.dupe(u8, "(plugin result too deep to serialize)") catch @constCast("");
                        return std.json.Stringify.valueAlloc(gpa, v, .{}) catch @constCast("");
                    },
                    else => {
                        const s = lua.c.luaL_tolstring(L, -1, null);
                        defer lua.pop(L, 1);
                        return gpa.dupe(u8, std.mem.span(s)) catch @constCast("");
                    },
                }
            },
        }
    }

    /// The /api/v1/plugins payload. gpa-owned.
    pub fn listJson(reg: *Registry, gpa: std.mem.Allocator) []u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        out.append(gpa, '[') catch {};
        for (reg.plugins, 0..) |*p, i| {
            if (i > 0) out.append(gpa, ',') catch {};
            out.appendSlice(gpa, "{\"name\":") catch {};
            jsonStr(gpa, &out, p.name);
            out.appendSlice(gpa, ",\"version\":") catch {};
            jsonStr(gpa, &out, p.version);
            out.appendSlice(gpa, ",\"description\":") catch {};
            jsonStr(gpa, &out, p.description);
            out.print(gpa, ",\"kind\":\"{s}\",\"state\":\"{s}\",\"hook_errors\":{d}", .{
                if (p.mcp_srv != null) "mcp" else "script",
                @tagName(p.state),
                p.hook_errors,
            }) catch {};
            out.appendSlice(gpa, ",\"error\":") catch {};
            jsonStr(gpa, &out, p.err);
            out.print(gpa, ",\"policy\":{},\"prompt\":{},\"tools\":[", .{ p.policy_ref != lua.NOREF, p.prompt_ref != lua.NOREF }) catch {};
            for (p.tools.items, 0..) |*t, ti| {
                if (ti > 0) out.append(gpa, ',') catch {};
                jsonStr(gpa, &out, t.name);
            }
            out.appendSlice(gpa, "]}") catch {};
        }
        out.append(gpa, ']') catch {};
        return out.toOwnedSlice(gpa) catch @constCast("[]");
    }
};

fn jsonStr(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    out.append(gpa, '"') catch {};
    for (s) |ch| switch (ch) {
        '"' => out.appendSlice(gpa, "\\\"") catch {},
        '\\' => out.appendSlice(gpa, "\\\\") catch {},
        '\n' => out.appendSlice(gpa, "\\n") catch {},
        '\r' => out.appendSlice(gpa, "\\r") catch {},
        '\t' => out.appendSlice(gpa, "\\t") catch {},
        else => {
            if (ch < 0x20) {
                var b: [6]u8 = undefined;
                out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{ch}) catch "") catch {};
            } else out.append(gpa, ch) catch {};
        },
    };
    out.append(gpa, '"') catch {};
}

fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > NAME_MAX) return false;
    for (s) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// The veil.* manifest API (CFns; upvalue 1 = lightuserdata *Plugin)
// ---------------------------------------------------------------------------------------------

fn plugOf(l: ?*lua.LuaState) *Plugin {
    return @ptrCast(@alignCast(lua.c.lua_touserdata(l.?, lua.upvalueIndex(1)).?));
}

fn raise(L: *lua.LuaState, comptime msg: [:0]const u8) c_int {
    _ = lua.c.lua_pushstring(L, msg.ptr);
    return lua.c.lua_error(L);
}

/// veil.plugin{ name=, version=, description= }
fn apiPlugin(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    if (!p.loading) return raise(L, "veil.plugin: registration is load-time only");
    if (lua.c.lua_type(L, 1) != lua.TTABLE) return raise(L, "veil.plugin expects a table");
    const a = p.reg.arena_state.allocator();
    _ = lua.c.lua_getfield(L, 1, "name");
    if (lua.toString(L, -1)) |s| p.name = a.dupe(u8, s) catch p.name;
    lua.pop(L, 1);
    _ = lua.c.lua_getfield(L, 1, "version");
    if (lua.toString(L, -1)) |s| p.version = a.dupe(u8, s) catch p.version;
    lua.pop(L, 1);
    _ = lua.c.lua_getfield(L, 1, "description");
    if (lua.toString(L, -1)) |s| p.description = a.dupe(u8, s) catch p.description;
    lua.pop(L, 1);
    if (!validName(p.name)) return raise(L, "veil.plugin: name must be [a-z0-9_], 1..24 chars");
    return 0;
}

/// veil.on_policy(fn) / veil.on_prompt(fn)
fn apiOnPolicy(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    if (!p.loading) return raise(L, "veil.on_policy: registration is load-time only");
    if (lua.c.lua_type(L, 1) != lua.TFUNCTION) return raise(L, "veil.on_policy expects a function");
    lua.c.lua_pushvalue(L, 1);
    p.policy_ref = lua.c.luaL_ref(L, lua.REGISTRYINDEX);
    return 0;
}
fn apiOnPrompt(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    if (!p.loading) return raise(L, "veil.on_prompt: registration is load-time only");
    if (lua.c.lua_type(L, 1) != lua.TFUNCTION) return raise(L, "veil.on_prompt expects a function");
    lua.c.lua_pushvalue(L, 1);
    p.prompt_ref = lua.c.luaL_ref(L, lua.REGISTRYINDEX);
    return 0;
}

/// veil.tool{ name=, description=, params={n={type=,description=,required=}} | params_json=, handler=fn }
fn apiTool(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    if (!p.loading) return raise(L, "veil.tool: registration is load-time only");
    if (lua.c.lua_type(L, 1) != lua.TTABLE) return raise(L, "veil.tool expects a table");
    if (p.tools.items.len >= MAX_TOOLS_PER_PLUGIN) return raise(L, "veil.tool: too many tools in this plugin");
    const a = p.reg.arena_state.allocator();

    var short: []const u8 = "";
    _ = lua.c.lua_getfield(L, 1, "name");
    if (lua.toString(L, -1)) |s| short = a.dupe(u8, s) catch "";
    lua.pop(L, 1);
    if (!validName(short)) return raise(L, "veil.tool: name must be [a-z0-9_], 1..24 chars");

    var desc: []const u8 = "";
    _ = lua.c.lua_getfield(L, 1, "description");
    if (lua.toString(L, -1)) |s| desc = a.dupe(u8, s) catch "";
    lua.pop(L, 1);

    // handler is required and must be a function
    _ = lua.c.lua_getfield(L, 1, "handler");
    if (lua.c.lua_type(L, -1) != lua.TFUNCTION) {
        lua.pop(L, 1);
        return raise(L, "veil.tool: handler must be a function");
    }
    const href = lua.c.luaL_ref(L, lua.REGISTRYINDEX); // pops the handler

    // parameters: params_json (verbatim, validated) or params table (synthesized), else empty object
    var params: []const u8 = "{\"type\":\"object\",\"properties\":{}}";
    _ = lua.c.lua_getfield(L, 1, "params_json");
    if (lua.toString(L, -1)) |pj| {
        const dup = a.dupe(u8, pj) catch "";
        lua.pop(L, 1);
        var arena_probe = std.heap.ArenaAllocator.init(p.reg.gpa);
        defer arena_probe.deinit();
        _ = std.json.parseFromSliceLeaky(std.json.Value, arena_probe.allocator(), dup, .{}) catch
            return raise(L, "veil.tool: params_json is not valid JSON");
        params = dup;
    } else {
        lua.pop(L, 1);
        if (lua.c.lua_getfield(L, 1, "params") == lua.TTABLE) {
            params = synthParams(p, L) catch return raise(L, "veil.tool: could not build params schema");
        }
        lua.pop(L, 1);
    }

    var name_buf: [80]u8 = undefined;
    const full = std.fmt.bufPrint(&name_buf, "plug_{s}_{s}", .{ p.name, short }) catch
        return raise(L, "veil.tool: combined tool name too long");
    if (full.len > 64) return raise(L, "veil.tool: combined tool name exceeds 64 chars");
    if (p.name.len == 0) return raise(L, "veil.tool: call veil.plugin{...} with a name first");

    p.tools.append(p.reg.gpa, .{
        .name = a.dupe(u8, full) catch return raise(L, "veil.tool: oom"),
        .short = short,
        .description = desc,
        .params_json = params,
        .kind = .script,
        .handler_ref = href,
    }) catch return raise(L, "veil.tool: oom");
    return 0;
}

/// Build {"type":"object","properties":{...},"required":[...]} from the `params` table at stack top.
fn synthParams(p: *Plugin, L: *lua.LuaState) ![]const u8 {
    const a = p.reg.arena_state.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(p.reg.gpa);
    var req: std.ArrayListUnmanaged(u8) = .empty;
    defer req.deinit(p.reg.gpa);
    try out.appendSlice(p.reg.gpa, "{\"type\":\"object\",\"properties\":{");
    var first = true;
    lua.c.lua_pushnil(L);
    while (lua.c.lua_next(L, -2) != 0) {
        // key must be a string param name; value a table {type=,description=,required=}
        if (lua.c.lua_type(L, -2) == lua.TSTRING and lua.c.lua_type(L, -1) == lua.TTABLE) {
            const pname = lua.toString(L, -2).?;
            if (!first) try out.append(p.reg.gpa, ',');
            first = false;
            jsonStr(p.reg.gpa, &out, pname);
            try out.appendSlice(p.reg.gpa, ":{\"type\":");
            _ = lua.c.lua_getfield(L, -1, "type");
            const ptype = lua.toString(L, -1) orelse "string";
            jsonStr(p.reg.gpa, &out, ptype);
            lua.pop(L, 1);
            _ = lua.c.lua_getfield(L, -1, "description");
            if (lua.toString(L, -1)) |d| {
                try out.appendSlice(p.reg.gpa, ",\"description\":");
                jsonStr(p.reg.gpa, &out, d);
            }
            lua.pop(L, 1);
            try out.append(p.reg.gpa, '}');
            _ = lua.c.lua_getfield(L, -1, "required");
            if (lua.c.lua_toboolean(L, -1) != 0) {
                if (req.items.len > 0) try req.append(p.reg.gpa, ',');
                jsonStr(p.reg.gpa, &req, pname);
            }
            lua.pop(L, 1);
        }
        lua.pop(L, 1);
    }
    try out.append(p.reg.gpa, '}');
    if (req.items.len > 0) {
        try out.appendSlice(p.reg.gpa, ",\"required\":[");
        try out.appendSlice(p.reg.gpa, req.items);
        try out.append(p.reg.gpa, ']');
    }
    try out.append(p.reg.gpa, '}');
    return a.dupe(u8, out.items);
}

/// veil.mcp{ command={"exe","arg",...}, env={K=V}, timeout_s=20 }
fn apiMcp(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    if (!p.loading) return raise(L, "veil.mcp: registration is load-time only");
    if (lua.c.lua_type(L, 1) != lua.TTABLE) return raise(L, "veil.mcp expects a table");
    const a = p.reg.arena_state.allocator();
    if (lua.c.lua_getfield(L, 1, "command") != lua.TTABLE) {
        lua.pop(L, 1);
        return raise(L, "veil.mcp: command must be an array like {\"npx\",\"-y\",\"pkg\"}");
    }
    const n: usize = @intCast(lua.c.lua_rawlen(L, -1));
    if (n == 0) {
        lua.pop(L, 1);
        return raise(L, "veil.mcp: command array is empty");
    }
    var argv = a.alloc([]const u8, n - 1) catch return raise(L, "veil.mcp: oom");
    var command: []const u8 = "";
    var i: lua.Integer = 1;
    while (i <= n) : (i += 1) {
        _ = lua.c.lua_rawgeti(L, -1, i);
        const s = lua.toString(L, -1) orelse "";
        const dup = a.dupe(u8, s) catch "";
        if (i == 1) command = dup else argv[@intCast(i - 2)] = dup;
        lua.pop(L, 1);
    }
    lua.pop(L, 1); // command table
    // env extras
    var envs: std.ArrayListUnmanaged(mcp.EnvPair) = .empty;
    defer envs.deinit(p.reg.gpa);
    if (lua.c.lua_getfield(L, 1, "env") == lua.TTABLE) {
        lua.c.lua_pushnil(L);
        while (lua.c.lua_next(L, -2) != 0) {
            if (lua.c.lua_type(L, -2) == lua.TSTRING and lua.c.lua_type(L, -1) == lua.TSTRING) {
                const k = a.dupe(u8, lua.toString(L, -2).?) catch "";
                const v = a.dupe(u8, lua.toString(L, -1).?) catch "";
                envs.append(p.reg.gpa, .{ .k = k, .v = v }) catch {};
            }
            lua.pop(L, 1);
        }
    }
    lua.pop(L, 1);
    _ = lua.c.lua_getfield(L, 1, "timeout_s");
    if (lua.c.lua_isnumber(L, -1) != 0) {
        const t = lua.c.lua_tointegerx(L, -1, null);
        if (t > 0 and t <= 300) p.mcp_timeout_s = @intCast(t);
    }
    lua.pop(L, 1);
    p.mcp_srv = .{
        .command = command,
        .args = argv,
        .env_extra = a.dupe(mcp.EnvPair, envs.items) catch &.{},
    };
    return 0;
}

/// veil.log(...) — also installed as the global `print` inside plugin VMs.
fn apiLog(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    const n = lua.c.lua_gettop(L);
    var i: c_int = 1;
    while (i <= n) : (i += 1) {
        const s = lua.c.luaL_tolstring(L, i, null);
        const sl = std.mem.span(s);
        if (len < buf.len and i > 1) {
            buf[len] = ' ';
            len += 1;
        }
        const take = @min(sl.len, buf.len - len);
        @memcpy(buf[len .. len + take], sl[0..take]);
        len += take;
        lua.pop(L, 1);
    }
    log.info("[{s}] {s}", .{ if (p.name.len > 0) p.name else "plugin", buf[0..len] });
    return 0;
}

/// veil.json_decode(s) -> table|nil, err
fn apiJsonDecode(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    var len: usize = 0;
    const s = lua.c.lua_tolstring(L, 1, &len) orelse {
        lua.c.lua_pushnil(L);
        _ = lua.c.lua_pushstring(L, "json_decode expects a string");
        return 2;
    };
    var arena_state = std.heap.ArenaAllocator.init(p.reg.gpa);
    defer arena_state.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), s[0..len], .{}) catch {
        lua.c.lua_pushnil(L);
        _ = lua.c.lua_pushstring(L, "invalid JSON");
        return 2;
    };
    lua.pushJson(L, v);
    return 1;
}

/// veil.json_encode(v) -> string|nil
fn apiJsonEncode(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    var arena_state = std.heap.ArenaAllocator.init(p.reg.gpa);
    defer arena_state.deinit();
    const v = lua.luaToJson(arena_state.allocator(), L, 1, 0) catch {
        lua.c.lua_pushnil(L);
        return 1;
    };
    const s = std.json.Stringify.valueAlloc(p.reg.gpa, v, .{}) catch {
        lua.c.lua_pushnil(L);
        return 1;
    };
    lua.pushSlice(L, s);
    p.reg.gpa.free(s);
    return 1;
}

/// veil.read_file(rel) -> string|nil, err — scoped to the plugin's own folder.
fn apiReadFile(l: ?*lua.LuaState) callconv(.c) c_int {
    const L = l.?;
    const p = plugOf(l);
    var len: usize = 0;
    const rel_p = lua.c.lua_tolstring(L, 1, &len) orelse {
        lua.c.lua_pushnil(L);
        _ = lua.c.lua_pushstring(L, "read_file expects a relative path");
        return 2;
    };
    const rel = rel_p[0..len];
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\' or std.mem.indexOf(u8, rel, "..") != null or (rel.len > 1 and rel[1] == ':')) {
        lua.c.lua_pushnil(L);
        _ = lua.c.lua_pushstring(L, "read_file: path must be relative, inside the plugin folder");
        return 2;
    }
    var path_buf: [640]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ p.dir, rel }) catch {
        lua.c.lua_pushnil(L);
        _ = lua.c.lua_pushstring(L, "read_file: path too long");
        return 2;
    };
    const vm = p.vm orelse {
        lua.c.lua_pushnil(L);
        _ = lua.c.lua_pushstring(L, "read_file: vm unavailable");
        return 2;
    };
    const data = lua.readSmallFile(vm.io, p.reg.gpa, path, 2 << 20) catch {
        lua.c.lua_pushnil(L);
        _ = lua.c.lua_pushstring(L, "read_file: not found or too large");
        return 2;
    };
    lua.pushSlice(L, data);
    p.reg.gpa.free(data);
    return 1;
}

fn installVeilApi(p: *Plugin) void {
    const vm = p.vm.?;
    const L = vm.L;
    lua.c.lua_createtable(L, 0, 9);
    const entries = [_]struct { n: [:0]const u8, f: lua.CFn }{
        .{ .n = "plugin", .f = apiPlugin },
        .{ .n = "tool", .f = apiTool },
        .{ .n = "on_policy", .f = apiOnPolicy },
        .{ .n = "on_prompt", .f = apiOnPrompt },
        .{ .n = "mcp", .f = apiMcp },
        .{ .n = "log", .f = apiLog },
        .{ .n = "json_decode", .f = apiJsonDecode },
        .{ .n = "json_encode", .f = apiJsonEncode },
        .{ .n = "read_file", .f = apiReadFile },
    };
    for (entries) |e| {
        lua.c.lua_pushlightuserdata(L, p);
        lua.c.lua_pushcclosure(L, e.f, 1);
        lua.c.lua_setfield(L, -2, e.n.ptr);
    }
    lua.c.lua_setglobal(L, "veil");
    // print → plugin log (stdout belongs to the server console, not plugins)
    lua.c.lua_pushlightuserdata(L, p);
    lua.c.lua_pushcclosure(L, apiLog, 1);
    lua.c.lua_setglobal(L, "print");
}

// ---------------------------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------------------------

/// Build a registry from `<data_dir>/plugins/*/plugin.lua` + the theme workspace. Never fails:
/// a broken plugin loads as state=failed with its error kept; a missing dir yields an empty set.
pub fn loadAll(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map, data_dir: []const u8, opts: LoadOptions) *Registry {
    const reg = gpa.create(Registry) catch unreachable;
    reg.* = .{
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .gpa = gpa,
        .io = io,
        .environ = environ,
    };
    const a = reg.arena_state.allocator();
    reg.data_dir = a.dupe(u8, data_dir) catch "";

    theme.loadWorkspace(gpa, io, data_dir, &reg.themes);
    // Cache the compiled set as JSON so the desk (a thin client on this same machine) can render user
    // themes without embedding Lua — it reads <data>/themes/themes.json directly. Refreshed on every reload.
    theme.writeCache(gpa, io, data_dir, &reg.themes);

    var dirbuf: [512]u8 = undefined;
    const pdir_path = std.fmt.bufPrint(&dirbuf, "{s}/plugins", .{data_dir}) catch return reg;
    std.Io.Dir.cwd().createDirPath(io, pdir_path) catch {};
    var pdir = std.Io.Dir.cwd().openDir(io, pdir_path, .{ .iterate = true }) catch return reg;
    defer pdir.close(io);

    // collect + sort plugin folder names — deterministic hook order
    var names: [MAX_PLUGINS][64]u8 = undefined;
    var lens: [MAX_PLUGINS]u8 = undefined;
    var n_dirs: usize = 0;
    var it = pdir.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        if (ent.name.len > 64 or n_dirs >= MAX_PLUGINS) continue;
        @memcpy(names[n_dirs][0..ent.name.len], ent.name);
        lens[n_dirs] = @intCast(ent.name.len);
        n_dirs += 1;
    }
    var si: usize = 1;
    while (si < n_dirs) : (si += 1) {
        var j: usize = si;
        while (j > 0 and std.mem.lessThan(u8, names[j][0..lens[j]], names[j - 1][0..lens[j - 1]])) : (j -= 1) {
            std.mem.swap([64]u8, &names[j], &names[j - 1]);
            std.mem.swap(u8, &lens[j], &lens[j - 1]);
        }
    }

    var plugins: std.ArrayListUnmanaged(Plugin) = .empty;
    for (0..n_dirs) |di| {
        const dname = names[di][0..lens[di]];
        var pathb: [640]u8 = undefined;
        // disabled marker: a `.disabled` file in the plugin folder skips it entirely
        const disabled = std.fmt.bufPrint(&pathb, "{s}/{s}/.disabled", .{ pdir_path, dname }) catch continue;
        if (std.Io.Dir.cwd().access(io, disabled, .{})) |_| {
            log.info("plugin {s}: disabled (marker present)", .{dname});
            continue;
        } else |_| {}
        const manifest_path = std.fmt.bufPrint(&pathb, "{s}/{s}/plugin.lua", .{ pdir_path, dname }) catch continue;
        const src = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(256 << 10)) catch continue; // no manifest ⇒ not a plugin
        defer gpa.free(src);

        plugins.append(a, .{}) catch break;
        const p = &plugins.items[plugins.items.len - 1];
        p.reg = reg;
        p.dir = std.fmt.allocPrint(a, "{s}/{s}", .{ pdir_path, dname }) catch "";
        loadOne(reg, p, src, opts);
    }
    reg.plugins = plugins.items;
    reg.schemas = buildSchemas(reg) catch "";
    return reg;
}

fn failPlugin(reg: *Registry, p: *Plugin, msg: []const u8) void {
    p.state = .failed;
    p.err = reg.arena_state.allocator().dupe(u8, msg) catch "";
    log.warn("plugin {s}: load failed: {s}", .{ if (p.name.len > 0) p.name else p.dir, msg });
}

fn loadOne(reg: *Registry, p: *Plugin, manifest_src: []const u8, opts: LoadOptions) void {
    const vm = lua.Vm.init(reg.gpa, reg.io, .{}) catch {
        failPlugin(reg, p, "could not create Lua state");
        return;
    };
    p.vm = vm;
    vm.openSandboxedLibs();
    vm.setRoot(p.dir) catch {};
    installVeilApi(p);
    p.loading = true;
    defer p.loading = false;
    vm.runBuffer(manifest_src, "@plugin.lua", 0) catch {
        failPlugin(reg, p, vm.lastError());
        return;
    };
    if (!validName(p.name)) {
        failPlugin(reg, p, "manifest never called veil.plugin{ name = ... }");
        return;
    }
    // duplicate plugin names: first (alphabetical dir) wins
    for (reg.plugins) |*other| {
        _ = other;
    }
    // MCP bridge: list the server's tools once at load and advertise each as plug_<name>_<tool>
    if (p.mcp_srv) |srv| {
        if (opts.skip_mcp_listing) {
            log.info("plugin {s}: MCP listing skipped (test mode)", .{p.name});
        } else if (reg.environ) |env| {
            const listing = mcp.listStdio(reg.gpa, reg.io, env, srv, p.mcp_timeout_s);
            defer reg.gpa.free(listing);
            addMcpTools(reg, p, listing) catch {
                failPlugin(reg, p, "MCP server did not return a usable tools/list");
                return;
            };
        } else {
            failPlugin(reg, p, "no server environment available to spawn the MCP server");
            return;
        }
    }
}

fn addMcpTools(reg: *Registry, p: *Plugin, listing_json: []const u8) !void {
    const a = reg.arena_state.allocator();
    var arena_state = std.heap.ArenaAllocator.init(reg.gpa);
    defer arena_state.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), listing_json, .{}) catch return error.BadListing;
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadListing,
    };
    if (obj.get("error") != null and obj.get("tools") == null) return error.BadListing;
    const tools_v = obj.get("tools") orelse return error.BadListing;
    const arr = switch (tools_v) {
        .array => |ar| ar,
        else => return error.BadListing,
    };
    for (arr.items) |item| {
        if (p.tools.items.len >= MAX_TOOLS_PER_PLUGIN) break;
        const to = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const tname = switch (to.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const tdesc: []const u8 = if (to.get("description")) |d| switch (d) {
            .string => |s| s,
            else => "",
        } else "";
        var full_buf: [96]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "plug_{s}_{s}", .{ p.name, tname }) catch continue;
        if (full.len > 64) continue;
        var schema: []const u8 = "{\"type\":\"object\",\"properties\":{}}";
        if (to.get("inputSchema")) |is| {
            schema = std.json.Stringify.valueAlloc(a, is, .{}) catch schema;
        }
        p.tools.append(reg.gpa, .{
            .name = a.dupe(u8, full) catch continue,
            .short = a.dupe(u8, tname) catch continue,
            .description = a.dupe(u8, tdesc[0..@min(tdesc.len, 512)]) catch "",
            .params_json = schema,
            .kind = .mcp_bridge,
        }) catch break;
    }
}

/// Join every ok plugin tool into ",\n{schema},\n{schema}" for buildTurnTools to append. The
/// string is stable for the registry's lifetime — the same prefix-cache discipline recipes follow.
fn buildSchemas(reg: *Registry) ![]const u8 {
    const a = reg.arena_state.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(reg.gpa);
    for (reg.plugins) |*p| {
        if (p.state != .ok) continue;
        for (p.tools.items) |*t| {
            try out.appendSlice(reg.gpa, ",\n{\"type\":\"function\",\"function\":{\"name\":");
            jsonStr(reg.gpa, &out, t.name);
            try out.appendSlice(reg.gpa, ",\"description\":");
            var db: [640]u8 = undefined;
            const d = std.fmt.bufPrint(&db, "[plugin {s}] {s}", .{ p.name, t.description[0..@min(t.description.len, 500)] }) catch t.description;
            jsonStr(reg.gpa, &out, d);
            try out.appendSlice(reg.gpa, ",\"parameters\":");
            try out.appendSlice(reg.gpa, t.params_json);
            try out.appendSlice(reg.gpa, "}}");
        }
    }
    return a.dupe(u8, out.items);
}

// ---------------------------------------------------------------------------------------------
// Registry pointer swap helpers (App.plugs is read from many threads; reload swaps it)
// ---------------------------------------------------------------------------------------------

pub fn current(slot: *?*Registry) ?*Registry {
    return @atomicLoad(?*Registry, slot, .acquire);
}
pub fn swap(slot: *?*Registry, new_reg: *Registry) void {
    // The previous registry is intentionally NOT freed: in-flight turns may still hold it. Reload
    // is a rare admin action; the leak is bounded and documented.
    @atomicStore(?*Registry, slot, new_reg, .release);
}

// ---------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------

const t_alloc = std.testing.allocator;

fn writePlugin(io: std.Io, dir: std.Io.Dir, sub: []const u8, manifest: []const u8) !void {
    var b: [128]u8 = undefined;
    try dir.createDirPath(io, std.fmt.bufPrint(&b, "plugins/{s}", .{sub}) catch unreachable);
    try dir.writeFile(io, .{ .sub_path = std.fmt.bufPrint(&b, "plugins/{s}/plugin.lua", .{sub}) catch unreachable, .data = manifest });
}

test "plugins: manifest registers meta + tool + hooks; tool executes; policy denies; prompt text" {
    var threaded = std.Io.Threaded.init(t_alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // tmp dir as the data dir: write plugins/greet/plugin.lua
    try writePlugin(io, tmp.dir, "greet",
        \\veil.plugin{ name = "greet", version = "1.0", description = "demo" }
        \\veil.tool{
        \\  name = "hello",
        \\  description = "Say hello",
        \\  params = { who = { type = "string", description = "name", required = true } },
        \\  handler = function(args) return "hello " .. (args.who or "?") end,
        \\}
        \\veil.tool{
        \\  name = "shape",
        \\  description = "returns a table",
        \\  handler = function(args) return { ok = true, n = 3 } end,
        \\}
        \\veil.on_policy(function(ctx)
        \\  if ctx.tool == "host_command" then return { allow = false, reason = "no host from tests" } end
        \\  return true
        \\end)
        \\veil.on_prompt(function(ctx) return "Answer like a pirate." end)
    );
    // a broken plugin alongside — must not sink the good one
    try writePlugin(io, tmp.dir, "broken", "this is not lua at all");
    // a disabled plugin — must be skipped entirely
    try writePlugin(io, tmp.dir, "off", "veil.plugin{ name = \"off\" }");
    var b: [64]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = std.fmt.bufPrint(&b, "plugins/off/.disabled", .{}) catch unreachable, .data = "" });

    // data_dir path for loadAll: canonical absolute path of the tmp dir handle.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const plen = try tmp.dir.realPath(io, &path_buf);
    const data_path = path_buf[0..plen];

    const reg = loadAll(t_alloc, io, null, data_path, .{ .skip_mcp_listing = true });
    defer {
        reg.deinit();
        t_alloc.destroy(reg);
    }
    try std.testing.expectEqual(@as(usize, 2), reg.plugins.len); // greet + broken (off skipped)

    // themes came along for the ride (workspace seeded into the same data dir)
    try std.testing.expect(reg.themes.count >= 3);

    const greet = blk: {
        for (reg.plugins) |*p| {
            if (std.mem.eql(u8, p.name, "greet")) break :blk p;
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(State.ok, greet.state);
    try std.testing.expectEqual(@as(usize, 2), greet.tools.items.len);

    const broken = blk: {
        for (reg.plugins) |*p| {
            if (p.state == .failed) break :blk p;
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(broken.err.len > 0);

    // schema chunk advertises the tool and is valid JSON when wrapped
    try std.testing.expect(std.mem.indexOf(u8, reg.schemas, "plug_greet_hello") != null);
    var wrap: std.ArrayListUnmanaged(u8) = .empty;
    defer wrap.deinit(t_alloc);
    try wrap.append(t_alloc, '[');
    try wrap.appendSlice(t_alloc, reg.schemas[1..]); // drop the leading comma
    try wrap.append(t_alloc, ']');
    const parsed = try std.json.parseFromSlice(std.json.Value, t_alloc, wrap.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);

    // dispatch: string result
    try std.testing.expect(reg.ownsTool("plug_greet_hello"));
    const r1 = reg.execTool(t_alloc, "plug_greet_hello", "{\"who\":\"veil\"}");
    defer t_alloc.free(r1);
    try std.testing.expectEqualStrings("hello veil", r1);
    // dispatch: table result → JSON
    const r2 = reg.execTool(t_alloc, "plug_greet_shape", "{}");
    defer t_alloc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "\"ok\":true") != null);

    // policy: denies host_command with the reason, allows others
    const denied = reg.policyGate(t_alloc, 1, true, "c1", "host_command", "{}");
    try std.testing.expect(denied != null);
    defer t_alloc.free(denied.?);
    try std.testing.expect(std.mem.indexOf(u8, denied.?, "no host from tests") != null);
    try std.testing.expect(reg.policyGate(t_alloc, 1, true, "c1", "read_file", "{}") == null);

    // prompt hook text with the plugin tag
    const pt = reg.promptText(t_alloc, 1, false, "c1");
    try std.testing.expect(pt != null);
    defer t_alloc.free(pt.?);
    try std.testing.expect(std.mem.indexOf(u8, pt.?, "pirate") != null);
    try std.testing.expect(std.mem.indexOf(u8, pt.?, "[plugin greet]") != null);

    // listJson mentions both states
    const lj = reg.listJson(t_alloc);
    defer t_alloc.free(lj);
    try std.testing.expect(std.mem.indexOf(u8, lj, "\"state\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lj, "\"state\":\"failed\"") != null);
}

test "plugins: empty/missing dir loads an empty registry with themes" {
    var threaded = std.Io.Threaded.init(t_alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const plen = try tmp.dir.realPath(io, &path_buf);
    const data_path = path_buf[0..plen];
    const reg = loadAll(t_alloc, io, null, data_path, .{ .skip_mcp_listing = true });
    defer {
        reg.deinit();
        t_alloc.destroy(reg);
    }
    try std.testing.expectEqual(@as(usize, 0), reg.plugins.len);
    try std.testing.expectEqual(@as(usize, 0), reg.schemas.len);
    try std.testing.expect(reg.themes.byId("matrix") != null);
    try std.testing.expect(reg.policyGate(t_alloc, 1, false, "", "anything", "{}") == null);
    try std.testing.expect(reg.promptText(t_alloc, 1, false, "") == null);
}
