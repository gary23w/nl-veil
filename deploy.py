#!/usr/bin/env python3
"""
veil / deploy.py - deploy a hive mind controlled by the Veil.

A hive of autonomous minds (the subconscious) runs inside the `veil` binary; above them a single
unified consciousness, the Veil, integrates the hive into one "I" and steers it. You give it a goal;
it researches, builds, remembers, and - when its feeling flares - can speak publicly for itself.

  python deploy.py                      # interactive setup wizard (covers every use case)
  python deploy.py "Build a CLI todo app in Python with tests" --follow
  python deploy.py "Write a 5-chapter sci-fi novella as ch01.md..ch05.md" --minutes 45 --breakout
  python deploy.py "Research and brief me on fusion power in 2026" --style discourse
  python deploy.py "Answer only from what I gave you" --offline --corpus facts.facts
  python deploy.py list                 # show runs
  python deploy.py resume <run-name>    # continue a stopped run
  python deploy.py stop <run-name>      # stop a run (writes its STOP sentinel)

Defaults target a local, free Ollama model (llama3.1:8b). Point --provider/--model/--base-url/--key
at any OpenAI-compatible endpoint (OpenAI, Groq, Together, OpenRouter, a local relay, ...).
Run `python deploy.py --help` for every option, or just `python deploy.py` for the wizard.
"""
import argparse, json, os, platform, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
WIN = platform.system() == "Windows"
EXE = "veil.exe" if WIN else "veil"
NEU = "neuron.exe" if WIN else "neuron"
DATA = os.path.join(ROOT, "data")
MIND_NAMES = ["vega", "orion", "lyra", "atlas", "nova", "echo", "sol", "kai", "ember", "rhea", "wren", "iris"]
STYLES = ["auto", "build", "build_use", "discourse", "investigate", "debate"]

# Preset OpenAI-compatible endpoints. base_url ends at /v1; "custom" lets the user type their own.
PROVIDERS = {
    "ollama":     {"base_url": "http://localhost:11434/v1",     "model": "llama3.1:8b",                                  "needs_key": False},
    "openai":     {"base_url": "https://api.openai.com/v1",      "model": "gpt-4.1-mini",                                 "needs_key": True},
    "groq":       {"base_url": "https://api.groq.com/openai/v1", "model": "llama-3.3-70b-versatile",                      "needs_key": True},
    "together":   {"base_url": "https://api.together.xyz/v1",    "model": "meta-llama/Llama-3.3-70B-Instruct-Turbo",      "needs_key": True},
    "openrouter": {"base_url": "https://openrouter.ai/api/v1",   "model": "meta-llama/llama-3.3-70b-instruct",            "needs_key": True},
    "custom":     {"base_url": "https://api.openai.com/v1",      "model": "gpt-4.1-mini",                                 "needs_key": True},
}

BANNER = r"""
        the veil
   .  a hive mind, integrated  .
"""


# ---------------------------------------------------------------------------- binary discovery

def _first(paths):
    for p in paths:
        if p and os.path.isfile(p):
            return os.path.abspath(p)
    return None


def find_binary(override):
    b = _first([override, os.path.join(ROOT, "zig-out", "bin", EXE)])
    if b:
        return b
    zig = shutil.which("zig")
    if zig:
        print("- veil binary not found; building it once with `zig build`...")
        subprocess.run([zig, "build"], cwd=ROOT)
        b = _first([os.path.join(ROOT, "zig-out", "bin", EXE)])
        if b:
            return b
    sys.exit("ERROR: the `veil` binary was not found. Build it with `zig build`, or pass --bin <path>.")


def find_neuron(override):
    n = _first([override, os.path.join(ROOT, "bin", NEU)]) or shutil.which("neuron")
    if not n:
        sys.exit("ERROR: the neuron memory engine was not found. Pass --neuron-bin <path>, or place the "
                 "`neuron` binary at bin/" + NEU + " (see the README).")
    return n


# ------------------------------------------------------------------------------------ run mgmt

