//! Supervisor — spawns + tracks one native Zig worker process per swarm, and enforces the per-user mind cap

const std = @import("std");
const builtin = @import("builtin");
const crypto = @import("../../config/key_vault.zig");
const dataset = @import("../dataset.zig"); // training-set root, injected so a mind records into the same set
const NeuronLedger = @import("../../plan/neurons.zig").NeuronLedger;
const cpaths = @import("../chat/paths.zig"); // conv → build-tree mapping (scheduled runs → _sched/{task}/runs/)
const llm = @import("../llm.zig"); // the curl key-config names and their age floor, for sweepKeyScratch

const log = std.log.scoped(.supervisor);

// Native process liveness/termination via the Win32 API directly — NO subprocess. Spawning tasklist/taskkill
// on the httpz request thread for every reconcile-probe and kill starves the worker pool under load; and a
// recycled stale pid handed to taskkill could target the server itself. Direct API calls are cheap and
// never touch the process table via a shell.
const winproc = if (builtin.os.tag == .windows) struct {
    const HANDLE = *anyopaque;
    const BOOL = c_int; // Win32 BOOL is a 32-bit int at the ABI; plain c_int lets `0` coerce cleanly
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const PROCESS_TERMINATE: u32 = 0x0001;
    const STILL_ACTIVE: u32 = 259;
    extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.c) ?HANDLE;
    extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *u32) callconv(.c) BOOL;
    extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.c) BOOL;
    extern "kernel32" fn QueryFullProcessImageNameW(h: HANDLE, flags: u32, buf: [*]u16, size: *u32) callconv(.c) BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.c) BOOL;
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
} else struct {};

/// Sleep `ms` on a thread the Io runtime did not spawn: bgLoop (a detached std.Thread) and remove's rmTree
/// retries (an httpz worker, from adminKill and swarmDelete). Never io.sleep there. On Windows io.sleep parks the
/// thread on the runtime's per-thread alert (NtWaitForAlertByThreadId), and on such a thread a wake the runtime
/// did not ask for is `unreachable` — undefined behaviour in the ReleaseFast build. It does not throw (Zig 0.16.0,
/// measured 2026-09-16); the alert is the hazard, and alerts are sticky, so one stray alert lands in the next park
/// (desk/src/nap.zig has the 2026-09-02 desk freeze it caused). Win32 Sleep is non-alertable. Elsewhere io.sleep
/// does not park, so it stays.
fn threadSleepMs(io: std.Io, ms: u64) void {
    if (builtin.os.tag == .windows) {
        winproc.Sleep(@intCast(ms));
    } else {
        io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
    }
}

/// True only if `path16` (a UTF-16 full image path) has basename "veil.exe" (case-insensitive).
fn imageIsVeil(path16: []const u16) bool {
    var start: usize = 0;
    for (path16, 0..) |c, i| if (c == '\\' or c == '/') {
        start = i + 1;
    };
    const base = path16[start..];
    const want = "veil.exe";
    if (base.len != want.len) return false;
    for (base, want) |c16, w| {
        const c: u16 = if (c16 >= 'A' and c16 <= 'Z') c16 + 32 else c16;
        if (c != w) return false;
    }
    return true;
}

