//! veil-desk — the native desktop dashboard for nl-veil. One window, four tabs (Dashboard / Swarm /
//! Hub / Settings), styled in the same Tokyo Night palette as the web UI. It is a same-machine companion:
//! a background poller thread owns io and reads the run directories directly, while this (main) thread
//! runs raylib and draws the Store. Deploy / chat / stop / monitor a swarm; watch the live event console
//! and metrics; connect hives from the Hub tab. Cross-platform (win/linux/mac) via raylib; the tray +
//! toasts are native on Windows and degrade gracefully elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const t = @import("theme.zig");
const store_mod = @import("store.zig");
const scan = @import("scan.zig");
const poller_mod = @import("poller.zig");
const tray_mod = @import("tray.zig");

const Store = store_mod.Store;
const Tab = store_mod.Tab;

// Silence the std diagnostic stack-trace print on "unexpected" errors — this Zig's Windows net layer maps a
// refused localhost connection to error.Unexpected, which we handle cleanly (server offline); without this
// every 1s liveness probe of a not-yet-running server spams stderr.
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

const WIN_W = 1180;
const WIN_H = 760;
const TABBAR_H = 34;

/// UI-thread-only interaction state (text fields, scroll offsets, current tab). The Store holds the
/// machine's state; this holds the cursor's.
const Ui = struct {
    tab: Tab = .dashboard,
    chat_input: [1024]u8 = [_]u8{0} ** 1024,
    chat_len: usize = 0,
    goal_input: [1024]u8 = [_]u8{0} ** 1024,
    goal_len: usize = 0,
    token_input: [128]u8 = [_]u8{0} ** 128,
    token_len: usize = 0,
    focus: Focus = .none,
    log_scroll: f32 = 0,
    log_follow: bool = true,
    sel_row: i32 = -1,

    const Focus = enum { none, chat, goal, token };
};

var ui: Ui = .{};

pub fn main() !void {
    // libc is linked (raylib needs it), so the C allocator is the simplest thread-safe choice — both the
    // UI thread and the poller thread allocate through it.
    const gpa = std.heap.c_allocator;

    // One Io for the poller thread (filesystem + net). InitOptions all default — no environ needed.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = Store{};
    seedSettings(&store, gpa, io);

    // Background poller: owns io, refreshes the Store ~1Hz.
    var poller = poller_mod.Poller{ .io = io, .gpa = gpa, .store = &store };
    const th = try std.Thread.spawn(.{}, poller_mod.Poller.run, .{&poller});
    defer {
        poller.stop.store(true, .monotonic);
        th.join();
    }

    // raylib window (this thread only, from here on).
    rl.setConfigFlags(.{ .window_resizable = true, .vsync_hint = true, .msaa_4x_hint = true });
    rl.setTraceLogLevel(.warning);
    rl.initWindow(WIN_W, WIN_H, "veil-desk");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var tray: tray_mod.Tray = .{};
    tray.init("veil-desk");
    defer tray.deinit();

    // auto-select the most-recent swarm once the first roster lands
    var auto_selected = false;

    while (!rl.windowShouldClose()) {
        // deliver any fresh notifications to the OS tray + reflect server-online in the tray
        pumpTray(&store, &tray, gpa);

        if (!auto_selected) auto_selected = autoSelect(&store);

        handleKeys(&store);

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(t.bg);
        drawTabbar(&store);
        const body = t.Rect{ .x = 0, .y = TABBAR_H, .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight() - TABBAR_H) };
        switch (ui.tab) {
            .dashboard => drawDashboard(&store, body),
            .swarm => drawSwarm(&store, body, gpa),
            .hub => drawHub(&store, body),
            .settings => drawSettings(&store, body, gpa),
        }
        drawToasts(&store);
    }
}

// ---------------------------------------------------------------------------------- setup

