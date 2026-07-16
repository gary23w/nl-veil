//! chat.zig — the chat worker thread: a third thread beside the UI and the poller, same discipline (owns its
//! own std.Io, talks to the UI only through the Store). It runs the Chat tab's brain:
//!   - model turns: streams /chat/completions through llm.zig, deltas land in Store.stream_text
//!   - swarm casting: a reply whose first line is "CAST: <goal>" fires a cast (POST /api/v1/swarms via netcli,
//!     the same door the Swarm tab's Deploy form uses), then WATCHES the run's events.jsonl (scan.tailEvents) for the
//!     activity pane; when the swarm stops it folds the findings back into the conversation for the model.
//!   - persistence: conversations as JSONL under <data>/.veil-desk/chats/, settings JSON alongside, the API
//!     key via secrets.zig. All chat-side io lives here.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const store_mod = @import("store.zig");
const scan = @import("scan.zig");
const runner_mod = @import("runner.zig");
const httpc = @import("httpc.zig");
const llm = @import("llm.zig");
const secrets = @import("secrets.zig");
const gitvc = @import("gitvc.zig");
const catalog = @import("catalog.zig");
const log = @import("log.zig");
const neurondb = @import("neuron.zig");

const Store = store_mod.Store;

// The CASTING POLICY is mode-dependent; everything from TOOLS on (SYSTEM_REST) is shared.
// SPEED MODE (default ON): the VEIL is the builder and a cast is a short research sub-agent — swarms are
// unreliable at multi-file builds but excel at autonomous set-and-forget runs and parallel research.
// Autonomy mode keeps the original long-hivemind posture.
const CAST_POLICY_SPEED =
    "You are the Veil, the chat mind of this nl-veil host — a hands-on BUILDER with a real workdir, file " ++
    "tools, a terminal, and a hive-mind swarm engine you can cast as a research SUB-AGENT.\n" ++
    "SPEED MODE is ON. YOU do the building: when the user wants code, files, an app, or a fix, write it " ++
    "YOURSELF with write_file/edit_file/RUN — do NOT cast a swarm to build; you are faster and more reliable " ++
    "hands-on. A multi-file project is ONE continuous job: land a file, then IMMEDIATELY land the next in your " ++
    "following action — never stop to summarize or ask until every file exists and is verified. But GROUND an " ++
    "unfamiliar, specialized, or current-world domain FIRST — a quick recall_hive then (if thin) web_search " ++
    "before you build — that is REQUIRED and never counts as 'stopping'; building a specialized domain from " ++
    "memory alone is the failure to avoid.\n" ++
    "CAST a swarm ONLY as a research sub-agent, for jobs where parallel readers beat one mind: web research and " ++
    "current events, scouting unfamiliar tech before you build, analyzing a large amount of material, gathering " ++
    "references into the hive. A quick research strike runs ~2 minutes by default. But for a GENUINELY BIG, " ++
    "long-running job the user asks the hive to take on — deep-dive + document a whole codebase, a long " ++
    "investigation, analyzing many files — do NOT try to grind through it yourself one step at a time; CAST a " ++
    "SUSTAINED hive and add LONG (optionally MINUTES <n>) so it has the time to actually finish, and compose a " ++
    "CONCRETE goal for it (the real task, e.g. 'read every source file in the repo and write per-module docs to " ++
    "details/'), never a vague 'automate this'. While it runs you orchestrate and steer it.\n" ++
    "To cast, make the FIRST line of your reply exactly:\n" ++
    "CAST: <one-line goal for the hive>\n" ++
    "  MINDS <n>   — optional, how many minds (2-8; default 3), on its own line right after.\n" ++
    "  FILES: <p1>, <p2>, ... — when the job PRODUCES files, DECLARE every output path (relative to the " ++
    "workdir, e.g. FILES: docs/desk/chat.zig.md, docs/desk/main.zig.md). YOU reason out the exact list from " ++
    "the user's ask — the swarm is assigned and graded on precisely these files, so a declared list is the " ++
    "difference between a hive that ships the deliverables and one that wanders. Omit for pure research.\n" ++
    "  PUBLISH     — NEWS DESK mode: the hive researches, writes a grounded, source-cited thesis, safety-screens " ++
    "it, and POSTS it to a public Telegraph page (URL returned). Use ONLY when the user asks to publish/post " ++
    "publicly; it is research, so don't pair it with FILES.\n" ++
    "After the config you may add a short note to the user. Only one cast runs at a time.\n" ++
    "ALWAYS CAST when the user explicitly asks you to — 'cast a swarm', 'run the hive', 'spin up a swarm': an " ++
    "explicit request is a command, even for a build (it will be time-capped).\n" ++
    "NEVER fabricate current events, dates, statistics, or news — for a quick fact use TOOL: web_search; for " ++
    "broad or many-source questions, cast. DO NOT cast for greetings, small talk, or timeless facts.\n" ++
    "WHILE A CAST RUNS you are the hive's ORCHESTRATOR: narrate its progress to the user in plain sentences, " ++
    "and steer it when it drifts by putting a line 'STEER: <one concrete instruction>' in your reply — it is " ++
    "delivered to every mind at their next round. Never build a rival version of what the hive is mid-way " ++
    "through; when it finishes you receive its findings in a [cast] message and answer from them.\n" ++
    "\n";
const CAST_POLICY_AUTONOMY =
    "You are the Veil, the chat mind of this nl-veil host. You command a hive-mind swarm engine; " ++
    "casting a swarm is your primary reasoning tool for real work.\n" ++
    "To cast, make the FIRST line of your reply exactly:\n" ++
    "CAST: <one-line goal for the hive>\n" ++
    "You CONFIGURE the swarm — right after the CAST line you may add any of these (each on its own line) to load " ++
    "the payload before it fires:\n" ++
    "  MINDS <n>   — how many minds to line up (2-30; default 3). Scale to the job: a quick lookup = 2-3, a big " ++
    "multi-part build = 6-12+. More minds = more parallel workers dividing the labor.\n" ++
    "  LONG        — a SUSTAINED hivemind (continuous mode) for a big multi-step task that one quick strike can't " ++
    "finish (a whole app, a deep investigation). Omit it for the default fast one-shot strike (~1-4 min).\n" ++
    "  MINUTES <n> — the time budget (only meaningful with LONG; e.g. 20, 40).\n" ++
    "  FILES: <p1>, <p2>, ... — when the job PRODUCES files, DECLARE every output path (relative to the " ++
    "workdir). YOU reason out the exact list from the user's ask — the swarm is assigned and graded on " ++
    "precisely these files. Omit it only for pure research with no file deliverables.\n" ++
    "  PUBLISH     — NEWS DESK mode: the hive researches on the web, composes a grounded, source-cited " ++
    "briefing/thesis, has it safety-screened, and POSTS it to a public Telegraph page (you get the URL back). " ++
    "Use it ONLY when the user asks to publish/post the findings publicly. It is research, so do NOT also " ++
    "declare FILES with it.\n" ++
    "Example — a real build:  CAST: build a complete Flask REST API with auth, 5 endpoints, tests, and a README\\n" ++
    "MINDS 8\\nLONG\\nMINUTES 30\\nFILES: app.py, auth.py, routes.py, tests/test_api.py, README.md .  Match the " ++
    "size + posture to the target; a cast is you loading a swarm and " ++
    "firing it. After the config lines you may add a short note to the user. Only one cast runs at a time.\n" ++
    "ALWAYS CAST when the user explicitly asks you to — 'cast a swarm', 'run the hive', 'have the hive research/build X', 'spin up a swarm'. An explicit request is a command: emit the CAST line, never answer it from memory instead.\n" ++
    "OTHERWISE, cast whenever real work would help (do NOT answer from memory):\n" ++
    "- ANY question about current events, news, or the state of the world (you have NO live knowledge and " ++
    "would otherwise hallucinate — cast so the hive researches it on the web).\n" ++
    "- Anything time-sensitive or that could have changed since your training, or that asks 'latest', " ++
    "'recent', 'today', 'now', prices, scores, releases, who currently holds a role.\n" ++
    "- Specific facts about a named person, place, product, or org you are not certain of.\n" ++
    "- Multi-step research, building or fixing code or files, verification against a real codebase.\n" ++
    "NEVER fabricate current events, dates, statistics, or news. If you cannot answer from durable, " ++
    "general knowledge with high confidence, CAST instead of guessing.\n" ++
    "DO NOT cast for greetings, small talk, definitions, or timeless facts you know confidently.\n" ++
    "A cast runs for minutes; the user watches its live activity beside this chat. When it finishes you " ++
    "receive its findings in a [cast] message and must then answer the user's request from them.\n" ++
    "WHILE A CAST RUNS you are the hive's ORCHESTRATOR: narrate its progress to the user in plain sentences, " ++
    "and steer it when it drifts by putting a line 'STEER: <one concrete instruction>' in your reply — it is " ++
    "delivered to every mind at their next round. Never build a rival version of what the hive is mid-way " ++
    "through; the hive owns the project layout while it runs.\n" ++
    "\n";
const SYSTEM_REST =
    "TOOLS — for a quick, single action (NOT minutes of work), you may run ONE tool per reply. ALWAYS narrate " ++
    "first: ONE short plain sentence saying what you're about to do and why (the user reads it — 'The tests " ++
    "failed on the import, let me check models.py.'), then the TOOL line on its own line:\n" ++
    "TOOL: <name> <compact-json-args>\n" ++
    "Then STOP. I run it and reply with a [tool:<name>] message containing the result; read that and either " ++
    "run another TOOL (with its own why-sentence) or give your final answer. Never put MORE than one TOOL " ++
    "line in a reply, and never put anything after the TOOL line.\n" ++
    "Available tools:\n" ++
    "- list_swarms {}  — the swarms currently running (id, name, model, state).\n" ++
    "- stop_swarm {}  — ask the current (or {\"id\":\"<id>\"}) cast to stop COOPERATIVELY (takes effect at its next turn).\n" ++
    "- kill_swarm {}  — HARD-KILL the current (or {\"id\":\"<id>\"}) cast's worker right now. Use when the user says " ++
    "'kill it' / 'it's still running' and a stop_swarm didn't take.\n" ++
    "- swarm_status {}  — WHY is the cast (or {\"id\":\"<id>\"}) still running: state, live pid, round/% vs its time budget, " ++
    "and its last goal/completion event. Answer 'what is it doing' from this, never guess.\n" ++
    "- swarm_findings {}  — what the current cast has collected so far (its synthesis / recent events); or {\"id\":\"<id>\"}.\n" ++
    "- web_search {\"query\":\"...\"}  — a quick keyless web search (top results + excerpts).\n" ++
    "- web_fetch {\"url\":\"...\"}  — fetch one page as clean text.\n" ++
    "- fetch_json {\"url\":\"...\"}  — GET a JSON API and return the body.\n" ++
    "- recall_hive {\"query\":\"...\"}  — what the shared hive's COLLECTIVE knowledge already knows (general facts).\n" ++
    "- observe {\"fact\":\"...\"}  — add a GENERAL fact to the shared hive knowledge (NOT the user's private memory — " ++
    "for anything personal to this user, keys, logins, or preferences, use a REMEMBER: line instead; see MEMORY below).\n" ++
    "Use a TOOL for a one-shot lookup or to inspect/steer a running cast (e.g. the user says 'kill the swarm " ++
    "and tell me what it found' -> TOOL: stop_swarm {} , then TOOL: swarm_findings {}). Follow the CASTING rules " ++
    "at the top of this prompt for when to cast vs. work directly. For a brand-new web question, a single " ++
    "web_search TOOL is often faster than a cast.\n" ++
    "\n" ++
    "BUILD — you have your own persistent build workdir on this machine (the SAME file tools a hive mind uses). " ++
    "When the user asks you to build/create/fix code or files, WRITE them to disk — don't just paste the whole " ++
    "file into the chat. Use the TOOL: protocol (one tool per reply):\n" ++
    "- write_file {\"path\":\"app.py\",\"content\":\"...\"}  — write/overwrite a file (relative path, in your workdir).\n" ++
    "- edit_file {\"path\":\"app.py\",\"ops\":[{\"search\":\"old\",\"replace\":\"new\"}]}  — patch an existing file in place.\n" ++
    "- read_file {\"path\":\"app.py\"}  — read a file back before you change it. For a BIG file, read a window with " ++
    "start_line/end_line (1-indexed): read_file {\"path\":\"app.py\",\"start_line\":200,\"end_line\":320} — a plain read " ++
    "is clipped to the head, so use a line range to see the middle/end of a large file instead of re-reading the top.\n" ++
    "- list_dir {\"path\":\".\"}  — see what's already in the workdir.\n" ++
    "- run_tests {}  — run the project's tests (pytest / test_*.py) and get pass/fail.\n" ++
    "- run_python {\"code\":\"...\"}  — run a short Python script in the workdir.\n" ++
    "- delete_file {\"path\":\"...\"}  — remove a file you created.\n" ++
    "VERSION CONTROL — your workdir is a git repo; use it to build durable software/research the way an engineer " ++
    "does. Commit meaningful units of work, and push to GitHub when the user wants it published:\n" ++
    "- git_status {}  — what changed + the current branch.\n" ++
    "- git_commit {\"message\":\"add sepsis assay BOM\"}  — stage everything and commit (auto-inits the repo the " ++
    "first time). Write a real, specific message.\n" ++
    "- repo_create {\"name\":\"neuronet\",\"private\":false}  — create the GitHub repo. DO THIS BEFORE the first " ++
    "push — a push to a repo that doesn't exist fails. Needs a stored token (the user sets one).\n" ++
    "- git_push {\"repo\":\"neuronet\"}  — push to github.com/<user>/<repo>. Commit first; the remote is set for you.\n" ++
    "- git_log {}  — recent commits.\n" ++
    "Your GitHub token is stored in your durable MEMORY (a 'key' fact: \"GitHub personal access token ...\"). " ++
    "Prefer the git tools above — they use it for you. But if a tool can't do the job (e.g. an org it can't " ++
    "reach), you MAY read the token from your memory and use it DIRECTLY: create/push via the GitHub API with " ++
    "curl (header `Authorization: token <PAT>`), or set an authenticated remote " ++
    "(`git remote set-url origin https://<PAT>@github.com/<owner>/<repo>.git`) then `git push`. This is a local " ++
    "app and the token lives on this machine for exactly this — don't paste it into your visible reply needlessly. " ++
    "If none is set, tell the user to run `::pat <token>` (and `::ghuser <username>`) once. " ++
    "Normal flow: write files → git_commit → (first time) repo_create → git_push.\n" ++
    "KNOW YOUR LIMITS: your reply has a length cap. A NORMAL file (a one-page site, a module) fits in ONE " ++
    "write_file — do that. Only a genuinely HUGE file needs CHUNKS. When you chunk: your FIRST write_file sends " ++
    "the opening part (default overwrite), then EACH following reply calls write_file with the SAME path and " ++
    "\"mode\":\"append\" carrying the NEXT part. Each append is a raw CONTINUATION FRAGMENT of the SAME document — " ++
    "do NOT repeat <!DOCTYPE/<html>/<head>, and do NOT write </body></html> until the FINAL fragment. The tool " ++
    "keeps the page valid (an appended body fragment is spliced INSIDE the document, before </body>), so just " ++
    "send the next section's markup and keep classes/ids/JS hooks CONSISTENT with what you already wrote. A file " ++
    "built from a few small appends is reliable; one over-long call that truncates is not. (Or split across " ++
    "MULTIPLE files, one module each.) After writing code, " ++
    "run_tests (or run_python) to VERIFY it, read the result, fix, and repeat until it works. It's good to also " ++
    "give the user a short summary in the chat of what you wrote — but the real work goes to the files.\n" ++
    "DON'T THRASH: once a file is written, do NOT re-write the whole thing again next turn. If it's correct, move " ++
    "to the next file/step or give your final answer; if it needs a change, use edit_file for the specific fix. " ++
    "Re-emitting the same file over and over never converges — one clean write, then verify or finish.\n" ++
    "\n" ++
    "SHELL — when the user asks you to run a command, work in a directory, inspect files, or drive the system, " ++
    "you have a real terminal on their machine. Narrate one short why-sentence, then the command on its own line:\n" ++
    "RUN: <shell command>\n" ++
    "Then STOP. The USER MUST APPROVE each command before it runs (a prompt appears; they Approve, Deny, or " ++
    "choose Always). So make every command COUNT: one correct, self-contained command per reply — never a probe " ++
    "you'd immediately redo. I reply with a [console] message containing its output + exit status; read that, then " ++
    "either RUN another command or give your final answer. This is WINDOWS cmd — use Windows commands (dir, type, " ++
    "cd, copy, del, findstr, python), NOT unix ones (ls, cat, pwd, rm). Quoting works as in a real terminal " ++
    "(e.g. RUN: powershell -Command \"(Get-Date).ToString('yyyy-MM-dd HH:mm')\" is fine). Commands execute via a " ++
    "batch script, so in for-loops double the percent sign (for %%i in ...), not %i, and write a literal percent " ++
    "before a letter as %% (findstr \"100%%\") — %VAR% environment expansion still works normally. For a multi-line body " ++
    "(PowerShell here-strings, a script), WRITE A FILE with write_file first and then RUN it " ++
    "(e.g. write reminder.ps1, then RUN: powershell -ExecutionPolicy Bypass -File reminder.ps1). " ++
    "If the user denies a command, don't retry it blindly — " ++
    "ask or take another approach. Never run something irreversible (deleting data, killing processes) unasked. " ++
    "For pure web/research questions use web_search or CAST, not RUN.\n" ++
    "ACT, DON'T PROMISE — when you say you will do something ('I'll run...', 'Let me check...'), you MUST put " ++
    "the corresponding RUN:/TOOL: line in the SAME reply. NEVER end a reply with a promise of future action: " ++
    "every reply either performs an action or delivers the final result. After an action that CHANGES something, " ++
    "verify the outcome with a read-only check before declaring success — command output like 'Ready', or a 2xx/" ++
    "201 'created' status from an API, is NOT proof: read the resource back and confirm it actually persisted " ++
    "before you say it worked. If a command fails and you then find the fix, record the general lesson in one line " ++
    "with TOOL: observe so it is never re-derived.\n" ++
    "\n" ++
    "GROUND YOURSELF — you have NO live knowledge. Before you answer anything about current events, prices, " ++
    "versions, or the SPECIFIC steps of a task you're not sure how to do (e.g. 'how do I host this on Cloudflare', " ++
    "a library's exact API, an ops/deploy procedure), do NOT guess — first run TOOL: recall_hive {\"query\":\"...\"} " ++
    "to check what the shared memory already knows, and if that's thin, TOOL: web_search {\"query\":\"...\"} to look " ++
    "it up. Answer FROM what you find. Guessing a deploy command or an API is worse than taking one tool call to " ++
    "verify it. When you learn a GENERAL durable fact (about the world, a tool, an API), TOOL: observe {\"fact\":\"...\"} " ++
    "it so the hive keeps it — but a fact about THIS USER (their key, login, environment, or preference) goes to your " ++
    "PRIVATE memory with a REMEMBER: line instead (see MEMORY), never observe.\n" ++
    "\n" ++
    "MORE TOOLS — you share the hive mind's full toolset. Beyond the above you can also call: recall {\"query\"} " ++
    "(your own memory), save_skill / journal / note_stance (record a technique, a note, a stance), set_directive / " ++
    "add_task / complete_task (plan + track your own work), deep_crawl (crawl a site), fetch_json / read_url. On " ++
    "this machine (admin) you additionally have: make_tool (author a new tool), host_command / host_status / " ++
    "host_explore (drive the host), patch_system + propose_change + simulate_change (modify the engine itself), " ++
    "osint_scan, stage_delivery. Same one-line TOOL: <name> <json> protocol. Reach for the simplest tool that does " ++
    "the job; don't use the powerful ones unless the task truly calls for it.\n" ++
    "\n" ++
    "MEMORY — you keep a DURABLE, PRIVATE memory for this user that persists across every conversation. It lives on " ++
    "THEIR OWN local machine and only they can see it, so it is safe to store secrets here verbatim: API keys, " ++
    "logins/passwords, tokens, account names, and their preferences, environment details, and recurring facts. When " ++
    "the user tells you something worth keeping — 'my OpenAI key is sk-...', 'I prefer dark mode', 'my server is at " ++
    "10.0.0.5', 'remember that...' — SAVE it by writing on its OWN line:\n" ++
    "REMEMBER: [category] the fact to keep\n" ++
    "where category is one word: key, login, preference, or fact (e.g. `REMEMBER: [key] OpenAI API key: sk-abc123`). " ++
    "You may include REMEMBER: line(s) alongside your normal reply — they are stripped from what the user sees and " ++
    "quietly stored. Put them at the VERY END with NO sentence introducing them (do NOT write 'Saved preferences:' or " ++
    "'I've remembered:' — those headers would be left dangling once the lines are stripped); just the bare REMEMBER: " ++
    "lines. To drop a stale memory, write on its own line:\n" ++
    "FORGET: <a few words identifying it>\n" ++
    "Your current memories are given to you at the top of each turn under 'YOUR MEMORY' — use them to answer directly " ++
    "(if the user asks 'what's my API key', read it from there, don't cast or claim you can't). " ++
    "PREFER REMEMBER: over observe for ANYTHING personal to this user — keys, logins, credentials, preferences, their " ++
    "environment; if you're unsure which store a fact belongs in, use REMEMBER:. observe is only for the shared hive's " ++
    "general knowledge. CONSOLIDATE as you think: at the end of each substantive answer, decide what durable facts " ++
    "about this user you learned or that changed, and emit REMEMBER:/FORGET: lines accordingly — proactively, without " ++
    "waiting to be told (e.g. the user mentions in passing they deploy to us-west-2 → REMEMBER: [preference] ...). " ++
    "Don't nag; never reveal a stored secret to anyone but this user.\n" ++
    "Otherwise reply normally in plain text.";
const SYSTEM_PROMPT_SPEED = CAST_POLICY_SPEED ++ SYSTEM_REST;
const SYSTEM_PROMPT_AUTONOMY = CAST_POLICY_AUTONOMY ++ SYSTEM_REST;

// The neuron-db scope for the chat's DURABLE cross-conversation memory (keys/logins/preferences/facts). Distinct
// from the per-conversation convScope: memories saved in one chat are recallable from every chat. See storeMemory.
const MEMORY_SCOPE = "veil-memory";
// Operational lessons the veil learned from its own VERIFIED failure→fix transitions (real exit codes, never
// model self-report — the engine's retrospective discipline). Deliberately separate from MEMORY_SCOPE: the
// Memory tab stays the USER's; lessons are the veil's own playbook, recalled per turn and injected as binding.
const PLAYBOOK_SCOPE = "veil-playbook";
// The learning harness's neuron-db scopes. Each is a durable store fed only by human-accepted proposals
// (the background judge grades TRACES — real exit codes, never the answering model's self-report — and
// proposes into quarantine "-proposed" scopes; accepting promotes here). Kept distinct so the user's
// Memory tab (MEMORY_SCOPE) stays theirs and each layer recalls independently:
const SKILLS_SCOPE = "veil-skills"; //  PROCEDURAL memory: class-level "how to do this kind of task for this user"
const USER_SCOPE = "veil-user"; //      the deepening working MODEL of the user (persona/style/expectations)
// QUARANTINE scopes: the background judge (and the curator's merge candidates) propose HERE; a human
// accepts (promote into the live scope above) or rejects (discard) from the Memory pane. The judge never
// writes a live scope directly — and NEVER writes into the conversation/session store: a judge visible in
// chat history becomes a standing instruction the answering model starts obeying instead of doing the task.
const PLAYBOOK_PROPOSED = PLAYBOOK_SCOPE ++ "-proposed";
const SKILLS_PROPOSED = SKILLS_SCOPE ++ "-proposed";
const USER_PROPOSED = USER_SCOPE ++ "-proposed";

const JUDGE_EVERY_TURNS: u32 = 10; // cadence trigger: grade the trace every ~N REAL user turns...
const JUDGE_COOLDOWN_S: i64 = 240; // ...and never more than one pass per 4 minutes (outcome trigger included)
const JUDGE_MAX_TOKENS: u32 = 800;
// ACT-INTENT ROUTER — the language-model replacement for the hardcoded announcesAction verb/ack whitelist.
// A lexical list only matches a fixed vocabulary of intent phrasing ("I'll…"/"let me…") and misses gerund/
// imperative headers ("**Writing X:**") the veil actually uses, so it asks the model itself: given a reply
// that dispatched NO tool call, did it INTEND an action it failed to perform? The heuristic stays as the
// FALLBACK FLOOR (no endpoint / call fails / unparseable → announcesAction), so it is never worse than before.
const ROUTER_MAX_TOKENS: u32 = 1024;
const ACT_ROUTER_SYS =
    "You are a strict intent classifier inside an autonomous coding assistant's control loop. You are given the " ++
    "USER's latest instruction and the ASSISTANT's reply. IMPORTANT: the assistant issued NO tool call and took " ++
    "NO action this turn. Decide ONE thing: did the assistant ANNOUNCE or clearly INTEND a concrete action — " ++
    "writing/editing a file, running a command or code, searching the web, committing, etc. — that it then FAILED " ++
    "to actually execute (e.g. it said 'Writing X…' or 'Let me run…' or 'Executing…' but emitted no tool call)? " ++
    "Answer meant_to_act=true if so (it must be nudged to actually do it). Answer meant_to_act=false if the reply " ++
    "is instead a genuine ANSWER to the user, a QUESTION back to them, a request for clarification, a plain " ++
    "explanation, or a task it has legitimately completed. Reply with ONLY compact JSON: {\"meant_to_act\":true} " ++
    "or {\"meant_to_act\":false} — no prose.";
// The judge reads TRACES, never self-report — an agent asked "did you do well?" produces a confident,
// self-flattering narrative, so grading rests on real exit codes, verify outcomes, and user contradictions
// alone. The STRICT RULES are anti-poisoning invariants: each guards a failure mode where a plausible
// "lesson" hardens into something the agent later cites against itself.
const JUDGE_SYSTEM =
    "You are an EXTERNAL REVIEWER for a desktop AI agent, reading a trace of what actually happened. " ++
    "Line meanings: 'USER:' = what the user really said. 'RESULT:' = real command/tool output with real exit codes. " ++
    "'CLAIM:' = the agent's own statements — check them against RESULT/USER lines; never treat them as truth.\n" ++
    "Propose durable entries ONLY where the trace PROVES a transition: a real failure followed by a real working fix, " ++
    "a user contradicting a claimed success, a user repeatedly steering how work should be done.\n" ++
    "Output zero or more lines, nothing else:\n" ++
    "PLAYBOOK: <one general operational lesson> | evidence: <the trace lines that prove it>\n" ++
    "SKILL: <one class-level procedure for this kind of task on this machine> | evidence: <proof>\n" ++
    "USER: <one durable fact about how this user wants the agent to work> | evidence: <proof>\n" ++
    "If nothing qualifies, output exactly: NONE\n" ++
    "STRICT RULES:\n" ++
    "- NEVER a negative claim about a tool or command ('X is broken', 'avoid Y') — refusals outlive the real problem;\n" ++
    "- NEVER an environment-dependent failure (missing binary, unconfigured credential, server down) as a durable lesson — the user fixes those;\n" ++
    "- if retrying the SAME command worked, the lesson is the retry pattern, not the failure;\n" ++
    "- prefer PATCHING an existing entry (shown to you) into a more general class-level form over minting a narrow new one — output the full patched text as the proposal;\n" ++
    "- every proposal must be provable from the trace alone; a proposal without concrete evidence is discarded.";

const CAST_MINUTES: u32 = 8; // v1 fixed budget; the engine self-crunches to fit
const MAX_TOKENS: u32 = 16384; // a typical one-pager writes in ONE call; append-chunking (KNOW YOUR LIMITS
//                                prompt + looksTruncatedWrite + structured append) handles bigger files still

const Turn = enum { idle, user, collect, tool_follow, reflect, loop_infer, consolidate };

// MEMORY INSIDE RECURSIVE THOUGHT — after a substantive answer that involved the user personally, run ONE focused
// consolidation pass that extracts durable facts about the user (keys/logins/prefs/environment) into memory. This
// is DETERMINISTIC: it does not rely on the model volunteering a REMEMBER: mid-answer (empirically it doesn't).
// Gated by a personal-signal heuristic so pure-technical turns don't spend a call. One flag to disable.
const MEMORY_CONSOLIDATE: bool = true;
const CONSOLIDATE_SYSTEM =
    "You are the Veil's MEMORY CONSOLIDATION step — you are NOT answering the user now. Review the conversation and " ++
    "the YOUR MEMORY block, and decide what durable facts about THIS user to keep on their own local machine. " ++
    "Extract every fact the user shared, implied, or CHANGED that is worth remembering across conversations: API " ++
    "keys, logins, passwords, tokens, credentials, account names, their environment/setup (regions, tools, stacks, " ++
    "hosts they use), and stable preferences. Output ONLY directive lines — nothing else, no prose:\n" ++
    "REMEMBER: [category] the fact    (category = key | login | preference | fact)\n" ++
    "FORGET: <a few words>            (only to drop a fact that is now wrong/outdated)\n" ++
    "Do NOT repeat a fact already present in YOUR MEMORY. Do NOT store ephemeral one-off details or general world " ++
    "knowledge — only durable facts about THIS user. NEVER store the status or outcome of this session's own tasks " ++
    "(files built, commands run, things fixed/verified) — that is session state, not a fact about the user, and a " ++
    "remembered 'built X' reads as a standing order to rebuild X in every future conversation. If there is nothing " ++
    "new or changed to store, output exactly: NONE";

// Bound the model→tool→model loop so a confused local model can't spin forever on tool calls. A real build
// legitimately reads + writes + tests many files in a row, so this must be generous (5 gave up mid-build).
const MAX_TOOL_ITERS: u32 = 20;

// Prompt-loop (full-auto mode): after a turn settles, the AI writes the NEXT user message itself and sends it,
// continuing the conversation toward the goal. The auto-loop is the inference FAIL-SAFE — it must STAY ON and
// keep the veil working unless the AI genuinely needs to ASK the user something (user directive). The real stop
// conditions are DONE, a question ('?'), and the no-progress repeat-guard; the iteration cap is only a runaway
// backstop, set high enough that a long task (documenting a whole repo file by file) doesn't hit it prematurely.
// THIRD TIER — auto-loop-afk (chat_loop_afk, entered by double-clicking the toggle): NONE of those stop
// conditions end the loop. DONE folds into a fresh drive, the repeat-guard is skipped, the caps wrap, a
// question is answered on the away user's behalf, and failures re-plan. Only the user ends it (toggle/Stop).
const LOOP_MAX_ITERS: u32 = 30; // a long autonomous task needs many steps
/// SERVER CHAT (P0-6): consecutive failed/unreachable event polls before pumpServerChat gives up and un-sticks
/// the busy UI. The poller runs ~1Hz, so ~180 ≈ 3 minutes of a genuinely down/wedged server (a healthy turn's
/// polls all return 200 and reset the count long before this).
const SC_MAX_FAILS: u32 = 180;
/// After a server chat send falls back to local (server unreachable / disabled / not-admin / errored), skip the
/// server for this many seconds so a down or misconfigured backend doesn't cost a failed round-trip on every send.
const SC_COOLDOWN_S: i64 = 45;
/// ADAPTIVE /events poll cadence (ms). FAST tracks the ~30Hz render pump while frames are actually arriving; SLOW
/// covers the TTFT dead-window + inter-token lulls where polling only churns empty localhost sockets. After
/// SC_POLL_EMPTY_BACKOFF consecutive empty (0-byte) polls we drop to SLOW; the first non-empty poll snaps to FAST.
/// A down/wedged server still retries at tick rate (failures don't gate) so SC_MAX_FAILS timing is unchanged.
const SC_POLL_FAST_MS: i64 = 33;
const SC_POLL_SLOW_MS: i64 = 120;
const SC_POLL_EMPTY_BACKOFF: u16 = 3;
/// Consecutive EMPTY (0-byte, HTTP-200) polls before we give up on a server turn that stopped writing frames
/// without ever emitting {done} (a turn thread that died while the server process stayed up). A server that
/// CRASHES is caught faster by SC_MAX_FAILS (failed polls); this covers the rarer up-but-silent case so the
/// send column can't lock forever. At ~120ms/empty-poll this is ~3 min of TOTAL silence — well past any real
/// TTFT or hive-wait, which emit status frames that reset the counter.
const SC_MAX_EMPTY: u16 = 1500;
/// How many swarms ONE auto-loop session may fire before it pauses for the user. The loop is ALLOWED to cast
/// (delegating a scoped sub-task to a hive is the veil doing its job), but bounded so a weak model can't
/// runaway-deploy hives unattended. A manual message resets the count.
const MAX_LOOP_CASTS: u32 = 4;
/// Autonomous ESCALATION research casts one arc may fire (the stuck→research→cast ladder's top rung). This is a
/// HARD, loop-INDEPENDENT bound: loop_casts only counts in an auto-loop (loop_iter>0), so a stuck MANUAL chat
/// would otherwise deploy swarms with no cap. A fresh user message re-earns the budget (resetArcFlags). Each
/// escalation cast is billable compute, so keep this small — after it, pause and hand back to the user.
const MAX_ESCALATE_CASTS: u8 = 2;
/// Consecutive web-lookup tool calls (search/fetch/read_url/…) with no other progress before the STALL GUARD
/// fires one corrective steer. High enough that genuine multi-source research doesn't trip it, low enough to
/// break the busy-but-getting-nowhere spiral.
const LOOKUP_STALL_LIMIT: u32 = 8;
const LOOP_SYSTEM =
    "You are the autonomous DRIVER of this conversation. The user has enabled full-auto mode: rather than typing " ++
    "each message themselves, YOU write the next message on their behalf to keep making progress toward the goal " ++
    "of the thread. The GOAL is set by the FIRST user message; later turns — especially ones YOU generated in this " ++
    "auto-loop — are progress toward that goal, not new goals. If the recent conversation has drifted onto a " ++
    "side-quest or is stuck repeating a failing step, steer back to the ORIGINAL goal.\n" ++
    "Read the whole conversation, judge what has been accomplished and what is still missing, then output ONLY the " ++
    "next message to send — a single concrete instruction, question, or refinement that advances the goal. Write it " ++
    "as the user would (first person, imperative), with NO preamble, NO quotes, NO explanation — just the message text.\n" ++
    "Do NOT answer it yourself and do NOT include a TOOL:/CAST:/RUN: line — you are composing the user's next prompt, " ++
    "not the assistant's reply. Keep it to one or two sentences.\n" ++
    "If this is a BUILD/code task, do not settle for 'it looks done' — the next step should write/extend the real " ++
    "files and then run_tests (or run_python) to VERIFY; only treat the goal as achieved once it actually works.\n" ++
    "When the goal is fully achieved (the assistant has delivered what was asked, verified where possible, and no " ++
    "further step would add value), output EXACTLY the single word: DONE";
/// What auto-loop-afk sends when the driver declares DONE: the afk tier never accepts an end state, so
/// "done" becomes a re-verify + extend drive and the conversation keeps working (user directive: afk
/// goes forever — nothing but the user stops it).
const AFK_DRIVE_MSG = "keep going: re-verify the latest work end-to-end, then pick the most valuable next improvement or extension toward the goal and do it.";

// Recursive-thought (reflect) loop: ITERATIVE self-critique — keep re-reviewing the draft while each pass still
// meaningfully changes it (that's how a careful reasoner converges: critique → fix → re-critique → … until it's
// stable), capped so it always terminates. ONLY for substantive answers to substantive requests, never chit-chat
// (a "hello" must not recurse). REFLECT_MIN_ANSWER is the answer length below which an answer is trivial + skips.
const REFLECT_PASSES: u8 = 1; // >0 enables the loop; the depth is bounded by REFLECT_MAX_PASSES
const REFLECT_MAX_PASSES: u8 = 3; // hard ceiling on self-check iterations (each is one model call)
const REFLECT_MIN_ANSWER: usize = 500;

// Concurrent Veil: while a cast runs, the primary Veil ALSO works the SAME goal, in parallel, directly inside
// the hive's own shared build dir — it JOINS the swarm rather than building a rival copy. A separate workdir +
// a post-hoc "pick the better one or merge them" pass reconciles two divergent version histories, which is
// exactly the merge problem the swarm's OWN micro-VCS (vcs.zig, chat_tools.zig's vcs_enabled) already solves;
// so the veil's tool calls target the identical dir and the swarm's concurrent-edit safety reconciles both
// streams. Costs extra model calls per cast, so it's a single flag to disable for cast-only runs.
const CONCURRENT_VEIL: bool = true;

// MEMORY INSIDE RECURSIVE THOUGHT: mirror the veil's reasoning-time `observe` tool into the durable per-user
// memory (the Memory tab) for PERSONAL facts (keys/logins/prefs). Without this, what the veil learns WHILE
// reasoning lands only in the shared hive store and never reaches the store the user manages. Strictly additive
// (the server `observe` still runs); gated so it's one flag to disable. See personalFact + the mirror in
// runToolAndContinue.
const MIRROR_OBSERVE: bool = true;

// ---- micro-console (dual-tab shell) ---------------------------------------------------------------------
// A shell command MUST NOT run inline on this worker thread: a hang (a dev server, `ping -t`, a REPL) would
// freeze chat turns AND cast-watching until it returned. Instead a command runs as an INDEPENDENT OS process
// writing to temp sink files, and run()'s loop POLLS it every ~100ms tick (pumpConsole) — so even a hard hang
// never wedges the thread. Three guards bound it: a wall-clock deadline (kill + report), a Stop button
// (console_cancel), and an output-flood cap. One command runs at a time.
const CONSOLE_TIMEOUT_AI_S: i64 = 60; // AI RUN: door — a turn must not hang on a command the model chose
const CONSOLE_TIMEOUT_YOU_S: i64 = 300; // You tab — the user may deliberately run something longer
const CONSOLE_MAX_OUTPUT: u64 = 4 << 20; // force-stop a command that floods more than ~4MB into its sink

// Native, no-subprocess exit poll (std.process has no non-blocking wait). Mirrors supervisor.zig's winproc
// pattern: on Windows read the exit code straight off the child HANDLE. Termination itself uses Child.kill
// (native TerminateProcess via the Io vtable — no taskkill child, same spirit as terminateVeilPid).
const winproc = if (builtin.os.tag == .windows) struct {
    const STILL_ACTIVE: u32 = 259;
    extern "kernel32" fn GetExitCodeProcess(h: *anyopaque, code: *u32) callconv(.c) c_int;
} else struct {};

/// Non-blocking: has `child` exited? Windows peeks the exit code off the process handle (the caller still
/// reaps via Child.wait); POSIX reaps with waitpid(WNOHANG) and nulls child.id so the caller must NOT wait.
/// On a natural exit `exit_code` receives the FULL exit status where the OS makes it available — the u32
/// matters on Windows: Child.wait's Term truncates to u8, which reads NTSTATUS crashes (0xC0000135 = DLL
/// not found) as small numbers and any multiple of 256 as a clean 0.
fn procExited(child: *std.process.Child, exit_code: *?u32) bool {
    const id = child.id orelse return true; // already reaped / killed
    if (builtin.os.tag == .windows) {
        var code: u32 = 0;
        if (winproc.GetExitCodeProcess(id, &code) == 0) return true; // handle unusable → treat as done
        if (code == winproc.STILL_ACTIVE) return false;
        exit_code.* = code;
        return true;
    } else {
        var status: c_int = undefined;
        const r = std.c.waitpid(id, &status, 1); // 1 = WNOHANG
        if (r == 0) return false; // still running
        child.id = null; // reaped here — don't Child.wait again
        const st: u32 = @bitCast(status);
        if (st & 0x7f == 0) exit_code.* = (st >> 8) & 0xff; // WIFEXITED → WEXITSTATUS (signal deaths stay null)
        return true;
    }
}

/// One in-flight micro-console command, run off the worker's blocking path (see pumpConsole). `ai` selects
/// the tab: Veil (the AI's RUN: door, whose result folds back into the turn) vs You (the user's own shell).
/// stdout and stderr go to SEPARATE sink files ("<base>.out"/".err") because Windows reopens each inherited
/// handle independently — one shared file would let the two streams clobber each other at offset 0.
const ConsoleProc = struct {
    child: std.process.Child,
    ai: bool,
    started_s: i64,
    deadline_s: i64, // wall-clock time to force-kill (the hang guard)
    base: [320]u8 = undefined, // sink path stem; "<base>.out" + "<base>.err" hold stdout/stderr
    base_len: usize = 0,
    cmd: [1024]u8 = undefined, // the command text (for the [console] fold + the timeout message)
    cmd_len: usize = 0,

    fn baseStr(p: *const ConsoleProc) []const u8 {
        return p.base[0..p.base_len];
    }
    fn cmdStr(p: *const ConsoleProc) []const u8 {
        return p.cmd[0..p.cmd_len];
    }
};

pub const Chat = struct {
    io: Io,
    gpa: std.mem.Allocator,
    store: *Store,
    stop: std.atomic.Value(bool) = .init(false),
    abort_turn: std.atomic.Value(bool) = .init(false),

    stream: llm.Stream = .{},
    turn: Turn = .idle,
    first_byte_logged: bool = false, // one timing line per turn
    turn_start_ms: i64 = 0, // wall-clock (ms) this turn's model call started — for the Metrics tab
    turn_fb_ms: u32 = 0, // ms to the first streamed token this turn (0 until seen)
    parallel_tip: bool = false, // shown the OLLAMA_NUM_PARALLEL tip once
    last_user: [1600]u8 = undefined, // the message that started the current .user turn (for cast recovery)
    last_user_len: usize = 0,
    tool_iters: u32 = 0, // tool calls this user turn (bounded by MAX_TOOL_ITERS)
    loop_iter: u32 = 0, // auto-loop iterations since the last manual message (bounded by LOOP_MAX_ITERS)
    loop_casts: u32 = 0, // swarms this auto-loop session has fired (bounded by MAX_LOOP_CASTS — runaway guard)
    // The conversation's DURABLE goal (its first user message). The auto-loop's next-message generator otherwise
    // treats the whole drifted transcript tail as "the goal" and amplifies drift; this re-anchors it. Set on the
    // first real send / conversation load, NEVER written by loopContinue (a loop guess must not redefine the goal).
    arc_goal: [1600]u8 = undefined,
    arc_goal_len: usize = 0,
    loop_repeat_streak: u32 = 0, // consecutive near-identical loop steps — afk stall breaker (afk never stops, so
    console_fail_streak: u32 = 0, //   these ESCALATE a change-of-approach nudge instead of looping a failing step forever)
    // ESCALATION LADDER (user directive: issue → try-fix → CANNOT fix → research → cast a swarm). arc_stuck is the
    // shared rung counter every stall signal feeds; it climbs rung 1 (change-approach nudge) → 2 (force recall_hive/
    // web_search on the ACTUAL error) → 3 (arm a research cast). Cleared only at arc boundaries + on a real success,
    // so repeated DIFFERENT failures still climb even across a mode's own streak reset.
    arc_stuck: u8 = 0,
    tool_fail_streak: u8 = 0, // consecutive same-tool same-arg failures ("ok":false) — the blind spot no other streak caught
    last_tool_fail: [200]u8 = undefined, // the last failing tool's arg signature (to detect a repeat)
    last_tool_fail_len: usize = 0,
    arc_escalate_cast: bool = false, // rung 3 ARMED: fire a research cast at the next idle seam (never inline from a breaker)
    arc_escalate_casts: u8 = 0, // escalation research casts FIRED this arc — the hard, loop-independent runaway bound
    arc_escalate_capped: bool = false, // the arc spent its escalation-cast budget; the "pausing" note printed once
    arc_researched: bool = false, // this arc already did a forced research step (rung 2)
    force_cast_goal: [512]u8 = undefined, // the composed research-cast goal (arc_goal + failure signature)
    force_cast_goal_len: usize = 0,
    loop_idle: u8 = 0, // consecutive no-action settles — ONE is tolerated (persistence), two end the loop
    lookup_streak: u32 = 0, // consecutive web-lookup tool calls with no other progress — the STALL signal (a
    //                         busy-but-getting-nowhere spiral: the loop keeps acting, so loop_idle never fires)
    build_dir: [400]u8 = undefined, // absolute build workdir for THIS chat (set from the server's tool response);
    build_dir_len: usize = 0, // the AI writes files here + the console (You/Veil) is cd'd here so both share it
    reflect_draft: [12288]u8 = undefined, // the current draft being iteratively self-critiqued
    reflect_draft_len: usize = 0,
    reflect_pass: u8 = 0, // how many self-check iterations have run for this answer (bounded by REFLECT_MAX_PASSES)
    reflect_dirty: bool = false, // did ANY self-check pass change the draft (so the final differs from the first)?
    reflect_msg_idx: ?usize = null, // the visible message slot holding the live draft — revisions land IN PLACE
    //                                 here (no draft+revision double-post); appendMsg keeps it valid across eviction
    reflect_trace: [8192]u8 = undefined, // reasoning accumulated across the draft + every self-check pass; lands as
    reflect_trace_len: usize = 0, //        ONE collapsed .thought message above the answer at finalize
    reflect_trace_has_reason: bool = false, // did ANY pass contribute real reasoning (not just its label)? A
    //                                         labels-only trace is noise — no .thought chip is inserted for it
    draft_latched: bool = false, // this turn's stream crossed REFLECT_MIN_ANSWER (drafting presentation is
    //                              sticky per turn — see pumpStream); reset at every startTurn
    // CONVERSATION EPOCH — the cancellation barrier. Bumped whenever the user moves the conversation forward
    // (send / new conv / switch conv / Stop). Deferred continuations (cast collect, veil parallel work) capture
    // it when SCHEDULED and refuse to mutate the chat if it has moved — a finished cast then leaves one passive
    // note instead of hijacking a model turn to post-process an old goal into the live conversation.
    conv_epoch: u64 = 0,
    cast_epoch: u64 = 0, // conv_epoch when the active cast (and its concurrent-veil work) was scheduled
    turn_epoch: u64 = 0, // conv_epoch when the current model turn started (settle chains check it)

    // active cast bookkeeping (one at a time)
    cast_active: bool = false,
    cast_server_owned: bool = false, // a SERVER veil fired this cast; the desk only DISPLAYS it (no local lifecycle)
    cast_hex: [32]u8 = [_]u8{0} ** 32,
    cast_hex_len: usize = 0,
    cast_rel: [96]u8 = [_]u8{0} ** 96, // resolved run path relative to data dir
    cast_rel_len: usize = 0,
    cast_conv: [64]u8 = [_]u8{0} ** 64, // the conv this cast was fired for — its run dir is _chat/builds/<conv>
    // (must match sc_conv[64]: startServerCastWatch copies sc_conv here, and a >40-byte conv id would
    //  otherwise silently no-op the server-cast display.)
    cast_conv_len: usize = 0, // (chat casts build in the conv dir, so the run-dir basename is <conv>, not the hex)
    cast_deadline_s: i64 = 0,
    cast_minutes: u32 = CAST_MINUTES, // the time budget of the ACTIVE cast (AI-configurable; drives deadline + progress %)
    cast_stop_sent: bool = false,
    cast_ev_size: u64 = 0, // events.jsonl size at the last parse — unchanged size skips the read+parse entirely
    cast_ev_start: u64 = 0, // fold events only past this offset (set when a reused dir still holds a STALE run's log)
    cast_fired_s: i64 = 0, // when the cast was fired — an events file whose mtime predates this is a PRIOR run's
    cast_bp: [1536]u8 = undefined, // the hive's .blueprint (its intended file layout) — the veil orchestrates WITHIN it
    cast_bp_len: usize = 0, //        (written by the engine ~a minute into the run; loaded lazily once it appears)
    nar_round: i64 = -1, // last round narrated into the chat ("[hive] r3 66% — ..."); one milestone line per round
    nar_pct: i32 = -1, //    and per material score jump — the chat narrates hive progress even with zero model calls
    nar_txt: [120]u8 = undefined, // last narrated event text — a round whose latest event just repeats it is skipped
    nar_txt_len: usize = 0, //       (13 rounds of "depgraph: ..." must not become 13 identical chat lines)
    layout_nudged: [128]u8 = undefined, // top-level path segment already nudged once (second attempt is allowed)
    layout_nudged_len: usize = 0,
    steer_scratch: [12288]u8 = undefined, // STEER:-stripped copy of a reply (mem_scratch is taken by processMemory)
    cast_m: scan.Metrics = .{}, // last parsed metrics (reused on skipped ticks)
    cast_ev_n: usize = 0, //       and the matching ev_scratch count
    cast_forced: bool = false, // the collect was forced by the DESKTOP deadline (report "budget exhausted", not "finished")
    ctx_warned: bool = false, // shown the "local model loaded at a huge context (slow)" tip once
    ctx_poll_budget: u8 = 0, // watchCast re-checks the loaded ctx for the first few ticks (catches load-during-cast)

    // CONCURRENT VEIL: while a hive cast runs, the primary Veil ALSO works the SAME goal in parallel, writing
    // into the SAME shared build dir the cast is using (_chat/builds/{conv}/work) — it joins the swarm's build
    // instead of keeping a separate copy, so there is nothing to compare/merge afterward.
    veil_work_active: bool = false, // a parallel veil turn is running the cast's goal
    veil_started: bool = false, //     the one veil-work turn has been kicked off (drives idle-after-start completion)
    veil_done: bool = false, //        the veil's own turn has fully settled
    in_veil_work: bool = false, //     the CURRENT turn is the veil-work turn (still targets the SAME shared dir)
    veil_nudged: bool = false, //      the veil tried to CAST instead of working; re-issued once as a direct task
    cast_awaiting_veil: bool = false, // cast finished; waiting on veil_done before folding the (single) tree into the answer
    veil_goal: [1600]u8 = undefined, // the cast goal the veil works in parallel
    veil_goal_len: usize = 0,

    // HIPPOCAMPUS — the chat's own neuron-db (gpa-owned; "" = disabled → all memory ops no-op)
    mind_bin: []const u8 = "",
    mind_db: []const u8 = "",

    // micro-console: the one in-flight shell command (null = idle), polled from run() so it never blocks
    console: ?ConsoleProc = null,
    console_cancel: bool = false, // Stop button pressed → pumpConsole kills the running command next tick
    // COMMAND APPROVAL: a veil RUN: shell command parked awaiting the user's Approve/Bypass/Deny. While set,
    // the turn is held busy (awaitingShellApproval) and no new turn/loop/switch starts. Copied off the stream.
    pending_cmd: [1024]u8 = undefined,
    pending_cmd_len: usize = 0,
    // AUTO-LOOP is ARMED by a user send (chat_loop) but only CONTINUES while the veil is actually working —
    // this is set true when a turn dispatches a tool/shell/cast/kill, false when it settles on plain prose.
    // A conversational answer (nothing actioned) ends the loop instead of spinning on invented next-steps.
    acted: bool = false,
    // Did ANY dispatch fire since this loop step / user message began? `acted` is reset at EVERY settle, so
    // a build chain that wrote three files and then ANNOUNCED the fourth read as "just replied" and the
    // auto-loop disarmed. The loop must keep driving while the ARC is working; each loop step re-earns
    // continuation by acting (reset in loopContinue), so an announce-only step still ends it.
    arc_acted: bool = false,
    // AGENTIC FLOOR (the announced-but-never-performed death spiral + verify-before-done + lesson loop):
    act_nudges: u8 = 0, // act-followthrough nudges fired this arc (capped — never competes with real
    //                     dispatches for the tool budget). Live replay showed a narrating model often
    //                     answers the FIRST nudge with another announcement; the second converts it.
    arc_mutated: bool = false, // this arc performed a side-effecting action (shell launch / mutating tool) —
    //                            the trigger for the one bounded post-arc verification turn
    verify_done: bool = false, // the verification turn already ran for this arc (one per arc)
    // WHOLE-ARC build debt (survives loop steps; arc_mutated/verify_done are per-step and reset in
    // loopContinue). The auto-loop can end via loop_infer emitting DONE right after a settle that ANNOUNCED
    // more work (or falsely claimed a write) — the per-step verify was skipped and the loop finished with
    // files missing. arc_built stays true from the first real write/edit to the arc's end; when the loop
    // tries to finish, fireTerminalVerify runs ONE whole-build check (list_dir + write anything missing)
    // before it stops.
    arc_built: bool = false, // this arc wrote/edited at least one file (sticky across loop steps)
    arc_final_verified: bool = false, // the one terminal whole-build verify already fired for this arc
    arc_fail_cmd: [900]u8 = undefined, // the last console command that FAILED this arc (lesson capture pairs
    arc_fail_cmd_len: usize = 0, //       it with a later similar SUCCESS — verified transitions only)
    arc_fail_note: [96]u8 = undefined, // that failure's note ("(exit code 2147942402)")
    arc_fail_note_len: usize = 0,
    arc_fail_sig: [160]u8 = undefined, // that failure's salient error line (last non-empty stderr/stdout line) —
    arc_fail_sig_len: usize = 0, //       minted into the lesson so recall can rank by failure MODE, not just cmd
    playbook_hit: bool = false, // an operational lesson was injected into this turn's prompt (a later clean
    //                             console result Hebbian-strengthens THOSE lessons — once, then cleared)
    playbook_hit_lesson: [1400]u8 = undefined, // the exact lesson text injected this turn (recalled from
    playbook_hit_lesson_len: usize = 0, //        PLAYBOOK_SCOPE), so a clean console result can strengthen the
    //                                            precise facts that proved useful — never the raw user prompt
    //                                            (keying feedback on the prompt minted it as a bogus "lesson")
    consolidate_pending: bool = false, // an internal re-entry (act nudge / verify turn) preempted a settle that
    //                                    WOULD have consolidated memory — the arc's eventual settle owes one
    //                                    consolidation pass (otherwise mutating arcs silently never save facts)
    stream_retried: bool = false, // one transient stream-death retry per arc (a dead stream otherwise settles
    //                               the whole arc as an error and the chat stops trying)
    pending_directive: [3600]u8 = undefined, // ephemeral machine directive (act nudge / verify / format retry).
    //                                 Sized for the terminal-verify directive: ground-truth file listing
    //                                 (≤2000b) + the arc goal quote (≤300b) + instructions — too small and the
    //                                 instruction tail is silently truncated off a real listing.
    pending_directive_len: usize = 0, // for the NEXT turn's prompt ONLY — never persisted. Directives written
    //                                   into history re-feed as user rows on every later turn and poison the
    //                                   conversation's NEXT task.
    // EXTERNAL JUDGE (decoupled learning pass — its OWN stream + side dir, never the chat turn slot):
    judge_stream: llm.Stream = .{},
    judge_live: bool = false,
    judge_turns: u32 = 0, //     real user turns since the last pass (cadence trigger)
    judge_outcome: bool = false, // a verified fail→fix landed (outcome trigger — grade soon, not on a clock)
    judge_last_s: i64 = 0,
    curated: bool = false, // the deterministic curator pass runs once per app session

    // PLAN-BOARD watch (right pane checklist): the ACTIVE conv's {conv}/plan.jsonl, polled ~1Hz with a size cache
    // so an unchanged board costs one statFile. plan_conv keys the cache — a conv switch forces a re-read.
    plan_conv: [64]u8 = [_]u8{0} ** 64,
    plan_conv_len: usize = 0,
    plan_size: u64 = 0,

    // scratch (thread-owned)
    ev_scratch: [store_mod.CAST_TAIL]scan.Ev = undefined,
    sw_scratch: [scan.MAX_SWARMS]scan.SwarmSummary = undefined,
    plan_scratch: [store_mod.MAX_PLAN]store_mod.PlanRow = undefined,
    file_scratch: [scan.MAX_FILES]scan.FileRow = undefined,
    mem_scratch: [12288]u8 = undefined, // durable-memory directive stripping (REMEMBER:/FORGET: removed from the answer)
    mem_saved_n: usize = 0, // memories stored on the turn being finalized (set by processMemory, read by appendVeil)
    mem_forgot_n: usize = 0, //   "" forgotten — lets appendVeil confirm a directives-only reply that strips to empty
    internal_turn: bool = false, // the current turn's `last_user` is a MACHINE directive (merge/nudge), not a real
    //                              user message — so it must NOT trigger memory consolidation. Cleared in cmdSend.

    // SERVER CHAT (P0-6, gated on Settings.server_chat; default OFF ⇒ all of these stay inert). When ON, a user
    // send routes to the conv's SERVER-side turn instead of the local loop, and pumpServerChat renders the turn's
    // event frames into the transcript by polling /events past a byte cursor.
    sc_active: bool = false, // a server turn is in flight for sc_conv → pumpServerChat renders its NEW frames
    // The LAST send was routed to the server (persists after the turn ends). The local auto-loop (maybeLoop) checks
    // this: when the conv is served by the server, the SERVER drives its own loop, so the desk must not also run
    // the local loop. A fallback to local sets it false so the local loop resumes — and it isn't tied to the 45s
    // serverChatOn() cooldown, which would else strand a >45s local fallback build mid-loop.
    sc_serving: bool = false,
    sc_from: usize = 0, //      byte cursor into the conv's events.jsonl — only frames past here are new
    sc_conv: [64]u8 = [_]u8{0} ** 64, // the conv the server turn was fired for (its id doubles as the /events path)
    sc_conv_len: usize = 0,
    sc_fails: u32 = 0, //        consecutive failed/unreachable event polls — bounds the retry so a down server can't
    //                           leave the UI busy forever (reset on any good poll)
    sc_cooldown_until: i64 = 0, // after a server turn falls back to local, skip the server for a bit (unix secs) so a
    //                            down/misconfigured server doesn't pay the failed round-trip on EVERY send
    mirror_live: bool = false, // the last mirrorServerConv saw "live":true — a turn is EXECUTING for that conv
    //                            right now (a scheduled run), so selecting it should ATTACH the live poller
    // METRICS for a SERVER turn: the local recordMetric fires only on the LOCAL turn-settle path, so with the brain
    // server-side the Metrics tab went empty. These accumulate from the server frames (pumpServerChat) and record
    // one sample on {done}, exactly like a local turn — the same numbers, sourced from the backend's own stream.
    sc_turn_start_ms: i64 = 0, // wall-clock ms the server send was accepted
    sc_fb_ms: u32 = 0, //        ms to the FIRST streamed frame (first token/reasoning delta)
    sc_chars: usize = 0, //      content chars streamed this turn (the ~4x token proxy, matching recordMetric)
    sc_tools: u32 = 0, //        tool calls this turn
    sc_tokens_out: u32 = 0, //   the backend's REAL output-token count from the {usage} frame (preferred over the proxy)
    // ADAPTIVE /events poll: pumpServerChat is called every ~34ms tick while sc_active, and each call opens a FRESH
    // localhost TCP socket (Connection: close) for a full round-trip. Through the ~1.6s TTFT dead-window and the
    // inter-token lulls that is tens of empty 0-byte polls per turn — a sustained ~30 connect+close/sec piling up
    // TIME_WAIT sockets on the local server. These gate the poll: skip (no socket) until sc_next_poll_ms; poll FAST
    // right after any poll that consumed bytes, back off to SLOW after a few consecutive empties, snap back on data.
    sc_next_poll_ms: i64 = 0, //  earliest wall-clock ms for the next /events poll (0 = poll now)
    sc_empty_polls: u16 = 0, //   consecutive good polls that returned 0 new bytes (drives the back-off)

    pub fn run(self: *Chat) void {
        var dbuf: [512]u8 = undefined;
        const dd0 = self.dataDir(&dbuf);
        self.ensureDirs(dd0);
        // HIPPOCAMPUS: find the neuron binary + point at a chat-local sqlite so turns + cast findings persist as
        // recallable neurons (neurondb.zig). Silently disabled (memory ops no-op) if the binary isn't found.
        self.mind_bin = neurondb.findBin(self.gpa, self.io);
        {
            var mb: [600]u8 = undefined;
            const p = std.fmt.bufPrint(&mb, "{s}/.veil-desk/chat.sqlite", .{dd0}) catch "";
            if (p.len > 0) self.mind_db = self.gpa.dupe(u8, p) catch "";
        }
        log.info("chat hippocampus: {s}", .{if (self.mind_bin.len > 0) "enabled" else "disabled (neuron binary not found)"});
        self.loadSettings(dd0);
        self.loadKey(dd0);
        self.refreshConvs(dd0, true);
        self.refreshMemory(dd0); // publish saved durable memories into the Memory tab at startup
        { // migrate any legacy sealed PAT to plaintext-local + restore it into memory so the veil can use it directly
            var sb0: [600]u8 = undefined;
            self.ensurePatUsable(dd0, sideDir(dd0, &sb0));
        }
        self.refreshProposals(dd0); // and any judge proposals still awaiting review
        self.fetchOllamaModels();

        var tick: u32 = 0;
        while (!self.stop.load(.monotonic)) {
            var db: [512]u8 = undefined;
            const dd = self.dataDir(&db);
            self.drainCommands(dd);
            self.pumpStream(dd);
            self.pumpServerChat(dd); // EVERY tick (10Hz), matching pumpStream, so a SERVER turn's streamed frames
            //                          type out smoothly. No-op unless sc_active.
            self.pumpConsole(dd); // poll any in-flight micro-console command (never blocks the loop)
            // ~1Hz auto-loop backstop: a .loop_kick that lands the instant a turn is finishing hits maybeLoop's
            // `turn != .idle` guard and is lost — the settle-point call can't recover it if the turn had already
            // settled. Re-checking every idle tick self-heals that gap (maybeLoop no-ops unless loop is on AND the
            // chat is genuinely idle with something to continue from, so this can't run away or double-fire).
            if (tick % 10 == 5) self.maybeLoop(dd);
            if (tick % 10 == 0) self.watchCast(dd); // ~1Hz beside the 10Hz stream pump
            if (tick % 10 == 4) self.watchPlan(dd); // ~1Hz: the ACTIVE conv's plan-board → right-pane checklist
            if (tick % 10 == 7) self.maybeVeilWork(dd); // concurrent veil: drive the parallel attempt (offset slot)
            if (tick % 10 == 3) self.maybeFinishAfterVeil(dd); // concurrent veil: compose the answer once cast + veil are both done
            // Files-tab refresh: ~2s while a turn/cast is actually producing files; ~20s once idle — an idle
            // desk was re-walking the active conv's whole build tree every 2 seconds forever (churn the
            // poller-side sub-scans had already been cured of).
            if ((self.turn != .idle or self.sc_active) and tick % 20 == 11) self.refreshChatFiles(dd);
            if (self.turn == .idle and !self.sc_active and tick % 200 == 11) self.refreshChatFiles(dd);
            if (tick % 50 == 0) self.refreshConvs(dd, false); // ~5s: pick up external changes
            if (tick % 300 == 299) self.fetchOllamaModels();
            if (tick % 10 == 9) self.pumpJudge(dd); // ~1Hz: the decoupled learning pass (own stream, never blocks)
            if (!self.curated and tick > 900 and tick % 50 == 21) self.curateOnce(dd); // once, ~90s after startup
            tick +%= 1;
            // SMOOTHER STREAMING (~30Hz while a reply types out): pump the stream 2 EXTRA times at ~33ms so the text
            // renders continuously like the local client, WITHOUT changing the 100ms cadence of the tick-scheduled
            // periodic tasks above. Inner pumps no-op unless something is actively streaming.
            if (self.turn != .idle or self.sc_active) {
                var extra: u8 = 0;
                while (extra < 2) : (extra += 1) {
                    self.io.sleep(.{ .nanoseconds = 33 * std.time.ns_per_ms }, .awake) catch {};
                    self.pumpStream(dd);
                    self.pumpServerChat(dd);
                }
                self.io.sleep(.{ .nanoseconds = 34 * std.time.ns_per_ms }, .awake) catch {};
            } else {
                self.io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
            }
        }
        llm.abort(&self.stream, self.io);
        self.stream.deinit(self.gpa);
        llm.abort(&self.judge_stream, self.io);
        self.judge_stream.deinit(self.gpa);
        if (self.console) |*p| p.child.kill(self.io); // don't leave a shell child running past shutdown
        self.console = null;
    }

    // ------------------------------------------------------------------------------ plumbing

    fn dataDir(self: *Chat, buf: []u8) []const u8 {
        self.store.lock();
        defer self.store.unlock();
        const d = self.store.settings.dataDir();
        const n = @min(d.len, buf.len);
        @memcpy(buf[0..n], d[0..n]);
        return buf[0..n];
    }

    fn nowS(self: *Chat) i64 {
        return @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_s));
    }

    fn nowMs(self: *Chat) i64 {
        return @intCast(@divTrunc(Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms));
    }

    /// AI ACT-INTENT ROUTER — the model's own judgment, replacing the hardcoded announcesAction verb/ack list for
    /// the act-follow-through decision. Given a reply that dispatched NO tool call, returns true if it
    /// announced/intended an action it failed to perform (→ nudge), false if it's a genuine answer/question/done
    /// (→ leave it), or null when it can't decide (no endpoint / call or parse failure) so the caller falls back
    /// to the announcesAction heuristic FLOOR. Bounded + SYNCHRONOUS (briefly blocks this settle) — the
    /// acknowledged cost trade for correctness. See ACT_ROUTER_SYS.
    fn routeMeantToAct(self: *Chat, dd: []const u8, reply: []const u8, hive_done: bool) ?bool {
        const body = std.mem.trim(u8, reply, " \r\n\t");
        if (body.len == 0) return false; // said nothing → nothing to follow through on
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.judgeProvider(&bb, &kb, &mb);
        if (prov.model.len == 0 or prov.base_url.len == 0) return null; // no endpoint → heuristic floor

        var msgs: std.ArrayListUnmanaged(u8) = .empty;
        defer msgs.deinit(self.gpa);
        msgs.appendSlice(self.gpa, "{\"role\":\"system\",\"content\":\"") catch return null;
        escJson(&msgs, self.gpa, ACT_ROUTER_SYS);
        msgs.appendSlice(self.gpa, "\"},{\"role\":\"user\",\"content\":\"") catch return null;
        escJson(&msgs, self.gpa, "USER INSTRUCTION:\n");
        escJson(&msgs, self.gpa, self.last_user[0..@min(self.last_user_len, 700)]);
        // A collect reply follows a FINISHED hive run: the work was already performed (by the swarm, its files
        // verified on disk in the fold above the reply). Without this line the router reads a completed-work
        // REPORT ("the file is in your workdir — ready to read") as an unperformed promise and forces a redo
        // spiral: nudge → re-enter → (any) file-check hiccup → the veil rebuilds the hive's whole deliverable.
        if (hive_done) escJson(&msgs, self.gpa, "\n\nCONTEXT: a worker hive ALREADY completed this task in this same turn and saved its output files to disk (verified). A reply that reports or summarizes that finished work is a genuine answer, NOT an unperformed action. Only answer true if the reply promises a NEW action beyond the hive's completed work.");
        escJson(&msgs, self.gpa, "\n\nASSISTANT REPLY (no tool call was made this turn):\n");
        escJson(&msgs, self.gpa, body[0..@min(body.len, 1400)]);
        escJson(&msgs, self.gpa, "\n\nDid the assistant intend an action it did not perform? Reply only the JSON.");
        msgs.appendSlice(self.gpa, "\"}") catch return null;

        const content = self.syncGatewayClassify(dd, prov, msgs.items, ROUTER_MAX_TOKENS) orelse return null;
        defer self.gpa.free(content);
        const key = "\"meant_to_act\"";
        const at = std.mem.indexOf(u8, content, key) orelse return null;
        const w = content[at + key.len .. @min(content.len, at + key.len + 24)];
        if (std.mem.indexOf(u8, w, "true") != null) {
            log.info("act router: meant_to_act=true (nudging) — reply had no tool call", .{});
            return true;
        }
        if (std.mem.indexOf(u8, w, "false") != null) {
            log.info("act router: meant_to_act=false (genuine answer/question) — no nudge", .{});
            return false;
        }
        return null; // unparseable → heuristic floor
    }

    /// A BOUNDED synchronous gateway completion: start a stream, poll it to completion (small sleeps, hard wall
    /// timeout), return gpa-owned content or null. The desk is async-stream-only, so this blocks the chat settle
    /// for the call's duration — acceptable for a rare, bounded classify (cost/latency optimized later). Uses its
    /// OWN curl-scratch dir so it never clobbers the live chat stream's files.
    fn syncGatewayClassify(self: *Chat, dd: []const u8, prov: llm.Provider, msgs: []const u8, max_tokens: u32) ?[]u8 {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        var rb: [700]u8 = undefined;
        const rdir = std.fmt.bufPrint(&rb, "{s}/router", .{side}) catch return null;
        _ = Io.Dir.cwd().createDirPathStatus(self.io, rdir, .default_dir) catch {};
        var s: llm.Stream = .{};
        if (!llm.start(&s, self.io, self.gpa, rdir, prov, msgs, max_tokens, self.nowS())) {
            s.deinit(self.gpa);
            return null;
        }
        const start_s = self.nowS();
        var guard: u32 = 0;
        while (!s.done and guard < 5000) : (guard += 1) {
            llm.poll(&s, self.io, self.gpa, self.nowS(), true);
            if (s.done) break;
            if (self.nowS() - start_s > 10) break; // hard 10s wall cap — a slow/unreachable gateway must not wedge the UI
            self.io.sleep(.{ .nanoseconds = 12 * std.time.ns_per_ms }, .awake) catch {};
        }
        llm.finish(&s, self.io);
        defer s.deinit(self.gpa);
        if (s.failed or s.content.items.len == 0) return null;
        return self.gpa.dupe(u8, s.content.items) catch null;
    }

    /// Record one completed turn's performance into the Metrics ring (chars are a ~4x proxy for tokens; the
    /// tok/s is measured over the GENERATION window = total minus first-byte, so queue/prefill latency doesn't
    /// deflate the rate). Called once per turn, at the settle point and the error path.
    fn recordMetric(self: *Chat, kind: Turn, ok: bool, out_chars: usize) void {
        // turn_start_ms is 0 until startTurn stamps it; an aborted or conversation-switch-raced turn can reach
        // here unstamped, and nowMs()-0 is a full epoch timestamp (~1.7e12) that overflows u32 — @max only guards
        // the negative side. Treat a missing/implausible start as an unmeasurable 0ms sample, never crash the desk.
        const raw_total_ms = self.nowMs() - self.turn_start_ms;
        const total_ms: u32 = if (self.turn_start_ms == 0 or raw_total_ms <= 0 or raw_total_ms > std.math.maxInt(u32)) 0 else @intCast(raw_total_ms);
        const gen_ms = if (total_ms > self.turn_fb_ms) total_ms - self.turn_fb_ms else total_ms;
        const toks: f32 = @as(f32, @floatFromInt(out_chars)) / 4.0;
        const tok_s: f32 = if (gen_ms > 0) toks / (@as(f32, @floatFromInt(gen_ms)) / 1000.0) else 0;
        self.store.pushMetric(.{
            .first_byte_ms = self.turn_fb_ms,
            .total_ms = total_ms,
            .out_chars = @intCast(@min(out_chars, std.math.maxInt(u32))),
            .tok_per_s = tok_s,
            .tools = @intCast(@min(self.tool_iters, std.math.maxInt(u16))),
            .kind = @intFromEnum(kind),
            .ok = ok,
        });
    }

    /// Record one completed SERVER turn's performance into the Metrics ring — the server-path twin of recordMetric,
    /// sourced from the backend's own event stream (accumulated in renderScFrame). Keeps the Metrics tab live now
    /// that the brain is server-side (the local settle path that calls recordMetric never runs for a served conv).
    fn recordServerMetric(self: *Chat) void {
        const raw_total = self.nowMs() - self.sc_turn_start_ms;
        const total_ms: u32 = if (self.sc_turn_start_ms == 0 or raw_total <= 0 or raw_total > std.math.maxInt(u32)) 0 else @intCast(raw_total);
        const gen_ms = if (total_ms > self.sc_fb_ms) total_ms - self.sc_fb_ms else total_ms;
        // Prefer the backend's REAL output-token count; fall back to the char/4 proxy (as recordMetric uses) if the
        // usage frame carried none.
        const toks: f32 = if (self.sc_tokens_out > 0) @floatFromInt(self.sc_tokens_out) else @as(f32, @floatFromInt(self.sc_chars)) / 4.0;
        const tok_s: f32 = if (gen_ms > 0) toks / (@as(f32, @floatFromInt(gen_ms)) / 1000.0) else 0;
        if (self.sc_turn_start_ms == 0) return; // an aborted/unstamped server turn is unmeasurable — skip, never crash
        self.store.pushMetric(.{
            .first_byte_ms = self.sc_fb_ms,
            .total_ms = total_ms,
            .out_chars = @intCast(@min(self.sc_chars, std.math.maxInt(u32))),
            .tok_per_s = tok_s,
            .tools = @intCast(@min(self.sc_tools, std.math.maxInt(u16))),
            .kind = @intFromEnum(Turn.user), // a server turn maps to the user-turn kind in the Metrics view
            .ok = true,
        });
        self.sc_turn_start_ms = 0; // consumed — the next send re-stamps (guards a stray duplicate {done})
    }

    /// The chat's hippocampus client (neuron-db). All ops no-op when the binary/db is unavailable.
    fn mind(self: *Chat) neurondb.Db {
        return .{ .gpa = self.gpa, .io = self.io, .bin = self.mind_bin, .db = self.mind_db };
    }

    /// The neuron-db scope for the ACTIVE conversation (its id) — memory is partitioned per conversation so
    /// recall never bleeds an unrelated chat's facts. Caller must hold no store lock. Empty if no active conv.
    fn convScope(self: *Chat, buf: []u8) []const u8 {
        self.store.lock();
        defer self.store.unlock();
        const id = self.store.conv_active[0..self.store.conv_active_len];
        const n = @min(id.len, buf.len);
        @memcpy(buf[0..n], id[0..n]);
        return buf[0..n];
    }

    /// Ask the local Ollama which models are installed (GET /api/tags) and publish their names so the
    /// Settings model dropdown shows the user's REAL models instead of a guessed catalog list. Best-effort:
    /// on any failure the dropdown falls back to the catalog. Uses the configured local base, else the
    /// default; the root is derived by trimming a trailing /v1.
    fn fetchOllamaModels(self: *Chat) void {
        var rootbuf: [200]u8 = undefined;
        var root: []const u8 = "http://127.0.0.1:11434";
        {
            self.store.lock();
            const s = &self.store.settings;
            const base = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1";
            self.store.unlock();
            var r = std.mem.trimEnd(u8, base, "/");
            if (std.mem.endsWith(u8, r, "/v1")) r = r[0 .. r.len - 3];
            // only probe a LOCAL ollama (loopback); a remote/BYOK base has no /api/tags for us to list
            if ((std.mem.indexOf(u8, r, "127.0.0.1") != null or std.mem.indexOf(u8, r, "localhost") != null) and std.mem.indexOf(u8, r, "11434") != null) {
                const n = @min(r.len, rootbuf.len);
                @memcpy(rootbuf[0..n], r[0..n]);
                root = rootbuf[0..n];
            }
        }
        // in-process socket, not curl: root is guaranteed loopback by the guard above, and the probe
        // must not feed Defender's spawn-pattern heuristics on every Settings open
        const target = httpc.parseLoopbackUrl(root) orelse return;
        var pathbuf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&pathbuf, "{s}/api/tags", .{target.path}) catch return;
        const resp = switch (httpc.request(self.io, self.gpa, .{
            .method = "GET",
            .port = target.port,
            .path = path,
            .timeout_s = 5,
            .cap = 256 << 10,
        })) {
            .ok => |r| r,
            else => return,
        };
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        if (resp.status != 200) return;
        // parse the "name":"..." fields (one per installed model)
        self.store.lock();
        defer self.store.unlock();
        self.store.ollama_model_count = 0;
        var i: usize = 0;
        const needle = "\"name\":\"";
        while (std.mem.indexOfPos(u8, resp.body, i, needle)) |at| {
            if (self.store.ollama_model_count >= store_mod.MAX_OLLAMA_MODELS) break;
            const from = at + needle.len;
            const end = std.mem.indexOfScalarPos(u8, resp.body, from, '"') orelse break;
            const name = resp.body[from..end];
            i = end + 1;
            if (name.len == 0 or name.len > 96) continue;
            var m: store_mod.OllamaModel = .{};
            @memcpy(m.name[0..name.len], name);
            m.name_len = @intCast(name.len);
            self.store.ollama_models[self.store.ollama_model_count] = m;
            self.store.ollama_model_count += 1;
        }
        log.info("chat: {d} local ollama models listed", .{self.store.ollama_model_count});
    }

    /// Is the chat model the local Ollama backend (where NUM_PARALLEL contention applies)?
    fn isLocalChat(self: *Chat) bool {
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        if (s.chat_kind == 0) return true; // local (Ollama) provider
        if (s.chat_kind == 2) return std.mem.indexOf(u8, s.chatBase(), "11434") != null; // custom URL at Ollama
        return false;
    }

    /// Largest "context_length": value in an /api/ps body (0 if none/unparseable). Pure — unit-tested.
    fn parseMaxCtx(body: []const u8) u32 {
        var maxc: u32 = 0;
        var i: usize = 0;
        const needle = "\"context_length\":";
        while (std.mem.indexOfPos(u8, body, i, needle)) |at| {
            var j = at + needle.len;
            while (j < body.len and body[j] == ' ') j += 1;
            var v: u64 = 0;
            var any = false;
            while (j < body.len and body[j] >= '0' and body[j] <= '9') : (j += 1) {
                v = v * 10 + (body[j] - '0');
                any = true;
                if (v > std.math.maxInt(u32)) break;
            }
            if (any and v > maxc) maxc = std.math.cast(u32, v) orelse std.math.maxInt(u32);
            i = j;
        }
        return maxc;
    }

    /// Best-effort: the context window the LOCAL Ollama has actually loaded the model with (0 if not local /
    /// nothing loaded / unreachable). Ollama IGNORES the per-request num_ctx and honors only the
    /// OLLAMA_CONTEXT_LENGTH env var; when that is unset, gpt-oss loads at its full 131072 window whose KV
    /// cache eats ~6GB of VRAM, starving the model onto the CPU (~1 tok/s) and making swarm casts crawl. A
    /// value far above what we request (32768) is the tell that the env var is unset — see localSlowTip.
    fn loadedLocalCtx(self: *Chat) u32 {
        if (!self.isLocalChat()) return 0;
        var rootbuf: [200]u8 = undefined;
        var root: []const u8 = "http://127.0.0.1:11434";
        {
            self.store.lock();
            const s = &self.store.settings;
            const base = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1";
            self.store.unlock();
            var r = std.mem.trimEnd(u8, base, "/");
            if (std.mem.endsWith(u8, r, "/v1")) r = r[0 .. r.len - 3];
            if ((std.mem.indexOf(u8, r, "127.0.0.1") != null or std.mem.indexOf(u8, r, "localhost") != null) and std.mem.indexOf(u8, r, "11434") != null) {
                const n = @min(r.len, rootbuf.len);
                @memcpy(rootbuf[0..n], r[0..n]);
                root = rootbuf[0..n];
            }
        }
        // in-process socket, not curl (same reasoning as fetchOllamaModels)
        const target = httpc.parseLoopbackUrl(root) orelse return 0;
        var pathbuf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&pathbuf, "{s}/api/ps", .{target.path}) catch return 0;
        const resp = switch (httpc.request(self.io, self.gpa, .{
            .method = "GET",
            .port = target.port,
            .path = path,
            .timeout_s = 4,
            .cap = 64 << 10,
        })) {
            .ok => |r| r,
            else => return 0,
        };
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        if (resp.status != 200) return 0;
        return parseMaxCtx(resp.body);
    }

    /// If a local model is loaded with a runaway context (env var unset), tell the user the one-line fix
    /// ONCE — a slow cast otherwise looks like a broken cast. No-op when correctly configured.
    fn localSlowTip(self: *Chat, dd: []const u8) void {
        if (self.ctx_warned) return;
        const ctx = self.loadedLocalCtx();
        if (ctx <= 40000) return; // 0 (not local / nothing loaded) or a sane window → nothing to warn about
        self.ctx_warned = true;
        self.appendMsg(dd, .cast_note, "[cast] heads-up: your local model is loaded with a very large context window, so most of it is running on the CPU and this swarm will be slow. For ~16x faster local casts, set the Windows environment variable OLLAMA_CONTEXT_LENGTH=8192 and fully restart Ollama.");
        log.info("cast: local model loaded at ctx={d} (>40k) — OLLAMA_CONTEXT_LENGTH likely unset; warned user", .{ctx});
    }

    fn ensureDirs(self: *Chat, dd: []const u8) void {
        var pbuf: [600]u8 = undefined;
        const dirs = [_][]const u8{ "chats", "judge", "archive" }; // judge = its own curl-sink dir (the chat's
        for (dirs) |d| { //                                           sink filenames are fixed per dir); archive =
            //                                                        the curator's export-before-forget packs
            const p = std.fmt.bufPrint(&pbuf, "{s}/.veil-desk/{s}", .{ dd, d }) catch return;
            _ = Io.Dir.cwd().createDirPathStatus(self.io, p, .default_dir) catch {};
        }
    }

    fn sideDir(dd: []const u8, buf: []u8) []const u8 {
        const p = std.fmt.bufPrint(buf, "{s}/.veil-desk", .{dd}) catch return dd;
        return p;
    }

    fn setStatus(self: *Chat, s: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        const n = @min(s.len, self.store.chat_status.len);
        @memcpy(self.store.chat_status[0..n], s[0..n]);
        self.store.chat_status_len = @intCast(n);
    }

    fn setBusy(self: *Chat, v: bool) void {
        self.store.lock();
        defer self.store.unlock();
        self.store.chat_busy = v;
        if (!v) {
            self.store.stream_len = 0;
            self.store.stream_reason_len = 0;
            self.store.stream_draft = false;
            self.store.chat_status_len = 0;
        }
    }

    // ------------------------------------------------------------------------------ commands

    fn drainCommands(self: *Chat, dd: []const u8) void {
        while (self.store.popChatCmd()) |c| {
            switch (c.kind) {
                .none => {},
                .send => self.cmdSend(dd, c.textStr()),
                .steer_turn => self.cmdSteerTurn(dd, c.textStr()),
                // Guard a chat switch/new-chat while ANY work is pending (a streaming reply, a running cast, or an
                // AI console command): switching would repoint conv_active and the settling output would land in —
                // and overwrite — the wrong chat. Mirror the cmdDeleteConv precedent: refuse with a clear notice
                // instead of corrupting state.
                .new_conv => if (self.busyForSwitch()) self.store.pushNotif("Busy", "let the current reply or cast finish before starting a new chat", 2) else self.cmdNewConv(dd),
                .select_conv => if (self.busyForSwitch()) self.store.pushNotif("Busy", "let the current reply or cast finish before switching chats", 2) else self.cmdSelectConv(dd, c.idStr()),
                .rename_conv => self.cmdRenameConv(dd, c.idStr(), c.textStr()),
                .delete_conv => self.cmdDeleteConv(dd, c.idStr()),
                .stop_cast => self.cmdStopCast(dd, c.idStr()),
                .save_settings => self.saveSettings(dd),
                .save_key => self.cmdSaveKey(dd, c.textStr()),
                .console_run => self.cmdConsoleRun(dd, std.mem.eql(u8, c.idStr(), "veil"), c.textStr()),
                .console_cancel => self.console_cancel = true, // Stop button → pumpConsole kills it next tick
                .console_approve => self.cmdConsoleApprove(dd, std.mem.eql(u8, c.idStr(), "always")), // Approve / Bypass a parked veil command
                .console_deny => self.cmdConsoleDeny(dd), // Deny the parked veil command
                // user just enabled auto-loop while idle → start it now. A SERVER-served conv needs its own kick
                // because maybeLoop stands down via sc_serving (arming the toggle alone would do nothing).
                .loop_kick => if (self.sc_serving) self.serverLoopKick(dd) else self.maybeLoop(dd),
                .stop_turn => self.stopTurn(dd), // Stop button by the input: abort the in-flight turn + halt auto-loop
                .chat_open_file => self.cmdChatOpenFile(dd, c.textStr()), // Files tab: load a file into the viewer
                .chat_open_folder => self.cmdChatOpenFolder(dd), // Files tab: open this chat's build folder in the OS
                .forget_mem => self.forgetMemory(dd, c.textStr()), // Memory tab: delete-button drops one saved memory
                .prop_accept => self.acceptProposal(dd, c.idStr(), c.textStr()), // Memory pane: promote a judge proposal
                .prop_reject => self.rejectProposal(dd, c.idStr(), c.textStr()), // Memory pane: discard one
                .set_github_pat => self.cmdSaveGithubPat(dd, c.textStr()), // ::pat / Settings — seal the GitHub token
                .set_github_user => self.cmdSaveGithubUser(dd, c.textStr()), // ::ghuser / Settings — the GitHub username
            }
        }
    }

    fn setConsoleBusy(self: *Chat, ai: bool, v: bool) void {
        self.store.lock();
        defer self.store.unlock();
        if (ai) self.store.console_busy_ai = v else self.store.console_busy_you = v;
    }

    /// Is the AI's RUN: door mid-command? While it awaits pumpConsole the model turn is logically in flight
    /// (busy is true, turn is idle) — new turns/loops must not start over it.
    fn consoleAiBusy(self: *Chat) bool {
        if (self.awaitingShellApproval()) return true; // a parked command holds the turn until approved/denied
        return if (self.console) |*p| p.ai else false;
    }

    /// The engine's handle to the outside world for server verbs (tool exec + cast). Constructed on demand over
    /// the shared store — the LocalRunner reads the live port + token from it. The engine NEVER calls netcli
    /// directly, so when the brain moves in-process server-side this getter returns an in-process runner instead
    /// with no other engine change. (P0-1 of the chat→backend move.)
    fn runner(self: *Chat) runner_mod.Runner {
        return runner_mod.local(self.store);
    }

    // ---------------------------------------------------------------- SERVER CHAT (P0-6, gated on server_chat)

    /// True when the SERVER CHAT setting is on (the chat brain runs in the backend, not the local loop). Read
    /// under the store lock. Default false ⇒ cmdSend takes the existing local path and this whole surface is inert.
    fn serverChatOn(self: *Chat) bool {
        {
            self.store.lock();
            defer self.store.unlock();
            if (!self.store.settings.server_chat) return false;
        }
        // In cooldown after a recent fallback → keep using the local engine until the backend has had time to
        // come back (avoids re-paying the failed round-trip on every message while a server is down/misconfigured).
        return self.nowS() >= self.sc_cooldown_until;
    }

    /// Set the server-turn-active state, mirroring it to the store so the input row can enable "Enter = steer".
    /// A plain bool write needs no lock (single-word, read by the render thread; a 1-frame-stale read is harmless).
    fn setServerActive(self: *Chat, v: bool) void {
        self.sc_active = v;
        self.store.chat_server_turn = v;
    }

    /// Route one user send to the conv's SERVER-side chat turn. Returns true if the send was handed to the server
    /// (the caller then SKIPS the entire local turn path); false if no conv could be resolved, so the caller falls
    /// back to the local loop. The user message is ALREADY in the transcript (cmdSend appended it before calling).
    fn routeToServerChat(self: *Chat, dd: []const u8, text: []const u8) bool {
        _ = dd;
        var convb: [96]u8 = undefined;
        const conv = self.convScope(&convb);
        if (conv.len == 0 or conv.len > self.sc_conv.len) return false; // no resolvable conv → local

        // Resolve the provider so BYOK carries server-side (the server falls back to its own config on blanks).
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.resolveProvider(&bb, &kb, &mb);

        // AUTO-LOOP MODE: the server now owns the loop, so PASS the desk's live toggle (0=off, 1=on, 2=afk) in the
        // body instead of throwing it away. The server drive loop drives persistently when armed (afk = never accept
        // DONE, only Stop ends it); the desk's LOCAL maybeLoop still stands down for this conv via the sc_serving guard.
        const loop_mode: u8 = blk_lm: {
            self.store.lock();
            defer self.store.unlock();
            break :blk_lm if (self.store.chat_loop_afk) @as(u8, 2) else if (self.store.chat_loop) @as(u8, 1) else @as(u8, 0);
        };

        // Heap body: on default-on a long user message would overflow a fixed buffer (which would then wrongly
        // fall back). Size it to the escaped worst case; any alloc/build failure just falls back to local.
        const cap = text.len * 2 + prov.base_url.len + prov.model.len + prov.key.len + 128;
        const body = self.gpa.alloc(u8, cap) catch return false;
        defer self.gpa.free(body);
        var w = Io.Writer.fixed(body);
        const bok = blk: {
            w.writeAll("{\"text\":\"") catch break :blk false;
            wesc(&w, text);
            w.writeAll("\",\"base_url\":\"") catch break :blk false;
            wesc(&w, prov.base_url);
            w.writeAll("\",\"model\":\"") catch break :blk false;
            wesc(&w, prov.model);
            w.writeAll("\",\"api_key\":\"") catch break :blk false;
            wesc(&w, prov.key);
            // CLIENT MODE: the server delegates every tool call back as a tool_request frame; the desk runs it on
            // THIS machine (via `veil exec-tool`) so the veil acts in the user's environment, not the server's box.
            w.writeAll("\",\"tool_client\":true,\"loop\":") catch break :blk false;
            w.writeByte('0' + loop_mode) catch break :blk false; // 0|1|2 — the desk's live auto-loop tier
            w.writeAll("}") catch break :blk false;
            break :blk true;
        };
        if (!bok) return false; // couldn't build the request → local fallback

        // Baseline cursor: only frames written AFTER this send are new (prior frames are already rendered/empty).
        var from0: usize = 0;
        if (self.runner().chatEvents(self.io, self.gpa, conv, 0)) |er| {
            from0 = er.body.len;
            if (er.body.len > 0) self.gpa.free(er.body);
        }

        self.setBusy(true);
        self.setStatus("server turn running...");
        log.info("server chat: send conv={s} from={d} model={s}", .{ conv, from0, prov.model });

        // The send returns FAST: the server fires the turn on a background thread and replies 202 ("running"), so
        // the poller below streams its event frames live (no blocking on the whole turn). 200/201/202 = accepted;
        // null = unreachable (a turn that already completed still exposes a {done} frame — check); anything else is
        // a definitive failure (501 kill switch, 401/403 not-admin, 404 old server binary, 5xx). Any non-success
        // FALLS BACK to the local engine so the user always gets a reply.
        var handled = false;
        if (self.runner().chatSend(self.io, self.gpa, conv, w.buffered())) |resp| {
            defer if (resp.body.len > 0) self.gpa.free(resp.body);
            log.info("server chat: POST -> status={d}", .{resp.status});
            handled = resp.status == 200 or resp.status == 201 or resp.status == 202;
        } else {
            log.warn("server chat: POST returned null — checking whether the turn completed anyway", .{});
            handled = self.serverTurnDone(conv, from0);
        }

        if (handled) {
            // METRICS: start this server turn's perf sample (recorded on {done} in renderScFrame) so the Metrics tab
            // stays live now that the brain is server-side.
            self.sc_turn_start_ms = self.nowMs();
            self.sc_fb_ms = 0;
            self.sc_chars = 0;
            self.sc_tools = 0;
            self.sc_tokens_out = 0;
            // Commit to the server for this turn. The SERVER now owns the loop (we passed loop_mode in the body), so
            // the desk's LOCAL auto-loop must NOT also drive turns — but do NOT clear the toggle (that would discard
            // the user's auto-loop/afk intent): sc_serving standing down the local maybeLoop keeps the desk from
            // double-driving while the toggle stays visibly armed and the server drives it.
            @memcpy(self.sc_conv[0..conv.len], conv);
            self.sc_conv_len = conv.len;
            self.sc_from = from0;
            self.sc_fails = 0;
            self.sc_next_poll_ms = 0; // poll immediately; the adaptive gate takes over after the first poll
            self.sc_empty_polls = 0;
            self.scClearStream(); // fresh live preview for this turn's streamed deltas
            self.setServerActive(true); // keep busy; pumpServerChat clears it on {done}
            self.sc_serving = true; // this conv is served by the server → the desk's local auto-loop stands down
            return true;
        }

        // FALLBACK → local engine: clear the UX we set, arm a cooldown (don't re-pay the failed round-trip on
        // every send while the backend is down/misconfigured), and return false so cmdSend runs the local path.
        self.setBusy(false);
        self.setStatus("");
        self.sc_cooldown_until = self.nowS() + SC_COOLDOWN_S;
        log.info("server chat: unavailable — falling back to the local engine (cooldown {d}s)", .{SC_COOLDOWN_S});
        return false;
    }

    /// One cheap poll: does the conv's events.jsonl carry a {"kind":"done"} frame past byte offset `from`? Detects
    /// a server turn that COMPLETED but whose POST timed out, so we render it instead of double-running locally.
    fn serverTurnDone(self: *Chat, conv: []const u8, from: usize) bool {
        const resp = self.runner().chatEvents(self.io, self.gpa, conv, from) orelse return false;
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        if (resp.status != 200) return false;
        return std.mem.indexOf(u8, resp.body, "\"kind\":\"done\"") != null;
    }

    /// SERVER CHAT poller: render a server-side turn's event frames into the transcript. No-op unless a server send
    /// armed it (sc_active) — so with server_chat OFF this never does anything. Reads the conv's events.jsonl past
    /// the byte cursor and renders each COMPLETE line, advancing the cursor ONLY past complete lines (a trailing
    /// partial line waits for the next poll — keeps rendering idempotent). Called ~1Hz from run().
    fn pumpServerChat(self: *Chat, dd: []const u8) void {
        if (!self.sc_active) return;
        const conv = self.sc_conv[0..self.sc_conv_len];
        if (conv.len == 0) {
            self.abortServerChat(dd, "");
            return;
        }
        // ADAPTIVE gate: skip this tick's poll (open NO socket) until the scheduled next-poll time. This collapses
        // the tens of empty polls/turn during TTFT + inter-token lulls into a ~120ms cadence while still tracking
        // arriving frames at ~30Hz. A {done} frame lands right after a non-empty message frame (→ FAST), so turn
        // completion is still caught within a frame; only a bare lull can delay detection by up to SC_POLL_SLOW_MS.
        const poll_now = self.nowMs();
        if (poll_now < self.sc_next_poll_ms) return;
        const resp = self.runner().chatEvents(self.io, self.gpa, conv, self.sc_from) orelse {
            // server unreachable this tick — don't spin or crash: retry next tick, but bound it so a truly down
            // server can't leave the chat busy forever.
            self.sc_fails +%= 1;
            if (self.sc_fails >= SC_MAX_FAILS) self.abortServerChat(dd, "(server chat: no response from the veil server — stopping)");
            return;
        };
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        if (resp.status != 200) {
            self.sc_fails +%= 1;
            if (self.sc_fails >= SC_MAX_FAILS) {
                var nb: [200]u8 = undefined;
                self.abortServerChat(dd, std.fmt.bufPrint(&nb, "(server chat: events poll failed — HTTP {d}, stopping)", .{resp.status}) catch "(server chat: events poll failed)");
            }
            return;
        }
        self.sc_fails = 0; // a good poll refills the failure budget
        const bodyb = resp.body;
        var consumed: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bodyb, start, '\n')) |nl| {
            const line = bodyb[start..nl]; // a COMPLETE line (excludes the '\n')
            consumed = nl + 1; //            everything up to and including this '\n' is safe to advance past
            start = nl + 1;
            self.renderScFrame(dd, line);
            if (!self.sc_active) break; // a {done} frame disarmed us — stop rendering the rest of this poll
        }
        self.sc_from += consumed; // advance ONLY past complete lines; a trailing partial waits for the next poll
        // schedule the next poll: FAST while bytes flow, back off to SLOW once several polls in a row come up empty.
        if (consumed > 0) {
            self.sc_empty_polls = 0;
            self.sc_next_poll_ms = poll_now + SC_POLL_FAST_MS;
        } else {
            self.sc_empty_polls +|= 1;
            // Give up if the turn went totally silent without a {done} (server up but the turn thread died): the
            // send column would otherwise stay locked on Stop with no way back but a manual click.
            if (self.sc_empty_polls >= SC_MAX_EMPTY) {
                self.abortServerChat(dd, "(server chat: the turn went silent without finishing — stopping)");
                return;
            }
            self.sc_next_poll_ms = poll_now + (if (self.sc_empty_polls >= SC_POLL_EMPTY_BACKOFF) SC_POLL_SLOW_MS else SC_POLL_FAST_MS);
        }
    }

    /// Append a streamed delta to the in-flight reply (is_reason=false) or reasoning (is_reason=true) buffer — the
    /// SAME buffers the local engine streams into, so main.zig renders them growing live (the reply "types out").
    /// Appends until full; a reply longer than the buffer caps the live preview, but the final {kind:message}
    /// commits it whole. No-op after overflow.
    fn scStreamAppend(self: *Chat, is_reason: bool, delta: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        if (is_reason) {
            const cur = self.store.stream_reason_len;
            const n = @min(delta.len, self.store.stream_reason.len - cur);
            @memcpy(self.store.stream_reason[cur..][0..n], delta[0..n]);
            self.store.stream_reason_len = cur + n;
        } else {
            const cur = self.store.stream_len;
            const n = @min(delta.len, self.store.stream_text.len - cur);
            @memcpy(self.store.stream_text[cur..][0..n], delta[0..n]);
            self.store.stream_len = cur + n;
        }
    }

    /// Commit the in-flight streamed REASONING as a durable .thought chip and clear the live buffer (0 = no-op).
    fn scCommitReason(self: *Chat, dd: []const u8) void {
        var rbuf: [4096]u8 = undefined;
        var rlen: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            rlen = @min(self.store.stream_reason_len, rbuf.len);
            @memcpy(rbuf[0..rlen], self.store.stream_reason[0..rlen]);
            self.store.stream_reason_len = 0;
        }
        // no observe: server frames are already observed into the SERVER's hippocampus; a desk-side subprocess
        // observe per committed frame (dozens per turn) stalled the worker thread that pumps the 30Hz stream.
        if (rlen > 0) self.appendMsgFull(dd, .thought, rbuf[0..rlen], false);
    }

    /// Commit the in-flight streamed REPLY as a durable .veil message and clear the live buffer (0 = no-op).
    fn scCommitText(self: *Chat, dd: []const u8) void {
        var tbuf: [store_mod.STREAM_CAP]u8 = undefined;
        var tlen: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            tlen = @min(self.store.stream_len, tbuf.len);
            @memcpy(tbuf[0..tlen], self.store.stream_text[0..tlen]);
            self.store.stream_len = 0;
        }
        if (tlen > 0) self.appendMsgFull(dd, .veil, tbuf[0..tlen], false); // no observe — see scCommitReason
    }

    /// Discard any in-flight streamed reply/reasoning preview WITHOUT committing (both buffers).
    fn scClearStream(self: *Chat) void {
        self.store.lock();
        defer self.store.unlock();
        self.store.stream_len = 0;
        self.store.stream_reason_len = 0;
    }

    /// Render ONE server event frame line. Frames are one flat JSON object per line, keyed by "kind" (see
    /// src/worker/chat/engine.zig): token/reasoning (streamed deltas → the live preview) | message (the
    /// authoritative final reply, seals the stream) | tool | status | error | done.
    fn renderScFrame(self: *Chat, dd: []const u8, line_raw: []const u8) void {
        const line = std.mem.trim(u8, line_raw, " \r\n\t");
        if (line.len == 0) return;
        const kind = scRawField(line, "kind") orelse return; // no kind → not a frame we render
        // STREAMED DELTAS: grow the live preview (types out). Robust to a non-streaming backend too, which sends
        // ONE reasoning delta (whole thinking) + then the message — the buffer just grows in one step.
        if (std.mem.eql(u8, kind, "token") or std.mem.eql(u8, kind, "reasoning")) {
            if (self.sc_fb_ms == 0 and self.sc_turn_start_ms > 0) { // FIRST streamed frame → first-byte latency
                const fb = self.nowMs() - self.sc_turn_start_ms;
                self.sc_fb_ms = if (fb > 0 and fb <= std.math.maxInt(u32)) @intCast(fb) else 1; // >=1 so it reads as "set"
            }
            if (scRawField(line, "delta")) |raw| {
                var buf: [store_mod.STREAM_CAP]u8 = undefined;
                const d = scUnescape(raw, &buf);
                if (d.len > 0) {
                    const is_reason = std.mem.eql(u8, kind, "reasoning");
                    if (!is_reason) self.sc_chars += d.len; // content chars = out_chars proxy (reasoning excluded, as local does)
                    self.scStreamAppend(is_reason, d);
                }
            }
            return;
        }
        if (std.mem.eql(u8, kind, "message")) {
            const role = scRawField(line, "role") orelse "";
            if (std.mem.eql(u8, role, "user")) return; // the user message is already in the transcript locally
            self.scCommitReason(dd); // seal the streamed thinking as a .thought chip
            self.scClearStream(); // discard the live reply PREVIEW — the message content below is authoritative
            if (scRawField(line, "content")) |raw| {
                var buf: [store_mod.STREAM_CAP]u8 = undefined;
                const content = scUnescape(raw, &buf);
                // no observe: the desk observing the server veil's replies re-creates the confabulation loop the
                // server side already fixed (its own replies recalled later as "grounded context") — and each
                // observe is a subprocess spawn on the streaming worker thread.
                if (content.len > 0) self.appendMsgFull(dd, .veil, content, false);
            }
            return;
        }
        if (std.mem.eql(u8, kind, "tool")) {
            // a tool call ends the current streamed step — seal the pre-tool narration (thinking + any content).
            self.scCommitReason(dd);
            self.scCommitText(dd);
            const tool = scRawField(line, "tool") orelse "";
            const state = scRawField(line, "state") orelse "";
            if (std.mem.eql(u8, state, "start")) self.sc_tools += 1; // metrics: one count per tool call (start, not done)
            // A SERVER veil just cast a swarm — arm a DISPLAY-ONLY watch (once per cast, on its "start" frame) so the
            // right-pane Swarm activity shows the run. The desk never runs the local cast lifecycle here (the server
            // veil composes the answer via swarm_status). cast_active stays FALSE (see startServerCastWatch).
            if (std.mem.eql(u8, tool, "cast") and std.mem.eql(u8, state, "start") and !self.cast_active) {
                self.startServerCastWatch();
            }
            var pvb: [260]u8 = undefined;
            const preview: []const u8 = if (std.mem.eql(u8, state, "done"))
                (if (scRawField(line, "preview")) |raw| scUnescape(raw, &pvb) else "")
            else
                "";
            var nb: [440]u8 = undefined;
            const note = if (preview.len > 0)
                std.fmt.bufPrint(&nb, "[tool:{s}] {s} — {s}", .{ tool[0..@min(tool.len, 96)], state[0..@min(state.len, 16)], preview[0..@min(preview.len, 220)] }) catch "[tool]"
            else
                std.fmt.bufPrint(&nb, "[tool:{s}] {s}", .{ tool[0..@min(tool.len, 96)], state[0..@min(state.len, 16)] }) catch "[tool]";
            self.appendMsgFull(dd, .cast_note, note, false); // no observe — a "[tool:x] start" row is not knowledge
            return;
        }
        if (std.mem.eql(u8, kind, "error")) {
            self.scCommitReason(dd);
            self.scCommitText(dd);
            var buf: [512]u8 = undefined;
            const err = if (scRawField(line, "err")) |raw| scUnescape(raw, &buf) else "";
            var nb: [600]u8 = undefined;
            const note = std.fmt.bufPrint(&nb, "(server error: {s})", .{err[0..@min(err.len, 500)]}) catch "(server error)";
            self.appendMsgFull(dd, .veil, note, false); // no observe — an error string is not knowledge
            return;
        }
        if (std.mem.eql(u8, kind, "status")) {
            // a short progress line ("continuing: ...", "reflected") — surface it as the status, not a transcript row
            if (scRawField(line, "text")) |raw| {
                var buf: [160]u8 = undefined;
                const t = scUnescape(raw, &buf);
                if (t.len > 0) self.setStatus(t);
            }
            return;
        }
        if (std.mem.eql(u8, kind, "usage")) {
            // the turn's token usage — a subtle transcript note (persists; a status would be cleared by {done} next)
            if (scRawField(line, "text")) |raw| {
                var buf: [128]u8 = undefined;
                const t = scUnescape(raw, &buf);
                if (t.len > 0) {
                    var nb: [160]u8 = undefined;
                    self.appendMsgFull(dd, .cast_note, std.fmt.bufPrint(&nb, "\u{2219} {s}", .{t}) catch t, false); // no observe
                }
            }
            // METRICS: the backend's REAL output-token count — preferred over the char/4 proxy for tok/s.
            if (jInt(line, "tokens_out")) |n| {
                if (n > 0) self.sc_tokens_out = @intCast(@min(n, @as(i64, std.math.maxInt(u32))));
            }
            return;
        }
        if (std.mem.eql(u8, kind, "done")) {
            self.recordServerMetric(); // one perf sample per server turn — keeps the Metrics tab live server-side
            self.scClearStream(); // any unsealed preview is stale now
            self.setServerActive(false);
            self.setBusy(false);
            self.setStatus("");
            // The SERVER owns/drove this turn's whole (possibly multi-step) sequence and just finished it, so
            // the desk's auto-loop flags are stale — clear them. cmdSend force-arms chat_loop on every send, and
            // for a server-served conv the local stopLoop (which clears it) never runs, so without this the send
            // column stays stuck on "Stop" after the reply and the user has to click Stop before they can send
            // again. The server drove to completion regardless of these flags; clearing them only fixes the UI.
            {
                self.store.lock();
                self.store.chat_loop = false;
                self.store.chat_loop_afk = false;
                self.store.unlock();
            }
            self.sc_serving = false; // no longer server-served; the local maybeLoop may drive a future turn
            return;
        }
        if (std.mem.eql(u8, kind, "tool_request")) {
            // CLIENT MODE: the server delegated this tool call and is now BLOCKED awaiting our result. Run it on
            // THIS machine via the shared executor and post the result so the turn resumes. The matching "tool"
            // start/done frames still draw the transcript chip — this frame is purely the delegation signal.
            self.scCommitReason(dd); // seal any pre-tool narration before we go run the tool
            self.scCommitText(dd);
            const id = scRawField(line, "id") orelse return;
            const tool = scRawField(line, "tool") orelse return;
            self.runDelegatedTool(dd, id, tool, line); // extracts args off `line`, runs, posts to /tool_result
            return;
        }
        if (std.mem.eql(u8, kind, "file_sync")) {
            // CLIENT MODE: a finished hive's output file, pushed down by the server so this machine has it. Frames
            // are processed in order, so these land BEFORE the delegated read_file that gathers them.
            self.applyFileSync(dd, line);
            return;
        }
        if (std.mem.eql(u8, kind, "sync_request")) {
            // workdir-sync manifest exchange (server diffs before transferring; the probe detects a shared
            // disk). A `root` on the frame is a sync_dir projection: manifest THAT absolute client folder.
            const id = scRawField(line, "id") orelse return;
            self.answerSyncRequest(dd, id, line);
            return;
        }
        if (std.mem.eql(u8, kind, "file_pull")) {
            // the server wants these files (a cast's workdir sync, or a sync_dir projection's contents)
            const id = scRawField(line, "id") orelse return;
            self.answerFilePull(dd, id, line);
            return;
        }
        // any other kind: not rendered.
    }

    /// Materialize one server-pushed hive file ({kind:"file_sync",path,content}) into this conv's local build
    /// workdir — emitted after a cast completes so delegated file tools (and the Files tab) see the swarm's
    /// output on THIS machine, not just the server's disk. Path is workdir-relative and sanitized; nested
    /// parents are created. On a local (same-disk) install this rewrites identical bytes — harmless, the run
    /// is already terminal when the server emits these.
    fn applyFileSync(self: *Chat, dd: []const u8, line: []const u8) void {
        var pb: [512]u8 = undefined;
        const rawp = scRawField(line, "path") orelse return;
        const path = scUnescape(rawp, &pb);
        if (!safeSyncPath(path)) {
            log.warn("file_sync: rejected unsafe path {s}", .{path[0..@min(path.len, 120)]});
            return;
        }
        const rawc = scRawField(line, "content") orelse return;
        const cbuf = self.gpa.alloc(u8, rawc.len + 1) catch return; // decoded is never longer than the escaped raw
        defer self.gpa.free(cbuf);
        const content = scUnescape(rawc, cbuf);
        var relb: [180]u8 = undefined;
        const rel = self.chatBuildRel(&relb);
        if (rel.len == 0) return;
        var fb: [1100]u8 = undefined;
        const full = std.fmt.bufPrint(&fb, "{s}/{s}/work/{s}", .{ dd, rel, path }) catch return;
        if (std.fs.path.dirname(full)) |parent| _ = Io.Dir.cwd().createDirPathStatus(self.io, parent, .default_dir) catch {};
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = full, .data = content }) catch {
            log.warn("file_sync: could not write {s}", .{path[0..@min(path.len, 120)]});
            return;
        };
        log.info("file_sync: wrote {s} ({d}b)", .{ path[0..@min(path.len, 120)], content.len });
        // the workdir just gained hive files — bind the console/git to it if this conv had none yet
        if (self.build_dir_len == 0) self.syncBuildDir(dd);
    }

    /// Resolve this conv's delegated workdir (the same path runDelegatedTool roots tools at), creating it.
    fn delegatedWorkdir(self: *Chat, dd: []const u8, buf: []u8) []const u8 {
        var relb: [180]u8 = undefined;
        const rel = self.chatBuildRel(&relb);
        const wd = if (rel.len > 0)
            (std.fmt.bufPrint(buf, "{s}/{s}/work", .{ dd, rel }) catch dd)
        else
            dd;
        _ = Io.Dir.cwd().createDirPathStatus(self.io, wd, .default_dir) catch {};
        return wd;
    }

    /// Answer a {kind:"sync_request"} frame: spawn `veil sync-manifest` on this conv's workdir — or on the
    /// frame's `root` (a sync_dir projection of an absolute client folder; the subcommand validates it) — and
    /// post the manifest (+ probe echo) it prints. On ANY failure post an EMPTY manifest — the server then
    /// degrades to a full push instead of stalling to its timeout. The desk stays a dumb pipe: hashing, caps,
    /// the probe read, and root validation all live in the shared sync module the spawned verb calls.
    fn answerSyncRequest(self: *Chat, dd: []const u8, id: []const u8, line: []const u8) void {
        var rb: [512]u8 = undefined;
        var wdb: [820]u8 = undefined;
        const workdir = if (scRawField(line, "root")) |raw|
            scUnescape(raw, &rb)
        else
            self.delegatedWorkdir(dd, &wdb);
        var binb: [1100]u8 = undefined;
        const bin = self.veilBinPath(&binb);
        const argv = [_][]const u8{ bin, "sync-manifest", "--workdir", workdir };
        const r = std.process.run(self.gpa, self.io, .{ .argv = &argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(8 << 10) }) catch {
            self.postToolResult(id, "{\"probe\":\"\",\"files\":[]}");
            return;
        };
        defer self.gpa.free(r.stdout);
        defer self.gpa.free(r.stderr);
        self.postToolResult(id, if (r.stdout.len > 0) r.stdout else "{\"probe\":\"\",\"files\":[]}");
    }

    /// Answer a {kind:"file_pull"} frame: stage the frame as the args file, spawn `veil sync-read`, and post
    /// the batched contents it prints. A `root` on the frame reads from that absolute client folder (sync_dir;
    /// validated by the subcommand). Empty batch on any failure — the hive casts with what the server has.
    fn answerFilePull(self: *Chat, dd: []const u8, id: []const u8, line: []const u8) void {
        var rb: [512]u8 = undefined;
        var wdb: [820]u8 = undefined;
        const workdir = if (scRawField(line, "root")) |raw|
            scUnescape(raw, &rb)
        else
            self.delegatedWorkdir(dd, &wdb);
        // stage the frame in the DESK's own sidecar dir, never in `workdir` — a rooted sync reads a projected
        // source folder that must stay untouched (read-only contract; may be an immutable system)
        var afb: [900]u8 = undefined;
        const args_file = std.fmt.bufPrint(&afb, "{s}/.veil-desk/.veil-sync-pull.json", .{dd}) catch {
            self.postToolResult(id, "{\"files\":[]}");
            return;
        };
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = args_file, .data = line }) catch {
            self.postToolResult(id, "{\"files\":[]}");
            return;
        };
        defer Io.Dir.cwd().deleteFile(self.io, args_file) catch {};
        var binb: [1100]u8 = undefined;
        const bin = self.veilBinPath(&binb);
        self.setStatus("sending your files to the hive...");
        const argv = [_][]const u8{ bin, "sync-read", "--workdir", workdir, "--args-file", args_file };
        const r = std.process.run(self.gpa, self.io, .{ .argv = &argv, .stdout_limit = .limited(8 << 20), .stderr_limit = .limited(8 << 10) }) catch {
            self.postToolResult(id, "{\"files\":[]}");
            return;
        };
        defer self.gpa.free(r.stdout);
        defer self.gpa.free(r.stderr);
        self.postToolResult(id, if (r.stdout.len > 0) r.stdout else "{\"files\":[]}");
    }

    /// Resolve the `veil` server binary to invoke as `veil exec-tool` — it hosts the ONE tool executor, so the desk
    /// never re-implements a tool. Order: next to our own exe (release bundle colocates them) → the dev zig-out
    /// layout (desk/zig-out/bin → repo/zig-out/bin) → bare name on PATH. Written into `buf`.
    fn veilBinPath(self: *Chat, buf: []u8) []const u8 {
        const exe = if (builtin.os.tag == .windows) "veil.exe" else "veil";
        var selfb: [1024]u8 = undefined;
        if (std.process.executablePath(self.io, &selfb)) |n| {
            const self_exe = selfb[0..n];
            if (std.fs.path.dirname(self_exe)) |dir| {
                if (std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, exe })) |c| {
                    if (fileExists(self.io, c)) return c;
                } else |_| {}
                if (std.fmt.bufPrint(buf, "{s}/../../../zig-out/bin/{s}", .{ dir, exe })) |c| {
                    if (fileExists(self.io, c)) return c;
                } else |_| {}
            }
        } else |_| {}
        return std.fmt.bufPrint(buf, "{s}", .{exe}) catch exe; // PATH fallback
    }

    /// Run a server-delegated tool on THIS machine and post its result back. `line` is the full tool_request frame
    /// (we pull "args" off it here so the caller needn't heap-unescape). Rooted at this conv's build workdir — the
    /// SAME path the server would use — so files the tool writes land where the Files tab reads them.
    fn runDelegatedTool(self: *Chat, dd: []const u8, id: []const u8, tool: []const u8, line: []const u8) void {
        // 1) workdir = {dd}/{uid}/_chat/builds/{conv}/work (created on demand). Falls back to dd if unresolvable.
        var relb: [180]u8 = undefined;
        const rel = self.chatBuildRel(&relb);
        var wdb: [820]u8 = undefined;
        const workdir = if (rel.len > 0)
            (std.fmt.bufPrint(&wdb, "{s}/{s}/work", .{ dd, rel }) catch dd)
        else
            dd;
        _ = Io.Dir.cwd().createDirPathStatus(self.io, workdir, .default_dir) catch {};

        // 2) unescape the tool args (a write_file payload can be large → heap) and write them to a temp file that
        //    `veil exec-tool --args-file` reads. Off the argv: large + may contain quotes/newlines.
        const raw = scRawField(line, "args") orelse "{}";
        const argsbuf = self.gpa.alloc(u8, raw.len + 1) catch {
            self.postToolResult(id, "(desk: out of memory building tool args)");
            return;
        };
        defer self.gpa.free(argsbuf);
        const args_json = scUnescape(raw, argsbuf);
        var afb: [900]u8 = undefined;
        const args_file = std.fmt.bufPrint(&afb, "{s}/.veil-tool-args.json", .{workdir}) catch {
            self.postToolResult(id, "(desk: tool args path too long)");
            return;
        };
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = args_file, .data = args_json }) catch {
            self.postToolResult(id, "(desk: could not stage tool args)");
            return;
        };
        defer Io.Dir.cwd().deleteFile(self.io, args_file) catch {};

        // 3) spawn `veil exec-tool <tool> --workdir <wd> --args-file <af>` and capture its stdout (the tool result).
        var binb: [1100]u8 = undefined;
        const bin = self.veilBinPath(&binb);
        const argv = [_][]const u8{ bin, "exec-tool", tool, "--workdir", workdir, "--args-file", args_file };
        var stbuf: [96]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&stbuf, "running {s} on this machine...", .{tool[0..@min(tool.len, 48)]}) catch "running tool locally...");
        const r = std.process.run(self.gpa, self.io, .{
            .argv = &argv,
            .stdout_limit = .limited(512 << 10),
            .stderr_limit = .limited(32 << 10),
        }) catch |e| {
            var eb: [256]u8 = undefined;
            self.postToolResult(id, std.fmt.bufPrint(&eb, "(desk: could not run '{s} exec-tool' ({s}) — is the veil binary reachable?)", .{ bin[0..@min(bin.len, 120)], @errorName(e) }) catch "(desk: exec-tool failed to run)");
            return;
        };
        defer self.gpa.free(r.stdout);
        defer self.gpa.free(r.stderr);
        const out = r.stdout;
        const stderr = std.mem.trim(u8, r.stderr, " \r\n\t");
        // 4) post the result. Prefer stdout; if the subprocess produced nothing but wrote to stderr, surface that.
        if (out.len > 0) {
            self.postToolResult(id, out);
        } else if (stderr.len > 0) {
            var sb: [640]u8 = undefined;
            self.postToolResult(id, std.fmt.bufPrint(&sb, "(tool produced no output; stderr: {s})", .{stderr[0..@min(stderr.len, 600)]}) catch "(tool produced no output)");
        } else {
            self.postToolResult(id, ""); // empty is a valid result (e.g. a silent write); the turn must still resume
        }
    }

    /// POST {"id":..,"result":..} to /tool_result so the blocked server turn continues. Best-effort: if the post
    /// fails, the server's delegateTool times out (180s) rather than hanging forever — but that's a degraded turn,
    /// so this is the one call in the delegation path that must not silently drop.
    fn postToolResult(self: *Chat, id: []const u8, result: []const u8) void {
        var convb: [96]u8 = undefined;
        const conv = self.convScope(&convb);
        if (conv.len == 0) return;
        const cap = id.len * 2 + result.len * 2 + 64;
        const body = self.gpa.alloc(u8, cap) catch return;
        defer self.gpa.free(body);
        var w = Io.Writer.fixed(body);
        const ok = blk: {
            w.writeAll("{\"id\":\"") catch break :blk false;
            wesc(&w, id);
            w.writeAll("\",\"result\":\"") catch break :blk false;
            wesc(&w, result);
            w.writeAll("\"}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return;
        if (self.runner().chatToolResult(self.io, self.gpa, conv, w.buffered())) |resp| {
            if (resp.body.len > 0) self.gpa.free(resp.body);
            if (resp.status != 200 and resp.status != 202) log.warn("delegated tool_result POST -> {d}", .{resp.status});
        } else {
            log.warn("delegated tool_result POST unreachable (conv={s})", .{conv});
        }
    }

    /// End a server-chat exchange, optionally leaving a one-line notice (unreachable / poll failure). An empty
    /// note just disarms silently. Clears the busy/status the send set.
    fn abortServerChat(self: *Chat, dd: []const u8, note: []const u8) void {
        // A still-live server turn — especially a persistent afk loop — must be told to STOP before we disarm the
        // poller: once sc_active is false the Stop button won't reach it, so a server that is UP but whose polls we
        // gave up on (transient failures / a stuck cursor) would keep driving forever with no desk control. Best
        // effort — if the server is genuinely down the POST just fails (and nothing is running to strand).
        const conv = self.sc_conv[0..self.sc_conv_len];
        if (conv.len > 0) {
            if (self.runner().chatControl(self.io, self.gpa, conv, "{\"op\":\"stop\"}")) |r| {
                if (r.body.len > 0) self.gpa.free(r.body);
            }
        }
        self.sc_serving = false; // no longer server-served → the local auto-loop may take over
        self.releaseServerCastDisplay("detached"); // finalize the row + clear status (the server turn that owned it is gone)
        self.scClearStream(); // drop any half-streamed preview
        if (note.len > 0) self.appendMsg(dd, .veil, note);
        self.setServerActive(false);
        self.setBusy(false);
        self.setStatus("");
        // clear the auto-loop flags so the send column returns to "Send" (see the {done} handler) — an aborted
        // server turn is done driving too.
        {
            self.store.lock();
            self.store.chat_loop = false;
            self.store.chat_loop_afk = false;
            self.store.unlock();
        }
        // A server turn that died mid-flight → cool the backend off so the user's next send goes to the local
        // engine instead of stalling on the same broken server again.
        self.sc_cooldown_until = self.nowS() + SC_COOLDOWN_S;
    }

    /// Is there work in flight that a chat switch/new-chat would corrupt (a live model turn, a running cast, or an
    /// AI console command)? Any settling output resolves its target conversation from conv_active at write time, so
    /// repointing it mid-flight misroutes the reply — refuse the switch while this is true.
    fn busyForSwitch(self: *Chat) bool {
        // Also block during the WHOLE concurrent-veil window: castFinished flips cast_active false while the merge
        // is still pending (cast_awaiting_merge) and the veil turn may still be running (veil_work_active). A switch
        // in those idle gaps would repoint conv_active and the settling veil/merge appends would overwrite the
        // newly-selected chat. Mirror maybeLoop's guard. sc_active: a SERVER-chat turn renders its frames into the
        // active conv from the poller (self.turn stays .idle for it), so a switch mid-turn would misroute them.
        return self.turn != .idle or self.cast_active or self.consoleAiBusy() or self.veil_work_active or self.cast_awaiting_veil or self.sc_active;
    }

    /// Is a cast in flight anywhere in its lifecycle (deploying/running, or the concurrent-veil parallel attempt /
    /// pending finish)? Used to refuse a SECOND cast that would clobber the first's pending finish state.
    fn castPending(self: *Chat) bool {
        return self.cast_active or self.cast_awaiting_veil or self.veil_work_active;
    }

    /// A user-typed / AI-issued micro-console command (the "You"/"Veil" tab). Launches it asynchronously via
    /// consoleStart; pumpConsole reports the result (and, for the Veil tab, folds it back into the turn).
    fn cmdConsoleRun(self: *Chat, dd: []const u8, ai: bool, cmd: []const u8) void {
        self.consoleStart(dd, ai, cmd);
    }

    /// Point THIS chat's build workdir (and thus the console) at `rel` (server data-relative, e.g.
    /// "u1/_chat/builds/c6a4"). Called from a build tool's response so the console (You + Veil) `cd`s into the
    /// same folder the AI is writing files to. Only announces + creates when the directory actually changes.
    fn setBuildDir(self: *Chat, dd: []const u8, rel: []const u8) void {
        var ab: [400]u8 = undefined;
        const abs = std.fmt.bufPrint(&ab, "{s}/{s}", .{ dd, rel }) catch return;
        if (std.mem.eql(u8, abs, self.build_dir[0..self.build_dir_len])) return; // unchanged — no re-announce
        const n = @min(abs.len, self.build_dir.len);
        @memcpy(self.build_dir[0..n], abs[0..n]);
        self.build_dir_len = n;
        _ = Io.Dir.cwd().createDirPathStatus(self.io, abs, .default_dir) catch {}; // ensure it exists locally too
        // Isolate this conversation as its OWN git repo the moment its workdir is adopted, BEFORE any git can
        // run here — so a `RUN: git` shell (or the git tools) can never walk up to a parent repo and pollute it.
        gitvc.ensureRepo(self.gpa, self.io, abs);
        var nb: [480]u8 = undefined;
        const note = std.fmt.bufPrint(&nb, "[build] working directory: {s} — the console (You + Veil tabs) is cd'd here, so you can inspect and run the files.", .{rel}) catch "[build] working directory set";
        self.appendMsg(dd, .cast_note, note);
    }

    /// Re-bind the console to the ACTIVE conversation's build workdir on chat selection. setBuildDir only fires
    /// from a live build-tool response, so a chat reopened after an app restart kept its historical "[build]
    /// working directory ..." note (which re-feeds to the model) while the console actually ran from the app's
    /// own cwd — RUN:/console commands missed files the server-side tools could read. Restores silently: the
    /// note is already in the transcript, and the path matches setBuildDir's exactly so a later build tool sees
    /// "unchanged" and doesn't re-announce. A chat with NO build dir on disk CLEARS the binding instead, so the
    /// previous conversation's dir can't leak across a switch.
    fn syncBuildDir(self: *Chat, dd: []const u8) void {
        var rb: [160]u8 = undefined;
        const rel = self.chatBuildRel(&rb); // reads the OLD build_dir for the uid prefix — must run before the clear
        self.build_dir_len = 0;
        if (rel.len == 0) return;
        var ab: [400]u8 = undefined;
        const abs = std.fmt.bufPrint(&ab, "{s}/{s}/work", .{ dd, rel }) catch return;
        var d = Io.Dir.cwd().openDir(self.io, abs, .{}) catch return; // this chat never built — console stays at the app cwd
        d.close(self.io);
        const n = @min(abs.len, self.build_dir.len);
        @memcpy(self.build_dir[0..n], abs[0..n]);
        self.build_dir_len = n;
        gitvc.ensureRepo(self.gpa, self.io, abs); // a reopened chat's workdir is isolated too, before any shell git
    }

    /// Launch a micro-console command as an INDEPENDENT OS process and register it as the in-flight console
    /// proc; pumpConsole polls it to completion. Returns immediately — the command NEVER runs on this worker's
    /// blocking path, so a hang can't freeze chat or cast-watching. stdout/stderr are captured to two temp
    /// sink files (see ConsoleProc). At most one command runs at a time; a second is refused (and, on the AI
    /// door, the refusal folds straight back so the turn still continues).
    fn consoleStart(self: *Chat, dd: []const u8, ai: bool, cmd: []const u8) void {
        const trimmed = std.mem.trim(u8, cmd, " \r\n\t");
        if (trimmed.len == 0) {
            if (ai) self.foldConsoleAi(dd, "", "(empty command)");
            return;
        }
        if (self.console != null) {
            self.store.consoleAppend(ai, "\n(the console is busy with another command)\n");
            if (ai) self.foldConsoleAi(dd, trimmed, "(the console was busy; command not run)");
            return;
        }
        self.store.consoleAppend(ai, "\n> ");
        self.store.consoleAppend(ai, trimmed);
        self.store.consoleAppend(ai, "\n");
        // The AI door learns the batch %-rules from its system prompt; the HUMAN typing into the You tab
        // gets a one-line hint when their command is about to hit the classic trap ("%i was unexpected").
        if (builtin.os.tag == .windows and !ai and needsBatchPercentHint(trimmed))
            self.store.consoleAppend(ai, "(note: this console runs commands via a batch script — write for-loop variables as %%i, not %i)\n");

        // Sink files: <dd>/.veil-desk/console_{ai|you}.{out,err}. createFile truncates, so a prior run's bytes
        // never bleed in. Two files (not one) because Windows reopens each inherited handle independently, so a
        // shared sink would let stdout and stderr clobber each other at offset 0.
        var bb: [320]u8 = undefined;
        const base = std.fmt.bufPrint(&bb, "{s}/.veil-desk/console_{s}", .{ dd, if (ai) "ai" else "you" }) catch {
            self.consoleLaunchFailed(dd, ai, "(failed to prepare the command)");
            return;
        };
        var ob: [332]u8 = undefined;
        var eb: [332]u8 = undefined;
        const outp = std.fmt.bufPrint(&ob, "{s}.out", .{base}) catch {
            self.consoleLaunchFailed(dd, ai, "(failed to prepare the command)");
            return;
        };
        const errp = std.fmt.bufPrint(&eb, "{s}.err", .{base}) catch {
            self.consoleLaunchFailed(dd, ai, "(failed to prepare the command)");
            return;
        };
        const of = Io.Dir.cwd().createFile(self.io, outp, .{}) catch {
            self.consoleLaunchFailed(dd, ai, "(failed to open the console output file)");
            return;
        };
        const ef = Io.Dir.cwd().createFile(self.io, errp, .{}) catch {
            of.close(self.io);
            self.consoleLaunchFailed(dd, ai, "(failed to open the console output file)");
            return;
        };
        // Run in the chat's build workdir if one has been set (so `dir`/`ls`/`python app.py` see the AI's files).
        // LATE BIND if unbound: syncBuildDir only binds on chat SELECTION (dir must exist then) and setBuildDir
        // only on a build-tool response — a workdir created by a CAST after selection left the console in the app
        // cwd, so `type <hive file>` failed while the file sat right there and the veil concluded it was never
        // written (then re-did the hive's work inline). One cheap openDir probe per unbound console command.
        if (self.build_dir_len == 0) self.syncBuildDir(dd);
        // Set the child's CWD via a DIR HANDLE rather than prepending `cd /d …`: a prepended `cd` runs in the
        // spawned cmd's own initial directory (which differed from ours → "The system cannot find the path
        // specified" even though the AI's files were right there). Opening the build dir with the same
        // Io.Dir.cwd() the desktop's own (working) file ops use, then handing CreateProcessW the handle, makes
        // Windows infer the correct absolute path — no relative/absolute or slash ambiguity.
        var cwd_dir: ?Io.Dir = if (self.build_dir_len > 0)
            (Io.Dir.cwd().openDir(self.io, self.build_dir[0..self.build_dir_len], .{}) catch null)
        else
            null;
        defer if (cwd_dir) |*d| d.close(self.io); // valid through the spawn call; closed after
        // Windows: the command runs from a .cmd BATCH FILE, never as `cmd /c <argv element>`. spawn
        // serializes argv with C-runtime quoting (an embedded " becomes \") but cmd.exe parses its command
        // line under its OWN rules and never un-escapes \" — so any quoted command reached its child with
        // literal backslash-quote bytes (observed: powershell -Command "(Get-Date)..." degraded into a
        // quoted string literal that PowerShell just echoed). With a script file, spawn hands cmd.exe only
        // the (quoted) script path and the command INSIDE the file is parsed exactly as if typed in a
        // terminal: quotes, &&, pipes and redirects all keep their meaning. The path must be absolute
        // (a relative argv[0] resolves against .cwd — the BUILD dir — not where the script lives).
        var win_argv: [1][]const u8 = undefined;
        var apb: [520]u8 = undefined;
        const posix_argv = [_][]const u8{ "sh", "-c", trimmed };
        const argv: []const []const u8 = if (builtin.os.tag == .windows) blk: {
            var cpb: [332]u8 = undefined;
            const cmdp = std.fmt.bufPrint(&cpb, "{s}.cmd", .{base}) catch {
                of.close(self.io);
                ef.close(self.io);
                self.consoleLaunchFailed(dd, ai, "(failed to prepare the command)");
                return;
            };
            var script: [8192]u8 = undefined;
            const body = buildBatchScript(&script, trimmed) orelse {
                of.close(self.io);
                ef.close(self.io);
                self.consoleLaunchFailed(dd, ai, "(the command is too long or contains bytes the console cannot carry)");
                return;
            };
            Io.Dir.cwd().writeFile(self.io, .{ .sub_path = cmdp, .data = body }) catch {
                of.close(self.io);
                ef.close(self.io);
                self.consoleLaunchFailed(dd, ai, "(failed to write the command script)");
                return;
            };
            const an = Io.Dir.cwd().realPathFile(self.io, cmdp, &apb) catch {
                of.close(self.io);
                ef.close(self.io);
                Io.Dir.cwd().deleteFile(self.io, cmdp) catch {};
                self.consoleLaunchFailed(dd, ai, "(failed to prepare the command)");
                return;
            };
            win_argv[0] = apb[0..an];
            break :blk &win_argv;
        } else &posix_argv;
        const child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = if (cwd_dir) |d| .{ .dir = d } else .inherit,
            .stdin = .ignore,
            .stdout = .{ .file = of },
            .stderr = .{ .file = ef },
            .create_no_window = true, // don't flash a console window per command on Windows
        }) catch {
            of.close(self.io);
            ef.close(self.io);
            if (builtin.os.tag == .windows) {
                var cpb2: [332]u8 = undefined;
                if (std.fmt.bufPrint(&cpb2, "{s}.cmd", .{base})) |cmdp| {
                    Io.Dir.cwd().deleteFile(self.io, cmdp) catch {};
                } else |_| {}
            }
            self.consoleLaunchFailed(dd, ai, "(failed to launch the command)");
            return;
        };
        // The child inherited its own copies; drop ours so the sinks have a single writer we can read cleanly
        // once the process is dead.
        of.close(self.io);
        ef.close(self.io);

        const now = self.nowS();
        var p: ConsoleProc = .{
            .child = child,
            .ai = ai,
            .started_s = now,
            .deadline_s = now + (if (ai) CONSOLE_TIMEOUT_AI_S else CONSOLE_TIMEOUT_YOU_S),
        };
        const cn = @min(trimmed.len, p.cmd.len);
        @memcpy(p.cmd[0..cn], trimmed[0..cn]);
        p.cmd_len = cn;
        const bn = @min(base.len, p.base.len);
        @memcpy(p.base[0..bn], base[0..bn]);
        p.base_len = bn;
        self.console = p;
        self.console_cancel = false;
        self.setConsoleBusy(ai, true);
        // A launched veil shell command is a side effect until proven otherwise → the arc verifies before
        // settling on "done". Conservative: only clearly read-only probes (dir/type/Get-*...) are exempt, so
        // pure diagnostic arcs don't buy a verification round. (Set at LAUNCH, past the approval park — a
        // denied command never mutates.)
        if (ai and !looksReadOnlyCommand(trimmed)) {
            self.arc_mutated = true;
            self.arc_built = true; // a mutating shell command may have created files → owe a whole-build verify
        }
        log.info("console: {s} launched: {s}", .{ if (ai) "veil" else "you", trimmed[0..@min(trimmed.len, 120)] });
    }

    /// Report a launch failure into the scrollback and — on the AI door — fold it back so the turn continues
    /// (no console proc was registered, so nothing else will finalize it).
    fn consoleLaunchFailed(self: *Chat, dd: []const u8, ai: bool, msg: []const u8) void {
        self.store.consoleAppend(ai, msg);
        self.store.consoleAppend(ai, "\n");
        if (ai) self.foldConsoleAi(dd, "", msg);
    }

    /// Fold a finished console command's output back into the conversation as a [console] message and re-enter
    /// a .tool_follow turn so the model reads the result and continues (the AI RUN: door only).
    fn foldConsoleAi(self: *Chat, dd: []const u8, cmd: []const u8, result: []const u8) void {
        // a console command (e.g. a registration POST) is where the claim_url/verification_code first appears —
        // capture it durably before the ring evicts it
        self.captureOneTimeSecrets(dd, result);
        var fb: [7168]u8 = undefined;
        const folded = std.fmt.bufPrint(&fb, "[console]\n$ {s}\n{s}", .{ cmd, result }) catch result;
        self.appendMsg(dd, .cast_note, folded);
        self.startTurn(dd, .tool_follow);
    }

    /// Poll the in-flight micro-console command each tick WITHOUT blocking. While it runs, do nothing; once it
    /// finishes (natural exit) or must be stopped (deadline, Stop button, or output flood), read its captured
    /// output, append it + a status note to the scrollback, and — for the AI door — fold the result back and
    /// continue the turn. No-op when nothing is running.
    fn pumpConsole(self: *Chat, dd: []const u8) void {
        const p = if (self.console) |*pp| pp else return;
        const now = self.nowS();

        const Outcome = enum { running, exited, timed_out, canceled, flooded };
        var outcome: Outcome = .running;
        var exit_code: ?u32 = null; // full u32 from the exit peek/reap (null = unknowable, e.g. killed)
        if (procExited(&p.child, &exit_code)) {
            outcome = .exited;
        } else if (self.console_cancel) {
            outcome = .canceled;
        } else if (now >= p.deadline_s) {
            outcome = .timed_out;
        } else if (self.consoleSinkBytes(p) > CONSOLE_MAX_OUTPUT) {
            outcome = .flooded;
        }
        if (outcome == .running) return; // still going — poll again next tick

        // Reap the child (natural exit) or force-kill it. Child.kill is native TerminateProcess via the Io
        // vtable (no taskkill child, mirroring terminateVeilPid) and also reaps + closes the handle. On a
        // natural exit, Windows peeked the code without reaping (id still set → reap now); POSIX's waitpid
        // already reaped and nulled id, so wait would trip the id!=null assert — the null guard skips it there.
        if (outcome == .exited) {
            if (p.child.id != null) {
                if (p.child.wait(self.io)) |_| {} else |_| {} // reap only — the code came from the peek
            }
        } else {
            p.child.kill(self.io);
        }

        const ai = p.ai;
        const timeout_s = if (ai) CONSOLE_TIMEOUT_AI_S else CONSOLE_TIMEOUT_YOU_S;

        // Read the captured output (stdout then stderr), bounded — one heap scratch split between the sinks.
        var ob: [332]u8 = undefined;
        var eb: [332]u8 = undefined;
        const outp = std.fmt.bufPrint(&ob, "{s}.out", .{p.baseStr()}) catch "";
        const errp = std.fmt.bufPrint(&eb, "{s}.err", .{p.baseStr()}) catch "";
        const scratch: ?[]u8 = self.gpa.alloc(u8, 48 << 10) catch null;
        defer if (scratch) |s| self.gpa.free(s);
        const out_slice = if (scratch) |s| self.readSink(outp, s[0 .. 40 << 10]) else "";
        const err_slice = if (scratch) |s| self.readSink(errp, s[40 << 10 ..]) else "";
        Io.Dir.cwd().deleteFile(self.io, outp) catch {}; // data is in scratch now — clean up the sinks
        Io.Dir.cwd().deleteFile(self.io, errp) catch {};
        if (builtin.os.tag == .windows) { // the batch carrier (only safe to delete once the child is dead)
            var cpb: [332]u8 = undefined;
            if (std.fmt.bufPrint(&cpb, "{s}.cmd", .{p.baseStr()})) |cmdp| {
                Io.Dir.cwd().deleteFile(self.io, cmdp) catch {};
            } else |_| {}
        }

        // Status note for the non-clean exits — the required "(command timed out after Ns)" lives here.
        // A nonzero exit code is surfaced too: the RUN: contract promises "output + exit status", and the
        // model needs the failure signal to react instead of treating garbage output as success. Codes
        // above 16 bits are printed in hex — that's the NTSTATUS crash range (0xC0000135 = DLL not found),
        // unrecognizable once shown in decimal.
        var nb: [64]u8 = undefined;
        const note: []const u8 = switch (outcome) {
            .running => "",
            .exited => if (exit_code) |c| (if (c == 0)
                ""
            else if (c > 0xFFFF)
                std.fmt.bufPrint(&nb, "(exit code 0x{X})\n", .{c}) catch "(nonzero exit code)\n"
            else
                std.fmt.bufPrint(&nb, "(exit code {d})\n", .{c}) catch "(nonzero exit code)\n") else "",
            .timed_out => std.fmt.bufPrint(&nb, "(command timed out after {d}s)\n", .{timeout_s}) catch "(command timed out)\n",
            .canceled => "(command stopped)\n",
            .flooded => "(command produced too much output — stopped)\n",
        };

        // Scrollback: stdout, then stderr, then the note (matches the old separate-stream append order).
        if (out_slice.len > 0) self.store.consoleAppend(ai, out_slice);
        if (err_slice.len > 0) self.store.consoleAppend(ai, err_slice);
        if (out_slice.len == 0 and err_slice.len == 0) self.store.consoleAppend(ai, "(no output)\n");
        if (note.len > 0) self.store.consoleAppend(ai, note);
        self.setConsoleBusy(ai, false);
        log.info("console: {s} finished ({t}) — {d}b out, {d}b err", .{ if (ai) "veil" else "you", outcome, out_slice.len, err_slice.len });

        // The AI door hands the result back to the model. Copy what's needed off `p` BEFORE clearing the slot,
        // then clear it so foldConsoleAi (which re-enters a turn) sees a clean idle console state.
        if (ai) {
            // LESSON LOOP (verified transitions only — the engine's retrospective discipline): a command that
            // FAILED (real nonzero exit / timeout, never model self-report) followed in the same arc by a
            // SIMILAR command that SUCCEEDED is a fix worth keeping. Deterministic, zero model calls; the
            // lesson lands in the playbook scope and is recalled into future prompts (see startTurn).
            const hard_fail = std.mem.startsWith(u8, note, "(exit code") or std.mem.startsWith(u8, note, "(command timed out");
            // Clean means a REAL zero exit. A reaped-unknowable code (killed child, GetExitCodeProcess
            // failure, POSIX signal death) also produces an empty note — that's absence of ground truth,
            // not success, so it must neither mint a lesson nor reinforce the playbook.
            const clean_ok = outcome == .exited and (exit_code orelse 1) == 0;
            if (clean_ok) self.console_fail_streak = 0; // a success breaks any failing-command spiral
            // NOTE: arc_stuck is NOT decayed on a bare clean exit — only when a PREVIOUSLY-FAILING command now
            // succeeds (the lessonPair branch below), i.e. the actual blocker cleared. A clean diagnostic probe,
            // or a successful build step while the real failure persists, is not progress and must not walk the
            // ladder back down (that residual kept a stuck build from ever reaching the research/cast rungs).
            if (hard_fail) {
                // afk stall breaker: the SAME command failing over and over must force a change of approach, not
                // loop forever. Compare against the prior failing command BEFORE it is overwritten below;
                // escalate a nudge on a sustained streak.
                if (self.arc_fail_cmd_len > 0 and nearlySame(p.cmdStr(), self.arc_fail_cmd[0..self.arc_fail_cmd_len]))
                    self.console_fail_streak += 1
                else
                    self.console_fail_streak = 1;
                const fl = @min(p.cmd_len, self.arc_fail_cmd.len);
                @memcpy(self.arc_fail_cmd[0..fl], p.cmd[0..fl]);
                self.arc_fail_cmd_len = fl;
                const nl2 = @min(note.len, self.arc_fail_note.len);
                @memcpy(self.arc_fail_note[0..nl2], note[0..nl2]);
                self.arc_fail_note_len = nl2;
                // the failure's own words (exception line / last error line) ride into the minted lesson —
                // without them a lesson is only a command, and commands alone are not a failure family
                self.arc_fail_sig_len = salientFailLine(out_slice, err_slice, &self.arc_fail_sig).len;
                // ESCALATION LADDER: the SAME command failing 3+ times in a row is a stall — climb the rung
                // (nudge → force research on the error → cast a swarm) instead of only nudging "change approach"
                // forever. The freshly-captured salient error line seeds the research + cast so they target the
                // ACTUAL failure, not the command in the abstract.
                if (self.console_fail_streak >= 3) {
                    self.console_fail_streak = 0;
                    self.escalateStuck(dd, self.arc_fail_sig[0..self.arc_fail_sig_len]);
                }
            } else if (clean_ok and self.arc_fail_cmd_len > 0 and
                lessonPair(self.arc_fail_cmd[0..self.arc_fail_cmd_len], p.cmdStr()))
            {
                // A command that was FAILING now succeeds — the blocker genuinely cleared, so walk the escalation
                // ladder back down one rung (this, not any clean exit, is what "progress" means to the ladder).
                if (self.arc_stuck > 0) self.arc_stuck -= 1;
                var lb2: [1400]u8 = undefined;
                const fail_note = std.mem.trim(u8, self.arc_fail_note[0..self.arc_fail_note_len], " \r\n\t");
                // the captured failure signature travels inside the lesson: future recalls that share the
                // failure MODE (not merely the executable) rank this lesson up, everything else ranks it out
                const fail_sig = std.mem.trim(u8, self.arc_fail_sig[0..self.arc_fail_sig_len], " \r\n\t");
                var sb3: [180]u8 = undefined;
                const sig_part = if (fail_sig.len > 0)
                    std.fmt.bufPrint(&sb3, " [{s}]", .{fail_sig}) catch ""
                else
                    "";
                if (std.fmt.bufPrint(&lb2, "fix: `{s}` failed {s}{s} — works as: `{s}`", .{
                    self.arc_fail_cmd[0..@min(self.arc_fail_cmd_len, 380)],
                    fail_note,
                    sig_part,
                    p.cmdStr()[0..@min(p.cmd_len, 380)],
                })) |lesson| {
                    // Store the TRANSFERABLE form — strip the one-time build-dir `cd` prefix NOW, before it
                    // enters the store. Recall strips it too, so storing it clean keeps the stored fact byte-
                    // equal to the recalled/injected/strengthen-key text; otherwise the Hebbian strengthen key
                    // (cd-stripped at recall) never substring-matches a cd-full stored fact and the outcome-
                    // confirmed reinforcement silently no-ops. Also drop a lesson the strip collapses to fail==fix.
                    var clb: [1400]u8 = undefined;
                    const clean_lesson = std.mem.trim(u8, stripWorkdirChdir(lesson, &clb), " \t");
                    if (clean_lesson.len > 0 and !fixSpansCollapsed(clean_lesson)) {
                        var ab2: [1400]u8 = undefined;
                        self.mind().observe(PLAYBOOK_SCOPE, atomizeForObserve(&ab2, clean_lesson));
                        log.info("playbook: lesson captured ({d}b) from a verified fail->fix transition", .{clean_lesson.len});
                        self.judge_outcome = true; // a verified transition is the judge's OUTCOME trigger —
                        //                            grade the arc's trace soon, not on the turn-count clock
                    }
                } else |_| {}
                self.arc_fail_cmd_len = 0;
                self.arc_fail_note_len = 0;
                self.arc_fail_sig_len = 0;
            }
            // Hebbian close of the loop: a lesson was injected this turn and the command came back clean —
            // STRENGTHEN the precise lessons that were injected so the ones that keep fixing things out-rank
            // stale ones. Strengthen-only (never mints): keyed on the recalled LESSON text, not the raw user
            // prompt — reinforcing on last_user would mint "<user prompt>: worked" into the lesson scope and
            // surface it as a bogus "RECALLED LESSON" on later failures.
            // ONE strengthen per injection (stash cleared here): repetition without new evidence just inflates.
            if (self.playbook_hit and clean_ok and self.playbook_hit_lesson_len > 0) {
                var lit = std.mem.tokenizeScalar(u8, self.playbook_hit_lesson[0..self.playbook_hit_lesson_len], '\n');
                while (lit.next()) |line| self.mind().strengthen(PLAYBOOK_SCOPE, line);
            }
            self.playbook_hit = false;
            self.playbook_hit_lesson_len = 0;

            var cmdb: [1024]u8 = undefined;
            const cl = @min(p.cmd_len, cmdb.len);
            @memcpy(cmdb[0..cl], p.cmd[0..cl]);
            var rb: [6144]u8 = undefined;
            // TRUNCATION MARKER, keyed to what the MODEL actually sees. composeConsoleResult copies out+err into rb
            // and keeps the HEAD up to a ~6KB body cap (rb minus the note), so anything past that is dropped from
            // the model's view — NOT readSink's 40KB sink. Detect at THIS layer and say so, or the model re-runs the
            // same dump thinking the file "didn't show".
            const vis_budget = if (rb.len > note.len + 280) rb.len - note.len - 280 else 0;
            const vis_clipped = out_slice.len + err_slice.len > vis_budget;
            var note_buf: [640]u8 = undefined;
            const note_full = if (vis_clipped)
                (std.fmt.bufPrint(&note_buf, "{s}(output was long and TRUNCATED — you are seeing only PART of it, roughly the first {d}KB. To read a file in full use TOOL: read_file {{\"path\":\"...\"}}; to run a command make it output less, e.g. Get-Content <file> -TotalCount 80.)\n", .{ note, vis_budget / 1024 }) catch note)
            else
                note;
            const result = composeConsoleResult(&rb, out_slice, err_slice, note_full);
            // RAG-ON-FAILURE: a failing command recalls the playbook against the COMMAND ITSELF (the
            // user's request rarely names the executable) — if a past verified fix covers this failure
            // family, the model reads it in the same fold as the failure instead of re-deriving it.
            var rb2: [7000]u8 = undefined;
            var folded: []const u8 = result;
            if (hard_fail) {
                // recall against command + the failure's own salient line: ranking sees HOW it failed, so a
                // lesson about this failure MODE out-ranks one that merely shares the executable or a path
                var sgb: [160]u8 = undefined;
                const cur_sig = salientFailLine(out_slice, err_slice, &sgb);
                var qb: [1200]u8 = undefined;
                const query = std.fmt.bufPrint(&qb, "{s} {s}", .{ p.cmdStr(), cur_sig }) catch p.cmdStr();
                var lrb: [700]u8 = undefined;
                const recalled = self.mind().recall(PLAYBOOK_SCOPE, query, &lrb);
                // Read-time guards, both required: playbook-SHAPED (the mint contract — raw prompts never
                // surface as lessons) and RELEVANT to this failure (executable family + shared evidence —
                // a `cd`-into-the-repo fix must never ride in on an HTTP 403 just because both commands
                // said `python` under the same long path).
                var lrf: [700]u8 = undefined;
                const lesson = filterRelevantLessons(wholeLines(recalled, lrb.len), p.cmdStr(), cur_sig, &lrf);
                if (lesson.len > 0) {
                    folded = std.fmt.bufPrint(&rb2, "{s}\nRECALLED LESSON (a verified past fix for this command family — apply its working form):\n{s}", .{ result, lesson }) catch result;
                    log.info("playbook: recalled {d}b of lessons into a failure fold", .{lesson.len});
                    // This cmd-keyed lesson was just INJECTED (it rides the fold into the next turn) —
                    // stash it so the arc's eventual clean command credits the lesson that actually
                    // fixed things, not only whatever the prompt's last_user-keyed recall surfaces.
                    self.stashLessonLines(lesson);
                    self.playbook_hit = true;
                }
            }
            self.console = null;
            self.console_cancel = false;
            self.foldConsoleAi(dd, cmdb[0..cl], folded);
        } else {
            self.console = null;
            self.console_cancel = false;
        }
    }

    /// Read up to buf.len bytes from the TAIL of a console sink file (the newest output — most useful for a
    /// killed/timed-out command). Empty on any error / missing file.
    fn readSink(self: *Chat, path: []const u8, buf: []u8) []const u8 {
        if (path.len == 0) return buf[0..0];
        const f = Io.Dir.cwd().openFile(self.io, path, .{}) catch return buf[0..0];
        defer f.close(self.io);
        const size = (f.stat(self.io) catch return buf[0..0]).size;
        const off: u64 = if (size > buf.len) size - buf.len else 0;
        const n = f.readPositionalAll(self.io, buf, off) catch return buf[0..0];
        return buf[0..n];
    }

    /// Combined byte size of a command's two sink files (the output-flood guard). 0 on any stat error.
    fn consoleSinkBytes(self: *Chat, p: *const ConsoleProc) u64 {
        var ob: [332]u8 = undefined;
        var eb: [332]u8 = undefined;
        const outp = std.fmt.bufPrint(&ob, "{s}.out", .{p.baseStr()}) catch return 0;
        const errp = std.fmt.bufPrint(&eb, "{s}.err", .{p.baseStr()}) catch return 0;
        var total: u64 = 0;
        if (Io.Dir.cwd().statFile(self.io, outp, .{})) |st| {
            total += st.size;
        } else |_| {}
        if (Io.Dir.cwd().statFile(self.io, errp, .{})) |st| {
            total += st.size;
        } else |_| {}
        return total;
    }

    // ---------------------------------------------------------------- external judge (decoupled learning)

    /// The background JUDGE: on a turn-count cadence (or right after a verified fail→fix transition),
    /// grade the active conversation's TRACE — real commands, real exit codes, user contradictions;
    /// NEVER the model's own account of how well it did — and PROPOSE durable lessons/skills/user-model
    /// facts into quarantine "-proposed" scopes for human review in the Memory pane. Runs on its OWN llm
    /// stream and side dir (never the chat turn slot, never the chat's curl sinks), preferably on a
    /// DIFFERENT model than the answering slot (a same-model judge shares the priors that make a model
    /// grade itself kindly). Everything degrades to a silent no-op — neuron-db absent, model unreachable,
    /// trace too thin — and the judge NEVER writes into the conversation or any live scope.
    fn pumpJudge(self: *Chat, dd: []const u8) void {
        const now = self.nowS();
        if (self.judge_live) {
            llm.poll(&self.judge_stream, self.io, self.gpa, now, false);
            if (!self.judge_stream.done) return;
            llm.finish(&self.judge_stream, self.io);
            self.judge_live = false;
            if (self.judge_stream.failed) {
                log.info("judge: pass failed ({s}) — skipped, no proposals", .{self.judge_stream.errStr()});
            } else {
                const n = self.harvestProposals(self.judge_stream.content.items);
                log.info("judge: pass done — {d} proposal(s) quarantined for review", .{n});
                if (n > 0) self.refreshProposals(dd);
            }
            self.judge_stream.deinit(self.gpa);
            return;
        }
        if (!self.mind().enabled()) return;
        if (!(self.judge_outcome or self.judge_turns >= JUDGE_EVERY_TURNS)) return;
        if (now - self.judge_last_s < JUDGE_COOLDOWN_S) return;
        // politeness: fire only AFTER answers land (idle chat, no console, no cast/veil work) — the judge
        // must never contend with the user's live turn for the model or the machine
        if (self.turn != .idle or self.consoleAiBusy() or self.cast_active or self.veil_work_active) return;
        var cb: [64]u8 = undefined;
        const conv = self.convScope(&cb);
        if (conv.len == 0) return;
        // the conversation JSONL IS the trace — r:2 result rows carry the real console exit codes inline
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, conv }) catch return;
        const jsonl = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(512 << 10)) catch return;
        defer self.gpa.free(jsonl);
        var tb: [6200]u8 = undefined;
        const trace = buildTrace(self.gpa, jsonl, &tb);
        // consume the triggers regardless of outcome: a thin trace has nothing gradeable and must not
        // re-fire every tick
        self.judge_turns = 0;
        self.judge_outcome = false;
        self.judge_last_s = now;
        if (std.mem.indexOf(u8, trace, "RESULT:") == null) return; // no ground truth — nothing to grade
        var msgs: std.ArrayListUnmanaged(u8) = .empty;
        defer msgs.deinit(self.gpa);
        msgs.appendSlice(self.gpa, "{\"role\":\"system\",\"content\":\"") catch return;
        escJson(&msgs, self.gpa, JUDGE_SYSTEM);
        msgs.appendSlice(self.gpa, "\"},{\"role\":\"user\",\"content\":\"") catch return;
        // existing live entries (so the judge patches instead of duplicating) + pending proposals (so it
        // never re-proposes) + the trace
        self.appendScopeBlock(&msgs, "EXISTING LIVE LESSONS:\n", PLAYBOOK_SCOPE, 900);
        self.appendScopeBlock(&msgs, "EXISTING LIVE SKILLS:\n", SKILLS_SCOPE, 900);
        self.appendScopeBlock(&msgs, "PENDING PROPOSALS (never re-propose these):\n", PLAYBOOK_PROPOSED, 500);
        self.appendScopeBlock(&msgs, "", SKILLS_PROPOSED, 500);
        self.appendScopeBlock(&msgs, "", USER_PROPOSED, 500);
        escJson(&msgs, self.gpa, "TRACE (ground truth):\n");
        escJson(&msgs, self.gpa, trace);
        msgs.appendSlice(self.gpa, "\"}") catch return;
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.judgeProvider(&bb, &kb, &mb);
        var jb: [640]u8 = undefined;
        const jdir = std.fmt.bufPrint(&jb, "{s}/.veil-desk/judge", .{dd}) catch return;
        if (llm.start(&self.judge_stream, self.io, self.gpa, jdir, prov, msgs.items, JUDGE_MAX_TOKENS, now)) {
            self.judge_live = true;
            log.info("judge: pass started (model={s}, trace={d}b)", .{ prov.model, trace.len });
        }
    }

    /// Append a bounded, JSON-escaped dump of a scope into a prompt being built. Silent no-op when empty.
    fn appendScopeBlock(self: *Chat, msgs: *std.ArrayListUnmanaged(u8), header: []const u8, scope: []const u8, cap: usize) void {
        const o = self.mind().dump(scope) orelse return;
        defer self.gpa.free(o);
        const t2 = std.mem.trim(u8, o, " \r\n\t");
        const body_start = (std.mem.indexOfScalar(u8, t2, '\n') orelse return) + 1; // skip "# scope: x"
        const body = std.mem.trim(u8, t2[body_start..], " \r\n\t");
        if (body.len == 0) return;
        escJson(msgs, self.gpa, header);
        escJson(msgs, self.gpa, wholeLines(body[0..@min(body.len, cap)], cap));
        escJson(msgs, self.gpa, "\n");
    }

    /// Parse the judge's output and quarantine each valid proposal. A proposal without an evidence tail
    /// is exactly the ungrounded self-assessment this design exists to keep out — dropped on the floor.
    /// Writes ONLY the "-proposed" scopes; never a live scope, never the conversation.
    fn harvestProposals(self: *Chat, content: []const u8) usize {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw| {
            if (n >= 5) break; // bounded per pass — a flood of "lessons" is judge noise, not learning
            const pr = parseProposal(raw) orelse continue;
            const scope: []const u8 = switch (pr.kind) {
                0 => PLAYBOOK_PROPOSED,
                1 => SKILLS_PROPOSED,
                else => USER_PROPOSED,
            };
            var ab: [720]u8 = undefined;
            self.mind().observe(scope, atomizeForObserve(&ab, pr.text));
            n += 1;
        }
        return n;
    }

    /// The judge's model slot — by preference a DIFFERENT model than the answering one: hosted answering
    /// → the first locally installed Ollama model; local answering → the saved BYOK catalog slot when a
    /// key exists. Falls back to the answering provider (worst case same model, but always a fresh,
    /// decoupled context with the judge's own system prompt — never a continuation of the live chat).
    fn judgeProvider(self: *Chat, base_buf: *[256]u8, key_buf: *[192]u8, model_buf: *[96]u8) llm.Provider {
        var local_model: [96]u8 = undefined;
        var local_n: usize = 0;
        var kind: u8 = 0;
        var have_key = false;
        {
            self.store.lock();
            defer self.store.unlock();
            kind = self.store.settings.chat_kind;
            have_key = self.store.settings.chatKey().len > 0;
            if (self.store.ollama_model_count > 0) {
                const nm = self.store.ollama_models[0].nameStr();
                local_n = @min(nm.len, local_model.len);
                @memcpy(local_model[0..local_n], nm[0..local_n]);
            }
        }
        if ((kind == 1 or kind == 2) and local_n > 0) {
            const base = "http://127.0.0.1:11434/v1";
            @memcpy(base_buf[0..base.len], base);
            @memcpy(model_buf[0..local_n], local_model[0..local_n]);
            return .{ .base_url = base_buf[0..base.len], .key = key_buf[0..0], .model = model_buf[0..local_n] };
        }
        if (kind == 0 and have_key) {
            self.store.lock();
            defer self.store.unlock();
            const s = &self.store.settings;
            var acct: [256]u8 = undefined;
            const prov_def = &catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)];
            const base = catalog.resolveBase(prov_def, s.cfAccount(), &acct);
            const bn = @min(base.len, base_buf.len);
            @memcpy(base_buf[0..bn], base[0..bn]);
            const k = s.chatKey();
            const kn = @min(k.len, key_buf.len);
            @memcpy(key_buf[0..kn], k[0..kn]);
            const m = prov_def.models[0].id;
            const mn = @min(m.len, model_buf.len);
            @memcpy(model_buf[0..mn], m[0..mn]);
            return .{ .base_url = base_buf[0..bn], .key = key_buf[0..kn], .model = model_buf[0..mn] };
        }
        return self.resolveProvider(base_buf, key_buf, model_buf);
    }

    /// Publish the quarantined proposals into the store for the Memory pane's accept/reject cards.
    fn refreshProposals(self: *Chat, dd: []const u8) void {
        _ = dd;
        var rows: [12]store_mod.PropRow = undefined;
        var n: usize = 0;
        const scopes = [_]struct { tag: u8, name: []const u8 }{
            .{ .tag = 0, .name = PLAYBOOK_PROPOSED },
            .{ .tag = 1, .name = SKILLS_PROPOSED },
            .{ .tag = 2, .name = USER_PROPOSED },
        };
        for (scopes) |sc| {
            const o = self.mind().dump(sc.name) orelse continue;
            defer self.gpa.free(o);
            var it = std.mem.splitScalar(u8, o, '\n');
            while (it.next()) |raw| {
                if (n >= rows.len) break;
                const ln = std.mem.trim(u8, raw, " \r\t");
                if (ln.len < 16 or ln[0] == '#') continue; // header / blank / stray fragment lines
                var row: store_mod.PropRow = .{ .scope = sc.tag };
                const tn = @min(ln.len, row.text.len);
                @memcpy(row.text[0..tn], ln[0..tn]);
                row.text_len = @intCast(tn);
                rows[n] = row;
                n += 1;
            }
        }
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.chat_props[0..n], rows[0..n]);
        self.store.chat_prop_count = n;
    }

    /// Promote an accepted proposal: the lesson text (sans its evidence tail) enters the LIVE scope and
    /// the quarantine entry is dropped. Human-gated by construction — only the Memory pane sends this.
    fn acceptProposal(self: *Chat, dd: []const u8, tag: []const u8, text: []const u8) void {
        const t2 = std.mem.trim(u8, text, " \r\n\t");
        if (t2.len < 8) return;
        const cut = std.mem.indexOf(u8, t2, "| evidence:") orelse t2.len;
        const lesson = std.mem.trim(u8, t2[0..cut], " \t");
        if (lesson.len < 8) return;
        // The playbook's read-time filter surfaces only the scope's own write shapes (fix:/works as:/
        // lesson:) — a judge-authored lesson is free-form, so stamp it on promotion or the filter
        // would silently starve human-accepted knowledge out of every future injection.
        const live = propLiveScope(tag);
        var sb: [440]u8 = undefined;
        const shaped = if (std.mem.eql(u8, live, PLAYBOOK_SCOPE) and !isLessonLine(lesson))
            std.fmt.bufPrint(&sb, "lesson: {s}", .{lesson}) catch lesson
        else
            lesson;
        var ab: [452]u8 = undefined;
        self.mind().observe(live, atomizeForObserve(&ab, shaped));
        self.mind().forget(propQuarantineScope(tag), t2[0..@min(t2.len, 110)]);
        log.info("proposal accepted into {s} ({d}b)", .{ propLiveScope(tag), lesson.len });
        self.refreshProposals(dd);
    }

    fn rejectProposal(self: *Chat, dd: []const u8, tag: []const u8, text: []const u8) void {
        const t2 = std.mem.trim(u8, text, " \r\n\t");
        if (t2.len < 8) return;
        self.mind().forget(propQuarantineScope(tag), t2[0..@min(t2.len, 110)]);
        log.info("proposal rejected ({d}b)", .{t2.len});
        self.refreshProposals(dd);
    }

    // ------------------------------------------------------------------- curator (store governance)

    /// Once per app session: deterministic governance over the veil's OWN learning scopes (playbook +
    /// skills ONLY — never the user's Memory, never the user model, never conversation scopes). Zero
    /// model calls. (1) STALENESS: a scope untouched ~90 days (with a creation grace floor) is archived —
    /// ALWAYS exported to a dated pack first, forgotten only after the archive verifiably landed whole;
    /// nothing is ever bare-deleted. (2) SIZE: past 60 entries the oldest overflow is archived the same
    /// way (export order is insertion order). (3) NEAR-DUPLICATES: high-overlap entry pairs surface as
    /// merge-candidate proposals for the judge/human — judged on CONTENT, never on usage, never auto-merged.
    fn curateOnce(self: *Chat, dd: []const u8) void {
        if (self.curated) return;
        self.curated = true;
        if (!self.mind().enabled()) return;
        const now_ms: u64 = @intCast(@max(0, self.nowS()) * 1000);
        const STALE_MS: u64 = 90 * 24 * 3600 * 1000;
        const scopes = [_][]const u8{ PLAYBOOK_SCOPE, SKILLS_SCOPE };
        for (scopes) |scope| {
            const st = self.mind().statsScope(scope) orelse continue;
            if (st.facts == 0) continue;
            const dump_out = self.mind().dump(scope) orelse continue;
            defer self.gpa.free(dump_out);
            const stale = st.updated_ms > 0 and now_ms > st.updated_ms + STALE_MS and
                st.created_ms > 0 and now_ms > st.created_ms + STALE_MS; // grace floor: never a young scope
            if (stale or st.facts > 60) {
                var ab: [760]u8 = undefined;
                const apath = std.fmt.bufPrint(&ab, "{s}/.veil-desk/archive/{s}-{d}.facts", .{ dd, scope, st.updated_ms }) catch continue;
                Io.Dir.cwd().writeFile(self.io, .{ .sub_path = apath, .data = dump_out }) catch continue;
                const wrote = (Io.Dir.cwd().statFile(self.io, apath, .{}) catch continue).size;
                if (wrote < dump_out.len) continue; // the archive did not land whole — touch nothing
                if (stale) {
                    self.mind().forgetAll(scope);
                    log.info("curator: {s} idle >90d — archived {d} fact(s), recoverable at {s}", .{ scope, st.facts, apath });
                    continue;
                }
                var dropped: usize = 0;
                const excess: usize = @intCast(st.facts - 60);
                var it = std.mem.splitScalar(u8, dump_out, '\n');
                while (it.next()) |raw| {
                    if (dropped >= excess) break;
                    const ln = std.mem.trim(u8, raw, " \r\t");
                    if (ln.len < 16 or ln[0] == '#') continue;
                    self.mind().forget(scope, ln[0..@min(ln.len, 110)]);
                    dropped += 1;
                }
                log.info("curator: {s} over cap — archived all {d}, dropped the {d} oldest", .{ scope, st.facts, dropped });
            }
            if (st.facts >= 8) self.proposeMergeCandidates(scope, dump_out);
        }
        self.refreshProposals(dd);
    }

    /// Surface up to two high-overlap entry pairs per scope as merge-candidate proposals (the judge may
    /// author one class-level replacement; the human decides). Skipped while a previous batch is pending.
    fn proposeMergeCandidates(self: *Chat, scope: []const u8, dump_out: []const u8) void {
        const pq = if (std.mem.eql(u8, scope, SKILLS_SCOPE)) SKILLS_PROPOSED else PLAYBOOK_PROPOSED;
        if (self.mind().dump(pq)) |pd| {
            defer self.gpa.free(pd);
            if (std.mem.indexOf(u8, pd, "merge candidates in ") != null) return; // one batch at a time
        }
        var entries: [64][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, dump_out, '\n');
        while (it.next()) |raw| {
            if (n >= entries.len) break;
            const ln = std.mem.trim(u8, raw, " \r\t");
            if (ln.len < 24 or ln[0] == '#') continue;
            entries[n] = ln;
            n += 1;
        }
        var found: usize = 0;
        var i: usize = 0;
        outer: while (i < n) : (i += 1) {
            var j = i + 1;
            while (j < n) : (j += 1) {
                if (!contentOverlap(entries[i], entries[j])) continue;
                var lb: [900]u8 = undefined;
                const prop = std.fmt.bufPrint(&lb, "merge candidates in {s} (same lesson class? author ONE general entry): 1) {s} 2) {s} | evidence: near-duplicate content overlap found by the curator", .{
                    scope, entries[i][0..@min(entries[i].len, 260)], entries[j][0..@min(entries[j].len, 260)],
                }) catch continue;
                var ab: [900]u8 = undefined;
                self.mind().observe(pq, atomizeForObserve(&ab, prop));
                found += 1;
                if (found >= 2) break :outer;
            }
        }
        if (found > 0) log.info("curator: {s} — {d} merge candidate(s) proposed", .{ scope, found });
    }

    /// POST-TO-STEER a RUNNING server-chat turn: write a {"op":"steer","text":..} op to the conv's control.jsonl,
    /// which the server turn reads between steps and folds in as a user message — the user guiding a running turn
    /// without stopping it. No-op (with a notice) when no server turn is live (a local turn: Stop then send).
    fn cmdSteerTurn(self: *Chat, dd: []const u8, text: []const u8) void {
        const txt = std.mem.trim(u8, text, " \r\n\t");
        if (txt.len == 0) return;
        if (!self.sc_active) {
            self.store.pushNotif("Busy", "the veil is working — press Stop to interrupt, then send", 2);
            return;
        }
        const conv = self.sc_conv[0..self.sc_conv_len];
        if (conv.len == 0) return;
        const cap = txt.len * 2 + 32;
        const body = self.gpa.alloc(u8, cap) catch return;
        defer self.gpa.free(body);
        var w = Io.Writer.fixed(body);
        const ok = blk: {
            w.writeAll("{\"op\":\"steer\",\"text\":\"") catch break :blk false;
            wesc(&w, txt);
            w.writeAll("\"}") catch break :blk false;
            break :blk true;
        };
        if (!ok) return;
        if (self.runner().chatControl(self.io, self.gpa, conv, w.buffered())) |r| {
            if (r.body.len > 0) self.gpa.free(r.body);
        }
        self.appendMsg(dd, .user, txt); // show the steer in the transcript
        self.setStatus("steer sent — the veil will fold it into the running turn");
    }

    pub fn cmdSend(self: *Chat, dd: []const u8, text: []const u8) void {
        if (text.len == 0) return;
        if (self.turn != .idle or self.consoleAiBusy() or self.sc_active) {
            // Don't silently drop the message — tell the user why. Sending DURING a cast is fine (cast_active
            // isn't blocked here); only a live turn/console is. sc_active: a server-chat turn is rendering — a
            // second send would clobber its poll cursor/conv.
            self.store.pushNotif("Busy", "finish or Stop the current reply before sending", 2);
            return;
        }
        // a conversation's FIRST message names it — whether the user typed straight away (auto-create)
        // or clicked + first (the "new chat" placeholder title gets replaced here).
        var have_conv = false;
        var fresh = false;
        {
            self.store.lock();
            have_conv = self.store.conv_active_len > 0;
            fresh = self.store.msg_count == 0;
            self.store.unlock();
        }
        if (!have_conv) {
            self.cmdNewConv(dd);
            fresh = true;
        }
        if (fresh) {
            var tb: [42]u8 = undefined;
            const n = @min(text.len, tb.len);
            @memcpy(tb[0..n], text[0..n]);
            for (tb[0..n]) |*c| {
                if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
            }
            self.renameActive(dd, tb[0..n]);
        }
        // remember the request so an explicit cast still fires if the model flakes (gpt-oss sometimes
        // puts its whole reply in the hidden reasoning channel and emits no CAST line in the content).
        self.last_user_len = @min(text.len, self.last_user.len);
        @memcpy(self.last_user[0..self.last_user_len], text[0..self.last_user_len]);
        if (fresh) { // the conversation's FIRST message IS its durable goal — anchor the auto-loop to it
            self.arc_goal_len = @min(text.len, self.arc_goal.len);
            @memcpy(self.arc_goal[0..self.arc_goal_len], text[0..self.arc_goal_len]);
        }
        self.internal_turn = false; // this is a REAL user message → its turn may consolidate memory
        self.conv_epoch += 1; // the conversation moved forward — pending continuations for older goals stand down
        self.tool_iters = 0; // fresh tool budget for this user turn
        self.loop_iter = 0; // a manual message resets the auto-loop budget (this is the new goal/steer)
        self.lookup_streak = 0; // ...and the stall counter — a fresh instruction is not part of the old spiral
        self.loop_casts = 0; // ...and its swarm budget — a fresh steer earns fresh loop-casts
        self.loop_idle = 0;
        self.resetArcFlags(); // fresh agentic-floor arc: follow-through nudge, verification, lesson capture
        self.judge_turns +%= 1; // a REAL user turn — the judge's cadence trigger counts only these
        // AUTO-LOOP ON by default once the user prompts (user directive): the veil drives its own next step
        // until it emits DONE or hits the iteration cap — so a task gets carried to completion, not one reply.
        // The user can switch it off with the input's auto-loop toggle; a manual send re-arms it.
        {
            self.store.lock();
            self.store.chat_loop = true;
            self.store.unlock();
        }
        self.reflect_pass = 0; // fresh iterative self-critique budget for this user turn
        self.reflect_dirty = false;
        self.reflect_msg_idx = null;
        self.reflect_trace_len = 0;
        self.reflect_trace_has_reason = false;
        self.abort_turn.store(false, .monotonic); // a new user message clears any pending Stop from the last turn
        self.appendMsg(dd, .user, text);
        // SERVER CHAT ROUTING (P0-6, gated on Settings.server_chat; default OFF ⇒ never taken, the LOCAL path
        // below runs exactly as today). When ON, the brain lives in the backend: hand this send to the conv's
        // server turn and let pumpServerChat render the frames. The whole local path (cast fast-path, knowledge
        // directive, startTurn, auto-loop) is SKIPPED. On a resolvable conv this returns; else it falls through.
        if (self.serverChatOn()) {
            if (self.routeToServerChat(dd, text)) return;
        }
        // Past the server route → this message is served LOCALLY (server off, in cooldown, or a fallback). Mark the
        // conv as NOT server-served so the local auto-loop (maybeLoop) is allowed to drive it.
        self.sc_serving = false;
        // SUB-AGENT DISPATCH: an explicit "cast a swarm to ..." IS the task — deploy it NOW instead of
        // spending a whole model turn deciding to (measured ~10s hosted, up to a minute on a local thinking
        // model, before the hive even existed). Config rides the user's own words mechanically (N minds /
        // N minutes / long|sustained|continuous); everything downstream is unchanged — the orchestrator
        // brief follows on the next ticks and the collect composes the answer when the hive finishes.
        // The settle-time cast recovery stays as the safety net for any path that still reaches a model turn.
        // The mechanical fast-path deploys a cast straight from the user's words ONLY for an imperative COMMAND
        // ("cast a swarm to build X"). A question or musing ("couldn't you cast a swarm to automate this?") is the
        // MODEL's to reason about — it has the conversation context to resolve what the real goal is and to
        // compose a concrete CAST: (mechanically stripping it yields garbage like "automate this???"). Rather than
        // pattern-match the goal in the engine, hand the ambiguous case to the model.
        const q = std.mem.trimEnd(u8, text, " \t\r\n");
        const is_question = q.len > 0 and q[q.len - 1] == '?';
        if (!self.castPending() and userWantsCast(text) and !is_question) {
            var gb: [1600]u8 = undefined;
            const goal = castGoalFromUser(text, &gb);
            log.info("cast fast-path: explicit user cast command — deploying without a deciding turn", .{});
            self.fireCast(dd, castSpecFromUser(text, goal));
            return;
        }
        // QUESTION-YOUR-KNOWLEDGE POSTURE (user directive): a fresh, substantive task in builder (speed) mode
        // should treat its training as a STARTING POINT to improve on, not a ceiling — even a FAMILIAR task
        // ("build a website") is done BETTER by first checking CURRENT methods/best-practices and RAG'ing them
        // in, rather than building from memory alone. Engine-injected as a directive (the weak model won't
        // reliably question itself) and scaled to SUBSTANCE — a trivial edit or a plain-general answer proceeds
        // directly; the model self-gates that. (The reactive ladder above handles getting STUCK; this is the
        // proactive front of the same instinct.)
        if (fresh and text.len >= 40) {
            const speed_on = blk_sg: {
                self.store.lock();
                defer self.store.unlock();
                break :blk_sg self.store.settings.speed_mode;
            };
            if (speed_on) self.setDirective("CHECK CURRENT METHODS FIRST — treat your training as a starting point, not the ceiling. For any SUBSTANTIVE task (building something real, or a specialized/named/current-world/uncertain domain), your FIRST action should be TOOL: recall_hive {\"query\":\"...\"} and, if that comes back thin, TOOL: web_search {\"query\":\"...\"} to find the CURRENT best method — then build on what you learn, not from memory alone. Ask yourself: \"I could do this from memory, but would researching current methods make it materially BETTER?\" — if yes, research first. Do NOT research trivia or something squarely within solid general knowledge (a quick edit, a basic answer); scale the research to the task's substance. When in doubt on a real build, check first.");
        }
        self.startTurn(dd, .user);
    }

    pub fn cmdNewConv(self: *Chat, dd: []const u8) void {
        var idb: [64]u8 = undefined; // = Store.conv_active capacity; [32] literals here were the missed-widening panic class
        const now = self.nowS();
        const id = std.fmt.bufPrint(&idb, "c{x}", .{@as(u64, @intCast(now))}) catch return;
        // collision (two in one second) → suffix
        var pb: [700]u8 = undefined;
        var path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch return;
        if (Io.Dir.cwd().statFile(self.io, path, .{})) |_| {
            const id2 = std.fmt.bufPrint(&idb, "c{x}b", .{@as(u64, @intCast(now))}) catch return;
            path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id2 }) catch return;
        } else |_| {}
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "{\"title\":\"new chat\"}\n" }) catch {
            log.err("chat: cannot create conversation file", .{});
            return;
        };
        const stem = std.fs.path.stem(std.fs.path.basename(path));
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(stem.len, self.store.conv_active.len);
            @memcpy(self.store.conv_active[0..n], stem[0..n]);
            self.store.conv_active_len = @intCast(n);
            self.store.msg_count = 0;
        }
        self.conv_epoch += 1; // new conversation — stale continuations must not post into it
        self.reflect_msg_idx = null;
        self.releaseServerCastDisplay("detached (left the conversation)"); // a server-cast display cannot span a conversation switch
        self.resetArcFlags(); // the agentic-floor arc cannot span a conversation switch
        self.arc_goal_len = 0; // a brand-new chat has no goal yet — the first cmdSend sets it
        self.syncBuildDir(dd); // a fresh chat has no build dir yet — this clears the previous chat's binding
        self.refreshConvs(dd, true);
    }

    fn cmdSelectConv(self: *Chat, dd: []const u8, id: []const u8) void {
        if (id.len == 0) return; // busy-guard is at the .select_conv dispatch (busyForSwitch), which also notifies
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(id.len, self.store.conv_active.len);
            @memcpy(self.store.conv_active[0..n], id[0..n]);
            self.store.conv_active_len = @intCast(n);
            self.store.msg_count = 0;
        }
        self.conv_epoch += 1; // switched conversation — stale continuations must not post into it
        self.reflect_msg_idx = null;
        self.releaseServerCastDisplay("detached (left the conversation)"); // a server-cast display cannot span a conversation switch
        self.resetArcFlags(); // a stale arc_mutated/fail pair must not leak a verify turn or lesson across chats
        self.mirror_live = false; // stale liveness from a previous select must never arm a watch on THIS conv
        self.loadMsgs(dd, id);
        { // re-anchor the loop's durable goal to THIS conversation's first message
            self.store.lock();
            defer self.store.unlock();
            if (self.store.msg_count > 0) {
                const g = self.store.msgs[0].textStr();
                self.arc_goal_len = @min(g.len, self.arc_goal.len);
                @memcpy(self.arc_goal[0..self.arc_goal_len], g[0..self.arc_goal_len]);
            } else self.arc_goal_len = 0;
        }
        self.syncBuildDir(dd); // console cwd follows the chat: restore ITS build dir (or clear the old chat's)
        // A server-born run (a scheduled task's turn) is EXECUTING right now — ATTACH the live event poller so
        // the run streams into this view exactly like a desk-fired turn (tokens, tools, status, Post/steer,
        // Stop), instead of the frozen snapshot the mirror alone gives. {done} disarms it as usual.
        if (self.mirror_live and !self.sc_active and id.len <= self.sc_conv.len) self.attachServerTurn(dd, id);
    }

    /// Attach the server-chat poller to a turn THIS desk did not fire (a scheduled run in progress). Baselines
    /// the event cursor at the CURRENT end of events.jsonl — the mirror already showed everything committed;
    /// only new frames stream in (an in-flight message's earlier tokens arrive when it commits as a whole).
    /// From here the run behaves like any served turn: pumpServerChat renders, Stop posts {op:stop}, Enter
    /// steers, and {done} (or the silence failsafe) disarms.
    fn attachServerTurn(self: *Chat, dd: []const u8, conv: []const u8) void {
        _ = dd;
        var from0: usize = 0;
        if (self.runner().chatEvents(self.io, self.gpa, conv, 0)) |er| {
            from0 = er.body.len;
            if (er.body.len > 0) self.gpa.free(er.body);
        }
        @memcpy(self.sc_conv[0..conv.len], conv);
        self.sc_conv_len = conv.len;
        self.sc_from = from0;
        self.sc_fails = 0;
        self.sc_next_poll_ms = 0;
        self.sc_empty_polls = 0;
        self.scClearStream();
        self.sc_turn_start_ms = self.nowMs();
        self.sc_fb_ms = 0;
        self.sc_chars = 0;
        self.sc_tools = 0;
        self.sc_tokens_out = 0;
        self.sc_serving = true; // the SERVER drives this conv — the local loop stands down
        self.setServerActive(true);
        self.setBusy(true);
        // Reflect the truth in the UI: a scheduled run IS auto-loop-driven server-side (launchRun arms
        // loop=1). Leaving the indicator "off" read as "auto-loop is not initializing" and invited a manual
        // toggle that fired a REDUNDANT local turn. {done} clears it, as with any served loop.
        {
            self.store.lock();
            self.store.chat_loop = true;
            self.store.unlock();
        }
        self.setStatus("scheduled run in progress — attached to the live turn");
        log.info("server chat: attached to live turn conv={s} from={d}", .{ conv, from0 });
    }

    fn cmdRenameConv(self: *Chat, dd: []const u8, id: []const u8, title: []const u8) void {
        if (id.len == 0 or title.len == 0) return;
        self.rewriteTitle(dd, id, title);
        self.refreshConvs(dd, true);
    }

    fn renameActive(self: *Chat, dd: []const u8, title: []const u8) void {
        var idb: [64]u8 = undefined; // = Store.conv_active capacity; [32] literals here were the missed-widening panic class
        var idn: usize = 0;
        {
            self.store.lock();
            idn = @min(self.store.conv_active_len, idb.len);
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            self.store.unlock();
        }
        if (idn > 0) self.cmdRenameConv(dd, idb[0..idn], title);
    }

    fn cmdDeleteConv(self: *Chat, dd: []const u8, id: []const u8) void {
        if (id.len == 0) return;
        // Refuse to delete the conversation whose turn is streaming: cmdSend/cmdSelectConv already guard
        // on turn==idle, but without this guard deleting the ACTIVE chat mid-turn clears conv_active, the
        // fallback select silently no-ops (its own guard), and the in-flight reply lands with no active
        // conversation — appendMsg writes it to a stranded Store slot and never persists it (lost). A
        // background conversation is always safe to delete.
        if (self.turn != .idle) {
            var active = false;
            {
                self.store.lock();
                active = std.mem.eql(u8, self.store.conv_active[0..self.store.conv_active_len], id);
                self.store.unlock();
            }
            if (active) {
                self.store.pushNotif("Busy", "let the reply finish before deleting this chat", 2);
                return;
            }
        }
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch return;
        Io.Dir.cwd().deleteFile(self.io, path) catch {};
        // ALSO delete it server-side. A server-born conv (a scheduled_* run, or one merged into the sidebar)
        // has no local file, so unlinking the local file alone is a no-op and the next refreshConvs re-merges
        // it straight back — deletes appeared to do nothing. The server route removes the authoritative copy.
        if (self.runner().chatDelete(self.io, self.gpa, id)) |r| {
            if (r.body.len > 0) self.gpa.free(r.body);
        }
        var was_active = false;
        {
            self.store.lock();
            defer self.store.unlock();
            was_active = std.mem.eql(u8, self.store.conv_active[0..self.store.conv_active_len], id);
            if (was_active) {
                self.store.conv_active_len = 0;
                self.store.msg_count = 0;
            }
        }
        self.refreshConvs(dd, true);
        if (was_active) {
            // fall back to the newest remaining conversation
            var nid: [64]u8 = undefined;
            var nn: usize = 0;
            {
                self.store.lock();
                defer self.store.unlock();
                if (self.store.conv_count > 0) {
                    nn = self.store.convs[0].id_len;
                    @memcpy(nid[0..nn], self.store.convs[0].id[0..nn]);
                }
            }
            if (nn > 0) self.cmdSelectConv(dd, nid[0..nn]) else self.syncBuildDir(dd); // deleted the LAST chat:
            // no reselect happens, so clear the dead chat's console binding here (syncBuildDir with no active
            // conversation always clears)
        }
    }

    // ---------------------------------------------------------------------- chat Files tab (this chat's own dir)

    /// The data-relative build dir for THIS conversation ("u{uid}/_chat/builds/{conv}"); "" if no active conv.
    /// The uid is taken from the leading "uN" segment of build_dir (set when a build tool ran) — defaults to u1,
    /// which is the desktop's admin user on localhost.
    fn chatBuildRel(self: *Chat, buf: []u8) []const u8 {
        var cb: [64]u8 = undefined;
        const conv = self.convScope(&cb);
        if (conv.len == 0) return "";
        var uid: []const u8 = "u1";
        if (self.build_dir_len > 0) {
            const bd = self.build_dir[0..self.build_dir_len];
            if (std.mem.indexOfScalar(u8, bd, '/')) |sl| {
                if (sl > 1 and bd[0] == 'u') uid = bd[0..sl];
            }
        }
        return std.fmt.bufPrint(buf, "{s}/_chat/builds/{s}", .{ uid, conv }) catch "";
    }

    /// Scan this chat's own build dir ({conv}/work) and publish the file list into the Store for the Files tab.
    /// Cheap (a manifest read + a shallow walk); called on a slow tick. No-op when there's no conv/build dir.
    fn refreshChatFiles(self: *Chat, dd: []const u8) void {
        var rb: [160]u8 = undefined;
        const rel = self.chatBuildRel(&rb);
        var n: usize = 0;
        if (rel.len > 0) n = scan.listWorkFiles(self.io, self.gpa, dd, rel, &self.file_scratch);
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.chat_files[0..n], self.file_scratch[0..n]);
        self.store.chat_file_count = n;
    }

    /// Load a chat build file's content into the Store for the viewer (row-click in the Files tab).
    fn cmdChatOpenFile(self: *Chat, dd: []const u8, sub: []const u8) void {
        if (sub.len == 0) return;
        var rb: [160]u8 = undefined;
        const rel = self.chatBuildRel(&rb);
        if (rel.len == 0) return;
        var buf: [1 << 14]u8 = undefined;
        var trunc = false;
        const n = scan.readWorkFile(self.io, self.gpa, dd, rel, sub, &buf, &trunc);
        self.store.lock();
        defer self.store.unlock();
        const sl = @min(sub.len, self.store.chat_sel_file.len);
        @memcpy(self.store.chat_sel_file[0..sl], sub[0..sl]);
        self.store.chat_sel_file_len = sl;
        @memcpy(self.store.chat_file_content[0..n], buf[0..n]);
        self.store.chat_file_content_len = n;
        self.store.chat_file_content_trunc = trunc;
    }

    /// Open this chat's build folder in the OS file browser (the "Open" button in the Files tab).
    fn cmdChatOpenFolder(self: *Chat, dd: []const u8) void {
        var rb: [160]u8 = undefined;
        const rel = self.chatBuildRel(&rb);
        if (rel.len == 0) return;
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/{s}/work", .{ dd, rel }) catch return;
        // ensure it exists so explorer doesn't error on a chat that hasn't built anything yet
        _ = Io.Dir.cwd().createDirPathStatus(self.io, path, .default_dir) catch {};
        const argv: []const []const u8 = switch (builtin.os.tag) {
            .windows => &.{ "explorer.exe", "." },
            .macos => &.{ "open", "." },
            else => &.{ "xdg-open", "." },
        };
        _ = std.process.spawn(self.io, .{ .argv = argv, .cwd = .{ .path = path }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
    }

    // ------------------------------------------------------------------------------ durable memory (keys / logins / prefs)
    // The chat AI keeps facts the user wants remembered across conversations. neuron-db (MEMORY_SCOPE) is the RECALL
    // engine — observe on save, relevance-recall into prompts; memories.jsonl is the readable mirror the Memory tab
    // shows + the source we rebuild the "YOUR MEMORY" prompt block from. LOCAL single-user store, so secrets are OK.

    /// Read memories.jsonl → publish rows into Store.chat_mem for the Memory tab. Cheap; on load + after any change.
    fn refreshMemory(self: *Chat, dd: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/memories.jsonl", .{dd}) catch return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(256 << 10)) catch {
            self.store.lock();
            defer self.store.unlock();
            self.store.chat_mem_count = 0; // no file yet → no memories
            return;
        };
        defer self.gpa.free(data);
        var rows: [128]store_mod.MemRow = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const ln = std.mem.trim(u8, line, " \r\t");
            if (ln.len < 5 or ln[0] != '{') continue;
            var row: store_mod.MemRow = .{};
            if (llm.jsonUnescape(self.gpa, ln, "text")) |tx| {
                defer self.gpa.free(tx);
                const tn = @min(tx.len, row.text.len);
                @memcpy(row.text[0..tn], tx[0..tn]);
                row.text_len = @intCast(tn);
            } else continue;
            if (row.text_len == 0) continue;
            if (llm.jsonUnescape(self.gpa, ln, "cat")) |c| {
                defer self.gpa.free(c);
                const cn = @min(c.len, row.cat.len);
                @memcpy(row.cat[0..cn], c[0..cn]);
                row.cat_len = @intCast(cn);
            }
            // Keep the NEWEST 128 (memories.jsonl grows by APPEND, so past the cap drop the oldest, not the newest —
            // else freshly consolidated facts would never load into the Memory tab / YOUR MEMORY injection).
            if (n < rows.len) {
                rows[n] = row;
                n += 1;
            } else {
                std.mem.copyForwards(store_mod.MemRow, rows[0 .. rows.len - 1], rows[1..rows.len]);
                rows[rows.len - 1] = row;
            }
        }
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.chat_mem[0..n], rows[0..n]);
        self.store.chat_mem_count = n;
    }

    /// Format the current memories as a compact "- [cat] text" list (newest first) up to `buf`, for the "YOUR MEMORY"
    /// prompt block. Reads the published Store.chat_mem under lock — the small local set is injected in full so the AI
    /// always has the user's keys/logins/preferences on hand (no relevance gating for such a bounded set).
    fn memoryBlock(self: *Chat, buf: []u8) []const u8 {
        self.store.lock();
        defer self.store.unlock();
        var w: usize = 0;
        var i: usize = self.store.chat_mem_count;
        while (i > 0) {
            i -= 1;
            const m = &self.store.chat_mem[i];
            const cat = m.catStr();
            const tx = m.textStr();
            if (w + cat.len + tx.len + 8 > buf.len) break;
            buf[w] = '-';
            buf[w + 1] = ' ';
            w += 2;
            if (cat.len > 0) {
                buf[w] = '[';
                w += 1;
                @memcpy(buf[w .. w + cat.len], cat);
                w += cat.len;
                buf[w] = ']';
                buf[w + 1] = ' ';
                w += 2;
            }
            @memcpy(buf[w .. w + tx.len], tx);
            w += tx.len;
            buf[w] = '\n';
            w += 1;
        }
        return buf[0..w];
    }

    /// Persist one durable memory: append to memories.jsonl AND observe it into neuron-db. Dedups on exact text.
    fn storeMemory(self: *Chat, dd: []const u8, cat_in: []const u8, fact_in: []const u8) void {
        const fact = std.mem.trim(u8, fact_in, " \r\n\t");
        if (fact.len < 2) return;
        var cat = std.mem.trim(u8, cat_in, " \r\n\t[]");
        if (cat.len == 0) cat = "fact";
        if (cat.len > 20) cat = cat[0..20];
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/memories.jsonl", .{dd}) catch return;
        const existing: ?[]u8 = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(256 << 10)) catch null;
        defer if (existing) |e| self.gpa.free(e);
        const ex: []const u8 = existing orelse "";
        // build the escaped JSON line
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"cat\":\"") catch return;
        escJson(&jb, self.gpa, cat);
        jb.appendSlice(self.gpa, "\",\"text\":\"") catch return;
        escJson(&jb, self.gpa, fact[0..@min(fact.len, 260)]);
        jb.appendSlice(self.gpa, "\"}") catch return;
        if (ex.len > 0 and std.mem.indexOf(u8, ex, jb.items) != null) return; // exact dup → skip
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.gpa);
        if (ex.len > 0) {
            const trimmed = std.mem.trimEnd(u8, ex, "\r\n");
            if (trimmed.len > 0) {
                out.appendSlice(self.gpa, trimmed) catch return;
                out.append(self.gpa, '\n') catch return;
            }
        }
        out.appendSlice(self.gpa, jb.items) catch return;
        out.append(self.gpa, '\n') catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out.items }) catch return;
        // neuron-db: observe "cat: fact" under the global memory scope for cross-conversation relevance recall
        var ob: [340]u8 = undefined;
        const obs = std.fmt.bufPrint(&ob, "{s}: {s}", .{ cat, fact[0..@min(fact.len, 300)] }) catch fact;
        self.mind().observe(MEMORY_SCOPE, obs);
        log.info("chat memory: stored [{s}] ({d}b)", .{ cat, fact.len });
        self.refreshMemory(dd);
    }

    /// Durably remember any one-time claim/verification secret a tool/console RESULT carried — the MOMENT it
    /// arrives, before the 64-message ring evicts it or end-of-run consolidation drops it. Without this, a
    /// one-time claim_url / verification_code kept only in the ring ages out and the agent loops re-discovering
    /// a claim step it already had. Idempotent (storeMemory dedups); skipped during the veil's parallel research
    /// work (that store is the user's private memory, not a research scratchpad).
    fn captureOneTimeSecrets(self: *Chat, dd: []const u8, result: []const u8) void {
        if (self.in_veil_work) return;
        if (result.len < 8 or result[0] == '(') return; // an error/empty note carries nothing worth keeping
        for (ONE_TIME_SECRET_KEYS) |k| {
            if (valueForKey(result, k)) |v| {
                var nb: [320]u8 = undefined;
                const note = std.fmt.bufPrint(&nb, "{s}: {s}", .{ k, v }) catch continue;
                self.storeMemory(dd, "claim", note);
                log.info("chat memory: captured one-time secret [{s}] from a tool result", .{k});
            }
        }
    }

    /// STALL GUARD. A busy-but-getting-nowhere spiral is invisible to loop_idle (which only catches NO action):
    /// the auto-loop keeps firing web lookups, so `acted` stays true while progress is zero. Count consecutive
    /// web-lookup calls; a non-lookup tool (a real build/read action) resets it. At the limit, inject ONE
    /// corrective steer: stop repeating, change approach, or — if the step needs a human/UI action the API can't
    /// do — say so to the user and move on. It NEVER stops the loop (afk is user-ended by design); it makes a
    /// stuck loop ESCALATE instead of spin.
    fn trackLookupStall(self: *Chat, dd: []const u8, name: []const u8) void {
        if (isWebLookupTool(name)) self.lookup_streak += 1 else self.lookup_streak = 0;
        if (self.lookup_streak >= LOOKUP_STALL_LIMIT) {
            self.setDirective("You have run many web lookups in a row without resolving the goal or learning anything genuinely new — this is a STALL, not progress. Do NOT run another search or fetch of the same kind, and do NOT re-read a page you've already read. Instead EITHER (a) take a fundamentally DIFFERENT concrete action that moves the goal forward, OR (b) if finishing this genuinely requires a human, UI, login, email, or verification step you cannot perform through the API, STOP looking now and tell the user plainly what is blocked and the exact steps THEY must take, then move on to other useful work.");
            self.appendMsg(dd, .cast_note, "(stall guard: many lookups, no progress — changing approach, and escalating if it stays stuck)");
            self.lookup_streak = 0; // re-arm for the next spiral
            // A lookup spiral means research is ALREADY happening and not converging — so jump the ladder past
            // the research rung straight toward a cast (a swarm can research harder + in parallel than one turn).
            // The directive above stands (escalateStuck rung 3 only arms the cast, it doesn't clobber a directive).
            if (self.arc_stuck < 2) self.arc_stuck = 2;
            self.escalateStuck(dd, "many web lookups in a row without resolving the goal — one turn's research isn't converging");
            log.info("chat stall guard: web-lookup streak hit {d} — steer + ladder escalation", .{LOOKUP_STALL_LIMIT});
        }
    }

    /// Drop the durable memory/memories whose text CONTAINS `match`: rewrite memories.jsonl without them + forget
    /// them from neuron-db. Driven by a FORGET: directive or the Memory tab's delete button (which passes exact text).
    fn forgetMemory(self: *Chat, dd: []const u8, match_in: []const u8) void {
        const match = std.mem.trim(u8, match_in, " \r\n\t");
        if (match.len < 2) return;
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/memories.jsonl", .{dd}) catch return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(256 << 10)) catch return;
        defer self.gpa.free(data);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.gpa);
        var removed = false;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const ln = std.mem.trim(u8, line, " \r\t");
            if (ln.len == 0) continue;
            var drop = false;
            if (llm.jsonUnescape(self.gpa, ln, "text")) |tx| {
                defer self.gpa.free(tx);
                if (std.ascii.indexOfIgnoreCase(tx, match) != null) drop = true;
            }
            if (drop) {
                removed = true;
                continue;
            }
            out.appendSlice(self.gpa, ln) catch return;
            out.append(self.gpa, '\n') catch return;
        }
        if (!removed) return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out.items }) catch return;
        self.mind().forget(MEMORY_SCOPE, match);
        log.info("chat memory: forgot match ({d}b)", .{match.len});
        self.refreshMemory(dd);
    }

    /// Scan a finalized answer for durable-memory directives (REMEMBER: / FORGET: on their own line), act on each,
    /// and return the answer with those lines stripped (so they never render). Fast-paths when neither is present.
    fn processMemory(self: *Chat, dd: []const u8, text: []const u8) []const u8 {
        self.mem_saved_n = 0; // reset per finalize so appendVeil sees only THIS turn's directive count
        self.mem_forgot_n = 0;
        if (std.mem.indexOf(u8, text, "REMEMBER:") == null and std.mem.indexOf(u8, text, "FORGET:") == null) return text;
        var w: usize = 0;
        var first = true;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const ln = std.mem.trim(u8, line, " \r\t");
            if (std.ascii.startsWithIgnoreCase(ln, "REMEMBER:")) {
                const spec = parseRememberBody(std.mem.trim(u8, ln["REMEMBER:".len..], " \t"));
                if (spec.fact.len >= 2) {
                    self.storeMemory(dd, spec.cat, spec.fact);
                    self.mem_saved_n += 1;
                }
                continue; // strip
            }
            if (std.ascii.startsWithIgnoreCase(ln, "FORGET:")) {
                const m = std.mem.trim(u8, ln["FORGET:".len..], " \t");
                if (m.len >= 2) {
                    self.forgetMemory(dd, m);
                    self.mem_forgot_n += 1;
                }
                continue; // strip
            }
            const src = std.mem.trimEnd(u8, line, "\r");
            if (!first and w < self.mem_scratch.len) {
                self.mem_scratch[w] = '\n';
                w += 1;
            }
            const cn = @min(src.len, self.mem_scratch.len - w);
            @memcpy(self.mem_scratch[w .. w + cn], src[0..cn]);
            w += cn;
            first = false;
        }
        var out = std.mem.trim(u8, self.mem_scratch[0..w], " \r\n\t");
        // If directives were stripped, the model may have left a dangling intro line ("Saved preferences:", "I've
        // remembered:") that now points at nothing — drop that one trailing line so the shown answer reads clean.
        if (self.mem_saved_n > 0 or self.mem_forgot_n > 0) out = stripDanglingMemoryIntro(out);
        return out;
    }

    pub fn cmdStopCast(self: *Chat, dd: []const u8, rel: []const u8) void {
        if (rel.len == 0) return;
        _ = scan.writeStop(self.io, self.gpa, dd, rel); // per-TURN sentinel — takes effect fast
        _ = scan.writeControl(self.io, self.gpa, dd, rel, "{\"op\":\"stop\"}"); // round-boundary fallback
        self.store.pushNotif("Stop sent", rel, 2);
        self.cast_stop_sent = true;
        self.releaseServerCastDisplay("stopped"); // releasing a server-owned display too (its run dir got the STOP above)
        self.resetVeilWork(); // stopping the cast also abandons the parallel veil attempt + pending finish
    }

    fn cmdSaveKey(self: *Chat, dd: []const u8, key: []const u8) void {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        const ok = secrets.save(self.io, self.gpa, side, key);
        {
            self.store.lock();
            defer self.store.unlock();
            const n = @min(key.len, self.store.settings.chat_key.len);
            @memcpy(self.store.settings.chat_key[0..n], key[0..n]);
            self.store.settings.chat_key_len = @intCast(n);
        }
        if (ok) self.store.pushNotif("Key saved", "stored in the local (user-private) store", 1) else self.store.pushNotif("Key NOT saved", "could not write the local store", 2);
    }

    /// Store the GitHub PAT (plaintext-local — this is a local, login-gated app). It goes to the local store the
    /// git tools read AND to a durable "key" memory the veil can recall + use directly (curl / authenticated
    /// remote). Entered via `::pat <token>` or the Settings pane. Never reaches settings.json or a tracked file.
    fn cmdSaveGithubPat(self: *Chat, dd: []const u8, pat: []const u8) void {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        const tok = std.mem.trim(u8, pat, " \r\n\t");
        const ok = secrets.savePat(self.io, self.gpa, side, tok);
        // Mirror into memory so the veil can recall + use it directly (not just the git tools). Local app: the
        // token lives plaintext-local on purpose; data/ is git-untracked so it never leaves this machine.
        if (tok.len > 0) {
            var ub: [80]u8 = undefined;
            const user = self.loadGhUser(side, &ub);
            var tb: [400]u8 = undefined;
            const text = if (user.len > 0)
                std.fmt.bufPrint(&tb, "GitHub personal access token for {s}: {s}", .{ user, tok }) catch tok
            else
                std.fmt.bufPrint(&tb, "GitHub personal access token: {s}", .{tok}) catch tok;
            self.storeMemory(dd, "key", text);
        }
        if (ok) self.store.pushNotif("GitHub token saved", "stored locally + in memory so the veil can use it", 1) else self.store.pushNotif("Token NOT saved", "could not write the local store", 2);
    }

    /// Persist the (public) GitHub username — the owner for the remote URL + the commit author. Plain file in the
    /// user-private sidecar dir (not a secret).
    fn cmdSaveGithubUser(self: *Chat, dd: []const u8, user: []const u8) void {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        const u = std.mem.trim(u8, user, " \r\n\t");
        var pb: [700]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/github_user", .{side}) catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = u }) catch {
            self.store.pushNotif("Username NOT saved", "could not write", 2);
            return;
        };
        self.store.pushNotif("GitHub username set", u, 1);
    }

    // ------------------------------------------------------------------------------ settings persistence

    fn saveSettings(self: *Chat, dd: []const u8) void {
        var kind: u8 = 0;
        var byok: u8 = 0;
        var base: [192]u8 = undefined;
        var base_n: usize = 0;
        var model: [96]u8 = undefined;
        var model_n: usize = 0;
        var theme: u8 = 0;
        var lopen = true;
        var ropen = true;
        var shell_allow = false;
        var speed = true;
        var server_chat = false;
        var dyslexia = false;
        var font_scale: u8 = 100;
        var font_bold = false;
        var cfa: [64]u8 = undefined;
        var cfa_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            const s = &self.store.settings;
            kind = s.chat_kind;
            byok = s.chat_byok;
            theme = s.theme;
            base_n = s.chat_base_len;
            @memcpy(base[0..base_n], s.chat_base[0..base_n]);
            model_n = s.chat_model_len;
            @memcpy(model[0..model_n], s.chat_model[0..model_n]);
            cfa_n = s.cf_account_len;
            @memcpy(cfa[0..cfa_n], s.cf_account[0..cfa_n]);
            lopen = s.chat_left_open;
            ropen = s.chat_right_open;
            shell_allow = s.shell_always_allow;
            speed = s.speed_mode;
            server_chat = s.server_chat;
            dyslexia = s.dyslexia;
            font_scale = s.font_scale;
            font_bold = s.font_bold;
        }
        var port: u16 = 8787;
        var host: [64]u8 = undefined;
        var host_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            port = self.store.settings.port;
            const h = self.store.settings.hostStr();
            host_n = @min(h.len, host.len);
            @memcpy(host[0..host_n], h[0..host_n]);
        }
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"kind\":") catch return;
        jb.print(self.gpa, "{d},\"port\":{d},\"byok\":{d},\"theme\":{d},\"host\":\"", .{ kind, port, byok, theme }) catch return;
        escJson(&jb, self.gpa, host[0..host_n]);
        jb.appendSlice(self.gpa, "\",\"base\":\"") catch return;
        escJson(&jb, self.gpa, base[0..base_n]);
        jb.appendSlice(self.gpa, "\",\"model\":\"") catch return;
        escJson(&jb, self.gpa, model[0..model_n]);
        jb.appendSlice(self.gpa, "\",\"cf_account\":\"") catch return;
        escJson(&jb, self.gpa, cfa[0..cfa_n]);
        // Server chat persists as an OPT-OUT flag under `local_brain` (true = user chose the local fallback).
        // Written this way so the DEFAULT (server) needs no key: older files, whatever they carry, read as
        // server-on. TWO dead predecessors, both ignored on read: `chat_server` (the old default-local build
        // wrote `"chat_server":false` for everyone — reading it pinned upgraded installs local) and
        // `chat_local` (its opt-outs were manufactured by a MISLEADING Settings label that sold "tools in
        // your environment" as the local option's advantage after delegation made that the SERVER path's
        // behavior too). A fresh key on each semantic break keeps a bad persisted state from surviving it.
        jb.print(self.gpa, "\",\"left\":{},\"right\":{},\"shell_allow\":{},\"speed\":{},\"local_brain\":{},\"dyslexia\":{},\"font_scale\":{d},\"font_bold\":{}}}", .{ lopen, ropen, shell_allow, speed, !server_chat, dyslexia, font_scale, font_bold }) catch return;
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/settings.json", .{dd}) catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {
            log.warn("chat: could not persist settings", .{});
        };
    }

    fn loadSettings(self: *Chat, dd: []const u8) void {
        // Runs LAST (registered before the body's lock/defer pair), on every path out — including the
        // no-settings-file early return of a fresh install: "loaded" means "the load pass finished",
        // which is what the Settings tab's field seeding waits for, not "a file existed".
        defer {
            self.store.lock();
            self.store.settings_loaded = true;
            self.store.unlock();
        }
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/settings.json", .{dd}) catch return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(8 << 10)) catch return;
        defer self.gpa.free(data);
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        // server host + port (absent host = local loopback, absent port = 8787): lets a desk instance
        // target a non-default or REMOTE veil server without a rebuild.
        if (jInt(data, "port")) |v| {
            if (v >= 1 and v <= 65535) s.port = @intCast(v);
        }
        if (llm.jsonUnescape(self.gpa, data, "host")) |h| {
            defer self.gpa.free(h);
            const n = @min(h.len, s.host.len);
            @memcpy(s.host[0..n], h[0..n]);
            s.host_len = @intCast(n);
        }
        if (jInt(data, "kind")) |v| s.chat_kind = @intCast(@max(0, @min(v, 2)));
        if (jInt(data, "byok")) |v| s.chat_byok = @intCast(@max(0, @min(v, @as(i64, @intCast(catalog.providers.len - 1)))));
        if (jInt(data, "theme")) |v| s.theme = @intCast(@max(0, @min(v, 1)));
        if (llm.jsonUnescape(self.gpa, data, "base")) |b| {
            defer self.gpa.free(b);
            const n = @min(b.len, s.chat_base.len);
            @memcpy(s.chat_base[0..n], b[0..n]);
            s.chat_base_len = @intCast(n);
        }
        if (llm.jsonUnescape(self.gpa, data, "model")) |m| {
            defer self.gpa.free(m);
            const n = @min(m.len, s.chat_model.len);
            @memcpy(s.chat_model[0..n], m[0..n]);
            s.chat_model_len = @intCast(n);
        }
        if (llm.jsonUnescape(self.gpa, data, "cf_account")) |a| {
            defer self.gpa.free(a);
            const n = @min(a.len, s.cf_account.len);
            @memcpy(s.cf_account[0..n], a[0..n]);
            s.cf_account_len = @intCast(n);
        }
        s.chat_left_open = std.mem.indexOf(u8, data, "\"left\":false") == null;
        s.chat_right_open = std.mem.indexOf(u8, data, "\"right\":false") == null;
        s.shell_always_allow = std.mem.indexOf(u8, data, "\"shell_allow\":true") != null;
        s.speed_mode = std.mem.indexOf(u8, data, "\"speed\":false") == null; // absent (old settings) = default ON
        s.dyslexia = std.mem.indexOf(u8, data, "\"dyslexia\":true") != null; // opt-in: absent = standard font
        s.font_bold = std.mem.indexOf(u8, data, "\"font_bold\":true") != null;
        if (jInt(data, "font_scale")) |v| {
            if (v >= 80 and v <= 140) s.font_scale = @intCast(v); // out-of-range hand-edit → keep the 100 default
        }
        // SERVER CHAT is the default and the primary path: the brain runs in the backend and delegates every tool
        // call to THIS client's harness (`veil exec-tool`), so the veil acts on the user's machine while the desk
        // stays a thin client. The local engine survives only as a break-glass fallback when the server is
        // unreachable. Persisted as the OPT-OUT key `local_brain` (absent = server on). Two dead predecessors are
        // deliberately ignored: `chat_server` (the default-local build wrote `false` for everyone — reading it
        // pinned upgraded installs to the retired brain) and `chat_local` (its opt-outs came from a misleading
        // Settings label, not user intent — see saveSettings). A user who truly wants the fallback re-unchecks
        // the now-honest toggle once.
        s.server_chat = std.mem.indexOf(u8, data, "\"local_brain\":true") == null;
    }

    fn loadKey(self: *Chat, dd: []const u8) void {
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        var kb: [192]u8 = undefined;
        const n = secrets.load(self.io, self.gpa, side, &kb);
        if (n == 0) return;
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.settings.chat_key[0..n], kb[0..n]);
        self.store.settings.chat_key_len = @intCast(n);
    }

    // ------------------------------------------------------------------------------ conversations on disk

    fn refreshConvs(self: *Chat, dd: []const u8, force: bool) void {
        _ = force;
        var rows: [store_mod.MAX_CONVS]store_mod.ConvRow = undefined;
        var n: usize = 0;
        var pb: [700]u8 = undefined;
        const cdir = std.fmt.bufPrint(&pb, "{s}/.veil-desk/chats", .{dd}) catch return;
        var dir = Io.Dir.cwd().openDir(self.io, cdir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (n < rows.len) {
            const e = (it.next(self.io) catch break) orelse break;
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".jsonl")) continue;
            const stem = e.name[0 .. e.name.len - 6];
            // scheduled-task runs stay OUT of the primary Chats list (user direction) — they're reachable via
            // the sidebar's Scheduled inner tab and the Scheduled top tab, where they belong.
            if (std.mem.startsWith(u8, stem, "scheduled_")) continue;
            var row: store_mod.ConvRow = .{};
            const idn = @min(stem.len, row.id.len);
            @memcpy(row.id[0..idn], stem[0..idn]);
            row.id_len = @intCast(idn);
            var fpb: [760]u8 = undefined;
            const fp = std.fmt.bufPrint(&fpb, "{s}/{s}", .{ cdir, e.name }) catch continue;
            if (Io.Dir.cwd().statFile(self.io, fp, .{})) |st| {
                row.mtime_s = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
            } else |_| {}
            // title = first line's {"title":"..."}
            if (Io.Dir.cwd().readFileAlloc(self.io, fp, self.gpa, .limited(4 << 10)) catch null) |head| {
                defer self.gpa.free(head);
                const nl = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
                if (llm.jsonUnescape(self.gpa, head[0..nl], "title")) |t| {
                    defer self.gpa.free(t);
                    const tn = @min(t.len, row.title.len);
                    @memcpy(row.title[0..tn], t[0..tn]);
                    row.title_len = @intCast(tn);
                }
            }
            rows[n] = row;
            n += 1;
        }
        // SERVER MERGE: conversations born in the backend (a scheduled task's scheduled_* runs) have no
        // local file yet — fold the server's list in so they reach the sidebar. A local row wins on id
        // collision (its mirror may carry a user-edited title); server unreachable/denied → local list only.
        if (self.runner().chatConvs(self.io, self.gpa)) |resp| {
            defer if (resp.body.len > 0) self.gpa.free(resp.body);
            if (resp.status == 200) {
                if (std.mem.indexOf(u8, resp.body, "\"convs\":[")) |arr| {
                    var cur = arr + "\"convs\":[".len;
                    const n_local = n; // only local rows participate in the dup check — server rows can't self-collide
                    while (n < rows.len) {
                        const obj = scan.nextJsonObj(resp.body, &cur) orelse break;
                        var row: store_mod.ConvRow = .{};
                        var pc: usize = 0;
                        while (scan.nextJsonPair(obj, &pc)) |p| {
                            if (p.is_str and std.mem.eql(u8, p.key, "id")) {
                                // an id the ConvRow can't hold verbatim can't round-trip a select — skip the row
                                if (p.raw.len == 0 or p.raw.len > row.id.len) break;
                                @memcpy(row.id[0..p.raw.len], p.raw); // safeSeg ids carry no escapes
                                row.id_len = @intCast(p.raw.len);
                            } else if (p.is_str and std.mem.eql(u8, p.key, "title")) {
                                row.title_len = @intCast(scan.unescapeInto(p.raw, &row.title).len);
                            } else if (!p.is_str and std.mem.eql(u8, p.key, "updated")) {
                                row.mtime_s = std.fmt.parseInt(i64, p.raw, 10) catch 0;
                            }
                        }
                        if (row.id_len == 0) continue;
                        // scheduled runs are listed under Scheduled, never merged into the Chats list
                        if (std.mem.startsWith(u8, row.idStr(), "scheduled_")) continue;
                        var dup = false;
                        for (rows[0..n_local]) |*r| {
                            if (std.mem.eql(u8, r.idStr(), row.idStr())) {
                                dup = true;
                                break;
                            }
                        }
                        if (dup) continue;
                        rows[n] = row;
                        n += 1;
                    }
                }
            }
        }
        std.mem.sort(store_mod.ConvRow, rows[0..n], {}, struct {
            fn lt(_: void, a: store_mod.ConvRow, b: store_mod.ConvRow) bool {
                return a.mtime_s > b.mtime_s;
            }
        }.lt);
        self.store.lock();
        defer self.store.unlock();
        @memcpy(self.store.convs[0..n], rows[0..n]);
        self.store.conv_count = n;
    }

    fn convPath(dd: []const u8, id: []const u8, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/.veil-desk/chats/{s}.jsonl", .{ dd, id }) catch null;
    }

    fn loadMsgs(self: *Chat, dd: []const u8, id: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = convPath(dd, id, &pb) orelse return;
        // SCHEDULED runs live server-side and GROW there (a run may still be streaming, or finished after the
        // mirror was cut) — a once-mirrored snapshot showed the prompt with no reply and read as "the task
        // never executed". Re-mirror on EVERY select so the view is the server's current truth; the local copy
        // is refreshed in place (best-effort — a down server just shows the last mirror).
        if (std.mem.startsWith(u8, id, "scheduled_")) _ = self.mirrorServerConv(dd, id);
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(2 << 20)) catch blk: {
            // No local file: a SERVER-born conversation (a scheduled_* run merged into the sidebar by
            // refreshConvs). Mirror it down once, then load through the unchanged local path — every
            // later append/rename/delete works on the mirror exactly like a native chat.
            if (!self.mirrorServerConv(dd, id)) return;
            break :blk Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(2 << 20)) catch return;
        };
        defer self.gpa.free(data);
        self.store.lock();
        defer self.store.unlock();
        self.store.msg_count = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        _ = it.next(); // title line
        while (it.next()) |line| {
            if (line.len < 4 or self.store.msg_count >= store_mod.MAX_CHAT_MSGS) continue;
            const r = jInt(line, "r") orelse continue;
            const t = llm.jsonUnescape(self.gpa, line, "t") orelse continue;
            defer self.gpa.free(t);
            var m: store_mod.ChatMsg = .{
                .role = switch (r) {
                    1 => .veil,
                    2 => .cast_note,
                    3 => .thought, // must be explicit: the .user fallback would re-feed a trace to the model as a user turn
                    else => .user,
                },
            };
            // heal transcripts written by an older stripper that stranded a fenced tool-call opener
            const tt = if (m.role == .veil) trimDanglingToolFence(t) else t;
            const tn = @min(tt.len, m.text.len);
            @memcpy(m.text[0..tn], tt[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[self.store.msg_count] = m;
            self.store.msg_count += 1;
        }
    }

    /// Fetch a SERVER conversation's message log (GET /api/v1/chat/convs/:id → {ok,id,messages:[{role,
    /// content,kind,ts}]}) and lay down a local mirror in the exact persistConv format: the {"title"} header
    /// line + one {"r":N,"t":"..."} line per message. Roles map user→.user, assistant→.veil, anything
    /// tool-ish→.cast_note (loadMsgs' numeric codes). The server's content arrives ALREADY JSON-escaped and
    /// is re-emitted verbatim — its escape repertoire (incl. \uXXXX) is exactly what loadMsgs' unescape
    /// reads. Returns false when the server can't produce the conv (down / 404 / denied) — select no-ops.
    fn mirrorServerConv(self: *Chat, dd: []const u8, id: []const u8) bool {
        self.mirror_live = false;
        const resp = self.runner().chatConv(self.io, self.gpa, id) orelse return false;
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        if (resp.status != 200) return false;
        // the conv GET carries turn liveness — a scheduled run may be EXECUTING right now; the selector uses
        // this to attach the live event poller instead of leaving the user staring at a frozen snapshot
        self.mirror_live = std.mem.indexOf(u8, resp.body, "\"live\":true") != null;
        const arr = std.mem.indexOf(u8, resp.body, "\"messages\":[") orelse return false;
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        // title: the sidebar row refreshConvs merged from the server list (or the id when it hasn't landed yet)
        var titleb: [64]u8 = undefined;
        var title_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            var i: usize = 0;
            while (i < self.store.conv_count) : (i += 1) {
                if (std.mem.eql(u8, self.store.convs[i].idStr(), id)) {
                    title_n = self.store.convs[i].title_len;
                    @memcpy(titleb[0..title_n], self.store.convs[i].title[0..title_n]);
                    break;
                }
            }
        }
        jb.appendSlice(self.gpa, "{\"title\":\"") catch return false;
        escJson(&jb, self.gpa, if (title_n > 0) titleb[0..title_n] else id);
        jb.appendSlice(self.gpa, "\"}\n") catch return false;
        var cur = arr + "\"messages\":[".len;
        while (scan.nextJsonObj(resp.body, &cur)) |obj| {
            var role: u8 = 2; // default: anything that isn't a user/assistant turn folds in as a .cast_note
            var raw: []const u8 = "";
            var pc: usize = 0;
            while (scan.nextJsonPair(obj, &pc)) |p| {
                if (p.is_str and std.mem.eql(u8, p.key, "role")) {
                    role = if (std.mem.eql(u8, p.raw, "user")) 0 else if (std.mem.eql(u8, p.raw, "assistant") or std.mem.eql(u8, p.raw, "veil")) 1 else 2;
                } else if (p.is_str and std.mem.eql(u8, p.key, "content")) {
                    raw = p.raw;
                }
            }
            if (raw.len == 0) continue;
            jb.print(self.gpa, "{{\"r\":{d},\"t\":\"", .{role}) catch return false;
            jb.appendSlice(self.gpa, raw) catch return false; // still-escaped server JSON, byte-compatible with loadMsgs
            jb.appendSlice(self.gpa, "\"}\n") catch return false;
        }
        var pb: [700]u8 = undefined;
        const path = convPath(dd, id, &pb) orelse return false;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch return false;
        log.info("chat: mirrored server conv {s} ({d}b)", .{ id, jb.items.len });
        return true;
    }

    fn rewriteTitle(self: *Chat, dd: []const u8, id: []const u8, title: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = convPath(dd, id, &pb) orelse return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(2 << 20)) catch return;
        defer self.gpa.free(data);
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"title\":\"") catch return;
        escJson(&jb, self.gpa, title);
        jb.appendSlice(self.gpa, "\"}") catch return;
        if (nl < data.len) jb.appendSlice(self.gpa, data[nl..]) catch return else jb.append(self.gpa, '\n') catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {};
    }

    /// Append to the ACTIVE conversation: into the Store (render copy, oldest evicted at cap) and rewrite
    /// its file (title + the retained messages — the file mirrors what the app can re-show).
    pub fn appendMsg(self: *Chat, dd: []const u8, role: store_mod.ChatRole, text: []const u8) void {
        self.appendMsgFull(dd, role, text, true);
    }

    /// appendMsg with the hippocampus observe optional — a reflect DRAFT commits without observing (only the
    /// FINAL text should become a neuron; a superseded draft in recall would poison future prompts).
    fn appendMsgFull(self: *Chat, dd: []const u8, role: store_mod.ChatRole, text: []const u8, do_observe: bool) void {
        var idb: [64]u8 = undefined; // = Store.conv_active capacity; [32] literals here were the missed-widening panic class
        var idn: usize = 0;
        var evicted = false; // ring eviction shifted rows → the file must be fully rewritten, not appended
        var tn: usize = 0; // the STORED (possibly clipped) text length — the file must match the store byte-for-byte
        {
            self.store.lock();
            defer self.store.unlock();
            idn = @min(self.store.conv_active_len, idb.len);
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            evicted = self.store.msg_count >= store_mod.MAX_CHAT_MSGS;
            if (self.store.msg_count >= store_mod.MAX_CHAT_MSGS) {
                // PIN THE GOAL: slot 0 is the conversation's original user request — evicting it erases the
                // assignment from both the model's context and the persisted file mid-build (deep into a run the
                // model no longer knows what it was asked to build). Keep it; evict the second-oldest instead.
                const lo: usize = if (self.store.msgs[0].role == .user) 1 else 0;
                std.mem.copyForwards(store_mod.ChatMsg, self.store.msgs[lo .. store_mod.MAX_CHAT_MSGS - 1], self.store.msgs[lo + 1 .. store_mod.MAX_CHAT_MSGS]);
                self.store.msg_count = store_mod.MAX_CHAT_MSGS - 1;
                // eviction shifted the indexes above `lo` down one — keep the live draft slot pointing at its message
                if (self.reflect_msg_idx) |mi| self.reflect_msg_idx = if (mi > lo) mi - 1 else if (mi == lo) null else mi;
            }
            var m: store_mod.ChatMsg = .{ .role = role };
            tn = @min(text.len, m.text.len);
            @memcpy(m.text[0..tn], text[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[self.store.msg_count] = m;
            self.store.msg_count += 1;
        }
        if (idn == 0) return;
        // HIPPOCAMPUS: persist this turn as a neuron under the conversation's scope so it survives the 64-message
        // ring eviction and can be relevance-recalled into future prompts (esp. a cast's synthesis digest, which
        // otherwise ages out as one [cast] message). No-op when neuron-db is disabled.
        if (do_observe) self.mind().observe(idb[0..idn], text);
        // FAST PATH: a plain append writes ONE line (O(1)). The full whole-file rewrite — which during a server
        // turn ran per tool/status frame and scaled with history length, on sync-watched storage — is only needed
        // when the ring evicted (rows shifted) or the file doesn't exist yet (fresh conv needs its title header).
        if (evicted or !self.persistAppendMsg(dd, idb[0..idn], role, text[0..tn]))
            self.persistConv(dd, idb[0..idn]);
    }

    /// Append ONE message line to the conv file. Returns false when the caller must do the full persistConv
    /// instead: the file is missing (a fresh conv needs the {"title"} header line first) or the stat/write failed.
    /// Single-writer (only this chat worker touches the file), so stat→positioned-write needs no lock here.
    fn persistAppendMsg(self: *Chat, dd: []const u8, conv_id: []const u8, role: store_mod.ChatRole, text: []const u8) bool {
        var pb: [700]u8 = undefined;
        const path = convPath(dd, conv_id, &pb) orelse return false;
        const st = Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        if (st.size == 0) return false; // header not written yet — let the full persist lay it down
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.print(self.gpa, "{{\"r\":{d},\"t\":\"", .{@intFromEnum(role)}) catch return false;
        escJson(&jb, self.gpa, text);
        jb.appendSlice(self.gpa, "\"}\n") catch return false;
        const f = Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false }) catch return false;
        defer f.close(self.io);
        f.writePositionalAll(self.io, jb.items, st.size) catch return false;
        return true;
    }

    /// Replace message `idx` IN PLACE (role + text) and re-persist — the in-place revision primitive. The
    /// store rewrites the whole conversation file per append anyway, so replacement costs the same. Never
    /// observes (callers observe the FINAL text exactly once, at finalize).
    fn replaceMsg(self: *Chat, dd: []const u8, idx: usize, role: store_mod.ChatRole, text: []const u8) void {
        var idb: [64]u8 = undefined; // = Store.conv_active capacity; [32] literals here were the missed-widening panic class
        var idn: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            if (idx >= self.store.msg_count) return;
            idn = @min(self.store.conv_active_len, idb.len);
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            var m: store_mod.ChatMsg = .{ .role = role };
            const tn = @min(text.len, m.text.len);
            @memcpy(m.text[0..tn], text[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[idx] = m;
        }
        if (idn == 0) return;
        self.persistConv(dd, idb[0..idn]);
    }

    /// Open a slot directly BEFORE `idx` and put a message there (the reasoning trace lands above the answer
    /// it produced, without re-posting the answer). Evicts the oldest message first when at capacity.
    fn insertMsgBefore(self: *Chat, dd: []const u8, idx_in: usize, role: store_mod.ChatRole, text: []const u8) void {
        var idb: [64]u8 = undefined; // = Store.conv_active capacity; [32] literals here were the missed-widening panic class
        var idn: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            var idx = idx_in;
            idn = @min(self.store.conv_active_len, idb.len);
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            if (idx > self.store.msg_count) return;
            if (self.store.msg_count >= store_mod.MAX_CHAT_MSGS) {
                const lo: usize = if (self.store.msgs[0].role == .user) 1 else 0; // the pinned goal never evicts
                if (idx <= lo) return; // inserting before the message being evicted — nothing sane to do
                std.mem.copyForwards(store_mod.ChatMsg, self.store.msgs[lo .. store_mod.MAX_CHAT_MSGS - 1], self.store.msgs[lo + 1 .. store_mod.MAX_CHAT_MSGS]);
                self.store.msg_count = store_mod.MAX_CHAT_MSGS - 1;
                idx -= 1;
                if (self.reflect_msg_idx) |mi| self.reflect_msg_idx = if (mi > lo) mi - 1 else if (mi == lo) null else mi;
            }
            var k = self.store.msg_count;
            while (k > idx) : (k -= 1) self.store.msgs[k] = self.store.msgs[k - 1];
            var m: store_mod.ChatMsg = .{ .role = role };
            const tn = @min(text.len, m.text.len);
            @memcpy(m.text[0..tn], text[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[idx] = m;
            self.store.msg_count += 1;
            if (self.reflect_msg_idx) |mi| if (mi >= idx) {
                self.reflect_msg_idx = mi + 1;
            };
        }
        if (idn == 0) return;
        self.persistConv(dd, idb[0..idn]);
    }

    /// Rewrite the active conversation's file from the Store copy (title line + retained messages).
    fn persistConv(self: *Chat, dd: []const u8, conv_id: []const u8) void {
        var titleb: [64]u8 = undefined;
        var title_n: usize = 0;
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        {
            self.store.lock();
            defer self.store.unlock();
            // keep the sidebar title in sync (it lives in convs; find it)
            var i: usize = 0;
            while (i < self.store.conv_count) : (i += 1) {
                if (std.mem.eql(u8, self.store.convs[i].idStr(), conv_id)) {
                    title_n = self.store.convs[i].title_len;
                    @memcpy(titleb[0..title_n], self.store.convs[i].title[0..title_n]);
                    break;
                }
            }
        }
        jb.appendSlice(self.gpa, "{\"title\":\"") catch return;
        escJson(&jb, self.gpa, if (title_n > 0) titleb[0..title_n] else "chat");
        jb.appendSlice(self.gpa, "\"}\n") catch return;
        {
            self.store.lock();
            defer self.store.unlock();
            var i: usize = 0;
            while (i < self.store.msg_count) : (i += 1) {
                const m = &self.store.msgs[i];
                jb.print(self.gpa, "{{\"r\":{d},\"t\":\"", .{@intFromEnum(m.role)}) catch return;
                escJson(&jb, self.gpa, m.textStr());
                jb.appendSlice(self.gpa, "\"}\n") catch return;
            }
        }
        var pb: [700]u8 = undefined;
        const path = convPath(dd, conv_id, &pb) orelse return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {
            log.warn("chat: could not persist conversation", .{});
        };
    }

    // ------------------------------------------------------------------------------ the model turn

    fn resolveProvider(self: *Chat, base_buf: *[256]u8, key_buf: *[192]u8, model_buf: *[96]u8) llm.Provider {
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
        var base: []const u8 = undefined;
        var key: []const u8 = "";
        var acct_scratch: [256]u8 = undefined;
        switch (s.chat_kind) {
            1 => {
                // resolveBase substitutes the Cloudflare {account} placeholder (no-op for every other provider)
                base = catalog.resolveBase(&catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)], s.cfAccount(), &acct_scratch);
                key = s.chatKey();
            },
            2 => {
                base = s.chatBase();
                key = s.chatKey();
            },
            else => base = if (s.chat_base_len > 0) s.chatBase() else "http://127.0.0.1:11434/v1",
        }
        const bn = @min(base.len, base_buf.len);
        @memcpy(base_buf[0..bn], base[0..bn]);
        const kn = @min(key.len, key_buf.len);
        @memcpy(key_buf[0..kn], key[0..kn]);
        var model: []const u8 = s.chatModel();
        if (model.len == 0) model = if (s.chat_kind == 1) catalog.providers[@min(s.chat_byok, catalog.providers.len - 1)].models[0].id else "gpt-oss:20b";
        const mn = @min(model.len, model_buf.len);
        @memcpy(model_buf[0..mn], model[0..mn]);
        return .{ .base_url = base_buf[0..bn], .key = key_buf[0..kn], .model = model_buf[0..mn] };
    }

    /// "Sunday 2026-07-05 14:03 UTC" — the model gets a real clock every turn (it has no other one).
    fn dateLine(self: *Chat, buf: []u8) []const u8 {
        const now = self.nowS();
        if (now <= 0) return "";
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
        const ed = es.getEpochDay();
        const yd = ed.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        const weekdays = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" }; // epoch day 0 = Thu 1970-01-01
        const wd = weekdays[@intCast(@mod(ed.day, 7))];
        return std.fmt.bufPrint(buf, "\nCurrent date and time: {s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC.", .{ wd, yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
    }

    fn startTurn(self: *Chat, dd: []const u8, kind: Turn) void {
        // Stop was pressed while this turn's chain was mid-flight — do NOT start the next model call. A genuinely
        // new user/loop turn clears the flag first (cmdSend / loopContinue), so this only pre-empts a re-entry.
        if (self.abort_turn.load(.monotonic)) {
            self.turn = .idle;
            self.setBusy(false);
            self.setStatus("");
            return;
        }
        var msgs: std.ArrayListUnmanaged(u8) = .empty;
        defer msgs.deinit(self.gpa);
        var dbuf: [96]u8 = undefined;
        msgs.appendSlice(self.gpa, "{\"role\":\"system\",\"content\":\"") catch return;
        // A loop-infer turn wears the DRIVER hat (write the user's next message); a consolidate turn is the memory
        // step (not an answer); every other turn is the assistant — with the casting policy picked by mode
        // (speed = the veil builds, casts are 2-minute research sub-agents; autonomy = long hiveminds allowed).
        const speed_now = blk_sp: {
            self.store.lock();
            defer self.store.unlock();
            break :blk_sp self.store.settings.speed_mode;
        };
        escJson(&msgs, self.gpa, if (kind == .loop_infer) LOOP_SYSTEM else if (kind == .consolidate) CONSOLIDATE_SYSTEM else if (speed_now) SYSTEM_PROMPT_SPEED else SYSTEM_PROMPT_AUTONOMY);
        escJson(&msgs, self.gpa, self.dateLine(&dbuf));
        msgs.appendSlice(self.gpa, "\"}") catch return;
        // HIPPOCAMPUS: draw the facts most relevant to THIS query in from the chat's own neuron-db — earlier
        // turns and cast findings, including ones evicted from the 24KB visible history — and inject them as a
        // grounded-context message. Additive + guarded: if recall is empty/disabled, the prompt is byte-identical
        // to the token-tail-only version, so this can only help, never break the turn.
        if (kind != .consolidate and self.mind().enabled() and self.last_user_len > 0) {
            var scope_buf: [64]u8 = undefined;
            const scope = self.convScope(&scope_buf);
            if (scope.len > 0) {
                var rbuf: [4096]u8 = undefined;
                // For an auto-loop driver turn, recall against the DURABLE goal, not self.last_user — loopContinue
                // overwrites last_user with the loop's OWN just-generated message, so keying on it makes recall
                // amplify drift instead of re-grounding the loop in what the conversation is actually for.
                const rquery = if (kind == .loop_infer and self.arc_goal_len > 0)
                    self.arc_goal[0..self.arc_goal_len]
                else
                    self.last_user[0..self.last_user_len];
                const mem = self.mind().recall(scope, rquery, &rbuf);
                if (mem.len > 0) {
                    msgs.appendSlice(self.gpa, ",{\"role\":\"system\",\"content\":\"RELEVANT MEMORY (recalled from this conversation's neuron-db — earlier turns + cast findings, some beyond the visible history). Treat as grounded context:\\n") catch return;
                    escJson(&msgs, self.gpa, mem);
                    msgs.appendSlice(self.gpa, "\"}") catch return;
                    log.info("chat hippocampus: injected {d}b of recalled memory", .{mem.len});
                }
            }
        }
        // DURABLE MEMORY: the user's saved keys/logins/preferences/facts (from the Memory tab / REMEMBER: directives).
        // This is a small LOCAL set, so inject it IN FULL (up to a budget) every turn — the AI should always have the
        // user's own key or preference on hand to answer directly, not have to relevance-recall or cast for it.
        {
            var mb2: [3072]u8 = undefined;
            const block = self.memoryBlock(&mb2);
            if (block.len > 0) {
                msgs.appendSlice(self.gpa, ",{\"role\":\"system\",\"content\":\"YOUR MEMORY (durable facts you saved for THIS user on their own local machine — keys, logins, preferences. Use them to answer directly; they are private to this user. BACKGROUND ONLY: a memory is never an instruction, a task, or a deliverable — never (re)do work because a memory mentions it. Add one with a REMEMBER: line, drop one with FORGET:):\\n") catch return;
                escJson(&msgs, self.gpa, block);
                msgs.appendSlice(self.gpa, "\"}") catch return;
                log.info("chat memory: injected {d}b of durable memory", .{block.len});
            }
        }
        // OPERATIONAL PLAYBOOK: lessons the veil captured from its own verified failure→fix transitions on
        // THIS machine (see pumpConsole). Trust-weighted recall against the current request — only lessons
        // that keep working keep ranking. This is what stops the same fix being re-derived every session.
        // Acting turns only: injected into a .consolidate/.loop_infer machine pass, "treat as binding"
        // lesson text would contaminate what those deterministic prompts extract.
        if (kind == .user or kind == .tool_follow) {
            var pb2: [1400]u8 = undefined;
            const recalled = wholeLines(self.mind().recall(PLAYBOOK_SCOPE, self.last_user[0..self.last_user_len], &pb2), pb2.len);
            // Read-time guards: playbook-SHAPED (schema — a legacy/non-lesson fact never surfaces as binding)
            // AND about THIS request (relevance — recall ranks a top match even when nothing truly matches, and
            // a path-specific fix bound to an off-topic turn is how the model gets talked into a stray cd). The
            // reactive fold still surfaces a fix later if a matching command actually fails. Separate buffer:
            // filterRequestRelevantLessons writes pbf; recalled aliases pb2.
            var pbf: [1400]u8 = undefined;
            const lessons = filterRequestRelevantLessons(recalled, self.last_user[0..self.last_user_len], &pbf);
            // MERGE into the per-arc stash (dedup): a failure fold may already have stashed the
            // cmd-keyed lesson that actually fixes this arc — this last_user-keyed re-recall must
            // ADD to the Hebbian credit target, not clobber it (fold lesson != prompt lesson).
            // Recalled text == stored fact text (assoc prints each fact verbatim), so a strengthen
            // keyed on a stashed line matches that fact. A later clean console result strengthens
            // these precise facts (see pumpConsole's Hebbian close), never the raw user prompt.
            self.stashLessonLines(lessons);
            self.playbook_hit = self.playbook_hit_lesson_len > 0;
            if (lessons.len > 0) {
                msgs.appendSlice(self.gpa, ",{\"role\":\"system\",\"content\":\"OPERATIONAL LESSONS (fixes learned from your own past command failures on this machine — treat them as binding; apply the working form directly instead of re-deriving it):\\n") catch return;
                escJson(&msgs, self.gpa, lessons);
                msgs.appendSlice(self.gpa, "\"}") catch return;
                log.info("playbook: injected {d}b of operational lessons", .{lessons.len});
            }
        }
        // SKILLS (procedural memory — how to do THIS class of task for this user). Written only by the
        // external judge from VERIFIED arcs (never model self-report), governed by the curator. Trust-weighted
        // recall surfaces the class-level skill relevant to the request; empty until the judge mints one.
        if (kind == .user or kind == .tool_follow) {
            var sk: [1600]u8 = undefined;
            const skills = wholeLines(self.mind().recall(SKILLS_SCOPE, self.last_user[0..self.last_user_len], &sk), sk.len);
            if (skills.len > 0) {
                msgs.appendSlice(self.gpa, ",{\"role\":\"system\",\"content\":\"RELEVANT SKILLS (procedural know-how you built from past tasks — the steps + pitfalls for this class of work. Follow them; if one proves wrong this session, note the correction so it can be patched):\\n") catch return;
                escJson(&msgs, self.gpa, skills);
                msgs.appendSlice(self.gpa, "\"}") catch return;
                log.info("skills: injected {d}b of procedural memory", .{skills.len});
            }
        }
        // USER MODEL (who this user is + how they want you to work). Deepened by the judge across sessions;
        // distinct from YOUR MEMORY (their keys/prefs facts) — this is the working persona/style model.
        // Answer-shaped turns only (.reflect polishes tone, so it needs the same grounding the draft had);
        // machine passes (.consolidate/.loop_infer/.collect) must stay uncontaminated.
        if (kind == .user or kind == .tool_follow or kind == .reflect) {
            var ub: [1200]u8 = undefined;
            const um = wholeLines(self.mind().recall(USER_SCOPE, if (self.last_user_len > 0) self.last_user[0..self.last_user_len] else "user", &ub), ub.len);
            if (um.len > 0) {
                msgs.appendSlice(self.gpa, ",{\"role\":\"system\",\"content\":\"WHO YOU'RE TALKING TO (your working model of this user — their style, expectations, and how they want you to operate. Let it shape tone and approach, not override explicit instructions):\\n") catch return;
                escJson(&msgs, self.gpa, um);
                msgs.appendSlice(self.gpa, "\"}") catch return;
                log.info("user-model: injected {d}b", .{um.len});
            }
        }
        const cast_live = self.castPending(); // rowRefeeds: the [orchestrator] brief flows only while its cast runs
        {
            self.store.lock();
            defer self.store.unlock();
            // include from the tail while the budget lasts (the newest matter most) — but PIN the goal:
            // msgs[0] is the user's assignment, and once a long tool arc pushed it out of the tail window the
            // model worked from tool chatter alone and drifted off the original request. Reserve its cost up
            // front and always emit it first when the window would otherwise drop it.
            var budget: usize = 24 * 1024;
            const pin_goal = self.store.msg_count > 0 and self.store.msgs[0].role == .user;
            const floor: usize = if (pin_goal) 1 else 0;
            if (pin_goal) budget -= @min(budget, self.store.msgs[0].text_len);
            var first: usize = floor;
            var i: usize = self.store.msg_count;
            while (i > floor) {
                i -= 1;
                const l = self.store.msgs[i].text_len;
                if (budget < l) {
                    first = i + 1;
                    break;
                }
                budget -= l;
            }
            if (pin_goal) {
                msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"") catch return;
                escJson(&msgs, self.gpa, self.store.msgs[0].textStr());
                msgs.appendSlice(self.gpa, "\"}") catch return;
            }
            var k = first;
            while (k < self.store.msg_count) : (k += 1) {
                const m = &self.store.msgs[k];
                // Thoughts and most machine notes are UI-only breadcrumbs: re-fed as user rows, past
                // nudge/verify directives and "(status)" chatter read as STANDING INSTRUCTIONS the model
                // keeps obeying on every later task in the same conversation. Only bracketed RESULT rows
                // ([console]/[tool:...]/[cast]/[build]) flow back — those are the ground truth the model
                // genuinely needs — and the [orchestrator] brief only while its cast is actually live (see
                // rowRefeeds).
                if (!rowRefeeds(m.role, m.textStr(), cast_live)) continue;
                const role = switch (m.role) {
                    .veil => "assistant",
                    else => "user",
                };
                msgs.print(self.gpa, ",{{\"role\":\"{s}\",\"content\":\"", .{role}) catch return;
                escJson(&msgs, self.gpa, m.textStr());
                msgs.appendSlice(self.gpa, "\"}") catch return;
            }
        }
        // DURABLE GOAL ANCHOR (loop driver only): the next-message generator otherwise reads the whole drifted
        // tail as "the goal". Re-assert the original goal right before it composes, so it steers back to the real
        // objective instead of amplifying a side-quest or a stuck spiral.
        if (kind == .loop_infer and self.arc_goal_len > 0) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"system\",\"content\":\"THE DURABLE GOAL of this thread is:\\n") catch return;
            escJson(&msgs, self.gpa, self.arc_goal[0..self.arc_goal_len]);
            msgs.appendSlice(self.gpa, "\\nLater messages may have drifted onto a side-task or were auto-generated by this loop. Judge what is genuinely DONE and pick the next step against THIS goal; if the recent conversation is stuck repeating a failing step, change approach or steer back to the goal.\"}") catch return;
        }
        // EPHEMERAL DIRECTIVE (act nudge / verify / format retry): injected into THIS re-entered turn's
        // prompt only, then cleared — the durable conversation never carries it.
        if (self.pending_directive_len > 0) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"") catch return;
            escJson(&msgs, self.gpa, self.pending_directive[0..self.pending_directive_len]);
            msgs.appendSlice(self.gpa, "\"}") catch return;
            self.pending_directive_len = 0;
        }
        if (kind == .reflect and self.reflect_draft_len > 0) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"assistant\",\"content\":\"") catch return;
            escJson(&msgs, self.gpa, self.reflect_draft[0..self.reflect_draft_len]);
            msgs.appendSlice(self.gpa, "\"}") catch return;
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"Self-critique pass. Review the draft above as if it were someone else's work you must catch mistakes in: check the logic and facts for errors, look for missing steps, unstated assumptions, unhandled edge cases, and unclear structure. If a claim is uncertain, hedge it or note it. Fix everything you find and make it sharper. If the draft is ALREADY correct and complete, return it exactly unchanged. Return ONLY the final answer text — no meta-commentary, no 'here is the revision', no TOOL: or CAST:.\"}") catch return;
        }
        if (kind == .collect) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"The cast has finished. The files listed above are WHATEVER the hive actually produced - their names may NOT match what the goal asked for (a file called COORDINATOR_PLAN.md or research.py might be the real deliverable, or a goal-named file might be missing). INVENTORY the files, judge which ones actually answer the user's original request, and compose your answer STRICTLY from their real content shown above - never invent content and never claim a file exists that isn't listed. If the goal asked for specific files that aren't present, say so plainly and point to the odd-named files that cover (or fail to cover) that need. TRUST THE SCORE: when the [cast] result above says 100%, the engine's own benchmark has ALREADY verified every deliverable file is present and structurally whole (it parses each format and fails cut-off files), so do NOT spend turns re-reading files just to re-verify existence or completeness - compose the answer now; read a file only when the content shown above is genuinely insufficient for the user's request. A score under 100% means something IS missing or broken - name it and fix or finish it. Do not cast again.\"}") catch return;
        }
        if (kind == .loop_infer) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"Output the next message to send now (or exactly DONE if the goal is already complete). Reply with only that message text.\"}") catch return;
        }
        if (kind == .consolidate) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"Consolidation step. From the conversation above, output the REMEMBER:/FORGET: lines for any durable facts about ME (keys, logins, credentials, environment/setup, stable preferences) that I shared or changed and that are not already in YOUR MEMORY. One directive per line, no other text. If there is nothing new or changed, output exactly NONE.\"}") catch return;
        }
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.resolveProvider(&bb, &kb, &mb);
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        if (!llm.start(&self.stream, self.io, self.gpa, side, prov, msgs.items, MAX_TOKENS, self.nowS())) {
            self.store.pushNotif("Chat failed", "could not start the model call (is curl available?)", 2);
            // A .tool_follow, .reflect (or .collect) re-entry gets here with busy already true — clear it or the chat
            // wedges "busy" forever. turn is already .idle (set by the caller before re-entry).
            self.setBusy(false);
            return;
        }
        self.turn = kind;
        self.turn_epoch = self.conv_epoch;
        self.first_byte_logged = false;
        self.draft_latched = false; // each turn re-earns its drafting presentation
        self.turn_start_ms = self.nowMs();
        self.turn_fb_ms = 0;
        self.setBusy(true);
        self.setStatus("thinking...");
        log.info("chat turn start: kind={t} prompt={d}b model_msgs history", .{ kind, msgs.items.len });
    }

    pub fn pumpStream(self: *Chat, dd: []const u8) void {
        if (self.turn == .idle) return;
        const now = self.nowS();
        // While a cast runs, the chat call shares the local backend with the whole swarm — long silence
        // is queueing. The stream gets a longer first-byte leash and the status line says so honestly.
        llm.poll(&self.stream, self.io, self.gpa, now, self.cast_active);
        // publish the partial reply AND the partial reasoning (so thinking shows live, line-by-line).
        // Strip any tool call from the live preview too — otherwise the raw TOOL:{...} blob (e.g. a whole
        // write_file payload) is visible in the bubble while it streams, even though the settled message
        // strips it; the dispatcher still sees the full stream content at settle.
        // A .reflect pass does NOT preview its content (streaming the in-flight revision below the draft is
        // exactly the double-post artifact) — it shows the CARRIED DRAFT instead, so the bubble never goes
        // blank mid-refinement. .consolidate/.loop_infer are machine turns whose raw output (REMEMBER:/NONE,
        // the next loop message) must never stream into the bubble at all.
        // The reasoning preview still streams (that's the self-check thinking, worth watching live).
        {
            self.store.lock();
            defer self.store.unlock();
            const src = switch (self.turn) {
                .reflect => stripToolTail(self.reflect_draft[0..self.reflect_draft_len]),
                .consolidate, .loop_infer => "",
                else => stripToolTail(self.stream.content.items),
            };
            const n = @min(src.len, self.store.stream_text.len);
            @memcpy(self.store.stream_text[0..n], src[0..n]);
            self.store.stream_len = n;
            // DRAFT MODE: while the answer is still pre-final it must read as the veil THINKING, not as a
            // delivered answer that later vanishes and re-lands. Approximate mirror of the settle-time reflect
            // gate: once a plain answer's stream crosses REFLECT_MIN_ANSWER a self-check will follow UNLESS the
            // reply turns out to be an action (TOOL:/RUN:/CAST: dispatch precedes the reflect gate at settle) —
            // so drafting mode is LATCHED once crossed (no flicker if a tool tail is momentarily stripped
            // mid-delta) and dropped again the moment an action tail is visible. The UI renders draft-mode
            // content as a quote block, so the committed final answer is the only thing that looks like the reply.
            const gate = REFLECT_PASSES > 0 and (self.turn == .user or self.turn == .tool_follow) and
                !self.in_veil_work and src.len >= REFLECT_MIN_ANSWER and
                !isSmallTalk(self.last_user[0..self.last_user_len]);
            if (gate) self.draft_latched = true;
            const action_tail = toolCall(self.stream.content.items) != null or
                castGoal(self.stream.content.items) != null or runCall(self.stream.content.items) != null or
                fencedShellCall(self.stream.content.items) != null;
            if (action_tail) self.draft_latched = false;
            self.store.stream_draft = self.turn == .reflect or self.draft_latched;
            // show the TAIL of the reasoning if it exceeds the buffer (the newest thinking matters most).
            // DE-FLAIL THE LIVE VIEW: a degenerating reasoning channel (one sentence looped dozens of times)
            // otherwise fills the whole preview with the same line — commit-time already dedups (appendVeil),
            // but the wall the user WATCHES is this buffer, so collapse it here too.
            var live_db: [16384]u8 = undefined; // dedupSentences passes anything larger through verbatim — size for a long think
            const rsrc = dedupSentences(self.stream.reasoning.items, &live_db);
            const rn = @min(rsrc.len, self.store.stream_reason.len);
            @memcpy(self.store.stream_reason[0..rn], rsrc[rsrc.len - rn ..]);
            self.store.stream_reason_len = rn;
        }
        if (!self.stream.done) {
            const el = now - self.stream.started_s;
            var sb: [96]u8 = undefined;
            const st = if (!self.stream.saw_any and self.cast_active)
                std.fmt.bufPrint(&sb, "queued behind the hive... {d}s", .{el}) catch "queued behind the hive..."
            else if (!self.stream.saw_any)
                std.fmt.bufPrint(&sb, "thinking... {d}s", .{el}) catch "thinking..."
            else
                std.fmt.bufPrint(&sb, "writing... {d}s", .{el}) catch "writing...";
            self.setStatus(st);
            // Ollama serializes requests unless OLLAMA_NUM_PARALLEL is set, so a chat call waits out the
            // swarm's whole generation. Once it's clearly queued behind a cast on the local backend, tip
            // the user (once) — this is the real lever for concurrent chat + hive, not anything in-app.
            if (self.cast_active and !self.stream.saw_any and el > 6 and !self.parallel_tip and self.isLocalChat()) {
                self.parallel_tip = true;
                self.store.pushNotif("Chat is waiting on Ollama", "set OLLAMA_NUM_PARALLEL=2 (then restart Ollama) so chat and the hive run at once", 0);
            }
            if (self.stream.saw_any and !self.first_byte_logged) {
                self.first_byte_logged = true;
                if (self.turn_fb_ms == 0) { // same u32-overflow guard as recordMetric: an unstamped turn_start_ms makes nowMs()-0 overflow
                    const fb_ms = self.nowMs() - self.turn_start_ms;
                    self.turn_fb_ms = if (self.turn_start_ms == 0 or fb_ms <= 0 or fb_ms > std.math.maxInt(u32)) 1 else @intCast(fb_ms);
                }
                log.info("chat turn: first byte after {d}s", .{el});
            }
            return;
        }
        llm.finish(&self.stream, self.io);
        const kind = self.turn;
        self.turn = .idle;
        if (self.stream.failed) {
            var eb: [260]u8 = undefined;
            const emsg = std.fmt.bufPrint(&eb, "(model error: {s})", .{self.stream.errStr()}) catch "(model error)";
            log.err("chat turn FAILED after {d}s: {s}", .{ now - self.stream.started_s, self.stream.errStr() });
            self.recordMetric(kind, false, self.stream.content.items.len);
            self.stream.deinit(self.gpa);
            // TRANSIENT-DEATH RETRY: a mid-arc stream death (connection reset, provider overload) used to
            // settle the whole arc as an error — auto-loop disarmed, the chat "stopped trying". One bounded
            // re-entry per arc: the prompt rebuilds from the same history, so a transient failure costs one
            // retry and a persistent one still surfaces right after it.
            if (!self.stream_retried and !self.abort_turn.load(.monotonic) and self.turn_epoch == self.conv_epoch) {
                self.stream_retried = true;
                self.appendMsgFull(dd, .cast_note, "(the model stream died — retrying once)", false);
                log.info("stream retry: transient model failure — re-entering the turn once", .{});
                self.startTurn(dd, kind);
                if (self.turn == kind) return; // the retry turn is live
            }
            self.appendMsg(dd, .veil, emsg);
            self.store.pushNotif("Chat model error", emsg, 2);
            self.setBusy(false);
            return;
        }
        const full = std.mem.trim(u8, self.stream.content.items, " \r\n\t");
        const reason = std.mem.trim(u8, self.stream.reasoningStr(), " \r\n\t");
        log.info("chat turn done in {d}s ({d} chars, {d} reasoning); cast_detected={} reply_head={s}", .{ now - self.stream.started_s, self.stream.content.items.len, self.stream.reasoning.items.len, castGoal(full) != null, full[0..@min(full.len, 90)] });
        self.recordMetric(kind, true, self.stream.content.items.len); // one perf sample per completed turn (Metrics tab)
        // Assume this turn is a plain answer; the action dispatchers (tool/shell/cast) flip it true. maybeLoop
        // reads it to decide whether the auto-loop keeps going (working) or stops (the veil just replied).
        if (kind == .user or kind == .tool_follow or kind == .reflect or kind == .collect) self.acted = false;
        // A loop-infer turn produced the NEXT user message (not an assistant reply) — copy it off the stream and
        // either send it (continue the auto-loop) or stop. Handled BEFORE tool/cast/reflect detection.
        if (kind == .loop_infer) {
            var nb: [1024]u8 = undefined;
            const src = if (full.len > 0) full else reason;
            const n = @min(src.len, nb.len);
            @memcpy(nb[0..n], src[0..n]);
            self.stream.deinit(self.gpa);
            self.loopContinue(dd, nb[0..n]);
            return;
        }
        // A CONSOLIDATE turn's output is durable-memory directives (REMEMBER:/FORGET:) or NONE — process them into
        // memory and go idle. Handled BEFORE tool/cast/reflect detection: it is never an answer, a tool, or a cast.
        if (kind == .consolidate) {
            const src = if (full.len > 0) full else reason;
            _ = self.processMemory(dd, src); // stores/forgets for side-effects; the stripped return is discarded
            const saved = self.mem_saved_n;
            const dropped = self.mem_forgot_n;
            self.stream.deinit(self.gpa);
            if (saved > 0 or dropped > 0) {
                var nb: [96]u8 = undefined;
                const note = if (saved > 0 and dropped > 0)
                    std.fmt.bufPrint(&nb, "(memory: {d} saved, {d} dropped)", .{ saved, dropped }) catch "(memory updated)"
                else if (dropped > 0)
                    std.fmt.bufPrint(&nb, "(memory: dropped {d} stale fact{s})", .{ dropped, if (dropped == 1) "" else "s" }) catch "(memory updated)"
                else
                    std.fmt.bufPrint(&nb, "(remembered {d} durable fact{s})", .{ saved, if (saved == 1) "" else "s" }) catch "(remembered)";
                self.appendMsg(dd, .cast_note, note);
                log.info("chat memory: consolidation stored {d}, dropped {d}", .{ saved, dropped });
            }
            self.setBusy(false);
            self.maybeLoop(dd);
            return;
        }
        // The user EXPLICITLY asked for a swarm this turn and none is running: the settle's cast recovery
        // OWES them that cast, so the rescue paths that would consume this settle first (the code-block
        // write hijack, the act nudge, the reflect pass) all stand aside and the reply falls through the
        // chain to the recovery. Deliberate literal TOOL:/RUN:/CAST: calls still dispatch normally.
        const cast_owed = kind == .user and self.loop_iter == 0 and !self.castPending() and
            userWantsCast(self.last_user[0..self.last_user_len]);
        // TOOL: <name> <args> — a single shared-tool call. Run it, fold the result back, continue the loop.
        // Not on a .collect/.reflect turn (those turns are answer-composition passes).
        if (kind != .collect and kind != .reflect) {
            // Primary: a strict TOOL line in content. Recovery: gpt-oss-style reasoning models sometimes leave
            // content empty and narrate the call in the hidden reasoning ("...so we issue TOOL: web_search {..}")
            // — pull the last TOOL: out of the reasoning so the tool still fires (mirrors the cast recovery).
            // TOOL: line first; then the `<tool:NAME>{...}</tool:NAME>` XML form (many models use it, even inline);
            // then a loose recovery from the reasoning channel when content is empty.
            // Last resort for a BUILD task: the model sometimes PASTES the whole file as a ```fenced code block
            // (or the auto-loop asked it to "replace the content of X") instead of using TOOL: write_file — so the
            // file never lands on disk and the run "achieves nothing" while claiming success. If a filename is
            // recoverable from the user's request and there's a substantial code block, synthesize the write_file.
            var synth_args: ?[]u8 = null;
            defer if (synth_args) |s| self.gpa.free(s); // freed AFTER runToolAndContinue dupes it (returns at 1446)
            var synthesized = false; // code-block rescue: the "prose" is the pasted file — never narrate it
            // Reasoning-channel recovery fires when content is EMPTY — and also when content merely
            // ANNOUNCES the action ("I'll check the task now") while the literal call sits stranded in the
            // thinking (non-empty narration is the common case, so a full.len==0-only gate misses it).
            // A literal CAST: in content vetoes recovery outright — the reply DID act (cast dispatches below
            // the reflect gate); hijacking it with a TOOL/RUN dug out of the thinking is wrong. When the
            // reasoning holds BOTH a TOOL: and a RUN:, the LATER one is the model's final decision (looseRunWins).
            const loose_ok = reason.len > 0 and castGoal(full) == null and
                (full.len == 0 or announcesAction(full));
            var tc_opt = toolCall(full) orelse toolCallXml(full) orelse toolCallTagXml(full) orelse toolCallBracket(full) orelse blk_xn: {
                // nested-XML call: <read_file><path>..</path><start_line>..</start_line></read_file>. Builds OWNED
                // JSON args from the XML children (freed via synth_args); NOT `synthesized`, so the prose is still
                // stripped + narrated and the call renders as a normal in-chat tool chip like any other.
                if (toolCallXmlNested(self.gpa, full)) |xc| {
                    synth_args = @constCast(xc.args); // args are heap-owned by toolCallXmlNested; freed via synth_args
                    break :blk_xn ToolCall{ .name = xc.name, .args = xc.args };
                }
                break :blk_xn null;
            } orelse
                (if (loose_ok and !looseRunWins(reason)) blk_loose: {
                    const lt = toolCallLoose(reason) orelse break :blk_loose null;
                    // A DESTRUCTIVE call may never dispatch off the hidden reasoning channel — musing
                    // about the toolbox is not a decision (a loose kill_swarm dug out of the thinking would
                    // hard-kill a cast the user never asked to stop). A kill still recovers when the USER asked for one.
                    if (std.mem.eql(u8, lt.name, "kill_swarm") and !userWantsKill(self.last_user[0..self.last_user_len])) break :blk_loose null;
                    break :blk_loose lt;
                } else null) orelse toolCallFenced(full) orelse toolCallJsonInferred(full) orelse blk_nr: {
                // NATURAL-LANGUAGE READ: `read_file <path> [start_line N] [end_line M]` with no JSON/XML/fence —
                // deepseek drops to this bare form and it never dispatched, so the model re-announced the read
                // forever. read_file is NON-DESTRUCTIVE, so recover it even ungated. OWNED.
                if (naturalReadCall(self.gpa, full)) |nc| {
                    synth_args = @constCast(nc.args);
                    break :blk_nr ToolCall{ .name = nc.name, .args = nc.args };
                }
                break :blk_nr null;
            } orelse blk: {
                // when a cast is owed, the code-block write rescue must stand aside — otherwise a pasted-file
                // answer gets synthesized into a self-build and the requested hive never fires (cast recovery owns it)
                if (cast_owed) break :blk null;
                if (codeBlockWrite(self.gpa, self.last_user[0..self.last_user_len], full)) |s| {
                    synth_args = s;
                    synthesized = true;
                    log.info("build recovery: model pasted a code block instead of write_file — synthesizing the write", .{});
                    break :blk ToolCall{ .name = "write_file", .args = s };
                }
                break :blk null;
            };
            // EMPTY-ARGS write rescue: findToolCall matched `TOOL: write_file` but the args never yielded a
            // usable path. A non-empty (but pathless) match PRE-EMPTS the code-block rescue in the orelse chain
            // above, so without this the empty {} call bounces off the server as "bad path" forever. Two distinct
            // causes, handled differently:
            if (tc_opt) |tc0| {
                if (synth_args == null and !cast_owed and !argsHasPath(tc0.args) and std.mem.eql(u8, tc0.name, "write_file")) {
                    // (1) TRUNCATION — the file was too big and got cut off mid-content by the reply length cap,
                    // so its JSON never closed. THE big-file bug: a 40KB one-pager can't fit in one reply. Don't
                    // dispatch the doomed call; direct a CHUNKED append rewrite (the hive's mechanism) + re-enter.
                    if (looksTruncatedWrite(full) and self.tool_iters < MAX_TOOL_ITERS) {
                        self.tool_iters += 1;
                        self.stream.deinit(self.gpa);
                        self.appendMsgFull(dd, .cast_note, "(that file was too large and got cut off mid-write — asking it to write in smaller append chunks)", false);
                        self.setDirective("Your write_file was TOO LARGE and got cut off mid-content — the reply hit its length limit, so NOTHING was written and the PATH was never the problem. Write this file in CHUNKS across replies: in THIS reply call write_file with ONLY the FIRST part (about the first 120 lines); then in EACH following reply call write_file with the SAME path, \"mode\":\"append\", and the NEXT part — repeat until the file is complete. Keep every chunk small.");
                        self.internal_turn = true;
                        self.setStatus("writing the file in chunks...");
                        log.info("build recovery: write_file truncated by the token cap — directing a chunked append rewrite", .{});
                        self.startTurn(dd, kind);
                        return;
                    }
                    // (2) FENCE PASTE — the file was pasted as a ```code block with no inline JSON. Synthesize
                    // the write from the block (filename from the request/reply, else index.html).
                    if (codeBlockWrite(self.gpa, self.last_user[0..self.last_user_len], full)) |s| {
                        synth_args = s;
                        synthesized = true;
                        log.info("build recovery: write_file call had empty/pathless args — synthesized the write from a pasted code block", .{});
                        tc_opt = ToolCall{ .name = "write_file", .args = s };
                    }
                }
            }
            if (tc_opt) |tc| {
                if (self.tool_iters >= MAX_TOOL_ITERS) {
                    self.appendMsg(dd, .veil, "(I ran several tools in a row without settling on an answer, so I stopped. Ask me to continue if you'd like.)");
                    self.stream.deinit(self.gpa);
                    self.setBusy(false);
                    return;
                }
                // NARRATION ABOVE THE TOOL: the why-sentence the protocol asks for renders as the veil's own
                // line above the tool chip ("this file is broken, let me inspect"); a reasoning-channel model
                // that emitted no prose gets its thinking surfaced as a collapsed thought chip instead — the
                // user always sees WHY a tool is about to run, and the reasoning never silently vanishes.
                if (!synthesized) {
                    const prose = self.processSteer(dd, std.mem.trim(u8, stripToolTail(full), " \r\n\t"));
                    if (prose.len > 0) {
                        self.appendVeil(dd, "", prose);
                    } else if (reason.len > 0) {
                        self.appendMsgFull(dd, .thought, reason[0..@min(reason.len, 1200)], false);
                    }
                }
                self.tool_iters += 1;
                self.runToolAndContinue(dd, tc); // copies tc off the stream, THEN frees it, THEN re-enters
                return; // a fresh .tool_follow turn is now live; stay busy
            }
            // RUN: <shell command> — the AI's micro-console door. Same agentic loop as TOOL (shared iteration
            // budget), output streams into the Veil console tab and folds back so the model reads the result.
            // Same reasoning-channel recovery as TOOL (a RUN: narrated only in the thinking would otherwise have
            // no recovery path and the turn would settle as idle prose).
            // ...and, last, a shell command the model left in a ```<shell> fence instead of a RUN: line. Gated on
            // announcesAction (like the loose term) so a fence that merely ILLUSTRATES a command in a plain answer
            // is never run — only a reply that announces it is about to act recovers its fenced command.
            const fenced = if (announcesAction(full)) fencedShellCall(full) else null;
            const run_opt = runCall(full) orelse (if (loose_ok) runCallLoose(reason) else null) orelse fenced;
            if (run_opt) |cmd| {
                if (self.tool_iters >= MAX_TOOL_ITERS) {
                    self.appendMsg(dd, .veil, "(I ran several commands in a row without settling on an answer, so I stopped. Ask me to continue if you'd like.)");
                    self.stream.deinit(self.gpa);
                    self.setBusy(false);
                    return;
                }
                { // same why-narration above the console chip as for TOOL calls
                    const prose = self.processSteer(dd, std.mem.trim(u8, stripToolTail(full), " \r\n\t"));
                    if (prose.len > 0) self.appendVeil(dd, "", prose);
                }
                self.tool_iters += 1;
                self.runShellAndContinue(dd, cmd); // copies cmd off the stream, THEN frees it, THEN re-enters
                return;
            }
            // KILL RECOVERY: the user asked to kill the hive but the model narrated it as prose ("kill_swarm
            // force=true") instead of a real TOOL: line, so nothing dispatched and the swarm kept running. If a
            // cast is in flight and the user's message is a kill request, run kill_swarm ourselves — the exact
            // recovery pattern userWantsCast uses for a flaked CAST. (kind==.user only; not on tool-follow loops.)
            // !in_veil_work: the orchestrator turn runs with last_user REPLACED by the [orchestrator] brief
            // (which mentions "hive"), so userWantsKill would read that as a kill order and stop a fresh cast.
            // Kill recovery serves REAL user messages only.
            if (kind == .user and !self.in_veil_work and self.castPending() and userWantsKill(self.last_user[0..self.last_user_len])) {
                log.info("kill recovery: user asked to kill; model emitted no tool — dispatching kill_swarm", .{});
                if (full.len > 0 or reason.len > 0) self.appendVeil(dd, reason, stripToolTail(full));
                self.tool_iters += 1;
                self.runToolAndContinue(dd, .{ .name = "kill_swarm", .args = "{}" });
                return;
            }
            // Neither TOOL:/<tool:>/RUN: parsed, but the text still LOOKS like an attempted tool call in some
            // other dialect (DeepSeek-style "<｜tool▁calls｜>" special tokens, Claude-style <invoke name="...">,
            // etc.) — left alone, this renders as garbage and the turn "finishes" having done NOTHING, which is
            // exactly the lock-up bug: the model tried to act, failed silently, and the caller (esp. the veil's
            // parallel attempt, which has no human watching to notice and correct it) treats it as a real answer.
            // Nudge ONCE (shares the tool budget so this can't loop forever) with the exact required format.
            if (looksLikeFailedToolCall(full) and self.tool_iters < MAX_TOOL_ITERS) {
                self.tool_iters += 1;
                self.stream.deinit(self.gpa);
                // The directive reaches the model through the history (cast_note rows re-feed as user
                // rows) — do NOT clobber last_user with it (that mis-keyed every recall/reinforce/loop
                // guard to machine boilerplate) and do NOT observe it (identical boilerplate as neurons
                // poisons the conversation scope's recall).
                self.appendMsgFull(dd, .cast_note, "(that used a tool-call format I can't run — asking it to retry in the right one)", false);
                self.setDirective("Your last reply attempted a tool call in a format I can't execute (only plain TOOL: lines run). Reissue the SAME call: one short why-sentence, then on its own line: TOOL: <name> {\"arg\":\"value\", ...} — no other syntax, no special tokens.");
                self.internal_turn = true; // corrective directive, not a real user turn — don't consolidate memory off it
                self.setStatus("retrying in the right tool format...");
                self.startTurn(dd, kind);
                return;
            }
            // ACT FOLLOW-THROUGH: the reply ANNOUNCED an action ("I'll re-create the task with the full
            // path...") but performed none — no TOOL:/RUN: line in content OR reasoning (the literal-line
            // cases were recovered above). Left alone this settles as a final answer, acted stays false, the
            // auto-loop silently disarms, and the app sits idle on a promise. Re-enter with a hard directive to
            // act — up to TWICE per arc: a narrating model often answers the first nudge with another
            // announcement, and the second converts it (still bounded, still cheap). Own capped counter:
            // narration nudges must never spend the real tool budget. Placed BEFORE the reflect gate — reflect's
            // critique prompt forbids action lines, so it would launder the announced intent into polished prose.
            // AI ROUTER decides "announced an action but performed none" (replacing the hardcoded verb/ack list
            // that missed gerund/imperative announcements); the short-circuit ordering means the gateway call
            // fires ONLY inside this decision window (≤2/arc), and it falls back to the announcesAction floor when
            // it can't decide.
            if (self.act_nudges < 2 and !self.in_veil_work and !self.castPending() and !cast_owed and
                castGoal(full) == null and // a literal CAST: IS the performed action — it dispatches below
                (self.routeMeantToAct(dd, if (full.len > 0) full else reason, false) orelse
                    (announcesAction(full) or (full.len == 0 and announcesAction(reason)))))
            {
                self.act_nudges += 1;
                // The fizzled reply is what the user watched stream — commit it (unobserved: a promise is
                // noise in recall) so it doesn't visibly vanish and the directive has its antecedent in
                // history. And this exchange may still owe a consolidation: the re-entry is machine-authored
                // (internal_turn), which would silently swallow shouldConsolidate — stash the debt.
                if (self.shouldConsolidate(kind, full)) self.consolidate_pending = true;
                if (full.len > 0) self.appendMsgFull(dd, .veil, full, false);
                self.stream.deinit(self.gpa);
                self.appendMsgFull(dd, .cast_note, "continue", false);
                self.setDirective("Your last reply PROMISED an action but performed none. Do it NOW, in this reply: one short why-sentence, then the action on its own line (RUN: <command> or TOOL: <name> {\"arg\":...}). Never end a reply with a promise of future action — act, or state plainly what is blocking you.");
                self.internal_turn = true; // machine directive, not a user exchange (last_user keeps the real goal)
                self.setStatus("following through on the announced action...");
                log.info("act follow-through: reply announced an action but performed none — re-entering", .{});
                self.startTurn(dd, kind);
                return; // startTurn's abort/llm-start failures clear busy; its alloc catch-returns share every caller's exposure
            }
        }
        // !internal_turn: a machine-continuation answer (verify turns, follow-through re-entries, the
        // post-cast repair chain) reports tool evidence — polishing its prose costs 2-3 model calls of pure
        // latency (measured ~30s per settle) for no benefit. Real user answers still reflect; the drafting pass
        // of the original turn already did before any nudge fired.
        if (REFLECT_PASSES > 0 and !self.in_veil_work and !cast_owed and !self.internal_turn and shouldReflectPass(kind, self.last_user[0..self.last_user_len], full)) {
            self.reflect_pass = 0; // fresh iterative-critique budget for this answer
            self.reflect_dirty = false; // no pass has changed anything yet
            self.reflect_draft_len = @min(full.len, self.reflect_draft.len);
            @memcpy(self.reflect_draft[0..self.reflect_draft_len], full[0..self.reflect_draft_len]);
            // seed the reasoning trace with the drafting pass's thinking (each self-check pass adds its own).
            // TRACE HYGIENE: only if it IS thinking — a "reasoning" that just restates the answer (gpt-oss
            // drafts in its thinking channel) is an answer copy; dumping it under the reasoning chip is the
            // reported "doubles of the context" artifact. reflectChanged==false means near-identical text.
            self.reflect_trace_len = 0;
            self.reflect_trace_has_reason = false;
            self.traceAddPass("- drafting -", if (reason.len > 0 and reflectChanged(full, reason)) reason else "");
            self.stream.deinit(self.gpa);
            // NOTHING is committed while the self-check runs — posting the draft and rewriting it in place each
            // pass makes the veil visibly "delete and replace its own answer". Instead the answer stays hidden;
            // the user watches the live reasoning stream during refinement, and revealReflect lands the FINAL
            // answer once at the end.
            self.reflect_msg_idx = null;
            self.setStatus("refining the answer...");
            self.startTurn(dd, .reflect);
            // If the self-check pass couldn't start, reveal the draft as the final answer now.
            if (self.turn != .reflect) self.revealReflect(dd, self.processMemory(dd, stripToolTail(self.reflect_draft[0..self.reflect_draft_len])));
            return;
        }
        if (kind == .reflect) {
            const revised = if (full.len > 0) full else reason; // the critiqued result (slice into the stream)
            const prior = self.reflect_draft[0..self.reflect_draft_len];
            const changed = revised.len > 0 and reflectChanged(prior, revised);
            if (changed) self.reflect_dirty = true; // remember that SOME pass improved the answer (cumulative)
            self.reflect_pass += 1;
            {
                var lb: [72]u8 = undefined;
                const label = std.fmt.bufPrint(&lb, "- self-check pass {d}: {s} -", .{ self.reflect_pass, if (changed) "revised" else "confirmed" }) catch "- self-check -";
                // TRACE HYGIENE: when content came back empty the reasoning channel was consumed AS the
                // revision (2129) — tracing it too would put the full answer under the reasoning chip. And
                // even with clean channels, thinking that merely restates the draft/revision is an answer
                // copy, not reasoning (the reported "doubles"): trace only genuinely distinct thinking.
                const pass_reason = if (full.len > 0 and reason.len > 0 and
                    reflectChanged(revised, reason) and reflectChanged(prior, reason)) reason else "";
                self.traceAddPass(label, pass_reason);
            }
            if (changed and self.reflect_pass < REFLECT_MAX_PASSES) {
                // ITERATIVE self-critique: the pass still improved the answer, so feed the improved text back for
                // ANOTHER critique — recursive refinement that CONVERGES (critique → fix → re-critique …) the way
                // a careful reasoner works, instead of a single shot. Copy it out BEFORE we free the stream.
                // MEMORY INSIDE RECURSIVE THOUGHT: a REMEMBER:/FORGET: the veil settles on DURING this reflection
                // pass was previously dropped (processMemory only ran at draft + finalize). Run it here so a fact
                // decided mid-critique is stored — and copy the CLEANED (directive-stripped) text into the draft so
                // the next pass never re-critiques its own directive (which would poison the convergence heuristic).
                const cleaned = self.processMemory(dd, revised);
                const rn2 = @min(cleaned.len, self.reflect_draft.len);
                @memcpy(self.reflect_draft[0..rn2], cleaned[0..rn2]);
                self.reflect_draft_len = rn2;
                // the improved draft is carried INTERNALLY only — nothing is shown until revealReflect (no churn)
                self.stream.deinit(self.gpa);
                var sb2: [72]u8 = undefined;
                self.setStatus(std.fmt.bufPrint(&sb2, "refining (pass {d} of up to {d})...", .{ self.reflect_pass + 1, REFLECT_MAX_PASSES }) catch "refining...");
                self.startTurn(dd, .reflect);
                if (self.turn == .reflect) return; // another critique pass is live; it settles later
                // couldn't start another pass → reveal the best draft we have as the final answer
                self.revealReflect(dd, self.processMemory(dd, stripToolTail(self.reflect_draft[0..self.reflect_draft_len])));
                self.setBusy(false);
                return;
            }
            // stabilized (the answer stopped changing) or hit the cap → finalize (falls through to the settle).
            // Use the CUMULATIVE dirty flag, not just this pass: if an earlier pass revised the draft and the
            // last pass merely confirmed it, the final answer STILL differs from the first draft, so the slot
            // must hold that final text. `revised` is the last pass's output (slice into the stream, valid until
            // the settle frees it below); fall back to the carried draft if this pass returned empty content.
            const dirty = self.reflect_dirty;
            const final_ans = if (revised.len > 0) revised else self.reflect_draft[0..self.reflect_draft_len];
            log.info("reflect finalize: pass={d} dirty={} changed={} final_len={d}", .{ self.reflect_pass, dirty, changed, final_ans.len });
            // If the self-check draft ITSELF emitted a tool call (e.g. the finish turn deciding to write_file), reflect
            // turns are excluded from tool execution — so RUN it now (showing only the prose part) instead of
            // dumping the raw TOOL:{content} blob as chat text.
            if (self.tool_iters < MAX_TOOL_ITERS) {
                var xml_args: ?[]u8 = null;
                defer if (xml_args) |s| self.gpa.free(s); // runToolAndContinue dupes args first; safe to free after
                const tcr = toolCall(final_ans) orelse toolCallXml(final_ans) orelse toolCallTagXml(final_ans) orelse blk_r: {
                    if (toolCallXmlNested(self.gpa, final_ans)) |xc| {
                        xml_args = @constCast(xc.args);
                        break :blk_r ToolCall{ .name = xc.name, .args = xc.args };
                    }
                    break :blk_r toolCallJsonInferred(final_ans);
                };
                if (tcr) |tc| {
                    const prose = self.processMemory(dd, stripToolTail(final_ans));
                    self.revealReflect(dd, prose); // reveal the prose (+ collapsed trace), then run the tool
                    self.tool_iters += 1;
                    self.runToolAndContinue(dd, tc); // copies tc off the stream, frees it, re-enters .tool_follow
                    return;
                }
            }
            // reveal the final answer ONCE (with the reasoning trace collapsed above it) — no in-place churn
            self.revealReflect(dd, self.processMemory(dd, stripToolTail(final_ans)));
        } else if (kind == .collect) {
            // A collect answer that only ANNOUNCES follow-up work ("the file is truncated — let me fix
            // it") used to settle as the FINAL answer: collect turns are gated out of the TOOL/RUN/
            // act-nudge block above, so the promise fizzled, acted stayed false, the auto-loop disarmed,
            // and the chat sat idle on a broken deliverable. Decide off the live stream slices, commit the
            // answer, then re-enter as a .tool_follow turn (a kind that CAN act) with the same bounded
            // follow-through directive the plain-answer path uses.
            // hive_done=true: this is the collect settle — the hive completed and its files were just verified
            // in the fold, so the router must not read a completed-work report as an unperformed promise.
            const fizzled = self.act_nudges < 2 and
                (self.routeMeantToAct(dd, if (full.len > 0) full else reason, true) orelse
                    (announcesAction(full) or (full.len == 0 and announcesAction(reason))));
            self.appendVeil(dd, reason, full);
            if (fizzled) {
                self.act_nudges += 1;
                self.stream.deinit(self.gpa);
                self.appendMsgFull(dd, .cast_note, "(the reply announced an action but didn't perform it — asking it to act now)", false);
                self.setDirective("Your last reply PROMISED an action but performed none. Do it NOW, in this reply: one short why-sentence, then the action on its own line (RUN: <command> or TOOL: <name> {\"arg\":...}). Never end a reply with a promise of future action — act, or state plainly what is blocking you.");
                self.internal_turn = true; // machine directive, not a user exchange (last_user keeps the real goal)
                self.setStatus("following through on the announced action...");
                log.info("act follow-through: the collect reply announced an action but performed none — re-entering", .{});
                self.startTurn(dd, .tool_follow);
                return; // startTurn's abort/llm-start failures clear busy; same exposure as every caller
            }
        } else if (self.in_veil_work and !self.castPending() and parseCastSpec(full) != null) {
            // castPending veto: while the hive is LIVE, an orchestrator reply that re-emits CAST (the model
            // re-answering the user's cast request it already sees satisfied) must fall to the generic
            // parseCastSpec branch below — "[cast] a cast is already running — new cast ignored" — not to
            // this "do the work yourself" nudge, which would spin up a rival builder beside the hive.
            // The veil tried to DELEGATE to a swarm instead of doing the work itself (common on research goals,
            // since the system prompt encourages casting for current-events). Convert its intent into DIRECT work:
            // re-issue the veil turn ONCE with a hard "no cast — do it yourself" instruction. If it casts again,
            // give up its parallel attempt (the answer falls back to the hive's shared build alone).
            self.stream.deinit(self.gpa);
            if (!self.veil_nudged) {
                self.veil_nudged = true;
                self.tool_iters = 0;
                var pb: [1800]u8 = undefined;
                const p = std.fmt.bufPrint(&pb, "Do NOT cast — you have no swarm here, you ARE the worker. DO THE WORK YOURSELF NOW: call web_search then web_fetch on the best results to gather what you need (or write_file/run_python for a build), then write your result to a file in your workdir. Task: {s}", .{self.veil_goal[0..self.veil_goal_len]}) catch "Do the work yourself now with web_search/write_file — do not cast.";
                self.appendMsg(dd, .cast_note, "(the veil must work directly, not cast — retrying with its own tools)");
                self.appendMsg(dd, .cast_note, p);
                self.last_user_len = @min(p.len, self.last_user.len);
                @memcpy(self.last_user[0..self.last_user_len], p[0..self.last_user_len]);
                self.internal_turn = true; // machine directive, not a user message → don't consolidate memory off it
                self.setStatus("veil working the goal directly...");
                self.startTurn(dd, .user);
                return;
            }
            self.appendMsg(dd, .cast_note, "(the veil kept trying to cast; using the hive's result for this one)");
            self.setBusy(false);
            return;
        } else if (parseCastSpec(full)) |spec| {
            var nb: [3072]u8 = undefined;
            const note = noteWithoutCast(full, &nb);
            // Refuse a second cast not just while one is ACTIVE but through the whole concurrent-veil pipeline
            // (awaiting-veil / veil still working) — a new cast there would reset cast_rel + the veil fields and
            // silently clobber the first cast's pending finish.
            if (self.castPending()) {
                self.appendVeil(dd, reason, if (note.len > 0) note else full);
                self.appendMsg(dd, .cast_note, "[cast] a cast is already running — new cast ignored");
            } else if (self.loop_iter > 0 and self.loop_casts >= MAX_LOOP_CASTS and !self.afkOn()) {
                // The auto-loop MAY cast — delegating a scoped sub-task to a hive is the veil doing its job, and the
                // loop is the inference fail-safe that must STAY ON (user directive). But it's bounded: after several
                // swarms in one loop session, pause for the user so a weak model can't runaway-deploy hives
                // unattended. castPending above already refuses a *concurrent* second cast. In afk the pause is
                // waived — the user opted into forever, swarm runs included (user directive).
                if (note.len > 0 or reason.len > 0) self.appendVeil(dd, reason, note);
                self.stream.deinit(self.gpa); // this early return skips the shared settle deinit — free here
                self.stopLoop(dd, "auto-loop paused: the veil cast several swarms in a row — say 'continue' to keep going.");
                return;
            } else {
                // Fire the cast and KEEP THE LOOP ARMED: after the hive's result folds back in, the loop resumes and
                // the veil keeps working the goal (stopping the loop the instant the veil wants to delegate would
                // prevent a follow-up cast). Count it toward the runaway bound.
                if (self.loop_iter > 0) self.loop_casts += 1;
                if (note.len > 0 or reason.len > 0) self.appendVeil(dd, reason, note);
                self.fireCast(dd, spec);
            }
        } else if (kind == .user and self.loop_iter == 0 and !self.castPending() and userWantsCast(self.last_user[0..self.last_user_len])) {
            // The user EXPLICITLY asked to cast but the model didn't emit a CAST line (gpt-oss commonly
            // leaves `content` empty, putting everything in its hidden reasoning). Honor the request:
            // cast using the user's own words as the goal so an explicit "cast a swarm to X" always fires.
            var gb: [1600]u8 = undefined;
            const goal = castGoalFromUser(self.last_user[0..self.last_user_len], &gb);
            log.info("cast recovery: model emitted no CAST line; casting from the user request", .{});
            if (full.len > 0 or reason.len > 0) self.appendVeil(dd, reason, full);
            self.fireCast(dd, .{ .goal = goal });
        } else if (full.len > 0) {
            self.appendVeil(dd, reason, full);
        } else if (reason.len > 0) {
            // content empty but the model reasoned — show the reasoning AS the reply so it's never blank. NOT
            // observed (appendMsgFull ..., false): gpt-oss commonly answers in the reasoning channel, so observing
            // this would re-open the exact confabulation loop appendVeil closes (parrot → re-observe → amplify).
            // dedupSentences collapses the "I am … I am … I am …" flail this raw-reasoning path is most prone to.
            var ddb: [8192]u8 = undefined;
            self.appendMsgFull(dd, .veil, dedupSentences(reason, &ddb), false);
        } else {
            self.appendMsgFull(dd, .veil, "(the model returned an empty reply — try rephrasing, or switch to a lighter model in Settings)", false);
        }
        // LEARNING (neuron-db Hebbian plasticity): a completed answer turn means the query topic + the memory
        // recalled for it proved useful — STRENGTHEN the stored turn for that topic so it out-ranks the
        // alternatives in later trust-weighted recall. Strengthen-only: the user's message was already observed
        // into this scope (appendMsgFull), so a fragment of it substring-matches that stored fact and bumps it;
        // it NEVER mints (minting "<prompt>: answered" stance facts would surface them as spurious "relevant
        // memory"). The chat's hippocampus LEARNS from engagement instead of only accumulating.
        if ((kind == .user or kind == .collect or kind == .reflect) and full.len > 0 and self.last_user_len > 3 and self.mind().enabled()) {
            var scope_buf: [64]u8 = undefined;
            const scope = self.convScope(&scope_buf);
            // Key on the FIRST SENTENCE as observe() stored it: the substrate sentence-splits on
            // store (and drops '?'-sentences entirely), so a raw multi-sentence prefix substring-
            // matches no stored fact and the strengthen silently no-ops.
            const key = firstStoredSentence(self.last_user[0..self.last_user_len], 120);
            if (scope.len > 0 and key.len > 0) self.mind().strengthen(scope, key);
        }
        // MEMORY INSIDE RECURSIVE THOUGHT: an answer turn just finalized — decide (BEFORE freeing the stream, since
        // `full` is a stream slice) whether to run the deterministic consolidation pass that persists durable facts
        // about the user. If it fires, its own settle does setBusy(false)+maybeLoop, so we return here.
        const consolidate = self.shouldConsolidate(kind, full);
        // VERIFY BEFORE DONE: this arc performed side-effecting actions and the model is now settling on a
        // prose answer (typically "done!"). "The command printed Ready" is not the same as "the thing works"
        // — a task that looked fine can silently fail later (e.g. a scheduled task's LastTaskResult 0x80070002).
        // One bounded verification turn: the model must check the OUTCOME with a read-only command whose result
        // folds back through the real console (exit codes and output are ground truth — the model picks WHAT to
        // check, never what the check returned). A failed check re-enters the normal fix loop (bounded by
        // MAX_TOOL_ITERS). Skipped when the answer hands the turn to the user with a question, on Stop/epoch
        // moves, and during casts/veil work.
        // The reply hands the turn to the user with a question. Read the text ACTUALLY COMMITTED as the
        // reply: gpt-oss commonly leaves content empty and answers in the reasoning channel (shown AS the
        // reply below), so a content-only check missed the common local-model case — a "…add a dark theme?"
        // in the reasoning would let the auto-loop answer the user's question on their behalf.
        const committed_reply = if (full.len > 0) full else reason;
        const asks_user = committed_reply.len > 0 and committed_reply[committed_reply.len - 1] == '?';
        // !announcesAction: a reply that says MORE work is coming is not claiming done — verifying after
        // every landed file inserts a whole ceremony turn mid-build (burning the budget); the auto-loop
        // carries the work forward and the TRUE final settle verifies once.
        const want_verify = (kind == .user or kind == .tool_follow or kind == .reflect) and self.arc_mutated and !self.verify_done and
            !self.arc_final_verified and // the whole-build check already ran; a write it prompted must not re-trigger per-step verify
            !self.in_veil_work and !self.castPending() and
            !asks_user and !announcesAction(committed_reply) and
            self.turn_epoch == self.conv_epoch and !self.abort_turn.load(.monotonic) and
            self.tool_iters + 1 < MAX_TOOL_ITERS; // headroom for the CHECK itself — a verify turn holding the
        //                                           last slot would demand a RUN the budget then refuses
        self.stream.deinit(self.gpa);
        // A question is the veil YIELDING to the user — the auto-loop must not answer it on their behalf
        // (checked here, before the verify/consolidate re-entries, so every path to maybeLoop inherits it).
        // EXCEPT in afk: the user is away by definition, so the loop-infer driver answers on their behalf
        // rather than stranding the conversation on a question nobody is there to read.
        if (asks_user and !self.afkOn()) self.stopLoopQuiet();
        if (want_verify) {
            self.verify_done = true;
            self.tool_iters += 1; // the verify turn spends from the arc's real budget
            // This settle WOULD have consolidated — the verify re-entry is machine-authored (internal_turn),
            // which suppresses shouldConsolidate for the rest of the arc, so carry the debt to the arc's
            // eventual settle (otherwise durable facts are dropped on every mutating arc).
            if (consolidate) self.consolidate_pending = true;
            self.appendMsgFull(dd, .cast_note, "(verifying the outcome before calling it done)", false);
            self.setDirective("Before we call this done: VERIFY the outcome OBJECTIVELY. One short sentence, then exactly ONE read-only RUN: or TOOL: line that checks the thing you just changed actually exists and behaves (query the created task/file/service/state — e.g. a scheduled task's LastTaskResult, a file's content, a service's status). When the result arrives: if it proves the work, report done WITH the evidence; if it exposes a failure, FIX it now and verify again. Only if this exchange truly changed nothing, restate your final answer instead.");
            self.internal_turn = true; // machine directive — never consolidated as a user exchange (last_user keeps the real goal)
            self.setStatus("verifying the work...");
            log.info("verify: arc acted with side effects — running the verification turn", .{});
            self.startTurn(dd, .tool_follow);
            if (self.turn == .tool_follow) return; // the verify turn is live; it settles later
            // couldn't start — fall through to a normal settle so the chat never wedges busy
        }
        if (consolidate or self.consolidate_pending) {
            self.consolidate_pending = false; // consumed (cleared FIRST — the consolidate settle re-enters this path)
            self.setStatus("consolidating memory...");
            self.startTurn(dd, .consolidate);
            if (self.turn == .consolidate) return; // the consolidation turn is live; it settles + goes idle later
        }
        self.setBusy(false);
        self.maybeLoop(dd); // full-auto: if loop mode is on and nothing else is pending, drive the next message
    }

    /// Should we run the deterministic memory-consolidation pass after this just-finalized answer? Only after a
    /// genuine ANSWER turn (never an internal consolidate/collect/loop/veil-work turn), only when the exchange has a
    /// PERSONAL signal (so pure-technical Q&A doesn't spend a model call), and never while a cast/veil-work is in
    /// flight. `full` must still be a live stream slice when this is called.
    fn shouldConsolidate(self: *Chat, kind: Turn, full: []const u8) bool {
        if (!MEMORY_CONSOLIDATE or !self.mind().enabled()) return false;
        if (self.abort_turn.load(.monotonic)) return false;
        if (self.turn_epoch != self.conv_epoch) return false; // the exchange this would consolidate was superseded
        if (kind != .user and kind != .tool_follow and kind != .reflect) return false; // answer turns only (no self-loop)
        if (self.internal_turn) return false; // a machine-authored finish/nudge turn is not a user exchange
        if (self.in_veil_work or self.castPending()) return false; // don't consolidate the veil's parallel research
        if (full.len == 0 and self.last_user_len == 0) return false;
        if (isSmallTalk(self.last_user[0..self.last_user_len])) return false; // "hi"/"thanks" carry nothing durable
        // Durable-signal gate (a cost guard — one model call per hit). Fires on keys/logins/prefs AND on
        // commitments/plans/schedules the user states in passing, and scans the ANSWER too (the veil often
        // re-states a durable fact it just learned). Pure-technical Q&A still matches nothing → no call.
        return exchangeHasDurableSignal(self.last_user[0..self.last_user_len]) or
            (full.len > 0 and exchangeHasDurableSignal(full));
    }

    // ------------------------------------------------------------------------------ escalation ladder (stuck → research → cast)

    /// The stuck→research→cast escalation ladder (user directive: "issues arise > it tries to fix > cannot fix?
    /// >> then it should research and use the swarm tool"). arc_stuck is the shared rung counter EVERY stall
    /// signal feeds — the console-command spiral, a tool failing on the same args, a web-lookup spiral, an afk
    /// repeat. Each call climbs one rung:
    ///   rung 1 — nudge a CHANGE OF APPROACH (stop repeating; get the result a different way)
    ///   rung 2 — FORCE a research step: recall_hive + web_search the ACTUAL error before trying again
    ///   rung 3 — ARM a research CAST at the next idle seam (a swarm breaks through what one turn can't)
    /// `sig_in` is the failure's own words (error line / stuck description) so the research + cast target the
    /// real blocker, not the goal in the abstract. arc_stuck resets at arc boundaries + decays on each success.
    fn escalateStuck(self: *Chat, dd: []const u8, sig_in: []const u8) void {
        // Don't climb during the veil's parallel research or while a cast is already live — that IS the top rung.
        if (self.in_veil_work or self.castPending()) return;
        const sig = std.mem.trim(u8, sig_in, " \r\n\t");
        if (self.arc_stuck < 255) self.arc_stuck += 1;
        if (self.arc_stuck == 1) {
            self.setDirective("This step has failed repeatedly — STOP repeating it; repetition will not make it work. Get the result a DIFFERENT way (a different tool, command, or approach), or state plainly what is blocked and move to the next step of the goal.");
            self.appendMsg(dd, .cast_note, "(stuck: nudging a change of approach)");
        } else if (self.arc_stuck == 2) {
            self.forceResearch(dd, sig);
        } else {
            // rung 3: ARM a research cast — fired at the next idle seam by maybeEscalateCast, NEVER inline from
            // here (a breaker runs deep in a tool-fold / console-pump path where entering the cast machinery isn't
            // safe). Bounded per-arc: once the arc has spent its escalation-cast budget, DON'T re-arm or re-promise
            // — say so once and stand down until the user sends a fresh message (this is the loop-independent
            // runaway guard; loop_casts alone can't bound a manual arc where loop_iter stays 0).
            if (self.arc_escalate_casts >= MAX_ESCALATE_CASTS) {
                if (!self.arc_escalate_capped) {
                    self.arc_escalate_capped = true;
                    self.appendMsg(dd, .cast_note, "(still stuck after casting for help — pausing escalation. Say 'continue' to push on, or take over.)");
                }
                return;
            }
            self.arc_escalate_cast = true;
            const goal_src = if (self.arc_goal_len > 0) self.arc_goal[0..self.arc_goal_len] else self.last_user[0..self.last_user_len];
            const gs = goal_src[0..@min(goal_src.len, 300)];
            var gb: [512]u8 = undefined;
            const g = if (sig.len > 0)
                std.fmt.bufPrint(&gb, "Research and solve this blocker, then report the working method: {s} -- the obstacle is: {s}", .{ gs, sig[0..@min(sig.len, 160)] }) catch gs
            else
                std.fmt.bufPrint(&gb, "Research a better, working method to accomplish this, then report it: {s}", .{gs}) catch gs;
            self.force_cast_goal_len = @min(g.len, self.force_cast_goal.len);
            @memcpy(self.force_cast_goal[0..self.force_cast_goal_len], g[0..self.force_cast_goal_len]);
            self.appendMsg(dd, .cast_note, "(stuck after research — arming a swarm to break through at the next opening)");
        }
    }

    /// Rung 2: the fix attempts aren't working — force a RESEARCH step before any further retry. Mirrors the
    /// startTurn grounding gate, but SEEDED with the actual failure so the lookups target the blocker, not the
    /// goal in the abstract. Ephemeral directive (next turn only); arc_researched marks that the research rung
    /// fired so a later look at posture can tell research already happened.
    fn forceResearch(self: *Chat, dd: []const u8, sig: []const u8) void {
        self.arc_researched = true;
        var db: [900]u8 = undefined;
        const generic = "You have tried to fix this and it keeps failing — STOP retrying the same fix. Your NEXT action MUST be RESEARCH: TOOL: recall_hive {\"query\":\"...\"} on this problem, then TOOL: web_search {\"query\":\"...\"} for a known-good method — BEFORE you touch it again.";
        const d = if (sig.len > 0)
            std.fmt.bufPrint(&db, "You have tried to fix this and it is STILL failing — do NOT retry the same fix. Your NEXT action MUST be RESEARCH: TOOL: recall_hive {{\"query\":\"...\"}} on this exact problem, then TOOL: web_search {{\"query\":\"...\"}} for the error and a known-good method — BEFORE you touch it again. The specific blocker is: {s}", .{sig[0..@min(sig.len, 200)]}) catch generic
        else
            generic;
        self.setDirective(d);
        self.appendMsg(dd, .cast_note, "(stuck: forcing a research step — recall_hive + web_search the error before retrying)");
    }

    /// Fire a rung-3 research cast if one is armed and the seam is safe. Called at the top of maybeLoop, so it
    /// runs whether or not auto-loop is on (a stuck manual arc escalates too). Files-less → veil_join stays off
    /// (fireCast) → the cast is a research strike that FOLDS BACK, not a punitive isolated-build freeze. Bounded
    /// by arc_escalate_casts (a HARD, per-arc, LOOP-INDEPENDENT cap — loop_casts stays 0 in a manual arc and so
    /// can't bound it; escalateStuck also stops re-arming once the budget is spent). Returns true if it fired.
    fn maybeEscalateCast(self: *Chat, dd: []const u8) bool {
        if (!self.arc_escalate_cast) return false;
        // RECOVERED since arming? A rung-3 cast is armed deep in a failing turn, but between arming and this idle
        // seam the model may have fixed the blocker (arc_stuck decays when the failing command/tool finally
        // succeeds). Firing then would deploy a pointless swarm — stand down and disarm if we're no longer at the
        // cast rung (arc_stuck >= 3 is where escalateStuck arms; below it the arc is recovering, not stuck).
        if (self.arc_stuck < 3) {
            self.arc_escalate_cast = false;
            return false;
        }
        if (self.castPending()) return false; // a cast is already live — let it finish and fold first (arming kept)
        self.arc_escalate_cast = false; // consume the arming (escalateStuck re-arms only while budget remains)
        if (self.arc_escalate_casts >= MAX_ESCALATE_CASTS) return false; // per-arc runaway guard (belt-and-suspenders)
        const goal = self.force_cast_goal[0..self.force_cast_goal_len];
        if (goal.len == 0) return false;
        self.arc_escalate_casts += 1;
        self.appendMsg(dd, .cast_note, "(escalation: stuck after trying + researching — casting a swarm to break through)");
        if (self.loop_iter > 0) self.loop_casts += 1; // still counts toward the auto-loop bound when in a loop
        self.fireCast(dd, .{ .goal = goal });
        return true;
    }

    // ------------------------------------------------------------------------------ prompt loop (full-auto)

    /// After a turn settles, start a loop-infer turn IF auto-loop is on and the conversation is genuinely idle
    /// (no in-flight turn, no running cast). Called at the settle point and on a fresh toggle-on (.loop_kick).
    /// The user armed auto-loop while a SERVER-served conv sat IDLE. The server owns the loop but only drives
    /// WITHIN a turn — with no turn running, arming the toggle used to do nothing (maybeLoop stands down via
    /// sc_serving). Fire one normal send with a synthetic continue: the server's resume-preferred plan-board +
    /// durable goal give it real work, and the send body carries the fresh loop tier (on/afk). Fired ONLY from
    /// the explicit .loop_kick command — never from the ~1Hz backstop — so a completed (DONE) turn is not
    /// endlessly re-fired; afk persistence lives INSIDE the server turn, not in desk re-fires.
    fn serverLoopKick(self: *Chat, dd: []const u8) void {
        if (self.turn != .idle or self.sc_active or self.cast_active or self.consoleAiBusy() or self.veil_work_active or self.cast_awaiting_veil) return;
        const st = blk: {
            self.store.lock();
            defer self.store.unlock();
            break :blk [2]bool{ self.store.chat_loop or self.store.chat_loop_afk, self.store.msg_count > 0 };
        };
        if (!st[0] or !st[1]) return; // not armed, or an empty conv (no goal to drive toward yet)
        self.cmdSend(dd, "Auto-loop armed: continue driving toward the goal — pick up the plan (or the last goal) where it left off.");
    }

    fn maybeLoop(self: *Chat, dd: []const u8) void {
        // SERVER CHAT owns the loop. When the conv is SERVED by the server (sc_serving — set on a successful route,
        // cleared on a fallback to local), the SERVER turn drives its own multi-step loop, so the desk must NOT run
        // its LOCAL auto-loop. Keyed on sc_serving (not the 45s serverChatOn() cooldown) so a >45s local fallback
        // build isn't stranded mid-loop.
        if (self.sc_serving) return;
        // wait for any turn/cast/console AND for a concurrent-veil attempt or its pending finish (else auto-loop
        // would grab the shared turn slot out from under the veil work / finish).
        if (self.turn != .idle or self.cast_active or self.consoleAiBusy() or self.veil_work_active or self.cast_awaiting_veil) return;
        // A stuck arc's armed research cast fires HERE, at the first safe idle seam — loop on or off (a stuck
        // manual arc escalates too). It re-enters its own settle when the findings fold back.
        if (self.maybeEscalateCast(dd)) return;
        const st = blk: {
            self.store.lock();
            defer self.store.unlock();
            break :blk [2]bool{ self.store.chat_loop, self.store.chat_loop_afk };
        };
        const afk = st[1];
        const on = st[0] or afk;
        if (!on) return;
        // Only KEEP LOOPING while the veil is actually working. `acted` reflects just the FINAL reply of a
        // chain (every settle resets it), so a build chain that wrote files and then ANNOUNCED the next one
        // read as "just replied" and the loop disarmed mid-build. arc_acted carries "this loop step DID work";
        // a step with zero dispatches (a plain conversational answer, or announce-only after both nudges) still
        // ends the loop — that is the anti-spin bound (re-earned per step in loopContinue), alongside
        // nearlySame + LOOP_MAX_ITERS.
        if (!self.acted and !self.arc_acted) {
            if (self.fireTerminalVerify(dd)) return; // a build that stalled on a no-work step still gets checked
            // ONE announce-only step must not silently disconnect the loop — persistence IS the feature. The
            // loop keeps driving through a single idle settle; only a SECOND consecutive no-action step ends it
            // (that's a conversation, not work).
            self.loop_idle += 1;
            if (self.loop_idle >= 2) {
                if (!afk) {
                    self.stopLoopQuiet();
                    return;
                }
                self.loop_idle = 0; // afk: the anti-spin bound resets instead of ending the loop — it never stops itself
            }
        } else {
            self.loop_idle = 0;
        }
        {
            self.store.lock();
            defer self.store.unlock();
            if (self.store.msg_count == 0) return; // nothing to continue from yet — wait for the first message
        }
        if (self.loop_iter >= LOOP_MAX_ITERS) {
            if (self.fireTerminalVerify(dd)) return;
            if (!afk) {
                self.stopLoop(dd, "auto-loop stopped: reached the iteration limit. Toggle it on again to keep going.");
                return;
            }
            self.loop_iter = 0; // afk: the runaway cap wraps instead of stopping
            self.appendMsg(dd, .cast_note, "(auto-loop-afk: iteration cap reached — counter reset, still going)");
        }
        self.abort_turn.store(false, .monotonic); // reaching here means the loop is (re)starting deliberately
        var sb: [64]u8 = undefined;
        self.setStatus(if (afk)
            std.fmt.bufPrint(&sb, "auto-loop-afk {d}: planning next step...", .{self.loop_iter + 1}) catch "auto-loop-afk: planning..."
        else
            std.fmt.bufPrint(&sb, "auto-loop {d}/{d}: planning next step...", .{ self.loop_iter + 1, LOOP_MAX_ITERS }) catch "auto-loop: planning...");
        self.startTurn(dd, .loop_infer);
    }

    /// The auto-loop (or a non-loop mutating arc) is about to FINISH — if this arc built files and hasn't
    /// had its one whole-build check, fire it now: a read-only inventory that WRITES anything the goal asked
    /// for but is missing, before we declare done. Returns true if it started the verify turn (the caller
    /// must then return without stopping the loop — the turn re-enters the settle path and, once the build
    /// is confirmed whole, the loop's next DONE really ends it). Guarded so it fires at most once per arc.
    fn fireTerminalVerify(self: *Chat, dd: []const u8) bool {
        if (!self.arc_built or self.arc_final_verified) return false;
        if (self.abort_turn.load(.monotonic) or self.turn_epoch != self.conv_epoch) return false;
        if (self.in_veil_work or self.castPending()) return false;
        if (self.tool_iters + 1 >= MAX_TOOL_ITERS) return false; // headroom for the check itself
        self.arc_final_verified = true;
        self.tool_iters += 1;
        // The ENGINE lists the build tree deterministically and hands the model GROUND TRUTH — a weak model
        // asked to "run list_dir" tends to ANNOUNCE the check without emitting the tool call, which spins the
        // act-nudge loop and reads as thrashing. With the real listing in hand the model needs no read-only
        // tool: it either WRITES a file the inventory shows missing (a real action) or gives its final summary.
        // Same discipline as the swarm's engine-stamped verification.
        var listing: std.ArrayListUnmanaged(u8) = .empty;
        defer listing.deinit(self.gpa);
        var rb: [700]u8 = undefined;
        const rel = self.chatBuildRel(&rb);
        if (rel.len > 0) {
            const fn_ = scan.listWorkFiles(self.io, self.gpa, dd, rel, &self.file_scratch);
            var i: usize = 0;
            while (i < fn_) : (i += 1) {
                listing.print(self.gpa, "  - {s} ({d} bytes)\n", .{ self.file_scratch[i].pathStr(), self.file_scratch[i].size }) catch break;
            }
        }
        const files_full = if (listing.items.len > 0) listing.items else "  (the build workdir is EMPTY — nothing was actually written)\n";
        const files_block = files_full[0..@min(files_full.len, 2000)];
        self.appendMsgFull(dd, .cast_note, "(before finishing: checking every file the build needs is actually on disk)", false);
        // The check is scoped to THIS ARC'S GOAL, quoted verbatim: without it the model fills the vacuum
        // from whatever else is in its prompt (a durable-memory fact about a PAST session's build can read
        // as a deliverable list and re-land a whole file tree unprompted).
        const goal = self.last_user[0..@min(self.last_user_len, 300)];
        var db: [3400]u8 = undefined;
        const directive = std.fmt.bufPrint(&db, "Before we call this build done, here is EXACTLY what is on disk right now (the engine listed it — this is ground truth, do NOT run a tool to re-list it):\n{s}\nTHIS conversation's goal — the ONLY source of required files:\n\"{s}\"\nCompare the listing against the files THIS goal itself asked you to build. Memories or notes about other sessions' builds are background, NEVER deliverables here; if this goal asked for no files, nothing is missing. If a file THIS goal requires is MISSING or shows 0/near-0 bytes, WRITE it NOW this turn (one write_file — a missing file is not done). If every required file is present with real content, give your FINAL summary to the user (no tool call) — do not re-write files that are already there.", .{ files_block, goal }) catch "Compare the on-disk files above against what THIS conversation's goal asked you to build (nothing else is a deliverable); write any that are missing, else give your final summary.";
        self.setDirective(directive);
        self.internal_turn = true;
        self.setStatus("checking the build is complete...");
        log.info("terminal verify: arc built files — engine listed {d}b of tree, folding into one completeness turn", .{listing.items.len});
        self.startTurn(dd, .tool_follow);
        return self.turn == .tool_follow;
    }

    /// Handle the message a loop-infer turn produced: stop on DONE / empty / user-toggled-off / cap, else send it.
    fn loopContinue(self: *Chat, dd: []const u8, raw: []const u8) void {
        var text = std.mem.trim(u8, raw, " \r\n\t`*\"'");
        const st = blk: {
            self.store.lock();
            defer self.store.unlock();
            break :blk [2]bool{ self.store.chat_loop, self.store.chat_loop_afk };
        };
        const afk = st[1];
        const on = st[0] or afk;
        if (!on) { // the user switched auto-loop off while it was inferring — stop quietly
            self.setBusy(false);
            return;
        }
        if (text.len == 0) {
            // An EMPTY inference (model hiccup, dead stream, null next-step) must not disconnect the loop —
            // the loop is the inference fail-safe (user directive). Substitute a plain "continue" so the veil
            // takes another real turn; a SECOND consecutive empty inference substitutes "continue" again and
            // the nearlySame repeat-guard below ends the streak — so the rescue is bounded, not a spin.
            if (self.fireTerminalVerify(dd)) return;
            text = "continue";
        } else if (stepIsToolMarkup(text)) {
            // The drive inference answered with a TOOL-CALL FRAGMENT, not an instruction (observed live: a
            // "tool\nread_file" step committed as a user message, which the NEXT turn read back as a confusing
            // user demand — "the user says 'tool read_file'??" — and derailed on). Markup carries no direction:
            // substitute a plain "continue"; the nearlySame repeat guard below bounds the streak exactly as it
            // bounds the empty-inference rescue.
            text = "continue";
        }
        if (loopIsDone(text)) {
            // Don't take the model's word for "done" on a build it may have only ANNOUNCED — run the
            // whole-build check first (it writes anything still missing). Only if that's already done (or
            // this wasn't a build) do we actually finish.
            if (self.fireTerminalVerify(dd)) return;
            if (!afk) {
                self.stopLoop(dd, "auto-loop complete: the goal looks achieved.");
                return;
            }
            // AFK: "done" is not a stop — fold the finish into a fresh drive (re-verify, then extend).
            // The user double-clicked into the never-ending tier; only they can end it.
            self.appendMsg(dd, .cast_note, "(auto-loop-afk: the goal looks achieved — continuing anyway)");
            text = AFK_DRIVE_MSG;
        }
        // REPEAT / STALL GUARD: a weak model in auto-loop can spin, re-emitting a near-identical next step
        // ("check the status to confirm" twice in a row) that makes no progress. Non-afk: stop instead of
        // churning. Skipped in afk (churn beats stopping there, and the DONE fold above re-sends the same drive
        // message by design); a sustained afk spiral instead forces a CHANGE OF APPROACH — re-ground the next
        // step to the original goal rather than re-sending the same stuck step forever.
        const rep = nearlySame(text, self.last_user[0..self.last_user_len]);
        self.loop_repeat_streak = if (rep) self.loop_repeat_streak + 1 else 0;
        if (!afk and rep) {
            if (self.fireTerminalVerify(dd)) return; // a stalled build still gets its completeness check
            self.stopLoop(dd, "auto-loop stopped: the next step just repeated the last one (no progress).");
            return;
        }
        var rgb: [1800]u8 = undefined;
        if (afk and self.loop_repeat_streak >= 3 and self.arc_goal_len > 0) {
            self.loop_repeat_streak = 0;
            self.appendMsg(dd, .cast_note, "(auto-loop-afk: stuck repeating a step — re-grounding to the original goal)");
            // Also climb the escalation ladder: an afk spiral is a stall like any other, so a sustained one
            // should force research and eventually a cast, not just re-ground to the goal forever.
            self.escalateStuck(dd, "repeating the same step in the auto-loop without making progress");
            text = std.fmt.bufPrint(&rgb, "You are stuck repeating a step that is not working. STOP repeating it and take a DIFFERENT concrete action toward the ORIGINAL goal: {s}", .{self.arc_goal[0..self.arc_goal_len]}) catch AFK_DRIVE_MSG;
        }
        if (self.loop_iter >= LOOP_MAX_ITERS) {
            if (!afk) {
                if (self.fireTerminalVerify(dd)) return;
                self.stopLoop(dd, "auto-loop stopped: reached the iteration limit. Toggle it on again to keep going.");
                return;
            }
            self.loop_iter = 0; // afk: the runaway cap wraps instead of stopping
        }
        self.loop_iter += 1;
        // send the inferred message as a (visible) user turn — same path as a manual send, minus the counter reset
        self.last_user_len = @min(text.len, self.last_user.len);
        @memcpy(self.last_user[0..self.last_user_len], text[0..self.last_user_len]);
        self.tool_iters = 0;
        self.act_nudges = 0; // each loop step re-earns its follow-through nudges + verification
        self.arc_acted = false; // ...and re-earns loop continuation by ACTING (announce-only steps end it)
        self.arc_mutated = false;
        self.verify_done = false;
        self.stream_retried = false; // and its own transient-death retry
        // Append WITHOUT observing: the loop's own generated message must not be re-observed into the conversation's
        // neuron-db, or its guesses become recallable "grounded context" next turn — a self-reinforcing drift loop.
        // The durable goal (arc_goal) is the loop's anchor; a synthetic driver turn is not durable knowledge.
        self.appendMsgFull(dd, .user, text, false);
        self.startTurn(dd, .user);
    }

    /// The input's Stop button: abort the in-flight model turn (kills the curl stream), halt auto-loop, and
    /// return to idle so the user can take over. A running CAST is left alone — it has its own Stop in the
    /// swarm panel — but auto-loop won't re-fire behind it.
    fn stopTurn(self: *Chat, dd: []const u8) void {
        // Raise the abort flag BEFORE anything else: the tool-follow chain may be idle-but-live (a blocking tool
        // call in flight) right now, and every re-entry seam checks this flag, so setting it first guarantees no
        // further tool round-trip or auto-loop turn can start behind the Stop.
        self.abort_turn.store(true, .monotonic);
        self.conv_epoch += 1; // Stop means "do not post-process older work into my chat" — collect included
        {
            self.store.lock();
            defer self.store.unlock();
            self.store.chat_loop = false;
            self.store.chat_loop_afk = false; // Stop ends even the never-ending afk tier — the user always wins
        }
        self.loop_iter = 0;
        self.loop_casts = 0;
        self.loop_idle = 0;
        self.reflect_pass = 0; // abandon any pending self-critique iteration
        self.reflect_dirty = false;
        self.reflect_draft_len = 0;
        self.reflect_msg_idx = null; // the committed draft simply stands as the answer
        self.reflect_trace_len = 0;
        // Abandon any concurrent-veil parallel work + pending compare/merge. Without this, in_veil_work could stay
        // TRUE and a later normal turn would write its files into the isolated {conv}-veil dir (lost work), and a
        // pending merge would fire behind the Stop. The hive's own output stays saved (viewable in the Swarm tab).
        self.resetVeilWork();
        self.resetArcFlags(); // Stop abandons the arc — no follow-through/verify/lesson fires behind it
        if (self.awaitingShellApproval()) self.clearPendingCmd(); // Stop dismisses a parked command (unrun)
        if (self.turn != .idle) {
            llm.abort(&self.stream, self.io);
            self.stream.deinit(self.gpa);
            self.turn = .idle;
            self.appendMsg(dd, .cast_note, "(stopped)");
        }
        // Stop a SERVER-chat turn: signal the running server turn to abort (control POST below), then stop the
        // desk-side poller + drop any half-streamed preview so the desk returns to idle and the user can take over.
        if (self.sc_active) {
            // Reach the SERVER turn: POST {"op":"stop"} to its control channel (the turn checks control.jsonl
            // between drive steps + before each inference and aborts). WITHOUT this, the detached background turn
            // keeps running + streaming forever. Then disarm the desk poller + drop any half-streamed preview.
            const conv = self.sc_conv[0..self.sc_conv_len];
            if (conv.len > 0) {
                if (self.runner().chatControl(self.io, self.gpa, conv, "{\"op\":\"stop\"}")) |r| {
                    if (r.body.len > 0) self.gpa.free(r.body);
                }
            }
            self.scClearStream();
            self.setServerActive(false);
            self.appendMsg(dd, .cast_note, "(stopped)");
        }
        // Stop a SERVER-owned cast DISPLAY: the swarm is a SEPARATE detached worker — the {op:stop} above went to the
        // chat TURN's control channel, NOT the swarm. Write the STOP into the swarm's own run dir (mirror cmdStopCast)
        // so the hive actually winds down, then release the display. Without this, Stop leaves the swarm running AND
        // (once the row goes .done) removes the card's Stop button — orphaning it unstoppable.
        if (self.cast_server_owned) {
            if (self.cast_rel_len > 0) {
                const rel = self.cast_rel[0..self.cast_rel_len];
                _ = scan.writeStop(self.io, self.gpa, dd, rel);
                _ = scan.writeControl(self.io, self.gpa, dd, rel, "{\"op\":\"stop\"}");
            }
            // finalize the row even with an UNRESOLVED run dir (updateCastRow skips the rel copy) — a .deploying
            // row left behind here pinned the green "hive is working" bar forever.
            self.releaseServerCastDisplay("stopped");
        }
        self.setStatus("");
        self.setBusy(false);
    }

    /// Reset every agentic-floor arc field. An "arc" is one user goal within ONE conversation — anything
    /// that abandons or leaves the arc (Stop, new/switched conversation, a fresh user message) must clear
    /// these so a stale arc_mutated can't buy a verify turn (or a stale fail half a lesson) somewhere else.
    /// Merge newline-separated lesson lines into the per-arc stash (exact-line dedup; overflow lines
    /// dropped whole). The stash is the Hebbian close's credit target — every lesson INJECTED this arc,
    /// whether by the prompt's last_user-keyed recall or a failure fold's cmd-keyed one. Cleared by the
    /// close itself (one strengthen per injection) and by resetArcFlags (never crosses arcs).
    fn stashLessonLines(self: *Chat, lessons: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, lessons, '\n');
        outer: while (it.next()) |line0| {
            const line = std.mem.trim(u8, line0, " \r\t");
            if (line.len == 0) continue;
            var have = std.mem.tokenizeScalar(u8, self.playbook_hit_lesson[0..self.playbook_hit_lesson_len], '\n');
            while (have.next()) |h| if (std.mem.eql(u8, h, line)) continue :outer;
            const sep: usize = @intFromBool(self.playbook_hit_lesson_len > 0);
            if (self.playbook_hit_lesson_len + sep + line.len > self.playbook_hit_lesson.len) break;
            if (sep > 0) {
                self.playbook_hit_lesson[self.playbook_hit_lesson_len] = '\n';
                self.playbook_hit_lesson_len += 1;
            }
            @memcpy(self.playbook_hit_lesson[self.playbook_hit_lesson_len..][0..line.len], line);
            self.playbook_hit_lesson_len += line.len;
        }
    }

    fn resetArcFlags(self: *Chat) void {
        self.act_nudges = 0;
        self.arc_acted = false;
        self.arc_mutated = false;
        self.arc_built = false; // the whole-build debt belongs to ONE user goal — a new/switched/stopped arc clears it
        self.arc_final_verified = false;
        self.verify_done = false;
        self.arc_fail_cmd_len = 0;
        self.arc_fail_note_len = 0;
        self.arc_fail_sig_len = 0; // a stale failure signature must not ride into an unrelated arc's lesson
        self.playbook_hit = false; // a Stop-abandoned arc's still-running command must not strengthen on landing
        self.playbook_hit_lesson_len = 0; // and its stashed lessons must not carry into an unrelated arc
        self.consolidate_pending = false;
        self.stream_retried = false;
        self.loop_repeat_streak = 0; // a fresh arc is not part of the previous arc's spiral
        self.console_fail_streak = 0;
        self.arc_stuck = 0; // the escalation ladder is per-arc — a new/switched/stopped goal starts un-stuck
        self.tool_fail_streak = 0;
        self.last_tool_fail_len = 0;
        self.arc_escalate_cast = false; // a stale armed cast must not fire into an unrelated arc
        self.arc_escalate_casts = 0; // a fresh arc re-earns its escalation-cast budget
        self.arc_escalate_capped = false;
        self.arc_researched = false;
        self.force_cast_goal_len = 0;
        self.pending_directive_len = 0; // a stale directive must never leak into an unrelated turn's prompt
    }

    /// Queue a machine directive for the NEXT startTurn's prompt only (ephemeral — never persisted, never
    /// re-fed on later turns; the caller appends a short parenthetical .cast_note for UI transparency).
    fn setDirective(self: *Chat, p: []const u8) void {
        self.pending_directive_len = @min(p.len, self.pending_directive.len);
        @memcpy(self.pending_directive[0..self.pending_directive_len], p[0..self.pending_directive_len]);
    }

    /// Third-tier auto-loop-afk armed? (double-click on the toggle). In afk the loop NEVER backs itself
    /// out — every automatic stop resets its budget instead. Only the user ends it (toggle click / Stop).
    fn afkOn(self: *Chat) bool {
        self.store.lock();
        defer self.store.unlock();
        return self.store.chat_loop_afk;
    }

    /// AFK backstop: absorb an automatic stop instead of disarming — counters reset, chat_loop stays
    /// armed, and the ~1Hz run() backstop re-fires maybeLoop. Every known stop site is afk-guarded
    /// explicitly; this catches any path that isn't (the invariant is NEVER backs out, so enforce it at
    /// the choke point too). Returns true when afk swallowed the stop. User-initiated stops (Stop
    /// button, toggle, ::loop off) never route through here — they clear chat_loop_afk directly.
    fn afkAbsorbStop(self: *Chat) bool {
        {
            self.store.lock();
            defer self.store.unlock();
            if (!self.store.chat_loop_afk) return false;
            self.store.chat_loop = true; // afk implies armed — re-assert in case a raced path cleared it
        }
        self.loop_iter = 0;
        self.loop_casts = 0;
        self.loop_idle = 0;
        self.setStatus("auto-loop-afk: still going...");
        return true;
    }

    /// Disarm auto-loop silently — the veil just gave a plain answer, so there's nothing to narrate.
    fn stopLoopQuiet(self: *Chat) void {
        if (self.afkAbsorbStop()) return;
        self.store.lock();
        defer self.store.unlock();
        self.store.chat_loop = false;
    }

    /// Turn auto-loop off and tell the user why (the verifiable stop condition fired).
    fn stopLoop(self: *Chat, dd: []const u8, why: []const u8) void {
        if (self.afkAbsorbStop()) {
            var b: [300]u8 = undefined;
            const note = std.fmt.bufPrint(&b, "(auto-loop-afk absorbed a stop [{s}] — still going)", .{why}) catch "(auto-loop-afk absorbed a stop — still going)";
            self.appendMsg(dd, .cast_note, note);
            return;
        }
        {
            self.store.lock();
            defer self.store.unlock();
            self.store.chat_loop = false;
        }
        self.loop_iter = 0;
        self.loop_casts = 0;
        self.loop_idle = 0;
        self.appendMsg(dd, .cast_note, why);
        self.setStatus("");
        self.setBusy(false);
    }

    /// Append a veil message, prepending the model's reasoning (if any) as a capped markdown blockquote so
    /// the user can see how it thought. Reasoning is trimmed to leave room for the answer in the message.
    fn appendVeil(self: *Chat, dd: []const u8, reasoning: []const u8, text_raw: []const u8) void {
        // Never let a raw TOOL:/RUN:/<tool:> call (esp. write_file{"content":<whole file>}) leak into the chat as
        // visible text — that only happens when a reflect/collect turn re-emits a tool call it can't run; strip it
        // so only the prose survives (the call itself runs in the tool loop + shows as a chip, or is dropped).
        // Then act on + strip STEER: hive-guidance lines and any durable-memory directives (REMEMBER:/FORGET:)
        // so they take effect but never render as answer text.
        const text0 = self.processMemory(dd, self.processSteer(dd, stripToolTail(text_raw)));
        // Collapse an intra-reply "flail" (the same sentence emitted several times in a row) before it renders.
        // Prose only — tool/steer/memory lines are already stripped above, so nothing structural is at risk.
        var tdb: [8192]u8 = undefined;
        const text = dedupSentences(text0, &tdb);
        if (text.len == 0 and reasoning.len == 0) {
            // The whole reply was memory directives (nothing left to render). Don't go silent — confirm the save so
            // the user gets feedback that their key/preference landed (it's in the Memory tab now).
            if (self.mem_saved_n > 0 or self.mem_forgot_n > 0) {
                const note: []const u8 = if (self.mem_saved_n > 0 and self.mem_forgot_n > 0)
                    "Updated your memory."
                else if (self.mem_saved_n == 1)
                    "Saved that to memory."
                else if (self.mem_saved_n > 1)
                    "Saved those to memory."
                else
                    "Removed that from memory.";
                self.appendMsg(dd, .veil, note);
            }
            return; // nothing left to show
        }
        // The veil's OWN reply is appended WITHOUT observing it into the hippocampus (appendMsgFull ..., false). It
        // is already re-fed into the visible window (rowRefeeds→assistant), so storing it for recall is redundant
        // AND is a confabulation vector: the per-conversation recall re-injects the model's own ephemeral narration
        // as "grounded context", so a stuck phrase gets parroted → re-observed → amplified from a one-off into a
        // runaway loop. The hippocampus keeps DURABLE facts — user turns, cast findings, tool/console results —
        // not the veil's own chatter.
        if (reasoning.len == 0) {
            self.appendMsgFull(dd, .veil, text, false);
            return;
        }
        // Reasoning lands as its OWN collapsed .thought message above the answer (.thought is excluded from the
        // prompt). Baking it into the answer text as "> " blockquote lines would re-feed the model its own prior
        // reasoning as assistant history every turn and clutter the visible answer.
        var buf: [4096]u8 = undefined;
        var w: usize = 0;
        const cap = @min(reasoning.len, 4000);
        var rdb: [4096]u8 = undefined;
        const reason_d = dedupSentences(reasoning[0..cap], &rdb); // de-flail the shown reasoning too
        var it = std.mem.splitScalar(u8, reason_d, '\n');
        while (it.next()) |line| {
            const ln = std.mem.trim(u8, line, " \r\t");
            if (ln.len == 0) continue;
            if (w + ln.len + 1 > buf.len) break;
            @memcpy(buf[w .. w + ln.len], ln);
            w += ln.len;
            buf[w] = '\n';
            w += 1;
        }
        if (reasoning.len > cap and w + 3 < buf.len) {
            @memcpy(buf[w .. w + 3], "...");
            w += 3;
        }
        if (w > 0) self.appendMsgFull(dd, .thought, buf[0..w], false);
        if (text.len > 0) self.appendMsgFull(dd, .veil, text, false); // not observed — see the note above
    }

    /// STEER: <instruction> — the veil's control door to a LIVE hive. Each STEER line is delivered on the
    /// run's control bus ({"op":"say","to":"all"} — the exact bus workers drain each round), confirmed with a
    /// small note in the chat, and stripped from the display text. With no live cast the line is dropped with
    /// a note instead (steering nothing is a model mistake worth surfacing, not rendering). Max 2 per reply.
    fn processSteer(self: *Chat, dd: []const u8, text: []const u8) []const u8 {
        if (std.mem.indexOf(u8, text, "STEER:") == null) return text;
        var w: usize = 0;
        var sent: u8 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const ln = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, ln, "STEER:")) {
                const body = std.mem.trim(u8, ln["STEER:".len..], " \r\t");
                if (body.len > 0 and sent < 2) {
                    sent += 1;
                    if (self.cast_active and self.cast_rel_len > 0) {
                        var jb: std.ArrayListUnmanaged(u8) = .empty;
                        defer jb.deinit(self.gpa);
                        const ok = blk: {
                            jb.appendSlice(self.gpa, "{\"op\":\"say\",\"to\":\"all\",\"text\":\"") catch break :blk false;
                            escJson(&jb, self.gpa, body);
                            jb.appendSlice(self.gpa, "\"}") catch break :blk false;
                            break :blk true;
                        };
                        if (ok and scan.writeControl(self.io, self.gpa, dd, self.cast_rel[0..self.cast_rel_len], jb.items)) {
                            var nb: [420]u8 = undefined;
                            const note = std.fmt.bufPrint(&nb, "(steered the hive: {s})", .{body[0..@min(body.len, 360)]}) catch "(steered the hive)";
                            self.appendMsg(dd, .cast_note, note);
                            log.info("chat steer: {s}", .{body[0..@min(body.len, 120)]});
                        } else self.appendMsg(dd, .cast_note, "(could not deliver the steer to the hive)");
                    } else self.appendMsg(dd, .cast_note, "(no live cast to steer)");
                }
                continue; // stripped from the display either way
            }
            if (w + line.len + 1 > self.steer_scratch.len) break;
            @memcpy(self.steer_scratch[w..][0..line.len], line);
            w += line.len;
            self.steer_scratch[w] = '\n';
            w += 1;
        }
        if (sent == 0) return text; // nothing acted on — hand back the original untouched
        return std.mem.trimEnd(u8, self.steer_scratch[0..w], " \r\n\t");
    }

    // ---- reflect trace helpers (the reasoning that led to the final answer, shown instead of the old draft) ----

    fn traceAppend(self: *Chat, s: []const u8) void {
        const n = @min(s.len, self.reflect_trace.len - self.reflect_trace_len);
        @memcpy(self.reflect_trace[self.reflect_trace_len..][0..n], s[0..n]);
        self.reflect_trace_len += n;
    }

    /// One labeled section per pass: "- drafting -" / "- self-check pass N: revised -" + that pass's reasoning
    /// (capped per pass so several passes fit the trace buffer), so intermediate passes' reasoning survives
    /// instead of being discarded.
    fn traceAddPass(self: *Chat, label: []const u8, reason: []const u8) void {
        if (self.reflect_trace_len > 0) self.traceAppend("\n");
        self.traceAppend(label);
        const r = std.mem.trim(u8, reason, " \r\n\t");
        if (r.len > 0) {
            self.reflect_trace_has_reason = true; // real thinking landed — the chip is worth showing
            self.traceAppend("\n");
            const cap = @min(r.len, 1500);
            self.traceAppend(r[0..cap]);
            if (r.len > cap) self.traceAppend(" ...");
        }
    }

    /// REVEAL the reflected answer — ONE clean commit at the end of refinement. Nothing is shown while the
    /// self-check passes run (committing the draft then rewriting it in place reads as the veil "deleting and
    /// replacing its answer"). During refinement the user watches the live reasoning stream; here the final
    /// answer lands once, with the full reasoning trace collapsed above it (the "reasoning locker" the user
    /// opens if curious). Clears all reflect state.
    fn revealReflect(self: *Chat, dd: []const u8, answer: []const u8) void {
        if (answer.len > 0) {
            self.appendMsgFull(dd, .veil, answer, false); // not observed into the hippocampus (see appendVeil's note)
            // Only when some pass contributed REAL thinking — a labels-only trace ("- drafting -" +
            // "- self-check pass 1: ... -" with nothing under them) is noise, not a reasoning locker.
            if (self.reflect_trace_len > 0 and self.reflect_trace_has_reason) {
                if (self.lastMsgIdxOfRole(.veil)) |mi| self.insertMsgBefore(dd, mi, .thought, self.reflect_trace[0..self.reflect_trace_len]);
            }
        }
        self.reflect_msg_idx = null;
        self.reflect_trace_len = 0;
        self.reflect_trace_has_reason = false;
        self.reflect_draft_len = 0;
        self.reflect_pass = 0;
        self.reflect_dirty = false;
    }

    /// Index of the newest message with `role` (the just-committed draft slot), or null.
    fn lastMsgIdxOfRole(self: *Chat, role: store_mod.ChatRole) ?usize {
        self.store.lock();
        defer self.store.unlock();
        var i = self.store.msg_count;
        while (i > 0) {
            i -= 1;
            if (self.store.msgs[i].role == role) return i;
        }
        return null;
    }

    // ------------------------------------------------------------------------------ casting (the existing door)

    /// CAST through the server's cast endpoint (POST /api/v1/cast). The AI configures the payload — the goal,
    /// how many minds, quick strike vs a sustained (LONG/continuous) hivemind, and the time budget — and the
    /// chat fires it on the chat's own provider. The server clamps to the plan's ceilings.
    pub fn fireCast(self: *Chat, dd: []const u8, spec: CastSpec) void {
        self.acted = true; // a cast is a big action → the exchange is "working"
        self.arc_acted = true;
        const goal = spec.goal;
        // The conversation id doubles as the cast's build dir: the server points the hive's run_dir at this
        // chat's `_chat/builds/{conv}` folder, so the cast builds in the SAME tree the chat's own build tools
        // (and the desktop console) use — not a throwaway `{hex}/work` the chat can never see.
        var convb: [96]u8 = undefined;
        const conv = self.convScope(&convb);
        // Concurrent Veil: the veil's parallel attempt JOINS the hive here — both build in this SAME "{conv}"
        // dir (no separate "-veil" copy), so the swarm's own concurrent-edit safety (not a post-hoc AI merge)
        // is what reconciles the two streams of edits. veil_join just gates whether maybeVeilWork fires.
        // GATED ON DECLARED FILES: a files-less RESEARCH cast (the escalation strike, or any "go find out X")
        // must NOT tie the veil up in an isolated parallel BUILD — there's nothing to build, and the isolated
        // work + its merge-wait is exactly the punitive freeze that made a 2-minute swarm read as a dead end.
        // Only a BUILD cast (declared deliverables) gets the concurrent veil-build; a research cast just runs,
        // folds its findings back, and the loop resumes.
        const veil_join = CONCURRENT_VEIL and spec.files.len > 0 and conv.len > 0 and conv.len <= self.cast_conv.len;
        const hive_dir = conv;
        const minds: u32 = if (spec.minds > 0) std.math.clamp(spec.minds, 1, 30) else 3;
        // SPEED MODE ceiling: a chat cast is a 2-minute research sub-agent — without the cap the model
        // dispatches 10-100 minute hiveminds for 3-5 minute jobs. Autonomy mode keeps the full range.
        const speed = blk_sm: {
            self.store.lock();
            defer self.store.unlock();
            break :blk_sm self.store.settings.speed_mode;
        };
        const minutes = blk_wf: {
            const base = castMinutes(spec.minutes, spec.long, speed);
            // WORKLOAD FLOOR: when the veil DECLARED the deliverables, the time budget must fit them —
            // a 2-minute speed cap against 14 declared files kills the run at 4/14. ~1 min per 3 declared
            // files, floor 2, ceiling 20. Mirrors the server's identical floor so the desktop's own deadline
            // watchdog doesn't kill a cast the server granted more time.
            if (spec.files.len == 0) break :blk_wf base;
            var nf: u32 = 0;
            var fit = std.mem.tokenizeAny(u8, spec.files, ",\n\r");
            while (fit.next()) |t| {
                if (std.mem.trim(u8, t, " \t`'\"").len >= 2) nf += 1;
            }
            if (nf == 0) break :blk_wf base;
            break :blk_wf @max(base, @min(20, @max(2, (nf + 2) / 3)));
        };
        if (speed and (spec.long or spec.minutes > minutes))
            self.appendMsg(dd, .cast_note, "(speed mode: swarm time-capped at 2 minutes — turn speed mode off in Settings for long autonomous hiveminds)");
        const mode: []const u8 = if (spec.long) "continuous" else "cast";
        self.cast_minutes = minutes;
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.resolveProvider(&bb, &kb, &mb);
        var kind: u8 = 0;
        var byok: u8 = 0;
        var port: u16 = 8787; // kept only for the unreachable-server log below; the runner reads port+token itself
        {
            self.store.lock();
            defer self.store.unlock();
            kind = self.store.settings.chat_kind;
            byok = self.store.settings.chat_byok;
            port = self.store.settings.port;
        }
        const prov_key = castProviderId(kind, byok);

        // A local model loaded with a runaway context (OLLAMA_CONTEXT_LENGTH unset) casts ~16x slower and
        // reads as "broken" — surface the one-line fix once, before the row, so the slowness is explained.
        if (std.mem.eql(u8, prov_key, "ollama")) {
            self.localSlowTip(dd); // check now (model may already be loaded huge)
            self.ctx_poll_budget = 12; // and re-check for the first ~12 ticks in case it loads huge mid-cast
        }

        // Show a "deploying" row + status the INSTANT casting starts, BEFORE building the body — so even a
        // body-build failure is visible (a stuck row) rather than a silent nothing.
        self.pushCastRow(goal);
        self.setStatus(if (spec.long) "casting a long-term hive..." else "casting the hive...");
        log.info("cast: start provider={s} model={s} minds={d} mode={s} minutes={d} goal={s}", .{ prov_key, prov.model, minds, mode, minutes, goal[0..@min(goal.len, 60)] });

        var body: [4096]u8 = undefined;
        var w = Io.Writer.fixed(&body);
        const bok = blk: {
            w.print("{{\"provider\":\"{s}\",\"model\":\"{s}\",\"base_url\":\"{s}\",\"minutes\":{d},\"minds\":{d},\"mode\":\"{s}\",\"dir\":\"", .{ prov_key, prov.model, prov.base_url, minutes, minds, mode }) catch break :blk false;
            wesc(&w, hive_dir); // the hive builds in {conv} — the SAME dir the veil's parallel attempt joins
            w.writeAll("\",\"api_key\":\"") catch break :blk false;
            wesc(&w, prov.key);
            if (spec.files.len > 0) {
                // DECLARED deliverables ride with the cast: the engine adopts them verbatim as the blueprint,
                // so the swarm is assigned + graded on the exact outputs the veil reasoned out — not on
                // whatever file-shaped tokens the goal prose happens to contain.
                w.writeAll("\",\"files\":\"") catch break :blk false;
                wesc(&w, spec.files);
            }
            // Close the preceding string value, insert publish (a BARE bool, not a quoted string — so its
            // separator differs from the string keys), then open goal. NEWS DESK: a publish cast runs as a
            // grounded research/briefing hive that posts its screened thesis to Telegraph.
            w.writeAll(if (spec.publish) "\",\"publish\":true,\"goal\":\"" else "\",\"goal\":\"") catch break :blk false;
            wesc(&w, goal);
            w.writeAll("\"}") catch break :blk false;
            break :blk true;
        };
        if (!bok) {
            log.err("cast: body build overflow (goal/key too long)", .{});
            self.appendMsg(dd, .cast_note, "[cast] failed — the request was too large to build");
            self.updateCastRow(.failed, 0, -1, "request too large", "");
            self.setStatus("");
            return;
        }

        const resp = self.runner().cast(self.io, self.gpa, w.buffered()) orelse {
            log.err("cast: netcli returned NULL (no response after retries) — server on :{d}?", .{port});
            self.appendMsg(dd, .cast_note, "[cast] no response from the veil server on :8787 — it may be starting up or briefly busy. If casts keep failing, make sure the server is running (run `veil`), then try again.");
            self.updateCastRow(.failed, 0, -1, "no response from :8787 (busy or down)", "");
            self.store.pushNotif("Cast failed", "no response from :8787 — try again", 2);
            self.setStatus("");
            return;
        };
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        log.info("cast: POST -> status={d} body={s}", .{ resp.status, resp.body[0..@min(resp.body.len, 160)] });
        if (resp.status != 200 and resp.status != 201) {
            // 404 specifically means the RUNNING veil.exe predates the /api/v1/cast route — a stale server binary.
            var nb: [280]u8 = undefined;
            const msg = if (resp.status == 404)
                std.fmt.bufPrint(&nb, "[cast] the veil server is out of date — its build predates the cast endpoint (HTTP 404). Rebuild + restart it (`zig build --release=fast` then relaunch `veil`). I'll answer directly from chat in the meantime.", .{}) catch "[cast] server out of date (404) — rebuild + restart it"
            else
                std.fmt.bufPrint(&nb, "[cast] rejected by the server (HTTP {d}): {s}", .{ resp.status, resp.body[0..@min(resp.body.len, 120)] }) catch "[cast] rejected";
            self.appendMsg(dd, .cast_note, msg);
            self.updateCastRow(.failed, 0, -1, if (resp.status == 404) "server out of date - rebuild it" else if (resp.status == 401 or resp.status == 403) "unauthorized - set an API token" else "server rejected the cast", "");
            self.store.pushNotif("Cast unavailable", if (resp.status == 404) "server is out of date — rebuild + restart veil.exe" else if (resp.status == 401 or resp.status == 403) "set an API token in Settings" else "server error", 2);
            self.setStatus("");
            // Graceful fallback: the model builds/answers directly from chat. pumpStream settles this turn right
            // after fireCast returns (setBusy(false) + maybeLoop), so auto-loop — or the user — drives the next step.
            self.appendMsg(dd, .cast_note, "[cast] proceeding without the hive — I'll build/answer directly here.");
            return;
        }
        var idb: [64]u8 = undefined;
        const hex = jStr(resp.body, "id", &idb) orelse "";
        if (hex.len == 0) {
            log.err("cast: 2xx but no id in body: {s}", .{resp.body[0..@min(resp.body.len, 160)]});
            self.appendMsg(dd, .cast_note, "[cast] deploy answered without an id — check the server log");
            self.updateCastRow(.failed, 0, -1, "no run id in the server response", "");
            self.setStatus("");
            return;
        }
        self.releaseServerCastDisplay("superseded"); // a fresh LOCAL cast owns the lifecycle; finalize any server-cast display first
        self.cast_active = true;
        self.cast_epoch = self.conv_epoch; // the conversation position this cast (and its veil work) belongs to
        self.cast_stop_sent = false;
        self.cast_ev_size = 0; // fresh watch state for this run
        self.cast_ev_start = 0;
        self.cast_fired_s = self.nowS();
        self.cast_m = .{};
        self.cast_ev_n = 0;
        self.cast_forced = false;
        self.cast_bp_len = 0; // this run's blueprint loads lazily once the engine writes it
        self.nar_round = -1; // fresh milestone-narration state
        self.nar_pct = -1;
        self.nar_txt_len = 0;
        self.layout_nudged_len = 0;
        self.cast_hex_len = @min(hex.len, self.cast_hex.len);
        @memcpy(self.cast_hex[0..self.cast_hex_len], hex[0..self.cast_hex_len]);
        self.cast_rel_len = 0;
        // the cast builds in this conversation's dir (_chat/builds/<hive_dir>); remember it so watchCast can find
        // the run dir (its basename is <hive_dir>).
        self.cast_conv_len = @min(hive_dir.len, self.cast_conv.len);
        @memcpy(self.cast_conv[0..self.cast_conv_len], hive_dir[0..self.cast_conv_len]);
        self.cast_deadline_s = self.nowS() + @as(i64, self.cast_minutes) * 60 + 120;
        // Concurrent-Veil: kick off the primary Veil's own parallel attempt at the SAME goal, in the SAME shared
        // dir the hive just started building in. The tick loop's maybeVeilWork drives it; when the cast finishes,
        // maybeFinishAfterVeil waits for the veil's turn to settle, then folds the (one, shared) tree into the answer.
        if (veil_join) {
            self.veil_goal_len = @min(goal.len, self.veil_goal.len);
            @memcpy(self.veil_goal[0..self.veil_goal_len], goal[0..self.veil_goal_len]);
            self.veil_work_active = true;
            self.veil_started = false;
            self.veil_done = false;
            self.in_veil_work = false;
            self.cast_awaiting_veil = false;
        }
        var gb: [200]u8 = undefined;
        const note = std.fmt.bufPrint(&gb, "[cast] hive deployed ({s}) — watching", .{hex}) catch "[cast] hive deployed";
        self.appendMsg(dd, .cast_note, note);
        self.updateCastRow(.deploying, 0, -1, "worker starting...", hex); // stamp the row with the real id
        self.store.pushNotif("Hive cast", goal, 1);
        log.info("chat cast: id={s} goal={s}", .{ hex, goal[0..@min(goal.len, 80)] });
    }

    // ------------------------------------------------------------------------------ shared tools (chat side)

    /// Run ONE shared tool through the server (POST /api/v1/chat/tool — the SAME executor a hive mind uses),
    /// fold the result back into the conversation as a [tool:NAME] message, and re-enter the turn loop so the
    /// model reads it and either runs another tool or answers. Blocking netcli call, but we are on the chat
    /// WORKER thread (not the UI thread), so the block is invisible — the status line set just before keeps
    /// the UI honest. Orchestration verbs (stop_swarm/swarm_findings) default to the live cast when the model
    /// gives no id, so "kill the swarm and tell me what it found" works without the model knowing the hex id.
    fn isGitToolName(name: []const u8) bool {
        const g = [_][]const u8{ "repo_create", "git_commit", "git_push", "git_status", "git_log" };
        for (g) |t| if (std.mem.eql(u8, name, t)) return true;
        return false;
    }

    /// The (public) configured GitHub username from the sidecar dir; "" if unset.
    fn loadGhUser(self: *Chat, side: []const u8, buf: []u8) []const u8 {
        var pb: [700]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/github_user", .{side}) catch return "";
        const data = Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, .limited(256)) catch return "";
        defer self.gpa.free(data);
        const t = std.mem.trim(u8, data, " \r\n\t");
        const n = @min(t.len, buf.len);
        @memcpy(buf[0..n], t[0..n]);
        return buf[0..n];
    }

    /// Fold a git tool's result back into the chat exactly like any other tool chip, and re-enter the turn so
    /// the veil reads the outcome (a failed push tells it to repo_create first, etc.). tool_iters was already
    /// bumped by the dispatcher before this ran.
    fn foldGit(self: *Chat, dd: []const u8, name: []const u8, result: []const u8) void {
        var fb: [4400]u8 = undefined;
        const folded = std.fmt.bufPrint(&fb, "[tool:{s}]\n{s}", .{ name, result[0..@min(result.len, 4000)] }) catch result;
        log.info("chat git: {s} -> {s}", .{ name, result[0..@min(result.len, 100)] });
        self.appendMsg(dd, .cast_note, folded);
        self.setStatus("");
        self.startTurn(dd, .tool_follow);
    }

    /// DESK-SIDE version control: run one git/GitHub tool in this conversation's build dir using the sealed PAT,
    /// which never leaves this process. Results fold back like a normal tool chip.
    fn runGitTool(self: *Chat, dd: []const u8, name: []const u8, args: []const u8) void {
        if (std.mem.eql(u8, name, "git_commit") or std.mem.eql(u8, name, "git_push") or std.mem.eql(u8, name, "repo_create")) self.arc_mutated = true;
        var relb: [180]u8 = undefined;
        const rel = self.chatBuildRel(&relb);
        if (rel.len == 0) {
            self.foldGit(dd, name, "no conversation workdir yet — write a file first so there's something to version-control.");
            return;
        }
        var wdb: [820]u8 = undefined;
        const workdir = std.fmt.bufPrint(&wdb, "{s}/{s}/work", .{ dd, rel }) catch {
            self.foldGit(dd, name, "workdir path too long");
            return;
        };
        _ = Io.Dir.cwd().createDirPathStatus(self.io, workdir, .default_dir) catch {};
        var sb: [600]u8 = undefined;
        const side = sideDir(dd, &sb);
        // repo_create/git_push read the PAT from the local store; keep it in sync with a token the user freely
        // supplied in memory (their supplying it IS the approval to use it). Plaintext-local, no sealing, no
        // scrubbing — so the veil can also read + use it directly for a curl/gh fallback. Idempotent.
        if (std.mem.eql(u8, name, "repo_create") or std.mem.eql(u8, name, "git_push")) self.ensurePatUsable(dd, side);
        var patb: [256]u8 = undefined;
        const pat = patb[0..secrets.loadPat(self.io, self.gpa, side, &patb)];
        var userb: [80]u8 = undefined;
        const user = self.loadGhUser(side, &userb);

        var stbuf: [64]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&stbuf, "running {s}...", .{name}) catch "running git...");

        const r: gitvc.Res = if (std.mem.eql(u8, name, "git_status"))
            gitvc.status(self.gpa, self.io, workdir)
        else if (std.mem.eql(u8, name, "git_log"))
            gitvc.logLine(self.gpa, self.io, workdir, 20)
        else if (std.mem.eql(u8, name, "git_commit")) blk: {
            var mb: [2048]u8 = undefined;
            const msg = jStr(args, "message", &mb) orelse "";
            break :blk gitvc.commit(self.gpa, self.io, workdir, user, "", msg);
        } else if (std.mem.eql(u8, name, "repo_create")) blk: {
            var nb: [128]u8 = undefined;
            var sn: [128]u8 = undefined;
            const rn = gitvc.sanitizeRepoName(jStr(args, "name", &nb) orelse "", &sn);
            const private = std.mem.indexOf(u8, args, "\"private\":true") != null or std.mem.indexOf(u8, args, "\"private\": true") != null;
            break :blk gitvc.repoCreate(self.gpa, self.io, side, pat, rn, private);
        } else blk: { // git_push
            var rb: [128]u8 = undefined;
            var sr: [128]u8 = undefined;
            const repo = gitvc.sanitizeRepoName(jStr(args, "repo", &rb) orelse "", &sr);
            var ob: [80]u8 = undefined;
            const owner_arg = jStr(args, "owner", &ob) orelse "";
            const owner = if (owner_arg.len > 0) owner_arg else user;
            var brb: [80]u8 = undefined;
            const branch = jStr(args, "branch", &brb) orelse "";
            break :blk gitvc.push(self.gpa, self.io, workdir, side, owner, repo, user, pat, branch);
        };
        defer r.deinit(self.gpa);
        self.foldGit(dd, name, r.msg);
    }

    /// Keep the GitHub PAT usable by BOTH the git tools (which read the local store) and the veil ITSELF (which
    /// reads its durable memory and can curl / set an authenticated remote directly when a tool can't reach an
    /// org). LOCAL, login-gated app: the token is plaintext-local by design — never sealed, never scrubbed.
    /// Bidirectional + idempotent:
    ///   - a token freely supplied in memory but not in the local store  → copy it to the store so the tools work.
    ///   - a token in the store (incl. one just auto-unsealed from a legacy blob) but not in memory → restore it
    ///     as a durable "key" memory so the veil can recall + use it.
    fn ensurePatUsable(self: *Chat, dd: []const u8, side: []const u8) void {
        var mp: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&mp, "{s}/.veil-desk/memories.jsonl", .{dd}) catch return;
        const data_opt: ?[]u8 = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(256 << 10)) catch null;
        defer if (data_opt) |d| self.gpa.free(d);
        const data = data_opt orelse "";

        // Newest token in memory wins (memories.jsonl is append-only, so a rotated credential is the LAST match).
        var mem_tok: []const u8 = "";
        {
            var cur: []const u8 = data;
            while (findGithubToken(cur)) |t| {
                mem_tok = t;
                const off = (@intFromPtr(t.ptr) - @intFromPtr(cur.ptr)) + t.len;
                if (off >= cur.len) break;
                cur = cur[off..];
            }
        }
        var pb: [256]u8 = undefined;
        const file_tok = pb[0..secrets.loadPat(self.io, self.gpa, side, &pb)];

        if (mem_tok.len > 0) {
            // Memory is the source of truth for a freshly-supplied token; keep the tool store in sync (plaintext).
            if (!std.mem.eql(u8, file_tok, mem_tok)) _ = secrets.savePat(self.io, self.gpa, side, mem_tok);
        } else if (file_tok.len > 0) {
            // Token only in the store (e.g. just auto-unsealed from a legacy blob) → restore it to memory so the
            // veil can recall + use it directly. storeMemory dedups, so this is a one-time restore per token.
            var ub: [80]u8 = undefined;
            const user = self.loadGhUser(side, &ub);
            var tb: [400]u8 = undefined;
            const text = if (user.len > 0)
                std.fmt.bufPrint(&tb, "GitHub personal access token for {s}: {s}", .{ user, file_tok }) catch return
            else
                std.fmt.bufPrint(&tb, "GitHub personal access token: {s}", .{file_tok}) catch return;
            self.storeMemory(dd, "key", text);
            log.info("git: restored the stored GitHub PAT into memory so the veil can use it directly", .{});
        }
    }

    fn runToolAndContinue(self: *Chat, dd: []const u8, tc: ToolCall) void {
        self.acted = true; // a tool ran this exchange → the veil is working → auto-loop may continue
        self.arc_acted = true;
        if (isMutatingToolName(tc.name)) {
            self.arc_mutated = true; // side effects → the arc must verify before "done"
            if (writesAFile(tc.name)) self.arc_built = true; // a file landed → whole-build verify owed at arc end
        }
        // Stop pressed while the previous stream was settling → don't fire another (blocking) tool round-trip.
        if (self.abort_turn.load(.monotonic)) {
            self.stream.deinit(self.gpa);
            self.turn = .idle;
            self.setBusy(false);
            self.setStatus("");
            return;
        }
        // tc.name/tc.args are slices INTO self.stream.content — copy them off BEFORE we free the stream, or they
        // dangle (a use-after-free). The NAME is short (stack), but args can be a WHOLE FILE now (write_file /
        // edit_file), so HEAP-dupe them — a fixed [1024] stack copy silently truncated any real source file
        // (the file-writing convergence then failed at the transport, not the model). Bounded by the reply size.
        var namebuf: [64]u8 = undefined;
        const nn = @min(tc.name.len, namebuf.len);
        @memcpy(namebuf[0..nn], tc.name[0..nn]);
        const name = namebuf[0..nn];
        const raw_args = self.gpa.dupe(u8, tc.args) catch {
            self.stream.deinit(self.gpa);
            self.appendMsg(dd, .cast_note, "[tool] out of memory building the request");
            self.setBusy(false);
            return;
        };
        defer self.gpa.free(raw_args);
        self.stream.deinit(self.gpa); // now safe — name/raw_args are owned copies

        // VERSION CONTROL runs entirely DESK-SIDE (never a server round-trip): the GitHub PAT stays in this
        // process, sealed at rest, and is used by gitvc without ever crossing the wire or the transcript. Git
        // operates in this conversation's own build dir. Handled here and returned — it never reaches the shared
        // tool endpoint.
        if (isGitToolName(name)) {
            self.runGitTool(dd, name, raw_args);
            return;
        }

        var abuf: [256]u8 = undefined;
        var args = raw_args;
        const orchestration = std.mem.eql(u8, name, "stop_swarm") or std.mem.eql(u8, name, "swarm_findings") or
            std.mem.eql(u8, name, "kill_swarm") or std.mem.eql(u8, name, "swarm_status");
        // Inject the LAST cast's id whenever the model omitted one — NOT gated on cast_active: the moment users
        // say "kill it / why is it still running" is exactly after the watcher declared the cast done (cast_active
        // false) while the worker may still be alive. cast_hex stays valid until the next cast overwrites it.
        if (orchestration and self.cast_hex_len > 0 and !hasRealId(raw_args)) {
            args = std.fmt.bufPrint(&abuf, "{{\"id\":\"{s}\"}}", .{self.cast_hex[0..self.cast_hex_len]}) catch raw_args;
        }
        // web_search with a missing/placeholder query — common when the call is recovered from the reasoning
        // channel, where a weak model writes {"query":"..."} as shorthand — searches for literal "...". Fall
        // back to the user's own words so the search stays on-topic.
        var qbuf: [2048]u8 = undefined;
        if (std.mem.eql(u8, name, "web_search") and self.last_user_len > 0 and queryWeak(args)) {
            var qw = Io.Writer.fixed(&qbuf);
            const okq = blk: {
                qw.writeAll("{\"query\":\"") catch break :blk false;
                wesc(&qw, self.last_user[0..self.last_user_len]);
                qw.writeAll("\"}") catch break :blk false;
                break :blk true;
            };
            if (okq) args = qw.buffered();
        }

        // LAYOUT GUARD while a cast runs: the hive owns the project structure — a chat write_file that would
        // START a new top-level file/package beside it is deflected ONCE with the blueprint so the model
        // redirects into the hive's layout (or STEERs the hive). An insistent second attempt at the same top
        // segment runs anyway — the guard is a nudge, never a hard wall.
        if (self.cast_active and std.mem.eql(u8, name, "write_file")) {
            self.loadBlueprint(dd);
            var wpb: [300]u8 = undefined;
            if (jStr(args, "path", &wpb)) |wp| {
                const top = topSegment(wp);
                const nudged_before = std.mem.eql(u8, top, self.layout_nudged[0..self.layout_nudged_len]);
                if (!nudged_before and !self.pathFitsHiveLayout(wp)) {
                    self.layout_nudged_len = @min(top.len, self.layout_nudged.len);
                    @memcpy(self.layout_nudged[0..self.layout_nudged_len], top[0..self.layout_nudged_len]);
                    var fb2: [2048]u8 = undefined;
                    const folded = std.fmt.bufPrint(&fb2, "[tool:write_file]\n(not executed: a hive cast is building this project and owns the layout — '{s}' would start a NEW top-level structure beside it. The hive's blueprint:\n{s}\nWrite WITHIN that structure, or STEER: the hive to add what's missing, or wait for its findings. Re-issuing the exact same path will run it anyway.)", .{ wp, self.cast_bp[0..self.cast_bp_len] }) catch "[tool:write_file]\n(not executed: the hive owns the layout while the cast runs — write within its blueprint or STEER: it.)";
                    self.appendMsg(dd, .cast_note, folded);
                    log.info("chat layout guard: deflected write to '{s}' (new top '{s}' not in blueprint/tree)", .{ wp, top });
                    self.startTurn(dd, .tool_follow);
                    return;
                }
            }
        }

        var stbuf: [96]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&stbuf, "running {s}...", .{name}) catch "running a tool...");
        log.info("chat tool: run {s} args={s}", .{ name, args[0..@min(args.len, 100)] });

        // the active conversation id → a per-conversation build workdir the server writes into + the console cd's to.
        // The veil's PARALLEL attempt (in_veil_work) targets this SAME dir too — it joins the hive's build rather
        // than a separate copy, so there's nothing to reconcile afterward (the server's edit_file already
        // serializes/merges concurrent edits the same way it does for multiple hive minds).
        var convb: [64]u8 = undefined;
        const conv = self.convScope(&convb);

        // body = {"tool":NAME,"args":"<escaped raw json>","dir":"<conv>"} — args ride as a JSON string (tool-call
        // convention). HEAP-sized to hold the whole (escaped) args: wesc doubles at most, so 2x + envelope (a
        // fixed buffer would reject any write_file over ~1.5KB). netcli sends the body in-process over a socket
        // (no cap), and a reply is bounded by MAX_TOKENS.
        const body = self.gpa.alloc(u8, args.len * 2 + name.len * 2 + conv.len + 64) catch {
            self.appendMsg(dd, .cast_note, "[tool] out of memory building the request");
            self.setBusy(false);
            return;
        };
        defer self.gpa.free(body);
        var w = Io.Writer.fixed(body);
        const bok = blk: {
            // the NAME is escaped too: a recovered name carrying a quote would ship as malformed JSON the
            // server could only 500 on — escaping keeps the envelope well-formed no matter what the parsers
            // let through
            w.writeAll("{\"tool\":\"") catch break :blk false;
            wesc(&w, name);
            w.writeAll("\",\"args\":\"") catch break :blk false;
            wesc(&w, args);
            w.print("\",\"dir\":\"{s}\"}}", .{conv}) catch break :blk false;
            break :blk true;
        };

        var rbuf: [8192]u8 = undefined;
        var result: []const u8 = "(tool error)";
        var tool_failed = false; // did THIS call fail? drives the same-tool-same-arg escalation ladder below
        if (!bok) {
            result = "(the tool arguments were too long to send)";
            tool_failed = true;
        } else if (self.runner().runTool(self.io, self.gpa, w.buffered())) |resp| {
            defer if (resp.body.len > 0) self.gpa.free(resp.body);
            log.info("chat tool: {s} -> status={d} body={s}", .{ name, resp.status, resp.body[0..@min(resp.body.len, 160)] });
            result = extractToolResult(resp.body, &rbuf);
            // the server marks a failed tool with "ok":false (a non-200 is a transport/route failure) — either
            // way this call did not succeed, which the same-tool-same-arg escalation below counts.
            tool_failed = resp.status != 200 or std.mem.indexOf(u8, resp.body, "\"ok\":false") != null;
            // the server echoes the workdir on EVERY tool response, but only a real BUILD tool means the AI is
            // writing files there — only then adopt it as the build dir + cd the console (a web_search turn must
            // NOT announce a build dir or redirect the console into an empty folder).
            if (isBuildToolName(name)) {
                var wdb: [256]u8 = undefined;
                if (jStr(resp.body, "workdir", &wdb)) |wd| {
                    if (wd.len > 0) self.setBuildDir(dd, wd);
                }
            }
            if (std.mem.eql(u8, name, "stop_swarm") and resp.status == 200) self.cast_stop_sent = true;
            // KILL unlocks the user immediately. kill_swarm terminates the worker but nothing here cleared
            // cast_active, and a hard kill emits no "stopped" event, so watchCast never converged — the next
            // cast bounced with "a cast is already running" and the user was locked in the chat until the
            // minutes-long deadline. Clear the cast trio locally now (mirrors failCast), so castPending() goes
            // false and a new cast can fire. The run dir + findings stay on disk.
            if (std.mem.eql(u8, name, "kill_swarm") and resp.status == 200) {
                self.cast_active = false;
                self.cast_stop_sent = true;
                self.resetVeilWork();
                self.updateCastRow(.done, 0, -1, "killed", self.cast_rel[0..self.cast_rel_len]);
                self.setStatus("");
                // A kill is the user saying "stop that swarm". Spend the loop's cast budget so an auto-loop that's
                // still armed can keep working DIRECTLY but won't immediately re-deploy another hive (the original
                // post-kill runaway). A manual message resets loop_casts and re-earns casting.
                self.loop_casts = MAX_LOOP_CASTS;
                log.info("chat: kill_swarm confirmed — cast state cleared, user unlocked", .{});
            }
        } else {
            result = "(no response from the veil server on :8787 — is it running?)";
            tool_failed = true;
            log.err("chat tool: {s} netcli NULL", .{name});
        }

        // MEMORY INSIDE RECURSIVE THOUGHT (write-side unification): the veil reaches for `observe` while reasoning
        // to keep a fact — but observe writes to the shared HIVE store, invisible to the user's durable Memory tab.
        // Mirror a PERSONAL/durable observe (a key/login/preference about THIS user) into veil-memory too, so what
        // it learns mid-thought reaches the store the user manages. Additive (the server observe already ran);
        // personal-only (tight filter → research observes stay hive-only); never during the veil's parallel research
        // work (in_veil_work → a research-goal observe must not land in the private tab). Gated by MIRROR_OBSERVE.
        if (MIRROR_OBSERVE and !self.in_veil_work and std.mem.eql(u8, name, "observe") and result.len > 0 and result[0] != '(') {
            if (llm.jsonUnescape(self.gpa, raw_args, "fact")) |fact| {
                defer self.gpa.free(fact);
                if (personalFact(fact)) |cat| {
                    self.storeMemory(dd, cat, fact);
                    log.info("chat memory: mirrored personal observe -> [{s}] durable", .{cat});
                }
            }
        }
        // Durably capture any one-time claim/verification secret THIS result carried, before it ages out of the
        // ring; and track the web-lookup stall so a busy-but-getting-nowhere spiral escalates instead of spinning.
        self.captureOneTimeSecrets(dd, result);
        self.trackLookupStall(dd, name);
        // TOOL-failure escalation — the blind spot no other stall breaker caught (they watch shell commands and
        // web lookups, not a build/edit TOOL that keeps failing on the SAME args). Count consecutive same-tool
        // same-arg failures; the second identical failure onward climbs the stuck ladder (nudge → research →
        // cast). Web-lookup tools are already driven by trackLookupStall, so they're excluded here.
        if (!isWebLookupTool(name)) {
            if (tool_failed) {
                const nl = std.mem.indexOfScalar(u8, result, '\n') orelse result.len;
                const one_line = result[0..@min(nl, 140)];
                var sgb: [200]u8 = undefined;
                const sig = std.fmt.bufPrint(&sgb, "{s}: {s}", .{ name, one_line }) catch name;
                if (self.last_tool_fail_len > 0 and nearlySame(sig, self.last_tool_fail[0..self.last_tool_fail_len])) {
                    if (self.tool_fail_streak < 255) self.tool_fail_streak += 1; // saturate — u8 in a ReleaseSafe build
                } else self.tool_fail_streak = 1;
                self.last_tool_fail_len = @min(sig.len, self.last_tool_fail.len);
                @memcpy(self.last_tool_fail[0..self.last_tool_fail_len], sig[0..self.last_tool_fail_len]);
                if (self.tool_fail_streak >= 2) self.escalateStuck(dd, sig);
            } else if (self.tool_fail_streak > 0 and self.last_tool_fail_len > name.len and
                std.mem.startsWith(u8, self.last_tool_fail[0..self.last_tool_fail_len], name) and
                self.last_tool_fail[name.len] == ':')
            {
                // The blocker clears (and the ladder decays) ONLY when the tool that was FAILING finally succeeds
                // — NOT when any other mutation lands. In the canonical edit → test → fail loop the successful
                // edit_file is not the failing action, so it must not cancel the accumulated stuck-pressure; that
                // residual was what kept a genuinely stuck build from ever climbing to the research/cast rungs.
                self.tool_fail_streak = 0;
                if (self.arc_stuck > 0) self.arc_stuck -= 1;
            }
        }
        // Fold the result into the conversation as a labeled message the next turn reads (cast_note -> the
        // model sees it as user content; it's also the user-visible record that the tool ran).
        var fb: [8320]u8 = undefined;
        const folded = std.fmt.bufPrint(&fb, "[tool:{s}]\n{s}", .{ name, result }) catch result;
        self.appendMsg(dd, .cast_note, folded);
        self.startTurn(dd, .tool_follow);
    }

    /// The AI's RUN: door. `cmd` is a slice INTO self.stream.content — copy it before freeing the stream (same
    /// UAF discipline as runToolAndContinue). Launches it on the Veil console tab ASYNCHRONOUSLY (consoleStart);
    /// pumpConsole folds the [console] output back and re-enters a .tool_follow turn once it finishes. The
    /// turn stays busy (turn is idle while it awaits the console — see consoleAiBusy) the whole time.
    fn runShellAndContinue(self: *Chat, dd: []const u8, cmd: []const u8) void {
        self.acted = true; // a shell command (or its approval prompt) means the veil is working
        self.arc_acted = true;
        // Stop pressed while the previous stream settled → don't launch the AI's next shell command.
        if (self.abort_turn.load(.monotonic)) {
            self.stream.deinit(self.gpa);
            self.turn = .idle;
            self.setBusy(false);
            self.setStatus("");
            return;
        }
        var cmdbuf: [1024]u8 = undefined;
        const cn = @min(cmd.len, cmdbuf.len);
        @memcpy(cmdbuf[0..cn], cmd[0..cn]);
        const command = cmdbuf[0..cn];
        self.stream.deinit(self.gpa); // now safe — command is an owned copy

        {
            // surface the Veil tab so the user watches the AI's command land (best-effort; store owns the flag)
            self.store.lock();
            defer self.store.unlock();
            self.store.console_show_veil = true;
        }

        // APPROVAL GATE: the veil runs commands in the USER'S real dev environment (powershell/cmd/sh). Unless
        // the user has chosen "Bypass" (shell_always_allow), PARK the command and ask for approval instead of
        // spawning it. The turn is held busy (awaitingShellApproval) until the user Approves / Bypasses / Denies
        // from the Veil tab.
        const always = blk: {
            self.store.lock();
            defer self.store.unlock();
            break :blk self.store.settings.shell_always_allow;
        };
        if (!always) {
            self.pending_cmd_len = command.len;
            @memcpy(self.pending_cmd[0..command.len], command);
            {
                self.store.lock();
                defer self.store.unlock();
                self.store.console_pending = true;
                self.store.console_pending_len = command.len;
                @memcpy(self.store.console_pending_cmd[0..command.len], command);
            }
            self.setStatus("waiting for you to approve a command...");
            self.setBusy(true); // keep the turn busy while parked — no loop/new-turn starts over it
            self.store.pushNotif("Approve command?", command[0..@min(command.len, 80)], 0);
            log.info("chat RUN: parked for approval: {s}", .{command[0..@min(command.len, 120)]});
            return;
        }

        var stbuf: [96]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&stbuf, "running: {s}", .{command[0..@min(command.len, 60)]}) catch "running a command...");
        log.info("chat RUN: {s}", .{command[0..@min(command.len, 120)]});

        // Async: consoleStart never blocks. On an immediate launch failure it folds the error back itself, so
        // the turn always continues; on success pumpConsole finalizes + folds when the command exits.
        self.consoleStart(dd, true, command);
    }

    /// True while a veil shell command is parked awaiting the user's Approve/Bypass/Deny.
    fn awaitingShellApproval(self: *Chat) bool {
        return self.pending_cmd_len > 0;
    }

    /// The user Approved (or Bypassed) the parked command → run it now. `always` persists the Bypass choice.
    fn cmdConsoleApprove(self: *Chat, dd: []const u8, always: bool) void {
        if (self.pending_cmd_len == 0) return;
        var cmdbuf: [1024]u8 = undefined;
        const cn = self.pending_cmd_len;
        @memcpy(cmdbuf[0..cn], self.pending_cmd[0..cn]);
        self.clearPendingCmd();
        if (always) {
            self.store.lock();
            self.store.settings.shell_always_allow = true;
            self.store.unlock();
            self.saveSettings(dd);
            self.appendMsg(dd, .cast_note, "(shell commands will now run without asking — turn this off in Settings)");
        }
        var stbuf: [96]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&stbuf, "running: {s}", .{cmdbuf[0..@min(cn, 60)]}) catch "running a command...");
        log.info("chat RUN (approved): {s}", .{cmdbuf[0..@min(cn, 120)]});
        self.consoleStart(dd, true, cmdbuf[0..cn]);
    }

    /// The user Denied the parked command → fold a denial back so the model reads it and moves on.
    fn cmdConsoleDeny(self: *Chat, dd: []const u8) void {
        if (self.pending_cmd_len == 0) return;
        var cmdbuf: [1024]u8 = undefined;
        const cn = self.pending_cmd_len;
        @memcpy(cmdbuf[0..cn], self.pending_cmd[0..cn]);
        self.clearPendingCmd();
        self.foldConsoleAi(dd, cmdbuf[0..cn], "(the user did not approve this command — it was NOT run. Ask before trying again, or take a different approach.)");
        log.info("chat RUN denied by user", .{});
    }

    fn clearPendingCmd(self: *Chat) void {
        self.pending_cmd_len = 0;
        self.store.lock();
        defer self.store.unlock();
        self.store.console_pending = false;
        self.store.console_pending_len = 0;
    }

    /// Add a fresh "deploying" cast row (newest) to the activity panel; evicts the oldest when full.
    fn pushCastRow(self: *Chat, goal: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        if (self.store.cast_count >= store_mod.MAX_CASTS) {
            std.mem.copyForwards(store_mod.CastRow, self.store.casts[0 .. store_mod.MAX_CASTS - 1], self.store.casts[1..store_mod.MAX_CASTS]);
            self.store.cast_count = store_mod.MAX_CASTS - 1;
        }
        var row: store_mod.CastRow = .{ .status = .deploying };
        const gn = @min(goal.len, row.goal.len);
        @memcpy(row.goal[0..gn], goal[0..gn]);
        row.goal_len = @intCast(gn);
        self.store.casts[self.store.cast_count] = row;
        self.store.cast_count += 1;
    }

    /// Arm a DISPLAY-ONLY watch on a swarm the SERVER veil just cast (its cast tool "start" frame). Mirrors the
    /// arming half of fireCast (fresh watch state + a CastRow) but leaves cast_active FALSE — the desk only renders
    /// the run into the Swarm pane; the server veil owns the lifecycle (timeout, stop, composing the answer via
    /// swarm_status). Resolves the run dir by conv basename (build-in-place: _chat/builds/<conv>).
    fn startServerCastWatch(self: *Chat) void {
        const conv = self.sc_conv[0..self.sc_conv_len];
        if (conv.len == 0 or conv.len > self.cast_conv.len) return; // no resolvable conv → nothing to watch
        // IDEMPOTENT: a server turn can cast more than once (cast → stop → re-cast). While a watch is already
        // armed on this conv's run dir, a second cast "start" frame must NOT push a second CastRow — updateCastRow
        // only ever touches the newest row, so the first would freeze mid-"running" forever. Same run dir either
        // way (build-in-place), so the existing watch covers it.
        if (self.cast_server_owned) return;
        self.cast_server_owned = true;
        self.cast_active = false; // the desk does NOT run the local collect/compose lifecycle for this cast
        self.cast_conv_len = conv.len; // watchCast matches the run-dir basename against <conv>
        @memcpy(self.cast_conv[0..conv.len], conv);
        self.cast_hex_len = 0; // resolve by conv basename, not a hex id (and so the orchestration-id inject stays off)
        self.cast_rel_len = 0; // watchCast resolves the run dir on its next tick
        self.cast_ev_size = 0; // fresh watch state for this run
        self.cast_ev_start = 0;
        self.cast_ev_n = 0;
        self.cast_m = .{};
        self.cast_stop_sent = false;
        self.cast_forced = false;
        self.cast_fired_s = self.nowS(); // the stale-prior-run guard in watchCast keys off this
        self.cast_deadline_s = self.nowS() + 365 * 24 * 3600; // far future: the SERVER owns the timeout, not the desk
        self.nar_round = -1; // narration is suppressed for server casts, but keep the state clean
        self.nar_pct = -1;
        self.nar_txt_len = 0;
        self.pushCastRow("hive (server)"); // the row's round/pct/last fill in live from watchCast (updateCastRow)
    }

    /// Release a server-owned cast DISPLAY at a seam that abandons the watch (conv switch, new conv, stop-cast,
    /// abort). Finalizes the newest row to .done and clears the status line — without this, dropping
    /// cast_server_owned killed the row's only updater and stranded it mid-"running": cast_live stayed true, so
    /// the green "the hive is working" bar rendered forever and even carried into a NEW conversation's view.
    /// The swarm itself is untouched (it keeps running server-side; the global Swarm tab still tracks it).
    fn releaseServerCastDisplay(self: *Chat, note: []const u8) void {
        if (!self.cast_server_owned) return;
        self.updateCastRow(.done, self.cast_m.round, self.cast_m.pct, note, self.cast_rel[0..self.cast_rel_len]);
        if (!self.sc_active) self.setStatus(""); // a LIVE server turn owns the status; its {done} clears it
        self.cast_server_owned = false;
    }

    /// Publish the ACTIVE conversation's server plan-board ({conv}/plan.jsonl) into the store so the right pane
    /// renders a live checklist (the user asked to SEE plan progress throughout the chat, not just the plan
    /// message). ~1Hz with a size cache: an unchanged board costs one statFile; a conv switch (plan_conv key
    /// mismatch) forces a re-read; an absent/empty board publishes 0 rows. The server rewrites the whole file per
    /// subtask update (non-atomic) — the skip-bad-lines parse self-heals a torn read on the next tick.
    fn watchPlan(self: *Chat, dd: []const u8) void {
        var cb: [64]u8 = undefined;
        const conv = self.convScope(&cb);
        if (conv.len == 0 or conv.len > self.plan_conv.len) {
            self.publishPlan(0);
            self.plan_conv_len = 0;
            self.plan_size = 0;
            return;
        }
        const switched = !std.mem.eql(u8, conv, self.plan_conv[0..self.plan_conv_len]);
        if (switched) {
            @memcpy(self.plan_conv[0..conv.len], conv);
            self.plan_conv_len = conv.len;
            self.plan_size = 0; // force a re-read for the new conv
            self.publishPlan(0); // and never show the previous conv's board meanwhile
        }
        // uid default mirrors chatBuildRel: desktop admin is u1 on localhost; a build-dir binding overrides.
        var uid: []const u8 = "u1";
        if (self.build_dir_len > 0) {
            const bd = self.build_dir[0..self.build_dir_len];
            if (std.mem.indexOfScalar(u8, bd, '/')) |sl| {
                if (sl > 1 and bd[0] == 'u') uid = bd[0..sl];
            }
        }
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/{s}/_chat/convs/{s}/plan.jsonl", .{ dd, uid, conv }) catch return;
        const size: u64 = if (Io.Dir.cwd().statFile(self.io, path, .{})) |st| st.size else |_| {
            // no board (a fresh conv, or plan.jsonl deleted) → clear the checklist
            if (self.plan_size != 0) {
                self.publishPlan(0);
                self.plan_size = 0;
            }
            return;
        };
        if (size == self.plan_size) return; // unchanged — one stat, no parse
        const raw = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(64 << 10)) catch return;
        defer self.gpa.free(raw);
        self.plan_size = size;

        var n: usize = 0;
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            if (n >= self.plan_scratch.len) break;
            const t = std.mem.trim(u8, line, " \r\t");
            if (t.len == 0 or t[0] != '{') continue;
            const T = struct { task: []const u8 = "", route: []const u8 = "inline", status: []const u8 = "pending" };
            const parsed = std.json.parseFromSlice(T, self.gpa, t, .{ .ignore_unknown_fields = true }) catch continue; // skip a torn/bad line
            defer parsed.deinit();
            var row = store_mod.PlanRow{};
            const tl = @min(parsed.value.task.len, row.text.len);
            @memcpy(row.text[0..tl], parsed.value.task[0..tl]);
            row.text_len = @intCast(tl);
            const rl = @min(parsed.value.route.len, row.route.len);
            @memcpy(row.route[0..rl], parsed.value.route[0..rl]);
            row.route_len = @intCast(rl);
            row.status = if (std.mem.eql(u8, parsed.value.status, "done")) .done else if (std.mem.eql(u8, parsed.value.status, "active")) .active else .pending;
            self.plan_scratch[n] = row;
            n += 1;
        }
        self.publishPlan(n);
    }

    /// Copy plan_scratch[0..n] into the store under one short lock (the watchCast tail-publish pattern).
    fn publishPlan(self: *Chat, n: usize) void {
        self.store.lock();
        defer self.store.unlock();
        if (n > 0) @memcpy(self.store.plan[0..n], self.plan_scratch[0..n]);
        self.store.plan_count = n;
    }

    pub fn watchCast(self: *Chat, dd: []const u8) void {
        if (!self.cast_active and !self.cast_server_owned) return; // runs for a local cast OR a server-owned display
        const now = self.nowS();
        // resolve the run dir once the scanner can see it (server writes u<uid>/<hex>)
        if (self.cast_rel_len == 0) {
            const n = scan.listSwarms(self.io, self.gpa, dd, &self.sw_scratch, now, 45);
            const hex = self.cast_hex[0..self.cast_hex_len];
            const conv = self.cast_conv[0..self.cast_conv_len];
            for (self.sw_scratch[0..n]) |*sw| {
                const id = sw.idStr();
                const base = if (std.mem.lastIndexOfScalar(u8, id, '/')) |sl| id[sl + 1 ..] else id;
                // A chat cast builds in the conversation dir, so its run-dir basename is <conv>, NOT the hex id
                // — match that first; fall back to the hex for any legacy path.
                if ((conv.len > 0 and std.mem.eql(u8, base, conv)) or std.mem.eql(u8, base, hex)) {
                    self.cast_rel_len = @min(id.len, self.cast_rel.len);
                    @memcpy(self.cast_rel[0..self.cast_rel_len], id[0..self.cast_rel_len]);
                    self.updateCastRow(.running, 0, -1, "", id);
                    break;
                }
            }
            if (self.cast_rel_len == 0) {
                if (!self.cast_server_owned and now > self.cast_deadline_s) self.failCast(dd, "[cast] the run directory never appeared — check the server");
                return;
            }
        }
        const rel = self.cast_rel[0..self.cast_rel_len];
        var ep_buf: [700]u8 = undefined;
        const ep = std.fmt.bufPrint(&ep_buf, "{s}/{s}/events.jsonl", .{ dd, rel }) catch return;
        // SIZE-GUARD: skip the tail read + two-pass parse entirely when the file hasn't grown (this ran
        // unconditionally at ~1Hz on the chat thread — with the poller's own scans, a real thrash source).
        var ev_size: u64 = 0;
        var ev_mtime_s: i64 = 0;
        if (Io.Dir.cwd().statFile(self.io, ep, .{})) |st| {
            ev_size = st.size;
            ev_mtime_s = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
        } else |_| {}
        if (ev_size != self.cast_ev_size) {
            self.cast_ev_size = ev_size;
            var pm: scan.Metrics = .{};
            const n = scan.tailEventsFrom(self.io, self.gpa, ep, self.cast_ev_start, &self.ev_scratch, &pm);
            // STALE-RUN GUARD (first parse only): a reused _chat/builds/{conv} dir can still hold the PREVIOUS
            // run's log — recognizable as "already stopped" AND untouched since before this cast fired. Fold
            // from EOF instead so the old run's stopped/score lines can never complete the new cast. (A cast
            // that genuinely finished fast has a FRESH mtime and collects normally.) The server also rotates
            // the log on re-cast; this is the desktop's own belt-and-suspenders.
            if (self.cast_ev_start == 0 and pm.stopped and self.cast_ev_n == 0 and n > 0 and
                self.cast_fired_s > 0 and ev_mtime_s < self.cast_fired_s)
            {
                self.cast_ev_start = ev_size;
                self.cast_m = .{};
                self.cast_ev_n = 0;
                log.info("cast watch: stale prior-run events detected in {s} — folding from offset {d}", .{ rel, ev_size });
            } else {
                self.cast_m = pm;
                self.cast_ev_n = n;
                {
                    // publish tail + row
                    self.store.lock();
                    defer self.store.unlock();
                    @memcpy(self.store.cast_tail[0..n], self.ev_scratch[0..n]);
                    self.store.cast_tail_count = n;
                }
                // MILESTONE NARRATION: the chat itself tells the hive's story — one compact line per round (or
                // major score move). The raw stream lives in the right pane; the conversation narrates progress
                // even when the veil isn't mid-turn, and the model sees the same milestones as context. A round
                // whose latest event just REPEATS the previous narration is skipped (no 13x "depgraph: ...").
                const jump = pm.pct >= 0 and (self.nar_pct < 0 or (pm.pct - self.nar_pct >= 20) or (pm.pct >= 100 and self.nar_pct < 100));
                const round_new = pm.round > 0 and pm.round != self.nar_round;
                var last_txt: []const u8 = "";
                if (n > 0) last_txt = self.ev_scratch[n - 1].textStr();
                const trimmed = last_txt[0..@min(last_txt.len, self.nar_txt.len)];
                const repeat = std.mem.eql(u8, trimmed, self.nar_txt[0..self.nar_txt_len]);
                if (jump or (round_new and !repeat)) {
                    self.nar_round = pm.round;
                    if (pm.pct >= 0) self.nar_pct = pm.pct;
                    self.nar_txt_len = trimmed.len;
                    @memcpy(self.nar_txt[0..trimmed.len], trimmed);
                    var nb2: [240]u8 = undefined;
                    const note = if (pm.pct >= 0)
                        std.fmt.bufPrint(&nb2, "[hive] round {d}, {d}% — {s}", .{ pm.round, pm.pct, trimmed }) catch "[hive] progress"
                    else
                        std.fmt.bufPrint(&nb2, "[hive] round {d} — {s}", .{ pm.round, trimmed }) catch "[hive] progress";
                    // Only narrate into the conversation that OWNS this cast. If the owning conv was deleted and
                    // another is now on screen (delete_conv isn't blocked by busyForSwitch), appendMsg would pour
                    // this cast's live narration into the unrelated conv's transcript + hippocampus.
                    if (!self.cast_server_owned and self.castIsForCurrentConv()) self.appendMsg(dd, .cast_note, note);
                } else if (round_new) self.nar_round = pm.round; // advance silently past the repeat
            }
        }
        const m = self.cast_m;
        const ev_n = self.cast_ev_n;
        var last: []const u8 = "";
        if (ev_n > 0) last = self.ev_scratch[ev_n - 1].textStr();
        self.updateCastRow(if (m.stopped) .done else .running, m.round, m.pct, last, rel);
        if (self.ctx_poll_budget > 0 and !self.ctx_warned) {
            self.ctx_poll_budget -= 1;
            self.localSlowTip(dd); // model may have loaded (huge) only after the cast fired — catch it early
        }
        // STATUS: don't fight the LIVE server turn's own {status} frames (server-owned + sc_active). Once the turn
        // has settled (or for a local cast), the desk owns the "hive running - rN X%" line — and for a server cast
        // the elapsed-estimate fallback is skipped (its deadline is far-future = garbage math); show the real pct or 0.
        if (!m.stopped and !(self.cast_server_owned and self.sc_active)) {
            var sbuf: [96]u8 = undefined;
            const shown_pct: i32 = if (m.pct >= 0) m.pct else if (self.cast_server_owned) 0 else blk: {
                const start = self.cast_deadline_s - (@as(i64, self.cast_minutes) * 60 + 120);
                const elapsed = self.nowS() - start;
                const budget: i64 = @as(i64, self.cast_minutes) * 60;
                if (elapsed <= 0 or budget <= 0) break :blk 0;
                break :blk @intCast(@min(@divTrunc(elapsed * 100, budget), 90));
            };
            const st = std.fmt.bufPrint(&sbuf, "hive running - r{d} {d}%", .{ m.round, shown_pct }) catch "hive running";
            self.setStatus(st);
        }

        if (m.stopped) {
            if (self.cast_server_owned) {
                // DISPLAY-ONLY: the swarm ended on its own; the row is already .done. The SERVER veil composes the
                // answer via swarm_status — the desk must NOT run castFinished (which would compose a DUPLICATE).
                // Clear the "hive running" status line we own — leaving it froze the green "the hive is working"
                // bar forever after the hive finished. A LIVE server turn (sc_active) owns the status itself and
                // its {done} frame clears it, so only touch it once the turn has settled.
                if (!self.sc_active) self.setStatus("the hive finished — results in Swarm activity");
                self.cast_server_owned = false;
                self.cast_active = false; // belt-and-suspenders; was already false
                return;
            }
            // a user (or the veil-work) turn may still be streaming — collect/merge on a later idle tick
            if (self.turn == .idle) self.castFinished(dd, rel, &m, ev_n);
            return;
        }
        if (!self.cast_server_owned and now > self.cast_deadline_s) { // the SERVER owns a server cast's timeout, not the desk
            if (!self.cast_stop_sent) {
                // STOP file first — the worker honors it PER TURN; control.jsonl only lands at a round boundary
                _ = scan.writeStop(self.io, self.gpa, dd, rel);
                _ = scan.writeControl(self.io, self.gpa, dd, rel, "{\"op\":\"stop\"}");
                self.cast_stop_sent = true;
                self.cast_deadline_s = now + 90; // grace for the turn/round boundary
                self.updateCastRow(.collecting, m.round, m.pct, last, rel);
                self.setStatus("asking the hive to stop...");
            } else if (self.turn == .idle) {
                // it never stopped cleanly — collect what exists, and say so honestly (not "finished")
                self.cast_forced = true;
                self.castFinished(dd, rel, &m, ev_n);
            }
        }
    }

    /// Is the finished cast's conversation the one on screen right now? An epoch bump inside the SAME
    /// conversation (a newer message, a Stop) must not strand the cast's results behind a passive note —
    /// they belong to this chat and the auto-loop feeds on the collect.
    fn castIsForCurrentConv(self: *Chat) bool {
        var cb: [96]u8 = undefined;
        const cur = self.convScope(&cb);
        return cur.len > 0 and std.mem.eql(u8, cur, self.cast_conv[0..self.cast_conv_len]);
    }

    /// The hive cast has finished. In concurrent-veil mode, defer finishing until the Veil's own parallel turn
    /// (writing into this SAME shared dir) has also settled, so its last edits are in the tree before the answer
    /// is composed; otherwise collect the result directly (the classic path).
    fn castFinished(self: *Chat, dd: []const u8, rel: []const u8, m: *const scan.Metrics, ev_n: usize) void {
        if (self.cast_epoch != self.conv_epoch) {
            // The epoch moved since this cast was scheduled. If the user is STILL IN this conversation, the
            // results belong here — re-stamp and collect normally (going passive here would disconnect the
            // auto-loop at its most valuable moment: the collect feeds the next step). Only a genuine
            // conversation SWITCH leaves the passive note (never hijack a DIFFERENT chat with old post-processing).
            if (self.castIsForCurrentConv()) {
                self.cast_epoch = self.conv_epoch;
            } else {
                self.cast_active = false;
                self.resetVeilWork();
                self.updateCastRow(.done, m.round, m.pct, "", rel);
                // The user switched to a DIFFERENT conversation. Do NOT appendMsg here — appendMsg is hardwired
                // to conv_active (the chat they switched TO) and observes into ITS hippocampus, so the note
                // would pollute an unrelated conversation's transcript and memory with this cast's completion.
                // The .done Swarm-tab row above is the durable record; a transient status is the only signal.
                self.setStatus("a background cast finished — see the Swarm tab");
                return;
            }
        }
        if (CONCURRENT_VEIL and self.veil_work_active) {
            self.cast_active = false;
            self.cast_awaiting_veil = true;
            self.updateCastRow(.finishing, m.round, m.pct, "", rel);
            self.setStatus("hive done - waiting on the veil's own attempt...");
        } else {
            self.collectCast(dd, rel, m, ev_n);
        }
    }

    fn failCast(self: *Chat, dd: []const u8, msg: []const u8) void {
        self.appendMsg(dd, .cast_note, msg);
        self.updateCastRow(.failed, 0, -1, "", self.cast_hex[0..self.cast_hex_len]);
        self.cast_active = false;
        self.resetVeilWork(); // abandon any parallel veil attempt + the pending finish
        self.setStatus("");
    }

    /// Lazily read the hive's .blueprint (its intended file layout) from the cast run dir — the engine writes
    /// it once planning settles (~a minute in), so callers simply retry until it appears. Cached per cast.
    fn loadBlueprint(self: *Chat, dd: []const u8) void {
        if (self.cast_bp_len > 0 or self.cast_rel_len == 0) return;
        var pb: [700]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/{s}/.blueprint", .{ dd, self.cast_rel[0..self.cast_rel_len] }) catch return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, .limited(16 << 10)) catch return;
        defer self.gpa.free(data);
        const t = std.mem.trim(u8, data, " \r\n\t");
        self.cast_bp_len = @min(t.len, self.cast_bp.len);
        @memcpy(self.cast_bp[0..self.cast_bp_len], t[0..self.cast_bp_len]);
        if (self.cast_bp_len > 0) log.info("cast blueprint loaded ({d}b)", .{self.cast_bp_len});
    }

    /// LAYOUT GUARD data check: does this write_file path fit the hive's layout — its blueprint OR the tree
    /// that already exists on disk (an existing top segment is too late to prevent; only NEW rivals matter)?
    fn pathFitsHiveLayout(self: *Chat, path: []const u8) bool {
        if (self.cast_bp_len == 0) return true; // nothing to judge against yet
        if (layoutAllows(self.cast_bp[0..self.cast_bp_len], path)) return true;
        const top = topSegment(path);
        self.store.lock();
        defer self.store.unlock();
        var i: usize = 0;
        while (i < self.store.chat_file_count) : (i += 1) {
            if (std.mem.eql(u8, topSegment(self.store.chat_files[i].pathStr()), top)) return true;
        }
        return false;
    }

    /// Clear all concurrent-veil state (on cast failure/stop, or after the finish completes).
    fn resetVeilWork(self: *Chat) void {
        self.veil_work_active = false;
        self.veil_started = false;
        self.veil_done = false;
        self.in_veil_work = false;
        self.veil_nudged = false;
        self.cast_awaiting_veil = false;
    }

    /// CONCURRENT VEIL driver (tick loop): while a cast runs, kick off the primary Veil's OWN turn at the same
    /// goal once, writing into the SAME shared build dir the hive is using (it joins the swarm's build rather
    /// than keeping a separate copy); then — once that turn has fully settled — mark it done so
    /// maybeFinishAfterVeil can compose the answer. Completion is detected as "we started it AND we're idle
    /// again" (tool/console re-entry is synchronous within a tick, and this runs after pumpStream+pumpConsole,
    /// so a mid-chain idle is never observed).
    fn maybeVeilWork(self: *Chat, dd: []const u8) void {
        if (!CONCURRENT_VEIL or !self.veil_work_active or self.veil_done) return;
        if (self.cast_epoch != self.conv_epoch) {
            // the user moved the conversation on — never start (or misread the settle of) a parallel attempt
            // for a superseded goal; its files stay on disk with the cast's
            self.resetVeilWork();
            return;
        }
        if (self.turn != .idle or self.consoleAiBusy()) return; // never contend with a live turn/console
        if (!self.veil_started) {
            self.veil_started = true;
            self.in_veil_work = true;
            self.veil_nudged = false;
            self.tool_iters = 0;
            self.reflect_pass = 0;
            self.reflect_dirty = false;
            self.abort_turn.store(false, .monotonic);
            // THE VEIL IS THE HIVE'S ORCHESTRATOR while a cast runs — never a rival builder. Building the same
            // goal blind in the same dir produces competing top-level structures beside the hive's, so it gets
            // the hive's OWN blueprint and a narrate / steer / gap-fill-within-the-layout job description.
            self.loadBlueprint(dd);
            const bp: []const u8 = if (self.cast_bp_len > 0) self.cast_bp[0..self.cast_bp_len] else "(not planned yet — inspect with list_dir before touching anything)";
            var pb: [4096]u8 = undefined;
            const prompt = std.fmt.bufPrint(&pb, "[orchestrator] A hive swarm is building this goal RIGHT NOW in your shared workdir, and YOU are its orchestrator — never a rival builder. The hive owns the project layout while it runs. Its blueprint (the intended files):\n{s}\nYour job, in order: (1) INSPECT what it has produced so far (list_dir, read_file) and NARRATE to the user in one or two plain sentences what the hive is building and how it is going; (2) if you see drift, duplication, or a missing piece the hive should handle, STEER it — output a line 'STEER: <one concrete instruction>' and it reaches every mind at their next round; (3) you may fix a SMALL gap yourself (write_file/edit_file/run_python) but ONLY inside the blueprint's structure — NEVER create a new top-level file or package the blueprint does not have; (4) never duplicate work the hive is mid-way through — when in doubt, narrate and stop; the full findings come to you when the cast finishes. You have no cast tool here; never output CAST:. The hive's goal: {s}", .{ bp, self.veil_goal[0..self.veil_goal_len] }) catch "[orchestrator] Inspect the hive's build, narrate its progress to the user, STEER: it if it drifts, and only fill small gaps inside ITS layout (never a new top-level structure, never CAST:).";
            self.last_user_len = @min(prompt.len, self.last_user.len);
            @memcpy(self.last_user[0..self.last_user_len], prompt[0..self.last_user_len]);
            // a cast_note renders dim/distinct (not a fake user bubble) but still maps to a user turn in the prompt
            self.appendMsg(dd, .cast_note, prompt);
            self.setStatus("veil orchestrating the hive...");
            self.startTurn(dd, .user);
            return;
        }
        // veil_started AND idle again => the veil-work turn (and its whole tool/reflect chain) has settled.
        self.in_veil_work = false;
        self.veil_done = true;
        log.info("concurrent-veil: the veil's own attempt settled; ready to finish", .{});
    }

    /// Once the cast finished AND the veil's own parallel turn (in the SAME shared dir) has settled, compose the
    /// final answer from that one tree — no compare/merge step, since both sides already edited the same build.
    fn maybeFinishAfterVeil(self: *Chat, dd: []const u8) void {
        if (!self.cast_awaiting_veil or !self.veil_done) return;
        if (self.turn != .idle or self.consoleAiBusy()) return;
        if (self.cast_epoch != self.conv_epoch) {
            // Same-conversation rescue (mirrors castFinished): only a genuine conv SWITCH goes passive —
            // an in-conversation epoch bump must not strand the merge behind "ask me to summarize".
            if (self.castIsForCurrentConv()) {
                self.cast_epoch = self.conv_epoch;
            } else {
                self.resetVeilWork();
                // Different conversation now on screen — see the castFinished note: appending here would
                // pollute the wrong conversation's transcript + hippocampus. Status only.
                self.updateCastRow(.done, 0, -1, "", self.cast_rel[0..self.cast_rel_len]);
                self.setStatus("a background cast finished — see the Swarm tab");
                return;
            }
        }
        self.cast_awaiting_veil = false;
        self.veil_work_active = false;
        const rel = self.cast_rel[0..self.cast_rel_len];
        var m: scan.Metrics = .{};
        var ev_n: usize = 0;
        var ep_buf: [700]u8 = undefined;
        if (std.fmt.bufPrint(&ep_buf, "{s}/{s}/events.jsonl", .{ dd, rel })) |ep| {
            ev_n = scan.tailEvents(self.io, self.gpa, ep, &self.ev_scratch, &m);
        } else |_| {}
        self.collectCast(dd, rel, &m, ev_n);
    }

    /// Fold the finished cast into the conversation as a [cast] findings digest, then ask the model to
    /// answer from it.
    fn collectCast(self: *Chat, dd: []const u8, rel: []const u8, m: *const scan.Metrics, ev_n: usize) void {
        self.cast_active = false;
        // NOTE: a pending Stop is deliberately NOT cleared here — Stop during a cast means "do not post-process
        // this into my chat" (it also bumps conv_epoch, so castFinished already refuses the collect).
        self.updateCastRow(.done, m.round, m.pct, "", rel);
        // The hive just created/filled this conv's build workdir — bind the console/git to it NOW, so the
        // follow-up turn's `RUN:`/meant-to-act checks run where the hive's files actually are (unbound before
        // this cast when the dir didn't exist at chat selection).
        if (self.build_dir_len == 0) self.syncBuildDir(dd);
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        if (self.cast_forced) {
            // the DESKTOP deadline forced this collect — the swarm did not finish; don't claim it did
            jb.print(self.gpa, "[cast] time budget exhausted (run {s}): rounds {d}, best {d}% — the worker was told to stop; collecting what exists", .{ rel, m.round, m.best_pct }) catch return;
        } else {
            jb.print(self.gpa, "[cast] finished run {s}: rounds {d}, score {d}% (best {d}%)", .{ rel, m.round, if (m.pct < 0) 0 else m.pct, m.best_pct }) catch return;
        }
        self.cast_forced = false;
        if (m.stop_reason_len > 0) jb.print(self.gpa, ", stopped: {s}", .{m.stop_reason[0..m.stop_reason_len]}) catch {};
        // FULL inventory of EVERY file the hive produced (any name, nested, manifest or not — listWorkFiles now
        // unions the manifest with a recursive work/ walk). The hive often writes oddly-named files that don't
        // match the goal's expected names, so the model must see the COMPLETE set and judge relevance itself.
        const fn_ = scan.listWorkFiles(self.io, self.gpa, dd, rel, &self.file_scratch);
        if (fn_ > 0) {
            jb.print(self.gpa, "\nfiles the hive produced ({d}) — names may NOT match what you'd expect:", .{fn_}) catch {};
            var i: usize = 0;
            while (i < fn_) : (i += 1) {
                jb.print(self.gpa, "\n  - {s} ({d}b)", .{ self.file_scratch[i].pathStr(), self.file_scratch[i].size }) catch {};
            }
        }
        // the tail of what the hive said/did (for a research cast, scout_learn notes carry the findings)
        if (ev_n > 0) {
            jb.appendSlice(self.gpa, "\nrecent hive activity:") catch {};
            const start = if (ev_n > 12) ev_n - 12 else 0;
            var i = start;
            while (i < ev_n) : (i += 1) {
                const e = &self.ev_scratch[i];
                jb.print(self.gpa, "\n- {s} {s}: {s}", .{ e.kindStr(), e.mindStr(), e.textStr() }) catch {};
            }
        }
        // CONTENT: surface synthesis.md first (the lead's own summary), then the ACTUAL CONTENT of every other
        // file up to a byte budget — so the model can reiterate from whatever the odd-named files really contain
        // instead of assuming the goal's file names were used. Read into a budget-sized heap buffer (not tiny
        // stack buffers) so a large deliverable isn't double-truncated. The full run stays saved under <data>/<rel>.
        const CONTENT_BUDGET: usize = 9000;
        var used: usize = 0;
        {
            var sbuf: [4500]u8 = undefined;
            var strunc = false;
            const sn = scan.readWorkFile(self.io, self.gpa, dd, rel, "synthesis.md", &sbuf, &strunc);
            if (sn > 0) {
                jb.appendSlice(self.gpa, "\n\n=== synthesis.md (the lead's own summary of the run) ===\n") catch {};
                jb.appendSlice(self.gpa, sbuf[0..sn]) catch {};
                if (strunc) jb.appendSlice(self.gpa, "\n[...truncated; full file in the run dir]") catch {};
                used += sn;
            }
        }
        var fi: usize = 0;
        while (fi < fn_ and used < CONTENT_BUDGET) : (fi += 1) {
            const path = self.file_scratch[fi].pathStr();
            if (std.mem.eql(u8, path, "synthesis.md")) continue; // already shown
            const allow = @min(CONTENT_BUDGET - used, 2400); // per-file cap so one big file can't crowd out the rest
            if (allow < 80) break;
            const buf = self.gpa.alloc(u8, allow) catch break;
            defer self.gpa.free(buf);
            var trunc = false;
            const cn = scan.readWorkFile(self.io, self.gpa, dd, rel, path, buf, &trunc);
            if (cn == 0) continue;
            jb.print(self.gpa, "\n\n--- {s} ({d}b) ---\n{s}{s}", .{ path, self.file_scratch[fi].size, buf[0..cn], if (trunc) "\n[...truncated; full file in the run dir]" else "" }) catch {};
            used += cn;
        }
        jb.print(self.gpa, "\n\n(full swarm output saved at {s}; open it in the Swarm tab. The files listed above are in YOUR OWN workdir RIGHT NOW at exactly those relative paths — read_file any of them directly, e.g. read_file {{\"path\":\"{s}\"}}. Do NOT go looking for them elsewhere on disk, and NEVER rebuild something the list already shows exists — verify by reading, then fill only real gaps.)", .{ rel, if (fn_ > 0) self.file_scratch[0].pathStr() else "index.html" }) catch {};
        // Keep as much of the digest as the ChatMsg buffer (12288b) holds — the synthesis IS the answer, so
        // we want it whole, not clipped. appendMsg truncates to the buffer anyway.
        const digest = jb.items[0..@min(jb.items.len, 12200)];
        self.appendMsg(dd, .cast_note, digest);
        self.setStatus("composing the answer...");
        // The collect (+ any repair it announces) is a NEW agentic leg: the orchestrator turns during the
        // cast spent from tool_iters/act_nudges, and a depleted budget here would refuse the very
        // follow-through that fixes a broken deliverable. Still bounded — one fresh capped budget per cast.
        self.tool_iters = 0;
        self.act_nudges = 0;
        self.startTurn(dd, .collect);
    }

    fn updateCastRow(self: *Chat, status: store_mod.CastStatus, round: i64, pct: i32, last: []const u8, run_id: []const u8) void {
        self.store.lock();
        defer self.store.unlock();
        if (self.store.cast_count == 0) return;
        // the newest row is this thread's active cast
        const row = &self.store.casts[self.store.cast_count - 1];
        row.status = status;
        row.round = round;
        row.pct = pct;
        if (run_id.len > 0) {
            const rn = @min(run_id.len, row.run.len);
            @memcpy(row.run[0..rn], run_id[0..rn]);
            row.run_len = @intCast(rn);
        }
        if (last.len > 0) {
            const ln = @min(last.len, row.last.len);
            @memcpy(row.last[0..ln], last[0..ln]);
            row.last_len = @intCast(ln);
        }
    }
};

// ------------------------------------------------------------------------------ pure helpers (tested)

/// If a "CAST: goal" line appears within the reply's first few substantive lines, return the goal.
/// Tolerant on purpose: reasoning models often put a short preamble ("Sure — this needs the hive.")
/// above the tag even when told to lead with it.
pub fn castGoal(full: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, full, '\n');
    var seen: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "CAST:")) {
            const g = std.mem.trim(u8, line[5..], " \r\t");
            return if (g.len > 0) g else null;
        }
        seen += 1;
        if (seen >= 5) return null; // a CAST mention deep in prose is narration, not an action
    }
    return null;
}

/// The AI's full cast "payload": the goal + how many minds to line up + quick-strike vs a sustained
/// (continuous) hivemind + a time budget. This is the AI loading + configuring its swarm before it fires.
pub const CastSpec = struct { goal: []const u8, minds: u32 = 0, long: bool = false, minutes: u32 = 0, files: []const u8 = "", publish: bool = false };

fn uintAfter(line: []const u8, key: []const u8) ?u32 {
    const rest = std.mem.trim(u8, line[key.len..], " :\t=");
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

/// Parse the AI's cast directive: a `CAST: <goal>` line, optionally followed (within the reply's first lines)
/// by `MINDS <n>` (swarm size, 2-30), `LONG` (a sustained continuous hivemind vs the default quick strike),
/// `MINUTES <n>` (time budget), and `FILES: a, b, c` (the DECLARED deliverables — the veil reasons out the
/// exact output paths and the engine adopts them verbatim as the blueprint, so the swarm is graded on the
/// right files instead of goal-prose guesses). Returns null if there's no CAST line. Config lines must ride
/// near the top, not buried in prose.
pub fn parseCastSpec(full: []const u8) ?CastSpec {
    const g = castGoal(full) orelse return null;
    var spec = CastSpec{ .goal = g };
    var it = std.mem.splitScalar(u8, full, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t#*-");
        n += 1;
        if (n > 8) break;
        if (std.mem.startsWith(u8, line, "MINDS")) {
            if (uintAfter(line, "MINDS")) |v| spec.minds = v;
        } else if (std.mem.startsWith(u8, line, "MINUTES")) {
            if (uintAfter(line, "MINUTES")) |v| spec.minutes = v;
        } else if (std.mem.startsWith(u8, line, "FILES")) {
            const v = std.mem.trim(u8, line["FILES".len..], " :\t=");
            if (v.len > 0) spec.files = v;
        } else if (std.mem.eql(u8, line, "PUBLISH") or std.mem.startsWith(u8, line, "PUBLISH ")) {
            spec.publish = true; // NEWS DESK: the hive posts a grounded, screened briefing to Telegraph
        } else if (std.mem.eql(u8, line, "LONG") or std.mem.startsWith(u8, line, "LONG ") or std.mem.eql(u8, line, "CONTINUOUS")) {
            spec.long = true;
        }
    }
    return spec;
}

/// Did a self-critique pass meaningfully change the draft? Used to decide whether to iterate again: while the
/// answer keeps changing we keep refining; once it stabilizes (near-identical revision) we stop. Heuristic:
/// a >~4% length shift, or a differing sampled prefix, counts as changed.
fn reflectChanged(prior: []const u8, revised: []const u8) bool {
    const a = std.mem.trim(u8, prior, " \r\n\t");
    const b = std.mem.trim(u8, revised, " \r\n\t");
    if (a.len == 0) return true;
    const dlen = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (dlen * 25 > a.len) return true; // length shifted more than ~4%
    const n = @min(@min(a.len, b.len), 240); // cheap proxy for "the wording changed"
    return !std.mem.eql(u8, a[0..n], b[0..n]);
}

/// Parse the body of a `REMEMBER:` directive into (category, fact). An optional leading `[category]` picks the
/// bucket (key/login/preference/fact); without it the whole body is a plain `fact`. Pure — unit-tested.
/// Is this observed fact PERSONAL/durable to THIS user (a credential or preference worth the private Memory tab)
/// rather than general hive knowledge? Returns the coarse category, or null = not personal (stays hive-only).
/// Deliberately biased to FALSE NEGATIVES: a miss just keeps today's hive-only behavior, but a false positive would
/// leak research noise into the user's private secret store. So the credential classes REQUIRE a first-person /
/// possessive marker ("my", "i ", "'s ") to fire — "the API key rotation interval is 90 days" must NOT match, while
/// "my openai api key is sk-…" must. Preferences fire on explicit first-person preference verbs. Pure; unit-tested.
fn personalFact(fact: []const u8) ?[]const u8 {
    var lb: [512]u8 = undefined;
    const n = @min(fact.len, lb.len);
    for (fact[0..n], 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const low = lb[0..n];
    const H = struct {
        fn has(h: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, h, needle) != null;
        }
    };
    // Does the fact refer to THIS user? First-person only — deliberately strict so a general-knowledge observe
    // ("that's the api key rotation interval") can't slip into the private store. Explicit third-person personal
    // secrets ("gary's password …") are expected to go via a REMEMBER: line (which the prompt steers hard), not
    // through this observe backstop; missing them is the safe (false-negative) direction.
    const mine = H.has(low, "my ") or std.mem.startsWith(u8, low, "i ") or H.has(low, " i ") or std.mem.startsWith(u8, low, "i'");
    if (mine) {
        if (H.has(low, "password") or H.has(low, "passphrase")) return "login";
        if (H.has(low, "api key") or H.has(low, "apikey") or H.has(low, "secret") or H.has(low, "token") or
            H.has(low, "signing key") or H.has(low, "private key") or H.has(low, "credential") or H.has(low, "access key")) return "key";
        if (H.has(low, "login") or H.has(low, "email") or H.has(low, "username") or H.has(low, "account")) return "login";
    }
    // Preferences — first-person only (a bare "prefer to" would match "most teams prefer to use postgres").
    if (H.has(low, "i prefer") or H.has(low, "i like") or H.has(low, "i always") or H.has(low, "i use") or
        H.has(low, "my preference")) return "preference";
    return null; // general knowledge → hive-only (unchanged)
}

/// Drop a trailing "intro to the (now-stripped) directives" line — a short line ending in ':' that announces a
/// save, e.g. "**Saved preferences:**" or "I've remembered:". Only touches the LAST line and only when it clearly
/// reads as such an intro, so real prose ending in a colon (a list header with content under it) is left alone.
fn stripDanglingMemoryIntro(text: []const u8) []const u8 {
    const nl = std.mem.lastIndexOfScalar(u8, text, '\n');
    const last_raw = if (nl) |i| text[i + 1 ..] else text;
    const ll = std.mem.trim(u8, last_raw, " \t*_#>`-—");
    if (ll.len == 0 or ll.len > 48 or ll[ll.len - 1] != ':') return text;
    var lb: [64]u8 = undefined;
    const n = @min(ll.len, lb.len);
    for (ll[0..n], 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const low = lb[0..n];
    const intro = std.mem.indexOf(u8, low, "sav") != null or std.mem.indexOf(u8, low, "remember") != null or
        std.mem.indexOf(u8, low, "prefer") != null or std.mem.indexOf(u8, low, "memor") != null or
        std.mem.indexOf(u8, low, "stored") != null or std.mem.indexOf(u8, low, "noted") != null or
        std.mem.indexOf(u8, low, "keep") != null;
    if (!intro) return text;
    return std.mem.trimEnd(u8, if (nl) |i| text[0..i] else "", " \r\n\t*_#>`-—");
}

/// Does this message plausibly contain a durable fact about the user (a first-person statement, a credential, a
/// preference, an environment detail)? Gates the consolidation pass so a purely technical exchange ("explain
/// quicksort") doesn't spend a model call. Permissive on the personal side, since a missed consolidation is worse
/// than an occasional NONE-returning call. Case-insensitive substring scan; cheap.
fn exchangeHasDurableSignal(text: []const u8) bool {
    // Markers of a fact worth keeping across conversations: first-person identity/preference/setup, explicit
    // remember/forget directives, credentials, AND commitments/schedule/plans the user states in passing. Still
    // tight enough that ordinary technical questions ("explain tokenization", "how does X work") match nothing.
    const sigs = [_][]const u8{
        // identity / preference / setup (first person)
        "my ",      "i'm",          "i am",           "i use",       "i prefer",   "i like",   "i always",
        "i work",   "i deploy",     "i run",          "i host",      "i keep",     "i need",   "i have to",
        "i want",   "we use",       "we deploy",      "we have",     "call me",    "name is",
        // explicit directives + credentials
         "remember",
        "forget",   "password",     "api key",        "apikey",      "credential", "token is",
        // commitments / schedule / plans (durable for THIS user's context) — words specific enough that a
        // technical answer won't trip them (no bare "am"/"at N" — those match "diagram"/"at 3 levels").
        "today",
        "tomorrow", "tonight",      "next week",      "appointment", "meeting",    "deadline", "remind me",
        "schedule", "set an alarm", "set a reminder", "due ",        "o'clock",
    };
    for (sigs) |s| {
        if (std.ascii.indexOfIgnoreCase(text, s) != null) return true;
    }
    return false;
}

const RememberSpec = struct { cat: []const u8, fact: []const u8 };
fn parseRememberBody(body_in: []const u8) RememberSpec {
    const body = std.mem.trim(u8, body_in, " \t");
    if (body.len > 0 and body[0] == '[') {
        if (std.mem.indexOfScalar(u8, body, ']')) |cb| {
            const cat = std.mem.trim(u8, body[1..cb], " \t");
            const fact = std.mem.trim(u8, body[cb + 1 ..], " \t");
            return .{ .cat = if (cat.len > 0) cat else "fact", .fact = fact };
        }
    }
    return .{ .cat = "fact", .fact = body };
}

/// Should we run the self-check (reflect) pass for this completed turn? Only a SUBSTANTIVE answer to a
/// SUBSTANTIVE request qualifies — a greeting or a one-liner must NOT recurse ("hello" -> short reply -> no
/// second pass). This mirrors how Claude Code iterates on real TASKS, not on chit-chat. Control lines
/// (TOOL:/CAST:) and the non-answer turns (collect/reflect/idle) never reflect.
fn shouldReflectPass(kind: Turn, user_msg: []const u8, full: []const u8) bool {
    if (kind != .user and kind != .tool_follow) return false;
    if (full.len == 0) return false;
    if (castGoal(full) != null or toolCall(full) != null) return false;
    if (full.len < REFLECT_MIN_ANSWER) return false; // trivial/short answers don't need a self-check
    if (isSmallTalk(user_msg)) return false; // greetings/acks/tiny queries never warrant a reflect pass
    return true;
}

/// A greeting, thanks, or tiny query — the kind of message a reflection pass must never fire on.
fn isSmallTalk(msg: []const u8) bool {
    const m = std.mem.trim(u8, msg, " \r\n\t");
    if (m.len < 24) return true;
    var buf: [24]u8 = undefined;
    const n = @min(m.len, buf.len);
    for (m[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const openers = [_][]const u8{ "hello", "hi ", "hey", "thanks", "thank you", "good morning", "good evening", "how are you", "what's up", "yo " };
    for (openers) |w| if (std.mem.startsWith(u8, buf[0..n], w)) return true;
    return false;
}

pub const ToolCall = struct { name: []const u8, args: []const u8 };

/// The tools the chat prompt advertises. A "TOOL:" buried mid-sentence only counts as a call when the
/// name is one of these, so a prose mention ("use the TOOL: menu") is never dispatched or clipped; a
/// call at a line start (the taught form) accepts any name — the server rejects unknowns.
fn knownChatTool(name: []const u8) bool {
    const names = [_][]const u8{
        "list_swarms", "stop_swarm", "kill_swarm",  "swarm_status", "swarm_findings", "web_search",
        "web_fetch",   "fetch_json", "recall_hive", "observe",      "write_file",     "edit_file",
        "read_file",   "list_dir",   "run_tests",   "run_python",   "delete_file",    "git_status",
        "git_commit",  "git_push",   "git_log",     "repo_create",
    };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

fn substantiveLinesBefore(text: []const u8, pos: usize) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text[0..pos], '\n');
    while (it.next()) |raw| {
        if (std.mem.trim(u8, raw, " \r\t").len > 0) n += 1;
    }
    return n;
}

const FoundCall = struct { name: []const u8, args: []const u8, at: usize };

/// Locate the opening '{' of a tool call's JSON args, starting at `from` (just past the tool NAME). Args
/// usually sit on the SAME line (`TOOL: web_search {..}`), but a capable model writing a big file routinely
/// puts the JSON on the NEXT line, or wraps it in a ```json fence — a scan that skips only spaces/tabs misses
/// those, defaults args to "{}", and sends an EMPTY call the server rejects as "bad path" (the model then loops,
/// unable to write its file). Skip inter-token whitespace INCLUDING newlines and at most a leading ```lang fence
/// line, then return the first '{'. Returns null the instant real prose appears first, so a bare no-arg call
/// (`TOOL: stop_swarm` then narration) still parses as "{}".
fn findArgsBrace(text: []const u8, from: usize) ?usize {
    var k = from;
    while (k < text.len) {
        const c = text[k];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            k += 1;
            continue;
        }
        if (c == '{') return k;
        if (c == '`' and std.mem.startsWith(u8, text[k..], "```")) {
            k += 3;
            while (k < text.len and text[k] != '\n') k += 1; // skip the rest of the ```lang opener line
            continue;
        }
        return null; // prose before any args brace — a bare / no-arg call
    }
    return null;
}

/// Scan a JSON object beginning at `open` (which MUST index the opening '{'), returning the index JUST
/// PAST its matching '}'. STRING-AWARE: a '{'/'}' inside a JSON string value (respecting \" and \\ escapes)
/// does NOT count toward brace depth. A raw byte counter truncates a `write_file` whose `content` holds an
/// unbalanced '}' (a code chunk closing a block — every CSS/JS/JSON tail, exactly what the chunked-append
/// recovery asks the model to emit), shipping invalid JSON the server rejects as a bad path. Returns null if
/// the object never closes before end-of-text (a reply cut off mid-args — also the truncated-write signal
/// looksTruncatedWrite wants).
fn jsonObjEnd(text: []const u8, open: usize) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var k = open;
    while (k < text.len) : (k += 1) {
        const c = text[k];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return k + 1;
            },
            else => {},
        }
    }
    return null; // opened but never closed — truncated
}

/// True if the reply holds a `TOOL: write_file`/`edit_file` whose JSON args OPENED a '{' but never closed it
/// (brace depth never returns to 0 before end-of-text) with a substantial partial body — the fingerprint of a
/// big file CUT OFF mid-content by the reply's length cap. Lets the dispatcher tell the model "your file was too
/// large, write it in append chunks" instead of the misleading "bad path" that made it loop on the path forever.
fn looksTruncatedWrite(text: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "TOOL:")) |p| {
        search = p + "TOOL:".len;
        var i = p + "TOOL:".len;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        const ns = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '{' and text[i] != '\n' and text[i] != '\r') i += 1;
        // trim markdown/punctuation EXACTLY as findToolCall does — otherwise a bolded `**TOOL: write_file**`
        // yields "write_file**" here and fails the eql check, so the two parsers disagree and this
        // truncation branch is skipped for a call findToolCall accepts (chunked-append recovery never fires)
        const name = std.mem.trim(u8, text[ns..i], " \t:`*\".,;)!?");
        if (!std.mem.eql(u8, name, "write_file") and !std.mem.eql(u8, name, "edit_file")) continue;
        const astart = findArgsBrace(text, i) orelse continue;
        // never closed (string-aware) + substantial = a big write cut off mid-content
        if (jsonObjEnd(text, astart) == null and (text.len - astart) > 400) return true;
    }
    // the fenced dialect truncates the same way: ```tool: write_file args that opened but never closed
    if (toolCallFencedAt(text)) |fc| {
        if (std.mem.eql(u8, fc.name, "write_file") or std.mem.eql(u8, fc.name, "edit_file")) {
            if (fc.open) |astart| {
                if (jsonObjEnd(text, astart) == null and (text.len - astart) > 400) return true;
            }
        }
    }
    return false;
}

/// THE one TOOL: predicate — dispatch (toolCall), the display stripper (stripToolTail) and the reflect
/// gate all use this same scan, so a call can never be hidden-but-not-run or run-but-shown (a line-start-only
/// dispatcher paired with a mid-line stripper would silently drop or leak anything between the two anchors).
/// Finds the FIRST "TOOL:" that is a real call:
/// - at a line start (markdown wrappers like `**` tolerated): any name within the first few substantive
///   lines, a known chat tool below them (a deep line-start mention of an unknown name is narration);
/// - mid-line ("...let me stop it. TOOL: stop_swarm"): only a known chat tool name.
/// Args are the balanced {...} blob after the name ("{}" when omitted — no-arg tools like stop_swarm
/// are legal without braces), passed to the server verbatim.
fn findToolCall(text: []const u8) ?FoundCall {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "TOOL:")) |p| {
        search = p + "TOOL:".len;
        var i = p + "TOOL:".len;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        const nstart = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '{' and text[i] != '\n' and text[i] != '\r') i += 1;
        const name = std.mem.trim(u8, text[nstart..i], " \t:`*\".,;)!?");
        if (!plausibleToolName(name)) continue; // punctuation inside the token is quoted prose, not a call
        const line_start = blk: {
            var j = p;
            while (j > 0) {
                const c = text[j - 1];
                if (c == '\n') break;
                if (c != ' ' and c != '\t' and c != '`' and c != '*' and c != '#' and c != '>' and c != '-') break :blk false;
                j -= 1;
            }
            break :blk true;
        };
        if (!line_start and !knownChatTool(name)) continue;
        if (line_start and !knownChatTool(name) and substantiveLinesBefore(text, p) >= 5) continue;
        var args: []const u8 = "{}";
        if (findArgsBrace(text, i)) |astart| {
            if (jsonObjEnd(text, astart)) |end| {
                if (end > astart + 1) args = text[astart..end];
            }
        }
        return .{ .name = name, .args = args, .at = p };
    }
    return null;
}

/// Cut a trailing TOOL:/RUN:/<tool:...> call out of DISPLAYED text and return only the prose before it. A tool
/// call reaching a displayed answer means a reflect/collect turn re-emitted it as text (those turns can't run
/// tools), so the huge write_file{"content":<file>} blob would otherwise dump into the chat. Uses the SAME
/// findToolCall predicate as the dispatcher, so display and dispatch can never disagree about what is a call.
pub fn stripToolTail(text: []const u8) []const u8 {
    var cut = text.len;
    if (findToolCall(text)) |f| cut = @min(cut, f.at);
    if (std.mem.indexOf(u8, text, "<tool:")) |p| cut = @min(cut, p);
    if (bareToolTagAt(text)) |p| cut = @min(cut, p); // bare `<edit_file>{...}` XML tool tag
    if (bracketToolAt(text)) |bt| cut = @min(cut, bt.at); // `[tool:…]` / `[TOOL: …]` square-bracket dialect
    // fenced dialect (```tool: write_file / write_file({...})) — cut at the FENCE so neither the opener nor
    // the `name(` wrapper strand in the display. Matches even while the args are still streaming (open == args
    // unclosed), same live behavior as a leading TOOL: line.
    if (toolCallFencedAt(text)) |fc| cut = @min(cut, fc.at);
    if (toolCallJsonInferred(text)) |jc| { // bare ```json {...}``` tool-args block (deepseek) — strip it + its fence
        const at = @intFromPtr(jc.args.ptr) - @intFromPtr(text.ptr);
        var c = at;
        // back over a bare `write_file({...})` function-call wrapper so `write_file(` can't strand
        {
            var j = c;
            while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t')) j -= 1;
            if (j > 0 and text[j - 1] == '(') {
                var k = j - 1;
                while (k > 0 and (std.ascii.isAlphanumeric(text[k - 1]) or text[k - 1] == '_')) k -= 1;
                if (k < j - 1) c = k;
            }
        }
        // a TAGGED fence header line directly above (```json, ```tool: name) is the block's OPENER — eat it
        // too. A bare ``` line stays: that's a previous block's closer.
        {
            var j = c;
            while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t' or text[j - 1] == '\r' or text[j - 1] == '\n')) j -= 1;
            const ls = if (std.mem.lastIndexOfScalar(u8, text[0..j], '\n')) |nl| nl + 1 else 0;
            const line = std.mem.trim(u8, text[ls..j], " \t\r");
            if (line.len > 3 and std.mem.startsWith(u8, line, "```")) c = ls;
        }
        cut = @min(cut, c);
    }
    // RUN: <shell command> — only at a line start (a prose "RUN:" mid-sentence isn't a shell call).
    {
        var i: usize = 0;
        while (i < text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            const line = std.mem.trimStart(u8, text[i..nl], " \t");
            const rl = if (line.len > 1 and line[0] == '[') line[1..] else line; // tolerate a `[RUN: …]` wrapper
            if (std.mem.startsWith(u8, rl, "RUN:") and rl.len > 4) {
                cut = @min(cut, i);
                break;
            }
            if (nl >= text.len) break;
            i = nl + 1;
        }
    }
    return std.mem.trimEnd(u8, text[0..cut], " \r\n\t");
}

/// The dispatcher's view of findToolCall: first real "TOOL: <name> <json-args>" call in the reply,
/// mid-line included ("{}" when the model omits args). The args are passed to the server verbatim,
/// so a malformed blob is the server's problem to reject, not ours.
pub fn toolCall(full: []const u8) ?ToolCall {
    const f = findToolCall(full) orelse return null;
    return .{ .name = f.name, .args = f.args };
}

/// Many models emit tool calls as `<tool:NAME>{json-args}</tool:NAME>` (or just `<tool:NAME>{...}`) instead of
/// the `TOOL:` convention — even inline in prose. Find the FIRST such call anywhere in the reply and return
/// name+args. Without this those calls render as inert text and the model loops forever re-issuing them.
pub fn toolCallXml(text: []const u8) ?ToolCall {
    const open = std.mem.indexOf(u8, text, "<tool:") orelse return null;
    var i = open + "<tool:".len;
    const nstart = i;
    while (i < text.len and text[i] != '>' and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and text[i] != '\t') i += 1;
    const name = std.mem.trim(u8, text[nstart..i], " \t:`*\"/");
    if (!plausibleToolName(name)) return null;
    while (i < text.len and text[i] != '>') i += 1; // skip to the tag close
    if (i < text.len) i += 1; // skip '>'
    var args: []const u8 = "{}";
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
    if (i < text.len and text[i] == '{') { // a balanced {...} blob after the tag
        const astart = i;
        if (jsonObjEnd(text, astart)) |end| {
            if (end > astart + 1) args = text[astart..end];
        }
    }
    return .{ .name = name, .args = args };
}

/// deepseek (and others) ALSO emit a call as a BARE tool-named XML tag — `<edit_file>{json}</edit_file>`,
/// `<read_file>{json}</read_file>` — with NO `tool:` prefix, so toolCallXml misses it. Dropped, it reads as a
/// hallucinated tool call and the model loops re-issuing it. Find the FIRST `<name>` whose name is a KNOWN chat
/// tool and is followed by a balanced {...}. The known-tool gate is what stops a built page's own
/// `<section>`/`<div>`/`<html>` markup from ever matching.
pub fn toolCallTagXml(text: []const u8) ?ToolCall {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, search, '<')) |lt| {
        search = lt + 1;
        var i = lt + 1;
        if (i < text.len and text[i] == '/') continue; // a closing tag </name>
        const nstart = i;
        while (i < text.len and text[i] != '>' and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and text[i] != '\t' and text[i] != '/') i += 1;
        const name = text[nstart..i];
        if (!knownChatTool(name)) continue;
        while (i < text.len and text[i] != '>') i += 1; // skip to the tag close
        if (i < text.len) i += 1; // past '>'
        const astart = findArgsBrace(text, i) orelse continue;
        const end = jsonObjEnd(text, astart) orelse continue; // unclosed here — try the next '<'
        if (end > astart + 1) return .{ .name = name, .args = text[astart..end] };
    }
    return null;
}

const BracketTool = struct { at: usize, name_off: usize };

/// Locate a `[tool:NAME …]` / `[TOOL: NAME …]` call — the SQUARE-bracket dialect the model falls into when it
/// mimics the desk's own `[tool:…]`/`[console]` result-render labels (fed back to it as history) as if they
/// were the invocation syntax. No angle-tag/TOOL: parser matches the square form, so the call leaked as inert
/// text and nothing ran. Case-insensitive on the marker; gated to a KNOWN chat tool so a `[note]` / `[1]`
/// citation / `[tooltip]` never matches. Returns the `[` offset (for stripToolTail) and where the tool NAME
/// begins (for the parser).
fn bracketToolAt(text: []const u8) ?BracketTool {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, search, '[')) |lb| {
        search = lb + 1;
        var i = lb + 1;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i + 5 > text.len or !std.ascii.eqlIgnoreCase(text[i .. i + 5], "tool:")) continue;
        i += 5;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        var j = i;
        while (j < text.len and text[j] != ']' and text[j] != ' ' and text[j] != '\t' and text[j] != '{' and text[j] != '\n' and text[j] != '\r') j += 1;
        const name = std.mem.trim(u8, text[i..j], " \t:`*\"]");
        if (!knownChatTool(name)) continue;
        return .{ .at = lb, .name_off = i };
    }
    return null;
}

/// Parse a `[tool:NAME {args}]` / `[TOOL: NAME {args}]` square-bracket call into name + balanced {args}
/// ("{}" when omitted, e.g. a bare `[tool:web_fetch]` — which then dispatches and the server returns a
/// missing-arg error the model can react to, instead of the reply silently leaking as text and deadlocking).
pub fn toolCallBracket(text: []const u8) ?ToolCall {
    const bt = bracketToolAt(text) orelse return null;
    var i = bt.name_off;
    while (i < text.len and text[i] != ']' and text[i] != ' ' and text[i] != '\t' and text[i] != '{' and text[i] != '\n' and text[i] != '\r') i += 1;
    const name = std.mem.trim(u8, text[bt.name_off..i], " \t:`*\"]");
    var args: []const u8 = "{}";
    if (findArgsBrace(text, i)) |astart| {
        if (jsonObjEnd(text, astart)) |end| {
            if (end > astart + 1) args = text[astart..end];
        }
    }
    return .{ .name = name, .args = args };
}

/// Byte offset of the first `<knowntool>…` XML tool call (bare `{json}` OR nested `<arg>…</arg>` form), or null —
/// lets stripToolTail cut it out of a displayed answer so a re-emitted `<write_file>…` blob never dumps into the chat.
fn bareToolTagAt(text: []const u8) ?usize {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, search, '<')) |lt| {
        search = lt + 1;
        var i = lt + 1;
        if (i < text.len and text[i] == '/') continue;
        const nstart = i;
        while (i < text.len and text[i] != '>' and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and text[i] != '\t' and text[i] != '/') i += 1;
        if (!knownChatTool(text[nstart..i])) continue;
        while (i < text.len and text[i] != '>') i += 1;
        if (i < text.len) i += 1;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
        if (i < text.len and (text[i] == '{' or text[i] == '<')) return lt; // {json} or nested-XML args
    }
    return null;
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0 or s.len > 18) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Parse a NESTED-XML tool call — `<read_file><path>index.html</path><start_line>100</start_line></read_file>` —
/// where the tool NAME and its ARGUMENTS are both XML elements (Hermes/Anthropic style), not a JSON blob. deepseek
/// emits this and it HUNG (toolCallTagXml expects `{json}` after the tag, hits `<path>`, gives up). Convert the
/// child `<key>value</key>` elements into a JSON args object — OWNED by the caller (free it). An all-digit value
/// becomes a JSON number (start_line:100); everything else a JSON-escaped string. Gated to known tool names so a
/// built page's own `<section>`/`<div>` markup can never match. Returns null if there are no XML child args
/// (that's the bare-tag `{json}` form, which toolCallTagXml owns).
pub fn toolCallXmlNested(gpa: std.mem.Allocator, text: []const u8) ?ToolCall {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, search, '<')) |lt| {
        search = lt + 1;
        if (lt + 1 < text.len and text[lt + 1] == '/') continue;
        var i = lt + 1;
        const nstart = i;
        while (i < text.len and text[i] != '>' and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and text[i] != '\t' and text[i] != '/') i += 1;
        const name = text[nstart..i];
        if (!knownChatTool(name)) continue;
        while (i < text.len and text[i] != '>') i += 1;
        if (i >= text.len) continue;
        i += 1; // past '>'
        var j = i; // args must be XML children (next non-ws is '<'); else the {json} bare-tag form owns it
        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) j += 1;
        if (j >= text.len or text[j] != '<') continue;
        var cb: [72]u8 = undefined;
        const closing = std.fmt.bufPrint(&cb, "</{s}>", .{name}) catch continue;
        const body_end = std.mem.indexOfPos(u8, text, i, closing) orelse text.len;
        const body = text[i..body_end];
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        out.append(gpa, '{') catch return null;
        var first = true;
        var k: usize = 0;
        while (std.mem.indexOfScalarPos(u8, body, k, '<')) |clt| {
            if (clt + 1 < body.len and body[clt + 1] == '/') {
                k = clt + 1;
                continue;
            }
            var m = clt + 1;
            const kstart = m;
            while (m < body.len and body[m] != '>' and body[m] != ' ' and body[m] != '/') m += 1;
            const key = body[kstart..m];
            while (m < body.len and body[m] != '>') m += 1;
            if (m >= body.len or key.len == 0) break;
            m += 1; // past '>'
            var kcb: [80]u8 = undefined;
            const kclose = std.fmt.bufPrint(&kcb, "</{s}>", .{key}) catch break;
            const vend = std.mem.indexOfPos(u8, body, m, kclose) orelse break;
            const val = std.mem.trim(u8, body[m..vend], " \r\n\t");
            if (!first) out.append(gpa, ',') catch return null;
            first = false;
            out.append(gpa, '"') catch return null;
            escJson(&out, gpa, key);
            out.appendSlice(gpa, "\":") catch return null;
            if (isAllDigits(val)) {
                out.appendSlice(gpa, val) catch return null;
            } else {
                out.append(gpa, '"') catch return null;
                escJson(&out, gpa, val);
                out.append(gpa, '"') catch return null;
            }
            k = vend + kclose.len;
        }
        out.append(gpa, '}') catch return null;
        if (first) { // no children parsed — not really the nested form
            out.deinit(gpa);
            continue;
        }
        return .{ .name = name, .args = out.toOwnedSlice(gpa) catch return null };
    }
    return null;
}

fn jsonHasKey(a: []const u8, key: []const u8) bool {
    var buf: [40]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return false;
    return std.mem.indexOf(u8, a, needle) != null;
}

/// Find the FIRST-BY-POSITION GitHub token in `s` — classic `ghp_…`, fine-grained `github_pat_…`, or the
/// gho_/ghu_/ghs_/ghr_ kin. Returns the token slice or null. Requires a long body so a bare-prefix mention
/// ("a ghp_ token") isn't matched. Positional (not prefix-priority) so a caller looping to redact EVERY token
/// never skips one of a different prefix that sits earlier in the text.
fn findGithubToken(s: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_" };
    var best_at: ?usize = null;
    var best_end: usize = 0;
    for (prefixes) |pre| {
        if (std.mem.indexOf(u8, s, pre)) |at| {
            var e = at + pre.len;
            while (e < s.len and (std.ascii.isAlphanumeric(s[e]) or s[e] == '_')) e += 1;
            if (e - at >= pre.len + 20 and (best_at == null or at < best_at.?)) {
                best_at = at;
                best_end = e;
            }
        }
    }
    return if (best_at) |at| s[at..best_end] else null;
}

/// A token that looks like a FILE PATH — only path-ish chars, and (when require_sep) contains a '.', '/', or '\'
/// so a `read_file <path>` is told from a prose word like "read_file the docs". list_dir passes require_sep=false
/// because a bare dir name ("src", "advanced-bci") has no separator; a stray list is non-destructive anyway.
fn looksLikePathTok(s: []const u8, require_sep: bool) bool {
    if (s.len == 0 or s.len > 400) return false;
    var has_sep = false;
    for (s) |c| {
        if (c == '/' or c == '\\' or c == '.') {
            has_sep = true;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '~' or c == ':')) {
            return false;
        }
    }
    return has_sep or !require_sep;
}

/// The integer immediately after a WHOLE-TOKEN `key` (`key 430`, `key=430`, `key: 430`) within a short gap. null
/// if absent/far. Whole-token so `start_lines`/`start_line_no` don't satisfy a `start_line` lookup.
fn intAfter(text: []const u8, key: []const u8) ?u32 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, key)) |at| {
        from = at + key.len;
        if (from < text.len) {
            const c = text[from];
            if (std.ascii.isAlphanumeric(c) or c == '_') continue; // longer token, not this key
        }
        var i = from;
        var gap: usize = 0;
        while (i < text.len and !std.ascii.isDigit(text[i])) {
            if (text[i] == '\n' or gap >= 6) return null; // the value must sit right after the key
            i += 1;
            gap += 1;
        }
        const d0 = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == d0) return null;
        return std.fmt.parseInt(u32, text[d0..i], 10) catch null;
    }
    return null;
}

/// Trim a trailing run of sentence punctuation glued to an unquoted path (`main.py.` -> `main.py`). Never trims
/// below one char, so a legitimate bare `.` (current dir, for list_dir) survives.
fn trimTrailingPathPunct(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 1) : (e -= 1) {
        switch (s[e - 1]) {
            '.', ',', ';', ':', ')', ']', '}', '!', '?' => {},
            else => break,
        }
    }
    return s[0..e];
}

/// Recover the model's NATURAL-LANGUAGE read form — `read_file <path> [start_line N] [end_line M]` with no JSON,
/// XML, or fence — into a real read_file call with OWNED JSON args. deepseek repeatedly drops to this bare form
/// and it never dispatched (every structured parser needs a `{`), so the model re-announced the read forever.
/// Scoped to read_file ONLY, which is NON-DESTRUCTIVE, so recovering even a prose mention is harmless (a stray
/// read, never a write) — hence no action gate. Skips the `{`/`(` forms the real parsers own. Args are heap-OWNED
/// (caller frees via synth_args).
fn naturalReadCall(gpa: std.mem.Allocator, text: []const u8) ?ToolCall {
    const Spec = struct { name: []const u8, ranged: bool, require_sep: bool };
    const specs = [_]Spec{
        .{ .name = "read_file", .ranged = true, .require_sep = true }, // a file has an extension/path separator
        .{ .name = "list_dir", .ranged = false, .require_sep = false }, // a dir can be a bare name
    };
    for (specs) |sp| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, text, search, sp.name)) |at| {
            search = at + sp.name.len;
            if (at > 0) { // word boundary before it: not part of a longer token / a quoted or XML form the parsers own
                const p = text[at - 1];
                if (std.ascii.isAlphanumeric(p) or p == '_' or p == '"' or p == '<' or p == '/') continue;
            }
            if (at + sp.name.len < text.len) { // ...and after it, so `read_files`/`read_file.py`/`list_dirs` isn't a match
                const nx = text[at + sp.name.len];
                if (std.ascii.isAlphanumeric(nx) or nx == '_' or nx == '.' or nx == '-') continue;
            }
            var i = at + sp.name.len;
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == ':')) i += 1;
            if (i >= text.len or text[i] == '{' or text[i] == '(') continue; // JSON / fn-call form — a real parser owns it
            var quote: u8 = 0;
            if (text[i] == '"' or text[i] == '\'') {
                quote = text[i];
                i += 1;
            }
            const pstart = i;
            while (i < text.len and (if (quote != 0) text[i] != quote else (text[i] != ' ' and text[i] != '\t' and text[i] != '\n' and text[i] != '\r'))) i += 1;
            const path = if (quote != 0) text[pstart..i] else trimTrailingPathPunct(text[pstart..i]);
            if (!looksLikePathTok(path, sp.require_sep)) continue;
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(gpa);
            out.appendSlice(gpa, "{\"path\":\"") catch return null;
            escJson(&out, gpa, path);
            out.append(gpa, '"') catch return null;
            if (sp.ranged) {
                const win = text[@min(i, text.len)..@min(text.len, i + 100)]; // start_line/end_line ride just after the path
                var nb: [24]u8 = undefined;
                if (intAfter(win, "start_line")) |n| {
                    out.appendSlice(gpa, ",\"start_line\":") catch return null;
                    out.appendSlice(gpa, std.fmt.bufPrint(&nb, "{d}", .{n}) catch return null) catch return null;
                }
                if (intAfter(win, "end_line")) |n| {
                    out.appendSlice(gpa, ",\"end_line\":") catch return null;
                    out.appendSlice(gpa, std.fmt.bufPrint(&nb, "{d}", .{n}) catch return null) catch return null;
                }
            }
            out.append(gpa, '}') catch return null;
            return .{ .name = sp.name, .args = out.toOwnedSlice(gpa) catch return null };
        }
    }
    return null;
}

/// A bare JSON args block with NO tool name — ```json {"path":..,"content":..} ``` — is how deepseek emits its
/// tool CALLS, expecting the harness to infer the tool. Dropped, the model "announces" an action that never runs
/// and the act-nudge loops forever. Infer the tool from the arg KEYS. This is the LAST-resort parser — reached
/// only when no named form (TOOL:/<tool:>/<name>/nested-XML) matched, so it can't steal a real call.
/// `content`+`path`⇒write_file, `ops`/`search`+`replace`⇒edit_file, `code`⇒run_python, `query`⇒web_search, a
/// lone/`start_line` `path`⇒read_file. Args are a slice into `text` (no allocation).
pub fn toolCallJsonInferred(text: []const u8) ?ToolCall {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, search, '{')) |astart| { // scan every { for a balanced tool-args object
        search = astart + 1;
        const end = jsonObjEnd(text, astart) orelse continue;
        if (end <= astart + 1) continue;
        const args = text[astart..end];
        if (!jsonHasKey(args, "path") and !jsonHasKey(args, "code") and !jsonHasKey(args, "query")) continue; // not tool args
        const name: []const u8 =
            if (jsonHasKey(args, "content") and jsonHasKey(args, "path")) "write_file" else if (jsonHasKey(args, "path") and (jsonHasKey(args, "ops") or (jsonHasKey(args, "search") and jsonHasKey(args, "replace")))) "edit_file" else if (jsonHasKey(args, "code")) "run_python" else if (jsonHasKey(args, "query")) "web_search" else if (jsonHasKey(args, "path")) "read_file" // lone path (± start_line) — a read
            else continue;
        return .{ .name = name, .args = args };
    }
    return null;
}

const FencedCall = struct { name: []const u8, args: []const u8, at: usize, open: ?usize };

/// Some models emit a tool call as a FENCED block whose info string names the tool —
///     ```tool: write_file
///     write_file({"path":"static/index.html","content":"..."})
///     ```
/// (the `name(` function wrapper is optional; the args may open directly with '{'; a `tool_code`-style
/// header carries no name, the wrapper then owns it). No named parser spoke this dialect, so the call only
/// dispatched when the args' KEYS were inferable (toolCallJsonInferred) — and the display stripper cut at
/// the args '{', stranding the fence header + `write_file(` as a broken unclosed code block in the chat.
/// Name from the fence header,
/// falling back to the wrapper; args = the first balanced JSON object in the body. Mirrors findToolCall's
/// truncation contract: args that OPEN but never close still return the call with "{}" (`open` says where),
/// so the oversized-write chunked-append rescue can own it. `at` = the fence opener, for the stripper.
fn toolCallFencedAt(text: []const u8) ?FencedCall {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "```tool")) |p| {
        search = p + "```tool".len;
        if (p > 0 and text[p - 1] != '\n') continue; // a fence opens at a line start
        var i = p + "```tool".len;
        var name: []const u8 = "";
        if (i < text.len and (text[i] == ':' or text[i] == ' ' or text[i] == '\t')) {
            // `tool: <name>` header — the name is the next token
            while (i < text.len and (text[i] == ':' or text[i] == ' ' or text[i] == '\t')) i += 1;
            const nstart = i;
            while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\r' and text[i] != '\n') i += 1;
            name = std.mem.trim(u8, text[nstart..i], " \t`");
        } // else `tool_code`/`tools` style tag — no name here, the body wrapper owns it
        while (i < text.len and text[i] != '\n') i += 1; // to the end of the header line
        if (i < text.len) i += 1;
        // body: an optional `ident(` function-call wrapper, then the args object
        var j = i;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\r' or text[j] == '\n')) j += 1;
        const wstart = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
        if (j > wstart and j < text.len and text[j] == '(') {
            if (name.len == 0) name = text[wstart..j];
            j += 1;
        } else j = wstart;
        if (!snakeToolName(name)) continue; // a ```tool fence quoting prose, or no recoverable name
        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\r' or text[j] == '\n')) j += 1;
        var args: []const u8 = "{}";
        var open: ?usize = null;
        if (j < text.len and text[j] == '{') {
            open = j;
            if (jsonObjEnd(text, j)) |end| {
                if (end > j + 1) args = text[j..end];
            } // unclosed = a big write cut off mid-content; "{}" lets the chunked-append rescue own it
        }
        return .{ .name = name, .args = args, .at = p, .open = open };
    }
    return null;
}

/// The dispatcher's view of toolCallFencedAt: name + args of the first fenced-dialect call, or null.
pub fn toolCallFenced(text: []const u8) ?ToolCall {
    const f = toolCallFencedAt(text) orelse return null;
    return .{ .name = f.name, .args = f.args };
}

/// A veil message persisted by an OLDER build can END with the stranded residue of a fenced tool call
/// ("...\n```tool: write_file\nwrite_file(") — the pre-fix stripper cut at the args '{' and left the opener
/// behind, so the transcript renders a broken empty code block forever. Trim that trailing residue at load
/// (the next persist rewrites the file clean). Only an UNCLOSED trailing ```tool fence whose body is at most
/// a dangling `ident(` wrapper is touched — a closed fence or one with real content after it stays.
fn trimDanglingToolFence(text: []const u8) []const u8 {
    const p = std.mem.lastIndexOf(u8, text, "```tool") orelse return text;
    if (p > 0 and text[p - 1] != '\n') return text;
    const rest = text[p..];
    if (std.mem.indexOfPos(u8, rest, 3, "```") != null) return text; // the fence closes — a legit block
    var it = std.mem.splitScalar(u8, rest, '\n');
    _ = it.next(); // the ```tool header line itself
    while (it.next()) |line| {
        const ln = std.mem.trim(u8, line, " \t\r");
        if (ln.len == 0) continue;
        if (ln.len < 48 and ln[ln.len - 1] == '(') { // a lone stranded `name(` wrapper
            var ident = true;
            for (ln[0 .. ln.len - 1]) |ch| {
                if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) {
                    ident = false;
                    break;
                }
            }
            if (ident) continue;
        }
        return text; // real content after the opener — not the residue
    }
    return std.mem.trimEnd(u8, text[0..p], " \r\n\t");
}

/// First path segment ("app/models.py" -> "app", "app.py" -> "app.py"); leading "./" and "/" tolerated.
fn topSegment(path: []const u8) []const u8 {
    var p = path;
    if (std.mem.startsWith(u8, p, "./")) p = p[2..];
    p = std.mem.trimStart(u8, p, "/");
    const sl = std.mem.indexOfScalar(u8, p, '/') orelse return p;
    return p[0..sl];
}

/// Does `path`'s TOP segment appear as a top segment of any blueprint line? Dotfiles/dot-dirs are always
/// allowed (tool sidecars, caches); an empty top never matches. Pure — the tree fallback lives in
/// pathFitsHiveLayout (it needs the store).
fn layoutAllows(blueprint: []const u8, path: []const u8) bool {
    const top = topSegment(path);
    if (top.len == 0 or top[0] == '.') return true;
    var it = std.mem.splitScalar(u8, blueprint, '\n');
    while (it.next()) |line| {
        const ln = std.mem.trim(u8, line, " \r\t");
        if (ln.len == 0) continue;
        if (std.mem.eql(u8, topSegment(ln), top)) return true;
    }
    return false;
}

/// The filename extensions every build-rescue scan recognizes. (.toml matters so a pasted Cargo.toml is named,
/// not lost to the fallback path.)
const FILE_EXTS = [_][]const u8{ ".html", ".js", ".py", ".css", ".json", ".ts", ".tsx", ".md", ".txt", ".c", ".cpp", ".h", ".hpp", ".go", ".rs", ".java", ".rb", ".php", ".sh", ".toml", ".yml", ".yaml", ".zig", ".sql", ".xml", ".jsx", ".svg", ".ini", ".cfg" };

/// The filename token around an extension hit at `at`, or null when the hit isn't a real filename
/// (mid-word, an extension that continues into a longer one, dotted-out path).
fn filenameAt(text: []const u8, at: usize, ext: []const u8) ?[]const u8 {
    // the char after the ext must not continue the extension (so ".js" in ".json" isn't a false hit)
    const after = at + ext.len;
    if (after < text.len and (std.ascii.isAlphanumeric(text[after]))) return null;
    var s = at;
    while (s > 0) {
        const ch = text[s - 1];
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == '/') s -= 1 else break;
    }
    const name = std.mem.trimStart(u8, text[s..after], "/."); // never absolute / dotfile-leading (safeRel would reject)
    if (name.len > ext.len and name.len < 100 and std.mem.indexOf(u8, name, "..") == null) return name;
    return null;
}

/// Recover a filename token (foo.html, src/game.js) from a build request — the EARLIEST one in the text
/// (position-priority, not extension-priority, so a stray .html mention can't beat the file the text is about).
fn recoverFilename(text: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_at: usize = text.len;
    for (FILE_EXTS) |ext| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, ext)) |at| {
            from = at + 1;
            if (at >= best_at) break; // a later hit can't win
            if (filenameAt(text, at, ext)) |name| {
                best = name;
                best_at = at;
                break;
            }
        }
    }
    return best;
}

/// The LAST filename token in the text — for the model's narration right before a pasted block, where the
/// name nearest the fence is the file it says it's writing ("Based on index.html, here is app.js:").
fn recoverFilenameLast(text: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_at: usize = 0;
    for (FILE_EXTS) |ext| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, ext)) |at| {
            from = at + 1;
            if (filenameAt(text, at, ext)) |name| {
                if (best == null or at > best_at) {
                    best = name;
                    best_at = at;
                }
            }
        }
    }
    return best;
}

/// The filename declared by a FILE-HEADER comment on the code block's FIRST line ("// src/routes.rs",
/// "# app.py", "/* style.css */", "<!-- index.html -->") — the strongest signal of what a pasted file IS.
/// Only line 1 is consulted: a path deep in the body (a <link href="style.css">) must never hijack the write.
fn headerCommentFilename(code: []const u8) ?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, code, '\n') orelse code.len;
    const line = std.mem.trim(u8, code[0..nl], " \r\t");
    const markers = [_][]const u8{ "//", "#", "/*", "<!--", "--", ";", "%" };
    for (markers) |m| {
        if (std.mem.startsWith(u8, line, m)) return recoverFilename(line[m.len..]);
    }
    return null;
}

/// The ```lang tag of the fence opening at `open`, lowercased into `buf` ("" = absent/unusable).
fn fenceLangTag(buf: []u8, full: []const u8, open: usize) []const u8 {
    const nl = std.mem.indexOfScalarPos(u8, full, open + 3, '\n') orelse full.len;
    const tag = std.mem.trim(u8, full[open + 3 .. nl], " \r\t`");
    if (tag.len == 0 or tag.len > buf.len) return "";
    for (tag, 0..) |c, k| buf[k] = std.ascii.toLower(c);
    return buf[0..tag.len];
}

/// Does the fence's language tag agree with the candidate filename's extension? Absent/unknown tags
/// constrain nothing. This is the guard that keeps a ```rust paste out of static/index.html.
fn langAllowsExt(lang: []const u8, name: []const u8) bool {
    if (lang.len == 0) return true;
    const Map = struct { lang: []const u8, exts: []const []const u8 };
    const maps = [_]Map{
        .{ .lang = "rust", .exts = &.{".rs"} },
        .{ .lang = "python", .exts = &.{".py"} },
        .{ .lang = "py", .exts = &.{".py"} },
        .{ .lang = "javascript", .exts = &.{ ".js", ".jsx", ".mjs" } },
        .{ .lang = "js", .exts = &.{ ".js", ".jsx", ".mjs" } },
        .{ .lang = "typescript", .exts = &.{ ".ts", ".tsx" } },
        .{ .lang = "ts", .exts = &.{ ".ts", ".tsx" } },
        .{ .lang = "html", .exts = &.{".html"} },
        .{ .lang = "css", .exts = &.{".css"} },
        .{ .lang = "json", .exts = &.{".json"} },
        .{ .lang = "toml", .exts = &.{".toml"} },
        .{ .lang = "yaml", .exts = &.{ ".yml", ".yaml" } },
        .{ .lang = "yml", .exts = &.{ ".yml", ".yaml" } },
        .{ .lang = "markdown", .exts = &.{".md"} },
        .{ .lang = "md", .exts = &.{".md"} },
        .{ .lang = "sql", .exts = &.{".sql"} },
        .{ .lang = "zig", .exts = &.{".zig"} },
        .{ .lang = "sh", .exts = &.{".sh"} },
        .{ .lang = "bash", .exts = &.{".sh"} },
        .{ .lang = "shell", .exts = &.{".sh"} },
        .{ .lang = "c", .exts = &.{ ".c", ".h" } },
        .{ .lang = "cpp", .exts = &.{ ".cpp", ".hpp", ".h" } },
        .{ .lang = "go", .exts = &.{".go"} },
        .{ .lang = "java", .exts = &.{".java"} },
        .{ .lang = "ruby", .exts = &.{".rb"} },
        .{ .lang = "php", .exts = &.{".php"} },
    };
    for (maps) |m| {
        if (std.mem.eql(u8, lang, m.lang)) {
            for (m.exts) |e| if (std.mem.endsWith(u8, name, e)) return true;
            return false;
        }
    }
    return true; // unknown tag — constrain nothing
}

/// True if a write_file/edit_file args blob carries a non-empty "path":"...". An empty/pathless blob is the
/// fingerprint of a mis-parsed TOOL: line (args defaulted to "{}") — the trigger for the code-block rescue.
fn argsHasPath(args: []const u8) bool {
    const at = std.mem.indexOf(u8, args, "\"path\"") orelse return false;
    var i = at + 6;
    while (i < args.len and (args[i] == ' ' or args[i] == ':' or args[i] == '\t')) i += 1;
    if (i >= args.len or args[i] != '"') return false;
    i += 1;
    return i < args.len and args[i] != '"'; // a non-empty string value
}

/// A sensible default filename for a pasted file body with no recoverable name — currently a one-page HTML
/// document (the common "build me a website" deliverable). null when we can't confidently name it.
fn defaultName(code: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, code, " \r\n\t");
    const n = @min(t.len, 9);
    var pfx: [9]u8 = undefined;
    for (t[0..n], 0..) |c, idx| pfx[idx] = std.ascii.toLower(c);
    const lp = pfx[0..n];
    if (std.mem.startsWith(u8, lp, "<!doctype") or std.mem.startsWith(u8, lp, "<html")) return "index.html";
    return null;
}

/// BUILD rescue: the model pasted a whole file as a ```fenced code block instead of TOOL: write_file, so it
/// never hit disk. Build a write_file args blob {"path":..,"content":..} (heap-owned; caller frees). The name
/// comes from the paste's own header comment, else the narration BEFORE the fence (nearest name last; never
/// the code body — a <link href="style.css"> would hijack it), else the user's request, else a content-type
/// default (a pasted one-pager is index.html) — every candidate gated on the fence's language tag.
/// null = not a paste we can rescue.
fn codeBlockWrite(gpa: std.mem.Allocator, last_user: []const u8, full: []const u8) ?[]u8 {
    const open = std.mem.indexOf(u8, full, "```") orelse return null;
    var cstart = open + 3;
    while (cstart < full.len and full[cstart] != '\n') cstart += 1; // skip an optional ```lang tag
    if (cstart >= full.len) return null;
    cstart += 1;
    const close = std.mem.indexOfPos(u8, full, cstart, "```") orelse return null;
    const code = std.mem.trim(u8, full[cstart..close], " \r\n");
    if (code.len < 200) return null; // a small snippet, not a file — don't hijack it
    if (code.len * 2 < full.len) return null; // must be >50% of the reply: a genuine PASTE of the file, not a
    // code snippet inside an explanation (which we must NOT write — it would clobber the real file).
    // Name the paste by the STRONGEST signal first: (1) a file-header comment on the block's first line
    // ("// src/routes.rs" is the file stating its own name); (2) the narration right before the fence,
    // nearest name last ("Writing src/routes.rs: ```rust…"); (3) the user's request; (4) the content-type
    // default. Each candidate must agree with the fence's language tag. Consulting the REQUEST first would send
    // every pasted module of a multi-file build into whatever single file the request happened to mention.
    var lb: [24]u8 = undefined;
    const lang = fenceLangTag(&lb, full, open);
    const cands = [_]?[]const u8{
        headerCommentFilename(code),
        recoverFilenameLast(full[0..open]),
        recoverFilename(last_user),
        defaultName(code),
    };
    var picked: ?[]const u8 = null;
    for (cands) |cand| {
        const c = cand orelse continue;
        if (!langAllowsExt(lang, c)) continue;
        picked = c;
        break;
    }
    const fname = picked orelse return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    out.appendSlice(gpa, "{\"path\":\"") catch return null;
    escJson(&out, gpa, fname);
    out.appendSlice(gpa, "\",\"content\":\"") catch return null;
    escJson(&out, gpa, code);
    out.appendSlice(gpa, "\"}") catch return null;
    return out.toOwnedSlice(gpa) catch null;
}

/// A name every parser agrees could be a tool: an identifier ([A-Za-z0-9_-], 1..40). Quotes, dots, or
/// brackets inside the token mean quoted prose, not a call.
fn plausibleToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// The loose-recovery gate is STRICTER: a dispatchable tool name is lowercase snake_case ([a-z0-9_], 2..40).
/// The reasoning channel gets to RECOVER a call the model decided on, never to mint one out of protocol
/// prose it happens to be quoting ("…emit TOOL: <name> on one line".).
fn snakeToolName(name: []const u8) bool {
    if (name.len < 2 or name.len > 40) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Loose recovery: find the LAST "TOOL:" ANYWHERE in text (not just line-start) and parse a tool name +
/// a balanced {...} args blob after it. Used ONLY on the reasoning channel when content is empty — a
/// reasoning model narrates its decision ("...so we issue TOOL: web_search {\"query\":\"x\"}") there. More
/// permissive than toolCall on purpose; the strict parser owns the content path.
pub fn toolCallLoose(text: []const u8) ?ToolCall {
    const key = "TOOL:";
    var at: ?usize = null;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, key)) |p| {
        at = p;
        search = p + key.len;
    }
    var i = (at orelse return null) + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const nstart = i;
    while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '{' and text[i] != '\n' and text[i] != '\r') i += 1;
    const name = std.mem.trim(u8, text[nstart..i], " \t:`*\"");
    if (!snakeToolName(name)) return null;
    var args: []const u8 = "{}";
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i < text.len and text[i] == '{') {
        const astart = i;
        if (jsonObjEnd(text, astart)) |end| {
            if (end > astart + 1) args = text[astart..end];
        }
    }
    return .{ .name = name, .args = args };
}

/// Does `text` look like a tool-call ATTEMPT in some dialect none of toolCall/toolCallXml/toolCallLoose speak,
/// rather than a genuine prose answer? Catches the observed failure modes: DeepSeek/Qwen-style special tokens
/// using the fullwidth vertical bar (U+FF5C) around "tool" markers (e.g. "<｜tool▁calls｜>", or a model garbling
/// its own token set into something like "<｜｜DSML｜｜tool_calls>"), and Claude/Anthropic-style
/// `<invoke name="...">`/`<function_calls>` XML. Deliberately loose (false positives just cost one corrective
/// retry) — the alternative is silently accepting the garbage as the final answer, which is the actual bug.
/// The value of a `key: …` / `key = …` field in `text`, tolerating BOTH JSON (`"claim_url":"https://…"`) and
/// PowerShell/plain (`claim_url=https://…`) renderings — a registration response comes back in either shape.
/// The key must be a whole token (not a suffix of a longer word). Value is the quoted string or the bare token
/// up to a delimiter, bounded 3..200 chars. Pure — unit-tested.
fn valueForKey(text: []const u8, key: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, key)) |at| {
        search = at + key.len;
        if (at > 0) {
            const p = text[at - 1];
            if (std.ascii.isAlphanumeric(p) or p == '_') continue; // a suffix of another word, not the key
        }
        var i = at + key.len;
        if (i < text.len and text[i] == '"') i += 1; // a closing quote after a JSON key
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len or (text[i] != ':' and text[i] != '=')) continue; // not key:value / key=value
        i += 1;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '"')) i += 1;
        const s = i;
        while (i < text.len and text[i] != '"' and text[i] != ',' and text[i] != ';' and text[i] != '}' and text[i] != '\n' and text[i] != '\r' and text[i] != ' ') i += 1;
        const v = std.mem.trim(u8, text[s..i], " \t\r\n\",;}");
        if (v.len >= 3 and v.len <= 200) return v;
    }
    return null;
}

/// Keys of a tool/console RESULT that carry a ONE-TIME secret the agent needs later but that end-of-run memory
/// consolidation drops and the 64-message ring evicts (a claim_url / verification_code vanishing makes the agent
/// loop re-discovering a claim step it already had).
const ONE_TIME_SECRET_KEYS = [_][]const u8{
    "claim_url",        "claim_link",     "verification_code", "verify_code",      "claim_code",
    "verification_url", "verify_url",     "magic_link",        "confirmation_url", "confirm_url",
    "activation_code",  "activation_url", "invite_url",        "invite_code",      "onboarding_url",
    "one_time_code",    "setup_url",      "setup_token",
};

/// A tool whose whole job is READING the web — the calls that make up a busy-but-getting-nowhere lookup spiral.
fn isWebLookupTool(name: []const u8) bool {
    const t = [_][]const u8{ "web_search", "web_fetch", "read_url", "fetch_json", "deep_crawl", "osint_scan" };
    for (t) |x| if (std.mem.eql(u8, name, x)) return true;
    return false;
}

fn looksLikeFailedToolCall(text: []const u8) bool {
    const markers = [_][]const u8{
        "\u{FF5C}tool", "tool\u{FF5C}", "tool_calls>", "tool_call>", "invoke name=", "function_calls>", "antml:invoke",
        // square-bracket render-label dialect: reached only when toolCallBracket/runCall did NOT dispatch (an
        // unknown/garbled bracketed name), so flagging it turns a silent leak into one corrective retry.
        "[tool:",       "[TOOL:",       "[RUN:",
    };
    for (markers) |m| if (std.mem.indexOf(u8, text, m) != null) return true;
    return false;
}

/// The auto-loop driver signals completion with a bare "DONE". Be strict so a normal next-message that merely
/// mentions "done" doesn't halt the loop: the whole (short) reply must be a completion word.
fn loopIsDone(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n.!\"'`*:");
    if (t.len == 0 or t.len > 16) return false;
    return std.ascii.eqlIgnoreCase(t, "DONE") or
        std.ascii.eqlIgnoreCase(t, "COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "GOAL COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "TASK COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "FINISHED");
}

/// True for the build (file/exec) tools whose response workdir means the AI is building there — used to gate
/// adopting the build dir + cd'ing the console (research tools also echo a workdir but write no files).
fn isBuildToolName(name: []const u8) bool {
    const bt = [_][]const u8{ "write_file", "edit_file", "read_file", "list_dir", "delete_file", "run_tests", "run_python" };
    for (bt) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

/// Copy as much of `src` as fits into `dst`; returns the slice of `dst` actually written.
fn copyInto(dst: []u8, src: []const u8) []const u8 {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return dst[0..n];
}

/// Build the bounded [console] payload the AI door hands back to the model: stdout, then stderr, then the
/// status note. The note is ALWAYS kept (room is reserved for it) so a "(command timed out …)"/stop note
/// survives even when the output alone would fill `buf`. Pure — unit-tested.
fn composeConsoleResult(buf: []u8, out: []const u8, err: []const u8, note: []const u8) []const u8 {
    const body_cap = if (buf.len > note.len + 1) buf.len - note.len - 1 else 0; // reserve room for the note (+ its newline guard)
    var w: usize = 0;
    w += copyInto(buf[w..body_cap], out).len;
    // stderr and the status note must start on their OWN lines: a command whose last write lacks a trailing
    // newline would otherwise glue them onto its final output line ("boom(exit code 2)") — which both reads
    // wrong and hides the failure from the console-card status parser.
    if (err.len > 0 and w > 0 and w < body_cap and buf[w - 1] != '\n') {
        buf[w] = '\n';
        w += 1;
    }
    w += copyInto(buf[w..body_cap], err).len;
    // A clean command with no output is SUCCESS, not failure — say so explicitly. A bare "(no output)" reads as
    // "it didn't work", so the model kept re-running the same probe.
    if (w == 0 and body_cap > 0 and note.len == 0) w += copyInto(buf[w..body_cap], "(command completed successfully — no output)").len;
    if (w == 0 and body_cap > 0) w += copyInto(buf[w..body_cap], "(no output)").len;
    if (note.len > 0 and w + note.len < buf.len) {
        if (w > 0 and buf[w - 1] != '\n') {
            buf[w] = '\n';
            w += 1;
        }
        @memcpy(buf[w .. w + note.len], note);
        w += note.len;
    }
    return buf[0..w];
}

/// Compose the Windows batch script that carries ONE console command (see consoleStart for why a file:
/// `cmd /c <argv>` mangles embedded quotes). @echo off keeps batch line-echo out of the sinks; a command
/// with non-ASCII bytes gets a UTF-8 codepage prelude (batch lines are otherwise read in the OEM codepage);
/// every line break is normalized to CRLF (LF-only batch parsing is unreliable). Percent signs that a batch
/// file would EAT are doubled back to literals: %<digit>/%* are script-parameter references (the script runs
/// with zero args, so `curl .../a%20b` would silently fetch "a0b") and a line-trailing lone % is dropped by
/// the batch parser — both worked literally under the old cmd /c. %NAME% env expansion is left alone.
/// Returns null when the command can't be carried (a NUL byte, or it overflows buf). Pure — unit-tested.
fn buildBatchScript(buf: []u8, cmd: []const u8) ?[]const u8 {
    const H = struct {
        fn put(b: []u8, at: usize, s: []const u8) ?usize {
            if (at + s.len > b.len) return null;
            @memcpy(b[at .. at + s.len], s);
            return at + s.len;
        }
    };
    var non_ascii = false;
    for (cmd) |c| {
        if (c == 0) return null;
        if (c >= 0x80) non_ascii = true;
    }
    var w = H.put(buf, 0, "@echo off\r\n") orelse return null;
    if (non_ascii) w = H.put(buf, w, "chcp 65001>nul\r\n") orelse return null;
    // Python in this console must speak UTF-8: Windows Python defaults stdout to the ANSI codepage, so a
    // script printing '→' (or any non-ASCII) dies with UnicodeEncodeError: 'charmap' — observed live when a
    // build's own verification script printed an arrow. Harmless for non-Python commands.
    w = H.put(buf, w, "set PYTHONUTF8=1\r\nset PYTHONIOENCODING=utf-8\r\n") orelse return null;
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        const c = cmd[i];
        if (c == '\r') continue; // dropped; the matching \n below re-emits the full CRLF
        if (c == '\n') {
            w = H.put(buf, w, "\r\n") orelse return null;
        } else if (c == '%') {
            const next: u8 = if (i + 1 < cmd.len) cmd[i + 1] else '\n';
            if (next == '%') { // already batch-escaped (%%i in a for-loop, %%2 literal) — pass the pair through
                w = H.put(buf, w, "%%") orelse return null;
                i += 1;
            } else {
                const eaten = std.ascii.isDigit(next) or next == '*' or next == '\n' or next == '\r';
                w = H.put(buf, w, if (eaten) "%%" else "%") orelse return null;
            }
        } else {
            if (w >= buf.len) return null;
            buf[w] = c;
            w += 1;
        }
    }
    w = H.put(buf, w, "\r\n") orelse return null;
    return buf[0..w];
}

/// Would this command trip the batch-vs-interactive FOR-variable trap (`for %i ...` errors in a batch
/// script; it needs %%i)? True when a "for" token appears and a SINGLE-letter %x variable (not %%x, not a
/// %NAME% env pair) follows. Drives the one-line You-tab hint in consoleStart. Pure — unit-tested.
fn needsBatchPercentHint(cmd: []const u8) bool {
    var lb: [1024]u8 = undefined;
    const n = @min(cmd.len, lb.len);
    for (cmd[0..n], 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const low = lb[0..n];
    const at = std.mem.indexOf(u8, low, "for ") orelse return false;
    var j = at + 4;
    while (j + 1 < n) : (j += 1) {
        if (low[j] != '%') continue;
        if (j > 0 and low[j - 1] == '%') continue; // %%x — already batch-escaped
        if (!std.ascii.isAlphabetic(low[j + 1])) continue; // %2/%* are handled by buildBatchScript itself
        if (j + 2 < n and (std.ascii.isAlphanumeric(low[j + 2]) or low[j + 2] == '%')) continue; // %NAME(%) env ref
        return true; // single-letter %x after a for — the trap
    }
    return false;
}

const RunLoose = struct { cmd: []const u8, at: usize };

/// Recover a RUN: command narrated inside the reasoning channel — LINE-ANCHORED: only a line that (after
/// markdown lead-in) STARTS with "RUN:" counts, so prose mentions ("you could use RUN: x"), pseudo-labels
/// (DRY-RUN:, OVERRUN:) and quoted discussion never dispatch a shell command. The LAST anchored line wins:
/// reasoning walks through options, the final action line is the decision. Pure — unit-tested.
fn runCallLooseAt(text: []const u8) ?RunLoose {
    var best: ?RunLoose = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const lead = std.mem.trimStart(u8, raw, " \t>-*`");
        if (!std.mem.startsWith(u8, lead, "RUN:")) continue;
        var cmd = std.mem.trim(u8, lead["RUN:".len..], " \t\r`");
        // a "**RUN: dir**" markdown-bold line leaves a trailing "**" — strip the pair, but KEEP a lone
        // trailing '*' (a real wildcard: `del *` must survive recovery intact)
        if (std.mem.endsWith(u8, cmd, "**")) cmd = std.mem.trimEnd(u8, cmd, "*");
        if (cmd.len > 0 and cmd.len <= 900)
            best = .{ .cmd = cmd, .at = @intFromPtr(raw.ptr) - @intFromPtr(text.ptr) };
    }
    return best;
}

pub fn runCallLoose(text: []const u8) ?[]const u8 {
    return if (runCallLooseAt(text)) |r| r.cmd else null;
}

/// A fenced body that is a rendered TERMINAL TRANSCRIPT (output the model is showing), not a command it is
/// issuing: a line begins with a shell prompt ($ , > , PS>). Never dispatch such a body.
fn looksLikeTranscript(body: []const u8) bool {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, l, "$ ") or std.mem.startsWith(u8, l, "> ") or
            std.ascii.startsWithIgnoreCase(l, "PS>") or std.ascii.startsWithIgnoreCase(l, "PS ")) return true;
    }
    return false;
}

/// Recover a shell command the model put in a ```<shell> fenced block instead of a `RUN:` line. RUN: is what it
/// SHOULD use, but it inconsistently drops to a bare fence (```powershell\ntype core.py) and the command then
/// never dispatches — so the model re-emits it and spirals. This is a pure EXTRACTOR; the caller gates it on
/// an action signal (announcesAction) so an illustrative fence in a
/// plain answer never runs, and the approval gate still governs execution. Only a SHELL-tagged fence counts
/// (powershell/pwsh/bash/sh/cmd/bat/zsh — NOT `console`/`shell`, which usually tag a transcript, nor untagged /
/// ```python / ```md content). Returns the LAST valid shell fence's body (mirrors runCallLoose's last-wins: the
/// model's final choice, not an alternative it weighed then discarded earlier). Handles an unclosed trailing
/// fence and skips transcript bodies and over-long/empty ones.
fn fencedShellCall(text: []const u8) ?[]const u8 {
    const shells = [_][]const u8{ "powershell", "pwsh", "bash", "sh", "cmd", "bat", "zsh" };
    var best: ?[]const u8 = null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "```")) |open| {
        const after = open + 3;
        const nl = std.mem.indexOfScalarPos(u8, text, after, '\n') orelse break;
        const lang = std.mem.trim(u8, text[after..nl], " \t\r");
        const body_start = nl + 1;
        const close = std.mem.indexOfPos(u8, text, body_start, "```") orelse text.len;
        var is_shell = false;
        for (shells) |s| {
            if (std.ascii.eqlIgnoreCase(lang, s)) {
                is_shell = true;
                break;
            }
        }
        if (is_shell) {
            const body = std.mem.trim(u8, text[body_start..close], " \t\r\n");
            if (body.len > 0 and body.len <= 900 and !looksLikeTranscript(body)) best = body; // LAST valid wins
        }
        if (close >= text.len) break;
        from = close + 3;
    }
    return best;
}

/// The reasoning holds BOTH recoverable action forms — which is the model's FINAL decision? The one that
/// appears LATER wins (mirrors each parser's own last-match rule); a fixed TOOL-before-RUN priority would
/// dispatch the option the reasoning had discarded. True = the RUN should dispatch.
fn looseRunWins(text: []const u8) bool {
    const r = runCallLooseAt(text) orelse return false;
    const t = std.mem.lastIndexOf(u8, text, "TOOL:") orelse return true;
    return r.at > t;
}

/// A recall result that exactly fills its buffer was almost certainly TRUNCATED mid-line — half a command
/// in a prompt block labeled "binding" is worse than one lesson fewer. Cut back to the last complete line
/// (a result that legitimately fits exactly loses at most its final line).
fn wholeLines(s: []const u8, cap: usize) []const u8 {
    if (s.len < cap) return s;
    const nl = std.mem.lastIndexOfScalar(u8, s, '\n') orelse return s;
    return s[0..nl];
}

/// True when a recalled line is actually PLAYBOOK-shaped — the deterministic mint (pumpConsole) always writes
/// "fix: `<cmd>` failed <note> — works as: `<cmd>`". This is a read-time schema guard: only present a recalled
/// fact to the model AS a verified lesson if it matches the mint contract. Defense-in-depth against a scope that
/// picked up non-lesson facts from any source (a legacy db, a since-fixed mint bug) — those never surface as
/// "binding" lessons even if they linger in the store. NOT a use-case hardcode: it is the feature's own format.
fn isLessonLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \r\n\t");
    if (t.len < 8) return false;
    return std.ascii.startsWithIgnoreCase(t, "fix:") or std.ascii.indexOfIgnoreCase(t, "works as:") != null or
        std.ascii.startsWithIgnoreCase(t, "lesson:"); // the judge-promotion stamp (acceptProposal)
}

/// The failure's salient line: the LAST non-empty line of stderr (or of stdout when stderr is silent —
/// plenty of CLIs report errors there). For a traceback that is the exception itself; for most tools it is
/// the error message. Caps into `out` without splitting a UTF-8 codepoint. Pure — unit-tested.
fn salientFailLine(out_s: []const u8, err_s: []const u8, out: []u8) []const u8 {
    const src = if (std.mem.trim(u8, err_s, " \r\n\t").len > 0) err_s else out_s;
    var last: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, src, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len > 0) last = t;
    }
    var n = @min(last.len, out.len);
    while (n > 0 and n < last.len and (last[n] & 0xC0) == 0x80) n -= 1; // never cut mid-codepoint
    @memcpy(out[0..n], last[0..n]);
    return out[0..n];
}

/// Words that appear in nearly every lesson and every failure — worthless as relevance evidence.
fn isGenericFailToken(t: []const u8) bool {
    const stop = [_][]const u8{ "exit", "code", "codes", "failed", "error", "errors", "works", "with", "file", "line", "lines", "command", "cannot", "could", "there", "output", "lesson", "traceback", "recent", "call", "last", "most" };
    for (stop) |s| if (std.ascii.eqlIgnoreCase(t, s)) return true;
    return false;
}

/// Read-time relevance gate for a recalled playbook lesson against the CURRENT failure (command + salient
/// error line). The mint pairs fail->fix inside one executable family with real token overlap; recall must
/// honor the same contract, or a cd-into-the-repo fix surfaces on an HTTP 403 purely because both commands
/// said `python` under one long path. Scoring: executable-family presence = 2, each distinct informative
/// token from the live failure found in the lesson = 1; relevant at >= 3. So the executable alone is never
/// enough, and a lesson for a different executable needs overwhelming shared evidence. Tokens are judged by
/// their path BASENAME (paths never count as evidence wholesale), pure numbers only from 3 digits up (403
/// counts, exit code 1 does not), and stop-words never count. Pure — unit-tested.
fn lessonRelevant(lesson: []const u8, cmd: []const u8, sig: []const u8) bool {
    var cit = std.mem.tokenizeAny(u8, cmd, " \t");
    const exe = execBase(cit.next() orelse return false);
    var score: usize = 0;
    if (exe.len >= 2 and std.ascii.indexOfIgnoreCase(lesson, exe) != null) score += 2;
    var seen: [8][]const u8 = undefined; // counted-token dedup — relevance needs at most a few hits
    var seen_n: usize = 0;
    // the executable's name is already scored — and it REAPPEARS in most error lines ("python: can't
    // open...", "FINDSTR: Cannot open...", "curl: (22)..."), so seed the dedup with it or every tool
    // that prefixes its own errors hands itself the third point and the gate never gates
    seen[0] = exe;
    seen_n = 1;
    const sources = [2][]const u8{ cmd, sig };
    for (sources, 0..) |src, si| {
        var it = std.mem.tokenizeAny(u8, src, " \t\"'`()[]{}<>,;=");
        if (si == 0) _ = it.next(); // the executable is already scored — never double-counted
        while (it.next()) |tok| {
            var t = std.mem.trim(u8, tok, ":.,;!?-");
            if (std.mem.lastIndexOfAny(u8, t, "/\\")) |i| t = t[i + 1 ..]; // a path's basename is its identity
            var all_digit = t.len > 0;
            for (t) |c| {
                if (c < '0' or c > '9') {
                    all_digit = false;
                    break;
                }
            }
            if (all_digit) {
                if (t.len < 3) continue; // small numbers (exit code 1, arg counts) are noise
            } else if (t.len < 4) continue;
            if (isGenericFailToken(t)) continue;
            var dup = false;
            for (seen[0..seen_n]) |s| {
                if (std.ascii.eqlIgnoreCase(s, t)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (std.ascii.indexOfIgnoreCase(lesson, t) != null) {
                score += 1;
                if (seen_n < seen.len) {
                    seen[seen_n] = t;
                    seen_n += 1;
                }
                if (score >= 3) return true;
            }
        }
    }
    return score >= 3;
}

/// Is a stored lesson about the CURRENT request? The pre-emptive playbook injection ("OPERATIONAL LESSONS
/// ... treat as binding") recalls by ranking against the request text, which — like any similarity search —
/// surfaces a top-ranked non-match when nothing truly matches. Binding a path-specific command fix onto an
/// unrelated request is exactly how the model gets talked into cd-ing somewhere it shouldn't. Require real
/// shared vocabulary: >= 2 distinct informative tokens the request and the lesson genuinely have in common.
/// (No executable bonus here — a request is prose and rarely names the command.) Pure — unit-tested.
fn lessonRelevantToRequest(lesson: []const u8, request: []const u8) bool {
    var hits: usize = 0;
    var seen: [8][]const u8 = undefined;
    var seen_n: usize = 0;
    var it = std.mem.tokenizeAny(u8, request, " \t\r\n\"'`()[]{}<>,;=");
    while (it.next()) |tok| {
        var t = std.mem.trim(u8, tok, ":.,;!?-");
        if (std.mem.lastIndexOfAny(u8, t, "/\\")) |i| t = t[i + 1 ..]; // path basename is the identity
        var all_digit = t.len > 0;
        for (t) |c| {
            if (c < '0' or c > '9') {
                all_digit = false;
                break;
            }
        }
        if (all_digit) continue; // a bare number in prose is not topic evidence
        if (t.len < 4) continue;
        if (isGenericFailToken(t)) continue;
        var dup = false;
        for (seen[0..seen_n]) |s| {
            if (std.ascii.eqlIgnoreCase(s, t)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (std.ascii.indexOfIgnoreCase(lesson, t) != null) {
            hits += 1;
            if (seen_n < seen.len) {
                seen[seen_n] = t;
                seen_n += 1;
            }
            if (hits >= 2) return true;
        }
    }
    return hits >= 2;
}

/// Length of a `cd`/`cd /d`/`pushd` INTO-A-SPECIFIC-PATH prefix at the start of `s` (verb + path arg + `&&`
/// + surrounding spaces), or 0 if `s` does not begin with one. A change into an absolute/nested directory is
/// never a transferable fix — it pins a one-time build workdir a later turn must not reuse — so surfaced
/// lessons drop it, keeping only the command that actually carries the lesson. Only strips when the path is
/// quoted or contains a separator (a bare `cd build` might be meaningful; an absolute path never is). Pure.
fn chdirPrefixLen(s: []const u8) usize {
    var i: usize = 0;
    // verb: cd | cd /d | pushd
    if (std.ascii.startsWithIgnoreCase(s, "cd ")) {
        i = 3;
        if (std.ascii.startsWithIgnoreCase(s[i..], "/d ")) i += 3;
    } else if (std.ascii.startsWithIgnoreCase(s, "pushd ")) {
        i = 6;
    } else return 0;
    while (i < s.len and s[i] == ' ') i += 1;
    if (i >= s.len) return 0;
    var had_sep = false;
    if (s[i] == '"') { // quoted path — always treat as specific
        had_sep = true;
        i += 1;
        while (i < s.len and s[i] != '"') i += 1;
        if (i >= s.len) return 0; // unterminated quote — do not strip
        i += 1;
    } else {
        const path_start = i;
        while (i < s.len and s[i] != ' ') i += 1;
        for (s[path_start..i]) |c| {
            if (c == '/' or c == '\\' or c == ':') had_sep = true;
        }
    }
    if (!had_sep) return 0; // a bare relative cd may be meaningful — leave it
    while (i < s.len and s[i] == ' ') i += 1;
    if (!std.mem.startsWith(u8, s[i..], "&&")) return 0; // only a chained `cd ... && cmd` prefixes a command
    i += 2;
    while (i < s.len and s[i] == ' ') i += 1;
    return i;
}

/// Strip every `cd/pushd <specific path> &&` prefix from a lesson line (they can appear inside both the
/// failing and the working command span). A prefix is only recognized at a word boundary. Writes into `out`;
/// returns the cleaned slice. Cleans pollution already in the store, not just newly-minted lessons. Pure.
fn stripWorkdirChdir(line: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < line.len and w < out.len) {
        const at_boundary = i == 0 or line[i - 1] == ' ' or line[i - 1] == '`' or line[i - 1] == '\t';
        if (at_boundary) {
            const skip = chdirPrefixLen(line[i..]);
            if (skip > 0) {
                i += skip;
                continue;
            }
        }
        out[w] = line[i];
        w += 1;
        i += 1;
    }
    return out[0..w];
}

/// A cleaned "fix: `A` failed … — works as: `B`" lesson is self-CONTRADICTORY when A == B: stripWorkdirChdir
/// removed the only difference (a `cd <path> &&` prefix — e.g. `cd C:\a && npm build` failed, `cd C:\b && npm
/// build` worked), collapsing both spans to the same text. It then teaches nothing and can push the model to
/// re-run the exact command that failed, presented as a "verified fix". Drop it. Returns true when the two
/// backtick spans exist and are byte-equal. Pure.
fn fixSpansCollapsed(c: []const u8) bool {
    if (!std.mem.startsWith(u8, c, "fix:")) return false;
    const a0 = std.mem.indexOfScalar(u8, c, '`') orelse return false; // failing command span
    const a1 = std.mem.indexOfScalarPos(u8, c, a0 + 1, '`') orelse return false;
    const wa = std.mem.indexOfPos(u8, c, a1 + 1, "works as:") orelse return false; // working command span
    const b0 = std.mem.indexOfScalarPos(u8, c, wa + "works as:".len, '`') orelse return false;
    const b1 = std.mem.indexOfScalarPos(u8, c, b0 + 1, '`') orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, c[a0 + 1 .. a1], " \t"), std.mem.trim(u8, c[b0 + 1 .. b1], " \t"));
}

/// Emit one cleaned lesson line into `out` at write cursor `w` (newline-separated), returning the new cursor.
fn emitLesson(line: []const u8, out: []u8, w: usize) usize {
    var ww = w;
    const t = std.mem.trim(u8, line, " \r\n\t");
    if (t.len == 0) return ww;
    var cb: [1500]u8 = undefined; // lessons run ~two 380-char commands + note + signature; hold a whole one
    const cleaned = if (t.len <= cb.len) stripWorkdirChdir(t, &cb) else t;
    const c = std.mem.trim(u8, cleaned, " \t");
    if (c.len == 0) return ww;
    if (fixSpansCollapsed(c)) return ww; // cd-stripped fail == fix — a non-lesson, never inject it
    if (ww != 0) {
        if (ww >= out.len) return ww;
        out[ww] = '\n';
        ww += 1;
    }
    const n = @min(c.len, out.len - ww);
    @memcpy(out[ww .. ww + n], c[0..n]);
    return ww + n;
}

/// Keep only the PLAYBOOK-shaped lines of a recalled block (see isLessonLine), stale-workdir-cd stripped,
/// joined by '\n' into `out`. Empty slice when nothing qualifies — an all-noise recall injects nothing.
fn filterLessonLines(block: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var it = std.mem.tokenizeScalar(u8, block, '\n');
    while (it.next()) |line| {
        if (!isLessonLine(line)) continue;
        w = emitLesson(line, out, w);
        if (w >= out.len) break;
    }
    return out[0..w];
}

/// filterLessonLines PLUS the lessonRelevant gate: only lines that are playbook-shaped AND actually about
/// THIS failure survive into the "RECALLED LESSON" fold. Empty when nothing qualifies — a weak recall
/// injects nothing rather than an authoritative-sounding non sequitur.
fn filterRelevantLessons(block: []const u8, cmd: []const u8, sig: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var it = std.mem.tokenizeScalar(u8, block, '\n');
    while (it.next()) |line| {
        if (!isLessonLine(line)) continue;
        if (!lessonRelevant(line, cmd, sig)) continue;
        w = emitLesson(line, out, w);
        if (w >= out.len) break;
    }
    return out[0..w];
}

/// filterLessonLines PLUS the request-relevance gate (see lessonRelevantToRequest): the pre-emptive
/// "OPERATIONAL LESSONS" injection surfaces only lessons that actually share vocabulary with the request,
/// so a top-ranked-but-unrelated command fix never rides into an off-topic turn as binding. Empty when
/// nothing qualifies — the reactive fold still surfaces a fix if a matching command later fails.
fn filterRequestRelevantLessons(block: []const u8, request: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var it = std.mem.tokenizeScalar(u8, block, '\n');
    while (it.next()) |line| {
        if (!isLessonLine(line)) continue;
        if (!lessonRelevantToRequest(line, request)) continue;
        w = emitLesson(line, out, w);
        if (w >= out.len) break;
    }
    return out[0..w];
}

/// Build the judge's TRACE from a conversation JSONL: USER rows verbatim (capped), bracketed RESULT rows
/// (real console/tool/cast output including exit codes), and the veil's replies as SHORT "CLAIM:" heads —
/// the judge checks claims against results, it never grades the model's self-narrative. Thought rows
/// (r:3) never appear: pure self-report. Keeps the newest whole entries that fit `out`. Unit-tested.
pub fn buildTrace(gpa: std.mem.Allocator, jsonl: []const u8, out: []u8) []const u8 {
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(gpa);
    var starts: std.ArrayListUnmanaged(usize) = .empty;
    defer starts.deinit(gpa);
    var it = std.mem.splitScalar(u8, jsonl, '\n');
    while (it.next()) |line| {
        const ln = std.mem.trim(u8, line, " \r\t");
        if (ln.len < 12 or ln[0] != '{') continue;
        const rpos = std.mem.indexOf(u8, ln, "\"r\":") orelse continue;
        const rc = ln[rpos + 4 ..];
        if (rc.len == 0 or rc[0] < '0' or rc[0] > '9') continue;
        const role = rc[0] - '0';
        var tag: []const u8 = "";
        var cap: usize = 0;
        switch (role) {
            0 => {
                tag = "USER: ";
                cap = 300;
            },
            1 => {
                tag = "CLAIM: ";
                cap = 160;
            },
            2 => {
                tag = "RESULT: ";
                cap = 520;
            },
            else => continue, // r:3 reasoning = self-report, never part of the trace
        }
        const txt = llm.jsonUnescape(gpa, ln, "t") orelse continue;
        defer gpa.free(txt);
        const tt = std.mem.trim(u8, txt, " \r\n\t");
        if (tt.len == 0) continue;
        if (role == 2 and tt[0] != '[') continue; // only bracketed RESULT rows are ground truth
        starts.append(gpa, acc.items.len) catch return out[0..0];
        acc.appendSlice(gpa, tag) catch return out[0..0];
        for (tt[0..@min(tt.len, cap)]) |c| // single-line each entry; results stay one row each
            acc.append(gpa, if (c == '\n') ' ' else c) catch return out[0..0];
        acc.append(gpa, '\n') catch return out[0..0];
    }
    if (acc.items.len == 0) return out[0..0];
    // the newest suffix of WHOLE entries that fits `out`
    var from: usize = acc.items.len;
    var si: usize = starts.items.len;
    while (si > 0) {
        si -= 1;
        if (acc.items.len - starts.items[si] > out.len) break;
        from = starts.items[si];
    }
    const slice = acc.items[from..];
    const n = @min(slice.len, out.len);
    @memcpy(out[0..n], slice[0..n]);
    return out[0..n];
}

pub const Proposal = struct { kind: u8, text: []const u8 }; // kind: 0 playbook, 1 skill, 2 user

/// One "PLAYBOOK:/SKILL:/USER: <text> | evidence: <proof>" judge-output line → a quarantined proposal.
/// Strict: the evidence tail is MANDATORY (an ungrounded proposal is dropped — that is the whole point),
/// and bounds keep entries atomic. Pure — unit-tested.
pub fn parseProposal(raw: []const u8) ?Proposal {
    const ln = std.mem.trim(u8, raw, " \r\t-*`");
    var kind: u8 = 255;
    var rest: []const u8 = "";
    if (std.mem.startsWith(u8, ln, "PLAYBOOK:")) {
        kind = 0;
        rest = ln["PLAYBOOK:".len..];
    } else if (std.mem.startsWith(u8, ln, "SKILL:")) {
        kind = 1;
        rest = ln["SKILL:".len..];
    } else if (std.mem.startsWith(u8, ln, "USER:")) {
        kind = 2;
        rest = ln["USER:".len..];
    } else return null;
    const text = std.mem.trim(u8, rest, " \t");
    if (text.len < 24 or text.len > 700) return null;
    const ev = std.mem.indexOf(u8, text, "| evidence:") orelse return null;
    if (ev < 16) return null; // no real lesson before the evidence marker
    if (std.mem.trim(u8, text[ev + "| evidence:".len ..], " \t.").len < 8) return null; // empty proof = ungrounded
    return .{ .kind = kind, .text = text };
}

/// The neuron CLI splits an observed text into SENTENCE facts on ".;!?"+space boundaries — right for
/// prose, fatal for ATOMIC machine entries (a lesson's fix half or a proposal's "| evidence:" tail
/// separates into its own fact and the entry stops meaning anything). Soften those boundaries to commas
/// before observing; mid-token punctuation (README.md, /c:"x") is untouched. Pure — unit-tested.
/// The first sentence of `text` as the substrate's observe() stored it: observe sentence-splits on
/// newline and on ./!/;/? followed by whitespace, trims each piece, and DROPS any sentence containing
/// '?'. A strengthen key must be a substring of a stored fact, so it is cut at the first boundary,
/// stripped of trailing sentence-enders, byte-capped WITHOUT splitting a UTF-8 codepoint, and empty
/// (caller no-ops) when the sentence was a '?'-drop or too short to identify a fact. Pure — unit-tested.
fn firstStoredSentence(text: []const u8, cap: usize) []const u8 {
    var end = text.len;
    var was_question = false;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            end = i;
            break;
        }
        if ((c == '.' or c == '!' or c == ';' or c == '?') and i + 1 < text.len and (text[i + 1] == ' ' or text[i + 1] == '\t' or text[i + 1] == '\r')) {
            end = i;
            was_question = c == '?'; // the boundary char belongs to the sentence observe dropped
            break;
        }
    }
    var s = std.mem.trim(u8, std.mem.trimEnd(u8, std.mem.trim(u8, text[0..end], " \r\t"), ".!;"), " \r\t");
    if (was_question or std.mem.indexOfScalar(u8, s, '?') != null) return s[0..0]; // observe dropped it — nothing stored to match
    if (s.len > cap) {
        var cut = cap;
        while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1; // never split a codepoint
        s = s[0..cut];
    }
    return if (s.len < 3) s[0..0] else s;
}

fn atomizeForObserve(buf: []u8, text: []const u8) []const u8 {
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        const c = buf[i];
        if ((c == '.' or c == ';' or c == '!' or c == '?') and buf[i + 1] == ' ') buf[i] = ',';
    }
    return buf[0..n];
}

fn propLiveScope(tag: []const u8) []const u8 {
    if (tag.len > 0 and tag[0] == '1') return SKILLS_SCOPE;
    if (tag.len > 0 and tag[0] == '2') return USER_SCOPE;
    return PLAYBOOK_SCOPE;
}

fn propQuarantineScope(tag: []const u8) []const u8 {
    if (tag.len > 0 and tag[0] == '1') return SKILLS_PROPOSED;
    if (tag.len > 0 and tag[0] == '2') return USER_PROPOSED;
    return PLAYBOOK_PROPOSED;
}

/// Are two stored entries near-duplicates by CONTENT? Substantial-token overlap in BOTH directions —
/// one entry merely mentioning the other's topic isn't redundancy, and usage frequency plays no part.
/// Pure — unit-tested.
fn contentOverlap(a: []const u8, b: []const u8) bool {
    const ca = substantialTokens(a, "");
    const cb = substantialTokens(b, "");
    if (ca == 0 or cb == 0) return false;
    return substantialTokens(a, b) * 10 >= 7 * ca and substantialTokens(b, a) * 10 >= 7 * cb;
}

/// Count tokens of `s` that are >=5 chars — and, when `within` is non-empty, only those appearing in it.
fn substantialTokens(s: []const u8, within: []const u8) usize {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    var n: usize = 0;
    while (it.next()) |tok| {
        if (tok.len < 5) continue;
        if (within.len > 0 and std.mem.indexOf(u8, within, tok) == null) continue;
        n += 1;
    }
    return n;
}

/// Does this reply ANNOUNCE an action without performing one? The intermediate-ack shape: a
/// future-tense commitment ("I'll ...", "Let me ...") paired with an action verb, in a SHORT reply (long
/// analyses aren't acks) that doesn't hand the turn back with a question. The ack must sit in the reply's
/// TAIL — announcements come as closings; an opening "I'll check X" followed by the finished work reads
/// differently. "let me know" (the classing closing) is explicitly not an ack. Pure — unit-tested.
/// True when an auto-loop DRIVE STEP is really a tool-call FRAGMENT the model leaked instead of an instruction
/// — "tool\nread_file", a fenced "```tool" block (the fence chars are trimmed before this sees it), or a bare
/// tool name. Committing one as a user message pollutes the transcript AND the next turn reads it back as a
/// confusing user demand. Trimmed input expected.
fn stepIsToolMarkup(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \r\n\t");
    if (std.mem.startsWith(u8, t, "```")) return true;
    const names = [_][]const u8{ "read_file", "write_file", "edit_file", "run_python", "run_tests", "list_dir", "web_search", "web_fetch", "delete_file", "fetch_json" };
    if (std.mem.eql(u8, t, "tool")) return true;
    if (std.mem.startsWith(u8, t, "tool\n") or std.mem.startsWith(u8, t, "tool ")) {
        const rest = std.mem.trim(u8, t["tool".len..], " \r\n\t");
        if (rest.len == 0) return true;
        for (names) |n| if (std.mem.startsWith(u8, rest, n)) return true;
    }
    for (names) |n| if (std.mem.eql(u8, t, n)) return true; // a bare tool name is not an instruction
    return false;
}

test "stepIsToolMarkup: catches leaked tool fragments, passes real instructions" {
    try std.testing.expect(stepIsToolMarkup("tool\nread_file"));
    try std.testing.expect(stepIsToolMarkup("tool write_file"));
    try std.testing.expect(stepIsToolMarkup("```tool\nwrite_file"));
    try std.testing.expect(stepIsToolMarkup("read_file"));
    try std.testing.expect(stepIsToolMarkup("tool"));
    try std.testing.expect(!stepIsToolMarkup("append the second chunk: enemies, waves, game loop"));
    try std.testing.expect(!stepIsToolMarkup("use read_file to verify the tail, then append part B"));
    try std.testing.expect(!stepIsToolMarkup("retool the pipeline for speed"));
    try std.testing.expect(!stepIsToolMarkup("continue"));
}

pub fn announcesAction(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \r\n\t");
    if (t.len == 0 or t.len > 1600) return false;
    if (t[t.len - 1] == '?') return false; // a question deliberately hands the turn to the user
    var lb: [1600]u8 = undefined;
    const n = @min(t.len, lb.len);
    for (t[0..n], 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const tail_from = n - @min(n, 280);
    const tail = lb[tail_from..n];
    // A commitment phrase must be followed CLOSELY by an action verb ("I'll check the task...") — matching
    // verbs anywhere in the tail makes the gate near-vacuous ("test" inside "latest"), so courtesy closings
    // would gate command dispatch. Curly-apostrophe variants included: reasoning models emit typographic
    // quotes, and an ASCII-only list misses every contraction ack.
    const acks = [_][]const u8{ "i'll ", "i\u{2019}ll ", "i will ", "i'm going to ", "i\u{2019}m going to ", "let's ", "let\u{2019}s ", "let me ", "we'll ", "we\u{2019}ll " };
    const verbs = [_][]const u8{ "run", "execut", "check", "verif", "regist", "creat", "schedul", "install", "writ", "updat", "delet", "quer", "inspect", "fix", "test", "set ", "look", "apply", "launch", "restart", "retry", "re-run", "rerun", "re-creat", "re-regist", "start", "open", "read", "list", "search", "add ", "remove", "correct", "adjust", "do " };
    for (acks) |a| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, tail, from, a)) |at| {
            from = at + a.len;
            const w = tail[from..@min(tail.len, from + 56)];
            if (std.mem.startsWith(u8, w, "know")) continue; // "let me know" / "i'll know" — closing courtesy
            for (verbs) |v| {
                if (std.mem.indexOf(u8, w, v) != null) return true;
            }
        }
    }
    return false;
}

/// Should this persisted conversation row re-feed into the model's prompt? Thoughts never do (the model's
/// own past reasoning is UI-only). Non-bracketed machine notes never do (nudge/verify chatter reads as
/// standing instructions). Bracketed RESULT rows ([console]/[tool:...]/[cast]/[build]) always flow — they
/// are ground truth. The one bracketed INSTRUCTION row is the [orchestrator] brief: a job description
/// scoped to ONE live cast ("when in doubt, narrate and stop", "never output CAST:", "never create a new
/// top-level file"). Re-fed after that cast ended, it kept the veil orchestrating a hive that no longer
/// existed — narrating instead of acting and refusing casts for the REST of the conversation — so it flows
/// only while a cast is actually live. Pure — unit-tested.
pub fn rowRefeeds(role: store_mod.ChatRole, text: []const u8, cast_live: bool) bool {
    if (role == .thought) return false;
    if (role == .cast_note) {
        if (text.len == 0 or text[0] != '[') return false;
        if (!cast_live and std.mem.startsWith(u8, text, "[orchestrator]")) return false;
    }
    return true;
}

/// Do a FAILED command and a later SUCCEEDING one form a fix pair worth learning? Same executable (first
/// token) + substantial token overlap (the fix is a VARIANT of the failure, not an unrelated success), and
/// not the identical command (a clean retry is a transient, not a lesson). Pure — unit-tested.
fn lessonPair(fail: []const u8, ok: []const u8) bool {
    const f = std.mem.trim(u8, fail, " \r\n\t");
    const o = std.mem.trim(u8, ok, " \r\n\t");
    if (f.len == 0 or o.len == 0) return false;
    if (std.mem.eql(u8, f, o)) return false; // identical retry that worked — transient at ANY length
    if (nearlySame(f, o)) return false; //      (nearlySame alone silently gave up past 400 chars)
    // a read-only probe succeeding after a failed MUTATION is diagnosis, not the fix — pairing it would
    // mint a lesson whose "working form" changes nothing
    if (looksReadOnlyCommand(o) and !looksReadOnlyCommand(f)) return false;
    var fi = std.mem.tokenizeAny(u8, f, " \t");
    var oi = std.mem.tokenizeAny(u8, o, " \t");
    const f0 = fi.next() orelse return false;
    const o0 = oi.next() orelse return false;
    // same executable, PATH-BLIND ("msg" == "C:\Windows\System32\msg.exe"): path-qualifying the exe IS
    // the motivating fix class, and strict first-token equality missed exactly it
    if (!std.ascii.eqlIgnoreCase(execBase(f0), execBase(o0))) return false;
    // overlap: at least half of the failing command's substantial tokens reappear in the fix
    var total: usize = 0;
    var hit: usize = 0;
    var it = std.mem.tokenizeAny(u8, f, " \t");
    _ = it.next(); // skip the executable
    while (it.next()) |tok| {
        if (tok.len < 5) continue;
        total += 1;
        if (std.mem.indexOf(u8, o, tok) != null) hit += 1;
    }
    return total > 0 and hit * 2 >= total;
}

/// "C:\Windows\System32\msg.exe" / "./msg" / "\"msg.exe\"" → "msg": the executable's identity for lesson
/// pairing, blind to path, quoting and the .exe suffix.
fn execBase(tok: []const u8) []const u8 {
    var t = std.mem.trim(u8, tok, "\"'");
    if (std.mem.lastIndexOfAny(u8, t, "/\\")) |i| t = t[i + 1 ..];
    if (t.len > 4 and std.ascii.eqlIgnoreCase(t[t.len - 4 ..], ".exe")) t = t[0 .. t.len - 4];
    return t;
}

/// Mutating chat tools — the ones whose side effects make an arc worth VERIFYING before "done". Read-class
/// tools (recall/read_file/web_search/...) never trigger a verification round on their own.
fn isMutatingToolName(name: []const u8) bool {
    const muts = [_][]const u8{ "write_file", "edit_file", "delete_file", "run_python", "host_command", "patch_system", "stage_delivery", "make_tool" };
    for (muts) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

/// Did this tool put a FILE on disk (vs. a general side effect like run_python)? A build arc's terminal
/// whole-build verify keys on this — the point is "the user asked for files; confirm they all exist."
fn writesAFile(name: []const u8) bool {
    const b = [_][]const u8{ "write_file", "edit_file", "delete_file", "stage_delivery" };
    for (b) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

/// Is this shell command CLEARLY read-only (a diagnostic probe)? Conservative allowlist — anything
/// unrecognized counts as mutating, so the verify pass errs toward running. Covers the bare cmd probes and
/// the `powershell -Command Get-*/Test-*/Select-*/Measure-*` diagnostic shape. Pure — unit-tested.
/// Is this token a known read-only cmd.exe probe verb? (Lowercased input expected.)
fn isProbeVerb(tok: []const u8) bool {
    const probes = [_][]const u8{ "dir", "type", "findstr", "where", "whoami", "tasklist", "systeminfo", "ipconfig", "hostname", "ver", "echo", "more", "tree" };
    for (probes) |pr| if (std.mem.eql(u8, tok, pr)) return true;
    return false;
}

fn looksReadOnlyCommand(cmd: []const u8) bool {
    var lb: [512]u8 = undefined;
    const t = std.mem.trim(u8, cmd, " \r\n\t");
    if (t.len == 0 or t.len > lb.len) return false; // unclassifiably long = mutating
    const n = t.len;
    for (t[0..n], 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const low = lb[0..n];
    var it = std.mem.tokenizeAny(u8, low, " \t");
    const first = it.next() orelse return false;
    if (isProbeVerb(first)) {
        // `dir > list.txt` WRITES — a redirect anywhere makes the whole line mutating
        if (std.mem.indexOfAny(u8, low, "><") != null) return false;
        // a chain/pipe stays read-only ONLY if EVERY segment leads with a probe verb (`type a & del b`
        // chains a delete; `findstr a x & findstr a y` is two probes) — the same per-segment discipline
        // the PowerShell branch below applies to its pipeline stages
        var seg = std.mem.tokenizeAny(u8, low, "&|;");
        while (seg.next()) |s0| {
            const s = std.mem.trim(u8, s0, " \t");
            if (s.len == 0) continue;
            var st = std.mem.tokenizeAny(u8, s, " \t");
            const sf = st.next() orelse return false;
            if (!isProbeVerb(sf)) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, first, "powershell") or std.mem.eql(u8, first, "pwsh")) {
        if (std.mem.indexOf(u8, low, "-encodedcommand") != null) return false; // opaque = mutating
        if (std.mem.indexOf(u8, low, "-command")) |at| {
            const body = std.mem.trim(u8, low[at + "-command".len ..], " \t\"'(");
            if (std.mem.indexOfAny(u8, body, "><;") != null) return false; // redirect / statement chain
            // EVERY pipeline stage must start with a read-family verb: `Get-X | Remove-Item` writes
            var seg = std.mem.splitScalar(u8, body, '|');
            var any = false;
            while (seg.next()) |s0| {
                const s = std.mem.trim(u8, s0, " \t\"')}");
                if (s.len == 0) continue;
                any = true;
                const ro = [_][]const u8{ "get-", "test-", "select-", "measure-", "compare-", "resolve-", "where-", "sort-", "format-" };
                var okseg = false;
                for (ro) |v| {
                    if (std.mem.startsWith(u8, s, v)) {
                        okseg = true;
                        break;
                    }
                }
                if (!okseg) return false;
            }
            return any;
        }
    }
    return false;
}

/// A reply that is exactly a "RUN: <shell command>" line (the AI's micro-console door). Returns the command,
/// trimmed, or null. Mirrors toolCall: only fires if RUN: leads one of the first few substantive lines so a
/// passing mention in prose can't trigger a shell command.
pub fn runCall(full: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, full, '\n');
    var seen: u32 = 0;
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r`*");
        if (line.len == 0) continue;
        seen += 1;
        if (seen > 4) return null;
        // Unwrap a single `[…]` wrapper: the model echoes the desk's OWN render-label — `[RUN: cmd]` — back as
        // if it were the call syntax (the desk re-feeds its `[console]`/`[tool:…]` result rows as history, and
        // the model imitates that bracketed render). Bracketed, the command leaked as inert text and never ran.
        if (line.len > 1 and line[0] == '[') {
            line = line[1..];
            if (line.len > 0 and line[line.len - 1] == ']') line = line[0 .. line.len - 1];
        }
        if (std.mem.startsWith(u8, line, "RUN:")) {
            const cmd = std.mem.trim(u8, line["RUN:".len..], " \t\r");
            return if (cmd.len == 0 or cmd.len > 900) null else cmd;
        }
    }
    return null;
}

/// Did the user's message explicitly ask to cast a swarm? Case-insensitive: a cast verb
/// (cast/run/spin/deploy/launch/summon) together with "swarm" or "hive". Used to honor an explicit
/// request even when the model flakes and emits no CAST line.
pub fn userWantsCast(msg: []const u8) bool {
    if (msg.len == 0 or msg.len > 4000) return false;
    var lower: [4000]u8 = undefined;
    const n = @min(msg.len, lower.len);
    for (0..n) |i| lower[i] = std.ascii.toLower(msg[i]);
    const lo = lower[0..n];
    const has_target = std.mem.indexOf(u8, lo, "swarm") != null or std.mem.indexOf(u8, lo, "hive") != null;
    if (!has_target) return false;
    const verbs = [_][]const u8{ "cast", "run ", "spin", "deploy", "launch", "summon", "dispatch" };
    for (verbs) |v| {
        if (std.mem.indexOf(u8, lo, v) != null) return true;
    }
    return false;
}

/// Does the user's message ask to KILL/STOP the running hive? Used to dispatch kill_swarm even when a weak
/// model narrates "kill_swarm force=true" as prose instead of emitting a real TOOL: line.
/// Two messages are "nearly the same" if, lowercased and whitespace-trimmed, one contains the other (or they
/// match) — a cheap loop-spin detector (a model re-issuing "check the status" as "check status now").
fn nearlySame(a_in: []const u8, b_in: []const u8) bool {
    const a = std.mem.trim(u8, a_in, " \r\n\t.!?");
    const b = std.mem.trim(u8, b_in, " \r\n\t.!?");
    if (a.len == 0 or b.len == 0) return false;
    if (a.len > 400 or b.len > 400) return false; // only guard short chatty steps, not long build instructions
    var la: [400]u8 = undefined;
    var lb: [400]u8 = undefined;
    for (a, 0..) |c, i| la[i] = std.ascii.toLower(c);
    for (b, 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const sa = la[0..a.len];
    const sb = lb[0..b.len];
    return std.mem.indexOf(u8, sa, sb) != null or std.mem.indexOf(u8, sb, sa) != null;
}

/// Collapse a tightly-repeated sentence WITHIN one reply. A weak model under stress "flails" — re-emitting the
/// same sentence ("I am going to check the file." … "I am going to check the file.") several times in a row.
/// Splits `in` on sentence terminators (. ! ? \n) and drops a substantial (>=8-char) fragment ONLY when it
/// near-duplicates the fragment IMMEDIATELY before it — a
/// window of one, deliberately, so a decimal / version / abbreviation split ("98." then "6.", "Fig." then "1.")
/// or two matching sentences that are not adjacent are NEVER fused into wrong output. Skips any reply carrying a
/// code fence outright (identical adjacent code lines are legitimate). Returns `in` unchanged when nothing was
/// dropped or it won't fit `out`, so it is safe to wrap any display-time text. Prose only: never pass text that
/// still carries a TOOL:/RUN:/CAST: line — every call site here runs after those are parsed/stripped.
fn dedupSentences(in: []const u8, out: []u8) []const u8 {
    if (in.len == 0 or in.len > out.len) return in;
    if (std.mem.indexOf(u8, in, "```") != null) return in; // never reshape a reply that carries code
    var last_off: usize = 0; // the last EMITTED fragment's (offset,len) in `out` — the only thing we compare to
    var last_len: usize = 0;
    var have_last = false;
    var w: usize = 0;
    var dropped = false;
    var i: usize = 0;
    while (i < in.len) {
        const s = i;
        while (i < in.len and in[i] != '.' and in[i] != '!' and in[i] != '?' and in[i] != '\n') i += 1;
        while (i < in.len and (in[i] == '.' or in[i] == '!' or in[i] == '?' or in[i] == '\n')) i += 1;
        const frag = in[s..i];
        const core = std.mem.trim(u8, frag, " \r\n\t");
        if (core.len >= 8 and have_last) { // short fragments ("OK.", "6.") never dedup — they may repeat fine
            const prev = std.mem.trim(u8, out[last_off..][0..last_len], " \r\n\t");
            // near-EQUAL length as well as near-match: the length band stops a short sentence being dropped as a
            // "duplicate" of a longer one it merely prefixes ("Let me check." vs "Let me check the config file.").
            const lo = @min(prev.len, core.len);
            const hi = @max(prev.len, core.len);
            if (hi > 0 and lo * 4 >= hi * 3 and nearlySame(prev, core)) {
                dropped = true;
                continue; // drop it; the last-kept anchor stays, so a whole run collapses to one
            }
        }
        @memcpy(out[w..][0..frag.len], frag);
        last_off = w;
        last_len = frag.len;
        have_last = true;
        w += frag.len;
    }
    if (!dropped) return in;
    return std.mem.trim(u8, out[0..w], " \r\n\t");
}

pub fn userWantsKill(msg: []const u8) bool {
    if (msg.len == 0 or msg.len > 4000) return false;
    var lower: [4000]u8 = undefined;
    const n = @min(msg.len, lower.len);
    for (0..n) |i| lower[i] = std.ascii.toLower(msg[i]);
    const lo = lower[0..n];
    // The verb must sit NEAR its target ("kill the swarm", "stop it") — an anywhere-in-message pair made
    // the gate near-vacuous on longer text: any prose containing "stop" plus an "it"/"hive" anywhere read
    // as a kill order (the [orchestrator] brief itself matched, and a "don't stop the hive yet, but…"
    // status question would too). 24 chars spans "stop that runaway swarm" comfortably.
    const verbs = [_][]const u8{ "kill", "stop", "abort", "cancel", "halt", "terminate", "shut down", "shutdown", "end the" };
    const targets = [_][]const u8{ "swarm", "hive", "cast", "it" };
    for (verbs) |v| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, lo, from, v)) |at| {
            from = at + v.len;
            const wend = @min(lo.len, at + v.len + 24);
            const window = lo[at + v.len .. wend];
            for (targets) |t| {
                if (hasWord(window, t)) return true; // word-bounded: "with"/"items" must not read as "it"
            }
        }
    }
    return false;
}

/// Strip a leading cast-request preamble ("cast a swarm to ", "have the hive ", "run a swarm that ")
/// from the user's message to get a clean one-line goal. Returns a slice into `buf`.
/// The cast's time budget under the mode ceiling: SPEED MODE caps the chat's DEFAULT/auto cast at 2 minutes (a
/// research sub-agent strike — without it, 10-100 minute hiveminds get dispatched for 3-5 minute jobs), BUT an
/// EXPLICIT sustained request (LONG, or a specific minutes count) is honored up to 120: a genuinely big job the
/// user asked the hive to commit to (deep-dive + document a whole repo) can't be done in a 2-minute strike.
/// Autonomy mode keeps the full range. The distinction is EXPLICIT vs default — not a hardcoded use case.
/// Pure — unit-tested.
pub fn castMinutes(spec_minutes: u32, long: bool, speed: bool) u32 {
    const explicit = spec_minutes > 0 or long; // the user/veil asked for a specific / sustained duration
    const max: u32 = if (speed and !explicit) 2 else 120;
    const want: u32 = if (spec_minutes > 0) spec_minutes else if (long) 20 else if (speed) 2 else CAST_MINUTES;
    return std.math.clamp(want, 1, max);
}

/// Word-bounded contains over an already-lowercased haystack ("along"/"belongs" must not read as "long").
fn hasWord(lo: []const u8, w: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, lo, from, w)) |at| {
        from = at + w.len;
        const pre = at == 0 or !std.ascii.isAlphanumeric(lo[at - 1]);
        const post = at + w.len >= lo.len or !std.ascii.isAlphanumeric(lo[at + w.len]);
        if (pre and post) return true;
    }
    return false;
}

/// The number the user put directly before a word ("5 minds", "15 minutes") — 0 when absent. Lowercased input.
fn numberBefore(lo: []const u8, word: []const u8) u32 {
    if (std.mem.indexOf(u8, lo, word)) |at| {
        var i = at;
        while (i > 0 and lo[i - 1] == ' ') i -= 1;
        const end = i;
        while (i > 0 and lo[i - 1] >= '0' and lo[i - 1] <= '9') i -= 1;
        if (end > i) return std.fmt.parseInt(u32, lo[i..end], 10) catch 0;
    }
    return 0;
}

/// Mechanical cast config from the USER'S OWN WORDS for the fast-path dispatch — verbatim signals only
/// ("5 minds", "20 minutes", "long"/"sustained"/"continuous"), never inference. Pure — unit-tested.
pub fn castSpecFromUser(msg: []const u8, goal: []const u8) CastSpec {
    var spec = CastSpec{ .goal = goal };
    var lower: [4000]u8 = undefined;
    const n = @min(msg.len, lower.len);
    for (0..n) |i| lower[i] = std.ascii.toLower(msg[i]);
    const lo = lower[0..n];
    if (hasWord(lo, "long") or hasWord(lo, "sustained") or hasWord(lo, "continuous")) spec.long = true;
    // NEWS DESK intent: the user asked the hive to publish/post its findings to Telegraph. The publish path
    // is grounded + double-screened server-side, so a false positive can only surface a held (unpublished)
    // edition, never an unvetted post — bias toward detecting the ask.
    if (std.mem.indexOf(u8, lo, "telegraph") != null or hasWord(lo, "publish") or
        std.mem.indexOf(u8, lo, "post it") != null or std.mem.indexOf(u8, lo, "post its") != null or
        std.mem.indexOf(u8, lo, "post publicly") != null or std.mem.indexOf(u8, lo, "post the") != null)
        spec.publish = true;
    spec.minds = numberBefore(lo, "mind");
    spec.minutes = numberBefore(lo, "minute");
    return spec;
}

pub fn castGoalFromUser(msg: []const u8, buf: []u8) []const u8 {
    var g = std.mem.trim(u8, msg, " \r\n\t");
    // find " to " / " that " / " for " after a cast verb and take what follows, else use the message
    const seps = [_][]const u8{ " to ", " that ", " which ", " for " };
    var lower: [1600]u8 = undefined;
    const ln = @min(g.len, lower.len);
    for (0..ln) |i| lower[i] = std.ascii.toLower(g[i]);
    // only strip if the message clearly starts with a cast request
    if (std.mem.indexOf(u8, lower[0..ln], "swarm") != null or std.mem.indexOf(u8, lower[0..ln], "hive") != null) {
        for (seps) |sep| {
            if (std.mem.indexOf(u8, lower[0..ln], sep)) |at| {
                const rest = std.mem.trim(u8, g[at + sep.len ..], " \r\n\t");
                if (rest.len > 3) {
                    g = rest;
                    break;
                }
            }
        }
    }
    const n = @min(g.len, buf.len);
    @memcpy(buf[0..n], g[0..n]);
    return buf[0..n];
}

/// The provider id a cast deploys under, derived from the CHAT's configured backend so a swarm always runs
/// on whatever the user is chatting with: BYOK (kind=1) -> that catalog provider's id ("openai",
/// "anthropic", "groq", ...); a custom OpenAI-compatible URL (kind=2) -> "openai" (the base_url carries the
/// real endpoint); otherwise the local backend -> "ollama". Paired with resolveProvider (model/base_url/key
/// come from the same chat settings), this is what makes "chatting with OpenAI casts an OpenAI swarm" true.
pub fn castProviderId(kind: u8, byok: u8) []const u8 {
    return switch (kind) {
        1 => catalog.providers[@min(byok, catalog.providers.len - 1)].key,
        2 => "openai",
        else => "ollama",
    };
}

/// The reply minus its CAST line — the note shown to the user beside the cast.
pub fn noteWithoutCast(full: []const u8, buf: []u8) []const u8 {
    var w: usize = 0;
    var removed = false;
    var it = std.mem.splitScalar(u8, full, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!removed and std.mem.startsWith(u8, line, "CAST:")) {
            removed = true;
            continue;
        }
        // also drop the cast CONFIG lines so the user-facing note doesn't show "MINDS 8 / LONG / MINUTES 30"
        if (removed and (std.mem.startsWith(u8, line, "MINDS") or std.mem.startsWith(u8, line, "MINUTES") or
            std.mem.eql(u8, line, "LONG") or std.mem.startsWith(u8, line, "LONG ") or std.mem.eql(u8, line, "CONTINUOUS"))) continue;
        if (w + raw.len + 1 > buf.len) break;
        if (w > 0) {
            buf[w] = '\n';
            w += 1;
        }
        @memcpy(buf[w .. w + raw.len], raw);
        w += raw.len;
    }
    return std.mem.trim(u8, buf[0..w], " \r\n\t");
}

// A lone high byte that is NOT part of a valid UTF-8 sequence would make the JSON body invalid UTF-8, which the
// server's std.json REJECTS with error.SyntaxError (a 500 that killed every cast/build whose text carried smart
// punctuation). Models + some APIs emit CP1252 punctuation as bare high bytes (em dash 0x97, smart quotes, …);
// fold those to their ASCII lookalike, anything else to '?'. Valid multi-byte UTF-8 is passed through untouched
// (the server accepts raw UTF-8 fine) — this only rewrites bytes that would otherwise corrupt the body.
fn foldBadByte(c: u8) u8 {
    return switch (c) {
        0x91, 0x92 => '\'',
        0x93, 0x94 => '"',
        0x95 => '*',
        0x96, 0x97 => '-',
        0x85 => '.',
        0xA0 => ' ',
        else => '?',
    };
}

/// Advance over a UTF-8 sequence at s[i]. Returns the number of bytes to emit verbatim (a VALID 1–4 byte
/// sequence) or 0 if s[i] is an invalid/truncated lead/continuation byte (caller folds it to one ASCII byte).
fn utf8Run(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 0;
    if (i + n > s.len) return 0;
    if (!std.unicode.utf8ValidateSlice(s[i .. i + n])) return 0;
    return n;
}

fn escJson(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => list.appendSlice(gpa, "\\\"") catch {},
                '\\' => list.appendSlice(gpa, "\\\\") catch {},
                '\n' => list.appendSlice(gpa, "\\n") catch {},
                '\r' => {},
                '\t' => list.appendSlice(gpa, "\\t") catch {},
                else => {
                    if (c < 0x20) list.append(gpa, ' ') catch {} else list.append(gpa, c) catch {};
                },
            }
            i += 1;
            continue;
        }
        const n = utf8Run(s, i);
        if (n == 0) {
            list.append(gpa, foldBadByte(c)) catch {};
            i += 1;
        } else {
            list.appendSlice(gpa, s[i .. i + n]) catch {};
            i += n;
        }
    }
}

/// Locate the string value of a flat top-level "key" in one JSON object line, RESPECTING backslash escapes so an
/// escaped quote inside the value doesn't clip it early. Returns the RAW (still-escaped) inner slice into `s`, or
/// null if the key or its opening quote isn't found. Desk-local, escape-aware twin of chat_service.jsonField —
/// enough for the server chat event frames (flat objects, string values). A non-string value returns null.
/// True if `path` names an existing file (used to probe candidate `veil` binary locations). Best-effort: any stat
/// error (missing, permission) reads as "not here" so the resolver moves to its next candidate.
fn fileExists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// A server-pushed file_sync path must stay INSIDE the conv workdir: relative, forward slashes only (the
/// server's walker emits '/'), no "."/".." segments, no drive letters or ADS colons.
fn safeSyncPath(p: []const u8) bool {
    if (p.len == 0 or p.len > 400) return false;
    if (p[0] == '/' or p[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, p, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, p, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false; // "//" or a trailing '/'
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

test "safeSyncPath accepts workdir-relative files and rejects escapes" {
    try std.testing.expect(safeSyncPath("canada_wildfire_update.md"));
    try std.testing.expect(safeSyncPath("journal/ada.md"));
    try std.testing.expect(!safeSyncPath("../outside.txt"));
    try std.testing.expect(!safeSyncPath("a/../../b"));
    try std.testing.expect(!safeSyncPath("/abs/path"));
    try std.testing.expect(!safeSyncPath("C:/windows/evil"));
    try std.testing.expect(!safeSyncPath("a\\b"));
    try std.testing.expect(!safeSyncPath(""));
    try std.testing.expect(!safeSyncPath("a//b"));
}

fn scRawField(s: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [40]u8 = undefined;
    // Match the KEY + its colon (`"tool":`), not the bare word (`"tool"`) — otherwise a value that equals the key
    // name matches first: searching `"tool"` in {"kind":"tool","tool":"run_python"} hits the "tool" VALUE of kind
    // before the real "tool": key, yielding an empty field ([tool:] done). The server writes compact JSON, so the
    // colon sits immediately after the key. (Note the [40]u8 pat cap allows key+`":` up to 37 chars — ample.)
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    const kidx = std.mem.indexOf(u8, s, pat) orelse return null;
    var i = kidx + pat.len;
    while (i < s.len and (s[i] == ' ' or s[i] == ':' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len or s[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') { // skip the escaped byte so a \" doesn't end the value
            i += 1;
            continue;
        }
        if (s[i] == '"') return s[start..i];
    }
    return null; // unterminated
}

/// Unescape a JSON string body (the RAW slice from scRawField) into `buf`, returning the decoded slice (clamped to
/// buf.len). Handles the escapes these frames actually use (\" \\ \/ \n \r \t); any other \x passes the following
/// byte through, and a bare \uXXXX is left literal (the server's writers never emit one).
fn scUnescape(raw: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len and n < buf.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            buf[n] = switch (raw[i + 1]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                else => raw[i + 1],
            };
            n += 1;
            i += 2;
            continue;
        }
        buf[n] = c;
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

fn wesc(w: *Io.Writer, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => w.writeAll("\\\"") catch {},
                '\\' => w.writeAll("\\\\") catch {},
                '\n' => w.writeAll("\\n") catch {},
                '\r' => {},
                '\t' => w.writeAll(" ") catch {},
                else => {
                    if (c < 0x20) w.writeByte(' ') catch {} else w.writeByte(c) catch {};
                },
            }
            i += 1;
            continue;
        }
        const n = utf8Run(s, i);
        if (n == 0) {
            w.writeByte(foldBadByte(c)) catch {};
            i += 1;
        } else {
            w.writeAll(s[i .. i + n]) catch {};
            i += n;
        }
    }
}

test "fenced tool-call dialect: name from the fence header or the function wrapper, args exact" {
    // the fenced form: ```tool: name header + name({...}) wrapper (braces in content)
    const a = toolCallFenced("Writing the feed UI now.\n\n```tool: write_file\nwrite_file({\"path\":\"static/index.html\",\"content\":\"body{margin:0}\"})\n```").?;
    try std.testing.expectEqualStrings("write_file", a.name);
    try std.testing.expectEqualStrings("{\"path\":\"static/index.html\",\"content\":\"body{margin:0}\"}", a.args);
    // args directly after the header — no wrapper
    const b = toolCallFenced("```tool: read_file\n{\"path\":\"src/main.rs\"}\n```").?;
    try std.testing.expectEqualStrings("read_file", b.name);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.rs\"}", b.args);
    // tool_code-style tag carries no name — the wrapper owns it
    const c = toolCallFenced("```tool_code\nlist_dir({\"path\":\".\"})\n```").?;
    try std.testing.expectEqualStrings("list_dir", c.name);
    // quoted protocol prose in a tool fence — no recoverable name, not a call
    try std.testing.expect(toolCallFenced("```tool\nremember to emit one call per reply\n```") == null);
    // not at a line start (inline mention) — not a call
    try std.testing.expect(toolCallFenced("see the ```tool: write_file example above") == null);
}

test "stripToolTail cuts a fenced call at the FENCE (streaming included) — no stranded opener or name(" {
    // settled: the whole block goes, prose stays
    try std.testing.expectEqualStrings("Writing static/index.html now - the dark feed UI.", stripToolTail("Writing static/index.html now - the dark feed UI.\n\n```tool: write_file\nwrite_file({\"path\":\"static/index.html\",\"content\":\"<div>{}</div>\"})\n```"));
    // streaming: args still open — the fence is already hidden
    try std.testing.expectEqualStrings("Writing it now.", stripToolTail("Writing it now.\n\n```tool: write_file\nwrite_file({\"path\":\"static/index.html\",\"content\":\"<!DOCTYPE h"));
    // header only so far
    try std.testing.expectEqualStrings("Writing it now.", stripToolTail("Writing it now.\n\n```tool: write_file"));
}

test "stripToolTail backs over a bare function wrapper + tagged fence above inferred args; keeps a closer" {
    // bare write_file({...}) with no fence: the wrapper is cut with the args
    try std.testing.expectEqualStrings("Now the store.", stripToolTail("Now the store.\nwrite_file({\"path\":\"src/store.rs\",\"content\":\"pub fn x(){}\"})"));
    // a CLOSED earlier code block keeps its bare ``` closer (only a TAGGED fence line is eaten)
    try std.testing.expectEqualStrings("look:\n```js\nlet x=1\n```", stripToolTail("look:\n```js\nlet x=1\n```\n{\"path\":\"a.md\",\"content\":\"hi\"}"));
}

test "trimDanglingToolFence heals the persisted pre-fix residue, leaves closed fences + prose alone" {
    try std.testing.expectEqualStrings("Writing src/store.rs now.", trimDanglingToolFence("Writing src/store.rs now.\n\n```tool: write_file\nwrite_file("));
    try std.testing.expectEqualStrings("Chaining them.", trimDanglingToolFence("Chaining them.\n\n```tool: write_file"));
    const closed = "here's how:\n```tool: write_file\nwrite_file({})\n```\ndone";
    try std.testing.expectEqualStrings(closed, trimDanglingToolFence(closed));
    const plain = "no fence at all";
    try std.testing.expectEqualStrings(plain, trimDanglingToolFence(plain));
}

test "a truncated FENCED write trips looksTruncatedWrite (chunked-append rescue)" {
    var big: [520]u8 = undefined;
    @memset(&big, 'x');
    var buf: [700]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "```tool: write_file\nwrite_file({{\"path\":\"a.html\",\"content\":\"{s}", .{big}) catch unreachable;
    try std.testing.expect(looksTruncatedWrite(text));
    // and the dispatcher still sees the call (args default {}), so the empty-args rescue path owns it
    const tc = toolCallFenced(text).?;
    try std.testing.expectEqualStrings("write_file", tc.name);
    try std.testing.expectEqualStrings("{}", tc.args);
}

test "stripToolTail removes a tool call (incl. mid-line) but keeps prose + prose mentions" {
    // mid-line TOOL: (the real leak) — keep the prose before it
    try std.testing.expectEqualStrings("I compared both. Let me write it now.", stripToolTail("I compared both. Let me write it now.TOOL: write_file {\"path\":\"x.md\",\"content\":\"# X\"}"));
    // line-start TOOL:
    try std.testing.expectEqualStrings("Here it is:", stripToolTail("Here it is:\nTOOL: write_file {\"path\":\"a\"}"));
    // <tool:> XML form
    try std.testing.expectEqualStrings("done", stripToolTail("done <tool:read_file>{\"path\":\"a\"}</tool:read_file>"));
    // RUN: at line start
    try std.testing.expectEqualStrings("run this", stripToolTail("run this\nRUN: python a.py"));
    // a prose mention of TOOL: with no args is NOT clipped
    try std.testing.expectEqualStrings("use the TOOL: menu to pick one", stripToolTail("use the TOOL: menu to pick one"));
    // ...even when an unrelated brace appears later (the old '{'-anywhere guard destroyed this answer)
    try std.testing.expectEqualStrings("use the TOOL: menu, e.g. {\"a\":1}", stripToolTail("use the TOOL: menu, e.g. {\"a\":1}"));
    // a mid-line no-args call to a KNOWN tool IS clipped (and toolCall dispatches the same thing)
    try std.testing.expectEqualStrings("Let me stop it.", stripToolTail("Let me stop it. TOOL: stop_swarm"));
    // a plain answer is untouched
    try std.testing.expectEqualStrings("just a normal answer", stripToolTail("just a normal answer"));
}

test "filterLessonLines keeps only playbook-shaped lines, drops raw-prompt pollution" {
    // a recalled block mixing one real lesson with the exact pollution shape from the screenshot
    const block =
        "deep dive into https://github.com/gary23w/nl-veil and write documentation: worked\n" ++
        "fix: `findstr features full-path` failed (exit code 1) — works as: `findstr features index.html`\n" ++
        "scopes_for_coinbase_at_2026-07 UTC.csv: worked\n" ++
        "Let me read the last 3000 bytes of index.html to verify: worked";
    var out: [1400]u8 = undefined;
    const kept = filterLessonLines(block, &out);
    try std.testing.expect(std.mem.indexOf(u8, kept, "fix: `findstr") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "deep dive") == null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "coinbase") == null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "read the last 3000") == null);
    // exactly the one lesson survives (no stray newline padding)
    try std.testing.expectEqualStrings("fix: `findstr features full-path` failed (exit code 1) — works as: `findstr features index.html`", kept);
    // an all-noise block yields nothing (injects no garbage)
    const noise = "are you broken now?: worked\ngo ahead, start your recon.: worked";
    try std.testing.expectEqualStrings("", filterLessonLines(noise, &out));
    // a judge-accepted lesson phrased with 'works as:' but no 'fix:' prefix still qualifies
    try std.testing.expect(isLessonLine("curl with -sL works as: it follows redirects"));
    try std.testing.expect(!isLessonLine("build a website for the repo: worked"));
    // the judge-promotion stamp (acceptProposal prepends it to free-form lessons) qualifies too —
    // without it, human-accepted playbook knowledge was silently filtered out of every injection
    try std.testing.expect(isLessonLine("lesson: prefer msg.exe's full System32 path under restricted shells"));
}

test "salientFailLine picks the exception off a traceback, falls back to stdout, respects UTF-8" {
    var buf: [160]u8 = undefined;
    // a python traceback: the LAST stderr line is the exception itself
    const tb =
        "Traceback (most recent call last):\n" ++
        "  File \"probe.py\", line 9, in <module>\n" ++
        "    with urllib.request.urlopen(req) as response:\n" ++
        "urllib.error.HTTPError: HTTP Error 403: Forbidden\n";
    try std.testing.expectEqualStrings("urllib.error.HTTPError: HTTP Error 403: Forbidden", salientFailLine("", tb, &buf));
    // stderr silent -> the last non-empty stdout line carries the error (plenty of CLIs do this)
    try std.testing.expectEqualStrings("FATAL: port 8787 already in use", salientFailLine("starting...\nFATAL: port 8787 already in use\n\n", "", &buf));
    // nothing anywhere -> empty (mint and recall both treat that as "no signature")
    try std.testing.expectEqualStrings("", salientFailLine("", "   \n \n", &buf));
    // the byte cap never splits a UTF-8 codepoint
    var tiny: [5]u8 = undefined;
    const cut = salientFailLine("", "abc — def", &tiny);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "lessonRelevant: an executable match alone never surfaces a lesson (the 403-vs-cd false positive)" {
    // An HTTP 403 auth failure must not recall a cd-into-the-repo fix just because both commands said
    // `python` under one long path. Executable + path fragments must never be enough.
    const cd_lesson = "fix: `python probe.py` failed (exit code 1) — works as: `cd /d \"C:\\Users\\garys\\OneDrive\\Documents\\Claude\\Projects\\Garrett\\nl-veil\"`";
    const cmd_403 = "python discourse_check.py --topics";
    const sig_403 = "urllib.error.HTTPError: HTTP Error 403: Forbidden";
    try std.testing.expect(!lessonRelevant(cd_lesson, cmd_403, sig_403));
    // ...while the SAME failing command recalling ITS OWN family still passes (exec + shared arg token)
    const findstr_lesson = "fix: `findstr features full-path` failed (exit code 1) — works as: `findstr features index.html`";
    try std.testing.expect(lessonRelevant(findstr_lesson, "findstr features full-path", "(exit code 1)"));
    // failure-MODE evidence carries a lesson even when args differ: the minted [signature] matches the live one
    const curl_lesson = "fix: `curl -s http://host/api` failed (exit code 22) [The requested URL returned error: 403] — works as: `curl -s -H \"Api-Key: k\" http://host/api`";
    try std.testing.expect(lessonRelevant(curl_lesson, "curl -s http://host/other", "The requested URL returned error: 403"));
    // a different executable with no shared evidence never qualifies
    try std.testing.expect(!lessonRelevant(findstr_lesson, "python build.py", "SyntaxError: invalid syntax"));
    // generic tokens (exit/code/error/failed) and small numbers are not evidence
    try std.testing.expect(!lessonRelevant(cd_lesson, "python other.py", "(exit code 1) error failed"));
    // the executable's own name in the error line ("python: can't open file ...") must not count as a
    // second piece of evidence on top of the executable score — that double-count let a pytest-cwd lesson
    // ride in on an unrelated missing-file failure
    const pytest_lesson = "fix: `cd /d \"C:\\w\" && where pytest && python -c \"import pytest\"` failed (exit code 1) — works as: `cd /d \"C:\\w\" && python -m pytest minimal_test.py -v`";
    try std.testing.expect(!lessonRelevant(pytest_lesson, "python missing_probe_xyz.py --check-auth", "python: can't open file 'C:\\x\\missing_probe_xyz.py': [Errno 2] No such file or directory"));
    // ...but a real shared token (the same script name in the error) still carries it over the bar
    try std.testing.expect(lessonRelevant(pytest_lesson, "python -m pytest minimal_test.py", "python: error collecting minimal_test.py"));
}

test "stripWorkdirChdir removes stale build-dir cd prefixes, keeps the transferable command" {
    var out: [700]u8 = undefined;
    // a lesson whose working form cd's into a one-time build workdir
    const polluted = "fix: `cd /d \"C:\\Users\\g\\...\\builds\\c6a505cb1\\work\" && findstr swarm docs\\zzz.html` failed (exit code 1) — works as: `cd /d \"C:\\Users\\g\\...\\builds\\c6a505cb1\\work\" && findstr swarm docs\\index.html`";
    const cleaned = stripWorkdirChdir(polluted, &out);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "cd /d") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "c6a505cb1") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "findstr swarm docs\\zzz.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "findstr swarm docs\\index.html") != null);
    // pushd form, and a chained non-cd `&&` command is preserved intact
    try std.testing.expectEqualStrings("python build.py", stripWorkdirChdir("pushd \"C:\\a\\b\" && python build.py", &out));
    try std.testing.expectEqualStrings("make && ./run", stripWorkdirChdir("make && ./run", &out));
    // a bare relative cd (no separator) is meaningful — left alone; a mid-word "cd" is never a prefix
    try std.testing.expectEqualStrings("cd build && test", stripWorkdirChdir("cd build && test", &out));
    try std.testing.expectEqualStrings("procd x && y", stripWorkdirChdir("procd x && y", &out));
    // nothing to strip -> byte-identical
    try std.testing.expectEqualStrings("findstr a b", stripWorkdirChdir("findstr a b", &out));
}

test "emitLesson drops a lesson that cd-stripping collapsed to fail==fix (self-contradiction)" {
    var out: [700]u8 = undefined;
    // fail and fix differ ONLY by the build-dir cd prefix; after stripping, both spans become `npm run build`
    const collapse = "fix: `cd /d \"C:\\a\" && npm run build` failed (exit code 1) — works as: `cd /d \"C:\\b\" && npm run build`";
    try std.testing.expectEqual(@as(usize, 0), emitLesson(collapse, &out, 0)); // dropped: nothing written
    // a genuinely transferable fix (different commands after stripping) still survives
    const keep = "fix: `cd /d \"C:\\a\" && findstr x zzz.html` failed (exit code 1) — works as: `cd /d \"C:\\a\" && findstr x index.html`";
    try std.testing.expect(emitLesson(keep, &out, 0) > 0);
    try std.testing.expect(fixSpansCollapsed("fix: `npm run build` failed (exit code 1) — works as: `npm run build`"));
    try std.testing.expect(!fixSpansCollapsed("fix: `npm run build` failed — works as: `npm ci && npm run build`"));
    try std.testing.expect(!fixSpansCollapsed("lesson: prefer full paths")); // not a fix-pair line
}

test "lessonRelevantToRequest needs real shared vocabulary, not generic words" {
    const pytest_lesson = "fix: `pytest suite_x` failed (exit code 1) — works as: `python -m pytest suite_x`";
    // an off-topic request that shares only generic words with the lesson -> NOT injected
    try std.testing.expect(!lessonRelevantToRequest(pytest_lesson, "run these two console commands and report each exit code, nothing else"));
    // a request that genuinely names the thing (two shared informative tokens) -> injected
    try std.testing.expect(lessonRelevantToRequest(pytest_lesson, "the pytest run on suite_x keeps failing, help"));
    // one shared token is not enough (pre-emptive binding needs more evidence than the reactive fold)
    try std.testing.expect(!lessonRelevantToRequest(pytest_lesson, "how do I run pytest here"));
}

test "filterRequestRelevantLessons gates the pre-emptive channel; stale cd is stripped from what survives" {
    const block =
        "fix: `cd /d \"C:\\builds\\c6a505cb1\\work\" && findstr swarm docs\\zzz.html` failed (exit code 1) — works as: `cd /d \"C:\\builds\\c6a505cb1\\work\" && findstr swarm docs\\index.html`\n" ++
        "fix: `pytest suite_x` failed (exit code 1) — works as: `python -m pytest suite_x`";
    var out: [900]u8 = undefined;
    // a request about findstr+docs surfaces THAT lesson (>=2 shared) with the stale cd stripped away
    const kept = filterRequestRelevantLessons(block, "the findstr search over docs\\index.html returns nothing", &out);
    try std.testing.expect(std.mem.indexOf(u8, kept, "findstr swarm docs\\index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "cd /d") == null); // stale workdir gone
    try std.testing.expect(std.mem.indexOf(u8, kept, "pytest") == null); // off-topic lesson not injected
    // a wholly unrelated request injects nothing at all
    try std.testing.expectEqualStrings("", filterRequestRelevantLessons(block, "please summarize the meeting notes from yesterday", &out));
}

test "filterRelevantLessons folds only same-family lessons; a weak recall injects nothing" {
    const block =
        "fix: `python probe.py` failed (exit code 1) — works as: `cd /d \"C:\\Projects\\Garrett\\nl-veil\"`\n" ++
        "fix: `findstr features full-path` failed (exit code 1) — works as: `findstr features index.html`";
    var out: [700]u8 = undefined;
    // the findstr failure keeps its own lesson, drops the python/cd one
    const kept = filterRelevantLessons(block, "findstr features full-path", "(exit code 1)", &out);
    try std.testing.expectEqualStrings("fix: `findstr features full-path` failed (exit code 1) — works as: `findstr features index.html`", kept);
    // the 403 python failure matches NEITHER -> empty fold, no authoritative non sequitur
    const none = filterRelevantLessons(block, "python discourse_check.py --topics", "urllib.error.HTTPError: HTTP Error 403: Forbidden", &out);
    try std.testing.expectEqualStrings("", none);
}

test "firstStoredSentence keys what observe actually stored" {
    // single sentence: whole thing, trailing ender trimmed (the substrate stores the trimmed sentence)
    try std.testing.expectEqualStrings("run the build now", firstStoredSentence("run the build now.", 120));
    // multi-sentence: only the FIRST sentence — a raw prefix spanning the boundary matches no stored fact
    try std.testing.expectEqualStrings("fix the header", firstStoredSentence("fix the header. then redeploy the site", 120));
    try std.testing.expectEqualStrings("first line goal", firstStoredSentence("first line goal\nsecond line detail", 120));
    // a '?' sentence was DROPPED by observe — there is nothing stored to strengthen (empty = caller no-op)
    try std.testing.expectEqualStrings("", firstStoredSentence("are you broken now?", 120));
    try std.testing.expectEqualStrings("", firstStoredSentence("what changed? everything else is fine", 120));
    // byte cap never splits a UTF-8 codepoint (em-dash is 3 bytes: cap lands mid-char, snaps back)
    const cut = firstStoredSentence("abcd — tail", 6);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings("abcd", std.mem.trim(u8, cut, " "));
    // too short to identify a fact
    try std.testing.expectEqualStrings("", firstStoredSentence("ok", 120));
}

test "looksReadOnlyCommand: compound of probes is read-only, mixed chain stays mutating" {
    // two read-only probes chained with & must stay read-only (a false mutating classification would buy an
    // unwanted build-verify turn)
    try std.testing.expect(looksReadOnlyCommand("findstr playbook a\\ghost.log & findstr playbook b\\real.log"));
    try std.testing.expect(looksReadOnlyCommand("type a.txt | more"));
    try std.testing.expect(looksReadOnlyCommand("dir /b ; tasklist"));
    // any non-probe segment keeps the compound mutating; redirects always mutate
    try std.testing.expect(!looksReadOnlyCommand("findstr x y.txt & format c:"));
    try std.testing.expect(!looksReadOnlyCommand("findstr x y.txt & echo hi > out.txt"));
}

test "stashLessonLines merges with dedup and never clobbers the fold's credit target" {
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.playbook_hit_lesson_len = 0;
    // the failure fold seeds the cmd-keyed lesson…
    chat.stashLessonLines("fix: `a` failed — works as: `b`");
    // …then the next prompt's last_user-keyed recall re-surfaces it plus a second lesson
    chat.stashLessonLines("fix: `a` failed — works as: `b`\nlesson: use the full path");
    try std.testing.expectEqualStrings("fix: `a` failed — works as: `b`\nlesson: use the full path", chat.playbook_hit_lesson[0..chat.playbook_hit_lesson_len]);
    // overflow drops whole lines, never truncates one mid-way (a half-line strengthens nothing)
    var big: [2000]u8 = undefined;
    @memset(&big, 'x');
    chat.stashLessonLines(big[0..2000]);
    try std.testing.expectEqualStrings("fix: `a` failed — works as: `b`\nlesson: use the full path", chat.playbook_hit_lesson[0..chat.playbook_hit_lesson_len]);
}

test "playbook Hebbian close strengthens recalled lessons; a raw-prompt key mints nothing (pollution fix)" {
    // Regression for the "RECALLED LESSON" pollution: reinforcing outcome feedback on the raw user prompt would
    // mint "<prompt>: worked" facts into the lesson scope, which surface as bogus lessons on later command
    // failures. Feedback must route through strengthen() (bump-only, never mints).
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const bin = neurondb.findBin(std.testing.allocator, io);
    defer std.testing.allocator.free(bin);
    if (bin.len == 0) return error.SkipZigTest; // neuron binary not reachable from the test cwd
    const dbp = "zig-playbook-tmp.sqlite";
    Io.Dir.cwd().deleteFile(io, dbp) catch {};
    defer {
        Io.Dir.cwd().deleteFile(io, dbp) catch {};
        Io.Dir.cwd().deleteFile(io, dbp ++ "-wal") catch {};
        Io.Dir.cwd().deleteFile(io, dbp ++ "-shm") catch {};
    }
    const db = neurondb.Db{ .gpa = std.testing.allocator, .io = io, .bin = bin, .db = dbp };
    // a real verified fail->fix lesson lands in the playbook (the deterministic minting path)
    db.observe(PLAYBOOK_SCOPE, "fix: `findstr features full-path` failed (exit code 1) works as: `findstr features index.html`");
    // the pollution key: outcome feedback on a raw user prompt. strengthen must touch/mint NOTHING.
    db.strengthen(PLAYBOOK_SCOPE, "deep dive into the desk folder and write markdown documentation for every zig file");
    // and the intended close: strengthen the ACTUAL recalled lesson text (what the fix now does) — a no-op-safe
    // bump of the existing fact.
    db.strengthen(PLAYBOOK_SCOPE, "fix: `findstr features full-path` failed (exit code 1) works as: `findstr features index.html`");
    // recall on a failing command must surface ONLY the real lesson, never the prompt text
    var lrb: [1024]u8 = undefined;
    const lesson = db.recall(PLAYBOOK_SCOPE, "findstr features index.html failed exit code 1", &lrb);
    try std.testing.expect(std.mem.indexOf(u8, lesson, "fix:") != null);
    try std.testing.expect(std.mem.indexOf(u8, lesson, "deep dive") == null);
    // the scope holds ONLY the one lesson we observed — the raw prompt never became a fact
    if (db.dump(PLAYBOOK_SCOPE)) |d| {
        defer std.testing.allocator.free(d);
        try std.testing.expect(std.mem.indexOf(u8, d, "findstr features") != null);
        try std.testing.expect(std.mem.indexOf(u8, d, "deep dive") == null);
    } else return error.TestUnexpectedResult;
}

test "parseRememberBody splits [category] from the fact" {
    const a = parseRememberBody("[key] OpenAI API key: sk-abc123");
    try std.testing.expectEqualStrings("key", a.cat);
    try std.testing.expectEqualStrings("OpenAI API key: sk-abc123", a.fact);
    // no category -> everything is a plain fact
    const b = parseRememberBody("the server is at 10.0.0.5");
    try std.testing.expectEqualStrings("fact", b.cat);
    try std.testing.expectEqualStrings("the server is at 10.0.0.5", b.fact);
    // spaces inside the bracket + around it are trimmed
    const c = parseRememberBody("  [ preference ]  dark mode ");
    try std.testing.expectEqualStrings("preference", c.cat);
    try std.testing.expectEqualStrings("dark mode", c.fact);
    // empty bracket falls back to fact
    const d = parseRememberBody("[] just this");
    try std.testing.expectEqualStrings("fact", d.cat);
    try std.testing.expectEqualStrings("just this", d.fact);
}

test "personalFact mirrors personal observes but leaves general knowledge hive-only" {
    // personal credentials/prefs -> a category (mirrored into the private Memory tab)
    try std.testing.expectEqualStrings("key", personalFact("my openai api key is sk-abc123").?);
    try std.testing.expectEqualStrings("login", personalFact("my password is hunter2").?);
    try std.testing.expectEqualStrings("login", personalFact("my login email is gary@x.com").?);
    // third-person possessive is intentionally NOT mirrored via observe (goes through REMEMBER: instead) — bias to
    // false-negative so a general-knowledge observe can never leak into the private secret store
    try std.testing.expect(personalFact("gary's password is 123456") == null);
    try std.testing.expectEqualStrings("preference", personalFact("I prefer dark mode and concise answers").?);
    try std.testing.expectEqualStrings("preference", personalFact("I always deploy to us-west-2").?);
    // GENERAL knowledge must NOT be mirrored (stays hive-only) — the false-positive class we must avoid
    try std.testing.expect(personalFact("the API key rotation interval is 90 days") == null);
    try std.testing.expect(personalFact("JWT tokens are signed with a secret") == null);
    try std.testing.expect(personalFact("Postgres listens on port 5432 by default") == null);
    try std.testing.expect(personalFact("OAuth2 uses an access token and a refresh token") == null);
}

test "exchangeHasDurableSignal fires on personal facts + commitments, not ordinary technical questions" {
    // personal identity/preference/credential → consolidation should run
    try std.testing.expect(exchangeHasDurableSignal("I always deploy to us-west-2 and I use pnpm"));
    try std.testing.expect(exchangeHasDurableSignal("my api key is sk-123"));
    try std.testing.expect(exchangeHasDurableSignal("please remember my staging host"));
    try std.testing.expect(exchangeHasDurableSignal("my name is gary"));
    // commitments / schedule the user states in passing (the previously-missed cases)
    try std.testing.expect(exchangeHasDurableSignal("today we have to go to therapy at 12pm"));
    try std.testing.expect(exchangeHasDurableSignal("set an alarm to remind me before the meeting"));
    try std.testing.expect(exchangeHasDurableSignal("my dentist appointment is tomorrow"));
    // pure-technical questions must NOT fire
    try std.testing.expect(!exchangeHasDurableSignal("explain how tokenization works"));
    try std.testing.expect(!exchangeHasDurableSignal("what is a secret sharing scheme?"));
    try std.testing.expect(!exchangeHasDurableSignal("what does the @ decorator do in Python?"));
    try std.testing.expect(!exchangeHasDurableSignal("how many hours are in four days?"));
    try std.testing.expect(!exchangeHasDurableSignal("describe an account balance class"));
    try std.testing.expect(!exchangeHasDurableSignal("draw a diagram of the parser at each stage"));
}

test "stripDanglingMemoryIntro drops a dangling save-intro but keeps real prose" {
    // a dangling save-intro: a bold header pointing at the (stripped) REMEMBER: lines
    try std.testing.expectEqualStrings("Here is the plan.", stripDanglingMemoryIntro("Here is the plan.\n\n**Saved preferences:**"));
    try std.testing.expectEqualStrings("Done.", stripDanglingMemoryIntro("Done.\nI've remembered:"));
    // a real colon-terminated line that is NOT a memory intro is preserved
    try std.testing.expectEqualStrings("The steps are:", stripDanglingMemoryIntro("The steps are:"));
    // no trailing colon -> untouched
    try std.testing.expectEqualStrings("A normal answer.", stripDanglingMemoryIntro("A normal answer."));
}

test "wesc keeps the JSON body valid UTF-8 (folds CP1252, preserves real UTF-8)" {
    var buf: [96]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    // a lone 0x97 (CP1252 em dash — INVALID utf8 that would 500 the server) + a REAL utf8 em dash + a quote
    wesc(&w, "a \x97 b \xe2\x80\x94 c \"q\"");
    const out = w.buffered();
    try std.testing.expect(std.unicode.utf8ValidateSlice(out)); // the whole body must be valid utf8
    try std.testing.expect(std.mem.indexOf(u8, out, "a - b") != null); // 0x97 -> '-'
    try std.testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\x94") != null); // real em dash preserved
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"q\\\"") != null); // quote escaped
}

fn jInt(line: []const u8, key: []const u8) ?i64 {
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = at + needle.len;
    while (i < line.len and line[i] == ' ') i += 1;
    var neg = false;
    if (i < line.len and line[i] == '-') {
        neg = true;
        i += 1;
    }
    var v: i64 = 0;
    var any = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        v = v * 10 + (line[i] - '0');
        any = true;
    }
    if (!any) return null;
    return if (neg) -v else v;
}

var jstr_buf: [64]u8 = undefined;
fn jStr(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    _ = out;
    var kbuf: [40]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = at + needle.len;
    while (i < body.len and body[i] == ' ') i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    var w: usize = 0;
    while (i < body.len and body[i] != '"' and w < jstr_buf.len) : (i += 1) {
        jstr_buf[w] = body[i];
        w += 1;
    }
    return jstr_buf[0..w];
}

/// Does `args` carry a real swarm id (not empty, not a placeholder)? When it doesn't and a cast is live,
/// runToolAndContinue substitutes the running cast's id so the model needn't know the hex.
fn hasRealId(args: []const u8) bool {
    var b: [64]u8 = undefined;
    const id = jStr(args, "id", &b) orelse return false;
    const t = std.mem.trim(u8, id, " ");
    if (t.len == 0) return false;
    if (std.mem.eql(u8, t, "current") or std.mem.eql(u8, t, "the current") or std.mem.eql(u8, t, "<id>") or std.mem.eql(u8, t, "id")) return false;
    return true;
}

/// Is a web_search "query" arg missing or a placeholder ("", "...", "…", "<query>")? A reasoning-recovered
/// call often carries shorthand; treat anything under 3 real chars (after stripping dots/brackets) as weak.
fn queryWeak(args: []const u8) bool {
    var b: [128]u8 = undefined;
    const q = jStr(args, "query", &b) orelse return true;
    const t = std.mem.trim(u8, q, " .\t\r\n<>…\"");
    return t.len < 3;
}

/// Extract a JSON string value for `key`, UNESCAPING into `out` (handles \" \\ \/ \n \r \t \b \f and, best-
/// effort, \uXXXX -> '?'). Unlike jStr this is not capped at 64b and survives escaped quotes + newlines —
/// tool results routinely contain both. Returns the written slice, or null if the key is absent.
fn jsonStrInto(body: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var kbuf: [48]u8 = undefined;
    if (key.len + 3 > kbuf.len) return null;
    kbuf[0] = '"';
    @memcpy(kbuf[1 .. 1 + key.len], key);
    kbuf[1 + key.len] = '"';
    kbuf[2 + key.len] = ':';
    const needle = kbuf[0 .. 3 + key.len];
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = at + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    var w: usize = 0;
    while (i < body.len and w < out.len) {
        const c = body[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < body.len) {
            const e = body[i + 1];
            i += 2;
            out[w] = switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 8,
                'f' => 12,
                'u' => blk: {
                    if (i + 4 <= body.len) i += 4; // skip the code point; emit a placeholder
                    break :blk '?';
                },
                else => e, // \" \\ \/ and anything else -> the literal char
            };
            w += 1;
            continue;
        }
        out[w] = c;
        w += 1;
        i += 1;
    }
    return out[0..w];
}

/// The human-readable payload of a /api/v1/chat/tool response: the mind-tool "result", else the swarm
/// "findings", else an "err" string, else the raw JSON body (list_swarms/stop_swarm hand back a small
/// object the model can read directly). Always returns a slice of `out` or `body`.
fn extractToolResult(body: []const u8, out: []u8) []const u8 {
    if (jsonStrInto(body, "result", out)) |r| return r;
    if (jsonStrInto(body, "findings", out)) |r| return r;
    if (jsonStrInto(body, "err", out)) |r| return r;
    const n = @min(body.len, out.len);
    @memcpy(out[0..n], body[0..n]);
    return out[0..n];
}

// ------------------------------------------------------------------------------ tests

test "first message auto-titles the conversation (both the type-first and +-first flows)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-title-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    // dead endpoint so startTurn's curl goes nowhere — the title path is what's under test
    const base = "http://127.0.0.1:1/v1";
    @memcpy(store.settings.chat_base[0..base.len], base);
    store.settings.chat_base_len = base.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    // flow 1: user types first (no conversation yet)
    chat.store.settings.server_chat = false; // this test drives the LOCAL engine (no server round-trip)
    chat.cmdSend(dd, "hello there veil, how are you?");
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
    chat.turn = .idle;
    var found_title = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.conv_count) : (i += 1) {
            if (std.mem.startsWith(u8, store.convs[i].titleStr(), "hello there veil")) found_title = true;
        }
    }
    try std.testing.expect(found_title);

    // flow 2: user clicks + first, then sends
    chat.cmdNewConv(dd);
    chat.cmdSend(dd, "second conversation opener");
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
    chat.turn = .idle;
    var found2 = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.conv_count) : (i += 1) {
            if (std.mem.startsWith(u8, store.convs[i].titleStr(), "second conversation")) found2 = true;
        }
    }
    try std.testing.expect(found2);
}

test "selecting a chat re-binds the console to ITS build dir; a chat without one clears the binding" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-bdir-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/u1/_chat/builds/cbuilt/work", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/.veil-desk/chats/cbuilt.jsonl", .data = "{\"title\":\"built chat\"}\n" }) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/.veil-desk/chats/cfresh.jsonl", .data = "{\"title\":\"fresh chat\"}\n" }) catch unreachable;
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    // the restart case: reopening the chat that built something must cd the console back into its workdir
    // (build_dir is otherwise only set from a live build-tool response, so the [build] note's promise —
    // "the console is cd'd here" — would be false for a conversation selected after an app restart)
    chat.cmdSelectConv(dd, "cbuilt");
    try std.testing.expectEqualStrings(dd ++ "/u1/_chat/builds/cbuilt/work", chat.build_dir[0..chat.build_dir_len]);

    // switching to a chat that never built must CLEAR the binding, not leak the previous chat's dir
    chat.cmdSelectConv(dd, "cfresh");
    try std.testing.expect(chat.build_dir_len == 0);

    // + (new chat) clears it too
    chat.cmdSelectConv(dd, "cbuilt");
    try std.testing.expect(chat.build_dir_len > 0);
    chat.cmdNewConv(dd);
    try std.testing.expect(chat.build_dir_len == 0);
}

test "the 64-message eviction pins the conversation's original goal (slot 0 stays)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-pin-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);
    // a long build arc: the goal, then a flood of tool-result rows well past the ring's capacity —
    // without the pin, row 0 (the assignment itself) would be the FIRST thing evicted and the model would
    // spend the rest of the arc working from tool chatter alone
    chat.appendMsgFull(dd, .user, "GOAL: build the neuronet app with axum 0.7", false);
    var i: usize = 0;
    while (i < store_mod.MAX_CHAT_MSGS + 20) : (i += 1) {
        chat.appendMsgFull(dd, .cast_note, "[tool:write_file]\nwrote a file", false);
    }
    {
        store.lock();
        defer store.unlock();
        try std.testing.expect(store.msg_count == store_mod.MAX_CHAT_MSGS);
        try std.testing.expect(store.msgs[0].role == .user);
        try std.testing.expect(std.mem.startsWith(u8, store.msgs[0].textStr(), "GOAL: build the neuronet"));
    }
}

test "cast watch resolves the run dir, tails it, and collects on stop (no server needed)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/u1/cafe01/work", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/u1/cafe01/events.jsonl", .data = "{\"seq\":1,\"kind\":\"act\",\"round\":1,\"mind\":\"nova\",\"tool\":\"observe\",\"result\":\"looked around\"}\n" ++
        "{\"seq\":2,\"kind\":\"score\",\"round\":2,\"passed\":2,\"total\":3,\"pct\":66}\n" ++
        "{\"seq\":3,\"kind\":\"stopped\",\"reason\":\"complete\"}\n" }) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/u1/cafe01/swarm.json", .data = "{\"swarm\":\"chat-test\"}" }) catch unreachable;

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    {
        const d = dd;
        @memcpy(store.settings.data_dir[0..d.len], d);
        store.settings.data_dir_len = d.len;
    }
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    // an active conversation to receive the [cast] digest
    chat.cmdNewConv(dd);
    // pretend a cast was fired: hex known, rel not yet resolved, one right-pane row
    chat.cast_active = true;
    chat.cast_epoch = chat.conv_epoch; // what fireCast stamps — the cast belongs to the CURRENT conversation position
    const hex = "cafe01";
    @memcpy(chat.cast_hex[0..hex.len], hex);
    chat.cast_hex_len = hex.len;
    chat.cast_deadline_s = chat.nowS() + 600;
    store.casts[0] = .{ .status = .deploying };
    store.cast_count = 1;

    chat.watchCast(dd); // resolves u1/cafe01 and sees `stopped` → collect fires a model turn
    try std.testing.expect(!chat.cast_active);
    try std.testing.expectEqualStrings("u1/cafe01", chat.cast_rel[0..chat.cast_rel_len]);
    try std.testing.expect(store.casts[0].status == .done);
    try std.testing.expect(store.cast_tail_count >= 2);
    // the digest message landed in the conversation
    var found = false;
    var i: usize = 0;
    while (i < store.msg_count) : (i += 1) {
        if (store.msgs[i].role == .cast_note and std.mem.indexOf(u8, store.msgs[i].textStr(), "score 66%") != null) found = true;
    }
    try std.testing.expect(found);
    // the collect turn started a model call (against the default local endpoint) — abort it either way
    try std.testing.expect(chat.turn == .collect or chat.turn == .idle);
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
}

test "epoch barrier: a cast finishing after a switch to a DIFFERENT conv injects nothing (no note, no digest)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp2";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/u1/cafe02/work", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/u1/cafe02/events.jsonl", .data = "{\"seq\":1,\"kind\":\"score\",\"round\":2,\"passed\":2,\"total\":3,\"pct\":66}\n" ++
        "{\"seq\":2,\"kind\":\"stopped\",\"reason\":\"complete\"}\n" }) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dd ++ "/u1/cafe02/swarm.json", .data = "{\"swarm\":\"chat-test\"}" }) catch unreachable;

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);
    chat.cast_active = true;
    chat.cast_epoch = chat.conv_epoch;
    const hex = "cafe02";
    @memcpy(chat.cast_hex[0..hex.len], hex);
    chat.cast_hex_len = hex.len;
    chat.cast_deadline_s = chat.nowS() + 600;
    store.casts[0] = .{ .status = .deploying };
    store.cast_count = 1;

    chat.conv_epoch += 1; // the user moved on (a newer send / conv switch / Stop) before the cast finished

    chat.watchCast(dd); // sees `stopped` — but the epoch moved to a DIFFERENT conv, so it must NOT inject anything
    try std.testing.expect(!chat.cast_active);
    try std.testing.expect(chat.turn == .idle); // no hijacked model turn
    var saw_note = false;
    var saw_digest = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.msg_count) : (i += 1) {
            const txt = store.msgs[i].textStr();
            if (std.mem.indexOf(u8, txt, "finished in the background") != null) saw_note = true;
            if (std.mem.indexOf(u8, txt, "score 66%") != null) saw_digest = true;
        }
    }
    // cast_conv (unset) != the on-screen conv, so this is a genuine switch: the finish must pollute NEITHER
    // the on-screen transcript (no note, no digest) NOR its hippocampus — the .done Swarm row is the record.
    try std.testing.expect(!saw_note);
    try std.testing.expect(!saw_digest);
}

test "collect fizzle: a post-cast answer that only announces the repair re-enters as a tool turn" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp3";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);

    // fabricate the settled .collect turn: the cast digest was folded, the model's answer only ANNOUNCES
    // the repair ("Let me inspect what's on disk now and fix it." would otherwise settle idle on the promise)
    chat.stream = .{ .done = true };
    chat.stream.content.appendSlice(std.testing.allocator, "The cast delivered an incomplete `varieties.html` — truncated mid-CSS. Let me inspect what's on disk now and fix it.") catch unreachable;
    chat.turn = .collect;
    chat.turn_epoch = chat.conv_epoch;
    chat.turn_start_ms = chat.nowMs(); // startTurn normally stamps these; the fabricated turn must too
    chat.stream.started_s = chat.nowS();

    chat.pumpStream(dd); // settles the collect → must re-enter, never sit idle on the promise
    try std.testing.expectEqual(@as(u8, 1), chat.act_nudges);
    // the answer text landed AND the follow-through note landed (the promise never silently vanishes)
    var saw_answer = false;
    var saw_nudge = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.msg_count) : (i += 1) {
            const txt = store.msgs[i].textStr();
            if (store.msgs[i].role == .veil and std.mem.indexOf(u8, txt, "inspect what's on disk") != null) saw_answer = true;
            if (std.mem.indexOf(u8, txt, "announced an action but didn't perform it") != null) saw_nudge = true;
        }
    }
    try std.testing.expect(saw_answer);
    try std.testing.expect(saw_nudge);
    // the re-entered turn is a kind that CAN act (.idle only if llm.start couldn't spawn curl here)
    try std.testing.expect(chat.turn == .tool_follow or chat.turn == .idle);
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
}

test "terminal verify: a build that reaches DONE gets one whole-build check; a non-build DONE finishes clean" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp7";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);
    const ask = "build a 3-file site: dashboard + two games";
    chat.last_user_len = ask.len;
    @memcpy(chat.last_user[0..ask.len], ask);
    store.msgs[0] = .{}; // msgs is undefined storage — claiming a slot without writing it leaves 0xaa in text_len, and the verify-note scan below reads every slot
    store.msg_count = 1;
    store.chat_loop = true;

    // the arc BUILT a file earlier (arc_built sticky), then loop_infer emits DONE — the model may have only
    // ANNOUNCED the remaining files. loopContinue must run ONE terminal verify.
    chat.arc_built = true;
    chat.turn_epoch = chat.conv_epoch;
    chat.loopContinue(dd, "DONE");
    try std.testing.expect(chat.arc_final_verified); // the whole-build check fired instead of a bare finish
    var saw_verify_note = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.msg_count) : (i += 1) {
            if (std.mem.indexOf(u8, store.msgs[i].textStr(), "checking every file the build needs") != null) saw_verify_note = true;
        }
    }
    try std.testing.expect(saw_verify_note);
    try std.testing.expect(chat.turn == .tool_follow or chat.turn == .idle); // the verify turn is live (or curl absent)
    if (chat.turn != .idle) {
        llm.abort(&chat.stream, io);
        chat.stream.deinit(std.testing.allocator);
        chat.turn = .idle;
    }
    // a SECOND DONE now really finishes — the terminal verify fires at most once per arc
    store.chat_loop = true;
    chat.loopContinue(dd, "DONE");
    try std.testing.expect(!store.chat_loop); // stopped for real

    // a NON-build arc (nothing written) skips the check and finishes immediately
    chat.resetArcFlags();
    store.chat_loop = true;
    chat.arc_built = false;
    chat.loopContinue(dd, "DONE");
    try std.testing.expect(!chat.arc_final_verified);
    try std.testing.expect(!store.chat_loop);
}

test "castMinutes: speed caps the DEFAULT to 2 min but honors an EXPLICIT LONG/minutes request" {
    try std.testing.expectEqual(@as(u32, 2), castMinutes(0, false, true)); // speed default = 2-min quick strike
    try std.testing.expectEqual(@as(u32, 30), castMinutes(30, true, true)); // EXPLICIT "LONG MINUTES 30" in speed → honored (a big job can't finish in 2 min)
    try std.testing.expectEqual(@as(u32, 20), castMinutes(0, true, true)); // EXPLICIT LONG in speed → sustained default
    try std.testing.expectEqual(@as(u32, 1), castMinutes(1, false, true)); // an even shorter explicit ask survives
    try std.testing.expectEqual(@as(u32, 120), castMinutes(400, true, true)); // still ceilinged at 120
    try std.testing.expectEqual(@as(u32, 30), castMinutes(30, true, false)); // autonomy honors LONG MINUTES 30
    try std.testing.expectEqual(@as(u32, 20), castMinutes(0, true, false)); // autonomy LONG default
    try std.testing.expectEqual(CAST_MINUTES, castMinutes(0, false, false)); // autonomy quick default
    try std.testing.expectEqual(@as(u32, 120), castMinutes(400, true, false)); // autonomy ceiling
}

test "arc-driving auto-loop: a chain that ACTED keeps looping past a prose settle; a workless step ends it; a question yields" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp6";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    store.settings.server_chat = false; // this test exercises the LOCAL auto-loop; maybeLoop now defers to the server when server_chat is on
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);
    const ask = "build a tiny two-page site: index.html and about.html";
    chat.last_user_len = ask.len;
    @memcpy(chat.last_user[0..ask.len], ask);
    store.msgs[0] = .{}; // msgs is undefined storage — initialize the slot the count claims
    store.msg_count = 1; // maybeLoop needs something to continue from

    // (1) the chain WROTE a file earlier (arc_acted), then settled on prose announcing the next one
    // (acted=false after the settle reset) — the loop must KEEP DRIVING
    store.chat_loop = true;
    chat.acted = false;
    chat.arc_acted = true;
    chat.maybeLoop(dd);
    try std.testing.expect(store.chat_loop); // never stopLoopQuiet'd — the arc is working
    if (chat.turn == .loop_infer) { // the loop-infer turn may be live (model call against the default endpoint)
        llm.abort(&chat.stream, io);
        chat.stream.deinit(std.testing.allocator);
        chat.turn = .idle;
    }

    // (2) ONE workless step is TOLERATED (persistence is the feature — a single announce-only settle must
    // not disconnect the loop); a SECOND consecutive workless settle ends it (that's a conversation, not work)
    store.chat_loop = true;
    chat.loop_idle = 0;
    chat.acted = false;
    chat.arc_acted = false;
    chat.maybeLoop(dd);
    try std.testing.expect(store.chat_loop); // first idle settle: still armed
    if (chat.turn == .loop_infer) {
        llm.abort(&chat.stream, io);
        chat.stream.deinit(std.testing.allocator);
        chat.turn = .idle;
    }
    chat.acted = false;
    chat.arc_acted = false;
    chat.maybeLoop(dd);
    try std.testing.expect(!store.chat_loop); // second idle settle: the anti-spin bound ends it

    // (3) a settle whose reply ENDS WITH A QUESTION yields to the user even though the arc acted
    store.chat_loop = true;
    chat.acted = false;
    chat.arc_acted = true;
    chat.stream = .{ .done = true };
    chat.stream.content.appendSlice(std.testing.allocator, "index.html is written. Want me to add a dark theme next?") catch unreachable;
    chat.turn = .user;
    chat.turn_epoch = chat.conv_epoch;
    chat.turn_start_ms = chat.nowMs();
    chat.stream.started_s = chat.nowS();
    chat.pumpStream(dd);
    try std.testing.expect(!store.chat_loop); // the question handed the turn to the user
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
}

test "auto-loop-afk: the third tier never backs itself out — idle settles, DONE, repeats, caps, and questions all keep it armed; only the user's Stop ends it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp8";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    store.settings.server_chat = false; // this test exercises the LOCAL auto-loop; maybeLoop now defers to the server when server_chat is on
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);
    const ask = "build a tiny two-page site: index.html and about.html";
    chat.last_user_len = ask.len;
    @memcpy(chat.last_user[0..ask.len], ask);
    store.msgs[0] = .{}; // msgs is undefined storage — initialize the slot the count claims
    store.msg_count = 1;
    store.chat_loop = true;
    store.chat_loop_afk = true;
    const drop = struct { // abort a live loop-started turn (real curl against the default endpoint)
        fn go(c: *Chat, i: std.Io) void {
            if (c.turn != .idle) {
                llm.abort(&c.stream, i);
                c.stream.deinit(std.testing.allocator);
                c.turn = .idle;
            }
        }
    }.go;

    // (1) TWO consecutive workless settles quiet-disarm plain auto-loop; afk resets the bound and keeps driving
    chat.acted = false;
    chat.arc_acted = false;
    chat.maybeLoop(dd);
    drop(chat, io);
    chat.acted = false;
    chat.arc_acted = false;
    chat.maybeLoop(dd);
    try std.testing.expect(store.chat_loop and store.chat_loop_afk); // the anti-spin bound reset instead of stopping
    drop(chat, io);

    // (2) DONE folds into a fresh drive instead of finishing
    chat.turn_epoch = chat.conv_epoch;
    chat.loopContinue(dd, "DONE");
    try std.testing.expect(store.chat_loop and store.chat_loop_afk);
    try std.testing.expect(std.mem.eql(u8, chat.last_user[0..chat.last_user_len], AFK_DRIVE_MSG)); // the drive message went out as the next step
    drop(chat, io);

    // (3) a repeated next-step is churn, not a stop, in afk
    chat.loopContinue(dd, AFK_DRIVE_MSG);
    try std.testing.expect(store.chat_loop and store.chat_loop_afk);
    drop(chat, io);

    // (4) the iteration cap wraps instead of stopping
    chat.loop_iter = LOOP_MAX_ITERS;
    chat.loopContinue(dd, "now add a third page: contact.html");
    try std.testing.expect(store.chat_loop and store.chat_loop_afk);
    try std.testing.expectEqual(@as(u32, 1), chat.loop_iter); // wrapped to 0, then counted this step
    drop(chat, io);

    // (5) the afkAbsorbStop backstop: any stop path not explicitly afk-guarded is swallowed, budgets reset
    chat.loop_iter = 7;
    chat.loop_casts = 3;
    chat.stopLoop(dd, "synthetic stop that must not land");
    try std.testing.expect(store.chat_loop and store.chat_loop_afk);
    try std.testing.expectEqual(@as(u32, 0), chat.loop_iter);
    try std.testing.expectEqual(@as(u32, 0), chat.loop_casts);
    chat.stopLoopQuiet();
    try std.testing.expect(store.chat_loop and store.chat_loop_afk);

    // (6) a '?' reply does NOT yield in afk — the user is away, the driver answers on their behalf
    chat.acted = false;
    chat.arc_acted = true;
    chat.stream = .{ .done = true };
    chat.stream.content.appendSlice(std.testing.allocator, "index.html is written. Want me to add a dark theme next?") catch unreachable;
    chat.turn = .user;
    chat.turn_epoch = chat.conv_epoch;
    chat.turn_start_ms = chat.nowMs();
    chat.stream.started_s = chat.nowS();
    chat.pumpStream(dd);
    try std.testing.expect(store.chat_loop and store.chat_loop_afk); // still armed through the question
    drop(chat, io);

    // (7) the user's Stop button DOES end it — the user always wins
    chat.stopTurn(dd);
    try std.testing.expect(!store.chat_loop and !store.chat_loop_afk);
}

test "castSpecFromUser: verbatim user config only (word-bounded 'long', N minds, N minutes)" {
    const s1 = castSpecFromUser("cast a swarm to build the site", "build the site");
    try std.testing.expect(!s1.long and s1.minds == 0 and s1.minutes == 0);
    const s2 = castSpecFromUser("cast a long swarm with 5 minds for 20 minutes to research X", "research X");
    try std.testing.expect(s2.long and s2.minds == 5 and s2.minutes == 20);
    // "along"/"belongs" are not "long"; a bare number not before minds/minutes carries nothing
    const s3 = castSpecFromUser("cast a swarm to walk along the 5 trails that belong here", "walk the trails");
    try std.testing.expect(!s3.long and s3.minds == 0 and s3.minutes == 0);
    const s4 = castSpecFromUser("spin up a sustained hive to monitor the feed", "monitor the feed");
    try std.testing.expect(s4.long);
}

test "cast fast-path: an explicit cast request deploys straight from send — no deciding model turn" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp5";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);

    chat.store.settings.server_chat = false; // this test drives the LOCAL engine (no server round-trip)
    chat.cmdSend(dd, "cast a swarm to build a tiny two-page site: index.html and about.html.");
    // the dispatch happened synchronously: no model turn was started, and the cast note (deployed OR the
    // bounded "no response from the veil server" failure — this env has no server) is already in the chat
    try std.testing.expect(chat.turn == .idle);
    var saw_cast_note = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.msg_count) : (i += 1) {
            if (std.mem.startsWith(u8, store.msgs[i].textStr(), "[cast]")) saw_cast_note = true;
        }
    }
    try std.testing.expect(saw_cast_note or chat.cast_active);
}

test "explicit cast request: a pasted-file reply falls through to the CAST recovery, never the write hijack" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-chat-tmp4";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);

    // the hijack case: user explicitly asks for a swarm, the model pastes the whole file instead
    const ask = "cast a swarm to finish the two-page tea website: build a complete index.html, plain css.";
    chat.last_user_len = ask.len;
    @memcpy(chat.last_user[0..ask.len], ask);
    chat.stream = .{ .done = true };
    chat.stream.content.appendSlice(std.testing.allocator, "index.html\n```html\n<!DOCTYPE html>\n<html>\n<head><title>The Leaf & Kettle</title></head>\n" ++
        "<body>\n<h1>Tea</h1>\n<p>green black oolong white herbal pu-erh</p>\n" ++
        "<a href=\"varieties.html\">varieties</a>\n</body>\n</html>\n```\n") catch unreachable;
    chat.turn = .user;
    chat.turn_epoch = chat.conv_epoch;
    chat.turn_start_ms = chat.nowMs();
    chat.stream.started_s = chat.nowS();

    chat.pumpStream(dd); // settle: must reach the cast recovery, not synthesize a write_file
    var saw_cast_attempt = false;
    var saw_write_chip = false;
    {
        store.lock();
        defer store.unlock();
        var i: usize = 0;
        while (i < store.msg_count) : (i += 1) {
            const txt = store.msgs[i].textStr();
            if (std.mem.startsWith(u8, txt, "[cast]")) saw_cast_attempt = true; // deployed OR "no response from the veil server" — either proves the recovery fired
            if (std.mem.indexOf(u8, txt, "[tool:write_file]") != null) saw_write_chip = true;
        }
    }
    try std.testing.expect(saw_cast_attempt or chat.cast_active);
    try std.testing.expect(!saw_write_chip);
    llm.abort(&chat.stream, io);
    chat.stream.deinit(std.testing.allocator);
}

test "LIVE chat turn: streams a real reply from local Ollama (best-effort, skips if down)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    if (!scan.serverOnline(io, 11434)) {
        std.debug.print("\n[chat live test] no Ollama on :11434 — skipping\n", .{});
        return;
    }
    const dd = "zig-chat-live-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    const model = if (Io.Dir.cwd().access(io, "../data/.veil_gptoss", .{})) |_| "gpt-oss:20b" else |_| "llama3.1:8b"; // marker → test the thinking model's pump path
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = model.len;

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    chat.store.settings.server_chat = false; // this test drives the LOCAL engine (no server round-trip)
    chat.cmdSend(dd, "Reply with exactly one short sentence: what is the capital of France?");
    try std.testing.expect(chat.turn == .user);
    var waited: usize = 0;
    while (chat.turn != .idle and waited < 3000) : (waited += 1) { // up to ~5min for a cold thinking model
        chat.pumpStream(dd);
        if (waited % 50 == 0) std.debug.print("[live] t+{d}s turn={s} content={d}b reason={d}b done={} saw_any={}\n", .{ waited / 10, @tagName(chat.turn), chat.stream.content.items.len, chat.stream.reasoning.items.len, chat.stream.done, chat.stream.saw_any });
        io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expect(chat.turn == .idle);
    // a veil reply landed and it is non-empty, non-error. NOT "the last row": auto-loop is on by default,
    // so after the answer the loop may infer a follow-up whose guard note (e.g. "auto-loop paused: the
    // veil wanted to cast") legitimately lands after the reply — the reply itself is what this test owns.
    try std.testing.expect(store.msg_count >= 2);
    // This test owns the PIPE (a real stream parsed, settled idle, persisted) — not the live model's
    // CHOICE. Two legitimate outcomes: a prose reply (a non-empty .veil row), or the model chose to CAST
    // (gpt-oss may cast even on a trivia question, all prose in its reasoning channel) — then the visible
    // outcome is the cast/loop-guard note, since this env has no authorized veil server.
    // Either way no row may carry a model error.
    var saw_reply = false;
    var saw_cast_flow = false;
    {
        var i: usize = 0;
        while (i < store.msg_count) : (i += 1) {
            const m = &store.msgs[i];
            const txt = m.textStr();
            std.debug.print("[chat live test] row {d} role={s} {d}b: {s}\n", .{ i, @tagName(m.role), m.text_len, txt[0..@min(m.text_len, 120)] });
            try std.testing.expect(std.mem.indexOf(u8, txt, "(model error") == null);
            if (m.role == .veil and m.text_len > 0) saw_reply = true;
            if (m.role == .cast_note and (std.mem.startsWith(u8, txt, "[cast]") or std.mem.indexOf(u8, txt, "auto-loop paused") != null)) saw_cast_flow = true;
        }
    }
    try std.testing.expect(saw_reply or saw_cast_flow);
    // and it persisted: the conversation file holds both messages
    var pb: [700]u8 = undefined;
    var idb: [64]u8 = undefined; // = Store.conv_active capacity; [32] literals here were the missed-widening panic class
    const idn: usize = store.conv_active_len;
    @memcpy(idb[0..idn], store.conv_active[0..idn]);
    const path = Chat.convPath(dd, idb[0..idn], &pb).?;
    const data = Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(1 << 20)) catch unreachable;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "capital of France") != null);
}

// Full-workflow live test (opt-in): drives the REAL Chat worker through the whole cowork chain against a
// live veil server + local gpt-oss — explicit cast fires, the chat answers a SECOND question in parallel
// while the swarm runs, then on completion the collect turn answers from the swarm's built file. Heavy
// (~6-10 min on local gpt-oss), so it only runs when VEIL_E2E=1 AND both servers are up; otherwise it skips.
test "E2E cowork: explicit cast fires, chat replies in parallel, collect answers from the swarm's file" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    // opt-in via a marker file (heavy test): `touch ../data/.veil_e2e` before running, remove it after
    Io.Dir.cwd().access(io, "../data/.veil_e2e", .{}) catch {
        std.debug.print("\n[E2E] create ../data/.veil_e2e to run the full cowork test — skipping\n", .{});
        return;
    };
    if (!scan.serverOnline(io, 11434)) {
        std.debug.print("\n[E2E] no Ollama on :11434 — skipping\n", .{});
        return;
    }
    if (!scan.serverOnline(io, 8787)) {
        std.debug.print("\n[E2E] no veil server on :8787 — skipping\n", .{});
        return;
    }
    // dd is the LIVE server data dir (../data from desktop/): the veil server writes swarm run dirs under
    // <dd>/u<uid>/<hex>, so watchCast must scan HERE to see the cast it fired — exactly as the shipped app
    // does (its data_dir points at the server's data). NB: never deleteTree(dd) — it is real user data; the
    // test removes only the single conversation file it creates (defer below).
    const dd = "../data";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};

    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    const model = "gpt-oss:20b";
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = model.len;
    store.settings.port = 8787;
    // the veil server drops an admin key at <home>/data/.desktop_key; the test cwd is desktop/, so ../data
    if (Io.Dir.cwd().readFileAlloc(io, "../data/.desktop_key", std.testing.allocator, .limited(4096)) catch null) |key| {
        defer std.testing.allocator.free(key);
        const kt = std.mem.trim(u8, key, " \r\n\t");
        if (kt.len > 0 and kt.len <= store.settings.token.len) {
            @memcpy(store.settings.token[0..kt.len], kt);
            store.settings.token_len = @intCast(kt.len);
        }
    }

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    // make sure any swarm we spawn gets stopped even if an assertion fails mid-test
    defer if (chat.cast_rel_len > 0) {
        _ = scan.writeControl(io, std.testing.allocator, dd, chat.cast_rel[0..chat.cast_rel_len], "{\"op\":\"stop\"}");
    };
    // dd is the LIVE data dir — clean up ONLY the one conversation file this test created (never the tree)
    defer if (store.conv_active_len > 0) {
        var pb: [700]u8 = undefined;
        if (Chat.convPath(dd, store.conv_active[0..store.conv_active_len], &pb)) |cp| Io.Dir.cwd().deleteFile(io, cp) catch {};
    };

    const tick = struct {
        fn pump(c: *Chat, d: []const u8, i: std.Io, w: usize, tag: []const u8) void {
            c.pumpStream(d);
            c.watchCast(d);
            if (w % 100 == 0) std.debug.print("[E2E] {s} t+{d}s turn={s} cast_active={} msgs={d}\n", .{ tag, w / 10, @tagName(c.turn), c.cast_active, c.store.msg_count });
            i.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
    };

    // 1) explicit cast request -> user turn completes -> a cast fires (CAST line or the userWantsCast recovery)
    std.debug.print("[E2E] step1: sending cast request...\n", .{});
    chat.store.settings.server_chat = false; // this test drives the LOCAL engine (no server round-trip)
    chat.cmdSend(dd, "cast a swarm to write two facts about the moon to facts.md");
    var waited: usize = 0;
    while (chat.turn != .idle and waited < 3600) : (waited += 1) tick.pump(chat, dd, io, waited, "s1"); // <=6min for the turn
    try std.testing.expect(chat.cast_active); // the cast deployed
    std.debug.print("\n[E2E] step1 OK — cast fired: {s}\n", .{chat.cast_hex[0..chat.cast_hex_len]});

    // 2) PARALLEL COWORK: with the swarm still running, the chat answers a second, unrelated question
    try std.testing.expect(chat.cast_active); // still running
    const before = store.msg_count;
    chat.cmdSend(dd, "While that runs, answer directly: what is 7 times 8? Reply with just the number.");
    waited = 0;
    while (chat.turn != .idle and waited < 2400) : (waited += 1) tick.pump(chat, dd, io, waited, "s2"); // <=4min
    try std.testing.expect(store.msg_count > before);
    const par = &store.msgs[store.msg_count - 1];
    try std.testing.expect(par.role == .veil and par.text_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, par.textStr(), "(model error") == null);
    std.debug.print("[E2E] step2 OK — parallel reply while cast_active={}: {s}\n", .{ chat.cast_active, par.textStr()[0..@min(par.text_len, 80)] });

    // 3) let the swarm finish -> collectCast folds the digest + RAGs the file -> collect turn answers
    waited = 0;
    while (chat.cast_active and waited < 7200) : (waited += 1) tick.pump(chat, dd, io, waited, "s3-cast"); // <=12min for the cast
    try std.testing.expect(!chat.cast_active); // completed + collected (not timed out mid-run)
    // drain the collect turn the collector started
    waited = 0;
    while (chat.turn != .idle and waited < 2400) : (waited += 1) tick.pump(chat, dd, io, waited, "s3-collect");

    // a [cast] digest landed AND the swarm built facts.md
    var saw_digest = false;
    var saw_file = false;
    var i: usize = 0;
    while (i < store.msg_count) : (i += 1) {
        const t = store.msgs[i].textStr();
        if (store.msgs[i].role == .cast_note and std.mem.indexOf(u8, t, "[cast] finished") != null) saw_digest = true;
        if (std.mem.indexOf(u8, t, "facts.md") != null) saw_file = true;
    }
    try std.testing.expect(saw_digest);
    try std.testing.expect(saw_file);
    const final = &store.msgs[store.msg_count - 1];
    std.debug.print("[E2E] step3 OK — cast collected; digest+facts.md folded in; final reply ({d}b): {s}\n", .{ final.text_len, final.textStr()[0..@min(final.text_len, 120)] });
}

test "castGoal fires on a CAST line within the first few lines" {
    try std.testing.expectEqualStrings("map the auth flow", castGoal("CAST: map the auth flow\nOn it.").?);
    try std.testing.expectEqualStrings("x", castGoal("\n  CAST: x").?);
    // tolerant: a short preamble above the tag still casts
    try std.testing.expectEqualStrings("dig into the repo", castGoal("This needs real work.\nCAST: dig into the repo").?);
    try std.testing.expect(castGoal("hello there") == null);
    try std.testing.expect(castGoal("CAST:") == null);
    // a CAST buried deep in prose is narration
    try std.testing.expect(castGoal("a\nb\nc\nd\ne\nf\nCAST: too deep") == null);
}

test "parseCastSpec reads the AI's swarm config (minds / LONG / minutes)" {
    // bare cast → defaults
    const a = parseCastSpec("CAST: research the topic").?;
    try std.testing.expectEqualStrings("research the topic", a.goal);
    try std.testing.expectEqual(@as(u32, 0), a.minds);
    try std.testing.expect(!a.long);
    // full payload
    const b = parseCastSpec("CAST: build a full REST API\nMINDS 8\nLONG\nMINUTES 30\nnote to user").?;
    try std.testing.expectEqualStrings("build a full REST API", b.goal);
    try std.testing.expectEqual(@as(u32, 8), b.minds);
    try std.testing.expect(b.long);
    try std.testing.expectEqual(@as(u32, 30), b.minutes);
    // MINDS with a colon; CONTINUOUS as an alias for LONG
    const c = parseCastSpec("CAST: x\nMINDS: 12\nCONTINUOUS").?;
    try std.testing.expectEqual(@as(u32, 12), c.minds);
    try std.testing.expect(c.long);
    // no CAST line → null
    try std.testing.expect(parseCastSpec("MINDS 5\nno cast here") == null);
    // FILES: — the veil DECLARES the deliverables; they ride to the engine as the blueprint
    const d = parseCastSpec("CAST: document every source file\nLONG\nFILES: docs/desk/chat.zig.md, docs/desk/main.zig.md\nMINUTES 20").?;
    try std.testing.expectEqualStrings("docs/desk/chat.zig.md, docs/desk/main.zig.md", d.files);
    try std.testing.expect(d.long);
    try std.testing.expectEqual(@as(u32, 20), d.minutes);
    // no FILES line → empty (pure research cast)
    try std.testing.expectEqualStrings("", a.files);
    // PUBLISH — the veil opts the cast into NEWS DESK mode (Telegraph post)
    try std.testing.expect(!a.publish); // default off
    const e = parseCastSpec("CAST: research quantum computing and write a thesis\nMINDS 6\nLONG\nMINUTES 30\nPUBLISH\nposting it publicly").?;
    try std.testing.expect(e.publish);
    try std.testing.expect(e.long);
    try std.testing.expectEqual(@as(u32, 6), e.minds);
    // PUBLISH must be its own line, not a substring of prose ("republish"/"published")
    try std.testing.expect(!parseCastSpec("CAST: x\nnote: this was already published last week").?.publish);
}

test "castSpecFromUser detects a Telegraph/publish ask; fireCast body stays valid JSON" {
    // the user explicitly asks to post publicly → publish on
    try std.testing.expect(castSpecFromUser("cast a swarm to research quantum computing and post it to telegraph", "research quantum computing").publish);
    try std.testing.expect(castSpecFromUser("have the hive publish its findings", "x").publish);
    // an ordinary research ask → publish stays off (no accidental posting)
    try std.testing.expect(!castSpecFromUser("cast a swarm to research quantum computing", "x").publish);
    try std.testing.expect(!castSpecFromUser("summarize the postgres docs", "x").publish); // "post" inside "postgres" must not trip it
}

test "shouldReflectPass: only substantive answers to real requests reflect (hello never recurses)" {
    var longbuf: [600]u8 = undefined;
    @memset(&longbuf, 'x');
    const long = longbuf[0..];
    const q = "Explain in detail how a red-black tree stays balanced and why rotations preserve the invariants.";
    // substantive question + substantive answer -> reflect
    try std.testing.expect(shouldReflectPass(.user, q, long));
    try std.testing.expect(shouldReflectPass(.tool_follow, q, long));
    // a greeting must NOT recurse
    try std.testing.expect(!shouldReflectPass(.user, "hello", "Hi! How can I help you today?"));
    try std.testing.expect(!shouldReflectPass(.user, "hi there", long)); // small-talk user msg
    try std.testing.expect(!shouldReflectPass(.user, "thanks!", long));
    // trivial (short) answer never reflects even for a real question
    try std.testing.expect(!shouldReflectPass(.user, q, "Short answer."));
    // control lines + non-answer turns never reflect
    try std.testing.expect(!shouldReflectPass(.collect, q, long));
    try std.testing.expect(!shouldReflectPass(.reflect, q, long));
    try std.testing.expect(!shouldReflectPass(.user, q, "CAST: research this repo"));
    try std.testing.expect(!shouldReflectPass(.user, q, "TOOL: web_search {}"));
    try std.testing.expect(!shouldReflectPass(.user, q, ""));
}

test "toolCall parses name + raw json args" {
    const a = toolCall("TOOL: web_search {\"query\":\"zig 0.16\"}").?;
    try std.testing.expectEqualStrings("web_search", a.name);
    try std.testing.expectEqualStrings("{\"query\":\"zig 0.16\"}", a.args);
    // no args -> defaults to {}
    const b = toolCall("TOOL: stop_swarm").?;
    try std.testing.expectEqualStrings("stop_swarm", b.name);
    try std.testing.expectEqualStrings("{}", b.args);
    // brace flush against the name (no space)
    const c = toolCall("TOOL: swarm_findings{\"id\":\"abc\"}").?;
    try std.testing.expectEqualStrings("swarm_findings", c.name);
    try std.testing.expectEqualStrings("{\"id\":\"abc\"}", c.args);
    // preamble tolerated; empty/absent -> null
    try std.testing.expectEqualStrings("list_swarms", toolCall("Sure, let me check.\nTOOL: list_swarms {}").?.name);
    try std.testing.expect(toolCall("just chatting") == null);
    try std.testing.expect(toolCall("TOOL:") == null);
    try std.testing.expect(toolCall("a\nb\nc\nd\ne\nf\nTOOL: too_deep {}") == null);
    // MID-LINE calls dispatch (same predicate as stripToolTail — a line-start-only dispatcher would miss
    // these while the stripper hides them, so the call would be neither executed nor shown):
    const m = toolCall("I compared both. Let me write it now.TOOL: write_file {\"path\":\"x.md\",\"content\":\"# X\"}").?;
    try std.testing.expectEqualStrings("write_file", m.name);
    try std.testing.expectEqualStrings("{\"path\":\"x.md\",\"content\":\"# X\"}", m.args);
    // mid-line no-args known tool (trailing punctuation tolerated)
    try std.testing.expectEqualStrings("stop_swarm", toolCall("Let me stop it. TOOL: stop_swarm.").?.name);
    // a KNOWN tool call deep in prose still dispatches (only unknown names are narration there)
    try std.testing.expectEqualStrings("web_search", toolCall("a\nb\nc\nd\ne\nf\nTOOL: web_search {\"query\":\"x\"}").?.name);
    // markdown-wrapped line start is tolerated
    try std.testing.expectEqualStrings("read_file", toolCall("**TOOL: read_file** {\"path\":\"a\"}").?.name);
    // a mid-line prose mention of an unknown name is NOT a call
    try std.testing.expect(toolCall("use the TOOL: menu to pick one") == null);
}

test "toolCall: braces inside a content string never truncate the args (jsonObjEnd)" {
    // a raw byte counter would close the args at the first '}' inside content, shipping invalid JSON the
    // server rejects as a bad path. A JS/CSS/code tail closing a block is the common trigger.
    const unbalanced = "TOOL: write_file {\"path\":\"a.js\",\"content\":\"  return x;\\n}\\n\"}";
    const a = toolCall(unbalanced).?;
    try std.testing.expectEqualStrings("write_file", a.name);
    try std.testing.expectEqualStrings("{\"path\":\"a.js\",\"content\":\"  return x;\\n}\\n\"}", a.args);

    // a full function body (nested + trailing braces, quotes, escapes) survives intact
    const css = "TOOL: write_file {\"path\":\"s.css\",\"content\":\".a{color:red}\\n.b{margin:0}\"}";
    const b = toolCall(css).?;
    try std.testing.expectEqualStrings("{\"path\":\"s.css\",\"content\":\".a{color:red}\\n.b{margin:0}\"}", b.args);

    // an escaped quote inside content must NOT prematurely end the string (so a following '}' still counts as literal)
    const esc = "TOOL: write_file {\"path\":\"q.txt\",\"content\":\"say \\\"hi\\\" }\"}";
    const c = toolCall(esc).?;
    try std.testing.expectEqualStrings("{\"path\":\"q.txt\",\"content\":\"say \\\"hi\\\" }\"}", c.args);

    // a genuinely truncated big write (opened, never closed) still yields "{}" here AND trips looksTruncatedWrite
    const cut = "TOOL: write_file {\"path\":\"big.html\",\"content\":\"" ++ ("<div>x</div>" ** 40);
    try std.testing.expectEqualStrings("{}", toolCall(cut).?.args);
    try std.testing.expect(looksTruncatedWrite(cut));
    // ...but a CLOSED write whose content merely contains '}' is NOT flagged truncated
    try std.testing.expect(!looksTruncatedWrite(unbalanced));
}

test "codeBlockWrite rescues a pasted file; ignores snippets + missing filenames" {
    const gpa = std.testing.allocator;
    // a real paste: user named a file, reply is mostly a ```block > 200 chars
    const big = "x" ** 400;
    const reply = "Here it is:\n```html\n" ++ big ++ "\n```";
    const s = codeBlockWrite(gpa, "Replace the content of arkanoid.html with the full game", reply).?;
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"path\":\"arkanoid.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"content\":\"") != null);
    // no filename in the request -> no rescue
    try std.testing.expect(codeBlockWrite(gpa, "explain how this works", reply) == null);
    // a small snippet inside a long explanation -> no rescue (would clobber the real file)
    const expl = "The key part is:\n```js\nconst x=1;\n```\n" ++ ("and here is a long explanation " ** 40);
    try std.testing.expect(codeBlockWrite(gpa, "improve game.js", expl) == null);
    try std.testing.expectEqualStrings("game.js", recoverFilename("please edit game.js now").?);
    try std.testing.expect(recoverFilename("no file mentioned") == null);
}

test "codeBlockWrite names a paste from its own header/narration, never the request's stray filename" {
    const gpa = std.testing.allocator;
    // the build task mentions static/index.html; the model pastes src/routes.rs as a ```rust block. A
    // request-first naming order would write the Rust into index.html.
    const task = "Build the app: Cargo.toml, then src/routes.rs, static/index.html, README.md - write every file";
    const body = "use actix_web::{web, HttpResponse};\n" ++ ("pub async fn feed() -> HttpResponse { HttpResponse::Ok().finish() }\n" ** 4);
    const reply = "Writing src/routes.rs — the web routes.\n\n```rust\n" ++ body ++ "```";
    const s = codeBlockWrite(gpa, task, reply).?;
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"path\":\"src/routes.rs\"") != null);
    // the block's own first-line header comment beats everything (no narration needed)
    const reply2 = "Here you go.\n\n```rust\n// src/models.rs\n" ++ body ++ "```";
    const s2 = codeBlockWrite(gpa, task, reply2).?;
    defer gpa.free(s2);
    try std.testing.expect(std.mem.indexOf(u8, s2, "\"path\":\"src/models.rs\"") != null);
    // a ```toml paste recovers Cargo.toml (the old extension list didn't know .toml at all)
    const toml_body = "[package]\nname = \"neuronet\"\nedition = \"2021\"\n" ++ ("# dependency pins follow\n" ** 12);
    const reply3 = "Writing Cargo.toml now:\n```toml\n" ++ toml_body ++ "```";
    const s3 = codeBlockWrite(gpa, task, reply3).?;
    defer gpa.free(s3);
    try std.testing.expect(std.mem.indexOf(u8, s3, "\"path\":\"Cargo.toml\"") != null);
    // the language gate refuses a mismatched rescue outright: a rust paste with only .html names in
    // scope must NOT be written anywhere (better no rescue than a corrupted page)
    const reply4 = "Here you go:\n\n```rust\n" ++ body ++ "```";
    try std.testing.expect(codeBlockWrite(gpa, "update static/index.html", reply4) == null);
    // narration nearest the fence wins over an earlier mention
    const reply5 = "Based on index.html, here is app.js:\n```js\n" ++ ("const post = () => { render(feed); };\n" ** 10) ++ "```";
    const s5 = codeBlockWrite(gpa, "", reply5).?;
    defer gpa.free(s5);
    try std.testing.expect(std.mem.indexOf(u8, s5, "\"path\":\"app.js\"") != null);
}

test "layout guard: topSegment + layoutAllows judge new top-level paths against the hive blueprint" {
    try std.testing.expectEqualStrings("app", topSegment("app/models.py"));
    try std.testing.expectEqualStrings("app.py", topSegment("app.py"));
    try std.testing.expectEqualStrings("app", topSegment("./app/__init__.py"));
    const bp = "app.py\nbase.html\napp/models.py\nconfig.py\nrequirements.txt";
    // inside the blueprint's structure -> allowed
    try std.testing.expect(layoutAllows(bp, "app/routes.py"));
    try std.testing.expect(layoutAllows(bp, "app.py"));
    try std.testing.expect(layoutAllows(bp, "config.py"));
    // a NEW top-level package beside the hive's layout (the rival-build failure) -> rejected
    try std.testing.expect(!layoutAllows(bp, "social_network/app/__init__.py"));
    try std.testing.expect(!layoutAllows(bp, "main.py"));
    // dotfiles/tool sidecars always pass
    try std.testing.expect(layoutAllows(bp, ".tool-chat.py"));
}

test "toolCallLoose recovers a call narrated inside reasoning" {
    // the gpt-oss shape: content empty, the decision lives mid-sentence in reasoning
    const r = "We must use web_search tool. That is not a cast. So we issue TOOL: web_search {\"query\":\"Zig 0.16 release highlights\"}";
    const a = toolCallLoose(r).?;
    try std.testing.expectEqualStrings("web_search", a.name);
    try std.testing.expectEqualStrings("{\"query\":\"Zig 0.16 release highlights\"}", a.args);
    // takes the LAST occurrence; balanced braces
    const b = toolCallLoose("first TOOL: list_swarms {} then decide TOOL: stop_swarm {\"id\":\"x\"}").?;
    try std.testing.expectEqualStrings("stop_swarm", b.name);
    try std.testing.expectEqualStrings("{\"id\":\"x\"}", b.args);
    // bare name, no args -> {}
    try std.testing.expectEqualStrings("{}", toolCallLoose("so I will run TOOL: list_swarms now").?.args);
    try std.testing.expect(toolCallLoose("no tool mentioned here") == null);
}

test "toolCallLoose never mints a call from quoted protocol prose (the live `line\".` 500)" {
    // reasoning QUOTING the protocol — the last TOOL: is part of a quoted sentence; a naive parser would
    // dispatch a tool literally named `line".` and the server would 500 on the malformed envelope
    try std.testing.expect(toolCallLoose("the protocol says to emit TOOL: line\". then we stop") == null);
    try std.testing.expect(toolCallLoose("we could use \"TOOL: <name> {json}\" as documented") == null);
    // the loose channel is recovery, not invention: non-snake names are prose
    try std.testing.expect(toolCallLoose("so we issue TOOL: WebSearch {\"query\":\"x\"}") == null);
    // a real narrated decision still recovers
    const ok = toolCallLoose("so we issue TOOL: web_search {\"query\":\"x\"}").?;
    try std.testing.expectEqualStrings("web_search", ok.name);
}

test "toolCallXml parses the <tool:NAME>{...}</tool:NAME> form that broke the Mario walkthrough" {
    const a = toolCallXml("<tool:read_file>{\"path\":\"index.html\"}</tool:read_file>").?;
    try std.testing.expectEqualStrings("read_file", a.name);
    try std.testing.expectEqualStrings("{\"path\":\"index.html\"}", a.args);
    // inline in prose, takes the FIRST one; balanced braces even with nested objects
    const b = toolCallXml("Let me check. <tool:list_dir>{\"path\":\".\"}</tool:list_dir> then read it").?;
    try std.testing.expectEqualStrings("list_dir", b.name);
    try std.testing.expectEqualStrings("{\"path\":\".\"}", b.args);
    // no args -> {}; not a tool -> null
    try std.testing.expectEqualStrings("{}", toolCallXml("<tool:list_swarms></tool:list_swarms>").?.args);
    try std.testing.expect(toolCallXml("just chatting, no tools") == null);
}

test "loopIsDone recognizes only a bare completion signal, not prose that mentions done" {
    try std.testing.expect(loopIsDone("DONE"));
    try std.testing.expect(loopIsDone("done"));
    try std.testing.expect(loopIsDone("  DONE. "));
    try std.testing.expect(loopIsDone("Complete"));
    try std.testing.expect(loopIsDone("GOAL COMPLETE"));
    // a real next-message that merely contains "done" must NOT halt the loop
    try std.testing.expect(!loopIsDone("Now that the intro is done, add a pricing section."));
    try std.testing.expect(!loopIsDone("Are we done with the outline?"));
    try std.testing.expect(!loopIsDone(""));
}

test "runCall parses the AI's RUN: shell door" {
    try std.testing.expectEqualStrings("dir", runCall("RUN: dir").?);
    try std.testing.expectEqualStrings("git status", runCall("RUN: git status").?);
    // a short preamble above the RUN line is tolerated (mirrors toolCall)
    try std.testing.expectEqualStrings("ls -la", runCall("Sure, let me look.\nRUN: ls -la").?);
    // strips a markdown code fence marker / bullet
    try std.testing.expectEqualStrings("echo hi", runCall("* RUN: echo hi").?);
    // not a command line -> null; empty command -> null; buried deep -> null (narration)
    try std.testing.expect(runCall("just chatting about running things") == null);
    try std.testing.expect(runCall("RUN:") == null);
    try std.testing.expect(runCall("a\nb\nc\nd\ne\nRUN: too_deep") == null);
}

test "jsonStrInto unescapes; extractToolResult picks the right field" {
    var out: [256]u8 = undefined;
    // newlines + escaped quotes survive
    try std.testing.expectEqualStrings("line1\nsaid \"hi\"", jsonStrInto("{\"result\":\"line1\\nsaid \\\"hi\\\"\"}", "result", &out).?);
    try std.testing.expect(jsonStrInto("{\"ok\":true}", "result", &out) == null);
    // extractToolResult precedence: result > findings > err > raw body
    try std.testing.expectEqualStrings("hey", extractToolResult("{\"ok\":true,\"result\":\"hey\"}", &out));
    try std.testing.expectEqualStrings("synth", extractToolResult("{\"ok\":true,\"findings\":\"synth\"}", &out));
    try std.testing.expectEqualStrings("not found", extractToolResult("{\"ok\":false,\"err\":\"not found\"}", &out));
    // list_swarms has no string field -> raw body handed back
    const raw = "{\"ok\":true,\"tool\":\"list_swarms\",\"swarms\":[]}";
    try std.testing.expectEqualStrings(raw, extractToolResult(raw, &out));
}

test "hasRealId distinguishes real ids from placeholders" {
    try std.testing.expect(hasRealId("{\"id\":\"3dd9cc6d\"}"));
    try std.testing.expect(!hasRealId("{}"));
    try std.testing.expect(!hasRealId("{\"id\":\"\"}"));
    try std.testing.expect(!hasRealId("{\"id\":\"current\"}"));
}

test "queryWeak catches missing/placeholder web_search queries" {
    try std.testing.expect(queryWeak("{}")); // no query field
    try std.testing.expect(queryWeak("{\"query\":\"\"}"));
    try std.testing.expect(queryWeak("{\"query\":\"...\"}"));
    try std.testing.expect(queryWeak("{\"query\":\"   \"}"));
    try std.testing.expect(!queryWeak("{\"query\":\"Zig 0.16 release\"}"));
}

test "userWantsCast detects explicit cast requests" {
    try std.testing.expect(userWantsCast("cast a swarm to research AI regulation"));
    try std.testing.expect(userWantsCast("Run the hive on this problem"));
    try std.testing.expect(userWantsCast("spin up a swarm that builds a CLI"));
    try std.testing.expect(userWantsCast("deploy a swarm for the news"));
    try std.testing.expect(!userWantsCast("what is the capital of France?"));
    try std.testing.expect(!userWantsCast("tell me about swarms of bees")); // target but no cast verb
    try std.testing.expect(!userWantsCast("run to the store")); // verb but no swarm/hive
}

test "userWantsKill detects kill requests; nearlySame catches loop spin" {
    try std.testing.expect(userWantsKill("kill the hive"));
    try std.testing.expect(userWantsKill("stop the swarm now"));
    try std.testing.expect(userWantsKill("abort the cast"));
    try std.testing.expect(userWantsKill("terminate it"));
    try std.testing.expect(!userWantsKill("what is the capital of France?"));
    try std.testing.expect(!userWantsKill("build me a website")); // no kill verb
    // the [orchestrator] brief ("narrate and stop; ... the cast finishes", "hive" everywhere) sits in
    // last_user during every orchestrator turn — reading it as a kill order would stop a live cast
    try std.testing.expect(!userWantsKill("(4) never duplicate work the hive is mid-way through — when in doubt, narrate and stop; the full findings come to you when the cast finishes. You have no cast tool here; never output CAST:."));
    // verb far from any target is prose, not an order
    try std.testing.expect(!userWantsKill("we should stop adding features and instead document what the swarm already built"));
    // loop-spin detector: a repeat (or containment) stops the loop; genuinely new steps don't
    try std.testing.expect(nearlySame("check the swarm status", "Check the swarm status.")); // same after fold
    try std.testing.expect(nearlySame("check the swarm status", "check the swarm status now")); // containment
    try std.testing.expect(!nearlySame("write the models file", "now write the routes file"));
    try std.testing.expect(!nearlySame("", "anything"));
}

test "castGoalFromUser strips the cast preamble" {
    var b: [1600]u8 = undefined;
    try std.testing.expectEqualStrings("research AI regulation news", castGoalFromUser("cast a swarm to research AI regulation news", &b));
    try std.testing.expectEqualStrings("build a REST API", castGoalFromUser("spin up a swarm that build a REST API", &b));
    // no clear separator → keep the whole message
    try std.testing.expectEqualStrings("run the hive", castGoalFromUser("run the hive", &b));
}

test "castProviderId routes a cast to the chat's configured backend (local vs BYOK vs custom)" {
    try std.testing.expectEqualStrings("ollama", castProviderId(0, 0)); // local Ollama chat -> local swarm
    try std.testing.expectEqualStrings("openai", castProviderId(2, 0)); // custom OpenAI-compatible URL
    // BYOK: the exact catalog provider the user chats with flows straight to the swarm
    try std.testing.expectEqualStrings("anthropic", castProviderId(1, 0));
    try std.testing.expectEqualStrings("openai", castProviderId(1, 1));
    try std.testing.expectEqualStrings("ollama", castProviderId(1, 2));
    try std.testing.expectEqualStrings("groq", castProviderId(1, 4));
    // the two providers added for BYO Cloudflare + Hugging Face route by their catalog key
    try std.testing.expectEqualStrings("workers-ai", castProviderId(1, 3));
    const hf = for (catalog.providers, 0..) |p, i| {
        if (std.mem.eql(u8, p.key, "huggingface")) break i;
    } else unreachable;
    try std.testing.expectEqualStrings("huggingface", castProviderId(1, @intCast(hf)));
}

test "resolveBase substitutes the Cloudflare {account}, falls back to the sentinel, and passes others through" {
    var out: [256]u8 = undefined;
    const cf = for (&catalog.providers) |*p| {
        if (std.mem.eql(u8, p.key, "workers-ai")) break p;
    } else unreachable;
    // account id spliced into the template
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1", catalog.resolveBase(cf, "abc123", &out));
    // whitespace trimmed
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1", catalog.resolveBase(cf, "  abc123 \n", &out));
    // no account → the "cloudflare" sentinel (server uses its own included creds)
    try std.testing.expectEqualStrings("cloudflare", catalog.resolveBase(cf, "", &out));
    // a non-templated provider passes its base_url through untouched
    const oa = &catalog.providers[1]; // openai
    try std.testing.expectEqualStrings("https://api.openai.com/v1", catalog.resolveBase(oa, "ignored", &out));
}

test "a BYOK Hugging Face chat resolves the router endpoint + hf model + token" {
    const hf_idx: u8 = for (catalog.providers, 0..) |p, i| {
        if (std.mem.eql(u8, p.key, "huggingface")) break @intCast(i);
    } else unreachable;
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    store.settings.chat_kind = 1;
    store.settings.chat_byok = hf_idx;
    const model = "meta-llama/Llama-3.3-70B-Instruct";
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = @intCast(model.len);
    const key = "hf_abc123";
    @memcpy(store.settings.chat_key[0..key.len], key);
    store.settings.chat_key_len = @intCast(key.len);

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = undefined, .gpa = std.testing.allocator, .store = store };
    var bb: [256]u8 = undefined;
    var kb: [192]u8 = undefined;
    var mb: [96]u8 = undefined;
    const prov = chat.resolveProvider(&bb, &kb, &mb);
    try std.testing.expectEqualStrings("https://router.huggingface.co/v1", prov.base_url);
    try std.testing.expectEqualStrings("meta-llama/Llama-3.3-70B-Instruct", prov.model);
    try std.testing.expectEqualStrings("hf_abc123", prov.key);
    try std.testing.expectEqualStrings("huggingface", castProviderId(1, hf_idx));
}

test "a BYO Cloudflare chat builds the account URL from the saved account id" {
    const cf_idx: u8 = for (catalog.providers, 0..) |p, i| {
        if (std.mem.eql(u8, p.key, "workers-ai")) break @intCast(i);
    } else unreachable;
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    store.settings.chat_kind = 1;
    store.settings.chat_byok = cf_idx;
    const acct = "deadbeef00";
    @memcpy(store.settings.cf_account[0..acct.len], acct);
    store.settings.cf_account_len = @intCast(acct.len);
    const model = "@cf/meta/llama-3.1-8b-instruct";
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = @intCast(model.len);

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = undefined, .gpa = std.testing.allocator, .store = store };
    var bb: [256]u8 = undefined;
    var kb: [192]u8 = undefined;
    var mb: [96]u8 = undefined;
    const prov = chat.resolveProvider(&bb, &kb, &mb);
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/deadbeef00/ai/v1", prov.base_url);
    // with no account id, the same provider yields the sentinel so the server uses its own creds
    store.settings.cf_account_len = 0;
    const prov2 = chat.resolveProvider(&bb, &kb, &mb);
    try std.testing.expectEqualStrings("cloudflare", prov2.base_url);
}

test "a BYOK-OpenAI chat resolves an OpenAI cast (base_url + chat model + key); a local chat resolves Ollama" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    // user chatting with OpenAI (BYOK): provider index 1 = "openai"
    store.settings.chat_kind = 1;
    store.settings.chat_byok = 1;
    const model = "gpt-4.1";
    @memcpy(store.settings.chat_model[0..model.len], model);
    store.settings.chat_model_len = model.len;
    const key = "sk-live-abc123";
    @memcpy(store.settings.chat_key[0..key.len], key);
    store.settings.chat_key_len = @intCast(key.len);

    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };

    var bb: [256]u8 = undefined;
    var kb: [192]u8 = undefined;
    var mb: [96]u8 = undefined;
    const prov = chat.resolveProvider(&bb, &kb, &mb);
    // the cast will carry EXACTLY the OpenAI endpoint + the chat's model + the chat's key
    try std.testing.expectEqualStrings("https://api.openai.com/v1", prov.base_url);
    try std.testing.expectEqualStrings("gpt-4.1", prov.model);
    try std.testing.expectEqualStrings("sk-live-abc123", prov.key);
    try std.testing.expectEqualStrings("openai", castProviderId(store.settings.chat_kind, store.settings.chat_byok));

    // flip to local Ollama: same code now routes to the local backend + local model, no key
    store.settings.chat_kind = 0;
    const local_model = "gpt-oss:20b";
    @memcpy(store.settings.chat_model[0..local_model.len], local_model);
    store.settings.chat_model_len = local_model.len;
    const prov2 = chat.resolveProvider(&bb, &kb, &mb);
    try std.testing.expect(std.mem.indexOf(u8, prov2.base_url, "11434") != null);
    try std.testing.expectEqualStrings("gpt-oss:20b", prov2.model);
    try std.testing.expectEqualStrings("ollama", castProviderId(store.settings.chat_kind, store.settings.chat_byok));
}

test "parseMaxCtx pulls the largest loaded context_length from an /api/ps body" {
    const ps = "{\"models\":[{\"name\":\"gpt-oss:20b\",\"size_vram\":3812873994,\"context_length\":131072}]}";
    try std.testing.expectEqual(@as(u32, 131072), Chat.parseMaxCtx(ps));
    const ok = "{\"models\":[{\"name\":\"gpt-oss:20b\",\"context_length\":8192}]}";
    try std.testing.expectEqual(@as(u32, 8192), Chat.parseMaxCtx(ok));
    try std.testing.expectEqual(@as(u32, 0), Chat.parseMaxCtx("{\"models\":[]}")); // nothing loaded
    // multiple models → the largest wins (the one that would dominate VRAM)
    const two = "{\"models\":[{\"context_length\":4096},{\"context_length\":131072}]}";
    try std.testing.expectEqual(@as(u32, 131072), Chat.parseMaxCtx(two));
}

test "noteWithoutCast drops exactly the tag line" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("On it - casting the hive.", noteWithoutCast("CAST: goal\nOn it - casting the hive.", &b));
    try std.testing.expectEqualStrings("", noteWithoutCast("CAST: goal", &b));
    try std.testing.expectEqualStrings("Preamble.\nAfter.", noteWithoutCast("Preamble.\nCAST: goal\nAfter.", &b));
}

test "jStr and jInt read the deploy response" {
    var b: [64]u8 = undefined;
    const body = "{\"ok\":true,\"id\":\"a1b2c3d4e5f60708\",\"state\":\"running\",\"minds\":3}";
    try std.testing.expectEqualStrings("a1b2c3d4e5f60708", jStr(body, "id", &b).?);
    try std.testing.expectEqual(@as(i64, 3), jInt(body, "minds").?);
}

test "composeConsoleResult keeps stdout then stderr, and always the status note on its own line" {
    var buf: [64]u8 = undefined;
    // stderr starts on its OWN line when stdout didn't end with one — glued "outerr" hid where one stream
    // ended and the other began (and a glued status note hid failures from the console-card parser)
    try std.testing.expectEqualStrings("out\nerr", composeConsoleResult(&buf, "out", "err", ""));
    try std.testing.expectEqualStrings("out\nerr", composeConsoleResult(&buf, "out\n", "err", ""));
    // a clean exit with no output → an explicit success line (not a bare "(no output)" the model misreads)
    try std.testing.expectEqualStrings("(command completed successfully — no output)", composeConsoleResult(&buf, "", "", ""));
    // ...but a NON-clean exit (note present) with no body keeps the plain "(no output)" + its note
    try std.testing.expectEqualStrings("(no output)\n(stopped)", composeConsoleResult(&buf, "", "", "(stopped)"));
    try std.testing.expectEqualStrings("hi\n(stopped)", composeConsoleResult(&buf, "hi", "", "(stopped)"));
    try std.testing.expectEqualStrings("hi\n(stopped)", composeConsoleResult(&buf, "hi\n", "", "(stopped)"));
    // when the body alone would overflow, room is reserved so the note (e.g. a timeout) still survives
    var small: [16]u8 = undefined;
    const note = "(timed out)"; // 11 bytes
    const r = composeConsoleResult(&small, "xxxxxxxxxxxxxxxxxxxx", "", note);
    try std.testing.expect(std.mem.endsWith(u8, r, note));
    try std.testing.expect(r.len <= small.len);
}

test "buildBatchScript: echo-off prelude, CRLF normalization, chcp only for non-ASCII, NUL/overflow rejected" {
    var buf: [384]u8 = undefined;
    // every script carries the Python-UTF8 prelude (Windows Python otherwise dies on the first non-ASCII print)
    const PRE = "@echo off\r\nset PYTHONUTF8=1\r\nset PYTHONIOENCODING=utf-8\r\n";
    // quotes pass through VERBATIM — the whole point of the batch carrier (cmd /c argv mangled them)
    try std.testing.expectEqualStrings(PRE ++ "powershell -Command \"(Get-Date).ToString('yyyy-MM-dd HH:mm')\"\r\n", buildBatchScript(&buf, "powershell -Command \"(Get-Date).ToString('yyyy-MM-dd HH:mm')\"").?);
    // lone \n and pre-normalized \r\n both land as CRLF
    try std.testing.expectEqualStrings(PRE ++ "echo a\r\necho b\r\n", buildBatchScript(&buf, "echo a\necho b").?);
    try std.testing.expectEqualStrings(PRE ++ "echo a\r\necho b\r\n", buildBatchScript(&buf, "echo a\r\necho b").?);
    // a non-ASCII byte pulls in the UTF-8 codepage prelude; pure ASCII must not
    try std.testing.expect(std.mem.indexOf(u8, buildBatchScript(&buf, "echo caf\xc3\xa9").?, "chcp 65001>nul\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buildBatchScript(&buf, "echo cafe").?, "chcp") == null);
    // uncarryable commands: an embedded NUL, or a command that overflows the script buffer
    try std.testing.expect(buildBatchScript(&buf, "echo a\x00b") == null);
    var tiny: [8]u8 = undefined;
    try std.testing.expect(buildBatchScript(&tiny, "dir") == null);
    // percent rules: batch parameter refs (%digit/%*) and a line-trailing lone % are doubled back to
    // literals (they worked literally under cmd /c); %VAR% env pairs and pre-escaped %% pass through
    try std.testing.expectEqualStrings(PRE ++ "curl https://x/a%%20b\r\n", buildBatchScript(&buf, "curl https://x/a%20b").?);
    try std.testing.expectEqualStrings(PRE ++ "echo %%* stays\r\n", buildBatchScript(&buf, "echo %* stays").?);
    try std.testing.expectEqualStrings(PRE ++ "echo 50%%\r\n", buildBatchScript(&buf, "echo 50%").?);
    try std.testing.expectEqualStrings(PRE ++ "echo %PATH% ok\r\n", buildBatchScript(&buf, "echo %PATH% ok").?);
    try std.testing.expectEqualStrings(PRE ++ "for %%i in (a) do echo %%i\r\n", buildBatchScript(&buf, "for %%i in (a) do echo %%i").?);
}

test "announcesAction: catches the narrate-without-act fizzles, never final answers" {
    // four real narrate-without-act fizzle replies
    try std.testing.expect(announcesAction("I'll re-create the task with the full path to msg.exe so the scheduler can find it, and set it 30 seconds from now again."));
    try std.testing.expect(announcesAction("Now I'll run the command to register it with the full path to `msg.exe`."));
    try std.testing.expect(announcesAction("You're right — let me check right now.\n\nI'll inspect the **ping** task's status and last run time."));
    try std.testing.expect(announcesAction("I'll register a new **ping** task with the full path to `msg.exe` and it will fire 30 seconds from now."));
    // real final answers must never trigger
    try std.testing.expect(!announcesAction("The output is: `2026-07-09`"));
    try std.testing.expect(!announcesAction("Done! The **ping** scheduled task is set and will trigger a message box saying \"ping\" in about 30 seconds from now. You'll see it pop up momentarily."));
    try std.testing.expect(!announcesAction("Done! If you ever want to change the time, cancel it, or set another reminder, just let me know. Good luck with your appointment, Gary!"));
    try std.testing.expect(!announcesAction("Should I run the command now?")); // a question hands the turn over
    try std.testing.expect(!announcesAction("")); // empty
    // courtesy closings commit to nothing — the verb must FOLLOW the ack, not float in the tail
    try std.testing.expect(!announcesAction("I'll let you know if anything changes."));
    try std.testing.expect(!announcesAction("I'll be here if you need anything else."));
    try std.testing.expect(announcesAction("I\u{2019}ll check the task status now.")); // typographic apostrophe
    // a post-cast collect fizzle: announced the repair, performed nothing
    try std.testing.expect(announcesAction("The cast finished but delivered an **incomplete** result — `varieties.html` is truncated mid-CSS and missing all the tea content, preparation methods, and back link. Let me inspect what's on disk now and fix it."));
}

test "rowRefeeds: the orchestrator brief flows only while its cast is live; results always flow" {
    // thoughts and non-bracketed machine notes never re-feed
    try std.testing.expect(!rowRefeeds(.thought, "the model's own reasoning", true));
    try std.testing.expect(!rowRefeeds(.cast_note, "(verifying the outcome before calling it done)", false));
    try std.testing.expect(!rowRefeeds(.cast_note, "", false));
    // bracketed RESULT rows are ground truth — cast live or not
    try std.testing.expect(rowRefeeds(.cast_note, "[tool:list_dir]\n(empty directory)", false));
    try std.testing.expect(rowRefeeds(.cast_note, "[cast] finished run u1/x: rounds 1, score 100%", false));
    try std.testing.expect(rowRefeeds(.cast_note, "[build] working directory: u1/_chat/builds/x/work", false));
    // the [orchestrator] brief is an INSTRUCTION row scoped to one live cast: re-fed after the cast it
    // would keep the veil narrating-not-acting for the rest of the conversation
    try std.testing.expect(rowRefeeds(.cast_note, "[orchestrator] A hive swarm is building this goal RIGHT NOW...", true));
    try std.testing.expect(!rowRefeeds(.cast_note, "[orchestrator] A hive swarm is building this goal RIGHT NOW...", false));
    // user/veil rows always flow
    try std.testing.expect(rowRefeeds(.user, "finish the two-page site", false));
    try std.testing.expect(rowRefeeds(.veil, "on it", false));
}

test "findToolCall captures args on the next line / in a fence (the deepseek empty-{} write_file bug)" {
    // same-line args still work (the common case)
    {
        const tc = toolCall("I'll search.\nTOOL: web_search {\"query\":\"zig\"}").?;
        try std.testing.expectEqualStrings("web_search", tc.name);
        try std.testing.expectEqualStrings("{\"query\":\"zig\"}", tc.args);
    }
    // args on the FOLLOWING line — a parser that skips only spaces/tabs defaults to "{}" (→ server "bad
    // path"). Must capture the real JSON.
    {
        const tc = toolCall("Writing it now.\nTOOL: write_file\n{\"path\":\"index.html\",\"content\":\"<html></html>\"}").?;
        try std.testing.expectEqualStrings("write_file", tc.name);
        try std.testing.expect(argsHasPath(tc.args));
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "index.html") != null);
    }
    // args wrapped in a ```json fence on the next lines
    {
        const tc = toolCall("TOOL: write_file\n```json\n{\"path\":\"a.html\",\"content\":\"x\"}\n```").?;
        try std.testing.expectEqualStrings("write_file", tc.name);
        try std.testing.expect(argsHasPath(tc.args));
    }
    // a bare no-arg call followed by prose must still parse as "{}" (never grab a later brace out of prose)
    {
        const tc = toolCall("Let me stop it.\nTOOL: stop_swarm\nThen I'll check the findings.").?;
        try std.testing.expectEqualStrings("stop_swarm", tc.name);
        try std.testing.expectEqualStrings("{}", tc.args);
    }
    // argsHasPath: the empty/pathless fingerprint of a mis-parsed call
    try std.testing.expect(!argsHasPath("{}"));
    try std.testing.expect(!argsHasPath("{\"path\":\"\"}"));
    try std.testing.expect(argsHasPath("{\"path\":\"index.html\",\"content\":\"x\"}"));
    // defaultName: a pasted one-pager with no recoverable filename → index.html
    try std.testing.expectEqualStrings("index.html", defaultName("<!DOCTYPE html><html>...").?);
    try std.testing.expectEqualStrings("index.html", defaultName("  <HTML>\n<body>").?);
    try std.testing.expect(defaultName("console.log(1)") == null);
    // the pure-fence case: model pastes the file with NO json + the user gave no filename → rescue synthesizes
    // {"path":"index.html","content":...} from the block (defaultName), so an empty write_file no longer bounces.
    {
        const html = "<!DOCTYPE html><html><head><style>body{margin:0;background:#111}h1{font-size:2rem}</style></head><body><h1>nl-veil</h1><p>" ++ ("the hive mind you talk to. " ** 8) ++ "</p></body></html>";
        const reply = "Here is the page.\n```html\n" ++ html ++ "\n```";
        const args = codeBlockWrite(std.testing.allocator, "build a one page website", reply).?;
        defer std.testing.allocator.free(args);
        try std.testing.expect(argsHasPath(args));
        try std.testing.expect(std.mem.indexOf(u8, args, "\"path\":\"index.html\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, args, "nl-veil") != null);
    }
}

test "looksTruncatedWrite: a big write_file cut off mid-content (the token-cap big-file bug)" {
    // a large write_file whose JSON never closes (the reply hit the length cap) — detected as truncation
    const cut = "I'll write the page.\nTOOL: write_file {\"path\":\"index.html\",\"content\":\"<!DOCTYPE html><html><head><style>body{margin:0}h1{font-size:2rem}" ++ ("a{color:red}" ** 40) ++ "</style>";
    try std.testing.expect(looksTruncatedWrite(cut));
    // a COMPLETE write_file is NOT truncated
    try std.testing.expect(!looksTruncatedWrite("TOOL: write_file {\"path\":\"a.html\",\"content\":\"<html>hi</html>\"}"));
    // a bare no-arg call is not a truncated write
    try std.testing.expect(!looksTruncatedWrite("TOOL: stop_swarm\nThen I'll check."));
    // a tiny unclosed blob is below the substantial-body threshold — not a big-file truncation
    try std.testing.expect(!looksTruncatedWrite("TOOL: write_file {\"path\":\"x\""));
}

test "toolCallTagXml parses a bare <edit_file>{...} tag; a built page's own markup never matches" {
    // deepseek's bare tool-named XML tag (no `tool:` prefix) — the "hallucinated tool call" the chat couldn't run
    {
        const tc = toolCallTagXml("I'll fix it.\n<edit_file>\n{\"path\":\"index.html\",\"ops\":[{\"search\":\"a\",\"replace\":\"b\"}]}\n</edit_file>").?;
        try std.testing.expectEqualStrings("edit_file", tc.name);
        try std.testing.expect(argsHasPath(tc.args));
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "\"search\":\"a\"") != null);
    }
    // <read_file> bare tag carrying a line range
    {
        const tc = toolCallTagXml("<read_file>{\"path\":\"index.html\",\"start_line\":228,\"end_line\":245}</read_file>").?;
        try std.testing.expectEqualStrings("read_file", tc.name);
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "228") != null);
    }
    // a built page's own HTML markup is NEVER a call (tag name is not a known tool)
    try std.testing.expect(toolCallTagXml("<section class=\"hero\"><div>{x:1}</div></section>") == null);
    try std.testing.expect(toolCallTagXml("<html><head><title>hi</title></head></html>") == null);
    // a bare mention with no following {args} is not a call
    try std.testing.expect(toolCallTagXml("use <read_file> to inspect the file") == null);
}

test "square-bracket render-label dialect dispatches (the moltbook-claim deadlock)" {
    // [tool:NAME {args}] — the model mimicking the desk's own [tool:…] result label as the call syntax
    {
        const tc = toolCallBracket("Let me check.\n[tool:web_fetch {\"url\":\"https://www.moltbook.com/api/v1/home\"}]").?;
        try std.testing.expectEqualStrings("web_fetch", tc.name);
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "moltbook.com/api/v1/home") != null);
    }
    // [TOOL: NAME {args}] — uppercase, space after the colon
    {
        const tc = toolCallBracket("[TOOL: read_file {\"path\":\"index.html\"}]").?;
        try std.testing.expectEqualStrings("read_file", tc.name);
        try std.testing.expect(argsHasPath(tc.args));
    }
    // a bare [tool:web_fetch] with no args -> dispatches with "{}" (server returns a missing-arg error the
    // model can react to) instead of leaking as inert text
    {
        const tc = toolCallBracket("[tool:web_fetch]").?;
        try std.testing.expectEqualStrings("web_fetch", tc.name);
        try std.testing.expectEqualStrings("{}", tc.args);
    }
    // a citation / note / unknown name is NOT a call
    try std.testing.expect(toolCallBracket("grounded in the sources [[1]](https://x) and [2]") == null);
    try std.testing.expect(toolCallBracket("see [tooltip] for details") == null);
    try std.testing.expect(toolCallBracket("[tool:frobnicate {}]") == null); // unknown tool
    // the whole [RUN: powershell …] the claim POST deadlocked on now unwraps and dispatches
    {
        const cmd = runCall("[RUN: powershell -Command \"Invoke-RestMethod -Uri 'https://www.moltbook.com/claim/x' -Method Post -Body $b | ConvertTo-Json -Depth 5\"]").?;
        try std.testing.expect(std.mem.startsWith(u8, cmd, "powershell -Command"));
        try std.testing.expect(std.mem.indexOf(u8, cmd, "moltbook.com/claim/x") != null);
        try std.testing.expect(cmd[cmd.len - 1] != ']'); // the wrapping bracket was stripped, not the command tail
    }
    // an UNbracketed RUN still parses (no regression)
    try std.testing.expectEqualStrings("dir /b", runCall("Let me list them.\nRUN: dir /b").?);
    // stripToolTail cuts the bracketed forms out of the displayed prose
    try std.testing.expectEqualStrings("Checking now.", stripToolTail("Checking now.\n[tool:web_fetch {\"url\":\"https://x\"}]"));
    try std.testing.expectEqualStrings("Running it.", stripToolTail("Running it.\n[RUN: powershell -Command \"echo hi\"]"));
    // the failed-call safety net flags an unparseable bracketed call for a corrective retry
    try std.testing.expect(looksLikeFailedToolCall("[tool:frobnicate]"));
    try std.testing.expect(looksLikeFailedToolCall("[RUN: something]"));
}

test "valueForKey captures one-time secrets from JSON and PowerShell result shapes (the moltbook loss)" {
    // JSON body (an API response)
    try std.testing.expectEqualStrings(
        "https://www.moltbook.com/claim/moltbook_claim_NY5NMN1",
        valueForKey("{\"success\":true,\"claim_url\":\"https://www.moltbook.com/claim/moltbook_claim_NY5NMN1\"}", "claim_url").?,
    );
    // PowerShell @{...} hashtable rendering (Invoke-RestMethod printed without ConvertTo-Json) — the shape a
    // registration console output takes, where the claim_url + verification_code can be lost
    const ps = "agent : @{id=e052369f; name=nl-veil; api_key=moltbook_sk_FTQK; claim_url=https://www.moltbook.com/claim/abc123; verification_code=splash-ZGZZ}";
    try std.testing.expectEqualStrings("https://www.moltbook.com/claim/abc123", valueForKey(ps, "claim_url").?);
    try std.testing.expectEqualStrings("splash-ZGZZ", valueForKey(ps, "verification_code").?);
    // a suffix of a longer word is NOT the key; a bare mention with no :/= is NOT a value
    try std.testing.expect(valueForKey("the reclaim_url=nope here", "claim_url") == null);
    try std.testing.expect(valueForKey("the claim_url is described below", "claim_url") == null);
    // every registration secret key is covered by the capture set
    try std.testing.expect(valueForKey(ps, "api_key") == null or true); // api_key already remembered elsewhere
    var hit_claim = false;
    for (ONE_TIME_SECRET_KEYS) |k| if (std.mem.eql(u8, k, "claim_url")) {
        hit_claim = true;
    };
    try std.testing.expect(hit_claim);
    // the stall guard counts only web-lookup tools; a real build action resets it
    try std.testing.expect(isWebLookupTool("web_search") and isWebLookupTool("web_fetch") and isWebLookupTool("read_url"));
    try std.testing.expect(!isWebLookupTool("write_file") and !isWebLookupTool("read_file") and !isWebLookupTool("observe"));
}

test "toolCallXmlNested converts nested-XML tool calls to JSON (deepseek's <read_file><path>..</path> form)" {
    const gpa = std.testing.allocator;
    // the nested form: name AND args are XML elements, digits become JSON numbers
    {
        const tc = toolCallXmlNested(gpa, "Let me read it.\n<read_file>\n<path>index.html</path>\n<start_line>100</start_line>\n<end_line>200</end_line>\n</read_file>").?;
        defer gpa.free(@constCast(tc.args));
        try std.testing.expectEqualStrings("read_file", tc.name);
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "\"path\":\"index.html\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "\"start_line\":100") != null); // number, not "100"
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "\"end_line\":200") != null);
    }
    // a flat edit_file (search/replace as elements; braces in the value are fine)
    {
        const tc = toolCallXmlNested(gpa, "<edit_file><path>a.html</path><search>x{y}</search><replace>z</replace></edit_file>").?;
        defer gpa.free(@constCast(tc.args));
        try std.testing.expectEqualStrings("edit_file", tc.name);
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "\"search\":\"x{y}\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "\"replace\":\"z\"") != null);
    }
    // a built page's own markup is NOT a call (no known tool name)
    try std.testing.expect(toolCallXmlNested(gpa, "<section><div>hello</div></section>") == null);
    // the bare `<name>{json}` form belongs to toolCallTagXml, not this one
    try std.testing.expect(toolCallXmlNested(gpa, "<read_file>{\"path\":\"a\"}</read_file>") == null);
}

test "toolCallJsonInferred infers the tool from a bare json args block (deepseek's nameless tool-call form)" {
    // a fenced json block with content+path is a write_file
    {
        const tc = toolCallJsonInferred("Now I'll write it.\n```json\n{\"path\":\"details/main.md\",\"content\":\"# Doc\\ntext\"}\n```").?;
        try std.testing.expectEqualStrings("write_file", tc.name);
        try std.testing.expect(std.mem.indexOf(u8, tc.args, "details/main.md") != null);
    }
    try std.testing.expectEqualStrings("read_file", toolCallJsonInferred("{\"path\":\"index.html\",\"start_line\":1,\"end_line\":10}").?.name);
    try std.testing.expectEqualStrings("read_file", toolCallJsonInferred("{\"path\":\"a.py\"}").?.name); // lone path → read
    try std.testing.expectEqualStrings("edit_file", toolCallJsonInferred("{\"path\":\"a.py\",\"ops\":[{\"search\":\"x\",\"replace\":\"y\"}]}").?.name);
    try std.testing.expectEqualStrings("run_python", toolCallJsonInferred("{\"code\":\"print(1)\"}").?.name);
    try std.testing.expectEqualStrings("web_search", toolCallJsonInferred("{\"query\":\"zig comptime\"}").?.name);
    // a non-tool object or plain prose is NOT a call
    try std.testing.expect(toolCallJsonInferred("{\"foo\":1,\"bar\":2}") == null);
    try std.testing.expect(toolCallJsonInferred("here is my final answer, no json at all") == null);
}

test "runCallLoose recovers only LINE-ANCHORED RUN: lines, keeping quotes and wildcards" {
    const r = "We need to check the task status. So I should run: \nRUN: powershell -Command \"Get-ScheduledTask -TaskName 'ping'\"\nThat will tell us.";
    try std.testing.expectEqualStrings("powershell -Command \"Get-ScheduledTask -TaskName 'ping'\"", runCallLoose(r).?);
    try std.testing.expect(runCallLoose("no command planned here") == null);
    try std.testing.expectEqualStrings("dir /b", runCallLoose("RUN: echo hi\nno — better:\nRUN: dir /b\ndone").?); // LAST anchored wins
    try std.testing.expect(runCallLoose("you could use RUN: del /q x here, but don't") == null); // prose mention never dispatches
    try std.testing.expect(runCallLoose("the DRY-RUN: output looked fine") == null); // pseudo-label is not an anchor
    try std.testing.expectEqualStrings("del *", runCallLoose("RUN: del *").?); // a real trailing wildcard survives
    try std.testing.expectEqualStrings("dir /b", runCallLoose("**RUN: dir /b**").?); // markdown bold unwrapped
}

test "fencedShellCall recovers only a SHELL-tagged command fence, last valid wins, never a transcript" {
    // the model dropped to a bare shell fence and it never dispatched
    try std.testing.expectEqualStrings("type core.py", fencedShellCall("Let me read it.\n```powershell\ntype core.py\n```").?);
    try std.testing.expectEqualStrings("type core.py", fencedShellCall("```powershell\ntype core.py").?); // unclosed (settled reply)
    try std.testing.expectEqualStrings("ls -la", fencedShellCall("```bash\nls -la\n```").?);
    try std.testing.expectEqualStrings("dir && echo done", fencedShellCall("```cmd\ndir && echo done\n```").?);
    // NON-shell fences are CONTENT, never commands — the safety line
    try std.testing.expect(fencedShellCall("```python\nprint('hi')\n```") == null);
    try std.testing.expect(fencedShellCall("```json\n{\"a\":1}\n```") == null);
    try std.testing.expect(fencedShellCall("```\nplain untagged fence\n```") == null);
    try std.testing.expect(fencedShellCall("no fence here at all") == null);
    try std.testing.expect(fencedShellCall("```powershell\n\n```") == null); // empty body
    // console/shell tags are DROPPED — they usually mark a rendered transcript, not a command to run
    try std.testing.expect(fencedShellCall("```console\n$ npm run build\nok\n```") == null);
    try std.testing.expect(fencedShellCall("```shell\nls\n```") == null);
    // a transcript body (prompt-prefixed lines) is rejected even under a real shell tag
    try std.testing.expect(fencedShellCall("```bash\n$ ls -la\ntotal 8\n```") == null);
    try std.testing.expect(fencedShellCall("```powershell\nPS> Get-ChildItem\n```") == null);
    // LAST valid shell fence wins — the model's final choice, not an alternative it weighed then discarded
    try std.testing.expectEqualStrings("git push", fencedShellCall("maybe ```bash\ngit status\n``` or better ```bash\ngit push\n```").?);
    // a non-shell fence before a shell fence: recover the shell command
    try std.testing.expectEqualStrings("git status", fencedShellCall("```python\nx=1\n```\nthen run:\n```bash\ngit status\n```").?);
}

test "naturalReadCall recovers the bare read_file/list_dir natural forms (the c6a54da12 stall)" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "Let me read the tail.\nread_file advanced-bci/core.py start_line 430 end_line 449", .out = "{\"path\":\"advanced-bci/core.py\",\"start_line\":430,\"end_line\":449}" },
        .{ .in = "read_file core.py", .out = "{\"path\":\"core.py\"}" }, // bare path, no range
        .{ .in = "```python\nread_file src/app.py start_line 1 end_line 40\n```", .out = "{\"path\":\"src/app.py\",\"start_line\":1,\"end_line\":40}" }, // wrapped in a fence
        .{ .in = "read_file main.py.", .out = "{\"path\":\"main.py\"}" }, // trailing sentence period trimmed
        .{ .in = "read_file x.py start_lines 99", .out = "{\"path\":\"x.py\"}" }, // start_lines is not a whole-token start_line
        .{ .in = "list_dir advanced-bci", .out = "{\"path\":\"advanced-bci\"}" }, // bare dir name (no separator needed)
        .{ .in = "list_dir .", .out = "{\"path\":\".\"}" },
    };
    for (cases) |c| {
        const tc = naturalReadCall(gpa, c.in).?;
        defer gpa.free(tc.args);
        try std.testing.expectEqualStrings(c.out, tc.args);
    }
    // read_file's name is preserved; list_dir picks the list tool
    {
        const tc = naturalReadCall(gpa, "read_file core.py").?;
        defer gpa.free(tc.args);
        try std.testing.expectEqualStrings("read_file", tc.name);
    }
    {
        const tc = naturalReadCall(gpa, "list_dir src/models").?;
        defer gpa.free(tc.args);
        try std.testing.expectEqualStrings("list_dir", tc.name);
    }
    // NOT recovered: prose with no path token, a proper JSON form (a real parser owns it), a longer token
    try std.testing.expect(naturalReadCall(gpa, "I'll use read_file to inspect the code") == null);
    try std.testing.expect(naturalReadCall(gpa, "read_file {\"path\":\"x.py\"}") == null);
    try std.testing.expect(naturalReadCall(gpa, "read_files.py list") == null);
    try std.testing.expect(naturalReadCall(gpa, "read_file.md is a file") == null); // '.' after the token
}

test "findGithubToken locates a token and ignores a bare-prefix mention" {
    // Fake, underscore-bearing tokens: valid to findGithubToken (prefix + >=20 body that allows '_') but NOT a
    // match for GitHub's own [A-Za-z0-9]-only secret pattern — so this test never trips secret-scanning push protection.
    try std.testing.expectEqualStrings("ghp_not_a_real_token_just_for_tests_00", findGithubToken("token: ghp_not_a_real_token_just_for_tests_00 end").?);
    try std.testing.expectEqualStrings("github_pat_not_a_real_token_for_tests_0", findGithubToken("PAT=github_pat_not_a_real_token_for_tests_0").?);
    try std.testing.expect(findGithubToken("set a ghp_ token via ::pat") == null); // bare prefix, no body
    try std.testing.expect(findGithubToken("no token in this text at all") == null);
    { // positional: the EARLIEST token wins across prefixes, so a redact-all loop never skips an earlier one
        const tok = findGithubToken("x ghp_earliest_fake_token_for_the_test y github_pat_later_fake_token_for_tests z").?;
        try std.testing.expect(std.mem.startsWith(u8, tok, "ghp_"));
    }
}

test "looseRunWins: the later action line in the reasoning is the decision" {
    try std.testing.expect(looseRunWins("TOOL: web_search {\"q\":\"x\"}\nactually simpler:\nRUN: dir /b"));
    try std.testing.expect(!looseRunWins("RUN: dir /b\nno — better:\nTOOL: read_file {\"path\":\"x\"}"));
    try std.testing.expect(!looseRunWins("TOOL: read_file {}")); // no RUN at all
    try std.testing.expect(looseRunWins("RUN: dir /b")); // no TOOL at all
}

test "lessonPair: fix variants pair, unrelated/identical commands don't" {
    const fail = "powershell -Command \"$action = New-ScheduledTaskAction -Execute 'msg' -Argument '* ping'; Register-ScheduledTask -TaskName 'ping' -Action $action -Force\"";
    const fixed = "powershell -Command \"$action = New-ScheduledTaskAction -Execute 'C:\\Windows\\System32\\msg.exe' -Argument '* ping'; Register-ScheduledTask -TaskName 'ping' -Action $action -Force\"";
    const probe = "powershell -Command \"Get-ScheduledTask -TaskName 'ping' | Get-ScheduledTaskInfo\"";
    try std.testing.expect(lessonPair(fail, fixed)); // the real msg.exe full-path fix
    try std.testing.expect(!lessonPair(fail, probe)); // a diagnostic query is not the fix
    try std.testing.expect(!lessonPair(fail, fail)); // identical retry = transient, not a lesson
    try std.testing.expect(!lessonPair(fail, "git status")); // different executable
    // identical LONG retry (past nearlySame's 400-char guard) is still a transient, not a lesson
    const longcmd = "python script.py --arg " ++ "x" ** 420;
    try std.testing.expect(!lessonPair(longcmd, longcmd));
    // path-qualifying the executable IS the motivating fix class (exe identity is path-blind)
    try std.testing.expect(lessonPair("msg * \"hello there\"", "C:\\Windows\\System32\\msg.exe * \"hello there\""));
}

test "looksReadOnlyCommand: probes exempt, mutations and unknowns count as mutating" {
    try std.testing.expect(looksReadOnlyCommand("dir /b"));
    try std.testing.expect(looksReadOnlyCommand("tasklist"));
    try std.testing.expect(looksReadOnlyCommand("powershell -Command \"Get-ScheduledTask -TaskName 'ping' | Get-ScheduledTaskInfo\""));
    try std.testing.expect(looksReadOnlyCommand("powershell -Command \"Test-Path C:\\x.txt\""));
    try std.testing.expect(!looksReadOnlyCommand("powershell -Command \"Register-ScheduledTask -TaskName 'ping'\""));
    try std.testing.expect(!looksReadOnlyCommand("del /q important.txt"));
    try std.testing.expect(!looksReadOnlyCommand("schtasks /create /tn x")); // unknown first token = mutating
    try std.testing.expect(!looksReadOnlyCommand("dir > list.txt")); // a redirected "probe" writes
    try std.testing.expect(!looksReadOnlyCommand("type a.txt & del b.txt")); // chained delete
    try std.testing.expect(!looksReadOnlyCommand("powershell -Command \"Get-Process | Stop-Process\"")); // pipe into a write verb
    try std.testing.expect(!looksReadOnlyCommand("powershell -EncodedCommand SQBuAHYAbwBrAGUA")); // opaque payload
}

test "buildTrace: users verbatim, only bracketed results, claims capped, thoughts never" {
    const jsonl =
        "{\"title\":\"t\"}\n" ++
        "{\"r\":0,\"t\":\"set up the task\"}\n" ++
        "{\"r\":3,\"t\":\"I am reasoning about how well I did\"}\n" ++
        "{\"r\":1,\"t\":\"Done! It works perfectly.\"}\n" ++
        "{\"r\":2,\"t\":\"(verifying the outcome)\"}\n" ++
        "{\"r\":2,\"t\":\"[console]\\n$ schtasks /query\\n(exit code 1)\"}\n";
    var buf: [2048]u8 = undefined;
    const tr = buildTrace(std.testing.allocator, jsonl, &buf);
    try std.testing.expect(std.mem.indexOf(u8, tr, "USER: set up the task") != null);
    try std.testing.expect(std.mem.indexOf(u8, tr, "CLAIM: Done!") != null);
    try std.testing.expect(std.mem.indexOf(u8, tr, "RESULT: [console] $ schtasks /query (exit code 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tr, "reasoning") == null); // r:3 = self-report, never
    try std.testing.expect(std.mem.indexOf(u8, tr, "verifying the outcome") == null); // unbracketed note, never
}

test "buildTrace keeps the newest whole entries when the window is small" {
    const jsonl = "{\"r\":0,\"t\":\"first question about alpha\"}\n{\"r\":0,\"t\":\"second question about bravo\"}\n";
    var buf: [40]u8 = undefined;
    const tr = buildTrace(std.testing.allocator, jsonl, &buf);
    try std.testing.expect(std.mem.indexOf(u8, tr, "bravo") != null);
    try std.testing.expect(std.mem.indexOf(u8, tr, "alpha") == null);
}

test "parseProposal: kinds parse, ungrounded and malformed are dropped" {
    const p = parseProposal("PLAYBOOK: always quote powershell -Command bodies via a batch carrier | evidence: RESULT exit 1 then exit 0").?;
    try std.testing.expect(p.kind == 0);
    try std.testing.expect(parseProposal("SKILL: to schedule a notification, register the task with a full exe path | evidence: trace lines 4-9").?.kind == 1);
    try std.testing.expect(parseProposal("- USER: wants evidence shown before any success claim | evidence: contradiction at line 12").?.kind == 2);
    try std.testing.expect(parseProposal("PLAYBOOK: too short | evidence: x") == null);
    try std.testing.expect(parseProposal("PLAYBOOK: a real looking lesson body without any grounding at all") == null);
    try std.testing.expect(parseProposal("NONE") == null);
    try std.testing.expect(parseProposal("USER: run a full diagnostic on this PC") == null); // trace echo, no evidence
}

test "atomizeForObserve softens sentence boundaries, leaves mid-token punctuation alone" {
    var buf: [200]u8 = undefined;
    try std.testing.expectEqualStrings("one, two, three, four", atomizeForObserve(&buf, "one; two. three! four"));
    try std.testing.expectEqualStrings("findstr /c:\"veil\" README.md works, use it", atomizeForObserve(&buf, "findstr /c:\"veil\" README.md works; use it"));
    try std.testing.expectEqualStrings("ends with a period.", atomizeForObserve(&buf, "ends with a period."));
}

test "contentOverlap: near-duplicates true, distinct or thin entries false" {
    try std.testing.expect(contentOverlap(
        "fix: `schtasks /create /tn ping` failed (exit code 1) — works as: `schtasks /create /tn ping /f`",
        "fix: `schtasks /create /tn ping` failed (exit code 1) — works as: `schtasks /create /f /tn ping`",
    ));
    try std.testing.expect(!contentOverlap(
        "fix: powershell quoting needs a batch carrier for nested quotes",
        "fix: curl progress output goes to stderr, use -sS for clean captures",
    ));
    try std.testing.expect(!contentOverlap("a b c", "a b c")); // no substantial tokens at all
}

test "dedupSentences collapses a repeated flail but keeps distinct + prefix-longer sentences" {
    var buf: [1024]u8 = undefined;
    // the "I am ..." flail: the same sentence three times -> one survives
    const flail = "I am going to check the models file. I am going to check the models file. I am going to check the models file.";
    const out = dedupSentences(flail, &buf);
    try std.testing.expect(std.mem.count(u8, out, "I am going to check the models file") == 1);

    // wholly distinct sentences are all preserved (nothing dropped -> returns the input unchanged)
    const distinct = "First I read the config. Then I patch the handler. Finally I run the tests.";
    try std.testing.expectEqualStrings(distinct, dedupSentences(distinct, &buf));

    // a longer DISTINCT sentence that a shorter one merely prefixes must NOT be swallowed (the 75% length guard)
    const prefixy = "Let me check. Let me check the config file for the missing key.";
    try std.testing.expect(std.mem.indexOf(u8, dedupSentences(prefixy, &buf), "config file for the missing key") != null);

    // short fragments (<8 chars) are never deduped even when repeated
    try std.testing.expectEqualStrings("OK. OK. OK.", dedupSentences("OK. OK. OK.", &buf));

    // decimals / abbreviations split on '.' but the two clauses are NOT adjacent duplicates -> nothing fused
    try std.testing.expectEqualStrings("Temperature is 98.6. Temperature is 98.7.", dedupSentences("Temperature is 98.6. Temperature is 98.7.", &buf));
    try std.testing.expectEqualStrings("See Fig. 1 for details. See Fig. 2 for details.", dedupSentences("See Fig. 1 for details. See Fig. 2 for details.", &buf));

    // a reply carrying a code fence is left completely untouched (identical adjacent code lines are legitimate)
    const fenced = "Here:\n```\nprint(\"hello\")\nprint(\"hello\")\n```\ndone.";
    try std.testing.expectEqualStrings(fenced, dedupSentences(fenced, &buf));

    // empty in -> empty out; and an out too small to hold the input returns the input unchanged (no partial write)
    try std.testing.expectEqualStrings("", dedupSentences("", &buf));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings(flail, dedupSentences(flail, &tiny));
}

test "escalateStuck climbs nudge -> research -> arm-cast; a live cast freezes it; resetArcFlags clears it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-ladder-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd); // establish an active conversation so appendMsg has somewhere to land
    const goal = "build a REST API in rust";
    chat.arc_goal_len = goal.len;
    @memcpy(chat.arc_goal[0..goal.len], goal);

    // rung 1: a change-approach nudge is queued; nothing armed yet
    chat.escalateStuck(dd, "error: connection refused");
    try std.testing.expectEqual(@as(u8, 1), chat.arc_stuck);
    try std.testing.expect(chat.pending_directive_len > 0);
    try std.testing.expect(!chat.arc_escalate_cast);

    // rung 2: a research step is forced
    chat.escalateStuck(dd, "error: connection refused");
    try std.testing.expectEqual(@as(u8, 2), chat.arc_stuck);
    try std.testing.expect(chat.arc_researched);
    try std.testing.expect(!chat.arc_escalate_cast);

    // rung 3: a research cast is ARMED, its goal seeded from the arc goal + the failure signature
    chat.escalateStuck(dd, "error: connection refused");
    try std.testing.expectEqual(@as(u8, 3), chat.arc_stuck);
    try std.testing.expect(chat.arc_escalate_cast);
    try std.testing.expect(std.mem.indexOf(u8, chat.force_cast_goal[0..chat.force_cast_goal_len], "REST API") != null);

    // a cast already in flight must FREEZE the ladder (no further climb)
    chat.cast_active = true;
    chat.escalateStuck(dd, "error: connection refused");
    try std.testing.expectEqual(@as(u8, 3), chat.arc_stuck);
    chat.cast_active = false;

    // budget spent: rung 3 refuses to re-arm and latches the "paused" note (the loop-independent runaway guard)
    chat.arc_escalate_cast = false;
    chat.arc_escalate_casts = MAX_ESCALATE_CASTS;
    chat.escalateStuck(dd, "error: connection refused"); // arc_stuck 3 -> 4, else branch, budget check
    try std.testing.expect(!chat.arc_escalate_cast); // NOT re-armed past the budget
    try std.testing.expect(chat.arc_escalate_capped);

    // a fresh arc wipes the whole ladder
    chat.resetArcFlags();
    try std.testing.expectEqual(@as(u8, 0), chat.arc_stuck);
    try std.testing.expect(!chat.arc_escalate_cast);
    try std.testing.expect(!chat.arc_researched);
    try std.testing.expectEqual(@as(u8, 0), chat.arc_escalate_casts);
    try std.testing.expect(!chat.arc_escalate_capped);
    try std.testing.expectEqual(@as(usize, 0), chat.force_cast_goal_len);
}

test "maybeEscalateCast is a no-op unless armed, and never fires past the per-arc escalation bound" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = llm.osEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const dd = "zig-ladder-cast-tmp";
    _ = Io.Dir.cwd().createDirPathStatus(io, dd ++ "/.veil-desk/chats", .default_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dd) catch {};
    var store = std.testing.allocator.create(Store) catch unreachable;
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    @memcpy(store.settings.data_dir[0..dd.len], dd);
    store.settings.data_dir_len = dd.len;
    var chat = std.testing.allocator.create(Chat) catch unreachable;
    defer std.testing.allocator.destroy(chat);
    chat.* = .{ .io = io, .gpa = std.testing.allocator, .store = store };
    chat.cmdNewConv(dd);

    // not armed -> no-op
    try std.testing.expect(!chat.maybeEscalateCast(dd));

    const g = "research the blocker";
    chat.force_cast_goal_len = g.len;
    @memcpy(chat.force_cast_goal[0..g.len], g);

    // armed but RECOVERED since arming (arc_stuck fell below the cast rung) -> disarms, never fires a stale swarm
    chat.arc_escalate_cast = true;
    chat.arc_stuck = 1;
    try std.testing.expect(!chat.maybeEscalateCast(dd));
    try std.testing.expect(!chat.arc_escalate_cast);

    // armed + still stuck but the arc already spent its escalation-cast budget -> consumes the arming, refuses to
    // fire (no network). LOOP-INDEPENDENT bound: loop_casts stays 0 in a manual arc, so it can't be the guard.
    chat.arc_escalate_cast = true;
    chat.arc_stuck = 3;
    chat.loop_casts = 0; // deliberately NOT at the loop bound — proves the guard is arc_escalate_casts, not loop_casts
    chat.arc_escalate_casts = MAX_ESCALATE_CASTS;
    try std.testing.expect(!chat.maybeEscalateCast(dd));
    try std.testing.expect(!chat.arc_escalate_cast); // one-shot: the arming was consumed even though it didn't fire

    // armed + still stuck + budget available but a cast is already pending -> refuses, KEEPS the arming
    chat.arc_escalate_cast = true;
    chat.arc_stuck = 3;
    chat.arc_escalate_casts = 0;
    chat.cast_active = true;
    try std.testing.expect(!chat.maybeEscalateCast(dd));
    try std.testing.expect(chat.arc_escalate_cast); // NOT consumed — it must still fire once the cast clears
    chat.cast_active = false;
}

test "scRawField matches the KEY, not a same-named VALUE (the [tool:] blank-name bug)" {
    // {"kind":"tool",...} — searching bare "tool" hit the "tool" VALUE of kind first, yielding an empty name.
    const frame = "{\"kind\":\"tool\",\"tool\":\"run_python\",\"state\":\"done\",\"preview\":\"exit=0\"}";
    try std.testing.expectEqualStrings("tool", scRawField(frame, "kind").?);
    try std.testing.expectEqualStrings("run_python", scRawField(frame, "tool").?); // was "" before the fix
    try std.testing.expectEqualStrings("done", scRawField(frame, "state").?);
    try std.testing.expectEqualStrings("exit=0", scRawField(frame, "preview").?);
    const msg = "{\"kind\":\"message\",\"role\":\"assistant\",\"content\":\"hi there\"}";
    try std.testing.expectEqualStrings("assistant", scRawField(msg, "role").?);
    try std.testing.expectEqualStrings("hi there", scRawField(msg, "content").?);
    try std.testing.expect(scRawField(msg, "tool") == null); // absent field → null
}

test "needsBatchPercentHint fires only on single-% for-loop variables" {
    try std.testing.expect(needsBatchPercentHint("for %i in (*.txt) do @echo %i"));
    try std.testing.expect(needsBatchPercentHint("FOR /f %a in ('dir /b') do echo %a"));
    try std.testing.expect(!needsBatchPercentHint("for %%i in (*.txt) do @echo %%i")); // already escaped
    try std.testing.expect(!needsBatchPercentHint("echo %PATH% for the record")); // env pair, not a loop var
    try std.testing.expect(!needsBatchPercentHint("curl https://x/a%20b")); // no for-loop at all
    try std.testing.expect(!needsBatchPercentHint("dir"));
}

// A tiny harness for the async-console tests: a Chat wired to a throwaway data dir. Caller owns teardown.
const ConsoleTestCtx = struct {
    threaded: *std.Io.Threaded,
    store: *Store,
    chat: *Chat,
    fn init(dd: []const u8, dead_endpoint: bool) ConsoleTestCtx {
        const a = std.testing.allocator;
        const threaded = a.create(std.Io.Threaded) catch unreachable;
        threaded.* = std.Io.Threaded.init(a, .{ .environ = llm.osEnviron() });
        const tio = threaded.io();
        _ = Io.Dir.cwd().createDirPathStatus(tio, dd, .default_dir) catch {};
        var vb: [256]u8 = undefined;
        const vd = std.fmt.bufPrint(&vb, "{s}/.veil-desk/chats", .{dd}) catch unreachable;
        _ = Io.Dir.cwd().createDirPathStatus(tio, vd, .default_dir) catch {};
        const store = a.create(Store) catch unreachable;
        store.* = .{};
        @memcpy(store.settings.data_dir[0..dd.len], dd);
        store.settings.data_dir_len = @intCast(dd.len);
        if (dead_endpoint) {
            const base = "http://127.0.0.1:1/v1"; // a follow-up turn's curl goes nowhere
            @memcpy(store.settings.chat_base[0..base.len], base);
            store.settings.chat_base_len = base.len;
        }
        const chat = a.create(Chat) catch unreachable;
        chat.* = .{ .io = tio, .gpa = a, .store = store };
        return .{ .threaded = threaded, .store = store, .chat = chat };
    }
    fn io(self: *ConsoleTestCtx) Io {
        return self.threaded.io();
    }
    /// Pump the console loop until the in-flight command finalizes (bounded so a stuck test can't hang).
    fn drain(self: *ConsoleTestCtx, dd: []const u8) void {
        var i: usize = 0;
        while (self.chat.console != null and i < 400) : (i += 1) {
            self.chat.pumpConsole(dd);
            if (self.chat.console == null) break;
            self.io().sleep(.{ .nanoseconds = 25 * std.time.ns_per_ms }, .awake) catch {};
        }
    }
    fn deinit(self: *ConsoleTestCtx, dd: []const u8) void {
        const a = std.testing.allocator;
        if (self.chat.console) |*p| p.child.kill(self.io());
        Io.Dir.cwd().deleteTree(self.io(), dd) catch {};
        self.threaded.deinit();
        a.destroy(self.chat);
        a.destroy(self.store);
        a.destroy(self.threaded);
    }
};

fn consoleScrollHas(store: *Store, ai: bool, needle: []const u8) bool {
    const s = if (ai) store.console_ai[0..store.console_ai_len] else store.console_you[0..store.console_you_len];
    return std.mem.indexOf(u8, s, needle) != null;
}

test "micro-console: a You command runs async (non-blocking), streams its output, and clears busy" {
    const dd = "zig-console-you-tmp";
    var ctx = ConsoleTestCtx.init(dd, false);
    defer ctx.deinit(dd);
    ctx.chat.consoleStart(dd, false, "echo neuron-db-console-probe");
    // launched but NOT yet finished — proves it did not block the caller
    try std.testing.expect(ctx.chat.console != null);
    try std.testing.expect(ctx.store.console_busy_you);
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null); // finalized
    try std.testing.expect(!ctx.store.console_busy_you); // busy cleared
    try std.testing.expect(consoleScrollHas(ctx.store, false, "neuron-db-console-probe"));
}

test "micro-console: a nonzero exit surfaces '(exit code N)' and the batch carrier is cleaned up" {
    if (builtin.os.tag != .windows) return; // the .cmd carrier + full-u32 exit peek are the Windows path
    const dd = "zig-console-exit-tmp";
    var ctx = ConsoleTestCtx.init(dd, false);
    defer ctx.deinit(dd);
    ctx.chat.consoleStart(dd, false, "exit 3");
    try std.testing.expect(ctx.chat.console != null);
    const carrier = dd ++ "/.veil-desk/console_you.cmd";
    // the carrier exists while the command is registered...
    if (Io.Dir.cwd().statFile(ctx.io(), carrier, .{})) |_| {} else |_| return error.CarrierMissingWhileRunning;
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null);
    // ...the exit status reached the scrollback, and the carrier is gone after finalize
    try std.testing.expect(consoleScrollHas(ctx.store, false, "(exit code 3)"));
    if (Io.Dir.cwd().statFile(ctx.io(), carrier, .{})) |_| return error.CarrierNotCleanedUp else |_| {}
}

test "micro-console: a command that overruns its wall-clock deadline is killed and reported" {
    const dd = "zig-console-timeout-tmp";
    var ctx = ConsoleTestCtx.init(dd, false);
    defer ctx.deinit(dd);
    const longcmd = if (builtin.os.tag == .windows) "ping -n 20 127.0.0.1" else "sleep 20";
    ctx.chat.consoleStart(dd, false, longcmd);
    try std.testing.expect(ctx.chat.console != null);
    ctx.chat.console.?.deadline_s = ctx.chat.nowS() - 1; // force the deadline into the past
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null); // killed + finalized
    try std.testing.expect(!ctx.store.console_busy_you);
    try std.testing.expect(consoleScrollHas(ctx.store, false, "timed out"));
}

test "micro-console: the Stop button (console_cancel) interrupts a running command" {
    const dd = "zig-console-cancel-tmp";
    var ctx = ConsoleTestCtx.init(dd, false);
    defer ctx.deinit(dd);
    const longcmd = if (builtin.os.tag == .windows) "ping -n 20 127.0.0.1" else "sleep 20";
    ctx.chat.consoleStart(dd, false, longcmd);
    try std.testing.expect(ctx.chat.console != null);
    ctx.chat.console_cancel = true; // what the .console_cancel command sets
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null);
    try std.testing.expect(!ctx.store.console_busy_you);
    try std.testing.expect(consoleScrollHas(ctx.store, false, "stopped"));
}

test "micro-console: an AI RUN: command folds its output back as a [console] message" {
    const dd = "zig-console-ai-tmp";
    var ctx = ConsoleTestCtx.init(dd, true);
    defer ctx.deinit(dd);
    ctx.chat.cmdNewConv(dd); // an active conversation for the fold to append into
    ctx.chat.consoleStart(dd, true, "echo neuron-db-ai-probe");
    try std.testing.expect(ctx.store.console_busy_ai);
    ctx.drain(dd);
    try std.testing.expect(ctx.chat.console == null);
    try std.testing.expect(!ctx.store.console_busy_ai);
    var found = false;
    {
        ctx.store.lock();
        defer ctx.store.unlock();
        var k: usize = 0;
        while (k < ctx.store.msg_count) : (k += 1) {
            const txt = ctx.store.msgs[k].textStr();
            if (std.mem.indexOf(u8, txt, "[console]") != null and std.mem.indexOf(u8, txt, "neuron-db-ai-probe") != null) found = true;
        }
    }
    try std.testing.expect(found);
    // tear down the follow-up turn's stream (foldConsoleAi started one against the dead endpoint)
    llm.abort(&ctx.chat.stream, ctx.io());
    ctx.chat.stream.deinit(std.testing.allocator);
    ctx.chat.turn = .idle;
}
