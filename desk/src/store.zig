//! store.zig — the single source of truth shared between the UI thread (raylib, draw + input) and the
//! poller thread (io, filesystem + net). Every field behind one lock; the UI copies what it needs under
//! lock and never blocks on io, the poller writes under lock and never touches raylib. This hard split
//! keeps raylib single-threaded (its requirement) while the machine's state is read off-thread.

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

pub const Tab = enum { dashboard, chat, swarm, hub, scheduled, settings }; // deploy = the Swarm tab's inner form

pub const CmdKind = enum { none, select, say, set_goal, stop, deploy, delete, open_folder, refresh_now, open_file, sched_create, sched_update, sched_toggle, sched_delete, sched_run, oauth_cf_login, oauth_cf_logout };

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

/// One overridable provider role (thinking / prompting) in the model trio. Mirrors the base chat_* fields.
/// An unset role (`set` false or a blank model) falls back to the base/coding provider — see resolveProviderFor
/// in chat.zig. The api key is NOT persisted here: like the base chat_key it lives in the OS secret store keyed
/// by the (kind,byok) provider slug, and loadKey copies it into `key`/`key_len` in memory at startup + on save.
pub const RoleCfg = struct {
    set: bool = false, // has the user configured this role? false ⇒ inherit the base/coding provider
    kind: u8 = 0, // 0 local (Ollama) / 1 BYOK (catalog provider) / 2 custom URL — same encoding as chat_kind
    byok: u8 = 0, // catalog.providers index when kind==1
    base: [192]u8 = [_]u8{0} ** 192, // custom endpoint (OpenAI-compatible /v1 root)
    base_len: u8 = 0,
    model: [96]u8 = [_]u8{0} ** 96,
    model_len: u8 = 0,
    cf_account: [64]u8 = [_]u8{0} ** 64,
    cf_account_len: u8 = 0,
    key: [192]u8 = [_]u8{0} ** 192, // in-memory only (from secrets.zig); never written to settings.json
    key_len: u8 = 0,

    pub fn baseStr(r: *const RoleCfg) []const u8 {
        return r.base[0..r.base_len];
    }
    pub fn modelStr(r: *const RoleCfg) []const u8 {
        return r.model[0..r.model_len];
    }
    pub fn keyStr(r: *const RoleCfg) []const u8 {
        return r.key[0..r.key_len];
    }
    pub fn cfAccountStr(r: *const RoleCfg) []const u8 {
        return r.cf_account[0..r.cf_account_len];
    }
};

