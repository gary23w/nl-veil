# How to write a test in this repo

Every rule here was paid for by a real failure — the ledger entry that bought it is named in
parentheses. Read this before adding tests; hand it to any agent you ask to write them.

## The shape

- **Register it DIRECTLY in `src/tests.zig` or `desk/src/tests.zig`.** Do not rely on being
  imported by something already registered: Zig collects tests only from imports it *analyzes*, and
  lazy analysis means a textual import chain proves nothing. `desk/assets.zig` was in the graph via
  `theme.zig` and its tests never ran once, because no test reaches theme's icon paths — and the
  scan called it clean (0029). `scripts\check.ps1 -Scan` now reports both files outside the graph
  (certainly dead) and files reachable only indirectly (not guaranteed); name yours and neither
  applies. If you want proof, count your test names in the runner output.
- **Name the property, not the mechanism.** `"sweep retires only records the throttle would never
  act on again"` forces a future tuning change to restate the invariant; `"sweep works"` does not
  (0017).
- **Assert the module's REAL constants**, read out of the file, never numbers you remember. A test
  that invents its own threshold passes while the code drifts (0015).

## Allocators — a leak is a bug, not a test artifact

- Use `std.testing.allocator`. It counts, and it has found **13 real production leaks** in this
  repo so far (0004, 0009, 0010).
- Never use an arena to make a test pass. The arena hides exactly the class the allocator would
  have caught: `appendSlice(gpa, std.fmt.allocPrint(gpa, ...))` copies the formatted slice and
  orphans the original. Capture it and `defer gpa.free(...)`, or use a stack `bufPrint` for small
  fixed formats. `scripts\check.ps1 -Scan` flags the pattern repo-wide.
- Plain `.append()` of an allocPrint *slice* transfers ownership and is fine — only `appendSlice`
  copies-and-orphans (0009).
- If a struct has no `deinit`, give it one rather than writing a test-only drain helper (0017).

## Touching the filesystem

The house pattern, copied from `src/worker/commons.zig` and `src/worker/vcs.zig`:

```zig
var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
defer threaded.deinit();
const io = threaded.io();
const root = "zig-<thing>-tmp";                       // cwd-relative, named for the test
std.Io.Dir.cwd().deleteTree(io, root) catch {};       // BEFORE: a previous crash may have left it
defer std.Io.Dir.cwd().deleteTree(io, root) catch {}; // and after
_ = std.Io.Dir.cwd().createDirPathStatus(io, root, .default_dir) catch {};
```

## Spawning a real subprocess

`std.Io.Threaded.init(gpa, .{})` hands children an **empty environment**. Under `zig build test` a
spawned binary then comes up with no `TEMP`/`SystemRoot`, its writes fail silently into a
`catch {}`, and the test asserts against a dead store. Pass `.environ = .{ .block = .global }`
(as `src/worker/tools.zig` already does), and probe with a real write→read round trip rather than
"did it spawn" (0015).

If the external dependency is absent, `return error.SkipZigTest` — a skip is honest, a faked pass
is not.

**But a skip is not a neutral outcome — it is a test reporting that it did not run.** Read the
SKIP lines; a permanent skip is a test you are no longer paying for. `client.zig`'s live UPSERT
test skipped on every machine for eight ledger entries (0053) behind a comment confidently
explaining it as "no binary on this box", which was false — the probe VALUE was one neuron-db
silently discards. A wrong explanation for a skip is worse than none, because it stops the looking.

Two consequences worth copying:

- **Share the probe, don't re-hand-roll it.** Four tests wrote their own probe value; one drew a bad
  one. `probeStore()` is now a single real write→read round trip, so "binary absent" and "store
  cannot persist" are told apart and both skip only after proof.
- **Match the shape production uses.** neuron-db atomises input into facts and stores NOTHING for
  input it cannot atomise, while `observe` still exits 0 — so `put` reports success and `get` reads
  null. Real callers store base64 of a JSON record, which always atomises. A test using `"first"`
  or `"v"` is asserting against a store that quietly kept nothing.

