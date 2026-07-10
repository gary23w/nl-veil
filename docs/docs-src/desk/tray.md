# tray

**File:** `desk/src/tray.zig`  
**Module:** `desk`  
**Description:** Cross-platform system-tray presence and native notification surface for the veil-desk raylib desktop app, with a fully implemented Win32 Shell_NotifyIcon backend and no-op stubs elsewhere.

---

## Purpose Summary

Gives veil-desk a real OS tray icon (with tooltip, right-click context menu, and Windows balloon toasts) plus the plumbing to route tray clicks back into the UI loop. On Windows it owns a live Shell_NotifyIcon anchored to a hidden window; on Linux/macOS it degrades to inert stubs, leaving the always-present in-app toast (drawn elsewhere by the UI) as the cross-platform notification floor.

## Key Exports

- `Tray` — public facade struct; compile-time-selects `WindowsTray` or `PosixTray` as its `impl` and forwards all calls
- `Tray.MenuAction` — enum { none, open_settings, toggle_notifications, refresh_now, quit } surfaced by the context menu
- `Tray.init(title)` / `deinit()` — create/tear down the tray; `inited` reflects whether the backend init succeeded (on Windows, whether the Shell_NotifyIcon NIM_ADD landed)
- `Tray.setOnline(online)` — swap the tooltip to 'veil-desk — server ONLINE'/'veil-desk — server offline'; dedupes on no-change
- `Tray.setNotifyEnabled(enabled)` — mirror the user's notify toggle into the menu checkmark; dedupes to avoid per-frame log flood
- `Tray.notify(gpa, title, body, accent)` — raise a balloon toast (accent==2 → warning icon, else info)
- `Tray.pump()` — drain the tray window's Win32 message queue once per UI frame
- `Tray.takeRestoreRequest()` — one-shot: true if the user left-clicked or double-clicked the tray icon (or picked Open) to restore the window
- `Tray.takeMenuAction()` — one-shot: pop the queued context-menu MenuAction
- `Tray.diag()` -> `Tray.Diag{reg,hwnd,add,err}` — expose captured init diagnostics for troubleshooting an invisible icon

## Dependencies

- std
- builtin (os.tag drives the compile-time Impl selection)
- raylib (rl) — rl.Image loading/resize/format for the PNG-to-HICON path
- log.zig — trace/info/warn logging
- Win32 externs: shell32 (Shell_NotifyIconW), user32 (window class/message/menu/icon APIs), gdi32 (CreateDIBSection/CreateBitmap/DeleteObject), kernel32 (GetModuleHandleW/GetLastError)

## Usage Context

Instantiated once by the veil-desk main app: init(title) at startup, then every UI frame the loop calls pump() to service tray messages, setNotifyEnabled(current_setting), and polls takeRestoreRequest()/takeMenuAction() to react (restore window, open settings, toggle notifications, refresh, quit). setOnline() is driven by the app's server-connection status and notify() by app events; deinit() at shutdown removes the icon. No direct server or neuron-db calls live here — it is a pure OS-integration seam consuming state the app hands it.

## Notable Implementation Details

Single-threaded despite looking event-driven: the Win32 WndProc runs on the main thread inside pump(), and because the callback has a fixed C signature with no user pointer, it communicates back through module-level globals — g_restore, g_menu_action (first-write-wins via queueMenuAction), and g_self (so the menu can read notify_enabled for its checkmark). g_reg/g_hwnd_ok/g_add_ok/g_err capture init ground-truth for diag(). Two one-shot 'take' flags (restore, menu action) are drained by the UI each frame; note g_restore is set on both WM_LBUTTONUP and WM_LBUTTONDBLCLK, so a single left-click (not only a double-click) restores. The load-bearing v1 fix documented in the header: the icon must be anchored to a REAL overlapped window (WS_OVERLAPPEDWINDOW) created then hidden with SW_HIDE — v1 anchored to GetConsoleWindow, which is null under the GUI subsystem, so no icon ever appeared. NIM_SETVERSION to NOTIFYICON_VERSION_4 is required or callback/balloon semantics vary and the icon misbehaves on Win10/11; with v4 the click event id lives in the low word of lParam. Fixed buffers throughout: NOTIFYICONDATAW's szTip[128]/szInfo[256]/szInfoTitle[64] u16 arrays, filled by utf16z() which UTF-8→UTF-16LE-converts with safe truncation and guaranteed null-termination. imageToHicon() builds the icon by hand — CreateDIBSection top-down 32bpp, premultiplies alpha (Windows icons require it), and needs a 1bpp AND mask sized into a fixed [512]u8 stack buffer that bounds the icon (returns null if (px_count+7)/8 exceeds it; the 32x32 resize needs 128 bytes, well within). loadIconFromPng tries four relative candidate paths for assets/icon.png and returns null on failure; init() then falls back to the system IDI_APPLICATION icon. Gotchas: notify()'s gpa allocator param is accepted for signature symmetry but unused (discarded); accent is a magic scalar where only ==2 means warning; setOnline() and notify() early-return when the icon isn't live (self.live false), but setNotifyEnabled() has no such guard and unconditionally records the flag (later read at menu-draw time via g_self). PosixTray is every method as a parameter-discarding no-op, with init() returning true so callers still treat the tray as 'present'.

---

*Documentation generated for nl-veil — desk/tray.zig source analysis.*
