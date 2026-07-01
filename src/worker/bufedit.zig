//! bufedit.zig — the buffer-based, line-addressable file EDIT core.

const std = @import("std");

pub const OpKind = enum { replace, insert_before, insert_after, insert_at, delete };

pub const EditOp = struct {
    kind: OpKind,
    anchor: []const u8 = "",
    text: []const u8 = "",
    at: usize = 0,
};

/// Where an applied op's replacement/insertion text landed in the RESULT bytes — the op's line identity for a
/// later rebase/merge guard (a mind's ops rebased onto a changed HEAD must prove they matched the SAME line).
pub const MatchLocus = struct { op_index: u32, matched_offset: u64 };

pub const Applied = struct {
    ok: bool,
    bytes: []u8 = "",
    reject: []u8 = "",
    loci: []MatchLocus = &.{}, // owned; one per op in op-index order, only when ok (empty under OOM fallback)
    reindented: u32 = 0, // ops whose replacement was auto-reindented to the file (loose match) — surfaced, not silent
};

fn trimTrail(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == '\t' or s[e - 1] == '\r')) e -= 1;
    return s[0..e];
}
fn trimBoth(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}
fn leadingWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[0..i];
}

/// On a LOOSE anchor match the model dropped the file's indentation; re-key `text`'s indentation from its own
/// first-line indent to the file's (`file_ws`), preserving the replacement's RELATIVE indentation. Only called
/// when the two differ, so an exact-match edit (an intentional reindent) is never touched. Returns owned bytes.
fn reindentToFile(gpa: std.mem.Allocator, text: []const u8, file_ws: []const u8) []u8 {
    const repl_ws = leadingWs(text); // the replacement's own first-line indent = the base we re-key from
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |ln| {
        if (!first) out.append(gpa, '\n') catch {};
        first = false;
        const strip = @min(repl_ws.len, leadingWs(ln).len);
        out.appendSlice(gpa, file_ws) catch {};
        out.appendSlice(gpa, ln[strip..]) catch {};
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, text) catch @constCast(text));
}

fn splitLines(gpa: std.mem.Allocator, lf: []const u8) std.ArrayListUnmanaged([]const u8) {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, lf, '\n');
    while (it.next()) |ln| lines.append(gpa, ln) catch {};
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0 and lf.len > 0 and lf[lf.len - 1] == '\n')
        _ = lines.pop();
    return lines;
}

fn normalizeLF(gpa: std.mem.Allocator, s: []const u8) []u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.ensureTotalCapacity(gpa, s.len) catch return gpa.dupe(u8, s) catch @constCast("");
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\r') {
            out.append(gpa, '\n') catch {};
            if (i + 1 < s.len and s[i + 1] == '\n') i += 1;
        } else out.append(gpa, s[i]) catch {};
    }
    return out.toOwnedSlice(gpa) catch (gpa.dupe(u8, s) catch @constCast(""));
}

const MatchErr = enum { not_found, ambiguous };

// Unique run of `anchor_lines` in `lines`: exact (trailing-trim) first, then a leading+trailing-trim rescue, but
// only when that rescue is itself unique — a reindented anchor is recovered without ever making a wrong match.
fn matchAnchor(lines: []const []const u8, anchor_lines: []const []const u8, out_start: *usize, out_loose: *bool) ?MatchErr {
    if (anchor_lines.len == 0 or anchor_lines.len > lines.len) return .not_found;
    inline for (.{ false, true }) |loose| {
        var found: usize = 0;
        var first: usize = 0;
        var s: usize = 0;
        while (s + anchor_lines.len <= lines.len) : (s += 1) {
            var all = true;
            for (anchor_lines, 0..) |al, k| {
                const a = if (loose) trimBoth(al) else trimTrail(al);
                const b = if (loose) trimBoth(lines[s + k]) else trimTrail(lines[s + k]);
                if (!std.mem.eql(u8, a, b)) {
                    all = false;
                    break;
                }
            }
            if (all) {
                found += 1;
                if (found == 1) first = s;
            }
        }
        if (found == 1) {
            out_start.* = first;
            out_loose.* = loose;
            return null;
        }
        if (found > 1) return .ambiguous;
    }
    return .not_found;
}

