//! llamaeng.zig — the embedded inference engine behind the built-in model (FFI side).
//!
//! Implements builtin.Engine over the veil_ll_* C facade (src/worker/llamashim.c), which is the
//! ONLY ffi surface: scalars and pointers, no by-value structs (see the shim header for why).
//! Compiled sources for the inference library exist only in -Dbuiltin builds; this file always
//! PARSES, but its externs resolve lazily, so nothing may reference them unless
//! build_options.builtin is true (main.zig gates the one construction site).
//!
//! Design points, in the order they matter:
//!   * ONE model, ONE context, single-flight: `generate` holds the engine mutex for the whole
//!     inference. Concurrent callers queue on the mutex — the same behavior a busy local runtime
//!     gives them, minus a request queue to misbehave.
//!   * PREFIX REUSE: chat resends the whole rendered conversation every turn; re-prefilling it on
//!     a CPU would cost tens of seconds per turn. The engine keeps the token vector currently in
//!     kv memory, finds the longest common prefix with the new prompt, drops only the divergent
//!     tail (veil_ll_seq_rm) and decodes the suffix. Worst case (no overlap) is exactly the naive
//!     cost; the steady-state chat turn re-evaluates only its newest messages.
//!   * LAZY LOAD + IDLE UNLOAD: the first request pays the model load; an unloader thread returns
//!     the ~7GB working set to the OS after NL_BUILTIN_KEEPALIVE seconds (default 300) of quiet.
//!   * NO TESTS HERE: everything reachable without weights lives in builtin.zig /
//!     builtin_endpoint.zig and is tested there against a mock Engine; a test block in this file
//!     would drag unresolved externs into every `zig build test`.

const std = @import("std");
const builtin_mod = @import("builtin.zig");

const Model = opaque {};
const Ctx = opaque {};
const Vocab = opaque {};
const Sampler = opaque {};

extern fn veil_ll_backend_init() void;
extern fn veil_ll_log_quiet() void;
extern fn veil_ll_load(path: [*:0]const u8) ?*Model;
extern fn veil_ll_load_meta(path: [*:0]const u8) ?*Model;
extern fn veil_ll_model_free(m: *Model) void;
extern fn veil_ll_ctx_new(m: *Model, n_ctx: u32, n_batch: u32, n_threads: i32) ?*Ctx;
extern fn veil_ll_ctx_free(c: *Ctx) void;
extern fn veil_ll_vocab(m: *const Model) *const Vocab;
extern fn veil_ll_tokenize(v: *const Vocab, text: [*]const u8, len: i32, toks: [*]i32, cap: i32, add_special: bool, parse_special: bool) i32;
extern fn veil_ll_decode(c: *Ctx, toks: [*]i32, n: i32) i32;
extern fn veil_ll_mem_clear(c: *Ctx) void;
extern fn veil_ll_seq_rm(c: *Ctx, p0: i32, p1: i32) bool;
extern fn veil_ll_sampler_new(temp: f32, top_p: f32, seed: u32) ?*Sampler;
extern fn veil_ll_sampler_free(s: *Sampler) void;
extern fn veil_ll_sample(s: *Sampler, c: *Ctx) i32;
extern fn veil_ll_is_eog(v: *const Vocab, t: i32) bool;
extern fn veil_ll_piece(v: *const Vocab, t: i32, buf: [*]u8, cap: i32) i32;
extern fn veil_ll_n_ctx_train(m: *const Model) i32;
extern fn veil_ll_n_params(m: *const Model) u64;
extern fn veil_ll_meta(m: *const Model, key: [*:0]const u8, buf: [*]u8, cap: usize) i32;

const log = std.log.scoped(.llamaeng);

/// Default sampling when the request pins nothing — the conventional local-model defaults, so the
/// builtin backend behaves like the other local backends the engine already knows how to drive.
const DEFAULT_TEMP: f32 = 0.8;
const DEFAULT_TOP_P: f32 = 0.95;
const N_BATCH: u32 = 512;

const G = struct {
    mutex: std.Io.Mutex = .init,
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    configured: bool = false,
    model: ?*Model = null,
    ctx: ?*Ctx = null,
    path: [512]u8 = @splat(0),
    path_len: u16 = 0,
    n_ctx: u32 = 8192,
    n_threads: i32 = 0,
    keepalive_s: i64 = 300,
    /// Token vector currently materialized in kv memory (prompt + generated), for prefix reuse.
    kv_toks: std.ArrayListUnmanaged(i32) = .empty,
    last_used_s: i64 = 0,
    /// Filled by the cheap metadata probe at configure() so /api/show answers before any full load.
    meta: builtin_mod.Info = .{},
    load_failed: bool = false,
    seed_seq: u32 = 1,
    unloader_up: bool = false,
    backend_up: bool = false,
};
var g: G = .{};

