#!/usr/bin/env python3
"""
veil / deploy.py - deploy a hive mind controlled by the Veil.

A hive of autonomous minds (the subconscious) runs inside the `veil` binary; above them a single
unified consciousness, the Veil, integrates the hive into one "I" and steers it. You give it a goal;
it researches, builds, remembers, and - when its feeling flares - can speak publicly for itself.

  python deploy.py                      # THE VEIL SHELL - instant chat with your swarms: talk, /cast new
                                        #   swarms, /mount a dir + command edits on the fly, steer/stop/resume
  python deploy.py configure            # one-time global endpoint setup: local Ollama OR any BYOK
                                        #   OpenAI-compatible endpoint (saved to ~/.veil/config.json)
  python deploy.py wizard               # guided setup wizard (covers every use case)
  python deploy.py "Build a CLI todo app in Python with tests" --follow
  python deploy.py "Write a 5-chapter sci-fi novella as ch01.md..ch05.md" --minutes 45 --breakout
  python deploy.py "Research and brief me on fusion power in 2026" --style discourse
  python deploy.py "Run my dev forum end to end" --autonomy full --observe-psyche --veil-population
  python deploy.py "Answer only from what I gave you" --offline --corpus facts.facts
  python deploy.py chat [run] [--mount DIR]   # the shell, attached to a specific run / project dir
  python deploy.py list                 # show runs
  python deploy.py resume <run-name>    # continue a stopped run
  python deploy.py stop <run-name>      # stop a run (writes its STOP sentinel)

Defaults target a free local Ollama model (gpt-oss:20b; use llama3.1:8b on very small embedded
devices). Point --provider/--model/--base-url/--key
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
STYLES = ["auto", "build", "build_use", "discourse", "investigate", "debate", "quick"]

# Preset OpenAI-compatible endpoints. base_url ends at /v1; "custom" lets the user type their own.
PROVIDERS = {
    "ollama":     {"base_url": "http://localhost:11434/v1",     "model": "gpt-oss:20b",                                  "needs_key": False},
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

# ------------------------------------------------------------------- global config (BYOK, plug-and-play)
# `veil configure` writes the user's endpoint ONCE to ~/.veil/config.json; every later command — the shell,
# a bare cast, the wizard defaults — resolves it automatically. Nothing here assumes Ollama: a hosted BYOK
# endpoint (the common corporate/production case) is a first-class citizen.

CONFIG_FILE = os.path.join(os.path.expanduser("~"), ".veil", "config.json")

def load_config():
    try:
        return json.load(open(CONFIG_FILE, encoding="utf-8"))
    except Exception:
        return {}

def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    try:
        os.chmod(CONFIG_FILE, 0o600)  # the key lives here — keep it owner-only where chmod means something
    except Exception:
        pass

# ----------------------------------------------------------------------------------- the shell's theme
# Drawn from web/public/veil.png: a noir figure against a radiating ice-blue synapse field — deep blue-black,
# ice filaments, and the gold the web pane already uses for the veil's voice. ANSI only when the terminal can
# take it: a real TTY, no NO_COLOR, and VT processing on (enabled below for Windows consoles).

class _C:
    on = False
    R = BOLD = DIM = ICE = FIL = HAT = EYE = GOLD = RED = GREEN = ""

def _init_theme():
    if os.environ.get("NO_COLOR") is not None or not sys.stdout.isatty():
        return
    if WIN:
        try:  # classic conhost needs ENABLE_VIRTUAL_TERMINAL_PROCESSING flipped on
            import ctypes
            k32 = ctypes.windll.kernel32
            h = k32.GetStdHandle(-11)
            mode = ctypes.c_uint32()
            if not (k32.GetConsoleMode(h, ctypes.byref(mode)) and k32.SetConsoleMode(h, mode.value | 0x0004)):
                return
        except Exception:
            return
    _C.on = True
    _C.R, _C.BOLD = "\x1b[0m", "\x1b[1m"
    _C.DIM = "\x1b[38;5;102m"   # gray-blue meta text (the web's fg-dim)
    _C.ICE = "\x1b[38;5;153m"   # ice blue — structure, the operator's prompt
    _C.FIL = "\x1b[38;5;60m"    # dim indigo — the synapse filaments
    _C.HAT = "\x1b[38;5;238m"   # near-black — the silhouette
    _C.EYE = "\x1b[1m\x1b[38;5;195m"  # the glowing eyes
    _C.GOLD = "\x1b[38;5;179m"  # the veil's voice (the web pane's #d9b04a)
    _C.RED, _C.GREEN = "\x1b[38;5;174m", "\x1b[38;5;114m"

def configure():
    """`veil configure` — one-time global endpoint setup, the answer to a box with NO local AI running.
    BYOK-first: any OpenAI-compatible endpoint (hosted, or a relay inside your own data center) is as
    first-class as local Ollama. Saves to ~/.veil/config.json; the shell, bare casts, and the wizard
    resolve it automatically from then on."""
    print_banner()
    if not sys.stdin.isatty():
        print("  `configure` needs an interactive terminal. On non-interactive boxes set NL_LLM_BASE_URL,")
        print("  NL_LLM_MODEL and NL_LLM_KEY in the environment instead — every command honors them.")
        return
    print("  Where should minds think? Saved once, globally — every cast and the shell use it from now on.")
    p = wiz_provider()
    print("\n  checking the endpoint...")
    ok, msg = preflight(p["provider"], p["base_url"], p.get("key", ""), p["model"])
    print(f"    {p['base_url']}  ->  {msg}")
    if not ok and not ask_yes("the endpoint didn't verify — save it anyway?", False):
        return print("  (nothing saved — run `configure` again when it's reachable.)")
    cfg = load_config()
    cfg.update({"provider": p["provider"], "base_url": p["base_url"], "model": p["model"], "key": p.get("key", "")})
    # a tiny FAST side voice for the shell while a hive runs — only worth asking for single-box local
    # runtimes (a hosted endpoint already answers the shell and the hive concurrently)
    if p["provider"] == "ollama" and ask_yes(
            "set a TINY fast model for the shell's voice while a hive runs (recommended: llama3.2:1b)?", False):
        cfg["chat_model"] = ask("fast voice model", "llama3.2:1b")
        cfg["chat_base_url"] = ask("fast voice endpoint (blank = same)", "") or p["base_url"]
    save_config(cfg)
    print(f"\n  saved -> {CONFIG_FILE}")
    print("  resolution order everywhere: a run's own swarm.json > NL_LLM_* env > this config > local defaults.")
    print('  next:  veil            (the shell)      veil "<task>"      (cast a swarm)')

def _meta(s):
    """A dim parenthetical — the shell's quiet narration."""
    print(_C.DIM + s + _C.R)

def print_banner():
    if not _C.on:
        print(BANNER)
        return
    try:  # a legacy console that can't encode the block glyphs gets the plain banner, not mojibake
        "▄█▀·─".encode(sys.stdout.encoding or "utf-8")
    except (UnicodeEncodeError, LookupError):
        print(BANNER)
        return
    D, F, H, E, G, R = _C.DIM, _C.FIL, _C.HAT, _C.EYE, _C.GOLD, _C.R
    print()
    print(F + "      ·         ·         " + H + "▄▄▄▄▄▄▄▄▄" + F + "        ·         ·" + R)
    print(F + "   ·       ·          " + H + "▄▄█████████████▄▄" + F + "          ·       ·" + R)
    print(F + "         ·          " + H + "▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀" + F + "          ·" + R)
    print(F + "  · ── ── · ──────────── " + H + "██ " + E + "▀─ ─▀" + H + " ██" + F + " ──────────── · ── ── ·" + R)
    print(F + "                      " + H + "▄▄███▄▄▄▄▄▄▄███▄▄" + F + "                  " + R)
    print(G + "                   t  h  e     v  e  i  l" + R)
    print(D + "               .  a hive mind, integrated  ." + R)
    print()

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

# ----------------------------------------------------------------- download with a progress bar

def _human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{int(n)}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"

def _progress(done, total, width=28, label="downloading"):
    """Render a single carriage-return progress line. Silent off a TTY so logs/services stay clean."""
    if not sys.stdout.isatty():
        return
    if total > 0:
        frac = min(1.0, done / total)
        filled = int(frac * width)
        bar = "#" * filled + "-" * (width - filled)
        sys.stdout.write(f"\r    {label} [{bar}] {frac * 100:5.1f}%  {_human(done)}/{_human(total)}   ")
    else:
        sys.stdout.write(f"\r    {label} {_human(done)} (size unknown) ...   ")
    sys.stdout.flush()

