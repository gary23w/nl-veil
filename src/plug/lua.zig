//! lua.zig — the embedded Lua 5.4 runtime every veil extension point runs on.
//!
//! One file, three layers:
//!   1. `c`  — hand-written extern bindings to the vendored Lua (vendor/lua). No @cImport: the C API
//!      is small and stable, and explicit externs keep the ABI visible and the build translate-c-free.
//!   2. macro re-implementations — lua.h exposes pop/tostring/pcall/... as C macros; the Zig twins
//!      live here so call sites read like the Lua manual.
//!   3. `Vm` — a SANDBOXED state: whitelisted stdlib (no io, no debug, no os.execute), text-only
//!      chunk loading (bytecode is a sandbox escape), a plugin-dir-scoped `require`, an instruction
//!      budget (count hook) so a `while true do end` cannot wedge a chat thread, and a byte-capped
//!      allocator so a string bomb cannot OOM the host.
//!
//! Threading: a Vm is NOT thread-safe. Owners (plugin registry) serialize entry with a mutex; theme
//! loading uses a throwaway Vm per load. CFns called back from Lua must not hold defers across
//! lua_error — Lua unwinds with longjmp and Zig defers in that frame will not run.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------------------------
// Layer 1: raw C API (vendor/lua, Lua 5.4.8)
// ---------------------------------------------------------------------------------------------

pub const LuaState = opaque {};
pub const LuaDebug = opaque {};

