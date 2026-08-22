//! CONTINUATION ANCHORS — the durable half of "a cut unit of work resumes instead of restarting".
//!
//! The chat engine already fuses a continuation state into the engine row it commits when it cuts a turn, and
//! for an ordinary conversation that is enough: the row sits in messages.jsonl and seedLines replays it on the
//! very next turn. It is enough for exactly as long as that row stays inside the recency window, and it is
//! never enough for a surface whose next unit of work reads a DIFFERENT transcript than the one that was cut.
//! A scheduled task is the sharp case: sched hands every run a fresh conv_dir, so the next run's
//! assembleHistory opens an empty messages.jsonl and a context.json that does not exist. The row the engine
//! so carefully wrote is addressed to a transcript nobody will ever read. A task that keeps hitting the
//! ceiling therefore restarts from zero every single run, forever, which is the worst version of the bug and
//! the one no amount of care inside one transcript can fix.
//!
//! So the state is ALSO pressed into neuron-db under a scope of its own, where it is addressed to the WORK
//! rather than to a transcript, and read back by whichever unit picks that work up next. That is the whole
//! module. It is deliberately not a second memory system: it is four functions over the Mem the engine, the
//! swarm and the tools already share, so chat, sched and a swarm mind all resume through one implementation
//! instead of three that drift.
//!
//! WHY readPage AND NOT recall/assoc. Every other read of this store is a scoring contest keyed on a query —
//! recallScored(scope, goal_text, 6) is the chat engine's, and it is precisely what fails here. At resume
//! time there IS no good query: "continue" retrieves nothing, and keying on the pinned goal (which the engine
//! already does, see its RESUME CUE) returns six goal-shaped facts rather than the thread that was actually
//! interrupted. readPage asks no question. It returns this scope's facts verbatim, in insertion order,
//! complete, in one spawn — deterministic where top-k is a lottery, which is the entire point of writing the
//! state down in the first place.
//!
//! WHY THE SCOPE IS PREFIXED, NOT A CHILD. `resume:{scope}`, never `{scope}__resume`. Mem.assocAcross merges
//! `<scope>__*` in a single spawn and runs live on the chat scope in two places (the recall tool, and the
//! per-drive-step weave), so a child scope would silently start competing for slots inside two paths that
//! work today. The prefix is invisible to scopeFamilyBase (which gates on a literal "chat:" head), to every
//! assoc/assocAcross/recallScored/recall call in the tree, and to read_doc's `knowledge__doc-*` enumeration.
//! An anchor is reachable ONLY by the one readPage that names it, which is what makes adding this safe.
//!
//! BEST-EFFORT, LIKE EVERY OTHER TOUCH OF THIS STORE. Mem.run returns null on a missing binary, a non-exit
//! term or a non-zero status, and every miss here degrades to a zero-length slice. A missing neuron.exe, a
//! read-only db, an OOM: the anchor is simply not written or not found, and the caller behaves exactly as it
//! does today. Nothing on any hot path may fail BECAUSE a continuation could not be recorded.

const std = @import("std");
const osc = @import("oscillation.zig");

/// Namespace for every anchor. See the module header for why this is a PREFIX and not a `__child`.
pub const SCOPE_PREFIX = "resume:";

/// Ceiling on one pressed anchor. Mem.observe normalizes through a [1600]u8 via cleanFactInto and CLIPS to
/// that buffer, so anything above it is silently lost mid-sentence; staying under leaves room for the header
/// this module always prepends. The engine's own handoff cap (HANDOFF_MAX_BYTES, 1400) is the real bound in
/// practice — this is the backstop for any other caller.
pub const PRESS_MAX_BYTES: usize = 1400;

/// How many insertion-ordered facts one read pulls back. neuron-db atomizes prose into one fact per sentence,
/// so a four-label continuation state lands as roughly a dozen; 24 covers it with headroom and still bounds a
/// scope that somehow grew.
pub const READ_MAX_FACTS: u32 = 24;

/// Ceiling on the rendered block handed to a prompt. Sized under the engine's varying-channel budget so an
/// anchor can never crowd out the recall and correction blocks it sits beside.
pub const READ_CAP_BYTES: usize = 1200;

