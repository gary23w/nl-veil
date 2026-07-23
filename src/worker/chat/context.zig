//! chat_context.zig — bounded LLM-context assembly for the server chat turn.
//!
//! The durable conversation log (messages.jsonl) grows without bound, but what we FEED the model each inference
//! must stay inside its context window. This module projects the full history into a fixed budget rather than
//! replaying the whole transcript (which overflows the model window and hits a hard 8 MiB read cliff on long chats):
//!
//!   * pin the original goal (the first user message) — it anchors the whole arc,
//!   * replay only a RECENCY WINDOW of the newest turns (the bulk of what the model needs),
//!   * report the GAP so the caller can cover the dropped middle with a rolling summary + relevance recall.
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
