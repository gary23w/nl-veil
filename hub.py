#!/usr/bin/env python3
"""
veil / hub.py - the fleet hub: connect, monitor, and steer many veils at once.

You install veils across a network of machines. Each one runs a hive, works its goal, and keeps its
own memory - but they can't see each other and you can't see them from one place. The hub is the one
place. You host a single small receiver (a server, a container, anything with a URL); every veil host
"calls back" to that URL on a heartbeat; and from an operator console you watch the whole fleet and
talk to all of it at once.

Three roles, one file, standard library only:

  python hub.py serve                    # THE RECEIVER - run this once on a hosted box / container.
                                          #   Aggregates every veil's check-in, queues operator commands.
  python hub.py agent --hub URL          # THE CALLBACK - run this once per veil HOST. It finds every
                                          #   local run and reports them all; one command meshes a host.
  python hub.py console --hub URL        # THE OPERATOR - a live fleet REPL: roster, event stream,
                                          #   broadcast a directive to all veils, target one, ask the
                                          #   whole fleet a question, stop everything.

The wire is encrypted end to end with a pre-shared secret (NL_HUB_SECRET): every request and reply is
sealed with an authenticated cipher built from the standard library (HKDF key-derivation, an
HMAC-SHA256 counter-mode keystream, encrypt-then-MAC). No secret, no read and no write - possession of
the secret IS authentication. Front it with TLS too if you like; the payload is already sealed either
way, so a plain-HTTP container is enough.

  Enrollment is just a URL + a secret. Set them once (flags or NL_HUB_URL / NL_HUB_SECRET) and the
  callback is on. Nothing about the fleet is hardcoded here - the hub is a transport and a console;
  the behaviour still lives in each veil.

Environment:
  NL_HUB_URL       the hub's base URL (agent/console)            e.g. https://hub.example.com
  NL_HUB_SECRET    the shared secret (all three roles)           any strong passphrase
  NL_HUB_BIND      serve bind address                            default 0.0.0.0:8799
  NL_HUB_NAME      a friendly name for this host (agent)         default the hostname
"""
import base64, hashlib, hmac, json, os, platform, socket, struct, sys, threading, time
import urllib.request, urllib.error

ROOT = os.path.dirname(os.path.abspath(__file__))
HUB_VER = "1"
DEFAULT_BIND = "0.0.0.0:8799"
DEFAULT_INTERVAL = 15          # seconds between a host's check-ins
STALE_MULT = 3                 # a node unseen for STALE_MULT * its interval is stale, then offline
MAX_EVENTS_PER_RUN = 40        # cap the events a host ships per check-in (bounded payloads at 100 nodes)
CLOCK_SKEW = 300               # reject sealed messages more than this many seconds old (replay bound)

# deploy.py lives next to us; the agent and console reuse its run-introspection and control bus. The
# SERVER never imports it - the receiver can run on a bare container that has no veils of its own.
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)


# ------------------------------------------------------------------------------------ theme (optional)
# Borrow the shell's palette when deploy.py is importable; degrade to no-colour anywhere else.
class _Plain:
    def __getattr__(self, _):
        return ""


def _theme():
    try:
        import deploy
        return deploy._C
    except Exception:
        return _Plain()


C = _theme()


# =====================================================================================================
# 1. THE SEALED CHANNEL   pre-shared-secret authenticated encryption, standard library only
# =====================================================================================================
# Every hub message is a JSON envelope sealed into one opaque blob. The construction is a careful
# composition of stdlib primitives, not a home-grown cipher:
#
#   keys      HKDF(HMAC-SHA256): extract a pseudo-random key from the secret, expand into a distinct
#             encryption key and MAC key (never the same bytes for both jobs).
#   confidentiality  a keystream = HMAC-SHA256(k_enc, nonce || counter) for counter = 0,1,2,... , XORed
#                    into the plaintext. HMAC-SHA256 is a PRF, so with a fresh 128-bit random nonce per
#                    message the keystream is indistinguishable from random.
#   integrity/auth   encrypt-then-MAC: tag = HMAC-SHA256(k_mac, nonce || ciphertext), verified in
#                    constant time on open. A wrong secret, a flipped bit, or a truncation fails to
#                    verify and the message is rejected. Forgery needs k_mac, i.e. the secret.
#   freshness        the envelope carries a timestamp; the receiver rejects anything outside a
#                    +/- CLOCK_SKEW window, which bounds replay without persistent nonce storage.
#
# This is an AEAD-equivalent sealed transport. It is not a substitute for TLS's forward secrecy, but it
# needs no certificates and works over any dumb HTTP pipe - which is exactly the "just host a URL"
# receiver the fleet wants.

