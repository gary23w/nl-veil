//! Supervisor — spawns + tracks one native Zig worker process per swarm, and enforces the per-user mind cap

const std = @import("std");
const builtin = @import("builtin");
const crypto = @import("../config/key_vault.zig");
const NeuronLedger = @import("../plan/neurons.zig").NeuronLedger;

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

    pub fn init(gpa: std.mem.Allocator, io: std.Io, neuron_bin: []const u8) Supervisor {
        return .{ .gpa = gpa, .io = io, .neuron_bin = neuron_bin };
    }

    pub fn liveMindsForUser(self: *Supervisor, uid: u64) usize {
        self.reconcile();
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
        self.reconcile();
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
        const sw = self.get(id) orelse return;
        var buf: [1024]u8 = undefined;
        const stop_path = std.fmt.bufPrint(&buf, "{s}/STOP", .{sw.run_dir}) catch return;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = stop_path, .data = "" }) catch {};
        sw.state = .stopped;
    }

    pub fn remove(self: *Supervisor, id: []const u8) void {
        const sw = self.get(id) orelse return;
        var pbuf: [1024]u8 = undefined;
        const sp = std.fmt.bufPrint(&pbuf, "{s}/STOP", .{sw.run_dir}) catch sw.run_dir;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = sp, .data = "" }) catch {};
        if (sw.child != null) {
            sw.child.?.kill(self.io);
            sw.child = null;
        } else {
            self.killByPidFile(sw.run_dir);
        }
        sw.state = .stopped;
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            if (self.rmTree(sw.run_dir)) break;
            self.io.sleep(.{ .nanoseconds = 300 * std.time.ns_per_ms }, .awake) catch {};
        }
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        _ = self.swarms.remove(id);
    }

    fn rmTree(self: *Supervisor, path: []const u8) bool {
        if (builtin.os.tag == .windows) {
            const cmd = std.fmt.allocPrint(self.gpa, "Remove-Item -LiteralPath '{s}' -Recurse -Force -ErrorAction Stop", .{path}) catch return false;
            defer self.gpa.free(cmd);
            const argv = [_][]const u8{ "powershell", "-NoProfile", "-Command", cmd };
            const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return false;
            defer self.gpa.free(res.stdout);
            defer self.gpa.free(res.stderr);
            return res.term == .exited and res.term.exited == 0;
        } else {
            const argv = [_][]const u8{ "rm", "-rf", path };
            const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return false;
            defer self.gpa.free(res.stdout);
            defer self.gpa.free(res.stderr);
            return res.term == .exited and res.term.exited == 0;
        }
    }

    fn killByPidFile(self: *Supervisor, run_dir: []const u8) void {
        var pbuf: [1024]u8 = undefined;
        const pidpath = std.fmt.bufPrint(&pbuf, "{s}/worker.pid", .{run_dir}) catch return;
        const txt = std.Io.Dir.cwd().readFileAlloc(self.io, pidpath, self.gpa, .limited(64)) catch return;
        defer self.gpa.free(txt);
        const pid = std.fmt.parseInt(u32, std.mem.trim(u8, txt, " \r\n\t"), 10) catch return;
        var nbuf: [16]u8 = undefined;
        const pidstr = std.fmt.bufPrint(&nbuf, "{d}", .{pid}) catch return;
        const argv = if (builtin.os.tag == .windows)
            [_][]const u8{ "taskkill", "/F", "/T", "/PID", pidstr }
        else
            [_][]const u8{ "kill", "-9", pidstr };
        const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return;
        self.gpa.free(res.stdout);
        self.gpa.free(res.stderr);
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
        return if (self.hasTerminalMarker(run_dir)) .stopped else .running;
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
            const fil = std.fmt.allocPrint(self.gpa, "PID eq {d}", .{pid}) catch return true;
            defer self.gpa.free(fil);
            const argv = [_][]const u8{ "tasklist", "/FI", fil, "/NH", "/FO", "CSV" };
            const res = std.process.run(self.gpa, self.io, .{ .argv = &argv }) catch return true;
            defer self.gpa.free(res.stdout);
            defer self.gpa.free(res.stderr);
            const needle = std.fmt.allocPrint(self.gpa, "\"{d}\"", .{pid}) catch return true;
            defer self.gpa.free(needle);
            return std.mem.indexOf(u8, res.stdout, needle) != null;
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
        self.reconcile();
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
        self.reconcile();
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
        self.reconcile();
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var list: std.ArrayList(*Swarm) = .empty;
        var it = self.swarms.valueIterator();
        while (it.next()) |sp| try list.append(self.gpa, sp.*);
        return list.toOwnedSlice(self.gpa);
    }
};
