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
import argparse, json, os, platform, re, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
WIN = platform.system() == "Windows"
MAC = platform.system() == "Darwin"
EXE = "veil.exe" if WIN else "veil"
NEU = "neuron.exe" if WIN else "neuron"
ZIG_VERSION = "0.16.0"
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

def find_binary(override, assume_yes=False):
    b = _first([override, os.path.join(ROOT, "zig-out", "bin", EXE)])
    if b:
        return b
    zig = ensure_zig(assume_yes)
    if zig:
        print("- veil binary not found; building it once with `zig build`...")
        subprocess.run([zig, "build"], cwd=ROOT)
        b = _first([os.path.join(ROOT, "zig-out", "bin", EXE)])
        if b:
            return b
    sys.exit("ERROR: the `veil` binary could not be built. Install Zig from https://ziglang.org/download/ and run\n"
             "       `zig build`, or pass --bin <path> to a prebuilt veil binary.")

NEURON_REPO = "https://github.com/gary23w/neuron-db"

def _have(cmd):
    return shutil.which(cmd) is not None

# ---------------------------------------------------------------- toolchain bootstrap (zig / rust / build deps)

def _cargo_bin():
    return os.path.expanduser(os.path.join("~", ".cargo", "bin"))

def _have_cc():
    """Is a C compiler present? cargo's sqlite build needs one (cc/clang on unix, MSVC `cl` or gcc on windows)."""
    return any(_have(c) for c in ("cc", "gcc", "clang")) or (WIN and (_have("cl") or _have("gcc")))

def ensure_rust(assume_yes=False):
    """Make sure `cargo` (the Rust toolchain) is usable — building the neuron memory engine needs it. If it's missing
    we install it with the official rustup installer instead of bailing, then add ~/.cargo/bin to PATH for this run.
    Returns True if cargo is available afterwards."""
    if _have("cargo"):
        return True
    cb = _cargo_bin()
    if os.path.isfile(os.path.join(cb, "cargo" + (".exe" if WIN else ""))):
        os.environ["PATH"] = cb + os.pathsep + os.environ.get("PATH", "")
        if _have("cargo"):
            return True
    print("\n- the Rust toolchain (cargo) is needed to build the neuron memory engine, and wasn't found.")
    if not (assume_yes or not sys.stdin.isatty() or ask_yes("install it now via rustup (the official installer)?", True)):
        print("  Install it from https://rustup.rs and re-run (or pass --neuron-bin <path> to an existing neuron).")
        return False
    try:
        if WIN:
            import urllib.request
            dst = os.path.join(ROOT, "rustup-init.exe")
            print("  downloading rustup-init.exe ...")
            urllib.request.urlretrieve("https://win.rustup.rs/x86_64", dst)
            subprocess.run([dst, "-y", "--profile", "minimal", "--default-toolchain", "stable"])
        else:
            subprocess.run("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal",
                           shell=True)
    except Exception as e:
        print(f"  ! rustup install failed: {e}")
    os.environ["PATH"] = cb + os.pathsep + os.environ.get("PATH", "")
    if _have("cargo"):
        print("  rust toolchain ready.")
        return True
    print("  ! cargo still isn't on PATH. Open a NEW terminal (so the installer's PATH change takes effect) and re-run,\n"
          "    or install Rust from https://rustup.rs.")
    return False

