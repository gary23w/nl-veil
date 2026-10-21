//! Oscillation — the worker's single gateway to neuron-db: the read/write round-trip (observe,
//! recall, chain, reinforce, assoc) plus the operator preamble + baseline tables. One seam for all
//! memory traffic — the place to instrument, debug, and gate it.
const std = @import("std");
const builtin = @import("builtin");
const bounded = @import("bounded.zig");
const bu = @import("browser/util.zig"); // sleepMs: a raw-thread sleep, no Io park (the lock-retry pause)

/// COST PROBE — bumped only in test builds. `Mem.exec` is the single spawn site in this file, reached by
/// `run` and `runEnv` alike (every assoc/recall-breadth read goes through runEnv), so this counts every
/// neuron-db PROCESS SPAWN the hive memory makes, which is what this module's batching claims are
/// actually about (`observeBatch`: "ONE subprocess instead of one spawn per fact", against a 40-tool
/// storm that used to pay ~40 serialized launches).
///
/// Counted, never timed: a wall-clock budget on a dev box measures Defender and background load, so
/// it flakes and then gets muted. A spawn count is exact and identical on every machine. Mirrors
/// `neuron/client.zig`'s probe, which prices the OTHER neuron-db seam. See harness/TESTING.md.
pub var spawn_probe: u64 = 0;

/// The bound on one neuron-db run when a Mem names none (Mem.bound_ms = 0). It is a local sqlite store that
/// answers in milliseconds to seconds, so this only ever cuts a wedged one: under std.process.run a wedged
/// neuron-db held the caller (often under the hive's write lock) forever, and an answer past 1 MiB, which read
/// as a failure through StreamTooLong, could hang the call outright on Windows (see bounded.zig).
const NEURON_BOUND_MS: u64 = 120_000;

/// Why a write did not land. `lock`: neuron-db's single-writer pid lock refused it ("one db file = one
/// writer", exit 1) and the retries below ran out; `missing`: the neuron binary could not be started;
/// `pack`: the temp pack an import reads could not be written beside the db; `timeout`: still running at
/// the Mem's bound, killed; `other`: any other nonzero exit or signal (two concurrent writers on one scope
/// collide on its append-log seq and the loser panics, exit 101) or output that could not be read.
pub const Fail = enum { lock, missing, pack, timeout, other };

/// WRITE ACCOUNTING for one owner of a Mem (a chat turn, one delegated tool call): every write spawn is
/// counted once by how it ended, with the time it spent waiting to write (the in-process write lock plus
/// any pause between lock retries). A write that does not land used to look exactly like one that did:
/// every caller discarded the count, so a step's raw-output documents could vanish with nothing said.
/// Atomic, because nothing stops two threads from sharing one ToolCtx.
pub const WriteStats = struct {
    ok: std.atomic.Value(u32) = .init(0),
    lock: std.atomic.Value(u32) = .init(0),
    missing: std.atomic.Value(u32) = .init(0),
    pack: std.atomic.Value(u32) = .init(0),
    timeout: std.atomic.Value(u32) = .init(0),
    other: std.atomic.Value(u32) = .init(0),
    /// lock-refused attempts that were retried (a write retried twice and then landed counts 2 here, 1 in ok)
    retries: std.atomic.Value(u32) = .init(0),
    wait_ns: std.atomic.Value(u64) = .init(0),

    pub fn note(s: *WriteStats, f: Fail) void {
        const c = switch (f) {
            .lock => &s.lock,
            .missing => &s.missing,
            .pack => &s.pack,
            .timeout => &s.timeout,
            .other => &s.other,
        };
        _ = c.fetchAdd(1, .monotonic);
    }
    pub fn failed(s: *const WriteStats) u32 {
        return s.lock.load(.monotonic) + s.missing.load(.monotonic) + s.pack.load(.monotonic) +
            s.timeout.load(.monotonic) + s.other.load(.monotonic);
    }
    pub fn writes(s: *const WriteStats) u32 {
        return s.ok.load(.monotonic) + s.failed();
    }
    pub fn waitMs(s: *const WriteStats) u64 {
        return s.wait_ns.load(.monotonic) / std.time.ns_per_ms;
    }
    /// One line for a trace or a log: "memory writes: 9 landed, 0 failed, 0 lock retries, waited 0 ms for the
    /// write lock", naming each failure reason when any write failed.
    pub fn line(s: *const WriteStats, buf: []u8) []const u8 {
        const nf = s.failed();
        if (nf == 0) return std.fmt.bufPrint(buf, "memory writes: {d} landed, 0 failed, {d} lock retr{s}, waited {d} ms for the write lock", .{
            s.ok.load(.monotonic), s.retries.load(.monotonic), if (s.retries.load(.monotonic) == 1) "y" else "ies", s.waitMs(),
        }) catch "memory writes";
        return std.fmt.bufPrint(buf, "memory writes: {d} landed, {d} FAILED (lock {d}, missing binary {d}, pack write {d}, timeout {d}, other {d}), {d} lock retr{s}, waited {d} ms for the write lock", .{
            s.ok.load(.monotonic),                               nf,                         s.lock.load(.monotonic),  s.missing.load(.monotonic),
            s.pack.load(.monotonic),                             s.timeout.load(.monotonic), s.other.load(.monotonic), s.retries.load(.monotonic),
            if (s.retries.load(.monotonic) == 1) "y" else "ies", s.waitMs(),
        }) catch "memory writes failed";
    }
};

/// A write refused by neuron-db's pid lock is retried up to LOCK_RETRIES times, pausing LOCK_PAUSE_MS
/// doubled per attempt (capped at LOCK_PAUSE_MAX_MS): 0.1+0.2+0.4+0.8+1.6+2 s ≈ 5 s in all. In-process
/// writers already queue on writeLockFor, so a refusal means ANOTHER process holds the db (`veil rag
/// ingest` writes u1's chat hive by default). Measured 2026-10-20 on a 22 MB hive with the shipped
/// neuron.exe: a step import took 0.11 s and the CLI's own liveness probe of a lock holder 0.15 s, so
/// ~5 s covers a neighbour's ordinary write without stalling a turn for long behind a whole-book absorb.
pub const LOCK_RETRIES: u32 = 6;
const LOCK_PAUSE_MS: u64 = 100;
const LOCK_PAUSE_MAX_MS: u64 = 2000;

/// TEST SEAM: `pause_cap_ms` caps every lock-retry pause, so a test reaches the give-up path in milliseconds.
pub const seam = if (builtin.is_test) struct {
    pub var pause_cap_ms: ?u64 = null;
} else struct {};

/// The bound on one chat neuron spawn (Mem.bound_ms), so a hung child can never hold the write lock and
/// every other turn of the user behind it. Measured 2026-10-20 (shipped neuron.exe, 22-43 MB synthetic
/// hive): the heaviest ordinary write was 0.45 s (observe into a 20k-fact scope, compaction included) and a
/// 20k-fact absorb import 0.86 s, so this is two orders of magnitude past any measured legitimate spawn.
/// importStats (a whole document) gets BULK_BOUND_MS instead.
pub const CHAT_BOUND_MS: u64 = 120_000;
pub const BULK_BOUND_MS: u64 = 1_800_000;

/// ONE WRITER PER DB FILE, IN THIS PROCESS. neuron-db's CLI refuses a second concurrent `import` on a db
/// (its `<db>.lock` pid lock, exit 1), and two concurrent single-shot writers on one scope race its append
/// log: both load seq N and the second INSERT panics on the primary key (exit 101), or a compaction
/// snapshot deletes the other's fresh row. Every chat turn of one user (a primary and its sub-chats, two
/// tabs, the desk's delegated tool endpoint) writes the same `{data}/u{uid}/_chat/hive.sqlite`, so their
/// writes queue on the mutex this returns for that path. Keyed by the path itself (on Windows with `\`
/// read as `/` and case folded), never by a hash bucket, so two users' hives never wait on each other.
/// Entries live as long as the process. Null only for a path over 1 KiB or when the registry cannot
/// allocate (writes then run unserialized, exactly as before).
pub fn writeLockFor(io: std.Io, db: []const u8) ?*std.Io.Mutex {
    var kb: [1024]u8 = undefined;
    if (db.len == 0 or db.len > kb.len) return null;
    for (db, 0..) |c, i| kb[i] = if (builtin.os.tag == .windows) (if (c == '\\') '/' else std.ascii.toLower(c)) else c;
    const key = kb[0..db.len];
    write_locks_mtx.lockUncancelable(io);
    defer write_locks_mtx.unlock(io);
    if (write_locks.get(key)) |m| return m;
    const pa = std.heap.page_allocator;
    const m = pa.create(std.Io.Mutex) catch return null;
    m.* = .init;
    const owned = pa.dupe(u8, key) catch {
        pa.destroy(m);
        return null;
    };
    write_locks.put(pa, owned, m) catch {
        pa.free(owned);
        pa.destroy(m);
        return null;
    };
    return m;
}
var write_locks_mtx: std.Io.Mutex = .init;
var write_locks: std.StringHashMapUnmanaged(*std.Io.Mutex) = .empty;

/// FAIL FAST BEHIND A HELD STORE. Once a write has sat out every lock retry (~5 s) and given up because
/// another process holds the db, the next writes to that db within REFUSED_HOLD_MS make ONE attempt each
/// instead of paying the same ~5 s again. A turn's exit makes many writes in a row (the user observe, the
/// step bank, the imports, one strengthen per fired overlay fact), and each sitting out its own retries
/// would hold the turn, and through writeLockFor every other turn of the user, for minutes. The writes are
/// still counted as lost to the lock. A write that lands ends the window. Best effort: a slot is a hash of
/// the db path, and a collision costs the other path one fail-fast window at most.
const REFUSED_SLOTS = 64;
pub const REFUSED_HOLD_MS: i64 = 30_000;
var refused_key: [REFUSED_SLOTS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.init(0)} ** REFUSED_SLOTS;
var refused_until_ms: [REFUSED_SLOTS]std.atomic.Value(i64) = [_]std.atomic.Value(i64){.init(0)} ** REFUSED_SLOTS;

/// The db path keyed as writeLockFor keys it (on Windows `\` read as `/`, case folded), hashed; never 0.
fn refusedKey(db: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    var kb: [256]u8 = undefined;
    var i: usize = 0;
    while (i < db.len) {
        const n = @min(kb.len, db.len - i);
        for (db[i .. i + n], 0..) |c, j| kb[j] = if (builtin.os.tag == .windows) (if (c == '\\') '/' else std.ascii.toLower(c)) else c;
        h.update(kb[0..n]);
        i += n;
    }
    const k = h.final();
    return if (k == 0) 1 else k;
}
fn awakeMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}
fn refusedRecently(io: std.Io, db: []const u8) bool {
    const k = refusedKey(db);
    const i = k % REFUSED_SLOTS;
    return refused_key[i].load(.monotonic) == k and awakeMs(io) < refused_until_ms[i].load(.monotonic);
}
fn markRefused(io: std.Io, db: []const u8, on: bool) void {
    const k = refusedKey(db);
    const i = k % REFUSED_SLOTS;
    if (on) {
        refused_until_ms[i].store(awakeMs(io) + REFUSED_HOLD_MS, .monotonic);
        refused_key[i].store(k, .monotonic);
    } else if (refused_key[i].load(.monotonic) == k) refused_key[i].store(0, .monotonic);
}

/// stderr of an exit-1 the CLI's single-writer lock produced ("<db>.lock is held by a live neuron writer
/// (pid N)." / "one db file = one writer: ..."): the shipped binary's exact wording.
fn lockRefused(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "held by a live neuron writer") != null or
        std.mem.indexOf(u8, stderr, "one db file = one writer") != null;
}

/// A spawn error that means the binary is not there to run (deps.isSpawnMissing's set).
fn spawnMissing(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir, error.InvalidExe, error.InvalidName, error.AccessDenied, error.PermissionDenied => true,
        else => false,
    };
}

// Operator preamble + build-time string tables (generated; do not hand-edit the byte tables or anchors).
fn mix(s: []const u8) u64 {
    var x: u64 = 0xcbf29ce484222325;
    for (s) |c| {
        x = (x ^ c) *% 0x100000001b3;
    }
    return x;
}

fn ksb(seed: u64, i: u64) u8 {
    var z = seed +% i +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return @truncate(z ^ (z >> 31));
}

const sd: u64 = 0x6a09e667f3bcc908;

