//! Server-side agentic chat turn loop — the WRITE twin of chat_service.zig's read-only conv routes. Given a
//! user message it runs a bounded tool-calling loop against the caller's chosen model, streaming its progress
//! into the SAME per-conversation store the P0-4 readers serve:
//!
//!     {data}/u{uid}/_chat/convs/{conv}/
//!         messages.jsonl   // one JSON object per line: {role,content,kind,ts}  (user + final assistant turns)
//!         events.jsonl     // one JSON object per line: {kind,...}              (live turn narration for the poll)
//!
//! The build tools the loop's calls run route through the SAME tree a hive cast for this conversation spawns in
//! ({data}/u{uid}/_chat/builds/{conv}) — ToolCtx here is a byte-for-byte copy of chat_tools.runMindTool's, so
//! chat + a cast co-edit ONE workdir with ONE micro-VCS history. Ownership is structural: every path is built
//! from the caller's own uid, so a turn can only ever touch its own conversation.
//!
//! ON by default — postMessage (chat_service.zig) runs this unless VEIL_CHAT_BACKEND=0 (the kill switch), and it
//! is admin-only. The desk prefers this backend turn and falls back to its own local engine on any failure.

const std = @import("std");
const http = @import("../gateway/http.zig");
const tools = @import("../worker/tools.zig");
const osc = @import("../worker/oscillation.zig");
const llm = @import("../worker/llm.zig");
const cctx = @import("chat_context.zig");

const App = http.App;

/// Hard ceiling on tool-calling round-trips per ONE settled answer. 12 was too low — a real build (e.g. a
/// three.js game: many write_file + read_file + edit_file rounds) exhausted it MID-BUILD and committed a raw
/// "(reached the step limit)" string as the reply even though the build succeeded. 24 comfortably fits a big
/// single-turn build; the outer DRIVE_MAX still bounds the whole turn, and a genuine runaway summarizes (below).
const MAX_ITERS: usize = 24;

/// Hard ceiling on AUTO-LOOP drive steps in one turn. Lowered 30 -> 6: at 30 a thorough model would "verify"
/// and re-read forever after a fix (observed: a fix-the-bug turn drove endlessly, thousands of frames). 6 is
/// enough for a build + a couple of follow-through steps; a plain Q&A still stops after one (DONE). The user's
/// Stop now reaches the turn (control.jsonl), and MAX_ITERS bounds each step's tool rounds.
const DRIVE_MAX: usize = 6;

/// The single question the drive inference answers between settled steps: it either names the next concrete
/// step (which becomes a synthetic user turn) or replies DONE. Carries the LOOP_SYSTEM intent inline rather than
/// swapping the system prompt (a server-turn simplification of desk's dedicated LOOP_SYSTEM driver turn).
const LOOP_QUESTION =
    "What is the single next concrete step toward the goal? Reply with ONLY that next instruction, or reply " ++
    "exactly DONE if the goal is fully achieved.";

/// REFLECT (desk REFLECT_PASSES): one self-critique/improve pass on a substantial first answer before it's
/// committed — the model reviews its own reply against the question and returns the final (improved-or-unchanged)
/// text. Gated to the FIRST drive step only (one reflect per turn) and to answers >= REFLECT_MIN bytes, so a
/// terse reply or a multi-step build's intermediate narration doesn't spend an extra full completion.
const REFLECT_MIN: usize = 240;
const REFLECT_PROMPT =
    "Critically review the answer you just gave for correctness, completeness, and clarity against the user's " ++
    "request. If it can be materially improved, reply with ONLY the improved answer. If it is already good, reply " ++
    "with it unchanged. Do not add commentary about the review itself.";

/// Serializes edit_file's micro-VCS commits (vcs.zig) across concurrent chat turns IN THIS gateway process —
/// the exact role chat_tools.chat_vcs_mtx plays for /api/v1/chat/tool. A live hive cast building in the same
/// conversation dir is a SEPARATE process with its own such lock; both sides still rebase onto the HEAD they
/// read and land via a same-dir atomic rename, so the cross-process window is microseconds (see chat_tools.zig).
var chat_vcs_mtx: std.Io.Mutex = .init;

const SYSTEM_PROMPT =
    "You are veil, a helpful coding and research assistant. You have tools: web_search / web_fetch / read_url " ++
    "for the live web, read_file / write_file / edit_file / list_dir / run_python / run_tests to build and run " ++
    "code in your working directory, and observe / recall / recall_hive for memory. Use a tool when it genuinely " ++
    "helps; call tools one or more times, then when you have what you need reply to the user directly in plain " ++
    "prose. Keep answers concrete and grounded in what the tools actually returned.";

/// io-based wall clock — the SAME source the worker stamps its event `t` with (std time under io, never a raw
/// clock primitive). Seconds are fine: the P0-4 reader only maxes `ts` for a conv's `updated`, so ties are OK.
fn nowSecs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Replace each byte not part of a valid UTF-8 sequence with '?' in place (length-preserving), so arbitrary
/// tool output (fetched page bytes) always serializes as conformant JSON. Local copy of chat_tools.scrubUtf8.
fn scrubUtf8(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const n = std.unicode.utf8ByteSequenceLength(buf[i]) catch {
            buf[i] = '?';
            i += 1;
            continue;
        };
        if (i + n > buf.len) {
            buf[i] = '?';
            i += 1;
            continue;
        }
        if (std.unicode.utf8Decode(buf[i .. i + n])) |_| {
            i += n;
        } else |_| {
            buf[i] = '?';
            i += 1;
        }
    }
}

/// Clip `s` to at most `max` bytes without splitting a UTF-8 multibyte sequence (back off through trailing high
/// bytes). Used only for the short event `preview`; the model still sees the full untruncated tool result.
fn clipBytes(s: []const u8, max: usize) []const u8 {
    var n = @min(s.len, max);
    while (n > 0 and (s[n - 1] & 0x80) != 0) n -= 1;
    return s[0..n];
}

/// Append one message object to messages.jsonl as a COMPLETE single line: {"role":..,"content":..,"kind":..,"ts":N}.
/// The whole escaped line is built first, then appended, so a reader never sees a partial/multiline object.
fn appendMsg(app: *App, conv_dir: []const u8, role: []const u8, content: []const u8, kind: []const u8, ts: i64) void {
    const gpa = app.gpa;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    line.appendSlice(gpa, "{\"role\":") catch return;
    http.jstr(gpa, &line, role) catch return;
    line.appendSlice(gpa, ",\"content\":") catch return;
    http.jstr(gpa, &line, content) catch return;
    line.appendSlice(gpa, ",\"kind\":") catch return;
    http.jstr(gpa, &line, kind) catch return;
    const tail = std.fmt.allocPrint(gpa, ",\"ts\":{d}}}\n", .{ts}) catch return;
    defer gpa.free(tail);
    line.appendSlice(gpa, tail) catch return;
    const path = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return;
    defer gpa.free(path);
    http.appendFile(app.io, gpa, path, line.items) catch {};
}