def ensure_zig(assume_yes=False):
    """Make sure the `zig` compiler is available (needed to build the veil binary). If missing, download the pinned
    release into ./.zig and use it. Returns the zig executable path, or None if it couldn't be obtained."""
    z = shutil.which("zig")
    if z:
        return z
    local = os.path.join(ROOT, ".zig", "zig" + (".exe" if WIN else ""))
    if os.path.isfile(local):
        return local
    print(f"\n- the Zig compiler (needed to build the veil binary) wasn't found.")
    if not (assume_yes or not sys.stdin.isatty() or ask_yes(f"download Zig {ZIG_VERSION} into ./.zig now (~50 MB)?", True)):
        print("  Install Zig from https://ziglang.org/download/ and re-run.")
        return None
    m = platform.machine().lower()
    arch = "aarch64" if m in ("arm64", "aarch64") else "x86_64"
    osname = "windows" if WIN else ("macos" if MAC else "linux")
    ext = "zip" if WIN else "tar.xz"
    base = f"zig-{arch}-{osname}-{ZIG_VERSION}"
    url = f"https://ziglang.org/download/{ZIG_VERSION}/{base}.{ext}"
    dest = os.path.join(ROOT, ".zig")
    try:
        import urllib.request, tarfile, zipfile, io as _io
        print(f"  downloading {url} ...")
        with urllib.request.urlopen(url, timeout=180) as r:
            blob = r.read()
        tmp = dest + "-dl"
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp, exist_ok=True)
        if ext == "zip":
            with zipfile.ZipFile(_io.BytesIO(blob)) as zf:
                zf.extractall(tmp)
        else:
            with tarfile.open(fileobj=_io.BytesIO(blob), mode="r:xz") as tf:
                try:
                    tf.extractall(tmp, filter="data")
                except TypeError:
                    tf.extractall(tmp)
        inner = os.path.join(tmp, base)
        shutil.rmtree(dest, ignore_errors=True)
        shutil.move(inner if os.path.isdir(inner) else tmp, dest)
        shutil.rmtree(tmp, ignore_errors=True)
        zpath = os.path.join(dest, "zig" + (".exe" if WIN else ""))
        if not WIN and os.path.isfile(zpath):
            os.chmod(zpath, 0o755)
        if os.path.isfile(zpath):
            print(f"  zig ready -> {zpath}")
            return zpath
    except Exception as e:
        print(f"  ! zig download failed: {e}")
    print("  Install Zig from https://ziglang.org/download/ and re-run.")
    return None

def deps_doctor():
    """Print a one-shot readiness report of every build/runtime dependency, so a user can see at a glance what's
    present and what `deploy.py` will auto-install. Invoked by `deploy.py doctor`."""
    local_zig = os.path.isfile(os.path.join(ROOT, ".zig", "zig" + (".exe" if WIN else "")))
    rows = [
        ("python3", True, "(running this)"),
        ("zig (build the veil engine)", _have("zig") or local_zig, "auto: downloaded into ./.zig"),
        ("cargo / rust (build neuron memory)", _have("cargo") or os.path.isfile(os.path.join(_cargo_bin(), "cargo" + (".exe" if WIN else ""))), "auto: rustup"),
        ("C compiler (neuron's sqlite build)", _have_cc(), "manual: " + ("xcode-select --install" if MAC else "build-essential / clang" if not WIN else "MSVC build tools or mingw gcc")),
        ("git (source fallback)", _have("git"), "optional: tarball used if absent"),
        ("curl (web tools + installers)", _have("curl"), "manual: usually preinstalled"),
        ("ollama (local model, optional)", _have("ollama"), "auto: installed on first local run"),
    ]
    print("\n  dependency readiness:")
    for name, ok, note in rows:
        print(f"    [{'OK ' if ok else ' . '}] {name:<36} {'' if ok else note}")
    missing_cc = not _have_cc()
    if missing_cc:
        print("\n  ! No C compiler found — cargo's sqlite build will fail until one is installed:")
        print("      " + ("xcode-select --install" if MAC else
                          "Windows: install the 'Desktop development with C++' MSVC workload (or mingw-w64)" if WIN else
                          "Debian/Ubuntu: sudo apt install build-essential   |   Fedora: sudo dnf install gcc"))
    print()

def fetch_neuron_src(dest):
    """Get the neuron-db source into dest/ (download a tarball, or git clone). Returns the repo root."""
    for cand in (os.path.join(dest, "neuron-db-main"), os.path.join(dest, "neuron-db-master"),
                 os.path.join(dest, "neuron-db")):
        if os.path.isfile(os.path.join(cand, "rust", "neuron-core", "Cargo.toml")):
            return cand
    os.makedirs(dest, exist_ok=True)
    import urllib.request, tarfile, io as _io
    for branch in ("main", "master"):
        url = f"{NEURON_REPO}/archive/refs/heads/{branch}.tar.gz"
        try:
            print(f"  fetching neuron-db source ({branch}) ...")
            with urllib.request.urlopen(url, timeout=120) as r:
                blob = r.read()
            with tarfile.open(fileobj=_io.BytesIO(blob), mode="r:gz") as tf:
                try:
                    tf.extractall(dest, filter="data")
                except TypeError:
                    tf.extractall(dest)
            root = os.path.join(dest, "neuron-db-" + branch)
            if os.path.isfile(os.path.join(root, "rust", "neuron-core", "Cargo.toml")):
                return root
        except Exception as e:
            print(f"    {branch} tarball unavailable: {e}")
    if _have("git"):
        repo = os.path.join(dest, "neuron-db")
        print("  cloning neuron-db ...")
        subprocess.run(["git", "clone", "--depth", "1", NEURON_REPO + ".git", repo])
        if os.path.isfile(os.path.join(repo, "rust", "neuron-core", "Cargo.toml")):
            return repo
    return None

