//! chat_context.zig — bounded LLM-context assembly for the server chat turn.
//!
//! The durable conversation log (messages.jsonl) grows without bound, but what we FEED the model each inference
//! must stay inside its context window. This module projects the full history into a fixed budget rather than
//! replaying the whole transcript (which overflows the model window and hits a hard 8 MiB read cliff on long chats):
//!
//!   * pin the original goal (the first user message) — it anchors the whole arc,
//!   * replay only a RECENCY WINDOW of the newest turns (the bulk of what the model needs),
//!   * report the GAP so the caller can cover the dropped middle with a rolling summary + relevance recall,
//!   * and keep a DIGEST LEDGER of what every fold established, projected back for the live question — the
//!     layer that lets a chat run without end (see "the transcript ledger" below).
//!
//! Storage stays full (the durable log is never truncated); only the CONTEXT is windowed. Pure + std-only so the
//! windowing math is unit-tested directly; impure file reads use std.Io. The caller (chat_engine.zig) parses the
//! windowed JSON lines and owns the LLM-backed summary generation.

const std = @import("std");

/// Recency window: the newest ~this many bytes of messages.jsonl are replayed verbatim. ~28 KiB ≈ ~7k tokens at
/// ~4 bytes/token — with the system prompt (~1 KiB), a capped summary (≤6 KiB), and recall (~a few hundred B),
/// the assembled base is ~9k tokens, leaving ample room under a 32k-token model for this turn's working context
/// and the output reservation.
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

/// Max bytes fed to ONE summary-update completion.
///
/// This replaces a 256 KiB cap that was applied to the NEWEST end of the uncovered span, with the older remainder
/// discarded and the coverage cursor advanced past it anyway. The justification given was that "older detail
/// already lives in neuron-db recall" — but recall never held the assistant's own record of the work (the
/// confabulation rule forbids observing assistant replies), so the discarded span was the one thing nothing else
/// retained. A long chat quietly lost its own middle and, seeing the original goal with no evidence of progress,
/// correctly started over.
///
/// The span is now drained oldest-first in chunks this size (see readSpanHeadTrimmed), so nothing is dropped —
/// only deferred. Sized at ~one recency window: with the prior summary (<= SUMMARY_INJECT_CAP) and the prompt,
/// one chunk is ~10k tokens, which fits any model the thinking role plausibly runs on. 256 KiB was ~64k tokens in
/// a single request; under oldest-first draining, a request the model always rejects is a cursor that never moves.
pub const SUMMARY_CHUNK_BYTES: usize = 32 * 1024;

/// Chunks one COMPLETED turn folds in. The catch-up runs on the turn thread before the {done} frame and inside
/// the per-conversation turn slot, so each chunk is post-answer latency the user waits through and a window in
/// which the next post for this conversation is refused as busy. Three (~96 KiB of backlog per completed turn)
/// drains a normal gap immediately and a pathological one over a handful of turns.
pub const SUMMARY_CHUNKS_PER_TURN: usize = 3;

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
/// cost is O(head+tail) regardless of how big the conversation grows. Returns slices into the caller-owned
/// buffers, or null on any error / empty file (caller: treat as "no history").
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

/// One line-aligned chunk taken from the OLDEST end of an uncovered span. See readSpanHeadTrimmed.
pub const HeadSpan = struct {
    /// Bytes read starting EXACTLY at `from` (never front-trimmed), ending just past a '\n' unless `clipped`.
    bytes: []const u8,
    /// File bytes accounted for — always == bytes.len and always >= 1. `from + consumed` is the caller's next
    /// `covered`: the ledger advances by this and by nothing else.
    consumed: usize,
    /// The chunk had to be cut mid-record: one stored line is longer than `buf`. The remainder is NOT lost — the
    /// next call resumes at `from + consumed`, mid-line, and re-aligns at that line's '\n'. The flag exists so the
    /// summarizer can be told the last record it sees is a fragment rather than a whole message.
    clipped: bool,
};

/// Read the OLDEST bytes of the span [from, to) into `buf`, trimmed BACK to end on a clean line boundary.
///
/// This replaced a tail-reading twin, and the direction is the whole point. That one kept the NEWEST bytes of an
/// oversized span and silently discarded the older remainder — safe only if the caller then admitted it had
/// covered less than it asked for. The caller did the opposite, advancing its `covered` cursor to the far end of a
/// span it had only partly read, so everything older than the cap was discarded AND marked summarized: absent from
/// the window, absent from the summary, and unreachable by any later pass. Reading from the OLDEST end instead
/// lets the caller advance `covered` by exactly `consumed` and come back for the rest, so a long backlog drains
/// over several turns instead of collapsing in one lossy jump.
///
/// `from` is a boundary the caller already owns (a prior `covered`, or goal_end), so nothing is trimmed off the
/// FRONT — front-trimming here would re-introduce the silent drop this exists to remove. Returns null on read
/// error or a degenerate span; on every non-null return `consumed >= 1`, so `from += consumed` cannot spin.
pub fn readSpanHeadTrimmed(io: std.Io, path: []const u8, from: usize, to: usize, buf: []u8) ?HeadSpan {
    if (to <= from or buf.len == 0) return null;
    const want = @min(to - from, buf.len);
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf[0..want], from) catch return null;
    if (n == 0) return null; // truncated or racing file — consumed==0 would spin the caller's loop
    const raw = buf[0..n];
    // Reached the span's end. `to` is itself a line boundary (a computeView window_start), so this read is already
    // whole — trimming here would drop the final line and pin `covered` one record short of the truth, forever.
    if (from + n >= to) return .{ .bytes = raw, .consumed = n, .clipped = false };
    // Cut short by the cap, so the read almost certainly ends mid-line: trim back to just past the last newline.
    if (std.mem.lastIndexOfScalar(u8, raw, '\n')) |nl| return .{ .bytes = raw[0 .. nl + 1], .consumed = nl + 1, .clipped = false };
    // NO newline anywhere in a full buffer: ONE record is longer than the chunk. Returning null here would pin
    // `covered` and re-read this same record every turn forever. Consume what was read — the summarizer sees a
    // truncated record, which is honest and bounded — and say it was cut. `covered` then sits mid-line, which is
    // self-healing: the next chunk starts mid-record and re-aligns at that record's newline.
    return .{ .bytes = raw, .consumed = n, .clipped = true };
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

// ------------------------------------------------------------------------------- the transcript ledger
//
// A conversation that never ends cannot live in one rewritten summary. Every fold used to REPLACE the running
// summary with a fresh 250-word rewrite, so whatever a rewrite failed to restate was gone for good: at turn
// 500 the decision made at turn 5, the path the user gave at turn 12, the preference stated at turn 30 — none
// survive a few hundred re-tellings. The transcript itself is never truncated, but nothing the model was shown
// could reach that far back.
//
// Three layers now project the whole transcript into a window of ANY size, each bounded by the model that
// reads it:
//
//   * the RECENCY WINDOW — verbatim, the newest turns (computeView above; the engine sizes it),
//   * the ROLLING SUMMARY — one rewritten narrative of everything older (as before, now capacity-sized),
//   * the DIGEST LEDGER — append-only: every fold ALSO writes the concrete facts its chunk established
//     (decisions, preferences, names, paths, values) as one {conv}/digest.jsonl record that is never
//     rewritten. At assembly the ledger is read back bounded and PROJECTED for the live question: the
//     newest lines for a dense recent past plus the lines lexically closest to what is being asked now.
//
// A fact written to the ledger decays with nothing: it is exactly as reachable at turn 5000 as at turn 6,
// for the price of one bounded positional read and no model call. The summary carries the narrative, the
// ledger carries the specifics, the window carries the present.
//
// Everything is sized from the window and the CAPACITY of the model that must hold it — a 1.3M-token
// frontier model keeps far more verbatim history and a much longer summary than an 8k local model, and a
// small-parameter model is never asked to write a summary it cannot hold or read one it cannot follow.

/// What the reading (or summarizing) model can HOLD — the engine maps modelcfg.Tier onto this so the budget
/// math stays std-only and testable with plain numbers. Same integer values as modelcfg.Tier; the engine pins
/// that agreement with a test.
pub const Capacity = enum(u8) { small = 0, mid = 1, large = 2 };