/// Native, no-subprocess: is `pid` a live process whose image is veil.exe (i.e. an actual worker)? false on
/// any failure — dead, access-denied, or a recycled pid now owned by some other app.
fn liveVeilPid(pid: u32) bool {
    if (builtin.os.tag != .windows or pid == 0) return false;
    const h = winproc.OpenProcess(winproc.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = winproc.CloseHandle(h);
    var code: u32 = 0;
    if (winproc.GetExitCodeProcess(h, &code) == 0 or code != winproc.STILL_ACTIVE) return false;
    var buf: [520]u16 = undefined;
    var sz: u32 = buf.len;
    if (winproc.QueryFullProcessImageNameW(h, 0, &buf, &sz) == 0) return false;
    return imageIsVeil(buf[0..sz]);
}

/// Native force-kill, but ONLY if `pid` is still a live veil worker and not our own process. A recycled stale
/// worker.pid can point at the server itself or an unrelated app — this refuses to touch either.
fn terminateVeilPid(pid: u32) void {
    if (builtin.os.tag != .windows or pid == 0) return;
    if (pid == std.os.windows.GetCurrentProcessId()) return;
    const h = winproc.OpenProcess(winproc.PROCESS_TERMINATE | winproc.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return;
    defer _ = winproc.CloseHandle(h);
    var code: u32 = 0;
    if (winproc.GetExitCodeProcess(h, &code) == 0 or code != winproc.STILL_ACTIVE) return;
    var buf: [520]u16 = undefined;
    var sz: u32 = buf.len;
    if (winproc.QueryFullProcessImageNameW(h, 0, &buf, &sz) == 0 or !imageIsVeil(buf[0..sz])) return;
    _ = winproc.TerminateProcess(h, 1);
}

/// .stopping = a stop/kill was REQUESTED but the worker process hasn't been confirmed dead yet (the STOP
/// file is cooperative — the worker acts on it at its next turn/round boundary). reconcile() flips it to
/// .stopped once the pid is actually gone or the worker wrote its DONE marker.
pub const State = enum { starting, running, stopping, stopped, crashed };

pub const Swarm = struct {
    id: []const u8,
    uid: u64,
    name: []const u8,
    run_dir: []const u8,
    model: []const u8,
    minds: usize,
    created: i64,
    child: ?std.process.Child = null,
    state: State = .starting,
    encrypted: bool = false,
    last_check: i64 = 0,
    restarts: u32 = 0,
    last_restart: i64 = 0,
    breaker_open: bool = false,
    metered_neurons: u64 = 0,
};

pub const Supervisor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    neuron_bin: []const u8,
    mu: std.Io.Mutex = .init,
    // Serializes worker CreateProcess/spawn calls. On Windows, std.process.spawn calls CreateProcessW with
    // bInheritHandles=TRUE and no HANDLE_LIST, so two spawns racing on different threads cross-inherit each
    // other's inheritable pipe handles, wedging the pipe reads. Spawns are ~2-6ms, so serializing them is
    // negligible latency and closes the race.
    launch_mu: std.Io.Mutex = .init,
    swarms: std.StringHashMapUnmanaged(*Swarm) = .empty,
    server_key: [32]u8 = undefined,
    parent_env: ?*const std.process.Environ.Map = null,
    last_gc: i64 = 0,
    ledger: ?*NeuronLedger = null,
    bg_stop: std.atomic.Value(bool) = .init(false),
    gc_data_dir: []const u8 = "",
    gc_days: u32 = 0,
    /// TEST ONLY: a pid that pidAlive reads as a live worker on every OS. A unit test cannot start a veil worker, and
    /// on Windows only a live veil.exe image counts. 0, the default, matches no pid.
    test_live_pid: if (builtin.is_test) u32 else void = if (builtin.is_test) 0 else {},

    pub fn init(gpa: std.mem.Allocator, io: std.Io, neuron_bin: []const u8) Supervisor {
        return .{ .gpa = gpa, .io = io, .neuron_bin = neuron_bin };
    }

    /// Background maintenance thread: reconcile swarm states + prune old runs every ~5s, OFF the httpz request
    /// threads. reconcile() probes worker liveness and can respawn a worker; doing that inline in a request
    /// handler starves the pool and wedges the server. Request handlers just read the in-memory map; this loop
    /// keeps it fresh. Fire-and-forget (detached).
    pub fn bgLoop(self: *Supervisor) void {
        while (!self.bg_stop.load(.monotonic)) {
            self.reconcile();
            if (self.gc_days > 0) self.maybeGc(self.gc_data_dir, self.gc_days);
            // real sleep on a raw thread (see threadSleepMs) — 5s in 100ms slices so stop stays responsive
            var slept: usize = 0;
            while (slept < 50 and !self.bg_stop.load(.monotonic)) : (slept += 1) threadSleepMs(self.io, 100);
        }
    }

    pub fn liveMindsForUser(self: *Supervisor, uid: u64) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var n: usize = 0;
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.uid == uid and (s.state == .running or s.state == .starting)) n += s.minds;
        }
        return n;
    }

    pub fn activeSwarmsForUser(self: *Supervisor, uid: u64) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var n: usize = 0;
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.uid == uid and (s.state == .running or s.state == .starting)) n += 1;
        }
        return n;
    }

    fn launch(self: *Supervisor, run_dir: []const u8, model: []const u8) !struct { child: std.process.Child, encrypted: bool } {
        var exebuf: [4096]u8 = undefined;
        const n = try std.process.executablePath(self.io, &exebuf);
        const argv = [_][]const u8{ exebuf[0..n], "worker", run_dir, self.neuron_bin, model };
        var opts: std.process.SpawnOptions = .{
            .argv = &argv,
            .cwd = .{ .path = run_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true, // don't pop a console window per worker on Windows (windowless parent)
        };
        var child_env: ?ChildEnv = if (self.parent_env) |penv| self.childEnv(penv, run_dir) else null;
        defer if (child_env) |*ce| ce.map.deinit();
        if (child_env) |*ce| opts.environ_map = &ce.map;
        const child = try std.process.spawn(self.io, opts);
        // `encrypted` is the SEALED-KEYS signal, not "did we build an env" — a child env may exist
        // only to carry the training-set root, which is not a credential fact.
        return .{ .child = child, .encrypted = if (child_env) |ce| ce.encrypted else false };
    }

    pub fn spawn(self: *Supervisor, uid: u64, id: []const u8, name: []const u8, run_dir: []const u8, model: []const u8, minds: usize) !*Swarm {
        const launched = blk: {
            self.launch_mu.lockUncancelable(self.io); // serialize CreateProcess against concurrent spawns
            defer self.launch_mu.unlock(self.io);
            break :blk try self.launch(run_dir, model);
        };

        const sw = try self.gpa.create(Swarm);
        sw.* = .{
            .id = try self.gpa.dupe(u8, id),
            .uid = uid,
            .name = try self.gpa.dupe(u8, name),
            .run_dir = try self.gpa.dupe(u8, run_dir),
            .model = try self.gpa.dupe(u8, model),
            .minds = minds,
            .created = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            .child = launched.child,
            .state = .running,
            .encrypted = launched.encrypted,
        };
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.swarms.put(self.gpa, sw.id, sw);
        return sw;
    }

    const MAX_RESTARTS: u32 = 3;
    const HEALTH_RESET_SECS: i64 = 300;

    fn respawn(self: *Supervisor, id: []const u8) void {
        var rd_buf: [1280]u8 = undefined;
        var md_buf: [256]u8 = undefined;
        var run_dir: []const u8 = "";
        var model: []const u8 = "";
        const copied = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const sw = self.swarms.get(id) orelse return;
            run_dir = std.fmt.bufPrint(&rd_buf, "{s}", .{sw.run_dir}) catch break :blk false;
            model = std.fmt.bufPrint(&md_buf, "{s}", .{sw.model}) catch break :blk false;
            break :blk true;
        };
        var failure: []const u8 = "its run dir or model name overflows the relaunch buffers";
        const launched = if (!copied) null else blk: {
            self.launch_mu.lockUncancelable(self.io); // serialize CreateProcess against concurrent spawns
            defer self.launch_mu.unlock(self.io);
            break :blk self.launch(run_dir, model) catch |err| {
                failure = @errorName(err);
                break :blk null;
            };
        };
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const sw = self.swarms.get(id) orelse return;
        const relaunched = launched orelse {
            // A crash that will not be relaunched must not look like one that will. reconcile never probes a .crashed
            // entry again, so with the breaker still closed it stayed "relaunching" forever (see relaunchPending).
            sw.breaker_open = true;
            log.warn("could not relaunch crashed swarm {s} ({s}) — circuit-breaker OPEN, leaving it crashed", .{ id, failure });
            return;
        };
        sw.child = relaunched.child;
        sw.state = .running;
        sw.restarts += 1;
        sw.last_restart = now;
        sw.last_check = now;
        log.info("auto-restarted crashed swarm {s} (restart {d}/{d})", .{ id, sw.restarts, MAX_RESTARTS });
    }

    /// The child's environment, or null to inherit the parent's unchanged. TWO independent reasons to
    /// build one, so the result says which applied: the run's sealed keys (the `encrypted` signal the
    /// caller reports back), and the training-set root (NL_SETS_DIR) so a mind's LLM calls and tool
    /// runs land in the SAME set the server is recording — a worker is a separate process and has no
    /// other way to find it. Neither present ⇒ null ⇒ the parent env, exactly as before.
    const ChildEnv = struct { map: std.process.Environ.Map, encrypted: bool };

    fn childEnv(self: *Supervisor, penv: *const std.process.Environ.Map, run_dir: []const u8) ?ChildEnv {
        const sets = dataset.setsDir();
        var keys: ?[]u8 = null;
        defer if (keys) |k| self.gpa.free(k);
        {
            var ebuf: [1280]u8 = undefined;
            if (std.fmt.bufPrint(&ebuf, "{s}/keys.env.enc", .{run_dir})) |p| {
                if (std.Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, .limited(8 << 10))) |b64| {
                    defer self.gpa.free(b64);
                    keys = crypto.open(self.gpa, self.server_key, std.mem.trim(u8, b64, " \r\n\t"));
                } else |_| {}
            } else |_| {}
        }
        if (keys == null and sets.len == 0) return null;
        var m = penv.clone(self.gpa) catch return null;
        if (sets.len > 0) m.put("NL_SETS_DIR", sets) catch {};
        if (keys) |pt| {
            var it = std.mem.tokenizeAny(u8, pt, "\r\n");
            while (it.next()) |line| {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                m.put(line[0..eq], line[eq + 1 ..]) catch {};
            }
        }
        return .{ .map = m, .encrypted = keys != null };
    }

    pub fn get(self: *Supervisor, id: []const u8) ?*Swarm {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.swarms.get(id);
    }

    /// get(), but tolerant of every id form in the wild, for the account `uid` asking: the registry key (the
    /// spawn-time hex id for a live swarm) OR any id that names one of that account's RUN DIRS (idMatchesRunDir) —
    /// a chat or deploy dir's basename (what a server restart re-adopts it as, and what the desktop Swarm tab sends),
    /// or the conversation whose build root castSwarm spawned it into, a sub-chat naming its family's. A run-dir name
    /// belongs to one account: conversation and task ids are minted from the clock, so two accounts can hold the
    /// same one, and each must reach its own run. One run dir can carry several entries: every re-cast into a
    /// conversation or its family registers a fresh hex id on the SAME dir, and the old entries stay. The NEWEST
    /// registration is the dir's current worker (deploySwarm reset the dir's lifecycle files when it spawned), so a
    /// run-dir id resolves to it, even when that id is also a re-adopted dir's key. A key that names no dir of its
    /// own (a spawn id, or a re-adopted dir's account-qualified key, see adoptKey) still names exactly its own swarm,
    /// whichever account owns it, so callers check the owner. Callers that mutate must use the returned swarm's own
    /// `.id` — it may differ from the id they passed.
    pub fn resolve(self: *Supervisor, uid: u64, id: []const u8) ?*Swarm {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.swarms.get(id)) |s| {
            if (!idMatchesRunDir(s.run_dir, id)) return s; // a spawn id, not a name for the dir it builds in
        }
        var newest: ?*Swarm = null;
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.uid != uid or !idMatchesRunDir(s.run_dir, id)) continue;
            if (newest == null or s.created > newest.?.created) newest = s;
        }
        return newest;
    }

    pub fn stop(self: *Supervisor, id: []const u8) void {
        // Read run_dir + set state UNDER the lock (respawn/meter/reconcile touch the same Swarm concurrently
        // on other httpz threads); the STOP-file IO runs after on a local copy of the path.
        var buf: [1024]u8 = undefined;
        var stop_path: []const u8 = "";
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const sw = self.swarms.get(id) orelse return;
            stop_path = std.fmt.bufPrint(&buf, "{s}/STOP", .{sw.run_dir}) catch return;
            // Truthful state: the STOP file is a cooperative REQUEST the worker acts on at its next turn/
            // round boundary. Report .stopping; reconcile flips it to .stopped once the pid is confirmed
            // dead (or DONE appears). A .crashed worker is already dead — that one IS stopped now.
            if (sw.state == .running or sw.state == .starting) {
                sw.state = .stopping;
            } else if (sw.state == .crashed) {
                sw.state = .stopped;
            }
        }
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = stop_path, .data = "" }) catch {};
    }

    /// Hard-kill a swarm's worker WITHOUT touching its run dir (unlike remove(), nothing is deleted): write
    /// the STOP file (so a worker that survives the kill still stops cooperatively), then terminate the process
    /// — the owned Child handle if we hold one, else via the pid file. killByPidFile routes through
    /// terminateVeilPid, which refuses our own pid and any pid that isn't a LIVE veil worker (a stale/recycled
    /// worker.pid could otherwise target the server itself — that check is load-bearing). A run dir whose worker
    /// already wrote DONE skips the pid-file path (clean exit; nothing left to kill). State goes to .stopping;
    /// reconcile confirms the death and flips it to .stopped. False = unknown id.
    pub fn kill(self: *Supervisor, id: []const u8) bool {
        var rd_buf: [1024]u8 = undefined;
        var run_dir: []const u8 = "";
        var child_copy: ?std.process.Child = null;
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const sw = self.swarms.get(id) orelse return false;
            const n = @min(sw.run_dir.len, rd_buf.len);
            @memcpy(rd_buf[0..n], sw.run_dir[0..n]);
            run_dir = rd_buf[0..n];
            child_copy = sw.child;
            sw.child = null;
            if (sw.state != .stopped) sw.state = .stopping;
        }
        var pbuf: [1200]u8 = undefined;
        if (std.fmt.bufPrint(&pbuf, "{s}/STOP", .{run_dir})) |sp| {
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = sp, .data = "" }) catch {};
        } else |_| {}
        if (child_copy) |*c| {
            c.kill(self.io); // blocks until dead + reaps the handle
        } else if (!self.hasDoneMarker(run_dir)) {
            self.killByPidFile(run_dir);
        }
        // A hard TerminateProcess never runs the worker's own writeDone, leaving no DONE marker, no terminal
        // "stopped" event, and a stale worker.pid — and desktop watchers key off "stopped" to see a cast finish.
        // Stamp the terminal state ourselves now the process is dead: append a "stopped" event, write DONE, drop
        // the pid file. No-op if the worker already exited cleanly and wrote its own DONE.
        if (!self.hasDoneMarker(run_dir)) self.writeKillMarker(run_dir);
        return true;
    }

    /// Stamp a run dir as terminated after a hard kill — the supervisor's replica of the worker's writeDone
    /// (run.zig): append a terminal "stopped" event so filesystem watchers converge, write DONE so reconcile
    /// treats a dead pid as finished (never a crash to respawn), and delete the now-stale worker.pid.
    fn writeKillMarker(self: *Supervisor, run_dir: []const u8) void {
        var pbuf: [1280]u8 = undefined;
        // append a terminal "stopped" event (read whole + rewrite — the killed worker's log is frozen, so no
        // concurrent writer; bounded by the run's own event volume)
        if (std.fmt.bufPrint(&pbuf, "{s}/events.jsonl", .{run_dir})) |evp| {
            const line = "{\"seq\":0,\"t\":0,\"kind\":\"stopped\",\"reason\":\"killed\"}\n";
            const prior = std.Io.Dir.cwd().readFileAlloc(self.io, evp, self.gpa, .limited(64 << 20)) catch &[_]u8{};
            defer if (prior.len > 0) self.gpa.free(prior);
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(self.gpa);
            buf.appendSlice(self.gpa, prior) catch return;
            buf.appendSlice(self.gpa, line) catch return;
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = evp, .data = buf.items }) catch {};
        } else |_| {}
        if (std.fmt.bufPrint(&pbuf, "{s}/DONE", .{run_dir})) |dp| {
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dp, .data = "killed" }) catch {};
        } else |_| {}
        if (std.fmt.bufPrint(&pbuf, "{s}/worker.pid", .{run_dir})) |pp| {
            std.Io.Dir.cwd().deleteFile(self.io, pp) catch {};
        } else |_| {}
    }

    pub fn remove(self: *Supervisor, id: []const u8) void {
        // Snapshot run_dir, take ownership of the ?Child, and UNLINK the map entry — all UNDER the lock — so
        // no other thread can race the ?Child (respawn writes it under the same lock) or get() a swarm that's
        // mid-teardown. The slow STOP-write + process kill + rmTree then run on LOCAL copies, lock released.
        // The *Swarm heap object is intentionally NOT freed: other threads may still hold a get() pointer to
        // it, and the small per-remove leak is far cheaper than a use-after-free.
        var rd_buf: [1024]u8 = undefined;
        var run_dir: []const u8 = "";
        var child_copy: ?std.process.Child = null;
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const sw = self.swarms.get(id) orelse return;
            const n = @min(sw.run_dir.len, rd_buf.len);
            @memcpy(rd_buf[0..n], sw.run_dir[0..n]);
            run_dir = rd_buf[0..n];
            child_copy = sw.child;
            sw.child = null;
            sw.state = .stopped;
            _ = self.swarms.remove(id);
        }
        var pbuf: [1024]u8 = undefined;
        const sp = std.fmt.bufPrint(&pbuf, "{s}/STOP", .{run_dir}) catch run_dir;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = sp, .data = "" }) catch {};
        if (child_copy) |*c| c.kill(self.io) else self.killByPidFile(run_dir);
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            if (self.rmTree(run_dir)) break;
            threadSleepMs(self.io, 300); // an httpz worker thread: never io.sleep (see threadSleepMs)
        }
    }

    fn rmTree(self: *Supervisor, path: []const u8) bool {
        // A chat cast builds IN the chat's conversation dir (`.../_chat/builds/{conv}`) so the chat and its hive
        // co-edit one tree. That dir is OWNED BY THE CHAT, not the cast — tree-deleting it (on explicit stop or
        // retention GC) would wipe the user's files. For those, strip only the cast's own metadata (so retention
        // stops re-listing it and a re-cast starts from a clean slate) and LEAVE the deliverables under work/.
        if (std.mem.indexOf(u8, path, "_chat/builds") != null or std.mem.indexOf(u8, path, "_chat\\builds") != null) {
            self.cleanCastMeta(path);
            return true;
        }
        // A SCHEDULED task's run dir (`.../_sched/{task}/runs/{stamp}`) is the task's PERMANENT artifact store
        // — same rule as a chat build dir: strip the cast's own metadata, never tree-delete the user's files.
        if ((std.mem.indexOf(u8, path, "_sched/") != null or std.mem.indexOf(u8, path, "_sched\\") != null) and
            (std.mem.indexOf(u8, path, "/runs/") != null or std.mem.indexOf(u8, path, "\\runs\\") != null))
        {
            self.cleanCastMeta(path);
            return true;
        }
        // Native recursive delete — NO PowerShell/rm subprocess. Spawning a shell per delete on the httpz
        // request thread starves the worker pool under load. deleteTree is idempotent (an already-absent tree is
        // success); a locked file (a still-dying worker) errors -> caller retries.
        std.Io.Dir.cwd().deleteTree(self.io, path) catch return false;
        return true;
    }

    /// Remove a cast's own bookkeeping from a chat-owned build dir without touching the deliverables. Deleting
    /// events.jsonl + swarm.json is what matters for lifecycle: retention GC lists by events.jsonl age and
    /// reconcile rediscovers by swarm.json, so pulling both stops the dir being re-swept, while work/ and user
    /// files stay put. SECURITY: it must also sweep the per-mind curl scratch — `.curlcfg-<mind>` embeds the API
    /// key in an `Authorization: Bearer …` line; a normal swarm's full-tree wipe scrubs it, but a chat dir is not
    /// wiped, so the key would be stranded on disk. `.build_manifest` and DELIVERY/ are kept (the chat reads them).
    fn cleanCastMeta(self: *Supervisor, run_dir: []const u8) void {
        const meta = [_][]const u8{ "swarm.json", "worker.pid", "STOP", "DONE", "events.jsonl", "events.prev.jsonl", "control.jsonl", "mind.sqlite", ".usage", ".round_writes", ".explore_seen", "keys.env", "keys.env.enc" };
        var buf: [1200]u8 = undefined;
        for (meta) |f| {
            const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ run_dir, f }) catch continue;
            std.Io.Dir.cwd().deleteFile(self.io, p) catch {};
        }
        const md = std.fmt.bufPrint(&buf, "{s}/minds", .{run_dir}) catch return;
        std.Io.Dir.cwd().deleteTree(self.io, md) catch {};

        // Per-mind scratch (`.curlcfg-<mind>`, `.llmreq-<mind>.json`) is dynamically named, so sweep by prefix.
        // Collect names first, THEN delete — mutating a dir mid-iteration is asking for a skipped/aliased entry.
        var dir = std.Io.Dir.cwd().openDir(self.io, run_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch null) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.startsWith(u8, ent.name, ".curlcfg-") and !std.mem.startsWith(u8, ent.name, ".llmreq-")) continue;
            const dup = self.gpa.dupe(u8, ent.name) catch continue;
            names.append(self.gpa, dup) catch {
                self.gpa.free(dup);
                continue;
            };
        }
        for (names.items) |n| {
            const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ run_dir, n }) catch continue;
            std.Io.Dir.cwd().deleteFile(self.io, p) catch {};
        }
    }

    fn killByPidFile(self: *Supervisor, run_dir: []const u8) void {
        var pbuf: [1024]u8 = undefined;
        const pidpath = std.fmt.bufPrint(&pbuf, "{s}/worker.pid", .{run_dir}) catch return;
        const txt = std.Io.Dir.cwd().readFileAlloc(self.io, pidpath, self.gpa, .limited(64)) catch return;
        defer self.gpa.free(txt);
        const pid = std.fmt.parseInt(u32, std.mem.trim(u8, txt, " \r\n\t"), 10) catch return;
        if (pid == 0) return;
        if (builtin.os.tag == .windows) {
            // Native, no subprocess: terminateVeilPid refuses to touch our own pid or any process that isn't a
            // live veil worker (a recycled stale worker.pid could otherwise abort the server or a random app).
            terminateVeilPid(pid);
        } else {
            var nbuf: [16]u8 = undefined;
            const pidstr = std.fmt.bufPrint(&nbuf, "{d}", .{pid}) catch return;
            const res = std.process.run(self.gpa, self.io, .{ .argv = &.{ "kill", "-9", pidstr } }) catch return;
            self.gpa.free(res.stdout);
            self.gpa.free(res.stderr);
        }
    }

    /// Re-adopt every run dir under `data_dir` that holds a manifest (listRunDirs says which dirs are run dirs).
    pub fn reattach(self: *Supervisor, data_dir: []const u8) usize {
        var runs = self.listRunDirs(data_dir);
        defer runs.deinit(self.gpa);
        var n: usize = 0;
        for (runs.list.items) |run| {
            if (self.adoptOne(run.uid, run.path)) n += 1 else |_| {}
        }
        return n;
    }

    /// A fresh spawn id: 8 random bytes in lowercase hex. deploySwarm names a deploy's run dir by it, and listRunDirs
    /// knows a deploy's run dir among an account's other dirs by that shape (isSpawnId).
    pub fn newSpawnId(self: *Supervisor) [16]u8 {
        var rnd: [8]u8 = undefined;
        self.io.random(&rnd);
        return std.fmt.bytesToHex(rnd, .lower);
    }

    /// A run dir listRunDirs found: the account whose dir it sits in, and its path.
    const RunDir = struct { uid: u64, path: []const u8 };

    const RunDirs = struct {
        list: std.ArrayListUnmanaged(RunDir) = .empty,

        fn add(runs: *RunDirs, gpa: std.mem.Allocator, uid: u64, path: []const u8) void {
            const owned = gpa.dupe(u8, path) catch return;
            runs.list.append(gpa, .{ .uid = uid, .path = owned }) catch gpa.free(owned);
        }

        fn deinit(runs: *RunDirs, gpa: std.mem.Allocator) void {
            for (runs.list.items) |run| gpa.free(run.path);
            runs.list.deinit(gpa);
        }
    };

    /// Every dir under `data_dir` that the server spawns workers in, found only where deploySwarm puts one:
    ///   u{uid}/{spawn id}                    a deploy, or a cast with no conversation (newSpawnId)
    ///   u{uid}/_chat/builds/{conv}           a conversation's casts (chat/paths.zig buildRootRel)
    ///   u{uid}/_sched/{task}/runs/{stamp}    a scheduled run's casts (buildRootRel, read back by schedRunOfDir)
    /// Each path is spelled `{data_dir}/{rel}`, as a spawn spells its run dir. The walk never goes below a run dir: its
    /// work/ tree holds the hive's deliverables, where write_file puts any name at any depth, so a swarm.json or an
    /// events.jsonl there is a file of the run's, not another run. Listed recursively, such a folder became a phantom
    /// swarm on restart (for the account of the last "u<digits>" folder in its path) and retention deleted or stripped
    /// it. A
    /// conversation's own dir (u{uid}/_chat/convs/{conv}) keeps an events.jsonl too, and it is no run dir either.
    /// Symlinks are not followed.
    fn listRunDirs(self: *Supervisor, data_dir: []const u8) RunDirs {
        const io = self.io;
        var runs: RunDirs = .{};
        var root = std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch return runs;
        defer root.close(io);
        var accounts = root.iterate();
        while (accounts.next(io) catch null) |account| {
            if (!maybeDir(account.kind)) continue;
            const uid = accountUid(account.name) orelse continue;
            var adir = root.openDir(io, account.name, .{ .iterate = true }) catch continue;
            defer adir.close(io);
            var entries = adir.iterate();
            while (entries.next(io) catch null) |entry| {
                if (!maybeDir(entry.kind)) continue;
                var pb: [1024]u8 = undefined; // remove() copies a run dir into 1024 bytes: never list one it would clip
                if (isSpawnId(entry.name)) {
                    const path = std.fmt.bufPrint(&pb, "{s}/{s}/{s}", .{ data_dir, account.name, entry.name }) catch continue;
                    runs.add(self.gpa, uid, path);
                } else if (std.mem.eql(u8, entry.name, "_chat")) {
                    var builds = adir.openDir(io, "_chat/builds", .{ .iterate = true }) catch continue;
                    defer builds.close(io);
                    var convs = builds.iterate();
                    while (convs.next(io) catch null) |conv| {
                        if (!maybeDir(conv.kind)) continue;
                        const path = std.fmt.bufPrint(&pb, "{s}/{s}/_chat/builds/{s}", .{ data_dir, account.name, conv.name }) catch continue;
                        runs.add(self.gpa, uid, path);
                    }
                } else if (std.mem.eql(u8, entry.name, "_sched")) {
                    var sched = adir.openDir(io, "_sched", .{ .iterate = true }) catch continue;
                    defer sched.close(io);
                    var tasks = sched.iterate();
                    while (tasks.next(io) catch null) |task| {
                        if (!maybeDir(task.kind)) continue;
                        var tb: [320]u8 = undefined;
                        const runs_rel = std.fmt.bufPrint(&tb, "{s}/runs", .{task.name}) catch continue;
                        var stamps_dir = sched.openDir(io, runs_rel, .{ .iterate = true }) catch continue;
                        defer stamps_dir.close(io);
                        var stamps = stamps_dir.iterate();
                        while (stamps.next(io) catch null) |stamp| {
                            if (!maybeDir(stamp.kind)) continue;
                            const path = std.fmt.bufPrint(&pb, "{s}/{s}/_sched/{s}/runs/{s}", .{ data_dir, account.name, task.name, stamp.name }) catch continue;
                            if (cpaths.schedRunOfDir(path) == null) continue; // no run stamp: no scheduled run built here
                            runs.add(self.gpa, uid, path);
                        }
                    }
                }
            }
        }
        return runs;
    }

    pub fn maybeGc(self: *Supervisor, data_dir: []const u8, days: u32) void {
        if (days == 0) return;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        if (self.last_gc != 0 and now - self.last_gc < 3600) return;
        self.last_gc = now;
        const n = self.pruneOldRuns(data_dir, days);
        if (n > 0) log.info("retention: pruned {d} run dir(s) inactive >= {d}d", .{ n, days });
    }

    /// Retention: prune each run dir (listRunDirs) whose own events.jsonl was last written more than `days` days ago and
    /// that no running entry holds. rmTree decides how much of a dir goes. Returns how many were pruned.
    pub fn pruneOldRuns(self: *Supervisor, data_dir: []const u8, days: u32) usize {
        var runs = self.listRunDirs(data_dir);
        defer runs.deinit(self.gpa);
        const now_ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        const idle_ns = @as(i96, days) * std.time.ns_per_day;
        var pruned: usize = 0;
        for (runs.list.items) |run| {
            var pb: [1100]u8 = undefined;
            const ev = std.fmt.bufPrint(&pb, "{s}/events.jsonl", .{run.path}) catch continue;
            const st = std.Io.Dir.cwd().statFile(self.io, ev, .{}) catch continue;
            if (now_ns - st.mtime.nanoseconds <= idle_ns) continue;
            if (self.runDirIsLive(run.path)) continue;
            if (self.rmTree(run.path)) pruned += 1;
        }
        return pruned;
    }

    /// Remove the curl configs that outlived their calls: files llm.isKeyCfgName names, last written more than
    /// llm.KEY_CFG_STALE_S ago, in the dirs llm calls write scratch to - each run dir listRunDirs finds and the top of
    /// its work/ tree (pixelrag's vision call writes there), and each conversation dir (the chat engine's). Nothing
    /// below those levels is read. Returns how many it removed.
    ///
    /// SECURITY: every config holds an `Authorization: Bearer` line. llm.zig now deletes each one when its call ends,
    /// so only a process killed mid-call leaves one - but earlier builds left one behind for every (dir, tag) that
    /// ever called out, in dirs nothing wipes: a conversation dir lives as long as the conversation, and a chat build
    /// dir only loses its cast bookkeeping (cleanCastMeta). A names-only listing of one live data dir on 2026-09-17
    /// found 111. The age floor is what makes the sweep safe beside live calls (an adopted worker's, another server
    /// process's on the same data dir): a younger config may still be waiting for its curl to read it.
    pub fn sweepKeyScratch(self: *Supervisor, data_dir: []const u8) usize {
        const now_ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        var removed: usize = 0;
        var runs = self.listRunDirs(data_dir);
        defer runs.deinit(self.gpa);
        for (runs.list.items) |run| {
            removed += self.sweepKeyCfgs(run.path, now_ns);
            var pb: [1100]u8 = undefined;
            const work = std.fmt.bufPrint(&pb, "{s}/work", .{run.path}) catch continue;
            removed += self.sweepKeyCfgs(work, now_ns);
        }
        var root = std.Io.Dir.cwd().openDir(self.io, data_dir, .{ .iterate = true }) catch return removed;
        defer root.close(self.io);
        var accounts = root.iterate();
        while (accounts.next(self.io) catch null) |account| {
            if (!maybeDir(account.kind) or accountUid(account.name) == null) continue;
            var rb: [320]u8 = undefined;
            const convs_rel = std.fmt.bufPrint(&rb, "{s}/_chat/convs", .{account.name}) catch continue;
            var convs = root.openDir(self.io, convs_rel, .{ .iterate = true }) catch continue;
            defer convs.close(self.io);
            var it = convs.iterate();
            while (it.next(self.io) catch null) |conv| {
                if (!maybeDir(conv.kind)) continue;
                var pb: [1100]u8 = undefined;
                const conv_dir = std.fmt.bufPrint(&pb, "{s}/{s}/{s}", .{ data_dir, convs_rel, conv.name }) catch continue;
                removed += self.sweepKeyCfgs(conv_dir, now_ns);
            }
        }
        return removed;
    }

    /// sweepKeyScratch for one dir, its top level only.
    fn sweepKeyCfgs(self: *Supervisor, dir_path: []const u8, now_ns: i96) usize {
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);
        // Collect names first, THEN delete, as cleanCastMeta does: a dir mutated mid-iteration can skip an entry.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch null) |ent| {
            if (ent.kind != .file or !llm.isKeyCfgName(ent.name)) continue;
            const dup = self.gpa.dupe(u8, ent.name) catch continue;
            names.append(self.gpa, dup) catch {
                self.gpa.free(dup);
                continue;
            };
        }
        const stale_ns = @as(i96, llm.KEY_CFG_STALE_S) * std.time.ns_per_s;
        var removed: usize = 0;
        for (names.items) |n| {
            const st = dir.statFile(self.io, n, .{}) catch continue;
            if (now_ns - st.mtime.nanoseconds <= stale_ns) continue;
            dir.deleteFile(self.io, n) catch continue;
            removed += 1;
        }
        return removed;
    }

    fn runDirIsLive(self: *Supervisor, run_dir: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if ((s.state == .running or s.state == .starting) and sameRunDir(s.run_dir, run_dir)) return true;
        }
        return false;
    }

    pub fn meter(self: *Supervisor) void {
        const l = self.ledger orelse return;
        const Charge = struct { uid: u64, n: u64 };
        var charges: std.ArrayListUnmanaged(Charge) = .empty;
        defer charges.deinit(self.gpa);
        self.mu.lockUncancelable(self.io);
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.state != .running and s.state != .starting) continue;
            var pbuf: [1024]u8 = undefined;
            const up = std.fmt.bufPrint(&pbuf, "{s}/.usage", .{s.run_dir}) catch continue;
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, up, self.gpa, .limited(64)) catch continue;
            defer self.gpa.free(data);
            const cur = std.fmt.parseInt(u64, std.mem.trim(u8, data, " \r\n\t"), 10) catch continue;
            if (cur > s.metered_neurons) {
                charges.append(self.gpa, .{ .uid = s.uid, .n = cur - s.metered_neurons }) catch {};
                s.metered_neurons = cur;
            }
        }
        self.mu.unlock(self.io);
        for (charges.items) |c| l.charge(c.uid, c.n);
    }

    pub fn runningUids(self: *Supervisor, gpa: std.mem.Allocator) []u64 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var seen: std.ArrayListUnmanaged(u64) = .empty;
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.state != .running and s.state != .starting) continue;
            var dup = false;
            for (seen.items) |x| if (x == s.uid) {
                dup = true;
                break;
            };
            if (!dup) seen.append(gpa, s.uid) catch {};
        }
        return seen.toOwnedSlice(gpa) catch &[_]u64{};
    }

    pub fn pauseUserSwarms(self: *Supervisor, uid: u64) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var n: usize = 0;
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.uid != uid or (s.state != .running and s.state != .starting)) continue;
            var pbuf: [1024]u8 = undefined;
            const stop_path = std.fmt.bufPrint(&pbuf, "{s}/STOP", .{s.run_dir}) catch continue;
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = stop_path, .data = "" }) catch {};
            if (s.child != null) {
                s.child.?.kill(self.io);
                s.child = null;
            } else self.killByPidFile(s.run_dir);
            s.state = .stopped;
            n += 1;
        }
        return n;
    }

    const MindManifest = struct { name: []const u8 = "" };
    const Manifest = struct { swarm: []const u8 = "swarm", model: []const u8 = "mock", encrypted: bool = false, minds: []const MindManifest = &.{} };

    /// Re-adopt `run_dir`, a run dir of account `uid` holding a manifest, under the key adoptKey picks. The account is
    /// the one whose dir listRunDirs found it in, never a "u<digits>" name further down the path, which a conversation
    /// id can be. error.AlreadyTracked only when an entry already tracks that very dir: a dir that merely shares a name
    /// with a tracked one is another run, and skipping it left a live worker there unsupervised and unreachable by any id.
    fn adoptOne(self: *Supervisor, uid: u64, run_dir: []const u8) !void {
        var mb: [1100]u8 = undefined;
        const mani_path = try std.fmt.bufPrint(&mb, "{s}/swarm.json", .{run_dir});
        const data = try std.Io.Dir.cwd().readFileAlloc(self.io, mani_path, self.gpa, .limited(256 << 10));
        defer self.gpa.free(data);
        const parsed = try std.json.parseFromSlice(Manifest, self.gpa, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const m = parsed.value;
        const state = self.inferState(run_dir);
        const created = std.Io.Timestamp.now(self.io, .real).toSeconds();

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            if (sameRunDir(sp.*.run_dir, run_dir)) return error.AlreadyTracked;
        }
        const sw = try self.gpa.create(Swarm);
        errdefer self.gpa.destroy(sw);
        const id = try self.adoptKey(uid, run_dir);
        errdefer self.gpa.free(id);
        const name = try self.gpa.dupe(u8, m.swarm);
        errdefer self.gpa.free(name);
        const rd = try self.gpa.dupe(u8, run_dir);
        errdefer self.gpa.free(rd);
        const model = try self.gpa.dupe(u8, m.model);
        errdefer self.gpa.free(model);
        sw.* = .{
            .id = id,
            .uid = uid,
            .name = name,
            .run_dir = rd,
            .model = model,
            .minds = m.minds.len,
            .created = created,
            .child = null,
            .state = state,
            .encrypted = m.encrypted,
        };
        try self.swarms.put(self.gpa, sw.id, sw);
    }

    /// The key a re-adopted run dir registers under: the name clients already reach that dir by, when no other dir
    /// holds it as a key. A scheduled run's name is its conversation id, "scheduled_{task}_{stamp}": its basename,
    /// the stamp, is the minute the run started, so every task that ran in that minute shares it. Any other dir's
    /// name is its basename (a deploy's spawn id, a conversation's id). A name can still be taken, because
    /// conversation and task ids are minted from the clock and two accounts can hold the same one: the later dir
    /// then gets its account appended, "{name}.u{uid}" (and a count after that, should even that be taken). No
    /// conversation or spawn id contains a '.', so the qualified key names no run dir, and resolve answers it with
    /// exactly this entry. Caller holds `mu`; the key is gpa-owned.
    fn adoptKey(self: *Supervisor, uid: u64, run_dir: []const u8) ![]u8 {
        const name = if (cpaths.schedRunOfDir(run_dir)) |run|
            try std.fmt.allocPrint(self.gpa, "scheduled_{s}_{s}", .{ run.tid, run.stamp })
        else
            try self.gpa.dupe(u8, runDirBase(run_dir));
        if (!self.swarms.contains(name)) return name;
        defer self.gpa.free(name);
        var n: u32 = 1;
        while (true) : (n += 1) {
            const key = if (n == 1)
                try std.fmt.allocPrint(self.gpa, "{s}.u{d}", .{ name, uid })
            else
                try std.fmt.allocPrint(self.gpa, "{s}.u{d}.{d}", .{ name, uid, n });
            if (!self.swarms.contains(key)) return key;
            self.gpa.free(key);
        }
    }

    fn inferState(self: *Supervisor, run_dir: []const u8) State {
        if (self.hasTerminalMarker(run_dir)) return .stopped;
        // Adopt as .running ONLY if the worker process is actually alive right now. An old run dir (dead pid,
        // no terminal marker) must be adopted as .stopped — otherwise reconcile() "crash-detects" it and
        // respawns a fresh worker for every stale swarm on startup, a mass-respawn that melts a single box.
        const pid = self.workerPid(run_dir) orelse return .stopped;
        return if (self.pidAlive(pid)) .running else .stopped;
    }

    const RECHECK_SECS: i64 = 10;

    pub fn reconcile(self: *Supervisor) void {
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const Cand = struct { id: []const u8, run_dir: []const u8, st: State };
        var cands: std.ArrayList(Cand) = .empty;
        defer {
            for (cands.items) |c| {
                self.gpa.free(c.id);
                self.gpa.free(c.run_dir);
            }
            cands.deinit(self.gpa);
        }
        var restart_ids: std.ArrayList([]const u8) = .empty;
        defer {
            for (restart_ids.items) |rid| self.gpa.free(rid);
            restart_ids.deinit(self.gpa);
        }
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var it = self.swarms.valueIterator();
            while (it.next()) |sp| {
                const s = sp.*;
                if (s.state != .running and s.state != .starting and s.state != .stopping) continue;
                if (now - s.last_check < RECHECK_SECS) continue;
                s.last_check = now;
                const id = self.gpa.dupe(u8, s.id) catch continue;
                const rd = self.gpa.dupe(u8, s.run_dir) catch {
                    self.gpa.free(id);
                    continue;
                };
                cands.append(self.gpa, .{ .id = id, .run_dir = rd, .st = s.state }) catch {
                    self.gpa.free(id);
                    self.gpa.free(rd);
                };
            }
        }
        for (cands.items) |c| {
            // a .stopping swarm is confirmed by pid-death/DONE, not by probeState's STOP-file heuristic
            // (STOP is the stop REQUEST itself — it would flip .stopping to .stopped instantly and lie)
            const new_state = if (c.st == .stopping) self.probeStopping(c.run_dir) else self.probeState(c.run_dir);
            const done = new_state == .stopped and self.hasDoneMarker(c.run_dir);
            var reap: ?std.process.Child = null;
            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                if (self.swarms.get(c.id)) |s| {
                    if (s.state == .running or s.state == .starting) {
                        s.state = new_state;
                        if (new_state == .crashed and self.shouldRestart(s, now)) {
                            if (self.gpa.dupe(u8, c.id)) |rid|
                                restart_ids.append(self.gpa, rid) catch self.gpa.free(rid)
                            else |_| {}
                        }
                        // a finished worker (clean exit wrote DONE) whose Child handle we still hold: reap it
                        if (done) {
                            reap = s.child;
                            s.child = null;
                        }
                    } else if (s.state == .stopping and new_state == .stopped) {
                        // stop/kill confirmed: the pid is actually gone (or the worker wrote DONE) — NOW
                        // it's truthfully stopped. Never respawn a swarm the operator asked to stop.
                        s.state = .stopped;
                        reap = s.child;
                        s.child = null;
                    }
                }
            }
            // outside the lock: kill() on an already-dead child returns at once and frees the handle
            if (reap) |*ch| ch.kill(self.io);
        }
        for (restart_ids.items) |rid| self.respawn(rid);
    }

    /// The auto-restart policy as a pure function of an entry at `now`: a crashed worker is relaunched while its breaker
    /// is closed and it has used fewer than MAX_RESTARTS restarts, a count that starts over once HEALTH_RESET_SECS pass
    /// after the last one. shouldRestart applies the verdict and relaunchPending only reads it, so they cannot drift.
    fn restartPolicy(s: *const Swarm, now: i64) struct { allow: bool, restarts: u32 } {
        if (s.breaker_open) return .{ .allow = false, .restarts = s.restarts };
        const restarts: u32 = if (s.last_restart != 0 and now - s.last_restart > HEALTH_RESET_SECS) 0 else s.restarts;
        return .{ .allow = restarts < MAX_RESTARTS, .restarts = restarts };
    }

    fn shouldRestart(_: *Supervisor, s: *Swarm, now: i64) bool {
        if (s.breaker_open) return false;
        const policy = restartPolicy(s, now);
        s.restarts = policy.restarts;
        if (!policy.allow) {
            s.breaker_open = true;
            log.warn("circuit-breaker OPEN for swarm {s} after {d} restarts — leaving it crashed", .{ s.id, s.restarts });
        }
        return policy.allow;
    }

    /// How old an entry's last probe or relaunch may be before relaunchPending stops vouching for it. A loop that keeps
    /// the entry re-probes it every RECHECK_SECS plus one ~5 s bgLoop sleep, so an older stamp means the loop is wedged
    /// or stuck behind a slow pass, and its verdict is no evidence that a worker is coming back. The bound is generous
    /// on purpose: a working loop settles a crash within one probe, so only a dead run under a stuck loop waits it out.
    const RELAUNCH_TRUST_SECS: i64 = 6 * RECHECK_SECS;

    /// Will reconcile put a worker back into `run_dir`? For a caller that just read the dir's worker.pid as dead and
    /// must not call the run finished: respawn relaunches a crash inside the restart budget into the SAME dir, so a
    /// run between workers looks like a finished one that never wrote DONE. True when an entry for the dir, probed or
    /// relaunched within RELAUNCH_TRUST_SECS, is relaunching it (.crashed with its breaker closed: the reconcile pass
    /// that marked it is launching the worker, and a launch that fails opens the breaker) or will (.running, where
    /// restartPolicy allows the restart, or a relaunch stamped it and no probe has read it since, so its worker may
    /// still be starting), and the dir, read by reconcile's own probe, holds that crash. A dir without a worker.pid
    /// never qualifies: reconcile reads it as running and relaunches nothing, while each probe keeps the entry fresh.
    /// A live pid answers true as well: the relaunch landed after the caller's read.
    pub fn relaunchPending(self: *Supervisor, run_dir: []const u8) bool {
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        const vouched = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            var it = self.swarms.valueIterator();
            while (it.next()) |sp| {
                const s = sp.*;
                if (!sameRunDir(s.run_dir, run_dir) or now - s.last_check > RELAUNCH_TRUST_SECS) continue;
                const relaunches = switch (s.state) {
                    .crashed => !s.breaker_open,
                    // respawn stamps last_check and last_restart with one `now`; any later probe moves last_check on
                    .running, .starting => restartPolicy(s, now).allow or (s.last_restart != 0 and s.last_check == s.last_restart),
                    .stopping, .stopped => false,
                };
                if (relaunches) break :blk true;
            }
            break :blk false;
        };
        if (!vouched) return false;
        return switch (self.probeRun(run_dir)) {
            .dead, .live => true,
            .terminal, .unclaimed => false,
        };
    }

    /// One run dir under two spellings: a spawn and reattach fmt-join it with '/' onto the native data path, while
    /// Windows spells the same dir with backslashes, so an entry and a caller can hold it in different slash forms.
    fn sameRunDir(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x == y) continue;
            if ((x == '/' or x == '\\') and (y == '/' or y == '\\')) continue;
            return false;
        }
        return true;
    }

    /// What a probe finds in a run dir: a terminal marker, no worker.pid yet, or its recorded worker alive or dead.
    /// probeState maps it to reconcile's State, and relaunchPending reads the same verdict.
    const Probe = enum { terminal, unclaimed, live, dead };

    fn probeRun(self: *Supervisor, run_dir: []const u8) Probe {
        if (self.hasTerminalMarker(run_dir)) return .terminal;
        const pid = self.workerPid(run_dir) orelse return .unclaimed;
        return if (self.pidAlive(pid)) .live else .dead;
    }

    fn probeState(self: *Supervisor, run_dir: []const u8) State {
        return switch (self.probeRun(run_dir)) {
            .terminal => .stopped,
            .unclaimed, .live => .running,
            .dead => .crashed,
        };
    }

    /// Probe for a swarm already in .stopping: only pid-death or the worker's DONE marker confirms the stop.
    /// The STOP file must NOT count here — it's the stop REQUEST (written by stop()/kill()), not evidence
    /// the process exited. A missing worker.pid also reads as gone: the clean-exit path deletes it.
    fn probeStopping(self: *Supervisor, run_dir: []const u8) State {
        if (self.hasDoneMarker(run_dir)) return .stopped;
        const pid = self.workerPid(run_dir) orelse return .stopped;
        return if (self.pidAlive(pid)) .stopping else .stopped;
    }

    /// The worker's clean-exit marker (<run_dir>/DONE, written beside the final "stopped" event).
    fn hasDoneMarker(self: *Supervisor, run_dir: []const u8) bool {
        var buf: [1280]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/DONE", .{run_dir}) catch return false;
        if (std.Io.Dir.cwd().access(self.io, p, .{})) |_| return true else |_| return false;
    }

    fn hasTerminalMarker(self: *Supervisor, run_dir: []const u8) bool {
        // Marker FILES first — cheap, and immune to events.jsonl size.
        if (self.hasDoneMarker(run_dir)) return true;
        var buf: [1280]u8 = undefined;
        const stop_path = std.fmt.bufPrint(&buf, "{s}/STOP", .{run_dir}) catch return false;
        if (std.Io.Dir.cwd().access(self.io, stop_path, .{})) |_| return true else |_| {}
        // Fallback for pre-DONE run dirs: the terminal record only lives inside events.jsonl. Read ONLY the
        // last 64KB — readFileAlloc(.limited) ERRORS (not truncates) past its cap, and that error read as
        // "no marker", which classified every long finished run as .crashed and made reconcile respawn
        // finished workers forever. Any read failure is just "no marker", never a crash signal by itself.
        const ev_path = std.fmt.bufPrint(&buf, "{s}/events.jsonl", .{run_dir}) catch return false;
        var tail_buf: [64 << 10]u8 = undefined;
        const tail = readTail(self.io, ev_path, &tail_buf) orelse return false;
        return std.mem.indexOf(u8, tail, "\"kind\":\"stopped\"") != null;
    }

    /// Native pid verdict for a run dir: the recorded worker.pid and whether it is a LIVE veil worker right
    /// now (a dead or recycled pid reads as not alive). pid 0 = no readable pid file.
    pub fn pidStatus(self: *Supervisor, run_dir: []const u8) struct { pid: u32, alive: bool } {
        const pid = self.workerPid(run_dir) orelse return .{ .pid = 0, .alive = false };
        return .{ .pid = pid, .alive = self.pidAlive(pid) };
    }

    fn workerPid(self: *Supervisor, run_dir: []const u8) ?u32 {
        var pbuf: [1280]u8 = undefined;
        const pidpath = std.fmt.bufPrint(&pbuf, "{s}/worker.pid", .{run_dir}) catch return null;
        const txt = std.Io.Dir.cwd().readFileAlloc(self.io, pidpath, self.gpa, .limited(64)) catch return null;
        defer self.gpa.free(txt);
        return std.fmt.parseInt(u32, std.mem.trim(u8, txt, " \r\n\t"), 10) catch null;
    }

    fn pidAlive(self: *Supervisor, pid: u32) bool {
        if (builtin.is_test) {
            if (pid != 0 and pid == self.test_live_pid) return true;
        }
        if (builtin.os.tag == .windows) {
            // Native check (no tasklist spawn): "alive" == a live veil worker. A recycled pid on an unrelated
            // app reads as NOT alive, so it can't become a phantom-running swarm or get force-killed.
            return liveVeilPid(pid);
        } else {
            var nbuf: [16]u8 = undefined;
            const pidstr = std.fmt.bufPrint(&nbuf, "{d}", .{pid}) catch return true;
            const argv = [_][]const u8{ "kill", "-0", pidstr };
            const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return true;
            defer self.gpa.free(res.stdout);
            defer self.gpa.free(res.stderr);
            return res.term == .exited and res.term.exited == 0;
        }
    }

    pub const Load = struct { swarms: usize = 0, live_swarms: usize = 0, live_minds: usize = 0 };

    pub fn load(self: *Supervisor) Load {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var l: Load = .{};
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            l.swarms += 1;
            if (s.state == .running or s.state == .starting) {
                l.live_swarms += 1;
                l.live_minds += s.minds;
            }
        }
        return l;
    }

    pub fn listForUser(self: *Supervisor, uid: u64) ![]*Swarm {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var list: std.ArrayList(*Swarm) = .empty;
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            if (sp.*.uid == uid) try list.append(self.gpa, sp.*);
        }
        return list.toOwnedSlice(self.gpa);
    }

    pub fn listAll(self: *Supervisor) ![]*Swarm {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var list: std.ArrayList(*Swarm) = .empty;
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| try list.append(self.gpa, sp.*);
        return list.toOwnedSlice(self.gpa);
    }
};

