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
const builtin = @import("builtin");
const http = @import("../../gateway/http.zig");
const tools = @import("../tools.zig");
const osc = @import("../oscillation.zig");
const llm = @import("../llm.zig");
const cctx = @import("context.zig");
const cplan = @import("plan.zig");
const cync = @import("sync.zig");
const deploy_service = @import("../deploy/service.zig");
const sched = @import("../sched.zig"); // mutual import (sched spawns turns here); Zig resolves it lazily
const metrics = @import("../metrics.zig"); // per-turn LLM usage lines behind the desk Dashboard

// Raw-thread sleep (supervisor.zig's threadSleepMs twin): the chat turn runs on a raw detached std.Thread
// (spawnTurn), where io.sleep throws and a swallowed error busy-spins a core. Win32 Sleep on Windows.
const winsleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
} else struct {};
fn sleepMsRaw(io: std.Io, ms: u64) void {
    if (builtin.os.tag == .windows) {
        winsleep.Sleep(@intCast(ms));
    } else {
        io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
    }
}

const App = http.App;

/// Hard ceiling on tool-calling round-trips per ONE settled answer. 24 comfortably fits a big single-turn build
/// (a three.js game is many write_file + read_file + edit_file rounds); the outer DRIVE_MAX still bounds the whole
/// turn, and a genuine runaway summarizes (below) rather than committing a raw step-limit string.
const MAX_ITERS: usize = 24;

/// Hard ceiling on AUTO-LOOP drive steps in one turn when the loop is OFF (loop=0). Kept low (6): a higher cap
/// lets a thorough model "verify" and re-read forever after a fix, while 6 still fits a build + a couple of
/// follow-through steps and a plain Q&A stops after one (DONE). The user's Stop reaches the turn (control.jsonl),
/// and MAX_ITERS bounds each step's tool rounds.
const DRIVE_MAX: usize = 6;

/// AUTO-LOOP mode (the desk's chat_loop / chat_loop_afk tiers, now driven SERVER-side). off = a normal bounded
/// turn; on = the veil writes its own next step and drives toward the goal until DONE / no-progress / the cap;
/// afk = the persistent tier — it NEVER accepts an end state (DONE folds into a re-verify+extend drive, the repeat
/// guard is skipped, the cap wraps), so only the user's Stop ends it. Passed on the /messages body (loop: 0|1|2).
const LOOP_OFF: u8 = 0;
const LOOP_ON: u8 = 1;
const LOOP_AFK: u8 = 2;
/// Drive-step cap for loop=ON (desk LOOP_MAX_ITERS): a long autonomous task needs many steps, but a non-afk loop
/// still terminates on its own (DONE / two idle steps / repeat) well before this — it's the runaway backstop.
const LOOP_MAX_STEPS: usize = 30;
/// Drive-step cap for loop=AFK: effectively unbounded (the user explicitly opted into "run until I Stop"). Every
/// step drains control (Stop exits promptly) and compacts the working context, so this large bound is a pure
/// runaway backstop, not a functional limit.
const AFK_MAX_STEPS: usize = 100_000;
/// What loop=AFK injects as the next drive step when the driver declares DONE — the afk tier never accepts an end
/// state, so "done" becomes a re-verify + extend (desk AFK_DRIVE_MSG). RE-GROUNDED to the goal at runtime so the
/// persistent loop can't drift off onto an unrelated task. Only the user's Stop ends afk.
const AFK_DRIVE_TMPL = "Keep going toward the goal: \"{s}\". Re-verify the latest work end-to-end, then pick the single most valuable next improvement or extension TOWARD THAT GOAL and do it now.";
/// What an AFK loop injects when its next step just REPEATS the last one (afk skips the repeat-guard that ends a
/// non-afk loop, so instead of churning the same failing step it steps back, re-grounds, and researches the blocker
/// — the light server-side form of the desk's stuck->research escalation, using the model's own recall/search tools.
const AFK_STUCK_TMPL = "You just repeated the previous step — that is not making progress. STOP repeating it: re-read the goal, and try a DIFFERENT approach. If you're blocked, first recall_hive / web_search the ACTUAL error or unknown, then act on what you learn. Goal: \"{s}\".";
/// TERMINAL BUILD-VERIFY (desk fireTerminalVerify): an armed loop must not accept a bare DONE right after writing
/// files — a model can ANNOUNCE a build it didn't finish. One completeness check (run the tests / write any missing
/// file) is injected before the loop ends; it fires at most once per turn and only when files were actually written.
const TERMINAL_VERIFY_PROMPT = "Before calling this done, VERIFY the deliverable actually works: run_tests (or run the code with run_python) to confirm it runs, and if any file the goal requires is missing or empty, write it NOW (write_file). If everything is present and works, give your FINAL summary to the user with no further tool calls — do not rewrite files that are already correct.";

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
/// PLAN-BOARD: how many subtasks one turn works before pausing (the plan persists, so "continue" resumes the
/// rest). Bounds a big plan's turn length — each subtask is a full agentic pass, so this * MAX_ITERS is the ceiling.
const PLAN_STEPS_PER_TURN: usize = 8;
const PLAN_PROMPT =
    "Decompose the user's request into an ordered list of concrete subtasks, and for EACH pick the best ROUTE: " ++
    "\"hive\" (delegate to a swarm of AI minds — a big or parallelizable build/research chunk), \"research\" (you " ++
    "need to learn or look something up first), or \"inline\" (a small, direct step you just do yourself). Reply " ++
    "with ONLY compact JSON: {\"plan\":[{\"task\":\"…\",\"route\":\"hive|research|inline\"}, …]}. If the request " ++
    "is a simple question, a greeting, or a single trivial step that needs no plan, reply exactly {\"plan\":[]}.";

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
    "prose. Keep answers concrete and grounded in what the tools actually returned.\n" ++
    "HOW YOU WORK A TASK. Your FIRST move on any non-trivial request is to BREAK IT DOWN into a concrete list of " ++
    "smaller subtasks -- however many it takes, a handful or dozens -- and show the user that plan. Then work the " ++
    "list, and for EACH subtask decide the best route: (a) DELEGATE TO A HIVE -- if a team building or " ++
    "researching in parallel would do it better or faster, `cast` a swarm for that part (it builds in THIS " ++
    "conversation, so its files sit alongside yours), then GUIDE that swarm: `swarm_status` to see how it's " ++
    "doing, `steer_swarm` to send its minds a live directive or retarget their goal, `swarm_asks` to see " ++
    "questions its minds raised for you and `answer_swarm` to unblock them, `stop_swarm` when it's done or off " ++
    "track. When a user asks you to \"use a hive\", do exactly that -- cast one, don't build it yourself. " ++
    "(b) LEARN FIRST -- if you're missing knowledge for a part, research it (web_search / read_url / recall_hive) " ++
    "BEFORE acting instead of guessing. (c) DO IT YOURSELF -- for a small, direct change, build it inline " ++
    "(write_file / edit_file / run_python). Revise the plan as you learn. Keep coordinating -- casting, steering, " ++
    "researching, building -- and narrate each move so the user can follow the work, until the goal is truly met.\n" ++
    "GROUND YOURSELF -- you have NO live knowledge of the current world. For anything time-sensitive or that could " ++
    "have changed (news, events, prices, versions, releases, 'latest'/'today'/'now', who currently holds a role), " ++
    "OR a specialized/unfamiliar domain you are about to build in, recall_hive first and, if that is thin, " ++
    "web_search -- then answer FROM what you find. NEVER fabricate current events, dates, statistics, or news; if " ++
    "you cannot answer from durable general knowledge with high confidence, look it up instead of guessing.\n" ++
    "CASTING. A `cast` swarm is a parallel SUB-AGENT -- reach for it when many minds beat one: broad web research " ++
    "and current events, scouting unfamiliar tech before you build, analyzing a large body of material. A quick " ++
    "strike runs a couple of minutes; for a GENUINELY BIG job the user wants the hive to own (deep-dive + document " ++
    "a whole codebase, a long investigation, a full app) cast a SUSTAINED hive (mode \"continuous\", enough " ++
    "`minutes`) with a CONCRETE goal and the exact deliverable `files` declared -- do not grind a big job yourself " ++
    "one step at a time. For a small, direct change, build it inline yourself (you are faster and more reliable " ++
    "hands-on). An explicit 'cast a swarm' / 'use a hive' is a COMMAND -- do it. While a hive runs you are its " ++
    "ORCHESTRATOR: swarm_status to watch it, steer_swarm when it drifts, answer_swarm to unblock a mind; never " ++
    "build a rival copy of what it is mid-way through; when it finishes, gather its files/findings and answer from " ++
    "them. Do not cast for greetings, small talk, or timeless facts you know confidently.\n" ++
    "ACT, DON'T PROMISE -- never end a reply with a promise of future action ('I'll run...', 'Let me check...') " ++
    "without the tool call in the SAME reply: every reply either calls a tool or delivers the result. After an " ++
    "action that CHANGES something, VERIFY the outcome before declaring success -- run_tests, or read the resource " ++
    "back; a 'Ready' log line or a 2xx status is not proof it persisted.\n" ++
    "BUILD DISCIPLINE -- write code to FILES with write_file/edit_file, do not paste whole files into the chat. " ++
    "DON'T THRASH: once a file is written, do not rewrite the whole thing next turn -- if it is correct, move to " ++
    "the next file/step; if it needs a change, edit_file the specific part. read_file before you edit. After " ++
    "writing code, run_tests (or run_python) to verify, read the result, fix, and repeat until it actually works.\n" ++
    "DURABLE MEMORY. Anything PERSONAL to THIS user that should persist across conversations -- a key, login, " ++
    "credential, preference, or a fact about them or their environment -- record with a `REMEMBER:` line, NOT " ++
    "observe (observe is the shared hive's knowledge). Format, one per line, alongside your normal reply:\n" ++
    "REMEMBER: [category] the fact to keep   (category is one word: key, login, preference, or fact)\n" ++
    "To drop a fact that is now wrong: `FORGET: <a few words identifying it>`. These lines are STRIPPED from what " ++
    "the user sees, so do NOT also write a prose header like \"I've remembered:\" -- just emit the bare REMEMBER:/" ++
    "FORGET: line(s). Use them proactively when the user reveals a durable fact (e.g. they mention deploying to " ++
    "us-west-2 -> `REMEMBER: [preference] deploys to us-west-2`). Facts already under YOUR MEMORY need no repeat.";

/// The chat turn's tool surface = the shared mind-tool SCHEMA + the veil's ORCHESTRATION verbs (cast / steer /
/// stop / status). The orchestration verbs are handled in-process by orchTool (deploy_service + app.sup), NOT by
/// tools.execute — the swarm minds themselves never get these (a mind can't spawn sibling swarms). Comptime
/// concatenation (both are comptime `\\` strings), joined by a comma into the "tools":[ … ] array body.
const ORCH_TOOLS =
    \\{"type":"function","function":{"name":"cast","description":"Deploy a SWARM (a hive of AI minds) to work on a goal in parallel, in THIS conversation's build dir so its files co-exist with yours. Use for a big or parallelizable build/research task you want a team to carry out while you guide them. Returns a swarm id; watch it with swarm_status, guide it with steer_swarm, end it with stop_swarm.","parameters":{"type":"object","properties":{"goal":{"type":"string","description":"what the swarm should accomplish"},"minds":{"type":"integer","description":"how many minds (default 3)"},"minutes":{"type":"integer","description":"time budget (0 = server default)"},"mode":{"type":"string","enum":["cast","continuous"],"description":"cast = fast one-shot strike; continuous = sustained hive"},"files":{"type":"string","description":"declared deliverable files, comma/newline separated — adopted verbatim as the blueprint"}},"required":["goal"]}}},
    \\{"type":"function","function":{"name":"steer_swarm","description":"Send LIVE guidance to a RUNNING swarm — a priority directive every mind reads at its next round (course-correct, add a constraint, unblock a mind). Or pass `goal` to retarget the whole hive.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id from cast/swarm_status"},"text":{"type":"string","description":"the guidance/directive for the minds"},"goal":{"type":"string","description":"optional: a new goal to retarget the hive"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"stop_swarm","description":"Stop a running swarm (cooperative; takes effect at its next round). Its files + findings are kept.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"swarm_status","description":"Check a swarm's state: whether it is running or finished, how many minds, and whether it has produced a result yet.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"swarm_asks","description":"List the OPEN questions a running swarm's minds have raised for you (via their ask_veil tool) and not yet been answered. Check this while a swarm runs — a mind may be blocked waiting on a decision only you can make. Each ask has an ask_id, the mind that asked, and the question.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"answer_swarm","description":"Answer a mind's open question (from swarm_asks). Your answer lands in that mind's inbox as a priority directive on its next round, unblocking it.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id"},"ask_id":{"type":"string","description":"the ask_id from swarm_asks"},"mind":{"type":"string","description":"the mind that asked (from swarm_asks)"},"text":{"type":"string","description":"your answer/decision for the mind"}},"required":["id","ask_id","mind","text"]}}},
    \\{"type":"function","function":{"name":"schedule_task","description":"Create a SCHEDULED TASK when the user asks for something to happen later or repeatedly ('every morning at 9', 'in 20 minutes', 'daily news digest'). Each firing runs a fresh UNATTENDED chat turn with this same provider, and the task keeps its own memory across runs. The prompt must be SELF-CONTAINED (a run cannot see this conversation) — put concrete specifics (locations, formats, file names) in details. kind 'once' needs in_min OR at_hm; 'every' needs every_min; 'daily' needs hm.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"short task name"},"prompt":{"type":"string","description":"the self-contained instruction each run executes"},"details":{"type":"string","description":"pinned specifics every run should use (optional)"},"kind":{"type":"string","enum":["once","every","daily"]},"in_min":{"type":"integer","description":"once: fire this many minutes from now"},"at_hm":{"type":"string","description":"once: fire at the next local occurrence of HH:MM"},"every_min":{"type":"integer","description":"every: interval in minutes"},"hm":{"type":"string","description":"daily: local wall-clock HH:MM"}},"required":["name","prompt","kind"]}}},
    \\{"type":"function","function":{"name":"schedule_list","description":"List the user's scheduled tasks (id, name, kind, next due, run count, enabled) — check before creating a duplicate, and to find ids for schedule_delete.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"schedule_delete","description":"Delete a scheduled task by its id (from schedule_list). Use when the user asks to cancel/remove a schedule.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the task id"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"sync_dir","description":"PROJECT a folder from the user's machine into this conversation's workdir (read-only copy, hash-diffed: only changed files transfer, the source is NEVER written back to). Use when the user points you at a project that lives OUTSIDE the workdir — an app inside a game-engine folder, a repo elsewhere on disk, an immutable system — so you AND any hive you cast can work with its files. Re-run it to refresh (cheap: unchanged files skip). Text files only, capped 64 files / 4MB — project the SPECIFIC subfolder that matters, not a whole engine install.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"ABSOLUTE folder on the user's machine (e.g. C:/dev/mygame/src or /home/u/app — no ~, expand it first)"},"as":{"type":"string","description":"optional folder name inside the workdir (default: the source folder's name)"}},"required":["path"]}}}
;
// The chat surface = the REACHABLE mind-tool subset (tools.CHAT_SCHEMA, not the full ~33-tool SCHEMA whose
// swarm-mind/host-sim/RSI-only verbs a solo chat turn can't use) + the veil's orchestration verbs. Trimming the
// unreachable tools roughly halves the cold-cache prefill re-sent on every drive step and stops the model emitting
// an off-surface tool call that would burn a whole agentic round-trip. tools.execute still dispatches the full
// SCHEMA, so nothing breaks if a tool is ever re-advertised. See tools.CHAT_SCHEMA for the exact keep-set + why.
const TURN_TOOLS = tools.CHAT_SCHEMA ++ "," ++ ORCH_TOOLS;

/// io-based wall clock — the SAME source the worker stamps its event `t` with (std time under io, never a raw
/// clock primitive). Seconds are fine: the P0-4 reader only maxes `ts` for a conv's `updated`, so ties are OK.
fn nowSecs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Replace each byte not part of a valid UTF-8 sequence with '?' in place (length-preserving), so arbitrary
/// tool output (fetched page bytes) always serializes as conformant JSON. Local copy of chat_tools.scrubUtf8.
/// The task id inside a scheduled-run conv id ("scheduled_{taskid}_MMDDHHMM") — null for ordinary convs.
/// Drives the per-TASK memory scope: runs of the same task share one partition across conversations.
fn schedTaskOf(conv: []const u8) ?[]const u8 {
    const prefix = "scheduled_";
    if (!std.mem.startsWith(u8, conv, prefix)) return null;
    const rest = conv[prefix.len..];
    if (rest.len == 0) return null;
    const us = std.mem.lastIndexOfScalar(u8, rest, '_') orelse return rest;
    if (us == 0) return null;
    return rest[0..us];
}

test "schedTaskOf: extracts the task id from a run conv, null for ordinary convs" {
    try std.testing.expectEqualStrings("news-0715174857", schedTaskOf("scheduled_news-0715174857_07151753").?);
    try std.testing.expectEqualStrings("daily-report-0301070500", schedTaskOf("scheduled_daily-report-0301070500_03010705").?);
    try std.testing.expect(schedTaskOf("c6a57f852") == null);
    try std.testing.expect(schedTaskOf("scheduled_") == null);
}

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

/// Emit the turn's token USAGE (the delta of the process token counters since `t0`, i.e. this turn's tokens) as a
/// `{"kind":"usage",...}` frame. Snapshotted BEFORE any deferred end-of-turn maintenance (the rolling-summary
/// refresh) so the displayed usage reflects the ANSWER's tokens, not background summarization. Zero delta = no frame.
fn emitUsage(app: *App, conv_dir: []const u8, t0: llm.TokUsage) void {
    const t1 = llm.tokensSnapshot();
    const din = if (t1.in >= t0.in) t1.in - t0.in else 0;
    const dout = if (t1.out >= t0.out) t1.out - t0.out else 0;
    if (din > 0 or dout > 0) {
        var b: [160]u8 = undefined;
        emitEvent(app, conv_dir, std.fmt.bufPrint(&b, "{{\"kind\":\"usage\",\"tokens_in\":{d},\"tokens_out\":{d},\"text\":\"{d} tokens in · {d} out\"}}", .{ din, dout, din, dout }) catch "{\"kind\":\"usage\"}");
        metrics.record(app, din, dout, nowSecs(app.io)); // one Dashboard metrics line per finished turn
    }
}

