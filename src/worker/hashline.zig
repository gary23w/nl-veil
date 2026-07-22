//! HASH-ANCHORED LINE EDITS — the edit addressing scheme that survives weak models and shared files.
//!
//! Text anchors ask a model to re-emit a code line byte-for-byte (models paraphrase; some local chat
//! templates even 500 on braces inside tool args). Bare line numbers drift the moment anyone else edits
//! the file. This scheme gives every line a short copyable tag the model quotes verbatim:
//!
//!     42:abc:rst→const x = load(path);
//!
//! `42` = 1-based line, `abc` = 3 letters of a 32-bit FNV-1a hash of the WHITESPACE-NORMALIZED line
//! (indent/trailing-ws changes don't invalidate; token changes do), `rst` = 3 letters of a fingerprint of
//! the fixed 8-line chunk containing the line (so edits NEAR the line surface as staleness too — an
//! anchor proves "the neighborhood I read is still there", which is exactly the guarantee a mind needs
//! when other minds edit the same file between its read and its edit).
//!
//! Batches are ATOMIC: every anchor validates against the current file before anything is spliced; one
//! stale anchor (or an overlapping range) rejects the whole batch. Every rejection carries FRESH anchors
//! for the failed region — and every success returns a fresh-anchor snippet of what changed — so the
//! model retries or continues immediately without re-reading the file. That closes the read→edit→re-read
//! loop that dominates multi-step build latency, and it turns concurrent-edit collisions into a
//! self-healing retry instead of a silent mis-splice.
//!
//! Special anchors: `0:` = start-of-file (insert_after it to prepend), `EOF` = end-of-file (append).
//! Pure library — no I/O; tools.zig owns reading/writing the file around applyBatch().

const std = @import("std");

pub const HASH_LEN = 3;
pub const CHUNK = 8; // lines per context-fingerprint chunk
pub const SEARCH_RADIUS = 15; // shifted-anchor recovery scan distance
pub const CTX_LINES = 5; // error context radius (rendered with fresh anchors)
pub const SNIPPET_CTX = 3; // success snippet radius

const FNV_OFFSET: u32 = 2_166_136_261;
const FNV_PRIME: u32 = 16_777_619;

/// FNV-1a over the whitespace-normalized line: leading/trailing ws dropped, internal runs collapsed to
/// one space. Reformatting a line doesn't move its anchor; changing a token does.
pub fn lineHash(line: []const u8) u32 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    var h: u32 = FNV_OFFSET;
    var pend_space = false;
    for (trimmed) |c| {
        if (c == ' ' or c == '\t') {
            pend_space = true;
            continue;
        }
        if (pend_space) {
            h = (h ^ ' ') *% FNV_PRIME;
            pend_space = false;
        }
        h = (h ^ c) *% FNV_PRIME;
    }
    return h;
}

pub fn encode(h: u32, out: *[HASH_LEN]u8) void {
    inline for (0..HASH_LEN) |i| out[i] = 'a' + @as(u8, @intCast((h >> (8 * i)) % 26));
}

/// Fingerprint of the fixed chunk [start, start+CHUNK) containing `idx` — line hashes mixed in order, so
/// any token change within the 8-line neighborhood changes the fingerprint.
pub fn chunkFp(lines: []const []const u8, idx: usize) u32 {
    var h: u32 = FNV_OFFSET;
    for ("chunk") |c| h = (h ^ c) *% FNV_PRIME;
    const start = (idx / CHUNK) * CHUNK;
    const end = @min(start + CHUNK, lines.len);
    var i = start;
    while (i < end) : (i += 1) {
        const lh = lineHash(lines[i]);
        inline for (0..4) |b| h = (h ^ @as(u8, @truncate(lh >> (8 * b)))) *% FNV_PRIME;
    }
    return h;
}

pub const Anchor = struct {
    line: u32, // 1-based; 0 = start-of-file sentinel
    local: [HASH_LEN]u8 = @splat('a'),
    ctx: [HASH_LEN]u8 = @splat('a'),
    has_ctx: bool = false,
    eof: bool = false,
    bof: bool = false,
};

