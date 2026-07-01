#!/usr/bin/env python3
"""Parse a veil run's events.jsonl into a low-param builder failure taxonomy.

Usage: python sim_analyze.py <run_dir>
"""
import json, os, sys, collections

def load_events(run_dir):
    p = os.path.join(run_dir, "events.jsonl")
    evs = []
    if not os.path.isfile(p):
        return evs
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evs.append(json.loads(line))
            except Exception:
                pass
    return evs

# act "kind" values we care about for the builder taxonomy
FAIL_KINDS = {
    "salvage_reject": "fence salvage rejected (no file written)",
    "tool_recover": "tool-call parse failed -> tools-off retry",
    "edit_fail": "edit_file anchor not found / apply failed",
    "write_reject": "write_file soft-rejected (ownership/slot guard)",
    "thinking": "model narrated instead of tool-calling",
}

def main(run_dir):
    evs = load_events(run_dir)
    if not evs:
        print(f"(no events yet in {run_dir})")
        return
    kinds = collections.Counter()
    act_tools = collections.Counter()          # act events keyed by tool verb
    act_tool_by_mind = collections.defaultdict(collections.Counter)
    scores = []
    caps = []
    rounds = 0
    stopped = None
    for e in evs:
        k = e.get("kind") or e.get("k") or ""
        kinds[k] += 1
        if k == "round":
            rounds += 1
        elif k == "score":
            scores.append((e.get("round"), e.get("pct"), e.get("tier"), e.get("passed")))
        elif k == "capacity":
            caps.append((e.get("round"), e.get("tier"), e.get("conv_cap"), e.get("tool_ok"), e.get("narrated")))
        elif k == "stopped":
            stopped = e
        elif k == "act":
            tool = e.get("tool", "") or "?"
            mind = e.get("mind", "?")
            act_tools[tool] += 1
            act_tool_by_mind[mind][tool] += 1

    print(f"=== {os.path.basename(run_dir)} ===")
    print(f"events: {len(evs)}  rounds: {rounds}")
    print(f"event kinds: {dict(kinds.most_common())}")
    print(f"\nact-tool distribution (all minds):")
    for tool, c in act_tools.most_common(40):
        print(f"   {c:4d}  {tool}")
    print(f"\nper-mind act-tool (top 8 tools each):")
    for mind, cc in act_tool_by_mind.items():
        top = ", ".join(f"{t}:{n}" for t, n in cc.most_common(8))
        print(f"   {mind}: {top}")
    if scores:
        print(f"\nfitness trajectory (round, pct, tier, passed):")
        for s in scores[-14:]:
            print(f"   {s}")
    if caps:
        print(f"\ncapacity events (round, tier, conv_cap, tool_ok, narrated):")
        for c in caps[-10:]:
            print(f"   {c}")
    # sample the act detail strings that mention failures/edits
    print("\n--- failure/edit/smoke act samples ---")
    shown = 0
    FAILV = ['salvage_reject', 'edit_fail', 'tool_recover', 'anchor', 'reject',
             'edit', 'smoke', 'error', 'fail', 'incomplete']
    for e in evs:
        if e.get("kind") != "act":
            continue
        tool = e.get("tool", "")
        res = str(e.get("result", ""))
        if any(t in tool for t in FAILV) or any(t in res.lower() for t in ['fail', 'reject', 'error', 'not found', 'anchor']):
            print(f"  [{e.get('mind','?')} r{e.get('round','?')}] {tool} | args={str(e.get('args',''))[:60]} | {res[:200]}")
            shown += 1
            if shown >= 25:
                break
    # final work tree
    work = os.path.join(run_dir, "work")
    print("\n--- work/ tree ---")
    if os.path.isdir(work):
        for root, dirs, files in os.walk(work):
            for fn in files:
                fp = os.path.join(root, fn)
                rel = os.path.relpath(fp, work)
                try:
                    sz = os.path.getsize(fp)
                except OSError:
                    sz = -1
                print(f"   {rel}  ({sz}B)")
    if stopped:
        print(f"\nstopped: {json.dumps(stopped)[:300]}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
