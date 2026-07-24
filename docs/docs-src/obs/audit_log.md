# audit_log

**File:** `src/obs/audit_log.zig`  
**Module:** `obs`  
**Description:** Append-only, hash-chained audit log for privileged actions (plan changes, bans/deletes, force-kills).

---

## Purpose Summary

A JSONL file at `<data>/audit.log` where each line is `{seq, ts, actor, action, target, prev, hash}` and each `hash` is SHA-256 over the previous record's hash plus this record's fields (genesis prev = 64 zeros). `record()` appends under a mutex; `verify()` re-walks the whole file recomputing the chain. Editing or deleting a mid-file line breaks every hash after it, so tampering with history is detectable — this is tamper-evidence, not a queryable event store.

## Key Exports

- `AuditLog.init` — build the path, then `recover()`: read the last line to resume `seq` and `last_hash`, so the chain continues across restarts instead of forking
- `AuditLog.record` — append one `(actor, action, target)` record, chained to the last; best-effort — errors are swallowed so auditing never fails the admin action itself
- `AuditLog.verify` — recompute the chain over the whole file; returns the count of valid records or `AuditCorrupt` / `AuditChainBroken` / `AuditHashMismatch`
- `path` (field) — read directly by the dump route

## Dependencies

- Std only: `std.crypto.hash.sha2.Sha256`, `std.Io` file read/write, `std.json` for recover/verify parsing

## Usage Context

Constructed in `main.zig`, carried on the `App` as `app.audit`. The writers are the privileged mutation paths — `admin_service` records every admin action (`ban`/`delete`, `kill_swarm`, `create_user`, `set_server_key`, `set_default_model`, recipe grants, even `read_activity`). `adminAudit` (GET `/api/v1/admin/audit`) serves the raw file with `verify()`'s result in an `X-Audit-Integrity` header.

## Notable Implementation Details

- The chain input is `prev_hash || "|seq|ts|actor|action|target"` — reorder, edit, or drop any record and `verify` fails at that line.
- Tamper-*evident*, not tamper-*proof*: whoever can rewrite the whole file can rebuild a consistent chain; there is no external anchor.
- "Append" is implemented as read-whole-file + rewrite (64 MB cap) under the mutex — simple and safe at this log's write rate, not a high-throughput design. Writes are synchronous; there is no batching, and no query API beyond reading the file.
- `recover()` trusts only the last line for resumption; full validation is `verify()`'s job, invoked on demand.

---

*Case file grounded in the module's `//!` header and public API.*