/// Emit the turn's usage then the terminal `{"kind":"done"}`. Used at the STOP / error / empty completion paths
/// (which must end promptly — no deferred summary work). The NORMAL completion path emits usage, runs the deferred
/// summary refresh, THEN done inline (so {done} still comes last), instead of calling this.
fn finishTurn(app: *App, conv_dir: []const u8, t0: llm.TokUsage) void {
    emitUsage(app, conv_dir, t0);
    emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
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
pub fn runTurn(app: *App, uid: u64, conv: []const u8, base_url: []const u8, key: []const u8, model: []const u8, user_text: []const u8, loop: u8, tool_client: bool) void {
    const gpa = app.gpa;

    // Arm this thread's LLM-usage recorder: emitUsage (the one usage choke-point, reached on every turn
    // completion path) records one per-model metrics line for the Dashboard. Thread-local, so none of the
    // eleven finish paths needs the model/uid threaded through.
    metrics.beginTurn(uid, model, base_url, schedTaskOf(conv) != null, nowSecs(app.io));
    defer metrics.endTurn();

    // ---- store + build paths (conv store under convs/, build tree under builds/ — same split as runMindTool) ----
    const base = std.fmt.allocPrint(gpa, "{s}/u{d}/_chat", .{ app.data, uid }) catch return;
    defer gpa.free(base);
    const conv_dir = std.fmt.allocPrint(gpa, "{s}/convs/{s}", .{ base, conv }) catch return;
    defer gpa.free(conv_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, conv_dir, .default_dir) catch {};

    // ---- HIPPOCAMPUS scope: this conversation's own durable neuron-db partition (user turns + tool findings).
    // SCHEDULED RUNS get a TASK-scoped partition instead: every run of "scheduled_{taskid}_{stamp}" shares
    // "sched:{taskid}", so the recall at run start surfaces previous runs' lessons/answers and everything this
    // run observes (the prompt, tool findings, the model's own observe() calls) persists into the NEXT run —
    // the task learns from its own failures and successes across runs, independent of any one conversation.
    const sched_task = schedTaskOf(conv);
    const mem_scope = if (sched_task) |tid|
        (std.fmt.allocPrint(gpa, "sched:{s}", .{tid}) catch return)
    else
        (std.fmt.allocPrint(gpa, "chat:{s}", .{conv}) catch return);
    defer gpa.free(mem_scope);

    // ---- COOPERATIVE-STOP cursor: only control.jsonl ops written AFTER this byte offset count for THIS turn ----
    const ctrl_cursor = controlLen(app, conv_dir);

    // CLIENT-MODE: truncate the delegated-tool-results channel so this turn's readToolResult scan starts clean
    // (results are keyed by call id, but resetting keeps the file from growing across a long conversation).
    if (tool_client) {
        if (std.fmt.allocPrint(gpa, "{s}/tool_results.jsonl", .{conv_dir})) |trp| {
            defer gpa.free(trp);
            std.Io.Dir.cwd().deleteFile(app.io, trp) catch {};
        } else |_| {}
    }

    // ---- record the user's message BEFORE anything else, so it's durable even if the LLM call dies ----
    appendMsg(app, conv_dir, "user", user_text, "user", nowSecs(app.io));
    emitUserRole(app, conv_dir, user_text); // {"kind":"message","role":"user","content":..}

    const environ = app.sup.parent_env orelse {
        emitKV(app, conv_dir, "error", "err", "server env unavailable");
        emitEvent(app, conv_dir, "{\"kind\":\"done\"}"); // the desk disarms only on {done}; an error alone would hang it
        return;
    };

    // USAGE: snapshot the process token counters BEFORE any LLM work (plan decomposition, history summary, drive,
    // reflect, the agentic loop) — finishTurn emits the delta as this turn's usage at every completion path.
    const usage_t0 = llm.tokensSnapshot();

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
        // a scheduled run's recall()/observe() tools work the TASK's own memory (the observe tool already
        // dual-writes the hive, giving "task memory AND hive memory" for free); ordinary chat keeps the
        // shared "chat" scope. DIRECTORY ISOLATION (strict): a scheduled run executes tools SERVER-side with
        // roam=false (the ToolCtx default — only the client executor ever sets it), so every file tool is
        // jailed to this run's builds/{conv}/work by safeRel, exactly like a chat. An unattended run can
        // never write outside its own workdir.
        .scope = if (sched_task != null) mem_scope else "chat",
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
    // — earlier turns + tool findings, including ones evicted from the visible history. Built into a standalone
    // fragment and handed to assembleHistory, which places it AFTER the stable prefix (system + durable memory +
    // summary + goal) and right before the recency window: recall varies with every message, and injecting it
    // early invalidated the provider's prompt-prefix cache for everything behind it (the whole window re-billed
    // as fresh prefill on every inference). Additive: empty/failed recall changes nothing.
    var recall_frag: std.ArrayListUnmanaged(u8) = .empty;
    defer recall_frag.deinit(gpa);
    {
        const recalled = ctx.mem.recall(mem_scope, user_text);
        defer gpa.free(recalled);
        if (recalled.len > 0) {
            scrubUtf8(recalled); // observed facts are already scrubbed, but a fetched-byte tail could slip in
            var mem_content: std.ArrayListUnmanaged(u8) = .empty;
            defer mem_content.deinit(gpa);
            mem_content.appendSlice(gpa, if (sched_task != null)
                "TASK MEMORY — lessons, outcomes, and findings from PREVIOUS RUNS of this scheduled task. USE them: prefer sources/approaches that worked, skip recorded pitfalls, keep stated assumptions, and improve on the last run instead of starting from zero:\n"
            else
                "RELEVANT MEMORY (recalled from this conversation's memory — earlier turns, tool findings). Treat as grounded context:\n") catch return;
            mem_content.appendSlice(gpa, recalled) catch return;
            recall_frag.appendSlice(gpa, ",{\"role\":\"system\",\"content\":") catch return;
            http.jstr(gpa, &recall_frag, mem_content.items) catch return;
            recall_frag.append(gpa, '}') catch return;
        }
    }
    // DURABLE USER MEMORY: inject the user's cross-conversation facts (keys/logins/preferences) from the shared
    // memories.jsonl — the desk's "YOUR MEMORY" block, which a server-served conv never had.
    injectDurableMemory(app, &conv_buf);
    // BOUNDED HISTORY (chat_context): instead of replaying the entire transcript (which overflowed the model
    // window on long chats and hit an 8 MiB read cliff), project it into a fixed budget — a rolling summary of
    // scrolled-out turns + the pinned goal + the recall fragment + a recency window of the newest turns.
    assembleHistory(app, conv_dir, user_text, &conv_buf, recall_frag.items);

    // HIPPOCAMPUS (observe): the user's own turn is durable knowledge — store it so a later turn can recall it.
    // We NEVER observe the veil's assistant replies (only user turns + tool results); self-observing generated
    // text then recalling it as "grounded context" is a parrot/confabulation loop.
    // DEFERRED to turn exit (a `defer` covers every completion path): the observe is a subprocess spawn that sat
    // between prefix assembly and the first inference — pure write-side durability nothing in THIS turn reads
    // (recall already ran above), so it must not tax the first token.
    defer _ = ctx.mem.observe(mem_scope, user_text);

    // TOOL-FINDING OBSERVES, BATCHED: each observe is a subprocess spawn, and doing one between every tool call
    // serialized big tool batches (a 40-tool storm paid ~40 spawns inline). The tool loop appends preformatted
    // notes here; the defer flushes them at turn exit — off every hot path. Nothing within this turn could have
    // read them anyway: recall runs once, at turn start.
    var tool_obs: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (tool_obs.items) |note| {
            _ = ctx.mem.observe(mem_scope, note);
            gpa.free(note);
        }
        tool_obs.deinit(gpa);
    }

    // The assembled, bounded PREFIX (system + recall + summary + goal + recency window). Everything appended past
    // this by the drive loop (settled answers, synthetic drive steps, per-pass tool notes) is compacted against it
    // between drive steps so a multi-step turn stays bounded ACROSS steps, not only within one pass.
    const assembled_len = conv_buf.items.len;

    // ---- PLAN-BOARD: the veil's first move on a non-trivial task is to decompose it into routed subtasks. Try a
    // fresh decomposition of THIS message; if it yields a plan, that's the new board (persist + show it). If not
    // (a question / "continue" / trivial step), resume an existing unfinished plan if one is on disk; else run a
    // normal free-form turn. When a plan is active the drive loop below walks it deterministically. ----
    var plan: []cplan.Task = blk: {
        // RESUME-PREFERRED: if an UNFINISHED plan is on disk, keep working IT — never silently clobber in-progress
        // work (with its completed-subtask state) by decomposing the new message into a fresh board. This is also
        // how "continue" resumes. A message sent mid-plan still rides in the model's context for the next subtask.
        const resumed = resumePlan(app, conv_dir);
        if (resumed.len > 0 and !cplan.allDone(resumed)) {
            emitPlanMessage(app, conv_dir, resumed);
            break :blk resumed;
        }
        cplan.freeTasks(gpa, resumed);
        // No unfinished plan → decompose a fresh message into a new board, but ONLY when it reads like a genuine
        // multi-step BUILD/RESEARCH task (shouldPlan). A question, greeting, ack, or one-liner skips the whole
        // decomposition ROUND-TRIP — that sequential inference adds seconds to time-to-first-token even when the
        // model correctly returns an empty plan, and weak models over-decompose greetings into swarm plans. Real
        // tasks still plan + coordinate; chat stays fast. This persistPlan only overwrites a completed/absent plan,
        // so no in-progress work is lost.
        if (shouldPlan(user_text)) {
            const fresh = planTask(app, run_root, base_url, key, model, user_text);
            if (fresh.len > 0) {
                persistPlan(app, conv_dir, fresh);
                emitPlanMessage(app, conv_dir, fresh);
                break :blk fresh;
            }
            cplan.freeTasks(gpa, fresh);
        }
        break :blk &.{};
    };
    defer cplan.freeTasks(gpa, plan);
    // var (not const): an ARMED turn whose plan completes while its cast hive still runs demotes to FREE-FORM
    // (has_plan=false) after the await, so the gather step can run through the normal drive machinery.
    var has_plan = plan.len > 0;

    // ---- AUTO-LOOP DRIVE: settle one answer, then either take the next PLAN subtask (deterministic) or infer the
    // next free-form step, and drive again until the plan/goal is done, a repeat, or the step cap. ----
    // `prev_drive` seeds the repeat guard with the user's own request so a driver that merely echoes it stops.
    var prev_drive: []u8 = gpa.dupe(u8, user_text) catch &[_]u8{};
    defer if (prev_drive.len > 0) gpa.free(prev_drive);

    // AUTO-LOOP MODE (desk chat_loop / chat_loop_afk, now server-driven). A plan drives its own subtask budget; a
    // free-form turn drives DRIVE_MAX off, LOOP_MAX_STEPS armed-on, effectively-unbounded in afk (Stop is the exit).
    const armed = loop >= LOOP_ON;
    const afk = loop >= LOOP_AFK;
    // afk OUTRANKS the plan cap: an afk turn whose message decomposed into a plan must still run until Stop (it
    // walks the plan, then keeps driving free-form) — not halt at PLAN_STEPS_PER_TURN, which would violate afk.
    var max_steps: usize = if (afk) AFK_MAX_STEPS else if (has_plan) PLAN_STEPS_PER_TURN else if (armed) LOOP_MAX_STEPS else DRIVE_MAX;
    var idle_steps: usize = 0; // consecutive no-tool drive steps — the armed (non-afk) anti-spin bound (desk loop_idle)
    var verified_done = false; // TERMINAL BUILD-VERIFY fires at most once per turn (desk arc_final_verified)
    var swarm_timeout_nudged = false; // SWARM_TIMEOUT_MSG fires at most once per turn — after that a stuck hive can't hold the turn open forever
    // afk re-drive / stuck messages, re-grounded to THIS turn's goal (the user message that started the loop) so the
    // persistent loop can't drift onto an unrelated task. Fixed stack buffers (no alloc/free on the hot path).
    var afk_buf: [800]u8 = undefined;
    var stuck_buf: [800]u8 = undefined;
    const goal_clip = clipBytes(user_text, 300);
    const afk_msg = std.fmt.bufPrint(&afk_buf, AFK_DRIVE_TMPL, .{goal_clip}) catch "Keep going toward the goal — re-verify the latest work, then do the single most valuable next improvement.";
    const afk_stuck_msg = std.fmt.bufPrint(&stuck_buf, AFK_STUCK_TMPL, .{goal_clip}) catch "You repeated the last step — try a DIFFERENT approach; recall_hive / web_search the actual blocker first.";
    if (armed) emitKV(app, conv_dir, "status", "text", if (afk) "auto-loop (afk): driving toward the goal" else "auto-loop: driving toward the goal");
    var steer_cursor = ctrl_cursor; // moving cursor over control.jsonl for stop + mid-turn steer messages
    // SCHEDULED-RUN TOOL BUDGET: an unattended auto-loop turn with a thorough model has an unbounded research
    // appetite — a live run burned 107 web calls (the repeat guard blocks exact duplicates, but the model just
    // VARIES the query) and was still "verifying" at the 10-minute mark, long after its deliverable was
    // written. Interactive chats have a human with a Stop button; a scheduled run needs a hard ceiling: past
    // the budget, every further tool call is answered with "finalize NOW", which drives the model to settle.
    // The successful reference run used 14 calls; 60 is generous headroom for real research.
    var tools_spent: usize = 0;
    const tool_budget: usize = if (schedTaskOf(conv) != null) 60 else std.math.maxInt(usize);
    var drive: usize = 0;
    outer: while (drive < max_steps) : (drive += 1) {
        // CONTROL (between drive steps): a `stop` op ends the turn; a `steer`/`say` op injects the user's text as a
        // mid-turn user message (posting to steer a running turn) so the next inference picks it up.
        switch (drainChatControl(app, conv_dir, &steer_cursor, &conv_buf)) {
            .stop => {
                finishTurn(app, conv_dir, usage_t0);
                return;
            },
            .none => {},
        }

        // CROSS-STEP COMPACTION: fold accumulated drive-step growth (prior settled answers + compacted notes) into
        // one note when it crosses the budget, so a long multi-step / afk turn can't overflow the model window
        // across steps. No-op on the first step (nothing past the assembled prefix yet).
        compactWorking(app, run_root, base_url, key, model, &conv_buf, assembled_len);

        // PLAN STEP: when a plan is active, take the next pending subtask and inject it as this step's working turn
        // (so the agentic pass works THAT subtask, route-hinted). No plan → drive step 0 works the user's message
        // (already the last turn) and later steps work the free-form next-step inferred at the bottom of the loop.
        var task_idx: ?usize = null;
        if (has_plan) {
            if (cplan.nextPending(plan)) |ti| {
                task_idx = ti;
                cplan.setStatus(gpa, &plan[ti], cplan.STATUS_ACTIVE);
                persistPlan(app, conv_dir, plan);
                var sb: [220]u8 = undefined;
                emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "subtask {d}/{d} ({s}): {s}", .{ ti + 1, plan.len, plan[ti].route, clipBytes(plan[ti].text, 80) }) catch "subtask");
                if (subtaskInstruction(gpa, plan[ti], ti, plan.len)) |instr| {
                    defer gpa.free(instr);
                    conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
                    http.jstr(gpa, &conv_buf, instr) catch break :outer;
                    conv_buf.append(gpa, '}') catch break :outer;
                }
            } else if (!afk) {
                // Whole plan done (non-afk). ARMED: don't settle over a RUNNING cast hive — a hive-routed final
                // subtask is marked done the pass right after casting, which would otherwise end the turn while the
                // hive is still working. Await it, then demote to FREE-FORM and gather.
                var plan_break = true;
                if (armed) {
                    if (awaitConvCast(app, uid, conv, conv_dir, steer_cursor, tool_client)) |w| switch (w) {
                        .stopped => {
                            finishTurn(app, conv_dir, usage_t0);
                            return;
                        },
                        .finished, .timeout => {
                            const gm: []const u8 = if (w == .finished) SWARM_GATHER_MSG else SWARM_TIMEOUT_MSG;
                            if (w == .timeout) {
                                if (swarm_timeout_nudged) {
                                    // already nudged once — a stuck hive can't hold the turn open forever
                                } else {
                                    swarm_timeout_nudged = true;
                                    plan_break = false;
                                }
                            } else plan_break = false;
                            if (!plan_break) {
                                conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
                                http.jstr(gpa, &conv_buf, gm) catch break :outer;
                                conv_buf.append(gpa, '}') catch break :outer;
                                emitKV(app, conv_dir, "status", "text", if (w == .finished) "the hive finished — folding its results in" else "the hive ran past its budget — salvaging");
                                has_plan = false; // plan done — continue free-form so the gather runs through the drive machinery
                                max_steps = @max(max_steps, LOOP_MAX_STEPS);
                            }
                        },
                    };
                }
                if (plan_break) break :outer;
            }
            // afk + plan complete → task_idx stays null → the loop keeps driving FREE-FORM (afk ends only on Stop)
        }

        // Run one agentic tool pass to a SETTLED (no-tool-call) answer.
        const inner = runInnerAgentic(app, uid, conv, conv_dir, run_root, base_url, key, model, &conv_buf, &ctx, &steer_cursor, &tool_obs, tool_client, &tools_spent, tool_budget);
        switch (inner.outcome) {
            .hard_error => {
                // the inference failed — the helper emitted {kind:error}; ALSO emit {kind:done} so the desk
                // poller disarms + clears busy instead of hanging forever.
                planStepInterrupted(app, conv_dir, plan, task_idx);
                salvageSteers(app, conv_dir, &steer_cursor); // an errored turn must not eat a pending steer
                // SCHEDULED runs learn from failure mechanically: record the failed run into the TASK's memory
                // (a plain engine fact, not model output — the confab rule stays intact) so the next run's
                // recall sees "the previous run failed" and can route around whatever broke.
                if (sched_task != null) {
                    var fb: [200]u8 = undefined;
                    _ = ctx.mem.observe(mem_scope, std.fmt.bufPrint(&fb, "previous scheduled run ({s}) FAILED: the model call errored mid-turn — check the provider/key, or simplify the task prompt", .{conv[0..@min(conv.len, 64)]}) catch "a previous scheduled run failed with a model-call error");
                }
                finishTurn(app, conv_dir, usage_t0);
                return;
            },
            .stopped => {
                // stop landed mid tool-loop — commit the last narration (if any) so the user keeps it, then close.
                planStepInterrupted(app, conv_dir, plan, task_idx);
                if (inner.content.len > 0) {
                    appendMsg(app, conv_dir, "assistant", inner.content, "veil", nowSecs(app.io));
                    emitAssistant(app, conv_dir, inner.content);
                }
                gpa.free(inner.content);
                finishTurn(app, conv_dir, usage_t0);
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
            planStepInterrupted(app, conv_dir, plan, task_idx);
            const note = "(no reply — the model returned an empty or malformed response this turn)";
            appendMsg(app, conv_dir, "assistant", note, "veil", nowSecs(app.io));
            emitAssistant(app, conv_dir, note);
            // SCHEDULED runs learn from an empty run too — a mechanical fact the next run's recall sees.
            if (sched_task != null) {
                var fb: [180]u8 = undefined;
                _ = ctx.mem.observe(mem_scope, std.fmt.bufPrint(&fb, "run {s} produced NO ANSWER (empty/malformed model response) — retry with a simpler first step", .{conv[0..@min(conv.len, 64)]}) catch "a previous run produced no answer");
            }
            salvageSteers(app, conv_dir, &steer_cursor); // an empty-reply end must not eat a pending steer
            finishTurn(app, conv_dir, usage_t0);
            return;
        }

        // DURABLE MEMORY: act on any REMEMBER:/FORGET: lines the reply carries (store/forget in the shared
        // memories.jsonl) and STRIP them so they never leak as literal text — the desk's processMemory, ported.
        // Runs BEFORE reflect so the self-critique sees the clean prose. A reply that was ONLY directives strips to
        // empty → show a short confirmation instead of committing a blank message.
        {
            var mem_saved: usize = 0;
            if (processMemoryDirectives(app, answer, &mem_saved)) |stripped| {
                if (std.mem.trim(u8, stripped, " \r\n\t").len == 0 and mem_saved > 0) {
                    if (gpa.dupe(u8, "(noted — saved to your memory)")) |note| {
                        gpa.free(stripped);
                        gpa.free(answer);
                        answer = note;
                    } else |_| {
                        gpa.free(answer);
                        answer = stripped;
                    }
                } else {
                    gpa.free(answer);
                    answer = stripped;
                }
            }
        }

        // REFLECT: on the FIRST substantial answer of the turn, run one self-critique/improve pass before commit.
        // Skipped when a plan drives the turn (the plan already structures the work) AND — critically — when the
        // answer already STREAMED to the user (inner.streamed): re-generating a streamed answer non-streamed froze
        // the chat ~8s and then swapped the text the user just watched type out. Reflect only runs when nothing
        // streamed (a non-streaming backend), where there's no live answer to preserve.
        if (!has_plan and !inner.streamed and drive == 0 and answer.len >= REFLECT_MIN) {
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

        // PLAN ADVANCE: mark this subtask done + move on. The next iteration picks the next pending subtask; the
        // free-form drive inference below is SKIPPED (the plan is the driver).
        if (task_idx) |ti| {
            cplan.setStatus(gpa, &plan[ti], cplan.STATUS_DONE);
            persistPlan(app, conv_dir, plan);
            // Plan complete (non-afk): a plain (unarmed) turn ends here; an ARMED one loops back so the top-of-loop
            // plan-complete branch can await a still-running cast hive before settling over it.
            if (cplan.nextPending(plan) == null and !afk and !armed) break :outer;
            continue :outer; // next subtask, OR (afk/armed + plan done) loop back — the top transitions or awaits
        }

        // ANTI-SPIN / FAST-PATH: a step that ran NO tools did no agentic work this pass.
        if (!inner.tools_ran) {
            if (!armed) {
                // OFF: a first-step no-plan answer with no tools is a complete one-shot reply (plain Q&A) — end now,
                // skipping the wasted LOOP_QUESTION round-trip. (A drive>0 no-tools step falls through to the DONE
                // check below, which ends it.)
                if (drive == 0) break :outer;
            } else {
                // ARMED: tolerate ONE idle (announce-only) step so a build that pauses to narrate isn't cut off, but
                // end a non-afk loop after TWO consecutive idle steps (that's a conversation, not work). AFK never
                // ends on idle — persistence IS the feature — so its counter just resets.
                idle_steps += 1;
                if (idle_steps >= 2) {
                    if (!afk) {
                        // Idle over a RUNNING cast hive isn't idleness — it's the veil narrating "the hive is
                        // working". Await the hive (cheap, stop-checked), then inject the gather step and continue.
                        if (awaitConvCast(app, uid, conv, conv_dir, steer_cursor, tool_client)) |w| switch (w) {
                            .stopped => {
                                finishTurn(app, conv_dir, usage_t0);
                                return;
                            },
                            .finished, .timeout => {
                                if (w == .timeout and swarm_timeout_nudged) break :outer;
                                if (w == .timeout) swarm_timeout_nudged = true;
                                idle_steps = 0;
                                const gm: []const u8 = if (w == .finished) SWARM_GATHER_MSG else SWARM_TIMEOUT_MSG;
                                conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
                                http.jstr(gpa, &conv_buf, gm) catch break :outer;
                                conv_buf.append(gpa, '}') catch break :outer;
                                emitKV(app, conv_dir, "status", "text", if (w == .finished) "the hive finished — folding its results in" else "the hive ran past its budget — salvaging");
                                continue :outer;
                            },
                        } else break :outer;
                    }
                    idle_steps = 0;
                }
            }
        } else idle_steps = 0;

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
        // A failed/empty drive inference always ends the turn (even afk — we can't determine a next step, and a
        // dead backend would spin). Otherwise decide by loop mode.
        if (!next.ok or trimmed.len == 0) break :outer;
        const is_done = loopIsDone(next.content);
        const is_repeat = nearlySame(trimmed, prev_drive) or cctx.looksLikeToolMarkup(trimmed);

        // Choose the next synthetic drive step, or break, honoring: TERMINAL VERIFY (an armed loop never accepts a
        // bare DONE right after building — one completeness check first), re-ground (afk anchors to the goal), and
        // stuck-recovery (afk re-grounds + researches on a repeat instead of churning).
        var next_step: []const u8 = trimmed;
        if (is_done) {
            if (armed and ctx.files_written.* > 0 and !verified_done) {
                verified_done = true; // TERMINAL BUILD-VERIFY (once): confirm the build before letting DONE stand
                next_step = TERMINAL_VERIFY_PROMPT;
            } else if (armed) {
                // ARMED (on or afk): never accept DONE while this conversation's cast hive is still working —
                // await it (cheap, stop-checked), then gather its results instead of settling over them.
                if (awaitConvCast(app, uid, conv, conv_dir, steer_cursor, tool_client)) |w| switch (w) {
                    .stopped => {
                        finishTurn(app, conv_dir, usage_t0);
                        return;
                    },
                    .finished => next_step = SWARM_GATHER_MSG,
                    .timeout => {
                        if (swarm_timeout_nudged) {
                            if (!afk) break :outer; // nudged once already — a stuck hive can't hold the turn forever
                            next_step = afk_msg;
                        } else {
                            swarm_timeout_nudged = true;
                            next_step = SWARM_TIMEOUT_MSG;
                        }
                    },
                } else if (afk) {
                    next_step = afk_msg; // afk never accepts DONE — re-verify + extend, re-grounded to the goal
                } else {
                    break :outer; // on: goal achieved, no hive in flight
                }
            } else {
                break :outer; // off: goal achieved (verified, or nothing was built)
            }
        } else if (is_repeat) {
            if (afk) {
                next_step = afk_stuck_msg; // afk: don't churn the same step — re-ground + research the blocker
            } else if (armed) {
                // ARMED repeat while the hive runs = "the hive is working" narrated twice — that's a wait, not
                // a stall. Await + gather; a genuine no-progress repeat (no hive) still ends the loop.
                if (awaitConvCast(app, uid, conv, conv_dir, steer_cursor, tool_client)) |w| switch (w) {
                    .stopped => {
                        finishTurn(app, conv_dir, usage_t0);
                        return;
                    },
                    .finished => next_step = SWARM_GATHER_MSG,
                    .timeout => {
                        if (swarm_timeout_nudged) break :outer;
                        swarm_timeout_nudged = true;
                        next_step = SWARM_TIMEOUT_MSG;
                    },
                } else break :outer;
            } else {
                break :outer; // off: a no-progress repeat ends the loop
            }
        }
        conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
        http.jstr(gpa, &conv_buf, next_step) catch break :outer;
        conv_buf.append(gpa, '}') catch break :outer;
        var sbuf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&sbuf, "continuing: {s}", .{clipBytes(next_step, 80)}) catch "continuing";
        emitKV(app, conv_dir, "status", "text", status);
        // The repeat guard tracks the MODEL's actual last step (`trimmed`), NOT any synthetic steering we injected
        // (TERMINAL_VERIFY / afk_msg / afk_stuck_msg) — else a model that keeps repeating its real action would slip
        // past nearlySame because prev_drive held our injected text instead of its output.
        const nd: []u8 = gpa.dupe(u8, trimmed) catch &[_]u8{};
        if (prev_drive.len > 0) gpa.free(prev_drive);
        prev_drive = nd;
    }

    // The drive loop ended (plan complete / DONE / repeat / step cap / an OOM append) — every settled answer is
    // already durable. A plan run gets a closing summary (all done, or paused at N/M — say "continue" to resume).
    // LAST-CALL STEER SALVAGE: a steer that landed during the final settle (after the last drain point) would
    // otherwise be dropped forever — the next turn re-snapshots the control cursor past it. Drain once more:
    // drainChatControl persists each pending steer as a durable user message, so the NEXT turn replays it.
    salvageSteers(app, conv_dir, &steer_cursor);
    if (has_plan) emitPlanClosing(app, conv_dir, plan);
    // SCHEDULED-RUN LEARNING: at normal completion, fold this run's outcome + one distilled lesson into the
    // TASK's memory so the next run starts smarter — the recursive-improvement loop for recurring tasks.
    if (sched_task != null) schedLearn(app, &ctx, mem_scope, conv, conv_dir, run_root, base_url, key, model, &conv_buf);
    // NORMAL COMPLETION: emit the answer's usage, then DEFER the rolling-summary fold-in to here (after the reply is
    // fully delivered) so it never blocked this turn's first token — it advances the summary for the NEXT turn. The
    // desk stays in its rendering state until {done}, so it naturally waits for this rather than sending early. Only
    // this path refreshes; Stop/error/empty end promptly via finishTurn (and the summary catches up next turn).
    emitUsage(app, conv_dir, usage_t0);
    refreshSummary(app, conv_dir, run_root, base_url, key, model);
    emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
}