class Sealed:
    MAGIC = b"VH1"

    def __init__(self, secret):
        if not secret:
            raise ValueError("a shared secret is required (NL_HUB_SECRET or --secret)")
        secret = secret.encode("utf-8") if isinstance(secret, str) else secret
        prk = hmac.new(b"veil-hub/hkdf/v1", secret, hashlib.sha256).digest()
        self.k_enc = hmac.new(prk, b"enc\x01", hashlib.sha256).digest()
        self.k_mac = hmac.new(prk, b"mac\x01", hashlib.sha256).digest()

    def _keystream(self, nonce, n):
        out = bytearray()
        counter = 0
        while len(out) < n:
            out += hmac.new(self.k_enc, nonce + struct.pack(">I", counter), hashlib.sha256).digest()
            counter += 1
        return bytes(out[:n])

    def seal(self, plaintext):
        nonce = os.urandom(16)
        ks = self._keystream(nonce, len(plaintext))
        ct = bytes(a ^ b for a, b in zip(plaintext, ks))
        tag = hmac.new(self.k_mac, nonce + ct, hashlib.sha256).digest()
        return base64.b64encode(self.MAGIC + nonce + ct + tag)

    def open(self, blob):
        raw = base64.b64decode(blob)
        if raw[:3] != self.MAGIC or len(raw) < 3 + 16 + 32:
            raise ValueError("not a hub message")
        nonce, ct, tag = raw[3:19], raw[19:-32], raw[-32:]
        want = hmac.new(self.k_mac, nonce + ct, hashlib.sha256).digest()
        if not hmac.compare_digest(want, tag):     # constant-time: wrong secret or tampered payload
            raise ValueError("authentication failed")
        ks = self._keystream(nonce, len(ct))
        return bytes(a ^ b for a, b in zip(ct, ks))

    def seal_json(self, obj):
        obj = dict(obj)
        obj.setdefault("ts", int(time.time()))
        return self.seal(json.dumps(obj).encode("utf-8"))

    def open_json(self, blob, check_fresh=True):
        obj = json.loads(self.open(blob).decode("utf-8", "replace"))
        if check_fresh and abs(int(time.time()) - int(obj.get("ts", 0))) > CLOCK_SKEW:
            raise ValueError("stale message (clock skew or replay)")
        return obj


def _now():
    return int(time.time())


