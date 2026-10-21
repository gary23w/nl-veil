//! tray.zig — the OS system-tray presence + native notifications. On Windows it owns a real
//! Shell_NotifyIcon icon anchored to a HIDDEN message window we create (GetConsoleWindow is null under
//! the Windows GUI subsystem, so it can't host the icon). That window lives on the UI thread, so raylib's own
//! unfiltered message poll delivers tray clicks to wndProc (a click restores the app); there is deliberately no
//! tray MESSAGE pump (WindowsTray says why a window-filtered peek must never come back). Tray.pump is a per-frame
//! chore tick that never reads the queue: it promotes a first-run icon out of Windows 11's overflow flyout and
//! retries a timed-out NIM_ADD (WindowsTray.pump). Linux/macOS degrade to no-op stubs; the always-present in-app
//! toast (drawn by the UI) is the cross-platform floor.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const log = @import("log.zig");
const assets = @import("assets.zig");

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
    /// Once per frame, from main's pumpTray. Drives the bounded, once-per-process chores a Windows tray cannot
    /// finish inside init — promoting the icon out of Windows 11's overflow flyout, and retrying a NIM_ADD the
    /// shell timed out (WindowsTray.pump) — and never reads the message queue. A no-op elsewhere. Runs even when
    /// init reported failure, because the add-retry is what turns that failure around: `inited` is raised once a
    /// retried add lands so canHide and deinit see the live icon.
    pub fn pump(t: *Tray) void {
        if (t.impl.pump()) t.inited = true;
    }
    /// True (once) if the user double-clicked the tray icon and wants the window restored.
    pub fn takeRestoreRequest(t: *Tray) bool {
        return if (t.inited) t.impl.takeRestoreRequest() else false;
    }
    pub fn takeMenuAction(t: *Tray) MenuAction {
        return if (t.inited) t.impl.takeMenuAction() else .none;
    }
    /// Whether the window may be HIDDEN to this tray — i.e. whether a real, live icon exists to bring it
    /// back. Not the same as `inited`: PosixTray.init returns true while every one of its methods is a
    /// no-op, so trusting `inited` would strand a Linux/macOS user behind an invisible window with no icon
    /// and no menu. False ⇒ the close button keeps its old meaning and quits.
    pub fn canHide(t: *Tray) bool {
        if (!t.inited) return false;
        return if (builtin.os.tag == .windows) WindowsTray.g_add_ok else false;
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
    // NOTIFYICON_VERSION_4 (adopted in init) changes what an ACTIVATION sends: the shell delivers
    // NIN_SELECT / NIN_KEYSELECT, not WM_LBUTTONUP. Only the button-up codes were handled, so clicking the
    // icon has never restored anything — right-click worked only because WM_CONTEXTMENU is itself a v4
    // message. Harmless while the window was always on screen; the whole way back once it can be hidden.
    const NIN_SELECT: u32 = 0x0400; // WM_USER + 0
    const NIN_KEYSELECT: u32 = 0x0401; // WM_USER + 1
    // Messages on the tray's OWN top-level window (it is a real WS_OVERLAPPEDWINDOW, parent=null), all of
    // which used to fall through to DefWindowProcW — fine when the app died with its desk, load-bearing now.
    const WM_CLOSE: u32 = 0x0010;
    const WM_QUERYENDSESSION: u32 = 0x0011;
    const WM_ENDSESSION: u32 = 0x0016;
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

    // The two once-per-process chores pump() drives; both bounded (see Retry). NIM_ADD is documented to fail
    // with ERROR_TIMEOUT when the shell is busy, so that one failure is retried: 5 tries ~1 s apart. The shell
    // creates an icon's NotifyIconSettings subkey asynchronously after the first NIM_ADD, so the promotion
    // probe retries until the subkey exists: 20 tries ~500 ms apart, then it gives up quietly.
    const ERROR_TIMEOUT: u32 = 1460;
    const ADD_RETRY_TRIES: u32 = 5;
    const ADD_RETRY_GAP_MS: u64 = 1_000;
    const PROMOTE_TRIES: u32 = 20;
    const PROMOTE_GAP_MS: u64 = 500;

    // Registry (advapi32) — only for the promotion chore. HKEY_CURRENT_USER is the predefined handle value the
    // SDK headers give (std.os.windows spells it the same way).
    const HKEY = *anyopaque;
    const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
    const KEY_READ: u32 = 0x20019;
    const KEY_SET_VALUE: u32 = 0x0002;
    const REG_SZ: u32 = 1;
    const REG_DWORD: u32 = 4;
    const ERROR_SUCCESS: i32 = 0;
    const ERROR_FILE_NOT_FOUND: i32 = 2;
    const ERROR_MORE_DATA: i32 = 234;
    const ERROR_NO_MORE_ITEMS: i32 = 259;

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
    extern "user32" fn RegisterWindowMessageW(lpString: [*:0]const u16) callconv(.winapi) u32;
    extern "user32" fn TrackPopupMenuEx(hMenu: ?*anyopaque, flags: u32, x: i32, y: i32, hwnd: ?HWND, tpm: ?*anyopaque) callconv(.winapi) u32;
    extern "user32" fn PostMessageW(hwnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) i32;
    extern "gdi32" fn CreateDIBSection(hdc: ?*anyopaque, pbmi: *const BITMAPINFO, usage: u32, bits: *?*anyopaque, hSection: ?*anyopaque, offset: u32) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn CreateBitmap(width: i32, height: i32, planes: u32, bits_per_pixel: u32, bits: ?*const anyopaque) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn DeleteObject(obj: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64; // ms since boot: the chores' clock (Retry)
    extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: ?[*:0]const u16, ulOptions: u32, samDesired: u32, phkResult: *HKEY) callconv(.winapi) i32;
    extern "advapi32" fn RegEnumKeyExW(hKey: HKEY, dwIndex: u32, lpName: [*]u16, lpcchName: *u32, lpReserved: ?*u32, lpClass: ?[*]u16, lpcchClass: ?*u32, lpftLastWriteTime: ?*anyopaque) callconv(.winapi) i32;
    extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: ?[*:0]const u16, lpReserved: ?*u32, lpType: ?*u32, lpData: ?[*]u8, lpcbData: ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegSetValueExW(hKey: HKEY, lpValueName: ?[*:0]const u16, Reserved: u32, dwType: u32, lpData: ?[*]const u8, cbData: u32) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;
    extern "shell32" fn SHGetKnownFolderPath(rfid: *const GUID, dwFlags: u32, hToken: ?*anyopaque, ppszPath: *?[*:0]u16) callconv(.winapi) i32;
    extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

    // module-level state read by the WndProc (runs on the UI thread, dispatched from raylib's message poll).
    var g_restore: bool = false;
    var g_menu_action: MenuAction = .none;
    var g_self: ?*WindowsTray = null;
    // diagnostics captured during init (read by Tray.diag for troubleshooting)
    var g_reg: u16 = 0;
    var g_hwnd_ok: bool = false;
    var g_add_ok: bool = false;
    var g_err: u32 = 0;
    var g_taskbar_created: u32 = 0; // the shell's "notification area re-created" broadcast; see wndProc
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("VeilDeskTrayWnd");
    const menu_open = std.unicode.utf8ToUtf16LeStringLiteral("Open veil-desk");
    const menu_settings = std.unicode.utf8ToUtf16LeStringLiteral("Settings");
    const menu_notifications = std.unicode.utf8ToUtf16LeStringLiteral("Notifications");
    const menu_refresh = std.unicode.utf8ToUtf16LeStringLiteral("Refresh now");
    // The close button no longer stops anything, so this menu is the only place the real quit is
    // discoverable — it should say what it actually does.
    const menu_quit = std.unicode.utf8ToUtf16LeStringLiteral("Quit veil (stops the server)");
    // Where Windows 11 keeps its per-icon tray placement (see pump).
    const notify_icon_settings = std.unicode.utf8ToUtf16LeStringLiteral("Control Panel\\NotifyIconSettings");
    const value_executable_path = std.unicode.utf8ToUtf16LeStringLiteral("ExecutablePath");
    const value_is_promoted = std.unicode.utf8ToUtf16LeStringLiteral("IsPromoted");

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
        // EMBEDDED FIRST: the icon is compiled into the exe, so the tray shows the real brand mark in a
        // released bundle. It previously probed CWD-relative paths, missed them all outside the repo, and
        // silently fell back to the generic IDI_APPLICATION icon (see the caller).
        if (assets.iconImage()) |loaded| {
            var img = loaded;
            defer rl.unloadImage(img);
            if (iconImageToHicon(&img)) |h_icon| {
                log.info("tray: icon loaded from the embedded asset", .{});
                return h_icon;
            }
            log.warn("tray: failed to convert the embedded icon image", .{});
        }
        // Disk probes retained as a last resort (edited assets/ in a source checkout, or a decode failure).
        const candidates = [_][:0]const u8{
            "assets/icon48x48.png",
            "desk/assets/icon48x48.png",
            "../assets/icon48x48.png",
            "../desk/assets/icon48x48.png",
        };
        for (candidates) |path| {
            if (rl.loadImage(path)) |loaded| {
                var img = loaded;
                defer rl.unloadImage(img);
                if (iconImageToHicon(&img)) |h_icon| {
                    log.info("tray: icon loaded from {s}", .{path});
                    return h_icon;
                }
                log.warn("tray: failed to convert icon image at {s}", .{path});
            } else |_| {}
        }
        return null;
    }

    /// Normalize a decoded icon image to the 32x32 RGBA the notification area wants, then hand it to
    /// CreateIconIndirect. Shared by the embedded and on-disk paths so both produce an identical icon.
    fn iconImageToHicon(img: *rl.Image) ?*anyopaque {
        img.resize(32, 32);
        img.setFormat(.uncompressed_r8g8b8a8);
        return imageToHicon(img.*);
    }

    nid: NOTIFYICONDATAW = undefined,
    hwnd: ?HWND = null,
    live: bool = false,
    icon_handle: ?*anyopaque = null,
    icon_owned: bool = false,
    notify_enabled: bool = true,
    // The once-per-process chores pump() drives after init; null once settled, which is the per-frame fast path.
    add_retry: ?Retry = null, // armed when NIM_ADD failed with ERROR_TIMEOUT
    promote: ?Retry = null, // armed by a successful NIM_ADD: the IsPromoted probe of NotifyIconSettings

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
        g_taskbar_created = RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));
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
            self.promote = Retry.arm(PROMOTE_TRIES, PROMOTE_GAP_MS, GetTickCount64());
        } else if (g_err == ERROR_TIMEOUT) {
            self.add_retry = Retry.arm(ADD_RETRY_TRIES, ADD_RETRY_GAP_MS, GetTickCount64());
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
    // NO PER-FRAME MESSAGE PUMP HERE - AND NEVER A WINDOW-FILTERED PeekMessage ON THE UI THREAD. (pump() below
    // is a chore tick that reads no messages.)
    //
    // The tray window is created on the UI thread (init runs there), so the unfiltered PeekMessageW(NULL, ...)
    // loop raylib runs every frame (EndDrawing -> PollInputEvents -> glfwPollEvents; rl.pollInputEvents on the
    // hidden path) already retrieves this window's messages, and DispatchMessageW routes them to wndProc below.
    //
    // Until 2026-09-16 the frame loop ALSO drained this window with `PeekMessageW(&msg, self.hwnd, 0, 0,
    // PM_REMOVE)` once per frame, and that filtered peek is what made Windows call the desk "Not Responding"
    // while it was drawing at 60 fps. Windows' hung-app clock (a window is "hung" 5 s after its thread last
    // read the queue) is only credited by the unfiltered poll, and with a window-filtered peek running each
    // frame that credit stops: IsHungAppWindow(glfw window) went TRUE whenever no message happened to arrive
    // for 5 s, DWM swapped in a "veil-desk (Not Responding)" ghost within 50 ms, the ghost ate every click, so
    // the real window never received the input that would have un-hung it - a hang with the frame loop alive,
    // the watchdog silent and the server fine. Reproduced outside this program: a 60 fps PeekMessageW(NULL)
    // loop with a GL swap stays responsive indefinitely; add one filtered peek on a second window of the same
    // thread each frame and Windows flags it ~5 s after the last message. Posting any message (even WM_NULL)
    // un-hung it for exactly 5 s, which is how the diagnosis was confirmed. watchdog.zig now logs this state.
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

    /// The per-frame chore tick (Tray.pump), on the UI thread like everything else here; returns whether the
    /// icon is live. It reads NO messages (the block above says why) — it only drives two once-per-process
    /// chores, each bounded by a Retry, so a shell that never answers costs a few probes and then silence:
    ///
    ///  - add_retry: init's NIM_ADD failed with ERROR_TIMEOUT (Microsoft documents NIM_ADD failing that way
    ///    when the shell is busy). Up to 5 more NIM_ADDs ~1 s apart; then the icon stays unavailable as before.
    ///
    ///  - promote: the first-run invisibility. A fresh Windows 11 machine showed NO icon on the desk's first run
    ///    although init's own line said reg/hwnd/add were all fine. Windows 11 parks a newly added notification
    ///    icon in the hidden overflow flyout unless the per-icon setting IsPromoted is 1, and that setting lives
    ///    under HKCU\Control Panel\NotifyIconSettings\<decimal id>: one subkey per exe path, holding
    ///    ExecutablePath (REG_SZ: the exe's path, literal or in the {KNOWNFOLDERID}\rest spelling
    ///    execPathIsOurs describes) and InitialTooltip (REG_SZ "veil-desk"); the Settings page "Other system
    ///    tray icons" toggles write IsPromoted (REG_DWORD 1/0) there. Measured on this machine (Windows 11 Home
    ///    10.0.26300, 2026-10-21): 39 such subkeys, 15 of them veil.exe / veil-desk.exe paths run here,
    ///    IsPromoted ABSENT on every veil one (present on exactly one subkey in all, OneDrive.exe, value 1).
    ///    The shell creates the subkey itself after the app's first NIM_ADD, so the probe retries
    ///    (~20 x 500 ms) until the subkey for this exe exists; promoteIcon says what it does there. An
    ///    IsPromoted that already exists (0 or 1) is the user's choice and is never touched.
    fn pump(self: *WindowsTray) bool {
        if (self.hwnd == null) return self.live;
        if (self.add_retry == null and self.promote == null) return self.live;
        const now = GetTickCount64();
        if (self.add_retry) |r| {
            if (self.live) { // wndProc's TaskbarCreated re-add got there first: nothing left to retry
                self.add_retry = null;
                self.promote = Retry.arm(PROMOTE_TRIES, PROMOTE_GAP_MS, now);
                return self.live;
            }
            if (!r.due(now)) return self.live;
            var next = r;
            next.spent(now);
            if (self.addIcon()) {
                log.info("tray: NIM_ADD succeeded on retry {d}/{d}", .{ next.tries, next.limit });
                self.add_retry = null;
                self.promote = Retry.arm(PROMOTE_TRIES, PROMOTE_GAP_MS, now);
            } else if (next.exhausted() or g_err != ERROR_TIMEOUT) {
                log.warn("tray: NIM_ADD still rejected after {d} retries, lastErr={d}; the icon stays unavailable", .{ next.tries, g_err });
                self.add_retry = null;
            } else {
                self.add_retry = next;
            }
            return self.live;
        }
        if (self.promote) |r| {
            if (!r.due(now)) return self.live;
            var next = r;
            next.spent(now);
            switch (self.promoteIcon()) {
                .not_found => {
                    if (next.exhausted()) {
                        log.info("tray: no NotifyIconSettings subkey names this exe after {d} probes; the icon's placement is left to Windows", .{next.tries});
                        self.promote = null;
                    } else {
                        self.promote = next;
                    }
                },
                .promoted => {
                    log.info("tray: IsPromoted was absent for this exe; set it to 1 and re-added the icon (live={})", .{self.live});
                    self.promote = null;
                },
                .already_set => |v| {
                    log.info("tray: IsPromoted already present for this exe (type={d} value={d}); left as the user's choice", .{ v.kind, v.value });
                    self.promote = null;
                },
                .api_error => |e| {
                    log.warn("tray: NotifyIconSettings probe failed at {s}, code={d}; giving up", .{ e.where, e.code });
                    self.promote = null;
                },
            }
        }
        return self.live;
    }

    /// NIM_ADD + the v4 SETVERSION with uFlags restored first (setOnline and notify overwrite it with NIF_TIP /
    /// NIF_INFO): the sequence wndProc runs on TaskbarCreated, for pump's retry and promoteIcon's re-add.
    /// Records live / g_add_ok / g_err like init does.
    fn addIcon(self: *WindowsTray) bool {
        self.nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
        self.live = Shell_NotifyIconW(NIM_ADD, &self.nid) != 0;
        g_add_ok = self.live;
        if (self.live) {
            self.nid.uVersionOrTimeout = NOTIFYICON_VERSION_4;
            _ = Shell_NotifyIconW(NIM_SETVERSION, &self.nid);
        } else {
            g_err = GetLastError();
        }
        return self.live;
    }

    /// Does a subkey's ExecutablePath name this process's exe? Measured here (39 subkeys, 2026-10-21): the
    /// shell stores a path under the user profile or a plain C:\dir literally (every veil entry was one of
    /// those), but a path under Program Files, Program Files (x86), Windows or System32 as
    /// {KNOWNFOLDERID}\rest — e.g. {6D809377-6AF0-444B-8957-A3773F02200E}\WindowsApps\...\app.exe, and
    /// SHGetKnownFolderPath resolves that GUID to C:\Program Files on this machine (the other three to
    /// C:\Program Files (x86), C:\Windows, C:\Windows\system32). A Store or Program Files install is spelled
    /// that way, so the GUID form is resolved through the same API before comparing.
    fn execPathIsOurs(reg_path: []const u16, own_path: []const u16) bool {
        if (eqlUtf16IgnoreAsciiCase(reg_path, own_path)) return true;
        const kf = splitKnownFolder(reg_path) orelse return false;
        const guid = parseGuid(kf.guid) orelse return false;
        var folder: ?[*:0]u16 = null;
        if (SHGetKnownFolderPath(&guid, 0, null, &folder) != 0) return false;
        defer CoTaskMemFree(@as(?*anyopaque, @ptrCast(folder)));
        const f = folder orelse return false;
        return pathIsJoin(own_path, std.mem.span(f), kf.rest);
    }

    const PromoteOutcome = union(enum) {
        promoted, // IsPromoted was absent: written as 1, icon re-added
        already_set: struct { kind: u32, value: u32 }, // the value exists: the user's choice, untouched
        not_found, // no subkey names this exe (yet)
        api_error: struct { where: []const u8, code: i32 },
    };

    /// One probe of HKCU\Control Panel\NotifyIconSettings for this process's exe: GetModuleFileNameW, compared
    /// with every subkey's ExecutablePath as UTF-16 under an ASCII case fold (eqlUtf16IgnoreAsciiCase).
    /// Ours + IsPromoted absent: write IsPromoted = 1 (REG_DWORD), then NIM_DELETE / NIM_ADD / NIM_SETVERSION so
    /// the shell applies the setting to this icon now rather than on the next run. Ours + IsPromoted present:
    /// hands off. pump logs the outcome. Buffers are the APIs' own bounds: a key name is at most 255 chars, a
    /// path at most 32767 UTF-16 units; both live on the stack for the length of this call only.
    fn promoteIcon(self: *WindowsTray) PromoteOutcome {
        var own: [32768]u16 = undefined;
        const own_n = GetModuleFileNameW(null, &own, own.len);
        if (own_n == 0 or own_n >= own.len) return .{ .api_error = .{ .where = "GetModuleFileNameW", .code = @bitCast(GetLastError()) } };
        const own_path = own[0..own_n];

        var root: HKEY = undefined;
        const open_root = RegOpenKeyExW(HKEY_CURRENT_USER, notify_icon_settings, 0, KEY_READ, &root);
        if (open_root == ERROR_FILE_NOT_FOUND) return .not_found;
        if (open_root != ERROR_SUCCESS) return .{ .api_error = .{ .where = "RegOpenKeyExW(NotifyIconSettings)", .code = open_root } };
        defer _ = RegCloseKey(root);

        var name: [256]u16 = undefined;
        var data: [32768]u16 = undefined;
        var index: u32 = 0;
        while (true) : (index += 1) {
            var name_len: u32 = name.len;
            const st = RegEnumKeyExW(root, index, &name, &name_len, null, null, null, null);
            if (st == ERROR_NO_MORE_ITEMS) return .not_found;
            if (st == ERROR_MORE_DATA) continue; // a name past the API's own limit: not one the shell wrote
            if (st != ERROR_SUCCESS) return .{ .api_error = .{ .where = "RegEnumKeyExW", .code = st } };
            if (name_len >= name.len) continue;
            name[name_len] = 0;
            const name_z: [*:0]const u16 = name[0..name_len :0];

            var sub: HKEY = undefined;
            if (RegOpenKeyExW(root, name_z, 0, KEY_READ, &sub) != ERROR_SUCCESS) continue;
            defer _ = RegCloseKey(sub);
            var kind: u32 = 0;
            var cb: u32 = @sizeOf(@TypeOf(data));
            if (RegQueryValueExW(sub, value_executable_path, null, &kind, @as([*]u8, @ptrCast(&data)), &cb) != ERROR_SUCCESS) continue;
            if (kind != REG_SZ) continue;
            if (!execPathIsOurs(regSz(&data, cb), own_path)) continue;

            // This subkey is ours. Present (0 or 1) is the user's Settings toggle; absent is never decided.
            var promoted: u32 = 0;
            kind = 0;
            cb = @sizeOf(u32);
            const q = RegQueryValueExW(sub, value_is_promoted, null, &kind, @as([*]u8, @ptrCast(&promoted)), &cb);
            if (q == ERROR_SUCCESS or q == ERROR_MORE_DATA) return .{ .already_set = .{ .kind = kind, .value = promoted } };
            if (q != ERROR_FILE_NOT_FOUND) return .{ .api_error = .{ .where = "RegQueryValueExW(IsPromoted)", .code = q } };

            var wsub: HKEY = undefined;
            const ow = RegOpenKeyExW(root, name_z, 0, KEY_SET_VALUE, &wsub);
            if (ow != ERROR_SUCCESS) return .{ .api_error = .{ .where = "RegOpenKeyExW(KEY_SET_VALUE)", .code = ow } };
            defer _ = RegCloseKey(wsub);
            const one: u32 = 1;
            const sw = RegSetValueExW(wsub, value_is_promoted, 0, REG_DWORD, @as([*]const u8, @ptrCast(&one)), @sizeOf(u32));
            if (sw != ERROR_SUCCESS) return .{ .api_error = .{ .where = "RegSetValueExW(IsPromoted)", .code = sw } };

            if (self.live) _ = Shell_NotifyIconW(NIM_DELETE, &self.nid);
            if (!self.addIcon() and g_err == ERROR_TIMEOUT) self.add_retry = Retry.arm(ADD_RETRY_TRIES, ADD_RETRY_GAP_MS, GetTickCount64());
            return .promoted;
        }
    }

    fn wndProc(hwnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
        if (msg == CALLBACK_MSG) {
            const ev: u32 = @intCast(@as(usize, @bitCast(lParam)) & 0xFFFF);
            if (ev == WM_LBUTTONDBLCLK or ev == WM_LBUTTONUP or ev == NIN_SELECT or ev == NIN_KEYSELECT) {
                g_restore = true;
                // The shell grants foreground rights to the icon's owner when it forwards the click.
                // Claiming them HERE is what lets the desk actually raise a frame later instead of just
                // flashing in the taskbar; worst case it is a no-op.
                _ = SetForegroundWindow(hwnd);
                return 0;
            }
            if (ev == WM_RBUTTONUP or ev == WM_CONTEXTMENU) {
                showContextMenu(hwnd);
                return 0;
            }
            return 0;
        }
        // The shell re-creates the notification area on an explorer.exe restart and every icon is dropped.
        // Cosmetic when the window was always visible; now it would leave a hidden desk reachable only
        // through Task Manager, so re-add on the broadcast. uFlags is restored first because setOnline and
        // notify overwrite it with NIF_TIP / NIF_INFO.
        if (g_taskbar_created != 0 and msg == g_taskbar_created) {
            if (g_self) |s| {
                s.nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
                s.live = Shell_NotifyIconW(NIM_ADD, &s.nid) != 0;
                g_add_ok = s.live;
                if (s.live) {
                    s.nid.uVersionOrTimeout = NOTIFYICON_VERSION_4;
                    _ = Shell_NotifyIconW(NIM_SETVERSION, &s.nid);
                }
            }
            return 0;
        }
        switch (msg) {
            // A polite close request aimed at this process — `taskkill /PID` without /F, a shutdown script,
            // an updater asking apps to close — arrives as WM_CLOSE on every top-level window. Ours is one.
            // DefWindowProcW would DESTROY the tray window, taking the icon with it and leaving a hidden
            // desk with no way back; and a hidden desk is exactly when this matters. Treat it as the quit
            // it plainly is.
            WM_CLOSE => {
                queueMenuAction(.quit);
                return 0;
            },
            // "May I end?" — not "I am ending". A session end can still be cancelled by another app, so
            // consent without acting; WM_ENDSESSION below is the one that commits.
            WM_QUERYENDSESSION => return 1,
            WM_ENDSESSION => {
                if (wParam != 0) queueMenuAction(.quit);
                return 0;
            },
            else => {},
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
};

// ------------------------------------------------------------------- pure helpers (every OS, unit-tested)

/// A bounded retry ticket for a chore that may need several tries: `limit` attempts, `gap_ms` apart, the first
/// one `gap_ms` after `arm`. The caller supplies the clock (ms, any monotonic origin), so the schedule is pure
/// and its tests run on every OS.
const Retry = struct {
    limit: u32,
    gap_ms: u64,
    tries: u32 = 0,
    not_before_ms: u64 = 0,

    fn arm(limit: u32, gap_ms: u64, now_ms: u64) Retry {
        return .{ .limit = limit, .gap_ms = gap_ms, .not_before_ms = now_ms +| gap_ms };
    }
    /// Another attempt is allowed at `now_ms`: tries remain and the gap since the last one has passed.
    fn due(r: Retry, now_ms: u64) bool {
        return r.tries < r.limit and now_ms >= r.not_before_ms;
    }
    /// An attempt at `now_ms` did not settle the chore; the next one waits a full gap from this attempt.
    fn spent(r: *Retry, now_ms: u64) void {
        r.tries += 1;
        r.not_before_ms = now_ms +| r.gap_ms;
    }
    fn exhausted(r: Retry) bool {
        return r.tries >= r.limit;
    }
};

/// `a` and `b` are the same UTF-16 string under an ASCII-only case fold (A-Z ~ a-z); every other code unit must
/// match exactly. That is enough for what it compares — two spellings of one exe path, GetModuleFileNameW's and
/// the shell's — without a Unicode case table.
fn eqlUtf16IgnoreAsciiCase(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x == y) continue;
        if (x < 0x80 and y < 0x80 and std.ascii.toLower(@intCast(x)) == std.ascii.toLower(@intCast(y))) continue;
        return false;
    }
    return true;
}