/// The scheduled task's LEARNING step, run once at a run's NORMAL completion. Two writes into the task's own
/// memory scope ("sched:{taskid}", shared by every run of the task):
///   1. a MECHANICAL outcome note (files written, observations stored) — never depends on the model;
///   2. ONE model-distilled lesson ("what should the next run do differently/faster?") — the deliberate
///      counterpart of the desk's playbook pattern. This is NOT the forbidden observe-own-reply confab loop:
///      the reply itself is never stored, only a provenance-labeled lesson ("lesson from run X: ..."), and the
///      recall injection presents it as task history, not as ground truth about the world.
/// Difficult recurring tasks improve because every run leaves behind what happened, what to change, and every
/// tool finding already observed during the run. Bounded: one small extra inference, best-effort.
fn schedLearn(app: *App, ctx: *tools.ToolCtx, mem_scope: []const u8, conv: []const u8, conv_dir: []const u8, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, conv_buf: *std.ArrayListUnmanaged(u8)) void {
    const gpa = app.gpa;
    var ob: [220]u8 = undefined;
    const note = std.fmt.bufPrint(&ob, "run {s} COMPLETED: {d} file(s) written, {d} observation(s) stored", .{ conv[0..@min(conv.len, 64)], ctx.files_written.*, ctx.observed.* }) catch "scheduled run completed";
    _ = ctx.mem.observe(mem_scope, note);

    const saved = conv_buf.items.len;
    defer conv_buf.shrinkRetainingCapacity(saved); // the lesson question never rides into durable context
    conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"This scheduled task will run again. In ONE or TWO sentences, state the single most useful lesson from THIS run for the next run — a faster path, a source that worked, a pitfall to skip, or an assumption to keep. Reply with ONLY the lesson.\"}") catch return;
    var next = llm.complete(gpa, app.io, run_root, "lesson", base_url, key, model, conv_buf.items, "", 256, 0.3);
    defer next.deinit(gpa);
    if (!next.ok) return;
    scrubUtf8(next.content);
    const lesson = std.mem.trim(u8, next.content, " \r\n\t\"");
    if (lesson.len < 8 or lesson.len > 600 or cctx.looksLikeToolMarkup(lesson)) return; // a degenerate/markup "lesson" teaches nothing
    var lb: [720]u8 = undefined;
    const lnote = std.fmt.bufPrint(&lb, "lesson from run {s}: {s}", .{ conv[0..@min(conv.len, 40)], lesson }) catch return;
    _ = ctx.mem.observe(mem_scope, lnote);
    var sb: [180]u8 = undefined;
    emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "task memory updated: {s}", .{clipBytes(lesson, 120)}) catch "task memory updated");
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

/// Idempotent network reads whose exact repeat within one turn returns the same bytes — the search-spiral
/// tool set the repeat-call ledger covers. Stateful tools stay exempt (a re-read after a write is legitimate).
fn dedupableTool(name: []const u8) bool {
    const list = [_][]const u8{ "web_search", "web_fetch", "fetch_json", "read_url", "osint_scan", "deep_crawl" };
    for (list) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// The conv id of a LIVE turn whose id starts with `prefix`, copied into `out` — or null. Lets run-now refuse
/// a duplicate launch for a task that already has a run going (its conv ids share "scheduled_{taskid}_").
pub fn liveTurnWithPrefix(io: std.Io, prefix: []const u8, out: *[64]u8) ?[]const u8 {
    if (prefix.len == 0 or prefix.len > 64) return null;
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] >= prefix.len and std.mem.startsWith(u8, active_convs[i][0..active_lens[i]], prefix)) {
            const n = active_lens[i];
            @memcpy(out[0..n], active_convs[i][0..n]);
            return out[0..n];
        }
    }
    return null;
}

/// Is a turn executing for `conv` RIGHT NOW? Read-only scan of the per-conv turn table — the liveness bit the
/// conv GET carries so a client can attach its live poller to a server-born run (a scheduled task's turn).
pub fn isTurnLive(io: std.Io, conv: []const u8) bool {
    if (conv.len == 0 or conv.len > 64) return false;
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] == conv.len and std.mem.eql(u8, active_convs[i][0..active_lens[i]], conv)) return true;
    }
    return false;
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
    loop: u8,
    tool_client: bool,
};

/// Detached-thread entry: run the whole turn, then free the owned args. Any failure inside runTurn is already
/// caught + surfaced as an event, so this thread returns cleanly (never propagates an error that could abort it).
fn turnThread(args: *TurnArgs) void {
    runTurn(args.app, args.uid, args.conv, args.base_url, args.key, args.model, args.text, args.loop, args.tool_client);
    endTurn(args.app.io, args.conv); // release the per-conv turn lock (before freeing the blob `conv` points into)
    const gpa = args.app.gpa;
    gpa.free(args.blob);
    gpa.destroy(args);
}

/// Launch a turn for (uid, conv) on a DETACHED background thread with owned copies of every arg, so the HTTP
/// handler can return 202 at once and the client streams the turn's event frames live (a synchronous turn would
/// block the client's /events poll for the whole turn). On an
/// allocation or thread-spawn failure it runs the turn INLINE (blocking the caller) rather than drop it — the
/// caller's arg slices are still valid at that point. The turn writes its frames to events.jsonl either way.
pub fn spawnTurn(app: *App, uid: u64, conv: []const u8, base_url: []const u8, key: []const u8, model: []const u8, text: []const u8, loop: u8, tool_client: bool) void {
    const gpa = app.gpa;
    const total = conv.len + base_url.len + key.len + model.len + text.len;
    // The caller (postMessage) already claimed the per-conv turn slot via tryBeginTurn; EVERY completion path here
    // must release it. The detached/inline turnThread paths release in turnThread; the two alloc-failure inline
    // paths run the turn directly, so they release explicitly.
    const args = gpa.create(TurnArgs) catch {
        runTurn(app, uid, conv, base_url, key, model, text, loop, tool_client);
        endTurn(app.io, conv);
        return;
    };
    const blob = gpa.alloc(u8, total) catch {
        gpa.destroy(args);
        runTurn(app, uid, conv, base_url, key, model, text, loop, tool_client);
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
    args.* = .{ .app = app, .uid = uid, .blob = blob, .conv = cv, .base_url = bu, .key = ky, .model = md, .text = tx, .loop = loop, .tool_client = tool_client };
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
    // Did this settled answer TYPE OUT to the user live (streamOnDelta fired)? If so, reflect MUST NOT run — you
    // cannot silently re-generate + swap an answer the user already watched stream (it froze the chat ~8s then
    // replaced the text). Reflect only makes sense when nothing streamed (a non-streaming backend fallback).
    streamed: bool = false,
    // Did ANY tool execute during this pass? A pure-prose answer with no tools on the first step is DONE — there's
    // no agentic work in flight to continue, so the drive loop's LOOP_QUESTION "are you done?" completion is pure
    // wasted latency (it delayed {done}/usage + the turn-lock release by a full round-trip on every simple Q&A).
    tools_ran: bool = false,
};

/// Batch streamed deltas to ~this many chars per emitted frame. One frame per model TOKEN produces thousands of
/// frames per turn — each a file append + a desk poll-parse — which overwhelms the client. Coalescing cuts frames
/// while the reply still visibly types out; at 12 chars/frame (appendFile is an O(1) positioned append and the
/// desk polls its event stream at ~30Hz) the reply flows continuously rather than arriving in visible chunks.
const FLUSH_CHARS: usize = 12;

const StreamCtx = struct {
    app: *App,
    conv_dir: []const u8,
    ctrl_cursor: usize = 0, // control.jsonl offset for the mid-stream abort check (chat Stop)
    streamed: bool = false,
    tok: [256]u8 = undefined,
    tok_len: usize = 0,
    rsn: [256]u8 = undefined,
    rsn_len: usize = 0,
};

/// completeStream's cooperative-abort hook: fires (~every 40ms) during a streaming reply so a chat Stop kills the
/// in-flight generation promptly instead of waiting out the whole ~15s inference. Reads control.jsonl from the
/// turn's cursor for a `stop` op — the SAME predicate the between-tool / between-step checks use.
fn streamShouldAbort(cx: *anyopaque) bool {
    const sc: *StreamCtx = @ptrCast(@alignCast(cx));
    return stopRequestedSince(sc.app, sc.conv_dir, sc.ctrl_cursor);
}

/// llm.completeStream fires this per delta. We ACCUMULATE into a small buffer and emit a `{"kind":"token"|
/// "reasoning","delta":…}` frame only every ~FLUSH_CHARS (or when the buffer fills) — the reply still types out,
/// but at a sane frame rate. The chunk is borrowed (valid only during this call); scAccum copies it immediately.
fn streamOnDelta(cx: *anyopaque, kind: llm.DeltaKind, text: []const u8) void {
    if (text.len == 0) return;
    const sc: *StreamCtx = @ptrCast(@alignCast(cx));
    if (kind == .tool_progress) {
        // Composing a big tool call emits NO content/reasoning deltas — surface what's being written as a live
        // status line ("writing index.html — 12 KB...") so the user isn't staring at a silent turn. Not part of
        // the reply: don't set `streamed` (a call-only step must still fall back to emitting its reasoning once).
        emitKV(sc.app, sc.conv_dir, "status", "text", text);
        return;
    }
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
        const buffer_full = (len.* == buf.len);
        if (len.* >= FLUSH_CHARS or buffer_full) {
            // Deltas arrive as WHOLE codepoints (whole JSON strings, split on \n which never bisects a codepoint),
            // so a FLUSH_CHARS-threshold flush always lands on a boundary. The ONE place a multibyte char can be
            // split is the buffer-full clamp when a single delta overflows the 256-byte buffer — emitting a frame
            // ending in a truncated lead byte (invalid UTF-8, which a strict JSON reader of events.jsonl rejects).
            // Back off to the last complete UTF-8 boundary and keep the trailing partial bytes for the next chunk.
            var emit_len = len.*;
            if (buffer_full) {
                const cut = utf8SafeCut(buf[0..len.*]);
                if (cut > 0) emit_len = cut; // cut==0 ⇒ a >256-byte "codepoint" (never happens); emit as-is, don't stall
            }
            emitKV(sc.app, sc.conv_dir, kind, "delta", buf[0..emit_len]);
            const carry = len.* - emit_len;
            if (carry > 0) std.mem.copyForwards(u8, buf[0..carry], buf[emit_len..len.*]);
            len.* = carry;
        }
    }
}

