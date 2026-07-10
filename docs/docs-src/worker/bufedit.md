# bufedit

**File:** `src/worker/bufedit.zig`  
**Module:** `worker`  
**Description:** In-memory buffer editor for file manipulation — supports insert, delete, replace, and diff operations on text buffers before writing to disk.

---

## Purpose Summary

In-memory buffer editor for file manipulation — supports insert, delete, replace, and diff operations on text buffers before writing to disk.

## Key Exports

- `Buffer` struct — in-memory editable text
- `insert(pos, text)` — insert at position
- `delete(range)` — remove range
- `replace(old, new)` — find-and-replace
- `diff()` — compute diff vs current state

## Dependencies

- `worker/commons` — shared types
- Standard library: string manipulation, diff algorithm

## Usage Context

Used by RSI, writer, and any module that needs to programmatically modify files.

## Notable Implementation Details

Operates on a rope data structure for O(log n) insertions and deletions. The diff engine uses Myers' algorithm for minimal diffs.

---

*Documentation generated for nl-veil — bufedit.zig source analysis.*