/// Append `obj` (a complete, already-escaped single-line JSON object) as one line to events.jsonl.
fn emitEvent(app: *App, conv_dir: []const u8, obj: []const u8) void {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/events.jsonl", .{conv_dir}) catch return;
    defer gpa.free(path);
    const line = std.fmt.allocPrint(gpa, "{s}\n", .{obj}) catch return;
    defer gpa.free(line);
    http.appendFile(app.io, gpa, path, line) catch {};
}

/// Emit `{"kind":<kind>,"<field>":<value>}` with `value` JSON-escaped. Covers the message/error/reasoning
/// events (one string payload); the multi-field tool events are built inline.
fn emitKV(app: *App, conv_dir: []const u8, kind: []const u8, field: []const u8, value: []const u8) void {
    const gpa = app.gpa;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    ev.appendSlice(gpa, "{\"kind\":") catch return;
    http.jstr(gpa, &ev, kind) catch return;
    ev.append(gpa, ',') catch return;
    http.jstr(gpa, &ev, field) catch return;
    ev.append(gpa, ':') catch return;
    http.jstr(gpa, &ev, value) catch return;
    ev.append(gpa, '}') catch return;
    emitEvent(app, conv_dir, ev.items);
}

/// Run one full agentic turn for `conv` (already safeSeg'd, non-empty). Blocks the calling httpz worker thread
/// to completion (casts/deploys block the same way); on return the whole turn is durable in messages/events.jsonl.
pub fn runTurn(app: *App, uid: u64, conv: []const u8, base_url: []const u8, key: []const u8, model: []const u8, user_text: []const u8) void {
    const gpa = app.gpa;

    // ---- store + build paths (conv store under convs/, build tree under builds/ — same split as runMindTool) ----
    const base = std.fmt.allocPrint(gpa, "{s}/u{d}/_chat", .{ app.data, uid }) catch return;
    defer gpa.free(base);
    const conv_dir = std.fmt.allocPrint(gpa, "{s}/convs/{s}", .{ base, conv }) catch return;
    defer gpa.free(conv_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, conv_dir, .default_dir) catch {};

    // ---- HIPPOCAMPUS scope: this conversation's own durable neuron-db partition (user turns + tool findings) ----
    const mem_scope = std.fmt.allocPrint(gpa, "chat:{s}", .{conv}) catch return;
    defer gpa.free(mem_scope);

    // ---- COOPERATIVE-STOP cursor: only control.jsonl ops written AFTER this byte offset count for THIS turn ----
    const ctrl_cursor = controlLen(app, conv_dir);

    // ---- record the user's message BEFORE anything else, so it's durable even if the LLM call dies ----
    appendMsg(app, conv_dir, "user", user_text, "user", nowSecs(app.io));
    emitUserRole(app, conv_dir, user_text); // {"kind":"message","role":"user","content":..}

    const environ = app.sup.parent_env orelse {
        emitKV(app, conv_dir, "error", "err", "server env unavailable");
        return;
    };

    // ---- ToolCtx: byte-for-byte the chat_tools.runMindTool construction (per-uid store, builds/{conv} tree) ----
    const run_root = std.fmt.allocPrint(gpa, "{s}/builds/{s}", .{ base, conv }) catch return;
    defer gpa.free(run_root);
    const workdir = std.fmt.allocPrint(gpa, "{s}/work", .{run_root}) catch return;
    defer gpa.free(workdir);
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, workdir, .default_dir) catch {};
    const db = std.fmt.allocPrint(gpa, "{s}/hive.sqlite", .{base}) catch return;
    defer gpa.free(db);

    var counters = [_]u32{0} ** 5;
    var ctx = tools.ToolCtx{
        .gpa = gpa,
        .io = app.io,
        .environ = environ,
        .run_dir = run_root,
        .workdir = workdir,
        .scope = "chat",
        .mind = "chat",
        .round = 0,
        .mem = osc.Mem.init(gpa, app.io, app.sup.neuron_bin, db),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        .fmtx = &chat_vcs_mtx,
        .vcs_enabled = conv.len > 0,
    };

    // ---- seed the LLM conversation: system prompt + every persisted message (incl. the user turn just added) ----
    // `conv_buf` is the INSIDE of "messages":[ … ]; it grows in the loop with the assistant tool_call turns and
    // tool-result turns so the model always sees full context. First object has no leading comma; rest do.
    var conv_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer conv_buf.deinit(gpa);
    conv_buf.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return;
    http.jstr(gpa, &conv_buf, SYSTEM_PROMPT) catch return;
    conv_buf.append(gpa, '}') catch return;

    // HIPPOCAMPUS (recall): pull the facts most relevant to THIS user text from the conversation's own neuron-db
    // — earlier turns + tool findings, including ones evicted from the visible history — and inject them as a
    // grounded-context system message RIGHT AFTER the base prompt (before the replayed history). Additive: an
    // empty/failed recall leaves conv_buf byte-identical to the history-only seed, so it can only help.
    {
        const recalled = ctx.mem.recall(mem_scope, user_text);
        defer gpa.free(recalled);
        if (recalled.len > 0) {
            scrubUtf8(recalled); // observed facts are already scrubbed, but a fetched-byte tail could slip in
            var mem_content: std.ArrayListUnmanaged(u8) = .empty;
            defer mem_content.deinit(gpa);
            mem_content.appendSlice(gpa, "RELEVANT MEMORY (recalled from this conversation's memory — earlier turns, tool findings). Treat as grounded context:\n") catch return;
            mem_content.appendSlice(gpa, recalled) catch return;
            conv_buf.appendSlice(gpa, ",{\"role\":\"system\",\"content\":") catch return;
            http.jstr(gpa, &conv_buf, mem_content.items) catch return;
            conv_buf.append(gpa, '}') catch return;
        }
    }
    // BOUNDED HISTORY (chat_context): instead of replaying the entire transcript (which overflowed the model
    // window on long chats and hit an 8 MiB read cliff), project it into a fixed budget — a rolling summary of
    // scrolled-out turns + the pinned goal + a recency window of the newest turns. The durable log stays whole.
    assembleHistory(app, conv_dir, run_root, base_url, key, model, user_text, &conv_buf);

    // HIPPOCAMPUS (observe): the user's own turn is durable knowledge — store it so a later turn can recall it.
    // We NEVER observe the veil's assistant replies (only user turns + tool results); self-observing generated
    // text then recalling it as "grounded context" is the parrot/confabulation loop the desk fix removed.
    _ = ctx.mem.observe(mem_scope, user_text);

    // The assembled, bounded PREFIX (system + recall + summary + goal + recency window). Everything appended past
    // this by the drive loop (settled answers, synthetic drive steps, per-pass tool notes) is compacted against it
    // between drive steps so a multi-step turn stays bounded ACROSS steps, not only within one pass.
    const assembled_len = conv_buf.items.len;

    // ---- AUTO-LOOP DRIVE: settle one answer, infer the next step, drive again until DONE / repeat / DRIVE_MAX ----
    // `prev_drive` seeds the repeat guard with the user's own request so a driver that merely echoes it stops.
    var prev_drive: []u8 = gpa.dupe(u8, user_text) catch &[_]u8{};
    defer if (prev_drive.len > 0) gpa.free(prev_drive);

    var drive: usize = 0;
    outer: while (drive < DRIVE_MAX) : (drive += 1) {
        // COOPERATIVE STOP (between drive steps): a `"op":"stop"` written to control.jsonl after the turn began.
        if (stopRequestedSince(app, conv_dir, ctrl_cursor)) {
            emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
            return;
        }

        // CROSS-STEP COMPACTION: fold accumulated drive-step growth (prior settled answers + compacted notes) into
        // one note when it crosses the budget, so a long multi-step / afk turn can't overflow the model window
        // across steps. No-op on the first step (nothing past the assembled prefix yet).
        compactWorking(app, run_root, base_url, key, model, &conv_buf, assembled_len);

        // Run one agentic tool pass to a SETTLED (no-tool-call) answer.
        const inner = runInnerAgentic(app, conv_dir, run_root, base_url, key, model, &conv_buf, &ctx, mem_scope, ctrl_cursor);
        switch (inner.outcome) {
            .hard_error => {
                // the inference failed — the helper emitted {kind:error}; ALSO emit {kind:done} so the desk
                // poller disarms + clears busy instead of hanging forever (the "kept streaming after an error").
                emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
                return;
            },
            .stopped => {
                // stop landed mid tool-loop — commit the last narration (if any) so the user keeps it, then close.
                if (inner.content.len > 0) {
                    appendMsg(app, conv_dir, "assistant", inner.content, "veil", nowSecs(app.io));
                    emitAssistant(app, conv_dir, inner.content);
                }
                gpa.free(inner.content);
                emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
                return;
            },
            .settled => {},
        }

        // Commit the settled answer as the assistant turn (durable + narrated) and thread it into the LLM context.
        var answer = inner.content;

        // Strip any leaked tool-call markup the recovery couldn't parse into a call, so the user never sees raw
        // `<｜｜DSML｜｜invoke …>` in the reply.
        if (cctx.looksLikeToolMarkup(answer)) {
            const clean = cctx.contentBeforeMarkup(answer);
            if (gpa.dupe(u8, clean)) |d| {
                gpa.free(answer);
                answer = d;
            } else |_| {}
        }

        // EMPTY settled answer (the model "died" — returned no text and no tools, or stripped to nothing): don't
        // commit an empty reply or drive further on nothing. Surface a brief honest note and end the turn.
        if (std.mem.trim(u8, answer, " \r\n\t").len == 0) {
            gpa.free(answer);
            const note = "(no reply — the model returned an empty or malformed response this turn)";
            appendMsg(app, conv_dir, "assistant", note, "veil", nowSecs(app.io));
            emitAssistant(app, conv_dir, note);
            emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
            return;
        }

        // REFLECT: on the FIRST substantial answer of the turn, run one self-critique/improve pass before commit.
        if (drive == 0 and answer.len >= REFLECT_MIN) {
            if (reflectAnswer(app, run_root, base_url, key, model, user_text, answer)) |improved| {
                gpa.free(answer);
                answer = improved;
                emitKV(app, conv_dir, "status", "text", "reflected");
            }
        }
        defer gpa.free(answer);
        appendMsg(app, conv_dir, "assistant", answer, "veil", nowSecs(app.io));
        emitAssistant(app, conv_dir, answer);
        conv_buf.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":") catch break :outer;
        http.jstr(gpa, &conv_buf, answer) catch break :outer;
        conv_buf.append(gpa, '}') catch break :outer;

        // DRIVE INFERENCE: one no-tools completion that names the next step (or DONE). The loop question is a
        // SYNTHETIC turn — appended only long enough to ask, then truncated back off conv_buf so it never rides
        // into the next real pass and never touches messages.jsonl.
        const saved_len = conv_buf.items.len;
        conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
        http.jstr(gpa, &conv_buf, LOOP_QUESTION) catch break :outer;
        conv_buf.append(gpa, '}') catch break :outer;
        var next = llm.complete(gpa, app.io, run_root, "loop", base_url, key, model, conv_buf.items, "", 512, 0.5);
        defer next.deinit(gpa);
        conv_buf.shrinkRetainingCapacity(saved_len); // drop the synthetic loop question

        const trimmed = std.mem.trim(u8, next.content, " \r\n\t`*\"'");
        // STOP the drive when the goal is achieved (DONE), the inference is empty/failed, the next step just
        // repeats the last one (no progress), OR the next step is itself leaked tool-call markup rather than a real
        // instruction (a malfunctioning model — driving on it is the "janked back and forth" churn). The settled
        // answer above is the turn's final reply.
        if (!next.ok or trimmed.len == 0 or loopIsDone(next.content) or nearlySame(trimmed, prev_drive) or cctx.looksLikeToolMarkup(trimmed)) break :outer;

        // CONTINUE: the inferred step becomes the next (synthetic) user turn in the LLM context — NOT written to
        // messages.jsonl (only real user + assistant turns are durable there).
        conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
        http.jstr(gpa, &conv_buf, trimmed) catch break :outer;
        conv_buf.append(gpa, '}') catch break :outer;
        var sbuf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&sbuf, "continuing: {s}", .{clipBytes(trimmed, 80)}) catch "continuing";
        emitKV(app, conv_dir, "status", "text", status);
        const nd: []u8 = gpa.dupe(u8, trimmed) catch &[_]u8{};
        if (prev_drive.len > 0) gpa.free(prev_drive);
        prev_drive = nd;
    }

    // The drive loop ended (DONE / repeat / DRIVE_MAX / an OOM append) — every settled answer is already durable;
    // emit the single terminal `done` exactly once.
    emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
}