const pz = [_]u8{
    0x0a, 0xcb, 0x1a, 0x95, 0xbf, 0x9f, 0x74, 0x43, 0xa0, 0x0d, 0xc9, 0x64, 0x5f, 0xf8, 0x12, 0x77,
    0x1a, 0xec, 0x70, 0xb7, 0x11, 0x46, 0xf2, 0x1e, 0x07, 0x7d, 0xa5, 0xb1, 0x20, 0xae, 0x55, 0xa8,
    0x6f, 0x7e, 0xf9, 0x95, 0xbe, 0x78, 0xfe, 0xd1, 0xa5, 0x3e, 0xa9, 0x43, 0x01, 0x93, 0x31, 0xc2,
    0x2f, 0x0e, 0x02, 0xeb, 0xcc, 0x59, 0x9e, 0x0b, 0xe1, 0x85, 0xec, 0xfb, 0x09, 0xee, 0x07, 0x85,
    0x77, 0xe0, 0xb7, 0x17, 0x05, 0xb1, 0x21, 0x1c, 0x95, 0xd1, 0x97, 0xe2, 0x96, 0xce, 0x12, 0xe1,
    0x45, 0xad, 0xa5, 0x72, 0x1d, 0x6a, 0x9b, 0xe9, 0x3d, 0x5b, 0x20, 0x1f, 0xea, 0xa9, 0xe4, 0xaf,
    0x4d, 0xa2, 0x83, 0x83, 0x59, 0xd2, 0x4d, 0x9c, 0x2a, 0x8f, 0x06, 0xda, 0x24, 0xcd, 0xcb, 0x4a,
    0x65, 0xe9, 0x24, 0x04, 0x0f, 0xe5, 0x4f, 0xf6, 0x67, 0x9a, 0x09, 0xc9, 0xb8, 0x29, 0x60, 0xd9,
    0x86, 0x92, 0x3f, 0x41, 0x13, 0x57, 0xad, 0xb3, 0x05, 0xe2, 0x30, 0xd0, 0x10, 0x34, 0xac, 0x3d,
    0xf2, 0xb5, 0x23, 0x1a, 0xc1, 0x2d, 0x2e, 0xcd, 0x9d, 0x51, 0x88, 0xd7, 0xb7, 0x2f, 0x76, 0x0d,
    0xe7, 0x4b, 0xf6, 0x07, 0xe2, 0x34, 0xbc, 0x52, 0xc0, 0xbd, 0xf6, 0x15, 0xbf, 0xff, 0xe7, 0x59,
    0x16, 0xb4, 0x54, 0xda, 0xa8, 0xa2, 0xf8, 0x19, 0x32, 0x9c, 0x2a, 0xf7, 0xfd, 0x8c, 0x15, 0x6d,
    0xfe, 0xd9, 0x95, 0xcd, 0x46, 0x46, 0xe8, 0xc4, 0x44, 0xa0, 0x7f, 0xe7, 0x76, 0x2c, 0x1a, 0x7d,
    0x4a, 0xbc, 0x67, 0xc1, 0x30, 0x52, 0x9d, 0xfc, 0x5c, 0x2a, 0xa8, 0xed, 0x1b, 0x1c, 0x97, 0x49,
    0xaa, 0x7f, 0x75, 0x01, 0xb4, 0x20, 0xba, 0xb2, 0xea, 0x95, 0xa4, 0x34, 0xc6, 0x1f, 0x19, 0x6f,
    0x48, 0xee, 0xf2, 0xaf, 0xd0, 0xee, 0x14, 0x85, 0xd5, 0x7a, 0x1d, 0x53, 0xf7, 0x8c, 0x29, 0x6b,
    0x59, 0xee, 0xcf, 0x56, 0xca, 0x65, 0xf6, 0x7c, 0xf3, 0x77, 0x2e, 0xea, 0xdd, 0xf3, 0xa5, 0xae,
    0x5e, 0xf6, 0x0e, 0x24, 0x7c, 0x86, 0xfb, 0x99, 0xab, 0xa2, 0x21, 0xb7, 0x3c, 0x67, 0x53, 0x68,
    0x72, 0x75, 0x23, 0x58, 0xa3, 0x48, 0x07, 0xa9, 0x16, 0xe4, 0x1a, 0x40, 0x0e, 0x55, 0x3a, 0x49,
    0xa5, 0x19, 0x5b, 0xcc, 0x22, 0x90, 0x6e, 0x7b, 0x1c, 0xcf, 0xa1, 0xb0, 0xd7, 0x98, 0xa1, 0xc1,
    0xc1, 0x4f, 0xa5, 0xe8, 0x2a, 0x0e, 0x2b, 0x93, 0x38, 0xaa, 0x81, 0x75, 0xbc, 0x22, 0x74, 0xb3,
    0xe5, 0xb3, 0xae, 0x1f, 0x4d, 0xb9, 0x51, 0xb2, 0xa0, 0x22, 0x51, 0x71, 0x4c, 0x11, 0xd8, 0x1f,
    0x86, 0xee, 0x05, 0xf1, 0x23, 0x3f, 0x42, 0x24, 0x3c, 0xd0, 0x77, 0xde, 0x43, 0x01, 0xb0, 0xa1,
    0x55, 0xba, 0x25, 0xaa, 0x84, 0x88, 0x85, 0x29, 0xeb, 0xf4, 0x6d, 0xc5, 0x01, 0x3c, 0x62, 0x02,
    0xf1, 0x9d, 0x58, 0x86, 0xde, 0x71, 0x48, 0xa9, 0xf2, 0x06, 0x51, 0x45, 0xe1, 0xd9, 0x3a, 0x1c,
    0xea, 0x1a, 0x99, 0xe9, 0xb0, 0x53, 0xf8, 0x57, 0x66, 0xc0, 0x03, 0xd8, 0x39, 0x68, 0xad, 0x1b,
    0xf6, 0xb1, 0xb5, 0x77, 0xe8, 0x3e, 0x3b, 0x98, 0xce, 0xc4, 0x8b, 0xa8, 0x2a, 0x9c, 0x4c, 0xf6,
    0x13, 0x70, 0x31, 0x50, 0x97, 0x59, 0xae, 0x27, 0xaf, 0x79, 0x7c, 0x9f, 0x63, 0x93, 0x2a, 0xd1,
    0xca, 0xa1, 0xa3, 0x6d, 0x0b, 0x9b, 0xe1, 0xe7, 0xca, 0x1a, 0x58, 0xec, 0x0d, 0xbd, 0xd2, 0xee,
    0xc4, 0xd8, 0x71, 0xb5, 0xf9, 0xbe, 0x86, 0xe3, 0xbe, 0x68, 0x65, 0x89, 0x91, 0x50, 0xcd, 0x6f,
    0x6f, 0x2a, 0x22, 0x0b, 0xd8, 0xbc, 0xb1, 0x78, 0xd0, 0x54, 0xe2, 0x80, 0xdd, 0x0a, 0x74, 0x14,
    0x00, 0x17, 0xa6, 0xd0, 0x5b, 0xb0, 0x53, 0x3b, 0x74, 0x85, 0xdc, 0x48, 0xae, 0x89, 0x54, 0x09,
    0x4b, 0x2e, 0x7c, 0x65, 0x84, 0xdc, 0x22, 0xc0, 0x81, 0xc0, 0xbf, 0x4e, 0x57, 0x53, 0x81, 0x5c,
    0x36, 0xcc, 0x0a, 0x87, 0x47, 0xc2, 0x15, 0x59, 0x5a, 0x64, 0x0b, 0x35, 0xf5, 0x94, 0xee, 0xab,
    0x63, 0xcc, 0xda, 0xf1, 0x66, 0x89, 0xa8, 0xed, 0x82, 0xa9, 0xb0, 0x9b, 0x1f, 0x1a, 0x0b, 0x68,
    0x4e, 0x51, 0xd2, 0xec, 0xe2, 0x8d, 0x06, 0x5c, 0xe9, 0x33, 0x14, 0x32, 0x63, 0xcb, 0x47, 0x79,
    0x63, 0x95, 0x48, 0x30, 0x51, 0x1b, 0xe8, 0xf5, 0x66, 0x13, 0x10, 0x02, 0x66, 0xf6, 0x43, 0x36,
    0x98, 0x2d, 0x4a, 0x1e, 0x32, 0x33, 0x00, 0x47, 0x51, 0x5d, 0xb3, 0x5f, 0x81, 0x08, 0x42, 0x36,
    0x53, 0xfd, 0x8b, 0x29, 0xff, 0x42, 0x2a, 0xa6, 0xd0, 0xa7, 0x82, 0xfb, 0x6e, 0xc2, 0xbc, 0xb4,
    0xea, 0xc9, 0x0f, 0x4b, 0xe8, 0xe2, 0xca, 0xed, 0xdc, 0x65, 0x4a, 0xa3, 0x4a, 0x98, 0xed, 0x75,
    0x23, 0xb4, 0xb8, 0xca, 0x10, 0x2b, 0x05, 0x24, 0x18, 0xba, 0xe5, 0xdc, 0x37, 0x63, 0xf0, 0x28,
    0xdb, 0x7c, 0x74, 0xe1, 0xf4, 0x5d, 0x38, 0x36, 0x7d, 0x5b, 0x8b, 0xd3, 0x1d, 0x4b, 0x0c, 0x11,
    0x07, 0x09, 0x71, 0xaf, 0x5b, 0x70, 0x4b, 0xb4, 0xf1, 0xca, 0xb8, 0xf5, 0x3f, 0x53, 0xcf, 0xcd,
    0x6e, 0x59, 0xc7, 0xb4, 0xa0, 0xcb, 0xb4, 0x8c, 0xb5, 0x25, 0x7b, 0xc8, 0x02, 0xb7, 0xdf, 0xe4,
    0xd3, 0x27, 0x04, 0xc1, 0xbc, 0x7e, 0x3a, 0xaf, 0x00, 0xfa, 0xe0, 0x6d, 0xee, 0x6a, 0x28, 0x5a,
    0x22, 0x25, 0x9a, 0x43, 0xa2, 0x64, 0xf9, 0x7a, 0x84, 0x23, 0xed, 0x81, 0x25, 0xa5, 0x51, 0x26,
    0xbb, 0xd5, 0x15, 0x97, 0xe7, 0x7a, 0x94, 0xe5, 0x28, 0x4d, 0xf2, 0x89, 0xe8, 0x54, 0xd3, 0xfe,
    0xb2, 0x54, 0xad, 0xc2, 0xff, 0x08, 0x98, 0x0d, 0xdf, 0x7a, 0x09, 0x98, 0x7c, 0x40, 0x46, 0x25,
    0x97, 0x5d, 0xff, 0x95, 0x9b, 0x4f, 0x17, 0x82, 0x9e, 0xb8, 0xfc, 0xf2, 0x85, 0xaa, 0x8c, 0x95,
    0x12, 0x3c, 0x37, 0xc0, 0xa3, 0x1a, 0x57, 0xf5, 0x59, 0xdf, 0x16, 0xc2, 0xb7, 0xff, 0xb8, 0x45,
    0xad, 0xb8, 0x2a, 0x42, 0x04, 0x34, 0xfb, 0x64, 0xd3, 0xb4, 0xea, 0x3d, 0x23, 0x5a, 0x83, 0x84,
    0x1e, 0x59, 0x8c, 0xc9, 0x57, 0x31, 0x74, 0x55, 0xe0, 0x85, 0x7e, 0x84, 0xb8, 0x65, 0xf2, 0x4d,
    0x80, 0xec, 0x11, 0x96, 0x2c, 0x1b, 0x89, 0x8b, 0xc5, 0xd3, 0xe1, 0x6e, 0xd7, 0x2d, 0x3e, 0x3c,
    0x24, 0x48, 0x74, 0x0c, 0x48, 0x96, 0x55, 0x50, 0xd6, 0xc2, 0x01, 0x8c, 0x67, 0x0b, 0x81, 0x7d,
    0x1e, 0x8c, 0xe6, 0x0d, 0x39, 0x2d, 0xce, 0x82, 0xfe, 0x17, 0x7a, 0x97, 0xcb, 0x80, 0xc5, 0x59,
    0x34, 0x62, 0x6c, 0x46, 0x23, 0xbf, 0x3c, 0x25, 0xb6, 0x2b, 0xdf, 0xdb, 0x9a, 0x51, 0x60, 0x18,
    0x3a, 0xd7, 0x7d, 0x66, 0xbc, 0x04, 0x3a, 0x7c, 0xa8, 0xde, 0x07, 0x04, 0xce, 0x72, 0x38, 0x6c,
    0xca, 0x1e, 0xea, 0x7a, 0x09, 0xcd, 0x30, 0x33, 0xdd, 0xe0, 0xa8, 0xff, 0x65, 0x1d, 0x6f, 0xda,
    0xeb, 0xde, 0x9f, 0xeb, 0x88, 0xd2, 0x35, 0x49, 0x24, 0x1d, 0x8e, 0x64, 0x1a, 0x9c, 0x70, 0x3a,
    0x5c, 0xeb, 0x0c, 0x2e, 0xce, 0xab, 0x3c, 0xee, 0x44, 0x4e, 0x86, 0xb1, 0x85, 0x35, 0x70, 0x1b,
    0x7b, 0x62, 0x14, 0x85, 0x54, 0xb3, 0x4e, 0x67, 0x1f, 0x3f, 0x36, 0xe7, 0xcc, 0xad, 0xb8, 0xa0,
    0xf0, 0x8f, 0x74, 0x6c, 0x4b, 0x64, 0x63, 0xcb, 0xaa, 0xf8, 0x32, 0x41, 0xa0, 0x25, 0xf0, 0x71,
    0x6b, 0x9b, 0xeb, 0xda, 0xd8, 0x84, 0xf9, 0x3b,
};
const cz = [_]u8{
    0x71, 0xe1, 0x07, 0x83, 0xa5, 0x9d, 0x6e, 0x47, 0xf2, 0x38, 0xeb, 0x53, 0x4c, 0x8c, 0x6b, 0x5f,
    0x2e, 0x9e, 0x43, 0x80, 0x20, 0x32, 0x93, 0x9b, 0xe2, 0x87, 0xf1, 0xe5, 0x0f, 0xaa, 0x07, 0xa9,
    0x62, 0x63, 0xe8, 0xd5, 0xfa, 0x2c, 0xf9, 0xd2, 0xa5, 0x39, 0xa9, 0x4f, 0x44, 0xbe, 0x38, 0x87,
    0x32, 0x01, 0x41, 0xfe, 0xd7, 0x12, 0x9e, 0x13, 0xe3, 0x95, 0xec, 0xb2, 0x0f, 0xfb, 0x1c, 0xcc,
    0xf6, 0x13, 0x03, 0x40, 0x01, 0xad, 0x20, 0x1c, 0x9c, 0xd8, 0xc5, 0xe0, 0x85, 0xcf, 0x40, 0xf1,
    0x0b, 0xfd, 0xb2, 0x65, 0x0a, 0x60, 0x98, 0xb5, 0x69, 0x41, 0x36, 0x02, 0xbe, 0xad, 0xe7, 0xe7,
    0x4d, 0xa2, 0x9f, 0x82, 0x59, 0xd7, 0x4f, 0x9f, 0x3b, 0x8f, 0x47, 0xc1, 0x30, 0xdb, 0x87, 0x46,
    0x31, 0xe9, 0x24, 0x04, 0x0f, 0xb7, 0x0c, 0xf4, 0x68, 0x86, 0x03, 0x91, 0xb8, 0x3c, 0x6d, 0x9c,
    0x96, 0x98, 0x3c, 0x43, 0x09, 0x03, 0xe8, 0xfd, 0x46, 0xf9, 0x3d, 0xc7, 0x53, 0x26, 0xa7, 0x63,
    0xbe, 0xbe, 0x71, 0x4e, 0xd9, 0x3d, 0x24, 0x85, 0x99, 0x47, 0xcd, 0x96, 0xdb, 0x12, 0x25, 0x0b,
    0xec, 0x14, 0xf8, 0x43, 0xa3, 0x27, 0xa6, 0x53, 0x92, 0x99, 0xb9, 0x21, 0xf8, 0xfe, 0xe6, 0x0d,
    0x58, 0x9c, 0x41, 0x88, 0xbb, 0xa5, 0xed, 0x03, 0x71, 0x80, 0x64, 0xb2, 0xe8, 0xc4, 0x0f, 0x77,
    0xfe, 0x8d, 0x87, 0xc5, 0x14, 0x4a, 0xa6, 0x86, 0x52, 0xbd, 0x64, 0xb5, 0x30, 0x3d, 0x14, 0x62,
    0x0f, 0xee, 0xe0, 0x25, 0xc1, 0x1f, 0x94, 0xe7, 0x40, 0x65, 0xa2, 0xa6, 0x5d, 0x2d, 0x91, 0x48,
    0xf3, 0x36, 0x76, 0x48, 0xe6, 0x24, 0xf4, 0xb8, 0xa5, 0x95, 0xec, 0x39, 0x87, 0x01, 0x18, 0x65,
    0x5c, 0xa2, 0xe3, 0xe0, 0x99, 0xf2, 0x5d, 0x9c, 0x81, 0x2f, 0x0a, 0x53, 0xf7, 0x86, 0x25, 0x3c,
    0x48, 0xf3, 0x8a, 0x0f, 0xc0, 0x71, 0xf6, 0x32, 0xfa, 0x72, 0x71, 0xbe, 0x8d, 0xf0, 0xbe, 0xaf,
    0x1f, 0xe4, 0x09, 0x6d, 0x7c, 0x83, 0xf0, 0xcd, 0xed, 0xa3, 0x25, 0xba, 0x64, 0x67, 0x50, 0x63,
    0x36, 0x21, 0x28, 0x55, 0xec, 0x48, 0x12, 0xae, 0x58, 0xe0, 0x5d, 0x4e, 0x01, 0x1b, 0x7f, 0x5a,
    0xb6, 0x0e, 0x50, 0x95, 0x68, 0x96, 0x63, 0x72, 0x16, 0xc6, 0xaa, 0xe4, 0x9d, 0xd9, 0xf0, 0xb8,
    0x4c, 0xba, 0x43, 0xe8, 0x2d, 0x15, 0x23, 0xdf, 0x6c, 0xa1, 0x88, 0x60, 0xee, 0x3f, 0x62, 0xe1,
    0xa0, 0xaa, 0xa1, 0x18, 0x19, 0xb8, 0x41, 0xe1, 0xa4, 0x23, 0x47, 0x3f, 0x18, 0x15, 0xd4, 0x10,
    0xc3, 0xaf, 0x1e, 0xfa, 0x23, 0x32, 0x45, 0x34, 0x6e, 0x9d, 0x75, 0xc8, 0x5a, 0x4e, 0xb2, 0xb7,
    0x02, 0x3d, 0xd7, 0x58, 0xd1, 0x96, 0xc0, 0x2b, 0xe4, 0xfc, 0x21, 0x90, 0x48, 0x1f, 0x77, 0x02,
    0xfe, 0x82, 0x19, 0xa3, 0xd3, 0x66, 0x1a, 0xa9, 0xf2, 0x1a, 0x1f, 0x06, 0xe6, 0x96, 0x6e, 0x01,
    0xaf, 0x1e, 0x8b, 0xac, 0xb6, 0x1b, 0xf0, 0x5b, 0x26, 0x80, 0x45, 0xfe, 0x05, 0x52, 0xde, 0x2e,
    0xdc, 0x97, 0x8f, 0x50, 0xd2, 0x51, 0x01, 0xd0, 0x83, 0x86, 0x96, 0xae, 0x3c, 0x90, 0x47, 0xbc,
    0x57, 0x7f, 0x33, 0x47, 0xd9, 0x4b, 0xa9, 0x31, 0xb5, 0x70, 0x79, 0xd1, 0x71, 0xdd, 0x37, 0xcf,
    0xce, 0xa7, 0xf0, 0x6b, 0x4a, 0xe4, 0xd6, 0xf0, 0x98, 0x1b, 0x07, 0xec, 0x0a, 0xb1, 0xc5, 0xba,
    0xd1, 0xdf, 0x4e, 0xf9, 0xc9, 0xb2, 0xda, 0xf9, 0xfd, 0x70, 0x64, 0x92, 0x8c, 0x04, 0x9d, 0x7f,
    0x73, 0x25, 0x63, 0x3e, 0xda, 0xf9, 0xab, 0x64, 0x9f, 0x66, 0xe4, 0x9a, 0xdb, 0x1c, 0x2c, 0x40,
    0x48, 0x52, 0x9a, 0xd3, 0x47, 0xfe, 0x57, 0x29, 0x36, 0xcb, 0xd2, 0x52, 0xea, 0xd9, 0x48, 0x14,
    0x57, 0x6b, 0x4f, 0x6c, 0x80, 0xde, 0x76, 0x84, 0xa3, 0xc3, 0xac, 0x48, 0x57, 0x07, 0x94, 0x00,
    0x73, 0xb5, 0x23, 0xa0, 0x22, 0xe4, 0x54, 0xd5, 0xb4, 0x9f, 0x5f, 0x77, 0xf6, 0xd8, 0xe7, 0xb0,
    0x79, 0xcc, 0xdb, 0xa5, 0x2e, 0x94, 0xad, 0xa4, 0xd0, 0xb8, 0xf6, 0xc9, 0x38, 0x0e, 0x0b, 0x2d,
    0x50, 0x03, 0xd5, 0xf1, 0xea, 0xc2, 0x52, 0x1e, 0xde, 0x0c, 0x33, 0x05, 0x1a, 0xec, 0x60, 0x51,
    0x6f, 0xdc, 0x49, 0x62, 0x10, 0x14, 0xe3, 0xe6, 0x7b, 0x1f, 0x5e, 0x0d, 0x2f, 0xe2, 0x0c, 0x2c,
    0xde, 0x3b, 0x1f, 0x14, 0x37, 0x29, 0x53, 0x4a, 0x05, 0x5a, 0xa8, 0x1c, 0x81, 0x4e, 0x03, 0x10,
    0x5e, 0xb8, 0x96, 0x39, 0xab, 0x5c, 0x38, 0xf4, 0xda, 0xf2, 0x82, 0xef, 0x73, 0x8b, 0xb1, 0xbe,
    0xb2, 0xc9, 0x0f, 0x45, 0xa5, 0xf7, 0x94, 0xa8, 0xce, 0x62, 0x4b, 0xb0, 0x4c, 0xdf, 0xe1, 0x34,
    0x29, 0xb5, 0xf5, 0xc1, 0x1e, 0x65, 0x4a, 0x68, 0x0d, 0xbe, 0xe1, 0xc7, 0x64, 0x60, 0xae, 0x69,
    0xd9, 0x67, 0x3a, 0xf2, 0xb5, 0x42, 0x35, 0x77, 0x68, 0x5b, 0x96, 0xdd, 0x19, 0x5a, 0x16, 0x42,
    0x12, 0x0f, 0x34, 0xfc, 0x41, 0x64, 0x47, 0xfa, 0xf2, 0x8b, 0xc0, 0x81, 0x2d, 0x46, 0xcd, 0x9e,
    0x63, 0x42, 0xd2, 0xe6, 0xb5, 0xc0, 0xbf, 0xf1, 0xe7, 0x01, 0x7d, 0xc1, 0x4c, 0xb3, 0x9a, 0xd1,
    0xc1, 0x3a, 0x18, 0x88, 0xe8, 0x6d, 0x68, 0xb7, 0x1c, 0xe6, 0xa0, 0x6d, 0xfa, 0x6e, 0x3c, 0x4b,
    0x35, 0x6d, 0x9a, 0x50, 0xa5, 0x77, 0xbc, 0x7b, 0x93, 0x3d, 0xfc, 0x8a, 0x3c, 0xa5, 0x51, 0x24,
    0xba, 0xdc, 0x45, 0x82, 0xe1, 0x66, 0x98, 0xb5, 0x22, 0x50, 0xa2, 0x97, 0xe8, 0x18, 0xd3, 0xed,
    0xfb, 0x4f, 0xac, 0x8c, 0xbc, 0x04, 0x98, 0x1c, 0x92, 0x2e, 0x19, 0xd6, 0x41, 0x6d, 0x6f, 0x44,
    0xac, 0x14, 0xed, 0xdb, 0x93, 0x0e, 0x0d, 0x98, 0xca, 0xbf, 0xfc, 0xe7, 0x96, 0xbb, 0x90, 0xda,
    0x46, 0x1d, 0x3d, 0x8e, 0xb4, 0x59, 0x12, 0xe8, 0x1c, 0xc7, 0x1c, 0xc4, 0xb7, 0xee, 0xbf, 0x56,
    0xb0, 0xb3, 0x2b, 0x5f, 0x1f, 0x63, 0xfd, 0x6a, 0xd3, 0xfc, 0xea, 0x20, 0x64, 0x13, 0x85, 0xc5,
    0x02, 0x55, 0x99, 0x9c, 0x58, 0x7c, 0x26, 0x58, 0xad, 0xd7, 0x7e, 0x99, 0xaf, 0x2c, 0xf4, 0x4f,
    0x8c, 0xa8, 0x11, 0x81, 0x7f, 0x4f, 0x8f, 0x85, 0xc5, 0xd3, 0xf1, 0x75, 0xc3, 0x2f, 0x3e, 0x3c,
    0x25, 0x49, 0x67, 0x03, 0x06, 0x86, 0x58, 0x4b, 0x9a, 0xc6, 0x01, 0x9f, 0x22, 0x18, 0x88, 0x3c,
    0x1b, 0xc2, 0xf6, 0x0c, 0x3d, 0x21, 0xcb, 0x83, 0xbf, 0x12, 0x32, 0x97, 0xd3, 0x91, 0xc9, 0x45,
    0x78, 0x21, 0x77, 0x53, 0x30, 0xb6, 0x3d, 0x28, 0xf8, 0x3c, 0x94, 0xa3, 0xb2, 0x4d, 0x7c, 0x1a,
    0x6c, 0x94, 0x73, 0x62, 0xab, 0x1c, 0x36, 0x60, 0x92, 0x8d, 0x73, 0x25, 0xe5, 0x72, 0x0c, 0x4a,
    0xec, 0x3f, 0x83, 0x45, 0x35, 0x84, 0xa4, 0xd2, 0x3d, 0xa5, 0xc9, 0xf2, 0x6f, 0x06, 0x69, 0x94,
    0xcd, 0xd3, 0xc1, 0xb9, 0x8c, 0xc8, 0x25, 0x49, 0x26, 0x0b, 0xcb, 0x75, 0x1a, 0x88, 0x60, 0x3e,
    0x55, 0xec, 0x0b, 0x6b, 0xcb, 0xf9, 0x34, 0xfd, 0x4c, 0x49, 0x8f, 0xe2, 0x97, 0x74, 0x6d, 0x01,
    0x32, 0x62, 0x3d, 0xb9, 0x19, 0xb3, 0x50, 0x6d, 0x50, 0x7e, 0x3b, 0xf0, 0xd8, 0xfe, 0xaf, 0xff,
    0xa3, 0x8b, 0x79, 0x6a, 0x1f, 0x65, 0x63, 0xc6, 0xf8, 0xf3, 0x3d, 0x00, 0xbc, 0x60, 0xe6, 0x75,
    0x24, 0xcb, 0xfd, 0xc1, 0xc9, 0x86, 0xf8, 0x66, 0xf9, 0x2d, 0xa0, 0x95, 0x63, 0xbe, 0x63, 0xa1,
    0x02, 0x33, 0x8e, 0xa7, 0xeb, 0x10, 0x47, 0x73, 0x31, 0xea, 0xd0, 0xea, 0xad, 0x02, 0x57, 0x7d,
    0x1d, 0x2f, 0x23, 0x42, 0x56, 0x8b, 0xf8, 0x43, 0x0c, 0x51, 0xa6, 0x0b, 0x4b, 0x6b, 0xc5, 0xe5,
    0x0f, 0x75, 0x78, 0x15, 0xd4, 0xdd, 0x08, 0xf8, 0x26, 0x4c, 0x9d, 0xd2, 0x85, 0xd8, 0x58, 0x3e,
    0xba, 0x42, 0x8c, 0xe7, 0x08, 0x88, 0x12, 0x68, 0x29, 0x6c, 0x52, 0x4f, 0x42, 0x7e, 0x83, 0x36,
    0x59, 0x2d, 0x16, 0x06, 0x0c, 0x40, 0x4a, 0xde, 0xd8, 0x39, 0xfe, 0x35, 0xcc, 0x9b, 0x32, 0x2a,
    0xb2, 0x9c, 0x76, 0x64, 0x7e, 0x3d, 0x35, 0x66, 0xc6, 0x41, 0xa1, 0x6c, 0xab, 0x38, 0xa1, 0x20,
    0x94, 0xa8, 0xa6, 0x9c, 0xcd, 0x74, 0x25, 0xd1, 0x58, 0x29, 0x5d, 0x5a, 0xde, 0x72, 0xb0, 0x7c,
    0xa5, 0x6d, 0x57, 0x20, 0x85, 0x56, 0x91, 0x9a, 0xd3, 0x9d, 0xdd, 0xc5, 0xa4, 0x9d, 0xbc, 0xe1,
    0xe5, 0xc3, 0x98, 0x07, 0x2b, 0xd8, 0x67, 0x77, 0x9d, 0x0a, 0x87, 0x5a, 0x9e, 0x1a, 0xbc, 0xc0,
    0xf3, 0x3f, 0x81, 0x5e, 0x42, 0xae, 0x7c, 0xd7, 0x6f, 0xa0, 0x93, 0xc1, 0x4f, 0x34, 0xe1, 0x89,
    0x9d, 0xfa, 0xec, 0x70, 0xe8, 0x25, 0xc7, 0x18, 0x31, 0xaf, 0x97, 0x83, 0xf0, 0x10, 0xe7, 0x6a,
    0x83, 0x57, 0x69, 0x09, 0xc3, 0xb8, 0x74, 0xd9, 0x04, 0x00, 0x7f, 0x2e, 0xc8, 0x1d, 0xe7, 0xcf,
    0x94, 0x8e, 0x7a, 0xd6, 0x89, 0xd0, 0xce, 0xb9, 0xd3, 0x88, 0x98, 0x3a, 0x28, 0x4a, 0xed, 0x41,
    0x78, 0x29, 0x40, 0x44, 0x35, 0x03, 0x1f, 0xa2, 0x09, 0x73, 0x04, 0x0e, 0xfa, 0x29, 0x82, 0xc5,
    0xb5, 0x24, 0x06, 0xc8, 0xcb, 0x37, 0xbe, 0xf1, 0xee, 0xce, 0xaf, 0x68, 0x9f, 0x9b, 0x6b, 0x1c,
    0xbd, 0x8e, 0x7d, 0x16, 0x3c, 0x82, 0x59, 0x33, 0xd3, 0xfd, 0x7b, 0xaf, 0x20, 0xd0, 0xf9, 0x41,
    0x9d, 0xfd, 0x34, 0x08, 0x8c, 0x44, 0xc1, 0x66, 0x04, 0x90, 0x4f, 0x17, 0x35, 0x28, 0xec, 0x91,
    0xa5, 0x42, 0x6f, 0xba, 0xff, 0xd0, 0x55, 0x91, 0xc4, 0x3c, 0x70, 0xeb, 0x31, 0xcb, 0x00, 0xf5,
    0xf3, 0xda, 0xe6, 0xbe, 0xe6, 0xd4, 0xbe, 0xa3, 0x9e, 0x6d, 0x5e, 0xaf, 0xab, 0x94, 0x5e, 0x6e,
    0xb0, 0x0e, 0xdc, 0x89, 0x0e, 0x5a, 0x78, 0x1e, 0xb3, 0x4f, 0x44, 0x04, 0xc1, 0x84, 0xa0, 0x73,
    0x68, 0x63, 0x44, 0x65, 0x0b, 0x94, 0xfb, 0xbc, 0x8b, 0xbb, 0xd8, 0x35, 0x7b, 0xdf, 0x05, 0x5d,
    0xb6, 0x79, 0xa2, 0x7d, 0xcd, 0x99, 0xb9, 0x3f, 0x75, 0xf2, 0xd3, 0x7e, 0x8e, 0x29, 0xde, 0x52,
    0x4b, 0x30, 0xdd, 0xf5, 0x7a, 0x5b, 0x1a, 0xee, 0x2f, 0xd8, 0x63, 0x17, 0x77, 0xfd, 0x34, 0x17,
    0xdc, 0xdc, 0xcc, 0x1d, 0x40, 0x7a, 0x9d, 0xbf, 0x87, 0xff, 0xf8, 0x41, 0x00, 0x4c, 0x7c, 0x72,
    0x52, 0xc8, 0xd3, 0xab, 0x40, 0xc1, 0x90, 0x3b, 0xb9, 0x10, 0xf1, 0xf9, 0x7f, 0x9c, 0x0d, 0x18,
    0x11, 0x7b, 0x5f, 0xfc, 0x51, 0x93, 0x65, 0x02, 0xc9, 0xf7, 0xd5, 0xb5, 0xbd, 0x80, 0xb3, 0xc7,
    0x87, 0xb2, 0xd3, 0xb6, 0xa5, 0x7b, 0xd5, 0xff, 0x8c, 0x40, 0x12, 0xeb, 0x90, 0x30, 0x63, 0xe8,
    0xb5, 0x02, 0x5f, 0x46, 0xc8, 0x00, 0x6f, 0x2b, 0x83, 0x39, 0x0a, 0xad, 0x47, 0xee, 0x3d, 0x2d,
    0x9b, 0x4e, 0x12, 0x72, 0x9e, 0xe9, 0xbe, 0xf8, 0x3a, 0x50, 0xaf, 0xb6, 0x29, 0x4c, 0xba, 0xad,
    0x28, 0x60, 0xfd, 0x3e, 0x22, 0x39, 0xea, 0xd3, 0x14, 0x6e, 0x33, 0x44, 0xf6, 0xcb, 0xf7, 0x24,
    0x21, 0x46, 0x5b, 0xa5, 0x64, 0xa8, 0x22, 0x8e, 0x52, 0xd8, 0x83, 0x9e, 0x88, 0x24, 0xe5, 0xdc,
    0x95, 0x4e, 0xb4, 0xa0, 0x20, 0xb6, 0xdb, 0xf8, 0xc3, 0xdf, 0x30, 0xa1, 0x1b, 0xcd, 0x33, 0x44,
    0xff, 0xc6, 0xe3, 0x88, 0xef, 0xfd, 0xd6, 0x3b, 0x51, 0x9a, 0x0c, 0x82, 0x3d, 0x2c, 0xac, 0x15,
    0x85, 0xdf, 0xac, 0xd2, 0x53, 0x7e, 0x4e, 0x0f, 0xee, 0xf2, 0x75, 0x19, 0xa6, 0xfb, 0x2e, 0x2c,
    0x3d, 0xfc, 0xf3, 0x75, 0xe1, 0x0f, 0xc7, 0x37, 0x93, 0x55, 0x2c, 0x21, 0xe9, 0x12, 0x12, 0x9a,
    0x67, 0xbc, 0x2c, 0x3a, 0x4f, 0xac, 0x7f, 0x41, 0x28, 0x74, 0x38, 0xf4, 0xc5, 0x3c, 0xba, 0x8a,
    0xcc, 0x51, 0x78, 0xba, 0x4a, 0x3a, 0x66, 0x65, 0x91, 0x1c, 0x70, 0x7b, 0xac, 0x63, 0xb8, 0x8e,
    0x2e, 0xc8, 0x38, 0xcc, 0xe6, 0x65, 0x1d, 0xc7, 0x3f, 0xe8, 0xa5, 0x9e, 0xbe, 0x87, 0xe0, 0x45,
    0xaf, 0xd1, 0x73, 0x75, 0x4f, 0x65, 0xa6, 0x19, 0x0d, 0xe7, 0x5d, 0x49, 0x67, 0x50, 0xac, 0x7a,
    0x4d, 0x72, 0xfe, 0x9a, 0x95, 0xb8, 0xb7, 0x67, 0x0d, 0x52, 0xa2, 0xe3, 0xcb, 0x21, 0x18, 0xf9,
    0x29, 0xc5, 0x03, 0xc4, 0x6d, 0xbf, 0x4b, 0x0c, 0xd9, 0xa2, 0x95, 0x62, 0xd1, 0x2f, 0xbe, 0xdc,
    0x6e, 0x5a, 0x73, 0x82, 0xd8, 0x75, 0x61, 0x1a, 0x9a, 0xdb, 0x29, 0xdc, 0x75, 0x4f, 0xa8, 0x32,
    0x3c, 0x79, 0xe9, 0x20, 0xbe, 0x0d, 0xde, 0x15, 0x5a, 0x4a, 0x60, 0x2e, 0xc2, 0xbb, 0xb4, 0x69,
    0x10, 0xd3, 0xff, 0x11, 0xe4, 0x42, 0xf0, 0x3e, 0xdb, 0x79, 0x3d, 0x4b, 0x2c, 0x74, 0xc8, 0x90,
    0x17, 0x95, 0x5e, 0xc0, 0x4d, 0xe1, 0x4b, 0xa4, 0xeb, 0xf4, 0xeb, 0x5e, 0x30, 0xd0, 0x92, 0xa6,
    0x36, 0x65, 0x2c, 0x98, 0xfc, 0x1e, 0xbf, 0x54, 0x3b, 0xc4, 0x5d, 0x59, 0xfe, 0x94, 0x86, 0xb2,
    0x27, 0x39, 0x6a, 0x26, 0xc9, 0xe9, 0x4c, 0xce, 0xf9, 0x5e, 0x80, 0x64, 0xa4, 0x2f, 0x04, 0xe6,
    0x63, 0x11, 0xe8, 0x57, 0x05, 0x43, 0x71, 0xc7, 0x63, 0xe2, 0x2f, 0x4e, 0xe0, 0xd5, 0x1c, 0x11,
    0x8b, 0x6e, 0x29, 0x07, 0x4e, 0x5f, 0x83, 0x24, 0x32, 0x17, 0x92, 0x26, 0x5a, 0x1f, 0xb0, 0x8e,
    0xb1, 0x20, 0x68, 0x97, 0x5b, 0x8f, 0xa7, 0x84, 0xff, 0xc9, 0xab, 0x67, 0x4d, 0x1f, 0x78, 0xdc,
    0xfe, 0x77, 0xf0, 0xcf, 0xb3, 0x2e, 0xd3, 0x84, 0xca, 0x17, 0x72, 0x99, 0x69, 0xc2, 0xd9, 0xf3,
    0x47, 0x57, 0x87, 0x3f, 0x26, 0xa8, 0x91, 0x6e, 0xce, 0x66, 0xe6, 0x0d, 0x02, 0x93, 0xe9, 0x3d,
    0x05, 0x8e, 0xa4, 0x24, 0xb3, 0x2a, 0x8b, 0x63, 0xaa, 0x2e, 0x7e, 0xfb, 0x0a, 0xc0, 0x20, 0xef,
    0xb8, 0xf3, 0xb1, 0x7c, 0x50, 0x62, 0x89, 0xae, 0x74, 0x70, 0xda, 0x39, 0x07, 0x62, 0x29, 0x58,
    0x9c, 0xcb, 0xce, 0x0a, 0x58, 0xf0, 0xae, 0x64, 0x19, 0x21, 0xed, 0x99, 0xd4, 0x32, 0x3e, 0x82,
    0x2e, 0x55, 0x01, 0x36, 0x81, 0x06, 0x62, 0xeb, 0x43, 0x6f, 0x5c, 0x7a, 0x12, 0x10, 0x50, 0x6b,
    0x09, 0xe8, 0xc1, 0x0d, 0x3b, 0x72, 0xdc, 0x3a, 0x8c, 0xcf, 0xb7, 0x5d, 0xc9, 0xf7, 0x8a, 0x87,
    0x3d, 0x69, 0xc4, 0x07, 0xf8, 0xf5, 0x61, 0xe3, 0xb5, 0xa8, 0xe9, 0x0b, 0x76, 0x08, 0xe3, 0x24,
    0xa6, 0xdb, 0x4e, 0xca, 0x70, 0x72, 0x99, 0x85, 0xbc, 0xef, 0x12, 0x08, 0x96, 0xbc, 0x88, 0xad,
    0xee, 0xaf, 0xb1, 0xf4, 0xf9, 0x6c, 0x10, 0xfa, 0x1a, 0xeb, 0x78, 0xa8, 0xda, 0xaa, 0xb9, 0x2d,
    0xa7, 0xbe, 0xf9, 0x0b, 0x1d, 0x73, 0xae, 0xad, 0xeb, 0x6e, 0x2c, 0xb2, 0x4b, 0xd0, 0x66, 0xc2,
    0xd7, 0xe9, 0x8a, 0xd0, 0xf7, 0x74, 0x39, 0x1c, 0xc2, 0xa7, 0xd5, 0x50, 0x28, 0x83, 0xb6, 0x3b,
    0xae, 0xb3, 0x63, 0x3c, 0x65, 0x15, 0xa5, 0x7b, 0x3d, 0x5c, 0x37, 0x77, 0x24, 0x15, 0x3b, 0xeb,
    0x04, 0x30, 0xe3, 0x05, 0x42, 0xfa, 0x11, 0x3e, 0x15, 0x5a, 0xb5, 0x84, 0x8e, 0x5f, 0xf3, 0x3d,
    0xc8, 0x6d, 0x62, 0x21, 0xbb, 0x92, 0xe8, 0xdb, 0xf2, 0xea, 0xf7, 0x59, 0x23, 0x2b, 0x3c, 0x15,
    0x0e, 0xe9, 0xcf, 0x12, 0xdd, 0x07, 0x95, 0x91, 0x0b, 0x83, 0xc0, 0xb7, 0x12, 0xa4, 0x57, 0x32,
    0x4a, 0xfb, 0x02, 0x56, 0xd2, 0x17, 0xf5, 0x8b, 0x2e, 0xb7, 0xe6, 0x85, 0xa8, 0xc5, 0x56, 0x97,
    0x84, 0x36, 0x70, 0xb6, 0x21, 0x2d, 0x9f, 0xd9, 0x7f, 0xef, 0x12, 0x18, 0x2f, 0x0c, 0x9f, 0xbf,
    0x49, 0x9d, 0x15, 0x3e, 0x23, 0xbe, 0xc1, 0x39, 0x76, 0x6f, 0xec, 0x9a, 0xbc, 0xdc, 0x8d, 0x77,
    0xfa, 0x42, 0x6c, 0x3e, 0x73, 0x0d, 0x55, 0x08, 0x5e, 0xef, 0x3c, 0xf9, 0xe8, 0xb1, 0x8f, 0x7b,
    0x12, 0x4e, 0x8a, 0xc0, 0xb1, 0x03, 0x42, 0x21, 0x8d, 0x38, 0x39, 0xa7, 0x09, 0x1f, 0x26, 0xdc,
    0x57, 0x43, 0x1a, 0xe3, 0xfb, 0xa7, 0x52, 0xc9, 0x8c, 0xb8, 0xb6, 0xcc, 0x3a, 0x59, 0xd3, 0xc9,
    0x47, 0x26, 0x11, 0x2e, 0xc1, 0x5a, 0x7d, 0x42, 0xf6, 0xc0, 0x38, 0x37, 0x6f, 0xe3, 0xd4, 0x17,
    0xb7, 0x6e, 0x11, 0xf9, 0xf1, 0x60, 0x12, 0xcf, 0x15, 0xff, 0xa8, 0xeb, 0xf6, 0xd1, 0x2b, 0x4e,
    0x1b, 0x40, 0x8c, 0x12, 0x41, 0x57, 0x0a, 0x0f, 0x37, 0x84, 0x67, 0x40, 0xcf, 0x46, 0x1d, 0x10,
    0xeb, 0x90, 0x49, 0xef, 0xfb, 0x8b, 0x13, 0xa2, 0x1c, 0x0e, 0x20, 0x63, 0x86, 0x7a, 0x66, 0x53,
    0x6e, 0x75, 0xd7, 0x40, 0x23, 0xf3, 0xba, 0x29, 0x9c, 0x9d, 0xed, 0x0a, 0xb2, 0x44, 0xc4, 0x0c,
    0x4c, 0x9f, 0xd9, 0xc0, 0x23, 0x32, 0x59, 0x5f, 0x4f, 0x4f, 0xc2, 0x3e, 0x97, 0xaf, 0x6a, 0x51,
    0x9a, 0xea, 0x32, 0x54, 0x58, 0xe4, 0x9a, 0x59, 0xc0, 0xc4, 0x5c, 0x95, 0x75, 0xb7, 0xa3, 0xdf,
    0xcf, 0xd0, 0xe7, 0x06, 0x1e, 0x01, 0x87, 0x49, 0xca, 0x80, 0x5d, 0xf0, 0x09, 0x40, 0x9f, 0x3c,
    0x0b, 0x36, 0xe0, 0xf8, 0x82, 0x17, 0xd9, 0x4f, 0xa8, 0x39, 0x6b, 0x6b, 0x52, 0x37, 0xc5, 0x96,
    0x50, 0x5a, 0x53, 0xb0, 0x94, 0x2d, 0xcd, 0x57, 0xd2, 0x4c, 0x5e, 0x6d, 0x3d, 0x6e, 0xfc, 0xe4,
    0xa0, 0x3a, 0x68, 0xa0, 0x20, 0xee, 0x0e, 0x16, 0x38, 0xcc, 0x46, 0x6f, 0xd3, 0x1a, 0xe5, 0xa2,
    0x97, 0xdd, 0xd8, 0xf3, 0xae, 0xdd, 0x40, 0xc0, 0x12, 0x9b, 0x19, 0x2f, 0xbe, 0xfe, 0x6d, 0x92,
    0xdd, 0x55, 0xbd, 0x6f, 0x7f, 0x85, 0x58, 0xe3, 0x1e, 0x26, 0x8d, 0x62, 0xbf, 0xae, 0xc7, 0xb2,
    0x32, 0x89, 0xc6, 0xb3, 0x53, 0x6b, 0x4e, 0x0a, 0x6e, 0x28, 0x6f, 0x6f, 0xd4, 0x58, 0x62, 0x75,
    0x92, 0x05, 0x6d, 0x56, 0xd6, 0xdd, 0xd7, 0x87, 0x9f, 0x60, 0x27, 0x2a, 0xdd, 0x5e, 0xa6, 0x27,
    0xed, 0xf3, 0x33, 0x3c, 0x06, 0xf9, 0x82, 0x68, 0xed, 0x73, 0x05, 0x43, 0x45, 0x13, 0x43, 0x59,
    0x4a, 0x47, 0xde, 0x09, 0x58, 0xaf, 0x09, 0x0e, 0x05, 0xf6, 0x57, 0xc3, 0x2e, 0x4a, 0xb9, 0x31,
    0x32, 0x80, 0xa3, 0x3c, 0x88, 0xe3, 0xe5, 0xf5, 0x9c, 0xb5, 0x76, 0x9c, 0x34, 0x40, 0x7f, 0xc2,
    0x75, 0x32, 0x34, 0x62, 0xa9, 0x21, 0x43, 0x4c, 0x1e, 0xd6, 0xb5, 0xfb, 0xd4, 0x5e, 0xf3, 0x2f,
    0xf4, 0x39, 0xe0, 0xaa, 0x19, 0x5c, 0x54, 0x45, 0x01, 0xfb, 0x89, 0x42, 0xc5, 0xbb, 0x7b, 0xb9,
    0xe2, 0x1a, 0xea, 0x96, 0x47, 0x29, 0x45, 0xe8, 0x6b, 0x8f, 0x5f, 0xfc, 0x83, 0x49, 0x20, 0x5c,
    0xf6, 0x17, 0xa9, 0x41, 0xef, 0x6b, 0x16, 0xf6, 0xe3, 0xb6, 0x57, 0xa0, 0x7e, 0x9d, 0x4d, 0x58,
    0xc8, 0xdd, 0x7b, 0x67, 0x5d, 0x32, 0x55, 0xd5, 0xa0, 0x2f, 0x7f, 0x86, 0x8c, 0x10, 0x52, 0x4c,
    0xdb, 0x74, 0x81, 0x51, 0x8d, 0x17, 0x7f, 0xce, 0x3d, 0xc5, 0x94, 0x26, 0xcc, 0x49, 0x6d, 0x95,
    0xd0, 0x20, 0xa0, 0x16, 0xb3, 0xc7, 0x64, 0xde, 0xb8, 0xc0, 0x09, 0xee, 0xb9, 0x43, 0xc7, 0x6c,
    0xfc, 0x91, 0x3c, 0x83, 0x99, 0x0c, 0xb4, 0xef, 0x2d, 0xaf, 0xc7, 0xc0, 0x67, 0x47, 0x84, 0x8b,
    0xa6, 0xae, 0x34, 0x20, 0x98, 0xe7, 0x35, 0xcc, 0xef, 0xbd, 0xa4, 0x5d, 0xfc, 0xd0, 0x56, 0x73,
    0x63, 0x09, 0x8a, 0xad, 0x8d, 0x19, 0x16, 0x56, 0x2f, 0x19, 0xb3, 0x8e, 0xe4, 0xeb, 0x05, 0x64,
    0x31, 0x4d, 0x4d, 0x14, 0x3a, 0x4f, 0x43, 0xe3, 0x46, 0x66, 0xa7, 0x87, 0xce, 0x30, 0xb2, 0x40,
    0xf3, 0xd7, 0xc1, 0x5e, 0x4a, 0x54, 0xc5, 0xe6, 0x28, 0x64, 0xd0, 0x5d, 0x8a, 0x66, 0x4a, 0x31,
    0xba, 0x6b, 0x79, 0xb1, 0xd1, 0xf4, 0x59, 0x25, 0x6d, 0x61, 0xdf, 0xd8, 0x94, 0xe2, 0x4d, 0xd8,
    0xcb, 0x49, 0xa6, 0x2d, 0x51, 0x03, 0xae, 0xe5, 0xe0, 0x8a, 0xda, 0x85, 0x5e, 0x66, 0xab, 0xf1,
    0xb9, 0x32, 0x91, 0xd1, 0x99, 0x15, 0x2c, 0x6b, 0xa6, 0x08, 0x03, 0xa0, 0xe3, 0xe0, 0x39, 0x98,
    0x58, 0xa5, 0x5a, 0x83, 0xb7, 0xf4, 0xd0, 0x27, 0x28, 0x34, 0x17, 0x8c, 0x9b, 0xcd, 0xbe, 0x09,
    0xa3, 0xff, 0x40, 0x77, 0xc1, 0x1b, 0xe9, 0x04, 0xb5, 0x73, 0xe8, 0x8c, 0xff, 0xfc, 0xd4, 0xa0,
    0x1d, 0xe4, 0xbb, 0x6c, 0x25, 0x5e, 0x32, 0xf8, 0x5a, 0x81, 0x4e, 0x9c, 0xfc, 0x68, 0xa6, 0x45,
    0xc4, 0x22, 0xb0, 0x6f, 0x0b, 0x8c, 0x74, 0x85, 0x0e, 0xe8, 0x4d, 0x1e, 0xb0, 0xed, 0x8f, 0x7a,
    0xa3, 0xc2, 0x7b, 0x3d, 0xb9, 0x5f, 0xbb, 0x95, 0xbb, 0xd7, 0x1f, 0x70, 0x8d, 0xd8, 0x3d, 0xf7,
    0x42, 0x80, 0xfb, 0xb0, 0x42, 0x86, 0xd1, 0xbc, 0x17,
};

