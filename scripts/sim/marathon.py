#!/usr/bin/env python3
"""MARATHON — a run long enough to reach where the context bugs actually live.

The earlier "long-tail" suites were 12-14 turns. That is not long. HISTORY_WINDOW_BYTES is 28 KiB,
so the recency window does not even begin to roll until roughly turn 12-15 of ordinary output, and
the summary-gap defect found earlier needs 256 KiB of UNCOVERED span before it can bite. A 14-turn
scenario therefore exercises the first tenth of the interesting range and then stops, which is why
everything passed.

This is built the other way round: start from the failure conditions and generate enough turns to
reach them.

  * every turn is asked for substantial prose, so messages.jsonl grows ~2-4 KB per turn and the
    window has rolled well before turn 20;
  * ten FACTS are planted in the opening turns and never repeated;
  * a RECALL PROBE fires every ninth turn, asking for facts from the opening block and forbidding
    file reads, so each probe measures continuity at a known distance;
  * per-turn telemetry (log size, `covered`, window-rolled) is recorded by drive.py, so a miss can
    be attributed to a window roll or a summary fold instead of guessed at.

The output is not a pass/fail. It is a CURVE: recall accuracy against conversation size. The turn
where it falls off is the answer.

  python scripts/sim/marathon.py plant
  python scripts/sim/marathon.py scenarios /tmp/mar.py [TURNS]
  python scripts/sim/drive.py /tmp/mar.py
  python scripts/sim/marathon.py grade "$SIM_OUT"
"""
import io, json, os, re, shutil, sys

