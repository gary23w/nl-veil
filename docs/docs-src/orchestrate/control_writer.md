# control_writer

**File:** `src/orchestrate/control_writer.zig`  
**Module:** `orchestrate`  
**Description:** Writes control-plane state mutations — provisioning commands, configuration updates, and resource allocations — to the distributed state store.

---

## Purpose Summary

Writes control-plane state mutations — provisioning commands, configuration updates, and resource allocations — to the distributed state store.

## Key Exports

- `ControlWriter` struct — state mutation client
- `apply_change()` — writes a state diff
- `watch()` — watches for external changes
- `ControlWriterConfig` — consensus and timeout tuning

## Dependencies

- `orchestrate/neuron_client` — cluster communication
- `obs/audit_log` — audit recording
- Standard library: serialization

## Usage Context

Called by deploy_service, supervisor, and admin during state mutations. Writes to the distributed consensus store.

## Notable Implementation Details

Uses a Raft-consensus client for distributed writes. Writes are idempotent — retry is safe. Employs optimistic concurrency with version vectors.

---

*Documentation generated for nl-veil — control_writer.zig source analysis.*
