# Growth ledger

The shared memory of every worker who grows this app — human, external AI, resident swarm. Rules:
entries are APPEND-ONLY, newest at the bottom, numbered; the *Open items* section is the only part
edited in place (close yours, add what you discovered). If it isn't in the ledger, it didn't happen.
Sizing discipline: an item a session can't land verified gets split, not half-landed.

## Open items

| id  | pri | item |
|-----|-----|------|
| H26 | med | OWNER'S CALL — capability inconsistency: `pixel_search` is in `chat/tools.zig`'s ADMIN_TOOLS (so the one-shot `/chat/tool` endpoint answers a non-admin 403) AND in the engine's `SANDBOX_TOOLS` (so the SAME user's sandboxed chat turn may run it). Not a hole — the endpoint takes the stricter reading — but the two surfaces are documented as sharing one registry, and `toolSafe` explicitly "delegates to the ENGINE'S sandbox predicate so the two surfaces cannot drift". Pick one: `pixel_search` only reads already-ingested tiles (so arguably sandbox-safe, and it should leave ADMIN_TOOLS), whereas `pixel_capture`/`pixel_ingest` touch the host screen and are rightly admin-only. Pinned by `KNOWN_CAP_OVERLAP` in chat/tools.zig — a NEW overlap fails the build, and so does fixing this one without updating that list. |
| H23 | low | `KeyVault.list()` builds `.provider = alloc.dupe(...) catch continue` inside a struct literal, so an allocation failure mid-entry leaks the dupes already made for that entry. OOM path only. |
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

PROCESS NOTE for whoever reads this next: twice this sitting I started an oracle run BEFORE the
edit it was meant to verify had landed (once because I fired it in the same breath as the edit,
once because the Edit was rejected for a stale read after I had changed the file with `sed`). Both
wasted a full run, and one produced an exit-0 that was ambiguous rather than reassuring. Apply the
edit, confirm it applied, then run.
