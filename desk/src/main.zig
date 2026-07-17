//! veil-desk — the native desktop dashboard for nl-veil: a borderless (own-chrome) raylib window styled in
//! the web UI's Tokyo Night palette. Same-machine companion — a background poller thread owns io and reads
//! the run directories directly, while this (main) thread runs raylib and draws the Store. Deploy swarms,
//! chat/monitor/stop them, and watch the live event console + metrics.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const t = @import("theme.zig");
const store_mod = @import("store.zig");
const scan = @import("scan.zig");
const poller_mod = @import("poller.zig");
const chat_mod = @import("chat.zig");
const llm = @import("llm.zig");
const tray_mod = @import("tray.zig");
const catalog = @import("catalog.zig");
const md = @import("mdutil.zig");
const log = @import("log.zig");

const Store = store_mod.Store;
const Tab = store_mod.Tab;

// This Zig's Windows net layer maps a refused localhost connection to error.Unexpected, which we handle
// (server offline); silence the diagnostic trace so the 1Hz liveness probe doesn't spam stderr.
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

// The server spawns us with `.stderr = .ignore`, so a ReleaseSafe panic (bounds violation, unreachable,
// unwrapped null) dies SILENTLY — the log just stops mid-turn and the fault is lost. Install a panic handler
// that appends the panic message + return address to a durable file BEFORE the normal panic path runs, so a
// recurrence is pinpointable regardless of how the desk was launched. Best-effort and allocation-free — we
// may be in a corrupt state.
pub const panic = std.debug.FullPanic(deskPanic);

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

// Re-entry guard: writeCrashReport walks the stack + reads the PDB, which itself can fault on a truly corrupt
// heap — that would re-enter deskPanic and recurse forever. The first entrant writes the report; a re-entrant
// panic (the reporter faulted) skips straight to abort. The bare header is flushed BEFORE the risky trace, so
// even a reporter fault leaves the panic message + address on disk.
var panicking = std.atomic.Value(bool).init(false);

fn deskPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (!panicking.swap(true, .seq_cst)) writeCrashReport(msg, first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr); // preserve the normal stderr trace + abort
}

/// Write the panic message, addresses, AND a SYMBOLICATED stack trace to a durable file. The desk is spawned
/// with stderr ignored, so defaultPanic's trace vanishes; this puts file:line frames on disk regardless of how
/// the desk was launched. Module base + RVA are logged too, so even a stripped-PDB build's bare address can be
/// mapped later. Best-effort: the header is flushed first, then the trace is attempted (guarded against a
/// reporter fault by `panicking` above).
fn writeCrashReport(msg: []const u8, ra: ?usize) void {
    // The app's gpa may be corrupt mid-panic, so stand up a throwaway blocking Io on the page allocator
    // (lock-free VirtualAlloc, no shared state). Skip deinit: we abort in defaultPanic right after.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = threaded.io();
    const base = @intFromPtr(GetModuleHandleW(null)); // this module's load base → RVA = ret_addr - base
    // The desk's cwd varies (repo root, zig-out/bin, Explorer double-click) and createFile makes no parent
    // dirs — a single hardcoded "data/..." path once made a live crash INVISIBLE from the wrong cwd. Try each
    // known data location, then the cwd itself; the first that opens gets the report.
    for ([_][]const u8{ "data/desk-panic.log", "../data/desk-panic.log", "../../data/desk-panic.log", "desk-panic.log" }) |p| {
        const f = std.Io.Dir.cwd().createFile(io, p, .{}) catch continue;
        defer f.close(io);
        var buf: [8 << 10]u8 = undefined;
        var fw = f.writer(io, &buf);
        const w = &fw.interface;
        if (ra) |a|
            w.print("=== desk PANIC === {s} (ret_addr=0x{x} base=0x{x} rva=0x{x})\n", .{ msg, a, base, a -% base }) catch {}
        else
            w.print("=== desk PANIC === {s} (ret_addr=? base=0x{x})\n", .{ msg, base }) catch {};
        w.flush() catch {}; // header is durable now, before the risky symbolication
        // Best-effort symbolicated backtrace (reads the co-located PDB). A fault here re-enters deskPanic →
        // the `panicking` guard sends it to abort, so the flushed header survives.
        std.debug.writeCurrentStackTrace(.{ .first_address = ra }, .{ .writer = w, .mode = .no_color }) catch {};
        w.flush() catch {};
        return;
    }
}

const WIN_W = 1220;
const WIN_H = 820;
const TITLE_H = 34;
const TAB_H = 38;

// Titlebar interactive zones — ONE definition shared by drawTitlebar (pixels) and handleWindowChrome
// (drag hit-test) so the drag zone and the rendered rects can't drift apart.
fn tbFileRect() t.Rect {
    return .{ .x = 70, .y = 5, .width = 46, .height = TITLE_H - 10 };
}
fn tbThemeRect() t.Rect {
    return .{ .x = 124, .y = 5, .width = 128, .height = TITLE_H - 10 };
}

const InnerTab = enum { console, details, files };
const DdKind = enum { none, provider, model, style, minutes, stack, mode, chat_provider, chat_byok, chat_model, sched_model };

const ChatInner = enum { chat, metrics, files }; // the Chat center-pane inner tabs
const RightTab = enum { activity, memory }; // the right pane's inner tabs (Swarm activity | Memory)
const SchedInner = enum { tasks, build }; // the Tasks tab's inner tabs (task list | builder form)
const SwarmInner = enum { live, deploy }; // the Swarm tab's inner tabs (live view | deploy form)
const ChatsInner = enum { chats, sched }; // the chat LEFT pane's inner tabs (conversations | scheduled tasks)

/// UI-thread-only interaction state (the Store holds the machine's state; this holds the cursor's).
const Ui = struct {
    tab: Tab = .dashboard,
    inner: InnerTab = .console,
    focus: Focus = .none,
    input_active: bool = false, // handleKeys/editField set this when they consume a keystroke — drives FPS
    hot_frames: u32 = 0, // frames of snappy 60fps remaining after the last activity (activity-gated redraw)
    // Chat message render-height cache: word-wrapping every message twice per frame (measure + draw) pins a
    // CPU core on long chats. Cache heights; recompute only when the message set or wrap width changes.
    // INCREMENTAL: per-row fingerprints (mh_mfp) so a change re-measures only the changed/new rows (re-wrapping
    // the WHOLE transcript on every few-hundred-ms server commit scaled cost with history length × commit rate).
    mh: [store_mod.MAX_CHAT_MSGS]f32 = undefined,
    mh_mfp: [store_mod.MAX_CHAT_MSGS]u64 = undefined,
    mh_count: usize = 0,
    mh_cols: usize = 0,
    mh_fp: u64 = 0,
    // live-stream measure cache: the growing preview only re-wraps when its length actually changed (not
    // every frame at 30-60fps while busy).
    stream_h: f32 = 0,
    stream_h_len: usize = std.math.maxInt(usize),
    stream_h_cols: usize = 0,
    // SMOOTH REVEAL: how many bytes of the in-flight reply are shown on screen. Server tokens arrive in
    // poll-batched chunks (33-120ms), so dumping each batch at once makes a slow reply appear in visible
    // jumps; this advances toward the received length at a steady catch-up rate so the text flows like typing.
    stream_reveal: usize = 0,
    tool_open: ?usize = null, // which tool-call message is expanded (else all collapsed to a one-line chip)
    chat: Field = .{},
    // Chat tab
    c_input: Field = .{},
    c_rename: Field = .{},
    c_renaming: bool = false, // the active conversation's title is being edited in the left pane
    chat_scroll: f32 = 0,
    chat_follow: bool = true,
    chat_inner: ChatInner = .chat, // center pane: conversation | Metrics (perf graphs) | Files (this chat's build dir)
    chat_file_scroll: f32 = 0, // scroll offset for the chat Files content viewer
    chat_file_list_scroll: f32 = 0, // scroll offset (px) for the chat Files LEFT file list
    right_tab: RightTab = .activity, // right pane: Swarm activity | Memory (durable keys/logins/prefs)
    mem_scroll: f32 = 0, // scroll offset for the Memory tab list
    conv_scroll: f32 = 0, // scroll offset for the Chats list (left pane)
    chats_inner: ChatsInner = .chats, // left pane inner tabs: conversations | scheduled tasks
    con_scroll: [2]f32 = .{ 0, 0 }, // micro-console scrollback per tab (You/Veil): wrapped lines back from the tail; 0 = follow
    cast_scroll: f32 = 0, // swarm-activity live console: events back from the tail; 0 = follow
    sel_msg: ?usize = null, // chat text selection: which message (null = none), and the [anchor,cursor) flat range
    sel_anchor: usize = 0,
    sel_cursor: usize = 0,
    sel_dragging: bool = false,
    // Settings: chat model provider fields
    s_model: Field = .{},
    s_url: Field = .{},
    s_ckey: Field = .{},
    s_cfacct: Field = .{}, // Cloudflare account id (chat BYOK, when the provider needs one)
    s_seeded: bool = false, // provider fields copied from the store once (after the chat thread loads)
    // Settings: server target (host empty = this machine)
    s_host: Field = .{},
    s_port: Field = .{},
    srv_seeded: bool = false, // host/port copied from the store once (after loadSettings finishes)
    // deploy form
    d_name: Field = .{},
    d_key: Field = .{},
    d_cfacct: Field = .{}, // Cloudflare account id (Deploy form, when the provider needs one)
    d_goal: Field = .{},
    d_gateway: Field = .{},
    d_provider: usize = 0,
    d_model: usize = 0,
    d_use_default: bool = false, // deploy PROVIDER slot 0: inherit the client's configured chat LLM
    d_minds: i32 = 3,
    d_minutes: usize = 3, // index into catalog.minutes
    d_style: usize = 0,
    d_stack: usize = 0,
    d_mode: usize = 0,
    d_population: bool = false,
    d_encrypt: bool = false,
    // RSI dials (mirror the deploy wizard's swarm.json knobs)
    d_autonomy_full: bool = true,
    d_internet: bool = true,
    d_gap: bool = true,
    d_breakout: bool = false,
    d_psyche: bool = false,
    swarm_inner: SwarmInner = .live, // Swarm tab: live view | the deploy form (Deploy folded in as an inner tab)
    // live-reply activity tracking (drives the thinking mark's energy): the stream's last seen length +
    // the wall time it last GREW. Updated at the one live renderMsg call site each frame.
    live_len_prev: usize = 0,
    live_change_t: f64 = -10,
    // chat input drag-resize (the grab strip above the input row) + transcript select-all state
    input_extra: f32 = 0,
    input_dragging: bool = false,
    conv_selected: bool = false, // Ctrl+A on the transcript: the WHOLE conversation is the copy target
    // Settings page scroll (content outgrows the window at larger text sizes)
    settings_scroll: f32 = 0,
    settings_h: f32 = 0, // content height measured last frame — the scroll clamp
    // Tasks tab: task list + builder form ("once" fires at now+N; "every" repeats; "daily" at HH:MM)
    sched_inner: SchedInner = .tasks,
    sched_scroll: f32 = 0,
    sc_name: Field = .{},
    sc_prompt: Field = .{},
    sc_details: Field = .{},
    sc_kind: usize = 0, // 0 once / 1 every N min / 2 daily at — mirrors the wire "kind"
    sc_once_min: i32 = 30, // once: run this many minutes from submit
    sc_every_min: i32 = 30, // every: interval minutes
    sc_hour: i32 = 9, // daily: HH
    sc_minute: i32 = 0, // daily: MM
    sc_enabled: bool = true,
    // per-task provider override (all three blank at create = snapshot the chat provider from Settings)
    sc_base: Field = .{},
    sc_model: Field = .{},
    sc_key: Field = .{},
    // edit mode: non-empty = the builder form is EDITING this existing task (save → POST /sched/:id)
    sc_edit_id: [64]u8 = [_]u8{0} ** 64,
    sc_edit_id_len: u8 = 0,
    // micro-console (below the swarm activity): dual-tab shell
    con_tab: u8 = 0, // 0 = You, 1 = Veil (the AI's tab)
    con_input: Field = .{},
    // You-shell command HISTORY: a ring of past commands, browsed with Up/Down exactly like a real prompt.
    con_hist: [32][512]u8 = undefined,
    con_hist_len: [32]usize = [_]usize{0} ** 32,
    con_hist_total: usize = 0, // monotonically increasing push count; slot = total % ring size
    con_hist_back: usize = 0, // 0 = the live draft; N = N entries back into history
    con_hist_draft: [512]u8 = undefined, // the in-progress text saved when browsing starts (Down restores it)
    con_hist_draft_len: usize = 0,
    // Files tab view state
    file_scroll: f32 = 0,
    file_list_scroll: f32 = 0, // scroll offset (px) for the swarm Files LEFT file list
    // deploy dropdowns
    open_dd: DdKind = .none,
    dd_rect: t.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    dd_scroll: f32 = 0, // scroll offset (rows) for a long dropdown list
    // window chrome
    dragging: bool = false,
    drag_grab_x: f32 = 0, // mouse-in-window offset captured at drag start (absolute-tracking, not delta)
    drag_grab_y: f32 = 0,
    resizing: bool = false,
    file_menu: bool = false,
    close_req: bool = false,
    // manual maximize/restore (the window is undecorated, so we drive it ourselves): on maximize we save the
    // current rect and grow to fill the monitor; on restore we write the saved rect back.
    win_max: bool = false,
    saved_x: i32 = 0,
    saved_y: i32 = 0,
    saved_w: i32 = 0,
    saved_h: i32 = 0,
    show_log: bool = false, // F12 debug overlay
    // log console
    log_scroll: f32 = 0,
    log_follow: bool = true,
    details_scroll: f32 = 0, // swarm Details tab: the goal + config + blueprint can outgrow the panel

    const Focus = enum { none, chat, d_name, d_key, d_cfacct, d_goal, d_gateway, c_input, c_rename, s_model, s_url, s_ckey, s_cfacct, s_host, s_port, con_input, sc_name, sc_prompt, sc_details, sc_base, sc_model, sc_key };
    const Field = struct {
        buf: [1200]u8 = [_]u8{0} ** 1200,
        len: usize = 0,
        cur: usize = 0, // caret byte index (0..=len), kept on a UTF-8 codepoint boundary
        sel: ?usize = null, // selection anchor; the selection is [min(cur,sel), max(cur,sel))
        fn str(f: *const Field) []const u8 {
            return f.buf[0..f.len];
        }
        fn clear(f: *Field) void {
            f.len = 0;
            f.cur = 0;
            f.sel = null;
        }
        fn clampCur(f: *Field) void {
            if (f.cur > f.len) f.cur = f.len;
            if (f.sel) |s| if (s > f.len) {
                f.sel = f.len;
            };
        }
        /// byte index one codepoint left of i (skips UTF-8 continuation bytes so the caret never lands mid-sequence)
        fn prevCp(f: *const Field, i: usize) usize {
            var j = i;
            while (j > 0) {
                j -= 1;
                if ((f.buf[j] & 0xC0) != 0x80) break;
            }
            return j;
        }
        fn nextCp(f: *const Field, i: usize) usize {
            var j = i;
            if (j < f.len) {
                j += 1;
                while (j < f.len and (f.buf[j] & 0xC0) == 0x80) j += 1;
            }
            return j;
        }
        /// the normalized selection [lo, hi), or null when empty
        fn selRange(f: *const Field) ?[2]usize {
            const s = f.sel orelse return null;
            if (s == f.cur) return null;
            return .{ @min(s, f.cur), @max(s, f.cur) };
        }
        /// delete the selection if one exists; returns whether anything was removed
        fn delSel(f: *Field) bool {
            const rg = f.selRange() orelse {
                f.sel = null;
                return false;
            };
            std.mem.copyForwards(u8, f.buf[rg[0] .. f.len - (rg[1] - rg[0])], f.buf[rg[1]..f.len]);
            f.len -= rg[1] - rg[0];
            f.cur = rg[0];
            f.sel = null;
            return true;
        }
        fn insert(f: *Field, ch: u8) void {
            if (f.len >= f.buf.len - 1) return;
            std.mem.copyBackwards(u8, f.buf[f.cur + 1 .. f.len + 1], f.buf[f.cur..f.len]);
            f.buf[f.cur] = ch;
            f.cur += 1;
            f.len += 1;
        }
        fn delBack(f: *Field) void {
            if (f.cur == 0) return;
            const p = f.prevCp(f.cur);
            std.mem.copyForwards(u8, f.buf[p .. f.len - (f.cur - p)], f.buf[f.cur..f.len]);
            f.len -= f.cur - p;
            f.cur = p;
        }
        fn delFwd(f: *Field) void {
            if (f.cur >= f.len) return;
            const nx = f.nextCp(f.cur);
            std.mem.copyForwards(u8, f.buf[f.cur .. f.len - (nx - f.cur)], f.buf[nx..f.len]);
            f.len -= nx - f.cur;
        }
    };
};

var ui: Ui = .{};

// UI-thread-only optimistic "deleting…" set: when the user clicks ✕ the row shows "deleting…" until the
// poller's delete lands and the swarm drops out of the roster.
var del_ids: [16][96]u8 = undefined;
var del_lens: [16]u8 = [_]u8{0} ** 16;
var del_n: usize = 0;
fn markDeleting(id: []const u8) void {
    if (isDeleting(id) or del_n >= del_ids.len) return;
    const nn = @min(id.len, del_ids[del_n].len);
    @memcpy(del_ids[del_n][0..nn], id[0..nn]);
    del_lens[del_n] = @intCast(nn);
    del_n += 1;
}
fn isDeleting(id: []const u8) bool {
    var i: usize = 0;
    while (i < del_n) : (i += 1) {
        if (std.mem.eql(u8, del_ids[i][0..del_lens[i]], id)) return true;
    }
    return false;
}
/// Drop del-set entries whose swarm no longer appears in the roster — the delete finished.
fn pruneDeleting(rows: []const scan.SwarmSummary) void {
    var i: usize = 0;
    while (i < del_n) {
        const id = del_ids[i][0..del_lens[i]];
        var present = false;
        for (rows) |*sw| {
            if (std.mem.eql(u8, sw.idStr(), id)) {
                present = true;
                break;
            }
        }
        if (present) {
            i += 1;
        } else {
            // swap-remove
            del_n -= 1;
            if (i != del_n) {
                del_ids[i] = del_ids[del_n];
                del_lens[i] = del_lens[del_n];
            }
        }
    }
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    // carry the real process environ so spawned children (curl, explorer) get a working environment
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var store = Store{};
    seedSettings(&store, gpa, io);
    ui.d_name.len = seedName(&ui.d_name.buf);

    var poller = poller_mod.Poller{ .io = io, .gpa = gpa, .store = &store };
    const th = try std.Thread.spawn(.{}, poller_mod.Poller.run, .{&poller});
    defer {
        poller.stop.store(true, .monotonic);
        th.join();
    }

    // The chat worker is the third thread (model turns + swarm casting); it owns its own Io instance so
    // the poller's cadence and the chat's long-running streams never contend.
    var chat_threaded = std.Io.Threaded.init(gpa, .{ .environ = llm.osEnviron() });
    defer chat_threaded.deinit();
    var chat_worker = chat_mod.Chat{ .io = chat_threaded.io(), .gpa = gpa, .store = &store };
    const cth = try std.Thread.spawn(.{}, chat_mod.Chat.run, .{&chat_worker});
    defer {
        chat_worker.stop.store(true, .monotonic);
        cth.join();
    }

    // Borderless: we draw our own title bar (drag / File / minimize / close). Resizable stays on so the
    // grip in the corner can drive setWindowSize. 60fps focused so scrolling/typing/hover feel instant; we
    // drop to a low idle FPS when the window is in the background (heat control) below.
    rl.setConfigFlags(.{ .window_resizable = true, .window_undecorated = true });
    rl.setTraceLogLevel(.warning);
    rl.initWindow(WIN_W, WIN_H, "veil-desk");
    defer rl.closeWindow();
    defer t.deinit();
    // Escape is raylib's default EXIT key, but here it's the "unfocus the input" key (handleKeys) — leaving
    // it as the exit key would quit the app whenever someone escapes a text field.
    rl.setExitKey(.null);
    rl.setTargetFPS(60);

    // Real TTFs replace raylib's blocky default: a proportional UI font + a monospace console font. Load at
    // a HIGH base size (48) and generate mipmaps + TRILINEAR filtering so downscaling to 11..22px picks the
    // right mip level and stays crisp (loading near the render size, or bilinear-minifying a 48px glyph to
    // 12px, leaves small text blurry). Mipmaps + trilinear is the standard raylib recipe for multi-size fonts.
    var ui_loaded = false;
    var mono_loaded = false;
    if (loadFontAt(uiCandidates(), 48)) |f| {
        var fm = f;
        rl.genTextureMipmaps(&fm.texture);
        rl.setTextureFilter(fm.texture, .trilinear);
        t.setFont(fm);
        ui_loaded = true;
    }
    if (loadFontAt(monoCandidates(), 44)) |f| {
        var fm = f;
        rl.genTextureMipmaps(&fm.texture);
        rl.setTextureFilter(fm.texture, .trilinear);
        t.setMono(fm);
        mono_loaded = true;
    }
    applyChatVariantFonts(false, false); // bold + italic chat faces; the settings reconcile below re-applies
    // Window + taskbar icon from assets/icon.png (with a procedural fallback).
    const icon = makeIcon();
    rl.setWindowIcon(icon);
    rl.unloadImage(icon);

    var tray: tray_mod.Tray = .{};
    tray.init("veil-desk");
    defer tray.deinit();

    {
        store.lock();
        const dd = store.settings.dataDir();
        const tk = store.settings.token_len;
        const pt = store.settings.port;
        log.info("veil-desk start; data={s} port={d} token={d}b fonts(ui={} mono={})", .{ dd, pt, tk, ui_loaded, mono_loaded });
        store.unlock();
    }

    syncThemeFromStore(&store);

    // AUTOMATION HOOK — poll <data>/.veil-desk/SIM.txt: whenever it exists AND the chat is idle + connected,
    // send its contents as a chat message and delete it. Drives multi-turn steering sims with zero synthetic
    // UI input (a borderless window delivers that unreliably); no trigger file = normal run (no-op). `sim_mode`
    // (set once any trigger fires) holds 30fps so a headless, unfocused run's turn/cast poll stays responsive.
    var sim_ticks: u32 = 0;
    var sim_mode = false;

    var auto_selected = false;
    while (true) {
        if (rl.windowShouldClose()) {
            _ = rl.saveFileText("data/desk-exit-reason.txt", "windowShouldClose (OS WM_CLOSE / no interactive desktop)");
            break;
        }
        if (ui.close_req) {
            _ = rl.saveFileText("data/desk-exit-reason.txt", "ui.close_req (X button / File>quit / tray quit)");
            break;
        }
        store.lock();
        const online0 = store.server_online;
        const busy0 = store.chat_busy;
        const dys0 = store.settings.dyslexia;
        const bold0 = store.settings.font_bold;
        const scale0 = store.settings.font_scale;
        // POLLER hand-off: a run-now (or any background action) minted a conversation to show — consume it
        // once, open it in Chat, and switch tabs, so "run now" visibly runs instead of just toasting.
        var goto_buf: [64]u8 = undefined;
        var goto_len: usize = 0;
        if (store.goto_conv_len > 0) {
            goto_len = store.goto_conv_len;
            @memcpy(goto_buf[0..goto_len], store.goto_conv[0..goto_len]);
            store.goto_conv_len = 0;
        }
        store.unlock();
        if (goto_len > 0) {
            store.pushChatCmd(store_mod.mkChatCmd(.select_conv, goto_buf[0..goto_len], ""));
            setTab(.chat);
        }
        // TEXT SETTINGS: hot-swap the UI font when face/weight differ from what's applied — covers the
        // Settings toggles AND the persisted values landing after startup (settings load on the chat
        // thread; fonts must load HERE, on the GL thread). Applied-state updates even on a failed load
        // so a missing font file can't become a per-frame retry. The size setting is draw-time math —
        // no atlas rebuild — and the chat's line heights follow the combined factor.
        if (dys0 != font_dyslexia_applied or bold0 != font_bold_applied) {
            applyUiFont(dys0, bold0);
            applyChatVariantFonts(dys0, bold0); // keep the chat's bold/italic variants in the same family
            font_dyslexia_applied = dys0;
            font_bold_applied = bold0;
        }
        t.setUiScale(@as(f32, @floatFromInt(scale0)) / 100.0);
        MSG_LINE_H = @round(19.0 * t.uiScale());
        MSG_HEAD_H = @round(18.0 * t.uiScale());
        // Activity-gated frame rate. This is an immediate-mode UI: EVERY frame re-lays-out + redraws every chat
        // message's markdown, so holding 60fps while the user is just READING pins a CPU core. Stay at 60 only
        // when something is actually changing — mouse activity, a keystroke, or a live token stream — and idle
        // down otherwise. Input is still polled every frame; only the redraw rate drops.
        {
            const mdelta = rl.getMouseDelta();
            const mouse_active = mdelta.x != 0 or mdelta.y != 0 or rl.isMouseButtonDown(.left) or rl.isMouseButtonDown(.right) or rl.getMouseWheelMove() != 0;
            if (mouse_active or ui.input_active or busy0) ui.hot_frames = 40; // ~0.66s of 60fps after any activity
            ui.input_active = false; // handleKeys/editField below re-arm it for the next frame
            const focused = rl.isWindowFocused();
            // idle floors: 12 focused / 6 unfocused. Input is still polled EVERY frame, so the first wake
            // costs at most one idle frame (~83ms) before hot_frames restores 60fps — imperceptible, and the
            // focused-idle redraw was the last steady CPU line item after the poller/log churn fixes.
            const fps: i32 = if (ui.hot_frames > 0) (if (focused) 60 else 30) else if (focused) 12 else 6;
            if (ui.hot_frames > 0) ui.hot_frames -= 1;
            rl.setTargetFPS(fps);
        }
        // KEYBOARD NAVIGATION (accessibility): Tab / Shift+Tab walk a high-contrast focus ring across
        // every button/tab/checkbox in draw order; Enter or Space activates — but ONLY while no text
        // field owns the keyboard, so typing is never hijacked. Escape or any click drops the ring.
        // With the narrator on, each focus move SPEAKS the control ("dyslexia mode: OFF. button") —
        // the app is operable and audible without sight or mouse.
        {
            const tab_k = rl.isKeyPressed(.tab);
            const kshift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
            const no_field = ui.focus == .none;
            t.kbFrame(tab_k and !kshift, tab_k and kshift, no_field and (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter) or rl.isKeyPressed(.space)));
            if (rl.isMouseButtonPressed(.left) or rl.isKeyPressed(.escape)) t.kbCancel();
            if (tab_k) ui.input_active = true; // keep 60fps while walking the ring
            var ab: [160]u8 = undefined;
            const an = t.kbTakeAnnouncement(&ab);
            if (an > 0) store.pushNarr(ab[0..an]);
        }
        tray.pump();
        pumpTray(&store, &tray, gpa);
        syncThemeFromStore(&store);
        if (!auto_selected) auto_selected = autoSelect(&store);
        sim_ticks += 1;
        // Command-approval controls must work WHILE the chat is busy (a parked shell command holds the turn),
        // so ::approve/::bypass/::deny bypass the !busy gate below. Dropped as their own SIM.txt; inert in real use.
        if (store.console_pending) {
            var ddb2: [512]u8 = undefined;
            store.lock();
            const dd2 = store.settings.dataDir();
            const ddn2 = @min(dd2.len, ddb2.len);
            @memcpy(ddb2[0..ddn2], dd2[0..ddn2]);
            store.unlock();
            var pb2: [640]u8 = undefined;
            if (std.fmt.bufPrint(&pb2, "{s}/.veil-desk/SIM.txt", .{ddb2[0..ddn2]})) |p2| {
                if (std.Io.Dir.cwd().readFileAlloc(io, p2, gpa, .limited(64))) |c2| {
                    defer gpa.free(c2);
                    const m2 = std.mem.trim(u8, c2, " \r\n\t");
                    if (std.mem.eql(u8, m2, "::approve")) {
                        std.Io.Dir.cwd().deleteFile(io, p2) catch {};
                        store.pushChatCmd(store_mod.mkChatCmd(.console_approve, "once", ""));
                    } else if (std.mem.eql(u8, m2, "::bypass")) {
                        std.Io.Dir.cwd().deleteFile(io, p2) catch {};
                        store.pushChatCmd(store_mod.mkChatCmd(.console_approve, "always", ""));
                    } else if (std.mem.eql(u8, m2, "::deny")) {
                        std.Io.Dir.cwd().deleteFile(io, p2) catch {};
                        store.pushChatCmd(store_mod.mkChatCmd(.console_deny, "veil", ""));
                    }
                } else |_| {}
            } else |_| {}
        }
        if (online0 and !busy0 and sim_ticks >= 30) { // ~1s cadence, only fire when connected AND idle
            sim_ticks = 0;
            var ddb: [512]u8 = undefined;
            store.lock();
            const dd = store.settings.dataDir();
            const ddn = @min(dd.len, ddb.len);
            @memcpy(ddb[0..ddn], dd[0..ddn]);
            store.unlock();
            var pathb: [640]u8 = undefined;
            const path = std.fmt.bufPrint(&pathb, "{s}/.veil-desk/SIM.txt", .{ddb[0..ddn]}) catch "";
            if (path.len > 0) {
                if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8000))) |content| {
                    defer gpa.free(content);
                    std.Io.Dir.cwd().deleteFile(io, path) catch {}; // consume immediately — never double-send
                    const msg = std.mem.trim(u8, content, " \r\n\t");
                    if (msg.len > 0) {
                        sim_mode = true;
                        // DEV/TEST control: a line beginning with `::` steers the UI headlessly (switch tabs,
                        // toggle the auto-loop) instead of sending a chat message — for automated verification
                        // when synthetic clicks can't reach a borderless window. Only reachable by dropping
                        // SIM.txt, which a normal user never does, so it's inert in real use.
                        if (std.mem.startsWith(u8, msg, "::")) {
                            const cmd = std.mem.trim(u8, msg[2..], " \r\n\t");
                            if (std.mem.eql(u8, cmd, "loop on")) {
                                store.chat_loop = true;
                                store.pushChatCmd(store_mod.mkChatCmd(.loop_kick, "", ""));
                            } else if (std.mem.eql(u8, cmd, "loop afk")) {
                                // third tier (UI: double-click the toggle): the loop never backs itself out
                                store.chat_loop = true;
                                store.chat_loop_afk = true;
                                store.pushChatCmd(store_mod.mkChatCmd(.loop_kick, "", ""));
                            } else if (std.mem.eql(u8, cmd, "loop off")) {
                                store.chat_loop = false;
                                store.chat_loop_afk = false;
                            } else if (std.mem.startsWith(u8, cmd, "tab ")) {
                                const tn = std.mem.trim(u8, cmd[4..], " \r\n\t");
                                if (std.mem.eql(u8, tn, "deploy")) {
                                    gotoDeploy(); // deploy is the Swarm tab's inner form now — "tab deploy" still lands there
                                } else {
                                    const tv: ?Tab =
                                        if (std.mem.eql(u8, tn, "dashboard")) .dashboard else if (std.mem.eql(u8, tn, "chat")) .chat else if (std.mem.eql(u8, tn, "swarm")) .swarm else if (std.mem.eql(u8, tn, "hub")) .hub else if (std.mem.eql(u8, tn, "scheduled")) .scheduled else if (std.mem.eql(u8, tn, "tasks")) .scheduled else if (std.mem.eql(u8, tn, "settings")) .settings else null;
                                    if (tv) |v| setTab(v);
                                }
                            } else if (std.mem.startsWith(u8, cmd, "right ")) {
                                // switch the right pane's inner tab (Swarm activity | Memory) for headless verification
                                const rn = std.mem.trim(u8, cmd[6..], " \r\n\t");
                                if (std.mem.eql(u8, rn, "memory")) ui.right_tab = .memory else if (std.mem.eql(u8, rn, "activity")) ui.right_tab = .activity;
                            } else if (std.mem.startsWith(u8, cmd, "trace ")) {
                                // function-entry tracing toggle for a diagnosis session (default OFF — the
                                // per-second trace volume kept the log flusher writing to disk forever)
                                const v = std.mem.trim(u8, cmd[6..], " \r\n\t");
                                log.setTraceEnabled(std.mem.eql(u8, v, "on"));
                            } else if (std.mem.startsWith(u8, cmd, "speed ")) {
                                // headless speed-mode toggle for automated verification
                                const v = std.mem.trim(u8, cmd[6..], " \r\n\t");
                                store.lock();
                                store.settings.speed_mode = std.mem.eql(u8, v, "on");
                                store.unlock();
                                store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
                            } else if (std.mem.eql(u8, cmd, "newconv")) {
                                // start a FRESH conversation headlessly (clean build dir, no prior history)
                                setTab(.chat);
                                store.pushChatCmd(store_mod.mkChatCmd(.new_conv, "", ""));
                            } else if (std.mem.startsWith(u8, cmd, "conv ")) {
                                // select a conversation by id (headless verification of OLD chats — e.g.
                                // re-driving a post-cast conversation; same path as clicking it in the list)
                                const cid = std.mem.trim(u8, cmd[5..], " \r\n\t");
                                if (cid.len > 0) {
                                    setTab(.chat);
                                    store.pushChatCmd(store_mod.mkChatCmd(.select_conv, cid, ""));
                                }
                            } else if (std.mem.eql(u8, cmd, "approve")) {
                                store.pushChatCmd(store_mod.mkChatCmd(.console_approve, "once", "")); // headless: approve a parked command
                            } else if (std.mem.eql(u8, cmd, "bypass")) {
                                store.pushChatCmd(store_mod.mkChatCmd(.console_approve, "always", ""));
                            } else if (std.mem.eql(u8, cmd, "deny")) {
                                store.pushChatCmd(store_mod.mkChatCmd(.console_deny, "veil", ""));
                            } else if (std.mem.startsWith(u8, cmd, "pat ")) {
                                // seal the GitHub token. It rides in the command's TEXT field (not id) so
                                // mkChatCmd's trace logs only its length — the token never hits the log or
                                // the transcript. The SIM.txt message itself is consumed (deleted) as usual.
                                const tok = std.mem.trim(u8, cmd[4..], " \r\n\t");
                                if (tok.len > 0) store.pushChatCmd(store_mod.mkChatCmd(.set_github_pat, "", tok));
                            } else if (std.mem.startsWith(u8, cmd, "ghuser ")) {
                                const usr = std.mem.trim(u8, cmd[7..], " \r\n\t");
                                if (usr.len > 0) store.pushChatCmd(store_mod.mkChatCmd(.set_github_user, "", usr));
                            } else if (std.mem.eql(u8, cmd, "adopt")) {
                                // headless: accept the FIRST pending judge proposal (same path as the
                                // Memory pane's keep button — test harness only, inert in real use)
                                var tag = [1]u8{'0'};
                                var txt: [420]u8 = undefined;
                                var tl: usize = 0;
                                {
                                    store.lock();
                                    defer store.unlock();
                                    if (store.chat_prop_count > 0) {
                                        const p0 = &store.chat_props[0];
                                        tag[0] = '0' + p0.scope;
                                        tl = p0.text_len;
                                        @memcpy(txt[0..tl], p0.text[0..tl]);
                                    }
                                }
                                if (tl > 0) store.pushChatCmd(store_mod.mkChatCmd(.prop_accept, tag[0..1], txt[0..tl]));
                            }
                            log.info("SIM.txt control command: {s}", .{cmd});
                        } else {
                            setTab(.chat); // land on Chat so the run is visible
                            store.pushChatCmd(store_mod.mkChatCmd(.send, "", msg));
                            log.info("SIM.txt auto-sent chat message ({d} bytes)", .{msg.len});
                        }
                    }
                } else |_| {}
            }
        }
        handleWindowChrome();
        handleKeys(&store);

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(t.bg);

        drawTitlebar(&store);
        drawTabbar(&store);
        const top = TITLE_H + TAB_H;
        const body = t.Rect{ .x = 0, .y = top, .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight() - top) };
        switch (ui.tab) {
            .dashboard => drawDashboard(&store, body),
            .chat => drawChat(&store, body),
            .swarm => drawSwarm(&store, body),
            .hub => drawHub(body),
            .scheduled => drawScheduled(&store, body),
            .settings => drawSettings(&store, body),
        }
        drawResizeGrip();
        if (ui.file_menu) drawFileMenu(&store);
        drawToasts(&store);
        if (ui.show_log) drawLogOverlay();
        t.applyCursor(); // one OS-cursor update per frame: pointer over buttons, I-beam over inputs
    }
}

fn setField(f: *Ui.Field, s: []const u8) void {
    const n = @min(s.len, f.buf.len);
    @memcpy(f.buf[0..n], s[0..n]);
    f.len = n;
    f.cur = n;
    f.sel = null;
}

fn drawLogOverlay() void {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());
    const r = t.Rect{ .x = 8, .y = TITLE_H + TAB_H + 8, .width = sw - 16, .height = sh - TITLE_H - TAB_H - 16 };
    rl.drawRectangleRounded(r, 0.02, 6, t.withAlpha(t.bg_dark, 245));
    t.panelBordered(r, t.withAlpha(t.bg_dark, 0), t.blue);
    t.text(t.z("debug log  (F12 to close)  -  also written to <data>/veil-desk.log", .{}), @intFromFloat(r.x + 12), @intFromFloat(r.y + 8), 13, t.comment);
    var lines: [200]log.Line = undefined;
    const n = log.snapshot(&lines);
    const rows: usize = @intFromFloat((r.height - 40) / 16);
    const start = if (n > rows) n - rows else 0;
    var yy: f32 = r.y + 30;
    var i: usize = start;
    while (i < n) : (i += 1) {
        const c = switch (lines[i].level) {
            .err => t.red,
            .warn => t.yellow,
            .dbg => t.comment,
            else => t.fg_dim,
        };
        t.textMonoClip(lines[i].str(), @intFromFloat(r.x + 12), @intFromFloat(yy), 13, c, @intFromFloat(r.width - 24));
        yy += 16;
    }
}

// -------------------------------------------------------------------------------- window chrome

fn handleWindowChrome() void {
    const mp = rl.getMousePosition();
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    // resize grip (bottom-right 18px)
    const grip = t.Rect{ .x = sw - 18, .y = @as(f32, @floatFromInt(rl.getScreenHeight())) - 18, .width = 18, .height = 18 };
    if (rl.checkCollisionPointRec(mp, grip) or ui.resizing) t.wantCursor(.resize_nwse);
    if (rl.isMouseButtonPressed(.left) and rl.checkCollisionPointRec(mp, grip)) ui.resizing = true;
    if (ui.resizing) {
        if (rl.isMouseButtonDown(.left)) {
            const d = rl.getMouseDelta();
            const nw = @max(760, rl.getScreenWidth() + @as(i32, @intFromFloat(d.x)));
            const nh = @max(520, rl.getScreenHeight() + @as(i32, @intFromFloat(d.y)));
            rl.setWindowSize(nw, nh);
            ui.win_max = false; // a manual resize means we're no longer "fullscreen"
        } else ui.resizing = false;
    }
    // title-bar drag (empty zone only: not over window controls, File, or the theme selector — the SAME
    // rects drawTitlebar renders, so the drag zone stays in sync with the pixels)
    const over_file = rl.checkCollisionPointRec(mp, tbFileRect());
    const over_theme = rl.checkCollisionPointRec(mp, tbThemeRect());
    const in_title = mp.y >= 0 and mp.y < TITLE_H and mp.x < sw - 142 and !(over_file or over_theme);
    if (rl.isMouseButtonPressed(.left) and in_title and !ui.resizing) {
        ui.dragging = true;
        ui.win_max = false; // dragging undocks a fullscreen window
        const g = rl.getMousePosition(); // remember WHERE on the title bar we grabbed
        ui.drag_grab_x = g.x;
        ui.drag_grab_y = g.y;
    }
    if (ui.dragging) {
        if (rl.isMouseButtonDown(.left)) {
            // Absolute tracking: keep the grabbed point under the cursor. getMouseDelta() is window-relative,
            // and moving the window shifts the mouse's window coords, corrupting the delta into a jitter loop.
            // screen_mouse = windowPos + mousePos; new = screen_mouse - grab.
            const p = rl.getWindowPosition();
            const m = rl.getMousePosition();
            rl.setWindowPosition(@intFromFloat(p.x + m.x - ui.drag_grab_x), @intFromFloat(p.y + m.y - ui.drag_grab_y));
        } else ui.dragging = false;
    }
}

/// Toggle the window between its normal rect and filling the current monitor ("fullscreen"). The window is
/// undecorated so rl.maximizeWindow() is unreliable across platforms — we drive size/pos ourselves and remember
/// the pre-maximize rect to restore it. The self-drawn titlebar (incl. this button) stays visible at the top.
fn toggleMaximize() void {
    if (!ui.win_max) {
        const p = rl.getWindowPosition();
        ui.saved_x = @intFromFloat(p.x);
        ui.saved_y = @intFromFloat(p.y);
        ui.saved_w = rl.getScreenWidth();
        ui.saved_h = rl.getScreenHeight();
        const mon = rl.getCurrentMonitor();
        const mp = rl.getMonitorPosition(mon);
        rl.setWindowPosition(@intFromFloat(mp.x), @intFromFloat(mp.y));
        rl.setWindowSize(rl.getMonitorWidth(mon), rl.getMonitorHeight(mon));
        ui.win_max = true;
    } else {
        rl.setWindowPosition(ui.saved_x, ui.saved_y);
        rl.setWindowSize(@max(760, ui.saved_w), @max(520, ui.saved_h));
        ui.win_max = false;
    }
}

fn drawTitlebar(store: *Store) void {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    t.fillRect(0, 0, @intFromFloat(sw), TITLE_H, t.bg_dark);
    t.hline(0, TITLE_H - 1, @intFromFloat(sw), t.border);
    // mark + wordmark (just "veil")
    t.drawMark(18, TITLE_H / 2, 9, false);
    t.text(t.z("veil", .{}), 32, (TITLE_H - 15) / 2, 15, t.fg);
    // File menu button (rect shared with handleWindowChrome so the drag zone matches the pixels)
    const fr = tbFileRect();
    if (t.hovering(fr) or ui.file_menu) t.panel(fr, t.bg_hl);
    const fw = t.measure(t.z("File", .{}), 13);
    t.text(t.z("File", .{}), @intFromFloat(fr.x + (fr.width - @as(f32, @floatFromInt(fw))) / 2), @intFromFloat(fr.y + (fr.height - 13) / 2), 13, if (t.hovering(fr) or ui.file_menu) t.fg else t.fg_dim);
    if (t.hovering(fr)) t.wantCursor(.pointing_hand);
    if (t.hovering(fr) and rl.isMouseButtonPressed(.left)) ui.file_menu = !ui.file_menu;

    // Theme selector beside File
    const tr = tbThemeRect();
    const scheme_now = t.getScheme();
    const theme_hot = t.hovering(tr);
    if (theme_hot) t.panel(tr, t.bg_hl);
    t.text(if (scheme_now == .light) t.z("Theme: Light", .{}) else t.z("Theme: Dark", .{}), @intFromFloat(tr.x + 10), @intFromFloat(tr.y + (tr.height - 12) / 2), 12, if (theme_hot) t.fg else t.fg_dim);
    if (theme_hot) t.wantCursor(.pointing_hand);
    if (theme_hot and rl.isMouseButtonPressed(.left)) {
        const next: t.Scheme = if (scheme_now == .dark) .light else .dark;
        t.setScheme(next);
        store.lock();
        store.settings.theme = @intFromEnum(next);
        store.unlock();
        store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
    }

    // right: server status + minimize + maximize/restore + close  (3 buttons = 138px flush-right)
    store.lock();
    const online = store.server_online;
    const minds = store.fleet_minds;
    store.unlock();
    // Down is an ALARM state, not a shade of grey: the muted "offline" read as a stale-but-fine chip while
    // every request was actually failing — say "server down" in red so a dead control plane is unmissable.
    const label = if (online) t.z("online   {d} minds", .{minds}) else t.z("server down", .{});
    const lw = t.measure(label, 12);
    const lx = sw - @as(f32, @floatFromInt(lw)) - 154;
    t.statusDot(@intFromFloat(lx - 11), TITLE_H / 2, if (online) t.green else t.red);
    t.text(label, @intFromFloat(lx), (TITLE_H - 12) / 2, 12, if (online) t.green else t.red);

    const minb = t.Rect{ .x = sw - 138, .y = 0, .width = 46, .height = TITLE_H };
    const maxb = t.Rect{ .x = sw - 92, .y = 0, .width = 46, .height = TITLE_H };
    const clsb = t.Rect{ .x = sw - 46, .y = 0, .width = 46, .height = TITLE_H };
    if (t.winButton(minb, t.z("_", .{}), false)) rl.minimizeWindow();
    // "[]" = go fullscreen; "><" = shrink back to the previous size (glyphs are ASCII — foldAscii drops Unicode).
    if (t.winButton(maxb, if (ui.win_max) t.z("><", .{}) else t.z("[]", .{}), false)) toggleMaximize();
    if (t.winButton(clsb, t.z("x", .{}), true)) ui.close_req = true;
}

fn drawFileMenu(store: *Store) void {
    const items = [_][:0]const u8{ t.z("New swarm", .{}), t.z("Refresh now", .{}), t.z("Open data folder", .{}), t.z("Quit", .{}) };
    const w: f32 = 190;
    const ih: f32 = 32;
    const fr = tbFileRect();
    const r = t.Rect{ .x = fr.x, .y = TITLE_H, .width = w, .height = ih * items.len + 12 };
    t.panelBordered(r, t.bg_dark, t.border);
    // click-away closes
    if (rl.isMouseButtonPressed(.left) and !t.hovering(r) and !t.hovering(fr)) ui.file_menu = false;
    var yy = r.y + 6;
    for (items, 0..) |it, i| {
        const ir = t.Rect{ .x = r.x + 6, .y = yy, .width = w - 12, .height = ih };
        const hot = t.hovering(ir);
        if (hot) {
            t.panel(ir, t.bg_hl);
            t.wantCursor(.pointing_hand);
        }
        t.text(it, @intFromFloat(ir.x + 12), @intFromFloat(ir.y + (ih - 13) / 2), 13, if (i == 3) t.red else t.fg);
        if (hot and rl.isMouseButtonPressed(.left)) {
            ui.file_menu = false;
            switch (i) {
                0 => gotoDeploy(),
                1 => store.pushCmd(store_mod.mkCmd(.refresh_now, "", "")),
                2 => store.pushCmd(store_mod.mkCmd(.open_folder, "", "")),
                3 => ui.close_req = true,
                else => {},
            }
        }
        yy += ih;
    }
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

// ASCII 32..126, PLUS the full Latin-1 supplement (0xA0..0xFF) and the General-Punctuation dashes/quotes.
// LLM-authored goal text is littered with these (non-breaking space 0xA0, non-breaking hyphen 0x2011, …);
// requesting the real codepoints from the TTF renders them as the proper space/dash instead of tofu ('?').
const glyph_set = blk: {
    const extra = [_]i32{ 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x2192, 0x25CF, 0x25CB };
    // Math glyphs so LaTeX-ish formulas render legibly (see mdutil.mathToUnicode): fraction slash, arrows,
    // operators/relations, set symbols, a couple of scattered subscript letters (i j r u v). Greek block and the
    // contiguous super/subscript block are added as ranges below.
    const mathops = [_]i32{ 0x2044, 0x2190, 0x2191, 0x2193, 0x21D2, 0x2202, 0x2207, 0x2208, 0x2209, 0x220F, 0x2211, 0x221A, 0x221D, 0x221E, 0x2229, 0x222A, 0x222B, 0x2248, 0x2260, 0x2261, 0x2264, 0x2265, 0x22C5, 0x25E6, 0x1D62, 0x1D63, 0x1D64, 0x1D65, 0x2C7C };
    const latin1 = 0xFF - 0xA0 + 1; // 0xA0..0xFF inclusive
    const greek = 0x03C9 - 0x0391 + 1; // Greek letters used in math (upper + lower)
    const supsub = 0x209C - 0x2070 + 1; // super/subscript digits, signs, and common subscript letters
    var arr: [95 + latin1 + extra.len + mathops.len + greek + supsub]i32 = undefined;
    var i: usize = 0;
    var c: i32 = 32;
    while (c <= 126) : (c += 1) {
        arr[i] = c;
        i += 1;
    }
    c = 0xA0;
    while (c <= 0xFF) : (c += 1) {
        arr[i] = c;
        i += 1;
    }
    c = 0x0391;
    while (c <= 0x03C9) : (c += 1) {
        arr[i] = c;
        i += 1;
    }
    c = 0x2070;
    while (c <= 0x209C) : (c += 1) {
        arr[i] = c;
        i += 1;
    }
    for (extra) |e| {
        arr[i] = e;
        i += 1;
    }
    for (mathops) |e| {
        arr[i] = e;
        i += 1;
    }
    break :blk arr;
};

// Two fonts: a clean proportional SANS for the UI (Calibri on Windows — modern + rounded, deliberately NOT
// Segoe UI) and a MONOSPACE for the log console so its columns align. Per-OS fallbacks pick the nearest
// clean sans / mono.
fn uiCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "C:/Windows/Fonts/calibri.ttf", "C:/Windows/Fonts/corbel.ttf", "C:/Windows/Fonts/candara.ttf", "C:/Windows/Fonts/segoeui.ttf" },
        .macos => &.{ "/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/HelveticaNeue.ttc", "/Library/Fonts/Arial.ttf" },
        else => &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/liberation/LiberationSans-Regular.ttf" },
    };
}
fn monoCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/lucon.ttf", "C:/Windows/Fonts/cour.ttf" },
        .macos => &.{ "/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Courier.ttc" },
        else => &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/liberation/LiberationMono-Regular.ttf" },
    };
}

/// Bold system faces mirroring uiCandidates — the text-weight setting for the standard face.
fn uiBoldCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "C:/Windows/Fonts/calibrib.ttf", "C:/Windows/Fonts/corbelb.ttf", "C:/Windows/Fonts/candarab.ttf", "C:/Windows/Fonts/segoeuib.ttf" },
        .macos => &.{ "/Library/Fonts/Arial Bold.ttf", "/System/Library/Fonts/HelveticaNeue.ttc" },
        else => &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", "/usr/share/fonts/liberation/LiberationSans-Bold.ttf" },
    };
}

/// Italic system faces mirroring uiCandidates — the chat markdown's *em* spans.
fn uiItalicCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "C:/Windows/Fonts/calibrii.ttf", "C:/Windows/Fonts/corbeli.ttf", "C:/Windows/Fonts/candarai.ttf", "C:/Windows/Fonts/segoeuii.ttf" },
        .macos => &.{ "/Library/Fonts/Arial Italic.ttf", "/System/Library/Fonts/HelveticaNeue.ttc" },
        else => &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf", "/usr/share/fonts/TTF/DejaVuSans-Oblique.ttf", "/usr/share/fonts/liberation/LiberationSans-Italic.ttf" },
    };
}

/// Dyslexia mode's UI face: the BUNDLED OpenDyslexic (SIL OFL; desk/assets/fonts, same relative roots the
/// icon loader probes) first, then system faces on the British Dyslexia Association's recommended list so
/// the mode still helps when the asset is missing (source checkout without assets, other OSes).
fn dyslexiaCandidates(bold: bool) []const [:0]const u8 {
    if (bold) return &.{
        "assets/fonts/OpenDyslexic3-Bold.ttf",
        "desk/assets/fonts/OpenDyslexic3-Bold.ttf",
        "../assets/fonts/OpenDyslexic3-Bold.ttf",
        "../desk/assets/fonts/OpenDyslexic3-Bold.ttf",
        "C:/Windows/Fonts/comicbd.ttf",
        "C:/Windows/Fonts/verdanab.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    };
    return &.{
        "assets/fonts/OpenDyslexic3-Regular.ttf",
        "desk/assets/fonts/OpenDyslexic3-Regular.ttf",
        "../assets/fonts/OpenDyslexic3-Regular.ttf",
        "../desk/assets/fonts/OpenDyslexic3-Regular.ttf",
        "C:/Windows/Fonts/comic.ttf",
        "C:/Windows/Fonts/verdana.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    };
}

var font_dyslexia_applied: bool = false; // what the loaded UI atlas currently is (frame loop reconciles)
var font_bold_applied: bool = false;

/// (Re)load the proportional UI font per the accessibility settings and hand it to the theme, which also
/// derives the face's optical-size compensation (OpenDyslexic's glyphs are ~2/3 of Calibri's at the same
/// px — uncompensated, dyslexia mode rendered unreadably small). GL texture work — RENDER THREAD ONLY.
/// On load failure the current font stays (the caller records the attempt so a missing bold file can't
/// turn into a per-frame retry storm).
fn applyUiFont(dyslexia: bool, bold: bool) void {
    const cands = if (dyslexia) dyslexiaCandidates(bold) else if (bold) uiBoldCandidates() else uiCandidates();
    if (loadFontAt(cands, 48)) |f| {
        var fm = f;
        rl.genTextureMipmaps(&fm.texture);
        rl.setTextureFilter(fm.texture, .trilinear);
        const comp = t.swapFont(fm);
        log.info("ui font applied (dyslexia={} bold={}) glyphs={d} comp={d:.2}", .{ dyslexia, bold, fm.glyphCount, comp });
    } else {
        log.warn("ui font load FAILED (dyslexia={} bold={}) - keeping the current font", .{ dyslexia, bold });
    }
}
fn loadFontAt(candidates: []const [:0]const u8, size: i32) ?rl.Font {
    for (candidates) |path| {
        if (rl.loadFontEx(path, size, glyph_set[0..])) |f| {
            if (f.glyphCount > 0) return f;
        } else |_| {}
    }
    return null;
}

/// Mipmaps + trilinear on a freshly loaded face — the same multi-size crispness recipe the base fonts use.
fn prepFont(f: rl.Font) rl.Font {
    var fm = f;
    rl.genTextureMipmaps(&fm.texture);
    rl.setTextureFilter(fm.texture, .trilinear);
    return fm;
}

/// (Re)load the chat markdown's STRONG + EM variant faces to match the active UI face. Regular face: the
/// system bold + italic variants. Weight setting ON: the base face IS already bold, so strong keeps the
/// bold file but renders double-struck (setStrongDistinct(false)) to keep a visible emphasis step.
/// Dyslexia mode: the bundled OpenDyslexic bold for strong and NO italic — slanted glyphs hurt exactly the
/// readers that mode serves, so *em* stays upright there. GL texture work — RENDER THREAD ONLY.
fn applyChatVariantFonts(dyslexia: bool, bold: bool) void {
    var strong: ?rl.Font = null;
    var em: ?rl.Font = null;
    if (dyslexia) {
        if (loadFontAt(dyslexiaCandidates(true), 48)) |f| strong = prepFont(f);
    } else {
        if (loadFontAt(uiBoldCandidates(), 48)) |f| strong = prepFont(f);
        if (loadFontAt(uiItalicCandidates(), 48)) |f| em = prepFont(f);
    }
    t.swapStrong(strong);
    t.swapEm(em);
    t.setStrongDistinct(strong != null and !bold);
    log.info("chat variant fonts (dyslexia={} bold={}): strong={} em={}", .{ dyslexia, bold, strong != null, em != null });
}

fn makeIcon() rl.Image {
    const candidates = [_][:0]const u8{
        "assets/icon.png",
        "desk/assets/icon.png",
        "../assets/icon.png",
        "../desk/assets/icon.png",
    };
    for (candidates) |path| {
        if (rl.loadImage(path)) |img| return img else |_| {}
    }

    var img = rl.genImageColor(64, 64, .{ .r = 0x1a, .g = 0x1b, .b = 0x26, .a = 255 });
    const mag = rl.Color{ .r = 0xbb, .g = 0x9a, .b = 0xf7, .a = 255 };
    // agent bust: broad shoulders (wider than head) + head — the person silhouette, not a padlock.
    rl.imageDrawRectangle(&img, 12, 36, 40, 22, mag);
    rl.imageDrawCircle(&img, 32, 26, 13, mag);
    return img;
}

fn syncThemeFromStore(store: *Store) void {
    store.lock();
    const theme = store.settings.theme;
    store.unlock();
    t.setSchemeFromInt(theme);
}

fn seedName(buf: []u8) usize {
    const s = "swarm";
    @memcpy(buf[0..s.len], s);
    return s.len;
}

fn seedSettings(store: *Store, gpa: std.mem.Allocator, io: std.Io) void {
    seedChatDefaults(store);
    const candidates = [_][]const u8{ "data", "../data", "../../data", "../nl-veil/data" };
    for (candidates) |c| {
        if (dirExists(io, c)) {
            setDataDir(store, c);
            loadDesktopKey(store, gpa, io, c);
            return;
        }
    }
    setDataDir(store, "data");
    loadDesktopKey(store, gpa, io, "data");
}

/// Chat provider defaults: local Ollama + the catalog's local default model. The chat thread overwrites
/// these with the persisted .veil-desk/settings.json right after it starts.
fn seedChatDefaults(store: *Store) void {
    store.lock();
    defer store.unlock();
    const s = &store.settings;
    s.chat_kind = 0;
    const model = catalog.defaults.local_model; // the catalog's local default (models.yaml)
    const n = @min(model.len, s.chat_model.len);
    @memcpy(s.chat_model[0..n], model[0..n]);
    s.chat_model_len = @intCast(n);
}

/// Auto-load the admin API key the server dropped at <data>/.desktop_key so Deploy works with no manual
/// paste. The desktop is a same-machine companion; the key is the server's own local admin key.
fn loadDesktopKey(store: *Store, gpa: std.mem.Allocator, io: std.Io, dd: []const u8) void {
    const path = std.fmt.allocPrint(gpa, "{s}/.desktop_key", .{dd}) catch return;
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256)) catch return;
    defer gpa.free(data);
    const key = std.mem.trim(u8, data, " \r\n\t");
    if (key.len == 0) return;
    store.lock();
    defer store.unlock();
    const n = @min(key.len, store.settings.token.len);
    @memcpy(store.settings.token[0..n], key[0..n]);
    store.settings.token_len = @intCast(n);
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
    var notify_on = store.settings.notify;
    tray.setNotifyEnabled(notify_on);
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

    while (true) {
        switch (tray.takeMenuAction()) {
            .none => break,
            .open_settings => {
                rl.restoreWindow();
                ui.tab = .settings;
                ui.focus = .none;
            },
            .toggle_notifications => {
                store.lock();
                store.settings.notify = !store.settings.notify;
                const now_on = store.settings.notify;
                store.unlock();
                tray.setNotifyEnabled(now_on);
                notify_on = now_on;
                if (now_on) tray.notify(gpa, "veil-desk", "Notifications enabled", 0);
            },
            .refresh_now => store.pushCmd(store_mod.mkCmd(.refresh_now, "", "")),
            .quit => ui.close_req = true,
        }
    }

    if (!notify_on) return;
    var k: usize = 0;
    while (k < send_n) : (k += 1) tray.notify(gpa, to_send[k].titleStr(), to_send[k].bodyStr(), to_send[k].accent);
}

// -------------------------------------------------------------------------------- input

/// Switch tabs from ANY input path (digit shortcut or tab click). Resetting open_dd here keeps a dropdown
/// opened on one tab from bleeding onto — or silently blocking every text field of — the next tab (a stray
/// open dropdown wedges focus, and thus Ctrl+V/Ctrl+C, which only run on the focused field). Landing focus
/// in the chat input on the way into Chat lets the app be driven from the keyboard. When a digit key triggers
/// the switch, that keypress also queued a character; swallow it so "2" doesn't type a literal '2' into the
/// input it just focused.
fn setTab(tabv: Tab) void {
    ui.tab = tabv;
    ui.open_dd = .none;
    ui.focus = if (tabv == .chat) .c_input else .none;
    if (tabv == .chat) while (rl.getCharPressed() > 0) {}; // drain the trigger digit; don't type it into the field
}

/// Jump to the deploy form — an INNER tab of Swarm (there is no Deploy top tab anymore).
fn gotoDeploy() void {
    setTab(.swarm);
    ui.swarm_inner = .deploy;
}

fn handleKeys(store: *Store) void {
    // any handled shortcut counts as activity so the redraw stays at 60fps for a beat (see the FPS gate)
    if (rl.isKeyPressed(.f12) or rl.isKeyPressed(.one) or rl.isKeyPressed(.two) or rl.isKeyPressed(.three) or
        rl.isKeyPressed(.four) or rl.isKeyPressed(.five) or rl.isKeyPressed(.six) or rl.isKeyPressed(.seven) or
        rl.isKeyPressed(.enter) or rl.isKeyPressed(.escape) or rl.isKeyPressed(.tab) or rl.isKeyDown(.left_control)) ui.input_active = true;
    if (rl.isKeyPressed(.f12)) ui.show_log = !ui.show_log; // debug log overlay
    if (ui.focus == .none) {
        if (rl.isKeyPressed(.one)) setTab(.dashboard);
        if (rl.isKeyPressed(.two)) setTab(.chat);
        if (rl.isKeyPressed(.three)) setTab(.scheduled);
        if (rl.isKeyPressed(.four)) setTab(.swarm);
        if (rl.isKeyPressed(.five)) setTab(.hub);
        if (rl.isKeyPressed(.six)) setTab(.settings);
        if (rl.isKeyPressed(.seven)) gotoDeploy(); // deploy lives inside Swarm now
    }
    // Keyboard copy — ONE priority chain, NOT gated on focus (the Chat tab force-focuses the prompt input and
    // clicks never clear focus, so a focus gate would make "select text, Ctrl+C" copy the empty input instead):
    //   1. the focused field's OWN selection (Ctrl+A in a field must beat a stale transcript drag)
    //   2. a transcript select-all (Ctrl+A outside a field selection)   3. an active drag-selection
    //   4. Ctrl+Shift+C → the WHOLE conversation   5. the focused field's text   6. the LAST veil answer
    {
        const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        // Ctrl+A on the chat TRANSCRIPT (no field content to select) = select the whole conversation —
        // the standard chat-app read of select-all. In a field with text, editField's Ctrl+A wins.
        if (ctrl and rl.isKeyPressed(.a) and ui.tab == .chat and ui.chat_inner == .chat) {
            const field_has_text = if (focusedField()) |f| f.len > 0 else false;
            if (!field_has_text) {
                ui.conv_selected = true;
                store.pushNotif("Conversation selected", "Ctrl+C copies the whole conversation", 0);
            }
        }
        if (rl.isMouseButtonPressed(.left)) ui.conv_selected = false; // any click drops the select-all
        if (ctrl and rl.isKeyPressed(.c)) {
            const field_sel: ?[2]usize = if (focusedField()) |f| f.selRange() else null;
            if (field_sel) |rg| {
                const f = focusedField().?;
                copyToClipboard(f.buf[rg[0]..rg[1]]);
                markCopied();
            } else if (ui.conv_selected) {
                copyConversation(store);
                ui.conv_selected = false;
            } else if (ui.tab == .chat and ui.chat_inner == .chat and sel_text_len > 0) {
                copyToClipboard(sel_text[0..sel_text_len]);
                markCopied();
            } else if (shift) {
                copyConversation(store);
            } else if (focusedField()) |f| {
                if (f.len > 0) copyToClipboard(f.str());
            } else {
                var last: ?store_mod.ChatMsg = null;
                store.lock();
                var i: usize = store.msg_count;
                while (i > 0) {
                    i -= 1;
                    if (store.msgs[i].role == .veil) {
                        last = store.msgs[i];
                        break;
                    }
                }
                store.unlock();
                if (last) |m| if (m.textStr().len > 0) copyToClipboard(m.textStr());
            }
        }
    }
    if (focusedField()) |f| editField(f);
    if (rl.isKeyPressed(.escape)) {
        ui.focus = .none;
        ui.file_menu = false;
        ui.c_renaming = false;
    }
}

/// The Field owning the keyboard right now (null when no input has focus).
fn focusedField() ?*Ui.Field {
    return switch (ui.focus) {
        .none => null,
        .chat => &ui.chat,
        .d_name => &ui.d_name,
        .d_key => &ui.d_key,
        .d_cfacct => &ui.d_cfacct,
        .d_goal => &ui.d_goal,
        .d_gateway => &ui.d_gateway,
        .c_input => &ui.c_input,
        .c_rename => &ui.c_rename,
        .s_model => &ui.s_model,
        .s_url => &ui.s_url,
        .s_ckey => &ui.s_ckey,
        .s_cfacct => &ui.s_cfacct,
        .s_host => &ui.s_host,
        .s_port => &ui.s_port,
        .con_input => &ui.con_input,
        .sc_name => &ui.sc_name,
        .sc_prompt => &ui.sc_prompt,
        .sc_details => &ui.sc_details,
        .sc_base => &ui.sc_base,
        .sc_model => &ui.sc_model,
        .sc_key => &ui.sc_key,
    };
}

fn editField(f: *Ui.Field) void {
    f.clampCur(); // external writers (setField/seeds) may have moved len under the caret
    const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
    const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
    // Ctrl+V paste — inserts at the caret (replacing any selection).
    if (ctrl and rl.isKeyPressed(.v)) {
        ui.input_active = true;
        _ = f.delSel();
        const clip = rl.getClipboardText();
        for (clip) |raw_ch| {
            // multi-line pastes flatten to spaces instead of being silently dropped
            const ch: u8 = if (raw_ch == '\n' or raw_ch == '\t') ' ' else raw_ch;
            // Accept UTF-8 (any byte >= 128) as well as printable ASCII, so smart quotes, em-dashes, and accents
            // survive a paste. The renderer folds these to ASCII for display, but the field keeps the real bytes
            // to send/copy.
            if (ch >= 32 and ch != 127) {
                if (ch == ' ' and f.cur > 0 and f.buf[f.cur - 1] == ' ' and (raw_ch == '\n' or raw_ch == '\t')) continue;
                f.insert(ch);
            }
        }
    }
    // (Ctrl+C is owned by the one priority chain in handleKeys — selection > conversation > field > last answer.)
    if (ctrl and rl.isKeyPressed(.a) and f.len > 0) { // select all
        f.sel = 0;
        f.cur = f.len;
    }
    if (ctrl and rl.isKeyPressed(.x)) { // cut the selection
        if (f.selRange()) |rg| {
            copyToClipboard(f.buf[rg[0]..rg[1]]);
            markCopied();
            _ = f.delSel();
        }
    }
    var c = rl.getCharPressed();
    while (c > 0) : (c = rl.getCharPressed()) {
        ui.input_active = true; // keep 60fps while typing
        if (c >= 32 and c < 127) {
            _ = f.delSel();
            f.insert(@intCast(c));
        }
    }
    // caret movement: arrows (Ctrl = word jump), Home/End; Shift extends a selection, plain movement drops it
    const kleft = rl.isKeyPressed(.left) or rl.isKeyPressedRepeat(.left);
    const kright = rl.isKeyPressed(.right) or rl.isKeyPressedRepeat(.right);
    const khome = rl.isKeyPressed(.home);
    const kend = rl.isKeyPressed(.end);
    if (kleft or kright or khome or kend) {
        ui.input_active = true;
        const rg = f.selRange();
        if (shift and f.sel == null) f.sel = f.cur;
        if (kleft) {
            if (!shift and rg != null) f.cur = rg.?[0] else if (ctrl) f.cur = wordJumpLeft(f) else f.cur = f.prevCp(f.cur);
        }
        if (kright) {
            if (!shift and rg != null) f.cur = rg.?[1] else if (ctrl) f.cur = wordJumpRight(f) else f.cur = f.nextCp(f.cur);
        }
        if (khome) f.cur = 0;
        if (kend) f.cur = f.len;
        if (!shift) f.sel = null;
    }
    if ((rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace)) and f.len > 0) {
        ui.input_active = true;
        if (!f.delSel()) f.delBack();
    }
    if ((rl.isKeyPressed(.delete) or rl.isKeyPressedRepeat(.delete)) and f.len > 0) {
        ui.input_active = true;
        if (!f.delSel()) f.delFwd();
    }
}

fn wordJumpLeft(f: *const Ui.Field) usize {
    var i = f.cur;
    while (i > 0 and f.buf[i - 1] == ' ') i -= 1;
    while (i > 0 and f.buf[i - 1] != ' ') i -= 1;
    return i;
}

fn wordJumpRight(f: *const Ui.Field) usize {
    var i = f.cur;
    while (i < f.len and f.buf[i] != ' ') i += 1;
    while (i < f.len and f.buf[i] == ' ') i += 1;
    return i;
}

// -------------------------------------------------------------------------------- tab bar

fn drawTabbar(store: *Store) void {
    _ = store;
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    t.fillRect(0, TITLE_H, @intFromFloat(sw), TAB_H, t.bg_dark);
    t.hline(0, TITLE_H + TAB_H - 1, @intFromFloat(sw), t.border);
    const labels = [_][:0]const u8{ t.z("Dashboard", .{}), t.z("Chat", .{}), t.z("Tasks", .{}), t.z("Swarm", .{}), t.z("Hub", .{}), t.z("Settings", .{}) };
    const tabs = [_]Tab{ .dashboard, .chat, .scheduled, .swarm, .hub, .settings };
    var x: f32 = t.PAD;
    for (labels, tabs) |lb, tabv| {
        const w = t.tabW(lb);
        const r = t.Rect{ .x = x, .y = TITLE_H + 5, .width = w, .height = TAB_H - 10 };
        if (t.tab(r, lb, ui.tab == tabv)) setTab(tabv);
        x += w + 6;
    }
}

// -------------------------------------------------------------------------------- dashboard

fn drawDashboard(store: *Store, body: t.Rect) void {
    const pad: f32 = t.PAD;
    var y: f32 = body.y + pad;
    const x: f32 = pad;
    const colw: f32 = body.width - pad * 2;
    t.text(t.z("Dashboard", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
    y += 38;

    store.lock();
    const online = store.server_online;
    const fl = store.fleet_live;
    const fm = store.fleet_minds;
    const fh = store.fleet_headroom;
    const sc = store.swarm_count;
    const tot_calls = store.llm_tot_calls;
    const tot_in = store.llm_tot_in;
    const tot_out = store.llm_tot_out;
    const tot_secs = store.llm_tot_secs;
    store.unlock();

    // row 1: the live fleet
    const card_w = (colw - 3 * t.GAP) / 4;
    statCard(x + 0 * (card_w + t.GAP), y, card_w, "SERVER", if (online) "online" else "offline", if (online) t.green else t.red);
    statCard(x + 1 * (card_w + t.GAP), y, card_w, "LIVE SWARMS", t.z("{d}", .{fl}), t.cyan);
    statCard(x + 2 * (card_w + t.GAP), y, card_w, "LIVE MINDS", t.z("{d}", .{fm}), t.magenta);
    statCard(x + 3 * (card_w + t.GAP), y, card_w, "HEADROOM", t.z("{d}", .{fh}), if (fh > 0) t.green else t.orange);
    y += 92 + t.GAP;

    // row 2: the LLM lifetime totals (every finished chat/task turn meters here)
    var cb1: [24]u8 = undefined;
    var cb2: [24]u8 = undefined;
    var cb3: [24]u8 = undefined;
    const spd: u64 = if (tot_secs > 0) tot_out / tot_secs else 0;
    statCard(x + 0 * (card_w + t.GAP), y, card_w, "TURNS", t.zs(fmtCount(tot_calls, &cb1)), t.blue);
    statCard(x + 1 * (card_w + t.GAP), y, card_w, "TOKENS IN", t.zs(fmtCount(tot_in, &cb2)), t.cyan);
    statCard(x + 2 * (card_w + t.GAP), y, card_w, "TOKENS OUT", t.zs(fmtCount(tot_out, &cb3)), t.magenta);
    statCard(x + 3 * (card_w + t.GAP), y, card_w, "AVG SPEED", t.z("{d} tok/s", .{spd}), t.green);
    y += 92 + t.PAD;

    // two columns: swarms (left) | client + LLM breakdown + activity (right)
    const right_w = @min(460, colw * 0.42);
    const left_w = colw - right_w - t.PAD;
    const bottom = body.y + body.height - pad;

    const nb_label = t.z("+ New swarm", .{});
    const nb = t.Rect{ .x = x, .y = y, .width = t.btnW(nb_label, t.BTN_MD), .height = t.BTN_MD };
    if (t.buttonSolid(nb, nb_label, t.blue, true)) gotoDeploy();
    t.text(t.z("Swarms ({d})", .{sc}), @intFromFloat(nb.x + nb.width + t.PAD), @intFromFloat(y + (t.BTN_MD - 14) / 2), 14, t.fg_dim);
    const list_r = t.Rect{ .x = x, .y = y + t.BTN_MD + t.GAP, .width = left_w, .height = bottom - y - t.BTN_MD - t.GAP };
    drawRoster(store, list_r);

    // right column: CLIENT panel, then the per-model table, then the 14-day bars filling the rest
    const rx = x + left_w + t.PAD;
    const client_h: f32 = 150;
    drawClientPanel(store, .{ .x = rx, .y = y, .width = right_w, .height = client_h });
    const bars_h: f32 = 118;
    const table_r = t.Rect{ .x = rx, .y = y + client_h + t.GAP, .width = right_w, .height = @max(90, bottom - y - client_h - bars_h - 2 * t.GAP) };
    drawLlmTable(store, table_r);
    drawLlmBars(store, .{ .x = rx, .y = table_r.y + table_r.height + t.GAP, .width = right_w, .height = bars_h });
}

/// "73.7k" / "1.2M" / "412" — token/call counts at dashboard scale.
fn fmtCount(v: u64, buf: []u8) []const u8 {
    if (v >= 1_000_000) return std.fmt.bufPrint(buf, "{d}.{d}M", .{ v / 1_000_000, (v % 1_000_000) / 100_000 }) catch "?";
    if (v >= 1_000) return std.fmt.bufPrint(buf, "{d}.{d}k", .{ v / 1_000, (v % 1_000) / 100 }) catch "?";
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "?";
}

// Win32 memory census for the CLIENT panel (the one OS fact raylib can't provide). Polled at ~1Hz via
// mem_stat — GlobalMemoryStatusEx is cheap but not draw-loop cheap.
const winmem = if (builtin.os.tag == .windows) struct {
    const MEMORYSTATUSEX = extern struct {
        dwLength: u32,
        dwMemoryLoad: u32,
        ullTotalPhys: u64,
        ullAvailPhys: u64,
        ullTotalPageFile: u64,
        ullAvailPageFile: u64,
        ullTotalVirtual: u64,
        ullAvailVirtual: u64,
        ullAvailExtendedVirtual: u64,
    };
    extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.c) i32;
} else struct {};

var mem_stat: struct { total_mb: u64 = 0, avail_mb: u64 = 0, load: u32 = 0, at: f64 = -10 } = .{};
var cached_cores: usize = 0; // queried once on first Dashboard draw

fn refreshMemStat() void {
    if (builtin.os.tag != .windows) return;
    const now = rl.getTime();
    if (now - mem_stat.at < 1.0) return;
    mem_stat.at = now;
    var m: winmem.MEMORYSTATUSEX = undefined;
    m.dwLength = @sizeOf(winmem.MEMORYSTATUSEX);
    if (winmem.GlobalMemoryStatusEx(&m) != 0) {
        mem_stat.total_mb = m.ullTotalPhys >> 20;
        mem_stat.avail_mb = m.ullAvailPhys >> 20;
        mem_stat.load = m.dwMemoryLoad;
    }
}

/// CLIENT — what this machine and session look like right now: OS/arch, cores, physical memory, the desk's
/// uptime, and which server this client is pointed at. The "how is my client running" panel.
fn drawClientPanel(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    t.text(t.z("CLIENT", .{}), @intFromFloat(r.x + 14), @intFromFloat(r.y + 12), 11, t.comment);
    refreshMemStat();

    var host: [64]u8 = undefined;
    var host_n: usize = 0;
    var port: u16 = 0;
    {
        store.lock();
        defer store.unlock();
        const h = store.settings.hostStr();
        host_n = @min(h.len, host.len);
        @memcpy(host[0..host_n], h[0..host_n]);
        port = store.settings.port;
    }
    const up: u64 = @intFromFloat(@max(0, rl.getTime()));
    // core count can't change mid-session — one syscall ever, not one per frame
    if (cached_cores == 0) cached_cores = std.Thread.getCpuCount() catch 0;
    const cores = cached_cores;

    var yy = r.y + 32;
    const lh: f32 = 22;
    clientRow(r, yy, "system", t.z("{s} / {s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }));
    yy += lh;
    clientRow(r, yy, "cpu", t.z("{d} logical cores", .{cores}));
    yy += lh;
    if (mem_stat.total_mb > 0) {
        const used = mem_stat.total_mb - mem_stat.avail_mb;
        clientRow(r, yy, "memory", t.z("{d}.{d} / {d}.{d} GB ({d}%)", .{ used / 1024, (used % 1024) / 103, mem_stat.total_mb / 1024, (mem_stat.total_mb % 1024) / 103, mem_stat.load }));
    } else {
        clientRow(r, yy, "memory", t.z("-", .{}));
    }
    yy += lh;
    clientRow(r, yy, "desk uptime", t.z("{d}h {d}m", .{ up / 3600, (up % 3600) / 60 }));
    yy += lh;
    clientRow(r, yy, "server", t.z("{s}:{d}", .{ if (host_n > 0) host[0..host_n] else "127.0.0.1", port }));
}

fn clientRow(r: t.Rect, y: f32, label: []const u8, value: []const u8) void {
    t.textClip(label, @intFromFloat(r.x + 14), @intFromFloat(y), 12, t.comment, 110);
    t.textClip(value, @intFromFloat(r.x + 130), @intFromFloat(y), 12, t.fg, @intFromFloat(r.width - 144));
}

/// LLM BREAKDOWN — one row per (model, provider host): calls, tokens in/out, and the observed generation
/// speed (out-tokens / summed turn seconds). Busiest first (server pre-sorts).
fn drawLlmTable(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    t.text(t.z("LLM BREAKDOWN", .{}), @intFromFloat(r.x + 14), @intFromFloat(r.y + 12), 11, t.comment);
    store.lock();
    var rows: [store_mod.MAX_LLM_MODELS]store_mod.LlmModelRow = undefined;
    const n = store.llm_model_count;
    @memcpy(rows[0..n], store.llm_models[0..n]);
    const seen = store.llm_seen;
    store.unlock();

    if (n == 0) {
        const msg = if (seen) t.z("no LLM usage yet - run a chat or a task", .{}) else t.z("fetching usage...", .{});
        t.text(msg, @intFromFloat(r.x + 14), @intFromFloat(r.y + 34), 12, t.comment);
        return;
    }
    // column layout: model+host flexes; the numbers hold fixed right-aligned-ish slots
    const cx_calls = r.x + r.width - 210;
    const cx_in = r.x + r.width - 162;
    const cx_out = r.x + r.width - 108;
    const cx_spd = r.x + r.width - 56;
    var yy = r.y + 32;
    t.text(t.z("calls", .{}), @intFromFloat(cx_calls), @intFromFloat(yy), 11, t.comment);
    t.text(t.z("in", .{}), @intFromFloat(cx_in), @intFromFloat(yy), 11, t.comment);
    t.text(t.z("out", .{}), @intFromFloat(cx_out), @intFromFloat(yy), 11, t.comment);
    t.text(t.z("tok/s", .{}), @intFromFloat(cx_spd), @intFromFloat(yy), 11, t.comment);
    yy += 18;
    rl.beginScissorMode(@intFromFloat(r.x), @intFromFloat(yy - 2), @intFromFloat(r.width), @intFromFloat(r.y + r.height - yy));
    defer rl.endScissorMode();
    for (rows[0..n]) |*m| {
        if (yy > r.y + r.height - 14) break;
        t.textClip(m.modelStr(), @intFromFloat(r.x + 14), @intFromFloat(yy), 12, t.fg, @intFromFloat(@max(40, cx_calls - r.x - 22)));
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        var b3: [24]u8 = undefined;
        t.textClip(fmtCount(m.calls, &b1), @intFromFloat(cx_calls), @intFromFloat(yy), 12, t.fg_dim, 44);
        t.textClip(fmtCount(m.tin, &b2), @intFromFloat(cx_in), @intFromFloat(yy), 12, t.cyan, 50);
        t.textClip(fmtCount(m.tout, &b3), @intFromFloat(cx_out), @intFromFloat(yy), 12, t.magenta, 48);
        const spd: u64 = if (m.secs > 0) m.tout / m.secs else 0;
        t.text(t.z("{d}", .{spd}), @intFromFloat(cx_spd), @intFromFloat(yy), 12, t.green);
        yy += 16;
        // the provider host under the model, quieter — the same model id can live on two providers
        if (m.base_len > 0 and yy <= r.y + r.height - 12) {
            t.textClip(m.baseStr(), @intFromFloat(r.x + 14), @intFromFloat(yy), 10, t.withAlpha(t.comment, 180), @intFromFloat(@max(40, cx_calls - r.x - 22)));
            yy += 14;
        }
        yy += 4;
    }
}

/// 14-DAY ACTIVITY — one bar per local day of total tokens moved (in+out), today rightmost. The quick
/// "how hard has this thing been working lately" read.
fn drawLlmBars(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    t.text(t.z("14-DAY ACTIVITY (tokens)", .{}), @intFromFloat(r.x + 14), @intFromFloat(r.y + 12), 11, t.comment);
    store.lock();
    const days = store.llm_days;
    store.unlock();

    var maxv: u64 = 1;
    for (days) |d| {
        const v = d.tin + d.tout;
        if (v > maxv) maxv = v;
    }
    const plot_x = r.x + 14;
    const plot_w = r.width - 28;
    const plot_bot = r.y + r.height - 26;
    const plot_h = plot_bot - (r.y + 32);
    const n: f32 = @floatFromInt(days.len);
    const bw = @max(4, plot_w / n - 4);
    for (days, 0..) |d, i| {
        const v = d.tin + d.tout;
        const h: f32 = if (v == 0) 2 else @max(3, plot_h * @as(f32, @floatFromInt(v)) / @as(f32, @floatFromInt(maxv)));
        const bx = plot_x + @as(f32, @floatFromInt(i)) * (plot_w / n) + 2;
        const col = if (i == days.len - 1) t.green else t.withAlpha(t.cyan, 170); // today pops
        t.fillRect(@intFromFloat(bx), @intFromFloat(plot_bot - h), @intFromFloat(bw), @intFromFloat(h), col);
    }
    // edge labels: the window's first day and "today" (labels stay sparse — the bars carry the story)
    var db: [16]u8 = undefined;
    t.textClip(fmtDayLabel(days[0].day, &db), @intFromFloat(plot_x), @intFromFloat(plot_bot + 6), 10, t.comment, 60);
    t.text(t.z("today", .{}), @intFromFloat(r.x + r.width - 46), @intFromFloat(plot_bot + 6), 10, t.comment);
}

/// Local epoch-day → "M/D" for the bars' left edge label. day 0 (no data yet) → "".
fn fmtDayLabel(day: i64, buf: []u8) []const u8 {
    if (day <= 0) return "";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(day * 86400) };
    const monday = es.getEpochDay().calculateYearDay().calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d}/{d}", .{ monday.month.numeric(), monday.day_index + 1 }) catch "";
}

fn statCard(x: f32, y: f32, w: f32, label: [:0]const u8, value: [:0]const u8, accent: t.Color) void {
    const r = t.Rect{ .x = x, .y = y, .width = w, .height = 92 };
    t.panelBordered(r, t.bg_dark, t.border);
    t.text(label, @intFromFloat(x + 16), @intFromFloat(y + 16), 11, t.comment);
    t.text(value, @intFromFloat(x + 16), @intFromFloat(y + 42), 26, accent);
}

fn drawRoster(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    rl.beginScissorMode(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.width), @intFromFloat(r.height));
    defer rl.endScissorMode();
    store.lock();
    const n = store.swarm_count;
    var rows: [scan.MAX_SWARMS]scan.SwarmSummary = undefined;
    @memcpy(rows[0..n], store.swarms[0..n]);
    var sel: [96]u8 = undefined;
    const sel_n = store.selected_len;
    @memcpy(sel[0..sel_n], store.selected[0..sel_n]);
    const scanned = store.last_refresh_s > 0; // has the poller completed its first pass?
    store.unlock();

    // drop any "deleting…" ids that are no longer in the roster (the delete landed)
    pruneDeleting(rows[0..n]);

    const row_h: f32 = 50;
    var yy: f32 = r.y + 6;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const sw = &rows[idx];
        const rr = t.Rect{ .x = r.x + 6, .y = yy, .width = r.width - 12, .height = row_h - 6 };
        const is_sel = std.mem.eql(u8, sw.idStr(), sel[0..sel_n]);
        const deleting = isDeleting(sw.idStr());
        const hot = t.hovering(rr) and !deleting;
        if (is_sel) t.panel(rr, t.bg_sel) else if (hot) t.panel(rr, t.bg_hl);
        t.statusDot(@intFromFloat(rr.x + 14), @intFromFloat(rr.y + rr.height / 2), if (deleting) t.red else if (sw.live) t.green else if (sw.stopped) t.comment else t.yellow);
        const name_c = if (deleting) t.comment else t.fg;
        // Reserve only ~130px on the right for the round/status columns, so the name stays wide in both the
        // wide dashboard row and the narrow (270px) swarm-tab side panel while clearing the right block.
        const name_w: f32 = @max(48, rr.width - 130);
        t.textClip(sw.nameStr(), @intFromFloat(rr.x + 30), @intFromFloat(rr.y + 7), 14, name_c, @intFromFloat(name_w));
        if (sw.goal_len > 0) t.textClip(sw.goalStr(), @intFromFloat(rr.x + 30), @intFromFloat(rr.y + 26), 12, t.comment, @intFromFloat(name_w));
        // ✕ delete button (right edge, on row hover)
        const xb = t.Rect{ .x = rr.x + rr.width - 30, .y = rr.y + (rr.height - 24) / 2, .width = 24, .height = 24 };
        if (deleting) {
            t.text(t.z("deleting...", .{}), @intFromFloat(rr.x + rr.width - 92), @intFromFloat(rr.y + 26), 11, t.red);
        } else {
            if (hot and t.buttonGhost(xb, t.z("x", .{}), t.red, true)) {
                markDeleting(sw.idStr());
                store.pushCmd(store_mod.mkCmd(.delete, sw.idStr(), ""));
            }
            const pct = sw.pct;
            const rt = if (pct >= 0) t.z("r{d}  {d}%", .{ sw.round, pct }) else t.z("r{d}", .{sw.round});
            const rtw = t.measure(rt, 12);
            const pc = if (pct >= 100) t.green else if (pct >= 50) t.cyan else if (pct >= 0) t.yellow else t.comment;
            t.text(rt, @intFromFloat(rr.x + rr.width - @as(f32, @floatFromInt(rtw)) - 40), @intFromFloat(rr.y + 7), 12, pc);
            const stt = if (sw.stopped) t.z("done", .{}) else if (sw.live) t.z("LIVE", .{}) else t.z("idle", .{});
            t.text(stt, @intFromFloat(rr.x + rr.width - @as(f32, @floatFromInt(t.measure(stt, 11))) - 40), @intFromFloat(rr.y + 26), 11, if (sw.live) t.green else t.comment);
        }
        if (hot and !t.hovering(xb)) t.wantCursor(.pointing_hand);
        if (hot and !t.hovering(xb) and rl.isMouseButtonPressed(.left)) {
            store.pushCmd(store_mod.mkCmd(.select, sw.idStr(), ""));
            ui.tab = .swarm;
        }
        yy += row_h;
        if (yy > r.y + r.height) break;
    }
    if (n == 0) {
        const msg = if (scanned) t.z("no swarms yet - Deploy one", .{}) else t.z("scanning run directories...", .{});
        t.text(msg, @intFromFloat(r.x + t.PAD_IN + 2), @intFromFloat(r.y + t.PAD_IN + 2), 13, t.comment);
    }
}

// -------------------------------------------------------------------------------- chat

const CHAT_LEFT_W: f32 = 230;
const CHAT_RIGHT_W: f32 = 320;
const CHAT_STRIP_W: f32 = 24;

/// The Chat tab: three panes. Left = conversations (create/select/rename/delete, collapsible), center =
/// the message stream + input, right = live swarm-cast activity (collapsible). Pane open state persists
/// via the chat settings file.
fn drawChat(store: *Store, body: t.Rect) void {
    const pad: f32 = 12;

    // copy everything the frame needs under one short lock
    store.lock();
    var convs: [store_mod.MAX_CONVS]store_mod.ConvRow = undefined;
    const conv_n = store.conv_count;
    @memcpy(convs[0..conv_n], store.convs[0..conv_n]);
    // sized FROM the store field (a stale [32] literal here missed the conv-id widening and made selecting
    // any scheduled_* conversation an out-of-bounds render-thread panic — the click-to-view crash)
    var active: @TypeOf(store.conv_active) = undefined;
    const active_n: usize = @min(store.conv_active_len, active.len);
    @memcpy(active[0..active_n], store.conv_active[0..active_n]);
    var msgs: [store_mod.MAX_CHAT_MSGS]store_mod.ChatMsg = undefined;
    const msg_n = store.msg_count;
    @memcpy(msgs[0..msg_n], store.msgs[0..msg_n]);
    // sized by the store's own constant (STREAM_CAP) + clamped — never hardcode a smaller size than
    // stream_text, or a streaming reply past that size is an instant OOB.
    var stream_buf: [store_mod.STREAM_CAP]u8 = undefined;
    const stream_n = @min(store.stream_len, stream_buf.len);
    @memcpy(stream_buf[0..stream_n], store.stream_text[0..stream_n]);
    var sreason_buf: [4096]u8 = undefined;
    const sreason_n = @min(store.stream_reason_len, sreason_buf.len);
    @memcpy(sreason_buf[0..sreason_n], store.stream_reason[0..sreason_n]);
    const stream_draft = store.stream_draft;
    const busy = store.chat_busy;
    var status: [96]u8 = undefined;
    const status_n: usize = store.chat_status_len;
    @memcpy(status[0..status_n], store.chat_status[0..status_n]);
    var casts: [store_mod.MAX_CASTS]store_mod.CastRow = undefined;
    const cast_n = store.cast_count;
    @memcpy(casts[0..cast_n], store.casts[0..cast_n]);
    var tail: [store_mod.CAST_TAIL]scan.Ev = undefined;
    const tail_n = store.cast_tail_count;
    @memcpy(tail[0..tail_n], store.cast_tail[0..tail_n]);
    var plan: [store_mod.MAX_PLAN]store_mod.PlanRow = undefined;
    const plan_n = store.plan_count;
    @memcpy(plan[0..plan_n], store.plan[0..plan_n]);
    if (store.console_show_veil) { // the AI just ran a command — surface its tab once, then clear the flag
        ui.con_tab = 1;
        store.console_show_veil = false;
    }
    var con_buf: [16384]u8 = undefined;
    const con_ai = ui.con_tab == 1;
    const con_src = if (con_ai) store.console_ai[0..store.console_ai_len] else store.console_you[0..store.console_you_len];
    const con_n = @min(con_src.len, con_buf.len);
    @memcpy(con_buf[0..con_n], con_src[0..con_n]);
    const con_busy = if (con_ai) store.console_busy_ai else store.console_busy_you;
    var con_cwd_buf: [400]u8 = undefined;
    const con_cwd_n = @min(store.console_cwd_len, con_cwd_buf.len);
    @memcpy(con_cwd_buf[0..con_cwd_n], store.console_cwd[0..con_cwd_n]);
    var left_open = store.settings.chat_left_open;
    var right_open = store.settings.chat_right_open;
    store.unlock();

    // RESPONSIVE COLLAPSE: both side panes at full width can starve the center column on a narrow window —
    // the old fixed math drove center.width negative, drawing a degenerate/"broken" empty bordered box AND
    // underflowing monoCols(view.width-28) (a panic in the desk's ReleaseSafe build). Collapse the panes to
    // their strip state (a first-class supported layout), right pane first then left, until the center keeps
    // a usable minimum. Derived from the live window width each frame, so widening the window restores them.
    const min_center: f32 = 260;
    const lwf: f32 = if (left_open) CHAT_LEFT_W else CHAT_STRIP_W; // left width before any collapse
    if (lwf + (if (right_open) CHAT_RIGHT_W else CHAT_STRIP_W) + pad * 4 + min_center > body.width) right_open = false;
    if (lwf + (if (right_open) CHAT_RIGHT_W else CHAT_STRIP_W) + pad * 4 + min_center > body.width) left_open = false;

    const left_w: f32 = if (left_open) CHAT_LEFT_W else CHAT_STRIP_W;
    const right_w: f32 = if (right_open) CHAT_RIGHT_W else CHAT_STRIP_W;
    const ph = body.height - pad * 2;
    const left = t.Rect{ .x = pad, .y = body.y + pad, .width = left_w, .height = ph };
    // The right column stacks the swarm-activity panel over a micro-console (only when the pane is open and
    // there's room). The console gets ~40% of the height, clamped to a sane band.
    const con_h: f32 = if (right_open and ph > 380) @min(280, ph * 0.42) else 0;
    const con_gap: f32 = if (con_h > 0) pad else 0;
    const right = t.Rect{ .x = body.width - pad - right_w, .y = body.y + pad, .width = right_w, .height = ph - con_h - con_gap };
    const console = t.Rect{ .x = right.x, .y = right.y + right.height + con_gap, .width = right_w, .height = con_h };
    // Final safety net: even with both panes collapsed to strips, an extreme window must never feed a
    // negative width downstream (monoCols underflow / degenerate panel rect). 28 keeps view.width-28 >= 0.
    const center = t.Rect{ .x = left.x + left_w + pad, .y = body.y + pad, .width = @max(28, right.x - (left.x + left_w) - pad * 2), .height = ph };

    // The in-flight reply, with any live reasoning prepended as a blockquote so thinking shows line-by-line.
    // Sized for the draft-mode worst case: quoted reasoning (4096 + "> " per line) + separator + "— drafting —"
    // header + the quoted 12288-cap reflect draft; quoteInto ellipsizes gracefully if this still overflows.
    var inflight_buf: [18432]u8 = undefined;
    const inflight_full = buildInflight(&inflight_buf, sreason_buf[0..sreason_n], stream_buf[0..stream_n], stream_draft);

    // SMOOTH REVEAL: show a growing prefix of the received buffer, advancing each frame, so chunky poll-batched
    // token arrivals read as smooth typing instead of appearing in jumps. Catch-up is proportional (≈1/5 of the
    // backlog per frame, min a few bytes) — a small chunk flows over ~5 frames (~80ms) yet a big burst drains
    // fast so the display never lags far behind reality. The buffer resets to empty between turns; clamp down
    // with it so a new reply starts revealing from the top.
    if (ui.stream_reveal > inflight_full.len) ui.stream_reveal = inflight_full.len;
    if (ui.stream_reveal < inflight_full.len) {
        const gap = inflight_full.len - ui.stream_reveal;
        ui.stream_reveal += @max(@as(usize, 3), gap / 5);
        if (ui.stream_reveal > inflight_full.len) ui.stream_reveal = inflight_full.len;
    }
    // never cut a multibyte UTF-8 glyph mid-sequence — back up to the last char boundary at/under the reveal
    var reveal = ui.stream_reveal;
    while (reveal > 0 and reveal < inflight_full.len and (inflight_full[reveal] & 0xC0) == 0x80) reveal -= 1;
    const inflight = inflight_full[0..reveal];

    // Only the NEWEST row can be the live cast (updateCastRow only ever writes casts[n-1]). Scanning ALL rows
    // would let a historical row orphaned mid-"running" (a conv-switch/stop seam) pin the green "hive is
    // working" bar forever, even in a brand-new conversation.
    var cast_live = false;
    if (cast_n > 0) {
        const c = &casts[cast_n - 1];
        cast_live = c.status == .deploying or c.status == .running or c.status == .collecting;
    }

    // the active conversation's display title (the schedule button seeds the task name from it). Default to a
    // human label, never the raw conv id.
    var conv_title: []const u8 = "New chat";
    for (convs[0..conv_n]) |*cv| {
        if (cv.title_len > 0 and std.mem.eql(u8, cv.idStr(), active[0..active_n])) {
            conv_title = cv.titleStr();
            break;
        }
    }

    drawChatLeft(store, left, left_open, convs[0..conv_n], active[0..active_n]);
    drawChatCenter(store, center, msgs[0..msg_n], inflight, busy, status[0..status_n], cast_live, conv_title);
    drawChatRight(store, right, right_open, casts[0..cast_n], tail[0..tail_n], plan[0..plan_n]);
    if (con_h > 0) drawMicroConsole(store, console, con_ai, con_buf[0..con_n], con_busy, con_cwd_buf[0..con_cwd_n]);
}

/// Push a just-run command into the You-shell history ring (skipping an immediate repeat — the arrow-up +
/// Enter loop must not fill the ring with duplicates) and snap browsing back to the live prompt.
fn conHistPush(cmd: []const u8) void {
    if (cmd.len == 0) return;
    ui.con_hist_back = 0;
    if (ui.con_hist_total > 0) {
        const last = (ui.con_hist_total - 1) % ui.con_hist.len;
        if (std.mem.eql(u8, ui.con_hist[last][0..ui.con_hist_len[last]], cmd)) return;
    }
    const slot = ui.con_hist_total % ui.con_hist.len;
    const n = @min(cmd.len, ui.con_hist[slot].len);
    @memcpy(ui.con_hist[slot][0..n], cmd[0..n]);
    ui.con_hist_len[slot] = n;
    ui.con_hist_total += 1;
}

/// Up/Down history browsing for the focused console input — the missing half of "works like a real shell".
/// Up walks back through past commands (saving the live draft first); Down walks forward and finally
/// restores the draft. Repeat-keys work so holding Up scrubs quickly.
fn conHistBrowse() void {
    const avail = @min(ui.con_hist_total, ui.con_hist.len);
    const up = rl.isKeyPressed(.up) or rl.isKeyPressedRepeat(.up);
    const down = rl.isKeyPressed(.down) or rl.isKeyPressedRepeat(.down);
    if (up and ui.con_hist_back < avail) {
        if (ui.con_hist_back == 0) {
            ui.con_hist_draft_len = @min(ui.con_input.len, ui.con_hist_draft.len);
            @memcpy(ui.con_hist_draft[0..ui.con_hist_draft_len], ui.con_input.buf[0..ui.con_hist_draft_len]);
        }
        ui.con_hist_back += 1;
        const slot = (ui.con_hist_total - ui.con_hist_back) % ui.con_hist.len;
        setField(&ui.con_input, ui.con_hist[slot][0..ui.con_hist_len[slot]]);
        ui.input_active = true;
    } else if (down and ui.con_hist_back > 0) {
        ui.con_hist_back -= 1;
        if (ui.con_hist_back == 0) {
            setField(&ui.con_input, ui.con_hist_draft[0..ui.con_hist_draft_len]);
        } else {
            const slot = (ui.con_hist_total - ui.con_hist_back) % ui.con_hist.len;
            setField(&ui.con_input, ui.con_hist[slot][0..ui.con_hist_len[slot]]);
        }
        ui.input_active = true;
    }
}

/// A dual-tab micro-terminal under the swarm activity: tab "You" is a real shell prompt (persistent cwd via
/// the cd/pwd builtins, PowerShell on Windows, Up/Down history); tab "Veil" shows (and lets the AI drive)
/// its own shell. Output streams into the scrollback in store.console_*; `cwd` is the You shell's current
/// directory (chat thread publishes it) drawn as the prompt line over the input field.
fn drawMicroConsole(store: *Store, r: t.Rect, ai: bool, scroll: []const u8, busy: bool, cwd: []const u8) void {
    t.panelBordered(r, t.bg_dark, t.border);
    // ---- tab header (You = user shell, Veil = AI shell) ----
    const th: f32 = 26;
    const tw = (r.width - 10) / 2;
    if (t.tab(.{ .x = r.x + 3, .y = r.y + 3, .width = tw, .height = th }, t.z("You", .{}), ui.con_tab == 0)) ui.con_tab = 0;
    if (t.tab(.{ .x = r.x + 7 + tw, .y = r.y + 3, .width = tw, .height = th }, t.z("Veil", .{}), ui.con_tab == 1)) ui.con_tab = 1;
    if (busy) t.statusDot(@intFromFloat(r.x + r.width - 14), @intFromFloat(r.y + 16), t.yellow);

    // ---- scrollback (mono, tail-anchored, viewport-culled, wheel-scrollable) ----
    const input_h: f32 = 30;
    const prompt_h: f32 = if (ai) 0 else 16; // the You tab reserves one row for the cwd prompt line
    const body_y: f32 = r.y + 3 + th + 5;
    const body_h: f32 = r.height - (body_y - r.y) - input_h - prompt_h - 10;
    rl.beginScissorMode(@intFromFloat(r.x + 1), @intFromFloat(body_y), @intFromFloat(r.width - 2), @intFromFloat(body_h));
    const line_h: f32 = 15;
    const cols: usize = @intFromFloat(@max(8, (r.width - 16) / 7)); // ~7px per mono glyph at size 12
    // Wrap the scrollback into display lines as a RING keeping the NEWEST slice.len lines, so a full 16KB
    // store ring that wraps past the line array still shows the live tail rather than stale content.
    var lines: [512][]const u8 = undefined;
    var ln: usize = 0; // total wrapped lines produced; the ring keeps the newest @min(ln, lines.len)
    var it = std.mem.splitScalar(u8, scroll, '\n');
    while (it.next()) |raw| {
        var seg = raw;
        while (true) {
            if (seg.len <= cols) {
                lines[ln % lines.len] = seg;
                ln += 1;
                break;
            }
            lines[ln % lines.len] = seg[0..cols];
            ln += 1;
            seg = seg[cols..];
        }
    }
    const kept = @min(ln, lines.len);
    const rows: usize = @intFromFloat(@max(1, body_h / line_h));
    // wheel: scroll back through the kept history; 0 = follow the tail as new output streams in
    const body = t.Rect{ .x = r.x + 1, .y = body_y, .width = r.width - 2, .height = body_h };
    const sc = &ui.con_scroll[if (ai) 1 else 0];
    const maxback: usize = if (kept > rows) kept - rows else 0;
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(body)) sc.* += wheel * 3;
    if (sc.* < 0) sc.* = 0;
    if (sc.* > @as(f32, @floatFromInt(maxback))) sc.* = @floatFromInt(maxback);
    const back: usize = @intFromFloat(sc.*);
    const first_kept = ln - kept;
    const endj = ln - back; // exclusive; back==0 means the live tail
    const startj = if (endj - first_kept > rows) endj - rows else first_kept;
    var yy: f32 = body_y;
    if (ln == 0) {
        const hint = if (ai) t.z("the veil runs shell commands here (RUN: ...)", .{}) else t.z("a real shell: cd persists, Up recalls, cls clears", .{});
        t.textMonoClip(hint, @intFromFloat(r.x + 8), @intFromFloat(yy), 12, t.comment, @intFromFloat(r.width - 16));
    }
    var li = startj;
    while (li < endj) : (li += 1) {
        t.textMonoClip(lines[li % lines.len], @intFromFloat(r.x + 8), @intFromFloat(yy), 12, t.fg_dim, @intFromFloat(r.width - 14));
        yy += line_h;
    }
    rl.endScissorMode();
    // hover copy: the whole scrollback as plain text (standard copy for a read-only surface)
    if (ln > 0 and t.hovering(body)) {
        if (copyChip(r.x + r.width - 54, body_y)) {
            copyToClipboard(scroll);
            markCopied();
        }
    }

    // ---- input row (only the You tab is user-typable; the Veil tab is driven by the AI) ----
    const iy: f32 = r.y + r.height - input_h - 4;
    // one fixed slot wide enough for BOTH labels, so the input doesn't shift width when Run swaps to Stop
    const runw: f32 = @max(t.btnW(t.z("Run", .{}), input_h), t.btnW(t.z("Stop", .{}), input_h));
    // While a command runs, a red Stop button (either tab) pushes a console_cancel so the user can kill a hang.
    const stopb = t.Rect{ .x = r.x + r.width - runw - 4, .y = iy, .width = runw, .height = input_h };
    if (ai) {
        // APPROVAL GATE: a veil RUN: command is parked awaiting the user's decision — show it + Approve/Always/Deny.
        var pending = false;
        var pcmd: [1024]u8 = undefined;
        var pn: usize = 0;
        {
            store.lock();
            pending = store.console_pending;
            if (pending) {
                pn = @min(store.console_pending_len, pcmd.len);
                @memcpy(pcmd[0..pn], store.console_pending_cmd[0..pn]);
            }
            store.unlock();
        }
        if (pending) {
            // the command, prominent, one line above the buttons
            t.textMono(t.z("the veil wants to run a command:", .{}), @intFromFloat(r.x + 8), @intFromFloat(iy - 34), 11, t.yellow);
            t.textMonoClip(pcmd[0..pn], @intFromFloat(r.x + 8), @intFromFloat(iy - 18), 12, t.fg, @intFromFloat(r.width - 16));
            const bw = (r.width - 24) / 3;
            const ay = t.Rect{ .x = r.x + 4, .y = iy, .width = bw, .height = input_h };
            const by = t.Rect{ .x = r.x + 12 + bw, .y = iy, .width = bw, .height = input_h };
            const dy = t.Rect{ .x = r.x + 20 + bw * 2, .y = iy, .width = bw, .height = input_h };
            if (t.buttonSolid(ay, t.z("Approve", .{}), t.green, true)) store.pushChatCmd(store_mod.mkChatCmd(.console_approve, "once", ""));
            if (t.button(by, t.z("Always", .{}), t.blue, true)) store.pushChatCmd(store_mod.mkChatCmd(.console_approve, "always", ""));
            if (t.button(dy, t.z("Deny", .{}), t.red, true)) store.pushChatCmd(store_mod.mkChatCmd(.console_deny, "veil", ""));
            return;
        }
        if (busy) {
            t.textMonoClip(t.z("veil is running a command...", .{}), @intFromFloat(r.x + 8), @intFromFloat(iy + (input_h - 12) / 2), 12, t.comment, @intFromFloat(r.width - runw - 20));
            if (t.button(stopb, t.z("Stop", .{}), t.red, true)) store.pushChatCmd(store_mod.mkChatCmd(.console_cancel, "veil", ""));
        } else {
            // clipped to the panel width — the only draw in this row that lacked a bound, so the placeholder
            // ran off the right edge of the 320px console (and past its border, since this is drawn after the
            // scissor is popped). Matches the busy/pending siblings above.
            t.textMonoClip(t.z("(the veil types here during a workflow)", .{}), @intFromFloat(r.x + 8), @intFromFloat(iy + (input_h - 12) / 2), 12, t.comment, @intFromFloat(r.width - 16));
        }
        return;
    }
    // ---- the You shell's PROMPT LINE: the cwd the next command runs in (the cd builtin maintains it) ----
    {
        const py = iy - prompt_h + 1;
        t.textMono(t.z(">", .{}), @intFromFloat(r.x + 8), @intFromFloat(py), 11, t.green);
        const px: f32 = r.x + 18;
        const pmax = r.width - 18 - 8;
        if (cwd.len > 0 and pmax > 30) {
            // tail-biased clip: the DEEPEST segment is the informative part, so an overflowing path drops
            // its head ("...ects\Garrett\nl-veil") instead of its tail like textMonoClip would
            const char_w = @max(1, t.measureMono(t.z("M", .{}), 11));
            const cols_p: usize = @intCast(@max(8, @divTrunc(@as(i32, @intFromFloat(pmax)), char_w)));
            if (cwd.len <= cols_p) {
                t.textMonoClip(cwd, @intFromFloat(px), @intFromFloat(py), 11, t.comment, @intFromFloat(pmax));
            } else {
                var pb: [420]u8 = undefined;
                const keep = cols_p - 3;
                const tail_s = cwd[cwd.len - keep ..];
                const shown = std.fmt.bufPrint(&pb, "...{s}", .{tail_s}) catch cwd;
                t.textMonoClip(shown, @intFromFloat(px), @intFromFloat(py), 11, t.comment, @intFromFloat(pmax));
            }
        }
    }
    // Up/Down browse the command history while the prompt is focused — exactly like a real shell.
    if (ui.focus == .con_input) conHistBrowse();
    const cf = t.Rect{ .x = r.x + 4, .y = iy, .width = r.width - runw - 12, .height = input_h };
    textField(cf, &ui.con_input, ui.focus == .con_input, "command", .con_input);
    if (busy) {
        // a command is running — swap Run for Stop so the user can interrupt it from here
        if (t.button(stopb, t.z("Stop", .{}), t.red, true)) store.pushChatCmd(store_mod.mkChatCmd(.console_cancel, "you", ""));
    } else {
        const can = ui.con_input.len > 0;
        const clicked = t.buttonSolid(stopb, t.z("Run", .{}), t.blue, can);
        const enter = rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter);
        if (can and (clicked or (ui.focus == .con_input and enter))) {
            conHistPush(ui.con_input.str());
            store.pushChatCmd(store_mod.mkChatCmd(.console_run, "you", ui.con_input.str()));
            ui.con_input.clear();
        }
    }
}

/// Compose the streaming display: reasoning as a `> ` blockquote, a blank line, then the answer. Matches how
/// a finished veil message is stored (Chat.appendVeil), so the live view and the settled view agree. When a
/// turn streams a tool call, detect the prefix live and return a compact one-line placeholder ("writing
/// snake.html…") — otherwise the raw escaped `TOOL: write_file {…}` dumps a wall of JSON until the turn
/// settles. Returns null if not a tool call.
fn streamToolLabel(content: []const u8, buf: []u8) ?[]const u8 {
    const c = std.mem.trimStart(u8, content, " \r\n\t");
    var name: []const u8 = "";
    if (std.mem.startsWith(u8, c, "TOOL:")) {
        const rest = std.mem.trimStart(u8, c[5..], " ");
        var i: usize = 0;
        while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '_')) i += 1;
        name = rest[0..i];
    } else if (std.mem.startsWith(u8, c, "<tool:")) {
        const rest = c[6..];
        name = rest[0 .. std.mem.indexOfScalar(u8, rest, '>') orelse rest.len];
    } else return null;
    if (name.len == 0) return null;
    // pull "path":"…" out of the (still-streaming) args for a friendlier label; empty until it arrives
    var path: []const u8 = "";
    if (std.mem.indexOf(u8, c, "\"path\"")) |at| {
        const after = c[at + 6 ..];
        if (std.mem.indexOfScalar(u8, after, ':')) |colon| {
            const v = std.mem.trimStart(u8, after[colon + 1 ..], " ");
            if (v.len > 1 and v[0] == '"') path = v[1 .. std.mem.indexOfScalarPos(u8, v, 1, '"') orelse v.len];
        }
    }
    const verb: []const u8 = if (std.mem.eql(u8, name, "write_file")) "writing" else if (std.mem.eql(u8, name, "edit_file")) "editing" else if (std.mem.eql(u8, name, "read_file")) "reading" else if (std.mem.eql(u8, name, "run_tests")) "running tests" else if (std.mem.eql(u8, name, "run_python")) "running" else "calling";
    const target = if (path.len > 0) path else name;
    return std.fmt.bufPrint(buf, "{s} {s}...", .{ verb, target }) catch null;
}

/// Append `text` line-by-line as a `> ` blockquote (the thinking style). Returns the new write offset.
/// A line that doesn't fit is partially emitted with a trailing ellipsis (never silently dropped).
fn quoteInto(buf: []u8, at: usize, text: []const u8) usize {
    var w = at;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const ln = std.mem.trim(u8, line, " \r\t");
        if (ln.len == 0) continue;
        if (w + ln.len + 3 > buf.len) {
            if (buf.len - w > 16) { // room for "> " + a meaningful head + "…\n" (… is 3 bytes)
                buf[w] = '>';
                buf[w + 1] = ' ';
                w += 2;
                const take = buf.len - w - 4;
                @memcpy(buf[w .. w + take], ln[0..take]);
                w += take;
                @memcpy(buf[w .. w + 3], "…");
                w += 3;
                buf[w] = '\n';
                w += 1;
            }
            break;
        }
        buf[w] = '>';
        buf[w + 1] = ' ';
        w += 2;
        @memcpy(buf[w .. w + ln.len], ln);
        w += ln.len;
        buf[w] = '\n';
        w += 1;
    }
    return w;
}

fn buildInflight(buf: []u8, reasoning: []const u8, content: []const u8, draft: bool) []const u8 {
    var w: usize = 0;
    if (reasoning.len > 0) {
        w = quoteInto(buf, w, reasoning);
        if (w + 1 < buf.len) {
            buf[w] = '\n';
            w += 1;
        }
    }
    // If the reply is streaming a tool call, show a compact "writing <file>…" line instead of the raw escaped
    // JSON body (which is a wall of text until the turn settles and collapses to a chip).
    var tbuf: [160]u8 = undefined;
    const shown = streamToolLabel(content, &tbuf) orelse content;
    if (draft and shown.len > 0) {
        // PRE-FINAL draft: render it as thinking (quoted, under a drafting header), never as answer body —
        // a self-check pass will revise it, and only the final committed message should read as the reply.
        w = quoteInto(buf, w, "— drafting —");
        w = quoteInto(buf, w, shown);
        return buf[0..w];
    }
    const cn = @min(shown.len, buf.len - w);
    @memcpy(buf[w .. w + cn], shown[0..cn]);
    w += cn;
    return buf[0..w];
}

fn togglePane(store: *Store, left: bool) void {
    store.lock();
    if (left) store.settings.chat_left_open = !store.settings.chat_left_open else store.settings.chat_right_open = !store.settings.chat_right_open;
    store.unlock();
    store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", "")); // persist the pane state
}

fn drawChatLeft(store: *Store, r: t.Rect, open: bool, convs: []const store_mod.ConvRow, active: []const u8) void {
    t.panelBordered(r, t.bg_dark, t.border);
    if (!open) {
        if (t.buttonGhost(.{ .x = r.x + 2, .y = r.y + 5, .width = r.width - 4, .height = 24 }, t.z(">", .{}), t.blue, true)) togglePane(store, true);
        return;
    }
    // INNER TABS: Chats | Tasks — the tasks live beside the conversations they mint, so a task's runs
    // are one click away from the chats they produced (the Tasks TOP tab remains the full manager).
    const tl_chats = t.z("Chats", .{});
    const tl_sched = t.z("Tasks", .{});
    var tx: f32 = r.x + t.PAD_IN;
    if (t.tab(.{ .x = tx, .y = r.y + 6, .width = t.tabW(tl_chats), .height = 26 }, tl_chats, ui.chats_inner == .chats)) ui.chats_inner = .chats;
    tx += t.tabW(tl_chats) + 6;
    if (t.tab(.{ .x = tx, .y = r.y + 6, .width = t.tabW(tl_sched), .height = 26 }, tl_sched, ui.chats_inner == .sched)) ui.chats_inner = .sched;
    if (t.buttonGhost(.{ .x = r.x + r.width - 32, .y = r.y + 7, .width = 26, .height = 24 }, t.z("<", .{}), t.blue, true)) togglePane(store, true);
    if (ui.chats_inner == .chats) {
        if (t.buttonGhost(.{ .x = r.x + r.width - 62, .y = r.y + 7, .width = 26, .height = 24 }, t.z("+", .{}), t.blue, true)) {
            store.pushChatCmd(store_mod.mkChatCmd(.new_conv, "", ""));
            ui.c_renaming = false;
        }
    }
    if (ui.chats_inner == .sched) {
        drawChatsSchedList(store, r);
        return;
    }

    const list = t.Rect{ .x = r.x + 1, .y = r.y + 38, .width = r.width - 2, .height = r.height - 42 };
    const row_h: f32 = 42;
    // wheel-scroll the conversation list
    const total: f32 = @as(f32, @floatFromInt(convs.len)) * row_h;
    const max_scroll = if (total > list.height) total - list.height else 0;
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(list)) ui.conv_scroll -= wheel * row_h;
    if (ui.conv_scroll < 0) ui.conv_scroll = 0;
    if (ui.conv_scroll > max_scroll) ui.conv_scroll = max_scroll;
    rl.beginScissorMode(@intFromFloat(list.x), @intFromFloat(list.y), @intFromFloat(list.width), @intFromFloat(list.height));
    defer rl.endScissorMode();
    var yy: f32 = r.y + 42 - ui.conv_scroll;
    for (convs) |*cv| {
        // cull rows outside the view but keep advancing yy so offsets stay stable
        if (yy + row_h < list.y or yy > r.y + r.height - 8) {
            yy += row_h;
            continue;
        }
        const rr = t.Rect{ .x = r.x + 5, .y = yy, .width = r.width - 10, .height = row_h - 6 };
        const is_active = std.mem.eql(u8, cv.idStr(), active);
        const hot = t.hovering(rr);
        if (is_active) t.panel(rr, t.bg_sel) else if (hot) t.panel(rr, t.bg_hl);

        if (is_active and ui.c_renaming) {
            textField(.{ .x = rr.x + 4, .y = rr.y + 4, .width = rr.width - 8, .height = rr.height - 8 }, &ui.c_rename, ui.focus == .c_rename, "new title - Enter", .c_rename);
            if (ui.focus == .c_rename and rl.isKeyPressed(.enter) and ui.c_rename.len > 0) {
                store.pushChatCmd(store_mod.mkChatCmd(.rename_conv, cv.idStr(), ui.c_rename.str()));
                ui.c_renaming = false;
                ui.focus = .none;
            }
        } else {
            // Never show the raw conv id — it's a storage key, not a name. refreshConvs resolves a real title
            // (or the first message); a still-nameless conv reads as "New chat", not "c6a5a…".
            const title = if (cv.title_len > 0) cv.titleStr() else "New chat";
            t.textClip(title, @intFromFloat(rr.x + 10), @intFromFloat(rr.y + (rr.height - 13) / 2), 13, if (is_active) t.fg else t.fg_dim, @intFromFloat(rr.width - 44));
            const xb = t.Rect{ .x = rr.x + rr.width - 28, .y = rr.y + (rr.height - 22) / 2, .width = 22, .height = 22 };
            if (hot and !t.hovering(xb)) t.wantCursor(.pointing_hand);
            if (hot and t.buttonGhost(xb, t.z("x", .{}), t.red, true)) {
                store.pushChatCmd(store_mod.mkChatCmd(.delete_conv, cv.idStr(), ""));
            } else if (hot and rl.isMouseButtonPressed(.left)) {
                if (is_active) {
                    // clicking the active row again edits its title in place
                    ui.c_renaming = true;
                    setField(&ui.c_rename, title);
                    ui.focus = .c_rename;
                } else {
                    store.pushChatCmd(store_mod.mkChatCmd(.select_conv, cv.idStr(), ""));
                    ui.chat_follow = true;
                    ui.c_renaming = false;
                }
            }
        }
        yy += row_h;
    }
    if (convs.len == 0) {
        t.text(t.z("no chats yet", .{}), @intFromFloat(r.x + 12), @intFromFloat(r.y + 42), 12, t.comment);
        t.text(t.z("type below to start one", .{}), @intFromFloat(r.x + 12), @intFromFloat(r.y + 60), 12, t.comment);
    }
}

/// Fixed mono columns for wrapping: the chat body renders in the console font, so wrap width is exact.
fn monoCols(w: f32, size: i32) usize {
    const ten = t.measureMono(t.z("MMMMMMMMMM", .{}), size);
    const per = @as(f32, @floatFromInt(ten)) / 10.0;
    if (per <= 0.1) return 80;
    return @max(10, @as(usize, @intFromFloat(w / per)));
}

// ---- chat markdown: a small block renderer. ONE function does both measuring and drawing (draw flag)
// so the scroll math and the pixels can never disagree. Structure honored: fenced code blocks (panel +
// copy chip), headings, bullets, **bold** markers stripped; body text stays mono so wrap math is exact.

var clip_buf: [65536]u8 = undefined; // 64K: long answers / whole-conversation copies shouldn't truncate
var copy_flash_until: f64 = 0;

fn copyToClipboard(s: []const u8) void {
    const n = @min(s.len, clip_buf.len - 1);
    @memcpy(clip_buf[0..n], s[0..n]);
    clip_buf[n] = 0;
    rl.setClipboardText(clip_buf[0..n :0]);
}

fn markCopied() void {
    copy_flash_until = rl.getTime() + 1.2;
}

fn copyIsFresh() bool {
    return rl.getTime() < copy_flash_until;
}

fn bufAppend(buf: []u8, n: *usize, s: []const u8) void {
    const c = @min(s.len, buf.len - n.*);
    @memcpy(buf[n.*..][0..c], s[0..c]);
    n.* += c;
}

/// Copy the ENTIRE active conversation as plain text ("role: message" blocks) — the keyboard-reachable
/// copy (Ctrl+Shift+C) for people who want the whole chat, not one message. Built under the store lock
/// because the chat thread writes the message ring concurrently; roleLabel is copied immediately so its
/// shared format buffer can't be clobbered before it lands.
var conv_buf: [65536]u8 = undefined;
fn copyConversation(store: *Store) void {
    var n: usize = 0;
    store.lock();
    var i: usize = 0;
    while (i < store.msg_count) : (i += 1) {
        bufAppend(&conv_buf, &n, roleLabel(store.msgs[i].role));
        bufAppend(&conv_buf, &n, ": ");
        bufAppend(&conv_buf, &n, store.msgs[i].textStr());
        bufAppend(&conv_buf, &n, "\n\n");
    }
    store.unlock();
    if (n > 0) copyToClipboard(conv_buf[0..n]);
}

/// A tiny "copy" chip; returns true on click.
fn copyChip(x: f32, y: f32) bool {
    const r = t.Rect{ .x = x, .y = y, .width = 46, .height = 17 };
    const hot = t.hovering(r);
    const copied = copyIsFresh();
    // No background/border — just the bare "copy"/"copied" label that brightens on hover (user request).
    t.text(if (copied) t.z("copied", .{}) else t.z("copy", .{}), @intFromFloat(x + (if (copied) @as(f32, 4) else 9)), @intFromFloat(y + 2), 11, if (hot) t.fg else t.comment);
    if (hot) t.wantCursor(.pointing_hand);
    return hot and rl.isMouseButtonPressed(.left);
}

/// A SMALL copy chip that lives in a code block's top-right corner. Only drawn while the block is hovered
/// (the caller gates on it), so it stays out of the way until wanted. Returns true on click.
fn codeCopyChip(x: f32, y: f32) bool {
    const r = t.Rect{ .x = x, .y = y, .width = 44, .height = 17 };
    const hot = t.hovering(r);
    const copied = copyIsFresh();
    t.panelBordered(r, if (hot) t.bg_sel else t.bg_dark, if (hot) t.blue else t.border);
    t.text(if (copied) t.z("copied", .{}) else t.z("copy", .{}), @intFromFloat(x + (if (copied) @as(f32, 5) else 10)), @intFromFloat(y + 2), 10, if (hot) t.fg else t.comment);
    if (hot) t.wantCursor(.pointing_hand);
    return hot and rl.isMouseButtonPressed(.left);
}

/// The code block's raw content, from just after the opening fence line to the closing fence.
fn codeBlockSlice(text_: []const u8, from: usize) []const u8 {
    var i = from;
    while (i < text_.len) {
        const nl = std.mem.indexOfScalarPos(u8, text_, i, '\n') orelse text_.len;
        const ln = std.mem.trimStart(u8, text_[i..nl], " ");
        if (std.mem.startsWith(u8, ln, "```")) return text_[from..i];
        i = if (nl == text_.len) text_.len else nl + 1;
    }
    return text_[from..];
}

// Chat line metrics — VARS, refreshed each frame from the text-scale settings so the reading surface's
// line advance grows with its glyphs (fixed-height chrome elsewhere keeps its constants; it has slack).
var MSG_LINE_H: f32 = 19;
var MSG_HEAD_H: f32 = 18;
const MSG_GAP_H: f32 = 12;
const MSG_HEADING_H: f32 = 24;
const MSG_FENCE_H: f32 = 6;
const MSG_HR_H: f32 = 12;
const MSG_MAX_LINES = 512;

fn inView(v: t.Rect, y: f32, h: f32) bool {
    return y + h >= v.y and y <= v.y + v.height;
}

fn isConsoleMsg(text_: []const u8) bool {
    return std.mem.startsWith(u8, text_, "[console]\n");
}

const CONSOLE_CAP: usize = 24; // output rows a console card shows before a "+K more lines" footer (bounds a dump)

/// Draw (or, with draw=false, just measure) a folded shell result "[console]\n$ cmd\n<output>" as a styled
/// terminal CARD — the counterpart to the fenced-code panel, for the AI's RUN: door. Reuses the code-panel
/// shell (rounded, bordered, bg_hl@170 fill, mono rows), adding traffic-light dots + a "console" header, a
/// status-colored left accent bar, a "$" prompt + command, dim mono output (capped, with a "+K more lines"
/// footer), and a status dot/pill. `card_top` is the y after renderMsg's reserved MSG_HEAD_H row. Height
/// derives PURELY from the text (scan.parseConsole), so measure and draw never disagree.
fn renderConsole(view: t.Rect, card_top: f32, text_: []const u8, fsz: i32, draw: bool) f32 {
    var out: [MSG_MAX_LINES][]const u8 = undefined;
    const p = scan.parseConsole(text_, &out);
    const shown: usize = if (p.out_n == 0) 1 else @min(p.out_n, CONSOLE_CAP);
    const foot: f32 = if (p.out_n > CONSOLE_CAP) 18 else 0;
    // HDR(24)+PAD(8)+CMD_H(22)+DIV_GAP(8)+PAD_BOT(8) = 70 constant, plus the output rows + optional footer.
    const card_h = 70 + @as(f32, @floatFromInt(shown)) * MSG_LINE_H + foot;
    const advance = card_top + card_h + MSG_GAP_H;
    if (!draw or !inView(view, card_top, card_h)) return advance; // measure-only, or culled off-screen

    const bx = view.x + 8;
    const bw = @max(60, view.width - 16); // floor so a pathologically narrow view can't go negative-width
    const status_col: t.Color = switch (p.status) {
        .ok => t.green,
        .exit_fail => t.red,
        .timeout, .truncated => t.orange,
        .stopped => t.yellow,
    };
    // the code-family panel + a status-colored left accent bar (inset 7px top/bottom to clear the rounded corners)
    t.panelBordered(.{ .x = bx, .y = card_top, .width = bw, .height = card_h }, t.withAlpha(t.bg_hl, 170), t.border);
    t.fillRect(@intFromFloat(bx + 1), @intFromFloat(card_top + 7), 3, @intFromFloat(card_h - 14), t.withAlpha(status_col, 200));
    // header: traffic-light dots (always tri-color — the "this is a terminal" signifier) + a muted "console" label
    const cy: i32 = @intFromFloat(card_top + 12);
    rl.drawCircle(@intFromFloat(bx + 14), cy, 3.0, t.red);
    rl.drawCircle(@intFromFloat(bx + 26), cy, 3.0, t.yellow);
    rl.drawCircle(@intFromFloat(bx + 38), cy, 3.0, t.green);
    t.text(t.z("console", .{}), @intFromFloat(bx + 52), @intFromFloat(card_top + 7), 11, t.comment);
    t.hline(@intFromFloat(bx + 4), @intFromFloat(card_top + 24), @intFromFloat(bw - 8), t.withAlpha(t.border, 140));
    // header-right status: a quiet green dot on success, a labeled colored pill on failure. The pill is
    // clamped to stay right of the "console" header label — a long hex exit code (exit 0xC0000135) on a
    // narrow pane clips inside the pill instead of sliding over the header.
    const pill_max = bw - 114;
    if (p.isFail() and pill_max >= 34) {
        var pill_w: f32 = @floatFromInt(t.measure(t.zs(p.labelStr()), 10) + 26);
        if (pill_w > pill_max) pill_w = pill_max;
        const pill_x = bx + bw - 10 - pill_w;
        t.panel(.{ .x = pill_x, .y = card_top + 4, .width = pill_w, .height = 16 }, t.withAlpha(status_col, 40));
        rl.drawCircle(@intFromFloat(pill_x + 9), @intFromFloat(card_top + 12), 3.0, status_col);
        t.textClip(p.labelStr(), @intFromFloat(pill_x + 16), @intFromFloat(card_top + 6), 10, status_col, @intFromFloat(pill_w - 20));
    } else {
        // success — or a pane too narrow for any pill: the status dot alone (still status-colored)
        rl.drawCircle(@intFromFloat(bx + bw - 14), @intFromFloat(card_top + 12), 3.5, if (p.isFail()) status_col else t.green);
    }
    // command row: green "$" prompt + the bright command (single clipped mono line, the visual focus)
    const cmd_y: i32 = @intFromFloat(card_top + 32);
    t.textMono(t.z("$", .{}), @intFromFloat(bx + 14), cmd_y, fsz, t.green);
    t.textMonoClip(p.cmd, @intFromFloat(bx + 30), cmd_y, fsz, t.fg, @intFromFloat(bw - 44));
    t.hline(@intFromFloat(bx + 10), @intFromFloat(card_top + 58), @intFromFloat(bw - 20), t.withAlpha(t.border, 90));
    // output rows (dim mono, one clipped source-line each), or a "(no output)" placeholder
    const out_top = card_top + 62;
    if (p.out_n == 0) {
        t.textMonoClip("(no output)", @intFromFloat(bx + 14), @intFromFloat(out_top), fsz, t.comment, @intFromFloat(bw - 28));
    } else {
        var k: usize = 0;
        while (k < shown) : (k += 1) {
            t.textMonoClip(std.mem.trimEnd(u8, out[k], "\r"), @intFromFloat(bx + 14), @intFromFloat(out_top + @as(f32, @floatFromInt(k)) * MSG_LINE_H), fsz, t.fg_dim, @intFromFloat(bw - 28));
        }
    }
    if (foot > 0) {
        t.text(t.z("+{d} more lines", .{p.out_n - CONSOLE_CAP}), @intFromFloat(bx + 14), @intFromFloat(out_top + @as(f32, @floatFromInt(CONSOLE_CAP)) * MSG_LINE_H), 11, t.comment);
    }
    return advance;
}

/// Render (or just measure, draw=false) one message with lightweight markdown: fenced code blocks
/// (backdrop + copy chip), GFM tables (aligned columns), headings, horizontal rules, bullets, and inline
/// **bold** / `code` / <br> handled. ONE function measures AND draws (draw flag) so scroll math and pixels
/// can never disagree. Returns the y after the message.
fn renderMsg(view: t.Rect, y0: f32, role: store_mod.ChatRole, text_: []const u8, fsz: i32, draw: bool, cursor: bool) f32 {
    var yy = y0;
    // A folded shell result ("[console]\n$ cmd\n…") renders as a styled terminal CARD instead of plain prose.
    // renderConsole is reached HERE in BOTH the height-cache/measure pass and the draw pass (renderMsg is called
    // in each), so its height can't diverge. The card carries its own "console" header, so the outer role label
    // is suppressed for it — but the MSG_HEAD_H row is still reserved so the on-hover whole-message copy chip
    // (drawn by the caller at y0) sits clear of the card's status pill.
    const is_console = role == .cast_note and isConsoleMsg(text_);
    if (draw and !is_console and inView(view, yy, MSG_HEAD_H)) {
        var lx = view.x + 14;
        // the LIVE reply (cursor=true only on the streaming message) carries the animated BRAND MARK +
        // thought dots — both paced by real stream activity (see thinkEnergy)
        if (cursor and role == .veil) lx += drawThinkingMark(lx, yy);
        t.text(roleLabel(role), @intFromFloat(lx), @intFromFloat(yy), 11, roleColor(role));
        if (cursor and role == .veil) drawThinkingDots(lx + @as(f32, @floatFromInt(t.measure(roleLabel(role), 11))) + 14, yy);
    }
    yy += MSG_HEAD_H;
    if (is_console) return renderConsole(view, yy, text_, fsz, draw);
    const dim = role == .cast_note or role == .thought;

    // split into a line array so multi-line constructs (tables, code) can be grouped with lookahead
    var lines: [MSG_MAX_LINES][]const u8 = undefined;
    var n: usize = 0;
    {
        var it = std.mem.splitScalar(u8, text_, '\n');
        while (it.next()) |l| {
            if (n >= MSG_MAX_LINES) break;
            lines[n] = l;
            n += 1;
        }
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const raw = lines[i];
        const tl = std.mem.trim(u8, raw, " \r\t");
        // fenced code block — rendered as ONE padded panel (top/bottom + left inset so text never touches the
        // border) with a small copy chip tucked in the top-right corner that only appears while the block is
        // hovered. The whole block is grouped by lookahead to the closing fence so height is exact in both the
        // measure and draw passes.
        if (std.mem.startsWith(u8, tl, "```")) {
            var j = i + 1;
            while (j < n and !std.mem.startsWith(u8, std.mem.trim(u8, lines[j], " \r\t"), "```")) : (j += 1) {}
            const n_code = j - (i + 1);
            const pad_v: f32 = 10;
            const block_h = pad_v * 2 + @as(f32, @floatFromInt(n_code)) * MSG_LINE_H;
            const bx = view.x + 8;
            const bw = view.width - 16;
            if (draw and inView(view, yy, block_h)) {
                const block = t.Rect{ .x = bx, .y = yy, .width = bw, .height = block_h };
                t.panelBordered(block, t.withAlpha(t.bg_hl, 170), t.border);
                // the fence's language tag ("```zig") becomes a quiet label in the top-right corner
                const lang = std.mem.trim(u8, tl[3..], " \r\t`");
                if (lang.len > 0 and lang.len <= 12 and !t.hovering(block)) {
                    const lw = t.measure(t.zs(lang), 10);
                    t.textClip(lang, @intFromFloat(bx + bw - 10 - @as(f32, @floatFromInt(lw))), @intFromFloat(yy + 6), 10, t.comment, lw + 4);
                }
                var k: usize = 0;
                while (k < n_code) : (k += 1) {
                    const cl = std.mem.trimEnd(u8, lines[i + 1 + k], "\r");
                    t.textMonoClip(cl, @intFromFloat(bx + 14), @intFromFloat(yy + pad_v + @as(f32, @floatFromInt(k)) * MSG_LINE_H), fsz, t.cyan, @intFromFloat(bw - 28));
                }
                if (t.hovering(block)) {
                    const off = @intFromPtr(lines[i].ptr) - @intFromPtr(text_.ptr);
                    const from = @min(off + lines[i].len + 1, text_.len);
                    if (codeCopyChip(bx + bw - 46, yy + 6)) {
                        copyToClipboard(codeBlockSlice(text_, from));
                        markCopied();
                    }
                }
            }
            yy += block_h + 6; // a little breathing room below the block
            i = j; // the for-loop's i += 1 resumes after the closing fence
            continue;
        }
        // horizontal rule
        if (md.isHr(tl)) {
            if (draw and inView(view, yy, MSG_HR_H)) t.fillRect(@intFromFloat(view.x + 14), @intFromFloat(yy + MSG_HR_H / 2), @intFromFloat(view.width - 28), 1, t.border);
            yy += MSG_HR_H;
            continue;
        }
        // GFM table: a pipe row whose NEXT line is the |---|---| separator
        if (md.hasPipe(tl) and i + 1 < n and md.isTableSep(std.mem.trim(u8, lines[i + 1], " \r\t"))) {
            var j = i;
            while (j < n and md.hasPipe(std.mem.trim(u8, lines[j], " \r\t"))) : (j += 1) {}
            yy = renderTable(view, yy, lines[i..j], fsz, draw);
            i = j - 1; // for-loop adds 1
            continue;
        }
        // heading — a real hierarchy: bold face, sized by level, wrapped (never clipped), and an anchoring
        // hairline under h1/h2. The whole heading parses through the span grammar, so inline `code` or
        // emphasis inside a heading renders instead of leaking markers.
        if (std.mem.startsWith(u8, tl, "#")) {
            var lvl: u8 = 0;
            var h = tl;
            while (h.len > 0 and h[0] == '#' and lvl < 6) {
                h = h[1..];
                lvl += 1;
            }
            h = std.mem.trimStart(u8, h, " ");
            const hsz: i32 = switch (lvl) {
                1 => 22,
                2 => 19,
                3 => 17,
                else => 15,
            };
            const hlh: f32 = @round((@as(f32, @floatFromInt(hsz)) + 6) * t.uiScale());
            var il: md.Inline = .{};
            md.parseInline(&il, h);
            yy += 9; // top lead separates the section from the prose above
            const hcolor = if (lvl >= 5) t.fg_dim else t.fg;
            yy = renderInline(view, yy, &il, hsz, hlh, draw, hcolor, .strong, 0, 0);
            if (lvl <= 2) {
                if (draw and inView(view, yy, 8)) t.fillRect(@intFromFloat(view.x + 14), @intFromFloat(yy + 2), @intFromFloat(view.width - 28), 1, t.withAlpha(t.border, 200));
                yy += 7;
            } else {
                yy += 2;
            }
            continue;
        }
        // blockquote (used for the model's reasoning): dim text with a left accent bar
        if (std.mem.startsWith(u8, tl, ">")) {
            var il: md.Inline = .{};
            md.parseInline(&il, std.mem.trimStart(u8, tl[1..], " "));
            const y_before = yy;
            yy = renderInline(view, yy, &il, fsz, MSG_LINE_H, draw, t.comment, .ui, 6, 6);
            if (draw and inView(view, y_before, yy - y_before)) t.fillRect(@intFromFloat(view.x + 10), @intFromFloat(y_before - 1), 2, @intFromFloat(yy - y_before - MSG_LINE_H + 2), t.comment);
            continue;
        }
        if (tl.len == 0) {
            yy += MSG_LINE_H; // blank line = paragraph spacing
            continue;
        }
        // bullet / task / ordered-list / prose — all through the span grammar, with NESTED indent levels,
        // accent-colored markers, and a hanging indent so wrapped lines align under their own text.
        const is_bullet = std.mem.startsWith(u8, tl, "- ") or std.mem.startsWith(u8, tl, "* ") or std.mem.startsWith(u8, tl, "+ ");
        var ord_len: usize = 0; // "N. " / "N) " (up to a couple of digits)
        if (!is_bullet) {
            var k: usize = 0;
            while (k < tl.len and k < 3 and tl[k] >= '0' and tl[k] <= '9') k += 1;
            if (k > 0 and k + 1 < tl.len and (tl[k] == '.' or tl[k] == ')') and tl[k + 1] == ' ') ord_len = k + 2;
        }
        if (is_bullet or ord_len > 0) {
            // nesting depth from leading whitespace (2 spaces or one tab per level, capped)
            var depth: usize = 0;
            {
                var spaces: usize = 0;
                for (raw) |rc| {
                    if (rc == ' ') spaces += 1 else if (rc == '\t') spaces += 2 else break;
                }
                depth = @min(spaces / 2, 3);
            }
            const dpx: f32 = @floatFromInt(depth * 16);
            var src = if (is_bullet) tl[2..] else tl[ord_len..];
            // task-list checkbox: "- [ ] " / "- [x] "
            var task: u8 = 0; // 0 = none, 1 = open, 2 = done
            if (is_bullet and src.len >= 3 and src[0] == '[' and src[2] == ']' and (src.len == 3 or src[3] == ' ')) {
                if (src[1] == ' ') task = 1;
                if (src[1] == 'x' or src[1] == 'X') task = 2;
                if (task != 0) src = std.mem.trimStart(u8, src[3..], " ");
            }
            var il: md.Inline = .{};
            md.parseInline(&il, src);
            var marker_w: f32 = 16;
            if (ord_len > 0) {
                const mz = t.zs(tl[0..ord_len]);
                marker_w = @max(16, @as(f32, @floatFromInt(t.measureStyled(mz, fsz, .ui))) + 4);
            }
            const y_row = yy;
            yy = renderInline(view, yy, &il, fsz, MSG_LINE_H, draw, if (dim) t.fg_dim else (if (task == 2) t.fg_dim else t.fg), .ui, dpx + marker_w, dpx + marker_w);
            if (draw and inView(view, y_row, MSG_LINE_H)) {
                const mx = view.x + 14 + dpx;
                if (task != 0) {
                    // a real checkbox: bordered square, filled + checked when done
                    const bx2 = mx;
                    const by2 = y_row + (MSG_LINE_H - 11) / 2;
                    if (task == 2) {
                        t.panel(.{ .x = bx2, .y = by2, .width = 11, .height = 11 }, t.blue);
                        rl.drawLineEx(.{ .x = bx2 + 2.5, .y = by2 + 5.5 }, .{ .x = bx2 + 4.5, .y = by2 + 8 }, 1.6, t.bg);
                        rl.drawLineEx(.{ .x = bx2 + 4.5, .y = by2 + 8 }, .{ .x = bx2 + 8.5, .y = by2 + 3 }, 1.6, t.bg);
                    } else {
                        t.panelBordered(.{ .x = bx2, .y = by2, .width = 11, .height = 11 }, t.withAlpha(t.bg_hl, 120), t.comment);
                    }
                } else if (ord_len > 0) {
                    t.textStyled(t.zs(tl[0..ord_len]), mx, y_row, fsz, t.blue, .ui);
                } else {
                    // marker glyph alternates by depth: • ◦ • ◦ (both in the font atlas)
                    const glyph = if (depth % 2 == 1) t.z("\u{25E6}", .{}) else t.z("\u{2022}", .{});
                    t.textStyled(glyph, mx + 2, y_row, fsz, t.blue, .ui);
                }
            }
            continue;
        }
        // plain prose paragraph
        var il: md.Inline = .{};
        md.parseInline(&il, tl);
        yy = renderInline(view, yy, &il, fsz, MSG_LINE_H, draw, if (dim) t.fg_dim else t.fg, .ui, 0, 0);
    }
    if (cursor and draw and @mod(rl.getTime(), 1.0) < 0.6) {
        t.textMono(t.z("|", .{}), @intFromFloat(view.x + 14), @intFromFloat(yy - MSG_LINE_H + 2), fsz, t.magenta);
    }
    return yy + MSG_GAP_H;
}

/// Render a GFM table (rows include the |---| separator, which is skipped) as aligned mono columns,
/// FITTED to the viewport: when the natural column widths overflow the message area, columns shrink
/// (widest first, floor of 5 chars) and long cells clip with ".." — every column stays visible and
/// aligned at any window size, instead of the old whole-line right-edge amputation that left broken
/// fragments of the last columns. Re-fits every frame, so resizing the window re-flows the table live.
fn renderTable(view: t.Rect, y0: f32, rows: []const []const u8, fsz: i32, draw: bool) f32 {
    var yy = y0;
    const MAXC = 10;
    const COL_MIN: usize = 5;
    var colw: [MAXC]usize = [_]usize{0} ** MAXC;
    var ncols: usize = 0;
    // pass 1: natural column widths (in bytes ~ mono chars)
    for (rows) |row| {
        const tl = std.mem.trim(u8, row, " \r\t");
        if (md.isTableSep(tl)) continue;
        var it = std.mem.splitScalar(u8, md.tableInner(tl), '|');
        var ci_: usize = 0;
        while (it.next()) |cell| {
            if (ci_ >= MAXC) break;
            var cb: [256]u8 = undefined;
            const cl = md.cleanInline(&cb, cell);
            if (cl > colw[ci_]) colw[ci_] = cl;
            ci_ += 1;
        }
        if (ci_ > ncols) ncols = ci_;
    }
    if (ncols == 0) return yy;
    // fit: shrink the widest column one char at a time until the row fits the viewport's mono columns
    const char_w = @max(1, t.measureMono("M", fsz));
    const avail_chars: usize = @intCast(@max(16, @divTrunc(@as(i32, @intFromFloat(view.width - 40)), char_w)));
    var total: usize = 3 * (ncols - 1);
    for (colw[0..ncols]) |cw| total += cw;
    while (total > avail_chars) {
        var widest: usize = 0;
        for (colw[0..ncols], 0..) |cw, i| {
            if (cw > colw[widest]) widest = i;
        }
        if (colw[widest] <= COL_MIN) break; // every column at the floor — physically can't fit; clip the tail
        colw[widest] -= 1;
        total -= 1;
    }
    // pass 2: draw each non-separator row as padded, joined cells, each CELL clipped to its fitted width
    var header = true;
    var body_row: usize = 0; // zebra counter (data rows only)
    for (rows) |row| {
        const tl = std.mem.trim(u8, row, " \r\t");
        if (md.isTableSep(tl)) continue;
        var lb: [1024]u8 = undefined;
        var w: usize = 0;
        var it = std.mem.splitScalar(u8, md.tableInner(tl), '|');
        var ci_: usize = 0;
        while (it.next()) |cell| {
            if (ci_ >= ncols or w >= lb.len - 4) break;
            if (ci_ > 0) {
                const sep = " | ";
                @memcpy(lb[w .. w + sep.len], sep);
                w += sep.len;
            }
            var cb: [256]u8 = undefined;
            var cl = md.cleanInline(&cb, cell);
            if (cl > colw[ci_]) {
                // clip to the fitted column with a ".." tail so a shrunk cell reads as clipped, not broken
                cl = colw[ci_];
                if (cl >= 2) {
                    cb[cl - 1] = '.';
                    cb[cl - 2] = '.';
                }
            }
            const take = @min(cl, lb.len - w);
            @memcpy(lb[w .. w + take], cb[0..take]);
            w += take;
            // pad to the column width (skip padding the final column)
            if (ci_ + 1 < ncols and colw[ci_] > cl) {
                const pad = @min(colw[ci_] - cl, lb.len - w);
                @memset(lb[w .. w + pad], ' ');
                w += pad;
            }
            ci_ += 1;
        }
        if (draw and inView(view, yy, MSG_LINE_H)) {
            if (header) {
                t.fillRect(@intFromFloat(view.x + 8), @intFromFloat(yy - 2), @intFromFloat(view.width - 16), @intFromFloat(MSG_LINE_H), t.withAlpha(t.bg_hl, 130));
            } else if (body_row % 2 == 1) {
                // zebra striping: alternate data rows get a whisper of fill so wide tables stay scannable
                t.fillRect(@intFromFloat(view.x + 8), @intFromFloat(yy - 2), @intFromFloat(view.width - 16), @intFromFloat(MSG_LINE_H), t.withAlpha(t.bg_hl, 55));
            }
            t.textMonoClip(lb[0..w], @intFromFloat(view.x + 14), @intFromFloat(yy), fsz, if (header) t.fg else t.fg_dim, @intFromFloat(view.width - 26));
        }
        yy += MSG_LINE_H;
        if (!header) body_row += 1;
        header = false;
    }
    return yy + 4;
}

// ---- the styled-span text engine ------------------------------------------------------------------------
// mdutil.parseInline turns a source line into display bytes + style runs; this lays them out with REAL
// typography: per-span faces (bold/italic/mono), inline-code chips, clickable underlined links, and proper
// word wrap with hanging indents — across every font size and weight. ONE code path measures AND draws
// (draw flag), so scroll math and pixels can never disagree; hostile input (2KB spaceless runs, marker
// storms) char-splits and never crashes.

/// Which face a span renders in. Headings pass base=.strong so every child span stays bold.
fn spanKind(st: md.Style, base: t.FontKind) t.FontKind {
    if (st.code) return .mono;
    if (base == .strong) return .strong;
    if (st.bold) return .strong;
    if (st.italic) return .em;
    return .ui;
}

fn spanColor(st: md.Style, base: t.Color) t.Color {
    if (st.link) return t.blue;
    if (st.code) return t.teal;
    return base;
}

/// Draw one measured piece of a row (a word fragment in a single style) + its decorations. Pure pixels —
/// the caller already did the layout math. `w` is the piece's measured advance.
fn drawPieceDecorated(il: *const md.Inline, sp: md.Span, z: [:0]const u8, x: f32, yy: f32, w: f32, size: i32, line_h: f32, color: t.Color, kind: t.FontKind) void {
    const st = sp.style;
    if (st.code) { // the code chip: a soft rounded backdrop so `inline code` reads at a glance
        t.panel(.{ .x = x - 2, .y = yy - 1, .width = w + 4, .height = line_h - 1 }, t.withAlpha(t.bg_hl, 210));
    }
    t.textStyled(z, x, yy, size, color, kind);
    if (st.strike) t.fillRect(@intFromFloat(x - 1), @intFromFloat(yy + line_h * 0.42), @intFromFloat(w + 2), 1, t.withAlpha(color, 210));
    if (st.link) {
        const r = t.Rect{ .x = x, .y = yy, .width = w, .height = line_h - 2 };
        const hot = t.hovering(r);
        t.fillRect(@intFromFloat(x), @intFromFloat(yy + line_h - 4), @intFromFloat(w), 1, t.withAlpha(t.blue, if (hot) 255 else 140));
        if (hot) {
            t.wantCursor(.pointing_hand);
            if (rl.isMouseButtonPressed(.left)) {
                if (il.urlOf(sp)) |url| {
                    // only real web schemes leave the app — a model can emit anything into an href
                    if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))
                        rl.openURL(t.zs(url));
                }
            }
        }
    }
}

/// Lay out one parsed line (`il`) wrapped into `view`, honoring per-span styles. `first_indent` offsets the
/// first row (list markers live in that gap), `hang_indent` every wrapped row — the hanging indent that
/// keeps bullet text aligned under itself. Returns the y after the last row. Measure/draw parity: the one
/// loop runs in both passes; only pixel calls check `draw`.
fn renderInline(view: t.Rect, y0: f32, il: *const md.Inline, size: i32, line_h: f32, draw: bool, base_color: t.Color, base_kind: t.FontKind, first_indent: f32, hang_indent: f32) f32 {
    var yy = y0;
    const x_base = view.x + 14;
    const max_x = view.x + view.width - 12;
    const space_w: f32 = @floatFromInt(@max(2, t.measureStyled(t.z(" ", .{}), size, base_kind)));
    var x = x_base + first_indent;
    var row_x0 = x;
    var row_text: [1024]u8 = undefined; // the row's plain bytes, for the selection/copy capture
    var row_len: usize = 0;
    var rows: u32 = 0;
    var line_start = true;
    var pending_space = false;
    var sidx: usize = 0; // monotone span cursor (spans are ordered by offset)

    const n = il.text_len;
    var pos: usize = 0;
    while (pos < n) {
        const c = il.text[pos];
        if (c == '\n') { // hard break (<br>)
            if (draw) captureSelLine(inView(view, yy, line_h), yy, row_x0, size, false, row_text[0..row_len]);
            yy += line_h;
            rows += 1;
            x = x_base + hang_indent;
            row_x0 = x;
            row_len = 0;
            line_start = true;
            pending_space = false;
            pos += 1;
            continue;
        }
        if (c == ' ') {
            pending_space = !line_start;
            pos += 1;
            continue;
        }
        // the WORD [pos, wend) — may cross span boundaries
        var wend = pos;
        while (wend < n and il.text[wend] != ' ' and il.text[wend] != '\n') wend += 1;
        // measure it piece-wise (advance the span cursor as offsets pass)
        var ww: f32 = 0;
        {
            var p = pos;
            var si = sidx;
            while (p < wend) {
                while (si + 1 < il.span_count and p >= il.spans[si].off + il.spans[si].len) si += 1;
                const sp = il.spans[si];
                const pe = @min(wend, @as(usize, sp.off) + sp.len);
                if (pe <= p) break; // degenerate span table — never spin
                ww += @floatFromInt(t.measureStyled(t.zs(il.text[p..pe]), size, spanKind(sp.style, base_kind)));
                p = pe;
            }
        }
        const sw: f32 = if (pending_space) space_w else 0;
        if (!line_start and x + sw + ww > max_x) { // wrap BEFORE this word
            if (draw) captureSelLine(inView(view, yy, line_h), yy, row_x0, size, false, row_text[0..row_len]);
            yy += line_h;
            rows += 1;
            x = x_base + hang_indent;
            row_x0 = x;
            row_len = 0;
            line_start = true;
            pending_space = false;
        } else if (pending_space) {
            x += sw;
            if (row_len < row_text.len) {
                row_text[row_len] = ' ';
                row_len += 1;
            }
            pending_space = false;
        }
        // emit the word piece-wise; a piece that STILL overflows an empty row char-splits (long url/path)
        var p = pos;
        while (p < wend) {
            while (sidx + 1 < il.span_count and p >= il.spans[sidx].off + il.spans[sidx].len) sidx += 1;
            const sp = il.spans[sidx];
            const pe = @min(wend, @as(usize, sp.off) + sp.len);
            if (pe <= p) break;
            var piece = il.text[p..pe];
            const kind = spanKind(sp.style, base_kind);
            const color = spanColor(sp.style, base_color);
            while (piece.len > 0) {
                var z = t.zs(piece);
                var w: f32 = @floatFromInt(t.measureStyled(z, size, kind));
                var taken = piece.len;
                if (x + w > max_x and !line_start) { // no room mid-row: wrap, then retry on the fresh row
                    if (draw) captureSelLine(inView(view, yy, line_h), yy, row_x0, size, false, row_text[0..row_len]);
                    yy += line_h;
                    rows += 1;
                    x = x_base + hang_indent;
                    row_x0 = x;
                    row_len = 0;
                    line_start = true;
                    continue;
                }
                if (x + w > max_x) { // fresh row and STILL too wide: take the longest fitting prefix
                    taken = 1;
                    while (taken < piece.len) : (taken += 1) {
                        const zc = t.zs(piece[0 .. taken + 1]);
                        if (x + @as(f32, @floatFromInt(t.measureStyled(zc, size, kind))) > max_x) break;
                    }
                    z = t.zs(piece[0..taken]);
                    w = @floatFromInt(t.measureStyled(z, size, kind));
                }
                const shown = inView(view, yy, line_h);
                if (draw and shown) drawPieceDecorated(il, sp, z, x, yy, w, size, line_h, color, kind);
                x += w;
                line_start = false;
                const cn = @min(taken, row_text.len - row_len);
                @memcpy(row_text[row_len..][0..cn], piece[0..cn]);
                row_len += cn;
                piece = piece[taken..];
                if (piece.len > 0) { // the split continues on a new row
                    if (draw) captureSelLine(shown, yy, row_x0, size, false, row_text[0..row_len]);
                    yy += line_h;
                    rows += 1;
                    x = x_base + hang_indent;
                    row_x0 = x;
                    row_len = 0;
                    line_start = true;
                }
            }
            p = pe;
        }
        pos = wend;
    }
    if (row_len > 0 or rows == 0) {
        if (draw) captureSelLine(inView(view, yy, line_h), yy, row_x0, size, false, row_text[0..row_len]);
        yy += line_h;
    }
    return yy;
}

/// How alive the live reply is RIGHT NOW, 0..1: 1.0 while stream bytes are actually landing, easing down
/// to a calm 0.25 floor when the model goes quiet (deep think, tool wait). Drives the thinking mark and
/// dots, so the indicator's tempo mirrors real activity instead of ticking blindly.
fn thinkEnergy() f32 {
    const dt = rl.getTime() - ui.live_change_t;
    if (dt < 0.6) return 1.0;
    return @floatCast(@max(0.25, 1.0 - (dt - 0.6) / 2.4 * 0.75));
}

/// The live reply's header indicator: the BRAND MARK (the real app icon when its texture is loaded)
/// breathing beside the label. Sized + centered to sit inside the MSG_HEAD_H label row with clear margin
/// — only the translucent halo may kiss the edges. Returns the width consumed by icon + breathing room.
fn drawThinkingMark(x: f32, y: f32) f32 {
    t.drawMarkPulse(x + 8, y + 7.5, 6.5, @floatCast(rl.getTime()), thinkEnergy());
    return 26;
}

/// Three thought dots in a staggered wave after the label — their tempo and brightness follow the same
/// live energy as the mark (quick while tokens land, a slow ember while the model thinks).
fn drawThinkingDots(x: f32, y: f32) void {
    const tm = rl.getTime();
    const e: f64 = thinkEnergy();
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ph = @sin(tm * (1.8 + 3.2 * e) + @as(f64, @floatFromInt(i)) * 0.9);
        const a: u8 = @intFromFloat(55.0 + (95.0 + 75.0 * e) * @abs(ph));
        rl.drawCircle(@intFromFloat(x + @as(f32, @floatFromInt(i)) * 8.0), @intFromFloat(y + 7), 1.8, t.withAlpha(t.magenta, a));
    }
}

fn roleLabel(role: store_mod.ChatRole) [:0]const u8 {
    return switch (role) {
        .user => t.z("you", .{}),
        .veil => t.z("veil", .{}),
        .cast_note => t.z("cast", .{}),
        .thought => t.z("reasoning", .{}),
    };
}

fn roleColor(role: store_mod.ChatRole) t.Color {
    return switch (role) {
        .user => t.cyan,
        .veil => t.magenta,
        .cast_note => t.yellow,
        .thought => t.comment,
    };
}

/// The collapsed reasoning-trace line — same shape as toolChip but labeled as the veil's own thinking. Shows
/// an inline preview of the first line of the thinking so the user sees WHAT is being reasoned without expanding
/// every trace. Click to expand the full text. Returns true on click (expand/collapse).
fn thoughtChip(view: t.Rect, y0: f32, expanded: bool, preview: []const u8) bool {
    const r = t.Rect{ .x = view.x + 12, .y = y0 + 4, .width = view.width - 24, .height = 20 };
    const hot = t.hovering(r) and t.hovering(view);
    t.fillRect(@intFromFloat(r.x + 2), @intFromFloat(y0 + 11), 6, 6, t.comment); // dim marker dot
    const lbl = t.z("reasoning", .{});
    t.text(lbl, @intFromFloat(r.x + 16), @intFromFloat(y0 + 8), 12, if (hot or expanded) t.fg else t.comment);
    // one-line preview of the thinking, after the label, clipped to leave room for the view/hide affordance
    const first = firstLine(preview);
    if (first.len > 0) {
        const lw: f32 = @floatFromInt(t.measure(lbl, 12));
        const px = r.x + 16 + lw + 12;
        const pmax: i32 = @intFromFloat(@max(20, (r.x + r.width - 42) - px));
        t.textClip(first, @intFromFloat(px), @intFromFloat(y0 + 8), 12, t.comment, pmax);
    }
    t.text(if (expanded) t.z("hide", .{}) else t.z("view", .{}), @intFromFloat(r.x + r.width - 34), @intFromFloat(y0 + 9), 10, if (hot) t.blue else t.comment);
    if (hot) t.wantCursor(.pointing_hand);
    return hot and rl.isMouseButtonPressed(.left);
}

/// The first non-empty line of `s`, trimmed — the reasoning preview snippet.
fn firstLine(s: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |ln| {
        const t2 = std.mem.trim(u8, ln, " \r\t");
        if (t2.len > 0) return t2;
    }
    return "";
}

/// A single clean 'the hive is working' status line in the chat flow while a cast runs, so the chat isn't dead
/// air; the detailed grounding/thinking/tool log stays in the Swarm activity pane (the raw event dump is too
/// noisy for the chat). One line only; the % + phase come from `status`.
fn renderCastLive(view: t.Rect, y0: f32, status: []const u8, draw: bool) f32 {
    if (draw and inView(view, y0, MSG_LINE_H + 2)) {
        t.fillRect(@intFromFloat(view.x + 8), @intFromFloat(y0 - 2), @intFromFloat(view.width - 16), @intFromFloat(MSG_LINE_H + 2), t.withAlpha(t.green, 34));
        const spin = [_][]const u8{ "|", "/", "-", "\\" };
        const s = spin[@as(usize, @intFromFloat(@mod(rl.getTime() * 6.0, 4.0)))];
        t.text(t.z("{s} the hive is working — {s}  (live detail in Swarm activity)", .{ s, if (status.len > 0) status else "casting" }), @intFromFloat(view.x + 14), @intFromFloat(y0), 12, t.green);
    }
    return y0 + MSG_LINE_H + 6 + MSG_GAP_H;
}

const TOOL_CHIP_H: f32 = 30;

/// If a chat message is a tool call — the model's "TOOL: name ..." request or the "[tool:name]\n<result>"
/// result — return the tool name. These are hidden behind a compact clickable chip instead of dumping the raw
/// JSON/result into the chat (the user reads a friendly line; the model still gets the full text).
fn toolName(text: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, text, "[tool:")) {
        const close = std.mem.indexOfScalar(u8, text[6..], ']') orelse return null;
        return text[6 .. 6 + close];
    }
    if (std.mem.startsWith(u8, text, "TOOL:")) {
        const rest = std.mem.trim(u8, text[5..], " \r\t");
        // '(' delimits too: a function-style `TOOL: write_file({...})` chips as "write_file", not "write_file("
        const sp = std.mem.indexOfAny(u8, rest, " \t{(\r\n") orelse rest.len;
        const nm = std.mem.trim(u8, rest[0..sp], " \t:");
        return if (nm.len > 0) nm else null;
    }
    return null;
}

/// A human one-liner for a tool name (the collapsed chip label).
fn toolFriendly(name: []const u8) [:0]const u8 {
    if (std.mem.eql(u8, name, "web_search")) return t.z("searched the web", .{});
    if (std.mem.eql(u8, name, "web_fetch")) return t.z("fetched a page", .{});
    if (std.mem.eql(u8, name, "fetch_json")) return t.z("fetched data", .{});
    if (std.mem.eql(u8, name, "read_url")) return t.z("read a page", .{});
    if (std.mem.eql(u8, name, "deep_crawl")) return t.z("crawled the web", .{});
    if (std.mem.eql(u8, name, "list_swarms")) return t.z("checked the swarms", .{});
    if (std.mem.eql(u8, name, "stop_swarm")) return t.z("stopped the swarm", .{});
    if (std.mem.eql(u8, name, "kill_swarm")) return t.z("killed the swarm", .{});
    if (std.mem.eql(u8, name, "swarm_status")) return t.z("checked the swarm's status", .{});
    if (std.mem.eql(u8, name, "swarm_findings")) return t.z("read the swarm's findings", .{});
    if (std.mem.eql(u8, name, "recall_hive")) return t.z("recalled memory", .{});
    if (std.mem.eql(u8, name, "observe")) return t.z("saved a note to memory", .{});
    if (std.mem.eql(u8, name, "share")) return t.z("shared to the hive", .{});
    return t.z("used a tool", .{});
}

/// The tokens a tool call put into context (result bytes / ~4) — the visible "cost" on the chip line. For a
/// `[tool:NAME]\n<result>` message that's the result; for a bare `TOOL:` request, the whole line.
fn tokCostOf(text: []const u8) usize {
    const body = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text[nl + 1 ..] else text;
    return body.len / 4;
}

/// Draw the collapsed tool line — NO background or border: a colored marker, the tool NAME, and a view/hide
/// affordance. The token cost lives in the expanded dropdown (see drawChatCenter). Returns true on click.
fn toolChip(view: t.Rect, y0: f32, name: []const u8, expanded: bool) bool {
    const r = t.Rect{ .x = view.x + 12, .y = y0 + 4, .width = view.width - 24, .height = 20 };
    const hot = t.hovering(r) and t.hovering(view);
    t.fillRect(@intFromFloat(r.x + 2), @intFromFloat(y0 + 11), 6, 6, t.blue); // small marker dot
    const nm = t.zs(name); // the actual tool called (read_file, write_file, web_search, …)
    t.text(nm, @intFromFloat(r.x + 16), @intFromFloat(y0 + 8), 12, if (hot or expanded) t.fg else t.fg_dim);
    t.text(if (expanded) t.z("hide", .{}) else t.z("view", .{}), @intFromFloat(r.x + r.width - 34), @intFromFloat(y0 + 9), 10, if (hot) t.blue else t.comment);
    if (hot) t.wantCursor(.pointing_hand);
    return hot and rl.isMouseButtonPressed(.left);
}

// ---- chat text selection: drag-select over the DISPLAYED glyphs + Ctrl+C copies the selection ----
// Each frame the message draw loop captures the geometry of every visible text line into sel_lines; a selection
// is a (message, [anchor,cursor) flat-char range) over that message's folded display text. Highlight is drawn
// translucent over the glyphs; the selected text is cached in sel_text for Ctrl+C.
// bytes sized to the draw-path fold cap (theme.nextBuf is [2048]) so a captured line never truncates the glyphs
// that were actually drawn — otherwise a >400-char wrapped line on a wide window would be partly uncopyable.
const SelLine = struct { msg: usize, char0: usize, y: f32, x0: f32, size: i32, mono: bool, drawn: bool = false, bytes: [2048]u8 = undefined, len: usize = 0 };
var sel_lines: [1400]SelLine = undefined;
var sel_line_n: usize = 0;
var cur_sel_msg: usize = std.math.maxInt(usize); // the message index currently being drawn (max = don't capture)
var cur_sel_char0: usize = 0; // running flat offset within the current message (in folded/display bytes)
var sel_text: [1 << 14]u8 = undefined; // the selected text, cached each frame for Ctrl+C
var sel_text_len: usize = 0;

fn captureSelLine(drawn: bool, y: f32, x0: f32, size: i32, mono: bool, raw: []const u8) void {
    if (cur_sel_msg == std.math.maxInt(usize)) return;
    var fb: [2048]u8 = undefined;
    const fl = t.foldAscii(&fb, raw); // capture what's ON SCREEN (folded), so measure + copy match the glyphs
    // Store on-screen lines (for hit-test + highlight) AND every line of the SELECTED message even when scrolled
    // out of view — so Ctrl+C copies the whole selection, not just the visible slice. `drawn` gates the highlight.
    const is_sel = if (ui.sel_msg) |sm| cur_sel_msg == sm else false;
    if ((drawn or is_sel) and sel_line_n < sel_lines.len) {
        const g = &sel_lines[sel_line_n];
        g.msg = cur_sel_msg;
        g.char0 = cur_sel_char0;
        g.y = y;
        g.x0 = x0;
        g.size = size;
        g.mono = mono;
        g.drawn = drawn;
        @memcpy(g.bytes[0..fl], fb[0..fl]);
        g.len = fl;
        sel_line_n += 1;
    }
    cur_sel_char0 += fl + 1; // advance for EVERY line (incl. culled) so offsets stay stable across scroll
}

fn selPrefixPx(g: *const SelLine, c: usize) f32 {
    const n = @min(c, g.len);
    if (n == 0) return 0;
    var b: [2049]u8 = undefined;
    @memcpy(b[0..n], g.bytes[0..n]);
    b[n] = 0;
    return @floatFromInt(if (g.mono) t.measureMono(b[0..n :0], g.size) else t.measure(b[0..n :0], g.size));
}

fn selColAt(g: *const SelLine, mx: f32) usize {
    const target = mx - g.x0;
    if (target <= 0) return 0;
    var lo: usize = 0;
    var hi: usize = g.len;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (selPrefixPx(g, mid) <= target) lo = mid else hi = mid - 1;
    }
    return lo;
}

const SelHit = struct { msg: usize, flat: usize };
fn selHit(mx: f32, my: f32) ?SelHit {
    var best: ?usize = null;
    var bestdy: f32 = 1e9;
    var i: usize = 0;
    while (i < sel_line_n) : (i += 1) {
        const g = &sel_lines[i];
        if (!g.drawn) continue; // off-screen lines of the selected msg live in sel_lines for copy, not hit-testing
        if (my >= g.y - 2 and my <= g.y + MSG_LINE_H) return .{ .msg = g.msg, .flat = g.char0 + selColAt(g, mx) };
        const dy = @abs(my - (g.y + MSG_LINE_H / 2));
        if (dy < bestdy) {
            bestdy = dy;
            best = i;
        }
    }
    // Nearest-line fallback ONLY within a line's height of some prose — else a click in the empty area below the
    // last message returns null so the caller's `else` branch can clear the selection (click-to-deselect).
    if (best) |bi| {
        if (bestdy <= MSG_LINE_H) {
            const g = &sel_lines[bi];
            return .{ .msg = g.msg, .flat = g.char0 + selColAt(g, mx) };
        }
    }
    return null;
}

/// Draw the selection highlight over the captured glyphs + cache the selected text for Ctrl+C. Call after the
/// message draw loop (geometry captured), inside the chat scissor.
fn drawSelection() void {
    sel_text_len = 0;
    const sm = ui.sel_msg orelse return;
    const lo = @min(ui.sel_anchor, ui.sel_cursor);
    const hi = @max(ui.sel_anchor, ui.sel_cursor);
    if (hi <= lo) return;
    var i: usize = 0;
    while (i < sel_line_n) : (i += 1) {
        const g = &sel_lines[i];
        if (g.msg != sm) continue;
        const ls = g.char0;
        const le = g.char0 + g.len;
        if (hi <= ls or lo >= le) continue; // >= : a selection anchored exactly at end-of-line adds no leading \n
        const a = if (lo > ls) lo - ls else 0;
        const b = if (hi < le) hi - ls else g.len;
        if (b > a) {
            if (g.drawn) { // highlight only what's on screen; copy (below) still grabs scrolled-off lines
                const xa = g.x0 + selPrefixPx(g, a);
                const xb = g.x0 + selPrefixPx(g, b);
                t.fillRect(@intFromFloat(xa), @intFromFloat(g.y - 1), @intFromFloat(@max(3, xb - xa)), g.size + 4, t.withAlpha(t.blue, 80));
            }
            if (sel_text_len + (b - a) < sel_text.len) {
                @memcpy(sel_text[sel_text_len..][0 .. b - a], g.bytes[a..b]);
                sel_text_len += b - a;
            }
        }
        if (hi > le and sel_text_len < sel_text.len) {
            sel_text[sel_text_len] = '\n';
            sel_text_len += 1;
        }
    }
}

fn drawChatCenter(store: *Store, r: t.Rect, msgs: []const store_mod.ChatMsg, stream: []const u8, busy: bool, status: []const u8, cast_live: bool, conv_title: []const u8) void {
    // The input row is USER-RESIZABLE (drag the grab strip above it): crafting a long prompt deserves
    // more than three lines. ui.input_extra persists for the session; the transcript view shrinks to
    // make room because everything below derives from input_h. Clamped so the transcript keeps space.
    ui.input_extra = std.math.clamp(ui.input_extra, 0, @max(0, r.height * 0.5 - 66));
    const input_h: f32 = 66 + ui.input_extra;
    const status_h: f32 = 22;
    const tab_h: f32 = 26;
    // Chat | Metrics | Files inner tabs (Metrics = per-turn perf graphs; Files = this chat's own build dir)
    const tl_chat = t.z("Chat", .{});
    const tl_metrics = t.z("Metrics", .{});
    const tl_files = t.z("Files", .{});
    var tx = r.x;
    if (t.tab(.{ .x = tx, .y = r.y, .width = t.tabW(tl_chat), .height = tab_h }, tl_chat, ui.chat_inner == .chat)) ui.chat_inner = .chat;
    tx += t.tabW(tl_chat) + 6;
    if (t.tab(.{ .x = tx, .y = r.y, .width = t.tabW(tl_metrics), .height = tab_h }, tl_metrics, ui.chat_inner == .metrics)) ui.chat_inner = .metrics;
    tx += t.tabW(tl_metrics) + 6;
    if (t.tab(.{ .x = tx, .y = r.y, .width = t.tabW(tl_files), .height = tab_h }, tl_files, ui.chat_inner == .files)) ui.chat_inner = .files;
    // right-aligned in the same tab row: seed a task from THIS conversation (its first user ask becomes
    // the prompt, the latest answer the key details). Pure UI-thread prefill — no commands fired.
    if (msgs.len > 0) {
        const tl_sched = t.z("make a task", .{});
        const sb = t.Rect{ .x = r.x + r.width - t.btnW(tl_sched, 22) - 2, .y = r.y + 2, .width = t.btnW(tl_sched, 22), .height = 22 };
        if (t.buttonGhost(sb, tl_sched, t.blue, true)) {
            schedResetForm(); // a CREATE seed must never inherit a half-open edit's id/provider fields
            setField(&ui.sc_name, if (conv_title.len > 0) conv_title else "chat task");
            for (msgs) |*m| {
                if (m.role == .user) {
                    setField(&ui.sc_prompt, m.textStr()); // the conversation's durable goal (its first ask)
                    break;
                }
            }
            var i: usize = msgs.len;
            while (i > 0) {
                i -= 1;
                if (msgs[i].role == .veil) {
                    setField(&ui.sc_details, msgs[i].textStr()); // setField clips to the field's 1200-byte cap
                    break;
                }
            }
            setTab(.scheduled);
            ui.sched_inner = .build;
        }
    }
    if (ui.chat_inner == .metrics) {
        drawChatMetrics(store, .{ .x = r.x, .y = r.y + tab_h + 6, .width = r.width, .height = r.height - tab_h - 6 });
        return;
    }
    if (ui.chat_inner == .files) {
        drawChatFiles(store, .{ .x = r.x, .y = r.y + tab_h + 6, .width = r.width, .height = r.height - tab_h - 6 });
        return;
    }
    const view = t.Rect{ .x = r.x, .y = r.y + tab_h + 6, .width = r.width, .height = r.height - input_h - status_h - 14 - tab_h - 6 };
    t.panelBordered(view, t.bg_dark, t.border);

    const fsz: i32 = 14;
    const cols = monoCols(view.width - 28, fsz);

    // total content height — from the per-message height CACHE (renderMsg word-wrap is expensive on long
    // chats). Rebuild the cache only when the message set or wrap width actually changed; otherwise reuse.
    var fp: u64 = 0;
    for (msgs) |*m| fp = fp *% 1000003 +% m.text_len +% (@as(u64, @intFromEnum(m.role)) << 56);
    fp +%= @as(u64, ui.tool_open orelse 0xffff) << 40; // expand/collapse changes a tool message's height
    // message set / wrap width changed → drop a stale selection — but NOT mid-drag, or a background message commit
    // (a cast_note row, the finalized veil answer) during an active drag would silently kill the in-progress select.
    if ((ui.mh_fp != fp or ui.mh_cols != cols) and !ui.sel_dragging) ui.sel_msg = null;
    if (ui.mh_count != msgs.len or ui.mh_cols != cols or ui.mh_fp != fp) {
        // INCREMENTAL rebuild: only rows whose own fingerprint changed re-measure. A width change isn't caught
        // by the per-row fp, so `wipe` (below) forces every cached height stale.
        const wipe = ui.mh_cols != cols; // wrap width changed → every cached height is stale
        for (msgs, 0..) |*m, i| {
            const mfp: u64 = @as(u64, m.text_len) ^ (@as(u64, @intFromEnum(m.role)) << 56) ^ (if (ui.tool_open == i) @as(u64, 1) << 48 else 0);
            if (!wipe and i < ui.mh_count and ui.mh_mfp[i] == mfp) continue; // unchanged row — keep its height
            ui.mh[i] = if ((m.role == .thought or toolName(m.textStr()) != null) and ui.tool_open != i)
                TOOL_CHIP_H // collapsed tool call / reasoning trace = a one-line chip
            else
                renderMsg(view, 0, m.role, m.textStr(), fsz, false, false);
            ui.mh_mfp[i] = mfp;
        }
        ui.mh_count = msgs.len;
        ui.mh_cols = cols;
        ui.mh_fp = fp;
    }
    var total: f32 = 8;
    for (msgs, 0..) |_, i| total += ui.mh[i];
    if (busy or stream.len > 0) {
        // re-measure the live preview only when it actually grew (it only ever grows within a step)
        if (stream.len != ui.stream_h_len or cols != ui.stream_h_cols) {
            ui.stream_h = renderMsg(view, 0, .veil, stream, fsz, false, false);
            ui.stream_h_len = stream.len;
            ui.stream_h_cols = cols;
        }
        total += ui.stream_h + MSG_LINE_H;
    }
    if (cast_live) total += renderCastLive(view, 0, status, false);

    const max_scroll = if (total > view.height) total - view.height else 0;
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(view)) {
        ui.chat_scroll -= wheel * 3 * MSG_LINE_H;
        ui.chat_follow = false;
    }
    if (ui.chat_follow) ui.chat_scroll = max_scroll;
    if (ui.chat_scroll < 0) ui.chat_scroll = 0;
    if (ui.chat_scroll > max_scroll) ui.chat_scroll = max_scroll;
    if (ui.chat_scroll >= max_scroll - 1) ui.chat_follow = true;

    // floating "scroll to bottom" (drawn after endScissorMode below): visible only while scrolled away from the
    // bottom — follow force-re-arms at the bottom (the line above), so !chat_follow IS "away from bottom".
    const show_jump = !ui.chat_follow;
    const jump_r = t.Rect{ .x = view.x + view.width - 40, .y = view.y + view.height - 40, .width = 28, .height = 28 };

    rl.beginScissorMode(@intFromFloat(view.x + 1), @intFromFloat(view.y + 1), @intFromFloat(view.width - 2), @intFromFloat(view.height - 2));
    sel_line_n = 0; // rebuild this frame's selection line-geometry as we draw
    var yy: f32 = view.y + 8 - ui.chat_scroll;
    const vtop = view.y;
    const vbot = view.y + view.height;
    for (msgs, 0..) |*m, i| {
        const y0 = yy;
        yy = y0 + ui.mh[i]; // cached height (draw + measure share layout, so this matches renderMsg's advance)
        cur_sel_msg = std.math.maxInt(usize); // default: don't capture (tool chips etc. aren't selectable prose)
        // CULL: a message fully above or below the viewport costs nothing — skip the word-wrap+draw entirely.
        // This is the big win on long scrollback (render ~a screenful, not the whole history, every frame).
        if (yy < vtop or y0 > vbot) continue;
        if (m.role == .thought) {
            // The reasoning trace renders collapsed (a dim one-line chip); click to read the full thinking that
            // led to the answer below it. Excluded from the model's history, so expanding costs nothing.
            if (ui.tool_open == i) {
                _ = renderMsg(view, y0, m.role, m.textStr(), fsz, true, false);
                // copy chip: flush RIGHT and only while the row is hovered (a reasoning block has no token-cost
                // label to its right, so a mid-row chip would read as floating).
                if (t.hovering(t.Rect{ .x = view.x + 2, .y = y0, .width = view.width - 4, .height = yy - y0 }) and t.hovering(view)) {
                    if (copyChip(view.x + view.width - 60, y0 + 3)) {
                        copyToClipboard(m.textStr());
                        markCopied();
                    }
                }
                const hdr = t.Rect{ .x = view.x + 2, .y = y0, .width = view.width - 132, .height = 20 };
                if (t.hovering(hdr) and t.hovering(view) and rl.isMouseButtonPressed(.left)) ui.tool_open = null;
            } else if (thoughtChip(view, y0, false, m.textStr())) {
                ui.tool_open = i;
            }
            continue;
        }
        if (toolName(m.textStr())) |tn| {
            // Tool calls render as a compact chip (raw JSON/result hidden). Click to expand/collapse; the full
            // text is untouched in the message, so the model still receives it and copy still grabs it.
            if (ui.tool_open == i) {
                _ = renderMsg(view, y0, m.role, m.textStr(), fsz, true, false);
                // the token cost lives in the expanded dropdown (top-right), not the collapsed line
                t.text(t.z("~{d} tok", .{tokCostOf(m.textStr())}), @intFromFloat(view.x + view.width - 76), @intFromFloat(y0 + 6), 11, t.comment);
                // expanded tool text is copyable like any other message
                if (copyChip(view.x + view.width - 126, y0 + 3)) {
                    copyToClipboard(m.textStr());
                    markCopied();
                }
                const hdr = t.Rect{ .x = view.x + 2, .y = y0, .width = view.width - 132, .height = 20 };
                if (t.hovering(hdr) and t.hovering(view) and rl.isMouseButtonPressed(.left)) ui.tool_open = null;
            } else if (toolChip(view, y0, tn, false)) {
                ui.tool_open = i;
            }
            continue;
        }
        cur_sel_msg = i; // capture THIS message's text-line geometry for selection
        cur_sel_char0 = 0;
        _ = renderMsg(view, y0, m.role, m.textStr(), fsz, true, false);
        // whole-message copy chip on hover (beside the role label)
        const mrect = t.Rect{ .x = view.x + 2, .y = y0, .width = view.width - 4, .height = yy - y0 };
        if (m.text_len > 0 and t.hovering(mrect) and t.hovering(view)) {
            if (copyChip(view.x + view.width - 60, y0)) {
                copyToClipboard(m.textStr());
                markCopied();
            }
        }
    }
    cur_sel_msg = std.math.maxInt(usize); // the streaming/cast-live rows change every frame — not selectable
    if (busy or stream.len > 0) {
        // feed the thinking mark's energy: note whenever the stream actually GREW this frame
        if (stream.len != ui.live_len_prev) {
            ui.live_len_prev = stream.len;
            ui.live_change_t = rl.getTime();
        }
        yy = renderMsg(view, yy, .veil, stream, fsz, true, true);
    }
    if (cast_live) yy = renderCastLive(view, yy, status, true);
    if (msgs.len == 0 and !busy and stream.len == 0) {
        t.text(t.z("talk to the veil - it casts the hive when a task needs real work", .{}), @intFromFloat(view.x + 14), @intFromFloat(view.y + 14), 13, t.comment);
    }
    // TEXT SELECTION: drag over the message text to select; the highlight + cached copy text are computed from the
    // line geometry captured above. A plain click (no drag) clears the selection. Ctrl+C (handled in handleKeys)
    // copies sel_text. Gated on hovering the chat view + not on a tool/copy chip row.
    const mp = rl.getMousePosition();
    // (the jump button owns its press — a click on it must not also set an empty selection)
    if (t.hovering(view) and rl.isMouseButtonPressed(.left) and !(show_jump and t.hovering(jump_r))) {
        if (selHit(mp.x, mp.y)) |h| {
            ui.sel_msg = h.msg;
            ui.sel_anchor = h.flat;
            ui.sel_cursor = h.flat;
            ui.sel_dragging = true;
        } else ui.sel_msg = null;
    }
    if (ui.sel_dragging) {
        if (rl.isMouseButtonDown(.left)) {
            if (selHit(mp.x, mp.y)) |h| {
                if (ui.sel_msg == h.msg) ui.sel_cursor = h.flat;
            }
        } else ui.sel_dragging = false;
    }
    drawSelection();
    rl.endScissorMode();

    // floating "scroll to bottom": small, minimal, semi-transparent — only while scrolled away from the bottom.
    // Drawn OUTSIDE the scissor so it floats above the messages; click snaps to the bottom + re-arms sticky
    // follow.
    if (show_jump) {
        const jhot = t.hovering(jump_r);
        rl.drawRectangleRounded(jump_r, 1.0, 12, t.withAlpha(if (jhot) t.bg_sel else t.bg_hl, if (jhot) 235 else 170));
        rl.drawRectangleRoundedLinesEx(jump_r, 1.0, 12, 1.0, t.withAlpha(if (jhot) t.blue else t.border, 200));
        const g = t.z("v", .{});
        const gw: f32 = @floatFromInt(t.measure(g, 14));
        t.text(g, @intFromFloat(jump_r.x + (jump_r.width - gw) / 2), @intFromFloat(jump_r.y + (jump_r.height - 14) / 2 - 1), 14, if (jhot) t.fg else t.fg_dim);
        if (jhot) {
            t.wantCursor(.pointing_hand);
            if (rl.isMouseButtonPressed(.left)) {
                ui.chat_follow = true; // sticky follow re-armed; takes visual effect next frame (immediate-mode)
                ui.chat_scroll = max_scroll;
            }
        }
    }

    // status line — CLIPPED to leave room for the auto-loop label at the right (a long "subtask 5/6 (inline): ..."
    // status would otherwise run under the toggle). The auto-loop label geometry is computed FIRST so the clip
    // width subtracts it; both sit on the same status row.
    var sy = view.y + view.height + 4;
    const loop_state = blk: {
        store.lock();
        defer store.unlock();
        break :blk [2]bool{ store.chat_loop, store.chat_loop_afk };
    };
    const afk_on = loop_state[1];
    const loop_on = loop_state[0] or afk_on;
    const ltxt: [:0]const u8 = if (afk_on) t.z("auto-loop: afk", .{}) else if (loop_on) t.z("auto-loop: on", .{}) else t.z("auto-loop: off", .{});
    const ltw: f32 = @floatFromInt(t.measure(ltxt, 12));
    const status_clip_w: i32 = @intFromFloat(@max(60, r.width - ltw - 24)); // never overlap the auto-loop label
    if (busy) {
        const dots: usize = @intFromFloat(@mod(rl.getTime() * 2.5, 4.0));
        const dstr = [_][]const u8{ "", ".", "..", "..." };
        var sb: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&sb, "{s}{s}", .{ if (status.len > 0) status else "working", dstr[dots] }) catch "working";
        t.textClip(line, @intFromFloat(r.x + 4), @intFromFloat(sy), 12, t.cyan, status_clip_w);
    } else if (status.len > 0) {
        t.textClip(status, @intFromFloat(r.x + 4), @intFromFloat(sy), 12, t.comment, status_clip_w);
    }
    // AUTO-LOOP toggle (full-auto: the AI writes + sends its own next message toward the goal until DONE or the
    // 12-step cap). Plain clickable label — no button chrome; the TEXT alone turns green when engaged.
    // DOUBLE-CLICK escalates to the THIRD TIER, auto-loop-afk (orange): the loop NEVER backs itself out —
    // no DONE, no failure, no cap, no cast pause ends it; it runs until the user clicks it off or hits Stop.
    const ltog = t.Rect{ .x = r.x + r.width - ltw - 8, .y = sy - 3, .width = ltw + 10, .height = 17 };
    const lhot = t.hovering(ltog);
    t.text(ltxt, @intFromFloat(ltog.x + 3), @intFromFloat(sy), 12, if (afk_on) t.orange else if (loop_on) t.green else if (lhot) t.fg_dim else t.comment);
    if (lhot) t.wantCursor(.pointing_hand);
    if (lhot and rl.isMouseButtonPressed(.left)) {
        // Manual double-click detection (raylib has none): two presses on the label within 400ms. The first
        // press of the pair still runs the single-click toggle — the second overrides whatever it did with afk.
        const S = struct {
            var last_click: f64 = -1e9;
        };
        const nowt = rl.getTime();
        const dbl = (nowt - S.last_click) < 0.40;
        S.last_click = nowt;
        var mode: u8 = 0; // where this click landed: 0=off 1=on 2=afk
        {
            store.lock();
            defer store.unlock();
            if (dbl) { // double-click = enter afk from ANY state
                store.chat_loop = true;
                store.chat_loop_afk = true;
                mode = 2;
            } else if (store.chat_loop_afk) { // single click while afk = fully off (the way out, besides Stop)
                store.chat_loop_afk = false;
                store.chat_loop = false;
                mode = 0;
            } else {
                store.chat_loop = !store.chat_loop;
                mode = if (store.chat_loop) 1 else 0;
            }
        }
        // Turning it on with an idle, non-empty conversation kicks the first iteration immediately; otherwise it
        // engages after the next turn settles.
        if (mode > 0) store.pushChatCmd(store_mod.mkChatCmd(.loop_kick, "", ""));
        // Turning it OFF: for a LOCAL-engine turn this just stops new iterations (the in-flight turn finishes). But
        // when the SERVER is driving this conv's loop, ONE persistent turn IS the loop — clearing the local flag does
        // nothing to it, so post a Stop to actually halt the server-side loop (Stop is the sole afk exit besides this).
        if (mode == 0) {
            const server_driving = blk_sd: {
                store.lock();
                defer store.unlock();
                break :blk_sd store.chat_server_turn;
            };
            if (server_driving) store.pushChatCmd(store_mod.mkChatCmd(.stop_turn, "", ""));
        }
        if (mode == 2) {
            store.pushNotif("Auto-loop AFK", "runs forever - no DONE, failure, or cap stops it; click the toggle (or Stop) to end it", 1);
        } else if (mode == 1) {
            store.pushNotif("Auto-loop on", "the veil will drive the conversation until it's done (double-click for afk: never stops)", 1);
        } else {
            store.pushNotif("Auto-loop off", "stopping after the current turn", 1);
        }
    }
    sy += status_h;

    // input row — a growing/scrolling text area; the GRAB STRIP above it drag-resizes the row (crafting
    // a long prompt deserves room). Rows follow the dragged height so the extra space is real lines.
    const send_w: f32 = 92;
    const grab = t.Rect{ .x = r.x, .y = sy - 5, .width = r.width, .height = 8 };
    const grab_hot = t.hovering(grab) or ui.input_dragging;
    if (grab_hot) {
        t.fillRect(@intFromFloat(r.x + r.width / 2 - 24), @intFromFloat(sy - 3), 48, 3, t.withAlpha(t.blue, 170));
        t.wantCursor(.resize_ns);
        ui.input_active = true; // keep the frame rate up while adjusting
    }
    if (grab_hot and rl.isMouseButtonPressed(.left)) ui.input_dragging = true;
    if (ui.input_dragging) {
        if (rl.isMouseButtonDown(.left)) {
            ui.input_extra = std.math.clamp(ui.input_extra - rl.getMouseDelta().y, 0, @max(0, r.height * 0.5 - 66));
        } else ui.input_dragging = false;
    }
    const input_rows: usize = @intFromFloat(@max(3, @divTrunc(input_h - 16, 18))); // textArea's 18px line pitch
    const cf = t.Rect{ .x = r.x, .y = sy, .width = r.width - send_w - t.GAP, .height = input_h };
    textArea(cf, &ui.c_input, ui.focus == .c_input, if (afk_on) t.z("auto-loop-afk - the veil never stops; type to steer, Stop to end", .{}) else if (loop_on) t.z("auto-loop on - type to steer, or let the veil drive", .{}) else t.z("message the veil - Enter to send", .{}), .c_input, input_rows);
    // Send/Stop spans the full input row (same convention as the swarm-detail chat + console rows) —
    // deriving y/height from input_h keeps the two aligned even if the row height changes later.
    const sendb = t.Rect{ .x = r.x + r.width - send_w, .y = sy, .width = send_w, .height = input_h };
    // While a turn is generating (or auto-loop is driving), the send column offers control. For a SERVER turn
    // (steerable) it SPLITS into two stacked buttons — POST (blue: send the typed text as a live steer the running
    // turn folds in) over STOP (red: abort + halt auto-loop), making steering an explicit, discoverable action.
    // A local-engine turn has no steer sink, so it shows Stop alone.
    if (busy or loop_on) {
        const server_steerable = store.chat_server_turn;
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        const enter = (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) and !shift and ui.focus == .c_input;
        if (server_steerable) {
            const g: f32 = 6;
            const bh = (input_h - g) / 2;
            const postb = t.Rect{ .x = sendb.x, .y = sy, .width = send_w, .height = bh };
            const stopb = t.Rect{ .x = sendb.x, .y = sy + bh + g, .width = send_w, .height = bh };
            const can_post = ui.c_input.len > 0;
            const post_click = t.buttonSolid(postb, t.z("Post", .{}), t.blue, can_post);
            if (t.buttonSolid(stopb, t.z("Stop", .{}), t.red, true)) store.pushChatCmd(store_mod.mkChatCmd(.stop_turn, "", ""));
            if (can_post and (post_click or enter)) {
                store.pushChatCmd(store_mod.mkChatCmd(.steer_turn, "", ui.c_input.str()));
                ui.c_input.clear();
                ui.chat_follow = true;
            }
        } else {
            if (t.buttonSolid(sendb, t.z("Stop", .{}), t.red, true)) store.pushChatCmd(store_mod.mkChatCmd(.stop_turn, "", ""));
        }
    } else {
        const can_send = ui.c_input.len > 0;
        const clicked = t.buttonSolid(sendb, t.z("Send", .{}), t.blue, can_send);
        // Enter sends; Shift+Enter inserts a literal newline (drafting multi-paragraph prompts).
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        const enter_key = rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter);
        if (enter_key and shift and ui.focus == .c_input) ui.c_input.insert('\n');
        const enter = enter_key and !shift;
        if (can_send and (clicked or (ui.focus == .c_input and enter))) {
            store.pushChatCmd(store_mod.mkChatCmd(.send, "", ui.c_input.str()));
            ui.c_input.clear();
            ui.chat_follow = true;
        }
    }
}

/// A small labeled stat readout (label above, big value below) — compact, borderless, for the Metrics row.
fn metricStat(x: f32, y: f32, label: [:0]const u8, value: [:0]const u8) void {
    t.text(label, @intFromFloat(x), @intFromFloat(y), 11, t.comment);
    t.text(value, @intFromFloat(x), @intFromFloat(y + 15), 18, t.fg);
}

/// A titled bar chart of `vals` (one bar per turn, newest at the right), scaled to its own max. Bars for a
/// failed turn are tinted red. Returns the next y below the chart.
fn barRow(r: t.Rect, label: [:0]const u8, vals: []const f32, samples: []const store_mod.TurnMetric, color: t.Color, y: f32) f32 {
    const pad: f32 = 14;
    t.text(label, @intFromFloat(r.x + pad), @intFromFloat(y), 12, t.fg_dim);
    const gy = y + 18;
    const gh: f32 = 54;
    const gw = r.width - pad * 2;
    const n = vals.len;
    var maxv: f32 = 0.0001;
    for (vals) |v| {
        if (v > maxv) maxv = v;
    }
    // max-value label at the top-right of the chart
    t.text(t.z("{d:.0}", .{maxv}), @intFromFloat(r.x + r.width - pad - 44), @intFromFloat(y), 11, t.comment);
    const slot = if (n > 0) gw / @as(f32, @floatFromInt(n)) else gw;
    const bw = @max(2.0, slot - 1.0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const h = @max(1.0, vals[i] / maxv * gh);
        const bx = r.x + pad + @as(f32, @floatFromInt(i)) * slot;
        const c = if (samples[i].ok) color else t.red;
        t.fillRect(@intFromFloat(bx), @intFromFloat(gy + gh - h), @intFromFloat(bw), @intFromFloat(h), c);
    }
    t.hline(@intFromFloat(r.x + pad), @intFromFloat(gy + gh + 1), @intFromFloat(gw), t.border);
    return gy + gh + 20;
}

/// The Metrics inner tab — live per-turn performance graphs for the current model (tok/s, first-byte latency,
/// turn time) + aggregate stats. This is both the "how is it doing" developer view and the harness for
/// comparing open-source models on the same tasks.
fn drawChatMetrics(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    var samples: [store_mod.METRIC_RING]store_mod.TurnMetric = undefined;
    var model_buf: [96]u8 = undefined;
    store.lock();
    const total = store.turn_metric_count;
    const n = @min(total, store_mod.METRIC_RING);
    const startidx = if (total > store_mod.METRIC_RING) total % store_mod.METRIC_RING else 0;
    var i: usize = 0;
    while (i < n) : (i += 1) samples[i] = store.turn_metrics[(startidx + i) % store_mod.METRIC_RING];
    const kind = store.settings.chat_kind;
    const byok = store.settings.chat_byok;
    const model_n = store.settings.chat_model_len;
    @memcpy(model_buf[0..model_n], store.settings.chat_model[0..model_n]);
    store.unlock();

    const pad: f32 = 14;
    var y: f32 = r.y + 12;
    const prov_lbl: [:0]const u8 = switch (kind) {
        1 => t.zs(catalog.providers[@min(byok, catalog.providers.len - 1)].label),
        2 => t.z("custom endpoint", .{}),
        else => t.z("local (Ollama)", .{}),
    };
    t.text(t.z("Model performance", .{}), @intFromFloat(r.x + pad), @intFromFloat(y), 16, t.fg);
    t.text(prov_lbl, @intFromFloat(r.x + r.width - pad - @as(f32, @floatFromInt(t.measure(prov_lbl, 12)))), @intFromFloat(y + 3), 12, t.comment);
    y += 24;
    t.textClip(if (model_n > 0) model_buf[0..model_n] else "(no model set)", @intFromFloat(r.x + pad), @intFromFloat(y), 13, t.cyan, @intFromFloat(r.width - pad * 2));
    y += 26;

    if (n == 0) {
        t.text(t.z("no turns recorded yet - send a message and the graphs populate here.", .{}), @intFromFloat(r.x + pad), @intFromFloat(y + 8), 12, t.comment);
        return;
    }

    // aggregates: tok/s + first-byte over successful turns; success rate over all
    var sum_toks: f32 = 0;
    var toks_n: usize = 0;
    var sum_fb: f64 = 0;
    var oks: usize = 0;
    for (samples[0..n]) |s| {
        if (!s.ok) continue;
        oks += 1;
        sum_fb += @floatFromInt(s.first_byte_ms);
        if (s.tok_per_s > 0) {
            sum_toks += s.tok_per_s;
            toks_n += 1;
        }
    }
    const avg_toks: f32 = if (toks_n > 0) sum_toks / @as(f32, @floatFromInt(toks_n)) else 0;
    const avg_fb: f64 = if (oks > 0) sum_fb / @as(f64, @floatFromInt(oks)) else 0;
    const okpct: f32 = @as(f32, @floatFromInt(oks)) / @as(f32, @floatFromInt(n)) * 100.0;
    metricStat(r.x + pad, y, t.z("turns", .{}), t.z("{d}", .{total}));
    metricStat(r.x + pad + 120, y, t.z("avg tok/s", .{}), t.z("{d:.1}", .{avg_toks}));
    metricStat(r.x + pad + 250, y, t.z("avg 1st-byte", .{}), t.z("{d:.0} ms", .{avg_fb}));
    metricStat(r.x + pad + 400, y, t.z("success", .{}), t.z("{d:.0}%", .{okpct}));
    y += 52;

    var vals: [store_mod.METRIC_RING]f32 = undefined;
    for (0..n) |k| vals[k] = samples[k].tok_per_s;
    y = barRow(r, t.z("output tok/s (per turn)", .{}), vals[0..n], samples[0..n], t.green, y);
    for (0..n) |k| vals[k] = @floatFromInt(samples[k].first_byte_ms);
    y = barRow(r, t.z("first-byte latency (ms)", .{}), vals[0..n], samples[0..n], t.cyan, y);
    for (0..n) |k| vals[k] = @floatFromInt(samples[k].total_ms);
    y = barRow(r, t.z("turn time (ms)", .{}), vals[0..n], samples[0..n], t.blue, y);
}

fn castStatusColor(st: store_mod.CastStatus) t.Color {
    return switch (st) {
        .deploying => t.yellow,
        .running => t.green,
        .collecting => t.cyan,
        .finishing => t.blue,
        .done => t.comment,
        .failed => t.red,
    };
}

fn castStatusWord(st: store_mod.CastStatus) [:0]const u8 {
    return switch (st) {
        .deploying => t.z("deploying", .{}),
        .running => t.z("running", .{}),
        .collecting => t.z("stopping", .{}),
        .finishing => t.z("finishing", .{}),
        .done => t.z("done", .{}),
        .failed => t.z("failed", .{}),
    };
}

// a stable colour per memory category so the chips read at a glance
fn memCatColor(cat: []const u8) t.Color {
    if (std.mem.eql(u8, cat, "key")) return t.red;
    if (std.mem.eql(u8, cat, "login")) return t.yellow;
    if (std.mem.eql(u8, cat, "preference")) return t.cyan;
    return t.blue;
}
// proportional-font char budget per wrapped line (slightly conservative so a chunk never over-runs maxw)
fn memColsPerLine(size: i32, maxw: f32) usize {
    const cw = @as(f32, @floatFromInt(size)) * 0.62;
    return @max(6, @as(usize, @intFromFloat(@max(1, maxw / cw))));
}
fn memLineCount(text_len: usize, size: i32, maxw: f32) usize {
    const cpl = memColsPerLine(size, maxw);
    return @max(1, @min(6, (text_len + cpl - 1) / cpl));
}
// draw `text` char-wrapped (handles long unbroken tokens like API keys) up to 6 lines; returns lines drawn
fn drawMemText(text: []const u8, x: f32, y0: f32, size: i32, color: t.Color, maxw: f32) usize {
    const cpl = memColsPerLine(size, maxw);
    var off: usize = 0;
    var line: usize = 0;
    var y = y0;
    while (off < text.len and line < 6) {
        const end = @min(off + cpl, text.len);
        t.textClip(text[off..end], @intFromFloat(x), @intFromFloat(y), size, color, @intFromFloat(maxw));
        off = end;
        y += 16;
        line += 1;
    }
    return @max(1, line);
}

/// The Memory tab: the durable facts the chat AI keeps for the user (keys, logins, preferences). Each is a card
/// showing its category chip + the stored text (fully wrapped so a long key is readable) + an × to forget it.
/// The AI writes these via REMEMBER: (stored to neuron-db + memories.jsonl); this is the human-facing view.
fn drawChatMemory(store: *Store, r: t.Rect) void {
    var rows: [128]store_mod.MemRow = undefined;
    var props: [12]store_mod.PropRow = undefined;
    var n: usize = 0;
    var np: usize = 0;
    {
        store.lock();
        defer store.unlock();
        n = @min(store.chat_mem_count, rows.len);
        @memcpy(rows[0..n], store.chat_mem[0..n]);
        np = @min(store.chat_prop_count, props.len);
        @memcpy(props[0..np], store.chat_props[0..np]);
    }
    var yy0: f32 = r.y + 40;
    t.textClip("keys, logins & preferences the veil keeps for you", @intFromFloat(r.x + 12), @intFromFloat(yy0), 11, t.comment, @intFromFloat(r.width - 20));
    yy0 += 15;
    t.textClip(t.z("{d} saved  -  private to this machine", .{n}), @intFromFloat(r.x + 12), @intFromFloat(yy0), 11, t.comment, @intFromFloat(r.width - 20));
    yy0 += 22;
    if (n == 0 and np == 0) {
        t.text(t.z("nothing saved yet", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy0 + 6), 12, t.fg_dim);
        t.textClip("tell the veil something to keep -", @intFromFloat(r.x + 12), @intFromFloat(yy0 + 30), 11, t.comment, @intFromFloat(r.width - 20));
        t.textClip("\"my openai key is sk-...\", a login,", @intFromFloat(r.x + 12), @intFromFloat(yy0 + 46), 11, t.comment, @intFromFloat(r.width - 20));
        t.textClip("or a preference - and it lands here.", @intFromFloat(r.x + 12), @intFromFloat(yy0 + 62), 11, t.comment, @intFromFloat(r.width - 20));
        return;
    }
    const view = t.Rect{ .x = r.x + 1, .y = yy0, .width = r.width - 2, .height = r.y + r.height - yy0 - 6 };
    const txtw = view.width - 16 - 24; // card padding + the delete button gutter
    // total height for scroll clamping (proposal cards draw first, above the saved memories)
    var total: f32 = 4;
    {
        var pi: usize = 0;
        while (pi < np) : (pi += 1) total += 24 + @as(f32, @floatFromInt(memLineCount(props[pi].text_len, 12, txtw))) * 16 + 30;
        var i: usize = 0;
        while (i < n) : (i += 1) total += 24 + @as(f32, @floatFromInt(memLineCount(rows[i].text_len, 12, txtw))) * 16 + 6;
    }
    const max_scroll = if (total > view.height) total - view.height else 0;
    const wheel = rl.getMouseWheelMove();
    // hover the whole pane below the tab strip, not just the card viewport, so wheeling over the header
    // strip still scrolls
    if (wheel != 0 and t.hovering(.{ .x = r.x, .y = r.y + 32, .width = r.width, .height = r.height - 32 })) ui.mem_scroll -= wheel * 3 * 18;
    if (ui.mem_scroll < 0) ui.mem_scroll = 0;
    if (ui.mem_scroll > max_scroll) ui.mem_scroll = max_scroll;

    rl.beginScissorMode(@intFromFloat(view.x), @intFromFloat(view.y), @intFromFloat(view.width), @intFromFloat(view.height));
    defer rl.endScissorMode();
    var forget_idx: ?usize = null; // capture a delete click; act after the draw loop (don't mutate mid-draw)
    var accept_idx: ?usize = null; // proposal keep/drop clicks — same act-after-draw discipline
    var reject_idx: ?usize = null;
    var y: f32 = view.y - ui.mem_scroll;
    // PROPOSED (judge/curator) — quarantined learning entries awaiting the human's verdict. Accepting
    // promotes into the live scope the veil actually recalls from; rejecting discards. Until then they
    // bind nothing.
    var pi: usize = 0;
    while (pi < np) : (pi += 1) {
        const p = &props[pi];
        const lines = memLineCount(p.text_len, 12, txtw);
        const card_h = 24 + @as(f32, @floatFromInt(lines)) * 16 + 30;
        if (y + card_h >= view.y and y <= view.y + view.height) {
            const card = t.Rect{ .x = view.x + 4, .y = y + 2, .width = view.width - 8, .height = card_h - 4 };
            t.panelBordered(card, t.bg, t.blue);
            const chip: []const u8 = switch (p.scope) {
                1 => "skill?",
                2 => "user?",
                else => "lesson?",
            };
            t.text(t.z("[{s}] proposed - not yet binding", .{chip}), @intFromFloat(card.x + 8), @intFromFloat(card.y + 6), 11, t.blue);
            _ = drawMemText(p.textStr(), card.x + 8, card.y + 24, 12, t.fg, txtw);
            const by = card.y + card_h - 30;
            if (t.button(.{ .x = card.x + 8, .y = by, .width = t.btnW("keep", 22), .height = 22 }, t.z("keep", .{}), t.green, true)) accept_idx = pi;
            if (t.buttonGhost(.{ .x = card.x + 8 + t.btnW("keep", 22) + 8, .y = by, .width = t.btnW("drop", 22), .height = 22 }, t.z("drop", .{}), t.red, true)) reject_idx = pi;
        }
        y += card_h;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const m = &rows[i];
        const lines = memLineCount(m.text_len, 12, txtw);
        const card_h = 24 + @as(f32, @floatFromInt(lines)) * 16 + 6;
        if (y + card_h >= view.y and y <= view.y + view.height) {
            const card = t.Rect{ .x = view.x + 4, .y = y + 2, .width = view.width - 8, .height = card_h - 4 };
            t.panelBordered(card, t.bg, t.border);
            const cat = m.catStr();
            t.text(t.z("[{s}]", .{if (cat.len > 0) cat else "fact"}), @intFromFloat(card.x + 8), @intFromFloat(card.y + 6), 11, memCatColor(cat));
            const del = t.Rect{ .x = card.x + card.width - 26, .y = card.y + 4, .width = 22, .height = 20 };
            if (t.buttonGhost(del, t.z("x", .{}), t.red, true)) forget_idx = i;
            // copy the stored fact (keys/logins live here — copy is the whole point of keeping them)
            if (copyChip(card.x + card.width - 74, card.y + 4)) {
                copyToClipboard(m.textStr());
                markCopied();
            }
            _ = drawMemText(m.textStr(), card.x + 8, card.y + 24, 12, t.fg, txtw);
        }
        y += card_h;
    }
    if (forget_idx) |fi| store.pushChatCmd(store_mod.mkChatCmd(.forget_mem, "", rows[fi].textStr()));
    if (accept_idx) |ai2| {
        const tag = [1]u8{'0' + props[ai2].scope};
        store.pushChatCmd(store_mod.mkChatCmd(.prop_accept, tag[0..1], props[ai2].textStr()));
    }
    if (reject_idx) |ri| {
        const tag = [1]u8{'0' + props[ri].scope};
        store.pushChatCmd(store_mod.mkChatCmd(.prop_reject, tag[0..1], props[ri].textStr()));
    }
}

fn drawChatRight(store: *Store, r: t.Rect, open: bool, casts: []const store_mod.CastRow, tail: []const scan.Ev, plan: []const store_mod.PlanRow) void {
    t.panelBordered(r, t.bg_dark, t.border);
    if (!open) {
        // collapsed rail: a status dot when a cast is live so the user knows to expand it
        const live = casts.len > 0 and (casts[casts.len - 1].status == .deploying or casts[casts.len - 1].status == .running or casts[casts.len - 1].status == .collecting);
        if (live) t.statusDot(@intFromFloat(r.x + r.width / 2), @intFromFloat(r.y + 40), t.green);
        if (t.buttonGhost(.{ .x = r.x + 2, .y = r.y + 5, .width = r.width - 4, .height = 24 }, t.z("<", .{}), t.blue, true)) togglePane(store, false);
        return;
    }
    // collapse chevron + the "Swarm activity | Memory" tab strip (Memory = durable keys/logins/prefs the AI keeps)
    if (t.buttonGhost(.{ .x = r.x + r.width - 32, .y = r.y + 7, .width = 26, .height = 24 }, t.z(">", .{}), t.blue, true)) togglePane(store, false);
    const tl_act = t.z("Swarm activity", .{});
    const tl_mem = t.z("Memory", .{});
    if (t.tab(.{ .x = r.x + 8, .y = r.y + 7, .width = t.tabW(tl_act), .height = 24 }, tl_act, ui.right_tab == .activity)) ui.right_tab = .activity;
    if (t.tab(.{ .x = r.x + 8 + t.tabW(tl_act) + 6, .y = r.y + 7, .width = t.tabW(tl_mem), .height = 24 }, tl_mem, ui.right_tab == .memory)) ui.right_tab = .memory;
    if (ui.right_tab == .memory) {
        drawChatMemory(store, r);
        return;
    }

    var yy: f32 = r.y + 40;

    // ---- PLAN CHECKLIST: the ACTIVE conv's server plan-board, so plan progress is visible throughout the chat
    // (not just in the plan message that scrolls away). Done/active/pending per subtask + a mini route tag. ----
    if (plan.len > 0) {
        var done_n: usize = 0;
        for (plan) |*p| {
            if (p.status == .done) done_n += 1;
        }
        t.text(t.z("plan {d}/{d}", .{ done_n, plan.len }), @intFromFloat(r.x + 12), @intFromFloat(yy), 11, t.comment);
        yy += 18;
        const max_rows: usize = 10; // cap so the cast card + console keep room; the tail count says what's hidden
        const shown = @min(plan.len, max_rows);
        for (plan[0..shown]) |*p| {
            const pc = switch (p.status) {
                .done => t.green,
                .active => t.cyan,
                .pending => t.comment,
            };
            t.statusDot(@intFromFloat(r.x + 16), @intFromFloat(yy + 8), pc);
            const route = t.z("{s}", .{p.routeStr()});
            const rc = if (std.mem.eql(u8, p.routeStr(), "hive")) t.blue else if (std.mem.eql(u8, p.routeStr(), "research")) t.magenta else t.fg_dim;
            const rw: f32 = @floatFromInt(t.measureMono(route, 10));
            t.textMono(route, @intFromFloat(r.x + r.width - rw - 10), @intFromFloat(yy + 3), 10, rc);
            t.textClip(p.textStr(), @intFromFloat(r.x + 26), @intFromFloat(yy + 1), 12, if (p.status == .done) t.fg_dim else t.fg, @intFromFloat(r.width - 26 - rw - 20));
            yy += 17;
        }
        if (plan.len > shown) {
            t.text(t.z("+{d} more", .{plan.len - shown}), @intFromFloat(r.x + 26), @intFromFloat(yy + 1), 11, t.comment);
            yy += 17;
        }
        t.hline(@intFromFloat(r.x + 8), @intFromFloat(yy + 6), @intFromFloat(r.width - 16), t.border);
        yy += 14;
    }

    if (casts.len == 0) {
        if (plan.len == 0) {
            t.text(t.z("no casts yet", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 6), 13, t.comment);
            t.text(t.z("when a message needs real work", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 28), 11, t.comment);
            t.text(t.z("- research, current facts, web", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 44), 11, t.comment);
            t.text(t.z("- building or fixing code", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 60), 11, t.comment);
            t.text(t.z("the veil casts the hive and its", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 84), 11, t.comment);
            t.text(t.z("live progress appears here.", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 100), 11, t.comment);
        } else {
            t.text(t.z("no casts yet", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 6), 11, t.comment);
        }
        return;
    }

    // ---- the newest cast gets a prominent DETAIL card (goal + phase + metrics + Stop) ----
    const c = &casts[casts.len - 1];
    const live = c.status == .deploying or c.status == .running or c.status == .collecting;
    const card = t.Rect{ .x = r.x + 6, .y = yy, .width = r.width - 12, .height = 96 };
    t.panelBordered(card, t.bg, if (live) castStatusColor(c.status) else t.border);
    t.statusDot(@intFromFloat(card.x + 14), @intFromFloat(card.y + 16), castStatusColor(c.status));
    t.text(castStatusWord(c.status), @intFromFloat(card.x + 26), @intFromFloat(card.y + 10), 12, castStatusColor(c.status));
    if (c.run_len > 0) t.textClip(c.runStr(), @intFromFloat(card.x + 96), @intFromFloat(card.y + 11), 10, t.comment, @intFromFloat(card.width - 160));
    if (live) {
        const sb_label = t.z("Stop", .{});
        const sbw = t.btnW(sb_label, 22);
        const sb = t.Rect{ .x = card.x + card.width - sbw - 8, .y = card.y + 7, .width = sbw, .height = 22 };
        if (t.button(sb, sb_label, t.red, true)) store.pushChatCmd(store_mod.mkChatCmd(.stop_cast, c.runStr(), ""));
    }
    // goal, up to two clipped lines
    t.textClip(c.goalStr(), @intFromFloat(card.x + 14), @intFromFloat(card.y + 32), 13, t.fg, @intFromFloat(card.width - 28));
    // metrics row
    const mrt = if (c.pct >= 0) t.z("round {d}   {d}%", .{ c.round, c.pct }) else t.z("round {d}", .{c.round});
    t.text(mrt, @intFromFloat(card.x + 14), @intFromFloat(card.y + 56), 13, if (c.pct >= 100) t.green else if (c.pct >= 50) t.cyan else if (c.pct >= 0) t.yellow else t.comment);
    // open in the full Swarm tab for the complete console/metrics/files
    const ob_label = t.z("open swarm", .{});
    const obw = t.btnW(ob_label, t.BTN_SM);
    const ob = t.Rect{ .x = card.x + card.width - obw - 8, .y = card.y + card.height - t.BTN_SM - 6, .width = obw, .height = t.BTN_SM };
    if (c.run_len > 0 and t.button(ob, ob_label, t.blue, true)) {
        store.pushCmd(store_mod.mkCmd(.select, c.runStr(), ""));
        ui.tab = .swarm;
        ui.inner = .details;
    }
    // ...and the card BODY is the same link (the whole card reads as "this swarm" — clicking it should go
    // there, not just the small button). The Stop + open-swarm buttons keep their own clicks.
    if (c.run_len > 0 and t.hovering(card) and !t.hovering(ob)) {
        const stop_w = t.btnW(t.z("Stop", .{}), 22);
        const stop_rect = t.Rect{ .x = card.x + card.width - stop_w - 8, .y = card.y + 7, .width = stop_w, .height = 22 };
        if (!(live and t.hovering(stop_rect))) {
            t.wantCursor(.pointing_hand);
            if (rl.isMouseButtonPressed(.left)) {
                store.pushCmd(store_mod.mkCmd(.select, c.runStr(), ""));
                ui.tab = .swarm;
                ui.inner = .details;
            }
        }
    }
    yy += 104;

    // older casts, one compact line each (up to 2) — each row is a LINK to that swarm's detail page
    var shown_old: usize = 0;
    var i: usize = casts.len - 1;
    while (i > 0 and shown_old < 2) {
        i -= 1;
        const oc = &casts[i];
        const row = t.Rect{ .x = r.x + 6, .y = yy, .width = r.width - 12, .height = 17 };
        const row_hot = oc.run_len > 0 and t.hovering(row);
        if (row_hot) t.panel(row, t.bg_hl);
        t.statusDot(@intFromFloat(r.x + 14), @intFromFloat(yy + 8), castStatusColor(oc.status));
        t.textClip(oc.goalStr(), @intFromFloat(r.x + 24), @intFromFloat(yy + 2), 11, if (row_hot) t.fg else t.fg_dim, @intFromFloat(r.width - 70));
        t.text(t.z("r{d}", .{oc.round}), @intFromFloat(r.x + r.width - 40), @intFromFloat(yy + 2), 11, t.comment);
        if (row_hot) {
            t.wantCursor(.pointing_hand);
            if (rl.isMouseButtonPressed(.left)) {
                store.pushCmd(store_mod.mkCmd(.select, oc.runStr(), ""));
                ui.tab = .swarm;
                ui.inner = .details;
            }
        }
        yy += 18;
        shown_old += 1;
    }

    // ---- live console: the swarm's own event stream (this is what "shows its progress") ----
    t.hline(@intFromFloat(r.x + 8), @intFromFloat(yy + 4), @intFromFloat(r.width - 16), t.border);
    t.text(t.z("live hive console", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 10), 11, t.comment);
    // copy the visible event tail as plain text ("r{d} mind text" lines)
    if (tail.len > 0 and copyChip(r.x + r.width - 58, yy + 7)) {
        var n: usize = 0;
        for (tail) |*ev| {
            if (ev.round >= 0) bufAppend(&conv_buf, &n, t.z("r{d} ", .{ev.round}));
            if (ev.mindStr().len > 0) {
                bufAppend(&conv_buf, &n, ev.mindStr());
                bufAppend(&conv_buf, &n, " ");
            }
            bufAppend(&conv_buf, &n, ev.textStr());
            bufAppend(&conv_buf, &n, "\n");
        }
        if (n > 0) copyToClipboard(conv_buf[0..n]);
        markCopied();
    }
    yy += 28;
    rl.beginScissorMode(@intFromFloat(r.x + 1), @intFromFloat(yy), @intFromFloat(r.width - 2), @intFromFloat(r.y + r.height - yy - 4));
    defer rl.endScissorMode();
    if (tail.len == 0) {
        // the "while it loads" state — a cold local model can take a minute before the first event
        if (live) {
            t.text(t.z("starting the hive...", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 2), 12, t.cyan);
            t.textClip(t.z("a local model may be loading;", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 22), 11, t.comment, @intFromFloat(r.width - 20));
            t.textClip(t.z("cold starts can take a minute", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 38), 11, t.comment, @intFromFloat(r.width - 20));
        } else {
            t.text(t.z("(no console output)", .{}), @intFromFloat(r.x + 12), @intFromFloat(yy + 2), 11, t.comment);
        }
        return;
    }
    const line_h: f32 = 17;
    const avail: usize = if (r.y + r.height - 8 > yy) @intFromFloat((r.y + r.height - 8 - yy) / line_h) else 0;
    // wheel: scroll back through the event tail; 0 = follow
    const con = t.Rect{ .x = r.x + 1, .y = yy, .width = r.width - 2, .height = r.y + r.height - yy - 4 };
    const maxback: usize = if (tail.len > avail) tail.len - avail else 0;
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(con)) ui.cast_scroll += wheel * 3;
    if (ui.cast_scroll < 0) ui.cast_scroll = 0;
    if (ui.cast_scroll > @as(f32, @floatFromInt(maxback))) ui.cast_scroll = @floatFromInt(maxback);
    const back: usize = @intFromFloat(ui.cast_scroll);
    const endk = tail.len - back;
    const start = if (endk > avail) endk - avail else 0;
    var k = start;
    while (k < endk) : (k += 1) {
        const e = &tail[k];
        if (e.round >= 0) t.textMono(t.z("r{d}", .{e.round}), @intFromFloat(r.x + 10), @intFromFloat(yy), 11, t.comment);
        const mind = e.mindStr();
        if (mind.len > 0) t.textMonoClip(mind, @intFromFloat(r.x + 40), @intFromFloat(yy), 11, kindColor(e.kindStr()), 54);
        t.textMonoClip(e.textStr(), @intFromFloat(r.x + 96), @intFromFloat(yy), 11, t.fg_dim, @intFromFloat(r.width - 106));
        yy += line_h;
    }
}

// -------------------------------------------------------------------------------- deploy form

fn drawDeploy(store: *Store, body: t.Rect) void {
    t.setBlockClicks(ui.open_dd != .none); // same dropdown-overlay guard as Settings (cleared before flushDropdown)
    defer t.setBlockClicks(false);
    const pad: f32 = t.PAD;
    const x: f32 = pad;
    const colw = @min(body.width - pad * 2, 900);
    var y: f32 = body.y + pad;
    t.text(t.z("Deploy a swarm", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
    t.text(t.z("full configuration - the same knobs as the web console", .{}), @intFromFloat(x + 200), @intFromFloat(y + 6), 12, t.comment);
    y += 40;

    const prov = &catalog.providers[ui.d_provider];
    if (ui.d_model >= prov.models.len) ui.d_model = 0;

    // two columns
    const cw = (colw - t.PAD) / 2;
    const rx = x + cw + t.PAD;
    var ly = y;
    var ry = y;
    const fh: f32 = 48; // one field row: 14px label + 34px input
    const gap: f32 = t.GAP;

    // left column: identity + endpoint
    flabel(x, ly, "NAME");
    textField(.{ .x = x, .y = ly + 14, .width = cw, .height = t.FIELD_H }, &ui.d_name, ui.focus == .d_name, "swarm name", .d_name);
    ly += fh + gap;

    // "default" = inherit the CLIENT's configured chat LLM (Settings → CHAT MODEL): the swarm runs on
    // whatever brain the user already set up, no re-entering providers and keys per deploy.
    selector(.{ .x = x, .y = ly, .width = cw, .height = fh }, t.z("PROVIDER", .{}), if (ui.d_use_default) "default (your chat model)" else prov.label, .provider);
    ly += fh + gap;
    if (ui.d_use_default) {
        selector(.{ .x = x, .y = ly, .width = cw, .height = fh }, t.z("MODEL", .{}), "from Settings - chat model", .model);
        ly += fh + gap;
    } else {
        selector(.{ .x = x, .y = ly, .width = cw, .height = fh }, t.z("MODEL", .{}), prov.models[ui.d_model].label, .model);
        ly += fh + gap;
    }

    if (!ui.d_use_default and prov.needs_account) {
        flabel(x, ly, "CLOUDFLARE ACCOUNT ID (blank = use the server's own Workers AI creds)");
        textField(.{ .x = x, .y = ly + 14, .width = cw, .height = t.FIELD_H }, &ui.d_cfacct, ui.focus == .d_cfacct, "account id", .d_cfacct);
        ly += fh + gap;
    }
    if (!ui.d_use_default and prov.needs_key) {
        const kh: [:0]const u8 = if (std.mem.eql(u8, prov.key, "huggingface")) t.z("HF TOKEN (hf_...)", .{}) else if (prov.needs_account) t.z("CLOUDFLARE API TOKEN (blank = server creds)", .{}) else t.z("API KEY (nlk_... or provider key)", .{});
        flabel(x, ly, kh);
        textField(.{ .x = x, .y = ly + 14, .width = cw, .height = t.FIELD_H }, &ui.d_key, ui.focus == .d_key, "sk-... / nlk_...", .d_key);
        ly += fh + gap;
    }

    // right column: knobs
    ui.d_minds = t.stepper(.{ .x = rx, .y = ry, .width = cw, .height = fh }, t.z("MINDS", .{}), ui.d_minds, 1, 5);
    ry += fh + gap;
    selector(.{ .x = rx, .y = ry, .width = cw, .height = fh }, t.z("STYLE", .{}), catalog.styles[ui.d_style], .style);
    ry += fh + gap;
    selector(.{ .x = rx, .y = ry, .width = cw, .height = fh }, t.z("RUNTIME (min, 0=until stopped)", .{}), catalog.minutes_lbl[ui.d_minutes], .minutes);
    ry += fh + gap;
    selector(.{ .x = rx, .y = ry, .width = cw / 2 - 6, .height = fh }, t.z("STACK", .{}), catalog.stacks[ui.d_stack], .stack);
    selector(.{ .x = rx + cw / 2 + 6, .y = ry, .width = cw / 2 - 6, .height = fh }, t.z("MODE", .{}), catalog.modes[ui.d_mode], .mode);
    ry += fh + gap;

    // goal spans full width below the columns
    var gy = @max(ly, ry) + 6;
    flabel(x, gy, "GOAL");
    textField(.{ .x = x, .y = gy + 14, .width = colw, .height = 56 }, &ui.d_goal, ui.focus == .d_goal, "one line: what should the hive build or research?", .d_goal);
    gy += 14 + 56 + gap;

    // gateway
    flabel(x, gy, "GATEWAY MODEL (optional - cheap model for mechanical calls)");
    textField(.{ .x = x, .y = gy + 14, .width = colw, .height = t.FIELD_H }, &ui.d_gateway, ui.focus == .d_gateway, "blank = same as the minds", .d_gateway);
    gy += fh + gap;

    // RSI DIALS — the same knobs the deploy wizard writes into swarm.json (omitting them makes a
    // desktop-deployed swarm behave differently from a wizard one).
    flabel(x, gy, "RSI DIALS");
    gy += 20;
    const tcw = (colw - 3 * t.GAP) / 4;
    const c0 = x;
    const c1 = x + (tcw + t.GAP);
    const c2 = x + 2 * (tcw + t.GAP);
    const c3 = x + 3 * (tcw + t.GAP);
    if (t.checkbox(.{ .x = c0, .y = gy, .width = tcw, .height = 30 }, t.z("full autonomy", .{}), ui.d_autonomy_full)) ui.d_autonomy_full = !ui.d_autonomy_full;
    if (t.checkbox(.{ .x = c1, .y = gy, .width = tcw, .height = 30 }, t.z("internet research", .{}), ui.d_internet)) ui.d_internet = !ui.d_internet;
    if (t.checkbox(.{ .x = c2, .y = gy, .width = tcw, .height = 30 }, t.z("gap audit", .{}), ui.d_gap)) ui.d_gap = !ui.d_gap;
    if (t.checkbox(.{ .x = c3, .y = gy, .width = tcw, .height = 30 }, t.z("breakout", .{}), ui.d_breakout)) ui.d_breakout = !ui.d_breakout;
    gy += 36;
    if (t.checkbox(.{ .x = c0, .y = gy, .width = tcw, .height = 30 }, t.z("living hive", .{}), ui.d_population)) ui.d_population = !ui.d_population;
    if (t.checkbox(.{ .x = c1, .y = gy, .width = tcw, .height = 30 }, t.z("observe psyche", .{}), ui.d_psyche)) ui.d_psyche = !ui.d_psyche;
    if (t.checkbox(.{ .x = c2, .y = gy, .width = tcw, .height = 30 }, t.z("encrypt memory", .{}), ui.d_encrypt)) ui.d_encrypt = !ui.d_encrypt;
    gy += 30 + t.PAD;

    // deploy button
    const online = blk: {
        store.lock();
        defer store.unlock();
        break :blk store.server_online;
    };
    const ready = ui.d_goal.len > 0 and online;
    const db_label = t.z("Deploy swarm", .{});
    const db = t.Rect{ .x = x, .y = gy, .width = @max(160, t.btnW(db_label, t.BTN_LG)), .height = t.BTN_LG };
    if (t.buttonSolid(db, db_label, t.blue, ready)) {
        submitDeploy(store, prov);
    }
    const hint = if (!online) t.z("server offline - start it to deploy", .{}) else if (ui.d_goal.len == 0) t.z("enter a goal", .{}) else t.z("posts to /api/v1/swarms on :{d}", .{portOf(store)});
    t.text(hint, @intFromFloat(db.x + db.width + 14), @intFromFloat(gy + (t.BTN_LG - 12) / 2), 12, if (ready) t.comment else t.orange);

    // draw the open dropdown LAST so its list sits on top of the fields below it (unblock so options click).
    t.setBlockClicks(false);
    flushDropdown();
}

/// A closed dropdown button (label + current value + chevron). Clicking toggles its option list, which is
/// drawn on top by flushDropdown() after the whole form. `value` is the current selection's display text.
fn selector(r: t.Rect, label: [:0]const u8, value: []const u8, kind: DdKind) void {
    const open = ui.open_dd == kind;
    const hot = t.hovering(r);
    t.panelBordered(r, if (hot and !open) t.bg_hl else t.bg, if (open) t.blue else if (hot) t.fg_dim else t.border);
    t.text(label, @intFromFloat(r.x + 12), @intFromFloat(r.y + 7), 11, t.comment);
    t.textClip(value, @intFromFloat(r.x + 12), @intFromFloat(r.y + 22), 14, t.fg, @intFromFloat(r.width - 34));
    t.text(t.z("v", .{}), @intFromFloat(r.x + r.width - 22), @intFromFloat(r.y + (r.height - 13) / 2), 13, if (open or hot) t.blue else t.comment);
    // While any dropdown list is open, only its own anchor may toggle; this prevents list clicks from
    // leaking through to a selector drawn underneath the list in the same frame.
    const can_toggle = ui.open_dd == .none or open;
    if (can_toggle and hot) t.wantCursor(.pointing_hand);
    if (can_toggle and hot and rl.isMouseButtonPressed(.left)) {
        ui.open_dd = if (open) .none else kind;
        ui.dd_rect = r;
        ui.dd_scroll = 0;
    }
}

/// Render the currently-open dropdown's option list on top of the form and apply a selection.
fn flushDropdown() void {
    if (ui.open_dd == .none) return;
    switch (ui.open_dd) {
        .chat_provider, .chat_byok, .chat_model => return, // owned by flushChatDropdown (Settings tab)
        .sched_model => return, // owned by flushSchedDropdown (Tasks tab) — never rendered from the deploy form
        else => {},
    }
    // Build the option labels + current index for the open kind.
    var labels: [16][]const u8 = undefined;
    var count: usize = 0;
    var current: usize = 0;
    const prov = &catalog.providers[ui.d_provider];
    switch (ui.open_dd) {
        .provider => {
            // slot 0 = inherit the client's configured chat LLM; catalog providers shift up one
            labels[0] = "default (your chat model)";
            count = 1;
            for (catalog.providers, 0..) |p, i| {
                labels[i + 1] = p.label;
                count += 1;
            }
            current = if (ui.d_use_default) 0 else ui.d_provider + 1;
        },
        .model => {
            if (ui.d_use_default) { // the model comes from Settings; the list is informational only
                labels[0] = "from Settings - chat model";
                count = 1;
                current = 0;
            } else {
                for (prov.models, 0..) |m, i| {
                    labels[i] = m.label;
                    count += 1;
                }
                current = ui.d_model;
            }
        },
        .style => {
            for (catalog.styles, 0..) |s, i| {
                labels[i] = s;
                count += 1;
            }
            current = ui.d_style;
        },
        .minutes => {
            for (catalog.minutes_lbl, 0..) |s, i| {
                labels[i] = s;
                count += 1;
            }
            current = ui.d_minutes;
        },
        .stack => {
            for (catalog.stacks, 0..) |s, i| {
                labels[i] = s;
                count += 1;
            }
            current = ui.d_stack;
        },
        .mode => {
            for (catalog.modes, 0..) |s, i| {
                labels[i] = s;
                count += 1;
            }
            current = ui.d_mode;
        },
        .none, .chat_provider, .chat_byok, .chat_model, .sched_model => return,
    }
    const chosen = drawList(ui.dd_rect, labels[0..count], current);
    if (chosen) |ci| {
        switch (ui.open_dd) {
            .provider => {
                if (ci == 0) {
                    ui.d_use_default = true;
                } else {
                    ui.d_use_default = false;
                    ui.d_provider = ci - 1;
                    ui.d_model = 0;
                }
            },
            .model => {
                if (!ui.d_use_default) ui.d_model = ci;
            },
            .style => ui.d_style = ci,
            .minutes => ui.d_minutes = ci,
            .stack => ui.d_stack = ci,
            .mode => ui.d_mode = ci,
            .none, .chat_provider, .chat_byok, .chat_model, .sched_model => {},
        }
        ui.open_dd = .none;
    }
}

/// Tasks-form MODEL OVERRIDE dropdown: a flat "Provider - Model" pick list built from the shared catalog.
/// Row 0 clears the override (blank = the task inherits your chat model at run time). Picking a model writes
/// its wire id into ui.sc_model and — only when the base-URL field is still empty — auto-fills that provider's
/// base_url (skipping the {account}-templated Cloudflare base, which the server fills from its own creds), so
/// "pick a cloud model and go" works without hand-typing an endpoint. Never clobbers a base the user typed.
fn flushSchedDropdown() void {
    if (ui.open_dd != .sched_model) return;
    // label backing storage lives for the whole call (drawList borrows these slices) — same stack-buffer
    // idiom flushChatDropdown uses for its live Cloudflare list.
    var namebuf: [128][96]u8 = undefined;
    var labels: [128][]const u8 = undefined;
    var pmap: [128]struct { p: usize, m: usize } = undefined;
    labels[0] = "(your chat model - default)";
    var count: usize = 1;
    var current: usize = 0;
    const cur = ui.sc_model.str();
    outer: for (catalog.providers, 0..) |p, pi| {
        for (p.models, 0..) |m, mi| {
            if (count >= labels.len) break :outer;
            labels[count] = std.fmt.bufPrint(namebuf[count][0..], "{s} - {s}", .{ p.label, m.label }) catch m.label;
            pmap[count] = .{ .p = pi, .m = mi };
            if (cur.len > 0 and std.mem.eql(u8, cur, m.id)) current = count;
            count += 1;
        }
    }
    const chosen = drawList(ui.dd_rect, labels[0..count], current) orelse return;
    if (chosen == 0) {
        ui.sc_model.clear(); // inherit the chat model at run time; leave the base field as the user has it
    } else {
        const prov = &catalog.providers[pmap[chosen].p];
        setField(&ui.sc_model, prov.models[pmap[chosen].m].id);
        // Picking "Provider - Model" is an explicit PROVIDER choice, so keep the base in lockstep with the
        // model — otherwise a re-pick from a different provider leaves a stale base and the server (which
        // infers the provider FROM base_url, no provider field is sent) silently mis-wires the task. A
        // concrete base overwrites; an {account}-templated (Cloudflare) base clears to blank so the server
        // falls back to its own Workers AI creds instead of a URL with an unresolved placeholder.
        if (std.mem.indexOf(u8, prov.base_url, "{account}") == null)
            setField(&ui.sc_base, prov.base_url)
        else
            ui.sc_base.clear();
    }
    ui.open_dd = .none;
}

/// Draw a dropdown option list under `anchor` (or ABOVE it when the window edge is closer than the list);
/// returns the clicked ABSOLUTE index, or null. The list CLAMPS to the window — visible rows shrink to
/// what actually fits and the wheel scrolls through the rest, so an anchor near the bottom of a small
/// window can never strand options outside the window where no scroll could reach them.
fn drawList(anchor: t.Rect, labels: []const []const u8, current: usize) ?usize {
    const ih: f32 = 32;
    const total = labels.len;
    const win_h: f32 = @floatFromInt(rl.getScreenHeight());
    const below = win_h - (anchor.y + anchor.height + 4) - 8; // space under the anchor
    const above = anchor.y - 4 - 8; // space over it (used when below is cramped)
    var fit_below: usize = if (below > ih) @intFromFloat(@divTrunc(below - 8, ih)) else 0;
    var fit_above: usize = if (above > ih) @intFromFloat(@divTrunc(above - 8, ih)) else 0;
    fit_below = @min(fit_below, 9);
    fit_above = @min(fit_above, 9);
    const flip = fit_below < @min(total, 4) and fit_above > fit_below; // cramped below + more room above
    const vis = @max(1, @min(total, if (flip) fit_above else fit_below));
    const list_h = ih * @as(f32, @floatFromInt(vis)) + 8;
    const ly = if (flip) anchor.y - 4 - list_h else anchor.y + anchor.height + 4;
    const lr = t.Rect{ .x = anchor.x, .y = ly, .width = anchor.width, .height = list_h };
    t.panelBordered(lr, t.bg_dark, t.blue);

    var start: usize = 0;
    if (total > vis) {
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0 and t.hovering(lr)) ui.dd_scroll -= wheel;
        const maxoff: f32 = @floatFromInt(total - vis);
        if (ui.dd_scroll < 0) ui.dd_scroll = 0;
        if (ui.dd_scroll > maxoff) ui.dd_scroll = maxoff;
        start = @intFromFloat(ui.dd_scroll);
    }

    var yy = lr.y + 4;
    var clicked: ?usize = null;
    var i: usize = start;
    while (i < total and i < start + vis) : (i += 1) {
        const ir = t.Rect{ .x = lr.x + 4, .y = yy, .width = lr.width - 8, .height = ih };
        const hot = t.hovering(ir);
        if (i == current) t.panel(ir, t.bg_sel) else if (hot) t.panel(ir, t.bg_hl);
        if (hot) t.wantCursor(.pointing_hand);
        t.textClip(labels[i], @intFromFloat(ir.x + 12), @intFromFloat(ir.y + (ih - 13) / 2), 13, t.fg, @intFromFloat(ir.width - 24));
        if (hot and rl.isMouseButtonPressed(.left)) clicked = i;
        yy += ih;
    }
    // a subtle scrollbar thumb when the list overflows its clamped height
    if (total > vis) {
        const track_h = lr.height - 8;
        const thumb_h = @max(12.0, track_h * @as(f32, @floatFromInt(vis)) / @as(f32, @floatFromInt(total)));
        const thumb_y = lr.y + 4 + (track_h - thumb_h) * (ui.dd_scroll / @as(f32, @floatFromInt(total - vis)));
        t.fillRect(@intFromFloat(lr.x + lr.width - 5), @intFromFloat(thumb_y), 3, @intFromFloat(thumb_h), t.comment);
    }
    // click outside the list AND its anchor button closes it
    if (rl.isMouseButtonPressed(.left) and !t.hovering(lr) and !t.hovering(anchor)) ui.open_dd = .none;
    return clicked;
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
    // Resolve the Cloudflare {account} placeholder (no-op for every other provider) before sending.
    var basebuf: [256]u8 = undefined;
    var eff_base = catalog.resolveBase(prov, ui.d_cfacct.str(), &basebuf);
    var eff_provider: []const u8 = prov.key;
    var eff_model: []const u8 = prov.models[ui.d_model].id;
    var keybuf: [192]u8 = undefined;
    var modelbuf: [96]u8 = undefined;
    var eff_key: []const u8 = ui.d_key.str();
    if (ui.d_use_default) {
        // DEFAULT provider: the swarm inherits the client's configured chat LLM — the same per-field
        // resolution the task builder snapshots (Settings → CHAT MODEL), so one setup drives everything.
        store.lock();
        const s = &store.settings;
        var acct_scratch: [256]u8 = undefined;
        var bsl: []const u8 = undefined;
        var ksl: []const u8 = "";
        switch (s.chat_kind) {
            1 => {
                const p = &catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)];
                bsl = catalog.resolveBase(p, s.cfAccount(), &acct_scratch);
                ksl = s.chatKey();
                eff_provider = p.key;
            },
            2 => {
                bsl = s.chatBase();
                ksl = s.chatKey();
                eff_provider = "ollama"; // custom endpoint: keyless-tolerant provider tag; base+key travel explicitly
            },
            else => {
                bsl = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1";
                eff_provider = "ollama";
            },
        }
        const bn = @min(bsl.len, basebuf.len);
        @memcpy(basebuf[0..bn], bsl[0..bn]);
        eff_base = basebuf[0..bn];
        const kn = @min(ksl.len, keybuf.len);
        @memcpy(keybuf[0..kn], ksl[0..kn]);
        eff_key = keybuf[0..kn];
        var msl: []const u8 = s.chatModel();
        if (msl.len == 0) msl = if (s.chat_kind == 1) catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)].models[0].id else catalog.defaults.local_model;
        const mn = @min(msl.len, modelbuf.len);
        @memcpy(modelbuf[0..mn], msl[0..mn]);
        eff_model = modelbuf[0..mn];
        store.unlock();
    }
    w.writeAll("{\"name\":\"") catch return;
    jesc(&w, ui.d_name.str());
    w.print("\",\"provider\":\"{s}\",\"model\":\"{s}\",\"style\":\"{s}\",\"stack\":\"{s}\",\"mode\":\"{s}\",\"base_url\":\"{s}\",\"minutes\":{d},\"encrypt\":{s},\"veil_population\":{s},\"autonomy\":\"{s}\",\"internet\":{s},\"gap_assess\":{s},\"breakout\":{s},\"observe_psyche\":{s},\"api_key\":\"", .{
        eff_provider,           eff_model,                     catalog.styles[ui.d_style], catalog.stacks[ui.d_stack], catalog.modes[ui.d_mode],
        eff_base,               catalog.minutes[ui.d_minutes], boolStr(ui.d_encrypt),      boolStr(ui.d_population),   if (ui.d_autonomy_full) "full" else "bounded",
        boolStr(ui.d_internet), boolStr(ui.d_gap),             boolStr(ui.d_breakout),     boolStr(ui.d_psyche),
    }) catch return;
    jesc(&w, eff_key);
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

/// The Swarm tab: inner tabs LIVE (roster + selected swarm's activity/details/files) | DEPLOY (the full
/// deploy form — folded in from its old top tab; every entry point that used to jump to Deploy lands on
/// this inner tab via gotoDeploy).
fn drawSwarm(store: *Store, body: t.Rect) void {
    const pad: f32 = t.PAD;
    const tab_h: f32 = 26;
    const tl_live = t.z("Live", .{});
    const tl_deploy = t.z("Deploy", .{});
    var tx: f32 = pad;
    if (t.tab(.{ .x = tx, .y = body.y + pad, .width = t.tabW(tl_live), .height = tab_h }, tl_live, ui.swarm_inner == .live)) ui.swarm_inner = .live;
    tx += t.tabW(tl_live) + 6;
    if (t.tab(.{ .x = tx, .y = body.y + pad, .width = t.tabW(tl_deploy), .height = tab_h }, tl_deploy, ui.swarm_inner == .deploy)) ui.swarm_inner = .deploy;
    const r = t.Rect{ .x = body.x, .y = body.y + pad + tab_h + 2, .width = body.width, .height = body.height - pad - tab_h - 2 };
    switch (ui.swarm_inner) {
        .live => drawSwarmLive(store, r),
        .deploy => drawDeploy(store, r),
    }
}

fn drawSwarmLive(store: *Store, body: t.Rect) void {
    const pad: f32 = 12;
    const left_w: f32 = 270;
    const left = t.Rect{ .x = pad, .y = body.y + pad, .width = left_w, .height = body.height - pad * 2 };
    drawRoster(store, left);

    store.lock();
    const sel_n = store.selected_len;
    var sel: [96]u8 = undefined;
    @memcpy(sel[0..sel_n], store.selected[0..sel_n]);
    const m = store.metrics;
    const cfg = store.sel_config; // manifest + blueprint for the Details tab
    const ev_n = store.event_count;
    var evs: [scan.MAX_LOG]scan.Ev = undefined;
    @memcpy(evs[0..ev_n], store.events[0..ev_n]);
    // friendly name for the header (look up the selected swarm in the roster)
    var title: [64]u8 = undefined;
    var title_n: usize = 0;
    var sel_live = false;
    {
        var i: usize = 0;
        while (i < store.swarm_count) : (i += 1) {
            if (std.mem.eql(u8, store.swarms[i].idStr(), sel[0..sel_n])) {
                const nm = store.swarms[i].nameStr();
                title_n = @min(nm.len, title.len);
                @memcpy(title[0..title_n], nm[0..title_n]);
                sel_live = store.swarms[i].live;
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
    // inner tabs (Files / Console / Details) — right-aligned in the header row, sized to their labels
    const tl_f = t.z("Files", .{});
    const tl_c = t.z("Console", .{});
    const tl_d = t.z("Details", .{});
    const w_f = t.tabW(tl_f);
    const w_c = t.tabW(tl_c);
    const w_d = t.tabW(tl_d);
    const tabs_w = w_f + w_c + w_d + 12;
    t.textClip(title[0..title_n], @intFromFloat(rx), @intFromFloat(y), 18, t.fg, @intFromFloat(rw - tabs_w - 16));
    const it_files = t.Rect{ .x = rx + rw - tabs_w, .y = y - 2, .width = w_f, .height = 26 };
    const it_console = t.Rect{ .x = rx + rw - tabs_w + w_f + 6, .y = y - 2, .width = w_c, .height = 26 };
    const it_details = t.Rect{ .x = rx + rw - w_d, .y = y - 2, .width = w_d, .height = 26 };
    if (t.tab(it_files, tl_f, ui.inner == .files)) ui.inner = .files;
    if (t.tab(it_console, tl_c, ui.inner == .console)) ui.inner = .console;
    if (t.tab(it_details, tl_d, ui.inner == .details)) ui.inner = .details;
    y += 32;

    // controls + chat row live at the bottom for BOTH inner tabs
    const chat_h: f32 = 38;
    const ctrl_h: f32 = 32;
    const panel_bottom = body.y + body.height - pad - chat_h - 8 - ctrl_h - 8;
    const panel = t.Rect{ .x = rx, .y = y, .width = rw, .height = panel_bottom - y };
    switch (ui.inner) {
        .console => drawConsole(panel, evs[0..ev_n], sel_live),
        .details => drawDetails(panel, m, &cfg),
        .files => drawFiles(store, panel),
    }

    var cy = panel.y + panel.height + 8;
    const stop_lbl = t.z("Stop", .{});
    const goal_lbl = t.z("Set goal->chat", .{});
    const follow_lbl = if (ui.log_follow) t.z("following", .{}) else t.z("follow log", .{});
    var bx = rx;
    const stopb = t.Rect{ .x = bx, .y = cy, .width = t.btnW(stop_lbl, ctrl_h), .height = ctrl_h };
    if (t.button(stopb, stop_lbl, t.red, !m.stopped)) store.pushCmd(store_mod.mkCmd(.stop, sel[0..sel_n], ""));
    bx += stopb.width + 8;
    const goalb = t.Rect{ .x = bx, .y = cy, .width = t.btnW(goal_lbl, ctrl_h), .height = ctrl_h };
    if (t.button(goalb, goal_lbl, t.magenta, ui.chat.len > 0)) {
        store.pushCmd(store_mod.mkCmd(.set_goal, sel[0..sel_n], ui.chat.str()));
        ui.chat.clear();
    }
    bx += goalb.width + 8;
    // fixed slot wide enough for both labels so the row doesn't shift when "follow log" <-> "following"
    const follow_w = @max(t.btnW(t.z("follow log", .{}), ctrl_h), t.btnW(t.z("following", .{}), ctrl_h));
    const followb = t.Rect{ .x = bx, .y = cy, .width = follow_w, .height = ctrl_h };
    if (t.button(followb, follow_lbl, t.blue, true)) ui.log_follow = !ui.log_follow;
    bx += followb.width + 14;
    const stlab = if (m.stopped) t.z("stopped: {s}", .{m.stop_reason[0..m.stop_reason_len]}) else t.z("round {d} - best {d}%", .{ m.round, m.best_pct });
    t.text(stlab, @intFromFloat(bx), @intFromFloat(cy + (ctrl_h - 12) / 2), 12, if (m.stopped) t.comment else t.green);
    cy += ctrl_h + 8;

    const send_w: f32 = 92;
    const cf = t.Rect{ .x = rx, .y = cy, .width = rw - send_w - t.GAP, .height = chat_h };
    textField(cf, &ui.chat, ui.focus == .chat, "message the hive (say) - Enter to send", .chat);
    const sendb = t.Rect{ .x = rx + rw - send_w, .y = cy, .width = send_w, .height = chat_h };
    const send = t.buttonSolid(sendb, t.z("Send", .{}), t.blue, ui.chat.len > 0);
    if (send or (ui.focus == .chat and ui.chat.len > 0 and rl.isKeyPressed(.enter))) {
        store.pushCmd(store_mod.mkCmd(.say, sel[0..sel_n], ui.chat.str()));
        ui.chat.clear();
    }
}

fn drawDetails(r: t.Rect, m: scan.Metrics, cfg: *const scan.SwarmConfig) void {
    t.panelBordered(r, t.bg_dark, t.border);
    rl.beginScissorMode(@intFromFloat(r.x + 1), @intFromFloat(r.y + 1), @intFromFloat(r.width - 2), @intFromFloat(r.height - 2));
    defer rl.endScissorMode();
    const x = r.x + 16;
    var y = r.y + 16 - ui.details_scroll;
    const bottom = r.y + r.height - 8;
    // wheel: the goal + config + blueprint can outgrow the panel — scroll like the console does
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(r)) ui.details_scroll -= wheel * 3 * 19;
    if (ui.details_scroll < 0) ui.details_scroll = 0;
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
    y += 58;
    if (m.gradient_warn) {
        t.text(t.z("! zero-gradient warning - edits aren't reaching the failing check", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.orange);
        y += 22;
    }
    // ---- everything the run was GIVEN: the exact prompt + configuration (user ask: full transparency) ----
    if (!cfg.loaded) {
        t.hline(@intFromFloat(x), @intFromFloat(y + 4), @intFromFloat(r.width - 32), t.border);
        t.text(t.z("(no swarm.json in this run dir - config unknown)", .{}), @intFromFloat(x), @intFromFloat(y + 14), 12, t.comment);
        return;
    }
    const line_h: f32 = 19;
    const wrap_w: f32 = r.width - 48;
    t.hline(@intFromFloat(x), @intFromFloat(y + 2), @intFromFloat(r.width - 32), t.border);
    y += 12;
    // CONFIGURATION — one compact chips line + the mind roster
    t.text(t.z("CONFIGURATION", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
    y += 20;
    const conf1 = t.z("{s} · {s}", .{ cfg.provider[0..cfg.provider_len], cfg.model[0..cfg.model_len] });
    t.textClip(conf1, @intFromFloat(x), @intFromFloat(y), 13, t.fg, @intFromFloat(wrap_w));
    y += line_h;
    const conf2 = t.z("mode {s} · style {s} · {d} min · autonomy {s} · internet {s} · gap {s}", .{
        cfg.mode[0..cfg.mode_len],
        cfg.style[0..cfg.style_len],
        cfg.minutes,
        cfg.autonomy[0..cfg.autonomy_len],
        if (cfg.internet) "on" else "off",
        if (cfg.gap_assess) "on" else "off",
    });
    t.textClip(conf2, @intFromFloat(x), @intFromFloat(y), 13, t.fg_dim, @intFromFloat(wrap_w));
    y += line_h;
    if (cfg.minds_len > 0) {
        t.textClip(t.z("minds: {s}", .{cfg.mindsStr()}), @intFromFloat(x), @intFromFloat(y), 13, t.fg_dim, @intFromFloat(wrap_w));
        y += line_h;
    }
    y += 10;
    // GOAL — the full prompt, word-wrapped (mono so the byte-wrap matches the glyphs)
    if (y < bottom) {
        t.text(t.z("GOAL (the exact prompt the swarm was given)", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
        y += 20;
        const cols = monoCols(wrap_w, 13);
        var rest = cfg.goalStr();
        while (rest.len > 0 and y < bottom) {
            var take = @min(rest.len, cols);
            if (take < rest.len) {
                // break at the last space inside the window so words stay whole
                if (std.mem.lastIndexOfScalar(u8, rest[0..take], ' ')) |sp| {
                    if (sp > cols / 2) take = sp;
                }
            }
            // newlines inside the goal hard-break the line
            if (std.mem.indexOfScalar(u8, rest[0..take], '\n')) |nl| take = nl;
            t.textMonoClip(rest[0..take], @intFromFloat(x), @intFromFloat(y), 13, t.fg, @intFromFloat(wrap_w));
            y += line_h;
            rest = rest[@min(take + 1, rest.len)..];
        }
        if (cfg.goal_len == 0) {
            t.text(t.z("(no goal recorded)", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
            y += line_h;
        }
        y += 10;
    }
    // DELIVERABLES — the engine's .blueprint rows: the ground truth of what the run is being GRADED on
    if (y < bottom and cfg.blueprint_len > 0) {
        t.text(t.z("DELIVERABLES (the engine's blueprint - what gets graded)", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
        y += 20;
        var it = std.mem.splitScalar(u8, cfg.blueprintStr(), '\n');
        while (it.next()) |row| {
            if (y >= bottom) break;
            const tr = std.mem.trim(u8, row, " \r\t");
            if (tr.len == 0) continue;
            t.textMonoClip(tr, @intFromFloat(x + 4), @intFromFloat(y), 13, t.cyan, @intFromFloat(wrap_w - 4));
            y += line_h;
        }
    }
}

fn metricCell(x: f32, y: f32, lbl: [:0]const u8, value: [:0]const u8, accent: t.Color) void {
    t.text(lbl, @intFromFloat(x), @intFromFloat(y), 12, t.comment);
    t.text(value, @intFromFloat(x), @intFromFloat(y + 16), 22, accent);
}

fn scoreColor(pct: i32) t.Color {
    return if (pct >= 100) t.green else if (pct >= 50) t.cyan else if (pct >= 0) t.yellow else t.comment;
}

fn drawConsole(r: t.Rect, evs: []const scan.Ev, live: bool) void {
    t.panelBordered(r, t.bg_dark, t.border);
    rl.beginScissorMode(@intFromFloat(r.x + 1), @intFromFloat(r.y + 1), @intFromFloat(r.width - 2), @intFromFloat(r.height - 2));
    defer rl.endScissorMode();
    const line_h: f32 = 21;
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
    // Monospace + fixed pixel columns so round / mind / text line up like a real log. 14px + brighter
    // body color (fg vs fg_dim) for legibility.
    while (i < evs.len and yy < r.y + r.height - 4) : (i += 1) {
        const e = &evs[i];
        const kc = kindColor(e.kindStr());
        if (e.round >= 0) t.textMono(t.z("r{d}", .{e.round}), @intFromFloat(r.x + 10), @intFromFloat(yy), 14, t.comment);
        const mind = e.mindStr();
        if (mind.len > 0) t.textMonoClip(mind, @intFromFloat(r.x + 54), @intFromFloat(yy), 14, kc, 78);
        t.textMonoClip(e.textStr(), @intFromFloat(r.x + 142), @intFromFloat(yy), 14, t.fg, @intFromFloat(r.width - 152));
        yy += line_h;
    }
    if (evs.len == 0) {
        // Distinguish "just launched, worker still booting" from "idle/empty". A local model cold-starts
        // slowly (the 20B has to load), so the setup phase can show nothing for a minute — say so.
        if (live) {
            t.text(t.z("starting worker...", .{}), @intFromFloat(r.x + 14), @intFromFloat(r.y + 14), 14, t.cyan);
            t.text(t.z("waiting for the first events - a local model may be loading (cold-starts are slow); this can take a minute", .{}), @intFromFloat(r.x + 14), @intFromFloat(r.y + 38), 12, t.comment);
        } else {
            t.text(t.z("no events yet", .{}), @intFromFloat(r.x + 14), @intFromFloat(r.y + 14), 13, t.comment);
        }
    }
    // hover copy: the whole event log as plain text ("r{d} mind text" lines)
    if (evs.len > 0 and t.hovering(r)) {
        if (copyChip(r.x + r.width - 58, r.y + 6)) {
            var n: usize = 0;
            for (evs) |*ev| {
                if (ev.round >= 0) bufAppend(&conv_buf, &n, t.z("r{d} ", .{ev.round}));
                if (ev.mindStr().len > 0) {
                    bufAppend(&conv_buf, &n, ev.mindStr());
                    bufAppend(&conv_buf, &n, " ");
                }
                bufAppend(&conv_buf, &n, ev.textStr());
                bufAppend(&conv_buf, &n, "\n");
            }
            if (n > 0) copyToClipboard(conv_buf[0..n]);
            markCopied();
        }
    }
}

// -------------------------------------------------------------------------------- files (swarm outputs)

/// The Files inner tab: a two-pane viewer over the swarm's build workdir — the file list on the left
/// (from .build_manifest), the selected file's content on the right (mono, scrollable). This is where the
/// user sees + inspects what the hive is actually producing. Clicking a file asks the poller to load it.
fn drawFiles(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    const list_w: f32 = @min(280, r.width * 0.38);
    t.fillRect(@intFromFloat(r.x + list_w), @intFromFloat(r.y + 1), 1, @intFromFloat(r.height - 2), t.border);

    store.lock();
    const nfiles = store.file_count;
    var files: [scan.MAX_FILES]scan.FileRow = undefined;
    @memcpy(files[0..nfiles], store.files[0..nfiles]);
    var selfile: [128]u8 = undefined;
    const sfl = store.sel_file_len;
    @memcpy(selfile[0..sfl], store.sel_file[0..sfl]);
    const cl = store.file_content_len;
    var content: [1 << 14]u8 = undefined;
    @memcpy(content[0..cl], store.file_content[0..cl]);
    const trunc = store.file_content_trunc;
    store.unlock();

    // ---- left: file list (scrollable — a node_modules tree runs to hundreds of files) ----
    {
        const list_region = t.Rect{ .x = r.x + 1, .y = r.y + 1, .width = list_w - 2, .height = r.height - 2 };
        rl.beginScissorMode(@intFromFloat(list_region.x), @intFromFloat(list_region.y), @intFromFloat(list_region.width), @intFromFloat(list_region.height));
        defer rl.endScissorMode();
        if (nfiles == 0) {
            t.text(t.z("no files yet", .{}), @intFromFloat(r.x + 12), @intFromFloat(r.y + 12), 13, t.comment);
        }
        const row_h: f32 = 30;
        // wheel scroll (px), clamped so the last rows can always be reached. getMouseWheelMove isn't consumed
        // on read, so the content pane below can read it too — hover gates which one actually moves.
        const list_content_h: f32 = @as(f32, @floatFromInt(nfiles)) * row_h + 12;
        const list_maxs: f32 = if (list_content_h > list_region.height) list_content_h - list_region.height else 0;
        const lwheel = rl.getMouseWheelMove();
        if (lwheel != 0 and t.hovering(list_region)) ui.file_list_scroll -= lwheel * row_h * 3;
        if (ui.file_list_scroll < 0) ui.file_list_scroll = 0;
        if (ui.file_list_scroll > list_maxs) ui.file_list_scroll = list_maxs;
        var yy: f32 = r.y + 6 - ui.file_list_scroll;
        var i: usize = 0;
        while (i < nfiles) : (i += 1) {
            defer yy += row_h;
            if (yy + row_h < r.y or yy > r.y + r.height) continue; // cull rows fully outside the view (draw + hit-test)
            const f = &files[i];
            const rr = t.Rect{ .x = r.x + 5, .y = yy, .width = list_w - 10, .height = row_h - 4 };
            const is_sel = std.mem.eql(u8, f.pathStr(), selfile[0..sfl]);
            const hot = t.hovering(rr);
            if (is_sel) t.panel(rr, t.bg_sel) else if (hot) t.panel(rr, t.bg_hl);
            if (hot) t.wantCursor(.pointing_hand);
            t.textClip(f.pathStr(), @intFromFloat(rr.x + 8), @intFromFloat(rr.y + 3), 13, if (is_sel) t.fg else t.fg_dim, @intFromFloat(rr.width - 62));
            t.textMono(fmtSize(f.size), @intFromFloat(rr.x + rr.width - 50), @intFromFloat(rr.y + 4), 11, t.comment);
            if (hot and rl.isMouseButtonPressed(.left)) {
                store.pushCmd(store_mod.mkCmd(.open_file, "", f.pathStr()));
                ui.file_scroll = 0;
            }
        }
    }

    // ---- right: content ----
    const cx = r.x + list_w + 12;
    const cw = r.width - list_w - 20;
    if (sfl == 0) {
        t.text(t.z("select a file to view its contents", .{}), @intFromFloat(cx), @intFromFloat(r.y + 14), 13, t.comment);
        return;
    }
    t.textClip(selfile[0..sfl], @intFromFloat(cx), @intFromFloat(r.y + 10), 13, t.cyan, @intFromFloat(cw - 260));
    // header, right-to-left: [copy] [open folder] [(first 16 KB) when truncated] — the chip hugs the
    // pane's right edge instead of floating mid-pane where the (usually absent) note reserved room
    if (cl > 0 and copyChip(cx + cw - 44, r.y + 9)) {
        copyToClipboard(content[0..cl]);
        markCopied();
    }
    const ofl = t.z("open folder", .{});
    const ofw = t.btnW(ofl, 20);
    if (t.buttonGhost(.{ .x = cx + cw - 52 - ofw, .y = r.y + 6, .width = ofw, .height = 20 }, ofl, t.blue, true)) {
        var selb: [96]u8 = undefined;
        var seln: usize = 0;
        {
            store.lock();
            defer store.unlock();
            seln = @min(store.selected_len, selb.len);
            @memcpy(selb[0..seln], store.selected[0..seln]);
        }
        if (seln > 0) store.pushCmd(store_mod.mkCmd(.open_folder, selb[0..seln], ""));
    }
    if (trunc) t.text(t.z("(first 16 KB)", .{}), @intFromFloat(cx + cw - 60 - ofw - 100), @intFromFloat(r.y + 11), 11, t.orange);
    const view = t.Rect{ .x = cx, .y = r.y + 30, .width = cw, .height = r.height - 40 };
    rl.beginScissorMode(@intFromFloat(view.x), @intFromFloat(view.y), @intFromFloat(view.width), @intFromFloat(view.height));
    defer rl.endScissorMode();
    const line_h: f32 = 17;
    const visible: usize = @intFromFloat(view.height / line_h);
    // count lines for scroll clamp
    var total_lines: usize = 1;
    for (content[0..cl]) |ch| {
        if (ch == '\n') total_lines += 1;
    }
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(view)) ui.file_scroll -= wheel * 3;
    if (ui.file_scroll < 0) ui.file_scroll = 0;
    const maxs: f32 = if (total_lines > visible) @floatFromInt(total_lines - visible) else 0;
    if (ui.file_scroll > maxs) ui.file_scroll = maxs;
    const skip: usize = @intFromFloat(ui.file_scroll);
    var yy: f32 = view.y;
    var it = std.mem.splitScalar(u8, content[0..cl], '\n');
    var ln: usize = 0;
    while (it.next()) |line| : (ln += 1) {
        if (ln < skip) continue;
        if (yy > view.y + view.height - line_h) break;
        t.textMonoClip(line, @intFromFloat(view.x + 2), @intFromFloat(yy), 13, t.fg_dim, @intFromFloat(view.width - 6));
        yy += line_h;
    }
    if (cl == 0) t.text(t.z("(empty or still being written)", .{}), @intFromFloat(view.x + 2), @intFromFloat(view.y), 12, t.comment);
}

/// Compact human byte size for the file list ("824b" / "12k" / "3.4M").
fn fmtSize(sz: u64) [:0]const u8 {
    if (sz < 1024) return t.z("{d}b", .{sz});
    if (sz < 1024 * 1024) return t.z("{d}k", .{sz / 1024});
    return t.z("{d}.{d}M", .{ sz / (1024 * 1024), (sz % (1024 * 1024)) / (105 * 1024) });
}

/// The Chat FILES inner tab — a two-pane viewer for the files THIS conversation built (its {conv}/work dir),
/// mirroring the Swarm file viewer but fed by the chat worker's Store.chat_files channel. An "Open folder"
/// button reveals the dir in the OS file browser. The chat worker owns the IO; this only reads the Store.
fn drawChatFiles(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    const hdr_h: f32 = 30;
    t.text(t.z("files built in this chat", .{}), @intFromFloat(r.x + 12), @intFromFloat(r.y + 9), 13, t.comment);
    const of_label = t.z("Open folder", .{});
    const ofw = t.btnW(of_label, t.BTN_SM);
    if (t.button(.{ .x = r.x + r.width - ofw - 6, .y = r.y + 3, .width = ofw, .height = t.BTN_SM }, of_label, t.blue, true)) {
        store.pushChatCmd(store_mod.mkChatCmd(.chat_open_folder, "", ""));
    }
    const body = t.Rect{ .x = r.x, .y = r.y + hdr_h, .width = r.width, .height = r.height - hdr_h };
    const list_w: f32 = @min(280, body.width * 0.38);
    t.fillRect(@intFromFloat(body.x + list_w), @intFromFloat(body.y + 1), 1, @intFromFloat(body.height - 2), t.border);

    store.lock();
    const nfiles = store.chat_file_count;
    var files: [scan.MAX_FILES]scan.FileRow = undefined;
    @memcpy(files[0..nfiles], store.chat_files[0..nfiles]);
    var selfile: [128]u8 = undefined;
    const sfl = store.chat_sel_file_len;
    @memcpy(selfile[0..sfl], store.chat_sel_file[0..sfl]);
    const cl = store.chat_file_content_len;
    var content: [1 << 14]u8 = undefined;
    @memcpy(content[0..cl], store.chat_file_content[0..cl]);
    const trunc = store.chat_file_content_trunc;
    store.unlock();

    // ---- left: file list (scrollable) ----
    {
        const list_region = t.Rect{ .x = body.x + 1, .y = body.y + 1, .width = list_w - 2, .height = body.height - 2 };
        rl.beginScissorMode(@intFromFloat(list_region.x), @intFromFloat(list_region.y), @intFromFloat(list_region.width), @intFromFloat(list_region.height));
        defer rl.endScissorMode();
        if (nfiles == 0) {
            t.text(t.z("no files built in this chat yet", .{}), @intFromFloat(body.x + 12), @intFromFloat(body.y + 12), 13, t.comment);
        }
        const row_h: f32 = 30;
        const list_content_h: f32 = @as(f32, @floatFromInt(nfiles)) * row_h + 12;
        const list_maxs: f32 = if (list_content_h > list_region.height) list_content_h - list_region.height else 0;
        const lwheel = rl.getMouseWheelMove();
        if (lwheel != 0 and t.hovering(list_region)) ui.chat_file_list_scroll -= lwheel * row_h * 3;
        if (ui.chat_file_list_scroll < 0) ui.chat_file_list_scroll = 0;
        if (ui.chat_file_list_scroll > list_maxs) ui.chat_file_list_scroll = list_maxs;
        var yy: f32 = body.y + 6 - ui.chat_file_list_scroll;
        var i: usize = 0;
        while (i < nfiles) : (i += 1) {
            defer yy += row_h;
            if (yy + row_h < body.y or yy > body.y + body.height) continue; // cull rows outside the view
            const f = &files[i];
            const rr = t.Rect{ .x = body.x + 5, .y = yy, .width = list_w - 10, .height = row_h - 4 };
            const is_sel = std.mem.eql(u8, f.pathStr(), selfile[0..sfl]);
            const hot = t.hovering(rr);
            if (is_sel) t.panel(rr, t.bg_sel) else if (hot) t.panel(rr, t.bg_hl);
            if (hot) t.wantCursor(.pointing_hand);
            t.textClip(f.pathStr(), @intFromFloat(rr.x + 8), @intFromFloat(rr.y + 3), 13, if (is_sel) t.fg else t.fg_dim, @intFromFloat(rr.width - 62));
            t.textMono(fmtSize(f.size), @intFromFloat(rr.x + rr.width - 50), @intFromFloat(rr.y + 4), 11, t.comment);
            if (hot and rl.isMouseButtonPressed(.left)) {
                store.pushChatCmd(store_mod.mkChatCmd(.chat_open_file, "", f.pathStr()));
                ui.chat_file_scroll = 0;
            }
        }
    }

    // ---- right: content ----
    const cx = body.x + list_w + 12;
    const cw = body.width - list_w - 20;
    if (sfl == 0) {
        t.text(t.z("select a file to view its contents", .{}), @intFromFloat(cx), @intFromFloat(body.y + 14), 13, t.comment);
        return;
    }
    t.textClip(selfile[0..sfl], @intFromFloat(cx), @intFromFloat(body.y + 10), 13, t.cyan, @intFromFloat(cw - 170));
    if (trunc) t.text(t.z("(first 16 KB)", .{}), @intFromFloat(cx + cw - 160), @intFromFloat(body.y + 11), 11, t.orange);
    // copy the whole (loaded) file content — hugging the pane's right edge
    if (cl > 0 and copyChip(cx + cw - 44, body.y + 9)) {
        copyToClipboard(content[0..cl]);
        markCopied();
    }
    const view = t.Rect{ .x = cx, .y = body.y + 30, .width = cw, .height = body.height - 40 };
    rl.beginScissorMode(@intFromFloat(view.x), @intFromFloat(view.y), @intFromFloat(view.width), @intFromFloat(view.height));
    defer rl.endScissorMode();
    const line_h: f32 = 17;
    const visible: usize = @intFromFloat(view.height / line_h);
    var total_lines: usize = 1;
    for (content[0..cl]) |ch| {
        if (ch == '\n') total_lines += 1;
    }
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(view)) ui.chat_file_scroll -= wheel * 3;
    if (ui.chat_file_scroll < 0) ui.chat_file_scroll = 0;
    const maxs: f32 = if (total_lines > visible) @floatFromInt(total_lines - visible) else 0;
    if (ui.chat_file_scroll > maxs) ui.chat_file_scroll = maxs;
    const skip: usize = @intFromFloat(ui.chat_file_scroll);
    var yy: f32 = view.y;
    var it = std.mem.splitScalar(u8, content[0..cl], '\n');
    var ln: usize = 0;
    while (it.next()) |line| : (ln += 1) {
        if (ln < skip) continue;
        if (yy > view.y + view.height - line_h) break;
        t.textMonoClip(line, @intFromFloat(view.x + 2), @intFromFloat(yy), 13, t.fg_dim, @intFromFloat(view.width - 6));
        yy += line_h;
    }
    if (cl == 0) t.text(t.z("(empty or still being written)", .{}), @intFromFloat(view.x + 2), @intFromFloat(view.y), 12, t.comment);
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
    const pad: f32 = t.PAD;
    var y: f32 = body.y + pad;
    const x: f32 = pad;
    const colw = body.width - pad * 2;
    t.text(t.z("Hub - the fleet console", .{}), @intFromFloat(x), @intFromFloat(y), 20, t.fg);
    y += 38;
    const card = t.Rect{ .x = x, .y = y, .width = colw, .height = 150 };
    t.panelBordered(card, t.bg_dark, t.border);
    t.text(t.z("The running server already aggregates every swarm you own. The `veil hub`", .{}), @intFromFloat(x + 14), @intFromFloat(y + 14), 13, t.fg_dim);
    t.text(t.z("CLI operates the whole fleet at once, over the same API this dashboard uses:", .{}), @intFromFloat(x + 14), @intFromFloat(y + 34), 13, t.fg_dim);
    t.text(t.z("veil hub", .{}), @intFromFloat(x + 14), @intFromFloat(y + 62), 13, t.cyan);
    t.text(t.z("roster: fleet summary + every swarm's state", .{}), @intFromFloat(x + 150), @intFromFloat(y + 62), 12, t.comment);
    t.text(t.z("veil hub all \"...\"", .{}), @intFromFloat(x + 14), @intFromFloat(y + 84), 13, t.cyan);
    t.text(t.z("broadcast a directive to every swarm", .{}), @intFromFloat(x + 150), @intFromFloat(y + 84), 12, t.comment);
    t.text(t.z("veil hub stopall", .{}), @intFromFloat(x + 14), @intFromFloat(y + 106), 13, t.cyan);
    t.text(t.z("stop the whole fleet", .{}), @intFromFloat(x + 150), @intFromFloat(y + 106), 12, t.comment);
    y += 166;
    const card2 = t.Rect{ .x = x, .y = y, .width = colw, .height = 90 };
    t.panelBordered(card2, t.bg_dark, t.border);
    t.text(t.z("Many veils, one console", .{}), @intFromFloat(x + 14), @intFromFloat(y + 14), 14, t.fg);
    t.text(t.z("Cross-machine aggregation is a planned server endpoint; today the console", .{}), @intFromFloat(x + 14), @intFromFloat(y + 40), 12, t.comment);
    t.text(t.z("operates the local server's fleet. Run `veil hub help` for the full surface.", .{}), @intFromFloat(x + 14), @intFromFloat(y + 60), 12, t.comment);
}

// -------------------------------------------------------------------------------- settings

// -------------------------------------------------------------------------------- scheduled tasks

/// The Tasks tab: standing instructions the SERVER runs on its own clock — each run lands as a
/// scheduled_* server conversation that the Chat sidebar merges in. Two inner tabs like the Chat pane:
/// the task list and a builder form (which doubles as the EDIT form when a row's "edit" is clicked).
/// Every mutation rides the poller's command ring to the admin-gated /api/v1/sched routes; the poller
/// re-lists every few seconds so the rows track the server.
fn drawScheduled(store: *Store, body: t.Rect) void {
    const pad: f32 = t.PAD;
    const tab_h: f32 = 26;
    const editing = ui.sc_edit_id_len > 0;
    const tl_tasks = t.z("All tasks", .{});
    const tl_build = if (editing) t.z("Edit task", .{}) else t.z("Build a task", .{});
    var tx: f32 = pad;
    if (t.tab(.{ .x = tx, .y = body.y + pad, .width = t.tabW(tl_tasks), .height = tab_h }, tl_tasks, ui.sched_inner == .tasks)) ui.sched_inner = .tasks;
    tx += t.tabW(tl_tasks) + 6;
    if (t.tab(.{ .x = tx, .y = body.y + pad, .width = t.tabW(tl_build), .height = tab_h }, tl_build, ui.sched_inner == .build)) ui.sched_inner = .build;
    const r = t.Rect{ .x = pad, .y = body.y + pad + tab_h + 8, .width = body.width - pad * 2, .height = body.height - pad * 2 - tab_h - 8 };
    switch (ui.sched_inner) {
        .tasks => drawSchedTasks(store, r),
        .build => drawSchedBuild(store, r),
    }
}

/// Reset the builder form to a blank CREATE (clears any half-open edit): fields, provider override, and
/// the edit id all drop so the next submit mints a new task instead of overwriting the one last edited.
fn schedResetForm() void {
    ui.sc_name.clear();
    ui.sc_prompt.clear();
    ui.sc_details.clear();
    ui.sc_base.clear();
    ui.sc_model.clear();
    ui.sc_key.clear();
    ui.sc_kind = 0;
    ui.sc_once_min = 30;
    ui.sc_every_min = 30;
    ui.sc_hour = 9;
    ui.sc_minute = 0;
    ui.sc_enabled = true;
    ui.sc_edit_id_len = 0;
}

/// Enter EDIT mode for the task with this id: prefill every builder field from the store's full-fidelity
/// row (prompt/details round-trip verbatim — that is why SchedRow carries them uncut) and flip to the
/// builder tab. The key field stays BLANK: the server never echoes a stored api_key, and a blank key on
/// save means "keep what's stored".
fn schedBeginEdit(store: *Store, id: []const u8) void {
    store.lock();
    defer store.unlock();
    for (store.sched_rows[0..store.sched_count]) |*row| {
        if (!std.mem.eql(u8, row.idStr(), id)) continue;
        setField(&ui.sc_name, row.nameStr());
        setField(&ui.sc_prompt, row.promptStr());
        setField(&ui.sc_details, row.detailsStr());
        setField(&ui.sc_base, row.baseUrlStr());
        setField(&ui.sc_model, row.modelStr());
        ui.sc_key.clear(); // never echoed; blank = keep stored
        ui.sc_kind = @min(row.kind, 2);
        ui.sc_enabled = row.enabled;
        if (row.every_min > 0) ui.sc_every_min = @intCast(@min(row.every_min, 1440));
        if (parseHmUi(row.hmStr())) |hm| {
            ui.sc_hour = hm[0];
            ui.sc_minute = hm[1];
        }
        // a "once" task edits as "run in N minutes from now" — recomputed against the poller's clock
        if (row.kind == 0 and row.at > store.last_refresh_s and store.last_refresh_s > 0) {
            ui.sc_once_min = @intCast(std.math.clamp(@divTrunc(row.at - store.last_refresh_s, 60), 5, 1440));
        } else if (row.kind == 0) {
            ui.sc_once_min = 30;
        }
        const n = @min(id.len, ui.sc_edit_id.len);
        @memcpy(ui.sc_edit_id[0..n], id[0..n]);
        ui.sc_edit_id_len = @intCast(n);
        ui.sched_inner = .build;
        return;
    }
}

/// Lenient "HH:MM" → {hour, minute} for prefilling the daily steppers (UI twin of the server's parseHm).
fn parseHmUi(hm: []const u8) ?[2]i32 {
    const colon = std.mem.indexOfScalar(u8, hm, ':') orelse return null;
    const h = std.fmt.parseInt(i32, hm[0..colon], 10) catch return null;
    const m = std.fmt.parseInt(i32, hm[colon + 1 ..], 10) catch return null;
    if (h < 0 or h > 23 or m < 0 or m > 59) return null;
    return .{ h, m };
}

/// "every 30m" / "daily 09:00" / "once Jul 15 13:40" — one row's human schedule summary, composed at
/// draw time from the raw fields so it can never go stale against the clock. anytype: the list rows
/// draw from the slim SchedRowView, but any struct with the raw schedule fields works.
fn schedSummary(row: anytype, buf: []u8) []const u8 {
    switch (row.kind) {
        1 => {
            if (row.every_min >= 60 and row.every_min % 60 == 0) return std.fmt.bufPrint(buf, "every {d}h", .{row.every_min / 60}) catch "every ?";
            return std.fmt.bufPrint(buf, "every {d}m", .{row.every_min}) catch "every ?";
        },
        2 => return std.fmt.bufPrint(buf, "daily {s}", .{row.hmStr()}) catch "daily ?",
        else => {
            if (row.at <= 0) return "once";
            const mons = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            const es = std.time.epoch.EpochSeconds{ .secs = @intCast(row.at) };
            const monday = es.getEpochDay().calculateYearDay().calculateMonthDay(); // (md shadows the mdutil import)
            const ds = es.getDaySeconds();
            return std.fmt.bufPrint(buf, "once {s} {d} {d:0>2}:{d:0>2}", .{ mons[monday.month.numeric() - 1], monday.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "once";
        },
    }
}

/// "due in 12m" / "due in 3h 20m" / "overdue" — countdown against the poller's epoch clock (the UI
/// thread's only wall clock; raylib time is app-relative). Empty when the server gave no next_due.
fn schedDue(next_due: i64, now: i64, buf: []u8) []const u8 {
    if (next_due <= 0 or now <= 0) return "";
    const d = next_due - now;
    if (d <= 0) return "overdue";
    const mins = @divTrunc(d + 59, 60); // round up: "due in 1m" until it actually fires, never "0m"
    if (mins >= 60 * 24) return std.fmt.bufPrint(buf, "due in {d}d {d}h", .{ @divTrunc(mins, 60 * 24), @mod(@divTrunc(mins, 60), 24) }) catch "";
    if (mins >= 60) return std.fmt.bufPrint(buf, "due in {d}h {d}m", .{ @divTrunc(mins, 60), @mod(mins, 60) }) catch "";
    return std.fmt.bufPrint(buf, "due in {d}m", .{mins}) catch "";
}

/// The chat sidebar's Tasks inner tab: a COMPACT task list (name over due + runs). Row click opens the
/// task's newest run conversation right here in Chat; the small "run" fires it now (the poller then auto-opens
/// the minted conv). The Tasks TOP tab remains the full manager (builder form, edit, toggle, delete).
fn drawChatsSchedList(store: *Store, r: t.Rect) void {
    store.lock();
    var rows: [store_mod.MAX_SCHED]store_mod.SchedRowView = undefined;
    const n = store.sched_count;
    for (store.sched_rows[0..n], 0..) |*full, i| rows[i] = store_mod.SchedRowView.of(full);
    const online = store.server_online;
    const now = store.last_refresh_s;
    store.unlock();
    const list = t.Rect{ .x = r.x + 1, .y = r.y + 38, .width = r.width - 2, .height = r.height - 42 };
    if (n == 0) {
        t.text(t.z("no tasks yet -", .{}), @intFromFloat(r.x + t.PAD_IN), @intFromFloat(list.y + 6), 12, t.comment);
        t.text(t.z("ask the veil to schedule one", .{}), @intFromFloat(r.x + t.PAD_IN), @intFromFloat(list.y + 22), 12, t.comment);
        return;
    }
    const row_h: f32 = 42;
    const total: f32 = @as(f32, @floatFromInt(n)) * row_h;
    const max_scroll = if (total > list.height) total - list.height else 0;
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(list)) ui.sched_scroll -= wheel * row_h;
    if (ui.sched_scroll < 0) ui.sched_scroll = 0;
    if (ui.sched_scroll > max_scroll) ui.sched_scroll = max_scroll;
    rl.beginScissorMode(@intFromFloat(list.x), @intFromFloat(list.y), @intFromFloat(list.width), @intFromFloat(list.height));
    defer rl.endScissorMode();
    var yy: f32 = list.y + 4 - ui.sched_scroll;
    for (rows[0..n]) |*row| {
        if (yy + row_h < list.y or yy > list.y + list.height) {
            yy += row_h;
            continue;
        }
        const rr = t.Rect{ .x = r.x + 5, .y = yy, .width = r.width - 10, .height = row_h - 6 };
        const hot = t.hovering(rr);
        if (hot) t.panel(rr, t.bg_hl);
        t.textClip(row.nameStr(), @intFromFloat(rr.x + 8), @intFromFloat(rr.y + 5), 13, if (row.enabled) t.fg else t.fg_dim, @intFromFloat(rr.width - 52));
        var dueb: [48]u8 = undefined;
        var sub: [96]u8 = undefined;
        const due = if (row.enabled) schedDue(row.next_due, now, &dueb) else "paused";
        const line = std.fmt.bufPrint(&sub, "{s} - {d} runs", .{ due, row.runs }) catch "";
        if (line.len > 0) t.textClip(line, @intFromFloat(rr.x + 8), @intFromFloat(rr.y + 22), 11, t.comment, @intFromFloat(rr.width - 52));
        const runb = t.Rect{ .x = rr.x + rr.width - 40, .y = rr.y + (rr.height - 22) / 2, .width = 36, .height = 22 };
        const run_hot = t.hovering(runb);
        if (t.buttonGhost(runb, t.z("run", .{}), t.blue, online)) store.pushCmd(store_mod.mkCmd(.sched_run, row.idStr(), ""));
        if (hot and !run_hot) t.wantCursor(.pointing_hand);
        if (hot and !run_hot and rl.isMouseButtonPressed(.left)) {
            if (row.last_conv_len > 0) {
                store.pushChatCmd(store_mod.mkChatCmd(.select_conv, row.lastConvStr(), ""));
                ui.chats_inner = .chats; // jump back to the conversations list with the run selected
            } else {
                store.pushNotif("No runs yet", "press run to fire it now", 2);
            }
        }
        yy += row_h;
    }
}

/// The full task manager list: one row per task with its enabled toggle, schedule summary + countdown,
/// run count, the newest run's conversation (click → open it in Chat), "edit", "run now", and a hover ✕
/// delete (the conv-row pattern: fire the command, the next list refresh drops the row).
fn drawSchedTasks(store: *Store, r: t.Rect) void {
    t.panelBordered(r, t.bg_dark, t.border);
    store.lock();
    var rows: [store_mod.MAX_SCHED]store_mod.SchedRowView = undefined;
    const n = store.sched_count;
    for (store.sched_rows[0..n], 0..) |*full, i| rows[i] = store_mod.SchedRowView.of(full);
    const seen = store.sched_seen;
    const denied = store.sched_denied;
    const online = store.server_online;
    const now = store.last_refresh_s;
    store.unlock();

    if (n == 0) {
        const msg = if (denied)
            t.z("admin token required - connect the admin key in Settings", .{})
        else if (!online)
            t.z("server offline - start it to see tasks", .{})
        else if (!seen)
            t.z("fetching tasks...", .{})
        else
            t.z("no tasks yet - use Build a task", .{});
        t.text(msg, @intFromFloat(r.x + t.PAD_IN + 2), @intFromFloat(r.y + t.PAD_IN + 2), 13, t.comment);
        return;
    }

    const row_h: f32 = 58;
    const list = t.Rect{ .x = r.x + 1, .y = r.y + 1, .width = r.width - 2, .height = r.height - 2 };
    const total: f32 = @as(f32, @floatFromInt(n)) * row_h + 12;
    const max_scroll = if (total > list.height) total - list.height else 0;
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0 and t.hovering(list)) ui.sched_scroll -= wheel * row_h;
    if (ui.sched_scroll < 0) ui.sched_scroll = 0;
    if (ui.sched_scroll > max_scroll) ui.sched_scroll = max_scroll;
    rl.beginScissorMode(@intFromFloat(list.x), @intFromFloat(list.y), @intFromFloat(list.width), @intFromFloat(list.height));
    defer rl.endScissorMode();
    var yy: f32 = r.y + 6 - ui.sched_scroll;
    for (rows[0..n]) |*row| {
        // cull rows outside the view but keep advancing yy so offsets stay stable (the conv-list pattern)
        if (yy + row_h < list.y or yy > list.y + list.height) {
            yy += row_h;
            continue;
        }
        const rr = t.Rect{ .x = r.x + 6, .y = yy, .width = r.width - 12, .height = row_h - 6 };
        const hot = t.hovering(rr);
        if (hot) t.panel(rr, t.bg_hl);
        // enabled toggle (label-less checkbox): posts the DESIRED state; the ~1s re-list confirms it
        if (t.checkbox(.{ .x = rr.x + 10, .y = rr.y, .width = 18, .height = rr.height }, t.z("", .{}), row.enabled))
            store.pushCmd(store_mod.mkCmd(.sched_toggle, row.idStr(), if (row.enabled) "0" else "1"));
        // name (bold-ish 14) over the schedule summary + countdown + runs subtitle
        const name_w: f32 = @max(60, rr.width - 340);
        t.textClip(row.nameStr(), @intFromFloat(rr.x + 44), @intFromFloat(rr.y + 8), 14, if (row.enabled) t.fg else t.fg_dim, @intFromFloat(name_w));
        var sumb: [48]u8 = undefined;
        var dueb: [48]u8 = undefined;
        var sub: [200]u8 = undefined;
        const due = if (row.enabled) schedDue(row.next_due, now, &dueb) else "paused";
        const line = std.fmt.bufPrint(&sub, "{s}{s}{s}  -  {d} runs{s}", .{
            schedSummary(row, &sumb), if (due.len > 0) "  -  " else "", due, row.runs, if (row.prompt_len > 0) "  -  " else "",
        }) catch "";
        var lw: f32 = 0;
        if (line.len > 0) {
            t.textClip(line, @intFromFloat(rr.x + 44), @intFromFloat(rr.y + 29), 12, if (due.len > 0 and due[0] == 'o') t.orange else t.comment, @intFromFloat(name_w));
            lw = @floatFromInt(t.measure(t.zs(line), 12));
        }
        // the prompt preview trails the subtitle in the quietest color (the row's tooltip-substitute)
        if (row.prompt_len > 0 and lw + 30 < name_w) {
            t.textClip(row.promptStr(), @intFromFloat(rr.x + 44 + lw), @intFromFloat(rr.y + 29), 12, t.withAlpha(t.comment, 170), @intFromFloat(name_w - lw));
        }
        // ✕ delete (right edge, on row hover — the conv-row pattern)
        const xb = t.Rect{ .x = rr.x + rr.width - 30, .y = rr.y + (rr.height - 24) / 2, .width = 24, .height = 24 };
        if (hot and t.buttonGhost(xb, t.z("x", .{}), t.red, true)) {
            store.pushCmd(store_mod.mkCmd(.sched_delete, row.idStr(), ""));
        }
        // run now (always visible — it's the row's primary affordance)
        const run_label = t.z("run now", .{});
        const run_w = t.btnW(run_label, 24);
        const runb = t.Rect{ .x = rr.x + rr.width - 38 - run_w, .y = rr.y + (rr.height - 24) / 2, .width = run_w, .height = 24 };
        if (t.buttonGhost(runb, run_label, t.blue, online)) {
            store.pushCmd(store_mod.mkCmd(.sched_run, row.idStr(), ""));
        }
        // edit — opens the builder prefilled with this task (prompt, schedule, provider, recent runs)
        const edit_label = t.z("edit", .{});
        const edit_w = t.btnW(edit_label, 24);
        const editb = t.Rect{ .x = runb.x - 8 - edit_w, .y = rr.y + (rr.height - 24) / 2, .width = edit_w, .height = 24 };
        if (t.buttonGhost(editb, edit_label, t.cyan, true)) {
            schedBeginEdit(store, row.idStr());
        }
        // the newest run's conversation — click to open it in Chat (a server-side conv mirrors on select)
        var conv_label_hot = false;
        if (row.last_conv_len > 0) {
            const cw: f32 = @min(170, @max(0, editb.x - (rr.x + 44 + name_w) - 12));
            if (cw > 40) {
                const cr = t.Rect{ .x = editb.x - cw - 8, .y = rr.y + (rr.height - 14) / 2, .width = cw, .height = 16 };
                conv_label_hot = t.hovering(cr);
                t.textClip(row.lastConvStr(), @intFromFloat(cr.x), @intFromFloat(cr.y), 12, if (conv_label_hot) t.fg else t.cyan, @intFromFloat(cw));
                if (conv_label_hot) t.wantCursor(.pointing_hand);
                if (conv_label_hot and rl.isMouseButtonPressed(.left)) {
                    store.pushChatCmd(store_mod.mkChatCmd(.select_conv, row.lastConvStr(), ""));
                    setTab(.chat);
                }
            }
        }
        // ROW CLICK → the same jump: the whole row is the natural target (the tiny label alone was missed).
        // Excludes the row's own controls (checkbox / edit / run now / delete / conv label) so their clicks stay theirs.
        const cb_r = t.Rect{ .x = rr.x + 10, .y = rr.y, .width = 18, .height = rr.height };
        const row_hot = hot and !t.hovering(cb_r) and !t.hovering(runb) and !t.hovering(editb) and !t.hovering(xb) and !conv_label_hot;
        if (row_hot and row.last_conv_len > 0) t.wantCursor(.pointing_hand);
        if (row_hot and rl.isMouseButtonPressed(.left)) {
            if (row.last_conv_len > 0) {
                store.pushChatCmd(store_mod.mkChatCmd(.select_conv, row.lastConvStr(), ""));
                setTab(.chat);
            } else {
                store.pushNotif("No runs yet", "this task hasn't produced a chat - press run now", 2);
            }
        }
        yy += row_h;
    }
}

/// The builder form: name + prompt + key details, a click-to-cycle schedule kind with its kind-specific
/// steppers, a per-task PROVIDER OVERRIDE (base URL / model / key), and the create-or-save action. The
/// same form serves CREATE and EDIT (sc_edit_id set → editing); in edit mode a RECENT RUNS panel sits
/// beside the form so a task's last few conversations are one click from the thing that minted them.
fn drawSchedBuild(store: *Store, r: t.Rect) void {
    // While the MODEL dropdown is open, block the form's fields/buttons from eating a click meant for the
    // option list drawn over them (flushSchedDropdown clears this before drawing the list). Mirrors the
    // Settings/Deploy dropdown-overlay guard.
    t.setBlockClicks(ui.open_dd != .none);
    defer t.setBlockClicks(false);
    const x = r.x;
    var y = r.y;
    const editing = ui.sc_edit_id_len > 0;
    // in edit mode reserve a right-hand column for the recent-runs panel when the window allows it
    const runs_w: f32 = 280;
    const want_runs = editing and r.width >= 560 + runs_w;
    const colw = @min(if (want_runs) r.width - runs_w - 24 else r.width, 760);
    const fh: f32 = 48; // one field row: 14px label + 34px input
    const area_h: f32 = 88; // a 4-row textArea (8px pad + 4×18px lines + 8px pad)
    const gap: f32 = t.GAP;

    if (editing) {
        var eb: [96]u8 = undefined;
        const el = std.fmt.bufPrint(&eb, "editing: {s}", .{ui.sc_edit_id[0..ui.sc_edit_id_len]}) catch "editing";
        t.text(t.zs(el), @intFromFloat(x), @intFromFloat(y), 12, t.cyan);
        y += 20;
    }

    flabel(x, y, "NAME");
    textField(.{ .x = x, .y = y + 14, .width = colw, .height = t.FIELD_H }, &ui.sc_name, ui.focus == .sc_name, "what to call this task", .sc_name);
    y += fh + gap;

    flabel(x, y, "PROMPT (the message the veil receives on every run)");
    textArea(.{ .x = x, .y = y + 14, .width = colw, .height = area_h }, &ui.sc_prompt, ui.focus == .sc_prompt, "e.g. check the overnight build logs and summarize any failures", .sc_prompt, 4);
    y += 14 + area_h + gap;

    flabel(x, y, "KEY DETAILS / DATA (context every run should carry)");
    textArea(.{ .x = x, .y = y + 14, .width = colw, .height = area_h }, &ui.sc_details, ui.focus == .sc_details, "paths, hosts, formats, constraints - anything the run needs to know", .sc_details, 4);
    y += 14 + area_h + gap;

    // schedule kind: click-to-cycle (three options — a floating dropdown would be overkill), with the
    // kind's own knobs beside it. once = fire at submit+N; every = repeat on an interval; daily = HH:MM.
    const half = (colw - gap) / 2;
    const kinds = [_][:0]const u8{ t.z("once", .{}), t.z("every N min", .{}), t.z("daily at", .{}) };
    const kd = t.cycle(.{ .x = x, .y = y, .width = half, .height = fh }, t.z("SCHEDULE", .{}), kinds[ui.sc_kind], false);
    if (kd != 0) ui.sc_kind = wrap(ui.sc_kind, kd, kinds.len);
    switch (ui.sc_kind) {
        1 => ui.sc_every_min = t.stepper(.{ .x = x + half + gap, .y = y, .width = half, .height = fh }, t.z("EVERY (minutes)", .{}), ui.sc_every_min, 5, 1440),
        2 => {
            const q = (half - gap) / 2;
            ui.sc_hour = t.stepper(.{ .x = x + half + gap, .y = y, .width = q, .height = fh }, t.z("HOUR (24h)", .{}), ui.sc_hour, 0, 23);
            ui.sc_minute = t.stepper(.{ .x = x + half + gap + q + gap, .y = y, .width = q, .height = fh }, t.z("MINUTE", .{}), ui.sc_minute, 0, 59);
        },
        else => ui.sc_once_min = t.stepper(.{ .x = x + half + gap, .y = y, .width = half, .height = fh }, t.z("RUN IN (minutes)", .{}), ui.sc_once_min, 5, 1440),
    }
    y += fh + gap;

    // per-task provider: THIS task's runs can use a different brain than your chat. Create: all three
    // blank = snapshot the chat provider from Settings, per-field otherwise. Edit: what's shown is what's
    // stored; a blank key keeps the stored one (the server never echoes keys back).
    flabel(x, y, "MODEL OVERRIDE (this task can run on its own provider)");
    textField(.{ .x = x, .y = y + 14, .width = half, .height = t.FIELD_H }, &ui.sc_base, ui.focus == .sc_base, "base URL - blank = your chat provider's", .sc_base);
    // MODEL: a dropdown populated from the shared model catalog (was a free-text field). Shows the chosen
    // model id, or the default hint when blank. The option list + selection are handled by flushSchedDropdown
    // after the whole form draws (so the list sits on top of the fields below it).
    const model_disp: []const u8 = if (ui.sc_model.len > 0) ui.sc_model.str() else "model - blank = your chat model";
    selector(.{ .x = x + half + gap, .y = y + 14, .width = half, .height = t.FIELD_H }, t.z("MODEL", .{}), model_disp, .sched_model);
    y += fh + 4;
    textField(.{ .x = x, .y = y + 14, .width = colw, .height = t.FIELD_H }, &ui.sc_key, ui.focus == .sc_key, if (editing) "API key - blank = keep the stored key" else "API key - blank = your chat provider's", .sc_key);
    y += fh + gap;

    if (t.checkbox(.{ .x = x, .y = y, .width = 200, .height = 30 }, t.z("enabled", .{}), ui.sc_enabled)) ui.sc_enabled = !ui.sc_enabled;
    y += 36;

    const online = blk: {
        store.lock();
        defer store.unlock();
        break :blk store.server_online;
    };
    const cb_label = if (editing) t.z("Save changes", .{}) else t.z("Create task", .{});
    const cb = t.Rect{ .x = x, .y = y, .width = @max(160, t.btnW(cb_label, t.BTN_LG)), .height = t.BTN_LG };
    if (t.buttonSolid(cb, cb_label, t.blue, online)) submitSched(store);
    var hx = cb.x + cb.width + 10;
    if (editing) {
        const cancel_label = t.z("Cancel", .{});
        const cancelb = t.Rect{ .x = hx, .y = y, .width = t.btnW(cancel_label, t.BTN_LG), .height = t.BTN_LG };
        if (t.buttonGhost(cancelb, cancel_label, t.comment, true)) {
            schedResetForm();
            ui.sched_inner = .tasks;
        }
        hx = cancelb.x + cancelb.width + 14;
    }
    const hint = if (!online) t.z("server offline - start it first", .{}) else if (editing) t.z("updates the task in place (admin)", .{}) else t.z("posts to /api/v1/sched (admin)", .{});
    t.text(hint, @intFromFloat(hx + 4), @intFromFloat(y + (t.BTN_LG - 12) / 2), 12, if (online) t.comment else t.orange);

    if (want_runs) drawSchedRecentRuns(store, .{ .x = x + colw + 24, .y = r.y, .width = runs_w, .height = r.height });

    // draw the open MODEL dropdown LAST so its list sits on top of the fields below it (unblock so options click)
    t.setBlockClicks(false);
    flushSchedDropdown();
}

/// EDIT-mode side panel: the task's recent run conversations (the server keeps the newest five), newest
/// first, each clickable → opens that conversation in Chat. This is the investigation path for "what did
/// this task actually do last night?" — the runs are real chats, so the full transcript is right there.
fn drawSchedRecentRuns(store: *Store, r: t.Rect) void {
    flabel(r.x, r.y, "RECENT RUNS (newest first)");
    // frame-time lookup by the edit id: the poller may refresh recent_convs while the form is open (a
    // run finishing mid-edit), and this stays live where an edit-begin snapshot would go stale.
    var recent: [340]u8 = undefined;
    var recent_len: usize = 0;
    var last: [64]u8 = undefined;
    var last_len: usize = 0;
    {
        store.lock();
        defer store.unlock();
        for (store.sched_rows[0..store.sched_count]) |*row| {
            if (!std.mem.eql(u8, row.idStr(), ui.sc_edit_id[0..ui.sc_edit_id_len])) continue;
            recent_len = @min(row.recent_len, recent.len);
            @memcpy(recent[0..recent_len], row.recent[0..recent_len]);
            last_len = @min(row.last_conv_len, last.len);
            @memcpy(last[0..last_len], row.last_conv[0..last_len]);
            break;
        }
    }
    // tasks from before run history existed have last_conv but an empty recent list — show what we have
    const list = if (recent_len > 0) recent[0..recent_len] else last[0..last_len];
    var y = r.y + 18;
    if (list.len == 0) {
        t.text(t.z("no runs yet - press run now", .{}), @intFromFloat(r.x), @intFromFloat(y), 12, t.comment);
        return;
    }
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |conv| {
        if (conv.len == 0) continue;
        if (y > r.y + r.height - 16) break;
        const cr = t.Rect{ .x = r.x, .y = y, .width = r.width - 4, .height = 16 };
        const hot = t.hovering(cr);
        t.textClip(conv, @intFromFloat(cr.x), @intFromFloat(cr.y), 12, if (hot) t.fg else t.cyan, @intFromFloat(cr.width));
        if (hot) t.wantCursor(.pointing_hand);
        if (hot and rl.isMouseButtonPressed(.left)) {
            store.pushChatCmd(store_mod.mkChatCmd(.select_conv, conv, ""));
            setTab(.chat);
        }
        y += 20;
    }
}

/// Validate + package the builder form and hand it to the poller. The payload rides the store's dedicated
/// slot, NOT Command.text — three 1200-byte fields at worst-case 2x escaping outgrow it. CREATE resolves
/// blank provider fields from the Settings chat provider per-field (all blank = exactly the old snapshot
/// behavior); EDIT sends the form verbatim as a partial update, omitting api_key when blank so the stored
/// key survives an unrelated edit.
fn submitSched(store: *Store) void {
    if (ui.sc_name.len == 0 or ui.sc_prompt.len == 0) {
        store.pushNotif("Task incomplete", "give the task a name and a prompt", 2);
        return;
    }
    const editing = ui.sc_edit_id_len > 0;
    var basebuf: [256]u8 = undefined;
    var keybuf: [192]u8 = undefined;
    var modelbuf: [96]u8 = undefined;
    var base: []const u8 = ui.sc_base.str();
    var key: []const u8 = ui.sc_key.str();
    var model: []const u8 = ui.sc_model.str();
    var now: i64 = 0;
    {
        store.lock();
        defer store.unlock();
        const s = &store.settings;
        now = store.last_refresh_s; // the poller's epoch clock — the UI thread's only wall clock
        if (!editing) {
            // CREATE: any blank provider field falls back to the chat provider from Settings, resolved
            // exactly the way the chat thread does — all three blank reproduces the old full snapshot.
            var acct_scratch: [256]u8 = undefined;
            var b: []const u8 = undefined;
            var k: []const u8 = "";
            switch (s.chat_kind) {
                1 => {
                    // resolveBase substitutes the Cloudflare {account} placeholder (no-op for every other provider)
                    b = catalog.resolveBase(&catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)], s.cfAccount(), &acct_scratch);
                    k = s.chatKey();
                },
                2 => {
                    b = s.chatBase();
                    k = s.chatKey();
                },
                else => b = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1",
            }
            if (base.len == 0) {
                const bn = @min(b.len, basebuf.len);
                @memcpy(basebuf[0..bn], b[0..bn]);
                base = basebuf[0..bn];
            }
            if (key.len == 0) {
                const kn = @min(k.len, keybuf.len);
                @memcpy(keybuf[0..kn], k[0..kn]);
                key = keybuf[0..kn];
            }
            if (model.len == 0) {
                var m: []const u8 = s.chatModel();
                if (m.len == 0) m = if (s.chat_kind == 1) catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)].models[0].id else catalog.defaults.local_model;
                const mn = @min(m.len, modelbuf.len);
                @memcpy(modelbuf[0..mn], m[0..mn]);
                model = modelbuf[0..mn];
            }
        }
    }
    if (ui.sc_kind == 0 and now == 0) {
        store.pushNotif("Not ready", "still reading the clock - try again in a second", 2);
        return;
    }

    const kind: []const u8 = switch (ui.sc_kind) {
        1 => "every",
        2 => "daily",
        else => "once",
    };
    const at: i64 = if (ui.sc_kind == 0) now + @as(i64, ui.sc_once_min) * 60 else 0;

    var b: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    w.writeAll("{\"name\":\"") catch return;
    jesc(&w, ui.sc_name.str());
    w.writeAll("\",\"prompt\":\"") catch return;
    jesc(&w, ui.sc_prompt.str());
    w.writeAll("\",\"details\":\"") catch return;
    jesc(&w, ui.sc_details.str());
    w.print("\",\"kind\":\"{s}\",\"at\":{d},\"every_min\":{d},\"hm\":\"{d:0>2}:{d:0>2}\",\"enabled\":{s},\"base_url\":\"", .{
        kind, at, ui.sc_every_min, ui.sc_hour, ui.sc_minute, boolStr(ui.sc_enabled),
    }) catch return;
    jesc(&w, base);
    w.writeAll("\",\"model\":\"") catch return;
    jesc(&w, model);
    // EDIT + blank key → OMIT the field entirely: the update route treats "absent" as keep, but an empty
    // STRING as "clear the stored key" — sending "" here would silently strip the task's credentials.
    if (!editing or key.len > 0) {
        w.writeAll("\",\"api_key\":\"") catch return;
        jesc(&w, key);
    }
    w.writeAll("\"}") catch return;
    const body = w.buffered();

    // park the payload + fire the command (the poller consumes and clears the slot)
    {
        store.lock();
        defer store.unlock();
        const bn = @min(body.len, store.sched_create_json.len);
        @memcpy(store.sched_create_json[0..bn], body[0..bn]);
        store.sched_create_len = bn;
    }
    if (editing) {
        store.pushCmd(store_mod.mkCmd(.sched_update, ui.sc_edit_id[0..ui.sc_edit_id_len], ""));
        store.pushNotif("Saving task...", ui.sc_name.str(), 0);
    } else {
        store.pushCmd(store_mod.mkCmd(.sched_create, "", ""));
        store.pushNotif("Scheduling...", ui.sc_name.str(), 0);
    }
    schedResetForm();
    ui.sched_inner = .tasks;
}

fn drawSettings(store: *Store, body: t.Rect) void {
    // While a dropdown is open, block the form's buttons/toggles from eating a click meant for the dropdown
    // list drawn over them (flushChatDropdown clears this before drawing the list, so the options still work).
    t.setBlockClicks(ui.open_dd != .none);
    defer t.setBlockClicks(false); // never let it leak to the titlebar/tabbar of the next frame
    // SCROLL: the page outgrows the window (text size XL especially — the report was "we cannot scroll
    // settings"). Wheel scrolls; the clamp comes from the content height measured LAST frame (immediate
    // mode: this frame's total isn't known until it draws). An open dropdown keeps the wheel to itself.
    {
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0 and t.hovering(body) and ui.open_dd == .none) {
            ui.settings_scroll -= wheel * 40;
            ui.input_active = true;
        }
        ui.settings_scroll = std.math.clamp(ui.settings_scroll, 0, @max(0, ui.settings_h - body.height + 24));
    }
    rl.beginScissorMode(@intFromFloat(body.x), @intFromFloat(body.y), @intFromFloat(body.width), @intFromFloat(body.height));
    const pad: f32 = t.PAD;
    var y: f32 = body.y + pad - ui.settings_scroll;
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
    var hostb: [64]u8 = undefined;
    const hostn: usize = store.settings.host_len;
    @memcpy(hostb[0..hostn], store.settings.host[0..hostn]);
    const settings_loaded = store.settings_loaded;
    const tok_n = store.settings.token_len;
    const notify_on = store.settings.notify;
    const speed_on = store.settings.speed_mode;
    const dys_on = store.settings.dyslexia;
    const scale_now = store.settings.font_scale;
    const bold_now = store.settings.font_bold;
    const online = store.server_online;
    const chat_kind = store.settings.chat_kind;
    const chat_byok = store.settings.chat_byok;
    const chat_key_n = store.settings.chat_key_len;
    const ol_n = store.ollama_model_count;
    var cmb: [96]u8 = undefined;
    const cmn: usize = store.settings.chat_model_len;
    @memcpy(cmb[0..cmn], store.settings.chat_model[0..cmn]);
    var cbb: [192]u8 = undefined;
    const cbn: usize = store.settings.chat_base_len;
    @memcpy(cbb[0..cbn], store.settings.chat_base[0..cbn]);
    var cfab: [64]u8 = undefined;
    const cfan: usize = store.settings.cf_account_len;
    @memcpy(cfab[0..cfan], store.settings.cf_account[0..cfan]);
    store.unlock();

    flabel(x, y, "DATA DIRECTORY (read live)");
    y += 20;
    const dr = t.Rect{ .x = x, .y = y, .width = colw, .height = 32 };
    t.panelBordered(dr, t.bg, t.border);
    t.textClip(ddb[0..ddn], @intFromFloat(x + 10), @intFromFloat(y + 9), 13, t.fg, @intFromFloat(colw - 20));
    y += 48;
    flabel(x, y, "SERVER HOST : PORT - the veil this desk drives (empty host = this machine)");
    y += 20;
    // Seed the editable fields from persisted values exactly once, after loadSettings finished — seeding
    // earlier would capture the pre-load defaults and show a stale target until the tab is reopened.
    if (!ui.srv_seeded and settings_loaded) {
        setField(&ui.s_host, hostb[0..hostn]);
        var spb: [8]u8 = undefined;
        setField(&ui.s_port, std.fmt.bufPrint(&spb, "{d}", .{portv}) catch "8787");
        ui.srv_seeded = true;
    }
    const ap_label = t.z("Apply", .{});
    const apw = t.btnW(ap_label, t.BTN_MD);
    const port_w: f32 = 76;
    const host_w = colw - port_w - apw - t.GAP * 2;
    textField(.{ .x = x, .y = y, .width = host_w, .height = t.FIELD_H }, &ui.s_host, ui.focus == .s_host, "127.0.0.1 (default - this machine)", .s_host);
    textField(.{ .x = x + host_w + t.GAP, .y = y, .width = port_w, .height = t.FIELD_H }, &ui.s_port, ui.focus == .s_port, "8787", .s_port);
    const apb = t.Rect{ .x = x + colw - apw, .y = y, .width = apw, .height = t.BTN_MD };
    if (t.button(apb, ap_label, t.blue, true)) {
        const hs = std.mem.trim(u8, ui.s_host.str(), " \t");
        const p = std.fmt.parseInt(u16, std.mem.trim(u8, ui.s_port.str(), " \t"), 10) catch 0;
        store.lock();
        const s = &store.settings;
        const hn2 = @min(hs.len, s.host.len);
        @memcpy(s.host[0..hn2], hs[0..hn2]);
        s.host_len = @intCast(hn2);
        if (p >= 1) s.port = p; // 0/garbage = keep the current port rather than saving a dead target
        store.unlock();
        store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
        store.pushNotif("Server target saved", if (hn2 == 0) "this machine (localhost)" else "remote veil - paste its nlk_ token below", 1);
        ui.focus = .none;
    }
    y += 42;
    t.text(t.z("{s}:{d}   ({s})", .{ if (hostn == 0) "127.0.0.1" else hostb[0..hostn], portv, if (online) "reachable" else "not reachable" }), @intFromFloat(x), @intFromFloat(y), 12, if (online) t.green else t.comment);
    y += 34;
    flabel(x, y, "API TOKEN - an nlk_ key from the web UI (enables Deploy over the API)");
    y += 20;
    const sv_label = t.z("Save token", .{});
    const svw = t.btnW(sv_label, t.BTN_MD);
    const tf = t.Rect{ .x = x, .y = y, .width = colw - svw - t.GAP, .height = t.FIELD_H };
    textField(tf, &ui.d_key, ui.focus == .d_key, "nlk_... (also used by the Swarm tab's Deploy form)", .d_key);
    const savb = t.Rect{ .x = x + colw - svw, .y = y, .width = svw, .height = t.BTN_MD };
    if (t.button(savb, sv_label, t.blue, ui.d_key.len > 0)) {
        store.lock();
        const n = @min(ui.d_key.len, store.settings.token.len);
        @memcpy(store.settings.token[0..n], ui.d_key.buf[0..n]);
        store.settings.token_len = @intCast(n);
        store.settings.token_manual = true; // stop the poller auto-syncing over the user's own key
        store.unlock();
        store.pushNotif("Token saved", "Deploy is authorized", 1);
        ui.focus = .none;
    }
    y += 42; // clear the 34px field + gap
    if (tok_n > 0) t.text(t.z("connected - a token is set ({d} chars, auto-loaded from the server)", .{tok_n}), @intFromFloat(x), @intFromFloat(y), 12, t.green);
    y += 34;
    // fixed slot wide enough for both labels so the button doesn't resize when toggled
    const ntf_w = @max(t.btnW(t.z("notifications: ON", .{}), 32), t.btnW(t.z("notifications: OFF", .{}), 32));
    const tr = t.Rect{ .x = x, .y = y, .width = ntf_w, .height = 32 };
    if (t.button(tr, if (notify_on) t.z("notifications: ON", .{}) else t.z("notifications: OFF", .{}), if (notify_on) t.green else t.comment, true)) {
        store.lock();
        store.settings.notify = !store.settings.notify;
        store.unlock();
    }
    y += 46;
    // SPEED MODE: the chat builds projects itself; casts become 2-minute research sub-agents. OFF restores
    // the autonomy posture (the chat may deploy long set-and-forget hiveminds). Persisted with the settings.
    const spd_w = @max(t.btnW(t.z("speed mode: ON", .{}), 32), t.btnW(t.z("speed mode: OFF", .{}), 32));
    const spr = t.Rect{ .x = x, .y = y, .width = spd_w, .height = 32 };
    if (t.button(spr, if (speed_on) t.z("speed mode: ON", .{}) else t.z("speed mode: OFF", .{}), if (speed_on) t.green else t.comment, true)) {
        store.lock();
        store.settings.speed_mode = !store.settings.speed_mode;
        store.unlock();
        store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
    }
    t.text(t.z("ON: the chat builds hands-on; swarms are 2-min research strikes.  OFF: long autonomous hiveminds.", .{}), @intFromFloat(x + spd_w + 14), @intFromFloat(y + 9), 12, t.comment);
    y += 46;

    // ACCESSIBILITY — dyslexia mode: swaps the UI type for OpenDyslexic (bundled, SIL OFL), whose
    // heavy-bottomed letterforms many dyslexic readers find easier to track. Applies INSTANTLY (the
    // render loop hot-swaps the font atlas on the next frame) and persists with the settings.
    const dys_w = @max(t.btnW(t.z("dyslexia mode: ON", .{}), 32), t.btnW(t.z("dyslexia mode: OFF", .{}), 32));
    const dyr = t.Rect{ .x = x, .y = y, .width = dys_w, .height = 32 };
    if (t.button(dyr, if (dys_on) t.z("dyslexia mode: ON", .{}) else t.z("dyslexia mode: OFF", .{}), if (dys_on) t.green else t.comment, true)) {
        store.lock();
        store.settings.dyslexia = !store.settings.dyslexia;
        store.unlock();
        store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
    }
    t.text(t.z("accessibility: renders the app in OpenDyslexic, a typeface designed for dyslexic readers.", .{}), @intFromFloat(x + dys_w + 14), @intFromFloat(y + 9), 12, t.comment);
    y += 46;

    // TEXT SIZE — a global text scale (90/100/112/125%), applied at draw time everywhere; the chat's
    // line heights follow it. Cycles on click, persists with the settings, applies the same frame.
    const size_name: [:0]const u8 = switch (scale_now) {
        90 => t.z("text size: Small", .{}),
        112 => t.z("text size: Large", .{}),
        125 => t.z("text size: XL", .{}),
        else => t.z("text size: Normal", .{}),
    };
    const size_w = @max(t.btnW(t.z("text size: Normal", .{}), 32), t.btnW(size_name, 32));
    const szr = t.Rect{ .x = x, .y = y, .width = size_w, .height = 32 };
    if (t.button(szr, size_name, if (scale_now != 100) t.green else t.comment, true)) {
        const next: u8 = switch (scale_now) {
            90 => 100,
            100 => 112,
            112 => 125,
            else => 90,
        };
        store.lock();
        store.settings.font_scale = next;
        store.unlock();
        store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
    }
    t.text(t.z("scales every label and message - click to cycle Small / Normal / Large / XL.", .{}), @intFromFloat(x + size_w + 14), @intFromFloat(y + 9), 12, t.comment);
    y += 46;

    // TEXT WEIGHT — swaps to the face's Bold file (bundled OpenDyslexic Bold in dyslexia mode; the
    // system face's bold otherwise). Thicker strokes read easier on some displays and for some eyes.
    const wt_w = @max(t.btnW(t.z("text weight: Normal", .{}), 32), t.btnW(t.z("text weight: Bold", .{}), 32));
    const wtr = t.Rect{ .x = x, .y = y, .width = wt_w, .height = 32 };
    if (t.button(wtr, if (bold_now) t.z("text weight: Bold", .{}) else t.z("text weight: Normal", .{}), if (bold_now) t.green else t.comment, true)) {
        store.lock();
        store.settings.font_bold = !store.settings.font_bold;
        store.unlock();
        store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
    }
    t.text(t.z("renders the whole app in the typeface's bold cut.", .{}), @intFromFloat(x + wt_w + 14), @intFromFloat(y + 9), 12, t.comment);
    y += 46;

    // NARRATOR — the app speaks: replies + alerts read aloud through the OS's own text-to-speech (no
    // audio code bundled). Voice INPUT rides the OS dictation layer (Win+H) into the normal input box.
    const narr_on = store.settings.narrator;
    const nr_w = @max(t.btnW(t.z("narrator: ON", .{}), 32), t.btnW(t.z("narrator: OFF", .{}), 32));
    const nrr = t.Rect{ .x = x, .y = y, .width = nr_w, .height = 32 };
    if (t.button(nrr, if (narr_on) t.z("narrator: ON", .{}) else t.z("narrator: OFF", .{}), if (narr_on) t.green else t.comment, true)) {
        store.lock();
        store.settings.narrator = !store.settings.narrator;
        const now_on = store.settings.narrator;
        store.unlock();
        store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
        if (now_on) {
            store.pushNotif("Narrator on", "replies and alerts will be read aloud. press Windows plus H to dictate into the message box", 1);
        }
    }
    t.text(t.z("accessibility: reads replies and alerts aloud (OS voice). dictate input with Win+H.", .{}), @intFromFloat(x + nr_w + 14), @intFromFloat(y + 9), 12, t.comment);
    y += 46;

    // BROWSER WINDOW — when the AI drives a web browser ON THIS MACHINE, show the window (headful) instead of
    // running it hidden (headless). Persisted, and mirrored to the local browser daemon's prefs file so the
    // next browser session opens in the chosen mode without a restart.
    const bh_on = store.settings.browser_headful;
    const bw_w = @max(t.btnW(t.z("browser window: SHOWN", .{}), 32), t.btnW(t.z("browser window: HIDDEN", .{}), 32));
    const bwr = t.Rect{ .x = x, .y = y, .width = bw_w, .height = 32 };
    if (t.button(bwr, if (bh_on) t.z("browser window: SHOWN", .{}) else t.z("browser window: HIDDEN", .{}), if (bh_on) t.green else t.comment, true)) {
        store.lock();
        store.settings.browser_headful = !store.settings.browser_headful;
        store.unlock();
        store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
    }
    t.text(t.z("when the AI drives a web browser on this machine, show it on screen instead of running it hidden.", .{}), @intFromFloat(x + bw_w + 14), @intFromFloat(y + 9), 12, t.comment);
    y += 46;

    // ---- chat model provider (the Chat tab's brain; casts use the same provider) ----
    // Seed the custom-URL editable fields from the store once (used only for chat_kind==2).
    if (!ui.s_seeded and (cmn > 0 or cbn > 0 or cfan > 0)) {
        setField(&ui.s_model, cmb[0..cmn]);
        setField(&ui.s_url, cbb[0..cbn]);
        setField(&ui.s_cfacct, cfab[0..cfan]);
        ui.s_seeded = true;
    }
    t.hline(@intFromFloat(x), @intFromFloat(y), @intFromFloat(colw), t.border);
    y += 12;
    t.text(t.z("CHAT MODEL", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
    t.text(t.z("the Chat tab talks through this provider - its swarm casts use it too", .{}), @intFromFloat(x + 100), @intFromFloat(y), 11, t.comment);
    y += 22;

    // CHAT ENGINE: the server brain (default + recommended) vs the retired local fallback. IMPORTANT COPY
    // LESSON: in client mode the SERVER brain STILL runs every tool on THIS machine (delegation) — the old
    // label sold "tools in your environment" as the LOCAL option's advantage, which misled the user into
    // opting out of the server path right after it became the primary one.
    {
        const cur = blk_ce: {
            store.lock();
            defer store.unlock();
            break :blk_ce store.settings.server_chat;
        };
        // Full-row hit area: the label sits well past the 18px box, so a 22px-wide rect made only the tiny box
        // clickable — clicking the label did nothing, which read as a "stuck" / policy-blocked switch.
        // CONTRACT: t.checkbox returns TRUE ON CLICK (the caller flips), NOT the new value. The previous
        // shape here (`nv = t.checkbox(...); if (nv != cur)`) treated the click flag as the value — so every
        // UN-clicked frame with the box CHECKED saw nv(false) != cur(true) and FORCED server_chat off:
        // opening Settings silently killed server mode, and turning it on lasted exactly one frame. That
        // was the whole "cannot click the input on or off / stuck in client mode" bug.
        if (t.checkbox(.{ .x = x, .y = y, .width = colw, .height = 22 }, t.z("server chat brain (recommended) - tools still run on THIS machine; off = old local engine (fallback only)", .{}), cur)) {
            const nv = !cur;
            store.lock();
            store.settings.server_chat = nv;
            store.unlock();
            store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
            store.pushNotif(if (nv) "Chat: server brain" else "Chat: local fallback engine", if (nv) "the brain runs in the backend; every tool still executes on this machine" else "the RETIRED local engine - use only if the server is unreachable", if (nv) 1 else 0);
        }
        y += 30;
    }
    const half = (colw - 10) / 2;

    // PROVIDER dropdown: Local / BYOK / Custom URL
    const kind_lbl = switch (chat_kind) {
        1 => t.z("BYOK (cloud key)", .{}),
        2 => t.z("Custom URL", .{}),
        else => t.z("Local (Ollama)", .{}),
    };
    selector(.{ .x = x, .y = y, .width = half, .height = 48 }, t.z("PROVIDER", .{}), kind_lbl, .chat_provider);
    // BYOK cloud-provider dropdown
    if (chat_kind == 1) {
        const p = &catalog.providers[@min(chat_byok, catalog.providers.len - 1)];
        selector(.{ .x = x + half + 10, .y = y, .width = half, .height = 48 }, t.z("CLOUD PROVIDER", .{}), t.zs(p.label), .chat_byok);
    }
    y += 58;

    // MODEL: a populated dropdown for local/BYOK; a text field for a custom endpoint (models unknown).
    if (chat_kind == 2) {
        flabel(x, y, "MODEL");
        textField(.{ .x = x, .y = y + 14, .width = half, .height = t.FIELD_H }, &ui.s_model, ui.focus == .s_model, "model id", .s_model);
        flabel(x + half + 10, y, "ENDPOINT URL (OpenAI-compatible /v1)");
        textField(.{ .x = x + half + 10, .y = y + 14, .width = half, .height = t.FIELD_H }, &ui.s_url, ui.focus == .s_url, "https://host/v1", .s_url);
        y += 58;
        const sem_label = t.z("Save endpoint + model", .{});
        if (t.buttonSolid(.{ .x = x, .y = y, .width = t.btnW(sem_label, t.BTN_MD), .height = t.BTN_MD }, sem_label, t.blue, true)) {
            store.lock();
            const s = &store.settings;
            const mn = @min(ui.s_model.len, s.chat_model.len);
            @memcpy(s.chat_model[0..mn], ui.s_model.buf[0..mn]);
            s.chat_model_len = @intCast(mn);
            const bn2 = @min(ui.s_url.len, s.chat_base.len);
            @memcpy(s.chat_base[0..bn2], ui.s_url.buf[0..bn2]);
            s.chat_base_len = @intCast(bn2);
            store.unlock();
            store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
            store.pushNotif("Chat endpoint saved", "custom model config persisted", 1);
            ui.focus = .none;
        }
        y += 42;
    } else if (chat_kind == 0) {
        // Local (Ollama) defaults to 127.0.0.1:11434, but the box may run Ollama on a different port, or
        // the model may live on another machine on the LAN — let the user override the endpoint.
        const model_disp: []const u8 = if (cmn > 0) cmb[0..cmn] else "(pick a model)";
        selector(.{ .x = x, .y = y, .width = half, .height = 48 }, t.z("MODEL", .{}), model_disp, .chat_model);
        flabel(x + half + 10, y, "ENDPOINT (optional - defaults to 127.0.0.1:11434)");
        const sv2_label = t.z("Save", .{});
        const sv2w = t.btnW(sv2_label, t.FIELD_H);
        const ew = half - sv2w - 8;
        textField(.{ .x = x + half + 10, .y = y + 14, .width = ew, .height = t.FIELD_H }, &ui.s_url, ui.focus == .s_url, "http://127.0.0.1:11434/v1", .s_url);
        if (t.button(.{ .x = x + half + 10 + ew + 8, .y = y + 14, .width = sv2w, .height = t.FIELD_H }, sv2_label, t.blue, true)) {
            store.lock();
            const s = &store.settings;
            const bn2 = @min(ui.s_url.len, s.chat_base.len);
            @memcpy(s.chat_base[0..bn2], ui.s_url.buf[0..bn2]);
            s.chat_base_len = @intCast(bn2);
            store.unlock();
            store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
            store.pushNotif("Endpoint saved", if (bn2 > 0) "custom Ollama endpoint set" else "reset to default 127.0.0.1:11434", 1);
            ui.focus = .none;
        }
        y += 58;
        const hint = if (ol_n > 0) t.z("{d} models installed on this machine", .{ol_n}) else t.z("Ollama not reachable - showing common models", .{});
        t.text(hint, @intFromFloat(x), @intFromFloat(y), 11, t.comment);
        y += 20;
    } else {
        const model_disp: []const u8 = if (cmn > 0) cmb[0..cmn] else "(pick a model)";
        selector(.{ .x = x, .y = y, .width = half, .height = 48 }, t.z("MODEL", .{}), model_disp, .chat_model);
        const hint = t.z("models available on {s}", .{catalog.providers[@min(chat_byok, catalog.providers.len - 1)].label});
        t.text(hint, @intFromFloat(x + half + 10), @intFromFloat(y + 18), 11, t.comment);
        y += 58;
    }

    // LOG IN WITH CLOUDFLARE (OAuth) — the primary path when the provider needs a Cloudflare account. Grants
    // Workers AI access once via the browser; the token lives server-side and auto-refreshes. The manual
    // account-id + token fields below remain as a fallback.
    if (chat_kind == 1 and catalog.providers[@min(chat_byok, catalog.providers.len - 1)].needs_account) {
        var cf_configured = false;
        var cf_connected = false;
        var cf_pending = false;
        var cf_seen = false;
        var acctbuf: [64]u8 = undefined;
        var acct_len: usize = 0;
        {
            store.lock();
            cf_configured = store.cf_oauth_configured;
            cf_connected = store.cf_oauth_connected;
            cf_pending = store.cf_oauth_pending;
            cf_seen = store.cf_oauth_seen;
            acct_len = @min(store.cf_oauth_account_len, acctbuf.len);
            @memcpy(acctbuf[0..acct_len], store.cf_oauth_account[0..acct_len]);
            store.unlock();
        }
        flabel(x, y, "CLOUDFLARE LOGIN");
        y += 14;
        if (cf_connected) {
            t.text(t.z("connected", .{}), @intFromFloat(x), @intFromFloat(y + 8), 14, t.green);
            if (acct_len > 0) t.text(t.z("account {s}", .{acctbuf[0..acct_len]}), @intFromFloat(x + 90), @intFromFloat(y + 10), 12, t.comment);
            const dl = t.z("Disconnect", .{});
            const dw = t.btnW(dl, t.BTN_MD);
            if (t.button(.{ .x = x + colw - dw, .y = y, .width = dw, .height = t.BTN_MD }, dl, t.red, true)) {
                store.pushCmd(store_mod.mkCmd(.oauth_cf_logout, "", ""));
            }
            y += 44;
        } else if (cf_configured) {
            const ll = t.z("Log in with Cloudflare", .{});
            const lw = t.btnW(ll, t.BTN_MD) + 20;
            if (t.button(.{ .x = x, .y = y, .width = lw, .height = t.BTN_MD }, ll, t.blue, !cf_pending)) {
                store.pushCmd(store_mod.mkCmd(.oauth_cf_login, "", ""));
            }
            const sub: [:0]const u8 = if (cf_pending) t.z("waiting for the grant in your browser...", .{}) else t.z("opens Cloudflare in your browser - one click, no token to paste", .{});
            t.text(sub, @intFromFloat(x + lw + 12), @intFromFloat(y + 10), 12, if (cf_pending) t.orange else t.comment);
            y += 44;
        } else if (cf_seen) {
            t.text(t.z("Cloudflare login isn't set up on this server - paste a token below instead.", .{}), @intFromFloat(x), @intFromFloat(y + 6), 12, t.comment);
            y += 30;
        }
    }

    // Cloudflare account id (only when the BYOK provider needs one) — built into the Workers AI base_url.
    if (chat_kind == 1 and catalog.providers[@min(chat_byok, catalog.providers.len - 1)].needs_account) {
        flabel(x, y, "CLOUDFLARE ACCOUNT ID (paste manually - or use the login above)");
        y += 14;
        const sid_label = t.z("Save id", .{});
        const sidw = t.btnW(sid_label, t.BTN_MD);
        textField(.{ .x = x, .y = y, .width = colw - 240, .height = t.FIELD_H }, &ui.s_cfacct, ui.focus == .s_cfacct, "e.g. 0123456789abcdef0123456789abcdef", .s_cfacct);
        if (t.button(.{ .x = x + colw - 240 + t.GAP, .y = y, .width = sidw, .height = t.BTN_MD }, sid_label, t.blue, true)) {
            store.lock();
            const s = &store.settings;
            const n = @min(ui.s_cfacct.len, s.cf_account.len);
            @memcpy(s.cf_account[0..n], ui.s_cfacct.buf[0..n]);
            s.cf_account_len = @intCast(n);
            store.unlock();
            store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", ""));
            store.pushNotif("Account id saved", "used to build the Workers AI endpoint", 1);
            ui.focus = .none;
        }
        y += 44;
    }

    // API key (BYOK only — local needs none, custom uses this too)
    if (chat_kind != 0) {
        const key_hint: [:0]const u8 = if (chat_kind == 1 and std.mem.eql(u8, catalog.providers[@min(chat_byok, catalog.providers.len - 1)].key, "huggingface")) t.z("hf_... (a Hugging Face fine-grained token with Inference Providers access)", .{}) else if (chat_kind == 1 and catalog.providers[@min(chat_byok, catalog.providers.len - 1)].needs_account) t.z("your Cloudflare API token (Workers AI)", .{}) else t.z("API KEY (stored in the OS-protected local store, never plaintext)", .{});
        flabel(x, y, key_hint);
        y += 14;
        const sk_label = t.z("Save key", .{});
        const skw = t.btnW(sk_label, t.BTN_MD);
        textField(.{ .x = x, .y = y, .width = colw - 240, .height = t.FIELD_H }, &ui.s_ckey, ui.focus == .s_ckey, "sk-...", .s_ckey);
        if (t.button(.{ .x = x + colw - 240 + t.GAP, .y = y, .width = skw, .height = t.BTN_MD }, sk_label, t.blue, ui.s_ckey.len > 0)) {
            store.pushChatCmd(store_mod.mkChatCmd(.save_key, "", ui.s_ckey.str()));
            ui.s_ckey.clear();
            ui.focus = .none;
        }
        if (chat_key_n > 0) t.text(t.z("key set ({d} chars)", .{chat_key_n}), @intFromFloat(x + colw - 240 + t.GAP + skw + 12), @intFromFloat(y + 10), 12, t.green);
        y += 48;
    }
    y += 8;
    t.text(t.z("veil-desk v0.2.0 - same-machine companion - borderless chrome", .{}), @intFromFloat(x), @intFromFloat(y), 12, t.comment);
    // content height for next frame's scroll clamp (add back the offset this frame subtracted)
    ui.settings_h = (y + 24 + ui.settings_scroll) - body.y;
    rl.endScissorMode();

    // draw the open chat dropdown LAST so its option list sits on top of the fields below it (and outside
    // the page scissor — a list flipped upward may poke above the body rect). Unblock first so the option
    // rows themselves are clickable (they were covered by the block during the form above).
    t.setBlockClicks(false);
    flushChatDropdown(store);
}

/// The catalog provider indices usable as a BYOK cloud chat provider: needs a key AND a real https base
/// (skips ollama/local, cloudflare-resolved, and mock). Fills `out`, returns the count.
fn byokProviderList(out: *[16]usize) usize {
    var n: usize = 0;
    for (catalog.providers, 0..) |p, i| {
        if (n >= out.len) break;
        if (p.needs_key and std.mem.startsWith(u8, p.base_url, "http")) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

fn setChatModel(store: *Store, model: []const u8) void {
    store.lock();
    setChatModelLocked(store, model);
    store.unlock();
}

/// Caller MUST hold store.lock(). Copies `model` into settings.chat_model.
fn setChatModelLocked(store: *Store, model: []const u8) void {
    const n = @min(model.len, store.settings.chat_model.len);
    @memcpy(store.settings.chat_model[0..n], model[0..n]);
    store.settings.chat_model_len = @intCast(n);
}

/// Render + apply the open chat dropdown (PROVIDER / CLOUD PROVIDER / MODEL) on top of the Settings form.
/// Selections apply live AND persist, and switching provider re-selects a valid model — so the chat can
/// never be left pointing a cloud provider at a local model (the "BYOK breaks" trap).
fn flushChatDropdown(store: *Store) void {
    switch (ui.open_dd) {
        .chat_provider, .chat_byok, .chat_model => {},
        else => return,
    }
    // snapshot the state the list needs
    store.lock();
    const kind = store.settings.chat_kind;
    const byok = store.settings.chat_byok;
    var models: [store_mod.MAX_OLLAMA_MODELS]store_mod.OllamaModel = undefined;
    const ol_n = store.ollama_model_count;
    @memcpy(models[0..ol_n], store.ollama_models[0..ol_n]);
    var cur_model: [96]u8 = undefined;
    const cur_model_n = store.settings.chat_model_len;
    @memcpy(cur_model[0..cur_model_n], store.settings.chat_model[0..cur_model_n]);
    // live Cloudflare model list (stack-local copy, so its slices are valid through drawList below)
    var cf_models: [store_mod.MAX_CF_MODELS][96]u8 = undefined;
    var cf_lens: [store_mod.MAX_CF_MODELS]u8 = undefined;
    const cf_n = store.cf_model_count;
    @memcpy(cf_models[0..cf_n], store.cf_models[0..cf_n]);
    @memcpy(cf_lens[0..cf_n], store.cf_model_lens[0..cf_n]);
    store.unlock();

    var labels: [64][]const u8 = undefined;
    var count: usize = 0;
    var current: usize = 0;
    var byok_idx: [16]usize = undefined;
    var byok_n: usize = 0;

    switch (ui.open_dd) {
        .chat_provider => {
            labels[0] = "Local (Ollama)";
            labels[1] = "BYOK (cloud key)";
            labels[2] = "Custom URL";
            count = 3;
            current = @min(kind, 2);
        },
        .chat_byok => {
            byok_n = byokProviderList(&byok_idx);
            for (0..byok_n) |i| {
                labels[i] = catalog.providers[byok_idx[i]].label;
                if (byok_idx[i] == byok) current = i;
            }
            count = byok_n;
        },
        .chat_model => {
            if (kind == 0 and ol_n > 0) {
                for (0..ol_n) |i| {
                    labels[i] = models[i].nameStr();
                    if (std.mem.eql(u8, labels[i], cur_model[0..cur_model_n])) current = i;
                }
                count = ol_n;
            } else {
                const prov = if (kind == 1) &catalog.providers[@min(byok, catalog.providers.len - 1)] else &catalog.providers[2]; // 2 = ollama
                // Cloudflare: prefer the LIVE model list fetched from the account (the catalog changes fast).
                if (kind == 1 and prov.needs_account and cf_n > 0) {
                    for (0..cf_n) |i| {
                        if (i >= labels.len) break;
                        labels[i] = cf_models[i][0..cf_lens[i]];
                        if (std.mem.eql(u8, labels[i], cur_model[0..cur_model_n])) current = i;
                        count += 1;
                    }
                } else {
                    for (prov.models, 0..) |m, i| {
                        if (i >= labels.len) break;
                        labels[i] = m.id;
                        if (std.mem.eql(u8, m.id, cur_model[0..cur_model_n])) current = i;
                        count += 1;
                    }
                }
            }
        },
        else => return,
    }

    const chosen = drawList(ui.dd_rect, labels[0..count], current) orelse return;
    // Switching provider re-selects a valid default model so the chat can never point a cloud provider at
    // a local model (the "BYOK breaks" trap). All model strings below are either catalog-static or slices
    // into the STACK-local `models` snapshot — never a slice into the shared Store held past an unlock.
    // Provider+model must change ATOMICALLY (one lock): otherwise the chat thread could drain a queued
    // send/cast between the two writes and read the new provider with the old (mismatched) model — the
    // exact "cloud provider pointed at a local model" trap this feature exists to prevent.
    switch (ui.open_dd) {
        .chat_provider => {
            const newkind: u8 = @intCast(chosen);
            store.lock();
            store.settings.chat_kind = newkind;
            if (newkind == 0) {
                setChatModelLocked(store, if (ol_n > 0) models[0].nameStr() else catalog.defaults.local_model);
            } else if (newkind == 1) {
                const p = &catalog.providers[@min(byok, catalog.providers.len - 1)];
                if (p.needs_account and cf_n > 0) setChatModelLocked(store, cf_models[0][0..cf_lens[0]]) else if (p.models.len > 0) setChatModelLocked(store, p.models[0].id);
            } // custom (2) keeps its typed model
            store.unlock();
        },
        .chat_byok => {
            const newbyok: u8 = @intCast(byok_idx[chosen]);
            store.lock();
            store.settings.chat_byok = newbyok;
            const p = &catalog.providers[newbyok];
            if (p.needs_account and cf_n > 0) setChatModelLocked(store, cf_models[0][0..cf_lens[0]]) else if (p.models.len > 0) setChatModelLocked(store, p.models[0].id);
            store.unlock();
        },
        .chat_model => setChatModel(store, labels[chosen]),
        else => {},
    }
    store.pushChatCmd(store_mod.mkChatCmd(.save_settings, "", "")); // apply live + persist
    ui.open_dd = .none;
}

// -------------------------------------------------------------------------------- shared widgets

/// Greedy word-wrap `s` into `out` display lines at pixel width `maxw` (font size 13). Accumulates single-glyph
/// widths (O(n), no O(n^2) re-measure) and breaks at the last space that fits. Returns the line count.
fn wrapInto(s: []const u8, maxw: f32, out: [][]const u8) usize {
    var n: usize = 0;
    var ls: usize = 0; // current line start
    var i: usize = 0;
    // Measure whole candidate LINES (word by word), not single chars — t.measure includes inter-char spacing,
    // so summing single-char widths underestimates and lines overflow the box.
    while (i < s.len and n < out.len) {
        var we = i; // extend through the next word + its trailing spaces
        while (we < s.len and s[we] != ' ') we += 1;
        while (we < s.len and s[we] == ' ') we += 1;
        const w: f32 = @floatFromInt(t.measure(t.zs(s[ls..we]), 13));
        if (w <= maxw) {
            i = we;
            continue;
        }
        if (i > ls) { // the line has content before this word — break there, retry the word on the next line
            out[n] = s[ls..i];
            n += 1;
            ls = i;
            continue;
        }
        // a single word is wider than the whole line — hard-break it by character
        var j = ls + 1;
        while (j < we and @as(f32, @floatFromInt(t.measure(t.zs(s[ls .. j + 1]), 13))) <= maxw) j += 1;
        out[n] = s[ls..j];
        n += 1;
        ls = j;
        i = j;
    }
    if (ls < s.len and n < out.len) {
        out[n] = s[ls..];
        n += 1;
    }
    return n;
}

/// Pixel width of a raw field slice's first `nbytes`, measured the same way the field is DRAWN (t.zs folds
/// non-ASCII), so the caret/selection x lines up with the rendered glyphs.
fn fieldPrefixPx(line: []const u8, nbytes: usize) f32 {
    const n = @min(nbytes, line.len);
    if (n == 0) return 0;
    return @floatFromInt(t.measure(t.zs(line[0..n]), 13));
}

/// Byte column within `line` nearest to pixel offset `targetpx` (binary search over prefix widths, the
/// selColAt pattern), snapped back onto a UTF-8 codepoint boundary.
fn fieldColAt(line: []const u8, targetpx: f32) usize {
    if (targetpx <= 0) return 0;
    var lo: usize = 0;
    var hi: usize = line.len;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (fieldPrefixPx(line, mid) <= targetpx) lo = mid else hi = mid - 1;
    }
    while (lo > 0 and lo < line.len and (line[lo] & 0xC0) == 0x80) lo -= 1;
    return lo;
}

/// Is a mouse drag currently extending a selection inside the focused Field? (one field can drag at a time)
var field_drag: bool = false;

/// A multi-row text input. The Field holds ONE logical line (paste flattens newlines); this wraps it across
/// up to `rows` visible rows and keeps the CARET's row in view. Click to place the caret, drag to select,
/// arrows/Home/End move it (editField owns the keys; this owns the pixels).
fn textArea(r: t.Rect, f: *Ui.Field, focused: bool, placeholder: [:0]const u8, which: Ui.Focus, rows: usize) void {
    t.panelBordered(r, t.bg, if (focused) t.blue else t.border);
    if (t.hovering(r) and ui.open_dd == .none) t.wantCursor(.ibeam);
    f.clampCur();
    const inner_x: i32 = @intFromFloat(r.x + 10);
    const line_h: f32 = 18;
    if (f.len == 0 and !focused) {
        if (t.hovering(r) and rl.isMouseButtonPressed(.left) and ui.open_dd == .none) ui.focus = which;
        t.text(placeholder, inner_x, @intFromFloat(r.y + 8), 13, t.comment);
        return;
    }
    var lines: [96][]const u8 = undefined;
    const nl = wrapInto(f.str(), r.width - 20, &lines);
    // the wrapped line the caret sits on (lines are slices into f.buf, so offsets are pointer math)
    var caret_line: usize = 0;
    {
        var li: usize = 0;
        while (li < nl) : (li += 1) {
            if (f.cur >= lineOff(f, lines[li])) caret_line = li else break;
        }
    }
    const first = if (caret_line >= rows) caret_line + 1 - rows else 0; // keep the caret's row in view
    // click to place the caret (and start a drag-selection); drag extends it
    if (t.hovering(r) and rl.isMouseButtonPressed(.left) and ui.open_dd == .none) {
        ui.focus = which;
        const mp = rl.getMousePosition();
        f.cur = hitField(f, lines[0..nl], first, mp, r.y + 8, line_h, @floatFromInt(inner_x));
        f.sel = f.cur;
        field_drag = true;
    }
    if (focused and field_drag) {
        if (rl.isMouseButtonDown(.left)) {
            const mp = rl.getMousePosition();
            f.cur = hitField(f, lines[0..nl], first, mp, r.y + 8, line_h, @floatFromInt(inner_x));
            ui.input_active = true;
        } else {
            if (f.selRange() == null) f.sel = null;
            field_drag = false;
        }
    }
    var yy: f32 = r.y + 8;
    var li = first;
    while (li < nl and li < first + rows) : (li += 1) {
        // selection highlight behind the text
        if (focused) if (f.selRange()) |rg| {
            const off = lineOff(f, lines[li]);
            const lo = @max(rg[0], off);
            const hi = @min(rg[1], off + lines[li].len);
            if (lo < hi) {
                const x0 = fieldPrefixPx(lines[li], lo - off);
                const x1 = fieldPrefixPx(lines[li], hi - off);
                t.fillRect(inner_x + @as(i32, @intFromFloat(x0)), @intFromFloat(yy - 1), @intFromFloat(@max(2, x1 - x0)), 17, t.bg_sel);
            }
        };
        t.text(t.zs(lines[li]), inner_x, @intFromFloat(yy), 13, t.fg);
        yy += line_h;
    }
    if (focused and @mod(rl.getTime(), 1.0) < 0.5 and caret_line >= first) {
        const cl: []const u8 = if (nl > 0) lines[caret_line] else "";
        const cw = fieldPrefixPx(cl, f.cur -| lineOff(f, cl));
        const shown: f32 = @floatFromInt(caret_line - first);
        t.fillRect(inner_x + @as(i32, @intFromFloat(cw)) + 1, @intFromFloat(r.y + 8 + shown * line_h), 2, 15, t.blue);
    }
}

/// Byte offset of a wrapped-line slice within its Field's buffer.
fn lineOff(f: *const Ui.Field, line: []const u8) usize {
    if (line.len == 0) return f.len;
    return @intFromPtr(line.ptr) - @intFromPtr(&f.buf);
}

/// Map a mouse position to a byte index in the field: row from y (clamped), column via prefix-measure.
fn hitField(f: *const Ui.Field, lines: [][]const u8, first: usize, mp: rl.Vector2, top_y: f32, line_h: f32, text_x: f32) usize {
    if (lines.len == 0) return 0;
    var row: usize = first;
    if (mp.y > top_y) {
        row = first + @as(usize, @intFromFloat((mp.y - top_y) / line_h));
    }
    if (row >= lines.len) row = lines.len - 1;
    const col = fieldColAt(lines[row], mp.x - text_x);
    return @min(lineOff(f, lines[row]) + col, f.len);
}

fn textField(r: t.Rect, f: *Ui.Field, focused: bool, placeholder: [:0]const u8, which: Ui.Focus) void {
    t.panelBordered(r, t.bg, if (focused) t.blue else t.border);
    if (t.hovering(r) and ui.open_dd == .none) t.wantCursor(.ibeam);
    f.clampCur();
    const inner_x: i32 = @intFromFloat(r.x + 10);
    const inner_y: i32 = @intFromFloat(r.y + (r.height - 13) / 2);
    // Don't grab focus while a dropdown is open: its option list is drawn OVER the fields below it, so a click
    // meant for a dropdown item would otherwise fall through and focus the input underneath. The open dropdown
    // owns the click; drawList closes it on an outside-click.
    if (t.hovering(r) and rl.isMouseButtonPressed(.left) and ui.open_dd == .none) {
        ui.focus = which;
        // place the caret at the clicked character (and anchor a drag-selection there)
        f.cur = fieldColAt(f.str(), rl.getMousePosition().x - @as(f32, @floatFromInt(inner_x)));
        f.sel = f.cur;
        field_drag = true;
    }
    if (focused and field_drag) {
        if (rl.isMouseButtonDown(.left)) {
            f.cur = fieldColAt(f.str(), rl.getMousePosition().x - @as(f32, @floatFromInt(inner_x)));
            ui.input_active = true;
        } else {
            if (f.selRange() == null) f.sel = null;
            field_drag = false;
        }
    }
    if (f.len == 0 and !focused) {
        t.text(placeholder, inner_x, inner_y, 13, t.comment);
    } else {
        if (focused) if (f.selRange()) |rg| {
            const x0 = fieldPrefixPx(f.str(), rg[0]);
            const x1 = fieldPrefixPx(f.str(), rg[1]);
            t.fillRect(inner_x + @as(i32, @intFromFloat(x0)), inner_y - 1, @intFromFloat(@max(2, x1 - x0)), 17, t.bg_sel);
        };
        t.textClip(f.str(), inner_x, inner_y, 13, t.fg, @intFromFloat(r.width - 20));
        if (focused) {
            const cw = fieldPrefixPx(f.str(), f.cur);
            if (@mod(rl.getTime(), 1.0) < 0.5) t.fillRect(inner_x + @as(i32, @intFromFloat(cw)) + 1, inner_y, 2, 15, t.blue);
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
        t.panelBordered(r, t.bg_hl, t.withAlpha(accent, 170));
        t.fillRect(@intFromFloat(r.x), @intFromFloat(r.y + 8), 3, @intFromFloat(h - 16), accent);
        t.textClip(tn.titleStr(), @intFromFloat(r.x + 16), @intFromFloat(r.y + 10), 13, t.fg, @intFromFloat(w - 28));
        t.textClip(tn.bodyStr(), @intFromFloat(r.x + 16), @intFromFloat(r.y + 31), 11, t.fg_dim, @intFromFloat(w - 28));
    }
}
