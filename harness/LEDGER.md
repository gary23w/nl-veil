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
| H4  | low | Coverage frontier, RECOUNTED 0053 — the old row said "31 src + 8 desk" and was ~25 modules stale; an open-items row that lies is exactly the drift this harness exists to catch, so recount before trusting any row here. RECOUNTED 0091 — now **4 src + 1 desk**: `cli/chat`, `cli/exec_tool`, `browser/{broker,session}`, `desk/tray` (`plan/billing_seam` covered 0054, `browser/host` 0066, `desk/main` 0069). `worker/fakehttp.zig` also carries no tests and is NOT counted: it is the TEST-ONLY canned server, and a harness has no shipped behaviour to test — the same reasoning the `[docs]` signal uses to exempt it (0077). The remainder really is thin: what is left in them is smoke harnesses that drive a real browser, plus helpers like `clip`/`pStr` whose only consumer is a debug print. Testing those would move the number without protecting anything -- say so rather than closing this row with theater. Read 0044 before accepting "device-bound" as the reason: four modules carrying that label turned out to be mostly testable, and one hid a real invalid-free bug. `plan/billing_seam` is the odd one out and the one to take first — neither device- nor UI-bound, and it is money. |
| H8-DONE | closed 0065 | "Faster" is no longer an unverifiable claim: every cost claim in the tree that HAS a choke point is now pinned, counted and never timed (a wall-clock budget on a dev box measures Defender, flakes, and gets muted). Pinned: `Neuron.exec` spawns — reading N records = N+1 (0053); `Mem.run` spawns — `observeBatch` = 1 for N facts vs N for the loop it replaced (0063); `buildTurnTools` — POINTER identity for "zero allocation", BYTE identity for the chat prompt prefix (0056); run.zig's swarm system prompt — the stable-prefix SHAPE, guarding a measured 21.6%→81.1% cache-hit gap (0064). The row previously also named "context rebuilds" and "tool round-trips per turn": both re-derived and neither is real work. context.zig is pure, 13 tests, makes no cost claim; `MAX_ITERS = 24` is a safety CEILING with a documented rationale, not an optimization, and asserting a constant equals itself is tautology. REOPEN only on a NEW claim with a real choke point — do not manufacture gates to fill this row. |
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

