//! builtin.zig — shared state + contracts for the BUILT-IN model engine (the plug-and-play tier).
//!
//! The server can serve the-veil-12b itself, in-process, from a GGUF weights file on disk — no
//! separate local model runtime to install. This module is the C-free heart of that feature, the
//! one file every other participant imports:
//!
//!   * the catalog's `builtin` provider carries the SENTINEL base ("builtin"); deploy/chat
//!     resolution swaps it for the live loopback engine endpoint minted here (same server-side
//!     trick as the "cloudflare" sentinel in deploy/service.zig)
//!   * worker/builtin_endpoint.zig serves that endpoint over 127.0.0.1 (worker subprocesses are
//!     separate PROCESSES, so the engine must be reachable over loopback TCP, not a function call)
//!   * worker/llamaeng.zig implements the `Engine` interface with the embedded inference library
//!     (only in -Dbuiltin builds); tests implement it with a mock — which is why the interface
//!     lives HERE, C-free, and not beside the FFI
//!   * worker/modelpull.zig fills the weights store this module describes
//!
//! The endpoint is boot-secret gated: every request carries the per-boot bearer minted here, so
//! the engine port is never the open-to-any-local-process surface a conventional local runtime is.
//!
//! init(io, …) must run before any accessor that locks — main boots it right after the data root
//! exists, and every test below does the same against a throwaway root.

const std = @import("std");

/// The catalog provider key AND its sentinel base URL. models.yaml's builtin provider says
/// `base: builtin`; resolution replaces it with the live loopback base at request time.
pub const SENTINEL = "builtin";
/// Every endpoint route lives under this path prefix, and the llm client recognizes the marker in
/// a base URL as "speaks the native local dialect" (llm.zig isOllama) — no port assumptions.
pub const PATH_PREFIX = "/builtin";
/// The one model the built-in engine serves.
pub const MODEL_ID = "the-veil-12b";
/// Where the weights live when the user has not published/downloaded anything custom.
pub const HF_REPO = "gary23w/the-veil-12b";

// ---- the engine interface (implemented by llamaeng.zig; mocked in tests) -------------------------

pub const GenReq = struct {
    prompt: []const u8,
    n_predict: u32 = 2048,
    /// < 0 = engine default sampling; 0 = greedy/deterministic; > 0 = that temperature.
    temp: f32 = -1,
    /// (0,1) = nucleus cutoff; anything else = none.
    top_p: f32 = 0,
    stops: []const []const u8 = &.{},
    /// Streaming sink: raw generated text pieces, stop-sequences already withheld. Return false to
    /// abort the generation (client hung up). null = collect only.
    sink_ctx: ?*anyopaque = null,
    on_piece: ?*const fn (ctx: *anyopaque, piece: []const u8) bool = null,
};

pub const GenRes = struct {
    /// Final text, stop sequence stripped. Owned by the caller.
    text: []u8,
    prompt_tokens: u64 = 0,
    gen_tokens: u64 = 0,
    /// Generation hit n_predict (maps to done_reason "length").
    truncated: bool = false,
};

pub const EngState = enum { absent, cold, loading, ready, failed };

pub const Info = struct {
    state: EngState = .absent,
    arch: [48]u8 = @splat(0),
    arch_len: u8 = 0,
    params_b: u32 = 0,
    /// The window the engine actually SERVES (its context allocation), not the model's trained max.
    /// /api/show reports this so the client never requests a window the engine cannot hold.
    ctx_serving: u32 = 0,
    err: [192]u8 = @splat(0),
    err_len: u8 = 0,

    pub fn archName(self: *const Info) []const u8 {
        return self.arch[0..self.arch_len];
    }
    pub fn errMsg(self: *const Info) []const u8 {
        return self.err[0..self.err_len];
    }
};

pub const Engine = struct {
    ctx: *anyopaque,
    generate: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, req: GenReq) anyerror!GenRes,
    info: *const fn (ctx: *anyopaque) Info,
};

// ---- live state -----------------------------------------------------------------------------------

/// Everything the resolution choke points and the status route need, mutex-guarded because chat
/// turns, deploys and the status poller read it from different threads while a pull updates it.
const St = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io = undefined,
    ready: bool = false, // init() ran: io is valid, locking is legal
    /// 0 = endpoint not running (server built without -Dbuiltin, or bind failed).
    port: u16 = 0,
    secret: [32]u8 = @splat(0), // hex chars; fixed width, minted once per boot
    secret_len: u8 = 0,
    /// Absolute path of the weights file serving MODEL_ID, empty = no weights on disk yet.
    model_path: [512]u8 = @splat(0),
    model_path_len: u16 = 0,
    /// The models directory (resolved once at init).
    dir: [512]u8 = @splat(0),
    dir_len: u16 = 0,
    /// Set when the models dir looks cloud-synced — surfaced in status so the operator can move it.
    synced_dir_warning: bool = false,
};
var st: St = .{};

