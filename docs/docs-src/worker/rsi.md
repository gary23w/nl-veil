# rsi

**File:** `src/worker/rsi.zig`  
**Module:** `worker`  
**Description:** Recursive Self-Improvement engine: generates, evaluates, and applies code patches to its own source to improve performance and capability over time.

---

## Purpose Summary

Recursive Self-Improvement engine: generates, evaluates, and applies code patches to its own source to improve performance and capability over time.

## Key Exports

- `RSIEngine` struct — self-improvement core
- `evaluate()` — assess current performance
- `generate_patch()` — propose code change
- `apply_patch()` — integrate change
- `rollback()` — revert last change if regression detected

## Dependencies

- `worker/llm` — code generation
- `worker/bufedit` — file editing
- `worker/vcs` — version control patches
- `obs/audit_log` — change tracking

## Usage Context

Runs as a periodic background task within the worker. Can be triggered manually via admin API.

## Notable Implementation Details

Each generated patch is tested in a sandbox before application. A regression suite runs automatically. If the patch decreases performance, it's rolled back and the failure is learned from.

---

*Documentation generated for nl-veil — rsi.zig source analysis.*