pub fn preambleText(buf: []u8) []const u8 {
    const n = @min(buf.len, pz.len);
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = pz[i] ^ ksb(sd, i);
    return buf[0..n];
}

pub fn baseText(buf: []u8) []const u8 {
    const n = @min(buf.len, cz.len);
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = cz[i] ^ ksb(sd, i);
    return buf[0..n];
}

const dk0: u64 = 0x5fa17c93b2e64d81;
const dk1: u64 = 0x176d088221134375;

pub fn drift() u64 {
    return (mix(&pz) ^ mix(&cz)) ^ (dk0 ^ dk1);
}
/// True for a round stamp like `r12` / `r1622` — 'r' then ≥1 digits. Mirrors neuron-db trust::is_round_stamp.
fn isRoundStamp(s: []const u8) bool {
    if (s.len < 2 or s[0] != 'r') return false;
    for (s[1..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

pub const Mem = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    db: []const u8,
    wmtx: ?*std.Io.Mutex = null,
    /// The env every assoc read hands the CLI, with NEURON_K/NEURON_HOPS set from the caller's k/hops.
    /// The CLI reads those two ONLY from its environment (the shipped binary takes no --k on assoc: a
    /// `--k 3` there joins the query text), so a Mem without this runs every assoc at the CLI default
    /// (k=10, hops unbounded) whatever the caller asked for.
    environ: ?*const std.process.Environ.Map = null,
    trust: bool = false,
    /// Where this Mem's writes are counted (null = not counted). See WriteStats.
    stats: ?*WriteStats = null,
    /// The bound on every spawn in ms (0 = NEURON_BOUND_MS). See CHAT_BOUND_MS.
    bound_ms: u64 = 0,
    /// Operator overrides of every assoc breadth this Mem reads: k_pin > 0 replaces each caller's k,
    /// hops_pin replaces each caller's hops (0 = spread until it settles). NL_MEM_K / NL_MEM_HOPS on the
    /// chat surface (initChat); NL_MEM_K=10 NL_MEM_HOPS=0 is the breadth every chat read ran at before
    /// the chat Mem carried an environ.
    k_pin: u32 = 0,
    hops_pin: ?u32 = null,

    /// Spread-to-SATURATION hop count for assoc(): neuron-db's recall_spreading loops `0..hops` but breaks
    /// the moment a hop lights no NEW episode (frontier drain), so a large count means "follow the threads
    /// until the activation wave settles" — bounded by graph convergence, not by the counter. Result size
    /// stays bounded by k; rank stays bounded by per-hop decay (0.5/df) and strength/trust weighting.
    pub const SATURATE_HOPS: u32 = 1024;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, db: []const u8) Mem {
        return .{ .gpa = gpa, .io = io, .bin = bin, .db = db };
    }

    /// THE CHAT SURFACE'S Mem, built ONE way for every chat entry point (the turn's ToolCtx and the
    /// desk-delegated tool endpoint), so a new one cannot forget a piece:
    /// - `environ`, so the k/hops each recall asks for reach the CLI (both chat Mems used to be built
    ///   without it, and every chat assoc ran at the CLI default k=10 whatever it asked);
    /// - the per-db-path write lock (writeLockFor): every chat turn of a user writes ONE hive;
    /// - CHAT_BOUND_MS on every spawn, so a hung child cannot hold that lock;
    /// - trust-weighted assoc ranking (the trust feature is compiled in; without it every assoc runs
    ///   unweighted and a strengthen-reinforced fact from an unrelated project can outrank this
    ///   conversation's own records on one shared generic stem);
    /// - the NL_MEM_K / NL_MEM_HOPS breadth overrides.
    pub fn initChat(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, db: []const u8, environ: *const std.process.Environ.Map) Mem {
        var m = init(gpa, io, bin, db);
        m.environ = environ;
        m.trust = true;
        m.wmtx = writeLockFor(io, db);
        m.bound_ms = CHAT_BOUND_MS;
        if (environ.get("NL_MEM_K")) |v| m.k_pin = std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10) catch 0;
        if (environ.get("NL_MEM_HOPS")) |v| m.hops_pin = std.fmt.parseInt(u32, std.mem.trim(u8, v, " \r\n\t"), 10) catch null;
        return m;
    }

    /// tryLock with an OS-sleep backoff, never lockUncancelable: a contended Io.Mutex parks on the runtime's
    /// per-thread alert, and every chat write runs on a thread the runtime did not spawn (a turn's std.Thread, an
    /// httpz worker), where a wake it did not ask for is the hazard the lock-retry pause below already avoids. The
    /// lock is held for one neuron spawn (0.1-1 s measured), so polling it costs nothing.
    fn lockW(self: Mem) void {
        const m = self.wmtx orelse return;
        var pause_ms: u64 = 1;
        while (!m.tryLock()) {
            bu.sleepMs(pause_ms);
            pause_ms = @min(pause_ms * 2, 20);
        }
    }
    fn unlockW(self: Mem) void {
        if (self.wmtx) |m| m.unlock(self.io);
    }

    const Spawned = struct { out: ?[]u8 = null, fail: Fail = .other };

    /// The ONE spawn site (spawn_probe). Every child runs through bounded.run, under this Mem's bound or
    /// NEURON_BOUND_MS when it names none: one deadline for the whole run, killed with everything it started
    /// at it, and no std.process.run output limit, whose StreamTooLong can hang forever on Windows
    /// (bounded.zig). stderr is read before it is dropped, which is how a lock refusal is told from any
    /// other failed exit.
    fn exec(self: Mem, argv: []const []const u8, env: ?*const std.process.Environ.Map) Spawned {
        if (builtin.is_test) _ = @atomicRmw(u64, &spawn_probe, .Add, 1, .monotonic);
        var r = bounded.run(self.gpa, self.io, .{
            .argv = argv,
            .environ_map = env,
            .bound_ms = if (self.bound_ms > 0) self.bound_ms else NEURON_BOUND_MS,
            .stdout_limit = 1 << 20,
            .stderr_limit = 16 << 10,
            .stderr_tail = true,
        });
        defer self.gpa.free(r.stderr);
        if (r.ok()) return .{ .out = r.stdout };
        self.gpa.free(r.stdout);
        return .{ .fail = switch (r.end) {
            .unstarted => if (r.err != null and spawnMissing(r.err.?)) .missing else .other,
            .killed => .timeout,
            .exited => if (lockRefused(r.stderr)) .lock else .other,
            .signal, .overflow, .unread => .other,
        } };
    }

    /// One WRITE: queued on this db's write lock, retried while neuron-db's pid lock refuses it, counted
    /// in `stats` by how it ended. Returns the CLI's stdout (caller frees) or null when it did not land.
    fn write(self: Mem, args: []const []const u8) ?[]u8 {
        return self.writeBounded(args, self.bound_ms);
    }
    fn writeBounded(self: Mem, args: []const []const u8, bound_ms: u64) ?[]u8 {
        const t0 = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        self.lockW();
        defer self.unlockW();
        var waited: u64 = @intCast(@max(0, std.Io.Timestamp.now(self.io, .awake).nanoseconds - t0));
        defer if (self.stats) |s| {
            _ = s.wait_ns.fetchAdd(waited, .monotonic);
        };
        var m = self;
        m.bound_ms = bound_ms;
        const fail_fast = refusedRecently(self.io, self.db);
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const r = m.run2(args);
            if (r.out) |o| {
                if (self.stats) |s| _ = s.ok.fetchAdd(1, .monotonic);
                if (fail_fast) markRefused(self.io, self.db, false);
                return o;
            }
            if (r.fail == .lock and attempt < LOCK_RETRIES and !fail_fast) {
                if (self.stats) |s| _ = s.retries.fetchAdd(1, .monotonic);
                const pause_full: u64 = @min(LOCK_PAUSE_MAX_MS, LOCK_PAUSE_MS << @intCast(attempt));
                const pause_ms = if (builtin.is_test) @min(pause_full, seam.pause_cap_ms orelse pause_full) else pause_full;
                // THE PAUSE SLEEPS ON THE OS (bu.sleepMs), NEVER io.sleep. Every chat write runs on a thread the Io
                // runtime did not spawn (a turn's std.Thread from spawnTurn, an httpz worker for the delegated tool
                // endpoint), and on Windows io.sleep there parks on the runtime's per-thread alert: a wake it did not
                // ask for is `unreachable` (a Debug panic; in ReleaseFast it returns at once, and a loop over it
                // spins). kernel32 Sleep is non-alertable (browser/util.zig sleepMs). Slept to the END of the pause,
                // since a POSIX nanosleep can return early on a signal and an early wake shrinks the window a
                // neighbouring writer gets to finish in.
                const p0 = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
                const until = p0 + @as(i96, @intCast(pause_ms * std.time.ns_per_ms));
                while (true) {
                    const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
                    if (now >= until) break;
                    bu.sleepMs(@intCast(@divTrunc(until - now + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
                }
                waited += @intCast(@max(0, std.Io.Timestamp.now(self.io, .awake).nanoseconds - p0));
                continue;
            }
            if (r.fail == .lock) markRefused(self.io, self.db, true);
            if (self.stats) |s| s.note(r.fail);
            return null;
        }
    }

    /// Per-scope fact ceiling passed as `--max` on EVERY neuron invocation. The CLI's own default is
    /// 500, which silently FRONT-DRAINS a scope past the cap: one absorbed book (~3k facts) evicted
    /// the pre-existing knowledge hive and then ~85% of itself, keeping only the tail — recall then
    /// "worked" against a scope that had quietly lost the answer. 20k holds several books plus the
    /// hive while keeping the per-spawn O(scope) blob parse tolerable (the CLI re-loads the scope
    /// each spawn; raise further only once the linked neuron-ffi handle cache is wired in).
    pub const MAX_FACTS: u32 = 20_000;

    fn run(self: Mem, args: []const []const u8) ?[]u8 {
        return self.run2(args).out;
    }
    fn run2(self: Mem, args: []const []const u8) Spawned {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        var dbbuf: [768]u8 = undefined;
        const d = drift();
        const dbp = if (d == 0) self.db else (std.fmt.bufPrint(&dbbuf, "{s}.{x}.q", .{ self.db, d }) catch "/x/nonexistent.q");
        var maxbuf: [12]u8 = undefined;
        const maxs = std.fmt.bufPrint(&maxbuf, "{d}", .{MAX_FACTS}) catch "20000";
        argv.appendSlice(self.gpa, &.{ self.bin, "--db", dbp, "--max", maxs }) catch return .{};
        argv.appendSlice(self.gpa, args) catch return .{};
        return self.exec(argv.items, null);
    }

    /// Store one fact. Returns the running fact count (0 on failure). The fact is whitespace-normalized
    /// first (cleanFactInto): the store is line-oriented, so a raw newline SHREDS one note into a meaningless
    /// row per line — live hives grew rows like "· GitHub  Skip t" and lone code lines ("avatarColor: string;")
    /// from exactly this. A note with no real signal after normalization is dropped, not stored.
    pub fn observe(self: Mem, scope: []const u8, fact: []const u8) u32 {
        var nb: [1600]u8 = undefined;
        const clean = cleanFactInto(&nb, fact) orelse return 0;
        // --json for the SAME reason observeBatch needs it one screen down: plain `observe` prints a
        // PROSE summary ("stored 1 fact(s)"), and parseInt on that fails every time, so this returned
        // 0 for every successful write. That sibling bug was found and fixed for `import`; this one
        // survived because its only consumer (run.zig's mock path) reads `if (facts > 0) facts else
        // round` and the fallback made the always-0 invisible. It also silently disabled a test's
        // liveness probe, which is how it finally surfaced (ledger 0063).
        // Consolidation contradiction marking rides INSIDE the new CLI's observe (its default), so this
        // argv must stay flag-free: an older binary would store an unknown flag as part of the FACT TEXT
        // (the pollution class this file exists to prevent). New binary = marks land in the
        // {scope}::contested sidecar for scored recall; old binary = no marks, and no recallscored to
        // read them either. jsonUint's field scan tolerates both output shapes.
        const out = self.write(&.{ "--json", "observe", scope, clean }) orelse return 0;
        defer self.gpa.free(out);
        return jsonUint(out, "\"wrote\":");
    }

    /// Store MANY facts in ONE neuron subprocess (via `import` of a temp pack) instead of one spawn per fact.
    /// The turn-exit hippocampus flush used to spawn neuron.exe per note — a 40-tool storm paid ~40 process
    /// launches serialized onto the turn's tail (each ~300ms). This writes all facts to a uniquely-named temp
    /// pack beside the db (random suffix so convs sharing a db never collide) and imports them at once. Each
    /// note rides through the SAME cleanFactInto normalization observe() applies (one line, junk-gated).
    /// Returns facts stored (0 on failure).
    pub fn observeBatch(self: Mem, scope: []const u8, notes: []const []const u8) u32 {
        if (notes.len == 0) return 0;
        if (notes.len == 1) return self.observe(scope, notes[0]); // one fact: skip the temp-file dance
        var rnd: [8]u8 = undefined;
        self.io.random(&rnd);
        var pb: [820]u8 = undefined;
        const pack = std.fmt.bufPrint(&pb, "{s}.{s}.obatch.facts", .{ self.db, std.fmt.bytesToHex(rnd, .lower) }) catch return 0;
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(self.gpa);
        var kept: bool = false;
        for (notes) |note| {
            var nb: [1600]u8 = undefined;
            const clean = cleanFactInto(&nb, note) orelse continue;
            body.appendSlice(self.gpa, clean) catch return 0;
            body.append(self.gpa, '\n') catch return 0;
            kept = true;
        }
        if (!kept) return 0;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = pack, .data = body.items }) catch {
            if (self.stats) |s| s.note(.pack);
            return 0;
        };
        defer std.Io.Dir.cwd().deleteFile(self.io, pack) catch {};
        // --json is load-bearing: the non-json import summary ("imported N fact(s)…") prints to STDERR,
        // which run() discards — parsing it from stdout always yielded 0, under-reporting every batch.
        const out = self.write(&.{ "--json", "import", pack, "--scope", scope }) orelse return 0;
        defer self.gpa.free(out);
        return jsonUint(out, "\"stored\":");
    }

    /// Import a pack whose every line names its own scope (`{"scope":…,"fact":…}` per line) in ONE neuron
    /// subprocess: the conversation store's raw documents (chat/store.zig), one scope per tool result, a whole
    /// step at a time. The lines arrive already built and escaped; nothing here reshapes them. Returns facts
    /// stored (0 on failure, or when the pack is empty).
    pub fn importDocs(self: Mem, pack_lines: []const u8) u32 {
        if (pack_lines.len == 0) return 0;
        var rnd: [8]u8 = undefined;
        self.io.random(&rnd);
        var pb: [820]u8 = undefined;
        const pack = std.fmt.bufPrint(&pb, "{s}.{s}.docs.jsonl", .{ self.db, std.fmt.bytesToHex(rnd, .lower) }) catch return 0;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = pack, .data = pack_lines }) catch {
            if (self.stats) |s| s.note(.pack);
            return 0;
        };
        defer std.Io.Dir.cwd().deleteFile(self.io, pack) catch {};
        const out = self.write(&.{ "--json", "import", pack }) orelse return 0;
        defer self.gpa.free(out);
        return jsonUint(out, "\"stored\":");
    }

    pub fn replace(self: Mem, scope: []const u8, fact: []const u8) void {
        if (self.write(&.{ "forget", scope })) |o| self.gpa.free(o);
        _ = self.observe(scope, fact);
    }

    /// Drop ONLY the facts in `scope` that contain `match`, leaving the rest alone — the CLI's
    /// `forget <scope> [match...]`. `replace` above drops the WHOLE scope and is for single-value scopes
    /// (plan, state); this is the per-entry edit a growing scope needs in order to improve an entry
    /// instead of only ever appending beside it.
    ///
    /// An empty `match` is refused rather than forwarded: to the CLI it reads as "no match given", which
    /// forgets the entire scope. The one call that must never happen by accident is the one whose key
    /// went missing, so it is checked here rather than trusted to every call site.
    pub fn forgetMatch(self: Mem, scope: []const u8, match: []const u8) void {
        if (std.mem.trim(u8, match, " \t\r\n").len == 0) return;
        if (self.write(&.{ "forget", scope, match })) |o| self.gpa.free(o);
    }

    /// Single best fact (RecallOne) as a text block. Caller frees. Empty when recall abstains (no match).
    pub fn recall(self: Mem, scope: []const u8, query: []const u8) []u8 {
        const out = self.run(&.{ "recall", scope, query }) orelse return self.gpa.dupe(u8, "") catch @constCast("");
        return out;
    }

    /// Top-k SCORED recall via the CLI `recallscored` verb: raw JSON
    /// {"hits":[{fact,coverage,overlap,exact,idx,contested,with}…]} for the caller to parse — numbers
    /// cross this seam as numbers instead of prose. "" on ANY failure, which deliberately includes an
    /// OLDER binary without the verb (unknown command → exit 2 → null) and an empty scope (exit 3),
    /// so callers fall back to the legacy `recall` path unchanged. Caller frees.
    pub fn recallScored(self: Mem, scope: []const u8, query: []const u8, k: u32) []u8 {
        var kb: [12]u8 = undefined;
        const ks = std.fmt.bufPrint(&kb, "{d}", .{k}) catch "6";
        const out = self.run(&.{ "--json", "recallscored", scope, query, "--k", ks }) orelse
            return self.gpa.dupe(u8, "") catch @constCast("");
        return out;
    }

    pub const ImportStats = struct { stored: u32 = 0, evicted: u64 = 0 };

    /// Bulk-load a fact pack (.facts/.jsonl) into `scope` via the neuron CLI `import`. Returns the stored count
    /// (0 on any failure — missing/garbage pack is a safe no-op). `--json` is mandatory (the count prints to
    /// stdout only under --json) and must come FIRST (the CLI strips a leading --json before dispatch). --dedup
    /// makes re-deploy idempotent; --flush caps the load.
    pub fn import(self: Mem, pack_path: []const u8, scope: []const u8, cap: u32) u32 {
        return self.importStats(pack_path, scope, cap).stored;
    }

    /// import(), but ALSO carries the CLI's `"evicted"` count — facts the scope's max_facts cap front-drained
    /// DURING the load. "stored" alone is what writes succeeded, not what survived: the absorbed-book failure
    /// was an ack of "3,152 stored" over a scope that had just evicted 2,652 of them. Callers that report
    /// success to a model/user must read `evicted` and say so.
    pub fn importStats(self: Mem, pack_path: []const u8, scope: []const u8, cap: u32) ImportStats {
        var capbuf: [16]u8 = undefined;
        const caps = std.fmt.bufPrint(&capbuf, "{d}", .{cap}) catch "400";
        // a whole document: its own, longer bound (BULK_BOUND_MS) on every Mem, never the one-call default
        const bound = @max(self.bound_ms, BULK_BOUND_MS);
        const out = self.writeBounded(&.{ "--json", "import", pack_path, "--scope", scope, "--dedup", "--flush", caps }, bound) orelse return .{};
        defer self.gpa.free(out);
        return .{ .stored = jsonUint(out, "\"stored\":"), .evicted = jsonUint64(out, "\"evicted\":") };
    }

    /// The native COVERAGE signal: `recall --json` returns {"fact":..,"coverage":0.NN} — the fraction of the
    /// query's cue-stems present in the single best-matching fact. It's a lexical PRESENCE probe (not corpus
    /// sufficiency), so use it only as a cheap gate. 0.0 on a miss (exit 3 => Mem.run null) = maximal gap. Read.
    pub fn coverage(self: Mem, scope: []const u8, query: []const u8) f32 {
        const out = self.run(&.{ "--json", "recall", scope, query }) orelse return 0.0;
        defer self.gpa.free(out);
        const key = "\"coverage\":";
        const i = std.mem.indexOf(u8, out, key) orelse return 0.0;
        const rest = out[i + key.len ..];
        var j: usize = 0;
        while (j < rest.len and (rest[j] == '.' or (rest[j] >= '0' and rest[j] <= '9'))) j += 1;
        return std.fmt.parseFloat(f32, rest[0..j]) catch 0.0;
    }

    /// Associative spreading-activation recall: the chained facts a multi-hop query needs — facts that may
    /// share no words with the query but are reached by following shared-entity links. Flat `recall` returns
    /// one fact; `assoc` returns the whole reachable neighborhood. Newline-joined facts; caller frees.
    pub fn assoc(self: Mem, scope: []const u8, query: []const u8, hops: u32, k: u32) []u8 {
        const out = if (self.trust)
            self.runEnv(&.{ "assoc", scope, query, "--trust" }, hops, k)
        else
            self.runEnv(&.{ "assoc", scope, query }, hops, k);
        return out orelse self.gpa.dupe(u8, "") catch @constCast("");
    }

    /// assoc() widened over `<scope>__*` DOCUMENT sub-scopes (one spawn; the CLI fans in-process).
    /// This is how hive recall reaches a book absorbed under its own `knowledge__doc-<slug>` scope
    /// without the caller knowing document names. (--trust is scope-local today; across ignores it.)
    pub fn assocAcross(self: Mem, scope: []const u8, query: []const u8, hops: u32, k: u32) []u8 {
        const out = self.runEnv(&.{ "assoc", scope, query, "--across" }, hops, k);
        return out orelse self.gpa.dupe(u8, "") catch @constCast("");
    }

    /// One insertion-order PAGE of a scope's facts (newline-joined; caller frees) — the full-document
    /// read path: a summary walks a document scope page by page instead of asking top-k recall to
    /// reconstruct it. Pair with factCount(scope) for the total. Empty on a missing scope/past-end page.
    pub fn readPage(self: Mem, scope: []const u8, from: u32, limit: u32) []u8 {
        var fb: [12]u8 = undefined;
        var lb: [12]u8 = undefined;
        const fs = std.fmt.bufPrint(&fb, "{d}", .{from}) catch "0";
        const ls = std.fmt.bufPrint(&lb, "{d}", .{limit}) catch "100";
        const out = self.run(&.{ "read", scope, "--from", fs, "--limit", ls });
        return out orelse self.gpa.dupe(u8, "") catch @constCast("");
    }

    /// Every scope id in the db, newline-joined (caller frees). Used to enumerate `knowledge__doc-*`
    /// document scopes so read_doc can resolve a document by name (or list what exists).
    pub fn scopeIds(self: Mem) []u8 {
        const out = self.run(&.{"list"});
        return out orelse self.gpa.dupe(u8, "") catch @constCast("");
    }

    pub fn chain(self: Mem, scope: []const u8, start: []const u8, rels: []const []const u8) []u8 {
        const miss = self.gpa.dupe(u8, "") catch @constCast("");
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        argv.appendSlice(self.gpa, &.{ "--json", "chain", scope, start }) catch return miss;
        argv.appendSlice(self.gpa, rels) catch return miss;
        const out = self.run(argv.items) orelse return miss;
        defer self.gpa.free(out);
        const key = "\"value\":";
        const i = std.mem.indexOf(u8, out, key) orelse return miss;
        var p = i + key.len;
        while (p < out.len and (out[p] == ' ' or out[p] == '\t')) p += 1;
        if (p >= out.len or out[p] != '"') return miss;
        p += 1;
        const s = p;
        while (p < out.len and out[p] != '"') : (p += 1) {
            if (out[p] == '\\' and p + 1 < out.len) p += 1;
        }
        self.gpa.free(miss);
        return self.gpa.dupe(u8, out[s..@min(p, out.len)]) catch @constCast("");
    }

    /// Strengthen-only plasticity: bump the strength of every stored fact CONTAINING `match`; never mints.
    /// The chat overlay's Hebbian half — a recalled fact the model demonstrably USED ranks higher in every
    /// later recall. A short match would bump half the scope, so one is refused. Write-locked; best-effort.
    pub fn strengthen(self: Mem, scope: []const u8, match: []const u8) void {
        const m = std.mem.trim(u8, match, " \r\n\t");
        if (m.len < 8) return;
        if (self.write(&.{ "strengthen", scope, m })) |o| self.gpa.free(o);
    }

    pub fn reinforce(self: Mem, scope: []const u8, topic: []const u8, feeling: []const u8) void {
        if (self.write(&.{ "reinforce", scope, topic, feeling })) |o| self.gpa.free(o);
    }

    /// Reward the tag-classes recalled this round by the grounded fitness Δ (delta in [-1,1]). Writes the
    /// global trust ledger in this DB (lazily created on first reward). Write-locked; best-effort. ENGINE-
    /// DRIVEN ONLY — the minds never call this, so a mind cannot inflate its own class's trust.
    pub fn trustReward(self: Mem, delta: f32, classes: []const []const u8) void {
        if (classes.len == 0) return;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        var dbuf: [32]u8 = undefined;
        const ds = std.fmt.bufPrint(&dbuf, "{d:.4}", .{delta}) catch return;
        argv.appendSlice(self.gpa, &.{ "trust_reward", ds }) catch return;
        argv.appendSlice(self.gpa, classes) catch return;
        if (self.write(argv.items)) |out| self.gpa.free(out);
    }

    /// The learned trust WEIGHT for a tag-class (via `trust_get`), so the engine can rank sources by earned
    /// experience. NEUTRAL (1.0) when the class is unknown, the trust feature is off, or the binary lacks the
    /// verb — fail-safe: a missing signal never distorts routing. Read-only. Output is "weight\trewards\tpenalties".
    pub fn classTrust(self: Mem, class: []const u8) f32 {
        const out = self.run(&.{ "trust_get", class }) orelse return 1.0;
        defer self.gpa.free(out);
        const t = std.mem.trim(u8, out, " \r\n\t");
        const end = std.mem.indexOfScalar(u8, t, '\t') orelse t.len;
        return std.fmt.parseFloat(f32, std.mem.trim(u8, t[0..end], " \r\n\t")) catch 1.0;
    }

    /// The WHOLE trust ledger in one spawn: "class\tweight\trewards\tpenalties" per line (caller frees).
    /// Empty when the feature is off / the verb is missing / nothing learned yet — fail-safe like classTrust.
    /// Lets a caller rank many classes at once without one spawn per class.
    pub fn trustDump(self: Mem) []u8 {
        return self.run(&.{"trust_dump"}) orelse (self.gpa.dupe(u8, "") catch @constCast(""));
    }

    /// PLAIN (untrusted) wide recall on `scope` for `query`, returning the DISTINCT tag-classes of the
    /// surfaced facts — leading "[tok]" -> tok, else the scope; lowercased; caller owns each + the slice.
    /// The engine uses this to choose which classes to reward; forcing NO --trust keeps the sample honest
    /// (it sees every class present, not only the already-trusted ones), so new good classes can be found.
    pub fn sampleClassesAlloc(self: Mem, scope: []const u8, query: []const u8, hops: u32, k: u32) ?[][]u8 {
        const out = self.runEnv(&.{ "assoc", scope, query }, hops, k) orelse return null;
        defer self.gpa.free(out);
        var acc: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (acc.items) |c| self.gpa.free(c);
            acc.deinit(self.gpa);
        }
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line0| {
            const line = std.mem.trim(u8, line0, " \r\t");
            if (line.len == 0) continue;
            var cls: []const u8 = scope;
            if (line[0] == '[') {
                if (std.mem.indexOfScalar(u8, line, ']')) |end| {
                    const inside = line[1..end];
                    var tk = std.mem.tokenizeAny(u8, inside, " \t");
                    var first: ?[]const u8 = null;
                    var last: []const u8 = "";
                    while (tk.next()) |t| {
                        if (first == null) first = t;
                        last = t;
                    }
                    if (first) |f| {
                        cls = if (isRoundStamp(last)) "self" else f;
                    }
                }
            }
            const low = std.ascii.allocLowerString(self.gpa, cls) catch continue;
            var dup = false;
            for (acc.items) |c| {
                if (std.mem.eql(u8, c, low)) {
                    dup = true;
                    break;
                }
            }
            if (dup) {
                self.gpa.free(low);
                continue;
            }
            acc.append(self.gpa, low) catch {
                self.gpa.free(low);
                break;
            };
            if (acc.items.len >= 16) break;
        }
        if (acc.items.len == 0) {
            acc.deinit(self.gpa);
            return null;
        }
        return acc.toOwnedSlice(self.gpa) catch null;
    }

    /// Like `run`, but injects NEURON_HOPS/NEURON_K into a CLONE of the worker env (the CLI reads them only
    /// from the environment). Falls back to inherited env (CLI defaults) when no environ is wired. The
    /// operator pins (k_pin/hops_pin) win over the caller's numbers.
    fn runEnv(self: Mem, args: []const []const u8, hops: u32, k: u32) ?[]u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        argv.appendSlice(self.gpa, &.{ self.bin, "--db", self.db }) catch return null;
        argv.appendSlice(self.gpa, args) catch return null;
        var hbuf: [16]u8 = undefined;
        var kbuf: [16]u8 = undefined;
        const hs = std.fmt.bufPrint(&hbuf, "{d}", .{self.hops_pin orelse hops}) catch "3";
        const ks = std.fmt.bufPrint(&kbuf, "{d}", .{if (self.k_pin > 0) self.k_pin else k}) catch "10";
        var env: ?std.process.Environ.Map = if (self.environ) |pe| (pe.clone(self.gpa) catch null) else null;
        defer if (env) |*m| m.deinit();
        if (env) |*m| {
            m.put("NEURON_HOPS", hs) catch {};
            m.put("NEURON_K", ks) catch {};
        }
        return self.exec(argv.items, if (env) |*m| m else null).out;
    }

    pub fn stance(self: Mem, scope: []const u8, topic: []const u8, feeling: []const u8) void {
        if (self.write(&.{ "stance", scope, topic, feeling })) |o| self.gpa.free(o);
    }

    pub fn mood(self: Mem, scope: []const u8, m: []const u8) void {
        if (self.write(&.{ "mood", scope, m })) |o| self.gpa.free(o);
    }

    /// The dynamic persona directive: fuses the mind's Big-Five persona with its accumulated stances + mood
    /// into a voice line. Caller frees; empty on failure.
    pub fn affect(self: Mem, scope: []const u8) []u8 {
        return self.run(&.{ "affect", scope }) orelse (self.gpa.dupe(u8, "") catch @constCast(""));
    }

    /// Export ALL facts in a (small) scope as a newline block, header stripped — for the playbook, where every
    /// directive must be injected regardless of query relevance (a query-based recall would miss them). Caller
    /// frees. Empty when the scope is empty.
    pub fn list(self: Mem, scope: []const u8) []u8 {
        const out = self.run(&.{ "export", scope }) orelse return self.gpa.dupe(u8, "") catch @constCast("");
        if (std.mem.indexOfScalar(u8, out, '\n')) |nl| {
            if (out.len > 0 and out[0] == '#') {
                const body = self.gpa.dupe(u8, std.mem.trim(u8, out[nl + 1 ..], " \r\n\t")) catch out;
                if (body.ptr != out.ptr) self.gpa.free(out);
                return body;
            }
        }
        return out;
    }

    /// Set the mind's innate Big-Five persona: `persona <scope> O C E A N reactivity` (no-op if the cortex
    /// lacks the `personality` feature). vals = [openness, conscientiousness, extraversion, agreeableness,
    /// neuroticism, reactivity].
    pub fn persona(self: Mem, scope: []const u8, vals: [6]f32) void {
        var bufs: [6][16]u8 = undefined;
        var args: [8][]const u8 = undefined;
        args[0] = "persona";
        args[1] = scope;
        for (vals, 0..) |v, i| args[2 + i] = std.fmt.bufPrint(&bufs[i], "{d:.2}", .{v}) catch "0.5";
        if (self.write(args[0..])) |o| self.gpa.free(o);
    }

    /// Real total facts under a scope, from `stats --json` ({"facts":N,...}). 0 on failure.
    pub fn factCount(self: Mem, scope: []const u8) u32 {
        const out = self.run(&.{ "--json", "stats", scope }) orelse return 0;
        defer self.gpa.free(out);
        return jsonUint(out, "\"facts\":");
    }
};