pub const CFn = *const fn (?*LuaState) callconv(.c) c_int;
pub const HookFn = *const fn (?*LuaState, ?*LuaDebug) callconv(.c) void;
pub const AllocFn = *const fn (ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque;
pub const WarnFn = *const fn (ud: ?*anyopaque, msg: [*:0]const u8, tocont: c_int) callconv(.c) void;

pub const Integer = i64; // LUA_INTEGER = long long (LLP64-safe)
pub const Number = f64;

// status codes
pub const OK: c_int = 0;
pub const YIELD: c_int = 1;
pub const ERRRUN: c_int = 2;
pub const ERRSYNTAX: c_int = 3;
pub const ERRMEM: c_int = 4;
pub const ERRERR: c_int = 5;

// type tags
pub const TNONE: c_int = -1;
pub const TNIL: c_int = 0;
pub const TBOOLEAN: c_int = 1;
pub const TLIGHTUSERDATA: c_int = 2;
pub const TNUMBER: c_int = 3;
pub const TSTRING: c_int = 4;
pub const TTABLE: c_int = 5;
pub const TFUNCTION: c_int = 6;
pub const TUSERDATA: c_int = 7;
pub const TTHREAD: c_int = 8;

pub const MULTRET: c_int = -1;
// -LUAI_MAXSTACK - 1000 with LUAI_MAXSTACK = 1_000_000 on 64-bit (luaconf.h)
pub const REGISTRYINDEX: c_int = -1001000;
pub const RIDX_GLOBALS: Integer = 2;
pub const MASKCOUNT: c_int = 1 << 3; // LUA_HOOKCOUNT = 3
pub const GCCOLLECT: c_int = 2;
pub const REFNIL: c_int = -1;
pub const NOREF: c_int = -2;

pub const c = struct {
    pub extern fn lua_newstate(f: AllocFn, ud: ?*anyopaque) ?*LuaState;
    pub extern fn lua_close(L: *LuaState) void;
    pub extern fn lua_atpanic(L: *LuaState, panicf: CFn) ?CFn;
    pub extern fn lua_setwarnf(L: *LuaState, f: ?WarnFn, ud: ?*anyopaque) void;
    pub extern fn lua_sethook(L: *LuaState, func: ?HookFn, mask: c_int, count: c_int) void;
    pub extern fn lua_error(L: *LuaState) c_int;
    pub extern fn lua_checkstack(L: *LuaState, n: c_int) c_int;

    pub extern fn lua_absindex(L: *LuaState, idx: c_int) c_int;
    pub extern fn lua_gettop(L: *LuaState) c_int;
    pub extern fn lua_settop(L: *LuaState, idx: c_int) void;
    pub extern fn lua_pushvalue(L: *LuaState, idx: c_int) void;
    pub extern fn lua_rotate(L: *LuaState, idx: c_int, n: c_int) void;
    pub extern fn lua_copy(L: *LuaState, fromidx: c_int, toidx: c_int) void;

    pub extern fn lua_type(L: *LuaState, idx: c_int) c_int;
    pub extern fn lua_typename(L: *LuaState, tp: c_int) [*:0]const u8;
    pub extern fn lua_toboolean(L: *LuaState, idx: c_int) c_int;
    pub extern fn lua_tolstring(L: *LuaState, idx: c_int, len: ?*usize) ?[*:0]const u8;
    pub extern fn lua_tonumberx(L: *LuaState, idx: c_int, isnum: ?*c_int) Number;
    pub extern fn lua_tointegerx(L: *LuaState, idx: c_int, isnum: ?*c_int) Integer;
    pub extern fn lua_rawlen(L: *LuaState, idx: c_int) u64;
    pub extern fn lua_touserdata(L: *LuaState, idx: c_int) ?*anyopaque;
    pub extern fn lua_isnumber(L: *LuaState, idx: c_int) c_int;
    pub extern fn lua_isinteger(L: *LuaState, idx: c_int) c_int;
    pub extern fn lua_isstring(L: *LuaState, idx: c_int) c_int;

    pub extern fn lua_pushnil(L: *LuaState) void;
    pub extern fn lua_pushboolean(L: *LuaState, b: c_int) void;
    pub extern fn lua_pushinteger(L: *LuaState, n: Integer) void;
    pub extern fn lua_pushnumber(L: *LuaState, n: Number) void;
    pub extern fn lua_pushlstring(L: *LuaState, s: [*]const u8, len: usize) ?[*:0]const u8;
    pub extern fn lua_pushstring(L: *LuaState, s: ?[*:0]const u8) ?[*:0]const u8;
    pub extern fn lua_pushcclosure(L: *LuaState, f: CFn, n: c_int) void;
    pub extern fn lua_pushlightuserdata(L: *LuaState, p: ?*anyopaque) void;

    pub extern fn lua_createtable(L: *LuaState, narr: c_int, nrec: c_int) void;
    pub extern fn lua_getfield(L: *LuaState, idx: c_int, k: [*:0]const u8) c_int;
    pub extern fn lua_setfield(L: *LuaState, idx: c_int, k: [*:0]const u8) void;
    pub extern fn lua_geti(L: *LuaState, idx: c_int, n: Integer) c_int;
    pub extern fn lua_seti(L: *LuaState, idx: c_int, n: Integer) void;
    pub extern fn lua_rawgeti(L: *LuaState, idx: c_int, n: Integer) c_int;
    pub extern fn lua_rawseti(L: *LuaState, idx: c_int, n: Integer) void;
    pub extern fn lua_gettable(L: *LuaState, idx: c_int) c_int;
    pub extern fn lua_settable(L: *LuaState, idx: c_int) void;
    pub extern fn lua_next(L: *LuaState, idx: c_int) c_int;
    pub extern fn lua_getglobal(L: *LuaState, name: [*:0]const u8) c_int;
    pub extern fn lua_setglobal(L: *LuaState, name: [*:0]const u8) void;

    pub extern fn lua_pcallk(L: *LuaState, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) c_int;
    pub extern fn lua_callk(L: *LuaState, nargs: c_int, nresults: c_int, ctx: isize, k: ?*const anyopaque) void;
    pub extern fn lua_gc(L: *LuaState, what: c_int, ...) c_int;

    pub extern fn luaL_loadbufferx(L: *LuaState, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
    pub extern fn luaL_traceback(L: *LuaState, L1: *LuaState, msg: ?[*:0]const u8, level: c_int) void;
    pub extern fn luaL_tolstring(L: *LuaState, idx: c_int, len: ?*usize) [*:0]const u8;
    pub extern fn luaL_ref(L: *LuaState, t: c_int) c_int;
    pub extern fn luaL_unref(L: *LuaState, t: c_int, ref: c_int) void;
    pub extern fn luaL_requiref(L: *LuaState, modname: [*:0]const u8, openf: CFn, glb: c_int) void;
    pub extern fn luaL_len(L: *LuaState, idx: c_int) Integer;

    pub extern fn luaopen_base(L: ?*LuaState) c_int;
    pub extern fn luaopen_string(L: ?*LuaState) c_int;
    pub extern fn luaopen_table(L: ?*LuaState) c_int;
    pub extern fn luaopen_math(L: ?*LuaState) c_int;
    pub extern fn luaopen_utf8(L: ?*LuaState) c_int;
    pub extern fn luaopen_coroutine(L: ?*LuaState) c_int;
    pub extern fn luaopen_os(L: ?*LuaState) c_int;
};

// ---------------------------------------------------------------------------------------------
// Layer 2: the macros lua.h doesn't export as functions
// ---------------------------------------------------------------------------------------------

pub fn pop(L: *LuaState, n: c_int) void {
    c.lua_settop(L, -n - 1);
}
pub fn pushCFn(L: *LuaState, f: CFn) void {
    c.lua_pushcclosure(L, f, 0);
}
pub fn toString(L: *LuaState, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const p = c.lua_tolstring(L, idx, &len) orelse return null;
    return p[0..len];
}
pub fn pushSlice(L: *LuaState, s: []const u8) void {
    _ = c.lua_pushlstring(L, s.ptr, s.len);
}
pub fn pcall(L: *LuaState, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return c.lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}
pub fn remove(L: *LuaState, idx: c_int) void {
    c.lua_rotate(L, idx, -1);
    pop(L, 1);
}
pub fn insert(L: *LuaState, idx: c_int) void {
    c.lua_rotate(L, idx, 1);
}
pub fn upvalueIndex(i: c_int) c_int {
    return REGISTRYINDEX - i;
}

// ---------------------------------------------------------------------------------------------
// Layer 3: the sandboxed Vm
// ---------------------------------------------------------------------------------------------

/// Byte-capped allocator state, heap-allocated so it outlives every Lua callback.
const AllocState = struct {
    used: usize = 0,
    cap: usize,
};

fn cappedAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const st: *AllocState = @ptrCast(@alignCast(ud.?));
    // per the Lua manual: when ptr is null, osize encodes an object KIND, not a size
    const old: usize = if (ptr == null) 0 else osize;
    if (nsize == 0) {
        std.c.free(ptr);
        st.used -|= old;
        return null;
    }
    if (nsize > old and st.used + (nsize - old) > st.cap) return null; // over budget → Lua raises ERRMEM
    const np = std.c.realloc(ptr, nsize) orelse return null;
    st.used = st.used - old + nsize;
    return np;
}

fn panicHandler(l: ?*LuaState) callconv(.c) c_int {
    const L = l.?;
    const msg = toString(L, -1) orelse "unknown lua panic";
    std.debug.panic("lua panic outside pcall: {s}", .{msg});
}

fn warnSink(ud: ?*anyopaque, msg: [*:0]const u8, tocont: c_int) callconv(.c) void {
    _ = ud;
    _ = msg;
    _ = tocont; // warnings are deliberately swallowed — plugins talk through veil.log/print
}

/// Count-hook: fires once the armed instruction budget is spent. Unhooks itself first so the error
/// unwind can't re-enter, then raises — the pending pcall returns ERRRUN with this message.
fn budgetHook(l: ?*LuaState, ar: ?*LuaDebug) callconv(.c) void {
    _ = ar;
    const L = l.?;
    c.lua_sethook(L, null, 0, 0);
    _ = c.lua_pushstring(L, "plugin exceeded its instruction budget (runaway loop?)");
    _ = c.lua_error(L);
}

/// Message handler for pcalls: turn the error into "message + stack traceback".
fn traceMsgh(l: ?*LuaState) callconv(.c) c_int {
    const L = l.?;
    if (c.lua_type(L, 1) == TSTRING) {
        const msg = c.lua_tolstring(L, 1, null);
        c.luaL_traceback(L, L, msg, 1);
    } else {
        _ = c.luaL_tolstring(L, 1, null); // stringify via __tostring, leave on stack
        const msg = c.lua_tolstring(L, -1, null);
        c.luaL_traceback(L, L, msg, 1);
    }
    return 1;
}

/// `load(chunk[, chunkname])` replacement: string chunks only, TEXT mode only — the stock `load`
/// accepts precompiled bytecode, which is the classic Lua sandbox escape.
fn safeLoad(l: ?*LuaState) callconv(.c) c_int {
    const L = l.?;
    if (c.lua_type(L, 1) != TSTRING) {
        c.lua_pushnil(L);
        _ = c.lua_pushstring(L, "load: only string chunks are allowed in the veil sandbox");
        return 2;
    }
    var len: usize = 0;
    const src = c.lua_tolstring(L, 1, &len).?;
    const name: [*:0]const u8 = if (c.lua_type(L, 2) == TSTRING) c.lua_tolstring(L, 2, null).? else "=(load)";
    if (c.luaL_loadbufferx(L, src, len, name, "t") == OK) return 1;
    c.lua_pushnil(L);
    insert(L, -2); // nil under the error message
    return 2;
}

pub const VmOptions = struct {
    /// Hard heap cap for the whole state. Default 64 MiB.
    mem_cap_bytes: usize = 64 << 20,
    /// Instructions allowed per host→Lua entry (armBudget re-arms before each call). ~50M ≈ tens of ms.
    instr_budget: c_int = 50_000_000,
};

pub const Vm = struct {
    L: *LuaState,
    alloc_state: *AllocState,
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: VmOptions,
    /// Owned absolute path of the sandbox root (plugin/theme dir); require + veil.read_file scope here.
    root_dir: ?[]u8 = null,
    last_error_buf: [768]u8 = undefined,
    last_error_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: VmOptions) !*Vm {
        const vm = try gpa.create(Vm);
        errdefer gpa.destroy(vm);
        const st = try gpa.create(AllocState);
        errdefer gpa.destroy(st);
        st.* = .{ .cap = opts.mem_cap_bytes };
        const L = c.lua_newstate(cappedAlloc, st) orelse return error.LuaOom;
        vm.* = .{ .L = L, .alloc_state = st, .gpa = gpa, .io = io, .opts = opts };
        _ = c.lua_atpanic(L, panicHandler);
        c.lua_setwarnf(L, warnSink, null);
        return vm;
    }

    pub fn deinit(vm: *Vm) void {
        c.lua_close(vm.L);
        if (vm.root_dir) |d| vm.gpa.free(d);
        vm.gpa.destroy(vm.alloc_state);
        vm.gpa.destroy(vm);
    }

    /// Open the WHITELISTED stdlib. Not opened at all: io, debug, package (require is ours, below).
    /// os is opened then pruned to the pure clock/date quartet.
    pub fn openSandboxedLibs(vm: *Vm) void {
        const L = vm.L;
        c.luaL_requiref(L, "_G", c.luaopen_base, 1);
        c.luaL_requiref(L, "string", c.luaopen_string, 1);
        c.luaL_requiref(L, "table", c.luaopen_table, 1);
        c.luaL_requiref(L, "math", c.luaopen_math, 1);
        c.luaL_requiref(L, "utf8", c.luaopen_utf8, 1);
        c.luaL_requiref(L, "coroutine", c.luaopen_coroutine, 1);
        c.luaL_requiref(L, "os", c.luaopen_os, 1);
        c.lua_settop(L, 0);
        // prune os to the pure functions
        const banned = [_][:0]const u8{ "execute", "exit", "getenv", "remove", "rename", "setlocale", "tmpname" };
        _ = c.lua_getglobal(L, "os");
        for (banned) |b| {
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, b.ptr);
        }
        pop(L, 1);
        // base-lib file/bytecode doors
        const gone = [_][:0]const u8{ "dofile", "loadfile", "collectgarbage" };
        for (gone) |g| {
            c.lua_pushnil(L);
            c.lua_setglobal(L, g.ptr);
        }
        pushCFn(L, safeLoad);
        c.lua_setglobal(L, "load");
    }

    /// Scope `require`/`veil.read_file` to `dir_abs` and install the custom text-only `require`.
    pub fn setRoot(vm: *Vm, dir_abs: []const u8) !void {
        if (vm.root_dir) |d| vm.gpa.free(d);
        vm.root_dir = try vm.gpa.dupe(u8, dir_abs);
        const L = vm.L;
        // require upvalues: (1) *Vm lightuserdata, (2) module cache table
        c.lua_pushlightuserdata(L, vm);
        c.lua_createtable(L, 0, 4);
        c.lua_pushcclosure(L, scopedRequire, 2);
        c.lua_setglobal(L, "require");
    }

    /// Re-arm the instruction budget. Call before EVERY host→Lua entry: the counter carries across
    /// pcalls inside one state, so without re-arming, many small calls eventually trip it.
    pub fn armBudget(vm: *Vm) void {
        c.lua_sethook(vm.L, budgetHook, MASKCOUNT, vm.opts.instr_budget);
    }

    fn setLastError(vm: *Vm, msg: []const u8) void {
        const n = @min(msg.len, vm.last_error_buf.len);
        @memcpy(vm.last_error_buf[0..n], msg[0..n]);
        vm.last_error_len = n;
    }

    pub fn lastError(vm: *Vm) []const u8 {
        return vm.last_error_buf[0..vm.last_error_len];
    }

    /// Compile (text-only) and run `src`; leaves `nresults` values on the stack on success.
    pub fn runBuffer(vm: *Vm, src: []const u8, chunkname: [:0]const u8, nresults: c_int) !void {
        const L = vm.L;
        pushCFn(L, traceMsgh);
        const msgh = c.lua_gettop(L);
        if (c.luaL_loadbufferx(L, src.ptr, src.len, chunkname.ptr, "t") != OK) {
            vm.setLastError(toString(L, -1) orelse "syntax error");
            c.lua_settop(L, msgh - 1);
            return error.LuaSyntax;
        }
        vm.armBudget();
        if (pcall(L, 0, nresults, msgh) != OK) {
            vm.setLastError(toString(L, -1) orelse "runtime error");
            c.lua_settop(L, msgh - 1);
            return error.LuaRuntime;
        }
        remove(L, msgh);
    }

    /// Call the function at the top of the stack (args already pushed above it).
    pub fn callTop(vm: *Vm, nargs: c_int, nresults: c_int) !void {
        const L = vm.L;
        const fidx = c.lua_gettop(L) - nargs;
        pushCFn(L, traceMsgh);
        insert(L, fidx); // msgh sits under the function
        vm.armBudget();
        if (pcall(L, nargs, nresults, fidx) != OK) {
            vm.setLastError(toString(L, -1) orelse "runtime error");
            c.lua_settop(L, fidx - 1);
            return error.LuaRuntime;
        }
        remove(L, fidx);
    }

    // --- table field helpers (read from the table at `idx`, copy out, restore the stack) ---

    pub fn fieldStringDup(vm: *Vm, idx: c_int, name: [:0]const u8, gpa: std.mem.Allocator) !?[]u8 {
        const L = vm.L;
        const t = c.lua_getfield(L, idx, name.ptr);
        defer pop(L, 1);
        if (t != TSTRING) return null; // deliberate: numbers are not auto-coerced into ids/names
        const s = toString(L, -1) orelse return null;
        return try gpa.dupe(u8, s);
    }

    pub fn fieldBool(vm: *Vm, idx: c_int, name: [:0]const u8, default: bool) bool {
        const L = vm.L;
        const t = c.lua_getfield(L, idx, name.ptr);
        defer pop(L, 1);
        if (t == TNIL) return default;
        return c.lua_toboolean(L, -1) != 0;
    }

    pub fn fieldInt(vm: *Vm, idx: c_int, name: [:0]const u8, default: Integer) Integer {
        const L = vm.L;
        const t = c.lua_getfield(L, idx, name.ptr);
        defer pop(L, 1);
        if (t != TNUMBER) return default;
        return c.lua_tointegerx(L, -1, null);
    }
};

