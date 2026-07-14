//! chat_context.zig — bounded LLM-context assembly for the server chat turn.
//!
//! The durable conversation log (messages.jsonl) grows without bound, but what we FEED the model each inference
//! must stay inside its context window. The old server turn replayed the ENTIRE transcript every inference, which
//! silently overflowed the model window after a few dozen turns and hit a hard 8 MiB read cliff (total amnesia)
//! on very long chats. This module projects the full history into a fixed budget instead of replaying it:
//!
//!   * pin the original goal (the first user message) — it anchors the whole arc,
//!   * replay only a RECENCY WINDOW of the newest turns (the bulk of what the model needs),
//!   * report the GAP so the caller can cover the dropped middle with a rolling summary + relevance recall.
//!
//! Storage stays full (the durable log is never truncated); only the CONTEXT is windowed. This file is pure +
//! std-only so the windowing math is unit-tested directly; the impure file reads use std.Io and are tested
//! against a temp file (like supervisor.readTail). The caller (chat_engine.zig) parses the windowed JSON lines
//! and owns the LLM-backed summary generation.

const std = @import("std");

/// Recency window: the newest ~this many bytes of messages.jsonl are replayed verbatim. ~28 KiB ≈ ~7k tokens at
/// ~4 bytes/token — with the system prompt (~1 KiB), a capped summary (≤6 KiB), and recall (~a few hundred B),
/// the assembled base is ~9k tokens, leaving ample room under a 32k-token model for this turn's working context
/// and the output reservation. Chosen to match the desk engine's 24 KiB tail window (which worked well live),
/// with a little more headroom now that a rolling summary carries the older context recall can't.
pub const HISTORY_WINDOW_BYTES: usize = 28 * 1024;

/// Head read: enough to always capture the first (goal) line even when the file is large. A goal message longer
/// than this is clipped for the pin — acceptable for a pathological first message.
pub const HEAD_READ_BYTES: usize = 16 * 1024;

/// The pinned goal content is clipped to this so a very long first message can't itself blow the budget.
pub const GOAL_PIN_CAP: usize = 4 * 1024;

/// The CURRENT user message is seeded verbatim (clipped to this) as a safety net when it is itself larger than the
/// recency window — otherwise it would fall out of the verbatim window and ride only on the fallible rolling
/// summary. Generous, because the live question is the single most important thing for the model to see.
pub const CURRENT_MSG_PIN_CAP: usize = 64 * 1024;

/// The rolling summary injected into context is clipped to this (a runaway summary is still bounded).
pub const SUMMARY_INJECT_CAP: usize = 6 * 1024;

/// Max middle-span bytes fed to ONE summary update. If the newly-dropped span exceeds this (e.g. the first time a
/// long chat rolls past the window), only the newest SUMMARY_SPAN_CAP of the span is summarized — the closest-to-
/// window history is the most relevant, and older detail already lives in neuron-db recall.
pub const SUMMARY_SPAN_CAP: usize = 256 * 1024;

/// In-turn working growth (assistant tool_call turns + full tool results appended during the loop) beyond the
/// assembled base before the caller compacts it into a progress note. Lets an afk turn run long without the
/// single-turn buffer overflowing on its own accumulation.
pub const WORKING_COMPACT_BYTES: usize = 24 * 1024;

/// ~bytes per token — a rough, model-agnostic proxy (we have no tokenizer). Deliberately conservative; real
/// tokenizers average ~3.5-4 bytes/token on prose. Used only to size byte budgets against a token ceiling.
pub const BYTES_PER_TOKEN: usize = 4;

pub fn estTokens(bytes: usize) usize {
    return bytes / BYTES_PER_TOKEN;
}

// ------------------------------------------------------------------------------------ positioned file reads

pub const HeadTail = struct {
    head: []const u8, // first HEAD_READ_BYTES of the file (whole file if smaller) — carries the goal line
    tail: []const u8, // last tail_buf.len bytes of the file (whole file if smaller) — the recency window region
    size: usize, //     total file size in bytes
};

