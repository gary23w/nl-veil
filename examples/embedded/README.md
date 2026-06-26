# Embedded security daemon

A worked example: the Veil running **on an embedded device** as a self-healing,
threat-detecting security daemon. A simulated host gets infected; the Veil watches its
telemetry, recalls a remediation playbook from its own memory, and issues commands to heal
it — all with **no cloud, no screen, and (after setup) no network**.

The device's whole job is to keep one host clean. It does two things:

- **Remediate** known infections — kill the malicious process, block its command-and-control
  (C2) address, and remove the persistence that would otherwise respawn it.
- **Detect** a stealth implant the host itself can't see — a process named like a legitimate
  service, talking to a real known-bad C2 — by cross-referencing every outbound connection
  against threat intelligence baked into its memory.

Everything here is a **defensive test fixture**. Nothing in this suite attacks anything real;
the "malware" is a few simulated processes and connections in a sandboxed Python host.

## What's in the box

| File                  | Role |
|-----------------------|------|
| `host_sim.py`         | An observable, infectable virtual host. Emits telemetry, accepts remediation commands, and respawns malware whose persistence wasn't removed. |
| `host_system.facts`   | The remediation playbook corpus — how to read telemetry and heal each infection. Baked into the Veil's memory at startup. |
| `threatintel.facts`   | A blue-team IOC snapshot (known-bad C2 IPs). Baked in for the detection test. |
| `veil_chat.py`        | An offline-first operator console. Ask the device what's going on and tell it what to do — no model, no network required. |
| `run_secops.sh`       | Remediation test harness. |
| `run_detect.sh`       | Detection test harness. |

## The file bus

The host and the Veil never call each other directly — they exchange plain append-only files
in the run's `work/` directory. This is what makes the device operable offline and fully
replayable after the fact.

- **Downlink (host → Veil):** `work/telemetry.json` is rewritten every tick with the current
  machine state — processes, connections, persistence units, file integrity, a `threat_score`,
  and a `mode` (`NOMINAL` / `COMPROMISED` / `QUARANTINE`). `work/events.log` is the running
  security event log.
- **Uplink (Veil → host):** appending one command line to `work/commands.jsonl` operates the
  host. The vocabulary is `scan`, `kill_proc <pid|name>`, `block_ip <ip[:port]>`,
  `remove_persistence <name>`, `restore_file <path>`, `isolate`, and `status`.

The key mechanic: **killing a malicious process without removing its persistence lets it
respawn.** A real heal removes the root cause, not just the symptom.

## Prerequisites

- The engine binary built at `zig-out/bin/veil` (run `zig build` at the repo root).
- The `neuron` CLI at `bin/neuron` (the `deploy.py` wizard fetches and builds it on first run).
- Python 3 on `PATH`.
- A model. The harnesses default to a local `llama3.1:8b` via Ollama; override with the
  `VEIL_MODEL`, `VEIL_PROVIDER`, `VEIL_BASE_URL`, and `VEIL_KEY` environment variables for any
  OpenAI-compatible endpoint.

## Run the remediation test

```bash
./examples/embedded/run_secops.sh [run_name] [minutes]
```

This bakes `host_system.facts` into a fresh neuron-db memory, boots `host_sim.py` on the file
bus, injects a crypto-miner early and then rotates fresh threats in, and runs the Veil against
it for the given duration (default 6 minutes). Each round the Veil reads the live telemetry,
recalls the playbook, and — for each infection — issues the full remediation
(`remove_persistence`, `block_ip`, `kill_proc`), then re-checks that `threat_score` is back to
0 and `mode` is `NOMINAL`.

## Run the detection test

```bash
./examples/embedded/run_detect.sh [run_name] [minutes]
```

This is the harder problem. It bakes in **both** the playbook and `threatintel.facts`, then
plants a **stealth implant**: a process named like a real system service, with no suspicious
flag and no persistence, beaconing to a genuinely known-bad C2 from the threat-intel snapshot.
The host's own heuristics report `NOMINAL` and `threat_score=0` — the implant is invisible to
it. The only way to catch it is to take each open outbound connection and cross-reference its
IP against threat intelligence in memory. A match means the owning process is malicious even
though nothing flagged it.

## Inspect a run

Every run writes a self-contained forensics tree under `examples/embedded/debug/<run>/`
(git-ignored). You can replay exactly how the device watched, diagnosed, and acted:

```
<run>/events.jsonl            everything the Veil thought and did
<run>/mind.sqlite             its neuron-db memory
<run>/worker.log              raw engine log
<run>/work/telemetry.json     the live machine state
<run>/work/events.log         the host's security event log
<run>/work/commands.jsonl     the commands the Veil issued
<run>/work/debug/state.jsonl  full machine state, every tick
<run>/work/debug/audit.log    every command + verdict
```

## Talk to the device

`veil_chat.py` is an offline-first operator console. Because the device's entire cognition is
already persisted to its run directory, you can interrogate it with no model and no network —
the script just reads that state and answers. Point it at a run directory:

```bash
# Offline (pure file + neuron-db reads):
python examples/embedded/veil_chat.py --dir <run> status        # host state + what the Veil is doing
python examples/embedded/veil_chat.py --dir <run> log 20        # recent Veil actions (heals, commands)
python examples/embedded/veil_chat.py --dir <run> ask "is the host compromised?"
python examples/embedded/veil_chat.py --dir <run> cmd "kill_proc xmrig"   # operate the host directly
python examples/embedded/veil_chat.py --dir <run> chat          # interactive REPL
```

In the REPL, plain text is an offline question; `/veil <msg>` speaks to the Veil directly,
`/cmd <host cmd>` operates the host, and `/status`, `/log`, and `/watch` show live state.
For networked devices, `serve --port 8765` exposes a tiny HTTP surface (`GET /status /log`,
`POST /chat /ask /cmd`).

Note that `cmd` lets an operator override the device, but it warns when the target isn't a
verified indicator in the current telemetry — a small guard against typos and stale targets.
