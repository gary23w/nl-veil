//! veil-desk — the native desktop dashboard for nl-veil. A borderless (own-chrome) window with five tabs
//! (Dashboard / Deploy / Swarm / Hub / Settings) styled in the web UI's Tokyo Night palette. Same-machine
//! companion: a background poller thread owns io and reads the run directories directly, while this (main)
//! thread runs raylib and draws the Store. Deploy with the full swarm config, chat/monitor/stop a swarm,
//! watch the live event console + metrics, connect hives from the Hub tab.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const t = @import("theme.zig");
const store_mod = @import("store.zig");
const scan = @import("scan.zig");
const poller_mod = @import("poller.zig");
const tray_mod = @import("tray.zig");
const catalog = @import("catalog.zig");

const Store = store_mod.Store;
const Tab = store_mod.Tab;

// This Zig's Windows net layer maps a refused localhost connection to error.Unexpected, which we handle
// (server offline); silence the diagnostic trace so the 1Hz liveness probe doesn't spam stderr.
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

const WIN_W = 1220;
const WIN_H = 820;
const TITLE_H = 30;
const TAB_H = 34;

const InnerTab = enum { console, details };

/// UI-thread-only interaction state (the Store holds the machine's state; this holds the cursor's).
const Ui = struct {
    tab: Tab = .dashboard,
    inner: InnerTab = .console,
    focus: Focus = .none,
    chat: Field = .{},
    // deploy form
    d_name: Field = .{},
    d_key: Field = .{},
    d_goal: Field = .{},
    d_gateway: Field = .{},
    d_provider: usize = 0,
    d_model: usize = 0,
    d_minds: i32 = 3,
    d_minutes: usize = 3, // index into catalog.minutes
    d_style: usize = 0,
    d_stack: usize = 0,
    d_mode: usize = 0,
    d_population: bool = false,
    d_encrypt: bool = false,
    // window chrome
    dragging: bool = false,
    resizing: bool = false,
    file_menu: bool = false,
    close_req: bool = false,
    // log console
    log_scroll: f32 = 0,
    log_follow: bool = true,

    const Focus = enum { none, chat, d_name, d_key, d_goal, d_gateway };
    const Field = struct {
        buf: [1200]u8 = [_]u8{0} ** 1200,
        len: usize = 0,
        fn str(f: *const Field) []const u8 {
            return f.buf[0..f.len];
        }
    };
};

var ui: Ui = .{};

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = Store{};
    seedSettings(&store, io);
    ui.d_name.len = seedName(&ui.d_name.buf);

    var poller = poller_mod.Poller{ .io = io, .gpa = gpa, .store = &store };
    const th = try std.Thread.spawn(.{}, poller_mod.Poller.run, .{&poller});
    defer {
        poller.stop.store(true, .monotonic);
        th.join();
    }

    // Borderless: we draw our own title bar (drag / File / minimize / close). Resizable stays on so the
    // grip in the corner can drive setWindowSize. No MSAA/vsync — this is a 2D UI, and MSAA + a pinned
    // 60fps kept the GPU hot with nothing happening; we cap FPS ourselves (30 focused / 8 idle) below.
    rl.setConfigFlags(.{ .window_resizable = true, .window_undecorated = true });
    rl.setTraceLogLevel(.warning);
    rl.initWindow(WIN_W, WIN_H, "veil-desk");
    defer rl.closeWindow();
    rl.setTargetFPS(30);

    // Real TTFs replace raylib's blocky default: a proportional UI font + a monospace console font. Load
    // at a crisp base size and bilinear-filter so they scale smoothly.
    if (loadFontAt(uiCandidates(), 32)) |f| {
        rl.setTextureFilter(f.texture, .bilinear);
        t.setFont(f);
    }
    if (loadFontAt(monoCandidates(), 30)) |f| {
        rl.setTextureFilter(f.texture, .bilinear);
        t.setMono(f);
    }
    // Window + taskbar icon: the shadow-figure mark rendered into an image.
    const icon = makeIcon();
    rl.setWindowIcon(icon);

    var tray: tray_mod.Tray = .{};
    tray.init("veil-desk");
    defer tray.deinit();

    var auto_selected = false;
    while (!rl.windowShouldClose() and !ui.close_req) {
        // Heat control: 30fps when focused, 8fps when the window is in the background. A 2D dashboard has
        // no reason to redraw 60x/sec, and a pinned high FPS is what warmed the machine with no swarms.
        rl.setTargetFPS(if (rl.isWindowFocused()) 30 else 8);
        tray.pump();
        pumpTray(&store, &tray, gpa);
        if (!auto_selected) auto_selected = autoSelect(&store);
        handleWindowChrome();
        handleKeys();

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(t.bg);

        drawTitlebar(&store);
        drawTabbar(&store);
        const top = TITLE_H + TAB_H;
        const body = t.Rect{ .x = 0, .y = top, .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight() - top) };
        switch (ui.tab) {
            .dashboard => drawDashboard(&store, body),
            .deploy => drawDeploy(&store, body),
            .swarm => drawSwarm(&store, body),
            .hub => drawHub(body),
            .settings => drawSettings(&store, body),
        }
        drawResizeGrip();
        if (ui.file_menu) drawFileMenu(&store);
        drawToasts(&store);
    }
}

// -------------------------------------------------------------------------------- window chrome

fn handleWindowChrome() void {
    const mp = rl.getMousePosition();
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    // resize grip (bottom-right 18px)
    const grip = t.Rect{ .x = sw - 18, .y = @as(f32, @floatFromInt(rl.getScreenHeight())) - 18, .width = 18, .height = 18 };
    if (rl.isMouseButtonPressed(.left) and rl.checkCollisionPointRec(mp, grip)) ui.resizing = true;
    if (ui.resizing) {
        if (rl.isMouseButtonDown(.left)) {
            const d = rl.getMouseDelta();
            const nw = @max(760, rl.getScreenWidth() + @as(i32, @intFromFloat(d.x)));
            const nh = @max(520, rl.getScreenHeight() + @as(i32, @intFromFloat(d.y)));
            rl.setWindowSize(nw, nh);
        } else ui.resizing = false;
    }
    // title-bar drag (empty zone only: not over the window buttons or the File hit-box)
    const in_title = mp.y >= 0 and mp.y < TITLE_H and mp.x < sw - 96 and !(mp.x > 40 and mp.x < 90);
    if (rl.isMouseButtonPressed(.left) and in_title and !ui.resizing) ui.dragging = true;
    if (ui.dragging) {
        if (rl.isMouseButtonDown(.left)) {
            const d = rl.getMouseDelta();
            const p = rl.getWindowPosition();
            rl.setWindowPosition(@intFromFloat(p.x + d.x), @intFromFloat(p.y + d.y));
        } else ui.dragging = false;
    }
}

