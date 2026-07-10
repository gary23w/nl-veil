# oscillation

**File:** `src/worker/oscillation.zig`  
**Module:** `worker`  
**Description:** Adaptive recursion engine that explores state spaces via oscillating exploration-exploitation cycles — used for self-play and strategy refinement.

---

## Purpose Summary

Adaptive recursion engine that explores state spaces via oscillating exploration-exploitation cycles — used for self-play and strategy refinement.

## Key Exports

- `Oscillator` struct — adaptive exploration engine
- `step()` — one exploration/exploitation cycle
- `state()` — current internal state
- `OscillationConfig` — amplitude, frequency, decay parameters

## Dependencies

- `worker/commons` — config types
- Standard library: math, random

## Usage Context

Used by AGI worker in self-play training mode and by RSI for exploration strategies.

## Notable Implementation Details

Implements a simulated annealing schedule for exploration temperature. The oscillation function is configurable (sine, sawtooth, random walk).

---

*Documentation generated for nl-veil — oscillation.zig source analysis.*