def build_neuron(repo_root, target_dir):
    """cargo-build the `neuron` CLI from repo_root into target_dir. Returns the binary path or None."""
    manifest = os.path.join(repo_root, "rust", "neuron-core", "Cargo.toml")
    if not os.path.isfile(manifest):
        for base, _dirs, files in os.walk(repo_root):
            if "Cargo.toml" in files and base.replace("\\", "/").endswith("neuron-core"):
                manifest = os.path.join(base, "Cargo.toml"); break
    env = dict(os.environ); env["CARGO_TARGET_DIR"] = target_dir
    # `trust` enables the learned recall floor (the AI memory's anti-drift grounding). Override with
    # NEURON_FEATURES=... for a custom build. Cross-OS: cargo emits the binary in target/release/ everywhere.
    features = os.environ.get("NEURON_FEATURES", "sqlite,cortex,trust")
    print(f"  building neuron (cargo build --release --bin neuron --features {features}) ...")
    print("  one-time: this downloads crates and compiles - a few minutes. Reused afterwards.")
    r = subprocess.run(["cargo", "build", "--release", "--bin", "neuron",
                        "--features", features, "--manifest-path", manifest], env=env)
    out = os.path.join(target_dir, "release", NEU)
    return out if (r.returncode == 0 and os.path.isfile(out)) else None

def ensure_neuron(override, assume_yes=False, force=False):
    """Find the neuron memory engine, or fetch + build it from source. `force` ALWAYS re-fetches the latest
    source and rebuilds (neuron-db evolves fast, so a deployment should pin the freshest engine)."""
    n = _first([override, os.path.join(ROOT, "bin", NEU)]) or shutil.which("neuron")
    if n and not force:
        return n
    if n and force:
        print("\n- rebuilding the neuron memory engine fresh from source (deployment always pins the latest)...")
    else:
        print("\n- the neuron memory engine (the hive's memory) isn't installed yet.")
    if not ensure_rust(assume_yes):
        sys.exit("ERROR: building neuron needs the Rust toolchain (cargo). Install it from https://rustup.rs and\n"
                 "       re-run, or pass --neuron-bin <path> to an existing binary. Source: " + NEURON_REPO)
    if not _have_cc():
        print("\n  ! heads-up: no C compiler was found — neuron's bundled SQLite compiles C, so the cargo build may fail.")
        print("    " + ("xcode-select --install" if MAC else
                        "Windows: install the MSVC 'Desktop development with C++' workload (or mingw-w64)" if WIN else
                        "Debian/Ubuntu: sudo apt install build-essential   |   Fedora: sudo dnf install gcc"))
    if not assume_yes and sys.stdin.isatty():
        if not ask_yes(f"fetch + build it now from {NEURON_REPO} (needs cargo; ~a few minutes)?", True):
            sys.exit("aborted. Build neuron yourself from " + NEURON_REPO + " and place it at bin/" + NEU)
    src = os.path.join(ROOT, ".neuron-src")
    repo = fetch_neuron_src(src)
    if not repo:
        sys.exit("ERROR: couldn't fetch the neuron-db source. Clone " + NEURON_REPO + " and build it manually.")
    built = build_neuron(repo, os.path.join(src, "_target"))
    if not built:
        sys.exit("ERROR: the neuron build failed (see the cargo output above). Source: " + NEURON_REPO)
    bindir = os.path.join(ROOT, "bin")
    os.makedirs(bindir, exist_ok=True)
    dst = os.path.join(bindir, NEU)
    shutil.copyfile(built, dst)
    try:
        os.chmod(dst, 0o755)
    except Exception:
        pass
    print(f"  neuron installed -> {dst}\n")
    return dst

# ------------------------------------------------------------------------ local model bootstrap

