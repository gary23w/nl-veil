# the veil — v1.0.1-beta-2

**The second beta.** beta-1 was about the veil bringing its own model. This one is about that model
*finishing the job* — 19 commits, most of them from watching a 12B fail a real browser task over and
over and finally checking whether the instructions we handed it were true.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.0.1-beta-2-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.0.1-beta-2-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.0.1-beta-2-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.0.1-beta-2-linux-x86_64.zip`** |

Unzip it, then run **`veil.exe`** (Windows) or **`./veil`** (macOS/Linux). That single action starts the
server *and* opens the app.

> **Do NOT download "Source code (zip / tar.gz)"** at the bottom of this page. GitHub attaches those to every
> release automatically — they're the raw repo, and building from them needs the Zig compiler. Likewise
> `install.ps1` inside that source archive is a *developer* installer, not the app.
>
> The `veil-server-*` files are the **headless** control plane for servers — no desktop app. Most people
> don't want these.

**Unsigned build:** these binaries aren't code-signed yet, so Windows shows *"Windows protected your PC"*
(click **More info → Run anyway**) and macOS says the developer can't be verified (**right-click → Open**, or
`xattr -dr com.apple.quarantine <folder>`). Signing certificates are still on the list.

---

## 🆕 New since beta-1

### 🌐 The browser actually finishes the task now

The biggest change in this release isn't code — it's that four instructions we shipped were **false**, and a
model that reasoned correctly from them concluded the task was impossible. Each one was internally
consistent and locally sensible. Each one killed sessions.

- **It knows the browser is yours, and that signing in is allowed.** `browser_navigate` said "a login-walled
  dashboard — reach for this", and `browser_type` said "never type passwords or other credentials". From those
  two lines the model derived, validly: the page needs a credential, I may never type one, therefore I cannot
  get in. It then defended that conclusion by denying it had a browser at all — reciting its own tool list back
  as proof the tools were absent. Both descriptions now state the truth: the browser is **your own**, carrying
  **your signed-in sessions**, and where a site *is* signed out the veil may sign in — into that site's own
  login form, never into a page that merely asks, and never echoed back into a reply or a file.
- **Page reads are projected, never truncated.** Tool results were clipped head-7KB + tail-2KB, and a browser
  page state is a **ref table** — so byte-offset elision silently deleted elements, with nothing to distinguish
  a dropped ref from an absent one. Measured on a live 18,317-character x.com read: asked which ref was the
  search box, the model answered **154 from the full payload, 154 from a projection, and 8 from the clipped
  one**. Not "I can't find it" — a confident wrong ref it would then have typed into. The projection keeps
  every interactive ref, drops the per-element JSON repeated 187 times, and is **59% smaller**. The turn that
  overflowed the window at ~10,790 tokens against a ~9,216 window now lands around 3,600.
- **Refs die on navigation, and now it's told so.** Nothing in any browser tool description said that
  navigating invalidates every ref, so the model kept reasoning with refs from a page it had already left.
  With the corollary the traces showed: typing into a ref whose tag is `button` or `a` **activates** the
  control rather than entering text — which is exactly how one run clicked itself off a composer onto a
  trending page and then re-read that page three times waiting for a composer it structurally cannot have.
- **Ambiguity is named instead of hidden.** On one compose page, of 175 interactive elements **17 carry no
  label at all** and 63 more share a duplicate — eleven separate elements all reading "More". Rendered plainly
  those look like 175 distinct choices, so the model picks confidently and lands somewhere random. They're now
  marked `(unlabelled)` and `(dup N)`. This doesn't invent information; it tells the model when its next pick
  is a coin flip.
- **The approval wall that fired on the thing you just asked for is gone.** `browser_navigate` carried "do not
  click irreversible actions (pay/submit/delete) without explicit human approval" — but *your instruction is
  the approval*. Given "go on twitter and post silly comments", the veil visited 32 distinct posts, drafted 14
  replies, wrote them to a queue file and **scheduled** them — everything except the act it was asked for — and
  when told to go ahead answered "No post. Pacing blocks it." (`browser_click` and `browser_eval` keep their
  own approval language; that was left as a separate decision.)
- **It says "won't", not "can't".** The compact system prompt now ends with one line naming **every tool it was
  actually served**, derived from the final belt string so it cannot drift. Plus a doctrine — decline by
  judgment in those words and give the real reason, never call a listed tool missing — and a corrector that
  rides the recall channel when the previous reply denied a tool that is on the belt, so it lands adjacent to
  the denial it has to break. Verified live: where the old build said "there are no browser tools on it", the
  new one says "I won't. I'm not allowed to use the browser to post on your behalf", and under pushback holds
  with "I do, but not for this."
- **A recovering model isn't killed mid-recovery.** The loop guard counted refusals across the whole turn, so a
  model that hit the guard, read the warning and moved to a different call still carried its old strikes. One
  run's last words were "the loop guard is firing and it's right, I'll try a different ref" — the correct
  response — and it was stopped anyway. A call that isn't refused now clears the counter.

### 🌙 AFK mode drives toward your goal instead of its own

AFK (the run-until-you-stop-it loop) was built as the normal auto-loop plus overrides, and inherited machinery
whose safety depended on stop conditions AFK had removed. **The ordinary auto-loop is byte-identical** — every
fix below branches on the AFK tier.

- **The goal was the engine's own kick text.** From the second turn onward, six consumers — the drive picker,
  the search intent, the course check, the repeat guard and two more — were reading the desk's re-arm sentence
  ("Auto-loop armed: continue driving toward the goal…") as your goal. An AFK session re-grounded itself to its
  own re-drive sentence. It now reads the pinned first user goal.
- **It stops asking a question it then overrides.** AFK ran the normal driver — "name the next step, or output
  DONE" — and when the model answered DONE, appended "(the goal looks achieved — continuing anyway)". Every
  cycle reached a conclusion the loop immediately contradicted, and the only way to satisfy both was to invent
  work. Observed live: 18 tool calls, two complete post-then-verify cycles, starting a third. In AFK the DONE
  branch isn't offered at all.
- **The re-drive is written, not canned.** What used to be posted was the identical sentence every cycle. The
  prompting model now writes it from what the transcript shows was just built. When it can't, the loop posts a
  bare "keep going" — deliberately bare, because a fixed paragraph dressed as a considered next step is exactly
  what this replaces.
- **The "cast: continue" spin is bounded.** When a drive inference came back empty, both arms substituted the
  literal string "continue" — safe in the normal tier because its repeat guard bounds the streak, and AFK skips
  that guard by contract. A bare "continue" carries no direction, so the reply is a promise, so the next
  inference degenerates again. AFK now re-grounds to the durable goal on the second degenerate inference.
- **One provider hiccup no longer ends the session.** The desk cleared both loop flags on `done`, while the
  server exits an AFK turn on a single failed drive inference — so a transient error ended a session you were
  promised only you could stop.
- **Steering always reachable.** An AFK turn is one long server-side turn, so the local busy flags could read
  false while the veil was working, leaving a Send button that then refused with "finish or Stop the current
  reply". A live server turn now always gets the control column.

### 🪟 Closing the desk window no longer kills the server *(Windows)*

The desk and the server are one process, so closing the window took the server, the chat workers and any
running turn with it. Now the titlebar **X hides the window to the tray** and everything keeps running; only
**File → Quit** or **tray → Quit** ends the process. While hidden it skips input, layout and drawing entirely
and idles at 5 Hz — no GL, no swap.

Three tray defects had to be fixed for the window to be reachable at all: **clicking the icon never worked**
(the shell sends `NIN_SELECT` under `NOTIFYICON_VERSION_4`, and only the older click messages were handled —
which is why right-click's menu looked fine while restore was dead), a close request aimed at the tray's own
window **destroyed the icon** and stranded a hidden desk with no way back, and an **explorer.exe restart
dropped the icon permanently**. Logging off no longer force-kills a hidden desk either.

**Windows only.** This is gated on a real, live tray icon existing — Linux and macOS keep the old
quit-on-close behaviour until a real StatusNotifierItem lands, rather than hiding a window behind an icon
that isn't there.

### 🗂 Memory recalls a fact you phrased differently

Recall's empty answer reads to the model as an authoritative "no" and overrides its own context. When the
spreading-activation pass finds nothing lexically linked, the tool now asks flat recall before declaring
emptiness — whose semantic fallback and topic gate can resolve a paraphrase that shares **no words** with the
stored fact. Measured through the chat stack on isolated conversations with the same seeds and phrasing:
grounded answers went **0/3 to 2/3 with one partial**, because turn-start recall now injects
paraphrase-bridged facts ("machine that routes customer orders" → "the dispatch gateway listens on port 7141")
that a lexical-only lookup never surfaced.

This needed a release-plumbing fix to actually reach you — see below.

### 🧠 The swarm improves its own work more carefully

Machinery for swarm runs, not for chat. Most of it is on by default and every piece is env-gated for A/B.

- **A self-edit that breaks the source is reverted in place.** Every `patch_system` gate ran *before* the
  write and nothing after it, so an edit that left the engine un-parseable stood until the next human build.
  A post-write verify (a real `zig ast-check` for `.zig`, the shared syntax gate otherwise) reverts from a
  pre-image and reports it blocked. Fail-open, so a machine without the checker isn't stopped.
- **Authored tools are compiled before they're registered.** `make_tool` validated the name, size and schema
  and nothing about the body — a syntax error entered the registry and first surfaced at the tool's first call,
  possibly many rounds later.
- **Lessons are scored by whether they helped.** The engine minted verified fail→fix lessons and recalled them,
  but never checked whether a recalled lesson preceded an actual fix. Now one that keeps preceding fixes
  surfaces first and one that never does fades. Strengthen-only, so a reward can never mint or resurrect a
  lesson, and engine-driven, so a mind can't inflate its own.
- **Recurring tool sequences become candidate habits.** The engine counts successful sequences per mind with
  zero extra model calls and proposes frequent ones into a quarantine. Quarantine only — nothing auto-registers,
  auto-runs, or reaches a prompt.
- **A stuck chain gets a tournament** *(opt-in)*. On a measured stuck signal the engine freezes the build, spends
  three rounds on independent candidates from that baseline, and lands the best — with an anti-shrink guard so a
  winner can't hold fewer files than the baseline.
- **A round that breaks one check while fixing another is no longer invisible.** The best-known-good build's
  failure set is the champion and each later round the challenger, so a new break is reported even when the
  aggregate score is flat or up (and flagged when it's masked).

### 🔧 One more way the release was going to lie to you

The semantic recall above **would not have worked in any published bundle.** CI builds the memory engine into
a path the bundle script can't guess and hands it over as a prebuilt binary — which the bundle script reuses
verbatim, so its own build line never runs there. The semantic feature flags were added to all three local
build scripts and not to CI, so every download would have carried a lexical-only engine while these notes
claimed paraphrase recall. Fixed, and `scripts/check.sh --scan` now compares all four build sites and fails if
they disagree.

Same shape as the three found last release: a failure whose only signal is *absence*.

> Data format is unchanged — your `./data` carries forward from beta-1 and the alphas.

---

> **This is a beta.** A real, working build — but with known gaps, stated up front rather than buried:
>
> - **Admin password & network exposure.** By default the server listens on **all interfaces** so other
>   devices on your network can reach the web UI. When it's reachable and you *haven't* set
>   `NL_ADMIN_PASSWORD`, it **generates a random admin password**, verifies it actually logs in, and writes it
>   to `data/admin-password.txt` — reusing that file on later boots, so a restart never invalidates the password
>   you wrote down. Set `NL_ADMIN_PASSWORD` to choose your own, or `NL_BIND=127.0.0.1` (or `localhost`) to pin
>   the server to this machine only (then the local admin is `admin@neuron-loops.local` / `changeme`,
>   same-machine trust). This program runs code as you — treat an exposed instance accordingly.
> - **The web UI lags the desktop app.** It is a full client — chat with sub-chats, tasks, swarms, settings,
>   dashboard, and an installable PWA — but not at parity: the narrator, OpenDyslexic mode, MCP server
>   management, and the memory keep/drop approval queue are desktop-only.
> - **Close-to-tray is Windows-only.** On Linux and macOS the close button still quits.
> - **Desktop bundles are built per-OS.** The GUI links the platform graphics stack and can't be
>   cross-compiled, so each OS bundle is built natively in CI. The standalone server covers all five targets.
> - **The desktop needs OpenGL 3.3.** On a VM, an RDP session, or a box without a real graphics driver, use
>   the web UI (the app tells you this instead of exiting silently).
> - **The Download buttons on the README and the docs site point at a specific tag**, because
>   `/releases/latest` skips pre-releases. They'll point here until the next beta.
> - Expect rough edges — please file what you hit.

**A local-first AI workspace that actually does the work.** One download, one click: a hive-mind engine,
a native desktop app, a web UI, a CLI, and a persistent associative memory — all in a single self-contained
bundle. No Docker, no Node, no cloud account required.

Bring your own model — or use none: the veil serves **the-veil-12b** in-process, with nothing separate to
install. Point it at a local Ollama or any hosted endpoint instead whenever you prefer. Either way it builds,
researches, browses, remembers, and schedules — on your machine, with your keys, against your files.

---

## Install

Download the bundle for your OS below, unpack it, and run it:

| OS | Run |
|---|---|
| **Windows** | double-click `veil.exe` |
| **macOS** | `./veil` |
| **Linux** | `./veil` |

That one action starts the **local server** (`http://127.0.0.1:8787`) **and opens the desktop app**. Nothing else
to install — the bundle carries the server, the desktop, and the memory engine.

