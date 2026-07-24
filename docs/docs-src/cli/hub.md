# hub

**File:** `src/cli/hub.zig`  
**Module:** `cli`  
**Description:** `veil hub`, the fleet console — the old hub.py reimplemented over the server API instead of a second, out-of-band control plane.

---

## Purpose Summary

hub.py aggregated many machines over a bespoke sealed channel that bypassed the server entirely and drove deploy.py's local functions. This console leans on the fact that the running veil server already aggregates every swarm a user owns: `roster` prints the fleet summary (`/api/v1/fleet`) plus every swarm's id/state/minds/goal (`/api/v1/swarms`); `all`/`say` broadcasts a directive (`op:"say"`) to every swarm, `goal` sets a new goal (`op:"set_goal"`), `stopall` stops the fleet. Cross-machine aggregation (hub.py's multi-node roster) needs a dedicated server fleet endpoint and is intentionally left as a documented follow-up.

## Key Exports

- `run` — the verb dispatcher: `roster`/`ls`/`fleet` (default), `all`/`say`, `goal`, `stopall`, `help`. Takes the `call` HTTP function injected from cli.zig.

## Dependencies

- `../cli.zig` — `Ctx`, `CallFn`, `out`, and the `JsonObjs`/`jsonStr`/`jsonNum` JSON walkers for the swarm list

## Usage Context

Reached only through `cli.zig`'s `cmdHub` (the `veil hub` verb). All operations go through the injected `call`, so the console shares the CLI's auth (`.desktop_key` bearer) and server auto-start.

## Notable Implementation Details

- `broadcast` fans one control body out to every swarm the server lists (`POST /api/v1/swarms/:id/control`), counts sent vs failed, and exits 0 only when every swarm accepted.
- The help text states the boundary explicitly: today the console operates the LOCAL server's fleet; many-veils-one-console is a planned server endpoint.

---

*Case file grounded in the module's `//!` header and public API.*
