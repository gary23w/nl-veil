//! store.zig — the single source of truth shared between the UI thread (raylib, draw + input) and the
//! poller thread (io, filesystem + net). Every field behind one std.Thread.Mutex; the UI copies what it
//! needs under lock and never blocks on io, the poller writes under lock and never touches raylib. This
//! hard split is what keeps raylib single-threaded (its hard requirement) while the machine's state is
//! read off-thread.

const std = @import("std");
const scan = @import("scan.zig");

/// A tiny io-free spinlock. std.Thread.Mutex is gone in this Zig and std.Io.Mutex needs an io handle the
/// UI thread doesn't carry. Critical sections here are microscopic (copying a few small fixed arrays under
/// lock), contention is trivial (poller ~1Hz vs UI 60fps), so a spinlock is the right primitive.
const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),
    pub fn lock(s: *SpinLock) void {
        while (s.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    pub fn unlock(s: *SpinLock) void {
        s.held.store(false, .release);
    }
};

pub const Tab = enum { dashboard, deploy, swarm, hub, settings };

pub const CmdKind = enum { none, select, say, set_goal, stop, deploy, delete, refresh_now };

/// A UI→poller command. Fixed-size, copied by value into the ring, so no cross-thread allocation.
pub const Command = struct {
    kind: CmdKind = .none,
    id: [96]u8 = [_]u8{0} ** 96, // swarm path relative to data dir ("name" or "u1/<hexid>")
    id_len: u8 = 0,
    text: [3200]u8 = [_]u8{0} ** 3200, // holds the full deploy-body JSON, not just a goal line
    text_len: u16 = 0,

    pub fn idStr(c: *const Command) []const u8 {
        return c.id[0..c.id_len];
    }
    pub fn textStr(c: *const Command) []const u8 {
        return c.text[0..c.text_len];
    }
};

/// A poller→UI notification. Shown as an in-app toast AND handed to the OS tray (tray.zig).
pub const Notif = struct {
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: u8 = 0,
    body: [180]u8 = [_]u8{0} ** 180,
    body_len: u8 = 0,
    accent: u8 = 0, // 0 info / 1 good / 2 warn — maps to a palette color in the UI
    born_s: f64 = 0, // getTime() when raised, for the auto-dismiss fade
    fresh: bool = false, // not yet delivered to the OS tray

    pub fn titleStr(n: *const Notif) []const u8 {
        return n.title[0..n.title_len];
    }
    pub fn bodyStr(n: *const Notif) []const u8 {
        return n.body[0..n.body_len];
    }
};

pub const Settings = struct {
    data_dir: [512]u8 = [_]u8{0} ** 512,
    data_dir_len: u16 = 0,
    port: u16 = 8787,
    token: [128]u8 = [_]u8{0} ** 128,
    token_len: u8 = 0,
    notify: bool = true,

    pub fn dataDir(s: *const Settings) []const u8 {
        return s.data_dir[0..s.data_dir_len];
    }
    pub fn tokenStr(s: *const Settings) []const u8 {
        return s.token[0..s.token_len];
    }
};

const CMD_RING = 32;
const NOTIF_RING = 8;

pub const Store = struct {
    mu: SpinLock = .{},

    // --- server / fleet (poller writes) ---
    server_online: bool = false,
    server_version: [16]u8 = [_]u8{0} ** 16,
    server_version_len: u8 = 0,
    fleet_swarms: i32 = 0,
    fleet_live: i32 = 0,
    fleet_minds: i32 = 0,
    fleet_headroom: i32 = 0,
    last_refresh_s: i64 = 0,

    // --- roster (poller writes) ---
    swarms: [scan.MAX_SWARMS]scan.SwarmSummary = undefined,
    swarm_count: usize = 0,

    // --- selected swarm detail (poller writes when selection set) ---
    selected: [96]u8 = [_]u8{0} ** 96,
    selected_len: u8 = 0,
    events: [scan.MAX_LOG]scan.Ev = undefined,
    event_count: usize = 0,
    metrics: scan.Metrics = .{},

    // --- settings (UI writes, poller reads) ---
    settings: Settings = .{},

    // --- command ring (UI writes head, poller reads tail) ---
    cmds: [CMD_RING]Command = undefined,
    cmd_head: usize = 0,
    cmd_tail: usize = 0,

    // --- notification ring (poller writes, UI reads/renders + tray-delivers) ---
    notifs: [NOTIF_RING]Notif = undefined,
    notif_head: usize = 0,
    notif_count: usize = 0,

    pub fn lock(s: *Store) void {
        s.mu.lock();
    }
    pub fn unlock(s: *Store) void {
        s.mu.unlock();
    }

    /// UI thread: enqueue a command for the poller. Drops silently if the ring is full (poller is ~1s
    /// behind at worst; a dropped duplicate say/refresh is harmless).
    pub fn pushCmd(s: *Store, c: Command) void {
        s.lock();
        defer s.unlock();
        if ((s.cmd_head + 1) % CMD_RING == s.cmd_tail) return;
        s.cmds[s.cmd_head] = c;
        s.cmd_head = (s.cmd_head + 1) % CMD_RING;
    }

    /// Poller thread: pop the next command, or null. Caller must hold no lock (this takes it).
    pub fn popCmd(s: *Store) ?Command {
        s.lock();
        defer s.unlock();
        if (s.cmd_tail == s.cmd_head) return null;
        const c = s.cmds[s.cmd_tail];
        s.cmd_tail = (s.cmd_tail + 1) % CMD_RING;
        return c;
    }

    /// Poller thread: raise a notification. Overwrites the oldest when full.
    pub fn pushNotif(s: *Store, title: []const u8, body: []const u8, accent: u8) void {
        s.lock();
        defer s.unlock();
        var n: Notif = .{ .accent = accent, .fresh = true };
        const tl = @min(title.len, n.title.len);
        @memcpy(n.title[0..tl], title[0..tl]);
        n.title_len = @intCast(tl);
        const bl = @min(body.len, n.body.len);
        @memcpy(n.body[0..bl], body[0..bl]);
        n.body_len = @intCast(bl);
        const idx = (s.notif_head + s.notif_count) % NOTIF_RING;
        if (s.notif_count < NOTIF_RING) {
            s.notifs[idx] = n;
            s.notif_count += 1;
        } else {
            s.notifs[s.notif_head] = n;
            s.notif_head = (s.notif_head + 1) % NOTIF_RING;
        }
    }
};

pub fn mkCmd(kind: CmdKind, id: []const u8, text: []const u8) Command {
    var c: Command = .{ .kind = kind };
    const il = @min(id.len, c.id.len);
    @memcpy(c.id[0..il], id[0..il]);
    c.id_len = @intCast(il);
    const tl = @min(text.len, c.text.len);
    @memcpy(c.text[0..tl], text[0..tl]);
    c.text_len = @intCast(tl);
    return c;
}
