# the veil — v1.0.1-beta-1

**The first beta.** Ten alphas went into making the thing installable; this one is about making it *self-contained*.
The veil can now bring its own model — no Ollama, no API key, no account — and the run it does with that model
holds together over hours instead of minutes.

There is no `v1.0.0` proper. The alpha line was tagged `v1.0.0-alpha.N` and pre-1.0 semver orders those *below*
`1.0.0`, so the version after `alpha.10` had to move forward, not sideways. `1.0.1-beta-1` is that step.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.0.1-beta-1-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.0.1-beta-1-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.0.1-beta-1-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.0.1-beta-1-linux-x86_64.zip`** |

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

## 🆕 New since alpha.10

38 commits. The headline is that **the veil now ships a brain**, and a long agentic session survives being long.

### It brings its own model

- **No model runtime to install.** The veil can download **[the-veil-12b](https://huggingface.co/gary23w/the-veil-12b)**
  (~6.9 GB, Apache-2.0) and run it *itself*, in the same process that serves the app. Ollama and a hosted key
  are now both optional — point at either whenever you prefer one.
- **It uses your graphics card.** The built-in engine runs on the GPU where one is available: measured at
  **1.6 → 66 tokens/sec** on an RTX 5070, roughly 40×. Machines with no usable GPU fall back to a much faster
  CPU path rather than to nothing.
- **A download panel that survives you closing the app.** Settings gains a **Built-in Model** section: Download
  with a live progress bar, *Import local copy* if you already have the GGUF, and one click to make it the chat
  model. The transfer runs server-side, so quitting the desktop app doesn't abort a 7 GB download.
- **Updates in place.** The app can ask whether a newer build of the built-in model has been published and swap
  it without a restart — from Settings, or `veil model check`.

### Long sessions hold together

- **No more 15–25 second freezes mid-run.** During a long agentic session the server would go unresponsive in
  bursts. Each idle connection was holding one of the 128 worker slots for a full minute; idle sockets now let
  go after five. Measured with 200 and 400 held connections: the stall disappeared entirely.
- **Your chat history is no longer destroyed as it scrolls.** The desktop app used to rewrite the conversation
  file to match what was on screen — permanently deleting everything older. Every committed message is now also
  appended to a separate archive that is never rewritten, and on-screen scrollback doubled to 128 messages.
- **A waiting tool can't hold a turn open forever.** The `poll` tool could wait indefinitely — people were
  typing "stop polling" to escape it. A turn now refuses the fourth timed-out poll outright, and when the
  server abandons a wait it tells the desk to clear the "still running" chip instead of leaving it up for the
  full timeout.
- **No rubber-banding while a reply streams.** Scrolling back during a streaming reply no longer snaps you to
  the bottom every few frames. The view follows the bottom only when you ask it to: by scrolling there, pressing
  jump-to-bottom, or sending a message.
- **A stuck turn ends itself instead of grinding on.** A model cycling through the same already-refused calls
  used to run all the way to the iteration limit and look like a crash. Also fixed: an edit thrown away because
  the model wrapped a line marker in stray asterisks, and a failed edit reporting that a file *you never named*
  did not exist.
- **A frozen window now leaves evidence.** A frame watchdog records a stalled UI straight to `data/desk-hang.log`,
  including whether the stall was inside the app's own work or inside the graphics driver's buffer swap. This
  makes the next freeze explainable; it does not prevent one.
- **Python errors show the part that explains the failure.** A long traceback was clipped to its first 1500
  bytes — the least useful end — so the model saw stack frames and never the error line. The tail survives now,
  on the same budget.

### Three ways the last release page was lying to you

None of these are in the app. All three were found by checking the *previous* release against its own download
table instead of trusting it, and all three had been true for several releases running.

- **macOS Intel bundles were never actually shipping.** GitHub retired the `macos-13` runners, and a job asking
  for a label that no longer exists doesn't fail loudly — it queues until the run is cancelled. Every tag from
  alpha.6 through alpha.10 built and attached three bundles while its download table promised four. The matrix
  now names the current Intel label.
- **The Linux desktop build failed to link, and the build reported success anyway.** The GUI now hands the final
  link to the system linker, and the build script no longer masks the failure.
- **The Download buttons pointed at the wrong page.** README and the docs site linked `/releases/latest`, which
  GitHub resolves by *skipping* pre-releases — and every release so far has been one, so the buttons resolved to
  an internal build-asset blob with one irrelevant file in it. They name an explicit tag now, and the acceptance
  gate fails if that tag drifts from the version.

### The model gets fewer chances to go wrong

- **Local models can use tools again.** Ollama sends tool calls with no identifier and with arguments shaped as
  an object, and the bridge rejected both. Every tool a local model tried to use burned a 20-second timeout and
  came back "no client picked up" — which the model then read as its tools being broken.
- **Three small-model failure modes closed.** A slightly mis-cased tool name (`WebSearch` for `web_search`) now
  simply runs instead of costing a whole round trip; a file write that the token limit cut off is *refused*
  rather than landing a half file that looks complete; and a "checking your browser" interstitial is reported as
  a blocked fetch instead of being handed to the model as the article.
- **Research stops spiralling on dead links.** Web search results are no longer prefixed with unrelated material
  from memory (fiction from an ingested novel was being served ahead of the real hits on every search), and
  after three fetches in a row come back "not found" the model stops inventing more URLs.
- **It stops denying facts you told it.** Recall searched only one of the two places durable facts are kept, so
  it could answer "nothing recalled yet" about a fact sitting in the very same prompt. It now searches both and
  ranks across them.
- **The model is told what day it is.** Every turn ends with today's date. Observed live: time-sensitive
  searches went from being dated to a year the model guessed to the actual one.

### Smaller things you'll notice

- **Replies come out in plain punctuation.** No em dashes, curly quotes, single-glyph ellipses, or invisible
  zero-width characters — the marks that make text read as machine-written. Code blocks keep exactly the
  punctuation the model typed.
- **Provider errors stop copying your account details into the log.** When a provider returned an error quoting
  your organisation id or key alias, that text was written verbatim into the permanent event log. Those tokens
  are masked now; the rest of the message stays readable.
- **Build dataset.** A switch in Settings (also `veil dataset start`, and a web panel) records every model call,
  tool run and reasoning trace into a folder a fine-tuning tool reads directly — with credentials, the durable
  memory block, and email addresses stripped before anything is written.
- **A faint grid behind the chat**, in whatever theme you have active, so an idle transcript on a wide window
  doesn't read as an empty void.
- **Two more Gemma-4 12B builds** (a coder and an agentic one) in the Ollama section of the model picker.
- **The website was rebuilt** on the same palette, type, and themes the app compiles in, with an explorable
  architecture map on the front page.
- **`veil doctor --growth` is now `veil doctor --runtime`.** The self-improvement harness that pointed the engine
  at its own source was removed from the project; the operator health report it fed is what remains.
- **The README describes the app that actually exists** — the built-in model, the ~58-tool belt, driving your own
  Chrome or Edge, small-model handling, and the full command list.

> Data format is unchanged — your `./data` carries forward from the alphas.

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
> - **The web UI lags the desktop app.** It is a full client now — chat with sub-chats, tasks, swarms, settings,
>   dashboard, and an installable PWA — but it is not at parity: the narrator, OpenDyslexic mode, MCP server
>   management, and the memory keep/drop approval queue are desktop-only.
> - **Desktop bundles are built per-OS.** The GUI links the platform graphics stack and can't be
>   cross-compiled, so each OS bundle is built natively in CI. The standalone server covers all five targets.
> - **The desktop needs OpenGL 3.3.** On a VM, an RDP session, or a box without a real graphics driver, use
>   the web UI (the app tells you this instead of exiting silently).
> - **The Download buttons on the README and the docs site point at `/releases/latest`, which skips
>   pre-releases.** Until a signed stable ships, come to *this* page for the files.
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
toward a goal until done — or in AFK mode, indefinitely. Advanced reasoning is the default (fast mode opts out),
a dissenting reviewer checks the answer, it looks before it plans, and it repairs failures instead of announcing
success. **Branch any conversation** into sub-chats that share one memory and workspace. Press **Stop** and it
stops — even mid-tool.

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
Recall is relevance-gated and trust-weighted, and every learned entry is quarantined for your **keep / drop**
approval before it binds — the memory can't quietly poison itself.

### 👁 Vision-as-text (Pixel RAG)
Drag an image onto the chat, or paste a screenshot with **Ctrl+V**. Its text is extracted with your OS's built-in
OCR — **Windows.Media.Ocr** on Windows, **Vision** on macOS, or a vision-model fallback where the OS has neither —
indexed as a searchable document, and handed to the model as grounded context. Web pages can be ingested the same
way: rendered to screenshot tiles and indexed by what's actually on screen, not by scraped HTML.

### 🌐 Real browser control — headless or your own
A headless (or visible) Chromium the AI drives: navigate, click, type, evaluate, capture. It sees a page's
links, buttons, **and text fields** (with their contents), and a click reports what it changed — so it fills
forms and confirms results instead of guessing. It can verify a web app it just built by *using* it — interact,
snapshot the live page (`pixel_capture`, no reload), and confirm what actually rendered. Or install the
**browser extension** and point it at your own Chrome/Edge to work inside your real, logged-in sessions — it
stays paired across restarts.

### ⏰ Scheduled tasks
Recurring or one-shot runs — "every morning at 9", "in 20 minutes", "daily digest". Each task keeps its own memory
across runs in its own permanent working directory, and can revise its own prompt and cadence as it learns what
works.

### 🖥 A real desktop app
Native (Zig + raylib), not a browser wrapper: dashboard with live metrics, multi-chat with concurrent turns,
sub-chat branches, swarm control, task editor, file viewer with syntax highlighting, and an in-app shell. Plus a
full **web UI** at `127.0.0.1:8787` and a **CLI** (`veil chat`, `veil cast`, `veil list`, `veil sched`,
`veil doctor`).

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
- Prompts **scale to the model**: an 8B local model gets compact doctrine and lean injections; a frontier model
  gets the full treatment. Provider quirks self-heal (a rejected parameter is detected, rewritten, retried, and
  remembered per model).

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
| `veil-v1.0.1-beta-1-windows-x86_64.zip` | **Full bundle** — server + desktop + memory engine |
| `veil-v1.0.1-beta-1-macos-arm64.zip` / `-macos-x86_64.zip` | **Full bundle** for macOS (Apple Silicon / Intel) |
| `veil-v1.0.1-beta-1-linux-x86_64.zip` | **Full bundle** for Linux |
| `veil-server-v1.0.1-beta-1-<os>-<arch>` | **Server only** — headless hosts, containers, remote boxes (no desktop) |
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
