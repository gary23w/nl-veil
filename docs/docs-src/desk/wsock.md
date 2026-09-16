# wsock

**File:** `desk/src/wsock.zig`  
**Module:** `desk`  
**Description:** The desk package's copy of the server's blocking Winsock round trip under one wall-clock deadline, which the desk's httpc uses on Windows for loopback and IPv4-literal hosts so those requests never park a desk thread on the Io runtime's thread alert.

---

## Purpose Summary

The 2026-09-02 freeze happened in the desk: the chat pane stopped mid-turn with "working." on screen while the server stayed healthy, and a stack scan found the desk's poller and chat threads parked in the Io runtime's Windows sleep, on their per-thread alert, with no timeout in effect. httpc's portable path bounds every request with a race on that runtime (two tasks, an await that parks on the alert, a cancel of the loser), and those threads made that round trip up to thirty times a second. This file sends the request on one blocking Winsock socket instead, with no task, no alert and nothing to cancel, and bounds the whole exchange, connect included, by `timeout_s`. The desk's sleeps moved off the same primitive through `nap.zig`.

## Key Exports

- `ip4Of(host)` — `""` or `"localhost"` gives 127.0.0.1, an IPv4 literal gives its bytes, and a DNS name or malformed literal gives null
- `Outcome` — `ok: []u8 | refused | timed_out | failed`; `ok` is the raw response, headers and body, owned by the caller
- `roundTrip(gpa, ip, port, request, timeout_s, cap)` — one blocking round trip read to the peer's close, all of it inside `timeout_s`; `.failed` on any OS but Windows

## Dependencies

- `std`, `builtin` — nothing else from the desk package
- `ws2_32` — eleven locally declared Winsock externs (this std ships no Winsock bindings), plus `bind`, `listen`, `accept` and `getsockname` for the tests' loopback peer; `ntdll.RtlGetSystemTimePrecise` for the deadline clock
- TWIN: `src/worker/wsock.zig` — the server package's copy

## Usage Context

Imported by `desk/src/httpc.zig`, whose `request` takes this path on Windows whenever `ip4Of(req.host)` returns an address and then parses the raw bytes with its own `readResponse`; registered directly in `desk/src/tests.zig`. The desk reaches it through `netcli.zig`'s `httpReq`, which dials the host from Settings (`netcli.setHost`, re-copied by the poller each tick; empty means loopback), and through `chat.zig`'s Ollama probes `fetchOllamaModels` (`/api/tags`, 5 s) and `loadedLocalCtx` (`/api/ps`, 4 s) on the loopback default. A remote veil host written as an IPv4 literal takes the blocking-socket path too; a DNS name keeps the portable `Io.Select` race, the residual the v1.1.0 release notes name.

## Notable Implementation Details

- TWIN, and how it stays one: the file is byte-identical to `src/worker/wsock.zig`, header included, and its TWIN FILE note says so; the header prose speaks for both packages ("the server's self-calls, the CLI"). `scripts/check.ps1 -Scan` and `scripts/check.sh --scan` compare the two whole files, where the httpc.zig pair is compared below its `//!` header only. Before 2026-09-16 no signal covered wsock.zig at all.
- The httpc signal is how this copy arrived. Commit 9ced18a added wsock.zig and the Windows branch to the server's httpc only; the httpc twin-drift signal stayed red until the v1.1.0 release commit (7018e79) ported wsock.zig into `desk/src` and mirrored the httpc body.
- One deadline for the whole trip, taken before the socket is created. The connect runs non-blocking and `select` waits for the time left, because a blocking connect takes no timeout on Windows: about 2 s to learn a loopback port is refused, about 21 s against an address that drops SYNs. `SO_ERROR` gives the verdict and the socket goes back to blocking. Every `send` and `recv` then gets `SO_SNDTIMEO` / `SO_RCVTIMEO` set to the milliseconds still left (at least 1, since 0 means no timeout), and a deadline already passed is `.timed_out` before the call. Until 2026-09-16 the deadline started after `connect` and each call got the full `timeout_s`, so a reply that stalled near the deadline could hold the last `recv` for up to another `timeout_s`.
- Outcomes: a refused connect, immediate or reported through `select`, is `.refused`; a connect that the deadline ends, or that Windows itself times out, is `.timed_out`; a failed `send` or `recv` is `.timed_out` only for `WSAETIMEDOUT`; anything else is `.failed`, including a failed `ioctlsocket`, `select`, `getsockopt` or `setsockopt`. `WSAStartup(0x0202)` runs on first use behind an atomic flag and is never cleaned up.
- No HTTP framing: the reply ends when `recv` returns 0, which depends on httpc's `Connection: close` and the server closing after the response. The reply is accumulated through a 16 KiB chunk, and more than `cap` + 256 KiB is `.failed`.
- netcli keeps its curl-era triage over these outcomes: `refused` and `timed_out` fail fast, `failed` is retried for idempotent requests. A remote literal that never answers the connect is now `.timed_out` inside the request's ceiling; it used to come back `.failed` after ~21 s, which a GET then retried twice more.
- Tests: `ip4Of` parsing; the 16-byte `sockaddr_in` layout; `fd_set1` matching the head of Winsock's `fd_set`; and, on Windows only, three real-socket round trips against a one-connection loopback peer on an ephemeral port — a whole exchange, a peer that sends one byte at 1.5 s and then goes quiet (with `timeout_s` 2 the trip must end `.timed_out` between 1.9 s and 2.9 s, where per-call timeouts took ~3.5 s), and a connect to TEST-NET-1 (192.0.2.1) that must give up inside 1.8 s with `timeout_s` 1.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
