//! sched.zig — SCHEDULED TASKS that run strictly THROUGH CHAT.
//!
//! A task is one JSON file at `{data}/u{uid}/_sched/{id}.json`. When it comes due, the scheduler thread mints a
//! brand-new chat conversation named `scheduled_{id}_{MMDDHHMM}` and fires ONE normal server chat turn at it via
//! the SAME engine entry points the /messages route uses (tryBeginTurn + spawnTurn) — so a scheduled run is a
//! real conversation: it persists under `_chat/convs/`, streams events, shows up in the conv list, and can be
//! continued by hand afterwards. The scheduler owns NOTHING about how the turn runs; it only decides WHEN to
//! post the first message.
//!
//!   GET    /api/v1/sched          -> {ok:true, tasks:[Task,...]}      (api_key ALWAYS redacted to "")
//!   POST   /api/v1/sched          -> create; 201 {ok:true, id}
//!   POST   /api/v1/sched/:id      -> partial update; {ok:true}
//!   DELETE /api/v1/sched/:id      -> {ok:true}                        (404 if absent)
//!   POST   /api/v1/sched/:id/run  -> run NOW; {ok:true, conv:"scheduled_..."}
//!
//! All routes are admin-gated exactly like chat_service.postMessage: the served chat turn hands the model the
//! full tool surface, so until per-role tool gating lands, only the admin may aim it — scheduled or not.
//! Catch-up policy for overdue tasks (server was down, machine slept): run ONCE and schedule the next occurrence
//! from NOW — never backfill a run per missed interval (a laptop closed for a week must not fire 2016 turns).
//!
//! SELF-HEALING / SELF-IMPROVING: a task is not a frozen prompt. Every run's first message carries an
//! engine-authored RUN CONTEXT (its own task id, run number, cadence, and the previous run's recorded outcome),
//! runs may revise their OWN definition through the chat veil's schedule_update tool (updateById — the same
//! single validated path the HTTP update route uses), and the engine keeps a mechanical outcome ledger on the
//! task file (last_status + fail_streak). A failed run makes the next run open in repair posture ("fix the
//! cause first"), and consecutive failures back the schedule off exponentially (failBackoffSecs) so a broken
//! task retries at declining cost instead of burning a full run every interval forever.

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const http = @import("../gateway/http.zig");
const chat_engine = @import("chat/engine.zig");
const cpaths = @import("chat/paths.zig"); // conv → build-tree mapping: a run builds in _sched/{task}/runs/{stamp}

const App = http.App;
const badReq = http.badReq;
const notFound = http.notFound;
const serverErr = http.serverErr;

// ---- task model (the WIRE CONTRACT — field names are what the desk client parses; do not rename) -----------

/// One scheduled task, exactly as stored on disk and (api_key redacted) as served over HTTP. Every field has a
/// default so a hand-edited or older file still parses (ignore_unknown_fields covers the other direction).
pub const Task = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    prompt: []const u8 = "",
    details: []const u8 = "",
    kind: []const u8 = "once", // "once" | "every" | "daily"
    at: i64 = 0, // "once": epoch seconds to fire at
    every_min: i64 = 0, // "every": interval in minutes (>= 1)
    hm: []const u8 = "", // "daily": local wall-clock "HH:MM"
    enabled: bool = true,
    created: i64 = 0,
    last_run: i64 = 0,
    next_due: i64 = 0,
    last_conv: []const u8 = "",
    recent_convs: []const u8 = "", // run HISTORY: up to RECENT_MAX conv ids, comma-joined, newest first (includes last_conv)
    runs: i64 = 0,
    // Mechanical outcome ledger (engine-written, never model text): the previous run's one-line outcome and how
    // many runs in a row have FAILED (0 = healthy). fail_streak > 0 puts the next run in repair posture
    // (buildRunMessage's SELF-HEAL block) and, from the second consecutive failure, backs the schedule off
    // (recordRunOutcome + failBackoffSecs). revisions counts definition updates (route or schedule_update) —
    // the visible trace of a task improving itself over time.
    last_status: []const u8 = "",
    fail_streak: i64 = 0,
    revisions: i64 = 0,
    base_url: []const u8 = "",
    model: []const u8 = "",
    api_key: []const u8 = "", // STORED on disk; NEVER echoed back out — encodeTask redacts it for HTTP
    // MODEL TRIO (optional, appended to the wire contract): per-role provider overrides so an unattended run
    // uses the same trio the creating turn did — `think_*` for planning + context housekeeping, `prompt_*`
    // for the auto-loop drive. Empty ⇒ that role falls back to base_url/model/api_key at run time (resolveTrio).
    // Both role keys are secrets: encodeTask redacts them for HTTP exactly like api_key. Old task files lack
    // these keys entirely — parseFromSliceLeaky(ignore_unknown_fields) leaves them "" ⇒ single-model as before.
    think_base_url: []const u8 = "",
    think_model: []const u8 = "",
    think_api_key: []const u8 = "",
    prompt_base_url: []const u8 = "",
    prompt_model: []const u8 = "",
    prompt_api_key: []const u8 = "",
};

/// How many run conversations a task remembers (the desk's "recent runs" investigation list). Five keeps the
/// comma-joined field bounded (5 × 64-byte conv ids + commas < 340 bytes) while comfortably clearing the
/// product floor of three previous chats per task.
pub const RECENT_MAX: usize = 5;

/// Prepend `newest` to the comma-joined `old` history, dropping any duplicate of `newest` (a same-minute
/// re-run mints the same conv id) and clipping to RECENT_MAX entries. Allocated into `alloc` (arena).
pub fn joinRecent(alloc: std.mem.Allocator, newest: []const u8, old: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(alloc, newest) catch return newest;
    var kept: usize = 1;
    var it = std.mem.splitScalar(u8, old, ',');
    while (it.next()) |e| {
        const id = std.mem.trim(u8, e, " \r\n\t");
        if (id.len == 0 or std.mem.eql(u8, id, newest)) continue;
        if (kept >= RECENT_MAX) break;
        out.append(alloc, ',') catch break;
        out.appendSlice(alloc, id) catch break;
        kept += 1;
    }
    return out.items;
}

fn validKind(k: []const u8) bool {
    return std.mem.eql(u8, k, "once") or std.mem.eql(u8, k, "every") or std.mem.eql(u8, k, "daily");
}

/// Interval ceiling: one year in minutes. Bounds `every_min * 60` (and the tool's in_min) safely inside i64 —
/// no schedule anyone means outlasts it, and an absurd value can't overflow-panic the tick loop.
pub const EVERY_MIN_MAX: i64 = 527040;

// ---- small local twins of private helpers elsewhere (kept verbatim so behavior can never drift) -------------

/// Sanitize an id into ONE safe path segment (alnum / - / _ only, no separators, no "..", bounded). Empty /
/// unsafe → "". Mirrors chat_service.safeSeg verbatim: a task id must satisfy the SAME rules as a conv id,
/// because the task id is embedded into the conversation id the run mints.
fn safeSeg(id: []const u8) []const u8 {
    const t = std.mem.trim(u8, id, " \r\n\t");
    if (t.len == 0 or t.len > 64) return "";
    for (t) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return "";
    }
    return t;
}

/// io-based wall clock — the SAME source the chat engine stamps message `ts` with (std time under io, never a
/// raw clock primitive). Local copy of chat engine nowSecs (private there).
fn nowSecs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Sleep `ms` from a RAW OS thread — local copy of supervisor.threadSleepMs (private there): the scheduler loop
/// is a std.Thread, NOT an Io-managed task, so io.sleep throws on it and swallowing that error would turn the
/// loop into a 100%-CPU spin.
fn threadSleepMs(io: std.Io, ms: u64) void {
    if (builtin.os.tag == .windows) {
        wintz.Sleep(@intCast(ms));
    } else {
        io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
    }
}

// Native Win32 for the two OS facts this module needs (no subprocess, same rationale as supervisor.winproc):
// a raw-thread sleep, and the machine's UTC-offset so "daily at HH:MM" means the USER's wall clock, not UTC.
const wintz = if (builtin.os.tag == .windows) struct {
    const SYSTEMTIME = extern struct { wYear: u16, wMonth: u16, wDayOfWeek: u16, wDay: u16, wHour: u16, wMinute: u16, wSecond: u16, wMilliseconds: u16 };
    const TIME_ZONE_INFORMATION = extern struct {
        Bias: i32,
        StandardName: [32]u16,
        StandardDate: SYSTEMTIME,
        StandardBias: i32,
        DaylightName: [32]u16,
        DaylightDate: SYSTEMTIME,
        DaylightBias: i32,
    };
    extern "kernel32" fn GetTimeZoneInformation(tzi: *TIME_ZONE_INFORMATION) callconv(.c) u32;
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
} else struct {};

/// The local clock's offset from UTC in seconds (local = UTC + offset), asked of the OS on every call so a DST
/// flip mid-uptime is picked up naturally. Non-Windows (and any query failure) degrades to UTC — a daily task
/// still fires exactly once a day, just anchored to UTC wall time instead of local. Pub: the chat veil's
/// schedule_task tool converts "at 18:30" the same way the tick loop does.
pub fn localOffsetSecs() i64 {
    if (builtin.os.tag != .windows) return 0;
    var tzi: wintz.TIME_ZONE_INFORMATION = undefined;
    const r = wintz.GetTimeZoneInformation(&tzi);
    // Bias is in minutes with UTC = local + Bias, so the local offset is its NEGATION; the active standard/
    // daylight adjustment rides on top. An invalid answer (0xFFFFFFFF) degrades to UTC rather than guessing.
    const bias_min: i64 = switch (r) {
        0 => @as(i64, tzi.Bias), // TIME_ZONE_ID_UNKNOWN — no DST info; the base bias is all there is
        1 => @as(i64, tzi.Bias) + @as(i64, tzi.StandardBias),
        2 => @as(i64, tzi.Bias) + @as(i64, tzi.DaylightBias),
        else => return 0,
    };
    return -bias_min * 60;
}

