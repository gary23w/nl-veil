# net

**File:** `src/worker/net.zig`  
**Module:** `worker`  
**Description:** A cached "is there internet?" probe that lets hosted model calls fail fast with one fixed sentence instead of rediscovering a dead uplink one ~20 s timeout at a time.

---

## Purpose Summary

When the uplink dropped, nothing was deadlocked: every egress path had its own bound (`--connect-timeout 20` on provider calls, 10–20 s ceilings on the web tools). The failure was the sum. An agentic turn makes many model and tool calls, each one spent its own ~20 s discovering the network was gone, and dozens of correct timeouts looked like a hung application with nothing on screen naming the cause. This module probes once, caches the verdict for 8 s, and gives callers one sentence to show. It is deliberately biased toward reporting online: a false "offline" refuses work the user could have had, while a false "online" costs only the timeout that would have been paid anyway. Local backends (the built-in model, Ollama) work with the uplink down and must never consult it.

## Key Exports

- `Verdict` — `online | offline | unknown`; `unknown` means the probe never got to ask (no curl, a spawn with no environment, a URL curl rejected before dialling), kept apart from `online` so tests can tell a real verdict from a probe that never ran
- `probe(io, gpa, environ)` — the cached probe: returns the stored verdict while it is younger than `TTL_MS` (8 s), otherwise runs curl and stores a new one
- `offline(io, gpa, environ)` — `probe(...) == .offline`; `unknown` collapses to "carry on"
- `MSG` — the one sentence every caller shows: the internet is offline, nothing hosted can be reached, and a local model (the built-in the-veil-12b or Ollama) plus the file, shell and memory tools keep working
- `invalidate(io)` — zero the cache timestamp so the next call re-probes; only the tests call it

## Dependencies

- `worker/deps` (imported as `depprobe`) — `isSpawnMissing`, to tell "curl could not be started" apart from "the network is down"
- `std` — `std.process.run` for the curl child, `std.Io.Mutex` around the cache, `Io.Timestamp` (`.real`) for the TTL clock
- The `curl` binary on PATH

## Usage Context

Imported only by `worker/llm.zig`, at both hosted entry points, and each call is gated on `!isLocal(base_url)` so a loopback backend is never asked. `post()` returns an error reply carrying `net.MSG`. `streamAttempt()` returns null, its existing signal to fall back to `complete()`, whose `post()` carries the same check, so a turn reaches the message in one cached probe instead of a stream timeout followed by a POST timeout. Both call sites pass `null` for `environ`. Registered directly in `src/tests.zig`. `run.zig`'s swarm probe reads the same `NL_NET_PROBE_URL` variable on its own but does not import this module.

## Notable Implementation Details

- The targets are IP literals, `https://1.1.1.1` then `https://8.8.8.8`, so a broken DNS resolver cannot pass for a dead uplink; exit 0 from the first skips the second. A non-empty `NL_NET_PROBE_URL` in the `environ` map replaces the pair, but that map is the argument, not the process environment: with the `null` both production callers pass, the override is never read.
- Each host is one `curl -sS -I --max-time 2 --connect-timeout 2 <url>`, with stdout capped at 8 KiB and stderr at 2 KiB. `PROBE_TIMEOUT_S` (2) documents that ceiling but nothing references it; the argv carries the literal `"2"`.
- Only curl exits 6 (couldn't resolve), 7 (couldn't connect), 28 (timed out) and 35 (SSL connect error) count as evidence of an outage. Any other exit, or a termination that is not a normal exit, marks the probe unusable. A spawn error marks it unusable only when `isSpawnMissing` says so; any other spawn error just moves on to the next host. Precedence: a reachable host gives `online`, else anything unusable gives `unknown`, else `offline`.
- That gate is a regression fix. The first cut read any non-zero exit as an outage, and an environ-less spawn that died in ~20 ms reported an online machine as offline. A test pins it with `htp://unsupported-scheme`, which makes curl exit 1 before touching the network, and asserts the verdict is not `offline`.
- The cache is process-wide module state (`mu`, `checked_at_ms`, `last_verdict`). The mutex guards only the read and the write, never the curl spawns, so callers that arrive together after expiry each run their own probe. `checked_at_ms` is the time the probe started, so a slow probe uses up part of its own 8 s.
- It shells out to curl rather than using httpc: on Windows httpc is a loopback client, and pointing it at a real external IP panics inside `netConnectIpWindows`. The header argues the TTL keeps these spawns far below the per-tool curl spawns already happening, so the Defender spawn-heuristic concern behind the curl-free clients does not apply.
- Tests pass the override map explicitly and give the test Io the real environment only where the language allows it (`.{ .block = .global }` on Windows, `.empty` elsewhere; the Windows-only form once broke Linux CI). The blackhole test (`https://192.0.2.1`, TEST-NET-1) expects `offline` in under 8 s and skips when the probe comes back `unknown`.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