## Cost: count it, never time it

A wall-clock budget on a dev box measures Defender, OneDrive and whatever else is running. It
flakes, it gets muted, and the muting becomes the habit — worse than no gate at all. Assert a
**count** instead: process spawns, allocations, round trips. Those are deterministic, identical on
every machine, and can be pinned EXACTLY rather than with a slack factor that hides drift.

Both neuron-db seams carry a `builtin.is_test`-gated `spawn_probe` at their one choke point:
`Neuron.exec` (`client.zig` pins reading N records at N+1 spawns) and `Mem.run` (`oscillation.zig`
pins `observeBatch` at 1 spawn for N facts, against the 5 the loop it replaced costs). Put the
counter where every call already passes through; if there is no such point, that is worth knowing
before you optimise anything.

Price the alternative in the same test. "1 spawn" means nothing on its own — measuring that the
loop it replaced costs N, right beside it, is what makes the number a claim instead of a constant.

A count is not the only exact measure. Two more, both used by `engine.zig`'s `buildTurnTools` test:

- **Pointer identity = zero allocation.** The no-grants path promises it returns the static tools
  block itself, not a copy. `got.ptr == TURN_TOOLS_FULL.ptr` proves that; a length or content check
  would pass just as happily against a fresh allocation on every turn.
- **Byte identity = a cache hit.** The prompt prefix must be identical across a turn's inferences or
  the provider re-bills the whole prefill. Build it twice and `expectEqualStrings`. This is the one
  cost regression with no local symptom at all — everything still works, it just costs more — so it
  will never be caught by noticing. Assert it or don't claim it.

## raylib in a desk test

raylib logs every decode to **stdout**, which under `zig build test` is the runner's `--listen=-`
IPC channel — four `INFO: IMAGE: Data loaded successfully…` lines hang the build indefinitely while
the same binary passes standalone. Silence it around anything that decodes:

```zig
rl.setTraceLogLevel(.none);
defer rl.setTraceLogLevel(.info);
```

## Time

- **Never sleep** for expiry logic. Move the stored stamps instead.
- Synthetic time is only safe for functions that TAKE the time as a parameter. If the code under
  test reads the clock itself, anchor your stamps to that same clock
  (`std.Io.Timestamp.now(io, .real).toSeconds()`) and leave margins wide enough that a second
  passing mid-test cannot flip a verdict. A synthetic `t = 1_000_000` put a "still locked" record
  1.7 billion seconds in the past (0017).

## HTTP handlers

Do NOT extract a pure helper just to get a handler under test — that was the workaround before the
harness existed. `http.testApp` builds a fully-wired `App` over a throwaway data dir, and
`httpz.testing` (vendored) supplies the request/response side:

```zig
var ta = try @import("../gateway/http.zig").testApp(std.testing.allocator, io, "zig-mything-tmp");
defer ta.deinit();
var web = httpz.testing.init(.{});
defer web.deinit();
web.header("authorization", "Bearer nlk_obviously-fake");
web.param("id", "abc");            // route params
web.json(.{ .provider = "openai" }); // request body
try myHandler(&ta.app, web.req, web.res);
try web.expectStatus(400);
```

**Build the io with `http.testEnviron()`**, not `.{}` — `testApp`'s vault, key store and user store
all reach the neuron binary, and an empty environment makes those calls fail. The symptom is
misleading: Auth fails OPEN (register and login appear to succeed off its in-memory maps) while the
vault propagates, so a handler that should answer 201 answers 400 and nothing says why.

```zig
var threaded = std.Io.Threaded.init(gpa, .{ .environ = http.testEnviron() });
```

`keys`, `ledger` and `plugs` start null — set them if the handler needs one. An authenticated test
can `auth.register` then `auth.login` for a session token and pass it as the `nl_sess` cookie.