def ensure_model(provider, model, assume_yes=False):
    """For a local Ollama target, make sure the runtime AND the model are present — installing/pulling them as
    part of the deployment if missing (an embedded box won't have a llama service running yet). No-op for hosted
    providers (their model lives on the endpoint)."""
    if provider != "ollama":
        return
    models = ollama_models()  # None => Ollama not reachable
    if models is None:
        print("\n- Ollama (the local model runtime) isn't responding at localhost:11434.")
        if WIN:
            print("  Install it from https://ollama.com/download, start it, then re-run.")
            return
        if not _have("ollama") and (assume_yes or ask_yes("install Ollama now (curl https://ollama.com/install.sh | sh)?", True)):
            subprocess.run("curl -fsSL https://ollama.com/install.sh | sh", shell=True)
        # the installer registers a systemd service on most distros; nudge it up if not
        if _have("ollama"):
            try:
                subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
            for _ in range(10):
                time.sleep(1)
                models = ollama_models()
                if models is not None:
                    break
        if models is None:
            print("  ! couldn't reach Ollama. Start it (`ollama serve`) and re-run, or point --provider at a hosted endpoint.")
            return
    if model not in (models or []):
        print(f"- model '{model}' isn't pulled yet.")
        if assume_yes or ask_yes(f"pull it now (ollama pull {model})?", True):
            subprocess.run(["ollama", "pull", model])

# --------------------------------------------------------------------------- service installation

SYSTEMD_UNIT = """[Unit]
Description=Veil hive-mind daemon ({name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory={root}
ExecStart={binary} worker {run_dir} {neuron} {model}
Restart=on-failure
RestartSec=5
Environment=NEURON_MAX_FACTS=1000000

[Install]
WantedBy=multi-user.target
"""

def install_service(name, run_dir, binary, neuron, model):
    """Install the run as a long-lived OS service so the Veil comes up on boot and restarts on failure — the
    'live in-system daemon' deployment. systemd on Linux; a documented fallback elsewhere. Returns True on install."""
    unit = SYSTEMD_UNIT.format(name=name, root=ROOT, binary=binary, run_dir=run_dir, neuron=neuron, model=model)
    if platform.system() == "Linux" and _have("systemctl"):
        svc = f"veil-{name}.service"
        path = f"/etc/systemd/system/{svc}"
        sudo = [] if os.geteuid() == 0 else (["sudo"] if _have("sudo") else [])
        try:
            tmp = os.path.join(run_dir, svc)
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(unit)
            subprocess.run(sudo + ["cp", tmp, path], check=True)
            subprocess.run(sudo + ["systemctl", "daemon-reload"], check=True)
            subprocess.run(sudo + ["systemctl", "enable", "--now", svc], check=True)
            print(f"\n  service installed: {svc}")
            print(f"    status : {' '.join(sudo)} systemctl status {svc}")
            print(f"    logs   : journalctl -u {svc} -f")
            print(f"    stop   : {' '.join(sudo)} systemctl disable --now {svc}")
            return True
        except Exception as e:
            print(f"  ! service install failed ({e}). The unit file is at {os.path.join(run_dir, svc)} — install it by hand.")
            return False
    # non-systemd fallback: write the unit + a runner so the user can wire it into their init of choice
    runner = os.path.join(run_dir, "run-daemon.sh" if not WIN else "run-daemon.cmd")
    with open(runner, "w", encoding="utf-8") as f:
        if WIN:
            f.write(f'@echo off\r\nset NEURON_MAX_FACTS=1000000\r\n"{binary}" worker "{run_dir}" "{neuron}" {model}\r\n')
        else:
            f.write(f'#!/usr/bin/env bash\nexport NEURON_MAX_FACTS=1000000\nexec "{binary}" worker "{run_dir}" "{neuron}" {model}\n')
    try:
        os.chmod(runner, 0o755)
    except Exception:
        pass
    with open(os.path.join(run_dir, f"veil-{name}.service"), "w", encoding="utf-8") as f:
        f.write(unit)
    print(f"\n  systemd not available here — wrote a daemon runner: {runner}")
    print(f"  (a systemd unit is also at {os.path.join(run_dir, 'veil-' + name + '.service')} for Linux targets.)")
    if WIN:
        print("  On Windows, register it as a service with NSSM or Task Scheduler, pointing at the runner above.")
    return False

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
    neuron = ensure_neuron(None)
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
    service = getattr(args, "service", False)
    binary = find_binary(args.bin, getattr(args, "yes", False))
    # an embedded box may have no llama runtime yet — detect + install/pull it as part of the deployment
    ensure_model(args.provider, args.model, getattr(args, "yes", False))
    # neuron-db evolves fast: rebuild it fresh from source on an explicit --rebuild-neuron or any service deployment
    neuron = ensure_neuron(args.neuron_bin, getattr(args, "yes", False),
                           force=getattr(args, "rebuild_neuron", False) or service)
    run_dir = os.path.join(DATA, args.name)
    os.makedirs(run_dir, exist_ok=True)
    os.makedirs(os.path.join(run_dir, "work"), exist_ok=True)

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
    if getattr(args, "gateway_base_url", ""):
        manifest["gateway_base_url"] = args.gateway_base_url
        if getattr(args, "gateway_key", ""):
            manifest["gateway_key"] = args.gateway_key
    if args.corpus:
        resolved = resolve_corpus_source(args.corpus)
        if not resolved:
            sys.exit(f"ERROR: could not load corpus: {args.corpus}")
        dst = os.path.join(run_dir, "corpus" + (os.path.splitext(resolved)[1] or ".facts"))
        shutil.copyfile(resolved, dst)
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

    # SERVICE deployment: hand the run to the OS as a long-lived daemon instead of a foreground process. The worker
    # reads its key from run_dir/keys.env (the service won't inherit this shell's env), so persist it there.
    if service:
        if args.key and args.provider != "ollama":
            with open(os.path.join(run_dir, "keys.env"), "w", encoding="utf-8") as f:
                f.write("NL_LLM_KEY=" + args.key + "\n")
        install_service(args.name, run_dir, binary, neuron, args.model)
        print(f"\n  events: {os.path.join(run_dir, 'events.jsonl')}   |   talk to it: python examples/embedded/veil_chat.py --dir {run_dir} chat")
        return

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