// ---- PER-CONVERSATION TURN LOCK ----------------------------------------------------------------------------
// A turn is a detached background thread that does an UNLOCKED read-modify-write of messages.jsonl + context.json.
// Two turns for the SAME conversation running concurrently (a raced double-POST, a second client, an auto-loop
// follow-up firing during a long turn) would lost-update the durable log or torn-read the summary cursor. This
// serializes them: at most one in-flight turn per conv. A distinct conv is unaffected (up to MAX_ACTIVE_TURNS at
// once — a 17th distinct conv while 16 run is rejected, which is safe, never silent corruption). Bounded fixed
// storage (conv is safeSeg'd and <= 64 bytes) so no allocation is needed on the hot path.
const MAX_ACTIVE_TURNS = 16;
var turn_mtx: std.Io.Mutex = .init;
var active_convs: [MAX_ACTIVE_TURNS][64]u8 = undefined;
var active_lens: [MAX_ACTIVE_TURNS]usize = [_]usize{0} ** MAX_ACTIVE_TURNS;

/// Claim the single in-flight slot for `conv`. Returns false if a turn is already running for it (caller rejects
/// the concurrent request) or all slots are busy. A caller that gets `true` MUST pair it with endTurn(io, conv).
pub fn tryBeginTurn(io: std.Io, conv: []const u8) bool {
    if (conv.len == 0 or conv.len > 64) return false; // unrepresentable (shouldn't happen: safeSeg'd, <=64) — reject
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    var free_slot: ?usize = null;
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] == 0) {
            if (free_slot == null) free_slot = i;
        } else if (std.mem.eql(u8, active_convs[i][0..active_lens[i]], conv)) {
            return false; // a turn is already running for this conversation
        }
    }
    const slot = free_slot orelse return false; // all slots busy — reject rather than run unserialized
    @memcpy(active_convs[slot][0..conv.len], conv);
    active_lens[slot] = conv.len;
    return true;
}

