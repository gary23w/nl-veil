//! chat.zig — the chat worker thread: the third thread beside the UI and the poller, same discipline
//! (owns its own std.Io, talks to the UI only through the Store). It runs the Chat tab's brain:
//!   - model turns: streams /chat/completions through llm.zig, deltas land in Store.stream_text
//!   - swarm casting: a reply whose first line is "CAST: <goal>" fires the EXISTING casting mechanism —
//!     POST /api/v1/swarms via netcli (the same door the Deploy tab uses) — then this thread WATCHES the
//!     run's events.jsonl (scan.tailEvents, filesystem-first) for the right-hand activity pane, and when
//!     the swarm stops it folds the findings back into the conversation and asks the model to answer.
//!   - persistence: conversations are JSONL files under <data>/.veil-desk/chats/, chat settings JSON at
//!     <data>/.veil-desk/settings.json, the API key sealed via secrets.zig. All chat-side io lives here.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const store_mod = @import("store.zig");
const scan = @import("scan.zig");
const netcli = @import("netcli.zig");
const llm = @import("llm.zig");
const secrets = @import("secrets.zig");
const catalog = @import("catalog.zig");
const log = @import("log.zig");
const neurondb = @import("neuron.zig");

const Store = store_mod.Store;

const SYSTEM_PROMPT =
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
    "Example — a real build:  CAST: build a complete Flask REST API with auth, 5 endpoints, tests, and a README\\n" ++
    "MINDS 8\\nLONG\\nMINUTES 30 .  Match the size + posture to the target; a cast is you loading a swarm and " ++
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
    "\n" ++
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
    "and tell me what it found' -> TOOL: stop_swarm {} , then TOOL: swarm_findings {}). Use CAST for open-ended " ++
    "research or building. For a brand-new web question, a single web_search TOOL is often faster than a cast.\n" ++
    "\n" ++
    "BUILD — you have your own persistent build workdir on this machine (the SAME file tools a hive mind uses). " ++
    "When the user asks you to build/create/fix code or files, WRITE them to disk — don't just paste the whole " ++
    "file into the chat. Use the TOOL: protocol (one tool per reply):\n" ++
    "- write_file {\"path\":\"app.py\",\"content\":\"...\"}  — write/overwrite a file (relative path, in your workdir).\n" ++
    "- edit_file {\"path\":\"app.py\",\"ops\":[{\"search\":\"old\",\"replace\":\"new\"}]}  — patch an existing file in place.\n" ++
    "- read_file {\"path\":\"app.py\"}  — read a file back before you change it.\n" ++
    "- list_dir {\"path\":\".\"}  — see what's already in the workdir.\n" ++
    "- run_tests {}  — run the project's tests (pytest / test_*.py) and get pass/fail.\n" ++
    "- run_python {\"code\":\"...\"}  — run a short Python script in the workdir.\n" ++
    "- delete_file {\"path\":\"...\"}  — remove a file you created.\n" ++
    "KNOW YOUR LIMITS: your reply has a length cap, so a large file will get CUT OFF if you write it all at once. " ++
    "For anything big, either write it across MULTIPLE files (module per file), or write the first part with " ++
    "write_file then extend it with edit_file — never send one giant file that truncates. After writing code, " ++
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
    "cd, copy, del, findstr, python), NOT unix ones (ls, cat, pwd, rm). For anything with nested quotes or a " ++
    "multi-line body (PowerShell here-strings, a script), WRITE A FILE with write_file first and then RUN it " ++
    "(e.g. write reminder.ps1, then RUN: powershell -ExecutionPolicy Bypass -File reminder.ps1) — do NOT try to " ++
    "cram it into one quoted command line, which mangles. If the user denies a command, don't retry it blindly — " ++
    "ask or take another approach. Never run something irreversible (deleting data, killing processes) unasked. " ++
    "For pure web/research questions use web_search or CAST, not RUN.\n" ++
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

// The neuron-db scope for the chat's DURABLE cross-conversation memory (keys/logins/preferences/facts). Distinct
// from the per-conversation convScope: memories saved in one chat are recallable from every chat. See storeMemory.
const MEMORY_SCOPE = "veil-memory";

const CAST_MINUTES: u32 = 8; // v1 fixed budget; the engine self-crunches to fit
const MAX_TOKENS: u32 = 4096; // was 2048 — code answers (a full Flask app) were truncated mid-file every turn

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
    "knowledge — only durable facts about THIS user. If there is nothing new or changed to store, output exactly: NONE";

// Bound the model→tool→model loop so a confused local model can't spin forever on tool calls. A real build
// legitimately reads + writes + tests many files in a row, so this must be generous (5 gave up mid-build).
const MAX_TOOL_ITERS: u32 = 20;

// Prompt-loop (full-auto mode): after a turn settles, the AI writes the NEXT user message itself and sends it,
// continuing the conversation toward the goal until it emits DONE or hits the iteration cap. LOOP_MAX_ITERS is
// the verifiable stop condition that prevents an endless/costly loop.
const LOOP_MAX_ITERS: u32 = 12;
const LOOP_SYSTEM =
    "You are the autonomous DRIVER of this conversation. The user has enabled full-auto mode: rather than typing " ++
    "each message themselves, YOU write the next message on their behalf to keep making progress toward the goal " ++
    "of the thread (the goal is set by the first user message and everything since).\n" ++
    "Read the whole conversation, judge what has been accomplished and what is still missing, then output ONLY the " ++
    "next message to send — a single concrete instruction, question, or refinement that advances the goal. Write it " ++
    "as the user would (first person, imperative), with NO preamble, NO quotes, NO explanation — just the message text.\n" ++
    "Do NOT answer it yourself and do NOT include a TOOL:/CAST:/RUN: line — you are composing the user's next prompt, " ++
    "not the assistant's reply. Keep it to one or two sentences.\n" ++
    "If this is a BUILD/code task, do not settle for 'it looks done' — the next step should write/extend the real " ++
    "files and then run_tests (or run_python) to VERIFY; only treat the goal as achieved once it actually works.\n" ++
    "When the goal is fully achieved (the assistant has delivered what was asked, verified where possible, and no " ++
    "further step would add value), output EXACTLY the single word: DONE";

// Recursive-thought (reflect) loop: ITERATIVE self-critique — keep re-reviewing the draft while each pass still
// meaningfully changes it (that's how a careful reasoner converges: critique → fix → re-critique → … until it's
// stable), capped so it always terminates. ONLY for substantive answers to substantive requests, never chit-chat
// (a "hello" must not recurse). REFLECT_MIN_ANSWER is the answer length below which an answer is trivial + skips.
const REFLECT_PASSES: u8 = 1; // >0 enables the loop; the depth is bounded by REFLECT_MAX_PASSES
const REFLECT_MAX_PASSES: u8 = 3; // hard ceiling on self-check iterations (each is one model call)
const REFLECT_MIN_ANSWER: usize = 500;