Prefer headless? `veil --server-only` runs the server alone (services, containers, remote boxes) and the web UI
stays at `127.0.0.1:8787`.

---

## What it does

### 🧠 A hive mind, not a chatbot
Deploy a **swarm** and it decomposes the goal, spawns specialist minds, gives each ownership of real files, and
lets them build, critique, and reconcile in parallel against one shared workdir with its own micro-VCS. Minds
share findings through a common memory, so a discovery by one becomes context for all — and that memory can
**compound across runs** through a swarm lineage.

### 💬 Chat that builds — with branches
The chat is an agent with real tools: read/write/edit files, run shell commands (with an approval gate), run
tests, search and fetch the web, drive a real browser, and call MCP servers. **Auto-loop** lets it drive itself
toward a goal until done — or in AFK mode, until you stop it. Advanced reasoning is the default (fast mode opts
out), a dissenting reviewer checks the answer, it looks before it plans, and it repairs failures instead of
announcing success. **Branch any conversation** into sub-chats that share one memory and workspace. Press
**Stop** and it stops — even mid-tool.

### 🔋 A model in the box
**the-veil-12b** runs inside the veil's own process — GPU-accelerated where one is available, CPU otherwise.
Download it from Settings (or `veil model pull`), check for updates and swap in place without a restart, or
import a GGUF you already have. There is no second runtime to install and nothing leaves the machine.

