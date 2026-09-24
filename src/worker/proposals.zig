//! LINEAGE PROPOSAL REVIEW — the promotion step the end-of-run judge and the habit miner were built to wait on.
//!
//! runJudge (rsi.zig) proposes durable lessons/skills into `lessons-proposed` / `skills-proposed`, and
//! proposeHabits (run.zig) proposes recurring successful tool sequences into `habits-proposed`. Nothing recalls
//! those scopes into a prompt, which is the point — an ungrounded "lesson" written straight into binding
//! context is the phantom-directive failure the quarantine exists to prevent. Until this file, though, nothing
//! read them at all: under a lineage the quarantine grew run over run and the most carefully graded output of
//! the whole loop never reached the next cast.
//!
//! This is that step, and nothing more. `decide` takes ONE proposal the reviewer (a human in the desk / CLI, or
//! a benchmark that measured it) names by its exact stored text, and either
//!   accept: writes the proposal's clean body into the LIVE scope the minds recall from (lessons → lessons,
//!           skills and habits → skills), then drops it from the quarantine; or
//!   reject: records it in `proposals-rejected`, which the judge and the miner read so a rejected proposal is
//!           not minted again next run, then drops it from the quarantine.
//! A text that is not currently in the named quarantine scope is refused (`.missing`), so a caller cannot use
//! this to forget arbitrary substrings or to write arbitrary text into a live scope.
//!
//! A promoted lesson is then graded like every other lesson: run.zig reinforces the lesson recalled for a
//! failure when that failure resolves into a verified fix, so one that never helps simply fades.

const std = @import("std");
const osc = @import("oscillation.zig");
const tools = @import("tools.zig");
const run = @import("run.zig");

pub const Source = struct {
    scope: []const u8, // the quarantine scope
    live: []const u8, // the scope an accepted proposal is promoted into
    kind: []const u8, // "lesson" / "skill" / "habit" — what the reviewer is shown
};

pub const SOURCES = [_]Source{
    .{ .scope = tools.LESSON_PROPOSED_SCOPE, .live = tools.LESSON_SCOPE, .kind = "lesson" },
    .{ .scope = tools.SKILL_PROPOSED_SCOPE, .live = tools.SKILL_SCOPE, .kind = "skill" },
    // A habit has no live scope of its own: a recurring successful sequence IS a procedure, which is what the
    // skill scope holds, and skills are recalled by relevance to the goal (run.zig assoc on SKILL_SCOPE).
    .{ .scope = tools.HABIT_PROPOSED_SCOPE, .live = tools.SKILL_SCOPE, .kind = "habit" },
    // a tool-proven requirement of the task: every mind reads the whole facts scope (run.zig PROVEN TASK FACTS)
    .{ .scope = tools.FACT_PROPOSED_SCOPE, .live = tools.FACT_SCOPE, .kind = "fact" },
};

/// Lowercase alphanumeric words of 3+ chars, deduplicated, into `out`; returns the count. Pure.
fn wordSet(text: []const u8, out: [][]const u8, store: []u8) usize {
    var n: usize = 0;
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) : (i += 1) {}
        const st = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) : (i += 1) {}
        const w = text[st..i];
        if (w.len < 3 or n >= out.len or used + w.len > store.len) continue;
        const dst = store[used .. used + w.len];
        for (w, 0..) |c, k| dst[k] = std.ascii.toLower(c);
        var dup = false;
        for (out[0..n]) |o| {
            if (std.mem.eql(u8, o, dst)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        used += w.len;
        out[n] = dst;
        n += 1;
    }
    return n;
}

