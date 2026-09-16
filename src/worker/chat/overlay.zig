//! overlay.zig — the RECALL OVERLAY: memory settled around every thought.
//!
//! Recall used to happen at two seams of a turn: once at the start, keyed on the goal, and once per synthetic
//! drive step, keyed on the step text. The reasoning rounds in between — the tool calls, the readings, the
//! decisions, which is where a long turn actually lives — saw the blocks assembled at turn start and nothing
//! else. A round that needed a finding from twenty rounds earlier, a durable note, or the fact that a file
//! already existed had no memory of its own: once the working span was compacted the finding survived only in
//! neuron-db, which nothing consulted until the next drive step, and the model re-did the work (observed on a
//! long research-and-write turn: three compactions, the site conventions re-read after each one).
//!
//! The overlay is a per-turn WORKING FIELD (hyperspace.Field: a bounded in-RAM set of facts settled by
//! spreading activation around a focus — the swarm's Lever 2, which the chat engine never used) that is:
//!   * SEEDED once at turn start — the conversation's own store partition (one bulk pull, the only subprocess
//!     the overlay spends per turn), the user's durable memory lines exactly as the prompt shows them (credential
//!     values already masked; the block's header and footer are framing, not facts), and the file ledger;
//!   * GROWN in-process as the turn produces findings — every tool-result note the engine mints for the store
//!     enters the field the moment it exists, so a finding is recallable in the very next round, compaction or
//!     not, and no subprocess is spent;
//!   * SETTLED before EVERY round's chat-model call (runInnerAgentic's streamed call; the auxiliary verdict,
//!     compaction and planning calls go without it) around a live CUE — the goal, the model's last narration,
//!     its last tool call, the last result, and the facts it most recently used — so the associative wave runs
//!     from what the model is doing right now, not from what the user asked at the top of the turn;
//!   * RENDERED as one small advisory block appended as the LAST message of that one request and removed from
//!     the working context the instant the model has answered. An overlay in the literal sense: it never enters
//!     the transcript, is never observed, never compacted, never re-uploaded on a later round.
//!
//! MEMORIES ARE ADVISORY. The block says so, and the engine behaves so: nothing in it is a task, an instruction
//! or a deliverable; the model may use or ignore any line, and a tool result outranks all of them. The choice is
//! respected MECHANICALLY, not only in prose — that is the refractory rule: a line shown for REFRACTORY
//! consecutive renders that the model never picked up is inhibited for INHIBIT renders, so the overlay rotates
//! what it offers instead of insisting. A line the model DID use — its distinctive stems appear in the next
//! narration or tool call, "firing" — has its streak reset, feeds the next cue (the link that carries value from
//! one firing to the next), and is queued to be STRENGTHENED in the store at turn end: the Hebbian half, so a
//! fact that helped ranks higher in every later recall.
//!
//! LOOPS ARE IMPOSSIBLE BY CONSTRUCTION, not by policy:
//!   * a rendering is never fed to the field, the store, or the cue — the field cannot recall its own output,
//!     so there is nothing to amplify (a thought is a cue, never a fact: only engine-observed findings enter);
//!   * the cue is built from engine-held strings (goal, narration, call, result, fired facts), never from the
//!     working context, so one block cannot seed the next;
//!   * every render is bounded by fixed numbers — the field's cap, the settle passes, the byte budget, the
//!     per-turn caps on fired and strengthened facts — and spends ZERO subprocesses (pinned by a test);
//!   * inhibition can only REMOVE lines; nothing here can grow the transcript or the store on its own.
//!
//! Polymorphic over sources: a fact is text plus a source tag rendered beside it ([conv], [durable], [ledger],
//! [found], [anchor]); the tag never enters the stems, so provenance cannot fuse unrelated facts into a hub.

const std = @import("std");
const hs = @import("../hyperspace.zig");
const osc = @import("../oscillation.zig");

