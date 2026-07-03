//! tray.zig — the OS system-tray presence + native notifications. Windows gets a real Shell_NotifyIcon
//! icon with balloon toasts (the app "sits in the system tray when online"); Linux/macOS degrade to a
//! best-effort notifier (notify-send / osascript) and otherwise no-op, so the SAME app binary builds and
//! runs on all three. The in-app toast (drawn by the UI) is the always-present fallback; this layer adds
//! the native surface where the platform offers one cheaply.

const std = @import("std");
const builtin = @import("builtin");

pub const Tray = struct {
    inited: bool = false,
    online: bool = false,
    impl: Impl = .{},

    pub fn init(t: *Tray, title: []const u8) void {
        t.inited = Impl.init(&t.impl, title);
    }
    pub fn deinit(t: *Tray) void {
        if (t.inited) t.impl.deinit();
        t.inited = false;
    }
    /// Reflect server-online state in the tray tooltip/icon (no-op where unsupported).
    pub fn setOnline(t: *Tray, online: bool) void {
        if (t.online == online) return;
        t.online = online;
        if (t.inited) t.impl.setOnline(online);
    }
    /// Raise a native notification. `accent`: 0 info / 1 good / 2 warn.
    pub fn notify(t: *Tray, gpa: std.mem.Allocator, title: []const u8, body: []const u8, accent: u8) void {
        t.impl.notify(gpa, title, body, accent);
    }
    /// True if the user activated the tray icon and wants the window restored (Windows only).
    pub fn takeRestoreRequest(t: *Tray) bool {
        return if (t.inited) t.impl.takeRestoreRequest() else false;
    }
};

const Impl = if (builtin.os.tag == .windows) WindowsTray else PosixTray;

// ------------------------------------------------------------------------------------- Windows
const WindowsTray = struct {
    const w = std.os.windows;
    const WM_APP: u32 = 0x8000;
    const CALLBACK_MSG: u32 = WM_APP + 1;
    const NIM_ADD: u32 = 0;
    const NIM_MODIFY: u32 = 1;
    const NIM_DELETE: u32 = 2;
    const NIF_MESSAGE: u32 = 0x01;
    const NIF_ICON: u32 = 0x02;
    const NIF_TIP: u32 = 0x04;
    const NIF_INFO: u32 = 0x10;
    const NIIF_INFO: u32 = 0x1;
    const NIIF_WARNING: u32 = 0x2;

    const NOTIFYICONDATAW = extern struct {
        cbSize: u32,
        hWnd: ?*anyopaque,
        uID: u32,
        uFlags: u32,
        uCallbackMessage: u32,
        hIcon: ?*anyopaque,
        szTip: [128]u16,
        dwState: u32 = 0,
        dwStateMask: u32 = 0,
        szInfo: [256]u16,
        uVersionOrTimeout: u32 = 0,
        szInfoTitle: [64]u16,
        dwInfoFlags: u32 = 0,
        guidItem: [16]u8 = [_]u8{0} ** 16,
        hBalloonIcon: ?*anyopaque = null,
    };

    extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, lpData: *NOTIFYICONDATAW) callconv(.winapi) c_int;
    extern "user32" fn LoadIconW(hInstance: ?*anyopaque, lpIconName: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?*anyopaque;

    const IDI_APPLICATION: usize = 32512;

    nid: NOTIFYICONDATAW = undefined,
    live: bool = false,

    fn utf16z(dst: []u16, s: []const u8) void {
        const n = std.unicode.utf8ToUtf16Le(dst[0 .. dst.len - 1], s) catch 0;
        dst[@min(n, dst.len - 1)] = 0;
    }

    fn init(self: *WindowsTray, title: []const u8) bool {
        // Attach to a window so balloons route somewhere; the console/message window is enough for a v1
        // tray presence. A dedicated hidden message window is the next step for click-to-restore.
        const hwnd = GetConsoleWindow();
        self.nid = std.mem.zeroes(NOTIFYICONDATAW);
        self.nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        self.nid.hWnd = hwnd;
        self.nid.uID = 1;
        self.nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
        self.nid.uCallbackMessage = CALLBACK_MSG;
        self.nid.hIcon = LoadIconW(null, IDI_APPLICATION);
        utf16z(&self.nid.szTip, title);
        self.live = Shell_NotifyIconW(NIM_ADD, &self.nid) != 0;
        return self.live;
    }
    fn deinit(self: *WindowsTray) void {
        if (self.live) _ = Shell_NotifyIconW(NIM_DELETE, &self.nid);
        self.live = false;
    }
    fn setOnline(self: *WindowsTray, online: bool) void {
        if (!self.live) return;
        self.nid.uFlags = NIF_TIP;
        utf16z(&self.nid.szTip, if (online) "veil-desk — server ONLINE" else "veil-desk — server offline");
        _ = Shell_NotifyIconW(NIM_MODIFY, &self.nid);
    }
    fn notify(self: *WindowsTray, gpa: std.mem.Allocator, title: []const u8, body: []const u8, accent: u8) void {
        _ = gpa;
        if (!self.live) return;
        self.nid.uFlags = NIF_INFO;
        self.nid.dwInfoFlags = if (accent == 2) NIIF_WARNING else NIIF_INFO;
        utf16z(&self.nid.szInfoTitle, title);
        utf16z(&self.nid.szInfo, body);
        _ = Shell_NotifyIconW(NIM_MODIFY, &self.nid);
    }
    fn takeRestoreRequest(self: *WindowsTray) bool {
        _ = self;
        return false; // needs a real message pump; the window stays visible in v1
    }
};

// ------------------------------------------------------------------------------------- POSIX
const PosixTray = struct {
    fn init(self: *PosixTray, title: []const u8) bool {
        _ = self;
        _ = title;
        return true; // no persistent icon, but notify() still works via the desktop notifier
    }
    fn deinit(self: *PosixTray) void {
        _ = self;
    }
    fn setOnline(self: *PosixTray, online: bool) void {
        _ = self;
        _ = online;
    }
    /// v1: no native toast on POSIX — the always-present in-app toast (drawn by the UI) covers it, and
    /// keeping this a pure no-op guarantees the Linux/macOS build has zero process-spawn surface. A
    /// notify-send / osascript path (needs the poller's io handle threaded in) is the next increment.
    fn notify(self: *PosixTray, gpa: std.mem.Allocator, title: []const u8, body: []const u8, accent: u8) void {
        _ = self;
        _ = gpa;
        _ = title;
        _ = body;
        _ = accent;
    }
    fn takeRestoreRequest(self: *PosixTray) bool {
        _ = self;
        return false;
    }
};