/// Release the in-flight slot for `conv` (matches tryBeginTurn). Copies nothing — safe to call before freeing any
/// backing storage `conv` points into.
fn endTurn(io: std.Io, conv: []const u8) void {
    if (conv.len == 0 or conv.len > 64) return;
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] == conv.len and std.mem.eql(u8, active_convs[i][0..active_lens[i]], conv)) {
            active_lens[i] = 0;
            return;
        }
    }
}

/// Owned arguments for a background turn: one backing `blob` holds every string arg (the request arena that
/// spawnTurn was called from dies immediately), plus slices into it. turnThread frees the blob + the struct.
pub const TurnArgs = struct {
    app: *App,
    uid: u64,
    blob: []u8,
    conv: []const u8,
    base_url: []const u8,
    key: []const u8,
    model: []const u8,
    text: []const u8,
};

/// Detached-thread entry: run the whole turn, then free the owned args. Any failure inside runTurn is already
/// caught + surfaced as an event, so this thread returns cleanly (never propagates an error that could abort it).
fn turnThread(args: *TurnArgs) void {
    runTurn(args.app, args.uid, args.conv, args.base_url, args.key, args.model, args.text);
    endTurn(args.app.io, args.conv); // release the per-conv turn lock (before freeing the blob `conv` points into)
    const gpa = args.app.gpa;
    gpa.free(args.blob);
    gpa.destroy(args);
}

/// Launch a turn for (uid, conv) on a DETACHED background thread with owned copies of every arg, so the HTTP
/// handler can return 202 at once and the client streams the turn's event frames live (a synchronous turn would
/// block the client's /events poll for the whole turn — the "shows only 'server thinking'" bug). On an
/// allocation or thread-spawn failure it runs the turn INLINE (blocking the caller) rather than drop it — the
/// caller's arg slices are still valid at that point. The turn writes its frames to events.jsonl either way.
pub fn spawnTurn(app: *App, uid: u64, conv: []const u8, base_url: []const u8, key: []const u8, model: []const u8, text: []const u8) void {
    const gpa = app.gpa;
    const total = conv.len + base_url.len + key.len + model.len + text.len;
    // The caller (postMessage) already claimed the per-conv turn slot via tryBeginTurn; EVERY completion path here
    // must release it. The detached/inline turnThread paths release in turnThread; the two alloc-failure inline
    // paths run the turn directly, so they release explicitly.
    const args = gpa.create(TurnArgs) catch {
        runTurn(app, uid, conv, base_url, key, model, text);
        endTurn(app.io, conv);
        return;
    };
    const blob = gpa.alloc(u8, total) catch {
        gpa.destroy(args);
        runTurn(app, uid, conv, base_url, key, model, text);
        endTurn(app.io, conv);
        return;
    };
    var o: usize = 0;
    const cv = blob[o..][0..conv.len];
    @memcpy(cv, conv);
    o += conv.len;
    const bu = blob[o..][0..base_url.len];
    @memcpy(bu, base_url);
    o += base_url.len;
    const ky = blob[o..][0..key.len];
    @memcpy(ky, key);
    o += key.len;
    const md = blob[o..][0..model.len];
    @memcpy(md, model);
    o += model.len;
    const tx = blob[o..][0..text.len];
    @memcpy(tx, text);
    args.* = .{ .app = app, .uid = uid, .blob = blob, .conv = cv, .base_url = bu, .key = ky, .model = md, .text = tx };
    if (std.Thread.spawn(.{}, turnThread, .{args})) |t| {
        t.detach();
    } else |_| {
        turnThread(args); // spawn failed → run inline (blocks) + free, rather than drop the turn
    }
}

/// One settled agentic tool pass: runs the tool-calling loop against the current `conv_buf` until the model emits
/// a NO-tool-call answer (that answer is `.settled`), a completion fails (`.hard_error` — the error event is
/// already emitted here), or a cooperative stop lands before an inference (`.stopped`). Grows `conv_buf` with the
/// assistant tool_call turns + tool-result turns (shared context for the outer drive). `.content` is gpa-owned;
/// the caller frees it in every outcome. Successful tool results are observed into `mem_scope` (confab-safe:
/// only tool findings + user turns are observed, never assistant replies).
const InnerResult = struct {
    outcome: enum { settled, hard_error, stopped },
    content: []u8,
};

/// Borrowed handle the streaming callback needs to emit live deltas into this turn's event log.
/// Batch streamed deltas to ~this many chars per emitted frame. Streaming one FRAME per model TOKEN produced
/// thousands of frames per turn (8400 reasoning frames observed) — each is a file append + a desk poll-parse,
/// which overwhelmed the client ("the chat is dying"). Coalescing to ~60-char chunks cuts frames ~15x while the
/// reply still visibly types out.
const FLUSH_CHARS: usize = 60;

const StreamCtx = struct {
    app: *App,
    conv_dir: []const u8,
    streamed: bool = false,
    tok: [256]u8 = undefined,
    tok_len: usize = 0,
    rsn: [256]u8 = undefined,
    rsn_len: usize = 0,
};

/// llm.completeStream fires this per delta. We ACCUMULATE into a small buffer and emit a `{"kind":"token"|
/// "reasoning","delta":…}` frame only every ~FLUSH_CHARS (or when the buffer fills) — the reply still types out,
/// but at a sane frame rate. The chunk is borrowed (valid only during this call); scAccum copies it immediately.
fn streamOnDelta(cx: *anyopaque, kind: llm.DeltaKind, text: []const u8) void {
    if (text.len == 0) return;
    const sc: *StreamCtx = @ptrCast(@alignCast(cx));
    sc.streamed = true; // a real stream happened — so the fallback reasoning emit is skipped
    scAccum(sc, kind == .reasoning, text);
}

fn scAccum(sc: *StreamCtx, is_reason: bool, text: []const u8) void {
    const buf: []u8 = if (is_reason) &sc.rsn else &sc.tok;
    const len: *usize = if (is_reason) &sc.rsn_len else &sc.tok_len;
    const kind: []const u8 = if (is_reason) "reasoning" else "token";
    var rest = text;
    while (rest.len > 0) {
        const n = @min(rest.len, buf.len - len.*);
        @memcpy(buf[len.*..][0..n], rest[0..n]);
        len.* += n;
        rest = rest[n..];
        if (len.* >= FLUSH_CHARS or len.* == buf.len) {
            emitKV(sc.app, sc.conv_dir, kind, "delta", buf[0..len.*]);
            len.* = 0;
        }
    }
}