/// The string in a REG_SZ value's data: `bytes` of `buf` as RegQueryValueExW reports them (terminator included
/// when the writer stored one), clamped to the buffer, trailing NULs dropped, interior ones kept.
fn regSz(buf: []const u16, bytes: u32) []const u16 {
    var n: usize = @min(bytes / 2, buf.len);
    while (n > 0 and buf[n - 1] == 0) n -= 1;
    return buf[0..n];
}

/// The layout SHGetKnownFolderPath takes its folder id in.
const GUID = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };

/// A `{GUID}\rest` path (WindowsTray.execPathIsOurs says where the shell writes one): the GUID text without its
/// braces and the remainder after the separator, or null for any other shape.
fn splitKnownFolder(path: []const u16) ?struct { guid: []const u16, rest: []const u16 } {
    if (path.len < 39 or path[0] != '{' or path[37] != '}' or path[38] != '\\') return null;
    return .{ .guid = path[1..37], .rest = path[39..] };
}

/// "6D809377-6AF0-444B-8957-A3773F02200E" (36 UTF-16 units, hex in either case) as a GUID, or null when the
/// text is not one.
fn parseGuid(text: []const u16) ?GUID {
    if (text.len != 36) return null;
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (text, 0..) |u, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (u != '-') return null;
            continue;
        }
        if (u > 0x7F) return null;
        const c: u8 = @intCast(u);
        if (!std.ascii.isHex(c)) return null;
        hex[n] = c;
        n += 1;
    }
    const d1 = std.fmt.parseUnsigned(u32, hex[0..8], 16) catch return null;
    const d2 = std.fmt.parseUnsigned(u16, hex[8..12], 16) catch return null;
    const d3 = std.fmt.parseUnsigned(u16, hex[12..16], 16) catch return null;
    var d4: [8]u8 = undefined;
    for (0..8) |k| d4[k] = std.fmt.parseUnsigned(u8, hex[16 + 2 * k .. 18 + 2 * k], 16) catch return null;
    return .{ .data1 = d1, .data2 = d2, .data3 = d3, .data4 = d4 };
}