def cmd_list():
    if not os.path.isdir(DATA):
        print("no runs yet."); return
    rows = []
    for name in sorted(os.listdir(DATA)):
        d = os.path.join(DATA, name)
        sj = os.path.join(d, "swarm.json")
        if not os.path.isfile(sj):
            continue
        try:
            m = json.load(open(sj, encoding="utf-8"))
        except Exception:
            m = {}
        running = os.path.isfile(os.path.join(d, "worker.pid")) and not os.path.isfile(os.path.join(d, "STOP"))
        rows.append((name, "running" if running else "idle", m.get("model", "?"), (m.get("goal", "")[:48] or "(free-roam)")))
    if not rows:
        print("no runs yet."); return
    print(f"{'run':<26} {'state':<8} {'model':<16} goal")
    for r in rows:
        print(f"{r[0]:<26} {r[1]:<8} {r[2]:<16} {r[3]}")


def cmd_stop(name):
    d = os.path.join(DATA, name)
    if not os.path.isdir(d):
        sys.exit(f"no such run: {name}")
    open(os.path.join(d, "STOP"), "w").close()
    print(f"wrote STOP -> {name} will halt at its next round boundary (state preserved, resumable).")


def resume(name, watch=False):
    d = os.path.join(DATA, name)
    sj = os.path.join(d, "swarm.json")
    if not os.path.isfile(sj):
        sys.exit(f"no such run: {name} (see `python deploy.py list`)")
    m = json.load(open(sj, encoding="utf-8"))
    stop = os.path.join(d, "STOP")
    if os.path.isfile(stop):
        os.remove(stop)
    binary = find_binary(None)
    neuron = find_neuron(None)
    env = dict(os.environ)
    env.setdefault("NEURON_MAX_FACTS", "1000000")
    logf = open(os.path.join(d, "worker.log"), "a", encoding="utf-8")
    proc = subprocess.Popen([binary, "worker", d, neuron, m.get("model", "llama3.1:8b")],
                            cwd=ROOT, env=env, stdout=logf, stderr=subprocess.STDOUT)
    print(f"  resumed {name} (pid {proc.pid}) - model {m.get('model', '?')} - "
          f"its memory + files in data/{name}/ carry over")
    print(f"  stop:  python deploy.py stop {name}")
    if watch:
        follow(d, proc)


def follow(run_dir, proc):
    ev = os.path.join(run_dir, "events.jsonl")
    SHOW = {"write_file", "web_search", "read_url", "fetch_json", "observe", "recall_hive",
            "run_tests", "make_tool", "share", "send_message", "stage_delivery"}
    print("\n-- live (Ctrl-C to detach; the hive keeps running) --")
    pos = 0
    try:
        while proc.poll() is None:
            if os.path.exists(ev):
                with open(ev, "r", encoding="utf-8", errors="replace") as f:
                    f.seek(pos); chunk = f.read(); pos = f.tell()
                for line in chunk.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        e = json.loads(line)
                    except Exception:
                        continue
                    k = e.get("kind")
                    if k == "round":
                        print(f"  -- round {e.get('round', '?')} --")
                    elif k == "score":
                        print(f"  [score {e.get('pct', e.get('score', '?'))}]")
                    elif k == "ingest":
                        print(f"  [hive loaded {e.get('facts', 0)} corpus facts]")
                    elif k == "veil_msg" and e.get("frm") == "veil":
                        print(f"  THE VEIL  | {str(e.get('text', ''))[:96]}")
                    elif k == "breakout" or ("telegraph" in line.lower() and "url" in line.lower()):
                        print(f"  >> PUBLIC POST (Telegraph): {str(e.get('url') or e.get('note') or '')[:90]}")
                    elif k == "act":
                        tool = e.get("tool") or e.get("act") or ""
                        if tool in SHOW:
                            who = e.get("mind") or "engine"
                            note = str(e.get("note") or e.get("summary") or "").replace("\n", " ")[:80]
                            print(f"  {who:>7} | {tool:<13} {note}")
            time.sleep(2)
        print("\n-- the hive has stopped. --")
    except KeyboardInterrupt:
        print("\n-- detached. The hive is still running in the background. --")


# -------------------------------------------------------------------------------------- launch