fn rejectMsg(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Applied {
    return .{ .ok = false, .reject = std.fmt.allocPrint(gpa, fmt, args) catch @constCast("edit rejected") };
}

fn firstNonEmpty(lines: []const []const u8) []const u8 {
    for (lines) |ln| {
        if (trimBoth(ln).len > 0) return ln;
    }
    return "";
}

/// A weak model's anchor usually misses by a FEW characters (retyped, wrong indent, curly quote). Show it the
/// closest real file line (by shared-character prefix/token overlap) with its line number, so the corrective
/// turn can copy the true text instead of guessing again. Returns a borrowed slice of `lines` content in a
/// caller-provided buffer ("" when the file is empty or nothing is remotely close).
fn nearestLineHint(lines: []const []const u8, anchor_first: []const u8, buf: []u8) []const u8 {
    const want = trimBoth(anchor_first);
    if (want.len == 0 or lines.len == 0) return "";
    var best_i: usize = 0;
    var best_score: usize = 0;
    for (lines, 0..) |ln, i| {
        const have = trimBoth(ln);
        if (have.len == 0) continue;
        var score: usize = 0;
        const n = @min(want.len, have.len);
        while (score < n and want[score] == have[score]) score += 1; // shared prefix
        if (std.mem.indexOf(u8, have, want) != null or std.mem.indexOf(u8, want, have) != null) score += n / 2;
        if (score > best_score) {
            best_score = score;
            best_i = i;
        }
    }
    if (best_score < 4) return "";
    return std.fmt.bufPrint(buf, " Closest file line is {d}: `{s}`", .{ best_i + 1, lines[best_i][0..@min(lines[best_i].len, 120)] }) catch "";
}

/// Apply all ops to `original`. Pure (no I/O). Returns owned rewritten bytes, or an owned reject reason.
/// Corruption-safe: every span resolves against the ORIGINAL, overlaps reject before any mutation, and the splice
/// runs highest-offset-first so earlier edits never invalidate a later span. All-or-nothing.
pub fn apply(gpa: std.mem.Allocator, original: []const u8, ops: []const EditOp) Applied {
    if (ops.len == 0) return rejectMsg(gpa, "no edit ops supplied", .{});
    if (ops.len > 64) return rejectMsg(gpa, "too many edit ops ({d}); split into separate turns (max 64)", .{ops.len});

    const crlf = std.mem.indexOf(u8, original, "\r\n") != null;
    const had_trailing_nl = original.len > 0 and (original[original.len - 1] == '\n' or original[original.len - 1] == '\r');
    const lf = normalizeLF(gpa, original);
    defer gpa.free(lf);
    var lines = splitLines(gpa, lf);
    defer lines.deinit(gpa);

    const Span = struct { lo: usize, hi: usize, insert: bool, kind: OpKind, text: []const u8, idx: usize };
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(gpa);
    // reindented replacement buffers (loose-match indentation preservation); span.text borrows these, so they
    // must outlive the splice loop below — freed at function return.
    var reindent_scratch: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (reindent_scratch.items) |s| gpa.free(s);
        reindent_scratch.deinit(gpa);
    }
    var reindent_count: u32 = 0;

    for (ops, 0..) |op, i| {
        if (op.kind == .insert_at) {
            var p = op.at;
            if (p == 0 or p > lines.items.len) p = lines.items.len + 1;
            spans.append(gpa, .{ .lo = p - 1, .hi = p - 1, .insert = true, .kind = .insert_after, .text = op.text, .idx = i }) catch {};
            continue;
        }
        if (op.anchor.len == 0) return rejectMsg(gpa, "op{d}: empty anchor — copy an exact snippet of the current file", .{i + 1});
        const anc_lf = normalizeLF(gpa, op.anchor);
        defer gpa.free(anc_lf);
        var anc_lines = splitLines(gpa, anc_lf);
        defer anc_lines.deinit(gpa);
        var start: usize = 0;
        var loose: bool = false;
        if (matchAnchor(lines.items, anc_lines.items, &start, &loose)) |err| {
            var hbuf: [180]u8 = undefined;
            return switch (err) {
                .not_found => rejectMsg(gpa, "op{d}: anchor not found — copy an exact snippet (leading spaces included) from the current file.{s}", .{ i + 1, nearestLineHint(lines.items, firstNonEmpty(anc_lines.items), &hbuf) }),
                .ambiguous => rejectMsg(gpa, "op{d}: anchor matches more than one place — add surrounding lines so it appears exactly once", .{i + 1}),
            };
        }
        const lo = start;
        const hi = start + anc_lines.items.len;
        // On a loose (reindented) match the model dropped the file's indentation; restore it on the replacement
        // so a de-indented SEARCH block cannot silently break an indentation-significant file (e.g. Python).
        var text = op.text;
        if (loose and op.kind != .delete and op.text.len > 0) {
            const file_ws = leadingWs(lines.items[start]);
            if (!std.mem.eql(u8, file_ws, leadingWs(op.text))) {
                const ri = reindentToFile(gpa, op.text, file_ws);
                reindent_scratch.append(gpa, ri) catch {};
                text = ri;
                reindent_count += 1;
            }
        }
        switch (op.kind) {
            .replace => spans.append(gpa, .{ .lo = lo, .hi = hi, .insert = false, .kind = .replace, .text = text, .idx = i }) catch {},
            .delete => spans.append(gpa, .{ .lo = lo, .hi = hi, .insert = false, .kind = .delete, .text = "", .idx = i }) catch {},
            .insert_before => spans.append(gpa, .{ .lo = lo, .hi = lo, .insert = true, .kind = .insert_after, .text = text, .idx = i }) catch {},
            .insert_after => spans.append(gpa, .{ .lo = hi, .hi = hi, .insert = true, .kind = .insert_after, .text = text, .idx = i }) catch {},
            .insert_at => unreachable,
        }
    }

    for (spans.items, 0..) |a, ai| {
        for (spans.items, 0..) |b, bi| {
            if (ai >= bi) continue;
            const overlap = (a.lo < b.hi and b.lo < a.hi);
            const a_pt_in_b = (a.insert and !b.insert and a.lo > b.lo and a.lo < b.hi);
            const b_pt_in_a = (b.insert and !a.insert and b.lo > a.lo and b.lo < a.hi);
            if (overlap or a_pt_in_b or b_pt_in_a)
                return rejectMsg(gpa, "op{d} and op{d} edit overlapping lines — split them into separate turns", .{ a.idx + 1, b.idx + 1 });
        }
    }

    std.mem.sort(Span, spans.items, {}, struct {
        fn lt(_: void, x: Span, y: Span) bool {
            return x.lo > y.lo;
        }
    }.lt);

    // inserted lines slice into these normalized buffers; keep them alive until AFTER the join below.
    var scratch: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (scratch.items) |s| gpa.free(s);
        scratch.deinit(gpa);
    }
    // each op's landing line in the evolving lines array. Spans apply highest-lo first, so every
    // already-recorded landing sits BELOW the current splice and shifts by (inserted - deleted); the op's own
    // landing starts at sp.lo and is shifted only by later (higher) splices, recorded after this shift.
    const Landing = struct { idx: u32, line: isize };
    var landings: std.ArrayListUnmanaged(Landing) = .empty;
    defer landings.deinit(gpa);
    for (spans.items) |sp| {
        var del: usize = 0;
        var ins: usize = 0;
        if (sp.kind == .delete) {
            del = sp.hi - sp.lo;
            lines.replaceRange(gpa, sp.lo, del, &.{}) catch return rejectMsg(gpa, "oom applying delete", .{});
        } else {
            const tnorm = normalizeLF(gpa, sp.text);
            scratch.append(gpa, tnorm) catch {};
            var tlines = splitLines(gpa, tnorm);
            defer tlines.deinit(gpa);
            del = if (sp.insert) 0 else (sp.hi - sp.lo);
            ins = tlines.items.len;
            lines.replaceRange(gpa, sp.lo, del, tlines.items) catch return rejectMsg(gpa, "oom applying edit", .{});
        }
        const delta: isize = @as(isize, @intCast(ins)) - @as(isize, @intCast(del));
        for (landings.items) |*L| L.line += delta;
        landings.append(gpa, .{ .idx = @intCast(sp.idx), .line = @intCast(sp.lo) }) catch {};
    }

    const eol: []const u8 = if (crlf) "\r\n" else "\n";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (lines.items, 0..) |ln, i| {
        out.appendSlice(gpa, ln) catch {};
        if (i + 1 < lines.items.len) out.appendSlice(gpa, eol) catch {};
    }
    if (had_trailing_nl and lines.items.len > 0) out.appendSlice(gpa, eol) catch {};
    const bytes = out.toOwnedSlice(gpa) catch return rejectMsg(gpa, "oom", .{});

    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) {
        gpa.free(bytes);
        return rejectMsg(gpa, "edit would empty the file — refusing", .{});
    }
    if (std.mem.eql(u8, bytes, original)) {
        gpa.free(bytes);
        return rejectMsg(gpa, "no change — the new text equals what is already there", .{});
    }

    // per-op match loci = the byte offset in `bytes` where each op's landing line begins (op-index order).
    // OOM here degrades to an ok result with no loci rather than failing the whole edit.
    const loci = gpa.alloc(MatchLocus, landings.items.len) catch return .{ .ok = true, .bytes = bytes, .reindented = reindent_count };
    const prefix = gpa.alloc(u64, lines.items.len + 1) catch {
        gpa.free(loci);
        return .{ .ok = true, .bytes = bytes, .reindented = reindent_count };
    };
    defer gpa.free(prefix);
    prefix[0] = 0;
    for (lines.items, 0..) |ln, i| prefix[i + 1] = prefix[i] + ln.len + eol.len;
    for (landings.items, 0..) |L, i| {
        const line_idx: usize = if (L.line < 0) 0 else @min(@as(usize, @intCast(L.line)), lines.items.len);
        loci[i] = .{ .op_index = L.idx, .matched_offset = prefix[line_idx] };
    }
    std.mem.sort(MatchLocus, loci, {}, struct {
        fn lt(_: void, x: MatchLocus, y: MatchLocus) bool {
            return x.op_index < y.op_index;
        }
    }.lt);
    return .{ .ok = true, .bytes = bytes, .loci = loci, .reindented = reindent_count };
}

