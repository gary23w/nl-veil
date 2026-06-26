#!/usr/bin/env bash
# run_detect.sh — the DETECTION test (vs run_secops.sh's remediation test). A STEALTH implant is planted: a process
# named like a legit service, talking to a REAL known-bad C2 from the baked threat-intel, with NO suspicious flag.
# The host's own heuristics report NOMINAL / threat_score 0. The ONLY way to catch it is to cross-reference each
# outbound connection against the threat-intel in neuron-db. This pushes a weak model past remediation into triage.
#
#   ./examples/embedded/run_detect.sh [run_name] [minutes]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
TS="${1:-detect_$(date +%Y%m%d_%H%M%S)}"; MIN="${2:-5}"
MODEL="${VEIL_MODEL:-llama3.1:8b}"; PROVIDER="${VEIL_PROVIDER:-ollama}"
BASE_URL="${VEIL_BASE_URL:-http://localhost:11434/v1}"; KEY="${VEIL_KEY:-ollama}"
RUN="$HERE/debug/$TS"; WORK="$RUN/work"; mkdir -p "$WORK"

NEU="$ROOT/bin/neuron.exe"; [ -f "$ROOT/bin/neuron" ] && NEU="$ROOT/bin/neuron"
VEIL=""; for c in zig-out/bin/neuron-loops.exe zig-out/bin/neuron-loops zig-out/bin/veil.exe zig-out/bin/veil; do
  [ -f "$ROOT/$c" ] && VEIL="$ROOT/$c" && break; done
[ -n "$VEIL" ] || { echo "ERROR: engine binary not found — run 'zig build' first"; exit 1; }
PY="$(command -v python || command -v py)"

echo "==> bake the remediation playbook + the blue-team threat-intel into the Veil's memory"
sed 's/^/[src:corpus] /' "$HERE/host_system.facts" > "$RUN/corpus.facts"
cat "$HERE/threatintel.facts" >> "$RUN/corpus.facts"
NEURON_MAX_FACTS=1000000 "$NEU" --db "$RUN/mind.sqlite" --json import "$RUN/corpus.facts" --scope knowledge --dedup --flush 100000 >/dev/null

cat > "$RUN/swarm.json" <<JSON
{
  "swarm": "$TS", "provider": "$PROVIDER", "model": "$MODEL", "base_url": "$BASE_URL",
  "style": "auto", "mode": "continuous", "minutes": $MIN, "internet": false, "gap_assess": false, "breakout": false,
  "minds": [{ "name": "vega" }, { "name": "orion" }],
  "goal": "You are the resident SECURITY MONITOR for a host. The host's own heuristics MISS stealthy malware that hides behind legitimate process names and unflagged connections, so a NOMINAL/threat_score=0 reading does NOT mean clean. Each round: call host_status, then for EVERY open outbound connection cross-reference its IP against threat intelligence with recall_hive 'IP <address> known C2'. If an IP matches a known-bad indicator, the owning process is malicious even though it is unflagged: block_ip that address and kill_proc the owning process. Also heal any normally-flagged infections (remove_persistence the root cause, block_ip the C2, kill_proc the process). Do NOT write files and do NOT run_python — issue host_command. DEFENSIVE only."
}
JSON
printf 'NL_LLM_KEY=%s\nNL_LLM_BASE_URL=%s\n' "$KEY" "$BASE_URL" > "$RUN/keys.env"

echo "==> plant the STEALTH implant (unflagged; host reports NOMINAL) + start the machine"
"$PY" "$HERE/host_sim.py" --dir "$WORK" --inject "stealth@8" --auto-inject 0 --hz 2 --minutes "$MIN" > "$RUN/host_sim.out" 2>&1 &
SIM=$!
echo "==> run the VEIL against it"
"$VEIL" worker "$RUN" "$NEU" "$MODEL" > "$RUN/worker.log" 2>&1 || true
kill "$SIM" 2>/dev/null || true
echo "FORENSICS under: $RUN  (work/telemetry.json events.log commands.jsonl ; events.jsonl mind.sqlite)"
