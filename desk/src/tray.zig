//! tray.zig — the OS system-tray presence + native notifications. On Windows it owns a real
//! Shell_NotifyIcon icon anchored to a HIDDEN message window we create (GetConsoleWindow is null under
//! the Windows GUI subsystem, so it can't host the icon). A per-frame `pump()` drains that window's
//! message queue so tray clicks reach us (double-click → restore the app). Linux/macOS degrade to no-op
//! stubs; the always-present in-app toast (drawn by the UI) is the cross-platform floor.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const log = @import("log.zig");

pub const Tray = struct {
    inited: bool = false,
    online: bool = false,
    notify_enabled: bool = true,
    notify_enabled_set: bool = false,
    impl: Impl = .{},

    pub const MenuAction = enum { none, open_settings, toggle_notifications, refresh_now, quit };

    pub fn init(t: *Tray, title: []const u8) void {
        log.trace("tray.init title={s}", .{title});
        t.inited = Impl.init(&t.impl, title);
    }
    pub fn deinit(t: *Tray) void {
        log.trace("tray.deinit inited={}", .{t.inited});
        if (t.inited) t.impl.deinit();
        t.inited = false;
    }
    pub fn setOnline(t: *Tray, online: bool) void {
        if (t.online == online) return;
        log.trace("tray.setOnline {} -> {}", .{ t.online, online });
        t.online = online;
        if (t.inited) t.impl.setOnline(online);
    }
    pub fn setNotifyEnabled(t: *Tray, enabled: bool) void {
        // pumpTray() calls this every frame with the current setting — only log/act on an actual change,
        // else this floods the log at frame rate instead of on real toggles.
        if (t.notify_enabled_set and t.notify_enabled == enabled) return;
        log.trace("tray.setNotifyEnabled {}", .{enabled});
        t.notify_enabled = enabled;
        t.notify_enabled_set = true;
        if (t.inited) t.impl.setNotifyEnabled(enabled);
    }
    pub fn notify(t: *Tray, gpa: std.mem.Allocator, title: []const u8, body: []const u8, accent: u8) void {
        log.trace("tray.notify title={s} accent={d}", .{ title, accent });
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
    pub fn takeMenuAction(t: *Tray) MenuAction {
        return if (t.inited) t.impl.takeMenuAction() else .none;
    }
    pub const Diag = struct { reg: u16, hwnd: bool, add: bool, err: u32 };
    pub fn diag(_: *Tray) Diag {
        return if (builtin.os.tag == .windows)
            .{ .reg = WindowsTray.g_reg, .hwnd = WindowsTray.g_hwnd_ok, .add = WindowsTray.g_add_ok, .err = WindowsTray.g_err }
        else
            .{ .reg = 0, .hwnd = false, .add = false, .err = 0 };
    }
};

const Impl = if (builtin.os.tag == .windows) WindowsTray else PosixTray;

// ------------------------------------------------------------------------------------- Windows
const WindowsTray = struct {
    const MenuAction = Tray.MenuAction;

    const HWND = std.os.windows.HWND;
    const WM_APP: u32 = 0x8000;
    const CALLBACK_MSG: u32 = WM_APP + 1;
    const WM_LBUTTONDBLCLK: u32 = 0x0203;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_RBUTTONUP: u32 = 0x0205;
    const WM_CONTEXTMENU: u32 = 0x007B;
    const WM_NULL: u32 = 0x0000;
    const PM_REMOVE: u32 = 0x0001;
    const NIM_ADD: u32 = 0;
    const NIM_MODIFY: u32 = 1;
    const NIM_DELETE: u32 = 2;
    const NIM_SETVERSION: u32 = 4;
    const NOTIFYICON_VERSION_4: u32 = 4;
    const NIF_MESSAGE: u32 = 0x01;
    const NIF_ICON: u32 = 0x02;
    const NIF_TIP: u32 = 0x04;
    const NIF_INFO: u32 = 0x10;
    const NIIF_INFO: u32 = 0x1;
    const NIIF_WARNING: u32 = 0x2;
    const IDI_APPLICATION: usize = 32512;
    const BI_RGB: u32 = 0;
    const DIB_RGB_COLORS: u32 = 0;

    const MF_STRING: u32 = 0x00000000;
    const MF_SEPARATOR: u32 = 0x00000800;
    const MF_CHECKED: u32 = 0x00000008;
    const TPM_NONOTIFY: u32 = 0x0080;
    const TPM_RETURNCMD: u32 = 0x0100;

    const MENU_OPEN: usize = 1001;
    const MENU_SETTINGS: usize = 1002;
    const MENU_TOGGLE_NOTIFS: usize = 1003;
    const MENU_REFRESH: usize = 1004;
    const MENU_QUIT: usize = 1005;

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
    const RGBQUAD = extern struct {
        rgbBlue: u8,
        rgbGreen: u8,
        rgbRed: u8,
        rgbReserved: u8,
    };
    const BITMAPINFOHEADER = extern struct {
        biSize: u32,
        biWidth: i32,
        biHeight: i32,
        biPlanes: u16,
        biBitCount: u16,
        biCompression: u32,
        biSizeImage: u32,
        biXPelsPerMeter: i32,
        biYPelsPerMeter: i32,
        biClrUsed: u32,
        biClrImportant: u32,
    };
    const BITMAPINFO = extern struct {
        bmiHeader: BITMAPINFOHEADER,
        bmiColors: [1]RGBQUAD,
    };
    const ICONINFO = extern struct {
        fIcon: i32,
        xHotspot: u32,
        yHotspot: u32,
        hbmMask: ?*anyopaque,
        hbmColor: ?*anyopaque,
    };
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
    extern "user32" fn LoadIconW(hInstance: ?*anyopaque, lpIconName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "user32" fn DestroyIcon(hIcon: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn CreateIconIndirect(piconinfo: *const ICONINFO) callconv(.winapi) ?*anyopaque;
    extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?HWND;
    extern "user32" fn DefWindowProcW(hwnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
    extern "user32" fn DestroyWindow(hwnd: ?HWND) callconv(.winapi) i32;
    extern "user32" fn ShowWindow(hwnd: ?HWND, cmd: i32) callconv(.winapi) i32;
    extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32, remove: u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;
    extern "user32" fn CreatePopupMenu() callconv(.winapi) ?*anyopaque;
    extern "user32" fn DestroyMenu(hMenu: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn AppendMenuW(hMenu: ?*anyopaque, flags: u32, itemId: usize, text: ?[*:0]const u16) callconv(.winapi) i32;
    extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) i32;
    extern "user32" fn SetForegroundWindow(hwnd: ?HWND) callconv(.winapi) i32;
    extern "user32" fn TrackPopupMenuEx(hMenu: ?*anyopaque, flags: u32, x: i32, y: i32, hwnd: ?HWND, tpm: ?*anyopaque) callconv(.winapi) u32;
    extern "user32" fn PostMessageW(hwnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) i32;
    extern "gdi32" fn CreateDIBSection(hdc: ?*anyopaque, pbmi: *const BITMAPINFO, usage: u32, bits: *?*anyopaque, hSection: ?*anyopaque, offset: u32) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn CreateBitmap(width: i32, height: i32, planes: u32, bits_per_pixel: u32, bits: ?*const anyopaque) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn DeleteObject(obj: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

    // module-level state read by the WndProc (runs on the main thread inside pump()).
    var g_restore: bool = false;
    var g_menu_action: MenuAction = .none;
    var g_self: ?*WindowsTray = null;
    // diagnostics captured during init (read by Tray.diag for troubleshooting)
    var g_reg: u16 = 0;
    var g_hwnd_ok: bool = false;
    var g_add_ok: bool = false;
    var g_err: u32 = 0;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("VeilDeskTrayWnd");
    const menu_open = std.unicode.utf8ToUtf16LeStringLiteral("Open");
    const menu_settings = std.unicode.utf8ToUtf16LeStringLiteral("Settings");
    const menu_notifications = std.unicode.utf8ToUtf16LeStringLiteral("Notifications");
    const menu_refresh = std.unicode.utf8ToUtf16LeStringLiteral("Refresh now");
    const menu_quit = std.unicode.utf8ToUtf16LeStringLiteral("Quit");

    fn queueMenuAction(action: MenuAction) void {
        if (g_menu_action == .none) g_menu_action = action;
    }

    fn intResource(id: usize) ?[*:0]const u16 {
        return @as(?[*:0]const u16, @ptrFromInt(id));
    }

    fn imageToHicon(img: rl.Image) ?*anyopaque {
        if (img.width <= 0 or img.height <= 0) return null;

        const w: usize = @intCast(img.width);
        const h: usize = @intCast(img.height);
        const px_count = w * h;
        if (px_count == 0) return null;

        var bmi = std.mem.zeroes(BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = img.width;
        bmi.bmiHeader.biHeight = -img.height; // top-down bitmap
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;

        var dib_bits: ?*anyopaque = null;
        const hbm_color = CreateDIBSection(null, &bmi, DIB_RGB_COLORS, &dib_bits, null, 0) orelse return null;
        defer _ = DeleteObject(hbm_color);
        const raw = dib_bits orelse return null;

        const src: [*]const u8 = @ptrCast(img.data);
        const dst: [*]u8 = @ptrCast(raw);
        var i: usize = 0;
        while (i < px_count) : (i += 1) {
            const p = i * 4;
            const a: u16 = src[p + 3];
            const r: u16 = src[p + 0];
            const g: u16 = src[p + 1];
            const b: u16 = src[p + 2];
            // Windows icons expect premultiplied alpha in the 32-bit color bitmap.
            dst[p + 0] = @intCast((b * a + 127) / 255); // B
            dst[p + 1] = @intCast((g * a + 127) / 255); // G
            dst[p + 2] = @intCast((r * a + 127) / 255); // R
            dst[p + 3] = @intCast(a); // A
        }

        var mask_storage: [512]u8 = [_]u8{0} ** 512;
        const mask_bytes = (px_count + 7) / 8;
        if (mask_bytes > mask_storage.len) return null;
        @memset(mask_storage[0..mask_bytes], 0);

        const hbm_mask = CreateBitmap(img.width, img.height, 1, 1, @as(?*const anyopaque, @ptrCast(mask_storage[0..mask_bytes].ptr))) orelse return null;
        defer _ = DeleteObject(hbm_mask);

        var ii = ICONINFO{ .fIcon = 1, .xHotspot = 0, .yHotspot = 0, .hbmMask = hbm_mask, .hbmColor = hbm_color };
        return CreateIconIndirect(&ii);
    }

    fn showContextMenu(hwnd: ?HWND) void {
        const menu = CreatePopupMenu() orelse return;
        defer _ = DestroyMenu(menu);

        _ = AppendMenuW(menu, MF_STRING, MENU_OPEN, menu_open);
        _ = AppendMenuW(menu, MF_STRING, MENU_SETTINGS, menu_settings);
        _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
        var notif_flags: u32 = MF_STRING;
        if (g_self != null and g_self.?.notify_enabled) notif_flags |= MF_CHECKED;
        _ = AppendMenuW(menu, notif_flags, MENU_TOGGLE_NOTIFS, menu_notifications);
        _ = AppendMenuW(menu, MF_STRING, MENU_REFRESH, menu_refresh);
        _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
        _ = AppendMenuW(menu, MF_STRING, MENU_QUIT, menu_quit);

        var pt: POINT = undefined;
        if (GetCursorPos(&pt) == 0) return;
        _ = SetForegroundWindow(hwnd);
        const sel = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, hwnd, null);
        switch (sel) {
            MENU_OPEN => g_restore = true,
            MENU_SETTINGS => queueMenuAction(.open_settings),
            MENU_TOGGLE_NOTIFS => queueMenuAction(.toggle_notifications),
            MENU_REFRESH => queueMenuAction(.refresh_now),
            MENU_QUIT => queueMenuAction(.quit),
            else => {},
        }
        _ = PostMessageW(hwnd, WM_NULL, 0, 0);
    }

    fn loadIconFromPng(self: *WindowsTray) ?*anyopaque {
        _ = self;
        const candidates = [_][:0]const u8{
            "assets/icon.png",
            "desk/assets/icon.png",
            "../assets/icon.png",
            "../desk/assets/icon.png",
        };
        for (candidates) |path| {
            if (rl.loadImage(path)) |loaded| {
                var img = loaded;
                defer rl.unloadImage(img);
                img.resize(32, 32);
                img.setFormat(.uncompressed_r8g8b8a8);
                if (imageToHicon(img)) |h_icon| {
                    log.info("tray: icon loaded from {s}", .{path});
                    return h_icon;
                }
                log.warn("tray: failed to convert icon image at {s}", .{path});
            } else |_| {}
        }
        return null;
    }

    nid: NOTIFYICONDATAW = undefined,
    hwnd: ?HWND = null,
    live: bool = false,
    icon_handle: ?*anyopaque = null,
    icon_owned: bool = false,
    notify_enabled: bool = true,

    fn utf16z(dst: []u16, s: []const u8) void {
        const n = std.unicode.utf8ToUtf16Le(dst[0 .. dst.len - 1], s) catch 0;
        dst[@min(n, dst.len - 1)] = 0;
    }

    fn init(self: *WindowsTray, title: []const u8) bool {
        g_self = self;
        const hinst = GetModuleHandleW(null);
        var wc = std.mem.zeroes(WNDCLASSEXW);
        wc.cbSize = @sizeOf(WNDCLASSEXW);
        wc.lpfnWndProc = &wndProc;
        wc.hInstance = hinst;
        wc.lpszClassName = class_name;
        g_reg = RegisterClassExW(&wc); // idempotent-ish; ignore "already registered"
        // Match the canonical Win32 tray recipe: a REAL overlapped window created then hidden (SW_HIDE) —
        // a proper window is a more reliable icon host than a zero-size style-0 one.
        const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
        const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
        const SW_HIDE: i32 = 0;
        self.hwnd = CreateWindowExW(0, class_name, class_name, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, null, null, hinst, null);
        g_hwnd_ok = self.hwnd != null;
        if (self.hwnd == null) {
            g_err = GetLastError();
            return false;
        }
        _ = ShowWindow(self.hwnd, SW_HIDE);
        self.nid = std.mem.zeroes(NOTIFYICONDATAW);
        self.nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        self.nid.hWnd = self.hwnd;
        self.nid.uID = 1;
        self.nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
        self.nid.uCallbackMessage = CALLBACK_MSG;
        self.icon_owned = false;
        self.icon_handle = null;
        if (loadIconFromPng(self)) |h_icon| {
            self.icon_handle = h_icon;
            self.icon_owned = true;
            self.nid.hIcon = h_icon;
        } else {
            self.nid.hIcon = LoadIconW(null, intResource(IDI_APPLICATION));
            if (self.nid.hIcon == null) {
                g_err = GetLastError();
                log.warn("tray: failed to load default system icon, err={d}", .{g_err});
            }
        }
        utf16z(&self.nid.szTip, title);
        self.live = Shell_NotifyIconW(NIM_ADD, &self.nid) != 0;
        g_add_ok = self.live;
        if (!self.live) g_err = GetLastError();
        if (self.live) {
            // Adopt the modern (v4) behavior contract — without SETVERSION the callback + balloon
            // semantics vary by shell and the icon can misbehave on Win10/11.
            self.nid.uVersionOrTimeout = NOTIFYICON_VERSION_4;
            _ = Shell_NotifyIconW(NIM_SETVERSION, &self.nid);
        }
        // ground truth for the tray: added or rejected, and the OS error if any.
        log.info("tray: reg={d} hwnd={} add={} lastErr={d} (add=false OR add=true-but-invisible => Win11 hides new icons in the overflow flyout)", .{ g_reg, g_hwnd_ok, self.live, g_err });
        return self.live;
    }
    fn deinit(self: *WindowsTray) void {
        log.trace("tray.WindowsTray.deinit live={}", .{self.live});
        if (self.live) _ = Shell_NotifyIconW(NIM_DELETE, &self.nid);
        if (self.hwnd) |h| _ = DestroyWindow(h);
        if (self.icon_owned and self.icon_handle != null) _ = DestroyIcon(self.icon_handle);
        self.live = false;
        self.icon_handle = null;
        self.icon_owned = false;
        if (g_self == self) g_self = null;
    }
    fn setOnline(self: *WindowsTray, online: bool) void {
        log.trace("tray.WindowsTray.setOnline {}", .{online});
        if (!self.live) return;
        self.nid.uFlags = NIF_TIP;
        utf16z(&self.nid.szTip, if (online) "veil-desk — server ONLINE" else "veil-desk — server offline");
        _ = Shell_NotifyIconW(NIM_MODIFY, &self.nid);
    }
    fn notify(self: *WindowsTray, gpa: std.mem.Allocator, title: []const u8, body: []const u8, accent: u8) void {
        _ = gpa;
        log.trace("tray.WindowsTray.notify title={s} accent={d}", .{ title, accent });
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
    fn setNotifyEnabled(self: *WindowsTray, enabled: bool) void {
        self.notify_enabled = enabled;
    }
    fn takeRestoreRequest(self: *WindowsTray) bool {
        _ = self;
        if (g_restore) {
            g_restore = false;
            return true;
        }
        return false;
    }
    fn takeMenuAction(self: *WindowsTray) MenuAction {
        _ = self;
        const action = g_menu_action;
        g_menu_action = .none;
        return action;
    }

    fn wndProc(hwnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
        if (msg == CALLBACK_MSG) {
            const ev: u32 = @intCast(@as(usize, @bitCast(lParam)) & 0xFFFF);
            if (ev == WM_LBUTTONDBLCLK or ev == WM_LBUTTONUP) {
                g_restore = true;
                return 0;
            }
            if (ev == WM_RBUTTONUP or ev == WM_CONTEXTMENU) {
                showContextMenu(hwnd);
                return 0;
            }
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
};

// ------------------------------------------------------------------------------------- POSIX
const PosixTray = struct {
    const MenuAction = Tray.MenuAction;

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
    fn setNotifyEnabled(self: *PosixTray, enabled: bool) void {
        _ = self;
        _ = enabled;
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
    fn takeMenuAction(self: *PosixTray) MenuAction {
        _ = self;
        return .none;
    }
};