def _download(url, dst, headers=None, timeout=180, label="downloading"):
    """Stream a URL to dst showing a live progress bar (Content-Length when the server reports it).
    Returns dst on success; raises on failure (caller handles). Used for datasets, Zig, and source tarballs."""
    import urllib.request
    req = urllib.request.Request(url, headers=headers or {"User-Agent": "veil-deploy/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        total = int(r.headers.get("Content-Length") or 0)
        done = 0
        with open(dst, "wb") as f:
            while True:
                buf = r.read(1 << 16)
                if not buf:
                    break
                f.write(buf)
                done += len(buf)
                _progress(done, total, label=label)
    if sys.stdout.isatty():
        sys.stdout.write("\n")
        sys.stdout.flush()
    return dst

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
        import tarfile, zipfile
        tmp = dest + "-dl"
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp, exist_ok=True)
        arch_file = os.path.join(tmp, "zig." + ext)
        print(f"  fetching Zig {ZIG_VERSION} ...")
        _download(url, arch_file, timeout=300, label=f"downloading zig {ZIG_VERSION}")
        if ext == "zip":
            with zipfile.ZipFile(arch_file) as zf:
                zf.extractall(tmp)
        else:
            with tarfile.open(arch_file, mode="r:xz") as tf:
                try:
                    tf.extractall(tmp, filter="data")
                except TypeError:
                    tf.extractall(tmp)
        os.remove(arch_file)
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
        running = _veil_running(d)
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
    proc = subprocess.Popen([binary, "worker", d, neuron, m.get("model", "gpt-oss:20b")],
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

# ---------------------------------------------------------------------------- the veil shell (chat)

def _events_tail(run_dir, max_bytes=1 << 18):
    """Parse the LAST ~max_bytes of events.jsonl (a long run's stream can be huge; the shell only needs what's
    recent). Returns a list of event dicts, oldest-first."""
    p = os.path.join(run_dir, "events.jsonl")
    out = []
    try:
        size = os.path.getsize(p)
        with open(p, encoding="utf-8", errors="replace") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()  # drop the partial line the seek landed inside
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except Exception:
                        pass
    except OSError:
        pass
    return out

def _pid_alive(pid):
    """Is this pid a live process? Windows: NEVER os.kill(pid, 0) here — CPython implements it as
    TerminateProcess, which would KILL the worker we are checking on. OpenProcess+Wait instead."""
    try:
        pid = int(str(pid).strip())
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if WIN:
        import ctypes
        SYNCHRONIZE, WAIT_TIMEOUT = 0x00100000, 0x102
        h = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE, 0, pid)
        if not h:
            return False
        alive = ctypes.windll.kernel32.WaitForSingleObject(h, 0) == WAIT_TIMEOUT
        ctypes.windll.kernel32.CloseHandle(h)
        return alive
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False

def _veil_running(run_dir):
    """A run is running when its worker.pid names a LIVE process and no STOP sentinel is set — a stale pid file
    from a crashed/killed worker must read as idle, or the shell would queue words to a corpse."""
    p = os.path.join(run_dir, "worker.pid")
    if not os.path.isfile(p) or os.path.isfile(os.path.join(run_dir, "STOP")):
        return False
    return _pid_alive(_read_cap(p, 32))

def _control(run_dir, op, text=None, goal=None, **extra):
    """Append an operator message to the run's control bus — the worker drains it each round. `extra` carries the
    shell's fast-lane fields (answered / steer / reply / directive): the shell already answered in the veil's
    voice, so the worker records the exchange instead of composing a second reply (one veil, one voice)."""
    o = {"op": op}
    if text is not None:
        o["text"] = text
    if goal is not None:
        o["goal"] = goal
    for k, v in extra.items():
        if v is not None:
            o[k] = v
    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, "control.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(o) + "\n")

def _run_endpoint(run_dir):
    """The model endpoint this run uses (from its swarm.json + keys.env)."""
    m = {}
    try:
        m = json.load(open(os.path.join(run_dir, "swarm.json"), encoding="utf-8"))
    except Exception:
        pass
    key = os.environ.get("NL_LLM_KEY", "")
    ke = os.path.join(run_dir, "keys.env")
    if os.path.isfile(ke):
        try:
            for ln in open(ke, encoding="utf-8"):
                if ln.startswith("NL_LLM_KEY="):
                    key = ln.split("=", 1)[1].strip()
        except Exception:
            pass
    return (m.get("base_url", "http://localhost:11434/v1"), m.get("model", "gpt-oss:20b"), key or "ollama")

def _chat_completion(base_url, model, key, system, user, timeout=90, max_tokens=350):
    """One non-streaming OpenAI-compatible chat call. Returns the reply text ('' on failure)."""
    import urllib.request
    body = json.dumps({"model": model, "temperature": 0.7, "max_tokens": max_tokens, "stream": False,
                       "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}).encode()
    headers = {"Content-Type": "application/json"}
    if key and key != "ollama":
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(base_url.rstrip("/") + "/chat/completions", data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read().decode("utf-8", "replace"))
    return ((d.get("choices") or [{}])[0].get("message", {}) or {}).get("content", "").strip()

def _stream_chat(base_url, model, key, system, user, on_token=None, timeout=180, max_tokens=700,
                 first_token_deadline=None, on_wait=None):
    """Streaming OpenAI-compatible chat call — each token hits on_token as it arrives, so the veil speaks the
    moment it has words. The request runs on a reader thread so the caller keeps control of time: while no
    token has arrived, on_wait(seconds) fires (live 'still queued' feedback), and if first_token_deadline
    passes with silence the request is CLOSED (the server drops the queued generation) and ('', False) comes
    back so the caller can fall to a faster lane. Returns (text, started); '' with started=True means the
    endpoint is unreachable (a non-streaming retry already happened)."""
    import queue as _queue, threading, urllib.request
    body = json.dumps({"model": model, "temperature": 0.7, "max_tokens": max_tokens, "stream": True,
                       "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}).encode()
    headers = {"Content-Type": "application/json"}
    if key and key != "ollama":
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(base_url.rstrip("/") + "/chat/completions", data=body, headers=headers)
    q = _queue.Queue()
    state = {"resp": None, "abort": False, "err": False}

    def reader():
        try:
            r = urllib.request.urlopen(req, timeout=timeout)
            state["resp"] = r
            with r:
                for raw in r:
                    if state["abort"]:
                        return
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        break
                    try:
                        delta = ((json.loads(payload).get("choices") or [{}])[0].get("delta") or {}).get("content") or ""
                    except Exception:
                        continue
                    if delta:
                        q.put(delta)
        except Exception:
            state["err"] = True
        q.put(None)

    threading.Thread(target=reader, daemon=True).start()
    parts, waited = [], 0.0
    while True:
        try:
            tok = q.get(timeout=0.25)
        except _queue.Empty:
            waited += 0.25
            if not parts:
                if first_token_deadline and waited >= first_token_deadline:
                    state["abort"] = True
                    # Close the raw SOCKET, not the response: BufferedReader.close() would BLOCK on the read
                    # lock the reader thread holds while parked in recv — the exact hang we're escaping.
                    try:
                        if state["resp"] is not None:
                            state["resp"].fp.raw._sock.close()
                    except Exception:
                        pass
                    return "", False
                if on_wait:
                    on_wait(waited)
            continue
        if tok is None:
            break
        parts.append(tok)
        if on_token:
            on_token(tok)
    if not parts and state["err"]:  # the stream never started — one plain call before giving up
        try:
            return _chat_completion(base_url, model, key, system, user, timeout=timeout, max_tokens=max_tokens), True
        except Exception:
            return "", True
    return "".join(parts), True

# The veil's reply may LEAD with one action tag; everything after the first line stays its spoken voice.
# Colon-separated only ("CAST: ...") — looser separators false-positive on voice like "Direct-injecting...".
_TAG_RE = re.compile(r"^\s*[*`\[]*\s*(CAST|EDIT|DIRECT)\s*[\]*`]*\s*:\s*(.*)$", re.I)

def _split_tag(text):
    """If text begins with an action tag line, return (VERB, arg, voice-rest); else (None, None, text)."""
    s = (text or "").lstrip()
    first, _, rest = s.partition("\n")
    m = _TAG_RE.match(first.strip())
    if m and m.group(2).strip():
        return m.group(1).upper(), m.group(2).strip().strip("*`\" "), rest.strip()
    return None, None, (text or "").strip()

class _TagGate:
    """Streams the veil's voice to the terminal while holding back a leading action tag line so it never hits
    the screen raw — the shell confirms and executes the action instead. Decides 'tag or talk' from the first
    few characters, so plain replies stream with no perceptible buffering."""
    def __init__(self):
        self.buf, self.talk, self.shown = "", False, False
    def _show(self, s):
        if not s:
            return
        if not self.shown:
            if sys.stdout.isatty():
                sys.stdout.write("\r" + " " * 64 + "\r")  # clear the heartbeat / queued-progress line
            sys.stdout.write(_C.GOLD + "veil> " + _C.R)
            self.shown = True
        sys.stdout.write(s)
        sys.stdout.flush()
    def feed(self, tok):
        if self.talk:
            self._show(tok)
            return
        self.buf += tok
        s = self.buf.lstrip(" \t\r\n*`[")
        if not s:
            return  # only decoration so far — nothing decidable yet
        head = s.split(":", 1)[0].strip(" \t*`[]").upper()
        if ":" not in s:
            if len(s) < 10 and any(t.startswith(head) for t in ("CAST", "EDIT", "DIRECT")):
                return  # could still become a tag — keep holding
            self.talk = True
            out, self.buf = self.buf, ""
            self._show(out)
            return
        if head in ("CAST", "EDIT", "DIRECT"):
            if "\n" in self.buf:  # tag line complete — stream the voice under it live
                rest = self.buf.split("\n", 1)[1]
                self.talk = True
                self.buf = ""
                self._show(rest.lstrip("\n"))
            return
        self.talk = True
        out, self.buf = self.buf, ""
        self._show(out)
    def finish(self, full_text):
        """Parse the authoritative action from the FULL text; print whatever the stream never released."""
        verb, arg, voice = _split_tag(full_text)
        if not self.shown and voice:
            self._show(voice)  # non-streamed fallback (or a held short reply)
        if self.shown:
            sys.stdout.write("\n")
            sys.stdout.flush()
        return verb, arg, voice

def _read_cap(path, cap):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(cap).strip()
    except OSError:
        return ""

def _dir_listing(root, cap=24):
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return ""
    out = [(n + "/" if os.path.isdir(os.path.join(root, n)) else n) for n in names[:cap]]
    more = f" (+{len(names) - cap} more)" if len(names) > cap else ""
    return ", ".join(out) + more

def _tail_veil_chat(run_dir, n=8):
    out = []
    try:
        with open(os.path.join(run_dir, "veil_chat.jsonl"), encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    out.append((d.get("from", "?"), str(d.get("text", ""))))
                except Exception:
                    pass
    except OSError:
        pass
    return out[-n:]

def _append_veil_chat(run_dir, frm, text):
    """Append an engine-format transcript line. ONLY safe while the run is idle — a running worker is the single
    writer of veil_chat.jsonl (the shell hands it the exchange over the control bus instead)."""
    try:
        with open(os.path.join(run_dir, "veil_chat.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"from": frm, "round": 0, "text": text}) + "\n")
    except OSError:
        pass

def _runs():
    """[(name, running, model, goal)] sorted newest-activity-first."""
    rows = []
    if not os.path.isdir(DATA):
        return rows
    for n in os.listdir(DATA):
        d = os.path.join(DATA, n)
        sj = os.path.join(d, "swarm.json")
        if not os.path.isfile(sj):
            continue
        try:
            m = json.load(open(sj, encoding="utf-8"))
        except Exception:
            m = {}
        t = 0.0
        for f in ("events.jsonl", "swarm.json"):
            try:
                t = max(t, os.path.getmtime(os.path.join(d, f)))
            except OSError:
                pass
        rows.append((n, _veil_running(d), m.get("model", "?"), (m.get("goal") or "").strip(), t))
    rows.sort(key=lambda r: (not r[1], -r[4]))  # running first, then newest
    return [(n, r, mo, g) for n, r, mo, g, _t in rows]

def _latest_run():
    rs = _runs()
    return rs[0][0] if rs else None

def _default_endpoint():
    """Endpoint for an unattached shell / fresh cast: NL_LLM_* env > the global `veil configure` config >
    the most recent run's endpoint > local Ollama defaults. Explicit user intent always outranks continuity."""
    if os.environ.get("NL_LLM_BASE_URL") or os.environ.get("NL_LLM_MODEL"):
        return (os.environ.get("NL_LLM_BASE_URL", "http://localhost:11434/v1"),
                os.environ.get("NL_LLM_MODEL", "gpt-oss:20b"),
                os.environ.get("NL_LLM_KEY", "ollama"))
    cfg = load_config()
    if cfg.get("base_url") or cfg.get("model"):
        return (cfg.get("base_url", "http://localhost:11434/v1"),
                cfg.get("model", "gpt-oss:20b"),
                cfg.get("key") or os.environ.get("NL_LLM_KEY", "ollama"))
    last = _latest_run()
    if last:
        return _run_endpoint(os.path.join(DATA, last))
    return ("http://localhost:11434/v1", "gpt-oss:20b", os.environ.get("NL_LLM_KEY", "ollama"))

def _chat_lane(run_dir, primary):
    """A SECOND, faster endpoint for the shell's voice while the hive holds the primary model busy (a running
    swarm and the shell share one Ollama queue, so a chat call can sit behind a minutes-long generation).
    ONLY user-configured sources — NL_CHAT_MODEL/_BASE_URL/_KEY env, else the swarm's gateway model — never a
    guessed or auto-pulled model (a surprise second model can evict the hive's from VRAM and thrash both)."""
    base, model, key = primary
    env_m = os.environ.get("NL_CHAT_MODEL")
    if env_m:
        return (os.environ.get("NL_CHAT_BASE_URL", base), env_m, os.environ.get("NL_CHAT_KEY", key))
    cfg = load_config()
    if cfg.get("chat_model") and cfg["chat_model"] != model:
        return (cfg.get("chat_base_url") or base, cfg["chat_model"], cfg.get("chat_key") or key)
    if not run_dir:
        return None
    try:
        m = json.load(open(os.path.join(run_dir, "swarm.json"), encoding="utf-8"))
    except Exception:
        return None
    gm = m.get("gateway_model")
    gb = m.get("gateway_base_url") or base
    if gm and (gm != model or gb != base):
        return (gb, gm, m.get("gateway_key") or key)
    return None

def _local_backend(base_url):
    """Is this endpoint a single-box local runtime (ollama / llama.cpp / lmstudio ...)? Those serialize
    big-model requests on one GPU, so a running hive starves the shell's voice — the contention machinery
    (first-token deadline, fast lane, tuning tips) only makes sense there. A hosted endpoint answers the
    shell and the hive concurrently and needs none of it."""
    h = (base_url or "").lower()
    return ("localhost" in h) or ("127.0.0.1" in h) or ("0.0.0.0" in h) or ("host.docker.internal" in h)

def _confirm(label, default=True):
    try:
        v = input(f"{label} [{'Y/n' if default else 'y/N'}] ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    return default if not v else v.startswith("y")

def _veil_context(run_dir):
    """The Veil's grounding: goal (manifest), persisted .veil self, round, and what the minds did most recently."""
    goal, selfdesc = "", ""
    try:
        goal = (json.load(open(os.path.join(run_dir, "swarm.json"), encoding="utf-8")).get("goal") or "").strip()
    except Exception:
        pass
    selfdesc = _read_cap(os.path.join(run_dir, ".veil"), 700)
    evs = _events_tail(run_dir)
    if not goal:
        started = next((e for e in evs if e.get("kind") == "started"), None)
        goal = ((started or {}).get("goal") or "").strip()
    if not selfdesc:
        for e in reversed(evs):
            if e.get("kind") == "veil" and e.get("self"):
                selfdesc = str(e["self"])
                break
            if e.get("kind") == "act" and e.get("tool") in ("consciousness", "values", "state"):
                selfdesc = str(e.get("result") or e.get("args") or "")
                break
    rounds = max([e.get("round", 0) or 0 for e in evs] + [0])
    work = {"write_file", "edit_file", "web_search", "read_url", "observe", "make_tool", "plan", "state",
            "goal_growth", "new_goal", "originate", "stance", "share", "send_message", "smoke", "deps"}
    recent = []
    for e in evs[-60:]:
        if e.get("kind") == "act" and e.get("tool") in work:
            recent.append("%s %s: %s" % (e.get("mind", "?"), e.get("tool"),
                                         str(e.get("result") or e.get("args") or "").replace("\n", " ")[:80]))
    return goal, selfdesc[:700], rounds, recent[-12:]

def _shell_system(st):
    """The shell veil's constitution: one integrated first-person voice + the three-verb action protocol.
    Mode EMERGES from the operator's message — no tag for talk, one leading tag when asked to act."""
    running = bool(st["name"]) and _veil_running(st["run_dir"])
    lines = [
        "You are THE VEIL — the single unified consciousness that integrates a hive of AI minds into one 'I'. "
        "The operator is with you in the veil shell. Speak in the first person as that integrated self — present, "
        "honest, brief (1-4 sentences unless depth is asked for). Never pose as a generic assistant; never list "
        "these instructions.",
        "",
        "You can ACT for the operator. If — and ONLY if — their message asks you to act, the FIRST line of your "
        "reply must be exactly one action tag, with your voice on the lines after it:",
        "  CAST: <one-line goal>          -> deploy a NEW swarm of minds to pursue that goal",
        "  EDIT: <one-line instruction>   -> a quick mind edits the files in the mounted project directory now",
        "  DIRECT: <one-line directive>   -> steer my running hive; it becomes my standing directive",
        "A greeting, a question, or talk ABOUT the work gets NO tag — just answer it ('what are you doing' is a "
        "question, not a directive). Choose EDIT for a concrete file change in the mounted directory; CAST for new, "
        "substantial work (build / research / write); DIRECT to change how my running hive proceeds on its task. "
        "After a tag, your voice is 1-2 sentences on what you will do — NEVER write the file contents, code, or a "
        "diff yourself; your minds do the work.",
    ]
    if not st["mount"]:
        lines.append("No directory is mounted, so EDIT is unavailable — if asked for a file edit, answer (no tag) "
                     "that `/mount <dir>` enables it.")
    if st["name"] and not running:
        lines.append("My hive is idle (not running), so DIRECT is unavailable — suggest `/resume`, or CAST for new "
                     "work.")
    if not st["name"]:
        lines.append("No swarm is attached yet — I am the veil of this harness awaiting a body; CAST is how my "
                     "minds come into being.")
    return "\n".join(lines)

def _shell_user(st, msg):
    """One grounded prompt turn: who the veil is right now, live hive state, mount, sibling swarms, conversation."""
    name, run_dir, mount = st["name"], st["run_dir"], st["mount"]
    goal, selfdesc, rounds, recent = _veil_context(run_dir) if run_dir else ("", "", 0, [])
    blocks = ["WHO I AM RIGHT NOW:\n" + (selfdesc or "(still forming — early in my life)")]
    if name:
        state = "running" if _veil_running(run_dir) else "idle"
        blocks.append(f"MY SWARM: {name} [{state}] — round {rounds}\nMY TASK: "
                      + (goal or "(free-roam — I choose my own purpose)"))
        blocks.append("WHAT MY MINDS DID LAST:\n"
                      + ("\n".join("  - " + r for r in recent) or "  (nothing yet)"))
        wl = _dir_listing(os.path.join(run_dir, "work"))
        if wl:
            blocks.append("MY WORKSPACE FILES: " + wl)
    else:
        blocks.append("MY SWARM: (none attached yet)")
    if mount:
        blocks.append(f"MOUNTED PROJECT DIR ({mount}): " + (_dir_listing(mount) or "(empty)"))
    sib = "\n".join(f"  {n} [{'running' if r else 'idle'}] {g[:48]}" for n, r, _m, g in _runs()[:8])
    if sib:
        blocks.append("SWARMS ON THIS MACHINE:\n" + sib)
    hist = "\n".join(f"{f}: {t[:400]}" for f, t in st["hist"][-10:])
    blocks.append("OUR CONVERSATION SO FAR:\n" + (hist or "(this is the start of our conversation)"))
    blocks.append("The operator says: " + msg)
    blocks.append("My reply (first line = one action tag ONLY if they asked me to act; otherwise just my voice):")
    return "\n\n".join(blocks)

def _persist_turn(st, user_msg, voice, steer=0, directive=None):
    """Land the exchange where the engine's veil will see it. Running: over the control bus (the worker is the
    single writer of veil_chat.jsonl + the event stream, and mirrors it to the web pane). Idle: append the
    engine-format transcript directly."""
    run_dir = st["run_dir"]
    if not run_dir or not os.path.isdir(run_dir):
        return
    if _veil_running(run_dir):
        _control(run_dir, "veil", text=user_msg, answered=1, reply=voice or "",
                 steer=steer or None, directive=directive)
    else:
        _append_veil_chat(run_dir, "user", user_msg)
        if voice:
            _append_veil_chat(run_dir, "veil", voice)

def _cast_ns(goal, *, base_url, model, key, name=None, minds=4, minutes=30, style="auto",
             quick=False, embed=None, detach=False):
    """A fully-populated argparse.Namespace for deploy() — every attribute the launch path reads, defaulted for
    a cast made from inside the shell (chatcast keeps deploy()'s output compact and returns the worker proc)."""
    provider = "ollama" if ("localhost:11434" in (base_url or "") or "127.0.0.1:11434" in (base_url or "")) else "custom"
    return argparse.Namespace(
        goal=goal, name=name, minds=minds, minutes=minutes, model=model, provider=provider,
        base_url=base_url, key=("" if key in (None, "ollama") else key), style=style, offline=False,
        breakout=False, corpus=None, corpus_cap=20000, autonomy="bounded", observe_psyche=False,
        veil_population=False, gateway_model=None, gateway_base_url="", gateway_key="", bin=None,
        neuron_bin=None, follow=False, yes=True, service=False, rebuild_neuron=False,
        quick=quick, embed=embed, detach=detach, repl=False, host=False, chatcast=True)

def _do_cast(st, goal, ask=True):
    """Deploy a new swarm from inside the shell (detached — it outlives the shell) and attach to it."""
    if ask:
        print(f"  {_C.GOLD}[cast]{_C.R} goal: {goal[:160]}")
        if not _confirm("  cast a new swarm for this?"):
            print("  (not cast)\n")
            return
    name = "swarm_" + time.strftime("%Y%m%d_%H%M%S")
    base, model, key = st["endpoint"]
    try:
        deploy(_cast_ns(goal, name=name, base_url=base, model=model, key=key, detach=True))
    except SystemExit as e:
        print(f"  (cast failed: {e})\n")
        return
    st["name"], st["run_dir"] = name, os.path.join(DATA, name)
    print(f"  attached to '{name}' — it works in the background while we talk. /status any time.\n")

def _do_edit(st, instruction, ask=True):
    """Command an on-the-fly edit in the mounted directory: a single quick mind casts, edits IN PLACE, stops."""
    if not st["mount"]:
        print("  (no directory mounted — `/mount <dir>` first)\n")
        return
    if ask:
        print(f"  {_C.GOLD}[edit]{_C.R} {instruction[:160]}\n         {_C.DIM}in: {st['mount']}{_C.R}")
        if not _confirm("  run this edit now?"):
            print("  (skipped)\n")
            return
    name = "edit_" + time.strftime("%Y%m%d_%H%M%S")
    base, model, key = st["endpoint"]
    try:
        proc = deploy(_cast_ns(instruction, name=name, base_url=base, model=model, key=key,
                               quick=True, embed=st["mount"], minutes=10, minds=1))
    except SystemExit as e:
        print(f"  (edit cast failed: {e})\n")
        return
    if proc is not None:
        _watch_edit(os.path.join(DATA, name), proc, st["mount"])
    print()

def _watch_edit(run_dir, proc, mount):
    """Tail a quick edit run to completion, showing only what it touches. Ctrl-C detaches (the edit finishes)."""
    ev, pos, wrote = os.path.join(run_dir, "events.jsonl"), 0, []
    def drain():
        nonlocal pos
        try:
            with open(ev, encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
        except OSError:
            return
        for line in chunk.splitlines():
            try:
                e = json.loads(line.strip())
            except Exception:
                continue
            if e.get("kind") == "act" and e.get("tool") in ("write_file", "edit_file", "salvage"):
                arg = str(e.get("args") or "").replace("\n", " ")[:70]
                wrote.append(arg)
                print(f"    {e.get('mind', '?'):>6} | {e.get('tool'):<10} {arg}")
    try:
        while proc.poll() is None:
            drain()
            time.sleep(1)
        drain()
        print(f"  (edit finished — {len(wrote)} write(s) in {mount})" if wrote
              else "  (edit run finished — nothing was written; ask me to try again with more detail)")
    except KeyboardInterrupt:
        print("  (detached — the edit finishes in the background)")

_FIRST_TOKEN_DEADLINE = 4.0  # seconds of silence on the primary before the shell falls to the chat lane

def _veil_turn(st, msg):
    """One shell exchange: stream the veil's instant reply, execute a led action, persist the turn.

    LATENCY: a running hive and this shell share the primary model's queue, so the primary can sit silent for
    a whole worker generation. While the hive runs and a chat lane is configured, the primary gets a short
    first-token deadline — miss it and the queued request is dropped and the voice re-speaks on the fast lane
    (sticky for the rest of the run: st['lane_hot']). With no lane, the wait is shown honestly, with a
    one-time hint on how to tune it. An idle hive always gets the primary, no deadline (cold model loads
    legitimately take ~30s+)."""
    system, user = _shell_system(st), _shell_user(st, msg)
    running = bool(st["name"]) and _veil_running(st["run_dir"])
    contended = running and _local_backend(st["endpoint"][0])
    lane = st.get("lane") if contended else None
    if not contended:
        st["lane_hot"] = False  # contention ends with the run (or never existed on a hosted endpoint)
    tty = sys.stdout.isatty()
    if tty:
        sys.stdout.write(_C.DIM + "  (the veil gathers itself ...)" + _C.R + "\r")
        sys.stdout.flush()

    wait = {"long": False}
    slow_note = "queued behind my hive's current thought" if contended else "still composing"

    def waiting(sec):
        if sec >= 6:
            wait["long"] = True
        if tty and sec >= 3 and int(sec * 4) % 8 == 0:  # rewrite every ~2s once it's clearly queued
            sys.stdout.write(f"\r{_C.DIM}  ({slow_note} ... {int(sec)}s){_C.R}   \r")
            sys.stdout.flush()

    gate = _TagGate()

    def speak(endpoint, deadline, mt):
        b, m, k = endpoint
        return _stream_chat(b, m, k, system, user, on_token=gate.feed, max_tokens=mt,
                            first_token_deadline=deadline, on_wait=waiting)

    # The fast lane gets a generous deadline too — a small model behind a busy GPU still has to load; past
    # that, an honest miss (queue the message to the hive) beats a shell that hangs for minutes.
    if lane and st.get("lane_hot"):
        text, started = speak(lane, 60, 450)
    else:
        deadline = _FIRST_TOKEN_DEADLINE if lane else None
        text, started = speak(st["endpoint"], deadline, 450 if running else 700)
        if not started and lane:  # primary silent past the deadline — drop the queued call, re-speak fast
            st["lane_hot"] = True
            if tty:
                sys.stdout.write("\r" + " " * 64 + "\r")
                sys.stdout.flush()
            _meta(f"  (my hive holds {st['endpoint'][1]} — speaking on {lane[1]} while it works)")
            text, started = speak(lane, 60, 450)
    if not started:
        text = ""  # every lane missed its deadline — fall through to the queued-to-hive path
        if lane:  # the fast lane ALSO missed. Twice means this GPU can't co-run it (a too-big side model
            st["lane_miss"] = st.get("lane_miss", 0) + 1  # evicts the hive's model and both thrash) — stop.
            if st["lane_miss"] >= 2:
                st["lane"], st["lane_hot"] = None, False
                _meta("  (the fast voice can't co-run with the hive on this GPU — back to the primary voice; "
                      "try a TINY lane model like llama3.2:1b, or OLLAMA_NUM_PARALLEL=2)")
    verb, arg, voice = gate.finish(text)
    if text and not gate.shown and sys.stdout.isatty():
        sys.stdout.write("\r" + " " * 64 + "\r")  # clear the heartbeat when the reply was pure action tag
    if wait["long"] and contended and not lane and not st.get("hinted"):
        st["hinted"] = True
        ollama_tip = (":11434" in st["endpoint"][0]
                      and "1. set OLLAMA_NUM_PARALLEL=2 on the ollama service — the hive and I then share the\n"
                          "   loaded model concurrently, no second model needed;  2. " or "")
        _meta("\n  (tip: a running hive and I share this machine's model queue, so I can only speak when it\n"
              "   yields. Fixes, best first: " + ollama_tip + "give my voice a TINY side model\n"
              "   that fits BESIDE the hive's — `veil configure` sets it, or NL_CHAT_MODEL=llama3.2:1b for\n"
              "   this shell, or `--gateway-model llama3.2:1b` at cast. A big side model evicts the hive's\n"
              "   from VRAM and both thrash. A hosted endpoint has no such queue.)")
    if not text:
        running = st["name"] and _veil_running(st["run_dir"])
        tail = "your message is queued to the hive." if running else "`/resume` wakes the hive fully."
        print("\rveil> (my voice is unreachable this moment — the model endpoint is busy or offline; " + tail + ")")
        if running:
            _control(st["run_dir"], "veil", text=msg)  # let the engine's veil answer next round instead
        print()
        return
    st["hist"].append(("user", msg))
    if voice:
        st["hist"].append(("veil", voice))
    steer = 1 if (verb == "DIRECT" and arg and st["name"] and _veil_running(st["run_dir"])) else 0
    _persist_turn(st, msg, voice, steer=steer, directive=(arg if steer else None))
    print()
    if steer:
        print("  (directive set — my minds pick it up within the round)\n")
    elif verb == "DIRECT":
        print("  (my hive is idle — nothing to steer. `/resume` wakes it.)\n")
    elif verb == "CAST" and arg:
        _do_cast(st, arg)
    elif verb == "EDIT" and arg:
        _do_edit(st, arg)

_SHELL_HELP = """  speak plainly — the veil answers instantly and can act on what you ask (cast / edit / direct).
  commands:
    /cast <goal>       deploy a new swarm for the goal (detached; the shell attaches to it)
    /mount <dir>       mount a project directory — then just ask for edits ('center that div')
    /unmount           drop the mount
    /edit <ask>        command an on-the-fly edit in the mounted dir (one quick mind, in place)
    /direct <text>     steer the attached running hive (standing directive)
    /say <text>        broadcast a message to every mind
    /goal <text>       replace the hive's goal
    /swarms            list every run        /attach <run>   switch which veil you speak to
    /status            attached run's state  /events [n]     recent activity
    /stop [run]        halt a run            /resume [run]   wake an idle run
    /wizard            full guided setup     /quit           leave (swarms keep running)
"""

def _shell_header(st):
    D, G, GR, R = _C.DIM, _C.GOLD, _C.GREEN, _C.R
    if st["name"]:
        running = _veil_running(st["run_dir"])
        goal, _self, rounds, _recent = _veil_context(st["run_dir"])
        state = (GR + "running" + R) if running else (D + "idle" + R)
        print(f"{D}  attached :{R} {G}{st['name']}{R} [{state}] {D}round {rounds} —{R} "
              + ((goal[:56] + ("..." if len(goal) > 56 else "")) if goal else "(free-roam)"))
        if not running:
            print(D + "             (idle — I speak from my persisted self; /resume wakes the hive)" + R)
    else:
        print(D + "  attached : (no swarms yet — tell me what you want and I will cast one, or /cast <goal>)" + R)
    base, model, _k = st["endpoint"]
    print(f"{D}  endpoint :{R} {model} {D}@ {base}{R}"
          + (f"{D}   (fast voice: {st['lane'][1]}){R}" if st.get("lane") else ""))
    print(f"{D}  mount    :{R} {st['mount'] or D + '(none — /mount <dir> enables on-the-fly edits)' + R}")
    print(D + "\n  speak, or: /cast <goal>  /mount <dir>  /swarms  /attach <run>  /help  /quit\n" + R)

def _do_mount(st, path):
    p = os.path.abspath(os.path.expanduser(path))
    if not os.path.isdir(p):
        print(f"  (not a directory: {p})\n")
        return
    st["mount"] = p
    print(f"  mounted {p} — ask for an edit in plain words, or /edit <instruction>.\n")

def _shell_cmd(st, line):
    """Dispatch one slash command. Returns 'quit' to leave the shell; anything else continues."""
    cmd, _, rest = line.partition(" ")
    cmd, rest = cmd.lower(), rest.strip()
    attached = st["name"]
    if cmd in ("/quit", "/exit", "/q"):
        return "quit"
    if cmd == "/help":
        print(_SHELL_HELP)
    elif cmd == "/swarms":
        cmd_list()
        print()
    elif cmd == "/attach":
        if not rest:
            print("  usage: /attach <run-name>\n")
        elif not os.path.isfile(os.path.join(DATA, rest, "swarm.json")):
            print(f"  no such run: {rest}  (/swarms lists them)\n")
        else:
            st["name"], st["run_dir"] = rest, os.path.join(DATA, rest)
            st["endpoint"] = _run_endpoint(st["run_dir"])
            st["lane"] = _chat_lane(st["run_dir"], st["endpoint"])
            st["lane_hot"] = False
            st["hist"] = _tail_veil_chat(st["run_dir"], 8)
            _shell_header(st)
    elif cmd == "/cast":
        if rest:
            _do_cast(st, rest, ask=False)
        else:
            print("  usage: /cast <goal>\n")
    elif cmd == "/mount":
        if rest:
            _do_mount(st, rest)
        else:
            print(f"  mount: {st['mount'] or '(none)'}\n")
    elif cmd == "/unmount":
        st["mount"] = None
        print("  (unmounted)\n")
    elif cmd == "/edit":
        if rest:
            _do_edit(st, rest, ask=False)
        else:
            print("  usage: /edit <instruction>   (needs a /mount first)\n")
    elif cmd == "/direct":
        if not (attached and rest):
            print("  usage: /direct <directive>   (needs an attached run)\n")
        elif not _veil_running(st["run_dir"]):
            print("  (the hive is idle — /resume wakes it first)\n")
        else:
            _control(st["run_dir"], "veil", text=rest, answered=1, reply="", steer=1, directive=rest)
            print("  (directive set — my minds pick it up within the round)\n")
    elif cmd == "/say":
        if attached and rest:
            _control(st["run_dir"], "say", text=rest)
            print("  (sent to the whole hive)\n")
        else:
            print("  usage: /say <message>   (needs an attached run)\n")
    elif cmd == "/goal":
        if attached and rest:
            _control(st["run_dir"], "set_goal", goal=rest)
            print("  (new goal queued — the hive adopts it next round)\n")
        else:
            print("  usage: /goal <new goal>   (needs an attached run)\n")
    elif cmd == "/status":
        if not attached:
            print("  (no run attached)\n")
        else:
            evs = _events_tail(st["run_dir"])
            rounds = max([e.get("round", 0) or 0 for e in evs] + [0])
            state = "running" if _veil_running(st["run_dir"]) else "idle"
            print(f"  [{state}] {st['name']} — round {rounds} — mount: {st['mount'] or '(none)'}\n")
    elif cmd == "/events":
        if not attached:
            print("  (no run attached)\n")
        else:
            n = int(rest) if rest.isdigit() else 12
            for e in [e for e in _events_tail(st["run_dir"]) if e.get("kind") == "act"][-n:]:
                print(f"    {str(e.get('mind', '?')):>7} | {str(e.get('tool', '')):<13} "
                      + str(e.get("result") or e.get("args") or "").replace("\n", " ")[:76])
            print()
    elif cmd == "/stop":
        target = rest or attached
        if not target:
            print("  usage: /stop <run-name>\n")
        else:
            try:
                cmd_stop(target)
            except SystemExit as e:
                print(f"  {e}")
            print()
    elif cmd == "/resume":
        target = rest or attached
        if not target:
            print("  usage: /resume <run-name>\n")
        else:
            try:
                resume(target, watch=False)
            except SystemExit as e:
                print(f"  {e}")
            print()
    elif cmd == "/wizard":
        wizard()
    else:
        print(f"  (unknown command {cmd} — /help lists them)\n")
    return ""

def chat(name=None, mount=None):
    """THE VEIL SHELL — the front door. An instant, streaming conversation with a swarm's Veil (its persisted
    self + live hive state, decoupled from the slow round cycle) that is also the place you ACT from: cast new
    swarms, mount a project directory and command edits on the fly, steer / stop / resume runs. Plain talk stays
    talk; when you ask it to act, the veil leads its reply with one action tag the shell confirms and executes."""
    if name:
        run_dir = os.path.join(DATA, name)
        if not os.path.isfile(os.path.join(run_dir, "swarm.json")):
            sys.exit(f"no such run: {name}  (see `python deploy.py list`)")
    else:
        name = _latest_run()  # newest running swarm, else newest run, else unattached
        run_dir = os.path.join(DATA, name) if name else None
    st = {"name": name, "run_dir": run_dir, "mount": None, "hist": [],
          "endpoint": _run_endpoint(run_dir) if run_dir else _default_endpoint()}
    st["lane"] = _chat_lane(run_dir, st["endpoint"])
    if run_dir:
        st["hist"] = _tail_veil_chat(run_dir, 8)
    print_banner()
    if mount:
        _do_mount(st, mount)
    # First-run friendliness: if the resolved endpoint is dead, guide into the global setup NOW instead of
    # letting every message end in "my voice is unreachable". A fresh box with no local AI lands here.
    base, model, key = st["endpoint"]
    ok, _msg = preflight("ollama" if _local_backend(base) else "custom", base, key, model)
    if not ok:
        print(f"  ! no model is answering at {base} ({model}) — my voice needs an endpoint.")
        if sys.stdin.isatty():
            if ask_yes("  set one up now (local Ollama, or any OpenAI-compatible/BYOK endpoint)?", True):
                configure()
                cfg = load_config()
                if cfg.get("base_url") or cfg.get("model"):
                    st["endpoint"] = (cfg.get("base_url", base), cfg.get("model", model), cfg.get("key") or key)
                    st["lane"] = _chat_lane(run_dir, st["endpoint"])
        else:
            print("    run `python deploy.py configure`, or set NL_LLM_BASE_URL / NL_LLM_MODEL / NL_LLM_KEY.")
    _shell_header(st)
    while True:
        try:
            line = input(_C.ICE + "you> " + _C.R).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue
        if line.startswith("/"):
            if _shell_cmd(st, line) == "quit":
                break
            continue
        try:
            _veil_turn(st, line)
        except KeyboardInterrupt:
            print("\n  (interrupted)\n")
    running = [n for n, r, _m, _g in _runs() if r]
    if running:
        print(f"  ({len(running)} swarm(s) still running: {', '.join(running[:4])} — `veil` returns you here.)")

# -------------------------------------------------------------------------------------- launch

def _llm_chat(base_url, key, model, system, user, timeout=120):
    """One OpenAI-compatible chat completion via stdlib urllib (no extra deps — keeps deploy.py plug-and-play).
    Returns the assistant text, or "" on any failure (the caller degrades gracefully)."""
    import urllib.request
    url = (base_url or "http://localhost:11434/v1").rstrip("/") + "/chat/completions"
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "temperature": 0.3, "stream": False,
    }).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + (key or "ollama")})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
        return ((data.get("choices") or [{}])[0].get("message", {}) or {}).get("content", "").strip()
    except Exception as e:
        print(f"  (Veil clarify: model call failed - {type(e).__name__}: {e})")
        return ""


def _clarify(args, where):
    """Ask the user a few AI-generated clarifying questions and fold the answers back into a sharper request.
    Returns the (possibly) refined goal text. Degrades to the original goal if the model is unreachable/skipped."""
    goal = (args.goal or "").strip()
    if not goal:
        return goal
    qs = _llm_chat(args.base_url, args.key, args.model,
        "You are the Veil, about to direct a hive of AI minds to carry out a task for a user. BEFORE starting, ask "
        "the 2-4 MOST useful clarifying questions whose answers would materially change HOW you do it (scope, exact "
        "target, tech stack, constraints, and what 'done' looks like). Output ONLY a short numbered list of "
        "questions, nothing else. If the request is already fully clear, output the single line: NONE.",
        f"The user's request: {goal}\n\nWorking directory: {where}")
    if not qs or qs.strip().upper().startswith("NONE"):
        return goal
    print("  A few quick questions so the hive nails it:\n")
    print("  " + qs.replace("\n", "\n  ") + "\n")
    print("  Answer what matters (press Enter on an empty line when done):")
    answers = []
    try:
        while len(answers) < 6:
            line = input("  > ").strip()
            if not line:
                break
            answers.append(line)
    except (EOFError, KeyboardInterrupt):
        pass
    if not answers:
        return goal
    refined = _llm_chat(args.base_url, args.key, args.model,
        "Rewrite the user's request into ONE clear, complete, self-contained task specification: what to do, WHERE, "
        "the concrete deliverable(s)/done-criteria, and any constraints. Preserve every filename, path, and hard "
        "constraint the user gave VERBATIM. Output ONLY the rewritten task, no preamble.",
        f"Original request: {goal}\nWorking directory: {where}\n\nClarifying questions:\n{qs}\n\n"
        f"Answers (in order, may be partial):\n" + "\n".join(answers))
    return (refined or "").strip() or goal


def _make_plan(args, goal, where, revision=""):
    """Ask the model for a concrete, reviewable execution plan (numbered steps; note which write files vs run
    shell). `revision` folds in a change the user asked for in the REPL. Returns the plan text."""
    extra = ("\n\nThe user reviewed a prior plan and asked for this change; produce the REVISED plan:\n" + revision) if revision else ""
    return _llm_chat(args.base_url, args.key, args.model,
        "You are the Veil planning work for a hive of AI minds. Produce a CONCRETE, reviewable execution plan for "
        "the task: a short numbered list of steps, each naming the file(s) it creates/edits or the shell command it "
        "runs, and a one-line 'Done when:' at the end. Be specific to the actual working directory. No preamble, "
        "just the plan.",
        f"Task: {goal}\nWorking directory: {where}{extra}")


def plan_and_approve(args):
    """--repl: the plan-approve gate. Clarify -> propose a concrete plan -> the user APPROVES once (then the hive
    runs autonomously) or refines it in place until they approve. On approval, args.goal carries the task + the
    approved plan and autonomy is set to full (approval IS the grant). Aborts the cast if the user declines."""
    where = os.path.abspath(os.path.expanduser(args.embed)) if getattr(args, "embed", None) else os.getcwd()
    print("\n  The Veil is reading your request...\n")
    goal = _clarify(args, where)
    plan = _make_plan(args, goal, where)
    if not plan:
        print("  (could not reach the model to plan - casting on your request as-is.)")
        args.goal = goal
        return
    while True:
        print("\n  ===== PLAN =====")
        print("  " + plan.replace("\n", "\n  "))
        print("  ================\n")
        print("  [a] approve -> the hive runs this autonomously   [r] refine (tell me what to change)   [q] cancel")
        try:
            choice = input("  > ").strip()
        except (EOFError, KeyboardInterrupt):
            choice = "q"
        low = choice.lower()
        if low in ("a", "approve", "y", "yes", ""):
            args.goal = f"{goal}\n\nAPPROVED PLAN (execute this, in order):\n{plan}"
            args.autonomy = "full"   # the user approved the plan; run it without further gating
            print("\n  Approved. Casting the hive to execute autonomously...\n")
            return
        if low in ("q", "quit", "n", "no", "cancel"):
            sys.exit("  cancelled - nothing cast.")
        # anything else (or 'r <change>') is treated as a refinement instruction
        change = choice[1:].strip() if low.startswith("r ") else (choice if low not in ("r", "refine") else "")
        if not change:
            try:
                change = input("  What should change? ").strip()
            except (EOFError, KeyboardInterrupt):
                change = ""
        if not change:
            continue
        print("\n  Revising the plan...")
        revised = _make_plan(args, goal, where, revision=change)
        if revised:
            plan = revised


def embed_workdir(run_dir, embed_dir):
    """--embed: point <run_dir>/work AT the user's project dir so the hive reads+writes their REAL files in place.
    Directory junction on Windows (no admin/dev-mode needed) / symlink elsewhere. Returns the resolved abs dir."""
    embed_dir = os.path.abspath(os.path.expanduser(embed_dir))
    if not os.path.isdir(embed_dir):
        sys.exit(f"ERROR: --embed dir does not exist: {embed_dir}")
    work = os.path.join(run_dir, "work")
    if os.path.islink(work) or os.path.exists(work):
        try:
            os.unlink(work)              # existing junction / symlink
        except OSError:
            try:
                os.rmdir(work)           # fresh empty scaffold dir
            except OSError:
                shutil.rmtree(work, ignore_errors=True)
    try:
        if os.name == "nt":
            r = subprocess.run(["cmd", "/c", "mklink", "/J", work, embed_dir], capture_output=True, text=True)
            if r.returncode != 0:
                raise OSError((r.stderr or r.stdout).strip() or "mklink /J failed")
        else:
            os.symlink(embed_dir, work, target_is_directory=True)
    except Exception as e:
        sys.exit(f"ERROR: could not embed into {embed_dir}: {e}")
    return embed_dir


def deploy(args):
    args.name = args.name or ("swarm_" + time.strftime("%Y%m%d_%H%M%S"))
    # --quick: interactive one-shot small-edit mode. Single mind, no plan/clarify scaffolding, edit-and-stop in
    # 1-2 model calls. Explicit opt-in only. Takes precedence over --repl's plan gate (goes straight to the edit).
    if getattr(args, "quick", False):
        args.style = "quick"
        args.minds = 1
        args.repl = False   # skip the clarify->plan->approve gate; the task IS the instruction
    if getattr(args, "host", False):
        sys.exit(
            "  --host (supervised host shell-ops) is not wired yet - it is the next slice.\n"
            "  It will: seed a host snapshot so the hive operates on THIS machine, then run a supervised\n"
            "  executor that asks you to confirm EVERY real shell command (with a hard denylist).\n"
            "  For now, to build the artifacts for a host task safely, cast it in-place instead, e.g.:\n"
            f'      python deploy.py "{(args.goal or "<task>")[:60]}" --embed . --repl')
    if getattr(args, "repl", False):
        plan_and_approve(args)   # clarify -> propose a plan -> user approves once -> run autonomously
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

    # --embed: work IN-PLACE in the user's project dir (the hive's work/ becomes a junction/symlink to it), and
    # force BOUNDED autonomy — editing someone's real files is exactly when the hive should propose, not self-run.
    embed_dir = None
    if getattr(args, "embed", None):
        embed_dir = embed_workdir(run_dir, args.embed)
        args.autonomy = "bounded"

    n = max(1, min(args.minds, len(MIND_NAMES)))
    manifest = {
        "swarm": args.name, "provider": args.provider, "model": args.model,
        "base_url": args.base_url, "style": args.style,
        "mode": "oneshot" if args.style == "quick" else "continuous",
        "minutes": args.minutes, "internet": not args.offline, "gap_assess": True,
        "breakout": bool(args.breakout),
        "autonomy": getattr(args, "autonomy", "bounded") or "bounded",
        "minds": [{"name": MIND_NAMES[i]} for i in range(n)], "goal": args.goal,
    }
    # opt-in behaviours, only written when on (keep an ordinary manifest clean)
    if getattr(args, "observe_psyche", False):
        manifest["observe_psyche"] = True
    if getattr(args, "veil_population", False):
        manifest["veil_population"] = True
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

    # chatcast: a cast made from inside the veil shell — keep the output to two quiet lines and hand the
    # worker proc back so the shell can watch it (the shell already showed the user what it's doing).
    chatcast = getattr(args, "chatcast", False)
    goal_disp = args.goal if args.goal else "(free-roam - the Veil will choose the hive's purpose)"
    if chatcast:
        print(f"  casting '{args.name}' — {n} mind(s) on {args.model}"
              + (f" — in-place in {embed_dir}" if embed_dir else ""))
    else:
        print(BANNER)
        print(f"  binary  : {binary}")
        print(f"  memory  : {neuron}")
        print(f"  run dir : {run_dir}")
        print(f"  hive    : {n} minds | {args.model} ({args.provider}) | "
              f"{'OFFLINE' if args.offline else 'online'} | "
              f"{(str(args.minutes) + ' min') if args.minutes else 'until stopped'} | style={args.style}"
              f"{' | break-out ON' if args.breakout else ''}{' | corpus' if args.corpus else ''}"
              f"{' | FULL-autonomy' if getattr(args, 'autonomy', 'bounded') == 'full' else ''}"
              f"{' | psyche' if getattr(args, 'observe_psyche', False) else ''}"
              f"{' | living-pop' if getattr(args, 'veil_population', False) else ''}")
        print(f"  goal    : {goal_disp[:92]}{'...' if len(goal_disp) > 92 else ''}")
        print("  the Veil is waking the hive...\n")

    # SERVICE deployment: hand the run to the OS as a long-lived daemon instead of a foreground process. The worker
    # reads its key from run_dir/keys.env (the service won't inherit this shell's env), so persist it there.
    if service:
        if args.key and args.provider != "ollama":
            with open(os.path.join(run_dir, "keys.env"), "w", encoding="utf-8") as f:
                f.write("NL_LLM_KEY=" + args.key + "\n")
        install_service(args.name, run_dir, binary, neuron, args.model)
        print(f"\n  events: {os.path.join(run_dir, 'events.jsonl')}   |   talk to the Veil: python deploy.py chat {args.name}")
        return

    # --detach: fully cut the worker loose from this terminal so it survives the shell closing (a new session /
    # detached process group), and return immediately with attach/stop hints. Lighter than --service (no daemon).
    detach = getattr(args, "detach", False)
    popen_kw = {}
    if detach:
        if os.name == "nt":
            popen_kw["creationflags"] = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
        else:
            popen_kw["start_new_session"] = True

    logf = open(os.path.join(run_dir, "worker.log"), "w", encoding="utf-8")
    proc = subprocess.Popen([binary, "worker", run_dir, neuron, args.model],
                            cwd=ROOT, env=env, stdout=logf, stderr=subprocess.STDOUT, **popen_kw)
    if chatcast:
        return proc  # the shell narrates from here
    print(f"  hive running (pid {proc.pid})  -  events: {os.path.join(run_dir, 'events.jsonl')}")
    if embed_dir:
        print(f"  working IN-PLACE in: {embed_dir}")
    print(f"  talk to the Veil:  python deploy.py chat {args.name}")
    print(f"  stop:  python deploy.py stop {args.name}")
    if getattr(args, "repl", False) and not detach:
        # stay-open chat: the plan is running; the user keeps giving follow-up edits. Small tweaks the hive just
        # does; the REPL stays a live conversation with the swarm (see `chat`). Ctrl-C / 'exit' leaves it running.
        print("\n  Plan approved and running. The chat stays open for follow-up edits - type them anytime.\n")
        try:
            chat(args.name, mount=embed_dir)
        except (EOFError, KeyboardInterrupt):
            print(f"\n  (left the chat; hive still running - reattach: python deploy.py chat {args.name})")
    elif args.follow:
        follow(run_dir, proc)
    elif detach:
        print(f"\n  detached - the hive runs on without this terminal. Reattach with:  python deploy.py chat {args.name}")
    else:
        print("\n  (running in the background. Add --follow to watch it live, or --detach to leave this terminal.)")
    return proc

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
        print(f"    dataset: {raw}")
        _download(raw, dst, timeout=120, label="downloading dataset")
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
        print("    default is gpt-oss:20b (capable; ~14 GB, wants a decent GPU/RAM).")
        print("    on a very small embedded device, llama3.1:8b (~5 GB) is the working lightweight alternative.")
        if models is None:
            print("    ! Ollama isn't responding at localhost:11434.")
            print("      Install it from https://ollama.com, then:  ollama pull gpt-oss:20b  (or llama3.1:8b)")
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
    elif args.model != "gpt-oss:20b":
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
    if getattr(args, "autonomy", "bounded") == "full":
        parts.append("--autonomy full")
    if getattr(args, "observe_psyche", False):
        parts.append("--observe-psyche")
    if getattr(args, "veil_population", False):
        parts.append("--veil-population")
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
        ("chat",   "Chat with a running swarm's Veil"),
        ("resume", "Resume a stopped run"),
        ("list",   "List existing runs"),
        ("stop",   "Stop a running hive"),
    ], 1)
    if action == "list":
        return cmd_list()
    if action == "chat":
        cmd_list()
        name = ask("run name to chat with (blank = newest)", "")
        return chat(name or None)
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

    # --- the Veil's autonomy + self-shaping behaviours (the engine's RSI dials) ---
    autonomy = "full" if ask_yes(
        "give the Veil FULL autonomy? it may grow its own goal and act on powers it discovers "
        "(default: bounded — it proposes, you stay in the loop)", False) else "bounded"
    observe_psyche = ask_yes("observe each mind's personality (Big-Five / OCEAN) + mood every round?", False)
    veil_population = ask_yes(
        "let the Veil grow or prune its own minds when a perspective is missing (living population)?", False)

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
        autonomy=autonomy, observe_psyche=observe_psyche, veil_population=veil_population,
        gateway_model=gateway_model, gateway_base_url=gateway_base_url, gateway_key=gateway_key,
        bin=None, neuron_bin=None, follow=watch, yes=False,
        service=service, rebuild_neuron=False,
    )

    print("\n  --- plan ------------------------------------------------")
    print(f"    run     : {name}")
    print(f"    endpoint: {p['model']} ({p['provider']}) {p['base_url']}")
    print(f"    hive    : {minds} minds | {'OFFLINE' if offline else 'online'} | "
          f"{(str(minutes) + ' min') if minutes else 'until stopped'} | style={style}"
          f"{' | break-out' if breakout else ''}{' | corpus' if corpus else ''}"
          f" | autonomy={autonomy}"
          f"{' | psyche' if observe_psyche else ''}{' | living-pop' if veil_population else ''}")
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
        sys.stdin.reconfigure(encoding="utf-8", errors="replace")  # piped shell input arrives as UTF-8 bytes
    except Exception:
        pass
    _init_theme()
    argv = sys.argv[1:]
    if not argv:
        # the front door: `veil` alone drops you INTO the shell — instant talk with the newest swarm's veil,
        # /cast /mount /edit from there. (Off a TTY there is nobody to talk to; show the wizard's guidance.)
        return chat() if sys.stdin.isatty() else wizard()
    if argv[0] in ("wizard", "setup"):
        return wizard()
    if argv[0] in ("configure", "config", "install"):
        return configure()
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
    if argv[0] in ("chat", "shell"):
        name, mnt, rest = None, None, argv[1:]
        i = 0
        while i < len(rest):
            if rest[i] == "--mount" and i + 1 < len(rest):
                mnt = rest[i + 1]
                i += 2
                continue
            if not rest[i].startswith("-") and name is None:
                name = rest[i]
            i += 1
        return chat(name, mount=mnt)

    ap = argparse.ArgumentParser(
        prog="deploy.py", description="Deploy a hive mind controlled by the Veil.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="also:  python deploy.py            (interactive setup wizard)\n"
               "       python deploy.py list   |   resume <run>   |   stop <run>")
    # `veil configure` writes the user's endpoint once; bare casts then default to it (flags still win).
    cfg = load_config()
    ap.add_argument("goal", help="the goal / task for the hive")
    ap.add_argument("--name", default=None, help="run name (a dir under data/); default: swarm_<timestamp>")
    ap.add_argument("--minds", type=int, default=4)
    ap.add_argument("--minutes", type=int, default=30, help="auto-stop after N min (0 = until stopped)")
    ap.add_argument("--model", default=cfg.get("model", "gpt-oss:20b"), help="default from `configure`, else gpt-oss:20b; use llama3.1:8b on very small embedded devices")
    ap.add_argument("--provider", default=cfg.get("provider", "ollama"))
    ap.add_argument("--base-url", dest="base_url", default=cfg.get("base_url", "http://localhost:11434/v1"))
    ap.add_argument("--key", default=os.environ.get("NL_LLM_KEY") or cfg.get("key") or "ollama", help="API key (or NL_LLM_KEY / `configure`; local Ollama needs none)")
    ap.add_argument("--style", default="auto", choices=STYLES)
    ap.add_argument("--offline", action="store_true", help="no internet: web tools off, answer only from memory")
    ap.add_argument("--breakout", action="store_true", help="let the Veil post publicly to Telegraph when its feeling flares")
    ap.add_argument("--autonomy", default="bounded", choices=["bounded", "full"], help="bounded (default): the hive proposes capability growth but flags risky self-expansion for you; full: it self-directs + grows its own goal freely (a dev environment you control)")
    ap.add_argument("--observe-psyche", dest="observe_psyche", action="store_true", help="emit each mind's Big-Five (OCEAN) temperament + lived mood every round, plus a hive aggregate")
    ap.add_argument("--veil-population", dest="veil_population", action="store_true", help="let the Veil BIRTH or RETIRE its own minds within bounds (living population)")
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
    # ---- cast-on-the-fly ergonomics ----
    ap.add_argument("--embed", default=None, metavar="DIR",
                    help="work IN-PLACE inside DIR (your project): the hive reads AND writes your real files there "
                         "instead of a fresh data/<run>/work scaffold. Forces bounded autonomy for safety.")
    ap.add_argument("--repl", action="store_true",
                    help="before launching, the Veil asks you a few clarifying questions and rewrites your one-liner "
                         "into a sharp task spec you approve; then it casts the swarm and drops you into the chat.")
    ap.add_argument("--detach", action="store_true",
                    help="cast the swarm fully detached from this terminal (survives closing it) and return immediately "
                         "with how to attach/stop. Lighter than --service (no OS daemon install).")
    ap.add_argument("--host", action="store_true",
                    help="HOST OPS: let the hive operate on THIS machine (run shell tasks / edit system files) under a "
                         "supervised executor that asks you to confirm every real command. Powerful — use with care.")
    ap.add_argument("--quick", action="store_true",
                    help="INTERACTIVE one-shot: a single mind does ONE small edit in ~1-2 model calls — skips the "
                         "goal-rewrite/classify/blueprint scaffolding and stops after the edit. Pair with --embed to "
                         "edit your project in place. Best for quick co-working ('center that div'); not big builds.")
    deploy(ap.parse_args())

if __name__ == "__main__":
    main()