pub const Narrated = struct { path: []u8, ops: []EditOp };

/// Parse narrated Aider-style SEARCH/REPLACE blocks out of a model reply; every block maps to a replace op. Returns
/// null (caller falls back to the full-file path) if there is no well-formed block. Fail-closed: never a partial edit.
///   path/to/file.ext
///   <<<<<<< SEARCH
///   <exact original lines>
///   =======
///   <replacement lines>
///   >>>>>>> REPLACE
pub fn parseNarrated(gpa: std.mem.Allocator, reply: []const u8) ?Narrated {
    return parseNarratedSlot(gpa, reply, "");
}

/// True when a reply carries at least one SEARCH/REPLACE marker — i.e. it is edit narration, not a file body.
/// The full-file salvage uses this to refuse committing raw edit markers as a file's contents.
pub fn hasSearchReplace(reply: []const u8) bool {
    return std.mem.indexOf(u8, reply, "<<<<<<< SEARCH") != null;
}

/// Parse SEARCH/REPLACE blocks, preferring a path line detected in the reply but falling back to `slot` (the file
/// the engine already knows this mind is editing) when the model omitted the path line. With slot="" this is the
/// strict form: no detected path => null. Every block maps to a replace op. Fail-closed: never a partial edit.
pub fn parseNarratedSlot(gpa: std.mem.Allocator, reply: []const u8, slot: []const u8) ?Narrated {
    const S = "<<<<<<< SEARCH";
    const M = "\n=======";
    const R = "\n>>>>>>> REPLACE";
    const first = std.mem.indexOf(u8, reply, S) orelse return null;
    var path: []const u8 = "";
    {
        var lit = std.mem.splitScalar(u8, reply[0..first], '\n');
        while (lit.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            if (t.len == 0 or std.mem.startsWith(u8, t, "```")) continue;
            var tok_it = std.mem.tokenizeAny(u8, t, " \t");
            var last: []const u8 = "";
            while (tok_it.next()) |tok| last = tok;
            last = std.mem.trim(u8, last, "`*#>:,;\"'()");
            if (last.len > 0 and std.mem.indexOfScalar(u8, last, '.') != null) path = last;
        }
    }
    if (path.len == 0) path = slot; // recover a pathless edit against the file the engine assigned this mind
    if (path.len == 0) return null;

    var ops: std.ArrayListUnmanaged(EditOp) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, reply, pos, S)) |s| {
        const sl = (std.mem.indexOfScalarPos(u8, reply, s, '\n') orelse break) + 1;
        const m = std.mem.indexOfPos(u8, reply, sl, M) orelse break;
        const search = reply[sl..m];
        const rl = (std.mem.indexOfScalarPos(u8, reply, m + 1, '\n') orelse break) + 1;
        const r = std.mem.indexOfPos(u8, reply, rl, R) orelse break;
        const replace = reply[rl..r];
        ops.append(gpa, .{ .kind = .replace, .anchor = gpa.dupe(u8, search) catch "", .text = gpa.dupe(u8, replace) catch "" }) catch {};
        pos = r + R.len;
    }
    if (ops.items.len == 0) {
        ops.deinit(gpa);
        return null;
    }
    return .{ .path = gpa.dupe(u8, path) catch return null, .ops = ops.toOwnedSlice(gpa) catch return null };
}

