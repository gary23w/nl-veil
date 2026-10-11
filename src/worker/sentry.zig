//! sentry.zig — the SENTRY: the veil as a working firewall and blue-team watch for the machine it is deployed on.
//!
//! Agent Garrett is the user's blue-team agent in the cloud: it looks OUT at domains, hashes and CVEs. The sentry
//! looks IN. It runs inside the server process on the user's own machine, and every minute (NL_SENTRY_EVERY) it
//! takes an inventory the operating system already knows how to give — what is listening and on which address,
//! which process holds it, where established connections go, what is wired to start at boot or on a schedule, and
//! whether the host firewall is on — diffs it against the baseline the user accepted, and writes what changed as
//! FINDINGS. A finding is a sentence with a severity, kept in a ring here and appended to {data}/_sentry/events.jsonl,
//! and the chat is told about the ones nobody has acknowledged, so the next question the user asks is answered by a
//! model that already knows a new port opened on their laptop last night.
//!
//! THE FIREWALL. A policy of allow/block rules lives in {data}/_sentry/policy.json. In the OBSERVE posture (the
//! default) the policy is a plan: nothing on the host changes. In the ENFORCE posture every rule is applied to the
//! host's own firewall — Windows Defender Firewall through `netsh advfirewall`, nftables on Linux in a table of our
//! own (`inet veil_sentry`), a pf anchor on macOS — each one named `veil-sentry:<id>` so the sentry can list,
//! reconcile and withdraw exactly what it added and never touch a rule it did not write. Switching back to observe
//! withdraws them all. With auto-block on, a new listener bound to a network address that is neither in the baseline
//! nor allowlisted is quarantined on sight: an inbound block for that port, named so the user (or the model) can lift
//! it with one call. The veil's own ports are never blocked, and nothing on loopback ever is.
//!
//! WHAT IT WILL NOT DO. It does not sniff traffic, inject into processes, or hide. Enforcement needs the rights the
//! OS demands for firewall changes (an elevated veil on Windows, root for nft and pf); without them it says so in
//! `last_error` and keeps observing. The first scan with no baseline ADOPTS the machine as it is — a fresh install
//! must not drown its user in a hundred findings about Windows services — and `baseline` re-adopts at any time.
//!
//! SHAPE. This file is std-only and pure where it can be: every parser takes text and returns rows, every command
//! is an argv array (never a shell string), and the diff is a function of two key sets. The surfaces are elsewhere:
//! the admin routes and the background thread in sentry_api.zig, the tool arms in tools.zig (every `sentry_*` verb
//! lands in `run` here), the branch in chat/belt.zig, `veil sentry` in cli/sentry.zig.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.sentry);

pub const DIR = "_sentry";
pub const RULE_PREFIX = "veil-sentry:";
pub const NFT_TABLE = "veil_sentry";
pub const PF_ANCHOR = "veil-sentry";
pub const MAX_RULES = 64;
pub const FIND_MAX = 256;
pub const ALLOW_MAX = 64;
pub const KEYS_MAX = 4096;
pub const DEFAULT_EVERY_S: u32 = 60;
pub const MIN_EVERY_S: u32 = 15;
pub const MAX_EVERY_S: u32 = 3600;
const TEXT_MAX = 240;
const ID_MAX = 24;
const REMOTE_MAX = 64;
const PROGRAM_MAX = 260;
const NOTE_MAX = 120;
const CMD_LIMIT: usize = 16 << 20;
const EVENTS_MAX_BYTES: u64 = 32 << 20;

/// Remote ports an outbound connection is expected to use. A connection to a PUBLIC address on any other port,
/// from a process that has not done so before, is a finding (new_outbound) — once per (process, port).
const COMMON_OUT_PORTS = [_]u16{ 80, 443, 53, 853, 123, 22, 993, 995, 587, 465, 25, 143, 110, 5228, 8080, 8443, 3478, 3479, 5223, 1194, 51820, 500, 4500 };

pub const Posture = enum { observe, enforce };
pub const Action = enum { allow, block };
pub const Dir = enum { in, out };
pub const Proto = enum { tcp, udp, any };
pub const Severity = enum(u8) { info = 0, low = 1, medium = 2, high = 3 };
pub const Kind = enum {
    new_listener,
    listener_gone,
    new_persistence,
    persistence_gone,
    firewall_off,
    firewall_on,
    new_outbound,
    rule_applied,
    rule_failed,
    rule_removed,
    quarantined,
    self_exposed,
    scan_error,
    baseline,
    posture,
};
pub const FwState = enum { on, off, partial, unknown };

/// One firewall rule of the policy. Fixed buffers: the policy is read on every scan from the sentry thread and
/// edited from request threads, and nothing handed out may dangle when it changes.
pub const Rule = struct {
    id: [ID_MAX]u8 = undefined,
    id_len: u8 = 0,
    action: Action = .block,
    dir: Dir = .in,
    proto: Proto = .tcp,
    port: u16 = 0,
    remote: [REMOTE_MAX]u8 = undefined,
    remote_len: u8 = 0,
    program: [PROGRAM_MAX]u8 = undefined,
    program_len: u16 = 0,
    note: [NOTE_MAX]u8 = undefined,
    note_len: u8 = 0,
    created: i64 = 0,
    auto: bool = false,
    on_host: bool = false,

    pub fn idStr(r: *const Rule) []const u8 {
        return r.id[0..r.id_len];
    }
    pub fn remoteStr(r: *const Rule) []const u8 {
        return r.remote[0..r.remote_len];
    }
    pub fn programStr(r: *const Rule) []const u8 {
        return r.program[0..r.program_len];
    }
    pub fn noteStr(r: *const Rule) []const u8 {
        return r.note[0..r.note_len];
    }
};

/// A rule as a caller spells it (tool arguments, the POST body, the CLI).
pub const RuleSpec = struct {
    id: []const u8 = "",
    action: []const u8 = "block",
    direction: []const u8 = "in",
    protocol: []const u8 = "tcp",
    port: u16 = 0,
    remote: []const u8 = "",
    program: []const u8 = "",
    note: []const u8 = "",
};

pub const Policy = struct {
    enabled: bool = false,
    posture: Posture = .observe,
    auto_block: bool = false,
    every_s: u32 = DEFAULT_EVERY_S,
    allow_ports: [ALLOW_MAX]u16 = undefined,
    allow_n: u8 = 0,
    rules: [MAX_RULES]Rule = undefined,
    rules_n: u8 = 0,

    pub fn allowed(p: *const Policy, port: u16) bool {
        for (p.allow_ports[0..p.allow_n]) |a| if (a == port) return true;
        return false;
    }
    pub fn find(p: *const Policy, id: []const u8) ?usize {
        for (p.rules[0..p.rules_n], 0..) |*r, i| if (std.mem.eql(u8, r.idStr(), id)) return i;
        return null;
    }
};

pub const Finding = struct {
    seq: u64 = 0,
    ts: i64 = 0,
    sev: Severity = .info,
    kind: Kind = .scan_error,
    text: [TEXT_MAX]u8 = undefined,
    text_len: u8 = 0,

    pub fn textStr(f: *const Finding) []const u8 {
        return f.text[0..f.text_len];
    }
};

pub const Listener = struct { proto: Proto, addr: []const u8, port: u16, pid: u32, name: []const u8 };
pub const Conn = struct { proto: Proto, raddr: []const u8, rport: u16, pid: u32, name: []const u8 };

/// One inventory of the host. Arena-owned: the rows borrow the command output they were cut from.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    listeners: std.ArrayListUnmanaged(Listener) = .empty,
    conns: std.ArrayListUnmanaged(Conn) = .empty,
    persist: std.ArrayListUnmanaged([]const u8) = .empty,
    fw: FwState = .unknown,
    fw_note: []const u8 = "",
    taken: i64 = 0,
    errors: u8 = 0,

    pub fn init(gpa: std.mem.Allocator) Snapshot {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }
    pub fn deinit(s: *Snapshot) void {
        s.arena.deinit();
    }
    pub fn alloc(s: *Snapshot) std.mem.Allocator {
        return s.arena.allocator();
    }
    pub fn exposedCount(s: *const Snapshot) usize {
        var n: usize = 0;
        for (s.listeners.items) |l| if (exposedAddr(l.addr)) {
            n += 1;
        };
        return n;
    }
};

/// How the sentry is wired to the process it lives in: the ports the veil itself listens on (never a finding,
/// never blocked), whether registration is open (a veil on network addresses with open signups is a
/// finding of its own), and the environment (startup folders live under %APPDATA% / %ProgramData%).
pub const Config = struct {
    own_ports: []const u16 = &.{},
    open_registration: bool = false,
    environ: ?*const std.process.Environ.Map = null,
    enabled_default: bool = false,
    every_default: u32 = DEFAULT_EVERY_S,
};

pub const ScanReport = struct {
    ran: bool = false,
    /// Another scan was already running; this caller did not wait for it (see Sentry.scan).
    busy: bool = false,
    new_findings: u32 = 0,
    listeners: u32 = 0,
    exposed: u32 = 0,
    conns: u32 = 0,
    persist: u32 = 0,
    fw: FwState = .unknown,
    err: []const u8 = "",
};

