# clef

**File:** `src/worker/chat/clef.zig`  
**Module:** `worker/chat`  
**Description:** Clef mode: yes/no decisions of a chat turn, answered as probabilities by Cloudflare's Clef decision model on the user's Cloudflare login. ON by default for every user logged in to Cloudflare; a turn (`clef` on the message body) or the server's admin can turn it off.

---

## Purpose Summary

A chat turn spends model calls on decisions that are a yes or a no. Clef is a Workers AI decision model: it takes a `state` and a set of questions and returns a probability per question, and writes no text. In clef mode the engine puts those decisions to Clef first, and keeps the chat model for the cases Clef is not sure about and for anything that needs words.

One request:

```
POST {api_root}/accounts/{account}/ai/run/@cf/cloudflare/clef-flash
{"model":"clef-flash","state":"...","questions":{"q0":{"type":"noul","instructions":"..."},"q1":{...}}}
```

This file asks `noul` (yes/no) questions only. Question i is keyed `q{i}`, and its answer comes back under the same key as the probability that the answer is yes.

## Key Exports

- `MODEL`, `MAX_QUESTIONS`, `Usage`, `Target`
- `ask(target, state, questions, probs)`: one call; the token usage, or null on any failure
- `buildBody(...)`: the request body
- `parse(gpa, raw, n, probs)`: `n` probabilities out of a reply, or null

## Notable Implementation Details

- **A failure is never a decision.** `ask` returns null when there is no account or token, when the call does not answer, when Cloudflare reports a failure, or when any one question lacks a probability in [0, 1]. The engine then decides the way it did without clef mode.
- **One transport.** The call goes through `cf_oauth.curl`, so the bearer rides curl's stdin. A body too big for that is written to the conversation's directory as `.clef-body-{16 hex}` for the call's life.
- **When it is on** (`engine.zig`, `runTurn`). The turn's own `clef` decides when it is sent: `veil chat --clef` sends true, and the desk's **clef mode** toggle (Settings, below the tool map) sends true or false with every message. A turn that says nothing gets the server's default: the admin's **Clef mode** box in the web app's server configuration, kept in `server-config.json`. Both start ON, and `NL_CLEF=0` seeds either one off until a choice is saved. Either way the user must be logged in to Cloudflare, so logging in is what turns it on. Otherwise the turn runs as before.
- **What the engine asks** (`engine.zig`). A probability at or above `CLEF_YES` (0.85) is a yes and one at or below `CLEF_NO` (0.15) is a no.
  - *Plan reconcile* (`planReconcile`): one question per remaining task, in one call. A task advances on a yes. Clef's answer replaces the prompting model's call.
  - *Course check* (`courseCheck`): "should the next step proceed?" A yes lets it proceed with no reviewer call. Anything else goes to the reviewer, which writes the replacement step.
  - *Answer review* (`critiqueAnswer`): "does the answer contain a material problem?" A no is silence with no review call. Anything else goes to the review, which writes the correction.
- **What it leaves on the event stream.** Each clef call writes an `llm` frame labelled `clef-planrec`, `clef-course` or `clef-reflect`, with Clef's model id, the call's time and its input tokens. The per-model usage lines (`metrics.zig`) do not count clef calls.

---

*Case file grounded in the module's `//!` header, public API, and its tests.*