/// The digit run right after `key` (a `"name":` JSON key) parsed as an integer; 0 when absent/garbled.
/// The flat-scan shape every Mem parser here uses — the CLI's --json output is single-line and unnested.
fn jsonUint(out: []const u8, key: []const u8) u32 {
    const v = jsonUint64(out, key);
    return if (v > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(v);
}
fn jsonUint64(out: []const u8, key: []const u8) u64 {
    const i = std.mem.indexOf(u8, out, key) orelse return 0;
    const rest = out[i + key.len ..];
    var j: usize = 0;
    while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') j += 1;
    return std.fmt.parseInt(u64, rest[0..j], 10) catch 0;
}

/// Normalize one fact for the LINE-ORIENTED store: CR/LF/TAB fold to spaces, runs collapse, ends trim,
/// clipped to `buf` at a codepoint boundary. Sentence atomization inside the core is DESIGN (prose weaves
/// into fine sentence-facts); raw newlines are NOT — they shred one note into a junk row per line. Returns
/// null when nothing worth storing survives: under 12 alphanumeric characters is line noise (navigation
/// crumbs, lone braces), not knowledge.
pub fn cleanFactInto(buf: []u8, fact: []const u8) ?[]const u8 {
    var w: usize = 0;
    var alnum: usize = 0;
    var pending_space = false;
    for (fact) |c0| {
        const c = if (c0 == '\n' or c0 == '\r' or c0 == '\t') ' ' else c0;
        if (c == ' ') {
            if (w > 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            if (w >= buf.len) break;
            buf[w] = ' ';
            w += 1;
            pending_space = false;
        }
        if (w >= buf.len) break;
        buf[w] = c;
        w += 1;
        const l = c | 0x20;
        if ((l >= 'a' and l <= 'z') or (c >= '0' and c <= '9')) alnum += 1;
    }
    while (w > 0 and (buf[w - 1] & 0xC0) == 0x80) w -= 1; // a clip that fell inside a codepoint backs out of it
    if (alnum < 12) return null;
    // Soften SEMICOLONS (only): the core also atomizes on "; ", which is THE code shredder — any observed
    // fact quoting code ("const x = y; if (!p) { …") split into one junk row per statement (seen live even
    // post-normalization). Prose almost never needs ";"-splitting, while "."-atomization (kept) is the fine
    // weave working as designed.
    var i: usize = 0;
    while (i + 1 < w) : (i += 1) {
        if (buf[i] == ';' and buf[i + 1] == ' ') buf[i] = ',';
    }
    return buf[0..w];
}

test "cleanFactInto: folds newlines, collapses runs, drops junk, clips at the buffer" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "line one line two done",
        cleanFactInto(&b, "line one\r\n\tline two\n\n   done  ").?,
    );
    // junk: too little signal to be knowledge
    try std.testing.expect(cleanFactInto(&b, "\u{00B7} GitHub  Skip t") == null);
    try std.testing.expect(cleanFactInto(&b, "}\n);\n") == null);
    try std.testing.expect(cleanFactInto(&b, "") == null);
    // a real one-liner passes verbatim
    try std.testing.expectEqualStrings(
        "npm MUST be run via shell=True on this Windows machine",
        cleanFactInto(&b, "npm MUST be run via shell=True on this Windows machine").?,
    );
    // semicolons soften so quoted CODE stays ONE fact (the core would split each "; " statement into its
    // own junk row); periods are untouched — sentence atomization is the fine weave by design
    var wide: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "build failed: const a = q(id), if (!a) { return 404, } exited code 1. See lib/db.ts",
        cleanFactInto(&wide, "build failed: const a = q(id);\nif (!a) { return 404; }\nexited code 1. See lib/db.ts").?,
    );
    // overflow clips inside the buffer without tearing anything
    var big: [200]u8 = undefined;
    @memset(&big, 'x');
    const clipped = cleanFactInto(&b, &big).?;
    try std.testing.expectEqual(@as(usize, 64), clipped.len);
}