pub const Sentry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    data: []const u8,
    /// Guards policy, findings, baseline, noted, counters and the inventory text.
    mu: std.Io.Mutex = .init,
    /// One scan at a time. Held across the subprocesses, which is why it is not `mu`.
    scan_mu: std.Io.Mutex = .init,
    cfg: Config = .{},
    policy: Policy = .{},
    baseline: std.ArrayListUnmanaged([]u8) = .empty,
    noted: std.ArrayListUnmanaged([]u8) = .empty,
    findings: [FIND_MAX]Finding = undefined,
    find_head: usize = 0,
    find_len: usize = 0,
    seq: u64 = 0,
    acked: u64 = 0,
    scans: u32 = 0,
    last_scan: i64 = 0,
    last_fw: FwState = .unknown,
    last_listeners: u32 = 0,
    last_exposed: u32 = 0,
    last_conns: u32 = 0,
    last_persist: u32 = 0,
    applied: u32 = 0,
    enforce_ok: bool = true,
    last_err: [TEXT_MAX]u8 = undefined,
    last_err_len: u8 = 0,
    inventory: []u8 = &.{},
    rule_counter: u32 = 0,
    loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data: []const u8) Sentry {
        return .{ .gpa = gpa, .io = io, .data = data };
    }

    pub fn deinit(s: *Sentry) void {
        for (s.baseline.items) |k| s.gpa.free(k);
        s.baseline.deinit(s.gpa);
        for (s.noted.items) |k| s.gpa.free(k);
        s.noted.deinit(s.gpa);
        if (s.inventory.len > 0) s.gpa.free(s.inventory);
        s.inventory = &.{};
    }

    /// Wire the process facts in and read the files. NL_SENTRY=1 seeds `enabled` the first time (a machine set up
    /// unattended comes up watched); after that policy.json is the truth and the env var is ignored.
    pub fn configure(s: *Sentry, cfg: Config) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        s.cfg = cfg;
        const had_policy = s.loadLocked();
        if (!had_policy) {
            s.policy.enabled = cfg.enabled_default;
            s.policy.every_s = clampEvery(cfg.every_default);
            s.savePolicyLocked();
        }
        s.loaded = true;
    }

    // ------------------------------------------------------------------------------------------ state files

    fn pathOf(s: *Sentry, buf: []u8, leaf: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ s.data, DIR, leaf }) catch null;
    }

    fn ensureDir(s: *Sentry) void {
        var pb: [1024]u8 = undefined;
        const d = std.fmt.bufPrint(&pb, "{s}/{s}", .{ s.data, DIR }) catch return;
        _ = std.Io.Dir.cwd().createDirPathStatus(s.io, d, .default_dir) catch {};
    }

    fn writeAtomic(s: *Sentry, leaf: []const u8, body: []const u8) void {
        s.ensureDir();
        var pb: [1024]u8 = undefined;
        var tb: [1024]u8 = undefined;
        const path = s.pathOf(&pb, leaf) orelse return;
        const tmp = std.fmt.bufPrint(&tb, "{s}.tmp", .{path}) catch return;
        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(s.io, .{ .sub_path = tmp, .data = body }) catch return;
        cwd.rename(tmp, cwd, path, s.io) catch {
            cwd.deleteFile(s.io, tmp) catch {};
            cwd.writeFile(s.io, .{ .sub_path = path, .data = body }) catch {};
        };
    }

    fn readLeaf(s: *Sentry, alloc: std.mem.Allocator, leaf: []const u8, limit: usize) ?[]u8 {
        var pb: [1024]u8 = undefined;
        const path = s.pathOf(&pb, leaf) orelse return null;
        return std.Io.Dir.cwd().readFileAlloc(s.io, path, alloc, .limited(limit)) catch null;
    }

    /// policy.json + baseline.json + state.json. True when a policy file was there.
    fn loadLocked(s: *Sentry) bool {
        var had = false;
        if (s.readLeaf(s.gpa, "policy.json", 1 << 20)) |raw| {
            defer s.gpa.free(raw);
            if (parsePolicy(s.gpa, raw)) |p| {
                s.policy = p;
                had = true;
            }
        }
        if (s.readLeaf(s.gpa, "baseline.json", 4 << 20)) |raw| {
            defer s.gpa.free(raw);
            loadKeys(s.gpa, raw, "keys", &s.baseline);
        }
        if (s.readLeaf(s.gpa, "state.json", 4 << 20)) |raw| {
            defer s.gpa.free(raw);
            const St = struct { seq: u64 = 0, acked: u64 = 0, last_fw: []const u8 = "unknown", rule_counter: u32 = 0 };
            if (std.json.parseFromSlice(St, s.gpa, raw, .{ .ignore_unknown_fields = true })) |p| {
                defer p.deinit();
                s.seq = p.value.seq;
                s.acked = @min(p.value.acked, p.value.seq);
                s.rule_counter = p.value.rule_counter;
                s.last_fw = std.meta.stringToEnum(FwState, p.value.last_fw) orelse .unknown;
            } else |_| {}
            loadKeys(s.gpa, raw, "noted", &s.noted);
        }
        return had;
    }

    fn savePolicyLocked(s: *Sentry) void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.gpa);
        encodePolicy(s.gpa, &out, &s.policy) catch return;
        s.writeAtomic("policy.json", out.items);
    }

    fn saveBaselineLocked(s: *Sentry) void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.gpa);
        out.appendSlice(s.gpa, "{\"keys\":[") catch return;
        for (s.baseline.items, 0..) |k, i| {
            if (i > 0) out.append(s.gpa, ',') catch return;
            jstr(s.gpa, &out, k) catch return;
        }
        out.appendSlice(s.gpa, "]}\n") catch return;
        s.writeAtomic("baseline.json", out.items);
    }

    fn saveStateLocked(s: *Sentry) void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.gpa);
        out.print(s.gpa, "{{\"seq\":{d},\"acked\":{d},\"last_fw\":\"{s}\",\"rule_counter\":{d},\"noted\":[", .{ s.seq, s.acked, @tagName(s.last_fw), s.rule_counter }) catch return;
        for (s.noted.items, 0..) |k, i| {
            if (i > 0) out.append(s.gpa, ',') catch return;
            jstr(s.gpa, &out, k) catch return;
        }
        out.appendSlice(s.gpa, "]}\n") catch return;
        s.writeAtomic("state.json", out.items);
    }

    fn appendEvent(s: *Sentry, f: *const Finding) void {
        s.ensureDir();
        var pb: [1024]u8 = undefined;
        const path = s.pathOf(&pb, "events.jsonl") orelse return;
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(s.gpa);
        line.print(s.gpa, "{{\"seq\":{d},\"ts\":{d},\"severity\":\"{s}\",\"kind\":\"{s}\",\"text\":", .{ f.seq, f.ts, @tagName(f.sev), @tagName(f.kind) }) catch return;
        jstr(s.gpa, &line, f.textStr()) catch return;
        line.appendSlice(s.gpa, "}\n") catch return;
        appendFile(s.io, path, line.items, EVENTS_MAX_BYTES);
    }

    // ------------------------------------------------------------------------------------------ findings

    fn setErrLocked(s: *Sentry, msg: []const u8) void {
        const n = @min(msg.len, s.last_err.len);
        @memcpy(s.last_err[0..n], msg[0..n]);
        s.last_err_len = @intCast(n);
    }

    pub fn lastError(s: *const Sentry) []const u8 {
        return s.last_err[0..s.last_err_len];
    }

    /// Record one finding (under `mu`): a seq, the ring, the event file, the log.
    fn noteLocked(s: *Sentry, sev: Severity, kind: Kind, text: []const u8) void {
        s.seq += 1;
        var f = Finding{ .seq = s.seq, .ts = nowSecs(s.io), .sev = sev, .kind = kind };
        var n: usize = 0;
        for (text) |c| {
            if (n >= TEXT_MAX) break;
            f.text[n] = if (c < 0x20 or c == 0x7F) ' ' else c;
            n += 1;
        }
        f.text_len = @intCast(n);
        const slot = (s.find_head + s.find_len) % FIND_MAX;
        s.findings[slot] = f;
        if (s.find_len < FIND_MAX) s.find_len += 1 else s.find_head = (s.find_head + 1) % FIND_MAX;
        s.appendEvent(&f);
        switch (sev) {
            .high => log.warn("[{s}] {s}", .{ @tagName(kind), f.textStr() }),
            .medium => log.warn("[{s}] {s}", .{ @tagName(kind), f.textStr() }),
            else => log.info("[{s}] {s}", .{ @tagName(kind), f.textStr() }),
        }
    }

    fn noteFmt(s: *Sentry, sev: Severity, kind: Kind, comptime fmt: []const u8, args: anytype) void {
        var tb: [TEXT_MAX + 64]u8 = undefined;
        const t = std.fmt.bufPrint(&tb, fmt, args) catch tb[0..];
        s.noteLocked(sev, kind, t);
    }

    fn findingAt(s: *const Sentry, i: usize) *const Finding {
        return &s.findings[(s.find_head + i) % FIND_MAX];
    }

    pub fn openCount(s: *Sentry) u32 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.openCountLocked(.info);
    }

    fn openCountLocked(s: *const Sentry, min: Severity) u32 {
        var n: u32 = 0;
        var i: usize = 0;
        while (i < s.find_len) : (i += 1) {
            const f = s.findingAt(i);
            if (f.seq > s.acked and @intFromEnum(f.sev) >= @intFromEnum(min)) n += 1;
        }
        return n;
    }

    fn keyIn(list: *const std.ArrayListUnmanaged([]u8), key: []const u8) bool {
        for (list.items) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    fn keyAdd(s: *Sentry, list: *std.ArrayListUnmanaged([]u8), key: []const u8) void {
        if (keyIn(list, key) or list.items.len >= KEYS_MAX) return;
        const k = s.gpa.dupe(u8, key) catch return;
        list.append(s.gpa, k) catch s.gpa.free(k);
    }

    fn keyDrop(s: *Sentry, list: *std.ArrayListUnmanaged([]u8), key: []const u8) void {
        for (list.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            s.gpa.free(k);
            _ = list.orderedRemove(i);
            return;
        };
    }

    // ------------------------------------------------------------------------------------------ the scan

    /// Take an inventory, diff it, record what changed, reconcile the firewall. Safe from any thread; one at a
    /// time. `enabled` false ⇒ returns ran=false unless `force` (an explicit sentry_scan still answers).
    pub fn scan(s: *Sentry, force: bool) ScanReport {
        // ONE SCAN AT A TIME, AND NOBODY WAITS FOR ONE. A scan holds scan_mu across seconds of subprocesses, and its
        // callers are plain threads (this module's own loop, httpz workers, chat turns). A contended std.Io.Mutex
        // waiter parks on the thread's alert (Io.Threaded's parking futex on Windows) — the primitive behind the
        // 2026-09-02 desk freeze (desk/src/nap.zig), where an alert the runtime did not expect is undefined
        // behaviour off its own pool. So a second caller (sentry_scan while the background scan runs) returns at
        // once with `busy` and the last inventory instead of parking for the first scan's duration.
        if (!s.scan_mu.tryLock()) return .{ .busy = true };
        defer s.scan_mu.unlock(s.io);
        const pol = s.snapshotPolicy();
        if (!pol.enabled and !force) return .{};
        var snap = Snapshot.init(s.gpa);
        defer snap.deinit();
        capture(s.gpa, s.io, s.cfg.environ, &snap);
        snap.taken = nowSecs(s.io);
        var rep = ScanReport{ .ran = true, .listeners = @intCast(snap.listeners.items.len), .exposed = @intCast(snap.exposedCount()), .conns = @intCast(snap.conns.items.len), .persist = @intCast(snap.persist.items.len), .fw = snap.fw };

        // The firewall side first, outside `mu`: subprocesses again.
        var present: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (present.items) |p| s.gpa.free(p);
            present.deinit(s.gpa);
        }
        const enforcing = pol.enabled and pol.posture == .enforce;
        var fw_err: []const u8 = "";
        if (enforcing) {
            if (!backend.listPresent(s.gpa, s.io, s.data, &present)) fw_err = "could not list the host firewall's veil-sentry rules";
        }

        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const before = s.seq;
        s.scans += 1;
        s.last_scan = snap.taken;
        s.last_listeners = rep.listeners;
        s.last_exposed = rep.exposed;
        s.last_conns = rep.conns;
        s.last_persist = rep.persist;
        if (fw_err.len > 0) s.setErrLocked(fw_err);

        const adopting = s.baseline.items.len == 0;
        if (adopting) {
            s.adoptLocked(&snap);
            s.noteFmt(.info, .baseline, "baseline adopted from this machine as it is: {d} listeners ({d} on network addresses), {d} startup/scheduled entries", .{ snap.listeners.items.len, snap.exposedCount(), snap.persist.items.len });
        } else {
            s.diffLocked(&snap, enforcing);
        }
        if (snap.errors > 0 and s.scans == 1) s.noteFmt(.info, .scan_error, "{d} inventory command(s) could not run on this host; coverage is partial (see the module notes for what each OS needs)", .{snap.errors});
        s.fwLocked(&snap);
        if (enforcing and fw_err.len == 0) s.reconcileLocked(&present) else {
            for (s.policy.rules[0..s.policy.rules_n]) |*r| r.on_host = false;
            s.applied = 0;
        }
        s.renderInventoryLocked(&snap);
        s.saveStateLocked();
        rep.new_findings = @intCast(s.seq - before);
        rep.err = s.lastError();
        return rep;
    }

    fn snapshotPolicy(s: *Sentry) Policy {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.policy;
    }

    fn adoptLocked(s: *Sentry, snap: *const Snapshot) void {
        var kb: [512]u8 = undefined;
        for (snap.listeners.items) |l| s.keyAdd(&s.baseline, listenerKey(&kb, l));
        for (snap.persist.items) |p| s.keyAdd(&s.baseline, persistKey(&kb, p));
        for (snap.conns.items) |c| if (outboundKey(&kb, c)) |k| s.keyAdd(&s.baseline, k);
        s.saveBaselineLocked();
    }

    /// Everything the current inventory has that neither the baseline nor an earlier finding covers, and the
    /// baseline entries that are gone. Each key is reported once and then remembered in `noted`.
    fn diffLocked(s: *Sentry, snap: *const Snapshot, enforcing: bool) void {
        var kb: [512]u8 = undefined;
        for (snap.listeners.items) |l| {
            const key = listenerKey(&kb, l);
            if (keyIn(&s.baseline, key) or keyIn(&s.noted, key)) continue;
            s.keyAdd(&s.noted, key);
            const exposed = exposedAddr(l.addr);
            const own = s.isOwnPort(l.port);
            if (own) {
                if (exposed) s.noteFmt(if (s.cfg.open_registration) .medium else .low, .self_exposed, "the veil itself listens on {s}:{d} — on network addresses{s}", .{ l.addr, l.port, if (s.cfg.open_registration) " and registration is OPEN (set NL_BIND=127.0.0.1 or close signups)" else "" });
                continue;
            }
            if (s.policy.allowed(l.port)) {
                s.noteFmt(.info, .new_listener, "new {s} listener on {s}:{d} ({s}, pid {d}) — port is on the allowlist", .{ @tagName(l.proto), l.addr, l.port, l.name, l.pid });
                continue;
            }
            if (!exposed) {
                s.noteFmt(.low, .new_listener, "new {s} listener on loopback {s}:{d} ({s}, pid {d})", .{ @tagName(l.proto), l.addr, l.port, l.name, l.pid });
                continue;
            }
            s.noteFmt(.high, .new_listener, "NEW {s} listener on network address {s}:{d} ({s}, pid {d}) — not in the baseline; sentry_rule can block it, sentry_set baseline accepts it", .{ @tagName(l.proto), l.addr, l.port, l.name, l.pid });
            if (enforcing and s.policy.auto_block and l.proto != .any) s.quarantineLocked(l);
        }
        for (snap.persist.items) |p| {
            const key = persistKey(&kb, p);
            if (keyIn(&s.baseline, key) or keyIn(&s.noted, key)) continue;
            s.keyAdd(&s.noted, key);
            s.noteFmt(.medium, .new_persistence, "new startup/scheduled entry: {s}", .{clip(p, 180)});
        }
        for (snap.conns.items) |c| {
            const key = outboundKey(&kb, c) orelse continue;
            if (keyIn(&s.baseline, key) or keyIn(&s.noted, key)) continue;
            s.keyAdd(&s.noted, key);
            s.noteFmt(.medium, .new_outbound, "{s} (pid {d}) opened an outbound {s} connection to {s}:{d} — a port it has not used before", .{ c.name, c.pid, @tagName(c.proto), c.raddr, c.rport });
        }
        // Gone: baseline listeners and persistence entries that this inventory no longer has. Once each.
        var gb: [520]u8 = undefined;
        for (s.baseline.items) |k| {
            if (std.mem.startsWith(u8, k, "out|")) continue;
            if (snapshotHas(snap, k)) continue;
            const gone = std.fmt.bufPrint(&gb, "gone|{s}", .{k}) catch continue;
            if (keyIn(&s.noted, gone)) continue;
            s.keyAdd(&s.noted, gone);
            if (std.mem.startsWith(u8, k, "p|")) s.noteFmt(.info, .persistence_gone, "startup/scheduled entry from the baseline is gone: {s}", .{clip(k[2..], 180)}) else s.noteFmt(.info, .listener_gone, "baseline listener is gone: {s}", .{clip(k, 180)});
        }
    }

    fn fwLocked(s: *Sentry, snap: *const Snapshot) void {
        if (snap.fw == s.last_fw) return;
        const prev = s.last_fw;
        s.last_fw = snap.fw;
        switch (snap.fw) {
            .off => s.noteFmt(.high, .firewall_off, "the host firewall is OFF{s}", .{if (snap.fw_note.len > 0) snap.fw_note else ""}),
            .partial => s.noteFmt(.medium, .firewall_off, "the host firewall is off on at least one profile{s}", .{if (snap.fw_note.len > 0) snap.fw_note else ""}),
            .on => if (prev == .off or prev == .partial) s.noteFmt(.info, .firewall_on, "the host firewall is on again", .{}),
            .unknown => {},
        }
    }

    fn isOwnPort(s: *const Sentry, port: u16) bool {
        for (s.cfg.own_ports) |p| if (p == port) return true;
        return false;
    }

    // ------------------------------------------------------------------------------------------ rules

    /// Validate and add a rule. In the enforce posture it is applied to the host at once. Returns the id or a
    /// sentence saying what was wrong.
    pub fn addRule(s: *Sentry, spec: RuleSpec) union(enum) { id: []const u8, err: []const u8 } {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        if (s.policy.rules_n >= MAX_RULES) return .{ .err = "the policy holds 64 rules already; remove one first" };
        var r = Rule{};
        if (ruleFromSpec(&r, spec)) |e| return .{ .err = e };
        if (r.port != 0 and s.isOwnPort(r.port) and r.action == .block and r.dir == .in) return .{ .err = "that is one of the veil's own ports; the sentry never blocks itself" };
        if (r.id_len > 0 and s.policy.find(r.idStr()) != null) return .{ .err = "a rule with that id exists; remove it or pick another id" };
        if (r.id_len == 0) s.mintIdLocked(&r);
        if (r.id_len == 0 or s.policy.find(r.idStr()) != null) return .{ .err = "could not mint a rule id; pass one" };
        r.created = nowSecs(s.io);
        s.policy.rules[s.policy.rules_n] = r;
        s.policy.rules_n += 1;
        s.savePolicyLocked();
        const idx = s.policy.rules_n - 1;
        if (s.policy.enabled and s.policy.posture == .enforce) s.applyOneLocked(idx);
        s.saveStateLocked();
        return .{ .id = s.policy.rules[idx].idStr() };
    }

    pub fn removeRule(s: *Sentry, id: []const u8) bool {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const i = s.policy.find(id) orelse return false;
        const r = s.policy.rules[i];
        if (r.on_host or (s.policy.enabled and s.policy.posture == .enforce)) {
            if (!backend.remove(s.gpa, s.io, s.data, &r)) s.noteFmt(.low, .rule_failed, "could not withdraw rule {s} from the host firewall; it will be retried on the next scan", .{r.idStr()});
        }
        var j = i;
        while (j + 1 < s.policy.rules_n) : (j += 1) s.policy.rules[j] = s.policy.rules[j + 1];
        s.policy.rules_n -= 1;
        s.savePolicyLocked();
        s.noteFmt(.info, .rule_removed, "rule {s} removed ({s} {s} {s} port {d}{s}{s})", .{ r.idStr(), @tagName(r.action), @tagName(r.dir), @tagName(r.proto), r.port, if (r.remote_len > 0) " remote " else "", r.remoteStr() });
        s.saveStateLocked();
        return true;
    }

    fn mintIdLocked(s: *Sentry, r: *Rule) void {
        s.rule_counter += 1;
        const id = std.fmt.bufPrint(&r.id, "{s}-{s}-{s}-{d}-{d}", .{ @tagName(r.action), @tagName(r.dir), @tagName(r.proto), r.port, s.rule_counter }) catch {
            r.id_len = 0;
            return;
        };
        r.id_len = @intCast(@min(id.len, ID_MAX));
    }

    fn applyOneLocked(s: *Sentry, idx: usize) void {
        const r = &s.policy.rules[idx];
        var eb: [TEXT_MAX]u8 = undefined;
        if (backend.apply(s.gpa, s.io, s.data, r, &eb)) |err| {
            r.on_host = false;
            s.enforce_ok = false;
            s.setErrLocked(err);
            s.noteFmt(.medium, .rule_failed, "rule {s} could not be applied to the host firewall: {s}", .{ r.idStr(), err });
        } else {
            r.on_host = true;
            s.enforce_ok = true;
            s.last_err_len = 0;
            s.noteFmt(.info, .rule_applied, "rule {s} applied: {s} {s} {s} port {d}{s}{s}", .{ r.idStr(), @tagName(r.action), @tagName(r.dir), @tagName(r.proto), r.port, if (r.remote_len > 0) " remote " else "", r.remoteStr() });
        }
    }

    /// Enforce posture: every policy rule present on the host, nothing of ours on the host that the policy lacks.
    fn reconcileLocked(s: *Sentry, present: *const std.ArrayListUnmanaged([]u8)) void {
        var applied: u32 = 0;
        for (s.policy.rules[0..s.policy.rules_n], 0..) |*r, i| {
            var found = false;
            for (present.items) |p| if (std.mem.eql(u8, p, r.idStr())) {
                found = true;
            };
            if (found) {
                r.on_host = true;
                applied += 1;
            } else {
                s.applyOneLocked(i);
                if (r.on_host) applied += 1;
            }
        }
        for (present.items) |p| {
            if (s.policy.find(p) != null) continue;
            var stray = Rule{};
            const n = @min(p.len, ID_MAX);
            @memcpy(stray.id[0..n], p[0..n]);
            stray.id_len = @intCast(n);
            if (backend.remove(s.gpa, s.io, s.data, &stray)) s.noteFmt(.info, .rule_removed, "stray host rule {s}{s} withdrawn (not in the policy)", .{ RULE_PREFIX, stray.idStr() });
        }
        s.applied = applied;
    }

    fn quarantineLocked(s: *Sentry, l: Listener) void {
        var r = Rule{ .action = .block, .dir = .in, .proto = l.proto, .port = l.port, .auto = true };
        const id = std.fmt.bufPrint(&r.id, "auto-{s}-{d}", .{ @tagName(l.proto), l.port }) catch return;
        r.id_len = @intCast(id.len);
        if (s.policy.find(r.idStr()) != null or s.policy.rules_n >= MAX_RULES) return;
        const note = std.fmt.bufPrint(&r.note, "auto: {s} pid {d} on {s}", .{ l.name, l.pid, l.addr }) catch "";
        r.note_len = @intCast(@min(note.len, NOTE_MAX));
        r.created = nowSecs(s.io);
        s.policy.rules[s.policy.rules_n] = r;
        s.policy.rules_n += 1;
        s.savePolicyLocked();
        s.applyOneLocked(s.policy.rules_n - 1);
        if (s.policy.rules[s.policy.rules_n - 1].on_host) s.noteFmt(.high, .quarantined, "QUARANTINED: inbound {s} port {d} ({s}) is now blocked by rule {s}; sentry_rule op=remove id={s} lifts it", .{ @tagName(l.proto), l.port, l.name, r.idStr(), r.idStr() });
    }

    /// Withdraw every host rule of ours (observe posture, disable, shutdown). The policy keeps them.
    fn withdrawAllLocked(s: *Sentry) void {
        var any = false;
        for (s.policy.rules[0..s.policy.rules_n]) |*r| {
            if (r.on_host) any = true;
            r.on_host = false;
        }
        s.applied = 0;
        if (!any and !backend.enforceSupported()) return;
        _ = backend.withdrawAll(s.gpa, s.io, s.data, &s.policy);
    }

    // ------------------------------------------------------------------------------------------ settings

    pub const SetSpec = struct {
        enabled: ?bool = null,
        posture: ?[]const u8 = null,
        auto_block: ?bool = null,
        every_s: ?u32 = null,
        allow_port: ?u16 = null,
        disallow_port: ?u16 = null,
        baseline: ?bool = null,
        ack: ?bool = null,
        ack_upto: ?u64 = null,
    };

    /// Apply a settings change. Returns a sentence saying what was refused, or null.
    pub fn set(s: *Sentry, spec: SetSpec) ?[]const u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var changed = false;
        if (spec.posture) |p| {
            const want = std.meta.stringToEnum(Posture, p) orelse return "posture must be observe or enforce";
            if (want == .enforce and !backend.enforceSupported()) return "enforcement is not supported on this operating system; observe is";
            if (want != s.policy.posture) {
                if (want == .observe) s.withdrawAllLocked();
                s.policy.posture = want;
                changed = true;
                s.noteFmt(.info, .posture, "posture is now {s}{s}", .{ @tagName(want), if (want == .enforce) " — policy rules are applied to the host firewall on the next scan" else " — every veil-sentry rule has been withdrawn from the host firewall" });
            }
        }
        if (spec.enabled) |e| if (e != s.policy.enabled) {
            if (!e and s.policy.posture == .enforce) s.withdrawAllLocked();
            s.policy.enabled = e;
            changed = true;
            s.noteFmt(.info, .posture, "the sentry is {s}", .{if (e) "ON — watching this machine" else "OFF"});
        };
        if (spec.auto_block) |a| if (a != s.policy.auto_block) {
            s.policy.auto_block = a;
            changed = true;
        };
        if (spec.every_s) |e| {
            s.policy.every_s = clampEvery(e);
            changed = true;
        }
        if (spec.allow_port) |p| {
            if (p == 0) return "allow_port must be 1..65535";
            if (!s.policy.allowed(p)) {
                if (s.policy.allow_n >= ALLOW_MAX) return "the allowlist is full (64 ports)";
                s.policy.allow_ports[s.policy.allow_n] = p;
                s.policy.allow_n += 1;
                changed = true;
            }
        }
        if (spec.disallow_port) |p| {
            var i: usize = 0;
            while (i < s.policy.allow_n) : (i += 1) if (s.policy.allow_ports[i] == p) {
                var j = i;
                while (j + 1 < s.policy.allow_n) : (j += 1) s.policy.allow_ports[j] = s.policy.allow_ports[j + 1];
                s.policy.allow_n -= 1;
                changed = true;
                break;
            };
        }
        if (changed) s.savePolicyLocked();
        if (spec.baseline orelse false) {
            // Everything reported so far becomes the baseline: the user looked and said "that is my machine".
            for (s.noted.items) |k| {
                if (std.mem.startsWith(u8, k, "gone|")) {
                    s.keyDrop(&s.baseline, k[5..]);
                } else s.keyAdd(&s.baseline, k);
            }
            for (s.noted.items) |k| s.gpa.free(k);
            s.noted.clearRetainingCapacity();
            s.saveBaselineLocked();
            s.noteFmt(.info, .baseline, "baseline accepted: {d} entries; findings reported so far are no longer new", .{s.baseline.items.len});
            s.acked = s.seq;
        }
        if (spec.ack_upto) |u| {
            s.acked = @min(@max(s.acked, u), s.seq);
        } else if (spec.ack orelse false) s.acked = s.seq;
        s.saveStateLocked();
        return null;
    }

    // ------------------------------------------------------------------------------------------ views

    /// Status as JSON (gpa-owned). The one shape the route, the tool, the CLI and the desk all read.
    pub fn statusJson(s: *Sentry, gpa: std.mem.Allocator) []u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var o: std.ArrayListUnmanaged(u8) = .empty;
        defer o.deinit(gpa);
        o.print(gpa, "{{\"ok\":true,\"enabled\":{},\"posture\":\"{s}\",\"auto_block\":{},\"every_s\":{d},\"platform\":\"{s}\",\"enforce_supported\":{},\"enforce_ok\":{},\"firewall\":\"{s}\",\"last_scan\":{d},\"scans\":{d},\"listeners\":{d},\"exposed\":{d},\"connections\":{d},\"persistence\":{d},\"rules\":{d},\"applied\":{d},\"findings_open\":{d},\"findings_high_open\":{d},\"findings_total\":{d},\"acked\":{d},\"baseline\":{d},\"allow_ports\":[", .{ s.policy.enabled, @tagName(s.policy.posture), s.policy.auto_block, s.policy.every_s, @tagName(builtin.os.tag), backend.enforceSupported(), s.enforce_ok, @tagName(s.last_fw), s.last_scan, s.scans, s.last_listeners, s.last_exposed, s.last_conns, s.last_persist, s.policy.rules_n, s.applied, s.openCountLocked(.info), s.openCountLocked(.high), s.seq, s.acked, s.baseline.items.len }) catch return dupe(gpa, "{\"ok\":false}");
        for (s.policy.allow_ports[0..s.policy.allow_n], 0..) |p, i| o.print(gpa, "{s}{d}", .{ if (i > 0) "," else "", p }) catch {};
        o.appendSlice(gpa, "],\"own_ports\":[") catch {};
        for (s.cfg.own_ports, 0..) |p, i| o.print(gpa, "{s}{d}", .{ if (i > 0) "," else "", p }) catch {};
        o.appendSlice(gpa, "],\"last_error\":") catch {};
        jstr(gpa, &o, s.lastError()) catch {};
        o.append(gpa, '}') catch {};
        return o.toOwnedSlice(gpa) catch dupe(gpa, "{\"ok\":false}");
    }

    /// Findings newer than `since` (a seq), at or above `min`, newest last, at most `limit`. JSON array.
    pub fn findingsJson(s: *Sentry, gpa: std.mem.Allocator, since: u64, min: Severity, limit: usize) []u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var o: std.ArrayListUnmanaged(u8) = .empty;
        defer o.deinit(gpa);
        o.append(gpa, '[') catch {};
        // Walk from the newest back to collect at most `limit`, then emit oldest-first.
        var picked: [FIND_MAX]usize = undefined;
        var n: usize = 0;
        var i: usize = s.find_len;
        while (i > 0 and n < @min(limit, FIND_MAX)) {
            i -= 1;
            const f = s.findingAt(i);
            if (f.seq <= since or @intFromEnum(f.sev) < @intFromEnum(min)) continue;
            picked[n] = i;
            n += 1;
        }
        var k: usize = n;
        var first = true;
        while (k > 0) {
            k -= 1;
            const f = s.findingAt(picked[k]);
            if (!first) o.append(gpa, ',') catch {};
            first = false;
            o.print(gpa, "{{\"seq\":{d},\"ts\":{d},\"severity\":\"{s}\",\"kind\":\"{s}\",\"open\":{},\"text\":", .{ f.seq, f.ts, @tagName(f.sev), @tagName(f.kind), f.seq > s.acked }) catch {};
            jstr(gpa, &o, f.textStr()) catch {};
            o.append(gpa, '}') catch {};
        }
        o.append(gpa, ']') catch {};
        return o.toOwnedSlice(gpa) catch dupe(gpa, "[]");
    }

    pub fn rulesJson(s: *Sentry, gpa: std.mem.Allocator) []u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var o: std.ArrayListUnmanaged(u8) = .empty;
        defer o.deinit(gpa);
        o.append(gpa, '[') catch {};
        for (s.policy.rules[0..s.policy.rules_n], 0..) |*r, i| {
            if (i > 0) o.append(gpa, ',') catch {};
            o.print(gpa, "{{\"id\":\"{s}\",\"action\":\"{s}\",\"direction\":\"{s}\",\"protocol\":\"{s}\",\"port\":{d},\"remote\":", .{ r.idStr(), @tagName(r.action), @tagName(r.dir), @tagName(r.proto), r.port }) catch {};
            jstr(gpa, &o, r.remoteStr()) catch {};
            o.appendSlice(gpa, ",\"program\":") catch {};
            jstr(gpa, &o, r.programStr()) catch {};
            o.appendSlice(gpa, ",\"note\":") catch {};
            jstr(gpa, &o, r.noteStr()) catch {};
            o.print(gpa, ",\"created\":{d},\"auto\":{},\"on_host\":{}}}", .{ r.created, r.auto, r.on_host }) catch {};
        }
        o.append(gpa, ']') catch {};
        return o.toOwnedSlice(gpa) catch dupe(gpa, "[]");
    }

    /// The last inventory as JSON (gpa-owned copy): listeners, connections, persistence entries.
    pub fn inventoryJson(s: *Sentry, gpa: std.mem.Allocator) []u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return dupe(gpa, if (s.inventory.len > 0) s.inventory else "{\"ok\":true,\"taken\":0,\"listeners\":[],\"connections\":[],\"persistence\":[]}");
    }

    fn renderInventoryLocked(s: *Sentry, snap: *const Snapshot) void {
        var o: std.ArrayListUnmanaged(u8) = .empty;
        defer o.deinit(s.gpa);
        o.print(s.gpa, "{{\"ok\":true,\"taken\":{d},\"firewall\":\"{s}\",\"listeners\":[", .{ snap.taken, @tagName(snap.fw) }) catch return;
        for (snap.listeners.items, 0..) |l, i| {
            if (i > 0) o.append(s.gpa, ',') catch return;
            o.print(s.gpa, "{{\"proto\":\"{s}\",\"addr\":", .{@tagName(l.proto)}) catch return;
            jstr(s.gpa, &o, l.addr) catch return;
            o.print(s.gpa, ",\"port\":{d},\"pid\":{d},\"exposed\":{},\"own\":{},\"name\":", .{ l.port, l.pid, exposedAddr(l.addr), s.isOwnPort(l.port) }) catch return;
            jstr(s.gpa, &o, l.name) catch return;
            o.append(s.gpa, '}') catch return;
        }
        o.appendSlice(s.gpa, "],\"connections\":[") catch return;
        for (snap.conns.items, 0..) |c, i| {
            if (i > 0) o.append(s.gpa, ',') catch return;
            o.print(s.gpa, "{{\"proto\":\"{s}\",\"remote\":", .{@tagName(c.proto)}) catch return;
            jstr(s.gpa, &o, c.raddr) catch return;
            o.print(s.gpa, ",\"port\":{d},\"pid\":{d},\"public\":{},\"name\":", .{ c.rport, c.pid, !privateAddr(c.raddr) }) catch return;
            jstr(s.gpa, &o, c.name) catch return;
            o.append(s.gpa, '}') catch return;
        }
        o.appendSlice(s.gpa, "],\"persistence\":[") catch return;
        for (snap.persist.items, 0..) |p, i| {
            if (i > 0) o.append(s.gpa, ',') catch return;
            jstr(s.gpa, &o, p) catch return;
        }
        o.appendSlice(s.gpa, "]}") catch return;
        const owned = o.toOwnedSlice(s.gpa) catch return;
        if (s.inventory.len > 0) s.gpa.free(s.inventory);
        s.inventory = owned;
    }

    /// The line the chat's system prompt carries when the sentry is on: what posture, what the host firewall
    /// says, how many findings wait. Empty when off. Written into `buf`.
    pub fn doctrine(s: *Sentry, buf: []u8) []const u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        if (!s.policy.enabled) return "";
        const open = s.openCountLocked(.low);
        const high = s.openCountLocked(.high);
        return std.fmt.bufPrint(buf, "SENTRY: this machine's sentry is ON (posture {s}, auto-block {s}, host firewall {s}, {d} rule(s), last scan {s}). {d} finding(s) await review, {d} high. When the user asks about this machine's security, exposure, ports, startup items or the firewall, call sentry_status and sentry_findings FIRST and answer from them; sentry_rule changes the firewall policy, sentry_set changes posture or accepts the baseline. Never claim the machine is clean without reading the findings.", .{ @tagName(s.policy.posture), if (s.policy.auto_block) "on" else "off", @tagName(s.last_fw), s.policy.rules_n, if (s.last_scan > 0) "done" else "pending", open, high }) catch "";
    }

    pub fn enabled(s: *Sentry) bool {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.policy.enabled;
    }

    pub fn everySecs(s: *Sentry) u32 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.policy.every_s;
    }

    pub fn posture(s: *Sentry) Posture {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.policy.posture;
    }

    pub fn ackedSeq(s: *Sentry) u64 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.acked;
    }

    /// The seq just before the last `n` findings: what `since` must be to list exactly them.
    pub fn seqBefore(s: *Sentry, n: u32) u64 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return if (s.seq >= n) s.seq - n else 0;
    }
};