pub const Settings = struct {
    data_dir: [512]u8 = [_]u8{0} ** 512,
    data_dir_len: u16 = 0,
    port: u16 = 8787,
    // The veil server this desk drives. Empty = the local loopback default (the zero-config primary mode);
    // a non-empty value (IP literal or DNS name) points every server call — poller, deploy, server chat —
    // at a remote veil. Persisted with the settings.
    host: [64]u8 = [_]u8{0} ** 64,
    host_len: u8 = 0,
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
    // MODEL TRIO: the base chat_* fields above ARE the "coding" model (and, when unified, the model for all
    // three roles). When chat_unified is false, chat_think / chat_prompt override the "thinking" (planning +
    // context housekeeping) and "prompting" (auto-loop self-prompt-back) roles. Default unified = today's
    // single-model behavior; an old settings.json (no trio keys) loads as unified with both roles unset.
    chat_unified: bool = true,
    chat_think: RoleCfg = .{},
    chat_prompt: RoleCfg = .{},
    // chat pane collapse state (persisted with the chat settings)
    chat_left_open: bool = true,
    chat_right_open: bool = true,
    // chat pane widths — user drag-resizable, persisted (defaults match CHAT_LEFT_W/CHAT_RIGHT_W in main.zig)
    chat_left_w: u16 = 230,
    chat_right_w: u16 = 320,
    shell_always_allow: bool = false, // "Bypass" chosen once → the veil's RUN: shell commands skip the approval prompt
    // SPEED MODE (default ON): the chat BUILDS projects itself with its file tools, and casts are quick
    // research sub-agents capped at 2 minutes. OFF = the autonomy posture: the chat may deploy long
    // set-and-forget hiveminds (the original swarm design) for builds and deep work.
    speed_mode: bool = true,
    // DYSLEXIA MODE (default off): swap the proportional UI font for OpenDyslexic (bundled, SIL OFL) —
    // heavy-bottomed letterforms many dyslexic readers find easier to track. The render loop hot-swaps
    // the font atlas whenever this differs from what's applied, so the toggle needs no restart.
    dyslexia: bool = false,
    // TEXT SIZE (percent, 90|100|112|125) and WEIGHT — the rest of the typography customization. Size is
    // draw-time scaling (no atlas rebuild); weight swaps to the face's Bold file like dyslexia swaps face.
    font_scale: u8 = 100,
    font_bold: bool = false,
    // NARRATOR (default off): the app SPEAKS — replies and alerts are read aloud through the OS's own
    // text-to-speech (Windows SAPI / macOS say / espeak), so visually impaired users can operate the app
    // through the chat + their ears with ZERO audio code bundled in this client. Voice input rides the
    // OS dictation layer (Win+H types into the focused input) for the same reason.
    narrator: bool = false,
    // CHAT ENGINE: default LOCAL. Interactive chat runs IN THE DESK (in-process, no poll round-trip), so the
    // AI's tools execute in the client's environment on this machine — not the server's buried sandbox. When ON,
    // a send instead routes to the SERVER-side chat turn (POST /api/v1/chat/convs/:id/messages, rendered by
    // polling /events). Scheduled tasks always run server-side regardless of this — the desk may be closed.
    server_chat: bool = true, // default ON: the brain runs server-side and delegates tools to this client's harness
    // BROWSER WINDOW (default off = headless): when the AI drives a web browser on this machine, show the
    // browser window instead of running it hidden. Persisted, and mirrored to a small prefs file the local
    // browser daemon reads so the next browser session opens in the chosen mode without a restart.
    browser_headful: bool = false,

    pub fn dataDir(s: *const Settings) []const u8 {
        return s.data_dir[0..s.data_dir_len];
    }
    pub fn hostStr(s: *const Settings) []const u8 {
        return s.host[0..s.host_len];
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

    // ---- MODEL TRIO role accessors: role 0 = base/coding (the chat_* fields), 1 = thinking, 2 = prompting ----
    pub fn kindFor(s: *const Settings, role: u8) u8 {
        return switch (role) {
            1 => s.chat_think.kind,
            2 => s.chat_prompt.kind,
            else => s.chat_kind,
        };
    }
    pub fn byokFor(s: *const Settings, role: u8) u8 {
        return switch (role) {
            1 => s.chat_think.byok,
            2 => s.chat_prompt.byok,
            else => s.chat_byok,
        };
    }
    pub fn modelStrFor(s: *const Settings, role: u8) []const u8 {
        return switch (role) {
            1 => s.chat_think.modelStr(),
            2 => s.chat_prompt.modelStr(),
            else => s.chatModel(),
        };
    }
    pub fn keyLenFor(s: *const Settings, role: u8) usize {
        return switch (role) {
            1 => s.chat_think.key_len,
            2 => s.chat_prompt.key_len,
            else => s.chat_key_len,
        };
    }
    /// Set a role's provider kind, marking an override role (1/2) as configured (`set`).
    pub fn setKindFor(s: *Settings, role: u8, v: u8) void {
        switch (role) {
            1 => {
                s.chat_think.kind = v;
                s.chat_think.set = true;
            },
            2 => {
                s.chat_prompt.kind = v;
                s.chat_prompt.set = true;
            },
            else => s.chat_kind = v,
        }
    }
    pub fn setByokFor(s: *Settings, role: u8, v: u8) void {
        switch (role) {
            1 => {
                s.chat_think.byok = v;
                s.chat_think.set = true;
            },
            2 => {
                s.chat_prompt.byok = v;
                s.chat_prompt.set = true;
            },
            else => s.chat_byok = v,
        }
    }
    pub fn setModelFor(s: *Settings, role: u8, m: []const u8) void {
        switch (role) {
            1 => {
                const n = @min(m.len, s.chat_think.model.len);
                @memcpy(s.chat_think.model[0..n], m[0..n]);
                s.chat_think.model_len = @intCast(n);
                s.chat_think.set = true;
            },
            2 => {
                const n = @min(m.len, s.chat_prompt.model.len);
                @memcpy(s.chat_prompt.model[0..n], m[0..n]);
                s.chat_prompt.model_len = @intCast(n);
                s.chat_prompt.set = true;
            },
            else => {
                const n = @min(m.len, s.chat_model.len);
                @memcpy(s.chat_model[0..n], m[0..n]);
                s.chat_model_len = @intCast(n);
            },
        }
    }
    /// Whether an override role (1=thinking, 2=prompting) has its own config. Role 0 (base/coding) is always
    /// "set". An unset override role inherits the coding provider (resolveProviderFor falls back).
    pub fn roleSet(s: *const Settings, role: u8) bool {
        return switch (role) {
            1 => s.chat_think.set,
            2 => s.chat_prompt.set,
            else => true,
        };
    }
};

// ------------------------------------------------------------------------------------ chat state

pub const MAX_CHAT_MSGS = 64;
pub const MAX_CONVS = 32;
pub const MAX_CASTS = 6;
pub const CAST_TAIL = 40;
pub const STREAM_CAP = 16384; // in-flight reply buffer — UI-side snapshot buffers MUST use this same constant
pub const MAX_OLLAMA_MODELS = 48;
pub const METRIC_RING = 60; // per-turn performance samples for the chat Metrics tab

/// One completed chat turn's performance sample — the raw material for the Metrics tab's live graphs.
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
    text: [12288]u8 = [_]u8{0} ** 12288, // 12K: long LLM answers (reasoning + tables/code) need the headroom
    text_len: u16 = 0,
    img: [512]u8 = [_]u8{0} ** 512, // SOURCE path of an image attached to this message (user bubble); persisted so it re-renders on load
    img_len: u16 = 0,

    pub fn textStr(m: *const ChatMsg) []const u8 {
        return m.text[0..m.text_len];
    }
    pub fn imgStr(m: *const ChatMsg) []const u8 {
        return m.img[0..m.img_len];
    }
};