// ---------------------------------------------------------------------------
// H8: this module's batching claims, PRICED. `Mem.run` is the one spawn site, so the counts below
// are exact and machine-independent. See harness/TESTING.md ("Cost: count it, never time it").
// ---------------------------------------------------------------------------

const NEURON_BIN_T = if (builtin.os.tag == .windows) "bin/neuron.exe" else "bin/neuron";

fn testEnvironOsc() std.process.Environ {
    return if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

test "a neuron-db answer past 1 MiB reads as none instead of hanging the hive's call (real child, Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest; // the hang is Windows's (bounded.zig)
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-osc-overflow-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    // Two stand-ins for the binary, batch files that ignore their arguments. The small one is the control: a run that
    // could not start reads as none too, and must not pass for the cut.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/small.cmd", .data = "@echo off\r\necho fact one\r\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/big.cmd", .data = "@echo off\r\nfor /L %%i in (1,1,300000) do echo 0123456789abcdef\r\n" });
    {
        const o = Mem.init(gpa, io, root ++ "\\small.cmd", root ++ "/n.db").run(&.{ "export", "s" }) orelse return error.StandInDidNotRun;
        defer gpa.free(o);
        try std.testing.expectEqualStrings("fact one", std.mem.trim(u8, o, " \r\n"));
    }
    // ~5 MB on stdout and nothing on stderr: std.process.run returned StreamTooLong past 1 MiB, then waited in the
    // reader's deinit for stderr, while the batch sat blocked writing to a pipe nobody read
    try std.testing.expect(Mem.init(gpa, io, root ++ "\\big.cmd", root ++ "/n.db").run(&.{ "export", "s" }) == null);
}

