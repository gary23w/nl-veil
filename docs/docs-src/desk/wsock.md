# wsock

**File:** `desk/src/wsock.zig`  
**Module:** `desk`  
**Description:** The desk package's copy of the server's blocking Winsock round trip, which the desk's httpc uses on Windows for loopback and IPv4-literal hosts so those requests never park a desk thread on the Io runtime's thread alert.

---

## Purpose Summary

The 2026-09-02 freeze happened in the desk: the chat pane stopped mid-turn with "working." on screen while the server stayed healthy, and a stack scan found the desk's poller and chat threads parked in the Io runtime's Windows sleep, on their per-thread alert, with no timeout in effect. httpc's portable path bounds every request with a race on that runtime (two tasks, an await that parks on the alert, a cancel of the loser), and those threads made that round trip up to thirty times a second. This file sends the request on one blocking Winsock socket with `SO_RCVTIMEO` / `SO_SNDTIMEO` as the ceiling, so there is no task, no alert and nothing to cancel. The desk's loop sleeps moved off the same primitive through `nap.zig`.

## Key Exports

- `ip4Of(host)` — `""` or `"localhost"` gives 127.0.0.1, an IPv4 literal gives its bytes, and a DNS name or malformed literal gives null
- `Outcome` — `ok: []u8 | refused | timed_out | failed`; `ok` is the raw response, headers and body, owned by the caller
- `roundTrip(gpa, ip, port, request, timeout_s, cap)` — one blocking round trip read to the peer's close; `.failed` on any OS but Windows

## Dependencies

- `std`, `builtin` — nothing else from the desk package
- `ws2_32` — eight locally declared Winsock externs (this std ships no Winsock bindings); `ntdll.RtlGetSystemTimePrecise` for the deadline clock
- TWIN: `src/worker/wsock.zig` — the server package's copy

## Usage Context

Imported only by `desk/src/httpc.zig`, whose `request` takes this path on Windows whenever `ip4Of(req.host)` returns an address and then parses the raw bytes with its own `readResponse`. The desk reaches it through `netcli.zig`'s `httpReq`, which dials the host from Settings (`netcli.setHost`, re-copied by the poller each tick; empty means loopback), and through `chat.zig`'s Ollama probes `fetchOllamaModels` (`/api/tags`, 5 s) and `loadedLocalCtx` (`/api/ps`, 4 s) on the loopback default. A remote veil host written as an IPv4 literal takes the blocking-socket path too; a DNS name keeps the portable `Io.Select` race, the residual the v1.1.0 release notes name.

## Notable Implementation Details

- TWIN, and how it stays one: the file is byte-identical to `src/worker/wsock.zig`, header included, so its header still speaks for both packages ("the server's self-calls, the CLI"). Unlike httpc.zig, neither copy carries a TWIN FILE note, and the drift scan in `scripts/check.ps1 -Scan` and `scripts/check.sh --scan` compares only the httpc.zig pair, bodies below the `//!` header. An edit to one wsock.zig raises no signal; only a change to one httpc.zig's call site does.
- That httpc signal is how this copy arrived. Commit 9ced18a added wsock.zig and the Windows branch to the server's httpc only; the httpc twin-drift signal stayed red until the v1.1.0 release commit (7018e79) ported wsock.zig into `desk/src` and mirrored the httpc body.
- Behavior matches the server copy exactly: `WSAStartup(0x0202)` on first use behind an atomic flag, never cleaned up; `setsockopt` results ignored; a failed `connect` is `.refused` only for `WSAECONNREFUSED`; a failed `send`/`recv` is `.timed_out` only for `WSAETIMEDOUT`; the wall-clock deadline starts after `connect` and is checked between calls, so one blocked `recv` can overrun it by up to `timeout_s`.
- No HTTP framing: the reply ends when `recv` returns 0, which depends on httpc's `Connection: close` and the server closing after the response. The reply is accumulated through a 16 KiB chunk, and more than `cap` + 256 KiB is `.failed`.
- netcli keeps its curl-era triage over these outcomes: `refused` and `timed_out` fail fast, `failed` is retried for idempotent requests. A `connect` that fails for any reason but refusal, a connect timeout to a remote literal included, arrives as `.failed`, so a GET or DELETE retries it.
- `desk/src/tests.zig` does not list this file, and its header says tests in unlisted files never run. The same two tests (`ip4Of` parsing, the 16-byte `sockaddr_in` layout) run in the server suite, where `src/tests.zig` registers `worker/wsock.zig`.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