fn clampEvery(e: u32) u32 {
    return @min(@max(e, MIN_EVERY_S), MAX_EVERY_S);
}

fn snapshotHas(snap: *const Snapshot, key: []const u8) bool {
    var kb: [512]u8 = undefined;
    if (std.mem.startsWith(u8, key, "p|")) {
        for (snap.persist.items) |p| if (std.mem.eql(u8, persistKey(&kb, p), key)) return true;
        return false;
    }
    for (snap.listeners.items) |l| if (std.mem.eql(u8, listenerKey(&kb, l), key)) return true;
    return false;
}

// ------------------------------------------------------------------------------------------------- keys

/// A listener's identity across scans: pid changes on restart, so it is proto|addr|port|name.
pub fn listenerKey(buf: []u8, l: Listener) []const u8 {
    return std.fmt.bufPrint(buf, "{s}|{s}|{d}|{s}", .{ @tagName(l.proto), l.addr, l.port, clip(l.name, 80) }) catch buf[0..0];
}

pub fn persistKey(buf: []u8, p: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "p|{s}", .{clip(p, 400)}) catch buf[0..0];
}

/// An outbound connection worth remembering: public destination on an uncommon port, keyed by (process, port).
/// Null for everything routine (a browser on 443, a resolver on 53, anything on the LAN).
pub fn outboundKey(buf: []u8, c: Conn) ?[]const u8 {
    if (privateAddr(c.raddr)) return null;
    for (COMMON_OUT_PORTS) |p| if (p == c.rport) return null;
    if (c.rport == 0) return null;
    return std.fmt.bufPrint(buf, "out|{s}|{d}", .{ clip(c.name, 80), c.rport }) catch null;
}

/// A bind address another machine can reach: anything but loopback.
pub fn exposedAddr(a: []const u8) bool {
    const s = stripBrackets(a);
    if (std.mem.startsWith(u8, s, "127.")) return false;
    if (std.mem.eql(u8, s, "::1") or std.mem.eql(u8, s, "localhost")) return false;
    if (std.mem.startsWith(u8, s, "::ffff:127.")) return false;
    return true;
}

pub fn wildcardAddr(a: []const u8) bool {
    const s = stripBrackets(a);
    return std.mem.eql(u8, s, "0.0.0.0") or std.mem.eql(u8, s, "::") or std.mem.eql(u8, s, "*");
}

