//! llamaeng.zig — the embedded inference engine behind the built-in model (FFI side).
//!
//! Implements builtin.Engine over the veil_ll_* C facade (src/worker/llamashim.c), which is the
//! ONLY ffi surface: scalars and pointers, no by-value structs (see the shim header for why).
//! Compiled sources for the inference library exist only in -Dbuiltin builds; this file always
//! PARSES, but its externs resolve lazily, so nothing may reference them unless
//! build_options.builtin is true (main.zig gates the one construction site).
//!
//! Design points, in the order they matter:
//!   * ROLE-AFFINE KV SLOTS. The turn loop interleaves up to ten DIFFERENT prompts (the agentic
//!     step, the planner, the drive loop, compaction …) through one engine. A single kv sequence
//!     re-prefilled the whole conversation on nearly every call — tens of seconds of full-core
//!     work per call on a CPU, which is what "the app eats the machine" was. The engine now keeps
//!     N sequences (NL_BUILTIN_SLOTS, default 4); each request is routed to the slot whose cached
//!     tokens share the LONGEST PREFIX with its prompt, a barely-matching prompt takes an empty
//!     slot before it evicts a warm one, and only the divergent tail is ever re-evaluated. Each
//!     prompt family stabilizes its own slot, so a steady-state call prefills only its newest
//!     messages. The kv allocation is per-slot-window × slots, and slot count HALVES automatically
//!     when that allocation does not fit the machine.
//!   * SPLIT THREAD POOLS. Decode is memory-bandwidth-bound (~physical cores is the sweet spot,
//!     more just contends); prefill is compute-bound and scales wider. NL_BUILTIN_THREADS /
//!     NL_BUILTIN_THREADS_BATCH pin either; the defaults are half the logical cores for decode and
//!     all of them for prefill — an embedded harness must be a polite tenant, so neither default
//!     grabs more than the work can actually use.
//!   * SINGLE-FLIGHT: `generate` holds the engine mutex for the whole inference. Concurrent
//!     callers queue — the same behavior a busy local runtime gives them.
//!   * LAZY LOAD + IDLE UNLOAD: the first request pays the model load; an unloader thread returns
//!     the ~7GB working set to the OS after NL_BUILTIN_KEEPALIVE seconds (default 300) of quiet.
//!   * PER-REQUEST PERF LOG: every generation logs reused/prefilled token counts and both phase
//!     rates — the regression instrument for this whole module.
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
extern fn veil_ll_load(path: [*:0]const u8, n_gpu_layers: i32) ?*Model;
extern fn veil_ll_load_meta(path: [*:0]const u8) ?*Model;
extern fn veil_ll_gpu_desc(buf: [*]u8, cap: usize) i32;
extern fn veil_ll_gpu_free_mb() usize;
extern fn veil_ll_n_layer(m: *const Model) i32;
extern fn veil_ll_model_free(m: *Model) void;
extern fn veil_ll_ctx_new(m: *Model, n_ctx_total: u32, n_batch: u32, n_threads: i32, n_threads_batch: i32, n_seq: u32, kv_q8: bool) ?*Ctx;
extern fn veil_ll_ctx_free(c: *Ctx) void;
extern fn veil_ll_vocab(m: *const Model) *const Vocab;
extern fn veil_ll_tokenize(v: *const Vocab, text: [*]const u8, len: i32, toks: [*]i32, cap: i32, add_special: bool, parse_special: bool) i32;
extern fn veil_ll_decode_seq(c: *Ctx, toks: [*]i32, n: i32, first_pos: i32, seq: i32, logits_last: bool) i32;
extern fn veil_ll_mem_clear(c: *Ctx) void;
extern fn veil_ll_seq_rm(c: *Ctx, seq: i32, p0: i32, p1: i32) bool;
extern fn veil_ll_sampler_new(temp: f32, top_k: i32, top_p: f32, seed: u32) ?*Sampler;
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
/// top_k rides every sampled request: on a 262k-token vocabulary it is the cheap gate that keeps
/// per-token sampling cost flat.
const DEFAULT_TEMP: f32 = 0.8;
const DEFAULT_TOP_P: f32 = 0.95;
const DEFAULT_TOP_K: i32 = 40;
const N_BATCH: u32 = 512;
const MAX_SLOTS: u32 = 8;

