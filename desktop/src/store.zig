//! store.zig — the single source of truth shared between the UI thread (raylib, draw + input) and the
//! poller thread (io, filesystem + net). Every field behind one std.Thread.Mutex; the UI copies what it
//! needs under lock and never blocks on io, the poller writes under lock and never touches raylib. This
//! hard split is what keeps raylib single-threaded (its hard requirement) while the machine's state is
//! read off-thread.

const std = @import("std");
const scan = @import("scan.zig");
const log = @import("log.zig");

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

pub const Tab = enum { dashboard, chat, deploy, swarm, hub, settings };

pub const CmdKind = enum { none, select, say, set_goal, stop, deploy, delete, open_folder, refresh_now, open_file };

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
    token_manual: bool = false, // user pasted+saved a token → don't auto-sync over it
    notify: bool = true,
    theme: u8 = 1, // 0 dark / 1 light

    // --- chat model provider (Settings tab writes, chat thread reads; persisted to .veil-desk) ---
    chat_kind: u8 = 0, // 0 local (Ollama) / 1 BYOK (catalog provider) / 2 custom URL
    chat_byok: u8 = 0, // catalog.providers index when chat_kind==1
    chat_base: [192]u8 = [_]u8{0} ** 192, // custom endpoint (OpenAI-compatible /v1 root)
    chat_base_len: u8 = 0,
    chat_model: [96]u8 = [_]u8{0} ** 96,
    chat_model_len: u8 = 0,
    chat_key: [192]u8 = [_]u8{0} ** 192, // in-memory only; persisted via secrets.zig, never plaintext
    chat_key_len: u8 = 0,
    cf_account: [64]u8 = [_]u8{0} ** 64, // Cloudflare account id — built into the Workers AI base_url (not a secret)
    cf_account_len: u8 = 0,
    // chat pane collapse state (persisted with the chat settings)
    chat_left_open: bool = true,
    chat_right_open: bool = true,

    pub fn dataDir(s: *const Settings) []const u8 {
        return s.data_dir[0..s.data_dir_len];
    }
    pub fn tokenStr(s: *const Settings) []const u8 {
        return s.token[0..s.token_len];
    }
    pub fn chatBase(s: *const Settings) []const u8 {
        return s.chat_base[0..s.chat_base_len];
    }
    pub fn chatModel(s: *const Settings) []const u8 {
        return s.chat_model[0..s.chat_model_len];
    }
    pub fn chatKey(s: *const Settings) []const u8 {
        return s.chat_key[0..s.chat_key_len];
    }
    pub fn cfAccount(s: *const Settings) []const u8 {
        return s.cf_account[0..s.cf_account_len];
    }
};

// ------------------------------------------------------------------------------------ chat state

pub const MAX_CHAT_MSGS = 64;
pub const MAX_CONVS = 32;
pub const MAX_CASTS = 6;
pub const CAST_TAIL = 40;
pub const STREAM_CAP = 16384; // in-flight reply buffer — UI-side snapshot buffers MUST use this same constant
//                               (a hardcoded 8192 copy in drawChat crashed the app the first time a streaming
//                               reply crossed 8KB: "index out of bounds: index 8194, len 8192")
pub const MAX_OLLAMA_MODELS = 48;
pub const METRIC_RING = 60; // per-turn performance samples for the chat Metrics tab

/// One completed chat turn's performance sample — the raw material for the Metrics tab's live graphs and the
/// "how is this model performing" read (the same numbers you'd use to compare open-source models fairly).
pub const TurnMetric = struct {
    first_byte_ms: u32 = 0, // latency to the first streamed token
    total_ms: u32 = 0, // wall-clock for the whole turn
    out_chars: u32 = 0, // characters produced (a ~4x proxy for output tokens)
    tok_per_s: f32 = 0, // approx output tokens/sec (out_chars/4 over the generation window)
    tools: u16 = 0, // tool calls fired on this turn
    kind: u8 = 0, // Turn tag (0 user / 1 collect / 2 tool_follow / 3 reflect / 4 loop_infer)
    ok: bool = true, // completed vs errored
};

/// One locally-installed Ollama model name (from GET /api/tags), for the Settings model dropdown.
pub const OllamaModel = struct {
    name: [96]u8 = [_]u8{0} ** 96,
    name_len: u8 = 0,
    pub fn nameStr(m: *const OllamaModel) []const u8 {
        return m.name[0..m.name_len];
    }
};

