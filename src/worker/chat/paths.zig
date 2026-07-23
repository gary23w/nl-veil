//! paths.zig — ONE mapping from a conversation id to its build tree, shared by every resolver (engine drive
//! loop, the desk-delegated tool endpoint, cast deploy, and the supervisor's run-dir matching).
//!
//! Ordinary conversations build under `u{uid}/_chat/builds/{conv}` (unchanged). A SCHEDULED RUN's
//! conversation ("scheduled_{taskid}_{stamp}") builds under the task's own PERMANENT directory instead:
//!
//!     u{uid}/_sched/{taskid}/            — the task's durable home (beside its {taskid}.json definition;
//!                                          the sched tick/list loops skip directories, so it is inert there)
//!     u{uid}/_sched/{taskid}/runs/{stamp}/       — one subdirectory per run, named by the run's timestamp
//!     u{uid}/_sched/{taskid}/runs/{stamp}/work/  — where that run's files land (same {root}/work shape as
//!                                                  every other build tree, so casts co-edit it unchanged)
//!
//! So a task accumulates its run artifacts in one browsable place instead of scattering them across
//! `_chat/builds/scheduled_*`, and nothing deletes them when the conversation is pruned. The mapping is a
//! PURE function of the conv id — every resolver (server or desk) derives the same tree with no side channel.
//!
//! Note: convIdFor clips a very long task id (> 45 bytes) to fit the 64-byte conv ceiling; the mapping then
//! uses the clipped id — consistently everywhere, launch included — so runs still share one stable dir.

const std = @import("std");

// ---- SUB-CHAT BRANCHES -------------------------------------------------------------------------
// A sub-chat is a conversation whose id is "<parent>__s<N>" (N = 1..5). The id convention IS the
// metadata — no side-channel file: every resolver derives the same facts from the id alone.
//   * build tree: a branch shares its PARENT's build root (one family workspace — the whole point
//     is branching an idea without forking the work), via branchRoot() below.
//   * memory: the branch's hippocampus scope is "chat:<parent>__s<N>" — automatically a `__` child
//     of the family base "chat:<parent>", so the across-recall the document sub-scopes use makes
//     the whole family (primary + all branches) one recallable mind while each conv's writes stay
//     attributable to it.
//   * nesting is a SINGLE level: a branch of a branch is rejected at the turn gate.

pub const MAX_BRANCHES: u8 = 5;

pub const BranchParts = struct { parent: []const u8, n: u8 };

/// Parse a sub-chat id: "<parent>__s<N>" with N in 1..MAX_BRANCHES and a non-empty parent. null for
/// ordinary convs — including a hand-named "x__s12" (out of range) or "x__s" (no digit).
pub fn branchParts(conv: []const u8) ?BranchParts {
    const mark = std.mem.lastIndexOf(u8, conv, "__s") orelse return null;
    if (mark == 0) return null; // "__s1" with an empty parent is not a branch
    const digits = conv[mark + 3 ..];
    if (digits.len != 1 or digits[0] < '1' or digits[0] > '0' + MAX_BRANCHES) return null;
    return .{ .parent = conv[0..mark], .n = digits[0] - '0' };
}

/// The build-family root id: a branch resolves to its parent, everything else to itself.
pub fn branchRoot(conv: []const u8) []const u8 {
    return if (branchParts(conv)) |bp| bp.parent else conv;
}

/// The recall FAMILY BASE for a memory scope: "chat:<parent>__s<N>" → "chat:<parent>"; every other
/// scope is its own base. Gated on the "chat:" prefix so swarm/task scopes that merely contain
/// "__s" can never be silently rerooted. Callers hand the base to across-recall so the primary and
/// every branch read one family mind while writing their own partitions.
pub fn scopeFamilyBase(scope: []const u8) []const u8 {
    const P = "chat:";
    if (!std.mem.startsWith(u8, scope, P)) return scope;
    if (branchParts(scope[P.len..])) |bp| return scope[0 .. P.len + bp.parent.len];
    return scope;
}

