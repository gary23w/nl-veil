#!/bin/sh
# check.sh -- the POSIX twin of scripts/check.ps1: the acceptance oracle's gates, one definition
# of done on every platform (CI's check job runs exactly these steps). The rich growth -Scan
# (test-graph reachability, docs mirror, in-flight banner) lives in check.ps1; --scan here covers
# the cheap signals only.
#
# Never touches a running app and never installs over zig-out/ (artifacts go to a throwaway
# prefix). No Defender self-heal here: the test-runner IPC flake is a Windows phenomenon; on
# Windows use check.ps1.
#
#   sh scripts/check.sh            gates: catalog sync, server build, src tests, desk tests
#   sh scripts/check.sh --full     also build the default GUI target (needs GL/X11 deps)
#   sh scripts/check.sh --scan     no builds: twin drift, version stamps, marker debt
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

# Windows (Git Bash): the pinned toolchain + the off-OneDrive cache. Elsewhere: zig from PATH,
# default cache (no OneDrive staleness problem to dodge).
case "$(uname -s)" in
  MINGW*|MSYS*)
    ZIG="${ZIG:-$USERPROFILE/zig-0.16.0/zig-x86_64-windows-0.16.0/zig.exe}"
    CACHE_ARGS="--cache-dir C:/zig-nlveil"
    PREFIX="C:/zig-nlveil/check-out"
    ;;
  *)
    ZIG="${ZIG:-zig}"
    CACHE_ARGS=""
    PREFIX="${TMPDIR:-/tmp}/nlveil-check-out"
    ;;
esac
PY="${PYTHON:-python}"
command -v "$PY" >/dev/null 2>&1 || PY=python3

fail=0
gate() { # gate <name> <cmd...>
  name="$1"; shift
  printf '>> %s\n' "$name"
  log="${TMPDIR:-/tmp}/nlveil-gate.$$.log"
  if "$@" >"$log" 2>&1; then
    cat "$log"
    printf '   PASS\n'
    rm -f "$log"
  else
    code=$?
    cat "$log"
    printf '   FAIL (%s)\n' "$code"
    # WHAT ACTUALLY BROKE, last — where a CI log is read from. A failing desk run buries its one
    # real assertion under CONNECTION_REFUSED stack dumps from tests that hit a dead port ON
    # PURPOSE, and a compile error can sit above a page of linker chatter.
    if grep -qE "^error: '.*' failed:|\.zig:[0-9]+:[0-9]+: error:|^error: the following" "$log"; then
      printf '   -- what failed --\n'
      grep -E "^error: '.*' failed:|\.zig:[0-9]+:[0-9]+: error:|^error: the following" "$log" | tail -8 | sed 's/^/   > /'
    fi
    rm -f "$log"
    fail=1
  fi
}

if [ "${1:-}" = "--scan" ]; then
  echo "== growth signals (lite; the full scan is check.ps1 -Scan) =="
  # twin drift: identical BELOW the //! header block (header prose differs per package by design)
  a=$(grep -v '^//!' src/worker/httpc.zig)
  b=$(grep -v '^//!' desk/src/httpc.zig)
  if [ "$a" = "$b" ]; then
    echo "[twins] httpc.zig twins in sync (below-header contract holds)"
  else
    echo "[twins] httpc.zig twin BODIES differ -- mirror them"
  fi
  vz=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -1)
  vm=$(sed -n 's/.*VERSION = "\([^"]*\)".*/\1/p' src/main.zig | head -1)
  if [ "$vz" = "$vm" ]; then echo "[version] $vz (zon matches main.zig)"; else echo "[version] zon=$vz main.zig=$vm -- stamp both (scripts/bump-version.ps1)"; fi
  grep -q "$vz" bin/MANIFEST.txt || echo "[version] bin/MANIFEST.txt carries no '$vz' stamp"
  echo "[markers] $(grep -rE 'TODO|FIXME|HACK|XXX' src desk/src --include='*.zig' | wc -l | tr -d ' ') TODO/FIXME/HACK/XXX across src + desk/src"
  exit 0
fi

# shellcheck disable=SC2086  # CACHE_ARGS is deliberately word-split
gate "catalog sync (models.yaml vs web/public/models.json)" "$PY" scripts/gen-models-json.py --check
gate "zig build server-only (-Dapp=false)" "$ZIG" build -Dapp=false $CACHE_ARGS --prefix "$PREFIX"
gate "zig build test (src suite)" "$ZIG" build test $CACHE_ARGS
[ -d desk ] || { echo "no desk/ package"; exit 1; }
gate_desk() { ( cd desk && "$ZIG" build test $CACHE_ARGS ); }
gate "zig build test (desk suite)" gate_desk
if [ "${1:-}" = "--full" ]; then
  gate "zig build default (GUI merged in)" "$ZIG" build $CACHE_ARGS --prefix "$PREFIX"
fi

echo
echo "== verdict =="
if [ "$fail" -eq 0 ]; then echo "ALL GREEN"; exit 0; fi
echo "NOT GREEN"
exit 1