/// Floor the load-time window ladder will step down to. Below this the harness's own fixed prefix cannot
/// fit and every turn would fail anyway, so failing the LOAD is the honest outcome — a served window that
/// cannot hold a single prompt is worse than a clear "not enough memory" at startup.
const MIN_SERVING_CTX: u32 = 4096;
/// A prompt matching a warm slot by fewer than this many tokens is "unrelated" — it takes an empty
/// slot (or the LRU) rather than evicting someone's cache for a nothing match.
const MIN_AFFINITY: usize = 16;

const Slot = struct {
    /// Token vector currently materialized in this slot's kv sequence (prompt + generated).
    toks: std.ArrayListUnmanaged(i32) = .empty,
    used_s: i64 = 0,
};

const G = struct {
    mutex: std.Io.Mutex = .init,
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    configured: bool = false,
    model: ?*Model = null,
    ctx: ?*Ctx = null,
    path: [512]u8 = @splat(0),
    path_len: u16 = 0,
    /// The PER-SLOT window (what /api/show reports). 8192 could not hold a chat turn: the harness's
    /// un-compactable prefix is ~6.4k tokens on its own (~2k of system blocks + ~4.4k for the 20-tool
    /// schema array), and num_predict reserves 2048 more, so the window was already oversubscribed
    /// before the user's first message — every conversation ended in "prompt exceeds the serving
    /// context window" (conv c6a6e014f). Worse, chat compaction only triggers past 24 KB of working
    /// span, which is the whole 8192-token window, so the fold that banks findings into neuron-db
    /// before dropping them never ran for this tier at all.
    ///
    /// 16384 leaves ~8k of real conversation room. Cost is ~128 KB/token of kv (48 layers, 8 kv heads,
    /// 8 full-attention layers at 512+512; the other 40 are SWA and cheap), so ~2.4 GB beside a 7.4 GB
    /// Q4 model — fits a 12 GB card. 32768 would not, which is why this is not simply the 32768 the
    /// chat client already asks for in num_ctx. Anything that cannot hold this degrades at load rather
    /// than failing (see the allocation ladder), and NL_BUILTIN_CTX still overrides in both directions.
    n_ctx: u32 = 16384,
    n_threads: i32 = 0,
    n_threads_batch: i32 = 0,
    n_slots_cfg: u32 = 4,
    n_slots_live: u32 = 0, // after allocation (halved until the kv fits)
    /// NL_BUILTIN_GPU: auto (default, offload everything a device will take), off, or a layer count.
    gpu_layers: i32 = 999,
    gpu_layers_live: i32 = 0, // where the fit ladder actually landed (0 = CPU serving)
    /// VRAM (MiB) the engine refuses to consume, left for the OTHER tenants on the card: the desk's
    /// own GL context, the browser the veil drives for web tools, the desktop compositor. Sized
    /// from a real failure — a 12GB card at ~370 MiB free took a driver kernel exception that
    /// killed the process. NL_BUILTIN_VRAM_RESERVE_MB tunes it; 0 disables the check.
    vram_reserve_mb: usize = 1536,
    /// Store the KV cache at q8_0 rather than f16 — roughly half the memory for a negligible
    /// quality cost, and the difference between a window that can hold a chat turn and one that
    /// cannot. NL_BUILTIN_KV_F16=1 restores full precision for anyone who wants it.
    kv_q8: bool = true,
    n_layer: i32 = 0, // the model's real layer count (from the metadata probe) — the offload unit
    weights_mb: usize = 0, // on-disk size, the pre-flight proxy for what the weights will cost in VRAM
    /// The status SNAPSHOT and its own short-lived lock. info() must never queue behind a
    /// generation: it shares no mutex with generate(), so a status poll cannot leak an http worker
    /// thread while the GPU is busy. Published after every state change.
    info_mu: std.Io.Mutex = .init,
    info_snap: builtin_mod.Info = .{},
    // measured rates from the LAST generation (tenths of a token/s) — the status row's honest
    // "what does THIS device actually deliver", instead of anyone guessing from specs
    last_decode_tps10: u32 = 0,
    last_prefill_tps10: u32 = 0,
    slots: [MAX_SLOTS]Slot = [_]Slot{.{}} ** MAX_SLOTS,
    keepalive_s: i64 = 300,
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
fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// Point the engine at a weights file (or at nothing). Called at boot and again after a
/// pull/import/delete changes the store. Cheap: full model load stays lazy; only the metadata
/// probe (vocab-only) runs here.
pub fn configure(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, path: ?[]const u8) void {
    g.io = io; // before the first lock — the mutex parks on this io
    lock();
    defer unlock();
    // publish the status snapshot on EVERY exit path (runs before unlock: LIFO), so a reader
    // never has to take the generation mutex to learn what the engine is doing
    defer publishInfoLocked();
    g.gpa = gpa;
    g.configured = true;
    if (environ.get("NL_BUILTIN_CTX")) |v| {
        if (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            if (n >= 1024) g.n_ctx = @min(n, 131072);
        } else |_| {}
    }
    if (environ.get("NL_BUILTIN_SLOTS")) |v| {
        if (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            if (n >= 1) g.n_slots_cfg = @min(n, MAX_SLOTS);
        } else |_| {}
    }
    const cpus: i32 = @intCast(std.Thread.getCpuCount() catch 8);
    if (environ.get("NL_BUILTIN_THREADS")) |v| {
        if (std.fmt.parseInt(i32, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            if (n > 0) g.n_threads = @min(n, 64);
        } else |_| {}
    }
    if (g.n_threads == 0) {
        // logical/2 ≈ physical cores — decode is bandwidth-bound; hyperthreads only contend
        g.n_threads = @max(4, @min(@divTrunc(cpus, 2), 16));
    }
    if (environ.get("NL_BUILTIN_THREADS_BATCH")) |v| {
        if (std.fmt.parseInt(i32, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            if (n > 0) g.n_threads_batch = @min(n, 64);
        } else |_| {}
    }
    if (g.n_threads_batch == 0) {
        // prefill is compute-bound and scales across every logical core
        g.n_threads_batch = @max(g.n_threads, @min(cpus, 32));
    }
    if (environ.get("NL_BUILTIN_KEEPALIVE")) |v| {
        if (std.fmt.parseInt(i64, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            if (n >= 30) g.keepalive_s = n;
        } else |_| {}
    }
    if (environ.get("NL_BUILTIN_KV_F16")) |v| {
        const t = std.mem.trim(u8, v, " \r\n\t");
        if (std.mem.eql(u8, t, "1") or std.ascii.eqlIgnoreCase(t, "true")) g.kv_q8 = false;
    }
    if (environ.get("NL_BUILTIN_VRAM_RESERVE_MB")) |v| {
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \r\n\t"), 10)) |n| {
            g.vram_reserve_mb = @min(n, 16384); // 0 = trust the driver's own allocation verdict
        } else |_| {}
    }
    if (environ.get("NL_BUILTIN_GPU")) |v| {
        const t = std.mem.trim(u8, v, " \r\n\t");
        if (std.ascii.eqlIgnoreCase(t, "off") or std.mem.eql(u8, t, "0")) {
            g.gpu_layers = 0;
        } else if (std.ascii.eqlIgnoreCase(t, "auto")) {
            g.gpu_layers = 999;
        } else if (std.fmt.parseInt(i32, t, 10)) |n| {
            g.gpu_layers = @max(0, @min(n, 999));
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
    // publish the status snapshot on EVERY exit path (runs before unlock: LIFO), so a reader
    // never has to take the generation mutex to learn what the engine is doing
    defer publishInfoLocked();
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
    // publish the status snapshot on EVERY exit path (runs before unlock: LIFO), so a reader
    // never has to take the generation mutex to learn what the engine is doing
    defer publishInfoLocked();
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
/// Also records which GPU-class device the runtime sees (backend registry is up by now) — the
/// status row's answer to "is it on the GPU?".
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
    // layer count + on-disk size: the two numbers the offload budget needs BEFORE any weight is
    // committed to the card. Both are free here — the probe already has the header open.
    g.n_layer = veil_ll_n_layer(m);
    g.weights_mb = blk: {
        const path = g.path[0..g.path_len];
        const s = std.Io.Dir.cwd().statFile(g.io, path, .{}) catch break :blk 0;
        break :blk @intCast(s.size / (1024 * 1024));
    };
    if (g.gpu_layers > 0) {
        const gn = veil_ll_gpu_desc(&g.meta.gpu, g.meta.gpu.len);
        g.meta.gpu_len = if (gn > 0) @intCast(gn) else 0;
    }
}

fn pathZLocked(buf: []u8) ?[*:0]const u8 {
    if (g.path_len == 0 or g.path_len + 1 > buf.len) return null;
    @memcpy(buf[0..g.path_len], g.path[0..g.path_len]);
    buf[g.path_len] = 0;
    return @ptrCast(buf[0..g.path_len :0].ptr);
}

fn ensureLoadedLocked() !void {
    if (g.ctx != null) return;
    if (g.path_len == 0) return error.NoWeights;
    ensureBackendLocked();
    var zbuf: [513]u8 = undefined;
    const p = pathZLocked(&zbuf) orelse return error.NoWeights;
    const t0 = nowS(g.io);

    // GPU FIT LADDER. "auto" must work on ANY card, and the only honest fit test on unknown
    // hardware is the allocation itself: try full offload, and on failure walk down (¾, ½, ¼,
    // CPU), logging where it landed. A 4GB card ends up partially offloaded; no card ends up
    // with a hard-failed engine. Each rung costs a load attempt — seconds, once, at first use.
    var gpu_avail = false;
    {
        var gbuf: [64]u8 = undefined;
        gpu_avail = g.gpu_layers > 0 and veil_ll_gpu_desc(&gbuf, gbuf.len) > 0;
    }
    // THE LADDER IS IN REAL LAYERS. It used to be 999/749/499/249/0, which llama clamps to the
    // model's layer count — so every rung above zero meant "all layers" and the ladder could only
    // ever go all-or-nothing. A card that can hold two thirds of the model got nothing.
    const total_layers: i32 = if (g.n_layer > 0) g.n_layer else 999;
    const want: i32 = @min(g.gpu_layers, total_layers);
    const ladder = [_]i32{ want, @divTrunc(want * 3, 4), @divTrunc(want, 2), @divTrunc(want, 4), 0 };

    // PRE-FLIGHT BUDGET. The reserve check after context creation is too late on its own: the
    // weights are committed first, and on Windows an over-budget commit does not fail — it
    // oversubscribes into shared memory, which is the state the driver died in. So decide how much
    // to offload from what is ACTUALLY free before asking for any of it. Skipped when the backend
    // cannot report free memory (0), where the old try-and-see remains the only available test.
    var rung: usize = if (gpu_avail) 0 else ladder.len - 1;
    if (gpu_avail and g.weights_mb > 0) {
        const free_mb = veil_ll_gpu_free_mb();
        if (free_mb > 0) {
            const budget: usize = if (free_mb > g.vram_reserve_mb) free_mb - g.vram_reserve_mb else 0;
            // fraction of the weights the budget can hold, in tenths (integer math, no float)
            const frac10: usize = if (g.weights_mb == 0) 0 else @min(budget * 10 / g.weights_mb, 10);
            const start: usize = if (frac10 >= 10) 0 else if (frac10 >= 7) 1 else if (frac10 >= 5) 2 else if (frac10 >= 2) 3 else 4;
            if (start > 0) log.warn(
                "{d} MiB free (reserve {d}) vs {d} MiB of weights — offloading {d}/{d} layers instead of all",
                .{ free_mb, g.vram_reserve_mb, g.weights_mb, ladder[start], total_layers },
            );
            rung = start;
        }
    }
    const m: *Model, const ngl: i32 = blk: {
        while (rung < ladder.len) : (rung += 1) {
            const try_ngl = ladder[rung];
            if (veil_ll_load(p, try_ngl)) |m| break :blk .{ m, try_ngl };
            if (try_ngl > 0) log.warn("offload at {d} layers did not fit — retrying lower", .{try_ngl});
        }
        g.load_failed = true;
        setErrLocked("model load failed (corrupt file, unsupported quant, or out of memory)");
        return error.LoadFailed;
    };

    // Slot budget follows PLACEMENT. On CPU, slot caching is the difference between seconds and
    // minutes per call, and system RAM has room for windows × slots. On a GPU the kv rides VRAM
    // beside the weights AND prefill runs ~50x faster, so extra slots buy little and can cost the
    // whole fit — serve 1 slot (NL_BUILTIN_SLOTS still overrides upward for big-VRAM boxes).
    var n: u32 = if (ngl > 0) @min(g.n_slots_cfg, 1) else @max(1, g.n_slots_cfg);
    if (ngl > 0 and g.n_slots_cfg > 4) n = 2; // an explicit big ask on a GPU box: meet halfway
    var win: u32 = g.n_ctx;
    const c: *Ctx = blk: {
        while (true) {
            if (veil_ll_ctx_new(m, win * n, N_BATCH, g.n_threads, g.n_threads_batch, n, g.kv_q8)) |c| {
                // A SUCCESSFUL ALLOCATION IS NOT A FIT. On Windows an over-budget VRAM request does
                // not fail — the driver oversubscribes into shared system memory — so this branch
                // was reached moments before a crash in which the display driver logged five
                // nvlddmkm errors and killed the whole process. We are also not the card's only
                // tenant: the desk's own GL context, the browser the veil drives for web tools, and
                // the desktop compositor all need room. So MEASURE what is left and step down until
                // a real reserve survives. CPU serving skips this — system RAM is not the scarce
                // thing there, and free-VRAM reads mean nothing.
                if (ngl > 0) {
                    const free_mb = veil_ll_gpu_free_mb();
                    if (free_mb > 0 and free_mb < g.vram_reserve_mb) {
                        if (win > MIN_SERVING_CTX or n > 1) {
                            veil_ll_ctx_free(c);
                            if (n > 1) {
                                n /= 2;
                            } else {
                                win = @max(MIN_SERVING_CTX, win / 1024 * 768); // 3/4, 1k-aligned
                            }
                            log.warn("only {d} MiB VRAM left after the kv (reserve {d}) — stepping down to {d} x {d} slot(s)", .{ free_mb, g.vram_reserve_mb, win, n });
                            continue;
                        }
                        // already at the floor: serve anyway, but say so — a user on a small card
                        // needs to know the machine is tight rather than be silently refused
                        log.warn("serving with only {d} MiB VRAM free — close other GPU apps if the driver misbehaves", .{free_mb});
                    }
                }
                g.n_ctx = win; // serve — and report through /api/show — the window that actually fit
                break :blk c;
            }
            if (n > 1) {
                n /= 2;
                log.warn("kv allocation did not fit — retrying with {d} slot(s)", .{n});
                continue;
            }
            // SLOTS EXHAUSTED: halve the WINDOW before giving up. This ladder only ever degraded slots,
            // so a box that could not hold one window failed the load outright — and raising the default
            // window would have turned that into a regression for smaller machines. Halving keeps the
            // plug-and-play promise: a box that used to serve 8192 still serves 8192, it just arrives
            // there by stepping down instead of by the constant happening to suit it.
            if (win > MIN_SERVING_CTX) {
                // 3/4 rather than 1/2: halving skips every useful size between 16384 and 8192, and
                // the window a turn needs (the harness prefix plus room to answer) usually lands in
                // that gap — a coarse ladder turns "slightly too big" into "half as much as the
                // card could serve".
                win = @max(MIN_SERVING_CTX, win / 1024 * 768);
                log.warn("kv allocation did not fit at 1 slot — retrying with a {d}-token window", .{win});
                continue;
            }
            veil_ll_model_free(m);
            g.load_failed = true;
            setErrLocked("context allocation failed (not enough memory for even one kv window)");
            return error.LoadFailed;
        }
    };
    g.model = m;
    g.ctx = c;
    g.n_slots_live = n;
    g.gpu_layers_live = ngl;
    for (g.slots[0..MAX_SLOTS]) |*sl| {
        sl.toks.clearRetainingCapacity();
        sl.used_s = 0;
    }
    log.info("model loaded in {d}s (window={d} x {d} slots, threads={d}/{d} batch, gpu_layers={d})", .{ nowS(g.io) - t0, g.n_ctx, n, g.n_threads, g.n_threads_batch, ngl });

    // WARM THE GPU PIPELINES. The Vulkan backend compiles its compute pipelines LAZILY on first
    // decode — ~15-20s of one-time cost that, unwarmed, lands on the user's first chat turn as a
    // mysterious stall. A single throwaway token decode here pays it during load (behind the
    // "installing/loading" state) instead. CPU serving compiles nothing, so skip it there.
    if (ngl > 0) {
        var warm = [_]i32{0}; // token 0 (BOS-ish); we discard the result, only the pipeline compile matters
        _ = veil_ll_decode_seq(c, &warm, 1, 0, 0, true);
        _ = veil_ll_seq_rm(c, 0, 0, -1); // leave slot 0 clean for the first real request
        log.info("gpu pipelines warmed ({d}s total to ready)", .{nowS(g.io) - t0});
    }
}

fn unloadLocked() void {
    if (g.ctx) |c| veil_ll_ctx_free(c);
    if (g.model) |m| veil_ll_model_free(m);
    g.ctx = null;
    g.model = null;
    g.n_slots_live = 0;
    for (g.slots[0..MAX_SLOTS]) |*sl| {
        sl.toks.clearAndFree(g.gpa);
        sl.used_s = 0;
    }
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

/// The status read, on its OWN lock over a published snapshot.
///
/// THIS USED TO TAKE THE GENERATION MUTEX, and that took the whole server down. generate() holds
/// that mutex for an entire inference; /api/v1/models/builtin calls this; the desk polls that route
/// every 10s and the web panel every 1.2s, each retried 3x. So while one generation ran long, every
/// poll blocked and parked an httpz worker thread — the 128-thread pool exhausted and EVERY
/// endpoint began timing out, including ones that never touch the engine (observed live: 13 minutes
/// of total wedge before the driver killed the process). A status read must never be able to queue
/// behind the work it is reporting on.
pub fn info() builtin_mod.Info {
    if (!g.configured) return .{};
    g.info_mu.lockUncancelable(g.io);
    defer g.info_mu.unlock(g.io);
    return g.info_snap;
}

/// Rebuild the published snapshot. CALLER HOLDS THE GENERATION MUTEX (it reads engine state); the
/// info lock is taken only for the microseconds of the copy, so a reader never waits on inference.
fn publishInfoLocked() void {
    var out = g.meta;
    out.ctx_serving = g.n_ctx;
    out.gpu_layers = g.gpu_layers_live;
    out.decode_tps10 = g.last_decode_tps10;
    out.state = if (g.path_len == 0)
        .absent
    else if (g.load_failed)
        .failed
    else if (g.ctx != null)
        .ready
    else
        .cold;
    g.info_mu.lockUncancelable(g.io);
    defer g.info_mu.unlock(g.io);
    g.info_snap = out;
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

/// One full generation under the engine mutex. See the module header for the slot, thread and
/// stop-withholding contracts; the sink receives raw text with stop sequences never leaked.
pub fn generate(gpa: std.mem.Allocator, req: builtin_mod.GenReq) !builtin_mod.GenRes {
    if (!g.configured) return error.NoWeights;
    lock();
    defer unlock();
    // publish the status snapshot on EVERY exit path (runs before unlock: LIFO), so a reader
    // never has to take the generation mutex to learn what the engine is doing
    defer publishInfoLocked();
    try ensureLoadedLocked();
    g.last_used_s = nowS(g.io);
    defer g.last_used_s = nowS(g.io);

    const ctx = g.ctx.?;
    const vocab = veil_ll_vocab(g.model.?);

    // ---- tokenize (specials parsed: the rendered prompt carries the wire-format tokens) ----
    const toks = try gpa.alloc(i32, g.n_ctx);
    defer gpa.free(toks);
    const n_tok = veil_ll_tokenize(vocab, req.prompt.ptr, @intCast(req.prompt.len), toks.ptr, @intCast(g.n_ctx), false, true);
    if (n_tok <= 0) return error.PromptTooLong; // negative = needed size exceeds the serving window
    const prompt_toks = toks[0..@intCast(n_tok)];
    // leave real room to answer: a prompt that fills the window would generate nothing useful
    if (prompt_toks.len + 16 > g.n_ctx) return error.PromptTooLong;

    // ---- slot election: longest shared prefix wins; weak matches take an empty slot before
    // evicting a warm one; everything warm and nothing matching → the least recently used ----
    var best_slot: usize = 0;
    var best_common: usize = 0;
    var empty_slot: ?usize = null;
    var lru_slot: usize = 0;
    var lru_s: i64 = std.math.maxInt(i64);
    for (g.slots[0..g.n_slots_live], 0..) |*sl, i| {
        if (sl.toks.items.len == 0 and empty_slot == null) empty_slot = i;
        if (sl.used_s < lru_s) {
            lru_s = sl.used_s;
            lru_slot = i;
        }
        const kv = sl.toks.items;
        var c: usize = 0;
        while (c < kv.len and c < prompt_toks.len and kv[c] == prompt_toks[c]) c += 1;
        if (c > best_common) {
            best_common = c;
            best_slot = i;
        }
    }
    var slot = best_slot;
    var common = best_common;
    if (best_common < MIN_AFFINITY) {
        slot = empty_slot orelse lru_slot;
        common = if (slot == best_slot) best_common else 0;
    }
    const sl = &g.slots[slot];
    // the final prompt token must be DECODED this call so its logits exist to sample from
    if (common == prompt_toks.len) common -= 1;
    if (common < sl.toks.items.len) {
        if (!veil_ll_seq_rm(ctx, @intCast(slot), @intCast(common), -1)) {
            _ = veil_ll_seq_rm(ctx, @intCast(slot), 0, -1);
            common = 0;
        }
    }
    sl.toks.clearRetainingCapacity();
    sl.toks.appendSlice(g.gpa, prompt_toks) catch {};
    sl.used_s = nowS(g.io);

    // ---- prefill the divergent suffix in batch-sized chunks ----
    const t_pre0 = nowMs(g.io);
    var at: usize = common;
    while (at < prompt_toks.len) {
        const n: usize = @min(N_BATCH, prompt_toks.len - at);
        const last = at + n == prompt_toks.len;
        if (veil_ll_decode_seq(ctx, prompt_toks.ptr + at, @intCast(n), @intCast(at), @intCast(slot), last) != 0) {
            _ = veil_ll_seq_rm(ctx, @intCast(slot), 0, -1);
            sl.toks.clearRetainingCapacity();
            return error.DecodeFailed;
        }
        at += n;
    }
    const prefill_ms = nowMs(g.io) - t_pre0;
    const prefilled = prompt_toks.len - common;

    // ---- sampler ----
    g.seed_seq +%= 1;
    const temp: f32 = if (req.temp < 0) DEFAULT_TEMP else req.temp;
    const top_p: f32 = if (req.temp < 0) DEFAULT_TOP_P else req.top_p;
    const smpl = veil_ll_sampler_new(temp, DEFAULT_TOP_K, top_p, g.seed_seq ^ @as(u32, @truncate(@as(u64, @intFromPtr(&g))))) orelse return error.DecodeFailed;
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
    const t_gen0 = nowMs(g.io);

    outer: while (true) {
        if (produced >= req.n_predict) {
            truncated = true;
            break;
        }
        if (sl.toks.items.len + 1 >= g.n_ctx) {
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
        if (veil_ll_decode_seq(ctx, &one, 1, @intCast(sl.toks.items.len), @intCast(slot), true) != 0) break;
        sl.toks.append(g.gpa, tok) catch {};
    }
    const gen_ms = nowMs(g.io) - t_gen0;

    // flush the withheld tail (minus any stop already truncated away)
    if (req.on_piece != null and !aborted and text.items.len > emitted) {
        _ = req.on_piece.?(req.sink_ctx.?, text.items[emitted..]);
    }

    const prefill_tps: f64 = if (prefill_ms > 0) @as(f64, @floatFromInt(prefilled)) * 1000.0 / @as(f64, @floatFromInt(prefill_ms)) else 0.0;
    const decode_tps: f64 = if (gen_ms > 0) @as(f64, @floatFromInt(produced)) * 1000.0 / @as(f64, @floatFromInt(gen_ms)) else 0.0;
    if (produced >= 4) g.last_decode_tps10 = @intFromFloat(@min(decode_tps * 10.0, 100_000)); // tiny gens are noise, not a measurement
    if (prefilled >= 64) g.last_prefill_tps10 = @intFromFloat(@min(prefill_tps * 10.0, 1_000_000));
    log.info("gen: slot={d} reuse={d} prefill={d}tk/{d}ms ({d:.1} t/s) decode={d}tk/{d}ms ({d:.1} t/s)", .{
        slot,
        common,
        prefilled,
        prefill_ms,
        prefill_tps,
        produced,
        gen_ms,
        decode_tps,
    });

    return .{
        .text = try text.toOwnedSlice(gpa),
        .prompt_tokens = @intCast(prefilled),
        .gen_tokens = produced,
        .truncated = truncated,
    };
}