pub const ConvRow = struct {
    // 64: the server conv-id ceiling (safeSeg). 32 TRUNCATED scheduled_* run ids (34-39 chars) in the list, so
    // selecting one loaded an empty chat and deleting one deleted a nonexistent id — "cannot delete" live bug.
    id: [64]u8 = [_]u8{0} ** 64, // file basename under .veil-desk/chats (no extension)
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

pub const PlanStatus = enum(u8) { pending, active, done };

/// One subtask of the ACTIVE conversation's server plan-board ({conv}/plan.jsonl), for the right-hand activity
/// pane's checklist. Chat thread writes (watchPlan), UI reads — the same one-writer/one-reader discipline as casts.
pub const PlanRow = struct {
    text: [160]u8 = [_]u8{0} ** 160,
    text_len: u8 = 0,
    route: [12]u8 = [_]u8{0} ** 12, // "hive" | "research" | "inline"
    route_len: u8 = 0,
    status: PlanStatus = .pending,

    pub fn textStr(p: *const PlanRow) []const u8 {
        return p.text[0..p.text_len];
    }
    pub fn routeStr(p: *const PlanRow) []const u8 {
        return p.route[0..p.route_len];
    }
};
pub const MAX_PLAN = 32; // == the server plan-board's MAX_TASKS cap

pub const MAX_SCHED = 32;
pub const MAX_CF_MODELS = 64; // live Workers AI models fetched from the connected Cloudflare account

/// One task (poller writes from GET /api/v1/sched; the Tasks tab reads). Raw schedule fields are kept —
/// the UI composes the human summary ("every 30m" / "daily 09:00") at draw time, so the row never goes
/// stale against a clock the poller doesn't re-publish. prompt/details are FULL-fidelity (the Field cap,
/// 1200 bytes) because the edit form must round-trip them verbatim — a clipped preview would silently
/// truncate the task on the first save. Draw code snapshots the slim SchedRowView, never whole rows.
pub const SchedRow = struct {
    id: [64]u8 = [_]u8{0} ** 64,
    id_len: u8 = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    kind: u8 = 0, // 0 once / 1 every / 2 daily — mirrors the task's "kind"
    at: i64 = 0, // epoch of the one-shot run (kind once)
    every_min: u32 = 0, // interval minutes (kind every)
    hm: [8]u8 = [_]u8{0} ** 8, // "HH:MM" (kind daily)
    hm_len: u8 = 0,
    enabled: bool = true,
    next_due: i64 = 0,
    last_run: i64 = 0,
    runs: u32 = 0,
    last_conv: [64]u8 = [_]u8{0} ** 64, // the newest scheduled_* conversation this task produced
    last_conv_len: u8 = 0,
    prompt: [1200]u8 = [_]u8{0} ** 1200, // the FULL prompt (edit round-trip; rows draw a clipped preview)
    prompt_len: u16 = 0,
    details: [1200]u8 = [_]u8{0} ** 1200, // full key-details block, same reason
    details_len: u16 = 0,
    base_url: [192]u8 = [_]u8{0} ** 192, // per-task provider override ("" = server resolves its default)
    base_url_len: u8 = 0,
    model: [96]u8 = [_]u8{0} ** 96,
    model_len: u8 = 0,
    recent: [340]u8 = [_]u8{0} ** 340, // run HISTORY: comma-joined conv ids, newest first (server caps at 5)
    recent_len: u16 = 0,

    pub fn idStr(s: *const SchedRow) []const u8 {
        return s.id[0..s.id_len];
    }
    pub fn nameStr(s: *const SchedRow) []const u8 {
        return s.name[0..s.name_len];
    }
    pub fn hmStr(s: *const SchedRow) []const u8 {
        return s.hm[0..s.hm_len];
    }
    pub fn lastConvStr(s: *const SchedRow) []const u8 {
        return s.last_conv[0..s.last_conv_len];
    }
    pub fn promptStr(s: *const SchedRow) []const u8 {
        return s.prompt[0..s.prompt_len];
    }
    pub fn detailsStr(s: *const SchedRow) []const u8 {
        return s.details[0..s.details_len];
    }
    pub fn baseUrlStr(s: *const SchedRow) []const u8 {
        return s.base_url[0..s.base_url_len];
    }
    pub fn modelStr(s: *const SchedRow) []const u8 {
        return s.model[0..s.model_len];
    }
    pub fn recentStr(s: *const SchedRow) []const u8 {
        return s.recent[0..s.recent_len];
    }
};

/// What the task LIST rows actually draw — a slim per-row snapshot (~0.5KB vs the ~3KB full SchedRow), so
/// the draw functions' copy-out-under-lock pattern stays cheap on the render thread's stack now that
/// SchedRow carries full-fidelity prompt/details for the edit form.
pub const SchedRowView = struct {
    id: [64]u8 = [_]u8{0} ** 64,
    id_len: u8 = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    kind: u8 = 0,
    at: i64 = 0,
    every_min: u32 = 0,
    hm: [8]u8 = [_]u8{0} ** 8,
    hm_len: u8 = 0,
    enabled: bool = true,
    next_due: i64 = 0,
    runs: u32 = 0,
    last_conv: [64]u8 = [_]u8{0} ** 64,
    last_conv_len: u8 = 0,
    prompt: [96]u8 = [_]u8{0} ** 96, // clipped preview for the row subtitle
    prompt_len: u8 = 0,

    pub fn of(r: *const SchedRow) SchedRowView {
        var v = SchedRowView{
            .id = r.id,
            .id_len = r.id_len,
            .name = r.name,
            .name_len = r.name_len,
            .kind = r.kind,
            .at = r.at,
            .every_min = r.every_min,
            .hm = r.hm,
            .hm_len = r.hm_len,
            .enabled = r.enabled,
            .next_due = r.next_due,
            .runs = r.runs,
            .last_conv = r.last_conv,
            .last_conv_len = r.last_conv_len,
        };
        const pn: usize = @min(r.prompt_len, v.prompt.len);
        @memcpy(v.prompt[0..pn], r.prompt[0..pn]);
        v.prompt_len = @intCast(pn);
        return v;
    }
    pub fn idStr(s: *const SchedRowView) []const u8 {
        return s.id[0..s.id_len];
    }
    pub fn nameStr(s: *const SchedRowView) []const u8 {
        return s.name[0..s.name_len];
    }
    pub fn hmStr(s: *const SchedRowView) []const u8 {
        return s.hm[0..s.hm_len];
    }
    pub fn lastConvStr(s: *const SchedRowView) []const u8 {
        return s.last_conv[0..s.last_conv_len];
    }
    pub fn promptStr(s: *const SchedRowView) []const u8 {
        return s.prompt[0..s.prompt_len];
    }
};

test "SchedRowView.of clips the full prompt to a preview and carries every draw field" {
    var full = SchedRow{};
    @memcpy(full.id[0..7], "task-01");
    full.id_len = 7;
    @memcpy(full.name[0..5], "probe");
    full.name_len = 5;
    full.kind = 1;
    full.every_min = 30;
    full.enabled = false;
    full.next_due = 12345;
    full.runs = 7;
    @memcpy(full.last_conv[0..10], "scheduled_");
    full.last_conv_len = 10;
    // a prompt longer than the 96-byte preview window must CLIP, never overflow or drop the row
    for (0..300) |i| full.prompt[i] = 'p';
    full.prompt_len = 300;
    const v = SchedRowView.of(&full);
    try std.testing.expectEqualStrings("task-01", v.idStr());
    try std.testing.expectEqualStrings("probe", v.nameStr());
    try std.testing.expectEqual(@as(u8, 1), v.kind);
    try std.testing.expectEqual(@as(u32, 30), v.every_min);
    try std.testing.expectEqual(false, v.enabled);
    try std.testing.expectEqual(@as(i64, 12345), v.next_due);
    try std.testing.expectEqual(@as(u32, 7), v.runs);
    try std.testing.expectEqualStrings("scheduled_", v.lastConvStr());
    try std.testing.expectEqual(@as(usize, 96), v.promptStr().len);
}

// --- LLM usage metrics (poller writes from GET /api/v1/metrics/llm; the Dashboard reads) ---

pub const MAX_LLM_MODELS = 16;
pub const LLM_DAYS = 14; // mirrors the server's aggregation window (worker/metrics.zig DAYS)

/// One (model, provider-host) usage aggregate — everything the Dashboard's breakdown table shows.
pub const LlmModelRow = struct {
    model: [96]u8 = [_]u8{0} ** 96,
    model_len: u8 = 0,
    base: [96]u8 = [_]u8{0} ** 96, // provider HOST only (never a path, never a key)
    base_len: u8 = 0,
    calls: u64 = 0,
    tin: u64 = 0,
    tout: u64 = 0,
    secs: u64 = 0, // summed wall seconds of the turns — tout/secs = observed generation speed
    last_ts: i64 = 0,

    pub fn modelStr(s: *const LlmModelRow) []const u8 {
        return s.model[0..s.model_len];
    }
    pub fn baseStr(s: *const LlmModelRow) []const u8 {
        return s.base[0..s.base_len];
    }
};

/// One local day of activity (the 14-day bars). `day` = local epoch-day from the server.
pub const LlmDay = struct { day: i64 = 0, tin: u64 = 0, tout: u64 = 0, calls: u64 = 0 };

pub const ChatCmdKind = enum { none, send, steer_turn, new_conv, select_conv, rename_conv, delete_conv, stop_cast, save_settings, save_key, console_run, console_cancel, loop_kick, stop_turn, chat_open_file, chat_open_folder, forget_mem, console_approve, console_deny, prop_accept, prop_reject, set_github_pat, set_github_user };

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

/// A learning proposal awaiting HUMAN review (the background judge writes these into quarantine
/// "-proposed" neuron scopes, never into the live ones; accepting promotes, rejecting discards).
pub const PropRow = struct {
    scope: u8 = 0, // 0 = playbook (operational lesson), 1 = skill (procedure), 2 = user (working model)
    text: [420]u8 = [_]u8{0} ** 420, // proposal text incl. its "| evidence: ..." grounding tail
    text_len: u16 = 0,
    pub fn textStr(p: *const PropRow) []const u8 {
        return p.text[0..p.text_len];
    }
};

/// A UI→chat-thread command; same copy-by-value ring discipline as Command.
pub const ChatCommand = struct {
    kind: ChatCmdKind = .none,
    id: [96]u8 = [_]u8{0} ** 96, // conversation id or cast run rel-path
    id_len: u8 = 0,
    text: [4096]u8 = [_]u8{0} ** 4096, // message text (up to the large-model input budget) / new title / api key
    text_len: u16 = 0,
    // Optional image attachment for a .send: the SOURCE file PATH (base64 is too big for this ring's buffers and
    // textures are GL-thread-only, so the chat thread reads + encodes the file from this path). Empty = none.
    attach_path: [512]u8 = [_]u8{0} ** 512,
    attach_path_len: u16 = 0,

    pub fn idStr(c: *const ChatCommand) []const u8 {
        return c.id[0..c.id_len];
    }
    pub fn textStr(c: *const ChatCommand) []const u8 {
        return c.text[0..c.text_len];
    }
    pub fn attachStr(c: *const ChatCommand) []const u8 {
        return c.attach_path[0..c.attach_path_len];
    }
};

const CMD_RING = 32;
const NOTIF_RING = 8;
const CHAT_CMD_RING = 8;

pub const Store = struct {
    mu: SpinLock = .{},

    // --- server / fleet (poller writes) ---
    server_online: bool = false,
    // True once the chat thread finished loadSettings (whether or not a settings file existed) — the
    // Settings tab seeds its editable host/port fields from persisted values exactly once, gated on this
    // so a first render can't capture pre-load defaults.
    settings_loaded: bool = false,
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
    sel_config: scan.SwarmConfig = .{}, // the selected swarm's manifest + blueprint (Details tab: the exact
    //                                     prompt + configuration the run was given)

    // --- settings (UI writes, poller reads) ---
    settings: Settings = .{},

    // --- locally-installed Ollama models (chat thread writes from /api/tags; Settings reads) ---
    ollama_models: [MAX_OLLAMA_MODELS]OllamaModel = undefined,
    ollama_model_count: usize = 0,

    // --- judge proposals awaiting review (chat thread writes; Memory pane reads) ---
    chat_props: [12]PropRow = undefined,
    chat_prop_count: usize = 0,

    // --- chat (chat thread writes, UI reads; UI writes the command ring) ---
    convs: [MAX_CONVS]ConvRow = undefined,
    conv_count: usize = 0,
    conv_active: [64]u8 = [_]u8{0} ** 64, // 64 = the conv-id ceiling (a scheduled_* run id is 34-39 chars)
    conv_active_len: u8 = 0,
    msgs: [MAX_CHAT_MSGS]ChatMsg = undefined,
    msg_count: usize = 0,
    stream_text: [STREAM_CAP]u8 = undefined, // the in-flight assistant reply, grown as deltas land (16K: don't clip long answers)
    stream_len: usize = 0,
    stream_reason: [4096]u8 = undefined, // the in-flight reasoning (thinking), shown live line-by-line
    stream_reason_len: usize = 0,
    stream_draft: bool = false, // the in-flight content is a PRE-FINAL draft (a self-check will follow / is
    //                             running) — the UI renders it as thinking, never as a delivered answer
    chat_busy: bool = false, // a model turn is in flight (Send disabled)
    chat_loop: bool = false, // full-auto: the AI writes + sends its own next message until DONE or the cap (runtime only)
    chat_server_turn: bool = false, // a SERVER-side chat turn is currently in flight (mirror of Chat.sc_active) —
    //                                 the input row reads this to enable "type + Enter = steer the running turn"
    chat_loop_afk: bool = false, // THIRD TIER (double-click the toggle): the loop NEVER backs itself out —
    //                              DONE, failures, caps, cast pauses, and questions all reset their budget
    //                              instead of stopping; runs until the user clicks it off or hits Stop
    //                              (runtime only; afk implies chat_loop armed)
    goto_conv: [64]u8 = undefined, // POLLER→RENDER hand-off: open this conversation in Chat (a run-now's minted
    goto_conv_len: u8 = 0, //         scheduled_* conv); the render loop consumes it once per set
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
    // Command-approval gate: a veil RUN: shell command PARKS here awaiting the user's Approve / Bypass(always) /
    // Deny. The chat thread sets console_pending + the command; the Veil tab renders the buttons; the choice
    // rides back as a console_approve/console_deny ChatCommand. (Bypass persists via Settings.shell_always_allow.)
    console_pending: bool = false,
    console_pending_cmd: [1024]u8 = undefined,
    console_pending_len: usize = 0,
    // The You shell's CURRENT DIRECTORY (chat thread resolves + writes; the console UI shows it as the prompt).
    console_cwd: [400]u8 = undefined,
    console_cwd_len: usize = 0,
    casts: [MAX_CASTS]CastRow = undefined,
    cast_count: usize = 0,
    cast_tail: [CAST_TAIL]scan.Ev = undefined, // live event tail of the newest active cast
    cast_tail_count: usize = 0,
    plan: [MAX_PLAN]PlanRow = undefined, // the ACTIVE conv's plan-board checklist (chat watchPlan writes, UI reads)
    plan_count: usize = 0,
    // per-turn chat performance ring (chat worker appends, Metrics tab reads)
    turn_metrics: [METRIC_RING]TurnMetric = undefined,
    turn_metric_count: usize = 0, // total turns recorded (may exceed the ring; @min with METRIC_RING to iterate)

    // --- LLM usage metrics (poller writes from GET /api/v1/metrics/llm; Dashboard reads) ---
    llm_models: [MAX_LLM_MODELS]LlmModelRow = undefined,
    llm_model_count: usize = 0,
    llm_days: [LLM_DAYS]LlmDay = [_]LlmDay{.{}} ** LLM_DAYS, // oldest first, [LLM_DAYS-1] = today
    llm_tot_calls: u64 = 0,
    llm_tot_in: u64 = 0,
    llm_tot_out: u64 = 0,
    llm_tot_secs: u64 = 0,
    llm_seen: bool = false, // first successful metrics fetch landed ("no usage yet" vs "loading")

    // --- scheduled tasks (poller writes from GET /api/v1/sched; Scheduled tab reads) ---
    sched_rows: [MAX_SCHED]SchedRow = undefined,
    sched_count: usize = 0,
    sched_seen: bool = false, // the first successful list fetch landed ("loading…" vs "no tasks yet")
    sched_denied: bool = false, // the list GET came back 401/403 — the tab shows "admin token required"
    // Task-payload hand-off: the full create/update JSON (three 1200-byte form fields, worst-case 2x
    // escaped) outgrows Command.text, so the UI writes it HERE under lock and pushes a bare .sched_create
    // or .sched_update (id in Command.id); the poller copies + clears it when it drains that command. One
    // slot — a second submit before the poller wakes (sub-second) overwrites the first, same drop-tolerant
    // discipline as the command ring itself.
    sched_create_json: [8192]u8 = undefined,
    sched_create_len: usize = 0,

    // --- Cloudflare OAuth login state (poller writes from GET /oauth/cloudflare/status; Settings tab reads) ---
    cf_oauth_seen: bool = false, //       a status fetch has landed at least once
    cf_oauth_configured: bool = false, // the server has an OAuth client_id (else the login button is inert)
    cf_oauth_connected: bool = false, //  this user has a stored Cloudflare credential
    cf_oauth_pending: bool = false, //    a login was started; waiting for the browser callback to complete
    cf_oauth_account: [64]u8 = undefined, // the connected account id (for display)
    cf_oauth_account_len: usize = 0,
    // Live Workers AI model list, fetched from the connected account (the catalog changes fast). The model
    // dropdown uses these for the Cloudflare provider when non-empty; empty → catalog defaults.
    cf_models: [MAX_CF_MODELS][96]u8 = undefined,
    cf_model_lens: [MAX_CF_MODELS]u8 = undefined,
    cf_model_count: usize = 0,

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

    // --- narrator utterance queue (any thread pushes; the poller speaks via the OS TTS) ---
    narr_q: [NARR_RING][NARR_TEXT]u8 = undefined,
    narr_lens: [NARR_RING]u16 = [_]u16{0} ** NARR_RING,
    narr_head: usize = 0,
    narr_count: usize = 0,

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

    /// Wipe a console scrollback (the You shell's `clear`/`cls` builtin; ai=Veil kept for symmetry).
    pub fn consoleClear(s: *Store, ai: bool) void {
        s.lock();
        defer s.unlock();
        if (ai) s.console_ai_len = 0 else s.console_you_len = 0;
    }

    /// Publish the You shell's current directory (chat thread resolves it; the console UI shows the prompt).
    pub fn consoleSetCwd(s: *Store, cwd: []const u8) void {
        s.lock();
        defer s.unlock();
        const n = @min(cwd.len, s.console_cwd.len);
        @memcpy(s.console_cwd[0..n], cwd[0..n]);
        s.console_cwd_len = n;
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
        // narrator: every toast is also an utterance ("Task updated. news.") — the audible app surface
        var nb: [NARR_TEXT]u8 = undefined;
        const spoken = std.fmt.bufPrint(&nb, "{s}. {s}", .{ title, body }) catch title;
        s.narrPushLocked(spoken);
    }

    /// Queue one narrator utterance (spoken by the poller through the OS TTS). Thread-safe; drops the
    /// OLDEST when full — narration must track the present, not replay a backlog.
    pub fn pushNarr(s: *Store, text: []const u8) void {
        s.lock();
        defer s.unlock();
        s.narrPushLocked(text);
    }

    fn narrPushLocked(s: *Store, text: []const u8) void {
        if (!s.settings.narrator or text.len == 0) return;
        if (s.narr_count >= NARR_RING) { // full → drop the oldest
            s.narr_head = (s.narr_head + 1) % NARR_RING;
            s.narr_count -= 1;
        }
        const idx = (s.narr_head + s.narr_count) % NARR_RING;
        const n = @min(text.len, NARR_TEXT);
        @memcpy(s.narr_q[idx][0..n], text[0..n]);
        s.narr_lens[idx] = @intCast(n);
        s.narr_count += 1;
    }

    /// Pop the next utterance into `out`; 0 = queue empty.
    pub fn popNarr(s: *Store, out: *[NARR_TEXT]u8) usize {
        s.lock();
        defer s.unlock();
        if (s.narr_count == 0) return 0;
        const n = s.narr_lens[s.narr_head];
        @memcpy(out[0..n], s.narr_q[s.narr_head][0..n]);
        s.narr_head = (s.narr_head + 1) % NARR_RING;
        s.narr_count -= 1;
        return n;
    }
};

pub const NARR_RING = 4; // pending utterances — small on purpose (see drop-oldest above)
pub const NARR_TEXT = 440; // one utterance's byte cap (~30s of speech)

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