/// Floor on the injected rolling summary: below this a summary cannot carry a goal, a decision and an open
/// thread at once, and a window too small for it is a window the belt already overflows.
pub const SUMMARY_INJECT_MIN: usize = 2 * 1024;

/// The rolling summary's size — injected into the prompt AND written back by the fold — for a model that holds
/// `win_bytes` of context with capacity `cap`. A sixteenth of the window, quantized to 1 KiB: the stock 6 KiB
/// at a 32k window, 2 KiB at 8k, and UP with the window to a capacity ceiling — a small-parameter model with a
/// huge window keeps the stock 6 KiB (it cannot follow a longer one), a frontier model reads up to 16 KiB.
pub fn summaryInjectCap(win_bytes: usize, cap: Capacity) usize {
    const ceiling: usize = switch (cap) {
        .small => SUMMARY_INJECT_CAP,
        .mid => 10 * 1024,
        .large => 16 * 1024,
    };
    const scaled = ((win_bytes / 16) / 1024) * 1024;
    return std.math.clamp(scaled, SUMMARY_INJECT_MIN, ceiling);
}

/// The most recency window a model of this capacity is replayed, however roomy its window: the stock 28 KiB
/// for a small model (a longer verbatim tail drowns it), 48 KiB mid, 64 KiB large. The engine reaches these only
/// when the window has room for a full working span BESIDE them (see its scale-up rule), so a 32k model keeps
/// exactly the window it had.
pub fn historyWindowCap(cap: Capacity) usize {
    return switch (cap) {
        .small => HISTORY_WINDOW_BYTES,
        .mid => 48 * 1024,
        .large => 64 * 1024,
    };
}

/// Floor on the FACTS block: room for a dozen lines.
pub const FACTS_BUDGET_MIN: usize = 1024;

/// Bytes of the digest ledger projected into one prompt: a twenty-fourth of the window, 512-byte quantized,
/// clamped between the floor and a capacity ceiling (4 / 8 / 12 KiB). At 8k that is the floor; at 32k, 4 KiB;
/// a 128k frontier model reads 12 KiB — a few hundred lines of settled facts, every turn, for no model call.
pub fn factsBudget(win_bytes: usize, cap: Capacity) usize {
    const ceiling: usize = switch (cap) {
        .small => 4 * 1024,
        .mid => 8 * 1024,
        .large => 12 * 1024,
    };
    const scaled = ((win_bytes / 24) / 512) * 512;
    return std.math.clamp(scaled, FACTS_BUDGET_MIN, ceiling);
}

/// Floor on one fold's input chunk. A chunk this small still moves the cursor by whole records on every turn.
pub const SUMMARY_CHUNK_MIN_BYTES: usize = 4 * 1024;
/// The fold prompt's own text plus the record envelope — what the request carries besides the summary and chunk.
pub const SUMMARY_PROMPT_OVERHEAD_BYTES: usize = 4 * 1024;

/// Bytes one fold reads, sized to the SUMMARIZING model's window: the request carries the prior summary
/// (<= `summary_cap`) and the chunk, and the reply must fit the rewritten summary plus its FACTS lines, so four
/// caps plus the prompt overhead are reserved before the chunk gets a byte. SUMMARY_CHUNK_BYTES (32 KiB) was a
/// flat figure written for a 32k summarizer; fed to an 8k local model whole, the fold was rejected on every
/// turn and the cursor never moved.
pub fn summaryChunkBytes(summarizer_win_bytes: usize, summary_cap: usize) usize {
    const fixed = 4 * summary_cap + SUMMARY_PROMPT_OVERHEAD_BYTES;
    if (summarizer_win_bytes <= fixed + SUMMARY_CHUNK_MIN_BYTES) return SUMMARY_CHUNK_MIN_BYTES;
    return @min(SUMMARY_CHUNK_BYTES, ((summarizer_win_bytes - fixed) / 1024) * 1024);
}

/// What one fold is asked to write: a summary length in words, a FACTS line allowance, and the completion
/// budget that holds both.
pub const FoldShape = struct { words: usize, facts_lines: usize, max_tokens: u32 };

/// The fold's shape for the capacity that BOUNDS it (the smaller of the reading and the summarizing model). A
/// small model writes short and faithful; a frontier model is asked for a summary long enough to actually use
/// the room its window gives it. The word target is also bounded by the byte cap it must fit under (~8 bytes a
/// word), so a tightened cap never asks for more words than it will keep.
pub fn foldShape(cap: Capacity, summary_cap: usize) FoldShape {
    const tier_words: usize = switch (cap) {
        .small => 200,
        .mid => 400,
        .large => 900,
    };
    const words = @max(80, @min(tier_words, summary_cap / 8));
    const facts_lines: usize = switch (cap) {
        .small => 15,
        .mid => 30,
        .large => 50,
    };
    const mt: usize = std.math.clamp(words * 2 + facts_lines * 24 + 256, 768, 4096);
    return .{ .words = words, .facts_lines = facts_lines, .max_tokens = @intCast(mt) };
}

/// A fold's reply, split: the rewritten summary and the FACTS section that follows it (null when the model
/// wrote none — an older or smaller model may answer with the summary alone, which is exactly the pre-ledger
/// behaviour and loses nothing that was kept before).
pub const Note = struct { summary: []const u8, facts: ?[]const u8 };

/// Is `line` a section heading for `word`, under any decoration a model reaches for — `FACTS`, `FACTS:`,
/// `## Facts`, `**Facts**`, `- facts -`? A few trailing characters are tolerated ("FACTS (new)") but a sentence
/// that merely begins with the word is content, not a heading.
fn isHeading(line: []const u8, comptime word: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r#*-:_");
    return t.len >= word.len and t.len <= word.len + 7 and std.ascii.eqlIgnoreCase(t[0..word.len], word);
}

/// Strip a leading `word` heading from `s` — its own line, or a `WORD:` / `**WORD:**` prefix — and return the
/// content. "SUMMARY of the work…" is prose and comes back untouched: only a colon or a line end after the word
/// makes it a heading.
fn stripHeading(s: []const u8, comptime word: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '#' or s[i] == '*' or s[i] == '_' or s[i] == '-')) i += 1;
    if (!std.ascii.startsWithIgnoreCase(s[i..], word)) return s;
    var j = i + word.len;
    while (j < s.len and (s[j] == '*' or s[j] == '_' or s[j] == ' ')) j += 1;
    if (j < s.len and s[j] == ':') {
        j += 1;
    } else if (j < s.len and s[j] != '\n' and s[j] != '\r') return s;
    return std.mem.trim(u8, s[j..], " \r\n\t*_");
}

/// Split a fold's reply into its summary and its FACTS section. The FACTS heading is found by the same rule the
/// working-span note uses (the engine delegates to this), the text before it is the summary with any SUMMARY
/// heading removed, and a reply with no FACTS line is all summary.
pub fn splitNote(note: []const u8) Note {
    var facts: ?[]const u8 = null;
    var summary_end: usize = note.len;
    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, note, '\n');
    while (it.next()) |line| {
        if (isHeading(line, "facts")) {
            summary_end = pos;
            const after = pos + line.len;
            facts = if (after < note.len) note[after + 1 ..] else note[note.len..];
            break;
        }
        pos += line.len + 1;
    }
    const summary = stripHeading(std.mem.trim(u8, note[0..summary_end], " \r\n\t"), "summary");
    return .{ .summary = summary, .facts = facts };
}

/// The append-only digest ledger beside messages.jsonl — one record per fold, never rewritten.
pub const DIGEST_FILE = "digest.jsonl";
/// How much of the ledger's newest end one assembly reads. 256 KiB is a few thousand fact lines — hundreds of
/// folds; a chat older than that still reaches its oldest specifics through the rolling summary, and the read
/// stays O(1) in the size of the conversation, which is what lets it grow without bound.
pub const DIGEST_SCAN_BYTES: usize = 256 * 1024;
/// A usable fact line: shorter than this is noise, longer is a paragraph the model pasted rather than a fact.
pub const FACT_LINE_MIN: usize = 4;
pub const FACT_LINE_MAX: usize = 400;
/// The most cue tokens one projection scores against — the live question rarely carries more content words.
pub const CUE_TOKENS_MAX: usize = 48;

