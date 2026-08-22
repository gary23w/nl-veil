#!/usr/bin/env python3
"""Non-interactive driver for the veil chat API — the same surface debug.ps1 exercises.

debug.ps1 is a REPL (Read-Host for the model, the key, and every turn), so it cannot run
unattended. This drives the identical endpoints, streams the same observable trace, and
records EVERYTHING to JSONL so a long-tail run can be analysed after the fact.

The API key is taken from the VEIL_API_KEY environment variable and is never written to
disk, never logged, and never echoed into a trace file.
"""
import json, os, sys, time, urllib.request, urllib.error, uuid, re
# the console here is cp1252; a single unicode arrow in a model answer used to abort the whole suite
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SERVER = os.environ.get("VEIL_SERVER", "http://127.0.0.1:8787")
REPO = os.environ.get("VEIL_REPO",
    os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
OUT = os.environ.get("SIM_OUT", ".")
API_KEY = os.environ.get("VEIL_API_KEY", "")

with open(os.path.join(REPO, "data", ".desktop_key"), "r", encoding="utf-8") as f:
    TOKEN = f.read().strip()

SECRETS = [s for s in (API_KEY, TOKEN) if s]


def scrub(text):
    """No credential may reach a trace file, even inside an echoed request body."""
    for s in SECRETS:
        if s:
            text = text.replace(s, "[REDACTED]")
    return text


def req(method, path, body=None, timeout=60):
    url = SERVER + path
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "Bearer " + TOKEN)
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read().decode("utf-8", "replace")


def watch(conv, sink, turn_idx, start_off, budget_s=900):
    """Stream one turn's events to `sink`, returning a per-turn summary."""
    off, done, t0 = start_off, False, time.time()
    answer, final_msg, events = [], [], []
    counts, tool_calls, errors, statuses = {}, [], [], []
    llm_calls = []
    last_progress = time.time()
    while not done:
        if time.time() - t0 > budget_s:
            errors.append("HARNESS: turn exceeded %ds budget" % budget_s)
            break
        try:
            st, hdrs, content = req("GET", "/api/v1/chat/convs/%s/events?from=%d" % (conv, off), timeout=30)
        except Exception as e:
            errors.append("HARNESS: event poll failed: %s" % e)
            time.sleep(1.0)
            continue
        nxt = hdrs.get("X-Next-Offset")
        if nxt:
            off = int(nxt)
        got = False
        for line in content.split("\n"):
            line = line.strip()
            if not line:
                continue
            got = True
            try:
                ev = json.loads(line)
            except Exception:
                continue
            k = str(ev.get("kind", "?"))
            counts[k] = counts.get(k, 0) + 1
            ev["_turn"] = turn_idx
            events.append(ev)
            sink.write(scrub(json.dumps(ev, ensure_ascii=False)) + "\n")
            if k == "token":
                answer.append(str(ev.get("delta", "")))
            elif k == "message" and ev.get("role") == "assistant":
                # the committed message is authoritative; streamed tokens are the same text arriving early,
                # so counting both double-reports every answer
                final_msg.append(str(ev.get("content", "")))
            elif k == "tool":
                tool_calls.append(ev)
            elif k == "error":
                errors.append(str(ev.get("err", ""))[:400])
            elif k == "status":
                statuses.append(str(ev.get("text", ""))[:200])
            elif k == "llm":
                llm_calls.append(ev)
            elif k == "done":
                done = True
        if got:
            last_progress = time.time()
        if not done:
            if time.time() - last_progress > 300:
                errors.append("HARNESS: no events for 300s — server appears wedged")
                break
            time.sleep(0.25)
    sink.flush()
    return {
        "turn": turn_idx, "secs": round(time.time() - t0, 1),
        "answer": "".join(final_msg) if final_msg else "".join(answer),
        "streamed_chars": len("".join(answer)),
        "next_off": off,
        "kinds": counts, "tools": tool_calls, "errors": errors, "statuses": statuses,
        "llm": llm_calls, "events": events,
    }


def send(conv, text, model, base_url, loop=0, fast=False):
    body = {"text": text, "base_url": base_url, "model": model, "api_key": API_KEY,
            "loop": loop, "tool_client": False, "fast": fast, "trace": True}
    return req("POST", "/api/v1/chat/convs/%s/messages" % conv, body, timeout=60)


def run_scenario(name, turns, model, base_url, loop=0, conv=None):
    conv = conv or ("sim-%s-%s" % (name, uuid.uuid4().hex[:8]))
    path = os.path.join(OUT, "trace-%s.jsonl" % name)
    summary = {"scenario": name, "conv": conv, "model": model, "turns": []}
    off = 0
    print("\n=== SCENARIO %s  conv=%s  (%d turns) ===" % (name, conv, len(turns)), flush=True)
    with open(path, "w", encoding="utf-8") as sink:
        for i, t in enumerate(turns, 1):
            prompt = t["text"] if isinstance(t, dict) else t
            tl = t.get("loop", loop) if isinstance(t, dict) else loop
            print("  [turn %d/%d] %s" % (i, len(turns), prompt[:90].replace("\n", " ")), flush=True)
            sink.write(json.dumps({"_meta": "user", "_turn": i, "text": prompt}) + "\n")
            try:
                st, _, body = send(conv, prompt, model, base_url, loop=tl)
                waited = 0.0
                while st == 409 and waited < 120:
                    time.sleep(0.5); waited += 0.5
                    st, _, body = send(conv, prompt, model, base_url, loop=tl)
                if waited:
                    print("    (waited %.1fs for the conv slot after {done})" % waited, flush=True)
                if st not in (200, 201, 202):
                    print("    POST rejected HTTP %s: %s" % (st, scrub(body)[:200]), flush=True)
                    summary["turns"].append({"turn": i, "post_status": st, "errors": ["POST %s" % st]})
                    continue
            except Exception as e:
                print("    POST failed: %s" % scrub(str(e))[:200], flush=True)
                summary["turns"].append({"turn": i, "errors": ["POST exception: %s" % scrub(str(e))[:200]]})
                continue
            r = watch(conv, sink, i, off)
            off = r["next_off"]
            ans = r["answer"].strip()
            print("    %.1fs  kinds=%s  tools=%d  answer=%dch%s" % (
                r["secs"], r["kinds"], len(r["tools"]), len(ans),
                ("  ERRORS=%s" % r["errors"][:2]) if r["errors"] else ""), flush=True)
            if ans:
                print("    > %s" % ans[:220].replace("\n", " "), flush=True)
            r.pop("events", None)
            r["answer"] = ans[:4000]
            summary["turns"].append(r)
    with open(os.path.join(OUT, "summary-%s.json" % name), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=1, ensure_ascii=False)
    return summary


if __name__ == "__main__":
    import importlib.util
    spec = importlib.util.spec_from_file_location("scen", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    only = sys.argv[2] if len(sys.argv) > 2 else None
    allsum = []
    for s in mod.SCENARIOS:
        if only and s["name"] != only:
            continue
        allsum.append(run_scenario(s["name"], s["turns"], mod.MODEL, mod.BASE_URL, s.get("loop", 0), s.get("conv")))
    with open(os.path.join(OUT, "ALL.json"), "w", encoding="utf-8") as f:
        json.dump(allsum, f, indent=1, ensure_ascii=False)
    print("\nwrote %d scenario summaries to %s" % (len(allsum), OUT))