fn drawTitlebar(store: *Store) void {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    t.fillRect(0, 0, @intFromFloat(sw), TITLE_H, t.bg_dark);
    t.hline(0, TITLE_H - 1, @intFromFloat(sw), t.border);
    // mark + wordmark (just "veil")
    t.drawMark(16, TITLE_H / 2, 9, false);
    t.text(t.z("veil", .{}), 30, 8, 15, t.fg);
    // File menu button
    const fr = t.Rect{ .x = 68, .y = 3, .width = 42, .height = TITLE_H - 6 };
    if (t.hovering(fr) or ui.file_menu) t.panel(fr, t.bg_hl);
    t.text(t.z("File", .{}), 76, 8, 13, t.fg_dim);
    if (t.hovering(fr) and rl.isMouseButtonPressed(.left)) ui.file_menu = !ui.file_menu;

    // right: server status + minimize + close
    store.lock();
    const online = store.server_online;
    const minds = store.fleet_minds;
    store.unlock();
    const label = if (online) t.z("online   {d} minds", .{minds}) else t.z("offline", .{});
    const lw = t.measure(label, 12);
    const lx = sw - @as(f32, @floatFromInt(lw)) - 108;
    t.statusDot(@intFromFloat(lx - 11), 15, if (online) t.green else t.comment);
    t.text(label, @intFromFloat(lx), 9, 12, if (online) t.green else t.comment);

    const minb = t.Rect{ .x = sw - 92, .y = 0, .width = 46, .height = TITLE_H };
    const clsb = t.Rect{ .x = sw - 46, .y = 0, .width = 46, .height = TITLE_H };
    if (t.winButton(minb, t.z("_", .{}), false)) rl.minimizeWindow();
    if (t.winButton(clsb, t.z("x", .{}), true)) ui.close_req = true;
}

fn drawFileMenu(store: *Store) void {
    const items = [_][:0]const u8{ t.z("New swarm", .{}), t.z("Refresh now", .{}), t.z("Open data folder", .{}), t.z("Quit", .{}) };
    const w: f32 = 180;
    const ih: f32 = 30;
    const r = t.Rect{ .x = 68, .y = TITLE_H, .width = w, .height = ih * items.len + 8 };
    t.panelBordered(r, t.bg_dark, t.border);
    // click-away closes
    if (rl.isMouseButtonPressed(.left) and !t.hovering(r) and !t.hovering(.{ .x = 68, .y = 3, .width = 42, .height = TITLE_H - 6 })) ui.file_menu = false;
    var yy = r.y + 4;
    for (items, 0..) |it, i| {
        const ir = t.Rect{ .x = r.x + 4, .y = yy, .width = w - 8, .height = ih };
        const hot = t.hovering(ir);
        if (hot) t.panel(ir, t.bg_hl);
        t.text(it, @intFromFloat(ir.x + 10), @intFromFloat(ir.y + 8), 13, if (i == 3) t.red else t.fg);
        if (hot and rl.isMouseButtonPressed(.left)) {
            ui.file_menu = false;
            switch (i) {
                0 => ui.tab = .deploy,
                1 => store.pushCmd(store_mod.mkCmd(.refresh_now, "", "")),
                2 => openDataFolder(store),
                3 => ui.close_req = true,
                else => {},
            }
        }
        yy += ih;
    }
}

fn openDataFolder(store: *Store) void {
    // v2 stub: opening a file browser needs a process spawn (explorer/open/xdg-open) which belongs on the
    // poller's io thread; wire a command for it next. For now the path is visible in Settings.
    _ = store;
}

fn drawResizeGrip() void {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());
    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        const o: f32 = @floatFromInt(4 + i * 4);
        rl.drawLineEx(.{ .x = sw - o, .y = sh - 4 }, .{ .x = sw - 4, .y = sh - o }, 1.0, t.comment);
    }
}

// -------------------------------------------------------------------------------- setup

// ASCII (32..126) plus the punctuation that shows up in swarm GOAL text (en/em dash, curly quotes,
// ellipsis, arrow, bullet, middle dot). Without these, non-ASCII bytes in the run data render as tofu.
const glyph_set = blk: {
    const extra = [_]i32{ 0x00B7, 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x2192, 0x25CF, 0x25CB, 0x2022 };
    var arr: [95 + extra.len]i32 = undefined;
    var i: usize = 0;
    var c: i32 = 32;
    while (c <= 126) : (c += 1) {
        arr[i] = c;
        i += 1;
    }
    for (extra) |e| {
        arr[i] = e;
        i += 1;
    }
    break :blk arr;
};

fn uiCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/tahoma.ttf", "C:/Windows/Fonts/arial.ttf" },
        .macos => &.{ "/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc", "/Library/Fonts/Arial.ttf" },
        else => &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/liberation/LiberationSans-Regular.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf" },
    };
}
fn monoCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/lucon.ttf", "C:/Windows/Fonts/cour.ttf" },
        .macos => &.{ "/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Courier.ttc" },
        else => &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/liberation/LiberationMono-Regular.ttf" },
    };
}
fn loadFontAt(candidates: []const [:0]const u8, size: i32) ?rl.Font {
    for (candidates) |path| {
        if (rl.loadFontEx(path, size, glyph_set[0..])) |f| {
            if (f.glyphCount > 0) return f;
        } else |_| {}
    }
    return null;
}