fn lock() void {
    st.mutex.lockUncancelable(st.io);
}
fn unlock() void {
    st.mutex.unlock(st.io);
}

/// Mint the per-boot bearer. Uniqueness/unguessability from the same construction the call-id mint
/// uses (llm.zig mintCallId): an ASLR-salted splitmix64 walk — std.crypto.random is absent in this
/// Zig, and this needs to beat "any local process can dial the port", not a nation state.
fn mintSecret() void {
    var z: u64 = @intFromPtr(&st) ^ 0x9E3779B97F4A7C15;
    var i: usize = 0;
    while (i < st.secret.len) : (i += 8) {
        z ^= @as(u64, @intFromPtr(&i)) +% (z << 7);
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        const hex = "0123456789abcdef";
        var v = z;
        var j: usize = 0;
        while (j < 8 and i + j < st.secret.len) : (j += 1) {
            st.secret[i + j] = hex[@intCast(v & 0xf)];
            v >>= 4;
        }
    }
    st.secret_len = st.secret.len;
}

/// Resolve the models directory and scan it for already-present weights. Called once at boot,
/// BEFORE the endpoint starts and before any other accessor. `data` is the server data root;
/// NL_MODELS_DIR overrides — the weights are multi-GB and a data root inside a cloud-synced folder
/// (OneDrive/Dropbox) would sync-churn them forever, so the override (and the warning) exist from
/// day one.
pub fn init(io: std.Io, environ: *const std.process.Environ.Map, data: []const u8) void {
    st.io = io;
    st.ready = true;
    lock();
    defer unlock();
    // NL_BUILTIN_SECRET pins the bearer (compose files, cross-process smoke drivers); otherwise a
    // fresh one is minted per boot. Pinning trades rotation for scriptability — operator's call.
    if (environ.get("NL_BUILTIN_SECRET")) |s| {
        const t = std.mem.trim(u8, s, " \r\n\t");
        if (t.len >= 8) {
            st.secret_len = @intCast(@min(t.len, st.secret.len));
            @memcpy(st.secret[0..st.secret_len], t[0..st.secret_len]);
        }
    }
    if (st.secret_len == 0) mintSecret();

    var buf: [512]u8 = undefined;
    const dir: []const u8 = blk: {
        if (environ.get("NL_MODELS_DIR")) |d| {
            const t = std.mem.trim(u8, d, " \r\n\t");
            if (t.len > 0 and t.len <= buf.len) break :blk t;
        }
        break :blk std.fmt.bufPrint(&buf, "{s}/models", .{data}) catch return;
    };
    st.dir_len = @intCast(@min(dir.len, st.dir.len));
    @memcpy(st.dir[0..st.dir_len], dir[0..st.dir_len]);
    st.synced_dir_warning = std.ascii.indexOfIgnoreCase(dir, "onedrive") != null or
        std.ascii.indexOfIgnoreCase(dir, "dropbox") != null;

    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    scanLocked(io);
}

/// Re-scan the models dir for a serving-ready GGUF (after a pull/import/delete). Preference order:
/// a file whose name contains MODEL_ID, else the lexically-first .gguf — deterministic, so two
/// scans of the same dir always elect the same file.
pub fn rescan(io: std.Io) void {
    lock();
    defer unlock();
    scanLocked(io);
}

fn scanLocked(io: std.Io) void {
    st.model_path_len = 0;
    const dir_path = st.dir[0..st.dir_len];
    if (dir_path.len == 0) return;
    var d = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer d.close(io);
    var best: [256]u8 = undefined;
    var best_len: usize = 0;
    var best_named = false;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(e.name, ".gguf")) continue;
        if (e.name.len > best.len) continue;
        const named = std.ascii.indexOfIgnoreCase(e.name, MODEL_ID) != null;
        const better = best_len == 0 or
            (named and !best_named) or
            (named == best_named and std.mem.lessThan(u8, e.name, best[0..best_len]));
        if (better) {
            @memcpy(best[0..e.name.len], e.name);
            best_len = e.name.len;
            best_named = named;
        }
    }
    if (best_len == 0) return;
    const full = std.fmt.bufPrint(st.model_path[0..], "{s}/{s}", .{ dir_path, best[0..best_len] }) catch return;
    st.model_path_len = @intCast(full.len);
}

