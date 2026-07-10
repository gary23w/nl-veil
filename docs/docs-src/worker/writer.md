# writer

**File:** `src/worker/writer.zig`  
**Module:** `worker`  
**Description:** Output generation and formatting: produces structured responses, markdown output, code blocks, and report formatting for agent deliverables.

---

## Purpose Summary

Output generation and formatting: produces structured responses, markdown output, code blocks, and report formatting for agent deliverables.

## Key Exports

- `Writer` struct — output formatter
- `write(output)` — write formatted result
- `format_markdown()` — convert to markdown
- `WriterConfig` — output format and destination

## Dependencies

- `worker/commons` — config types
- Standard library: io, formatting

## Usage Context

Called by AGI worker and RSI engine to produce formatted outputs, reports, and deliverables.

## Notable Implementation Details

Supports multiple output formats (markdown, plaintext, JSON). Uses Zig's `std.fmt` for type-safe formatting. Large outputs are streamed rather than buffered entirely.

---

*Documentation generated for nl-veil — writer.zig source analysis.*
