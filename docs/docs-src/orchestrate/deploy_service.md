# deploy_service

**File:** `src/orchestrate/deploy_service.zig`  
**Module:** `orchestrate`  
**Description:** Manages the deployment lifecycle: build, stage, rollout, health-check, rollback, and teardown of services and worker fleets.

---

## Purpose Summary

Manages the deployment lifecycle: build, stage, rollout, health-check, rollback, and teardown of services and worker fleets.

## Key Exports

- `DeployService` struct — deployment controller
- `deploy()` — run deployment
- `rollback()` — revert to prior version
- `DeploymentState` enum — pending, active, failed, rolled_back

## Dependencies

- `orchestrate/neuron_client` — agent coordination
- `orchestrate/control_writer` — state mutations
- `obs/audit_log` — audit trail

## Usage Context

Triggered by the admin API or CI/CD pipeline. Coordinates across multiple neurons for rolling deployments.

## Notable Implementation Details

Implements a canary strategy: rolls out to one neuron first, runs health checks, then proceeds with a configurable ramp. Automatic rollback on health-check failure.

---

*Documentation generated for nl-veil — deploy_service.zig source analysis.*
