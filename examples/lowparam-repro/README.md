# lowparam-repro — reproduce & grade the weak-model build path

A small, deterministic harness for measuring how well the swarm's divide-and-conquer
build works on LOW-PARAMETER local models (e.g. `llama3.1:8b` via Ollama), and for
verifying the engine's adaptive responses: the `/api/show` capability probe, the
large-tool-call transport probe, the adaptive fence-writes flip, salvage recovery,
and write-time RAG grounding.

## Files

- `sim_tasktracker.facts` — a 10-fact corpus with precise interface conventions
  (`load_tasks(path)`, `save_tasks(path, tasks)`, `next_task_id(tasks)`,
  `TASKS_PATH`, `created_ts`, …). The goal below requires the built code to honor
  them, so "did RAG land?" is directly gradeable from the output files.
- `sim_analyze.py` — parses a run's `events.jsonl` into an act-tool distribution,
  per-mind breakdown, fitness trajectory, failure/edit/smoke samples, and the final
  `work/` tree.

## Run

```sh
python deploy.py "Build a small Python command-line task tracker. Files: store.py (load_tasks/save_tasks/next_task_id, TASKS_PATH constant), cli.py (argparse subcommands add/list/done), and test_store.py (pytest round-trip test using a temp dir). Follow the conventions in hive memory exactly." \
  --name lp_repro --minds 2 --minutes 7 \
  --model llama3.1:8b --provider ollama --offline \
  --corpus examples/lowparam-repro/sim_tasktracker.facts \
  --neuron-bin bin/neuron.exe --bin zig-out/bin/veil.exe --detach -y
```

## Grade

```sh
python examples/lowparam-repro/sim_analyze.py data/lp_repro
```

What to look for:

- `caps` event: probed `tools/thinking/ctx` from `/api/show` (no name heuristics).
- `tool_recover` ≈ 0 (transport probe fences a broken backend before round 1) —
  or ≤ 2 followed by a `fence_writes adaptive` flip.
- `salvage` events landing files; `salvage_reject` followed by `salvage_retry`
  (corrective feedback), not silence.
- No concatenated half-programs (`compile_fail` ≈ 0); the corpus identifiers
  (`load_tasks`, `save_tasks`, `next_task_id`, `TASKS_PATH`, `created_ts`)
  present in `data/lp_repro/work/*.py`.
- Fitness trajectory monotone (no 50→0 regression).
