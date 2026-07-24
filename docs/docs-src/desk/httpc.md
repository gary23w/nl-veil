# httpc

**File:** `desk/src/httpc.zig`  
**Module:** `desk`  
**Description:** An in-process, timeout-bounded HTTP/1.1 client over raw loopback sockets that replaces the curl.exe subprocess for veil-desk's local server and Ollama traffic.

---

## Purpose Summary

Performs a single bounded HTTP/1.1 round trip to 127.0.0.1:<port> without spawning a child process. It exists to kill the old `curl.exe` spawn pattern — bearer token and JSON body on the command line (readable by any same-user process) plus a self-built binary forking curl to POST at localhost on the poller's cadence, which Defender's behavior/ML models flagged and killed. It simultaneously fixes the "casting hangs" bug of the earlier raw-socket attempt by parsing real HTTP framing and enforcing a hard total-time ceiling.

## Key Exports

- `request(io, gpa, req) Result` — one bounded HTTP/1.1 round trip (connect+send+recv) to 127.0.0.1:req.port; never blocks past req.timeout_s.
- `Result` — union(enum){ ok: Resp, refused, timed_out, failed } preserving curl-era triage (refused≈exit 7, timed_out≈exit 28, failed=transient/retryable).
- `Req` — request spec: method, port, path, bearer (in-process only), optional JSON body, timeout_s hard ceiling, cap (default 1<<20 body-byte limit).
- `Resp` — { status: u16, body: []u8 } where body is gpa-owned and the caller frees it when len>0.
- `readResponse(r, gpa, cap) error{BadResponse}!Resp` — socket-independent HTTP response parser (status line, headers, Content-Length / chunked / read-to-EOF); unit-tested against fixed buffers.
- `parseLoopbackUrl(url) ?LoopbackUrl` — splits an `http://127.0.0.1|localhost[:port][/base]` URL into { port, path }; null for https/remote/non-loopback.
- `LoopbackUrl` — { port: u16, path: []const u8 } (path is the base prefix without trailing slash).

## Dependencies

- std
- std.Io (Io.Select racing, Io.net.IpAddress loopback connect/stream, Io.Reader framing, Io.Writer.Allocating request building, io.sleep)
- std.ascii (case-insensitive header/host matching)
- TWIN: src/worker/httpc.zig — byte-for-byte duplicate in the separate server package; bug fixes must be applied to both

## Usage Context

Called by veil-desk's netcli layer for every request to the local veil server (:8787) and a local Ollama (:11434) — the poller's few-second cadence, chat/cast POSTs carrying the bearer token, GET/DELETE ops. netcli maps the Result variants back onto the curl-era retry triage it already had (fail-fast on refused/timed_out, retry failed when idempotent). parseLoopbackUrl gates whether a configured endpoint URL is eligible for this client at all; non-loopback or https URLs fall back to the caller's other path.

## Notable Implementation Details

Concurrency: `request` uses `Io.Select` to race two async tasks — the actual `roundTrip` and a `sleeper(timeout_s)`. The round trip is spawned FIRST deliberately: if the Io backend is out of concurrency and runs a task inline, it degrades to an unwatched-but-framing-bounded request rather than eating the full timeout before connecting. `timeout_s` is a hard ceiling on the entire connect+send+recv, equivalent to `curl --max-time`; cancellation reaches a blocked read on every backend (on Windows the Threaded Io cancels the pending AFD receive), so a wedged server surfaces as `.timed_out` not a frozen thread. Subtle ownership gotcha handled by `drain`: on timeout the round trip can still COMPLETE with an allocated body in the window between the timer firing and the cancel landing, so drain uses the result-returning cancel loop (not cancelDiscard) to free that orphan body. There is intentionally NO connect timeout option — this Zig's Windows backend panics on one (netConnectIpWindows TODO) and loopback connects resolve immediately, so the Select sleeper bounds everything else. Fixed buffers: 4096-byte write buffer; 16 KiB read buffer that must hold each header LINE (takeDelimiter is capacity-bounded) while body bytes merely stream through it. Framing state machine in readResponse: parses the status line, accumulates headers, then chooses body framing by REAL framing — chunked wins over Content-Length per RFC 9112 §6.3, else Content-Length (rejected if > cap, and a short/truncated body is BadResponse), else read-to-EOF capped (Connection: close). readChunked strips `;`-extensions, parses hex sizes, verifies each chunk's trailing CRLF (mismatch = desync = BadResponse), and drains trailers. Any framing violation is an error the caller maps to a bounded failure rather than guessing at a truncated body. A key parsing detail: it uses `takeDelimiter('\n')` (which consumes the newline) not the Exclusive variant (which would leave every subsequent line read empty). Every request sends `Connection: close`; the bearer is emitted as an `Authorization: Bearer` header only in-process, never as argv. The file ships with 7 tests exercising the framing parser, URL splitter, and exact request bytes on fixed buffers with no sockets.

---

*Case file grounded in the module's `//!` header and public API.*
