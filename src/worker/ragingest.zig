//! LOCAL-FILE RAG INGEST — absorb an arbitrary text file (a book, a doc, notes, a dataset) into the
//! neuron-db knowledge hive as recallable facts, fully OFFLINE. No internet, no rag repo, no LLM: the
//! distillation is deterministic (the same clean-sentence extraction nl-rag's pack builder uses), so a
//! sealed machine can still turn "/path/to/book" into grounded recall.
//!
//! Pipeline: read text → paragraph-join (repairs hard-wrapped prose) → drop code/markup → split into
//! sentences → gate each (length, letter ratio, terminal punctuation) → dedup → tag `[<label>] <sentence>`
//! → write a temp `.facts` pack → `neuron import --dedup --flush <cap>` into the target scope. Every fact
//! then surfaces through the ordinary recall / recall_hive path, so the book is RAG-able like any pack.
//! Chapter/section headings survive as `[section]` marker facts (paging landmarks + summary skeleton),
//! and a document defaults into its OWN `<base>__doc-<slug>` sub-scope (see docScope) — the scope is the
//! document's identity, insertion order its document order.
//!
//! Exposed two ways: the `absorb` tool (a mind/chat says "absorb this file") and `veil rag ingest <path>`.

const std = @import("std");
const oscillation = @import("oscillation.zig");

pub const Stats = struct { facts: u32 = 0, stored: u32 = 0, evicted: u64 = 0, bytes_in: usize = 0 };

/// A scope-safe slug from a free-text label ("The Green Overcoat - Hilaire Belloc" → "the-green-overcoat-hilaire-belloc"):
/// lowercase alnum with single dashes, trimmed, capped at 40. "doc" fallback. Used to derive a document's
/// OWN sub-scope name, so the scope (not an in-band text tag) is the document's durable identity.
pub fn scopeSlug(label: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var dash_pending = false;
    for (label) |c| {
        if (n >= @min(buf.len, 40)) break;
        if (std.ascii.isAlphanumeric(c)) {
            if (dash_pending and n > 0) {
                buf[n] = '-';
                n += 1;
                if (n >= @min(buf.len, 40)) break;
            }
            buf[n] = std.ascii.toLower(c);
            n += 1;
            dash_pending = false;
        } else {
            dash_pending = true;
        }
    }
    const s = std.mem.trim(u8, buf[0..n], "-");
    return if (s.len == 0) "doc" else s;
}

/// The per-document sub-scope for a label under `base`: `<base>__doc-<slug>`. The `base__child`
/// convention is what neuron-db's across-recall merges, so a document filed here is reachable from
/// plain hive recall while never flooding (or being flooded by) the shared base scope.
pub fn docScope(base: []const u8, label: []const u8, buf: []u8) []const u8 {
    var sb: [48]u8 = undefined;
    const slug = scopeSlug(label, &sb);
    return std.fmt.bufPrint(buf, "{s}__doc-{s}", .{ base, slug }) catch base;
}

/// A short, filesystem-safe provenance label from a path's basename (drops the extension). "doc" fallback.
pub fn labelFromPath(path: []const u8, buf: []u8) []const u8 {
    var base = path;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| if (d > 0) {
        base = base[0..d];
    };
    var n: usize = 0;
    for (base) |c| {
        if (n >= buf.len) break;
        buf[n] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '-';
        n += 1;
    }
    const s = std.mem.trim(u8, buf[0..n], "-");
    return if (s.len == 0) "doc" else s;
}

/// The heading text of a heading-shaped paragraph (markdown `#`-runs, or CHAPTER/BOOK/PART-style
/// section openers), else null. Kept as `[section]` marker facts instead of being dropped: they are
/// the document's skeleton — chapter-aligned paging landmarks and the outline a summary hangs on.
fn headingText(p: []const u8) ?[]const u8 {
    const h = std.mem.trim(u8, p, " \t");
    if (h.len == 0 or h.len > 90) return null;
    if (h[0] == '#') {
        var i: usize = 0;
        while (i < h.len and h[i] == '#') i += 1;
        if (i > 6 or i >= h.len or h[i] != ' ') return null;
        const txt = std.mem.trim(u8, h[i..], " \t#");
        return if (txt.len >= 2) txt else null;
    }
    const openers = [_][]const u8{ "CHAPTER ", "Chapter ", "BOOK ", "PART ", "PROLOGUE", "EPILOGUE", "APPENDIX" };
    for (openers) |o| if (std.mem.startsWith(u8, h, o)) return h;
    return null;
}

