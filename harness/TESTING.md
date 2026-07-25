# How to write a test in this repo

Every rule here was paid for by a real failure — the ledger entry that bought it is named in
parentheses. Read this before adding tests; hand it to any agent you ask to write them.

## The shape

- **Register it.** `zig build test` only collects `test` blocks reachable from `src/tests.zig`
  (and `desk/src/tests.zig`) through `@import` chains. Reachability is transitive — a module
  imported by a registered module is covered — so check with `scripts\check.ps1 -Scan`, which
  walks the graph and names any test-bearing file that never runs (0001).
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

## Time

- **Never sleep** for expiry logic. Move the stored stamps instead.
- Synthetic time is only safe for functions that TAKE the time as a parameter. If the code under
  test reads the clock itself, anchor your stamps to that same clock
  (`std.Io.Timestamp.now(io, .real).toSeconds()`) and leave margins wide enough that a second
  passing mid-test cannot flip a verdict. A synthetic `t = 1_000_000` put a "still locked" record
  1.7 billion seconds in the past (0017).

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
Two local quirks worth knowing:

- Windows Defender can kill the build runner's test IPC: the failure names no test, just
  `failed command: ...test.exe --listen=-`. check.ps1 self-heals by rerunning that exact exe
  standalone. A compile error names `zig.exe` instead and is a real red (0001, 0007).
- `zig build test` sometimes prints that same line and still exits 0. Trust the **exit code**.