/// The newest `buf.len` bytes of a file, with any leading partial line dropped (the whole file when it fits).
/// Null on a missing or empty file — the caller treats that as "no ledger yet".
pub fn readTailTrimmed(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const size_u64 = f.length(io) catch return null;
    if (size_u64 == 0) return null;
    const size: usize = std.math.cast(usize, size_u64) orelse return null;
    const off: u64 = if (size > buf.len) size - buf.len else 0;
    const n = f.readPositionalAll(io, buf, off) catch return null;
    const raw = buf[0..n];
    if (off == 0) return raw;
    const nl = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    return raw[nl + 1 ..];
}

/// Render one digest record: `{"from":N,"to":M,"ts":T,"facts":"…"}` plus its newline. `from`/`to` are the
/// messages.jsonl byte span the fold covered, so a record can always be traced back to the turns it came from.
pub fn digestRecord(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), from: usize, to: usize, ts: i64, facts: []const u8) !void {
    var hb: [96]u8 = undefined;
    const head = try std.fmt.bufPrint(&hb, "{{\"from\":{d},\"to\":{d},\"ts\":{d},\"facts\":", .{ from, to, ts });
    try out.appendSlice(gpa, head);
    try appendJsonString(gpa, out, facts);
    try out.appendSlice(gpa, "}\n");
}

/// The usable lines of a FACTS section — bullets stripped, length-bounded, at most `max_lines`, a PROGRESS or
/// SUMMARY heading ending the list — joined with newlines. Null when nothing usable is left, so a fold that
/// wrote an empty or decorative FACTS section writes no record.
pub fn cleanFactLines(gpa: std.mem.Allocator, raw: []const u8, max_lines: usize) ?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |l| {
        if (n >= max_lines) break;
        const line = std.mem.trim(u8, l, " \t\r-*");
        if (line.len < FACT_LINE_MIN or line.len > FACT_LINE_MAX) continue;
        if (startsSection(line)) break;
        if (out.items.len > 0) out.append(gpa, '\n') catch return null;
        out.appendSlice(gpa, line) catch return null;
        n += 1;
    }
    if (n == 0) return null;
    return out.toOwnedSlice(gpa) catch null;
}

/// Does this line open a PROGRESS or SUMMARY section — the two the working note and the fold reply put after
/// (or before) their FACTS? Matched on the line's START, decoration stripped: "PROGRESS: wrote the parser" is a
/// sentence, not a heading, and it still ends the list.
fn startsSection(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t#*-_");
    return std.ascii.startsWithIgnoreCase(t, "progress") or std.ascii.startsWithIgnoreCase(t, "summary");
}

/// Function words a cue never scores on. Only words of four letters or more reach the scorer, so this is the
/// short list of those that carry no topic.
fn isStopWord(tok: []const u8) bool {
    const stops = [_][]const u8{
        "that",  "this",  "with",   "from",    "have",   "what",   "when",   "which", "there",  "their",     "about", "would",
        "could", "should", "will",  "your",    "just",   "into",   "then",   "than",  "them",   "they",      "also",  "been",
        "were",  "does",  "make",   "like",    "some",   "more",   "only",   "over",  "please", "want",      "need",  "here",
        "where", "these", "those",  "know",    "think",  "still",  "again",  "because", "every", "each",     "other", "after",
        "before", "being", "while", "most",    "much",   "many",   "very",   "really", "okay",  "sure",      "thanks", "thank",
        "hello", "yeah",  "right",  "tell",    "show",   "give",   "take",   "going", "back",   "well",      "good",  "same",
        "next",  "last",  "first",  "role",    "user",   "content", "assistant", "kind", "true", "false",    "null",  "https",
        "http",  "done",  "help",   "using",   "used",   "keep",   "look",
    };
    for (stops) |s| if (std.ascii.eqlIgnoreCase(s, tok)) return true;
    return false;
}

/// The content words of a cue: alphanumeric runs of 4..32 characters, stop words and repeats dropped, at most
/// `out.len`. Returns how many were written.
pub fn cueTokens(cue: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < cue.len and n < out.len) {
        while (i < cue.len and !std.ascii.isAlphanumeric(cue[i])) i += 1;
        const start = i;
        while (i < cue.len and (std.ascii.isAlphanumeric(cue[i]) or cue[i] == '_')) i += 1;
        const tok = cue[start..i];
        if (tok.len < 4 or tok.len > 32 or isStopWord(tok)) continue;
        var seen = false;
        for (out[0..n]) |t| {
            if (std.ascii.eqlIgnoreCase(t, tok)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        out[n] = tok;
        n += 1;
    }
    return n;
}

const Cand = struct { text: []const u8, ord: usize, score: u16, take: bool };

fn newerFirst(cs: []const Cand, a: usize, b: usize) bool {
    return cs[a].ord > cs[b].ord;
}

fn bestFirst(cs: []const Cand, a: usize, b: usize) bool {
    if (cs[a].score != cs[b].score) return cs[a].score > cs[b].score;
    return cs[a].ord > cs[b].ord;
}

fn olderFirst(cs: []const Cand, a: usize, b: usize) bool {
    return cs[a].ord < cs[b].ord;
}

/// Project the digest ledger's newest `tail` (whole records, as readTailTrimmed returns it) for one prompt:
/// every fact line, deduplicated (a repeat keeps its NEWEST position), then chosen under `budget` bytes in
/// three passes — the newest lines until half the budget is spent, then the lines lexically closest to `cue`
/// (the live question plus the pinned goal) by descending overlap, then more of the newest to fill what is
/// left. Rendered oldest-first, one per line, so the model reads them as the chronology they are. Null when
/// nothing is selected. No model call: this runs on the critical path before the first token.
pub fn selectFacts(gpa: std.mem.Allocator, tail: []const u8, cue: []const u8, budget: usize) ?[]u8 {
    if (budget == 0 or tail.len == 0) return null;
    const Rec = struct { facts: []const u8 = "" };
    var texts: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(Rec, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (p.value.facts.len == 0) continue;
        const d = gpa.dupe(u8, p.value.facts) catch return null;
        texts.append(gpa, d) catch {
            gpa.free(d);
            return null;
        };
    }
    if (texts.items.len == 0) return null;

    var cands: std.ArrayListUnmanaged(Cand) = .empty;
    defer cands.deinit(gpa);
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    defer index.deinit(gpa);
    var ord: usize = 0;
    for (texts.items) |t| { // records in file order: oldest first
        var li = std.mem.splitScalar(u8, t, '\n');
        while (li.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r-*");
            if (line.len < FACT_LINE_MIN or line.len > FACT_LINE_MAX) continue;
            if (index.get(line)) |at| {
                cands.items[at].ord = ord; // re-established: it is as new as its latest record
            } else {
                cands.append(gpa, .{ .text = line, .ord = ord, .score = 0, .take = false }) catch return null;
                index.put(gpa, line, cands.items.len - 1) catch return null;
            }
            ord += 1;
        }
    }
    if (cands.items.len == 0) return null;

    var toks: [CUE_TOKENS_MAX][]const u8 = undefined;
    const ntok = cueTokens(cue, &toks);
    for (cands.items) |*c| {
        var s: u16 = 0;
        for (toks[0..ntok]) |tk| {
            if (std.ascii.indexOfIgnoreCase(c.text, tk) != null) s += 1;
        }
        c.score = s;
    }

    const order = gpa.alloc(usize, cands.items.len) catch return null;
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;

    var used: usize = 0;
    // pass 1: the newest lines, until half the budget is spent
    std.mem.sort(usize, order, @as([]const Cand, cands.items), newerFirst);
    const recent_share = budget / 2;
    for (order) |i| {
        const c = &cands.items[i];
        const cost = c.text.len + 1;
        if (used + cost > recent_share) continue;
        c.take = true;
        used += cost;
    }
    // pass 2: the closest lines to the cue, best overlap first, newest breaking ties
    if (ntok > 0) {
        std.mem.sort(usize, order, @as([]const Cand, cands.items), bestFirst);
        for (order) |i| {
            const c = &cands.items[i];
            if (c.take or c.score == 0) continue;
            const cost = c.text.len + 1;
            if (used + cost > budget) continue;
            c.take = true;
            used += cost;
        }
    }
    // pass 3: whatever room is left goes to more of the recent past
    std.mem.sort(usize, order, @as([]const Cand, cands.items), newerFirst);
    for (order) |i| {
        const c = &cands.items[i];
        if (c.take) continue;
        const cost = c.text.len + 1;
        if (used + cost > budget) continue;
        c.take = true;
        used += cost;
    }

    std.mem.sort(usize, order, @as([]const Cand, cands.items), olderFirst);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    for (order) |i| {
        const c = cands.items[i];
        if (!c.take) continue;
        if (out.items.len > 0) out.append(gpa, '\n') catch return null;
        out.appendSlice(gpa, c.text) catch return null;
    }
    if (out.items.len == 0) return null;
    return out.toOwnedSlice(gpa) catch null;
}

// -------------------------------------------------------------------------- markup tool-call recovery (gpt-oss)

pub const RecoveredCall = struct { name: []u8, args: []u8 }; // both gpa-owned
pub const MarkupRecovery = struct {
    stripped: []u8, // gpa-owned: `content` with the markup block removed
    calls: []RecoveredCall, // gpa-owned
};

/// True if `s` carries tool-call markup a model may emit into the CONTENT channel instead of a structured
/// tool_calls entry. Two dialects are seen in the wild: the Claude/DSML style (`<｜｜DSML｜｜invoke name="…">` /
/// `<｜｜DSML｜｜tool_calls>` — anchored on the ASCII substrings, robust to sentinel variations) and the
/// hermes/Qwen style (`<tool_call>` + `<function=NAME>` + `<parameter=KEY>VALUE</parameter>`), which DeepSeek
/// endpoints fall back to under load. Both leak as prose, run no tool, and stall the drive loop.
pub fn looksLikeToolMarkup(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "invoke name=\"") != null or std.mem.indexOf(u8, s, "tool_calls>") != null or
        std.mem.indexOf(u8, s, "<function=") != null or std.mem.indexOf(u8, s, "<tool_call>") != null;
}

