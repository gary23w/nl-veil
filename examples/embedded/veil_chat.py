#!/usr/bin/env python3
"""veil_chat.py — talk to the resident Veil on an embedded device. OFFLINE-FIRST, stdlib only.

The whole point: an embedded box often has NO uplink and NO screen, yet an operator still needs to ask it
"what's going on?" and tell it "do this." The Veil's entire cognition is already persisted to its run dir —
telemetry.json (the wired host), events.jsonl (everything the Veil thought/did), commands.jsonl (what it issued),
and mind.sqlite (its neuron-db memory). So you can INTERROGATE the device's mind with NO model and NO network:
this script just reads that state and answers. And because the operator->Veil channel (control.jsonl) and the
host command bus (work/commands.jsonl) are plain append-only files, the SAME script can talk to the Veil and
operate the wired host from a local shell — exactly what the engine already drains each round.

  Offline (no model, no network — pure file + neuron-db reads):
    veil_chat.py --dir RUN status            # the wired host + what the Veil is doing
    veil_chat.py --dir RUN log [N]           # recent Veil actions (heals, commands, replies)
    veil_chat.py --dir RUN ask "<question>"  # answer from neuron-db memory + live state
    veil_chat.py --dir RUN cmd "kill_proc xmrig"   # operate the wired host (-> commands.jsonl)
    veil_chat.py --dir RUN say "<message>"   # message the swarm (-> control.jsonl, op:say)
    veil_chat.py --dir RUN veil "<message>"  # speak to the Veil directly (-> control.jsonl, op:veil)
    veil_chat.py --dir RUN chat              # interactive REPL (all of the above)
    veil_chat.py --dir RUN watch             # live monitor (poll telemetry + new events)

  Online (optional callback for networked devices):
    veil_chat.py --dir RUN serve --port 8765 # tiny HTTP surface: GET /status /log, POST /chat /cmd
    veil_chat.py --dir RUN ... --notify URL  # POST an alert to a webhook when something changes
"""
import argparse, json, os, sys, time, subprocess

# embedded consoles are often not UTF-8 (Windows cp1252, minimal busybox); never let an encoding quirk crash the chat
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HOST_VERBS =("kill_proc", "block_ip", "remove_persistence", "restore_file", "isolate",
              "quarantine", "unisolate", "resume", "scan", "status", "safe_mode")


# ---------- locating things ----------
def find_neuron(run):
    """Locate the neuron CLI: env, then walking up from the run dir toward a repo 'bin/'."""
    for c in (os.environ.get("NEURON_BIN"),):
        if c and os.path.isfile(c):
            return c
    d = os.path.abspath(run)
    for _ in range(8):
        for name in ("bin/neuron.exe", "bin/neuron"):
            cand = os.path.join(d, name)
            if os.path.isfile(cand):
                return cand
        d = os.path.dirname(d)
    return None


def rp(run, *parts):
    return os.path.join(run, *parts)