// Concurrent Veil: while a cast runs, the primary Veil ALSO works the SAME goal, in parallel, directly inside
// the hive's own shared build dir — it JOINS the swarm rather than building a rival copy. A separate isolated
// workdir + a post-hoc AI "pick the better one or merge them" pass never worked: two independently-evolving
// trees are two version histories, and reconciling divergent builds is exactly the merge problem the swarm's
// OWN micro-VCS (vcs.zig, see chat_tools.zig's vcs_enabled) already exists to solve — running a SECOND ad-hoc
// merge on top of it just breaks builds instead of fixing them. So there is no separate veil dir and no compare
// step: the veil's tool calls target the identical dir the hive is building in, and the swarm's own concurrent-
// edit safety is what reconciles the two streams of edits. Costs extra model calls per cast (the veil's own
// attempt), so it's a single flag to disable if a run should be cast-only.
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
fn procExited(child: *std.process.Child) bool {
    const id = child.id orelse return true; // already reaped / killed
    if (builtin.os.tag == .windows) {
        var code: u32 = 0;
        if (winproc.GetExitCodeProcess(id, &code) == 0) return true; // handle unusable → treat as done
        return code != winproc.STILL_ACTIVE;
    } else {
        var status: c_int = undefined;
        const r = std.c.waitpid(id, &status, 1); // 1 = WNOHANG
        if (r == 0) return false; // still running
        child.id = null; // reaped here — don't Child.wait again
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
    // CONVERSATION EPOCH — the cancellation barrier. Bumped whenever the user moves the conversation forward
    // (send / new conv / switch conv / Stop). Deferred continuations (cast collect, veil parallel work) capture
    // it when SCHEDULED and refuse to mutate the chat if it has moved — a finished cast then leaves one passive
    // note instead of hijacking a model turn to post-process an old goal into the live conversation.
    conv_epoch: u64 = 0,
    cast_epoch: u64 = 0, // conv_epoch when the active cast (and its concurrent-veil work) was scheduled
    turn_epoch: u64 = 0, // conv_epoch when the current model turn started (settle chains check it)

    // active cast bookkeeping (one at a time)
    cast_active: bool = false,
    cast_hex: [32]u8 = [_]u8{0} ** 32,
    cast_hex_len: usize = 0,
    cast_rel: [96]u8 = [_]u8{0} ** 96, // resolved run path relative to data dir
    cast_rel_len: usize = 0,
    cast_conv: [40]u8 = [_]u8{0} ** 40, // the conv this cast was fired for — its run dir is _chat/builds/<conv>
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

    // scratch (thread-owned)
    ev_scratch: [store_mod.CAST_TAIL]scan.Ev = undefined,
    sw_scratch: [scan.MAX_SWARMS]scan.SwarmSummary = undefined,
    file_scratch: [scan.MAX_FILES]scan.FileRow = undefined,
    mem_scratch: [12288]u8 = undefined, // durable-memory directive stripping (REMEMBER:/FORGET: removed from the answer)
    mem_saved_n: usize = 0, // memories stored on the turn being finalized (set by processMemory, read by appendVeil)
    mem_forgot_n: usize = 0, //   "" forgotten — lets appendVeil confirm a directives-only reply that strips to empty
    internal_turn: bool = false, // the current turn's `last_user` is a MACHINE directive (merge/nudge), not a real
    //                              user message — so it must NOT trigger memory consolidation. Cleared in cmdSend.

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
        self.fetchOllamaModels();

        var tick: u32 = 0;
        while (!self.stop.load(.monotonic)) {
            var db: [512]u8 = undefined;
            const dd = self.dataDir(&db);
            self.drainCommands(dd);
            self.pumpStream(dd);
            self.pumpConsole(dd); // poll any in-flight micro-console command (never blocks the loop)
            // ~1Hz auto-loop backstop: a .loop_kick that lands the instant a turn is finishing hits maybeLoop's
            // `turn != .idle` guard and is lost — the settle-point call can't recover it if the turn had already
            // settled. Re-checking every idle tick self-heals that gap (maybeLoop no-ops unless loop is on AND the
            // chat is genuinely idle with something to continue from, so this can't run away or double-fire).
            if (tick % 10 == 5) self.maybeLoop(dd);
            if (tick % 10 == 0) self.watchCast(dd); // ~1Hz beside the 10Hz stream pump
            if (tick % 10 == 7) self.maybeVeilWork(dd); // concurrent veil: drive the parallel attempt (offset slot)
            if (tick % 10 == 3) self.maybeFinishAfterVeil(dd); // concurrent veil: compose the answer once cast + veil are both done
            if (tick % 20 == 11) self.refreshChatFiles(dd); // ~2s: publish this chat's build files for the Files tab
            if (tick % 50 == 0) self.refreshConvs(dd, false); // ~5s: pick up external changes
            if (tick % 300 == 299) self.fetchOllamaModels();
            tick +%= 1;
            self.io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
        }
        llm.abort(&self.stream, self.io);
        self.stream.deinit(self.gpa);
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

    /// Record one completed turn's performance into the Metrics ring (chars are a ~4x proxy for tokens; the
    /// tok/s is measured over the GENERATION window = total minus first-byte, so queue/prefill latency doesn't
    /// deflate the rate). Called once per turn, at the settle point and the error path.
    fn recordMetric(self: *Chat, kind: Turn, ok: bool, out_chars: usize) void {
        const total_ms: u32 = @intCast(@max(0, self.nowMs() - self.turn_start_ms));
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
        const url = std.fmt.allocPrint(self.gpa, "{s}/api/tags", .{root}) catch return;
        defer self.gpa.free(url);
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "curl", "-sS", "--max-time", "5", url },
            .stdout_limit = .limited(256 << 10),
        }) catch return;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return;
        // parse the "name":"..." fields (one per installed model)
        self.store.lock();
        defer self.store.unlock();
        self.store.ollama_model_count = 0;
        var i: usize = 0;
        const needle = "\"name\":\"";
        while (std.mem.indexOfPos(u8, res.stdout, i, needle)) |at| {
            if (self.store.ollama_model_count >= store_mod.MAX_OLLAMA_MODELS) break;
            const from = at + needle.len;
            const end = std.mem.indexOfScalarPos(u8, res.stdout, from, '"') orelse break;
            const name = res.stdout[from..end];
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
        const url = std.fmt.allocPrint(self.gpa, "{s}/api/ps", .{root}) catch return 0;
        defer self.gpa.free(url);
        const res = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "curl", "-sS", "--max-time", "4", url },
            .stdout_limit = .limited(64 << 10),
        }) catch return 0;
        defer self.gpa.free(res.stdout);
        defer self.gpa.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return 0;
        return parseMaxCtx(res.stdout);
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
        const p = std.fmt.bufPrint(&pbuf, "{s}/.veil-desk/chats", .{dd}) catch return;
        _ = Io.Dir.cwd().createDirPathStatus(self.io, p, .default_dir) catch {};
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
            self.store.chat_status_len = 0;
        }
    }

    // ------------------------------------------------------------------------------ commands

    fn drainCommands(self: *Chat, dd: []const u8) void {
        while (self.store.popChatCmd()) |c| {
            switch (c.kind) {
                .none => {},
                .send => self.cmdSend(dd, c.textStr()),
                // Guard a chat switch/new-chat while ANY work is pending (a streaming reply, a running cast, or an
                // AI console command): switching would repoint conv_active and the settling output would land in —
                // and overwrite — the wrong chat (the "old chat bleeds into the new chat" bug). Mirror the
                // cmdDeleteConv precedent: refuse with a clear notice instead of corrupting state.
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
                .loop_kick => self.maybeLoop(dd), // user just enabled auto-loop while idle → start it now
                .stop_turn => self.stopTurn(dd), // Stop button by the input: abort the in-flight turn + halt auto-loop
                .chat_open_file => self.cmdChatOpenFile(dd, c.textStr()), // Files tab: load a file into the viewer
                .chat_open_folder => self.cmdChatOpenFolder(dd), // Files tab: open this chat's build folder in the OS
                .forget_mem => self.forgetMemory(dd, c.textStr()), // Memory tab: delete-button drops one saved memory
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

    /// Is there work in flight that a chat switch/new-chat would corrupt (a live model turn, a running cast, or an
    /// AI console command)? Any settling output resolves its target conversation from conv_active at write time, so
    /// repointing it mid-flight misroutes the reply — refuse the switch while this is true.
    fn busyForSwitch(self: *Chat) bool {
        // Also block during the WHOLE concurrent-veil window: castFinished flips cast_active false while the merge
        // is still pending (cast_awaiting_merge) and the veil turn may still be running (veil_work_active). A switch
        // in those idle gaps would repoint conv_active and the settling veil/merge appends would overwrite the
        // newly-selected chat. Mirror maybeLoop's guard.
        return self.turn != .idle or self.cast_active or self.consoleAiBusy() or self.veil_work_active or self.cast_awaiting_veil;
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
        var nb: [480]u8 = undefined;
        const note = std.fmt.bufPrint(&nb, "[build] working directory: {s} — the console (You + Veil tabs) is cd'd here, so you can inspect and run the files.", .{rel}) catch "[build] working directory set";
        self.appendMsg(dd, .cast_note, note);
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
        // Windows: run through cmd /c so the user gets the shell they expect (dir, echo, git, python, …).
        const argv = if (builtin.os.tag == .windows)
            [_][]const u8{ "cmd", "/c", trimmed }
        else
            [_][]const u8{ "sh", "-c", trimmed };
        const child = std.process.spawn(self.io, .{
            .argv = &argv,
            .cwd = if (cwd_dir) |d| .{ .dir = d } else .inherit,
            .stdin = .ignore,
            .stdout = .{ .file = of },
            .stderr = .{ .file = ef },
            .create_no_window = true, // don't flash a console window per command on Windows
        }) catch {
            of.close(self.io);
            ef.close(self.io);
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
        if (procExited(&p.child)) {
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
                if (p.child.wait(self.io)) |_| {} else |_| {}
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

        // Status note for the non-clean exits — the required "(command timed out after Ns)" lives here.
        var nb: [64]u8 = undefined;
        const note: []const u8 = switch (outcome) {
            .running, .exited => "",
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
            var cmdb: [1024]u8 = undefined;
            const cl = @min(p.cmd_len, cmdb.len);
            @memcpy(cmdb[0..cl], p.cmd[0..cl]);
            var rb: [6144]u8 = undefined;
            const result = composeConsoleResult(&rb, out_slice, err_slice, note);
            self.console = null;
            self.console_cancel = false;
            self.foldConsoleAi(dd, cmdb[0..cl], result);
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

    pub fn cmdSend(self: *Chat, dd: []const u8, text: []const u8) void {
        if (text.len == 0) return;
        if (self.turn != .idle or self.consoleAiBusy()) {
            // Don't silently drop the message (the "new chat fails to deploy / nothing happens" report) — tell the
            // user why. Sending DURING a cast is fine (cast_active isn't blocked here); only a live turn/console is.
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
        self.internal_turn = false; // this is a REAL user message → its turn may consolidate memory
        self.conv_epoch += 1; // the conversation moved forward — pending continuations for older goals stand down
        self.tool_iters = 0; // fresh tool budget for this user turn
        self.loop_iter = 0; // a manual message resets the auto-loop budget (this is the new goal/steer)
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
        self.abort_turn.store(false, .monotonic); // a new user message clears any pending Stop from the last turn
        self.appendMsg(dd, .user, text);
        self.startTurn(dd, .user);
    }

    pub fn cmdNewConv(self: *Chat, dd: []const u8) void {
        var idb: [32]u8 = undefined;
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
        self.loadMsgs(dd, id);
    }

    fn cmdRenameConv(self: *Chat, dd: []const u8, id: []const u8, title: []const u8) void {
        if (id.len == 0 or title.len == 0) return;
        self.rewriteTitle(dd, id, title);
        self.refreshConvs(dd, true);
    }

    fn renameActive(self: *Chat, dd: []const u8, title: []const u8) void {
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        {
            self.store.lock();
            idn = self.store.conv_active_len;
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
            var nid: [32]u8 = undefined;
            var nn: usize = 0;
            {
                self.store.lock();
                defer self.store.unlock();
                if (self.store.conv_count > 0) {
                    nn = self.store.convs[0].id_len;
                    @memcpy(nid[0..nn], self.store.convs[0].id[0..nn]);
                }
            }
            if (nn > 0) self.cmdSelectConv(dd, nid[0..nn]);
        }
    }

    // ---------------------------------------------------------------------- chat Files tab (this chat's own dir)

    /// The data-relative build dir for THIS conversation ("u{uid}/_chat/builds/{conv}"); "" if no active conv.
    /// The uid is taken from the leading "uN" segment of build_dir (set when a build tool ran) — defaults to u1,
    /// which is the desktop's admin user on localhost.
    fn chatBuildRel(self: *Chat, buf: []u8) []const u8 {
        var cb: [40]u8 = undefined;
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
        if (ok) self.store.pushNotif("Key saved", "stored in the OS-protected local store", 1) else self.store.pushNotif("Key NOT saved", "could not write the secure store", 2);
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
        }
        var jb: std.ArrayListUnmanaged(u8) = .empty;
        defer jb.deinit(self.gpa);
        jb.appendSlice(self.gpa, "{\"kind\":") catch return;
        jb.print(self.gpa, "{d},\"byok\":{d},\"theme\":{d},\"base\":\"", .{ kind, byok, theme }) catch return;
        escJson(&jb, self.gpa, base[0..base_n]);
        jb.appendSlice(self.gpa, "\",\"model\":\"") catch return;
        escJson(&jb, self.gpa, model[0..model_n]);
        jb.appendSlice(self.gpa, "\",\"cf_account\":\"") catch return;
        escJson(&jb, self.gpa, cfa[0..cfa_n]);
        jb.print(self.gpa, "\",\"left\":{},\"right\":{},\"shell_allow\":{}}}", .{ lopen, ropen, shell_allow }) catch return;
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/settings.json", .{dd}) catch return;
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = jb.items }) catch {
            log.warn("chat: could not persist settings", .{});
        };
    }

    fn loadSettings(self: *Chat, dd: []const u8) void {
        var pb: [700]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/.veil-desk/settings.json", .{dd}) catch return;
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(8 << 10)) catch return;
        defer self.gpa.free(data);
        self.store.lock();
        defer self.store.unlock();
        const s = &self.store.settings;
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
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(2 << 20)) catch return;
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
            var m: store_mod.ChatMsg = .{ .role = switch (r) {
                1 => .veil,
                2 => .cast_note,
                3 => .thought, // must be explicit: the .user fallback would re-feed a trace to the model as a user turn
                else => .user,
            } };
            const tn = @min(t.len, m.text.len);
            @memcpy(m.text[0..tn], t[0..tn]);
            m.text_len = @intCast(tn);
            self.store.msgs[self.store.msg_count] = m;
            self.store.msg_count += 1;
        }
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
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            idn = self.store.conv_active_len;
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            if (self.store.msg_count >= store_mod.MAX_CHAT_MSGS) {
                std.mem.copyForwards(store_mod.ChatMsg, self.store.msgs[0 .. store_mod.MAX_CHAT_MSGS - 1], self.store.msgs[1..store_mod.MAX_CHAT_MSGS]);
                self.store.msg_count = store_mod.MAX_CHAT_MSGS - 1;
                // eviction shifted every index down one — keep the live draft slot pointing at its message
                if (self.reflect_msg_idx) |mi| self.reflect_msg_idx = if (mi > 0) mi - 1 else null;
            }
            var m: store_mod.ChatMsg = .{ .role = role };
            const tn = @min(text.len, m.text.len);
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
        self.persistConv(dd, idb[0..idn]);
    }

    /// Replace message `idx` IN PLACE (role + text) and re-persist — the in-place revision primitive. The
    /// store rewrites the whole conversation file per append anyway, so replacement costs the same. Never
    /// observes (callers observe the FINAL text exactly once, at finalize).
    fn replaceMsg(self: *Chat, dd: []const u8, idx: usize, role: store_mod.ChatRole, text: []const u8) void {
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            if (idx >= self.store.msg_count) return;
            idn = self.store.conv_active_len;
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
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            var idx = idx_in;
            idn = self.store.conv_active_len;
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
            if (idx > self.store.msg_count) return;
            if (self.store.msg_count >= store_mod.MAX_CHAT_MSGS) {
                if (idx == 0) return; // inserting before the message being evicted — nothing sane to do
                std.mem.copyForwards(store_mod.ChatMsg, self.store.msgs[0 .. store_mod.MAX_CHAT_MSGS - 1], self.store.msgs[1..store_mod.MAX_CHAT_MSGS]);
                self.store.msg_count = store_mod.MAX_CHAT_MSGS - 1;
                idx -= 1;
                if (self.reflect_msg_idx) |mi| self.reflect_msg_idx = if (mi > 0) mi - 1 else null;
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
        // step (not an answer); every other turn is the assistant.
        escJson(&msgs, self.gpa, if (kind == .loop_infer) LOOP_SYSTEM else if (kind == .consolidate) CONSOLIDATE_SYSTEM else SYSTEM_PROMPT);
        escJson(&msgs, self.gpa, self.dateLine(&dbuf));
        msgs.appendSlice(self.gpa, "\"}") catch return;
        // HIPPOCAMPUS: draw the facts most relevant to THIS query in from the chat's own neuron-db — earlier
        // turns and cast findings, including ones evicted from the 24KB visible history — and inject them as a
        // grounded-context message. Additive + guarded: if recall is empty/disabled, the prompt is byte-identical
        // to the token-tail-only version, so this can only help, never break the turn.
        if (kind != .consolidate and self.mind().enabled() and self.last_user_len > 0) {
            var scope_buf: [40]u8 = undefined;
            const scope = self.convScope(&scope_buf);
            if (scope.len > 0) {
                var rbuf: [4096]u8 = undefined;
                const mem = self.mind().recall(scope, self.last_user[0..self.last_user_len], &rbuf);
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
                msgs.appendSlice(self.gpa, ",{\"role\":\"system\",\"content\":\"YOUR MEMORY (durable facts you saved for THIS user on their own local machine — keys, logins, preferences. Use them to answer directly; they are private to this user. Add one with a REMEMBER: line, drop one with FORGET:):\\n") catch return;
                escJson(&msgs, self.gpa, block);
                msgs.appendSlice(self.gpa, "\"}") catch return;
                log.info("chat memory: injected {d}b of durable memory", .{block.len});
            }
        }
        {
            self.store.lock();
            defer self.store.unlock();
            // include from the tail while the budget lasts (the newest matter most)
            var budget: usize = 24 * 1024;
            var first: usize = 0;
            var i: usize = self.store.msg_count;
            while (i > 0) {
                i -= 1;
                const l = self.store.msgs[i].text_len;
                if (budget < l) {
                    first = i + 1;
                    break;
                }
                budget -= l;
            }
            var k = first;
            while (k < self.store.msg_count) : (k += 1) {
                const m = &self.store.msgs[k];
                if (m.role == .thought) continue; // reasoning traces are UI-only — never re-fed to the model
                const role = switch (m.role) {
                    .veil => "assistant",
                    else => "user",
                };
                msgs.print(self.gpa, ",{{\"role\":\"{s}\",\"content\":\"", .{role}) catch return;
                escJson(&msgs, self.gpa, m.textStr());
                msgs.appendSlice(self.gpa, "\"}") catch return;
            }
        }
        if (kind == .reflect and self.reflect_draft_len > 0) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"assistant\",\"content\":\"") catch return;
            escJson(&msgs, self.gpa, self.reflect_draft[0..self.reflect_draft_len]);
            msgs.appendSlice(self.gpa, "\"}") catch return;
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"Self-critique pass. Review the draft above as if it were someone else's work you must catch mistakes in: check the logic and facts for errors, look for missing steps, unstated assumptions, unhandled edge cases, and unclear structure. If a claim is uncertain, hedge it or note it. Fix everything you find and make it sharper. If the draft is ALREADY correct and complete, return it exactly unchanged. Return ONLY the final answer text — no meta-commentary, no 'here is the revision', no TOOL: or CAST:.\"}") catch return;
        }
        if (kind == .collect) {
            msgs.appendSlice(self.gpa, ",{\"role\":\"user\",\"content\":\"The cast has finished. The files listed above are WHATEVER the hive actually produced - their names may NOT match what the goal asked for (a file called COORDINATOR_PLAN.md or research.py might be the real deliverable, or a goal-named file might be missing). INVENTORY the files, judge which ones actually answer the user's original request, and compose your answer STRICTLY from their real content shown above - never invent content and never claim a file exists that isn't listed. If the goal asked for specific files that aren't present, say so plainly and point to the odd-named files that cover (or fail to cover) that need. Do not cast again.\"}") catch return;
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
        // A .reflect pass does NOT preview its content: the revision lands IN PLACE in the draft's slot at
        // settle — streaming it as a second bubble below the draft is exactly the double-post artifact.
        // The reasoning preview still streams (that's the self-check thinking, worth watching live).
        {
            self.store.lock();
            defer self.store.unlock();
            const src = if (self.turn == .reflect) "" else stripToolTail(self.stream.content.items);
            const n = @min(src.len, self.store.stream_text.len);
            @memcpy(self.store.stream_text[0..n], src[0..n]);
            self.store.stream_len = n;
            // show the TAIL of the reasoning if it exceeds the buffer (the newest thinking matters most)
            const rsrc = self.stream.reasoning.items;
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
                if (self.turn_fb_ms == 0) self.turn_fb_ms = @intCast(@max(1, self.nowMs() - self.turn_start_ms));
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
            self.appendMsg(dd, .veil, emsg);
            self.store.pushNotif("Chat model error", self.stream.errStr(), 2);
            self.stream.deinit(self.gpa);
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
            const tc_opt = toolCall(full) orelse toolCallXml(full) orelse
                (if (full.len == 0 and reason.len > 0) toolCallLoose(reason) else null) orelse blk: {
                if (codeBlockWrite(self.gpa, self.last_user[0..self.last_user_len], full)) |s| {
                    synth_args = s;
                    synthesized = true;
                    log.info("build recovery: model pasted a code block instead of write_file — synthesizing the write", .{});
                    break :blk ToolCall{ .name = "write_file", .args = s };
                }
                break :blk null;
            };
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
            if (runCall(full)) |cmd| {
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
            if (kind == .user and self.castPending() and userWantsKill(self.last_user[0..self.last_user_len])) {
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
                self.appendMsg(dd, .cast_note, "(that used a tool-call format I can't run — asking it to retry in the right one)");
                const p = "Your last reply attempted a tool call in a format I can't execute (only plain TOOL: lines run). Reissue the SAME call: one short why-sentence, then on its own line: TOOL: <name> {\"arg\":\"value\", ...} — no other syntax, no special tokens.";
                self.appendMsg(dd, .cast_note, p);
                self.last_user_len = @min(p.len, self.last_user.len);
                @memcpy(self.last_user[0..self.last_user_len], p[0..self.last_user_len]);
                self.internal_turn = true; // corrective directive, not a real user turn — don't consolidate memory off it
                self.setStatus("retrying in the right tool format...");
                self.startTurn(dd, kind);
                return;
            }
        }
        if (REFLECT_PASSES > 0 and !self.in_veil_work and shouldReflectPass(kind, self.last_user[0..self.last_user_len], full)) {
            self.reflect_pass = 0; // fresh iterative-critique budget for this answer
            self.reflect_dirty = false; // no pass has changed anything yet
            self.reflect_draft_len = @min(full.len, self.reflect_draft.len);
            @memcpy(self.reflect_draft[0..self.reflect_draft_len], full[0..self.reflect_draft_len]);
            // seed the reasoning trace with the drafting pass's thinking (each self-check pass adds its own)
            self.reflect_trace_len = 0;
            self.traceAddPass("- drafting -", reason);
            self.stream.deinit(self.gpa);
            // NOTHING is committed while the self-check runs. The draft used to be posted here and then
            // rewritten in place each pass — the veil visibly "deleting and replacing its own answer", which
            // the user called out as annoying. Instead the answer stays hidden; the user watches the live
            // reasoning stream during refinement, and revealReflect lands the FINAL answer once at the end.
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
                self.traceAddPass(label, reason);
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
                if (toolCall(final_ans) orelse toolCallXml(final_ans)) |tc| {
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
            self.appendVeil(dd, reason, full);
        } else if (self.in_veil_work and parseCastSpec(full) != null) {
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
            } else if (self.loop_iter > 0) {
                // AUTO-LOOP GUARD: a loop-INFERRED turn must never launch a fresh multi-minute swarm on its own —
                // casting is a big, resource-heavy commitment the USER makes explicitly (the observed runaway:
                // auto-loop kept inventing steps after a kill and deployed an unprompted hive). Show the prose,
                // stop the loop, and tell the user to ask for a cast directly if they want one.
                if (note.len > 0 or reason.len > 0) self.appendVeil(dd, reason, note);
                self.stopLoop(dd, "auto-loop paused: the veil wanted to cast a new swarm — say 'cast a swarm to …' yourself to start one.");
                return;
            } else {
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
            // content empty but the model reasoned — show the reasoning AS the reply so it's never blank.
            self.appendMsg(dd, .veil, reason);
        } else {
            self.appendMsg(dd, .veil, "(the model returned an empty reply — try rephrasing, or switch to a lighter model in Settings)");
        }
        // LEARNING (neuron-db Hebbian plasticity): a completed answer turn means the query topic + the memory
        // recalled for it proved useful — reinforce that topic so it out-ranks the alternatives in later
        // trust-weighted recall. The chat's hippocampus now LEARNS from engagement instead of only accumulating;
        // paired with the trust-weighted recall() this closes the perception→learning→belief loop. No-op on fail.
        if ((kind == .user or kind == .collect or kind == .reflect) and full.len > 0 and self.last_user_len > 3 and self.mind().enabled()) {
            var scope_buf: [40]u8 = undefined;
            const scope = self.convScope(&scope_buf);
            if (scope.len > 0) self.mind().reinforce(scope, self.last_user[0..self.last_user_len], "answered");
        }
        // MEMORY INSIDE RECURSIVE THOUGHT: an answer turn just finalized — decide (BEFORE freeing the stream, since
        // `full` is a stream slice) whether to run the deterministic consolidation pass that persists durable facts
        // about the user. If it fires, its own settle does setBusy(false)+maybeLoop, so we return here.
        const consolidate = self.shouldConsolidate(kind, full);
        self.stream.deinit(self.gpa);
        if (consolidate) {
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
        // Durable-signal gate (kept as a cost guard — one model call per hit — but WIDENED per the user's report
        // that the veil "doesn't know when to save data": it now also fires on commitments/plans/schedule the
        // user states in passing (the missed "therapy at 12pm today" case), and scans the ANSWER too, since the
        // veil often re-states a durable fact it just learned. Pure-technical Q&A still matches nothing → no call.
        return exchangeHasDurableSignal(self.last_user[0..self.last_user_len]) or
            (full.len > 0 and exchangeHasDurableSignal(full));
    }

    // ------------------------------------------------------------------------------ prompt loop (full-auto)

    /// After a turn settles, start a loop-infer turn IF auto-loop is on and the conversation is genuinely idle
    /// (no in-flight turn, no running cast). Called at the settle point and on a fresh toggle-on (.loop_kick).
    fn maybeLoop(self: *Chat, dd: []const u8) void {
        // wait for any turn/cast/console AND for a concurrent-veil attempt or its pending finish (else auto-loop
        // would grab the shared turn slot out from under the veil work / finish).
        if (self.turn != .idle or self.cast_active or self.consoleAiBusy() or self.veil_work_active or self.cast_awaiting_veil) return;
        const on = blk: {
            self.store.lock();
            defer self.store.unlock();
            break :blk self.store.chat_loop;
        };
        if (!on) return;
        // Only KEEP LOOPING while the veil is actually working (took a tool/shell/cast action this exchange). A
        // plain conversational answer means it's done — stop instead of inventing next-steps (the observed spin,
        // e.g. re-emitting "read the test and fix it" forever, or looping on "what's the agenda").
        if (!self.acted) {
            self.stopLoopQuiet();
            return;
        }
        {
            self.store.lock();
            defer self.store.unlock();
            if (self.store.msg_count == 0) return; // nothing to continue from yet — wait for the first message
        }
        if (self.loop_iter >= LOOP_MAX_ITERS) {
            self.stopLoop(dd, "auto-loop stopped: reached the iteration limit. Toggle it on again to keep going.");
            return;
        }
        self.abort_turn.store(false, .monotonic); // reaching here means the loop is (re)starting deliberately
        var sb: [64]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&sb, "auto-loop {d}/{d}: planning next step...", .{ self.loop_iter + 1, LOOP_MAX_ITERS }) catch "auto-loop: planning...");
        self.startTurn(dd, .loop_infer);
    }

    /// Handle the message a loop-infer turn produced: stop on DONE / empty / user-toggled-off / cap, else send it.
    fn loopContinue(self: *Chat, dd: []const u8, raw: []const u8) void {
        const text = std.mem.trim(u8, raw, " \r\n\t`*\"'");
        const on = blk: {
            self.store.lock();
            defer self.store.unlock();
            break :blk self.store.chat_loop;
        };
        if (!on) { // the user switched auto-loop off while it was inferring — stop quietly
            self.setBusy(false);
            return;
        }
        if (text.len == 0) {
            self.stopLoop(dd, "auto-loop ended: no next step was inferred.");
            return;
        }
        if (loopIsDone(text)) {
            self.stopLoop(dd, "auto-loop complete: the goal looks achieved.");
            return;
        }
        // REPEAT GUARD: a weak model in auto-loop can spin, re-emitting a near-identical next step ("check the
        // status to confirm" twice in a row). If the inferred message basically repeats the last one, the loop
        // isn't making progress — stop instead of churning.
        if (nearlySame(text, self.last_user[0..self.last_user_len])) {
            self.stopLoop(dd, "auto-loop stopped: the next step just repeated the last one (no progress).");
            return;
        }
        if (self.loop_iter >= LOOP_MAX_ITERS) {
            self.stopLoop(dd, "auto-loop stopped: reached the iteration limit. Toggle it on again to keep going.");
            return;
        }
        self.loop_iter += 1;
        // send the inferred message as a (visible) user turn — same path as a manual send, minus the counter reset
        self.last_user_len = @min(text.len, self.last_user.len);
        @memcpy(self.last_user[0..self.last_user_len], text[0..self.last_user_len]);
        self.tool_iters = 0;
        self.appendMsg(dd, .user, text);
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
        }
        self.loop_iter = 0;
        self.reflect_pass = 0; // abandon any pending self-critique iteration
        self.reflect_dirty = false;
        self.reflect_draft_len = 0;
        self.reflect_msg_idx = null; // the committed draft simply stands as the answer
        self.reflect_trace_len = 0;
        // Abandon any concurrent-veil parallel work + pending compare/merge. Without this, in_veil_work could stay
        // TRUE and a later normal turn would write its files into the isolated {conv}-veil dir (lost work), and a
        // pending merge would fire behind the Stop. The hive's own output stays saved (viewable in the Swarm tab).
        self.resetVeilWork();
        if (self.awaitingShellApproval()) self.clearPendingCmd(); // Stop dismisses a parked command (unrun)
        if (self.turn != .idle) {
            llm.abort(&self.stream, self.io);
            self.stream.deinit(self.gpa);
            self.turn = .idle;
            self.appendMsg(dd, .cast_note, "(stopped)");
        }
        self.setStatus("");
        self.setBusy(false);
    }

    /// Disarm auto-loop silently — the veil just gave a plain answer, so there's nothing to narrate.
    fn stopLoopQuiet(self: *Chat) void {
        self.store.lock();
        defer self.store.unlock();
        self.store.chat_loop = false;
    }

    /// Turn auto-loop off and tell the user why (the verifiable stop condition fired).
    fn stopLoop(self: *Chat, dd: []const u8, why: []const u8) void {
        {
            self.store.lock();
            defer self.store.unlock();
            self.store.chat_loop = false;
        }
        self.loop_iter = 0;
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
        const text = self.processMemory(dd, self.processSteer(dd, stripToolTail(text_raw)));
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
        if (reasoning.len == 0) {
            self.appendMsg(dd, .veil, text);
            return;
        }
        // Reasoning lands as its OWN collapsed .thought message above the answer. It used to be baked into the
        // answer text as "> " blockquote lines, which re-fed the model its own prior reasoning as assistant
        // history every turn (.thought is excluded from the prompt) and cluttered the visible answer.
        var buf: [4096]u8 = undefined;
        var w: usize = 0;
        const cap = @min(reasoning.len, 4000);
        var it = std.mem.splitScalar(u8, reasoning[0..cap], '\n');
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
        if (text.len > 0) self.appendMsg(dd, .veil, text);
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
    /// (capped per pass so several passes fit the trace buffer). Intermediate passes' reasoning used to be
    /// DISCARDED entirely; this is where it survives.
    fn traceAddPass(self: *Chat, label: []const u8, reason: []const u8) void {
        if (self.reflect_trace_len > 0) self.traceAppend("\n");
        self.traceAppend(label);
        const r = std.mem.trim(u8, reason, " \r\n\t");
        if (r.len > 0) {
            self.traceAppend("\n");
            const cap = @min(r.len, 1500);
            self.traceAppend(r[0..cap]);
            if (r.len > cap) self.traceAppend(" ...");
        }
    }

    /// REVEAL the reflected answer — ONE clean commit at the end of refinement. Nothing is shown while the
    /// self-check passes run (the draft used to be committed then rewritten in place, which read as the veil
    /// "deleting and replacing its answer" — the reported annoyance). During refinement the user watches the
    /// live reasoning stream; here the final answer lands once, with the full reasoning trace collapsed above
    /// it (the "reasoning locker" the user opens if curious). Clears all reflect state.
    fn revealReflect(self: *Chat, dd: []const u8, answer: []const u8) void {
        if (answer.len > 0) {
            self.appendMsgFull(dd, .veil, answer, false);
            self.observeFinal(answer); // hippocampus stores the FINAL text, never a superseded draft
            if (self.reflect_trace_len > 0) {
                if (self.lastMsgIdxOfRole(.veil)) |mi| self.insertMsgBefore(dd, mi, .thought, self.reflect_trace[0..self.reflect_trace_len]);
            }
        }
        self.reflect_msg_idx = null;
        self.reflect_trace_len = 0;
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

    /// Hippocampus observe of the FINAL answer text — deferred from the draft commit so recall never
    /// surfaces a superseded draft.
    fn observeFinal(self: *Chat, text: []const u8) void {
        if (text.len == 0) return;
        var idb: [32]u8 = undefined;
        var idn: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            idn = self.store.conv_active_len;
            @memcpy(idb[0..idn], self.store.conv_active[0..idn]);
        }
        if (idn > 0) self.mind().observe(idb[0..idn], text);
    }

    // ------------------------------------------------------------------------------ casting (the existing door)

    /// CAST through the server's cast endpoint (POST /api/v1/cast). The AI configures the payload — the goal,
    /// how many minds, quick strike vs a sustained (LONG/continuous) hivemind, and the time budget — and the
    /// chat fires it on the chat's own provider. The server clamps to the plan's ceilings.
    pub fn fireCast(self: *Chat, dd: []const u8, spec: CastSpec) void {
        self.acted = true; // a cast is a big action → the exchange is "working"
        const goal = spec.goal;
        // The conversation id doubles as the cast's build dir: the server points the hive's run_dir at this
        // chat's `_chat/builds/{conv}` folder, so the cast builds in the SAME tree the chat's own build tools
        // (and the desktop console) use — not a throwaway `{hex}/work` the chat can never see.
        var convb: [96]u8 = undefined;
        const conv = self.convScope(&convb);
        // Concurrent Veil: the veil's parallel attempt JOINS the hive here — both build in this SAME "{conv}"
        // dir (no separate "-veil" copy), so the swarm's own concurrent-edit safety (not a post-hoc AI merge)
        // is what reconciles the two streams of edits. veil_join just gates whether maybeVeilWork fires.
        const veil_join = CONCURRENT_VEIL and conv.len > 0 and conv.len <= self.cast_conv.len;
        const hive_dir = conv;
        const minds: u32 = if (spec.minds > 0) std.math.clamp(spec.minds, 1, 30) else 3;
        const minutes: u32 = if (spec.minutes > 0) std.math.clamp(spec.minutes, 1, 120) else if (spec.long) 20 else CAST_MINUTES;
        const mode: []const u8 = if (spec.long) "continuous" else "cast";
        self.cast_minutes = minutes;
        var bb: [256]u8 = undefined;
        var kb: [192]u8 = undefined;
        var mb: [96]u8 = undefined;
        const prov = self.resolveProvider(&bb, &kb, &mb);
        var kind: u8 = 0;
        var byok: u8 = 0;
        var port: u16 = 8787;
        var tokb: [128]u8 = undefined;
        var tok_n: usize = 0;
        {
            self.store.lock();
            defer self.store.unlock();
            kind = self.store.settings.chat_kind;
            byok = self.store.settings.chat_byok;
            port = self.store.settings.port;
            tok_n = self.store.settings.token_len;
            @memcpy(tokb[0..tok_n], self.store.settings.token[0..tok_n]);
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

        var body: [3072]u8 = undefined;
        var w = Io.Writer.fixed(&body);
        const bok = blk: {
            w.print("{{\"provider\":\"{s}\",\"model\":\"{s}\",\"base_url\":\"{s}\",\"minutes\":{d},\"minds\":{d},\"mode\":\"{s}\",\"dir\":\"", .{ prov_key, prov.model, prov.base_url, minutes, minds, mode }) catch break :blk false;
            wesc(&w, hive_dir); // the hive builds in {conv} — the SAME dir the veil's parallel attempt joins
            w.writeAll("\",\"api_key\":\"") catch break :blk false;
            wesc(&w, prov.key);
            w.writeAll("\",\"goal\":\"") catch break :blk false;
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

        const resp = netcli.cast(self.io, self.gpa, port, tokb[0..tok_n], w.buffered()) orelse {
            log.err("cast: netcli returned NULL (no response after retries) — server on :{d}?", .{port});
            self.appendMsg(dd, .cast_note, "[cast] no response from the veil server on :8787 — it may be starting up or briefly busy. If casts keep failing, make sure the server is running (run the veil server / `python deploy.py`), then try again.");
            self.updateCastRow(.failed, 0, -1, "no response from :8787 (busy or down)", "");
            self.store.pushNotif("Cast failed", "no response from :8787 — try again", 2);
            self.setStatus("");
            return;
        };
        defer if (resp.body.len > 0) self.gpa.free(resp.body);
        log.info("cast: POST -> status={d} body={s}", .{ resp.status, resp.body[0..@min(resp.body.len, 160)] });
        if (resp.status != 200 and resp.status != 201) {
            // 404 specifically means the RUNNING veil.exe predates the /api/v1/cast route — a stale server binary
            // (also the usual cause of the on/offline flapping, since it predates the crash + httpz-spin fixes).
            var nb: [280]u8 = undefined;
            const msg = if (resp.status == 404)
                std.fmt.bufPrint(&nb, "[cast] the veil server is out of date — its build predates the cast endpoint (HTTP 404). Rebuild + restart it (`zig build --release=fast` then relaunch veil.exe, or `python deploy.py`). I'll answer directly from chat in the meantime.", .{}) catch "[cast] server out of date (404) — rebuild + restart it"
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
    fn runToolAndContinue(self: *Chat, dd: []const u8, tc: ToolCall) void {
        self.acted = true; // a tool ran this exchange → the veil is working → auto-loop may continue
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
        // START a new top-level file/package beside it (the "rival build" failure: app.py + app/ +
        // social_network/ in one tree) is deflected ONCE with the blueprint so the model redirects into the
        // hive's layout (or STEERs the hive). An insistent second attempt at the same top segment runs anyway —
        // the guard is a nudge, never a hard wall.
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

        var tokb: [128]u8 = undefined;
        var tok_n: usize = 0;
        var port: u16 = 8787;
        {
            self.store.lock();
            defer self.store.unlock();
            port = self.store.settings.port;
            tok_n = self.store.settings.token_len;
            @memcpy(tokb[0..tok_n], self.store.settings.token[0..tok_n]);
        }

        // the active conversation id → a per-conversation build workdir the server writes into + the console cd's to.
        // The veil's PARALLEL attempt (in_veil_work) targets this SAME dir too — it joins the hive's build rather
        // than a separate copy, so there's nothing to reconcile afterward (the server's edit_file already
        // serializes/merges concurrent edits the same way it does for multiple hive minds).
        var convb: [40]u8 = undefined;
        const conv = self.convScope(&convb);

        // body = {"tool":NAME,"args":"<escaped raw json>","dir":"<conv>"} — args ride as a JSON string (tool-call
        // convention). HEAP-sized to hold the whole (escaped) args: wesc doubles at most, so 2x + envelope. A
        // fixed [2048] used to reject any write_file over ~1.5KB ("arguments were too long to send"). netcli
        // passes the body straight to curl --data-binary (no cap), and a reply is bounded by MAX_TOKENS.
        const body = self.gpa.alloc(u8, args.len * 2 + name.len + conv.len + 64) catch {
            self.appendMsg(dd, .cast_note, "[tool] out of memory building the request");
            self.setBusy(false);
            return;
        };
        defer self.gpa.free(body);
        var w = Io.Writer.fixed(body);
        const bok = blk: {
            w.print("{{\"tool\":\"{s}\",\"args\":\"", .{name}) catch break :blk false;
            wesc(&w, args);
            w.print("\",\"dir\":\"{s}\"}}", .{conv}) catch break :blk false;
            break :blk true;
        };

        var rbuf: [8192]u8 = undefined;
        var result: []const u8 = "(tool error)";
        if (!bok) {
            result = "(the tool arguments were too long to send)";
        } else if (netcli.chatTool(self.io, self.gpa, port, tokb[0..tok_n], w.buffered())) |resp| {
            defer if (resp.body.len > 0) self.gpa.free(resp.body);
            log.info("chat tool: {s} -> status={d} body={s}", .{ name, resp.status, resp.body[0..@min(resp.body.len, 160)] });
            result = extractToolResult(resp.body, &rbuf);
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
            // KILL unlocks the user immediately. The bug: kill_swarm terminated the worker but the desktop kept
            // cast_active=true (nothing here cleared it), and a hard kill emits no "stopped" event, so watchCast
            // never converged — the next cast bounced with "a cast is already running" and the user was locked in
            // the chat until the minutes-long deadline. Clear the cast trio locally now (mirrors failCast), so
            // castPending() goes false and a new cast can fire. The run dir + findings stay on disk.
            if (std.mem.eql(u8, name, "kill_swarm") and resp.status == 200) {
                self.cast_active = false;
                self.cast_stop_sent = true;
                self.resetVeilWork();
                self.updateCastRow(.done, 0, -1, "killed", self.cast_rel[0..self.cast_rel_len]);
                self.setStatus("");
                log.info("chat: kill_swarm confirmed — cast state cleared, user unlocked", .{});
            }
        } else {
            result = "(no response from the veil server on :8787 — is it running?)";
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
        // spawning it — the evidence was the veil firing 6 mangled powershell commands unattended. The turn is
        // held busy (awaitingShellApproval) until the user Approves / Bypasses / Denies from the Veil tab.
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

    pub fn watchCast(self: *Chat, dd: []const u8) void {
        if (!self.cast_active) return;
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
                // (the v27 build-in-place change) — match that first; fall back to the hex for any legacy path.
                if ((conv.len > 0 and std.mem.eql(u8, base, conv)) or std.mem.eql(u8, base, hex)) {
                    self.cast_rel_len = @min(id.len, self.cast_rel.len);
                    @memcpy(self.cast_rel[0..self.cast_rel_len], id[0..self.cast_rel_len]);
                    self.updateCastRow(.running, 0, -1, "", id);
                    break;
                }
            }
            if (self.cast_rel_len == 0) {
                if (now > self.cast_deadline_s) self.failCast(dd, "[cast] the run directory never appeared — check the server");
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
                    self.appendMsg(dd, .cast_note, note);
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
        if (!m.stopped) {
            var sbuf: [96]u8 = undefined;
            // Show the real metric once a score/phase event has landed; before that (common early in a slow
            // local cast) fall back to an elapsed-vs-budget estimate capped at 90% so the label MOVES instead of
            // sitting at 0 the whole time. cast_deadline_s = start + CAST_MINUTES*60 + 120, so start is derivable.
            const shown_pct: i32 = if (m.pct >= 0) m.pct else blk: {
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
            // a user (or the veil-work) turn may still be streaming — collect/merge on a later idle tick
            if (self.turn == .idle) self.castFinished(dd, rel, &m, ev_n);
            return;
        }
        if (now > self.cast_deadline_s) {
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

    /// The hive cast has finished. In concurrent-veil mode, defer finishing until the Veil's own parallel turn
    /// (writing into this SAME shared dir) has also settled, so its last edits are in the tree before the answer
    /// is composed; otherwise collect the result directly (the classic path).
    fn castFinished(self: *Chat, dd: []const u8, rel: []const u8, m: *const scan.Metrics, ev_n: usize) void {
        if (self.cast_epoch != self.conv_epoch) {
            // The user has moved on (newer message / switched conversation / Stop) since this cast was scheduled.
            // Do NOT inject the digest or hijack a .collect model turn to post-process an old goal into the live
            // chat — leave one passive note; the run stays on disk and can be summarized on request.
            self.cast_active = false;
            self.resetVeilWork();
            self.updateCastRow(.done, m.round, m.pct, "", rel);
            var nb: [256]u8 = undefined;
            const note = std.fmt.bufPrint(&nb, "[cast] finished in the background — results saved at {s}; open the Swarm tab or ask me to summarize them.", .{rel}) catch "[cast] finished in the background — results saved; open the Swarm tab or ask me to summarize them.";
            self.appendMsg(dd, .cast_note, note);
            self.setStatus("");
            return;
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
            // THE VEIL IS THE HIVE'S ORCHESTRATOR while a cast runs — never a rival builder. The old [parallel]
            // prompt had it build the same goal blind in the same dir, which produced competing top-level
            // structures beside the hive's (the "chat went off and did its own thing" report). Now it gets the
            // hive's OWN blueprint and a narrate / steer / gap-fill-within-the-layout job description.
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
            // user moved on between the hive finishing and the merge — passive note, no hijacked collect turn
            const rel0 = self.cast_rel[0..self.cast_rel_len];
            self.resetVeilWork();
            var nb: [256]u8 = undefined;
            const note = std.fmt.bufPrint(&nb, "[cast] finished in the background — results saved at {s}; open the Swarm tab or ask me to summarize them.", .{rel0}) catch "[cast] finished in the background — results saved; open the Swarm tab or ask me to summarize them.";
            self.appendMsg(dd, .cast_note, note);
            self.setStatus("");
            return;
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
        // NOTE: a pending Stop is deliberately NOT cleared here anymore — Stop during a cast now means "do not
        // post-process this into my chat" (it also bumps conv_epoch, so castFinished already refuses the collect).
        self.updateCastRow(.done, m.round, m.pct, "", rel);
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
        jb.print(self.gpa, "\n\n(full swarm output saved at {s}; open it in the Swarm tab)", .{rel}) catch {};
        // Keep as much of the digest as the ChatMsg buffer (12288b) holds — the synthesis IS the answer, so
        // we want it whole, not clipped. appendMsg truncates to the buffer anyway.
        const digest = jb.items[0..@min(jb.items.len, 12200)];
        self.appendMsg(dd, .cast_note, digest);
        self.setStatus("composing the answer...");
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
pub const CastSpec = struct { goal: []const u8, minds: u32 = 0, long: bool = false, minutes: u32 = 0 };

fn uintAfter(line: []const u8, key: []const u8) ?u32 {
    const rest = std.mem.trim(u8, line[key.len..], " :\t=");
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

/// Parse the AI's cast directive: a `CAST: <goal>` line, optionally followed (within the reply's first lines)
/// by `MINDS <n>` (swarm size, 2-30), `LONG` (a sustained continuous hivemind vs the default quick strike),
/// and `MINUTES <n>` (time budget). Returns null if there's no CAST line. Config lines must ride near the top,
/// not buried in prose.
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
    // Preferences — first-person only (dropped bare "prefer to", which matched "most teams prefer to use postgres").
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
    // remember/forget directives, credentials, AND commitments/schedule/plans the user states in passing (the
    // "we have to go to therapy at 12pm today" case the narrow first-person-only gate missed). Still tight
    // enough that ordinary technical questions ("explain tokenization", "how does X work") match nothing.
    const sigs = [_][]const u8{
        // identity / preference / setup (first person)
        "my ",       "i'm",        "i am",      "i use",     "i prefer",  "i like",     "i always",
        "i work",    "i deploy",   "i run",     "i host",    "i keep",    "i need",     "i have to",
        "i want",    "we use",     "we deploy", "we have",   "call me",   "name is",
        // explicit directives + credentials
        "remember",  "forget",     "password",  "api key",   "apikey",    "credential", "token is",
        // commitments / schedule / plans (durable for THIS user's context) — words specific enough that a
        // technical answer won't trip them (no bare "am"/"at N" — those match "diagram"/"at 3 levels").
        "today",       "tomorrow",  "tonight",     "next week", "appointment", "meeting",  "deadline",
        "remind me",   "schedule",  "set an alarm", "set a reminder", "due ",     "o'clock",
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
        "list_swarms",  "stop_swarm", "kill_swarm",     "swarm_status", "swarm_findings", "web_search",
        "web_fetch",    "fetch_json", "recall_hive",    "observe",      "write_file",     "edit_file",
        "read_file",    "list_dir",   "run_tests",      "run_python",   "delete_file",
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

/// THE one TOOL: predicate — dispatch (toolCall), the display stripper (stripToolTail) and the reflect
/// gate all use this same scan, so a call can never be hidden-but-not-run or run-but-shown (the old
/// dispatcher was line-start-only while the stripper matched mid-line; anything between the two anchors
/// was silently dropped or leaked verbatim into the chat). Finds the FIRST "TOOL:" that is a real call:
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
        if (name.len == 0 or name.len > 40) continue;
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
        var k = i;
        while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
        if (k < text.len and text[k] == '{') {
            const astart = k;
            var depth: i32 = 0;
            while (k < text.len) : (k += 1) {
                if (text[k] == '{') depth += 1 else if (text[k] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        k += 1;
                        break;
                    }
                }
            }
            if (depth == 0 and k > astart + 1) args = text[astart..k];
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
    // RUN: <shell command> — only at a line start (a prose "RUN:" mid-sentence isn't a shell call).
    {
        var i: usize = 0;
        while (i < text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            const line = std.mem.trimStart(u8, text[i..nl], " \t");
            if (std.mem.startsWith(u8, line, "RUN:") and line.len > 4) {
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
/// name+args. Without this those calls render as inert text and the model loops forever re-issuing them (the
/// Mario walkthrough failure: every `<tool:read_file>` was dropped, so the model never saw the files).
pub fn toolCallXml(text: []const u8) ?ToolCall {
    const open = std.mem.indexOf(u8, text, "<tool:") orelse return null;
    var i = open + "<tool:".len;
    const nstart = i;
    while (i < text.len and text[i] != '>' and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and text[i] != '\t') i += 1;
    const name = std.mem.trim(u8, text[nstart..i], " \t:`*\"/");
    if (name.len == 0 or name.len > 40) return null;
    while (i < text.len and text[i] != '>') i += 1; // skip to the tag close
    if (i < text.len) i += 1; // skip '>'
    var args: []const u8 = "{}";
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
    if (i < text.len and text[i] == '{') { // a balanced {...} blob after the tag
        const astart = i;
        var depth: i32 = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '{') depth += 1 else if (text[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
        }
        if (depth == 0 and i > astart + 1) args = text[astart..i];
    }
    return .{ .name = name, .args = args };
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

/// Recover a filename token (foo.html, src/game.js) from a build request — used to rescue a pasted file.
fn recoverFilename(text: []const u8) ?[]const u8 {
    const exts = [_][]const u8{ ".html", ".js", ".py", ".css", ".json", ".ts", ".tsx", ".md", ".txt", ".c", ".cpp", ".h", ".hpp", ".go", ".rs", ".java", ".rb", ".php", ".sh" };
    for (exts) |ext| {
        const at = std.mem.indexOf(u8, text, ext) orelse continue;
        // the char after the ext must not continue the extension (so ".js" in ".json" isn't a false hit)
        const after = at + ext.len;
        if (after < text.len and (std.ascii.isAlphanumeric(text[after]))) continue;
        var s = at;
        while (s > 0) {
            const ch = text[s - 1];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == '/') s -= 1 else break;
        }
        const name = std.mem.trimStart(u8, text[s..after], "/."); // never absolute / dotfile-leading (safeRel would reject)
        if (name.len > ext.len and name.len < 100 and std.mem.indexOf(u8, name, "..") == null) return name;
    }
    return null;
}

/// BUILD rescue: the model pasted a whole file as a ```fenced code block instead of TOOL: write_file, so it
/// never hit disk. If a filename is recoverable from the user's request and the block is substantial, build a
/// write_file args blob {"path":..,"content":..} (heap-owned; caller frees). null = not a paste we can rescue.
fn codeBlockWrite(gpa: std.mem.Allocator, last_user: []const u8, full: []const u8) ?[]u8 {
    const fname = recoverFilename(last_user) orelse return null;
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
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    out.appendSlice(gpa, "{\"path\":\"") catch return null;
    escJson(&out, gpa, fname);
    out.appendSlice(gpa, "\",\"content\":\"") catch return null;
    escJson(&out, gpa, code);
    out.appendSlice(gpa, "\"}") catch return null;
    return out.toOwnedSlice(gpa) catch null;
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
    if (name.len == 0 or name.len > 40) return null;
    var args: []const u8 = "{}";
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i < text.len and text[i] == '{') {
        const astart = i;
        var depth: i32 = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '{') depth += 1 else if (text[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
        }
        if (depth == 0 and i > astart + 1) args = text[astart..i];
    }
    return .{ .name = name, .args = args };
}

/// Does `text` look like a tool-call ATTEMPT in some dialect none of toolCall/toolCallXml/toolCallLoose speak,
/// rather than a genuine prose answer? Catches the observed failure modes: DeepSeek/Qwen-style special tokens
/// using the fullwidth vertical bar (U+FF5C) around "tool" markers (e.g. "<｜tool▁calls｜>", or a model garbling
/// its own token set into something like "<｜｜DSML｜｜tool_calls>"), and Claude/Anthropic-style
/// `<invoke name="...">`/`<function_calls>` XML. Deliberately loose (false positives just cost one corrective
/// retry) — the alternative is silently accepting the garbage as the final answer, which is the actual bug.
fn looksLikeFailedToolCall(text: []const u8) bool {
    const markers = [_][]const u8{
        "\u{FF5C}tool", "tool\u{FF5C}", "tool_calls>", "tool_call>", "invoke name=", "function_calls>", "antml:invoke",
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
    const body_cap = if (buf.len > note.len) buf.len - note.len else 0; // reserve room for the note
    var w: usize = 0;
    w += copyInto(buf[w..body_cap], out).len;
    w += copyInto(buf[w..body_cap], err).len;
    // A clean command with no output is SUCCESS, not failure — say so explicitly. The model kept re-running the
    // same probe because a bare "(no output)" read as "it didn't work" (the therapy-alarm evidence).
    if (w == 0 and body_cap > 0 and note.len == 0) w += copyInto(buf[w..body_cap], "(command completed successfully — no output)").len;
    if (w == 0 and body_cap > 0) w += copyInto(buf[w..body_cap], "(no output)").len;
    if (note.len > 0 and w + note.len <= buf.len) {
        @memcpy(buf[w .. w + note.len], note);
        w += note.len;
    }
    return buf[0..w];
}

/// A reply that is exactly a "RUN: <shell command>" line (the AI's micro-console door). Returns the command,
/// trimmed, or null. Mirrors toolCall: only fires if RUN: leads one of the first few substantive lines so a
/// passing mention in prose can't trigger a shell command.
pub fn runCall(full: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, full, '\n');
    var seen: u32 = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r`*");
        if (line.len == 0) continue;
        seen += 1;
        if (seen > 4) return null;
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
/// model narrates "kill_swarm force=true" as prose instead of emitting a real TOOL: line (the observed miss).
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

pub fn userWantsKill(msg: []const u8) bool {
    if (msg.len == 0 or msg.len > 4000) return false;
    var lower: [4000]u8 = undefined;
    const n = @min(msg.len, lower.len);
    for (0..n) |i| lower[i] = std.ascii.toLower(msg[i]);
    const lo = lower[0..n];
    const has_target = std.mem.indexOf(u8, lo, "swarm") != null or std.mem.indexOf(u8, lo, "hive") != null or
        std.mem.indexOf(u8, lo, "cast") != null or std.mem.indexOf(u8, lo, "it") != null;
    if (!has_target) return false;
    const verbs = [_][]const u8{ "kill", "stop", "abort", "cancel", "halt", "terminate", "shut down", "shutdown", "end the" };
    for (verbs) |v| {
        if (std.mem.indexOf(u8, lo, v) != null) return true;
    }
    return false;
}

/// Strip a leading cast-request preamble ("cast a swarm to ", "have the hive ", "run a swarm that ")
/// from the user's message to get a clean one-line goal. Returns a slice into `buf`.
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
    // pure-technical questions must NOT fire (the dropped bare-substring false positives)
    try std.testing.expect(!exchangeHasDurableSignal("explain how tokenization works"));
    try std.testing.expect(!exchangeHasDurableSignal("what is a secret sharing scheme?"));
    try std.testing.expect(!exchangeHasDurableSignal("what does the @ decorator do in Python?"));
    try std.testing.expect(!exchangeHasDurableSignal("how many hours are in four days?"));
    try std.testing.expect(!exchangeHasDurableSignal("describe an account balance class"));
    try std.testing.expect(!exchangeHasDurableSignal("draw a diagram of the parser at each stage"));
}

test "stripDanglingMemoryIntro drops a dangling save-intro but keeps real prose" {
    // the exact live artifact: a bold header pointing at the (stripped) REMEMBER: lines
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
    // a lone 0x97 (CP1252 em dash — INVALID utf8, the byte that 500'd every cast) + a REAL utf8 em dash + a quote
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

test "epoch barrier: a cast finishing AFTER the user moved on leaves a passive note, no hijacked collect turn" {
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

    chat.watchCast(dd); // sees `stopped` — but the epoch moved, so it must NOT inject the digest or start .collect
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
    try std.testing.expect(saw_note);
    try std.testing.expect(!saw_digest);
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

    chat.cmdSend(dd, "Reply with exactly one short sentence: what is the capital of France?");
    try std.testing.expect(chat.turn == .user);
    var waited: usize = 0;
    while (chat.turn != .idle and waited < 3000) : (waited += 1) { // up to ~5min for a cold thinking model
        chat.pumpStream(dd);
        if (waited % 50 == 0) std.debug.print("[live] t+{d}s turn={s} content={d}b reason={d}b done={} saw_any={}\n", .{ waited / 10, @tagName(chat.turn), chat.stream.content.items.len, chat.stream.reasoning.items.len, chat.stream.done, chat.stream.saw_any });
        io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expect(chat.turn == .idle);
    // last message is the veil's reply and it is non-empty, non-error
    try std.testing.expect(store.msg_count >= 2);
    const last = &store.msgs[store.msg_count - 1];
    std.debug.print("[chat live test] veil replied ({d}b): {s}\n", .{ last.text_len, last.textStr()[0..@min(last.text_len, 120)] });
    try std.testing.expect(last.role == .veil);
    try std.testing.expect(last.text_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, last.textStr(), "(model error") == null);
    // and it persisted: the conversation file holds both messages
    var pb: [700]u8 = undefined;
    var idb: [32]u8 = undefined;
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
}

test "shouldReflectPass: only substantive answers to real requests reflect (hello never recurses)" {
    var longbuf: [600]u8 = undefined;
    @memset(&longbuf, 'x');
    const long = longbuf[0..];
    const q = "Explain in detail how a red-black tree stays balanced and why rotations preserve the invariants.";
    // substantive question + substantive answer -> reflect
    try std.testing.expect(shouldReflectPass(.user, q, long));
    try std.testing.expect(shouldReflectPass(.tool_follow, q, long));
    // THE BUG: a greeting must NOT recurse
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
    // MID-LINE calls now dispatch (same predicate as stripToolTail — the old dispatcher missed these
    // while the stripper hid them, so the call was neither executed nor shown):
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
    // the exact gpt-oss failure: content empty, the decision lives mid-sentence in reasoning
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

test "composeConsoleResult keeps stdout then stderr, and always the status note" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("outerr", composeConsoleResult(&buf, "out", "err", ""));
    // a clean exit with no output → an explicit success line (not a bare "(no output)" the model misreads)
    try std.testing.expectEqualStrings("(command completed successfully — no output)", composeConsoleResult(&buf, "", "", ""));
    // ...but a NON-clean exit (note present) with no body keeps the plain "(no output)" + its note
    try std.testing.expectEqualStrings("(no output)(stopped)", composeConsoleResult(&buf, "", "", "(stopped)"));
    try std.testing.expectEqualStrings("hi(stopped)", composeConsoleResult(&buf, "hi", "", "(stopped)"));
    // when the body alone would overflow, room is reserved so the note (e.g. a timeout) still survives
    var small: [12]u8 = undefined;
    const note = "(timed out)"; // 11 bytes
    const r = composeConsoleResult(&small, "xxxxxxxxxxxxxxxxxxxx", "", note);
    try std.testing.expect(std.mem.endsWith(u8, r, note));
    try std.testing.expect(r.len <= small.len);
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