/// Read the head and tail of a (possibly large) file with positioned reads — never loads the whole middle, so
/// cost is O(head+tail) regardless of how big the conversation grows (no more 8 MiB whole-file cliff). Returns
/// slices into the caller-owned buffers, or null on any error / empty file (caller: treat as "no history").
/// The tail slice may begin MID-LINE when the file is larger than tail_buf — computeView trims that.
pub fn readHeadTail(io: std.Io, path: []const u8, head_buf: []u8, tail_buf: []u8) ?HeadTail {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const size_u64 = f.length(io) catch return null;
    if (size_u64 == 0) return null;
    const size: usize = std.math.cast(usize, size_u64) orelse return null;
    const head_n = f.readPositionalAll(io, head_buf, 0) catch return null;
    const tail_off: u64 = if (size > tail_buf.len) size - tail_buf.len else 0;
    const tail_n = f.readPositionalAll(io, tail_buf, tail_off) catch return null;
    return .{ .head = head_buf[0..head_n], .tail = tail_buf[0..tail_n], .size = size };
}

/// Read the NEWEST bytes of the file span [from, to) into buf, then trim any leading partial line so the result
/// begins on a clean JSON-line boundary. If the span is larger than buf, only its newest buf.len bytes are read
/// (older detail is covered by recall / the prior summary). Returns null on error / empty / degenerate span.
pub fn readSpanTailTrimmed(io: std.Io, path: []const u8, from: usize, to: usize, buf: []u8) ?[]const u8 {
    if (to <= from) return null;
    const start: usize = if (to - from > buf.len) to - buf.len else from;
    const want = to - start; // <= buf.len
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf[0..want], start) catch return null;
    const raw = buf[0..n];
    // The caller passes `from` as a clean line boundary (a prior window_start / goal_end). We only skip bytes when
    // the span exceeded the cap (start > from) — THEN the read likely began mid-line, so drop to the first
    // newline. When start == from the first line is already whole and must NOT be trimmed.
    if (start > from) {
        if (std.mem.indexOfScalar(u8, raw, '\n')) |nl| return raw[nl + 1 ..];
        return null; // one giant partial line, no boundary — nothing clean to summarize
    }
    return raw;
}

// --------------------------------------------------------------------------------------- recency-window view

pub const View = struct {
    /// The pinned goal message LINE (a full JSON-object line from messages.jsonl), or "" when the window already
    /// contains the start of the conversation (short chats) — then no separate pin is needed.
    goal_line: []const u8,
    /// The recency-window bytes: a run of COMPLETE JSON-object lines (any leading partial dropped). May be "".
    window: []const u8,
    /// Absolute byte offset in messages.jsonl where `window` begins (a clean line boundary).
    window_start: usize,
    /// Absolute byte offset where the summarizable middle begins — just past the goal line, clamped so it never
    /// exceeds window_start. The rolling summary should cover [goal_end, window_start).
    goal_end: usize,
    /// True when history exists between the goal and the window (dropped from the literal prompt) — the caller
    /// injects the rolling summary and leans on recall to cover it.
    gap: bool,
};

/// Compute the recency-window view over a messages.jsonl of total `size` bytes, given its `head` (first bytes,
/// for the goal line) and `tail` (last min(window_bytes,size) bytes, possibly starting mid-line). All returned
/// offsets are absolute into the full file.
pub fn computeView(head: []const u8, tail: []const u8, size: usize, window_bytes: usize) View {
    _ = window_bytes; // the tail slice is already sized to the window by readHeadTail's tail_buf; kept for clarity
    // Did the head read capture the WHOLE first (goal) line? Only if it contains a newline; otherwise the goal line
    // is longer than HEAD_READ_BYTES and head[0..] is a TRUNCATED JSON fragment we must not try to pin (the parser
    // would reject it and the goal would be dropped from both the pin and the summary).
    const head_nl = std.mem.indexOfScalar(u8, head, '\n');

    // Where does `tail` begin in the file? readHeadTail read the last tail_buf.len bytes, so tail_start = size - tail.len.
    const tail_start: usize = size - tail.len;

    // Whole file fit in the window → replay it verbatim; the goal is inside the window, no pin, no gap.
    if (tail_start == 0) {
        return .{ .goal_line = "", .window = tail, .window_start = 0, .goal_end = 0, .gap = false };
    }

    // tail began mid-line: drop to the first clean line boundary so every replayed line is a full JSON object.
    const win_rel: usize = if (std.mem.indexOfScalar(u8, tail, '\n')) |nl| nl + 1 else tail.len;
    const window = tail[win_rel..];
    const window_start = tail_start + win_rel;

    if (head_nl) |nl| {
        // Goal line fully captured → pin it verbatim; the rolling summary covers [goal_end, window_start). Clamp
        // goal_end to window_start so that middle span is never negative for a large-but-in-head goal line.
        const goal_end = @min(nl + 1, window_start);
        return .{ .goal_line = std.mem.trim(u8, head[0 .. nl + 1], " \r\n\t"), .window = window, .window_start = window_start, .goal_end = goal_end, .gap = window_start > goal_end };
    }
    // Goal line longer than the head read → do NOT pin a truncated fragment. Fold the whole goal into the rolling
    // summary by starting its coverage at offset 0 (a real line boundary), so the goal is represented in the
    // summary rather than lost. gap is true whenever any history precedes the window.
    return .{ .goal_line = "", .window = window, .window_start = window_start, .goal_end = 0, .gap = window_start > 0 };
}