/// The scoped `require`: resolves `name` strictly inside vm.root_dir, text-mode loads only,
/// caches results like stock require. Upvalues: (1) *Vm, (2) cache table.
fn scopedRequire(l: ?*LuaState) callconv(.c) c_int {
    const L = l.?;
    const vm: *Vm = @ptrCast(@alignCast(c.lua_touserdata(L, upvalueIndex(1)).?));
    var nlen: usize = 0;
    const name_p = c.lua_tolstring(L, 1, &nlen) orelse {
        _ = c.lua_pushstring(L, "require: module name must be a string");
        return c.lua_error(L);
    };
    const name = name_p[0..nlen];
    // cache hit?
    c.lua_pushvalue(L, 1);
    if (c.lua_gettable(L, upvalueIndex(2)) != TNIL) return 1;
    pop(L, 1);
    // validate: dotted identifiers only — no separators, no traversal
    if (name.len == 0 or name.len > 128) {
        _ = c.lua_pushstring(L, "require: bad module name");
        return c.lua_error(L);
    }
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '.';
        if (!ok) {
            _ = c.lua_pushstring(L, "require: module names may only contain [A-Za-z0-9_.]");
            return c.lua_error(L);
        }
    }
    const root = vm.root_dir orelse {
        _ = c.lua_pushstring(L, "require: no plugin root configured");
        return c.lua_error(L);
    };
    // name.with.dots -> name/with/dots.lua under root
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.lua", .{ root, name }) catch {
        _ = c.lua_pushstring(L, "require: module path too long");
        return c.lua_error(L);
    };
    for (path[root.len .. path.len - 4]) |*ch| {
        if (ch.* == '.') ch.* = '/';
    }
    const src = readSmallFile(vm.io, vm.gpa, path, 2 << 20) catch {
        var msg_buf: [640]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "require: module '{s}' not found in plugin dir", .{name}) catch "require: module not found";
        _ = c.lua_pushstring(L, msg.ptr);
        return c.lua_error(L);
    };
    var cname_buf: [160]u8 = undefined;
    const cname = std.fmt.bufPrintZ(&cname_buf, "@{s}.lua", .{name}) catch "@module";
    const rc = c.luaL_loadbufferx(L, src.ptr, src.len, cname.ptr, "t");
    vm.gpa.free(src); // freed BEFORE any lua_error can longjmp past us
    if (rc != OK) return c.lua_error(L); // compile error message already on the stack
    c.lua_callk(L, 0, 1, 0, null); // errors propagate to the surrounding pcall
    if (c.lua_type(L, -1) == TNIL) {
        pop(L, 1);
        c.lua_pushboolean(L, 1); // stock require semantics: nil result caches as true
    }
    c.lua_pushvalue(L, 1);
    c.lua_pushvalue(L, -2);
    c.lua_settable(L, upvalueIndex(2));
    return 1;
}

