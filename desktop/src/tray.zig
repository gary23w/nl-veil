//! tray.zig — the OS system-tray presence + native notifications. On Windows it owns a real
//! Shell_NotifyIcon icon anchored to a HIDDEN message window we create (v1 anchored to GetConsoleWindow,
//! which is null under the Windows GUI subsystem — so no icon ever appeared). A per-frame `pump()` drains
//! that window's message queue so tray clicks reach us (double-click → restore the app). Linux/macOS
//! degrade to no-op stubs; the always-present in-app toast (drawn by the UI) is the cross-platform floor.

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
    pub fn setOnline(t: *Tray, online: bool) void {
        if (t.online == online) return;
        t.online = online;
        if (t.inited) t.impl.setOnline(online);
    }
    pub fn notify(t: *Tray, gpa: std.mem.Allocator, title: []const u8, body: []const u8, accent: u8) void {
        if (t.inited) t.impl.notify(gpa, title, body, accent);
    }
    /// Drain the tray window's message queue (Windows). Call once per UI frame.
    pub fn pump(t: *Tray) void {
        if (t.inited) t.impl.pump();
    }
    /// True (once) if the user double-clicked the tray icon and wants the window restored.
    pub fn takeRestoreRequest(t: *Tray) bool {
        return if (t.inited) t.impl.takeRestoreRequest() else false;
    }
};

const Impl = if (builtin.os.tag == .windows) WindowsTray else PosixTray;

// ------------------------------------------------------------------------------------- Windows
const WindowsTray = struct {
    const HWND = std.os.windows.HWND;
    const WM_APP: u32 = 0x8000;
    const CALLBACK_MSG: u32 = WM_APP + 1;
    const WM_LBUTTONDBLCLK: u32 = 0x0203;
    const WM_LBUTTONUP: u32 = 0x0202;
    const PM_REMOVE: u32 = 0x0001;
    const NIM_ADD: u32 = 0;
    const NIM_MODIFY: u32 = 1;
    const NIM_DELETE: u32 = 2;
    const NIF_MESSAGE: u32 = 0x01;
    const NIF_ICON: u32 = 0x02;
    const NIF_TIP: u32 = 0x04;
    const NIF_INFO: u32 = 0x10;
    const NIIF_INFO: u32 = 0x1;
    const NIIF_WARNING: u32 = 0x2;
    const IDI_APPLICATION: usize = 32512;

    const POINT = extern struct { x: i32, y: i32 };
    const MSG = extern struct {
        hwnd: ?HWND,
        message: u32,
        wParam: usize,
        lParam: isize,
        time: u32,
        pt: POINT,
    };
    const WNDPROC = *const fn (?HWND, u32, usize, isize) callconv(.winapi) isize;
    const WNDCLASSEXW = extern struct {
        cbSize: u32,
        style: u32,
        lpfnWndProc: WNDPROC,
        cbClsExtra: i32,
        cbWndExtra: i32,
        hInstance: ?*anyopaque,
        hIcon: ?*anyopaque,
        hCursor: ?*anyopaque,
        hbrBackground: ?*anyopaque,
        lpszMenuName: ?[*:0]const u16,
        lpszClassName: ?[*:0]const u16,
        hIconSm: ?*anyopaque,
    };
    const NOTIFYICONDATAW = extern struct {
        cbSize: u32,
        hWnd: ?HWND,
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
    extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?HWND;
    extern "user32" fn DefWindowProcW(hwnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
    extern "user32" fn DestroyWindow(hwnd: ?HWND) callconv(.winapi) i32;
    extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32, remove: u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;
    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

    // module-level state read by the WndProc (runs on the main thread inside pump()).
    var g_restore: bool = false;

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("VeilDeskTrayWnd");

    fn wndProc(hwnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
        if (msg == CALLBACK_MSG) {
            const ev: u32 = @intCast(@as(usize, @bitCast(lParam)) & 0xFFFF);
            if (ev == WM_LBUTTONDBLCLK or ev == WM_LBUTTONUP) g_restore = true;
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    nid: NOTIFYICONDATAW = undefined,
    hwnd: ?HWND = null,
    live: bool = false,

    fn utf16z(dst: []u16, s: []const u8) void {
        const n = std.unicode.utf8ToUtf16Le(dst[0 .. dst.len - 1], s) catch 0;
        dst[@min(n, dst.len - 1)] = 0;
    }

    fn init(self: *WindowsTray, title: []const u8) bool {
        const hinst = GetModuleHandleW(null);
        var wc = std.mem.zeroes(WNDCLASSEXW);
        wc.cbSize = @sizeOf(WNDCLASSEXW);
        wc.lpfnWndProc = &wndProc;
        wc.hInstance = hinst;
        wc.lpszClassName = class_name;
        _ = RegisterClassExW(&wc); // idempotent-ish; ignore "already registered"
        // A normal but never-shown window owns the tray icon (message-only windows are flakier hosts).
        self.hwnd = CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, null, null, hinst, null);
        if (self.hwnd == null) return false;
        self.nid = std.mem.zeroes(NOTIFYICONDATAW);
        self.nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        self.nid.hWnd = self.hwnd;
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
        if (self.hwnd) |h| _ = DestroyWindow(h);
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
    fn pump(self: *WindowsTray) void {
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, self.hwnd, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }
    fn takeRestoreRequest(self: *WindowsTray) bool {
        _ = self;
        if (g_restore) {
            g_restore = false;
            return true;
        }
        return false;
    }
};

// ------------------------------------------------------------------------------------- POSIX
const PosixTray = struct {
    fn init(self: *PosixTray, title: []const u8) bool {
        _ = self;
        _ = title;
        return true;
    }
    fn deinit(self: *PosixTray) void {
        _ = self;
    }
    fn setOnline(self: *PosixTray, online: bool) void {
        _ = self;
        _ = online;
    }
    fn notify(self: *PosixTray, gpa: std.mem.Allocator, title: []const u8, body: []const u8, accent: u8) void {
        _ = self;
        _ = gpa;
        _ = title;
        _ = body;
        _ = accent;
    }
    fn pump(self: *PosixTray) void {
        _ = self;
    }
    fn takeRestoreRequest(self: *PosixTray) bool {
        _ = self;
        return false;
    }
};
