#!/usr/bin/env python3
"""
app_sim.py — a synthetic APPLICATION for testing generic app-attach (LEARN mode).

Where host_sim.py is an operable machine (it consumes commands and can be HEALED), app_sim.py is a PURE
PUBLISHER: it exposes an app's surface over the read-only file bus so a Veil swarm can ATTACH and LEARN it,
and it consumes NOTHING. There is deliberately NO commands.jsonl reader here — even if a line reached the
command bus, nothing would execute it. That is the zero-actuation guarantee of the app-attach LEARN phase:
the swarm can map and reason about the app, but v1 gives it no way to change it.

The app is a generic "job service": an API tier, a worker pool, a scheduler, a config, and a job queue.

Bus (all DOWNLINK / read-only; the swarm never writes these — reservedBusName blocks it):
  <dir>/telemetry.json          the app's current observable state, every tick
  <dir>/explore.jsonl           UPLINK requests the swarm queues: "<verb> <node> [rel]" (we only READ them)
  <dir>/explore_results.jsonl   our answers: "<scope> <fact>" lines (scope = map|node) the engine folds
                                into the swarm's MAP/NODE memory — this is how the swarm LEARNS the app
  <dir>/score.json              the app's own health/completeness invariant (the acceptance oracle)

Run:
  python app_sim.py --dir work --hz 2 --minutes 6
"""

import argparse
import json
import os
import sys
import time

# The app's static SURFACE — what a read-only exploration discovers. Keyed by node; each entry lists the
# child nodes an `enumerate`/`expand` reveals and a one-line `describe`. This stands in for whatever an
# adapter would learn from a real app's API schema / accessibility tree / CLI --help.
SURFACE = {
    "app": {
        "describe": "job-service: an HTTP API tier, a worker pool, and a cron-like scheduler over a job queue",
        "children": ["api", "workers", "scheduler", "queue", "config"],
    },
    "api": {
        "describe": "the HTTP API tier: submits jobs and reports status",
        "children": ["endpoint:POST /jobs", "endpoint:GET /jobs/{id}", "endpoint:GET /healthz"],
    },
    "workers": {
        "describe": "a pool of workers that pull jobs from the queue and execute them",
        "children": ["worker:w1", "worker:w2", "worker:w3"],
    },
    "scheduler": {
        "describe": "enqueues recurring jobs on a cron-like timer",
        "children": ["cron:nightly-report@02:00", "cron:cleanup@*/15min"],
    },
    "queue": {
        "describe": "the job queue: pending + in-flight jobs the workers drain",
        "children": ["state:pending", "state:in_flight", "state:done", "state:failed"],
    },
    "config": {
        "describe": "runtime configuration the app reads at boot",
        "children": ["key:max_workers", "key:retry_limit", "key:queue_backend"],
    },
}


def atomic_write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)  # atomic on POSIX and Windows — the swarm never reads a torn file


def telemetry(tick, pending):
    return {
        "app": "job-service",
        "tick": tick,
        "healthy": pending < 50,
        "queue_depth": pending,
        "workers_up": 3,
        "note": "read-only attach target; explore me with host_explore (enumerate/expand/describe)",
    }


def answer_explore(dir_, seen):
    """Serve any NEW request line in explore.jsonl by appending map/node facts to explore_results.jsonl.
    Request format (from host_explore): '<verb> <node> [rel]'. We never mutate; we only publish what the
    node IS and what it CONTAINS, tagged map/node so the engine folds them into the swarm's app-model."""
    ep = os.path.join(dir_, "explore.jsonl")
    if not os.path.exists(ep):
        return seen
    try:
        with open(ep, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return seen
    out = []
    for ln in lines[seen:]:
        parts = ln.split()
        if len(parts) < 2:
            continue
        verb, node = parts[0], parts[1]
        info = SURFACE.get(node)
        if not info:
            # an unknown node: report it as a leaf we could not expand (still a real discovery)
            out.append(f"node {node} is a leaf of the app surface (no further structure discovered)")
            continue
        if verb == "describe":
            out.append(f"node {node}: {info['describe']}")
        else:  # enumerate / expand: reveal the node's members and grow the map
            out.append(f"map {node} contains: {', '.join(info['children'])}")
            for ch in info["children"]:
                out.append(f"node {ch} is a member of {node}")
    if out:
        with open(os.path.join(dir_, "explore_results.jsonl"), "a", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
    return len(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="the bus directory (the swarm's work/ dir)")
    ap.add_argument("--hz", type=float, default=2.0)
    ap.add_argument("--minutes", type=float, default=6.0)
    a = ap.parse_args()
    os.makedirs(a.dir, exist_ok=True)
    deadline = time.time() + a.minutes * 60.0
    period = 1.0 / max(a.hz, 0.1)
    tick, seen, pending = 0, 0, 12
    # a self-describing note so the surface is legible even without exploration
    atomic_write(os.path.join(a.dir, "APP.txt"),
                 "job-service (read-only attach target). Explore with host_explore: enumerate app, "
                 "then expand api/workers/scheduler/queue/config, then describe any node.\n")
    while time.time() < deadline:
        tick += 1
        pending = max(0, pending + (3 if tick % 5 == 0 else -1))  # a gently varying observable
        atomic_write(os.path.join(a.dir, "telemetry.json"), json.dumps(telemetry(tick, pending), indent=2))
        # the oracle: the app is "well-understood/healthy" when the queue is drained — a signal the swarm
        # cannot forge (reservedBusName blocks writing score.json), only OBSERVE.
        atomic_write(os.path.join(a.dir, "score.json"),
                     json.dumps({"score": round(max(0.0, 1.0 - pending / 100.0), 3), "queue_depth": pending}))
        seen = answer_explore(a.dir, seen)
        time.sleep(period)
    print("app_sim: done", file=sys.stderr)


if __name__ == "__main__":
    main()