/// True when `id` names this run dir, among one account's dirs (resolve asks about the caller's entries only): a
/// chat or deploy dir by its BASENAME (either slash form) — the key a re-adopted dir gets and the id the desktop
/// Swarm tab sends — or any dir as a conversation id, through the build-root mapping castSwarm spawns every chat
/// cast with (paths.zig buildRootRel). A sub-chat ("<primary>__sN") builds in its primary's tree, so its id names
/// the FAMILY's run dir and matches exactly what the primary's id matches. A scheduled run's dir
/// (`.../_sched/{task}/runs/{stamp}`) answers to its conversation id alone: its basename is the minute the run
/// started, every task that ran in that minute has a dir by that name, so the bare stamp names no run.
fn idMatchesRunDir(run_dir: []const u8, id: []const u8) bool {
    if (id.len == 0) return false;
    // The id stands for its build family's root, as buildRootRel applies it: a sub-chat's primary, every other id itself.
    const root = cpaths.branchRoot(id);
    if (cpaths.schedRunOfDir(run_dir)) |run| {
        const conv = cpaths.schedParts(root) orelse return false;
        return std.mem.eql(u8, conv.tid, run.tid) and std.mem.eql(u8, conv.stamp, run.stamp);
    }
    const base = runDirBase(run_dir);
    return std.mem.eql(u8, base, id) or (root.len != id.len and std.mem.eql(u8, base, root));
}

