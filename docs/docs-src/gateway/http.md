# http

**File:** `src/gateway/http.zig`  
**Module:** `gateway`  
**Description:** The HTTP gateway and router: parses incoming requests, applies middleware (auth, logging, CORS), dispatches to handlers, and formats responses.

---

## Purpose Summary

The HTTP gateway and router: parses incoming requests, applies middleware (auth, logging, CORS), dispatches to handlers, and formats responses.

## Key Exports

- `Gateway` struct — server container
- `listen()` — starts accepting connections
- `middleware_pipeline()` — composes middleware stack
- `Router` — path-based request dispatch

## Dependencies

- `auth/auth_core` — auth middleware
- `config/key_vault` — TLS/SSL config
- Standard library: http, net, tls

## Usage Context

Sits at the ingress boundary. All external HTTP traffic passes through the gateway before reaching handler modules.

## Notable Implementation Details

Implements a trie-based router for O(1) path matching. Middleware is composed as a linked chain. Supports HTTP/2 and graceful shutdown.

---

*Documentation generated for nl-veil — http.zig source analysis.*
