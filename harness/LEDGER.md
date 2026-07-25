# Growth ledger

The shared memory of every worker who grows this app — human, external AI, resident swarm. Rules:
entries are APPEND-ONLY, newest at the bottom, numbered; the *Open items* section is the only part
edited in place (close yours, add what you discovered). If it isn't in the ledger, it didn't happen.
Sizing discipline: an item a session can't land verified gets split, not half-landed.

## Open items

| id  | pri | item |
|-----|-----|------|
| H28 | low | OWNER'S CALL — product copy, deliberately NOT changed by me (0054). `POST /billing/checkout` presents `workers_ai` as part of what upgrading to Pro gets you, but `entitlements()` grants `workers_ai = true` on EVERY tier including free — entitlements.zig's own test says so outright: this flag "is NOT what keeps a free user off hosted inference. What meters them is the neuron ledger." The one flag a paid plan actually turns on is `cloudflare_deploy`. So the pitch lists a capability the reader already has, and the `note` string ("hosted Workers AI inference (no BYOK)") leans on it. This is now factually accurate to the code (0054 made the field read from the pro row), so nothing is LYING — the question is whether advertising a non-differentiator is what you want, and that is a copy decision, not a defect I should quietly rewrite. |
| H26 | med | OWNER'S CALL — capability inconsistency: `pixel_search` is in `chat/tools.zig`'s ADMIN_TOOLS (so the one-shot `/chat/tool` endpoint answers a non-admin 403) AND in the engine's `SANDBOX_TOOLS` (so the SAME user's sandboxed chat turn may run it). Not a hole — the endpoint takes the stricter reading — but the two surfaces are documented as sharing one registry, and `toolSafe` explicitly "delegates to the ENGINE'S sandbox predicate so the two surfaces cannot drift". Pick one: `pixel_search` only reads already-ingested tiles (so arguably sandbox-safe, and it should leave ADMIN_TOOLS), whereas `pixel_capture`/`pixel_ingest` touch the host screen and are rightly admin-only. Pinned by `KNOWN_CAP_OVERLAP` in chat/tools.zig — a NEW overlap fails the build, and so does fixing this one without updating that list. |
| H19-DONE | closed 0042 | Revoked API keys never stop costing: `neuron forget` clears the value but leaves ~6 `k_`-prefixed scopes per key (plus ::var/::instr/::stance/::affect/::persona), and `warm()` spawns one `neuron export` per matching scope — startup cost grows with every key EVER created, not every live key. Correctness is fine (a revoked key stays rejected). |
| H14b | OWNER | The STRINGS now tell the truth (0048), which was the part that could be fixed without a decision. The decision itself is still open: leave the GitHub PAT plaintext-local (current, defensible for a local login-gated app) or restore sealing at rest (`secrets.zig` says "we never seal again" — a deliberate past choice, and DPAPI is Windows-only so it would not be uniform). Nothing is lying to a user in the meantime. |
| H14-OLD | done 0048 | Stale security claim in user-facing strings: `desk/src/gitvc.zig`'s header and its in-code user message say the GitHub PAT is "sealed at rest" (DPAPI), and `desk/src/chat.zig` (~1476) says "seal the GitHub token" — but `desk/src/secrets.zig` stores plaintext on every OS by design (DPAPI is legacy unseal only). Either fix the strings to tell the truth or restore sealing — owner's security-posture call. (Also minor: key_vault's provider-charset error string says `a-z0-9-_` but the validator accepts A-Z too.) |
| H4  | low | Coverage frontier, RECOUNTED 0053 — the old row said "31 src + 8 desk" and was ~25 modules stale; an open-items row that lies is exactly the drift this harness exists to catch, so recount before trusting any row here. Now **5 src + 2 desk**: `cli/chat`, `cli/exec_tool`, `browser/{broker,host,session}`, `desk/{main,tray}` (`plan/billing_seam` covered 0054). Read 0044 before accepting "device-bound" as the reason: four modules carrying that label turned out to be mostly testable, and one hid a real invalid-free bug. `plan/billing_seam` is the odd one out and the one to take first — neither device- nor UI-bound, and it is money. |
| H8  | med | Engine bench harness: no perf gate on the engine's own hot paths; "faster" is currently an unverifiable claim (Ring 1, HORIZON.md). PATTERN SET 0053: count, never time — `Neuron.exec` carries an `is_test`-gated `spawn_probe` and `client.zig` pins reading N records at exactly N+1 spawns. A wall-clock budget on a dev box measures Defender and gets muted. Engine hot paths still unpriced; find each one's choke point first. |
| H10 | OWNER | SELF lane (Ring 2). DESIGNED, NOT WIRED — see `harness/SELF-LANE.md` for the safety floor (oracle + harness + tests.zig out of reach of a self cast; branch-only, never main; green necessary not sufficient; one increment per cast; ledger append-only for the swarm too; dry-run first). Switching it on is the owner's call and I will not infer it: an agent that can edit its own acceptance criteria has none. |
| H11-DONE | closed 0060 | In-repo stand-in gateway now exists at `src/worker/fakehttp.zig` — and it mostly already did: `config/local_models.zig` had a well-built canned loopback server, private and named for one caller, so nobody could reach it. Shared rather than re-built (a second copy is what 0055 spent an entry undoing), and `llm.chat()` is now driven through the REAL path against it: loopback plain-http skips the curl child, so `httpc.request` dials the fake in-process and `completeBody` parses a genuine provider-shaped response. NEXT if wanted: the server drains and discards the request, so nothing yet asserts the REQUEST body (trio routing per role, the tools array, temperature quirks) — capturing it is the natural extension and would let the trio-routing claims be checked end to end rather than by source audit. |
| H12-DONE | closed 0059 | Marker debt was never 23, and is not 12 either — it is effectively ZERO. Both oracles' `[markers]` signal matched `XXX` unbounded, so ten `\uXXXX` doc-comment mentions (JSON escape notation) counted as debt; word-bounding drops the class. The 2 that remain are the same comment mirrored in the httpc twins, describing a TODO in **Zig's own stdlib** (`netConnectIpWindows`), not ours. Nothing to pay down. The real defect was the signal: one that always reports phantom work is one a worker learns to skip, which costs more than the debt would have. |
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

## 0019 — 2026-07-24 — the test lore stops living in my head
- did: Wrote `harness/TESTING.md` — the house test patterns, every rule tagged with the ledger
  entry that paid for it: register/reachability, testing.allocator (a leak is a bug; 13 real ones
  found), never an arena to make a leak pass, the temp-dir pattern, `.environ = .{ .block =
  .global }` for subprocess tests, skip honestly when a dependency is absent, never sleep for
  expiry (and anchor synthetic stamps to the clock the code actually reads), prove escaping by
  round-tripping through a real parser, check the counterfactual, and the test-block-local
  `@import` for deliberately duplicated code. Linked from CLAUDE.md and the /grow skill's CHANGE
  step, with the instruction to paste it into any agent delegated test work.
- verified: docs + instructions only, no compiled code touched — `check.ps1 -Scan` clean, 0
  actionable signals (last full oracle green at 0018, tree unchanged since apart from markdown).
- learned: I hand-wrote these same patterns into three agent prompts this session, and the two
  reds in 0017 were both violations of rules I already knew. Lore that lives only in the driver's
  head gets re-derived (or re-broken) by every worker who follows. Coverage frontier is down from
  31 untested src modules to 21 across this session.
- ratchet: this entry IS the ratchet — the harness now teaches its own test conventions instead of
  depending on whoever is driving.
- next: coverage frontier (deploy/service, chat/tools); H10 SELF lane; H14 the owner's call.

## 0020 — 2026-07-24 — the MCP demultiplexer, and an escaping landmine one line from the cure
- did: `worker/mcp/client.zig` — 5 test blocks over `recvResult`, the JSON-RPC demultiplexer that
  reads a FOREIGN process's stdout (so every case is one a live server can produce): it returns the
  reply whose id matches, walks past log chatter, id-less notifications, another in-flight call's
  reply and a string-typed id, and maps a JSON-RPC error, a closed stream and an empty stream to
  null rather than to a result. The one that matters: never hand back id 6's payload when asked for
  id 7 — silent cross-talk between tools. Built on `Io.Reader.fixed`, the same idiom httpc's tests
  use. Fixed a latent bug the test exposed: `errJson` interpolated its message raw into
  `"error":"{s}"`, so a quoted binary name or a Windows path (`C:\Users` is an invalid JSON escape)
  produced unparseable JSON — in a value handed to the model as a tool result. Now stringified via
  `std.json.Stringify.valueAlloc`, the idiom the same file already used 13 lines below for the tool
  name. Not reachable today (every caller passes a literal), which is exactly when it is cheap.
- verified: Full oracle ALL GREEN, exit 0, first try.
- learned: the cure was already in the file — the module safely stringified the tool NAME while
  interpolating the error MESSAGE raw. When a file has both a safe and an unsafe idiom for the
  same job, the unsafe one is a bug waiting for its first dynamic input; grep a module for its own
  good pattern before writing a new one.
- ratchet: `harness/TESTING.md` (0019) was handed to the vault agent as a three-line pointer
  instead of a dictated prompt — the lore is now the repo's, not the driver's.
- next: fold the key-vault lane when it reports; coverage frontier continues.

## 0021 — 2026-07-24 — one plan spelling table; a typo can no longer downgrade a customer
- did: The plan-name coercion `if eql("max") .max else if eql("pro") .pro else .free` was written
  out twice — in `deploy/service.zig` adminBilling (ADMIN INPUT) and in `auth_core.zig` when
  loading a stored user row. In the admin path it meant `POST /admin/billing {"plan":"Pro"}`
  answered ok while quietly putting a paying customer on free, with no signal to the admin. Added
  `ent.parsePlan` (trims, case-insensitive, null for unknown) next to `Plan`, and split the two
  callers' intents explicitly: the admin endpoint now REJECTS an unknown name with a 400, while
  the storage path keeps its deliberate fall-back to least privilege on a corrupt row. Both now
  share one spelling table. The test is exhaustive over the enum, so a future tier that gets no
  spelling fails the build rather than becoming unreachable through the API.
- verified: first run RED — I added `const std = @import("std")` at the top of entitlements.zig
  without noticing the file already declares it below its prose block (Zig top-level decls are
  order-independent, so the existing one was already in scope). Removed mine; second run ALL
  GREEN, exit 0.
- learned: BEHAVIOR CHANGE worth flagging to the owner — an admin call that previously "succeeded"
  with a mistyped plan now returns 400. That is the point (silence was the bug), but it is a
  visible API change, not just an internal fix.
- ratchet: none this sitting; 0019's TESTING.md carried the load (the exhaustive-over-the-enum
  pattern came straight from it).
- next: fold the key-vault lane; then the frontier is mostly HTTP handlers needing a request
  harness, so the honest next lane may be H10 (SELF) rather than more unit tests.

