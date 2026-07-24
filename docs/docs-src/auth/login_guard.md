# login_guard

**File:** `src/auth/login_guard.zig`  
**Module:** `auth`  
**Description:** Per-IP login throttle — MAX_FAILS failed logins from one IP within a sliding window locks it out for LOCK_SECS.

---

## Purpose Summary

A small brute-force brake on the login route. Each source IP gets a record of failed attempts; 5 failures within a 300-second window lock that IP out of login for 300 seconds. State is one mutex-guarded in-memory map keyed by the raw IP bytes — nothing is persisted, so a restart forgives everyone.

## Key Exports

- `LoginGuard.init` — construct with allocator + io
- `LoginGuard.allowed` — is this IP currently allowed to attempt login (no record, or lock expired)
- `LoginGuard.fail` — count one failed attempt; resets the window after 300s of quiet, arms `locked_until` on the 5th fail
- `LoginGuard.success` — a successful login erases the IP's record entirely

## Dependencies

- Std only: `std.Io.net.IpAddress` (the key — 4 bytes for v4, 16 for v6), `std.Io.Mutex`, `std.Io.Timestamp` for the clock

## Usage Context

Constructed in `main.zig` and carried on the `App` as `app.login_guard`. Its only caller is `auth_api.login`: `allowed` is checked before credentials are touched (429 when locked), `fail` on bad credentials, `success` on a good login.

## Notable Implementation Details

- The constants are private and fixed: `WINDOW_SECS=300`, `MAX_FAILS=5`, `LOCK_SECS=300`. There is no config struct.
- Throttling is per-IP, not per-account — a distributed attacker is not slowed, and one noisy NAT can lock out its neighbors for five minutes.
- The window is coarse-sliding: `window_start` resets when the gap since it exceeds 300s, rather than tracking individual attempt timestamps.
- `success` freeing the record means lockout history never accumulates for legitimate users; the map only holds currently-failing IPs.

---

*Case file grounded in the module's `//!` header and public API.*