/// Emit any buffered tail deltas — called after completeStream returns so the last partial chunk isn't lost.
fn streamFlush(sc: *StreamCtx) void {
    if (sc.tok_len > 0) {
        emitKV(sc.app, sc.conv_dir, "token", "delta", sc.tok[0..sc.tok_len]);
        sc.tok_len = 0;
    }
    if (sc.rsn_len > 0) {
        emitKV(sc.app, sc.conv_dir, "reasoning", "delta", sc.rsn[0..sc.rsn_len]);
        sc.rsn_len = 0;
    }
}
fn runInnerAgentic(
    app: *App,
    conv_dir: []const u8,
    run_root: []const u8,
    base_url: []const u8,
    key: []const u8,
    model: []const u8,
    conv_buf: *std.ArrayListUnmanaged(u8),
    ctx: *tools.ToolCtx,
    mem_scope: []const u8,
    ctrl_cursor: usize,
) InnerResult {
    const gpa = app.gpa;
    const empty: []u8 = &[_]u8{};
    // the last narrated content across tool iterations — the salvage if we exhaust MAX_ITERS or a stop lands mid-loop.
    var last_content: []u8 = empty;
    defer if (last_content.len > 0) gpa.free(last_content);

    // Everything already in conv_buf when this pass begins (system + bounded history + prior drive steps). This
    // pass's tool-call/result growth is measured against it so within-turn compaction can bound just the growth.
    const base_len = conv_buf.items.len;

    var iter: usize = 0;
    while (iter < MAX_ITERS) : (iter += 1) {
        // COOPERATIVE STOP (before each inference): abort with whatever narration we have; the caller commits it.
        if (stopRequestedSince(app, conv_dir, ctrl_cursor))
            return .{ .outcome = .stopped, .content = gpa.dupe(u8, last_content) catch empty };

        // STREAMING: the model's reply + reasoning type out via streamOnDelta as {kind:token|reasoning,delta}
        // frames. The returned Step is the SAME accumulated shape complete() gives (content + reasoning +
        // tool_calls), so everything below is unchanged — and completeStream falls back to complete() itself
        // on any streaming trouble, so a backend that can't stream still works (on_delta just never fires).
        var sctx = StreamCtx{ .app = app, .conv_dir = conv_dir };
        var step = llm.completeStream(gpa, app.io, run_root, "chat", base_url, key, model, conv_buf.items, tools.SCHEMA, 4096, 0.7, &sctx, streamOnDelta);
        defer step.deinit(gpa);
        streamFlush(&sctx); // emit the last buffered <FLUSH_CHARS chunk so the tail of the reply/reasoning isn't lost

        if (!step.ok) {
            emitKV(app, conv_dir, "error", "err", clipBytes(step.content, 400));
            return .{ .outcome = .hard_error, .content = empty };
        }
        // reasoning normally streams via the .reasoning deltas above. But if completeStream FELL BACK to a
        // non-streaming complete() (no deltas fired — e.g. a hosted tool-call step, or a backend that ignored
        // stream:true), emit the reasoning once here so the desk still shows the thinking (no regression).
        if (!sctx.streamed and step.reasoning.len > 0)
            emitKV(app, conv_dir, "reasoning", "delta", clipBytes(step.reasoning, 4000));

        // MARKUP TOOL-CALL RECOVERY: a local gpt-oss/DeepSeek model sometimes emits its tool call as Claude-style
        // XML markup in the CONTENT channel (<｜｜DSML｜｜invoke name="…">) instead of a structured tool_calls entry.
        // The transport then returns it as plain content with NO calls, so no tool runs, the markup leaks into the
        // reply, and the drive loop churns on it ("bad tool requests / janked back and forth"). Recover the call(s)
        // from the markup + strip it from the content, so the tool actually executes and the turn makes progress.
        if (step.calls.len == 0 and cctx.looksLikeToolMarkup(step.content)) {
            if (cctx.recoverMarkupCalls(gpa, step.content)) |rec| {
                var built: std.ArrayListUnmanaged(llm.ToolCall) = .empty;
                for (rec.calls) |rc| {
                    const idc = gpa.dupe(u8, "") catch {
                        gpa.free(rc.name);
                        gpa.free(rc.args);
                        continue;
                    };
                    built.append(gpa, .{ .id = idc, .name = rc.name, .args = rc.args }) catch {
                        gpa.free(idc);
                        gpa.free(rc.name);
                        gpa.free(rc.args);
                    };
                }
                gpa.free(rec.calls); // wrapper array only; name/args ownership moved into `built` (or freed above)
                if (built.items.len == 0) {
                    built.deinit(gpa);
                    gpa.free(rec.stripped); // every append OOM-failed — leave the original content untouched
                } else if (built.toOwnedSlice(gpa)) |owned| {
                    gpa.free(step.content);
                    step.content = rec.stripped; // narration with the markup block removed
                    step.calls = owned; // adopted into the Step; freed by step.deinit
                    var nb: [72]u8 = undefined;
                    emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&nb, "recovered {d} tool call(s) from model markup", .{owned.len}) catch "recovered tool call from markup");
                } else |_| {
                    // OOM finalizing the slice — free each built call + the backing array + the stripped content.
                    for (built.items) |c| {
                        gpa.free(c.id);
                        gpa.free(c.name);
                        gpa.free(c.args);
                    }
                    built.deinit(gpa);
                    gpa.free(rec.stripped);
                }
            }
        }

        if (step.calls.len == 0) // no tool calls — this settled answer is the turn's reply for this drive step.
            return .{ .outcome = .settled, .content = gpa.dupe(u8, step.content) catch empty };

        // remember the last narrated content in case we run out of iterations mid-tool-loop
        if (step.content.len > 0) {
            if (last_content.len > 0) gpa.free(last_content);
            last_content = gpa.dupe(u8, step.content) catch empty;
        }

        // append the assistant tool_call turn to the running context (standard OpenAI tool_calls shape) ...
        conv_buf.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":") catch return .{ .outcome = .hard_error, .content = empty };
        http.jstr(gpa, conv_buf, step.content) catch return .{ .outcome = .hard_error, .content = empty };
        conv_buf.appendSlice(gpa, ",\"tool_calls\":[") catch return .{ .outcome = .hard_error, .content = empty };
        for (step.calls, 0..) |c, i| {
            if (i > 0) conv_buf.append(gpa, ',') catch return .{ .outcome = .hard_error, .content = empty };
            conv_buf.appendSlice(gpa, "{\"id\":") catch return .{ .outcome = .hard_error, .content = empty };
            http.jstr(gpa, conv_buf, c.id) catch return .{ .outcome = .hard_error, .content = empty };
            conv_buf.appendSlice(gpa, ",\"type\":\"function\",\"function\":{\"name\":") catch return .{ .outcome = .hard_error, .content = empty };
            http.jstr(gpa, conv_buf, c.name) catch return .{ .outcome = .hard_error, .content = empty };
            conv_buf.appendSlice(gpa, ",\"arguments\":") catch return .{ .outcome = .hard_error, .content = empty };
            http.jstr(gpa, conv_buf, c.args) catch return .{ .outcome = .hard_error, .content = empty };
            conv_buf.appendSlice(gpa, "}}") catch return .{ .outcome = .hard_error, .content = empty };
        }
        conv_buf.appendSlice(gpa, "]}") catch return .{ .outcome = .hard_error, .content = empty };

        // ... then run each call, narrate + observe its result, and append its result turn.
        for (step.calls) |c| {
            emitToolState(app, conv_dir, c.name, "start", "");
            const result = tools.execute(ctx, c.name, c.args);
            scrubUtf8(result); // fetched bytes may be invalid UTF-8; must be valid before it rides in JSON
            emitToolState(app, conv_dir, c.name, "done", clipBytes(result, 200));

            // HIPPOCAMPUS (observe): a SUCCESSFUL tool finding is durable knowledge. Gate out engine error strings
            // — "(...)" notes and `"ok":false` payloads — and never observe assistant reply content (confab fix).
            if (result.len > 0 and result[0] != '(' and std.mem.indexOf(u8, result, "\"ok\":false") == null)
                observeToolResult(app, ctx, mem_scope, c.name, result);

            // Build the whole tool-result object in a scratch list, then append it to conv_buf in ONE shot. A
            // mid-object OOM must never leave conv_buf as a partial/unterminated object — that malformed JSON would
            // ride into the next completion (a 400) instead of a clean hard_error. On any failure: free + hard_error.
            var toolobj: std.ArrayListUnmanaged(u8) = .empty;
            defer toolobj.deinit(gpa);
            const obj_ok = blk: {
                toolobj.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":") catch break :blk false;
                http.jstr(gpa, &toolobj, c.id) catch break :blk false;
                toolobj.appendSlice(gpa, ",\"content\":") catch break :blk false;
                http.jstr(gpa, &toolobj, result) catch break :blk false;
                toolobj.append(gpa, '}') catch break :blk false;
                conv_buf.appendSlice(gpa, toolobj.items) catch break :blk false;
                break :blk true;
            };
            if (result.len > 0) gpa.free(result); // OOM fallback in execute() can hand back a static "" — don't free that
            if (!obj_ok) return .{ .outcome = .hard_error, .content = empty };
        }
        // WITHIN-TURN COMPACTION (step boundary): if this pass's working growth has crossed the budget, compress it
        // into a progress note so a long/afk turn can keep going without overflowing the model window.
        compactWorking(app, run_root, base_url, key, model, conv_buf, base_len);
        // loop: feed the tool results back for the next completion
    }

    // Ran out of tool iterations mid-loop: ask for a brief no-tools SUMMARY so the reply is a real closing message
    // ("here's what I built…") rather than a raw step-limit string (the shooter turn committed exactly that). Fall
    // back to the last narration, then a friendly note, only if the summary itself fails.
    if (summarizeTurn(app, run_root, base_url, key, model, conv_buf.items)) |sum| return .{ .outcome = .settled, .content = sum };
    const fallback: []const u8 = if (last_content.len > 0) last_content else "I did as much as I could this turn — say \"continue\" if there's more you want.";
    return .{ .outcome = .settled, .content = gpa.dupe(u8, fallback) catch empty };
}