fn structuralParagraph(p: []const u8) bool {
    const h = std.mem.trimStart(u8, p, " \t");
    if (h.len == 0) return true;
    switch (h[0]) {
        '#', '|', '>', '=', '`', '~', '+' => return true,
        '*', '-' => return h.len > 1 and (h[1] == ' ' or h[1] == '*' or h[1] == '-'), // list/bullet/rule, not a mid-sentence dash
        else => {},
    }
    // "1." / "12)" ordered-list openers
    var i: usize = 0;
    while (i < h.len and std.ascii.isDigit(h[i])) i += 1;
    if (i > 0 and i < h.len and (h[i] == '.' or h[i] == ')')) return true;
    return false;
}

fn goodSentence(s: []const u8) bool {
    // prose floor 16 (keeps short iconic sentences like "Call me Ishmael."); ceiling 400 for long literary
    // sentences. Narrower than nl-rag's 40..300 pack-fact window because a BOOK, not a doc page, is the input.
    if (s.len < 16 or s.len > 400) return false;
    if (!(s[s.len - 1] == '.' or s[s.len - 1] == '!' or s[s.len - 1] == '?')) return false;
    var letters: usize = 0;
    for (s) |c| {
        if (std.ascii.isAlphabetic(c) or c == ' ') letters += 1;
    }
    // mostly-letters filter rejects tables, code, numeric noise (nl-rag's 0.72 gate)
    return @as(f32, @floatFromInt(letters)) / @as(f32, @floatFromInt(s.len)) >= 0.72;
}

/// Collapse internal whitespace runs to single spaces, trimmed, into `out`. Returns the written slice.
fn collapseWs(out: []u8, in: []const u8) []const u8 {
    var n: usize = 0;
    var pend = false;
    for (in) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            pend = n > 0;
            continue;
        }
        if (pend and n < out.len) {
            out[n] = ' ';
            n += 1;
            pend = false;
        }
        if (n < out.len) {
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

/// Split a collapsed paragraph into sentence spans, handing each to the collector. A sentence ends at .!?
/// when the next non-space begins a new sentence (uppercase / quote / digit) or the paragraph ends.
fn eachSentence(col: *Collector, para: []const u8) void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < para.len) : (i += 1) {
        const c = para[i];
        if (c != '.' and c != '!' and c != '?') continue;
        // consume a run of terminal punctuation ("?!", "...")
        var j = i;
        while (j + 1 < para.len and (para[j + 1] == '.' or para[j + 1] == '!' or para[j + 1] == '?')) j += 1;
        const after = j + 1;
        if (after >= para.len) {
            col.take(std.mem.trim(u8, para[start..], " "));
            start = para.len;
            break;
        }
        if (para[after] == ' ') {
            var k = after;
            while (k < para.len and para[k] == ' ') k += 1;
            if (k >= para.len) break;
            const nx = para[k];
            // a real boundary: next sentence starts with a capital, quote, or digit — not "e.g. foo" / "3.5"
            if (std.ascii.isUpper(nx) or nx == '"' or nx == '\'' or nx == '(' or std.ascii.isDigit(nx)) {
                col.take(std.mem.trim(u8, para[start .. j + 1], " "));
                start = k;
                i = k - 1;
            }
        }
    }
    if (start < para.len) col.take(std.mem.trim(u8, para[start..], " "));
}