fn makeIcon() rl.Image {
    var img = rl.genImageColor(64, 64, .{ .r = 0x1a, .g = 0x1b, .b = 0x26, .a = 255 });
    // hooded head + cloak in magenta, a dark face void — the shadow-figure mark.
    rl.imageDrawCircle(&img, 32, 22, 12, .{ .r = 0xbb, .g = 0x9a, .b = 0xf7, .a = 255 });
    rl.imageDrawRectangle(&img, 14, 30, 36, 28, .{ .r = 0xbb, .g = 0x9a, .b = 0xf7, .a = 255 });
    rl.imageDrawCircle(&img, 32, 22, 6, .{ .r = 0x16, .g = 0x16, .b = 0x1e, .a = 255 });
    return img;
}

fn seedName(buf: []u8) usize {
    const s = "swarm";
    @memcpy(buf[0..s.len], s);
    return s.len;
}

fn seedSettings(store: *Store, io: std.Io) void {
    const candidates = [_][]const u8{ "data", "../data", "../../data", "../nl-veil/data" };
    for (candidates) |c| {
        if (dirExists(io, c)) {
            setDataDir(store, c);
            return;
        }
    }
    setDataDir(store, "data");
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn setDataDir(store: *Store, dd: []const u8) void {
    store.lock();
    defer store.unlock();
    const n = @min(dd.len, store.settings.data_dir.len);
    @memcpy(store.settings.data_dir[0..n], dd[0..n]);
    store.settings.data_dir_len = @intCast(n);
}

fn autoSelect(store: *Store) bool {
    store.lock();
    const have = store.swarm_count > 0;
    var id: [64]u8 = undefined;
    var idn: usize = 0;
    if (have and store.selected_len == 0) {
        idn = store.swarms[0].id_len;
        @memcpy(id[0..idn], store.swarms[0].id[0..idn]);
    }
    store.unlock();
    if (have and idn > 0) {
        store.pushCmd(store_mod.mkCmd(.select, id[0..idn], ""));
        return true;
    }
    return have;
}

// -------------------------------------------------------------------------------- tray pump

fn pumpTray(store: *Store, tray: *tray_mod.Tray, gpa: std.mem.Allocator) void {
    store.lock();
    tray.setOnline(store.server_online);
    const notify_on = store.settings.notify;
    var to_send: [8]store_mod.Notif = undefined;
    var send_n: usize = 0;
    var i: usize = 0;
    while (i < store.notif_count) : (i += 1) {
        const idx = (store.notif_head + i) % store.notifs.len;
        if (store.notifs[idx].fresh) {
            store.notifs[idx].fresh = false;
            if (send_n < to_send.len) {
                to_send[send_n] = store.notifs[idx];
                send_n += 1;
            }
        }
    }
    store.unlock();
    if (tray.takeRestoreRequest()) rl.restoreWindow();
    if (!notify_on) return;
    var k: usize = 0;
    while (k < send_n) : (k += 1) tray.notify(gpa, to_send[k].titleStr(), to_send[k].bodyStr(), to_send[k].accent);
}

// -------------------------------------------------------------------------------- input

fn handleKeys() void {
    if (ui.focus == .none) {
        if (rl.isKeyPressed(.one)) ui.tab = .dashboard;
        if (rl.isKeyPressed(.two)) ui.tab = .deploy;
        if (rl.isKeyPressed(.three)) ui.tab = .swarm;
        if (rl.isKeyPressed(.four)) ui.tab = .hub;
        if (rl.isKeyPressed(.five)) ui.tab = .settings;
    }
    switch (ui.focus) {
        .none => {},
        .chat => editField(&ui.chat),
        .d_name => editField(&ui.d_name),
        .d_key => editField(&ui.d_key),
        .d_goal => editField(&ui.d_goal),
        .d_gateway => editField(&ui.d_gateway),
    }
    if (rl.isKeyPressed(.escape)) {
        ui.focus = .none;
        ui.file_menu = false;
    }
}

fn editField(f: *Ui.Field) void {
    var c = rl.getCharPressed();
    while (c > 0) : (c = rl.getCharPressed()) {
        if (c >= 32 and c < 127 and f.len < f.buf.len - 1) {
            f.buf[f.len] = @intCast(c);
            f.len += 1;
        }
    }
    if ((rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace)) and f.len > 0) f.len -= 1;
}

// -------------------------------------------------------------------------------- tab bar

fn drawTabbar(store: *Store) void {
    _ = store;
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    t.fillRect(0, TITLE_H, @intFromFloat(sw), TAB_H, t.bg_dark);
    t.hline(0, TITLE_H + TAB_H - 1, @intFromFloat(sw), t.border);
    const labels = [_][:0]const u8{ t.z("Dashboard", .{}), t.z("Deploy", .{}), t.z("Swarm", .{}), t.z("Hub", .{}), t.z("Settings", .{}) };
    const tabs = [_]Tab{ .dashboard, .deploy, .swarm, .hub, .settings };
    var x: f32 = 12;
    for (labels, tabs) |lb, tabv| {
        const w: f32 = @floatFromInt(t.measure(lb, 13) + 26);
        const r = t.Rect{ .x = x, .y = TITLE_H + 4, .width = w, .height = TAB_H - 6 };
        if (t.tab(r, lb, ui.tab == tabv)) {
            ui.tab = tabv;
            ui.focus = .none;
        }
        x += w + 4;
    }
}

// -------------------------------------------------------------------------------- dashboard

