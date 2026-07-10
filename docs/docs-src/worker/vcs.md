# vcs

**File:** `src/worker/vcs.zig`  
**Module:** `worker`  
**Description:** Version-control integration: clone, pull, commit, push, branch management, and diff generation against remote git repositories.

---

## Purpose Summary

Version-control integration: clone, pull, commit, push, branch management, and diff generation against remote git repositories.

## Key Exports

- `Vcs` struct — git integration
- `clone(url)` — clone repository
- `commit(message)` — commit changes
- `push()` — push to remote
- `diff()` — working tree diff

## Dependencies

- `worker/commons` — shared types
- Standard library: process execution (git), io, path manipulation

## Usage Context

Used by RSI (to commit changes), writer (to sync outputs), and admin (for system updates).

## Notable Implementation Details

Shells out to the system `git` binary. Operations are retried with exponential backoff on network failures. Commit messages are formatted with structured metadata for traceability.

---

*Documentation generated for nl-veil — vcs.zig source analysis.*