/// The one physical line above and below an anchor's UNIQUE match in `haystack` — the anchor's line identity.
/// A rebase guard captures these against a mind's base, then re-checks them against current HEAD: if they differ,
/// the target moved or changed shape and the edit must NOT auto-merge. null when the anchor is not uniquely present.
pub const Brackets = struct { before: []u8 = "", after: []u8 = "" };
pub fn anchorBrackets(gpa: std.mem.Allocator, haystack: []const u8, anchor: []const u8) ?Brackets {
    if (anchor.len == 0) return null;
    const hlf = normalizeLF(gpa, haystack);
    defer gpa.free(hlf);
    var hlines = splitLines(gpa, hlf);
    defer hlines.deinit(gpa);
    const alf = normalizeLF(gpa, anchor);
    defer gpa.free(alf);
    var alines = splitLines(gpa, alf);
    defer alines.deinit(gpa);
    var start: usize = 0;
    var loose: bool = false;
    if (matchAnchor(hlines.items, alines.items, &start, &loose) != null) return null; // not found or ambiguous
    const before = if (start > 0) hlines.items[start - 1] else "";
    const after_idx = start + alines.items.len;
    const after = if (after_idx < hlines.items.len) hlines.items[after_idx] else "";
    return .{ .before = gpa.dupe(u8, before) catch @constCast(""), .after = gpa.dupe(u8, after) catch @constCast("") };
}
pub fn freeBrackets(gpa: std.mem.Allocator, b: Brackets) void {
    if (b.before.len > 0) gpa.free(b.before);
    if (b.after.len > 0) gpa.free(b.after);
}