/// Largest prefix of `b` that ends on a UTF-8 codepoint boundary (i.e. contains no trailing partial codepoint).
/// Returns b.len when the last codepoint is already complete. Used to avoid splitting a multibyte char across two
/// streamed frames when the fixed accumulation buffer fills mid-codepoint.
fn utf8SafeCut(b: []const u8) usize {
    if (b.len == 0) return 0;
    var i: usize = b.len;
    while (i > 0) { // walk back past continuation bytes (0b10xxxxxx) to the lead byte of the last codepoint
        i -= 1;
        if (b[i] & 0xC0 != 0x80) break;
    }
    const lead = b[i];
    const need: usize = if (lead < 0x80) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else 1;
    return if (i + need <= b.len) b.len else i; // last codepoint complete → keep all; else cut before it
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
// ------------------------------------------------------------------------------------ veil PLAN-BOARD (Phase A+)

/// Slice out the outermost {...} JSON object from a model reply (which may wrap it in prose or ``` fences).
fn extractJsonObject(s: []const u8) []const u8 {
    const a = std.mem.indexOfScalar(u8, s, '{') orelse return s;
    const b = std.mem.lastIndexOfScalar(u8, s, '}') orelse return s;
    if (b > a) return s[a .. b + 1];
    return s;
}

/// Cheap, inference-free pre-gate: does THIS message warrant a plan-decomposition round-trip? The plan-board is
/// for genuine multi-step BUILD/RESEARCH jobs — the veil breaking a real task into routed subtasks and steering a
/// swarm. A question, a greeting, an ack, or a one-line ask must NOT pay a sequential decomposition inference
/// (it dominated time-to-first-token) nor risk a weak model over-decomposing "hi" into a swarm plan. Bias HARD
/// toward NOT planning: only a clear build/research intent verb (with enough length to be a real task) plans;
/// everything else answers directly and fast. A message that IS a task phrased without a marker still gets worked
/// by the drive loop — it just isn't pre-decomposed into a persisted board, which is the safe direction to err.
fn shouldPlan(user_text: []const u8) bool {
    const t = std.mem.trim(u8, user_text, " \r\n\t");
    if (t.len < 24) return false; // greetings, acks, short questions — never a multi-step task
    var buf: [192]u8 = undefined;
    const n = @min(t.len, buf.len);
    for (t[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    // UNAMBIGUOUS multi-step markers — checked BEFORE the question guard so a task phrased with a leading verb like
    // "do a deep dive …" or "audit the engine and categorize …" still plans (these almost never occur in plain Q&A).
    const strong_markers = [_][]const u8{ "audit ", "deep dive", "deep-dive", "step by step", "step-by-step", "from scratch", "end to end", "end-to-end" };
    for (strong_markers) |m| if (std.mem.indexOf(u8, low, m) != null) return true;
    // A clear question / explanation / lookup opener → answer directly, never plan (even if a build verb like
    // "write" appears later, as in "write 200 words explaining X" — that's Q&A, not a build).
    const q_openers = [_][]const u8{
        "what ",  "what's", "whats ",  "why ",    "how ",    "how's",    "hows ",  "when ",  "who ",    "where ",       "which ",
        "whose ", "is ",    "are ",    "am ",     "was ",    "were ",    "do ",    "does ",  "did ",    "can you tell", "could you tell",
        "will ",  "would ", "should ", "explain", "tell me", "describe", "summar", "define", "what is", "what are",
    };
    for (q_openers) |q| if (std.mem.startsWith(u8, low, q)) return false;
    // Strong multi-step build / research task intent anywhere → plan + coordinate.
    const task_markers = [_][]const u8{
        "build ",    "create ",    "implement ", "develop ",     "scaffold",     "set up a",     "set up the", "make me a",
        "make a ",   "write me a", "write a ",   "write the ",   "code me",      "refactor ",    "migrate ",   "port the",
        "port it",   "deploy ",    "generate a", "research ",    "investigate ", "analyze ",     "gather ",    "scrape ",
        "crawl ",    "design a",   "design and", "from scratch", "step by step", "step-by-step", "and then ",  "an app",
        "a website", "a web app",  "a cli",      "a rest api",   "a full ",      "end to end",   "end-to-end",
    };
    for (task_markers) |m| if (std.mem.indexOf(u8, low, m) != null) return true;
    return false; // ambiguous / conversational → fast direct answer (no decomposition round-trip)
}

/// DECOMPOSITION inference: ask the model to break the request into routed subtasks. Returns owned tasks (empty =
/// no plan needed → a normal single-step turn). No tools; deterministic (low temp). Any failure → empty.
fn planTask(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, user_text: []const u8) []cplan.Task {
    const gpa = app.gpa;
    const empty: []cplan.Task = &.{};
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return empty;
    http.jstr(gpa, &msgs, "You are veil. Plan how to tackle the user's request by decomposing it into routed subtasks.") catch return empty;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return empty;
    var uc: std.ArrayListUnmanaged(u8) = .empty;
    defer uc.deinit(gpa);
    uc.appendSlice(gpa, "USER REQUEST:\n") catch return empty;
    uc.appendSlice(gpa, clipBytes(user_text, 8000)) catch return empty;
    uc.appendSlice(gpa, "\n\n") catch return empty;
    uc.appendSlice(gpa, PLAN_PROMPT) catch return empty;
    http.jstr(gpa, &msgs, uc.items) catch return empty;
    msgs.append(gpa, '}') catch return empty;
    var step = llm.complete(gpa, app.io, run_root, "plan", base_url, key, model, msgs.items, "", 1024, 0.3);
    defer step.deinit(gpa);
    if (!step.ok) return empty;
    return cplan.parseDecomposition(gpa, extractJsonObject(step.content));
}

/// Read the persisted plan.jsonl back into a task list (for resuming a plan across turns). Empty if absent.
fn resumePlan(app: *App, conv_dir: []const u8) []cplan.Task {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/plan.jsonl", .{conv_dir}) catch return &.{};
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(256 << 10)) catch return &.{};
    defer gpa.free(data);
    return cplan.parsePlan(gpa, data);
}

/// Write the current plan state to plan.jsonl (full overwrite — it's the live board, not an append log).
fn persistPlan(app: *App, conv_dir: []const u8, plan: []const cplan.Task) void {
    const gpa = app.gpa;
    const body = cplan.formatPlan(gpa, plan) catch return;
    defer gpa.free(body);
    const path = std.fmt.allocPrint(gpa, "{s}/plan.jsonl", .{conv_dir}) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = body }) catch {};
}

/// Commit a readable rendering of the plan as an assistant message — durable + visible in chat + in the model's
/// own context so it knows its plan. Marks each task with its route and (on a resume) its status.
fn emitPlanMessage(app: *App, conv_dir: []const u8, plan: []const cplan.Task) void {
    const gpa = app.gpa;
    var m: std.ArrayListUnmanaged(u8) = .empty;
    defer m.deinit(gpa);
    m.appendSlice(gpa, "Here's my plan:\n") catch return;
    for (plan, 0..) |t, i| {
        const mark = if (std.mem.eql(u8, t.status, cplan.STATUS_DONE)) "[x] " else "[ ] ";
        const line = std.fmt.allocPrint(gpa, "{d}. {s}({s}) {s}\n", .{ i + 1, mark, t.route, t.text }) catch return;
        defer gpa.free(line);
        m.appendSlice(gpa, line) catch return;
    }
    appendMsg(app, conv_dir, "assistant", m.items, "veil", nowSecs(app.io));
    emitAssistant(app, conv_dir, m.items);
}

/// The instruction injected as the working turn for one subtask — the subtask text + a route-specific nudge.
fn subtaskInstruction(gpa: std.mem.Allocator, task: cplan.Task, idx: usize, total: usize) ?[]u8 {
    const hint = if (std.mem.eql(u8, task.route, cplan.ROUTE_HIVE))
        "This subtask suits a HIVE — `cast` a swarm for it and steer it; don't build it all yourself."
    else if (std.mem.eql(u8, task.route, cplan.ROUTE_RESEARCH))
        "You may be missing knowledge here — research it first (web_search / read_url / recall_hive) before acting."
    else
        "Do this directly with your own tools (write_file / edit_file / run_python).";
    return std.fmt.allocPrint(gpa, "Work this subtask now — step {d} of {d} in your plan: {s}\nSuggested route ({s}): {s}\nWhen it's done, briefly say what you did.", .{ idx + 1, total, task.text, task.route, hint }) catch null;
}

/// A plan subtask was mid-flight when the turn aborted (Stop / hard error / empty answer). Mark it DONE + persist
/// so a resume does NOT re-run it — critically, a `route:hive` subtask that already cast a swarm must not re-cast a
/// duplicate on "continue". No-op when no subtask is active. (The user sees it marked and can re-plan if needed.)
fn planStepInterrupted(app: *App, conv_dir: []const u8, plan: []cplan.Task, task_idx: ?usize) void {
    const ti = task_idx orelse return;
    if (ti >= plan.len) return;
    cplan.setStatus(app.gpa, &plan[ti], cplan.STATUS_DONE);
    persistPlan(app, conv_dir, plan);
}

/// Closing message after the drive loop worked a plan: all done, or paused with N/M and how to resume.
fn emitPlanClosing(app: *App, conv_dir: []const u8, plan: []const cplan.Task) void {
    const gpa = app.gpa;
    const done = cplan.doneCount(plan);
    const total = plan.len;
    const note = if (cplan.allDone(plan))
        std.fmt.allocPrint(gpa, "Plan complete — worked all {d} subtasks.", .{total}) catch return
    else
        std.fmt.allocPrint(gpa, "Worked {d} of {d} planned subtasks this turn. Say \"continue\" to do the rest.", .{ done, total }) catch return;
    defer gpa.free(note);
    appendMsg(app, conv_dir, "assistant", note, "veil", nowSecs(app.io));
    emitAssistant(app, conv_dir, note);
}

// --------------------------------------------------------------------------- veil ORCHESTRATION tools (Phase A)

/// A safe empty tool-result (len 0) for OOM fallbacks — never freed (the caller frees only result.len>0).
fn emptyRes() []u8 {
    return @constCast(@as([]const u8, ""));
}

/// Mirror of llm.isLocal / deploy_service's local-model detection over a base_url (loopback = local Ollama etc.).
fn isLocalBase(base_url: []const u8) bool {
    return std.mem.indexOf(u8, base_url, "localhost") != null or
        std.mem.indexOf(u8, base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, base_url, "0.0.0.0") != null or
        std.mem.indexOf(u8, base_url, "[::1]") != null;
}

/// Build a gpa-owned `{"ok":false,"err":<escaped msg>}` tool result (or emptyRes on OOM).
fn orchErr(gpa: std.mem.Allocator, msg: []const u8) []u8 {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    defer l.deinit(gpa); // no-op after a successful toOwnedSlice (list is emptied); frees the buffer on OOM
    (build: {
        l.appendSlice(gpa, "{\"ok\":false,\"err\":") catch break :build;
        http.jstr(gpa, &l, msg) catch break :build;
        l.append(gpa, '}') catch break :build;
    });
    return l.toOwnedSlice(gpa) catch emptyRes();
}

/// Dispatch the veil's orchestration verbs. Returns a gpa-owned result string, or null when `name` is not an
/// orchestration verb (the caller then routes to the normal mind-tool executor).
// ---- AWAIT-SWARM: the engine-level "wait for the hive" the model can't do itself. Without it a cast leaves the
// model only inference-speed polling, so it spin-polls swarm_status, grows impatient, stops the hive early, and
// the armed loop then accepts DONE while the hive is still running — settling over half-finished work. Two
// mechanisms prevent that: (1) statusTool BLOCKS while the swarm runs (cheap file probes + stop checks, no
// inference) so one call replaces a poll storm; (2) an ARMED drive loop refuses to settle while this
// conversation's cast hive is still working — it awaits, then injects a gather step so the results fold into the
// turn. Loop OFF keeps fire-and-forget.

/// The gather step injected when the awaited hive finishes: fold its results into the turn instead of settling.
const SWARM_GATHER_MSG = "The hive you cast has finished. Collect its results NOW: call swarm_status, then list_dir / read_file its deliverable files, verify they satisfy the goal, and fold them into your answer — then continue toward the goal or give the final summary.";
/// Injected ONCE if the hive outlives its budget+grace: salvage rather than wait forever.
const SWARM_TIMEOUT_MSG = "The hive you cast is still running past its time budget. Call swarm_status once more; if it is stuck, stop_swarm it and salvage what it produced (list_dir / read_file), then finish the goal yourself.";
/// Slack past the swarm's minutes budget before the await gives up: the worker's own hang watchdog exits at
/// minutes+90s and stamps DONE, so budget+150s covers the honest path with margin.
const SWARM_WAIT_GRACE_S: i64 = 150;
/// Per-call cap on how long a single swarm_status BLOCKS while the hive works (the drive-loop await has no such
/// cap — it waits to the budget deadline). One bounded wait per call keeps the model in the loop with fresh
/// context instead of a poll storm, and keeps any single tool frame's latency predictable.
const SWARM_STATUS_WAIT_S: i64 = 45;

/// The swarm's `minutes` budget from its manifest ({run_dir}/swarm.json) — the effective value castSwarm computed.
fn swarmMinutes(app: *App, run_dir: []const u8) i64 {
    const gpa = app.gpa;
    var pb: [1280]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/swarm.json", .{run_dir}) catch return 4;
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, p, gpa, .limited(16 << 10)) catch return 4;
    defer gpa.free(raw);
    const M = struct { minutes: i64 = 4 };
    const parsed = std.json.parseFromSlice(M, gpa, raw, .{ .ignore_unknown_fields = true }) catch return 4;
    defer parsed.deinit();
    return std.math.clamp(parsed.value.minutes, 1, 60);
}

/// Is a swarm terminal RIGHT NOW? DONE marker or a dead worker pid — the same fresh predicate statusTool reports
/// (sw.state lags the supervisor's ~10s reconcile, so never trust it for liveness). A very young swarm whose
/// worker.pid hasn't landed yet reads as alive (the spawn takes a moment to write it).
fn swarmTerminal(app: *App, run_dir: []const u8, created: i64) bool {
    var pb: [1280]u8 = undefined;
    if (std.fmt.bufPrint(&pb, "{s}/DONE", .{run_dir})) |dp| {
        if (std.Io.Dir.cwd().access(app.io, dp, .{})) |_| return true else |_| {}
    } else |_| {}
    const ps = app.sup.pidStatus(run_dir);
    if (ps.alive) return false;
    return nowSecs(app.io) - created > 20; // no live pid: terminal unless the swarm is still spawning
}

/// This conversation's cast swarm, if one is LIVE. A chat cast always builds in _chat/builds/{conv}, and
/// sup.resolve falls back to run-dir-basename matching — so the conv id alone finds it, including a cast from an
/// earlier turn (armed-loop semantics: the loop shouldn't settle over ANY running hive in this conversation).
fn liveConvCast(app: *App, uid: u64, conv: []const u8) ?struct { run_dir: []const u8, deadline: i64 } {
    const sw = app.sup.resolve(conv) orelse return null;
    if (sw.uid != uid) return null;
    if (swarmTerminal(app, sw.run_dir, sw.created)) return null;
    return .{ .run_dir = sw.run_dir, .deadline = sw.created + swarmMinutes(app, sw.run_dir) * 60 + SWARM_WAIT_GRACE_S };
}

const AwaitVerdict = enum { finished, stopped, timeout };