pub const SchedParts = struct { tid: []const u8, stamp: []const u8 };

/// Parse a scheduled-run conversation id: "scheduled_{taskid}_{stamp}" where stamp is the trailing all-digit
/// run timestamp convIdFor minted. null for ordinary convs — including a hand-named "scheduled_notes" (no
/// digit stamp), which must keep its ordinary build dir rather than surprise-redirect into `_sched/`.
pub fn schedParts(conv: []const u8) ?SchedParts {
    const prefix = "scheduled_";
    if (!std.mem.startsWith(u8, conv, prefix)) return null;
    const rest = conv[prefix.len..];
    const us = std.mem.lastIndexOfScalar(u8, rest, '_') orelse return null;
    if (us == 0) return null; // "_stamp" with an empty task id is not a run conv
    const stamp = rest[us + 1 ..];
    if (stamp.len < 4) return null;
    for (stamp) |c| {
        if (c < '0' or c > '9') return null;
    }
    return .{ .tid = rest[0..us], .stamp = stamp };
}

/// The data-relative build ROOT for `conv`: "u{uid}/_sched/{tid}/runs/{stamp}" for a scheduled run,
/// "u{uid}/_chat/builds/{conv}" otherwise. Files go in "{root}/work" exactly as before. Empty on overflow
/// (conv ids are <= 64 bytes, so any sane buffer fits).
pub fn buildRootRel(buf: []u8, uid: u64, conv: []const u8) []const u8 {
    const root = branchRoot(conv); // a sub-chat builds in its parent's tree — one family workspace
    if (schedParts(root)) |p| {
        return std.fmt.bufPrint(buf, "u{d}/_sched/{s}/runs/{s}", .{ uid, p.tid, p.stamp }) catch "";
    }
    return std.fmt.bufPrint(buf, "u{d}/_chat/builds/{s}", .{ uid, root }) catch "";
}

/// Same mapping, composed from an absolute "{...}/u{d}/_chat" base (what the engine's call sites hold).
/// For a scheduled run the "/_chat" tail is swapped for the task tree; a base without that tail (never the
/// case today) falls back to the ordinary builds/ shape under it.
pub fn buildRootFromChatBase(buf: []u8, chat_base: []const u8, conv: []const u8) []const u8 {
    const root = branchRoot(conv); // a sub-chat builds in its parent's tree — one family workspace
    if (schedParts(root)) |p| {
        if (std.mem.endsWith(u8, chat_base, "/_chat")) {
            const user_root = chat_base[0 .. chat_base.len - "/_chat".len];
            return std.fmt.bufPrint(buf, "{s}/_sched/{s}/runs/{s}", .{ user_root, p.tid, p.stamp }) catch "";
        }
    }
    return std.fmt.bufPrint(buf, "{s}/builds/{s}", .{ chat_base, root }) catch "";
}

/// The run-dir TAIL a scheduled conv's build root always ends with ("_sched/{tid}/runs/{stamp}") — what the
/// supervisor's id↔run-dir matcher needs, since a redirected cast run_dir's basename is the bare stamp, not
/// the conv id. null for ordinary convs.
pub fn schedRunTail(buf: []u8, conv: []const u8) ?[]const u8 {
    const p = schedParts(conv) orelse return null;
    return std.fmt.bufPrint(buf, "_sched/{s}/runs/{s}", .{ p.tid, p.stamp }) catch null;
}

// ---- tests ----