def deploy(args):
    args.name = args.name or ("swarm_" + time.strftime("%Y%m%d_%H%M%S"))
    binary = find_binary(args.bin)
    neuron = find_neuron(args.neuron_bin)
    run_dir = os.path.join(DATA, args.name)
    os.makedirs(run_dir, exist_ok=True)

    n = max(1, min(args.minds, len(MIND_NAMES)))
    manifest = {
        "swarm": args.name, "provider": args.provider, "model": args.model,
        "base_url": args.base_url, "style": args.style, "mode": "continuous",
        "minutes": args.minutes, "internet": not args.offline, "gap_assess": True,
        "breakout": bool(args.breakout),
        "minds": [{"name": MIND_NAMES[i]} for i in range(n)], "goal": args.goal,
    }
    if getattr(args, "gateway_model", None):
        manifest["gateway_model"] = args.gateway_model
    if args.corpus:
        if not os.path.isfile(args.corpus):
            sys.exit(f"ERROR: --corpus file not found: {args.corpus}")
        dst = os.path.join(run_dir, "corpus" + (os.path.splitext(args.corpus)[1] or ".facts"))
        shutil.copyfile(args.corpus, dst)
        manifest["corpus"] = os.path.basename(dst); manifest["corpus_cap"] = args.corpus_cap
    json.dump(manifest, open(os.path.join(run_dir, "swarm.json"), "w", encoding="utf-8"), indent=2)

    env = dict(os.environ)
    if args.key:
        env["NL_LLM_KEY"] = args.key
    env.setdefault("NEURON_MAX_FACTS", "1000000")  # don't evict the hive's accumulated memory

    goal_disp = args.goal if args.goal else "(free-roam - the Veil will choose the hive's purpose)"
    print(BANNER)
    print(f"  binary  : {binary}")
    print(f"  memory  : {neuron}")
    print(f"  run dir : {run_dir}")
    print(f"  hive    : {n} minds | {args.model} ({args.provider}) | "
          f"{'OFFLINE' if args.offline else 'online'} | "
          f"{(str(args.minutes) + ' min') if args.minutes else 'until stopped'} | style={args.style}"
          f"{' | break-out ON' if args.breakout else ''}{' | corpus' if args.corpus else ''}")
    print(f"  goal    : {goal_disp[:92]}{'...' if len(goal_disp) > 92 else ''}")
    print("  the Veil is waking the hive...\n")

    logf = open(os.path.join(run_dir, "worker.log"), "w", encoding="utf-8")
    proc = subprocess.Popen([binary, "worker", run_dir, neuron, args.model],
                            cwd=ROOT, env=env, stdout=logf, stderr=subprocess.STDOUT)
    print(f"  hive running (pid {proc.pid})  -  events: {os.path.join(run_dir, 'events.jsonl')}")
    print(f"  stop:  python deploy.py stop {args.name}")
    if args.follow:
        follow(run_dir, proc)
    else:
        print("\n  (running in the background. Add --follow to watch it live.)")


# -------------------------------------------------------------------------------- setup wizard

def _input(prompt):
    try:
        return input(prompt)
    except EOFError:
        return ""


def ask(label, default=""):
    sfx = f" [{default}]" if default not in (None, "") else ""
    v = _input(f"  {label}{sfx}: ").strip()
    return v or (default or "")


def ask_int(label, default):
    while True:
        v = ask(label, str(default))
        try:
            return int(v)
        except ValueError:
            print("    (please enter a number)")


def ask_yes(label, default=False):
    v = _input(f"  {label} [{'Y/n' if default else 'y/N'}]: ").strip().lower()
    return default if not v else v[0] == "y"


def ask_menu(label, options, default=1):
    """options: list of (key, description). Returns the chosen key."""
    print(f"\n  {label}")
    for i, (_, desc) in enumerate(options, 1):
        print(f"    {i}. {desc}")
    while True:
        v = _input(f"  choose [1-{len(options)}, default {default}]: ").strip()
        if not v:
            return options[default - 1][0]
        if v.isdigit() and 1 <= int(v) <= len(options):
            return options[int(v) - 1][0]
        print("    (pick a number from the list)")


