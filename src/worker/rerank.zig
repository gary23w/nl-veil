//! rerank.zig — SECOND-STAGE relevance reranking over first-stage retrieval, through the run's SELECTED
//! (BYOK / gateway) chat endpoint. No local model, weights, or sidecar: it rides the same `gw_base`/`gw_key`/
//! `gateway_model` that `screenPass` and `gapToQuery` use, so it works on ANY machine a BYOK download lands on.
//!
//! Why an LLM reranker, not a cross-encoder: a cross-encoder (bge-reranker et al.) is more precise per call but
//! needs downloaded weights + compute + a sidecar, so it can't be the DEFAULT under BYOK. Zero-shot LLM
//! reranking through the configured endpoint is the any-machine default; a local reranker stays an opt-in.
//!
//! DESIGN — zero-shot listwise reranking, cost-disciplined to one call per recall:
//!   * SINGLE-CALL LISTWISE-SELECT. One gateway inference over the whole (small) candidate window — NOT
//!     pointwise (N calls), pairwise, or setwise/tournament (multi-call sorts). A step that runs on every
//!     grounded recall can afford exactly one call.
//!   * KEEP + ABSTAIN, not just permute. The model returns ONLY the ids that genuinely answer the query, best
//!     first — or NONE. The empty return is RAG's missing abstain floor: the caller can SAY "nothing relevant"
//!     instead of injecting the retriever's argmax noise.
//!   * POSITION-BIAS AWARE. Candidates are id-labelled [1..N] and the model answers with IDS (never positions);
//!     temperature is pinned to 0 for determinism; the window is ONE pass (no sliding window). A caller needing
//!     more robustness can run a second shuffled pass and intersect; left to the caller because it doubles cost.
//!   * TOKEN BUDGET for reasoning models. A reasoning gateway model spends its completion budget on hidden
//!     reasoning first; too small a cap returns an EMPTY answer. The budget here is generous so the id list
//!     always fits after the reasoning.
//!   * GRACEFUL. Any transport/parse ambiguity returns .passthrough (retrieval order): the reranker can only
//!     improve or no-op, NEVER regress below first-stage retrieval. Abstain (drops all context) fires ONLY on
//!     an explicit NONE, never on a mere parse failure.

const std = @import("std");
const llm = @import("llm.zig");

/// Largest candidate window sent in one pass. Kept small so it fits a single prompt (no sliding window) and the
/// call stays cheap; first-stage retrieval already narrowed the field, so 20 is ample headroom.
pub const MAX_CANDIDATES: usize = 20;
/// Per-candidate clip — the judge needs enough to judge relevance, not the whole document.
const CANDIDATE_CLIP: usize = 240;
/// Completion budget: room for a REASONING gateway model to think, THEN emit the (short) id list. Too small and
/// a reasoning model burns the budget on hidden reasoning and returns empty content.
const RERANK_MAX_TOKENS: u32 = 1024;

const SYS =
    "You are a strict relevance judge for a retrieval system. You are given a QUERY and a numbered list of " ++
    "candidate facts. Return ONLY the numbers of the candidates that GENUINELY help answer the query, most " ++
    "relevant FIRST, as a plain comma-separated list (e.g. 3,1,7). Include a candidate ONLY if it actually " ++
    "addresses the query — OMIT anything that is merely on the same broad topic but does not answer it. If NONE " ++
    "of the candidates are genuinely relevant, reply with exactly NONE. Output ONLY the numbers or the word " ++
    "NONE — no prose, no explanation, no restating the candidates.";

pub const Outcome = enum {
    reranked, // `order` holds the kept candidate indices, best-first (a filtered + reordered subset)
    abstain, // the judge said NONE are relevant — the caller should surface "nothing relevant", not the argmax
    passthrough, // could not/should not rerank (no gateway, ≤1 candidate, transport/parse failure) — use retrieval order
};

pub const Result = struct {
    outcome: Outcome,
    /// 0-based indices into the caller's `candidates`, best-first. gpa-owned; free with `deinit` when
    /// outcome == .reranked (empty and static for .abstain / .passthrough).
    order: []const usize = &.{},

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        if (self.order.len > 0) gpa.free(self.order);
    }
};