// ---- pure calendar/schedule math (std-only, unit-tested below) ----------------------------------------------

const Civil = struct { mo: u32, day: u32, hh: u32, mi: u32, ss: u32 };

/// Split epoch seconds into month/day + time-of-day — the same civil-from-days Gregorian math run.zig's
/// formatNow uses (Zig has no strftime). Feed it `secs + offset` for local wall-clock fields.
fn civilOf(secs: i64) Civil {
    const days = @divFloor(secs, 86400);
    const sod = secs - days * 86400;
    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const mo = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .mo = @intCast(mo),
        .day = @intCast(day),
        .hh = @intCast(@divFloor(sod, 3600)),
        .mi = @intCast(@divFloor(@mod(sod, 3600), 60)),
        .ss = @intCast(@mod(sod, 60)),
    };
}

pub const Hm = struct { h: u32, m: u32 };

/// Parse "HH:MM" (lenient on zero-padding: "9:5" is 09:05). null on anything unparseable / out of range.
pub fn parseHm(hm: []const u8) ?Hm {
    const t = std.mem.trim(u8, hm, " \r\n\t");
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const h = std.fmt.parseInt(u32, t[0..colon], 10) catch return null;
    const m = std.fmt.parseInt(u32, t[colon + 1 ..], 10) catch return null;
    if (h > 23 or m > 59) return null;
    return .{ .h = h, .m = m };
}

/// When should this task fire next? Pure — the caller supplies `now` and the local-clock offset so the math is
/// directly testable.
///   "once"  → `at`, verbatim (fires as soon as next_due <= now; enabled flips off after the run).
///   "every" → last_run (or created, before the first run) + every_min*60. After a run the caller has already
///             set last_run = now, so an OVERDUE interval task runs ONCE and re-anchors to NOW — the catch-up
///             policy; missed intervals are never backfilled.
///   "daily" → the next local wall-clock occurrence of hm STRICTLY after now (today if still ahead, else
///             tomorrow), converted back to UTC epoch seconds.
pub fn computeNextDue(kind: []const u8, at: i64, every_min: i64, hm: []const u8, created: i64, last_run: i64, now: i64, tz_off: i64) i64 {
    if (std.mem.eql(u8, kind, "every")) {
        const base = if (last_run > 0) last_run else created;
        // Clamp BOTH ways (hand-edited file; the API validates 1..EVERY_MIN_MAX): the floor bounds a garbled
        // task to one run per minute; the CEILING keeps `every_min * 60` inside i64 — an absurd interval would
        // otherwise overflow-panic the scheduler thread on every tick, killing scheduling for the whole server.
        const step = std.math.clamp(every_min, 1, EVERY_MIN_MAX) * 60;
        return base + step;
    }
    if (std.mem.eql(u8, kind, "daily")) {
        const p = parseHm(hm) orelse return now + 86400; // garbled hm (hand-edit) → try again in a day, NEVER a per-tick fire loop
        const local_now = now + tz_off;
        const day = @divFloor(local_now, 86400);
        var target = day * 86400 + @as(i64, p.h) * 3600 + @as(i64, p.m) * 60;
        if (target <= local_now) target += 86400;
        return target - tz_off;
    }
    return at; // "once" (and, via loadTask's normalization, anything unknown — which then disables itself after one run)
}

/// How much LONGER than its normal cadence a failing "every" task waits before the next attempt, given how many
/// runs in a row have failed. Pure — recordRunOutcome pushes next_due by this after a failed run.
///   streak 1  → 0 (the first failure retries on the normal schedule, in repair posture — cheap to heal fast)
///   streak 2+ → interval × 2,4,8,16 (shift capped at ×16), absolute cap 2 days
/// "daily" already retries at most once a day and "once" consumed itself, so only "every" backs off — the kind
/// where an always-failing task would otherwise burn a full unattended run every N minutes forever.
pub fn failBackoffSecs(kind: []const u8, every_min: i64, fail_streak: i64) i64 {
    if (!std.mem.eql(u8, kind, "every") or fail_streak < 2) return 0;
    const step = std.math.clamp(every_min, 1, EVERY_MIN_MAX) * 60;
    const shift: u6 = @intCast(@min(fail_streak - 1, 4));
    return @min(step << shift, 172800);
}

/// Room the id slug leaves for uniqueness suffixes: 48 + "-MMDDHHMMSS"(11) + a possible "-hhhh" collision
/// suffix (5) = 64, the safeSeg ceiling.
const SLUG_MAX: usize = 48;

/// Mint a task id from its name + a local-time stamp: "daily report!" → "daily-report-0715123456". The slug is
/// lowercased [a-z0-9_], runs of anything else collapse to one '-', clipped to SLUG_MAX; the suffix is
/// MMDDHHMMSS so two same-named tasks minted in different seconds never collide (same-second collisions get a
/// random extra suffix at the create route). Always safeSeg-clean and <= 64 bytes.
pub fn mintTaskId(buf: *[64]u8, name: []const u8, local_secs: i64) []const u8 {
    var n: usize = 0;
    var prev_dash = true; // suppress a leading '-'
    for (name) |ch| {
        if (n >= SLUG_MAX) break;
        const lc = std.ascii.toLower(ch);
        if ((lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9') or lc == '_') {
            buf[n] = lc;
            n += 1;
            prev_dash = false;
        } else if (!prev_dash) {
            buf[n] = '-';
            n += 1;
            prev_dash = true;
        }
    }
    while (n > 0 and buf[n - 1] == '-') n -= 1; // no trailing '-'
    if (n == 0) {
        @memcpy(buf[0..4], "task"); // a name of pure punctuation still yields a usable id
        n = 4;
    }
    const c = civilOf(local_secs);
    const tail = std.fmt.bufPrint(buf[n..], "-{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{ c.mo, c.day, c.hh, c.mi, c.ss }) catch return buf[0..n];
    return buf[0 .. n + tail.len];
}

/// Mint the conversation id for one run: "scheduled_" ++ clipped task id ++ "_MMDDHHMM" (local time, so the
/// conv name in the desk list matches the user's clock). The task id is clipped so the whole id stays <= 64
/// bytes — the safeSeg ceiling every conv route enforces. Digits + the id's own safe charset → safeSeg-clean.
pub fn convIdFor(buf: *[64]u8, task_id: []const u8, local_secs: i64) []const u8 {
    const prefix = "scheduled_";
    const keep = @min(task_id.len, 64 - prefix.len - 9); // "_MMDDHHMM" = 9 bytes
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..keep], task_id[0..keep]);
    const head = prefix.len + keep;
    const c = civilOf(local_secs);
    const tail = std.fmt.bufPrint(buf[head..], "_{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{ c.mo, c.day, c.hh, c.mi }) catch return buf[0..head];
    return buf[0 .. head + tail.len];
}

// ---- storage: one JSON file per task under {data}/u{uid}/_sched/ --------------------------------------------

// Serializes every read-modify-write of a task file across the scheduler thread + the httpz handler threads
// (tick re-anchoring next_due vs a POST update racing it would lost-update the file). Same process-wide-mutex
// shape as http.append_mtx: each critical section is a few file ops, so contention is negligible.
var sched_mtx: std.Io.Mutex = .init;

/// Serialize `t` as one flat JSON object in the wire-contract field order. `redact_key` is the HTTP path: the
/// stored api_key NEVER leaves the server — every response carries "api_key":"".
pub fn encodeTask(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), t: Task, redact_key: bool) !void {
    var nb: [200]u8 = undefined;
    try out.appendSlice(gpa, "{\"id\":");
    try http.jstr(gpa, out, t.id);
    try out.appendSlice(gpa, ",\"name\":");
    try http.jstr(gpa, out, t.name);
    try out.appendSlice(gpa, ",\"prompt\":");
    try http.jstr(gpa, out, t.prompt);
    try out.appendSlice(gpa, ",\"details\":");
    try http.jstr(gpa, out, t.details);
    try out.appendSlice(gpa, ",\"kind\":");
    try http.jstr(gpa, out, t.kind);
    try out.appendSlice(gpa, std.fmt.bufPrint(&nb, ",\"at\":{d},\"every_min\":{d}", .{ t.at, t.every_min }) catch return error.NoSpaceLeft);
    try out.appendSlice(gpa, ",\"hm\":");
    try http.jstr(gpa, out, t.hm);
    try out.appendSlice(gpa, if (t.enabled) ",\"enabled\":true" else ",\"enabled\":false");
    try out.appendSlice(gpa, std.fmt.bufPrint(&nb, ",\"created\":{d},\"last_run\":{d},\"next_due\":{d}", .{ t.created, t.last_run, t.next_due }) catch return error.NoSpaceLeft);
    try out.appendSlice(gpa, ",\"last_conv\":");
    try http.jstr(gpa, out, t.last_conv);
    try out.appendSlice(gpa, ",\"recent_convs\":");
    try http.jstr(gpa, out, t.recent_convs);
    try out.appendSlice(gpa, std.fmt.bufPrint(&nb, ",\"runs\":{d}", .{t.runs}) catch return error.NoSpaceLeft);
    try out.appendSlice(gpa, ",\"last_status\":");
    try http.jstr(gpa, out, t.last_status);
    try out.appendSlice(gpa, std.fmt.bufPrint(&nb, ",\"fail_streak\":{d},\"revisions\":{d}", .{ t.fail_streak, t.revisions }) catch return error.NoSpaceLeft);
    try out.appendSlice(gpa, ",\"base_url\":");
    try http.jstr(gpa, out, t.base_url);
    try out.appendSlice(gpa, ",\"model\":");
    try http.jstr(gpa, out, t.model);
    try out.appendSlice(gpa, ",\"api_key\":");
    try http.jstr(gpa, out, if (redact_key) "" else t.api_key);
    try out.appendSlice(gpa, ",\"think_base_url\":");
    try http.jstr(gpa, out, t.think_base_url);
    try out.appendSlice(gpa, ",\"think_model\":");
    try http.jstr(gpa, out, t.think_model);
    try out.appendSlice(gpa, ",\"think_api_key\":");
    try http.jstr(gpa, out, if (redact_key) "" else t.think_api_key);
    try out.appendSlice(gpa, ",\"prompt_base_url\":");
    try http.jstr(gpa, out, t.prompt_base_url);
    try out.appendSlice(gpa, ",\"prompt_model\":");
    try http.jstr(gpa, out, t.prompt_model);
    try out.appendSlice(gpa, ",\"prompt_api_key\":");
    try http.jstr(gpa, out, if (redact_key) "" else t.prompt_api_key);
    try out.append(gpa, '}');
}

