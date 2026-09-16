# portprobe

**File:** `src/worker/portprobe.zig`  
**Module:** `worker`  
**Description:** Whether a TCP port is already held on this machine, answered on Windows by one exclusive dual-stack bind that no holder can share, since neither std's listen nor httpz's SO_REUSEADDR ever fails with AddressInUse there.

---

## Purpose Summary

A bind that fails with AddressInUse is how a program usually learns a port is taken, and on Windows neither binder in this tree ever fails that way. Zig 0.16's `std.Io.net.IpAddress.listen` binds through AFD with `BIND_INFO.Mode = .Passive`, AFD's address-reuse share type, and the vendored httpz listener sets `SO_REUSEADDR`, which on Windows shares the port with whoever holds it. Measured on 2026-09-16: a second std listen on a held loopback port succeeds, in the same process or another one. The built-in engine endpoint's probe-bind and the Ollama test's default-port takeover both read a held port as free, and two processes served one port.

The probe is one throwaway Winsock socket: AF_INET6 with `IPV6_V6ONLY` off (dual-stack), `SO_EXCLUSIVEADDRUSE` on, bound to `[::]:port` and closed without listening. An exclusive wildcard bind is refused by any socket already bound to that port on any local address, and the dual-stack socket carries that across both families. It was the only bind refused by every holder measured: std listens on 127.0.0.1 and 0.0.0.0, and Winsock sockets in each share mode (default, `SO_REUSEADDR`, `SO_EXCLUSIVEADDRUSE`) on 127.0.0.1, 0.0.0.0, dual-stack `[::]`, IPv6-only `[::]` and `[::1]`. POSIX keeps the throwaway std listen on 127.0.0.1 every caller already made, because a POSIX listen on a held port does fail.

## Key Exports

- `held(io, port) bool` — true when something holds TCP `port`. False when the probe cannot run at all (no Winsock), so a caller falls back to attempting the bind itself.

## Dependencies

- `std`, `builtin` — no other repo modules
- `ws2_32` — `WSAStartup`, `socket`, `setsockopt`, `bind`, `closesocket` and `WSAGetLastError`, with their constants and both `sockaddr` layouts, all declared locally because this std ships no Winsock bindings (its sockets are AFD handles). The tests add `listen` and `getsockname`.
- `iphlpapi` — `GetTcpTable`, tests only, to prove a TIME_WAIT setup landed

## Usage Context

- `worker/builtin_endpoint.zig` `tryStart` asks before building each httpz server, so a pinned `NL_BUILTIN_PORT` another socket holds is refused (`error.NoFreePort`) and the 8788..8797 scan moves past a held port instead of sharing it.
- `config/local_models.zig`'s tests ask before a stand-in takes over Ollama's default port 11434, so a live Ollama or another suite's stand-in keeps it.

Not used by `worker/browser/broker.zig`, which needs no fixed port and listens on port 0 instead. Not used in front of the main server's 8787 listen either. Registered directly in `src/tests.zig`.

## Notable Implementation Details

- A narrower probe misses real holders. An IPv4 exclusive bind on 127.0.0.1 misses a 0.0.0.0 holder. Every IPv4 bind, even exclusive on 0.0.0.0, misses a dual-stack `[::]` socket, which is what a Go or Node server on a wildcard address opens. That socket still answers 127.0.0.1, and an IPv4 127.0.0.1 listener next to it took 8 of 8 loopback connections (measured).
- `WSAEADDRINUSE` (10048) and `WSAEACCES` (10013, returned against an exclusive holder) both mean held. Any other failure is unknown, and so is a failed socket or `setsockopt`. An unknown dual-stack result retries as an IPv4 wildcard exclusive bind, which still sees every IPv4 holder. Unknown after both is reported as not held.
- It never listens. A socket bound to a wildcard address and not listened on raised no Windows Firewall prompt (measured), while a wildcard listen raises one for every executable path the firewall has not seen before.
- TIME_WAIT is not held: after a listener's server-side active close, with twenty TIME_WAIT rows on the port and the listener closed, every bind kind still bound it, exclusive ones included. A server restarted right after serving is never refused. A closed listener's accepted connection that is still open does not count either.
- Rejected, a connect probe: a refused loopback connect takes about 2 s on Windows (the SYN is retried), per candidate port, and it only sees listeners reachable over IPv4 loopback.
- `WSAStartup(0x0202)` runs once behind an atomic flag, the pattern `wsock.zig` uses. Winsock reference-counts startup, and `WSACleanup` is never called.
- The answer is a snapshot: something can take the port between the probe and the caller's own bind. `builtin_endpoint.zig` accepts that race on loopback.
- Tests (every port is OS-assigned; a fixed port may belong to something live): eight std listeners are all held twice over and all free once closed. A second std listen on each held port succeeds 8 of 8 on Windows and 0 of 8 on POSIX, priced beside `held` seeing 8 of 8. On Windows, `held` sees 4 of 4 holders (httpz-shaped `SO_REUSEADDR` on 127.0.0.1 listening, `SO_REUSEADDR` and plain binds on 0.0.0.0, a dual-stack `[::]` socket), where the old std-listen probe sees 0 and the IPv4 fallback sees 3 and reports the dual-stack socket free. TIME_WAIT rows left by server-first closes are counted through `GetTcpTable` before the port is asserted free. Wildcard holders in tests bind without listening, so a test run raises no firewall prompt.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