/// Rerank `candidates` against `query` via the gateway endpoint, keeping the best `keep`. See the module header
/// for the algorithm. `base`/`key`/`model` are the run's gateway creds; an empty model (or ≤1 candidate) is a
/// clean no-op passthrough so callers can invoke this unconditionally.
pub fn rerank(
    gpa: std.mem.Allocator,
    io: std.Io,
    run_dir: []const u8,
    base: []const u8,
    key: []const u8,
    model: []const u8,
    query: []const u8,
    candidates: []const []const u8,
    keep: usize,
) Result {
    // Nothing to reorder, or nowhere to ask: fall straight through to retrieval order.
    if (candidates.len <= 1 or model.len == 0 or std.mem.trim(u8, query, " \r\n\t").len == 0)
        return .{ .outcome = .passthrough };

    const n = @min(candidates.len, MAX_CANDIDATES);

    var user: std.ArrayListUnmanaged(u8) = .empty;
    defer user.deinit(gpa);
    user.appendSlice(gpa, "QUERY: ") catch return .{ .outcome = .passthrough };
    user.appendSlice(gpa, clip(query, 400)) catch return .{ .outcome = .passthrough };
    user.appendSlice(gpa, "\n\nCANDIDATES:\n") catch return .{ .outcome = .passthrough };
    for (candidates[0..n], 1..) |c, i| {
        var nb: [16]u8 = undefined;
        const head = std.fmt.bufPrint(&nb, "[{d}] ", .{i}) catch "[?] ";
        user.appendSlice(gpa, head) catch return .{ .outcome = .passthrough };
        // one candidate = one line: collapse embedded newlines/tabs to spaces so the [n] framing stays unambiguous
        for (clip(c, CANDIDATE_CLIP)) |ch| {
            user.append(gpa, if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch) catch return .{ .outcome = .passthrough };
        }
        user.append(gpa, '\n') catch return .{ .outcome = .passthrough };
    }
    user.appendSlice(gpa, "\nRelevant candidate numbers, most relevant first (or NONE):") catch return .{ .outcome = .passthrough };

    // temperature 0 → deterministic verdict for an identical candidate set (mirrors the constitution screen).
    const r = llm.chatTemp(gpa, io, run_dir, "rerank", base, key, model, SYS, user.items, RERANK_MAX_TOKENS, 0.0);
    defer gpa.free(r.content);
    if (!r.ok) return .{ .outcome = .passthrough };

    var buf: [MAX_CANDIDATES]usize = undefined;
    const p = parseRanked(r.content, n, @min(keep, n), &buf);
    switch (p.kind) {
        .none => return .{ .outcome = .abstain },
        .ambiguous => return .{ .outcome = .passthrough }, // never drop all context on a parse we don't trust
        .ids => {
            const owned = gpa.alloc(usize, p.ids.len) catch return .{ .outcome = .passthrough };
            @memcpy(owned, p.ids);
            return .{ .outcome = .reranked, .order = owned };
        },
    }
}

const ParseKind = enum { ids, none, ambiguous };
const Parsed = struct { kind: ParseKind, ids: []const usize };