/// Loopback, link-local, RFC 1918, CGNAT, ULA: a destination on this machine or its network, not the internet.
pub fn privateAddr(a: []const u8) bool {
    var s = stripBrackets(a);
    if (std.mem.startsWith(u8, s, "::ffff:")) s = s["::ffff:".len..];
    if (s.len == 0 or std.mem.eql(u8, s, "*")) return true;
    if (std.mem.startsWith(u8, s, "127.") or std.mem.startsWith(u8, s, "10.") or std.mem.startsWith(u8, s, "192.168.") or std.mem.startsWith(u8, s, "169.254.") or std.mem.startsWith(u8, s, "0.")) return true;
    if (std.mem.eql(u8, s, "::1") or std.mem.eql(u8, s, "::")) return true;
    if (std.mem.startsWith(u8, s, "fe80:") or std.mem.startsWith(u8, s, "fc") or std.mem.startsWith(u8, s, "fd")) return true;
    if (std.mem.startsWith(u8, s, "172.")) {
        const rest = s[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;
        if (second >= 16 and second <= 31) return true;
    }
    if (std.mem.startsWith(u8, s, "100.")) {
        const rest = s[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;
        if (second >= 64 and second <= 127) return true;
    }
    return false;
}

fn stripBrackets(a: []const u8) []const u8 {
    if (a.len >= 2 and a[0] == '[' and a[a.len - 1] == ']') return a[1 .. a.len - 1];
    return a;
}

fn clip(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

// ------------------------------------------------------------------------------------------------- rule shape

/// Fill `r` from a spec. Returns the refusal, or null. Values travel as argv elements (never a shell string),
/// so this is about shape, not quoting: a port in range, an address made of address characters, a program path
/// without control characters, an id that is a slug.
pub fn ruleFromSpec(r: *Rule, spec: RuleSpec) ?[]const u8 {
    r.action = std.meta.stringToEnum(Action, spec.action) orelse return "action must be allow or block";
    r.dir = std.meta.stringToEnum(Dir, spec.direction) orelse return "direction must be in or out";
    r.proto = std.meta.stringToEnum(Proto, spec.protocol) orelse return "protocol must be tcp, udp or any";
    r.port = spec.port;
    const remote = std.mem.trim(u8, spec.remote, " \t\r\n");
    const program = std.mem.trim(u8, spec.program, " \t\r\n");
    if (r.port == 0 and remote.len == 0 and program.len == 0) return "a rule needs a port, a remote address or a program (or it would match everything)";
    if (r.port != 0 and r.proto == .any) return "a port needs a protocol: tcp or udp";
    if (remote.len > 0) {
        if (remote.len > REMOTE_MAX) return "remote is too long";
        if (!addrChars(remote)) return "remote must be an IP address or CIDR block (1.2.3.4, 10.0.0.0/8, 2001:db8::/32)";
        @memcpy(r.remote[0..remote.len], remote);
    }
    r.remote_len = @intCast(remote.len);
    if (program.len > 0) {
        if (program.len > PROGRAM_MAX) return "program path is too long";
        for (program) |c| if (c < 0x20 or c == 0x7F or c == '"') return "program must be an absolute executable path without quotes";
        @memcpy(r.program[0..program.len], program);
    }
    r.program_len = @intCast(program.len);
    const note = std.mem.trim(u8, spec.note, " \t\r\n");
    var nn: usize = 0;
    for (note) |c| {
        if (nn >= NOTE_MAX) break;
        r.note[nn] = if (c < 0x20 or c == 0x7F) ' ' else c;
        nn += 1;
    }
    r.note_len = @intCast(nn);
    const id = std.mem.trim(u8, spec.id, " \t\r\n");
    if (id.len > 0) {
        if (id.len > ID_MAX) return "id is too long (24 characters)";
        for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return "id may use letters, digits, - and _";
        @memcpy(r.id[0..id.len], id);
    }
    r.id_len = @intCast(id.len);
    return null;
}

fn addrChars(s: []const u8) bool {
    var digits: usize = 0;
    for (s) |c| {
        if (std.ascii.isDigit(c)) digits += 1;
        if (!(std.ascii.isHex(c) or c == '.' or c == ':' or c == '/')) return false;
    }
    return digits > 0 and (std.mem.indexOfScalar(u8, s, '.') != null or std.mem.indexOfScalar(u8, s, ':') != null);
}

fn isV6(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, ':') != null;
}

// ------------------------------------------------------------------------------------------------- policy JSON

fn parsePolicy(gpa: std.mem.Allocator, raw: []const u8) ?Policy {
    const R = struct { id: []const u8 = "", action: []const u8 = "block", direction: []const u8 = "in", protocol: []const u8 = "tcp", port: u16 = 0, remote: []const u8 = "", program: []const u8 = "", note: []const u8 = "", created: i64 = 0, auto: bool = false };
    const P = struct { enabled: bool = false, posture: []const u8 = "observe", auto_block: bool = false, every_s: u32 = DEFAULT_EVERY_S, allow_ports: []const u16 = &.{}, rules: []const R = &.{} };
    const parsed = std.json.parseFromSlice(P, gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    var p = Policy{};
    p.enabled = parsed.value.enabled;
    p.posture = std.meta.stringToEnum(Posture, parsed.value.posture) orelse .observe;
    p.auto_block = parsed.value.auto_block;
    p.every_s = clampEvery(parsed.value.every_s);
    for (parsed.value.allow_ports) |ap| {
        if (ap == 0 or p.allow_n >= ALLOW_MAX) continue;
        p.allow_ports[p.allow_n] = ap;
        p.allow_n += 1;
    }
    for (parsed.value.rules) |rr| {
        if (p.rules_n >= MAX_RULES) break;
        var r = Rule{};
        if (ruleFromSpec(&r, .{ .id = rr.id, .action = rr.action, .direction = rr.direction, .protocol = rr.protocol, .port = rr.port, .remote = rr.remote, .program = rr.program, .note = rr.note }) != null) continue;
        if (r.id_len == 0) continue;
        r.created = rr.created;
        r.auto = rr.auto;
        p.rules[p.rules_n] = r;
        p.rules_n += 1;
    }
    return p;
}

fn encodePolicy(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), p: *const Policy) !void {
    try out.print(gpa, "{{\"enabled\":{},\"posture\":\"{s}\",\"auto_block\":{},\"every_s\":{d},\"allow_ports\":[", .{ p.enabled, @tagName(p.posture), p.auto_block, p.every_s });
    for (p.allow_ports[0..p.allow_n], 0..) |ap, i| try out.print(gpa, "{s}{d}", .{ if (i > 0) "," else "", ap });
    try out.appendSlice(gpa, "],\"rules\":[");
    for (p.rules[0..p.rules_n], 0..) |*r, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "\n {{\"id\":\"{s}\",\"action\":\"{s}\",\"direction\":\"{s}\",\"protocol\":\"{s}\",\"port\":{d},\"remote\":", .{ r.idStr(), @tagName(r.action), @tagName(r.dir), @tagName(r.proto), r.port });
        try jstr(gpa, out, r.remoteStr());
        try out.appendSlice(gpa, ",\"program\":");
        try jstr(gpa, out, r.programStr());
        try out.appendSlice(gpa, ",\"note\":");
        try jstr(gpa, out, r.noteStr());
        try out.print(gpa, ",\"created\":{d},\"auto\":{}}}", .{ r.created, r.auto });
    }
    try out.appendSlice(gpa, "\n]}\n");
}

fn loadKeys(gpa: std.mem.Allocator, raw: []const u8, field: []const u8, into: *std.ArrayListUnmanaged([]u8)) void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const arr = parsed.value.object.get(field) orelse return;
    if (arr != .array) return;
    for (arr.array.items) |v| {
        if (v != .string or v.string.len == 0 or v.string.len > 512) continue;
        if (into.items.len >= KEYS_MAX) break;
        const k = gpa.dupe(u8, v.string) catch return;
        into.append(gpa, k) catch {
            gpa.free(k);
            return;
        };
    }
}

// ------------------------------------------------------------------------------------------------- the inventory

/// Fill `snap` from the host. Every command that cannot run bumps `errors` and leaves its rows empty; the scan
/// goes on with what it has.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map, snap: *Snapshot) void {
    // Every command's text is allocated in the SNAPSHOT'S ARENA, never freed on its own: the rows borrow slices of
    // it (an address, a process name) for as long as the snapshot lives. Measured 2026-10-11 on the first live
    // scan: freeing each output after its parse left every row pointing into memory the next command reused,
    // and the baseline was adopted from fragments of the schtasks CSV.
    _ = gpa;
    switch (builtin.os.tag) {
        .windows => {
            if (runCmd(snap.alloc(), io, &.{ "netstat", "-ano" }, CMD_LIMIT, 30)) |t| {
                parseNetstat(snap, t);
            } else snap.errors += 1;
            if (runCmd(snap.alloc(), io, &.{ "tasklist", "/fo", "csv", "/nh" }, CMD_LIMIT, 30)) |t| {
                nameByPid(snap, t, .tasklist);
            } else snap.errors += 1;
            if (runCmd(snap.alloc(), io, &.{ "netsh", "advfirewall", "show", "allprofiles", "state" }, 64 << 10, 20)) |t| {
                snap.fw = parseNetshProfiles(t);
                if (snap.fw != .on) snap.fw_note = " (netsh advfirewall show allprofiles state)";
            } else snap.errors += 1;
            const hives = [_][]const u8{ "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce", "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce" };
            const tags = [_][]const u8{ "run:HKCU", "runonce:HKCU", "run:HKLM", "runonce:HKLM" };
            for (hives, tags) |h, tag| {
                if (runCmd(snap.alloc(), io, &.{ "reg", "query", h }, 1 << 20, 20)) |t| {
                    parseRegRun(snap, t, tag);
                }
                // an absent RunOnce key is normal: reg exits 1, which run() reports as null — not an error here
            }
            if (runCmd(snap.alloc(), io, &.{ "schtasks", "/query", "/fo", "csv", "/nh" }, CMD_LIMIT, 60)) |t| {
                parseSchtasks(snap, t);
            } else snap.errors += 1;
            if (environ) |env| {
                if (env.get("APPDATA")) |ad| listDirInto(io, snap, ad, "\\Microsoft\\Windows\\Start Menu\\Programs\\Startup", "startup:user");
                if (env.get("ProgramData")) |pd| listDirInto(io, snap, pd, "\\Microsoft\\Windows\\Start Menu\\Programs\\StartUp", "startup:all");
            }
        },
        .linux => {
            if (runCmd(snap.alloc(), io, &.{ "ss", "-tunapH" }, CMD_LIMIT, 30)) |t| {
                parseSs(snap, t);
            } else snap.errors += 1;
            if (runCmd(snap.alloc(), io, &.{ "ufw", "status" }, 64 << 10, 20)) |t| {
                if (std.mem.indexOf(u8, t, "Status: active") != null) snap.fw = .on else if (std.mem.indexOf(u8, t, "Status: inactive") != null) {
                    snap.fw = .off;
                    snap.fw_note = " (ufw status: inactive)";
                }
            }
            if (snap.fw == .unknown) {
                if (runCmd(snap.alloc(), io, &.{ "nft", "list", "ruleset" }, CMD_LIMIT, 20)) |t| {
                    snap.fw = if (std.mem.indexOf(u8, t, "hook input") != null) .on else .off;
                    if (snap.fw == .off) snap.fw_note = " (no nftables input hook; run the veil as root if this is wrong)";
                }
            }
            if (runCmd(snap.alloc(), io, &.{ "crontab", "-l" }, 1 << 20, 20)) |t| {
                parseCrontab(snap, t, "cron:user");
            }
            if (runCmd(snap.alloc(), io, &.{ "systemctl", "list-unit-files", "--state=enabled", "--no-legend", "--no-pager" }, 4 << 20, 30)) |t| {
                parseUnitFiles(snap, t, "unit:system");
            } else snap.errors += 1;
            if (runCmd(snap.alloc(), io, &.{ "systemctl", "--user", "list-unit-files", "--state=enabled", "--no-legend", "--no-pager" }, 4 << 20, 30)) |t| {
                parseUnitFiles(snap, t, "unit:user");
            }
            listDirInto(io, snap, "/etc/cron.d", "", "cron.d");
            if (environ) |env| if (env.get("HOME")) |home| listDirInto(io, snap, home, "/.config/autostart", "autostart");
        },
        .macos => {
            if (runCmd(snap.alloc(), io, &.{ "lsof", "-nP", "-iTCP", "-iUDP" }, CMD_LIMIT, 60)) |t| {
                parseLsof(snap, t);
            } else snap.errors += 1;
            if (runCmd(snap.alloc(), io, &.{ "/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate" }, 64 << 10, 20)) |t| {
                if (std.mem.indexOf(u8, t, "enabled") != null) snap.fw = .on else if (std.mem.indexOf(u8, t, "disabled") != null) {
                    snap.fw = .off;
                    snap.fw_note = " (Application Firewall: disabled)";
                }
            } else snap.errors += 1;
            listDirInto(io, snap, "/Library/LaunchAgents", "", "launch:agents");
            listDirInto(io, snap, "/Library/LaunchDaemons", "", "launch:daemons");
            if (environ) |env| if (env.get("HOME")) |home| listDirInto(io, snap, home, "/Library/LaunchAgents", "launch:user");
            if (runCmd(snap.alloc(), io, &.{ "crontab", "-l" }, 1 << 20, 20)) |t| {
                parseCrontab(snap, t, "cron:user");
            }
        },
        else => snap.errors += 1,
    }
}

/// stdout of `argv` when it exited 0, else null. Never a shell: argv is the array it is.
fn runCmd(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, limit: usize, comptime secs: u64) ?[]u8 {
    const r = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(64 << 10),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(secs), .clock = .awake } },
    }) catch return null;
    gpa.free(r.stderr);
    if (!(r.term == .exited and r.term.exited == 0)) {
        gpa.free(r.stdout);
        return null;
    }
    return r.stdout;
}

/// Both streams and the verdict of `argv`, for the commands whose failure text matters (firewall changes).
const CmdOut = struct { ok: bool, text: []u8 };
fn runAll(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, comptime secs: u64) CmdOut {
    const r = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(CMD_LIMIT),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(secs), .clock = .awake } },
    }) catch |e| return .{ .ok = false, .text = std.fmt.allocPrint(gpa, "could not run {s}: {t}", .{ argv[0], e }) catch dupe(gpa, "could not run the firewall command") };
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    const ok = r.term == .exited and r.term.exited == 0;
    const text = std.fmt.allocPrint(gpa, "{s}{s}", .{ std.mem.trim(u8, r.stdout, " \r\n\t"), std.mem.trim(u8, r.stderr, " \r\n\t") }) catch dupe(gpa, "");
    return .{ .ok = ok, .text = text };
}

fn listDirInto(io: std.Io, snap: *Snapshot, base: []const u8, sub: []const u8, tag: []const u8) void {
    var pb: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}{s}", .{ base, sub }) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (std.mem.eql(u8, ent.name, "desktop.ini") or std.mem.eql(u8, ent.name, ".DS_Store")) continue;
        const key = std.fmt.allocPrint(snap.alloc(), "{s}:{s}", .{ tag, ent.name }) catch return;
        snap.persist.append(snap.alloc(), key) catch return;
    }
}

// ------------------------------------------------------------------------------------------------- parsers

/// host:port with IPv6 in brackets ("[::]:135", "[fe80::1%12]:546") or bare ("0.0.0.0:135", "*:*").
pub fn splitHostPort(s: []const u8) ?struct { host: []const u8, port: u16 } {
    if (s.len == 0) return null;
    if (s[0] == '[') {
        const close = std.mem.indexOfScalar(u8, s, ']') orelse return null;
        if (close + 1 >= s.len or s[close + 1] != ':') return null;
        const host = s[1..close];
        const port = std.fmt.parseInt(u16, s[close + 2 ..], 10) catch return null;
        return .{ .host = host, .port = port };
    }
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const ps = s[colon + 1 ..];
    const port: u16 = if (std.mem.eql(u8, ps, "*")) 0 else std.fmt.parseInt(u16, ps, 10) catch return null;
    return .{ .host = s[0..colon], .port = port };
}

/// Windows `netstat -ano`.
pub fn parseNetstat(snap: *Snapshot, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const proto_s = it.next() orelse continue;
        const proto: Proto = if (std.ascii.eqlIgnoreCase(proto_s, "TCP")) .tcp else if (std.ascii.eqlIgnoreCase(proto_s, "UDP")) .udp else continue;
        const local_s = it.next() orelse continue;
        const foreign_s = it.next() orelse continue;
        const local = splitHostPort(local_s) orelse continue;
        if (proto == .tcp) {
            const state = it.next() orelse continue;
            const pid_s = it.next() orelse continue;
            const pid = std.fmt.parseInt(u32, pid_s, 10) catch continue;
            if (std.ascii.eqlIgnoreCase(state, "LISTENING")) {
                snap.listeners.append(snap.alloc(), .{ .proto = .tcp, .addr = local.host, .port = local.port, .pid = pid, .name = "" }) catch return;
            } else if (std.ascii.eqlIgnoreCase(state, "ESTABLISHED")) {
                const remote = splitHostPort(foreign_s) orelse continue;
                snap.conns.append(snap.alloc(), .{ .proto = .tcp, .raddr = remote.host, .rport = remote.port, .pid = pid, .name = "" }) catch return;
            }
        } else {
            const pid_s = it.next() orelse continue;
            const pid = std.fmt.parseInt(u32, pid_s, 10) catch continue;
            if (local.port >= 49152) continue; // an ephemeral UDP socket is a client, not a service
            snap.listeners.append(snap.alloc(), .{ .proto = .udp, .addr = local.host, .port = local.port, .pid = pid, .name = "" }) catch return;
        }
    }
}

const NameSource = enum { tasklist, ps };

/// Fill the empty `name` fields from `tasklist /fo csv /nh` ("name","pid",...) or `ps -axo pid=,comm=`.
pub fn nameByPid(snap: *Snapshot, text: []const u8, src: NameSource) void {
    const Row = struct { pid: u32, name: []const u8 };
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(snap.alloc());
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        switch (src) {
            .tasklist => {
                if (line[0] != '"') continue;
                const q1 = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse continue;
                const name = line[1..q1];
                const rest = line[q1 + 1 ..];
                const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
                const q3 = std.mem.indexOfScalarPos(u8, rest, q2 + 1, '"') orelse continue;
                const pid = std.fmt.parseInt(u32, rest[q2 + 1 .. q3], 10) catch continue;
                rows.append(snap.alloc(), .{ .pid = pid, .name = name }) catch return;
            },
            .ps => {
                var it = std.mem.tokenizeAny(u8, line, " \t");
                const pid = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
                const name = it.rest();
                rows.append(snap.alloc(), .{ .pid = pid, .name = std.mem.trim(u8, name, " \t") }) catch return;
            },
        }
    }
    for (snap.listeners.items) |*l| if (l.name.len == 0) {
        for (rows.items) |r| if (r.pid == l.pid) {
            l.name = r.name;
            break;
        };
        if (l.name.len == 0) l.name = if (l.pid == 4) "System" else "?";
    };
    for (snap.conns.items) |*c| if (c.name.len == 0) {
        for (rows.items) |r| if (r.pid == c.pid) {
            c.name = r.name;
            break;
        };
        if (c.name.len == 0) c.name = "?";
    };
}

/// `netsh advfirewall show allprofiles state`: one State line per profile.
pub fn parseNetshProfiles(text: []const u8) FwState {
    var on: u8 = 0;
    var off: u8 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!std.mem.startsWith(u8, line, "State")) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next();
        const v = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(v, "ON")) on += 1 else if (std.ascii.eqlIgnoreCase(v, "OFF")) off += 1;
    }
    if (on == 0 and off == 0) return .unknown;
    if (off == 0) return .on;
    if (on == 0) return .off;
    return .partial;
}

/// `reg query <Run key>`: value lines are indented, "Name    REG_SZ    command".
pub fn parseRegRun(snap: *Snapshot, text: []const u8, tag: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        if (!std.mem.startsWith(u8, line, "    ")) continue;
        const body = std.mem.trim(u8, line, " \t");
        const reg_at = std.mem.indexOf(u8, body, "    REG_") orelse continue;
        const name = std.mem.trim(u8, body[0..reg_at], " \t");
        const after_type = std.mem.indexOfPos(u8, body, reg_at + 4, "    ") orelse body.len;
        const value = std.mem.trim(u8, body[after_type..], " \t");
        if (name.len == 0) continue;
        const key = std.fmt.allocPrint(snap.alloc(), "{s}:{s}={s}", .{ tag, name, clip(value, 200) }) catch return;
        snap.persist.append(snap.alloc(), key) catch return;
    }
}