### 🧩 Per-role model trio
Point **coding**, **thinking**, and **prompting** at *different* models — a strong coder for the build stream, a
cheap planner for housekeeping, something else to drive the auto-loop. Or keep one model for all three (the
default). Mix local and hosted freely; unset roles inherit the coding model.

### 🗂 Memory that persists
Backed by **neuron-db**, an associative memory engine. The veil accumulates a durable model of your work: facts
and preferences you tell it, an operational **playbook** learned only from *verified* failure→fix transitions
(and pruned by relevance, not age), reusable **skills**, ingested **documents** (per-doc scopes with
across-document recall), a **conversation family mind** shared across sub-chat branches, and a user model.
Recall is relevance-gated, trust-weighted, and **resolves paraphrases** — a question sharing no words with the
stored fact still finds it. Every learned entry is quarantined for your **keep / drop** approval before it
binds, so the memory can't quietly poison itself.

### 👁 Vision-as-text (Pixel RAG)
Drag an image onto the chat, or paste a screenshot with **Ctrl+V**. Its text is extracted with your OS's built-in
OCR — **Windows.Media.Ocr** on Windows, **Vision** on macOS, or a vision-model fallback where the OS has neither —
indexed as a searchable document, and handed to the model as grounded context. Web pages can be ingested the same
way: rendered to screenshot tiles and indexed by what's actually on screen, not by scraped HTML.