/// .thought is the veil's reasoning trace — rendered collapsed in the UI and EXCLUDED from the prompt
/// history (the model must never re-read its own prior reasoning as answer text). Persisted as "r":3.
pub const ChatRole = enum(u8) { user, veil, cast_note, thought };

/// One chat message of the ACTIVE conversation. Fixed-size like everything else in the Store; the chat
/// thread owns the full history on disk, this is the render copy.
pub const ChatMsg = struct {
    role: ChatRole = .user,
    text: [12288]u8 = [_]u8{0} ** 12288, // 12K: LLM answers (esp. reasoning + tables/code) blew past 3K and clipped
    text_len: u16 = 0,

    pub fn textStr(m: *const ChatMsg) []const u8 {
        return m.text[0..m.text_len];
    }
};

pub const ConvRow = struct {
    id: [32]u8 = [_]u8{0} ** 32, // file basename under .veil-desk/chats (no extension)
    id_len: u8 = 0,
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: u8 = 0,
    mtime_s: i64 = 0,

    pub fn idStr(c: *const ConvRow) []const u8 {
        return c.id[0..c.id_len];
    }
    pub fn titleStr(c: *const ConvRow) []const u8 {
        return c.title[0..c.title_len];
    }
};

pub const CastStatus = enum(u8) { deploying, running, collecting, finishing, done, failed };

/// One swarm cast fired from the chat, for the right-hand activity pane.
pub const CastRow = struct {
    run: [96]u8 = [_]u8{0} ** 96, // rel path under data ("u1/<hex>") once resolved; hex id before that
    run_len: u8 = 0,
    goal: [120]u8 = [_]u8{0} ** 120,
    goal_len: u8 = 0,
    status: CastStatus = .deploying,
    round: i64 = 0,
    pct: i32 = -1,
    last: [180]u8 = [_]u8{0} ** 180, // most recent act line
    last_len: u8 = 0,

    pub fn runStr(c: *const CastRow) []const u8 {
        return c.run[0..c.run_len];
    }
    pub fn goalStr(c: *const CastRow) []const u8 {
        return c.goal[0..c.goal_len];
    }
    pub fn lastStr(c: *const CastRow) []const u8 {
        return c.last[0..c.last_len];
    }
};

pub const ChatCmdKind = enum { none, send, new_conv, select_conv, rename_conv, delete_conv, stop_cast, save_settings, save_key, console_run, console_cancel, loop_kick, stop_turn, chat_open_file, chat_open_folder, forget_mem };

/// One durable memory the chat AI keeps for the user (a key, login, preference, fact). The value lives in
/// neuron-db (the chat's local hippocampus, used for relevance recall) mirrored to memories.jsonl for display.
/// This is a LOCAL, single-user store — secrets are fine to hold in plaintext here per the user's direction.
pub const MemRow = struct {
    cat: [24]u8 = [_]u8{0} ** 24, // one-word category: key / login / preference / fact
    cat_len: u8 = 0,
    text: [280]u8 = [_]u8{0} ** 280, // the remembered content
    text_len: u16 = 0,
    pub fn catStr(m: *const MemRow) []const u8 {
        return m.cat[0..m.cat_len];
    }
    pub fn textStr(m: *const MemRow) []const u8 {
        return m.text[0..m.text_len];
    }
};

/// A UI→chat-thread command; same copy-by-value ring discipline as Command.
pub const ChatCommand = struct {
    kind: ChatCmdKind = .none,
    id: [96]u8 = [_]u8{0} ** 96, // conversation id or cast run rel-path
    id_len: u8 = 0,
    text: [1600]u8 = [_]u8{0} ** 1600, // message text / new title / api key
    text_len: u16 = 0,

    pub fn idStr(c: *const ChatCommand) []const u8 {
        return c.id[0..c.id_len];
    }
    pub fn textStr(c: *const ChatCommand) []const u8 {
        return c.text[0..c.text_len];
    }
};

