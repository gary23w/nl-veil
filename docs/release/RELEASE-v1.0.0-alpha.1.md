# the veil — v1.0.0-alpha.1

> **This is an alpha.** A real, working build — but with known gaps, stated up front rather than buried:
>
> - **Default admin password.** The local admin is `admin@neuron-loops.local` / `changeme`. The server binds
>   loopback-only by default, so this is same-machine trust — but if you set `NL_BIND` to expose it,
>   **set `NL_ADMIN_PASSWORD` first.**
> - **The web UI lags the desktop app.** It's still the older swarm console — no chat, tasks, or settings
>   yet. Use the desktop app for those; the web port to full parity is in progress.
> - **Desktop bundles are built per-OS.** The GUI links the platform graphics stack and can't be
>   cross-compiled, so each OS bundle is built natively in CI. The standalone server covers all five targets.
> - Expect rough edges — please file what you hit.

**A local-first AI workspace that actually does the work.** One download, one click: a hive-mind engine,
a native desktop app, a web UI, a CLI, and a persistent associative memory — all in a single self-contained
bundle. No Docker, no Python, no Node, no cloud account required.

Bring your own model (local Ollama or any hosted endpoint) and the veil builds, researches, browses, remembers,
and schedules — on your machine, with your keys, against your files.

---

## Install

Download the bundle for your OS below, unpack it, and run it:

| OS | Run |
|---|---|
| **Windows** | double-click `start.cmd` (or `veil.exe`) |
| **macOS** | `./start` |
| **Linux** | `./start` |

That one action starts the **local server** (`http://127.0.0.1:8787`) **and opens the desktop app**. Nothing else
to install — the bundle carries the server, the desktop, and the memory engine.

Prefer headless? `veil --server-only` runs the server alone (services, containers, remote boxes) and the web UI
stays at `127.0.0.1:8787`.

---

## What it does

### 🧠 A hive mind, not a chatbot
Deploy a **swarm** and it decomposes the goal, spawns specialist minds, gives each ownership of real files, and
lets them build, critique, and reconcile in parallel against one shared workdir with its own micro-VCS. Minds
share findings through a common memory, so a discovery by one becomes context for all.

### 💬 Chat that builds
The chat is an agent with real tools: read/write/edit files, run shell commands (with an approval gate), run
tests, search and fetch the web, drive a real browser, and call MCP servers. **Auto-loop** lets it drive itself
toward a goal until done — or in AFK mode, indefinitely. It plans, checks its own work, and repairs failures
instead of announcing success.

### 🧩 Per-role model trio
Point **coding**, **thinking**, and **prompting** at *different* models — a strong coder for the build stream, a
cheap planner for housekeeping, something else to drive the auto-loop. Or keep one model for all three (the
default). Mix local and hosted freely; unset roles inherit the coding model.

### 🗂 Memory that persists
Backed by **neuron-db**, an associative memory engine. The veil accumulates a durable model of your work: facts
and preferences you tell it, an operational **playbook** learned only from *verified* failure→fix transitions,
reusable **skills**, and a user model. Recall is relevance-gated and trust-weighted, and every learned entry is
quarantined for your **keep / drop** approval before it binds — the memory can't quietly poison itself.

### 👁 Vision-as-text (Pixel RAG)
Drag an image onto the chat, or paste a screenshot with **Ctrl+V**. Its text is extracted with your OS's built-in
OCR — **Windows.Media.Ocr** on Windows, **Vision** on macOS — indexed as a searchable document, and handed to the
model as grounded context. Web pages can be ingested the same way: rendered to screenshot tiles and indexed by
what's actually on screen, not by scraped HTML.

### 🌐 Real browser control
A headless (or visible) Chromium the AI drives: navigate, click, type, evaluate, capture. It can verify a web app
it just built by *using* it — interact, snapshot the live page, and confirm what actually rendered.

### ⏰ Scheduled tasks
Recurring or one-shot runs — "every morning at 9", "in 20 minutes", "daily digest". Each task keeps its own memory
across runs, and can revise its own prompt and cadence as it learns what works.

### 🖥 A real desktop app
Native (Zig + raylib), not a browser wrapper: dashboard with live metrics, multi-chat with concurrent turns,
swarm control, task editor, file viewer with syntax highlighting, and an in-app shell. Plus a full **web UI** at
`127.0.0.1:8787` and a **CLI** (`veil chat`, `veil cast`, `veil list`, `veil sched`).

### ♿ Accessibility built in
OpenDyslexic mode, global text scaling, bold cut, and a **narrator** that reads replies aloud through your OS's
own text-to-speech — with `Win+H` dictation into the input.

---

## Bring your own model

One shared catalog (`models.yaml`) drives every menu in the app.

- **Local** — Ollama on your machine. Zero egress.
- **Hosted / BYOK** — OpenAI, Anthropic, DeepSeek, Moonshot (Kimi), Cloudflare Workers AI, Hugging Face,
  OpenRouter, and any OpenAI-compatible endpoint.
- Prompts **scale to the model**: an 8B local model gets compact doctrine and lean injections; a frontier model
  gets the full treatment. Provider quirks self-heal (a rejected parameter is detected, rewritten, retried, and
  remembered per model).

Keys live in your OS keychain — never in plaintext, never in the repo.

---

## Local-first by construction

- Your data stays in `./data`; your keys stay in the OS secret store.
- The server binds **loopback** by default.
- Nothing is sent anywhere except the model provider *you* configured.
- Run it fully offline with a local model — memory, files, browser, and scheduling all still work.

---

## Downloads

| Asset | Contains |
|---|---|
| `veil-v1.0.0-windows-x86_64.zip` | **Full bundle** — server + desktop + memory engine + launcher |
| `veil-v1.0.0-macos-*.tar.gz` | **Full bundle** for macOS |
| `veil-v1.0.0-linux-x86_64.tar.gz` | **Full bundle** for Linux |
| `veil-server-v1.0.0-<os>-<arch>` | **Server only** — headless hosts, containers, remote boxes (no desktop) |
| `SHA256SUMS.txt` | Checksums for every asset |

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