fn drawDashboard(store: *Store, body: t.Rect) void {
    const pad: f32 = 16;
    var y: f32 = body.y + pad;
    const x: f32 = pad;
    const colw: f32 = body.width - pad * 2;
    t.text(t.z("Dashboard", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
    y += 34;

    store.lock();
    const online = store.server_online;
    const fl = store.fleet_live;
    const fm = store.fleet_minds;
    const fh = store.fleet_headroom;
    const sc = store.swarm_count;
    store.unlock();

    const card_w = (colw - 30) / 4;
    statCard(x + 0 * (card_w + 10), y, card_w, "SERVER", if (online) "online" else "offline", if (online) t.green else t.red);
    statCard(x + 1 * (card_w + 10), y, card_w, "LIVE SWARMS", t.z("{d}", .{fl}), t.cyan);
    statCard(x + 2 * (card_w + 10), y, card_w, "LIVE MINDS", t.z("{d}", .{fm}), t.magenta);
    statCard(x + 3 * (card_w + 10), y, card_w, "HEADROOM", t.z("{d}", .{fh}), if (fh > 0) t.green else t.orange);
    y += 102;

    const nb = t.Rect{ .x = x, .y = y, .width = 150, .height = 34 };
    if (t.button(nb, t.z("+ New swarm", .{}), t.blue, true)) ui.tab = .deploy;
    t.text(t.z("Swarms ({d})", .{sc}), @intFromFloat(x + 166), @intFromFloat(y + 9), 14, t.fg_dim);
    y += 46;
    const list_r = t.Rect{ .x = x, .y = y, .width = colw, .height = body.y + body.height - y - pad };
    drawRoster(store, list_r);
}

fn statCard(x: f32, y: f32, w: f32, label: [:0]const u8, value: [:0]const u8, accent: t.Color) void {
    const r = t.Rect{ .x = x, .y = y, .width = w, .height = 88 };
    t.panelBordered(r, t.bg_dark, t.border);
    t.text(label, @intFromFloat(x + 14), @intFromFloat(y + 14), 12, t.comment);
    t.text(value, @intFromFloat(x + 14), @intFromFloat(y + 40), 26, accent);
}

fn drawRoster(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    rl.beginScissorMode(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.width), @intFromFloat(r.height));
    defer rl.endScissorMode();
    store.lock();
    const n = store.swarm_count;
    var rows: [scan.MAX_SWARMS]scan.SwarmSummary = undefined;
    @memcpy(rows[0..n], store.swarms[0..n]);
    var sel: [64]u8 = undefined;
    const sel_n = store.selected_len;
    @memcpy(sel[0..sel_n], store.selected[0..sel_n]);
    const scanned = store.last_refresh_s > 0; // has the poller completed its first pass?
    store.unlock();

    const row_h: f32 = 46;
    var yy: f32 = r.y + 6;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const sw = &rows[idx];
        const rr = t.Rect{ .x = r.x + 6, .y = yy, .width = r.width - 12, .height = row_h - 6 };
        const is_sel = std.mem.eql(u8, sw.idStr(), sel[0..sel_n]);
        const hot = t.hovering(rr);
        if (is_sel) t.panel(rr, t.bg_sel) else if (hot) t.panel(rr, t.bg_hl);
        t.statusDot(@intFromFloat(rr.x + 12), @intFromFloat(rr.y + rr.height / 2), if (sw.live) t.green else if (sw.stopped) t.comment else t.yellow);
        t.textClip(sw.nameStr(), @intFromFloat(rr.x + 26), @intFromFloat(rr.y + 6), 13, t.fg, @intFromFloat(rr.width - 220));
        if (sw.goal_len > 0) t.textClip(sw.goalStr(), @intFromFloat(rr.x + 26), @intFromFloat(rr.y + 23), 11, t.comment, @intFromFloat(rr.width - 220));
        const pct = sw.pct;
        const rt = if (pct >= 0) t.z("r{d}  {d}%", .{ sw.round, pct }) else t.z("r{d}", .{sw.round});
        const rtw = t.measure(rt, 12);
        const pc = if (pct >= 100) t.green else if (pct >= 50) t.cyan else if (pct >= 0) t.yellow else t.comment;
        t.text(rt, @intFromFloat(rr.x + rr.width - @as(f32, @floatFromInt(rtw)) - 12), @intFromFloat(rr.y + 6), 12, pc);
        const stt = if (sw.stopped) t.z("done", .{}) else if (sw.live) t.z("live", .{}) else t.z("idle", .{});
        t.text(stt, @intFromFloat(rr.x + rr.width - @as(f32, @floatFromInt(t.measure(stt, 11))) - 12), @intFromFloat(rr.y + 24), 11, if (sw.live) t.green else t.comment);
        if (hot and rl.isMouseButtonPressed(.left)) {
            store.pushCmd(store_mod.mkCmd(.select, sw.idStr(), ""));
            ui.tab = .swarm;
        }
        yy += row_h;
        if (yy > r.y + r.height) break;
    }
    if (n == 0) {
        const msg = if (scanned) t.z("no swarms yet - Deploy one", .{}) else t.z("scanning run directories...", .{});
        t.text(msg, @intFromFloat(r.x + 14), @intFromFloat(r.y + 14), 13, t.comment);
    }
}

// -------------------------------------------------------------------------------- deploy form