/// Read + parse one task file. All strings land in `alloc` (callers pass an arena — res.arena on a handler, a
/// per-tick arena on the scheduler thread), so nothing here needs freeing. Returns null on any trouble: a
/// missing/corrupt file is a skipped task, never a crash. The FILENAME is the canonical id — the body's id
/// field is overwritten so a hand-edited body can never redirect a save onto another task's file.
fn loadTask(app: *App, alloc: std.mem.Allocator, uid: u64, id: []const u8) ?Task {
    const path = std.fmt.allocPrint(alloc, "{s}/u{d}/_sched/{s}.json", .{ app.data, uid, id }) catch return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, path, alloc, .limited(512 << 10)) catch return null;
    var t = std.json.parseFromSliceLeaky(Task, alloc, raw, .{ .ignore_unknown_fields = true }) catch return null;
    t.id = alloc.dupe(u8, id) catch return null;
    // An unknown kind (hand-edit) normalizes to "once" — the SELF-DISABLING kind, so a garbled file fires at
    // most one run instead of looping. "every"/"daily" would re-arm forever.
    if (!validKind(t.kind)) t.kind = "once";
    return t;
}

/// Whole-file write, atomic-ish: the new body lands beside the live file then renames over it, so a concurrent
/// reader (tick on the scheduler thread vs a handler on an httpz thread) sees the old task or the new one,
/// never a torn half-write. A rename refused by a Windows sharing window degrades to a direct overwrite —
/// losing the update would be worse than a torn read the next load skips.
fn saveTask(app: *App, alloc: std.mem.Allocator, uid: u64, t: Task) bool {
    const dir = std.fmt.allocPrint(alloc, "{s}/u{d}/_sched", .{ app.data, uid }) catch return false;
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, dir, .default_dir) catch {};
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(app.gpa);
    encodeTask(app.gpa, &body, t, false) catch return false; // DISK copy keeps the real api_key
    const path = std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, t.id }) catch return false;
    const tmp = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return false;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = tmp, .data = body.items }) catch return false;
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, app.io) catch {
        std.Io.Dir.cwd().deleteFile(app.io, tmp) catch {};
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = body.items }) catch return false;
    };
    return true;
}

// ---- in-process create/list/delete (the chat veil's schedule_* tools; shared with the HTTP handlers) ---------

/// The create fields, exactly as POST /api/v1/sched takes them.
pub const CreateSpec = struct {
    name: []const u8 = "",
    prompt: []const u8 = "",
    details: []const u8 = "",
    kind: []const u8 = "once",
    at: i64 = 0,
    every_min: i64 = 0,
    hm: []const u8 = "",
    enabled: bool = true,
    base_url: []const u8 = "",
    model: []const u8 = "",
    api_key: []const u8 = "",
    // MODEL TRIO (optional): per-role overrides carried from the creating turn; empty ⇒ fall back to base.
    think_base_url: []const u8 = "",
    think_model: []const u8 = "",
    think_api_key: []const u8 = "",
    prompt_base_url: []const u8 = "",
    prompt_model: []const u8 = "",
    prompt_api_key: []const u8 = "",
};

pub const CreateResult = union(enum) { id: []const u8, err: []const u8 };

/// Validate + mint + persist one task. The single create path: the HTTP route and the chat veil's
/// schedule_task tool both land here, so a task can never enter the tick loop with a shape only one of them
/// validated. `.id` is duped into `alloc`; `.err` is a static string.
pub fn createFromSpec(app: *App, alloc: std.mem.Allocator, uid: u64, s: CreateSpec) CreateResult {
    const name = std.mem.trim(u8, s.name, " \r\n\t");
    const prompt = std.mem.trim(u8, s.prompt, " \r\n\t");
    if (name.len == 0) return .{ .err = "name is required" };
    if (prompt.len == 0) return .{ .err = "prompt is required" };
    if (!validKind(s.kind)) return .{ .err = "kind must be \"once\", \"every\", or \"daily\"" };
    // ceiling as well as floor: every_min rides i64 math (every_min * 60) in computeNextDue — an absurd value
    // from the API/tool would overflow the tick loop's arithmetic (a crash on every scheduler pass, forever).
    if (std.mem.eql(u8, s.kind, "every") and (s.every_min < 1 or s.every_min > EVERY_MIN_MAX)) return .{ .err = "every_min must be between 1 and 527040 (one year)" };
    if (std.mem.eql(u8, s.kind, "daily") and parseHm(s.hm) == null) return .{ .err = "hm must be \"HH:MM\"" };

    const now = nowSecs(app.io);
    var idb: [64]u8 = undefined;
    var id = mintTaskId(&idb, name, now + localOffsetSecs());
    var idb2: [64]u8 = undefined;
    // Collision probe + save under ONE lock hold: probing outside it was a TOCTOU — two same-second creates
    // with the same slug both saw "no file", both minted the same id, and the second silently overwrote the
    // first (the exact loss the random suffix exists to prevent).
    sched_mtx.lockUncancelable(app.io);
    defer sched_mtx.unlock(app.io);
    {
        const existing = std.fmt.allocPrint(alloc, "{s}/u{d}/_sched/{s}.json", .{ app.data, uid, id }) catch null;
        if (existing) |p| {
            if (std.Io.Dir.cwd().access(app.io, p, .{})) |_| {
                var r: [2]u8 = undefined;
                app.io.random(&r);
                id = std.fmt.bufPrint(&idb2, "{s}-{s}", .{ id, std.fmt.bytesToHex(r, .lower) }) catch id;
            } else |_| {}
        }
    }
    const t = Task{
        .id = id,
        .name = name,
        .prompt = prompt,
        .details = s.details,
        .kind = s.kind,
        .at = s.at,
        .every_min = s.every_min,
        .hm = s.hm,
        .enabled = s.enabled,
        .created = now,
        .last_run = 0,
        .next_due = computeNextDue(s.kind, s.at, s.every_min, s.hm, now, 0, now, localOffsetSecs()),
        .last_conv = "",
        .runs = 0,
        .base_url = s.base_url,
        .model = s.model,
        .api_key = s.api_key,
        .think_base_url = s.think_base_url,
        .think_model = s.think_model,
        .think_api_key = s.think_api_key,
        .prompt_base_url = s.prompt_base_url,
        .prompt_model = s.prompt_model,
        .prompt_api_key = s.prompt_api_key,
    };
    if (!saveTask(app, alloc, uid, t)) return .{ .err = "could not write the task file" };
    // The task's PERMANENT working directory, created up front so it exists (and is browsable) before the
    // first run: {data}/u{uid}/_sched/{id}/runs/ — each run adds its own timestamped subdir under runs/.
    // The tick/list loops only look at *.json FILES in _sched/, so the directory is inert to scheduling.
    {
        var db: [512]u8 = undefined;
        if (std.fmt.bufPrint(&db, "{s}/u{d}/_sched/{s}/runs", .{ app.data, uid, id })) |wd| {
            _ = std.Io.Dir.cwd().createDirPathStatus(app.io, wd, .default_dir) catch {};
        } else |_| {}
    }
    return .{ .id = alloc.dupe(u8, id) catch return .{ .err = "out of memory" } };
}

