//! Per-provider (host) outbound pacing for HOSTED LLM backends. Local (loopback) backends never rate-limit, so
//! callers skip this for them. Two mechanisms share one small fixed host table:
//!
//!   - a 429 COOLDOWN every concurrent turn observes: when a provider returns 429/503, ALL in-flight turns to
//!     that host wait out the window instead of retrying in lockstep (a thundering herd just earns more 429s);
//!   - an optional token-bucket REQUESTS-PER-MINUTE cap (`NL_RATE_RPM`, default 0 = unlimited) that paces bursts
//!     BEFORE they reach the provider.
//!
//! State is process-global and mutex-guarded; wall-clock ms drives both the cooldown and the bucket refill. With
//! the default (no RPM cap, no active cooldown) `acquire` is a lock + two comparisons — no added latency.

const std = @import("std");

const MAX_HOSTS = 24;
const COOLDOWN_CAP_MS: i64 = 120_000; // never honor a back-off longer than 2 minutes
const DEFAULT_429_MS: i64 = 5_000; // 429/503 with no Retry-After → back off 5s
const ACQUIRE_WAIT_CAP_MS: i64 = 30_000; // a single acquire never sleeps longer than this per wait

const Host = struct {
    name: [110]u8 = undefined,
    len: usize = 0,
    cooldown_until_ms: i64 = 0,
    tokens: f64 = 0,
    last_refill_ms: i64 = 0,
};

var mtx: std.Io.Mutex = .init;
var table: [MAX_HOSTS]Host = @splat(.{});
var count: usize = 0;
var configured_rpm: i32 = 0; // requests/min cap; 0 = unlimited (default). Set once at startup via configure().

/// Set the per-host requests-per-minute cap (from `NL_RATE_RPM` at startup). <= 0 → unlimited. The 429 cooldown
/// is always active regardless; this only enables PROACTIVE bucket pacing. Call once before serving.
pub fn configure(rpm_val: i32) void {
    configured_rpm = if (rpm_val > 0) rpm_val else 0;
}

/// The host[:port] of a base_url: strip scheme, take up to the next '/', '?' or '#'. Empty for a bare path.
/// "https://api.deepseek.com/v1" → "api.deepseek.com".
pub fn hostOf(base_url: []const u8) []const u8 {
    var s = base_url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    const end = std.mem.indexOfAny(u8, s, "/?#") orelse s.len;
    return s[0..end];
}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// Requests-per-minute cap (0 = unlimited), configured once at startup.
fn rpm() i32 {
    return configured_rpm;
}

/// Find or insert the host slot (caller holds mtx). null when the table is full for a NEW host — pacing simply
/// no-ops for the overflow host, since correctness never depends on it (worst case: an unpaced 25th provider).
fn slotFor(host: []const u8, now_ms: i64, limit: i32) ?*Host {
    for (table[0..count]) |*h| {
        if (h.len == host.len and std.mem.eql(u8, h.name[0..h.len], host)) return h;
    }
    if (count >= MAX_HOSTS or host.len > 110) return null;
    const h = &table[count];
    count += 1;
    @memcpy(h.name[0..host.len], host);
    h.len = host.len;
    h.cooldown_until_ms = 0;
    h.tokens = @floatFromInt(@max(limit, 1)); // start the bucket full
    h.last_refill_ms = now_ms;
    return h;
}

const Decision = struct { clear: bool, wait_ms: i64 };

/// Pure send/wait decision for one host at `now` under a `limit` RPM (mutates the bucket on a clear grant). A
/// live cooldown always wins; then the token bucket (if limit > 0); else clear. Factored out of `acquire` so the
/// timing logic is unit-testable without a clock.
fn decide(h: *Host, now: i64, limit: i32) Decision {
    if (now < h.cooldown_until_ms) return .{ .clear = false, .wait_ms = h.cooldown_until_ms - now };
    if (limit <= 0) return .{ .clear = true, .wait_ms = 0 };
    const lf: f64 = @floatFromInt(limit);
    const elapsed: f64 = @floatFromInt(@max(now - h.last_refill_ms, 0));
    h.last_refill_ms = now;
    h.tokens = @min(lf, h.tokens + elapsed * (lf / 60_000.0));
    if (h.tokens >= 1.0) {
        h.tokens -= 1.0;
        return .{ .clear = true, .wait_ms = 0 };
    }
    const need = 1.0 - h.tokens;
    return .{ .clear = false, .wait_ms = @intFromFloat(@ceil(need * (60_000.0 / lf))) };
}

