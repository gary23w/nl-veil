#!/bin/sh
# ============================================================================
# build-official.sh — the OFFICIAL release builder. Outputs everything to bin/.
#
# the veil — https://github.com/gary23w/nl-veil
# Author / publisher: gary23w — https://github.com/gary23w
#
# Produces:
#   • a FULL one-click bundle for THIS host  (ONE veil binary — server + desktop
#     + web UI + CLI in a single exe — plus neuron and a launcher)
#   • bin/server-only/ — the server cross-compiled for EVERY supported target
#   • SHA256SUMS.txt + MANIFEST.txt saying exactly what each artifact contains
#
# The bundle is SCRUBBED of runtime state (./data, keys, auth.sqlite) before it is
# archived, and the build refuses to package if any of it survives.
#
# WHY NOT FULL BUNDLES FOR ALL THREE OSes FROM ONE MACHINE
#   The desktop is raylib: it links the platform GUI stack (X11/GL on Linux,
#   Cocoa/OpenGL on macOS). Cross-compiling it fails at link time —
#     error: unable to find dynamic system library 'GL' ... 'X11' ... 'Xcursor'
#   because Zig ships no foreign GUI libs and macOS needs the Apple SDK. The
#   Rust memory engine (neuron) likewise wants a per-target toolchain.
#   The SERVER has no such deps and cross-compiles cleanly to all 5 targets.
#
#   So: run this script ON each OS — or just push a v* tag and let
#   .github/workflows/release.yml's windows/ubuntu/macos matrix run it — and
#   each run drops its own full bundle into bin/. Together they are the release.
#
#   sh scripts/build-official.sh              host bundle + every server target
#   sh scripts/build-official.sh --host-only  skip the cross-compiled servers
#
# Env: ZIG=<zig>  NEURON=<prebuilt neuron>  VERSION=<override>  NO_BOOTSTRAP=1
# ============================================================================
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/bin"
ZIG=${ZIG:-zig}

# VERSION comes from the binary's own literal so the artifacts can never disagree with `veil --version`.
VERSION=${VERSION:-$(sed -n 's/^const VERSION = "\(.*\)";$/\1/p' "$ROOT/src/main.zig" | head -1)}
[ -n "$VERSION" ] || { echo "could not read VERSION from src/main.zig"; exit 1; }

case "$(uname -s)" in
  Linux*)  OS=linux ;;
  Darwin*) OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) OS=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) ARCH=$(uname -m) ;;
esac
EXE=""
[ "$OS" = windows ] && EXE=".exe"

say()  { printf '\033[1;31m▌\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▌\033[0m %s\n' "$*"; }

# Zig cache OUTSIDE the repo. A repo-local .zig-cache inside a SYNCED folder (OneDrive/Dropbox/iCloud) gets
# mutated under the build and the install step then dies with
#   error: unable to update file from '.zig-cache/o/<hash>/veil.exe' to '<prefix>/bin/veil.exe': FileNotFound
# which silently drops a target from the release. Override with ZIG_CACHE=<dir>.
CACHE=${ZIG_CACHE:-}
if [ -z "$CACHE" ]; then
  case "$OS" in
    windows) CACHE="/c/nl-veil-zig-cache" ;;
    *) CACHE="${TMPDIR:-/tmp}/nl-veil-zig-cache" ;;
  esac
fi
mkdir -p "$CACHE"

mkdir -p "$OUT"

# ---- 0. toolchain bootstrap (same helper the dev release script uses) ----
if [ "${NO_BOOTSTRAP:-0}" != 1 ] && [ -f "$ROOT/scripts/lib-deps.sh" ]; then
  # shellcheck source=lib-deps.sh
  DEP_ROOT="$ROOT" . "$ROOT/scripts/lib-deps.sh"
  ZIG=$(dep_zig) || { say "no zig — set ZIG=<path> or install from ziglang.org"; exit 1; }
  [ "$OS" = linux ] && { dep_desk_libs || true; }   # raylib needs GL/X11 dev libs to LINK natively
  if [ -z "${NEURON:-}" ] && [ ! -f "$ROOT/bin/neuron$EXE" ]; then
    dep_cargo || true
    dep_cc || true
  fi
fi
ZIG=${ZIG:-zig}