/// A partial update: null = keep the stored value, non-null = replace it. The single update shape BOTH revisers
/// share — the HTTP route (human/desk edits) and the chat veil's schedule_update tool (the task revising
/// ITSELF mid-run, or the veil revising it from conversation). The tool never passes the provider triple
/// (base_url/model/api_key): a self-improving task must not be able to redirect its own credentials.
pub const UpdateSpec = struct {
    name: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    details: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    at: ?i64 = null,
    every_min: ?i64 = null,
    hm: ?[]const u8 = null,
    enabled: ?bool = null,
    base_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

/// Apply the present fields of `s` onto `t` and validate the FINAL shape (not just the touched fields —
/// switching kind to "daily" must fail unless a parseable hm is stored, from this update or an earlier one).
/// Returns a static error string, or null on success. `sched_changed` = a schedule field (kind/at/every_min/hm)
/// was present (next_due must be recomputed); `content_changed` = the task's substance (name/prompt/details)
/// changed (counts as a revision). Pure — string fields alias `s`, so the caller's allocation outlives the save.
pub fn applySpecToTask(t: *Task, s: UpdateSpec, sched_changed: *bool, content_changed: *bool) ?[]const u8 {
    if (s.name) |v| {
        const tv = std.mem.trim(u8, v, " \r\n\t");
        if (tv.len == 0) return "name must be a non-empty string";
        t.name = tv;
        content_changed.* = true;
    }
    if (s.prompt) |v| {
        const tv = std.mem.trim(u8, v, " \r\n\t");
        if (tv.len == 0) return "prompt must be a non-empty string";
        t.prompt = tv;
        content_changed.* = true;
    }
    if (s.details) |v| {
        t.details = v;
        content_changed.* = true;
    }
    if (s.kind) |v| {
        if (!validKind(v)) return "kind must be \"once\", \"every\", or \"daily\"";
        t.kind = v;
        sched_changed.* = true;
    }
    if (s.at) |v| {
        t.at = v;
        sched_changed.* = true;
    }
    if (s.every_min) |v| {
        t.every_min = v;
        sched_changed.* = true;
    }
    if (s.hm) |v| {
        t.hm = v;
        sched_changed.* = true;
    }
    if (s.enabled) |v| t.enabled = v;
    if (s.base_url) |v| t.base_url = v;
    if (s.model) |v| t.model = v;
    if (s.api_key) |v| t.api_key = v;
    if (std.mem.eql(u8, t.kind, "every") and (t.every_min < 1 or t.every_min > EVERY_MIN_MAX)) return "every_min must be between 1 and 527040 (one year) for kind \"every\"";
    if (std.mem.eql(u8, t.kind, "daily") and parseHm(t.hm) == null) return "hm must be \"HH:MM\" for kind \"daily\"";
    return null;
}

pub const UpdateResult = union(enum) { ok: void, not_found: void, err: []const u8 };

/// Validate + apply + persist one partial update — THE single update path (HTTP route and schedule_update tool
/// both land here, mirroring createFromSpec's one-create-path rule). Holds sched_mtx across load-apply-save so
/// a tick's bookkeeping can never interleave. next_due is recomputed only when a schedule field was present (an
/// unrelated rename must not re-anchor a running interval); a content or schedule change counts one revision.
pub fn updateById(app: *App, alloc: std.mem.Allocator, uid: u64, id: []const u8, s: UpdateSpec) UpdateResult {
    const seg = safeSeg(id);
    if (seg.len == 0) return .not_found;
    sched_mtx.lockUncancelable(app.io);
    defer sched_mtx.unlock(app.io);
    var t = loadTask(app, alloc, uid, seg) orelse return .not_found;
    var sched_changed = false;
    var content_changed = false;
    if (applySpecToTask(&t, s, &sched_changed, &content_changed)) |e| return .{ .err = e };
    if (sched_changed)
        t.next_due = computeNextDue(t.kind, t.at, t.every_min, t.hm, t.created, t.last_run, nowSecs(app.io), localOffsetSecs());
    if (content_changed or sched_changed) t.revisions += 1;
    if (!saveTask(app, alloc, uid, t)) return .{ .err = "could not write the task file" };
    return .ok;
}

/// One compact human line per task ("id | name | kind ... | next due in Nm | runs N | enabled") — the chat
/// veil's schedule_list result. gpa-owned; empty string when none exist.
pub fn listBrief(app: *App, gpa: std.mem.Allocator, uid: u64) []u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const now = nowSecs(app.io);
    const sd = std.fmt.allocPrint(arena, "{s}/u{d}/_sched", .{ app.data, uid }) catch return gpa.dupe(u8, "") catch @constCast("");
    if (std.Io.Dir.cwd().openDir(app.io, sd, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue;
            const id = safeSeg(ent.name[0 .. ent.name.len - 5]);
            if (id.len == 0) continue;
            const id_dup = arena.dupe(u8, id) catch continue;
            const t = loadTask(app, arena, uid, id_dup) orelse continue;
            const due_min = @divFloor(t.next_due - now, 60);
            out.print(gpa, "{s} | {s} | {s}", .{ t.id, t.name, t.kind }) catch break;
            if (std.mem.eql(u8, t.kind, "every")) out.print(gpa, " {d}min", .{t.every_min}) catch {};
            if (std.mem.eql(u8, t.kind, "daily")) out.print(gpa, " at {s}", .{t.hm}) catch {};
            out.print(gpa, " | next due in {d}m | runs {d} | {s}", .{ due_min, t.runs, if (t.enabled) "enabled" else "disabled" }) catch break;
            // Health surfaces where the veil actually looks: a sick task is visible (and fixable via
            // schedule_update) from any chat, not only from inside its own runs.
            if (t.fail_streak > 0) out.print(gpa, " | FAILING x{d}", .{t.fail_streak}) catch {};
            if (t.revisions > 0) out.print(gpa, " | self-tuned x{d}", .{t.revisions}) catch {};
            out.append(gpa, '\n') catch break;
        }
    } else |_| {}
    return gpa.dupe(u8, out.items) catch @constCast("");
}

/// Delete one task by id (in-process twin of the DELETE route). false = no such task / unsafe id.
pub fn deleteById(app: *App, alloc: std.mem.Allocator, uid: u64, id: []const u8) bool {
    const seg = safeSeg(id);
    if (seg.len == 0) return false;
    const path = std.fmt.allocPrint(alloc, "{s}/u{d}/_sched/{s}.json", .{ app.data, uid, seg }) catch return false;
    std.Io.Dir.cwd().access(app.io, path, .{}) catch return false;
    sched_mtx.lockUncancelable(app.io);
    defer sched_mtx.unlock(app.io);
    std.Io.Dir.cwd().deleteFile(app.io, path) catch return false;
    return true;
}

// ---- run outcome ledger + composing one run's first message -------------------------------------------------

/// Record how a run ENDED onto the task file — the engine's ground-truth outcome ledger, written from the chat
/// engine's completion paths (never from model text). ok resets fail_streak; a failure increments it, and from
/// the second consecutive failure pushes next_due out by failBackoffSecs (never pulled earlier — @max) so an
/// unattended task that keeps dying retries at declining cost. The note lands verbatim (clipped) in last_status,
/// where the NEXT run's RUN CONTEXT block and the desk's task list can see it. Returns the new streak.
/// Self-contained (own arena, takes the sched lock) — callable from any engine thread at turn end.
pub fn recordRunOutcome(app: *App, uid: u64, id: []const u8, ok: bool, note: []const u8) i64 {
    const seg = safeSeg(id);
    if (seg.len == 0) return 0;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const now = nowSecs(app.io);
    sched_mtx.lockUncancelable(app.io);
    defer sched_mtx.unlock(app.io);
    var t = loadTask(app, alloc, uid, seg) orelse return 0;
    t.last_status = note[0..@min(note.len, 160)]; // engine-authored ASCII one-liners; the clip keeps the file tiny
    t.fail_streak = if (ok) 0 else t.fail_streak + 1;
    if (!ok) {
        const backoff = failBackoffSecs(t.kind, t.every_min, t.fail_streak);
        if (backoff > 0) t.next_due = @max(t.next_due, now + backoff);
    }
    _ = saveTask(app, alloc, uid, t);
    return t.fail_streak;
}

