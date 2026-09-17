# wsock

**File:** `src/worker/wsock.zig`  
**Module:** `worker`  
**Description:** A blocking Winsock HTTP round trip under one wall-clock deadline that covers connect, send and receive, which httpc uses on Windows for loopback and IPv4-literal hosts instead of racing the request against a timer on the Io runtime.

---

## Purpose Summary

httpc's portable path bounds a request by running it and a sleeper as two tasks on the Io runtime's pool, awaiting the first to finish, and cancelling the loser. The await parks the calling thread on its per-thread alert (`NtWaitForAlertByThreadId` on Windows), one bit shared by everything on that thread: the runtime's mutexes, conditions, sleeps and awaits, and Windows' own SRW locks and `WaitOnAddress` inside any system call. On 2026-09-02 the desk's poller and chat threads were found parked in the runtime's sleep with no timeout in effect, hours into a session, while the server in the same process kept answering in milliseconds. `desk/src/nap.zig` moved the desk's sleeps off that primitive; this file takes the request itself off the runtime: one blocking socket, no tasks, no alerts, nothing to cancel, with `timeout_s` bounding the whole exchange. The header notes this is the model httpz uses for its own blocking worker.

## Key Exports

- `ip4Of(host)` — `""` or `"localhost"` gives 127.0.0.1, a dotted-quad IPv4 literal gives its four bytes, and anything else (a DNS name, a malformed literal) gives null: not this module's to resolve
- `Outcome` — `ok: []u8 | refused | timed_out | failed`; `ok` is the whole raw response, headers and body, owned by the caller
- `roundTrip(gpa, ip, port, request, timeout_s, cap)` — send pre-built request bytes on one blocking socket and read until the peer closes, all inside `timeout_s`

## Dependencies

- `std`, `builtin` — no other repo modules
- `ws2_32` — eleven Winsock functions (`WSAStartup`, `socket`, `connect`, `ioctlsocket`, `select`, `getsockopt`, `setsockopt`, `send`, `recv`, `closesocket`, `WSAGetLastError`) with their constants, `sockaddr_in`, a one-socket `fd_set` and `timeval`, all declared locally because this std ships no Winsock bindings; its sockets are AFD handles that Winsock's `recv`/`send` would not accept. The tests add `bind`, `listen`, `accept`, `getsockname` and kernel32 `Sleep` for a loopback peer.
- `std.os.windows.ntdll.RtlGetSystemTimePrecise` — the clock behind the deadline

## Usage Context

Imported only by `worker/httpc.zig`. On Windows, `httpc.request` builds the request bytes and, whenever `wsock.ip4Of(req.host)` returns an address, calls `roundTrip`, runs its own `readResponse` framing parser over the raw bytes, and maps `refused` / `timed_out` / `failed` straight onto its `Result`; a DNS name keeps the portable `Io.Select` race. No server-package caller sets `Req.host`, so on Windows every server-side httpc request takes this path: `main.zig`'s Ollama and health probes, `cli.zig`, `llm.zig`, `run.zig`, `modelpull.zig`, `browser/ext.zig`, `browser/host.zig`, `mcp/discovery.zig` and `config/local_models.zig`. Registered directly in `src/tests.zig`.

## Notable Implementation Details

- `roundTrip` returns `.failed` immediately on any OS other than Windows; httpc only reaches it inside a Windows branch.
- `WSAStartup(0x0202)` runs on first use behind an atomic flag. The flag is not a once-guard, so two threads can both call it; Winsock reference-counts startup, and `WSACleanup` is never called.
- One deadline, taken before the socket is created, bounds everything. The connect runs non-blocking (`ioctlsocket(FIONBIO)`) and `select` waits for the time left, because a blocking connect takes no timeout on Windows (`SO_SNDTIMEO` does not apply to it): about 2 s to learn a loopback port is refused, about 21 s against an address that drops SYNs. `getsockopt(SO_ERROR)` gives the verdict and the socket returns to blocking mode. Each `send` and `recv` then gets `SO_SNDTIMEO` / `SO_RCVTIMEO` set to the milliseconds still left (at least 1, since 0 means no timeout), and a deadline already passed is `.timed_out` before the call is made. Until 2026-09-16 the deadline started after `connect` and each call got the whole `timeout_s`, so one blocked `recv` could run up to another `timeout_s` past the deadline, and the connect was not bounded at all.
- Callers with a 2 s ceiling (`main.zig`'s health wait, `mcp/discovery.zig`'s port probe) sit right at the ~2 s it takes Windows to report a refused loopback connect, so a dead port can come back `.timed_out` rather than `.refused` there. Both treat every non-`ok` outcome alike. The callers that tell `.refused` apart are never given less than 6 s: `cli.zig`'s `call`, which starts the daemon on it, and `llm.zig`'s local-model POST, which words its error from it.
- Outcome mapping: a refused connect, immediate or reported through `select`, is `.refused`; a connect the deadline ends, or one Windows itself times out, is `.timed_out`; a failed `send` or `recv` is `.timed_out` only for `WSAETIMEDOUT`; anything else, a failed socket option included, is `.failed`.
- There is no HTTP framing here. The response is complete only when `recv` returns 0, which relies on the `Connection: close` httpc sends and on the server closing after the reply; a peer that keeps the socket open turns a complete reply into `.timed_out`.
- The response is accumulated through a 16 KiB stack chunk, and more than `cap` + 256 KiB (an allowance for headers) is `.failed`. httpc's parser then allocates its own copy of the body, so a large reply is briefly held twice. Sends go in slices of at most 1 GiB to fit Winsock's `i32` length.
- `ip4Of` requires exactly four dot-separated parts of 1–3 digits, each parsing as a `u8`: `300.1.1.1`, `1..2.3`, `1.2.3` and `1.2.3.4.5` are all null.
- TWIN: `desk/src/wsock.zig` is a byte-identical copy, header included, and the header's TWIN FILE note says so. `scripts/check.ps1 -Scan` and `scripts/check.sh --scan` compare the whole files.
- Tests: `ip4Of` on the loopback defaults, literals, names and malformed input; `sockaddr_in` as the 16-byte wire layout with `AF_INET` first and the port in network byte order; `fd_set1` matching the head of Winsock's `fd_set`; and, on Windows only, three round trips on real sockets against a one-connection loopback peer on an ephemeral port — a whole exchange; a peer that sends one byte at 1.5 s and then goes quiet, which with `timeout_s` 2 must end `.timed_out` between 1.9 s and 2.9 s (per-call timeouts took ~3.5 s); and a connect to TEST-NET-1 (192.0.2.1) that must give up inside 1.8 s with `timeout_s` 1.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