/// Read a whole small file (bounded).
pub fn readSmallFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max));
}

// ---------------------------------------------------------------------------------------------
// JSON <-> Lua (used by the MCP bridge and veil.json_* helpers)
// ---------------------------------------------------------------------------------------------

/// Push a std.json.Value onto the Lua stack (objects/arrays become tables).
pub fn pushJson(L: *LuaState, v: std.json.Value) void {
    switch (v) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, @intFromBool(b)),
        .integer => |i| c.lua_pushinteger(L, i),
        .float => |f| c.lua_pushnumber(L, f),
        .number_string => |s| pushSlice(L, s),
        .string => |s| pushSlice(L, s),
        .array => |arr| {
            c.lua_createtable(L, @intCast(arr.items.len), 0);
            for (arr.items, 1..) |item, i| {
                pushJson(L, item);
                c.lua_rawseti(L, -2, @intCast(i));
            }
        },
        .object => |obj| {
            c.lua_createtable(L, 0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |e| {
                pushSlice(L, e.key_ptr.*);
                pushJson(L, e.value_ptr.*);
                c.lua_settable(L, -3);
            }
        },
    }
}

/// Convert the Lua value at `idx` into a std.json.Value tree allocated in `arena`.
/// Tables with only 1..n integer keys become arrays; everything else becomes an object with
/// stringified keys. Depth-capped so a cyclic table can't recurse forever.
pub fn luaToJson(arena: std.mem.Allocator, L: *LuaState, idx: c_int, depth: u32) error{ OutOfMemory, TooDeep }!std.json.Value {
    if (depth > 24) return error.TooDeep;
    const abs = c.lua_absindex(L, idx);
    switch (c.lua_type(L, abs)) {
        TNIL, TNONE => return .null,
        TBOOLEAN => return .{ .bool = c.lua_toboolean(L, abs) != 0 },
        TNUMBER => {
            if (c.lua_isinteger(L, abs) != 0) return .{ .integer = c.lua_tointegerx(L, abs, null) };
            return .{ .float = c.lua_tonumberx(L, abs, null) };
        },
        TSTRING => {
            const s = toString(L, abs).?;
            return .{ .string = try arena.dupe(u8, s) };
        },
        TTABLE => {
            const n: usize = @intCast(c.lua_rawlen(L, abs));
            // array shape? every key must be an integer in 1..n
            var is_array = true;
            var count: usize = 0;
            c.lua_pushnil(L);
            while (c.lua_next(L, abs) != 0) {
                count += 1;
                if (c.lua_isinteger(L, -2) == 0) {
                    is_array = false;
                } else {
                    const k = c.lua_tointegerx(L, -2, null);
                    if (k < 1 or k > @as(Integer, @intCast(n))) is_array = false;
                }
                pop(L, 1);
            }
            if (is_array and count == n) {
                var arr = std.json.Array.init(arena);
                try arr.ensureTotalCapacity(n);
                var i: Integer = 1;
                while (i <= n) : (i += 1) {
                    _ = c.lua_rawgeti(L, abs, i);
                    const item = try luaToJson(arena, L, -1, depth + 1);
                    pop(L, 1);
                    arr.appendAssumeCapacity(item);
                }
                return .{ .array = arr };
            }
            var obj: std.json.ObjectMap = .empty;
            c.lua_pushnil(L);
            while (c.lua_next(L, abs) != 0) {
                // key: stringify a COPY (lua_tolstring on the raw key would confuse lua_next)
                c.lua_pushvalue(L, -2);
                const ks = c.luaL_tolstring(L, -1, null);
                const key = try arena.dupe(u8, std.mem.span(ks));
                pop(L, 2); // tolstring result + key copy
                const val = luaToJson(arena, L, -1, depth + 1) catch |e| switch (e) {
                    error.TooDeep => std.json.Value{ .string = "<too deep>" },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                try obj.put(arena, key, val);
                pop(L, 1);
            }
            return .{ .object = obj };
        },
        else => return .{ .string = "<function>" },
    }
}

// ---------------------------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------------------------

/// Test-only io: every fs-touching std API in 0.16 wants one.
fn testIo(threaded: *std.Io.Threaded) std.Io {
    return threaded.io();
}

test "sandbox: run a chunk, read fields, stdlib whitelist holds" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const vm = try Vm.init(std.testing.allocator, testIo(&threaded), .{});
    defer vm.deinit();
    vm.openSandboxedLibs();
    try vm.runBuffer(
        \\local t = { name = "demo", ok = true, n = 42 }
        \\t.upper = string.upper("veil")
        \\t.has_io = (io ~= nil)
        \\t.has_debug = (debug ~= nil)
        \\t.has_exec = (os.execute ~= nil)
        \\t.has_time = (os.time ~= nil)
        \\t.has_dofile = (dofile ~= nil)
        \\return t
    , "=test", 1);
    try std.testing.expectEqual(TTABLE, c.lua_type(vm.L, -1));
    const name = try vm.fieldStringDup(-1, "name", std.testing.allocator);
    defer std.testing.allocator.free(name.?);
    try std.testing.expectEqualStrings("demo", name.?);
    const upper = try vm.fieldStringDup(-1, "upper", std.testing.allocator);
    defer std.testing.allocator.free(upper.?);
    try std.testing.expectEqualStrings("VEIL", upper.?);
    try std.testing.expectEqual(@as(Integer, 42), vm.fieldInt(-1, "n", 0));
    try std.testing.expect(vm.fieldBool(-1, "ok", false));
    try std.testing.expect(!vm.fieldBool(-1, "has_io", true));
    try std.testing.expect(!vm.fieldBool(-1, "has_debug", true));
    try std.testing.expect(!vm.fieldBool(-1, "has_exec", true));
    try std.testing.expect(vm.fieldBool(-1, "has_time", false));
    try std.testing.expect(!vm.fieldBool(-1, "has_dofile", true));
    pop(vm.L, 1);
}