// ------------------------------------------------------------------------------------------------- tests

test "computeView: whole small file fits — replay verbatim, no goal pin, no gap" {
    const data = "{\"role\":\"user\",\"content\":\"hi\"}\n{\"role\":\"assistant\",\"content\":\"hello\"}\n";
    // head and tail both = whole file, size = data.len (fits under the window)
    const v = computeView(data, data, data.len, HISTORY_WINDOW_BYTES);
    try std.testing.expectEqualStrings("", v.goal_line);
    try std.testing.expectEqualStrings(data, v.window);
    try std.testing.expectEqual(@as(usize, 0), v.window_start);
    try std.testing.expect(!v.gap);
}

test "computeView: large file — pins the goal, windows the tail on a clean line boundary, reports a gap" {
    // Build a file: goal line, then many filler lines, so total > window. Simulate the tail as the last chunk.
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"role\":\"user\",\"content\":\"GOAL build the thing\"}\n");
    const goal_len = buf.items.len;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        try buf.appendSlice(gpa, "{\"role\":\"assistant\",\"content\":\"filler line to grow the transcript well past the window budget\"}\n");
    }
    const size = buf.items.len;
    try std.testing.expect(size > HISTORY_WINDOW_BYTES);

    const head = buf.items[0..@min(HEAD_READ_BYTES, size)];
    const tail = buf.items[size - HISTORY_WINDOW_BYTES ..]; // exactly the window-sized tail
    const v = computeView(head, tail, size, HISTORY_WINDOW_BYTES);

    try std.testing.expect(v.gap);
    try std.testing.expectEqualStrings("{\"role\":\"user\",\"content\":\"GOAL build the thing\"}", v.goal_line);
    try std.testing.expectEqual(goal_len, v.goal_end); // goal_end == just past the first line
    // window begins at a clean boundary: its first char starts a JSON object, and the byte before window_start is '\n'
    try std.testing.expect(v.window.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), v.window[0]);
    try std.testing.expectEqual(@as(u8, '\n'), buf.items[v.window_start - 1]);
    // every line in the window is complete (parses as an object); spot-check no leading partial
    try std.testing.expect(std.mem.startsWith(u8, v.window, "{\"role\""));
    // window is bounded by the budget
    try std.testing.expect(v.window.len <= HISTORY_WINDOW_BYTES);
}

test "computeView: a single newest line bigger than the window empties the window but still pins the goal (clamp holds)" {
    // Degenerate: the most recent message is itself larger than the whole window. The tail lands entirely inside
    // that one line, so the recency window comes out empty and the giant line becomes summarizable middle. The
    // invariant to hold: the goal is still pinned and goal_end never exceeds window_start (no negative span).
    const goal = "{\"role\":\"user\",\"content\":\"g\"}\n";
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, goal);
    try buf.append(gpa, '{');
    try buf.appendSlice(gpa, "\"role\":\"assistant\",\"content\":\"");
    var j: usize = 0;
    while (j < HISTORY_WINDOW_BYTES * 2) : (j += 1) try buf.append(gpa, 'x'); // one line ~2x the window
    try buf.appendSlice(gpa, "\"}\n");
    const size = buf.items.len;
    const head = buf.items[0..@min(HEAD_READ_BYTES, size)];
    const tail = buf.items[size - HISTORY_WINDOW_BYTES ..];
    const v = computeView(head, tail, size, HISTORY_WINDOW_BYTES);
    try std.testing.expectEqualStrings(std.mem.trim(u8, goal, " \r\n\t"), v.goal_line);
    try std.testing.expect(v.goal_end <= v.window_start); // clamp invariant: span [goal_end, window_start) never negative
    try std.testing.expectEqual(@as(usize, goal.len), v.goal_end); // goal_end is the first-line boundary
}