/// The endpoint reports in once it is listening (and reports out if its listener dies).
pub fn setPort(p: u16) void {
    lock();
    defer unlock();
    st.port = p;
}

pub fn port() u16 {
    lock();
    defer unlock();
    return st.port;
}

pub fn secret() []const u8 {
    lock();
    defer unlock();
    return st.secret[0..st.secret_len]; // fixed storage: the slice stays valid after unlock
}

pub fn modelsDir() []const u8 {
    lock();
    defer unlock();
    return st.dir[0..st.dir_len];
}

/// Absolute path of the weights file, or null when none is on disk. Fixed storage — the returned
/// slice is only invalidated by a rescan electing a DIFFERENT file, which callers tolerate by
/// copying before long holds.
pub fn modelPath() ?[]const u8 {
    lock();
    defer unlock();
    if (st.model_path_len == 0) return null;
    return st.model_path[0..st.model_path_len];
}

pub fn syncedDirWarning() bool {
    lock();
    defer unlock();
    return st.synced_dir_warning;
}

/// Is this base URL the catalog sentinel? (Exact match — a real URL is never "builtin".)
/// Lock-free on purpose: resolution sites ask this about EVERY base, including before init.
pub fn isSentinelBase(base_url: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, base_url, " \r\n\t"), SENTINEL);
}

pub const Resolved = struct { base: []u8, key: []const u8 };

/// Swap the sentinel for the LIVE endpoint base + per-boot bearer. Null when the endpoint is not
/// running — the caller owns the user-facing error ("server built without the built-in engine").
/// `arena` owns the base string (request-scoped, like every other resolution product).
pub fn resolve(arena: std.mem.Allocator) ?Resolved {
    if (!st.ready) return null; // a build/boot with no builtin never initialized this module
    lock();
    defer unlock();
    if (st.port == 0 or st.secret_len == 0) return null;
    const base = std.fmt.allocPrint(arena, "http://127.0.0.1:{d}" ++ PATH_PREFIX ++ "/v1", .{st.port}) catch return null;
    return .{ .base = base, .key = st.secret[0..st.secret_len] };
}

// ---- tests ---------------------------------------------------------------------------------------

test "sentinel detection is exact: real URLs and prefixed strings never match" {
    try std.testing.expect(isSentinelBase("builtin"));
    try std.testing.expect(isSentinelBase("  builtin\r\n"));
    try std.testing.expect(!isSentinelBase("http://127.0.0.1:8788/builtin/v1"));
    try std.testing.expect(!isSentinelBase("builtin2"));
    try std.testing.expect(!isSentinelBase(""));
}

test "resolve mints the loopback base with the path marker and the boot secret; not-running resolves null" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = "zig-builtin-resolve-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    init(io, &env, root);

    // not running → null (the server-without-engine case a caller must handle)
    setPort(0);
    try std.testing.expect(resolve(arena) == null);

    setPort(8788);
    defer setPort(0); // this module is process-global state — leave it as found
    const r = resolve(arena).?;
    try std.testing.expectEqualStrings("http://127.0.0.1:8788" ++ PATH_PREFIX ++ "/v1", r.base);
    try std.testing.expect(r.key.len == st.secret.len); // full-width hex bearer
}

test "scan elects deterministically: a model-id-named gguf beats other ggufs, lexical order breaks ties" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-builtin-scan-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};

    // init() derives {data}/models — write the candidates there
    const mdir = root ++ "/models";
    _ = std.Io.Dir.cwd().createDirPathStatus(io, mdir, .default_dir) catch {};
    for ([_][]const u8{ "zeta.gguf", "alpha.gguf", "the-veil-12b-q4_k_m.gguf", "readme.txt" }) |n| {
        var fbuf: [128]u8 = undefined;
        const fp = try std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ mdir, n });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fp, .data = "x" });
    }

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    init(io, &env, root);
    const p = modelPath() orelse return error.TestExpectedModel;
    try std.testing.expect(std.mem.endsWith(u8, p, "the-veil-12b-q4_k_m.gguf"));

    // remove the named file → lexical winner among the rest
    std.Io.Dir.cwd().deleteFile(io, mdir ++ "/the-veil-12b-q4_k_m.gguf") catch {};
    rescan(io);
    const p2 = modelPath() orelse return error.TestExpectedModel;
    try std.testing.expect(std.mem.endsWith(u8, p2, "alpha.gguf"));
}