/// `own` is `folder` + '\' + `rest` under the ASCII case fold, without building the joined string. A folder
/// that already ends in '\' (a drive root) contributes no second separator.
fn pathIsJoin(own: []const u16, folder: []const u16, rest: []const u16) bool {
    const f = if (folder.len > 0 and folder[folder.len - 1] == '\\') folder[0 .. folder.len - 1] else folder;
    if (own.len != f.len + 1 + rest.len) return false;
    return eqlUtf16IgnoreAsciiCase(own[0..f.len], f) and own[f.len] == '\\' and eqlUtf16IgnoreAsciiCase(own[f.len + 1 ..], rest);
}

test "splitKnownFolder + parseGuid: the shell's {GUID}\\rest spelling, and nothing that merely resembles it" {
    @setEvalBranchQuota(20_000); // this many UTF-16 literals overrun the default comptime budget
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const kf = splitKnownFolder(L("{6D809377-6AF0-444B-8957-A3773F02200E}\\WindowsApps\\x\\app.exe")).?;
    try std.testing.expectEqualSlices(u16, L("6D809377-6AF0-444B-8957-A3773F02200E"), kf.guid);
    try std.testing.expectEqualSlices(u16, L("WindowsApps\\x\\app.exe"), kf.rest);
    try std.testing.expect(splitKnownFolder(L("C:\\Users\\garys\\veil.exe")) == null);
    try std.testing.expect(splitKnownFolder(L("{6D809377-6AF0-444B-8957-A3773F02200E}")) == null); // no separator
    try std.testing.expect(splitKnownFolder(L("{6D809377-6AF0-444B-8957-A3773F02200E}/x")) == null);
    try std.testing.expect(splitKnownFolder(L("{short}\\x")) == null);
    const empty_rest = splitKnownFolder(L("{6D809377-6AF0-444B-8957-A3773F02200E}\\")).?;
    try std.testing.expectEqual(@as(usize, 0), empty_rest.rest.len);

    const g = parseGuid(L("6D809377-6AF0-444B-8957-A3773F02200E")).?;
    try std.testing.expectEqual(@as(u32, 0x6D809377), g.data1);
    try std.testing.expectEqual(@as(u16, 0x6AF0), g.data2);
    try std.testing.expectEqual(@as(u16, 0x444B), g.data3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x57, 0xA3, 0x77, 0x3F, 0x02, 0x20, 0x0E }, &g.data4);
    const lower = parseGuid(L("6d809377-6af0-444b-8957-a3773f02200e")).?;
    try std.testing.expectEqual(g, lower);
    try std.testing.expect(parseGuid(L("6D809377-6AF0-444B-8957-A3773F02200")) == null); // 35 units
    try std.testing.expect(parseGuid(L("6D809377-6AF0-444B-8957-A3773F02200EF")) == null); // 37
    try std.testing.expect(parseGuid(L("6D809377_6AF0-444B-8957-A3773F02200E")) == null); // wrong separator
    try std.testing.expect(parseGuid(L("6D809377-6AF0-444B-8957-A3773F02200G")) == null); // not hex
    try std.testing.expect(parseGuid(L("6D809377-6AF0-444B-8957-A3773F0220ÖE")) == null); // not ASCII
    try std.testing.expect(parseGuid(L("{6D809377-6AF0-444B-8957-A3773F02200E")) == null); // brace left in
}