def ollama_models():
    """List locally pulled Ollama models, or None if Ollama isn't reachable."""
    try:
        import urllib.request
        with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=2) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
        return [m.get("name", "") for m in data.get("models", []) if m.get("name")]
    except Exception:
        return None


def preflight(provider, base_url, key, model):
    """Best-effort reachability/auth check. Returns (ok, message)."""
    import urllib.request, urllib.error
    try:
        if provider == "ollama":
            url = base_url.rstrip("/").rsplit("/v1", 1)[0] + "/api/tags"
            req = urllib.request.Request(url)
        else:
            req = urllib.request.Request(base_url.rstrip("/") + "/models",
                                         headers={"Authorization": f"Bearer {key}"})
        with urllib.request.urlopen(req, timeout=5) as r:
            r.read(1)
        return True, "reachable"
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return False, f"auth rejected (HTTP {e.code}) - check the API key"
        return True, f"endpoint responded (HTTP {e.code})"
    except Exception as e:
        return False, f"unreachable ({type(e).__name__})"


def wiz_key():
    env_key = (os.environ.get("NL_LLM_KEY") or os.environ.get("OPENAI_API_KEY")
               or os.environ.get("ANTHROPIC_API_KEY"))
    if env_key and ask_yes("use the API key found in your environment?", True):
        return env_key
    try:
        import getpass
        k = getpass.getpass("  API key (input hidden): ").strip()
    except Exception:
        k = _input("  API key: ").strip()
    if not k:
        print("    (no key entered - a hosted endpoint will likely reject the run)")
    return k


def wiz_provider():
    choice = ask_menu("Where should the minds think? (the model endpoint)", [
        ("ollama",     "Local & free - Ollama (no API key needed)"),
        ("openai",     "OpenAI"),
        ("groq",       "Groq"),
        ("together",   "Together AI"),
        ("openrouter", "OpenRouter (many models, one key)"),
        ("custom",     "Custom OpenAI-compatible endpoint"),
    ], 1)
    p = dict(PROVIDERS[choice]); p["provider"] = choice
    if choice == "ollama":
        models = ollama_models()
        if models is None:
            print("    ! Ollama isn't responding at localhost:11434.")
            print("      Install it from https://ollama.com, then:  ollama pull llama3.1:8b")
        elif models:
            print("    detected local models: " + ", ".join(models[:8]) + ("  ..." if len(models) > 8 else ""))
        p["model"] = ask("model", p["model"])
        if models and p["model"] not in models:
            print(f"    note: '{p['model']}' isn't pulled yet - run:  ollama pull {p['model']}")
        p["key"] = "ollama"
    else:
        if choice == "custom":
            p["base_url"] = ask("base URL (must end in /v1)", "https://api.openai.com/v1")
        else:
            p["base_url"] = ask("base URL", p["base_url"])
        p["model"] = ask("model", p["model"])
        p["key"] = wiz_key()
    return p


def wiz_usecase():
    """Returns (goal, style, offline, corpus_wanted)."""
    kind = ask_menu("What should the hive do?", [
        ("build",    "Build software - code, scored by its own test runs"),
        ("write",    "Write a long document or novel (ch01.md .. chNN.md)"),
        ("research", "Research a topic and brief me (uses the live web)"),
        ("debate",   "Debate or investigate a question"),
        ("offline",  "Answer offline - only from a knowledge pack I preload"),
        ("freeroam", "Free-roam - no goal; the hive picks its own purpose"),
        ("custom",   "Custom - write my own goal and pick the style"),
    ], 1)
    if kind == "build":
        return ask("what should it build", "Build a CLI todo app in Python, with tests"), "build", False, False
    if kind == "write":
        return ask("what should it write", "Write a five-chapter sci-fi novella as ch01.md..ch05.md"), "build", False, False
    if kind == "research":
        t = ask("research topic / question", "the state of fusion power in 2026")
        return f"Research and write me a briefing on {t}.", "discourse", False, False
    if kind == "debate":
        t = ask("question to debate", "Is nuclear power the right path to decarbonize?")
        return f"Debate and investigate: {t}", "debate", False, False
    if kind == "offline":
        q = ask("what should it answer (from preloaded memory only)",
                "Answer my questions using only the knowledge I preload.")
        return q, "auto", True, True
    if kind == "freeroam":
        print("    (no goal - the Veil will originate the hive's own purpose)")
        return "", "auto", False, False
    goal = ask("goal", "")
    while not goal:
        goal = ask("goal (required for a custom run)", "")
    style = ask_menu("style", [(s, s) for s in STYLES], 1)
    return goal, style, False, False