**Probe the store; do not infer it from register/login.** Auth fails OPEN, so both succeed off its
in-memory maps with no neuron binary present — which is CI's normal state, since `bin/` is
gitignored. A test that treats a successful login as "the store works" will then fail somewhere
else entirely (a vault write answering 400 where 201 was due). Probe and skip:

```zig
const probe = "cHJvYmU";
ta.vault.nb.put("nl_x_probe", probe) catch return error.SkipZigTest;
const got = (ta.vault.nb.get("nl_x_probe") catch return error.SkipZigTest) orelse return error.SkipZigTest;
defer gpa.free(got);
if (!std.mem.eql(u8, got, probe)) return error.SkipZigTest;
``` (Extraction is still right when the
LOGIC deserves to be its own tested unit — evcursor, parsePlan — just not as a testing workaround.)

## Proving a property instead of a spelling

- For escaping, **round-trip through a real parser** and compare the recovered value, rather than
  string-matching the escaped form. That tests what actually matters — that a user string cannot
  forge structure — and survives a legitimate change of escape style (0018).
- For a security property, check the **counterfactual**: swap in a naive implementation and confirm
  the test fails. An escaping test that passes against a no-op escaper is worth nothing (0015).
- For deliberately duplicated code (a documented architectural boundary), pin agreement with a test
  whose `@import` sits **inside the test block** — nothing is coupled outside the test binary, and
  drift becomes a build failure (0016).

## Verifying

`scripts\check.ps1` (or `sh scripts/check.sh`) is the definition of done — the same gates CI runs.

**Never pipe it.** `sh scripts/check.sh | tail -12` reports *tail's* exit status, so a failed run
looks like a pass — this nearly put a false ALL GREEN in the ledger (0037). Run it bare and read
the exit code, or grep the output for the literal `NOT GREEN`.

**This is not specific to the oracle — it applies to every verification you run.** In 0054 a
counterfactual run as `zig build test 2>&1 | grep -E ... | head -4` printed *nothing*, and nothing
was one step from being read as "the injected bug did not fail the test, so the new guard is
worthless" — the exact opposite of the truth. A pipeline can return silence instead of a verdict,
and silence looks like whichever answer you were expecting. Capture the exit code (`; echo
"EXIT=$?"`), or redirect to a file and grep the file. Never let `| grep | head` be the last word on
whether something passed.

**A throwaway extractor is a hypothesis, not a measurement.** Scripts written to survey the tree —
"which escapers lack the arm", "which verbs does dispatch handle" — get trusted like tests, and
they have not been reviewed by anyone. Three misled a single sitting: a hand grep that missed a
fifth JSON escaper because it matched the shape already in view rather than the property (0055);
the pipe above (0054); and a regex that bounded a function body at the next `pub fn`, ran past it
into a private helper reusing the same local name, and produced a confident, wrong "four CLI
commands are unreachable" (0058). Before reporting what a one-off script found, **re-derive the
number a second way** — brace-match instead of regex, count from the other side, spot-check one hit
by hand. When the two methods disagree, the disagreement is the finding.

**A counterfactual has two halves: inject, then observe. Assert the injection landed.** Breaking the
code to prove a guard fails is the strongest verification here — and it silently inverts if the
break never applied. In 0059 a `sed` with over-escaped backslashes changed nothing, the guard
correctly stayed quiet, and the quiet read as "my new guard is worthless" — one step from deleting a
working check. Print the proof: `sed -i ... && echo "INJECTED: $(grep -c <marker> file)"`, then run.
No injection count, no counterfactual — you tested the unmodified code and learned nothing.

Two local quirks worth knowing:

- Windows Defender can kill the build runner's test IPC: the failure names no test, just
  `failed command: ...test.exe --listen=-`. check.ps1 self-heals by rerunning that exact exe
  standalone. A compile error names `zig.exe` instead and is a real red (0001, 0007).
- `zig build test` sometimes prints that same line and still exits 0. Trust the **exit code**.