test "pathIsJoin: folder + '\\' + rest equals the own path under the ASCII fold; a root folder adds no separator" {
    @setEvalBranchQuota(20_000); // this many UTF-16 literals overrun the default comptime budget
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(pathIsJoin(L("C:\\Program Files\\WindowsApps\\x\\app.exe"), L("C:\\Program Files"), L("WindowsApps\\x\\app.exe")));
    try std.testing.expect(pathIsJoin(L("c:\\program files\\windowsapps\\X\\APP.EXE"), L("C:\\Program Files"), L("WindowsApps\\x\\app.exe")));
    try std.testing.expect(pathIsJoin(L("C:\\app.exe"), L("C:\\"), L("app.exe")));
    try std.testing.expect(pathIsJoin(L("C:\\app.exe"), L("C:"), L("app.exe")));
    try std.testing.expect(!pathIsJoin(L("C:\\Program Files (x86)\\x\\app.exe"), L("C:\\Program Files"), L("x\\app.exe")));
    try std.testing.expect(!pathIsJoin(L("C:\\Program Files\\x\\app.exe"), L("C:\\Program Files"), L("x\\app.exe\\")));
    try std.testing.expect(!pathIsJoin(L("C:\\Program Filesx\\app.exe"), L("C:\\Program Files"), L("app.exe"))); // the separator must be there
    try std.testing.expect(!pathIsJoin(L("D:\\Program Files\\app.exe"), L("C:\\Program Files"), L("app.exe")));
    try std.testing.expect(!pathIsJoin(L("C:\\Program Files\\app.exe"), L("C:\\Program Files"), L("")));
    try std.testing.expect(!pathIsJoin(L(""), L(""), L("")));
}

