#!/bin/sh
# ============================================================================
# build-release.sh — package a self-contained veil release bundle.
#
# A bundle is the app (`veil` — ONE binary: the desktop GUI is compiled in and
# runs in-process alongside its server), the memory engine (`neuron`), and a
# `start` launcher. No Python, no toolchain, nothing to build on the user's
# machine, and no separate veil-desk binary any more.
#
#   scripts/build-release.sh            build THIS host's full bundle -> dist/
#   scripts/build-release.sh --all      also cross-compile the SERVER binary for
#                                        windows/linux/macos into dist/ (server
#                                        only — raylib + the Rust engine build
#                                        per-OS in CI; see .github/workflows).
#
# It bootstraps its own toolchain: if zig, rust, a C compiler, or (on Linux)
# raylib's dev libraries are missing, it fetches/installs them (pinned zig into
# ./.zig, rust via rustup, libs via the OS package manager). Opt out with
# NO_BOOTSTRAP=1 (then provide ZIG=/NEURON= yourself). Unattended: ASSUME_YES=1.
#
# Env: ZIG=<zig>  NEURON=<prebuilt neuron>  VERSION=<override>  NO_BOOTSTRAP=1  ASSUME_YES=1
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

# ---- 0. bootstrap the toolchain (unless the caller opted out) ----
# shellcheck source=lib-deps.sh
DEP_ROOT="$ROOT" . "$ROOT/scripts/lib-deps.sh"
if [ "${NO_BOOTSTRAP:-0}" != 1 ]; then
  # zig is the whole toolchain for the server + desktop — it bundles its own C compiler, so it builds
  # raylib's C itself. No external cc needed for those.
  ZIG=$(dep_zig) || { say "no zig — set ZIG=<path> or install from ziglang.org"; exit 1; }
  # the desktop links raylib against the platform GL/X11 libs (Linux only).
  [ "$OS" = linux ] && { dep_desk_libs || true; }
  # rust + a C compiler are needed ONLY to build neuron from source (cargo compiles its bundled SQLite,
  # which is C) — skip both when a prebuilt neuron is already available to bundle.
  if [ -z "${NEURON:-}" ] && [ ! -f "$ROOT/bin/neuron$EXE" ]; then
    dep_cargo || true
    dep_cc || true
  fi
fi
ZIG=${ZIG:-zig}

# ---- 1. build the app (ONE binary — the desktop GUI is compiled into veil) ----
# There is no separate veil-desk to build or bundle any more: `zig build` (-Dapp defaults to true) links
# raylib and the desk sources straight into veil, and a bare `veil` runs the window in-process.
say "building the app (zig build — desktop GUI compiled in)"
( cd "$ROOT" && "$ZIG" build )
SERVER="$ROOT/zig-out/bin/veil$EXE"
[ -f "$SERVER" ] || { say "veil binary not found at $SERVER"; exit 1; }

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
[ -n "$neuron" ] || say "! no neuron binary found — commit one to bin/ or build neuron-db before bundling"

# ---- 3. assemble the bundle ----
NAME="veil-v$VERSION-$OS-$ARCH"
OUT="$DIST/$NAME"
rm -rf "$OUT"
mkdir -p "$OUT/bin"
cp "$SERVER" "$OUT/veil$EXE"
[ -n "$neuron" ] && cp "$neuron" "$OUT/bin/neuron$EXE"

# launcher: a bare `veil` IS the app now (window + server in ONE process), so there is no flag to pass and
# no second binary to start. Kept as a launcher anyway so the bundle has an obvious double-click target and
# so the cwd is pinned to the bundle dir.
cat > "$OUT/start" <<'LAUNCH'
#!/bin/sh
# start the veil app — desktop window and its server, one process.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"
exec ./veil "$@"
LAUNCH
chmod +x "$OUT/start" "$OUT/veil$EXE" 2>/dev/null || true
[ -f "$OUT/bin/neuron$EXE" ] && chmod +x "$OUT/bin/neuron$EXE" 2>/dev/null || true

cat > "$OUT/start.cmd" <<'LAUNCHW'
@echo off
cd /d "%~dp0"
veil.exe %*
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