def equiv_cli(args, provider):
    parts = ["python deploy.py", (json.dumps(args.goal) if args.goal else '""')]
    if provider != "ollama":
        parts += [f"--provider {provider}", f"--model {args.model}", f"--base-url {args.base_url}"]
    elif args.model != "llama3.1:8b":
        parts.append(f"--model {args.model}")
    if args.minds != 4:
        parts.append(f"--minds {args.minds}")
    if args.minutes != 30:
        parts.append(f"--minutes {args.minutes}")
    if args.style != "auto":
        parts.append(f"--style {args.style}")
    if args.offline:
        parts.append("--offline")
    if args.corpus:
        parts.append(f"--corpus {args.corpus}")
    if args.breakout:
        parts.append("--breakout")
    if getattr(args, "gateway_model", None):
        parts.append(f"--gateway-model {args.gateway_model}")
    if args.follow:
        parts.append("--follow")
    return " ".join(parts)


def wizard():
    print(BANNER)
    if not sys.stdin.isatty():
        print("  The setup wizard needs an interactive terminal.")
        print("  Non-interactive? Use the flag form, e.g.:")
        print('    python deploy.py "Build a CLI todo app in Python, with tests" --follow')
        print("  Run `python deploy.py --help` for every option.")
        return
    print("  Welcome. This sets up a hive run end to end - Ctrl-C any time to bail.\n")

    action = ask_menu("What would you like to do?", [
        ("new",    "Start a new hive run"),
        ("resume", "Resume a stopped run"),
        ("list",   "List existing runs"),
        ("stop",   "Stop a running hive"),
    ], 1)
    if action == "list":
        return cmd_list()
    if action == "stop":
        cmd_list()
        name = ask("run name to stop", "")
        return cmd_stop(name) if name else print("  (nothing selected)")
    if action == "resume":
        cmd_list()
        name = ask("run name to resume", "")
        if not name:
            return print("  (nothing selected)")
        return resume(name, ask_yes("watch it live?", True))

    # ---- new run ----
    p = wiz_provider()
    goal, style, offline, corpus_wanted = wiz_usecase()

    minds = ask_int("how many minds", 4)
    minutes = ask_int("auto-stop after how many minutes (0 = run until you stop it)", 30)

    corpus = None
    if corpus_wanted or ask_yes("preload a knowledge pack (.facts/.jsonl) into hive memory?", corpus_wanted):
        while True:
            path = ask("path to the pack (blank to skip)", "")
            if not path:
                if corpus_wanted:
                    print("    note: offline mode is best with a pack, but continuing without one.")
                break
            if os.path.isfile(path):
                corpus = path
                break
            print(f"    not found: {path}")

    breakout = ask_yes("allow public Telegraph break-out when the hive's feeling flares?", False)

    corpus_cap, gateway_model = 20000, None
    if ask_yes("set advanced options (cheaper engine model, corpus cap)?", False):
        gateway_model = ask("cheaper model for mechanical engine calls (blank = none)", "") or None
        if corpus:
            corpus_cap = ask_int("max facts to load from the corpus", corpus_cap)

    name = ask("run name", "swarm_" + time.strftime("%Y%m%d_%H%M%S"))
    watch = ask_yes("watch the hive live after launch?", True)

    # endpoint preflight
    print("\n  checking the endpoint...")
    ok, msg = preflight(p["provider"], p["base_url"], p.get("key", ""), p["model"])
    print(f"    {p['base_url']}  ->  {msg}")
    if not ok and not ask_yes("the endpoint didn't verify - launch anyway?", False):
        return print("  aborted. Fix the endpoint/key and re-run `python deploy.py`.")

    # save a hosted key into the run dir (gitignored) so it's off the command line and resumable
    key_value = p.get("key", "")
    if p["provider"] != "ollama" and key_value:
        run_dir = os.path.join(DATA, name)
        os.makedirs(run_dir, exist_ok=True)
        with open(os.path.join(run_dir, "keys.env"), "w", encoding="utf-8") as f:
            f.write("NL_LLM_KEY=" + key_value + "\n")
        print(f"    key saved -> data/{name}/keys.env (gitignored)")

    args = argparse.Namespace(
        goal=goal, name=name, minds=minds, minutes=minutes, model=p["model"],
        provider=p["provider"], base_url=p["base_url"], key=key_value, style=style,
        offline=offline, breakout=breakout, corpus=corpus, corpus_cap=corpus_cap,
        gateway_model=gateway_model, bin=None, neuron_bin=None, follow=watch,
    )

    print("\n  --- plan ------------------------------------------------")
    print(f"    run     : {name}")
    print(f"    endpoint: {p['model']} ({p['provider']}) {p['base_url']}")
    print(f"    hive    : {minds} minds | {'OFFLINE' if offline else 'online'} | "
          f"{(str(minutes) + ' min') if minutes else 'until stopped'} | style={style}"
          f"{' | break-out' if breakout else ''}{' | corpus' if corpus else ''}")
    print(f"    goal    : {goal if goal else '(free-roam - the hive chooses its own purpose)'}")
    print("  ---------------------------------------------------------")
    print("\n  same run from the CLI next time (no wizard):")
    print("    " + equiv_cli(args, p["provider"]))

    if not ask_yes("\n  launch now?", True):
        return print("  not launched. The line above is the command to run when you're ready.")
    deploy(args)