REPO = os.environ.get("VEIL_REPO",
    os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
BUILDS = os.path.join(REPO, "data", "u1", "_chat", "builds")
CONVS = os.path.join(REPO, "data", "u1", "_chat", "convs")
NAME = "mar_recall"

# (key, value, the question used to probe it) — each value is distinctive enough that a near-miss is
# not scored as a hit, and none can be guessed from the surrounding task.
FACTS = [
    ("deploy key", "orbital-7", "what is the deploy key called"),
    ("staging database", "pg-eu-west-2b", "what is the staging database host"),
    ("release manager", "Priya Raghavan", "who is the release manager"),
    ("rollback window", "45 minutes", "how long is the rollback window"),
    ("incident channel", "#ops-red", "what is the incident channel"),
    ("canary percentage", "7%", "what is the canary percentage"),
    ("on-call flip", "09:00 UTC", "when does the on-call rotation flip"),
    ("artifact bucket", "s3://veil-artifacts-prod-eu", "what is the artifact bucket"),
    ("break-glass account", "svc-breakglass-04", "what is the break-glass account"),
    ("SLA target", "99.95%", "what is the SLA target"),
]

# Filler topics: each asks for ~400 words of prose, which is what actually grows the log. They are
# real questions rather than nonsense so the model is doing ordinary work between probes.
TOPICS = [
    "blue-green deployment", "canary releases", "feature flags", "database migration safety",
    "circuit breakers", "exponential backoff", "idempotency keys", "distributed tracing",
    "log sampling strategies", "SLO error budgets", "chaos engineering", "connection pooling",
    "read replicas and lag", "cache invalidation", "rate limiting algorithms", "graceful shutdown",
    "health checks vs readiness", "blue-team incident review", "runbook design", "on-call handover",
    "capacity planning", "queue backpressure", "schema versioning", "secret rotation",
    "immutable infrastructure", "config drift", "canary analysis metrics", "rollout automation",
    "dependency pinning", "build reproducibility",
]


def plant():
    for d in (os.path.join(BUILDS, NAME), os.path.join(CONVS, NAME)):
        shutil.rmtree(d, ignore_errors=True)
    w = os.path.join(BUILDS, NAME, "work")
    os.makedirs(w, exist_ok=True)
    io.open(os.path.join(w, "README.md"), "w", encoding="utf-8", newline="\n").write(
        "Operations notebook. Facts are given in conversation and are NOT written down here.\n")
    print("planted %s" % NAME)


def build_turns(total):
    """Opening fact block, then filler with a recall probe every ninth turn."""
    turns = []
    for key, val, _q in FACTS:
        turns.append("Note this for later: the %s is %s. Acknowledge in one short line, nothing else."
                     % (key, val))
    probe_at = []
    i = 0
    while len(turns) < total:
        n = len(turns) + 1
        if n % 9 == 0:
            # probe two facts, oldest-first rotation, and forbid reading anything
            a = FACTS[(len(probe_at) * 2) % len(FACTS)]
            b = FACTS[(len(probe_at) * 2 + 1) % len(FACTS)]
            turns.append(
                "Answer from memory of this conversation ONLY — do not read or search any file, and do "
                "not use tools. Two questions: (1) %s? (2) %s? Answer both in one short line each, "
                "exactly as they were given to you." % (a[2], b[2]))
            probe_at.append((n, a[0], a[1], b[0], b[1]))
        else:
            t = TOPICS[i % len(TOPICS)]
            i += 1
            turns.append("Write roughly 400 words on %s. Prose only, no tools, no files." % t)
    return turns, probe_at


def scenarios(path, total):
    turns, probe_at = build_turns(total)
    out = ["# generated by scripts/sim/marathon.py — do not edit",
           "MODEL = %r" % os.environ.get("SIM_MODEL", "deepseek-v4-flash"),
           "BASE_URL = %r" % os.environ.get("SIM_BASE_URL", "https://api.deepseek.com/v1"),
           "SCENARIOS = [",
           "  {%r: %r, %r: %r, %r: %r}," % ("name", NAME, "conv", NAME, "turns", turns),
           "]"]
    io.open(path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
    io.open(os.path.join(os.path.dirname(os.path.abspath(path)), "mar_probes.json"),
            "w", encoding="utf-8", newline="\n").write(json.dumps(probe_at))
    print("wrote %s: %d turns, %d recall probes (every 9th turn)" % (path, len(turns), len(probe_at)))


def _norm(s):
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def grade(out_dir):
    p = os.path.join(out_dir, "summary-%s.json" % NAME)
    if not os.path.exists(p):
        print("no summary for %s — nothing was exercised" % NAME)
        return
    turns = json.load(io.open(p, encoding="utf-8")).get("turns", [])
    if not any((t.get("answer") or "").strip() for t in turns):
        print("NO_DATA: no answers recorded")
        return
    probes_path = os.path.join(os.path.dirname(os.path.abspath(out_dir)), "mar_probes.json")
    if not os.path.exists(probes_path):
        probes_path = os.path.join(out_dir, "mar_probes.json")
    probe_at = json.load(io.open(probes_path, encoding="utf-8")) if os.path.exists(probes_path) else []
    by_turn = {t.get("turn"): t for t in turns}

    print("%-6s %-9s %-9s %-8s %s" % ("TURN", "LOG(KB)", "COVERED", "WINDOW", "RECALL"))
    print("-" * 96)
    hits = misses = 0
    first_miss = None
    for n, ka, va, kb, vb in probe_at:
        t = by_turn.get(n)
        if not t:
            continue
        a = _norm(t.get("answer"))
        c = t.get("ctx") or {}
        got_a, got_b = _norm(va) in a, _norm(vb) in a
        ok = got_a and got_b
        hits += 1 if ok else 0
        misses += 0 if ok else 1
        if not ok and first_miss is None:
            first_miss = (n, c.get("messages_bytes", 0))
        detail = "%s %s / %s %s" % (ka, "OK" if got_a else "MISS(%s)" % va,
                                    kb, "OK" if got_b else "MISS(%s)" % vb)
        print("%-6d %-9d %-9d %-8s %s" % (
            n, c.get("messages_bytes", 0) // 1024, c.get("covered", 0) // 1024,
            "rolled" if c.get("window_rolled") else "intact", detail))
    print("-" * 96)
    total = hits + misses
    print("recall: %d/%d probes fully correct" % (hits, total))
    if first_miss:
        print("first miss at turn %d, conversation log %d KB" % (first_miss[0], first_miss[1] // 1024))
    else:
        print("no misses — continuity held for the whole run")
    last = turns[-1].get("ctx") or {}
    print("final: log=%dKB covered=%dKB summary=%dB uncovered=%dKB" % (
        last.get("messages_bytes", 0) // 1024, last.get("covered", 0) // 1024,
        last.get("summary_len", 0), last.get("uncovered_bytes", 0) // 1024))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "plant"
    if cmd == "plant":
        plant()
    elif cmd == "scenarios":
        scenarios(sys.argv[2] if len(sys.argv) > 2 else "marathon_gen.py",
                  int(sys.argv[3]) if len(sys.argv) > 3 else 120)
    elif cmd == "grade":
        grade(sys.argv[2])
    else:
        print(__doc__)
