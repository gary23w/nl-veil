#!/usr/bin/env bash
# run_secops.sh — the self-healing security experiment with FULL forensics in ONE place.
#
# Everything that happened — the MACHINE and the OPERATOR — lands under examples/embedded/debug/<run>/:
#   <run>/swarm.json events.jsonl control.jsonl worker.log .veil mind.sqlite   <- all the Veil run data
#   <run>/work/      telemetry.json events.log commands.jsonl MISSION.txt        <- the live machine (the sim bus)
#   <run>/work/debug/state.jsonl  audit.log                                      <- the booted-machine state log
# so you can replay exactly how the Veil watched, diagnosed, and healed the host.
#
#   ./examples/embedded/run_secops.sh [run_name] [minutes]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TS="${1:-secops_$(date +%Y%m%d_%H%M%S)}"
MIN="${2:-6}"
MODEL="${VEIL_MODEL:-llama3.1:8b}"
PROVIDER="${VEIL_PROVIDER:-ollama}"
BASE_URL="${VEIL_BASE_URL:-http://localhost:11434/v1}"
KEY="${VEIL_KEY:-ollama}"
RUN="$HERE/debug/$TS"
WORK="$RUN/work"
mkdir -p "$WORK"

NEU="$ROOT/bin/neuron.exe"; [ -f "$ROOT/bin/neuron" ] && NEU="$ROOT/bin/neuron"
VEIL=""
for c in zig-out/bin/neuron-loops.exe zig-out/bin/neuron-loops zig-out/bin/veil.exe zig-out/bin/veil; do
  [ -f "$ROOT/$c" ] && VEIL="$ROOT/$c" && break
done
[ -n "$VEIL" ] || { echo "ERROR: engine binary not found — run 'zig build' first"; exit 1; }
PY="$(command -v python || command -v py)"

echo "==> bake the host security playbook into the Veil's memory"
sed 's/^/[src:corpus] /' "$HERE/host_system.facts" > "$RUN/corpus.facts"
NEURON_MAX_FACTS=1000000 "$NEU" --db "$RUN/mind.sqlite" --json import "$RUN/corpus.facts" --scope knowledge --dedup --flush 100000 >/dev/null

cat > "$RUN/swarm.json" <<JSON
{
  "swarm": "$TS", "provider": "$PROVIDER", "model": "$MODEL", "base_url": "$BASE_URL",
  "style": "auto", "mode": "continuous", "minutes": $MIN, "internet": false, "gap_assess": false, "breakout": false,
  "minds": [{ "name": "vega" }, { "name": "orion" }],
  "goal": "You are the resident SECURITY MONITOR for a host. Each round you are shown the host's LIVE telemetry, and you can call host_status to read its current state. If the host is COMPROMISED, recall_hive the remediation playbook, then for EACH infection ISSUE the full remediation using host_command: host_command to remove_persistence the persistence unit (the ROOT CAUSE), host_command to block_ip the C2 address, and host_command to kill_proc the malicious process. Then call host_status again to verify threat_score is 0 and mode is NOMINAL. Do NOT write files about the fix and do NOT use run_python — ISSUE the commands with host_command. Keep watching every round; new infections will appear. DEFENSIVE only."
}
JSON
printf 'NL_LLM_KEY=%s\nNL_LLM_BASE_URL=%s\n' "$KEY" "$BASE_URL" > "$RUN/keys.env"

echo "==> start the MACHINE (host_sim) on the Veil's command bus"
"$PY" "$HERE/host_sim.py" --dir "$WORK" --inject "miner@20" --auto-inject 160 --hz 2 --minutes "$MIN" > "$RUN/host_sim.out" 2>&1 &
SIM=$!

echo "==> run the VEIL against it (everything logs under $RUN/)"
"$VEIL" worker "$RUN" "$NEU" "$MODEL" > "$RUN/worker.log" 2>&1 || true
kill "$SIM" 2>/dev/null || true

echo
echo "FULL FORENSICS under: $RUN"
echo "  the veil : $RUN/events.jsonl  mind.sqlite  .veil  worker.log"
echo "  the host : $RUN/work/telemetry.json  events.log  commands.jsonl"
echo "  the log  : $RUN/work/debug/state.jsonl  audit.log"
