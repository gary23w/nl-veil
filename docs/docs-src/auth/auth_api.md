# auth_api

**File:** `src/auth/auth_api.zig`  
**Module:** `auth`  
**Description:** Defines HTTP endpoints for authentication flows — login, logout, token refresh, and session validation — handling request parsing and response formatting.

---

## Purpose Summary

Defines HTTP endpoints for authentication flows — login, logout, token refresh, and session validation — handling request parsing and response formatting.

## Key Exports

- `login_handler()` — POST /auth/login
- `logout_handler()` — POST /auth/logout
- `refresh_handler()` — POST /auth/refresh
- `AuthApi` router setup

## Dependencies

- `auth/auth_core` — core auth logic
- `auth/login_guard` — rate-limit middleware
- `gateway/http` — HTTP types and routing

## Usage Context

Exposed to end-users and client applications. Sits behind the login guard middleware.

## Notable Implementation Details

Implements CSRF protection for cookie-based sessions. Token refresh uses rotating refresh tokens with a reuse-detection window.

---

*Documentation generated for nl-veil — auth_api.zig source analysis.*