/// Compose one run's FIRST MESSAGE: the prompt, the pinned details, then an engine-authored RUN CONTEXT block —
/// the task's own id, run number, cadence, the previous run's recorded outcome, this run's PERMANENT working
/// directory (when the caller resolved one), a SELF-HEAL directive when the task is failing, and the standing
/// self-improvement contract (revise yourself via schedule_update). The id is what makes self-revision
/// DETERMINISTIC: without it the run would have to fish its own identity out of schedule_list by name.
/// `run_rel` is the data-relative run root ("u1/_sched/{task}/runs/{stamp}") or "" to omit the workdir block.
/// gpa-owned; null only on OOM. Pure of I/O — unit-tested below.
pub fn buildRunMessage(gpa: std.mem.Allocator, t: *const Task, run_rel: []const u8) ?[]u8 {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    const fail = build: {
        text.appendSlice(gpa, t.prompt) catch break :build true;
        const det = std.mem.trim(u8, t.details, " \r\n\t");
        if (det.len > 0) {
            text.appendSlice(gpa, "\n\nKey details / data to use:\n") catch break :build true;
            text.appendSlice(gpa, det) catch break :build true;
        }
        text.appendSlice(gpa, "\n\n--- SCHEDULED RUN CONTEXT (engine-authored) ---\n") catch break :build true;
        text.print(gpa, "This is run #{d} of scheduled task \"{s}\" — its id is \"{s}\" (", .{ t.runs + 1, t.name, t.id }) catch break :build true;
        if (std.mem.eql(u8, t.kind, "every"))
            text.print(gpa, "runs every {d} min", .{t.every_min}) catch break :build true
        else if (std.mem.eql(u8, t.kind, "daily"))
            text.print(gpa, "runs daily at {s}", .{t.hm}) catch break :build true
        else
            text.appendSlice(gpa, "one-shot") catch break :build true;
        text.appendSlice(gpa, ").\n") catch break :build true;
        const st = std.mem.trim(u8, t.last_status, " \r\n\t");
        if (st.len > 0) text.print(gpa, "Previous run outcome: {s}\n", .{st}) catch break :build true;
        if (run_rel.len > 0) {
            // The permanent task dir is the run root minus its "/runs/{stamp}" tail.
            const task_rel = if (std.mem.lastIndexOf(u8, run_rel, "/runs/")) |i| run_rel[0..i] else run_rel;
            text.print(gpa, "WORKDIR (permanent): this run's files land in \"{s}/work\" under the server data dir and are KEPT after the run — every run of this task gets its own timestamped folder under \"{s}/runs/\". Save anything worth keeping (reports, collected data, scripts, logs) as FILES via write_file; also record reusable knowledge with observe, because later runs read the task memory, not this folder.\n", .{ run_rel, task_rel }) catch break :build true;
        }
        if (t.fail_streak > 0)
            text.print(gpa, "SELF-HEAL FIRST: the last {d} run(s) of this task FAILED in a row. Before working the task, diagnose and FIX the cause — verify inputs, tools, and approach; simplify whatever keeps breaking — and record what you fixed with observe so the repair sticks.\n", .{t.fail_streak}) catch break :build true;
        text.appendSlice(gpa, "STANDING DIRECTIVE — this task must be SELF-HEALING and SELF-IMPROVING across runs: " ++
            "fix any error or warning this run surfaces instead of merely reporting it; reuse what TASK MEMORY says worked and skip its recorded pitfalls; " ++
            "and when the task DEFINITION itself should change — a clearer prompt, sharper details, a saner cadence, pausing when obsolete — apply that yourself by calling schedule_update with id \"") catch break :build true;
        text.appendSlice(gpa, t.id) catch break :build true;
        text.appendSlice(gpa, "\" and a short reason. Improvements must preserve this task's goal.") catch break :build true;
        break :build false;
    };
    if (fail) return null;
    return text.toOwnedSlice(gpa) catch null;
}

// ---- provider resolution + launching one run ----------------------------------------------------------------

const Provider = struct { base: []const u8, key: []const u8, model: []const u8 };

/// Fill BLANK provider fields with the same defaults /api/v1/cast resolves when a request leaves them out
/// (deploySwarm's default-provider path, mirrored): no key AND no base → the server's own configured inference
/// backbone (account URL + token + its default model when none/mismatched is stored), else the user's stored
/// key for that default provider. An explicit base or key on the task is respected verbatim — same rule that
/// keeps a cast from silently redirecting a custom endpoint's traffic to the wrong host with the wrong creds.
fn resolveProvider(app: *App, alloc: std.mem.Allocator, uid: u64, t: *const Task) Provider {
    var base = t.base_url;
    var key = t.api_key;
    var model = t.model;
    if (key.len == 0 and base.len == 0) {
        if (app.cf_account_id.len > 0 and app.workers_ai_token.len > 0) {
            base = std.fmt.allocPrint(alloc, "https://api.cloudflare.com/client/v4/accounts/{s}/ai/v1", .{app.cf_account_id}) catch t.base_url;
            key = app.workers_ai_token;
            if (model.len == 0 or !std.mem.startsWith(u8, model, "@cf/")) model = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
        } else if (app.vault.resolve(uid, "workers-ai", alloc)) |rk| {
            key = rk.key;
            if (rk.base_url.len > 0) base = rk.base_url;
        }
        // Neither configured → pass the blanks through; the turn surfaces the provider failure as an error
        // event INSIDE the minted conversation, where the user can actually see why the schedule produced
        // nothing (a silent skip here would look like the scheduler never fired).
    }
    return .{ .base = base, .key = key, .model = model };
}

/// Fire one run of `t` NOW: mint the conv id, compose the first message, resolve the provider, claim the
/// per-conv turn slot, spawn the turn, and persist the run bookkeeping (last_run/runs/last_conv/next_due;
/// "once" disables itself). Shared verbatim by the due-task tick and the POST :id/run route — "run now" IS a
/// scheduled run, just with a caller-chosen due time.
///
/// Returns the conv id (duped into `alloc`) or null when the turn could not start (that conv already has a
/// live turn, or all 16 turn slots are busy). On null NOTHING is persisted — the task stays due and the next
/// tick retries, so a busy engine delays a schedule rather than eating a run.
///
/// LOCKING: callers must NOT hold sched_mtx here. The spawn path can degrade to running the turn INLINE on
/// this thread (spawnTurn's alloc-failure fallback), and a turn's model may call schedule_task — which takes
/// sched_mtx. Held across the spawn, that is a self-deadlock on a non-reentrant mutex. launchRun instead
/// takes the lock only around its own bookkeeping, RE-LOADING the task fresh so a concurrent update between
/// the caller's read and the save is never clobbered.
fn launchRun(app: *App, alloc: std.mem.Allocator, uid: u64, t: *Task, now: i64) ?[]const u8 {
    var cb: [64]u8 = undefined;
    const conv = convIdFor(&cb, t.id, now + localOffsetSecs());

    // The run's PERMANENT working directory: every resolver maps this conv into the task's own tree
    // ({data}/u{uid}/_sched/{task}/runs/{stamp} — paths.zig), so create it now and tell the run about it.
    // Creation failure is non-fatal: the engine's own createDirPathStatus retries on first tool use.
    var rb: [256]u8 = undefined;
    const run_rel = cpaths.buildRootRel(&rb, uid, conv);
    if (run_rel.len > 0) {
        var ab: [512]u8 = undefined;
        if (std.fmt.bufPrint(&ab, "{s}/{s}/work", .{ app.data, run_rel })) |wd| {
            _ = std.Io.Dir.cwd().createDirPathStatus(app.io, wd, .default_dir) catch {};
        } else |_| {}
    }

    // First message = the prompt + pinned details + the engine-authored RUN CONTEXT (buildRunMessage): the run
    // knows its OWN task id, run number, cadence, the previous run's recorded outcome, and its permanent
    // per-run workdir — the mechanical ground the self-heal/self-improve loop stands on (schedule_update needs
    // the id; repair posture needs the outcome). Each minted conversation stays self-contained: everything the
    // run may know about its task is IN the message. The run fires with the AUTO-LOOP ARMED (loop=1 below), so
    // the drive loop carries it through ambiguity to a completed deliverable, and the engine injects the task's
    // memory (recall) + records outcomes/lessons (see runTurn's sched branches) — autonomy and learning are
    // ENGINE mechanics.
    const text = buildRunMessage(app.gpa, t, run_rel) orelse return null;
    defer app.gpa.free(text);

    const pr = resolveProvider(app, alloc, uid, t);
    // The run's model trio: coding/base is the blank-filled provider above; thinking/prompting come straight
    // from the task (empty ⇒ ModelTrio.pick falls back to coding, so an old single-model task is unchanged).
    // This is how an unattended run's auto-loop drive + planning honor the trio the creating turn picked.
    const trio: chat_engine.ModelTrio = .{
        .coding = .{ .base_url = pr.base, .key = pr.key, .model = pr.model },
        .thinking = .{ .base_url = t.think_base_url, .key = t.think_api_key, .model = t.think_model },
        .prompting = .{ .base_url = t.prompt_base_url, .key = t.prompt_api_key, .model = t.prompt_model },
    };

    // Claim-before-spawn, exactly like postMessage: a `false` here means a same-named run from this minute is
    // still going, or the engine is saturated — skip WITHOUT bookkeeping so the task fires on a later tick.
    if (!chat_engine.tryBeginTurn(app.io, conv)) return null;
    // loop=1 (AUTO-LOOP ON): autonomy IS the point of a scheduled run — the drive loop pushes through
    // ambiguity, waits out any hive it casts, runs the terminal build-verify, and only settles on a genuine
    // DONE (bounded by LOOP_MAX_STEPS, so a stuck task ends instead of burning forever). Never afk: an
    // unattended run must terminate on its own. spawnTurn copies every arg into its own blob (conv lives in
    // a stack buffer here) and owns releasing the turn slot on every completion path.
    chat_engine.spawnTurn(app, uid, conv, trio, text, 1, false); // tool_client=false: a scheduled run executes tools server-side (no client attached)

    // Bookkeeping AFTER the spawn is committed, under the sched lock with a FRESH re-load: a concurrent
    // update (rename, toggle, prompt edit) between the caller's read and this save must not be clobbered by
    // our stale copy. last_run = now first, so the "every" recompute re-anchors the interval to NOW (the
    // catch-up policy: an overdue task runs once, never once per missed interval).
    {
        sched_mtx.lockUncancelable(app.io);
        defer sched_mtx.unlock(app.io);
        var fresh = loadTask(app, alloc, uid, t.id) orelse t.*;
        fresh.last_run = now;
        fresh.runs += 1;
        fresh.last_conv = alloc.dupe(u8, conv) catch fresh.last_conv;
        fresh.recent_convs = joinRecent(alloc, fresh.last_conv, fresh.recent_convs); // history: newest first, capped
        fresh.next_due = computeNextDue(fresh.kind, fresh.at, fresh.every_min, fresh.hm, fresh.created, fresh.last_run, now, localOffsetSecs());
        if (std.mem.eql(u8, fresh.kind, "once")) fresh.enabled = false; // a one-shot consumed itself
        _ = saveTask(app, alloc, uid, fresh); // a failed save can double-fire later — visible + recoverable, unlike a lost run
        t.* = fresh;
    }
    return alloc.dupe(u8, conv) catch null;
}

