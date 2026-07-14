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

const App = http.App;

/// Hard ceiling on tool-calling round-trips per ONE settled answer — the same bound the worker's round loop
/// keeps, so a model that loops on tools can never wedge the httpz worker thread indefinitely.
const MAX_ITERS: usize = 12;

/// Hard ceiling on AUTO-LOOP drive steps in one turn — after each settled answer the engine infers the next
/// step and drives again, up to this many times (desk's LOOP_MAX_ITERS). A plain Q&A stops after one step
/// because the drive inference returns DONE for an achieved goal; this bound only caps a genuine multi-step build.
const DRIVE_MAX: usize = 30;

/// The single question the drive inference answers between settled steps: it either names the next concrete
/// step (which becomes a synthetic user turn) or replies DONE. Carries the LOOP_SYSTEM intent inline rather than
/// swapping the system prompt (a server-turn simplification of desk's dedicated LOOP_SYSTEM driver turn).
const LOOP_QUESTION =
    "What is the single next concrete step toward the goal? Reply with ONLY that next instruction, or reply " ++
    "exactly DONE if the goal is fully achieved.";

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
    seedPriorMessages(app, conv_dir, &conv_buf);

    // HIPPOCAMPUS (observe): the user's own turn is durable knowledge — store it so a later turn can recall it.
    // We NEVER observe the veil's assistant replies (only user turns + tool results); self-observing generated
    // text then recalling it as "grounded context" is the parrot/confabulation loop the desk fix removed.
    _ = ctx.mem.observe(mem_scope, user_text);

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

        // Run one agentic tool pass to a SETTLED (no-tool-call) answer.
        const inner = runInnerAgentic(app, conv_dir, run_root, base_url, key, model, &conv_buf, &ctx, mem_scope, ctrl_cursor);
        switch (inner.outcome) {
            .hard_error => return, // the inference failed — helper already emitted the error event; end the turn
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
        const answer = inner.content;
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
        // STOP the drive when the goal is achieved (DONE), the inference is empty/failed, or the next step just
        // repeats the last one (no progress) — the settled answer above is the turn's final reply.
        if (!next.ok or trimmed.len == 0 or loopIsDone(next.content) or nearlySame(trimmed, prev_drive)) break :outer;

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

    var iter: usize = 0;
    while (iter < MAX_ITERS) : (iter += 1) {
        // COOPERATIVE STOP (before each inference): abort with whatever narration we have; the caller commits it.
        if (stopRequestedSince(app, conv_dir, ctrl_cursor))
            return .{ .outcome = .stopped, .content = gpa.dupe(u8, last_content) catch empty };

        var step = llm.complete(gpa, app.io, run_root, "chat", base_url, key, model, conv_buf.items, tools.SCHEMA, 4096, 0.7);
        defer step.deinit(gpa);

        if (!step.ok) {
            emitKV(app, conv_dir, "error", "err", clipBytes(step.content, 400));
            return .{ .outcome = .hard_error, .content = empty };
        }
        if (step.reasoning.len > 0) emitKV(app, conv_dir, "reasoning", "delta", clipBytes(step.reasoning, 2000));

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

            conv_buf.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":") catch {
                if (result.len > 0) gpa.free(result);
                return .{ .outcome = .hard_error, .content = empty };
            };
            http.jstr(gpa, conv_buf, c.id) catch {};
            conv_buf.appendSlice(gpa, ",\"content\":") catch {};
            http.jstr(gpa, conv_buf, result) catch {};
            conv_buf.append(gpa, '}') catch {};
            if (result.len > 0) gpa.free(result); // OOM fallback in execute() can hand back a static "" — don't free that
        }
        // loop: feed the tool results back for the next completion
    }

    // ran out of tool iterations mid-loop: hand the last narration (or a placeholder) back as the settled answer.
    const fallback: []const u8 = if (last_content.len > 0) last_content else "(reached the step limit for this turn)";
    return .{ .outcome = .settled, .content = gpa.dupe(u8, fallback) catch empty };
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

/// Rebuild the prior conversation from messages.jsonl into `conv_buf` as OpenAI message objects. Each stored
/// line is parsed as JSON (so its content is UNescaped raw text) and re-emitted via jstr — round-tripping the
/// escaped-on-disk form through jstr again would double-escape it.
fn seedPriorMessages(app: *App, conv_dir: []const u8, conv_buf: *std.ArrayListUnmanaged(u8)) void {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return;
    defer gpa.free(mpath);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, mpath, gpa, .limited(8 << 20)) catch return;
    defer gpa.free(data);

    const M = struct { role: []const u8 = "", content: []const u8 = "" };
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (p.value.content.len == 0) continue;
        // stored role is already an OpenAI role ("user"/"assistant"); anything else falls back to user.
        const role: []const u8 = if (std.mem.eql(u8, p.value.role, "assistant")) "assistant" else "user";
        conv_buf.appendSlice(gpa, ",{\"role\":") catch return;
        http.jstr(gpa, conv_buf, role) catch return;
        conv_buf.appendSlice(gpa, ",\"content\":") catch return;
        http.jstr(gpa, conv_buf, p.value.content) catch return;
        conv_buf.append(gpa, '}') catch return;
    }
}