/// A run dir's last segment, in either slash form. Hand-rolled, not std.fs.path.basename: that splits only on '/'
/// under POSIX, while run_dir strings are fmt-joined with '/' onto native base paths, so a Windows-written dir
/// carries both separator forms on any host.
fn runDirBase(run_dir: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, run_dir, "/\\");
    return if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i| trimmed[i + 1 ..] else trimmed;
}

/// The user id an account dir holds runs for: the server names it "u" and the decimal id ("u1", "u42").
fn accountUid(name: []const u8) ?u64 {
    if (name.len < 2 or name[0] != 'u') return null;
    for (name[1..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u64, name[1..], 10) catch null;
}

/// A deploy's run dir name: a spawn id as Supervisor.newSpawnId mints it, 16 lowercase hex digits.
fn isSpawnId(name: []const u8) bool {
    if (name.len != 16) return false;
    for (name) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    }
    return true;
}

/// A directory entry that may be a directory: a real one, or one whose type the filesystem did not report (a walk then
/// opens it and finds out). A symlink is not followed.
fn maybeDir(kind: std.Io.File.Kind) bool {
    return kind == .directory or kind == .unknown;
}

/// Read at most `buf.len` bytes from the END of the file at `path` (positional read at size-buf.len).
/// Returns the bytes read, or null on any error — callers treat null as "no data", never as a crash signal.
/// The slice may begin mid-line when the file was longer than the buffer.
pub fn readTail(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const size = f.length(io) catch return null;
    const off: u64 = if (size > buf.len) size - buf.len else 0;
    const n = f.readPositionalAll(io, buf, off) catch return null;
    return buf[0..n];
}