const CMD_RING = 32;
const NOTIF_RING = 8;
const CHAT_CMD_RING = 8;

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

    // --- selected swarm's built files (poller writes; Files tab reads) ---
    files: [scan.MAX_FILES]scan.FileRow = undefined,
    file_count: usize = 0,
    sel_file: [128]u8 = [_]u8{0} ** 128, // which file the Files viewer is showing (rel to work/)
    sel_file_len: u8 = 0,
    file_content: [1 << 14]u8 = undefined, // up to 16KB of the selected file, for the viewer
    file_content_len: usize = 0,
    file_content_trunc: bool = false,

    // --- settings (UI writes, poller reads) ---
    settings: Settings = .{},

    // --- locally-installed Ollama models (chat thread writes from /api/tags; Settings reads) ---
    ollama_models: [MAX_OLLAMA_MODELS]OllamaModel = undefined,
    ollama_model_count: usize = 0,

    // --- chat (chat thread writes, UI reads; UI writes the command ring) ---
    convs: [MAX_CONVS]ConvRow = undefined,
    conv_count: usize = 0,
    conv_active: [32]u8 = [_]u8{0} ** 32,
    conv_active_len: u8 = 0,
    msgs: [MAX_CHAT_MSGS]ChatMsg = undefined,
    msg_count: usize = 0,
    stream_text: [STREAM_CAP]u8 = undefined, // the in-flight assistant reply, grown as deltas land (16K: don't clip long answers)
    stream_len: usize = 0,
    stream_reason: [4096]u8 = undefined, // the in-flight reasoning (thinking), shown live line-by-line
    stream_reason_len: usize = 0,
    chat_busy: bool = false, // a model turn is in flight (Send disabled)
    chat_loop: bool = false, // full-auto: the AI writes + sends its own next message until DONE or the cap (runtime only)
    chat_status: [96]u8 = [_]u8{0} ** 96, // "thinking…" / "casting…" / "watching r3 42%"
    chat_status_len: u8 = 0,
    // Chat FILES inner tab — files produced inside THIS chat's own build dir ({conv}/work). The chat worker scans
    // + publishes here (mirrors the swarm-file viewer's `files` channel, but scoped to the conversation).
    chat_files: [scan.MAX_FILES]scan.FileRow = undefined,
    chat_file_count: usize = 0,
    chat_sel_file: [128]u8 = [_]u8{0} ** 128,
    chat_sel_file_len: usize = 0,
    chat_file_content: [1 << 14]u8 = undefined, // up to 16KB of the selected file, for the viewer
    chat_file_content_len: usize = 0,
    chat_file_content_trunc: bool = false,
    // Chat MEMORY tab — durable things the AI remembers for the user (keys, logins, preferences, facts). The chat
    // worker publishes these from memories.jsonl; neuron-db holds the same facts for relevance recall into prompts.
    chat_mem: [128]MemRow = undefined,
    chat_mem_count: usize = 0,
    // Micro-console (below Swarm activity): two independent shell sessions — "You" (the user drives it) and
    // "Veil" (the AI drives it via RUN:). Each keeps a scrollback ring the chat worker appends command output to.
    console_you: [16384]u8 = undefined,
    console_you_len: usize = 0,
    console_ai: [16384]u8 = undefined,
    console_ai_len: usize = 0,
    console_busy_you: bool = false,
    console_busy_ai: bool = false,
    console_show_veil: bool = false, // one-shot: the AI ran a RUN: — the UI flips to the Veil tab, then clears it
    casts: [MAX_CASTS]CastRow = undefined,
    cast_count: usize = 0,
    cast_tail: [CAST_TAIL]scan.Ev = undefined, // live event tail of the newest active cast
    cast_tail_count: usize = 0,
    // per-turn chat performance ring (chat worker appends, Metrics tab reads)
    turn_metrics: [METRIC_RING]TurnMetric = undefined,
    turn_metric_count: usize = 0, // total turns recorded (may exceed the ring; @min with METRIC_RING to iterate)

    // --- command ring (UI writes head, poller reads tail) ---
    cmds: [CMD_RING]Command = undefined,
    cmd_head: usize = 0,
    cmd_tail: usize = 0,

    // --- chat command ring (UI writes head, chat thread reads tail) ---
    chat_cmds: [CHAT_CMD_RING]ChatCommand = undefined,
    chat_cmd_head: usize = 0,
    chat_cmd_tail: usize = 0,

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
        log.trace("store.pushCmd kind={t} id={s}", .{ c.kind, c.idStr() });
        s.lock();
        defer s.unlock();
        if ((s.cmd_head + 1) % CMD_RING == s.cmd_tail) {
            log.trace("store.pushCmd DROPPED (ring full)", .{});
            return;
        }
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
        log.trace("store.popCmd kind={t} id={s}", .{ c.kind, c.idStr() });
        return c;
    }

    /// UI thread: enqueue a command for the chat thread. Same drop-when-full discipline as pushCmd.
    pub fn pushChatCmd(s: *Store, c: ChatCommand) void {
        log.trace("store.pushChatCmd kind={t} id={s}", .{ c.kind, c.idStr() });
        s.lock();
        defer s.unlock();
        if ((s.chat_cmd_head + 1) % CHAT_CMD_RING == s.chat_cmd_tail) {
            log.trace("store.pushChatCmd DROPPED (ring full)", .{});
            return;
        }
        s.chat_cmds[s.chat_cmd_head] = c;
        s.chat_cmd_head = (s.chat_cmd_head + 1) % CHAT_CMD_RING;
    }

    /// Record one completed turn's performance sample (chat worker → Metrics tab).
    pub fn pushMetric(s: *Store, m: TurnMetric) void {
        log.trace("store.pushMetric kind={d} ok={} first_byte_ms={d} total_ms={d} tools={d}", .{ m.kind, m.ok, m.first_byte_ms, m.total_ms, m.tools });
        s.lock();
        defer s.unlock();
        s.turn_metrics[s.turn_metric_count % METRIC_RING] = m;
        s.turn_metric_count += 1;
    }

    /// Append `text` to a console scrollback (ai=Veil console, else You). Keeps the newest ~half on overflow.
    pub fn consoleAppend(s: *Store, ai: bool, text: []const u8) void {
        log.trace("store.consoleAppend ai={} len={d}", .{ ai, text.len });
        s.lock();
        defer s.unlock();
        const buf = if (ai) &s.console_ai else &s.console_you;
        const lenp = if (ai) &s.console_ai_len else &s.console_you_len;
        if (lenp.* + text.len > buf.len) {
            const keep = buf.len / 2;
            const from = if (lenp.* > keep) lenp.* - keep else 0;
            std.mem.copyForwards(u8, buf[0..], buf[from..lenp.*]);
            lenp.* -= from;
        }
        const n = @min(text.len, buf.len - lenp.*);
        @memcpy(buf[lenp.* .. lenp.* + n], text[0..n]);
        lenp.* += n;
    }

    /// Chat thread: pop the next chat command, or null.
    pub fn popChatCmd(s: *Store) ?ChatCommand {
        s.lock();
        defer s.unlock();
        if (s.chat_cmd_tail == s.chat_cmd_head) return null;
        const c = s.chat_cmds[s.chat_cmd_tail];
        s.chat_cmd_tail = (s.chat_cmd_tail + 1) % CHAT_CMD_RING;
        log.trace("store.popChatCmd kind={t} id={s}", .{ c.kind, c.idStr() });
        return c;
    }

    /// Poller thread: raise a notification. Overwrites the oldest when full.
    pub fn pushNotif(s: *Store, title: []const u8, body: []const u8, accent: u8) void {
        log.trace("store.pushNotif title={s} accent={d}", .{ title, accent });
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
    log.trace("store.mkCmd kind={t} id={s} text_len={d}", .{ kind, id, text.len });
    var c: Command = .{ .kind = kind };
    const il = @min(id.len, c.id.len);
    @memcpy(c.id[0..il], id[0..il]);
    c.id_len = @intCast(il);
    const tl = @min(text.len, c.text.len);
    @memcpy(c.text[0..tl], text[0..tl]);
    c.text_len = @intCast(tl);
    return c;
}

pub fn mkChatCmd(kind: ChatCmdKind, id: []const u8, text: []const u8) ChatCommand {
    log.trace("store.mkChatCmd kind={t} id={s} text_len={d}", .{ kind, id, text.len });
    var c: ChatCommand = .{ .kind = kind };
    const il = @min(id.len, c.id.len);
    @memcpy(c.id[0..il], id[0..il]);
    c.id_len = @intCast(il);
    const tl = @min(text.len, c.text.len);
    @memcpy(c.text[0..tl], text[0..tl]);
    c.text_len = @intCast(tl);
    return c;
}