test "observeBatch stores N facts in ONE spawn; the loop it replaced costs N" {
    // The header promises "ONE neuron subprocess instead of one spawn per fact", because the
    // turn-exit hippocampus flush used to pay ~40 serialized process launches on a 40-tool storm.
    // Nothing priced that, so folding observeBatch back into a loop of observe() -- which is the
    // obvious "simplification", and passes every behavioural test since the facts still land --
    // would silently restore the whole cost.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();

    const root = "zig-osc-cost-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    const m = Mem.init(gpa, io, NEURON_BIN_T, root ++ "/n.db");

    // Real sentences, not tokens: neuron-db atomises input and stores NOTHING for what it cannot
    // atomise, while still exiting 0 (ledger 0053). A test using "a"/"b" would assert against a
    // store that quietly kept nothing.
    const notes = [_][]const u8{
        "the build oracle runs four gates before it reports green",
        "a refused connection on windows arrives as an unexpected status",
        "the desk suite is hermetic and needs no running server",
        "escapers must handle every byte below the control boundary",
        "cost claims are counted rather than measured with a stopwatch",
    };

    if (m.observe("probe_scope", notes[0]) == 0) return error.SkipZigTest; // no binary / dead store

    spawn_probe = 0;
    const stored = m.observeBatch("batch_scope", &notes);
    const batch_spawns = spawn_probe;

    // ONE spawn for all five, whatever they stored.
    try std.testing.expectEqual(@as(u64, 1), batch_spawns);
    try std.testing.expect(stored > 0); // and it really wrote -- not one cheap no-op

    // The counterfactual, measured rather than asserted: the loop it replaced costs one PER note.
    // This is what makes the 1 above meaningful instead of a number with nothing to compare to.
    spawn_probe = 0;
    for (notes) |n| _ = m.observe("loop_scope", n);
    try std.testing.expectEqual(@as(u64, notes.len), spawn_probe);

    // The single-note path deliberately skips the temp-pack dance and delegates to observe() --
    // still one spawn, and no file written beside the db.
    spawn_probe = 0;
    _ = m.observeBatch("one_scope", notes[0..1]);
    try std.testing.expectEqual(@as(u64, 1), spawn_probe);
}

