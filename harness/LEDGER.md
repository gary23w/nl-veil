# Growth ledger

The shared memory of every worker who grows this app — human, external AI, resident swarm. Rules:
entries are APPEND-ONLY, newest at the bottom, numbered; the *Open items* section is the only part
edited in place (close yours, add what you discovered). If it isn't in the ledger, it didn't happen.
Sizing discipline: an item a session can't land verified gets split, not half-landed.

## Open items

| id  | pri | item |
|-----|-----|------|
| H19 | low | Revoked API keys never stop costing: `neuron forget` clears the value but leaves ~6 `k_`-prefixed scopes per key (plus ::var/::instr/::stance/::affect/::persona), and `warm()` spawns one `neuron export` per matching scope — startup cost grows with every key EVER created, not every live key. Correctness is fine (a revoked key stays rejected). |
| H20 | low | Model-id matching in the neuron ledger is lowercase-only ("coder"/"qwen"), so a capitalized vendor spelling silently falls to the default row (cheaper input, dearer output) — a real billing difference. Pinned as-is by tests because every shipped id is lowercase; revisit if a vendor changes case. |
| H14 | med | Stale security claim in user-facing strings: `desk/src/gitvc.zig`'s header and its in-code user message say the GitHub PAT is "sealed at rest" (DPAPI), and `desk/src/chat.zig` (~1476) says "seal the GitHub token" — but `desk/src/secrets.zig` stores plaintext on every OS by design (DPAPI is legacy unseal only). Either fix the strings to tell the truth or restore sealing — owner's security-posture call. (Also minor: key_vault's provider-charset error string says `a-z0-9-_` but the validator accepts A-Z too.) |
| H4  | med | Coverage frontier: 31 src + 8 desk modules carry no test blocks at all (control/fanout, deploy/service, pixelrag, ocr, gateway, admin, obs, browser...). Pick load-bearing ones first. (writer.zig done — 0004.) |
| H8  | med | Engine bench harness: no perf gate on the engine's own hot paths; "faster" is currently an unverifiable claim (Ring 1, HORIZON.md). |
| H10 | horizon | SELF lane: let `veil cast` target this repo with acceptance rows that run the real oracle, under a standing `lineage: nl-veil-self` id; retrospectives append here (Ring 2). |
| H11 | low | In-repo mock-LLM server: keyless runs only exercise the inline `provider="mock"` moment; live routing/trio behavior needs a stand-in server to test without external deps. |
| H12 | low | Marker debt: 23 TODO/FIXME/HACK/XXX across src + desk/src. |
| H13 | low | check.ps1 verdict anomaly, root-cause only: the `Confirm-Gate` guard (0003) makes the verdict immune and self-diagnosing, so this is now a forensic itch — if the magenta `[h13]` trace ever fires, its typed dump IS the repro; record it here. Also remember: background task runners may re-execute an exit-1 script, truncating its output file. |

## Entries

## 0001 — 2026-07-24 — plant the harness
- did: Seeded the growth harness, all new files, no app code touched: `CLAUDE.md` (constitution),
  `AGENTS.md` (pointer), `.claude/skills/grow/SKILL.md` (the /grow loop), `harness/HORIZON.md`
  (rings 0-2), this ledger, and `scripts/check.ps1` (oracle: CI-check mirror + `-Scan` signals;
  installs to a throwaway prefix, never touches zig-out or the running app).
- verified: `check.ps1 -Scan` runs clean and found real signals (H1, H3, H4). Full gates run
  honestly: catalog sync PASS; desk suite PASS; server build + src suite FAIL — both on
  `src/plug/plugins.zig:60` (`std.Thread.Mutex`, Zig 0.16 API) inside the owner's IN-FLIGHT plugin
  feature (untracked `src/plug/` + `vendor/lua/`, files minutes old), left strictly alone per the
  in-flight-work rule. On the pre-plug tree the src suite passed 320/320 via the standalone
  fallback. Verdict correctly reports NOT GREEN, exit 1.
- learned: (1) .ps1 must be pure ASCII — PS 5.1 reads BOM-less files as ANSI and an em-dash corrupts
  the parse. (2) `Start-Process -PassThru` needs `$null = $p.Handle` before exit or ExitCode stays
  null and gates misreport. (3) Zig test collection is TRANSITIVE from tests.zig — orphan detection
  needs BFS over resolved relative @imports (naive direct-list diff flagged 5 false orphans; truth
  is zero). (4) The httpc twin contract is identity BELOW the //! header, and it is genuinely broken
  right now (H1). (5) Defender kills the build-runner test IPC (`failed command: ...test.exe
  --listen=-`, no test named) while the same exe passes standalone — the oracle self-heals by
  rerunning the exact exe the runner named, and ONLY on that signature (a compile error must stay
  red; the newest-cached-exe shortcut would test yesterday's tree). (6) Pipeline output in a
  PowerShell function becomes its return value: an emitted error tail made failed gates truthy and
  the verdict lied ALL GREEN once — print via Write-Host in gate code, always.
- ratchet: check.ps1 grew all of the above (BFS reachability, twin body compare, module-root
  resolution via build.zig, signature-gated self-healing runner, truth-telling verdict); CLAUDE.md
  gained the "a red oracle is not automatically YOUR red" rule.
- next: H1 (twin reconcile, direction desk→src) once the in-flight plugin work lands.

## 0002 — 2026-07-24 — H1: mirror the httpc twins (ports the pool-freeze fix to the server)
- did: Replaced the body of `src/worker/httpc.zig` (below its `//!` header) with the desk twin's
  body, byte-exact. This was not cosmetic: the desk body carries the `rt_done` sliced-sleeper fix
  (losing race timers used to sleep the FULL timeout in a Threaded pool worker; enough residue hit
  the async_limit and degraded io.async to inline — the app-freeze bug) plus the defaulted
  `host: []const u8 = ""` field (remote-host resolve; empty keeps the 127.0.0.1 loopback default).
  The server package had neither. All 12 src callsites use anonymous `Req` literals without `host`,
  so their loopback-only behavior is unchanged (`config/local_models.zig`'s "loopback by
  construction" doc stays true). Also restored `CLAUDE.md` + `AGENTS.md`, which had VANISHED from
  the tree since morning (untracked, so unrecoverable from git) — if the owner deleted them
  deliberately, say so in the next entry and fold the constitution into harness/ instead.
- verified: Baseline at HEAD (412ef78) first: server build exit 0; src suite 333/333 standalone
  (runner IPC-flaked; the plug tests run — visible `[plug]` fixture warnings). After the mirror:
  `check.ps1 -Scan` = twins in sync, 0 actionable signals; full oracle ALL GREEN exit 0 (catalog,
  server build, src suite, desk suite — src runner flaked in the first execution and passed
  standalone, passed the runner directly in the second). Diff: 1 file, +40/−11.
- learned: The runner IPC flake is NONDETERMINISTIC (fired in one execution, not the next). One
  execution summarized NOT GREEN with all effective gates PASS — filed as H13 with repro notes,
  do not paper over it. The background task runner re-executes a script that exits 1 and truncates
  its output file (also H13). Twin files are both LF; compose mirrors by byte-offset concat
  (src header + desk body from `const std`) to keep the below-header contract byte-exact.
- ratchet: `check.ps1 -Scan` gained signal 0, an in-flight-work banner: dirty tracked files
  modified in the last 20 minutes are flagged as someone else's mid-feature edits ("their reds are
  not yours") — the morning's hard lesson, now mechanical.
- next: H13 (verdict anomaly repro) or H2 (hermetic desk tests) — both harden the oracle itself.

## 0003 — 2026-07-24 — H13: pollution-proof, self-diagnosing verdict
- did: The anomaly (NOT GREEN with all-PASS rows) would not reproduce in isolation, so the verdict
  is now immune to its suspected cause instead: `Confirm-Gate` in `scripts/check.ps1` judges each
  gate by the LAST Boolean it emitted (a PS function's return is EVERYTHING it emitted; returns
  come last, pollution precedes them), treats a no-Boolean result as red, and prints a magenta
  `[h13]` trace with the value types whenever a gate emits anything but one pure bool — the next
  occurrence diagnoses itself.
- verified: Unit-proofed all seven shapes (pure true/false, strings+true, strings+false, no bool,
  empty, false-then-true) — correct verdicts, anomalies traced. Full oracle with the guard live:
  ALL GREEN, exit 0.
- learned: The runner IPC flake is nondeterministic run-to-run. H13 stays open only for the
  root-cause repro; the verdict can no longer be flipped by it.
- ratchet: CLAUDE.md gained the oracle-honesty caveats — background task runners may silently
  re-execute an exit-nonzero script (masking the first verdict; exit code + check-logs are
  authoritative), and the `[h13]` trace must be captured in the ledger when seen.
- next: coverage on the grounding floor (worker/writer.zig) — its pure citation machinery is
  untested and it is the anti-fabrication boundary.

## 0004 — 2026-07-24 — H4 (first bite): grounding-floor tests + two real leak fixes
- did: `src/worker/writer.zig` — 4 test blocks over the pure anti-fabrication machinery (`urlEnd`
  delimiter/punctuation trimming; `buildNumberedSources` numbering/dedup and the core invariant
  that the model-visible text carries NO urls; `resolveCitations` [N] resolution, out-of-range
  drops, invented-link and bare-url stripping, wrapper-noise removal, cited/grounded counts).
  Writing them exposed two real leaks — both `appendSlice(gpa, allocPrint(...))` patterns copied
  the formatted string and never freed it (buildNumberedSources per source line, resolveCitations
  per citation) — fixed with capture + `defer free`. Registered in `src/tests.zig`.
- verified: Full oracle ALL GREEN, exit 0; src suite passed the runner directly (337 tests, was
  333). `std.testing.allocator` doubles as the leak proof: with the old code these tests would
  fail on leak detection.
- learned: Write new tests against `std.testing.allocator`, never an arena — the arena hides
  exactly the allocPrint-append leak class this found, and a leak a test finds is a leak
  production has.
- ratchet: folded into 0005 (same sitting).
- next: H5 (version bump script).

## 0005 — 2026-07-24 — H5: one-command version stamping
- did: `scripts/bump-version.ps1` — stamps build.zig.zon, src/main.zig VERSION, every
  bin/MANIFEST.txt occurrence, and the release.yml notes pointer, then creates the
  `docs/release/RELEASE-v<new>.md` stub; `-DryRun` previews; any missing stamp aborts loudly
  ("the stamp moved; fix this script").
- verified: DryRun on the live tree finds all 10 stamps (1+1+7+1). Same-version apply is
  byte-neutral on zon/main/MANIFEST (empty git diff — write path preserves encodings/endings);
  it advanced only the release.yml notes pointer, which exposed a real pre-existing skew: the
  pointer tracks the LAST PUBLISHED notes (v1.0.0-alpha.3) by design and only moves at bump time.
  Test residue reverted (yml checkout + stub deleted).
- learned: zon/main/MANIFEST agree at 1.0.0; the notes pointer deliberately lags — documented in
  the script header so a same-version re-apply surprises nobody.
- ratchet: `check.ps1 -Scan` version signal now also yellow-flags bin/MANIFEST.txt when it carries
  no current-version stamp (the notes pointer keeps its lag excuse; MANIFEST does not).
- next: H2 re-examination + H7.

## 0006 — 2026-07-24 — H2 closed by evidence; H7 stale entrypoint neutered
- did: Re-read the desk net test (`desk/src/netcli.zig` "round-trips in-process against a running
  server"): it early-returns without `../data/.desktop_key`, and since the bounded-httpc rework
  every call carries a hard timeout — the historical "hangs without a live server" premise is
  gone. H2 CLOSED as overtaken by events; noted behavior: when a server IS up, the test casts a
  1-minute mock swarm at it (deliberate — "the exact door the chat uses"). H7: `.codex/config.toml`
  (gitignored, local) pointed `[mcp_servers.nl-veil]` at the retired `deploy.py mcp` and no MCP
  serve mode exists in the veil binary — replaced with a comment saying exactly that and where to
  go instead. H7 CLOSED.
- verified: This session's desk gates passed bounded twice with no hang (ALL GREEN runs above).
  `.codex/` is gitignored so no oracle gate applies; content is comment-only TOML.
- learned: A ledger item's premise can rot while it waits — re-verify the complaint before
  building the fix. The desk suite does side-effect a running server with a mock cast; if that
  ever bites, make it opt-in via env var rather than deleting the coverage.
- ratchet: none beyond the scan MANIFEST check landed in 0005 this sitting.
- next: H3 (docs case files for the most load-bearing undocumented modules) or H9 (veil doctor
  --growth).

## 0007 — 2026-07-24 — H6: check.sh, the POSIX oracle twin
- did: `scripts/check.sh` — the same four gates as check.ps1 for POSIX/CI (plus `--full` and a
  `--scan` lite: twin bodies, version stamps, marker debt). Platform-aware: Git Bash uses the
  pinned Windows zig + the off-OneDrive cache; elsewhere zig comes from PATH. No Defender
  self-heal (a Windows-only phenomenon; use check.ps1 there).
- verified: Full run on this machine via Git Bash: scan-lite agrees with the ps1 (twins in sync,
  version 1.0.0), all four gates green, task exit code 0. Trust the EXIT CODE: the task output
  file demonstrably lags/rewrites in flush generations (a monitor read even stitched two
  generations into an impossible "ALL GREEN/NOT GREEN" adjacency mid-truncate).
- learned: (1) `zig build test` sometimes prints the runner-flake signature (`failed command:
  ...test.exe --listen=-`) and still exits 0 — zig self-resolves some flakes internally; both
  oracles now tolerate both outcomes. (2) The ps1 marker count (23) was inflated by Select-String's
  case-INSENSITIVE default vs grep's sensitive 11 — markers are an uppercase convention.
- ratchet: check.ps1 marker scan made case-sensitive for parity (true debt: 11).
- next: process the docs-truth audit (running) into grounded rewrites + a docs-debt open item.

## 0008 — 2026-07-24 — H3 (truth half): the docs mirror was 44% confabulated; restored + verified
- did: A full audit of the 50 module case files against their modules' `//!` headers and pub
  surfaces graded 22 CONFABULATED (machine-generated fabrications — invented Redis/JWT/Stripe/
  HNSW/cgroups/geocoding machinery; worst: rsi.md claimed the module patches its own source, the
  opposite of the engine's actual safety boundary) and 2 STALE, all server-side flat modules with
  terse headers. Three parallel rewriters re-grounded all 24 against the real code (caller-level
  evidence) and created the missing `desk/gitvc` case file; the docs.js manifest got 17 corrected
  titles + the DK-16 row (single-writer). An INDEPENDENT adversarial re-audit then tried to refute
  every rewrite: 26/27 survived number-level checks; the one refutation (gitvc.md repeating its
  own module's stale "PAT sealed at rest" header) was fixed, and it exposed a real product bug
  (H14). Footer sweeps: the 12 test-less modules no longer claim grounding "in tests"; the legacy
  "Documentation generated" footer is gone from all 23 survivors (0 remain).
- verified: Re-audit verdict 26/27 CLEAN with traps checked (constants, routes, caps, callers);
  `node --check` passes docs.js; all 59 manifest paths resolve 1:1; live render on :8077 — 59
  inventory entries, gitvc and rsi pages render grounded, zero old-claim residue; `git log`
  confirms no agent committed; scan: 0 actionable, docs-missing 43->42.
- learned: (1) Generated docs confabulate exactly where the source is terse — a rich `//!` header
  is the cheapest defense. (2) A rewriter grounding against a module can still inherit that
  module's OWN stale comments — code comments are claims too; ground security claims against the
  module that implements them. (3) The audit->rewrite->adversarial-re-audit cycle caught what a
  single pass would have shipped.
- ratchet: none new this sitting (three landed earlier today); the standing confabulation tell
  (the old footer) is now extinct, which retires that grep.
- next: H4 next bite (worker/commons — the message bus + task board is load-bearing and untested)
  or H9 (veil doctor --growth).

## 0009 — 2026-07-24 — H4 second bite: commons tests; three more leaks caught red-handed
- did: `src/worker/commons.zig` — 3 real-filesystem test blocks (bus delivery is to-me-or-broadcast
  and never one's own; limit keeps the newest; quotes/newlines survive the JSON round trip; board
  ids count prior adds, done closes open, and — the trap — a task TEXT quoting `"type":"add"`
  arrives jstr-escaped so the substring event-scan must count it once, not twice). Registered in
  tests.zig. The first oracle run FAILED with all 340 assertions passing: "3 tests leaked memory,
  11 errors were logged" — the 11 "errors" were DebugAllocator leak reports pointing into
  `sendMessage`/`addTask`/`completeTask`, the same inline `appendSlice(gpa, allocPrint(...))`
  class as writer's (0004). Fixed all three with capture + defer free.
- verified: Full oracle ALL GREEN, exit 0 (340 tests, 0 leaks, 0 logged errors).
- learned: The leak class is systemic, not incidental — every hand-rolled JSONL writer used the
  same idiom. Plain `.append()` of the allocPrint SLICE is ownership transfer and fine (inbox,
  agi's reader); only `appendSlice` copies-and-orphans.
- ratchet: `check.ps1 -Scan` signal 6 — flags every inline allocPrint(gpa)-into-appendSlice site
  repo-wide (10 remain: H15); tuned once against a false positive to exclude pointer-transfer
  `.append()`.
- next: H15 — sweep the 10 remaining sites (mechanical), then the class should read zero forever.

## 0010 — 2026-07-24 — H15: the allocPrint-append leak class, extinct
- did: Fixed all 10 remaining sites — agi.zig:305 (veil-chat line head), run.zig:7499/9068/9138
  (context-body header, project-tree header, underlength-doc entries), tools.zig:2175/2464/2625/
  5904 (manifest/round-write lines) with capture + defer free preserving each site's failure
  semantics; tools.zig:4226 (%XX query-encode) and :4302 (numeric history lines) converted to
  stack `bufPrint` — tiny fixed-size formats never needed the heap at all.
- verified: `check.ps1 -Scan`: "[leaks] no inline allocPrint(gpa)-into-append sites", 0 actionable
  signals. Full oracle ALL GREEN, exit 0 (340 tests, no leaks, no logged errors).
- learned: The class was 16 textual matches, 13 real (writer 2 + commons 3 + these 10 — arena/ta
  variants and pointer-transfer `.append()` are fine). Every hand-rolled JSONL/manifest writer had
  independently invented the same bleed; the scan signal is what keeps it at zero.
- ratchet: signal 6 already landed in 0009; no additional notch this sitting.
- next: H9 — `veil doctor --growth` (Ring 1: fold the runtime ledgers into worker-readable app
  health) or H3 next batch (cli/, config/, plug/ case files).

## 0011 — 2026-07-24 — H9: veil doctor --growth (Ring 1 opens)
- did: `src/cli.zig` — `doctor` takes `--growth`: three sections read straight from {data} (works
  with the server down): the engine's LEARNED tool digest (reuses toolperf.digest — no reparsing),
  schedule fail-streaks off each task file's outcome ledger, and a per-model rollup of
  u*/_metrics/llm.jsonl (turn-rows, calls, tokens, avg ms). cmdDoctor restructured (flag parse +
  single exit path); help text updated.
- verified: Compiled first try; live run against the real data dir surfaced real health the engine
  had learned but nobody could see: recall fails ~73%, mcp_discover ~60%, poll averages ~148s;
  deepseek-v4-flash at 257 turn-rows / 36.9M input tokens / 24s avg. Empty-data paths degrade
  gracefully (fresh dir prints three clean "nothing yet" lines). Full oracle ALL GREEN, exit 0.
- learned: data-dir resolution is exe-adjacent for a bare binary — NEURON_LOOPS_DATA points the
  doctor at a real data dir when running from a throwaway prefix. The growth report is the SENSE
  step's runtime half: scan reads the tree, doctor --growth reads the lived experience.
- ratchet: SKILL.md's SENSE step should name `veil doctor --growth` alongside `-Scan` — landing
  with this entry.
- next: H3 next batch (cli/, config/, plug/ case files) or H4 next bite; H14 awaits the owner's
  security-posture call.

## 0012 — 2026-07-24 — H4 third bite: the audit chain gets teeth (and loses an injection)
- did: `src/obs/audit_log.zig` — record() wrote fields into its JSON line UNESCAPED: one `"` in an
  actor/action/target made that line unparseable and verify() reported the whole log corrupt
  (an attacker-influencable target string could DoS auditability). Added `jesc` (quote/backslash/
  newline/tab escaped; other control bytes \u-escaped, never dropped — the hash preimage is the
  RAW bytes, so verify() must recover them exactly). Three test blocks pin the contract: chain
  verifies and RECOVERY resumes it across a restart; hostile field bytes round-trip; and a flipped
  byte, a deleted middle entry, and a garbage line are each detected as their distinct error.
  Registered in tests.zig.
- verified: Full oracle ALL GREEN, exit 0, src suite first-try (343 tests).
- learned: chain()'s preimage bufPrint caps at 320 bytes and falls to "" beyond it — fields longer
  than ~300 bytes weaken the binding (verify stays consistent, so no false alarms; noted, not
  fixed — callers pass short ids today).
- ratchet: lands with 0013 (same sitting).
- next: fold the 41-file docs batch (writers running) and wrap: commit + push per the owner.

## 0013 — 2026-07-24 — H3 CLOSED: the docs mirror is complete, 100/100 grounded
- did: Three parallel writers created the 41 missing case files (cli x4, config x4, plug x3,
  worker-flat x14, browser x7, chat x5, mcp x2, desk x2), each grounded in the module's header,
  pub surface, and tests, with the footer-honesty rule enforced up front (a tests claim only when
  test blocks exist). Manifest grew four new groups (CLI, PLUG, WORKER-BROWSER, WORKER-MCP) and
  extensions to CONFIG/CHAT/WORKER/DESK — 100 entries. `trio_routing_test.zig` deliberately
  excluded (a test harness, not a module) and the scan now skips `*_test.zig`.
- verified: Independent grep-level adversarial check: 41/41 CLEAN — every claimed export exists,
  footers match test reality bidirectionally (the 14 no-tests modules are exactly the 14
  no-tests-claimed footers), zero invented-technology keywords, all multi-digit numbers matched to
  source literals. Site renders 100 sheets, all paths resolving. `check.ps1 -Scan`:
  "[docs] docs-src mirror complete", 0 actionable signals.
- learned: Stating the footer-honesty rule in the writing prompt (instead of sweeping after)
  produced exact bidirectional compliance — encode audit findings into the next generation's
  instructions and the defect class never recurs.
- ratchet: scan's docs signal skips `*_test.zig`; the site's sheet counter is the coverage proof
  (SHEET n OF 100).
- next: the coverage frontier is the standing lane (28 src + 8 desk modules without tests);
  H10 (SELF lane) is the horizon; H14 still awaits the owner's security-posture call.

## 0014 — 2026-07-24 — the events-poll cursor: lockstep made structural
- did: `control/fanout.zig` swarmEvents and `chat/service.zig` convEvents are twins — same probe
  sentinel, same 512KiB page cap, same cursor arithmetic — kept in step by a "change one, change
  the other" COMMENT, with the logic written out twice. Extracted to `src/worker/evcursor.zig`
  (`PROBE`, `PAGE_MAX`, `parseFrom`, `isProbe`, `want`, `nextOffset`): std-only, no io, no httpz,
  so the contract is directly testable. Both handlers now call it; behavior preserved exactly
  (`want > 0` is equivalent to the old `size > from`, since a positive delta always yields >= 1).
  6 test blocks: junk/overflow cursors degrade to 0, the probe sentinel round-trips through the
  query string a client actually sends, the page cap bounds a burst, a short read advances only by
  what arrived, and a catch-up walk over a 1.5MB file converges in 4 polls delivering every byte
  exactly once. Case file + manifest row (CT-06) added.
- verified: Full oracle ALL GREEN, exit 0 (4/4 gates). docs.js `node --check` clean, 101 manifest
  entries, 0 unresolved paths.
- learned: `want()` returns 0 when size <= from, so a SHRUNKEN events file parks a polling client
  past EOF — the SSE loop facing the same file rewinds instead. events.jsonl only grows today, so
  it is latent; pinned by a test and documented so it stays a decision. Also: PROBE is typed usize
  = maxInt(u64), which pins the project to 64-bit targets (every shipped target is).
- ratchet: the docs-mirror signal did its job — adding a module immediately made the mirror
  incomplete, and the case file landed inside the same increment.
- next: the privilege boundary is the biggest untested surface (entitlements, neurons ledger,
  api_keys, login_guard, the control bus) — fanning out test writers.

## 0015 — 2026-07-24 — the privilege boundary gets tests; a billing overflow panic found and fixed
- did: Three parallel test writers took the untested security surface: `plan/entitlements` (4) and
  `plan/neurons` (15), `auth/api_keys` (6) and `auth/login_guard` (5), `worker/control/writer` (3)
  and `worker/browser/util` (5) — 38 tests, each pinning the module's REAL constants. Registered
  the five unreachable modules in tests.zig (browser/util was already reachable via manager).
  One justified non-test extraction: `controlLine` pulled verbatim out of `swarmControl` so the
  wire format is testable without an HTTP harness (same move as evcursor in 0014).
  REAL BUG FIXED — `plan/neurons.status()` overflowed: `addTopup`/`charge` write saturating (`+|`)
  so topup/used can legitimately reach maxInt(u64), but status() summed with a plain `+` and
  `@intCast`ed to i64 — a panic inside an httpz handler in Debug, UB and a silently wrong balance
  in the shipped ReleaseFast build, reachable from `POST /admin/billing`, which parses `topup` as
  a raw u64 from the body and passes it unclamped. Fix: `+|` plus `std.math.cast(...) orelse
  maxInt(i64)` on both sides.
- verified: per-lane green during the run; the whole tree verified together in 0016 below.
- learned: (1) `std.Io.Threaded.init(gpa, .{})` hands spawned children an EMPTY environment — under
  `zig build test` the neuron binary came up with no TEMP/SystemRoot, its writes silently failed
  into a `catch {}`, and the ledger read as permanently empty. Pass `.environ = .{ .block =
  .global }` (as worker/tools.zig:6246 already does) for any test that spawns a real subprocess.
  (2) The control-bus escaping is load-bearing SECURITY, not tidiness: a steer text carrying
  `}\n{"op":"stop"}` must stay one `say` op — proven counterfactually, a naive writer turns it
  into three lines and the worker honors the injected stop.
- ratchet: CI now runs `sh scripts/check.sh --full` instead of re-spelling the gates in YAML — one
  definition of done for CI and both local oracles, so they cannot drift.
- next: H16 (the duplicated billing rate table) is the sharpest remaining item — two sources of
  truth for what a user is charged.

## 0016 — 2026-07-24 — H16 CLOSED: the billing copies can no longer drift
- did: The token→neuron rate table exists twice — `plan/neurons.zig` neuronsForModel (the control
  plane charges) and `run.zig` neuronsForCfModel (the worker reports). Reading the code first paid
  off: the duplication is DELIBERATE and documented ("kept INLINE so the worker stays decoupled
  from the control-plane billing module"), so collapsing it would have broken a real boundary.
  Kept the boundary, killed the drift instead: a test in run.zig with the `@import` INSIDE the
  test block (nothing coupled outside the test binary) asserts the two agree on all four rate rows
  plus their capitalized spellings, the empty/unknown default, a combined call that pins
  independent flooring, and maxInt saturation. A rate edited in one copy now fails the build.
- verified: covered by the same final oracle as 0015 (below/at commit time) — ALL GREEN.
- learned: "duplicated code" is not automatically a defect to collapse. Read the WHY first: here
  the copy is an architectural boundary, and the right fix was a test-only bridge rather than a
  production import. Same shape as evcursor (0014) but the opposite conclusion about merging.
- ratchet: the pattern itself — a test-block-local `@import` is how this repo can pin agreement
  between deliberately decoupled copies without linking them.
- next: H17-H20 (unbounded IP map, latent list/revoke UAF, revoked-key startup cost, lowercase-only
  model matching); H10 SELF lane on the horizon; H14 still the owner's call.

## 0017 — 2026-07-24 — H17 + H18: the login guard stops hoarding, the key list stops lending
- did: H17 — `LoginGuard.by_ip` only ever shrank via success(), so every address that ever mistyped
  a password kept a heap key forever (internet background noise alone grows it; a distributed
  guesser spreading attempts thin enough never to trip a lock grows it faster). Added `sweepLocked`:
  drops records whose window has passed AND whose lock has expired — provably invisible, since such
  a record carries no state a verdict could use. Runs on a WINDOW_SECS cadence, plus immediately
  past 4096 entries, and the size trigger is rate-limited to once a second so a flood holding the
  map at the threshold with LIVE records can't make every failed login pay an O(n) sweep — the
  defence becoming its own amplifier. Also promoted the test-only drain helper to a real `deinit`.
  H18 — `ApiKeys.list()` returned Views whose id, prefix AND name all borrowed map memory that
  revoke() frees; now duped into the caller's allocator, with the ownership contract documented on
  the function and a test that reads a view AFTER revoking its key.
- verified: TWO self-inflicted reds before green, both in the new test, neither in the fix. (1) I
  stamped records with a synthetic `t = 1_000_000` while `allowed()` reads the REAL clock, so a
  "still locked" record sat ~1.7 billion seconds in the past — anchored `t` to the real clock with
  drift-safe margins (lock at t+3600, expiry exactly at t). (2) I asserted 3 survivors when the
  scenario retires 2 of 4 — a leftover from an earlier draft's shape. Third run ALL GREEN.
- learned: a test that moves stored timestamps must anchor them to the same clock the code under
  test reads — synthetic time is only safe for functions that TAKE the time as a parameter
  (sweepLocked does; allowed() does not). Also: when a test's SHAPE changes (3 addresses + a
  trigger became 4 addresses + a direct call), re-derive every count in it rather than carrying
  the old numbers forward — the oracle caught both, which is the system working, not failing.
- ratchet: the eviction predicate is stated as a property in the test name ("retires only records
  the throttle would never act on again") rather than as a threshold, so a future tuning change
  has to restate the invariant instead of silently widening it.
- next: H19/H20 are low; the honest next lane is either H10 (SELF cast) or more coverage.

## 0018 — 2026-07-24 — both ends of the events pipeline now hold their contract
- did: `gateway/http.zig` was untested despite holding the two primitives everything else builds
  on. Added 4 test blocks: `jstr` escapes exactly what JSON requires (control bytes to \u, never
  dropped, >=0x20 passing through raw); hostile inputs — `","op":"stop","x":"`, `}\n{"op":"stop"}`,
  a NUL, embedded CRLF+`{"seq":999}` — round-trip through a REAL parser byte-for-byte with a
  trailing field intact and no bare newline in the escaped form, so a user string cannot forge
  structure in any of the hand-rolled JSON lines (control bus, audit log, event logs);
  `appendFile` creates at offset 0, concatenates in order, and NEVER shrinks; `appendStripe` maps
  a path to a stable lock and actually spreads across the array.
- verified: Full oracle ALL GREEN, exit 0, first try.
- learned: the appendFile test states the exact property `worker/evcursor.zig` documents as its
  assumption ("the file only grows, so `from` stays valid"). The writer that guarantees monotonic
  growth and the reader that depends on it are now pinned from both ends — the events pipeline's
  contract is no longer an unwritten agreement between two modules.
- ratchet: proving escaping by ROUND-TRIPPING through std.json (rather than string-comparing the
  escaped form) is the pattern to copy — it tests the property that matters (no forged structure)
  instead of one particular spelling of the escape.
- next: coverage frontier continues (deploy/service's unknown-plan coercion, chat/tools); H10 SELF
  lane remains the horizon; H14 is the owner's call.