## 0022 — 2026-07-24 — the vault's at-rest key could be undefined stack memory
- did: 14 tests on `config/key_vault.zig` (10 pure, 4 against a throwaway neuron-db) — seal/open
  round-trips for empty/1-byte/3000-byte/full-binary payloads with the blob length leaking nothing
  but size; a wrong key and all 32 one-bit-off near misses failing closed; a bit flipped at EVERY
  offset of the blob rejected; a fresh nonce per seal; the blob surviving the store's line-oriented
  pipe; scopeKey injectivity across uids x providers; validProvider's path-traversal boundary; and
  cleanValue as the JSON boundary WITH the counterfactual (an unescaped quote parses cleanly as a
  different record and sets a field the caller never supplied). Live: write-only at rest, per-user
  isolation, rotation/revocation beating the TTL cache, OAuth bundles.
  REAL BUG FIXED — `deriveServerKey` gated the on-disk path on
  `dec.decode(...) != error.InvalidPadding`. `calcSizeForSlice` only measures length and padding,
  never the alphabet, so a `.server.key` with the right length but one out-of-alphabet character
  sizes as 32, decode fails with InvalidCharacter, and `!= error.InvalidPadding` read that as
  SUCCESS — returning `var key: [32]u8 = undefined` that the decoder had never written. The
  server's AES-256 at-rest key became undefined stack memory: no guaranteed entropy, never
  persisted, different on the next call, so every secret sealed during that boot was permanently
  unopenable after a restart. Now gated on the decode succeeding; an undecodable file falls
  through to regenerate-and-persist. Also added `KeyVault.deinit` per TESTING.md.
- verified: agent ran green (410 tests standalone); confirmed independently by a full oracle here.
- learned: `!= error.SomeSpecificError` is a trap wherever a function can fail more than one way —
  it reads as "success" for every OTHER error. The counterfactual is what proved it: restoring the
  old spelling made the new test fail with the corrupt file still on disk.
- ratchet: the agent needed only a three-line pointer to `harness/TESTING.md` and produced the
  house patterns unprompted (skip-honestly, counterfactual, deinit-not-drain-helper, exhaustive
  boundaries) — 0019 paying for itself one lane later.
- next: H22/H23 from this lane; H21 (handler harness) is now scoped; H10 SELF remains the horizon.

## 0023 — 2026-07-24 — H22: the vault stops accepting keys it can never read back
- did: `cleanValue` guarded quotes, backslashes and control bytes — everything that would break OUT
  of the JSON string — but not UTF-8 validity, while `resolve()` reads the record back through
  `std.json`, which refuses invalid UTF-8 outright. So a pasted key with one stray high byte was
  accepted, sealed, stored and answered 201 Created, and then every read of it failed forever,
  with the miss cached as "no key here" — the user sees "key saved" and the app insists there is
  no key. Now `std.unicode.utf8ValidateSlice` is part of the check, and keys_api's 400 message
  says so. Test covers a lone continuation byte, truncated 2- and 3-byte sequences, a raw 0xFF and
  a stray high byte mid-key, each with the COUNTERFACTUAL that the record it would have produced
  fails to parse with SyntaxError; ASCII and real multi-byte UTF-8 (accents, 日本語, an emoji) stay
  accepted.
- verified: Full oracle ALL GREEN, exit 0, first try.
- learned: a validator has to admit exactly what its READER can recover. This one was written
  against the JSON *writer* (what breaks the string) and never re-checked against the parser, so
  the gap sat between two correct-looking halves.
- ratchet: none this sitting.
- next: H21 (App test-constructor) is the last big unlock; desk package coverage in parallel.

## 0024 — 2026-07-24 — H21 CLOSED: handlers are testable, and it cost 60 lines
- did: `http.testApp(gpa, io, root)` builds a fully-wired `App` over a throwaway data dir and
  `TestApp.deinit` tears it down. The scoping in H21 assumed this was expensive; reading the code
  first showed every subsystem's `init` is pure bookkeeping — none touch the disk or spawn anything
  until first use, and the neuron-backed ones fail open when the binary is absent, so the whole
  harness is ~60 lines with no stubs, no interfaces and no narrowing of handler signatures.
  Heap-allocated on purpose: `App` holds pointers INTO the struct, so it must not move. Paired
  with `httpz.testing.init(.{})`, which was in vendor all along. First test covers the widest
  security surface in the server — `requireUser` REFUSES rather than admits: no credential, a
  cookie naming no session, a bearer key while the key store is not even wired (the arm that
  cannot check must not admit), and `requireAdmin` being strictly narrower.
- verified: Full oracle ALL GREEN, exit 0, first try.
- learned: the estimate was wrong in the cheap direction, and only reading the constructors showed
  it. "This needs a big harness" deserves the same five minutes of reading as "this is duplicated
  code deserves collapsing" (0016) — both scopings were decided by what the code actually does,
  not by what the shape suggested.
- ratchet: `harness/TESTING.md` gained a Handlers section pointing at testApp, so the next worker
  reaches for it instead of extracting yet another pure helper; H21 is retired and replaced by H24,
  which names the six modules it unlocks.
- next: H24 (handler coverage) and the desk lane; H10 SELF remains the horizon.

