# the veil — v1.0.1-beta-4

**The fourth beta.** beta-3 was about the desktop app around the model. This one is about what the model
is *allowed to see*: every block of chat context now passes through a governed workspace with receipts,
budgets, and an audit trail — and the memory underneath learned to notice when it contradicts itself.

## ⬇ Which file do I download?

| You're on | Download |
|---|---|
| **Windows** | **`veil-v1.0.1-beta-4-windows-x86_64.zip`** |
| **macOS** (Apple Silicon) | **`veil-v1.0.1-beta-4-macos-arm64.zip`** |
| **macOS** (Intel) | **`veil-v1.0.1-beta-4-macos-x86_64.zip`** |
| **Linux** | **`veil-v1.0.1-beta-4-linux-x86_64.zip`** |

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

## 🆕 New since beta-3

### 🧾 The prompt workspace: context is governed, not accreted

Every non-transcript block a turn injects — your durable memory, recalled facts, the learned tool digest
and belt, image OCR, engine corrections, sub-chat family context, plugin hooks, the file ledger — now
**bids** into one workspace instead of being appended ad hoc. The workspace renders admitted blocks in a
fixed order, enforces per-channel byte budgets (an oversized stack drops whole blocks, lowest priority
first, instead of silently crowding out your conversation), and stamps every admitted block with a
**provenance receipt** the model can cite:

```
[provenance recall: chat:cli7f3a1c, 6 items, conf 0.82, 1480B]
```

Each turn appends its admit/drop record to `workspace.jsonl` in the conversation's folder — every block
that bid for the model's attention, its score, its size, and whether it made it in. *"Why did it say
that"* now has a queryable answer.

### 🔢 Recall with numbers, not vibes

The engine asks the bundled memory engine for **scored recall**: top-k facts, each carrying its own
retrieval numbers, rendered strongest-first and numbered. The top score rides the workspace receipt as
measured confidence and lands in the decision log. Confidence is now a number that crosses every seam
intact — never an adverb the next layer re-inflates. (Pointing the app at an older `neuron` binary keeps
working: the engine falls back to the previous recall path byte-for-byte.)

### ⚔️ Contested memory

Storing a fact that contradicts one already stored — a negation ("the deploy does **not** use docker"),
or a different value for the same head ("the api port is **9090**" vs "the api port is **8080**") — now
marks **both** sides at write time. Nothing is blocked and nothing is deleted; the store stays
write-cheap and adjudicates at recall, where the model sees:

```
2. the api port is 8080 [CONTESTED — a stored fact disagrees: "the api port is 9090"]
```

Both sides shown, instead of confidently repeating whichever fact happened to rank higher. The scan is
deliberately conservative (two shapes only), because a false contradiction mark would pollute recall the
same way a false fact does.

### 🕵️ A second model audits doubtful memory

When recalled memory looks weak or contested, the turn spends **one bounded completion on the thinking
role** to review the block *before* the answering model reads it. Doubts come back as caution notes
rendered directly under the recall block ("fact #2: contradicted by a newer fact"). It **annotates,
never deletes** — no machine verdict silently removes a memory — and it only runs when a cheap always-on
check flags the turn, so ordinary turns pay nothing. `NL_MEM_VERIFY=0` turns the tier off.

### 📚 Docs

The prompt workspace has a full annotated page on the [docs site](https://gary23w.github.io/nl-veil/#doc=worker/chat/workspace)
(CH-10), and the engine, memory-gateway, and README pages were refreshed to match. The memory engine's
own release notes cover the new `recallscored` CLI verb and the default-on contradiction scan on
[gary23w/neuron-db](https://github.com/gary23w/neuron-db).

---

*Full changelog: [`v1.0.1-beta-3...v1.0.1-beta-4`](https://github.com/gary23w/nl-veil/compare/v1.0.1-beta-3...v1.0.1-beta-4)*
