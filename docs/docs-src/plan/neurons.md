# neurons

**File:** `src/plan/neurons.zig`  
**Module:** `plan`  
**Description:** Defines neuron resource models — CPU, memory, storage, and concurrency limits per plan tier — used for capacity planning and quota enforcement.

---

## Purpose Summary

Defines neuron resource models — CPU, memory, storage, and concurrency limits per plan tier — used for capacity planning and quota enforcement.

## Key Exports

- `Neuron` struct — resource spec
- `NeuronPlan` — tier definition
- `allocate()` — compute resource budget
- `validate_quota()` — check against limits

## Dependencies

- (standalone — defines resource model types)
- Standard library: math

## Usage Context

Referenced by entitlements and deploy_service during resource allocation. Configuration loaded at startup.

## Notable Implementation Details

Resource limits are enforced at the OS level (cgroups) when available. Soft limits trigger warnings; hard limits enforce caps.

---

*Documentation generated for nl-veil — neurons.zig source analysis.*