### 🌐 Real browser control — headless or your own
A headless (or visible) Chromium the AI drives: navigate, click, type, evaluate, capture. Page reads are
**projected, not truncated** — every interactive element survives, ambiguous and unlabelled ones are marked as
such, and the tools state that navigating invalidates every reference. It can verify a web app it just built by
*using* it — interact, snapshot the live page (`pixel_capture`, no reload), and confirm what actually rendered.
Or install the **browser extension** and point it at your own Chrome/Edge to work inside your real, logged-in
sessions — it stays paired across restarts.

### ⏰ Scheduled tasks
Recurring or one-shot runs — "every morning at 9", "in 20 minutes", "daily digest". Each task keeps its own memory
across runs in its own permanent working directory, and can revise its own prompt and cadence as it learns what
works.

### 🖥 A real desktop app
Native (Zig + raylib), not a browser wrapper: dashboard with live metrics, multi-chat with concurrent turns,
sub-chat branches, swarm control, task editor, file viewer with syntax highlighting, and an in-app shell. On
Windows it lives in the tray, so closing the window leaves the server running. Plus a full **web UI** at
`127.0.0.1:8787` and a **CLI** (`veil chat`, `veil cast`, `veil list`, `veil sched`, `veil doctor`).

### ♿ Accessibility built in
OpenDyslexic mode, global text scaling, bold cut, and a **narrator** that reads replies aloud through your OS's
own text-to-speech — with `Win+H` dictation into the input.