fn lastLtBefore(s: []const u8, pos: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, s[0..pos], '<')) |lt| lt else pos;
}

/// Is `inner` (the text between `<` and `>`) a BARE provider sentinel tag — the control token spelled as
/// markup, carrying no verb or attributes? Accepts every decoration variant seen in the wild: `DSML`,
/// `/DSML`, `|DSML|`, `｜｜DSML｜｜` (fullwidth bar U+FF5C, the raw special-token spelling), with or without
/// spaces. REJECTS anything carrying real content — `｜｜DSML｜｜invoke name="read_file"` has `=` and quotes,
/// so it stays a tool-call for recoverMarkupCalls to parse; only the empty wrapper is a wrapper.
fn isSentinelTag(inner: []const u8) bool {
    var letters: [8]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c == '/' or c == '|' or c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (c == 0xEF and i + 2 < inner.len and inner[i + 1] == 0xBD and inner[i + 2] == 0x9C) {
            i += 3; // U+FF5C fullwidth vertical bar
            continue;
        }
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            if (n >= letters.len) return false; // longer than any sentinel name — a real tag
            letters[n] = std.ascii.toLower(c);
            n += 1;
            i += 1;
            continue;
        }
        return false; // punctuation/attributes ⇒ a real tag, not a bare sentinel
    }
    return std.mem.eql(u8, letters[0..n], "dsml");
}

/// Strip BARE provider control-token wrappers from a finished reply: some models wrap their whole answer in
/// their own sentinel (`<DSML>…</DSML>`, `<｜DSML｜>…</｜DSML｜>`), which leaks to the user as literal tag
/// text. These tokens are never part of a real answer, so any bare sentinel tag is removed wherever it sits
/// and the result is trimmed. Returns null when there is nothing to strip (the caller keeps its original —
/// no allocation on the common path). Tool-call markup is deliberately untouched: it carries a verb, fails
/// isSentinelTag, and belongs to recoverMarkupCalls / contentBeforeMarkup instead.
pub fn stripSentinelTags(gpa: std.mem.Allocator, s: []const u8) ?[]u8 {
    if (std.ascii.indexOfIgnoreCase(s, "dsml") == null) return null; // fast path: nothing to do
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    var dropped = false;
    while (i < s.len) {
        if (s[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, s, i, '>')) |close| {
                if (close - i <= 48 and isSentinelTag(s[i + 1 .. close])) {
                    i = close + 1;
                    dropped = true;
                    continue;
                }
            }
        }
        out.append(gpa, s[i]) catch return null;
        i += 1;
    }
    if (!dropped) return null;
    return gpa.dupe(u8, std.mem.trim(u8, out.items, " \r\n\t")) catch null;
}

/// The portion of `s` BEFORE any tool-call markup block (trimmed) — used to strip leaked markup from a reply
/// shown to the user when it couldn't be recovered into an actual call. Returns `s` (trimmed) when there's none.
pub fn contentBeforeMarkup(s: []const u8) []const u8 {
    var start: usize = s.len;
    if (std.mem.indexOf(u8, s, "invoke name=\"")) |inv| start = lastLtBefore(s, inv);
    if (std.mem.indexOf(u8, s, "tool_calls>")) |tc| {
        const lt = lastLtBefore(s, tc);
        if (lt < start) start = lt;
    }
    if (std.mem.indexOf(u8, s, "<function=")) |fnat| { if (fnat < start) start = fnat; }
    if (std.mem.indexOf(u8, s, "<tool_call>")) |tc| { if (tc < start) start = tc; }
    return std.mem.trim(u8, s[0..start], " \r\n\t");
}

/// Minimal JSON string escaper (std-only; http.jstr lives in the gateway layer). Appends a quoted, escaped `s`.
fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var b: [8]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "");
        } else try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

/// Is `v` a bare JSON scalar (number / true / false / null) safe to emit UNQUOTED? Used for parameters the model
/// tagged string="false". Anything else (an IP like 10.0.0.1, a version 1.2.3, a stray "+5") falls back to a
/// quoted string so the args JSON the tool then parses is always valid.
fn isBareScalar(v: []const u8) bool {
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "null")) return true;
    return isJsonNumber(v);
}

/// Strict JSON number grammar: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)? consuming ALL of `v`. Rejects
/// leading zeros, a bare/trailing '.', a '+' sign, and an empty exponent — anything std.json would reject.
fn isJsonNumber(v: []const u8) bool {
    if (v.len == 0) return false;
    var i: usize = 0;
    if (v[i] == '-') i += 1;
    if (i >= v.len) return false;
    if (v[i] == '0') {
        i += 1; // a leading 0 must stand alone (no 00, no 01)
    } else if (v[i] >= '1' and v[i] <= '9') {
        i += 1;
        while (i < v.len and v[i] >= '0' and v[i] <= '9') i += 1;
    } else return false;
    if (i < v.len and v[i] == '.') { // fraction: at least one digit
        i += 1;
        if (i >= v.len or v[i] < '0' or v[i] > '9') return false;
        while (i < v.len and v[i] >= '0' and v[i] <= '9') i += 1;
    }
    if (i < v.len and (v[i] == 'e' or v[i] == 'E')) { // exponent: optional sign then at least one digit
        i += 1;
        if (i < v.len and (v[i] == '+' or v[i] == '-')) i += 1;
        if (i >= v.len or v[i] < '0' or v[i] > '9') return false;
        while (i < v.len and v[i] >= '0' and v[i] <= '9') i += 1;
    }
    return i == v.len;
}

/// Build the JSON args object from one invoke's parameter region: each `parameter name="Y" string="B">VALUE
/// </…parameter>` becomes `"Y":VALUE` (raw when string="false" and VALUE is a bare scalar, else a quoted string).
fn buildArgs(gpa: std.mem.Allocator, region: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '{');
    var first = true;
    var j: usize = 0;
    const PAR = "parameter name=\"";
    while (std.mem.indexOfPos(u8, region, j, PAR)) |p_at| {
        const pn_start = p_at + PAR.len;
        const pn_end = std.mem.indexOfScalarPos(u8, region, pn_start, '"') orelse break;
        const pname = region[pn_start..pn_end];
        const gt = std.mem.indexOfScalarPos(u8, region, pn_end, '>') orelse break;
        const attrs = region[pn_end..gt]; // between the name's closing quote and the tag's '>'
        const raw_ok = std.mem.indexOf(u8, attrs, "string=\"false\"") != null;
        const close = std.mem.indexOfPos(u8, region, gt, "parameter>") orelse break;
        const val_end = lastLtBefore(region, close); // the '<' beginning the closing tag
        const value = if (val_end > gt) region[gt + 1 .. val_end] else "";
        if (!first) try out.append(gpa, ',');
        first = false;
        try appendJsonString(gpa, &out, pname);
        try out.append(gpa, ':');
        if (raw_ok and isBareScalar(std.mem.trim(u8, value, " \r\n\t")))
            try out.appendSlice(gpa, std.mem.trim(u8, value, " \r\n\t"))
        else
            try appendJsonString(gpa, &out, value);
        j = close + "parameter>".len;
    }
    try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
}

