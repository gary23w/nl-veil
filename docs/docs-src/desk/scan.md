# scan

**File:** `desk/src/scan.zig`  
**Module:** `desk`  
**Description:** The filesystem data layer of the veil-desk native dashboard: it reads the veil engine's on-disk run directories directly (no HTTP/auth) — distilling event streams, swarm rosters, config, and built files into fixed-size POD structs the UI can snapshot — and writes the operator control/STOP files back into those dirs.

---

## Purpose Summary

scan.zig is veil-desk's filesystem data layer. Because the desktop app is a same-machine companion to the veil server, it bypasses HTTP and auth entirely and reads the run directories under `<home>/data` exactly as the engine writes them (events.jsonl, swarm.json, .goal_brief, .blueprint, .build_manifest), and it writes back the operator-bus files (control.jsonl and the STOP sentinel) the worker drains. Every IO function here runs on the poller thread and produces plain-old-data structs that get published into the mutex-guarded Store; the UI thread never performs IO. It also owns the pure, parity-critical parseConsole for the chat's folded shell-output cards, which — unlike the rest — is called from the UI renderer, not the poller.

## Key Exports

- `tailEvents` / `tailEventsFrom` — tail the last `out.len` meaningful events.jsonl records into an `Ev` ring (oldest-first) and fold cumulative `Metrics` in one windowed read; the `from` variant folds only bytes past an offset to ignore a stale prior run in a reused dir
- `listSwarms` — enumerate run dirs under a data dir into `SwarmSummary[]`, handling flat CLI layout (data/<name>), nested server deploys (data/u<uid>/<hex>), and chat casts (data/u<uid>/_chat/builds/<conv>); sorts newest-mtime first
- `listWorkFiles` — the Files tab: parse `.build_manifest` ("path|bytes|valve", de-duped to latest size) UNION a bounded recursive walk of work/ so nested/oddly-named files still show
- `readWorkFile` — read a built file's bytes for the viewer from <data>/<rel>/work/<sub>, rejecting absolute/`..` escape paths and truncating past out.len
- `readSwarmConfig` — load swarm.json + .blueprint into `SwarmConfig` (full goal, provider/model/style/mode/autonomy, minutes, internet/gap_assess flags, composed minds roster, deliverable blueprint) for the Details tab
- `writeStop` — drop a per-turn `STOP` sentinel file into a run dir (faster than a round-boundary control op)
- `writeControl` — append one operator JSON line (say/set_goal/stop) to a swarm's control.jsonl, the bus the worker drains (read-modify-rewrite under the hood)
- `serverOnline` — TCP connect-and-close probe of 127.0.0.1:port for the "server online" indicator
- `parseConsole` — pure/deterministic parser turning a folded "[console]\n$ cmd\n<output>" message into `ConsoleParse` (cmd, true output-line count, and a popped status note → `ConsoleStatus` label)
- Data structs: `Ev`, `Metrics`, `SwarmSummary`, `FileRow`, `SwarmConfig`, `ConsoleParse`/`ConsoleStatus` — all fixed-buffer POD with `len` fields and accessor helpers

## Dependencies

- std (std.mem scanning/sorting, std.fmt.bufPrint/allocPrint)
- std.Io — Zig's newer explicit-IO API: Io.Dir.cwd() for statFile/openFile/readPositionalAll/readFileAlloc/iterate, Io.net for the loopback probe, Io.Threaded/Io.Timestamp in tests
- log.zig (log.trace instrumentation)
- Data contract with the veil engine/server (not imports, but the real coupling): events.jsonl, swarm.json, .goal_brief, .blueprint, .build_manifest are engine-written and read here; control.jsonl and the STOP sentinel are written here for the worker to drain — the same files the server's swarmFiles/control handlers use

## Usage Context

The IO functions run on veil-desk's poller thread (Zig + raylib). Each poll tick it runs listSwarms over the data dir — which, via addSwarm, calls summarizeTail (roster score/stopped) for every run dir on disk — and for the selected swarm calls tailEventsFrom (log console + live Metrics), listWorkFiles/readWorkFile (Files tab), and readSwarmConfig (Details tab); serverOnline feeds the tray/status indicator. Operator actions from the UI route through writeStop and writeControl, which write directly to the run dir instead of the authenticated HTTP endpoint. The one non-poller export is parseConsole, called by chat.zig's card renderer in both its measure and draw passes, which is why it must be pure and side-effect-free.

## Notable Implementation Details

Everything is fixed-buffer POD (inline byte arrays + u8/u16 length fields, MAX_LOG=400/MAX_SWARMS=64/MAX_FILES=64) so structs copy cleanly into the Store snapshot with zero heap ownership crossing the thread boundary. JSON is read by hand-rolled flat scanners (jsonStr/jsonInt/jsonStrList/jsonStrBig) that just indexOf a `"key":` needle — deliberately NOT a real parser, to stay cheap folding multi-MB streams every poll (~1Hz); jsonStr unescapes into a 256-byte scratch while jsonStrBig exists solely because a swarm goal can exceed that. The load-bearing perf fix is windowed tailing: tailEventsFrom reads only the final TAIL_WINDOW (256KB) and summarizeTail only the last 64KB, each skipping the torn first partial line — replacing an old whole-file (8–16MB) read every second that was the poller's slice of local thrash. tailEventsFrom is two-pass over the window: pass 1 folds cumulative Metrics (cost/score token totals are cumulative, so the newest line in the window carries true run totals — though `calls` is instead summed across the window's cost lines), pass 2 keeps the last out.len meaningful lines in a modular ring then compacts to oldest-first. foldMetrics special-cases that RESEARCH/discourse casts emit no "score" — their %/best come from "phase" now/best, which is what un-sticks the progress label at 0%. parseEv narrates each event kind into a human console line (act = tool+first-string-arg-gist+result via key-agnostic argGist; tick with no monologue = "moment {dt}s: {trace}") and returns false for unsurfaced kinds (psyche/flare/trust). listSwarms encodes three on-disk layouts and stores id as the path relative to data_dir so control/tail resolve for all of them; it descends exactly one container level, plus a special _chat/builds/* descent for in-place chat casts. listWorkFiles unions the manifest with a depth-4 work/ walk (skipping dotfiles/__pycache__/*.pyc) because the manifest only records flat write_file outputs. Gotchas: serverOnline does a connect-and-close with `.mode = .stream` and deliberately passes NO timeout option because this Zig's Windows connect panics on a timeout option (a dead local port refuses instantly anyway, so none is needed); writeStop's sentinel is checked per-turn whereas a control.jsonl stop only lands at a round boundary. parseConsole is explicitly pure and parity-critical — its out_n is the TRUE line count (may exceed the filled slots so a "+K more" footer stays honest), and the trailing status note is classified on the RAW tail (never through the capped buffer) so a dump longer than the caller's slice can't hide a failure, with extra handling for a note glued to the last line when a command's final write lacked a newline. A substantial in-file test suite exercises the parsers on synthetic events and best-effort against the real ../data dir.

---

*Case file grounded in the module's `//!` header and public API.*
