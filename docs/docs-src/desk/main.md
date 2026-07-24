# main

**File:** `desk/src/main.zig`  
**Module:** `desk`  
**Description:** The process entrypoint and UI shell for nl-veil's native desktop app "veil-desk": a borderless (self-drawn chrome) raylib window that immediate-mode-draws six tabs over a shared Store, running on the UI thread alongside a poller thread and a chat worker thread.

---

## Purpose Summary

This is the UI/render half of veil-desk, a same-machine companion to the nl-veil server. `main()` sets up the shared `Store`, spawns two background threads (a filesystem/net poller and a model/chat worker), loads fonts and the tray, then runs the raylib event+draw loop. Every frame it snapshots the Store under a lock, draws the active tab (Dashboard/Chat/Deploy/Swarm/Hub/Settings) in immediate mode, and pushes user actions back to the background threads as fixed-size commands. It owns raylib exclusively (raylib is single-threaded) and delegates the heavy server/model/run-directory io to the two background threads, itself doing only light local file reads (the admin key at startup and the SIM.txt automation poll).

## Key Exports

- `main` — process entry: c_allocator + std.Io.Threaded, seeds Store settings (auto-detects data dir, auto-loads <data>/.desktop_key admin token), spawns a poller thread (which shares the UI thread's std.Io.Threaded) and a chat worker thread (which owns a separate std.Io.Threaded so its long streams never contend with the ~1Hz poll), loads TTF fonts with mipmaps/trilinear, inits tray, then runs the activity-gated raylib loop until close
- `Ui` struct + global `var ui` — all UI-thread-only interaction state (focus enum, per-field editors, scroll offsets, dropdown state, window-chrome/drag/maximize flags, chat message-height cache); the Store holds machine state, this holds the cursor's
- `Ui.Field` — a fixed [1200]u8 single-line text editor with UTF-8-boundary caret, selection range, and insert/delBack/delFwd/delSel primitives; `handleKeys`/`editField` drive it (arrows, word-jump, Home/End, Ctrl+A/C/V/X)
- `renderMsg` / `renderWrapped` / `renderTable` / `renderConsole` — one measure-AND-draw markdown block renderer (draw flag) so scroll math and pixels can't diverge; handles fenced code, GFM tables, headings, HR, bullets, blockquotes, and folded `[console]` shell-result cards
- `drawChat` + `drawChatCenter`/`drawChatLeft`/`drawChatRight`/`drawMicroConsole` — the three-pane Chat tab (conversations | message stream+input | swarm-activity/Memory) plus a dual You/Veil shell console with an approval gate
- `drawDeploy` + `submitDeploy` — the full deploy form (providers/models/RSI dials via dropdowns) that hand-builds a JSON body (no DeployReq struct — assembled with a fixed std.Io.Writer + jesc() escaping) mirroring POST /api/v1/swarms and enqueues it as a .deploy command for the poller
- `drawSwarm` + `drawConsole`/`drawDetails`/`drawFiles` — swarm monitor: roster, live event console, config/blueprint details, and a build-workdir file viewer
- `drawSettings` + `flushChatDropdown` — chat-model provider config (Local Ollama / BYOK cloud / Custom URL) with atomic provider+model switching, plus token/notify/speed-mode toggles
- `drawTitlebar` / `handleWindowChrome` / `toggleMaximize` / `drawFileMenu` — self-drawn borderless window chrome (drag, File menu, theme switch, min/max/close, corner resize grip, manual maximize saving the prior rect)
- `pumpTray` — drains tray menu actions and forwards fresh Store notifications to OS toasts
- `std_options` — the only other pub symbol; disables unexpected_error_tracing so the offline-server liveness probe doesn't spam stderr

## Dependencies

- raylib (rl) — window, input, drawing, fonts, clipboard, scissor/culling
- store.zig (Store) — the shared single-source-of-truth guarded by a spinlock; two command rings (pushCmd→poller, pushChatCmd→chat), snapshot constants (STREAM_CAP, MAX_CHAT_MSGS, CAST_TAIL, METRIC_RING)
- poller.zig (Poller) — background thread reading run dirs + hitting the server API
- chat.zig (Chat) — background thread owning model turns, swarm casts, and build-file IO
- theme.zig (t) — Tokyo Night palette, widgets (text/panel/button/tab/checkbox/selector), fonts, cursor, foldAscii
- scan.zig — SwarmSummary/Ev/Metrics/SwarmConfig/FileRow types and parseConsole
- catalog.zig — provider/model/style/stack/mode/minutes tables + resolveBase for the Deploy + Settings dropdowns
- mdutil.zig (md) — inline markdown cleanup, table/HR detection, LaTeX-to-unicode (mathToUnicode)
- tray.zig (Tray) — system tray icon, menu, and OS notifications
- llm.zig — osEnviron() for child-process environments
- log.zig — ring-buffer logger surfaced in the F12 overlay and <data>/veil-desk.log
- std (std.Io.Threaded, std.Thread, atomics, fmt)

## Usage Context

This module is the binary's entrypoint — it runs when the user launches the veil-desk desktop app on the same machine as an nl-veil server. It is the interactive front-end: the user watches the fleet, deploys/monitors/stops swarms, and chats with "the veil" (which can cast the hive for real work). It reads run directories and server state indirectly (via the poller writing the Store) and drives long chat/cast streams via the chat worker; it also auto-loads the server's local admin key so Deploy works with no manual paste. A hidden automation seam polls <data>/.veil-desk/SIM.txt so the borderless window can be driven headlessly for multi-turn steering sims and verification.

## Notable Implementation Details

Concurrency: three threads (UI/main, poller, chat), one shared Store behind a tiny io-free spinlock (store.zig SpinLock: swap-acquire spin, chosen because std.Thread.Mutex is gone in this Zig and contention is trivial). The UI thread owns raylib and keeps the heavy/blocking io — server API, run-dir scans, model streams, build-file IO — OFF itself by delegating to the two background threads; it does only light local fs reads (auto-loading the admin key at startup and polling/deleting the SIM.txt automation file, plus writing a desk-exit-reason.txt). There are only TWO std.Io.Threaded instances: one is shared by the UI thread AND the poller (~1Hz), and the chat worker owns a separate one so its long-running streams never contend with the poll. All cross-thread traffic is fixed-size structs copied by value into two drop-when-full command rings (mkCmd/pushCmd → poller, mkChatCmd/pushChatCmd → chat); the UI copies whatever a frame needs into stack buffers under one short lock, then draws from the copy. Activity-gated redraw: because this is immediate-mode and re-lays-out every chat message's markdown per frame, holding 60fps while idle pins a CPU core — so `ui.hot_frames` keeps 60fps (30 unfocused) for ~0.66s (40 frames) after any mouse/keystroke/token-stream activity, then idles to 20fps focused / 8fps background (heat control); input is still polled every frame. Measure/draw unity: renderMsg and friends run the identical layout with a `draw` flag, so a cached per-message height (ui.mh, invalidated by a fingerprint hashing each message's text_len+role plus the expanded tool_open index, and by wrap-width/cols) matches the drawn pixels exactly; long scrollback is viewport-culled. Fixed-buffer discipline is everywhere and load-bearing — UI snapshot buffers MUST use the Store's own constants (a hardcoded [8192] vs STREAM_CAP was the first streaming-reply crash, called out in-code); Ui.Field is [1200], clip_buf/conv_buf are 64K, sel_text 16K (1<<14), inflight_buf 18432. Borderless window: the app is undecorated and draws its own titlebar/menu/resize-grip; drag uses absolute cursor tracking (getMouseDelta corrupts once the window moves), and maximize is manual (toggleMaximize saves/restores the prior rect because rl.maximizeWindow is unreliable undecorated). Titlebar hit-rects are shared functions (tbFileRect/tbThemeRect) so the drag zone can't drift from the pixels. Fonts load real system TTFs at a high base size (UI 48 / mono 44) with generated mipmaps + trilinear filtering for crisp downscaling, over a comptime glyph_set that adds Latin-1, Greek, super/subscripts, and math/punctuation codepoints (raw LLM-authored goals were rendering NBSP/non-breaking-hyphen as tofu). Chat rendering hides raw tool calls behind clickable chips (toolChip/streamToolLabel collapse a streaming `TOOL: write_file {...}` into \"writing x.html...\"), reasoning behind a thought chip (thoughtChip, labeled \"reasoning\"), and folded `[console]` results into styled terminal cards; text selection is reconstructed each frame from captured on-screen glyph geometry (sel_lines) with binary-search hit-testing. Integration seams: Deploy posts a hand-built JSON to /api/v1/swarms (submitDeploy) with jesc() escaping; Settings' flushChatDropdown changes chat provider+model atomically under one lock to avoid the \"cloud provider pointed at a local model\" trap. The SIM.txt hook (main loop) supports plain messages plus `::` control verbs (loop on/afk/off, tab, right, speed, newconv, conv, approve/bypass/deny, adopt) and forces 30fps sim_mode; command-approval verbs bypass the busy-gate because a parked shell command holds the turn. Optimistic-delete set (del_ids/markDeleting/pruneDeleting) shows \"deleting…\" until the poller drops the swarm from the roster.

---

*Case file grounded in the module's `//!` header and public API.*
