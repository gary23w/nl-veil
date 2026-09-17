# watchdog

**File:** `desk/src/watchdog.zig`  
**Module:** `desk`  
**Description:** A watcher thread that turns a desk UI hang into a durable record: a stale frame heartbeat, or Windows calling a still-drawing window hung, is written straight to `{data}/desk-hang.log`.

---

## Purpose Summary

A hang leaves nothing to read afterwards: no panic, no dump (Windows dumps faults, not hangs), no stack. Windows twice closed the desk with Event 1002 ("stopped interacting with Windows") while the desk log's last line was 14 minutes old, so the only way to learn where the UI stalls is to watch while it stalls. The frame loop stores a heartbeat, a phase and a frame count in atomics; a separate thread, which keeps running when the UI thread does not, samples them every 250 ms and reports a stall with the phase it happened in, then the recovery. The module was added on 2026-08-04, made to write through to disk the same day after the app died with the watchdog running and left no line of it, and on 2026-09-16 given the window handle so it also records Windows' own hung-window verdict.

## Key Exports

- `start(io, data_dir, hwnd)` — spawn the watcher (a call while it is running returns at once); records go to `{data_dir}/desk-hang.log`; `hwnd` is the main window's native handle or null. If the thread cannot spawn, a warning is logged and the desk runs without a watchdog
- `stop()` — clear the running flag; the watcher exits after its current sample
- `beat(p)` — top of every frame: stamp the heartbeat from the module's own clock and set the phase; a no-op until `start` has run
- `mark(p)` — set the phase inside a frame without a new timestamp, so a stall is charged to the section that was running
- `frameDone()` — advance the frame counter
- `Phase` — `idle_start`, `input`, `sim`, `draw_chrome`, `draw_tab`, `gl_swap`; `name()` is the label written to the log (`idle_start` is "frame-start", `gl_swap` is "GL endDrawing (driver)")
- `stallReport(now, last_beat, already_reported_at)` — the pure timing rule: the stall length in ms once the beat is `STALL_MS` (4000) old, else null, and null again until `REPEAT_MS` (15000) has passed since the last report
- `stallCount()` — stall reports this process has made, repeats included
- `osHungEpisodes()` — episodes in which Windows called the window hung while the frame counter was still advancing

## Dependencies

- std (`std.atomic.Value`, `std.Thread.spawn`, `std.fmt.bufPrint`)
- std.Io — `Io.Timestamp` on the real clock, and `Io.Dir` stat, create and positional write for the hang record
- nap.zig — `nap.ms` for the 250 ms sampling sleep
- builtin — `os.tag` picks the user32 `IsHungAppWindow` extern on Windows and a stub returning 0 elsewhere
- log.zig — every record is also logged with `log.warn`

## Usage Context

`runApp` in `desk/src/main.zig` copies the data dir out of the Store under its lock and calls `watchdog.start(chat_threaded.io(), wdb[0..wdn], rl.getWindowHandle())` before the frame loop, with `defer watchdog.stop()`. Every iteration opens with `beat(.idle_start)`. A drawn frame marks `.input` before window chrome and key handling, `.draw_chrome` before the titlebar and tab bar, `.draw_tab` before the active tab body, and `.gl_swap` in the `defer` that calls `rl.endDrawing()` and then `frameDone()`. The hidden or minimized path calls `rl.pollInputEvents()` and `frameDone()` and naps `HIDDEN_SLEEP_MS` (200 ms), well inside the stall window. `Phase.sim` is declared but main.zig has never marked it, so a stall anywhere before `mark(.input)`, including `pumpTray` and the SIM.txt probe, reports as `frame-start`. `stallCount()` is read only by the module's test and `osHungEpisodes()` has no caller. The record has been used once already: main.zig cites 684 stalls in desk-hang.log, every one in `GL endDrawing (driver)`, as the evidence that sent a minimized window down the hidden path. `desk/src/tests.zig` registers the module.

## Notable Implementation Details

- **Frozen loop.** When `stallReport` fires, the watcher writes `UI FROZEN {ms}ms  phase='…'  frame=#…  stall_no=…`, writes it again every 15 s while the stall lasts (each repeat bumps `stall_no`), and writes `UI resumed after {ms}ms frozen` once the beat is fresh again.
- **Live loop, hung window.** On Windows with a non-null handle, every sample also calls `IsHungAppWindow`, which turns TRUE once the thread has gone about 5 s without a credited read of its message queue. That can happen while the loop draws at 60 fps, and the heartbeat never sees it. If the verdict is TRUE and the frame counter moved since the previous sample, the watcher opens one episode and writes `OS SAYS NOT RESPONDING, frame loop alive  frame=#…  episode_no=…`; when the verdict clears it writes `OS credits the window again after {ms}ms ({n} frames drawn meanwhile)`. A TRUE verdict with a stopped counter is left to the heartbeat branch. The case that prompted it was the tray's per-frame window-filtered `PeekMessageW`, which let DWM ghost the live window and swallow its clicks (see tray.zig).
- **Written straight to disk.** Each record goes to `log.warn` and to `writeHangRecord`, which stats the file, opens it without truncating, writes at the current size and closes it on the spot. The first version used only log.zig's ring, which a flusher thread drains later, and a freeze that ended with the process killed left nothing. Write errors are ignored, a path that overflows the 512-byte buffer disables the file record, and the file lines carry no timestamp.
- **One clock.** `beat` reads `Io.Timestamp.now(.real)` itself rather than taking a time from the caller: `rl.getTime` counts from raylib init, and mixing the two epochs gives a watchdog that never fires or never stops.
- **Thresholds.** `STALL_MS` 4000 is just under the ~5 s after which Windows calls a window unresponsive, so the line lands first; `REPEAT_MS` 15000 turns a long freeze into a visible progression; `SAMPLE_MS` is 250.
- **A sampler that cannot park.** The watcher is a plain `std.Thread`, the kind of thread a stray thread alert parked for good inside `io.sleep` on 2026-09-02 (see nap.zig), and a watchdog stuck that way is the one that never reports. It samples through `nap.ms`, a non-alertable wait; until 2026-09-16 it called `io.sleep(...) catch return`, and that `catch` could never fire on a thread with no cancelation to deliver. `stop()` is seen at the next sample.
- **Reading the phase.** It names the last section the loop entered. `gl_swap` means the driver's buffer swap, not desk code (the header cites a confirmed nvoglv64.dll fault and hybrid AMD + NVIDIA graphics on the machine it was built on); any other phase narrows the stall to one section of desk code.
- **Tests.** The `stallReport` rules; every `Phase` has a name and `gl_swap`'s mentions the driver; and a real thread on a real clock that must see a stall, fall silent after recovery, and leave `UI FROZEN` and `draw active tab` in `./desk-hang.log`. That test passes a null handle, so the OS-verdict branch has no test.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
