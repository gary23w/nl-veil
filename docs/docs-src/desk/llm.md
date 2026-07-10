# llm

**File:** `desk/src/llm.zig`  
**Module:** `desk`  
**Description:** The veil-desk desktop chat client: one OpenAI-compatible Provider shape (base_url + key + model) behind which local Ollama, BYOK cloud, or a custom endpoint all plug, driving a filesystem-first streaming request through curl and tailing the SSE/NDJSON response into an in-memory Stream.

---

## Purpose Summary

llm.zig is the desktop app's chat-model client. It exposes a single Provider interface (an OpenAI-compatible /chat/completions plus a local-Ollama native /api/chat path) and runs streaming completions entirely off the filesystem: curl writes the SSE/NDJSON stream to a scratch file and the chat thread tails it, folding token deltas into a Stream struct. It deliberately trades std.http for curl to inherit TLS and to mirror the engine's transport convention, and it carries a large tolerance for slow local backends plus recovery paths for Ollama's gpt-oss harmony tool-call parse errors.

## Key Exports

- `Provider` — the one provider shape: base_url (".../v1" root), key (empty = local, no Authorization), model
- `Stream` — the per-turn state machine/struct holding the curl child, out-path, byte offset, growable `carry` for partial lines, accumulated `content` and `reasoning` buffers, framing flags (native/saw_sse/saw_any), and done/failed/err state; with `errStr`/`reasoningStr`/`outPath`/`deinit` accessors
- `osEnviron()` — returns the real OS process.Environ (live PEB on Windows, libc environ on POSIX) that any Io running curl MUST carry or Winsock init fails
- `start()` — writes request/curl-config/sink scratch files, builds the native-or-OpenAI JSON body, and spawns curl streaming to the sink; returns false on any spawn/IO failure
- `poll()` — call ~10x/sec to consume new stream bytes, split off curl's STAT_MARK+HTTP-code sentinel, fold deltas into content, and enforce timeouts; flips s.done
- `abort()` / `finish()` — kill+reap the curl child (idempotent kill, never blocking wait) on cancel/timeout vs. normal completion
- `jsonUnescape()` — pub full JSON string unescaper (\n \t \" \uXXXX + surrogate pairs) reused by the chat thread to parse stored conversation lines

## Dependencies

- std (std.Io filesystem + std.process.Child/spawn, ArrayListUnmanaged, std.unicode, std.fmt)
- builtin (OS-tag branch for osEnviron: Windows PEB vs POSIX std.c.environ)
- log.zig (trace/info/err logging)
- external `curl` binary (HTTP transport, invoked with -sS -N --connect-timeout 20 --max-time -K cfg --data-binary @req -w STAT_MARK+%{http_code})
- engine parity constants mirrored from src/worker/llm.zig (OLLAMA_NUM_CTX=32768 must equal the worker's NATIVE_CTX; key-in-config-file convention)
- the .veil-desk sidecar dir supplied by the caller for scratch files (.chatreq.json, .chatcurlcfg, .chatstream.sse)

## Usage Context

Called only on veil-desk's CHAT thread. The chat UI builds the escaped messages_json (inner of \"messages\":[…]), calls start() once to launch a turn, then poll()s the Stream roughly ten times a second while rendering s.content (the reply) and s.reasoning (the thinking channel) live; on s.done it reads s.failed/errStr() and calls finish() (or abort() on user cancel/timeout). The `patient` flag is passed true when a cast/swarm is running on the same local backend so a long silent queue-wait isn't misread as failure. Local Ollama (127.0.0.1/localhost:11434) auto-routes to the native streaming NDJSON endpoint with engine-matched num_ctx so chat and swarm share one Ollama runner instead of thrashing reloads.

## Notable Implementation Details

Concurrency/transport: no threads and no non-blocking child wait — the only \"curl exited\" signal is curl's `-w` appending STAT_MARK (\"\\n__VEILSTAT__\") + a 3-digit HTTP code (000 on failed connect) to the same stream file poll() tails; poll splits that off (ignoring a partial marker until the full 3 digits land) and routes to finishNativeWhole (native) or finishBySentinel (OpenAI) to resolve immediately from the code instead of blindly waiting out timeouts. Child is reaped via kill() (terminates+reaps, idempotent) NEVER wait() — a blocking wait would hang the chat thread up to curl's --max-time if the endpoint holds the SSE socket open past [DONE]. State machine: the native NDJSON path is chosen up-front in start() from the URL (isLocalOllama), not from the stream bytes; consume() then decides SSE-vs-plain-JSON framing from the first non-whitespace bytes (SSE `data:`/`event:`/`:`, else a non-stream body deferred to tryWholeJson in poll()), and line-frames the SSE/NDJSON shapes keeping the trailing partial in `carry`. Critically `carry` is a GROWABLE ArrayList, not the old 16KB fixed buffer — a single delta line longer than the cap (a backend flushing the whole completion as one event) would otherwise drop its tail and splice a hole into the JSON; there's a dedicated 40000-char test for this. Tool-call recovery is the signature gotcha: Ollama's gpt-oss harmony parser emits {\"error\":\"error parsing tool call: raw='<text>', err=...\"} where the raw IS the model's intended reply; recoverToolCallRaw() extracts it (terminated by \"', err=\" or last quote) and appends it to content as a SUCCESS rather than failing the turn — handled in both the streaming line handler and the whole-body finisher, uncapped. extractErr() keys on the VALUE after \"error\": (returns null on `null`/empty/number) so the many OpenAI-compatible stacks that ship \"error\":null on SUCCESS aren't wrongly failed. Reasoning channel is unified across backends: NDJSON \"thinking\", DeepSeek \"reasoning_content\", and OpenRouter/HF \"reasoning\" all fold into s.reasoning (the exact-key order matters so \"reasoning\" doesn't false-match \"reasoning_content\"). Timeouts are generous by design (300s first-byte / 900s while patient / 300s stall / 900s total) because a cold 20B load or being queued behind the swarm on one GPU is normal. finishNativeWhole/finishBySentinel only extract from the whole body when nothing streamed, to avoid duplicating deltas already buffered. Helper fns errBodyHead and extractErr write into module-level static scratch buffers (body_head_buf, err_scratch); jsonStrInto writes into a caller-supplied buffer (extractErr hands it err_scratch) — all fine because everything runs single-threaded on the chat thread. The parser is pure over byte chunks, so the 12 tests exercise it with no network.

---

*Documentation generated for nl-veil — desk/llm.zig source analysis.*