// ---------------------------------------------------------------------------------------------------- tests

test "idMatchesRunDir: basename hits on both slash forms, misses on substrings and the empty id" {
    try std.testing.expect(idMatchesRunDir("data/u1/_chat/builds/conv42", "conv42"));
    try std.testing.expect(idMatchesRunDir("data\\u1\\_chat\\builds\\conv42", "conv42"));
    try std.testing.expect(!idMatchesRunDir("data/u1/_chat/builds/conv42", "conv4"));
    try std.testing.expect(!idMatchesRunDir("data/u1/_chat/builds/conv42", "builds"));
    try std.testing.expect(!idMatchesRunDir("data/u1/_chat/builds/conv42", ""));
    // a scheduled conv id matches its task-tree run dir (whose basename is the bare stamp), both slash forms
    try std.testing.expect(idMatchesRunDir("data/u1/_sched/news-0715/runs/07171400", "scheduled_news-0715_07171400"));
    try std.testing.expect(idMatchesRunDir("data\\u1\\_sched\\news-0715\\runs\\07171400", "scheduled_news-0715_07171400"));
    try std.testing.expect(!idMatchesRunDir("data/u1/_sched/news-0715/runs/07171400", "scheduled_news-0715_07179999"));
    try std.testing.expect(!idMatchesRunDir("data/u1/_sched/xnews-0715/runs/07171400", "scheduled_news-0715_07171400"));
    // ...and by nothing else: its basename is the minute it ran, which every task that ran then shares
    try std.testing.expect(!idMatchesRunDir("data/u1/_sched/news-0715/runs/07171400", "07171400"));
    try std.testing.expect(!idMatchesRunDir("data\\u1\\_sched\\news-0715\\runs\\07171400", "07171400"));
    try std.testing.expect(!idMatchesRunDir("data/u1/_sched/news-0715/runs/07171400", "07171400__s1"));
}

