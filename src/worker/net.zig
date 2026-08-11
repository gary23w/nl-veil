//! net.zig — "is there internet?", answered once and cached, so the rest of the engine can fail fast and
//! say so instead of rediscovering it one timeout at a time.
//!
//! THE BUG THIS EXISTS FOR. Nothing here was deadlocked when the uplink dropped — every egress path was
//! individually well-behaved, with `--connect-timeout 20` on the provider calls and 10-20s ceilings on the
//! web tools. The failure was the SUM: an agentic turn makes many model calls and many tool calls, each one
//! independently spends its own ~20s discovering the network is gone, and background polls do the same on
//! their own cadence. Dozens of correct 20s timeouts read, from the outside, as an application that has
//! hung — with nothing on screen ever naming the cause. Death by a thousand timeouts.
//!
//! So: probe ONCE, cache the verdict briefly, and let callers turn a multi-minute grind into one sentence.
//!
//! LOCAL BACKENDS MUST NEVER CONSULT THIS. A built-in or Ollama model is loopback and works perfectly with
//! the uplink down; making it wait on an internet probe would invent an outage it does not have. Callers
//! gate on `llm.isLocal(base_url)` BEFORE asking, and the probe itself never touches loopback.
//!
//! CURL, not httpc, and that is not a style choice. httpc.zig is a LOOPBACK client on Windows: its own header
//! says "no connect timeout option: this Zig's Windows backend panics on one … loopback connects resolve
//! immediately either way", and pointing it at a real external IP does exactly that — netConnectIpWindows
//! panics inside io.vtable.netConnectIp. Every real egress path in this engine already shells out to curl for
//! this reason. The TTL keeps it to at most one spawn per TTL_MS, far below the per-tool curl spawns already
//! happening, so the Defender spawn-heuristic concern that motivated the curl-free twins does not apply here.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const depprobe = @import("deps.zig"); // aliased like run.zig: tells "curl is missing" apart from "network down"

/// Where to knock. Two anycast resolvers — IP literals, so a dead DNS resolver cannot masquerade as a dead
/// uplink — and reaching EITHER proves egress. NL_NET_PROBE_URL overrides for locked-down networks that
/// blackhole both, where a fixed pair would report a permanent false outage. (run.zig's swarm probe reads the
/// same variable; one knob for one question.)
const PROBE_URLS = [_][]const u8{ "https://1.1.1.1", "https://8.8.8.8" };
/// A TCP handshake to a reachable anycast address is single-digit ms. 2s is generous for a slow link and
/// still an order of magnitude under the 20s each caller would otherwise burn alone.
const PROBE_TIMEOUT_S: u32 = 2;
/// How long a verdict stands. Long enough that a turn's many calls share one probe; short enough that
/// plugging the cable back in is noticed within a step or two rather than needing a restart.
const TTL_MS: i64 = 8_000;

var mu: std.Io.Mutex = .init; // Io.Mutex, like rate.zig — std.Thread.Mutex is gone in this Zig
var checked_at_ms: i64 = 0; // 0 = never probed
var last_offline: bool = false;

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// True when the machine looks to have NO working egress. Cached for TTL_MS.
///
/// Deliberately biased toward reporting ONLINE: only a probe where every host failed returns true. A
/// false "offline" is far more damaging than a false "online" — it refuses work the user could have had,
/// whereas guessing online merely costs the one timeout we would have paid anyway.
pub fn offline(io: Io, gpa: std.mem.Allocator, environ: ?*const std.process.Environ.Map) bool {
    const now = nowMs(io);
    mu.lockUncancelable(io);
    if (checked_at_ms != 0 and now -| checked_at_ms < TTL_MS) {
        defer mu.unlock(io);
        return last_offline;
    }
    mu.unlock(io);

    var any_reachable = false;
    var probe_unusable = false; // curl absent ⇒ we learned NOTHING; never report that as an outage
    const override = if (environ) |e| e.get("NL_NET_PROBE_URL") orelse "" else "";
    const urls: []const []const u8 = if (override.len > 0) &.{override} else &PROBE_URLS;
    for (urls) |u| {
        const argv = [_][]const u8{ "curl", "-sS", "-I", "--max-time", "2", "--connect-timeout", "2", u };
        const r = std.process.run(gpa, io, .{ .argv = &argv, .stdout_limit = .limited(8 << 10), .stderr_limit = .limited(2 << 10) }) catch |e| {
            // A MISSING curl is not a network signal (run.zig's probe makes the same distinction). Treat the
            // whole probe as unusable rather than let a toolchain gap masquerade as an outage and refuse work.
            if (depprobe.isSpawnMissing(e)) probe_unusable = true;
            continue;
        };
        gpa.free(r.stdout);
        gpa.free(r.stderr);
        if (r.term == .exited and r.term.exited == 0) {
            any_reachable = true;
            break; // one good host is proof; don't pay for the second
        }
        // ONLY a curl exit that MEANS "the network did not work" counts as evidence of an outage. Anything
        // else — a bad argument, a failed init, curl not on PATH, a spawn with no environment — tells us
        // nothing about the uplink, and reading it as an outage is the fail-CLOSED direction this module
        // must never take. That is not hypothetical: with an environ-less Io the child dies in ~20ms and the
        // first cut of this file reported a perfectly online machine as offline.
        const code: u8 = if (r.term == .exited) r.term.exited else 0;
        const network_evidence = switch (code) {
            6, // couldn't resolve host
            7, // couldn't connect
            28, // operation timed out
            35, // SSL connect error
            => true,
            else => false,
        };
        if (!network_evidence) probe_unusable = true;
    }
    if (probe_unusable and !any_reachable) any_reachable = true; // unknown ⇒ assume online, per the bias above

    mu.lockUncancelable(io);
    defer mu.unlock(io);
    checked_at_ms = now;
    last_offline = !any_reachable;
    return last_offline;
}