# ---- 1. host build: server + desktop, into a PRIVATE staging prefix ----
# Deliberately NOT zig-out/: a release build must never fight (or clobber) the dev tree. On Windows a
# running veil.exe / veil-desk.exe holds zig-out/bin locked and the install step dies with AccessDenied —
# staging sidesteps that entirely, so you can cut a release while the app is still running.
STAGE="$ROOT/.release-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# --release=fast is now belt-and-braces rather than load-bearing: build.zig switches on b.release_mode itself,
# so a bare `zig build` is already ReleaseFast (it used to silently emit a DEBUG server). Kept explicit so the
# release build states its own mode instead of inheriting a default someone could change. Release builds also
# strip by default now — no 16MB PDB rides along beside a 5MB exe.
# ONE binary: the desktop GUI is compiled INTO veil (-Dapp, default on), so there is no separate
# veil-desk to build or ship any more. The trade is that this build now needs the platform graphics
# stack present — on a headless box the raylib link fails, and it would take the whole release with
# it. So: try the real thing, and if it does not link, fall back to an explicitly server-only bundle
# and SAY SO, rather than emitting something that silently has no window.
say "building the app for $OS/$ARCH (ReleaseFast, stripped, GUI linked in)"
HAVE_GUI=1
( cd "$ROOT" && "$ZIG" build --release=fast --cache-dir "$CACHE" --prefix "$STAGE/server" ) || HAVE_GUI=0
if [ "$HAVE_GUI" = 0 ]; then
  warn "the GUI did not link here (no GL/X11 dev libs?) — retrying server-only"
  rm -rf "$STAGE/server"
  ( cd "$ROOT" && "$ZIG" build -Dapp=false --release=fast --cache-dir "$CACHE" --prefix "$STAGE/server" )
fi
SERVER="$STAGE/server/bin/veil$EXE"
[ -f "$SERVER" ] || { say "veil binary missing at $SERVER"; exit 1; }
[ "$HAVE_GUI" = 1 ] || warn "THIS BUNDLE HAS NO DESKTOP — server + web UI only"

# ---- 2. the neuron memory engine ----
neuron=""
if [ -n "${NEURON:-}" ] && [ -f "$NEURON" ]; then neuron="$NEURON"
elif [ -f "$ROOT/bin/neuron$EXE" ]; then neuron="$ROOT/bin/neuron$EXE"
elif [ -d "$ROOT/../neuron-db/rust/neuron-core" ] && command -v cargo >/dev/null 2>&1; then
  say "building the neuron memory engine (cargo --release)"
  ( cd "$ROOT/../neuron-db/rust/neuron-core" && cargo build --release --features "sqlite secure server trust" )
  cand="$ROOT/../neuron-db/rust/neuron-core/target/release/neuron$EXE"
  [ -f "$cand" ] && neuron="$cand"
fi
[ -n "$neuron" ] || warn "no neuron binary — memory features degrade; put one at bin/neuron$EXE"

# ---- 3. assemble the full one-click bundle ----
NAME="veil-v$VERSION-$OS-$ARCH"
B="$OUT/$NAME"
rm -rf "$B"
mkdir -p "$B/bin"
cp "$SERVER" "$B/veil$EXE"
[ -n "$neuron" ] && cp "$neuron" "$B/bin/neuron$EXE"

# Launcher. A bare `veil` now boots the server AND opens the desk (the one-click default), so the
# launcher needs no flag at all — it exists purely so double-clicking works on every OS.
cat > "$B/start" <<'LAUNCH'
#!/bin/sh
# Start the veil: server + desktop, one click.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"
exec ./veil "$@"
LAUNCH
# `start "" veil.exe` — the empty "" is the window TITLE argument, not a typo: without it cmd treats the
# first quoted token as the title and would try to run nothing. Launching this way hands veil.exe off and
# lets start.cmd exit, so double-clicking does NOT leave a dead console window parked on the taskbar for
# the entire life of the server (the old `veil.exe %*` kept cmd blocked until the server died, and users
# closed that window — killing the server — thinking it was junk).
cat > "$B/start.cmd" <<'LAUNCHW'
@echo off
cd /d "%~dp0"
start "" veil.exe %*
LAUNCHW
chmod +x "$B/start" "$B/veil$EXE" 2>/dev/null || true
[ -n "$neuron" ] && chmod +x "$B/bin/neuron$EXE" 2>/dev/null || true

cat > "$B/README.txt" <<TXT
the veil — v$VERSION ($OS/$ARCH)

RUN IT
  Windows        double-click start.cmd  (or veil.exe)
  macOS / Linux  ./start                 (or ./veil)