test "Retry: first attempt waits one gap, each later one another gap, and the limit ends it" {
    var r = Retry.arm(3, 500, 10_000);
    try std.testing.expect(!r.due(10_000));
    try std.testing.expect(!r.due(10_499));
    try std.testing.expect(r.due(10_500));
    r.spent(10_500);
    try std.testing.expect(!r.exhausted());
    try std.testing.expect(!r.due(10_900));
    try std.testing.expect(r.due(11_000));
    r.spent(11_300); // a late frame: the next gap counts from the attempt, not from the schedule
    try std.testing.expect(!r.due(11_799));
    try std.testing.expect(r.due(11_800));
    r.spent(11_800);
    try std.testing.expect(r.exhausted());
    try std.testing.expect(!r.due(99_999_999)); // never again, however long the process lives
    try std.testing.expectEqual(@as(u32, 3), r.tries);
    // the clock may sit near its ceiling: arming and spending saturate instead of wrapping
    var top = Retry.arm(1, 1_000, std.math.maxInt(u64) - 10);
    try std.testing.expect(!top.due(std.math.maxInt(u64) - 10));
    try std.testing.expect(top.due(std.math.maxInt(u64)));
    top.spent(std.math.maxInt(u64));
    try std.testing.expect(top.exhausted());
}