/// Why the unit of work stopped. Rendered into the anchor so the reader knows whether it is picking up after
/// a spend backstop (the work is sound, it just ran out of room), a loop guard (something was going in
/// circles and repeating it is the one thing not to do), or a hard stop.
pub const Cut = enum {
    ceiling,
    loop_guard,
    window,
    deadline,
    operator,

    pub fn text(c: Cut) []const u8 {
        return switch (c) {
            .ceiling => "it reached its spend ceiling",
            .loop_guard => "the loop guard stopped it repeating itself",
            .window => "its working context filled up",
            .deadline => "it ran out of time",
            .operator => "it was stopped",
        };
    }
};

/// `resume:{unit}` written into `buf` (no allocation). Empty when `unit` is empty or will not fit, and every
/// entry point treats an empty scope as "this capability is off" — a caller with no scope simply does nothing.
pub fn scopeFor(buf: []u8, unit: []const u8) []const u8 {
    if (unit.len == 0) return "";
    return std.fmt.bufPrint(buf, SCOPE_PREFIX ++ "{s}", .{unit}) catch "";
}

/// The fixed sentence every anchor opens with. Load-bearing twice over.
///
/// It is what makes `press` SAFE: Mem.replace forgets the whole scope BEFORE observing, and observe then
/// drops the write entirely when cleanFactInto counts under 12 alphanumerics. A caller who passed a body of
/// mostly paths and punctuation would therefore erase a perfectly good anchor and write nothing in its place.
/// This header clears that bar on its own, so the pair can never leave the scope empty. Asserted in the tests
/// rather than left as a convention, because the failure is silent and only shows up as a lost resume.
///
/// And it is what makes the anchor SELF-DESCRIBING to whatever reads it back: prose in a fact store has no
/// schema, so the record has to say what it is.
const ANCHOR_HEAD = "RESUME ANCHOR. The previous unit of work on this thread did not finish because ";

/// Record where a unit of work stopped, replacing whatever the last one left. `unit` is the caller's OWN
/// memory scope (ctx.scope on every surface) — no new addressing scheme, so a conversation, a scheduled task
/// and a swarm mind each anchor themselves without any of them agreeing on anything first.
///
/// SUPERSEDE, NOT APPEND, and that is the anti-accumulation story: Mem.replace drops the whole scope first,
/// so cut #2 REPLACES cut #1 and a task that hits the ceiling fifty times still has exactly one anchor. The
/// engine's fused engine row solves the same problem one layer up with the same shape (see seedLines' newest-
/// row rule); this is that discipline made durable.
///
/// A body too thin to be worth resuming from is DROPPED rather than pressed, so a good anchor is never
/// replaced by a worthless one.
pub fn press(mem: osc.Mem, unit: []const u8, why: Cut, body: []const u8) void {
    var sb: [512]u8 = undefined;
    const scope = scopeFor(&sb, unit);
    if (scope.len == 0) return;
    const trimmed = std.mem.trim(u8, body, " \r\n\t");
    if (trimmed.len < 24) return;

    const gpa = mem.gpa;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, ANCHOR_HEAD) catch return;
    out.appendSlice(gpa, why.text()) catch return;
    // The period matters: the store atomizes prose on sentence boundaries, so without it the header and the
    // first line of the body fuse into one fact and read back as one run-on sentence.
    out.appendSlice(gpa, ". ") catch return;
    const room = if (out.items.len < PRESS_MAX_BYTES) PRESS_MAX_BYTES - out.items.len else 0;
    if (room == 0) return;
    out.appendSlice(gpa, trimmed[0..@min(trimmed.len, room)]) catch return;
    mem.replace(scope, out.items);
}