test "branchParts: sub-chat ids parse, everything else abstains" {
    const b = branchParts("c6a616d35__s2").?;
    try std.testing.expectEqualStrings("c6a616d35", b.parent);
    try std.testing.expectEqual(@as(u8, 2), b.n);
    try std.testing.expect(branchParts("c6a616d35") == null);
    try std.testing.expect(branchParts("c6a616d35__s0") == null); // out of range
    try std.testing.expect(branchParts("c6a616d35__s6") == null); // beyond MAX_BRANCHES
    try std.testing.expect(branchParts("c6a616d35__s12") == null); // one digit only
    try std.testing.expect(branchParts("c6a616d35__s") == null);
    try std.testing.expect(branchParts("__s1") == null); // empty parent
    // a branch-of-a-branch id still PARSES (parent = the inner branch) — the turn gate rejects it
    const nested = branchParts("a__s1__s2").?;
    try std.testing.expectEqualStrings("a__s1", nested.parent);
}

test "branchRoot + build roots: a sub-chat shares its parent's tree" {
    try std.testing.expectEqualStrings("c42", branchRoot("c42__s3"));
    try std.testing.expectEqualStrings("c42", branchRoot("c42"));
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("u7/_chat/builds/c42", buildRootRel(&b, 7, "c42__s3"));
    try std.testing.expectEqualStrings("data/u1/_chat/builds/c42", buildRootFromChatBase(&b, "data/u1/_chat", "c42__s1"));
}

test "scopeFamilyBase: chat branch scopes reroot to the family base, everything else stays" {
    try std.testing.expectEqualStrings("chat:c42", scopeFamilyBase("chat:c42__s4"));
    try std.testing.expectEqualStrings("chat:c42", scopeFamilyBase("chat:c42"));
    try std.testing.expectEqualStrings("sched:tid__s1", scopeFamilyBase("sched:tid__s1")); // not chat: — untouched
    try std.testing.expectEqualStrings("knowledge__doc-x", scopeFamilyBase("knowledge__doc-x"));
}

test "schedParts: run convs parse, ordinary and hand-named convs don't" {
    const p = schedParts("scheduled_daily-report-0301070500_03010705").?;
    try std.testing.expectEqualStrings("daily-report-0301070500", p.tid);
    try std.testing.expectEqualStrings("03010705", p.stamp);
    try std.testing.expect(schedParts("c6a57f852") == null);
    try std.testing.expect(schedParts("scheduled_") == null);
    try std.testing.expect(schedParts("scheduled_notes") == null); // no digit stamp — ordinary conv
    try std.testing.expect(schedParts("scheduled_notes_v2") == null); // non-digit tail
    try std.testing.expect(schedParts("scheduled__03010705") == null); // empty task id
}

test "buildRootRel: scheduled runs land under the task's permanent dir, everything else under builds/" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "u1/_sched/daily-report-0301070500/runs/03010705",
        buildRootRel(&b, 1, "scheduled_daily-report-0301070500_03010705"),
    );
    try std.testing.expectEqualStrings("u7/_chat/builds/c6a57f852", buildRootRel(&b, 7, "c6a57f852"));
    try std.testing.expectEqualStrings("u1/_chat/builds/scheduled_notes", buildRootRel(&b, 1, "scheduled_notes"));
}

test "buildRootFromChatBase: swaps the /_chat tail for the task tree on scheduled runs only" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "data/u1/_sched/news-0715174857/runs/07151753",
        buildRootFromChatBase(&b, "data/u1/_chat", "scheduled_news-0715174857_07151753"),
    );
    try std.testing.expectEqualStrings(
        "data/u1/_chat/builds/c42",
        buildRootFromChatBase(&b, "data/u1/_chat", "c42"),
    );
    // absolute Windows-style base works the same (the mapping is pure string composition)
    try std.testing.expectEqualStrings(
        "C:/x/data/u2/_sched/t/runs/07171200",
        buildRootFromChatBase(&b, "C:/x/data/u2/_chat", "scheduled_t_07171200"),
    );
}

test "schedRunTail: the suffix a redirected run dir always carries" {
    var b: [160]u8 = undefined;
    try std.testing.expectEqualStrings("_sched/t/runs/07171200", schedRunTail(&b, "scheduled_t_07171200").?);
    try std.testing.expect(schedRunTail(&b, "c42") == null);
}