// ---- the scheduler thread -----------------------------------------------------------------------------------

/// Mirror of postMessage's kill switch: VEIL_CHAT_BACKEND=0 disables the served chat turn, and a scheduled run
/// IS a served chat turn — so the scheduler idles under the same switch instead of spawning turns the message
/// route would refuse.
fn backendDisabled(app: *App) bool {
    const env = app.sup.parent_env orelse return false;
    const v = env.get("VEIL_CHAT_BACKEND") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, v, " \r\n\t"), "0");
}

/// One scheduler pass: scan every user's `_sched/` dir and fire each enabled task whose next_due has arrived.
/// Called from the dedicated scheduler thread only (never an httpz request thread — a due task spawns a turn,
/// and even the spawn bookkeeping shouldn't ride a request's latency).
pub fn tick(app: *App) void {
    if (backendDisabled(app)) return;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const now = nowSecs(app.io);

    // {data}/u{uid}/... — uid parsed from the dir name, same layout every chat/build path uses.
    var root = std.Io.Dir.cwd().openDir(app.io, app.data, .{ .iterate = true }) catch return;
    defer root.close(app.io);
    var it = root.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        if (ent.name.len < 2 or ent.name[0] != 'u') continue;
        const uid = std.fmt.parseInt(u64, ent.name[1..], 10) catch continue; // "u123" only; anything else isn't a user dir
        // ADMIN-ONLY, mirroring postMessage: the served turn hands the model the full tool surface, so a task
        // file owned by a non-admin (there shouldn't be one — the routes are gated — but files are just files)
        // must not become a privilege escalation that runs admin tools on a schedule.
        const owner = app.auth.userById(uid) orelse continue;
        if (!app.auth.isAdmin(owner)) continue;
        tickUser(app, arena, uid, now);
    }
}

fn tickUser(app: *App, arena: std.mem.Allocator, uid: u64, now: i64) void {
    const sd = std.fmt.allocPrint(arena, "{s}/u{d}/_sched", .{ app.data, uid }) catch return;
    var dir = std.Io.Dir.cwd().openDir(app.io, sd, .{ .iterate = true }) catch return; // no _sched yet → nothing scheduled
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue; // skips .tmp mid-save files too
        const id = safeSeg(ent.name[0 .. ent.name.len - 5]);
        if (id.len == 0) continue; // stray/unsafe filename — never surface it into a conv id
        const id_dup = arena.dupe(u8, id) catch continue; // ent.name is only valid for this iteration step
        // Read the task + due-check under the lock, then RELEASE before launching: launchRun must never run
        // under sched_mtx (its spawn can degrade to an inline turn whose model calls schedule_task — a
        // self-deadlock; see launchRun's LOCKING note). A racing run-now in the same minute is benign:
        // both mint the same conv id and tryBeginTurn lets exactly one spawn.
        var due: ?Task = null;
        {
            sched_mtx.lockUncancelable(app.io);
            defer sched_mtx.unlock(app.io);
            const t = loadTask(app, arena, uid, id_dup) orelse continue;
            if (t.enabled and t.next_due <= now) due = t;
        }
        var t = due orelse continue;
        _ = launchRun(app, arena, uid, &t, now); // null = engine busy → task stays due, next tick retries
    }
}

/// Scheduler thread body — the second background thread beside Supervisor.bgLoop, same ~5s cadence in 100ms
/// slices (a raw-thread sleep; see threadSleepMs). Runs for the life of the process: there is no stop flag
/// because there is nothing to hand off — a mid-tick shutdown at worst delays a task to the next boot's
/// catch-up pass, which the overdue policy already handles.
pub fn bgLoop(app: *App) void {
    while (true) {
        tick(app);
        var slept: usize = 0;
        while (slept < 50) : (slept += 1) threadSleepMs(app.io, 100);
    }
}

// ---- REST handlers (registered in main.zig beside the chat routes) ------------------------------------------

/// requireUser + admin, replying 403 like postMessage (NOT requireAdmin's 401 — the desk distinguishes "log
/// in" from "not allowed"). Every sched route is admin-gated for the same reason postMessage is: the turn a
/// task fires carries the full tool surface.
fn gate(app: *App, req: *httpz.Request, res: *httpz.Response) ?http.User {
    const u = http.requireUser(app, req, res) orelse return null;
    if (!app.auth.isAdmin(u)) {
        res.status = 403;
        res.json(.{ .ok = false, .err = "scheduled tasks are admin-only for now" }, .{}) catch {};
        return null;
    }
    return u;
}

/// GET /api/v1/sched — every task this user owns, api_key redacted. Reads WITHOUT the sched lock: saves are
/// rename-atomic, so the worst case is one unparseable mid-rename file this poll, which loadTask skips.
pub fn listTasks(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const root = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_sched", .{ app.data, u.id });
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(app.gpa);
    try arr.appendSlice(app.gpa, "{\"ok\":true,\"tasks\":[");
    if (std.Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(app.io);
        var it = dir.iterate();
        var n: usize = 0;
        while (it.next(app.io) catch null) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".json")) continue;
            const id = safeSeg(ent.name[0 .. ent.name.len - 5]);
            if (id.len == 0) continue;
            const t = loadTask(app, res.arena, u.id, id) orelse continue;
            if (n > 0) try arr.append(app.gpa, ',');
            try encodeTask(app.gpa, &arr, t, true); // REDACTED: the key never rides an HTTP response
            n += 1;
        }
    } else |_| {} // no _sched dir yet → empty list, never an error
    try arr.appendSlice(app.gpa, "]}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, arr.items);
}

/// POST /api/v1/sched — create a task. Validates the schedule shape up front (name+prompt required; every_min
/// >= 1 for "every"; hm must parse for "daily") so a bad task can never reach the tick loop, then mints the id
/// from the name + a local-time stamp and computes the first next_due.
pub fn createTask(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const Body = struct {
        name: []const u8 = "",
        prompt: []const u8 = "",
        details: []const u8 = "",
        kind: []const u8 = "once",
        at: i64 = 0,
        every_min: i64 = 0,
        hm: []const u8 = "",
        enabled: bool = true,
        base_url: []const u8 = "",
        model: []const u8 = "",
        api_key: []const u8 = "",
        // MODEL TRIO (optional): the desk's Tasks form / a raw API client may send per-role overrides so the
        // task's unattended runs use the same trio. Absent ⇒ empty ⇒ each role falls back to base at run time.
        think_base_url: []const u8 = "",
        think_model: []const u8 = "",
        think_api_key: []const u8 = "",
        prompt_base_url: []const u8 = "",
        prompt_model: []const u8 = "",
        prompt_api_key: []const u8 = "",
    };
    const b = (try req.json(Body)) orelse return badReq(res, "bad body");
    // ONE create path: the same createFromSpec the chat veil's schedule_task tool calls — identical
    // validation, id minting (with the same-second collision suffix), and persisted shape.
    switch (createFromSpec(app, res.arena, u.id, .{
        .name = b.name,
        .prompt = b.prompt,
        .details = b.details,
        .kind = b.kind,
        .at = b.at,
        .every_min = b.every_min,
        .hm = b.hm,
        .enabled = b.enabled,
        .base_url = b.base_url,
        .model = b.model,
        .api_key = b.api_key,
        .think_base_url = b.think_base_url,
        .think_model = b.think_model,
        .think_api_key = b.think_api_key,
        .prompt_base_url = b.prompt_base_url,
        .prompt_model = b.prompt_model,
        .prompt_api_key = b.prompt_api_key,
    })) {
        .id => |id| {
            res.status = 201;
            try res.json(.{ .ok = true, .id = id }, .{});
        },
        .err => |e| return badReq(res, e),
    }
}

/// POST /api/v1/sched/:id — partial update: any subset of the create fields (+ enabled). Parsed as a generic
/// JSON object so ABSENT means "keep" (a typed struct's defaults can't tell "" apart from not-sent); the route
/// type-checks each present field into an UpdateSpec and updateById — the ONE update path this route shares
/// with the chat veil's schedule_update tool — validates the final shape, recomputes next_due only when a
/// schedule field was sent (an unrelated rename must not re-anchor a running interval), and persists.
pub fn updateTask(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);
    const body = req.body() orelse return badReq(res, "bad body");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, res.arena, body, .{}) catch return badReq(res, "bad body");
    const obj = switch (parsed) {
        .object => |o| o,
        else => return badReq(res, "bad body"),
    };

    var s = UpdateSpec{};
    if (obj.get("name")) |v| {
        if (v != .string) return badReq(res, "name must be a non-empty string");
        s.name = v.string;
    }
    if (obj.get("prompt")) |v| {
        if (v != .string) return badReq(res, "prompt must be a non-empty string");
        s.prompt = v.string;
    }
    if (obj.get("details")) |v| {
        if (v != .string) return badReq(res, "details must be a string");
        s.details = v.string;
    }
    if (obj.get("kind")) |v| {
        if (v != .string) return badReq(res, "kind must be \"once\", \"every\", or \"daily\"");
        s.kind = v.string;
    }
    if (obj.get("at")) |v| {
        if (v != .integer) return badReq(res, "at must be an epoch-seconds integer");
        s.at = v.integer;
    }
    if (obj.get("every_min")) |v| {
        if (v != .integer) return badReq(res, "every_min must be an integer");
        s.every_min = v.integer;
    }
    if (obj.get("hm")) |v| {
        if (v != .string) return badReq(res, "hm must be \"HH:MM\"");
        s.hm = v.string;
    }
    if (obj.get("enabled")) |v| {
        if (v != .bool) return badReq(res, "enabled must be a boolean");
        s.enabled = v.bool;
    }
    if (obj.get("base_url")) |v| {
        if (v != .string) return badReq(res, "base_url must be a string");
        s.base_url = v.string;
    }
    if (obj.get("model")) |v| {
        if (v != .string) return badReq(res, "model must be a string");
        s.model = v.string;
    }
    if (obj.get("api_key")) |v| {
        if (v != .string) return badReq(res, "api_key must be a string");
        s.api_key = v.string;
    }

    switch (updateById(app, res.arena, u.id, seg, s)) {
        .ok => try res.json(.{ .ok = true }, .{}),
        .not_found => return notFound(res),
        .err => |e| return if (std.mem.eql(u8, e, "could not write the task file")) serverErr(res, e) else badReq(res, e),
    }
}

