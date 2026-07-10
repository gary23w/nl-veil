# login_guard

**File:** `src/auth/login_guard.zig`  
**Module:** `auth`  
**Description:** Middleware that enforces rate limiting, brute-force detection, and suspicious-pattern blacklisting on login endpoints to prevent credential-stuffing attacks.

---

## Purpose Summary

Middleware that enforces rate limiting, brute-force detection, and suspicious-pattern blacklisting on login endpoints to prevent credential-stuffing attacks.

## Key Exports

- `LoginGuard` struct — rate-limit state
- `guard()` — middleware check
- `LoginGuardConfig` — threshold, window, cooldown settings

## Dependencies

- `gateway/http` — middleware request context
- Standard library: time, collections

## Usage Context

Applied as middleware to authentication endpoints. Runs on every login attempt.

## Notable Implementation Details

Employs a token-bucket algorithm per IP. Squaks on coordinated attacks via shared counters when Redis is available.

---

*Documentation generated for nl-veil — login_guard.zig source analysis.*