fn drawDeploy(store: *Store, body: t.Rect) void {
    const pad: f32 = 16;
    const x: f32 = pad;
    const colw = @min(body.width - pad * 2, 900);
    var y: f32 = body.y + pad;
    t.text(t.z("Deploy a swarm", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
    t.text(t.z("full configuration - the same knobs as the web console", .{}), @intFromFloat(x + 200), @intFromFloat(y + 6), 12, t.comment);
    y += 36;

    const prov = &catalog.providers[ui.d_provider];
    if (ui.d_model >= prov.models.len) ui.d_model = 0;

    // two columns
    const cw = (colw - 16) / 2;
    const rx = x + cw + 16;
    var ly = y;
    var ry = y;
    const fh: f32 = 46;
    const gap: f32 = 10;

    // left column: identity + endpoint
    flabel(x, ly, "NAME");
    textField(.{ .x = x, .y = ly + 14, .width = cw, .height = 32 }, &ui.d_name, ui.focus == .d_name, "swarm name", .d_name);
    ly += fh + 14 + gap - 14;

    const pv = t.cycle(.{ .x = x, .y = ly, .width = cw, .height = fh }, t.z("PROVIDER", .{}), t.zs(prov.label), false);
    if (pv != 0) {
        ui.d_provider = wrap(ui.d_provider, pv, catalog.providers.len);
        ui.d_model = 0;
    }
    ly += fh + gap;

    const mv = t.cycle(.{ .x = x, .y = ly, .width = cw, .height = fh }, t.z("MODEL", .{}), t.zs(prov.models[ui.d_model].label), false);
    if (mv != 0) ui.d_model = wrap(ui.d_model, mv, prov.models.len);
    ly += fh + gap;

    if (prov.needs_key) {
        flabel(x, ly, "API KEY (nlk_... or provider key)");
        textField(.{ .x = x, .y = ly + 14, .width = cw, .height = 32 }, &ui.d_key, ui.focus == .d_key, "sk-... / nlk_...", .d_key);
        ly += fh + 14 + gap - 14;
    }

    // right column: knobs
    ui.d_minds = t.stepper(.{ .x = rx, .y = ry, .width = cw, .height = fh }, t.z("MINDS", .{}), ui.d_minds, 1, 5);
    ry += fh + gap;
    const sv = t.cycle(.{ .x = rx, .y = ry, .width = cw, .height = fh }, t.z("STYLE", .{}), t.zs(catalog.styles[ui.d_style]), false);
    if (sv != 0) ui.d_style = wrap(ui.d_style, sv, catalog.styles.len);
    ry += fh + gap;
    const tv = t.cycle(.{ .x = rx, .y = ry, .width = cw, .height = fh }, t.z("RUNTIME (min, 0=until stopped)", .{}), t.zs(catalog.minutes_lbl[ui.d_minutes]), false);
    if (tv != 0) ui.d_minutes = wrap(ui.d_minutes, tv, catalog.minutes.len);
    ry += fh + gap;
    const kv = t.cycle(.{ .x = rx, .y = ry, .width = cw / 2 - 5, .height = fh }, t.z("STACK", .{}), t.zs(catalog.stacks[ui.d_stack]), false);
    if (kv != 0) ui.d_stack = wrap(ui.d_stack, kv, catalog.stacks.len);
    const ov = t.cycle(.{ .x = rx + cw / 2 + 5, .y = ry, .width = cw / 2 - 5, .height = fh }, t.z("MODE", .{}), t.zs(catalog.modes[ui.d_mode]), false);
    if (ov != 0) ui.d_mode = wrap(ui.d_mode, ov, catalog.modes.len);
    ry += fh + gap;

    // goal spans full width below the columns
    var gy = @max(ly, ry) + 6;
    flabel(x, gy, "GOAL");
    textField(.{ .x = x, .y = gy + 14, .width = colw, .height = 54 }, &ui.d_goal, ui.focus == .d_goal, "one line: what should the hive build or research?", .d_goal);
    gy += 78;

    // gateway + toggles row
    flabel(x, gy, "GATEWAY MODEL (optional - cheap model for mechanical calls)");
    textField(.{ .x = x, .y = gy + 14, .width = cw, .height = 32 }, &ui.d_gateway, ui.focus == .d_gateway, "blank = same as the minds", .d_gateway);
    if (t.checkbox(.{ .x = rx, .y = gy + 14, .width = cw / 2, .height = 32 }, t.z("living hive", .{}), ui.d_population)) ui.d_population = !ui.d_population;
    if (t.checkbox(.{ .x = rx + cw / 2, .y = gy + 14, .width = cw / 2, .height = 32 }, t.z("encrypt memory", .{}), ui.d_encrypt)) ui.d_encrypt = !ui.d_encrypt;
    gy += 58;

    // deploy button
    const online = blk: {
        store.lock();
        defer store.unlock();
        break :blk store.server_online;
    };
    const ready = ui.d_goal.len > 0 and online;
    const db = t.Rect{ .x = x, .y = gy, .width = 200, .height = 40 };
    if (t.button(db, t.z("Deploy swarm", .{}), t.blue, ready)) {
        submitDeploy(store, prov);
    }
    const hint = if (!online) t.z("server offline - start it to deploy", .{}) else if (ui.d_goal.len == 0) t.z("enter a goal", .{}) else t.z("posts to /api/v1/swarms on :{d}", .{portOf(store)});
    t.text(hint, @intFromFloat(x + 214), @intFromFloat(gy + 13), 12, if (ready) t.comment else t.orange);
}

fn flabel(x: f32, y: f32, s: [:0]const u8) void {
    t.text(s, @intFromFloat(x), @intFromFloat(y), 12, t.comment);
}

fn wrap(cur: usize, delta: i32, n: usize) usize {
    const ni: i32 = @as(i32, @intCast(cur)) + delta;
    if (ni < 0) return n - 1;
    if (ni >= @as(i32, @intCast(n))) return 0;
    return @intCast(ni);
}

fn portOf(store: *Store) u16 {
    store.lock();
    defer store.unlock();
    return store.settings.port;
}

/// Build the full DeployReq JSON (mirrors the web UI's POST /api/v1/swarms body) and hand it to the
/// poller as a deploy command; the poller posts it verbatim with the Settings API token.
fn submitDeploy(store: *Store, prov: *const catalog.Provider) void {
    var b: [3072]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    w.writeAll("{\"name\":\"") catch return;
    jesc(&w, ui.d_name.str());
    w.print("\",\"provider\":\"{s}\",\"model\":\"{s}\",\"style\":\"{s}\",\"stack\":\"{s}\",\"mode\":\"{s}\",\"base_url\":\"{s}\",\"minutes\":{d},\"encrypt\":{s},\"veil_population\":{s},\"api_key\":\"", .{
        prov.key, prov.models[ui.d_model].id, catalog.styles[ui.d_style], catalog.stacks[ui.d_stack], catalog.modes[ui.d_mode], prov.base_url, catalog.minutes[ui.d_minutes], boolStr(ui.d_encrypt), boolStr(ui.d_population),
    }) catch return;
    jesc(&w, ui.d_key.str());
    w.writeAll("\",\"gateway_model\":\"") catch return;
    jesc(&w, ui.d_gateway.str());
    w.writeAll("\",\"goal\":\"") catch return;
    jesc(&w, ui.d_goal.str());
    w.writeAll("\",\"minds\":[") catch return;
    const names = [_][]const u8{ "nova", "ada", "rex", "lux", "sol" };
    var i: i32 = 0;
    while (i < ui.d_minds) : (i += 1) {
        if (i > 0) w.writeAll(",") catch return;
        const nm = if (i < 5) names[@intCast(i)] else "m";
        w.print("{{\"name\":\"{s}\",\"role\":\"{s}\",\"duty\":\"build\",\"lead\":{s}}}", .{ nm, if (i == 0) "Lead" else "Maker", boolStr(i == 0) }) catch return;
    }
    w.writeAll("]}") catch return;
    const body = w.buffered();
    store.pushCmd(store_mod.mkCmd(.deploy, "", body));
    store.pushNotif("Deploying...", ui.d_goal.str(), 0);
    ui.tab = .dashboard;
}

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn jesc(w: *std.Io.Writer, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch {},
            '\\' => w.writeAll("\\\\") catch {},
            '\n' => w.writeAll("\\n") catch {},
            '\r' => {},
            '\t' => w.writeAll(" ") catch {},
            else => w.writeByte(c) catch {},
        }
    }
}