test "computeView: a goal line longer than the head read is NOT pinned as a truncated fragment; summary covers it (goal_end=0)" {
    // First (goal) message is a >HEAD_READ_BYTES paste, so head[0..] is a truncated JSON fragment (no newline).
    // The goal must not be pinned (parser would reject it) — instead goal_end=0 so the rolling summary covers it.
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, '{');
    try buf.appendSlice(gpa, "\"role\":\"user\",\"content\":\"");
    var i: usize = 0;
    while (i < HEAD_READ_BYTES * 2) : (i += 1) try buf.append(gpa, 'g'); // goal line ~2x the head read
    try buf.appendSlice(gpa, "\"}\n");
    // then a few normal later messages so the window has clean lines and there's a gap
    var j: usize = 0;
    while (j < 400) : (j += 1) try buf.appendSlice(gpa, "{\"role\":\"assistant\",\"content\":\"later turn content here\"}\n");
    const size = buf.items.len;

    const head = buf.items[0..@min(HEAD_READ_BYTES, size)];
    const tail = buf.items[size - HISTORY_WINDOW_BYTES ..];
    const v = computeView(head, tail, size, HISTORY_WINDOW_BYTES);
    try std.testing.expectEqualStrings("", v.goal_line); // NOT pinned (would be a truncated fragment)
    try std.testing.expectEqual(@as(usize, 0), v.goal_end); // summary coverage starts at offset 0 → includes the goal
    try std.testing.expect(v.gap); // there IS a middle to summarize
    // window still begins on a clean boundary
    try std.testing.expectEqual(@as(u8, '{'), v.window[0]);
}

test "estTokens: rough proxy divides by BYTES_PER_TOKEN" {
    try std.testing.expectEqual(@as(usize, 256), estTokens(1024));
    try std.testing.expectEqual(@as(usize, 0), estTokens(3));
}

test "readHeadTail + readSpanTailTrimmed: positioned reads over a temp file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-chatctx-tmp.jsonl";
    const dir = std.Io.Dir.cwd();
    // three lines; make the middle findable
    const content = "{\"role\":\"user\",\"content\":\"first\"}\n{\"role\":\"assistant\",\"content\":\"middle\"}\n{\"role\":\"user\",\"content\":\"last\"}\n";
    try dir.writeFile(io, .{ .sub_path = path, .data = content });
    defer dir.deleteFile(io, path) catch {};

    var head_buf: [8]u8 = undefined; // tiny head so it's a partial first line
    var tail_buf: [40]u8 = undefined; // tiny tail so it starts mid-line
    const ht = readHeadTail(io, path, &head_buf, &tail_buf) orelse return error.NoRead;
    try std.testing.expectEqual(content.len, ht.size);
    try std.testing.expectEqual(@as(usize, 8), ht.head.len); // filled the small head buffer
    try std.testing.expect(ht.tail.len == 40); // filled the small tail buffer
    try std.testing.expectEqualStrings(content[content.len - 40 ..], ht.tail);

    // read the span covering the middle line region and trim to a clean boundary
    const first_nl = std.mem.indexOfScalar(u8, content, '\n').?;
    const second_nl = std.mem.indexOfScalarPos(u8, content, first_nl + 1, '\n').?;
    var span_buf: [200]u8 = undefined;
    const span = readSpanTailTrimmed(io, path, first_nl + 1, second_nl + 1, &span_buf) orelse return error.NoSpan;
    try std.testing.expectEqualStrings(content[first_nl + 1 .. second_nl + 1], span);
}

test "readHeadTail: null on a missing file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var hb: [8]u8 = undefined;
    var tb: [8]u8 = undefined;
    try std.testing.expect(readHeadTail(io, "zig-chatctx-does-not-exist.jsonl", &hb, &tb) == null);
}