test "pump: a tray whose window never came up is a per-frame no-op, and stays un-hideable" {
    // On Windows this also analyzes the whole chore path (pump -> addIcon / promoteIcon), so the advapi32 and
    // kernel32 externs must resolve for the test binary to link; none of them is called (hwnd is null).
    var t: Tray = .{};
    t.pump();
    t.pump();
    try std.testing.expect(!t.inited);
    try std.testing.expect(!t.canHide());
}

test "eqlUtf16IgnoreAsciiCase: ASCII case folds, everything else is exact, length counts" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(eqlUtf16IgnoreAsciiCase(L("C:\\Users\\x\\veil.exe"), L("c:\\users\\X\\VEIL.EXE")));
    try std.testing.expect(eqlUtf16IgnoreAsciiCase(L("C:\\veil.exe"), L("C:\\veil.exe")));
    try std.testing.expect(!eqlUtf16IgnoreAsciiCase(L("C:\\veil.exe"), L("C:\\veil.exe ")));
    try std.testing.expect(!eqlUtf16IgnoreAsciiCase(L("C:\\veil.exe"), L("C:\\veil.ex")));
    try std.testing.expect(!eqlUtf16IgnoreAsciiCase(L("C:\\vei1.exe"), L("C:\\veil.exe")));
    try std.testing.expect(!eqlUtf16IgnoreAsciiCase(L("C:\\veil.exe"), L("C:/veil.exe"))); // no separator folding either
    try std.testing.expect(eqlUtf16IgnoreAsciiCase(L("C:\\Ünïcode\\veil.exe"), L("c:\\Ünïcode\\VEIL.exe")));
    try std.testing.expect(!eqlUtf16IgnoreAsciiCase(L("C:\\Ünïcode\\veil.exe"), L("C:\\ünïcode\\veil.exe"))); // no Unicode fold
    try std.testing.expect(eqlUtf16IgnoreAsciiCase(&[_]u16{}, &[_]u16{}));
    try std.testing.expect(!eqlUtf16IgnoreAsciiCase(&[_]u16{}, L("a")));
}