fn seedSettings(store: *Store, gpa: std.mem.Allocator, io: std.Io) void {
    _ = gpa;
    // Probe likely locations relative to the launch cwd: the repo root has data/, and running from
    // zig-out/bin or desktop/ puts the tree one or two levels up. First existing wins. (An explicit
    // override is passed on argv by the deploy launcher; env reads moved behind io in this Zig.)
    const candidates = [_][]const u8{ "data", "../data", "../../data", "../nl-veil/data" };
    for (candidates) |c| {
        if (dirExists(io, c)) {
            setSetting(store, c);
            return;
        }
    }
    setSetting(store, "data"); // default; the user can see it's empty and fix it in Settings later
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn setSetting(store: *Store, dd: []const u8) void {
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
    return have; // roster present but already selected → done trying
}

// ---------------------------------------------------------------------------------- tray pump

fn pumpTray(store: *Store, tray: *tray_mod.Tray, gpa: std.mem.Allocator) void {
    store.lock();
    tray.setOnline(store.server_online);
    const notify_on = store.settings.notify;
    // deliver any notif still marked fresh
    var i: usize = 0;
    var to_send: [8]store_mod.Notif = undefined;
    var send_n: usize = 0;
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
    if (!notify_on) return;
    var k: usize = 0;
    while (k < send_n) : (k += 1) {
        tray.notify(gpa, to_send[k].titleStr(), to_send[k].bodyStr(), to_send[k].accent);
    }
}

// ---------------------------------------------------------------------------------- input

fn handleKeys(store: *Store) void {
    // tab hotkeys 1-4
    if (ui.focus == .none) {
        if (rl.isKeyPressed(.one)) ui.tab = .dashboard;
        if (rl.isKeyPressed(.two)) ui.tab = .swarm;
        if (rl.isKeyPressed(.three)) ui.tab = .hub;
        if (rl.isKeyPressed(.four)) ui.tab = .settings;
    }
    switch (ui.focus) {
        .none => {},
        .chat => editField(&ui.chat_input, &ui.chat_len),
        .goal => editField(&ui.goal_input, &ui.goal_len),
        .token => editField(&ui.token_input, &ui.token_len),
    }
    if (rl.isKeyPressed(.escape)) ui.focus = .none;
    _ = store;
}

fn editField(buf: []u8, len: *usize) void {
    var c = rl.getCharPressed();
    while (c > 0) : (c = rl.getCharPressed()) {
        if (c >= 32 and c < 127 and len.* < buf.len - 1) {
            buf[len.*] = @intCast(c);
            len.* += 1;
        }
    }
    if ((rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace)) and len.* > 0) len.* -= 1;
}

fn fieldStr(buf: []const u8, len: usize) []const u8 {
    return buf[0..len];
}

// ---------------------------------------------------------------------------------- tabbar

fn drawTabbar(store: *Store) void {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    t.fillRect(0, 0, @intFromFloat(sw), TABBAR_H, t.bg_dark);
    t.hline(0, TABBAR_H - 1, @intFromFloat(sw), t.border);
    // brand
    t.text(t.z("veil", .{}), 14, 10, 15, t.magenta);
    t.text(t.z("desk", .{}), 14 + t.measure(t.z("veil", .{}), 15), 10, 15, t.blue);

    const labels = [_][:0]const u8{ t.z("1 Dashboard", .{}), t.z("2 Swarm", .{}), t.z("3 Hub", .{}), t.z("4 Settings", .{}) };
    const tabs = [_]Tab{ .dashboard, .swarm, .hub, .settings };
    var x: f32 = 110;
    for (labels, tabs) |lb, tabv| {
        const w: f32 = @floatFromInt(t.measure(lb, 13) + 22);
        const r = t.Rect{ .x = x, .y = 5, .width = w, .height = TABBAR_H - 8 };
        if (t.tab(r, lb, ui.tab == tabv)) {
            ui.tab = tabv;
            ui.focus = .none;
        }
        x += w + 4;
    }

    // right-aligned server status pill
    store.lock();
    const online = store.server_online;
    const minds = store.fleet_minds;
    const refresh_s = store.last_refresh_s;
    store.unlock();
    _ = refresh_s;
    const dot_c = if (online) t.green else t.red;
    const label = if (online) t.z("server online  {d} minds", .{minds}) else t.z("server offline", .{});
    const lw = t.measure(label, 12);
    t.statusDot(@intFromFloat(sw - @as(f32, @floatFromInt(lw)) - 22), 17, dot_c);
    t.text(label, @intFromFloat(sw - @as(f32, @floatFromInt(lw)) - 12), 10, 12, if (online) t.fg_dim else t.comment);
}

