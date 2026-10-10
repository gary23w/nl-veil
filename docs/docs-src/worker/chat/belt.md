# belt — the tool tree

**File:** `src/worker/chat/belt.zig`
**Module:** `worker/chat`
**Description:** The tool belt as a tree the model walks instead of a list it is handed, so any size of belt costs a small model only the branches it is standing in.

---

## The problem, measured

A tools array is re-uploaded on every inference, and the model has to choose from all of it at once. Three sizes of belt, three outcomes:

| belt | tools | bytes a call | what happened |
|---|---|---|---|
| compact (small tier) | ~20 | ~13 KB | fine |
| chat belt, full | 49 | ~35 KB | a 12B model reached for invented and irrelevant verbs (why the compact belt exists) |
| chat belt + Agent Garrett | 221 | ~405 KB (~110k tokens) | conv c6ac996e9, 2026-10-10: the 400k spend ceiling tripped every three or four inferences, four compactions in one task, and a frontier model paid for 200 tools it never touched |

Terser descriptions shrink the last row by a constant factor (the security catalogue's 366 KB becomes ~140 KB). Nothing flat survives the next catalogue. The belt has to stop being flat.

## The idea: tooling is a maze

Gary's maze write-up (hallios.github.io, maze challenge one) solves its maze with plain depth-first search over a visited grid. The solver sees the whole map; the walk itself is trivial; the whole difficulty was staying in lockstep with the server. The same split works here, and it is the entire design:

- **The engine is the solver.** It holds the whole map (every def and its path), the visited marks, the path stack and the set of groups currently open. It never forgets where the walk has been.
- **The model is the walker, with local vision.** At any moment it sees the branches at the node it stands in, at most seven, each one line saying what that branch is *for*. It does the one thing even a tiny model does reliably: pick the line that matches, go deeper, back out when it was wrong.
- **Reaching a group opens it.** A group's tools join the tools array with their full typed defs and are callable by name from then on. The walk is depth-first for the model: one branch at a time, the way a small model thinks.

What the model sees per inference is the core verbs for its tier, one navigation verb, and the four most recently used groups: ~12-16 KB on the measured belt instead of 405 KB. The 166 security tools cost nothing until one is wanted.

## The map

Every def gets a path. Built-ins by table (`pathFor`): `build/files`, `build/code`, `web/fetch`, `web/browser`, `knowledge/memory`, `knowledge/images`, `delegate/swarm`, `delegate/schedule`, `cloud`, `connect/mcp`, `connect/plugins`. Discovered belts by prefix and keyword: `security_*` lands under `security/<group>` (`securityPath` — intel, dns-ip, web, email-breach, people, malware, forensics, darkweb, decode, scan) and the agent's own task system under `security/agent/<group>` (shell, files, tasks, inspect, findings, assets, traffic, extend, web). Keyword rules rather than a name table, so a tool the catalogue gains next month lands somewhere sensible; a name nothing claims lands in `other`, which the view shows like any branch. Every branch carries a one-line use case (`branchDesc`) written in the user's words — "anything about a web page or site: fetch it, search the web, or drive the browser" — because that line is what the walker matches against.

On the measured 221-tool belt the root has exactly seven families, every group holds at most 24 tools, the security family fans out into twelve branches, and `security/other` is empty. Those bounds are tests, not hopes.

## The walk

`Walk` is a turn's state: `here` (the node the model stands in), `open` (at most `OPEN_MAX = 4` groups, with the round each was last used), `dead` and `seen` (the visited grid), `nav_streak`, and the turn's `cue`. One verb drives it, `open_tools`, with three optional arguments, because a small model asked to choose between `descend`, `search` and `back` has been handed another maze:

- **no arguments** — the root view: the families.
- **`path`** — walk into a branch. Absolute (`web/browser`), relative to where the model stands (`browser` from `web`), or a bare name read off a view. A family shows its branches; a group opens; a tool named as a path opens its group.
- **`find`** — breadth-first search over every tool for the words given, listing the best five with their paths and opening the best group when there is a clear winner.
- **`back`** — leave the branch. A group opened and left without a call from it is a dead end.

The view ranks branches for the turn's cue, shows at most `BRANCH_SHOW = 7`, says how many more there are, labels dead ends `[looked already: nothing fit]` and ranks them last, and always ends with the two ways out (`back`, `find`) and what is currently open. Opening a fifth group closes the least recently *used* one, and the result says which, so the model knows to reopen it if it needs it.

## The three accelerators

A walk costs rounds, and a round is an inference. Three things make the walk the default rather than a fallback:

1. **The engine reads the map first.** At turn start `start` restores the previous turn's open set (conversations stay on a topic), then scores every group against the request with the same cue tokens the facts ledger uses (`cctx.cueTokens`; `branchScore` is the best tool weighted plus a little for every tool that answers and for the branch's own line) and opens the best one if it clears a small threshold. "Check the DMARC and SPF posture of example.com" begins with `security/email-breach` open and pays zero navigation rounds. "Hello" opens nothing.
2. **A known name needs no walk.** `noteCall` is consulted on every tool call: a name that exists in the tree but is not open opens its group *and the call runs in the same round*. A capable model that knows `browser_click` from the doctrine never pays for the map. The tree only ever shrinks what is **advertised**, never what is **callable** — the contract the compact belt already relies on (`execute` dispatches the full schema regardless).
3. **A lost walker is handed the map.** After `NAV_MAX = 4` navigation rounds in a row without a tool call, the next `open_tools` runs `find` from the turn's own cue and opens the best match, unasked. Depth-first for the model, breadth-first for the engine (it has the map; breadth is free for it), best-first for the pre-walk.