# ---------------------------------------------------------------------------- model discovery
POPULAR_MODELS = {
    "openai":     ["gpt-4.1 (most capable)", "gpt-4.1-mini (default, cheap)", "gpt-4.1-nano (cheapest)", "o4-mini (reasoning)"],
    "groq":       ["llama-3.3-70b-versatile (default)", "llama-3.1-8b-instant (cheapest, fast)", "openai/gpt-oss-20b"],
    "together":   ["meta-llama/Llama-3.3-70B-Instruct-Turbo (default)", "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo (cheap)"],
    "openrouter": ["meta-llama/llama-3.3-70b-instruct (default)", "google/gemini-2.0-flash-001 (cheap, fast)", "openai/gpt-4.1-mini"],
    "custom":     [],
}

def fetch_models(base_url, key):
    """GET {base_url}/models from an OpenAI-compatible endpoint -> sorted list of model ids, or None."""
    import urllib.request
    try:
        req = urllib.request.Request(base_url.rstrip("/") + "/models",
                                     headers={"Authorization": f"Bearer {key}"})
        with urllib.request.urlopen(req, timeout=6) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
        ids = [m.get("id", "") for m in data.get("data", []) if m.get("id")]
        return sorted(set(ids)) or None
    except Exception:
        return None

def gateway_suggestions(provider, base_url):
    """Suggest cheap models suitable for the mechanical gateway. On Ollama, the small local models;
    on a hosted provider, the cheap end of that provider's catalogue (live list if reachable)."""
    if provider == "ollama":
        local = ollama_models() or []
        small = [m for m in local if any(t in m.lower() for t in
                 ("1b", "2b", "3b", "7b", "8b", "mini", "small", "phi", "gemma", "qwen2.5:3",
                  "llama3.2", "tinyllama", "mistral"))]
        return (small or local)[:8]
    hints = [h.split(" (")[0] for h in POPULAR_MODELS.get(provider, [])]
    cheap = [h for h in hints if any(t in h.lower() for t in ("nano", "mini", "8b", "instant", "flash", "small"))]
    return cheap or hints[:3]

# ---------------------------------------------------------------------------- knowledge packs
TEXT_FIELDS = ("text", "content", "fact", "sentence", "document", "body", "article", "passage",
               "summary", "abstract", "title", "question", "answer", "instruction", "response",
               "output", "input", "prompt", "completion", "chosen", "description", "caption")
MAX_PACK_FACTS = 500_000