fn lock() void {
    g.mutex.lockUncancelable(g.io);
}
fn unlock() void {
    g.mutex.unlock(g.io);
}

fn nowS(io: std.Io) i64 {
    return @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
}

/// Point the engine at a weights file (or at nothing). Called at boot and again after a
/// pull/import/delete changes the store. Cheap: full model load stays lazy; only the metadata
/// probe (vocab-only) runs here.
pub fn configure(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, path: ?[]const u8) void {
    g.io = io; // before the first lock — the mutex parks on this io
    lock();
    defer unlock();
    g.gpa = gpa;
    g.configured = true;
    if (environ.get("NL_BUILTIN_CTX")) |v| {
        if (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            if (n >= 1024) g.n_ctx = @min(n, 131072);
        } else |_| {}
    }
    if (environ.get("NL_BUILTIN_THREADS")) |v| {
        if (std.fmt.parseInt(i32, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            if (n > 0) g.n_threads = @min(n, 64);
        } else |_| {}
    }
    if (g.n_threads == 0) {
        // logical/2 ≈ physical cores — the sweet spot for this workload; hyperthreads only add
        // contention on the shared FMA units. Floor 4 so small boxes still parallelize.
        const cpus: i32 = @intCast(std.Thread.getCpuCount() catch 8);
        g.n_threads = @max(4, @min(@divTrunc(cpus, 2), 16));
    }
    if (environ.get("NL_BUILTIN_KEEPALIVE")) |v| {
        if (std.fmt.parseInt(i64, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            if (n >= 30) g.keepalive_s = n;
        } else |_| {}
    }

    const new_path = path orelse "";
    const cur = g.path[0..g.path_len];
    const changed = !std.mem.eql(u8, cur, new_path);
    if (changed) {
        unloadLocked();
        g.load_failed = false;
        g.meta = .{};
        g.path_len = @intCast(@min(new_path.len, g.path.len));
        @memcpy(g.path[0..g.path_len], new_path[0..g.path_len]);
    }
    if (g.path_len > 0 and g.meta.arch_len == 0 and !g.load_failed) metaProbeLocked();

    if (!g.unloader_up) {
        g.unloader_up = true;
        const t = std.Thread.spawn(.{}, unloaderLoop, .{}) catch blk: {
            g.unloader_up = false;
            break :blk null;
        };
        if (t) |th| th.detach();
    }
}

/// Re-point at a (possibly different) weights file after the store changed — configure() minus the
/// env re-read, safe from any thread (the pull thread calls it via modelpull.on_store_change).
/// A SAME-path repoint is what an in-place update produces: the bytes changed under the name, so
/// when the engine is unloaded and the meta was cleared (unload()), re-probe rather than no-op.
pub fn repoint(path: ?[]const u8) void {
    if (!g.configured) return;
    lock();
    defer unlock();
    const new_path = path orelse "";
    const cur = g.path[0..g.path_len];
    if (std.mem.eql(u8, cur, new_path)) {
        if (g.path_len > 0 and g.ctx == null and g.meta.arch_len == 0 and !g.load_failed) metaProbeLocked();
        return;
    }
    unloadLocked();
    g.load_failed = false;
    g.meta = .{};
    g.path_len = @intCast(@min(new_path.len, g.path.len));
    @memcpy(g.path[0..g.path_len], new_path[0..g.path_len]);
    if (g.path_len > 0) metaProbeLocked();
}

/// Drop the loaded weights and the cached meta, WAITING OUT any in-flight generation (same mutex).
/// The store calls this via modelpull.on_before_swap right before it replaces or removes the
/// serving file — Windows refuses to touch a file the engine still maps. The meta clears too: the
/// bytes under the path are about to change, so what was probed is about to be a lie; the
/// store-change repoint afterwards re-probes whatever actually landed.
pub fn unload() void {
    if (!g.configured) return;
    lock();
    defer unlock();
    unloadLocked();
    g.load_failed = false;
    g.meta = .{};
}

fn ensureBackendLocked() void {
    if (g.backend_up) return;
    veil_ll_log_quiet();
    veil_ll_backend_init();
    g.backend_up = true;
}

fn setErrLocked(msg: []const u8) void {
    const n = @min(msg.len, g.meta.err.len);
    @memcpy(g.meta.err[0..n], msg[0..n]);
    g.meta.err_len = @intCast(n);
}

/// Vocab-only load: arch + param count without touching the weight tensors. ~100ms on a 7GB file.
fn metaProbeLocked() void {
    ensureBackendLocked();
    var zbuf: [513]u8 = undefined;
    const p = pathZLocked(&zbuf) orelse return;
    const m = veil_ll_load_meta(p) orelse {
        g.load_failed = true;
        setErrLocked("weights file exists but could not be read as a model");
        return;
    };
    defer veil_ll_model_free(m);
    var abuf: [128]u8 = undefined;
    const an = veil_ll_meta(m, "general.architecture", &abuf, abuf.len);
    if (an > 0) {
        const n = @min(@as(usize, @intCast(an)), g.meta.arch.len);
        @memcpy(g.meta.arch[0..n], abuf[0..n]);
        g.meta.arch_len = @intCast(n);
    }
    g.meta.params_b = @intCast((veil_ll_n_params(m) + 500_000_000) / 1_000_000_000);
}

fn pathZLocked(buf: []u8) ?[*:0]const u8 {
    if (g.path_len == 0 or g.path_len + 1 > buf.len) return null;
    @memcpy(buf[0..g.path_len], g.path[0..g.path_len]);
    buf[g.path_len] = 0;
    return @ptrCast(buf[0..g.path_len :0].ptr);
}

fn ensureLoadedLocked() ![]const u8 {
    if (g.ctx != null) return "";
    if (g.path_len == 0) return error.NoWeights;
    ensureBackendLocked();
    var zbuf: [513]u8 = undefined;
    const p = pathZLocked(&zbuf) orelse return error.NoWeights;
    const t0 = nowS(g.io);
    const m = veil_ll_load(p) orelse {
        g.load_failed = true;
        setErrLocked("model load failed (corrupt file, unsupported quant, or out of memory)");
        return error.LoadFailed;
    };
    const c = veil_ll_ctx_new(m, g.n_ctx, N_BATCH, g.n_threads) orelse {
        veil_ll_model_free(m);
        g.load_failed = true;
        setErrLocked("context allocation failed (not enough memory for the kv window)");
        return error.LoadFailed;
    };
    g.model = m;
    g.ctx = c;
    g.kv_toks.clearRetainingCapacity();
    log.info("model loaded in {d}s (ctx={d} threads={d})", .{ nowS(g.io) - t0, g.n_ctx, g.n_threads });
    return "";
}

fn unloadLocked() void {
    if (g.ctx) |c| veil_ll_ctx_free(c);
    if (g.model) |m| veil_ll_model_free(m);
    g.ctx = null;
    g.model = null;
    g.kv_toks.clearRetainingCapacity();
}

fn unloaderLoop() void {
    while (true) {
        g.io.sleep(.{ .nanoseconds = 60 * std.time.ns_per_s }, .awake) catch {};
        lock();
        const idle = g.ctx != null and g.last_used_s > 0 and nowS(g.io) - g.last_used_s > g.keepalive_s;
        if (idle) {
            unloadLocked();
            log.info("model unloaded after {d}s idle", .{g.keepalive_s});
        }
        unlock();
    }
}

pub fn info() builtin_mod.Info {
    if (!g.configured) return .{};
    lock();
    defer unlock();
    var out = g.meta;
    out.ctx_serving = g.n_ctx;
    out.state = if (g.path_len == 0)
        .absent
    else if (g.load_failed)
        .failed
    else if (g.ctx != null)
        .ready
    else
        .cold;
    return out;
}

fn vtInfo(_: *anyopaque) builtin_mod.Info {
    return info();
}

fn vtGenerate(_: *anyopaque, gpa: std.mem.Allocator, req: builtin_mod.GenReq) anyerror!builtin_mod.GenRes {
    return generate(gpa, req);
}

var vt_ctx: u8 = 0;

pub fn engine() builtin_mod.Engine {
    return .{ .ctx = @ptrCast(&vt_ctx), .generate = vtGenerate, .info = vtInfo };
}

/// One full generation under the engine mutex. See the module header for the prefix-reuse and
/// stop-withholding contracts; the sink receives raw text with stop sequences never leaked.
pub fn generate(gpa: std.mem.Allocator, req: builtin_mod.GenReq) !builtin_mod.GenRes {
    if (!g.configured) return error.NoWeights;
    lock();
    defer unlock();
    _ = try ensureLoadedLocked();
    g.last_used_s = nowS(g.io);
    defer g.last_used_s = nowS(g.io);

    const ctx = g.ctx.?;
    const vocab = veil_ll_vocab(g.model.?);

    // ---- tokenize (specials parsed: the rendered prompt carries the wire-format tokens) ----
    const cap: i32 = @intCast(g.n_ctx);
    const toks = try gpa.alloc(i32, g.n_ctx);
    defer gpa.free(toks);
    const n_tok = veil_ll_tokenize(vocab, req.prompt.ptr, @intCast(req.prompt.len), toks.ptr, cap, false, true);
    if (n_tok <= 0) return error.PromptTooLong; // negative = needed size exceeds the serving window
    const prompt_toks = toks[0..@intCast(n_tok)];
    // leave real room to answer: a prompt that fills the window would generate nothing useful
    if (prompt_toks.len + 16 > g.n_ctx) return error.PromptTooLong;

    // ---- prefix reuse ----
    var common: usize = 0;
    const kv = g.kv_toks.items;
    while (common < kv.len and common < prompt_toks.len and kv[common] == prompt_toks[common]) common += 1;
    // the final prompt token must be DECODED this call so its logits exist to sample from
    if (common == prompt_toks.len) common -= 1;
    if (common < kv.len) {
        if (!veil_ll_seq_rm(ctx, @intCast(common), -1)) {
            veil_ll_mem_clear(ctx);
            common = 0;
        }
    }
    g.kv_toks.clearRetainingCapacity();
    g.kv_toks.appendSlice(g.gpa, prompt_toks) catch {};

    // ---- prefill the divergent suffix in batch-sized chunks ----
    var at: usize = common;
    while (at < prompt_toks.len) {
        const n: usize = @min(N_BATCH, prompt_toks.len - at);
        if (veil_ll_decode(ctx, prompt_toks.ptr + at, @intCast(n)) != 0) {
            veil_ll_mem_clear(ctx);
            g.kv_toks.clearRetainingCapacity();
            return error.DecodeFailed;
        }
        at += n;
    }

    // ---- sampler ----
    g.seed_seq +%= 1;
    const temp: f32 = if (req.temp < 0) DEFAULT_TEMP else req.temp;
    const top_p: f32 = if (req.temp < 0) DEFAULT_TOP_P else req.top_p;
    const smpl = veil_ll_sampler_new(temp, top_p, g.seed_seq ^ @as(u32, @truncate(@as(u64, @intFromPtr(&g))))) orelse return error.DecodeFailed;
    defer veil_ll_sampler_free(smpl);

    // ---- decode loop with stop withholding ----
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(gpa);
    var max_stop: usize = 0;
    for (req.stops) |s| max_stop = @max(max_stop, s.len);
    var emitted: usize = 0; // bytes of `text` already handed to the sink
    var produced: u64 = 0;
    var truncated = false;
    var aborted = false;
    var piece_buf: [512]u8 = undefined;

    outer: while (true) {
        if (produced >= req.n_predict) {
            truncated = true;
            break;
        }
        if (g.kv_toks.items.len + 1 >= g.n_ctx) {
            truncated = true;
            break;
        }
        const tok = veil_ll_sample(smpl, ctx);
        if (veil_ll_is_eog(vocab, tok)) break;
        produced += 1;
        const pn = veil_ll_piece(vocab, tok, &piece_buf, piece_buf.len);
        if (pn > 0) {
            try text.appendSlice(gpa, piece_buf[0..@intCast(pn)]);
            // scan the window a new stop could newly occupy: piece + longest-stop lookback
            if (req.stops.len > 0) {
                const from = if (text.items.len > @as(usize, @intCast(pn)) + max_stop)
                    text.items.len - @as(usize, @intCast(pn)) - max_stop
                else
                    0;
                for (req.stops) |s| {
                    if (s.len == 0) continue;
                    if (std.mem.indexOfPos(u8, text.items, from, s)) |hit| {
                        text.shrinkRetainingCapacity(hit);
                        break :outer;
                    }
                }
            }
            // stream everything that can no longer be part of a stop sequence
            if (req.on_piece) |cb| {
                const hold = if (max_stop > 0) max_stop - 1 else 0;
                if (text.items.len > emitted + hold) {
                    const upto = text.items.len - hold;
                    if (!cb(req.sink_ctx.?, text.items[emitted..upto])) {
                        aborted = true;
                        break :outer;
                    }
                    emitted = upto;
                }
            }
        }
        var one = [1]i32{tok};
        if (veil_ll_decode(ctx, &one, 1) != 0) break;
        g.kv_toks.append(g.gpa, tok) catch {};
    }

    // flush the withheld tail (minus any stop already truncated away)
    if (req.on_piece != null and !aborted and text.items.len > emitted) {
        _ = req.on_piece.?(req.sink_ctx.?, text.items[emitted..]);
    }

    return .{
        .text = try text.toOwnedSlice(gpa),
        .prompt_tokens = @intCast(prompt_toks.len - common),
        .gen_tokens = produced,
        .truncated = truncated,
    };
}