test "a conversation id names exactly the run dirs castSwarm spawns its build family's casts into, in either slash form" {
    // Two derivations of one dir must meet: castSwarm (deploy/service.zig) spawns a conversation's cast with
    // run_dir = {data}/{buildRootRel(uid, conv)}, and resolve has only the conv id to find it again. For every pair
    // of convs, one's id must name the other's spawn dir exactly when buildRootRel sends both to the same dir: in
    // the fmt-joined form castSwarm registers, and in the backslash form Windows spells the same dir with.
    const convs = [_][]const u8{
        "c6a57f852", // ordinary: builds/{conv}
        "c6a57f852__s1", // its sub-chats share that tree
        "c6a57f852__s5",
        "c6a57f852__s6", // out of range: an ordinary conv with its own dir
        "c6a57f8521", // a neighbour whose id extends the primary's
        "c6a57f8521__s2",
        "scheduled_news-0715174857_07151753", // a scheduled run: _sched/{task}/runs/{stamp}
        "scheduled_news-0715174857_07151753__s1", // its sub-chat: both redirects at once
        "scheduled_news-0715174857_07151800", // the same task's next run
        "scheduled_digest-0715174901_07151753", // another task that ran in the same minute: a dir with the same basename
        "07151753", // an ordinary conv named like that minute: builds/{conv}, never either scheduled run's dir
        "scheduled_notes", // hand-named: an ordinary conv
    };
    for (convs) |a| {
        var ra: [256]u8 = undefined;
        const root_a = cpaths.buildRootRel(&ra, 7, a);
        try std.testing.expect(root_a.len > 0);
        var fb: [300]u8 = undefined;
        const spawned = try std.fmt.bufPrint(&fb, "C:/nl/data/{s}", .{root_a});
        var bb: [300]u8 = undefined;
        const adopted = bb[0..spawned.len];
        for (spawned, adopted) |c, *d| d.* = if (c == '/') '\\' else c;
        for (convs) |b| {
            var rb: [256]u8 = undefined;
            const same = std.mem.eql(u8, root_a, cpaths.buildRootRel(&rb, 7, b));
            if (idMatchesRunDir(spawned, b) != same or idMatchesRunDir(adopted, b) != same) {
                std.debug.print("id {s} vs the dir castSwarm spawns {s}'s cast into: same dir = {s}\n", .{ b, a, if (same) "yes" else "no" });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "resolve: a conversation's id finds the newest cast on its family's run dir, whichever order the registry yields them in" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var sup = Supervisor.init(gpa, threaded.io(), "");
    defer sup.swarms.deinit(gpa);
    try sup.swarms.ensureTotalCapacity(gpa, 8); // one slot layout for every pass below: no growth, no rehash
    const mk = struct {
        fn swarm(id: []const u8, run_dir: []const u8, created: i64, state: State) Swarm {
            return .{ .id = id, .uid = 7, .name = "cast", .run_dir = run_dir, .model = "mock", .minds = 3, .created = created, .state = state };
        }
    }.swarm;

    // castSwarm's dir for the primary AND every sub-chat of it: {data}/{buildRootRel(7, conv)}
    const family = "C:/nl/data/u7/_chat/builds/c6a57f852";
    const keys = [_][]const u8{ "5f0c2a9e41d7b3a6", "e83b17c4d2a09f55" };
    // Two casts on the family dir, the primary's (an hour old, finished) and a sub-chat's re-cast (running), beside
    // a neighbour family's cast newer than both and a scheduled run's. The passes swap which key holds the newer
    // cast. Slot order depends on the keys alone, so in one pass the stale cast comes first, which is exactly
    // where a first-match scan returns it.
    var stale_came_first = false;
    for (0..2) |pass| {
        sup.swarms.clearRetainingCapacity();
        var cast_a = mk(keys[0], family, 0, .stopped);
        var cast_b = mk(keys[1], family, 0, .stopped);
        const newest = if (pass == 0) &cast_a else &cast_b;
        const stale = if (pass == 0) &cast_b else &cast_a;
        stale.created = 1_700_000_000;
        newest.created = 1_700_003_600;
        newest.state = .running;
        var neighbour = mk("0a1b2c3d4e5f6071", "C:/nl/data/u7/_chat/builds/c6a57f8521", 1_700_009_000, .running);
        var sched_run = mk("9d8c7b6a5f4e3d2c", "C:/nl/data/u7/_sched/news-0715174857/runs/07151753", 1_700_001_000, .running);
        for ([_]*Swarm{ &cast_a, &cast_b, &neighbour, &sched_run }) |s| try sup.swarms.put(gpa, s.id, s);
        var vit = sup.swarms.valueIterator();
        while (vit.next()) |sp| {
            if (sp.* == stale) stale_came_first = true;
            if (sp.* == stale or sp.* == newest) break;
        }

        for ([_][]const u8{ "c6a57f852", "c6a57f852__s1", "c6a57f852__s5" }) |conv| {
            try std.testing.expectEqual(@as(?*Swarm, newest), sup.resolve(7, conv));
        }
        try std.testing.expectEqual(@as(?*Swarm, stale), sup.resolve(7, stale.id)); // a spawn id names its own swarm, however old
        try std.testing.expectEqual(@as(?*Swarm, stale), sup.resolve(8, stale.id)); // whoever asks: the caller checks the owner
        try std.testing.expectEqual(@as(?*Swarm, null), sup.resolve(8, "c6a57f852")); // but a conversation is one account's
        try std.testing.expectEqual(@as(?*Swarm, &neighbour), sup.resolve(7, "c6a57f8521__s2"));
        try std.testing.expectEqual(@as(?*Swarm, &sched_run), sup.resolve(7, "scheduled_news-0715174857_07151753__s1"));
        try std.testing.expectEqual(@as(?*Swarm, null), sup.resolve(7, "c6a57f852__s6")); // not a branch: its own dir holds no cast
        try std.testing.expectEqual(@as(?*Swarm, null), sup.resolve(7, "c6a57f85__s1")); // a primary id that only prefixes the family's
    }
    try std.testing.expect(stale_came_first);

    // After a restart, reattach keys the family dir by its basename, the conv id itself (spelled here with
    // backslashes), and a re-cast then lands beside it. The re-adopted KEY must not shadow the newer cast.
    sup.swarms.clearRetainingCapacity();
    var adopted = mk("c6a57f852", "C:\\nl\\data\\u7\\_chat\\builds\\c6a57f852", 1_700_000_000, .stopped);
    var recast = mk("3e2d1c0b9a887766", family, 1_700_000_600, .running);
    try sup.swarms.put(gpa, adopted.id, &adopted);
    try sup.swarms.put(gpa, recast.id, &recast);
    try std.testing.expectEqual(@as(?*Swarm, &recast), sup.resolve(7, "c6a57f852"));
    try std.testing.expectEqual(@as(?*Swarm, &recast), sup.resolve(7, "c6a57f852__s3"));
    try std.testing.expectEqual(@as(?*Swarm, &adopted), sup.get("c6a57f852")); // the exact-key read is unchanged
}

test "reattach adopts every run dir, whatever other dir shares its name, and each dir's names reach only that dir" {
    const gpa = std.testing.allocator;
    // reattach walks the data dir itself, but a listing that shelled out again must fail on what it lists, not on a
    // child that an empty environment cannot start
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = @import("../../gateway/http.zig").testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-supervisor-adopt-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const F = struct {
        /// `run_dir` is the data-relative dir `rel`, in either slash form, under whatever prefix the listing gave it.
        fn isRun(run_dir: []const u8, rel: []const u8) bool {
            if (run_dir.len <= rel.len) return false;
            const tail = run_dir[run_dir.len - rel.len ..];
            for (tail, rel) |c, r| {
                if (c != r and !(c == '\\' and r == '/')) return false;
            }
            const sep = run_dir[run_dir.len - rel.len - 1];
            return sep == '/' or sep == '\\';
        }
    };

    // The run dirs castSwarm spawned before a restart, {data}/{buildRootRel(uid, conv)}, each holding the manifest
    // deploySwarm wrote: two tasks of one account that ran in the same minute, so both dirs are named 07151753, and two
    // accounts whose desks minted the same conversation id in the same second.
    const Run = struct { uid: u64, conv: []const u8 };
    const runs = [_]Run{
        .{ .uid = 7, .conv = "scheduled_news-0715174857_07151753" },
        .{ .uid = 7, .conv = "scheduled_digest-0715174901_07151753" },
        .{ .uid = 1, .conv = "c6a57f852" },
        .{ .uid = 2, .conv = "c6a57f852" },
    };
    var rel_bufs: [runs.len][128]u8 = undefined;
    var rels: [runs.len][]const u8 = undefined;
    for (runs, &rel_bufs, &rels) |r, *rb, *rel| {
        rel.* = cpaths.buildRootRel(rb, r.uid, r.conv);
        var db: [200]u8 = undefined;
        const dir = try std.fmt.bufPrint(&db, root ++ "/{s}", .{rel.*});
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
        var mb: [220]u8 = undefined;
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fmt.bufPrint(&mb, "{s}/swarm.json", .{dir}),
            .data = "{\"swarm\":\"cast\",\"model\":\"mock\",\"minds\":[{\"name\":\"nova\"}]}",
        });
    }

    var sup = Supervisor.init(gpa, io, "");
    defer @import("fanout.zig").dropTestSwarms(&sup, gpa);
    try std.testing.expectEqual(@as(usize, runs.len), sup.reattach(root));
    try std.testing.expectEqual(@as(usize, 0), sup.reattach(root)); // each dir is tracked once: a second pass adds nothing

    // Every run dir has exactly one entry...
    var entries: [runs.len]*Swarm = undefined;
    for (rels, &entries) |rel, *entry| {
        const all = try sup.listAll();
        defer gpa.free(all);
        var found: ?*Swarm = null;
        for (all) |s| {
            if (!F.isRun(s.run_dir, rel)) continue;
            try std.testing.expect(found == null);
            found = s;
        }
        entry.* = found orelse {
            std.debug.print("{s} was not adopted\n", .{rel});
            return error.TestUnexpectedResult;
        };
    }
    // ...under a key that reaches it and only it. A scheduled run is keyed by its conversation, never by the stamp every
    // task that ran that minute shares. Of the two accounts' conversations, whichever the listing reached first keeps the
    // id and the other has its account appended.
    for (entries) |entry| {
        try std.testing.expectEqual(@as(?*Swarm, entry), sup.get(entry.id));
        try std.testing.expectEqual(@as(?*Swarm, entry), sup.resolve(entry.uid, entry.id));
    }
    try std.testing.expectEqualStrings(runs[0].conv, entries[0].id);
    try std.testing.expectEqualStrings(runs[1].conv, entries[1].id);
    try std.testing.expectEqual(@as(?*Swarm, null), sup.get("07151753"));
    const first: usize = if (std.mem.eql(u8, entries[2].id, "c6a57f852")) 2 else 3;
    const later = 5 - first;
    try std.testing.expectEqualStrings("c6a57f852", entries[first].id);
    var qb: [32]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&qb, "c6a57f852.u{d}", .{runs[later].uid}), entries[later].id);
    // the qualified key names that entry alone, even asked by the account whose conversation holds the bare id
    try std.testing.expectEqual(@as(?*Swarm, entries[later]), sup.resolve(runs[first].uid, entries[later].id));

    // Every conversation id (a sub-chat's too), asked by every account: it reaches that account's run of the
    // conversation and nothing else. The bare stamp reaches no run at all, and each account lists its own runs.
    for ([_]u64{ 1, 2, 7, 9 }) |uid| {
        for (runs) |named| {
            for ([_][]const u8{ "", "__s2" }) |suffix| {
                var nb: [80]u8 = undefined;
                const name = try std.fmt.bufPrint(&nb, "{s}{s}", .{ named.conv, suffix });
                var want: ?*Swarm = null;
                for (runs, entries) |r, entry| {
                    if (r.uid == uid and std.mem.eql(u8, r.conv, named.conv)) want = entry;
                }
                const got = sup.resolve(uid, name);
                errdefer std.debug.print("account {d} asked for {s} and reached {s}\n", .{ uid, name, if (got) |g| g.run_dir else "nothing" });
                try std.testing.expectEqual(want, got);
            }
        }
        try std.testing.expectEqual(@as(?*Swarm, null), sup.resolve(uid, "07151753"));
        const listed = try sup.listForUser(uid);
        defer gpa.free(listed);
        var owned: usize = 0;
        for (runs) |r| owned += @intFromBool(r.uid == uid);
        try std.testing.expectEqual(owned, listed.len);
    }
}