/// The anchor for `unit`, rendered for a prompt, or "" when there is none (the ordinary case — every healthy
/// unit of work clears its own on the way out). Caller frees.
///
/// The framing is deliberate and is what makes it safe to inject UNCONDITIONALLY. It is presented as a record
/// the ENGINE wrote about a previous unit of work, never as an instruction, and it says in as many words that
/// a request about something else should ignore it. A cut turn followed by an unrelated question is a real
/// case; a continuation block that hijacked it would be a worse bug than the one this fixes.
pub fn read(gpa: std.mem.Allocator, mem: osc.Mem, unit: []const u8, cap: usize) []u8 {
    var sb: [512]u8 = undefined;
    const scope = scopeFor(&sb, unit);
    if (scope.len == 0) return gpa.dupe(u8, "") catch @constCast("");
    const raw = mem.readPage(scope, 0, READ_MAX_FACTS);
    defer gpa.free(raw);
    const body = std.mem.trim(u8, raw, " \r\n\t");
    if (body.len == 0) return gpa.dupe(u8, "") catch @constCast("");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(gpa, "CONTINUATION — the engine's record of a previous unit of work on this thread that " ++
        "was cut short before it finished. If the request below continues that work, ROLL FORWARD from here: " ++
        "treat what it says is done as done, do not repeat what it says was ruled out, and start from the next " ++
        "step it names. If the request is about something else, ignore this block.\n") catch {
        out.deinit(gpa);
        return gpa.dupe(u8, "") catch @constCast("");
    };
    out.appendSlice(gpa, body[0..@min(body.len, cap)]) catch {};
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return gpa.dupe(u8, "") catch @constCast("");
    };
}

/// Drop the anchor — the unit of work finished, so there is nothing to resume.
///
/// Called on every normal completion, which is what keeps this capability invisible in ordinary use: a
/// healthy conversation has no anchor, so its reads find nothing and its prompts are byte-identical to what
/// they are today. An anchor exists only in the window between a real cut and the work being picked back up.
pub fn clear(mem: osc.Mem, unit: []const u8) void {
    var sb: [512]u8 = undefined;
    const scope = scopeFor(&sb, unit);
    if (scope.len == 0) return;
    // replace(scope, "") is a whole-scope forget: cleanFactInto returns null for an empty fact and observe
    // bails before it spawns, so this costs the forget alone.
    mem.replace(scope, "");
}

test "an anchor is namespaced away from every scope the recall paths walk" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("resume:chat:c17f3a", scopeFor(&b, "chat:c17f3a"));
    try std.testing.expectEqualStrings("resume:sched:t42", scopeFor(&b, "sched:t42"));
    // A sub-chat keeps its OWN anchor: the branch is a different unit of work than its parent.
    try std.testing.expectEqualStrings("resume:chat:c17f3a__s2", scopeFor(&b, "chat:c17f3a__s2"));
    // No scope, no capability — never a bare "resume:" that every unit would then share.
    try std.testing.expectEqualStrings("", scopeFor(&b, ""));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", scopeFor(&tiny, "chat:c17f3a"));

    // The prefix, not a `__child`: assocAcross merges `<scope>__*` and runs live on the chat scope, so a
    // child anchor would compete for slots inside a recall path that works today.
    const s = scopeFor(&b, "chat:c17f3a");
    try std.testing.expect(!std.mem.startsWith(u8, s, "chat:"));
    try std.testing.expect(std.mem.indexOf(u8, s, "__") == null);
}

test "the anchor header clears the store's junk bar on its own, so a thin body can never erase a good anchor" {
    // Mem.replace forgets BEFORE it observes, and observe drops a fact under 12 alphanumerics (cleanFactInto).
    // Without a header that clears the bar by itself, pressing a body of mostly punctuation would wipe the
    // previous anchor and store nothing — a silent lost resume. This is that guarantee, asserted.
    var alnum: usize = 0;
    for (ANCHOR_HEAD) |c| {
        const l = c | 0x20;
        if ((l >= 'a' and l <= 'z') or (c >= '0' and c <= '9')) alnum += 1;
    }
    try std.testing.expect(alnum >= 12);

    // Every cut reason keeps that property, since each is concatenated onto the head before any body.
    for ([_]Cut{ .ceiling, .loop_guard, .window, .deadline, .operator }) |c|
        try std.testing.expect(c.text().len > 0);

    // The head ends open, so the reason completes it as one sentence rather than colliding with it.
    try std.testing.expect(std.mem.endsWith(u8, ANCHOR_HEAD, "because "));
}