/// `schtasks /query /fo csv /nh`: "\Path","Next Run Time","Status". Disabled tasks are not persistence.
pub fn parseSchtasks(snap: *Snapshot, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len < 3 or line[0] != '"') continue;
        const q1 = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse continue;
        const name = line[1..q1];
        if (std.mem.eql(u8, name, "TaskName")) continue;
        var status: []const u8 = "";
        var rest = line[q1 + 1 ..];
        var field: usize = 1;
        while (field < 3) : (field += 1) {
            const a = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const b = std.mem.indexOfScalarPos(u8, rest, a + 1, '"') orelse break;
            status = rest[a + 1 .. b];
            rest = rest[b + 1 ..];
        }
        if (std.ascii.eqlIgnoreCase(status, "Disabled")) continue;
        if (std.mem.startsWith(u8, name, "\\Microsoft\\")) continue; // the OS's own schedule: hundreds of rows, none of them the user's
        const key = std.fmt.allocPrint(snap.alloc(), "task:{s}", .{clip(name, 200)}) catch return;
        snap.persist.append(snap.alloc(), key) catch return;
    }
}

/// Linux `ss -tunapH`: netid state recvq sendq local peer process.
pub fn parseSs(snap: *Snapshot, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const netid = it.next() orelse continue;
        const proto: Proto = if (std.mem.eql(u8, netid, "tcp")) .tcp else if (std.mem.eql(u8, netid, "udp")) .udp else continue;
        const state = it.next() orelse continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        const local_s = it.next() orelse continue;
        const peer_s = it.next() orelse continue;
        const proc = it.rest();
        var name: []const u8 = "?";
        var pid: u32 = 0;
        if (std.mem.indexOf(u8, proc, "((\"")) |a| {
            const b = std.mem.indexOfScalarPos(u8, proc, a + 3, '"') orelse proc.len;
            name = proc[a + 3 .. b];
        }
        if (std.mem.indexOf(u8, proc, "pid=")) |a| {
            const e = std.mem.indexOfAnyPos(u8, proc, a + 4, ",)") orelse proc.len;
            pid = std.fmt.parseInt(u32, proc[a + 4 .. e], 10) catch 0;
        }
        const local = splitHostPort(local_s) orelse continue;
        if (std.mem.eql(u8, state, "LISTEN") or (proto == .udp and std.mem.eql(u8, state, "UNCONN"))) {
            if (proto == .udp and local.port >= 49152) continue;
            snap.listeners.append(snap.alloc(), .{ .proto = proto, .addr = local.host, .port = local.port, .pid = pid, .name = name }) catch return;
        } else if (std.mem.eql(u8, state, "ESTAB")) {
            const peer = splitHostPort(peer_s) orelse continue;
            snap.conns.append(snap.alloc(), .{ .proto = proto, .raddr = peer.host, .rport = peer.port, .pid = pid, .name = name }) catch return;
        }
    }
}

/// macOS `lsof -nP -iTCP -iUDP`: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [STATE].
pub fn parseLsof(snap: *Snapshot, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse continue;
        if (std.mem.eql(u8, cmd, "COMMAND")) continue;
        const pid = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        _ = it.next() orelse continue; // user
        _ = it.next() orelse continue; // fd
        _ = it.next() orelse continue; // type
        _ = it.next() orelse continue; // device
        _ = it.next() orelse continue; // size/off
        const node = it.next() orelse continue;
        const proto: Proto = if (std.mem.eql(u8, node, "TCP")) .tcp else if (std.mem.eql(u8, node, "UDP")) .udp else continue;
        const name_field = it.next() orelse continue;
        const state = it.next() orelse "";
        if (std.mem.indexOf(u8, name_field, "->")) |arrow| {
            if (!std.mem.eql(u8, state, "(ESTABLISHED)")) continue;
            const peer = splitHostPort(name_field[arrow + 2 ..]) orelse continue;
            snap.conns.append(snap.alloc(), .{ .proto = proto, .raddr = peer.host, .rport = peer.port, .pid = pid, .name = cmd }) catch return;
            continue;
        }
        const local = splitHostPort(name_field) orelse continue;
        if (proto == .tcp and !std.mem.eql(u8, state, "(LISTEN)")) continue;
        if (proto == .udp and local.port >= 49152) continue;
        const addr: []const u8 = if (std.mem.eql(u8, local.host, "*")) "0.0.0.0" else local.host;
        snap.listeners.append(snap.alloc(), .{ .proto = proto, .addr = addr, .port = local.port, .pid = pid, .name = cmd }) catch return;
    }
}

pub fn parseCrontab(snap: *Snapshot, text: []const u8, tag: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const key = std.fmt.allocPrint(snap.alloc(), "{s}:{s}", .{ tag, clip(line, 200) }) catch return;
        snap.persist.append(snap.alloc(), key) catch return;
    }
}

pub fn parseUnitFiles(snap: *Snapshot, text: []const u8, tag: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const unit = it.next() orelse continue;
        if (std.mem.indexOfScalar(u8, unit, '.') == null) continue;
        const key = std.fmt.allocPrint(snap.alloc(), "{s}:{s}", .{ tag, clip(unit, 200) }) catch return;
        snap.persist.append(snap.alloc(), key) catch return;
    }
}

// ------------------------------------------------------------------------------------------------- host firewall

/// The one place the OS firewall is spoken to. Every rule it writes is named RULE_PREFIX ++ id, and listing,
/// removing and withdrawing only ever name that prefix: a rule the sentry did not write is not its to touch.
pub const backend = struct {
    pub fn enforceSupported() bool {
        return builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos;
    }

    /// Apply `r`. Null on success; else the OS's own sentence (clipped into `eb`).
    pub fn apply(gpa: std.mem.Allocator, io: std.Io, data: []const u8, r: *const Rule, eb: *[TEXT_MAX]u8) ?[]const u8 {
        switch (builtin.os.tag) {
            .windows => {
                var argv: std.ArrayListUnmanaged([]const u8) = .empty;
                defer {
                    if (argv.items.len > 7) for (argv.items[7..]) |a| gpa.free(a);
                    argv.deinit(gpa);
                }
                argv.appendSlice(gpa, &.{ "netsh", "advfirewall", "firewall", "add", "rule" }) catch return "out of memory";
                argv.appendSlice(gpa, &.{ "enable=yes", "profile=any" }) catch return "out of memory";
                netshArgs(gpa, &argv, r) catch return "out of memory";
                return verdict(gpa, io, argv.items, eb, "elevation", "enforce needs an elevated veil: run it as administrator, or keep the observe posture");
            },
            .linux => {
                if (nftEnsure(gpa, io, eb)) |e| return e;
                var argv: std.ArrayListUnmanaged([]const u8) = .empty;
                defer {
                    if (argv.items.len > 6) for (argv.items[6..]) |a| gpa.free(a);
                    argv.deinit(gpa);
                }
                argv.appendSlice(gpa, &.{ "nft", "add", "rule", "inet", NFT_TABLE, if (r.dir == .in) "input" else "output" }) catch return "out of memory";
                nftArgs(gpa, &argv, r) catch return "out of memory";
                return verdict(gpa, io, argv.items, eb, "not permitted", "enforce needs root for nftables: run the veil as root, or keep the observe posture");
            },
            .macos => {
                // pf is loaded from a file we own, whole: write every rule of the policy, load the anchor. `r` is
                // already in that file (the caller saved the policy first), so only its id is reported.
                if (r.id_len == 0) return "a rule needs an id";
                return pfReload(gpa, io, data, eb);
            },
            else => return "enforcement is not supported on this operating system",
        }
    }

    /// Remove `r` from the host. True when it is gone (or was never there).
    pub fn remove(gpa: std.mem.Allocator, io: std.Io, data: []const u8, r: *const Rule) bool {
        switch (builtin.os.tag) {
            .windows => {
                const name = std.fmt.allocPrint(gpa, "name={s}{s}", .{ RULE_PREFIX, r.idStr() }) catch return false;
                defer gpa.free(name);
                const out = runAll(gpa, io, &.{ "netsh", "advfirewall", "firewall", "delete", "rule", name }, 30);
                defer gpa.free(out.text);
                return out.ok or std.mem.indexOf(u8, out.text, "No rules match") != null;
            },
            .linux => {
                var handles: std.ArrayListUnmanaged(NftHandle) = .empty;
                defer handles.deinit(gpa);
                const listing = runCmd(gpa, io, &.{ "nft", "-a", "list", "table", "inet", NFT_TABLE }, CMD_LIMIT, 20) orelse return true; // no table: nothing of ours is there
                defer gpa.free(listing);
                parseNftHandles(gpa, listing, &handles);
                var ok = true;
                for (handles.items) |h| {
                    if (!std.mem.eql(u8, listing[h.id_at..h.id_end], r.idStr())) continue;
                    var hb: [24]u8 = undefined;
                    const hs = std.fmt.bufPrint(&hb, "{d}", .{h.handle}) catch continue;
                    const out = runAll(gpa, io, &.{ "nft", "delete", "rule", "inet", NFT_TABLE, if (h.input) "input" else "output", "handle", hs }, 20);
                    gpa.free(out.text);
                    if (!out.ok) ok = false;
                }
                return ok;
            },
            .macos => {
                if (r.id_len == 0) return true;
                var eb: [TEXT_MAX]u8 = undefined;
                return pfReload(gpa, io, data, &eb) == null;
            },
            else => return true,
        }
    }

    /// The ids of every veil-sentry rule the host has right now. False when the host could not be asked.
    pub fn listPresent(gpa: std.mem.Allocator, io: std.Io, data: []const u8, into: *std.ArrayListUnmanaged([]u8)) bool {
        switch (builtin.os.tag) {
            .windows => {
                const t = runCmd(gpa, io, &.{ "netsh", "advfirewall", "firewall", "show", "rule", "name=all" }, CMD_LIMIT, 60) orelse return false;
                defer gpa.free(t);
                parseNetshRuleNames(gpa, t, into);
                return true;
            },
            .linux => {
                const t = runCmd(gpa, io, &.{ "nft", "-a", "list", "table", "inet", NFT_TABLE }, CMD_LIMIT, 20) orelse return true; // no table yet
                defer gpa.free(t);
                var handles: std.ArrayListUnmanaged(NftHandle) = .empty;
                defer handles.deinit(gpa);
                parseNftHandles(gpa, t, &handles);
                for (handles.items) |h| {
                    const id = gpa.dupe(u8, t[h.id_at..h.id_end]) catch return true;
                    into.append(gpa, id) catch gpa.free(id);
                }
                return true;
            },
            .macos => {
                var pb: [1024]u8 = undefined;
                const path = std.fmt.bufPrint(&pb, "{s}/{s}/pf.rules", .{ data, DIR }) catch return false;
                const t = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return true;
                defer gpa.free(t);
                var lines = std.mem.splitScalar(u8, t, '\n');
                while (lines.next()) |l| {
                    const at = std.mem.indexOf(u8, l, "# " ++ RULE_PREFIX) orelse continue;
                    const id = std.mem.trim(u8, l[at + 2 + RULE_PREFIX.len ..], " \r\t");
                    const d = gpa.dupe(u8, id) catch return true;
                    into.append(gpa, d) catch gpa.free(d);
                }
                return true;
            },
            else => return false,
        }
    }

    /// Everything of ours, gone. Linux drops the whole table (it is ours alone); Windows deletes by name;
    /// macOS flushes the anchor.
    pub fn withdrawAll(gpa: std.mem.Allocator, io: std.Io, data: []const u8, p: *const Policy) bool {
        switch (builtin.os.tag) {
            .windows => {
                var ok = true;
                for (p.rules[0..p.rules_n]) |*r| if (!remove(gpa, io, data, r)) {
                    ok = false;
                };
                return ok;
            },
            .linux => {
                const out = runAll(gpa, io, &.{ "nft", "delete", "table", "inet", NFT_TABLE }, 20);
                defer gpa.free(out.text);
                return out.ok or std.mem.indexOf(u8, out.text, "No such file") != null;
            },
            .macos => {
                const out = runAll(gpa, io, &.{ "pfctl", "-a", PF_ANCHOR, "-F", "rules" }, 20);
                gpa.free(out.text);
                return out.ok;
            },
            else => return true,
        }
    }

    fn verdict(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, eb: *[TEXT_MAX]u8, needle: []const u8, hint: []const u8) ?[]const u8 {
        const out = runAll(gpa, io, argv, 30);
        defer gpa.free(out.text);
        if (out.ok) return null;
        if (std.ascii.indexOfIgnoreCase(out.text, needle) != null) return hint;
        const t = std.mem.trim(u8, out.text, " \r\n\t");
        const n = @min(t.len, eb.len);
        @memcpy(eb[0..n], t[0..n]);
        return if (n > 0) eb[0..n] else "the firewall command failed without saying why";
    }

    // --- Windows -------------------------------------------------------------------------------------------

    /// The `key=value` elements of a netsh add-rule command after the verb. Appended, gpa-owned.
    pub fn netshArgs(gpa: std.mem.Allocator, argv: *std.ArrayListUnmanaged([]const u8), r: *const Rule) !void {
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "name={s}{s}", .{ RULE_PREFIX, r.idStr() }));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "dir={s}", .{@tagName(r.dir)}));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "action={s}", .{@tagName(r.action)}));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "protocol={s}", .{switch (r.proto) {
            .tcp => "TCP",
            .udp => "UDP",
            .any => "any",
        }}));
        if (r.port != 0) try argv.append(gpa, try std.fmt.allocPrint(gpa, "{s}={d}", .{ if (r.dir == .in) "localport" else "remoteport", r.port }));
        if (r.remote_len > 0) try argv.append(gpa, try std.fmt.allocPrint(gpa, "remoteip={s}", .{r.remoteStr()}));
        if (r.program_len > 0) try argv.append(gpa, try std.fmt.allocPrint(gpa, "program={s}", .{r.programStr()}));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "description=written by the veil's sentry{s}{s}", .{ if (r.note_len > 0) ": " else "", r.noteStr() }));
    }

    /// Our ids out of `netsh advfirewall firewall show rule name=all`.
    pub fn parseNetshRuleNames(gpa: std.mem.Allocator, text: []const u8, into: *std.ArrayListUnmanaged([]u8)) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (!std.mem.startsWith(u8, line, "Rule Name:")) continue;
            const v = std.mem.trim(u8, line["Rule Name:".len..], " \t");
            if (!std.mem.startsWith(u8, v, RULE_PREFIX)) continue;
            const id = v[RULE_PREFIX.len..];
            if (id.len == 0 or id.len > ID_MAX) continue;
            const d = gpa.dupe(u8, id) catch return;
            into.append(gpa, d) catch gpa.free(d);
        }
    }

    // --- Linux ---------------------------------------------------------------------------------------------

    /// The table and its two chains, idempotently. The error sentence when they cannot be made.
    fn nftEnsure(gpa: std.mem.Allocator, io: std.Io, eb: *[TEXT_MAX]u8) ?[]const u8 {
        const steps = [_][]const []const u8{
            &.{ "nft", "add", "table", "inet", NFT_TABLE },
            &.{ "nft", "add", "chain", "inet", NFT_TABLE, "input", "{", "type", "filter", "hook", "input", "priority", "0", ";", "policy", "accept", ";", "}" },
            &.{ "nft", "add", "chain", "inet", NFT_TABLE, "output", "{", "type", "filter", "hook", "output", "priority", "0", ";", "policy", "accept", ";", "}" },
        };
        for (steps) |argv| {
            if (verdict(gpa, io, argv, eb, "not permitted", "enforce needs root for nftables: run the veil as root, or keep the observe posture")) |e| return e;
        }
        return null;
    }

    /// The match + verdict + comment of an nft rule. A program match does not exist in nftables; it is kept in
    /// the policy (and in the comment) but cannot narrow the rule, which the rule's note says.
    pub fn nftArgs(gpa: std.mem.Allocator, argv: *std.ArrayListUnmanaged([]const u8), r: *const Rule) !void {
        if (r.port != 0) {
            try argv.append(gpa, try gpa.dupe(u8, @tagName(r.proto)));
            try argv.append(gpa, try gpa.dupe(u8, "dport"));
            try argv.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{r.port}));
        }
        if (r.remote_len > 0) {
            try argv.append(gpa, try gpa.dupe(u8, if (isV6(r.remoteStr())) "ip6" else "ip"));
            try argv.append(gpa, try gpa.dupe(u8, if (r.dir == .in) "saddr" else "daddr"));
            try argv.append(gpa, try gpa.dupe(u8, r.remoteStr()));
        }
        try argv.append(gpa, try gpa.dupe(u8, if (r.action == .block) "drop" else "accept"));
        try argv.append(gpa, try gpa.dupe(u8, "comment"));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "\"{s}{s}\"", .{ RULE_PREFIX, r.idStr() }));
    }

    pub const NftHandle = struct { input: bool, handle: u64, id_at: usize, id_end: usize };

    /// `nft -a list table inet veil_sentry`: which chain each of our comments sits in, and its handle.
    pub fn parseNftHandles(gpa: std.mem.Allocator, text: []const u8, into: *std.ArrayListUnmanaged(NftHandle)) void {
        var input = true;
        var pos: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            defer pos += l.len + 1;
            const t = std.mem.trim(u8, l, " \t\r");
            if (std.mem.startsWith(u8, t, "chain input")) input = true;
            if (std.mem.startsWith(u8, t, "chain output")) input = false;
            const c = std.mem.indexOf(u8, l, "comment \"" ++ RULE_PREFIX) orelse continue;
            const id_at = pos + c + ("comment \"" ++ RULE_PREFIX).len;
            const id_end_rel = std.mem.indexOfScalarPos(u8, l, c + ("comment \"" ++ RULE_PREFIX).len, '"') orelse continue;
            const h = std.mem.indexOf(u8, l, "# handle ") orelse continue;
            const handle = std.fmt.parseInt(u64, std.mem.trim(u8, l[h + "# handle ".len ..], " \r\t"), 10) catch continue;
            into.append(gpa, .{ .input = input, .handle = handle, .id_at = id_at, .id_end = pos + id_end_rel }) catch return;
        }
    }

    // --- macOS ---------------------------------------------------------------------------------------------

    /// One pf rule line. pf has no program match either.
    pub fn pfLine(buf: []u8, r: *const Rule) []const u8 {
        const proto_part: []const u8 = switch (r.proto) {
            .tcp => " proto tcp",
            .udp => " proto udp",
            .any => "",
        };
        var fb: [160]u8 = undefined;
        var rb: [120]u8 = undefined;
        const remote = if (r.remote_len > 0) r.remoteStr() else "any";
        const port_part = if (r.port != 0) (std.fmt.bufPrint(&fb, " port {d}", .{r.port}) catch "") else "";
        const from_to = if (r.dir == .in) (std.fmt.bufPrint(&rb, "from {s} to any{s}", .{ remote, port_part }) catch "") else (std.fmt.bufPrint(&rb, "from any to {s}{s}", .{ remote, port_part }) catch "");
        return std.fmt.bufPrint(buf, "{s} {s}{s} {s} # {s}{s}", .{ if (r.action == .block) "block" else "pass", @tagName(r.dir), proto_part, from_to, RULE_PREFIX, r.idStr() }) catch buf[0..0];
    }

    fn pfReload(gpa: std.mem.Allocator, io: std.Io, data: []const u8, eb: *[TEXT_MAX]u8) ?[]const u8 {
        // The policy file is the truth; the caller holds `mu`. Re-read it rather than thread the Policy through.
        var pb: [1024]u8 = undefined;
        const ppath = std.fmt.bufPrint(&pb, "{s}/{s}/policy.json", .{ data, DIR }) catch return "path too long";
        const raw = std.Io.Dir.cwd().readFileAlloc(io, ppath, gpa, .limited(1 << 20)) catch return "policy.json could not be read";
        defer gpa.free(raw);
        const p = parsePolicy(gpa, raw) orelse return "policy.json could not be parsed";
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(gpa);
        for (p.rules[0..p.rules_n]) |*r| {
            var lb: [400]u8 = undefined;
            body.appendSlice(gpa, pfLine(&lb, r)) catch return "out of memory";
            body.append(gpa, '\n') catch return "out of memory";
        }
        var fb: [1024]u8 = undefined;
        const fpath = std.fmt.bufPrint(&fb, "{s}/{s}/pf.rules", .{ data, DIR }) catch return "path too long";
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fpath, .data = body.items }) catch return "pf.rules could not be written";
        return verdict(gpa, io, &.{ "pfctl", "-a", PF_ANCHOR, "-f", fpath }, eb, "Permission denied", "enforce needs root for pf: run the veil as root, and reference anchor \"veil-sentry\" from /etc/pf.conf");
    }
};

