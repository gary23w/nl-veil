# accounts and the sandbox

**Covers:** `src/auth/auth_core.zig`, `src/worker/tools.zig` (the capability gate), `src/worker/chat/{tools,engine,service}.zig`  
**Kind:** operator + security orientation  
**Description:** What a normal account can and cannot do on a shared server, where its data lives, and why the line is drawn at capability rather than at file paths.

---

## Start from the uncomfortable fact

A chat turn runs **on the server, in the server's process, as the OS user who started `veil`**. A browser cannot execute a shell command, so the web client deliberately leaves the "run tools on my machine" flag out of its request and the server executes the turn's tools itself.

That is the whole reason this page exists. Handing someone a login is handing them a prompt that reaches a real machine. What stops that from being a host compromise is a capability gate, not good manners.

## Who is admin

The first account is admin — uid 1, seeded at boot. If `NL_ADMIN_EMAIL` is set, whoever holds that address is admin instead. Everybody else is a normal account.

## Where an account's data lives

Every path is built from the caller's own uid, so ownership is **structural** rather than a per-request check against a registry — there is no query that could return someone else's row, because the path was never constructed.

```
{data}/u{uid}/
  _chat/convs/{conv}/messages.jsonl   the conversation itself
                     events.jsonl     live turn narration the client polls
                     control.jsonl    stop / steer, appended by the client
  _chat/builds/{conv}/                what a turn (and any hive it casts) builds
  _sched/{id}.json                    scheduled tasks
  .veil-desk/memories.jsonl           the durable memory store
```

The memory store is per-uid for a specific reason: it backs `get_credential`, and one global file would have meant every account reading every other account's stored secrets the moment chat opened up.

## The gate

A non-admin turn runs with `caps = .sandboxed`. The check is the **first thing** in `tools.execute`, before any tool-specific logic, so there is exactly one place a capability decision is made:

```zig
if (ctx.caps == .sandboxed and !sandboxAllowed(name))
    return "that tool is not available in this workspace — …";
```

It is an **allowlist**, deliberately. `execute` falls through to authored tools for unknown names, and a denylist would be defeated the moment a model called `make_tool`.

The HTTP tool endpoint does not keep a second list. `worker/chat/tools.zig` delegates to the same `tools.sandboxAllowed` predicate, because a tool added to one list and forgotten in the other is exactly how a hole gets opened quietly.

## What a sandboxed account keeps

The hive mind is the product, and a sandboxed user keeps all of it. What they lose is the ability to act on the machine.

- **Research** — `web_search`, `web_fetch`, `fetch_json`, `read_url`
- **The entire memory surface** — `recall`, `recall_hive`, `observe`, `share`, `note_stance`, `save_skill`, `journal`, `set_directive`, `probe`
- **Coordination and planning** — `add_task`, `complete_task`, `send_message`, `propose_plan_change`
- **Files**, jailed to the conversation's own workdir — `write_file`, `edit_file`, `read_file`, `list_dir`, `delete_file`
- **`pixel_search`** — local retrieval over the caller's own attachments; renders nothing, touches no network
- **Read-only swarm observation** — `swarm_status`, `swarm_asks`, and `stop_swarm`, each uid-checked by its own handler

## What it does not get

Code execution (`run_python`, `run_tests`), host control (`host_status`, `host_command`, `host_explore`), engine self-modification (`patch_system`, `propose_change`, `simulate_change`), tool authoring (`make_tool`), egress and recon (`stage_delivery`, `osint_scan`), the browser verbs, `pixel_ingest` / `pixel_capture`, and the MCP verbs.

`deep_crawl` is also refused, and the reason is worth reading because it is not obvious: it fans out to links it discovers, and its host filter is weaker than the one guarding a single fetch. `web_search` and `web_fetch` cover research without the fan-out.

Two environment variables, `NL_BROWSER_DRIVER` and `NL_MCP`, exist as the operator's opt-in for handing browser and MCP access to sandboxed callers — the browser inherits the host's network position and its profile's cookies, so it is off by default. Note honestly, though, that as the code stands the allowlist gate in `execute` refuses `browser_*` and `mcp_*` for a sandboxed caller **before** those opt-in checks are ever consulted, so setting the variables does not currently hand a non-admin the browser. An admin (`.full`) already holds code execution, for which a headless browser is strictly the smaller capability, and gets both unconditionally.

## Orchestration: watch, yes; mint execution, no

Casting a swarm and scheduling a run are handled ahead of the sandbox gate, so they need their own decision — and they get one. For a sandboxed caller, `cast`, `steer_swarm`, `answer_swarm`, `sync_dir` and every `schedule_*` verb are refused inside a turn.

The reasoning: a swarm mind runs its own tool context with the *full* surface. "Sandbox the chat but allow casting" is not a sandbox, it is a redirect. Scheduling has the same shape one step removed, since a run executes later and outside this turn's context entirely.

Read-only observation stays. A sandboxed user can watch and halt their own swarms; they just cannot mint new execution.

At the REST layer the split is slightly different, and worth knowing if you are exposing the API:

- **Scheduled tasks** (`/api/v1/sched/*`) are admin-only outright, answering `403`.
- **Swarms** (`/api/v1/swarms`, `/cast`, `/run`) are gated by the caller's plan entitlements — mind counts, concurrent swarms, encryption, and metered balance — not by admin status.
- **Local models are admin-only.** A cast whose provider is `ollama`, or whose base URL names `localhost`, `127.0.0.1`, `0.0.0.0` or `[::1]`, is refused for a non-admin: that set has to match the worker's own notion of "local", because a host the worker treats as local but the gate misses is a non-admin reaching the host's loopback.

## The admin's own turn is not sandboxed

An admin calling the shared tool endpoint gets the **roam** privilege — absolute-path reads, plus the browser, pixel and MCP verbs authorized on roam rather than a server-side flag. That is the local-chat path: the desk is admin on this machine, and the endpoint runs the tool on the machine the user is already sitting at.

Which is fine on a laptop and is the thing to think hardest about on a shared box. Admin here means the host.

## Fair share

Turn admission is capacity-based, not queued. `NL_MAX_TURNS` sets how many chat turns run at once server-wide (default 64, hard ceiling 256) and `NL_MAX_TURNS_PER_USER` how many one account may hold (default: an eighth of capacity) — the second is what stops one busy user starving everyone else.

A refusal says which of the three things happened rather than collapsing them into one status: this conversation already has a turn running, this account is at its share, or every slot is taken by other people.

## Provider keys

Each account's key is sealed server-side in the vault, per provider. It is never stored in the browser and the server never sends one back — only a last-four and a fingerprint. A key in `localStorage` is a key in every XSS.

If the admin has set an instance-wide key, it is the **last** resort: a user's own key always wins, so an account bringing its own billing is never silently switched onto the admin's. Everything about that trade is on the [running a server](server.md) page.

---

Next: [architecture](architecture.md) · the tool surface itself, [chat/tools](../worker/chat/tools.md) · the turn loop, [chat/engine](../worker/chat/engine.md)