// ---------------------------------------------------------------------------------- dashboard

fn drawDashboard(store: *Store, body: t.Rect) void {
    const pad: f32 = 16;
    var y: f32 = body.y + pad;
    const x: f32 = pad;
    const colw: f32 = body.width - pad * 2;

    t.text(t.z("Dashboard", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
    y += 34;

    // fleet stat cards
    store.lock();
    const online = store.server_online;
    const fl = store.fleet_live;
    const fm = store.fleet_minds;
    const fh = store.fleet_headroom;
    var vbuf: [16]u8 = undefined;
    const vn = store.server_version_len;
    @memcpy(vbuf[0..vn], store.server_version[0..vn]);
    const sc = store.swarm_count;
    store.unlock();

    const card_w = (colw - 30) / 4;
    statCard(x + 0 * (card_w + 10), y, card_w, "SERVER", if (online) "online" else "offline", if (online) t.green else t.red);
    statCard(x + 1 * (card_w + 10), y, card_w, "LIVE SWARMS", t.z("{d}", .{fl}), t.cyan);
    statCard(x + 2 * (card_w + 10), y, card_w, "LIVE MINDS", t.z("{d}", .{fm}), t.magenta);
    statCard(x + 3 * (card_w + 10), y, card_w, "HEADROOM", t.z("{d}", .{fh}), if (fh > 0) t.green else t.orange);
    y += 92;

    // deploy card
    const dr = t.Rect{ .x = x, .y = y, .width = colw, .height = 96 };
    t.panelBordered(dr, t.bg_dark, t.border);
    t.text(t.z("Deploy a swarm", .{}), @intFromFloat(x + 14), @intFromFloat(y + 12), 14, t.fg);
    const gf = t.Rect{ .x = x + 14, .y = y + 38, .width = colw - 160, .height = 34 };
    textField(gf, &ui.goal_input, &ui.goal_len, ui.focus == .goal, "one-line goal — e.g. Build a URL shortener in Go with tests", .goal);
    const db = t.Rect{ .x = x + colw - 134, .y = y + 38, .width = 120, .height = 34 };
    if (t.button(db, t.z("Deploy", .{}), t.blue, ui.goal_len > 0)) {
        store.pushCmd(store_mod.mkCmd(.deploy, "", fieldStr(&ui.goal_input, ui.goal_len)));
        ui.goal_len = 0;
        ui.focus = .none;
    }
    y += 112;

    // roster header
    t.text(t.z("Swarms ({d})", .{sc}), @intFromFloat(x), @intFromFloat(y), 15, t.fg_dim);
    y += 26;
    const list_r = t.Rect{ .x = x, .y = y, .width = colw, .height = body.y + body.height - y - pad };
    drawRoster(store, list_r, true);
}

fn statCard(x: f32, y: f32, w: f32, label: [:0]const u8, value: [:0]const u8, accent: t.Color) void {
    const r = t.Rect{ .x = x, .y = y, .width = w, .height = 82 };
    t.panelBordered(r, t.bg_dark, t.border);
    t.text(label, @intFromFloat(x + 12), @intFromFloat(y + 12), 11, t.comment);
    t.text(value, @intFromFloat(x + 12), @intFromFloat(y + 36), 26, accent);
}

fn drawRoster(store: *Store, r: t.Rect, clickable: bool) void {
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
    store.unlock();

    const row_h: f32 = 46;
    var yy: f32 = r.y + 6;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const sw = &rows[idx];
        const rr = t.Rect{ .x = r.x + 6, .y = yy, .width = r.width - 12, .height = row_h - 6 };
        const is_sel = std.mem.eql(u8, sw.idStr(), sel[0..sel_n]);
        const hot = clickable and t.hovering(rr);
        if (is_sel) t.panel(rr, t.bg_sel) else if (hot) t.panel(rr, t.bg_hl);
        // live dot
        t.statusDot(@intFromFloat(rr.x + 12), @intFromFloat(rr.y + rr.height / 2), if (sw.live) t.green else if (sw.stopped) t.comment else t.yellow);
        t.textClip(sw.idStr(), @intFromFloat(rr.x + 26), @intFromFloat(rr.y + 6), 13, t.fg, @intFromFloat(rr.width - 220));
        // goal subtitle
        if (sw.goal_len > 0) t.textClip(sw.goalStr(), @intFromFloat(rr.x + 26), @intFromFloat(rr.y + 22), 11, t.comment, @intFromFloat(rr.width - 220));
        // right: round + pct
        const pct = sw.pct;
        const rt = if (pct >= 0) t.z("r{d}  {d}%", .{ sw.round, pct }) else t.z("r{d}", .{sw.round});
        const rtw = t.measure(rt, 12);
        const pc = if (pct >= 100) t.green else if (pct >= 50) t.cyan else if (pct >= 0) t.yellow else t.comment;
        t.text(rt, @intFromFloat(rr.x + rr.width - @as(f32, @floatFromInt(rtw)) - 12), @intFromFloat(rr.y + 6), 12, pc);
        const st = if (sw.stopped) t.z("done", .{}) else if (sw.live) t.z("live", .{}) else t.z("idle", .{});
        t.text(st, @intFromFloat(rr.x + rr.width - @as(f32, @floatFromInt(t.measure(st, 11))) - 12), @intFromFloat(rr.y + 24), 11, if (sw.live) t.green else t.comment);

        if (hot and rl.isMouseButtonPressed(.left)) {
            store.pushCmd(store_mod.mkCmd(.select, sw.idStr(), ""));
            ui.tab = .swarm;
        }
        yy += row_h;
        if (yy > r.y + r.height) break;
    }
    if (n == 0) t.text(t.z("no swarms yet — deploy one above", .{}), @intFromFloat(r.x + 14), @intFromFloat(r.y + 14), 13, t.comment);
}

// ---------------------------------------------------------------------------------- swarm view

fn drawSwarm(store: *Store, body: t.Rect, gpa: std.mem.Allocator) void {
    _ = gpa;
    const pad: f32 = 12;
    // left column: roster (narrow). right: the open swarm (console + metrics + chat).
    const left_w: f32 = 280;
    const left = t.Rect{ .x = pad, .y = body.y + pad, .width = left_w, .height = body.height - pad * 2 };
    drawRoster(store, left, true);

    store.lock();
    const sel_n = store.selected_len;
    var sel: [64]u8 = undefined;
    @memcpy(sel[0..sel_n], store.selected[0..sel_n]);
    const m = store.metrics;
    const ev_n = store.event_count;
    var evs: [scan.MAX_LOG]scan.Ev = undefined;
    @memcpy(evs[0..ev_n], store.events[0..ev_n]);
    store.unlock();

    const rx = pad * 2 + left_w;
    const rw = body.width - rx - pad;

    if (sel_n == 0) {
        t.text(t.z("select a swarm on the left", .{}), @intFromFloat(rx + 8), @intFromFloat(body.y + 20), 14, t.comment);
        return;
    }

    // header: id + metrics strip
    var y = body.y + pad;
    t.textClip(sel[0..sel_n], @intFromFloat(rx), @intFromFloat(y), 18, t.fg, @intFromFloat(rw));
    y += 30;
    drawMetricsStrip(rx, y, rw, m);
    y += 66;

    // chat input row at the bottom
    const chat_h: f32 = 40;
    const controls_h: f32 = 34;
    const console_bottom = body.y + body.height - pad - chat_h - 8 - controls_h - 8;
    const console = t.Rect{ .x = rx, .y = y, .width = rw, .height = console_bottom - y };
    drawConsole(rx, console, evs[0..ev_n], m);

    // control buttons row
    var cy = console.y + console.height + 8;
    const stopb = t.Rect{ .x = rx, .y = cy, .width = 90, .height = controls_h };
    if (t.button(stopb, t.z("Stop", .{}), t.red, !m.stopped)) {
        store.pushCmd(store_mod.mkCmd(.stop, sel[0..sel_n], ""));
    }
    const setgoalb = t.Rect{ .x = rx + 98, .y = cy, .width = 130, .height = controls_h };
    if (t.button(setgoalb, t.z("Set goal → chat", .{}), t.magenta, ui.chat_len > 0)) {
        store.pushCmd(store_mod.mkCmd(.set_goal, sel[0..sel_n], fieldStr(&ui.chat_input, ui.chat_len)));
        ui.chat_len = 0;
    }
    const followb = t.Rect{ .x = rx + 236, .y = cy, .width = 130, .height = controls_h };
    if (t.button(followb, if (ui.log_follow) t.z("following ✓", .{}) else t.z("follow log", .{}), t.blue, true)) ui.log_follow = !ui.log_follow;
    // status label
    const stlab = if (m.stopped) t.z("stopped: {s}", .{m.stop_reason[0..m.stop_reason_len]}) else t.z("live · round {d} · best {d}%", .{ m.round, m.best_pct });
    t.text(stlab, @intFromFloat(rx + 376), @intFromFloat(cy + 9), 12, if (m.stopped) t.comment else t.green);
    cy += controls_h + 8;

    // chat row: input + send (writes a `say` to the swarm's control bus)
    const cf = t.Rect{ .x = rx, .y = cy, .width = rw - 96, .height = chat_h };
    textField(cf, &ui.chat_input, &ui.chat_len, ui.focus == .chat, "message the hive (say) — Enter to send", .chat);
    const sendb = t.Rect{ .x = rx + rw - 88, .y = cy, .width = 88, .height = chat_h };
    const send = t.button(sendb, t.z("Send", .{}), t.blue, ui.chat_len > 0);
    if (send or (ui.focus == .chat and ui.chat_len > 0 and rl.isKeyPressed(.enter))) {
        store.pushCmd(store_mod.mkCmd(.say, sel[0..sel_n], fieldStr(&ui.chat_input, ui.chat_len)));
        ui.chat_len = 0;
    }
}

fn drawMetricsStrip(x: f32, y: f32, w: f32, m: scan.Metrics) void {
    const r = t.Rect{ .x = x, .y = y, .width = w, .height = 58 };
    t.panelBordered(r, t.bg_dark, t.border);
    const cells = 5;
    const cw = w / cells;
    metricCell(x + 0 * cw, y, "SCORE", t.z("{d}/{d}", .{ m.passed, m.total }), scoreColor(m.pct));
    metricCell(x + 1 * cw, y, "PCT", if (m.pct >= 0) t.z("{d}%", .{m.pct}) else t.z("—", .{}), scoreColor(m.pct));
    metricCell(x + 2 * cw, y, "ROUND", t.z("{d}", .{m.round}), t.fg);
    metricCell(x + 3 * cw, y, "TOKENS", t.z("{d}k", .{@divTrunc(m.tokens_in + m.tokens_out, 1000)}), t.cyan);
    const smoke = if (!m.smoke_seen) t.z("—", .{}) else if (m.smoke_ok) t.z("ok", .{}) else t.z("fail", .{});
    metricCell(x + 4 * cw, y, "SMOKE", smoke, if (!m.smoke_seen) t.comment else if (m.smoke_ok) t.green else t.red);
    // gradient sentinel flag, if it fired
    if (m.gradient_warn) t.text(t.z("zero-gradient warning active", .{}), @intFromFloat(x + 12), @intFromFloat(y + 42), 10, t.orange);
}

fn metricCell(x: f32, y: f32, label: [:0]const u8, value: [:0]const u8, accent: t.Color) void {
    t.text(label, @intFromFloat(x + 12), @intFromFloat(y + 10), 10, t.comment);
    t.text(value, @intFromFloat(x + 12), @intFromFloat(y + 24), 18, accent);
}

fn scoreColor(pct: i32) t.Color {
    return if (pct >= 100) t.green else if (pct >= 50) t.cyan else if (pct >= 0) t.yellow else t.comment;
}

fn drawConsole(x: f32, r: t.Rect, evs: []const scan.Ev, m: scan.Metrics) void {
    _ = x;
    _ = m;
    t.panelBordered(r, t.bg_dark, t.border);
    rl.beginScissorMode(@intFromFloat(r.x + 1), @intFromFloat(r.y + 1), @intFromFloat(r.width - 2), @intFromFloat(r.height - 2));
    defer rl.endScissorMode();

    const line_h: f32 = 17;
    const visible: usize = @intFromFloat((r.height - 12) / line_h);
    // wheel scrolls; follow mode pins to the tail
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(r)) {
        ui.log_scroll -= wheel * 3;
        ui.log_follow = false;
    }
    const total: f32 = @floatFromInt(evs.len);
    var start: usize = 0;
    if (ui.log_follow) {
        start = if (evs.len > visible) evs.len - visible else 0;
        ui.log_scroll = @floatFromInt(start);
    } else {
        if (ui.log_scroll < 0) ui.log_scroll = 0;
        const maxs = if (total > @as(f32, @floatFromInt(visible))) total - @as(f32, @floatFromInt(visible)) else 0;
        if (ui.log_scroll > maxs) ui.log_scroll = maxs;
        start = @intFromFloat(ui.log_scroll);
    }

    var yy: f32 = r.y + 8;
    var i: usize = start;
    while (i < evs.len and yy < r.y + r.height - 4) : (i += 1) {
        const e = &evs[i];
        // gutter: round + mind, color by kind
        const kc = kindColor(e.kindStr());
        if (e.round >= 0) t.text(t.z("r{d}", .{e.round}), @intFromFloat(r.x + 8), @intFromFloat(yy), 12, t.comment);
        const mind = e.mindStr();
        if (mind.len > 0) t.textClip(mind, @intFromFloat(r.x + 44), @intFromFloat(yy), 12, kc, 70);
        t.textClip(e.textStr(), @intFromFloat(r.x + 120), @intFromFloat(yy), 12, t.fg_dim, @intFromFloat(r.width - 128));
        yy += line_h;
    }
    if (evs.len == 0) t.text(t.z("no events yet", .{}), @intFromFloat(r.x + 12), @intFromFloat(r.y + 12), 12, t.comment);
}

