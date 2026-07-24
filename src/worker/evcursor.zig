//! evcursor.zig — the byte-cursor contract shared by the two events.jsonl poll endpoints:
//! control/fanout.zig swarmEvents (a swarm's run dir) and chat/service.zig convEvents (a
//! conversation's dir). The web console polls BOTH with one piece of client code, so any
//! behavioral difference between them is a bug.
//!
//! That lockstep used to be a comment in each handler saying "change one, change the other", with
//! the sentinel, the page cap and the cursor arithmetic written out twice. It lives here now, so
//! the two endpoints cannot drift by accident and the contract is unit-testable away from httpz.
//!
//! THE CONTRACT
//!   from = PROBE  — a size probe: answer the file's TOTAL length as tiny JSON, no body, so a
//!                   watcher can baseline at the TAIL without transferring the backlog. An older
//!                   client never sends it; an older server reads it as past-the-end and returns
//!                   an empty 200, which a new client detects and falls back from.
//!   otherwise     — a POSITIONAL read from the client's cursor, never the whole file (a long run
//!                   appends indefinitely; a capped whole-file read returns EMPTY once the file
//!                   crosses the cap, which resets the cursor to 0 and replays history at the
//!                   client). One poll's payload is bounded by PAGE_MAX — UNDER the client's 1MB
//!                   response cap, because a burst bigger than the client could swallow wedges its
//!                   poll forever. The client catches up across polls.

const std = @import("std");

/// Sentinel `from` value requesting a size probe instead of a body. Typed `usize`, so this pins the
/// project to 64-bit targets (every shipped target is; a 32-bit build would fail here rather than
/// silently disagree with a client that sends the u64 sentinel).
pub const PROBE: usize = std.math.maxInt(u64);

/// Max bytes one poll may return. Deliberately under the client's 1MB per-response cap.
pub const PAGE_MAX: usize = 512 << 10;

/// Parse the `from`/`offset` query value. Anything unparseable is 0 — a missing or junk cursor
/// means "from the beginning", never an error the client has to handle.
pub fn parseFrom(raw: ?[]const u8) usize {
    const s = raw orelse return 0;
    return std.fmt.parseInt(usize, s, 10) catch 0;
}

pub fn isProbe(from: usize) bool {
    return from == PROBE;
}

/// How many bytes this poll should read at `from`, given the file's current `size`.
/// 0 means "nothing to send" — the client re-polls with its cursor unchanged.
///
/// NOTE the size < from case (a truncated or rotated file) also yields 0, which leaves the client
/// parked past EOF. events.jsonl only ever grows, so that cannot happen in practice today; the SSE
/// loop in control/fanout.zig, which faces the same file, rewinds instead. Pinned by a test so the
/// asymmetry is a decision rather than an accident.
pub fn want(size: usize, from: usize) usize {
    if (size <= from) return 0;
    return @min(size - from, PAGE_MAX);
}

/// The cursor a client should send next, after actually reading `n` bytes at `from`.
/// A short read (or an OOM that read nothing) leaves the cursor where it was.
pub fn nextOffset(from: usize, n: usize) usize {
    return from + n;
}

test "parseFrom: missing, junk, negative and huge all degrade to a usable cursor" {
    try std.testing.expectEqual(@as(usize, 0), parseFrom(null));
    try std.testing.expectEqual(@as(usize, 0), parseFrom(""));
    try std.testing.expectEqual(@as(usize, 0), parseFrom("abc"));
    try std.testing.expectEqual(@as(usize, 0), parseFrom("-5"));
    try std.testing.expectEqual(@as(usize, 0), parseFrom("12x"));
    try std.testing.expectEqual(@as(usize, 42), parseFrom("42"));
    try std.testing.expectEqual(@as(usize, 0), parseFrom("99999999999999999999999")); // overflow → 0
}

test "probe sentinel round-trips through the query string a client actually sends" {
    var buf: [24]u8 = undefined;
    const as_sent = try std.fmt.bufPrint(&buf, "{d}", .{PROBE});
    try std.testing.expect(isProbe(parseFrom(as_sent)));
    try std.testing.expect(!isProbe(parseFrom("0")));
    try std.testing.expect(!isProbe(0));
}

test "want: fresh file, caught up, a small delta, and a burst bounded by the page cap" {
    try std.testing.expectEqual(@as(usize, 0), want(0, 0)); // no events.jsonl yet
    try std.testing.expectEqual(@as(usize, 0), want(900, 900)); // caught up
    try std.testing.expectEqual(@as(usize, 100), want(1000, 900)); // ordinary delta
    try std.testing.expectEqual(PAGE_MAX, want(PAGE_MAX * 4, 0)); // burst: bounded, not the whole file
    try std.testing.expectEqual(PAGE_MAX, want(PAGE_MAX + 1, 0)); // one byte over the cap
    try std.testing.expectEqual(PAGE_MAX, want(PAGE_MAX, 0)); // exactly the cap
}

test "want: a shrunken file yields nothing (the poll endpoints do not rewind — see the doc comment)" {
    try std.testing.expectEqual(@as(usize, 0), want(50, 900));
}

test "nextOffset: a full page advances, a short read advances only by what arrived, OOM stays put" {
    try std.testing.expectEqual(@as(usize, 1000), nextOffset(900, 100));
    try std.testing.expectEqual(@as(usize, 940), nextOffset(900, 40)); // short read
    try std.testing.expectEqual(@as(usize, 900), nextOffset(900, 0)); // read nothing → cursor unchanged
}

test "a catch-up walk over a growing file terminates and never replays a byte" {
    // The property the client depends on: repeated polls from a cursor converge on the file size,
    // each poll is bounded, and the offsets tile the file exactly once.
    const size: usize = PAGE_MAX * 3 + 1234;
    var from: usize = 0;
    var polls: u32 = 0;
    var covered: usize = 0;
    while (want(size, from) > 0) {
        const n = want(size, from);
        covered += n;
        from = nextOffset(from, n);
        polls += 1;
        try std.testing.expect(polls < 100); // must converge, not spin
    }
    try std.testing.expectEqual(size, from);
    try std.testing.expectEqual(size, covered); // every byte delivered exactly once
    try std.testing.expectEqual(@as(u32, 4), polls);
}