test "readTail: whole small file; only the last bytes of a big one; null for a missing path" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-supervisor-tail-tmp.jsonl";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var buf: [16]u8 = undefined;
    try std.testing.expect(readTail(io, path, &buf) == null); // missing file -> null, not an error

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "short" });
    try std.testing.expectEqualStrings("short", readTail(io, path, &buf).?);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "0123456789abcdefghij" }); // 20 > 16
    try std.testing.expectEqualStrings("456789abcdefghij", readTail(io, path, &buf).?);
}

test "relaunchPending vouches for a dead worker exactly when reconcile will relaunch it, and only while the loop keeps the entry" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-supervisor-relaunch-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const run_dir = root ++ "/u7/_chat/builds/c1";
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir);
    const dead_pid = "999999999"; // no process on any OS: Windows pids stay far below it, Linux caps them at 2^22
    const F = struct {
        fn put(io_: std.Io, dir: []const u8, name: []const u8, data: []const u8) !void {
            var b: [256]u8 = undefined;
            try std.Io.Dir.cwd().writeFile(io_, .{ .sub_path = try std.fmt.bufPrint(&b, "{s}/{s}", .{ dir, name }), .data = data });
        }
        fn drop(io_: std.Io, dir: []const u8, name: []const u8) !void {
            var b: [256]u8 = undefined;
            try std.Io.Dir.cwd().deleteFile(io_, try std.fmt.bufPrint(&b, "{s}/{s}", .{ dir, name }));
        }
    };

    var sup = Supervisor.init(gpa, io, "");
    defer sup.swarms.deinit(gpa);
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    // A cast whose worker crashed: its worker.pid names a process that is gone, and it wrote no DONE.
    try F.put(io, run_dir, "worker.pid", dead_pid);
    var cast: Swarm = .{ .id = "5b8e0f3a2c7d4e19", .uid = 7, .name = "cast", .run_dir = run_dir, .model = "mock", .minds = 3, .created = now - 600 };
    try sup.swarms.put(gpa, cast.id, &cast);

    // The restart policy, derived here from its rule, against both of its readers: shouldRestart (what reconcile does
    // at its probe) and relaunchPending. Every restart count to past the cap, with no restart yet, a recent one, and one
    // long enough ago that the count starts over. Each entry was probed after any relaunch, so no worker is starting.
    const recent = now - 60;
    const healed = now - Supervisor.HEALTH_RESET_SECS - 60;
    for (0..Supervisor.MAX_RESTARTS + 2) |n| {
        for ([_]i64{ 0, recent, healed }) |last_restart| {
            cast.state = .running;
            cast.breaker_open = false;
            cast.restarts = @intCast(n);
            cast.last_restart = last_restart;
            cast.last_check = now;
            const want = n < Supervisor.MAX_RESTARTS or last_restart == healed;
            var decided = cast; // shouldRestart stores its verdict in the entry, so it decides on a copy
            try std.testing.expectEqual(want, sup.shouldRestart(&decided, now));
            try std.testing.expectEqual(want, sup.relaunchPending(run_dir));
        }
    }

    // The last restart the policy allows, not probed since (respawn stamps last_check and last_restart with one `now`):
    // its worker may still be starting, and until it writes its own pid the dir holds the dead one it replaces.
    cast.restarts = Supervisor.MAX_RESTARTS;
    cast.last_restart = now - 30;
    cast.last_check = cast.last_restart;
    try std.testing.expect(sup.relaunchPending(run_dir));
    cast.last_check = cast.last_restart + Supervisor.RECHECK_SECS; // probed since: that crash is one the policy refuses
    try std.testing.expect(!sup.relaunchPending(run_dir));

    // .crashed is what reconcile marks right before respawn launches the worker: pending until a breaker opens.
    cast.restarts = 0;
    cast.last_restart = 0;
    cast.last_check = now;
    cast.state = .crashed;
    try std.testing.expect(sup.relaunchPending(run_dir));
    cast.breaker_open = true;
    try std.testing.expect(!sup.relaunchPending(run_dir));
    cast.breaker_open = false;
    for ([_]State{ .stopping, .stopped }) |asked_to_stop| {
        cast.state = asked_to_stop;
        try std.testing.expect(!sup.relaunchPending(run_dir));
    }
    cast.state = .running;

    // Only bookkeeping the loop still keeps vouches: RELAUNCH_TRUST_SECS after the last probe or relaunch, it lapses.
    const t = std.Io.Timestamp.now(io, .real).toSeconds();
    cast.last_check = t - Supervisor.RELAUNCH_TRUST_SECS + 5;
    try std.testing.expect(sup.relaunchPending(run_dir));
    cast.last_check = t - Supervisor.RELAUNCH_TRUST_SECS - 5;
    try std.testing.expect(!sup.relaunchPending(run_dir));
    cast.last_check = t;

    // The dir, read by reconcile's own probe. No worker.pid is no crash to relaunch: the probe reads the dir as running
    // and each probe keeps the entry fresh, so vouching for it would hold the run open forever. A stop request, DONE,
    // or a final "stopped" event ends the run instead.
    try std.testing.expect(sup.relaunchPending(run_dir));
    try F.drop(io, run_dir, "worker.pid");
    try std.testing.expect(!sup.relaunchPending(run_dir));
    try F.put(io, run_dir, "worker.pid", dead_pid);
    const Marker = struct { name: []const u8, data: []const u8 };
    const markers = [_]Marker{
        .{ .name = "STOP", .data = "" },
        .{ .name = "DONE", .data = "completed" },
        .{ .name = "events.jsonl", .data = "{\"seq\":7,\"t\":0,\"kind\":\"stopped\",\"reason\":\"goal_met\"}\n" },
    };
    for (markers) |m| {
        try F.put(io, run_dir, m.name, m.data);
        try std.testing.expect(!sup.relaunchPending(run_dir));
        try F.drop(io, run_dir, m.name);
    }
    try std.testing.expect(sup.relaunchPending(run_dir));

    // Every entry on the dir counts, in either slash form: a cast joins its run dir with '/', while Windows spells the
    // same dir with backslashes. An earlier cast's stopped entry beside it masks nothing.
    var adopted: [run_dir.len]u8 = undefined;
    for (run_dir, &adopted) |c, *d| d.* = if (c == '/') '\\' else c;
    cast.run_dir = &adopted;
    var earlier: Swarm = .{ .id = "c1", .uid = 7, .name = "cast", .run_dir = run_dir, .model = "mock", .minds = 3, .created = now - 7200, .state = .stopped, .last_check = now };
    try sup.swarms.put(gpa, earlier.id, &earlier);
    try std.testing.expect(sup.relaunchPending(run_dir));

    // No entry vouches for a dir it isn't on, even one whose name extends it.
    const sibling = root ++ "/u7/_chat/builds/c10";
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, sibling, .default_dir);
    try F.put(io, sibling, "worker.pid", dead_pid);
    cast.state = .stopped;
    var neighbour: Swarm = .{ .id = "0e4b6d8f2a1c3957", .uid = 7, .name = "cast", .run_dir = sibling, .model = "mock", .minds = 3, .created = now - 600, .last_check = now, .state = .running };
    try sup.swarms.put(gpa, neighbour.id, &neighbour);
    try std.testing.expect(!sup.relaunchPending(run_dir));
    try std.testing.expect(sup.relaunchPending(sibling));
}

test "a crash whose relaunch cannot launch opens its breaker instead of reading as relaunching forever" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-supervisor-relaunch-fail-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var sup = Supervisor.init(gpa, io, "");
    defer sup.swarms.deinit(gpa);
    const now = std.Io.Timestamp.now(io, .real).toSeconds();

    // Each crash stands as reconcile leaves one it queued for respawn: .crashed, breaker closed, probed this pass.
    // The first cast's run dir is gone, so `veil worker <run_dir>` cannot start there: the child's working directory
    // does not exist, and the launch fails before anything runs.
    var gone: Swarm = .{ .id = "3a9c5e7f1b2d4086", .uid = 7, .name = "cast", .run_dir = root ++ "/missing/u7/_chat/builds/c2", .model = "mock", .minds = 1, .created = now - 600, .state = .crashed, .last_check = now };
    try sup.swarms.put(gpa, gone.id, &gone);
    sup.respawn(gone.id);
    try std.testing.expect(gone.breaker_open);
    try std.testing.expect(gone.state == .crashed and gone.child == null and gone.restarts == 0);

    // The second's model name overflows respawn's copy, so it fails before any launch. Its dir holds the crash (a dead
    // worker.pid), and relaunchPending vouched for it until respawn gave up.
    const run_dir = root ++ "/u7/_chat/builds/c1";
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, run_dir, .default_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = run_dir ++ "/worker.pid", .data = "999999999" });
    var overflow: Swarm = .{ .id = "6d2f8a0c4e1b3957", .uid = 7, .name = "cast", .run_dir = run_dir, .model = "m" ** 300, .minds = 1, .created = now - 600, .state = .crashed, .last_check = now };
    try sup.swarms.put(gpa, overflow.id, &overflow);
    try std.testing.expect(sup.relaunchPending(run_dir));
    sup.respawn(overflow.id);
    try std.testing.expect(overflow.breaker_open);
    try std.testing.expect(overflow.state == .crashed and overflow.child == null);
    try std.testing.expect(!sup.relaunchPending(run_dir));
}

