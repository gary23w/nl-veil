#!/bin/sh
# ============================================================================
# build-release.sh — package a self-contained veil release bundle.
#
# A bundle is the server (`veil`), the desktop (`veil-desk`), the memory engine
# (`neuron`), and a `start` launcher that runs the server AND the desktop at
# once. No Python, no toolchain, nothing to build on the user's machine.
#
#   scripts/build-release.sh            build THIS host's full bundle -> dist/
#   scripts/build-release.sh --all      also cross-compile the SERVER binary for
#                                        windows/linux/macos into dist/ (server
#                                        only — raylib + the Rust engine build
#                                        per-OS in CI; see .github/workflows).
#
# Env: ZIG=<zig>  NEURON=<path to a prebuilt neuron>  VERSION=<override>
# ============================================================================
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=${VERSION:-1.0.0}
ZIG=${ZIG:-zig}
DIST="$ROOT/dist"

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

say() { printf '\033[1;31m▌\033[0m %s\n' "$*"; }

# ---- 1. build server + desktop (one graph: -Ddesk=true also builds veil-desk) ----
say "building the server + desktop (zig build -Ddesk=true)"
( cd "$ROOT" && "$ZIG" build -Ddesk=true )
SERVER="$ROOT/zig-out/bin/veil$EXE"
DESK="$ROOT/desk/zig-out/bin/veil-desk$EXE"
[ -f "$SERVER" ] || { say "server binary not found at $SERVER"; exit 1; }
[ -f "$DESK" ] || say "! veil-desk not built (headless box / no GL) — bundling server only"

# ---- 2. locate or build the neuron memory engine ----
neuron=""
if [ -n "${NEURON:-}" ] && [ -f "$NEURON" ]; then
  neuron="$NEURON"
elif [ -f "$ROOT/bin/neuron$EXE" ]; then
  neuron="$ROOT/bin/neuron$EXE"
elif [ -d "$ROOT/../neuron-db/rust/neuron-core" ] && command -v cargo >/dev/null 2>&1; then
  say "building the neuron memory engine (cargo --release)"
  ( cd "$ROOT/../neuron-db/rust/neuron-core" \
    && cargo build --release --features "sqlite secure server trust" )
  cand="$ROOT/../neuron-db/rust/neuron-core/target/release/neuron$EXE"
  [ -f "$cand" ] && neuron="$cand"
fi
[ -n "$neuron" ] || say "! no neuron binary found — bundle will fetch/build it on first run (needs deploy.py)"

# ---- 3. assemble the bundle ----
NAME="veil-v$VERSION-$OS-$ARCH"
OUT="$DIST/$NAME"
rm -rf "$OUT"
mkdir -p "$OUT/bin"
cp "$SERVER" "$OUT/veil$EXE"
[ -f "$DESK" ] && cp "$DESK" "$OUT/veil-desk$EXE"
[ -n "$neuron" ] && cp "$neuron" "$OUT/bin/neuron$EXE"

# launcher: run the server in desktop-host mode (it spawns veil-desk sitting beside it)
cat > "$OUT/start" <<'LAUNCH'
#!/bin/sh
# start the veil server AND the desktop together.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"
exec ./veil --desk "$@"
LAUNCH
chmod +x "$OUT/start" "$OUT/veil$EXE" 2>/dev/null || true
[ -f "$OUT/veil-desk$EXE" ] && chmod +x "$OUT/veil-desk$EXE" 2>/dev/null || true
[ -f "$OUT/bin/neuron$EXE" ] && chmod +x "$OUT/bin/neuron$EXE" 2>/dev/null || true

cat > "$OUT/start.cmd" <<'LAUNCHW'
@echo off
cd /d "%~dp0"
veil.exe --desk %*
LAUNCHW

cat > "$OUT/README.txt" <<TXT
the veil — v$VERSION ($OS/$ARCH)

Run:
  Windows        double-click start.cmd
  macOS / Linux  ./start

It starts the server on http://127.0.0.1:8787 and opens the desktop dashboard.
Configure a model on first run (a local Ollama, or a hosted/BYOK endpoint).
Server-only:  ./veil        (no desktop)
Disable desk: NL_NO_DESKTOP=1 ./veil --desk

https://github.com/gary23w/nl-veil
TXT

# ---- 4. archive ----
mkdir -p "$DIST"
( cd "$DIST"
  if [ "$OS" = windows ] && command -v zip >/dev/null 2>&1; then
    rm -f "$NAME.zip"; zip -qr "$NAME.zip" "$NAME"
    say "packaged dist/$NAME.zip"
  else
    tar -czf "$NAME.tar.gz" "$NAME"
    say "packaged dist/$NAME.tar.gz"
  fi
)

# ---- 5. optional: cross-compile the server for the other platforms ----
if [ "${1:-}" = "--all" ]; then
  say "cross-compiling the server binary for all targets (server-only)"
  for tgt in x86_64-windows:windows:x86_64:.exe x86_64-linux-gnu:linux:x86_64: aarch64-macos:macos:arm64:; do
    ztarget=${tgt%%:*}; rest=${tgt#*:}; xos=${rest%%:*}; rest=${rest#*:}; xarch=${rest%%:*}; xexe=${rest#*:}
    [ "$xos" = "$OS" ] && [ "$xarch" = "$ARCH" ] && continue
    say "  server → $xos/$xarch"
    ( cd "$ROOT" && "$ZIG" build -Dtarget="$ztarget" ) || { say "  (skipped $xos/$xarch)"; continue; }
    xname="veil-server-v$VERSION-$xos-$xarch$xexe"
    cp "$ROOT/zig-out/bin/veil$xexe" "$DIST/$xname" 2>/dev/null || true
  done
  say "note: full desktop bundles for other OSes are built per-OS in CI (.github/workflows/release.yml)"
fi

say "done → $DIST"
