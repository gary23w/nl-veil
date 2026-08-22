#!/usr/bin/env python3
"""Scan simulation traces for the failure signatures worth fixing."""
import json, io, os, sys, collections, hashlib, re

SIGNALS = [
    ("EMPTY_REPLY",      r"no reply — the model returned an empty or malformed"),
    ("LOOP_GUARD_STOP",  r"loop guard: stopped this turn"),
    ("LOOP_GUARD_REFUSE",r"loop guard: you have made this EXACT call"),
    ("DUP_CALL",         r"you already ran this EXACT call earlier this turn"),
    ("ENGINE_CUT",       r"\[engine: this turn was cut short"),
    ("FIRST_PERSON_CUT", r"engine: I stopped this turn"),
    ("UNKNOWN_TOOL",     r"unknown tool|is not available this turn|not on it"),
    ("ARBITER",          r"engine arbiter"),
    ("NUDGE",            r"has produced a FAILED outcome"),
    ("BELT_DENIAL",      r"there are no .* tools"),
    ("CTX_OVERFLOW",     r"exceeds the serving context|prompt exceeds"),
    ("TRUNCATED_WRITE",  r"looksTruncatedWrite|cut off mid-content"),
    ("SUMMARY_FAIL",     r"summary.*fail|ctxsum.*fail"),
]


def scan(path):
    name = os.path.basename(path)
    per_turn = collections.defaultdict(lambda: collections.defaultdict(int))
    hits = collections.Counter()
    tool_sig = collections.defaultdict(list)   # (turn,name,args) -> results
    errors, statuses = [], []
    llm_fail, llm_ok = 0, 0
    slow, failed = [], collections.Counter()
    kinds = collections.Counter()
    turns = set()
    for line in io.open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get("_turn", 0)
        turns.add(t)
        k = d.get("kind") or d.get("_meta") or "?"
        kinds[k] += 1
        blob = json.dumps(d, ensure_ascii=False)
        for label, pat in SIGNALS:
            if re.search(pat, blob, re.I):
                hits[label] += 1
                per_turn[t][label] += 1
        if k == "error":
            errors.append((t, str(d.get("err", ""))[:200]))
        if k == "status":
            statuses.append((t, str(d.get("text", ""))[:160]))
        if k == "llm":
            if d.get("ok") is False:
                llm_fail += 1
            else:
                llm_ok += 1
        if k == "tool" and str(d.get("state")) == "done":
            if d.get("ms") is not None:
                slow.append((int(d["ms"]), str(d.get("tool"))))
            if d.get("ok") is False:
                failed[str(d.get("tool"))] += 1
        if k == "tool" and str(d.get("state")) == "start":
            # args ride the START frame, so a repeated call is now identifiable by SIGNATURE rather than by
            # name alone. Before that, every call hashed to the same empty string and eight re-reads of one
            # file looked identical to eight reads of different files — the distinction that matters most
            # when judging whether a run is making progress or spinning.
            nm = str(d.get("tool") or "?")
            args = str(d.get("args") or "")
            tool_sig[(t, nm, args[:120])].append(args)
    print("\n===== %s  (%d turns, %d event kinds) =====" % (name, len(turns), len(kinds)))
    print("  kinds:", dict(kinds))
    print("  llm calls: ok=%d fail=%d" % (llm_ok, llm_fail))
    if hits:
        print("  SIGNALS:", dict(hits))
        for t in sorted(per_turn):
            if per_turn[t]:
                print("    turn %s: %s" % (t, dict(per_turn[t])))
    # identical call+args repeated within one turn
    rep = {k: v for k, v in tool_sig.items() if len(v) > 1}
    if rep:
        print("  REPEATED IDENTICAL CALLS (same tool AND same args in one turn):")
        for (turn, nm, args), v in sorted(rep.items(), key=lambda x: -len(x[1]))[:8]:
            print("    turn %s  %-14s x%-3d %s" % (turn, nm, len(v), args[:90]))
    if slow:
        print("  SLOWEST TOOL CALLS:")
        for ms, nm in sorted(slow, reverse=True)[:5]:
            print("    %6dms  %s" % (ms, nm))
    if failed:
        print("  FAILED TOOL CALLS: %s" % dict(failed))
    if errors:
        print("  ERRORS:")
        for t, e in errors[:8]:
            print("    turn %s: %s" % (t, e))
    interesting = [s for s in statuses if re.search(r"guard|stuck|recover|cut|stop|refus|overflow|compact|summar", s[1], re.I)]
    if interesting:
        print("  NOTABLE STATUS:")
        for t, s in interesting[:12]:
            print("    turn %s: %s" % (t, s))


if __name__ == "__main__":
    d = sys.argv[1]
    files = sorted(f for f in os.listdir(d) if f.startswith("trace-") and f.endswith(".jsonl"))
    if not files:
        print("no traces in", d)
    for f in files:
        scan(os.path.join(d, f))