## 0061 — 2026-07-25 — the fake gateway now records what we SEND
- did: 0060's stand-in drained the request and threw it away, so the tests could only prove we PARSE
  a response. Everything about what leaves the process — which URL, which model, whether the system
  prompt is attached at all — was still "verified" by reading the source. A provider only ever sees
  that side. `fakehttp.Server` now captures the first request (head + body) and exposes it via
  `request()`, and a new llm test asserts the POST path is `/v1/chat/completions` (the OpenAI route,
  not Ollama's native one — wrong here is a 404 against a real provider), that the caller's model
  reaches the wire rather than a default or the trio fallback, and that BOTH roles are present in
  order. A silently dropped system prompt degrades every answer without failing anything.
- FOUND IN MY OWN CHANGE, before commit: `startAt` did not initialise `req_len`. Callers declare
  `var srv: Server = undefined` — they must, since the serve thread holds a pointer and the struct
  cannot be copied into place — and `= undefined` skips field defaults. So `req_len` was garbage,
  and `capture`'s `req.len - req_len` would underflow and memcpy past a 32 KB buffer. The suite went
  GREEN anyway: the garbage happened not to be 0, so `first` was false and `capture` was never
  reached. A passing run proved nothing about the path that mattered. Initialising in `startAt` is
  the fix — an invariant belongs to the thing that establishes it, not to every caller.
- verified: src suite exit 0; counterfactual (injection printed) on the path assertion fails the
  named test. Full oracle green.
- learned: a field default is a trap on any struct that must be initialised in place. `= undefined`
  is not an unusual way to write these — it is the ONLY way when a thread takes a pointer to the
  struct — so `req_len: usize = 0` reads like a safety net while providing none. Worse, the failure
  is silent and load-bearing on garbage: green today, out-of-bounds write tomorrow when the stack
  happens to hold a zero. I only caught it by asking why the first test still passed when it never
  set the field.
- ratchet: the comment on that line says WHY it cannot rely on the default, so the next person does
  not "tidy" the assignment away.
- next: I first wrote here that trio routing could now be tested end to end and that this "would
  retire the source-audit half of trio_routing_test". WRONG, corrected before commit — read that
  file's header. The label→role mapping is not data, it is TEN hand-written positional argument
  lists threaded through helper chains, where swapping `think` for `prompt` still type-checks and
  still passes everything. The audit re-derives all ten exhaustively; a live wire test would cover
  only the one or two call sites it happened to exercise and would miss precisely the misroute the
  audit is built to catch. It is the right tool, not a placeholder for one. Do not replace it.
  Remaining: H8's other engine paths. Frontier 5 src + 2 desk. H10, H14b, H26, H28 are the owner's.

## 0062 — 2026-07-25 — the constitution was telling workers to wave through a hang
- did: after finding THREE open-item rows wrong about their own subject (H4, H12, H11), I turned the
  same suspicion on the docs a fresh worker reads FIRST. CLAUDE.md said: "The desk suite's final net
  test needs a live server on :8787 — until it's hermetic (ledger item H2), the earlier tests are the
  verdict when only that one hangs." Wrong three ways. H2 was CLOSED in ledger 0006. The test
  (`desk/src/netcli.zig`) early-returns without `../data/.desktop_key`, so it needs no server. And
  since the bounded-httpc rework every call carries a hard timeout, so it cannot hang.
- why it mattered more than an ordinary stale line: it did not merely misinform, it INSTRUCTED —
  "the earlier tests are the verdict when only that one hangs" trains a worker to accept a hang as
  expected and move on. A real hang in the desk suite would have been waved through by anyone
  following the constitution correctly. A wrong fact costs a re-derivation; a wrong instruction
  costs the thing the instruction was protecting.
- did: corrected it to state the suite is hermetic and a hang is NOT normal, kept the fact that is
  still true and useful (when a server happens to be up, that test casts a 1-minute mock swarm at
  it, so it side-effects a live instance), and filled two Map gaps — `harness/TESTING.md` and
  `SELF-LANE.md` existed but the Map listed neither, and `scripts/check.sh` (what CI actually runs)
  was absent beside check.ps1. Added fakehttp.zig so the next worker finds it before writing a third
  stand-in.
- did: HORIZON.md's Ring 1 read as entirely future when most of it had landed — `doctor --growth` is
  live, the scan set has grown to nine signals, hermetic desk tests turned out already true. Marked
  LIVE / PARTLY honestly, with H8's remaining half stated concretely rather than as an aspiration.
  A roadmap that lists finished work as pending gets a worker to rebuild it.
- verified: full oracle green. Every claim re-derived against the tree before writing it, per 0060.
- learned: staleness concentrates in the documents NOBODY re-reads while working — the ones read
  once at the start and then trusted. Four of the five wrong things I have found this sitting were
  in exactly those (three ledger rows, one constitution line); none were in code comments next to
  code people edit. Prose adjacent to working code gets corrected by whoever touches the code;
  orientation prose has no such gardener. Re-derive it on a schedule, not on suspicion.
- ratchet: none new — this WAS the ratchet (the harness's own orientation docs made true).
- next: H8's remaining engine paths. Frontier 5 src + 2 desk, genuinely device/UI-bound. H10, H14b,
  H26, H28 are the owner's.

## 0063 — 2026-07-25 — Mem.observe returned 0 for every successful write
- did: went after H8's remaining half — the engine's hot paths — and picked the hottest: hive memory.
  `Mem.run` is the single `std.process.run` in oscillation.zig (its header even says "one seam for
  all memory traffic, the place to instrument"), so it takes an `is_test` spawn probe exactly like
  `Neuron.exec` (0053). `observeBatch` claims "ONE neuron subprocess instead of one spawn per fact",
  because a 40-tool storm used to pay ~40 serialized launches on the turn's tail. Nothing priced it,
  so folding it back into a loop of `observe()` — the obvious simplification, which still passes
  every behavioural test since the facts land either way — would silently restore the whole cost.
  Now pinned: 5 notes = 1 spawn, the loop it replaced = 5, single-note path = 1.
- FOUND because the first counterfactual PASSED. Folding the batch into a loop should have failed
  the new test; it did not, which meant the test was not running. Cause: its liveness probe was
  `if (m.observe(...) == 0) return error.SkipZigTest`, and **`Mem.observe` returns 0 for every
  successful write**. It parses stdout with `parseInt`, and neuron prints PROSE — `stored 1 fact(s)`
  — which never parses. Fixed with `--json` + `jsonUint("wrote")`.
- the sharp part: this is the SAME bug already found and fixed one screen below, in `observeBatch`,
  whose comment reads "--json is load-bearing: the non-json summary prints to STDERR ... parsing it
  from stdout always yielded 0, under-reporting every batch". Somebody hit this exact symptom, wrote
  it down, fixed their function, and the sibling kept the bug. A fix applied to one instance and a
  note explaining it is not the same as fixing the class — the note only helps whoever reads THAT
  function.
- impact, stated honestly: LOW. The only consumer of the return value is run.zig's MOCK path, which
  reads `if (facts > 0) facts else round` — the fallback made the always-0 invisible, and the live
  path counts `observed` separately. It broke a test's liveness probe, not a user's data.
- verified: src suite exit 0. Counterfactual now fails the named test with the injection printed
  first (0059's rule) — so the test runs, which is the thing the first attempt could not claim.
  `--json observe` confirmed against the real binary before relying on it; observeBatch already
  depends on `--json import`, so the flag is not a new assumption.
- learned: I wrote 0053's "a SKIP is a test reporting it did not run" rule and then shipped a test
  that skipped, in the same sitting. Reading the rule is not applying it. What caught it was the
  counterfactual, not vigilance — which is the argument for running one EVERY time rather than when
  a test feels risky. A test whose liveness probe depends on a return value nobody checks is a test
  that will quietly stop running the moment that value goes wrong.
- ratchet: the spawn probe on the second neuron-db seam, and TESTING.md's cost section now names
  both probes.
- next: H8's remaining paths (context rebuilds, tool round-trips per turn). Frontier 5 src + 2 desk.
  H10, H14b, H26, H28 are the owner's.

## 0064 — 2026-07-25 — the swarm's stable-prefix contract, guarded
- did: run.zig carries a MEASURED cache contract in a comment: the system message's head holds only
  per-run-stable content, and everything per-mind or per-round rides the tail, because a provider's
  KV cache serves a request only up to the first byte that differs. The mind's NAME used to sit at
  byte 8 ("You are {name}, ..."), so N minds forked N cache lineages, each separately re-billing
  ~11.2 KB of doctrine that was byte-identical between them. Cast-355797 measured it: the swarm got
  21.6% cached tokens while a chat turn on the SAME model and endpoint in the same ten minutes got
  81.1%. Identity was moved to the tail. Nothing enforced that it stays there.
- did: a source audit of the format string — 4 substitutions before the `YOU, SPECIFICALLY` marker
  (the run-stable clauses), 3 after (mi.name, w.roster, space_clause), plus a check that those three
  really are the trailing args in placeholder order, plus a vacuity guard that the marker sits past
  the literal's midpoint so the "stable head" cannot be shrunk to nothing and still pass.
- why a source audit and not a live assertion: same reason as trio_routing_test (see its header) —
  the invariant lives in the SHAPE of one allocPrint, not in data any runtime value exposes. There
  is nothing to call that returns "the prefix"; there is only the argument list.
- verified: src suite exit 0. Counterfactual, injection printed first: putting `{s}` for mi.name
  back at the head — the natural-sounding edit, since a reader expects identity first — fails the
  named test. Full oracle green.
- learned: this is the most expensive class of regression in the tree and the least visible. Every
  answer stays correct, every test stays green, and the only symptom is the bill. The comment even
  says WHY the name has to be in the awkward place ("the cost of that move is that identity is no
  longer the first thing the model reads"), which makes moving it back a plausible, well-intentioned
  edit — precisely the kind a guard has to catch, because review will not.
- ratchet: the audit itself; and it names the measured numbers in its failure message, so whoever
  trips it learns the cost rather than just the rule.
- next: H8's remaining unpriced paths are context rebuilds and tool round-trips per turn. Frontier
  5 src + 2 desk. H10, H14b, H26, H28 are the owner's.

## 0065 — 2026-07-25 — H8 CLOSED, and the half of it that was never real
- did: closed H8 by finishing the real half and DELETING the imaginary half rather than building
  gates to fill it. Everything in the tree that makes a cost claim AND has a single choke point is
  now pinned, counted rather than timed: spawns on both neuron-db seams (`Neuron.exec` N+1 per N
  records, 0053; `Mem.run` 1 vs N for observeBatch, 0063), pointer identity for buildTurnTools'
  zero-allocation path and byte identity for the chat prompt prefix (0056), and the SHAPE of the
  swarm system prompt that protects a measured 21.6%→81.1% cache-hit gap (0064).
- did: the row's other two named items were re-derived and are not work. `context.zig` is pure
  helpers with 13 tests and makes no cost claim at all — "context rebuilds" named a thing that does
  not exist. "Tool round-trips per turn" is `MAX_ITERS = 24`, a safety CEILING with a documented
  rationale, not an optimization; a test asserting a constant equals itself would be pure theater.
  Both removed from the row with the reasoning, and the row now says REOPEN ONLY ON A NEW CLAIM.
- learned: the pull to write those two gates anyway was real — they were named in an open item, the
  session had momentum, and two more green tests would have looked like progress. But a gate that
  pins a constant to itself does not protect anything; it adds a file to maintain, a line to the
  suite, and a false sense that the area is covered. Deleting a phantom item is worth more than
  satisfying it, and is harder to do because it produces no artifact. That is the FOURTH row this
  sitting that was wrong about its own subject (H4 count, H12 phantom debt, H11 framing, now H8's
  back half) — the open-items table has been the least reliable document in the harness, which is
  why 0060 put "re-derive the row before you act on it" into the skill's PICK step.
- verified: full oracle green; scan 0 signals.
- ratchet: none new — this increment REMOVED work rather than adding a mechanism, which is the
  ratchet the HORIZON principle "if a harness piece isn't earning its keep, prune it" asks for.
- next: no priced-cost work remains without a new claim. Frontier is 5 src + 2 desk, genuinely
  device/UI-bound. H13 is a watch item. H10, H14b, H26, H28 are the owner's decisions.

## 0066 — 2026-07-25 — the discovery file, which decides where browser traffic goes
- did: `browser/host.zig` sat on the frontier labelled device-bound. Most of it is (spawning a
  daemon, pinging it), but `writeDiscovery`/`readInfo` are a plain write→read pair over a JSON file
  and needed no browser at all — 0044's lesson exactly, that the label is usually unexamined. That
  file is how a tool call FINDS the machine's browser daemon: it carries the port to dial and the
  token that authorises the dial, so a stale or half-written one must read as ABSENT rather than as
  a half-valid daemon somewhere arbitrary.
- did: pinned the round trip and every malformed shape — missing file, `port: 0` (the broker never
  bound; reading it live would dial port zero), non-JSON truncation, and both token-length failures.
  The short/long token cases are the sharp ones: `Info.token` is a fixed `[32]u8` filled by
  `@memcpy`, and the `token.len != 32` check is the only thing between a truncated file and a read
  past the parsed slice. Also pinned that unknown fields are IGNORED — a newer daemon may publish
  more and an older client must still find it — and that `discoveryPath` honours TEMP/TMP/TMPDIR and
  degrades to a relative path rather than returning null (the daemon must not become unfindable).
- verified: src suite exit 0. Counterfactual with the injection printed: relaxing `!= 32` to `< 32`
  — the plausible edit, since "at least 32" reads permissive rather than wrong — fails the
  long-token assertion, because it would silently truncate instead of refusing. Full oracle green.
  Registered DIRECTLY in src/tests.zig (0029).
- learned: "device-bound" was again a label rather than a finding. Four modules were written off
  that way in 0044 and turned out mostly testable; this is the fifth. But the REMAINDER of the
  frontier is now genuinely thin — smoke harnesses that drive a real browser, and helpers like
  `clip`/`pStr` whose only consumer is a debug print. Testing those would move H4's number without
  protecting anything, so the row now says so instead of inviting the next worker to close it.
- ratchet: H4 recounted (4 src + 2 desk) and annotated with WHY the rest should stay uncovered —
  a coverage row that does not say where to stop is an invitation to write theater.
- next: nothing worker-actionable but H4's genuinely-thin remainder. H13 is a watch item. H10, H14b,
  H26, H28 are the owner's decisions.

## 0067 — 2026-07-25 — a memory-safety sweep that found nothing, and the one footgun it left behind
- did: with the open items exhausted and the scan at 0 signals, went looking for NEW signal rather
  than manufacturing work (SENSE's field of candidates, minus the sources that were empty). Picked
  the class 0066 had just tested: a fixed-size `@memcpy` whose only protection is a length check.
  In ReleaseFast — the server's default — bounds checks are OFF, so a weak guard there is a real
  overflow rather than a panic.
- verified CLEAN, which is the result: 463 `@memcpy` sites, and every one with a fixed-size
  destination is properly guarded. `cli.zig` clamps with `@min`; `tools.zig` copies between two
  `[32]u8` whose sizes match at compile time; `audit_log` gates on `hash.len == 64`; `host.zig` on
  the `!= 32` check pinned in 0066. Recorded so the next worker does not repeat the sweep — a clean
  audit is only worth something if somebody can tell it happened.
- did (small, and honestly hardening rather than a fix): `desk`'s `attachServerTurn` fills
  `sc_conv[64]` from `conv` with NO internal length check. Not a live bug — its one caller checks
  `id.len <= sc_conv.len` first. But the sibling doing the same copy (`startServerChat`) checks
  INSIDE itself, so the two paths carried different contracts, and a second caller added without the
  call-site check would slice out of bounds and crash the desk. One line, and they now agree.
- learned: the honest output of an audit is often "nothing". The pull is to find SOMETHING to
  justify the looking — and the nearest available something was a safe function I could describe
  alarmingly. Naming it hardening rather than a fix, and saying plainly that the sweep found no
  bugs, is the difference between a ledger a worker can trust and one that inflates. 0065 deleted
  phantom work; this entry declines to invent some.
- verified: desk suite exit 0, full oracle green.
- ratchet: none — this is the second entry in a row whose value is subtractive (a sweep closed, an
  item deleted). Both are legitimate; not every increment leaves a mechanism behind.
- next: nothing worker-actionable remains. H13 is a watch item. H10, H14b, H26, H28 are decisions
  for the owner, and H4's remainder is documented as deliberately uncovered.

## 0068 — 2026-07-25 — the plugin sandbox's file boundary, tested adversarially
- did: went looking for a boundary nobody had stress-tested and picked the Lua plugin sandbox — a
  plugin is untrusted third-party code the user installed, so if it can walk out of its folder it
  reads the vault db, `.desktop_key`, and everything else under the data dir. The escape classes the
  author had already thought about were covered (bytecode via `load`, instruction budget, memory
  cap, stdlib whitelist). The FILE boundary was not.
- audited first, and `require` is airtight for a reason worth writing down: module names are
  restricted to `[A-Za-z0-9_.]` — no separators — and then every `.` is rewritten to `/`, so a
  literal `..` cannot survive into the path even when the name is `..`. Two independent properties,
  either of which alone would be enough.
- did: `veil.read_file` (plugins.zig) rejects empty, leading `/` or `\`, a drive letter, and `..`
  ANYWHERE rather than only as a leading segment. Correct, and untested — the existing test near it
  exercises the POLICY gate for the name "read_file", not the path guard. Now driven end to end: a
  real plugin whose Lua handler calls `veil.read_file`, so the test hits the guard exactly as a
  third-party plugin would, not a predicate lifted out for convenience.
- the shape that makes it worth something: a CANARY. A real file with known contents sits outside
  the plugin folder, and every refusal is asserted alongside "the canary never appears in the
  answer". Without it, `nil` proves only that a path was bad — not that the file was unreachable.
  And the ALLOWED read is asserted FIRST: a guard that refuses everything is not a guard, it is a
  broken feature that looks secure, and every refusal below it would be vacuous.
- verified: src suite exit 0; eight escape shapes refused (`..` leading, doubled, and BURIED behind
  a real segment; backslash; absolute posix; UNC; drive letter; empty). Counterfactual with the
  injection printed: deleting the `..` check makes the test report
  `ACCEPTED an escaping path: '../../escape-target.txt' -> READ:outside-the-sandbox-canary` — an
  actual demonstrated escape, which is the proof the canary exists to produce. Full oracle green.
- learned: the audit found no bug, and the test still earned its place. "Already correct" and "will
  stay correct" are different claims, and for a security boundary the second one needs a mechanism.
  This is the distinction 0067 got right by declining to invent a bug: report the audit honestly,
  then decide separately whether the boundary deserves a guard. Here it does.
- ratchet: the test itself, and the canary pattern written into its comments so the next security
  test copies the structure (assert the allowed case first; prove the target is reachable-in-
  principle; assert the secret never appears rather than only that an error came back).
- next: nothing worker-actionable outstanding. H13 watch; H10, H14b, H26, H28 owner's.

## 0069 — 2026-07-25 — the biggest untested file in the tree, and the rounding bug inside it
- did: measured coverage against SIZE rather than trusting the frontier list, and one file dwarfed
  everything: `desk/src/main.zig`, 7,930 lines and ZERO tests (next worst: run.zig 10.5k/64,
  chat.zig 14.2k/116). It sits under H4's "UI-bound" label, and most of it genuinely is — but 7.9k
  lines is a lot to write off wholesale, and the small pure helpers UNDER the drawing need no
  window. It now has the first tests in its history, and main.zig is registered in desk/tests.zig.
- FOUND: `fmtSize` computed its tenths digit as `(sz % MiB) / (105 * 1024)`. A tenth of a MiB is
  104,857.6; the divisor used is 107,520 — 2.5% high, so the fraction always read LOW. 1.5 MiB
  rendered as "1.4M", and 54 of the tenth-steps under 10 MiB were off by one. Cosmetic, but wrong
  everywhere it showed. `fmtCount` right beside it uses exact powers of ten.
- the fix is the interesting part: the OBVIOUS repair, `/ (1024 * 1024 / 10)`, is wrong the other
  way — integer division gives 104,857, so a remainder of 1,048,575 yields 10 and prints "1.10M".
  `rem * 10 / MiB` is exact and cannot leave [0,9] because rem is always < MiB. The test walks
  1→4 MiB on a 9,973-byte stride asserting the fraction stays ONE digit, which is what would have
  caught the naive repair.
- also pinned: `fmtCount`'s thresholds and its "?" degradation on a too-small buffer; `wrap`'s
  forward/backward cycling at both edges; and `fmtConvWhen`, clock-anchored through its `now_s`/`tz`
  parameters — including the zero-padded UNSIGNED clock, which the code comments record as having
  once rendered "+8:+0", and that a tz offset moves which local day a timestamp lands on.
- noted, NOT changed: `wrap(cur, delta, n)` evaluates `n - 1` when the index goes negative, so
  `n == 0` underflows. Its only call site passes a comptime 3-element array, so it is unreachable —
  recorded in the test as a note for whoever gives it a runtime-sized list, rather than adding a
  guard to a path that cannot happen (0067's line: hardening is fine, inventing a bug is not).
- verified: desk suite exit 0; counterfactual with the injection printed — restoring `105 * 1024`
  fails `main.test.fmtSize`, which also proves main.zig is genuinely COLLECTED and not silently
  skipped (0053). Full oracle green.
- learned: "UI-bound" hid the largest untested surface in the repo, and a coverage row organised by
  MODULE COUNT (H4: "4 src + 2 desk") made it invisible — six modules sounds small, but one of them
  is 7.9k lines. Count what the number is standing in for, not the number.
- next: H13 watch; H10, H14b, H26, H28 owner's.

## 0070 — 2026-07-25 — the at-rest key that fails to save and says nothing
- did: every real bug this sitting shared ONE shape — silent failure (an escaper that dropped
  messages, `Mem.observe` returning 0, a test that skipped, `stored 0 fact(s)` at exit 0). So I
  measured for it directly: writes whose failure is swallowed. 1,274 `catch {}` sites tree-wide, 72
  of them on `writeFile`. Most are legitimately best-effort (swarm journals, draw calls, cleanup).
  Two were not, and they behave very differently.
- `obs/audit_log.zig`'s append swallows its write, but that DEGRADES SAFELY: a missing entry breaks
  the hash chain, so `verify()` reports it. The failure announces itself later. Left alone.
- `config/key_vault.zig`'s `deriveServerKey` does not. It generates the at-rest key, fails to
  persist it silently, and returns it anyway — so this boot seals every stored provider key with a
  key that was never written down, the next boot generates a different one, and nothing sealed today
  can ever be opened again. No error, anywhere, at any point. The damage accrues for the life of the
  process and only surfaces after a restart, far from the cause.
- did: the swallow STAYS (the server must boot), but it now logs — with the consequence and the two
  fixes (data-dir permissions, or set NL_SECRET so the key is derived rather than stored). `warn`
  not `err` on this repo's own precedent: `seedDefaultAdmin` logs the default-password condition at
  warn — serious, security-relevant, operator-fixable, process continues. Same shape. It also keeps
  the case testable, since Zig's runner fails any test that logs an err, so `err` could only be
  asserted by never exercising it — the wrong trade for a diagnostic whose whole job is to fire.
- did: pinned the combination the existing tests cannot reach. The invariant test covers a WRITABLE
  data dir; the NL_SECRET test covers an unwritable one but with a secret set, where the file is
  irrelevant. Untested until now: no secret AND unwritable — the only path that loses data. The test
  asserts the key is still usable (the server boots), that two calls DIFFER (which IS the loss), that
  sealing round-trips within one boot, and that the next boot's key cannot open it.
- verified: src suite exit 0. Counterfactual with the injection printed: making the unpersisted key
  stable fails BOTH the new test and the pre-existing invariant test. Full oracle green.
- learned: the sweep was aimed at a SHAPE rather than a place — "where does a failure go unreported"
  — and that is what found a site no coverage or scan signal pointed at. Also worth separating: the
  code was not wrong, it was UNOBSERVABLE. Those need different fixes, and conflating them produces
  either a bogus bug report or a missing diagnostic.
- ratchet: none new; the log line and the test are the mechanism.
- next: H13 watch; H10, H14b, H26, H28 owner's.

## 0071 — 2026-07-25 — a clean audit, and the coupling it left unguarded
- did: kept measuring SHAPES rather than places. This one: `bufPrint(...) catch "<constant>"`, which
  degrades a too-small buffer into a FIXED STRING instead of an error. 93 sites. Harmless in status
  text ("subtask", "waiting on the hive"), but dangerous anywhere the result is an IDENTIFIER —
  two distinct things collapsing to one constant is a collision, not a cosmetic bug.
- audited the identifier-shaped ones and they are CLEAN. `plan/neurons.zig`'s `n_{d}` cannot overflow
  a [24]u8. `key_vault.zig`'s `scopeKey` ends in `catch ""`, and an empty scope key WOULD be a
  cross-tenant collision — two users' vault records in one neuron-db scope, each able to read and
  overwrite the other's provider key — but it is unreachable, because three separate facts line up:
  the buffer is a typed `*[80]u8` (compile-time, every call site), `validProvider` caps the provider
  at 32, and BOTH write paths (`put`, `putOAuth`) validate before calling it. Longest possible key:
  3 + 20 + 1 + 32 = 56 of 80.
- did: pinned the COUPLING, which is the part nothing guarded. There was already a test on the
  32-char cap — in isolation. Nothing said why 32 matters, so raising it to 64 while leaving the
  buffer at 80 would make the collision reachable with the existing test still passing on its own
  terms. The new test states the relationship: the worst case that can reach `scopeKey` (max u64 uid
  + max-length provider) still fits with headroom and never returns "".
- verified: src suite exit 0; counterfactual with the injection printed (cap 32 → 64) fails BOTH the
  new test and the pre-existing cap test. Full oracle green.
- learned: the useful output was not a bug, it was a MISSING EDGE. Two facts were each guarded and
  the line between them was not, which is the same shape as every twin-drift defect in this ledger —
  only here the two things that must agree are a constant and a buffer size in different functions.
  Worth asking of any invariant that rests on several facts: is each one pinned, or is their
  RELATIONSHIP pinned? Only the second survives someone editing one of them for a good reason.
- ratchet: the coupling test.
- next: audit yield is falling — four sweeps this stretch (result enums, fixed-size memcpy, security
  claim strings, constant-degrading bufPrint) found no bugs; the fifth (swallowed writes, 0070)
  found a diagnostic gap. The tree is in genuinely good shape. H13 watch; H10, H14b, H26, H28 owner's.

## 0072 — 2026-07-25 — the comment that says "must match", now enforced
- did: applied 0071's lens — pin the RELATIONSHIP, not just the facts — to the instance the code
  flags itself. `desk/src/chat.zig` declares `cast_conv: [64]u8` with the note "(must match
  sc_conv[64]: startServerCastWatch copies sc_conv here, and a >40-byte conv id would otherwise
  silently no-op the server-cast display)". That is a comment asking a human to keep two array sizes
  in different declarations equal — the same class as 0057's `CHAT_SCHEMA` "keep them in sync" and
  0058's `isCommand`/`dispatch`.
- the failure mode is the one this repo keeps producing, not a crash: the copy IS guarded
  (`conv.len > cast_conv.len` returns early), so shrinking `cast_conv` is memory-safe. It just means
  a conv id that fits `sc_conv` and not `cast_conv` makes the guard fire and the server-cast display
  SILENTLY stops watching. Nothing errors, nothing logs, the panel never updates. The comment's own
  author saw this — "would otherwise silently no-op" — and wrote a note instead of a check.
- did: one test asserting the two lengths are equal, plus a floor (>= 64) so shrinking BOTH together
  is caught too. Reading `.len` of a fixed-size array is comptime, so `const c: Chat = undefined`
  touches no memory — the type is the whole subject.
- verified: desk suite exit 0; counterfactual with the injection printed (cast_conv 64 → 32) fails
  the named test. Full oracle green.
- learned: three "keep X in sync" comments have now been converted to checks in this ledger (0057,
  0058, 0072), and all three were written by someone who had ALREADY reasoned out the failure — the
  comments describe the exact bug that would result. The knowledge was never missing; only its
  enforcement was. A comment that predicts a specific failure is a test that has not been written
  yet, and it is worth grepping for that phrasing on purpose rather than waiting to trip over it.
- ratchet: the size-equality test.
- next: audit yield has fallen to near zero on fresh sweeps; the productive vein is now converting
  the tree's own "must match" notes into checks. H13 watch; H10, H14b, H26, H28 owner's.

## 0073 — 2026-07-25 — "must match EXACTLY" had four copies
- did: followed 0072's vein — comments that PREDICT a specific failure are tests nobody wrote — and
  grepped for "must match / must stay / must agree". `run.zig`'s promote gate carried the sharpest:
  "The condition must match trackConvergence's own `has_score` EXACTLY (status .ok AND total > 0) —
  it is the only thing that writes best_pct, so gating on a broader condition would compare against
  a best_pct that never moves and block promotion for the whole run."
- found: FOUR copies of that predicate in one file — the promote gate (1517), trackConvergence's
  `has_score` (8801), `fitnessSource` (1838), and a fourth at 1432 carrying an extra clause. The
  comment asked a human to keep two of them identical and did not know about the other two.
- did: made it structural instead of asserted. `BenchResult.hasScore()` is now the single predicate
  and all four sites call it, so there is nothing left to keep in sync — the same move as 0055's one
  escaper and 0060's one canned server, which is now three times this has been the right answer.
- verified: src suite exit 0; counterfactual with the injection printed — broadening it to
  `status == .ok`, the exact drift the comment describes, fails the new test. Full oracle green.
- learned: the comment was RIGHT, specific, and load-bearing, and it still lost — because a note can
  only reach whoever reads that function, and the predicate had spread to three others. That is the
  same lesson as 0063's `Mem.observe` (a fix plus a note beside it, while the sibling kept the bug).
  Prose scales with readers; structure scales with the codebase. When a comment says two things must
  agree, the question is not "is it still true" but "can I delete the comment by making it
  impossible to violate".
- ratchet: the shared predicate + its test; the "must match" grep is now a named vein in this ledger
  for the next worker (0072 converted one, this converted another; `run.zig:9829`'s saturating-op
  pair is the next candidate and is NOT yet done).
- next: H13 watch; H10, H14b, H26, H28 owner's.

## 0074 — 2026-07-25 — CORRECTION to 0073, and the "must match" vein is mined out
- correction: 0073's `next:` line says `run.zig:9829`'s saturating-op pair "is the next candidate and
  is NOT yet done". That is WRONG, and it shipped. Line 9829 sits INSIDE a test — `test
  "neuronsForCfModel agrees with the control plane's rate table on every row (the copies must not
  drift)"` — which walks every rate row and then asserts both implementations agree at
  `maxInt(u64)` on each side, which is exactly the saturation case the comment describes. The
  coupling was fully enforced before I named it as outstanding. I grepped for the PHRASE and wrote
  down the hit without reading what surrounded it — the same shortcut that produced the phantom
  "four broken CLI commands" in 0058 and the phantom marker debt in 0059.
- swept the rest of the vein properly this time, reading each hit's context:
  * ALREADY ENFORCED: `neuronsForCfModel` (above); `chat/sync.zig`'s `safeSyncPath` ("the shared
    checker every side applies" — already one function, and tested); `engine.zig:460`'s "the gate and
    the schema must agree" (inside the turn-tools test); `neuron/client.zig`'s "the listing must stay
    clean" (0042 + 0053); `locs/atlas.zig:911` (inside a test).
  * NOT COUPLINGS: `http.zig:65` (an OAuth redirect matching something registered with the PROVIDER —
    external, unenforceable here), `main.zig:221` (console-subsystem, a link setting),
    `context.zig:4` and `engine.zig:5681` (design statements, not two things that must agree).
  * CONVERTED: 0072 (`cast_conv`/`sc_conv` sizes), 0073 (`hasScore`, four copies → one).
  So the vein yielded two real conversions out of eleven candidates, and is now exhausted.
- learned: I found this while following up on my own "next" line — which is the only reason it
  surfaced. A ledger entry's forward-looking claims get acted on by someone who trusts them, and
  they are written at the point of LEAST verification: the end of an increment, about work not yet
  started. Everything else in an entry describes something just done and checked. Treat `next:` as
  the least reliable line in any entry, mine included, and re-derive before acting (0060's PICK rule
  applies to entries, not just the open-items table).
- verified: full oracle green (ledger-only change, run for the discipline rather than the risk).
- next: nothing outstanding in this vein. H13 watch; H10, H14b, H26, H28 owner's.

## 0075 — 2026-07-25 — the ratchet 0074 earned
- did: 0074 corrected a false `next:` claim, and the interesting part was WHY that line was wrong
  while the rest of the entry was right. Every other line in a ledger entry describes work just done
  and verified; `next:` describes work NOT started, written at the end of an increment when the
  author is finished and least inclined to check anything. It is structurally the least-verified
  sentence in the record — and the one most likely to be acted on, because the next worker reads it
  as a finding rather than a guess.
- did: put that in the skill's RECORD step, where it will be read before the line is written rather
  than after: verify a `next:` claim, or mark it as unverified ("looks like", "worth checking").
  Also stated the correction protocol explicitly — a wrong entry is fixed by a LATER entry saying so,
  never by editing history, because a ledger that quietly rewrites itself is not a record.
- learned: this is the second harness rule this sitting to come from a mistake I made rather than a
  defect in the code (the first: 0059's "no injection count, no counterfactual"). Both were invisible
  while things were going well and obvious the moment something went wrong — which is the argument
  for writing the rule at the moment of the failure, while the reason is still concrete, instead of
  as general advice later.
- verified: full oracle green.
- ratchet: this IS the ratchet.
- next (verified, per the rule above): nothing outstanding — open items are H13 (watch), and H10,
  H14b, H26, H28 (owner's). The frontier's remainder is documented as deliberately uncovered in H4.

## 0076 — 2026-07-25 — nothing was parsing the web UI, and a stale note survived 0062
- did: went looking in territory no increment had touched — `web/public/`. `app.js` is 4,393 lines
  and 213 KB, `@embedFile`'d VERBATIM into the binary. Nothing compiles it, nothing parses it, no
  test loads it. A syntax error or a truncated write ships a DEAD web UI behind a fully green
  oracle — the silent-failure shape this repo keeps producing, on the one artifact a user actually
  loads. `styles.css` had a palette-mirror signal; `app.js` and `index.html` had nothing at all.
- did: a new gate in BOTH oracles, `node --check web/public/app.js`. Verified it passes today and
  that it CATCHES a break (injected `function broken( {`, exit 1, names the line) before wiring it
  in — a gate never proven to fail is not a gate. Script dialect deliberately: the file carries no
  import/export, and `--check` rejects a plain script if asked to parse it as a module. Node is
  optional here (Zig + Python are the real toolchain), so an absent node SKIPS LOUDLY rather than
  failing the build or passing quietly. Gate names kept byte-identical across the twins; the
  `[oracles]` parity signal now reports 6 shared gates instead of 5.
- FOUND while editing: check.ps1's desk-gate note still carried the stale text 0062 corrected in
  CLAUDE.md — "needs a live server on :8787 ... treat the earlier tests as the verdict", citing an
  item ledger 0006 had CLOSED. I fixed the constitution and missed the copy, and this copy is the
  WORSE one: it prints at the exact moment the desk gate is red, when a worker is deciding whether
  a hang is expected. Corrected to say the suite is hermetic and a hang is real.
- learned: 0062 fixed "the docs", and I treated CLAUDE.md as the whole of the docs. Operator-facing
  prose also lives in gate notes, log strings and error messages, and those are read at the moment
  of failure — the moment they matter most and the moment nobody re-reads them. When correcting a
  claim, grep the CLAIM across the tree, not the file you found it in. (Same shape as 0055's fifth
  escaper and 0073's four copies: fixing the instance, not the class.)
- verified: gate green in both oracles; scan parity 6/6, 0 signals; full oracle ALL GREEN.
- ratchet: the gate itself, plus the corrected note.
- next (verified): `index.html` and `styles.css` still have no structural check — a gutted or
  truncated one would ship the same way. Named as a real remaining gap, not as work I started.

## 0077 — 2026-07-25 — the test binary could not see the shipped page at all
- did: followed 0076's named gap — `index.html` had no structural check. Its own comment records the
  bug worth preventing: "/icon.png has no route on the server, so a linked icon 404s on every load".
  That is two things that must agree — the URLs baked into the page and main.zig's route table —
  held together by attention. Now audited: every same-origin `href`/`src` in the page must have a
  matching route, with a floor (>= 4 refs) so a rewrite that inlines everything fails loudly rather
  than passing on zero.
- FOUND, and bigger than the test: `@embedFile("index.html")` **does not resolve in the test build**.
  build.zig adds the four web assets to `exe.root_module` only, so the test module cannot even NAME
  `ASSET_HTML`/`ASSET_JS`/`ASSET_CSS`/`ASSET_MODELS`. No test could ever assert anything about the
  shipped page, and nobody noticed because Zig's analysis is LAZY: main.zig compiles fine under test
  right up until a test actually references one of those consts — which nothing did until this one.
  Same trap as ledger 0029's silently-uncollected tests, wearing different clothes: absence of a
  reference looked identical to absence of a problem. Fixed in build.zig; the test module now gets
  the same four imports the exe does.
- FOUND, second: my needle `router.get("{s}"` made the PRE-EXISTING router audit fail — that audit
  scans this same file's source for any line containing `router.` and parses it as a declaration, so
  my format string read as a route named `{s}`. Split the literal (`"router" ++ ".get(\"{s}\""`)
  with a comment saying why. Worth knowing generally: two source-reading audits in one file WILL
  read each other, and the second one written is the one that discovers it.
- verified: src suite exit 0. Counterfactual with the injection printed — adding a
  `href="/nonexistent-asset.png"` fails the new test with the URL named and the consequence spelled
  out. Full oracle green.
- learned: the interesting defect was not the missing test, it was that the missing test was
  IMPOSSIBLE to write and nothing said so. A capability gap in the build hid behind lazy analysis
  and looked exactly like "nobody got around to it". When a whole category of assertion is absent,
  check whether it is unwritten or unwritable before assuming the former.
- ratchet: the build.zig imports (unlocks asset assertions generally, not just this one) and the
  route audit.
- next (verified): `styles.css` is partly covered by the `[theme]` palette signal — a truncation
  losing slots would trip it. `app.js` now parses (0076). No further web-asset gap identified.

## 0078 — 2026-07-25 — the rest of the "unwritable" check, and where this sitting ends
- did: 0077's gap was that `exe.root_module` had imports the test module lacked, making a whole
  category of assertion impossible rather than merely unwritten. That question is mechanical, so I
  finished it: diffed what each module is given in build.zig.
- verified CLEAN: after 0077's fix the two differ by exactly ONE import — `desk` — and that omission
  is deliberate and already documented in build.zig ("a test module that pulled the GUI in would
  need GL on every CI box, which is exactly what -Dapp=false exists to avoid"), with the desk
  package carrying its own suite. No other category of assertion is blocked by build configuration.
  Recorded so the next worker does not re-derive the diff.
- state of the tree at the end of this sitting, for whoever picks it up: open items are H13 (a watch
  item — record the trace if it ever fires) and four OWNER decisions (H10 self-lane, H14b PAT
  sealing, H26 pixel_search placement, H28 the workers_ai copy). H4's remainder is documented as
  deliberately uncovered. Six audit sweeps this sitting found NO bugs (result enums, fixed-size
  memcpy, security-claim strings, constant-degrading bufPrint, narrowing @intCast, module config);
  two found real gaps (swallowed at-rest-key write; the entire web-asset surface, unparsed and
  untestable). That ratio is the honest signal about where the remaining risk is: not in the Zig.
- learned across the whole sitting, if only one thing survives: the recurring defect here is not
  wrongness, it is SILENCE — a message that never sends, a test that never runs, a key that never
  persists, a UI that never parses, each behind a green build. Every increment that mattered came
  from asking "what would fail without saying so?" rather than "what looks wrong?".
- verified: full oracle green.
- ratchet: none — this entry is a recorded negative result plus a handoff, which 0067 established is
  worth writing down rather than dressing up as work.
- next (verified): nothing worker-actionable. The four owner decisions are the only open work.

## 0079 — 2026-07-25 — you cannot optimise token spend you cannot attribute
- did: took "optimize token spend" as a measurement problem first. A chat turn is not one call: it is
  one `chat` stream plus up to a dozen auxiliary round-trips (plan, recon, course, planrec, summary,
  arbiter, searchq, stuck, reflect, ctxsum, compact, lesson, loop), each with its own prompt. The
  static schema alone is ~2.9k tokens of CHAT_SCHEMA + ~2.3k of ORCH_TOOLS on every inference.
- FOUND: the engine already measures all of this per call — `logCall` records
  `{ts, role(label), model, base, ms, in, cached, out}`, metrics.zig writes every field to
  `u*/_metrics/llm.jsonl`, and llm.zig folds three provider dialects to get `cached` specifically so
  that "is provider prompt caching actually working?" is answerable from our own meters. Then
  `doctor --growth` parsed the rows with a struct containing only `{model, calls, in, out, ms}` —
  DISCARDING the label and the cache field. The data reached disk and stopped one layer short of a
  reader. Two questions you actually ask when a bill looks wrong were unanswerable from the report:
  which call is spending it, and is the prefix cache working.
- did: report both. Per-model rows gain `cached%`; a new per-label section lists the biggest spenders
  first with each one's share of input and its own cache rate. No new plumbing — every number was
  already on disk.
- verified END TO END against the real binary, not just a compile: built server-only, pointed
  `NEURON_LOOPS_DATA` at a synthetic `llm.jsonl` with hand-computable numbers, and checked every
  figure (70k in = 30+12+20+8; 57% cached = 40/70; chat = 71% of input; ordering by in+out). The
  output also demonstrates the point immediately: `chat` reads 80% cached while `plan` and `arbiter`
  read 0% — the diagnostic that was invisible before. Full oracle green.
- HONEST LIMIT: this is verified but NOT regression-guarded. The aggregation is inline in
  `growthReport`, which writes to stdout, so no test covers it and the oracle would not catch a
  future break. Extracting a pure fold + testing it is the obvious follow-up and I did not do it —
  saying so rather than implying the increment is fully ratcheted.
- learned: "optimize X" starts as an observability question surprisingly often. The costly calls were
  already instrumented to the field level; nobody could SEE them, so nobody could rank them. The gap
  was not in the engine's measurement, it was one struct literal in a reader that quietly dropped two
  fields — the same silent-truncation shape as everything else this sitting, wearing a parser's
  clothes.
- next (verified): with per-label numbers visible, the actual optimisation becomes measurable —
  an auxiliary call rivalling `chat` is the first candidate for a cheap inference-free pre-gate
  (`planWorthwhile` is the existing pattern). That needs REAL usage data, which only the owner has.

## 0080 — 2026-07-25 — closing the gap 0079 admitted
- did: 0079 shipped the per-label token report "verified but NOT regression-guarded" and named the
  follow-up: the aggregation lived inline in `growthReport`, which writes to stdout, so nothing could
  assert a number it printed and an arithmetic regression would have been invisible to the oracle.
  Done now — `foldMetricsJsonl` + `MetricAgg` are file-scope and pure, and growthReport is a renderer
  over them. Behaviour preserved: the same synthetic data through the rebuilt binary prints output
  byte-identical to the pre-refactor run.
- did: tests the report's own arithmetic. Both foldings of the same rows (per model, per label) with
  hand-computed totals; the cache rate the report prints derived from exactly the two numbers it
  divides; a corrupt line SKIPPED rather than blanking the report; a row missing `model` or `role`
  folding into the view it can and not the other; and 40 distinct keys into 24 buckets stopping at 24
  rather than writing past the array.
- the assertion worth copying: the two views fold the SAME rows, so their input totals must
  reconcile. If they ever diverge, one fold is dropping rows and every percentage printed from it is
  wrong — a cross-check that no single-view test could make. The counterfactual proves it bites:
  zeroing the per-label cache fold fails that test.
- learned: writing "verified but not guarded" in 0079 is what made this get done. The honest limit
  was a to-do with a name attached; had the entry claimed the increment was complete, nobody would
  have come back. Admitting the gap in the record is not bookkeeping, it is the mechanism — and it
  cost one sentence.
- verified: src suite exit 0; end-to-end output identical to 0079's; counterfactual (injection
  printed) fails the named test. Full oracle green.
- ratchet: the extracted pure fold — the report's arithmetic is now inside the oracle instead of
  outside it.
- next (verified): the per-label numbers are only as useful as the data behind them, which needs real
  usage the owner has and I do not.

## 0081 — 2026-07-25 — a sandboxed chat advertised nine tools it would always be refused
- did: ran a 15-agent audit (5 subsystem surveys → an independent skeptic per finding, briefed that
  this codebase is unusually well-guarded and to FIND THE GUARD). 10 candidates, **7 refuted** — by
  an existing test, a documented deliberate exclusion, a guard the claimant missed, or a premise that
  was simply false about the code. That ratio is the useful output of the shape: the refuters earned
  their tokens by deleting plausible work, and it matches my own 4-false-findings record this sitting.
- FIX (survived, verified myself before touching anything): `TURN_TOOLS_SANDBOXED` filtered
  CHAT_SCHEMA and EXTRA_TOOLS through `tools.sandboxSchema` but concatenated **ORCH_TOOLS raw**.
  `orchTool`'s FIRST statement — before any dispatch — refuses nine of its twelve verbs for a
  sandboxed caller (cast, steer_swarm, answer_swarm, sync_dir, open_subchat, schedule_*). So every
  non-admin turn advertised nine tools whose only possible outcome was a refusal: the exact harm the
  paragraph directly above that line condemns for the browser/pixel verbs it does filter.
- the reason it survived so long is the interesting part. The header said ORCH_TOOLS is "deliberately
  NOT filtered ... dropping them would remove working capability" — a correct argument about dropping
  the block WHOLESALE, and simply not about `sandboxSchema`, which is allowlist-derived and PER-TOOL.
  SANDBOX_TOOLS already lists the three verbs that genuinely work ("read-only swarm observation":
  swarm_status, swarm_asks, stop_swarm), so the filter keeps exactly those and drops the nine. A true
  sentence guarding the wrong operation — which reads as a decision and stops the next reader cold.
- cost, measured not estimated: 8,099 bytes (~2,024 tokens) of schema leaves every sandboxed turn's
  tools array, keeping 1,051 bytes of working verbs. The bytes are the smaller half — the skeptic
  correctly noted the tools array is prefix-cached, so the real saving is the AGENTIC ROUND-TRIPS a
  model spends calling a tool that can only answer "not available in this workspace".
- ratchet, and the part I'd keep: the existing test had to `continue` past every ORCH_TOOLS name
  ("rides along unfiltered on purpose"), which is exactly why it never saw this. That exemption is
  GONE — every name in the sandboxed array must now be `sandboxAllowed` — plus explicit assertions
  that the three observation verbs survive and the escalating ones do not. An exemption written to
  accommodate a design is a blind spot the moment the design is wrong.
- verified: src suite exit 0; counterfactual (injection printed) reverting the filter fails the named
  test. Full oracle green.
- next (verified): two more findings survived refutation and are NOT yet done — schedLearn's unbounded
  lesson prompt (engine.zig:2073) and the fitness block's one-round smoke skew (run.zig:1424). Both
  carry the skeptic's corrected magnitude; see 0082.

## 0082 — 2026-07-25 — the lesson call paid a full prefill for one sentence
- did: second finding from 0081's audit, verified myself before touching it. `schedLearn` appended its
  question to `conv_buf` and passed the WHOLE buffer to the "lesson" completion — the only auxiliary
  completion in engine.zig with no `msgTail` bound. So the end of every scheduled run paid a full
  prefill of its entire assembled context (system prompt + memory blocks + the working span, which
  compaction holds near 32 KB and lets reach 48 KB) to produce ONE sentence capped at 256 tokens.
- uncached twice over, which is why it costs full price: the request is TOOLLESS, so it cannot reuse
  the provider's tools-bearing cached prefix, and it runs on the THINKING provider while the turn's
  chat calls run on CODING — there is not even a same-endpoint prefix to hit. The skeptic corrected
  the claimant's arithmetic here (~10-18k tokens, not 17-31k, because a scheduled run mints a fresh
  conv so the recency window and rolling summary are empty at assembly) and I kept the corrected
  figure; the mechanism was unaffected either way.
- did: mirrored `summarizeTurn`, which does the same job correctly one screen away —
  `msgTail(conv_buf.items, SUMMARY_CTX_BYTES)` into a LOCAL message list. That also retires the
  save/shrink pair: the question cannot leak into durable context if it never touches conv_buf.
  Tradeoff accepted, the same one summarizeTurn accepts: the lesson sees the run's tail, not its
  whole arc.
- ratchet — the part that outlives this fix: NOTHING said an auxiliary call may not send the whole
  transcript, which is how this shipped and how the drive picker shipped the same way before it (its
  fix note is still in the file). Now a source audit requires every `llm.complete` in engine.zig to
  bound its prompt, with a floor (>= 8 calls scanned) so a rename fails loudly instead of passing on
  zero, and an assertion that the STREAMED turn still sends the whole conversation — so the rule
  cannot be satisfied by crippling the actual chat.
- verified: src suite exit 0; counterfactual (injection printed) re-unbinding the lesson prompt fails
  the new audit by name. Full oracle green.
- learned: two instances of one mistake, years apart in the same file, each fixed locally with a
  careful note beside it — and the note never generalised. This is the third time this sitting the
  answer was "make the rule mechanical rather than written" (0055's one escaper, 0073's one
  predicate, now this). The tell is a comment that explains a fix: it means someone understood the
  class and had no way to enforce it.
- next (verified): one finding from the audit remains unimplemented — the fitness block's one-round
  smoke skew (run.zig:1424), where buildFitnessBlock folds in the PREVIOUS round's smoke verdict. The
  skeptic confirmed the order and narrowed the harm to flip-rounds with a green bench. It needs a
  reorder inside the swarm round loop, which I cannot exercise without a live swarm — left for a
  session that can, with the analysis in this ledger.

## 0083 — 2026-07-25 — groundwork for the third finding, and why I did not "fix" it
- did: the audit's third surviving finding is real — at the round loop's single call site,
  `buildFitnessBlock`'s `runtime_fail` argument carries the PREVIOUS round's smoke verdict, because
  `smokeTest` runs AFTER it in the same iteration. The skeptic verified the order, the single writer,
  and that nothing recomputes the block afterwards, then narrowed the harm honestly: a one-round
  contradiction at each FLIP of the smoke verdict, and only when the bench is otherwise green (a real
  failure list always wins over the folded note).
- did NOT apply the proposed fix (hoist `smokeTest` above `runBenchmark`). Reason, stated plainly:
  it reorders a live swarm round loop that NO test in this repo exercises, and I could not rule out
  the obvious hazard by reading — if the benchmark path installs dependencies or otherwise prepares
  the tree that the smoke harness boots, running smoke first would produce a FALSE RED every round,
  which is far worse than a one-round stale note. "No green, no done" has to mean something when the
  green available does not cover the thing being changed.
- did instead, and it is not a consolation prize: `buildFitnessBlock` had ZERO tests, and it is the
  line every mind optimises — what it says IS the swarm's objective function. Now pinned: a green
  bench with a red gate never reads "all green" and names the gate; a green bench with a green gate
  reads all-green and invents no phantom failure; and REAL bench failures take precedence over the
  folded note, so a mind sees the checks that actually failed. Counterfactual (injection printed):
  dropping the fold-in fails the first assertion.
- learned: an audit finding has two separable parts — is it REAL, and can I land it VERIFIED. The
  skeptic settled the first; the second is mine and the answer was no. Splitting them let me take the
  safe half (contract now pinned, so a future reorder that breaks it fails in the suite instead of in
  a live cast) and hand over the risky half with the analysis attached, rather than either shipping an
  unverifiable reorder or dropping a confirmed defect on the floor.
- verified: src suite exit 0; counterfactual fails the named test. Full oracle green.
- next (verified): the hoist itself, for a session that can run a live swarm. The test added here pins
  the shape the fold-in must keep, so the reorder can be checked against something.

## 0084 — 2026-07-25 — the end-of-run judge read 1 MiB of an 8 MiB log and said nothing
- did: a second 14-agent audit, this time over the subsystems that DECIDE (rsi governor/playbook,
  agi goal origination, plan decomposition/reconciliation, rerank+recall relevance, sched
  self-healing) — none of which the first audit touched. 9 candidates, 7 stood. That survival rate is
  itself worth noting: the first audit's finders reported 10 and kept 3, and the only change was
  telling this round's finders that seven of ten had been refuted, exactly how each died, and that
  ZERO findings was a good answer. Calibrating a searcher with the previous searcher's failure rate
  cost one paragraph and roughly doubled precision.
- FIX (verified myself before touching it): `appendFile` holds events.jsonl at `EVENT_LOG_CAP` =
  8 MiB, self-trimming. `readFileAlloc`'s limit ERRORS with StreamTooLong at the limit — it does not
  truncate. rsi.zig's `runJudge` read `.limited(1 << 20)` and its `catch return` is the function's
  FIRST statement, so on any run whose log passed 1 MiB the end-of-run judge graded nothing, emitted
  no `judge_done`, and left no trace that it had been skipped. Two other readers (fanout.zig:160,
  run.zig:3342) already matched the writer at 8 MiB; the judge was the one that didn't.
- kept the skeptic's corrections, which mattered: the run still LEARNS on such a run (`reviewFork`
  mints lessons/skills into the live hive every round and never reads events.jsonl) — what is lost is
  the end-of-run QUARANTINE proposal pass, i.e. a missing human-review queue, not a run that learned
  nothing. The claimant also called this "the smallest cap in the repo" (false — chat/tools.zig:310
  uses 512 KiB, though it degrades to a visible fallback string rather than silence) and called the
  band "routine" (unsupported — the largest events.jsonl in the data tree is 469 KB). Corrected
  severity is what went in the ledger.
- did: made the coupling STRUCTURAL rather than a matched literal. `EVENT_LOG_CAP` is now `pub`, its
  doc states it is half of a contract, and all three run-scoped readers reference it instead of
  restating 8 MiB. A reader can no longer drift from the writer by editing one number.
- ratchet: a source audit over run.zig, rsi.zig and fanout.zig — any `readFileAlloc` line touching
  `ev_path` must use `EVENT_LOG_CAP`, with a floor (>= 3 readers) so a rename fails loudly instead of
  scanning nothing. Counterfactual (injection printed): putting the judge back to 1 MiB fails it by
  name and prints the offending line.
- learned: this is the fourth "two things that must agree" in three sittings (twin escapers, the
  has_score predicate, cast_conv/sc_conv, now writer-cap/reader-cap) and the first where the two
  things were a WRITER and a READER of the same file rather than two copies of one expression. Worth
  generalising: any bound enforced on write is a claim the read side must honour, and nothing in a
  type system connects them.
- verified: src suite exit 0; counterfactual fails by name; full oracle green.
- next (verified): six more findings from this audit stand and are NOT implemented — agi's
  best_oracle carry-over, scoreWill's percent-vs-count comparison, planReconcile's digit scavenging,
  the unreachable has_plan disjunct, sched's 45-byte task-id ledger no-op, and the tick path's
  missing one-run-per-task guard. Each has a skeptic's corrected severity attached in this run's
  journal (wf_8f5e3c7c-ed1).

## 0085 — 2026-07-25 — the audit was wrong, and there was a real bug next to it
- CORRECTION FIRST: the audit filed "the outcome ledger silently no-ops for any task whose id exceeds
  45 bytes — fail_streak/backoff dead", and its skeptic let it through. I checked the path myself and
  it is FALSE. `recordRunOutcome` → `safeSeg` (bounds at 64, not 45) → `loadTask`, which builds its
  path with `allocPrint` — heap, unbounded, no truncation anywhere. There is no 45-byte clip in the
  outcome-ledger path at all. Filed severity: a dead self-healing ledger. Actual: nothing.
- but the 45 was real, one function away. `convIdFor` clips the task id to `64 - prefix.len - 9` = 45
  when minting a run's conv id. The one-run-per-task guard on the manual-run route REBUILDS that
  prefix to grep live turns and refuse a duplicate — and it hardcoded a bare `45`, hundreds of lines
  from the expression that derives it. Widen the prefix or the stamp and convIdFor adapts, the guard
  does not, it stops matching, and the protection lapses silently. Its own comment states the cost:
  "double the tokens for the same deliverable".
- did: `CONV_PREFIX`, `CONV_STAMP_BYTES` and `CONV_TASK_CLIP` are derived once and used by both.
- ratchet, and the assertion is the point: NOT "both use the same constant" — that restates the fix.
  The test rebuilds the guard's prefix and requires it to be an actual PREFIX OF A MINTED CONV ID,
  across five id lengths (short, clip-1, exactly clip, clip+1, the 64-byte ceiling). That is the
  property the feature depends on, and it survives any refactor that keeps the two consistent
  (TESTING.md's "two derivations of one source must reconcile", 0080).
- verified, and the first counterfactual was WRONG so I redid it: widening the stamp tripped a
  DIFFERENT pre-existing test before reaching mine, because both sides now derive from one constant —
  changing it keeps them consistent, which is the fix working, not the test firing. Making them
  DISAGREE (guard clipped to 40, mint left at 45) fails my test by name and prints
  `guard prefix 'scheduled_a…a_' does not match minted conv 'scheduled_a…a_07081840' — a second run
  would start`. Full oracle green.
- learned: a refuted-vs-confirmed verdict is not a substitute for reading the code. Seven of nine
  survived this audit versus three of ten in the last, and I took that as evidence the finders had
  improved — some of it was the skeptics being softer. The finding I picked to implement was
  confirmed, well-argued, and wrong about its own mechanism. What saved it was verifying the path
  myself BEFORE editing, which also happened to walk me past the real defect.
- also learned: my own counterfactual can pass for the wrong reason. "Something failed" is not
  "the thing I claimed would fail, failed" — check WHICH test fired, every time.
- next (verified): five findings from wf_8f5e3c7c-ed1 remain unimplemented and now carry a health
  warning — re-derive each against the code before acting, the confirmations are not reliable.

## 0086 — 2026-07-25 — a polite refusal became a binding rule for every mind
- did: the retrospective asks the model for ONE operating rule per round and invites "none" when the
  round taught nothing. It tested for that with an exact whole-reply match — which can only fire on
  the bare word, and the bare word is already rejected by the `rule.len < 8` gate one line above. So
  the check was DEAD for the case it was written for and blind to every case that occurs: models
  decline politely. "None needed.", "No changes required.", "Nothing to change this round." each
  clear 8 characters and none equals "none", so each was minted into PLAYBOOK_SCOPE and injected into
  every mind's prompt as a binding operating rule — a sentence instructing nobody to do anything,
  crowding real directives out of a clipTail'd 1200-byte window.
- did: `isDecline` keyed on the FIRST WORD, which is where a decline announces itself, deliberately
  narrow — a false positive silently drops a genuine lesson, which is worse than one weak rule
  getting through. The test carries both halves: the refusal shapes that actually shipped, and the
  rule shapes that must still pass ("Note the failing test's name...", "Never write a file another
  mind owns", "Northbound API calls...") — all of which a sloppier prefix match would eat.
- MY OWN COUNTERFACTUAL CAUGHT MY OWN GAP, and this is the part worth keeping. Reverting the call
  site to the old exact match left the suite GREEN: my test exercised `isDecline` directly, so
  removing the CALL left the function defined, correct, and unused. A unit test proves a function
  works and says nothing about whether anything uses it. That is the third distinct instance of this
  shape in the ledger — the sandbox test that exempted ORCH_TOOLS, the live store test that skipped,
  now this — all green for a reason unrelated to the claim.
- ratchet: a wiring audit. `roundRetrospective`'s body must call `isDecline`, and the dead
  exact-match must not creep back. Counterfactual now fails by name and prints the consequence.
- learned: "is it correct" and "is it reachable" are separate questions and I keep collapsing them.
  Every unit test of an extracted predicate needs a companion assertion that the predicate is WIRED,
  or the extraction itself becomes the hiding place.
- verified: src suite exit 0; both counterfactuals (unit and wiring) fail by name; full oracle green.
- next (verified): four findings from wf_8f5e3c7c-ed1 remain, each needing its own re-derivation
  first — 0085 records why the confirmations are not trustworthy on their own.

## 0087 — 2026-07-25 — prose after the answer could mark a subtask complete
- did: `planReconcile` asks a model which subtasks are already done and parsed the reply by taking
  EVERYTHING from "done:" to the end, tokenizing on `, \r\n\t`, and marking DONE any token that
  parsed as an in-range integer. So a model that answered and then explained itself —
  "done: 1, 2\nSubtask 3 is still in progress", "done: 2 (took 3 tries)" — silently marked work
  complete that was not. The old comment said "'none' and stray prose just skip": true of
  non-numeric tokens, and exactly wrong about a numeral INSIDE prose, which is the case that occurs.
- consequence, which is why this is worth more than its size: a subtask wrongly DONE is never
  revisited. The turn stops working on it and the deliverable ships short, with the plan board
  reporting success. Nothing errors.
- did: `parseDoneList`, bounded twice — stop at the end of the answer LINE, and stop at the first
  token that is not a number. Both fail SAFE, and the second is a deliberate trade: "done: 1 and 2"
  now yields only 1. A subtask left PENDING is re-examined by the next reconcile pass and the work
  continues; a subtask wrongly DONE is unrecoverable. When two failure directions are not symmetric,
  bound toward the recoverable one — and assert the truncation in the test so it reads as a decision
  rather than a bug someone later "fixes".
- ratchet: the parser's tests plus a WIRING audit (0086's lesson, applied in the same sitting it was
  learned) — `planReconcile` must call `parseDoneList`, or an extraction becomes the hiding place.
- verified, and the counterfactual took THREE attempts, which is the entry's real lesson:
  * #1 never injected — my Python escaping of `'\n'` did not match the file, so exit 0 meant nothing.
  * #2 injected but failed to COMPILE ("local variable is never mutated"), so exit 1 also meant
    nothing — a red for a reason unrelated to the claim.
  * #3 kept the variable mutated and removed only the bound; the NAMED test failed. That is the
    only one of the three that proved anything.
  Two of three counterfactual runs produced a verdict that looked usable and was not. Checking WHICH
  test fired — not merely that the exit code moved — is the whole discipline. Full oracle green.
- next (verified): three findings from wf_8f5e3c7c-ed1 remain (agi's percent-vs-count comparison, the
  unreachable has_plan disjunct, the tick path's missing one-run guard), each needing re-derivation
  per 0085.

## 0088 — 2026-07-25 — a scheduled task could run itself in parallel, forever
- did: `launchRun`'s only duplicate protection was `tryBeginTurn(conv)`, and its own comment states
  the limit precisely — a false there means "a same-named run from this MINUTE is still going". A
  conv id is stamped to the minute, so the guard cannot see the case that actually piles up: an
  every-N-minute task whose run OUTLIVES N. The next tick mints a different stamp, claims a different
  conv cleanly, and starts a second run of the same task beside the first. The tick after that starts
  a third. Nothing errors; the task just multiplies.
- the asymmetry is the point. The MANUAL run route has guarded this for a while, via
  `liveTurnWithPrefix`, and names the cost outright: "double the tokens for the same deliverable". A
  human clicking twice is rare and self-limiting. A scheduler firing every five minutes against a
  twelve-minute run is neither. The path that needed the guard most had it least — and the guard was
  already written, one file over, unused by the caller that needed it.
- did: the same prefix check in `launchRun`, placed BEFORE the run-dir creation and message build so
  a duplicate costs nothing at all. Skipping without bookkeeping is the established shape here:
  `next_due` is untouched, so the task fires on a later tick once the run finishes.
- ratchet: a test that reproduces the exact hole — two conv ids for one task ten minutes apart, the
  conv-id claim succeeding for BOTH (that is the pile-up), and the prefix guard refusing the second
  because it matches the task rather than the minute. Plus an assertion that a DIFFERENT task is
  still free to run, so the guard is not a global lock. Plus a wiring audit (0086).
- verified: src suite exit 0. Counterfactual clean on the first attempt this time — injection
  printed, exit 1, the NAMED test failed with its message, and zero compile errors in the log. That
  last check is 0087's lesson made routine: exit 1 is not evidence until you know WHICH test produced
  it. Full oracle green.
- learned: three of this sitting's fixes were "the guard exists, the caller does not use it"
  (ORCH_TOOLS unfiltered, isDecline unwired after extraction, now this). That is a different shape
  from a missing guard and it hides better, because a reader who greps for the protection FINDS it
  and stops looking. Worth asking of any safety mechanism: who calls this, and is that everyone?
- next (verified): two findings from wf_8f5e3c7c-ed1 remain — agi's percent-vs-count comparison and
  the unreachable has_plan disjunct. Both need re-derivation first (0085).

## 0089 — 2026-07-25 — the Veil graded its own predictions against a changing yardstick
- did: `selfMetric` returns TWO different quantities out of one function —
  `if (last_bench.status == .ok) last_bench.pct else (factCount(KNOWLEDGE) + factCount(SKILL))` — a
  benchmark PERCENT (0..100) or a raw FACT COUNT (unbounded), switched by bench status. `recordWill`
  stages a will with `baseline = selfMetric(w)`; `scoreWill` later grades it with `now > baseline`.
  Nothing recorded WHICH unit the baseline was in.
- the flip is ordinary, not exotic: it happens the first time a deliverable acquires runnable tests,
  which is the normal arc of a build. A will staged before that (baseline = 200 facts) is then graded
  against a percentage (65) and reads MISS forever; the reverse (baseline 80%, now 250 facts) reads
  HIT for nothing. Everything downstream inherits it — `will_hits`/`will_misses`, the calibration
  RATE, the `.veil_self_model` text the Veil is shown ("the direction I will into being has actually
  moved the needle N% of the time"), and the metacog event. A self-model built on a unit error is
  worse than none: it is confidently wrong about which of its own judgements are working.
- did: the baseline now carries its unit (`pending_will_bench`), and `scoreWill` DECLINES to grade
  when the yardstick changed under it — clearing the pending will without recording a verdict, rather
  than inventing one the comparison cannot support. Refusing to answer is the correct output when the
  measurement is incommensurable; a HIT/MISS either way would be noise entering a durable record.
- ratchet: the bench branch of selfMetric is pure, so its PERCENT answer is pinned directly (including
  0% as a real score rather than "no score"); the count branch needs a live store and is not
  exercised, which the test says plainly. A source assertion pins that the two branches really do
  return different kinds of number, and a wiring audit (0086) requires recordWill to record the unit
  and scoreWill to check it. Counterfactual: bypassing the guard fails by name, zero compile errors.
- learned: this is a UNIT error, which is a category the other audits never looked for — every prior
  finding was a missing bound, a stale value, or an unwired guard. A function that answers in
  different units depending on hidden state is a type error the type system cannot see, because both
  answers are `u32`. Worth a sweep of its own: which other functions return one type and two meanings?
- verified: src suite exit 0; counterfactual by name with no compile error; full oracle green.
- next (verified): one audit-2 finding remains (the unreachable has_plan disjunct, engine.zig:1547).
  Audit 3 (edit primitives, grounding, ingestion, metering, acceptance) is still running.

## 0090 — 2026-07-25 — how often the audit's "confirmed" findings are wrong: about a third
- did: no code change. Two record corrections and a bounded class, which 0067/0078 established is
  worth an entry of its own rather than being dressed up as work.
- CORRECTION: audit 2 filed "the mid-turn course check's `has_plan` disjunct is unreachable — a plan
  walking its board never gets a course check", and a skeptic confirmed it. FALSE. `plan` is
  populated at engine.zig:1395 (the block breaks with a real plan or with `&.{}`), `has_plan` is set
  from it at 1448, and NOTHING reassigns it before its use at 1547 — the only reassignment is at
  1669, inside the loop that runs after. The disjunct is live; an unarmed turn with a plan does get
  the course check.
- so the running tally, and it is the useful output: of audit 2's SEVEN "confirmed" findings I have
  now independently re-derived five before acting. Two were false — the sched 45-byte outcome-ledger
  claim (0085, a truncation in a path that truncates nothing) and this one. Three were real and are
  fixed (0084 event-log cap, 0086 decline-as-rule, 0087 done-list scavenging), plus two more from the
  same run (0088 pile-up, 0089 unit error). **About a third of confirmed findings did not survive a
  careful read.** Audit 1's ratio was the mirror image: 7 of 10 refuted BEFORE reaching me. Taken
  together: the refutation stage is worth its tokens and is not a substitute for reading the code.
- also: swept the class 0089 opened — a function returning ONE type with TWO meanings, which no type
  system can catch when both are `u32`. Checked every numeric-returning function in src/ with
  divergent return expressions (26 of them). All are the ordinary "0 means absent" idiom;
  `selfMetric` was the only genuine unit switch. The class is bounded at one instance, recorded so
  nobody re-derives the sweep.
- learned: I set audit 3's refuters a harder brief because of 0085 — "your FIRST job is not is there
  a guard, it is IS THE MECHANISM REAL: open the file, read the expression, trace the value to the
  line that imposes the bound; if you cannot find that line, refute" — and added a separate
  `mechanism_verified` flag so a confirmation without it lands in its own bucket rather than among
  the confirmed. That change came from this exact failure mode, one run too late to help audits 1-2.
- verified: full oracle green (record-only change, run for the discipline).
- next (verified): audit 3 is still running. Its findings should be treated as ~2/3 reliable until
  each is re-derived, same as these.

## 0091 — 2026-07-25 — an edit batch could silently eat one of its own ops, in BOTH edit engines
- did: third audit (edit primitives, grounding, ingestion, metering, acceptance). Its refuter did
  something no previous one had: it copied bufedit.zig byte-identically into a scratch dir, ran
  `zig test` with the project's own pinned toolchain, and REPRODUCED the corruption before confirming
  it. That is the difference between "I read the code and it looks wrong" and evidence.
- THE BUG, verified independently by me before touching anything: `insert_before X` is span
  {lo=i, hi=i}; `replace X` is {lo=i, hi=i+1}. The overlap loop rejects neither — `overlap` needs
  `b.lo < a.hi` (i < i), `a_pt_in_b` needs `a.lo > b.lo` (i > i). `std.mem.sort` is STABLE and the
  comparator had no tie-break, so equal `lo` kept append order: the insert spliced FIRST, then the
  replace's [i, i+1) window landed on the freshly inserted line, consumed it, and left the original
  target sitting untouched below. `apply` returned ok and the tool told the model "2 op(s) applied"
  while one op's content had vanished and the other's target had not changed.
- and the MIRROR, in the engine the tool schema calls PREFERRED: hashline.zig tied on op INDEX
  (`x.op > y.op`), which happens to order [insert, replace] correctly and orders [replace, insert]
  exactly wrong. Same corruption, opposite listing order, different file. Fixing one would have left
  the other — and hashline is the dialect `read_file` hands the model on every line.
- both now tie on span KIND: a consuming span splices before a zero-width insert at the same
  position, whichever order the model listed them. Same-kind pairs still compare equal, so the stable
  sort keeps their relative order and nothing else moves.
- kept the refuter's corrections rather than the dramatic framing: tools.zig's syntax gate has a
  language-blind brace/bracket balance backstop for file types with no dedicated checker, so the
  SILENT case is confined to delimiter-BALANCED lines — HTML, JSX, CSS, markdown, YAML — with other
  languages failing loudly but misleadingly ("N unclosed '{'", pointing at delimiters instead of the
  cause). The silent set is small and is exactly what this swarm builds. The `delete` variant is
  largely self-limiting (an existing "no change" guard catches it unless the insert is longer).
- verified: tests reproduce BOTH op orders in BOTH engines; each counterfactual fails its named test
  with ZERO compile errors. Full oracle green.
- learned: this survived because each engine was correct in the op order its own tests happened to
  use. Two implementations of one idea, each with a different half of the bug, and the tie-break —
  the least conspicuous line in either — was the whole defect. Also: a refuter that RUNS the code
  outranks one that reads it, and this is the first audit where one did. Worth asking for explicitly.
- next (verified): audit 3's remaining findings are unread — this one was large enough to take alone.

## 0092 — 2026-07-26 — the meters missed the call the provider actually billed
- did: `streamAttempt` has NINE exits that `return null` so the caller falls back to `complete()`, and
  only its two SUCCESS paths called `meterStream`. So a streamed attempt that could not be used — tool
  calls it could not reconstruct, an error line, an empty body — had its tokens dropped from every
  meter, while the fallback that re-sent the same prompt WAS counted. The provider billed two calls;
  the meters recorded one.
- why it matters more than its size: the per-label spend view added in 0079/0080 reads STRAIGHT off
  these meters. I spent two increments making token spend attributable and the source data had a hole
  in it the whole time. An observability fix inherits every defect of the thing it observes, and I did
  not check the meter before publishing what it said.
- did: one `defer` that meters on any exit which did not already, plus a `reported` flag the two
  explicit sites set. Double counting is impossible by construction, and `meterStream` is a no-op
  unless the provider actually reported usage (`st.metered`), so the paths where nothing was billed
  stay silent.
- HONEST LIMIT, and the reason the ratchet is structural: this path needs a live SSE provider, so no
  behavioural test here reaches it — my first counterfactual (delete the defer) passed, which is the
  proof. The guard is therefore a source audit: exactly one deferred meter, and every explicit
  meterStream marks itself. Both halves counterfactualled — removing the defer reports "0 deferred
  meters", removing a flag reports "will meter it a SECOND time" — each by name, zero compile errors.
- learned: I introduced an indentation mismatch while wiring the flag (`reported = true;` at 8 spaces
  under a 12-space call) and stopped to check whether it had landed outside its block. It had not —
  Zig reads braces, not columns — but the check was right to make: the same edit in Python would have
  silently changed control flow. Verify the shape of your own edit before trusting the green build.
- verified: src suite exit 0; both counterfactuals by name; full oracle green.
- next (verified): audit 3 has six standing findings not yet acted on — writer.zig's ratio and
  provenance pair, run.zig's PROBE newline delimiter, crawl.zig's unreachable prune gate and its
  first-chunk max_bytes exemption, and metrics.zig's 16 MB all-zero read (the same reader-cap shape as
  0084). Each still needs its own re-derivation per 0090.

## 0093 — 2026-07-26 — a 360-byte budget could return the whole page
- did: `fitToQuery` BM25-ranks a page's chunks and returns the best ones "capped near max_bytes". The
  size check read `if (used + clen > max_bytes and picked.items.len > 0) break;` — the second conjunct
  exempted the FIRST chunk, so the top-scoring chunk went in whatever its size.
- why that is not the small overshoot it looks like: `chunkMarkdown` splits on BLANK LINES ONLY. A page
  without one — dense converted HTML, a single long paragraph — is ONE chunk the size of the whole
  document. `tools.zig:5088` fetches up to 512 KB, asks for a 360-byte snippet, and could put all
  512 KB into the prompt; `run.zig:8510` asks for 4000 and had the same hole. The cap was honoured on
  every path EXCEPT the one that runs on every successful query.
- did: kept the exemption's intent (never return empty), dropped the unbounded part — when the top
  chunk alone overruns, return its clipped head. Still the most relevant text, now inside the budget
  the caller actually named.
- second defect, found by USING the function: `chunkMarkdown` never freed its own scratch buffer. It is
  arena-only by accident of how it happens to be called, but its signature takes any allocator, so
  nothing warned anyone. My test leaked. The fix belonged in the function, not the test.
- learned (the real one): my first instinct was to make the test work AROUND the leak by passing an
  arena. That would have gone green and left the trap armed for the next caller. Calling it with the
  testing allocator instead turns the leak detector into a permanent guard. A test that avoids a defect
  documents nothing; a test that walks into it is a ratchet.
- learned (again, cheaply): a build of mine printed `EXIT=0` under `zig: command not found` — `$?` was
  `tail`'s. The ledger already says never pipe the oracle; I re-learned it on a plain build. Capture the
  status of the thing you ran.
- verified: 549 tests, 0 leaks, exit 0. CF-A restore the exemption -> named test fails on the length
  assertion, 0 compile errors. CF-B drop the scratch free -> named test fails "leaked 1 allocations",
  0 compile errors. Full oracle green.
- next (verified): audit 3 has five standing findings left — writer.zig's per-round/run-cumulative ratio
  and its seedSources provenance, run.zig's PROBE url newline delimiter, crawl.zig's unreachable
  boilerplate gate, metrics.zig's all-zero answer past 16 MB (the 0084 reader-cap shape again).

## 0094 — 2026-07-26 — the content scorer threw away the only signal that said "boilerplate"
- did: `compositeScore` blends five signals and returns `score / total`, where `total` is the sum of the
  weights — arithmetic that is a weighted average ONLY if every term lands in [0,1]. Two of the five
  were broken, and they reinforced each other.
  - `0.1 * @max(0, classIdWeight(node))`: classIdWeight returns 0, -0.5 or -1.0 and nothing else, so
    the clamp made the term identically zero. The one signal that says "this block is nav / footer /
    sidebar / ads" was computed on every node and then discarded.
  - `0.1 * @log(tl + 1)`: a raw logarithm sitting among four ratios. Unbounded.
- the measurement, not the impression: an ordinary 150-char paragraph scored 1.284 out of a possible
  1.0 — the divisor's own definition says that cannot happen. The same inflation lifted a pure-nav
  block (150 chars, all of it link text) to 0.752, well clear of the 0.48 prune threshold. So both
  boilerplate gates in pruneTree were dead in practice: chrome could not score low enough to trip them
  however much chrome it was.
- what it cost: nav bars, footers, cookie banners and share widgets survived pruning into the markdown
  that every web tool hands the model — on every crawled page, in every prompt. Widest blast radius of
  any token-spend defect found so far.
- did: apply the penalty (bounded, {0, -0.05, -0.1}) and normalise the length term to [0,1] against a
  1000-char saturation, same "longer is more contentful" shape. Worked on paper BEFORE editing:
  nav div 0.752 -> 0.273 (pruned), short nav span 0.315 -> 0.127 (pruned), article paragraph
  1.284 -> 0.855 (kept), h2 heading -> 0.666 (kept).
- pruneTree and compositeScore had ZERO tests before this. Three now: the invariant (a score never
  exceeds the average it divides by), the penalty's direction, and an end-to-end extract that keeps the
  article and drops class="nav" / class="footer".
- learned: `zig build test` printed EXIT=0 while its own log ended at "failed command:" with no Build
  Summary — a network test had died on CONNECTION_REFUSED, unrelated to this change. Running the cached
  test.exe directly gave the truth: 543/543. The ledger already knew this harness lies; what is new is
  that it lied GREEN, which is the dangerous direction. Prefer the binary when the summary is missing.
- learned: I nearly took the audit's word that these gates were "unreachable". They are not literally
  unreachable — they fire for tiny nodes. Doing the arithmetic turned a vague claim into a specific
  one, and only the specific one justified touching a heuristic that decides what every crawl keeps.
- verified: 543/543 direct, exit 0. CF-A restore the clamp -> "a negative class actually lowers the
  score" fails, 0 compile errors. CF-B restore the raw log -> "compositeScore stays inside the weighted
  average" fails, 0 compile errors. Full oracle green.
- next (verified): four audit-3 findings left — writer.zig's per-round/run-cumulative ratio and its
  seedSources provenance, run.zig's PROBE url newline delimiter, metrics.zig's all-zero answer past
  16 MB (the 0084 reader-cap shape).

## 0095 — 2026-07-26 — the oracle said ALL GREEN over two test binaries that never reported
- found while closing 0094: `zig build test` printed EXIT=0 while its own log ended at
  `failed command: "...test.exe" ... --listen=-` with no Build Summary and no results. Running that
  exact binary standalone gave 543/543. So the tests were fine — but the ORACLE had no way to know
  that, and said so anyway.
- the actual damage, from the log of the run that shipped 0094: gate "zig build test (src suite)"
  printed PASS with the crash signature inside its own output, and so did "zig build test (desk
  suite)". BOTH test gates of an ALL GREEN run had learned nothing about the tests. Every green this
  session is weaker than I reported it, and I only caught it because a crash happened to be loud.
- why both twins missed it: check.ps1 ALREADY knew this signature and self-heals — but only after a
  NON-ZERO exit. The case that matters exits ZERO, so the gate passed and the fallback never ran.
  check.sh did not know the signature at all, and its header said the flake was Windows-only.
- did: a `zig_tests` wrapper in check.sh that scans the runner's output for the signature and, when it
  finds it, reruns the exact exe the runner named and takes ITS verdict — refusing to pass if that exe
  is gone. check.ps1 now decides on the signature instead of the exit status, and records the stderr
  log so a PASSED gate can be inspected at all (it only kept stdout before).
- deliberately not suppression: a red that always fires on this machine would train me to ignore it,
  so the fix goes and GETS the evidence rather than hiding the absence of it.
- verified: a gate that prints the signature and exits 0 -> FAIL (97), NOT GREEN. And in that same
  run the desk gate hit the REAL flake and self-healed, printing genuine test output before PASS —
  the synthetic case and the live one both exercised, in one run. check.ps1 parses clean (PS 5.1
  ParseFile, 0 errors); check.sh passes `sh -n`. Full oracle green.
- learned: the harness's own guard was one conjunct away from working, which is the same shape as
  0090's `has_plan` and 0086's dead `eqlIgnoreCase` — a guard that exists, is correct about WHAT to
  look for, and is wired to the wrong trigger. Worth grepping for others: "we handle that" is a claim
  about the trigger, not the handler.
- next (verified): four audit-3 findings remain — writer.zig's per-round/run-cumulative ratio and its
  seedSources provenance, run.zig's PROBE url newline delimiter, metrics.zig's all-zero answer past
  16 MB.

## 0096 — 2026-07-26 — the Dashboard would have reported zero spend, forever
- did: `GET /api/v1/metrics/llm` read the usage ledger with `.limited(16 << 20) catch ""`. Per 0084,
  `readFileAlloc`'s limit ERRORS with StreamTooLong rather than truncating — so past 16 MiB the
  endpoint answers 200 with all-zero usage, indistinguishable from a fresh install that has genuinely
  spent nothing. The worst kind of wrong: a plausible answer.
- why certain rather than theoretical: calls.jsonl rotates at CALLS_MAX; llm.jsonl — the file the
  Dashboard actually aggregates — had NO rotation at all. The file's own header said two contradictory
  things: line 21 "Bounded like the old one", and line 30 "reaches the 16MB read cap after ~100k turns;
  rotation can land when anyone gets a tenth of the way there". Rotation was a deliberate deferral, and
  I am landing it as the author planned. The SILENT ZERO is the part nobody signed up for.
- third site, and it is mine: cli.zig's growth report (0079) used the same literal with `catch
  continue`, so past the cap it prints "no llm.jsonl yet (served chat turns write it)" about a file
  that exists and is 20 MB. I added a reader in 0079 and inherited a bug I had not read.
- did: landed rotation as a `rotateIfBig` SHARED by both logs, paired LLM_MAX with an explicit
  LLM_READ_LIMIT strictly above it, and stopped both readers fabricating — the endpoint returns the
  error for anything but FileNotFound, the CLI names the user it excluded instead of dropping it.
- the guard is the WIRING, not the constants. A bound and a limit can agree perfectly while a reader
  passes its own literal and goes to zero on its own schedule; a limit can be right while nothing
  enforces the bound. So the audit does both halves: every `readFileAlloc(` on this file names
  LLM_READ_LIMIT, and every appendFile to a log is preceded by rotateIfBig.
- learned: the guard's first version failed on my own doc comment — it matched the WORD readFileAlloc,
  not a call. A source audit is a parser with no grammar: anchor it on syntax only code has (the open
  paren), and build the needle by concatenation so the test cannot match its own source.
- learned (again, 0087 exactly): CF-A first exited 1 because removing the constant left `metrics`
  unused — a COMPILE error. Exit 1 from a build that never compiled proves nothing. Redone keeping the
  import alive; that is what the compile-error count in every counterfactual here is for.
- verified: suite exit 0. CF-A CLI back to its own literal -> named test fails, warn names cli.zig,
  0 compile errors. CF-B drop the llm.jsonl rotation -> named test fails "that log grows forever",
  0 compile errors. Full oracle green.
- next (verified): three audit-3 findings left — writer.zig's per-round/run-cumulative ratio and its
  seedSources provenance, run.zig's PROBE url newline delimiter.

## 0097 — 2026-07-26 — the publish gate graded every edition on evidence from earlier rounds
- did: four fields are named `round_*`. ONLY ONE of them was per-round. `round_seed_sources` is assigned
  each seeding; `round_independent_sources` and `round_source_diversity` only ever increment, and
  nothing anywhere resets them — there is no round-boundary reset in the file at all.
- so both source-quality publish gates decay into no-ops:
  - `enough_independent = round_independent_sources >= 1` — once a run has EVER fetched one independent
    source, every later round passes it, including a round that fetched nothing.
  - `seed_dependency_pct` — a per-round numerator over a run-cumulative denominator. 12 seed sources
    with 1 independent fetch is 92% and is correctly held; by round five the same 12 seeds read as
    ~37% and publish freely. The gate stops discriminating exactly when a long run makes it matter.
  The function's own doc says "post only if ... at least one was independently retrieved" — present
  tense, about THIS edition. The code agreed with that sentence only in round one.
- nearly got this wrong: my first move was to reset the stored percentage to its declared default of
  100 each round. That would have HELD every edition on a round that did not re-seed, because seeding
  is conditional on `ground` while publishing is not. A derived value should not be stored and then
  reset to a guess — it should not be stored. `seedDepPct(seed, independent)` is computed at the gate
  from the two counters, so it cannot be stale and has no default to get wrong.
- did: reset the three raw counters at the top of the round loop; deleted the stored field; three call
  sites now derive. This makes the gate STRICTER — editions that used to coast on old evidence will be
  held — which is the documented intent, not a regression.
- learned: a name is not a scope. Three fields carried a `round_` prefix for however long, and the
  prefix was doing all the work of convincing readers (me included, on first pass) that something
  cleared them. The audit half of the test asserts the loop clears each one BY NAME, because the next
  person to add a `round_` field will believe the prefix too.
- verified: suite exit 0, 0 compile errors. CF-A drop one reset -> named test fails, warn names
  `round_independent_sources`. CF-B make an empty round read as 0% dependent instead of 100 -> named
  test fails. Full oracle green.
- next (verified): two audit-3 findings left — writer.zig's seedSources provenance, and run.zig's
  PROBE url newline delimiter.

## 0098 — 2026-07-26 — a PROBE url split in two at a newline and failed a deliverable that was up
- did: the declared-acceptance parser documents a PROBE as "exactly one whitespace-delimited url
  token", but the token ended at a space or a tab only — never a newline. Goals are written by people
  and are not always one line.
- why that is not cosmetic: `probes_str` is JOINED BY NEWLINE. A newline left inside a token does not
  merely dirty the url, it splits it into TWO probe entries — the real one, plus a fragment of the
  next sentence. That fragment can never answer 2xx, so the acceptance oracle holds a deliverable that
  is genuinely serving, and the run cannot complete. A delimiter collision between the token grammar
  and the storage encoding.
- did: one character class. Checked whether VERIFY rows have the same shape — they do split on
  interior newlines, but there each line is a separate shell command, which is defensible. Left it,
  rather than widening a fix into a place where the behaviour is arguably correct.
- learned, and this one nearly cost the increment: the first counterfactual reported CF_EXIT=0 with
  CF_INJECTIONS=0. Bash had eaten the `\t` in my python one-liner and turned it into a real tab, so
  the replacement matched nothing and I "verified" an unmodified tree. Green from a counterfactual
  that never injected is the same lie as green from one that never compiled (0087) — which is exactly
  why the injection COUNT is printed. Redone through the Edit tool, which passes text literally, and
  confirmed the injected line by grep before believing the run.
- verified: suite exit 0, 0 compile errors. CF restore the space/tab-only split -> named test fails,
  0 compile errors, injection confirmed present by grep first. Tree byte-identical to pre-CF after
  restore. Full oracle green.
- next (verified): one audit-3 finding left — writer.zig's seedSources provenance.

## 0099 — 2026-07-26 — CORRECTION: two filters I added to save tokens were rejecting good input
- context: the owner reported the harness "appears less intelligent than before" after this sitting's
  token-spend work. Went back over every change from 0079-0098 that removes information, capability or
  input, and MEASURED rather than reasoned wherever measuring was possible.
- CLEARED, with evidence, not argument:
  - 0093 + 0094 (crawl byte budget, boilerplate scoring): built the pre-change and post-change
    crawl.zig side by side as two modules and ran BOTH over one realistic article page. Every content
    marker survives identically — body, all headings, the list, the closing paragraph. The
    social-share block is now pruned. `fitToQuery` returns BYTE-IDENTICAL output at both the 360 and
    the 4000 budget. 1196 -> 1089 bytes, and the entire delta is chrome plus three junk reference
    lines. The clip I worried about never fires on well-formed markdown, which is multi-chunk.
  - 0081 (nine tools dropped from sandboxed turns): the schema filter keys on `ctx.caps == .sandboxed`
    and orchTool's refusal keys on `ctx.caps == .sandboxed`. The same condition, so nothing that could
    have worked was taken away.
  - 0089 (declining to grade a will across a unit change): fires only on the single transition when
    the first bench lands, not run after run.
- FOUND — two, both mine, both the same shape: a filter added to reject bad input that also rejects
  good input.
  1. `isDecline` vetoed any rule whose FIRST WORD is "no". A prohibition is the most natural way to
     write a rule, so "No secrets in logs", "No hardcoded use cases", "No retry without a backoff"
     were all silently discarded as polite refusals. The self-authored playbook — the mechanism by
     which minds get better across rounds — was being thinned at every retrospective. Fixed: a decline
     is short, and when it opens with "no" the next word names the RETROSPECTIVE ("no changes", "no
     lesson"), never the WORK.
  2. `parseDoneList` stopped at the first non-numeric token and "." is not a delimiter — so
     "done: 1, 2, 3." yielded {1,2}, and so did "done: 1, 2 and 3". The engine re-ran work it had
     already finished, every round. I had written that truncation up as a deliberate trade and the
     reasoning holds for PROSE; a trailing period and the word "and" are not prose. The guard is
     unchanged — "(took 3 tries)" and "Subtask 3 is still in progress" still end the list, asserted.
- the pattern, and it is the point of this entry: BOTH defects were introduced by fixes that were
  RIGHT about the failure they targeted. 0086 was right that a refusal must not become a rule; 0087
  was right that prose must not mark work done. Each then drew its boundary with the cheapest
  available signal — a first word, a token class — and the cheapest signal caught legitimate input
  too. A filter's PRECISION is a separate claim from its MOTIVATION, and being sure of the motivation
  is exactly what stops you testing the precision.
- learned: both times my test corpus was built out of the failure I was fixing, so it could not see
  what I was newly rejecting. isDecline's corpus even had a negatives list — Note, Never, Not,
  Northbound, nominate — every n-word EXCEPT the bare "No" that people actually write rules with.
  When adding a filter that REJECTS, write the negative corpus first and draw it from how people
  really write, not from the bug in front of you.
- open, and deliberately NOT changed here: 0097 made the publish gate correct per-round, but
  PUBLISH_MAX_SEED_DEP_PCT = 85 was tuned while the counter was cumulative and the gate effectively
  never bound. A round now needs ~3 independent fetches against 12 seeds to publish an edition. That
  is a policy calibration, not a bug, and it is the owner's to make.
- NOT MINE, untouched and unstaged: desk/src/{chat,main,store}.zig carry an in-flight per-message uid
  feature, modified seconds before this commit. A desk-gate red belongs to that work, not this.
- verified: suite exit 0, 0 compile errors. CF-A restore the bare "no" veto -> the isDecline test
  fails by name. CF-B revert the token handling -> the parseDoneList test fails by name. Both files
  byte-identical to pre-counterfactual after restore.

## 0100 — 2026-07-26 — the publish gate's two conditions were one policy that disagreed with itself
- owner decision, from 0099's open item: make the two agree, with PUBLISH_MIN_INDEPENDENT as the knob.
- the disagreement, stated plainly: `PUBLISH_MIN_INDEPENDENT = 1` says one independent fetch earns
  publication. `PUBLISH_MAX_SEED_DEP_PCT = 85` against a 12-source seeding demanded THREE. Two
  constants, one policy, opposite answers — and nobody noticed for as long as they have both existed,
  because while the counter was run-cumulative (0097) the ratio never actually bound. Fixing the
  counter is what made the contradiction start mattering; it did not create it.
- did: the ceiling is DERIVED — `maxSeedDepPct(seed) = seedDepPct(seed, PUBLISH_MIN_INDEPENDENT)`. A
  hand-picked 92 would have agreed with the bar at today's seeding size and silently disagreed again
  the moment that size changed, which is precisely how 85 got out of step. Named the seeding size too
  (`writer.SEED_SOURCE_TARGET`), since a bound derived from a magic literal is still a magic literal.
- proportionality is NOT abandoned, only stated at the declared bar: a round that fetched nothing of
  its own still cannot publish at any seed count, asserted.
- the ratchet is an invariant rather than an example: for seedings of 1, 5, 12, 40 and 200, the bar
  passes and one fetch below the bar fails. Change SEED_SOURCE_TARGET or the minimum and the two must
  still agree or the test fails — which is the guard the original pair of constants never had.
- learned: this is the same shape as 0072/0073 ("must match" enforced), 0095 (the guard wired to the
  wrong trigger) and 0097 (a name doing a mechanism's work) — a relationship between two values that
  is real, load-bearing, and written nowhere the compiler can see. The recurring answer this sitting
  has been to make the relationship mechanical. Here that meant deleting one of the two values.
- verified: suite exit 0, 0 compile errors. CF restore the hand-picked 85 ceiling -> the named test
  fails, 0 compile errors. run.zig byte-identical to pre-CF after restore. Full oracle green.