test "regSz: REG_SZ data is clamped to the buffer and loses its terminator(s), not interior NULs" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [8]u16 = .{ 'v', 'e', 'i', 'l', 0, 0, 'x', 'y' };
    try std.testing.expectEqualSlices(u16, L("veil"), regSz(&buf, 10)); // 4 chars + one NUL
    try std.testing.expectEqualSlices(u16, L("veil"), regSz(&buf, 12)); // two NULs
    try std.testing.expectEqualSlices(u16, L("vei"), regSz(&buf, 7)); // odd byte count: the half unit is dropped
    try std.testing.expectEqualSlices(u16, L("veil"), regSz(&buf, 8)); // no terminator stored
    try std.testing.expectEqualSlices(u16, &buf, regSz(&buf, 1_000)); // claims more than the buffer: clamped
    try std.testing.expectEqualSlices(u16, &[_]u16{}, regSz(&buf, 0));
    try std.testing.expectEqualSlices(u16, &[_]u16{}, regSz(&[_]u16{}, 4));
    buf = .{ 'a', 0, 'b', 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u16, &[_]u16{ 'a', 0, 'b' }, regSz(&buf, 16)); // interior NUL kept
}

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
    fn takeRestoreRequest(self: *PosixTray) bool {
        _ = self;
        return false;
    }
    fn takeMenuAction(self: *PosixTray) MenuAction {
        _ = self;
        return .none;
    }
    fn pump(self: *PosixTray) bool {
        _ = self;
        return false;
    }
};