test "reattach adopts the run dirs the server spawns and no manifest a hive wrote into a run's work tree" {
    const gpa = std.testing.allocator;
    // Nothing here starts a child, but a listing that shelled out again must fail on what it lists, not on a child that
    // an empty environment cannot start.
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = @import("../../gateway/http.zig").testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-supervisor-worktree-adopt-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var sup = Supervisor.init(gpa, io, "");
    defer @import("fanout.zig").dropTestSwarms(&sup, gpa);

    // The walk knows a deploy's run dir by the shape of the id deploySwarm names it with.
    for (0..64) |_| try std.testing.expect(isSpawnId(&sup.newSpawnId()));

    // A run dir of each shape the server spawns a worker in, each holding the manifest deploySwarm wrote: a deploy's
    // u{uid}/{spawn id}, and castSwarm's build roots for conversations and a scheduled run (paths.zig buildRootRel).
    // One conversation's id is "u9", a name any conversation may take, and the dir is still account 7's.
    var deploy_buf: [32]u8 = undefined;
    var rel_bufs: [3][96]u8 = undefined;
    const runs = [_][]const u8{
        try std.fmt.bufPrint(&deploy_buf, "u7/{s}", .{&sup.newSpawnId()}),
        cpaths.buildRootRel(&rel_bufs[0], 7, "c6a57f852"),
        cpaths.buildRootRel(&rel_bufs[1], 7, "u9"),
        cpaths.buildRootRel(&rel_bufs[2], 7, "scheduled_news-0715174857_07151753"),
    };
    // A mind's write_file takes any workdir-relative path, and swarm.json is no reserved name, so a hive can leave a
    // manifest anywhere in its deliverables, {run_dir}/work: at their root, in a site folder, or in folders that spell
    // out a run dir of every shape, another account's included.
    const planted = [_][]const u8{ "/work", "/work/site", "/work/u9", "/work/u7/fedcba9876543210", "/work/u7/_chat/builds/c1", "/work/u7/_sched/digest-0715174901/runs/07151800" };
    for (runs) |run| {
        for ([_][]const u8{""} ++ planted) |sub| {
            var db: [256]u8 = undefined;
            const dir = try std.fmt.bufPrint(&db, root ++ "/{s}{s}", .{ run, sub });
            _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
            var mb: [280]u8 = undefined;
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = try std.fmt.bufPrint(&mb, "{s}/swarm.json", .{dir}),
                .data = "{\"swarm\":\"cast\",\"model\":\"mock\",\"minds\":[{\"name\":\"nova\"}]}",
            });
        }
    }

    const adopted = sup.reattach(root);
    const all = try sup.listAll();
    defer gpa.free(all);
    errdefer for (all) |s| std.debug.print("adopted {s} for account {d}\n", .{ s.run_dir, s.uid });
    try std.testing.expectEqual(@as(usize, runs.len), adopted);
    try std.testing.expectEqual(runs.len, all.len);
    // Each run dir is adopted once, for the account it sits under, in whatever spelling the adoption gives its path.
    for (runs) |run| {
        var hits: usize = 0;
        for (all) |s| {
            if (s.run_dir.len <= run.len) continue;
            const cut = s.run_dir.len - run.len;
            if (!Supervisor.sameRunDir(s.run_dir[cut..], run) or (s.run_dir[cut - 1] != '/' and s.run_dir[cut - 1] != '\\')) continue;
            try std.testing.expectEqual(@as(u64, 7), s.uid);
            hits += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), hits);
    }
    const other_account = try sup.listForUser(9);
    defer gpa.free(other_account);
    try std.testing.expectEqual(@as(usize, 0), other_account.len);
    try std.testing.expectEqual(@as(usize, 0), sup.reattach(root)); // a second pass finds nothing new
}

test "retention prunes only the idle run dirs the server spawned, never a work-tree folder holding an events.jsonl, a conversation or a live run" {
    const gpa = std.testing.allocator;
    // as in the reattach test above: a listing that shelled out again must fail on what it lists
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = @import("../../gateway/http.zig").testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-supervisor-worktree-prune-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir_bufs: [3][128]u8 = undefined;
    var rel_bufs: [3][96]u8 = undefined;
    const idle_deploy = root ++ "/u7/1111111111111111";
    const busy_deploy = root ++ "/u7/2222222222222222";
    const live_deploy = root ++ "/u7/3333333333333333";
    const idle_cast = try std.fmt.bufPrint(&dir_bufs[0], root ++ "/{s}", .{cpaths.buildRootRel(&rel_bufs[0], 7, "c6a57f852")});
    const busy_cast = try std.fmt.bufPrint(&dir_bufs[1], root ++ "/{s}", .{cpaths.buildRootRel(&rel_bufs[1], 7, "c7b68a963")});
    const idle_sched = try std.fmt.bufPrint(&dir_bufs[2], root ++ "/{s}", .{cpaths.buildRootRel(&rel_bufs[2], 7, "scheduled_news-0715174857_07151753")});
    const conv = root ++ "/u7/_chat/convs/c6a57f852";

    // Every file in the tree: whether it was last written 30 days ago, far outside a 14-day window, and whether
    // retention keeps it. A hive's files are named like a run's own bookkeeping, since write_file reserves no name.
    const File = struct { dir: []const u8, name: []const u8, idle: bool = true, kept: bool };
    const files = [_]File{
        // an idle deploy goes whole
        .{ .dir = idle_deploy, .name = "events.jsonl", .kept = false },
        .{ .dir = idle_deploy, .name = "swarm.json", .kept = false },
        .{ .dir = idle_deploy, .name = "work/index.html", .kept = false },
        // a deploy still writing events keeps the idle events.jsonl its hive left in a data folder
        .{ .dir = busy_deploy, .name = "events.jsonl", .idle = false, .kept = true },
        .{ .dir = busy_deploy, .name = "work/data/events.jsonl", .kept = true },
        .{ .dir = busy_deploy, .name = "work/data/swarm.json", .kept = true },
        .{ .dir = busy_deploy, .name = "work/data/rows.csv", .kept = true },
        // an idle deploy whose worker the registry holds as running
        .{ .dir = live_deploy, .name = "events.jsonl", .kept = true },
        // an idle conversation cast loses only its own bookkeeping; its hive's files of the same names stay
        .{ .dir = idle_cast, .name = "events.jsonl", .kept = false },
        .{ .dir = idle_cast, .name = "swarm.json", .kept = false },
        .{ .dir = idle_cast, .name = "DONE", .kept = false },
        .{ .dir = idle_cast, .name = "work/logs/events.jsonl", .kept = true },
        .{ .dir = idle_cast, .name = "work/logs/swarm.json", .kept = true },
        .{ .dir = idle_cast, .name = "work/logs/DONE", .kept = true },
        // a conversation cast still running keeps a folder of old logs among files named like cast bookkeeping
        .{ .dir = busy_cast, .name = "events.jsonl", .idle = false, .kept = true },
        .{ .dir = busy_cast, .name = "work/logs/events.jsonl", .kept = true },
        .{ .dir = busy_cast, .name = "work/logs/control.jsonl", .kept = true },
        .{ .dir = busy_cast, .name = "work/logs/mind.sqlite", .kept = true },
        .{ .dir = busy_cast, .name = "work/logs/keys.env", .kept = true },
        .{ .dir = busy_cast, .name = "work/logs/minds/nova.md", .kept = true },
        // an idle scheduled run, like a conversation cast
        .{ .dir = idle_sched, .name = "events.jsonl", .kept = false },
        .{ .dir = idle_sched, .name = "swarm.json", .kept = false },
        .{ .dir = idle_sched, .name = "work/report/events.jsonl", .kept = true },
        .{ .dir = idle_sched, .name = "work/report/report.md", .kept = true },
        // a conversation idle as long is no run dir
        .{ .dir = conv, .name = "events.jsonl", .kept = true },
        .{ .dir = conv, .name = "messages.jsonl", .kept = true },
    };
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    for (files) |f| {
        var pb: [320]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ f.dir, f.name });
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, std.fs.path.dirname(path).?, .default_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{}\n" });
        if (!f.idle) continue;
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(now_ns - 30 * std.time.ns_per_day) } });
    }

    var sup = Supervisor.init(gpa, io, "");
    defer sup.swarms.deinit(gpa);
    // the live run's entry spells its dir with the other separator, as a dir can be registered in either
    var live_dir: [live_deploy.len]u8 = undefined;
    for (live_deploy, &live_dir) |c, *d| d.* = if (c == '/') '\\' else c;
    var live: Swarm = .{ .id = "3333333333333333", .uid = 7, .name = "cast", .run_dir = &live_dir, .model = "mock", .minds = 1, .created = 0, .state = .running };
    try sup.swarms.put(gpa, live.id, &live);

    const pruned = sup.pruneOldRuns(root, 14);
    var wrong: usize = 0;
    for (files) |f| {
        var pb: [320]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ f.dir, f.name });
        const kept = if (std.Io.Dir.cwd().access(io, path, .{})) |_| true else |_| false;
        if (kept == f.kept) continue;
        std.debug.print("retention {s} {s}\n", .{ if (kept) "left" else "deleted", path });
        wrong += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
    try std.testing.expectEqual(@as(usize, 3), pruned); // the idle deploy, conversation cast and scheduled run
    try std.testing.expectEqual(@as(usize, 0), sup.pruneOldRuns(root, 14)); // nothing idle is left to prune
}

test "the key sweep removes the curl configs no running call can still need, from every dir a call writes them to, and nothing else" {
    const gpa = std.testing.allocator;
    // as in the reattach test above: a listing that shelled out again must fail on what it lists
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = @import("../../gateway/http.zig").testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const root = "zig-supervisor-keysweep-tmp";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir_bufs: [2][128]u8 = undefined;
    var rel_bufs: [2][96]u8 = undefined;
    const conv = root ++ "/u7/_chat/convs/c6a57f852";
    const cast = try std.fmt.bufPrint(&dir_bufs[0], root ++ "/{s}", .{cpaths.buildRootRel(&rel_bufs[0], 7, "c6a57f852")});
    const sched = try std.fmt.bufPrint(&dir_bufs[1], root ++ "/{s}", .{cpaths.buildRootRel(&rel_bufs[1], 7, "scheduled_news-0715174857_07151753")});
    const deploy = root ++ "/u7/1111111111111111";

    // Ages straddle the floor: a minute past it is a call that cannot still be running; a minute short of it may be.
    const stale: i64 = llm.KEY_CFG_STALE_S + 60;
    const young: i64 = llm.KEY_CFG_STALE_S - 60;
    const File = struct { dir: []const u8, name: []const u8, age_s: i64 = stale, kept: bool };
    const files = [_]File{
        // a conversation dir, the chat engine's scratch: the per-tag configs earlier builds left, and a per-call one
        .{ .dir = conv, .name = ".streamcfg-chat", .kept = false },
        .{ .dir = conv, .name = ".curlcfg-loop", .kept = false },
        .{ .dir = conv, .name = ".curlcfg-chat-0123456789abcdef", .kept = false },
        // younger than the floor, so possibly a running call's whose curl has not read it: one just written, one a minute short
        .{ .dir = conv, .name = ".curlcfg-chat-fedcba9876543210", .age_s = 0, .kept = true },
        .{ .dir = conv, .name = ".streamcfg-chat-0f1e2d3c4b5a6978", .age_s = young, .kept = true },
        // what carries no key stays, however old: a request body a replay starts from, the transcript
        .{ .dir = conv, .name = ".llmreq-loop.json", .kept = true },
        .{ .dir = conv, .name = "messages.jsonl", .kept = true },
        // a conversation's build root: the family's memverify, a cast mind's etl, the vision call's work/ scratch
        .{ .dir = cast, .name = ".curlcfg-memverify", .kept = false },
        .{ .dir = cast, .name = ".curlcfg-etl-00112233445566ff", .kept = false },
        .{ .dir = cast, .name = ".llmreq-memverify.json", .kept = true },
        .{ .dir = cast, .name = "work/.curlcfg-vision-aabbccddeeff0011", .kept = false },
        .{ .dir = cast, .name = "work/index.html", .kept = true },
        // below the top of work/ is the hive's deliverables, never read, whatever a file there is called
        .{ .dir = cast, .name = "work/site/.curlcfg-notes", .kept = true },
        // a scheduled run, with an untagged config
        .{ .dir = sched, .name = ".streamcfg-chat", .kept = false },
        .{ .dir = sched, .name = ".curlcfg", .kept = false },
        // a deploy, beside a dotfile that only begins like a config
        .{ .dir = deploy, .name = ".curlcfg-planner", .kept = false },
        .{ .dir = deploy, .name = ".curlcfgrc", .kept = true },
    };
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    var swept: usize = 0;
    for (files) |f| {
        var pb: [320]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ f.dir, f.name });
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, std.fs.path.dirname(path).?, .default_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "header = \"Authorization: Bearer x\"\n" });
        if (!f.kept) swept += 1;
        if (f.age_s == 0) continue;
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(now_ns - @as(i96, f.age_s) * std.time.ns_per_s) } });
    }

    var sup = Supervisor.init(gpa, io, "");
    defer sup.swarms.deinit(gpa);
    const removed = sup.sweepKeyScratch(root);
    var wrong: usize = 0;
    for (files) |f| {
        var pb: [320]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ f.dir, f.name });
        const kept = if (std.Io.Dir.cwd().access(io, path, .{})) |_| true else |_| false;
        if (kept == f.kept) continue;
        std.debug.print("key sweep {s} {s}\n", .{ if (kept) "left" else "deleted", path });
        wrong += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
    try std.testing.expectEqual(swept, removed); // the count it reports is the files it took
    try std.testing.expectEqual(@as(usize, 0), sup.sweepKeyScratch(root)); // and a second pass finds nothing
}