/// Parse `42:abc:rst`, `42:abc`, `0:` (start), or `EOF` (end). Tolerates a copied `→content` /
/// `->content` suffix (models paste whole read lines). null = not an anchor at all — the caller treats
/// the string as a legacy text anchor instead.
pub fn parseAnchor(raw: []const u8) ?Anchor {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOf(u8, s, "\u{2192}")) |p| s = std.mem.trimEnd(u8, s[0..p], " \t");
    if (std.mem.indexOf(u8, s, "->")) |p| s = std.mem.trimEnd(u8, s[0..p], " \t");
    if (s.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(s, "EOF")) return .{ .line = 0, .eof = true };
    if (std.mem.eql(u8, s, "0:") or std.mem.eql(u8, s, "0")) return .{ .line = 0, .bof = true };
    const c1 = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    if (c1 == 0) return null;
    const line = std.fmt.parseInt(u32, s[0..c1], 10) catch return null;
    if (line == 0 or line > 50_000_000) return null;
    const rest = s[c1 + 1 ..];
    var a = Anchor{ .line = line };
    const c2 = std.mem.indexOfScalar(u8, rest, ':');
    const loc = if (c2) |p| rest[0..p] else rest;
    if (loc.len != HASH_LEN) return null;
    for (loc, 0..) |ch, i| {
        if (ch < 'a' or ch > 'z') return null;
        a.local[i] = ch;
    }
    if (c2) |p| {
        const cx = rest[p + 1 ..];
        if (cx.len != HASH_LEN) return null;
        for (cx, 0..) |ch, i| {
            if (ch < 'a' or ch > 'z') return null;
            a.ctx[i] = ch;
        }
        a.has_ctx = true;
    }
    return a;
}

/// True when the string is anchor-shaped (`N:abc[:def]`). `0:`/`EOF` alone are NOT enough — plain code
/// contains "EOF" — so batch-level dispatch requires at least one numbered anchor (tools.zig enforces).
pub fn isNumberedAnchor(s: []const u8) bool {
    const a = parseAnchor(s) orelse return false;
    return !a.eof and !a.bof;
}

pub fn renderAnchor(lines: []const []const u8, idx: usize, buf: *[24]u8) []const u8 {
    var loc: [HASH_LEN]u8 = undefined;
    encode(lineHash(lines[idx]), &loc);
    var cx: [HASH_LEN]u8 = undefined;
    encode(chunkFp(lines, idx), &cx);
    return std.fmt.bufPrint(buf, "{d}:{s}:{s}", .{ idx + 1, loc, cx }) catch unreachable;
}

/// The anchored read rendering: every line prefixed `N:abc:def→`. This is what makes anchors copyable —
/// the model never computes one, it only quotes what a read (or a previous edit result) handed it.
pub fn renderRead(gpa: std.mem.Allocator, content: []const u8) []u8 {
    var lines = splitLines(gpa, content) catch return gpa.dupe(u8, content) catch @constCast(content);
    defer lines.deinit(gpa);
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    var ab: [24]u8 = undefined;
    for (lines.items, 0..) |ln, i| {
        b.appendSlice(gpa, renderAnchor(lines.items, i, &ab)) catch break;
        b.appendSlice(gpa, "\u{2192}") catch break;
        b.appendSlice(gpa, ln) catch break;
        b.append(gpa, '\n') catch break;
    }
    return gpa.dupe(u8, b.items) catch gpa.dupe(u8, content) catch @constCast(content);
}

/// Split into lines, dropping the synthetic empty tail a trailing '\n' produces — line N in an anchor is
/// line N here. Slices borrow from `content`.
pub fn splitLines(gpa: std.mem.Allocator, content: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    if (content.len == 0) return out;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |ln| try out.append(gpa, std.mem.trimEnd(u8, ln, "\r"));
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0 and content[content.len - 1] == '\n')
        _ = out.pop();
    return out;
}

pub const Verdict = enum { valid, stale, out_of_range };

pub fn validate(lines: []const []const u8, a: Anchor) Verdict {
    if (a.eof or a.bof) return .valid;
    if (a.line == 0 or a.line > lines.len) return .out_of_range;
    const idx: usize = a.line - 1;
    var loc: [HASH_LEN]u8 = undefined;
    encode(lineHash(lines[idx]), &loc);
    if (!std.mem.eql(u8, &loc, &a.local)) return .stale;
    if (a.has_ctx) {
        var cx: [HASH_LEN]u8 = undefined;
        encode(chunkFp(lines, idx), &cx);
        if (!std.mem.eql(u8, &cx, &a.ctx)) return .stale;
    }
    return .valid;
}

const Shifted = struct { idx: ?usize, candidates: u32 };