/// A brief no-tools completion asking the model to summarize what it just did — used when the tool loop hits its
/// round cap, so the reply is a real closing message instead of a raw step-limit note. gpa-owned text or null (a
/// failed/empty summary lets the caller fall back to the last narration).
fn summarizeTurn(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, conv_items: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, conv_items) catch return null;
    msgs.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, "In 1-3 sentences, tell the user what you accomplished this turn and what (if anything) remains. Do not call any tools.") catch return null;
    msgs.append(gpa, '}') catch return null;
    var step = llm.complete(gpa, app.io, run_root, "summary", base_url, key, model, msgs.items, "", 1024, 0.5);
    defer step.deinit(gpa);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t");
    if (t.len == 0) return null;
    return gpa.dupe(u8, t) catch null;
}

/// One REFLECT pass: hand the model its own answer + the original question and ask for the final (improved-or-
/// unchanged) text. Fresh minimal context (system + user + assistant + critique), no tools. Returns a gpa-owned
/// improved answer, or null to keep the original (a failed / empty / too-short reply means "leave it alone").
fn reflectAnswer(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, user_text: []const u8, answer: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, SYSTEM_PROMPT) catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, user_text) catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"assistant\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, answer) catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, REFLECT_PROMPT) catch return null;
    msgs.append(gpa, '}') catch return null;
    var step = llm.complete(gpa, app.io, run_root, "reflect", base_url, key, model, msgs.items, "", 4096, 0.5);
    defer step.deinit(gpa);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t");
    if (t.len < REFLECT_MIN) return null; // too short to be a genuine improved answer → keep the original
    return gpa.dupe(u8, t) catch null;
}

/// Observe a SHORT durable note of a successful tool result into the conversation's neuron-db: `tool <name>: <=200b`.
fn observeToolResult(app: *App, ctx: *tools.ToolCtx, mem_scope: []const u8, name: []const u8, result: []const u8) void {
    const gpa = app.gpa;
    const note = std.fmt.allocPrint(gpa, "tool {s}: {s}", .{ name, clipBytes(result, 200) }) catch return;
    defer gpa.free(note);
    _ = ctx.mem.observe(mem_scope, note);
}

/// Current byte length of control.jsonl (0 if absent/unreadable) — the cursor past which a later stop op counts.
fn controlLen(app: *App, conv_dir: []const u8) usize {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{conv_dir}) catch return 0;
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(1 << 20)) catch return 0;
    defer gpa.free(data);
    return data.len;
}

/// True if control.jsonl carries a `"op":"stop"` in the bytes appended AFTER `cursor` (i.e. since the turn began).
/// Best-effort: any read error means "no stop" (never block the turn on a control-file hiccup).
fn stopRequestedSince(app: *App, conv_dir: []const u8, cursor: usize) bool {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{conv_dir}) catch return false;
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(1 << 20)) catch return false;
    defer gpa.free(data);
    if (data.len <= cursor) return false;
    return std.mem.indexOf(u8, data[cursor..], "\"op\":\"stop\"") != null;
}

/// The drive is DONE when the inference's next-step text is exactly a terminal token (desk loopIsDone): trim the
/// chatty punctuation/markers, then case-insensitively match one of the short "finished" words (<=16 bytes).
fn loopIsDone(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n.!\"'`*:");
    if (t.len == 0 or t.len > 16) return false;
    return std.ascii.eqlIgnoreCase(t, "DONE") or
        std.ascii.eqlIgnoreCase(t, "COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "GOAL COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "TASK COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "FINISHED");
}