/// Recover tool call(s) a model emitted as markup in the CONTENT channel (see looksLikeToolMarkup). Returns the
/// content with the markup block stripped + the parsed calls, or null when there's nothing recoverable. `content`
/// is BORROWED; on success the caller frees its old content and adopts `stripped`. On any allocation failure the
/// partial work is freed and null is returned (caller keeps the original content — the drive-loop guard is the
/// safety net). Dispatches by dialect: DSML (`invoke name="…"`) first, else hermes (`<function=NAME>`).
pub fn recoverMarkupCalls(gpa: std.mem.Allocator, content: []const u8) ?MarkupRecovery {
    if (std.mem.indexOf(u8, content, "invoke name=\"") != null) return recoverDsml(gpa, content);
    if (std.mem.indexOf(u8, content, "<function=") != null) return recoverHermes(gpa, content);
    return null;
}

fn recoverDsml(gpa: std.mem.Allocator, content: []const u8) ?MarkupRecovery {
    const INV = "invoke name=\"";
    const first_inv = std.mem.indexOf(u8, content, INV) orelse return null;

    // Where does the markup block begin? The '<' before the first invoke, or an earlier `<…tool_calls>` opener.
    var block_start = lastLtBefore(content, first_inv);
    if (std.mem.indexOf(u8, content[0..first_inv], "tool_calls>")) |tc| {
        const lt = lastLtBefore(content, tc);
        if (lt < block_start) block_start = lt;
    }

    var calls: std.ArrayListUnmanaged(RecoveredCall) = .empty;
    defer calls.deinit(gpa);
    var i: usize = first_inv;
    while (std.mem.indexOfPos(u8, content, i, INV)) |inv_at| {
        const name_start = inv_at + INV.len;
        const name_end = std.mem.indexOfScalarPos(u8, content, name_start, '"') orelse break;
        const name = content[name_start..name_end];
        const region_end = std.mem.indexOfPos(u8, content, name_end, INV) orelse content.len;
        const args = buildArgs(gpa, content[name_end..region_end]) catch break;
        const nm = gpa.dupe(u8, name) catch {
            gpa.free(args);
            break;
        };
        calls.append(gpa, .{ .name = nm, .args = args }) catch {
            gpa.free(args);
            gpa.free(nm);
            break;
        };
        i = region_end;
    }
    if (calls.items.len == 0) return null; // nothing parsed → leave content as-is

    const stripped = gpa.dupe(u8, std.mem.trim(u8, content[0..block_start], " \r\n\t")) catch {
        for (calls.items) |c| {
            gpa.free(c.name);
            gpa.free(c.args);
        }
        return null;
    };
    const owned = calls.toOwnedSlice(gpa) catch {
        gpa.free(stripped);
        for (calls.items) |c| {
            gpa.free(c.name);
            gpa.free(c.args);
        }
        return null;
    };
    return .{ .stripped = stripped, .calls = owned };
}

/// The hermes/Qwen markup dialect: `<tool_call>` wrapper (optional) around `<function=NAME>` blocks whose
/// arguments ride as `<parameter=KEY>\nVALUE\n</parameter>`. Seen live from a DeepSeek endpoint under load:
/// the transport returned it as plain content with NO structured calls, so nothing executed and the drive
/// loop nudged "continuing:" against prose — the reluctant-to-act failure. Values carry no type info, so a
/// bare JSON scalar stays bare (line numbers must reach the tool's typed parse as numbers) and everything
/// else is a quoted string.
fn recoverHermes(gpa: std.mem.Allocator, content: []const u8) ?MarkupRecovery {
    const FN = "<function=";
    const first_fn = std.mem.indexOf(u8, content, FN) orelse return null;

    // strip from the <tool_call> opener when it directly precedes the first function (whitespace only between)
    var block_start = first_fn;
    if (std.mem.lastIndexOf(u8, content[0..first_fn], "<tool_call>")) |tc| {
        if (std.mem.trim(u8, content[tc + "<tool_call>".len .. first_fn], " \r\n\t").len == 0) block_start = tc;
    }

    var calls: std.ArrayListUnmanaged(RecoveredCall) = .empty;
    defer calls.deinit(gpa);
    var i: usize = first_fn;
    while (std.mem.indexOfPos(u8, content, i, FN)) |fn_at| {
        const name_start = fn_at + FN.len;
        const name_end = std.mem.indexOfScalarPos(u8, content, name_start, '>') orelse break;
        // tolerate <function="x"> and stray spaces; a sane tool name is short [a-z0-9_]
        const name = std.mem.trim(u8, content[name_start..name_end], " \"\r\n\t");
        if (name.len == 0 or name.len > 64) {
            i = name_end;
            continue;
        }
        const region_end = std.mem.indexOfPos(u8, content, name_end, FN) orelse content.len;
        const args = buildArgsHermes(gpa, content[name_end..region_end]) catch break;
        const nm = gpa.dupe(u8, name) catch {
            gpa.free(args);
            break;
        };
        calls.append(gpa, .{ .name = nm, .args = args }) catch {
            gpa.free(args);
            gpa.free(nm);
            break;
        };
        i = region_end;
    }
    if (calls.items.len == 0) return null;

    const stripped = gpa.dupe(u8, std.mem.trim(u8, content[0..block_start], " \r\n\t")) catch {
        for (calls.items) |c| {
            gpa.free(c.name);
            gpa.free(c.args);
        }
        return null;
    };
    const owned = calls.toOwnedSlice(gpa) catch {
        gpa.free(stripped);
        for (calls.items) |c| {
            gpa.free(c.name);
            gpa.free(c.args);
        }
        return null;
    };
    return .{ .stripped = stripped, .calls = owned };
}

/// Args JSON from one hermes function region: each `<parameter=KEY>VALUE</parameter>` becomes `"KEY":VALUE`
/// (bare when VALUE is a bare JSON scalar, else a quoted string). A missing closing tag takes the value up to
/// the next parameter (or the region's end tags) rather than dropping the call.
fn buildArgsHermes(gpa: std.mem.Allocator, region: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '{');
    var first = true;
    var j: usize = 0;
    const PAR = "<parameter=";
    while (std.mem.indexOfPos(u8, region, j, PAR)) |p_at| {
        const k_start = p_at + PAR.len;
        const k_end = std.mem.indexOfScalarPos(u8, region, k_start, '>') orelse break;
        const key = std.mem.trim(u8, region[k_start..k_end], " \"\r\n\t");
        // value runs to the EARLIEST terminator: its </parameter>, the next parameter (a model that forgot
        // the closing tag), or the closing </function>/</tool_call> — never swallow a sibling parameter.
        var v_end: usize = region.len;
        for ([_][]const u8{ "</parameter", PAR, "</function", "</tool_call" }) |t| {
            if (std.mem.indexOfPos(u8, region, k_end, t)) |at| {
                if (at < v_end) v_end = at;
            }
        }
        if (v_end < k_end + 1) v_end = k_end + 1;
        const value = std.mem.trim(u8, region[k_end + 1 .. v_end], " \r\n\t");
        j = v_end;
        if (key.len == 0) continue;
        if (!first) try out.append(gpa, ',');
        first = false;
        try appendJsonString(gpa, &out, key);
        try out.append(gpa, ':');
        if (isBareScalar(value)) try out.appendSlice(gpa, value) else try appendJsonString(gpa, &out, value);
    }
    try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
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