// -------------------------------------------------------------------------------- swarm view

fn drawSwarm(store: *Store, body: t.Rect) void {
    const pad: f32 = 12;
    const left_w: f32 = 270;
    const left = t.Rect{ .x = pad, .y = body.y + pad, .width = left_w, .height = body.height - pad * 2 };
    drawRoster(store, left);

    store.lock();
    const sel_n = store.selected_len;
    var sel: [96]u8 = undefined;
    @memcpy(sel[0..sel_n], store.selected[0..sel_n]);
    const m = store.metrics;
    const ev_n = store.event_count;
    var evs: [scan.MAX_LOG]scan.Ev = undefined;
    @memcpy(evs[0..ev_n], store.events[0..ev_n]);
    // friendly name for the header (look up the selected swarm in the roster)
    var title: [64]u8 = undefined;
    var title_n: usize = 0;
    {
        var i: usize = 0;
        while (i < store.swarm_count) : (i += 1) {
            if (std.mem.eql(u8, store.swarms[i].idStr(), sel[0..sel_n])) {
                const nm = store.swarms[i].nameStr();
                title_n = @min(nm.len, title.len);
                @memcpy(title[0..title_n], nm[0..title_n]);
                break;
            }
        }
    }
    store.unlock();
    if (title_n == 0) {
        title_n = @min(sel_n, title.len);
        @memcpy(title[0..title_n], sel[0..title_n]);
    }

    const rx = pad * 2 + left_w;
    const rw = body.width - rx - pad;
    if (sel_n == 0) {
        t.text(t.z("select a swarm on the left", .{}), @intFromFloat(rx + 8), @intFromFloat(body.y + 20), 14, t.comment);
        return;
    }

    var y = body.y + pad;
    t.textClip(title[0..title_n], @intFromFloat(rx), @intFromFloat(y), 18, t.fg, @intFromFloat(rw - 200));
    // inner tabs (Console / Details)
    const it_console = t.Rect{ .x = rx + rw - 190, .y = y - 2, .width = 92, .height = 24 };
    const it_details = t.Rect{ .x = rx + rw - 94, .y = y - 2, .width = 92, .height = 24 };
    if (t.tab(it_console, t.z("Console", .{}), ui.inner == .console)) ui.inner = .console;
    if (t.tab(it_details, t.z("Details", .{}), ui.inner == .details)) ui.inner = .details;
    y += 30;

    // controls + chat row live at the bottom for BOTH inner tabs
    const chat_h: f32 = 38;
    const ctrl_h: f32 = 32;
    const panel_bottom = body.y + body.height - pad - chat_h - 8 - ctrl_h - 8;
    const panel = t.Rect{ .x = rx, .y = y, .width = rw, .height = panel_bottom - y };
    switch (ui.inner) {
        .console => drawConsole(panel, evs[0..ev_n]),
        .details => drawDetails(panel, m),
    }

    var cy = panel.y + panel.height + 8;
    const stopb = t.Rect{ .x = rx, .y = cy, .width = 84, .height = ctrl_h };
    if (t.button(stopb, t.z("Stop", .{}), t.red, !m.stopped)) store.pushCmd(store_mod.mkCmd(.stop, sel[0..sel_n], ""));
    const goalb = t.Rect{ .x = rx + 92, .y = cy, .width = 120, .height = ctrl_h };
    if (t.button(goalb, t.z("Set goal->chat", .{}), t.magenta, ui.chat.len > 0)) {
        store.pushCmd(store_mod.mkCmd(.set_goal, sel[0..sel_n], ui.chat.str()));
        ui.chat.len = 0;
    }
    const followb = t.Rect{ .x = rx + 220, .y = cy, .width = 120, .height = ctrl_h };
    if (t.button(followb, if (ui.log_follow) t.z("following", .{}) else t.z("follow log", .{}), t.blue, true)) ui.log_follow = !ui.log_follow;
    const stlab = if (m.stopped) t.z("stopped: {s}", .{m.stop_reason[0..m.stop_reason_len]}) else t.z("round {d} - best {d}%", .{ m.round, m.best_pct });
    t.text(stlab, @intFromFloat(rx + 350), @intFromFloat(cy + 8), 12, if (m.stopped) t.comment else t.green);
    cy += ctrl_h + 8;

    const cf = t.Rect{ .x = rx, .y = cy, .width = rw - 96, .height = chat_h };
    textField(cf, &ui.chat, ui.focus == .chat, "message the hive (say) - Enter to send", .chat);
    const sendb = t.Rect{ .x = rx + rw - 88, .y = cy, .width = 88, .height = chat_h };
    const send = t.button(sendb, t.z("Send", .{}), t.blue, ui.chat.len > 0);
    if (send or (ui.focus == .chat and ui.chat.len > 0 and rl.isKeyPressed(.enter))) {
        store.pushCmd(store_mod.mkCmd(.say, sel[0..sel_n], ui.chat.str()));
        ui.chat.len = 0;
    }
}