/// Block (cheaply — file probes + stop checks, NO inference) until this conversation's cast hive finishes, a stop
/// lands, or the hive outlives its budget. null = no live hive (nothing to wait for). Emits a status frame every
/// ~15s so the desk shows the wait honestly. In client mode, a .finished verdict pushes the hive's files down to
/// the client BEFORE the gather step runs, so the delegated list_dir/read_file that follows finds them locally.
/// (.timeout leaves the hive running — files sync via the pre-delegation hook once a stop_swarm makes it terminal.)
fn awaitConvCast(app: *App, uid: u64, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize, tool_client: bool) ?AwaitVerdict {
    const cast = liveConvCast(app, uid, conv) orelse return null;
    const t0 = nowSecs(app.io);
    var last_frame: i64 = 0;
    var waited: i64 = 0;
    while (true) {
        const now = nowSecs(app.io);
        if (now > cast.deadline) return .timeout;
        waited = now - t0;
        if (waited - last_frame >= 15) {
            last_frame = waited;
            var sb: [128]u8 = undefined;
            emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "the hive is still working — waiting to fold its results ({d}s)", .{waited}) catch "waiting on the hive");
        }
        // ~2s between probes, stop-checked every 250ms so a desk Stop lands promptly mid-wait.
        var slice: usize = 0;
        while (slice < 8) : (slice += 1) {
            if (stopRequestedSince(app, conv_dir, ctrl_cursor)) return .stopped;
            sleepMsRaw(app.io, 250);
        }
        const sw = app.sup.resolve(conv) orelse {
            if (tool_client) maybeSyncCastFiles(app, uid, conv, conv_dir, ctrl_cursor);
            return .finished;
        };
        if (sw.uid != uid or swarmTerminal(app, sw.run_dir, sw.created)) {
            if (tool_client) maybeSyncCastFiles(app, uid, conv, conv_dir, ctrl_cursor);
            return .finished;
        }
    }
}

fn orchTool(app: *App, uid: u64, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize, base_url: []const u8, key: []const u8, model: []const u8, name: []const u8, args: []const u8, tool_client: bool) ?[]u8 {
    if (std.mem.eql(u8, name, "cast")) return castTool(app, uid, conv, conv_dir, ctrl_cursor, base_url, key, model, args, tool_client);
    if (std.mem.eql(u8, name, "steer_swarm")) return steerTool(app, uid, args);
    if (std.mem.eql(u8, name, "stop_swarm")) return stopTool(app, uid, args);
    if (std.mem.eql(u8, name, "swarm_status")) return statusTool(app, uid, conv_dir, ctrl_cursor, args);
    if (std.mem.eql(u8, name, "swarm_asks")) return asksTool(app, uid, args);
    if (std.mem.eql(u8, name, "answer_swarm")) return answerTool(app, uid, args);
    if (std.mem.eql(u8, name, "schedule_task")) return scheduleTool(app, uid, base_url, key, model, args);
    if (std.mem.eql(u8, name, "schedule_list")) return scheduleListTool(app, uid);
    if (std.mem.eql(u8, name, "schedule_delete")) return scheduleDeleteTool(app, uid, args);
    if (std.mem.eql(u8, name, "sync_dir")) return syncDirTool(app, conv, conv_dir, ctrl_cursor, args, tool_client);
    return null;
}

/// sync_dir — PROJECT a directory from the CLIENT's machine into this conversation's workdir (read-only,
/// hash-diffed: only changed files transfer; the source is NEVER written back to — an immutable system or a
/// live game project stays untouched). This is how work that lives outside the workdir (an app inside a game
/// engine folder, a repo elsewhere on disk) becomes visible to the veil AND to any hive it casts, on command.
fn syncDirTool(app: *App, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize, args: []const u8, tool_client: bool) []u8 {
    const gpa = app.gpa;
    if (!tool_client) return orchErr(gpa, "sync_dir needs a connected client (desk/CLI) — there is no client machine to project from");
    const A = struct { path: []const u8 = "", as: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "sync_dir: could not parse args JSON");
    defer p.deinit();
    const src = std.mem.trim(u8, p.value.path, " \r\n\t");
    if (src.len == 0) return orchErr(gpa, "sync_dir: 'path' is required — an ABSOLUTE directory on the user's machine (e.g. C:/dev/mygame/src)");
    if (std.mem.indexOf(u8, src, "..") != null) return orchErr(gpa, "sync_dir: no '..' in the path");
    // dest = builds/{conv}/work/{as or the source's basename} — always INSIDE the conversation workdir
    const base_name = if (p.value.as.len > 0) p.value.as else std.fs.path.basename(src);
    if (base_name.len == 0 or !cync.safeSyncPath(base_name)) return orchErr(gpa, "sync_dir: bad 'as' — a workdir-relative folder name (e.g. mygame)");
    const at = std.mem.lastIndexOf(u8, conv_dir, "/convs/") orelse return orchErr(gpa, "sync_dir: cannot resolve the workdir");
    const dest = std.fmt.allocPrint(gpa, "{s}/builds/{s}/work/{s}", .{ conv_dir[0..at], conv, base_name }) catch return orchErr(gpa, "sync_dir: out of memory");
    defer gpa.free(dest);
    const got = pullClientFilesRooted(app, conv_dir, dest, ctrl_cursor, src);
    if (got < 0) return orchErr(gpa, "sync_dir: the client did not answer — is the desk/CLI still connected?");
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"sync_dir\",\"projected\":{d},\"into\":\"{s}\",\"note\":\"{d} file(s) copied/updated from the client folder into the workdir (unchanged files skipped by hash; text files only, caps 64 files / 512KB each / 4MB total — project the SPECIFIC subfolder you need). The source folder is never written back to; outputs belong in the workdir.\"}}", .{ got, base_name, got }) catch emptyRes();
}

/// schedule_task — the veil creates a scheduled task straight from conversation ("do X every morning at 9").
/// The task inherits THIS turn's provider creds, so its unattended runs use the same backend that created it.
/// Time conveniences the model can actually express: in_min (relative) and at_hm (next local occurrence) for
/// "once" — it never has to guess epoch seconds.
fn scheduleTool(app: *App, uid: u64, base_url: []const u8, key: []const u8, model: []const u8, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct {
        name: []const u8 = "",
        prompt: []const u8 = "",
        details: []const u8 = "",
        kind: []const u8 = "once",
        in_min: i64 = 0,
        at_hm: []const u8 = "",
        every_min: i64 = 0,
        hm: []const u8 = "",
    };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "schedule_task: could not parse args JSON");
    defer p.deinit();
    const a = p.value;
    const now = nowSecs(app.io);
    var at: i64 = 0;
    if (std.mem.eql(u8, a.kind, "once")) {
        if (a.in_min > 0) {
            if (a.in_min > sched.EVERY_MIN_MAX) return orchErr(gpa, "schedule_task: in_min is capped at 527040 (one year)"); // model-authored i64: unbounded would overflow the epoch math
            at = now + a.in_min * 60;
        } else if (sched.parseHm(a.at_hm) != null) {
            // next local occurrence of HH:MM — the exact math the daily tick uses
            at = sched.computeNextDue("daily", 0, 0, a.at_hm, now, 0, now, sched.localOffsetSecs());
        } else {
            return orchErr(gpa, "schedule_task: kind \"once\" needs in_min (minutes from now) or at_hm (\"HH:MM\", next occurrence)");
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    switch (sched.createFromSpec(app, arena_state.allocator(), uid, .{
        .name = a.name,
        .prompt = a.prompt,
        .details = a.details,
        .kind = a.kind,
        .at = at,
        .every_min = a.every_min,
        .hm = a.hm,
        .enabled = true,
        .base_url = base_url,
        .model = model,
        .api_key = key,
    })) {
        .id => |id| return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"schedule_task\",\"id\":\"{s}\",\"note\":\"created — it fires on schedule as an unattended run with its own cross-run memory; schedule_list shows it\"}}", .{id}) catch emptyRes(),
        .err => |e| return orchErr(gpa, e),
    }
}

/// schedule_list — the user's tasks, one compact line each (id | name | kind | next due | runs | state).
fn scheduleListTool(app: *App, uid: u64) []u8 {
    const gpa = app.gpa;
    const brief = sched.listBrief(app, gpa, uid);
    defer gpa.free(brief);
    if (std.mem.trim(u8, brief, " \r\n\t").len == 0) return gpa.dupe(u8, "(no scheduled tasks yet)") catch emptyRes();
    return std.fmt.allocPrint(gpa, "scheduled tasks (id | name | kind | next due | runs | state):\n{s}", .{brief}) catch emptyRes();
}

/// schedule_delete — remove one task by id (ownership is structural: the path is built under this uid).
fn scheduleDeleteTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "schedule_delete: could not parse args JSON");
    defer p.deinit();
    if (p.value.id.len == 0) return orchErr(gpa, "schedule_delete: an id is required (see schedule_list)");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    if (!sched.deleteById(app, arena_state.allocator(), uid, p.value.id)) return orchErr(gpa, "schedule_delete: no such task id — call schedule_list for the exact ids");
    return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"schedule_delete\",\"deleted\":true}") catch emptyRes();
}

/// cast — deploy a swarm into THIS conversation's build dir, using the chat turn's own model/creds so the hive
/// runs on the same backend the user is chatting with. Reuses deploy_service.castSwarm (the exact server cast
/// pipeline the HTTP /cast route uses). gpa-owned result.
fn castTool(app: *App, uid: u64, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize, base_url: []const u8, key: []const u8, model: []const u8, args: []const u8, tool_client: bool) []u8 {
    const gpa = app.gpa;
    const A = struct { goal: []const u8 = "", minds: u32 = 3, minutes: u32 = 0, mode: []const u8 = "cast", files: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "cast: could not parse args JSON");
    defer p.deinit();
    const a = p.value;
    if (std.mem.trim(u8, a.goal, " \r\n\t").len == 0) return orchErr(gpa, "cast: a goal is required");
    const user = app.auth.userById(uid) orelse return orchErr(gpa, "cast: user not found");

    // CLIENT MODE (client→server): the hive is about to build in the SERVER's copy of this conversation's
    // workdir, but the veil's files (and any client-side script output / user-dropped assets) live on the
    // CLIENT. Pull the difference down first — one manifest round-trip, then only changed files; same-disk
    // installs detect via the probe and transfer nothing. See chat/sync.zig.
    if (tool_client) {
        const at = std.mem.lastIndexOf(u8, conv_dir, "/convs/");
        if (at) |i| {
            var wb: [1400]u8 = undefined;
            if (std.fmt.bufPrint(&wb, "{s}/builds/{s}/work", .{ conv_dir[0..i], conv })) |work| {
                pullClientFiles(app, conv_dir, work, ctrl_cursor);
            } else |_| {}
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rq = deploy_service.CastReq{
        .goal = a.goal,
        .minutes = a.minutes,
        .minds = a.minds,
        // The swarm runs on the SAME backend the chat turn uses (local Ollama or hosted): pass the turn's creds.
        .provider = if (isLocalBase(base_url)) "ollama" else "openai",
        .model = model,
        .api_key = key,
        .base_url = base_url,
        .style = "auto",
        .mode = a.mode,
        .dir = conv, // build in this conversation's dir so the cast + chat co-edit one tree
        .files = a.files,
        // No autonomous public egress: the veil's casts stay local build/research. Telegraph publishing remains a
        // deliberate user action via the deploy path, never something the chat veil triggers on its own.
        .publish = false,
        .post = false,
    };
    switch (deploy_service.castSwarm(app, arena.allocator(), user, rq)) {
        .ok => |sp| return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"cast\",\"id\":\"{s}\",\"minds\":{d},\"state\":\"{s}\",\"note\":\"swarm deployed in this conversation's build dir; it runs ASYNC for its minutes budget. swarm_status WAITS while the hive works (call it to watch progress — no need to re-poll rapidly); steer_swarm to guide it (use this id). do NOT stop_swarm just because it is still running — only if it is off-track\"}}", .{ sp.id, sp.minds, sp.state }) catch emptyRes(),
        .fail => |f| return orchErr(gpa, f.msg),
    }
}

/// steer_swarm — deliver a live directive (op:"say" to all minds) or retarget the goal (op:"set_goal") to a
/// running swarm by appending to its control.jsonl, which the worker drains each round. gpa-owned result.
fn steerTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "", text: []const u8 = "", goal: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "steer_swarm: could not parse args JSON");
    defer p.deinit();
    const a = p.value;
    if (a.id.len == 0) return orchErr(gpa, "steer_swarm: an id is required (from cast/swarm_status)");
    const sw = app.sup.resolve(a.id) orelse return orchErr(gpa, "steer_swarm: no such swarm — check the id");
    if (sw.uid != uid) return orchErr(gpa, "steer_swarm: that swarm isn't yours");

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    const built = build: {
        if (a.goal.len > 0) {
            line.appendSlice(gpa, "{\"op\":\"set_goal\",\"goal\":") catch break :build false;
            http.jstr(gpa, &line, a.goal) catch break :build false;
            line.appendSlice(gpa, "}\n") catch break :build false;
            break :build true;
        }
        if (a.text.len == 0) break :build false;
        line.appendSlice(gpa, "{\"op\":\"say\",\"to\":\"all\",\"text\":") catch break :build false;
        http.jstr(gpa, &line, a.text) catch break :build false;
        line.appendSlice(gpa, "}\n") catch break :build false;
        break :build true;
    };
    if (!built) return orchErr(gpa, "steer_swarm: provide `text` (a directive for the minds) or `goal` (to retarget the hive)");
    const ctl = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{sw.run_dir}) catch return orchErr(gpa, "steer_swarm: out of memory");
    defer gpa.free(ctl);
    http.appendFile(app.io, gpa, ctl, line.items) catch return orchErr(gpa, "steer_swarm: could not write the control channel");
    return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"steer_swarm\",\"note\":\"delivered; the minds read it at their next round\"}") catch emptyRes();
}

/// stop_swarm — cooperative stop of a running swarm (its files + findings are kept). gpa-owned result.
fn stopTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "stop_swarm: could not parse args JSON");
    defer p.deinit();
    if (p.value.id.len == 0) return orchErr(gpa, "stop_swarm: an id is required");
    const sw = app.sup.resolve(p.value.id) orelse return orchErr(gpa, "stop_swarm: no such swarm");
    if (sw.uid != uid) return orchErr(gpa, "stop_swarm: that swarm isn't yours");
    app.sup.stop(sw.id);
    return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"stop_swarm\",\"state\":\"stopping\",\"note\":\"stop requested (cooperative; effective at the swarm's next round). files + findings are kept.\"}") catch emptyRes();
}

/// swarm_status — compact liveness for the veil to decide keep-going / steer / collect: supervisor state, whether
/// the worker process is alive, mind count, and whether a terminal DONE marker exists yet. While the swarm is
/// STILL RUNNING this call BLOCKS (cheap file probes + stop checks, up to SWARM_STATUS_WAIT_S) — the engine-level
/// "wait" the model can't express itself. Without it the model's only move is to re-poll at inference speed,
/// burning the pass's iterations. One blocking call replaces the storm; the result says how long it waited.
/// gpa-owned result.
fn statusTool(app: *App, uid: u64, conv_dir: []const u8, ctrl_cursor: usize, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "swarm_status: could not parse args JSON");
    defer p.deinit();
    if (p.value.id.len == 0) return orchErr(gpa, "swarm_status: an id is required");
    var sw = app.sup.resolve(p.value.id) orelse return orchErr(gpa, "swarm_status: no such swarm");
    if (sw.uid != uid) return orchErr(gpa, "swarm_status: that swarm isn't yours");

    // WAIT while running: probe every ~2s (stop-checked every 250ms), bounded per call. A finished/dead swarm
    // returns immediately; a Stop mid-wait returns the current state so the turn's next boundary ends promptly.
    const t0 = nowSecs(app.io);
    var waited: i64 = 0;
    var last_frame: i64 = 0;
    while (!swarmTerminal(app, sw.run_dir, sw.created) and waited < SWARM_STATUS_WAIT_S) {
        var slice: usize = 0;
        stop: while (slice < 8) : (slice += 1) {
            if (stopRequestedSince(app, conv_dir, ctrl_cursor)) break :stop;
            sleepMsRaw(app.io, 250);
        }
        if (stopRequestedSince(app, conv_dir, ctrl_cursor)) break;
        waited = nowSecs(app.io) - t0;
        if (waited - last_frame >= 15) {
            last_frame = waited;
            var sb: [96]u8 = undefined;
            emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "hive still working — watching it ({d}s)", .{waited}) catch "watching the hive");
        }
        sw = app.sup.resolve(p.value.id) orelse break; // re-resolve: the registry entry can be replaced/removed
        if (sw.uid != uid) return orchErr(gpa, "swarm_status: that swarm isn't yours");
    }

    const ps = app.sup.pidStatus(sw.run_dir);
    const finished = blk: {
        var pb: [1280]u8 = undefined;
        const dp = std.fmt.bufPrint(&pb, "{s}/DONE", .{sw.run_dir}) catch break :blk false;
        if (std.Io.Dir.cwd().access(app.io, dp, .{})) |_| break :blk true else |_| break :blk false;
    };
    const note = if (finished or !ps.alive)
        "the hive is done — read its deliverable files (list_dir/read_file) and fold the results in"
    else
        "still working; this call WAITS while the hive runs — call swarm_status again to keep watching, steer_swarm to guide it, or do other useful work meanwhile. do NOT stop_swarm just because it is still running";
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"swarm_status\",\"id\":\"{s}\",\"state\":\"{s}\",\"minds\":{d},\"alive\":{s},\"finished\":{s},\"waited_s\":{d},\"note\":\"{s}\"}}", .{ sw.id, @tagName(sw.state), sw.minds, if (ps.alive) "true" else "false", if (finished) "true" else "false", waited, note }) catch emptyRes();
}

/// Read the veil's answered-ledger for a swarm ({run_dir}/veil_answered.jsonl — one ask_id per line). gpa-owned
/// blob or empty. The veil is the ONLY writer (in-process chat turn), so there's no cross-process contention.
fn readAnswered(app: *App, run_dir: []const u8) []u8 {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/veil_answered.jsonl", .{run_dir}) catch return emptyRes();
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(256 << 10)) catch emptyRes();
}

/// Is `id` listed (as a whole trimmed line) in a ledger blob?
fn idInLedger(blob: []const u8, id: []const u8) bool {
    if (id.len == 0) return false;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \r\t"), id)) return true;
    }
    return false;
}