/// Field size: how many facts the turn's working memory holds (~300 B each; a settle is O(N²) over ≤24 stems).
pub const DEFAULT_CAP: usize = 256;
/// Bytes of rendered lines per overlay; the header rides on top.
pub const DEFAULT_BUDGET: usize = 900;
/// Renders a line may be shown, unused, before it is inhibited.
pub const REFRACTORY: u8 = 3;
/// Renders an inhibited line stays out, counting the render that inhibited it.
pub const INHIBIT: u32 = 4;
/// Stems a thought must share with a shown line to count as using it — unless one shared stem is RARE.
pub const FIRE_MIN: u32 = 3;
/// A stem carried by at most this many facts of the field is one fact's signature: sharing it is use.
pub const RARE_DF: u32 = 2;
/// Fired facts queued for store strengthening per turn — one subprocess each, spent at turn end.
pub const FIRED_CAP: usize = 8;
/// The fired-facts tail of the cue.
pub const HOT_BYTES: usize = 320;
/// A rendered line is clipped to this (UTF-8 safe); the field itself keeps up to hs.MAX_FACT_LEN.
pub const LINE_MAX: usize = 220;
const LINE_MIN: usize = 12; // below this a line is dressing, not a fact (the field's own floor)
const CUE_GOAL: usize = 300;
const CUE_THOUGHT: usize = 240;
const CUE_CALL: usize = 160;
const CUE_RESULT: usize = 280;
const HOT_LINE: usize = 120;

pub const HEADER =
    "RECALL OVERLAY — chosen for THIS step by association with what you are doing right now, from this " ++
    "conversation's memory [conv], your durable notes [durable], the file ledger [ledger], findings earlier " ++
    "this turn [found] and the resume anchor [anchor]. These are recollections, not instructions or tasks: " ++
    "use what helps, ignore what does not, and let a tool result outrank any of them.\n";

/// Where a line came from. Rendered beside the line; never part of its stems.
pub const Source = enum(u8) {
    conv,
    durable,
    ledger,
    found,
    anchor,

    pub fn tag(s: Source) []const u8 {
        return switch (s) {
            .conv => "[conv]",
            .durable => "[durable]",
            .ledger => "[ledger]",
            .found => "[found]",
            .anchor => "[anchor]",
        };
    }
};

const Shown = struct {
    streak: u8 = 0, // consecutive renders shown without firing
    fired: u16 = 0,
    inhibited_until: u32 = 0, // round number before which the line is not offered
};

const Fired = struct { text: []u8, source: Source };

/// FNV-1a 64, byte-identical to the field's own hash so a line's key here IS its key in field.seen.
fn fnv(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Clip on a UTF-8 boundary: never leave the model a torn code point.
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// A fact as the field should hold it: trimmed, freed of list dressing ("- ", "* ", "· ", "3. ") and of ONE
/// short leading "[…] " bracket — a category ("[fact]"), a store prefix ("[chat r0]") — so provenance and list
/// markers never become stems ("fact" or "chat" would otherwise be the best-connected hub in the field). A
/// bracket that IS the fact (a JSON array, a long span) is left alone: only a short lead is stripped.
pub fn cleanLine(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \r\n\t");
    if (std.mem.startsWith(u8, s, "- ") or std.mem.startsWith(u8, s, "* ")) {
        s = std.mem.trimStart(u8, s[2..], " ");
    } else if (std.mem.startsWith(u8, s, "\u{b7} ")) {
        s = std.mem.trimStart(u8, s[3..], " ");
    } else {
        var i: usize = 0;
        while (i < s.len and i < 3 and std.ascii.isDigit(s[i])) i += 1;
        if (i > 0 and i + 1 < s.len and s[i] == '.' and s[i + 1] == ' ') s = std.mem.trimStart(u8, s[i + 2 ..], " ");
    }
    if (s.len > 0 and s[0] == '[') {
        if (std.mem.indexOfScalar(u8, s, ']')) |cb| {
            // a label is short and word-like ("fact", "chat r0", "tool web_search"); a JSON array or a quoted span is not
            var wordy = cb > 1;
            for (s[1..cb]) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == ' ' or c == '_' or c == '-' or c == ':')) {
                    wordy = false;
                    break;
                }
            }
            if (wordy and cb <= 24 and cb + 1 < s.len and s[cb + 1] == ' ') s = std.mem.trimStart(u8, s[cb + 1 ..], " ");
        }
    }
    return s;
}