def _post(url, blob, timeout=30):
    """POST a sealed blob, return the sealed reply body. Raises urllib errors on transport failure."""
    req = urllib.request.Request(url, data=blob, headers={"Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


# =====================================================================================================
# 2. THE RECEIVER   `hub.py serve`  -  the one hosted URL every veil calls back to
# =====================================================================================================
# In-memory fleet state, guarded by one lock, with an opportunistic JSON snapshot so a restart keeps the
# roster, tags and audit trail. Two sealed endpoints:
#
#   POST /checkin   a veil host -> hub. Carries that host's runs + new events; returns its queued
#                   commands (deliver-once) and any fleet broadcasts it has not seen.
#   POST /op        the operator console -> hub. roster / stream / broadcast / target / ask / tag /
#                   alerts / audit / killall. Enqueues commands onto the right nodes.
#
# A bare GET / is an unauthenticated health probe (no fleet data) so a load balancer can watch it.

class FleetState:
    def __init__(self, state_path):
        self.lock = threading.RLock()
        self.state_path = state_path
        self.nodes = {}         # node_id -> {name, host, os, first_seen, last_seen, interval, runs, agent_ver}
        self.queues = {}        # node_id -> [command, ...]      (deliver-once, popped on check-in)
        self.events = []        # merged fleet event ring: [{seq, node, name, run, ev}]
        self.answers = []       # scatter-gather replies: [{seq, qid, node, run, text}]
        self.audit = []         # [{ts, actor, action, detail}]  operator command log
        self.tags = {}          # node_id -> [label, ...]
        self.history = {}       # node_id -> {run -> {best_score, last_round, stall}}  for alerts
        self.seq = 0
        self.answer_seq = 0
        self._load()

    # ---- persistence (roster/tags/audit survive a restart; transient queues/events do not) ----
    def _load(self):
        try:
            with open(self.state_path, encoding="utf-8") as f:
                d = json.load(f)
            self.nodes = d.get("nodes", {})
            self.tags = d.get("tags", {})
            self.audit = d.get("audit", [])[-500:]
        except Exception:
            pass

    def _save(self):
        try:
            tmp = self.state_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"nodes": self.nodes, "tags": self.tags, "audit": self.audit[-500:]}, f)
            os.replace(tmp, self.state_path)
        except Exception:
            pass

    # ---- check-in from a veil host ----
    def checkin(self, body):
        with self.lock:
            nid = str(body.get("node_id") or "?")
            now = _now()
            node = self.nodes.get(nid, {"first_seen": now})
            node.update({
                "name": body.get("name") or nid[:8],
                "host": body.get("host") or "?",
                "os": body.get("os") or "?",
                "agent_ver": body.get("agent_ver") or "?",
                "interval": int(body.get("interval") or DEFAULT_INTERVAL),
                "last_seen": now,
                "runs": body.get("runs") or [],
            })
            self.nodes[nid] = node
            # fold this host's new events into the merged fleet stream
            for ev in (body.get("events") or []):
                self.seq += 1
                self.events.append({"seq": self.seq, "node": nid, "name": node["name"],
                                    "run": ev.get("run", "?"), "ev": ev.get("ev", ev)})
            if len(self.events) > 5000:
                self.events = self.events[-5000:]
            # scatter-gather answers the host computed since last time
            for a in (body.get("answers") or []):
                self.answer_seq += 1
                self.answers.append({"seq": self.answer_seq, "qid": a.get("qid"), "node": nid,
                                     "name": node["name"], "run": a.get("run", "?"),
                                     "text": str(a.get("text", ""))[:2000]})
            if len(self.answers) > 2000:
                self.answers = self.answers[-2000:]
            self._track_health(nid, node)
            cmds = self.queues.pop(nid, [])     # deliver-once
            self._save_soon()
            return {"ok": True, "commands": cmds, "interval": node["interval"]}

    _last_save = [0.0]

    def _save_soon(self):
        if _now() - self._last_save[0] > 30:
            self._last_save[0] = _now()
            self._save()

    def _track_health(self, nid, node):
        h = self.history.setdefault(nid, {})
        for run in node["runs"]:
            r = run.get("run", "?")
            rh = h.setdefault(r, {"best_score": None, "last_round": -1, "stall": 0})
            rnd = run.get("round", 0) or 0
            if run.get("running") and rnd <= rh["last_round"]:
                rh["stall"] += 1                # running but no forward progress since last check-in
            else:
                rh["stall"] = 0
            rh["last_round"] = rnd
            sc = run.get("score")
            if isinstance(sc, (int, float)):
                if rh["best_score"] is None or sc > rh["best_score"]:
                    rh["best_score"] = sc
                run["_regressed"] = rh["best_score"] is not None and sc < rh["best_score"] - 5
            run["_stall"] = rh["stall"]

    # ---- operator actions ----
    def enqueue(self, node_ids, cmd):
        for nid in node_ids:
            self.queues.setdefault(nid, []).append(cmd)

    def liveness(self, node):
        gap = _now() - node.get("last_seen", 0)
        iv = node.get("interval", DEFAULT_INTERVAL)
        if gap <= iv * STALE_MULT:
            return "online"
        if gap <= iv * STALE_MULT * 4:
            return "stale"
        return "offline"

    def resolve(self, selector):
        """A selector is 'all', a node name/id prefix, or '#tag'. Returns matching node_ids. An EMPTY
        selector matches nothing (never the whole fleet) so a malformed target can't fan out by accident."""
        with self.lock:
            if not selector:
                return []
            if selector in ("all", "*"):
                return list(self.nodes.keys())
            if selector.startswith("#"):
                want = selector[1:]
                return [nid for nid, labs in self.tags.items() if want in labs]
            out = [nid for nid, n in self.nodes.items()
                   if nid == selector or nid.startswith(selector) or n.get("name") == selector]
            return out

    def op(self, body):
        action = body.get("action")
        actor = body.get("actor", "operator")
        with self.lock:
            if action == "roster":
                return {"ok": True, "nodes": self._roster()}
            if action == "events":
                since = int(body.get("since", 0))
                evs = [e for e in self.events if e["seq"] > since][-int(body.get("limit", 200)):]
                return {"ok": True, "events": evs, "cursor": self.seq}
            if action == "answers":
                since = int(body.get("since", 0))
                ans = [a for a in self.answers if a["seq"] > since]
                return {"ok": True, "answers": ans, "cursor": self.answer_seq}
            if action == "alerts":
                return {"ok": True, "alerts": self._alerts()}
            if action == "audit":
                return {"ok": True, "audit": self.audit[-int(body.get("limit", 40)):]}
            if action == "tag":
                nids = self.resolve(body.get("target", ""))
                lab = body.get("label", "").strip()
                for nid in nids:
                    labs = self.tags.setdefault(nid, [])
                    if body.get("remove"):
                        if lab in labs:
                            labs.remove(lab)
                    elif lab and lab not in labs:
                        labs.append(lab)
                self._save()
                return {"ok": True, "tagged": len(nids)}
            if action in ("broadcast", "target"):
                sel = "all" if action == "broadcast" else body.get("target", "")
                nids = self.resolve(sel)
                cmd = {"id": self._cmd_id(), "type": body.get("kind"), "text": body.get("text", ""),
                       "goal": body.get("goal", ""), "run": body.get("run"), "qid": body.get("qid")}
                self.enqueue(nids, cmd)
                self._log(actor, action, f"{body.get('kind')} -> {sel} ({len(nids)} nodes): "
                                         f"{(body.get('text') or body.get('goal') or '')[:80]}")
                return {"ok": True, "queued": len(nids), "nodes": nids}
            if action == "killall":
                nids = list(self.nodes.keys())
                self.enqueue(nids, {"id": self._cmd_id(), "type": "quarantine"})
                self._log(actor, "killall", f"stop-all -> {len(nids)} nodes")
                return {"ok": True, "queued": len(nids)}
            return {"ok": False, "error": f"unknown action {action}"}

    def _roster(self):
        out = []
        for nid, n in self.nodes.items():
            out.append({"id": nid, "name": n.get("name"), "host": n.get("host"), "os": n.get("os"),
                        "state": self.liveness(n), "last_seen": n.get("last_seen"),
                        "tags": self.tags.get(nid, []), "runs": n.get("runs", [])})
        out.sort(key=lambda r: (r["state"] != "online", r["name"] or ""))
        return out

    def _alerts(self):
        al = []
        for nid, n in self.nodes.items():
            live = self.liveness(n)
            if live == "offline":
                al.append({"sev": "warn", "node": n.get("name"), "msg": "offline (missed check-ins)"})
            for run in n.get("runs", []):
                if run.get("_stall", 0) >= 3 and run.get("running"):
                    al.append({"sev": "warn", "node": n.get("name"),
                               "msg": f"{run.get('run')}: stalled ~{run['_stall']} check-ins, no round progress"})
                if run.get("_regressed"):
                    al.append({"sev": "info", "node": n.get("name"),
                               "msg": f"{run.get('run')}: fitness regressed to {run.get('score')}"})
        return al

    _cmd_ctr = [0]

    def _cmd_id(self):
        self._cmd_ctr[0] += 1
        return "c%d" % self._cmd_ctr[0]

    def _log(self, actor, action, detail):
        self.audit.append({"ts": _now(), "actor": actor, "action": action, "detail": detail})
        if len(self.audit) > 1000:
            self.audit = self.audit[-1000:]