test "isBareScalar: accepts real JSON numbers/bools, rejects IPs/versions/malformed (else args JSON would break)" {
    try std.testing.expect(isBareScalar("0"));
    try std.testing.expect(isBareScalar("42"));
    try std.testing.expect(isBareScalar("-17"));
    try std.testing.expect(isBareScalar("3.14"));
    try std.testing.expect(isBareScalar("1e10"));
    try std.testing.expect(isBareScalar("-2.5e-3"));
    try std.testing.expect(isBareScalar("true") and isBareScalar("false") and isBareScalar("null"));
    // must be REJECTED (→ quoted) — these are the args-corrupting cases:
    try std.testing.expect(!isBareScalar("10.0.0.1"));
    try std.testing.expect(!isBareScalar("1.2.3"));
    try std.testing.expect(!isBareScalar("+5"));
    try std.testing.expect(!isBareScalar("5."));
    try std.testing.expect(!isBareScalar(".5"));
    try std.testing.expect(!isBareScalar("1e"));
    try std.testing.expect(!isBareScalar("00"));
    try std.testing.expect(!isBareScalar("01"));
    try std.testing.expect(!isBareScalar(""));
    try std.testing.expect(!isBareScalar("three.js"));
}

test "estTokens: rough proxy divides by BYTES_PER_TOKEN" {
    try std.testing.expectEqual(@as(usize, 256), estTokens(1024));
    try std.testing.expectEqual(@as(usize, 0), estTokens(3));
}

test "readHeadTail + readSpanHeadTrimmed: positioned reads over a temp file" {
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

    // read the span covering the middle line region; it ends on a clean boundary and reports what it consumed
    const first_nl = std.mem.indexOfScalar(u8, content, '\n').?;
    const second_nl = std.mem.indexOfScalarPos(u8, content, first_nl + 1, '\n').?;
    var span_buf: [200]u8 = undefined;
    const span = readSpanHeadTrimmed(io, path, first_nl + 1, second_nl + 1, &span_buf) orelse return error.NoSpan;
    try std.testing.expectEqualStrings(content[first_nl + 1 .. second_nl + 1], span.bytes);
    try std.testing.expectEqual(span.bytes.len, span.consumed);
    try std.testing.expect(!span.clipped);
}