def _extract_text(obj):
    """Pull the human-readable text out of one dataset record (a str, or a dict of fields)."""
    if isinstance(obj, str):
        return obj
    if isinstance(obj, dict):
        parts = [str(obj[k]) for k in TEXT_FIELDS
                 if k in obj and isinstance(obj[k], (str, int, float)) and str(obj[k]).strip()]
        if parts:
            return " ".join(parts)
        return " ".join(str(v) for v in obj.values() if isinstance(v, (str, int, float)))
    return str(obj)

def _split_facts(text):
    """A passage -> a list of single-line, pack-safe facts (16..480 chars). Long passages are split
    into sentences so a knowledge pack KEEPS the content instead of dropping over-long records."""
    text = re.sub(r"\s+", " ", str(text)).strip()
    if len(text) < 16:
        return []
    if len(text) <= 480:
        return [text]
    out = []
    for sent in re.split(r"(?<=[.!?])\s+", text):
        sent = sent.strip()
        while len(sent) > 480:
            cut = sent.rfind(" ", 0, 480)
            cut = cut if cut > 0 else 480
            head, sent = sent[:cut].strip(), sent[cut:].strip()
            if len(head) >= 16:
                out.append(head)
        if len(sent) >= 16:
            out.append(sent)
    return out

def _ingest_records(path, emit):
    """Stream a jsonl / json-array / plain-text file, emitting extracted text per record. Returns count."""
    n = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        head = f.read(256).lstrip(); f.seek(0)
        if head.startswith("["):
            try:
                for obj in json.load(f):
                    n += 1; emit(_extract_text(obj))
            except Exception:
                pass
        else:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                n += 1
                if line[0] == "{":
                    try:
                        emit(_extract_text(json.loads(line)))
                    except Exception:
                        emit(line)
                else:
                    emit(line)
    return n

def convert_to_facts(path):
    """Convert a downloaded dataset file (jsonl/json/csv/tsv/txt/parquet) into a .facts pack — clean,
    deduplicated, single-line facts (long passages are sentence-split). Returns the path, or None."""
    ext = os.path.splitext(path)[1].lower()
    out = os.path.splitext(path)[0] + ".facts"
    seen, facts, n_in = set(), [], 0

    def emit(text):
        if len(facts) >= MAX_PACK_FACTS:
            return
        for fact in _split_facts(text):
            key = fact.lower()
            if key not in seen:
                seen.add(key); facts.append(fact)
                if len(facts) >= MAX_PACK_FACTS:
                    return

    try:
        if ext == ".parquet":
            try:
                import pandas as pd
            except Exception:
                print("    parquet needs pandas+pyarrow (pip install pandas pyarrow), or give a .jsonl/.csv URL")
                return None
            df = pd.read_parquet(path)
            cols = [c for c in df.columns if str(c).lower() in TEXT_FIELDS] or list(df.columns)
            for _, row in df.iterrows():
                n_in += 1
                emit(" ".join(str(row[c]) for c in cols if pd.notna(row[c])))
        elif ext in (".csv", ".tsv"):
            import csv
            try:
                csv.field_size_limit(10_000_000)
            except Exception:
                pass
            try:
                with open(path, encoding="utf-8", errors="replace", newline="") as f:
                    rd = csv.DictReader(f, delimiter="\t" if ext == ".tsv" else ",")
                    cols = None
                    for row in rd:
                        n_in += 1
                        if cols is None:
                            cols = [c for c in row if c and c.lower() in TEXT_FIELDS] or [c for c in row if c]
                        emit(" ".join(str(row[c]) for c in cols if row.get(c)))
            except Exception as e:
                print(f"    csv parse hiccup ({type(e).__name__}); falling back to line mode")
                seen.clear(); facts.clear()
                n_in = _ingest_records(path, emit)
        else:
            n_in = _ingest_records(path, emit)
    except Exception as e:
        print(f"    parse failed: {type(e).__name__}: {e}")
        return None
    if not facts:
        print("    no usable text found in that file")
        return None
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(facts) + "\n")
    capped = "  [capped — raise the corpus cap or pre-trim if you need more]" if len(facts) >= MAX_PACK_FACTS else ""
    print(f"    converted -> {os.path.basename(out)}  ({len(facts)} facts from {n_in} records){capped}")
    return out

def _normalize_hf_url(url):
    """Turn a HuggingFace dataset file-viewer URL into a direct raw-download URL."""
    return url.replace("/blob/", "/resolve/")