/// Repeat guard (desk nearlySame): case-insensitive substring containment either way, capped at 400 bytes so it
/// only guards short chatty next-steps, not long build instructions. A near-repeat means the drive isn't
/// progressing, so it stops instead of churning the same step.
fn nearlySame(a_in: []const u8, b_in: []const u8) bool {
    const a = std.mem.trim(u8, a_in, " \r\n\t.!?");
    const b = std.mem.trim(u8, b_in, " \r\n\t.!?");
    if (a.len == 0 or b.len == 0) return false;
    if (a.len > 400 or b.len > 400) return false;
    var la: [400]u8 = undefined;
    var lb: [400]u8 = undefined;
    for (a, 0..) |c, i| la[i] = std.ascii.toLower(c);
    for (b, 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const sa = la[0..a.len];
    const sb = lb[0..b.len];
    return std.mem.indexOf(u8, sa, sb) != null or std.mem.indexOf(u8, sb, sa) != null;
}

/// {"kind":"message","role":"user","content":..}
fn emitUserRole(app: *App, conv_dir: []const u8, content: []const u8) void {
    emitRoleMessage(app, conv_dir, "user", content);
}
/// {"kind":"message","role":"assistant","content":..}
fn emitAssistant(app: *App, conv_dir: []const u8, content: []const u8) void {
    emitRoleMessage(app, conv_dir, "assistant", content);
}
fn emitRoleMessage(app: *App, conv_dir: []const u8, role: []const u8, content: []const u8) void {
    const gpa = app.gpa;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    ev.appendSlice(gpa, "{\"kind\":\"message\",\"role\":") catch return;
    http.jstr(gpa, &ev, role) catch return;
    ev.appendSlice(gpa, ",\"content\":") catch return;
    http.jstr(gpa, &ev, content) catch return;
    ev.append(gpa, '}') catch return;
    emitEvent(app, conv_dir, ev.items);
}

/// {"kind":"tool","tool":<name>,"state":<state>[,"preview":<preview>]}
fn emitToolState(app: *App, conv_dir: []const u8, name: []const u8, state: []const u8, preview: []const u8) void {
    const gpa = app.gpa;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    ev.appendSlice(gpa, "{\"kind\":\"tool\",\"tool\":") catch return;
    http.jstr(gpa, &ev, name) catch return;
    ev.appendSlice(gpa, ",\"state\":") catch return;
    http.jstr(gpa, &ev, state) catch return;
    if (preview.len > 0) {
        ev.appendSlice(gpa, ",\"preview\":") catch return;
        http.jstr(gpa, &ev, preview) catch return;
    }
    ev.append(gpa, '}') catch return;
    emitEvent(app, conv_dir, ev.items);
}

/// Append ONE `,{"role":..,"content":..}` object to conv_buf, built whole in a scratch list first so a mid-object
/// OOM can never leave conv_buf as invalid JSON. `content` is clipped to `cap` bytes (UTF-8 safe via clipBytes).
fn appendMsgObj(gpa: std.mem.Allocator, conv_buf: *std.ArrayListUnmanaged(u8), role: []const u8, content: []const u8, cap: usize) void {
    var obj: std.ArrayListUnmanaged(u8) = .empty;
    defer obj.deinit(gpa);
    obj.appendSlice(gpa, ",{\"role\":") catch return;
    http.jstr(gpa, &obj, role) catch return;
    obj.appendSlice(gpa, ",\"content\":") catch return;
    http.jstr(gpa, &obj, clipBytes(content, cap)) catch return;
    obj.append(gpa, '}') catch return;
    conv_buf.appendSlice(gpa, obj.items) catch return;
}

/// Replay a run of stored messages.jsonl lines (`bytes`) into conv_buf as OpenAI message objects. Each stored line
/// is parsed as JSON (content is UNescaped raw text) and re-emitted via appendMsgObj — round-tripping the escaped-
/// on-disk form through jstr again would double-escape it. `cap` clips each message's content.
fn seedLines(app: *App, conv_buf: *std.ArrayListUnmanaged(u8), bytes: []const u8, cap: usize) void {
    const gpa = app.gpa;
    const M = struct { role: []const u8 = "", content: []const u8 = "" };
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (p.value.content.len == 0) continue;
        // stored role is already an OpenAI role ("user"/"assistant"); anything else falls back to user.
        const role: []const u8 = if (std.mem.eql(u8, p.value.role, "assistant")) "assistant" else "user";
        appendMsgObj(gpa, conv_buf, role, p.value.content, cap);
    }
}

/// Assemble the prior-conversation context into conv_buf under a bounded budget (chat_context): a rolling summary
/// of turns that have scrolled out of the recency window, the pinned original goal, and the recency window itself.
/// Replaces "replay the whole transcript". Best-effort: any read/parse/summary failure degrades to less context,
/// never a crash — the turn still runs on the system prompt + recall + whatever seeded.
fn assembleHistory(app: *App, conv_dir: []const u8, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, user_text: []const u8, conv_buf: *std.ArrayListUnmanaged(u8)) void {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return;
    defer gpa.free(mpath);

    const head_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return;
    defer gpa.free(head_buf);
    const tail_buf = gpa.alloc(u8, cctx.HISTORY_WINDOW_BYTES) catch return;
    defer gpa.free(tail_buf);

    const ht = cctx.readHeadTail(app.io, mpath, head_buf, tail_buf) orelse return; // no history yet → nothing to seed
    const view = cctx.computeView(ht.head, ht.tail, ht.size, cctx.HISTORY_WINDOW_BYTES);

    // ROLLING SUMMARY: when older turns have scrolled past the recency window, inject a condensed running summary
    // of them so continuity survives beyond the window + relevance recall.
    if (view.gap) {
        const sum = loadOrUpdateSummary(app, conv_dir, run_root, base_url, key, model, mpath, view);
        defer if (sum.len > 0) gpa.free(sum);
        if (sum.len > 0) {
            var sc: std.ArrayListUnmanaged(u8) = .empty;
            defer sc.deinit(gpa);
            sc.appendSlice(gpa, "CONVERSATION SUMMARY (older turns of THIS conversation, condensed — everything before the messages shown below). Treat as grounded context:\n") catch {};
            sc.appendSlice(gpa, sum) catch {};
            if (sc.items.len > 0) appendMsgObj(gpa, conv_buf, "system", sc.items, cctx.SUMMARY_INJECT_CAP + 256);
        }
    }

    // PINNED GOAL: the conversation's first user message anchors the arc even after it scrolls out of the window.
    if (view.goal_line.len > 0) seedLines(app, conv_buf, view.goal_line, cctx.GOAL_PIN_CAP);

    // RECENCY WINDOW: replay the newest complete turns verbatim (includes the just-appended user message).
    seedLines(app, conv_buf, view.window, cctx.HISTORY_WINDOW_BYTES);

    // SAFETY NET: an EMPTY window means the newest line (the just-appended current user message) is itself larger
    // than the recency window and fell out — so the live question would ride only on the fallible rolling summary
    // (and be lost entirely if that summary call fails or the message exceeds SUMMARY_SPAN_CAP). Seed the current
    // message verbatim (clipped) so the model always sees the actual question it must answer.
    if (view.window.len == 0) appendMsgObj(gpa, conv_buf, "user", user_text, cctx.CURRENT_MSG_PIN_CAP);
}

