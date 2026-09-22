# lineage_api

**File:** `src/worker/deploy/lineage_api.zig`  
**Module:** `worker/deploy`  
**Description:** HTTP routes for swarm lineages: what each lineage has learned, and the review of what its end-of-run judge and habit miner proposed.

---

## Purpose Summary

A lineage (`veil cast … --lineage <id>`) keeps one neuron-db across casts at `{data}/u{uid}/_lineage/<slug>/mind.sqlite`. These routes expose it to the account that owns it: counts of the live and quarantined scopes, the quarantined proposals themselves, and the accept/reject decision that `proposals.decide` carries out.

## Key Exports

- `listLineages` — `GET /api/v1/lineages` → `{"lineages":[{"id","lessons","skills","playbook","pending","rejected"}]}` (at most 32 lineages; each count is a neuron subprocess)
- `listProposals` — `GET /api/v1/lineages/:id/proposals` → `{"proposals":[{"scope","kind","text"}]}`
- `decideProposal` — `POST /api/v1/lineages/:id/proposals` with `{"scope","text","action":"accept"|"reject"}` → `{"ok":true,"outcome":…}`; 404 when that exact text is not pending, 400 for a bad action or a scope that is not a quarantine, 500 when the live write failed (the proposal stays queued)

## Dependencies

`gateway/http.zig` (`requireUser`, response helpers), `lineage.zig` (`dbPathIn`, `slug`), `proposals.zig` (`decide`, `SOURCES`), `oscillation.zig` (`Mem`), `tools.zig` (scope names).

## Usage Context

Registered in `main.zig` beside the swarm routes and listed in its router audit (`ROUTE_MODS`). Called by `veil lineage`, the desk poller (Memory pane), and `scripts/sim/lineage.py`.

## Notable Implementation Details

- The account id is part of the path, and the id is slugged (`[a-z0-9-_]` only), so `../` cannot reach another account's lineage; the tests cover a traversal-shaped id and a second account naming the same lineage.
- These handlers never create a lineage: a request for one that does not exist is a 404.
- The route table (`LINEAGE_ROUTES`) is swept for the anonymous-caller gate, and an exhaustiveness test fails when a new handler is not in it.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