## Why depth-first for the model and not breadth-first

Breadth-first is what a flat belt already is: every option at once, and it is the thing that fails at scale. A small model cannot hold 221 options, but it can hold seven and a reason. Depth-first with a visited grid gives it exactly that and guarantees progress: every pick narrows, a dead end is marked and ranked last, and the streak bound stops wandering. The engine does the breadth-first part on the model's behalf, where it costs nothing.

## Cost

| | flat, full catalogue | map, small tier | map, mid/large |
|---|---|---|---|
| tools array a call | ~405 KB | core (~5 KB) + `open_tools` (~0.6 KB) + one open group (6-10 KB) | chat core (~35 KB) + heads + open groups ≈ 45-55 KB |
| per-inference tokens | ~110k | ~4k | ~13k |
| navigation rounds a task | 0 | usually 0 (pre-walk); 1-3 when the request is new ground; bounded at 4 | 0 for any verb the model knows |

The tools array changes only when the open set changes — a navigation round or an eviction — and each change costs one uncached prefill of the prefix. Bounded by `NAV_MAX` plus evictions per turn, against a flat belt that was uncached-size on every call once it overflowed.

## Wiring (engine.zig), behind `NL_TOOL_MAP`

The module is the algorithm and its state; the engine owns the turn, and it walks only when `NL_TOOL_MAP` is set (`1`; unset or `0` is today's flat belt, byte for byte). The seams, in the order a turn meets them:

1. **Build** (`runTurn`, right after the plugin schemas merge). `splitBelt` divides the turn's full array by tier: a small model's core is `CORE_SMALL` (read, write, edit, list, run Python, search, fetch, recall, observe) and everything else is walked; a mid or large model keeps the whole built-in belt as its core and walks only the discovered families (`isDiscovered`: `security_`, `cf_`, `plug_`). The map half goes through `Tree.addDefs`; the learned table is read from `{data}/belt-learned.txt`; `Walk.start` restores `{conv}/belt.txt` and pre-opens for the request. The walk's first `tools` array *replaces* `turn_tools`, so the spend ceiling, the context plan and everything else sized from the array size the mapped belt.
2. **Teach.** For a mapped turn `DOCTRINE` rides in the system prompt and the compact tier's YOUR TOOLS manifest does not — its "that line is the complete list" would be false on a map.
3. **Per inference** (`runInnerAgentic`). The loop advertises `tools_cur`: rebuilt from `Walk.tools` whenever the walk is `dirty`, `turn_tools` otherwise. `tick` after every inference.
4. **Dispatch.** `open_tools` is answered by `Walk.navigate` before any executor runs (not counted as an executed tool). Any other name the map `knows` is accepted even when it is not advertised; `noteCall` then opens its group in the same round and the result ends with a line saying so. A name the map does not know falls through to `knownToolName` and the belt's own correction and refusal paths, unchanged.
5. **End.** On normal completion `finish` ties the turn's request to the tools it called, `save` writes the open set beside the conversation, and the learned table is written back. A turn that stops early saves nothing and loses nothing but one lesson.

Nothing above changes what a tool does when called, so the sandbox gate, client routing and the Garrett bearer rules are untouched. Not yet done: a live smoke on a small local model with the flag on, and the desk's tool chip for `open_tools` (today it renders like any tool call).

## The compiler: anything attaches, live

The map is not a table someone maintains. `Belt` holds **sources** — the built-ins, Agent Garrett, a plugin, any MCP server — and `compile` builds the tree from whatever is attached. Switching Agent Garrett on is `attach("garrett", defs, "", "")`; off is `detach("garrett")`; an MCP server that arrives mid-session is one more `attach`, and the next turn walks a map that has it. The compiled tree is replaced, never edited, so a turn walks the tree it started on to the end.

A def's path is decided in this order, per source (`Tree.addDefsFrom`):

1. **The source's own hints** — `name=path` lines. An MCP server that categorizes its tools says so and the map takes its word. This is the hook a catalogue should fill: a `category` annotation per tool, rendered by its client into hints, puts the catalogue author in charge of the shape of their branch.
2. **`pathFor`** for an unmounted source — the built-in table and the discovered families it knows (`security_*` by keyword, `cf_`, `plug_`, `browser_`, ...).
3. **The mount** for a server nobody wrote rules for: a source of up to fourteen tools is one group at its mount (`connect/jira`); a larger one is grouped by the first `_`-token where three or more tools share it (`issue_*` → `connect/acme/issue`, `wiki_*` → `connect/acme/wiki`) and strays land in `<mount>/misc`. A branch with no line of its own describes itself by a sample of its tools.

So any `tools/list` compiles into a walkable branch the moment it is rendered as defs, and the better its naming or its hints, the better its branch. Nothing about the walk changes: the model sees seven lines wherever it stands.

## The map learns from the walk

`Learned` is the self-improving part, and it is data, not a model call. Every time a `find` leads to a call, the words of the query are tied to the tool that was called; at the end of every turn (`Walk.finish`), the turn's own request is tied to every tool it called. Those edges (`token tool count`, per machine, bounded at two thousand with the weakest evicted) add to a tool's score — and so its branch's — as if its own line carried the words, capped at three per token so one habit cannot drown the map. A request no branch line anticipated ("is example.com spoofable") opens `security/email-breach` unasked the second time it is asked. The engine owns the table like it owns toolperf's per-machine learning: load at start, `save` at turn end.

That table is also the input to the next loop up, which is a model's job and is not built here: branch lines that keep losing finds to the same words are lines worth rewriting from those words, and tools that are called together across turns are tools worth grouping together. Both read straight off `Learned` and the dead-end marks; both would change the map's *shape* rather than its ranking, so both belong to a deliberate pass between sessions rather than inside a turn.

## Exports

- `Belt` (`init`, `attach`, `detach`, `has`, `compile`), `Source` — the dynamic belt and its compiler.
- `Tree` (`init`, `addDefs`, `addDefsFrom`, `addTool`, `find`, `locate`, `groupOf`, `node`), `Node`, `Kind`, `ROOT`, `NONE`.
- `pathFor`, `defName` — where a def lives and how its name is read.
- `Walk` (`init`, `start`, `tick`, `noteCall`, `isOpen`, `knows`, `tools`, `finish`, `save`, `navigate`), with `learned` pointing at the machine's table.
- `Learned` (`init`, `note`, `bonus`, `save`, `load`) — what the walk has learned, per machine.
- `NAV_TOOL`, `NAV_DEF`, `DOCTRINE` — the one navigation verb, its def, and the system-prompt block that teaches the map.
- `BRANCH_SHOW`, `OPEN_MAX`, `NAV_MAX`, `FIND_TOP` — the bounds.

Tests build the measured belt (the 55 chat verbs and Agent Garrett's 166 security tools by name) and pin: the root is at most seven families and nothing is lost; any tool is reached in at most three picks from at most seven lines; a known name opens its own group in the round it is called; the pre-walk opens the right group for a cue and the next turn restores it; `find` lists and opens; the open set is bounded and least-recently-used; dead ends are labelled and ranked last; a wandering walker is handed the map after `NAV_MAX` rounds; core tools are advertised once; a source attaches and detaches and the map recompiles; an unknown MCP server compiles into a mounted, grouped, hinted branch; a find that led to a call and a turn's calls teach the pre-walk, and the lesson survives a restart.

See [engine](#doc=worker/chat/engine) for the turn loop the walk rides in, [garrett](#doc=worker/garrett) for the discovered belt it was built against, and [Gary's 4tope](#doc=worker/chat/net) for its sibling: the same bounded, frontier-first view applied to the transcript instead of the belt.