/// swarm_asks — the OPEN questions a running swarm's minds raised (ask_veil) that the veil hasn't answered yet.
/// Reads {run_dir}/asks.jsonl (each line {id, mind, q}, a stable random id) and drops any id already in the
/// answered-ledger. gpa-owned JSON result.
fn asksTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "swarm_asks: could not parse args JSON");
    defer p.deinit();
    if (p.value.id.len == 0) return orchErr(gpa, "swarm_asks: an id is required");
    const sw = app.sup.resolve(p.value.id) orelse return orchErr(gpa, "swarm_asks: no such swarm");
    if (sw.uid != uid) return orchErr(gpa, "swarm_asks: that swarm isn't yours");

    const askpath = std.fmt.allocPrint(gpa, "{s}/asks.jsonl", .{sw.run_dir}) catch return orchErr(gpa, "swarm_asks: out of memory");
    defer gpa.free(askpath);
    const asks = std.Io.Dir.cwd().readFileAlloc(app.io, askpath, gpa, .limited(1 << 20)) catch return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"swarm_asks\",\"asks\":[]}") catch emptyRes();
    defer gpa.free(asks);
    const answered = readAnswered(app, sw.run_dir);
    defer if (answered.len > 0) gpa.free(answered);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":true,\"tool\":\"swarm_asks\",\"asks\":[") catch return emptyRes();
    var count: usize = 0;
    const R = struct { id: []const u8 = "", mind: []const u8 = "", q: []const u8 = "" };
    var it = std.mem.splitScalar(u8, asks, '\n');
    while (it.next()) |raw| {
        if (count >= 20) break; // cap the surfaced asks
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const rp = std.json.parseFromSlice(R, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer rp.deinit();
        if (rp.value.id.len == 0 or std.mem.trim(u8, rp.value.q, " \r\n\t").len == 0) continue;
        if (idInLedger(answered, rp.value.id)) continue;
        var obj: std.ArrayListUnmanaged(u8) = .empty;
        defer obj.deinit(gpa);
        const objs = build: {
            obj.appendSlice(gpa, "{\"ask_id\":") catch break :build false;
            http.jstr(gpa, &obj, rp.value.id) catch break :build false;
            obj.appendSlice(gpa, ",\"mind\":") catch break :build false;
            http.jstr(gpa, &obj, rp.value.mind) catch break :build false;
            obj.appendSlice(gpa, ",\"question\":") catch break :build false;
            http.jstr(gpa, &obj, rp.value.q) catch break :build false;
            obj.append(gpa, '}') catch break :build false;
            break :build true;
        };
        if (!objs) continue; // couldn't build this object — skip it (never emit a partial)
        if (count > 0) out.append(gpa, ',') catch break;
        out.appendSlice(gpa, obj.items) catch break;
        count += 1;
    }
    out.appendSlice(gpa, "]}") catch return emptyRes();
    return out.toOwnedSlice(gpa) catch emptyRes();
}

/// answer_swarm — deliver the veil's answer to a mind's open ask: write an `answer` control op (routed to that
/// mind's inbox by the worker's drainControl) and record the ask_id in the answered-ledger so swarm_asks stops
/// surfacing it. gpa-owned JSON result.
fn answerTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "", ask_id: []const u8 = "", mind: []const u8 = "", text: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "answer_swarm: could not parse args JSON");
    defer p.deinit();
    const a = p.value;
    if (a.id.len == 0 or a.ask_id.len == 0 or a.mind.len == 0 or std.mem.trim(u8, a.text, " \r\n\t").len == 0)
        return orchErr(gpa, "answer_swarm: id, ask_id, mind, and text are all required");
    const sw = app.sup.resolve(a.id) orelse return orchErr(gpa, "answer_swarm: no such swarm");
    if (sw.uid != uid) return orchErr(gpa, "answer_swarm: that swarm isn't yours");

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    const built = build: {
        line.appendSlice(gpa, "{\"op\":\"answer\",\"to\":") catch break :build false;
        http.jstr(gpa, &line, a.mind) catch break :build false;
        line.appendSlice(gpa, ",\"id\":") catch break :build false;
        http.jstr(gpa, &line, a.ask_id) catch break :build false;
        line.appendSlice(gpa, ",\"text\":") catch break :build false;
        http.jstr(gpa, &line, a.text) catch break :build false;
        line.appendSlice(gpa, "}\n") catch break :build false;
        break :build true;
    };
    if (!built) return orchErr(gpa, "answer_swarm: out of memory");
    const ctl = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{sw.run_dir}) catch return orchErr(gpa, "answer_swarm: out of memory");
    defer gpa.free(ctl);
    http.appendFile(app.io, gpa, ctl, line.items) catch return orchErr(gpa, "answer_swarm: could not write the control channel");
    // dedup ledger (best-effort — a failed write just means swarm_asks may re-show this ask)
    if (std.fmt.allocPrint(gpa, "{s}/veil_answered.jsonl", .{sw.run_dir})) |ap| {
        defer gpa.free(ap);
        if (std.fmt.allocPrint(gpa, "{s}\n", .{a.ask_id})) |aline| {
            defer gpa.free(aline);
            http.appendFile(app.io, gpa, ap, aline) catch {};
        } else |_| {}
    } else |_| {}
    return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"answer_swarm\",\"note\":\"answer delivered to the mind's inbox; it reads it on its next round\"}") catch emptyRes();
}

/// CLIENT-MODE tool execution: emit a {kind:"tool_request"} frame and BLOCK the turn until the client posts
/// the result back (POST .../tool_result → tool_results.jsonl). This is how a desk/CLI turn runs file/shell/
/// code tools with ITS OWN harness on the user's machine while the brain stays server-side. Stop-checked and
/// timed out so a disconnected client can't wedge the turn — a timeout returns an error the model then sees.
fn delegateTool(app: *App, conv_dir: []const u8, id: []const u8, name: []const u8, args: []const u8, ctrl_cursor: usize) []u8 {
    const gpa = app.gpa;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    const built = blk: {
        ev.appendSlice(gpa, "{\"kind\":\"tool_request\",\"id\":") catch break :blk false;
        http.jstr(gpa, &ev, id) catch break :blk false;
        ev.appendSlice(gpa, ",\"tool\":") catch break :blk false;
        http.jstr(gpa, &ev, name) catch break :blk false;
        ev.appendSlice(gpa, ",\"args\":") catch break :blk false;
        http.jstr(gpa, &ev, args) catch break :blk false; // raw args JSON carried as a string; the client parses it
        ev.append(gpa, '}') catch break :blk false;
        break :blk true;
    };
    if (built) emitEvent(app, conv_dir, ev.items);

    const CLIENT_TOOL_TIMEOUT_S: i64 = 180; // a client run_python / long shell can take a while
    return awaitClientResult(app, conv_dir, id, ctrl_cursor, CLIENT_TOOL_TIMEOUT_S) orelse
        gpa.dupe(u8, "(the client did not return a result in time — is the desk/CLI still connected?)") catch emptyRes();
}

/// Block until the client posts a result for `id` to /tool_result (or a stop lands / the timeout passes).
/// The one wait primitive under every client round-trip: delegated tools AND the sync protocol's manifest /
/// file-pull exchanges. gpa-owned result; null = stopped or timed out (callers degrade, never wedge).
fn awaitClientResult(app: *App, conv_dir: []const u8, id: []const u8, ctrl_cursor: usize, timeout_s: i64) ?[]u8 {
    const t0 = nowSecs(app.io);
    while (nowSecs(app.io) - t0 < timeout_s) {
        if (stopRequestedSince(app, conv_dir, ctrl_cursor)) return null;
        if (readToolResult(app, conv_dir, id)) |r| return r;
        sleepMsRaw(app.io, 150);
    }
    return null;
}

// ------------------------------------------------------------------ CLIENT-MODE WORKDIR SYNC (see chat/sync.zig)

/// How long a sync round-trip (manifest / file-pull) waits for the client. Short vs the tool timeout: a client
/// that answers delegated tools answers these instantly; a vanished client must not stall a cast for minutes.
const SYNC_WAIT_S: i64 = 60;

const SyncInfo = struct {
    shared: bool, // the probe token round-tripped: both sides read the SAME directory — no transfer ever needed
    parsed: ?std.json.Parsed(cync.ManifestResp), // the client's manifest (null when it never answered)

    fn deinit(si: *SyncInfo) void {
        if (si.parsed) |p| p.deinit();
    }
    fn manifest(si: *const SyncInfo) ?*const cync.ManifestResp {
        return if (si.parsed) |*p| &p.value else null;
    }
};

/// One manifest round-trip with the client (+ same-disk probe): write a token into the SERVER's copy of the
/// workdir, ask the client for its manifest, and see whether the token came back. A non-empty `root` asks the
/// client to manifest THAT absolute directory on its machine instead of the conv workdir (the sync_dir
/// projection) — the probe then never matches, so a rooted exchange always runs the full protocol, which is
/// exactly right (the source dir is never the server's dest dir). null = the client never answered (no client
/// attached / gone) — callers degrade to their no-manifest behavior, never wedge.
fn syncExchange(app: *App, conv_dir: []const u8, workdir: []const u8, ctrl_cursor: usize, root: []const u8) ?SyncInfo {
    const gpa = app.gpa;
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, workdir, .default_dir) catch {};
    // the probe token: random hex, written server-side, echoed by the client only if it sees the same disk
    var rnd: [8]u8 = undefined;
    app.io.random(&rnd);
    var tokb: [16]u8 = undefined;
    const token = std.fmt.bufPrint(&tokb, "{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return null;
    var pb: [1500]u8 = undefined;
    const probe_path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ workdir, cync.PROBE_NAME }) catch return null;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = probe_path, .data = token }) catch {};
    defer std.Io.Dir.cwd().deleteFile(app.io, probe_path) catch {};

    var idb: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "sync{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return null;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    const built = blk: {
        ev.appendSlice(gpa, "{\"kind\":\"sync_request\",\"id\":") catch break :blk false;
        http.jstr(gpa, &ev, id) catch break :blk false;
        if (root.len > 0) {
            ev.appendSlice(gpa, ",\"root\":") catch break :blk false;
            http.jstr(gpa, &ev, root) catch break :blk false;
        }
        ev.append(gpa, '}') catch break :blk false;
        break :blk true;
    };
    if (!built) return null;
    emitEvent(app, conv_dir, ev.items);
    const resp = awaitClientResult(app, conv_dir, id, ctrl_cursor, SYNC_WAIT_S) orelse return null;
    defer gpa.free(resp);
    const parsed = std.json.parseFromSlice(cync.ManifestResp, gpa, resp, .{ .ignore_unknown_fields = true }) catch return null;
    const shared = std.mem.eql(u8, std.mem.trim(u8, parsed.value.probe, " \r\n\t"), token);
    return .{ .shared = shared, .parsed = parsed };
}

/// Does the client's manifest already carry `rel` with this exact content hash? (Linear scan — manifests are
/// capped at MAX_FILES entries.)
fn clientHasFile(m: ?*const cync.ManifestResp, rel: []const u8, hash: []const u8) bool {
    const mm = m orelse return false;
    for (mm.files) |e| {
        if (std.mem.eql(u8, e.p, rel) and std.mem.eql(u8, e.h, hash)) return true;
    }
    return false;
}

/// CLIENT MODE, cast time (client→server): the hive is about to build in the SERVER's builds/{conv}/work, but
/// in client mode every file the veil wrote — and anything a client-side script generated or the user dropped
/// in — exists only on the CLIENT. Pull the difference down first: one manifest round-trip, then only the
/// files whose hash differs from the server's copy. Same-disk installs short-circuit on the probe (zero
/// transfers); a client that never answers degrades to casting with what the server has.
fn pullClientFiles(app: *App, conv_dir: []const u8, workdir: []const u8, ctrl_cursor: usize) void {
    _ = pullClientFilesRooted(app, conv_dir, workdir, ctrl_cursor, "");
}

/// The pull engine behind both cast-time workdir sync (root="") and the sync_dir projection (root = an
/// absolute directory on the CLIENT's machine, mirrored into `workdir` server-side). Returns how many files
/// landed; -1 = the client never answered the manifest request.
fn pullClientFilesRooted(app: *App, conv_dir: []const u8, workdir: []const u8, ctrl_cursor: usize, root: []const u8) i64 {
    const gpa = app.gpa;
    var si = syncExchange(app, conv_dir, workdir, ctrl_cursor, root) orelse return -1;
    defer si.deinit();
    if (si.shared) return 0; // same directory — the hive already sees the client's files
    const m = si.manifest() orelse return 0;

    // want-list: every client file the server's copy is missing or has different bytes for
    var paths: std.ArrayListUnmanaged(u8) = .empty;
    defer paths.deinit(gpa);
    var want: usize = 0;
    for (m.files) |e| {
        if (!cync.safeSyncPath(e.p)) continue;
        var fb: [1700]u8 = undefined;
        const full = std.fmt.bufPrint(&fb, "{s}/{s}", .{ workdir, e.p }) catch continue;
        var same = false;
        if (std.Io.Dir.cwd().readFileAlloc(app.io, full, gpa, .limited(cync.FILE_CAP)) catch null) |cur| {
            var hb: [16]u8 = undefined;
            same = std.mem.eql(u8, cync.hashHex(cur, &hb), e.h);
            gpa.free(cur);
        }
        if (same) continue;
        const ok = blk: {
            if (want > 0) paths.append(gpa, ',') catch break :blk false;
            http.jstr(gpa, &paths, e.p) catch break :blk false;
            break :blk true;
        };
        if (!ok) return 0;
        want += 1;
    }
    if (want == 0) return 0;

    // pull the batch and materialize it into the server's workdir
    var rnd: [8]u8 = undefined;
    app.io.random(&rnd);
    var idb: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "pull{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return 0;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    const built = blk: {
        ev.appendSlice(gpa, "{\"kind\":\"file_pull\",\"id\":") catch break :blk false;
        http.jstr(gpa, &ev, id) catch break :blk false;
        if (root.len > 0) {
            ev.appendSlice(gpa, ",\"root\":") catch break :blk false;
            http.jstr(gpa, &ev, root) catch break :blk false;
        }
        ev.appendSlice(gpa, ",\"paths\":[") catch break :blk false;
        ev.appendSlice(gpa, paths.items) catch break :blk false;
        ev.appendSlice(gpa, "]}") catch break :blk false;
        break :blk true;
    };
    if (!built) return 0;
    emitEvent(app, conv_dir, ev.items);
    const resp = awaitClientResult(app, conv_dir, id, ctrl_cursor, SYNC_WAIT_S) orelse return 0;
    defer gpa.free(resp);
    const parsed = std.json.parseFromSlice(cync.PullResp, gpa, resp, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();
    var got: usize = 0;
    for (parsed.value.files) |f| {
        if (!cync.safeSyncPath(f.p) or f.c.len == 0 or f.c.len > cync.FILE_CAP) continue;
        var fb: [1700]u8 = undefined;
        const full = std.fmt.bufPrint(&fb, "{s}/{s}", .{ workdir, f.p }) catch continue;
        if (std.fs.path.dirname(full)) |parent| _ = std.Io.Dir.cwd().createDirPathStatus(app.io, parent, .default_dir) catch {};
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = full, .data = f.c }) catch continue;
        got += 1;
    }
    if (got > 0) {
        var sb: [96]u8 = undefined;
        emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "pulled {d} file(s) from your machine", .{got}) catch "pulled your files");
    }
    return @intCast(got);
}

/// CLIENT MODE, hive done (server→client): a finished cast's files exist only in the SERVER's run dir, but every
/// file tool is delegated to the CLIENT, which reads its own disk — so without a push the veil reads "no such
/// file" over work the hive verifiably produced (then wastefully redoes it), and a remote client never receives
/// the deliverables at all. Called before each delegated tool: once this conversation's cast is terminal and not
/// yet synced, exchange manifests and emit only the CHANGED files as {kind:"file_sync"} frames — the client
/// writes each into its local workdir BEFORE it executes the next delegated tool (frames are processed in
/// order). A same-disk install detects via the probe and transfers nothing. Marker-deduped per run; no-op while
/// the hive still runs or when there is no cast.
fn maybeSyncCastFiles(app: *App, uid: u64, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize) void {
    var run_buf: [1280]u8 = undefined;
    var run_dir: []const u8 = "";
    if (app.sup.resolve(conv)) |sw| {
        if (sw.uid != uid) return;
        if (!swarmTerminal(app, sw.run_dir, sw.created)) return; // sync once it finishes
        run_dir = copyTo(&run_buf, sw.run_dir) orelse return; // sw points into the registry; copy before slow IO
    } else {
        // Registry entry gone (server restarted after the cast) — fall back to the conventional run dir this
        // conversation's casts always use, and require its terminal DONE marker before syncing anything.
        const at = std.mem.lastIndexOf(u8, conv_dir, "/convs/") orelse return;
        run_dir = std.fmt.bufPrint(&run_buf, "{s}/builds/{s}", .{ conv_dir[0..at], conv }) catch return;
        var db: [1400]u8 = undefined;
        const done = std.fmt.bufPrint(&db, "{s}/DONE", .{run_dir}) catch return;
        _ = std.Io.Dir.cwd().access(app.io, done, .{}) catch return; // never sync a half-written run
    }
    // Dedup marker lives in the RUN dir: a re-cast resets that dir, so the fresh run re-syncs naturally.
    var mb: [1400]u8 = undefined;
    const marker = std.fmt.bufPrint(&mb, "{s}/.filesync_done", .{run_dir}) catch return;
    if (std.Io.Dir.cwd().access(app.io, marker, .{})) |_| return else |_| {}
    // Marker FIRST: a sync that trips a persistent walk error must not re-fire before every future tool call.
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = marker, .data = "" }) catch {};

    var wb: [1400]u8 = undefined;
    const work = std.fmt.bufPrint(&wb, "{s}/work", .{run_dir}) catch return;
    // manifest exchange: shared disk → nothing to push; no answer → push everything (the pre-manifest behavior)
    var si_opt = syncExchange(app, conv_dir, work, ctrl_cursor, "");
    defer if (si_opt) |*si| si.deinit();
    if (si_opt) |si| {
        if (si.shared) return; // the client reads the same directory the hive wrote — already "synced"
    }
    const manifest: ?*const cync.ManifestResp = if (si_opt) |*si| si.manifest() else null;
    const sent = emitRunFiles(app, conv_dir, work, manifest);
    if (sent > 0) {
        var sb: [96]u8 = undefined;
        emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "synced {d} hive file(s) to your workdir", .{sent}) catch "synced hive files");
    }
}

