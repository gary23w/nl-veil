# rate

**File:** `src/worker/rate.zig`  
**Module:** `worker`  
**Description:** Per-provider (host) outbound pacing for HOSTED LLM backends — a 429/503 cooldown every concurrent turn observes, plus an optional token-bucket requests-per-minute cap, sharing one small fixed host table.

---

## Purpose Summary

Two mechanisms, one table. When a provider returns 429/503, ALL in-flight turns to that host wait out the window instead of retrying in lockstep — a thundering herd just earns more 429s. Separately, an optional `NL_RATE_RPM` token bucket (default 0 = unlimited) paces bursts BEFORE they reach the provider. Local (loopback) backends never rate-limit, so callers skip this for them.

## Key Exports

- `configure(rpm_val)` — set the per-host requests-per-minute cap from `NL_RATE_RPM` at startup, once before serving; <= 0 = unlimited. The 429 cooldown is always active regardless — this only enables PROACTIVE bucket pacing
- `hostOf(base_url)` — the host[:port] of a base URL (scheme stripped, path/query dropped)
- `acquire(io, base_url)` — block until this host is clear to send (past any cooldown, and holding a bucket token when a cap is set), then consume a token
- `note429(io, base_url, retry_after_s)` — record a provider back-off signal; every subsequent acquire for the host waits out the (capped) window, so concurrent turns back off together

## Dependencies

- `std` only — `std.Io.Mutex` guards the process-global table; wall-clock ms drives both the cooldown and the bucket refill.

## Usage Context

`worker/llm.zig` is the caller on the hosted-LLM request path; `main.zig` wires `configure` at startup. With the default (no RPM cap, no active cooldown) `acquire` is a lock + two comparisons — no added latency.

## Notable Implementation Details

- State is process-global and mutex-guarded: a fixed 24-slot host table. A NEW host past the table (or a >110-byte name) simply no-ops — correctness never depends on pacing, worst case an unpaced 25th provider.
- Cooldowns: 429/503 with no Retry-After backs off 5s; an honored Retry-After is capped at 2 minutes; overlapping signals keep the furthest deadline.
- `acquire` is bounded so a mis-set clock or huge cooldown can't wedge a turn: one wait never sleeps longer than 30s, and it gives up (returning anyway) after 64 waits.
- The send/wait decision (`decide`) is factored pure — cooldown wins, then the token bucket, then clear — so the timing logic unit-tests without a clock; the bucket starts full and refills at `limit/60s` per ms.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
