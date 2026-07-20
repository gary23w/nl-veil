# the model trio

**Covers:** `src/worker/chat/engine.zig` (`Role`, `ModelTrio`, the labelled call sites), `src/worker/chat/trio_routing_test.zig`, `src/worker/{llm,metrics}.zig`, `src/config/server_config.zig`, `src/worker/chat/service.zig`  
**Kind:** operator guidance — one decision, explained rather than asserted  
**Description:** A turn is not one kind of work, so it does not have to be one model. What the three roles are, exactly which internal call runs on which, how much each call actually costs, and how to reason about a split for your own workload.

---

## One turn, up to three models

Every LLM call the chat engine makes carries a short **label** — `chat`, `plan`, `loop`, `compact`, and six more. The label says what the call is for. Each label is routed to one of three **roles**:

- **coding** — the agentic step. It streams the reply you read and carries the tool calls.
- **thinking** — planning, and every piece of transcript housekeeping.
- **prompting** — the short, high-frequency calls that write the *next instruction* rather than answer anything.

You may point each role at a different model, endpoint and key. You may also point all three at one model, which is the default and is what happens if you never touch this page's settings.

## The routing table

This is the ground truth. It is enforced, not documented-and-hoped: `trio_routing_test.zig` reads `engine.zig` as text, traces the three provider arguments of every labelled call back through the helper chain to the `ModelTrio.pick(.role)` binding they came from, and fails `zig build test` if any label reaches the wrong role — or if a new labelled call appears that nobody classified.

| label | role | what the call does | when it fires |
|---|---|---|---|
| `chat` | **coding** | the agentic step: streams the reply, carries the tool calls | every turn |
| `plan` | **thinking** | decomposes the task into subtasks and writes the acceptance contract (`done_when`) | when the planner decides the task warrants one |
| `reflect` | **thinking** | critiques the committed answer and may append a correction | first answer of an unplanned turn, and only when that turn actually ran tools — so never on a plain question |
| `compact` | **thinking** | compresses the working transcript when it outgrows the window | only past a byte budget |
| `ctxsum` | **thinking** | rewrites the rolling conversation summary | only past a byte budget |
| `summary` | **thinking** | closing message when a turn exhausts its iterations | only on an exhausted turn |
| `lesson` | **thinking** | one-sentence lesson after a run | scheduled tasks only |
| `loop` | **prompting** | one line per drive step: the single next concrete step, or DONE | every auto-loop step |
| `searchq` | **prompting** | reformulates a `web_search` query before it is dispatched | per search that actually executes |
| `stuck` | **prompting** | writes the recovery instruction when the auto-loop is confirmed stuck | rarely |

The labels are mutually exclusive within a turn in the sense that most of them are conditional — an ordinary interactive turn fires `chat` and nothing else. A long unattended run fires `loop` dozens of times and `compact`/`ctxsum` whenever the window fills.

## The fallback rule

A role counts as **set** only when it names both a base URL and a model. Anything else is blank, and blank means *inherit coding*:

```zig
pub fn pick(self: ModelTrio, role: Role) Provider {
    return switch (role) {
        .coding => self.coding,
        .thinking => if (self.thinking.isSet()) self.thinking else self.coding,
        .prompting => if (self.prompting.isSet()) self.prompting else self.coding,
    };
}
```

Three consequences worth holding on to:

- **A single-model setup is not a special case.** It is the trio with two blank roles, and it behaves exactly as it did before the trio existed. Nothing to opt out of.
- **A half-filled role falls back silently.** A base URL with no model id is not a configured role; it is a blank one. That is deliberate — a call dispatched to an endpoint with no model would fail at the provider, and inheriting a model that works is the better failure.
- **The fallback is per role.** Setting thinking alone leaves prompting on the coding model, and vice versa.

On a shared server there is a step in between. A role you left blank is filled from the host's published trio first (`service.zig`, `roleDefault`), and only then falls back to coding. Precedence, most specific first: **your role → the host's role → whatever coding resolved to.** So on a server whose admin published a thinking model, "blank" means the host's thinking model, not yours.

- **A role counts as set only with both halves.** `Provider.isSet` requires a model id *and* a base URL. Filling one without the other falls back exactly as if you had filled neither — it does not half-apply and it does not error. If a role you configured seems to be ignored, check this first.

- **Scheduled runs skip the host hop.** `sched.zig` builds a task's trio from the stored task row and blank-fills only the coding role; it never consults the host's published defaults. A task whose thinking and prompting roles are blank runs them on coding no matter what the admin published, and tasks created before the trio existed carry no roles at all.

## How to choose

The usual advice — *put your best model on thinking* — is half right, and the half that is wrong is expensive. Here is the measurement that shows why. These are the average prompt sizes of real request bodies on disk, per call, by label:

| label | role | average prompt |
|---|---|---|
| `chat` | coding | 30,738 B |
| `compact` | thinking | 31,274 B |
| `summary` | thinking | 21,064 B |
| `lesson` | thinking | 21,111 B |
| `loop` | prompting | 17,647 B |
| `ctxsum` | thinking | 12,107 B |
| `reflect` | thinking | 5,687 B |
| `plan` | thinking | 1,011 B |