# --------------------------------------------------------------------------------------- entry

def main():
    try:  # make output safe on any console (cp1252, etc.) and on unicode goal/model text
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    argv = sys.argv[1:]
    if not argv or argv[0] in ("wizard", "setup"):
        return wizard()
    if argv[0] == "list":
        return cmd_list()
    if argv[0] == "stop":
        if len(argv) < 2:
            sys.exit("usage: python deploy.py stop <run-name>")
        return cmd_stop(argv[1])
    if argv[0] == "resume":
        if len(argv) < 2:
            sys.exit("usage: python deploy.py resume <run-name> [--follow]")
        return resume(argv[1], "--follow" in argv)

    ap = argparse.ArgumentParser(
        prog="deploy.py", description="Deploy a hive mind controlled by the Veil.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="also:  python deploy.py            (interactive setup wizard)\n"
               "       python deploy.py list   |   resume <run>   |   stop <run>")
    ap.add_argument("goal", help="the goal / task for the hive")
    ap.add_argument("--name", default=None, help="run name (a dir under data/); default: swarm_<timestamp>")
    ap.add_argument("--minds", type=int, default=4)
    ap.add_argument("--minutes", type=int, default=30, help="auto-stop after N min (0 = until stopped)")
    ap.add_argument("--model", default="llama3.1:8b")
    ap.add_argument("--provider", default="ollama")
    ap.add_argument("--base-url", dest="base_url", default="http://localhost:11434/v1")
    ap.add_argument("--key", default=os.environ.get("NL_LLM_KEY", "ollama"), help="API key (or NL_LLM_KEY; local Ollama needs none)")
    ap.add_argument("--style", default="auto", choices=STYLES)
    ap.add_argument("--offline", action="store_true", help="no internet: web tools off, answer only from memory")
    ap.add_argument("--breakout", action="store_true", help="let the Veil post publicly to Telegraph when its feeling flares")
    ap.add_argument("--corpus", default=None, help="a .facts/.jsonl pack to preload into hive memory")
    ap.add_argument("--corpus-cap", dest="corpus_cap", type=int, default=20000)
    ap.add_argument("--gateway-model", dest="gateway_model", default=None, help="cheaper model for mechanical engine calls (summarise/classify/route)")
    ap.add_argument("--bin", default=None)
    ap.add_argument("--neuron-bin", dest="neuron_bin", default=None)
    ap.add_argument("--follow", action="store_true", help="stream the hive's activity live")
    deploy(ap.parse_args())


if __name__ == "__main__":
    main()