---

## Bring your own model

One shared catalog (`models.yaml`) drives every menu in the app.

- **Built-in** — the-veil-12b, served in-process. No key, no separate runtime, no egress.
- **Local** — Ollama on your machine. Zero egress.
- **Hosted / BYOK** — OpenAI, Anthropic, DeepSeek, Moonshot (Kimi), Groq, Google, Z.AI, Hugging Face,
  OpenRouter, and any OpenAI-compatible endpoint.
- Prompts **scale to the model**: a small local model gets compact doctrine, lean injections, and a one-line
  manifest of every tool it was served; a frontier model gets the full treatment. Provider quirks self-heal (a
  rejected parameter is detected, rewritten, retried, and remembered per model).

Keys never leave your machine and are never in the repo. Provider (BYOK) keys are sealed at rest with
**AES-256-GCM** in the local store. The desktop's own chat key and GitHub token are kept as plain files inside
your user-private `./data` directory — deliberately, so the veil can *use* the GitHub token on your behalf
instead of it being locked in a blob it can't read. The trust boundary there is your OS login.

---

## Local-first by construction

- Your data stays in `./data`; provider keys are sealed at rest in the local store.
- Nothing is sent anywhere except the model provider *you* configured — plus the downloads you ask for (the
  built-in model's weights from Hugging Face, and any page the web tools fetch on your instruction).
- The server listens on your network by default (so your other devices can reach the web UI);
  `NL_BIND=127.0.0.1` pins it to this machine only.
- Run it fully offline with the built-in model or a local one — memory, files, browser, and scheduling all still
  work.
- The `run_python` / `run_tests` tools use your system Python 3 if it's installed; without it, they say so
  rather than failing silently. Nothing else in the bundle needs it.

---

## Downloads

| Asset | Contains |
|---|---|
| `veil-v1.0.1-beta-2-windows-x86_64.zip` | **Full bundle** — server + desktop + memory engine |
| `veil-v1.0.1-beta-2-macos-arm64.zip` / `-macos-x86_64.zip` | **Full bundle** for macOS (Apple Silicon / Intel) |
| `veil-v1.0.1-beta-2-linux-x86_64.zip` | **Full bundle** for Linux |
| `veil-server-v1.0.1-beta-2-<os>-<arch>` | **Server only** — headless hosts, containers, remote boxes (no desktop) |
| `SHA256SUMS-*.txt` | Checksums for each platform's assets |

The full bundles are built natively on each OS. The standalone server binaries cross-compile cleanly to
Windows, macOS (Intel + Apple Silicon), and Linux (x86_64 + arm64).

**Linux desktop note:** the desktop links the system GUI stack. If it doesn't start, install the usual runtime
libs (`libGL`, `libX11`, `libXrandr`, `libXinerama`, `libXi`, `libXcursor`) — or just use `veil --server-only`
plus the web UI.

---

## Build it yourself

```sh
git clone https://github.com/gary23w/nl-veil
cd nl-veil
sh scripts/build-official.sh      # → bin/
```

Zig 0.16. The script bootstraps its own toolchain, builds the full bundle for your OS, cross-compiles the server
for every other target, and writes checksums + a manifest. It never touches your dev tree, so you can cut a
release while the app is running.

---

## Notes

- Everything runs as **you**, on **your** machine. Shell commands are gated behind an approval prompt (with an
  opt-in bypass) — read what it wants to run.
- The desktop and server talk over loopback; tools execute on the client machine even when the server hosts the
  brain.
- Data format is stable for v1.x — `./data` carries forward.

**Full source:** https://github.com/gary23w/nl-veil
