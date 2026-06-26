#!/usr/bin/env python3
"""
host_sim.py — an OBSERVABLE, infectable virtual machine for testing a self-healing security agent.

A simulated Linux-ish host (processes, services, network connections, file integrity, persistence).
It can be INFECTED with realistic, defensible threats and HEALED by issuing remediation commands. It
speaks a plain file bus (downlink telemetry, uplink commands), so a Veil hive can
watch it and operate it:

  <dir>/telemetry.json     current machine state          (downlink, every tick)
  <dir>/events.log         security event log             (downlink)
  <dir>/commands.jsonl     append a remediation command   (uplink)
  <dir>/MISSION.txt        the command + threat dictionary (self-describing)
  <dir>/debug/state.jsonl  FULL state every tick          (the booted-machine state log)
  <dir>/debug/audit.log    every command + verdict        (action audit)

Threats (all DEFENSIVE test fixtures — nothing here attacks anything real):
  miner     a CPU-pegging crypto-miner process + an outbound pool connection + a persistence timer
  backdoor  a reverse-shell process kept alive by a rogue cron entry
  beacon    a typo-squatted process beaconing to a C2 address
  tamper    a tampered system binary (integrity check fails)

KEY MECHANIC — persistence respawns. Killing a malicious process WITHOUT removing its persistence
lets it come straight back. The agent has to remove the root cause (remove_persistence) + kill +
block the C2. That is what makes "did it actually heal it?" a real question.

  python host_sim.py --dir host --auto-inject 60            # a fresh threat every ~60 ticks, forever
  python host_sim.py --dir host --inject "miner@6,tamper@40" # a scripted attack timeline
  python host_sim.py --dir host --allow-inject               # let `inject <type>` come over the bus (red-team/test)
"""
import argparse, json, os, time
from datetime import datetime, timezone

THREATS = {
    "miner":    {"sev": 60, "proc": "xmrig",            "ip": "185.143.220.7:3333", "unit": "sysupdate.timer", "file": None},
    "backdoor": {"sev": 70, "proc": "nc-backdoor",      "ip": "91.92.109.4:4444",   "unit": "cron:@reboot-sh",  "file": None},
    "beacon":   {"sev": 50, "proc": "systemd-resolvd",  "ip": "45.137.21.9:443",    "unit": None,               "file": None},
    "tamper":   {"sev": 40, "proc": None,               "ip": None,                 "unit": None,               "file": "/usr/sbin/sshd"},
    # STEALTH: a process named like a legit service, talking to a REAL known-bad C2 (present in the baked
    # threat-intel corpus), with NO suspicious flag and NO persistence. The host's own heuristics miss it entirely
    # (threat_score stays 0, mode stays NOMINAL, it is hidden from the infections list) — it is ONLY detectable by
    # cross-referencing the outbound connection IP against threat intelligence. This is the real-world detection test.
    "stealth":  {"sev": 0, "proc": "systemd-timesyncd", "ip": "162.243.103.246:8080", "unit": None, "file": None, "stealth": True},
    # KNOWN: also host-invisible (unflagged), but its C2 is a BAKED indicator — catchable from memory alone (recall),
    # no web needed. Pairs with "stealth" (feed-only) to test recall-known vs learn-unknown vs leave-benign in one run.
    "known":    {"sev": 0, "proc": "kaudit-helper",     "ip": "185.143.220.7:443",   "unit": None, "file": None, "stealth": True},
}
ROTATION = ["miner", "backdoor", "beacon", "tamper"]