/// Load the persisted rolling summary + its coverage cursor from {conv_dir}/context.json, and if the recency
/// window has rolled forward past what the summary covers, fold the newly-dropped span into it (one cheap no-tools
/// completion) and persist the advance. Returns the (gpa-owned) summary text to inject, or an EMPTY slice (never
/// null) when there's nothing / on any failure — the caller frees only a non-empty return.
fn loadOrUpdateSummary(app: *App, conv_dir: []const u8, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, mpath: []const u8, view: cctx.View) []u8 {
    const gpa = app.gpa;
    const empty: []u8 = &[_]u8{};

    // ---- load existing {covered, summary} (absent/garbage → covered 0, empty summary) ----
    var covered: usize = 0;
    var summary: []u8 = empty; // gpa-owned once duped below
    const cpath = std.fmt.allocPrint(gpa, "{s}/context.json", .{conv_dir}) catch return empty;
    defer gpa.free(cpath);
    if (std.Io.Dir.cwd().readFileAlloc(app.io, cpath, gpa, .limited(1 << 20))) |raw| {
        defer gpa.free(raw);
        const S = struct { covered: usize = 0, summary: []const u8 = "" };
        if (std.json.parseFromSlice(S, gpa, raw, .{ .ignore_unknown_fields = true })) |p| {
            defer p.deinit();
            covered = p.value.covered;
            if (p.value.summary.len > 0) summary = gpa.dupe(u8, p.value.summary) catch empty;
        } else |_| {}
    } else |_| {}

    // ---- is there newly-dropped history to fold in? summary should cover [goal_end, window_start) ----
    const target = view.window_start;
    const span_from = @max(covered, view.goal_end);
    if (target <= span_from) return summary; // already covered (or no middle) → inject what we have

    const span_buf = gpa.alloc(u8, cctx.SUMMARY_SPAN_CAP) catch return summary;
    defer gpa.free(span_buf);
    const span = cctx.readSpanTailTrimmed(app.io, mpath, span_from, target, span_buf) orelse return summary;
    if (span.len == 0) return summary;

    const updated = summarizeInto(app, run_root, base_url, key, model, summary, span) orelse return summary;
    persistSummary(app, cpath, target, updated); // best-effort; even if the write fails we still inject `updated`
    if (summary.len > 0) gpa.free(summary);
    return updated;
}

/// One no-tools completion that rewrites the running summary to incorporate a span of just-dropped messages.
/// gpa-owned new summary (clipped) or null on failure. Kept deterministic (low temp) and short.
fn summarizeInto(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, prior_summary: []const u8, span_json: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, "You maintain a running summary of a long assistant/user conversation so older turns can be dropped from the live context without losing continuity. Be faithful and concise; preserve concrete facts, decisions, file names, and open threads. Output ONLY the updated summary, no preamble.") catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    var uc: std.ArrayListUnmanaged(u8) = .empty;
    defer uc.deinit(gpa);
    uc.appendSlice(gpa, "Running summary so far:\n") catch return null;
    uc.appendSlice(gpa, if (prior_summary.len > 0) prior_summary else "(none yet)") catch return null;
    uc.appendSlice(gpa, "\n\nOlder conversation messages now scrolling out of the live window (JSON lines, oldest to newest):\n") catch return null;
    uc.appendSlice(gpa, span_json) catch return null;
    uc.appendSlice(gpa, "\n\nRewrite the running summary to incorporate these messages. Keep it under 250 words.") catch return null;
    http.jstr(gpa, &msgs, uc.items) catch return null;
    msgs.append(gpa, '}') catch return null;
    var step = llm.complete(gpa, app.io, run_root, "ctxsum", base_url, key, model, msgs.items, "", 1024, 0.3);
    defer step.deinit(gpa);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t");
    if (t.len == 0) return null;
    return gpa.dupe(u8, clipBytes(t, cctx.SUMMARY_INJECT_CAP)) catch null;
}

/// Persist {covered, summary} to context.json as one atomic overwrite (whole line built first). Best-effort.
fn persistSummary(app: *App, cpath: []const u8, covered: usize, summary: []const u8) void {
    const gpa = app.gpa;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const head = std.fmt.allocPrint(gpa, "{{\"covered\":{d},\"summary\":", .{covered}) catch return;
    defer gpa.free(head);
    out.appendSlice(gpa, head) catch return;
    http.jstr(gpa, &out, summary) catch return;
    out.append(gpa, '}') catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = cpath, .data = out.items }) catch {};
}

/// One no-tools completion that compresses the CURRENT turn's working log (assistant tool_call turns + tool
/// results appended since the pass began) into a short progress note, so a long/afk turn can keep going without
/// its single-turn buffer overflowing the model window. gpa-owned note (clipped) or null on failure.
fn summarizeWorkingSpan(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, span_json: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, "You compress the working log of an in-progress task so it can continue without exceeding the context window. Preserve concrete progress: files created/edited, commands run and their key results, decisions made, and what remains. Output ONLY the compressed progress note.") catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    var uc: std.ArrayListUnmanaged(u8) = .empty;
    defer uc.deinit(gpa);
    uc.appendSlice(gpa, "Working log so far (assistant tool calls + tool results as JSON):\n") catch return null;
    uc.appendSlice(gpa, clipBytes(span_json, 200 * 1024)) catch return null; // bound the summarizer's own input
    uc.appendSlice(gpa, "\n\nWrite the compressed progress note (<= 200 words).") catch return null;
    http.jstr(gpa, &msgs, uc.items) catch return null;
    msgs.append(gpa, '}') catch return null;
    var step = llm.complete(gpa, app.io, run_root, "compact", base_url, key, model, msgs.items, "", 1024, 0.3);
    defer step.deinit(gpa);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t");
    if (t.len == 0) return null;
    return gpa.dupe(u8, clipBytes(t, cctx.SUMMARY_INJECT_CAP)) catch null;
}

/// If this pass's working growth (everything appended after `base_len`) exceeds WORKING_COMPACT_BYTES, replace it
/// with a single compressed progress note so the loop can continue bounded. Called at a STEP BOUNDARY (after all of
/// a step's tool results are appended), so the message sequence stays protocol-valid (no dangling tool_calls).
/// Best-effort: a failed summary leaves the buffer as-is (the MAX_ITERS cap still bounds the pass).
fn compactWorking(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, conv_buf: *std.ArrayListUnmanaged(u8), base_len: usize) void {
    if (conv_buf.items.len <= base_len or conv_buf.items.len - base_len <= cctx.WORKING_COMPACT_BYTES) return;
    const gpa = app.gpa;
    const note = summarizeWorkingSpan(app, run_root, base_url, key, model, conv_buf.items[base_len..]) orelse return;
    defer gpa.free(note);
    conv_buf.shrinkRetainingCapacity(base_len);
    appendMsgObj(gpa, conv_buf, "assistant", note, cctx.SUMMARY_INJECT_CAP);
}