test "the summary cursor advances by bytes actually read, and can never stall" {
    // The ledger contract, which is the whole fix: `covered` moves by `consumed` and by nothing else, and every
    // non-null return consumes at least one byte. A helper that could return 0 — or that front-trimmed, the way
    // the tail-reading version silently did when a span overflowed its buffer — either spins the catch-up loop
    // forever or drops records the cursor then claims to have covered.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-chatctx-head-tmp.jsonl";
    const dir = std.Io.Dir.cwd();
    const content = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n";
    try dir.writeFile(io, .{ .sub_path = path, .data = content });
    defer dir.deleteFile(io, path) catch {};

    // A chunk smaller than the span stops on a line boundary — never mid-record, never front-trimmed.
    var small: [12]u8 = undefined;
    const c1 = readSpanHeadTrimmed(io, path, 0, content.len, &small) orelse return error.NoSpan;
    try std.testing.expectEqualStrings("{\"a\":1}\n", c1.bytes); // NOT the newest bytes — the OLDEST
    try std.testing.expectEqual(@as(usize, 8), c1.consumed);
    try std.testing.expect(!c1.clipped);

    // Draining the whole file is lossless: every byte is consumed exactly once, in order.
    var cursor: usize = 0;
    var seen: std.ArrayListUnmanaged(u8) = .empty;
    defer seen.deinit(gpa);
    var guard: usize = 0;
    while (cursor < content.len and guard < 100) : (guard += 1) {
        const c = readSpanHeadTrimmed(io, path, cursor, content.len, &small) orelse break;
        try std.testing.expect(c.consumed >= 1); // the anti-stall invariant
        try seen.appendSlice(gpa, c.bytes);
        cursor += c.consumed;
    }
    try std.testing.expectEqual(content.len, cursor);
    try std.testing.expectEqualStrings(content, seen.items); // nothing dropped, nothing duplicated

    // A single record LONGER than the chunk must still make progress rather than pin the cursor forever.
    const longline = "{\"x\":\"" ++ "y" ** 64 ++ "\"}\n";
    try dir.writeFile(io, .{ .sub_path = path, .data = longline });
    const big = readSpanHeadTrimmed(io, path, 0, longline.len, &small) orelse return error.NoSpan;
    try std.testing.expect(big.clipped); // reported as a fragment so the summarizer is not misled
    try std.testing.expectEqual(@as(usize, small.len), big.consumed);
    try std.testing.expect(big.consumed >= 1);

    // degenerate spans yield null rather than a zero-consumed advance
    try std.testing.expect(readSpanHeadTrimmed(io, path, 5, 5, &small) == null);
    try std.testing.expect(readSpanHeadTrimmed(io, "zig-chatctx-missing.jsonl", 0, 10, &small) == null);
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

test "recoverMarkupCalls: parses the real DeepSeek/gpt-oss DSML tool-call markup, strips it from content" {
    const gpa = std.testing.allocator;
    // EXACT format a local gpt-oss run emits: narration + a Claude-style invoke block.
    const content =
        "I see the issue.\n\n" ++
        "<｜｜DSML｜｜tool_calls>\n" ++
        "<｜｜DSML｜｜invoke name=\"read_file\">\n" ++
        "<｜｜DSML｜｜parameter name=\"path\" string=\"true\">index.html</｜｜DSML｜｜parameter>\n" ++
        "<｜｜DSML｜｜parameter name=\"start_line\" string=\"false\">1</｜｜DSML｜｜parameter>\n" ++
        "<｜｜DSML｜｜parameter name=\"end_line\" string=\"false\">100</｜｜DSML｜｜parameter>\n" ++
        "</｜｜DSML｜｜invoke>\n" ++
        "</｜｜DSML｜｜tool_calls>";
    const rec = recoverMarkupCalls(gpa, content) orelse return error.NoRecovery;
    defer {
        gpa.free(rec.stripped);
        for (rec.calls) |c| {
            gpa.free(c.name);
            gpa.free(c.args);
        }
        gpa.free(rec.calls);
    }
    try std.testing.expectEqualStrings("I see the issue.", rec.stripped); // markup block removed
    try std.testing.expectEqual(@as(usize, 1), rec.calls.len);
    try std.testing.expectEqualStrings("read_file", rec.calls[0].name);
    // path quoted (string="true"); start_line/end_line raw (string="false" + bare integer)
    try std.testing.expectEqualStrings("{\"path\":\"index.html\",\"start_line\":1,\"end_line\":100}", rec.calls[0].args);
}

test "recoverMarkupCalls: null when there is no markup; a non-numeric raw value falls back to a string" {
    const gpa = std.testing.allocator;
    try std.testing.expect(recoverMarkupCalls(gpa, "just a normal reply, no tool calls here") == null);

    // string="false" but the value isn't a bare scalar → must be quoted so the args JSON still parses.
    const content =
        "<｜｜DSML｜｜invoke name=\"web_search\">" ++
        "<｜｜DSML｜｜parameter name=\"query\" string=\"false\">three.js sprites</｜｜DSML｜｜parameter>" ++
        "</｜｜DSML｜｜invoke>";
    const rec = recoverMarkupCalls(gpa, content) orelse return error.NoRecovery;
    defer {
        gpa.free(rec.stripped);
        for (rec.calls) |c| {
            gpa.free(c.name);
            gpa.free(c.args);
        }
        gpa.free(rec.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), rec.calls.len);
    try std.testing.expectEqualStrings("web_search", rec.calls[0].name);
    try std.testing.expectEqualStrings("{\"query\":\"three.js sprites\"}", rec.calls[0].args);
    try std.testing.expect(looksLikeToolMarkup(content));
    try std.testing.expect(!looksLikeToolMarkup("a clean answer"));
}

test "stripSentinelTags: unwraps a reply wrapped in its own control token, in every decoration variant" {
    const gpa = std.testing.allocator;
    // the reported shape: the whole answer wrapped in bare <DSML>…</DSML>
    const plain = stripSentinelTags(gpa, "<DSML>Here is the summary you asked for.</DSML>").?;
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("Here is the summary you asked for.", plain);

    // fullwidth-bar spelling (U+FF5C), the raw special-token form, with newlines around the body
    const bars = stripSentinelTags(gpa, "<\u{FF5C}\u{FF5C}DSML\u{FF5C}\u{FF5C}>\nthe answer\n</\u{FF5C}\u{FF5C}DSML\u{FF5C}\u{FF5C}>").?;
    defer gpa.free(bars);
    try std.testing.expectEqualStrings("the answer", bars);

    // ASCII-pipe spelling, and a stray opener with no closer still goes
    const pipes = stripSentinelTags(gpa, "<|DSML|>real text").?;
    defer gpa.free(pipes);
    try std.testing.expectEqualStrings("real text", pipes);

    // NO-OP on clean prose (and no allocation): null means "keep what you had"
    try std.testing.expect(stripSentinelTags(gpa, "A perfectly normal answer with <html> in it.") == null);

    // TOOL-CALL markup is NOT a bare wrapper — it carries a verb, so it survives for recoverMarkupCalls
    try std.testing.expect(stripSentinelTags(gpa, "<\u{FF5C}\u{FF5C}DSML\u{FF5C}\u{FF5C}invoke name=\"read_file\">") == null);
}

test "recoverMarkupCalls: parses the hermes <tool_call>/<function=…> dialect seen live from DeepSeek" {
    const gpa = std.testing.allocator;
    // EXACT shape from the live web-conv drive step that stalled as "continuing: <tool_call>…"
    const content =
        "Let me check the file first.\n\n" ++
        "<tool_call>\n" ++
        "<function=read_file>\n" ++
        "<parameter=path>\n" ++
        "gary-game.html\n" ++
        "</parameter>\n" ++
        "<parameter=start_line>\n" ++
        "1\n" ++
        "</parameter>\n" ++
        "</function>\n" ++
        "</tool_call>";
    try std.testing.expect(looksLikeToolMarkup(content));
    const rec = recoverMarkupCalls(gpa, content) orelse return error.NoRecovery;
    defer {
        gpa.free(rec.stripped);
        for (rec.calls) |c| {
            gpa.free(c.name);
            gpa.free(c.args);
        }
        gpa.free(rec.calls);
    }
    try std.testing.expectEqualStrings("Let me check the file first.", rec.stripped); // <tool_call> wrapper stripped too
    try std.testing.expectEqual(@as(usize, 1), rec.calls.len);
    try std.testing.expectEqualStrings("read_file", rec.calls[0].name);
    // a path stays a string; a bare integer stays bare so the tool's typed parse accepts it
    try std.testing.expectEqualStrings("{\"path\":\"gary-game.html\",\"start_line\":1}", rec.calls[0].args);
}

test "recoverMarkupCalls: two hermes functions in one block; a missing </parameter> doesn't swallow the sibling" {
    const gpa = std.testing.allocator;
    const content =
        "<function=recall>\n<parameter=query>player name</parameter>\n</function>\n" ++
        "<function=observe>\n<parameter=fact>\nthe user's name is Gary\n<parameter=></parameter>\n</function>";
    const rec = recoverMarkupCalls(gpa, content) orelse return error.NoRecovery;
    defer {
        gpa.free(rec.stripped);
        for (rec.calls) |c| {
            gpa.free(c.name);
            gpa.free(c.args);
        }
        gpa.free(rec.calls);
    }
    try std.testing.expectEqualStrings("", rec.stripped); // markup-only content -> empty narration
    try std.testing.expectEqual(@as(usize, 2), rec.calls.len);
    try std.testing.expectEqualStrings("recall", rec.calls[0].name);
    try std.testing.expectEqualStrings("{\"query\":\"player name\"}", rec.calls[0].args);
    try std.testing.expectEqualStrings("observe", rec.calls[1].name);
    // the unclosed fact value ends at the NEXT <parameter=, not at the block's end
    try std.testing.expectEqualStrings("{\"fact\":\"the user's name is Gary\"}", rec.calls[1].args);
}

test "capacity budgets follow the window in BOTH directions, and a small model is never handed a frontier prompt" {
    const t = std.testing;
    const k8: usize = 8 * 1024 * 3; // window bytes at the engine's 3 bytes/token: an 8k model
    const k32: usize = 32 * 1024 * 3;
    const k64: usize = 64 * 1024 * 3;
    const k128: usize = 128 * 1024 * 3;

    // the summary: the stock cap at 32k for EVERY capacity (a 32k model keeps exactly what it had), the floor at
    // 8k, and above 32k it grows only as far as the READER can follow
    try t.expectEqual(SUMMARY_INJECT_MIN, summaryInjectCap(k8, .small));
    try t.expectEqual(SUMMARY_INJECT_CAP, summaryInjectCap(k32, .small));
    try t.expectEqual(SUMMARY_INJECT_CAP, summaryInjectCap(k32, .large));
    try t.expectEqual(SUMMARY_INJECT_CAP, summaryInjectCap(k128, .small)); // an 8B with a 128k window stays at 6 KiB
    try t.expectEqual(@as(usize, 10 * 1024), summaryInjectCap(k128, .mid));
    try t.expectEqual(@as(usize, 16 * 1024), summaryInjectCap(k128, .large));
    try t.expectEqual(@as(usize, 12 * 1024), summaryInjectCap(k64, .large));
    // monotone in the window, monotone in capacity
    var prev: usize = 0;
    var w: usize = 4 * 1024;
    while (w <= 2 * 1024 * 1024) : (w *= 2) {
        const c = summaryInjectCap(w, .large);
        try t.expect(c >= prev);
        try t.expect(summaryInjectCap(w, .small) <= summaryInjectCap(w, .mid));
        try t.expect(summaryInjectCap(w, .mid) <= summaryInjectCap(w, .large));
        prev = c;
    }

    // the recency ceiling: a small model is capped where it was, a frontier model may replay more than twice that
    try t.expectEqual(HISTORY_WINDOW_BYTES, historyWindowCap(.small));
    try t.expect(historyWindowCap(.mid) > historyWindowCap(.small));
    try t.expect(historyWindowCap(.large) > historyWindowCap(.mid));

    // the facts block: the floor at 8k, 4 KiB at 32k, and a capacity ceiling above
    try t.expectEqual(FACTS_BUDGET_MIN, factsBudget(k8, .small));
    try t.expectEqual(@as(usize, 4 * 1024), factsBudget(k32, .mid));
    try t.expectEqual(@as(usize, 12 * 1024), factsBudget(k128, .large));
    try t.expectEqual(@as(usize, 4 * 1024), factsBudget(k128, .small));

    // the fold chunk follows the SUMMARIZER: an 8k model reads 12 KiB a fold (and the whole request then fits its
    // window), a 32k model reads the stock 32 KiB, and nothing pushes it below the floor
    const small_cap = summaryInjectCap(k8, .small);
    const small_chunk = summaryChunkBytes(k8, small_cap);
    try t.expect(small_chunk < SUMMARY_CHUNK_BYTES);
    try t.expect(small_chunk >= SUMMARY_CHUNK_MIN_BYTES);
    try t.expect(small_chunk + 4 * small_cap + SUMMARY_PROMPT_OVERHEAD_BYTES <= k8);
    try t.expectEqual(SUMMARY_CHUNK_BYTES, summaryChunkBytes(k32, SUMMARY_INJECT_CAP));
    try t.expectEqual(SUMMARY_CHUNK_MIN_BYTES, summaryChunkBytes(10 * 1024, SUMMARY_INJECT_CAP));

    // the fold's shape: a small model writes short, a frontier model uses its room, and a tightened cap bounds
    // the words it is asked for so nothing it writes is clipped away
    const s = foldShape(.small, summaryInjectCap(k8, .small));
    const l = foldShape(.large, summaryInjectCap(k128, .large));
    try t.expectEqual(@as(usize, 200), s.words);
    try t.expectEqual(@as(usize, 900), l.words);
    try t.expect(s.facts_lines < l.facts_lines);
    try t.expect(s.max_tokens < l.max_tokens);
    try t.expect(s.max_tokens >= 768 and l.max_tokens <= 4096);
    const bounded = foldShape(.large, SUMMARY_INJECT_MIN); // a frontier summarizer writing for a tiny reader
    try t.expect(bounded.words * 8 <= SUMMARY_INJECT_MIN);
    try t.expect(bounded.words >= 80);
}

test "splitNote: the summary and the FACTS come apart under every heading style, and a bare reply is all summary" {
    const t = std.testing;
    const a = splitNote("SUMMARY:\nThe user is building a parser.\n\nFACTS:\n- db: sqlite\n- path: src/x.zig");
    try t.expectEqualStrings("The user is building a parser.", a.summary);
    try t.expectEqualStrings("- db: sqlite\n- path: src/x.zig", a.facts.?);

    const b = splitNote("## Summary\ntext here\n## Facts\nk: v\n");
    try t.expectEqualStrings("text here", b.summary);
    try t.expectEqualStrings("k: v\n", b.facts.?);

    const c = splitNote("**SUMMARY:** inline text\n**FACTS**\na: 1");
    try t.expectEqualStrings("inline text", c.summary);
    try t.expectEqualStrings("a: 1", c.facts.?);

    // no FACTS line: the whole reply is the summary — exactly what the pre-ledger fold kept
    const d = splitNote("Just a summary, with the facts unclear.");
    try t.expectEqualStrings("Just a summary, with the facts unclear.", d.summary);
    try t.expect(d.facts == null);

    // prose that begins with the word is content, not a heading
    const e = splitNote("Summary of the work so far: the parser is done.");
    try t.expectEqualStrings("Summary of the work so far: the parser is done.", e.summary);

    const f = splitNote("");
    try t.expectEqualStrings("", f.summary);
    try t.expect(f.facts == null);

    // facts with no summary: the caller keeps its prior summary and still gets the facts
    const g = splitNote("FACTS:\na: 1");
    try t.expectEqualStrings("", g.summary);
    try t.expectEqualStrings("a: 1", g.facts.?);
}

test "cleanFactLines: bullets and noise drop, the allowance holds, and a trailing PROGRESS section ends the list" {
    const gpa = std.testing.allocator;
    const raw = "- db: sqlite\n* path: src/x.zig\n\n-\nPROGRESS: wrote stuff\nnot a fact after progress";
    const all = cleanFactLines(gpa, raw, 10) orelse return error.NoFacts;
    defer gpa.free(all);
    try std.testing.expectEqualStrings("db: sqlite\npath: src/x.zig", all);

    const one = cleanFactLines(gpa, raw, 1) orelse return error.NoFacts;
    defer gpa.free(one);
    try std.testing.expectEqualStrings("db: sqlite", one);

    try std.testing.expect(cleanFactLines(gpa, "\n- \n", 10) == null);
    const long = "k: " ++ "v" ** 500;
    try std.testing.expect(cleanFactLines(gpa, long, 10) == null);
}

test "cueTokens: content words only, deduplicated, bounded" {
    var toks: [CUE_TOKENS_MAX][]const u8 = undefined;
    const n = cueTokens("Which DATABASE did we pick for the parser? database, please", &toks);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("DATABASE", toks[0]);
    try std.testing.expectEqualStrings("pick", toks[1]);
    try std.testing.expectEqualStrings("parser", toks[2]);
    var two: [2][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), cueTokens("alpha bravo charlie delta", &two));
    try std.testing.expectEqual(@as(usize, 0), cueTokens("", &toks));
}