// ------------------------------------------------------------------------------------------------- the belt

/// The sentry's verbs on the belt. Advertised to an admin turn on the server's own machine; refused everywhere
/// else (the sandbox gate never admits them, and a mind has no Sentry pointer).
pub const SCHEMA =
    \\{"type":"function","function":{"name":"sentry_status","description":"The sentry watching THIS machine (the one the veil runs on): on or off, posture (observe or enforce), whether the host firewall is on, how many listeners are on network addresses, how many findings await review, the firewall rules in force. Call it first for any question about this computer's security, exposure or open ports.","parameters":{"type":"object","properties":{}}}},
    \\{"type":"function","function":{"name":"sentry_findings","description":"The sentry's findings on this machine: new listeners, new startup or scheduled entries, the firewall turning off, unusual outbound connections, quarantines — each with a severity and a seq. Newest last. Read them before telling the user their machine is fine.","parameters":{"type":"object","properties":{"since":{"type":"integer","description":"only findings with a seq above this (0 = all)"},"min_severity":{"type":"string","enum":["info","low","medium","high"],"description":"default low"},"limit":{"type":"integer","description":"default 40"},"open_only":{"type":"boolean","description":"only findings nobody has acknowledged yet (default true)"}}}}},
    \\{"type":"function","function":{"name":"sentry_scan","description":"Take an inventory of this machine NOW (listening ports with their processes, established connections, startup and scheduled entries, host firewall state), diff it against the baseline and return what is listening plus any new findings. Use it when the user asks what is open or running right now.","parameters":{"type":"object","properties":{"connections":{"type":"boolean","description":"include established connections in the answer (default false)"},"persistence":{"type":"boolean","description":"include the startup/scheduled inventory (default false)"}}}}},
    \\{"type":"function","function":{"name":"sentry_rules","description":"The sentry's firewall policy: every allow/block rule with its id, whether it is applied on the host, and which posture is in force.","parameters":{"type":"object","properties":{}}}},
    \\{"type":"function","function":{"name":"sentry_rule","description":"Add or remove a firewall rule in the sentry's policy. In the enforce posture a rule is applied to the host firewall at once (Windows Defender Firewall, nftables, pf); in observe it is recorded and applied when the user switches to enforce. Blocking inbound on a port closes it to the network; blocking outbound to an address stops this machine talking to it. The veil's own ports cannot be blocked.","parameters":{"type":"object","properties":{"op":{"type":"string","enum":["add","remove"]},"id":{"type":"string","description":"remove: the rule's id; add: optional slug"},"action":{"type":"string","enum":["allow","block"]},"direction":{"type":"string","enum":["in","out"]},"protocol":{"type":"string","enum":["tcp","udp","any"]},"port":{"type":"integer","description":"local port for in, remote port for out; 0 = any"},"remote":{"type":"string","description":"an IP or CIDR the rule applies to (optional)"},"program":{"type":"string","description":"absolute path of the program the rule applies to (Windows only; optional)"},"note":{"type":"string","description":"why, in a few words"}},"required":["op"]}}},
    \\{"type":"function","function":{"name":"sentry_set","description":"Change how the sentry runs: turn it on or off, set the posture (observe = report only; enforce = apply the policy to the host firewall), auto_block (quarantine a new network-reachable listener on sight — enforce only), the scan interval, the port allowlist, accept the current state as the baseline, or acknowledge the findings so far. Ask before switching to enforce or auto_block unless the user already asked for it.","parameters":{"type":"object","properties":{"enabled":{"type":"boolean"},"posture":{"type":"string","enum":["observe","enforce"]},"auto_block":{"type":"boolean"},"every_s":{"type":"integer","description":"seconds between scans (15..3600)"},"allow_port":{"type":"integer","description":"a port that is fine to see listening"},"disallow_port":{"type":"integer"},"baseline":{"type":"boolean","description":"accept everything seen so far as this machine's normal"},"ack":{"type":"boolean","description":"mark every finding reviewed"}}}}}
;

pub fn isTool(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "sentry_");
}

const NOT_HERE = "the sentry is not available on this server (it runs on the machine the veil is deployed on; a swarm mind or a non-admin cannot reach it)";

/// One tool call. `s` null ⇒ the caller has no sentry (a mind, a sandboxed turn). gpa-owned text back.
pub fn run(s: ?*Sentry, gpa: std.mem.Allocator, name: []const u8, args_json: []const u8) []u8 {
    const sen = s orelse return dupe(gpa, NOT_HERE);
    if (std.mem.eql(u8, name, "sentry_status")) return toolStatus(sen, gpa);
    if (std.mem.eql(u8, name, "sentry_findings")) return toolFindings(sen, gpa, args_json);
    if (std.mem.eql(u8, name, "sentry_scan")) return toolScan(sen, gpa, args_json);
    if (std.mem.eql(u8, name, "sentry_rules")) return toolRules(sen, gpa);
    if (std.mem.eql(u8, name, "sentry_rule")) return toolRule(sen, gpa, args_json);
    if (std.mem.eql(u8, name, "sentry_set")) return toolSet(sen, gpa, args_json);
    return std.fmt.allocPrint(gpa, "unknown sentry verb {s}: the sentry's tools are sentry_status, sentry_findings, sentry_scan, sentry_rules, sentry_rule, sentry_set", .{clip(name, 40)}) catch dupe(gpa, "unknown sentry verb");
}

fn toolStatus(s: *Sentry, gpa: std.mem.Allocator) []u8 {
    const st = s.statusJson(gpa);
    defer gpa.free(st);
    const open = s.findingsJson(gpa, s.ackedSeq(), .low, 12);
    defer gpa.free(open);
    return std.fmt.allocPrint(gpa, "{s}\nopen findings (newest last, up to 12): {s}\n{s}", .{ st, open, if (!s.enabled()) "The sentry is OFF: sentry_set enabled=true starts it (observe posture; nothing on the host changes until the user chooses enforce)." else "" }) catch dupe(gpa, "oom");
}