/// Does `text` restate a line of `listing` (newline-separated)? The body before any "| evidence:" tail is compared
/// as a word set; a Jaccard overlap of 0.6 or more is the same entry in other words. Pure.
pub fn nearDuplicate(text: []const u8, listing: []const u8) bool {
    var aw: [96][]const u8 = undefined;
    var ab: [1024]u8 = undefined;
    const an = wordSet(run.proposalBody(text), &aw, &ab);
    if (an == 0) return false;
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |line| {
        var bw: [96][]const u8 = undefined;
        var bb: [1024]u8 = undefined;
        const bn = wordSet(run.proposalBody(line), &bw, &bb);
        if (bn == 0) continue;
        var common: usize = 0;
        for (aw[0..an]) |a| {
            for (bw[0..bn]) |b| {
                if (std.mem.eql(u8, a, b)) {
                    common += 1;
                    break;
                }
            }
        }
        const uni = an + bn - common;
        if (common * 10 >= uni * 6) return true;
    }
    return false;
}

/// A proposal that is a pasted tool call rather than a rule in words (bench v2 kept a `fix: edit_file {"path":...}`
/// row): JSON object syntax or an edit anchor in the body. Pure.
pub fn looksLikeNoise(text: []const u8) bool {
    const body = run.proposalBody(text);
    return std.mem.indexOf(u8, body, "{\"") != null or std.mem.indexOf(u8, body, "\":") != null or
        std.mem.indexOf(u8, body, "\"ops\"") != null or std.mem.count(u8, body, "{") >= 2;
}

pub fn sourceFor(scope: []const u8) ?Source {
    for (SOURCES) |s| if (std.mem.eql(u8, s.scope, scope)) return s;
    return null;
}

/// How much of the stored line `forget` matches on (a substring match) — the desk's acceptProposal uses the
/// same prefix length for its own quarantine.
pub const KEY_LEN = 110;

/// The tool sequence of a mined habit line, "habit: a>b>c (a mind ran this sequence Nx this run) | …" → "a>b>c".
/// Pure.
pub fn habitSeq(text: []const u8) []const u8 {
    var s = std.mem.trim(u8, run.proposalBody(text), " \t");
    if (std.mem.startsWith(u8, s, "habit:")) s = s["habit:".len..];
    if (std.mem.indexOf(u8, s, " (")) |p| s = s[0..p];
    return std.mem.trim(u8, s, " \t");
}

/// The text an accepted proposal is stored as in its live scope: the body without the reviewer's evidence
/// tail, atomized so the store keeps it as ONE fact. A habit becomes a named procedure. Pure.
pub fn liveText(buf: []u8, src: Source, stored: []const u8) []const u8 {
    var tmp: [720]u8 = undefined;
    const body = if (std.mem.eql(u8, src.kind, "habit"))
        (std.fmt.bufPrint(&tmp, "procedure: {s} - a tool sequence that recurred in successful work", .{habitSeq(stored)}) catch return "")
    else
        run.proposalBody(stored);
    return run.atomizeForObserve(buf, body);
}

/// The line a rejection is remembered by in `proposals-rejected`. A habit keeps its "habit: <seq> (" shape so
/// the miner's same-sequence check (`habitKnown`) matches it. Pure.
pub fn rejectedText(buf: []u8, src: Source, stored: []const u8) []const u8 {
    var tmp: [720]u8 = undefined;
    const body = if (std.mem.eql(u8, src.kind, "habit"))
        (std.fmt.bufPrint(&tmp, "habit: {s} (rejected in review)", .{habitSeq(stored)}) catch return "")
    else
        (std.fmt.bufPrint(&tmp, "{s}: {s}", .{ src.kind, run.proposalBody(stored) }) catch return "");
    return run.atomizeForObserve(buf, body);
}

/// Is `seq` already pending, rejected, or promoted? The miner counts a sequence per RUN, so under a lineage the
/// same habit came back every run as a new line ("ran 3x", then "ran 4x") and the quarantine only grew.
/// `pending` / `rejected` / `skills` are the three scopes' export bodies. Pure.
pub fn habitKnown(seq: []const u8, pending: []const u8, rejected: []const u8, skills: []const u8) bool {
    var kb: [128]u8 = undefined;
    const as_habit = std.fmt.bufPrint(&kb, "habit: {s} (", .{seq}) catch return false;
    if (std.mem.indexOf(u8, pending, as_habit) != null) return true;
    if (std.mem.indexOf(u8, rejected, as_habit) != null) return true;
    var pb: [128]u8 = undefined;
    const as_proc = std.fmt.bufPrint(&pb, "procedure: {s} -", .{seq}) catch return false;
    return std.mem.indexOf(u8, skills, as_proc) != null;
}