/// Bounded copy of `s` into `buf` (null when it doesn't fit) — for slices whose owner may mutate under us.
fn copyTo(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Emit files under `work` as file_sync frames (recursive, bounded; dot-entries and binaries skipped — a NUL
/// byte can't ride a JSON string). With a client manifest, only files the client is missing (or holds with
/// different bytes) are emitted. Returns how many frames were emitted.
fn emitRunFiles(app: *App, conv_dir: []const u8, work: []const u8, manifest: ?*const cync.ManifestResp) usize {
    var sent: usize = 0;
    var budget: usize = cync.TOTAL_CAP;
    emitRunDirFiles(app, conv_dir, work, "", 0, &sent, &budget, manifest);
    return sent;
}

fn emitRunDirFiles(app: *App, conv_dir: []const u8, abs_dir: []const u8, rel: []const u8, depth: usize, sent: *usize, budget: *usize, manifest: ?*const cync.ManifestResp) void {
    const gpa = app.gpa;
    if (depth > cync.MAX_DEPTH or sent.* >= cync.MAX_FILES or budget.* == 0) return;
    var dir = std.Io.Dir.cwd().openDir(app.io, abs_dir, .{ .iterate = true }) catch return;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (sent.* >= cync.MAX_FILES or budget.* == 0) return;
        if (ent.name.len == 0 or ent.name[0] == '.') continue; // engine scratch (.search_health…) stays server-side
        var ab: [1800]u8 = undefined;
        const child_abs = std.fmt.bufPrint(&ab, "{s}/{s}", .{ abs_dir, ent.name }) catch continue;
        var rb: [512]u8 = undefined;
        const child_rel = (if (rel.len == 0)
            std.fmt.bufPrint(&rb, "{s}", .{ent.name})
        else
            std.fmt.bufPrint(&rb, "{s}/{s}", .{ rel, ent.name })) catch continue;
        switch (ent.kind) {
            .directory => emitRunDirFiles(app, conv_dir, child_abs, child_rel, depth + 1, sent, budget, manifest),
            .file => {
                const data = std.Io.Dir.cwd().readFileAlloc(app.io, child_abs, gpa, .limited(cync.FILE_CAP)) catch continue;
                defer gpa.free(data);
                if (data.len == 0 or data.len > budget.*) continue;
                if (!cync.isTextContent(data)) continue; // binaries can't ride a JSON string
                // DIFF: the client already holds these exact bytes → nothing to transfer
                var hb: [16]u8 = undefined;
                if (clientHasFile(manifest, child_rel, cync.hashHex(data, &hb))) continue;
                scrubUtf8(data);
                var ev: std.ArrayListUnmanaged(u8) = .empty;
                defer ev.deinit(gpa);
                const ok = blk: {
                    ev.appendSlice(gpa, "{\"kind\":\"file_sync\",\"path\":") catch break :blk false;
                    http.jstr(gpa, &ev, child_rel) catch break :blk false;
                    ev.appendSlice(gpa, ",\"content\":") catch break :blk false;
                    http.jstr(gpa, &ev, data) catch break :blk false;
                    ev.append(gpa, '}') catch break :blk false;
                    break :blk true;
                };
                if (!ok) continue;
                emitEvent(app, conv_dir, ev.items);
                budget.* -= data.len;
                sent.* += 1;
            },
            else => {},
        }
    }
}

/// Scan tool_results.jsonl for the line whose "id" matches; return its "result" (gpa-owned) or null (not yet).
fn readToolResult(app: *App, conv_dir: []const u8, id: []const u8) ?[]u8 {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/tool_results.jsonl", .{conv_dir}) catch return null;
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(8 << 20)) catch return null;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const R = struct { id: []const u8 = "", result: []const u8 = "" };
        const p = std.json.parseFromSlice(R, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (std.mem.eql(u8, p.value.id, id)) return gpa.dupe(u8, p.value.result) catch null;
    }
    return null;
}

fn runInnerAgentic(
    app: *App,
    uid: u64,
    conv: []const u8,
    conv_dir: []const u8,
    run_root: []const u8,
    base_url: []const u8,
    key: []const u8,
    model: []const u8,
    conv_buf: *std.ArrayListUnmanaged(u8),
    ctx: *tools.ToolCtx,
    steer_cursor: *usize,
    tool_obs: *std.ArrayListUnmanaged([]u8),
    tool_client: bool,
    tools_spent: *usize, // turn-scoped executed-call counter (shared across drive steps)
    tool_budget: usize, // ceiling for scheduled runs; maxInt for interactive chats (a human holds Stop)
) InnerResult {
    const gpa = app.gpa;
    const empty: []u8 = &[_]u8{};
    // the last narrated content across tool iterations — the salvage if we exhaust MAX_ITERS or a stop lands mid-loop.
    var last_content: []u8 = empty;
    defer if (last_content.len > 0) gpa.free(last_content);
    var any_tool = false; // did any tool run this pass? gates the drive loop's LOOP_QUESTION for pure-prose answers
    // REPEAT-CALL GUARD: a model in a research spiral re-issues the SAME network call (identical name+args)
    // over and over — observed live: a scheduled run burned 40+ near-duplicate web_search/web_fetch calls
    // without ever settling to write its deliverable. The result is already in context; re-running buys
    // nothing and costs minutes + tokens. Ledger every executed idempotent-network call's (name,args) hash;
    // a repeat is answered with a pointed refusal that steers the model to USE what it has. Stateful tools
    // (read_file, run_python, swarm_status, recall...) are exempt — their results legitimately change.
    var call_ledger: std.ArrayListUnmanaged(u64) = .empty;
    defer call_ledger.deinit(gpa);

    // Everything already in conv_buf when this pass begins (system + bounded history + prior drive steps). This
    // pass's tool-call/result growth is measured against it so within-turn compaction can bound just the growth.
    const base_len = conv_buf.items.len;

    // Offer the browser (+ pixel) and MCP tools whenever a CLIENT (desk/CLI, tool_client) is attached to run
    // them — that is the "client-side by default" model: the client's own machine can drive a browser and reach
    // its installed MCP servers, so the chat should always know it has the capability (the client controls
    // visibility via its browser-window setting). A server-side turn with no client (API/hive) still requires
    // the operator env flag. Adds ~10 tool defs to a client turn's prefill; that is the price of the capability
    // being available on demand.
    const turn_tools: []const u8 = blk: {
        const envon = struct {
            fn f(e: ?*const std.process.Environ.Map, name: []const u8) bool {
                const m = e orelse return false;
                const v = m.get(name) orelse return false;
                return v.len > 0 and !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false");
            }
        }.f;
        // Accessibility directive ("always include every tool"): a chat turn ALWAYS gets the browser/pixel/mcp
        // schema so a tool can never silently drop out. The old signals are retained (discarded here) only so the
        // reasoning stays legible; the swarm-mind schema in run.zig keeps its own env/tier gate.
        const had_signal = tool_client or envon(app.sup.parent_env, "NL_BROWSER_DRIVER") or envon(app.sup.parent_env, "NL_MCP");
        _ = had_signal;
        const b = ",\n" ++ tools.BROWSER_SCHEMA ++ ",\n" ++ tools.PIXEL_SCHEMA;
        const m = ",\n" ++ tools.MCP_SCHEMA;
        break :blk std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ TURN_TOOLS, b, m }) catch TURN_TOOLS;
    };
    defer if (turn_tools.ptr != TURN_TOOLS.ptr) gpa.free(@constCast(turn_tools));

    var iter: usize = 0;
    while (iter < MAX_ITERS) : (iter += 1) {
        // COOPERATIVE CONTROL (before each inference): a stop aborts with whatever narration we have; a steer is
        // folded straight into conv_buf as a user turn so THIS upcoming inference already honors it — folding only
        // at the outer drive-step boundary would delay it by however long a tool loop runs (minutes).
        switch (drainChatControl(app, conv_dir, steer_cursor, conv_buf)) {
            .stop => return .{ .outcome = .stopped, .content = gpa.dupe(u8, last_content) catch empty },
            .none => {},
        }

        // STREAMING: the model's reply + reasoning type out via streamOnDelta as {kind:token|reasoning,delta}
        // frames. The returned Step is the SAME accumulated shape complete() gives (content + reasoning +
        // tool_calls), so everything below is unchanged — and completeStream falls back to complete() itself
        // on any streaming trouble, so a backend that can't stream still works (on_delta just never fires).
        var sctx = StreamCtx{ .app = app, .conv_dir = conv_dir, .ctrl_cursor = steer_cursor.* };
        var step = llm.completeStream(gpa, app.io, run_root, "chat", base_url, key, model, conv_buf.items, turn_tools, 4096, 0.7, &sctx, streamOnDelta, streamShouldAbort);
        defer step.deinit(gpa);
        streamFlush(&sctx); // emit the last buffered <FLUSH_CHARS chunk so the tail of the reply/reasoning isn't lost

        // STOP DURING STREAMING: the abort hook killed the stream mid-generation. Commit the partial that already
        // streamed to the user (step.content) as the stopped narration and end the turn — don't fall through to
        // treat the truncated reply as a settled answer or drive on it.
        if (stopRequestedSince(app, conv_dir, steer_cursor.*)) {
            const partial = if (step.content.len > 0) step.content else last_content;
            return .{ .outcome = .stopped, .content = gpa.dupe(u8, partial) catch empty };
        }

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
        // reply, and the drive loop churns on it. Recover the call(s) from the markup + strip it from the content,
        // so the tool actually executes and the turn makes progress.
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
            return .{ .outcome = .settled, .content = gpa.dupe(u8, step.content) catch empty, .streamed = sctx.streamed, .tools_ran = any_tool };

        any_tool = true; // this iteration is running tools — the turn did agentic work, so the drive loop may continue

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

        // ... then run each call, narrate + observe its result, and append its result turn. A steer that lands
        // mid-batch is drained into `pending_steer` (a user turn may NOT sit between an assistant tool_calls turn
        // and its tool results — providers 400 on that) and spliced in AFTER the batch, before the next inference.
        var pending_steer: std.ArrayListUnmanaged(u8) = .empty;
        defer pending_steer.deinit(gpa);
        for (step.calls, 0..) |c, ci| {
            // COOPERATIVE CONTROL (between tool calls): a single inference can request many tools, each taking
            // seconds — checking only per-inference lets a Stop (or a steer) wait minutes. A stop aborts with the
            // narration so far; a steer SKIPS the still-queued calls (each still gets a result row — the shape
            // requires one per call id) so the next inference honors it in seconds.
            switch (drainChatControl(app, conv_dir, steer_cursor, &pending_steer)) {
                .stop => return .{ .outcome = .stopped, .content = gpa.dupe(u8, last_content) catch empty },
                .none => {},
            }
            if (pending_steer.items.len > 0) {
                var skipped: usize = 0;
                for (step.calls[ci..]) |sk| {
                    var skobj: std.ArrayListUnmanaged(u8) = .empty;
                    defer skobj.deinit(gpa);
                    const sk_ok = blk: {
                        skobj.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":") catch break :blk false;
                        http.jstr(gpa, &skobj, sk.id) catch break :blk false;
                        skobj.appendSlice(gpa, ",\"content\":\"(skipped — the user steered the conversation mid-batch; honor their newest message first)\"}") catch break :blk false;
                        conv_buf.appendSlice(gpa, skobj.items) catch break :blk false;
                        break :blk true;
                    };
                    if (!sk_ok) return .{ .outcome = .hard_error, .content = empty };
                    skipped += 1;
                }
                var nb: [96]u8 = undefined;
                emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&nb, "steer received — skipped {d} queued tool call(s)", .{skipped}) catch "steer received");
                break;
            }
            emitToolState(app, conv_dir, c.name, "start", "");
            // REPEAT-CALL GUARD (see call_ledger above): an exact repeat of an idempotent network call is
            // answered from the ledger — the model is told to use the result it already has and move on.
            const call_h = std.hash.Fnv1a_64.hash(c.name) ^ std.hash.Fnv1a_64.hash(c.args);
            var repeated = false;
            if (dedupableTool(c.name)) {
                for (call_ledger.items) |h| {
                    if (h == call_h) {
                        repeated = true;
                        break;
                    }
                }
                if (!repeated) call_ledger.append(gpa, call_h) catch {};
            }
            const result = if (repeated)
                (gpa.dupe(u8, "(you already ran this EXACT call earlier this turn — its full result is above in this conversation. Do NOT re-run it: extract what you need from the earlier result and MOVE ON to the next step, e.g. writing the deliverable file.)") catch @constCast(""))
            else if (dedupableTool(c.name) and tools_spent.* >= tool_budget) blk_ob: {
                // BUDGET CEILING (scheduled runs): the research appetite is unbounded but the wallet is not.
                // Past the budget, NETWORK research calls are answered with "finalize now" — but LOCAL tools
                // (write_file/edit_file/read_file/run_tests) always execute, because finalizing IS writing:
                // the first cut refused the very write_file the refusal demanded, and the run spun. One
                // status frame the first time it trips.
                if (tools_spent.* == tool_budget) {
                    tools_spent.* += 1;
                    var bb: [96]u8 = undefined;
                    emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&bb, "research budget ({d}) exhausted — steering the run to finalize", .{tool_budget}) catch "research budget exhausted — finalizing");
                }
                break :blk_ob gpa.dupe(u8, "(this scheduled run's RESEARCH budget is exhausted — no further web/search calls will execute. write_file/edit_file/read_file still work: write or finalize the deliverable NOW from what you already gathered, state any remaining gaps inside it, then reply DONE.)") catch @constCast("");
            } else blk: {
                if (dedupableTool(c.name)) tools_spent.* += 1; // only network research spends the budget
                // CLIENT MODE: if this conversation's cast just finished, push its files down FIRST — the frames
                // land before this tool's tool_request, and the client processes frames in order, so a delegated
                // list_dir/read_file sees the hive's work on the client's own disk instead of "no such file".
                if (tool_client) maybeSyncCastFiles(app, uid, conv, conv_dir, steer_cursor.*);
                // ORCHESTRATION verbs (cast/steer_swarm/stop_swarm/swarm_status) are the VEIL's — handled
                // in-process via deploy_service + app.sup, NOT the mind-tool executor. Everything else executes
                // as a mind tool: in CLIENT mode (a desk/CLI turn) it is DELEGATED to the client's harness so
                // file/shell/code tools act on the USER's machine; otherwise it runs here (a hive/server turn).
                break :blk orchTool(app, uid, conv, conv_dir, steer_cursor.*, base_url, key, model, c.name, c.args, tool_client) orelse
                    (if (tool_client) delegateTool(app, conv_dir, c.id, c.name, c.args, steer_cursor.*) else tools.execute(ctx, c.name, c.args));
            };
            scrubUtf8(result); // fetched bytes may be invalid UTF-8; must be valid before it rides in JSON
            emitToolState(app, conv_dir, c.name, "done", clipBytes(result, 200));

            // HIPPOCAMPUS (observe): a SUCCESSFUL tool finding is durable knowledge. Gate out engine error strings
            // — "(...)" notes and `"ok":false` payloads — and never observe assistant reply content (confab fix).
            // QUEUED, not observed inline: each observe spawns a subprocess, which serialized big tool batches.
            // runTurn flushes the queue at turn exit (bounded — a runaway afk turn can't hoard notes forever).
            if (result.len > 0 and result[0] != '(' and std.mem.indexOf(u8, result, "\"ok\":false") == null and tool_obs.items.len < 200) {
                if (std.fmt.allocPrint(gpa, "tool {s}: {s}", .{ c.name, clipBytes(result, 200) })) |note| {
                    tool_obs.append(gpa, note) catch gpa.free(note);
                } else |_| {}
            }

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
        // MID-BATCH STEER SPLICE — after compaction, so the literal user instruction can never be folded into a
        // summary note. The next completion sees: assistant tool_calls → results (real + skipped) → user steer.
        if (pending_steer.items.len > 0)
            conv_buf.appendSlice(gpa, pending_steer.items) catch return .{ .outcome = .hard_error, .content = empty };
        // loop: feed the tool results back for the next completion
    }

    // Ran out of tool iterations mid-loop: ask for a brief no-tools SUMMARY so the reply is a real closing message
    // ("here's what I built…") rather than a raw step-limit string. Fall back to the last narration, then a
    // friendly note, only if the summary itself fails.
    // These salvage returns follow a full tool loop, so tools_ran reflects the real work (any_tool) — the drive
    // loop must keep its multi-step continuation, not be short-circuited by the no-tools fast path.
    if (summarizeTurn(app, run_root, base_url, key, model, conv_buf.items)) |sum| return .{ .outcome = .settled, .content = sum, .tools_ran = any_tool };
    const fallback: []const u8 = if (last_content.len > 0) last_content else "I did as much as I could this turn — say \"continue\" if there's more you want.";
    return .{ .outcome = .settled, .content = gpa.dupe(u8, fallback) catch empty, .tools_ran = any_tool };
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

/// Current byte length of control.jsonl (0 if absent/unreadable) — the cursor past which a later stop op counts.
/// A stat, not a read: the stop poll fires ~50×/s during a stream, so reading the whole file (O(control-size) on a
/// file that only grows across a long conversation's steers) would be a hot-path cost.
fn controlLen(app: *App, conv_dir: []const u8) usize {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{conv_dir}) catch return 0;
    defer gpa.free(path);
    const st = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch return 0;
    return std.math.cast(usize, st.size) orelse 0;
}

/// The bytes of control.jsonl past `cursor` (gpa-owned; null = nothing new / unreadable). POSITIONAL tail read,
/// mirroring convEvents — never the whole file.
fn readControlTail(app: *App, conv_dir: []const u8, cursor: usize) ?[]u8 {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{conv_dir}) catch return null;
    defer gpa.free(path);
    const f = std.Io.Dir.cwd().openFile(app.io, path, .{}) catch return null;
    defer f.close(app.io);
    const size: usize = std.math.cast(usize, f.length(app.io) catch 0) orelse 0;
    if (size <= cursor) return null;
    const want = @min(size - cursor, 1 << 20);
    const buf = gpa.alloc(u8, want) catch return null;
    const n = f.readPositionalAll(app.io, buf, cursor) catch {
        gpa.free(buf);
        return null;
    };
    if (n == 0) {
        gpa.free(buf);
        return null;
    }
    return buf[0..n];
}

/// True if control.jsonl carries a `"op":"stop"` in the bytes appended AFTER `cursor` (i.e. since the turn began).
/// Best-effort: any read error means "no stop" (never block the turn on a control-file hiccup).
fn stopRequestedSince(app: *App, conv_dir: []const u8, cursor: usize) bool {
    const tail = readControlTail(app, conv_dir, cursor) orelse return false;
    defer app.gpa.free(tail);
    return std.mem.indexOf(u8, tail, "\"op\":\"stop\"") != null;
}