Read the thinking rows against each other. **`plan` is about a kilobyte and carries all of the judgment** — it is handed the task, not the transcript, and it decides what the work is and what *done* means. **`compact` and `ctxsum` together are tens of kilobytes per turn and carry almost none** — they are mechanical compression, feeding a model the transcript and asking for a shorter one.

So "thinking" is one setting covering two very different jobs: a small, rare, high-stakes call, and a large, repeated, low-stakes one. Whichever model you put there pays for both. That is the real trade, and it is why this page shows you the numbers instead of naming a model.

To reason about a choice this page did not anticipate, ask three questions about the role:

1. **How big is the prompt?** That sets the per-call bill, and it is mostly the *context window* requirement too. `compact` needs a window that fits the transcript it is compressing; `plan` does not.
2. **How often does it fire?** Prompting's individual calls are middling in size, but `loop` runs once per drive step, so an unattended run makes many of them. Prompting is cheap because of *what* it does, not because the prompts are small.
3. **How much does a bad output cost?** A weak `plan` sends the whole turn at the wrong target and you pay for the wrong work. A weak `compact` loses a detail from the middle of a transcript. A weak `loop` line produces one wasted step that the next one usually corrects.

Two shapes that follow from that and tend to hold:

- **Prompting wants a small, fast, cheap model.** It writes one line at a time from a short slice of context. There is no judgment in it to lose, and the volume is where its bill comes from.
- **Coding wants your strongest model, and it is also the fallback**, so it is the one setting that is never wasted. If you only ever configure one thing, configure this.

Thinking is the one to think about, because you are choosing for `plan` and `compact` with the same field.

## The cost picture

Two numbers, one measured and one modelled. Keep them apart.

**Measured:** across 140 recorded turns, **47.6% of all input tokens were prefix-cache hits** — and essentially all of that was on `chat`. That is the shape you would expect: the coding role re-sends a long, stable prefix (system prompt, tool schemas, the conversation so far) on every step of a turn, which is exactly what a provider's prompt cache is for. The other roles build a fresh prompt per call and hit the cache rarely or never.

The practical reading: **coding's raw prompt volume overstates its bill by roughly half**, and the other two roles' does not. Anything you do that destabilises the coding prefix — changing a tool set mid-conversation, varying the system prompt per message — throws that discount away.

**Modelled — this is an estimate, not a measurement:** after cache effects, billable input divides roughly **62% coding / 22% thinking / 16% prompting**. It is a structural model built from the request sizes above and the cache-hit rate, not a per-account meter. It is here to steer one decision — how much to spend on prompting — and it is precise enough for that and nothing else. The UI rounds it to 60/20/15 for the same reason.

`GET /api/v1/metrics/llm` reports the real thing for your own account, aggregated per model and per (role, model), which is what the Dashboard draws.

## Where to set it

| surface | where |
|---|---|
| web app | **Settings → Models**, switch *One model for everything*; off reveals a panel per role |
| desktop | **Settings**, checkbox *use one model for all three*; off reveals a coding / thinking / prompting panel, each with its own provider, model and key |
| shared server | **Admin → Default model**, the same switch and the same three panels; publishes a trio to every account that has not chosen its own, per role |
| `veil chat` | environment: `NL_LLM_BASE_URL` / `NL_LLM_MODEL` / `NL_LLM_KEY` for coding, plus `NL_LLM_THINK_*` and `NL_LLM_PROMPT_*` (`_BASE_URL`, `_MODEL`, `_KEY`) for the other two |

Each role resolves its key independently. A role sent with a blank key is filled server-side from your sealed vault entry for that endpoint's provider (or a Cloudflare OAuth grant, for a Workers AI endpoint), so a browser can run a hosted turn on three different providers without ever holding a key.

## What this does not do yet, honestly

- **Per-role cost attribution is new.** Usage used to be recorded as one row per turn stamped with whichever model armed the turn — the coding model — fed by a thread-local counter that every call bumped regardless of who served it. So the thinking and prompting models' tokens were billed to the coding model's row, and the file could not represent a trio at all. Rows written before the split land under an empty role and still aggregate, but they attribute everything to the turn's primary model. **Your historical dashboard numbers under-report thinking and prompting to exactly the extent you were using them.** Rows written from now on are measured per call, at the point where the label and the model that served it are both in hand.

- **Whether a trio beats one strong model on your workload is an open question here.** The routing is verified, the per-call sizes are measured, and the cost split is modelled — but this project has not run a controlled end-to-end comparison of a trio against a single strong model on the same tasks, and so cannot tell you that splitting will save you money or cost you quality. What it can tell you is where the tokens go, which is enough to make the experiment yourself and read the result off the metrics endpoint.

- **The local-model admission gate keys on the coding role only.** A local backend can serve one process at a time and is admitted against this machine's local budget; that check reads the coding endpoint. A trio whose *secondary* role points at a local model is not counted by it.

- **Hive and cast minds are not metered here.** They burn tokens on their own threads outside the turn loop, so they do not appear in the per-role breakdown.

---

Next: [running a server](server.md) · [architecture](architecture.md) · the turn loop itself, [chat/engine](../worker/chat/engine.md) · the LLM layer, [llm](../worker/llm.md)
