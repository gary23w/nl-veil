#!/bin/sh
# check.sh -- the POSIX twin of scripts/check.ps1: the acceptance oracle's gates, one definition
# of done on every platform (CI's check job runs exactly these steps). The rich -Scan
# (test-graph reachability, docs mirror, in-flight banner) lives in check.ps1; --scan here covers
# the cheap signals only.
#
# Never touches a running app and never installs over zig-out/ (artifacts go to a throwaway
# prefix). The test-runner IPC flake self-heals here too (see zig_tests, and its twin in check.ps1):
# the build runner can exit 0 after the test binary died without reporting, and neither twin may
# report green on a gate that produced no test verdict at all.
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
# STRICT gates refuse to read a zero exit as success when the log says a step died. The zig build
# runner has been observed printing "failed command: … zig build-exe" and a promoted LLD error and
# STILL exiting 0 — which reported a broken Linux GUI build as PASS in CI. Only build gates set
# this: the test gates legitimately print "failed command" on the IPC flake and then re-run the
# binary standalone (see zig_tests), so a blanket check there would fail every green run.
GATE_STRICT=0
gate_build() { GATE_STRICT=1; gate "$@"; GATE_STRICT=0; }

gate() { # gate <name> <cmd...>
  name="$1"; shift
  printf '>> %s\n' "$name"
  log="${TMPDIR:-/tmp}/nlveil-gate.$$.log"
  if "$@" >"$log" 2>&1; then
    if [ "$GATE_STRICT" = 1 ] && grep -qE '^failed command:|^error: ' "$log"; then
      cat "$log"
      printf '   FAIL (exit 0, but the log shows a failed step — see above)\n'
      grep -E '^failed command:|^error: ' "$log" | tail -4 | sed 's/^/   > /'
      rm -f "$log"
      fail=1
      return
    fi
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
  echo "== drift signals (lite; the full scan is check.ps1 -Scan) =="
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
  # desk/build.zig.zon is checked too: it was in NEITHER this echo nor bump-version.ps1's edit list, so it
  # sat at 1.0.0 through every alpha while the root manifest moved. A stamp nothing checks is a stamp that
  # drifts.
  vd=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' desk/build.zig.zon | head -1)
  if [ "$vz" = "$vm" ] && [ "$vd" = "$vm" ]; then echo "[version] $vz (zon + desk/zon match main.zig)"; else echo "[version] zon=$vz desk/zon=$vd main.zig=$vm -- stamp all three (scripts/bump-version.ps1)"; fi
  grep -q "$vz" bin/MANIFEST.txt || echo "[version] bin/MANIFEST.txt carries no '$vz' stamp"
  # The docs' download links name an explicit release tag. They used to say /releases/latest, which GitHub
  # resolves by SKIPPING prereleases -- and every app release so far has been one, so the buttons pointed at a
  # `builtin-assets-*` blob instead of the app. An explicit tag is correct but has to move with the version.
  bad=$(grep -roE 'releases/tag/v[^\s")]+' README.md docs/index.html | grep -v "releases/tag/v$vm\$" | wc -l | tr -d ' ')
  if [ "$bad" = "0" ]; then echo "[links] download links point at v$vm"; else echo "[links] $bad download link(s) in README/docs point at a tag other than v$vm (scripts/bump-version.ps1)"; fi
  # Word-bounded on purpose: without \b this counted ten `\uXXXX` doc-comment hits as debt, and a
  # signal that always reports phantom work is one you learn to skip. Keep IDENTICAL to check.ps1's
  # pattern -- the oracle-parity signal compares GATES only, so scan drift is caught by nothing.
  echo "[markers] $(grep -rE '\bTODO\b|\bFIXME\b|\bHACK\b|\bXXX\b' src desk/src --include='*.zig' | wc -l | tr -d ' ') TODO/FIXME/HACK/XXX across src + desk/src"
  exit 0
fi

# shellcheck disable=SC2086  # CACHE_ARGS is deliberately word-split
gate "catalog sync (models.yaml vs web/public/models.json)" "$PY" scripts/gen-models-json.py --check
# web/public/app.js is @embedFile'd VERBATIM into the binary — nothing compiles or parses it, so a
# syntax error or a truncated write ships a dead web UI behind a fully green build. That is the
# silent-failure shape this repo keeps producing, on the one artifact a user actually loads. Script
# dialect on purpose: the file carries no import/export, and --check would reject a plain script if
# asked to parse it as a module. Node is OPTIONAL here (Zig + Python are the real toolchain), so an
# absent node SKIPS LOUDLY rather than failing or passing quietly.
gate_webjs() {
  if command -v node >/dev/null 2>&1; then node --check web/public/app.js; else
    echo "SKIPPED: node not on PATH — web/public/app.js was NOT parsed"; fi
}
gate "web assets parse (node --check app.js)" gate_webjs
# -Dbuiltin=false, and why. This gate answers ONE question — does the server still compile without the GUI?
# `-Dapp=false` alone only skips raylib: -Dbuiltin and -Dvulkan both default TRUE, so this step also fetched
# llama.cpp, the Khronos headers and ~50MB of pre-built Vulkan shaders from two GitHub hosts before it
# compiled a line. That made the FIRST gate of every CI run depend on two large network transfers it never
# uses, and CI duly died on exactly that:
#     build.zig.zon:45: error: invalid HTTP response: HttpConnectionClosing   (veil-vulkan-shaders)
#     build.zig.zon:55: error: invalid HTTP response: HttpConnectionClosing   (SPIRV-Headers)
# while every later gate passed on the retry — a flaky download reported as a broken build.
# Coverage is unchanged: build_options.builtin gates ONE construction site, and the `zig build default`
# gate below compiles the whole thing WITH builtin + vulkan. This gate keeps the -Dapp=false path honest;
# that one keeps the engine honest. Locally, warm deps hide the difference; on a cold runner it is the
# difference between a fast signal and a coin flip.
gate_build "zig build server-only (-Dapp=false)" "$ZIG" build -Dapp=false -Dbuiltin=false $CACHE_ARGS --prefix "$PREFIX"
# `zig build test` can EXIT 0 after its test binary died without reporting a single result: the build
# runner prints `failed command: "...test.exe" ... --listen=-` and returns success anyway. Taking that
# as green means calling the suite passed while knowing nothing whatever about it -- the worst thing an
# acceptance oracle can do, and it happened on BOTH test gates of a run that printed ALL GREEN. On this
# machine Defender kills the test IPC and the very same binary passes standalone, so the honest move is
# not to suppress it but to go get the evidence: rerun the exact exe the runner named and take ITS
# verdict. A compile error names zig.exe, never a test.exe, so a real red cannot reach this path.
zig_tests() { # zig_tests <cmd...> -- forwards output, returns a verdict backed by an actual test run
  raw="${TMPDIR:-/tmp}/nlveil-zt.$$.log"
  "$@" >"$raw" 2>&1
  rc=$?
  cat "$raw"
  # BOTH spellings of the runner's failure line. It used to match only the Windows one --
  #   failed command: "C:\...\test.exe" "--cache-dir=..."
  # -- while Linux CI prints it unquoted and with no .exe:
  #   failed command: ./.zig-cache/o/HASH/test --cache-dir=... --seed=... --listen=-
  # so on Linux `exe` came back empty, the function fell through to the runner's exit code, and
  # that code was 0. Both test gates reported PASS having produced NO test verdict at all --
  # exactly what this helper's header promises can never happen.
  exe=$(sed -n \
    -e 's/^failed command: "\([^"]*test\.exe\)".*/\1/p' \
    -e 's|^failed command: \([^" ][^ ]*/test\)\( .*\)\{0,1\}$|\1|p' \
    "$raw" | head -1 | sed 's/\\\\/\\/g')
  if [ -z "$exe" ]; then
    # No named binary. If the runner ALSO printed a failure line, it died without a verdict and a
    # zero exit is meaningless -- never let that read as green.
    if grep -q '^failed command:' "$raw"; then
      rm -f "$raw"
      echo "   the runner reported a failed command but named no test binary --"
      echo "   that is a gate with no verdict; refusing to call it green"
      return 96
    fi
    rm -f "$raw"
    return "$rc"
  fi
  rm -f "$raw"
  echo "   build runner died without naming a test (IPC flake) -- rerunning it standalone:"
  echo "   $exe"
  [ -f "$exe" ] || { echo "   that exe is gone -- refusing to call this green"; return 97; }
  "$exe"
}
gate "zig build test (src suite)" zig_tests "$ZIG" build test $CACHE_ARGS
[ -d desk ] || { echo "no desk/ package"; exit 1; }
gate_desk() { ( cd desk && zig_tests "$ZIG" build test $CACHE_ARGS ); }
gate "zig build test (desk suite)" gate_desk
if [ "${1:-}" = "--full" ]; then
  gate_build "zig build default (GUI merged in)" "$ZIG" build $CACHE_ARGS --prefix "$PREFIX"
fi

echo
echo "== verdict =="
if [ "$fail" -eq 0 ]; then echo "ALL GREEN"; exit 0; fi
echo "NOT GREEN"
exit 1
