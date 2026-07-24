# httpc

**File:** `src/worker/httpc.zig`  
**Module:** `worker`  
**Description:** A bounded raw-socket HTTP/1.1 client for plain-HTTP loopback endpoints — a local Ollama on :11434 and the smoke gate's declared 127.0.0.1 probes — replacing the curl subprocess for that traffic.

---

## Purpose Summary

Spawning curl.exe put the bearer token and full JSON body on the command line (readable by any same-user process on Windows), and the spawn pattern — a self-built binary forking curl to POST bearer JSON at localhost on a few-second cadence — is exactly what Defender's behavior/ML models flag; it killed the app on unexcluded machines. In-process sockets have no argv, no child, and no per-call cost. Unlike the earlier raw-socket client that trusted `Connection: close` and read to EOF unbounded, this one parses real HTTP framing AND races the whole round trip against a sleeper, so `timeout_s` is a hard ceiling exactly like `curl --max-time`. Anything non-loopback (hosted TLS providers, web fetches) stays on curl.

## Key Exports

- `Resp { status, body }` — one reply; body is gpa-owned when non-empty
- `Result` — `ok | refused | timed_out | failed`; the header spells out the triage: refused (nothing listening) and timed_out (server wedged) mean fail fast, `failed` is worth retrying when the request is idempotent
- `Req` — method/host/port/path, optional bearer (in-process only, never argv), optional JSON body, `timeout_s` hard ceiling, `cap` on body bytes (default 1 MB; bigger replies are `.failed`, never unbounded memory)
- `request(io, gpa, req)` — one bounded round trip to `<host>:<port>` (empty host = 127.0.0.1); never blocks past `timeout_s`
- `readResponse(r, gpa, cap)` — the framing parser (status line, headers, Content-Length / chunked / read-to-EOF), split from the socket so it unit-tests on fixed buffers
- `LoopbackUrl` + `parseLoopbackUrl(url)` — decompose a loopback plain-http URL for `request`; null for anything else (callers keep their fallback)

## Dependencies

- `std` only — `std.Io` sockets, `Io.Select` for the timeout race.

## Usage Context

Imported by `worker/llm.zig`, `worker/browser/host.zig`, `worker/run.zig`, `worker/mcp/discovery.zig`, `config/local_models.zig`, `main.zig`, and `cli.zig` — the shared client wherever the server talks plain HTTP to a loopback peer.

## Notable Implementation Details

- TWIN FILE contract: `desk/src/httpc.zig` is a byte-for-byte twin below the header (the desk and server are separate Zig packages by design, so they can't share a module without cross-package build wiring). Fix a bug in one → apply it to the other.
- The timeout race is kept cheap by `rt_done`: the sleeper sleeps in 200ms slices and exits as soon as the round trip finishes. Without it, every completed request left its losing timer asleep for the full timeout, pinning the Threaded pool at its async_limit — at which point `io.async` degrades to inline-on-caller: the freeze.
- Chunked framing wins over Content-Length per RFC 9112 §6.3; chunk sizes are overflow-safe (a hostile hex size is a clean `BadResponse`, not a ReleaseSafe trap); no declared framing falls back to capped read-to-EOF.
- `parseLoopbackUrl` accepts `127.0.0.1`, `localhost`, and `0.0.0.0` (INADDR_ANY also listens on IPv4 loopback) but deliberately rejects `[::1]` — dialing IPv4 loopback would mis-reach an IPv6-only listener, so it falls back to curl.
- On timeout the round trip may still complete with an allocated body between the timer firing and the cancel landing; the drain loop uses the result-returning cancel so that body is freed.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