fn toolFindings(s: *Sentry, gpa: std.mem.Allocator, args_json: []const u8) []u8 {
    const A = struct { since: u64 = 0, min_severity: []const u8 = "low", limit: usize = 40, open_only: bool = true };
    const p = std.json.parseFromSlice(A, gpa, if (args_json.len > 0) args_json else "{}", .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args: {since?, min_severity?, limit?, open_only?}");
    defer p.deinit();
    const min = std.meta.stringToEnum(Severity, p.value.min_severity) orelse .low;
    const since = if (p.value.open_only) @max(p.value.since, s.ackedSeq()) else p.value.since;
    const j = s.findingsJson(gpa, since, min, @min(p.value.limit, 200));
    defer gpa.free(j);
    if (std.mem.eql(u8, j, "[]")) return dupe(gpa, if (p.value.open_only) "no open findings at or above that severity (sentry_findings open_only=false shows acknowledged ones too)" else "no findings at or above that severity");
    return std.fmt.allocPrint(gpa, "findings (seq, severity, kind, text): {s}\nsentry_set ack=true marks them reviewed; sentry_set baseline=true accepts what they describe as this machine's normal.", .{j}) catch dupe(gpa, "oom");
}

fn toolScan(s: *Sentry, gpa: std.mem.Allocator, args_json: []const u8) []u8 {
    const A = struct { connections: bool = false, persistence: bool = false };
    const p = std.json.parseFromSlice(A, gpa, if (args_json.len > 0) args_json else "{}", .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args");
    defer p.deinit();
    const rep = s.scan(true);
    const inv = s.inventoryJson(gpa);
    defer gpa.free(inv);
    var o: std.ArrayListUnmanaged(u8) = .empty;
    defer o.deinit(gpa);
    if (rep.busy) {
        o.appendSlice(gpa, "a scan is already running (the sentry's own cycle); here is the last completed inventory — call sentry_findings in a few seconds for what this one finds\n") catch {};
        appendSection(gpa, &o, inv, "listeners", true);
        return o.toOwnedSlice(gpa) catch dupe(gpa, "oom");
    }
    o.print(gpa, "scan done: {d} listeners ({d} on network addresses), {d} established connections, {d} startup/scheduled entries, host firewall {s}, {d} new finding(s){s}{s}\n", .{ rep.listeners, rep.exposed, rep.conns, rep.persist, @tagName(rep.fw), rep.new_findings, if (rep.err.len > 0) "; last error: " else "", rep.err }) catch {};
    // Listeners always; the rest on request. The inventory JSON is one object; cut the arrays out of it.
    appendSection(gpa, &o, inv, "listeners", true);
    if (p.value.connections) appendSection(gpa, &o, inv, "connections", true);
    if (p.value.persistence) appendSection(gpa, &o, inv, "persistence", true);
    if (rep.new_findings > 0) {
        const f = s.findingsJson(gpa, s.seqBefore(rep.new_findings), .info, 40);
        defer gpa.free(f);
        o.print(gpa, "new findings: {s}\n", .{f}) catch {};
    }
    return o.toOwnedSlice(gpa) catch dupe(gpa, "oom");
}

fn appendSection(gpa: std.mem.Allocator, o: *std.ArrayListUnmanaged(u8), inv: []const u8, key: []const u8, show: bool) void {
    if (!show) return;
    var kb: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&kb, "\"{s}\":[", .{key}) catch return;
    const at = std.mem.indexOf(u8, inv, pat) orelse return;
    const start = at + pat.len - 1;
    // the matching close bracket: arrays here hold only flat objects and strings, so depth counting is enough
    var depth: usize = 0;
    var i = start;
    var in_str = false;
    while (i < inv.len) : (i += 1) {
        const c = inv[i];
        if (in_str) {
            if (c == '\\') i += 1 else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') in_str = true else if (c == '[') depth += 1 else if (c == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    const end = @min(i + 1, inv.len);
    o.print(gpa, "{s}: {s}\n", .{ key, inv[start..end] }) catch {};
}

fn toolRules(s: *Sentry, gpa: std.mem.Allocator) []u8 {
    const r = s.rulesJson(gpa);
    defer gpa.free(r);
    const st = s.statusJson(gpa);
    defer gpa.free(st);
    const posture = if (std.mem.indexOf(u8, st, "\"posture\":\"enforce\"") != null) "enforce (rules are applied to the host firewall)" else "observe (rules are a plan; nothing on the host is changed)";
    return std.fmt.allocPrint(gpa, "posture: {s}\nrules: {s}", .{ posture, r }) catch dupe(gpa, "oom");
}

fn toolRule(s: *Sentry, gpa: std.mem.Allocator, args_json: []const u8) []u8 {
    const A = struct { op: []const u8 = "", id: []const u8 = "", action: []const u8 = "block", direction: []const u8 = "in", protocol: []const u8 = "tcp", port: u16 = 0, remote: []const u8 = "", program: []const u8 = "", note: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, if (args_json.len > 0) args_json else "{}", .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args: {op: add|remove, id?, action?, direction?, protocol?, port?, remote?, program?, note?}");
    defer p.deinit();
    const v = p.value;
    if (std.mem.eql(u8, v.op, "remove")) {
        if (v.id.len == 0) return dupe(gpa, "remove needs the rule's id (sentry_rules lists them)");
        return dupe(gpa, if (s.removeRule(v.id)) "rule removed (and withdrawn from the host firewall if it was applied)" else "no rule with that id");
    }
    if (!std.mem.eql(u8, v.op, "add")) return dupe(gpa, "op must be add or remove");
    switch (s.addRule(.{ .id = v.id, .action = v.action, .direction = v.direction, .protocol = v.protocol, .port = v.port, .remote = v.remote, .program = v.program, .note = v.note })) {
        .id => |id| {
            const enforcing = s.posture() == .enforce and s.enabled();
            return std.fmt.allocPrint(gpa, "rule {s} added: {s} {s} {s} port {d}{s}{s}. {s}", .{ id, v.action, v.direction, v.protocol, v.port, if (v.remote.len > 0) " remote " else "", v.remote, if (enforcing) (if (s.lastError().len == 0) "Applied to the host firewall." else "It could NOT be applied: see sentry_status last_error.") else "Posture is observe, so it is recorded, not applied; sentry_set posture=enforce applies the policy (ask the user first)." }) catch dupe(gpa, "rule added");
        },
        .err => |e| return std.fmt.allocPrint(gpa, "refused: {s}", .{e}) catch dupe(gpa, "refused"),
    }
}

fn toolSet(s: *Sentry, gpa: std.mem.Allocator, args_json: []const u8) []u8 {
    const A = struct { enabled: ?bool = null, posture: ?[]const u8 = null, auto_block: ?bool = null, every_s: ?u32 = null, allow_port: ?u16 = null, disallow_port: ?u16 = null, baseline: ?bool = null, ack: ?bool = null };
    const p = std.json.parseFromSlice(A, gpa, if (args_json.len > 0) args_json else "{}", .{ .ignore_unknown_fields = true }) catch return dupe(gpa, "bad args: {enabled?, posture?, auto_block?, every_s?, allow_port?, disallow_port?, baseline?, ack?}");
    defer p.deinit();
    const v = p.value;
    if (v.enabled == null and v.posture == null and v.auto_block == null and v.every_s == null and v.allow_port == null and v.disallow_port == null and v.baseline == null and v.ack == null) return dupe(gpa, "nothing to set");
    if (s.set(.{ .enabled = v.enabled, .posture = v.posture, .auto_block = v.auto_block, .every_s = v.every_s, .allow_port = v.allow_port, .disallow_port = v.disallow_port, .baseline = v.baseline, .ack = v.ack })) |e| return std.fmt.allocPrint(gpa, "refused: {s}", .{e}) catch dupe(gpa, "refused");
    if (v.enabled orelse false) {
        // Turning it on: scan now so the first status is real, not "pending".
        _ = s.scan(false);
    }
    return toolStatus(s, gpa);
}

// ------------------------------------------------------------------------------------------------- helpers

fn nowSecs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @constCast(s[0..0]);
}

fn jstr(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try list.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try list.appendSlice(gpa, "\\\""),
        '\\' => try list.appendSlice(gpa, "\\\\"),
        '\n' => try list.appendSlice(gpa, "\\n"),
        '\r' => try list.appendSlice(gpa, "\\r"),
        '\t' => try list.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [6]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
        } else try list.append(gpa, c),
    };
    try list.append(gpa, '"');
}

/// Append to the event file; start it over past `cap` bytes (the ring in memory and the findings in the chat are
/// the working record; the file is the long one).
fn appendFile(io: std.Io, path: []const u8, data: []const u8, cap: u64) void {
    const dir = std.Io.Dir.cwd();
    const end: u64 = if (dir.statFile(io, path, .{})) |st| st.size else |_| 0;
    if (end > cap) {
        dir.writeFile(io, .{ .sub_path = path, .data = data }) catch {};
        return;
    }
    const f = dir.createFile(io, path, .{ .truncate = false }) catch return;
    defer f.close(io);
    f.writePositionalAll(io, data, end) catch {};
}

// ================================================================================================= tests

const tt = std.testing;

const NETSTAT_SAMPLE =
    \\
    \\Active Connections
    \\
    \\  Proto  Local Address          Foreign Address        State           PID
    \\  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1820
    \\  TCP    0.0.0.0:445            0.0.0.0:0              LISTENING       4
    \\  TCP    0.0.0.0:8787           0.0.0.0:0              LISTENING       9580
    \\  TCP    127.0.0.1:49700        0.0.0.0:0              LISTENING       7000
    \\  TCP    192.168.1.20:52011     93.184.216.34:443      ESTABLISHED     7000
    \\  TCP    192.168.1.20:52012     203.0.113.9:6667       ESTABLISHED     7001
    \\  TCP    192.168.1.20:52013     192.168.1.1:445        ESTABLISHED     4
    \\  TCP    [::]:135               [::]:0                 LISTENING       1820
    \\  TCP    [::1]:49701            [::]:0                 LISTENING       7000
    \\  UDP    0.0.0.0:5353           *:*                                    3280
    \\  UDP    0.0.0.0:61234          *:*                                    3280
    \\  UDP    [fe80::1%12]:546       *:*                                    1544
;

const TASKLIST_SAMPLE =
    \\"System Idle Process","0","Services","0","8 K"
    \\"System","4","Services","0","49,428 K"
    \\"svchost.exe","1820","Services","0","12,000 K"
    \\"veil.exe","9580","Console","1","80,000 K"
    \\"browser.exe","7000","Console","1","300,000 K"
    \\"odd.exe","7001","Console","1","1,000 K"
    \\"svchost.exe","3280","Services","0","9,000 K"
;

test "netstat -ano: listeners with pid and address family, established peers, UDP services but not UDP clients" {
    var snap = Snapshot.init(tt.allocator);
    defer snap.deinit();
    parseNetstat(&snap, NETSTAT_SAMPLE);
    nameByPid(&snap, TASKLIST_SAMPLE, .tasklist);
    // 6 TCP listeners + 2 UDP services (5353, 546); the 61234 UDP socket is ephemeral and skipped
    try tt.expectEqual(@as(usize, 8), snap.listeners.items.len);
    try tt.expectEqual(@as(usize, 3), snap.conns.items.len);
    const l0 = snap.listeners.items[0];
    try tt.expectEqualStrings("0.0.0.0", l0.addr);
    try tt.expectEqual(@as(u16, 135), l0.port);
    try tt.expectEqualStrings("svchost.exe", l0.name);
    try tt.expectEqualStrings("System", snap.listeners.items[1].name); // pid 4 is the kernel
    try tt.expectEqualStrings("::", snap.listeners.items[4].addr); // brackets stripped
    try tt.expectEqualStrings("::1", snap.listeners.items[5].addr);
    try tt.expectEqualStrings("fe80::1%12", snap.listeners.items[7].addr);
    // the loopback ones are not exposed
    try tt.expect(!exposedAddr("127.0.0.1"));
    try tt.expect(!exposedAddr("::1"));
    try tt.expect(exposedAddr("0.0.0.0"));
    try tt.expect(exposedAddr("192.168.1.20"));
    // peers: a browser on 443 (routine), odd.exe on 6667 (not), the kernel to the LAN (private)
    var kb: [512]u8 = undefined;
    try tt.expect(outboundKey(&kb, snap.conns.items[0]) == null);
    try tt.expectEqualStrings("out|odd.exe|6667", outboundKey(&kb, snap.conns.items[1]).?);
    try tt.expect(outboundKey(&kb, snap.conns.items[2]) == null);
}

test "exposedCount counts every non-loopback bind, UDP included" {
    var snap = Snapshot.init(tt.allocator);
    defer snap.deinit();
    parseNetstat(&snap, NETSTAT_SAMPLE);
    // 0.0.0.0:135, 0.0.0.0:445, 0.0.0.0:8787, [::]:135, UDP 0.0.0.0:5353, UDP fe80::1%12:546
    try tt.expectEqual(@as(usize, 6), snap.exposedCount());
}

test "private address space: RFC 1918, CGNAT, link-local, loopback, ULA; public is public" {
    try tt.expect(privateAddr("10.1.2.3"));
    try tt.expect(privateAddr("192.168.0.1"));
    try tt.expect(privateAddr("172.16.5.5"));
    try tt.expect(privateAddr("172.31.255.1"));
    try tt.expect(!privateAddr("172.32.0.1"));
    try tt.expect(privateAddr("100.64.0.1"));
    try tt.expect(!privateAddr("100.128.0.1"));
    try tt.expect(privateAddr("169.254.10.10"));
    try tt.expect(privateAddr("127.0.0.1"));
    try tt.expect(privateAddr("::1"));
    try tt.expect(privateAddr("fe80::1"));
    try tt.expect(privateAddr("fd12::1"));
    try tt.expect(privateAddr("[::ffff:192.168.1.1]"));
    try tt.expect(!privateAddr("93.184.216.34"));
    try tt.expect(!privateAddr("2606:4700::1111"));
}

test "netsh profile state: all on, any off, none readable" {
    const all_on = "\r\nDomain Profile Settings: \r\n----\r\nState                                 ON\r\n\r\nPrivate Profile Settings: \r\n----\r\nState                                 ON\r\n\r\nPublic Profile Settings: \r\n----\r\nState                                 ON\r\nOk.\r\n";
    try tt.expectEqual(FwState.on, parseNetshProfiles(all_on));
    const one_off = "Domain Profile Settings:\nState ON\nPrivate Profile Settings:\nState OFF\nPublic Profile Settings:\nState ON\n";
    try tt.expectEqual(FwState.partial, parseNetshProfiles(one_off));
    const all_off = "State OFF\nState OFF\nState OFF\n";
    try tt.expectEqual(FwState.off, parseNetshProfiles(all_off));
    try tt.expectEqual(FwState.unknown, parseNetshProfiles("The following command was not found"));
}

test "reg query Run keys and schtasks csv become persistence keys; disabled and Microsoft's own tasks are left out" {
    var snap = Snapshot.init(tt.allocator);
    defer snap.deinit();
    const reg = "\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\r\n    Claude    REG_SZ    \"C:\\Program Files\\Claude\\Claude.exe\"\r\n    OneDrive    REG_SZ    \"C:\\Users\\g\\OneDrive.exe\" /background\r\n    Updater    REG_EXPAND_SZ    %LOCALAPPDATA%\\u.exe\r\n\r\n";
    parseRegRun(&snap, reg, "run:HKCU");
    try tt.expectEqual(@as(usize, 3), snap.persist.items.len);
    try tt.expectEqualStrings("run:HKCU:Claude=\"C:\\Program Files\\Claude\\Claude.exe\"", snap.persist.items[0]);
    try tt.expectEqualStrings("run:HKCU:Updater=%LOCALAPPDATA%\\u.exe", snap.persist.items[2]);
    const tasks = "\"\\AMDLinkUpdate\",\"N/A\",\"Ready\"\r\n\"\\OneDrive Reporting Task\",\"N/A\",\"Disabled\"\r\n\"\\Microsoft\\Windows\\Defrag\\ScheduledDefrag\",\"N/A\",\"Ready\"\r\n\"\\Evil Task\",\"10/12/2026 3:00:00 AM\",\"Ready\"\r\nINFO: there are no scheduled tasks presently available at your access level.\r\n";
    parseSchtasks(&snap, tasks);
    try tt.expectEqual(@as(usize, 5), snap.persist.items.len);
    try tt.expectEqualStrings("task:\\AMDLinkUpdate", snap.persist.items[3]);
    try tt.expectEqualStrings("task:\\Evil Task", snap.persist.items[4]);
}

test "ss -tunapH: LISTEN and UNCONN services with their process, ESTAB peers, ephemeral UDP skipped" {
    var snap = Snapshot.init(tt.allocator);
    defer snap.deinit();
    const ss =
        \\tcp   LISTEN 0      128          0.0.0.0:22        0.0.0.0:*     users:(("sshd",pid=800,fd=3))
        \\tcp   LISTEN 0      4096       127.0.0.1:8787      0.0.0.0:*     users:(("veil",pid=9580,fd=12))
        \\tcp   ESTAB  0      0        192.168.1.5:40000  203.0.113.9:4444  users:(("nc",pid=1234,fd=3))
        \\udp   UNCONN 0      0      127.0.0.53%lo:53        0.0.0.0:*     users:(("systemd-resolve",pid=500,fd=13))
        \\udp   UNCONN 0      0            0.0.0.0:58000     0.0.0.0:*     users:(("chrome",pid=2,fd=9))
        \\tcp   LISTEN 0      128             [::]:22           [::]:*     users:(("sshd",pid=800,fd=4))
    ;
    parseSs(&snap, ss);
    try tt.expectEqual(@as(usize, 4), snap.listeners.items.len);
    try tt.expectEqualStrings("sshd", snap.listeners.items[0].name);
    try tt.expectEqual(@as(u32, 800), snap.listeners.items[0].pid);
    try tt.expectEqualStrings("127.0.0.53%lo", snap.listeners.items[2].addr);
    try tt.expect(!exposedAddr(snap.listeners.items[2].addr));
    try tt.expectEqualStrings("::", snap.listeners.items[3].addr);
    try tt.expectEqual(@as(usize, 1), snap.conns.items.len);
    var kb: [512]u8 = undefined;
    try tt.expectEqualStrings("out|nc|4444", outboundKey(&kb, snap.conns.items[0]).?);
}

test "lsof -nP: LISTEN rows, ESTABLISHED peers, UDP services, '*' as the wildcard" {
    var snap = Snapshot.init(tt.allocator);
    defer snap.deinit();
    const lsof =
        \\COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        \\rapportd    600 gary    4u  IPv4 0x1234567890      0t0  TCP *:49152 (LISTEN)
        \\veil       9580 gary   12u  IPv4 0x1234567891      0t0  TCP 127.0.0.1:8787 (LISTEN)
        \\Safari      700 gary   20u  IPv4 0x1234567892      0t0  TCP 192.168.1.9:50000->93.184.216.34:443 (ESTABLISHED)
        \\mDNSRespo   300 _mdns   8u  IPv4 0x1234567893      0t0  UDP *:5353
        \\Safari      700 gary   21u  IPv4 0x1234567894      0t0  UDP 192.168.1.9:60000
    ;
    parseLsof(&snap, lsof);
    try tt.expectEqual(@as(usize, 3), snap.listeners.items.len);
    try tt.expectEqualStrings("0.0.0.0", snap.listeners.items[0].addr);
    try tt.expectEqual(@as(u16, 49152), snap.listeners.items[0].port);
    try tt.expectEqualStrings("rapportd", snap.listeners.items[0].name);
    try tt.expectEqual(Proto.udp, snap.listeners.items[2].proto);
    try tt.expectEqual(@as(usize, 1), snap.conns.items.len);
    try tt.expectEqualStrings("93.184.216.34", snap.conns.items[0].raddr);
}

test "a rule spec is validated: ports need a protocol, a remote must look like an address, ids are slugs, something must narrow it" {
    var r = Rule{};
    try tt.expectEqualStrings("a rule needs a port, a remote address or a program (or it would match everything)", ruleFromSpec(&r, .{ .port = 0 }).?);
    try tt.expectEqualStrings("a port needs a protocol: tcp or udp", ruleFromSpec(&r, .{ .port = 80, .protocol = "any" }).?);
    try tt.expect(ruleFromSpec(&r, .{ .port = 80, .remote = "evil; rm -rf /" }) != null);
    try tt.expect(ruleFromSpec(&r, .{ .port = 80, .remote = "example.com" }) != null); // names resolve later and differently; addresses only
    try tt.expect(ruleFromSpec(&r, .{ .port = 80, .id = "bad id!" }) != null);
    try tt.expect(ruleFromSpec(&r, .{ .port = 80, .program = "C:\\x\" & calc.exe" }) != null);
    try tt.expect(ruleFromSpec(&r, .{ .port = 4444, .remote = "203.0.113.0/24", .id = "no-irc", .note = "tab\there" }) == null);
    try tt.expectEqual(@as(u16, 4444), r.port);
    try tt.expectEqualStrings("203.0.113.0/24", r.remoteStr());
    try tt.expectEqualStrings("no-irc", r.idStr());
    try tt.expectEqualStrings("tab here", r.noteStr());
    try tt.expect(ruleFromSpec(&r, .{ .remote = "2001:db8::/32", .direction = "out", .protocol = "any", .action = "allow" }) == null);
    try tt.expectEqual(Dir.out, r.dir);
    try tt.expectEqual(Action.allow, r.action);
}

test "netsh add-rule arguments are one key=value per argv element, named with the prefix, local port in, remote port out" {
    const gpa = tt.allocator;
    var r = Rule{};
    try tt.expect(ruleFromSpec(&r, .{ .id = "no-irc", .port = 6667, .direction = "out", .remote = "203.0.113.9", .program = "C:\\Program Files\\odd\\odd.exe" }) == null);
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    try backend.netshArgs(gpa, &argv, &r);
    try tt.expectEqualStrings("name=veil-sentry:no-irc", argv.items[0]);
    try tt.expectEqualStrings("dir=out", argv.items[1]);
    try tt.expectEqualStrings("action=block", argv.items[2]);
    try tt.expectEqualStrings("protocol=TCP", argv.items[3]);
    try tt.expectEqualStrings("remoteport=6667", argv.items[4]);
    try tt.expectEqualStrings("remoteip=203.0.113.9", argv.items[5]);
    try tt.expectEqualStrings("program=C:\\Program Files\\odd\\odd.exe", argv.items[6]);
    try tt.expect(std.mem.startsWith(u8, argv.items[7], "description=written by the veil's sentry"));
    // inbound: the port is the local one
    var r2 = Rule{};
    try tt.expect(ruleFromSpec(&r2, .{ .id = "close-4444", .port = 4444 }) == null);
    var argv2: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (argv2.items) |a| gpa.free(a);
        argv2.deinit(gpa);
    }
    try backend.netshArgs(gpa, &argv2, &r2);
    try tt.expectEqualStrings("localport=4444", argv2.items[4]);
}

test "netsh show rule: only names with our prefix are ours" {
    const gpa = tt.allocator;
    const text = "\r\nRule Name:                            Microsoft.Office.ActionsServer\r\n----\r\nEnabled:                              Yes\r\n\r\nRule Name:                            veil-sentry:no-irc\r\n----\r\nEnabled:                              Yes\r\n\r\nRule Name:                            veil-sentry-lookalike\r\n\r\nRule Name:                            veil-sentry:auto-tcp-4444\r\n";
    var ids: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (ids.items) |i| gpa.free(i);
        ids.deinit(gpa);
    }
    backend.parseNetshRuleNames(gpa, text, &ids);
    try tt.expectEqual(@as(usize, 2), ids.items.len);
    try tt.expectEqualStrings("no-irc", ids.items[0]);
    try tt.expectEqualStrings("auto-tcp-4444", ids.items[1]);
}

test "nft rule arguments and handle listing: chain, match, verdict, quoted comment; handles map back to ids and chains" {
    const gpa = tt.allocator;
    var r = Rule{};
    try tt.expect(ruleFromSpec(&r, .{ .id = "no-irc", .port = 6667, .direction = "out", .remote = "203.0.113.9" }) == null);
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    try backend.nftArgs(gpa, &argv, &r);
    const want = [_][]const u8{ "tcp", "dport", "6667", "ip", "daddr", "203.0.113.9", "drop", "comment", "\"veil-sentry:no-irc\"" };
    try tt.expectEqual(want.len, argv.items.len);
    for (want, argv.items) |w, g| try tt.expectEqualStrings(w, g);
    const listing =
        \\table inet veil_sentry { # handle 12
        \\    chain input { # handle 1
        \\        type filter hook input priority filter; policy accept;
        \\        tcp dport 4444 drop comment "veil-sentry:auto-tcp-4444" # handle 5
        \\    }
        \\    chain output { # handle 2
        \\        type filter hook output priority filter; policy accept;
        \\        tcp dport 6667 ip daddr 203.0.113.9 drop comment "veil-sentry:no-irc" # handle 7
        \\    }
        \\}
    ;
    var hs: std.ArrayListUnmanaged(backend.NftHandle) = .empty;
    defer hs.deinit(gpa);
    backend.parseNftHandles(gpa, listing, &hs);
    try tt.expectEqual(@as(usize, 2), hs.items.len);
    try tt.expect(hs.items[0].input);
    try tt.expectEqual(@as(u64, 5), hs.items[0].handle);
    try tt.expectEqualStrings("auto-tcp-4444", listing[hs.items[0].id_at..hs.items[0].id_end]);
    try tt.expect(!hs.items[1].input);
    try tt.expectEqual(@as(u64, 7), hs.items[1].handle);
    try tt.expectEqualStrings("no-irc", listing[hs.items[1].id_at..hs.items[1].id_end]);
}

test "a pf line: block in by port, block out to an address, pass" {
    var r = Rule{};
    var buf: [400]u8 = undefined;
    try tt.expect(ruleFromSpec(&r, .{ .id = "close-4444", .port = 4444 }) == null);
    try tt.expectEqualStrings("block in proto tcp from any to any port 4444 # veil-sentry:close-4444", backend.pfLine(&buf, &r));
    try tt.expect(ruleFromSpec(&r, .{ .id = "no-irc", .port = 6667, .direction = "out", .remote = "203.0.113.9", .action = "allow" }) == null);
    try tt.expectEqualStrings("pass out proto tcp from any to 203.0.113.9 port 6667 # veil-sentry:no-irc", backend.pfLine(&buf, &r));
}

