# the veil v1.1.16

A long chat now carries itself forward by graph instead of by summary. **Gary's 4tope** reads each turn's working log as a dependency graph, keeps the chain of results the current step rests on, and writes the continuation from the turn's own bytes with no model call. The **tool tree** turns the tool belt into a map the model walks a branch at a time, so a small model can use a belt of hundreds of tools. Long chats with Agent Garrett on compact far less often.

## Why

On the first long chat with the full Agent Garrett catalogue (2026-10-10), the tools array was 405 KB, about 110k tokens, on every model call. The 400k-token spend ceiling tripped every three or four calls, and each trip replaced the work with a model-written summary of about 180 words. The task finished, but the user watched four of those short carries scroll past and read them, correctly, as the harness losing the thread.

## What changed

- **Gary's 4tope: continuation without a summary.** When a turn crosses its spend ceiling, the engine reads the turn's working log as a dependency graph. Each result hangs off the step that asked for it. A step depends strongly on the results it reused, and a later read or write of the same file supersedes the earlier one. The engine lays the graph out from where the work stands, and the continuation state is written straight from the log: NEXT is the step's own last words, ON DISK the files written, RULED OUT the calls that failed, ESTABLISHED the results the step rests on. Every line is the turn's own text. No model call, no paraphrase, and a failure that a later success replaced is not carried as current.
- **The critical chain is never pruned.** When the working context is trimmed, the results the current step transitively depends on stay whole, however old they are. Before, the rule was "keep the newest 32 KB".
- **Memory as the chat runs.** Tool findings are saved to neuron-db at every step that produced any, not only when they were about to be trimmed.
- **The tool tree (opt-in).** With `NL_TOOL_MAP=1`, the belt is a map the model walks with one verb, `open_tools`. It shows at most seven branches at a time, each with one line saying what it is for, and reaching a group opens its tools. The engine opens the most likely group from the request before the first model call. A tool the model already knows opens its own branch in the round it is called. A model that wanders for four rounds is handed a search of the whole map. Sources attach and detach live: Agent Garrett's catalogue, plugins and other MCP servers each compile into their own branch. A small model keeps nine core tools in hand and walks the rest. A larger model keeps today's belt and walks only the families that grow without bound: security tools, Cloudflare and plugins.
- **Long chats compact less.** Old tool results are stubbed before anything is summarized, which on a large window usually avoids the summary entirely. The working span, its verbatim tail and the continuation size all grow with the model's window, while small models keep their current numbers exactly. The default spend ceiling now always allows at least twelve uploads of the turn's own prompt, so a large tool belt widens it instead of tripping it.
- **A lighter Agent Garrett belt.** The 166 security tools are advertised with their types, enums, nested objects and required fields intact, but without validation constraints and long usage descriptions. The 54 alias arguments shared by 94 tools are listed once per tool instead of typed out in full. The belt drops from 366 KB to about 140 KB.
- **Tater-tots that opted out of Agent Garrett are no longer told it is missing.** Only a tater-tot that asked for the security tools hears that they are not ready.

## How Gary's 4tope works

A turn's working log is a directed acyclic graph: every dependency points at something older. From the frontier step `f`:

```
Keep   L(v) = max{ L(u) + w(v,u) : u ∈ deps(v) }        L = 0 with no dependencies
Carry  d(v) = min{ d(u) + c(u,v) : u ~ v },  d(f) = 0
```

`L` is the longest weighted path back from each node, one linear pass because the graph is acyclic; following it from `f` gives the critical chain that is never pruned. `w` is 2 when a step reused that result, 1 for the step that issued it or the step before, and 0 when it only saw it. `d` is Dijkstra's shortest-path tree from `f`, where `u ~ v` is an edge in either direction and `c` is 1 per read, 3 per glance, plus 4 for a stale result and 1 for a failed one. Results are taken in order of `d` until the carry's byte budget is full, then laid out along the tree so each derivation reads as one run and nothing appears twice. The name comes from Gary's framing: a conversation is a higher-dimensional object that a model can only read flat, the way a 4-polytope is seen through its net, and the question is which tree to cut along.

## Verification

`scripts/check.ps1 -Full` passed all nine gates: model-catalog sync, web assets, the tater-tot suite, the Python runner, the server build, the server test suite, the Linux test cross-compile, the desktop test suite and the full GUI build.

Both features ran end to end on a scratch server with a scripted model, nothing shared with a live install:

- **Gary's 4tope.** With the spend ceiling set to 8000 tokens, the turn wrote a file, read it back and tried a missing file, then crossed the ceiling. The engine wrote the continuation state with no model call. The turn continued and finished from it, and the next segment received exactly this:

  ```
  NEXT (the frontier, in its own last words): Reading the spec file missing-spec.md next.
  ON DISK: notes.md (22 B)
  RULED OUT (calls that failed; do not repeat them as they were):
  - r3 read_file {"path": "missing-spec.md"} -> not found
  ESTABLISHED (what the frontier rests on, nearest first, each derivation contiguous):
  - r2 read_file {"path": "notes.md"}: 1:xuv:gij→alpha ZEBRA-7781 line
  ```

  The first run of this check found a defect, fixed before release. The ON DISK line was clipped to the engine's framing sentence and never named the file.
- **The tool tree.** On a small-tier model, the request "tidy up the scratch file" opened the file tools before the first call. `open_tools` rendered the map and opened a group. A call to `read_doc`, which was not open, opened its own branch in the same round, and the next call advertised it. The open set and the learned table were saved at the end of the turn.

Not yet verified: a hosted model continuing a long real task from a 4tope carry, and the tool tree with Agent Garrett's live catalogue attached.

## Switches

| variable | effect |
|---|---|
| `NL_HANDOFF` | `net` (default) writes the continuation with Gary's 4tope; `model` restores the model-written state |
| `NL_TOOL_MAP` | `1` turns on the tool tree; unset or `0` keeps today's flat belt byte for byte |

[Gary's 4tope](https://gary23w.github.io/nl-veil/#doc=worker/chat/net) and [the tool tree](https://gary23w.github.io/nl-veil/#doc=worker/chat/belt) are documented in full in the source docs.

## Install or update

From v1.1.3 or later, finish active work and choose **Settings → Updates → App updates → Update & restart**. For a new installation, download the complete bundle from the [v1.1.16 release page](https://github.com/gary23w/nl-veil/releases/tag/v1.1.16), extract it, and run `veil.exe` on Windows or `./veil` on macOS/Linux. Preserve your existing data directory.

[Full changelog](https://github.com/gary23w/nl-veil/compare/v1.1.15...v1.1.16) · [Update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)

## Licenses and corresponding source

NL-Veil code uses its [MIT license](https://github.com/gary23w/nl-veil/blob/v1.1.16/LICENSE). Gary includes modified [ARTEX](https://github.com/Hinln/ARTEX) source under [AGPL-3.0](https://github.com/gary23w/nl-veil/blob/v1.1.16/cloud/GARY-LICENSE). The [Gary notice](https://github.com/gary23w/nl-veil/blob/v1.1.16/cloud/GARY-NOTICE), [source archive](https://github.com/gary23w/nl-veil/raw/refs/tags/v1.1.16/cloud/gary-source.tar.gz), and [Cloudflare build sources](https://github.com/gary23w/nl-veil/tree/v1.1.16/cloud) are public and included in every full release bundle. Dependencies retain their own licenses.