One click brings up BOTH the local server (http://127.0.0.1:8787) and the
desktop app. Pick a model on first run — a local Ollama, or any hosted/BYOK
endpoint (OpenAI, Anthropic, DeepSeek, Moonshot, Cloudflare, OpenRouter, ...).

OTHER WAYS TO RUN
  veil --server-only     server alone, no desktop (headless boxes, services)
  veil chat              talk to the running server from the terminal
  veil cast "<goal>"     deploy a swarm
  veil list | stop <id>  fleet control

Everything is local: your data lives in ./data, your keys stay on this machine.

the veil — by gary23w
  author   https://github.com/gary23w
  project  https://github.com/gary23w/nl-veil
TXT

# ---- 3b. SCRUB the bundle before it is sealed ----
# Anything that ran veil out of this directory — a smoke test, a manual double-click, an interrupted
# earlier run — leaves ./data behind, and ./data is where the LIVE SECRETS live: .desktop_key is a working
# admin API key for the local control plane, .server.key signs sessions, auth.sqlite holds the user table.
# Shipping those in a public release archive hands every downloader the same admin credentials. The bundle
# must contain only artifacts we deliberately put there, so delete runtime state and REFUSE to package if
# it somehow survives (a failed delete is a release-blocking bug, not a warning).
rm -rf "$B/data"
rm -f "$B/.server.key" "$B/.desktop_key" "$B"/*.sqlite "$B"/*.sqlite-* 2>/dev/null || true
if [ -e "$B/data" ]; then
  say "REFUSING TO PACKAGE: $B/data still exists after scrub (would leak live keys)"
  exit 1
fi
leaked=$(find "$B" \( -name '.desktop_key' -o -name '.server.key' -o -name 'auth.sqlite' \) 2>/dev/null | head -5)
if [ -n "$leaked" ]; then
  say "REFUSING TO PACKAGE: secret material inside the bundle:"; echo "$leaked"; exit 1
fi
say "bundle scrubbed (no data/, no keys)"

( cd "$OUT"
  if command -v zip >/dev/null 2>&1; then
    rm -f "$NAME.zip"; zip -qr "$NAME.zip" "$NAME"; say "packaged bin/$NAME.zip"
  else
    tar -czf "$NAME.tar.gz" "$NAME"; say "packaged bin/$NAME.tar.gz"
  fi )

# ---- 4. cross-compile the SERVER for every target ----
# These are genuine, runnable server binaries — they just have no GUI beside them. They live in their own
# server-only/ subdirectory, NOT loose in bin/: sitting beside the bundle archive, `veil-server-...-windows-
# x86_64.exe` is the most double-clickable thing in the folder, and clicking it starts a headless control
# plane with no desk attached — the user sees nothing happen and has a stray server running. A subdirectory
# named for what they are makes that a deliberate choice instead of an accident.
XOUT="$OUT/server-only"
SERVER_TARGETS="x86_64-windows:windows:x86_64:.exe
x86_64-linux-gnu:linux:x86_64:
aarch64-linux-gnu:linux:arm64:
x86_64-macos:macos:x86_64:
aarch64-macos:macos:arm64:"

if [ "${1:-}" != "--host-only" ]; then
  say "cross-compiling the server for every target"
  # Stale binaries from a previous run would otherwise be re-listed in MANIFEST.txt and re-checksummed
  # even if this run's build for that target FAILED.
  rm -rf "$XOUT"
  mkdir -p "$XOUT"
  # Loose copies from before the server-only/ move — sweep them so bin/ has exactly one home for these.
  rm -f "$OUT"/veil-server-v*-* 2>/dev/null || true
  echo "$SERVER_TARGETS" | while IFS= read -r row; do
    [ -n "$row" ] || continue
    ztarget=${row%%:*}; rest=${row#*:}; xos=${rest%%:*}; rest=${rest#*:}; xarch=${rest%%:*}; xexe=${rest#*:}
    printf '    %-18s ' "$xos/$xarch"
    if ( cd "$ROOT" && "$ZIG" build --release=fast -Dtarget="$ztarget" --cache-dir "$CACHE" --prefix "$STAGE/xc/$ztarget" ) >/dev/null 2>&1; then
      cp "$STAGE/xc/$ztarget/bin/veil$xexe" "$XOUT/veil-server-v$VERSION-$xos-$xarch$xexe" 2>/dev/null && echo "ok" || echo "copy failed"
    else
      echo "FAILED"
    fi
  done
fi
rm -rf "$STAGE"

# ---- 5. manifest + checksums ----
{
  echo "the veil v$VERSION — release artifacts"
  echo
  echo "FULL BUNDLE (server + desktop + neuron, one-click):"
  echo "  $NAME/            built here on $OS/$ARCH"
  echo
  # Only claim a server-only section if something is actually in it (--host-only runs have none).
  have_xc=0
  for f in "$XOUT"/veil-server-v"$VERSION"-*; do [ -e "$f" ] && have_xc=1; done
  if [ "$have_xc" = 1 ]; then
    echo "SERVER-ONLY BINARIES (no desktop — the GUI cannot cross-compile; see below):"
    echo "  server-only/      headless control plane, NOT the one-click app — do not double-click these"
    for f in "$XOUT"/veil-server-v"$VERSION"-*; do [ -e "$f" ] && echo "    server-only/$(basename "$f")"; done
    echo
  fi
  echo "To get a FULL bundle for another OS, run scripts/build-official.sh on that OS,"
  echo "or push a v* tag and let .github/workflows/release.yml build all three natively."
} > "$OUT/MANIFEST.txt"

# Checksum ONLY this version's real release assets — a bare veil-* glob also swept up unrelated dev scratch
# binaries sitting in bin/ (veil-scratch.exe, veil-synapse.exe, ...) and the bundle DIRECTORY, which isn't a file.
( cd "$OUT"
  set --
  for f in "veil-v$VERSION-$OS-$ARCH.tar.gz" "veil-v$VERSION-$OS-$ARCH.zip" server-only/veil-server-v"$VERSION"-* MANIFEST.txt; do
    [ -f "$f" ] && set -- "$@" "$f"
  done
  [ "$#" -gt 0 ] || exit 0
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" > SHA256SUMS.txt
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@" > SHA256SUMS.txt
  fi )

say "done → bin/"
echo
sed 's/^/    /' "$OUT/MANIFEST.txt"