/// Is `text` exactly one of the lines of an export body? Pure.
pub fn present(listing: []const u8, text: []const u8) bool {
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), text)) return true;
    }
    return false;
}

pub const Outcome = enum { accepted, rejected, missing, failed };

/// Accept or reject ONE quarantined proposal, named by its exact stored text. See the file header.
pub fn decide(mem: osc.Mem, scope: []const u8, text: []const u8, accept: bool) Outcome {
    const src = sourceFor(scope) orelse return .missing;
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 8) return .missing;
    const listing = mem.list(scope);
    defer mem.gpa.free(listing);
    if (!present(listing, t)) return .missing;
    var b: [720]u8 = undefined;
    if (accept) {
        const live = liveText(&b, src, t);
        if (live.len == 0 or mem.observe(src.live, live) == 0) return .failed; // keep it queued: nothing was promoted
    } else {
        const r = rejectedText(&b, src, t);
        if (r.len > 0) _ = mem.observe(tools.PROPOSAL_REJECTED_SCOPE, r);
    }
    mem.forgetMatch(scope, t[0..@min(t.len, KEY_LEN)]);
    return if (accept) .accepted else .rejected;
}

// ------------------------------------------------------------------------------------------- tests

const tt = std.testing;

test "proposals: a habit line yields its sequence, a live procedure, and a rejection the miner recognizes" {
    const line = "habit: read_file>edit_file>run_command (a mind ran this sequence 4x this run) | evidence: recurring successful tool sequence";
    try tt.expectEqualStrings("read_file>edit_file>run_command", habitSeq(line));
    const hab = sourceFor(tools.HABIT_PROPOSED_SCOPE).?;
    var b: [720]u8 = undefined;
    const live = liveText(&b, hab, line);
    try tt.expect(std.mem.startsWith(u8, live, "procedure: read_file>edit_file>run_command - "));
    try tt.expect(std.mem.indexOf(u8, live, "evidence") == null);
    var rb: [720]u8 = undefined;
    const rej = rejectedText(&rb, hab, line);
    // every shape the miner can meet it in: pending, rejected, promoted
    try tt.expect(habitKnown("read_file>edit_file>run_command", line, "", ""));
    try tt.expect(habitKnown("read_file>edit_file>run_command", "", rej, ""));
    try tt.expect(habitKnown("read_file>edit_file>run_command", "", "", live));
    // a PREFIX of a known sequence is a different habit
    try tt.expect(!habitKnown("read_file>edit_file", line, rej, live));
}

test "proposals: a lesson is promoted without its evidence tail, atomized to one fact" {
    const les = sourceFor(tools.LESSON_PROPOSED_SCOPE).?;
    try tt.expectEqualStrings(tools.LESSON_SCOPE, les.live);
    var b: [720]u8 = undefined;
    const live = liveText(&b, les, "Install the missing module first. Then rerun the suite | evidence: act row 12 exit 1, row 14 exit 0");
    try tt.expectEqualStrings("Install the missing module first, Then rerun the suite", live);
    try tt.expect(sourceFor("lessons") == null); // a LIVE scope is never a review source
}

test "proposals: a restated entry is a near duplicate, a different one is not, and pasted JSON is noise" {
    const live = "When an import fails, install the dependency then rerun the tests\nParse money with Decimal, never float, before rounding";
    try tt.expect(nearDuplicate("When an import fails, install the dependency, then rerun the tests: worked | evidence: rows 3-4", live));
    try tt.expect(nearDuplicate("Install the dependency then rerun the tests when an import fails | evidence: row 9", live));
    try tt.expect(!nearDuplicate("A value that rounds to zero formats as 0.00, never -0.00 | evidence: FAIL HOUSE RULE row 12", live));
    try tt.expect(!nearDuplicate("anything at all | evidence: x", ""));
    try tt.expect(looksLikeNoise("fix: edit_file {\"path\": \"money.py\", \"ops\": []} failed | evidence: row 3"));
    try tt.expect(!looksLikeNoise("A leading decimal point parses: '.5' is 0.50 | evidence: checker FAIL line {row 4}"));
    // a FACT promotes into the live facts scope every mind reads
    const f = sourceFor(tools.FACT_PROPOSED_SCOPE).?;
    try tt.expectEqualStrings(tools.FACT_SCOPE, f.live);
    try tt.expectEqualStrings("fact", f.kind);
}

