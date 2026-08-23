#!/usr/bin/env python3
"""Non-interactive driver for the veil chat API — the same surface debug.ps1 exercises.

debug.ps1 is a REPL (Read-Host for the model, the key, and every turn), so it cannot run
unattended. This drives the identical endpoints, streams the same observable trace, and
records EVERYTHING to JSONL so a long-tail run can be analysed after the fact.

The API key is taken from the VEIL_API_KEY environment variable and is never written to
disk, never logged, and never echoed into a trace file.
"""
import io, json, os, sys, time, urllib.request, urllib.error, uuid, re
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
RESUME = "--resume" in sys.argv or os.environ.get("SIM_RESUME") == "1"

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


def conv_state(conv):
    """Per-turn context mechanics, read straight from the conversation store.

    Answer-correctness alone cannot tell a REASONING failure from a CONTINUITY failure. These are the
    numbers that distinguish them: how big the durable log has grown, how much of it the rolling
    summary claims to cover, and therefore whether the turn that just ran was reading history
    verbatim or reading a summary of it. A recall miss at the exact turn `covered` jumps is a
    context bug; the same miss with a healthy window is a reasoning bug.
    """
    base = os.path.join(REPO, "data", "u1", "_chat", "convs", conv)
    out = {}
    try:
        out["messages_bytes"] = os.path.getsize(os.path.join(base, "messages.jsonl"))
    except OSError:
        out["messages_bytes"] = 0
    try:
        out["events_bytes"] = os.path.getsize(os.path.join(base, "events.jsonl"))
    except OSError:
        out["events_bytes"] = 0
    try:
        cj = json.load(io.open(os.path.join(base, "context.json"), encoding="utf-8"))
        out["covered"] = cj.get("covered", 0)
        out["summary_len"] = len(cj.get("summary", "") or "")
    except Exception as e:
        # DO NOT swallow this. A bare `except` here hid a NameError (io was not imported) for an
        # entire 100-turn run, reporting covered=0 throughout while context.json on disk said
        # 257815. Silent zeros are worse than a missing field: they look like a real measurement and
        # they pointed at an engine bug that did not exist.
        out["covered"] = 0
        out["summary_len"] = 0
        out["ctx_read_error"] = "%s: %s" % (type(e).__name__, e)
    # HISTORY_WINDOW_BYTES is 28 KiB: past that, the oldest turns stop being replayed verbatim and
    # continuity depends entirely on the summary.
    out["window_rolled"] = out["messages_bytes"] > 28 * 1024
    out["uncovered_bytes"] = max(0, out["messages_bytes"] - 28 * 1024 - out["covered"])
    return out


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
        # A non-200 body is an API ERROR, not event lines. Parsing it as events silently turned
        # {"ok":false,"err":"not found"} into a phantom "event" with no kind — masking a real server
        # race instead of surfacing it. Retry rather than poison the trace.
        if st != 200:
            if st == 404:
                time.sleep(0.25)
                continue
            errors.append("HARNESS: events HTTP %s: %s" % (st, content[:120]))
            time.sleep(0.5)
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
    # 180s, not 60: the POST only has to be ACCEPTED, but a server already working another
    # conversation can be slow to get there, and a timeout here loses the whole scenario.
    return req("POST", "/api/v1/chat/convs/%s/messages" % conv, body, timeout=180)


def run_scenario(name, turns, model, base_url, loop=0, conv=None):
    conv = conv or ("sim-%s-%s" % (name, uuid.uuid4().hex[:8]))
    path = os.path.join(OUT, "trace-%s.jsonl" % name)
    summary = {"scenario": name, "conv": conv, "model": model, "turns": []}
    off = 0
    # RESUME. A multi-hour run will be interrupted — a server restart, a session ending, a machine
    # sleeping. Without this the only options are losing hours of work or replaying turns against a
    # conversation that already contains them, which corrupts the very state being measured. The
    # per-turn summary write is what makes this possible: it is the checkpoint.
    done = 0
    spath = os.path.join(OUT, "summary-%s.json" % name)
    if RESUME and os.path.exists(spath):
        try:
            prev = json.load(open(spath, encoding="utf-8"))
            if prev.get("conv") == conv:
                summary = prev
                done = len([t for t in prev.get("turns", []) if (t.get("answer") or "").strip()])
                off = max((t.get("next_off", 0) for t in prev.get("turns", [])), default=0)
                print("  RESUME: %d turn(s) already done, continuing at %d (event offset %d)"
                      % (done, done + 1, off), flush=True)
        except Exception as e:
            print("  RESUME: could not read checkpoint (%s) — starting fresh" % type(e).__name__, flush=True)
    print("\n=== SCENARIO %s  conv=%s  (%d turns) ===" % (name, conv, len(turns)), flush=True)
    with open(path, "a" if RESUME else "w", encoding="utf-8") as sink:
        for i, t in enumerate(turns, 1):
            if i <= done:
                continue
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
            r["ctx"] = conv_state(conv)   # read the store BEFORE the print that reports it
            c = r["ctx"]
            print("    %.1fs  tools=%-3d answer=%-5dch  log=%dKB covered=%dKB%s%s" % (
                r["secs"], len(r["tools"]), len(ans),
                c["messages_bytes"] // 1024, c["covered"] // 1024,
                "  WINDOW-ROLLED" if c["window_rolled"] else "",
                ("  ERRORS=%s" % r["errors"][:1]) if r["errors"] else ""), flush=True)
            if ans:
                print("    > %s" % ans[:220].replace("\n", " "), flush=True)
            r.pop("events", None)
            r["answer"] = ans[:4000]
            summary["turns"].append(r)
            # write after EVERY turn: a 150-turn run that dies at turn 120 must still be gradeable,
            # and an end-of-scenario-only write throws away everything on any abort
            with open(os.path.join(OUT, "summary-%s.json" % name), "w", encoding="utf-8") as sf:
                json.dump(summary, sf, indent=1, ensure_ascii=False)
    with open(os.path.join(OUT, "summary-%s.json" % name), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=1, ensure_ascii=False)
    return summary


def preflight():
    """Refuse to start against a dead server.

    A 38-turn run once executed end to end with the server down: every POST refused, every turn
    logged as failed, and the graders — which read disk state rather than answers — reported EARNED
    on pristine fixtures. The graders are fixed, but the run should never have been attempted. Ten
    minutes of connection-refused is not data.
    """
    try:
        st, _h, _b = req("GET", "/models.json", timeout=8)
        if st == 200:
            return True
    except Exception as e:
        print("PREFLIGHT: cannot reach %s (%s)" % (SERVER, type(e).__name__), flush=True)
        return False
    print("PREFLIGHT: %s answered HTTP %s for /models.json" % (SERVER, st), flush=True)
    return False


if __name__ == "__main__":
    import importlib.util
    if not preflight():
        print("aborting: start the server first", flush=True)
        raise SystemExit(2)
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