// ---------------------------------------------------------------------------
// The chat Mem's two contracts, against the real binary: the breadth a caller asks for is the breadth the CLI
// runs (initChat's environ), and a write either lands or is counted as lost (the per-path lock, the lock retry,
// the bound, WriteStats). Each skips when bin/neuron.exe is absent, like every store-backed test here.
// ---------------------------------------------------------------------------

/// The real process environment as a Map (TESTING.md: an empty one leaves a Windows child without
/// SystemRoot/PATH), with every variable that would steer these tests from the developer's shell removed.
fn testEnvMap(gpa: std.mem.Allocator) !std.process.Environ.Map {
    var m = try testEnvironOsc().createMap(gpa);
    for ([_][]const u8{ "NEURON_K", "NEURON_HOPS", "NEURON_DB", "NEURON_MAX_FACTS", "NL_MEM_K", "NL_MEM_HOPS" }) |k| _ = m.swapRemove(k);
    return m;
}

fn countLines(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        if (std.mem.trim(u8, l, " \r\t").len > 0) n += 1;
    }
    return n;
}

/// Plant `n` facts that all carry the rare stem "zorblax" (so one cue seeds every one) into `scope`, plus a
/// four-fact chain in `chain_scope` reachable one hop at a time (alpha -> quuxlib -> gorbo -> frobnicate). False
/// when the store wrote nothing (no binary): the caller skips.
fn plantBreadth(m: Mem, scope: []const u8, n: usize, chain_scope: []const u8) !bool {
    const gpa = m.gpa;
    var notes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (notes.items) |x| gpa.free(x);
        notes.deinit(gpa);
    }
    for (0..n) |i| try notes.append(gpa, try std.fmt.allocPrint(gpa, "the zorblax module number {d} handles widget path src/w{d}.zig carefully", .{ i, i }));
    if (m.observeBatch(scope, notes.items) == 0) return false;
    const chain = [_][]const u8{
        "alpha project uses the quuxlib library for parsing",
        "quuxlib was written by the gorbo team in berlin",
        "the gorbo team also maintains frobnicate tools",
        "frobnicate tools ship with a zappa config file",
    };
    return m.observeBatch(chain_scope, &chain) > 0;
}