test "proposals: present matches whole lines only" {
    const listing = "alpha beta gamma\n  second line here \nthird";
    try tt.expect(present(listing, "second line here"));
    try tt.expect(!present(listing, "alpha beta"));
    try tt.expect(!present(listing, ""));
}

test "proposals: decide promotes, rejects, and refuses what is not queued (real neuron store)" {
    const gpa = tt.allocator;
    const io = tt.io;
    const bin = if (@import("builtin").os.tag == .windows) "bin/neuron.exe" else "bin/neuron";
    std.Io.Dir.cwd().access(io, bin, .{}) catch return error.SkipZigTest;
    const dir = "zig-proposals-tmp";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const mem = osc.Mem.init(gpa, io, bin, dir ++ "/mind.sqlite");

    const L1 = "When an import fails, install the dependency then rerun the tests | evidence: row 12 exit 1, row 14 exit 0";
    const L2 = "Parse money with Decimal, never float, before rounding | evidence: rows 3-5 fail then pass";
    const H1 = "habit: read_file>edit_file>run_command (a mind ran this sequence 4x this run) | evidence: recurring successful tool sequence";
    if (mem.observe(tools.LESSON_PROPOSED_SCOPE, L1) == 0) return error.SkipZigTest; // store unusable here
    _ = mem.observe(tools.LESSON_PROPOSED_SCOPE, L2);
    _ = mem.observe(tools.HABIT_PROPOSED_SCOPE, H1);

    // not queued / wrong scope / a live scope: refused, nothing changes
    try tt.expectEqual(Outcome.missing, decide(mem, tools.LESSON_PROPOSED_SCOPE, "When an import fails", true));
    try tt.expectEqual(Outcome.missing, decide(mem, tools.SKILL_PROPOSED_SCOPE, L1, true));
    try tt.expectEqual(Outcome.missing, decide(mem, tools.LESSON_SCOPE, L1, true));
    try tt.expectEqual(@as(u32, 2), mem.factCount(tools.LESSON_PROPOSED_SCOPE));

    try tt.expectEqual(Outcome.accepted, decide(mem, tools.LESSON_PROPOSED_SCOPE, L1, true));
    try tt.expectEqual(Outcome.rejected, decide(mem, tools.LESSON_PROPOSED_SCOPE, L2, false));
    try tt.expectEqual(Outcome.accepted, decide(mem, tools.HABIT_PROPOSED_SCOPE, H1, true));

    const pend = mem.list(tools.LESSON_PROPOSED_SCOPE);
    defer gpa.free(pend);
    try tt.expectEqual(@as(usize, 0), pend.len);
    const live = mem.list(tools.LESSON_SCOPE);
    defer gpa.free(live);
    try tt.expect(std.mem.indexOf(u8, live, "install the dependency then rerun the tests") != null);
    try tt.expect(std.mem.indexOf(u8, live, "evidence") == null);
    try tt.expect(std.mem.indexOf(u8, live, "Decimal") == null); // the rejected one never went live
    const rej = mem.list(tools.PROPOSAL_REJECTED_SCOPE);
    defer gpa.free(rej);
    try tt.expect(std.mem.indexOf(u8, rej, "Decimal") != null);
    const sk = mem.list(tools.SKILL_SCOPE);
    defer gpa.free(sk);
    try tt.expect(habitKnown("read_file>edit_file>run_command", "", "", sk));
    // a second decision on the same text finds nothing queued
    try tt.expectEqual(Outcome.missing, decide(mem, tools.LESSON_PROPOSED_SCOPE, L1, true));
}