const Collector = struct {
    gpa: std.mem.Allocator,
    label: []const u8,
    cap: u32,
    body: *std.ArrayListUnmanaged(u8),
    seen: *std.StringHashMapUnmanaged(void),
    count: u32 = 0,
    scratch: [512]u8 = undefined,

    fn take(self: *Collector, raw: []const u8) void {
        if (self.count >= self.cap) return;
        const s = collapseWs(&self.scratch, raw);
        if (!goodSentence(s)) return;
        var lb: [512]u8 = undefined;
        const low = std.ascii.lowerString(lb[0..@min(s.len, lb.len)], s[0..@min(s.len, lb.len)]);
        if (self.seen.contains(low)) return;
        const key = self.gpa.dupe(u8, low) catch return;
        self.seen.put(self.gpa, key, {}) catch {
            self.gpa.free(key);
            return;
        };
        self.body.print(self.gpa, "[{s}] {s}\n", .{ self.label, s }) catch return;
        self.count += 1;
    }

    /// Emit a section-heading marker fact directly (bypasses the prose gate — a heading is short and
    /// unpunctuated by design). Counts against the cap like any fact.
    fn marker(self: *Collector, heading: []const u8) void {
        if (self.count >= self.cap) return;
        var hb: [160]u8 = undefined;
        const h = collapseWs(&hb, heading);
        if (h.len < 2) return;
        self.body.print(self.gpa, "[{s}] [section] {s}\n", .{ self.label, h }) catch return;
        self.count += 1;
    }
};

/// Distill raw text into a `.facts` pack body: one clean declarative sentence per line, provenance-tagged
/// `[<label>] <sentence>`, deduped, capped. Deterministic + offline. Caller frees the returned body.
pub fn distillToFacts(gpa: std.mem.Allocator, text: []const u8, label: []const u8, cap: u32) []u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(gpa);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    var col = Collector{ .gpa = gpa, .label = label, .cap = cap, .body = &body, .seen = &seen };

    // paragraph accumulation: blank line = break; a fenced code block is skipped whole
    var para: std.ArrayListUnmanaged(u8) = .empty;
    defer para.deinit(gpa);
    var in_fence = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (trimmed.len == 0) {
            flushPara(&col, &para);
            continue;
        }
        if (para.items.len > 0) para.append(gpa, ' ') catch {};
        para.appendSlice(gpa, line) catch {};
        if (col.count >= cap) break;
    }
    flushPara(&col, &para);
    return body.toOwnedSlice(gpa) catch @constCast("");
}

fn flushPara(col: *Collector, para: *std.ArrayListUnmanaged(u8)) void {
    defer para.clearRetainingCapacity();
    if (para.items.len == 0 or col.count >= col.cap) return;
    if (headingText(para.items)) |h| { col.marker(h); return; }   // keep the skeleton, before the markup drop
    if (structuralParagraph(para.items)) return;
    eachSentence(col, para.items);
}

/// Full ingest: distill `text`, write a temp pack beside `near_dir`, import into `scope` via the neuron
/// CLI (dedup + flush cap), delete the temp. Returns the facts distilled + facts actually stored.
pub fn ingestText(mem: oscillation.Mem, io: std.Io, gpa: std.mem.Allocator, near_dir: []const u8, text: []const u8, label: []const u8, scope: []const u8, cap: u32) Stats {
    var st = Stats{ .bytes_in = text.len };
    const body = distillToFacts(gpa, text, label, cap);
    defer gpa.free(body);
    if (body.len == 0) return st;
    st.facts = @intCast(std.mem.count(u8, body, "\n"));
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const pack = std.fmt.allocPrint(gpa, "{s}/.absorb-{s}.facts", .{ near_dir, std.fmt.bytesToHex(rnd, .lower) }) catch return st;
    defer gpa.free(pack);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pack, .data = body }) catch return st;
    defer std.Io.Dir.cwd().deleteFile(io, pack) catch {};
    // importStats, not import: "stored" counts writes, "evicted" counts what the scope's max_facts cap
    // front-drained during the load. A capped scope can report thousands stored and keep only the tail —
    // the caller's ack must be able to say so instead of claiming the document is fully recallable.
    const imp = mem.importStats(pack, scope, cap);
    st.stored = imp.stored;
    st.evicted = imp.evicted;
    return st;
}

// ------------------------------------------------------------------------------------------- tests

