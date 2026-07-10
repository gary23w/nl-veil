# log

**File:** `desk/src/log.zig`  
**Module:** `desk`  
**Description:** A tiny lock-guarded, allocation-free ring-buffer logging facility for the veil-desk desktop app, written by both the UI and poller threads and read by a consuming file-flusher and a non-consuming in-app overlay.

---

## Purpose Summary

Provides veil-desk's in-process logging: a fixed 8192-line ring buffer that both the UI thread and the poller thread write to concurrently. It backs two consumers — the poller flushing new lines to data/veil-desk.log, and the F12 in-app overlay showing recent lines. It also hosts a whole-app function-entry tracing facility (default-on) so a live run's log reads as a call trace, which is the specific tooling that was missing when root-causing the DSML lock-up/crash bug.

## Key Exports

- `Level` — log severity enum: info, warn, dbg, err
- `levelTag(Level) []const u8` — maps a level to a fixed 4-char tag ("INFO", "WARN", "DBG ", "ERR ")
- `Line` — a log record: i64 t_s timestamp, Level, inline 220-byte buf, u16 len, plus str() returning buf[0..len]
- `info`/`warn`/`dbg`/`err(comptime fmt, args)` — level-specific formatted log entry points (thin wrappers over emit)
- `trace(comptime fmt, args)` — function-entry tracing; no-op when disabled, else emits at .dbg level
- `setTraceEnabled(bool)` / `traceEnabled() bool` — atomically toggle/read the global trace gate (.monotonic ordering)
- `setClock(i64)` — poller stamps current wall-clock seconds used to timestamp subsequent lines
- `drain([]Line) usize` — consuming read for the file flusher: copies lines since last drain (oldest-first), advances the drain cursor, returns count
- `snapshot([]Line) usize` — non-consuming read for the overlay: most recent min(out.len, CAP) lines, oldest-first

## Dependencies

- std (std.fmt.bufPrint, std.atomic.Value, spinLoopHint, @atomicLoad/@atomicStore)

## Usage Context

Used app-wide in veil-desk (Zig + raylib). Two producer threads write concurrently: the UI thread (F12 overlay producers) and the poller thread (deploy/delete/tray/http). The poller calls setClock each refresh to give lines a real timestamp, then calls drain() to flush newly written lines to data/veil-desk.log; the F12 overlay calls snapshot() to render recent lines without consuming them. trace() is invoked at the top of nearly every non-hot-path function across the app (deliberately excluded from main.zig's per-frame draw/render paths to avoid 60fps flooding), and can be silenced at runtime via setTraceEnabled(false) without a rebuild.

## Notable Implementation Details

All shared state is module-global: a fixed `g_lines: [CAP]Line` array (CAP=8192, ~1.8MB static, bumped up from 512 precisely because whole-app trace volume would otherwise evict real signal within seconds), a monotonic `g_write` cursor, and a `g_drain` cursor for the flusher; indexing is `cursor % CAP`. Mutual exclusion is a hand-rolled spinlock, not a mutex: `g_held` is a std.atomic.Value(bool) spun on with swap(true, .acquire)/spinLoopHint and released with store(false, .release) — cheap and fine for the short critical sections, but it busy-waits. The hot path is allocation-free: emit() formats directly into the Line's inline 220-byte buffer via bufPrint, and on overflow it deliberately keeps the truncated prefix that fit (catch returns buf[0..buf.len]) rather than dropping the line. Timestamp is read lock-free with @atomicLoad on g_clock; the trace gate g_trace_on is atomic (checked before taking the lock, so a disabled trace is nearly free). drain() self-heals if the flusher falls behind more than CAP lines: it fast-forwards start to g_write - CAP, silently skipping the lost oldest lines rather than re-reading stale ring slots. snapshot() applies the same CAP-clamp so an oversized or lagging caller still only sees valid recent lines. Note the two cursors are independent — snapshot never touches g_drain, so overlay reads and file flushing don't interfere. There is no direct neuron-db or nl-veil server coupling here; the only integration seam is the poller draining to data/veil-desk.log and stamping the clock.

---

*Documentation generated for nl-veil — desk/log.zig source analysis.*
