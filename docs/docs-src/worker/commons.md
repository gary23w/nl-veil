# commons

**File:** `src/worker/commons.zig`  
**Module:** `worker`  
**Description:** Shared utilities used across the worker module: logging helpers, error types, timing utilities, and common data structures.

---

## Purpose Summary

Shared utilities used across the worker module: logging helpers, error types, timing utilities, and common data structures.

## Key Exports

- `WorkerConfig` — shared configuration type
- `Result` / `Error` — common result type
- `log()` — structured logging helper
- `Timer` — performance measurement utility

## Dependencies

- (standalone — foundational utilities)
- Standard library: time, io, log

## Usage Context

Linked by every file in the worker module. Provides shared infrastructure.

## Notable Implementation Details

Uses Zig's comptime to generate specialized logging paths per caller module. Error types implement the standard error interface.

---

*Documentation generated for nl-veil — commons.zig source analysis.*
