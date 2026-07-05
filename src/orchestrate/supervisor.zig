//! Supervisor — spawns + tracks one native Zig worker process per swarm, and enforces the per-user mind cap

const std = @import("std");
const builtin = @import("builtin");
const crypto = @import("../config/key_vault.zig");
const NeuronLedger = @import("../plan/neurons.zig").NeuronLedger;

// Native process liveness/termination — NO subprocess. tasklist/taskkill spawned a child process ON THE
// httpz REQUEST THREAD for every reconcile-probe and every kill; under load those spawns starve the worker
// pool and wedge (then a stale-pid recycle used to taskkill the server itself). These call the Win32 API
// directly instead, so the checks are cheap and never touch the process table via a shell.
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

/// Sleep `ms` from a RAW OS thread (the background loop is a std.Thread, NOT an Io-managed task — io.sleep
/// throws there, and swallowing that error turned the loop into a 100%-CPU spin that starved the http pool).
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

pub const State = enum { starting, running, stopped, crashed };

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
    swarms: std.StringHashMapUnmanaged(*Swarm) = .empty,
    server_key: [32]u8 = undefined,
    parent_env: ?*const std.process.Environ.Map = null,
    last_gc: i64 = 0,
    ledger: ?*NeuronLedger = null,
    bg_stop: std.atomic.Value(bool) = .init(false),
    gc_data_dir: []const u8 = "",
    gc_days: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, neuron_bin: []const u8) Supervisor {
        return .{ .gpa = gpa, .io = io, .neuron_bin = neuron_bin };
    }

    /// Background maintenance thread: reconcile swarm states + prune old runs every ~5s, OFF the httpz request
    /// threads. reconcile() probes worker liveness and can respawn (spawn a worker subprocess) — doing that
    /// inline in a /fleet or list handler starves the pool and wedges the server (esp. with a live swarm).
    /// Request handlers now just read the in-memory map; this loop keeps it fresh. Fire-and-forget (detached).
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
        var child_env: ?std.process.Environ.Map = if (self.parent_env) |penv| self.encInjectEnv(penv, run_dir) else null;
        defer if (child_env) |*m| m.deinit();
        if (child_env) |*m| opts.environ_map = m;
        const child = try std.process.spawn(self.io, opts);
        return .{ .child = child, .encrypted = child_env != null };
    }

    pub fn spawn(self: *Supervisor, uid: u64, id: []const u8, name: []const u8, run_dir: []const u8, model: []const u8, minds: usize) !*Swarm {
        const launched = try self.launch(run_dir, model);

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
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const sw = self.swarms.get(id) orelse return;
            run_dir = std.fmt.bufPrint(&rd_buf, "{s}", .{sw.run_dir}) catch return;
            model = std.fmt.bufPrint(&md_buf, "{s}", .{sw.model}) catch return;
        }
        const launched = self.launch(run_dir, model) catch return;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const sw = self.swarms.get(id) orelse return;
        sw.child = launched.child;
        sw.state = .running;
        sw.restarts += 1;
        sw.last_restart = now;
        sw.last_check = now;
        std.debug.print("[supervisor] auto-restarted crashed swarm {s} (restart {d}/{d})\n", .{ id, sw.restarts, MAX_RESTARTS });
    }

    fn encInjectEnv(self: *Supervisor, penv: *const std.process.Environ.Map, run_dir: []const u8) ?std.process.Environ.Map {
        var ebuf: [1280]u8 = undefined;
        const p = std.fmt.bufPrint(&ebuf, "{s}/keys.env.enc", .{run_dir}) catch return null;
        const b64 = std.Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, .limited(8 << 10)) catch return null;
        defer self.gpa.free(b64);
        const pt = crypto.open(self.gpa, self.server_key, std.mem.trim(u8, b64, " \r\n\t")) orelse return null;
        defer self.gpa.free(pt);
        var m = penv.clone(self.gpa) catch return null;
        var it = std.mem.tokenizeAny(u8, pt, "\r\n");
        while (it.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            m.put(line[0..eq], line[eq + 1 ..]) catch {};
        }
        return m;
    }

    pub fn get(self: *Supervisor, id: []const u8) ?*Swarm {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.swarms.get(id);
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
            sw.state = .stopped;
        }
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = stop_path, .data = "" }) catch {};
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
            self.io.sleep(.{ .nanoseconds = 300 * std.time.ns_per_ms }, .awake) catch {};
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
        // Native recursive delete — NO PowerShell/rm subprocess. Spawning a shell per delete on the httpz
        // request thread starves the worker pool under load (the DELETE-flood wedge). deleteTree is idempotent
        // (an already-absent tree is success); a locked file (a still-dying worker) errors -> caller retries.
        std.Io.Dir.cwd().deleteTree(self.io, path) catch return false;
        return true;
    }

    /// Remove a cast's own bookkeeping from a chat-owned build dir without touching the deliverables. Deleting
    /// events.jsonl + swarm.json is what actually matters for lifecycle: retention GC lists by events.jsonl age
    /// and reconcile rediscovers by swarm.json, so pulling both stops the dir from being re-swept — while work/
    /// and any user files stay put for the chat (and the next cast into the same conversation). Crucially it also
    /// sweeps the per-mind curl scratch: `.curlcfg-<mind>` embeds the API key in an `Authorization: Bearer …`
    /// line, so a normal swarm's full-tree wipe scrubs it — for a chat dir we must scrub it explicitly or the
    /// key would be stranded on disk. `.build_manifest` and DELIVERY/ are deliberately kept (the chat reads them).
    fn cleanCastMeta(self: *Supervisor, run_dir: []const u8) void {
        const meta = [_][]const u8{ "swarm.json", "worker.pid", "STOP", "events.jsonl", "control.jsonl", "mind.sqlite", ".usage", ".round_writes", ".explore_seen", "keys.env", "keys.env.enc" };
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

    pub fn reattach(self: *Supervisor, data_dir: []const u8) usize {
        const out = self.findManifests(data_dir) orelse return 0;
        defer self.gpa.free(out);
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, out, "\r\n");
        while (it.next()) |raw| {
            const mpath = std.mem.trim(u8, raw, " \t");
            if (mpath.len == 0) continue;
            if (self.adoptOne(mpath)) n += 1 else |_| {}
        }
        return n;
    }

    fn findManifests(self: *Supervisor, data_dir: []const u8) ?[]u8 {
        if (builtin.os.tag == .windows) {
            const cmd = std.fmt.allocPrint(self.gpa, "if (Test-Path -LiteralPath '{s}') {{ Get-ChildItem -LiteralPath '{s}' -Filter swarm.json -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {{ $_.FullName }} }}", .{ data_dir, data_dir }) catch return null;
            defer self.gpa.free(cmd);
            const argv = [_][]const u8{ "powershell", "-NoProfile", "-Command", cmd };
            const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return null;
            self.gpa.free(res.stderr);
            return res.stdout;
        } else {
            const argv = [_][]const u8{ "find", data_dir, "-name", "swarm.json", "-type", "f" };
            const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return null;
            self.gpa.free(res.stderr);
            return res.stdout;
        }
    }

    pub fn maybeGc(self: *Supervisor, data_dir: []const u8, days: u32) void {
        if (days == 0) return;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        if (self.last_gc != 0 and now - self.last_gc < 3600) return;
        self.last_gc = now;
        const n = self.pruneOldRuns(data_dir, days);
        if (n > 0) std.debug.print("retention: pruned {d} run dir(s) inactive >= {d}d\n", .{ n, days });
    }

    pub fn pruneOldRuns(self: *Supervisor, data_dir: []const u8, days: u32) usize {
        const list = self.findInactiveRunDirs(data_dir, days) orelse return 0;
        defer self.gpa.free(list);
        var pruned: usize = 0;
        var it = std.mem.tokenizeAny(u8, list, "\r\n");
        while (it.next()) |raw| {
            const ev = std.mem.trim(u8, raw, " \r\n\t");
            if (ev.len == 0) continue;
            const run_dir = std.fs.path.dirname(ev) orelse continue;
            if (self.runDirIsLive(run_dir)) continue;
            if (self.rmTree(run_dir)) pruned += 1;
        }
        return pruned;
    }

    fn findInactiveRunDirs(self: *Supervisor, data_dir: []const u8, days: u32) ?[]u8 {
        if (builtin.os.tag == .windows) {
            const cmd = std.fmt.allocPrint(self.gpa, "if (Test-Path -LiteralPath '{s}') {{ Get-ChildItem -LiteralPath '{s}' -Filter events.jsonl -Recurse -File -ErrorAction SilentlyContinue | Where-Object {{ $_.LastWriteTime -lt (Get-Date).AddDays(-{d}) }} | ForEach-Object {{ $_.FullName }} }}", .{ data_dir, data_dir, days }) catch return null;
            defer self.gpa.free(cmd);
            const argv = [_][]const u8{ "powershell", "-NoProfile", "-Command", cmd };
            const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return null;
            self.gpa.free(res.stderr);
            return res.stdout;
        } else {
            const ds = std.fmt.allocPrint(self.gpa, "+{d}", .{days}) catch return null;
            defer self.gpa.free(ds);
            const argv = [_][]const u8{ "find", data_dir, "-name", "events.jsonl", "-type", "f", "-mtime", ds };
            const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return null;
            self.gpa.free(res.stderr);
            return res.stdout;
        }
    }

    fn runDirIsLive(self: *Supervisor, run_dir: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if ((s.state == .running or s.state == .starting) and std.mem.eql(u8, s.run_dir, run_dir)) return true;
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

    fn adoptOne(self: *Supervisor, mani_path: []const u8) !void {
        const run_dir = std.fs.path.dirname(mani_path) orelse return error.BadPath;
        const id = std.fs.path.basename(run_dir);
        if (self.get(id) != null) return error.AlreadyTracked;
        const uid = parseUidFromPath(run_dir) orelse return error.NoUid;
        const data = try std.Io.Dir.cwd().readFileAlloc(self.io, mani_path, self.gpa, .limited(256 << 10));
        defer self.gpa.free(data);
        const parsed = try std.json.parseFromSlice(Manifest, self.gpa, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const m = parsed.value;
        const sw = try self.gpa.create(Swarm);
        errdefer self.gpa.destroy(sw);
        sw.* = .{
            .id = try self.gpa.dupe(u8, id),
            .uid = uid,
            .name = try self.gpa.dupe(u8, m.swarm),
            .run_dir = try self.gpa.dupe(u8, run_dir),
            .model = try self.gpa.dupe(u8, m.model),
            .minds = m.minds.len,
            .created = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            .child = null,
            .state = self.inferState(run_dir),
            .encrypted = m.encrypted,
        };
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.swarms.put(self.gpa, sw.id, sw);
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
        const Cand = struct { id: []const u8, run_dir: []const u8 };
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
                if (s.state != .running and s.state != .starting) continue;
                if (now - s.last_check < RECHECK_SECS) continue;
                s.last_check = now;
                const id = self.gpa.dupe(u8, s.id) catch continue;
                const rd = self.gpa.dupe(u8, s.run_dir) catch {
                    self.gpa.free(id);
                    continue;
                };
                cands.append(self.gpa, .{ .id = id, .run_dir = rd }) catch {
                    self.gpa.free(id);
                    self.gpa.free(rd);
                };
            }
        }
        for (cands.items) |c| {
            const new_state = self.probeState(c.run_dir);
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
                }
            }
        }
        for (restart_ids.items) |rid| self.respawn(rid);
    }

    fn shouldRestart(_: *Supervisor, s: *Swarm, now: i64) bool {
        if (s.breaker_open) return false;
        if (s.last_restart != 0 and now - s.last_restart > HEALTH_RESET_SECS) s.restarts = 0;
        if (s.restarts >= MAX_RESTARTS) {
            s.breaker_open = true;
            std.debug.print("[supervisor] circuit-breaker OPEN for swarm {s} after {d} restarts — leaving it crashed\n", .{ s.id, s.restarts });
            return false;
        }
        return true;
    }

    fn probeState(self: *Supervisor, run_dir: []const u8) State {
        if (self.hasTerminalMarker(run_dir)) return .stopped;
        const pid = self.workerPid(run_dir) orelse return .running;
        return if (self.pidAlive(pid)) .running else .crashed;
    }

    fn hasTerminalMarker(self: *Supervisor, run_dir: []const u8) bool {
        var buf: [1280]u8 = undefined;
        const stop_path = std.fmt.bufPrint(&buf, "{s}/STOP", .{run_dir}) catch return false;
        if (std.Io.Dir.cwd().access(self.io, stop_path, .{})) |_| return true else |_| {}
        const ev_path = std.fmt.bufPrint(&buf, "{s}/events.jsonl", .{run_dir}) catch return false;
        const ev = std.Io.Dir.cwd().readFileAlloc(self.io, ev_path, self.gpa, .limited(1 << 20)) catch return false;
        defer self.gpa.free(ev);
        return std.mem.indexOf(u8, ev, "\"kind\":\"stopped\"") != null;
    }

    fn workerPid(self: *Supervisor, run_dir: []const u8) ?u32 {
        var pbuf: [1280]u8 = undefined;
        const pidpath = std.fmt.bufPrint(&pbuf, "{s}/worker.pid", .{run_dir}) catch return null;
        const txt = std.Io.Dir.cwd().readFileAlloc(self.io, pidpath, self.gpa, .limited(64)) catch return null;
        defer self.gpa.free(txt);
        return std.fmt.parseInt(u32, std.mem.trim(u8, txt, " \r\n\t"), 10) catch null;
    }

    fn pidAlive(self: *Supervisor, pid: u32) bool {
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

    fn parseUidFromPath(p: []const u8) ?u64 {
        var it = std.mem.splitAny(u8, p, "/\\");
        var uid: ?u64 = null;
        while (it.next()) |seg| {
            if (seg.len >= 2 and seg[0] == 'u' and std.ascii.isDigit(seg[1]))
                uid = std.fmt.parseInt(u64, seg[1..], 10) catch uid;
        }
        return uid;
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