/// A stale anchor often just MOVED (someone inserted lines above). Scan ±SEARCH_RADIUS for positions
/// where BOTH the line hash and the chunk fingerprint re-validate; exactly one such position is a safe
/// automatic recovery, several is ambiguity the model must resolve from the fresh context.
fn findShifted(lines: []const []const u8, a: Anchor) Shifted {
    if (a.eof or a.bof or a.line == 0) return .{ .idx = null, .candidates = 0 };
    const orig: i64 = @as(i64, a.line) - 1;
    var found: ?usize = null;
    var count: u32 = 0;
    var d: i64 = -@as(i64, SEARCH_RADIUS);
    while (d <= SEARCH_RADIUS) : (d += 1) {
        const i = orig + d;
        if (d == 0 or i < 0 or i >= lines.len) continue;
        const idx: usize = @intCast(i);
        var loc: [HASH_LEN]u8 = undefined;
        encode(lineHash(lines[idx]), &loc);
        if (!std.mem.eql(u8, &loc, &a.local)) continue;
        if (a.has_ctx) {
            var cx: [HASH_LEN]u8 = undefined;
            encode(chunkFp(lines, idx), &cx);
            if (!std.mem.eql(u8, &cx, &a.ctx)) continue;
        }
        count += 1;
        found = idx;
    }
    return .{ .idx = if (count == 1) found else null, .candidates = count };
}

pub const OpKind = enum { replace, insert_after, insert_before };
pub const Op = struct {
    kind: OpKind,
    anchor: Anchor,
    end_anchor: ?Anchor = null, // replace only: inclusive range end
    text: []const u8 = "", // empty replace text = delete
    raw_anchor: []const u8 = "", // what the model actually sent, for error echo
};

const Resolved = struct { op: usize, pos: usize, len: usize, text: []const u8 };

pub const Result = union(enum) { ok: Applied, err: []u8 };
pub const Applied = struct { content: []u8, summary: []u8 };

fn renderContext(gpa: std.mem.Allocator, b: *std.ArrayListUnmanaged(u8), lines: []const []const u8, center: usize, radius: usize) void {
    const lo = center -| radius;
    const hi = @min(lines.len, center + radius + 1);
    var ab: [24]u8 = undefined;
    var i = lo;
    while (i < hi) : (i += 1) {
        b.appendSlice(gpa, renderAnchor(lines, i, &ab)) catch return;
        b.appendSlice(gpa, "\u{2192}") catch return;
        b.appendSlice(gpa, lines[i]) catch return;
        b.append(gpa, '\n') catch return;
    }
}

fn anchorFail(gpa: std.mem.Allocator, lines: []const []const u8, op_i: usize, nops: usize, op: Op, verdict: Verdict) []u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    const sh = findShifted(lines, op.anchor);
    b.print(gpa, "edit {d}/{d}: anchor \"{s}\" ", .{ op_i + 1, nops, op.raw_anchor }) catch {};
    switch (verdict) {
        .out_of_range => b.print(gpa, "is out of range — the file has {d} lines.\n", .{lines.len}) catch {},
        else => {
            if (sh.idx) |ni| {
                var ab: [24]u8 = undefined;
                b.print(gpa, "is STALE at line {d}; the content moved to line {d}. Retry with anchor \"{s}\".\n", .{ op.anchor.line, ni + 1, renderAnchor(lines, ni, &ab) }) catch {};
            } else if (sh.candidates > 1) {
                b.print(gpa, "is STALE and matches {d} nearby lines — pick the right one from the fresh anchors below.\n", .{sh.candidates}) catch {};
            } else {
                b.print(gpa, "is STALE — that line changed since you read it.\n", .{}) catch {};
            }
        },
    }
    b.print(gpa, "This batch had {d} edit(s); NONE were applied. Retry the WHOLE batch using the fresh anchors below (do not reuse old anchors, do not re-read the file):\n", .{nops}) catch {};
    const center: usize = if (sh.idx) |ni| ni else if (op.anchor.line > 0 and op.anchor.line <= lines.len) op.anchor.line - 1 else if (lines.len > 0) lines.len - 1 else 0;
    if (lines.len > 0) renderContext(gpa, &b, lines, center, CTX_LINES);
    return gpa.dupe(u8, b.items) catch @constCast("edit failed: anchor stale (oom)");
}