const CtlResult = enum { none, stop };

/// Drain the conv's control.jsonl from *cursor (between drive steps): a `stop` op ENDS the turn; a `steer`/`say`
/// op INJECTS the user's text as a mid-turn user message so the next inference incorporates it — this is the user
/// "posting to steer" a running turn without stopping it. Advances *cursor past everything read.
// ---- DURABLE USER MEMORY: the user's cross-conversation facts (keys/logins/preferences) live in
// {data}/.veil-desk/memories.jsonl — one {"cat","text"} JSON line each. The DESK writes this file; the server
// shares the same localhost data dir, so reading + appending it keeps ONE durable store (no split-brain). ----
const MEM_INJECT_CAP = 96; // newest N durable memories injected (bounded prompt)

fn memoriesPath(app: *App, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.veil-desk/memories.jsonl", .{app.data}) catch null;
}

/// Inject the user's durable memory as a "YOUR MEMORY" system message right after the recall block. Additive: an
/// absent/empty store leaves conv_buf unchanged.
fn injectDurableMemory(app: *App, conv_buf: *std.ArrayListUnmanaged(u8)) void {
    const gpa = app.gpa;
    var pb: [700]u8 = undefined;
    const path = memoriesPath(app, &pb) orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(256 << 10)) catch return;
    defer gpa.free(data);
    // gather non-empty JSON lines, keep the NEWEST cap (append order = oldest first)
    var slices: std.ArrayListUnmanaged([]const u8) = .empty;
    defer slices.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len > 0 and ln[0] == '{') slices.append(gpa, ln) catch break;
    }
    if (slices.items.len == 0) return;
    const from = slices.items.len -| MEM_INJECT_CAP;
    var block: std.ArrayListUnmanaged(u8) = .empty;
    defer block.deinit(gpa);
    block.appendSlice(gpa, "YOUR MEMORY (durable facts this user asked you to keep across conversations — keys, logins, preferences, environment). Use them; do not re-REMEMBER what's already here:\n") catch return;
    const M = struct { cat: []const u8 = "", text: []const u8 = "" };
    var any = false;
    for (slices.items[from..]) |ln| {
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        const tx = std.mem.trim(u8, p.value.text, " \r\n\t");
        if (tx.len == 0) continue;
        block.append(gpa, '-') catch break;
        block.append(gpa, ' ') catch break;
        if (p.value.cat.len > 0) {
            block.append(gpa, '[') catch break;
            block.appendSlice(gpa, p.value.cat) catch break;
            block.appendSlice(gpa, "] ") catch break;
        }
        block.appendSlice(gpa, tx) catch break;
        block.append(gpa, '\n') catch break;
        any = true;
    }
    if (!any) return;
    conv_buf.appendSlice(gpa, ",{\"role\":\"system\",\"content\":") catch return;
    http.jstr(gpa, conv_buf, block.items) catch return;
    conv_buf.append(gpa, '}') catch return;
}

/// True if `fact` (trimmed) is already stored — exact text match against the durable store (dedup).
fn durableMemoryHas(app: *App, fact: []const u8) bool {
    const gpa = app.gpa;
    var pb: [700]u8 = undefined;
    const path = memoriesPath(app, &pb) orelse return false;
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(256 << 10)) catch return false;
    defer gpa.free(data);
    const M = struct { text: []const u8 = "" };
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0 or ln[0] != '{') continue;
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (std.mem.eql(u8, std.mem.trim(u8, p.value.text, " \r\n\t"), fact)) return true;
    }
    return false;
}

/// Append one durable memory {cat,text} to the shared store (dedup on exact text). Category clamped to one short word.
fn storeDurableMemory(app: *App, cat_in: []const u8, fact_in: []const u8) void {
    const gpa = app.gpa;
    const fact = std.mem.trim(u8, fact_in, " \r\n\t");
    if (fact.len < 2) return;
    const fact_clip = fact[0..@min(fact.len, 260)];
    if (durableMemoryHas(app, fact_clip)) return;
    var cat = std.mem.trim(u8, cat_in, " \r\n\t[]");
    if (cat.len == 0) cat = "fact";
    if (cat.len > 20) cat = cat[0..20];
    var pb: [700]u8 = undefined;
    const path = memoriesPath(app, &pb) orelse return;
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    defer jb.deinit(gpa);
    jb.appendSlice(gpa, "{\"cat\":") catch return;
    http.jstr(gpa, &jb, cat) catch return;
    jb.appendSlice(gpa, ",\"text\":") catch return;
    http.jstr(gpa, &jb, fact_clip) catch return;
    jb.appendSlice(gpa, "}\n") catch return;
    http.appendFile(app.io, gpa, path, jb.items) catch {};
}

/// Drop durable memories whose text contains `match` (case-insensitive) — whole-file rewrite.
fn forgetDurableMemory(app: *App, match_in: []const u8) void {
    const gpa = app.gpa;
    const match = std.mem.trim(u8, match_in, " \r\n\t");
    if (match.len < 2) return;
    var pb: [700]u8 = undefined;
    const path = memoriesPath(app, &pb) orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(256 << 10)) catch return;
    defer gpa.free(data);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var removed = false;
    const M = struct { text: []const u8 = "" };
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        var drop = false;
        if (ln[0] == '{') {
            if (std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true })) |p| {
                defer p.deinit();
                if (std.ascii.indexOfIgnoreCase(p.value.text, match) != null) drop = true;
            } else |_| {}
        }
        if (drop) {
            removed = true;
            continue;
        }
        out.appendSlice(gpa, ln) catch return;
        out.append(gpa, '\n') catch return;
    }
    if (removed) std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// Parse a REMEMBER: body: an optional leading `[category]` then the fact. Returns cat+fact (cat defaults "fact").
fn parseRemember(body_in: []const u8) struct { cat: []const u8, fact: []const u8 } {
    const body = std.mem.trim(u8, body_in, " \t");
    if (body.len > 0 and body[0] == '[') {
        if (std.mem.indexOfScalar(u8, body, ']')) |cb| {
            const cat = std.mem.trim(u8, body[1..cb], " \t");
            return .{ .cat = if (cat.len > 0) cat else "fact", .fact = std.mem.trim(u8, body[cb + 1 ..], " \t") };
        }
    }
    return .{ .cat = "fact", .fact = body };
}

/// Act on a reply's REMEMBER:/FORGET: lines (store/forget in the shared durable memory) and return the reply with
/// those lines STRIPPED — the desk's processMemory ported. Returns an owned copy when it changed anything, else
/// null (caller keeps the original). `saved` receives the number of directives applied.
fn processMemoryDirectives(app: *App, text: []const u8, saved: *usize) ?[]u8 {
    const gpa = app.gpa;
    saved.* = 0;
    if (std.mem.indexOf(u8, text, "REMEMBER:") == null and std.mem.indexOf(u8, text, "FORGET:") == null) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const ln = std.mem.trim(u8, line, " \r\t");
        if (std.ascii.startsWithIgnoreCase(ln, "REMEMBER:")) {
            const spec = parseRemember(ln["REMEMBER:".len..]);
            if (spec.fact.len >= 2) {
                storeDurableMemory(app, spec.cat, spec.fact);
                saved.* += 1;
            }
            continue; // strip
        }
        if (std.ascii.startsWithIgnoreCase(ln, "FORGET:")) {
            const m = std.mem.trim(u8, ln["FORGET:".len..], " \t");
            if (m.len >= 2) {
                forgetDurableMemory(app, m);
                saved.* += 1;
            }
            continue; // strip
        }
        if (!first) out.append(gpa, '\n') catch return null;
        out.appendSlice(gpa, std.mem.trimEnd(u8, line, "\r")) catch return null;
        first = false;
    }
    // trim + drop a now-dangling intro line ("Saved:", "I've remembered:") left pointing at stripped directives
    var s = std.mem.trim(u8, out.items, " \r\n\t");
    if (saved.* > 0) s = stripDanglingMemoryIntro(s);
    const owned = gpa.dupe(u8, s) catch {
        out.deinit(gpa);
        return null;
    };
    out.deinit(gpa);
    return owned;
}

/// Drop a trailing intro line ("Saved preferences:", "I've remembered:") left dangling after directives were
/// stripped. Ported from the desk stripDanglingMemoryIntro.
fn stripDanglingMemoryIntro(text: []const u8) []const u8 {
    const nl = std.mem.lastIndexOfScalar(u8, text, '\n');
    const last_raw = if (nl) |i| text[i + 1 ..] else text;
    const ll = std.mem.trim(u8, last_raw, " \t*_#>`-");
    if (ll.len == 0 or ll.len > 48 or ll[ll.len - 1] != ':') return text;
    var lb: [64]u8 = undefined;
    const n = @min(ll.len, lb.len);
    for (ll[0..n], 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const low = lb[0..n];
    const intro = std.mem.indexOf(u8, low, "sav") != null or std.mem.indexOf(u8, low, "remember") != null or
        std.mem.indexOf(u8, low, "prefer") != null or std.mem.indexOf(u8, low, "memor") != null or
        std.mem.indexOf(u8, low, "stored") != null or std.mem.indexOf(u8, low, "noted") != null or
        std.mem.indexOf(u8, low, "keep") != null;
    if (!intro) return text;
    return std.mem.trimEnd(u8, if (nl) |i| text[0..i] else "", " \r\n\t*_#>`-");
}

/// One last control drain that persists any still-unconsumed steer as a durable user message (drainChatControl
/// does the persisting). The scratch fragments are discarded — no inference follows; the NEXT turn's history
/// replay carries the text instead. Called on every turn-completion path that isn't an explicit user stop.
fn salvageSteers(app: *App, conv_dir: []const u8, cursor: *usize) void {
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(app.gpa);
    if (drainChatControl(app, conv_dir, cursor, &scratch) == .none and scratch.items.len > 0)
        emitKV(app, conv_dir, "status", "text", "steer noted — it will lead the next turn");
}

/// Drain control.jsonl past `cursor`: a `stop` op returns .stop (cursor consumed to EOF); each `steer`/`say` op
/// is appended to `buf` as a `,{"role":"user","content":…}` fragment (the CALLER decides when that buffer is in
/// a position where a user turn is legal — directly conv_buf before an inference, or a pending list mid-tool-batch)
/// AND persisted as a durable user message. Emits a "steering:" status frame per folded op so the client sees it land.
fn drainChatControl(app: *App, conv_dir: []const u8, cursor: *usize, buf: *std.ArrayListUnmanaged(u8)) CtlResult {
    const gpa = app.gpa;
    const tail = readControlTail(app, conv_dir, cursor.*) orelse return .none;
    defer gpa.free(tail);
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const C = struct { op: []const u8 = "", text: []const u8 = "" };
        const p = std.json.parseFromSlice(C, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (std.mem.eql(u8, p.value.op, "stop")) {
            cursor.* += tail.len;
            return .stop;
        }
        if ((std.mem.eql(u8, p.value.op, "steer") or std.mem.eql(u8, p.value.op, "say")) and std.mem.trim(u8, p.value.text, " \r\n\t").len > 0) {
            buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch continue;
            http.jstr(gpa, buf, p.value.text) catch {};
            buf.append(gpa, '}') catch {};
            // DURABLE: a folded steer is a real user turn — persist it so the NEXT turn's history replay (and a
            // turn that ends before acting on it) still carries the user's course correction instead of dropping
            // it when the next turn re-snapshots the control cursor past it.
            appendMsg(app, conv_dir, "user", p.value.text, "user", nowSecs(app.io));
            var sb: [200]u8 = undefined;
            emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "steering: {s}", .{clipBytes(p.value.text, 120)}) catch "steering");
        }
    }
    cursor.* += tail.len;
    return .none;
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
fn assembleHistory(app: *App, conv_dir: []const u8, user_text: []const u8, conv_buf: *std.ArrayListUnmanaged(u8), recall_frag: []const u8) void {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return;
    defer gpa.free(mpath);

    const head_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return;
    defer gpa.free(head_buf);
    const tail_buf = gpa.alloc(u8, cctx.HISTORY_WINDOW_BYTES) catch return;
    defer gpa.free(tail_buf);

    const ht = cctx.readHeadTail(app.io, mpath, head_buf, tail_buf) orelse return; // no history yet → nothing to seed
    const view = cctx.computeView(ht.head, ht.tail, ht.size, cctx.HISTORY_WINDOW_BYTES);

    // ROLLING SUMMARY: when older turns have scrolled past the recency window, inject the condensed running summary
    // of them so continuity survives beyond the window + relevance recall. CRITICAL PATH: only the PERSISTED summary
    // is loaded here (a cheap file read) — the LLM fold-in of newly-dropped history is deferred to refreshSummary at
    // end-of-turn, so the first streamed token never waits on a summarization round-trip. The injected summary can
    // therefore lag by one turn's worth of dropped middle; the recency window + goal pin + relevance recall cover it.
    if (view.gap) {
        const sum = loadSummary(app, conv_dir);
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

    // RELEVANCE RECALL (varies per message): placed here — after the stable prefix, before the window — so the
    // provider's prompt-prefix cache keeps hitting on system + memory + summary + goal across inferences.
    if (recall_frag.len > 0) conv_buf.appendSlice(gpa, recall_frag) catch {};

    // RECENCY WINDOW: replay the newest complete turns verbatim (includes the just-appended user message).
    seedLines(app, conv_buf, view.window, cctx.HISTORY_WINDOW_BYTES);

    // SAFETY NET: an EMPTY window means the newest line (the just-appended current user message) is itself larger
    // than the recency window and fell out — so the live question would ride only on the fallible rolling summary
    // (and be lost entirely if that summary call fails or the message exceeds SUMMARY_SPAN_CAP). Seed the current
    // message verbatim (clipped) so the model always sees the actual question it must answer.
    if (view.window.len == 0) appendMsgObj(gpa, conv_buf, "user", user_text, cctx.CURRENT_MSG_PIN_CAP);
}

/// Serializes context.json reads/writes across the (rare) case of a deferred refreshSummary on one turn's thread
/// racing the next turn's loadSummary — held only for the quick file ops, NEVER across the summarization LLM call.
var ctx_json_mtx: std.Io.Mutex = .init;

/// CRITICAL PATH: load ONLY the persisted rolling summary text from {conv_dir}/context.json (a cheap file read, no
/// LLM). The fold-in of newly-dropped history is deferred to refreshSummary at end-of-turn, so the first streamed
/// token never waits on a summarization round-trip. gpa-owned text, or an EMPTY slice (never null) if absent/garbage.
fn loadSummary(app: *App, conv_dir: []const u8) []u8 {
    const gpa = app.gpa;
    const empty: []u8 = &[_]u8{};
    const cpath = std.fmt.allocPrint(gpa, "{s}/context.json", .{conv_dir}) catch return empty;
    defer gpa.free(cpath);
    ctx_json_mtx.lockUncancelable(app.io);
    defer ctx_json_mtx.unlock(app.io);
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, cpath, gpa, .limited(1 << 20)) catch return empty;
    defer gpa.free(raw);
    const S = struct { covered: usize = 0, summary: []const u8 = "" };
    const p = std.json.parseFromSlice(S, gpa, raw, .{ .ignore_unknown_fields = true }) catch return empty;
    defer p.deinit();
    if (p.value.summary.len == 0) return empty;
    return gpa.dupe(u8, p.value.summary) catch empty;
}

/// DEFERRED (end of a NORMAL turn, after the answer is delivered): if the recency window has rolled forward past
/// what the persisted summary covers, fold the newly-dropped span into the summary (one no-tools ctxsum completion)
/// and persist it for the NEXT turn. This is the ONLY place the summary advances — kept OFF the first-token path,
/// which is the whole point. Re-reads the (now-grown) transcript for a fresh view. Best-effort: any failure leaves
/// the prior summary intact (the next turn retries). The ctxsum LLM call runs OUTSIDE the context.json lock so it
/// never blocks a concurrent loadSummary; two overlapping refreshes just race to persist and the later (wider) wins.
fn refreshSummary(app: *App, conv_dir: []const u8, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8) void {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return;
    defer gpa.free(mpath);
    const head_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return;
    defer gpa.free(head_buf);
    const tail_buf = gpa.alloc(u8, cctx.HISTORY_WINDOW_BYTES) catch return;
    defer gpa.free(tail_buf);
    const ht = cctx.readHeadTail(app.io, mpath, head_buf, tail_buf) orelse return;
    const view = cctx.computeView(ht.head, ht.tail, ht.size, cctx.HISTORY_WINDOW_BYTES);
    if (!view.gap) return; // the window still covers everything → nothing has dropped that needs summarizing

    const cpath = std.fmt.allocPrint(gpa, "{s}/context.json", .{conv_dir}) catch return;
    defer gpa.free(cpath);

    // load current {covered, summary} under the lock (quick file read only)
    var covered: usize = 0;
    var summary: []u8 = &[_]u8{};
    {
        ctx_json_mtx.lockUncancelable(app.io);
        defer ctx_json_mtx.unlock(app.io);
        if (std.Io.Dir.cwd().readFileAlloc(app.io, cpath, gpa, .limited(1 << 20))) |raw| {
            defer gpa.free(raw);
            const S = struct { covered: usize = 0, summary: []const u8 = "" };
            if (std.json.parseFromSlice(S, gpa, raw, .{ .ignore_unknown_fields = true })) |p| {
                defer p.deinit();
                covered = p.value.covered;
                if (p.value.summary.len > 0) summary = gpa.dupe(u8, p.value.summary) catch &[_]u8{};
            } else |_| {}
        } else |_| {}
    }
    defer if (summary.len > 0) gpa.free(summary);

    // is there newly-dropped history to fold in? the summary should cover [goal_end, window_start)
    const target = view.window_start;
    const span_from = @max(covered, view.goal_end);
    if (target <= span_from) return; // already covered → nothing to do

    const span_buf = gpa.alloc(u8, cctx.SUMMARY_SPAN_CAP) catch return;
    defer gpa.free(span_buf);
    const span = cctx.readSpanTailTrimmed(app.io, mpath, span_from, target, span_buf) orelse return;
    if (span.len == 0) return;

    const updated = summarizeInto(app, run_root, base_url, key, model, summary, span) orelse return; // LLM call, no lock held
    defer gpa.free(updated);
    ctx_json_mtx.lockUncancelable(app.io);
    defer ctx_json_mtx.unlock(app.io);
    persistSummary(app, cpath, target, updated); // best-effort
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