pub fn freeNarrated(gpa: std.mem.Allocator, n: Narrated) void {
    for (n.ops) |op| {
        if (op.anchor.len > 0) gpa.free(@constCast(op.anchor));
        if (op.text.len > 0) gpa.free(@constCast(op.text));
    }
    gpa.free(n.ops);
    gpa.free(n.path);
}

// ---------------------------------------------------------------------------------------------------- tests
test "replace one line in a large buffer by anchor" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var i: usize = 0;
    while (i < 500) : (i += 1) buf.appendSlice(gpa, "  --filler: 0;\n") catch {};
    buf.appendSlice(gpa, "  --green: #00ff41;\n") catch {};
    while (i < 990) : (i += 1) buf.appendSlice(gpa, "  --more: 1;\n") catch {};
    const r = apply(gpa, buf.items, &.{.{ .kind = .replace, .anchor = "  --green: #00ff41;", .text = "  --green: #00e5ff;" }});
    defer if (r.ok) gpa.free(r.bytes) else gpa.free(r.reject);
    defer if (r.ok and r.loci.len > 0) gpa.free(r.loci);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.bytes, "#00e5ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.bytes, "#00ff41") == null);
    try std.testing.expect(std.mem.count(u8, r.bytes, "\n") == std.mem.count(u8, buf.items, "\n"));
}

test "insert after anchor + delete, applied together, offsets stay valid" {
    const gpa = std.testing.allocator;
    const src = "line1\nline2\nline3\nline4\n";
    const r = apply(gpa, src, &.{
        .{ .kind = .insert_after, .anchor = "line1", .text = "INSERTED" },
        .{ .kind = .delete, .anchor = "line3" },
    });
    defer if (r.ok) gpa.free(r.bytes) else gpa.free(r.reject);
    defer if (r.ok and r.loci.len > 0) gpa.free(r.loci);
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("line1\nINSERTED\nline2\nline4\n", r.bytes);
}

test "CRLF file: matched with LF anchor, dominant EOL restored" {
    const gpa = std.testing.allocator;
    const src = "a\r\nOLD\r\nb\r\n";
    const r = apply(gpa, src, &.{.{ .kind = .replace, .anchor = "OLD", .text = "NEW" }});
    defer if (r.ok) gpa.free(r.bytes) else gpa.free(r.reject);
    defer if (r.ok and r.loci.len > 0) gpa.free(r.loci);
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("a\r\nNEW\r\nb\r\n", r.bytes);
}