test "policy JSON round-trips: posture, cadence, allowlist, rules with ids; a malformed rule is dropped, not the file" {
    const gpa = tt.allocator;
    var p = Policy{ .enabled = true, .posture = .enforce, .auto_block = true, .every_s = 120 };
    p.allow_ports[0] = 8787;
    p.allow_ports[1] = 3000;
    p.allow_n = 2;
    try tt.expect(ruleFromSpec(&p.rules[0], .{ .id = "no-irc", .port = 6667, .direction = "out", .remote = "203.0.113.9", .note = "irc \"quoted\"" }) == null);
    p.rules[0].created = 1760000000;
    p.rules_n = 1;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try encodePolicy(gpa, &out, &p);
    const back = parsePolicy(gpa, out.items).?;
    try tt.expect(back.enabled and back.posture == .enforce and back.auto_block);
    try tt.expectEqual(@as(u32, 120), back.every_s);
    try tt.expectEqual(@as(u8, 2), back.allow_n);
    try tt.expect(back.allowed(3000) and !back.allowed(22));
    try tt.expectEqual(@as(u8, 1), back.rules_n);
    try tt.expectEqualStrings("no-irc", back.rules[0].idStr());
    try tt.expectEqualStrings("irc \"quoted\"", back.rules[0].noteStr());
    try tt.expectEqual(@as(i64, 1760000000), back.rules[0].created);
    // a rule with a bad remote is dropped; the file still loads; cadence is clamped
    const bad = "{\"enabled\":true,\"posture\":\"observe\",\"every_s\":1,\"rules\":[{\"id\":\"x\",\"port\":80,\"remote\":\"nope\"},{\"id\":\"ok\",\"port\":81}]}";
    const b2 = parsePolicy(gpa, bad).?;
    try tt.expectEqual(@as(u8, 1), b2.rules_n);
    try tt.expectEqualStrings("ok", b2.rules[0].idStr());
    try tt.expectEqual(MIN_EVERY_S, b2.every_s);
    try tt.expect(parsePolicy(gpa, "not json") == null);
}

/// A Sentry over a scratch data dir, with the policy file written so configure() reads it.
fn scratchSentry(gpa: std.mem.Allocator, io: std.Io, root: []const u8, policy_json: ?[]const u8) !*Sentry {
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var pb: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ root, DIR });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
    if (policy_json) |pj| {
        var fb: [512]u8 = undefined;
        const f = try std.fmt.bufPrint(&fb, "{s}/policy.json", .{dir});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f, .data = pj });
    }
    const s = try gpa.create(Sentry);
    s.* = Sentry.init(gpa, io, root);
    s.configure(.{ .own_ports = &.{8787}, .environ = null });
    return s;
}

fn snapWith(gpa: std.mem.Allocator, netstat: []const u8) Snapshot {
    var snap = Snapshot.init(gpa);
    parseNetstat(&snap, netstat);
    nameByPid(&snap, TASKLIST_SAMPLE, .tasklist);
    snap.fw = .on;
    return snap;
}

test "first scan adopts the machine as the baseline; a later network-reachable listener is a high finding, loopback is low, the veil's own port is not a finding, an allowlisted port is info" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-sentry-tmp-diff";
    const s = try scratchSentry(gpa, io, root, "{\"enabled\":true,\"posture\":\"observe\",\"allow_ports\":[3000]}");
    defer {
        s.deinit();
        gpa.destroy(s);
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
    }
    // scan 1 on the sample inventory: adopt
    {
        var snap = snapWith(gpa, NETSTAT_SAMPLE);
        defer snap.deinit();
        s.mu.lockUncancelable(io);
        s.adoptLocked(&snap);
        s.noteLocked(.info, .baseline, "adopted");
        s.fwLocked(&snap);
        s.mu.unlock(io);
    }
    try tt.expect(s.baseline.items.len >= 8);
    const before = s.seq;
    // scan 2: three new listeners (0.0.0.0:4444 odd.exe, 127.0.0.1:5000, 0.0.0.0:3000) and the veil on 0.0.0.0:8787 unchanged
    const later = NETSTAT_SAMPLE ++ "\n  TCP    0.0.0.0:4444           0.0.0.0:0              LISTENING       7001\n  TCP    127.0.0.1:5000         0.0.0.0:0              LISTENING       7000\n  TCP    0.0.0.0:3000           0.0.0.0:0              LISTENING       7000\n";
    {
        var snap = snapWith(gpa, later);
        defer snap.deinit();
        s.mu.lockUncancelable(io);
        s.diffLocked(&snap, false);
        s.mu.unlock(io);
    }
    try tt.expectEqual(@as(u64, 3), s.seq - before);
    const j = s.findingsJson(gpa, before, .info, 10);
    defer gpa.free(j);
    try tt.expect(std.mem.indexOf(u8, j, "\"severity\":\"high\",\"kind\":\"new_listener\"") != null);
    try tt.expect(std.mem.indexOf(u8, j, "0.0.0.0:4444 (odd.exe, pid 7001)") != null);
    try tt.expect(std.mem.indexOf(u8, j, "\"severity\":\"low\",\"kind\":\"new_listener\"") != null);
    try tt.expect(std.mem.indexOf(u8, j, "loopback 127.0.0.1:5000") != null);
    try tt.expect(std.mem.indexOf(u8, j, "\"severity\":\"info\",\"kind\":\"new_listener\"") != null);
    try tt.expect(std.mem.indexOf(u8, j, "port is on the allowlist") != null);
    try tt.expect(std.mem.indexOf(u8, j, "8787") == null);
    // the same inventory again: nothing new (noted)
    {
        var snap = snapWith(gpa, later);
        defer snap.deinit();
        s.mu.lockUncancelable(io);
        s.diffLocked(&snap, false);
        s.mu.unlock(io);
    }
    try tt.expectEqual(@as(u64, 3), s.seq - before);
    // the open count sees them; ack clears; baseline moves them in
    try tt.expectEqual(@as(u32, 4), s.openCount()); // + the adopt note
    try tt.expect(s.set(.{ .ack = true }) == null);
    try tt.expectEqual(@as(u32, 0), s.openCount());
    try tt.expect(s.set(.{ .baseline = true }) == null);
    try tt.expectEqual(@as(usize, 0), s.noted.items.len);
    var kb: [512]u8 = undefined;
    try tt.expect(Sentry.keyIn(&s.baseline, listenerKey(&kb, .{ .proto = .tcp, .addr = "0.0.0.0", .port = 4444, .pid = 0, .name = "odd.exe" })));
    // a baseline listener that disappears is reported once, as info
    const seq2 = s.seq;
    {
        var snap = snapWith(gpa, NETSTAT_SAMPLE);
        defer snap.deinit();
        s.mu.lockUncancelable(io);
        s.diffLocked(&snap, false);
        s.diffLocked(&snap, false);
        s.mu.unlock(io);
    }
    try tt.expectEqual(@as(u64, 3), s.seq - seq2);
    const g = s.findingsJson(gpa, seq2, .info, 10);
    defer gpa.free(g);
    try tt.expect(std.mem.indexOf(u8, g, "\"kind\":\"listener_gone\"") != null);
    // the firewall going off is high; coming back is info; steady state is silent
    {
        var snap = snapWith(gpa, NETSTAT_SAMPLE);
        defer snap.deinit();
        snap.fw = .off;
        s.mu.lockUncancelable(io);
        s.fwLocked(&snap);
        s.fwLocked(&snap);
        snap.fw = .on;
        s.fwLocked(&snap);
        s.mu.unlock(io);
    }
    const f = s.findingsJson(gpa, seq2 + 3, .info, 10);
    defer gpa.free(f);
    try tt.expect(std.mem.indexOf(u8, f, "\"severity\":\"high\",\"kind\":\"firewall_off\"") != null);
    try tt.expect(std.mem.indexOf(u8, f, "\"kind\":\"firewall_on\"") != null);
    try tt.expectEqual(@as(usize, 2), std.mem.count(u8, f, "\"kind\":\"firewall_"));
}

test "state survives a restart: findings seq, ack, noted keys and the baseline are read back; the doctrine names the open count" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-sentry-tmp-persist";
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    {
        const s = try scratchSentry(gpa, io, root, "{\"enabled\":true}");
        defer {
            s.deinit();
            gpa.destroy(s);
        }
        var snap = snapWith(gpa, NETSTAT_SAMPLE);
        defer snap.deinit();
        s.mu.lockUncancelable(io);
        s.adoptLocked(&snap);
        s.noteLocked(.info, .baseline, "adopted");
        s.noteLocked(.high, .new_listener, "something");
        s.saveStateLocked();
        s.mu.unlock(io);
        try tt.expect(s.set(.{ .ack_upto = 1 }) == null);
        var db: [600]u8 = undefined;
        const d = s.doctrine(&db);
        try tt.expect(std.mem.indexOf(u8, d, "1 finding(s) await review, 1 high") != null);
        try tt.expect(std.mem.indexOf(u8, d, "posture observe") != null);
    }
    {
        var s2 = Sentry.init(gpa, io, root);
        defer s2.deinit();
        s2.configure(.{ .own_ports = &.{8787} });
        try tt.expectEqual(@as(u64, 2), s2.seq);
        try tt.expectEqual(@as(u64, 1), s2.acked);
        try tt.expect(s2.baseline.items.len >= 8);
        try tt.expect(s2.policy.enabled);
        // a finding is not re-reported after a restart: the ring is empty but the key is noted
        try tt.expectEqual(@as(u32, 0), s2.openCount()); // ring does not persist; the file does
        var pb: [512]u8 = undefined;
        const ev = try std.fmt.bufPrint(&pb, "{s}/{s}/events.jsonl", .{ root, DIR });
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, ev, gpa, .limited(1 << 20));
        defer gpa.free(raw);
        try tt.expectEqual(@as(usize, 2), std.mem.count(u8, raw, "\n"));
        try tt.expect(std.mem.indexOf(u8, raw, "\"seq\":2,") != null);
    }
    // enabled_default seeds a fresh install only: a policy file wins over NL_SENTRY
    {
        var s3 = Sentry.init(gpa, io, root);
        defer s3.deinit();
        s3.configure(.{ .enabled_default = false });
        try tt.expect(s3.policy.enabled);
    }
    {
        const fresh = "zig-sentry-tmp-fresh";
        defer std.Io.Dir.cwd().deleteTree(io, fresh) catch {};
        std.Io.Dir.cwd().deleteTree(io, fresh) catch {};
        var s4 = Sentry.init(gpa, io, fresh);
        defer s4.deinit();
        s4.configure(.{ .enabled_default = true, .every_default = 5 });
        try tt.expect(s4.policy.enabled);
        try tt.expectEqual(MIN_EVERY_S, s4.policy.every_s);
        var s5 = Sentry.init(gpa, io, fresh);
        defer s5.deinit();
        s5.configure(.{ .enabled_default = false });
        try tt.expect(s5.policy.enabled); // the file it wrote is now the truth
    }
}

test "rules through the Sentry: added with a minted id, refused for the veil's own port, listed, removed; observe never calls the host" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-sentry-tmp-rules";
    const s = try scratchSentry(gpa, io, root, "{\"enabled\":true,\"posture\":\"observe\"}");
    defer {
        s.deinit();
        gpa.destroy(s);
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
    }
    switch (s.addRule(.{ .port = 8787 })) {
        .err => |e| try tt.expect(std.mem.indexOf(u8, e, "own ports") != null),
        .id => return error.TestUnexpectedResult,
    }
    const id = switch (s.addRule(.{ .port = 4444, .note = "odd.exe" })) {
        .id => |i| try gpa.dupe(u8, i),
        .err => return error.TestUnexpectedResult,
    };
    defer gpa.free(id);
    try tt.expectEqualStrings("block-in-tcp-4444-1", id);
    switch (s.addRule(.{ .id = id, .port = 4445 })) {
        .err => |e| try tt.expect(std.mem.indexOf(u8, e, "exists") != null),
        .id => return error.TestUnexpectedResult,
    }
    const rj = s.rulesJson(gpa);
    defer gpa.free(rj);
    try tt.expect(std.mem.indexOf(u8, rj, "\"id\":\"block-in-tcp-4444-1\"") != null);
    try tt.expect(std.mem.indexOf(u8, rj, "\"on_host\":false") != null);
    // the tool face
    const out = run(s, gpa, "sentry_rules", "{}");
    defer gpa.free(out);
    try tt.expect(std.mem.startsWith(u8, out, "posture: observe"));
    const rm = run(s, gpa, "sentry_rule", "{\"op\":\"remove\",\"id\":\"block-in-tcp-4444-1\"}");
    defer gpa.free(rm);
    try tt.expect(std.mem.startsWith(u8, rm, "rule removed"));
    try tt.expectEqual(@as(u8, 0), s.policy.rules_n);
    const nope = run(s, gpa, "sentry_rule", "{\"op\":\"remove\",\"id\":\"ghost\"}");
    defer gpa.free(nope);
    try tt.expectEqualStrings("no rule with that id", nope);
    const refused = run(s, gpa, "sentry_rule", "{\"op\":\"add\",\"port\":80,\"protocol\":\"any\"}");
    defer gpa.free(refused);
    try tt.expect(std.mem.startsWith(u8, refused, "refused: a port needs a protocol"));
    // settings: posture/enabled/allowlist; ack; a bad posture
    try tt.expectEqualStrings("posture must be observe or enforce", s.set(.{ .posture = "yolo" }).?);
    try tt.expect(s.set(.{ .allow_port = 3000, .every_s = 10 }) == null);
    try tt.expect(s.policy.allowed(3000));
    try tt.expectEqual(MIN_EVERY_S, s.policy.every_s);
    try tt.expect(s.set(.{ .disallow_port = 3000 }) == null);
    try tt.expect(!s.policy.allowed(3000));
    const st = s.statusJson(gpa);
    defer gpa.free(st);
    try tt.expect(std.mem.indexOf(u8, st, "\"posture\":\"observe\"") != null);
    try tt.expect(std.mem.indexOf(u8, st, "\"own_ports\":[8787]") != null);
}

test "a scan never waits for another: while one holds the scan lock, a second caller returns busy at once" {
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-sentry-tmp-busy";
    const s = try scratchSentry(gpa, io, root, "{\"enabled\":true}");
    defer {
        s.deinit();
        gpa.destroy(s);
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
    }
    try tt.expect(s.scan_mu.tryLock()); // a scan in progress
    const rep = s.scan(true);
    try tt.expect(rep.busy);
    try tt.expect(!rep.ran);
    const out = run(s, gpa, "sentry_scan", "{}");
    defer gpa.free(out);
    try tt.expect(std.mem.startsWith(u8, out, "a scan is already running"));
    s.scan_mu.unlock(io);
}

test "the tool face without a sentry refuses; every verb in SCHEMA dispatches; an unknown verb names the real ones" {
    const gpa = tt.allocator;
    const none = run(null, gpa, "sentry_status", "{}");
    defer gpa.free(none);
    try tt.expectEqualStrings(NOT_HERE, none);
    var i: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, SCHEMA, i, "\"name\":\"")) |at| {
        const from = at + "\"name\":\"".len;
        const to = std.mem.indexOfScalarPos(u8, SCHEMA, from, '"') orelse break;
        i = to;
        const name = SCHEMA[from..to];
        try tt.expect(isTool(name));
        try tt.expect(std.mem.indexOf(u8, @embedFile("sentry.zig"), name) != null);
        n += 1;
    }
    try tt.expectEqual(@as(usize, 6), n);
    try tt.expect(!isTool("sentry"));
    try tt.expect(isTool("sentry_anything"));
    // the fragment parses as a JSON array once wrapped
    const wrapped = try std.fmt.allocPrint(gpa, "[{s}]", .{SCHEMA});
    defer gpa.free(wrapped);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, wrapped, .{});
    defer parsed.deinit();
    try tt.expectEqual(@as(usize, 6), parsed.value.array.items.len);
}

test "the live inventory on this host parses into rows, never crashes, and names its own listeners" {
    // Runs the real commands of this OS. On a runner without them (no ss, no netsh) `errors` counts them and
    // the rows stay empty, which is also a pass: coverage is reported, not faked.
    const gpa = tt.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var snap = Snapshot.init(gpa);
    defer snap.deinit();
    capture(gpa, io, null, &snap);
    // A second command's output must not have overwritten the first's rows (the 2026-10-11 bug): every address
    // is made of address characters, every name is printable.
    for (snap.listeners.items) |l| {
        try tt.expect(l.port != 0 or l.proto == .udp);
        try tt.expect(l.addr.len > 0);
        for (l.addr) |c| try tt.expect(std.ascii.isHex(c) or c == '.' or c == ':' or c == '%' or c == '*');
        try tt.expect(l.name.len > 0);
        for (l.name) |c| try tt.expect(c >= 0x20 and c != 0x7F);
    }
    for (snap.conns.items) |c| {
        try tt.expect(c.raddr.len > 0);
        for (c.raddr) |ch| try tt.expect(std.ascii.isHex(ch) or ch == '.' or ch == ':' or ch == '%');
    }
    var kb: [512]u8 = undefined;
    for (snap.persist.items) |p| try tt.expect(persistKey(&kb, p).len > 2);
}
