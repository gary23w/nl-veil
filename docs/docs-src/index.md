# nl-veil — source documentation

> Repository: [gary23w/nl-veil](https://github.com/gary23w/nl-veil)  
> Every `.zig` source file across the modules — the server (including the CLI and the server-side chat brain) and the native desktop — plus a short guide to running the thing.

---

## Where the index lives

**The contents sheet on the site is the index.** It is the DOCUMENT INVENTORY section on the front page: every group, every sheet, its code and its source file, in reading order.

This page used to carry a second copy of that list, hand-maintained, and it did exactly what a second hand-maintained list always does — it drifted. It described `worker/locs/atlas` as "geospatial location services" when the file is the source atlas that points scouts at nl-rag packs, and nobody noticed, because there was no reason to read both. One list can be wrong. Two lists are wrong *and* disagree, which is worse, because the disagreement is the only symptom and it is invisible unless you happen to open both.

So the table is gone. Close this sheet and read the inventory.

## Start here if you are new

| | |
|---|---|
| [architecture](guide/architecture.md) | one server process; the web app, the native desk and the `veil` CLI as three clients of one `/api/v1` surface |
| [running a server](guide/server.md) | install, first login, the network bind, the default model, the shared provider key, accounts |
| [accounts and the sandbox](guide/accounts.md) | what a non-admin account can and cannot do, and why the line is capability rather than path |
| [main](main.md) | the entry point itself — CLI dispatch, subsystem wiring, the route table, server or app mode |

## How the modules divide

The per-file sheets are grouped by module; this is what each group is for.

| module | role |
|---|---|
| `gateway/` | HTTP ingress — the shared `App` context, the auth guard every handler calls, the JSON/file helpers. The route table itself is registered in `main.zig` |
| `auth/` | accounts, sessions, API keys, and the login guard that rate-limits brute force |
| `config/` | the encrypted key vault, the key API, admin-owned runtime settings, and address discovery |
| `admin/` | the admin surface — users, moderation, the instance-wide default model and provider key, audit |
| `obs/` | the audit log — structured event recording |
| `plan/` | entitlements, neuron plans, and the billing seam |
| `worker/chat/` | the server-side chat brain: the agentic turn loop, its REST handlers, its tool surface, context window and plan board |
| `worker/control/` · `deploy/` · `neuron/` | the swarm control plane — deploy, supervise, stream, steer, and the fail-open memory bridge |
| `worker/` | the hive runtime — the moment loop, the Veil, self-improvement, crawling, the micro-VCS for concurrent minds, scheduled tasks |
| `desk/` | the native dashboard: chat, casts, monitoring. Compiled **into** `veil` rather than shipped as a second binary |

## A note on reading these

Each per-file sheet is written by hand against the source, not generated from it. That means they can fall behind the code — the reading order is the source file first, the sheet second, and where the two disagree the source wins. If you find a disagreement, it is worth fixing rather than working around.