/// Block until this host is clear to send: past any 429 cooldown and (if NL_RATE_RPM > 0) holding a bucket token,
/// then consume a token. Bounded — one call never sleeps longer than ACQUIRE_WAIT_CAP_MS per wait, and gives up
/// after a fixed number of waits (returning anyway) so a mis-set clock or huge cooldown can't wedge a turn.
pub fn acquire(io: std.Io, base_url: []const u8) void {
    const host = hostOf(base_url);
    if (host.len == 0) return;
    const limit = rpm();
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        var wait_ms: i64 = 0;
        {
            mtx.lockUncancelable(io);
            defer mtx.unlock(io);
            const h = slotFor(host, nowMs(io), limit) orelse return; // table full for a new host → no-op
            const d = decide(h, nowMs(io), limit);
            if (d.clear) return;
            wait_ms = d.wait_ms;
        }
        if (wait_ms <= 0) return;
        if (wait_ms > ACQUIRE_WAIT_CAP_MS) wait_ms = ACQUIRE_WAIT_CAP_MS;
        io.sleep(.{ .nanoseconds = @as(u64, @intCast(wait_ms)) * std.time.ns_per_ms }, .awake) catch return;
    }
}

/// Record a provider back-off signal (HTTP 429 or 503) for a host. `retry_after_s` <= 0 → a default window.
/// Every subsequent acquire for the host waits out the (capped) window, so concurrent turns back off together.
pub fn note429(io: std.Io, base_url: []const u8, retry_after_s: i64) void {
    const host = hostOf(base_url);
    if (host.len == 0) return;
    var ms: i64 = if (retry_after_s > 0) retry_after_s * 1000 else DEFAULT_429_MS;
    if (ms > COOLDOWN_CAP_MS) ms = COOLDOWN_CAP_MS;
    mtx.lockUncancelable(io);
    defer mtx.unlock(io);
    const now = nowMs(io);
    const h = slotFor(host, now, rpm()) orelse return;
    const until = now + ms;
    if (until > h.cooldown_until_ms) h.cooldown_until_ms = until;
}

test "hostOf strips scheme and path" {
    try std.testing.expectEqualStrings("api.deepseek.com", hostOf("https://api.deepseek.com/v1"));
    try std.testing.expectEqualStrings("api.openai.com", hostOf("https://api.openai.com/v1/chat/completions"));
    try std.testing.expectEqualStrings("localhost:11434", hostOf("http://localhost:11434/v1"));
    try std.testing.expectEqualStrings("host.tld", hostOf("host.tld")); // scheme-less
    try std.testing.expectEqual(@as(usize, 0), hostOf("https:///onlypath").len);
}

test "decide: cooldown wins, then bucket, then clear" {
    // no limit, no cooldown → always clear
    var h1: Host = .{};
    try std.testing.expect(decide(&h1, 1000, 0).clear);

    // active cooldown → wait exactly the remainder
    var h2: Host = .{ .cooldown_until_ms = 5000 };
    const d2 = decide(&h2, 1000, 0);
    try std.testing.expect(!d2.clear);
    try std.testing.expectEqual(@as(i64, 4000), d2.wait_ms);

    // token bucket at 60 rpm: one token/sec. Full bucket grants; drained bucket waits ~1s.
    var h3: Host = .{ .tokens = 1.0, .last_refill_ms = 0 };
    try std.testing.expect(decide(&h3, 0, 60).clear); // consumes the one token
    const d3 = decide(&h3, 0, 60); // no time passed, empty → wait ~1000ms for the next token
    try std.testing.expect(!d3.clear);
    try std.testing.expect(d3.wait_ms >= 900 and d3.wait_ms <= 1000);

    // after ~1s the bucket refills one token → clear again
    try std.testing.expect(decide(&h3, 1000, 60).clear);
}