/// DELETE /api/v1/sched/:id — remove the task file. Structural ownership like every chat route: the path is
/// built under the caller's own u{uid} prefix, so no cross-user id is expressible. 404 if absent.
pub fn deleteTask(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const u = gate(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);
    const path = try std.fmt.allocPrint(res.arena, "{s}/u{d}/_sched/{s}.json", .{ app.data, u.id, seg });
    std.Io.Dir.cwd().access(app.io, path, .{}) catch return notFound(res);
    sched_mtx.lockUncancelable(app.io);
    defer sched_mtx.unlock(app.io);
    std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
    try res.json(.{ .ok = true }, .{});
}

/// POST /api/v1/sched/:id/run — fire the task NOW, due time (and even a disabled flag — an explicit click is
/// consent) notwithstanding. Same launchRun the tick uses, so a manual run gets identical bookkeeping: it
/// counts, re-anchors an interval, and consumes a "once". 409 when the engine can't take the turn right now,
/// mirroring postMessage's concurrent-turn reply.
pub fn runTaskNow(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // Kill switch first, before auth — byte-for-byte the postMessage order, since this route IS a message post.
    if (backendDisabled(app)) {
        res.status = 501;
        return res.json(.{ .ok = false, .err = "chat backend disabled" }, .{});
    }
    const u = gate(app, req, res) orelse return;
    const id = req.param("id") orelse return badReq(res, "no id");
    const seg = safeSeg(id);
    if (seg.len == 0) return notFound(res);

    // Load under the lock, launch OUTSIDE it — launchRun must never run under sched_mtx (self-deadlock via
    // the inline-spawn fallback + the turn's schedule_task tool; see launchRun's LOCKING note).
    var t: Task = undefined;
    {
        sched_mtx.lockUncancelable(app.io);
        defer sched_mtx.unlock(app.io);
        t = loadTask(app, res.arena, u.id, seg) orelse return notFound(res);
    }
    // ONE run per task at a time: an impatient second click (a long research run shows nothing for a while)
    // used to mint a NEW same-task conv the next minute and run the whole thing again in parallel — double
    // the tokens for the same deliverable. Refuse with the RUNNING conv id so the client opens that instead.
    {
        var pb: [64]u8 = undefined;
        const prefix = std.fmt.bufPrint(&pb, "scheduled_{s}_", .{t.id[0..@min(t.id.len, 45)]}) catch "";
        var cb: [64]u8 = undefined;
        if (prefix.len > 0) {
            if (chat_engine.liveTurnWithPrefix(app.io, prefix, &cb)) |running| {
                res.status = 409;
                return res.json(.{ .ok = false, .err = "this task already has a run going — opening it", .conv = running }, .{});
            }
        }
    }
    const conv = launchRun(app, res.arena, u.id, &t, nowSecs(app.io)) orelse {
        res.status = 409;
        return res.json(.{ .ok = false, .err = "a turn is already running for this task's conversation (or all turn slots are busy) — try again shortly" }, .{});
    };
    try res.json(.{ .ok = true, .conv = conv }, .{});
}

// ---- tests (pure logic only: schedule math, id minting, JSON round-trip) ------------------------------------

test "computeNextDue: once verbatim; every anchors to created then last_run; daily rolls over + honors tz" {
    // once → at, no matter how overdue
    try std.testing.expectEqual(@as(i64, 1234), computeNextDue("once", 1234, 0, "", 0, 0, 99999, 0));
    // every: never run → created + n min; run before → last_run + n min (catch-up: caller sets last_run=now)
    try std.testing.expectEqual(@as(i64, 1000 + 300), computeNextDue("every", 0, 5, "", 1000, 0, 1100, 0));
    try std.testing.expectEqual(@as(i64, 2000 + 300), computeNextDue("every", 0, 5, "", 1000, 2000, 2100, 0));
    // garbled interval clamps to the 1-minute floor (never a per-tick fire loop)
    try std.testing.expectEqual(@as(i64, 1000 + 60), computeNextDue("every", 0, 0, "", 1000, 0, 1100, 0));
    // daily, UTC clock: 08:00 → today 09:30; 10:00 → tomorrow 09:30
    const day: i64 = 86400 * 100;
    try std.testing.expectEqual(day + 9 * 3600 + 30 * 60, computeNextDue("daily", 0, 0, "09:30", 0, 0, day + 8 * 3600, 0));
    try std.testing.expectEqual(day + 86400 + 9 * 3600 + 30 * 60, computeNextDue("daily", 0, 0, "09:30", 0, 0, day + 10 * 3600, 0));
    // daily in a UTC-4 zone (tz_off = -4h): local 09:30 = 13:30 UTC
    try std.testing.expectEqual(day + 13 * 3600 + 30 * 60, computeNextDue("daily", 0, 0, "09:30", 0, 0, day + 12 * 3600, -4 * 3600));
    // daily with a garbled hm degrades to "try in a day", never an immediate fire
    try std.testing.expectEqual(day + 86400, computeNextDue("daily", 0, 0, "nope", 0, 0, day, 0));
    // hm parsing edges
    try std.testing.expect(parseHm("23:59") != null);
    try std.testing.expect(parseHm("9:5") != null);
    try std.testing.expect(parseHm("24:00") == null);
    try std.testing.expect(parseHm("12-30") == null);
}

test "mintTaskId + convIdFor: slugged, stamped, safeSeg-clean, bounded at 64" {
    // 2000-03-01 07:05:00 UTC = epoch day 11017 (10957 days to 2000-01-01 + 31 + 29)
    const secs: i64 = 11017 * 86400 + 7 * 3600 + 5 * 60;
    var idb: [64]u8 = undefined;
    const id = mintTaskId(&idb, "  Daily Report!!  ", secs);
    try std.testing.expectEqualStrings("daily-report-0301070500", id);
    try std.testing.expect(safeSeg(id).len == id.len); // clean as a path segment / conv-id component
    // pure-punctuation name still mints a usable id
    var idb2: [64]u8 = undefined;
    try std.testing.expectEqualStrings("task-0301070500", mintTaskId(&idb2, "!!!", secs));
    // conv id: prefixed, stamped to the minute, and the whole thing stays a valid conv segment
    var cb: [64]u8 = undefined;
    const conv = convIdFor(&cb, id, secs);
    try std.testing.expectEqualStrings("scheduled_daily-report-0301070500_03010705", conv);
    try std.testing.expect(safeSeg(conv).len == conv.len);
    // a maximum-length task id is clipped so the conv id never exceeds the 64-byte safeSeg ceiling
    const long = "x" ** 64;
    var cb2: [64]u8 = undefined;
    const conv2 = convIdFor(&cb2, long, secs);
    try std.testing.expectEqual(@as(usize, 64), conv2.len);
    try std.testing.expect(safeSeg(conv2).len == conv2.len);
    // a long name's slug is clipped too, and the id still fits the ceiling with the stamp attached
    var idb3: [64]u8 = undefined;
    const id3 = mintTaskId(&idb3, "n" ** 100, secs);
    try std.testing.expect(id3.len <= 64 - 5); // room reserved for a "-hhhh" collision suffix
}

test "joinRecent: prepends newest, dedupes a same-minute re-run, caps at RECENT_MAX" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // empty history → just the newest
    try std.testing.expectEqualStrings("c1", joinRecent(a, "c1", ""));
    // normal growth, newest first
    try std.testing.expectEqualStrings("c2,c1", joinRecent(a, "c2", "c1"));
    try std.testing.expectEqualStrings("c3,c2,c1", joinRecent(a, "c3", "c2,c1"));
    // a same-minute re-run mints the same conv id — never a duplicate entry
    try std.testing.expectEqualStrings("c3,c2,c1", joinRecent(a, "c3", "c3,c2,c1"));
    // the cap: a 6th run drops the oldest
    try std.testing.expectEqualStrings("c6,c5,c4,c3,c2", joinRecent(a, "c6", "c5,c4,c3,c2,c1"));
    // stray whitespace/empties in a hand-edited file are dropped, not preserved
    try std.testing.expectEqualStrings("c2,c1", joinRecent(a, "c2", " c1 ,,"));
}