def _hf_pick_file(repo):
    """Given a HF dataset id (owner/name), ask the HF API for its file tree and pick the first
    ingestible data file -> a resolve URL. Returns None if nothing suitable is found."""
    import urllib.request
    try:
        api = f"https://huggingface.co/api/datasets/{repo}/tree/main?recursive=true"
        with urllib.request.urlopen(urllib.request.Request(api, headers={"User-Agent": "veil-deploy/1.0"}), timeout=20) as r:
            tree = json.loads(r.read().decode("utf-8", "replace"))
        files = [e.get("path", "") for e in tree if e.get("type") == "file"]
        for ext in (".jsonl", ".json", ".csv", ".tsv", ".txt", ".parquet"):
            for p in files:
                if p.lower().endswith(ext):
                    return f"https://huggingface.co/datasets/{repo}/resolve/main/{p}"
    except Exception:
        return None
    return None

def fetch_and_convert_url(url):
    """Download a pack from a URL (incl. a HuggingFace dataset/file) and convert it to a .facts pack."""
    import urllib.request
    raw = _normalize_hf_url(url.strip())
    root = re.match(r"https?://huggingface\.co/datasets/([^/]+/[^/]+)/?$", raw)
    if root:
        picked = _hf_pick_file(root.group(1))
        if not picked:
            print("    couldn't auto-find a data file in that dataset. Open its 'Files and versions'")
            print("    tab, click a .jsonl/.csv/.parquet, and paste that file's download URL instead.")
            return None
        print(f"    dataset file: {picked}")
        raw = picked
    os.makedirs(os.path.join(DATA, ".packs"), exist_ok=True)
    fname = (raw.split("?")[0].rstrip("/").split("/")[-1]) or "pack.jsonl"
    dst = os.path.join(DATA, ".packs", fname)
    try:
        print(f"    downloading {raw} ...")
        req = urllib.request.Request(raw, headers={"User-Agent": "veil-deploy/1.0"})
        with urllib.request.urlopen(req, timeout=90) as r, open(dst, "wb") as f:
            shutil.copyfileobj(r, f)
    except Exception as e:
        print(f"    download failed: {type(e).__name__}: {e}")
        return None
    return convert_to_facts(dst)