test "sandbox: instruction budget stops a runaway loop" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const vm = try Vm.init(std.testing.allocator, testIo(&threaded), .{ .instr_budget = 200_000 });
    defer vm.deinit();
    vm.openSandboxedLibs();
    const r = vm.runBuffer("while true do end", "=spin", 0);
    try std.testing.expectError(error.LuaRuntime, r);
    try std.testing.expect(std.mem.indexOf(u8, vm.lastError(), "instruction budget") != null);
}

test "sandbox: memory cap stops a string bomb" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const vm = try Vm.init(std.testing.allocator, testIo(&threaded), .{ .mem_cap_bytes = 2 << 20 });
    defer vm.deinit();
    vm.openSandboxedLibs();
    const r = vm.runBuffer(
        \\local s = "xxxxxxxxxxxxxxxx"
        \\for i = 1, 40 do s = s .. s end
        \\return #s
    , "=bomb", 1);
    try std.testing.expectError(error.LuaRuntime, r);
}

test "sandbox: load() refuses bytecode and non-strings" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const vm = try Vm.init(std.testing.allocator, testIo(&threaded), .{});
    defer vm.deinit();
    vm.openSandboxedLibs();
    try vm.runBuffer(
        \\local f, err = load("\27Lua bytecode here")
        \\local g = load(function() return nil end)
        \\return { text_err = (f == nil), fn_refused = (g == nil) }
    , "=loads", 1);
    try std.testing.expect(vm.fieldBool(-1, "text_err", false));
    try std.testing.expect(vm.fieldBool(-1, "fn_refused", false));
    pop(vm.L, 1);
}

test "json bridge: lua table -> json -> lua roundtrip shapes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const vm = try Vm.init(std.testing.allocator, testIo(&threaded), .{});
    defer vm.deinit();
    vm.openSandboxedLibs();
    try vm.runBuffer(
        \\return { list = {1, 2, 3}, obj = { a = "x", b = true }, n = 7.5 }
    , "=json", 1);
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const v = try luaToJson(arena_impl.allocator(), vm.L, -1, 0);
    pop(vm.L, 1);
    try std.testing.expect(v == .object);
    const list = v.object.get("list").?;
    try std.testing.expect(list == .array);
    try std.testing.expectEqual(@as(usize, 3), list.array.items.len);
    const obj = v.object.get("obj").?;
    try std.testing.expectEqualStrings("x", obj.object.get("a").?.string);
    // and back up
    pushJson(vm.L, v);
    try std.testing.expectEqual(TTABLE, c.lua_type(vm.L, -1));
    const n = vm.fieldInt(-1, "n", 0);
    _ = n;
    pop(vm.L, 1);
}