pub const Overlay = struct {
    gpa: std.mem.Allocator,
    field: hs.Field,
    tags: std.AutoHashMapUnmanaged(u64, Source) = .empty,
    shown: std.AutoHashMapUnmanaged(u64, Shown) = .empty,
    picks: std.ArrayListUnmanaged(u64) = .empty, // keys of the lines in the last rendering
    fired: std.ArrayListUnmanaged(Fired) = .empty, // owned texts, deduped, capped at FIRED_CAP
    goal: []u8 = &[_]u8{},
    thought: []u8 = &[_]u8{},
    call: []u8 = &[_]u8{},
    result: []u8 = &[_]u8{},
    hot: std.ArrayListUnmanaged(u8) = .empty, // the texts of recently fired lines, newest last
    budget: usize = DEFAULT_BUDGET,
    round: u32 = 0,
    // the turn's accounting, logged at turn end
    renders: u32 = 0,
    lines_shown: u32 = 0,
    fired_total: u32 = 0,
    inhibited_total: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, cap: usize) Overlay {
        var f = hs.Field.init(gpa);
        f.cap = std.math.clamp(cap, hs.MIN_FACTS, hs.MAX_FACTS_CAP);
        return .{ .gpa = gpa, .field = f };
    }

    pub fn deinit(self: *Overlay) void {
        self.field.deinit();
        self.tags.deinit(self.gpa);
        self.shown.deinit(self.gpa);
        self.picks.deinit(self.gpa);
        for (self.fired.items) |f| self.gpa.free(f.text);
        self.fired.deinit(self.gpa);
        if (self.goal.len > 0) self.gpa.free(self.goal);
        if (self.thought.len > 0) self.gpa.free(self.thought);
        if (self.call.len > 0) self.gpa.free(self.call);
        if (self.result.len > 0) self.gpa.free(self.result);
        self.hot.deinit(self.gpa);
    }

    fn setStr(self: *Overlay, slot: *[]u8, text: []const u8, cap: usize) void {
        const t = std.mem.trim(u8, text, " \r\n\t");
        const dup = self.gpa.dupe(u8, clipUtf8(t, cap)) catch return;
        if (slot.len > 0) self.gpa.free(slot.*);
        slot.* = dup;
    }

    /// The turn's goal: the steady head of every cue.
    pub fn setGoal(self: *Overlay, text: []const u8) void {
        self.setStr(&self.goal, text, CUE_GOAL);
    }
    /// What the model last said (its narration, or the step it was handed): a cue fragment, never a fact.
    pub fn noteThought(self: *Overlay, text: []const u8) void {
        self.setStr(&self.thought, text, CUE_THOUGHT);
    }
    /// The tool call the model just made: a cue fragment.
    pub fn noteCall(self: *Overlay, name: []const u8, args: []const u8) void {
        var buf: [CUE_CALL + 8]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, "{s} {s}", .{ name, clipUtf8(args, CUE_CALL) }) catch name;
        self.setStr(&self.call, joined, CUE_CALL);
    }
    /// The head of the result the model is about to read: a cue fragment.
    pub fn noteResult(self: *Overlay, text: []const u8) void {
        self.setStr(&self.result, text, CUE_RESULT);
    }

    /// Fold a newline-joined block into the field under one source tag. Returns the lines admitted (new).
    pub fn seedBlock(self: *Overlay, block: []const u8, source: Source) u32 {
        var n: u32 = 0;
        var it = std.mem.splitScalar(u8, block, '\n');
        while (it.next()) |raw| {
            if (self.absorb(raw, source)) n += 1;
        }
        return n;
    }

    /// One engine-observed finding, the moment it exists — the same note memBank stores at turn end.
    pub fn noteFinding(self: *Overlay, text: []const u8) void {
        _ = self.absorb(text, .found);
    }

    fn absorb(self: *Overlay, raw: []const u8, source: Source) bool {
        const line = cleanLine(raw);
        if (line.len < LINE_MIN) return false;
        const before = self.field.facts.items.len;
        self.field.observeLine(line);
        const stored = line[0..@min(line.len, hs.MAX_FACT_LEN)]; // the field's own cap — its key is fnv(stored)
        const key = fnv(stored);
        if (!self.field.seen.contains(key)) return false; // dropped by the field (no stems)
        self.tags.put(self.gpa, key, source) catch {};
        return self.field.facts.items.len > before;
    }

    fn findFact(self: *const Overlay, key: u64) ?usize {
        for (self.field.facts.items, 0..) |f, i| {
            if (fnv(f.text) == key) return i;
        }
        return null;
    }

    fn buildCue(self: *const Overlay) ?[]u8 {
        var cue: std.ArrayListUnmanaged(u8) = .empty;
        defer cue.deinit(self.gpa);
        for ([_][]const u8{ self.goal, self.thought, self.call, self.result, self.hot.items }) |part| {
            if (part.len == 0) continue;
            cue.appendSlice(self.gpa, part) catch return null;
            cue.append(self.gpa, '\n') catch return null;
        }
        if (cue.items.len == 0) return null;
        return cue.toOwnedSlice(self.gpa) catch null;
    }

    /// Settle the field around the live cue and render the advisory block for ONE inference, or null when there
    /// is nothing worth offering. Applies the refractory rule and records what was offered so a later
    /// observeFiring can tell use from neglect. Spends no subprocess.
    pub fn render(self: *Overlay) ?[]u8 {
        self.round += 1;
        if (self.field.facts.items.len == 0) return null;
        const cue = self.buildCue() orelse return null;
        defer self.gpa.free(cue);
        const dense = self.field.pack(cue, self.budget * 2); // over-pack, then filter and fit
        defer self.gpa.free(dense);
        if (dense.len == 0) return null;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, HEADER) catch return null;
        var new_picks: std.ArrayListUnmanaged(u64) = .empty;
        defer new_picks.deinit(self.gpa);
        var used: usize = 0;
        var it = std.mem.splitScalar(u8, dense, '\n');
        while (it.next()) |ln| {
            if (ln.len < LINE_MIN) continue;
            const key = fnv(ln); // pack emits the stored text verbatim, so this is the field's key
            const gop = self.shown.getOrPut(self.gpa, key) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const st = gop.value_ptr;
            if (st.inhibited_until > self.round) continue;
            const tag = (self.tags.get(key) orelse Source.conv).tag();
            const shown_line = clipUtf8(ln, LINE_MAX);
            const need = "\u{b7} ".len + tag.len + 1 + shown_line.len + 1;
            if (used + need > self.budget) continue; // keep trying smaller lines
            if (st.streak >= REFRACTORY) {
                // offered REFRACTORY times, never used: the model's choice — stop insisting for a while
                st.inhibited_until = self.round + INHIBIT;
                st.streak = 0;
                self.inhibited_total += 1;
                continue;
            }
            st.streak += 1;
            out.appendSlice(self.gpa, "\u{b7} ") catch return null;
            out.appendSlice(self.gpa, tag) catch return null;
            out.append(self.gpa, ' ') catch return null;
            out.appendSlice(self.gpa, shown_line) catch return null;
            out.append(self.gpa, '\n') catch return null;
            used += need;
            new_picks.append(self.gpa, key) catch {};
        }
        // a line that simply fell out of the pack this round is not being ignored: its streak restarts
        for (self.picks.items) |old| {
            var still = false;
            for (new_picks.items) |k| {
                if (k == old) {
                    still = true;
                    break;
                }
            }
            if (!still) if (self.shown.getPtr(old)) |st| {
                st.streak = 0;
            };
        }
        if (new_picks.items.len == 0) return null;
        self.picks.clearRetainingCapacity();
        self.picks.appendSlice(self.gpa, new_picks.items) catch {};
        self.renders += 1;
        self.lines_shown +|= @intCast(new_picks.items.len);
        return out.toOwnedSlice(self.gpa) catch null;
    }

    /// The firing half. `text` is what the model produced right after the last rendering — its narration or a
    /// tool call's arguments. A shown line whose distinctive stems appear in it has been USED: its streak
    /// resets, it is un-inhibited, its text joins the hot tail of the next cue, and it is queued for the store.
    /// Distinctive means RARE in the field (a stem few facts carry) or at least FIRE_MIN shared stems, so the
    /// common vocabulary of a task ("file", "write") cannot fire everything at once. Returns the lines fired.
    pub fn observeFiring(self: *Overlay, text: []const u8) u32 {
        if (self.picks.items.len == 0) return 0;
        const t = std.mem.trim(u8, text, " \r\n\t");
        if (t.len < 8) return 0;
        const ts = hs.stemHashes(self.gpa, t);
        defer self.gpa.free(ts);
        if (ts.len == 0) return 0;
        // document frequency of every stem across the field: a stem few facts carry is one fact's signature
        var df: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer df.deinit(self.gpa);
        for (self.field.facts.items) |f| {
            for (f.stems) |s| {
                const gop = df.getOrPut(self.gpa, s) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
        var n: u32 = 0;
        for (self.picks.items) |key| {
            const fi = self.findFact(key) orelse continue;
            const f = self.field.facts.items[fi];
            var all: u32 = 0;
            var rare: u32 = 0;
            var i: usize = 0;
            var j: usize = 0;
            while (i < f.stems.len and j < ts.len) {
                if (f.stems[i] == ts[j]) {
                    all += 1;
                    if ((df.get(f.stems[i]) orelse 0) <= RARE_DF) rare += 1;
                    i += 1;
                    j += 1;
                } else if (f.stems[i] < ts[j]) {
                    i += 1;
                } else {
                    j += 1;
                }
            }
            if (rare == 0 and all < FIRE_MIN) continue;
            n += 1;
            if (self.shown.getPtr(key)) |st| {
                st.streak = 0;
                st.fired +|= 1;
                st.inhibited_until = 0;
            }
            self.pushHot(f.text);
            self.queueFired(key, f.text);
        }
        self.fired_total += n;
        return n;
    }

    fn pushHot(self: *Overlay, text: []const u8) void {
        const line = clipUtf8(text, HOT_LINE);
        if (std.mem.indexOf(u8, self.hot.items, line) != null) return;
        self.hot.appendSlice(self.gpa, line) catch return;
        self.hot.append(self.gpa, '\n') catch return;
        if (self.hot.items.len > HOT_BYTES) {
            // drop whole oldest lines until the tail fits — newest firings stay
            const keep_from = self.hot.items.len - HOT_BYTES;
            const cut = (std.mem.indexOfScalarPos(u8, self.hot.items, keep_from, '\n') orelse (self.hot.items.len - 1)) + 1;
            const rest = self.hot.items.len - cut;
            std.mem.copyForwards(u8, self.hot.items[0..rest], self.hot.items[cut..]);
            self.hot.shrinkRetainingCapacity(rest);
        }
    }

    fn queueFired(self: *Overlay, key: u64, text: []const u8) void {
        if (self.fired.items.len >= FIRED_CAP) return;
        for (self.fired.items) |f| {
            if (std.mem.eql(u8, f.text, text)) return;
        }
        const dup = self.gpa.dupe(u8, text) catch return;
        self.fired.append(self.gpa, .{ .text = dup, .source = self.tags.get(key) orelse .conv }) catch self.gpa.free(dup);
    }

    /// The Hebbian half, spent at turn end: every fired STORE-BACKED line ([conv]) is strengthened in the
    /// conversation's partition so it ranks higher in every later recall — at most FIRED_CAP subprocesses, off
    /// the hot path. Durable notes, the ledger and this turn's own findings are not in that partition (the
    /// findings reach it in the same turn-exit flush) and are skipped. Returns the count strengthened.
    pub fn strengthenFired(self: *Overlay, mem: osc.Mem, scope: []const u8) u32 {
        var n: u32 = 0;
        for (self.fired.items) |f| {
            if (f.source != .conv) continue;
            const m = std.mem.trim(u8, clipUtf8(f.text, 48), " \r\n\t");
            if (m.len < 8) continue;
            mem.strengthen(scope, m);
            n += 1;
        }
        return n;
    }
};

test "the overlay cannot recall its own rendering: a render adds no fact, and a thought never enters the field" {
    const gpa = std.testing.allocator;
    var o = Overlay.init(gpa, 64);
    defer o.deinit();
    o.setGoal("write the spire cgroup spoofing post for garrettstimpson.ca");
    _ = o.seedBlock("the site is a Jekyll blog: posts live in _posts with front matter and an excerpt under 160 chars\n" ++
        "tool web_fetch spire cgroup spoofing: the article explains node attestation via cgroup paths\n", .conv);
    const n0 = o.field.facts.items.len;
    try std.testing.expectEqual(@as(usize, 2), n0);
    const blk = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(blk);
    try std.testing.expect(std.mem.startsWith(u8, blk, HEADER));
    try std.testing.expect(std.mem.indexOf(u8, blk, "[conv] the site is a Jekyll blog") != null);
    try std.testing.expectEqual(n0, o.field.facts.items.len);
    // even fed back as a thought (the engine never does), a rendering is a cue, never a fact
    o.noteThought(blk);
    const again = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(again);
    try std.testing.expectEqual(n0, o.field.facts.items.len);
    // and no rendered line ever carries the header's own words
    try std.testing.expect(std.mem.indexOf(u8, again[HEADER.len..], "RECALL OVERLAY") == null);
}

test "refractory: a line shown REFRACTORY times without being used is inhibited for INHIBIT renders, then offered again" {
    const gpa = std.testing.allocator;
    var o = Overlay.init(gpa, 64);
    defer o.deinit();
    o.setGoal("deploy region preference for the veil worker");
    _ = o.seedBlock("preferred deploy region is us-west-2 for every veil worker", .durable);
    var r: u32 = 0;
    while (r < REFRACTORY) : (r += 1) {
        const b = o.render() orelse return error.TestUnexpectedResult;
        defer gpa.free(b);
        try std.testing.expect(std.mem.indexOf(u8, b, "[durable] preferred deploy region is us-west-2") != null);
    }
    // ignored REFRACTORY times: out — the model's choice, respected
    try std.testing.expect(o.render() == null);
    try std.testing.expectEqual(@as(u32, 1), o.inhibited_total);
    var k: u32 = 1;
    while (k < INHIBIT) : (k += 1) try std.testing.expect(o.render() == null);
    // and back once the inhibition has run
    const back = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(back);
    try std.testing.expect(std.mem.indexOf(u8, back, "us-west-2") != null);
}

test "firing: a thought that uses a shown line resets its streak, feeds the next cue and queues it for the store; an unused sibling is inhibited on schedule" {
    const gpa = std.testing.allocator;
    var o = Overlay.init(gpa, 64);
    defer o.deinit();
    o.setGoal("finish the blog post and commit it");
    _ = o.seedBlock("the spire post draft lives at _posts/2026-09-16-spire-cgroup-spoofing-node-trust.md\n" ++
        "Canadian wildfire seasons have been historically severe in the prairie provinces\n", .conv);
    const b1 = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(b1);
    try std.testing.expect(std.mem.indexOf(u8, b1, "spire-cgroup") != null);
    try std.testing.expect(std.mem.indexOf(u8, b1, "wildfire") != null);
    // the model's next call names the draft's distinctive path: that line fired, the wildfire line did not
    const fired = o.observeFiring("{\"path\":\"_posts/2026-09-16-spire-cgroup-spoofing-node-trust.md\",\"content\":\"---\\ntitle: ...\"}");
    try std.testing.expectEqual(@as(u32, 1), fired);
    try std.testing.expectEqual(@as(usize, 1), o.fired.items.len);
    try std.testing.expect(std.mem.indexOf(u8, o.fired.items[0].text, "spire-cgroup") != null);
    try std.testing.expect(std.mem.indexOf(u8, o.hot.items, "spire") != null);
    // renders 2 and 3: both still offered (the used line's streak restarted when it fired)
    var r: u32 = 0;
    while (r < 2) : (r += 1) {
        const b = o.render() orelse return error.TestUnexpectedResult;
        defer gpa.free(b);
        try std.testing.expect(std.mem.indexOf(u8, b, "spire-cgroup") != null);
        try std.testing.expect(std.mem.indexOf(u8, b, "wildfire") != null);
    }
    // render 4: the wildfire line has been ignored REFRACTORY times → inhibited; the used line stays
    const b4 = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(b4);
    try std.testing.expect(std.mem.indexOf(u8, b4, "spire-cgroup") != null);
    try std.testing.expect(std.mem.indexOf(u8, b4, "wildfire") == null);
    try std.testing.expectEqual(@as(u32, 1), o.inhibited_total);
}

test "a render spends zero subprocesses and stays within its budget, whatever the field holds" {
    const gpa = std.testing.allocator;
    var o = Overlay.init(gpa, 64);
    defer o.deinit();
    o.budget = 300;
    o.setGoal("widgets gadgets sprockets inventory");
    var buf: [160]u8 = undefined;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const line = std.fmt.bufPrint(&buf, "inventory note {d}: the widgets gadgets and sprockets warehouse holds distinct persistent stock item {d}", .{ i, i }) catch continue;
        o.noteFinding(line);
    }
    try std.testing.expect(o.field.facts.items.len >= 2);
    const before = osc.spawn_probe;
    const b = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(b);
    try std.testing.expectEqual(before, osc.spawn_probe);
    try std.testing.expect(b.len <= HEADER.len + o.budget);
    try std.testing.expect(o.lines_shown >= 1);
    try std.testing.expect(std.mem.indexOf(u8, b, "[found] inventory note") != null);
}