test "anchor not found and ambiguous both reject with no bytes" {
    const gpa = std.testing.allocator;
    const nf = apply(gpa, "a\nb\n", &.{.{ .kind = .replace, .anchor = "zzz", .text = "x" }});
    defer gpa.free(nf.reject);
    try std.testing.expect(!nf.ok and std.mem.indexOf(u8, nf.reject, "not found") != null);
    const am = apply(gpa, "dup\nmid\ndup\n", &.{.{ .kind = .replace, .anchor = "dup", .text = "x" }});
    defer gpa.free(am.reject);
    try std.testing.expect(!am.ok and std.mem.indexOf(u8, am.reject, "more than one") != null);
}

test "all-or-nothing: one bad op in a batch yields no bytes" {
    const gpa = std.testing.allocator;
    const r = apply(gpa, "a\nb\nc\n", &.{
        .{ .kind = .replace, .anchor = "a", .text = "A" },
        .{ .kind = .replace, .anchor = "nope", .text = "X" },
    });
    defer gpa.free(r.reject);
    try std.testing.expect(!r.ok);
}

test "leading-indent reindent is rescued when unique" {
    const gpa = std.testing.allocator;
    const src = "func {\n        return 1;\n}\n";
    const r = apply(gpa, src, &.{.{ .kind = .replace, .anchor = "    return 1;", .text = "        return 2;" }});
    defer if (r.ok) gpa.free(r.bytes) else gpa.free(r.reject);
    defer if (r.ok and r.loci.len > 0) gpa.free(r.loci);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.bytes, "return 2;") != null);
    // the replacement already carried the file's 8-space indent, so it is preserved exactly (not doubled)
    try std.testing.expectEqualStrings("func {\n        return 2;\n}\n", r.bytes);
}

test "loose match preserves the file's indentation when the model de-indents (single line)" {
    const gpa = std.testing.allocator;
    const src = "root {\n    --green: #00ff41;\n    --blue: #00f;\n}\n"; // file indents 4 spaces
    // model dropped the indent in BOTH the anchor and the replacement (the real gpt-oss failure)
    const r = apply(gpa, src, &.{.{ .kind = .replace, .anchor = "--green: #00ff41;", .text = "--green: #00e5ff;" }});
    defer if (r.ok) gpa.free(r.bytes) else gpa.free(r.reject);
    defer if (r.ok and r.loci.len > 0) gpa.free(r.loci);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.bytes, "    --green: #00e5ff;") != null); // 4-space indent kept
    try std.testing.expect(std.mem.indexOf(u8, r.bytes, "\n--green:") == null); // never a de-indented line
}

test "loose match reindents a multi-line replacement, preserving relative indent (python)" {
    const gpa = std.testing.allocator;
    const src = "class C:\n    def a(self):\n        return 1\n"; // def at 4, body at 8
    // model de-indented the whole block by 4 in both anchor and replacement
    const r = apply(gpa, src, &.{.{
        .kind = .replace,
        .anchor = "def a(self):\n    return 1",
        .text = "def a(self):\n    return 2",
    }});
    defer if (r.ok) gpa.free(r.bytes) else gpa.free(r.reject);
    defer if (r.ok and r.loci.len > 0) gpa.free(r.loci);
    try std.testing.expect(r.ok);
    // file base indent (4) restored on line 1, relative +4 preserved on the body → 8
    try std.testing.expectEqualStrings("class C:\n    def a(self):\n        return 2\n", r.bytes);
}

test "parseNarrated reads a SEARCH/REPLACE block" {
    const gpa = std.testing.allocator;
    const reply =
        "sure, here is the edit:\n\nassets/css/style.scss\n```scss\n<<<<<<< SEARCH\n  --green: #00ff41;\n=======\n  --green: #00e5ff;\n>>>>>>> REPLACE\n```\ndone\n";
    const n = parseNarrated(gpa, reply) orelse return error.NoParse;
    defer freeNarrated(gpa, n);
    try std.testing.expectEqualStrings("assets/css/style.scss", n.path);
    try std.testing.expect(n.ops.len == 1 and n.ops[0].kind == .replace);
    try std.testing.expectEqualStrings("  --green: #00ff41;", n.ops[0].anchor);
    try std.testing.expectEqualStrings("  --green: #00e5ff;", n.ops[0].text);
}