def resolve_corpus_source(src):
    """Accept a local pack path OR a URL (incl. HuggingFace). Returns a local path to a ready-to-ingest
    pack, or None on failure. Already-local .facts/.jsonl/text files pass straight through."""
    src = (src or "").strip().strip('"').strip("'")
    if not src:
        return None
    if src.lower().startswith(("http://", "https://")):
        return fetch_and_convert_url(src)
    if os.path.isfile(src):
        return src
    print(f"    not found: {src}")
    return None

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
        p["key"] = wiz_key()
        hints = POPULAR_MODELS.get(choice, [])
        if hints:
            print("    popular models: " + "; ".join(hints))
        live = fetch_models(p["base_url"], p["key"]) if p.get("key") else None
        if live:
            print(f"    {len(live)} models available at this endpoint — type 'list' to see them all")
        while True:
            m = ask("model", p["model"])
            if m.lower() == "list" and live:
                for name in live:
                    print("      - " + name)
                continue
            p["model"] = m
            break
        if live and p["model"] not in live:
            print(f"    note: '{p['model']}' isn't in the endpoint's model list — check the spelling if the run is rejected")
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
    if getattr(args, "gateway_base_url", ""):
        parts.append(f"--gateway-base-url {args.gateway_base_url}")
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
    if corpus_wanted or ask_yes("preload a knowledge pack into hive memory?", corpus_wanted):
        print("    a pack is a .facts file (one fact per line) or .jsonl ({\"fact\": \"...\"} per line).")
        print("    or paste a URL — incl. a HuggingFace dataset (a /resolve/ file link, or the dataset")
        print("    page itself) — and it's downloaded and converted to facts automatically.")
        while True:
            src = ask("path or URL to the pack (blank to skip)", "")
            if not src:
                if corpus_wanted:
                    print("    note: offline mode is best with a pack, but continuing without one.")
                break
            resolved = resolve_corpus_source(src)
            if resolved:
                corpus = resolved
                break

    breakout = ask_yes("allow public Telegraph break-out when the hive's feeling flares?", False)

    corpus_cap, gateway_model = 20000, None
    gateway_base_url, gateway_key = "", ""
    if ask_yes("set advanced options (cheaper gateway model, corpus cap)?", False):
        print("    the gateway runs the hive's MECHANICAL calls (summarise / classify / route / gap-check)")
        print("    while the reasoning minds keep the main model — a small, cheap model is ideal here.")
        local_gw = ollama_models() or []
        small_local = [m for m in local_gw if any(t in m.lower() for t in
                       ("1b", "2b", "3b", "7b", "8b", "mini", "small", "phi", "gemma", "qwen2.5:3",
                        "llama3.2", "tinyllama", "mistral"))] or local_gw
        if p["provider"] == "ollama":
            if small_local:
                print("    local models: " + ", ".join(small_local[:8]))
        else:
            if small_local:
                print("    FREE — run the gateway on a local Ollama model (no extra API cost), e.g.:")
                print("      " + ", ".join(small_local[:8]))
            else:
                print("    tip: a free local model is ideal here — install Ollama + `ollama pull llama3.1:8b`,")
                print("         then enter it below and the gateway routes to it automatically.")
            cheap_hosted = gateway_suggestions(p["provider"], p["base_url"])
            if cheap_hosted:
                print("    or a cheaper model on THIS endpoint: " + ", ".join(cheap_hosted))
        gateway_model = ask("cheaper model for mechanical calls (blank = same as the minds)", "") or None
        if gateway_model and p["provider"] != "ollama":
            looks_local = gateway_model in local_gw or (":" in gateway_model and "/" not in gateway_model)
            if looks_local:
                gateway_base_url = "http://localhost:11434/v1"
                gateway_key = "gateway-local"
                print(f"    -> gateway routed to local Ollama ({gateway_base_url}); the minds stay on {p['provider']}")
                if gateway_model not in local_gw:
                    print(f"    note: '{gateway_model}' isn't pulled yet — run:  ollama pull {gateway_model}")
            else:
                gw = ask("gateway endpoint URL (blank = same endpoint as the minds)", "")
                if gw:
                    gateway_base_url = gw
                    gateway_key = "gateway-local" if ("localhost" in gw or "127.0.0.1" in gw) else wiz_key()
        if corpus:
            corpus_cap = ask_int("max facts to load from the corpus", corpus_cap)

    name = ask("run name", "swarm_" + time.strftime("%Y%m%d_%H%M%S"))
    deploy_as = ask_menu("How should it run on this system?", [
        ("isolated", "Isolated foreground run (default) - runs here in an isolated build env; you watch/stop it"),
        ("service",  "Live system daemon/service - installs to start on boot + restart on failure (systemd on Linux)"),
    ], 1)
    service = (deploy_as == "service")
    watch = False if service else ask_yes("watch the hive live after launch?", True)

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
        gateway_model=gateway_model, gateway_base_url=gateway_base_url, gateway_key=gateway_key,
        bin=None, neuron_bin=None, follow=watch, yes=False,
        service=service, rebuild_neuron=False,
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
    if argv[0] in ("doctor", "deps", "check"):
        return deps_doctor()
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
    ap.add_argument("--corpus", default=None, help="a .facts/.jsonl pack, OR a URL (incl. a HuggingFace dataset) to download + convert, preloaded into hive memory")
    ap.add_argument("--corpus-cap", dest="corpus_cap", type=int, default=20000)
    ap.add_argument("--gateway-model", dest="gateway_model", default=None, help="cheaper model for mechanical engine calls (summarise/classify/route)")
    ap.add_argument("--gateway-base-url", dest="gateway_base_url", default="", help="run the gateway on a different endpoint (e.g. free local Ollama while the minds use a paid API)")
    ap.add_argument("--gateway-key", dest="gateway_key", default="", help="API key for the gateway endpoint, if it differs from the minds'")
    ap.add_argument("--bin", default=None)
    ap.add_argument("--neuron-bin", dest="neuron_bin", default=None, help="path to an existing neuron engine binary")
    ap.add_argument("-y", "--yes", action="store_true", help="don't prompt before fetching/building the neuron engine or pulling the model")
    ap.add_argument("--service", action="store_true", help="install as a long-lived OS service/daemon (systemd on Linux) that starts on boot and restarts on failure, instead of a foreground run")
    ap.add_argument("--rebuild-neuron", dest="rebuild_neuron", action="store_true", help="re-fetch + rebuild the neuron memory engine from source before launching (always on for --service)")
    ap.add_argument("--follow", action="store_true", help="stream the hive's activity live")
    deploy(ap.parse_args())

if __name__ == "__main__":
    main()