fn drawDetails(r: t.Rect, m: scan.Metrics) void {
    t.panelBordered(r, t.bg_dark, t.border);
    const x = r.x + 16;
    var y = r.y + 16;
    const cw = (r.width - 48) / 3;
    metricCell(x + 0 * cw, y, "SCORE", t.z("{d}/{d}", .{ m.passed, m.total }), scoreColor(m.pct));
    metricCell(x + 1 * cw, y, "PCT", if (m.pct >= 0) t.z("{d}%", .{m.pct}) else t.z("-", .{}), scoreColor(m.pct));
    metricCell(x + 2 * cw, y, "BEST", t.z("{d}%", .{m.best_pct}), t.green);
    y += 64;
    metricCell(x + 0 * cw, y, "ROUND", t.z("{d}", .{m.round}), t.fg);
    metricCell(x + 1 * cw, y, "FILES", t.z("{d}", .{m.files}), t.cyan);
    const smoke = if (!m.smoke_seen) t.z("-", .{}) else if (m.smoke_ok) t.z("ok", .{}) else t.z("fail", .{});
    metricCell(x + 2 * cw, y, "SMOKE", smoke, if (!m.smoke_seen) t.comment else if (m.smoke_ok) t.green else t.red);
    y += 64;
    metricCell(x + 0 * cw, y, "TOKENS IN", t.z("{d}k", .{@divTrunc(m.tokens_in, 1000)}), t.yellow);
    metricCell(x + 1 * cw, y, "TOKENS OUT", t.z("{d}k", .{@divTrunc(m.tokens_out, 1000)}), t.yellow);
    metricCell(x + 2 * cw, y, "CACHED", t.z("{d}k", .{@divTrunc(m.tokens_cached, 1000)}), t.magenta);
    y += 70;
    if (m.gradient_warn) {
        t.fillRect(@intFromFloat(x), @intFromFloat(y), @intFromFloat(r.width - 32), 1, t.border);
        t.text(t.z("! zero-gradient warning - edits aren't reaching the failing check", .{}), @intFromFloat(x), @intFromFloat(y + 10), 12, t.orange);
    }
}

fn metricCell(x: f32, y: f32, lbl: [:0]const u8, value: [:0]const u8, accent: t.Color) void {
    t.text(lbl, @intFromFloat(x), @intFromFloat(y), 12, t.comment);
    t.text(value, @intFromFloat(x), @intFromFloat(y + 16), 22, accent);
}

fn scoreColor(pct: i32) t.Color {
    return if (pct >= 100) t.green else if (pct >= 50) t.cyan else if (pct >= 0) t.yellow else t.comment;
}

fn drawConsole(r: t.Rect, evs: []const scan.Ev) void {
    t.panelBordered(r, t.bg_dark, t.border);
    rl.beginScissorMode(@intFromFloat(r.x + 1), @intFromFloat(r.y + 1), @intFromFloat(r.width - 2), @intFromFloat(r.height - 2));
    defer rl.endScissorMode();
    const line_h: f32 = 19;
    const visible: usize = @intFromFloat((r.height - 12) / line_h);
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(r)) {
        ui.log_scroll -= wheel * 3;
        ui.log_follow = false;
    }
    var start: usize = 0;
    if (ui.log_follow) {
        start = if (evs.len > visible) evs.len - visible else 0;
        ui.log_scroll = @floatFromInt(start);
    } else {
        if (ui.log_scroll < 0) ui.log_scroll = 0;
        const total: f32 = @floatFromInt(evs.len);
        const maxs = if (total > @as(f32, @floatFromInt(visible))) total - @as(f32, @floatFromInt(visible)) else 0;
        if (ui.log_scroll > maxs) ui.log_scroll = maxs;
        start = @intFromFloat(ui.log_scroll);
    }
    var yy: f32 = r.y + 8;
    var i: usize = start;
    // Monospace + fixed pixel columns so round / mind / text line up like a real log. Sizes bumped for
    // readability (13px mono).
    while (i < evs.len and yy < r.y + r.height - 4) : (i += 1) {
        const e = &evs[i];
        const kc = kindColor(e.kindStr());
        if (e.round >= 0) t.textMono(t.z("r{d}", .{e.round}), @intFromFloat(r.x + 10), @intFromFloat(yy), 13, t.comment);
        const mind = e.mindStr();
        if (mind.len > 0) t.textMonoClip(mind, @intFromFloat(r.x + 52), @intFromFloat(yy), 13, kc, 72);
        t.textMonoClip(e.textStr(), @intFromFloat(r.x + 134), @intFromFloat(yy), 13, t.fg_dim, @intFromFloat(r.width - 144));
        yy += line_h;
    }
    if (evs.len == 0) t.text(t.z("no events yet", .{}), @intFromFloat(r.x + 12), @intFromFloat(r.y + 12), 13, t.comment);
}

fn kindColor(kind: []const u8) t.Color {
    if (std.mem.eql(u8, kind, "score")) return t.green;
    if (std.mem.eql(u8, kind, "cost")) return t.yellow;
    if (std.mem.eql(u8, kind, "goal") or std.mem.eql(u8, kind, "complete")) return t.magenta;
    if (std.mem.eql(u8, kind, "tick")) return t.blue;
    if (std.mem.eql(u8, kind, "stopped")) return t.red;
    return t.cyan;
}

// -------------------------------------------------------------------------------- hub