/// Validate every op against `original`, then splice bottom-up. All-or-nothing: the first stale /
/// out-of-range anchor or overlapping range rejects the batch with a fresh-anchor report and the file
/// untouched. Success returns the new content plus a fresh-anchor snippet per edited region.
pub fn applyBatch(gpa: std.mem.Allocator, original: []const u8, ops: []const Op) Result {
    var lines = splitLines(gpa, original) catch return .{ .err = gpa.dupe(u8, "edit failed: oom") catch @constCast("oom") };
    defer lines.deinit(gpa);
    const L = lines.items;

    var resolved: std.ArrayListUnmanaged(Resolved) = .empty;
    defer resolved.deinit(gpa);
    for (ops, 0..) |op, oi| {
        const v1 = validate(L, op.anchor);
        if (v1 != .valid) return .{ .err = anchorFail(gpa, L, oi, ops.len, op, v1) };
        switch (op.kind) {
            .insert_after, .insert_before => {
                // insert index: after line N = N; before line N = N-1; sentinels land at the file's ends
                const pos: usize = if (op.anchor.eof) L.len else if (op.anchor.bof) 0 else if (op.kind == .insert_after) op.anchor.line else op.anchor.line - 1;
                resolved.append(gpa, .{ .op = oi, .pos = pos, .len = 0, .text = op.text }) catch return oom(gpa);
            },
            .replace => {
                if (op.anchor.eof or op.anchor.bof) {
                    var bad = op;
                    bad.anchor.line = 0;
                    return .{ .err = anchorFail(gpa, L, oi, ops.len, bad, .out_of_range) };
                }
                var end_idx: usize = op.anchor.line - 1;
                if (op.end_anchor) |ea| {
                    const v2 = validate(L, ea);
                    if (v2 != .valid) {
                        var e = op;
                        e.anchor = ea;
                        e.raw_anchor = op.raw_anchor;
                        return .{ .err = anchorFail(gpa, L, oi, ops.len, e, v2) };
                    }
                    if (ea.eof) {
                        end_idx = if (L.len > 0) L.len - 1 else 0;
                    } else end_idx = ea.line - 1;
                }
                const start_idx: usize = op.anchor.line - 1;
                if (end_idx < start_idx) return .{ .err = gpa.dupe(u8, "edit failed: end_anchor is above anchor — swap them and retry the whole batch") catch @constCast("range inverted") };
                resolved.append(gpa, .{ .op = oi, .pos = start_idx, .len = end_idx - start_idx + 1, .text = op.text }) catch return oom(gpa);
            },
        }
    }

    // overlap check on the ORIGINAL coordinates — overlapping splices silently corrupt
    for (resolved.items, 0..) |a, i| {
        for (resolved.items[i + 1 ..]) |c| {
            const a_end = a.pos + a.len;
            const c_end = c.pos + c.len;
            const disjoint = a_end <= c.pos or c_end <= a.pos;
            const both_insert_same = a.len == 0 and c.len == 0;
            if (!disjoint and !both_insert_same) {
                const msg = std.fmt.allocPrint(gpa, "edit failed: edits {d} and {d} touch overlapping line ranges. NONE of the {d} edits were applied — merge or separate them and retry the whole batch.", .{ a.op + 1, c.op + 1, ops.len }) catch return oom(gpa);
                return .{ .err = msg };
            }
        }
    }

    // splice bottom-up (ties: later op first, so equal-position inserts land in op order)
    std.mem.sort(Resolved, resolved.items, {}, struct {
        fn lt(_: void, x: Resolved, y: Resolved) bool {
            if (x.pos != y.pos) return x.pos > y.pos;
            return x.op > y.op;
        }
    }.lt);
    var work: std.ArrayListUnmanaged([]const u8) = .empty;
    defer work.deinit(gpa);
    work.appendSlice(gpa, L) catch return oom(gpa);
    for (resolved.items) |r| {
        var new_lines = splitLines(gpa, r.text) catch return oom(gpa);
        defer new_lines.deinit(gpa);
        work.replaceRange(gpa, r.pos, r.len, new_lines.items) catch return oom(gpa);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    for (work.items) |ln| {
        out.appendSlice(gpa, ln) catch return oom(gpa);
        out.append(gpa, '\n') catch return oom(gpa);
    }
    // preserve a no-trailing-newline original; everything else ends with '\n'
    if (out.items.len > 0 and original.len > 0 and original[original.len - 1] != '\n') _ = out.pop();

    // success summary: fresh anchors around each edited region (recomputed against the NEW lines)
    var sb: std.ArrayListUnmanaged(u8) = .empty;
    defer sb.deinit(gpa);
    sb.print(gpa, "applied {d} edit(s). Fresh anchors for the changed regions (valid for the file AS IT IS NOW — reuse these directly, no re-read needed):\n", .{ops.len}) catch {};
    // recompute positions top-down: walk resolved ops in ascending original pos, tracking line delta
    std.mem.sort(Resolved, resolved.items, {}, struct {
        fn lt(_: void, x: Resolved, y: Resolved) bool {
            if (x.pos != y.pos) return x.pos < y.pos;
            return x.op < y.op;
        }
    }.lt);
    var delta: i64 = 0;
    for (resolved.items) |r| {
        var nl = splitLines(gpa, r.text) catch continue;
        defer nl.deinit(gpa);
        const new_pos: usize = @intCast(@as(i64, @intCast(r.pos)) + delta);
        const center = @min(new_pos + (nl.items.len -| 1) / 2, work.items.len -| 1);
        if (work.items.len > 0) renderContext(gpa, &sb, work.items, center, SNIPPET_CTX);
        sb.print(gpa, "---\n", .{}) catch {};
        delta += @as(i64, @intCast(nl.items.len)) - @as(i64, @intCast(r.len));
    }
    const content = gpa.dupe(u8, out.items) catch return oom(gpa);
    const summary = gpa.dupe(u8, sb.items) catch {
        gpa.free(content);
        return oom(gpa);
    };
    return .{ .ok = .{ .content = content, .summary = summary } };
}

fn oom(gpa: std.mem.Allocator) Result {
    return .{ .err = gpa.dupe(u8, "edit failed: oom") catch @constCast("oom") };
}

// ------------------------------------------------------------------------------------------- tests

const t = std.testing;

test "line hash is whitespace-stable and token-sensitive" {
    var a: [HASH_LEN]u8 = undefined;
    var b: [HASH_LEN]u8 = undefined;
    encode(lineHash("  const x =  1;  "), &a);
    encode(lineHash("const x = 1;"), &b);
    try t.expectEqualSlices(u8, &a, &b);
    encode(lineHash("const x = 2;"), &b);
    try t.expect(!std.mem.eql(u8, &a, &b));
}

test "render → parse → validate round-trips; edits nearby invalidate via the chunk fingerprint" {
    const gpa = t.allocator;
    const src = "a();\nb();\nc();\nd();\ne();\n";
    var lines = try splitLines(gpa, src);
    defer lines.deinit(gpa);
    var ab: [24]u8 = undefined;
    const s = renderAnchor(lines.items, 2, &ab);
    const a = parseAnchor(s).?;
    try t.expectEqual(Verdict.valid, validate(lines.items, a));
    // a change to a NEIGHBOR (same 8-line chunk) makes the anchor stale even though line 3 is intact
    var lines2 = try splitLines(gpa, "a();\nCHANGED();\nc();\nd();\ne();\n");
    defer lines2.deinit(gpa);
    try t.expectEqual(Verdict.stale, validate(lines2.items, a));
    // the copied-content suffix is tolerated
    try t.expect(parseAnchor("3:abc:def\u{2192}c();") != null);
    try t.expect(parseAnchor("EOF") != null);
    try t.expect(parseAnchor("not an anchor") == null);
}

test "applyBatch: replace + range delete + inserts, bottom-up, trailing newline preserved" {
    const gpa = t.allocator;
    const src = "one\ntwo\nthree\nfour\nfive\n";
    var lines = try splitLines(gpa, src);
    defer lines.deinit(gpa);
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    const a2 = parseAnchor(renderAnchor(lines.items, 1, &b1)).?; // "two"
    const a3 = parseAnchor(renderAnchor(lines.items, 2, &b2)).?; // "three"
    const a4 = parseAnchor(renderAnchor(lines.items, 3, &b3)).?; // "four"
    const ops = [_]Op{
        .{ .kind = .replace, .anchor = a2, .text = "TWO\nTWO-B", .raw_anchor = "a2" },
        .{ .kind = .replace, .anchor = a3, .end_anchor = a4, .text = "", .raw_anchor = "a3" }, // delete three..four
        .{ .kind = .insert_after, .anchor = .{ .line = 0, .bof = true }, .text = "zero", .raw_anchor = "0:" },
        .{ .kind = .insert_after, .anchor = .{ .line = 0, .eof = true }, .text = "six", .raw_anchor = "EOF" },
    };
    switch (applyBatch(gpa, src, ops[0..])) {
        .ok => |ap| {
            defer gpa.free(ap.content);
            defer gpa.free(ap.summary);
            try t.expectEqualStrings("zero\none\nTWO\nTWO-B\nfive\nsix\n", ap.content);
            try t.expect(std.mem.indexOf(u8, ap.summary, "Fresh anchors") != null);
        },
        .err => |e| {
            defer gpa.free(e);
            return error.TestUnexpectedResult;
        },
    }
}

test "applyBatch is atomic: one stale anchor rejects everything and hands back fresh anchors" {
    const gpa = t.allocator;
    const src = "alpha\nbeta\ngamma\n";
    var lines = try splitLines(gpa, src);
    defer lines.deinit(gpa);
    var b1: [24]u8 = undefined;
    const good = parseAnchor(renderAnchor(lines.items, 0, &b1)).?;
    var stale = good;
    stale.line = 2; // right hashes, wrong line → stale
    const ops = [_]Op{
        .{ .kind = .replace, .anchor = good, .text = "ALPHA", .raw_anchor = "1:xxx:yyy" },
        .{ .kind = .replace, .anchor = stale, .text = "BETA", .raw_anchor = "2:xxx:yyy" },
    };
    switch (applyBatch(gpa, src, ops[0..])) {
        .ok => |ap| {
            gpa.free(ap.content);
            gpa.free(ap.summary);
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            defer gpa.free(e);
            try t.expect(std.mem.indexOf(u8, e, "NONE were applied") != null);
            try t.expect(std.mem.indexOf(u8, e, "\u{2192}") != null); // fresh anchors present
        },
    }
}

test "shifted-anchor recovery names the new line when content moved by a chunk-aligned insert" {
    const gpa = t.allocator;
    // 24 lines; target = idx 20 (chunk 2). Insert exactly 8 lines at the top: chunks realign, target
    // is now idx 28 with an IDENTICAL chunk fingerprint — the one safe automatic recovery.
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(gpa);
    for (0..24) |i| src.print(gpa, "line-{d}\n", .{i}) catch {};
    var lines = try splitLines(gpa, src.items);
    defer lines.deinit(gpa);
    var ab: [24]u8 = undefined;
    const a = parseAnchor(renderAnchor(lines.items, 20, &ab)).?;
    var moved: std.ArrayListUnmanaged(u8) = .empty;
    defer moved.deinit(gpa);
    for (0..8) |i| moved.print(gpa, "pad-{d}\n", .{i}) catch {};
    moved.appendSlice(gpa, src.items) catch {};
    const ops = [_]Op{.{ .kind = .replace, .anchor = a, .text = "X", .raw_anchor = "21:...:..." }};
    switch (applyBatch(gpa, moved.items, ops[0..])) {
        .ok => |ap| {
            gpa.free(ap.content);
            gpa.free(ap.summary);
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            defer gpa.free(e);
            try t.expect(std.mem.indexOf(u8, e, "moved to line 29") != null);
        },
    }
}

test "overlapping ranges reject atomically; empty file accepts only inserts" {
    const gpa = t.allocator;
    const src = "a\nb\nc\nd\n";
    var lines = try splitLines(gpa, src);
    defer lines.deinit(gpa);
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    const a1 = parseAnchor(renderAnchor(lines.items, 0, &b1)).?;
    const a3 = parseAnchor(renderAnchor(lines.items, 2, &b2)).?;
    const a2 = parseAnchor(renderAnchor(lines.items, 1, &b3)).?;
    const ops = [_]Op{
        .{ .kind = .replace, .anchor = a1, .end_anchor = a3, .text = "X", .raw_anchor = "r1" },
        .{ .kind = .replace, .anchor = a2, .text = "Y", .raw_anchor = "r2" },
    };
    switch (applyBatch(gpa, src, ops[0..])) {
        .ok => |ap| {
            gpa.free(ap.content);
            gpa.free(ap.summary);
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            defer gpa.free(e);
            try t.expect(std.mem.indexOf(u8, e, "overlapping") != null);
        },
    }
    const ins = [_]Op{.{ .kind = .insert_after, .anchor = .{ .line = 0, .bof = true }, .text = "first", .raw_anchor = "0:" }};
    switch (applyBatch(gpa, "", ins[0..])) {
        .ok => |ap| {
            defer gpa.free(ap.content);
            defer gpa.free(ap.summary);
            try t.expectEqualStrings("first\n", ap.content);
        },
        .err => |e| {
            defer gpa.free(e);
            return error.TestUnexpectedResult;
        },
    }
}
