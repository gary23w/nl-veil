# net

**File:** `src/worker/net.zig`  
**Module:** `worker`  
**Description:** A cached, single-flight "is there internet?" probe that lets hosted model calls fail fast with one fixed sentence instead of rediscovering a dead uplink one ~20 s timeout at a time.

---

## Purpose Summary

When the uplink dropped, nothing was deadlocked: every egress path had its own bound (`--connect-timeout 20` on provider calls, 10–20 s ceilings on the web tools). The failure was the sum. An agentic turn makes many model and tool calls, each one spent its own ~20 s discovering the network was gone, and dozens of correct timeouts looked like a hung application with nothing on screen naming the cause. This module probes once, caches the verdict for 8 s, runs one probe at a time however many callers arrive together, and gives callers one sentence to show. It is deliberately biased toward reporting online: a false "offline" refuses work the user could have had, while a false "online" costs only the timeout that would have been paid anyway. Local backends (the built-in model, Ollama) work with the uplink down and must never consult it.

## Key Exports

- `Verdict` — `online | offline | unknown` (`enum(u8)`, so the cache can hold it in an atomic); `unknown` means no verdict was established for this caller: the probe never got to ask (no curl, a spawn with no environment, a URL curl rejected before dialling), or another caller's probe outlived the wait for it. It is kept apart from `online` so tests can tell a real verdict from a probe that never ran
- `useEnviron(environ)` — take `NL_NET_PROBE_URL` from the process environment; `src/main.zig` calls it once at startup
- `probe(io, gpa, environ)` — the cached probe: the stored verdict while it is younger than `TTL_MS` (8 s), otherwise one curl probe, shared by every caller that arrives while it runs
- `offline(io, gpa, environ)` — `probe(...) == .offline`; `unknown` collapses to "carry on"
- `MSG` — the one sentence every caller shows: the internet is offline, nothing hosted can be reached, and a local model (the built-in the-veil-12b or Ollama) plus the file, shell and memory tools keep working
- `invalidate()` — zero the cache timestamp so the next call re-probes; only the tests call it

## Dependencies

- `worker/deps` (imported as `depprobe`) — `isSpawnMissing`, to tell "curl could not be started" apart from "the network is down"
- `worker/browser/util` (imported as `bu`) — `sleepMs`, the raw-thread sleep a waiting caller naps in
- `std` — `std.process.run` for the curl child, `std.atomic.Value` for the cache, `Io.Timestamp` (`.real`) for the TTL clock
- The `curl` binary on PATH

## Usage Context

`worker/llm.zig` asks at both hosted entry points, and each call is gated on `!isLocal(base_url)` so a loopback backend is never asked. `post()` returns an error reply carrying `net.MSG`. `streamAttempt()` returns null, its existing signal to fall back to `complete()`, whose `post()` carries the same check, so a turn reaches the message in one cached probe instead of a stream timeout followed by a POST timeout. Both call sites pass `null` for `environ`, so the URL override comes from `useEnviron`, which `src/main.zig` calls right after creating its Io and before parsing the subcommand; that covers the server and the `worker` subprocess alike. Registered directly in `src/tests.zig`. `run.zig`'s swarm probe reads the same `NL_NET_PROBE_URL` variable on its own but does not import this module.

## Notable Implementation Details

- The targets are IP literals, `https://1.1.1.1` then `https://8.8.8.8`, so a broken DNS resolver cannot pass for a dead uplink; exit 0 from the first skips the second. A non-empty `NL_NET_PROBE_URL` replaces the pair: from the `environ` argument when a caller passes one (the tests do), otherwise from the copy `useEnviron` took. That copy lives in a 512-byte buffer; a longer value is ignored rather than truncated. Until 2026-09-16 nothing took the process environment, so with the `null` both production callers pass, the override documented for networks that blackhole both resolvers was never read.
- Each host is one `curl -sS -I --max-time 2 --connect-timeout 2 <url>`, with stdout capped at 8 KiB and stderr at 2 KiB. Both `2`s are `PROBE_TIMEOUT_S`, rendered into the argv at compile time (it used to be a literal the constant merely documented).
- Only curl exits 6 (couldn't resolve), 7 (couldn't connect), 28 (timed out) and 35 (SSL connect error) count as evidence of an outage. Any other exit, or a termination that is not a normal exit, marks the probe unusable. A spawn error marks it unusable only when `isSpawnMissing` says so; any other spawn error just moves on to the next host. Precedence: a reachable host gives `online`, else anything unusable gives `unknown`, else `offline`.
- That gate is a regression fix. The first cut read any non-zero exit as an outage, and an environ-less spawn that died in ~20 ms reported an online machine as offline. A test pins it with `htp://unsupported-scheme`, which makes curl exit 1 before touching the network, and asserts the verdict is not `offline`.
- The cache is process-wide and lock-free: `checked_at_ms` (when the standing verdict's probe started, 0 = never), `last_verdict` and `probing` are atomics, so no caller ever parks on the Io runtime here. A probe stores its verdict before its timestamp, so a reader never pairs a fresh time with an old answer. Because the timestamp is the start of the probe, a slow probe uses up part of its own 8 s.
- Single flight. When the verdict has expired, the first caller claims `probing` with a compare-and-swap, looks at the cache once more (a probe may have landed in between), and runs the curls. A caller that loses the claim waits in 25 ms `sleepMs` naps for up to `PROBE_WAIT_MS` (every host at its ceiling plus 2 s: 6 s), then takes the new verdict, or `unknown` if the probe is still running. This is the shape of `cf_oauth.zig`'s token refresh. Before 2026-09-16 callers that arrived together after expiry, such as a swarm round's minds reaching their model calls at once, each ran a probe of their own.
- It shells out to curl rather than using httpc: the probe is an HTTPS request, httpc speaks plain HTTP, and on Windows httpc's portable path panics dialing a real external address (the IPv4-literal path it takes there now, `wsock.zig`, has no TLS either). The header argues that the TTL and the single flight keep these spawns to one probe per `TTL_MS`, far below the per-call curl spawns already happening, so the Defender spawn-heuristic concern behind the curl-free clients does not apply.
- Tests pass the override map explicitly and give the test Io the real environment only where the language allows it (`.{ .block = .global }` on Windows, `.empty` elsewhere; the Windows-only form once broke Linux CI). The blackhole test (`https://192.0.2.1`, TEST-NET-1) expects `offline` in under 8 s and skips when the probe comes back `unknown`. The single-flight test starts four callers against an expired verdict with that blackholed override, so the one probe runs its full 2 s while the other three arrive, and asserts that exactly one probe ran (`probes_run`) and that all four got the same verdict.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