test "task JSON round-trips through encodeTask/parse; the HTTP encoding always redacts api_key" {
    const gpa = std.testing.allocator;
    const t = Task{
        .id = "daily-report-0301070500",
        .name = "Daily Report",
        .prompt = "summarize \"everything\"\nline two",
        .details = "use the numbers from ops",
        .kind = "daily",
        .at = 0,
        .every_min = 0,
        .hm = "09:30",
        .enabled = true,
        .created = 123,
        .last_run = 456,
        .next_due = 789,
        .last_conv = "scheduled_daily-report_03010705",
        .recent_convs = "scheduled_daily-report_03010705,scheduled_daily-report_02280705",
        .runs = 7,
        .last_status = "ok: 2 file(s), 3 note(s)",
        .fail_streak = 2,
        .revisions = 3,
        .base_url = "http://127.0.0.1:11434/v1",
        .model = "gpt-oss:20b",
        .api_key = "sk-secret",
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    // DISK shape: the key survives the round-trip
    try encodeTask(gpa, &out, t, false);
    {
        const back = try std.json.parseFromSlice(Task, gpa, out.items, .{ .ignore_unknown_fields = true });
        defer back.deinit();
        try std.testing.expectEqualStrings(t.id, back.value.id);
        try std.testing.expectEqualStrings(t.name, back.value.name);
        try std.testing.expectEqualStrings(t.prompt, back.value.prompt);
        try std.testing.expectEqualStrings(t.details, back.value.details);
        try std.testing.expectEqualStrings(t.kind, back.value.kind);
        try std.testing.expectEqualStrings(t.hm, back.value.hm);
        try std.testing.expectEqualStrings(t.last_conv, back.value.last_conv);
        try std.testing.expectEqualStrings(t.recent_convs, back.value.recent_convs);
        try std.testing.expectEqualStrings(t.last_status, back.value.last_status);
        try std.testing.expectEqual(t.fail_streak, back.value.fail_streak);
        try std.testing.expectEqual(t.revisions, back.value.revisions);
        try std.testing.expectEqualStrings(t.base_url, back.value.base_url);
        try std.testing.expectEqualStrings(t.model, back.value.model);
        try std.testing.expectEqualStrings("sk-secret", back.value.api_key);
        try std.testing.expectEqual(t.created, back.value.created);
        try std.testing.expectEqual(t.last_run, back.value.last_run);
        try std.testing.expectEqual(t.next_due, back.value.next_due);
        try std.testing.expectEqual(t.runs, back.value.runs);
        try std.testing.expectEqual(t.enabled, back.value.enabled);
    }
    // HTTP shape: identical except the key is ALWAYS ""
    out.clearRetainingCapacity();
    try encodeTask(gpa, &out, t, true);
    {
        try std.testing.expect(std.mem.indexOf(u8, out.items, "sk-secret") == null);
        const back = try std.json.parseFromSlice(Task, gpa, out.items, .{ .ignore_unknown_fields = true });
        defer back.deinit();
        try std.testing.expectEqualStrings("", back.value.api_key);
        try std.testing.expectEqualStrings(t.name, back.value.name);
    }
    // a PRE-LEDGER task file (no last_status/fail_streak/revisions) still parses, healthy by default
    {
        const old = "{\"id\":\"x\",\"name\":\"n\",\"prompt\":\"p\",\"kind\":\"every\",\"every_min\":30}";
        const back = try std.json.parseFromSlice(Task, gpa, old, .{ .ignore_unknown_fields = true });
        defer back.deinit();
        try std.testing.expectEqual(@as(i64, 0), back.value.fail_streak);
        try std.testing.expectEqual(@as(i64, 0), back.value.revisions);
        try std.testing.expectEqualStrings("", back.value.last_status);
    }
}

test "failBackoffSecs: only 'every' backs off, from the SECOND consecutive failure, doubling to caps" {
    // first failure retries on the normal cadence (repair posture is enough); non-"every" kinds never back off
    try std.testing.expectEqual(@as(i64, 0), failBackoffSecs("every", 60, 0));
    try std.testing.expectEqual(@as(i64, 0), failBackoffSecs("every", 60, 1));
    try std.testing.expectEqual(@as(i64, 0), failBackoffSecs("daily", 60, 5));
    try std.testing.expectEqual(@as(i64, 0), failBackoffSecs("once", 60, 5));
    // hourly task: 2h, 4h, 8h, 16h, then the multiplier caps at x16
    try std.testing.expectEqual(@as(i64, 2 * 3600), failBackoffSecs("every", 60, 2));
    try std.testing.expectEqual(@as(i64, 4 * 3600), failBackoffSecs("every", 60, 3));
    try std.testing.expectEqual(@as(i64, 8 * 3600), failBackoffSecs("every", 60, 4));
    try std.testing.expectEqual(@as(i64, 16 * 3600), failBackoffSecs("every", 60, 5));
    try std.testing.expectEqual(@as(i64, 16 * 3600), failBackoffSecs("every", 60, 50));
    // a long cadence hits the 2-day absolute cap instead
    try std.testing.expectEqual(@as(i64, 172800), failBackoffSecs("every", 1440, 3));
    // a garbled interval is clamped like computeNextDue clamps it — never zero, never overflow
    try std.testing.expectEqual(@as(i64, 120), failBackoffSecs("every", 0, 2));
}

test "applySpecToTask: absent keeps, present replaces + validates the FINAL shape, change flags drive revisions" {
    var t = Task{ .id = "x", .name = "n", .prompt = "p", .kind = "every", .every_min = 30 };
    var sc = false;
    var cc = false;
    // empty spec: nothing changes, still valid
    try std.testing.expect(applySpecToTask(&t, .{}, &sc, &cc) == null);
    try std.testing.expect(!sc and !cc);
    // content change flips cc only
    try std.testing.expect(applySpecToTask(&t, .{ .prompt = "  better prompt  " }, &sc, &cc) == null);
    try std.testing.expectEqualStrings("better prompt", t.prompt);
    try std.testing.expect(cc and !sc);
    // schedule change flips sc; final shape validated
    cc = false;
    try std.testing.expect(applySpecToTask(&t, .{ .every_min = 120 }, &sc, &cc) == null);
    try std.testing.expect(sc and !cc);
    try std.testing.expectEqual(@as(i64, 120), t.every_min);
    // bad final shapes are rejected with the route's exact messages
    sc = false;
    try std.testing.expectEqualStrings("prompt must be a non-empty string", applySpecToTask(&t, .{ .prompt = "  " }, &sc, &cc).?);
    try std.testing.expectEqualStrings("kind must be \"once\", \"every\", or \"daily\"", applySpecToTask(&t, .{ .kind = "hourly" }, &sc, &cc).?);
    try std.testing.expectEqualStrings("every_min must be between 1 and 527040 (one year) for kind \"every\"", applySpecToTask(&t, .{ .every_min = 0 }, &sc, &cc).?);
    // switching to daily without a stored hm fails on the FINAL shape, not just the touched field
    try std.testing.expectEqualStrings("hm must be \"HH:MM\" for kind \"daily\"", applySpecToTask(&t, .{ .kind = "daily" }, &sc, &cc).?);
    try std.testing.expect(applySpecToTask(&t, .{ .kind = "daily", .hm = "07:30" }, &sc, &cc) == null);
    // enabled/provider fields apply without counting as content or schedule changes
    sc = false;
    cc = false;
    try std.testing.expect(applySpecToTask(&t, .{ .enabled = false, .model = "m2" }, &sc, &cc) == null);
    try std.testing.expect(!sc and !cc);
    try std.testing.expect(!t.enabled);
    try std.testing.expectEqualStrings("m2", t.model);
}

test "buildRunMessage: prompt + details + run context (id, run number, cadence, outcome, heal posture)" {
    const gpa = std.testing.allocator;
    // healthy task: context names the id + cadence + standing directive, but NO self-heal block; a blank
    // run_rel omits the workdir block entirely
    {
        const t = Task{ .id = "digest-0301070500", .name = "Digest", .prompt = "Do the digest.", .details = "use source X", .kind = "every", .every_min = 60, .runs = 4 };
        const msg = buildRunMessage(gpa, &t, "").?;
        defer gpa.free(msg);
        try std.testing.expect(std.mem.startsWith(u8, msg, "Do the digest."));
        try std.testing.expect(std.mem.indexOf(u8, msg, "Key details / data to use:\nuse source X") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "run #5 of scheduled task \"Digest\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "its id is \"digest-0301070500\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "runs every 60 min") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "schedule_update with id \"digest-0301070500\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "SELF-HEALING and SELF-IMPROVING") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "SELF-HEAL FIRST") == null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "Previous run outcome") == null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "WORKDIR") == null);
    }
    // failing task: previous outcome + repair posture lead the run; empty details adds no details block
    {
        const t = Task{ .id = "digest-0301070500", .name = "Digest", .prompt = "Do the digest.", .kind = "daily", .hm = "09:30", .runs = 9, .last_status = "FAILED: the model call errored mid-turn", .fail_streak = 3 };
        const msg = buildRunMessage(gpa, &t, "").?;
        defer gpa.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, "Key details") == null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "runs daily at 09:30") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "Previous run outcome: FAILED: the model call errored mid-turn") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "SELF-HEAL FIRST: the last 3 run(s) of this task FAILED in a row") != null);
    }
    // a resolved run_rel adds the permanent-workdir block, naming this run's dir AND the task's runs/ fan-out
    {
        const t = Task{ .id = "digest-0301070500", .name = "Digest", .prompt = "Do the digest.", .kind = "every", .every_min = 60 };
        const msg = buildRunMessage(gpa, &t, "u1/_sched/digest-0301070500/runs/07171400").?;
        defer gpa.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, "WORKDIR (permanent): this run's files land in \"u1/_sched/digest-0301070500/runs/07171400/work\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "timestamped folder under \"u1/_sched/digest-0301070500/runs/\"") != null);
    }
}
