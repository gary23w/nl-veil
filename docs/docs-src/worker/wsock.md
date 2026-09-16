# wsock

**File:** `src/worker/wsock.zig`  
**Module:** `worker`  
**Description:** A blocking Winsock HTTP round trip bounded by socket-level send and receive timeouts, which httpc uses on Windows for loopback and IPv4-literal hosts instead of racing the request against a timer on the Io runtime.

---

## Purpose Summary

httpc's portable path bounds a request by running it and a sleeper as two tasks on the Io runtime's pool, awaiting the first to finish, and cancelling the loser. The await parks the calling thread on its per-thread alert (`NtWaitForAlertByThreadId` on Windows), one bit shared by everything on that thread: the runtime's mutexes, conditions, sleeps and awaits, and Windows' own SRW locks and `WaitOnAddress` inside any system call. On 2026-09-02 the desk's poller and chat threads were found parked in the runtime's sleep with no timeout in effect, hours into a session, while the server in the same process kept answering in milliseconds. `desk/src/nap.zig` moved the desk's loop sleeps off that primitive; this file takes the request itself off the runtime: one blocking socket, `SO_RCVTIMEO` / `SO_SNDTIMEO` for the ceiling, no tasks, no alerts, nothing to cancel. The header notes this is the model httpz uses for its own blocking worker.

## Key Exports

- `ip4Of(host)` — `""` or `"localhost"` gives 127.0.0.1, a dotted-quad IPv4 literal gives its four bytes, and anything else (a DNS name, a malformed literal) gives null: not this module's to resolve
- `Outcome` — `ok: []u8 | refused | timed_out | failed`; `ok` is the whole raw response, headers and body, owned by the caller
- `roundTrip(gpa, ip, port, request, timeout_s, cap)` — send pre-built request bytes on one blocking socket and read until the peer closes

## Dependencies

- `std`, `builtin` — no other repo modules
- `ws2_32` — eight Winsock functions (`WSAStartup`, `socket`, `connect`, `setsockopt`, `send`, `recv`, `closesocket`, `WSAGetLastError`) with their constants and `sockaddr_in`, all declared locally because this std ships no Winsock bindings; its sockets are AFD handles that Winsock's `recv`/`send` would not accept
- `std.os.windows.ntdll.RtlGetSystemTimePrecise` — the clock behind the wall-clock deadline

## Usage Context

Imported only by `worker/httpc.zig`. On Windows, `httpc.request` builds the request bytes and, whenever `wsock.ip4Of(req.host)` returns an address, calls `roundTrip`, runs its own `readResponse` framing parser over the raw bytes, and maps `refused` / `timed_out` / `failed` straight onto its `Result`; a DNS name keeps the portable `Io.Select` race. No server-package caller sets `Req.host`, so on Windows every server-side httpc request takes this path: `main.zig`'s Ollama and health probes, `cli.zig`, `llm.zig`, `run.zig`, `modelpull.zig`, `browser/ext.zig`, `browser/host.zig`, `mcp/discovery.zig` and `config/local_models.zig`. Registered directly in `src/tests.zig`.

## Notable Implementation Details

- `roundTrip` returns `.failed` immediately on any OS other than Windows; httpc only reaches it inside a Windows branch.
- `WSAStartup(0x0202)` runs on first use behind an atomic flag. The flag is not a once-guard, so two threads can both call it; Winsock reference-counts startup, and `WSACleanup` is never called.
- `timeout_s` is applied as `SO_RCVTIMEO` and `SO_SNDTIMEO` in milliseconds (clamped to `u32`), and the `setsockopt` results are ignored. The wall-clock deadline starts after `connect` returns and is checked between calls, so one blocked `recv` can run up to another `timeout_s` past it.
- Outcome mapping: a failed `connect` is `.refused` only for `WSAECONNREFUSED` and `.failed` otherwise; a failed `send` or `recv` is `.timed_out` only for `WSAETIMEDOUT` and `.failed` otherwise; passing the deadline is `.timed_out`.
- There is no HTTP framing here. The response is complete only when `recv` returns 0, which relies on the `Connection: close` httpc sends and on the server closing after the reply; a peer that keeps the socket open turns a complete reply into `.timed_out`.
- The response is accumulated through a 16 KiB stack chunk, and more than `cap` + 256 KiB (an allowance for headers) is `.failed`. httpc's parser then allocates its own copy of the body, so a large reply is briefly held twice. Sends go in slices of at most 1 GiB to fit Winsock's `i32` length.
- `ip4Of` requires exactly four dot-separated parts of 1–3 digits, each parsing as a `u8`: `300.1.1.1`, `1..2.3`, `1.2.3` and `1.2.3.4.5` are all null.
- TWIN: `desk/src/wsock.zig` is a byte-identical copy, header included. No drift check covers the pair (see that case file).
- The two tests use no sockets: `ip4Of` on the loopback defaults, literals, names and malformed input; and `sockaddr_in` as the 16-byte wire layout with `AF_INET` first and the port in network byte order.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