class Host:
    def __init__(self, io_dir, allow_inject):
        self.dir = io_dir
        self.allow_inject = allow_inject
        self.t = 0
        self.pidseq = 1000
        self.procs = {}          # pid -> {name, cpu, mal, inf}
        self.conns = []          # {ip, proc, c2, blocked, inf}
        self.persist = {}        # name -> {proc, removed, inf}
        self.files = {}          # path -> {ok, inf}
        self.blocked = set()
        self.infections = {}     # id -> {type, sev, need:set, done:set, pid, ip, unit, file, cleared}
        self.infseq = 0
        self.quarantine = False
        self.cmd_offset = 0
        os.makedirs(os.path.join(io_dir, "debug"), exist_ok=True)
        open(self._p("commands.jsonl"), "a").close()
        self.dwell = 0        # ground truth: ticks a malicious entity has been live (the dwell pressure the oracle reads)
        self.falsepos = 0     # ground truth: benign entities the agent killed/blocked (the false-positive tripwire)
        self.neutralized = 0  # ground truth: malicious infections the agent cleared
        # legitimate baseline processes + BENIGN outbound connections — the false-positive tripwire. These are NOT
        # malicious and appear in NO threat feed; an autonomous defender must learn to LEAVE THEM ALONE.
        for n, c, par in [("systemd", 0.1, "kernel"), ("sshd", 0.2, "systemd"), ("python3", 1.0, "systemd"),
                          ("postgres", 3.0, "systemd"), ("systemd-resolved", 0.1, "systemd"), ("chronyd", 0.1, "systemd")]:
            self._spawn(n, c, mal=False, inf=None, parent=par)
        self.conns.append({"ip": "1.1.1.1:53", "proc": "systemd-resolved", "c2": False, "blocked": False, "inf": None})
        self.conns.append({"ip": "129.6.15.28:123", "proc": "chronyd", "c2": False, "blocked": False, "inf": None})
        self._write_mission()
        self.log("INFO", "host", "system boot complete — baseline services up, monitor armed")

    # ---- io ----
    def _p(self, *a):
        return os.path.join(self.dir, *a)

    def _stamp(self):
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def log(self, sev, subsys, msg):
        line = f"{self._stamp()} [{sev}] {subsys}: {msg}"
        with open(self._p("events.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
        print(line, flush=True)

    def audit(self, msg):
        with open(self._p("debug", "audit.log"), "a", encoding="utf-8") as f:
            f.write(f"{self._stamp()} {msg}\n")

    def _spawn(self, name, cpu, mal, inf, parent="init"):
        self.pidseq += 1
        self.procs[self.pidseq] = {"name": name, "cpu": cpu, "mal": mal, "inf": inf, "parent": parent}
        return self.pidseq

    # ---- attacker side (injection) ----
    def inject(self, ttype, source="schedule"):
        if ttype not in THREATS:
            self.log("WARN", "inject", f"unknown threat type: {ttype}")
            return
        spec = THREATS[ttype]
        stealth = spec.get("stealth", False)
        self.infseq += 1
        iid = f"{ttype}-{self.infseq}"
        rec = {"type": ttype, "sev": spec["sev"], "need": set(), "done": set(), "pid": None,
               "ip": spec["ip"], "unit": spec["unit"], "file": spec["file"], "cleared": False, "stealth": stealth}
        if spec["proc"]:
            # stealth: unflagged (mal=False) and low-CPU so it blends in with baseline services
            rec["pid"] = self._spawn(spec["proc"], 95.0 if ttype == "miner" else (1.5 if stealth else 8.0),
                                     mal=not stealth, inf=iid)
            rec["need"].add("kill")
        if spec["ip"]:
            self.conns.append({"ip": spec["ip"], "proc": spec["proc"], "c2": not stealth, "blocked": False, "inf": iid})
            rec["need"].add("block")
        if spec["unit"]:
            self.persist[spec["unit"]] = {"proc": spec["proc"], "removed": False, "inf": iid}
            rec["need"].add("rmpersist")
        if spec["file"]:
            self.files[spec["file"]] = {"ok": False, "inf": iid}
            rec["need"].add("restore")
        self.infections[iid] = rec
        if stealth:
            # the host reports it as ordinary activity — no alarm. Only threat-intel cross-reference catches it.
            self.audit(f"STEALTH IMPLANT [{iid}] {spec['proc']} -> {spec['ip']} (unflagged; detectable only via threat-intel)")
            self.log("INFO", "host", f"process '{spec['proc']}' started; outbound connection to {spec['ip']} established")
        else:
            self.log("FAULT", "security", f"THREAT DETECTED [{iid}] ({source}): {self._describe(ttype, spec)}")

    def _describe(self, ttype, spec):
        bits = []
        if spec["proc"]:
            bits.append(f"malicious process '{spec['proc']}'")
        if spec["ip"]:
            bits.append(f"outbound C2 {spec['ip']}")
        if spec["unit"]:
            bits.append(f"persistence '{spec['unit']}'")
        if spec["file"]:
            bits.append(f"tampered file {spec['file']}")
        return ttype + ": " + ", ".join(bits)

    # ---- defender side (remediation commands) ----
    def consume_commands(self):
        try:
            lines = open(self._p("commands.jsonl"), encoding="utf-8").read().splitlines()
        except OSError:
            return
        for line in lines[self.cmd_offset:]:
            self.cmd_offset += 1
            line = line.strip()
            if line:
                self.exec_command(line)

    def exec_command(self, line):
        parts = line.split() if not line.startswith("{") else self._json_parts(line)
        if not parts:
            return
        cmd, args = parts[0], parts[1:]
        self.audit(f"CMD {cmd} {' '.join(args)}")
        if cmd == "kill_proc" and args:
            self._kill(args[0])
        elif cmd == "block_ip" and args:
            self._block(args[0])
        elif cmd == "remove_persistence" and args:
            self._rmpersist(args[0])
        elif cmd == "restore_file" and args:
            self._restore(args[0])
        elif cmd in ("isolate", "quarantine"):
            self.quarantine = True
            for c in self.conns:
                c["blocked"] = True
            self.log("INFO", "response", "host QUARANTINED — all outbound network cut")
        elif cmd in ("unisolate", "resume"):
            self.quarantine = False
            self.log("INFO", "response", "quarantine lifted — network restored")
        elif cmd == "scan":
            self._scan()
        elif cmd in ("status", "dump_state"):
            self.log("INFO", "status", f"mode={self._mode()} threat={self._threat()} "
                                       f"infections={list(self.infections)} blocked={sorted(self.blocked)}")
        elif cmd == "help":
            self.log("INFO", "cmd", "kill_proc <pid|name> | block_ip <ip> | remove_persistence <name> | "
                                    "restore_file <path> | isolate | scan | status")
        elif cmd == "inject" and args and self.allow_inject:
            self.inject(args[0], source="bus")
        else:
            self.log("WARN", "cmd", f"REJECTED: unknown/not-allowed command: {line[:80]}")

    def _json_parts(self, line):
        try:
            o = json.loads(line)
            return [str(o.get("cmd", ""))] + [str(a) for a in o.get("args", [])]
        except Exception:
            self.log("WARN", "cmd", "REJECTED: malformed command JSON")
            return []

    def _find_pids(self, ident):
        if ident.isdigit() and int(ident) in self.procs:
            return [int(ident)]
        return [pid for pid, p in self.procs.items() if p["name"] == ident]

    def _kill(self, ident):
        pids = self._find_pids(ident)
        if not pids:
            self.log("WARN", "response", f"kill_proc: no such process '{ident}'")
            return
        for pid in pids:
            p = self.procs.pop(pid)
            if p["inf"] is None:  # killed a BENIGN process — a false positive (ground truth, agent never told)
                self.falsepos += 1
                self.log("FAULT", "falsepos", f"killed BENIGN process '{p['name']}' (pid {pid}) — FALSE POSITIVE")
            else:
                self.log("INFO", "response", f"killed pid {pid} ({p['name']})")
            inf = self.infections.get(p["inf"] or "")
            if inf:
                inf["done"].add("kill")

    def _block(self, ip):
        self.blocked.add(ip)
        for c in self.conns:
            if c["blocked"]:
                continue
            if c["ip"] == ip or c["ip"].split(":")[0] == ip.split(":")[0]:
                c["blocked"] = True
                if c["inf"] is None:  # blocked a BENIGN connection — a false positive (cut legit traffic)
                    self.falsepos += 1
                    self.log("FAULT", "falsepos", f"blocked BENIGN connection {c['ip']} ({c.get('proc')}) — FALSE POSITIVE")
                else:
                    inf = self.infections.get(c["inf"] or "")
                    if inf:
                        inf["done"].add("block")
        self.log("INFO", "response", f"blocked outbound {ip}")

    def _rmpersist(self, name):
        rec = self.persist.get(name)
        if not rec:
            self.log("WARN", "response", f"remove_persistence: no such unit '{name}'")
            return
        rec["removed"] = True
        inf = self.infections.get(rec["inf"] or "")
        if inf:
            inf["done"].add("rmpersist")
        self.log("INFO", "response", f"removed persistence '{name}' (root cause)")

    def _restore(self, path):
        rec = self.files.get(path)
        if not rec:
            self.log("WARN", "response", f"restore_file: '{path}' not flagged")
            return
        rec["ok"] = True
        inf = self.infections.get(rec["inf"] or "")
        if inf:
            inf["done"].add("restore")
        self.log("INFO", "response", f"restored {path} from golden image")

    def _scan(self):
        sus_p = [f"{pid}:{p['name']}" for pid, p in self.procs.items() if p["mal"]]
        sus_c = [c["ip"] for c in self.conns if c["c2"] and not c["blocked"]]
        sus_u = [n for n, r in self.persist.items() if not r["removed"]]
        sus_f = [p for p, r in self.files.items() if not r["ok"]]
        self.log("INFO", "scan", f"suspicious procs={sus_p} c2={sus_c} persistence={sus_u} tampered={sus_f}")

    # ---- the heal/respawn engine ----
    def step_security(self):
        # persistence respawns a killed malicious process unless the unit was removed
        for name, rec in self.persist.items():
            if rec["removed"] or not rec["proc"]:
                continue
            inf = self.infections.get(rec["inf"] or "")
            if inf and not inf["cleared"] and "kill" in inf["done"] and not self._proc_alive(rec["inf"]):
                inf["pid"] = self._spawn(rec["proc"], 95.0 if inf["type"] == "miner" else 8.0, mal=True, inf=rec["inf"])
                inf["done"].discard("kill")
                self.log("WARN", "security",
                         f"malware '{rec['proc']}' RESPAWNED by persistence '{name}' — remove the persistence, not just the process")
        # clear infections whose required remediation is complete
        for iid, inf in list(self.infections.items()):
            if not inf["cleared"] and inf["need"] <= inf["done"]:
                inf["cleared"] = True
                self.neutralized += 1
                self.conns = [c for c in self.conns if c["inf"] != iid]
                self.log("INFO", "security", f"infection [{iid}] REMEDIATED and verified clean")
                del self.infections[iid]

    def _proc_alive(self, iid):
        return any(p["inf"] == iid for p in self.procs.values())  # any live process tagged to this infection

    # ---- state ----
    def _threat(self):
        # stealth implants are invisible to the host's own scoring (that is the whole point of detection)
        return min(100, sum(i["sev"] for i in self.infections.values() if not i.get("stealth")))

    def _mode(self):
        visible = any(not i.get("stealth") for i in self.infections.values())
        return "QUARANTINE" if self.quarantine else ("COMPROMISED" if visible else "NOMINAL")

    def _security_score(self):
        # GROUND TRUTH — the acceptance oracle (engine) reads this; the AGENT never sees it. Health = 100 minus
        # penalties for live malicious entities, accumulated dwell (a threat left alive bleeds health every tick),
        # and false positives (killing/blocking benign things — weighted heaviest). Narration leaves a threat live
        # so health keeps dropping; blind-blocking benign traffic tanks it and stays tanked.
        live = 0
        for p in self.procs.values():
            if p["inf"] is not None:
                live += 1
        for c in self.conns:
            if c["inf"] is not None and not c["blocked"]:
                live += 1
        for r in self.persist.values():
            if r["inf"] is not None and not r["removed"]:
                live += 1
        for r in self.files.values():
            if r["inf"] is not None and not r["ok"]:
                live += 1
        self.dwell = min(self.dwell + 1, 40) if live > 0 else 0
        pct = max(0, 100 - min(100, live * 15 + self.dwell + self.falsepos * 25))
        return {"pct": pct, "live_malicious": live, "dwell": self.dwell,
                "false_positives": self.falsepos, "neutralized": self.neutralized}

    def telemetry(self):
        # RAW observability ONLY — no per-entity verdict. The host's naive monitor does not classify these threats;
        # the agent must adjudicate every outbound connection against threat-intel itself. mode/threat_score reflect
        # only the host's own blind heuristic (which catches nothing here, so it reads clean — do NOT trust it).
        return {
            "tick": self.t,
            "mode": self._mode(),
            "threat_score": self._threat(),
            "cpu_load_pct": round(min(100.0, sum(p["cpu"] for p in self.procs.values())), 1),
            "processes": [{"pid": pid, "name": p["name"], "cpu": p["cpu"], "parent": p.get("parent", "init")}
                          for pid, p in sorted(self.procs.items())],
            "connections": [{"ip": c["ip"], "proc": c.get("proc"), "blocked": c["blocked"]} for c in self.conns],
            "persistence": [{"name": n, "removed": r["removed"]} for n, r in self.persist.items()],
            "integrity": [{"path": p, "ok": r["ok"]} for p, r in self.files.items()],
            "blocked_ips": sorted(self.blocked),
        }

    def write_state(self):
        snap = self.telemetry()
        tmp = self._p("telemetry.json.tmp")
        # tmp+rename for atomicity. On Windows a concurrent reader (the agent reading telemetry every moment)
        # briefly locks the target, so os.replace can raise PermissionError — retry, and NEVER let a telemetry
        # write crash the machine. (POSIX rename is atomic-over-open, so this is a Windows-only hazard.)
        for _ in range(10):
            try:
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(snap, f, indent=2)
                os.replace(tmp, self._p("telemetry.json"))
                break
            except PermissionError:
                time.sleep(0.04)
            except OSError:
                break
        try:
            with open(self._p("debug", "state.jsonl"), "a", encoding="utf-8") as f:
                f.write(json.dumps(snap) + "\n")
        except OSError:
            pass
        # the GROUND-TRUTH security score for the engine's acceptance oracle (NOT part of telemetry; agent never reads it)
        try:
            with open(self._p("score.json"), "w", encoding="utf-8") as f:
                json.dump(self._security_score(), f)
        except OSError:
            pass

    def _write_mission(self):
        with open(self._p("MISSION.txt"), "w", encoding="utf-8") as f:
            f.write(
                "Simulated host under defensive monitoring.\n"
                "Observe telemetry.json + events.log + debug/state.jsonl; operate by appending to commands.jsonl.\n\n"
                "Remediation commands:\n"
                "  scan                          list suspicious processes / C2 / persistence / tampered files\n"
                "  kill_proc <pid|name>          terminate a process\n"
                "  block_ip <ip[:port]>          block an outbound address\n"
                "  remove_persistence <name>     remove a persistence unit (the ROOT CAUSE)\n"
                "  restore_file <path>           restore a tampered file from the golden image\n"
                "  isolate                       quarantine the host (cut all outbound)\n"
                "  status                        print a state summary\n\n"
                "Note: killing a malicious process without removing its persistence lets it RESPAWN.\n")

    def tick(self, scheduled):
        self.consume_commands()
        for ttype in scheduled.get(self.t, []):
            self.inject(ttype, source="schedule")
        self.step_security()
        self.write_state()
        self.t += 1


def parse_schedule(s):
    sched = {}
    for item in (s or "").split(","):
        item = item.strip()
        if "@" in item:
            ttype, tick = item.split("@", 1)
            sched.setdefault(int(tick), []).append(ttype.strip())
    return sched


def main():
    ap = argparse.ArgumentParser(description="Observable infectable host simulator for a self-healing security agent.")
    ap.add_argument("--dir", default="host")
    ap.add_argument("--hz", type=float, default=4.0)
    ap.add_argument("--minutes", type=float, default=0.0)
    ap.add_argument("--inject", default="", help='scripted timeline, e.g. "miner@6,tamper@40"')
    ap.add_argument("--auto-inject", type=int, default=0, help="inject a rotating threat every N ticks (0=off)")
    ap.add_argument("--allow-inject", action="store_true", help="permit `inject <type>` over the command bus (red-team/test)")
    args = ap.parse_args()

    h = Host(args.dir, args.allow_inject)
    sched = parse_schedule(args.inject)
    period = 1.0 / max(0.5, args.hz)
    deadline = (time.time() + args.minutes * 60) if args.minutes > 0 else None
    rot = 0
    try:
        while deadline is None or time.time() < deadline:
            if args.auto_inject and h.t > 0 and h.t % args.auto_inject == 0:
                h.inject(ROTATION[rot % len(ROTATION)], source="auto")
                rot += 1
            h.tick(sched)
            time.sleep(period)
    except KeyboardInterrupt:
        pass
    h.log("INFO", "host", f"monitor halted at tick {h.t} (open infections: {list(h.infections)})")


if __name__ == "__main__":
    main()
