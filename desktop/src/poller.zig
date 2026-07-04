//! poller.zig — the background worker. Owns the std.Io handle and does ALL io: probe the server, scan the
//! run dirs, tail the selected swarm, drain UI commands (control writes + deploy), and raise notifications
//! on state transitions. Publishes everything into the mutex-guarded Store. Runs ~1Hz; the UI thread reads
//! the Store at 60fps and never blocks. This is the only thread that may call io — the UI only calls raylib.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const store_mod = @import("store.zig");
const scan = @import("scan.zig");
const netcli = @import("netcli.zig");
const log = @import("log.zig");

const Store = store_mod.Store;

pub const Poller = struct {
    io: Io,
    gpa: std.mem.Allocator,
    store: *Store,
    stop: std.atomic.Value(bool) = .init(false),
    log_buf: std.ArrayListUnmanaged(u8) = .empty,

    // transition memory for notifications (poller-local, no lock needed)
    prev_online: bool = false,
    prev_online_set: bool = false,
    prev_live_ids: [scan.MAX_SWARMS][64]u8 = undefined,
    prev_live_lens: [scan.MAX_SWARMS]u8 = [_]u8{0} ** scan.MAX_SWARMS,
    prev_live_n: usize = 0,
    prev_stopped_marked: [scan.MAX_SWARMS]bool = [_]bool{false} ** scan.MAX_SWARMS,
    prev_sel_pct: [scan.MAX_SWARMS]i32 = [_]i32{-1} ** scan.MAX_SWARMS,

    // scratch (poller-owned)
    swarm_scratch: [scan.MAX_SWARMS]scan.SwarmSummary = undefined,
    ev_scratch: [scan.MAX_LOG]scan.Ev = undefined,
    file_scratch: [scan.MAX_FILES]scan.FileRow = undefined,
    fc_scratch: [1 << 14]u8 = undefined, // selected-file content read buffer

    // server-poll throttle: the roster/tail are read from the FILESYSTEM every ~1s (free), but the
    // server-hitting checks (serverOnline + GET /fleet) only need to run every few seconds — a fresh
    // connection every second is needless load on a small local server. Carry the last counters between.
    last_fleet_s: i64 = 0,

    // notification de-dup state (poller-local)
    grad_warned: bool = false,
    stopped_ids: [scan.MAX_SWARMS][64]u8 = undefined,
    stopped_lens: [scan.MAX_SWARMS]u8 = [_]u8{0} ** scan.MAX_SWARMS,
    stopped_n: usize = 0,

    pub fn run(self: *Poller) void {
        while (!self.stop.load(.monotonic)) {
            self.drainCommands();
            self.refresh();
            // ~1s cadence, but wake early to service commands responsively (10x100ms polls of the stop flag)
            var i: u8 = 0;
            while (i < 10 and !self.stop.load(.monotonic)) : (i += 1) {
                self.io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
                if (self.hasPendingCmd()) break;
            }
        }
    }

    fn hasPendingCmd(self: *Poller) bool {
        self.store.lock();
        defer self.store.unlock();
        return self.store.cmd_tail != self.store.cmd_head;
    }

    fn dataDir(self: *Poller, buf: []u8) []const u8 {
        self.store.lock();
        defer self.store.unlock();
        const d = self.store.settings.dataDir();
        const n = @min(d.len, buf.len);
        @memcpy(buf[0..n], d[0..n]);
        return buf[0..n];
    }

    fn port(self: *Poller) u16 {
        self.store.lock();
        defer self.store.unlock();
        return self.store.settings.port;
    }

    fn drainCommands(self: *Poller) void {
        var dbuf: [512]u8 = undefined;
        const dd = self.dataDir(&dbuf);
        while (self.store.popCmd()) |c| {
            switch (c.kind) {
                .none, .refresh_now => {},
                .select => self.setSelected(c.idStr()),
                .say => self.doControl(dd, c.idStr(), "say", c.textStr(), ""),
                .set_goal => self.doControl(dd, c.idStr(), "set_goal", "", c.textStr()),
                .stop => self.doControl(dd, c.idStr(), "stop", "", ""),
                .deploy => self.doDeploy(c.textStr()),
                .delete => self.doDelete(dd, c.idStr()),
                .open_folder => self.doOpenFolder(dd),
                .open_file => self.setSelFile(c.textStr()),
            }
        }
    }

    fn setSelected(self: *Poller, id: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        const n = @min(id.len, self.store.selected.len);
        @memcpy(self.store.selected[0..n], id[0..n]);
        self.store.selected_len = @intCast(n);
        self.store.event_count = 0; // force a fresh tail on next refresh
        // clear the previous swarm's file view so it doesn't bleed across selections
        self.store.file_count = 0;
        self.store.sel_file_len = 0;
        self.store.file_content_len = 0;
    }

    /// Files tab: remember which file the viewer is showing; refresh() re-reads it each pass so a live
    /// build's file updates as it grows.
    fn setSelFile(self: *Poller, sub: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        const n = @min(sub.len, self.store.sel_file.len);
        @memcpy(self.store.sel_file[0..n], sub[0..n]);
        self.store.sel_file_len = @intCast(n);
        self.store.file_content_len = 0; // force a re-read next refresh
    }

    fn doControl(self: *Poller, dd: []const u8, id: []const u8, op: []const u8, text: []const u8, goal: []const u8) void {
        if (id.len == 0) return;
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"op\":\"") catch return;
        jb.appendSlice(self.gpa, op) catch return;
        jb.append(self.gpa, '"') catch return;
        if (text.len > 0) {
            jb.appendSlice(self.gpa, ",\"to\":\"all\",\"text\":\"") catch return;
            appendEsc(&jb, self.gpa, text);
            jb.append(self.gpa, '"') catch return;
        }
        if (goal.len > 0) {
            jb.appendSlice(self.gpa, ",\"goal\":\"") catch return;
            appendEsc(&jb, self.gpa, goal);
            jb.append(self.gpa, '"') catch return;
        }
        jb.append(self.gpa, '}') catch return;
        const ok = scan.writeControl(self.io, self.gpa, dd, id, jb.items);
        if (ok and std.mem.eql(u8, op, "stop")) self.store.pushNotif("Stop sent", id, 2);
        if (!ok) self.store.pushNotif("Control failed", id, 2);
    }

    fn doDeploy(self: *Poller, body: []const u8) void {
        // `body` is the complete DeployReq JSON built by the UI (Deploy form). Post it verbatim.
        if (body.len == 0) {
            log.err("deploy: EMPTY body (submitDeploy built nothing — buffer overflow or bad state)", .{});
            return;
        }
        var tbuf: [128]u8 = undefined;
        var tlen: usize = 0;
        {
            self.store.lock();
            const t = self.store.settings.tokenStr();
            tlen = @min(t.len, tbuf.len);
            @memcpy(tbuf[0..tlen], t[0..tlen]);
            self.store.unlock();
        }
        log.info("deploy: POST body={d}b token={d}b port={d}", .{ body.len, tlen, self.port() });
        log.dbg("deploy body: {s}", .{body[0..@min(body.len, 200)]});
        const resp = netcli.deploy(self.io, self.gpa, self.port(), tbuf[0..tlen], body) orelse {
            log.err("deploy: netcli returned NO RESPONSE (client/connect failed)", .{});
            self.store.pushNotif("Deploy failed", "server unreachable — is it running?", 2);
            return;
        };
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        log.info("deploy: status={d} resp={s}", .{ resp.status, resp.body[0..@min(resp.body.len, 160)] });
        if (resp.status == 200 or resp.status == 201) {
            self.store.pushNotif("Swarm deploying", "the server accepted the deploy", 1);
        } else if (resp.status == 401 or resp.status == 403) {
            self.store.pushNotif("Deploy unauthorized", "set an API token in Settings", 2);
        } else {
            self.store.pushNotif("Deploy rejected", "server returned an error", 2);
        }
    }

    /// Delete a swarm. `rel` is the path relative to data ("name" or "u1/<hexid>"). Server-managed swarms
    /// (rel has a '/') go through DELETE /api/v1/swarms/<hexid> so the worker is stopped + removed; a flat
    /// CLI run is removed by deleting exactly its own dir. Only ever the one dir the user picked — never a
    /// sweep.
    fn doDelete(self: *Poller, dd: []const u8, rel: []const u8) void {
        if (rel.len == 0) return;
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |sl| rel[sl + 1 ..] else rel;
        if (std.mem.indexOfScalar(u8, rel, '/') != null) {
            // server swarm → API delete (stops + removes)
            var tbuf: [128]u8 = undefined;
            var tlen: usize = 0;
            {
                self.store.lock();
                const t = self.store.settings.tokenStr();
                tlen = @min(t.len, tbuf.len);
                @memcpy(tbuf[0..tlen], t[0..tlen]);
                self.store.unlock();
            }
            const resp = netcli.delete(self.io, self.gpa, self.port(), tbuf[0..tlen], base);
            log.info("delete {s} basename={s} status={d} token={d}b", .{ rel, base, if (resp) |r| r.status else 0, tlen });
            if (resp) |r| {
                defer if (r.body.len > 0) self.gpa.free(r.body);
                if (r.status == 200 or r.status == 204) {
                    self.store.pushNotif("Deleted", rel, 1);
                    return;
                }
                if (r.status == 401 or r.status == 403) {
                    self.store.pushNotif("Delete unauthorized", "set an API token in Settings", 2);
                    return;
                }
            }
            self.store.pushNotif("Delete failed", rel, 2);
        } else {
            // flat CLI run → remove exactly this dir
            const path = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dd, rel }) catch return;
            defer self.gpa.free(path);
            Io.Dir.cwd().deleteTree(self.io, path) catch {
                self.store.pushNotif("Delete failed", rel, 2);
                return;
            };
            self.store.pushNotif("Deleted", rel, 1);
        }
    }

    /// Keep the API token in sync with <data>/.desktop_key each poll — the server may (re)write it AFTER
    /// the desktop started or rotate it, and a stale token was silently rejecting deploy + delete (fixed by
    /// a restart before). Skips if the user manually saved their own token.
    fn syncDesktopKey(self: *Poller, dd: []const u8) void {
        {
            self.store.lock();
            const manual = self.store.settings.token_manual;
            self.store.unlock();
            if (manual) return;
        }
        const path = std.fmt.allocPrint(self.gpa, "{s}/.desktop_key", .{dd}) catch return;
        defer self.gpa.free(path);
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(256)) catch return;
        defer self.gpa.free(data);
        const key = std.mem.trim(u8, data, " \r\n\t");
        if (key.len == 0) return;
        self.store.lock();
        defer self.store.unlock();
        if (!std.mem.eql(u8, self.store.settings.tokenStr(), key)) {
            const n = @min(key.len, self.store.settings.token.len);
            @memcpy(self.store.settings.token[0..n], key[0..n]);
            self.store.settings.token_len = @intCast(n);
            log.info("token synced from .desktop_key ({d} chars, prefix {s})", .{ key.len, key[0..@min(key.len, 8)] });
        }
    }

    /// Open the data dir in the OS file browser (best-effort). Set the child's cwd to the data dir and
    /// open "." — sidesteps resolving `dd` to an absolute path (getCwd is gone in this Zig).
    fn doOpenFolder(self: *Poller, dd: []const u8) void {
        const argv: []const []const u8 = switch (builtin.os.tag) {
            .windows => &.{ "explorer.exe", "." },
            .macos => &.{ "open", "." },
            else => &.{ "xdg-open", "." },
        };
        _ = std.process.spawn(self.io, .{ .argv = argv, .cwd = .{ .path = dd }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
    }

    /// Append any new log lines to <data>/veil-desk.log. Uses writeFile (whole-file rewrite of a bounded
    /// in-memory copy) rather than an append API — simplest reliable path.
    fn flushLog(self: *Poller, dd: []const u8) void {
        var lb: [128]log.Line = undefined;
        const n = log.drain(&lb);
        if (n == 0) return;
        for (lb[0..n]) |ln| {
            const hh: u64 = @intCast(@mod(@divTrunc(ln.t_s, 3600), 24));
            const mm: u64 = @intCast(@mod(@divTrunc(ln.t_s, 60), 60));
            const ss: u64 = @intCast(@mod(ln.t_s, 60));
            const s = std.fmt.allocPrint(self.gpa, "{d:0>2}:{d:0>2}:{d:0>2} {s} {s}\n", .{ hh, mm, ss, log.levelTag(ln.level), ln.str() }) catch continue;
            defer self.gpa.free(s);
            self.log_buf.appendSlice(self.gpa, s) catch {};
        }
        if (self.log_buf.items.len > 512 * 1024) {
            const keep = self.log_buf.items[self.log_buf.items.len / 2 ..];
            std.mem.copyForwards(u8, self.log_buf.items, keep);
            self.log_buf.items.len = keep.len;
        }
        const p = std.fmt.allocPrint(self.gpa, "{s}/veil-desk.log", .{dd}) catch return;
        defer self.gpa.free(p);
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = self.log_buf.items }) catch {};
    }

    fn refresh(self: *Poller) void {
        var dbuf: [512]u8 = undefined;
        const dd = self.dataDir(&dbuf);
        const now_ns = Io.Timestamp.now(self.io, .real).nanoseconds;
        const now_s: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));
        log.setClock(now_s);

        self.syncDesktopKey(dd);
        self.flushLog(dd);

        // 1) server liveness + fleet counters — THROTTLED to every ~5s (see last_fleet_s). Between polls we
        // carry the previous values so the dashboard counters stay put instead of flickering to 0/offline.
        const FLEET_EVERY_S: i64 = 5;
        var online: bool = undefined;
        var fs: i32 = 0;
        var fl: i32 = 0;
        var fm: i32 = 0;
        var fh: i32 = 0;
        var ver: [16]u8 = [_]u8{0} ** 16;
        var ver_len: u8 = 0;
        if (now_s - self.last_fleet_s >= FLEET_EVERY_S) {
            self.last_fleet_s = now_s;
            // Liveness comes from the fleet GET itself — do NOT do a separate raw TCP probe. serverOnline()
            // opened a connection and closed it WITHOUT sending a request, which left the server half-open
            // (CLOSE_WAIT) with a worker thread spinning on the dead socket — a handful of those pinned ~7
            // CPU cores. The fleet curl sends a real request with `Connection: close`, so the server closes
            // cleanly. online == "the fleet request came back".
            online = false;
            if (netcli.fleet(self.io, self.gpa, self.port())) |resp| {
                online = true;
                defer if (resp.body.len > 0) self.gpa.free(resp.body);
                fs = jint(resp.body, "swarms");
                fl = jint(resp.body, "live_swarms");
                fm = jint(resp.body, "live_minds");
                fh = jint(resp.body, "headroom");
                if (jstr(resp.body, "version")) |v| {
                    const n = @min(v.len, ver.len);
                    @memcpy(ver[0..n], v[0..n]);
                    ver_len = @intCast(n);
                }
            }
        } else {
            // carry the last-known server state forward
            self.store.lock();
            online = self.store.server_online;
            fs = self.store.fleet_swarms;
            fl = self.store.fleet_live;
            fm = self.store.fleet_minds;
            fh = self.store.fleet_headroom;
            self.store.unlock();
        }

        // 2) roster
        const nsw = scan.listSwarms(self.io, self.gpa, dd, &self.swarm_scratch, now_s, 45);

        // 3) selected swarm tail
        var selbuf: [64]u8 = undefined;
        var sel_len: usize = 0;
        {
            self.store.lock();
            sel_len = self.store.selected_len;
            @memcpy(selbuf[0..sel_len], self.store.selected[0..sel_len]);
            self.store.unlock();
        }
        var ev_n: usize = 0;
        var metrics: scan.Metrics = .{};
        var file_n: usize = 0;
        var fc_len: usize = 0;
        var fc_trunc = false;
        if (sel_len > 0) {
            const ep = std.fmt.allocPrint(self.gpa, "{s}/{s}/events.jsonl", .{ dd, selbuf[0..sel_len] }) catch "";
            if (ep.len > 0) {
                defer self.gpa.free(ep);
                ev_n = scan.tailEvents(self.io, self.gpa, ep, &self.ev_scratch, &metrics);
            }
            // Files tab: list built files, and (if one is open) re-read its content.
            file_n = scan.listWorkFiles(self.io, self.gpa, dd, selbuf[0..sel_len], &self.file_scratch);
            var selfile: [128]u8 = undefined;
            var selfile_len: usize = 0;
            {
                self.store.lock();
                selfile_len = self.store.sel_file_len;
                @memcpy(selfile[0..selfile_len], self.store.sel_file[0..selfile_len]);
                self.store.unlock();
            }
            if (selfile_len > 0)
                fc_len = scan.readWorkFile(self.io, self.gpa, dd, selbuf[0..sel_len], selfile[0..selfile_len], &self.fc_scratch, &fc_trunc);
        }

        // 4) publish under lock
        {
            self.store.lock();
            self.store.server_online = online;
            self.store.fleet_swarms = fs;
            self.store.fleet_live = fl;
            self.store.fleet_minds = fm;
            self.store.fleet_headroom = fh;
            if (ver_len > 0) {
                @memcpy(self.store.server_version[0..ver_len], ver[0..ver_len]);
                self.store.server_version_len = ver_len;
            }
            @memcpy(self.store.swarms[0..nsw], self.swarm_scratch[0..nsw]);
            self.store.swarm_count = nsw;
            if (sel_len > 0) {
                @memcpy(self.store.events[0..ev_n], self.ev_scratch[0..ev_n]);
                self.store.event_count = ev_n;
                self.store.metrics = metrics;
                @memcpy(self.store.files[0..file_n], self.file_scratch[0..file_n]);
                self.store.file_count = file_n;
                @memcpy(self.store.file_content[0..fc_len], self.fc_scratch[0..fc_len]);
                self.store.file_content_len = fc_len;
                self.store.file_content_trunc = fc_trunc;
            }
            self.store.last_refresh_s = now_s;
            self.store.unlock();
        }

        // 5) notifications on transitions (poller-local memory, so no lock)
        self.notifyTransitions(online, self.swarm_scratch[0..nsw], selbuf[0..sel_len], metrics);
    }

    fn notifyTransitions(self: *Poller, online: bool, swarms: []const scan.SwarmSummary, sel: []const u8, sel_metrics: scan.Metrics) void {
        // server up/down
        if (self.prev_online_set and online != self.prev_online) {
            if (online) self.store.pushNotif("veil server online", "the control plane is up", 1) else self.store.pushNotif("veil server offline", "the control plane went away", 2);
        }
        self.prev_online = online;
        self.prev_online_set = true;

        // a swarm that WAS live is now stopped → completion notice
        for (swarms) |*sw| {
            if (!sw.stopped) continue;
            const was_live = self.wasLive(sw.idStr());
            const already = self.markStopped(sw.idStr());
            if (was_live and !already) {
                self.store.pushNotif("Swarm finished", sw.idStr(), 1);
            }
        }
        // remember the current live set for next round
        self.prev_live_n = 0;
        for (swarms) |*sw| {
            if (!sw.live) continue;
            if (self.prev_live_n >= self.prev_live_ids.len) break;
            const id = sw.idStr();
            const n = @min(id.len, self.prev_live_ids[self.prev_live_n].len);
            @memcpy(self.prev_live_ids[self.prev_live_n][0..n], id[0..n]);
            self.prev_live_lens[self.prev_live_n] = @intCast(n);
            self.prev_live_n += 1;
        }

        // zero-gradient sentinel firing on the OPEN swarm → surface it (it's the RSI signal we shipped)
        if (sel.len > 0 and sel_metrics.gradient_warn and !self.grad_warned) {
            self.store.pushNotif("Zero-gradient warning", "edits aren't reaching the failing check", 2);
            self.grad_warned = true;
        }
        if (sel.len == 0 or !sel_metrics.gradient_warn) self.grad_warned = false;
    }

    fn wasLive(self: *Poller, id: []const u8) bool {
        var i: usize = 0;
        while (i < self.prev_live_n) : (i += 1) {
            if (std.mem.eql(u8, self.prev_live_ids[i][0..self.prev_live_lens[i]], id)) return true;
        }
        return false;
    }
    /// Returns true if already marked stopped (so we notify once). Records it otherwise.
    fn markStopped(self: *Poller, id: []const u8) bool {
        var i: usize = 0;
        while (i < self.stopped_n) : (i += 1) {
            if (std.mem.eql(u8, self.stopped_ids[i][0..self.stopped_lens[i]], id)) return true;
        }
        if (self.stopped_n < self.stopped_ids.len) {
            const n = @min(id.len, self.stopped_ids[self.stopped_n].len);
            @memcpy(self.stopped_ids[self.stopped_n][0..n], id[0..n]);
            self.stopped_lens[self.stopped_n] = @intCast(n);
            self.stopped_n += 1;
        }
        return false;
    }
};

fn appendEsc(jb: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => jb.appendSlice(gpa, "\\\"") catch {},
            '\\' => jb.appendSlice(gpa, "\\\\") catch {},
            '\n' => jb.appendSlice(gpa, "\\n") catch {},
            '\r' => {},
            '\t' => jb.appendSlice(gpa, " ") catch {},
            else => jb.append(gpa, c) catch {},
        }
    }
}

// tiny JSON readers for the fleet response (flat object)
fn jint(body: []const u8, key: []const u8) i32 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return 0;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, body, needle) orelse return 0;
    var i = at + needle.len;
    while (i < body.len and body[i] == ' ') i += 1;
    var v: i32 = 0;
    var any = false;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
        v = v * 10 + @as(i32, body[i] - '0');
        any = true;
    }
    return if (any) v else 0;
}

var jstr_buf: [32]u8 = undefined;
fn jstr(body: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = at + needle.len;
    while (i < body.len and body[i] == ' ') i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    var w: usize = 0;
    while (i < body.len and body[i] != '"' and w < jstr_buf.len) : (i += 1) {
        jstr_buf[w] = body[i];
        w += 1;
    }
    return jstr_buf[0..w];
}