/// The one sentence every caller shows. Kept here so the wording cannot drift between the model path and
/// the tool path — the user reads the same thing whichever one noticed first.
pub const MSG = "Internet is offline — this machine has no working network connection right now. " ++
    "Nothing hosted can be reached until it comes back. A local model (the built-in the-veil-12b, or Ollama) " ++
    "keeps working offline, as do the file, shell and memory tools.";

/// Force the next `offline()` to re-probe. For tests, and for the moment a caller learns the truth the hard
/// way (a real connect failure) and wants the cache to reflect it rather than wait out the TTL.
pub fn invalidate(io: Io) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    checked_at_ms = 0;
}

/// Tests only: a spawn environment with enough in it for a curl child to actually run. Production gets the
/// real process environ from the Io (src/main.zig), and WITHOUT one the child dies in ~20ms — which is the
/// exact false signal the exit-code gate above exists to reject, so the tests must not reproduce it by
/// accident and call it a pass.
/// Tests only: the override map. The spawn environment comes from the Io (`.environ = .{ .block = .global }`,
/// mirroring production), NOT from here — with an environ-less Io the curl child dies in ~20ms having never
/// touched the network, which is the exact false signal the exit-code gate rejects. These tests must not
/// reproduce that by accident and then call the pass meaningful.
fn probeOverride(gpa: std.mem.Allocator, url: []const u8) !std.process.Environ.Map {
    var m = std.process.Environ.Map.init(gpa);
    if (url.len > 0) try m.put("NL_NET_PROBE_URL", url);
    return m;
}

test "offline(): the verdict is cached within the TTL" {
    const gpa = std.testing.allocator;
    var env = try probeOverride(gpa, "");
    defer env.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    const io = threaded.io();

    invalidate(io);
    const first = offline(io, gpa, &env);
    const t0 = nowMs(io);
    var i: usize = 0;
    while (i < 3) : (i += 1) try std.testing.expectEqual(first, offline(io, gpa, &env));
    try std.testing.expect(nowMs(io) -| t0 < 500); // cache hits, not fresh probes
    invalidate(io);
}

test "MSG names the offline condition and the local-model escape hatch" {
    // Load-bearing wording: this is what the user sees instead of a multi-minute stall, so it has to say
    // WHAT happened and WHAT still works.
    try std.testing.expect(std.mem.indexOf(u8, MSG, "Internet is offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, MSG, "Ollama") != null);
}

test "a blackholed uplink reads as offline, inside the probe ceiling" {
    // 192.0.2.1 is TEST-NET-1 (RFC 5737) — guaranteed unroutable, so SYNs are dropped with no RST. That is
    // what a pulled cable looks like to connect(), and is the case this whole module exists for.
    const gpa = std.testing.allocator;
    var env = try probeOverride(gpa, "https://192.0.2.1");
    defer env.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    const io = threaded.io();

    invalidate(io);
    const t0 = nowMs(io);
    const verdict = offline(io, gpa, &env);
    const ms = nowMs(io) -| t0;
    invalidate(io);
    try std.testing.expect(verdict);
    try std.testing.expect(ms < 8000); // must resolve on the 2s ceiling, not curl's default
}

test "a curl failure that is NOT network evidence must NOT report an outage (fail-open)" {
    // THE REGRESSION THIS PINS. The first cut of this file treated any non-zero curl exit as "the internet is
    // down", so an environ-less spawn — a child that died in 20ms having never touched the network — reported
    // a perfectly online machine as offline and would have refused hosted work outright. A false offline is
    // strictly worse than a false online: one denies the user work they could have had, the other costs the
    // single timeout we were going to pay anyway. `htp://` makes curl exit 1 (unsupported protocol) before it
    // touches the network, which is emphatically not a verdict on the uplink. Note the probe's real URLs are
    // IP LITERALS, so exit 6 (couldn't resolve) can never come from a broken resolver on a healthy link —
    // which is why 6 is safe to count as evidence.
    const gpa = std.testing.allocator;
    var env = try probeOverride(gpa, "htp://unsupported-scheme");
    defer env.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    const io = threaded.io();

    invalidate(io);
    const verdict = offline(io, gpa, &env);
    invalidate(io);
    try std.testing.expect(!verdict);
}