const t = std.testing;

test "labelFromPath: basename without extension, sanitized" {
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("moby-dick", labelFromPath("C:/books/moby-dick.txt", &b));
    try t.expectEqualStrings("notes", labelFromPath("/home/x/notes", &b));
    try t.expectEqualStrings("a-b-c", labelFromPath("a b c.md", &b));
}

test "distill: extracts clean sentences from wrapped prose, drops code and list markup" {
    const gpa = t.allocator;
    const text =
        \\# A Heading Kept As Skeleton
        \\
        \\Call me Ishmael. Some years ago—never mind how long
        \\precisely—having little or no money in my purse, I thought I
        \\would sail about a little and see the watery part of the world.
        \\
        \\```
        \\fn code() void { return; }
        \\```
        \\
        \\- a list item that is not a sentence
        \\
        \\It is a way I have of driving off the spleen and regulating the circulation.
    ;
    const body = distillToFacts(gpa, text, "book:moby", 100);
    defer gpa.free(body);
    // the wrapped opening sentences are rejoined and split correctly
    try t.expect(std.mem.indexOf(u8, body, "[book:moby] Call me Ishmael.") != null);
    try t.expect(std.mem.indexOf(u8, body, "see the watery part of the world.") != null);
    try t.expect(std.mem.indexOf(u8, body, "regulating the circulation.") != null);
    // a heading survives as a [section] MARKER (the document skeleton), never as a prose fact
    try t.expect(std.mem.indexOf(u8, body, "[book:moby] [section] A Heading Kept As Skeleton") != null);
    // code and bullets never become facts
    try t.expect(std.mem.indexOf(u8, body, "fn code") == null);
    try t.expect(std.mem.indexOf(u8, body, "list item") == null);
}

test "distill: CHAPTER-style openers become section markers in document order" {
    const gpa = t.allocator;
    const text =
        \\CHAPTER I.
        \\
        \\The professor walked into the cold night without his overcoat on.
        \\
        \\CHAPTER II.
        \\
        \\By morning the whole town had heard about the missing green coat.
    ;
    const body = distillToFacts(gpa, text, "b", 100);
    defer gpa.free(body);
    const c1 = std.mem.indexOf(u8, body, "[b] [section] CHAPTER I.").?;
    const s1 = std.mem.indexOf(u8, body, "cold night").?;
    const c2 = std.mem.indexOf(u8, body, "[b] [section] CHAPTER II.").?;
    const s2 = std.mem.indexOf(u8, body, "missing green coat").?;
    try t.expect(c1 < s1 and s1 < c2 and c2 < s2); // markers interleave in document order
}

test "scopeSlug + docScope derive a per-document sub-scope from a free-text label" {
    var b: [48]u8 = undefined;
    try t.expectEqualStrings("the-green-overcoat-hilaire-belloc", scopeSlug("The Green Overcoat - Hilaire Belloc", &b));
    try t.expectEqualStrings("doc", scopeSlug("!!!", &b));
    var sb: [96]u8 = undefined;
    try t.expectEqualStrings("knowledge__doc-notes-v2", docScope("knowledge", "Notes (v2)", &sb));
}

test "distill: dedup and cap hold" {
    const gpa = t.allocator;
    const text =
        \\This sentence is repeated to prove that duplicates are dropped cleanly.
        \\This sentence is repeated to prove that duplicates are dropped cleanly.
        \\A second distinct sentence exists here to make the count exactly two facts.
    ;
    const body = distillToFacts(gpa, text, "x", 100);
    defer gpa.free(body);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\n"));
    // cap clamps output
    const capped = distillToFacts(gpa, text, "x", 1);
    defer gpa.free(capped);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, capped, "\n"));
}

test "distill: a non-prose blob yields no facts (offline junk gate)" {
    const gpa = t.allocator;
    const text = "|col|col|\n|---|---|\n0xDEADBEEF 42 99 ;;; ### ---\n";
    const body = distillToFacts(gpa, text, "x", 100);
    defer gpa.free(body);
    try t.expectEqual(@as(usize, 0), body.len);
}