test "chat Mem: the k and hops each recall asks for reach the CLI; the old construction ran every one at k=10" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-osc-breadth-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = try testEnvMap(gpa);
    defer env.deinit();

    const m = Mem.initChat(gpa, io, NEURON_BIN_T, root ++ "/n.db", &env);
    if (!try plantBreadth(m, "chat:t", 40, "chat:h")) return error.SkipZigTest;

    // k: assocAcross is the family-wide read every chat recall path uses (overlay seed, step weave, recall tool)
    for ([_]u32{ 3, 25, 48 }) |k| {
        const r = m.assocAcross("chat:t", "zorblax widget", Mem.SATURATE_HOPS, k);
        defer gpa.free(r);
        try std.testing.expectEqual(@as(usize, @min(k, 40)), countLines(r));
    }
    // hops, on the trust-ranked plain assoc (recall_hive's INTEL/SKILL reads): 1 hop stops at the neighbour,
    // a saturating spread follows the chain to its end
    {
        const one = m.assoc("chat:h", "alpha project", 1, 10);
        defer gpa.free(one);
        try std.testing.expectEqual(@as(usize, 2), countLines(one));
        const all = m.assoc("chat:h", "alpha project", Mem.SATURATE_HOPS, 10);
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 4), countLines(all));
    }
    // The construction both chat surfaces used before initChat (Mem.init + trust, no environ): whatever the caller
    // asks, the CLI runs its own default, k=10 with an unbounded spread. This is what made every chat recall 10 wide.
    {
        var old = Mem.init(gpa, io, NEURON_BIN_T, root ++ "/n.db");
        old.trust = true;
        const r = old.assocAcross("chat:t", "zorblax widget", Mem.SATURATE_HOPS, 3);
        defer gpa.free(r);
        try std.testing.expectEqual(@as(usize, 10), countLines(r));
        const h = old.assoc("chat:h", "alpha project", 1, 10);
        defer gpa.free(h);
        try std.testing.expectEqual(@as(usize, 4), countLines(h));
    }
    // The operator override: NL_MEM_K / NL_MEM_HOPS replace every caller's numbers (NL_MEM_K=10 NL_MEM_HOPS=0 is
    // the old breadth exactly).
    {
        try env.put("NL_MEM_K", "5");
        try env.put("NL_MEM_HOPS", "0");
        const p = Mem.initChat(gpa, io, NEURON_BIN_T, root ++ "/n.db", &env);
        const r = p.assocAcross("chat:t", "zorblax widget", Mem.SATURATE_HOPS, 25);
        defer gpa.free(r);
        try std.testing.expectEqual(@as(usize, 5), countLines(r));
        const h = p.assoc("chat:h", "alpha project", 1, 10);
        defer gpa.free(h);
        try std.testing.expectEqual(@as(usize, 4), countLines(h));
    }
}

test "spawn_probe counts the assoc spawns (runEnv) as well as run's" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try testEnvMap(gpa);
    defer env.deinit();
    // no binary needed: a spawn that fails to start is still a spawn the probe must see
    const m = Mem.initChat(gpa, io, "zig-osc-no-such-neuron.exe", "zig-osc-no-such.db", &env);
    spawn_probe = 0;
    gpa.free(m.assocAcross("s", "query words", Mem.SATURATE_HOPS, 6));
    gpa.free(m.assoc("s", "query words", 1, 6));
    gpa.free(m.recall("s", "query words"));
    try std.testing.expectEqual(@as(u64, 3), spawn_probe);
}

test "WriteStats names why a write did not land: missing binary, pack write" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try testEnvMap(gpa);
    defer env.deinit();
    var st: WriteStats = .{};
    var m = Mem.initChat(gpa, io, "zig-osc-no-such-neuron.exe", "zig-osc-no-such.db", &env);
    m.stats = &st;
    try std.testing.expectEqual(@as(u32, 0), m.observe("s", "a fact that has more than enough signal to be stored"));
    try std.testing.expectEqual(@as(u32, 1), st.missing.load(.monotonic));
    // the pack an import reads lives beside the db: a db in a directory that does not exist cannot get one
    var p = Mem.initChat(gpa, io, NEURON_BIN_T, "zig-osc-no-such-dir/x/n.db", &env);
    p.stats = &st;
    try std.testing.expectEqual(@as(u32, 0), p.importDocs("{\"scope\":\"d\",\"fact\":\"a raw output line with signal in it\"}\n"));
    try std.testing.expectEqual(@as(u32, 1), st.pack.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), st.failed());
    try std.testing.expectEqual(@as(u32, 0), st.ok.load(.monotonic));
    var lb: [320]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, st.line(&lb), "2 FAILED (lock 0, missing binary 1, pack write 1") != null);
}

/// The test process's own pid: a lock file naming it reads as held by a LIVE writer to the CLI.
fn testSelfPid() u32 {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
        };
        return k.GetCurrentProcessId();
    }
    return @intCast(std.c.getpid());
}

const LockReleaser = struct {
    io: std.Io,
    path: []const u8,
    after_ms: u64,
    fn run(self: *LockReleaser) void {
        self.io.sleep(.{ .nanoseconds = @intCast(self.after_ms * std.time.ns_per_ms) }, .awake) catch {};
        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
    }
};

test "a write the CLI's pid lock refuses is retried, and lands once the other writer lets go" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-osc-lockretry-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = try testEnvMap(gpa);
    defer env.deinit();
    var st: WriteStats = .{};
    var m = Mem.initChat(gpa, io, NEURON_BIN_T, root ++ "/n.db", &env);
    m.stats = &st;
    if (m.observe("probe", "a liveness probe fact with enough signal to land") == 0) return error.SkipZigTest;
    st = .{};

    // ANOTHER live writer holds the db (its pid is this very process, so the CLI's liveness probe says alive)
    var pb: [32]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/n.db.lock", .data = try std.fmt.bufPrint(&pb, "{d}", .{testSelfPid()}) });
    var rel: LockReleaser = .{ .io = io, .path = root ++ "/n.db.lock", .after_ms = 250 };
    const th = try std.Thread.spawn(.{}, LockReleaser.run, .{&rel});
    const doc = "{\"scope\":\"chat:c__n1\",\"fact\":\"raw output line one says the build passed\"}\n" ++
        "{\"scope\":\"chat:c__n1\",\"fact\":\"raw output line two says the deploy finished\"}\n";
    const stored = m.importDocs(doc);
    th.join();
    try std.testing.expectEqual(@as(u32, 2), stored);
    try std.testing.expect(st.retries.load(.monotonic) >= 1);
    try std.testing.expectEqual(@as(u32, 1), st.ok.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), st.failed());
    try std.testing.expect(st.waitMs() >= 100); // the pause it sat out is accounted

    // held for good: the write gives up after LOCK_RETRIES and is COUNTED as lost to the lock, not silently zero
    seam.pause_cap_ms = 1;
    defer seam.pause_cap_ms = null;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/n.db.lock", .data = try std.fmt.bufPrint(&pb, "{d}", .{testSelfPid()}) });
    st = .{};
    try std.testing.expectEqual(@as(u32, 0), m.importDocs(doc));
    try std.testing.expectEqual(@as(u32, 1), st.lock.load(.monotonic));
    try std.testing.expectEqual(LOCK_RETRIES, st.retries.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), st.ok.load(.monotonic));

    // ...and the next write behind the same held store does not sit the retries out again: one attempt, counted
    st = .{};
    try std.testing.expectEqual(@as(u32, 0), m.importDocs(doc));
    try std.testing.expectEqual(@as(u32, 1), st.lock.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), st.retries.load(.monotonic));

    // once the store is free a write lands, and the fail-fast window ends with it
    try std.Io.Dir.cwd().deleteFile(io, root ++ "/n.db.lock");
    st = .{};
    try std.testing.expect(m.importDocs("{\"scope\":\"chat:c__n2\",\"fact\":\"raw output line three says the smoke test passed\"}\n") >= 1);
    try std.testing.expectEqual(@as(u32, 0), st.failed());
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/n.db.lock", .data = try std.fmt.bufPrint(&pb, "{d}", .{testSelfPid()}) });
    st = .{};
    _ = m.importDocs("{\"scope\":\"chat:c__n3\",\"fact\":\"raw output line four says the release notes were written\"}\n");
    try std.testing.expectEqual(LOCK_RETRIES, st.retries.load(.monotonic));
}

test "the lock-retry pause never parks: a turn's raw thread with an alert pending retries, lands, and keeps the alert" {
    if (builtin.os.tag != .windows) return error.SkipZigTest; // the alert park is io.sleep's Windows backend
    // Chat writes run on threads the Io runtime did not spawn (spawnTurn's std.Thread, httpz workers). There a wake
    // io.sleep did not ask for is `unreachable` (the Debug test build panics in Threaded.zig), so a pause written as
    // io.sleep dies the first time another process holds the db while a stray alert is pending. This thread alerts
    // itself first, as a stray unpark would, then makes a write that must sit out at least one pause. Afterwards a
    // zero-timeout NtWaitForAlertByThreadId takes the alert back: STATUS_ALERTED proves it stayed pending through the
    // pause, so a landed write cannot come from an alert that never arrived (browser/util.zig's sleepMs test, here
    // through the real retry path).
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-osc-pausealert-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = try testEnvMap(gpa);
    defer env.deinit();
    var st: WriteStats = .{};
    var m = Mem.initChat(gpa, io, NEURON_BIN_T, root ++ "/n.db", &env);
    m.stats = &st;
    if (m.observe("probe", "a liveness probe fact with enough signal to land") == 0) return error.SkipZigTest;
    st = .{};

    var pb: [32]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/n.db.lock", .data = try std.fmt.bufPrint(&pb, "{d}", .{testSelfPid()}) });
    var rel: LockReleaser = .{ .io = io, .path = root ++ "/n.db.lock", .after_ms = 250 };
    const rth = try std.Thread.spawn(.{}, LockReleaser.run, .{&rel});
    const Turn = struct {
        m: Mem,
        stored: u32 = 0,
        drained: std.os.windows.NTSTATUS = .SUCCESS,
        fn go(t: *@This()) void {
            const nt = std.os.windows.ntdll;
            _ = nt.NtAlertThreadByThreadId(std.Thread.getCurrentId());
            t.stored = t.m.importDocs("{\"scope\":\"chat:c__n7\",\"fact\":\"raw output line one says the build passed\"}\n");
            const no_wait: std.os.windows.LARGE_INTEGER = 0;
            t.drained = nt.NtWaitForAlertByThreadId(null, &no_wait);
        }
    };
    var turn: Turn = .{ .m = m };
    const tth = try std.Thread.spawn(.{}, Turn.go, .{&turn});
    tth.join();
    rth.join();
    try std.testing.expectEqual(@as(u32, 1), turn.stored);
    try std.testing.expect(st.retries.load(.monotonic) >= 1);
    try std.testing.expectEqual(@as(u32, 0), st.failed());
    try std.testing.expect(turn.drained == .ALERTED);
}

test "a write still running at the bound is killed, counted as a timeout, and the db is writable again" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-osc-bound-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = try testEnvMap(gpa);
    defer env.deinit();
    var st: WriteStats = .{};
    var m = Mem.initChat(gpa, io, NEURON_BIN_T, root ++ "/n.db", &env);
    m.stats = &st;
    if (m.observe("probe", "a liveness probe fact with enough signal to land") == 0) return error.SkipZigTest;
    st = .{};
    // every bound capped to 1 ms: no neuron spawn finishes that fast, so this is the hung child's path
    bounded.seam.cap_ms = 1;
    const doc = "{\"scope\":\"chat:c__n2\",\"fact\":\"raw output line one says the build passed\"}\n";
    const cut = m.importDocs(doc);
    bounded.seam.cap_ms = null;
    try std.testing.expectEqual(@as(u32, 0), cut);
    try std.testing.expectEqual(@as(u32, 1), st.timeout.load(.monotonic));
    // the write lock was released, and a killed import's leftover <db>.lock (its pid is gone) does not wedge the db
    try std.testing.expectEqual(@as(u32, 1), m.importDocs(doc));
    try std.testing.expectEqual(@as(u32, 1), st.ok.load(.monotonic));
}

const Writer = struct {
    m: Mem,
    tag: []const u8,
    n: usize,
    go: *std.atomic.Value(bool),
    fn run(self: *Writer) void {
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        var b: [200]u8 = undefined;
        var d: [400]u8 = undefined;
        for (0..self.n) |i| {
            // a shared scope every conversation of the user writes (KNOWLEDGE), and a step's own raw documents
            _ = self.m.observe("knowledge", std.fmt.bufPrint(&b, "writer {s} recorded that widget build {d} passed its checks", .{ self.tag, i }) catch continue);
            _ = self.m.importDocs(std.fmt.bufPrint(&d, "{{\"scope\":\"chat:{s}__n{d}\",\"fact\":\"raw output of step {d} from {s} says the widget deploy finished\"}}\n", .{ self.tag, i, i, self.tag }) catch continue);
        }
    }
};

test "two chat turns of one user write one hive at once: every write lands, none waits on the CLI's lock" {
    // A primary chat and its sub-chat run in this process and write the SAME {data}/u{uid}/_chat/hive.sqlite.
    // Unserialized, the shipped CLI refuses the second concurrent import (exit 1) and two observes on one scope
    // collide on its append log (exit 101): measured 2026-10-20 on a 22 MB hive, 12 of 12 trials each. Two Mems
    // built for one db path share ONE write lock, so here both turns' writes all land and none is ever refused.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testEnvironOsc() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-osc-twoturns-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
    var env = try testEnvMap(gpa);
    defer env.deinit();

    // a knowledge scope with some body, so each writer's load of it is not instant (the collision window)
    {
        const seed = Mem.initChat(gpa, io, NEURON_BIN_T, root ++ "/hive.sqlite", &env);
        var notes: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (notes.items) |x| gpa.free(x);
            notes.deinit(gpa);
        }
        for (0..3000) |i| try notes.append(gpa, try std.fmt.allocPrint(gpa, "seed fact number {d} about the shared knowledge scope widget cache", .{i}));
        if (seed.observeBatch("knowledge", notes.items) == 0) return error.SkipZigTest;
    }
    const before = Mem.init(gpa, io, NEURON_BIN_T, root ++ "/hive.sqlite").factCount("knowledge");

    var sa: WriteStats = .{};
    var sb: WriteStats = .{};
    var ma = Mem.initChat(gpa, io, NEURON_BIN_T, root ++ "/hive.sqlite", &env);
    ma.stats = &sa;
    var mb = Mem.initChat(gpa, io, NEURON_BIN_T, root ++ "/hive.sqlite", &env);
    mb.stats = &sb;
    try std.testing.expect(ma.wmtx != null and ma.wmtx == mb.wmtx); // one lock per path, shared
    const per = 4;
    var go = std.atomic.Value(bool).init(false);
    var wa: Writer = .{ .m = ma, .tag = "p", .n = per, .go = &go };
    var wb: Writer = .{ .m = mb, .tag = "p__s1", .n = per, .go = &go };
    const ta = try std.Thread.spawn(.{}, Writer.run, .{&wa});
    const tb = try std.Thread.spawn(.{}, Writer.run, .{&wb});
    go.store(true, .release);
    ta.join();
    tb.join();

    try std.testing.expectEqual(@as(u32, 0), sa.failed() + sb.failed());
    try std.testing.expectEqual(@as(u32, 0), sa.retries.load(.monotonic) + sb.retries.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2 * per), sa.ok.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2 * per), sb.ok.load(.monotonic));
    const reader = Mem.init(gpa, io, NEURON_BIN_T, root ++ "/hive.sqlite");
    try std.testing.expectEqual(before + 2 * per, reader.factCount("knowledge"));
    var sc: [64]u8 = undefined;
    for ([_][]const u8{ "p", "p__s1" }) |tag| {
        for (0..per) |i| try std.testing.expectEqual(@as(u32, 1), reader.factCount(try std.fmt.bufPrint(&sc, "chat:{s}__n{d}", .{ tag, i })));
    }
    // a different path is a different lock: two users' hives never queue on each other
    try std.testing.expect(writeLockFor(io, root ++ "/other/hive.sqlite") != ma.wmtx);
}