## 0025 — 2026-07-24 — first handlers under test: every vault route is gated
- did: `config/keys_api.zig` — the module the key-vault lane had to report as untestable ("all
  three handlers take httpz Request/Response and go through requireUser… there is no httpz.testing
  harness anywhere in this repo") — now has one. Each of putKey/listKeys/delKey is called
  anonymously with a body and params good enough that ONLY the auth gate can be what rejects it,
  so an edit that ever moves `requireUser` below the work surfaces here rather than in production;
  plus an assertion that nothing reached the store.
- verified: Full oracle ALL GREEN, exit 0, first try.
- learned: the value of the harness showed up immediately as a REPORT being overturned — an
  "untestable" finding from one lane became a tested module one lane later, because the blocker was
  missing tooling rather than an untestable design. Worth re-reading old "can't be tested" notes
  after any tooling change.
- ratchet: none new; 0024's harness and TESTING.md section carried it.
- next: H25 (Auth.deinit) is the gate on everything else — authenticated handler tests leak until
  it exists.

## 0026 — 2026-07-24 — H25: Auth.deinit, and the whole authenticated path opens
- did: `Auth.deinit` frees both maps and everything they own, wired into `TestApp.deinit`. The trap
  it had to respect: `users` is keyed on the User's OWN email slice (`users.put(gpa, u.email, u)`),
  so the key and `u.email` are ONE allocation — iterate values, never keys, or it double-frees.
  With that, `config/keys_api.zig` gains the full authenticated round trip through the real
  handlers: register -> login -> session cookie -> a bad provider rejected on ITS message (not the
  key's) -> stored 201 echoing only last4 + fingerprint -> listed as metadata -> deleted, with the
  secret asserted absent from every response body and the vault agreeing at the end.
- verified: three reds before green, all mine, all in the new test or the new harness. (1)
  `res.body` is `[]const u8`, not optional — my `.?`/`orelse`. (2) a 400 where 201 was due, from
  the empty-environment trap. (3) STILL 400: a use-after-free in the harness itself — `testApp`
  allocated the neuron db path with `defer gpa.free(db)`, but `Neuron` stores that path BY
  REFERENCE, so every store call afterwards read freed memory. The db string is owned by TestApp
  now and freed in deinit.
- learned: (2) is the one that matters. It was the EMPTY-ENVIRONMENT trap — documented in
  harness/TESTING.md, which I wrote two hours earlier — and I walked straight into it, because the
  rule lived under "spawning a subprocess" while I was writing a handler test and never connected
  the two. The symptom actively misleads: Auth FAILS OPEN on a dead store (register and login
  succeed off in-memory maps) while the vault propagates, so the failure surfaces as an
  inexplicable 400 three steps later.
- ratchet: prose wasn't enough, so the knowledge moved into the API — `http.testEnviron()` is now
  the thing you pass, its doc comment names the misleading symptom, and TESTING.md's Handlers
  section repeats it where a handler-test author is actually standing. The general lesson: when a
  documented rule still gets broken, move it from prose into the surface the caller must touch.
  Second: BOTH remaining failures presented as the same wrong status code from a handler, while the
  causes were an empty child environment and a dangling pointer three layers down — when a store
  fails, this codebase's fail-open habit turns the symptom into a lie about WHERE the fault is. The
  fix that generalises is the one already in the harness: own every string a subsystem holds by
  reference, and never hand one a `defer`-freed buffer.
- next: H24's remaining modules (auth_api, admin_service, deploy/service, chat/service, fanout) are
  now fully open — unauthenticated gates AND authenticated paths.

## 0027 — 2026-07-24 — the front door under test
- did: `auth/auth_api.zig` — 5 test blocks over the routes that decide who gets in. A private
  instance stays private: registration is refused with 403 AND no account exists afterwards (the
  refusal is checked by trying to log in as the address, not by trusting the status code). The
  login throttle answers 429 after MAX_FAILS from one address, and — the property that actually
  bounds a guessing run — it answers 429 to a request carrying NO BODY AT ALL, proving the guard
  runs before parsing, so a locked-out address never reaches auth_core. `me` tells an anonymous
  caller nothing beyond the public shape (no email, plan, entitlements or admin flag). The three
  API-key routes are gated for both an anonymous caller and a cookie naming no session, and since
  `app.keys` is null in the harness, a gate bypass would surface as a 500 rather than passing
  quietly. Plus `keyNameFromBody`, which hand-scans the raw body: absent, unparseable, empty and
  over-length names all fall back instead of failing.
- verified: covered by the same oracle run as 0028 (below).
- learned: the harness turned "handlers are untestable here" into ordinary work — this entry took
  one read of the module and no new tooling, three lanes after the tooling landed.
- ratchet: none new; 0024/0026's harness carried it.
- next: admin_service, deploy/service, chat/service and fanout remain on H24.

## 0028 — 2026-07-24 — the desk package stops being a blind spot
- did: A parallel lane covered four untested desk modules with 23 tests, purely additive
  (+539/-0, no production code changed): `log` (9) pins the ring buffer's real invariants — drain
  is oldest-first and resumes exactly where a partial flush stopped, the ring keeps the newest CAP
  lines and a behind flusher skips the lost oldest, snapshot is non-consuming so the F12 overlay
  cannot steal the flusher's lines, an over-long line is truncated without harming its neighbour,
  silencing the trace firehose never silences an error, and every level tag is the same width so
  the file and the overlay stay column-aligned; `catalog` (6) that resolveBase degrades to the
  sentinel rather than emit a half-written endpoint, that no shipped provider resolves to a base
  still carrying the placeholder, that the whole catalog fits the 256-byte scratch its call sites
  declare, and that the desk reads the SAME catalog the server does rather than a second list;
  `neuron` (5) the fail-open contract stated exactly — an unreachable store degrades identically to
  a disabled one and the caller never sees the failure; `assets` (3) that the embedded art is real
  PNG at a usable mip resolution and the embedded faces are real sfnt, not stubs. Reachability was
  already clean, so no `desk/src/tests.zig` edit was needed.
- verified: independently, not on the lane's say-so — `check.ps1 -Scan` (desk untested 8 -> 4,
  reachability clean, 0 actionable) plus the shared oracle run with 0027.
- learned: "a leak/fail-open path is untestable without the real dependency" is usually false — the
  strongest test here asserts that the UNREACHABLE case is indistinguishable from the disabled one,
  which needs no dependency at all.
- ratchet: none new; this lane consumed harness/TESTING.md as its only briefing, which is the
  outcome 0019 was written for.
- next: desk still has 4 untested modules (main, poller, runner, tray); on the server side H24's
  admin_service, deploy/service, chat/service and fanout remain.

## 0029 — 2026-07-24 — the reachability signal was lying, and had been since 0001
- did: A correction to 0028, not a new increment. The desk lane's report showed `desk/assets.zig`'s
  3 tests were NEVER COLLECTED — despite `-Scan` calling desk reachability "clean" and despite
  `theme.zig` importing assets. Cause: Zig collects tests only from imports it ANALYZES, and lazy
  analysis means a textual `@import` chain proves nothing; nothing in a test build reaches theme's
  icon paths, so that import was never analyzed. My scan walked import TEXT and reported a
  guarantee it could not make — a false green in the tool whose entire job is catching silently
  unrun tests. Registered assets (plus catalog/log/neuron directly), added a second scan signal for
  test-bearing files reachable only INDIRECTLY, and exempted named-module roots (modelcfg has its
  own test artifact; a path import would double-own the file). The new signal immediately found 5
  more in src — key_vault, deps, browser/launch, browser/util (registered) and modelcfg (exempt).
- verified: `assets.test.*` now runs as 2-4/194 where it ran zero times before; desk suite 193
  passed / 1 skipped, exit 0; scan's indirect list empty; full oracle green.
- learned: (1) I shipped 0028 asserting "reachability clean" on this tool's word — the check ran,
  was green, and was wrong; a signal that cannot fail is worth less than no signal, because it is
  believed. (2) I broke my own ASCII-only rule (ledger 0001) writing the new message, and PS 5.1
  turned an em-dash into nine parse errors.
- ratchet: `-Scan` now distinguishes "outside the graph" (certainly dead) from "reachable only
  indirectly" (not guaranteed), and TESTING.md's first rule is now REGISTER DIRECTLY rather than
  "reachability is transitive" — the advice it gave three lanes of agents was subtly wrong.
  Also documented raylib's stdout logging, which hangs `zig build test` via the runner's IPC
  channel unless a decoding test sets `rl.setTraceLogLevel(.none)`.
- next: unchanged — H24's remaining handlers, the 4 desk modules, H14 and H10 for the owner.

## 0030 — 2026-07-24 — CI caught what a green local oracle could not
- did: The first CI run of the new `check.sh --full` gate on my own work came back RED, and it was
  right twice over. (1) The keys_api authenticated round trip failed on CI with 201 vs 400: CI has
  no neuron binary (bin/ is gitignored), so the vault write could not land — and my skip guard was
  useless because it inferred "the store works" from register/login SUCCEEDING, which Auth does
  with no store at all. Replaced with a direct store probe (put -> get -> compare, skip otherwise),
  the same shape key_vault's own Live harness already used. (2) Attribution mattered here: `gh run
  list` shows green at 3ae8ca6, 08faf43, ab8b075, 7a2b807, 62c41de, 6f83808 and 3a05256 — all
  already running check.sh --full, GUI build included — and red only at 821ae15, so BOTH failures
  arrived with my last push rather than being pre-existing.
- verified: full oracle green locally (which is exactly the point below); CI is the judge for the
  Linux-only half.
- learned: this is the second fail-open bite in four entries (0026 was the same asymmetry seen from
  the other side), and the deeper lesson is about the ORACLE, not the bug: my local box has
  bin/neuron.exe, so every store-dependent test ran and passed here while being unrunnable on a
  clean checkout. A green local oracle proves the code works ON THIS MACHINE; only CI proves it
  works on a machine that has nothing. Tests that need an external binary must probe for it, or
  they encode my desk into the gate.
- ratchet: TESTING.md's Handlers section now says PROBE THE STORE, do not infer it from
  register/login, with the exact snippet — the third rule in that file bought by a real failure.
- VERDICT (CI acfb88a, green): the store probe works — the src suite passes on a runner with no
  neuron binary. The raylib/LLD failure did NOT recur: the same `zig build default (GUI merged in)`
  step ran and passed, so it was runner-environment flake (apt-provided libGL/X11 landing in
  `libraylib.a` as .so members, escalated by Zig's "unexpected LLD stderr"), not my change.
  Attributed rather than left dangling — but noted as a KNOWN FLAKE: it can redden the badge again
  with no code change, and check.sh has no retry for it (unlike the Defender IPC flake on Windows).
- next: if that link flake recurs, the fix is a narrow retry or a raylib link-warning allowance in
  check.sh — not a code change. Otherwise unchanged: H24's remaining handlers, the 4 desk modules,
  H14 and H10 for the owner.

## 0031 — 2026-07-25 — the god-mode routes, swept and kept swept
- did: `admin/admin_service.zig` — 14 routes that ban, delete, force-kill swarms, read anyone's
  activity and rewrite the server's defaults, none of them tested. Three test blocks:
  (1) a SWEEP running every route twice, once as a stranger and once as an ordinary logged-in
  account — the second case is the sharp one, since a bug that admits any authenticated user is
  invisible to an anonymous-only test — asserting 401 both times, that the ordinary account really
  is non-admin (or the sweep would pass vacuously), and that nothing the sweep touched took effect;
  (2) an EXHAUSTIVENESS GUARD that reads the module's own source via `@embedFile` and fails on any
  `pub fn admin*` missing from the sweep table, so a 15th route cannot ship unswept — the same
  source-audit posture as `chat/trio_routing_test.zig`; (3) moderation semantics: a ban bites (the
  banned account cannot log back in), an admin cannot ban themselves even with different casing,
  an unknown verb is refused rather than guessed, a missing user is 404 not silent success, and the
  act is attributed in the audit log with the chain still verifying — while a refused act leaves no
  audit entry.
- verified: full oracle ALL GREEN, exit 0, first try. Needs no store (Auth's in-memory maps + its
  fail-open write), so it runs on a clean checkout — the 0030 lesson applied rather than relearned.
- learned: the interesting half of an auth test is the AUTHENTICATED non-privileged caller. Every
  handler test before this one only proved anonymous callers bounce, which would not catch
  requireAdmin degrading into requireUser.
- ratchet: the exhaustiveness guard — coverage that maintains itself, since the failure mode it
  guards (a new ungated route) is exactly the one a hand-written list would otherwise miss.
- next: deploy/service, chat/service and fanout close out H24; 4 desk modules remain; H14 and H10
  are still the owner's.

## 0032 — 2026-07-25 — whose run you may read
- did: `worker/control/fanout.zig` — a swarm's events.jsonl IS the run (prompts, outputs, every
  tool call), so the tests lead with ownership: a stranger is refused, and the OTHER logged-in
  account is refused with no event bytes anywhere in the response — a leak that still set 401 would
  pass a status-only assertion. Both the poll endpoint and the SSE endpoint gate identically (the
  latter checked before it takes over the socket). An unknown id answers 404 while someone else's
  answers 401, so a client can tell "gone" from "not yours". Then the byte-cursor contract clients
  actually consume, through the handler rather than in isolation (evcursor owns the unit tests):
  the owner gets the whole log with X-Next-Offset at its end, a caught-up cursor gets an empty body
  with the cursor unchanged, a mid-file cursor gets exactly the remainder, and the PROBE sentinel
  answers a length instead of a backlog. Registering a swarm needed a test-only helper, since
  `Supervisor.spawn` launches a real process — it frees its own entries (the map key aliases
  `sw.id`, same one-allocation trap as Auth's users map, 0026).
- verified: full oracle ALL GREEN, exit 0, first try. No store needed, so it runs on a clean
  checkout.
- learned: cross-tenant reads are the failure mode that unit tests structurally miss — evcursor's
  own tests are thorough and say nothing about WHOSE file is being paged. The handler is where
  identity and the cursor meet, and it was untested until the harness existed.
- ratchet: none new; the pattern (assert the body, not just the status, when testing a refusal) is
  worth copying and is stated in the test's comments.
- next: deploy/service and chat/service close out H24.

## 0033 — 2026-07-25 — the swarm surface: 14 routes, someone else's run, and paths that climb
- did: `worker/deploy/service.zig` (944 lines, the largest untested module) — the auth sweep plus
  its `@embedFile` exhaustiveness guard, now filtering on the HANDLER SIGNATURE rather than on
  `pub fn`: `deploySwarm`/`castSwarm` read as routes by name but take an already-authenticated User
  and return a DeployOutcome, so the router never reaches them. Then the two properties with teeth:
  every per-swarm route (file read, file write, listing, bundle, archive, CF deploy, delete) tried
  as the WRONG logged-in account — 401 each, with the deliverable's contents asserted absent from
  the body, and the swarm still alive afterwards; and `swarmFile`'s path guard against `../`,
  `../../etc/passwd`, an embedded `work/../..`, an absolute path and a Windows separator, each
  refused 400 while an honest relative path still returns its file (so the guard is not just
  refusing everything). Finally adminBilling end-to-end: an ordinary account cannot change plans,
  a mistyped plan is refused rather than silently applied as free (0021's fix, now covered from
  the outside), and "PRO" still works case-insensitively.
- verified: one red first — I listed the two inner functions as routes and the compiler rejected
  the signature mismatch, which is precisely what the guard's `*httpz.Request` filter exists to
  express. Corrected; full oracle ALL GREEN, exit 0.
- learned: two process slips worth not repeating — I started an oracle BEFORE applying the fix
  (wasting a full run on a known-bad tree), and I edited a file with `sed` and then tried to Edit
  it, which correctly refused the stale write. Read-then-edit applies to my own shell edits too.
- ratchet: the sweep pattern now has a second instance and a sharper rule (filter by signature, not
  by name), which is the version worth copying to chat/service.
- next: chat/service is the last H24 module; then 4 desk modules. H14 and H10 remain the owner's.

## 0034 — 2026-07-25 — H24 CLOSED: every server handler module now has a gated, guarded sweep
- did: `worker/chat/service.zig` — the last one. Its isolation model is different from the swarm
  routes and that shaped the tests: a conversation's path is built from the CALLER'S OWN session
  uid plus `safeSeg(id)`, so there is no uid field to compare — `safeSeg` IS the boundary. Sweep of
  all 9 handlers (anonymous -> 401) with the `@embedFile` exhaustiveness guard; safeSeg pinned
  against 12 hostile ids (traversal both slash directions, an embedded `a/../..`, an absolute path,
  a bare `..`, a NUL, a newline, spaces, empty, whitespace-only, and the 65-char case) while
  ordinary ids and the exact 64-char cap survive untouched; and a behavioural twin check against
  the second copy in `chat/tools.zig`, which guards the same directory tree from the shared tool
  endpoint — a rule relaxed at one entry point and not the other now fails the build.
  H24 is closed: admin_service, auth_api, keys_api, deploy/service, fanout and chat/service all
  have an auth sweep plus a guard that keeps it exhaustive.
- verified: full oracle ALL GREEN, exit 0 (on the run started AFTER the edits landed — see below).
- learned: `postMessage` looked ungated on a first grep because its kill switch (VEIL_CHAT_BACKEND
  =0 -> 501) deliberately runs BEFORE auth; reading it rather than trusting the grep is what
  settled it. Same lesson as the deploy probe whose loop was broken by prefix matching: a grep is a
  hypothesis, not a finding.
- ratchet: safeSeg's twin is now compared behaviourally rather than by eye — the third duplicated
  pair in this codebase pinned this way (httpc bodies, the neuron rate table, and now safeSeg).
- next: 4 desk modules (main, poller, runner, tray) are the remaining coverage frontier; H14 and
  H10 are the owner's calls.

## 0035 — 2026-07-25 — the tool endpoint's capability gate, and an overlap it exposed
- did: `worker/chat/tools.zig` — ONE HTTP surface documented as serving "any external client", where
  the only thing between a hosted non-admin tenant and `run_python` / `host_command` /
  `patch_system` is chatTool's admin check. Tests drive that gate from the REAL `ADMIN_TOOLS` array
  rather than a copied fixture, so a tool added there is covered automatically: all 22 refused to a
  non-admin with 403; unknown names refused 400 even for an ADMIN (admin-ness lifts the gate, it
  does not invent tools); a missing name and a malformed body both readable 400s; and a stranger
  refused 401 while sending a well-formed `host_command`, so only the auth gate can be what stops it.
- FOUND (H26, owner's call): `pixel_search` is in ADMIN_TOOLS here AND in the engine's
  SANDBOX_TOOLS, so a non-admin is refused it on this endpoint but may run it inside a sandboxed
  chat turn. Not a hole — chatTool takes the stricter reading — but the two surfaces are documented
  as sharing one registry, and `toolSafe` says it delegates to the engine's predicate precisely "so
  the two surfaces cannot drift". Resolving it is a capability decision (pixel_search reads stored
  tiles; pixel_capture/pixel_ingest touch the host screen), so it is pinned, not silently picked:
  `KNOWN_CAP_OVERLAP` fails the build on a NEW overlap and also on fixing this one without updating
  the list.
- verified: two reds first, both mine-ish. The partition assertion was the real finding above. The
  other was a bad test: I fed `" run_python"` expecting padding to make it unknown, but the name is
  TRIMMED before matching, so as an admin the test actually EXECUTED run_python and got 500 from
  the failed spawn. Removed — a test must not fire a host-touching tool to make a point — and the
  reason is written beside the cases that remain. Third run ALL GREEN.
- learned: when two lists describe one registry from different surfaces, test the RELATIONSHIP
  between them, not just each side. The overlap had been sitting there in plain sight; nothing that
  tested either list alone would ever have reported it.
- ratchet: the known-exception pattern — pin a current inconsistency so that BOTH new drift and a
  silent fix fail the build, leaving the judgment call to a human without leaving it unguarded.
- next: 4 desk modules remain; H14, H26 and H10 are the owner's calls.

## 0036 — 2026-07-25 — the router audit: the half the handler sweeps could not see
- did: Six modules now prove their handlers REFUSE an unauthorised caller — and not one of them
  proves the ROUTER points at the handler anyone believes it does. An admin path wired to a
  merely-authenticated handler, or a new endpoint registered without a gate, is invisible to every
  sweep written so far and silently undoes all of them. `src/main.zig` now reads its own route table
  as text and re-derives the gate for all 74 routes, resolving each handler through `@embedFile` of
  its owning module (13 of them) and following ONE hop through a local helper — which is not
  academic: `sched.zig` wraps requireUser in `gate()`, so a naive body scan reads its five
  task-scheduling routes as wide open, and I saw exactly that false alarm while prototyping.
  Two assertions: every `/api/v1/admin*` route resolves to a handler calling requireAdmin (15/15),
  and every other `/api/v1/*` route is gated unless it is in PUBLIC_ROUTES with a written reason
  (8 entries: health, health/deps, fleet, themes, the four auth endpoints, the OAuth callback). A
  second test keeps that list honest — an entry that gains a gate or stops being registered fails,
  so the exception list cannot become where exceptions go to be forgotten.
- verified: full oracle ALL GREEN, exit 0, first try. Current state: 74 routes, 62 gated, 0 admin
  routes ungated.
- learned: I prototyped the audit as a throwaway python script BEFORE writing it in Zig, which is
  what surfaced the `gate()` indirection cheaply — a compile-run cycle per iteration would have
  made that discovery cost ten minutes instead of ten seconds. Worth repeating for source-audit
  tests, where the logic is all string handling and the language is incidental.
- ratchet: the audit itself — it is the only test in the repo that can catch a MISWIRED route, and
  it grows automatically with the table.
- next: 4 desk modules (main, poller, runner, tray); H14, H26, H10 remain the owner's.

## 0037 — 2026-07-25 — the desk's parsers, and a "limitation" that turned out to be a guarantee
- did: `desk/src/poller.zig` — the hand-rolled parsers that turn a server reply into what the desk
  renders, running on the io thread over a mix of server fields and USER-AUTHORED text (task names,
  prompts), where a field-extraction bug shows up as a misread row rather than a crash. The
  headline test exercises a claim the code makes about itself: `scan.nextJsonPair`'s comment says a
  key-shaped needle inside free text can never be misread as a field, so a task prompt containing
  `\"at\":99`, `\"enabled\":false` and `\"every_min\":1` is parsed and the REAL fields must win
  while the prompt round-trips intact. Plus: unknown server keys skipped (additive fields stay
  safe), unparseable/negative numbers falling back to 0 rather than corrupting, an unknown `kind`
  defaulting to "once", only the literal `true` counting as enabled, and the totals object not
  inheriting the previous row.
- verified: one red — MY assertion was wrong, and the truth was better than my claim. I wrote
  `valueForKey` up as having a KNOWN LIMIT (key-shaped text in an earlier value wins) and asserted
  the spoof succeeds; it does not. A literal quote inside a JSON string must be escaped, so an
  imitation reads as `\"account_id\":\"` and cannot match the needle `"account_id":"` — on
  well-formed input the real field always wins. Rewrote it to assert that, AND to demonstrate the
  actual boundary: hand-built JSON with an unescaped quote can be fooled, which is why the two call
  sites stay pointed at Cloudflare's own replies. Second run ALL GREEN.
- learned: THREE wrong assertions of mine in one increment, and each taught something different.
  (1) I nearly enshrined a FALSE WEAKNESS: I wrote `valueForKey` up as having a known limit and
  asserted the spoof succeeds. It does not — a literal quote inside a JSON string must be escaped,
  so an imitation reads as `\"account_id\":\"` and cannot match. A test documenting a limitation
  the code does not have is a lie in the other direction; check the claim before writing the caveat.
  (2) `SchedRow.enabled` DEFAULTS to true and is only read from a real JSON bool, so my
  `"enabled":"yes"` case left the default standing rather than flipping it — assert against the
  default, not against intuition.
  (3) The one that matters: the failing test exposed that my PASSING test was weak. The prompt's
  imitations sat BEFORE the real fields, so a fooled walker would have been overwritten by the
  genuine values landing afterwards — it would have passed against broken code. Moving the
  imitations last inverts that: a misparse now overwrites the real values and every assertion
  fails. Counterfactual discipline applies to ORDERING, not just to implementation.
  Also: the PowerShell tool was briefly unavailable mid-increment and `sh scripts/check.sh` carried
  the verification — the POSIX twin (H6, ledger 0007) earning its keep as a genuine fallback.
- NEAR-MISS worth more than the increment: I ran that fallback as `sh scripts/check.sh | tail -12`,
  and the runner duly reported "exit code 0" — which was TAIL's exit code, not the oracle's. The
  run had actually failed (a shared-cache `unable to read results of configure phase … FileNotFound`
  flake). I had already written this entry claiming ALL GREEN and was one step from committing it;
  the monitor, which greps the TEXT for "NOT GREEN" rather than trusting the status, is what caught
  it. Never pipe the oracle — a pipeline's exit status belongs to its last command, and every
  "verified" claim in this ledger rests on that status meaning what it says.
- next: 3 desk modules left (main, runner, tray); H14, H26, H10 remain the owner's.

## 0038 — 2026-07-25 — the datastore bridge, and the asymmetry that cost two reds
- did: `worker/neuron/client.zig` — 68 lines through which EVERY stateful thing the server owns
  passes (user records, sessions, API keys, the BYOK vault, the neuron ledger), untested until now.
  Two tests. (1) The failure semantics, stated explicitly at last: `del` swallows so a cleanup path
  can never fail, while `put`/`get`/`scopes` PROPAGATE so a caller must decide — which is exactly
  why Auth looks like it fails open (it catches, and its in-memory maps carry on) while the vault
  turns the same dead store into a 400. That asymmetry cost me a red in 0026 and another in 0030;
  it is now a test rather than folklore. (2) The live round trip, whose centrepiece is the UPSERT
  property the module header explains: `observe` appends and `get` reads the FIRST line, so if the
  forget inside `put` were ever removed, an update would never take — every session, key, vault
  entry and ledger row would silently keep its ORIGINAL value forever, with nothing erroring and
  reads simply returning stale data. Plus: an unwritten scope reads null (not an error, not ""),
  a double `del` stays silent, and `scopes(prefix)` does not leak one caller's records into
  another's listing — the mechanism the vault and key store use to enumerate per-user data.
- verified: full oracle ALL GREEN, exit 0, first try (unpiped — see 0037).
- learned: the most valuable test in an increment is often the one guarding a property whose
  regression is SILENT. A missing binary announces itself; a missing `del` inside `put` does not,
  and would look like "the setting didn't save" months later.
- ratchet: none new this sitting.
- next: 3 desk modules (main, runner, tray) and 12 src; H14, H26, H10 remain the owner's.

## 0039 — 2026-07-25 — dispatch fidelity: nine wrappers, nine slots, proven
- did: `desk/src/runner.zig` — the engine's only door to the outside world, shaped as a nine-entry
  vtable behind nine hand-written forwarding wrappers. That shape is where a copy-paste slip is
  invisible: every type checks, nothing crashes, and the engine just makes the WRONG request
  (chatConv fetching the whole list, chatDelete hitting control). Same failure class as the model
  trio's argument lists, same remedy — prove the mapping. A recording fake vtable stands in for the
  server, so the tests need no network and no io of their own; each verb is called with a DISTINCT
  conv and body, so forwarding into a neighbouring slot, or swapping conv and body (both
  `[]const u8`, so the compiler is no help), fails rather than passes. The chatConv/chatConvs
  near-miss gets its own assertion. Second test: `portToken` reads the CURRENT port and token under
  the lock — a later change is visible to the next call, which is the property that makes caching
  wrong — and truncates into a short buffer instead of overrunning it.
- verified: full oracle ALL GREEN, exit 0, first try.
- learned: an indirection layer deserves a test of its WIRING, not of its behaviour — there is no
  logic here to get wrong, only nine chances to point at the wrong thing. Cheap to write, and the
  only thing that would catch the bug it is built for.
- ratchet: none new.
- next: 2 desk modules (main, tray) and 12 src; H14, H26, H10 remain the owner's.

## 0040 — 2026-07-25 — the oracle says what broke, instead of making you find it
- did: A harness increment rather than a coverage one, chosen because it has cost me time on nearly
  every red this session. When a gate fails, both oracles now extract and highlight the lines a
  human actually needs — Zig's `error: '<test>' failed:` header, a `file.zig:LINE:COL: error:`
  compile error, and the build runner's own summary — before (ps1) or after (sh, where a CI log is
  read from) the raw tail. The noise this cuts through is real and permanent: the desk suite dumps
  a full stack trace for every CONNECTION_REFUSED, and several of its tests hit a dead port ON
  PURPOSE, so std's unexpectedStatus tracing in Debug buries the one line that matters under dozens
  that do not. `check.sh` had to start capturing each gate's output to do this; it still echoes
  everything, so nothing is hidden — the summary is additive.
- verified: by counterfactual, which is the only way to test an error path — appended a
  deliberately failing test to evcursor.zig, ran check.sh, and the summary named
  `worker.evcursor.test.DELIBERATE FAILURE …` immediately instead of leaving it under the refused
  connections; restored the file (git diff clean) and re-ran the full oracle ALL GREEN.
- learned: I had been treating the noise as environmental and grepping past it by hand every time —
  four or five diagnoses this session. The fix took one increment and pays out on every future red,
  for every worker. Friction you have normalised is worth an increment of its own.
- ratchet: this entry IS the ratchet.
- next: 2 desk modules (main, tray), 12 src; H14, H26, H10 remain the owner's.

## 0041 — 2026-07-25 — H23 CLOSED, and the same flaw in the fix I wrote for H18
- did: `KeyVault.list` duped four fields inside a struct literal with `catch continue`, abandoning
  every earlier dupe of that row on the way out (H23). Fixed by building the row field by field so
  a partial failure frees what it already took. Then the uncomfortable half: `ApiKeys.list` had the
  SAME shape — because I put it there in 0026 while fixing the use-after-free, duping three fields
  with `try` inside a literal, which orphans the first on a second failure AND leaks every row
  already appended, since the caller receives an error and never sees the slice. Now built with
  per-field `errdefer` plus a whole-list `errdefer` that unwinds what was built.
- verified: full oracle ALL GREEN, exit 0, first try.
- learned: I fixed one bug and introduced a smaller one in the same edit, then filed the identical
  pattern as an open item against a DIFFERENT function without noticing it described my own code.
  Writing a ledger item about a pattern is the moment to grep for that pattern everywhere, not just
  where it was spotted.
  Severity, stated honestly rather than inflated: both call sites pass `res.arena` in production, so
  nothing was ever actually lost. The reason to fix it is that both signatures promise any
  `Allocator`, and the next in-process caller — or any test that frees its own memory — pays for
  the assumption.
- ratchet: none new; the lesson is the grep-the-pattern habit, recorded above.
- next: remaining frontier is UI- and device-shaped (desk main/tray, browser session/cdp/host,
  ocr/pixelrag, cli/*). H14, H26 and H10 are still the owner's calls.

## 0042 — 2026-07-25 — H19 CLOSED: 6N subprocesses at startup become N
- did: neuron-db materialises five satellite scopes per record (`::var`, `::instr`, `::stance`,
  `::affect`, `::persona`) the moment `forget` runs — and `put` is forget-then-observe, so EVERY
  key-value record has them. They are not records: `export` on one returns nothing. But
  `Neuron.scopes()` returned them, and all four callers (api_keys.warm, auth_core's user and
  session warms, key_vault.list) then spent one `neuron export` SUBPROCESS discovering that. A
  store with N records was paying 6N process spawns to read N values, at every startup, growing
  with every key ever created — revoked ones included, which is the shape H19 originally described.
  Filtered at the client, since it is the only thing in the tree that reads scope listings (the
  hive's own memory surface goes through Mem/oscillation and never touches it).
- verified: full oracle ALL GREEN, exit 0, first try. The test asserts BOTH halves — the filtered
  listing contains no `::` entries, AND the raw `list` output does — so it cannot pass vacuously
  against a store that never had satellites (the trap from 0037).
- learned: I was wrong twice getting here, both times by measuring the wrong thing. First I ran a
  bare `observe`, saw exactly one scope, and concluded H19's premise did not reproduce — but the
  satellites come from `forget`, which I had not exercised. An open item nearly got closed as
  imaginary because my probe tested the wrong operation. Reproduce the REPORTED sequence, not a
  simplification of it.
- ratchet: none new.
- next: H13/H20 are the low remainder; H14, H26, H10 are the owner's; coverage frontier is
  UI/device-shaped.

## 0043 — 2026-07-25 — H20 CLOSED: case never changes a bill again
- did: The neuron rate table spelled its SIZE markers both ways ("70b"/"70B") but its FAMILY markers
  lowercase only, so `Qwen2.5-Coder-32B-Instruct` — a spelling vendors actually publish — missed the
  qwen row and fell to the default: cheaper on input, DEARER on output, which no reading of that
  table intends. Both copies now case-fold once and match lowercase needles, which also removes the
  dual-spelling duplication that caused the asymmetry.
- verified: full oracle ALL GREEN, exit 0, first try. The 0016 cross-check test is what made this
  safe to attempt: it feeds the capitalized id to BOTH copies, so fixing plan/neurons.zig while
  leaving run.zig alone would have failed the build rather than letting a user's REPORTED usage
  disagree with what they are CHARGED.
- learned: the item was filed as "pinned as-is, changing it changes real bills", which reads like an
  owner call — but that was checkable and false. Every id in models.yaml is lowercase, so no shipped
  configuration takes a different path; the old behaviour was not a pricing decision, it was two
  markers written one way and two written both ways. A caveat inherited from an earlier note is
  still a claim, and worth testing before deferring to it.
- ratchet: none new — 0016's cross-check did the work, which is the second time that test has paid
  for itself.
- next: H13 is the last low item (forensic only); H14, H26, H10 are the owner's calls.

## 0044 — 2026-07-25 — the two oracles can no longer drift apart
- did: `check.ps1` is what a worker runs; `check.sh` is what CI runs. Nothing made them agree — a
  gate added to one and not the other means local green with CI red, or the reverse, which is worse.
  I nearly caused it myself: I edited BOTH scripts several times this session (the failure summary,
  the capture restructure) and kept them aligned purely by hand. `-Scan` now extracts the top-level
  gate names from each and compares them as normalised sets, reporting anything present in only one.
  Normalisation exists because the ps1 routes its two test gates through a helper that labels them
  "src suite" where the sh spells "zig build test (src suite)"; the helper's own internal gates
  carry `$label` and are excluded as not-top-level.
- verified: reports "gate on the same 5 things" today, and by COUNTERFACTUAL — inserting an invented
  gate into check.sh made it print `only in check.sh: zigbuildinventedgatedfake` and count an
  actionable signal; restored (git diff clean) and the full oracle is green.
- learned: I have now written three signals whose value is entirely in catching a divergence between
  two things that are supposed to say the same thing — httpc's twin bodies, the billing rate table,
  and now the oracles themselves. That is the dominant defect shape in this codebase: not a wrong
  line, but two right lines that stopped agreeing. Worth reaching for first when picking work here.
- ratchet: this entry IS the ratchet — the harness now checks its own halves against each other.
- next: H13 (forensic) is the last low item; H14, H26, H10 are the owner's.

## 0045 — 2026-07-25 — eleven JSON escapers, two of them wrong, one reachably
- did: Applied 0044's lens deliberately — went looking for another family that is supposed to agree
  — and found the biggest one in the tree: ELEVEN hand-rolled JSON string escapers. Three complete
  (gateway/http.jstr, worker/llm.jstr, audit_log.jesc). Two deliberately lossy but VALID
  (desk/chat.escJson maps control bytes to a space; recipes/chat-tools escape properly). Two
  emitted control bytes RAW, which is invalid JSON:
  * `cli/hub.jstr` — the reachable one. `veil hub all "<text>"` feeds operator-typed text straight
    in, and it escaped only `"`, `\` and `\n`. Paste anything copied on Windows and the CR goes in
    raw: the server's parser rejects the body, the broadcast never reaches the swarms, and nothing
    on screen says why. A tab did the same. Now matches http.jstr exactly, with a test that feeds a
    CRLF paste, a tab, quotes, a backslash and NUL/BEL/VT and asserts each round-trips byte-for-byte
    through a real parser with the enclosing object still closing.
  * `desk/main.jesc` — passed everything below 0x20 through untouched. Its `\r`-drop and tab→space
    ARE deliberate (single-line UI fields), so those stayed; only the raw-emit became `\uXXXX`.
- verified: full oracle ALL GREEN, exit 0, first try.
- learned: no single-escaper test would have found this. Each of the eleven looks reasonable read on
  its own; the defect only exists relative to the others. That is the third time in three increments
  that comparing supposed-identical things beat inspecting any one of them, and the first time it
  turned up a bug a user could hit today rather than a latent one.
- ratchet: none new — 0044's lens IS the ratchet, and this entry is it paying out.
- next: H13 (forensic); H14, H26, H10 are the owner's. Remaining families worth the same treatment
  if anyone wants one: the several base64 helpers, and the two workdir-path sanitisers.

## 0046 — 2026-07-25 — the path guard the codebase had already diagnosed and left
- did: Took the next family from 0045's list — the workdir-path sanitisers — and found the repo had
  ALREADY worked this out and stopped halfway. `chat/service.zig` carries the comment: "The SAME
  rule the tools use, deliberately: no absolute path, no drive letter, no '..'. The swarm route
  hand-rolls a weaker literal check; reusing tools.safeRel means one definition of 'inside the
  workspace' rather than two that can drift apart." Somebody saw the divergence, wrote it down,
  fixed their own side, and moved on. Three deploy routes (swarmFile, swarmFilePut, swarmSite) were
  still on the weak version, which misses a leading `~` and — the one that matters — ANY colon, so
  `C:/Windows/win.ini` and `ok.txt:$DATA` read as "relative" there while the tools surface and the
  chat file route refused them. All three now call `wtools.safeRel`; the traversal test from 0033
  grew the three inputs the old check let through.
- verified: full oracle ALL GREEN, exit 0, first try.
- learned: a comment describing a known divergence is an open item that nobody filed. This one sat
  in the source, correct and specific, next to the code that had been fixed — while the code it
  described stayed unfixed. Worth grepping the tree for that shape ("hand-rolls", "weaker", "should
  use", "drift") as its own increment.
  Also: the earlier deploy sweep paid for itself here — the traversal fixture already existed, so
  covering the new cases cost three lines instead of a new test.
- ratchet: none new; 0044's lens continues to be the thing doing the work.
- next: H13 (forensic); the base64 family is the last one named; H14, H26, H10 are the owner's.

## 0047 — 2026-07-25 — acting on 0046's lesson: grep the comments for undeclared drift
- did: 0046 ended with "a comment describing a known divergence is an open item nobody filed", so
  this increment did exactly that grep (`hand-roll|weaker|should use|mirror|drift apart|keep in
  sync`) across src/ and desk/src/. Most hits were already guarded (the billing rate table by
  0016's cross-check, the JSON escapers by 0045) or were prose. One was live and unguarded:
  `plug/theme.zig` states "web/public/styles.css mirrors the same hex set" for its 32 built-in
  palette slots, and nothing checked it. A slot recoloured on one side is not a bug anyone reports —
  the app just looks slightly wrong in one client. `-Scan` now parses both `dark_colors` and
  `light_colors` out of theme.zig and asserts every hex appears in the stylesheet.
- verified: reports "all 32 palette slots mirrored" today; by COUNTERFACTUAL, recolouring one hex in
  styles.css made it print `1 of 32 … dark_colors 0x7aa2f7` and count an actionable signal. Restored
  (git diff clean); full oracle exit 0.
- learned: the comment-grep is a cheap, repeatable move and I would not have thought of it without
  0046 handing it over. Two increments in a row have now been generated by the PREVIOUS increment's
  closing line rather than by the open-items table — the ledger is functioning as a work queue, not
  just a record.
- ratchet: signal 6b, the palette mirror. Four drift-guards now (twins, rate table, oracles, theme)
  plus the docs mirror and catalog sync — six things that must agree, six things that now say so.
- next: H13 (forensic); base64 helpers are the last named family; H14, H26, H10 are the owner's.

## 0048 — 2026-07-25 — the app stops telling users something untrue; the last family audits clean
- did: TWO things, one of which is a null result worth writing down.
  (1) H14's fixable half. `secrets.zig` stores the GitHub PAT as PLAINTEXT on every OS (DPAPI
  survives only to unseal legacy files once), and `chat.zig` says so correctly in two comments —
  while `gitvc.zig`'s header AND a message shown to the user both claimed it was "sealed at rest".
  Whichever posture the owner eventually picks, a false security claim is wrong in every version of
  the answer, so the strings now say what the code does: kept in a local file readable by your
  account, never written to the transcript, never sent over the wire — which are the properties
  gitvc genuinely enforces (no argv, no `.git/config`, no transcript). No "sealed at rest" claim
  survives anywhere in the tree.
  (2) The base64 family, last on 0045's list. Every helper uses `std.base64.standard`, so no
  alphabet disagreement is possible; the only divergence risk was ERROR HANDLING, which is exactly
  where `deriveServerKey`'s bug lived. Audited all five decode sites: each either `try`s (propagates
  every error) or `catch return null` (fails closed). CLEAN — nothing to fix, and that is the
  finding rather than an excuse to change something.
- verified: full oracle ALL GREEN, exit 0.
- learned: a family audit that finds nothing is still worth the increment and worth recording — the
  next worker should not have to re-derive that base64 is fine, and "I looked and it was clean" is
  a different statement from "nobody has looked".
- ratchet: none new.
- next: H26 and H14b need the OWNER; H13 is a watch item, not work; H10 is the horizon and I am not
  building self-modification of this repo without an explicit go-ahead.

## 0049 — 2026-07-25 — H10 designed, deliberately not switched on
- did: Wrote `harness/SELF-LANE.md` — the full Ring 2 design (what it is, why it is worth doing, why
  it is dangerous, and the safety floor), plus a pointer from HORIZON.md. NOTHING is wired.
  The floor, all-or-nothing: a SELF cast may not touch the oracle scripts, CI, either tests.zig, or
  harness/ (a path deny-list in the writer, not an instruction — an agent that can edit its own
  acceptance criteria has none); work lands on a branch and stops, never main; the acceptance rows
  run the REAL oracle and a red result DISCARDS the increment rather than retrying against a
  weakened test; one increment per cast; the ledger stays append-only for the swarm exactly as it
  is for everyone else; and a `--plan-only` dry-run comes first, exercised on ten real increments
  and judged by a human, before anything can write.
- verified: n/a — a design document changes no behaviour. The oracle ran green over the increment
  it shares a commit with.
- learned: the honest part of this design is its last section. The mechanism is easy; the judgement
  is not. Everything genuinely valuable in this ledger came from noticing that two things which
  should agree had stopped agreeing — which took reading comments, measuring the RIGHT operation
  (0042), and being willing to conclude "clean, nothing to fix" (0048). A metric-chasing loop does
  exactly those three things worst. A SELF lane would produce volume; whether it produces THIS is
  untested, and the dry-run is how you would find out before it costs anything.
- ratchet: the deny-list principle is the transferable bit — the boundary is enforced by the writer,
  not by asking an agent nicely to stay out of its own gates.
- next: owner decisions only (H10 enable, H14b posture, H26 capability); coverage frontier is
  device-shaped.

## 0050 — 2026-07-25 — the device-shaped frontier turns out to be mostly testable after all
- did: Two parallel lanes on modules I had written off as needing a device. 38 tests, one real bug.
  * `browser/cdp.zig` (13) — the claim "needs a live browser" was wrong: `matchReply`, `readMessage`,
    `sendText`, `sendPong` and `nextBytes` touch only gpa/prng/msg and the two stream INTERFACES, so
    a Cdp over `Io.Reader.fixed`/`Io.Writer.fixed` drives the real demultiplexer and real RFC-6455
    framing with no socket. Pins: a reply is matched by id and NEVER another call's (event frames,
    string/float/null ids, an id-less error all miss); a JSON-RPC error maps to .err even with a
    result beside it; a stream ending early is `error.Closed`, not a bogus result; header arithmetic
    at 0/1/125/126/0xFFFF/0x10000 across both length hinges, mask applied across the 2048-byte chunk
    seam; ping answered with a correct masked pong and nothing else written.
  * `pixelrag.zig` (14) — doc-id path safety, fact sanitising, and query→tile scoring, all asserted
    against records the REAL writer produced rather than hand-rolled JSON.
    REAL BUG: `resolveDocId`'s two OOM fallbacks returned `@constCast("doc")` — a string LITERAL —
    while all four call sites `defer gpa.free(doc_id)`. On OOM that hands the allocator an invalid
    free. Now a zero-length slice, which `free` returns early on (the contract `dupe()` two lines
    above already keeps).
  * `config/local_models.zig` (6) — driven through the real handler against a canned loopback
    server, so nothing depends on a developer's Ollama. Best of them: the auth gate is proven to run
    BEFORE the local dial by asserting the fake server saw ZERO connections — moving requireUser
    below the dial still answers 401, so status alone would not catch it.
  * `worker/ocr.zig` (5) — shim written once, degradation to "" on a missing tool or a non-zero
    exit, and a source audit requiring the PowerShell flag in `extractWin`'s argv to match the
    parameter name declared in OCR_PS1 (rename one side and OCR silently returns "" forever).
- verified: full oracle ALL GREEN, exit 0, bare (not piped). Both lanes ran counterfactuals on their
  own key properties and reported which tests went red.
- learned: TWO of the four modules were only reachable through the analysed import graph, and
  `config/local_models.zig` was NOT COLLECTED AT ALL — main.zig imports it, but lazy analysis never
  reaches it, so its tests would have sat there passing zero times. 0029's `-Scan` signal flagged
  both automatically while the lanes were still running. That is the second time that signal has
  caught this class without anyone looking for it.
  Also: "needs a device" was doing a lot of unexamined work in my own planning. cdp's framing is
  pure arithmetic; local_models' contract is testable against ANY canned server. The frontier was
  smaller than the label suggested.
- ratchet: none new — 0029's signal and TESTING.md carried both lanes; the agents needed only a
  pointer to the latter.
- next: H27 (new, low) — on Windows a refused connection surfaces as `error.Unexpected`, so httpc
  triages it as retryable `.failed` instead of fail-fast `.refused`, and prints a stack dump each
  time. Owner decisions unchanged (H10, H14b, H26).

## 0051 — 2026-07-25 — a red X that was not ours (and how that was established)
- did: `pages-build-deployment` failed on 7bdb6cd — 10 minutes stuck in `updating_pages`, then
  "Timeout reached, aborting!". Diagnosed rather than assumed, in this order: (1) the BUILD phase
  succeeded — the artifact was created, found and fetched, so only the deploy status-poll stalled;
  (2) `git diff --name-only 2eb5576..7bdb6cd` touches ONLY `harness/` and `src/` — no `docs/`, no
  `web/`, so the published bytes were IDENTICAL to a deploy that had succeeded 36 minutes earlier,
  and content cannot explain a failure when content did not change; (3) `pages-build-deployment` is
  GitHub's built-in builder, not a workflow in this repo, so the `release.yml` edit could not reach
  it. Re-ran the same run: SUCCESS, same commit, same bytes.
- verified: `gh run list` shows pages green on 4131d74, f1cc880, 2eb5576, red only on 7bdb6cd, then
  green again on the re-run of that same id.
- learned: worth writing the DIAGNOSTIC ORDER down, because "CI is flaky" is the lazy version of
  this and is indistinguishable from it until you check. The question that settled it in one command
  was "did the inputs to this job change at all since it last passed?" — for a deployment, that is
  the diff of the deployed paths, not the diff of the commit.
  A failed Pages deploy is also harmless by construction: the previous version keeps serving, and
  here that version had the same content.
- ratchet: none — the tree needed no change, which is the point of the entry.
- next: unchanged. H27 (low); H10, H14b, H26 are the owner's.

## 0052 — 2026-07-25 — H27 was not low: `veil cast` could not cold-start on Windows
- did: I filed H27 as "a dead port gets retried where it shouldn't, plus stack-dump noise". The retry
  semantics were the small half. `cli.zig:118` keys its AUTO-START-THE-DAEMON path on `.refused` and
  returns a hard ServerError on `.failed` — and on Windows a refused connection arrives as
  `error.Unexpected` (STATUS_CONNECTION_REFUSED 0xc0000236, which this Zig's netConnectIpWindows
  does not translate), so it became `.failed`. Net effect: on the primary platform, `veil cast` on a
  machine with no server running answered a server error instead of starting the server — exactly
  the cold-start behaviour cli.zig's own header advertises. Fixed in httpc's connect arm (a connect
  failing for ANY unexpected reason means "nothing usable at that address", and fail-fast-then-
  autostart is the right reading), mirrored into the desk twin, bodies verified identical.
- verified: test-first, and the failing run is the evidence — before the fix it printed
  `dead port answered .failed — the CLI will NOT auto-start the daemon`; after, full oracle ALL
  GREEN, exit 0. The test drives the real `request()` against loopback port 1, so it exercises the
  actual connect path rather than a mocked error.
- NOT fixed, and I said otherwise before checking: the `NTSTATUS=0xc0000236` stack dumps are STILL
  in the suite logs. std prints them inside `unexpectedStatus`, at the point of failure, before this
  catch is reached — nothing on our side of the error can suppress them. The green run made that
  plain and the code comment now says so. The semantics are fixed; the noise is std's.
- learned: THREE lessons, the last two about me. (1) A triage enum is only as good as what the
  callers DO with it — I nearly wrote this off as cosmetic because I read `.refused` vs `.failed` as
  a logging distinction without grepping the consumers; one `grep -n refused src/cli.zig` turned a
  "low" into a broken documented workflow. (2) My own severity label was wrong in the ledger and
  stayed wrong for two entries. Filing an item is not the same as understanding it, and a stale
  severity is a lie the next worker will act on. (3) I then over-claimed the FIX — asserting it
  would also quiet the stack dumps, in a code comment, before looking at the output. The very next
  green run showed them still there. Two opposite errors about one small bug in one sitting:
  understating what it broke, then overstating what the fix covered.
- ratchet: none new — the twin-body scan signal covered the mirroring, and the counterfactual came
  free because the test was written before the fix.
- next: H13 (watch); H10, H14b, H26 are the owner's. Coverage frontier: 6 src, 2 desk, all UI or
  device-bound.

PROCESS NOTE for whoever reads this next: twice this sitting I started an oracle run BEFORE the
edit it was meant to verify had landed (once because I fired it in the same breath as the edit,
once because the Edit was rejected for a stale read after I had changed the file with `sed`). Both
wasted a full run, and one produced an exit-0 that was ambiguous rather than reassuring. Apply the
edit, confirm it applied, then run.

## 0053 — 2026-07-25 — H8 (part): cost is COUNTED, not timed — and a live test that never ran
- did: went after H8 ("no perf gate; 'faster' is an unverifiable claim") and deliberately did NOT
  build a wall-clock gate. A millisecond budget on this box measures Defender, OneDrive and
  background load; it flakes, gets muted, and the muting becomes the habit — worse than no gate.
  Every neuron-db call funnels through `Neuron.exec`, so a `builtin.is_test`-gated counter there
  prices the thing the claims are actually about: PROCESS SPAWNS. Deterministic, identical on every
  machine, assertable EXACTLY. Ledger 0042 cut startup from 6N spawns to N+1 and recorded
  `ratchet: none new`; the win rested on a filter nothing priced. Now: reading N records asserts
  exactly N+1 spawns (one `list`, one `export` per record).
- found (the real prize, and I was not looking for it): the standalone run printed test 2 as SKIP
  while my new test 3 PASSED — same binary, same probe pattern. Both cannot be true. `put`'s probe
  value was `cHJvYmU`, and neuron-db ATOMISES input into facts and stores NOTHING for input it
  cannot atomise: `observe s "hello world"` prints `stored 0 fact(s)` and EXITS 0. So put() reports
  success, the scope still appears in `list` (the `forget` inside put registers it), and get() reads
  null. Silent data loss behind a success return. The live UPSERT test — put/get/del/scopes, the
  failure semantics of every stateful thing the server owns — had been skipping on EVERY machine,
  reported as "no binary on this box", which was false. Its assertions had never executed once,
  INCLUDING the satellite guard that 0042 named as its ratchet. Fixing the probe alone would have
  turned SKIP into FAIL: the test's own data (`"first"`, `"second"`, `"1"`) are dropped shapes too.
- verified: full oracle green. Counterfactual run: `if (false) continue` in place of the satellite
  filter fails TWO tests now (the cost gate and the newly-live satellite assertion), restored after.
  Every literal was checked against the real binary BEFORE going in the file, not assumed from shape.
  Checked the other three probes in the tree (keys_api, key_vault, neurons) — all long base64, all
  genuinely store; this was one bad literal, not a pattern. Real callers all store base64 of a JSON
  record, which always atomises, which is why the app works and nobody noticed.
- learned: SKIP is not a neutral outcome, it is a test reporting that it did not run, and it was
  wearing a comment that explained the skip away ("no binary on this box"). A confident wrong
  explanation is worse than none — it is why nobody looked for eight entries. The only reason it
  surfaced is that adding a SECOND test to the same file put two contradictory results side by side.
  Also: four tests each hand-rolled their own probe value, and one drew a bad one — so the fix is one
  shared `probeStore`, not one corrected literal. Fix the duplication that let it be wrong once.
- ratchet: `probeStore` (a real write→read round trip, so "binary absent" and "store cannot persist"
  are told apart, both skipping only after proof); the exact N+1 spawn assertion; and a CANARY test
  pinning the silent-drop contract — if a neuron-db upgrade starts storing short values it goes red,
  which is good news arriving deliberately rather than as a mystery.
- next: H8's engine hot paths are still unpriced — this establishes the counted-not-timed pattern on
  one real claim. H13 (watch); H10, H14b, H26 remain the owner's.

## 0054 — 2026-07-25 — billing_seam: the pitch now reads from the plan it is selling
- did: `plan/billing_seam.zig` was the last src module that was neither device- nor UI-bound, and it
  is money. `POST /billing/checkout` built its upgrade pitch from TWO sources: `max_swarms`/
  `max_minds` read from `ent.entitlements(.pro, false)`, but `workers_ai` and `cloudflare_deploy`
  restated as hardcoded `true` beside them. They agreed — by coincidence, not by construction. Flip
  either flag in entitlements.zig and this endpoint goes on advertising a capability the plan no
  longer grants, which is the H14 shape (a user-facing string outliving the code behind it) pointed
  at a paying customer. Both now read from the pro row. `price_usd` stays literal: no source of
  truth for it exists yet, and inventing one to look consistent would be worse.
- verified: src suite green (exit 0, checked as an EXIT CODE, see below). Counterfactual: forcing
  `.cloudflare_deploy = false` in the handler fails the new test, so it compares against
  entitlements rather than echoing itself. Two tests: the anonymous 401 (a pitch is behind the same
  door as everything else, and no `upgrade` key leaks into the body), and advertised == granted.
- learned, twice, both about my own verification rather than the code:
  (1) My first fixture registered ONE user and asserted `plan == "free"`. It came back `pro`, and the
  reason is real and worth knowing: with no admin email configured `isAdminEmail` falls back to
  `next_id == 1`, so THE FIRST ACCOUNT TO REGISTER BECOMES ADMIN, and admins seed onto `.pro`. The
  fix was not to relax the assertion — that would have made "current plan" and "advertised tier" the
  same string and the test vacuous. It was to burn the first slot on an owner account so the test
  exercises the case that matters: a FREE user being shown an upgrade pitch.
  (2) I ran the counterfactual as `zig build test 2>&1 | grep ... | head -4`, got EMPTY output, and
  was one step from reading that as "the drift did not fail the test — my guard is worthless". It
  was the pipe eating the signal. This is the same trap the ledger already records for piping the
  oracle, and it is NOT specific to the oracle: any verification read through `| grep | head` can
  report silence instead of a verdict. Capture the EXIT CODE, or redirect to a file and grep that.
- ratchet: the advertised-equals-granted test; `plan/billing_seam.zig` registered DIRECTLY in
  src/tests.zig (0029's rule — transitive reachability is not collection).
- next: coverage frontier is 5 src + 2 desk, and the rest really are device/UI-bound. H8's engine hot
  paths still unpriced. H10, H14b, H26 remain the owner's.

## 0055 — 2026-07-25 — one JSON escaper for the CLI, and the signal that found the fifth copy
- did: `veil chat` escaped the user's line with a private `appendJsonStr` that stopped at `\t` and
  let every other control byte through raw. Bytes under 0x20 are illegal inside a JSON string, so
  the body is malformed and the server's parser rejects the turn — the message never sends, with
  nothing shown. Reachable by the most ordinary thing a CLI user does: paste terminal output to ask
  about it (colour is ESC, 0x1B; no newline or quote involved, so no handled case fires).
- found while fixing it: `cli.zig` had its OWN private `jstr`, also missing the arm, and it is the
  worse one. It feeds `postToolResult`, which sends a delegated tool's arbitrary OUTPUT back to a
  blocked server turn. Compiler colour, a form feed, a stray NUL — any of them makes the body
  invalid, the server rejects it, and the turn never receives its result: a stall with nothing
  printed. (Same SYMPTOM class as the lost-tool-result hang chased before; an independent mechanism,
  not a claim they are the same incident.) It also escapes `veil cast --goal` and sched prompts.
- did: four hand-rolled copies of nine lines, two broken. The two under `src/cli/` are now one
  `pub fn cli.jstr` beside the `jsonStr`/`jsonNum` helpers both modules already share.
  `gateway/http.jstr` stays separate: it returns an error union rather than swallowing, and dragging
  the gateway into the CLI path to save nine lines is the worse trade.
- ratchet, and the part worth copying: a per-module test cannot catch the NEXT copy, so
  `check.ps1 -Scan` gained a `[jsonesc]` signal — find the escape table anywhere in src/ or
  desk/src/, require an `0x20` branch near it. I had already swept the tree BY HAND and concluded
  the other ten escapers were fine. The signal immediately found an ELEVENTH my grep had missed:
  `desk/src/poller.zig:appendEsc`, differently shaped (it drops `\r`, maps `\t` to a space) so my
  pattern skipped it, and it escapes operator-typed steer text and swarm goals into a control-bus
  body. Fixed, keeping both deliberate normalisations, with a test that pins them so a later "just
  escape everything" edit is a visible choice.
- verified: test-first on both — the cli test failed at `parseFromSlice` before the fix, and the
  desk counterfactual (`c < 0x00`) fails the named test, so it runs and it bites. Scan clean, 0
  signals. Full oracle green.
- learned: my hand sweep was confident and wrong, and the mechanised check found the case my eyes
  filtered out — I searched for the shape I had just been looking at, not for the property. When a
  defect has recurred three times, the fix is not a better manual pass; it is a check that runs
  without me. Also: five copies means the recurrence was never really a bug, it was duplication.
- next: H8 engine hot paths still unpriced. Frontier 5 src + 2 desk. H10, H14b, H26, H28 owner's.

## 0056 — 2026-07-25 — H8: the prompt-prefix cache claim is now asserted, not just documented
- did: `buildTurnTools` carries an explicit promise in its header — the turn's tools block is
  "turn-stable and byte-identical across every inference of the turn, so it never re-bills the
  prompt-prefix cache" — and the same discipline is restated in four more comments around it
  (lines 280, 300, 974, 982). Nothing tested any of it; `buildTurnTools` had no test at all. That is
  H8's "faster is an unverifiable claim" in its most expensive form, because a broken prefix has NO
  local symptom: every response still looks right, the provider just re-bills the entire prefill.
  Nobody notices by using it.
- did: pinned three properties, all exactly, none with a stopwatch. (1) No grants ⇒ the static base
  is returned BY POINTER (`got.ptr == TURN_TOOLS_FULL.ptr`) and `owned` stays null — the zero-
  allocation common path, where a length or content check would pass just as happily against a
  fresh copy per turn. (2) `caps` and nothing else chooses the base. (3) With grants the base still
  LEADS the buffer unchanged, and building twice yields identical bytes — appended schemas extend
  the prompt, they never rewrite the part already cached.
- verified: src suite exit 0. Counterfactual: appending `base[1..]` instead of `base` fails the new
  test at the startsWith assertion, so it runs and it bites. Full oracle green.
- learned: the codebase was already RIGHT here — five comments describing the discipline, and the
  code honours it. That is the interesting part. A correct invariant explained five times and
  checked zero times is still one careless edit from being false, and its failure mode is a bigger
  invoice rather than a red test. Confidence in a comment is not coverage; the density of the prose
  was itself the signal that something load-bearing had no gate under it.
- ratchet: harness/TESTING.md's cost section gained the two exact non-count measures this used —
  pointer identity for "zero allocation", byte identity for "cache hit" — alongside the spawn
  counter from 0053.
- next: H8's remaining engine paths (tool round-trips per turn, context rebuilds) still unpriced.
  Frontier 5 src + 2 desk, all device/UI-bound. H10, H14b, H26, H28 are the owner's.

## 0057 — 2026-07-25 — "keep them in sync" was an instruction to a human, and it was also wrong
- did: `CHAT_SCHEMA` ends with "Defs are copied VERBATIM from SCHEMA above ... keep them in sync." Two
  hand-maintained copies of one tool contract, with a comment as the only mechanism. Edit a
  description in SCHEMA, forget the copy, and the chat veil goes on advertising the old contract to
  the model — no error, no test, just a surface promising behaviour the tool no longer has.
- found: measuring it first was the whole game. Of 19 CHAT_SCHEMA defs, 13 are verbatim, 4
  deliberately DIFFER, and 2 exist only there. The four differ for good reasons — the chat veil runs
  on the USER'S machine, so `read_file`/`list_dir`/`absorb` widen paths to absolute/`~`, and
  `recall_hive` drops "what ANY teammate contributed" because a solo veil has none. So the comment
  was not merely unenforced, it was FALSE, and a worker who believed it and "fixed the drift" would
  have deleted correct behaviour. I nearly did: my first read of the diff was "4 defs are stale".
- did: verbatim is now the rule, with the exceptions DECLARED — `CHAT_ADAPTED_DEFS` and
  `CHAT_ONLY_DEFS`, each entry carrying its reason. An undeclared difference fails; so does a
  declared exception that has stopped being one, so the lists cannot rot. Same shape as
  `KNOWN_CAP_OVERLAP` in chat/tools.zig, which is the house pattern for exactly this.
- also: `SCOUT_SCHEMA` carried the same "keep these defs in sync with their twins" line and is 14/15
  ADAPTED — its `read_file` deliberately drops SCHEMA's edit_file anchor-tag guidance, because a
  scout has no edit_file. Taken literally that line would have someone advertise a tool the mind
  cannot call. Corrected to describe what it is (an adapted subset) and to say why there is no
  verbatim rule to enforce there. No guard added: at 1/15 verbatim there is no rule, and inventing
  one to look symmetrical would be worse than the comment was.
- verified: src suite exit 0 — and the Zig guard independently reproduces the split my throwaway
  script found (13/4/2), which is the second opinion that made me trust the number. Counterfactual:
  dropping `list_dir` from the declared list fails with the tool named and both fixes offered.
  Full oracle green.
- learned: a comment that asks a human to maintain agreement is a defect report about the code, not
  a safeguard — and it should be read as evidence the invariant is UNCHECKED, not as evidence it
  holds. But check what it claims before enforcing it: two of the three "sync" comments in this file
  described a rule the code had deliberately outgrown, and mechanically enforcing either would have
  broken working behaviour. Measure first, then decide whether the comment or the code is wrong.
- ratchet: the CHAT_SCHEMA guard itself, plus both corrected headers.
- next: H8's remaining engine paths. Frontier 5 src + 2 desk. H10, H14b, H26, H28 are the owner's.

## 0058 — 2026-07-25 — isCommand vs dispatch, and a false finding I nearly filed
- did: `isCommand` carries a hardcoded list of 30 CLI verbs and its header says "Kept in sync with
  `dispatch` below" — another instruction to a human. main.zig gates on it:
  `if (cli_sub.len > 0 and cli.isCommand(cli_sub))` dispatches, and ANYTHING else falls through to
  booting the server. So a verb added to dispatch and forgotten here does not error — `veil <verb>`
  silently starts the daemon instead of running the command. Now a source audit reads dispatch's
  chain out of `@embedFile("cli.zig")` and requires every verb to be listed (the
  trio_routing_test.zig pattern).
- verified: they AGREE today, 30 for 30 — this guard keeps them agreeing, it did not fix a break.
  Counterfactual: removing `themes` fails with "'themes' is dispatched but missing from isCommand —
  `veil themes` would boot the daemon instead". Full oracle green.
- learned — the actual value of this entry. My FIRST measurement said dispatch handled four verbs
  (`absorb`, `ingest`, `status`, `sync`) that isCommand was missing, which would have been four
  working commands unreachable from the command line. I had the ledger entry half-written. It was
  wrong: my extractor bounded dispatch's body by "the next `pub fn`", and `cmdRag` further down is a
  PRIVATE `fn` that reuses a local named `sub`, so the scan ran straight past dispatch and picked up
  `veil rag`'s sub-verbs. Brace-matching the body gives 30/30. The guard now bounds on `\nfn ` OR
  `\npub fn `, and its comment says why, because the next person will reach for the same shortcut.
- learned (2): that is the THIRD ad-hoc extractor to mislead me this sitting — a hand grep that
  missed a fifth JSON escaper (0055), a `| grep | head` that returned silence instead of a verdict
  (0054), and this. The pattern is not carelessness about the code, it is trusting a throwaway
  script the way I would trust a test. A one-off extractor is a HYPOTHESIS: before reporting what it
  found, re-derive the number a second way. Brace-matching disagreed with the regex, and the
  disagreement was the whole finding.
- ratchet: the guard itself, plus a vacuity floor (`found >= 25`) so a refactor that changes the
  dispatch idiom fails loudly instead of silently scanning nothing and passing.
- next: H8's remaining engine paths. Frontier 5 src + 2 desk. H10, H14b, H26, H28 are the owner's.

## 0059 — 2026-07-25 — H12 CLOSED: the debt was phantom, the signal was the defect
- did: H12 sat in open items as "23 TODO/FIXME/HACK/XXX", and both oracles' `[markers]` signal
  reported 12. The real number is effectively ZERO. Ten of the twelve were `\uXXXX` — JSON escape
  notation inside doc comments, matched because the pattern was unbounded. The other two are the
  same comment mirrored across the httpc twins, describing a TODO in **Zig's own stdlib**
  (`netConnectIpWindows`), not ours. `\bXXX\b` cannot match inside `XXXX`, so word-bounding drops
  the whole class; both scripts now report 2, and both were checked independently before the edit.
- did: the signal, not the debt, was the thing worth fixing. One that always reports phantom work is
  one a worker learns to scroll past — and then it is worth less than nothing, because a REAL marker
  arriving later lands in noise the reader has already been trained to ignore. Its own header showed
  this had happened before (an earlier pass cut 23 to 11 by going case-sensitive) and stopped short.
- ratchet: the marker pattern is now a TWIN across check.ps1 and check.sh, and the oracle-parity
  signal compares GATES only, so nothing policed it — the two scans are deliberately different sizes
  and wholesale parity would be wrong. So: pin the one thing that must match. check.ps1 now fails the
  scan if check.sh's pattern differs.
- verified: both scans report 2 and agree; counterfactual desyncs check.sh's pattern and the new
  signal fires, 0 signals after restore. Full oracle green.
- learned: my FIRST counterfactual for that guard did nothing — the `sed` was over-escaped, check.sh
  was never modified, the guard correctly stayed silent, and I read the silence as "the guard is
  worthless". I was a step from deleting a check that works. A counterfactual has TWO halves, inject
  and observe, and only the second is ever looked at. Every earlier one this sitting printed an
  injection count (`grep -c` after the edit) and this one did not, which is exactly why it fooled me.
  That is now a rule in TESTING.md: no injection count, no counterfactual.
- next: H8's remaining engine paths. Frontier 5 src + 2 desk, all device/UI-bound. H10, H14b, H26,
  H28 are the owner's.

## 0060 — 2026-07-25 — H11 CLOSED: the stand-in gateway already existed, it just could not be reached
- did: H11 asked for an in-repo mock-LLM server so live routing could be tested without an external
  endpoint. Before building one I went looking, and `config/local_models.zig` already had it: a
  careful canned loopback server (binds a scanned port, counts connections, drains the request head
  first so httpc's write-then-read cannot reset the peer, and a `stop` that dials its OWN port so a
  serve loop parked in `accept` always wakes). Private, and named `FakeOllama` for its one caller.
  So the increment was to SHARE it, not write a second one — `src/worker/fakehttp.zig`, lifted
  verbatim so the move cannot change behaviour, with local_models aliasing it. Copying instead would
  have created exactly the twin 0055 spent an entry collapsing.
- did: `llm.chat()` now runs against it through the REAL path. Loopback plain-http takes the
  in-process branch (no curl child, no scratch files), so `httpc.request` dials the fake and
  `completeBody` parses a genuine provider-shaped `{"choices":[{"message":{"content":…}}]}`. The
  test asserts the returned text AND `conns == 1` — without the second, a path that short-circuited
  before the request (a cache, an early return, a mock branch) would satisfy every other assertion.
- verified: src suite exit 0. Counterfactual with the injection PRINTED first (0059's new rule):
  expecting the wrong string fails the named test, so it genuinely runs rather than skipping on a
  busy port. Full oracle green.
- learned: "build a mock server" was the wrong framing and I nearly took it at face value. The open
  item described a MISSING capability when the real state was an UNREACHABLE one — the difference
  between a day's work and moving 76 lines. Read the row, then go look; an item written months ago
  describes the tree as it was, and this one had been overtaken by 0044's local_models work without
  anyone updating it. Same failure as H4's stale count and H12's phantom debt: three of the rows I
  have touched this sitting were wrong about their own subject.
- ratchet: fakehttp.zig's header names its callers and states why it is shared rather than copied,
  so the next person reaching for a canned server finds it instead of writing a third. The new file
  also immediately tripped `[docs]` ("no docs-src case file"), which was the signal doing its job:
  its exclusion covered `tests.zig` and `*_test.zig` but not a shared test HELPER, which has no
  shipped behaviour to write a case file about. Renaming it `*_test.zig` to dodge the check would
  claim it contains tests when it has none — so the exclusion now reads a `//! TEST-ONLY` doc
  header, which cannot drift from what the file IS the way a filename convention can. Counterfactual
  with the injection printed: strip the header and it is flagged again.
- next: capture the REQUEST body in fakehttp (see H11-DONE) — that turns trio routing, the tools
  array and the temperature quirks into end-to-end assertions instead of source audits. H8's
  remaining engine paths. Frontier 5 src + 2 desk. H10, H14b, H26, H28 are the owner's.
