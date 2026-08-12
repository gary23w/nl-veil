# the veil — v1.0.1-beta-3

**The third beta.** beta-2 made the browser finish the job. This one is about the desktop app around it:
the "crashes" that were really hangs, a shell you can actually use, a chat that says when the network is
gone instead of freezing, one-click roles, and two new local models to run them on.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.0.1-beta-3-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.0.1-beta-3-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.0.1-beta-3-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.0.1-beta-3-linux-x86_64.zip`** |

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

## 🆕 New since beta-2

### 🪟 The "crash" was a hang — and it's fixed *(Windows)*

The desk "crashing" was never a crash. Windows' own log across six days showed **seven Application Hang
events and zero Application Error faults** — every one was Windows closing a *frozen* window, which looks
identical to a crash from the outside. The frame watchdog that shipped in beta-1 named the phase:
**684 of 684 stalls inside the GPU present call**, one of them frozen for **72 minutes** before it resumed.

The cause was a hole in beta-2's tray work: the idle path that skips drawing was gated on our own
tray-hidden flag, but **minimizing** doesn't set that — so a minimized window kept asking the compositor to
present a window it would not show, and the driver simply doesn't return. The fix skips the draw when the
window is minimized *and* sets the always-run flag (raylib's input pump blocks while minimized too, so
without it the stall just moves). Measured on the reporting machine: 45 seconds minimized went from a
locked-up window to responsive throughout.

### 🎭 One-click roles

The Chat composer gains a **"+ give the veil a role"** picker below the input. Click one and its full
doctrine is handed to the conversation as the first message, so the AI operates under it from turn one.
Five ship, each a complete operating brief rather than a one-liner:

- **Content Writer & Copywriter**, **SEO Strategist**, **Automation Engineer**, **Legal Analyst /
  Paralegal** (opens with a not-a-lawyer / not-legal-advice disclaimer and a never-fabricate-citations
  rule), and **Bug Bounty Hunter** (authorized, in-scope testing only — an authorization gate up front,
  stop-and-report rather than pivot, minimal-PoC ceiling).

The roles live in a `roles.json` embedded at build time; adding your own is one JSON edit and a rebuild.

### 🖥 A shell you can actually use, and a Veil pane that shows the work

The micro-console under the swarm activity was a peephole — a fixed 280px tall in a column capped at 560px,
so a directory listing wrapped and the prompt clipped. Now the console **height is drag-resizable** (a grip
on the seam, persisted) and the right pane widens to 1100px. And the **Veil tab actually shows what the AI
is doing**: every delegated tool call and its result (`read_file → 0s, 8291b`) now streams into the pane
that previously sat empty behind a placeholder while the work happened only in a log file.

### 📴 "Internet is offline" instead of a multi-minute freeze

When the uplink dropped, nothing was deadlocked — but an agentic turn makes many model and tool calls, and
each one independently spent ~20 seconds discovering the network was gone. Dozens of correct timeouts read
as a hung app with nothing on screen explaining why. Now a single cached probe answers the question once and
hosted turns fail fast with a plain **"Internet is offline"** message. **Local models are never affected** —
the built-in engine and Ollama are loopback and keep working with the uplink down; the probe is only ever
consulted for hosted providers.

### 🌐 The browser stops refusing what you asked for

The sibling of beta-2's browser fixes. `browser_click` carried "do not click irreversible controls
(pay, submit, delete, confirm) without approval" — but *post* and *submit* are exactly those controls, so
any instruction to post turned the requested action into the forbidden one, and the model, reasoning
correctly, wouldn't do it. The clause is **repolarized, not removed**: carrying out a control the user
asked for (post, send, submit, publish) is doing their instruction; the guard now fires only on an
irreversible action they did *not* ask for and wouldn't expect. `browser_eval`'s blanket ban on submitting
forms got the same treatment.

### 🧩 Two more local models

Two new 30B agentic models in the Ollama picker, both tool-callers built for always-on local agents:

- **NVIDIA Nemotron 3.5 Lightning** (`nemotron-3.5-lightning:30b`) — 30B total / 3B active MoE.
- **Meta Muse Glimmer** (`muse-glimmer:30b`) — 30B.

Pull either with `ollama pull <id>` and pick it from the model dropdown. Both are sensed as mid-tier, so
they get fuller prompt doctrine than a small local model.

> Data format is unchanged — your `./data` carries forward from beta-2, beta-1, and the alphas.

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
>   management, the memory keep/drop approval queue, and the role picker are desktop-only.
> - **Close-to-tray is Windows-only.** On Linux and macOS the close button still quits.
> - **Full occlusion / display-off can still stall a frame.** The minimize hang is fixed, but a fully
>   covered window or a slept display parks the same GPU present call; if `data/desk-hang.log` shows
>   `GL endDrawing (driver)` on a window that was never minimized, that's the remaining case.
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

### 💬 Chat that builds — with branches and roles
The chat is an agent with real tools: read/write/edit files, run shell commands (with an approval gate), run
tests, search and fetch the web, drive a real browser, and call MCP servers. **Auto-loop** lets it drive itself
toward a goal until done — or in AFK mode, until you stop it. Advanced reasoning is the default (fast mode opts
out), a dissenting reviewer checks the answer, it looks before it plans, and it repairs failures instead of
announcing success. Hand it a **prebuilt role** in one click, or **branch any conversation** into sub-chats that
share one memory and workspace. Press **Stop** and it stops — even mid-tool.

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
such, and the tools state that navigating invalidates every reference. It carries out the actions you ask for
(post, submit, publish) instead of refusing them, and asks first only for an irreversible action you didn't
request. Or install the **browser extension** and point it at your own Chrome/Edge to work inside your real,
logged-in sessions — it stays paired across restarts.

### ⏰ Scheduled tasks
Recurring or one-shot runs — "every morning at 9", "in 20 minutes", "daily digest". Each task keeps its own memory
across runs in its own permanent working directory, and can revise its own prompt and cadence as it learns what
works.

### 🖥 A real desktop app
Native (Zig + raylib), not a browser wrapper: dashboard with live metrics, multi-chat with concurrent turns,
sub-chat branches, swarm control, task editor, file viewer with syntax highlighting, and a **resizable in-app
shell** that shows what the veil runs. On Windows it lives in the tray, so closing the window leaves the server
running. Plus a full **web UI** at `127.0.0.1:8787` and a **CLI** (`veil chat`, `veil cast`, `veil list`,
`veil sched`, `veil doctor`).

### ♿ Accessibility built in
OpenDyslexic mode, global text scaling, bold cut, and a **narrator** that reads replies aloud through your OS's
own text-to-speech — with `Win+H` dictation into the input.

---

## Bring your own model

One shared catalog (`models.yaml`) drives every menu in the app.

- **Built-in** — the-veil-12b, served in-process. No key, no separate runtime, no egress.
- **Local** — Ollama on your machine (gpt-oss, Qwen, Llama, Hermes, the two Gemma-4 12B builds, and now
  **Nemotron 3.5 Lightning 30B** and **Muse Glimmer 30B**). Zero egress.
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
| `veil-v1.0.1-beta-3-windows-x86_64.zip` | **Full bundle** — server + desktop + memory engine |
| `veil-v1.0.1-beta-3-macos-arm64.zip` / `-macos-x86_64.zip` | **Full bundle** for macOS (Apple Silicon / Intel) |
| `veil-v1.0.1-beta-3-linux-x86_64.zip` | **Full bundle** for Linux |
| `veil-server-v1.0.1-beta-3-<os>-<arch>` | **Server only** — headless hosts, containers, remote boxes (no desktop) |
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