fn drawHub(body: t.Rect) void {
    const pad: f32 = 16;
    var y: f32 = body.y + pad;
    const x: f32 = pad;
    const colw = body.width - pad * 2;
    t.text(t.z("Hub - connect hives across machines", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
    y += 34;
    const card = t.Rect{ .x = x, .y = y, .width = colw, .height = 150 };
    t.panelBordered(card, t.bg_dark, t.border);
    t.text(t.z("The hub meshes many veil hosts into one console.", .{}), @intFromFloat(x + 14), @intFromFloat(y + 14), 13, t.fg_dim);
    t.text(t.z("Run the receiver once on a hosted box:", .{}), @intFromFloat(x + 14), @intFromFloat(y + 42), 12, t.comment);
    t.text(t.z("python hub.py serve", .{}), @intFromFloat(x + 14), @intFromFloat(y + 60), 13, t.cyan);
    t.text(t.z("On each veil host, start the callback:", .{}), @intFromFloat(x + 14), @intFromFloat(y + 88), 12, t.comment);
    t.text(t.z("python hub.py agent --hub URL", .{}), @intFromFloat(x + 14), @intFromFloat(y + 106), 13, t.cyan);
    y += 166;
    const card2 = t.Rect{ .x = x, .y = y, .width = colw, .height = 120 };
    t.panelBordered(card2, t.bg_dark, t.border);
    t.text(t.z("Fleet console", .{}), @intFromFloat(x + 14), @intFromFloat(y + 14), 14, t.fg);
    t.text(t.z("python hub.py console --hub URL", .{}), @intFromFloat(x + 14), @intFromFloat(y + 40), 13, t.cyan);
    t.text(t.z("Live roster, broadcast a directive to every veil, target one, stop all.", .{}), @intFromFloat(x + 14), @intFromFloat(y + 66), 12, t.comment);
    t.text(t.z("Wire NL_HUB_URL + NL_HUB_SECRET in Settings to embed this here (next).", .{}), @intFromFloat(x + 14), @intFromFloat(y + 88), 12, t.comment);
}

// -------------------------------------------------------------------------------- settings

fn drawSettings(store: *Store, body: t.Rect) void {
    const pad: f32 = 16;
    var y: f32 = body.y + pad;
    const x: f32 = pad;
    const colw = @min(body.width - pad * 2, 720);
    t.text(t.z("Settings", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
    y += 40;
    store.lock();
    const dd = store.settings.dataDir();
    var ddb: [512]u8 = undefined;
    const ddn = @min(dd.len, ddb.len);
    @memcpy(ddb[0..ddn], dd[0..ddn]);
    const portv = store.settings.port;
    const tok_n = store.settings.token_len;
    const notify_on = store.settings.notify;
    const online = store.server_online;
    store.unlock();

    flabel(x, y, "DATA DIRECTORY (read live)");
    y += 20;
    const dr = t.Rect{ .x = x, .y = y, .width = colw, .height = 32 };
    t.panelBordered(dr, t.bg, t.border);
    t.textClip(ddb[0..ddn], @intFromFloat(x + 10), @intFromFloat(y + 9), 13, t.fg, @intFromFloat(colw - 20));
    y += 48;
    flabel(x, y, "SERVER PORT");
    y += 20;
    t.text(t.z("{d}   ({s})", .{ portv, if (online) "reachable" else "not reachable" }), @intFromFloat(x), @intFromFloat(y), 14, if (online) t.green else t.comment);
    y += 40;
    flabel(x, y, "API TOKEN - an nlk_ key from the web UI (enables Deploy over the API)");
    y += 20;
    const tf = t.Rect{ .x = x, .y = y, .width = colw - 120, .height = 34 };
    textField(tf, &ui.d_key, ui.focus == .d_key, "nlk_... (also used by the Deploy tab)", .d_key);
    const savb = t.Rect{ .x = x + colw - 108, .y = y, .width = 108, .height = 34 };
    if (t.button(savb, t.z("Save token", .{}), t.blue, ui.d_key.len > 0)) {
        store.lock();
        const n = @min(ui.d_key.len, store.settings.token.len);
        @memcpy(store.settings.token[0..n], ui.d_key.buf[0..n]);
        store.settings.token_len = @intCast(n);
        store.unlock();
        store.pushNotif("Token saved", "Deploy is authorized", 1);
        ui.focus = .none;
    }
    y += 30;
    if (tok_n > 0) t.text(t.z("a token is set ({d} chars)", .{tok_n}), @intFromFloat(x), @intFromFloat(y), 12, t.green);
    y += 40;
    const tr = t.Rect{ .x = x, .y = y, .width = 220, .height = 30 };
    if (t.button(tr, if (notify_on) t.z("notifications: ON", .{}) else t.z("notifications: OFF", .{}), if (notify_on) t.green else t.comment, true)) {
        store.lock();
        store.settings.notify = !store.settings.notify;
        store.unlock();
    }
    y += 44;
    t.text(t.z("veil-desk v0.2.0 - same-machine companion - borderless chrome", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
}

// -------------------------------------------------------------------------------- shared widgets

fn textField(r: t.Rect, f: *Ui.Field, focused: bool, placeholder: [:0]const u8, which: Ui.Focus) void {
    t.panelBordered(r, t.bg, if (focused) t.blue else t.border);
    if (t.hovering(r) and rl.isMouseButtonPressed(.left)) ui.focus = which;
    const inner_x: i32 = @intFromFloat(r.x + 10);
    const inner_y: i32 = @intFromFloat(r.y + (r.height - 13) / 2);
    if (f.len == 0 and !focused) {
        t.text(placeholder, inner_x, inner_y, 13, t.comment);
    } else {
        t.textClip(f.str(), inner_x, inner_y, 13, t.fg, @intFromFloat(r.width - 20));
        if (focused) {
            const tw = t.measure(t.zs(f.str()), 13);
            if (@mod(rl.getTime(), 1.0) < 0.5) t.fillRect(inner_x + tw + 1, inner_y, 2, 15, t.blue);
        }
    }
}

fn drawToasts(store: *Store) void {
    store.lock();
    const now = rl.getTime();
    const n = store.notif_count;
    var shown: [4]store_mod.Notif = undefined;
    var sh: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (store.notif_head + i) % store.notifs.len;
        if (store.notifs[idx].born_s == 0) store.notifs[idx].born_s = now;
        if (now - store.notifs[idx].born_s < 5.0 and sh < shown.len) {
            shown[sh] = store.notifs[idx];
            sh += 1;
        }
    }
    store.unlock();
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const shh: f32 = @floatFromInt(rl.getScreenHeight());
    var yy = shh - 16;
    var k: usize = sh;
    while (k > 0) {
        k -= 1;
        const tn = &shown[k];
        const w: f32 = 320;
        const h: f32 = 56;
        yy -= h + 8;
        const r = t.Rect{ .x = sw - w - 16, .y = yy, .width = w, .height = h };
        const accent = switch (tn.accent) {
            1 => t.green,
            2 => t.orange,
            else => t.blue,
        };
        t.panelBordered(r, t.bg_hl, accent);
        t.fillRect(@intFromFloat(r.x), @intFromFloat(r.y + 6), 3, @intFromFloat(h - 12), accent);
        t.textClip(tn.titleStr(), @intFromFloat(r.x + 14), @intFromFloat(r.y + 9), 13, t.fg, @intFromFloat(w - 24));
        t.textClip(tn.bodyStr(), @intFromFloat(r.x + 14), @intFromFloat(r.y + 30), 11, t.fg_dim, @intFromFloat(w - 24));
    }
}