fn kindColor(kind: []const u8) t.Color {
    if (std.mem.eql(u8, kind, "score")) return t.green;
    if (std.mem.eql(u8, kind, "cost")) return t.yellow;
    if (std.mem.eql(u8, kind, "goal") or std.mem.eql(u8, kind, "complete")) return t.magenta;
    if (std.mem.eql(u8, kind, "tick")) return t.blue;
    if (std.mem.eql(u8, kind, "stopped")) return t.red;
    return t.cyan;
}

// ---------------------------------------------------------------------------------- hub

fn drawHub(store: *Store, body: t.Rect) void {
    _ = store;
    const pad: f32 = 16;
    var y: f32 = body.y + pad;
    const x: f32 = pad;
    const colw = body.width - pad * 2;
    t.text(t.z("Hub — connect hives across machines", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
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
    t.text(t.z("Wire NL_HUB_URL + NL_HUB_SECRET in Settings to embed this here (next).", .{}), @intFromFloat(x + 14), @intFromFloat(y + 88), 11, t.comment);
}

// ---------------------------------------------------------------------------------- settings

fn drawSettings(store: *Store, body: t.Rect, gpa: std.mem.Allocator) void {
    _ = gpa;
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

    t.text(t.z("Data directory (read live)", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
    y += 20;
    const dr = t.Rect{ .x = x, .y = y, .width = colw, .height = 32 };
    t.panelBordered(dr, t.bg, t.border);
    t.textClip(ddb[0..ddn], @intFromFloat(x + 10), @intFromFloat(y + 9), 12, t.fg, @intFromFloat(colw - 20));
    y += 48;

    t.text(t.z("Server port", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
    y += 20;
    t.text(t.z("{d}   ({s})", .{ portv, if (online) "reachable" else "not reachable" }), @intFromFloat(x), @intFromFloat(y), 14, if (online) t.green else t.comment);
    y += 40;

    t.text(t.z("API token (for Deploy — paste an API key from the web UI)", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
    y += 20;
    const tf = t.Rect{ .x = x, .y = y, .width = colw - 120, .height = 34 };
    textField(tf, &ui.token_input, &ui.token_len, ui.focus == .token, "optional — enables Deploy over the API", .token);
    const savb = t.Rect{ .x = x + colw - 108, .y = y, .width = 108, .height = 34 };
    if (t.button(savb, t.z("Save token", .{}), t.blue, ui.token_len > 0)) {
        store.lock();
        const n = @min(ui.token_len, store.settings.token.len);
        @memcpy(store.settings.token[0..n], ui.token_input[0..n]);
        store.settings.token_len = @intCast(n);
        store.unlock();
        store.pushNotif("Token saved", "Deploy is now authorized", 1);
        ui.focus = .none;
    }
    y += 30;
    if (tok_n > 0) t.text(t.z("a token is set ({d} chars)", .{tok_n}), @intFromFloat(x), @intFromFloat(y), 11, t.green);
    y += 40;

    // notifications toggle
    const tr = t.Rect{ .x = x, .y = y, .width = 200, .height = 30 };
    if (t.button(tr, if (notify_on) t.z("notifications: ON", .{}) else t.z("notifications: OFF", .{}), if (notify_on) t.green else t.comment, true)) {
        store.lock();
        store.settings.notify = !store.settings.notify;
        store.unlock();
    }
    y += 48;
    t.text(t.z("veil-desk v0.1.0 · same-machine companion · reads {s}", .{if (online) "+ server API" else "run dirs"}), @intFromFloat(x), @intFromFloat(y), 11, t.comment);
}

// ---------------------------------------------------------------------------------- shared widgets

fn textField(r: t.Rect, buf: []u8, len: *usize, focused: bool, placeholder: [:0]const u8, which: Ui.Focus) void {
    t.panelBordered(r, t.bg, if (focused) t.blue else t.border);
    if (t.hovering(r) and rl.isMouseButtonPressed(.left)) ui.focus = which;
    const inner_x: i32 = @intFromFloat(r.x + 10);
    const inner_y: i32 = @intFromFloat(r.y + (r.height - 13) / 2);
    if (len.* == 0 and !focused) {
        t.text(placeholder, inner_x, inner_y, 13, t.comment);
    } else {
        t.textClip(buf[0..len.*], inner_x, inner_y, 13, t.fg, @intFromFloat(r.width - 20));
        // caret
        if (focused) {
            const tw = t.measure(t.zs(buf[0..len.*]), 13);
            if (@mod(rl.getTime(), 1.0) < 0.5) t.fillRect(inner_x + tw + 1, inner_y, 2, 15, t.blue);
        }
    }
}

// ---------------------------------------------------------------------------------- toasts

fn drawToasts(store: *Store) void {
    store.lock();
    const now = rl.getTime();
    const n = store.notif_count;
    var shown: [4]store_mod.Notif = undefined;
    var sh: usize = 0;
    // stamp born time lazily on first draw, drop expired
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
    const sh_h: f32 = @floatFromInt(rl.getScreenHeight());
    var yy = sh_h - 16;
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