test "digestRecord round-trips through a real JSON parser" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try digestRecord(gpa, &out, 120, 4096, 1788819741, "db: \"sqlite\"\npath: C:\\x\\y.zig");
    try std.testing.expect(std.mem.endsWith(u8, out.items, "}\n"));
    const Rec = struct { from: usize, to: usize, ts: i64, facts: []const u8 };
    const p = try std.json.parseFromSlice(Rec, gpa, out.items[0 .. out.items.len - 1], .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 120), p.value.from);
    try std.testing.expectEqual(@as(usize, 4096), p.value.to);
    try std.testing.expectEqual(@as(i64, 1788819741), p.value.ts);
    try std.testing.expectEqualStrings("db: \"sqlite\"\npath: C:\\x\\y.zig", p.value.facts);
}

test "selectFacts: the newest half is always present, the cue pulls an old line back, and a repeat lands once" {
    const gpa = std.testing.allocator;
    var tail: std.ArrayListUnmanaged(u8) = .empty;
    defer tail.deinit(gpa);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var fb: [256]u8 = undefined;
        const facts = if (i == 0)
            try std.fmt.bufPrint(&fb, "r{d} topic: value{d}\ndatabase engine: sqlite WAL mode", .{ i, i })
        else if (i == 3 or i == 30)
            try std.fmt.bufPrint(&fb, "r{d} topic: value{d}\nshared: same", .{ i, i })
        else
            try std.fmt.bufPrint(&fb, "r{d} topic: value{d}", .{ i, i });
        try digestRecord(gpa, &tail, i * 100, i * 100 + 100, @intCast(1000 + i), facts);
    }
    try tail.appendSlice(gpa, "this line is not a record\n{\"facts\":\"\"}\n"); // garbage and an empty record are skipped

    // a tight budget: the newest facts are there, the oldest unrelated one is not, and the budget holds
    const tight = selectFacts(gpa, tail.items, "", 300) orelse return error.NoFacts;
    defer gpa.free(tight);
    try std.testing.expect(tight.len <= 300);
    try std.testing.expect(std.mem.indexOf(u8, tight, "r39 topic: value39") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight, "r1 topic: value1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, tight, "database engine") == null);

    // the same budget, asked about the database: the oldest line comes back, the newest are still present
    const cued = selectFacts(gpa, tail.items, "which database engine did we choose?", 300) orelse return error.NoFacts;
    defer gpa.free(cued);
    try std.testing.expect(cued.len <= 300);
    try std.testing.expect(std.mem.indexOf(u8, cued, "database engine: sqlite WAL mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, cued, "r39 topic: value39") != null);
    // ...and it is rendered oldest-first: the recovered line precedes the newest
    try std.testing.expect(std.mem.indexOf(u8, cued, "database engine").? < std.mem.indexOf(u8, cued, "r39 topic").?);

    // a roomy budget takes everything once: the repeat appears a single time, at its NEWEST position
    const all = selectFacts(gpa, tail.items, "", 100_000) orelse return error.NoFacts;
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, all, "shared: same"));
    const at = std.mem.indexOf(u8, all, "shared: same").?;
    try std.testing.expect(at > std.mem.indexOf(u8, all, "r29 topic").?);
    try std.testing.expect(at < std.mem.indexOf(u8, all, "r31 topic").?);
    try std.testing.expect(std.mem.indexOf(u8, all, "r0 topic").? < std.mem.indexOf(u8, all, "r39 topic").?);
    try std.testing.expect(std.mem.indexOf(u8, all, "not a record") == null);

    // nothing to project renders nothing
    try std.testing.expect(selectFacts(gpa, "", "x", 300) == null);
    try std.testing.expect(selectFacts(gpa, tail.items, "x", 0) == null);
    try std.testing.expect(selectFacts(gpa, "garbage\n", "x", 300) == null);
}

test "readTailTrimmed: the newest bytes of the ledger, whole records only, or nothing" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-chatctx-digest-tmp.jsonl";
    const dir = std.Io.Dir.cwd();
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(gpa);
    try digestRecord(gpa, &content, 0, 10, 1, "a: 1");
    try digestRecord(gpa, &content, 10, 20, 2, "b: 2");
    try digestRecord(gpa, &content, 20, 30, 3, "c: 3");
    try dir.writeFile(io, .{ .sub_path = path, .data = content.items });
    defer dir.deleteFile(io, path) catch {};

    // a buffer smaller than the file starts mid-record: the torn head is dropped, whole records remain
    var small: [60]u8 = undefined;
    const tail = readTailTrimmed(io, path, &small) orelse return error.NoTail;
    try std.testing.expect(tail.len < 60);
    try std.testing.expect(std.mem.startsWith(u8, tail, "{\"from\":20"));
    try std.testing.expect(std.mem.endsWith(u8, tail, "}\n"));
    // a buffer larger than the file returns it whole
    var big: [1024]u8 = undefined;
    const whole = readTailTrimmed(io, path, &big) orelse return error.NoTail;
    try std.testing.expectEqualStrings(content.items, whole);
    // and a missing ledger is "no ledger yet"
    try std.testing.expect(readTailTrimmed(io, "zig-chatctx-digest-missing.jsonl", &big) == null);
}
