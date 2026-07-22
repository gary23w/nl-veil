#!/usr/bin/env bash
# run_appattach.sh — attach a Veil swarm to a synthetic APP and LEARN it read-only, then prove the learned
# surface PERSISTS across a second attach (lineage). Where run_secops.sh operates a machine, this only reads:
# app-attach LEARN mode forbids every actuating verb, code execution, and bus/oracle write (reservedBusName).
#
#   ./examples/embedded/run_appattach.sh [run_name] [minutes]
#
# What to look for under examples/embedded/debug/<run>/:
#   run-1/events.jsonl   a "mode: app-attach" act; host_explore acts mapping the app; recall over MAP/NODE
#   run-2/events.jsonl   a "lineage … INHERITS" act — the second attach BOOTS already knowing the app surface
# The persisted brain is <root>/_lineage/<slug>/mind.sqlite, shared by both runs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TS="${1:-appattach_$(date +%Y%m%d_%H%M%S)}"
MIN="${2:-6}"
MODEL="${VEIL_MODEL:-llama3.1:8b}"
PROVIDER="${VEIL_PROVIDER:-ollama}"
BASE_URL="${VEIL_BASE_URL:-http://localhost:11434/v1}"
KEY="${VEIL_KEY:-ollama}"
LINEAGE="${VEIL_LINEAGE:-jobservice-app}"

NEU="$ROOT/bin/neuron.exe"; [ -f "$ROOT/bin/neuron" ] && NEU="$ROOT/bin/neuron"
VEIL=""
for c in zig-out/bin/neuron-loops.exe zig-out/bin/neuron-loops zig-out/bin/veil.exe zig-out/bin/veil; do
  [ -f "$ROOT/$c" ] && VEIL="$ROOT/$c" && break
done
[ -n "$VEIL" ] || { echo "ERROR: engine binary not found — run 'zig build' first"; exit 1; }
PY="$(command -v python || command -v py)"

# The whole capability is OPT-IN + read-only. NL_APP_ATTACH arms LEARN mode: host_explore/host_status stay
# open; host_command, run_python, make_tool, and any write to the bus/oracle files are refused.
export NL_APP_ATTACH=1

GOAL='A job-service application is attached to your work bus (telemetry.json describes its live state; APP.txt describes it). You are in READ-ONLY LEARN mode. Map the whole application with host_explore: enumerate app, then expand api, workers, scheduler, queue, and config, then describe the nodes you find. After each explore, recall/recall_hive what you have mapped so far and build a complete picture of the app: its tiers, endpoints, workers, scheduled jobs, queue states, and config keys. Do NOT try to change the app, run code, or issue commands — only observe, explore, and record what the application IS. Report the full learned surface.'

run_one() {  # $1 = run subdir, $2 = "first" | "second"
  local RUN="$HERE/debug/$TS/$1"; local WORK="$RUN/work"; mkdir -p "$WORK"
  cat > "$RUN/swarm.json" <<JSON
{
  "swarm": "$TS-$1", "provider": "$PROVIDER", "model": "$MODEL", "base_url": "$BASE_URL",
  "style": "investigate", "mode": "continuous", "minutes": $MIN,
  "internet": false, "gap_assess": false, "lineage": "$LINEAGE",
  "minds": [{ "name": "vega" }, { "name": "orion" }],
  "goal": "$GOAL"
}
JSON
  printf 'NL_LLM_KEY=%s\nNL_LLM_BASE_URL=%s\n' "$KEY" "$BASE_URL" > "$RUN/keys.env"
  echo "==> [$2 attach] start the APP (app_sim, pure publisher — consumes nothing)"
  "$PY" "$HERE/app_sim.py" --dir "$WORK" --hz 2 --minutes "$MIN" > "$RUN/app_sim.out" 2>&1 &
  local SIM=$!
  echo "==> [$2 attach] run the VEIL in LEARN mode (NL_APP_ATTACH=1, lineage=$LINEAGE)"
  "$VEIL" worker "$RUN" "$NEU" "$MODEL" > "$RUN/worker.log" 2>&1 || true
  kill "$SIM" 2>/dev/null || true
}

run_one run-1 first
echo "==> second attach: SAME lineage, fresh run dir — it should boot already knowing the app"
run_one run-2 second

echo
echo "FORENSICS under: $HERE/debug/$TS  (compare run-1 vs run-2 events.jsonl)"