test "a full field keeps every finding of a round: each is recallable at the next render, not only the last" {
    const gpa = std.testing.allocator;
    var o = Overlay.init(gpa, hs.MIN_FACTS);
    defer o.deinit();
    o.setGoal("restock the widgets warehouse");
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < hs.MIN_FACTS) : (i += 1) {
        _ = o.seedBlock(try std.fmt.bufPrint(&buf, "warehouse note {d}: the widgets warehouse restocks gadgets and sprockets weekly", .{i}), .conv);
    }
    try std.testing.expectEqual(hs.MIN_FACTS, o.field.facts.items.len);
    gpa.free(o.render() orelse return error.TestUnexpectedResult); // the first round's settle
    // one round, three tool calls deep: every finding lands in a full field before the next render
    const findings = [_][]const u8{
        "tool read_file inventory.csv: 412 widgets on hand, reorder point 500",
        "tool web_fetch supplier catalog: sprockets ship from the Hamilton depot in three days",
        "tool run_python forecast: gadgets demand rises eleven percent next quarter",
    };
    for (findings) |fd| o.noteFinding(fd);
    try std.testing.expectEqual(hs.MIN_FACTS, o.field.facts.items.len);
    for (findings) |fd| try std.testing.expect(o.field.seen.contains(fnv(fd)));
    // and the next round, cued on the first of them, is offered it
    o.noteThought("check inventory.csv against the reorder point");
    const next = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(next);
    try std.testing.expect(std.mem.indexOf(u8, next, "[found] tool read_file inventory.csv") != null);
}

