# supervisor

**File:** `src/orchestrate/supervisor.zig`  
**Module:** `orchestrate`  
**Description:** Agent supervisor that monitors worker health, restarts failed agents, manages lifecycle, and coordinates graceful shutdown.

---

## Purpose Summary

Agent supervisor that monitors worker health, restarts failed agents, manages lifecycle, and coordinates graceful shutdown.

## Key Exports

- `Supervisor` struct — agent lifecycle manager
- `spawn_agent()` — start worker
- `monitor_health()` — periodic health checks
- `shutdown()` — graceful stop all agents

## Dependencies

- `orchestrate/neuron_client` — agent comms
- `orchestrate/deploy_service` — deploy coordination
- `obs/audit_log` — lifecycle events

## Usage Context

Runs as a background daemon within the orchestration layer. Monitors all registered agents.

## Notable Implementation Details

Uses exponential-backoff restarts with a max-delay cap. Keeps a ring buffer of recent agent state for post-mortem analysis.

---

*Documentation generated for nl-veil — supervisor.zig source analysis.*