test "loci report post-splice byte offsets in op-index order" {
    const gpa = std.testing.allocator;
    const src = "L0\nL1\nL2\nL3\n";
    const r = apply(gpa, src, &.{
        .{ .kind = .insert_after, .anchor = "L0", .text = "NEW" }, // op 0 — lands at line 1
        .{ .kind = .replace, .anchor = "L3", .text = "X3" }, // op 1 — lands at final line 4
    });
    defer if (r.ok) gpa.free(r.bytes) else gpa.free(r.reject);
    defer if (r.ok and r.loci.len > 0) gpa.free(r.loci);
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("L0\nNEW\nL1\nL2\nX3\n", r.bytes);
    try std.testing.expect(r.loci.len == 2);
    // op 0 (insert_after L0) begins at byte 3 ("L0\n"); op 1 (replace L3) begins at byte 13, shifted down one
    // line by op 0's insert — proving loci track a match through a lower splice.
    try std.testing.expect(r.loci[0].op_index == 0 and r.loci[0].matched_offset == 3);
    try std.testing.expect(r.loci[1].op_index == 1 and r.loci[1].matched_offset == 13);
}

test "parseNarratedSlot recovers a pathless SEARCH/REPLACE against the assigned slot" {
    const gpa = std.testing.allocator;
    // the real failure: the model led straight with the SEARCH marker, no path line above it
    const reply = "<<<<<<< SEARCH\nfunction initMatrix() {}\n=======\nfunction initMatrix() { rain(); }\n>>>>>>> REPLACE\n";
    try std.testing.expect(hasSearchReplace(reply));
    try std.testing.expect(parseNarrated(gpa, reply) == null); // strict form: no path -> null (would leak to salvage)
    const n = parseNarratedSlot(gpa, reply, "app.js") orelse return error.NoParse;
    defer freeNarrated(gpa, n);
    try std.testing.expectEqualStrings("app.js", n.path);
    try std.testing.expect(n.ops.len == 1 and n.ops[0].kind == .replace);
    try std.testing.expectEqualStrings("function initMatrix() {}", n.ops[0].anchor);
    // a real path line still wins over the slot fallback
    const n2 = parseNarratedSlot(gpa, "lib/x.js\n<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE\n", "app.js") orelse return error.NoParse;
    defer freeNarrated(gpa, n2);
    try std.testing.expectEqualStrings("lib/x.js", n2.path);
}

test "anchorBrackets returns bracketing lines of a unique match; null when ambiguous" {
    const gpa = std.testing.allocator;
    {
        const bk = anchorBrackets(gpa, "a\nb\nTARGET\nc\nd\n", "TARGET") orelse return error.NoMatch;
        defer freeBrackets(gpa, bk);
        try std.testing.expectEqualStrings("b", bk.before);
        try std.testing.expectEqualStrings("c", bk.after);
    }
    try std.testing.expect(anchorBrackets(gpa, "x\nx\n", "x") == null); // ambiguous
    {
        const bk = anchorBrackets(gpa, "HEAD\nnext\n", "HEAD") orelse return error.NoMatch;
        defer freeBrackets(gpa, bk);
        try std.testing.expectEqualStrings("", bk.before); // top of file
        try std.testing.expectEqualStrings("next", bk.after);
    }
}

test "parseNarrated reads multiple SEARCH/REPLACE blocks with a multi-line anchor" {
    const gpa = std.testing.allocator;
    const reply =
        "path: src/app.js\n<<<<<<< SEARCH\nconst a = 1;\nconst b = 2;\n=======\nconst a = 10;\nconst b = 20;\n>>>>>>> REPLACE\n<<<<<<< SEARCH\nfoo();\n=======\nbar();\n>>>>>>> REPLACE\n";
    const n = parseNarrated(gpa, reply) orelse return error.NoParse;
    defer freeNarrated(gpa, n);
    try std.testing.expectEqualStrings("src/app.js", n.path);
    try std.testing.expect(n.ops.len == 2);
    try std.testing.expectEqualStrings("const a = 1;\nconst b = 2;", n.ops[0].anchor);
    try std.testing.expectEqualStrings("const a = 10;\nconst b = 20;", n.ops[0].text);
    try std.testing.expectEqualStrings("foo();", n.ops[1].anchor);
    try std.testing.expectEqualStrings("bar();", n.ops[1].text);
}
