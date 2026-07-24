# nl-veil — worker constitution

One binary: `veil` — a Zig 0.16 hive-mind orchestration engine (server + CLI + desktop GUI in one
process). This file is the constitution for ANY AI worker in this tree. Read it first, then the tail
of `harness/LEDGER.md`. When prompted to "grow / fix / upgrade" with no specific task attached,
follow the growth loop in `.claude/skills/grow/SKILL.md` (`/grow`).

## Build & verify — the oracle

- Toolchain: Zig 0.16 at `%USERPROFILE%\zig-0.16.0\zig-x86_64-windows-0.16.0\zig.exe` (CI uses
  mlugg/setup-zig @ 0.16.0).
- ALWAYS pass `--cache-dir C:\zig-nlveil`. The repo lives under OneDrive and a repo-local
  `.zig-cache` goes stale against it: builds "succeed" while installing yesterday's exe. If a change
  ever seems ignored, grep the built BINARY for a string you just added; if it's absent, delete
  `C:\zig-nlveil` and rebuild.
- The oracle: `scripts\check.ps1` — local mirror of the CI `check` job. `-Scan` prints growth
  signals without building; `-Full` adds the slow default-GUI build (CI covers it otherwise).
  **No green, no done.** Gates, individually:
  1. `python scripts/gen-models-json.py --check` (models.yaml ↔ web/public/models.json sync)
  2. `zig build -Dapp=false --cache-dir C:\zig-nlveil` (server-only build)
  3. `zig build test --cache-dir C:\zig-nlveil` (full server suite via src/tests.zig)
  4. `cd desk; zig build test --cache-dir C:\zig-nlveil` (desk suite)
- check.ps1 installs to a throwaway prefix under `C:\zig-nlveil` — it must NEVER write `zig-out\`
  (a live veil.exe may hold that path open) and must never stop or start the app. `dev.ps1` is the
  only script that owns stop→rebuild→relaunch; use it when you actually need the app running.
- `web/public/*` is `@embedFile`'d into the binary — edits do nothing until a rebuild. Editing
  `models.yaml` requires regenerating the mirror: `python scripts/gen-models-json.py`.
- Tests are OPT-IN: Zig only collects `test` blocks from files referenced by `src/tests.zig`
  (and `desk/src/tests.zig`). A new module's tests silently do not run until registered there.
- Known local flakes: Windows Defender can break test-runner IPC (rerun, or run the newest cached
  test exe under `C:\zig-nlveil\o\...` directly with a timeout). The desk suite's final net test
  needs a live server on :8787 — until it's hermetic (ledger item), the earlier tests are the
  verdict when only that one hangs.

## Hard rules

- Grow by accretion. One increment per session, the smallest change that lands VERIFIED. Never gut
  or wholesale-rewrite a working file; never delete user assets (binaries, PNGs, data) to "clean up".
- A live desktop app may share this tree. Re-read any file immediately before editing it, and stage
  only files you changed.
- A red oracle is not automatically YOUR red. The owner (or a resident swarm) may be mid-feature in
  this tree: before fixing a compile error you didn't cause, check `git status` and file mtimes —
  a file modified minutes ago that you never touched is in-flight work. Report it, don't "fix" it.
- `src/worker/httpc.zig` ↔ `desk/src/httpc.zig` are byte-for-byte twins. Change one → mirror the
  other in the same commit (`check.ps1 -Scan` verifies).
- Version literals live in `build.zig.zon` AND `src/main.zig` (`VERSION`), and the release-notes
  path is pinned in `.github/workflows/release.yml`. Bump all or none.
- Never commit: `data/`, `neurons.db*`, secrets or API keys, or real test-subject material.
- Commit messages are plain and written as the repo owner — no AI attribution or co-author lines.
- Docs and commits describe mechanisms in this repo's own vocabulary — never by comparison to
  external products.
- Don't hardcode use-cases into engine behavior; behavior emerges from live signals
  (`harness/HORIZON.md`, Principles).

## Map

- `README.md` § "Project layout" is the component map. Every `.zig` file opens with a `//!` header —
  the per-module doc (`grep '^//!'` for a fast atlas).
- `src/worker/run.zig` — the swarm runtime (lanes, fitness, and the goal-declared acceptance rows
  `VERIFY:`/`SMOKE:`/`PROBE:`). `rsi.zig` — governor, playbook, curriculum, retrospective.
  `agi.zig` — goal origination and the persistent primary consciousness. `sched.zig` — self-healing
  schedules with an outcome ledger. `lineage.zig` — cross-run memory (opt-in via `lineage:` id).
  `tools.zig` — the tool surface (`set_directive`, `make_tool`, `propose_change`, ...).
- `src/gateway/http.zig` — HTTP API. `src/cli.zig` — the `veil` CLI. `desk/` — desktop package
  (own build.zig + tests.zig). `docs/` — the annotated-source case-file site; `docs/docs-src/`
  mirrors `src/` one .md per module — feed it when you add or rename modules.
- `harness/` — LEDGER.md (growth journal + open items, the cross-worker memory) and HORIZON.md
  (the long arc). `scripts/check.ps1` — the oracle.