# ---------- reading the Veil's persisted cognition ----------
def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def read_events(run, n=None):
    out = []
    try:
        with open(rp(run, "events.jsonl"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    pass
    except OSError:
        return []
    return out[-n:] if n else out


def host_log(run, n=12):
    try:
        with open(rp(run, "work", "events.log"), encoding="utf-8") as f:
            return [l.rstrip() for l in f if l.strip()][-n:]
    except OSError:
        return []


# ---------- formatting ----------
def fmt_status(run):
    tel = load_json(rp(run, "work", "telemetry.json"))
    evs = read_events(run)
    lines = []
    started = next((e for e in evs if e.get("kind") == "started"), None)
    if started:
        lines.append("Veil  : model=%s  provider=%s" % (started.get("model", "?"), started.get("provider", "?")))
        g = (started.get("goal") or "").strip()
        if g:
            lines.append("Task  : %s%s" % (g[:140], "…" if len(g) > 140 else ""))
    rounds = sum(1 for e in evs if e.get("kind") == "round")
    cmds = sum(1 for e in evs if e.get("kind") == "act" and e.get("tool") == "host_command")
    recs = sum(1 for e in evs if e.get("kind") == "act" and e.get("tool") == "recover")
    lines.append("Veil  : %d rounds observed, %d host_command issued, %d recovered" % (rounds, cmds, recs))
    if tel:
        infs = tel.get("infections", [])
        lines.append("Host  : mode=%s  threat_score=%s  tick=%s" % (tel.get("mode"), tel.get("threat_score"), tel.get("tick")))
        if infs:
            lines.append("Threat: " + ", ".join("%s[%s]" % (i.get("type"), i.get("id")) for i in infs))
        else:
            lines.append("Threat: none — host is clean")
    else:
        lines.append("Host  : (no telemetry.json on the bus — no wired host attached, or not booted yet)")
    heals = [e for e in host_log(run, 200) if "REMEDIATED" in e]
    if heals:
        lines.append("Heals : %d verified-clean remediations; last: %s" % (len(heals), heals[-1].split("] ", 1)[-1]))
    return "\n".join(lines)


def fmt_log(run, n=12):
    evs = read_events(run)
    keep = {"host_command": "->host", "host_status": "host?", "write_file": "wrote", "recover": "recovered",
            "directive": "VEIL", "connectivity": "net"}
    rows = []
    for e in evs:
        if e.get("kind") != "act":
            continue
        tool = e.get("tool", "")
        if tool not in keep and e.get("mind") != "veil":
            continue
        tag = keep.get(tool, tool)
        det = (e.get("result") or e.get("args") or "")[:110].replace("\n", " ")
        rows.append("  [r%s] %-7s %-9s %s" % (e.get("round", "?"), e.get("mind", "?"), tag, det))
    out = rows[-n:] if n else rows
    if not out:
        # fall back to the wired host's own log if the Veil hasn't acted yet
        return "\n".join("  " + l for l in host_log(run, n)) or "  (no activity logged yet)"
    return "\n".join(out)


# ---------- neuron-db memory (offline Q&A) ----------
def recall(run, scope, query):
    neu = find_neuron(run)
    db = rp(run, "mind.sqlite")
    if not neu or not os.path.isfile(db):
        return None
    for cmd in (["assoc", scope], ["recall", scope], ["get", scope]):
        try:
            r = subprocess.run([neu, "--db", db] + cmd + query.split(), capture_output=True, text=True, timeout=20)
            out = (r.stdout or "").strip()
            if out and "no match" not in out.lower():
                return out
        except Exception:
            pass
    return None


# ---------- writing to the buses (operator -> Veil / wired host) ----------
def append_jsonl(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj) + "\n")


def control(run, op, text=None, goal=None):
    o = {"op": op}
    if text is not None:
        o["text"] = text
    if goal is not None:
        o["goal"] = goal
    append_jsonl(rp(run, "control.jsonl"), o)


def host_cmd(run, command):
    command = command.strip()
    verb = command.split()[0] if command else ""
    if verb not in HOST_VERBS:
        return "rejected: '%s' is not an allowed host command (%s)" % (verb, ", ".join(HOST_VERBS))
    # operator override is allowed, but warn if the target isn't a verified indicator in live telemetry
    warn = ""
    tel = load_json(rp(run, "work", "telemetry.json")) or {}
    tgt = command[len(verb):].strip()
    if verb in ("block_ip", "kill_proc", "remove_persistence") and tgt:
        known = []
        if verb == "block_ip":
            known = [c.get("ip", "") for c in tel.get("connections", []) if c.get("c2")]
        elif verb == "kill_proc":
            known = [p.get("name", "") for p in tel.get("processes", []) if p.get("suspicious")]
        else:
            known = [x.get("name", "") for x in tel.get("persistence", [])]
        bare = tgt.split(":")[0]
        if known and not any(bare == k.split(":")[0] or tgt == k for k in known):
            warn = "  [warn: '%s' is not a verified indicator right now; known: %s]" % (tgt, known)
    append_jsonl(rp(run, "work", "commands.jsonl"), {"command": command, "src": "operator"})
    # the engine's hostCommand reads bare lines too; write a plain line as well for the file-bus sim
    with open(rp(run, "work", "commands.jsonl"), "a", encoding="utf-8") as f:
        f.write(command + "\n")
    return "issued to host: %s%s" % (command, warn)


# ---------- online callback ----------
def notify(url, payload):
    import urllib.request
    try:
        req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
        return True
    except Exception:
        return False


# ---------- answering (the offline brain: route to state or memory) ----------
def answer(run, scope, q):
    ql = q.lower()
    if any(w in ql for w in ("status", "health", "threat", "infect", "compromis", "host", "okay", "ok?")):
        return fmt_status(run)
    if any(w in ql for w in ("log", "did you", "what have", "recent", "history", "happened", "action")):
        return fmt_log(run, 14)
    mem = recall(run, scope, q)
    if mem:
        return "From the device's memory:\n" + mem
    # last resort: lexical scan of the event stream
    hits = [e for e in read_events(run) if q and any(t in json.dumps(e).lower() for t in ql.split())]
    if hits:
        return fmt_log_from(hits[-8:])
    return "I have nothing in memory or telemetry about that yet. Try 'status', 'log', or ask about the host."


def fmt_log_from(evs):
    rows = []
    for e in evs:
        det = (e.get("result") or e.get("args") or e.get("goal") or "")[:110].replace("\n", " ")
        rows.append("  [r%s] %s %s %s" % (e.get("round", "?"), e.get("mind", "?"), e.get("tool", e.get("kind", "")), det))
    return "\n".join(rows)


# ---------- REPL ----------
def repl(run, scope):
    print("veil-chat — talking to the resident Veil at %s" % run)
    print("  plain text = ask (offline) | /veil <msg> | /say <msg> | /cmd <host cmd> | /status | /log [n] | /watch | /quit\n")
    print(fmt_status(run) + "\n")
    while True:
        try:
            line = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue
        if line in ("/quit", "/exit", "/q"):
            break
        elif line == "/status":
            print(fmt_status(run))
        elif line.startswith("/log"):
            parts = line.split()
            print(fmt_log(run, int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 12))
        elif line == "/watch":
            watch(run)
        elif line.startswith("/veil "):
            msg = line[6:].strip()
            control(run, "veil", text=msg)
            print("(queued to the Veil. waiting for its reply…)")
            print(wait_veil_reply(run))
        elif line.startswith("/say "):
            control(run, "say", text=line[5:].strip())
            print("(sent to the swarm)")
        elif line.startswith("/cmd "):
            print(host_cmd(run, line[5:].strip()))
        else:
            print("veil> " + answer(run, scope, line))
        print()


def wait_veil_reply(run, timeout=90):
    """After op:veil, the engine runs veilConverse next round and logs a mind=veil 'directive' act. Tail for it."""
    start = len(read_events(run))
    deadline = time.time() + timeout
    while time.time() < deadline:
        evs = read_events(run)
        for e in evs[start:]:
            if e.get("kind") == "act" and e.get("mind") == "veil" and e.get("tool") == "directive":
                return "veil> " + (e.get("result") or "").strip()
        time.sleep(1.5)
    return "(no reply yet — the Veil may be offline/idle; it will answer when it next runs a round)"


def watch(run, interval=2.0):
    print("watching %s — Ctrl-C to stop" % run)
    seen = 0
    try:
        while True:
            evs = read_events(run)
            for e in evs[seen:]:
                if e.get("kind") == "act" and e.get("tool") in ("host_command", "recover", "directive"):
                    print("  [r%s] %s %s: %s" % (e.get("round", "?"), e.get("mind", "?"), e.get("tool"),
                                                 (e.get("result") or e.get("args") or "")[:90]))
            seen = len(evs)
            for l in host_log(run, 3):
                if "THREAT DETECTED" in l or "REMEDIATED" in l:
                    print("  HOST: " + l.split("] ", 1)[-1])
            time.sleep(interval)
    except KeyboardInterrupt:
        print()


# ---------- online surface ----------
def serve(run, port, scope):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class H(BaseHTTPRequestHandler):
        def _send(self, code, body):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())

        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.path.startswith("/status"):
                self._send(200, {"status": fmt_status(run)})
            elif self.path.startswith("/log"):
                self._send(200, {"log": fmt_log(run, 20)})
            else:
                self._send(404, {"error": "GET /status | /log"})

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except Exception:
                body = {}
            if self.path.startswith("/chat"):
                control(run, "veil", text=body.get("text", ""))
                self._send(200, {"ok": True, "reply": wait_veil_reply(run, timeout=60)})
            elif self.path.startswith("/ask"):
                self._send(200, {"answer": answer(run, scope, body.get("text", ""))})
            elif self.path.startswith("/cmd"):
                self._send(200, {"result": host_cmd(run, body.get("command", ""))})
            else:
                self._send(404, {"error": "POST /chat | /ask | /cmd"})

    srv = ThreadingHTTPServer(("0.0.0.0", port), H)
    print("veil-chat HTTP surface on :%d  (GET /status /log ; POST /chat /ask /cmd)" % port)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


# ---------- cli ----------
def main():
    ap = argparse.ArgumentParser(description="talk to the resident Veil on an embedded device (offline-first)")
    ap.add_argument("--dir", required=True, help="the Veil's run directory")
    ap.add_argument("--scope", default="knowledge", help="neuron-db scope to query (default: knowledge)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("cmd", nargs="?", default="chat",
                    help="status | log | ask | say | veil | cmd | watch | serve | chat")
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    run, rest = a.dir, " ".join(a.rest).strip()
    if a.cmd == "status":
        print(fmt_status(run))
    elif a.cmd == "log":
        print(fmt_log(run, int(rest) if rest.isdigit() else 12))
    elif a.cmd == "ask":
        print(answer(run, a.scope, rest))
    elif a.cmd == "say":
        control(run, "say", text=rest); print("(sent to the swarm)")
    elif a.cmd == "veil":
        control(run, "veil", text=rest); print("(queued)\n" + wait_veil_reply(run))
    elif a.cmd == "cmd":
        print(host_cmd(run, rest))
    elif a.cmd == "watch":
        watch(run)
    elif a.cmd == "serve":
        serve(run, a.port, a.scope)
    else:
        repl(run, a.scope)


if __name__ == "__main__":
    main()