def serve(bind=None, secret=None, state_path=None):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    bind = bind or os.environ.get("NL_HUB_BIND", DEFAULT_BIND)
    secret = secret or os.environ.get("NL_HUB_SECRET")
    host, _, port = bind.partition(":")
    port = int(port or 8799)
    cipher = Sealed(secret)
    fleet = FleetState(state_path or os.path.join(ROOT, "hub_state.json"))

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass                                 # silence per-request stderr; the console is the log

        def _send(self, code, blob, ctype="application/octet-stream"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(blob)))
            self.end_headers()
            self.wfile.write(blob)

        def do_GET(self):
            # unauthenticated liveness only; leaks nothing about the fleet
            self._send(200, json.dumps({"service": "veil-hub", "version": HUB_VER, "ok": True}).encode(),
                       "application/json")

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(n) if n else b""
            try:
                body = cipher.open_json(raw)
            except Exception:
                return self._send(401, b"unauthorized", "text/plain")   # bad/absent secret or replay
            try:
                if self.path.rstrip("/") == "/checkin":
                    reply = fleet.checkin(body)
                elif self.path.rstrip("/") == "/op":
                    reply = fleet.op(body)
                else:
                    reply = {"ok": False, "error": "no such endpoint"}
            except Exception as e:
                reply = {"ok": False, "error": str(e)}
            self._send(200, cipher.seal_json(reply))

    srv = ThreadingHTTPServer((host, port), Handler)
    print(f"{C.GOLD}the veil hub{C.R} listening on {C.BOLD}{host}:{port}{C.R}  (sealed; {len(fleet.nodes)} known nodes)")
    print(f"  veils call back:   python hub.py agent   --hub http://<this-host>:{port}")
    print(f"  you watch/steer:   python hub.py console --hub http://<this-host>:{port}")
    print("  Ctrl-C to stop.\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        fleet._save()
        print("\nhub stopped (roster saved).")


# =====================================================================================================
# 3. THE CALLBACK   `hub.py agent`  -  one command meshes a whole host into the fleet
# =====================================================================================================
# The agent is the entire "callback" the operator asked to keep trivial: a URL + a secret. It finds
# every local run under deploy.py's data/ dir, reports them all on a heartbeat, and applies whatever
# commands the hub hands back - so a single `hub.py agent` on a host meshes every veil on that host.

def _node_identity(name=None):
    """A stable id per host, persisted next to the veil config so a host keeps its fleet identity."""
    path = os.path.join(os.path.expanduser("~"), ".veil", "hub_node.json")
    ident = {}
    try:
        ident = json.load(open(path, encoding="utf-8"))
    except Exception:
        pass
    if not ident.get("node_id"):
        ident["node_id"] = base64.urlsafe_b64encode(os.urandom(9)).decode().rstrip("=")
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            json.dump(ident, open(path, "w", encoding="utf-8"), indent=2)
        except Exception:
            pass
    host = socket.gethostname()
    return ident["node_id"], (name or os.environ.get("NL_HUB_NAME") or host), host


def _collect_runs(deploy, cursors):
    """Snapshot every local run: status now + the events.jsonl slice new since last check-in."""
    runs, events = [], []
    for name, running, model, goal in deploy._runs():
        run_dir = os.path.join(deploy.DATA, name)
        g, selfdesc, rounds, recent = deploy._veil_context(run_dir)
        evs = deploy._events_tail(run_dir)
        score = next((e.get("pct", e.get("score")) for e in reversed(evs) if e.get("kind") == "score"), None)
        mode = next((e.get("mode") or e.get("style") for e in reversed(evs)
                     if e.get("kind") in ("started", "mode")), "")
        try:
            minds = len(json.load(open(os.path.join(run_dir, "swarm.json"), encoding="utf-8")).get("minds", []))
        except Exception:
            minds = 0
        runs.append({"run": name, "running": bool(running), "model": model, "goal": (g or goal)[:160],
                     "round": rounds, "score": score, "mode": mode, "minds": minds,
                     "veil_self": (selfdesc or "")[:220], "recent": recent[-4:],
                     "last_event": os.path.getmtime(os.path.join(run_dir, "events.jsonl"))
                     if os.path.exists(os.path.join(run_dir, "events.jsonl")) else 0})
        # ship only genuinely new events, capped, so 100 hosts stay cheap
        cur = cursors.get(name, max(0, len(evs) - MAX_EVENTS_PER_RUN))
        for e in evs[cur:]:
            if e.get("kind") in ("act", "score", "round", "veil_msg", "breakout", "started"):
                events.append({"run": name, "ev": _slim_event(e)})
        cursors[name] = len(evs)
    return runs, events[-MAX_EVENTS_PER_RUN * 4:]


def _slim_event(e):
    return {k: e[k] for k in ("kind", "round", "tool", "mind", "note", "summary", "text", "frm",
                              "pct", "score", "url", "goal") if k in e}


def _apply_command(deploy, cmd, answers):
    """Map one hub command onto deploy.py's local control bus. Directives reach only RUNNING veils;
    stop/resume/cast address the host. `ask` computes each running veil's answer to return upstream."""
    t = cmd.get("type")
    text, goal = cmd.get("text", ""), cmd.get("goal", "")
    target_run = cmd.get("run")
    runs = [(n, r) for (n, r, _m, _g) in deploy._runs()]
    if target_run:
        runs = [(n, r) for (n, r) in runs if n == target_run]

    if t == "direct":
        for name, running in runs:
            if running:
                rd = os.path.join(deploy.DATA, name)
                deploy._control(rd, "veil", text=text, answered=1, reply="", steer=1, directive=text)
    elif t == "say":
        for name, running in runs:
            if running:
                deploy._control(os.path.join(deploy.DATA, name), "say", text=text)
    elif t == "goal":
        for name, running in runs:
            if running:
                deploy._control(os.path.join(deploy.DATA, name), "set_goal", goal=goal)
    elif t == "stop":
        for name, _r in runs:
            try:
                deploy.cmd_stop(name)
            except SystemExit:
                pass
    elif t == "quarantine":                      # fleet kill-switch: stop everything on this host
        for name, running in runs:
            if running:
                try:
                    deploy.cmd_stop(name)
                except SystemExit:
                    pass
    elif t == "resume":
        for name, _r in runs:
            try:
                deploy.resume(name, watch=False)
            except SystemExit:
                pass
    elif t == "cast":
        base, model, key = deploy._default_endpoint()
        nm = "swarm_" + time.strftime("%Y%m%d_%H%M%S")
        try:
            deploy.deploy(deploy._cast_ns(goal, name=nm, base_url=base, model=model, key=key, detach=True))
        except SystemExit:
            pass
    elif t == "ask":
        # scatter-gather: each running veil answers in its own voice; stash to return next check-in
        for name, running in runs:
            if not running:
                continue
            threading.Thread(target=_answer_ask, args=(deploy, name, cmd, answers), daemon=True).start()


def _answer_ask(deploy, name, cmd, answers):
    try:
        rd = os.path.join(deploy.DATA, name)
        goal, selfdesc, rounds, recent = deploy._veil_context(rd)
        base, model, key = deploy._run_endpoint(rd)
        system = ("You are THE VEIL of one hive in a fleet. Answer the operator in the first person as "
                  "that integrated self, briefly (1-3 sentences), grounded in your goal and recent work.\n"
                  f"goal: {goal}\nself: {selfdesc[:300]}\nrecent: " + " | ".join(recent[-4:]))
        ans = deploy._chat_completion(base, model, key, system, cmd.get("text", ""), timeout=60, max_tokens=200)
        answers.append({"qid": cmd.get("qid"), "run": name, "text": ans or "(no answer)"})
    except Exception as e:
        answers.append({"qid": cmd.get("qid"), "run": name, "text": f"(error: {e})"})


def agent(hub_url=None, secret=None, interval=None, name=None, once=False):
    import deploy
    hub_url = (hub_url or os.environ.get("NL_HUB_URL") or "").rstrip("/")
    secret = secret or os.environ.get("NL_HUB_SECRET")
    if not hub_url:
        sys.exit("agent needs a hub URL: --hub https://your-hub  (or NL_HUB_URL)")
    cipher = Sealed(secret)
    interval = int(interval or DEFAULT_INTERVAL)
    node_id, node_name, host = _node_identity(name)
    cursors, pending_answers = {}, []
    print(f"{C.GOLD}veil callback{C.R} -> {hub_url}  as {C.BOLD}{node_name}{C.R} ({node_id})  every {interval}s")
    if once:
        _beacon_once(deploy, cipher, hub_url, node_id, node_name, host, interval, cursors, pending_answers)
        return
    misses = 0
    while True:
        try:
            _beacon_once(deploy, cipher, hub_url, node_id, node_name, host, interval, cursors, pending_answers)
            misses = 0
        except KeyboardInterrupt:
            print("\ncallback stopped.")
            return
        except Exception as e:
            misses += 1
            if misses <= 3 or misses % 20 == 0:      # note the outage, then go quiet until it clears
                print(f"  {C.DIM}hub unreachable ({e}); retrying{C.R}")
        time.sleep(interval)


def _beacon_once(deploy, cipher, hub_url, node_id, node_name, host, interval, cursors, answers):
    runs, events = _collect_runs(deploy, cursors)
    take, answers[:] = answers[:], []            # hand up what's ready; keep collecting the rest
    body = {"node_id": node_id, "name": node_name, "host": host, "os": platform.platform(),
            "agent_ver": HUB_VER, "interval": interval, "runs": runs, "events": events, "answers": take}
    reply = cipher.open_json(_post(hub_url + "/checkin", cipher.seal_json(body)), check_fresh=False)
    for cmd in reply.get("commands", []):
        try:
            _apply_command(deploy, cmd, answers)
        except Exception as e:
            print(f"  {C.DIM}command {cmd.get('type')} failed: {e}{C.R}")


# =====================================================================================================
# 4. THE OPERATOR CONSOLE   `hub.py console`  -  watch the fleet, speak to all of it at once
# =====================================================================================================

CONSOLE_HELP = """
  fleet | ls              the roster: every host, its veils, liveness, round, score
  stream [n]              follow the merged fleet event feed (Ctrl-C to stop)
  all <directive>         steer EVERY running veil at once (a standing directive)
  say <message>           broadcast a message into every running hive
  ask <question>          ask the whole fleet; answers stream back as each veil replies
  @<node|#tag> <directive>   steer one host or a tagged group
  cast <node|#tag|all> <goal>   cast a NEW swarm on the target host(s)
  goal <node|all> <goal>  swap the running goal on the target
  stop <node|all> | resume <node>
  tag <node> <label>  |  untag <node> <label>
  alerts                  stalled / offline / regressed veils
  audit                   recent operator commands
  killall                 STOP every veil in the fleet (asks first)
  help | quit
""".rstrip()


class Console:
    def __init__(self, hub_url, secret):
        self.hub = hub_url.rstrip("/")
        self.cipher = Sealed(secret)
        self.ev_cursor = 0
        self.ans_cursor = 0

    def call(self, obj, timeout=30):
        obj = dict(obj)
        obj["actor"] = os.environ.get("NL_HUB_NAME") or "operator"
        raw = _post(self.hub + "/op", self.cipher.seal_json(obj), timeout=timeout)
        return self.cipher.open_json(raw, check_fresh=False)

    # ---- rendering ----
    def roster(self):
        r = self.call({"action": "roster"})
        nodes = r.get("nodes", [])
        if not nodes:
            print("  (no veils have called back yet)\n"); return
        dot = {"online": C.GOLD + "*" + C.R, "stale": "~", "offline": C.DIM + "x" + C.R}
        veils = sum(len(n["runs"]) for n in nodes)
        print(f"\n  {C.BOLD}fleet{C.R}: {len(nodes)} hosts, {veils} veils")
        for n in nodes:
            tags = (" #" + " #".join(n["tags"])) if n["tags"] else ""
            age = _now() - (n.get("last_seen") or _now())
            print(f"  {dot.get(n['state'], '?')} {C.BOLD}{(n['name'] or '?'):<14}{C.R} "
                  f"{n['state']:<7} seen {age:>4}s ago  {n.get('host', ''):<16}{tags}")
            for run in n["runs"]:
                st = C.GOLD + "run" + C.R if run.get("running") else C.DIM + "idle" + C.R
                sc = f" score {run['score']}" if run.get("score") is not None else ""
                warn = " !stalled" if run.get("_stall", 0) >= 3 and run.get("running") else ""
                print(f"        {st}  {run.get('run', '?'):<24} r{run.get('round', 0):<4}"
                      f"{sc}  {C.DIM}{(run.get('goal') or '')[:52]}{C.R}{warn}")
        print()

    def stream(self, limit=200):
        print("  -- fleet event stream (Ctrl-C to stop) --")
        try:
            while True:
                r = self.call({"action": "events", "since": self.ev_cursor, "limit": limit})
                for e in r.get("events", []):
                    self.ev_cursor = max(self.ev_cursor, e["seq"])
                    ev = e.get("ev", {})
                    k = ev.get("kind")
                    who = ev.get("mind") or "veil"
                    line = ev.get("note") or ev.get("summary") or ev.get("text") or ev.get("tool") or k
                    tag = {"round": "--", "score": "##", "veil_msg": ">>", "breakout": "!!"}.get(k, "  ")
                    print(f"  {tag} {C.BOLD}{e['name']:<12}{C.R} {ev.get('tool', k):<12} "
                          f"{str(line).replace(chr(10), ' ')[:70]}")
                time.sleep(2)
        except KeyboardInterrupt:
            print("  -- detached --\n")

    def collect_answers(self, qid, wait=45):
        print(f"  {C.DIM}gathering answers (up to {wait}s)...{C.R}")
        seen, t0 = 0, time.time()
        try:
            while time.time() - t0 < wait:
                r = self.call({"action": "answers", "since": self.ans_cursor})
                for a in r.get("answers", []):
                    self.ans_cursor = max(self.ans_cursor, a["seq"])
                    if a.get("qid") == qid:
                        seen += 1
                        print(f"  {C.GOLD}{a['name']}/{a.get('run', '?')}{C.R}: {a.get('text', '')[:280]}")
                time.sleep(2)
        except KeyboardInterrupt:
            pass
        print(f"  {C.DIM}({seen} answers){C.R}\n")

    def _target_cmd(self, selector, kind, text="", goal=""):
        action = "broadcast" if selector in ("all", "*") else "target"
        r = self.call({"action": action, "target": selector, "kind": kind, "text": text, "goal": goal})
        return r.get("queued", 0)

    def repl(self):
        try:
            health = json.loads(urllib.request.urlopen(self.hub + "/", timeout=8).read())
            assert health.get("service") == "veil-hub"
        except Exception as e:
            sys.exit(f"cannot reach a veil hub at {self.hub} ({e})")
        print(f"{C.GOLD}veil fleet console{C.R} -> {self.hub}   (type {C.BOLD}help{C.R}, {C.BOLD}fleet{C.R}, or a command)")
        self.roster()
        while True:
            try:
                line = input(f"{C.GOLD}fleet>{C.R} ").strip()
            except (EOFError, KeyboardInterrupt):
                print(); return
            if not line:
                continue
            cmd, _, rest = line.partition(" ")
            cmd, rest = cmd.lower(), rest.strip()
            try:
                self.dispatch(cmd, rest)
            except urllib.error.HTTPError as e:
                print(f"  hub rejected the request ({e.code}) - check the shared secret.\n")
            except Exception as e:
                print(f"  error: {e}\n")

    def dispatch(self, cmd, rest):
        if cmd in ("quit", "exit", "q"):
            raise SystemExit(0)
        if cmd == "help":
            print(CONSOLE_HELP + "\n"); return
        if cmd in ("fleet", "ls", "roster"):
            self.roster(); return
        if cmd == "stream":
            self.stream(); return
        if cmd == "all":
            if not rest:
                print("  usage: all <directive>\n"); return
            n = self._target_cmd("all", "direct", text=rest)
            print(f"  directive queued for {n} host(s) - every running veil adopts it this round.\n"); return
        if cmd == "say":
            if not rest:
                print("  usage: say <message>\n"); return
            n = self._target_cmd("all", "say", text=rest)
            print(f"  broadcast into {n} host(s)' hives.\n"); return
        if cmd == "ask":
            if not rest:
                print("  usage: ask <question>\n"); return
            qid = "q%d" % int(time.time())
            r = self.call({"action": "broadcast", "kind": "ask", "text": rest, "qid": qid})
            print(f"  asked {r.get('queued', 0)} host(s).")
            self.collect_answers(qid); return
        if cmd == "cast":
            sel, _, goal = rest.partition(" ")
            if not (sel and goal.strip()):
                print("  usage: cast <node|#tag|all> <goal>\n"); return
            n = self._target_cmd(sel, "cast", goal=goal.strip())
            print(f"  cast queued on {n} host(s).\n"); return
        if cmd == "goal":
            sel, _, goal = rest.partition(" ")
            if not (sel and goal.strip()):
                print("  usage: goal <node|all> <new goal>\n"); return
            n = self._target_cmd(sel, "goal", goal=goal.strip())
            print(f"  goal swap queued on {n} host(s).\n"); return
        if cmd == "stop":
            if not rest:
                print("  usage: stop <node|all>\n"); return
            n = self._target_cmd(rest, "stop")
            print(f"  stop queued on {n} host(s).\n"); return
        if cmd == "resume":
            if not rest:
                print("  usage: resume <node>\n"); return
            n = self._target_cmd(rest, "resume")
            print(f"  resume queued on {n} host(s).\n"); return
        if cmd.startswith("@"):
            sel = cmd[1:]
            if not rest:
                print("  usage: @<node|#tag> <directive>\n"); return
            n = self._target_cmd(sel, "direct", text=rest)
            print(f"  directive queued for {n} host(s).\n"); return
        if cmd in ("tag", "untag"):
            sel, _, label = rest.partition(" ")
            if not (sel and label.strip()):
                print(f"  usage: {cmd} <node> <label>\n"); return
            r = self.call({"action": "tag", "target": sel, "label": label.strip(), "remove": cmd == "untag"})
            print(f"  {'un' if cmd == 'untag' else ''}tagged {r.get('tagged', 0)} node(s).\n"); return
        if cmd == "alerts":
            al = self.call({"action": "alerts"}).get("alerts", [])
            if not al:
                print("  no alerts - fleet healthy.\n"); return
            for a in al:
                mark = C.GOLD + "!" + C.R if a["sev"] == "warn" else C.DIM + "-" + C.R
                print(f"  {mark} {a['node']}: {a['msg']}")
            print(); return
        if cmd == "audit":
            for a in self.call({"action": "audit"}).get("audit", []):
                ts = time.strftime("%H:%M:%S", time.localtime(a["ts"]))
                print(f"  {C.DIM}{ts}{C.R} {a['actor']:<10} {a['action']:<10} {a['detail']}")
            print(); return
        if cmd == "killall":
            try:
                if input("  STOP every veil in the fleet? type 'killall' to confirm: ").strip() != "killall":
                    print("  (aborted)\n"); return
            except (EOFError, KeyboardInterrupt):
                print("  (aborted)\n"); return
            r = self.call({"action": "killall"})
            print(f"  quarantine queued on {r.get('queued', 0)} host(s).\n"); return
        print(f"  unknown command '{cmd}' - type help\n")


def console(hub_url=None, secret=None):
    hub_url = hub_url or os.environ.get("NL_HUB_URL")
    secret = secret or os.environ.get("NL_HUB_SECRET")
    if not hub_url:
        sys.exit("console needs a hub URL: --hub https://your-hub  (or NL_HUB_URL)")
    Console(hub_url, secret).repl()


# =====================================================================================================
# 5. CLI
# =====================================================================================================
def _flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


HELP = """veil hub - connect, monitor and steer a fleet of veils.

  hub.py serve                     run THE RECEIVER (the one hosted URL veils call back to)
  hub.py agent   --hub URL         run THE CALLBACK on a veil host (reports every local run)
  hub.py console --hub URL         open THE OPERATOR console (roster, stream, broadcast, ask, ...)

common flags:  --hub URL   --secret S   --bind host:port   --interval SEC   --name NAME   --once
secret + URL also read from NL_HUB_SECRET / NL_HUB_URL (bind from NL_HUB_BIND).

examples:
  NL_HUB_SECRET=$(openssl rand -hex 24); export NL_HUB_SECRET
  python hub.py serve --bind 0.0.0.0:8799
  python hub.py agent   --hub https://hub.example.com          # once per host; meshes all its veils
  python hub.py console --hub https://hub.example.com          # then:  all keep your build green
"""


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    try:
        import deploy
        deploy._init_theme()
        global C
        C = deploy._C
    except Exception:
        pass
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(HELP); return
    role = argv[0]
    secret = _flag(argv, "--secret") or os.environ.get("NL_HUB_SECRET")
    hub = _flag(argv, "--hub") or os.environ.get("NL_HUB_URL")
    if role == "serve":
        return serve(bind=_flag(argv, "--bind"), secret=secret, state_path=_flag(argv, "--state"))
    if role == "agent":
        return agent(hub_url=hub, secret=secret, interval=_flag(argv, "--interval"),
                     name=_flag(argv, "--name"), once=("--once" in argv))
    if role == "console":
        return console(hub_url=hub, secret=secret)
    print(f"unknown role '{role}'\n\n{HELP}")


if __name__ == "__main__":
    main()