/// Parse the judge's reply into best-first 0-based indices. PURE — the reliability core, unit-tested:
///   * scans integer runs in order; keeps those in [1..n]; dedups; maps to 0-based; caps at `keep`.
///   * ANY valid id ⇒ .ids (a real selection wins even if the model also wrote noise).
///   * no valid id but an explicit NONE / "no ... relevant" marker ⇒ .none (a real abstain).
///   * no valid id and no NONE marker ⇒ .ambiguous (garbled/off-format — caller keeps retrieval order; we do
///     NOT abstain, because abstain drops ALL context and a parse failure is not evidence of irrelevance).
/// `buf` must hold at least `keep` entries; the returned slice aliases it.
fn parseRanked(reply: []const u8, n: usize, keep: usize, buf: []usize) Parsed {
    const t = std.mem.trim(u8, reply, " \r\n\t");
    var count: usize = 0;
    var i: usize = 0;
    while (i < t.len and count < keep and count < buf.len) {
        if (t[i] < '0' or t[i] > '9') {
            i += 1;
            continue;
        }
        // read the integer run
        var v: usize = 0;
        var digits: usize = 0;
        while (i < t.len and t[i] >= '0' and t[i] <= '9' and digits < 6) : (i += 1) {
            v = v * 10 + (t[i] - '0');
            digits += 1;
        }
        // skip any remaining digits of an over-long run so "1234567" doesn't re-enter mid-number
        while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
        if (v < 1 or v > n) continue; // out of range → not a candidate id (stray number in prose)
        const idx = v - 1;
        var dup = false;
        for (buf[0..count]) |seen| {
            if (seen == idx) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            buf[count] = idx;
            count += 1;
        }
    }
    if (count > 0) return .{ .kind = .ids, .ids = buf[0..count] };
    if (saysNone(t)) return .{ .kind = .none, .ids = &.{} };
    return .{ .kind = .ambiguous, .ids = &.{} };
}

/// An explicit "nothing relevant" verdict (no ids were present). Case-insensitive; matches a leading NONE and
/// the common natural-language forms a model emits when told to answer NONE.
fn saysNone(t: []const u8) bool {
    var lb: [64]u8 = undefined;
    const m = @min(t.len, lb.len);
    for (t[0..m], 0..) |c, k| lb[k] = std.ascii.toLower(c);
    const low = lb[0..m];
    if (std.mem.startsWith(u8, low, "none")) return true;
    const needles = [_][]const u8{ "no relevant", "none are relevant", "none of the", "not relevant", "no candidate" };
    for (needles) |ndl| if (std.mem.indexOf(u8, low, ndl) != null) return true;
    return false;
}

fn clip(s: []const u8, max: usize) []const u8 {
    return if (s.len > max) s[0..max] else s;
}

// ------------------------------------------------------------------------------------------------ tests

test "parseRanked: comma list of ids → best-first 0-based, in range, deduped, capped" {
    var buf: [20]usize = undefined;
    const p = parseRanked("3, 1, 7", 10, 8, &buf);
    try std.testing.expect(p.kind == .ids);
    try std.testing.expectEqualSlices(usize, &.{ 2, 0, 6 }, p.ids);
}

test "parseRanked: NONE and natural-language none → abstain" {
    var buf: [20]usize = undefined;
    try std.testing.expect(parseRanked("NONE", 5, 8, &buf).kind == .none);
    try std.testing.expect(parseRanked("none are relevant", 5, 8, &buf).kind == .none);
    try std.testing.expect(parseRanked("None of the candidates address the query.", 5, 8, &buf).kind == .none);
}

test "parseRanked: garbled/off-format with no ids and no NONE → ambiguous (passthrough, never abstain)" {
    var buf: [20]usize = undefined;
    try std.testing.expect(parseRanked("the second one looks good", 5, 8, &buf).kind == .ambiguous);
    try std.testing.expect(parseRanked("", 5, 8, &buf).kind == .ambiguous);
}

test "parseRanked: out-of-range numbers are ignored; a valid id still wins over stray numbers" {
    var buf: [20]usize = undefined;
    // "in 2026 ... candidate 3" — only 3 is a real id (2026 is out of [1..5] range and skipped)
    const p = parseRanked("Based on the 2026 data, candidate 3 is the answer.", 5, 8, &buf);
    try std.testing.expect(p.kind == .ids);
    try std.testing.expectEqualSlices(usize, &.{2}, p.ids);
}

test "parseRanked: dedup + keep cap + bracketed/reasoning-model output" {
    var buf: [20]usize = undefined;
    // a reasoning model that restated ids with brackets and repeats; keep=3 caps it
    const p = parseRanked("[4] [2] [4] [9] [1]", 10, 3, &buf);
    try std.testing.expect(p.kind == .ids);
    try std.testing.expectEqualSlices(usize, &.{ 3, 1, 8 }, p.ids); // 4,2,9 (dup 4 dropped, capped at 3)
}