test "a source tag rides beside the line, never inside its stems, and the overlay's keys are the field's own" {
    const gpa = std.testing.allocator;
    var o = Overlay.init(gpa, 64);
    defer o.deinit();
    o.setGoal("what is the user's age");
    try std.testing.expectEqual(@as(u32, 1), o.seedBlock("- [fact] Gary is 34 years old and lives in Toronto\n", .durable));
    const stored = o.field.facts.items[0].text;
    try std.testing.expectEqualStrings("Gary is 34 years old and lives in Toronto", stored);
    try std.testing.expect(o.field.seen.contains(fnv(stored))); // the same FNV-1a as the field
    const probe = hs.stemHashes(gpa, "fact");
    defer gpa.free(probe);
    try std.testing.expectEqual(@as(u32, 0), hs.interCount(o.field.facts.items[0].stems, probe));
    const b = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "[durable] Gary is 34 years old") != null);
    // list dressing and store prefixes are stripped the same way
    try std.testing.expectEqualStrings("index.html is a Three.js FPS game", cleanLine("[chat r0] index.html is a Three.js FPS game"));
    try std.testing.expectEqualStrings("run the migration first", cleanLine("  3. run the migration first  "));
    try std.testing.expectEqualStrings("[\"a\",\"b\"] is the list", cleanLine("[\"a\",\"b\"] is the list"));
}

test "strengthenFired: only store-backed lines are strengthened, one subprocess each" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const mem = osc.Mem.init(gpa, io, "zig-overlay-no-such-binary", "zig-overlay-no-such.db");
    var o = Overlay.init(gpa, 64);
    defer o.deinit();
    o.setGoal("the deploy");
    _ = o.seedBlock("the deploy pipeline builds the veil binary with the zig compiler on the build box\n", .conv);
    _ = o.seedBlock("preferred deploy region is us-west-2 for every veil worker\n", .durable);
    const b = o.render() orelse return error.TestUnexpectedResult;
    defer gpa.free(b);
    // the model uses both lines; only the store-backed one is strengthened, and it costs exactly one spawn
    try std.testing.expectEqual(@as(u32, 2), o.observeFiring("run the deploy pipeline with the zig compiler for the us-west-2 veil worker"));
    const before = osc.spawn_probe;
    try std.testing.expectEqual(@as(u32, 1), o.strengthenFired(mem, "chat:test"));
    try std.testing.expectEqual(before + 1, osc.spawn_probe);
}
