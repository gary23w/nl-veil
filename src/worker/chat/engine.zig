//! Server-side agentic chat turn loop — the WRITE twin of chat_service.zig's read-only conv routes. Given a
//! user message it runs a bounded tool-calling loop against the caller's chosen model, streaming its progress
//! into the SAME per-conversation store the P0-4 readers serve:
//!
//!     {data}/u{uid}/_chat/convs/{conv}/
//!         messages.jsonl   // one JSON object per line: {role,content,kind,ts}  (user + final assistant turns)
//!         events.jsonl     // one JSON object per line: {kind,...}              (live turn narration for the poll)
//!
//! The build tools the loop's calls run route through the SAME tree a hive cast for this conversation spawns in
//! ({data}/u{uid}/_chat/builds/{conv}) — ToolCtx here is a byte-for-byte copy of chat_tools.runMindTool's, so
//! chat + a cast co-edit ONE workdir with ONE micro-VCS history. Ownership is structural: every path is built
//! from the caller's own uid, so a turn can only ever touch its own conversation.
//!
//! ON by default — postMessage (chat_service.zig) runs this unless VEIL_CHAT_BACKEND=0 (the kill switch), and it
//! is admin-only. The desk prefers this backend turn and falls back to its own local engine on any failure.

const std = @import("std");
const builtin = @import("builtin");
const http = @import("../../gateway/http.zig");
const tools = @import("../tools.zig");
const recipes = @import("../recipes.zig"); // recipe tools: the per-turn granted set advertised in turn_tools + resolved onto ctx.grants
const plugins = @import("../../plug/plugins.zig"); // user extensions: prompt/policy/tool hooks over the sandboxed Lua runtime
const pixelrag = @import("../pixelrag.zig"); // browser-free image attachment ingest (OCR → pixel-RAG index)
const osc = @import("../oscillation.zig");
const llm = @import("../llm.zig");
const modelcfg = @import("modelcfg"); // a MODULE (src/worker/modelcfg.zig) — never a path import
const cctx = @import("context.zig");
const wsp = @import("workspace.zig"); // prompt workspace: typed bids -> fixed-order scored admission + decision log
const builtin_mod = @import("../builtin.zig"); // the built-in engine's sentinel + LIVE served-window publication
const cplan = @import("plan.zig");
const cync = @import("sync.zig");
const toolperf = @import("toolperf.zig"); // per-machine tool latency/reliability learning (dynamic, emergent)
const deploy_service = @import("../deploy/service.zig");
const sched = @import("../sched.zig"); // mutual import (sched spawns turns here); Zig resolves it lazily
const metrics = @import("../metrics.zig"); // per-turn LLM usage lines behind the desk Dashboard
const cpaths = @import("paths.zig"); // conv → build-tree mapping (scheduled runs live under _sched/{task}/runs/)

// Raw-thread sleep (supervisor.zig's threadSleepMs twin): the chat turn runs on a raw detached std.Thread
// (spawnTurn), where io.sleep throws and a swallowed error busy-spins a core. Win32 Sleep on Windows.
const winsleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
} else struct {};
pub fn sleepMsRaw(io: std.Io, ms: u64) void {
    if (builtin.os.tag == .windows) {
        winsleep.Sleep(@intCast(ms));
    } else {
        io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
    }
}

const App = http.App;

/// Hard ceiling on tool-calling round-trips per ONE settled answer. 24 comfortably fits a big single-turn build
/// (a three.js game is many write_file + read_file + edit_file rounds); the outer DRIVE_MAX still bounds the whole
/// turn, and a genuine runaway summarizes (below) rather than committing a raw step-limit string.
const MAX_ITERS: usize = 24;

/// Identical (call, result) repeats before the echo guard refuses that ONE signature. Module-level so the
/// hard stop below can be checked against it — the two only work as a pair.
const ECHO_LIMIT: u8 = 3;

/// How many consecutive refusal-bearing INFERENCES end the turn outright (see `loop_refusals` in
/// runInnerAgentic). The echo guard refuses one signature once it has returned the identical result 3
/// times; an inference whose batch contains any such refusal (or a cross-batch ledger repeat) is one
/// strike, and only a refusal-free inference that executed real work clears the streak — so a model
/// cycling between tools, or padding one dead signature with calls that still execute, terminates
/// instead of grinding to MAX_ITERS. Generous on purpose: strikes land at most one per inference, so the
/// model sees the refusal feedback between every strike and ignores it that many inferences running
/// before the turn is cut.
///
/// FOUR, NOT THREE, AND THE FOURTH IS LOAD-BEARING. At three this sat in exact lockstep with the failure-streak
/// escalation: a pure echo-grind accrues its first strike and its first streak point on the SAME inference, so
/// `fail_streak` reached 3 — the round that spends a real completion on `toolArbiter` for a concrete way out —
/// on the very inference that pushed `loop_refusals` to the kill threshold. The advice was generated, appended
/// to a result the model would never be asked about, and thrown away with the turn. The engine paid for the one
/// piece of genuinely new information it had to offer and then hung up before saying it. The fourth strike buys
/// exactly one inference in which the model can read the arbiter's suggestion and act on it; if it grinds on
/// anyway, that inference is a refusal too and the turn still ends. See the threshold-spacing test.
const LOOP_STOP_REFUSALS: u32 = 4;

/// Hard ceiling on AUTO-LOOP drive steps in one turn when the loop is OFF (loop=0). Kept low (6): a higher cap
/// lets a thorough model "verify" and re-read forever after a fix, while 6 still fits a build + a couple of
/// follow-through steps and a plain Q&A stops after one (DONE). The user's Stop reaches the turn (control.jsonl),
/// and MAX_ITERS bounds each step's tool rounds.
const DRIVE_MAX: usize = 6;

/// AUTO-LOOP mode (the desk's chat_loop / chat_loop_afk tiers, now driven SERVER-side). off = a normal bounded
/// turn; on = the veil writes its own next step and drives toward the goal until DONE / no-progress / the cap;
/// afk = the persistent tier — it NEVER accepts an end state (DONE folds into a re-verify+extend drive, the repeat
/// guard is skipped, the cap wraps), so only the user's Stop ends it. Passed on the /messages body (loop: 0|1|2).
const LOOP_OFF: u8 = 0;
const LOOP_ON: u8 = 1;
const LOOP_AFK: u8 = 2;
/// Drive-step cap for loop=ON (desk LOOP_MAX_ITERS): a long autonomous task needs many steps, but a non-afk loop
/// still terminates on its own (DONE / two idle steps / repeat) well before this — it's the runaway backstop.
const LOOP_MAX_STEPS: usize = 30;
/// Drive-step cap for loop=AFK: effectively unbounded (the user explicitly opted into "run until I Stop"). Every
/// step drains control (Stop exits promptly) and compacts the working context, so this large bound is a pure
/// runaway backstop, not a functional limit.
const AFK_MAX_STEPS: usize = 100_000;
/// What loop=AFK injects as the next drive step when the driver declares DONE — the afk tier never accepts an end
/// state, so "done" becomes a re-verify + extend (desk AFK_DRIVE_MSG). RE-GROUNDED to the goal at runtime so the
/// persistent loop can't drift off onto an unrelated task. Only the user's Stop ends afk.
/// What an AFK loop injects when its next step just REPEATS the last one (afk skips the repeat-guard that ends a
/// non-afk loop, so instead of churning the same failing step it steps back, re-grounds, and researches the blocker
/// — the light server-side form of the desk's stuck->research escalation, using the model's own recall/search tools.
/// This is now the FALLBACK, not the plan: prompting writes the real instruction from the transcript tail (see
/// stuckStep). A static nudge fires exactly when the loop is CONFIRMED stuck, which is the one moment a generic
/// "try something different" is worth least and the one moment the tail contains the actual blocker.
const AFK_STUCK_TMPL = "You just repeated the previous step — that is not making progress. STOP repeating it: re-read the goal, and try a DIFFERENT approach. If you're blocked, first recall_hive / web_search the ACTUAL error or unknown, then act on what you learn. Goal: \"{s}\".";
/// What the LOOP HARD STOP writes when it cuts a turn (see loop_refusals). THIRD PERSON, DELIBERATELY.
///
/// This note used to read "(engine: I stopped this turn. …)" and was concatenated onto the model's own narration,
/// which the caller commits as the assistant's durable message. Replay then handed it to the NEXT turn verbatim
/// and unmarked, so the model read a first-person admission of being stuck as its own prior words — and each cut
/// turn appended another copy. Ask such a run "are you stuck?" and it is looking at a growing column of what
/// appear to be its own confessions sitting directly under the question; fixating is the correct reading of that
/// transcript. Nothing here says "I" or "my": the engine narrates what the ENGINE did, the row is stored as
/// `role:"system"` / `kind:"engine"` (see the .stopped arm), and only the newest survives replay (see seedLines).
const LOOP_STOP_NOTE = "[engine: this turn was cut short by the loop guard — the same tool calls kept returning identical results, so more rounds could not make progress. Whatever is already written to the workdir is real: re-read it before redoing that work, and take a different approach.]";
/// STUCK-RECOVERY WRITER (prompting). Reads the same bounded transcript tail the drive picker rides and names the
/// concrete way around the blocker it can see, instead of the template's abstract encouragement.
const STUCK_SYSTEM =
    "You are reading the tail of an autonomous work loop that has just REPEATED the same step instead of making " ++
    "progress. Find the ACTUAL blocker in what you can see — the command that failed, the error text, the file " ++
    "that is missing, the assumption that did not hold — and write the single next instruction that gets around " ++
    "it. Name the concrete thing: the exact error string to look up, the file to read, the different approach to " ++
    "take. Do not restate the goal, do not encourage, do not call tools, do not explain your reasoning.";
const STUCK_QUESTION =
    "Write that next instruction: 2-4 sentences, addressed to the worker as a command. If the blocker is a " ++
    "specific error or unknown, say to look THAT up by name first. Reply with ONLY the instruction.";

/// AFK RE-DRIVE, WRITTEN BY THE PROMPTING ROLE. afk never accepts DONE, and what it posted back in DONE's
/// place was AFK_DRIVE_TMPL — the identical sentence every cycle, no matter what the turn had just built,
/// which is what the loop looked like from the outside ("keep going: re-verify the latest work end-to-end,
/// then pick the most valuable next improvement"). The trio HAS a prompting slot for exactly this, and
/// stuckStep already proves the pattern for the repeat case; this is its twin for the finished case.
///
/// It must ask a DIFFERENT question than the drive inference did. That one offered "next step, or DONE" and
/// the model chose DONE, so re-asking it verbatim just gets DONE again — this one states that the work
/// continues and asks what is genuinely most valuable NEXT, given what the transcript shows was just done.
const AFK_NEXT_SYSTEM =
    "You are reading the tail of an autonomous work loop whose worker has just declared the task finished. It " ++
    "is not finished: this session runs until the human stops it, so there is always a next move. Look at what " ++
    "was ACTUALLY just built or changed and name the single most valuable thing to do next — verify a specific " ++
    "claim that has not been checked, harden a part that is thin, finish an edge the worker skipped, or extend " ++
    "the work toward the goal. Be concrete about WHICH file, command, or behavior. Do not restate the goal, do " ++
    "not congratulate, do not call tools, do not explain your reasoning.";
const AFK_NEXT_QUESTION =
    "Write that next instruction: 1-3 sentences, addressed to the worker as a command, naming the specific " ++
    "target. Reply with ONLY the instruction.";
/// What afk posts back when the prompting model cannot write one (dead backend, empty, tool markup, or it
/// just said DONE again). Deliberately bare: a fixed paragraph pretending to be a considered next step is
/// what this whole path is replacing, so the degraded case should look degraded.
const AFK_KEEP_GOING = "keep going";
/// SEARCH-QUERY FORMULATION (prompting). The swarm's scoutQuery text, kept deliberately close — it is the same
/// job. Terms, not a sentence: a search engine matches documents, not questions.
const SEARCH_QUERY_PROMPT =
    "You convert an intent and a draft query into ONE focused web-search query. Output ONLY the query: at most 10 " ++
    "words, no quotes, no punctuation, no preamble — just the search terms a person would actually type. Keep the " ++
    "proper nouns, versions, error strings and identifiers that pin the search down; drop question words and " ++
    "filler. If the draft query is already the best search, output it unchanged.";
/// TERMINAL BUILD-VERIFY (desk fireTerminalVerify): an armed loop must not accept a bare DONE right after writing
/// files — a model can ANNOUNCE a build it didn't finish. One completeness check (run the tests / write any missing
/// file) is injected before the loop ends; it fires at most once per turn and only when files were actually written.
// "run the project's OWN build" + the import cross-check are load-bearing: an armed build turn accepted DONE
// after a smoke test that exercised one API slice while pages imported component files that were never
// written — the gap only surfaced as webpack errors at deploy time (observed live, c6a5a520a). A whole-project
// build/compile catches missing-reference gaps that spot-checks structurally cannot.
const TERMINAL_VERIFY_PROMPT = "Before calling this done, VERIFY the deliverable actually works AS A WHOLE: if the project has its own build/test entrypoint (a build script, a compiler, a test suite), RUN IT — a full build catches files that import or reference files never actually written, which spot-checking one flow misses. Otherwise run the code directly (run_tests / run_python). If any file the goal requires — or any file the written files import/include — is missing or empty, write it NOW (write_file). Verifying one slice does not verify the whole. If everything is present and works, give your FINAL summary to the user with no further tool calls — do not rewrite files that are already correct.";
/// The AFK twin. Identical evidence demand, opposite ending: the tier-1 text closes with "give your FINAL
/// summary to the user with no further tool calls", which lands one step after LOOP_QUESTION_AFK has said
/// there is no finished state and DONE is not an answer. That sandwich is the contradiction an afk turn
/// could not resolve. The check itself stays — a model can announce a build it did not finish in either
/// tier — only the instruction about what to do once it passes changes.
const TERMINAL_VERIFY_PROMPT_AFK = "Before calling this done, VERIFY the deliverable actually works AS A WHOLE: if the project has its own build/test entrypoint (a build script, a compiler, a test suite), RUN IT — a full build catches files that import or reference files never actually written, which spot-checking one flow misses. Otherwise run the code directly (run_tests / run_python). If any file the goal requires — or any file the written files import/include — is missing or empty, write it NOW (write_file). Verifying one slice does not verify the whole. If everything is present and works, say so in one line, then state what is still THIN or missing and continue with the next most valuable step — do not rewrite files that are already correct, and do not stop.";

/// The single question the drive inference answers between settled steps: it either names the next concrete
/// step (which becomes a synthetic user turn) or replies DONE. Carries the LOOP_SYSTEM intent inline rather than
/// swapping the system prompt (a server-turn simplification of desk's dedicated LOOP_SYSTEM driver turn).
const LOOP_QUESTION =
    "What is the single next concrete step toward the goal? Reply with ONLY that next instruction, or reply " ++
    "exactly DONE if the goal is fully achieved.";
/// The AFK drive question. afk was built as tier-1-plus-overrides: it asked "next step, or DONE", the model
/// answered DONE, and the engine overrode that with a canned "keep going" — so every cycle the model reached a
/// conclusion the loop then contradicted, and the only way to obey both was to invent more work. Observed live:
/// posted, verified, posted again, verified again, forever. In afk the DONE branch simply should not be offered;
/// a session the user opted into running until they stop it has no end state to ask about. Tier 1 keeps
/// LOOP_QUESTION exactly as it was — its stop conditions are the whole point of that tier and they work.
const LOOP_QUESTION_AFK =
    "This session runs until the human stops it, so there is no finished state to report and DONE is not an " ++
    "answer. Judge what has ALREADY been accomplished from the conversation above and do not redo or re-verify " ++
    "it. What is the single most valuable next step — something not yet done? Reply with ONLY that instruction.";

/// POST-ANSWER CRITIQUE (was REFLECT): the THINKING model reviews the answer the user has ALREADY been given and
/// may APPEND a short correction as its own separate message. It can never rewrite what was said.
///
/// The predecessor re-generated the answer and SWAPPED it, which froze the chat ~8s and replaced text the user had
/// watched type out — so it was gated on the answer not having streamed. streamOnDelta sets that flag on the first
/// delta, so on any healthy streaming backend the gate could only open when the stream had FAILED: the trio's one
/// evaluative faculty was alive exclusively on the error path. Append-only removes the reason for the gate rather
/// than the gate's protection — the committed answer is never touched, so there is nothing left to preserve.
/// Still gated to the FIRST answer of a turn (drive == 0), to unplanned turns, and to answers >= REFLECT_MIN
/// bytes, so a terse reply or a build's intermediate narration never pays for it.
/// PLAN-BOARD: how many subtasks one turn works before pausing (the plan persists, so "continue" resumes the
/// rest). Bounds a big plan's turn length — each subtask is a full agentic pass, so this * MAX_ITERS is the ceiling.
const PLAN_STEPS_PER_TURN: usize = 8;
/// The decomposition prompt. It asks for TWO things: the routed subtask list, and the turn's ACCEPTANCE CONTRACT
/// (objective / done_when / watch_for). The contract is the load-bearing half — it is the only channel the
/// THINKING model has into the CODING model's own prompt in the turn where it thinks (see the TURN BRIEF note at
/// the injection site), and it turns each subtask from a bucket of prose into something checkable. Every added
/// field is OPTIONAL on the wire: a model that answers with the old {"plan":[…]} shape still yields a working
/// board (plan.parseDecomposition / plan.parseBrief both degrade to empty rather than failing).
const PLAN_PROMPT =
    "Decompose the user's request into an ordered list of concrete subtasks, and for EACH pick the best ROUTE: " ++
    "\"hive\" (delegate to a swarm of AI minds — a big or parallelizable build/research chunk), \"research\" (you " ++
    "need to learn or look something up first), or \"inline\" (a small, direct step you just do yourself). Also " ++
    "state what DONE means before any work starts: one-sentence \"objective\", a \"done_when\" list of conditions " ++
    "that can each be CHECKED (a command that must exit clean, a file that must exist, an output that must " ++
    "appear — not \"it works well\"), and a \"watch_for\" list of failure modes you expect on THIS task. Give each " ++
    "subtask its own short \"done_when\" too, and a \"tool_hint\" naming the single tool you expect it to use " ++
    "(e.g. write_file, edit_file, read_file, list_dir, poll, web_fetch, read_url, web_search, read_doc, " ++
    "recall_hive, run_python, open_subchat, cast — or \"\" if unsure). Reply with ONLY compact JSON: " ++
    "{\"objective\":\"…\",\"done_when\":[\"…\"],\"watch_for\":[\"…\"],\"plan\":[{\"task\":\"…\",\"route\":" ++
    "\"hive|research|inline\",\"done_when\":\"…\",\"tool_hint\":\"…\"}, …]}. If the request is a simple question, " ++
    "a greeting, or a single trivial step that needs no plan, reply exactly {\"plan\":[]}.";

// ---------------------------------------------------------------------------------------- RECON BEFORE PLAN
//
// THE PROBLEM. PLAN_PROMPT decomposes the user's WORDS. Nothing has run yet, so the subtask list, the routes
// and every `done_when` are written against an IMAGINED project — and the board is DURABLE, so a
// decomposition built on a wrong picture is what every later "continue" resumes. The failure is quiet: the
// plan reads as perfectly reasonable, it just describes a different codebase than the one on disk.
//
// THE FIX. Look, then plan. Two rungs, cheapest first:
//   Rung 1 (FREE) — the engine already surveys the workdir into the file ledger. That block now goes into the
//     plan prompt; until now it reached only the chat inference, which made the planner the one participant
//     in the turn that could not see what already existed.
//   Rung 2 (one inference + up to RECON_MAX_PROBES read-only tool calls) — the model names what it needs to
//     FIND OUT, the engine runs those probes, and the findings enter the plan prompt as evidence.
//
// WHY THIS IS AFFORDABLE. It fires only when shouldPlan has already committed to a decomposition round trip,
// so ordinary Q&A latency is untouched. And the probe list is enforced against RECON_TOOLS BY THE ENGINE, not
// by the prompt: a model that asks for write_file or run_python has it dropped, because a recon pass must not
// be able to change the thing it exists to observe.
const RECON_MAX_PROBES: usize = 3;

/// Read-only, checked here rather than trusted from the prompt. Nothing that writes, executes, spawns or
/// spends is on this list, by construction.
const RECON_TOOLS = [_][]const u8{ "list_dir", "read_file", "read_doc", "recall_hive", "recall", "web_search", "read_url" };

/// Bound on the evidence block handed to the planner. Big enough for a directory listing plus a couple of file
/// heads; small enough that it cannot crowd out the request it is supposed to inform.
const RECON_BLOCK_MAX: usize = 4000;

const RECON_SYSTEM =
    "You are about to plan a task, but you have not looked at anything yet. Before planning, name the few " ++
    "things you most need to FIND OUT: what the working directory already contains, what a key file actually " ++
    "says, what this project already is, an unfamiliar API you are about to build against. Prefer looking at " ++
    "what already exists over searching the web. You are gathering evidence, not doing the work.";

const RECON_QUESTION =
    "List at most 3 read-only probes to run first. Reply with ONLY compact JSON: " ++
    "{\"probes\":[{\"tool\":\"list_dir|read_file|read_doc|recall_hive|recall|web_search|read_url\",\"args\":{…}}, …]} " ++
    "— args are that tool's own arguments (list_dir {\"path\":\".\"}, read_file {\"path\":\"…\"}, " ++
    "recall_hive {\"query\":\"…\"}, web_search {\"query\":\"…\"}, read_url {\"url\":\"…\"}). " ++
    "If the request needs no looking — it is self-contained, or purely conversational — reply exactly {\"probes\":[]}.";

// ------------------------------------------------------------------------------------ MID-TURN COURSE CHECK
//
// THE PROBLEM. This turn's one evaluative faculty (the post-answer critique below) runs AFTER the user already
// has the answer, is gated to the FIRST step of the turn, and is append-only by design. So on drive step 7 of
// 30 — mid-build, precisely where a wrong approach compounds into more work — nothing is watching. The drive
// picker chooses the next step, but it is a CONTINUATION writer: its question is "what next", never "is this
// still right".
//
// THE FIX. Between the picker naming a step and that step being committed, one bounded reviewer reads the
// goal, the acceptance contract and the recent tail, and either abstains or REPLACES the next step with a
// correction. It changes only what has not happened yet — the same safety property the post-answer critique
// has, moved to where it can still alter the outcome.
//
// ABSTAIN IS THE DESIGNED COMMON CASE, exactly as for the post-answer critique. A reviewer that always finds
// something is a reviewer that is inventing, and it would drag every drive step sideways in the name of
// improving it. Silence is the correct output for a loop that is working.
const COURSE_ABSTAIN = "OK";
const COURSE_MIN: usize = 40;

const COURSE_SYSTEM =
    "You are reviewing an autonomous work loop MID-TASK, between steps. You can see the goal, what counts as " ++
    "done, and the recent work. Judge ONE thing: is the next step about to be taken the right move toward the " ++
    "goal? Answer with the single word OK unless something is genuinely wrong — the work has drifted off the " ++
    "goal, it is solving a problem it invented rather than the one that was asked, it is about to build on " ++
    "something already known to be broken, it is repeating an approach that already failed, or it is about to " ++
    "claim progress the evidence does not support. Being able to imagine a marginally better step is NOT a " ++
    "reason to intervene. Do not call tools. Do not explain yourself.";

const COURSE_QUESTION_HEAD = "The next step is about to be:\n";
const COURSE_QUESTION_TAIL =
    "\n\nReply with exactly OK if that step should proceed. Otherwise reply with ONLY the corrected " ++
    "instruction — 2 to 4 sentences, addressed to the worker as a command, naming the concrete thing that is " ++
    "wrong and what to do instead.";

const REFLECT_MIN: usize = 240;
/// The reply that means "nothing worth saying", and the shortest note that is worth appending. ABSTAIN IS THE
/// DESIGNED COMMON CASE: an always-on footer is noise the user learns to skip past, and it bills output tokens on
/// every substantial turn for the privilege. Anything shorter than CRITIQUE_MIN is the abstain token, a variant of
/// it, or too vague to act on — all of which are silence.
const CRITIQUE_ABSTAIN = "OK";
const CRITIQUE_MIN: usize = 40;
/// The longest note that is still a CORRECTION and not a rewrite of the answer. Past this the model has started
/// re-answering, and appending a second full answer under the first is the swap failure wearing a new hat.
const CRITIQUE_MAX: usize = 600;
const CRITIQUE_PROMPT =
    "The answer above has ALREADY been sent to the user and CANNOT be changed — you are not rewriting it. Look for " ++
    "exactly one class of thing: a MATERIAL problem that would mislead them or make them act wrongly — a factual " ++
    "or logical error, a claim that contradicts what the tools actually returned, or a missing caveat that changes " ++
    "the conclusion. Style, tone, polish, and \"it could go deeper\" are NOT material. Most answers have no such " ++
    "problem, so OK is the normal and expected reply: answer with exactly OK unless you can name something " ++
    "specific that is wrong. If there IS such a problem, reply with 1-3 sentences addressed to the user stating " ++
    "the correction directly and nothing else — do not restate or summarize the answer, and do not mention that a " ++
    "review happened.\n\n" ++
    "THE TOOL RECORD ABOVE IS GROUND TRUTH AND YOU MAY NOT CONTRADICT IT. It lists every tool this turn " ++
    "actually ran. If it shows a tool ran, the assistant DID have and DID use that capability — never reply that " ++
    "the assistant cannot do something, has no such tool, or fabricated an action the record shows it performed. " ++
    "Denying a real action is itself a false correction, and a confident false correction is worse than staying " ++
    "silent. What the record does NOT settle is whether the effect reached the USER: a tool can succeed on this " ++
    "machine and still not produce what the user asked for. That gap is worth a correction; a flat denial of the " ++
    "assistant's capabilities is not.";

/// Serializes edit_file's micro-VCS commits (vcs.zig) across concurrent chat turns IN THIS gateway process —
/// the exact role chat_tools.chat_vcs_mtx plays for /api/v1/chat/tool. A live hive cast building in the same
/// conversation dir is a SEPARATE process with its own such lock; both sides still rebase onto the HEAD they
/// read and land via a same-dir atomic rename, so the cross-process window is microseconds (see chat_tools.zig).
var chat_vcs_mtx: std.Io.Mutex = .init;

const SYSTEM_PROMPT =
    "You are veil, a helpful coding and research assistant. You have tools: web_search / web_fetch / read_url " ++
    "for the live web, read_file / write_file / edit_file / list_dir / run_python / run_tests to build and run " ++
    "code in your working directory, and observe / recall / recall_hive for memory. Use a tool when it genuinely " ++
    "helps; call tools one or more times, then when you have what you need reply to the user directly in plain " ++
    "prose. Keep answers concrete and grounded in what the tools actually returned.\n" ++
    "STORED DOCUMENTS. absorb files a document into its own memory scope; recall_hive answers TARGETED questions " ++
    "about it. For WHOLE-document work (summarize, outline, review), recall fragments are NOT the document -- " ++
    "page it in order with read_doc and work from those pages; if read_doc has nothing, fall back to read_file " ++
    "on the source.\n" ++
    "SIDE-THREADS. When a distinct sub-idea deserves its own focused thread (a tangent the user raised, a " ++
    "parallel angle of the main work), open_subchat branches this chat into a tab that starts working it " ++
    "immediately -- same files, same memory, so its findings flow back here. Lighter than a hive.\n" ++
    "WAITING. Never guess whether something finished and never re-check blind -- poll watches a file, url, " ++
    "port, process, probe command, or your cast to completion in bounded steps and reports what it saw; on " ++
    "timeout, poll again ONLY while the log shows progress - after 2-3 no-progress timeouts STOP waiting: act on " ++
    "what you have, or tell the user it hasn't arrived.\n" ++
    "HOW YOU WORK A TASK. Your FIRST move on any non-trivial request is to BREAK IT DOWN into a concrete list of " ++
    "smaller subtasks -- however many it takes, a handful or dozens -- and show the user that plan. Then work the " ++
    "list, and for EACH subtask decide the best route: (a) DELEGATE TO A HIVE -- if a team building or " ++
    "researching in parallel would do it better or faster, `cast` a swarm for that part (it builds in THIS " ++
    "conversation, so its files sit alongside yours), then GUIDE that swarm: `swarm_status` to see how it's " ++
    "doing, `steer_swarm` to send its minds a live directive or retarget their goal, `swarm_asks` to see " ++
    "questions its minds raised for you and `answer_swarm` to unblock them, `stop_swarm` when it's done or off " ++
    "track. When a user asks you to \"use a hive\", do exactly that -- cast one, don't build it yourself. " ++
    "(b) LEARN FIRST -- if you're missing knowledge for a part, research it (web_search / read_url / recall_hive) " ++
    "BEFORE acting instead of guessing. (c) DO IT YOURSELF -- for a small, direct change, build it inline " ++
    "(write_file / edit_file / run_python). Revise the plan as you learn. Keep coordinating -- casting, steering, " ++
    "researching, building -- and narrate each move so the user can follow the work, until the goal is truly met.\n" ++
    "GROUND YOURSELF -- you have NO live knowledge of the current world. For anything time-sensitive or that could " ++
    "have changed (news, events, prices, versions, releases, 'latest'/'today'/'now', who currently holds a role), " ++
    "OR a specialized/unfamiliar domain you are about to build in, recall_hive first and, if that is thin, " ++
    "web_search -- then answer FROM what you find. NEVER fabricate current events, dates, statistics, or news; if " ++
    "you cannot answer from durable general knowledge with high confidence, look it up instead of guessing.\n" ++
    "CASTING. A `cast` swarm is a parallel SUB-AGENT -- reach for it when many minds beat one: broad web research " ++
    "and current events, scouting unfamiliar tech before you build, analyzing a large body of material. A quick " ++
    "strike runs a couple of minutes; for a GENUINELY BIG job the user wants the hive to own (deep-dive + document " ++
    "a whole codebase, a long investigation, a full app) cast a SUSTAINED hive (mode \"continuous\", enough " ++
    "`minutes`) with a CONCRETE goal and the exact deliverable `files` declared -- do not grind a big job yourself " ++
    "one step at a time. For a small, direct change, build it inline yourself (you are faster and more reliable " ++
    "hands-on). An explicit 'cast a swarm' / 'use a hive' is a COMMAND -- do it. While a hive runs you are its " ++
    "ORCHESTRATOR: swarm_status to watch it, steer_swarm when it drifts, answer_swarm to unblock a mind; never " ++
    "build a rival copy of what it is mid-way through; when it finishes, gather its files/findings and answer from " ++
    "them. Do not cast for greetings, small talk, or timeless facts you know confidently.\n" ++
    "ACT, DON'T PROMISE -- never end a reply with a promise of future action ('I'll run...', 'Let me check...') " ++
    "without the tool call in the SAME reply: every reply either calls a tool or delivers the result. After an " ++
    "action that CHANGES something, VERIFY the outcome before declaring success -- run_tests, or read the resource " ++
    "back; a 'Ready' log line or a 2xx status is not proof it persisted.\n" ++
    "BUILD DISCIPLINE -- write code to FILES with write_file/edit_file, do not paste whole files into the chat. " ++
    "DON'T THRASH: once a file is written, do not rewrite the whole thing next turn -- if it is correct, move to " ++
    "the next file/step; if it needs a change, edit_file the specific part. read_file before you edit. After " ++
    "writing code, run_tests (or run_python) to verify, read the result, fix, and repeat until it actually works.\n" ++
    "DURABLE MEMORY. Anything PERSONAL to THIS user that should persist across conversations -- a key, login, " ++
    "credential, preference, or a fact about them or their environment -- record with a `REMEMBER:` line, NOT " ++
    "observe (observe is the shared hive's knowledge). Format, one per line, alongside your normal reply:\n" ++
    "REMEMBER: [category] the fact to keep   (category is one word: key, login, preference, or fact)\n" ++
    "To drop a fact that is now wrong: `FORGET: <a few words identifying it>`. These lines are STRIPPED from what " ++
    "the user sees, so do NOT also write a prose header like \"I've remembered:\" -- just emit the bare REMEMBER:/" ++
    "FORGET: line(s). Use them proactively when the user reveals a durable fact (e.g. they mention deploying to " ++
    "us-west-2 -> `REMEMBER: [preference] deploys to us-west-2`). Facts already under YOUR MEMORY need no repeat. " ++
    "Credential VALUES are withheld from prompts -- YOUR MEMORY shows them masked as [withheld]; when a task " ++
    "actually needs one, fetch it with get_credential and use it directly in that call. Never repeat a fetched " ++
    "value into replies, observe/share notes, REMEMBER lines, or files beyond the immediate use.\n" ++
    "PLAIN PUNCTUATION. Write with ASCII punctuation only: never em or en dashes (use a comma, a colon, or a " ++
    "hyphen), never curly quotes, never the single-character ellipsis. This applies to FILES you write as much " ++
    "as to replies: the engine folds the reply text, but a file keeps exactly what you typed.";

/// The SMALL-tier twin of SYSTEM_PROMPT, paired with TURN_TOOLS_COMPACT the same way the full prompt pairs
/// with the full belt. The full prompt is a 6KB orchestration curriculum - cast/steer_swarm/answer_swarm
/// doctrine, "recall_hive first", open_subchat, poll - delivered to a model whose compact belt advertises NONE
/// of those names. That is the recall_hive bug class at its source: the observed 12B never saw `cast` in its
/// tools array, the PROMPT told it to cast ("do exactly that"), and knownToolName let the full-schema name
/// through - so it spent four rounds failing to orchestrate a swarm instead of writing the file it was asked
/// for. This twin names ONLY tools the compact belt advertises, keeps the behavioral spine (ground yourself /
/// act don't promise / build discipline / REMEMBER lines), and drops every delegation concept - a small model
/// works alone, one step at a time. Also ~4KB shorter, which a 12B feels on every single inference.
///
/// get_credential is deliberately NOT mentioned (the compact belt drops it): masked values stay masked, and a
/// small model telling the user it cannot read a credential beats it fumbling a fetch-and-leak.
const SYSTEM_PROMPT_COMPACT =
    "You are veil, a helpful coding and research assistant. You have tools: web_search / web_fetch for the " ++
    "live web; read_file / write_file / edit_file / list_dir / delete_file for files; " ++
    "run_python / run_tests to run code; recall / observe / read_doc / pixel_search for memory " ++
    "and stored documents; browser_navigate / browser_read / browser_click / browser_type to drive a real " ++
    "browser page. Those are ALL your tools - call them by exactly those names. Use a tool when it genuinely " ++
    "helps, then reply in plain prose, grounded in what the tools actually returned.\n" ++
    "HOW YOU WORK. Break a non-trivial request into a short list of steps and work them IN ORDER, yourself, one " ++
    "tool call at a time. Do not try to delegate - you have no sub-agents; you are the one doing the work. If a " ++
    "tool errors, read the error and CHANGE something (arguments, tool, approach) - never repeat the identical " ++
    "call hoping for a different result.\n" ++
    "run_python IS YOUR EXECUTOR - the DEFAULT whenever no other tool on the belt fits, because it is the only " ++
    "way you can execute anything at all. Real Python 3, real network: HTTP with your own headers/auth/POST " ++
    "body, APIs no dedicated tool covers, parsing, math, data and file work. Reach for it instead of telling " ++
    "the user something is impossible. Read the LAST line of a traceback - that is the actual error; a " ++
    "name-resolution failure means THAT hostname is wrong (check it against what you were told), not that the " ++
    "network is down.\n" ++
    "GROUND YOURSELF - you have NO live knowledge of the current world. For anything time-sensitive (news, " ++
    "prices, versions, 'latest'/'today'/'now'), recall first and, if that is thin, web_search - then answer FROM " ++
    "what you find. NEVER fabricate current events, dates, statistics, or news.\n" ++
    "STORED DOCUMENTS. recall answers TARGETED questions about an ingested document; for WHOLE-document work " ++
    "(summarize, outline, review) page it in order with read_doc - recall fragments are NOT the document.\n" ++
    "ACT, DON'T PROMISE - never end a reply promising future action ('I'll check...') without the tool call in " ++
    "the SAME reply. After a change, VERIFY: run_tests or read the resource back before declaring success.\n" ++
    "BUILD DISCIPLINE - write code to FILES with write_file/edit_file, do not paste whole files into chat. " ++
    "read_file before you edit; once a file is right, move on - do not rewrite it next turn.\n" ++
    "DURABLE MEMORY. A personal fact about THIS user worth keeping across conversations gets a line, alongside " ++
    "your normal reply:\nREMEMBER: [category] the fact   (category: key, login, preference, or fact)\n" ++
    "To drop a wrong fact: FORGET: <a few words identifying it>. These lines are stripped from what the user " ++
    "sees, so emit them bare, no prose header.\n" ++
    "PLAIN PUNCTUATION. ASCII only: no em or en dashes (use a comma or a hyphen), no curly quotes, no " ++
    "single-character ellipsis. In replies AND in files you write.";

/// The chat turn's tool surface = the shared mind-tool SCHEMA + the veil's ORCHESTRATION verbs (cast / steer /
/// stop / status). The orchestration verbs are handled in-process by orchTool (deploy_service + app.sup), NOT by
/// tools.execute - the swarm minds themselves never get these (a mind can't spawn sibling swarms). Comptime
/// concatenation (both are comptime `\\` strings), joined by a comma into the "tools":[ … ] array body.
const ORCH_TOOLS =
    \\{"type":"function","function":{"name":"cast","description":"Deploy a SWARM (a hive of AI minds) to work on a goal in parallel, in THIS conversation's build dir so its files co-exist with yours. Use for a big or parallelizable build/research task you want a team to carry out while you guide them. Returns a swarm id; watch it with swarm_status, guide it with steer_swarm, end it with stop_swarm.","parameters":{"type":"object","properties":{"goal":{"type":"string","description":"what the swarm should accomplish. LIVE CONTRACT: the engine parses VERIFY:/SMOKE:/PROBE: out of this text and SHELLS the rest of that line every round as the hive's acceptance score (VERIFY: build/tests, SMOKE: boot the deliverable, PROBE: health-check). The body must be a RUNNABLE command — 'VERIFY: npm test', not 'VERIFY: make the tests pass'. Never write these tokens as prose emphasis; omit them and the hive scores on goal coverage instead."},"minds":{"type":"integer","description":"how many minds (default 3)"},"minutes":{"type":"integer","description":"time budget (0 = server default)"},"mode":{"type":"string","enum":["cast","continuous"],"description":"cast = fast one-shot strike; continuous = sustained hive"},"files":{"type":"string","description":"declared deliverable files, comma/newline separated — adopted verbatim as the blueprint"}},"required":["goal"]}}},
    \\{"type":"function","function":{"name":"steer_swarm","description":"Send LIVE guidance to a RUNNING swarm — a priority directive every mind reads at its next round (course-correct, add a constraint, unblock a mind). Or pass `goal` to retarget the whole hive.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id from cast/swarm_status"},"text":{"type":"string","description":"the guidance/directive for the minds"},"goal":{"type":"string","description":"optional: a new goal to retarget the hive"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"stop_swarm","description":"Stop a running swarm (cooperative; takes effect at its next round). Its files + findings are kept.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"swarm_status","description":"Check a swarm's state: whether it is running or finished, how many minds, and whether it has produced a result yet.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"swarm_asks","description":"List the OPEN questions a running swarm's minds have raised for you (via their ask_veil tool) and not yet been answered. Check this while a swarm runs — a mind may be blocked waiting on a decision only you can make. Each ask has an ask_id, the mind that asked, and the question.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"answer_swarm","description":"Answer a mind's open question (from swarm_asks). Your answer lands in that mind's inbox as a priority directive on its next round, unblocking it.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the swarm id"},"ask_id":{"type":"string","description":"the ask_id from swarm_asks"},"mind":{"type":"string","description":"the mind that asked (from swarm_asks)"},"text":{"type":"string","description":"your answer/decision for the mind"}},"required":["id","ask_id","mind","text"]}}},
    \\{"type":"function","function":{"name":"schedule_task","description":"Create a SCHEDULED TASK when the user asks for something to happen later or repeatedly ('every morning at 9', 'in 20 minutes', 'daily news digest'). Each firing runs a fresh UNATTENDED chat turn with this same provider, and the task keeps its own memory across runs. The prompt must be SELF-CONTAINED (a run cannot see this conversation) — put concrete specifics (locations, formats, file names) in details. kind 'once' needs in_min OR at_hm; 'every' needs every_min; 'daily' needs hm.","parameters":{"type":"object","properties":{"name":{"type":"string","description":"short task name"},"prompt":{"type":"string","description":"the self-contained instruction each run executes"},"details":{"type":"string","description":"pinned specifics every run should use (optional)"},"kind":{"type":"string","enum":["once","every","daily"]},"in_min":{"type":"integer","description":"once: fire this many minutes from now"},"at_hm":{"type":"string","description":"once: fire at the next local occurrence of HH:MM"},"every_min":{"type":"integer","description":"every: interval in minutes"},"hm":{"type":"string","description":"daily: local wall-clock HH:MM"}},"required":["name","prompt","kind"]}}},
    \\{"type":"function","function":{"name":"schedule_update","description":"Revise an EXISTING scheduled task in place (partial update — ONLY the fields you pass change; everything else keeps its stored value). This is how a task self-heals and self-improves over time: during a scheduled run, call it on YOUR OWN task id (given in the run context) to fold what this run learned into the prompt/details, tune the cadence, or repair a broken definition; in normal chat, use it when the user asks to change an existing schedule. Always pass reason — it is recorded into the task's cross-run memory so future runs know why the definition changed. Provider credentials cannot be changed here. Revisions must preserve the task's goal.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the task id (a scheduled run's own id is in its RUN CONTEXT; schedule_list shows all ids)"},"name":{"type":"string","description":"new short task name"},"prompt":{"type":"string","description":"the new SELF-CONTAINED instruction future runs execute (replaces the old prompt verbatim)"},"details":{"type":"string","description":"new pinned specifics future runs should use (replaces the old details verbatim — restate what should survive)"},"kind":{"type":"string","enum":["once","every","daily"]},"every_min":{"type":"integer","description":"every: new interval in minutes"},"hm":{"type":"string","description":"daily: new local wall-clock HH:MM"},"in_min":{"type":"integer","description":"once: re-arm to fire this many minutes from now"},"enabled":{"type":"boolean","description":"false pauses the task (it keeps its memory and can be re-armed later); true re-enables it"},"reason":{"type":"string","description":"one sentence: WHY this revision (recorded in task memory for future runs)"}},"required":["id","reason"]}}},
    \\{"type":"function","function":{"name":"schedule_list","description":"List the user's scheduled tasks (id, name, kind, next due, run count, enabled, plus FAILING/self-tuned health markers) — check before creating a duplicate, and to find ids for schedule_update/schedule_delete.","parameters":{"type":"object","properties":{},"required":[]}}},
    \\{"type":"function","function":{"name":"schedule_delete","description":"Delete a scheduled task by its id (from schedule_list). Use when the user asks to cancel/remove a schedule.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"the task id"}},"required":["id"]}}},
    \\{"type":"function","function":{"name":"sync_dir","description":"PROJECT a folder from the user's machine into this conversation's workdir (read-only copy, hash-diffed: only changed files transfer, the source is NEVER written back to). Use when the user points you at a project that lives OUTSIDE the workdir — an app inside a game-engine folder, a repo elsewhere on disk, an immutable system — so you AND any hive you cast can work with its files. Re-run it to refresh (cheap: unchanged files skip). Text files only, capped 64 files / 4MB — project the SPECIFIC subfolder that matters, not a whole engine install.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"ABSOLUTE folder on the user's machine (e.g. C:/dev/mygame/src or /home/u/app — no ~, expand it first)"},"as":{"type":"string","description":"optional folder name inside the workdir (default: the source folder's name)"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"open_subchat","description":"BRANCH this conversation into a SUB-CHAT (a tab of this chat, max 5) and start it working on a goal — for a side-thread worth its own focused context: a tangent the user raised, a parallel angle of the main work, a deep-dive that would clutter this thread. The sub-chat is a full conversation in the SAME family: one shared workspace (files), one shared memory (what it learns becomes recallable here and vice versa), and it sees this chat's live context every turn. Its first turn starts immediately, server-side, with this turn's models. Lighter than cast (one focused conversation, not a swarm). Tell the user which tab it opened.","parameters":{"type":"object","properties":{"goal":{"type":"string","description":"the sub-chat's first instruction — self-contained and concrete (it also receives the primary's live context automatically)"}},"required":["goal"]}}}
;
// The chat surface = the REACHABLE mind-tool subset (tools.CHAT_SCHEMA, not the full ~33-tool SCHEMA whose
// swarm-mind/host-sim/RSI-only verbs a solo chat turn can't use) + the veil's orchestration verbs. Trimming the
// unreachable tools roughly halves the cold-cache prefill re-sent on every drive step and stops the model emitting
// an off-surface tool call that would burn a whole agentic round-trip. tools.execute still dispatches the full
// SCHEMA, so nothing breaks if a tool is ever re-advertised. See tools.CHAT_SCHEMA for the exact keep-set + why.
const TURN_TOOLS = tools.CHAT_SCHEMA ++ "," ++ ORCH_TOOLS;

/// The browser/pixel/MCP block every chat turn carries — see the accessibility directive where turn_tools is
/// bound in runInnerAgentic.
const EXTRA_TOOLS = tools.BROWSER_SCHEMA ++ ",\n" ++ tools.PIXEL_SCHEMA ++ ",\n" ++ tools.MCP_SCHEMA;

/// This turn's tools array, in the two shapes a caller can have. Both are STATIC strings built at comptime: the
/// choice is made by the caller's CAPS and by nothing else. It must never vary with message content, or the
/// provider's prompt-prefix cache misses and the whole prefill is re-billed on every inference (same hazard the
/// recall-placement note in runTurn describes).
const TURN_TOOLS_FULL = TURN_TOOLS ++ ",\n" ++ EXTRA_TOOLS;

/// The `.sandboxed` projection. tools.sandboxSchema DERIVES it from the sandbox allowlist, so it drops exactly
/// what tools.execute's gate refuses before any tool logic runs: all browser_*, pixel_ingest, pixel_capture,
/// mcp_discover, mcp_call, stage_file, get_credential, run_python, run_tests — ~8 KB of schema that was being
/// advertised to every non-admin and re-sent on every inference of their turn, inviting calls that could only
/// come back as a refusal. pixel_search outlives its two PIXEL_SCHEMA neighbours because it is sandbox-safe
/// (local retrieval over the caller's own attachments); the removal is per-tool, not per-block.
///
/// ORCH_TOOLS goes through the SAME filter. This line used to say it deliberately did not, on the grounds
/// that "orchTool dispatches the orchestration verbs BEFORE the sandbox gate, so they do run for a
/// sandboxed caller and dropping them would remove working capability". That argues against dropping the
/// block WHOLESALE — which is not what sandboxSchema does. It is allowlist-derived and per-tool, and
/// SANDBOX_TOOLS already carries the three orchestration verbs that genuinely work for a sandboxed caller
/// (tools.zig: "read-only swarm observation" — swarm_status, swarm_asks, stop_swarm). The other nine are
/// refused by orchTool's own FIRST statement, before any dispatch (cast, steer_swarm, answer_swarm,
/// sync_dir, open_subchat, schedule_*), so advertising them did precisely what the paragraph above
/// condemns: invited calls that could only come back as a refusal — and each one costs a whole agentic
/// round-trip, not just the schema bytes. Filtering keeps every verb that works and drops only those that
/// cannot. (Ledger 0081.)
const TURN_TOOLS_SANDBOXED = blk: {
    var out: []const u8 = tools.sandboxSchema(tools.CHAT_SCHEMA) ++ "," ++ tools.sandboxSchema(ORCH_TOOLS);
    const extra = tools.sandboxSchema(EXTRA_TOOLS);
    if (extra.len > 0) out = out ++ ",\n" ++ extra; // empty ⇒ no trailing comma into the tools array
    break :blk out;
};

/// Comma-join the non-empty projections into one tools array. A projection CAN come back empty — the compact
/// belt drops every orchestration verb, so tools.compactSchema(ORCH_TOOLS) is "" — and a blind `++ ",\n" ++`
/// would then emit a leading or doubled comma and hand the provider a malformed tools array.
fn joinDefs(comptime parts: []const []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (parts) |p| {
        if (p.len == 0) continue;
        out = if (out.len == 0) p else out ++ ",\n" ++ p;
    }
    return out;
}

/// The SMALL-tier projections (modelcfg.Tier.small — ≤24B, or a ≤15k window): the two CAPS variants with
/// tools.compactSchema applied. See tools.COMPACT_TOOLS for exactly what drops and the live 12B evidence for
/// why. Two more comptime strings cost a turn nothing, and the pick stays a pure function of (caps, tier) —
/// both turn-stable — so the tools array is still byte-identical across the turn's inferences and the
/// prompt-prefix cache keeps hitting, exactly as the note on TURN_TOOLS_FULL requires.
///
/// This does NOT remove capability: execute() dispatches the full SCHEMA regardless, so a small model that
/// names a dropped tool from memory still runs it (knownToolName relies on that).
// terseSchema over compactSchema: the small tier keeps every verb the belt already served and pays a large
// model's prose for none of them. See tools.TERSE_DESC — the membership lever is spent, this is the one left.
const TURN_TOOLS_COMPACT = joinDefs(&.{
    tools.terseSchema(tools.compactSchema(tools.CHAT_SCHEMA)),
    tools.terseSchema(tools.compactSchema(ORCH_TOOLS)),
    tools.terseSchema(tools.compactSchema(EXTRA_TOOLS)),
});

const TURN_TOOLS_SANDBOXED_COMPACT = joinDefs(&.{
    tools.terseSchema(tools.compactSchema(tools.sandboxSchema(tools.CHAT_SCHEMA))),
    tools.terseSchema(tools.compactSchema(tools.sandboxSchema(ORCH_TOOLS))),
    tools.terseSchema(tools.compactSchema(tools.sandboxSchema(EXTRA_TOOLS))),
});

/// Resolve THIS turn's granted recipe set (I3): for an admin (.full) the whole registry; for a sandboxed
/// caller the registry ∩ the user's tool_grants. Called ONCE per turn (turn-stable), so the granted tools'
/// advertised schemas do not vary with message content — same prefix-cache discipline the two static
/// TURN_TOOLS variants follow. Returns a gpa-owned slice of pointers INTO the registry arena (caller frees the
/// slice with gpa.free; the Recipes themselves are owned by the registry and outlive the turn per the
/// resolve-at-turn-boundary contract in recipes.zig). Empty — the feature wholly INERT, no behaviour change —
/// when no registry is wired onto App yet, the registry is empty, or the caller holds no grants.
///
/// REQUIRES `app.recipes: ?*recipes.Registry` — the loaded recipe registry, owned/reloaded by the admin route
/// (a file this agent does not own). Null-safe: absent ⇒ no grants. See the run-report for the exact contract.
fn resolveGrants(app: *App, uid: u64, is_admin: bool, gpa: std.mem.Allocator) []const *const recipes.Recipe {
    const reg = app.recipes;
    if (reg.count() == 0) return &.{};
    var list: std.ArrayListUnmanaged(*const recipes.Recipe) = .empty;
    if (is_admin) {
        for (reg.recipes) |*r| list.append(gpa, r) catch {};
    } else {
        // Snapshot the user once and match the registry against tool_grants. hasToolGrant walks the snapshot's
        // grant slice (a free fn — no lock), matching how every other field is read off a userById snapshot.
        const u = app.auth.userById(uid) orelse return &.{};
        for (reg.recipes) |*r| {
            if (http.Auth.hasToolGrant(u, r.name)) list.append(gpa, r) catch {};
        }
    }
    return list.toOwnedSlice(gpa) catch &.{};
}

/// This turn's tools array with the granted recipes' schemas appended (I6/schema advertising). Built ONCE per
/// turn: the base is the caller's static TURN_TOOLS variant (chosen by CAPS and nothing else), then each
/// granted recipe's function def is appended — turn-stable and byte-identical across every inference of the
/// turn (grants don't vary with message content), so it never re-bills the prompt-prefix cache. Returns the
/// static base verbatim (borrowed, do not free) when there are no grants; otherwise a gpa-owned buffer the
/// caller frees. `owned` receives the allocation to free, or stays null for the borrowed-base path.
fn buildTurnTools(gpa: std.mem.Allocator, ctx: *const tools.ToolCtx, compact: bool, owned: *?[]u8) []const u8 {
    const base: []const u8 = if (ctx.caps == .sandboxed)
        (if (compact) TURN_TOOLS_SANDBOXED_COMPACT else TURN_TOOLS_SANDBOXED)
    else
        (if (compact) TURN_TOOLS_COMPACT else TURN_TOOLS_FULL);
    if (ctx.grants.len == 0) return base; // common case: no grants ⇒ the exact static string, zero allocation
    var b: std.ArrayListUnmanaged(u8) = .empty;
    b.appendSlice(gpa, base) catch {
        b.deinit(gpa);
        return base;
    };
    for (ctx.grants) |r| {
        const sch = recipes.schemaFor(gpa, r.*);
        defer gpa.free(sch);
        if (sch.len == 0) continue; // schemaFor degrades to "" only on OOM — skip, never emit a torn def
        b.appendSlice(gpa, ",\n") catch {
            b.deinit(gpa);
            return base;
        };
        b.appendSlice(gpa, sch) catch {
            b.deinit(gpa);
            return base;
        };
    }
    const out = b.toOwnedSlice(gpa) catch {
        b.deinit(gpa);
        return base;
    };
    owned.* = out;
    return out;
}

/// One plain-prose line naming EVERY tool in `belt` (the "tools":[…] array body), in belt order —
/// served ONLY with the compact prompt. Derived by walking the belt's "name":"…" fields (the same
/// walk the prompt/belt guard tests do), so it can never drift from what is actually advertised:
/// the base variant, granted recipes, and plugin schemas all land here because the caller hands in
/// the FINAL belt string. Why it exists: a small model "checks its belt" by re-skimming 3KB of
/// schema JSON — observed live (c6a751a54), the 12B ran list_dir to look for the browser verbs,
/// read the empty directory as proof, and denied a browser it was holding. A denial now has to
/// contradict one plain line sitting in its own system prompt. Turn-stable exactly like the belt
/// it mirrors, so the provider's prompt-prefix cache is untouched. Caller frees; null on OOM or an
/// empty belt (serve the prompt unchanged rather than a torn line).
fn beltManifest(gpa: std.mem.Allocator, belt: []const u8) ?[]u8 {
    var names: std.ArrayListUnmanaged(u8) = .empty;
    defer names.deinit(gpa);
    var count: usize = 0;
    var i: usize = 0;
    const key = "\"name\":\"";
    while (std.mem.indexOfPos(u8, belt, i, key)) |at| {
        const start = at + key.len;
        const end = std.mem.indexOfScalarPos(u8, belt, start, '"') orelse break;
        // only string-valued "name" fields match this key: a schema PROPERTY named name appears as
        // `"name":{`, and description text carries escaped quotes, so the walk is exact — the same
        // fact the hand-enumeration guard test relies on.
        if (count > 0) names.appendSlice(gpa, ", ") catch return null;
        names.appendSlice(gpa, belt[start..end]) catch return null;
        count += 1;
        i = end;
    }
    if (count == 0) return null;
    return std.fmt.allocPrint(gpa, "\nTOOLS ON THIS BELT ({d}): {s}. That line is the complete belt: a tool named on it EXISTS and is callable by exactly that name; a name not on it is not available this turn.\n" ++
        "WON'T, NOT CAN'T. If you decide against doing something — judgment, caution, the user should do it themselves — say \"I won't\" and give the real reason. NEVER say a tool on the belt line is missing, and never go looking for a tool with list_dir (that lists FILES, it can tell you nothing about your belt). Claiming a listed tool is absent is a false statement about yourself, and it does not become true by repeating it.", .{ count, names.items }) catch null;
}

/// A belt tool (or tool FAMILY, e.g. "browser") that `reply` claims not to have, or null. The manifest
/// gave the model the names; it did not stop it LYING about them — observed live (c6a75cac3): a policy
/// refusal ("I can't post as you") hardened, under three turns of pushback, into a capability denial
/// that quoted the manifest's own tail back as proof — "no browser_navigate, read, click, type or
/// pixel_search". A model defending "can't" reaches for absence, and the system prompt sits far behind
/// the recency window where that momentum lives.
///
/// Names AND family roots come from the belt itself (a root shared by >= 3 defs is a family the model
/// talks about collectively — "browser tools"), so nothing here is hand-enumerated. "won't"/"wouldn't"
/// are deliberately NOT negation markers: declining by judgment is the sanctioned answer this correction
/// steers toward, so saying it plainly must never trip the detector.
fn beltDenial(gpa: std.mem.Allocator, reply: []const u8, belt: []const u8) ?[]const u8 {
    const NEG = [_][]const u8{ "no ", "not ", "isn't", "aren't", "don't", "doesn't", "didn't", "none", "without", "missing", "absent", "lack", "can't", "cannot", "couldn't" };
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(gpa);
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    defer roots.deinit(gpa);
    var i: usize = 0;
    const key = "\"name\":\"";
    while (std.mem.indexOfPos(u8, belt, i, key)) |at| {
        const s = at + key.len;
        const e = std.mem.indexOfScalarPos(u8, belt, s, '"') orelse break;
        names.append(gpa, belt[s..e]) catch return null;
        i = e;
    }
    for (names.items) |n| {
        const root = n[0 .. std.mem.indexOfScalar(u8, n, '_') orelse continue];
        if (root.len < 4) continue; // too short to be distinctive in prose
        var fam: usize = 0;
        for (names.items) |m| if (std.mem.startsWith(u8, m, root) and m.len > root.len and m[root.len] == '_') { fam += 1; };
        if (fam >= 3) {
            var seen = false;
            for (roots.items) |r| if (std.mem.eql(u8, r, root)) { seen = true; };
            if (!seen) roots.append(gpa, root) catch return null;
        }
    }
    // A mention is a DENIAL when a negation sits just before it IN THE SAME SENTENCE **and** the phrasing
    // is about having/reaching the tool. The possession cue is what separates "there are no browser tools
    // on it" (the lie) from "No results came back from web_search" (a fine sentence that negates the
    // RESULTS) — without it the corrector fires on ordinary reporting and teaches the model to distrust it.
    const CUE = [_][]const u8{ "have", "belt", "here", "access", "available", "tool" };
    const hit = struct {
        fn f(hay: []const u8, needle: []const u8, neg: []const []const u8, cue: []const []const u8) bool {
            var p: usize = 0;
            while (std.ascii.indexOfIgnoreCasePos(hay, p, needle)) |at| {
                const from = at -| 64;
                const win = hay[from..at];
                const sentence = if (std.mem.lastIndexOfAny(u8, win, ".!?")) |b| win[b + 1 ..] else win;
                const after = hay[@min(at + needle.len, hay.len)..@min(at + needle.len + 24, hay.len)];
                var negated = false;
                for (neg) |m| if (std.ascii.indexOfIgnoreCase(sentence, m) != null) { negated = true; };
                if (negated) {
                    for (cue) |c| {
                        if (std.ascii.indexOfIgnoreCase(sentence, c) != null or std.ascii.indexOfIgnoreCase(after, c) != null) return true;
                    }
                }
                p = at + 1;
            }
            return false;
        }
    }.f;
    for (roots.items) |r| if (hit(reply, r, &NEG, &CUE)) return r;
    for (names.items) |n| if (hit(reply, n, &NEG, &CUE)) return n;
    return null;
}

/// The conversation's most recent ASSISTANT reply (for the belt-denial check). Tail read, same bounded
/// head/tail primitive firstUserGoal uses; null when the conv has no assistant turn yet.
fn lastAssistantReply(app: *App, conv_dir: []const u8) ?[]u8 {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return null;
    defer gpa.free(mpath);
    const head_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return null;
    defer gpa.free(head_buf);
    const tail_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return null;
    defer gpa.free(tail_buf);
    const ht = cctx.readHeadTail(app.io, mpath, head_buf, tail_buf) orelse return null;
    var out: ?[]u8 = null;
    for ([_][]const u8{ ht.head, ht.tail }) |part| {
        var it = std.mem.splitScalar(u8, part, '\n');
        while (it.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \r\t");
            if (t.len == 0 or t[0] != '{') continue;
            const P = struct { role: []const u8 = "", content: []const u8 = "" };
            const p = std.json.parseFromSlice(P, gpa, t, .{ .ignore_unknown_fields = true }) catch continue;
            defer p.deinit();
            if (!std.mem.eql(u8, p.value.role, "assistant") or p.value.content.len == 0) continue;
            if (out) |o| gpa.free(o);
            out = gpa.dupe(u8, p.value.content) catch null;
        }
    }
    return out;
}

/// io-based wall clock — the SAME source the worker stamps its event `t` with (std time under io, never a raw
/// clock primitive). Seconds are fine: the P0-4 reader only maxes `ts` for a conv's `updated`, so ties are OK.
fn nowSecs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Millisecond wall clock — for per-tool latency in the tool-performance learner (seconds are too coarse; a
/// fast local tool would read as 0). Same io time source as nowSecs.
fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// Replace each byte not part of a valid UTF-8 sequence with '?' in place (length-preserving), so arbitrary
/// tool output (fetched page bytes) always serializes as conformant JSON. Local copy of chat_tools.scrubUtf8.
/// The task id inside a scheduled-run conv id ("scheduled_{taskid}_MMDDHHMM") — null for ordinary convs.
/// Drives the per-TASK memory scope: runs of the same task share one partition across conversations.
fn schedTaskOf(conv: []const u8) ?[]const u8 {
    const prefix = "scheduled_";
    if (!std.mem.startsWith(u8, conv, prefix)) return null;
    const rest = conv[prefix.len..];
    if (rest.len == 0) return null;
    const us = std.mem.lastIndexOfScalar(u8, rest, '_') orelse return rest;
    if (us == 0) return null;
    return rest[0..us];
}

test "memory-weave gates: echo tools, credential-shaped results, note atomization" {
    // recall/observe echoes never become new facts; real finding tools still do
    try std.testing.expect(memoryEchoTool("recall"));
    try std.testing.expect(memoryEchoTool("recall_hive"));
    try std.testing.expect(memoryEchoTool("observe"));
    try std.testing.expect(!memoryEchoTool("web_search"));
    try std.testing.expect(!memoryEchoTool("read_file"));
    // result-side credential scan (the args were clean; the VALUE came back in the body)
    try std.testing.expect(containsCredentialKey("status=200, body={\"csrf\":\"cku...\"}"));
    try std.testing.expect(containsCredentialKey("set-cookie: session=abc"));
    try std.testing.expect(!containsCredentialKey("dir listing: index.html 3771 b"));
    // atomization: one fact per note — newlines fold, sentence enders soften, so the store cannot shred it
    var n = "wrote a.ts — file is now 31 bytes.\nNext: build the feed. Then ship!".*;
    atomizeNoteInPlace(&n);
    try std.testing.expectEqualStrings("wrote a.ts — file is now 31 bytes, Next: build the feed, Then ship!", &n);
}

test "msgTail: full when it fits; suffix anchors on a non-tool boundary; tool anchors are skipped" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"role\":\"system\",\"content\":\"sys\"}");
    try buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"");
    try buf.appendNTimes(gpa, 'x', 3000); // a fat message pushes everything else past the window
    try buf.appendSlice(gpa, "\"}");
    try buf.appendSlice(gpa, ",{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"1\"}]}");
    try buf.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":\"1\",\"content\":\"r\"}");
    try buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"latest\"}");
    // fits → verbatim
    try std.testing.expectEqualStrings(buf.items, msgTail(buf.items, buf.items.len + 1));
    // window covers assistant+tool+user → anchors at the assistant (its tool result stays paired)
    try std.testing.expect(std.mem.startsWith(u8, msgTail(buf.items, 150), "{\"role\":\"assistant\""));
    // window covers only tool+user → the ORPHAN tool anchor is skipped; lands on the final user
    try std.testing.expect(std.mem.startsWith(u8, msgTail(buf.items, 90), "{\"role\":\"user\",\"content\":\"latest\"}"));
    // window inside the last object (no boundary) → degrades to the FULL list, never a torn slice
    try std.testing.expectEqualStrings(buf.items, msgTail(buf.items, 20));
}

test "clipToolResult: small stays verbatim (same ptr); big keeps head+tail around an elision note" {
    const gpa = std.testing.allocator;
    const small = "tiny result";
    try std.testing.expect(clipToolResult(gpa, small).ptr == small.ptr);
    const big = try gpa.alloc(u8, 12 * 1024);
    defer gpa.free(big);
    @memset(big, 'a');
    @memcpy(big[0..4], "HEAD");
    @memcpy(big[big.len - 4 ..], "TAIL");
    const c = clipToolResult(gpa, big);
    defer gpa.free(c);
    try std.testing.expect(c.len < big.len);
    try std.testing.expect(std.mem.startsWith(u8, c, "HEAD"));
    try std.testing.expect(std.mem.endsWith(u8, c, "TAIL"));
    try std.testing.expect(std.mem.indexOf(u8, c, "bytes elided") != null);
}

test "turn tools: both caps variants are valid JSON arrays, and the sandboxed one drops exactly the refused set" {
    const gpa = std.testing.allocator;

    // WHY THIS TEST EXISTS: tools.sandboxSchema filters the schema LINE BY LINE, so it silently depends on every
    // tool def occupying its own line. That holds today (27 defs, 27 lines) but it is a formatting convention,
    // not something the compiler enforces — and if a def is ever wrapped across two lines, the continuation has
    // no `"name":"…"` key, gets dropped, and the sandboxed array becomes malformed JSON. That failure would be
    // invisible in dev (admins get the unfiltered variant) and would break every non-admin turn in production.
    // Parsing both variants here turns that into a build failure.
    inline for (.{ TURN_TOOLS_FULL, TURN_TOOLS_SANDBOXED }) |variant| {
        const arr = try std.fmt.allocPrint(gpa, "[{s}]", .{variant});
        defer gpa.free(arr);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, arr, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expect(parsed.value.array.items.len > 0);
    }

    // The gate and the schema must agree: advertising a tool tools.execute would refuse is the waste this
    // filter removes, and dropping one it would ALLOW is a silent capability regression.
    const arr = try std.fmt.allocPrint(gpa, "[{s}]", .{TURN_TOOLS_SANDBOXED});
    defer gpa.free(arr);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, arr, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |def| {
        // OpenAI tool shape: {"type":"function","function":{"name":…}} — the name is nested, which is also why
        // sandboxSchema scans for the `"name":"` key rather than assuming a top-level field.
        const name = def.object.get("function").?.object.get("name").?.string;
        // NO EXEMPTION. This loop used to `continue` past every ORCH_TOOLS name, because the block rode
        // along unfiltered — which meant the test could not see the nine orchestration verbs that
        // orchTool refuses outright for a sandboxed caller. Now that ORCH_TOOLS goes through the same
        // allowlist filter, EVERY name in the sandboxed array must be one the gate actually permits, and
        // the exemption that hid the gap is gone (0081).
        try std.testing.expect(tools.sandboxAllowed(name));
    }
    // The three orchestration verbs that DO work for a sandboxed caller survive the filter — the point is
    // to drop the refused ones, not the block. SANDBOX_TOOLS calls these "read-only swarm observation".
    for ([_][]const u8{ "swarm_status", "swarm_asks", "stop_swarm" }) |keep| {
        if (std.mem.indexOf(u8, TURN_TOOLS_SANDBOXED, keep) == null) {
            std.debug.print("\nsandboxed turn tools lost '{s}' — the filter is dropping working capability, which is what the old exemption feared\n", .{keep});
            return error.SandboxDroppedWorkingVerb;
        }
    }
    // ...and the escalating ones are gone. Each of these was advertised to a sandboxed model that would be
    // refused by orchTool before dispatch, burning an agentic round-trip per attempt.
    for ([_][]const u8{ "\"cast\"", "\"steer_swarm\"", "\"answer_swarm\"", "\"sync_dir\"", "\"open_subchat\"", "\"schedule_task\"" }) |gone| {
        if (std.mem.indexOf(u8, TURN_TOOLS_SANDBOXED, gone) != null) {
            std.debug.print("\nsandboxed turn tools still advertise {s} — orchTool refuses it before dispatch, so every call is a wasted round-trip\n", .{gone});
            return error.SandboxAdvertisesRefusedVerb;
        }
    }
    // Still present for an ADMIN turn: the filter must not have removed them from the full variant.
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_FULL, "\"cast\"") != null);
    // pixel_search is the reason the removal is per-tool rather than per-block — it is sandbox-safe while both
    // of its PIXEL_SCHEMA neighbours are not.
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_SANDBOXED, "\"pixel_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_SANDBOXED, "\"pixel_capture\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_SANDBOXED, "\"browser_navigate\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_SANDBOXED, "\"get_credential\"") == null);
    try std.testing.expect(TURN_TOOLS_SANDBOXED.len < TURN_TOOLS_FULL.len);
}

test "belt manifest: names EVERY tool a compact belt serves, with a true count, nothing hand-enumerated" {
    const gpa = std.testing.allocator;
    inline for (.{ TURN_TOOLS_COMPACT, TURN_TOOLS_SANDBOXED_COMPACT }) |variant| {
        const m = beltManifest(gpa, variant) orelse return error.TestUnexpectedResult;
        defer gpa.free(m);
        // walk the belt's "name":"…" fields — the exact walk the manifest itself performs and the
        // hand-enumeration guard below performs — and require every served name on the line
        var count: usize = 0;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, variant, i, "\"name\":\"")) |at| {
            const start = at + "\"name\":\"".len;
            const end = std.mem.indexOfScalarPos(u8, variant, start, '"') orelse break;
            try std.testing.expect(std.mem.indexOf(u8, m, variant[start..end]) != null);
            count += 1;
            i = end;
        }
        try std.testing.expect(count > 0);
        // the count in the header is the belt's true def count, not an approximation
        var head: [64]u8 = undefined;
        const expect_head = try std.fmt.bufPrint(&head, "\nTOOLS ON THIS BELT ({d}): ", .{count});
        try std.testing.expect(std.mem.startsWith(u8, m, expect_head));
    }
}

test "the-veil-12b is SERVED a manifest: model id -> small tier -> compact belt -> manifest" {
    // Each link in this chain is tested somewhere; nothing tested them TOGETHER, so breaking
    // any one of them would have been silent. The chain is what decides whether the shipped
    // 12B is ever told what it is holding:
    //   senseModel(id).tier == .small  ->  compact_belt  ->  beltManifest(turn_tools)
    //
    // What it is worth, measured on the-veil-12b over 110 held-out drills: the compact belt
    // WITH the manifest scored 97/110 with 2 invented tool names, against 92/111 with 6 for
    // the 20-tool full-doctrine config that carries none. On a later checkpoint the same
    // before/after moved invented names 11 -> 1. Invented names are the failure with the
    // worst user-visible cost -- the harness rejects the name and the turn is simply lost.
    const gpa = std.testing.allocator;

    // link 1: the shipped id tiers small on BOTH paths. tier_local only widens what counts
    // as small, so neither value may promote this model out of the compact tier.
    inline for (.{ true, false }) |local| {
        try std.testing.expectEqual(modelcfg.Tier.small, modelcfg.senseModel("the-veil-12b", local).tier);
    }

    // link 2: the belt that tier selects yields a manifest naming its exact tools
    const m = beltManifest(gpa, TURN_TOOLS_COMPACT) orelse return error.TestUnexpectedResult;
    defer gpa.free(m);
    try std.testing.expect(std.mem.startsWith(u8, m, "\nTOOLS ON THIS BELT ("));
    for ([_][]const u8{ "read_file", "run_python", "web_search", "recall", "browser_navigate" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, m, name) != null);
    }
    // the rule that stops a policy refusal hardening into a capability denial
    try std.testing.expect(std.mem.indexOf(u8, m, "WON'T, NOT CAN'T") != null);

    // link 3: a tool the compact belt does NOT serve must not appear on the line, or the
    // manifest asserts the exact falsehood it exists to prevent
    try std.testing.expect(std.mem.indexOf(u8, m, "stop_process") == null);
}

test "belt denial: catches the live lie, spares an honest 'won't', and never fires on a clean reply" {
    const gpa = std.testing.allocator;
    const belt = TURN_TOOLS_COMPACT;
    // THE LIVE FAILURE, verbatim from c6a75cac3 — a policy refusal that hardened into capability denial
    for ([_][]const u8{
        "I can't open a browser from this belt -- there are no browser tools on it -- so I genuinely can't go to Twitter at all.",
        "I genuinely don't have a browser on this belt -- there's no browser tool here to call.",
        "I've looked at the belt and there are no browser tools on it -- no browser_navigate, read, click, type or pixel_search.",
        "I've no recall tool on this belt -- recall itself isn't here, so I can't call it.",
    }) |lie| {
        try std.testing.expect(beltDenial(gpa, lie, belt) != null);
    }
    // the SANCTIONED answer must never trip it: declining by judgment is what the correction steers toward,
    // so "won't" is deliberately absent from the negation markers
    for ([_][]const u8{
        "I won't use browser_navigate to post as you on social media -- that is your account to speak from.",
        "I wouldn't drive the browser for that without your say-so.",
        "I'll use browser_navigate to open the page now.",
        "The browser is on my belt; opening Twitter next.",
        "No results came back from web_search, so I'll try browser_navigate instead.",
    }) |ok| {
        try std.testing.expect(beltDenial(gpa, ok, belt) == null);
    }
    // a tool genuinely NOT on the compact belt is not the corrector's business (cast is full-tier only)
    try std.testing.expect(beltDenial(gpa, "I don't have cast on this belt.", belt) == null);
}

test "browser_read projection: EVERY ref survives, boilerplate does not, and non-browser results pass through" {
    const gpa = std.testing.allocator;
    // a page whose editable field sits deep enough that byte-offset clipping would elide it — the
    // measured live failure (x.com: composer at 11%, search box at 70%, clip kept neither reliably)
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.appendSlice(gpa, "{\"url\":\"https://x.com/home\",\"title\":\"Home / X\",\"count\":180,\"elements\":[");
    for (0..180) |i| {
        if (i > 0) try payload.append(gpa, ',');
        const editable = (i == 25 or i == 150); // composer near the head, search box deep in the middle
        const el = try std.fmt.allocPrint(
            gpa,
            "{{\"ref\":{d},\"tag\":\"button\",\"type\":\"button\",\"name\":\"\",\"edit\":{s},\"text\":\"{s}\"}}",
            .{ i + 1, if (editable) "true" else "false", if (i == 25) "Post text" else if (i == 150) "Search query" else "Skip to home timeline" },
        );
        defer gpa.free(el);
        try payload.appendSlice(gpa, el);
    }
    try payload.appendSlice(gpa, "],\"text\":\"timeline prose\",\"textLen\":14}");

    const proj = clipToolResult(gpa, payload.items);
    defer if (proj.ptr != payload.items.ptr) gpa.free(proj);
    try std.testing.expect(proj.ptr != payload.items.ptr); // it projected, not passed through

    // THE PROPERTY: every ref in the payload is still addressable afterwards. A ref table must never be
    // truncated by position — the model cannot tell a dropped ref from an absent element, and answers
    // with a confidently wrong one (measured: it said ref 8 for a search box that was really 154).
    for (1..181) |r| {
        var needle: [16]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, proj, try std.fmt.bufPrint(&needle, "[{d}]", .{r})) != null);
    }
    // editable fields are called out, and the projection is materially smaller than the raw payload
    try std.testing.expect(std.mem.indexOf(u8, proj, "EDITABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj, "Post text") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj, "Search query") != null);
    try std.testing.expect(proj.len * 2 < payload.items.len);

    // a NON-browser result is untouched by the projection and still takes the ordinary clip path
    const plain = "npm test output, no elements array here";
    try std.testing.expect(clipToolResult(gpa, plain).ptr == plain.ptr);
    const big = try gpa.alloc(u8, TOOL_RESULT_KEEP + 4096);
    defer gpa.free(big);
    @memset(big, 'x');
    const clipped = clipToolResult(gpa, big);
    defer gpa.free(clipped);
    try std.testing.expect(std.mem.indexOf(u8, clipped, "elided from the middle") != null);
}

test "the terse belt halves the small tier's schema bytes without hiding a single verb" {
    const gpa = std.testing.allocator;
    // WHAT THIS PROTECTS: the small tier's belt is what pushes its prompt past an 8k window, and the cheap way
    // to shrink it — dropping verbs — is the wrong way. The browser four cannot go (worker/run.zig splices the
    // same comptime filter into every scout mind, and beltDenial needs three to see the family), and hiding
    // tools from a 12B is the failure the streak-2 nudge exists to paper over. So the bytes come out of the
    // PROSE, and this test holds that line: same capabilities, far fewer bytes, and no description that
    // advertises a verb the tier cannot call.
    var terse: std.ArrayListUnmanaged(u8) = .empty;
    defer terse.deinit(gpa);
    try terse.appendSlice(gpa, "[");
    try terse.appendSlice(gpa, TURN_TOOLS_COMPACT);
    try terse.appendSlice(gpa, "]");
    const p = try std.json.parseFromSlice(std.json.Value, gpa, terse.items, .{});
    defer p.deinit();
    const defs = p.value.array;

    // EVERY tool the belt served before is still served — the saving costs no capability at all.
    const must = [_][]const u8{
        "web_search",       "web_fetch",    "read_file",     "write_file",   "edit_file",
        "list_dir",         "delete_file",  "run_python",    "run_tests",    "recall",
        "observe",          "read_doc",     "pixel_search",  "browser_read", "browser_navigate",
        "browser_click",    "browser_type",
    };
    for (must) |name| {
        var found = false;
        for (defs.items) |d| {
            const fnobj = d.object.get("function").?.object;
            if (std.mem.eql(u8, fnobj.get("name").?.string, name)) found = true;
        }
        if (!found) {
            std.debug.print("terse belt dropped a verb the small tier still needs: {s}\n", .{name});
            return error.TerseBeltDroppedAVerb;
        }
    }
    try std.testing.expectEqual(must.len, defs.items.len); // and added none

    // NO DESCRIPTION NAMES AN OFF-BELT VERB. Five of the replaced descriptions did (read_url, deep_crawl,
    // pixel_ingest, pixel_capture, absorb, recall_hive, patch_system) — the belt taught a tier to reach for
    // tools it cannot call, which burns an agentic round on an unknown-tool refusal every time it lands.
    const hidden = [_][]const u8{
        "read_url",  "deep_crawl",  "pixel_ingest", "pixel_capture", "absorb",
        "recall_hive", "patch_system", "open_subchat", "fetch_json",  "mcp_call",
    };
    for (defs.items) |d| {
        const fnobj = d.object.get("function").?.object;
        const desc = fnobj.get("description").?.string;
        for (hidden) |h| if (std.mem.indexOf(u8, desc, h) != null) {
            std.debug.print("belt description for {s} names off-belt verb {s}\n", .{ fnobj.get("name").?.string, h });
            return error.BeltDescriptionNamesHiddenVerb;
        };
    }

    // The browser workflow a small model skips is taught where it is needed: read yields the refs, and the two
    // verbs that consume them say so.
    for (defs.items) |d| {
        const fnobj = d.object.get("function").?.object;
        const nm = fnobj.get("name").?.string;
        if (std.mem.eql(u8, nm, "browser_click") or std.mem.eql(u8, nm, "browser_type"))
            try std.testing.expect(std.mem.indexOf(u8, fnobj.get("description").?.string, "browser_read") != null);
    }

    // MATERIALLY SMALLER, and locked so the prose cannot creep back. The pre-terse belt measured 13,489 B.
    try std.testing.expect(TURN_TOOLS_COMPACT.len < 9 * 1024);
    try std.testing.expect(TURN_TOOLS_COMPACT.len * 2 < TURN_TOOLS_FULL.len);
    // the sandboxed twin rides the same projection
    try std.testing.expect(TURN_TOOLS_SANDBOXED_COMPACT.len < TURN_TOOLS_SANDBOXED.len);
}

test "compact belt: valid JSON, materially smaller, keeps the core verbs and drops the decoys" {
    const gpa = std.testing.allocator;

    // both compact variants must still be a well-formed tools array — joinDefs exists because an empty
    // projection (compactSchema(ORCH_TOOLS) is empty: every orchestration verb drops) would otherwise splice a
    // leading or doubled comma and hand the provider a malformed array
    inline for (.{ TURN_TOOLS_COMPACT, TURN_TOOLS_SANDBOXED_COMPACT }) |variant| {
        const arr = try std.fmt.allocPrint(gpa, "[{s}]", .{variant});
        defer gpa.free(arr);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, arr, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expect(parsed.value.array.items.len > 0);
    }

    // THE POINT: a 12B model was being handed 49 defs / ~35KB, three quarters of the whole request. Less than
    // half the bytes is the floor worth asserting — if a future edit re-adds the world to the small belt, this
    // fails rather than silently regressing every local turn.
    try std.testing.expect(TURN_TOOLS_COMPACT.len * 2 < TURN_TOOLS_FULL.len);

    // the core belt survives: research, files, code, memory, and the four browser verbs that drive a page
    for ([_][]const u8{
        "\"web_search\"", "\"web_fetch\"",       "\"read_file\"",   "\"write_file\"",    "\"edit_file\"",
        "\"list_dir\"",   "\"run_python\"",      "\"run_tests\"",   "\"recall\"",        "\"observe\"",
        "\"read_doc\"",   "\"browser_navigate\"", "\"browser_read\"", "\"browser_click\"", "\"browser_type\"",
    }) |keep| {
        if (std.mem.indexOf(u8, TURN_TOOLS_COMPACT, keep) == null) {
            std.debug.print("\ncompact belt lost {s} — that is core solo-chat capability, not a decoy\n", .{keep});
            return error.CompactDroppedCoreVerb;
        }
    }

    // and the decoys are gone. mcp_call/mcp_discover lead this list on evidence: a 12B asked to "use the web
    // browser" reached for them twice while browser_navigate sat in the same array.
    for ([_][]const u8{
        "\"mcp_call\"", "\"mcp_discover\"",  "\"cast\"",        "\"steer_swarm\"", "\"open_subchat\"",
        "\"absorb\"",   "\"schedule_task\"", "\"browser_eval\"", "\"browser_key\"", "\"recall_hive\"",
    }) |gone| {
        if (std.mem.indexOf(u8, TURN_TOOLS_COMPACT, gone) != null) {
            std.debug.print("\ncompact belt still advertises {s} — every extra def is surface a small model has to rule out\n", .{gone});
            return error.CompactKeptDecoy;
        }
    }

    // dropping from the BELT must not drop from the full variant — mid/large turns are untouched
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_FULL, "\"mcp_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_FULL, "\"browser_eval\"") != null);

    // the belt is a REASONING aid, not a permission boundary: a dropped-but-real tool must still be dispatchable,
    // or hiding it would silently remove capability the model may still name from memory
    try std.testing.expect(knownToolName(TURN_TOOLS_COMPACT, "browser_eval"));
    try std.testing.expect(knownToolName(TURN_TOOLS_COMPACT, "cast"));
}

test "wmFold: watermark typography folds; code fences and chunk splits survive" {
    var out: [512]u8 = undefined;
    var st: WmState = .{};
    // the headline case
    var n = wmFold(&st, &out, "it works\u{2014}mostly", true);
    try std.testing.expectEqualStrings("it works-mostly", out[0..n]);
    // curly quotes, ellipsis, NBSP
    st = .{};
    n = wmFold(&st, &out, "\u{201C}don\u{2019}t\u{201D}\u{2026}\u{00A0}ok", true);
    try std.testing.expectEqualStrings("\"don't\"... ok", out[0..n]);
    // zero-width characters vanish (the real data-carrying vector)
    st = .{};
    n = wmFold(&st, &out, "he\u{200B}llo\u{FEFF} wor\u{200D}ld", true);
    try std.testing.expectEqualStrings("hello world", out[0..n]);
    // CHUNK SPLIT: an em dash cut across two deltas still folds (3 bytes: E2 80 94)
    st = .{};
    const em = "\u{2014}";
    var w: usize = 0;
    w += wmFold(&st, out[w..], "a" ++ em[0..1], false);
    try std.testing.expectEqual(@as(usize, 1), w); // the partial lead byte is HELD, not emitted
    w += wmFold(&st, out[w..], em[1..3] ++ "b", false);
    try std.testing.expectEqualStrings("a-b", out[0..w]);
    // FENCE: visible punctuation inside code is data and must survive verbatim...
    st = .{};
    n = wmFold(&st, &out, "```\nlet s = \u{201C}x\u{201D}; // a\u{2014}b\n```", true);
    try std.testing.expectEqualStrings("```\nlet s = \u{201C}x\u{201D}; // a\u{2014}b\n```", out[0..n]);
    // ...but an invisible character never belongs in code either
    st = .{};
    n = wmFold(&st, &out, "```\nlet x\u{200B} = 1;\n```", true);
    try std.testing.expectEqualStrings("```\nlet x = 1;\n```", out[0..n]);
    // and prose AFTER the fence closes folds again
    st = .{};
    n = wmFold(&st, &out, "```\na\u{2014}b\n```\nthen\u{2014}this", true);
    try std.testing.expectEqualStrings("```\na\u{2014}b\n```\nthen-this", out[0..n]);
    // plain ASCII is byte-identical (the common case must not churn)
    st = .{};
    n = wmFold(&st, &out, "ordinary text - already fine", true);
    try std.testing.expectEqualStrings("ordinary text - already fine", out[0..n]);

    // the owned wrapper returns null when there is nothing to change
    const gpa = std.testing.allocator;
    try std.testing.expect(wmScrubOwned(gpa, "clean ascii") == null);
    const dirty = wmScrubOwned(gpa, "a\u{2014}b").?;
    defer gpa.free(dirty);
    try std.testing.expectEqualStrings("a-b", dirty);
}

test "scrubAccountIds: provider-error account tokens mask, prose survives" {
    var b: [420]u8 = undefined;
    // the live shape: a suspension error quoting the org id and key alias
    const got = scrubAccountIds(&b, "Your account org-4c484c356e734760be8bc089bdb59f40 <ak-fbf36yago7ti11bc3f7i> is suspended due to insufficient balance");
    try std.testing.expect(std.mem.indexOf(u8, got, "org-4c48**") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "4c484c356e734760be8bc089bdb59f40") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "ak-fbf3**") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "fbf36yago7ti11bc3f7i") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "is suspended due to insufficient balance") != null);
    // prose with an embedded prefix-looking word is untouched ("fork-lifting" ≠ a key)
    var b2: [120]u8 = undefined;
    const p2 = scrubAccountIds(&b2, "the fork-lifting task-force worked (rate limit)");
    try std.testing.expectEqualStrings("the fork-lifting task-force worked (rate limit)", p2);
    // a SHORT token (under 8 id chars) is left alone — masking "sk-test" style words costs more than it saves
    var b3: [64]u8 = undefined;
    const p3 = scrubAccountIds(&b3, "set sk-test as a dummy");
    try std.testing.expectEqualStrings("set sk-test as a dummy", p3);
}

test "isMutatingTool: file mutations guard on truncation; reads never do" {
    // the truncated-mutation guard (dispatch loop) refuses ONLY these on done_reason=length — a half-executed
    // read just searches worse, but a half-executed write lands a corrupt file that reads as complete
    for ([_][]const u8{ "write_file", "edit_file", "delete_file", "stage_file" }) |m|
        try std.testing.expect(isMutatingTool(m));
    for ([_][]const u8{ "read_file", "list_dir", "web_search", "run_python", "recall", "browser_read" }) |r|
        try std.testing.expect(!isMutatingTool(r));
}

test "canonToolMatch: re-cased real names resolve uniquely; phantoms and ambiguity refuse" {
    // the observed misses: CamelCase / stray punctuation over a REAL advertised name
    try std.testing.expectEqualStrings("web_search", canonToolMatch(TURN_TOOLS_COMPACT, "WebSearch").?);
    try std.testing.expectEqualStrings("list_dir", canonToolMatch(TURN_TOOLS_COMPACT, "ListDir").?);
    try std.testing.expectEqualStrings("read_file", canonToolMatch(TURN_TOOLS_COMPACT, "Read_File").?);
    try std.testing.expectEqualStrings("web_fetch", canonToolMatch(TURN_TOOLS_COMPACT, "web-fetch").?);
    // pure inventions still refuse — there is nothing to correct TO
    try std.testing.expect(canonToolMatch(TURN_TOOLS_COMPACT, "Gemma4__1m_check") == null);
    try std.testing.expect(canonToolMatch(TURN_TOOLS_COMPACT, "I_want_to_know") == null);
    try std.testing.expect(canonToolMatch(TURN_TOOLS_COMPACT, "") == null);
    // the compact belt must NOT helpfully upgrade into hidden orchestration: "Cast" is a real full-schema
    // name, but this turn never advertised it, so the match is scoped to the belt and misses
    try std.testing.expect(canonToolMatch(TURN_TOOLS_COMPACT, "Cast") == null);
    // ambiguity refuses to guess
    const two = "{\"name\":\"web_search\"},{\"name\":\"websearch\"}";
    try std.testing.expect(canonToolMatch(two, "WebSearch") == null);
    // the loose comparator itself
    try std.testing.expect(toolNameEqLoose("web_search", "WebSearch"));
    try std.testing.expect(toolNameEqLoose("web_search", "web-search"));
    try std.testing.expect(!toolNameEqLoose("web_search", "web_fetch"));
    try std.testing.expect(!toolNameEqLoose("read_file", "read_files"));
}

test "looksLikeNotFound: 404 pages flag; real content, big pages, and mid-article mentions don't" {
    // the observed arXiv shapes — a guessed paper id and a malformed pdf URL
    try std.testing.expect(looksLikeNotFound("Not found  ![](https://static.arxiv.org/...smileybones...) arXiv is now an independent nonprofit!"));
    try std.testing.expect(looksLikeNotFound("| arXiv e-print repository  # No document for '2312.17986v2'  Please inform help@arxiv.org"));
    try std.testing.expect(looksLikeNotFound("<html><title>404 Not Found</title><body>nginx</body></html>"));
    // "not found" buried mid-article is vocabulary, not a verdict — the lead window misses it on purpose
    try std.testing.expect(!looksLikeNotFound("The survey covers methods where a solution was not found by classical solvers, including QAOA variants and their scaling behavior on NISQ hardware in recent benchmarks and more text making this clearly an article."));
    try std.testing.expect(!looksLikeNotFound(""));
    // a big body is content no matter what its first bytes say
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 20000);
    defer gpa.free(big);
    @memset(big, 'x');
    @memcpy(big[0.."Not found".len], "Not found");
    try std.testing.expect(!looksLikeNotFound(big));
}

test "looksLikeBotChallenge: challenge stubs flag; real content and big pages don't" {
    try std.testing.expect(looksLikeBotChallenge("<html><head><title>Just a moment...</title></head></html>"));
    try std.testing.expect(looksLikeBotChallenge("<html lang=\"en\"><head><title>reuters.com</title><style>#cmsg{animation: A 1.5s;}</style>"));
    try std.testing.expect(looksLikeBotChallenge("<p>Please Enable JavaScript and cookies to continue</p>"));
    // an article that merely TALKS about Cloudflare is not a challenge page
    try std.testing.expect(!looksLikeBotChallenge("Cloudflare reported record revenue this quarter; the CDN market..."));
    // a big body is a real page even if boilerplate appears somewhere in it
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 20000);
    defer gpa.free(big);
    @memset(big, 'a');
    @memcpy(big[0.."Just a moment...".len], "Just a moment...");
    try std.testing.expect(!looksLikeBotChallenge(big));
    try std.testing.expect(!looksLikeBotChallenge(""));
}

/// True if `needle` occurs in `hay` delimited by non-identifier characters on both sides — so searching for
/// the tool name "recall" does not fire on "recall_hive", and "poll" does not fire on "polling".
fn namesVerb(hay: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |at| {
        const before_ok = at == 0 or !(std.ascii.isAlphanumeric(hay[at - 1]) or hay[at - 1] == '_');
        const e = at + needle.len;
        const after_ok = e >= hay.len or !(std.ascii.isAlphanumeric(hay[e]) or hay[e] == '_');
        if (before_ok and after_ok) return true;
        i = at + 1;
    }
    return false;
}

test "compact system prompt: paired with the compact belt — no unadvertised verbs, core verbs named" {
    // the recall_hive class, asserted at its source: a compact turn must never be TAUGHT a verb its belt
    // doesn't advertise. DERIVED from the belt rather than listed by hand — the hand-written deny-list this
    // replaces named eight verbs and therefore proved nothing about the ninth. It went green while the
    // durable-memory footer taught get_credential to a belt that had dropped it, and it would have gone green
    // again when read_url / fetch_json / stop_process left the belt while the prompt still named them. Walk
    // EVERY tool the full belt knows: any name the compact belt does not carry must not appear in its prompt.
    var it = std.mem.splitSequence(u8, TURN_TOOLS_FULL, "\"name\":\"");
    _ = it.next(); // before the first name
    var checked: usize = 0;
    while (it.next()) |seg| {
        const end = std.mem.indexOfScalar(u8, seg, '"') orelse continue;
        const verb = seg[0..end];
        if (verb.len == 0 or tools.compactAllowed(verb)) continue;
        checked += 1;
        if (namesVerb(SYSTEM_PROMPT_COMPACT, verb)) {
            std.debug.print("\ncompact system prompt teaches '{s}' — its belt does not advertise that\n", .{verb});
            return error.CompactPromptTeachesUnadvertisedVerb;
        }
    }
    try std.testing.expect(checked > 20); // the walk actually ran over a real belt, not an empty split
    // and the belt's own core IS taught by exact name
    for ([_][]const u8{ "web_search", "read_doc", "browser_navigate", "run_tests", "REMEMBER:" }) |need|
        try std.testing.expect(std.mem.indexOf(u8, SYSTEM_PROMPT_COMPACT, need) != null);
    // the whole point: materially smaller than the 6KB curriculum
    try std.testing.expect(SYSTEM_PROMPT_COMPACT.len * 2 < SYSTEM_PROMPT.len);
}

test "knownToolName + unknownToolResult: an invented name is refused with the real belt, never delegated" {
    const gpa = std.testing.allocator;

    // the three names a 12B actually invented in the "good morning gemma" conversation
    for ([_][]const u8{ "WebSearch", "Gemma4__1m_check", "Gemma2_7B_Instruct", "" }) |bad|
        try std.testing.expect(!knownToolName(TURN_TOOLS_COMPACT, bad));

    // real names resolve, whether advertised this turn or only dispatchable
    for ([_][]const u8{ "web_search", "read_file", "browser_navigate" }) |good|
        try std.testing.expect(knownToolName(TURN_TOOLS_COMPACT, good));

    // a name too long to even build a needle for is NOT refused — an unmeasurable case must never become a
    // refusal, since the dispatcher below would have handled it
    const huge = "x" ** 400;
    try std.testing.expect(knownToolName(TURN_TOOLS_COMPACT, huge));

    // the correction names the offender, says nothing ran, and lists real tools — the model must not be able to
    // read it as a transport failure, which is the misreading that ended the observed turn
    const msg = unknownToolResult(gpa, "WebSearch", TURN_TOOLS_COMPACT);
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "WebSearch") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "nothing ran") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "web_search") != null); // the real name it meant
    try std.testing.expect(std.mem.indexOf(u8, msg, "read_file") != null);
    // it must NOT sound like the bridge died — that is the whole failure this replaces
    try std.testing.expect(std.mem.indexOf(u8, msg, "disconnected") == null);
}

test "buildTurnTools: grants extend the cached prefix, they never rewrite it" {
    // WHY THIS TEST EXISTS: buildTurnTools' header promises the tools block is "turn-stable and
    // byte-identical across every inference of the turn, so it never re-bills the prompt-prefix
    // cache". Nothing asserted it. When a prefix stops matching, the provider re-bills the WHOLE
    // prefill, so the regression is invisible in dev and shows up only as a larger bill — H8's
    // "faster is an unverifiable claim", in its most expensive form. Checked EXACTLY here (byte
    // identity and pointer identity), never with a stopwatch, per harness/TESTING.md.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var counters = [_]u32{0} ** 5;
    var fmtx: std.Io.Mutex = .init;

    var ctx = tools.ToolCtx{
        .gpa = gpa,
        .io = io,
        .environ = &env,
        .run_dir = ".",
        .workdir = ".",
        .scope = "t",
        .mind = "t",
        .round = 0,
        .mem = osc.Mem.init(gpa, io, "", ""),
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .fmtx = &fmtx,
    };

    // The common case — no grants. The static base comes back BY POINTER: zero allocation, and
    // `owned` stays null so the caller frees nothing. A cost claim, counted rather than timed.
    {
        var owned: ?[]u8 = null;
        const got = buildTurnTools(gpa, &ctx, false, &owned);
        try std.testing.expect(owned == null);
        try std.testing.expect(got.ptr == TURN_TOOLS_FULL.ptr);
    }
    // SMALL-tier belt: same zero-allocation static-pointer path, a DIFFERENT and smaller array. Asserted
    // because buildTurnTools' contract is "a pure function of (caps, tier)" — if the compact path ever started
    // allocating, or quietly fell through to FULL, both the prefix-cache promise and the point of the belt
    // would go with it.
    {
        var owned: ?[]u8 = null;
        const got = buildTurnTools(gpa, &ctx, true, &owned);
        try std.testing.expect(owned == null);
        try std.testing.expect(got.ptr == TURN_TOOLS_COMPACT.ptr);
        try std.testing.expect(got.len < TURN_TOOLS_FULL.len);
    }
    // caps, and nothing else, picks the base.
    {
        ctx.caps = .sandboxed;
        var owned: ?[]u8 = null;
        const got = buildTurnTools(gpa, &ctx, false, &owned);
        try std.testing.expect(owned == null);
        try std.testing.expect(got.ptr == TURN_TOOLS_SANDBOXED.ptr);
        ctx.caps = .full;
    }

    // With grants the block is allocated — and the static base must still LEAD it, unchanged. That
    // is the entire prefix-cache property: an appended schema extends the prompt, it never rewrites
    // the part the provider already holds cached.
    const r = recipes.Recipe{ .name = "research_brief", .description = "a granted recipe", .owner_uid = 1, .params = &.{}, .steps = &.{}, .output = "" };
    const grants = [_]*const recipes.Recipe{&r};
    ctx.grants = &grants;

    var owned1: ?[]u8 = null;
    const a = buildTurnTools(gpa, &ctx, false, &owned1);
    defer if (owned1) |o| gpa.free(o);
    try std.testing.expect(owned1 != null); // now the caller DOES own it — the free contract flips
    try std.testing.expect(std.mem.startsWith(u8, a, TURN_TOOLS_FULL));
    try std.testing.expect(a.len > TURN_TOOLS_FULL.len);

    // Same grants twice ⇒ the same bytes. Any nondeterminism — map iteration order, a pointer or a
    // timestamp reaching the schema — would miss the cache on every inference after the first.
    var owned2: ?[]u8 = null;
    const b = buildTurnTools(gpa, &ctx, false, &owned2);
    defer if (owned2) |o| gpa.free(o);
    try std.testing.expectEqualStrings(a, b);
}

test "schedTaskOf: extracts the task id from a run conv, null for ordinary convs" {
    try std.testing.expectEqualStrings("news-0715174857", schedTaskOf("scheduled_news-0715174857_07151753").?);
    try std.testing.expectEqualStrings("daily-report-0301070500", schedTaskOf("scheduled_daily-report-0301070500_03010705").?);
    try std.testing.expect(schedTaskOf("c6a57f852") == null);
    try std.testing.expect(schedTaskOf("scheduled_") == null);
}

fn scrubUtf8(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const n = std.unicode.utf8ByteSequenceLength(buf[i]) catch {
            buf[i] = '?';
            i += 1;
            continue;
        };
        if (i + n > buf.len) {
            buf[i] = '?';
            i += 1;
            continue;
        }
        if (std.unicode.utf8Decode(buf[i .. i + n])) |_| {
            i += n;
        } else |_| {
            buf[i] = '?';
            i += 1;
        }
    }
}

/// Clip `s` to at most `max` bytes without splitting a UTF-8 multibyte sequence (back off through trailing high
/// bytes). Used only for the short event `preview`; the model still sees the full untruncated tool result.
fn clipBytes(s: []const u8, max: usize) []const u8 {
    var n = @min(s.len, max);
    while (n > 0 and (s[n - 1] & 0x80) != 0) n -= 1;
    return s[0..n];
}

/// How much of a tool's result rides along in its event frame.
///
/// 200 bytes was enough for a one-line chip and nothing else — the client shows roughly forty
/// characters of it, so "what did that actually return?" was unanswerable without reading the run
/// directory off disk, which a browser cannot do. 2KB is enough to see a stack trace, a JSON response,
/// or the head of a file, and it is still a bound: this lands in events.jsonl once per tool call, and
/// a long auto-loop makes many calls.
///
/// get_credential is exempt above and stays exempt — its result is a secret, and no cap makes logging
/// one acceptable.
const TOOL_PREVIEW_BYTES: usize = 2000;

/// Bounded-context sizes for the cheap auxiliary inferences (drive-loop step picker / round-cap summary).
const LOOP_CTX_BYTES: usize = 14 * 1024;
const SUMMARY_CTX_BYTES: usize = 18 * 1024;

/// The LARGEST suffix of a serialized message list (comma-joined {"role":…} objects) that fits `want` bytes
/// AND starts on a clean, VALID boundary — the "recent context" slice for cheap auxiliary inferences, which
/// must never re-prefill the whole transcript. A boundary is valid when the message is NOT role:"tool": an
/// orphaned tool result (its assistant tool_calls message cut off) 400s on strict providers. Returns the
/// full input when it already fits or no valid boundary lands inside the window (never a blind byte slice —
/// that would tear a JSON object).
fn msgTail(items: []const u8, want: usize) []const u8 {
    if (items.len <= want) return items;
    const marker = ",{\"role\":\"";
    var from = items.len - want;
    while (std.mem.indexOfPos(u8, items, from, marker)) |at| {
        const role_at = at + marker.len;
        if (role_at < items.len and items[role_at] != 't') // user/assistant/system anchor — not an orphan tool result
            return items[at + 1 ..]; // skip the joining comma — the slice starts at {"role":…
        from = role_at;
    }
    return items;
}

/// How much of a tool result rides back into the conversation context. Results append VERBATIM below this;
/// above it, the middle is elided (head + tail kept) — every later inference re-uploads every appended byte,
/// so one 100KB npm/test dump otherwise taxes EVERY subsequent call of the turn.
const TOOL_RESULT_KEEP: usize = 10 * 1024;
const TOOL_RESULT_HEAD: usize = 7 * 1024;
const TOOL_RESULT_TAIL: usize = 2 * 1024;

/// How much of the working span survives compaction VERBATIM (see compactWorking). A tail is kept at all
/// because folding the WHOLE span was itself a token sink: three unowned read_file results are 3x8000 bytes
/// plus envelopes, so they cross WORKING_COMPACT_BYTES on the very round that issues them, and the model's
/// freshly-read bytes were summarized away before it could use them. It then re-read them — rationally, since
/// a ~200-byte memory note is not the file. Observed: 14 re-reads of the same files in one turn.
///
/// The size is not a taste call: it must EXCEED one round's growth. msgTail can only anchor on a message it
/// finds at or after `span.len - keep`, and the only non-tool object in a round is the assistant tool_calls
/// message that OPENS it — so a keep smaller than a round sees nothing but orphan tool results, refuses, and
/// the whole mechanism silently no-ops. Measured over 14 rounds of 3x8000 B: 12 KiB and 16 KiB splice ZERO
/// times, 24-40 KiB splice on every round and hold the working span at ~24 KB with the newest round intact.
/// 32 KiB takes the middle of that plateau, leaving headroom for a 4-read round.
const WORKING_KEEP_TAIL_BYTES: usize = 32 * 1024;

/// Above this the span is folded WHOLE (the pre-tail behaviour) when no safe splice point exists — a single
/// enormous message, or a round so large the keep window lands entirely inside its own tool results. Re-reading
/// a file is expensive; overflowing the model window is fatal, so the safety valve wins at the extreme. Held at
/// 2x WORKING_COMPACT_BYTES: below it a spliceless span is simply left alone until the next round gives msgTail
/// something to anchor on.
const WORKING_HARD_FOLD_BYTES: usize = 48 * 1024;

/// Floor for the window-scaled working budget (see workingBudgetBytes). Small enough that a genuinely tiny
/// window still folds, large enough that one real tool round survives a fold — below this the model spends
/// every round re-reading what the previous fold deleted, which is worse than a slightly long prompt.
const WORKING_MIN_BUDGET_BYTES: usize = 6 * 1024;

/// Bytes the window must keep free for the model's own answer, when sizing the working span. num_predict is
/// 2048 tokens at the small tier (turnTokenBudget); at the same pessimistic 3 bytes/token that is ~6 KB.
const turnOutputReserveBytes: usize = 6 * 1024;

/// PROJECT a browser_read payload instead of truncating it: keep EVERY interactive ref, drop the
/// per-element JSON boilerplate. Returns null when `result` is not a browser page-state payload.
///
/// Why this exists, measured on a live x.com read (18,317 chars, 187 elements, exactly TWO of them
/// editable): the model needs the refs, and the middle-elision clip below deletes them by position.
/// Asked "which ref is the search box" (it sits 70% in), the model answered 154 from the full payload,
/// 154 from this projection — and **8** from the clipped one. Not "NONE": a confident WRONG ref it
/// would then have typed into. Truncating a ref table by byte offset is worse than useless, because the
/// thing it drops is indistinguishable, to the reader, from the thing it keeps.
///
/// The projection is 64% smaller than the raw payload (6.5KB vs 18.3KB) AND lossless in refs, so this
/// is not a quality/size trade — the boilerplate was pure cost. Editable fields are listed first and
/// labelled: they are what typing needs, and there are almost never more than a handful.
fn projectBrowserRead(gpa: std.mem.Allocator, result: []const u8) ?[]u8 {
    const t = std.mem.trim(u8, result, " \r\n\t");
    if (t.len == 0 or t[0] != '{') return null;
    if (std.mem.indexOf(u8, t, "\"elements\":[") == null) return null;
    const P = struct {
        url: []const u8 = "",
        title: []const u8 = "",
        count: u32 = 0,
        text: []const u8 = "",
        elements: []const struct {
            ref: u32 = 0,
            tag: []const u8 = "",
            type: []const u8 = "",
            name: []const u8 = "",
            edit: bool = false,
            text: []const u8 = "",
        } = &.{},
    };
    const p = std.json.parseFromSlice(P, gpa, t, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    const d = p.value;
    if (d.elements.len == 0) return null;
    var b: std.ArrayListUnmanaged(u8) = .empty;
    errdefer b.deinit(gpa);
    {
        const hdr = std.fmt.allocPrint(gpa, "page: {s} | {s} | {d} interactive elements\n(unlabelled) = the page gives this element no text at all; (dup N) = N elements share that exact label. For either, choosing by label is a guess — use coordinates (browser_click_at) or pixel_search rather than picking one and hoping.\n", .{ d.title, d.url, d.count }) catch return null;
        defer gpa.free(hdr);
        b.appendSlice(gpa, hdr) catch return null;
    }
    for ([_]bool{ true, false }) |want_edit| {
        var wrote_header = false;
        for (d.elements) |e| {
            if (e.edit != want_edit) continue;
            if (!wrote_header) {
                b.appendSlice(gpa, if (want_edit) "EDITABLE (browser_type into these refs):\n" else "CLICKABLE:\n") catch return null;
                wrote_header = true;
            }
            const label = if (e.text.len > 0) e.text else e.name;
            // MAKE AMBIGUITY VISIBLE. Measured on the live compose page (175 elements): 17 carry NO
            // label at all (blank text AND name — the extractor has nothing else to give: no href, no
            // aria-label) and 63 more share a duplicate one, eleven of them all reading "More". Rendered
            // plainly they look like 175 distinct choices, so the model picks confidently and lands
            // somewhere random — which is exactly how c6a75df8b clicked off the composer onto a trending
            // page. Naming the ambiguity does not invent information; it tells the model when its next
            // pick is a coin flip, so it can reach for coordinates or a visual read instead of guessing.
            var dupes: usize = 0;
            if (label.len > 0) {
                for (d.elements) |o| {
                    const ol = if (o.text.len > 0) o.text else o.name;
                    if (ol.len > 0 and std.mem.eql(u8, ol, label)) dupes += 1;
                }
            }
            // the markers stay TERSE and are explained once in the header — spelling the warning out per
            // element cost more bytes than the boilerplate this projection exists to remove (caught by the
            // size assertion in the projection test, on a page where every label was identical)
            const line = if (label.len == 0)
                std.fmt.allocPrint(gpa, "  [{d}] {s} (unlabelled)\n", .{ e.ref, e.tag }) catch return null
            else if (dupes > 1)
                std.fmt.allocPrint(gpa, "  [{d}] {s} {s} (dup {d})\n", .{ e.ref, e.tag, clipBytes(label, 90), dupes }) catch return null
            else
                std.fmt.allocPrint(gpa, "  [{d}] {s} {s}\n", .{ e.ref, e.tag, clipBytes(label, 90) }) catch return null;
            defer gpa.free(line);
            b.appendSlice(gpa, line) catch return null;
        }
    }
    if (d.text.len > 0) {
        b.appendSlice(gpa, "PAGE TEXT:\n") catch return null;
        b.appendSlice(gpa, clipBytes(d.text, BROWSER_TEXT_KEEP)) catch return null;
    }
    return b.toOwnedSlice(gpa) catch null;
}
const BROWSER_TEXT_KEEP: usize = 3 * 1024; // the prose half of a page read; refs are never clipped

/// Clip an oversized tool result to head + elision note + tail (UTF-8-boundary safe). Returns `result`
/// unchanged (same pointer) when it already fits; otherwise a NEW gpa string (caller frees whichever it holds).
/// A browser page-state payload takes the lossless projection above INSTEAD — see projectBrowserRead for why
/// byte-offset truncation of a ref table produces confidently wrong clicks.
fn clipToolResult(gpa: std.mem.Allocator, result: []const u8) []u8 {
    if (projectBrowserRead(gpa, result)) |proj| {
        if (proj.len < result.len) return proj;
        gpa.free(proj);
    }
    if (result.len <= TOOL_RESULT_KEEP) return @constCast(result);
    const head = clipBytes(result, TOOL_RESULT_HEAD);
    var tstart = result.len - TOOL_RESULT_TAIL;
    while (tstart < result.len and (result[tstart] & 0xC0) == 0x80) tstart += 1; // never start mid-codepoint
    const tail = result[tstart..];
    return std.fmt.allocPrint(gpa, "{s}\n...[{d} bytes elided from the middle of this tool result — it was too large to keep in full. The head and tail above/below are verbatim; re-run the tool with a narrower target if you need the elided part.]...\n{s}", .{ head, result.len - head.len - tail.len, tail }) catch @constCast(result);
}

/// Append one message object to messages.jsonl as a COMPLETE single line: {"role":..,"content":..,"kind":..,"ts":N}.
/// The whole escaped line is built first, then appended, so a reader never sees a partial/multiline object.
fn appendMsg(app: *App, conv_dir: []const u8, role: []const u8, content: []const u8, kind: []const u8, ts: i64) void {
    const gpa = app.gpa;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    line.appendSlice(gpa, "{\"role\":") catch return;
    http.jstr(gpa, &line, role) catch return;
    line.appendSlice(gpa, ",\"content\":") catch return;
    http.jstr(gpa, &line, content) catch return;
    line.appendSlice(gpa, ",\"kind\":") catch return;
    http.jstr(gpa, &line, kind) catch return;
    const tail = std.fmt.allocPrint(gpa, ",\"ts\":{d}}}\n", .{ts}) catch return;
    defer gpa.free(tail);
    line.appendSlice(gpa, tail) catch return;
    const path = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return;
    defer gpa.free(path);
    http.appendFile(app.io, gpa, path, line.items) catch {};
}

/// Emit the turn's token USAGE (the delta of the process token counters since `t0`, i.e. this turn's tokens) as a
/// `{"kind":"usage",...}` frame. Snapshotted BEFORE any deferred end-of-turn maintenance (the rolling-summary
/// refresh) so the displayed usage reflects the ANSWER's tokens, not background summarization. Zero delta = no frame.
fn emitUsage(app: *App, conv_dir: []const u8, t0: llm.TokUsage) void {
    const t1 = llm.tokensSnapshot();
    const din = if (t1.in >= t0.in) t1.in - t0.in else 0;
    const dout = if (t1.out >= t0.out) t1.out - t0.out else 0;
    const dcached = if (t1.cached >= t0.cached) t1.cached - t0.cached else 0;
    if (din > 0 or dout > 0) {
        var b: [160]u8 = undefined;
        emitEvent(app, conv_dir, std.fmt.bufPrint(&b, "{{\"kind\":\"usage\",\"tokens_in\":{d},\"tokens_out\":{d},\"text\":\"{d} tokens in · {d} out\"}}", .{ din, dout, din, dout }) catch "{\"kind\":\"usage\"}");
        metrics.record(app, din, dout, dcached, nowSecs(app.io)); // one Dashboard metrics line per finished turn
    }
}

/// Emit the turn's usage then the terminal `{"kind":"done"}`. Used at the STOP / error / empty completion paths
/// (which must end promptly — no deferred summary work). The NORMAL completion path emits usage, runs the deferred
/// summary refresh, THEN done inline (so {done} still comes last), instead of calling this.
fn finishTurn(app: *App, conv_dir: []const u8, t0: llm.TokUsage) void {
    emitUsage(app, conv_dir, t0);
    emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
}

/// Append `obj` (a complete, already-escaped single-line JSON object) as one line to events.jsonl.
fn emitEvent(app: *App, conv_dir: []const u8, obj: []const u8) void {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/events.jsonl", .{conv_dir}) catch return;
    defer gpa.free(path);
    const line = std.fmt.allocPrint(gpa, "{s}\n", .{obj}) catch return;
    defer gpa.free(line);
    http.appendFile(app.io, gpa, path, line) catch {};
}

/// Emit `{"kind":<kind>,"<field>":<value>}` with `value` JSON-escaped. Covers the message/error/reasoning
/// events (one string payload); the multi-field tool events are built inline.
fn emitKV(app: *App, conv_dir: []const u8, kind: []const u8, field: []const u8, value: []const u8) void {
    const gpa = app.gpa;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    ev.appendSlice(gpa, "{\"kind\":") catch return;
    http.jstr(gpa, &ev, kind) catch return;
    ev.append(gpa, ',') catch return;
    http.jstr(gpa, &ev, field) catch return;
    ev.append(gpa, ':') catch return;
    http.jstr(gpa, &ev, value) catch return;
    ev.append(gpa, '}') catch return;
    emitEvent(app, conv_dir, ev.items);
}

// ---- PER-CALL MODEL ATTRIBUTION ON THE EVENT STREAM ---------------------------------------------------------
// One `{"kind":"llm",...}` frame per COMPLETED LLM call of a turn, carrying the model that ACTUALLY served it.
// Under the trio a single turn is served by up to three different models at three different prices, and until
// now the event stream said nothing about which — a client watching a turn could not tell whether the slow part
// was the coder, the planner, or the driver, and a per-turn `usage` frame cannot express it either.
//
// The frame is emitted BESIDE llm.zig's own per-call meter and reads the SAME numbers: `in`/`out` are the delta
// of llm.tokensSnapshot() (the thread-local total llm.zig folds each call's usage into, which is also what
// metrics.zig bills), so the stream and the Dashboard cannot drift apart. Failures are emitted too (`ok:false`,
// and a failed call has no usage so its token counts are honestly 0) — otherwise a success rate read off the
// stream would be 100% by construction.
//
// `streamed` SAYS WHETHER `fb_ms` IS A REAL FIRST-BYTE TIME. Exactly one of the ten labeled calls in a turn goes
// through llm.completeStream ("chat"); the other nine — plan, loop, lesson, summary, searchq, stuck, reflect,
// ctxsum, compact — are blocking llm.complete, where the engine sees the whole body arrive at once and has NO
// first byte to time. Their fb_ms is the total call time wearing a first-byte label, so a panel that averaged
// fb_ms across the trio showed the thinking/prompting models one to two orders of magnitude "slower to first
// byte" than the coder purely as a measurement artifact. Consumers must NOT mix the two: a non-streamed sample
// still counts toward turns / tok-s / success / turn-time and is EXCLUDED from any first-byte average or chart.
// A frame with NO `streamed` field came from an older server and MUST be read as false — the safe reading,
// because it means we cannot vouch for the number either way.
//
// Consumers ignore unknown kinds: the web app's applyFrame falls through to `default: return false`, the desk's
// renderScFrame falls through to "any other kind: not rendered", and the CLI's renderConvFrames only matches
// token/tool/status. Verified before adding the kind — see the task report.

/// The conv_dir whose events.jsonl the turn on THIS thread writes to. Thread-local for the same reason
/// metrics.zig's turn context is: a turn runs start-to-finish on one thread, and the labeled LLM calls are
/// scattered across ten helpers, six of which never receive conv_dir. Armed at runTurn entry, cleared on exit.
threadlocal var llm_frame_dir: [1024]u8 = undefined;
threadlocal var llm_frame_dir_len: usize = 0;

fn armLlmFrames(conv_dir: []const u8) void {
    // A TRUNCATED path is worse than none — it would name a different directory. Refuse instead.
    if (conv_dir.len == 0 or conv_dir.len > llm_frame_dir.len) {
        llm_frame_dir_len = 0;
        return;
    }
    @memcpy(llm_frame_dir[0..conv_dir.len], conv_dir);
    llm_frame_dir_len = conv_dir.len;
}

fn disarmLlmFrames() void {
    llm_frame_dir_len = 0;
}

/// One LLM call, measured from the engine's side of the transport: wall time, this thread's token delta, and
/// (streaming only) the moment the first delta landed. Taken before the call, closed out after it.
const CallMeter = struct {
    t0_ms: i64,
    tok0: llm.TokUsage,
    /// Wall-clock ms of the first streamed delta, or 0 when nothing streamed. Only the streaming chat call can
    /// set this; llm.completeStream falls back to a non-streaming complete() on any trouble, in which case it
    /// stays 0 exactly as it does for a call that was never streaming to begin with.
    ///
    /// This is ALSO the sole source of the frame's `streamed` flag (see meterEnd): non-zero here means a delta
    /// was genuinely observed, which is the only condition under which the emitted fb_ms is a real first-byte.
    fb_ms: i64 = 0,
};

fn meterBegin(io: std.Io) CallMeter {
    return .{ .t0_ms = nowMillis(io), .tok0 = llm.tokensSnapshot() };
}

/// Close a measured call out onto the event stream. `model` must be the model the call actually ran on (the
/// role's resolved Provider.model), never the turn's configured default — that is the whole point of the frame.
///
/// `streamed` IS DERIVED FROM THE METER, not passed in per call site, and that is deliberate: it must report
/// what the transport actually did, and only `m.fb_ms` knows. It is an absolute wall-clock stamp written by
/// streamOnDelta, so it is non-zero if and only if at least one delta was observed. The nine blocking sites
/// never touch it (false by construction — the safe default a forgotten new call site also gets), and the one
/// streaming site is true only when deltas really landed: llm.completeStream silently falls back to a blocking
/// complete() on any streaming trouble, and a hardcoded `true` at that site would then be a lie.
fn meterEnd(app: *App, m: CallMeter, label: []const u8, role: Role, model: []const u8, ok: bool) void {
    const r = meterReport(m, nowMillis(app.io));
    const t1 = llm.tokensSnapshot();
    emitLlmFrame(
        app,
        label,
        role,
        model,
        r.ms,
        r.fb_ms,
        r.streamed,
        if (t1.in >= m.tok0.in) t1.in - m.tok0.in else 0,
        if (t1.out >= m.tok0.out) t1.out - m.tok0.out else 0,
        ok,
        nowSecs(app.io),
    );
}

/// The three timing numbers a closed-out call reports, and the whole of the fb_ms/streamed relationship. Pure
/// (clock passed in) so that relationship is testable without a server, an App, or a real inference.
fn meterReport(m: CallMeter, now_ms: i64) struct { ms: u64, fb_ms: u64, streamed: bool } {
    const ms: u64 = @intCast(@max(now_ms - m.t0_ms, 0));
    const streamed = m.fb_ms > 0;
    // A non-streamed call has no first byte the engine can observe before its last one — the whole body arrives
    // in a single blocking return — so its fb_ms is its ms. The VALUE IS KEPT (rather than zeroed) and the
    // `streamed:false` flag carries the meaning: zeroing would be indistinguishable from an absent field after
    // any parse-with-default, would read as an instant response to a consumer that ignores the flag, and would
    // change what already-shipped readers compute — this field feeds a `total - fb` generation window that is
    // then divided into. Adding the flag is purely additive; rewriting the number would not be.
    return .{ .ms = ms, .fb_ms = if (streamed) @intCast(@max(m.fb_ms - m.t0_ms, 0)) else ms, .streamed = streamed };
}

fn emitLlmFrame(app: *App, label: []const u8, role: Role, model: []const u8, ms: u64, fb_ms: u64, streamed: bool, tin: u64, tout: u64, ok: bool, ts: i64) void {
    if (llm_frame_dir_len == 0) return; // no turn armed on this thread — nowhere to write
    const gpa = app.gpa;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    renderLlmFrame(gpa, &ev, label, role, model, ms, fb_ms, streamed, tin, tout, ok, ts) catch return;
    emitEvent(app, llm_frame_dir[0..llm_frame_dir_len], ev.items);
}

/// Render the shared `llm` frame into `out`. Split from the emit so its exact wire shape is testable without a
/// server, an App, or a turn. `model` is BYOK-supplied text and is JSON-escaped; role/label are engine-owned.
/// `streamed` sits next to `fb_ms` on the wire because it is the qualifier ON fb_ms — read either alone and you
/// read a number whose meaning you don't know.
fn renderLlmFrame(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), label: []const u8, role: Role, model: []const u8, ms: u64, fb_ms: u64, streamed: bool, tin: u64, tout: u64, ok: bool, ts: i64) !void {
    try out.appendSlice(gpa, "{\"kind\":\"llm\",\"model\":");
    try http.jstr(gpa, out, model);
    try out.appendSlice(gpa, ",\"role\":");
    try http.jstr(gpa, out, @tagName(role));
    try out.appendSlice(gpa, ",\"label\":");
    try http.jstr(gpa, out, label);
    var b: [240]u8 = undefined;
    const tail = try std.fmt.bufPrint(&b, ",\"ms\":{d},\"fb_ms\":{d},\"streamed\":{s},\"in\":{d},\"out\":{d},\"ok\":{s},\"ts\":{d}}}", .{ ms, fb_ms, if (streamed) "true" else "false", tin, tout, if (ok) "true" else "false", ts });
    try out.appendSlice(gpa, tail);
}

/// Run one full agentic turn for `conv` (already safeSeg'd, non-empty). Blocks the calling httpz worker thread
/// to completion (casts/deploys block the same way); on return the whole turn is durable in messages/events.jsonl.
pub fn runTurn(app: *App, uid: u64, conv: []const u8, trio: ModelTrio, user_text: []const u8, loop: u8, tool_client_req: bool, image_b64: []const u8, fast: bool) void {
    const gpa = app.gpa;

    // TOOL DELEGATION IS ADMIN-ONLY, and the check belongs HERE rather than at the delegation branch.
    // `tool_client` arrives as a plain bool on the request body (chat/service.zig), so it is caller-controlled:
    // any authed user could send `{"tool_client":true}`. That flag routes tool calls to a client harness via
    // delegateTool INSTEAD of tools.execute — and the sandbox gate that confines non-admins to their own
    // workspace lives inside tools.execute. Delegating therefore walked straight around the one enforcement
    // point, for run_python and host_command included. Gating the whole turn (not just the dispatch branch)
    // keeps every downstream reader — cast file sync, syncDirTool, awaitConvCast — on the same answer.
    // Legitimate clients are unaffected: the desk authenticates as admin, and the web UI omits the flag
    // entirely (see the note in web/public/app.js) because the server executes its tools.
    const is_admin = if (app.auth.userById(uid)) |cu| app.auth.isAdmin(cu) else false;
    const tool_client = tool_client_req and is_admin;

    // The trio splits this turn's LLM calls across three models. `coding` is the base/default (the main answer
    // stream, metrics attribution, cast/schedule inheritance); `think` drives planning + context housekeeping;
    // `prompt` drives the auto-loop self-prompt-back. An unset thinking/prompting role resolves back to coding
    // (see ModelTrio.pick), so a single-model client behaves exactly as before.
    const coding = trio.coding;
    const think = trio.pick(.thinking);
    const prompt = trio.pick(.prompting);

    // Arm this thread's LLM-usage recorder: emitUsage (the one usage choke-point, reached on every turn
    // completion path) records one per-model metrics line for the Dashboard. Thread-local, so none of the
    // eleven finish paths needs the model/uid threaded through. Attributed to the coding/base model.
    metrics.beginTurn(uid, coding.model, coding.base_url, schedTaskOf(conv) != null, nowSecs(app.io));
    defer metrics.endTurn();

    // ---- store + build paths (conv store under convs/, build tree under builds/ — same split as runMindTool) ----
    const base = std.fmt.allocPrint(gpa, "{s}/u{d}/_chat", .{ app.data, uid }) catch return;
    defer gpa.free(base);
    const conv_dir = std.fmt.allocPrint(gpa, "{s}/convs/{s}", .{ base, conv }) catch return;
    defer gpa.free(conv_dir);
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, conv_dir, .default_dir) catch {};

    // Arm this thread's per-call `llm` frame target. Same thread-local trick as metrics.beginTurn above, and for
    // the same reason: the ten labeled call sites live in helpers that mostly never see conv_dir. Disarmed on
    // every exit path so a recycled thread can never append a stray frame to a finished conversation.
    armLlmFrames(conv_dir);
    defer disarmLlmFrames();

    // ---- HIPPOCAMPUS scope: this conversation's own durable neuron-db partition (user turns + tool findings).
    // SCHEDULED RUNS get a TASK-scoped partition instead: every run of "scheduled_{taskid}_{stamp}" shares
    // "sched:{taskid}", so the recall at run start surfaces previous runs' lessons/answers and everything this
    // run observes (the prompt, tool findings, the model's own observe() calls) persists into the NEXT run —
    // the task learns from its own failures and successes across runs, independent of any one conversation.
    const sched_task = schedTaskOf(conv);
    const mem_scope = if (sched_task) |tid|
        (std.fmt.allocPrint(gpa, "sched:{s}", .{tid}) catch return)
    else
        (std.fmt.allocPrint(gpa, "chat:{s}", .{conv}) catch return);
    defer gpa.free(mem_scope);

    // FILE LEDGER (the fine-needle memory weave, ground-truth half): every landed file mutation — server-
    // executed OR delegated to the client — is captured from the tool's own success result at the dispatch
    // point, persisted to {conv_dir}/files.jsonl, and loaded back here at every turn start. The drive loop
    // weaves it into each step, so "which files exist?" is answered by the ENGINE, not by the model burning
    // steps on re-verification (or concluding "the write succeeded" from a failed read — observed live).
    var file_ledger: FileLedger = .{};
    defer file_ledger.deinit(gpa);
    ledgerLoad(app, conv_dir, &file_ledger);

    // ---- COOPERATIVE-STOP cursor: only control.jsonl ops written AFTER this byte offset count for THIS turn ----
    const ctrl_cursor = controlLen(app, conv_dir);
    // PUBLISH it, immediately and before any other work: /control answers "will this op be read?" by comparing
    // the offset its line landed at against this number. Until it is published that endpoint reports "no", which
    // is the truth — a cursor snapshotted later than an op is a cursor that skips it.
    publishCtrlCursor(app.io, conv, ctrl_cursor);

    // CLIENT-MODE: truncate the delegated-tool-results channel so this turn's scanToolChannel scan starts clean
    // (results are keyed by call id, but resetting keeps the file from growing across a long conversation).
    if (tool_client) {
        if (std.fmt.allocPrint(gpa, "{s}/tool_results.jsonl", .{conv_dir})) |trp| {
            defer gpa.free(trp);
            std.Io.Dir.cwd().deleteFile(app.io, trp) catch {};
        } else |_| {}
    }

    // ---- record the user's message BEFORE anything else, so it's durable even if the LLM call dies ----
    appendMsg(app, conv_dir, "user", user_text, "user", nowSecs(app.io));
    emitUserRole(app, conv_dir, user_text); // {"kind":"message","role":"user","content":..}

    const environ = app.sup.parent_env orelse {
        emitKV(app, conv_dir, "error", "err", "server env unavailable");
        emitEvent(app, conv_dir, "{\"kind\":\"done\"}"); // the desk disarms only on {done}; an error alone would hang it
        return;
    };

    // USAGE: snapshot the process token counters BEFORE any LLM work (plan decomposition, history summary, drive,
    // reflect, the agentic loop) — finishTurn emits the delta as this turn's usage at every completion path.
    const usage_t0 = llm.tokensSnapshot();

    // ---- ToolCtx: byte-for-byte the chat_tools.runMindTool construction (per-uid store, builds/{conv} tree;
    // a SCHEDULED run's tree lives under its task's permanent _sched/{task}/runs/{stamp} dir — see paths.zig) ----
    var rrb: [700]u8 = undefined;
    const run_root_m = cpaths.buildRootFromChatBase(&rrb, base, conv);
    if (run_root_m.len == 0) return;
    const run_root = gpa.dupe(u8, run_root_m) catch return;
    defer gpa.free(run_root);
    const workdir = std.fmt.allocPrint(gpa, "{s}/work", .{run_root}) catch return;
    defer gpa.free(workdir);
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, workdir, .default_dir) catch {};
    // LLM SCRATCH DIR — the CONV dir, never the build root. llm.zig keys its per-call scratch
    // (.curlcfg-<tag>, .llmreq-<tag>.json, .stream-<tag>.sse) by (dir, tag), and a SUB-CHAT FAMILY
    // shares run_root: two concurrent family turns both labeled "chat" would collide on the same
    // files — observed live (c6a61ff12): s2's stream read s1's half-written .stream-chat.sse tail
    // and committed it as s2's reply, and the overwritten request body broke s1's thinking-mode
    // reasoning_content echo-back. conv_dir is unique per conversation by construction.
    const llm_dir = conv_dir;
    // RESTART RESUME: an empty ledger over a non-empty workdir (client restart, pre-ledger conversation)
    // seeds from a bounded disk survey — a "continue" turn then continues FROM the existing build instead
    // of re-scaffolding it from zero (the observed restart bug in c6a594cb1).
    ledgerBootstrap(app, workdir, &file_ledger);
    const db = std.fmt.allocPrint(gpa, "{s}/hive.sqlite", .{base}) catch return;
    defer gpa.free(db);
    var durable_pb: [700]u8 = undefined; // backs ctx.durable_path for the turn (same lifetime pattern as db)

    var counters = [_]u32{0} ** 5;
    // Lives for the whole turn: `ctx.cancel` borrows it, and a tool may consult it minutes from here.
    var tool_stop = ToolStopCtx{ .app = app, .conv_dir = conv_dir, .ctrl_cursor = ctrl_cursor };
    var ctx = tools.ToolCtx{
        .gpa = gpa,
        .io = app.io,
        .cancel = .{ .fn_ptr = toolShouldStop, .ctx = &tool_stop },
        .environ = environ,
        .run_dir = run_root,
        .workdir = workdir,
        // recall()/observe() tools work THIS conversation's own memory partition — the same scope the
        // engine's turn-start recall reads and its tool-finding observes write. (They used to point at the
        // shared "chat" scope for ordinary chats, which meant the model could NEVER recall what the engine
        // had observed for this conversation, and vice versa — the two memory loops never met. recall_hive
        // still covers the shared KNOWLEDGE/INTEL/SKILL scopes, and the observe tool still dual-writes the
        // hive.) DIRECTORY ISOLATION (strict): a scheduled run executes tools SERVER-side with roam=false
        // (the ToolCtx default — only the client executor ever sets it), so every file tool is jailed to
        // this run's builds/{conv}/work by safeRel, exactly like a chat.
        .scope = mem_scope,
        .mind = "chat",
        .round = 0,
        // The chat hive db is shared across ALL of this user's conversations: keep conversation-local
        // project state (files/lines/workdir) out of the global KNOWLEDGE scope, and provenance-tag what
        // does globalize — the read side (stepWeave) relevance-gates the same scope.
        .hive_guard = true,
        // get_credential's store: the chat veil acts AS the user, so it may fetch a withheld credential
        // value in the turn that needs it (values are masked out of every broadcast prompt).
        .durable_path = memoriesPath(app, uid, &durable_pb) orelse "",
        .mem = blk_mem: {
            var m = osc.Mem.init(gpa, app.io, app.sup.neuron_bin, db);
            // TRUST-WEIGHTED RANKING: the trust feature is compiled in; without this flag every assoc runs
            // unweighted and a strengthen-reinforced fact from an unrelated project can outrank this
            // conversation's own records on one shared generic stem.
            m.trust = true;
            break :blk_mem m;
        },
        .files_written = &counters[0],
        .observed = &counters[1],
        .skills_saved = &counters[2],
        .directives_set = &counters[3],
        .tools_made = &counters[4],
        .internet = true,
        // RECALL_HIVE SECOND STAGE. tools.zig gates the reranker on gw_model.len > 0, and a chat turn never set
        // these — so recall_hive returned raw first-stage hits (and could never ABSTAIN) for every chat that has
        // ever run, while only a swarm mind got the reranked read. Point them at the THINKING model: judging
        // whether a recalled fact is relevant to the query is exactly the role's job, and it keeps the judgement
        // off the coding model's stream. An unset thinking role resolves back to coding via trio.pick, so this is
        // never empty when the turn has a provider at all.
        .gw_base = think.base_url,
        .gw_key = think.key,
        .gw_model = think.model,
        .fmtx = &chat_vcs_mtx,
        .vcs_enabled = conv.len > 0,
        // TAG-ANCHORED READS on the chat surface. edit_file's schema advertises the `42:abc:def` dialect to
        // every turn ("PREFERRED anchors"), but only run.zig (swarm minds) ever set this flag — so a chat read
        // came back UNTAGGED and every chat edit fell through to bufedit's verbatim-text matching. On a large
        // file that path is where edits go to die: a snippet retyped from a HEAD-CLIPPED read is "anchor not
        // found", a short one is "matches more than one place", and the model's escape hatch is a write_file
        // overwrite/append that reconstructs the file from what it could see — the duplicated methods and
        // shredded files this fixes. Tags validate against the file AS IT IS NOW, the batch is atomic, and a
        // stale tag hands back FRESH tags for an immediate retry.
        .anchored_reads = true,
        // THE SANDBOX. A non-admin's prompts are not trusted with the host, so their turn runs the
        // restricted surface: files (already jailed to this conversation's workdir), research, and the
        // whole hive-memory surface — but no code execution, host control, engine self-modification,
        // tool authoring, or browser/MCP drive. Derived from the caller here rather than threaded
        // through runTurn's signature: the uid is already the thing every path in this function keys on,
        // and one lookup beats changing five signatures to carry a bool alongside it.
        .caps = if (app.auth.userById(uid)) |cu| (if (app.auth.isAdmin(cu)) .full else .sandboxed) else .sandboxed,
    };

    // GRANTED RECIPES (I3): resolve this caller's recipe allowlist ONCE, right where caps was decided — the
    // same turn-stable, per-user discipline the tool schema follows. Admin ⇒ the whole registry; a sandboxed
    // caller ⇒ the registry ∩ their tool_grants. Empty (feature inert) until the admin route wires app.recipes.
    // execute()/runRecipe read ctx.grants to route a granted name through the recipe dispatch as DATA.

    ctx.grants = resolveGrants(app, uid, is_admin, gpa);
    defer gpa.free(ctx.grants);

    // The tools array this turn advertises: the caller's static CAPS variant plus each granted recipe's schema,
    // built ONCE (byte-identical across the turn's inferences → prefix-cache safe) and threaded into
    // runInnerAgentic so every drive pass sends the SAME bytes.
    var turn_tools_owned: ?[]u8 = null;
    defer if (turn_tools_owned) |t| gpa.free(t);
    // SMALL-tier models get the compact belt (tools.COMPACT_TOOLS): 49 tool defs — 35 KB, ~75% of the request —
    // is surface a 12B model cannot pick through, and it demonstrably reached for invented and irrelevant tools
    // instead of the one it needed. Keyed on this turn's CODING model (the role that actually emits tool calls)
    // and on nothing that varies with message content, so the array stays turn-stable and prefix-cache safe.
    const tier_local = std.mem.indexOf(u8, trio.coding.base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, trio.coding.base_url, "localhost") != null;
    const compact_belt = modelcfg.senseModel(trio.coding.model, tier_local).tier == .small;
    var turn_tools = buildTurnTools(gpa, &ctx, compact_belt, &turn_tools_owned);
    // PLUGIN TOOLS: advertise every loaded plugin's tools (plug_<name>_<tool>) after the built-ins + grants.
    // reg.schemas is registry-stable and already ",\n"-prefixed, so it splices cleanly into the tools array
    // and stays byte-identical across the turn's inferences — the same prefix-cache discipline buildTurnTools
    // follows. execute-side interception (below) routes these names to the plugin executor.
    if (plugins.current(&app.plugs)) |preg| {
        if (preg.schemas.len > 0) {
            if (std.fmt.allocPrint(gpa, "{s}{s}", .{ turn_tools, preg.schemas })) |merged| {
                if (turn_tools_owned) |old| gpa.free(old);
                turn_tools_owned = merged;
                turn_tools = merged;
            } else |_| {}
        }
    }

    // ---- seed the LLM conversation: system prompt + every persisted message (incl. the user turn just added) ----
    // `conv_buf` is the INSIDE of "messages":[ … ]; it grows in the loop with the assistant tool_call turns and
    // tool-result turns so the model always sees full context. First object has no leading comma; rest do.
    var conv_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer conv_buf.deinit(gpa);
    conv_buf.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return;
    // Tier-paired with the belt: the compact belt gets the compact prompt. One decides WHAT is advertised, the
    // other WHAT is taught — a small model must never be taught a verb its belt doesn't advertise (the
    // recall_hive/cast class). Keyed on the same turn-stable compact_belt bool, so prefix caching still holds.
    //
    // DATE GROUNDING, every tier: no model knows what day it is, and a small one confidently invents dates —
    // observed live, a 12B researching current events date-qualified its searches with THREE different wrong
    // years in one turn ("last 24 hours January 30-31 2025" … in July 2026), which quietly poisons every
    // time-sensitive query. Turn-stable (changes once a day, never per message), so prefix caching holds.
    {
        var dstamp: [16]u8 = undefined;
        const sys_base: []const u8 = if (compact_belt) SYSTEM_PROMPT_COMPACT else SYSTEM_PROMPT;
        // BELT MANIFEST — compact tier ONLY: the one-line tool index (see beltManifest). Derived from
        // `turn_tools` AFTER grants and plugin schemas merged above, so every def the provider will
        // see is named on the line; the full tier reads its belt fine and pays nothing.
        const manifest: ?[]u8 = if (compact_belt) beltManifest(gpa, turn_tools) else null;
        defer if (manifest) |m| gpa.free(m);
        const dated = std.fmt.allocPrint(gpa, "{s}{s}\nTODAY (UTC): {s}. Any time-sensitive search query, date, or claim must be grounded in THIS date — never a guessed one.", .{ sys_base, manifest orelse "", tools.dateStamp(app.io, &dstamp) }) catch null;
        defer if (dated) |d| gpa.free(d);
        http.jstr(gpa, &conv_buf, dated orelse sys_base) catch return;
    }
    conv_buf.append(gpa, '}') catch return;

    // PROMPT WORKSPACE: every non-transcript context block this turn (durable memory, tool digest/belt, image
    // OCR, recall, corrections, family, plugin hooks, the file ledger) is a BID — typed, provenance-tagged,
    // scored — packed ONCE into three channels under per-channel byte budgets, with the admit/drop record
    // appended to {conv}/workspace.jsonl. Channel placement preserves the cache discipline the direct appends
    // had: prefix blocks are turn-stable and render right after the system prompt; varying blocks land AFTER
    // the stable prefix (system + durable memory + summary + goal) and right before the recency window — they
    // change with every message, and injecting them early invalidated the provider's prompt-prefix cache for
    // everything behind them (the whole window re-billed as fresh prefill on every inference); the ledger
    // rides after the window. Additive: an empty workspace changes nothing.
    var ws = wsp.Workspace.init(gpa);
    defer ws.deinit();
    // THE GOAL ANCHOR, hoisted to turn scope. From the SECOND server turn onward `user_text` is not the
    // user's goal at all — it is the desk's own kick sentence ("Auto-loop armed: continue driving toward the
    // goal…"), because that is what the desk posts to re-arm. Every downstream consumer that thinks it is
    // reading the goal was reading the engine's own re-drive text, which is why an afk session appeared to
    // stop evolving: the anchor it re-grounded to WAS the anchor text. This resolution already existed and
    // was already correct — it was just scoped to the recall block below and freed before the drive loop.
    var goal_owned: ?[]u8 = null;
    defer if (goal_owned) |g| gpa.free(g);
    // A META-QUESTION IS NEVER THE GOAL (see metaQuestionShaped). Unlike the continuation case below, this
    // substitution is NOT afk-only: a tier-0/1 user who types "are you stuck?" in the middle of a build is asking
    // ABOUT the work, not replacing it, and every steering surface must keep pointing at the work. Nothing is
    // hidden from the model — the question is still delivered verbatim as the user turn it was, and still gets
    // answered; only the GOAL ANCHOR is held steady. The tier-0/1 caution in the note below is about silently
    // swapping a user's real instruction ("continue"), which this cannot do: a question is not an instruction.
    const meta_q = metaQuestionShaped(user_text);
    if (continuationShaped(user_text) or meta_q) goal_owned = firstUserGoal(app, conv_dir);
    // The real goal for everything that steers — AFK ONLY. Recall has substituted the pinned goal on a
    // continuation-shaped turn for a long time, but that is ADDITIVE and hedged: it widens what gets
    // remembered and cannot change what the turn does. Substituting it into the STEERING inputs replaces
    // the thing the drive picker, the course check and the repeat guard reason about, and in tier 0/1 a
    // user who simply types "continue" would silently have their message swapped for a goal pinned turns
    // ago. Tier 1 keeps reading user_text exactly as before; only afk, whose "user_text" is the desk's own
    // kick sentence rather than anything a human wrote, gets the substitution. NOT for the hippocampus
    // observe either — the message the user really sent is what belongs in memory.
    const goal_text: []const u8 = if (meta_q or loop >= LOOP_AFK) (if (goal_owned) |g| g else user_text) else user_text;
    {
        // RESUME CUE: a continuation-shaped turn ("continue", the desk's auto-loop arm) carries no recall
        // cue of its own — keyed on the literal word, recall surfaces nothing and the resumed turn starts
        // unanchored (observed: a restart's "continue" re-scaffolded the whole build). Key it on the
        // conversation's pinned GOAL instead: the memories of the actual work come back.
        const recall_query: []const u8 = goal_text;
        // SCORED RECALL first (a neuron binary with `recallscored`): numbers cross the seam as numbers —
        // the top hit's coverage rides the workspace bid as MEASURED confidence (rendered in the receipt,
        // recorded in the decision log), facts are numbered so the verifier below can cite them, and
        // consolidation's --check marks surface inline as CONTESTED with the disagreeing sibling's text.
        // An older binary (unknown verb → exit 2 → "") or an empty scope falls through to the legacy
        // prose path, byte-identical to before.
        const rs_raw = ctx.mem.recallScored(mem_scope, recall_query, 6);
        defer gpa.free(rs_raw);
        var scored_ok = false;
        if (rs_raw.len > 0) scored: {
            scrubUtf8(rs_raw);
            const parsed = std.json.parseFromSlice(ScoredRecall, gpa, rs_raw, .{ .ignore_unknown_fields = true }) catch break :scored;
            defer parsed.deinit();
            const hits = parsed.value.hits;
            if (hits.len == 0) break :scored;
            scored_ok = true;
            var mem_content: std.ArrayListUnmanaged(u8) = .empty;
            defer mem_content.deinit(gpa);
            mem_content.appendSlice(gpa, if (sched_task != null)
                "TASK MEMORY — lessons, outcomes, and findings from PREVIOUS RUNS of this scheduled task, numbered, strongest match first. USE them: prefer sources/approaches that worked, skip recorded pitfalls, keep stated assumptions, and improve on the last run instead of starting from zero:\n"
            else
                "RELEVANT MEMORY — facts recalled from this conversation's memory (earlier turns, tool findings), numbered, strongest match first. Treat as grounded context:\n") catch return;
            var contested_n: u32 = 0;
            for (hits, 1..) |h, num| {
                var nb2: [12]u8 = undefined;
                mem_content.appendSlice(gpa, std.fmt.bufPrint(&nb2, "{d}. ", .{num}) catch "- ") catch return;
                mem_content.appendSlice(gpa, h.fact) catch return;
                if (h.contested) {
                    contested_n += 1;
                    mem_content.appendSlice(gpa, " [CONTESTED — a stored fact disagrees: \"") catch return;
                    mem_content.appendSlice(gpa, clipBytes(h.with orelse "", 160)) catch return;
                    mem_content.appendSlice(gpa, "\"]") catch return;
                }
                mem_content.append(gpa, '\n') catch return;
            }
            // The workspace cap bounds the whole block (header + numbered facts + contested notes) at the
            // same order as the legacy 1500-byte fact clip; the receipt says so when it bites.
            const top_conf: f32 = @floatCast(hits[0].coverage);
            ws.bidConf(.recall, mem_scope, mem_content.items, 0.60, 1800, @intCast(hits.len), top_conf);

            // TIER-2 VERIFIER, sentinel-gated (NL_MEM_VERIFY=0 disables): contested marks or a weak top
            // hit trigger ONE bounded no-tools completion on the THINKING role to audit the block BEFORE
            // the main inference reads it — decorrelated whenever the trio routes thinking to a different
            // model. Verdicts ANNOTATE, never delete: dropping memory on a model's say-so is the
            // recall-pollution class inverted. A doubted fact gets a caution note bid directly after the
            // recall block (Kind order), and the workspace log records the whole decision.
            if (memSentinel(hits.len, contested_n, top_conf) and !envDisabled(environ, "NL_MEM_VERIFY")) {
                var vmsgs: std.ArrayListUnmanaged(u8) = .empty;
                defer vmsgs.deinit(gpa);
                const vbuilt = blk_v: {
                    vmsgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch break :blk_v false;
                    http.jstr(gpa, &vmsgs, "You audit MEMORY RECALLED for an assistant's next turn. Some facts may be wrong, stale, contradicted (CONTESTED entries show the disagreeing stored fact), or irrelevant to the request. Reply with ONLY compact JSON: {\"doubt\":[{\"i\":<fact number>,\"why\":\"<short reason>\"}]} — an empty list when the block is fine. Doubt sparingly; never doubt a fact merely for being brief.") catch break :blk_v false;
                    vmsgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch break :blk_v false;
                    var uc: std.ArrayListUnmanaged(u8) = .empty;
                    defer uc.deinit(gpa);
                    uc.appendSlice(gpa, mem_content.items) catch break :blk_v false;
                    uc.appendSlice(gpa, "\nREQUEST THIS MEMORY MUST SERVE: ") catch break :blk_v false;
                    uc.appendSlice(gpa, clipBytes(goal_text, 600)) catch break :blk_v false;
                    uc.appendSlice(gpa, "\n\nWhich fact numbers, if any, deserve caution?") catch break :blk_v false;
                    http.jstr(gpa, &vmsgs, uc.items) catch break :blk_v false;
                    vmsgs.append(gpa, '}') catch break :blk_v false;
                    break :blk_v true;
                };
                if (vbuilt) {
                    const vp = trio.pick(.thinking);
                    const vm_cm = meterBegin(app.io);
                    var vstep = llm.complete(gpa, app.io, run_root, "memverify", vp.base_url, vp.key, vp.model, vmsgs.items, "", 384, 0.1);
                    defer vstep.deinit(gpa);
                    meterEnd(app, vm_cm, "memverify", .thinking, vp.model, vstep.ok);
                    if (vstep.ok) {
                        if (verifierNote(gpa, vstep.content, hits.len)) |note| {
                            defer gpa.free(note);
                            ws.bid(.verifier, "memverify", note, 0.92, 700, 0);
                        }
                    }
                }
            }
        }
        if (!scored_ok) {
            const recalled = ctx.mem.recall(mem_scope, recall_query);
            defer gpa.free(recalled);
            if (recalled.len > 0) {
                scrubUtf8(recalled); // observed facts are already scrubbed, but a fetched-byte tail could slip in
                var mem_content: std.ArrayListUnmanaged(u8) = .empty;
                defer mem_content.deinit(gpa);
                mem_content.appendSlice(gpa, if (sched_task != null)
                    "TASK MEMORY — lessons, outcomes, and findings from PREVIOUS RUNS of this scheduled task. USE them: prefer sources/approaches that worked, skip recorded pitfalls, keep stated assumptions, and improve on the last run instead of starting from zero:\n"
                else
                    "RELEVANT MEMORY (recalled from this conversation's memory — earlier turns, tool findings). Treat as grounded context:\n") catch return;
                // Clipped like every other memory injection (the durable-memory and lesson blocks below clip at
                // 700/500, the image OCR at 2800). Recall is unbounded by construction — it grows with the
                // conversation's own fact count — and this fragment rides in front of the recency window on EVERY
                // inference of the turn.
                const shown = clipBytes(recalled, 1500);
                mem_content.appendSlice(gpa, shown) catch return;
                var nfacts: u32 = 0;
                var fit = std.mem.splitScalar(u8, shown, '\n');
                while (fit.next()) |fl| {
                    if (std.mem.trim(u8, fl, " \r\t").len > 0) nfacts += 1;
                }
                ws.bid(.recall, mem_scope, mem_content.items, 0.60, 0, nfacts);
            }
        }
    }
    // BELT CORRECTION (compact tier): the previous reply claimed a belt tool is missing. The manifest sits
    // in the system prompt, thousands of tokens behind the recency window where the denial lives — and a
    // model defending an earlier "can't" re-derives the denial from its own last turns, not from the prompt
    // (observed c6a75cac3: five escalating denials, one of them quoting the manifest's own names back as
    // proof of absence). This correction rides the per-turn channel so it lands ADJACENT to the momentum it
    // has to break, and it re-offers the honest exit rather than just contradicting.
    if (compact_belt) {
        if (lastAssistantReply(app, conv_dir)) |prev| {
            defer gpa.free(prev);
            if (beltDenial(gpa, prev, turn_tools)) |denied| {
                var corr: std.ArrayListUnmanaged(u8) = .empty;
                defer corr.deinit(gpa);
                corr.appendSlice(gpa, "BELT CORRECTION — your previous reply said you do not have `") catch return;
                corr.appendSlice(gpa, denied) catch return;
                corr.appendSlice(gpa, "`. That is factually wrong: it is on this turn's belt (see TOOLS ON THIS BELT above) and calling it by that exact name works. Do not repeat the claim or try to verify it with list_dir — that lists files, not tools. CALL IT NOW as your next action and read what comes back; if a missing LOGIN is what you actually meant, that is also wrong — the browser is the user's own, its sessions are already signed in, and where one is not you can ask for the credential and sign in yourself. If instead you are declining by judgment, say plainly \"I won't ...\" and give the real reason. Do not describe a choice as an inability.") catch return;
                ws.bid(.correction, "belt-manifest", corr.items, 0.95, 0, 0);
            }
        }
    }
    // SUB-CHAT FAMILY CONTEXT: a branch re-anchors on the primary (live goal + latest progress); a primary
    // lists its live branches. Varies per turn → rides the recall-fragment channel, never the stable prefix.
    injectFamilyContext(app, conv, base, &ws);
    // PLUGIN PROMPT HOOKS: any loaded plugin's veil.on_prompt(fn) may add system-prompt text for this turn
    // (a house style, a compliance reminder, project context). Rides the per-turn recall channel — NEVER the
    // stable prefix — so the provider prompt-prefix cache is untouched (same discipline as recall above).
    // Inert when no plugin registers a prompt hook.
    if (plugins.current(&app.plugs)) |preg| {
        if (preg.promptText(gpa, uid, is_admin, conv)) |ptext| {
            defer gpa.free(ptext);
            var wrapped: std.ArrayListUnmanaged(u8) = .empty;
            defer wrapped.deinit(gpa);
            wrapped.appendSlice(gpa, "PLUGIN CONTEXT (added by an installed extension):\n") catch {};
            wrapped.appendSlice(gpa, clipBytes(ptext, 3500)) catch {};
            ws.bid(.plugin, "plugin:on_prompt", wrapped.items, 0.50, 0, 0);
        }
    }
    // DURABLE USER MEMORY: inject the user's cross-conversation facts (keys/logins/preferences) from the shared
    // memories.jsonl — the desk's "YOUR MEMORY" block, which a server-served conv never had.
    injectDurableMemory(app, uid, &ws, compact_belt);
    // TOOL-PERFORMANCE DIGEST: a compact, learned note on which tools are slow or flaky on THIS machine, so the
    // agent plans around them (waits out a cold browser, avoids a 404-ing endpoint) instead of relearning each
    // run. Fixed within this turn (computed once), so it lives in the stable prefix like durable memory. Absent
    // until enough samples accrue — a fresh machine sees nothing.
    if (toolperf.digest(gpa, app.io, app.data, turn_tools)) |dg| {
        defer gpa.free(dg);
        if (dg.len > 0) ws.bid(.tool_digest, "toolperf", dg, 0.55, 0, 0);
    }
    // TOOL BELT: the positive half of the same learning — the tools ranked RELIABLE-FIRST by lived
    // outcome success on this machine, blended with the neuron-db trust floor's earned cross-session
    // preference when the floor holds a verdict for this scope. Turn-stable (the aggregate only writes at
    // turn exit), so it rides the stable prefix beside the digest and is seen at every inference — the
    // option space arrives pre-weighted by history, not alphabetical. Absent until >=2 tools have samples.
    {
        const tl = trustBeltLine(app, mem_scope);
        defer if (tl.len > 0) gpa.free(tl);
        if (toolperf.belt(gpa, app.io, app.data, tl, turn_tools)) |bl| {
            defer gpa.free(bl);
            if (bl.len > 0) ws.bid(.tool_belt, "toolperf+trust", bl, 0.55, 0, 0);
        }
    }
    // ATTACHED IMAGE (vision-as-text): the desk can attach ONE raster image this turn (image_b64 = STANDARD
    // base64 of the raw PNG). It has no DOM, so its text comes from OS-native OCR (Windows.Media.Ocr / macOS
    // Vision — free/offline/private), or, where the OS has none, a vision-model fallback (pixelrag.ingestImage →
    // llm.visionExtract, using this turn's coding provider). The extracted text rides as its OWN per-turn system
    // fragment — NEVER folded into user_text, which is the recall query + deferred neuron-db observe + pinned
    // goal; polluting it would corrupt memory. The full image is indexed as a pixel-RAG doc, so pixel_search can
    // retrieve it. Sits after the stable prefix (durable memory + tool digest) and before the history window,
    // where the per-turn recall fragment also lives, so the cache prefix behind it stays intact.
    if (image_b64.len > 0) attach: {
        const Dec = std.base64.standard.Decoder;
        const n = Dec.calcSizeForSlice(image_b64) catch break :attach;
        const png = gpa.alloc(u8, n) catch break :attach;
        defer gpa.free(png);
        Dec.decode(png, image_b64) catch break :attach;
        // Ingest into `workdir` (not run_root): pixel_search is DELEGATED to the client, which roots at the
        // conversation workdir — writing the manifest there is what lets a later pixel_search actually find it.
        const text = pixelrag.ingestImage(gpa, app.io, environ, workdir, ctx.mem, "", png, coding.base_url, coding.key, coding.model);
        defer gpa.free(text);
        const trimmed = std.mem.trim(u8, text, " \r\n\t");
        var note: std.ArrayListUnmanaged(u8) = .empty;
        defer note.deinit(gpa);
        if (trimmed.len > 0) {
            note.appendSlice(gpa, "ATTACHED IMAGE — text extracted from the image the user attached this turn (vision-as-text; treat as grounded context). The full image is also indexed for pixel_search if you need more than the excerpt below. Extracted:\n") catch break :attach;
            note.appendSlice(gpa, clipBytes(trimmed, 2800)) catch break :attach; // UTF-8-safe clip of the OCR text
        } else {
            note.appendSlice(gpa, "ATTACHED IMAGE — the user attached an image this turn, but no text could be extracted from it (OCR unavailable, or the image carries no readable text).") catch break :attach;
        }
        ws.bid(.image, "pixelrag", note.items, 0.85, 3200, 0);
    }

    // GROUND-TRUTH LEDGER (fine-needle weave, step 0): if previous turns already wrote files, say so as
    // engine fact — loaded once per turn. Bid into the suffix channel (renders after the recency window).
    // Without this, a "continue" turn re-discovers its own build with list_dir/read_file probes.
    if (file_ledger.files.items.len > 0) {
        var gt: std.ArrayListUnmanaged(u8) = .empty;
        defer gt.deinit(gpa);
        ledgerBlock(gpa, &file_ledger, &gt);
        if (gt.items.len > 0)
            ws.bid(.ledger, "file-ledger", std.mem.trim(u8, gt.items, " \n"), 0.90, 0, @intCast(@min(file_ledger.files.items.len, std.math.maxInt(u32))));
    }

    // PACK THE WORKSPACE: one deterministic admission pass over every bid above — fixed render order,
    // per-channel byte budgets, whole-block drops (lowest score first), a provenance receipt on each
    // block — then splice the channels around the bounded history and append the decision line to
    // {conv}/workspace.jsonl (best-effort: the turn never fails on its own audit trail).
    var ws_packed = ws.pack(conv, nowSecs(app.io));
    defer ws_packed.deinit(gpa);
    conv_buf.appendSlice(gpa, ws_packed.prefix) catch {};

    // BOUNDED HISTORY (chat_context): instead of replaying the entire transcript (which overflowed the model
    // window on long chats and hit an 8 MiB read cliff), project it into a fixed budget — a rolling summary of
    // scrolled-out turns + the pinned goal + the varying workspace channel + a recency window of the newest turns.
    // The window is sized for the model that CONSUMES this prompt (coding), against the REAL tool array — not a
    // tier estimate, which would overflow on exactly the turns that granted a recipe. refreshSummary below is
    // handed the same number so both agree on where the window starts.
    const hist_win = historyWindowBytes(trio.coding.base_url, trio.coding.model, turn_tools.len);
    warnIfPromptCannotFit(trio.coding.base_url, trio.coding.model, turn_tools.len, hist_win);
    assembleHistory(app, conv_dir, user_text, &conv_buf, ws_packed.varying, hist_win);
    conv_buf.appendSlice(gpa, ws_packed.suffix) catch {};

    if (ws_packed.log.len > 0) {
        if (std.fmt.allocPrint(gpa, "{s}\n", .{ws_packed.log})) |wl| {
            defer gpa.free(wl);
            if (std.fmt.allocPrint(gpa, "{s}/workspace.jsonl", .{conv_dir})) |wp| {
                defer gpa.free(wp);
                http.appendFile(app.io, gpa, wp, wl) catch {};
            } else |_| {}
        } else |_| {}
    }

    // HIPPOCAMPUS (observe): the user's own turn is durable knowledge — store it so a later turn can recall it.
    // We NEVER observe the veil's assistant replies (only user turns + tool results); self-observing generated
    // text then recalling it as "grounded context" is a parrot/confabulation loop.
    // DEFERRED to turn exit (a `defer` covers every completion path): the observe is a subprocess spawn that sat
    // between prefix assembly and the first inference — pure write-side durability nothing in THIS turn reads
    // (recall already ran above), so it must not tax the first token.
    // A SCHEDULED run's message ends in engine-authored boilerplate (RUN CONTEXT / WORKDIR / SELF-HEAL) — that
    // is chrome, not knowledge; stored, it resurfaced in later runs' recall as junk facts ("--- SCHEDULED RUN
    // CONTEXT ---", the workdir paragraph — observed live in sched:* scopes). Store the task's own words only.
    defer {
        const cut = std.mem.indexOf(u8, user_text, "--- SCHEDULED RUN CONTEXT") orelse user_text.len;
        _ = ctx.mem.observe(mem_scope, user_text[0..cut]);
    }

    // TOOL-FINDING OBSERVES, BATCHED: each observe is a subprocess spawn, and doing one between every tool call
    // serialized big tool batches (a 40-tool storm paid ~40 spawns inline). The tool loop appends preformatted
    // notes here; the defer flushes them at turn exit — off every hot path. Nothing within this turn could have
    // read them anyway: recall runs once, at turn start.
    var tool_obs: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        // ONE subprocess for the whole batch (observeBatch imports a temp pack) instead of a neuron.exe spawn
        // per note — a tool-heavy turn used to pay dozens of serialized ~300ms launches on its tail.
        memBank(app, &ctx, mem_scope, tool_obs.items);
        for (tool_obs.items) |note| gpa.free(note);
        tool_obs.deinit(gpa);
    }

    // TOOL-PERFORMANCE LEARNING: the drive loop times each executed tool into this accumulator; at turn exit it
    // merges into {data}/.tool_perf.json (per-machine latency + fail-rate aggregate). A digest of the notable
    // tools is injected below so the agent adapts to how tools actually behave here. Machine-wide (not per-conv)
    // and off every hot path — the merge is one file read+write at turn exit.
    var tool_perf: toolperf.Acc = .{};
    defer toolperf.merge(app.io, gpa, app.data, &tool_perf);
    // TRUST FLOOR (feature-gated, fail-safe): at turn exit, reward/penalize each tool's `tool:<name>` class
    // in the neuron-db trust ledger by its OUTCOME rate this turn — so tool preference is EARNED across
    // sessions, not just prompted. Engine-driven only (the model never writes it). No-op when the neuron
    // binary lacks the trust verb (classTrust/trustReward both fail-safe), so this is safe before deploy.
    defer rewardToolTrust(&ctx, mem_scope, &tool_perf);

    // ---- PLAN-BOARD: the veil's first move on a non-trivial task is to decompose it into routed subtasks. Try a
    // fresh decomposition of THIS message; if it yields a plan, that's the new board (persist + show it). If not
    // (a question / "continue" / trivial step), resume an existing unfinished plan if one is on disk; else run a
    // normal free-form turn. When a plan is active the drive loop below walks it deterministically. ----
    // THE TURN BRIEF: the acceptance contract the planning pass wrote, carried for the whole turn (see the
    // injection below the plan block for why it lives here and not in the drive loop). Empty when this turn
    // doesn't plan, or when the planner answered in the old plan-only shape.
    var brief: cplan.Brief = .{};
    defer brief.deinit(gpa);
    var plan: []cplan.Task = blk: {
        // RESUME-PREFERRED: if an UNFINISHED plan is on disk, keep working IT — never silently clobber in-progress
        // work (with its completed-subtask state) by decomposing the new message into a fresh board. This is also
        // how "continue" resumes. A message sent mid-plan still rides in the model's context for the next subtask.
        const resumed = resumePlan(app, conv_dir);
        if (resumed.len > 0 and !cplan.allDone(resumed)) {
            emitPlanMessage(app, conv_dir, resumed);
            brief = resumeBrief(app, conv_dir); // resume under the contract this board was planned against
            break :blk resumed;
        }
        cplan.freeTasks(gpa, resumed);
        // No unfinished plan → decompose a fresh message into a new board, but ONLY when it reads like a genuine
        // multi-step BUILD/RESEARCH task (shouldPlan). A question, greeting, ack, or one-liner skips the whole
        // decomposition ROUND-TRIP — that sequential inference adds seconds to time-to-first-token even when the
        // model correctly returns an empty plan, and weak models over-decompose greetings into swarm plans. Real
        // tasks still plan + coordinate; chat stays fast. This persistPlan only overwrites a completed/absent plan,
        // so no in-progress work is lost.
        if (shouldPlan(user_text)) {
            // LOOK BEFORE PLANNING. Rung 1 is free — the workdir survey the engine already holds, which until
            // now reached only the chat inference. Rung 2 spends one inference plus up to three READ-ONLY
            // probes so the decomposition is written against the project that exists. Both degrade to nothing:
            // no ledger and no probes just means planning from the request, exactly as before.
            var ground: std.ArrayListUnmanaged(u8) = .empty;
            defer ground.deinit(gpa);
            ledgerBlock(gpa, &file_ledger, &ground);
            // Rung 2 is what FAST MODE gives up: the probe inference plus its tool calls, which is where
            // the latency lives. Rung 1 (the ledger block above) stays in BOTH modes — it is already in
            // hand and costs nothing, and a planner that cannot see the workdir is not "fast", just wrong.
            const evidence = if (fast or envDisabled(environ, "NL_CHAT_RECON"))
                null
            else
                reconFindings(app, llm_dir, think, &ctx, user_text, ground.items);
            defer if (evidence) |e| gpa.free(e);

            var ev: std.ArrayListUnmanaged(u8) = .empty;
            defer ev.deinit(gpa);
            if (ground.items.len > 0) ev.appendSlice(gpa, ground.items) catch {};
            if (evidence) |e| ev.appendSlice(gpa, e) catch {};

            const fresh = planTask(app, llm_dir, think.base_url, think.key, think.model, user_text, ev.items, &brief);
            if (fresh.len > 0) {
                // SMALL-tier turns keep every subtask INLINE. A hive route hands a small model the hardest
                // orchestration surface there is — observed live on a 12B: the plan said "(hive)", the drive
                // hint said "`cast` a swarm and steer it", and the model burned four rounds on cast /
                // swarm_status / open_subchat (flubbing the args) instead of just writing the weather script
                // it was asked for. One choke point, right where the plan is adopted: everything downstream
                // (status lines, subtask hints, cast recording) then already sees inline.
                if (compact_belt) for (fresh) |*t| {
                    if (std.mem.eql(u8, t.route, cplan.ROUTE_HIVE)) {
                        const nr = gpa.dupe(u8, cplan.ROUTE_INLINE) catch continue; // OOM: keep the old route
                        gpa.free(t.route);
                        t.route = nr;
                    }
                };
                persistPlan(app, conv_dir, fresh);
                persistBrief(app, conv_dir, brief);
                emitPlanMessage(app, conv_dir, fresh);
                break :blk fresh;
            }
            cplan.freeTasks(gpa, fresh);
        }
        break :blk &.{};
    };
    defer cplan.freeTasks(gpa, plan);
    // var (not const): an ARMED turn whose plan completes while its cast hive still runs demotes to FREE-FORM
    // (has_plan=false) after the await, so the gather step can run through the normal drive machinery.
    var has_plan = plan.len > 0;

    // ---- TURN BRIEF, injected HERE and nowhere else ----
    // This is the ONLY channel the thinking model has into the coding model's prompt in the turn where it thinks:
    // emitPlanMessage writes messages.jsonl and emits a UI frame, but never touches conv_buf, so the plan board
    // itself does not reach this turn's inference at all (only the NEXT turn's history replay sees it).
    //
    // The PLACEMENT is the whole point. compactWorking only rewrites conv_buf.items[assembled_len..] — everything
    // inside the assembled prefix is untouchable — so a brief appended BEFORE the freeze below survives every
    // compaction for the entire turn, including a 100k-step afk run that folds its working context dozens of
    // times. Move this into the drive loop and it becomes just another compactable note: the acceptance contract
    // would be summarized away exactly when a long turn most needs it. It is not tidiable back into the loop.
    //
    // CACHE SAFETY: it goes in the MESSAGE BODY, after SYSTEM_PROMPT and after the tools array — never into
    // SYSTEM_PROMPT or turn_tools, whose content must not vary per turn (see TURN_TOOLS_FULL above for why a
    // content-varying prefix re-bills the whole prefill).
    if (!brief.isEmpty()) {
        var bt: std.ArrayListUnmanaged(u8) = .empty;
        defer bt.deinit(gpa);
        renderBrief(gpa, brief, &bt);
        if (bt.items.len > 0) {
            // Scratch-build then append in ONE shot, like the ground-truth block above: an OOM mid-append must
            // not strand a partial JSON object in conv_buf.
            var frag: std.ArrayListUnmanaged(u8) = .empty;
            defer frag.deinit(gpa);
            _ = blk_br: {
                frag.appendSlice(gpa, ",{\"role\":\"system\",\"content\":") catch break :blk_br false;
                http.jstr(gpa, &frag, clipBytes(std.mem.trim(u8, bt.items, " \n"), BRIEF_MAX_BYTES)) catch break :blk_br false;
                frag.append(gpa, '}') catch break :blk_br false;
                conv_buf.appendSlice(gpa, frag.items) catch break :blk_br false;
                break :blk_br true;
            };
        }
    }

    // What this turn is FOR, in one line, for search-query formulation: the planner's objective when there is one
    // (it is already the distilled statement of intent), else the user's own words. Turn-stable.
    const search_intent: []const u8 = if (brief.objective.len > 0) brief.objective else user_text;

    // The assembled, bounded PREFIX (system + recall + summary + goal + recency window + the turn brief).
    // Everything appended past this by the drive loop (settled answers, synthetic drive steps, per-pass tool
    // notes) is compacted against it between drive steps so a multi-step turn stays bounded ACROSS steps, not
    // only within one pass. compactWorking (the sole reader) is the reason the brief is appended above this line.
    const assembled_len = conv_buf.items.len;

    // TERMINAL VERIFY, contract-aware: the generic paragraph plus THIS turn's done_when list, so the one
    // completeness check an armed loop gets before accepting DONE names the specific conditions that must hold
    // instead of asking for verification in the abstract. Built once (turn-stable); falls back to the bare
    // paragraph when the planner gave no contract, which is every unplanned turn.
    var verify_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer verify_buf.deinit(gpa);
    const verify_prompt: []const u8 = blk_vp: {
        // tier test inline: `afk` is declared with the loop-mode block below this point
        const vbase = if (loop >= LOOP_AFK) TERMINAL_VERIFY_PROMPT_AFK else TERMINAL_VERIFY_PROMPT;
        if (brief.done_when.len == 0) break :blk_vp vbase;
        verify_buf.appendSlice(gpa, vbase) catch break :blk_vp vbase;
        verify_buf.appendSlice(gpa, "\nThis turn is not done until EVERY one of these holds — check each one and name any that does not:\n") catch break :blk_vp TERMINAL_VERIFY_PROMPT;
        for (brief.done_when) |c| {
            if (verify_buf.items.len > BRIEF_MAX_BYTES) break;
            verify_buf.appendSlice(gpa, "- ") catch break;
            verify_buf.appendSlice(gpa, clipBytes(c, 300)) catch break;
            verify_buf.append(gpa, '\n') catch break;
        }
        break :blk_vp verify_buf.items;
    };

    // ---- AUTO-LOOP DRIVE: settle one answer, then either take the next PLAN subtask (deterministic) or infer the
    // next free-form step, and drive again until the plan/goal is done, a repeat, or the step cap. ----
    // `prev_drive` seeds the repeat guard with the user's own request so a driver that merely echoes it stops.
    var prev_drive: []u8 = gpa.dupe(u8, goal_text) catch &[_]u8{};
    defer if (prev_drive.len > 0) gpa.free(prev_drive);

    // POST-ANSWER CRITIQUE source: the turn's first substantial answer, HELD (not critiqued) here and reviewed
    // once at the completion site below. Captured rather than reviewed inline so the drive loop's pacing is
    // untouched, and CLEARED at the top of every drive step — so it is still non-empty at the completion site
    // only when the turn actually ended on that first answer. A turn that drove on has superseded it, and a
    // critique of superseded narration is noise about work the user already watched get redone.
    var critique_src: []u8 = &[_]u8{};
    defer if (critique_src.len > 0) gpa.free(critique_src);

    // WEB-SEARCH QUERY LEDGER (turn scope): the literal query TEXT of every search this turn. call_ledger below
    // dedups EXACT repeats by hash; this exists because the observed failure was the OTHER one — a model that
    // varies the wording slightly and searches the same thing over and over (107 web calls in one live run). The
    // reformulator is required to move off this list, which is only possible if the engine kept the words.
    var search_log: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (search_log.items) |q| gpa.free(q);
        search_log.deinit(gpa);
    }

    // AUTO-LOOP MODE (desk chat_loop / chat_loop_afk, now server-driven). A plan drives its own subtask budget; a
    // free-form turn drives DRIVE_MAX off, LOOP_MAX_STEPS armed-on, effectively-unbounded in afk (Stop is the exit).
    const armed = loop >= LOOP_ON;
    const afk = loop >= LOOP_AFK;
    // MID-TURN COURSE CHECK, on for the runs where drift is expensive: an armed loop (up to 30 steps, or
    // unbounded in afk) or a plan walking its board. A plain 6-step turn is short enough that the user is
    // still watching and is the correction, so it does not pay for a reviewer. NL_CHAT_COURSE=0 disables.
    //
    // THREE WAYS OFF, in descending scope: the operator's NL_CHAT_COURSE=0 (this build, every user), the
    // user's own fast mode (this turn, their choice), and the gate itself (this turn is too short to be
    // worth a reviewer).
    const course_on = (armed or has_plan) and !fast and !envDisabled(environ, "NL_CHAT_COURSE");
    // afk OUTRANKS the plan cap: an afk turn whose message decomposed into a plan must still run until Stop (it
    // walks the plan, then keeps driving free-form) — not halt at PLAN_STEPS_PER_TURN, which would violate afk.
    var max_steps: usize = if (afk) AFK_MAX_STEPS else if (has_plan) PLAN_STEPS_PER_TURN else if (armed) LOOP_MAX_STEPS else DRIVE_MAX;
    var idle_steps: usize = 0; // consecutive no-tool drive steps — the armed (non-afk) anti-spin bound (desk loop_idle)
    var verified_done = false; // TERMINAL BUILD-VERIFY fires at most once per turn (desk arc_final_verified)
    var swarm_timeout_nudged = false; // SWARM_TIMEOUT_MSG fires at most once per turn — after that a stuck hive can't hold the turn open forever
    // A hive past its deadline that never went terminal. awaitConvCast returns .timeout instantly in that
    // state and can never return .finished, so there is nothing left to await: afk stops asking, this turn.
    var cast_abandoned = false;
    // afk re-drive / stuck messages, re-grounded to THIS turn's goal (the user message that started the loop) so the
    // persistent loop can't drift onto an unrelated task. Fixed stack buffers (no alloc/free on the hot path).
    var stuck_buf: [800]u8 = undefined;
    const goal_clip = clipBytes(goal_text, 300);
    // AFK_DRIVE_TMPL is gone with its last reader: the "re-verify the latest work end-to-end, then pick the
    // most valuable next improvement" treadmill is what afkNextStep replaced, and leaving it live at one
    // stuck-hive site is how it kept reappearing.
    const afk_stuck_msg = std.fmt.bufPrint(&stuck_buf, AFK_STUCK_TMPL, .{goal_clip}) catch "You repeated the last step — try a DIFFERENT approach; recall_hive / web_search the actual blocker first.";
    if (armed) emitKV(app, conv_dir, "status", "text", if (afk) "auto-loop (afk): driving toward the goal" else "auto-loop: driving toward the goal");
    var steer_cursor = ctrl_cursor; // moving cursor over control.jsonl for stop + mid-turn steer messages
    // SCHEDULED-RUN TOOL BUDGET: an unattended auto-loop turn with a thorough model has an unbounded research
    // appetite — a live run burned 107 web calls (the repeat guard blocks exact duplicates, but the model just
    // VARIES the query) and was still "verifying" at the 10-minute mark, long after its deliverable was
    // written. Interactive chats have a human with a Stop button; a scheduled run needs a hard ceiling: past
    // the budget, every further tool call is answered with "finalize NOW", which drives the model to settle.
    // The successful reference run used 14 calls; 60 is generous headroom for real research.
    var tools_spent: usize = 0;
    var no_ack_streak: u32 = 0; // turn-scoped client-absence evidence — see delegateTool / CLIENT_GONE_AFTER
    var dud_fetches: u32 = 0; // turn-scoped guessed-URL spiral evidence — see looksLikeNotFound / DUD_FETCH_STREAK
    var poll_timeouts: u32 = 0; // turn-scoped stuck-in-a-wait evidence — see POLL_TIMEOUT_STREAK
    const tool_budget: usize = if (schedTaskOf(conv) != null) 60 else std.math.maxInt(usize);
    // TOOL-ECHO GUARD + network repeat ledger, at TURN scope. Both used to live inside the inner agentic
    // pass, which is re-entered on EVERY drive step — so the guards forgot all repeats each step, and a
    // stuck turn re-listed the same directory step after step while the context ballooned (observed live:
    // 340k tokens in / 12k out on one chat turn that never progressed past exploration).
    var echo_guard: [24]EchoRec = @splat(.{});
    var call_ledger: std.ArrayListUnmanaged(u64) = .empty;
    defer call_ledger.deinit(gpa);
    // FOREIGN-KNOWLEDGE LEDGER (turn-scoped): every cross-task hive note injected this turn, kept verbatim
    // for the conflict check — a read_file NOT FOUND on a path this text mentions means the model is chasing
    // ANOTHER task's files, and it gets told so (once per turn).
    var foreign_mem: std.ArrayListUnmanaged(u8) = .empty;
    defer foreign_mem.deinit(gpa);
    var foreign_warned = false;
    var drive: usize = 0;
    outer: while (drive < max_steps) : (drive += 1) {
        // Reaching a SECOND drive step means the answer captured last step was not the turn's answer — drop it
        // (see the capture site). This clear is what makes "still held at the completion site" mean "the turn
        // ended on that answer" without threading a flag through every break path.
        if (critique_src.len > 0) {
            gpa.free(critique_src);
            critique_src = &[_]u8{};
        }
        // CONTROL (between drive steps): a `stop` op ends the turn; a `steer`/`say` op injects the user's text as a
        // mid-turn user message (posting to steer a running turn) so the next inference picks it up.
        switch (drainChatControl(app, conv_dir, &steer_cursor, &conv_buf)) {
            .stop => {
                finishTurn(app, conv_dir, usage_t0);
                return;
            },
            .none => {},
        }

        // CROSS-STEP COMPACTION: fold accumulated drive-step growth (prior settled answers + compacted notes) into
        // one note when it crosses the budget, so a long multi-step / afk turn can't overflow the model window
        // across steps. No-op on the first step (nothing past the assembled prefix yet).
        // Budget keyed on the CODING model + this turn's tool array: coding is what consumes conv_buf, and
        // the schemas ride in the same window. `think` here is only who WRITES the fold.
        compactWorking(app, llm_dir, think.base_url, think.key, think.model, &conv_buf, assembled_len, &ctx, &tool_obs,
            workingBudgetBytes(trio.coding.base_url, trio.coding.model, assembled_len + turn_tools.len));

        // PLAN STEP: when a plan is active, take the next pending subtask and inject it as this step's working turn
        // (so the agentic pass works THAT subtask, route-hinted). No plan → drive step 0 works the user's message
        // (already the last turn) and later steps work the free-form next-step inferred at the bottom of the loop.
        var task_idx: ?usize = null;
        if (has_plan) {
            if (cplan.nextPending(plan)) |ti| {
                task_idx = ti;
                cplan.setStatus(gpa, &plan[ti], cplan.STATUS_ACTIVE);
                persistPlan(app, conv_dir, plan);
                var sb: [220]u8 = undefined;
                emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "subtask {d}/{d} ({s}): {s}", .{ ti + 1, plan.len, plan[ti].route, clipBytes(plan[ti].text, 80) }) catch "subtask");
                if (subtaskInstruction(gpa, plan[ti], ti, plan.len)) |instr| {
                    defer gpa.free(instr);
                    // FINE-NEEDLE WEAVE: the subtask enters with the engine's ground truth + the facts this
                    // conversation already observed about it — not a cold restatement of the task text.
                    const weave = stepWeave(gpa, &ctx, &file_ledger, instr);
                    defer if (weave.step.len > 0) gpa.free(weave.step);
                    defer if (weave.hive.len > 0) gpa.free(weave.hive);
                    // Cross-task knowledge rides as the ENGINE's own system note, never inside the user-role
                    // step text — appended there, the model read it as "the user mentioned…" and adopted it.
                    if (weave.hive.len > 0) {
                        conv_buf.appendSlice(gpa, ",{\"role\":\"system\",\"content\":") catch break :outer;
                        http.jstr(gpa, &conv_buf, weave.hive) catch break :outer;
                        conv_buf.append(gpa, '}') catch break :outer;
                        foreign_mem.appendSlice(gpa, weave.hive) catch {};
                        foreign_mem.append(gpa, '\n') catch {};
                    }
                    var stept: std.ArrayListUnmanaged(u8) = .empty;
                    defer stept.deinit(gpa);
                    stept.appendSlice(gpa, instr) catch break :outer;
                    if (weave.step.len > 0) stept.appendSlice(gpa, weave.step) catch {};
                    conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
                    http.jstr(gpa, &conv_buf, stept.items) catch break :outer;
                    conv_buf.append(gpa, '}') catch break :outer;
                }
            } else if (!afk) {
                // Whole plan done (non-afk). ARMED: don't settle over a RUNNING cast hive — a hive-routed final
                // subtask is marked done the pass right after casting, which would otherwise end the turn while the
                // hive is still working. Await it, then demote to FREE-FORM and gather.
                var plan_break = true;
                if (armed) {
                    if (awaitConvCast(app, uid, conv, conv_dir, steer_cursor, tool_client)) |w| switch (w) {
                        .stopped => {
                            finishTurn(app, conv_dir, usage_t0);
                            return;
                        },
                        .finished, .timeout => {
                            const gm: []const u8 = if (w == .finished) SWARM_GATHER_MSG else SWARM_TIMEOUT_MSG;
                            if (w == .timeout) {
                                if (swarm_timeout_nudged) {
                                    // already nudged once — a stuck hive can't hold the turn open forever
                                } else {
                                    swarm_timeout_nudged = true;
                                    plan_break = false;
                                }
                            } else plan_break = false;
                            if (!plan_break) {
                                conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
                                http.jstr(gpa, &conv_buf, gm) catch break :outer;
                                conv_buf.append(gpa, '}') catch break :outer;
                                emitKV(app, conv_dir, "status", "text", if (w == .finished) "the hive finished — folding its results in" else "the hive ran past its budget — salvaging");
                                has_plan = false; // plan done — continue free-form so the gather runs through the drive machinery
                                max_steps = @max(max_steps, LOOP_MAX_STEPS);
                            }
                        },
                    };
                }
                if (plan_break) break :outer;
            }
            // afk + plan complete → task_idx stays null → the loop keeps driving FREE-FORM (afk ends only on Stop)
        }

        // Run one agentic tool pass to a SETTLED (no-tool-call) answer.
        const mut_before = file_ledger.mutations;
        const inner = runInnerAgentic(app, uid, conv, conv_dir, llm_dir, trio, &conv_buf, &ctx, &steer_cursor, &tool_obs, &tool_perf, tool_client, &no_ack_streak, &dud_fetches, &poll_timeouts, &tools_spent, tool_budget, &echo_guard, &call_ledger, &file_ledger, foreign_mem.items, &foreign_warned, search_intent, &search_log, turn_tools);
        // TRAJECTORY THREAD (fine weave): a pass that LANDED file changes mints one provenance-labeled
        // progress fact pairing the step's language with the engine-observed effect — the lexical thread
        // that lets a later step's recall hop from "what am I doing" to "what already happened here".
        // Mechanical composition (step text + ledger delta), batched via tool_obs like every other note.
        // NOT FILE-GATED ANY MORE. This block used to require `file_ledger.mutations > mut_before`, which meant
        // a step banked a trajectory fact only if it WROTE something. Research, debugging, reading and deciding
        // banked nothing — and that is precisely the class of work with no other durable home: the file ledger
        // records only files, and the confabulation rule (correctly) forbids observing the assistant's own reply.
        // So the work least recoverable from anywhere else was the work never written down, and a later turn
        // whose window had rolled past it saw the original goal with no evidence any of it had happened.
        //
        // The flush was nested INSIDE the same condition, so a research-heavy turn also never populated its
        // partition mid-turn and every step's weave recall abstained for the whole turn.
        //
        // What gets banked is still an ENGINE-OBSERVED EVENT, never a model claim: either the ledger delta this
        // step actually landed, or the tools it actually ran. Nothing here records what the model SAID it did.
        if (drive > 0 and tool_obs.items.len < 200) {
            const step_label: []const u8 = if (task_idx) |ti| plan[ti].text else if (prev_drive.len > 0) prev_drive else user_text;
            const landed = file_ledger.mutations - mut_before;
            if (landed > 0) {
                var tail_buf: [220]u8 = undefined;
                var tl: usize = 0;
                const from = file_ledger.files.items.len -| 4;
                for (file_ledger.files.items[from..]) |f| {
                    const add = std.fmt.bufPrint(tail_buf[tl..], "{s} ", .{f.path}) catch break;
                    tl += add.len;
                }
                // "this turn": file_ledger.mutations is turn-local (a fresh FileLedger each turn) while
                // .files is conversation-cumulative — phrasing this as a conversation total would be a lie.
                if (std.fmt.allocPrint(gpa, "progress: step \"{s}\" landed {d} file change(s) this turn — {s}", .{ clipBytes(step_label, 140), landed, tail_buf[0..tl] })) |note| {
                    atomizeNoteInPlace(note);
                    tool_obs.append(gpa, note) catch gpa.free(note);
                } else |_| {}
            } else if (inner.tools_ran) {
                // NON-FILE WORK: the step ran tools and settled without writing. The findings themselves are
                // already queued as their own notes; this one records that the step HAPPENED and what it was
                // about, so a later recall can hop from "what am I doing" to "this was already looked into"
                // instead of finding nothing and starting the investigation over.
                if (std.fmt.allocPrint(gpa, "progress: step \"{s}\" ran tools and settled without writing files this turn", .{clipBytes(step_label, 140)})) |note| {
                    atomizeNoteInPlace(note);
                    tool_obs.append(gpa, note) catch gpa.free(note);
                } else |_| {}
            }
            // MID-TURN FLUSH (thread the loom NOW): populate the conversation's neuron-db partition after a
            // step (one batched spawn) so the NEXT step's weave recall can surface what this step just did and
            // learned. Without it the partition stayed empty until turn exit and every step's conv recall
            // abstained — the within-turn threads never existed.
            if (tool_obs.items.len > 0) {
                memBank(app, &ctx, mem_scope, tool_obs.items);
                for (tool_obs.items) |n2| gpa.free(n2);
                tool_obs.clearRetainingCapacity();
            }
        }
        switch (inner.outcome) {
            .hard_error => {
                // the inference failed — the helper emitted {kind:error}; ALSO emit {kind:done} so the desk
                // poller disarms + clears busy instead of hanging forever.
                planStepInterrupted(app, conv_dir, plan, task_idx);
                salvageSteers(app, conv_dir, &steer_cursor); // an errored turn must not eat a pending steer
                // SCHEDULED runs learn from failure mechanically: record the failed run into the TASK's memory
                // (a plain engine fact, not model output — the confab rule stays intact) so the next run's
                // recall sees "the previous run failed" and can route around whatever broke. The outcome ALSO
                // lands on the task file (recordRunOutcome): the next run opens in SELF-HEAL posture
                // deterministically (not recall-dependent), and consecutive failures back the schedule off.
                if (sched_task) |tid| {
                    var fb: [200]u8 = undefined;
                    _ = ctx.mem.observe(mem_scope, std.fmt.bufPrint(&fb, "previous scheduled run ({s}) FAILED: the model call errored mid-turn — check the provider/key, or simplify the task prompt", .{conv[0..@min(conv.len, 64)]}) catch "a previous scheduled run failed with a model-call error");
                    _ = sched.recordRunOutcome(app, uid, tid, false, "FAILED: the model call errored mid-turn (provider/key/prompt trouble)");
                }
                finishTurn(app, conv_dir, usage_t0);
                return;
            },
            .stopped => {
                // stop landed mid tool-loop — commit the last narration (if any) so the user keeps it, then close.
                planStepInterrupted(app, conv_dir, plan, task_idx);
                // same control-token unwrap the settled path does — a stopped partial is still shown to the user
                const partial = cctx.stripSentinelTags(gpa, inner.content);
                defer if (partial) |p| gpa.free(p);
                const shown = partial orelse inner.content;
                if (shown.len > 0) {
                    appendMsg(app, conv_dir, "assistant", shown, "veil", nowSecs(app.io));
                    emitAssistant(app, conv_dir, shown);
                }
                // The ENGINE's account of the stop is stored as its own `role:"system"` / `kind:"engine"` row —
                // never merged into the assistant message above. Replay renders a system row as a system turn
                // (seedLines), so the next turn reads it as a machine event rather than as the model's own
                // confession, and only the NEWEST engine row survives replay, so a streak of cut turns cannot
                // pile up into a wall of failure notices. The user still SEES it: the emit below is unchanged.
                if (inner.engine_note.len > 0) {
                    appendMsg(app, conv_dir, "system", inner.engine_note, "engine", nowSecs(app.io));
                    emitEngineNote(app, conv_dir, inner.engine_note);
                }
                gpa.free(inner.content);
                gpa.free(inner.engine_note);
                finishTurn(app, conv_dir, usage_t0);
                return;
            },
            .settled => {},
        }

        // Commit the settled answer as the assistant turn (durable + narrated) and thread it into the LLM context.
        var answer = inner.content;

        // WATERMARK FOLD on the committed answer: the streamed deltas were folded at the edge, but the
        // settled text takes its own path into the transcript, the .hist archive, memory, and the narrator —
        // and a non-streamed reply (a hosted tool-call step) never passed the delta fold at all.
        if (wmScrubOwned(gpa, answer)) |clean| {
            gpa.free(answer);
            answer = clean;
        }

        // Strip a leaked CONTROL-TOKEN WRAPPER first: some models wrap the whole reply in their own sentinel
        // (`<DSML>…</DSML>`), which reaches the user as literal tag text. Bare wrappers only — tool-call markup
        // carries a verb and falls through to the recovery strip below.
        if (cctx.stripSentinelTags(gpa, answer)) |clean| {
            gpa.free(answer);
            answer = clean;
        }

        // Strip any leaked tool-call markup the recovery couldn't parse into a call, so the user never sees raw
        // `<｜｜DSML｜｜invoke …>` in the reply.
        if (cctx.looksLikeToolMarkup(answer)) {
            const clean = cctx.contentBeforeMarkup(answer);
            if (gpa.dupe(u8, clean)) |d| {
                gpa.free(answer);
                answer = d;
            } else |_| {}
        }

        // EMPTY settled answer (the model "died" — returned no text and no tools, or stripped to nothing).
        // ONE plain-text rescue before surrendering: re-ask with NO tools advertised — the model cannot emit
        // another malformed call, only prose. Small models earn this pass constantly: observed live, a 12B
        // fetched the right answer through the tool bridge and then died emitting a hallucinated final call —
        // the data was IN CONTEXT and the turn still ended "(no reply)". One bounded inference turns that
        // gathered-but-unspoken context into the user's answer; a model that returns nothing twice still gets
        // the honest note below.
        if (std.mem.trim(u8, answer, " \r\n\t").len == 0) rescue: {
            var rmsgs: std.ArrayListUnmanaged(u8) = .empty;
            defer rmsgs.deinit(gpa);
            rmsgs.appendSlice(gpa, conv_buf.items) catch break :rescue;
            rmsgs.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"(your previous response was empty or malformed and was discarded. Answer me NOW in plain text, using what the conversation above already established — especially any tool results. Do not call tools; do not emit JSON, code fences, or tool markup. Just the answer.)\"}") catch break :rescue;
            emitKV(app, conv_dir, "status", "text", "recovering: asking for a plain-text answer");
            const rp = trio.coding; // the rescue finishes the answer stream's own job — coding role (see trio_routing_test)
            const rcm = meterBegin(app.io);
            var rs = completeAux(app, llm_dir, "rescue", rp.base_url, rp.key, rp.model, rmsgs.items, 1024, 0.4);
            defer rs.deinit(gpa);
            meterEnd(app, rcm, "rescue", .coding, rp.model, rs.ok);
            if (!rs.ok) break :rescue;
            // the rescue output rides the same strips the settled path applies above
            var r: []u8 = gpa.dupe(u8, rs.content) catch break :rescue;
            if (cctx.stripSentinelTags(gpa, r)) |clean| {
                gpa.free(r);
                r = clean;
            }
            if (cctx.looksLikeToolMarkup(r)) {
                const clean = cctx.contentBeforeMarkup(r);
                if (gpa.dupe(u8, clean)) |d| {
                    gpa.free(r);
                    r = d;
                } else |_| {}
            }
            if (std.mem.trim(u8, r, " \r\n\t").len == 0) {
                gpa.free(r);
                break :rescue;
            }
            gpa.free(answer);
            answer = r; // rescued — fall through to the normal commit path
        }
        if (std.mem.trim(u8, answer, " \r\n\t").len == 0) {
            gpa.free(answer);
            planStepInterrupted(app, conv_dir, plan, task_idx);
            const note = "(no reply — the model returned an empty or malformed response this turn)";
            appendMsg(app, conv_dir, "assistant", note, "veil", nowSecs(app.io));
            emitAssistant(app, conv_dir, note);
            // SCHEDULED runs learn from an empty run too — a mechanical fact the next run's recall sees, plus
            // the task-file outcome that flips the next run into self-heal posture and arms the backoff.
            if (sched_task) |tid| {
                var fb: [180]u8 = undefined;
                _ = ctx.mem.observe(mem_scope, std.fmt.bufPrint(&fb, "run {s} produced NO ANSWER (empty/malformed model response) — retry with a simpler first step", .{conv[0..@min(conv.len, 64)]}) catch "a previous run produced no answer");
                _ = sched.recordRunOutcome(app, uid, tid, false, "FAILED: empty/malformed model response (no answer produced)");
            }
            salvageSteers(app, conv_dir, &steer_cursor); // an empty-reply end must not eat a pending steer
            finishTurn(app, conv_dir, usage_t0);
            return;
        }

        // DURABLE MEMORY: act on any REMEMBER:/FORGET: lines the reply carries (store/forget in the shared
        // memories.jsonl) and STRIP them so they never leak as literal text — the desk's processMemory, ported.
        // Runs BEFORE reflect so the self-critique sees the clean prose. A reply that was ONLY directives strips to
        // empty → show a short confirmation instead of committing a blank message.
        {
            var mem_saved: usize = 0;
            if (processMemoryDirectives(app, uid, answer, &mem_saved)) |stripped| {
                if (std.mem.trim(u8, stripped, " \r\n\t").len == 0 and mem_saved > 0) {
                    if (gpa.dupe(u8, "(noted — saved to your memory)")) |note| {
                        gpa.free(stripped);
                        gpa.free(answer);
                        answer = note;
                    } else |_| {
                        gpa.free(answer);
                        answer = stripped;
                    }
                } else {
                    gpa.free(answer);
                    answer = stripped;
                }
            }
        }

        // POST-ANSWER CRITIQUE, capture half: hold the FIRST substantial answer of an unplanned turn for the
        // append-only review at the completion site. Nothing runs here — the critique used to, and re-generating
        // the answer at this point is precisely what swapped text the user had already read. The old
        // `!inner.streamed` gate that suppressed that (and, since streaming works, suppressed the critique
        // entirely) is gone: an APPEND has nothing to swap, so streaming is no longer a reason to stay silent.
        //
        // `inner.tools_ran` is part of the gate and it is the difference between this being free and being a
        // tax on every message. Without it the capture fires ahead of the no-tools fast path at the bottom of
        // this block — the plain-Q&A path — so an ordinary question with a >=REFLECT_MIN answer bought a whole
        // extra completion AND made the user wait for it before {done}. That is the same "the chat froze"
        // complaint that neutered the old reflect, just moved to the end of the turn. Critique the turns that
        // DID work: a tool-using turn is where a wrong claim is both likelier and more expensive, and its user
        // is already waiting on tool round-trips, so one more is not what they notice.
        if (!has_plan and drive == 0 and inner.tools_ran and answer.len >= REFLECT_MIN) {
            if (gpa.dupe(u8, answer)) |d| {
                if (critique_src.len > 0) gpa.free(critique_src);
                critique_src = d;
            } else |_| {}
        }
        defer gpa.free(answer);
        appendMsg(app, conv_dir, "assistant", answer, "veil", nowSecs(app.io));
        emitAssistant(app, conv_dir, answer);
        conv_buf.appendSlice(gpa, ",{\"role\":\"assistant\",\"content\":") catch break :outer;
        http.jstr(gpa, &conv_buf, answer) catch break :outer;
        conv_buf.append(gpa, '}') catch break :outer;

        // PLAN ADVANCE: mark this subtask done + move on. The next iteration picks the next pending subtask; the
        // free-form drive inference below is SKIPPED (the plan is the driver).
        if (task_idx) |ti| {
            cplan.setStatus(gpa, &plan[ti], cplan.STATUS_DONE);
            // and RECONCILE: this step may have completed later subtasks too (see planReconcile) — advance
            // them now so the board tracks the work, then persist the whole updated board once.
            if (inner.tools_ran and cplan.nextPending(plan) != null)
                planReconcile(app, llm_dir, conv_dir, trio, plan, &file_ledger, answer);
            persistPlan(app, conv_dir, plan);
            // Plan complete (non-afk): a plain (unarmed) turn ends here; an ARMED one loops back so the top-of-loop
            // plan-complete branch can await a still-running cast hive before settling over it.
            if (cplan.nextPending(plan) == null and !afk and !armed) break :outer;
            continue :outer; // next subtask, OR (afk/armed + plan done) loop back — the top transitions or awaits
        }

        // ANTI-SPIN / FAST-PATH: a step that ran NO tools did no agentic work this pass.
        if (!inner.tools_ran) {
            if (!armed) {
                // OFF: a first-step no-plan answer with no tools is a complete one-shot reply (plain Q&A) — end now,
                // skipping the wasted LOOP_QUESTION round-trip. (A drive>0 no-tools step falls through to the DONE
                // check below, which ends it.)
                if (drive == 0) break :outer;
            } else {
                // ARMED: tolerate ONE idle (announce-only) step so a build that pauses to narrate isn't cut off, but
                // end a non-afk loop after TWO consecutive idle steps (that's a conversation, not work). AFK never
                // ends on idle — persistence IS the feature — so its counter just resets.
                idle_steps += 1;
                if (idle_steps >= 2) {
                    if (!afk) {
                        // Idle over a RUNNING cast hive isn't idleness — it's the veil narrating "the hive is
                        // working". Await the hive (cheap, stop-checked), then inject the gather step and continue.
                        if (awaitConvCast(app, uid, conv, conv_dir, steer_cursor, tool_client)) |w| switch (w) {
                            .stopped => {
                                finishTurn(app, conv_dir, usage_t0);
                                return;
                            },
                            .finished, .timeout => {
                                if (w == .timeout and swarm_timeout_nudged) break :outer;
                                if (w == .timeout) swarm_timeout_nudged = true;
                                idle_steps = 0;
                                const gm: []const u8 = if (w == .finished) SWARM_GATHER_MSG else SWARM_TIMEOUT_MSG;
                                conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
                                http.jstr(gpa, &conv_buf, gm) catch break :outer;
                                conv_buf.append(gpa, '}') catch break :outer;
                                emitKV(app, conv_dir, "status", "text", if (w == .finished) "the hive finished — folding its results in" else "the hive ran past its budget — salvaging");
                                continue :outer;
                            },
                        } else break :outer;
                    }
                    idle_steps = 0;
                }
            }
        } else idle_steps = 0;

        // DRIVE INFERENCE: one no-tools completion that names the next step (or DONE) — on a BOUNDED context:
        // a goal-anchor system message + the freshest boundary-aligned slice of the conversation + the loop
        // question, built in its OWN buffer (conv_buf is untouched). It used to ride the ENTIRE conv_buf,
        // re-prefilling a 50-150K-token transcript once per drive step just to pick the next step — pure
        // overhead on slow hosted models, and (being a toolless request) it couldn't even reuse the provider's
        // prompt cache, which keys on the tools-bearing prefix. The chat inference above still sees the full
        // context; the picker needs the goal + the tail, and the verify/repeat/cast guards below still gate it.
        var lq: std.ArrayListUnmanaged(u8) = .empty;
        defer lq.deinit(gpa);
        lq.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch break :outer;
        var gb: [1700]u8 = undefined;
        const goal_line = std.fmt.bufPrint(&gb, "You drive an agentic work loop. THE GOAL of this conversation: {s}\n(Only the most recent part of the conversation follows.)", .{clipBytes(goal_text, 1400)}) catch "You drive an agentic work loop; only the most recent part of the conversation follows.";
        http.jstr(gpa, &lq, goal_line) catch break :outer;
        lq.appendSlice(gpa, "},") catch break :outer;
        lq.appendSlice(gpa, msgTail(conv_buf.items, LOOP_CTX_BYTES)) catch break :outer;
        lq.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
        http.jstr(gpa, &lq, if (afk) LOOP_QUESTION_AFK else LOOP_QUESTION) catch break :outer;
        lq.append(gpa, '}') catch break :outer;
        const loop_cm = meterBegin(app.io);
        var next = completeAux(app, llm_dir, "loop", prompt.base_url, prompt.key, prompt.model, lq.items, 512, 0.5);
        defer next.deinit(gpa);
        meterEnd(app, loop_cm, "loop", .prompting, prompt.model, next.ok);

        const trimmed = std.mem.trim(u8, next.content, " \r\n\t`*\"'");
        // A failed/empty drive inference always ends the turn (even afk — we can't determine a next step, and a
        // dead backend would spin). Otherwise decide by loop mode.
        if (!next.ok or trimmed.len == 0) break :outer;
        const is_done = loopIsDone(next.content);
        const is_repeat = nearlySame(trimmed, prev_drive) or cctx.looksLikeToolMarkup(trimmed);

        // Choose the next synthetic drive step, or break, honoring: TERMINAL VERIFY (an armed loop never accepts a
        // bare DONE right after building — one completeness check first), re-ground (afk anchors to the goal), and
        // stuck-recovery (afk re-grounds + researches on a repeat instead of churning).
        var next_step: []const u8 = trimmed;
        // Holds a WRITTEN stuck-recovery instruction for this iteration (see stuckStep); empty means the static
        // template. Freed at the end of the iteration, which is past every use of next_step below.
        var stuck_written: []u8 = &[_]u8{};
        defer if (stuck_written.len > 0) gpa.free(stuck_written);
        // Same lifetime discipline for the afk re-drive instruction (see afkNextStep).
        var afk_written: []u8 = &[_]u8{};
        defer if (afk_written.len > 0) gpa.free(afk_written);
        // Same lifetime discipline for a mid-turn course correction (see the check below the DONE/repeat block).
        var course_written: ?[]u8 = null;
        defer if (course_written) |c| gpa.free(c);
        if (is_done) {
            // files_written counts only SERVER-executed writes; delegated client-mode writes register in the
            // ledger (parsed from their result strings). Without the ledger arm, a desk-client build accepted
            // a bare DONE with no verification nudge at all — the counter sat at 0 the whole turn.
            if (armed and (ctx.files_written.* > 0 or file_ledger.mutations > 0) and !verified_done) {
                verified_done = true; // TERMINAL BUILD-VERIFY (once): confirm the build before letting DONE stand
                next_step = verify_prompt; // the brief's done_when list when this turn has one, else the bare paragraph
            } else if (armed) {
                // ARMED (on or afk): never accept DONE while this conversation's cast hive is still working —
                // await it (cheap, stop-checked), then gather its results instead of settling over them.
                if (if (cast_abandoned) null else awaitConvCast(app, uid, conv, conv_dir, steer_cursor, tool_client)) |w| switch (w) {
                    .stopped => {
                        finishTurn(app, conv_dir, usage_t0);
                        return;
                    },
                    .finished => next_step = SWARM_GATHER_MSG,
                    .timeout => {
                        if (swarm_timeout_nudged) {
                            if (!afk) break :outer; // nudged once already — a stuck hive can't hold the turn forever
                            // THE CAST-CONTINUE SPIN. awaitConvCast returns .timeout INSTANTLY once the hive is
                            // past its deadline (no sleep, no probe), and a hive that never goes terminal stays
                            // live forever — so in afk this was: DONE -> timeout in ~0ms -> canned drive text ->
                            // a full agentic pass -> DONE -> … at full inference cost, over a swarm nobody stops.
                            // Tier 1 escapes with the break above; afk cannot break, so it churned. Past the
                            // deadline the await can never return .finished either, so there was nothing to wait
                            // for: abandon the hive for the rest of this turn and drive on the written step.
                            cast_abandoned = true;
                            afk_written = afkNextStep(app, llm_dir, prompt, goal_text, conv_buf.items) orelse &[_]u8{};
                            next_step = if (afk_written.len > 0) afk_written else AFK_KEEP_GOING;
                        } else {
                            swarm_timeout_nudged = true;
                            next_step = SWARM_TIMEOUT_MSG;
                        }
                    },
                } else if (afk) {
                    // afk never accepts DONE. The PROMPTING role writes what to do instead, from the transcript
                    // tail that holds what was actually just built — the canned template is what a failed or
                    // implausible write degrades to, not the first choice (same contract as stuckStep above).
                    afk_written = afkNextStep(app, llm_dir, prompt, goal_text, conv_buf.items) orelse &[_]u8{};
                    next_step = if (afk_written.len > 0) afk_written else AFK_KEEP_GOING;
                } else {
                    break :outer; // on: goal achieved, no hive in flight
                }
            } else {
                break :outer; // off: goal achieved (verified, or nothing was built)
            }
        } else if (is_repeat) {
            // A STUCK-SITE RE-ANCHOR WAS TRIED HERE AND REMOVED — the note is worth more than the code was.
            // The idea was to re-read firstUserGoal on a repeat and steer by it instead of `goal_text`, on the
            // theory that goal_text might be the desk's kick sentence or a meta-question. It is measurably the
            // wrong place. `anchor` is consumed only in the afk branch below, and on an afk turn goal_text has
            // ALREADY been substituted to the pinned goal (continuationShaped covers the kick sentence), so the
            // re-anchor was a no-op in the case it was written for. In the remaining case — an afk turn the user
            // opened with a real instruction — goal_text is that instruction while firstUserGoal is the
            // conversation's FIRST message, which in a long multi-topic thread is stale: the re-anchor would have
            // dragged the loop back to an abandoned topic, and paid a messages.jsonl read per repeat to do it.
            // Goal poisoning is fixed where it starts (metaQuestionShaped, at the goal_text derivation), not by
            // stacking a second and staler anchor at the recovery site.
            if (afk) {
                // afk: don't churn the same step — re-ground + research the blocker. PROMPTING writes the actual
                // instruction from the transcript tail, which at this exact moment holds the failing command and
                // its error; AFK_STUCK_TMPL is what a failed/implausible write degrades to, not the first choice.
                stuck_written = stuckStep(app, llm_dir, prompt, goal_text, trimmed, conv_buf.items) orelse &[_]u8{};
                next_step = if (stuck_written.len > 0) stuck_written else afk_stuck_msg;
            } else if (armed) {
                // ARMED repeat while the hive runs = "the hive is working" narrated twice — that's a wait, not
                // a stall. Await + gather; a genuine no-progress repeat (no hive) still ends the loop.
                if (awaitConvCast(app, uid, conv, conv_dir, steer_cursor, tool_client)) |w| switch (w) {
                    .stopped => {
                        finishTurn(app, conv_dir, usage_t0);
                        return;
                    },
                    .finished => next_step = SWARM_GATHER_MSG,
                    .timeout => {
                        if (swarm_timeout_nudged) break :outer;
                        swarm_timeout_nudged = true;
                        next_step = SWARM_TIMEOUT_MSG;
                    },
                } else break :outer;
            } else {
                break :outer; // off: a no-progress repeat ends the loop
            }
        }
        // MID-TURN COURSE CHECK: the last moment a wrong direction is still cheap. The step is chosen but not
        // yet committed, so a correction here costs one inference; the same realisation ten steps later costs
        // everything built on top of it.
        //
        // DELIBERATELY NOT RUN ON THE ENGINE'S OWN STEERING. verify_prompt, afk_msg, the stuck instruction and
        // the swarm messages are the engine asserting policy, not the model choosing a direction — reviewing
        // them would let a model argue its way out of the terminal build-verify, which is the one check that
        // exists precisely because models talk themselves past it.
        if (course_on and !is_done and !is_repeat and next_step.ptr == trimmed.ptr) {
            // A course check REVIEWS the direction the coding model just chose, so it wants a reviewer that
            // is able to disagree. `pick(.thinking)` resolves to the coding model itself whenever thinking
            // is unset — the author grading their own next step, at full price, agreeing with itself.
            // When the trio has a genuinely different model, review runs there instead.
            //
            // The fallback is deliberately KEPT: one model configured everywhere must keep working exactly
            // as before. An independent reviewer is something a trio ADDS, never something its absence
            // removes — so this degrades to today's provider rather than skipping the check.
            const rev = trio.independentReviewer();
            const course_p = if (rev) |r| r.provider else think;
            const course_role: Role = if (rev) |r| r.role else .thinking;
            if (courseCheck(app, llm_dir, course_p, course_role, goal_text, &brief, next_step, conv_buf.items)) |corrected| {
                course_written = corrected;
                next_step = corrected;
                // The user SEES the redirect. A silent correction is the worst version of this feature: the
                // loop would change direction for reasons nobody watching could reconstruct.
                emitKV(app, conv_dir, "status", "text", "course-correcting");
            }
        }
        // FINE-NEEDLE WEAVE: every synthetic drive step re-enters with the engine's file ledger + per-step
        // recall from this conversation's neuron-db partition. This is what stops the observed churn class —
        // the model re-listing directories and re-writing files it wrote two steps ago, because compaction
        // folded the evidence and nothing re-surfaced it.
        {
            const weave = stepWeave(gpa, &ctx, &file_ledger, next_step);
            defer if (weave.step.len > 0) gpa.free(weave.step);
            defer if (weave.hive.len > 0) gpa.free(weave.hive);
            // Cross-task knowledge as the engine's own system note — never inside the user-role step text.
            if (weave.hive.len > 0) {
                conv_buf.appendSlice(gpa, ",{\"role\":\"system\",\"content\":") catch break :outer;
                http.jstr(gpa, &conv_buf, weave.hive) catch break :outer;
                conv_buf.append(gpa, '}') catch break :outer;
                foreign_mem.appendSlice(gpa, weave.hive) catch {};
                foreign_mem.append(gpa, '\n') catch {};
            }
            var stept: std.ArrayListUnmanaged(u8) = .empty;
            defer stept.deinit(gpa);
            stept.appendSlice(gpa, next_step) catch break :outer;
            if (weave.step.len > 0) stept.appendSlice(gpa, weave.step) catch {};
            conv_buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :outer;
            http.jstr(gpa, &conv_buf, stept.items) catch break :outer;
            conv_buf.append(gpa, '}') catch break :outer;
        }
        var sbuf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&sbuf, "continuing: {s}", .{clipBytes(next_step, 80)}) catch "continuing";
        emitKV(app, conv_dir, "status", "text", status);
        // The repeat guard tracks the MODEL's actual last step (`trimmed`), NOT any synthetic steering we injected
        // (TERMINAL_VERIFY / afk_msg / afk_stuck_msg) — else a model that keeps repeating its real action would slip
        // past nearlySame because prev_drive held our injected text instead of its output.
        const nd: []u8 = gpa.dupe(u8, trimmed) catch &[_]u8{};
        if (prev_drive.len > 0) gpa.free(prev_drive);
        prev_drive = nd;
    }

    // The drive loop ended (plan complete / DONE / repeat / step cap / an OOM append) — every settled answer is
    // already durable. A plan run gets a closing summary (all done, or paused at N/M — say "continue" to resume).
    // LAST-CALL STEER SALVAGE: a steer that landed during the final settle (after the last drain point) would
    // otherwise be dropped forever — the next turn re-snapshots the control cursor past it. Drain once more:
    // drainChatControl persists each pending steer as a durable user message, so the NEXT turn replays it.
    salvageSteers(app, conv_dir, &steer_cursor);
    // NOT IN AFK. This writes a role:"assistant" end-state claim into the durable transcript — "Plan complete
    // — worked all N subtasks." or "Worked D of N planned subtasks this turn. Say \"continue\" to do the rest."
    // In afk there is no turn the user sees and no user to say continue, and the desk's re-arm posts directly
    // underneath it, so the history the next drive step reads alternates a completion claim in the model's own
    // voice with a re-drive. (afk also never reaches the plan-complete branch that would demote has_plan, so
    // this fired at the end of every planned afk turn.)
    if (has_plan and !afk) emitPlanClosing(app, conv_dir, plan);
    // POST-ANSWER CRITIQUE, review half. It runs HERE, in the same deferred phase as the rolling-summary refresh
    // below and for the same reason: the answer was delivered and read long before this point, so the cost lands
    // where the user is not waiting on a blank chat. It can only ADD a message — the answer above is already
    // durable in messages.jsonl and already on screen, and nothing here can reach back and edit it.
    //
    // Why not a background thread, which would also spare the {done} frame: appendMsg is an UNLOCKED
    // read-modify-write of messages.jsonl (see the turn-thread note above), so a critique still writing after the
    // turn ended would race the NEXT turn's appends — and the desk disarms on {done}, so a message emitted after
    // it is a message nobody renders. Deferring inside the turn is the version that is actually safe.
    if (critique_src.len > 0) {
        const tl = toolperf.ledger(&tool_perf, gpa);
        defer if (tl) |s| gpa.free(s);
        if (critiqueAnswer(app, llm_dir, think.base_url, think.key, think.model, user_text, critique_src, tl orelse "")) |note| {
            defer gpa.free(note);
            appendMsg(app, conv_dir, "assistant", note, "veil", nowSecs(app.io));
            emitAssistant(app, conv_dir, note);
        }
    }
    // SCHEDULED-RUN LEARNING: at normal completion, fold this run's outcome + one distilled lesson into the
    // TASK's memory so the next run starts smarter — the recursive-improvement loop for recurring tasks.
    if (sched_task) |tid| schedLearn(app, &ctx, mem_scope, uid, tid, conv, conv_dir, llm_dir, think.base_url, think.key, think.model, &conv_buf);
    // NORMAL COMPLETION: emit the answer's usage, then DEFER the rolling-summary fold-in to here (after the reply is
    // fully delivered) so it never blocked this turn's first token — it advances the summary for the NEXT turn. The
    // desk stays in its rendering state until {done}, so it naturally waits for this rather than sending early. Only
    // this path refreshes; Stop/error/empty end promptly via finishTurn (and the summary catches up next turn).
    emitUsage(app, conv_dir, usage_t0);
    refreshSummary(app, conv_dir, llm_dir, think.base_url, think.key, think.model, hist_win);
    emitEvent(app, conv_dir, "{\"kind\":\"done\"}");
}

/// The scheduled task's LEARNING step, run once at a run's NORMAL completion. Two writes into the task's own
/// memory scope ("sched:{taskid}", shared by every run of the task):
///   1. a MECHANICAL outcome note (files written, observations stored) — never depends on the model;
///   2. ONE model-distilled lesson ("what should the next run do differently/faster?") — the deliberate
///      counterpart of the desk's playbook pattern. This is NOT the forbidden observe-own-reply confab loop:
///      the reply itself is never stored, only a provenance-labeled lesson ("lesson from run X: ..."), and the
///      recall injection presents it as task history, not as ground truth about the world.
/// Difficult recurring tasks improve because every run leaves behind what happened, what to change, and every
/// tool finding already observed during the run. Bounded: one small extra inference, best-effort.
fn schedLearn(app: *App, ctx: *tools.ToolCtx, mem_scope: []const u8, uid: u64, tid: []const u8, conv: []const u8, conv_dir: []const u8, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, conv_buf: *std.ArrayListUnmanaged(u8)) void {
    const gpa = app.gpa;
    var ob: [220]u8 = undefined;
    const note = std.fmt.bufPrint(&ob, "run {s} COMPLETED: {d} file(s) written, {d} observation(s) stored", .{ conv[0..@min(conv.len, 64)], ctx.files_written.*, ctx.observed.* }) catch "scheduled run completed";
    _ = ctx.mem.observe(mem_scope, note);
    // Task-file outcome ledger: a completed run resets fail_streak and stamps last_status — the next run's RUN
    // CONTEXT opens on "the previous run worked" instead of a stale failure, and any backoff unwinds.
    var sb2: [180]u8 = undefined;
    _ = sched.recordRunOutcome(app, uid, tid, true, std.fmt.bufPrint(&sb2, "ok: {d} file(s) written, {d} observation(s) stored", .{ ctx.files_written.*, ctx.observed.* }) catch "ok");

    // BOUNDED, like every other auxiliary completion in this file. This one used to append the question to
    // conv_buf and send the WHOLE buffer — the only aux call here with no msgTail bound — so a run paid a
    // full uncached prefill of its entire assembled context (system prompt + memory blocks + the working
    // span, which compaction holds near 32 KB and lets reach 48 KB) to produce ONE sentence capped at 256
    // tokens. Uncached twice over: the request is toolless, so it cannot reuse the provider's tools-bearing
    // prefix, and it runs on the THINKING provider while the turn's chat calls run on CODING — there is not
    // even a same-endpoint prefix to hit. The identical mistake was already fixed on the drive picker (see
    // the note at the "loop" call) and the shape to copy is summarizeTurn's. A local buffer also retires the
    // save/shrink pair: the question cannot leak into durable context if it never touches conv_buf.
    // The tradeoff, the same one summarizeTurn accepts: the lesson sees the run's tail, not its whole arc.
    // (Ledger 0082.)
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, msgTail(conv_buf.items, SUMMARY_CTX_BYTES)) catch return;
    msgs.appendSlice(gpa, ",{\"role\":\"user\",\"content\":\"This scheduled task will run again. In ONE or TWO sentences, state the single most useful lesson from THIS run for the next run — a faster path, a source that worked, a pitfall to skip, or an assumption to keep. Reply with ONLY the lesson.\"}") catch return;
    const lesson_cm = meterBegin(app.io);
    var next = completeAux(app, run_root, "lesson", base_url, key, model, msgs.items, 256, 0.3);
    defer next.deinit(gpa);
    meterEnd(app, lesson_cm, "lesson", .thinking, model, next.ok);
    if (!next.ok) return;
    scrubUtf8(next.content);
    const lesson = std.mem.trim(u8, next.content, " \r\n\t\"");
    if (lesson.len < 8 or lesson.len > 600 or cctx.looksLikeToolMarkup(lesson)) return; // a degenerate/markup "lesson" teaches nothing
    var lb: [720]u8 = undefined;
    const lnote = std.fmt.bufPrint(&lb, "lesson from run {s}: {s}", .{ conv[0..@min(conv.len, 40)], lesson }) catch return;
    _ = ctx.mem.observe(mem_scope, lnote);
    var sb: [180]u8 = undefined;
    emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "task memory updated: {s}", .{clipBytes(lesson, 120)}) catch "task memory updated");
}

// ---- PER-CONVERSATION TURN LOCK ----------------------------------------------------------------------------
// A turn is a detached background thread that does an UNLOCKED read-modify-write of messages.jsonl + context.json.
// Two turns for the SAME conversation running concurrently (a raced double-POST, a second client, an auto-loop
// follow-up firing during a long turn) would lost-update the durable log or torn-read the summary cursor. This
// serializes them: at most one in-flight turn per conv. A distinct conv is unaffected (up to MAX_ACTIVE_TURNS at
// once — a 17th distinct conv while 16 run is rejected, which is safe, never silent corruption). Bounded fixed
// storage (conv is safeSeg'd and <= 64 bytes) so no allocation is needed on the hot path.
/// The hard table size. 16 was the ceiling for a single-user desktop and the wrong shape for a server
/// a hundred people share: the 17th concurrent conversation was refused outright, whoever it belonged
/// to. 256 slots is 20KB of static storage and costs a linear scan per claim — nothing next to a turn.
const MAX_ACTIVE_TURNS = 256;

/// How many turns this server will actually run at once, and how many ONE account may hold.
///
/// Capacity alone does not make a shared server fair. With a single provider key, a user with ten
/// conversations open would take ten of the slots first-come and everyone else would meet a 409 — so the
/// per-user share is the part that makes "a hundred people" work rather than "the fastest ten people".
/// Default: an eighth of capacity, at least one, so at least eight distinct accounts can always be
/// running something.
///
/// Both are set from the environment at startup (NL_MAX_TURNS / NL_MAX_TURNS_PER_USER) rather than
/// compiled in, because the right number depends on the provider's rate limit for the key everyone is
/// sharing — which is an operator's fact, not ours.
var turn_capacity: usize = 64;
var turn_per_user: usize = 8;

pub fn configureTurnLimits(capacity: usize, per_user: usize) void {
    turn_capacity = std.math.clamp(capacity, 1, MAX_ACTIVE_TURNS);
    const derived = @max(@as(usize, 1), turn_capacity / 8);
    turn_per_user = std.math.clamp(if (per_user == 0) derived else per_user, 1, turn_capacity);
}

pub fn turnLimits() struct { capacity: usize, per_user: usize } {
    return .{ .capacity = turn_capacity, .per_user = turn_per_user };
}

/// Why a claim failed — so the caller can say something true instead of one 409 for three situations.
pub const TurnDenied = enum {
    ok,
    conv_busy, // this conversation already has a turn running
    user_at_cap, // this account is already using its share
    server_full, // every slot is taken, by other people
};

var turn_mtx: std.Io.Mutex = .init;
var active_convs: [MAX_ACTIVE_TURNS][64]u8 = undefined;
var active_lens: [MAX_ACTIVE_TURNS]usize = [_]usize{0} ** MAX_ACTIVE_TURNS;
var active_uids: [MAX_ACTIVE_TURNS]u64 = [_]u64{0} ** MAX_ACTIVE_TURNS;
/// The control.jsonl byte offset each live turn started reading from, or null while a turn holds a slot but has
/// not snapshotted its cursor yet. Published under the SAME mutex as the slot itself so a reader can compare
/// "where the turn began reading" against "where my op landed" without a torn view. See turnWillConsume.
var active_ctrl: [MAX_ACTIVE_TURNS]?usize = [_]?usize{null} ** MAX_ACTIVE_TURNS;

/// Claim the single in-flight slot for `conv`, on behalf of `uid`. One pass over the table answers all
/// three questions (is this conv running, how many does this user hold, is there a free slot), so the
/// lock is held for one scan rather than three.
pub fn beginTurn(io: std.Io, conv: []const u8, uid: u64) TurnDenied {
    if (conv.len == 0 or conv.len > 64) return .conv_busy; // unrepresentable — safeSeg should have caught it
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    var free_slot: ?usize = null;
    var mine: usize = 0;
    for (0..turn_capacity) |i| {
        if (active_lens[i] == 0) {
            if (free_slot == null) free_slot = i;
            continue;
        }
        if (std.mem.eql(u8, active_convs[i][0..active_lens[i]], conv)) return .conv_busy;
        if (active_uids[i] == uid) mine += 1;
    }
    if (mine >= turn_per_user) return .user_at_cap;
    const slot = free_slot orelse return .server_full;
    @memcpy(active_convs[slot][0..conv.len], conv);
    active_lens[slot] = conv.len;
    active_uids[slot] = uid;
    active_ctrl[slot] = null; // claimed, but this turn has not decided where it starts reading control.jsonl yet
    return .ok;
}

/// Publish the control.jsonl offset this turn will start reading from. Called by runTurn the instant it takes
/// that snapshot, so /control can answer truthfully instead of guessing (see turnWillConsume). A turn with no
/// slot (or a conv too long to be one) simply publishes nothing — the reader then reports "will not consume",
/// which is the safe answer.
pub fn publishCtrlCursor(io: std.Io, conv: []const u8, cursor: usize) void {
    if (conv.len == 0 or conv.len > 64) return;
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] == conv.len and std.mem.eql(u8, active_convs[i][0..active_lens[i]], conv)) {
            active_ctrl[i] = cursor;
            return;
        }
    }
}

/// Will the turn running for `conv` actually READ a control op that landed at byte offset `at`?
///
/// isTurnLive answers a different question — "is something running" — and a client steering a turn cannot use
/// it, because a turn that started AFTER the op landed snapshots its cursor past the op and skips it forever
/// while still reporting live. The three answers here, and why each is sound:
///
///   * no slot for this conv                → false. Nothing is reading; the op waits for a turn that will
///                                            snapshot past it.
///   * slot held, cursor NOT yet published  → false. The snapshot has not happened, so it will happen after
///                                            `at` was already on disk, so it will land past the op.
///   * cursor published as C                → C <= at. drainChatControl reads from C forward, so an op at or
///                                            after C is inside every tail it reads.
///
/// The one-directional guarantee is deliberate: a caller passing an `at` measured BEFORE its own append can only
/// UNDER-report (another writer's line may have landed in between, pushing the real offset higher — still >= C),
/// never claim an op will be read when it will not. Remaining honest gap: an explicit `stop` ends its turn
/// WITHOUT the closing salvage drain, so a steer racing a stop can still be consumed-as-read and discarded.
pub fn turnWillConsume(io: std.Io, conv: []const u8, at: usize) bool {
    if (conv.len == 0 or conv.len > 64) return false;
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] == conv.len and std.mem.eql(u8, active_convs[i][0..active_lens[i]], conv))
            return (active_ctrl[i] orelse return false) <= at;
    }
    return false;
}

/// Back-compat shim for callers with no uid to hand (the scheduler runs as the task's owner, but its
/// call site predates this). uid 0 shares one bucket, which is correct for server-initiated work.
pub fn tryBeginTurn(io: std.Io, conv: []const u8) bool {
    return beginTurn(io, conv, 0) == .ok;
}

/// Idempotent network reads whose exact repeat within one turn returns the same bytes — the search-spiral
/// tool set the repeat-call ledger covers. Stateful tools stay exempt (a re-read after a write is legitimate).
fn dedupableTool(name: []const u8) bool {
    const list = [_][]const u8{ "web_search", "web_fetch", "fetch_json", "read_url", "osint_scan", "deep_crawl" };
    for (list) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// One tracked call signature for the turn-scoped tool-echo guard (the swarm loop's design, ported): sig =
/// hash(name+args), res = hash of the last result, count = consecutive identical call+result repeats. Unlike
/// the network ledger above this covers EVERY tool — a stateful tool whose result CHANGED resets its count,
/// so legitimate re-reads after writes never trip it; only true echo loops (identical call, identical bytes,
/// over and over) are warned and then refused. That changed-result reset needs the call to EXECUTE, which a
/// wedged slot (count past the limit) never does again — the refusal's "it will not return anything
/// different" would otherwise be self-fulfilling. So `probe` marks side-effect-free file reads, and a landed
/// mutation caps wedged probe slots back to one-below-limit: one real execution to observe whether the world
/// actually changed (see PROBE RE-OPEN in runInnerAgentic).
const EchoRec = struct { sig: u64 = 0, res: u64 = 0, count: u8 = 0, probe: bool = false };

// ------------------------------------------------------------------ file ledger (the fine-needle memory weave)

/// One landed file mutation, engine-verified from the tool's own success result — the conversation's exact
/// ground truth of what exists in the build workdir. Captured at the tool dispatch point (so DELEGATED
/// client-mode writes register too), upserted by path, persisted per-conv as files.jsonl, observed into the
/// conversation's neuron-db partition immediately, and woven into every drive step — so the model never has
/// to "wonder" (or confabulate) what it already wrote.
const LedgerFile = struct { path: []u8, bytes: u64 };
const FileLedger = struct {
    files: std.ArrayListUnmanaged(LedgerFile) = .empty,
    mutations: u32 = 0, // landed mutations this TURN (incl. delegated) — the client-mode files_written stand-in
    // The ledger KNOWS it may be missing entries (cap overflow, unreadable/oversized files.jsonl, an
    // unparseable line). While set, the woven block must stop universally quantifying ("a file not in this
    // list was never written") and say "may be incomplete" instead — a partial ledger that overclaims
    // invites blind re-writes of good files, the exact damage it exists to prevent.
    partial: bool = false,
    // Entries came from a DISK SURVEY of the build workdir (restart resume — no files.jsonl existed yet),
    // not from observed writes: the block words them as "already exist, continue FROM this state".
    from_disk: bool = false,

    fn deinit(self: *FileLedger, gpa: std.mem.Allocator) void {
        for (self.files.items) |f| gpa.free(f.path);
        self.files.deinit(gpa);
    }
    /// Upsert by path, separator-insensitively (Windows tools may report `src\\a.py` for the `src/a.py`
    /// written earlier; both are one file). Stored paths are normalized to '/'. Bounded at 128 files —
    /// overflow flips `partial` so the block downgrades its claim instead of lying by omission.
    fn note(self: *FileLedger, gpa: std.mem.Allocator, path: []const u8, bytes: u64) void {
        if (path.len == 0 or path.len > 300) return;
        for (self.files.items) |*f| {
            if (sameSep(f.path, path)) {
                f.bytes = bytes;
                return;
            }
        }
        if (self.files.items.len >= 128) {
            self.partial = true;
            return;
        }
        const p = gpa.dupe(u8, path) catch return;
        for (p) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        self.files.append(gpa, .{ .path = p, .bytes = bytes }) catch gpa.free(p);
    }
    fn has(self: *const FileLedger, path: []const u8) ?u64 {
        for (self.files.items) |f| {
            if (sameSep(f.path, path)) return f.bytes;
        }
        return null;
    }
};

/// Credential-shaped key anywhere in a small args clip — the observe cue is DROPPED rather than persisted
/// into the memory store. Over-redaction ("count tokens" query) is the accepted cost; fail-safe direction.
fn looksCredentialed(s: []const u8) bool {
    var lb: [160]u8 = undefined;
    if (s.len > lb.len) return true;
    const lower = std.ascii.lowerString(lb[0..s.len], s);
    return containsCredentialKey(lower);
}

/// Case-INSENSITIVE-ready scan for credential-shaped key names (caller lowercases, or use on known-lower
/// text). Split from looksCredentialed so RESULT clips (longer than its 160-byte args window) can be
/// scanned too: a probe that returned a csrf/session token must not persist as a memory fact.
fn containsCredentialKey(lower: []const u8) bool {
    const keys = [_][]const u8{ "authorization", "api_key", "api-key", "apikey", "token", "password", "passwd", "secret", "bearer", "credential", "csrf", "set-cookie" };
    for (keys) |k| {
        if (std.mem.indexOf(u8, lower, k) != null) return true;
    }
    return false;
}

/// Would storing this tool's RESULT just re-mint memory output as new facts? recall/recall_hive RETURN
/// memory — observing their echoes copies other scopes' facts into this one (observed live: a Discourse
/// task's memory carrying an unrelated FPS-game description via one recall echo — the bleed class that
/// relevance gates can't stop once the fact is laundered into the local scope). read_doc PAGES stored
/// documents — observing its output would re-mint an entire book back into memory, page by page.
/// observe/skill acks are bookkeeping, not findings.
fn memoryEchoTool(name: []const u8) bool {
    const t = [_][]const u8{ "recall", "recall_hive", "read_doc", "observe", "skill" };
    for (t) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// In-place atomization guard for a composed tool note: fold hard whitespace and SOFTEN sentence enders
/// (". " → ", ") so the store's sentence atomizer keeps the note as ONE fact — a tool finding is one
/// thread, not a paragraph to shred (the desk's atomizeForObserve discipline, applied server-side).
fn atomizeNoteInPlace(s: []u8) void {
    for (s) |*c| {
        if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
    }
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        const c = s[i];
        if ((c == '.' or c == ';' or c == '!' or c == '?') and s[i + 1] == ' ') s[i] = ',';
    }
}

/// Path equality where '\\' == '/' — the one normalization the ledger needs on Windows.
fn sameSep(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xn: u8 = if (x == '\\') '/' else x;
        const yn: u8 = if (y == '\\') '/' else y;
        if (xn != yn) return false;
    }
    return true;
}

/// Parse a file-mutating tool's SUCCESS result into (path, bytes). These are the exact shapes tools.zig
/// returns for write_file/edit_file — and DELEGATED client execution returns the identical strings (exec-tool
/// runs the same code): "wrote {path} — file is now {N} bytes", "appended to {path} — …", "rewrote {path} — …",
/// "edited {path} — {K} op(s) applied, file is now {N} bytes". Anything else (failures, guard notes, other
/// tools) returns null. Pure — unit-tested.
fn parseFileMutation(tool: []const u8, result: []const u8) ?struct { path: []const u8, bytes: u64 } {
    if (!std.mem.eql(u8, tool, "write_file") and !std.mem.eql(u8, tool, "edit_file")) return null;
    const prefixes = [_][]const u8{ "wrote ", "appended to ", "rewrote ", "edited " };
    var rest: []const u8 = "";
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, result, p)) {
            rest = result[p.len..];
            break;
        }
    }
    if (rest.len == 0) return null;
    // The success shapes ALWAYS carry the "file is now {N} bytes" marker; failure strings never do —
    // requiring it kills the failure-as-success mints (edit_file's "{path} does not exist … — use
    // write_file…" starts with the raw model path, which can itself start with "edited "). Both scans run
    // LAST-occurrence: a pathological path may contain " — " or even "file is now " — the true marker and
    // separator are always the final ones (the tail after the real separator never repeats them).
    const marker = std.mem.lastIndexOf(u8, rest, "file is now ") orelse return null;
    const sep = std.mem.lastIndexOf(u8, rest[0..marker], " \xe2\x80\x94 ") orelse return null; // " — "
    const path = rest[0..sep];
    if (path.len == 0 or path.len > 300) return null;
    var bytes: u64 = 0;
    var i = marker + "file is now ".len;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') : (i += 1)
        bytes = bytes *| 10 +| (rest[i] - '0');
    return .{ .path = path, .bytes = bytes };
}

/// The "path" argument of a tool call's args JSON (unescaped only for the plain case — an escaped path simply
/// returns null and the caller stays quiet; fail-safe, never fail-wrong). Pure — unit-tested.
fn argsPath(args: []const u8) ?[]const u8 {
    const key = "\"path\":\"";
    const s = std.mem.indexOf(u8, args, key) orelse return null;
    const rest = args[s + key.len ..];
    const e = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const p = rest[0..e];
    if (p.len == 0 or std.mem.indexOfScalar(u8, p, '\\') != null) return null;
    return p;
}

/// The last path segment (either separator): "client/js/game.js" → "game.js".
fn pathBase(p: []const u8) []const u8 {
    var i = p.len;
    while (i > 0) : (i -= 1) {
        if (p[i - 1] == '/' or p[i - 1] == '\\') break;
    }
    return p[i..];
}

/// Does the turn's injected cross-task knowledge mention this path's basename? A hit means a NOT-FOUND read
/// of the path was chasing another task's files. Basenames under 4 chars are too generic to pin that on.
fn foreignMentions(foreign: []const u8, path: []const u8) bool {
    if (foreign.len == 0) return false;
    const base = pathBase(path);
    if (base.len < 4) return false;
    return std.mem.indexOf(u8, foreign, base) != null;
}

test "foreignMentions matches basenames from injected cross-task knowledge" {
    const foreign = "KNOWLEDGE FROM OTHER TASKS: index.html is a Three.js FPS game (Neo-Pulse Arena)";
    try std.testing.expect(foreignMentions(foreign, "index.html"));
    try std.testing.expect(foreignMentions(foreign, "client/index.html"));
    try std.testing.expect(!foreignMentions(foreign, "business_model.md"));
    try std.testing.expect(!foreignMentions("", "index.html"));
    try std.testing.expect(!foreignMentions(foreign, "a.js")); // too short to pin a conflict on
}

/// Append one landed mutation to {conv_dir}/files.jsonl — the per-conv ledger file (same whole-line append
/// idiom as messages.jsonl, so a concurrent reader never sees a partial object).
fn ledgerPersist(app: *App, conv_dir: []const u8, tool: []const u8, path: []const u8, bytes: u64) void {
    const gpa = app.gpa;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    line.appendSlice(gpa, "{\"path\":") catch return;
    http.jstr(gpa, &line, path) catch return;
    const mid = std.fmt.allocPrint(gpa, ",\"bytes\":{d},\"tool\":\"{s}\",\"ts\":{d}}}\n", .{ bytes, tool, nowSecs(app.io) }) catch return;
    defer gpa.free(mid);
    line.appendSlice(gpa, mid) catch return;
    const fp = std.fmt.allocPrint(gpa, "{s}/files.jsonl", .{conv_dir}) catch return;
    defer gpa.free(fp);
    http.appendFile(app.io, gpa, fp, line.items) catch {};
}

/// Load {conv_dir}/files.jsonl into the ledger (upsert per line — the newest entry for a path wins), giving
/// the turn CROSS-TURN ground truth: a follow-up "continue" turn starts knowing every file already written.
/// Only plain (backslash-free) paths are parsed — same fail-safe rule as argsPath.
fn ledgerLoad(app: *App, conv_dir: []const u8, ledger: *FileLedger) void {
    const gpa = app.gpa;
    const fp = std.fmt.allocPrint(gpa, "{s}/files.jsonl", .{conv_dir}) catch return;
    defer gpa.free(fp);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, fp, gpa, .limited(256 << 10)) catch |e| {
        // .limited FAILS on an oversized file (it does not truncate) — an unreadable ledger is UNKNOWN
        // state, not "no files": flag partial so the block never claims unlisted files were never written.
        // A missing file is simply a fresh conversation.
        if (e != error.FileNotFound) ledger.partial = true;
        return;
    };
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (t.len == 0) continue;
        const p = argsPath(t) orelse {
            ledger.partial = true; // a line we could not parse (escaped path, corruption) — unknown entry
            continue;
        };
        var bytes: u64 = 0;
        if (std.mem.indexOf(u8, t, "\"bytes\":")) |bp| {
            var i = bp + "\"bytes\":".len;
            while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1)
                bytes = bytes *| 10 +| (t[i] - '0');
        }
        ledger.note(gpa, p, bytes);
    }
    // COMPACTION: files.jsonl appends one line per landed write forever; past ~256KiB the .limited read
    // above would start FAILING and the whole cross-turn ledger would silently vanish. Rewrite it as the
    // upserted snapshot (bounded: <=128 entries) once it crosses half the cap — but only when the parse was
    // COMPLETE (compacting a partial ledger would delete the very entries we failed to parse).
    if (!ledger.partial and data.len > (128 << 10)) {
        var snap: std.ArrayListUnmanaged(u8) = .empty;
        defer snap.deinit(gpa);
        var ok = true;
        for (ledger.files.items) |f| {
            snap.appendSlice(gpa, "{\"path\":") catch {
                ok = false;
                break;
            };
            http.jstr(gpa, &snap, f.path) catch {
                ok = false;
                break;
            };
            const tail = std.fmt.allocPrint(gpa, ",\"bytes\":{d},\"tool\":\"compact\",\"ts\":{d}}}\n", .{ f.bytes, nowSecs(app.io) }) catch {
                ok = false;
                break;
            };
            defer gpa.free(tail);
            snap.appendSlice(gpa, tail) catch {
                ok = false;
                break;
            };
        }
        if (ok) std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = fp, .data = snap.items }) catch {};
    }
}

/// Render the ledger as ONE compact bracketed block (bounded ~1.4KB) — the GROUND TRUTH half of the per-step
/// weave. Empty ledger renders nothing.
fn ledgerBlock(gpa: std.mem.Allocator, ledger: *const FileLedger, out: *std.ArrayListUnmanaged(u8)) void {
    if (ledger.files.items.len == 0) return;
    // A COMPLETE ledger may quantify universally; a partial one must not — overclaiming "never written"
    // about a file that silently fell off the ledger invites a blind re-write over good work. Survey
    // entries word the resume case: the work EXISTS, continue from it (the observed restart bug: a bare
    // "continue" re-started the whole build from scratch).
    out.appendSlice(gpa, if (ledger.partial and ledger.from_disk)
        "\n\n[ENGINE GROUND TRUTH — the build workdir ALREADY CONTAINS these files (surveyed from disk; this conversation is RESUMING earlier work — do NOT start over or re-scaffold). The list may be INCOMPLETE — verify unlisted files with list_dir before assuming anything: "
    else if (ledger.partial)
        "\n\n[ENGINE GROUND TRUTH — these files were ALREADY WRITTEN in this conversation and exist in the build workdir. Do not re-write them blind and do not burn a step re-verifying them. This list may be INCOMPLETE — verify a file that is not listed with list_dir before assuming anything: "
    else if (ledger.from_disk)
        "\n\n[ENGINE GROUND TRUTH — the build workdir ALREADY CONTAINS these files (surveyed from disk; this conversation is RESUMING earlier work). Do NOT start over or re-scaffold: continue FROM this state — read what exists where needed and build the missing pieces: "
    else
        "\n\n[ENGINE GROUND TRUTH — these files were ALREADY WRITTEN in this conversation and exist in the build workdir. Do not re-write them blind and do not burn a step re-verifying them; a file NOT in this list was never successfully written: ") catch return;
    var listed: usize = 0;
    for (ledger.files.items) |f| {
        if (out.items.len > 1400) break;
        if (listed > 0) out.appendSlice(gpa, ", ") catch return;
        out.appendSlice(gpa, f.path) catch return;
        var bb: [32]u8 = undefined;
        out.appendSlice(gpa, std.fmt.bufPrint(&bb, " ({d} B)", .{f.bytes}) catch "") catch return;
        listed += 1;
    }
    if (listed < ledger.files.items.len) {
        var mb: [40]u8 = undefined;
        out.appendSlice(gpa, std.fmt.bufPrint(&mb, " … +{d} more", .{ledger.files.items.len - listed}) catch "") catch return;
    }
    out.append(gpa, ']') catch return;
}

/// One drive step's woven context; both halves gpa-owned ("" = absent). `step` — the engine's file-ledger
/// ground truth + the conversation's OWN recalled records — rides inside the step text as before. `hive` —
/// cross-task knowledge — is emitted by the CALLER as the engine's own system note: appended to the
/// user-role step text it read as "the user mentioned…" and a fresh conversation adopted an old task's
/// project wholesale (the observed derailment).
const StepWeave = struct { step: []u8 = &[_]u8{}, hive: []u8 = &[_]u8{} };

/// Header for cross-task hive knowledge — names the source, disclaims user authorship, and pre-empts the
/// two observed failure readings (treating it as the user's words / treating its files as present here).
const HIVE_FOREIGN_HEADER = "KNOWLEDGE FROM OTHER TASKS (engine-recalled from the shared hive; the user did NOT say this). It may be stale or irrelevant — ignore it unless the user's request explicitly refers to it. Files or projects it mentions do NOT exist in this conversation unless ENGINE GROUND TRUTH / list_dir shows them; never adopt them as the goal:\n";

/// Stop list for the relevance bar: the drive loop's own steering vocabulary (subtask templates, afk
/// nudges, ground-truth blocks) plus generic function words. Terms shorter than 4 chars never reach the
/// list, so only 4+ entries appear.
const HIVE_STOP = [_][]const u8{
    // steering-template vocabulary (subtaskInstruction, AFK_DRIVE_TMPL, AFK_STUCK_TMPL, ledger blocks)
    "work",    "working",   "subtask",  "step",    "plan",     "route",        "suggested", "hive",   "cast",        "swarm",
    "steer",   "build",     "built",    "done",    "briefly",  "inline",       "directly",  "tool",   "tools",       "write",
    "edit",    "file",      "files",    "python",  "research", "learn",        "look",      "first",  "keep",        "going",
    "toward",  "goal",      "verify",   "latest",  "single",   "most",         "valuable",  "next",   "improvement", "repeated",
    "last",    "different", "approach", "recall",  "search",   "actual",       "blocker",   "engine", "ground",      "truth",
    "list",    "exist",     "exists",   "workdir", "written",  "conversation",
    // generic function words
    "this",      "that",   "with",        "from",
    "into",    "your",      "have",     "will",    "then",     "than",         "they",      "them",   "what",        "when",
    "where",   "which",     "should",   "would",   "could",    "about",        "after",     "before", "using",       "their",
    "there",   "here",      "only",     "also",    "just",     "been",         "were",      "does",   "doing",       "each",
    "every",   "other",     "some",     "more",    "much",     "many",         "very",      "over",   "under",       "between",
    "because", "while",     "still",    "already", "without",  "within",
};

fn hiveStopWord(w: []const u8) bool {
    for (&HIVE_STOP) |s| {
        if (std.mem.eql(u8, s, w)) return true;
    }
    return false;
}

/// Next lowercase alnum run of `s` from `pos` into `buf` (clipped to buf.len — both sides of the match
/// clip identically, so comparisons stay consistent). null at end of input.
fn nextTerm(s: []const u8, pos: *usize, buf: []u8) ?[]const u8 {
    var i = pos.*;
    while (i < s.len and !std.ascii.isAlphanumeric(s[i])) i += 1;
    var n: usize = 0;
    while (i < s.len and std.ascii.isAlphanumeric(s[i])) : (i += 1) {
        if (n < buf.len) {
            buf[n] = std.ascii.toLower(s[i]);
            n += 1;
        }
    }
    pos.* = i;
    if (n == 0) return null;
    return buf[0..n];
}

/// DISCRIMINATIVE-RELEVANCE BAR for cross-task knowledge: keep only the fact lines that share vocabulary
/// with the step cue — at least two distinct content terms, or one long (8+ chars) one. Saturation-spread
/// assoc on a small scope returns its argmax for ANY cue; unfiltered, a fresh conversation's step 1
/// inherited a two-day-old FPS project because the hive happened to contain one. gpa-owned ("" = nothing).
fn hiveRelevant(gpa: std.mem.Allocator, cue: []const u8, facts: []const u8) []u8 {
    var terms: [24][24]u8 = undefined;
    var term_len: [24]usize = @splat(0);
    var nterms: usize = 0;
    {
        var pos: usize = 0;
        var tb: [24]u8 = undefined;
        collect: while (nextTerm(cue, &pos, &tb)) |t| {
            if (t.len < 4 or hiveStopWord(t)) continue;
            for (terms[0..nterms], term_len[0..nterms]) |ex, el| {
                if (std.mem.eql(u8, ex[0..el], t)) continue :collect;
            }
            if (nterms >= terms.len) break;
            @memcpy(terms[nterms][0..t.len], t);
            term_len[nterms] = t.len;
            nterms += 1;
        }
    }
    if (nterms == 0) return &[_]u8{};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, facts, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        var hit: [24]bool = @splat(false);
        var distinct: usize = 0;
        var longest: usize = 0;
        var pos: usize = 0;
        var tb: [24]u8 = undefined;
        while (nextTerm(t, &pos, &tb)) |w| {
            if (w.len < 4) continue;
            for (terms[0..nterms], term_len[0..nterms], 0..) |ex, el, ti| {
                if (hit[ti] or !std.mem.eql(u8, ex[0..el], w)) continue;
                hit[ti] = true;
                distinct += 1;
                longest = @max(longest, el);
            }
        }
        if (distinct >= 2 or (distinct >= 1 and longest >= 8)) {
            if (out.items.len > 0) out.append(gpa, '\n') catch {};
            out.appendSlice(gpa, t) catch {};
        }
    }
    return out.toOwnedSlice(gpa) catch &[_]u8{};
}

test "hiveRelevant drops off-cue facts, keeps cue-sharing ones" {
    const gpa = std.testing.allocator;
    const facts = "[chat r0] index.html is a Three.js FPS game (Neo-Pulse Arena) with wave spawning\n[chat r0] Canadian wildfire seasons have been historically severe\n";
    // the observed derailment cue: a business-planning step shares no discriminative vocabulary
    const none = hiveRelevant(gpa, "Work this subtask now - step 1 of 10 in your plan: Define business idea and value proposition", facts);
    defer if (none.len > 0) gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    // a cue that actually refers to the old game keeps the game line and drops the wildfire one
    const kept = hiveRelevant(gpa, "continue the three.js fps game neo pulse arena weapon system", facts);
    defer if (kept.len > 0) gpa.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "Neo-Pulse") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "wildfire") == null);
}

/// The FINE-NEEDLE WEAVE for one drive step: engine ground truth (the file ledger) + per-step associative
/// recall from the conversation's own neuron-db partition — the model re-enters every step knowing what
/// already exists on disk and what it already learned, instead of re-exploring, re-writing, or
/// confabulating success. Cross-task hive knowledge comes back in the SEPARATE `hive` half, relevance-
/// gated and provenance-framed, for the caller to emit as an engine note.
fn stepWeave(gpa: std.mem.Allocator, ctx: *tools.ToolCtx, ledger: *const FileLedger, step_text: []const u8) StepWeave {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var hive_out: std.ArrayListUnmanaged(u8) = .empty;
    defer hive_out.deinit(gpa);
    ledgerBlock(gpa, ledger, &out);
    // Per-step recall: the step text is the cue; the conversation's own observed facts (tool findings, file
    // facts, user turns — including ones already compacted out of the context window) come back exactly when
    // a step needs them. SATURATION spread — the activation wave follows every discriminative thread until
    // it settles (neuron-db's frontier-drain convergence), not a fixed hop budget; k + decay + trust bound
    // the output. One bounded subprocess per drive step; abstains quietly.
    // FAMILY-WIDE for sub-chats: recall runs across the chat family base ("chat:<primary>" reaches the
    // primary + every "__sN" branch partition), so the primary and its branches read ONE mind while each
    // conversation's writes stay in its own partition. A plain conv's base is itself — behavior unchanged.
    const rec = ctx.mem.assocAcross(cpaths.scopeFamilyBase(ctx.scope), step_text, osc.Mem.SATURATE_HOPS, 6);
    defer if (rec.len > 0) gpa.free(rec);
    if (rec.len > 0) {
        scrubUtf8(rec);
        out.appendSlice(gpa, "\n[RELEVANT MEMORY (this conversation's own records): ") catch {};
        out.appendSlice(gpa, clipBytes(rec, 700)) catch {};
        out.append(gpa, ']') catch {};
    } else {
        // The conversation's own partition abstained — thread OUTWARD across the shared KNOWLEDGE hive
        // (where every conversation's observes and swarm deposits land). That scope is CROSS-TASK by
        // construction, so what comes back must clear the relevance bar, and it never rides inside the
        // step text: it returns as the engine's own provenance-framed note. ACROSS: absorbed documents
        // live in their own knowledge__doc-* sub-scopes now — still one spawn, the CLI fans in-process.
        const hive = ctx.mem.assocAcross(tools.KNOWLEDGE_SCOPE, step_text, osc.Mem.SATURATE_HOPS, 4);
        defer if (hive.len > 0) gpa.free(hive);
        if (hive.len > 0) {
            scrubUtf8(hive);
            const kept = hiveRelevant(gpa, step_text, hive);
            defer if (kept.len > 0) gpa.free(kept);
            if (kept.len > 0) {
                hive_out.appendSlice(gpa, HIVE_FOREIGN_HEADER) catch {};
                hive_out.appendSlice(gpa, clipBytes(kept, 500)) catch {};
            }
        }
    }
    return .{
        .step = out.toOwnedSlice(gpa) catch &[_]u8{},
        .hive = hive_out.toOwnedSlice(gpa) catch &[_]u8{},
    };
}

/// A continuation-shaped user turn ("continue", "resume", the desk's auto-loop arm note) carries no recall
/// cue of its own — the observed restart bug: recall keyed on the literal word "continue" surfaces nothing,
/// the resumed turn starts unanchored, and the model re-scaffolds the build from zero.
fn continuationShaped(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \r\n\t");
    if (t.len == 0) return true;
    if (std.mem.startsWith(u8, t, "Auto-loop armed")) return true;
    if (t.len > 80) return false;
    var lb: [80]u8 = undefined;
    const lower = std.ascii.lowerString(&lb, t);
    const heads = [_][]const u8{ "continue", "go on", "keep going", "keep at it", "resume", "carry on", "proceed", "finish your task", "next" };
    for (heads) |h| {
        if (!std.mem.startsWith(u8, lower, h)) continue;
        // word boundary: "nextjs setup" / "proceedings" must not read as continuations
        if (lower.len > h.len and std.ascii.isAlphanumeric(lower[h.len])) continue;
        return true;
    }
    return false;
}

/// Bank a batch of ENGINE-OBSERVED facts into neuron-db, and notice when they do not land.
///
/// Every deposit site used to discard the return (`_ = ctx.mem.observeBatch(...)`), so a store that was absent,
/// tamper-tripped, or erroring looked exactly like a healthy one with nothing to say. That silence is not a
/// cosmetic gap: the compaction path drops bytes out of the context window on the stated grounds that older
/// detail "already lives in neuron-db recall", so a store that quietly accepts nothing turns a bounded context
/// into permanent data loss with no alarm attached — which is how it stayed dead long enough to be designed
/// around.
///
/// The shortfall is measured, not the zero. observeBatch also returns 0 when every note was rejected by the fact
/// hygiene filter (too few identifying characters to be a usable memory), which is ordinary and not a fault, so
/// comparing `stored` against `queued` is what distinguishes "nothing worth keeping" from "nothing got through".
/// The message deliberately says only that the store did not accept the records: never the database path, and
/// never the state of the tamper tripwire, which would make this a probe for it.
fn memBank(app: *App, ctx: *tools.ToolCtx, scope: []const u8, notes: []const []const u8) void {
    _ = app;
    if (notes.len == 0) return;
    const stored = ctx.mem.observeBatch(scope, notes);
    if (stored >= notes.len) return;
    memlog.warn("memory: the store accepted {d} of {d} record(s) queued this step — recall will be thinner than the context that was dropped for it", .{ stored, notes.len });
}
const memlog = std.log.scoped(.chatmem);

/// Does this call's outcome count toward the same-tool FAILURE STREAK (the nudge at 2, the arbiter at 3)?
///
/// A GUARD REFUSAL COUNTS. The streak block used to sit inside `if (executed)`, which made the only
/// approach-changing escalation in the engine unreachable for the one failure mode it was built for: an
/// echo-refused call never executes, so a model grinding the same call accrued no streak, was never shown the
/// option space, never heard the arbiter, and simply collected refusals until the loop guard killed the turn.
/// The grind switched off the machinery for breaking grinds. Gated exactly like the loop strike (`echo_blocked or
/// repeated_prior`), so a SAME-BATCH duplicate still does not count — the model had not yet seen feedback to
/// ignore, and striking it would punish dup-batching models that are otherwise making progress.
fn streakEligible(executed: bool, echo_blocked: bool, repeated_prior: bool) bool {
    return executed or echo_blocked or repeated_prior;
}

/// A short META-QUESTION about the RUN ITSELF — "are you stuck?", "what are you doing?", "still there?". Such a
/// message is a perfectly good thing to ANSWER, and it reaches the model as a user turn either way; what it is NOT
/// is the conversation's goal. Letting it become one is how a single "are you stuck?" turned every re-grounding
/// surface into a re-injection of the fixation: the drive picker announced "THE GOAL of this conversation: are you
/// stuck exactly?", the stuck template said "re-read the goal" and pointed back at the same question, the course
/// check graded progress against it, and recall keyed on it and surfaced nothing. The model then spent its cycles
/// on the meta-question because the engine kept telling it that WAS the job.
///
/// NARROW ON PURPOSE, and narrower than it first looks like it should be. This predicate SUPPRESSES a message's
/// claim to be the goal, so a false positive silently steers the turn by an older goal instead — the same class of
/// harm the fix exists to remove, merely pointed the other way. A first cut matched open-ended prefixes ("why is
/// this", "why is it", "are we", "status", "did you get") and swallowed ordinary work: "why is this test
/// failing?", "are we handling null bytes in the parser?", "status of the migration?", "did you get the CSV export
/// working?" were all read as meta. So:
///   * every head is boundary-checked, exactly as continuationShaped does it, or "are website builds cached?"
///     matches the head "are we" on its first six bytes;
///   * heads must be specific to the ASSISTANT or the RUN, never a generic sentence opener; and
///   * forms too short to carry a subject at all ("status?", "progress?") are matched WHOLE, never as prefixes,
///     so "statuses of the queued jobs?" and "status of the migration?" stay the goal they are.
/// Anything without a trailing '?', anything over 120 bytes, and any question carrying real work is left alone.
fn metaQuestionShaped(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \r\n\t`*\"'");
    if (t.len == 0 or t.len > 120) return false;
    if (t[t.len - 1] != '?') return false;
    var lb: [120]u8 = undefined;
    const lower = std.ascii.lowerString(&lb, t);
    // Drop the '?' and any space before it so a head can match to end-of-string.
    const body = std.mem.trim(u8, lower[0 .. lower.len - 1], " ");
    if (body.len == 0) return false;
    // WHOLE-MESSAGE forms: no subject, so only an exact match is safe.
    for ([_][]const u8{
        "status",   "status update", "progress", "any progress", "any update",
        "you good", "still there",   "you there", "hello",       "you alive",
    }) |exact| if (std.mem.eql(u8, body, exact)) return true;
    // PHRASAL heads: each names the assistant or the run, and each is boundary-checked.
    const heads = [_][]const u8{
        "are you stuck",      "are you ok",           "are you okay",        "are you there",
        "are you alive",      "are you still",        "are you done",        "are you working",
        "are you looping",    "are you lost",         "are you making progress",
        "you stuck",          "u stuck",              "r u stuck",
        "what are you doing", "what are you working", "what are you up to",
        "what happened",      "what's going on",      "whats going on",      "what is going on",
        "why are you",        "why is this taking",   "why is it taking",    "why is this so slow",
        "how is it going",    "how's it going",       "hows it going",
        "is it stuck",        "is this stuck",        "did you get stuck",   "any progress",
    };
    for (heads) |h| {
        if (!std.mem.startsWith(u8, body, h)) continue;
        // word boundary — "are website builds cached?" must not match a head that is its byte-prefix
        if (body.len > h.len and std.ascii.isAlphanumeric(body[h.len])) continue;
        return true;
    }
    return false;
}

/// The conversation's first user message (the pinned goal), parsed from messages.jsonl's head — the right
/// recall cue for a continuation-shaped turn. Uses the same bounded head read as assembleHistory (a
/// .limited readFileAlloc would FAIL outright on a long conversation's file). gpa-owned, or null.
/// The LAST assistant message content of a conversation (tail-windowed read) — the sub-chat family
/// block's "what is the primary up to right now". null when none is readable. gpa-owned.
fn lastAssistantNote(app: *App, conv_dir: []const u8) ?[]u8 {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return null;
    defer gpa.free(mpath);
    const head_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return null;
    defer gpa.free(head_buf);
    const tail_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return null;
    defer gpa.free(tail_buf);
    const ht = cctx.readHeadTail(app.io, mpath, head_buf, tail_buf) orelse return null;
    var best: ?[]u8 = null;
    var it = std.mem.splitScalar(u8, ht.tail, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (t.len == 0) continue;
        const P = struct { role: []const u8 = "", content: []const u8 = "" };
        const p = std.json.parseFromSlice(P, gpa, t, .{ .ignore_unknown_fields = true }) catch continue; // a mid-line tail start just skips
        defer p.deinit();
        if (std.mem.eql(u8, p.value.role, "assistant") and p.value.content.len > 0) {
            if (best) |b| gpa.free(b);
            best = gpa.dupe(u8, p.value.content) catch null;
        }
    }
    return best;
}

/// Wire shape of `neuron --json recallscored` (contested facts carry the disagreeing sibling in
/// `with`). Shared by the turn's parse and the test below so the contract drifts loudly, not silently.
const ScoredHit = struct { fact: []const u8 = "", coverage: f64 = 0, overlap: u32 = 0, exact: u32 = 0, idx: u32 = 0, contested: bool = false, with: ?[]const u8 = null };
const ScoredRecall = struct { hits: []const ScoredHit = &.{} };

test "ScoredRecall parses the neuron CLI's recallscored wire shape verbatim" {
    const gpa = std.testing.allocator;
    // exact bytes a live `neuron --json recallscored` run produced (a contested pair + a clean hit)
    const wire = "{\"hits\":[{\"fact\":\"the api port is 8080\",\"coverage\":1.0000,\"overlap\":2,\"exact\":2,\"idx\":0,\"contested\":true,\"with\":\"the api port is 9090\"},{\"fact\":\"the deploy uses docker\",\"coverage\":0.6667,\"overlap\":2,\"exact\":2,\"idx\":2,\"contested\":false,\"with\":null}]}";
    const p = try std.json.parseFromSlice(ScoredRecall, gpa, wire, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.value.hits.len);
    try std.testing.expect(p.value.hits[0].contested);
    try std.testing.expectEqualStrings("the api port is 9090", p.value.hits[0].with.?);
    try std.testing.expect(!p.value.hits[1].contested);
    try std.testing.expect(p.value.hits[1].with == null);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), p.value.hits[0].coverage, 0.0001);
}

/// Sentinel for the tier-2 memory verifier: fire on any contested fact, or a weak top hit backing a
/// non-empty block. Pure and cheap — the always-on statistical gate deciding when the expensive
/// decorrelated check is worth one completion.
fn memSentinel(nhits: usize, contested: u32, top_conf: f32) bool {
    if (nhits == 0) return false;
    return contested > 0 or top_conf < 0.35;
}

/// Parse the memory-verifier's verdict ({"doubt":[{"i":N,"why":"…"}]}, possibly wrapped in prose)
/// into the caution note bid into the context. Null when nothing is doubted or the reply is
/// unusable — fail-open: a garbled verdict must never block the turn or invent a caution. An index
/// outside 1..=nhits is itself a hallucination and is dropped.
fn verifierNote(gpa: std.mem.Allocator, reply: []const u8, nhits: usize) ?[]u8 {
    const open = std.mem.indexOfScalar(u8, reply, '{') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, reply, '}') orelse return null;
    if (close <= open) return null;
    const D = struct { i: u32 = 0, why: []const u8 = "" };
    const V = struct { doubt: []const D = &.{} };
    const p = std.json.parseFromSlice(V, gpa, reply[open .. close + 1], .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    if (p.value.doubt.len == 0) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "MEMORY VERIFIER — a second model audited the RELEVANT MEMORY block above; treat these entries with caution:") catch return null;
    var any = false;
    for (p.value.doubt) |d| {
        if (d.i == 0 or d.i > nhits) continue;
        out.appendSlice(gpa, "\n- fact #") catch return null;
        var ib: [8]u8 = undefined;
        out.appendSlice(gpa, std.fmt.bufPrint(&ib, "{d}", .{d.i}) catch "?") catch return null;
        if (d.why.len > 0) {
            out.appendSlice(gpa, ": ") catch return null;
            out.appendSlice(gpa, clipBytes(d.why, 140)) catch return null;
        }
        any = true;
    }
    if (!any) return null;
    return gpa.dupe(u8, out.items) catch null;
}

test "memSentinel: contested or a weak top hit fires; a clean strong block stays quiet" {
    try std.testing.expect(!memSentinel(0, 0, 0.0)); // no facts, nothing to audit
    try std.testing.expect(memSentinel(3, 1, 0.9)); // contested → fire
    try std.testing.expect(memSentinel(2, 0, 0.2)); // weak top hit → fire
    try std.testing.expect(!memSentinel(4, 0, 0.8)); // strong, uncontested → quiet
}

test "verifierNote: builds the caution note, drops invented indexes, null on none/garbage" {
    const gpa = std.testing.allocator;
    const note = verifierNote(gpa, "Sure — my audit: {\"doubt\":[{\"i\":2,\"why\":\"contradicted by a newer fact\"},{\"i\":9,\"why\":\"out of range\"}]}", 3).?;
    defer gpa.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "fact #2: contradicted by a newer fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "#9") == null); // invented index dropped
    try std.testing.expect(verifierNote(gpa, "{\"doubt\":[]}", 3) == null);
    try std.testing.expect(verifierNote(gpa, "no json here", 3) == null);
    try std.testing.expect(verifierNote(gpa, "{\"doubt\":[{\"i\":9,\"why\":\"x\"}]}", 3) == null); // only invented → null
}

/// SUB-CHAT FAMILY CONTEXT, bid into the varying workspace channel (never the stable prefix). A branch
/// turn re-anchors on the PRIMARY live each turn: its goal plus its latest progress, so the branch
/// follows one angle without losing the trunk — and it stays current as the primary moves, unlike a
/// one-shot seed at branch creation. A primary with live branches gets them listed. Memory itself is
/// shared structurally (scopeFamilyBase across-recall); this block is the CONVERSATIONAL half of "they
/// must know the primary chat context".
fn injectFamilyContext(app: *App, conv: []const u8, base: []const u8, ws: *wsp.Workspace) void {
    const gpa = app.gpa;
    var block: std.ArrayListUnmanaged(u8) = .empty;
    defer block.deinit(gpa);
    if (cpaths.branchParts(conv)) |bp| {
        const pdir = std.fmt.allocPrint(gpa, "{s}/convs/{s}", .{ base, bp.parent }) catch return;
        defer gpa.free(pdir);
        block.print(gpa, "THIS IS SUB-CHAT {d} of a primary conversation. ", .{bp.n}) catch return;
        const goal = firstUserGoal(app, pdir);
        defer if (goal) |g| gpa.free(g);
        if (goal) |g| {
            block.appendSlice(gpa, "PRIMARY'S GOAL: \"") catch return;
            block.appendSlice(gpa, clipBytes(g, 300)) catch return;
            block.appendSlice(gpa, "\". ") catch return;
        }
        const last = lastAssistantNote(app, pdir);
        defer if (last) |l| gpa.free(l);
        if (last) |l| {
            scrubUtf8(l);
            block.appendSlice(gpa, "PRIMARY'S LATEST PROGRESS: \"") catch return;
            block.appendSlice(gpa, clipBytes(l, 500)) catch return;
            block.appendSlice(gpa, "\". ") catch return;
        }
        block.appendSlice(gpa, "Pursue THIS branch's angle in depth — do not re-do the primary's work. " ++
            "The family shares ONE memory (recall reaches the primary and sibling branches) and ONE " ++
            "workspace (the same files — coordinate through them, never clobber).") catch return;
    } else {
        // primary side: list live branches so the trunk knows its angles are being worked
        var listed: u8 = 0;
        var n: u8 = 1;
        while (n <= cpaths.MAX_BRANCHES) : (n += 1) {
            var db: [900]u8 = undefined;
            const bdir = std.fmt.bufPrint(&db, "{s}/convs/{s}__s{d}", .{ base, conv, n }) catch continue;
            std.Io.Dir.cwd().access(app.io, bdir, .{}) catch continue;
            if (listed == 0) block.appendSlice(gpa, "ACTIVE SUB-CHATS branched from this conversation: ") catch return;
            if (listed > 0) block.appendSlice(gpa, "; ") catch return;
            block.print(gpa, "s{d}", .{n}) catch return;
            const title = firstUserGoal(app, bdir);
            defer if (title) |t| gpa.free(t);
            if (title) |t| {
                block.appendSlice(gpa, " \"") catch return;
                block.appendSlice(gpa, clipBytes(t, 80)) catch return;
                block.appendSlice(gpa, "\"") catch return;
            }
            listed += 1;
        }
        if (listed > 0)
            block.appendSlice(gpa, ". Their findings are already in this conversation's shared memory (recall), and their files land in this same workspace.") catch return;
    }
    if (block.items.len == 0) return;
    ws.bid(.family, "chat-family", block.items, 0.70, 0, 0);
}

fn firstUserGoal(app: *App, conv_dir: []const u8) ?[]u8 {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return null;
    defer gpa.free(mpath);
    const head_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return null;
    defer gpa.free(head_buf);
    const tail_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return null;
    defer gpa.free(tail_buf);
    const ht = cctx.readHeadTail(app.io, mpath, head_buf, tail_buf) orelse return null;
    var it = std.mem.splitScalar(u8, ht.head, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (t.len == 0) continue;
        const P = struct { role: []const u8 = "", content: []const u8 = "" };
        const p = std.json.parseFromSlice(P, gpa, t, .{ .ignore_unknown_fields = true }) catch return null;
        defer p.deinit();
        if (std.mem.eql(u8, p.value.role, "user") and p.value.content.len > 0)
            return gpa.dupe(u8, p.value.content) catch null;
        return null; // first line is always the first user message by construction — anything else, abstain
    }
    return null;
}

/// RESTART RESUME (bootstrap): no files.jsonl entries, but the build workdir already holds files — a client
/// restart or a conversation predating the ledger. Survey the tree (names + sizes only, bounded, dot/dep
/// dirs skipped) so the resumed turn starts from "here is what exists" instead of re-scaffolding from zero.
fn ledgerBootstrap(app: *App, workdir: []const u8, ledger: *FileLedger) void {
    if (ledger.files.items.len > 0) return;
    var n: usize = 0;
    ledgerSurveyDir(app, workdir, "", 0, &n, ledger);
    if (ledger.files.items.len > 0) ledger.from_disk = true;
}

fn ledgerSurveyDir(app: *App, abs_dir: []const u8, rel: []const u8, depth: usize, n: *usize, ledger: *FileLedger) void {
    if (depth > 5) return;
    var dir = std.Io.Dir.cwd().openDir(app.io, abs_dir, .{ .iterate = true }) catch return;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (n.* >= 128) {
            ledger.partial = true; // the tree holds more than the survey — the block must not overclaim
            return;
        }
        if (ent.name.len == 0 or ent.name[0] == '.') continue; // dot-entries incl. .git stay out
        if (ent.kind == .directory and (std.mem.eql(u8, ent.name, "node_modules") or std.mem.eql(u8, ent.name, "__pycache__") or
            std.mem.eql(u8, ent.name, "target") or std.mem.eql(u8, ent.name, "dist") or std.mem.eql(u8, ent.name, "zig-out"))) continue;
        var ab: [1800]u8 = undefined;
        const child_abs = std.fmt.bufPrint(&ab, "{s}/{s}", .{ abs_dir, ent.name }) catch continue;
        var rb: [512]u8 = undefined;
        const child_rel = (if (rel.len == 0)
            std.fmt.bufPrint(&rb, "{s}", .{ent.name})
        else
            std.fmt.bufPrint(&rb, "{s}/{s}", .{ rel, ent.name })) catch continue;
        switch (ent.kind) {
            .directory => ledgerSurveyDir(app, child_abs, child_rel, depth + 1, n, ledger),
            .file => {
                const st = std.Io.Dir.cwd().statFile(app.io, child_abs, .{}) catch continue;
                ledger.note(app.gpa, child_rel, st.size);
                n.* += 1;
            },
            // OneDrive files-on-demand DEHYDRATED placeholders carry a reparse tag and classify as
            // .sym_link — real workdir files the survey cannot see. Flag partial so the block never
            // overclaims completeness over a cloud-dehydrated tree.
            .sym_link => ledger.partial = true,
            else => {},
        }
    }
}

/// The conv id of a LIVE turn whose id starts with `prefix`, copied into `out` — or null. Lets run-now refuse
/// a duplicate launch for a task that already has a run going (its conv ids share "scheduled_{taskid}_").
pub fn liveTurnWithPrefix(io: std.Io, prefix: []const u8, out: *[64]u8) ?[]const u8 {
    if (prefix.len == 0 or prefix.len > 64) return null;
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] >= prefix.len and std.mem.startsWith(u8, active_convs[i][0..active_lens[i]], prefix)) {
            const n = active_lens[i];
            @memcpy(out[0..n], active_convs[i][0..n]);
            return out[0..n];
        }
    }
    return null;
}

/// Is a turn executing for `conv` RIGHT NOW? Read-only scan of the per-conv turn table — the liveness bit the
/// conv GET carries so a client can attach its live poller to a server-born run (a scheduled task's turn).
pub fn isTurnLive(io: std.Io, conv: []const u8) bool {
    if (conv.len == 0 or conv.len > 64) return false;
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] == conv.len and std.mem.eql(u8, active_convs[i][0..active_lens[i]], conv)) return true;
    }
    return false;
}

/// Release the in-flight slot for `conv` (matches tryBeginTurn). Copies nothing — safe to call before freeing any
/// backing storage `conv` points into. Pub so postMessage can release the slot when a LATER admission gate (the
/// local-model budget) rejects the turn after tryBeginTurn already claimed it.
pub fn endTurn(io: std.Io, conv: []const u8) void {
    if (conv.len == 0 or conv.len > 64) return;
    turn_mtx.lockUncancelable(io);
    defer turn_mtx.unlock(io);
    for (0..MAX_ACTIVE_TURNS) |i| {
        if (active_lens[i] == conv.len and std.mem.eql(u8, active_convs[i][0..active_lens[i]], conv)) {
            active_lens[i] = 0;
            active_uids[i] = 0; // or the freed slot keeps counting against its owner's share forever
            active_ctrl[i] = null; // and a stale cursor must not answer for the NEXT turn that takes this slot
            return;
        }
    }
}

// ---------------------------------------------------------------- local-model admission (capability-tiered)
// A hosted provider fans out freely (up to MAX_ACTIVE_TURNS) — its concurrency is the provider's problem. A
// LOCAL model backend (Ollama/llama.cpp on loopback) is the opposite: ONE process doing one forward pass at a
// time, its weights already filling most of the machine's RAM/VRAM. Two concurrent local turns don't run in
// parallel — they queue inside the model server or thrash its KV cache, so admitting them just deepens a queue
// no one can see. Local turns therefore get a SEPARATE, machine-sized budget: qualify the box once and admit
// at most that many at a time, rejecting the rest with 409 (the desk falls back to its own engine, or the user
// waits) instead of piling onto a model that cannot parallelize. Hosted turns never touch this gate.
var local_mtx: std.Io.Mutex = .init;
var local_inflight: u32 = 0;
var local_budget_cache: u32 = 0; // 0 = not computed yet; memoized on first read (hardware is fixed for the run)

/// Total physical RAM in gibibytes (0 if it can't be determined). Windows: GlobalMemoryStatusEx; other OSes
/// return 0 → the budget falls back to the conservative floor of 1.
fn totalPhysicalRamGiB() u64 {
    if (builtin.os.tag != .windows) return 0;
    const win = struct {
        const MEMORYSTATUSEX = extern struct {
            dwLength: u32,
            dwMemoryLoad: u32,
            ullTotalPhys: u64,
            ullAvailPhys: u64,
            ullTotalPageFile: u64,
            ullAvailPageFile: u64,
            ullTotalVirtual: u64,
            ullAvailVirtual: u64,
            ullAvailExtendedVirtual: u64,
        };
        extern "kernel32" fn GlobalMemoryStatusEx(buffer: *MEMORYSTATUSEX) callconv(.c) i32;
    };
    var ms: win.MEMORYSTATUSEX = undefined;
    ms.dwLength = @sizeOf(win.MEMORYSTATUSEX);
    if (win.GlobalMemoryStatusEx(&ms) == 0) return 0;
    return ms.ullTotalPhys / (1 << 30);
}

/// Concurrent-local-turn budget from the qualified machine: RAM is the binding resource (model weights + a KV
/// cache per parallel slot), cores a secondary gate. Deliberately conservative — a mis-high budget OOMs or
/// thrashes the model server, a mis-low one just serializes (safe). Always >= 1.
fn deriveLocalBudget(ram_gib: u64, cores: u32) u32 {
    if (ram_gib == 0) return 1; // couldn't qualify → one at a time
    if (ram_gib >= 64 and cores >= 16) return 3;
    if (ram_gib >= 32 and cores >= 12) return 2;
    return 1;
}

/// How many concurrent LOCAL-model chat turns this machine may run. `NL_LOCAL_CHAT_BUDGET` (parent env) overrides
/// with an explicit number; otherwise it is derived from RAM + cores. Memoized — the hardware doesn't change.
pub fn localChatBudget(app: *App) u32 {
    if (local_budget_cache != 0) return local_budget_cache;
    var budget: u32 = 0;
    if (app.sup.parent_env) |env| {
        if (env.get("NL_LOCAL_CHAT_BUDGET")) |v| {
            const t = std.mem.trim(u8, v, " \r\n\t");
            if (std.fmt.parseInt(u32, t, 10)) |n| budget = n else |_| {}
        }
    }
    if (budget == 0) {
        const cores: u32 = @intCast(std.Thread.getCpuCount() catch 1);
        budget = deriveLocalBudget(totalPhysicalRamGiB(), cores);
    }
    budget = std.math.clamp(budget, 1, MAX_ACTIVE_TURNS);
    local_budget_cache = budget;
    return budget;
}

/// Claim one local-model turn slot. Returns false when the machine's local budget is already full (caller 409s
/// rather than pile onto a model that can't parallelize). Every success MUST be paired with releaseLocal.
pub fn tryClaimLocal(app: *App) bool {
    const budget = localChatBudget(app);
    local_mtx.lockUncancelable(app.io);
    defer local_mtx.unlock(app.io);
    if (local_inflight >= budget) return false;
    local_inflight += 1;
    return true;
}

/// Release a local-model turn slot claimed by tryClaimLocal. Saturating (never underflows past 0).
pub fn releaseLocal(io: std.Io) void {
    local_mtx.lockUncancelable(io);
    defer local_mtx.unlock(io);
    if (local_inflight > 0) local_inflight -= 1;
}

test "deriveLocalBudget: conservative floor, scales with RAM+cores" {
    try std.testing.expectEqual(@as(u32, 1), deriveLocalBudget(0, 32)); // unqualified machine → 1
    try std.testing.expectEqual(@as(u32, 1), deriveLocalBudget(16, 8)); // modest box → 1
    try std.testing.expectEqual(@as(u32, 2), deriveLocalBudget(32, 12));
    try std.testing.expectEqual(@as(u32, 3), deriveLocalBudget(64, 16));
    try std.testing.expectEqual(@as(u32, 1), deriveLocalBudget(64, 8)); // big RAM but few cores → still 1
}

/// One provider endpoint: an OpenAI-compatible base_url, its api key, and the model id.
pub const Provider = struct {
    base_url: []const u8 = "",
    key: []const u8 = "",
    model: []const u8 = "",
    /// "Set" only when it names a real endpoint AND model; a blank field means "inherit the coding/base
    /// provider" — the trio's fallback, and how a single-model client (which sends only the base triple)
    /// keeps every role on one model.
    pub fn isSet(p: Provider) bool {
        return p.base_url.len > 0 and p.model.len > 0;
    }
};

/// Which model a given LLM call runs on. The engine's labeled call sites map onto these: coding = the main
/// agentic build/answer stream ("chat"); thinking = planning, grounding and every context-housekeeping call
/// ("plan"/"recon"/"course"/"reflect"/"summary"/"ctxsum"/"compact"/"lesson"); prompting = the short VERDICT
/// calls that route the turn rather than reason through it ("loop"/"searchq"/"stuck"/"planrec"/"arbiter").
/// chat/trio_routing_test.zig is the authority on that table; this comment drifted behind it once already,
/// having claimed prompting served "loop" alone long after four more labels moved onto it.
///
/// A user can point each at a different model — a strong coder, a mid planner, a cheap driver. Doing so buys
/// more than cost control: it is the only way `independentReviewer` below can return anything at all.
pub const Role = enum { coding, thinking, prompting };

/// The three models one turn may run on. `coding` is the base/default triple every caller always sends;
/// `thinking`/`prompting` are optional overrides. An unset override falls back to `coding` (see pick), so a
/// single-model client — one that leaves the extra triples blank — behaves exactly as it did before the trio.
pub const ModelTrio = struct {
    coding: Provider = .{},
    thinking: Provider = .{},
    prompting: Provider = .{},

    /// The provider a role should use, resolving an unset thinking/prompting back to the coding base.
    pub fn pick(self: ModelTrio, role: Role) Provider {
        return switch (role) {
            .coding => self.coding,
            .thinking => if (self.thinking.isSet()) self.thinking else self.coding,
            .prompting => if (self.prompting.isSet()) self.prompting else self.coding,
        };
    }

    /// A provider that can REVIEW what the coding model produced — or null, meaning nobody here can.
    ///
    /// `pick` resolves an unset role back to `coding`, which is exactly right for getting work done and
    /// exactly wrong for review: it silently turns a critique into the author grading their own output.
    /// That is not a cheaper review, it is a more expensive nothing — a full prefill spent to receive
    /// confident agreement that carries no information, while looking from the outside like a second
    /// opinion was obtained. A reviewer that cannot disagree is not a reviewer.
    ///
    /// So review asks a different question than `pick` does, and answers with an honest null rather than
    /// a fallback. `prompting` is preferred because it is the lightest-loaded slot, which makes pointing
    /// it at a different model family the cheapest independence a user can buy.
    ///
    /// Independence is judged on the MODEL ID alone, not the endpoint. A mirror, a proxy, a second key or
    /// a different region serves the same weights, and the same weights agree with themselves just as
    /// readily however they were reached. Requiring both to match would have called a mirrored endpoint an
    /// independent reviewer — which is the exact failure this function exists to name.
    /// The provider AND the slot it came from. The role travels with it because the meter is keyed by role:
    /// moving a call to a different model while still booking it to the old one would make the per-label
    /// spend view lie, which is the defect ledger 0079/0092 already paid for once.
    pub const Reviewer = struct { provider: Provider, role: Role };

    pub fn independentReviewer(self: ModelTrio) ?Reviewer {
        const order = [_]Reviewer{
            .{ .provider = self.prompting, .role = .prompting },
            .{ .provider = self.thinking, .role = .thinking },
        };
        for (order) |cand| {
            if (!cand.provider.isSet()) continue;
            if (std.mem.eql(u8, cand.provider.model, self.coding.model)) continue;
            return cand;
        }
        return null;
    }
};

test "independentReviewer: a model never reviews itself, however the trio is wired" {
    const coder: Provider = .{ .base_url = "https://c/v1", .key = "kc", .model = "coder" };

    // The default single-model client. pick() hands every role back the coding model, so anything that
    // called itself a review here was the author agreeing with the author — at full prefill price, and
    // indistinguishable from a real second opinion at the call site. Say so instead.
    const solo: ModelTrio = .{ .coding = coder };
    try std.testing.expect(solo.independentReviewer() == null);
    // ...and the single-model default is UNTOUCHED by any of this. `pick` still answers for every role,
    // so a user running one model everywhere keeps exactly the behaviour they have today; the reviewer is
    // something the trio ADDS when it exists, never something its absence takes away.
    try std.testing.expectEqualStrings("coder", solo.pick(.thinking).model);
    try std.testing.expectEqualStrings("coder", solo.pick(.prompting).model);

    // The same model id at a different endpoint is NOT independence — a mirror, a proxy, a second key.
    const mirrored: ModelTrio = .{ .coding = coder, .prompting = .{ .base_url = "https://mirror/v1", .key = "k2", .model = "coder" } };
    try std.testing.expect(mirrored.independentReviewer() == null);
    try std.testing.expectEqualStrings("coder", mirrored.pick(.prompting).model); // still usable for work

    // prompting is preferred: it is the lightest-loaded slot, so it is the cheapest one to point at
    // another family purely to get a reviewer. The ROLE comes back with it so the meter stays honest.
    const both: ModelTrio = .{
        .coding = coder,
        .thinking = .{ .base_url = "https://t/v1", .key = "kt", .model = "planner" },
        .prompting = .{ .base_url = "https://p/v1", .key = "kp", .model = "driver" },
    };
    try std.testing.expectEqualStrings("driver", both.independentReviewer().?.provider.model);
    try std.testing.expectEqual(Role.prompting, both.independentReviewer().?.role);

    // ...but thinking still answers when prompting is unset, or is only a mirror of the coder.
    const think_only: ModelTrio = .{ .coding = coder, .thinking = .{ .base_url = "https://t/v1", .key = "kt", .model = "planner" } };
    try std.testing.expectEqualStrings("planner", think_only.independentReviewer().?.provider.model);
    try std.testing.expectEqual(Role.thinking, think_only.independentReviewer().?.role);
    const prompting_is_mirror: ModelTrio = .{
        .coding = coder,
        .thinking = .{ .base_url = "https://t/v1", .key = "kt", .model = "planner" },
        .prompting = .{ .base_url = "https://c/v1", .key = "kc", .model = "coder" },
    };
    try std.testing.expectEqualStrings("planner", prompting_is_mirror.independentReviewer().?.provider.model);

    // A half-configured slot is not a reviewer either — isSet() requires a real endpoint AND model.
    const half: ModelTrio = .{ .coding = coder, .prompting = .{ .base_url = "https://p/v1", .key = "kp" } };
    try std.testing.expect(half.independentReviewer() == null);
}

test "ModelTrio.pick: unset thinking/prompting fall back to coding; configured roles win" {
    const coding: Provider = .{ .base_url = "https://c/v1", .key = "kc", .model = "coder" };
    // both extras unset → every role resolves to coding (the single-model default / backward-compat)
    const solo: ModelTrio = .{ .coding = coding };
    try std.testing.expectEqualStrings("coder", solo.pick(.coding).model);
    try std.testing.expectEqualStrings("coder", solo.pick(.thinking).model);
    try std.testing.expectEqualStrings("coder", solo.pick(.prompting).model);
    // a role with base_url+model is used as-is; a role missing the model is NOT "set" → falls back to coding
    const trio: ModelTrio = .{
        .coding = coding,
        .thinking = .{ .base_url = "https://t/v1", .key = "kt", .model = "planner" },
        .prompting = .{ .base_url = "https://p/v1", .key = "kp", .model = "" }, // blank model ⇒ unset
    };
    try std.testing.expectEqualStrings("planner", trio.pick(.thinking).model);
    try std.testing.expectEqualStrings("https://t/v1", trio.pick(.thinking).base_url);
    try std.testing.expectEqualStrings("coder", trio.pick(.prompting).model); // blank model → fell back
    try std.testing.expect(!(Provider{ .base_url = "https://x/v1", .model = "" }).isSet());
    try std.testing.expect((Provider{ .base_url = "https://x/v1", .model = "m" }).isSet());
}

test "llm frame: the shared wire shape, parsed as a consumer would parse it" {
    const gpa = std.testing.allocator;

    // The SHARED EVENT CONTRACT, spelled out as a reader's struct. If a field is renamed, retyped, or dropped,
    // this fails to parse or fails an assert — which is the point: the desk and the web app read these names.
    const Frame = struct {
        kind: []const u8 = "",
        model: []const u8 = "",
        role: []const u8 = "",
        label: []const u8 = "",
        ms: i64 = -1,
        fb_ms: i64 = -1,
        /// OPTIONAL ON PURPOSE, mirroring the contract: an older server omits it, and a reader must be able to
        /// tell "the server didn't say" from "the server said false" even though it treats both as false.
        streamed: ?bool = null,
        in: i64 = -1,
        out: i64 = -1,
        ok: ?bool = null,
        ts: i64 = 0,
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try renderLlmFrame(gpa, &out, "chat", .coding, "kimi-k3", 18450, 1240, true, 92214, 1204, true, 1784165341);

    // events.jsonl is line-delimited JSON: emitEvent adds the newline, so the object itself must contain none.
    try std.testing.expect(std.mem.indexOfScalar(u8, out.items, '\n') == null);

    const p = try std.json.parseFromSlice(Frame, gpa, out.items, .{ .ignore_unknown_fields = false });
    defer p.deinit();
    const f = p.value;
    try std.testing.expectEqualStrings("llm", f.kind); // the NEW frame kind
    try std.testing.expectEqualStrings("kimi-k3", f.model);
    try std.testing.expectEqualStrings("coding", f.role);
    try std.testing.expectEqualStrings("chat", f.label);
    try std.testing.expectEqual(@as(i64, 18450), f.ms);
    try std.testing.expectEqual(@as(i64, 1240), f.fb_ms);
    try std.testing.expectEqual(@as(?bool, true), f.streamed); // the ONE streaming call: fb_ms is a real TTFB
    try std.testing.expectEqual(@as(i64, 92214), f.in);
    try std.testing.expectEqual(@as(i64, 1204), f.out);
    try std.testing.expectEqual(@as(?bool, true), f.ok);
    try std.testing.expectEqual(@as(i64, 1784165341), f.ts);

    // Every role tag reaches the wire under the name the contract gives it.
    for ([_]struct { r: Role, name: []const u8 }{
        .{ .r = .coding, .name = "coding" },
        .{ .r = .thinking, .name = "thinking" },
        .{ .r = .prompting, .name = "prompting" },
    }) |c| {
        var o2: std.ArrayListUnmanaged(u8) = .empty;
        defer o2.deinit(gpa);
        try renderLlmFrame(gpa, &o2, "plan", c.r, "m", 1, 1, false, 0, 0, true, 5);
        const p2 = try std.json.parseFromSlice(Frame, gpa, o2.items, .{});
        defer p2.deinit();
        try std.testing.expectEqualStrings(c.name, p2.value.role);
    }

    // FAILURES ARE EMITTED TOO, or the success rate read off the stream is 100% by construction. A failed call
    // returns no usage block, so its token counts are honestly zero rather than absent.
    var o3: std.ArrayListUnmanaged(u8) = .empty;
    defer o3.deinit(gpa);
    try renderLlmFrame(gpa, &o3, "searchq", .prompting, "cheap-driver", 900, 900, false, 0, 0, false, 42);
    const p3 = try std.json.parseFromSlice(Frame, gpa, o3.items, .{});
    defer p3.deinit();
    try std.testing.expectEqual(@as(?bool, false), p3.value.ok);
    try std.testing.expectEqual(@as(i64, 0), p3.value.in);
    try std.testing.expectEqual(@as(i64, 0), p3.value.out);
    // THE DEFECT THIS FIELD EXISTS FOR: a blocking call reports fb_ms == ms because there is no first byte to
    // time, and averaged blind that makes the thinking/prompting models look 1-2 orders of magnitude slower to
    // first byte than the streaming coder. The number stays (it is a true total); `streamed:false` is what tells
    // a consumer to keep it out of the first-byte average.
    try std.testing.expectEqual(@as(?bool, false), p3.value.streamed);
    try std.testing.expectEqual(p3.value.ms, p3.value.fb_ms);

    // A BYOK model id is arbitrary user text on this line. It must be escaped, not spliced: an unescaped quote
    // would end the string early and corrupt every reader of the whole file from that byte on.
    var o4: std.ArrayListUnmanaged(u8) = .empty;
    defer o4.deinit(gpa);
    try renderLlmFrame(gpa, &o4, "loop", .prompting, "we\"ird\\model\nname", 3, 3, false, 1, 2, true, 7);
    const p4 = try std.json.parseFromSlice(Frame, gpa, o4.items, .{});
    defer p4.deinit();
    try std.testing.expectEqualStrings("we\"ird\\model\nname", p4.value.model);
    try std.testing.expect(std.mem.indexOfScalar(u8, o4.items, '\n') == null); // the newline survived as \n

    // `streamed` is a BARE JSON boolean, not the string "true" — a consumer reading it with a bool parser (the
    // desk's jBool scans for `"streamed":` then `true`/`false`) must find one, and quoting it would break that
    // silently while still parsing as a Frame if the field were typed as a string.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"streamed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, o3.items, "\"streamed\":false") != null);

    // A PRE-CONTRACT FRAME (no `streamed`) must still parse, since that is exactly what an older server writes
    // into a log a newer consumer later reads. `null` there is the reader's "didn't say" — treated as false.
    const legacy = "{\"kind\":\"llm\",\"model\":\"m\",\"role\":\"thinking\",\"label\":\"plan\",\"ms\":900,\"fb_ms\":900,\"in\":1,\"out\":2,\"ok\":true,\"ts\":9}";
    const p5 = try std.json.parseFromSlice(Frame, gpa, legacy, .{ .ignore_unknown_fields = false });
    defer p5.deinit();
    try std.testing.expectEqual(@as(?bool, null), p5.value.streamed);
    try std.testing.expect(!(p5.value.streamed orelse false)); // the mandated safe reading
}

test "llm frame: `streamed` reports what the transport did, never what the call site hoped" {
    const t0: i64 = 1_700_000_000_000;
    const tok0: llm.TokUsage = .{ .in = 0, .out = 0 };

    // The nine BLOCKING call sites never touch fb_ms — false by construction, and fb_ms falls back to the total
    // so the number on the wire is still true, just not a first byte.
    const blocking = meterReport(.{ .t0_ms = t0, .tok0 = tok0 }, t0 + 4200);
    try std.testing.expect(!blocking.streamed);
    try std.testing.expectEqual(@as(u64, 4200), blocking.ms);
    try std.testing.expectEqual(@as(u64, 4200), blocking.fb_ms);

    // The ONE streaming site, with a delta actually observed: fb_ms is a real time-to-first-byte and well under
    // the total. This is the only shape a first-byte average may consume.
    const streamed = meterReport(.{ .t0_ms = t0, .tok0 = tok0, .fb_ms = t0 + 310 }, t0 + 4200);
    try std.testing.expect(streamed.streamed);
    try std.testing.expectEqual(@as(u64, 310), streamed.fb_ms);
    try std.testing.expectEqual(@as(u64, 4200), streamed.ms);

    // STREAMING THAT DIDN'T STREAM: llm.completeStream silently falls back to a blocking complete() on trouble,
    // and a reply with no deltas fires on_delta zero times. A hardcoded `true` at that call site would report a
    // first byte that was never observed; deriving from the meter reports false, which is the honest answer.
    const fell_back = meterReport(.{ .t0_ms = t0, .tok0 = tok0, .fb_ms = 0 }, t0 + 50);
    try std.testing.expect(!fell_back.streamed);
    try std.testing.expectEqual(@as(u64, 50), fell_back.fb_ms);

    // A CLOCK THAT WENT BACKWARDS (a wall-clock adjustment mid-call) must not underflow the unsigned wire
    // fields. A delta WAS seen here, so `streamed` stays true — the flag reports observation, not plausibility —
    // and both durations clamp to 0 rather than wrapping to ~18 quintillion ms.
    const backwards = meterReport(.{ .t0_ms = t0, .tok0 = tok0, .fb_ms = t0 - 5 }, t0 - 900);
    try std.testing.expect(backwards.streamed);
    try std.testing.expectEqual(@as(u64, 0), backwards.ms);
    try std.testing.expectEqual(@as(u64, 0), backwards.fb_ms);
}

test "llm frame: unarmed thread emits nothing, and a too-long conv_dir is refused rather than truncated" {
    // The emit target is thread-local (armed at runTurn entry). A recycled thread with no turn armed must not
    // append a frame to whatever conversation ran on it last — emitLlmFrame returns before touching the App,
    // which is also why passing an undefined *App here is safe.
    disarmLlmFrames();
    try std.testing.expectEqual(@as(usize, 0), llm_frame_dir_len);

    armLlmFrames("C:/data/u1/_chat/convs/c123");
    try std.testing.expectEqualStrings("C:/data/u1/_chat/convs/c123", llm_frame_dir[0..llm_frame_dir_len]);

    // A path longer than the buffer is DISARMED, never clipped: a truncated path names a different directory.
    const too_long = "x" ** (llm_frame_dir.len + 1);
    armLlmFrames(too_long);
    try std.testing.expectEqual(@as(usize, 0), llm_frame_dir_len);

    armLlmFrames("");
    try std.testing.expectEqual(@as(usize, 0), llm_frame_dir_len);
    disarmLlmFrames();
}

/// Copy `s` into `dst` at `off.*`, advance the offset, and return the copied sub-slice. The blob-packing
/// primitive spawnTurn uses to own every string arg in one allocation (the caller's arena dies at once).
fn dupInto(dst: []u8, off: *usize, s: []const u8) []const u8 {
    const r = dst[off.*..][0..s.len];
    @memcpy(r, s);
    off.* += s.len;
    return r;
}

/// Owned arguments for a background turn: one backing `blob` holds every string arg (the request arena that
/// spawnTurn was called from dies immediately), plus slices into it. turnThread frees the blob + the struct.
/// `trio` carries the three role models (coding/thinking/prompting), each Provider slicing into `blob`.
pub const TurnArgs = struct {
    app: *App,
    uid: u64,
    blob: []u8,
    conv: []const u8,
    trio: ModelTrio,
    text: []const u8,
    loop: u8,
    tool_client: bool,
    image_b64: []const u8,
    /// FAST MODE: this turn opted out of the advanced-reasoning passes (see the Body field in chat/service.zig).
    /// False = the default = advanced.
    fast: bool,
};

/// Detached-thread entry: run the whole turn, then free the owned args. Any failure inside runTurn is already
/// caught + surfaced as an event, so this thread returns cleanly (never propagates an error that could abort it).
fn turnThread(args: *TurnArgs) void {
    runTurn(args.app, args.uid, args.conv, args.trio, args.text, args.loop, args.tool_client, args.image_b64, args.fast);
    endTurn(args.app.io, args.conv); // release the per-conv turn lock (before freeing the blob `conv` points into)
    if (llm.isLocal(args.trio.coding.base_url)) releaseLocal(args.app.io); // release the machine-sized local slot (admission keys on the coding/base model)
    const gpa = args.app.gpa;
    gpa.free(args.blob);
    gpa.destroy(args);
}

/// Launch a turn for (uid, conv) on a DETACHED background thread with owned copies of every arg, so the HTTP
/// handler can return 202 at once and the client streams the turn's event frames live (a synchronous turn would
/// block the client's /events poll for the whole turn). On an
/// allocation or thread-spawn failure it runs the turn INLINE (blocking the caller) rather than drop it — the
/// caller's arg slices are still valid at that point. The turn writes its frames to events.jsonl either way.
pub fn spawnTurn(app: *App, uid: u64, conv: []const u8, trio: ModelTrio, text: []const u8, loop: u8, tool_client: bool, image_b64: []const u8, fast: bool) void {
    const gpa = app.gpa;
    const c = trio.coding;
    const t = trio.thinking;
    const p = trio.prompting;
    // Own every string in ONE allocation: conv + text + image_b64 + all three role triples (9 strings). `total`
    // is the exact sum of what dupInto copies below — the two MUST stay in lockstep (a short total → OOB slices).
    const total = conv.len + text.len + image_b64.len +
        c.base_url.len + c.key.len + c.model.len +
        t.base_url.len + t.key.len + t.model.len +
        p.base_url.len + p.key.len + p.model.len;
    // The caller (postMessage) already claimed the per-conv turn slot via tryBeginTurn; EVERY completion path here
    // must release it. The detached/inline turnThread paths release in turnThread; the two alloc-failure inline
    // paths run the turn directly, so they release explicitly. Local-slot release keys on the coding/base model.
    const args = gpa.create(TurnArgs) catch {
        runTurn(app, uid, conv, trio, text, loop, tool_client, image_b64, fast);
        endTurn(app.io, conv);
        if (llm.isLocal(c.base_url)) releaseLocal(app.io);
        return;
    };
    const blob = gpa.alloc(u8, total) catch {
        gpa.destroy(args);
        runTurn(app, uid, conv, trio, text, loop, tool_client, image_b64, fast);
        endTurn(app.io, conv);
        if (llm.isLocal(c.base_url)) releaseLocal(app.io);
        return;
    };
    var o: usize = 0;
    const cv = dupInto(blob, &o, conv);
    const tx = dupInto(blob, &o, text);
    const ib = dupInto(blob, &o, image_b64);
    // Re-slice every provider string into the owned blob (the passed-in slices die with the request arena).
    const owned: ModelTrio = .{
        .coding = .{ .base_url = dupInto(blob, &o, c.base_url), .key = dupInto(blob, &o, c.key), .model = dupInto(blob, &o, c.model) },
        .thinking = .{ .base_url = dupInto(blob, &o, t.base_url), .key = dupInto(blob, &o, t.key), .model = dupInto(blob, &o, t.model) },
        .prompting = .{ .base_url = dupInto(blob, &o, p.base_url), .key = dupInto(blob, &o, p.key), .model = dupInto(blob, &o, p.model) },
    };
    args.* = .{ .app = app, .uid = uid, .blob = blob, .conv = cv, .trio = owned, .text = tx, .loop = loop, .tool_client = tool_client, .image_b64 = ib, .fast = fast };
    if (std.Thread.spawn(.{}, turnThread, .{args})) |th| {
        th.detach();
    } else |_| {
        turnThread(args); // spawn failed → run inline (blocks) + free, rather than drop the turn
    }
}

/// One settled agentic tool pass: runs the tool-calling loop against the current `conv_buf` until the model emits
/// a NO-tool-call answer (that answer is `.settled`), a completion fails (`.hard_error` — the error event is
/// already emitted here), or a cooperative stop lands before an inference (`.stopped`). Grows `conv_buf` with the
/// assistant tool_call turns + tool-result turns (shared context for the outer drive). `.content` is gpa-owned;
/// the caller frees it in every outcome. Successful tool results are observed into `mem_scope` (confab-safe:
/// only tool findings + user turns are observed, never assistant replies).
const InnerResult = struct {
    outcome: enum { settled, hard_error, stopped },
    content: []u8,
    // (There used to be a `streamed` flag here, read by exactly one caller: the reflect gate, to refuse to
    // re-generate an answer the user had already watched type out. The critique that replaced reflect only ever
    // APPENDS, so whether the answer streamed no longer changes what may be done with it, and the flag had no
    // second reader. sctx.streamed still exists inside the pass, where it gates the non-streaming reasoning emit.)
    // Did ANY tool execute during this pass? A pure-prose answer with no tools on the first step is DONE — there's
    // no agentic work in flight to continue, so the drive loop's LOOP_QUESTION "are you done?" completion is pure
    // wasted latency (it delayed {done}/usage + the turn-lock release by a full round-trip on every simple Q&A).
    tools_ran: bool = false,
    /// The ENGINE's own account of why this pass ended (today: the loop-guard hard stop), kept STRICTLY apart
    /// from `content`. `content` is committed as the assistant's durable message, so an engine note folded into
    /// it is stored in the model's voice and replayed next turn as something the model itself said. That is the
    /// observed "are you stuck?" spiral: the user asks, the guard kills the turn, and a first-person "I stopped
    /// this turn…" confession lands in the transcript directly under the question — one more copy per killed
    /// turn, until the model is reading a wall of its own apparent admissions and can do nothing but ruminate on
    /// them. Routed to a `role:"system"` / `kind:"engine"` row instead. gpa-owned when non-empty; the caller
    /// frees it (a zero-length default is a safe no-op free).
    engine_note: []u8 = &[_]u8{},
};

/// Batch streamed deltas to ~this many chars per emitted frame. One frame per model TOKEN produces thousands of
/// frames per turn — each a file append + a desk poll-parse — which overwhelms the client. Coalescing cuts frames
/// while the reply still visibly types out; at 12 chars/frame (appendFile is an O(1) positioned append and the
/// desk polls its event stream at ~30Hz) the reply flows continuously rather than arriving in visible chunks.
const FLUSH_CHARS: usize = 12;

/// Carry + fence state for the watermark fold across a STREAM's chunk boundaries.
const WmState = struct {
    carry: [4]u8 = undefined, // an incomplete trailing UTF-8 sequence held for the next chunk
    carry_len: u8 = 0,
    ticks: u8 = 0, // consecutive '`' seen — three toggles the fence
    in_fence: bool = false,
};

/// Strip the TYPOGRAPHIC watermarks that make text read as machine-written — em/en dashes, curly quotes,
/// the ellipsis glyph, exotic spaces — and delete zero-width characters outright.
///
/// Byte-level and single-pass: a chunk costs microseconds while the inference that produced it cost seconds,
/// so this is free in practice. Three properties make it safe to run on every delta:
///   - CHUNK-SPLIT SAFE. An em dash is three bytes and WILL arrive split across two deltas. An incomplete
///     trailing sequence is held in `st.carry` and prepended to the next chunk; `final` flushes it as-is.
///   - FENCE AWARE. Inside a ``` block only the INVISIBLE characters are removed: a code sample's punctuation
///     is data, and rewriting it would corrupt what the user copies out.
///   - NEVER GROWS. Every mapping is same-length or shorter (ellipsis 3→3 is the max), so `out` need only be
///     src.len + 4 (the carry) and no allocation is ever needed.
/// Deliberately NOT applied to: tool arguments, file contents (mechanically editing a write_file payload is
/// the salvage-corruption class), or reasoning traces. This is about the REPLY the user reads.
fn wmFold(st: *WmState, out: []u8, src: []const u8, final: bool) usize {
    var w: usize = 0;
    var i: usize = 0;
    const carried = st.carry_len;
    st.carry_len = 0;
    while (i < @as(usize, carried) + src.len) {
        const b = if (i < carried) st.carry[i] else src[i - carried];
        if (b < 0x80) {
            st.ticks = if (b == '`') st.ticks + 1 else 0;
            if (st.ticks == 3) {
                st.in_fence = !st.in_fence;
                st.ticks = 0;
            }
            out[w] = b;
            w += 1;
            i += 1;
            continue;
        }
        st.ticks = 0;
        const len: usize = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const total = @as(usize, carried) + src.len;
        if (i + len > total) { // incomplete tail
            if (final) { // nothing more is coming — pass the bytes through untouched
                while (i < total) : (i += 1) {
                    out[w] = if (i < carried) st.carry[i] else src[i - carried];
                    w += 1;
                }
                break;
            }
            while (i < total) : (i += 1) { // hold for the next chunk
                st.carry[st.carry_len] = if (i < carried) st.carry[i] else src[i - carried];
                st.carry_len += 1;
            }
            break;
        }
        var seq: [4]u8 = undefined;
        var k: usize = 0;
        while (k < len) : (k += 1) seq[k] = if (i + k < carried) st.carry[i + k] else src[i + k - carried];
        const cp: u21 = std.unicode.utf8Decode(seq[0..len]) catch 0xFFFD;
        i += len;

        // zero-width / invisible: the actual data-carrying vector — removed EVERYWHERE, fences included
        switch (cp) {
            0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD => continue,
            else => {},
        }
        if (st.in_fence) { // visible punctuation inside code is data — copy verbatim
            @memcpy(out[w .. w + len], seq[0..len]);
            w += len;
            continue;
        }
        const rep: ?[]const u8 = switch (cp) {
            0x2012, 0x2013, 0x2014, 0x2015, 0x2212 => "-", // figure/en/em/horizontal-bar/minus
            0x2018, 0x2019, 0x201A, 0x201B => "'",
            0x201C, 0x201D, 0x201E, 0x201F => "\"",
            0x2026 => "...",
            0x00A0, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000 => " ",
            0x2022 => "-", // bullet glyph mid-prose (markdown lists use ASCII '-')
            0x00B7 => "-",
            else => null,
        };
        if (rep) |r| {
            @memcpy(out[w .. w + r.len], r);
            w += r.len;
        } else {
            @memcpy(out[w .. w + len], seq[0..len]);
            w += len;
        }
    }
    return w;
}

/// Whole-string convenience over wmFold: scrub `src` into a gpa-owned copy. Used at the SETTLED answer, so
/// what lands in the transcript, the .hist archive, and memory is clean too — not just the pixels.
fn wmScrubOwned(gpa: std.mem.Allocator, src: []const u8) ?[]u8 {
    const buf = gpa.alloc(u8, src.len + 4) catch return null;
    var st: WmState = .{};
    const n = wmFold(&st, buf, src, true);
    if (n == src.len and std.mem.eql(u8, buf[0..n], src)) { // nothing to change — don't churn the caller's slice
        gpa.free(buf);
        return null;
    }
    if (gpa.realloc(buf, n)) |shrunk| return shrunk else |_| return buf[0..n];
}

const StreamCtx = struct {
    app: *App,
    conv_dir: []const u8,
    wm: WmState = .{}, // watermark fold state for the CONTENT channel (carry + fence), see wmFold
    ctrl_cursor: usize = 0, // control.jsonl offset for the mid-stream abort check (chat Stop)
    streamed: bool = false,
    /// Wall-clock ms at which the FIRST delta of any kind landed, or 0 if nothing streamed. Feeds `fb_ms` on
    /// the call's `llm` frame: on the one streaming call of a turn, time-to-first-byte is measurable, and it is
    /// the number that separates "the provider is slow to start" from "the reply was simply long".
    fb_ms: i64 = 0,
    tok: [256]u8 = undefined,
    tok_len: usize = 0,
    rsn: [256]u8 = undefined,
    rsn_len: usize = 0,
};

/// The same Stop predicate, handed to blocking TOOLS (tools.Cancel).
///
/// Streaming has been interruptible mid-flight for a while; tools have not, and the gap shows worst exactly
/// where it hurts. `poll` is bounded at 180s and MEANT to be chained, so a long watch reaches the between-tool
/// check only every few minutes: the user presses Stop, nothing appears to happen, and the turn keeps its
/// thread. This lets a tool that blocks in a loop notice at its own sample boundaries instead.
const ToolStopCtx = struct { app: *App, conv_dir: []const u8, ctrl_cursor: usize };

fn toolShouldStop(cx: *anyopaque) tools.CancelReason {
    const tc: *ToolStopCtx = @ptrCast(@alignCast(cx));
    if (stopRequestedSince(tc.app, tc.conv_dir, tc.ctrl_cursor)) return .stopped;
    // A steer is just as much "stop sitting on the thread" as a stop is — the user is mid-watch and being
    // ignored. The difference is what happens after: this only makes the tool RETURN, and the turn's own
    // between-tools drain then folds the text in as a user message. Deliberately not consumed here, so
    // there is exactly one place that reads a steer and one place that persists it.
    if (steerPendingSince(tc.app, tc.conv_dir, tc.ctrl_cursor)) return .steered;
    return .none;
}

/// completeStream's cooperative-abort hook: fires (~every 40ms) during a streaming reply so a chat Stop kills the
/// in-flight generation promptly instead of waiting out the whole ~15s inference. Reads control.jsonl from the
/// turn's cursor for a `stop` op — the SAME predicate the between-tool / between-step checks use.
fn streamShouldAbort(cx: *anyopaque) bool {
    const sc: *StreamCtx = @ptrCast(@alignCast(cx));
    return stopRequestedSince(sc.app, sc.conv_dir, sc.ctrl_cursor);
}

/// llm.completeStream fires this per delta. We ACCUMULATE into a small buffer and emit a `{"kind":"token"|
/// "reasoning","delta":…}` frame only every ~FLUSH_CHARS (or when the buffer fills) — the reply still types out,
/// but at a sane frame rate. The chunk is borrowed (valid only during this call); scAccum copies it immediately.
fn streamOnDelta(cx: *anyopaque, kind: llm.DeltaKind, text: []const u8) void {
    if (text.len == 0) return;
    const sc: *StreamCtx = @ptrCast(@alignCast(cx));
    // First byte of ANY kind — a tool_progress delta is the provider having started generating just as much as
    // a content one, and on a step that composes a large tool call it is the only delta that ever arrives.
    if (sc.fb_ms == 0) sc.fb_ms = nowMillis(sc.app.io);
    if (kind == .tool_progress) {
        // Composing a big tool call emits NO content/reasoning deltas — surface what's being written as a live
        // status line ("writing index.html — 12 KB...") so the user isn't staring at a silent turn. Not part of
        // the reply: don't set `streamed` (a call-only step must still fall back to emitting its reasoning once).
        // FLUSH FIRST: a status frame must never interleave inside an unflushed delta run — the desk treats a
        // delta that follows a non-delta frame as an inference boundary (its glue-seam heuristic) and would
        // stitch a paragraph break into the middle of a healthy sentence.
        streamFlush(sc);
        emitKV(sc.app, sc.conv_dir, "status", "text", text);
        return;
    }
    sc.streamed = true; // a real stream happened — so the fallback reasoning emit is skipped
    if (kind == .reasoning) {
        scAccum(sc, true, text);
        return;
    }
    // WATERMARK FOLD on the content channel, at the streaming edge: the user must never SEE an em dash type
    // itself out and then get silently rewritten at commit. Stack-buffered (never grows — see wmFold) and
    // stateful across chunks, so a sequence split between two deltas still folds correctly.
    var wb: [1024 + 4]u8 = undefined;
    var off: usize = 0;
    while (off < text.len) {
        const take = @min(text.len - off, 1024);
        const n = wmFold(&sc.wm, &wb, text[off .. off + take], false);
        if (n > 0) scAccum(sc, false, wb[0..n]);
        off += take;
    }
}

fn scAccum(sc: *StreamCtx, is_reason: bool, text: []const u8) void {
    // CHANNEL-SWITCH FLUSH: emit the OTHER channel's buffered residue before accumulating this kind, so
    // frames always land in true stream order. Without this, up to FLUSH_CHARS-1 bytes of thinking residue
    // held since the reasoning→content switch were emitted AFTER the entire reply (a stale trailing
    // "reasoning" frame) — which the desk's inference-seam heuristic read as a new inference and stitched a
    // paragraph break into the middle of a healthy thought.
    if (is_reason) {
        if (sc.tok_len > 0) {
            emitKV(sc.app, sc.conv_dir, "token", "delta", sc.tok[0..sc.tok_len]);
            sc.tok_len = 0;
        }
    } else if (sc.rsn_len > 0) {
        emitKV(sc.app, sc.conv_dir, "reasoning", "delta", sc.rsn[0..sc.rsn_len]);
        sc.rsn_len = 0;
    }
    const buf: []u8 = if (is_reason) &sc.rsn else &sc.tok;
    const len: *usize = if (is_reason) &sc.rsn_len else &sc.tok_len;
    const kind: []const u8 = if (is_reason) "reasoning" else "token";
    var rest = text;
    while (rest.len > 0) {
        const n = @min(rest.len, buf.len - len.*);
        @memcpy(buf[len.*..][0..n], rest[0..n]);
        len.* += n;
        rest = rest[n..];
        const buffer_full = (len.* == buf.len);
        if (len.* >= FLUSH_CHARS or buffer_full) {
            // Deltas arrive as WHOLE codepoints (whole JSON strings, split on \n which never bisects a codepoint),
            // so a FLUSH_CHARS-threshold flush always lands on a boundary. The ONE place a multibyte char can be
            // split is the buffer-full clamp when a single delta overflows the 256-byte buffer — emitting a frame
            // ending in a truncated lead byte (invalid UTF-8, which a strict JSON reader of events.jsonl rejects).
            // Back off to the last complete UTF-8 boundary and keep the trailing partial bytes for the next chunk.
            var emit_len = len.*;
            if (buffer_full) {
                const cut = utf8SafeCut(buf[0..len.*]);
                if (cut > 0) emit_len = cut; // cut==0 ⇒ a >256-byte "codepoint" (never happens); emit as-is, don't stall
            }
            emitKV(sc.app, sc.conv_dir, kind, "delta", buf[0..emit_len]);
            const carry = len.* - emit_len;
            if (carry > 0) std.mem.copyForwards(u8, buf[0..carry], buf[emit_len..len.*]);
            len.* = carry;
        }
    }
}

/// Largest prefix of `b` that ends on a UTF-8 codepoint boundary (i.e. contains no trailing partial codepoint).
/// Returns b.len when the last codepoint is already complete. Used to avoid splitting a multibyte char across two
/// streamed frames when the fixed accumulation buffer fills mid-codepoint.
fn utf8SafeCut(b: []const u8) usize {
    if (b.len == 0) return 0;
    var i: usize = b.len;
    while (i > 0) { // walk back past continuation bytes (0b10xxxxxx) to the lead byte of the last codepoint
        i -= 1;
        if (b[i] & 0xC0 != 0x80) break;
    }
    const lead = b[i];
    const need: usize = if (lead < 0x80) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else 1;
    return if (i + need <= b.len) b.len else i; // last codepoint complete → keep all; else cut before it
}

/// Emit any buffered tail deltas — called after completeStream returns so the last partial chunk isn't lost.
fn streamFlush(sc: *StreamCtx) void {
    if (sc.tok_len > 0) {
        emitKV(sc.app, sc.conv_dir, "token", "delta", sc.tok[0..sc.tok_len]);
        sc.tok_len = 0;
    }
    if (sc.rsn_len > 0) {
        emitKV(sc.app, sc.conv_dir, "reasoning", "delta", sc.rsn[0..sc.rsn_len]);
        sc.rsn_len = 0;
    }
}
// ------------------------------------------------------------------------------------ veil PLAN-BOARD (Phase A+)

/// Slice out the outermost {...} JSON object from a model reply (which may wrap it in prose or ``` fences).
fn extractJsonObject(s: []const u8) []const u8 {
    const a = std.mem.indexOfScalar(u8, s, '{') orelse return s;
    const b = std.mem.lastIndexOfScalar(u8, s, '}') orelse return s;
    if (b > a) return s[a .. b + 1];
    return s;
}

/// Cheap, inference-free pre-gate: does THIS message warrant a plan-decomposition round-trip? The plan-board is
/// for genuine multi-step BUILD/RESEARCH jobs — the veil breaking a real task into routed subtasks and steering a
/// swarm. A question, a greeting, an ack, or a one-line ask must NOT pay a sequential decomposition inference
/// (it dominated time-to-first-token) nor risk a weak model over-decomposing "hi" into a swarm plan. Bias HARD
/// toward NOT planning: only a clear build/research intent verb (with enough length to be a real task) plans;
/// everything else answers directly and fast. A message that IS a task phrased without a marker still gets worked
/// by the drive loop — it just isn't pre-decomposed into a persisted board, which is the safe direction to err.
fn shouldPlan(user_text: []const u8) bool {
    const t = std.mem.trim(u8, user_text, " \r\n\t");
    if (t.len < 24) return false; // greetings, acks, short questions — never a multi-step task
    var buf: [192]u8 = undefined;
    const n = @min(t.len, buf.len);
    for (t[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    // UNAMBIGUOUS multi-step markers — checked BEFORE the question guard so a task phrased with a leading verb like
    // "do a deep dive …" or "audit the engine and categorize …" still plans (these almost never occur in plain Q&A).
    const strong_markers = [_][]const u8{ "audit ", "deep dive", "deep-dive", "step by step", "step-by-step", "from scratch", "end to end", "end-to-end" };
    for (strong_markers) |m| if (std.mem.indexOf(u8, low, m) != null) return true;
    // A clear question / explanation / lookup opener → answer directly, never plan (even if a build verb like
    // "write" appears later, as in "write 200 words explaining X" — that's Q&A, not a build).
    const q_openers = [_][]const u8{
        "what ",  "what's", "whats ",  "why ",    "how ",    "how's",    "hows ",  "when ",  "who ",    "where ",       "which ",
        "whose ", "is ",    "are ",    "am ",     "was ",    "were ",    "do ",    "does ",  "did ",    "can you tell", "could you tell",
        "will ",  "would ", "should ", "explain", "tell me", "describe", "summar", "define", "what is", "what are",
    };
    for (q_openers) |q| if (std.mem.startsWith(u8, low, q)) return false;
    // Strong multi-step build / research task intent anywhere → plan + coordinate.
    const task_markers = [_][]const u8{
        "build ",    "create ",    "implement ", "develop ",     "scaffold",     "set up a",     "set up the", "make me a",
        "make a ",   "write me a", "write a ",   "write the ",   "code me",      "refactor ",    "migrate ",   "port the",
        "port it",   "deploy ",    "generate a", "research ",    "investigate ", "analyze ",     "gather ",    "scrape ",
        "crawl ",    "design a",   "design and", "from scratch", "step by step", "step-by-step", "and then ",  "an app",
        "a website", "a web app",  "a cli",      "a rest api",   "a full ",      "end to end",   "end-to-end",
    };
    for (task_markers) |m| if (std.mem.indexOf(u8, low, m) != null) return true;
    return false; // ambiguous / conversational → fast direct answer (no decomposition round-trip)
}

/// RECON pass (see RECON_SYSTEM): ask what needs finding out, run those read-only probes, and return a bounded
/// evidence block for the planner — or null when the model wanted nothing (the designed answer for a
/// self-contained request). gpa-owned.
///
/// The whitelist check is the load-bearing line. `tools.execute` is the full tool surface, so a probe list
/// taken at face value would let a PLANNING pass write files and run code before the user has seen a plan.
///
/// KNOWN LIMIT: probes run SERVER-side (tools.execute) even on a client-delegated turn, which the main loop
/// would route through delegateTool. For the desk that is the same machine and the same workdir, so
/// list_dir/read_file answer identically; for a hosted server with a remote client they would describe the
/// server's tree, not the user's. Delegating recon would put a client round trip ahead of time-to-first-token
/// on every planned turn — deliberately not paid until a remote-client case actually needs it.
fn reconFindings(app: *App, run_root: []const u8, p: Provider, ctx: *tools.ToolCtx, user_text: []const u8, ground: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, RECON_SYSTEM) catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    var uc: std.ArrayListUnmanaged(u8) = .empty;
    defer uc.deinit(gpa);
    uc.appendSlice(gpa, "USER REQUEST:\n") catch return null;
    uc.appendSlice(gpa, clipBytes(user_text, 6000)) catch return null;
    if (ground.len > 0) {
        uc.appendSlice(gpa, "\n\n") catch return null;
        uc.appendSlice(gpa, ground) catch return null;
    }
    uc.appendSlice(gpa, "\n\n") catch return null;
    uc.appendSlice(gpa, RECON_QUESTION) catch return null;
    http.jstr(gpa, &msgs, uc.items) catch return null;
    msgs.append(gpa, '}') catch return null;

    const cm = meterBegin(app.io);
    var step = llm.complete(gpa, app.io, run_root, "recon", p.base_url, p.key, p.model, msgs.items, "", 512, 0.2);
    defer step.deinit(gpa);
    meterEnd(app, cm, "recon", .thinking, p.model, step.ok);
    if (!step.ok) return null;

    const obj = extractJsonObject(step.content);
    const P = struct {
        probes: []const struct {
            tool: []const u8 = "",
            args: std.json.Value = .null,
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(P, gpa, obj, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.probes.len == 0) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var ran: usize = 0;
    for (parsed.value.probes) |pr| {
        if (ran >= RECON_MAX_PROBES or out.items.len > RECON_BLOCK_MAX) break;
        var allowed = false;
        for (RECON_TOOLS) |t| {
            if (std.mem.eql(u8, t, pr.tool)) {
                allowed = true;
                break;
            }
        }
        // Silently dropped, not failed: a model naming write_file here is a formatting miss, and the recon
        // pass degrading to fewer probes is strictly better than aborting a turn over it. The whitelist is
        // the security property; that it is enforced at all is what matters, not that anyone is told.
        if (!allowed) continue;
        const args = std.json.Stringify.valueAlloc(gpa, pr.args, .{}) catch continue;
        defer gpa.free(args);
        const res = tools.execute(ctx, pr.tool, if (std.mem.eql(u8, args, "null")) "{}" else args);
        defer gpa.free(res);
        if (ran == 0) out.appendSlice(gpa, "\n\nWHAT YOU FOUND WHEN YOU LOOKED (evidence — plan from THIS, not from assumption):") catch break;
        const seg = std.fmt.allocPrint(gpa, "\n\n$ {s} {s}\n{s}", .{ pr.tool, clipBytes(args, 200), clipBytes(res, 1200) }) catch break;
        defer gpa.free(seg);
        out.appendSlice(gpa, seg) catch break;
        ran += 1;
    }
    if (ran == 0) {
        out.deinit(gpa);
        return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// MID-TURN COURSE CHECK (see COURSE_SYSTEM). Returns a replacement instruction when the next step is going
/// the wrong way, or null to let it proceed — null being the overwhelmingly common answer. gpa-owned.
///
/// It never sees the tools and never runs one: this is a judgement about direction, and a reviewer that could
/// act would just become a second worker racing the first.
fn courseCheck(app: *App, run_root: []const u8, p: Provider, role: Role, goal: []const u8, brief: *const cplan.Brief, next_step: []const u8, conv_items: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, COURSE_SYSTEM) catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"system\",\"content\":") catch return null;

    // The goal and the acceptance contract, so "drifted off the goal" is checkable rather than a vibe.
    var gl: std.ArrayListUnmanaged(u8) = .empty;
    defer gl.deinit(gpa);
    gl.appendSlice(gpa, "THE GOAL: ") catch return null;
    gl.appendSlice(gpa, clipBytes(goal, 1400)) catch return null;
    if (!brief.isEmpty()) {
        gl.appendSlice(gpa, "\nDONE MEANS:") catch return null;
        for (brief.done_when) |c| {
            if (gl.items.len > 2600) break;
            gl.appendSlice(gpa, "\n- ") catch break;
            gl.appendSlice(gpa, clipBytes(c, 300)) catch break;
        }
    }
    http.jstr(gpa, &msgs, gl.items) catch return null;
    msgs.appendSlice(gpa, "},") catch return null;
    msgs.appendSlice(gpa, msgTail(conv_items, LOOP_CTX_BYTES)) catch return null;
    msgs.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch return null;
    var q: std.ArrayListUnmanaged(u8) = .empty;
    defer q.deinit(gpa);
    q.appendSlice(gpa, COURSE_QUESTION_HEAD) catch return null;
    q.appendSlice(gpa, clipBytes(next_step, 1200)) catch return null;
    q.appendSlice(gpa, COURSE_QUESTION_TAIL) catch return null;
    http.jstr(gpa, &msgs, q.items) catch return null;
    msgs.append(gpa, '}') catch return null;

    const cm = meterBegin(app.io);
    var step = completeAux(app, run_root, "course", p.base_url, p.key, p.model, msgs.items, 384, 0.2);
    defer step.deinit(gpa);
    meterEnd(app, cm, "course", role, p.model, step.ok);
    if (!step.ok) return null;

    const verdict = courseVerdict(step.content) orelse return null;
    return gpa.dupe(u8, verdict) catch null;
}

/// Does this reviewer reply actually redirect the loop? Pure, so the ABSTAIN DISCIPLINE is testable without a
/// model — and it is the property worth pinning: every ambiguous reply must read as silence, because the cost
/// of a false correction (a working loop dragged sideways) is paid on every step, while the cost of a missed
/// one is just the status quo. Returns a slice INTO `content`, or null for "let the step proceed".
fn courseVerdict(content: []const u8) ?[]const u8 {
    // DECORATION only — quotes, backticks, asterisks, whitespace. Sentence punctuation is deliberately NOT
    // trimmed here: a correction is handed to the worker verbatim as its next instruction, and silently
    // eating the final period is the sort of quiet mangling that turns a reviewed sentence into a truncated
    // one. The abstain check below does its own stricter trim instead.
    const t = std.mem.trim(u8, content, " \r\n\t`*\"'");
    // Abstain, in every shape a model writes it: "OK", "ok.", "OK!".
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " .!"), COURSE_ABSTAIN)) return null;
    // Too short to name a concrete thing to do instead — the vague nudge ("try something else"), which is
    // worse than silence because it swaps a specific next step for an unspecific one.
    if (t.len < COURSE_MIN) return null;
    // A HEDGED abstain — "OK, but you could also…" — is silence too. The reviewer was asked for exactly OK or
    // exactly a correction; a reply that opens by approving the step has approved it, and letting the trailing
    // suggestion through is how a loop gets nudged off a working path by a reviewer that had no objection.
    if (t.len > COURSE_ABSTAIN.len and std.ascii.startsWithIgnoreCase(t, COURSE_ABSTAIN)) {
        const after = t[COURSE_ABSTAIN.len];
        if (after == ',' or after == ' ' or after == '-' or after == ';' or after == ':') return null;
    }
    if (cctx.looksLikeToolMarkup(t)) return null; // a reviewer that tried to ACT — discard, never execute
    return t;
}

/// DECOMPOSITION inference: ask the model to break the request into routed subtasks. Returns owned tasks (empty =
/// no plan needed → a normal single-step turn) and fills `out_brief` with the turn's acceptance contract (empty
/// when the model omitted it). No tools; deterministic (low temp). Any failure → empty tasks + empty brief.
///
/// `evidence` is what recon actually saw (empty when it looked at nothing). It goes in BEFORE the instruction
/// so the decomposition is written against the real project rather than an imagined one — the whole point of
/// the recon rung above.
fn planTask(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, user_text: []const u8, evidence: []const u8, out_brief: *cplan.Brief) []cplan.Task {
    const gpa = app.gpa;
    const empty: []cplan.Task = &.{};
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return empty;
    http.jstr(gpa, &msgs, "You are veil. Plan how to tackle the user's request by decomposing it into routed subtasks.") catch return empty;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return empty;
    var uc: std.ArrayListUnmanaged(u8) = .empty;
    defer uc.deinit(gpa);
    uc.appendSlice(gpa, "USER REQUEST:\n") catch return empty;
    uc.appendSlice(gpa, clipBytes(user_text, 8000)) catch return empty;
    if (evidence.len > 0) uc.appendSlice(gpa, clipBytes(evidence, RECON_BLOCK_MAX)) catch return empty;
    uc.appendSlice(gpa, "\n\n") catch return empty;
    uc.appendSlice(gpa, PLAN_PROMPT) catch return empty;
    http.jstr(gpa, &msgs, uc.items) catch return empty;
    msgs.append(gpa, '}') catch return empty;
    // The contract costs OUTPUT tokens the old 1024 budget did not allow for — and this pass is sequential ahead
    // of time-to-first-token, so on a slow host the contract is paid in seconds of latency, not just tokens. The
    // cap is a ceiling, not a target (the model stops at the closing brace); it is raised only so a long plan
    // can't get truncated mid-JSON, which extractJsonObject would hand to the parser as an unbalanced object and
    // the whole board would come back empty.
    const plan_cm = meterBegin(app.io);
    var step = llm.complete(gpa, app.io, run_root, "plan", base_url, key, model, msgs.items, "", 1536, 0.3);
    defer step.deinit(gpa);
    meterEnd(app, plan_cm, "plan", .thinking, model, step.ok);
    if (!step.ok) return empty;
    const obj = extractJsonObject(step.content);
    const tasks = cplan.parseDecomposition(gpa, obj);
    // Only adopt a brief that came with a REAL board: a brief without tasks has no turn to govern, and the caller
    // would otherwise inject an acceptance contract for a plan it decided not to run.
    if (tasks.len > 0) out_brief.* = cplan.parseBrief(gpa, obj);
    return tasks;
}

/// EARN TOOL PREFERENCE across sessions: at turn exit, reward each tool's `tool:<name>` trust class by
/// its OUTCOME rate this turn. A tool whose outcomes were mostly good nudges its class UP; mostly bad,
/// DOWN — so a tool that keeps failing at a job (run_python for file work) slowly loses standing while a
/// tool that keeps succeeding gains it, learned from real outcomes rather than prompted. trustReward
/// takes ONE delta per class list, so this issues at most two calls (the good batch, the bad batch).
/// No-op when the neuron binary lacks the trust verb (trustReward fail-safes). Engine-driven only.
fn rewardToolTrust(ctx: *tools.ToolCtx, mem_scope: []const u8, acc: *const toolperf.Acc) void {
    _ = mem_scope; // the trust ledger is ONE global ledger per DB (not scope-keyed); ctx.mem is that DB
    const gpa = ctx.gpa;
    var good: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (good.items) |c| gpa.free(c);
        good.deinit(gpa);
    }
    var bad: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (bad.items) |c| gpa.free(c);
        bad.deinit(gpa);
    }
    for (acc.slice()) |*r| {
        if (r.calls == 0) continue;
        const bad_rate: f32 = @as(f32, @floatFromInt(r.bad)) / @as(f32, @floatFromInt(r.calls));
        const cls = std.fmt.allocPrint(gpa, "tool:{s}", .{r.nameStr()}) catch continue;
        // majority-good → reward; majority-bad → penalize; a 50/50 tool stays put (no class minted)
        if (bad_rate <= 0.34) {
            good.append(gpa, cls) catch gpa.free(cls);
        } else if (bad_rate >= 0.66) {
            bad.append(gpa, cls) catch gpa.free(cls);
        } else gpa.free(cls);
    }
    // small deltas: many turns of consistent behavior move a class, one bad turn barely does — the floor
    // is a slow learner by design (matching neuron-db's outcome-reinforcement contract).
    if (good.items.len > 0) ctx.mem.trustReward(0.10, good.items);
    if (bad.items.len > 0) ctx.mem.trustReward(-0.10, bad.items);
}

/// The trust half of the belt line: the neuron-db floor's earned per-tool preference, as a short
/// "earned: write_file↑ run_python↓" clause the belt appends. Reads the whole ledger in ONE spawn and
/// names only tool: classes that have moved meaningfully from neutral (1.0). "" when the floor is off /
/// empty / near-neutral — the belt then shows session stats alone. Turn-stable → built once in the prefix.
fn trustBeltLine(app: *App, mem_scope: []const u8) []u8 {
    const gpa = app.gpa;
    // reach the same trust DB the chat Mem uses (mem_scope "chat:<conv>" → the conv's hive.sqlite is the
    // engine's; the trust ledger is global-per-DB). Reuse the ctx-built handle path via a throwaway Mem.
    _ = mem_scope;
    var db_pb: [700]u8 = undefined;
    const db = std.fmt.bufPrint(&db_pb, "{s}/hive.sqlite", .{app.data}) catch return &.{};
    var m = osc.Mem.init(gpa, app.io, app.sup.neuron_bin, db);
    m.trust = true;
    const dump = m.trustDump();
    defer gpa.free(dump);
    if (dump.len == 0) return &.{};
    var up: std.ArrayListUnmanaged(u8) = .empty;
    defer up.deinit(gpa);
    var down: std.ArrayListUnmanaged(u8) = .empty;
    defer down.deinit(gpa);
    var it = std.mem.splitScalar(u8, dump, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\t");
        if (!std.mem.startsWith(u8, t, "tool:")) continue;
        var f = std.mem.splitScalar(u8, t, '\t');
        const cls = f.next() orelse continue;
        const wstr = f.next() orelse continue;
        const w = std.fmt.parseFloat(f32, wstr) catch continue;
        const nm = cls["tool:".len..];
        if (w >= 1.08) {
            if (up.items.len > 0) up.append(gpa, ' ') catch {};
            up.appendSlice(gpa, nm) catch {};
        } else if (w <= 0.92) {
            if (down.items.len > 0) down.append(gpa, ' ') catch {};
            down.appendSlice(gpa, nm) catch {};
        }
    }
    if (up.items.len == 0 and down.items.len == 0) return &.{};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "Earned on this machine —") catch return &.{};
    if (up.items.len > 0) out.print(gpa, " reliable: {s};", .{up.items}) catch {};
    if (down.items.len > 0) out.print(gpa, " has been unreliable: {s};", .{down.items}) catch {};
    return gpa.dupe(u8, out.items) catch &.{};
}

/// SETTLE-TIME PLAN RECONCILE — the board must move at the pace of the WORK, not the pace of the loop.
/// One drive step often completes more than its own subtask: the inner agentic pass keeps running tools
/// until it settles, and a capable model finishes half the board inside subtask 1 (observed live: "plan
/// 0/4" through an entire build, then a burst of ticks at the end). After each settled step, the cheap
/// prompting model judges which REMAINING tasks are ALREADY complete — against the FILE LEDGER (engine
/// ground truth), not the narration alone — and those advance too, so the desk's ~1Hz plan poll shows
/// real progress at every settle. Best-effort: any failure or a "done: none" changes nothing.
fn planReconcile(app: *App, llm_dir: []const u8, conv_dir: []const u8, trio: ModelTrio, plan: []cplan.Task, ledger: *const FileLedger, answer: []const u8) void {
    const gpa = app.gpa;
    var pending_n: usize = 0;
    for (plan) |t| {
        if (std.mem.eql(u8, t.status, cplan.STATUS_PENDING)) pending_n += 1;
    }
    if (pending_n == 0) return;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"user\",\"content\":") catch return;
    var q: std.ArrayListUnmanaged(u8) = .empty;
    defer q.deinit(gpa);
    q.appendSlice(gpa, "A work step just finished. Judge which of the REMAINING plan tasks are ALREADY fully complete, using the evidence below. Count a task complete only when the EVIDENCE (files in the ledger, verified outcomes in the step result) shows it — a stated intention is not completion.\n\nREMAINING TASKS:\n") catch return;
    for (plan, 1..) |t, i| {
        if (!std.mem.eql(u8, t.status, cplan.STATUS_PENDING)) continue;
        q.print(gpa, "{d}. {s}", .{ i, clipBytes(t.text, 200) }) catch return;
        if (t.done_when.len > 0) q.print(gpa, " (done when: {s})", .{clipBytes(t.done_when, 160)}) catch return;
        q.append(gpa, '\n') catch return;
    }
    q.appendSlice(gpa, "\nENGINE FILE LEDGER (ground truth of what exists on disk):\n") catch return;
    ledgerBlock(gpa, ledger, &q);
    q.appendSlice(gpa, "\nTHE STEP'S SETTLED RESULT:\n") catch return;
    q.appendSlice(gpa, clipBytes(answer, 700)) catch return;
    q.appendSlice(gpa, "\n\nAnswer with ONLY one line: 'done: <comma-separated task numbers>' or 'done: none'.") catch return;
    http.jstr(gpa, &msgs, q.items) catch return;
    msgs.append(gpa, '}') catch return;
    const pr = trio.pick(.prompting);
    const cm = meterBegin(app.io);
    var step = llm.complete(gpa, app.io, llm_dir, "planrec", pr.base_url, pr.key, pr.model, msgs.items, "", 96, 0.0);
    defer step.deinit(gpa);
    meterEnd(app, cm, "planrec", .prompting, pr.model, step.ok);
    if (!step.ok or step.content.len == 0) return;
    var idx_buf: [32]usize = undefined;
    var advanced: usize = 0;
    for (parseDoneList(step.content, plan.len, &idx_buf)) |n| {
        if (!std.mem.eql(u8, plan[n - 1].status, cplan.STATUS_PENDING)) continue;
        cplan.setStatus(gpa, &plan[n - 1], cplan.STATUS_DONE);
        advanced += 1;
    }
    if (advanced > 0) {
        var nb: [96]u8 = undefined;
        emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&nb, "plan reconciled — {d} more subtask(s) were already complete", .{advanced}) catch "plan reconciled");
    }
}

/// The brief lives beside plan.jsonl so a "continue" turn resumes under the SAME acceptance contract the work was
/// planned against — the plan board survives across turns, and a contract that didn't would leave the resumed half
/// of the job judged by nothing.
fn resumeBrief(app: *App, conv_dir: []const u8) cplan.Brief {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/brief.json", .{conv_dir}) catch return .{};
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(64 << 10)) catch return .{};
    defer gpa.free(data);
    return cplan.parseBrief(gpa, data);
}

fn persistBrief(app: *App, conv_dir: []const u8, brief: cplan.Brief) void {
    const gpa = app.gpa;
    const body = cplan.formatBrief(gpa, brief) catch return;
    defer gpa.free(body);
    const path = std.fmt.allocPrint(gpa, "{s}/brief.json", .{conv_dir}) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = body }) catch {};
}

/// Render the brief as the TURN BRIEF system message. Bounded: MAX_BRIEF_ITEMS lines per list on the parse side,
/// BRIEF_MAX_BYTES here — it rides in every inference of the turn, so it must be small and it must be capped by
/// the engine rather than by the planner's restraint.
const BRIEF_MAX_BYTES: usize = 1200;
fn renderBrief(gpa: std.mem.Allocator, brief: cplan.Brief, out: *std.ArrayListUnmanaged(u8)) void {
    out.appendSlice(gpa, "TURN BRIEF — the acceptance contract for this turn, written by the planning pass before any work started. It is the definition of DONE for everything below: do not declare the task complete while any condition is unmet, and say which one is unmet if you stop short.\n") catch return;
    if (brief.objective.len > 0) {
        out.appendSlice(gpa, "OBJECTIVE: ") catch return;
        out.appendSlice(gpa, clipBytes(brief.objective, 400)) catch return;
        out.append(gpa, '\n') catch return;
    }
    if (brief.done_when.len > 0) {
        out.appendSlice(gpa, "DONE WHEN (each must be checkable, and checked):\n") catch return;
        for (brief.done_when) |c| {
            out.appendSlice(gpa, "- ") catch return;
            out.appendSlice(gpa, clipBytes(c, 300)) catch return;
            out.append(gpa, '\n') catch return;
        }
    }
    if (brief.watch_for.len > 0) {
        out.appendSlice(gpa, "WATCH FOR (failure modes anticipated for this task):\n") catch return;
        for (brief.watch_for) |c| {
            out.appendSlice(gpa, "- ") catch return;
            out.appendSlice(gpa, clipBytes(c, 300)) catch return;
            out.append(gpa, '\n') catch return;
        }
    }
}

/// Read the persisted plan.jsonl back into a task list (for resuming a plan across turns). Empty if absent.
fn resumePlan(app: *App, conv_dir: []const u8) []cplan.Task {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/plan.jsonl", .{conv_dir}) catch return &.{};
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(256 << 10)) catch return &.{};
    defer gpa.free(data);
    return cplan.parsePlan(gpa, data);
}

/// Write the current plan state to plan.jsonl (full overwrite — it's the live board, not an append log).
fn persistPlan(app: *App, conv_dir: []const u8, plan: []const cplan.Task) void {
    const gpa = app.gpa;
    const body = cplan.formatPlan(gpa, plan) catch return;
    defer gpa.free(body);
    const path = std.fmt.allocPrint(gpa, "{s}/plan.jsonl", .{conv_dir}) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = body }) catch {};
}

/// Commit a readable rendering of the plan as an assistant message — durable + visible in chat + in the model's
/// own context so it knows its plan. Marks each task with its route and (on a resume) its status.
fn emitPlanMessage(app: *App, conv_dir: []const u8, plan: []const cplan.Task) void {
    const gpa = app.gpa;
    var m: std.ArrayListUnmanaged(u8) = .empty;
    defer m.deinit(gpa);
    m.appendSlice(gpa, "Here's my plan:\n") catch return;
    for (plan, 0..) |t, i| {
        const mark = if (std.mem.eql(u8, t.status, cplan.STATUS_DONE)) "[x] " else "[ ] ";
        const line = std.fmt.allocPrint(gpa, "{d}. {s}({s}) {s}\n", .{ i + 1, mark, t.route, t.text }) catch return;
        defer gpa.free(line);
        m.appendSlice(gpa, line) catch return;
    }
    appendMsg(app, conv_dir, "assistant", m.items, "veil", nowSecs(app.io));
    emitAssistant(app, conv_dir, m.items);
}

/// The instruction injected as the working turn for one subtask — the subtask text + a route-specific nudge +
/// the subtask's own acceptance condition. The closing line is where the planner's done_when lands: "briefly say
/// what you did" invites narration, a named condition invites a check. Falls back to the generic line whenever the
/// planner gave the subtask no condition (an old-schema plan, or a resumed plan.jsonl written before briefs).
fn subtaskInstruction(gpa: std.mem.Allocator, task: cplan.Task, idx: usize, total: usize) ?[]u8 {
    const hint = if (std.mem.eql(u8, task.route, cplan.ROUTE_HIVE))
        "This subtask suits a HIVE — `cast` a swarm for it and steer it; don't build it all yourself."
    else if (std.mem.eql(u8, task.route, cplan.ROUTE_RESEARCH))
        // `recall`, not `recall_hive`: this line must only name tools EVERY belt advertises — the compact
        // (small-tier) belt carries recall alone, and a hint naming an unadvertised tool invites the exact
        // off-belt flailing the belt exists to prevent.
        "You may be missing knowledge here — research it first (web_search / read_url / recall) before acting."
    else
        "Do this directly with your own tools (write_file / edit_file / run_python).";
    const generic = "When it's done, briefly say what you did.";
    var cb: [420]u8 = undefined;
    const closing: []const u8 = if (task.done_when.len > 0)
        (std.fmt.bufPrint(&cb, "DONE WHEN: {s} — verify that, then briefly say how you met it (or why you couldn't).", .{clipBytes(task.done_when, 300)}) catch generic)
    else
        generic;
    // TOOL HINT: the planner's own suggestion of the fitting tool, carried as a hint (not a constraint —
    // the model may pick another if the work turns out different). One line, only when the planner filled it.
    var tb: [200]u8 = undefined;
    const tool_line: []const u8 = if (task.tool_hint.len > 0)
        (std.fmt.bufPrint(&tb, "\nSuggested tool: {s} (a hint from planning — use a better-fitting tool if this step needs one).", .{clipBytes(task.tool_hint, 120)}) catch "")
    else
        "";
    return std.fmt.allocPrint(gpa, "Work this subtask now — step {d} of {d} in your plan: {s}\nSuggested route ({s}): {s}{s}\n{s}", .{ idx + 1, total, task.text, task.route, hint, tool_line, closing }) catch null;
}

/// A plan subtask was mid-flight when the turn aborted (Stop / hard error / empty answer). Mark it DONE + persist
/// so a resume does NOT re-run it — critically, a `route:hive` subtask that already cast a swarm must not re-cast a
/// duplicate on "continue". No-op when no subtask is active. (The user sees it marked and can re-plan if needed.)
fn planStepInterrupted(app: *App, conv_dir: []const u8, plan: []cplan.Task, task_idx: ?usize) void {
    const ti = task_idx orelse return;
    if (ti >= plan.len) return;
    cplan.setStatus(app.gpa, &plan[ti], cplan.STATUS_DONE);
    persistPlan(app, conv_dir, plan);
}

/// Closing message after the drive loop worked a plan: all done, or paused with N/M and how to resume.
fn emitPlanClosing(app: *App, conv_dir: []const u8, plan: []const cplan.Task) void {
    const gpa = app.gpa;
    const done = cplan.doneCount(plan);
    const total = plan.len;
    const note = if (cplan.allDone(plan))
        std.fmt.allocPrint(gpa, "Plan complete — worked all {d} subtasks.", .{total}) catch return
    else
        std.fmt.allocPrint(gpa, "Worked {d} of {d} planned subtasks this turn. Say \"continue\" to do the rest.", .{ done, total }) catch return;
    defer gpa.free(note);
    appendMsg(app, conv_dir, "assistant", note, "veil", nowSecs(app.io));
    emitAssistant(app, conv_dir, note);
}

// --------------------------------------------------------------------------- veil ORCHESTRATION tools (Phase A)

/// A safe empty tool-result (len 0) for OOM fallbacks — never freed (the caller frees only result.len>0).
fn emptyRes() []u8 {
    return @constCast(@as([]const u8, ""));
}

/// Mirror of llm.isLocal / deploy_service's local-model detection over a base_url (loopback = local Ollama etc.).
fn isLocalBase(base_url: []const u8) bool {
    return std.mem.indexOf(u8, base_url, "localhost") != null or
        std.mem.indexOf(u8, base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, base_url, "0.0.0.0") != null or
        std.mem.indexOf(u8, base_url, "[::1]") != null;
}

/// Build a gpa-owned `{"ok":false,"err":<escaped msg>}` tool result (or emptyRes on OOM).
fn orchErr(gpa: std.mem.Allocator, msg: []const u8) []u8 {
    var l: std.ArrayListUnmanaged(u8) = .empty;
    defer l.deinit(gpa); // no-op after a successful toOwnedSlice (list is emptied); frees the buffer on OOM
    (build: {
        l.appendSlice(gpa, "{\"ok\":false,\"err\":") catch break :build;
        http.jstr(gpa, &l, msg) catch break :build;
        l.append(gpa, '}') catch break :build;
    });
    return l.toOwnedSlice(gpa) catch emptyRes();
}

/// Dispatch the veil's orchestration verbs. Returns a gpa-owned result string, or null when `name` is not an
/// orchestration verb (the caller then routes to the normal mind-tool executor).
// ---- AWAIT-SWARM: the engine-level "wait for the hive" the model can't do itself. Without it a cast leaves the
// model only inference-speed polling, so it spin-polls swarm_status, grows impatient, stops the hive early, and
// the armed loop then accepts DONE while the hive is still running — settling over half-finished work. Two
// mechanisms prevent that: (1) statusTool BLOCKS while the swarm runs (cheap file probes + stop checks, no
// inference) so one call replaces a poll storm; (2) an ARMED drive loop refuses to settle while this
// conversation's cast hive is still working — it awaits, then injects a gather step so the results fold into the
// turn. Loop OFF keeps fire-and-forget.

/// The gather step injected when the awaited hive finishes: fold its results into the turn instead of settling.
const SWARM_GATHER_MSG = "The hive you cast has finished. Collect its results NOW: call swarm_status, then list_dir / read_file its deliverable files, verify they satisfy the goal, and fold them into your answer — then continue toward the goal or give the final summary.";
/// Injected ONCE if the hive outlives its budget+grace: salvage rather than wait forever.
const SWARM_TIMEOUT_MSG = "The hive you cast is still running past its time budget. Call swarm_status once more; if it is stuck, stop_swarm it and salvage what it produced (list_dir / read_file), then finish the goal yourself.";
/// Slack past the swarm's minutes budget before the await gives up: the worker's own hang watchdog exits at
/// minutes+90s and stamps DONE, so budget+150s covers the honest path with margin.
const SWARM_WAIT_GRACE_S: i64 = 150;
/// Per-call cap on how long a single swarm_status BLOCKS while the hive works (the drive-loop await has no such
/// cap — it waits to the budget deadline). One bounded wait per call keeps the model in the loop with fresh
/// context instead of a poll storm, and keeps any single tool frame's latency predictable.
const SWARM_STATUS_WAIT_S: i64 = 45;

/// The swarm's `minutes` budget from its manifest ({run_dir}/swarm.json) — the effective value castSwarm computed.
fn swarmMinutes(app: *App, run_dir: []const u8) i64 {
    const gpa = app.gpa;
    var pb: [1280]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/swarm.json", .{run_dir}) catch return 4;
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, p, gpa, .limited(16 << 10)) catch return 4;
    defer gpa.free(raw);
    const M = struct { minutes: i64 = 4 };
    const parsed = std.json.parseFromSlice(M, gpa, raw, .{ .ignore_unknown_fields = true }) catch return 4;
    defer parsed.deinit();
    return std.math.clamp(parsed.value.minutes, 1, 60);
}

/// Is a swarm terminal RIGHT NOW? DONE marker or a dead worker pid — the same fresh predicate statusTool reports
/// (sw.state lags the supervisor's ~10s reconcile, so never trust it for liveness). A very young swarm whose
/// worker.pid hasn't landed yet reads as alive (the spawn takes a moment to write it).
fn swarmTerminal(app: *App, run_dir: []const u8, created: i64) bool {
    var pb: [1280]u8 = undefined;
    if (std.fmt.bufPrint(&pb, "{s}/DONE", .{run_dir})) |dp| {
        if (std.Io.Dir.cwd().access(app.io, dp, .{})) |_| return true else |_| {}
    } else |_| {}
    const ps = app.sup.pidStatus(run_dir);
    if (ps.alive) return false;
    return nowSecs(app.io) - created > 20; // no live pid: terminal unless the swarm is still spawning
}

/// This conversation's cast swarm, if one is LIVE. A chat cast always builds in _chat/builds/{conv}, and
/// sup.resolve falls back to run-dir-basename matching — so the conv id alone finds it, including a cast from an
/// earlier turn (armed-loop semantics: the loop shouldn't settle over ANY running hive in this conversation).
fn liveConvCast(app: *App, uid: u64, conv: []const u8) ?struct { run_dir: []const u8, deadline: i64 } {
    const sw = app.sup.resolve(conv) orelse return null;
    if (sw.uid != uid) return null;
    if (swarmTerminal(app, sw.run_dir, sw.created)) return null;
    return .{ .run_dir = sw.run_dir, .deadline = sw.created + swarmMinutes(app, sw.run_dir) * 60 + SWARM_WAIT_GRACE_S };
}

const AwaitVerdict = enum { finished, stopped, timeout };

/// Block (cheaply — file probes + stop checks, NO inference) until this conversation's cast hive finishes, a stop
/// lands, or the hive outlives its budget. null = no live hive (nothing to wait for). Emits a status frame every
/// ~15s so the desk shows the wait honestly. In client mode, a .finished verdict pushes the hive's files down to
/// the client BEFORE the gather step runs, so the delegated list_dir/read_file that follows finds them locally.
/// (.timeout leaves the hive running — files sync via the pre-delegation hook once a stop_swarm makes it terminal.)
fn awaitConvCast(app: *App, uid: u64, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize, tool_client: bool) ?AwaitVerdict {
    const cast = liveConvCast(app, uid, conv) orelse return null;
    const t0 = nowSecs(app.io);
    var last_frame: i64 = 0;
    var waited: i64 = 0;
    while (true) {
        const now = nowSecs(app.io);
        if (now > cast.deadline) return .timeout;
        waited = now - t0;
        if (waited - last_frame >= 15) {
            last_frame = waited;
            var sb: [128]u8 = undefined;
            emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "the hive is still working — waiting to fold its results ({d}s)", .{waited}) catch "waiting on the hive");
        }
        // ~2s between probes, stop-checked every 250ms so a desk Stop lands promptly mid-wait.
        var slice: usize = 0;
        while (slice < 8) : (slice += 1) {
            if (stopRequestedSince(app, conv_dir, ctrl_cursor)) return .stopped;
            sleepMsRaw(app.io, 250);
        }
        const sw = app.sup.resolve(conv) orelse {
            if (tool_client) maybeSyncCastFiles(app, uid, conv, conv_dir, ctrl_cursor);
            return .finished;
        };
        if (sw.uid != uid or swarmTerminal(app, sw.run_dir, sw.created)) {
            if (tool_client) maybeSyncCastFiles(app, uid, conv, conv_dir, ctrl_cursor);
            return .finished;
        }
    }
}

fn orchTool(app: *App, uid: u64, ctx: *tools.ToolCtx, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize, trio: ModelTrio, name: []const u8, args: []const u8, tool_client: bool) ?[]u8 {
    // cast inherits the CODING/base model as its PRIMARY (a hive builds like the main turn) and the PROMPTING
    // model as its gateway (see castTool); schedule_task persists the full trio.

    // ORCHESTRATION IS A CAPABILITY ESCALATION for a sandboxed caller, and casting is the sharpest edge:
    // a swarm mind runs its OWN ToolCtx (run.zig) with the full surface and patch_root pointed at the
    // engine tree, so "sandbox the chat but allow casting" is not a sandbox — it is a redirect. Same for
    // scheduling, whose runs execute later, outside this turn's context entirely (sched.zig already
    // refuses to TICK a non-admin's task; this stops one being created in the first place).
    //
    // Read-only observation stays: swarm_status / swarm_asks / stop_swarm are each uid-checked by their
    // own handler, so a sandboxed user can watch and halt their own swarms, just not mint new execution.
    if (ctx.caps == .sandboxed) {
        const escalates = std.mem.eql(u8, name, "cast") or std.mem.eql(u8, name, "steer_swarm") or
            std.mem.eql(u8, name, "answer_swarm") or std.mem.eql(u8, name, "sync_dir") or
            std.mem.eql(u8, name, "open_subchat") or // mints a new server-side turn — execution, not observation
            std.mem.startsWith(u8, name, "schedule_");
        if (escalates)
            return ctx.gpa.dupe(u8, "that is not available in this workspace — deploying swarms and scheduling runs are reserved for the server's admin, because they execute outside this conversation's sandbox.") catch null;
    }

    if (std.mem.eql(u8, name, "cast")) return castTool(app, uid, conv, conv_dir, ctrl_cursor, trio, args, tool_client);
    if (std.mem.eql(u8, name, "steer_swarm")) return steerTool(app, uid, args);
    if (std.mem.eql(u8, name, "stop_swarm")) return stopTool(app, uid, args);
    if (std.mem.eql(u8, name, "swarm_status")) return statusTool(app, uid, conv_dir, ctrl_cursor, args);
    if (std.mem.eql(u8, name, "swarm_asks")) return asksTool(app, uid, args);
    if (std.mem.eql(u8, name, "answer_swarm")) return answerTool(app, uid, args);
    if (std.mem.eql(u8, name, "schedule_task")) return scheduleTool(app, uid, trio, args);
    if (std.mem.eql(u8, name, "schedule_update")) return scheduleUpdateTool(app, uid, ctx, args);
    if (std.mem.eql(u8, name, "schedule_list")) return scheduleListTool(app, uid);
    if (std.mem.eql(u8, name, "schedule_delete")) return scheduleDeleteTool(app, uid, args);
    if (std.mem.eql(u8, name, "sync_dir")) return syncDirTool(app, conv, conv_dir, ctrl_cursor, args, tool_client);
    if (std.mem.eql(u8, name, "open_subchat")) return openSubchatTool(app, uid, conv, conv_dir, trio, args);
    return null;
}

/// open_subchat — the veil branches THIS conversation into a tabbed sub-chat ("<primary>__sN") and starts
/// its first turn. The sub-chat is a full family member: shared workspace, shared across-recall memory, a
/// live primary-context block every turn. The spawned turn runs SERVER-SIDE (tools execute on the server in
/// the shared workdir — no client needed) with THIS turn's model trio, through the same per-conv/per-user
/// turn slots a message POST claims, so orchestration cannot exceed the server's concurrency contract.
fn openSubchatTool(app: *App, uid: u64, conv: []const u8, conv_dir: []const u8, trio: ModelTrio, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { goal: []const u8 = "", topic: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "open_subchat: could not parse args JSON");
    defer p.deinit();
    const goal = std.mem.trim(u8, if (p.value.goal.len > 0) p.value.goal else p.value.topic, " \r\n\t");
    if (goal.len == 0) return orchErr(gpa, "open_subchat: 'goal' is required — the branch's own first instruction");
    // ONE nesting level: called from a sub-chat, the new branch is a SIBLING under the same primary
    const primary = cpaths.branchRoot(conv);
    const at = std.mem.lastIndexOf(u8, conv_dir, "/convs/") orelse return orchErr(gpa, "open_subchat: cannot resolve the conversations root");
    const convs_root = conv_dir[0 .. at + "/convs".len + 1]; // ".../convs/" — trailing slash for direct concat
    var free_n: u8 = 0;
    var n: u8 = 1;
    while (n <= cpaths.MAX_BRANCHES) : (n += 1) {
        var bb: [900]u8 = undefined;
        const bdir = std.fmt.bufPrint(&bb, "{s}{s}__s{d}", .{ convs_root, primary, n }) catch continue;
        std.Io.Dir.cwd().access(app.io, bdir, .{}) catch {
            free_n = n;
            break;
        };
    }
    if (free_n == 0) return orchErr(gpa, "this chat already has 5 sub-chats — one must be closed (the x on its tab) before another can open");
    var idb: [96]u8 = undefined;
    const bid = std.fmt.bufPrint(&idb, "{s}__s{d}", .{ primary, free_n }) catch return orchErr(gpa, "open_subchat: id overflow");
    // claim the sub-chat's turn slot exactly as the message POST does; spawnTurn's thread releases it
    switch (beginTurn(app.io, bid, uid)) {
        .ok => {},
        .conv_busy => return orchErr(gpa, "that sub-chat slot already has a turn running"),
        .user_at_cap, .server_full => return orchErr(gpa, "no free turn slot right now — work the branch idea inline, or try again in a moment"),
    }
    if (llm.isLocal(trio.coding.base_url) and !tryClaimLocal(app)) {
        endTurn(app.io, bid);
        return orchErr(gpa, "the local model has no free concurrency for a parallel sub-chat turn — work the idea inline, or switch to a hosted model for parallel branches");
    }
    // A sub-chat runs on the DEFAULTS, exactly as this call site already does for loop and tool_client:
    // it works unattended on a branch nobody is watching, which is precisely where advanced reasoning
    // earns its cost. The parent's fast-mode choice was about the parent's own latency.
    spawnTurn(app, uid, bid, trio, goal, 0, false, "", false);
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"open_subchat\",\"sub\":\"s{d}\",\"conv\":\"{s}\",\"note\":\"sub-chat s{d} opened and its first turn is RUNNING server-side on that goal. It shares this chat's workspace and memory — its findings become recallable here (recall) as it works. Tell the user it opened as tab s{d}; check its progress later via recall or by switching to the tab.\"}}", .{ free_n, bid, free_n, free_n }) catch emptyRes();
}

/// sync_dir — PROJECT a directory from the CLIENT's machine into this conversation's workdir (read-only,
/// hash-diffed: only changed files transfer; the source is NEVER written back to — an immutable system or a
/// live game project stays untouched). This is how work that lives outside the workdir (an app inside a game
/// engine folder, a repo elsewhere on disk) becomes visible to the veil AND to any hive it casts, on command.
fn syncDirTool(app: *App, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize, args: []const u8, tool_client: bool) []u8 {
    const gpa = app.gpa;
    if (!tool_client) return orchErr(gpa, "sync_dir needs a connected client (desk/CLI) — there is no client machine to project from");
    const A = struct { path: []const u8 = "", as: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "sync_dir: could not parse args JSON");
    defer p.deinit();
    const src = std.mem.trim(u8, p.value.path, " \r\n\t");
    if (src.len == 0) return orchErr(gpa, "sync_dir: 'path' is required — an ABSOLUTE directory on the user's machine (e.g. C:/dev/mygame/src)");
    if (std.mem.indexOf(u8, src, "..") != null) return orchErr(gpa, "sync_dir: no '..' in the path");
    // dest = builds/{conv}/work/{as or the source's basename} — always INSIDE the conversation workdir
    const base_name = if (p.value.as.len > 0) p.value.as else std.fs.path.basename(src);
    if (base_name.len == 0 or !cync.safeSyncPath(base_name)) return orchErr(gpa, "sync_dir: bad 'as' — a workdir-relative folder name (e.g. mygame)");
    const at = std.mem.lastIndexOf(u8, conv_dir, "/convs/") orelse return orchErr(gpa, "sync_dir: cannot resolve the workdir");
    var drb: [700]u8 = undefined;
    const droot = cpaths.buildRootFromChatBase(&drb, conv_dir[0..at], conv); // scheduled runs project into their task tree
    if (droot.len == 0) return orchErr(gpa, "sync_dir: cannot resolve the workdir");
    const dest = std.fmt.allocPrint(gpa, "{s}/work/{s}", .{ droot, base_name }) catch return orchErr(gpa, "sync_dir: out of memory");
    defer gpa.free(dest);
    const got = pullClientFilesRooted(app, conv_dir, dest, ctrl_cursor, src);
    if (got < 0) return orchErr(gpa, "sync_dir: the client did not answer — is the desk/CLI still connected?");
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"sync_dir\",\"projected\":{d},\"into\":\"{s}\",\"note\":\"{d} file(s) copied/updated from the client folder into the workdir (unchanged files skipped by hash; text files only, caps 64 files / 512KB each / 4MB total — project the SPECIFIC subfolder you need). The source folder is never written back to; outputs belong in the workdir.\"}}", .{ got, base_name, got }) catch emptyRes();
}

/// schedule_task — the veil creates a scheduled task straight from conversation ("do X every morning at 9").
/// The task inherits THIS turn's provider creds, so its unattended runs use the same backend that created it.
/// Time conveniences the model can actually express: in_min (relative) and at_hm (next local occurrence) for
/// "once" — it never has to guess epoch seconds.
fn scheduleTool(app: *App, uid: u64, trio: ModelTrio, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct {
        name: []const u8 = "",
        prompt: []const u8 = "",
        details: []const u8 = "",
        kind: []const u8 = "once",
        in_min: i64 = 0,
        at_hm: []const u8 = "",
        every_min: i64 = 0,
        hm: []const u8 = "",
    };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "schedule_task: could not parse args JSON");
    defer p.deinit();
    const a = p.value;
    const now = nowSecs(app.io);
    var at: i64 = 0;
    if (std.mem.eql(u8, a.kind, "once")) {
        if (a.in_min > 0) {
            if (a.in_min > sched.EVERY_MIN_MAX) return orchErr(gpa, "schedule_task: in_min is capped at 527040 (one year)"); // model-authored i64: unbounded would overflow the epoch math
            at = now + a.in_min * 60;
        } else if (sched.parseHm(a.at_hm) != null) {
            // next local occurrence of HH:MM — the exact math the daily tick uses
            at = sched.computeNextDue("daily", 0, 0, a.at_hm, now, 0, now, sched.localOffsetSecs());
        } else {
            return orchErr(gpa, "schedule_task: kind \"once\" needs in_min (minutes from now) or at_hm (\"HH:MM\", next occurrence)");
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    switch (sched.createFromSpec(app, arena_state.allocator(), uid, .{
        .name = a.name,
        .prompt = a.prompt,
        .details = a.details,
        .kind = a.kind,
        .at = at,
        .every_min = a.every_min,
        .hm = a.hm,
        .enabled = true,
        // The task inherits this turn's trio; unset thinking/prompting are stored empty and fall back to the
        // coding/base provider at run time (launchRun rebuilds a ModelTrio whose pick() resolves the blanks).
        .base_url = trio.coding.base_url,
        .model = trio.coding.model,
        .api_key = trio.coding.key,
        .think_base_url = trio.thinking.base_url,
        .think_model = trio.thinking.model,
        .think_api_key = trio.thinking.key,
        .prompt_base_url = trio.prompting.base_url,
        .prompt_model = trio.prompting.model,
        .prompt_api_key = trio.prompting.key,
    })) {
        .id => |id| return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"schedule_task\",\"id\":\"{s}\",\"note\":\"created — it fires on schedule as an unattended run with its own cross-run memory; schedule_list shows it\"}}", .{id}) catch emptyRes(),
        .err => |e| return orchErr(gpa, e),
    }
}

/// schedule_update — revise an existing task in place: THE self-improvement verb. A scheduled run calls it on
/// its OWN id (handed to it in the run context) to fold lessons into its prompt/details, tune its cadence, or
/// repair a broken definition; an interactive chat calls it when the user asks to change a schedule. One shared
/// validated path (sched.updateById — the same one the HTTP route uses), absent-vs-present parsed via
/// std.json.Value exactly like the route (a typed struct's defaults can't tell "" from not-sent). The revision
/// is recorded into the TASK's own memory scope ("sched:{id}") with the model's stated reason, so future runs
/// recall WHY the definition changed. The provider triple (base_url/model/api_key) is not on the surface: a
/// self-revising task must never be able to redirect its own credentials.
fn scheduleUpdateTool(app: *App, uid: u64, ctx: *tools.ToolCtx, args: []const u8) []u8 {
    const gpa = app.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch return orchErr(gpa, "schedule_update: could not parse args JSON");
    const obj = switch (parsed) {
        .object => |o| o,
        else => return orchErr(gpa, "schedule_update: args must be a JSON object"),
    };
    const idv = obj.get("id") orelse return orchErr(gpa, "schedule_update: 'id' is required — your own task id is in the SCHEDULED RUN CONTEXT; schedule_list shows all ids");
    if (idv != .string or idv.string.len == 0) return orchErr(gpa, "schedule_update: 'id' must be a task-id string");
    const id = idv.string;

    var s: sched.UpdateSpec = .{};
    var changed: std.ArrayListUnmanaged(u8) = .empty; // arena-backed summary of which fields were passed
    const mark = struct {
        fn add(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), field: []const u8) void {
            if (list.items.len > 0) list.appendSlice(a, ", ") catch return;
            list.appendSlice(a, field) catch {};
        }
    }.add;
    if (obj.get("name")) |v| {
        if (v != .string) return orchErr(gpa, "schedule_update: name must be a string");
        s.name = v.string;
        mark(arena, &changed, "name");
    }
    if (obj.get("prompt")) |v| {
        if (v != .string) return orchErr(gpa, "schedule_update: prompt must be a string");
        s.prompt = v.string;
        mark(arena, &changed, "prompt");
    }
    if (obj.get("details")) |v| {
        if (v != .string) return orchErr(gpa, "schedule_update: details must be a string");
        s.details = v.string;
        mark(arena, &changed, "details");
    }
    if (obj.get("kind")) |v| {
        if (v != .string) return orchErr(gpa, "schedule_update: kind must be \"once\", \"every\", or \"daily\"");
        s.kind = v.string;
        mark(arena, &changed, "kind");
    }
    if (obj.get("every_min")) |v| {
        if (v != .integer) return orchErr(gpa, "schedule_update: every_min must be an integer");
        s.every_min = v.integer;
        mark(arena, &changed, "every_min");
    }
    if (obj.get("hm")) |v| {
        if (v != .string) return orchErr(gpa, "schedule_update: hm must be \"HH:MM\"");
        s.hm = v.string;
        mark(arena, &changed, "hm");
    }
    if (obj.get("in_min")) |v| {
        // "once" re-arm convenience, mirroring schedule_task: the model states minutes-from-now, never epoch math
        if (v != .integer or v.integer < 1) return orchErr(gpa, "schedule_update: in_min must be a positive integer (minutes from now)");
        if (v.integer > sched.EVERY_MIN_MAX) return orchErr(gpa, "schedule_update: in_min is capped at 527040 (one year)");
        s.at = nowSecs(app.io) + v.integer * 60;
        mark(arena, &changed, "at");
    }
    if (obj.get("enabled")) |v| {
        if (v != .bool) return orchErr(gpa, "schedule_update: enabled must be a boolean");
        s.enabled = v.bool;
        mark(arena, &changed, if (v.bool) "enabled(on)" else "enabled(paused)");
    }
    if (changed.items.len == 0) return orchErr(gpa, "schedule_update: pass at least one field to change (name/prompt/details/kind/every_min/hm/in_min/enabled)");

    switch (sched.updateById(app, arena, uid, id, s)) {
        .ok => {},
        .not_found => return orchErr(gpa, "schedule_update: no such task id — call schedule_list for the exact ids"),
        .err => |e| return orchErr(gpa, e),
    }

    // PROVENANCE into the task's own cross-run memory: future runs' TASK MEMORY recall surfaces what changed
    // and why — the revision trail is how "improved over time" stays legible instead of silent prompt drift.
    var reason: []const u8 = "";
    if (obj.get("reason")) |v| {
        if (v == .string) reason = v.string;
    }
    var scope_buf: [80]u8 = undefined;
    if (std.fmt.bufPrint(&scope_buf, "sched:{s}", .{id})) |scope| {
        var note: std.ArrayListUnmanaged(u8) = .empty;
        note.print(arena, "task definition REVISED (fields: {s})", .{changed.items}) catch {};
        if (reason.len > 0) note.print(arena, " — reason: {s}", .{reason[0..@min(reason.len, 300)]}) catch {};
        note.appendSlice(arena, " — future runs execute the NEW definition") catch {};
        if (note.items.len > 0) _ = ctx.mem.observe(scope, note.items);
    } else |_| {}

    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"schedule_update\",\"id\":\"{s}\",\"updated\":\"{s}\",\"note\":\"revision recorded in the task's memory; every future run executes the new definition\"}}", .{ id, changed.items }) catch emptyRes();
}

/// schedule_list — the user's tasks, one compact line each (id | name | kind | next due | runs | state).
fn scheduleListTool(app: *App, uid: u64) []u8 {
    const gpa = app.gpa;
    const brief = sched.listBrief(app, gpa, uid);
    defer gpa.free(brief);
    if (std.mem.trim(u8, brief, " \r\n\t").len == 0) return gpa.dupe(u8, "(no scheduled tasks yet)") catch emptyRes();
    return std.fmt.allocPrint(gpa, "scheduled tasks (id | name | kind | next due | runs | state):\n{s}", .{brief}) catch emptyRes();
}

/// schedule_delete — remove one task by id (ownership is structural: the path is built under this uid).
fn scheduleDeleteTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "schedule_delete: could not parse args JSON");
    defer p.deinit();
    if (p.value.id.len == 0) return orchErr(gpa, "schedule_delete: an id is required (see schedule_list)");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    if (!sched.deleteById(app, arena_state.allocator(), uid, p.value.id)) return orchErr(gpa, "schedule_delete: no such task id — call schedule_list for the exact ids");
    return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"schedule_delete\",\"deleted\":true}") catch emptyRes();
}

/// cast — deploy a swarm into THIS conversation's build dir, using the chat turn's own model/creds so the hive
/// runs on the same backend the user is chatting with. Reuses deploy_service.castSwarm (the exact server cast
/// pipeline the HTTP /cast route uses). gpa-owned result.
///
/// THE TRIO REACHES THE HIVE HERE. A cast used to flatten the trio to `coding` for every one of the worker's
/// labels, so a 16-token BUILD-or-DISCOURSE classifier and a 5-token health ping billed the expensive coding
/// model. The worker already HAS the split — its mechanical calls (classify/digest/screen/gap/rerank/retro/
/// growth/mode/preflight) ride gw_base+gw_key+gateway_model — it was just never handed a gateway. The chat
/// turn's `prompting` role IS that gateway: same intent (cheap, high-volume, non-reasoning), same shape.
///
/// Sent as a WHOLE TRIPLE, never model-only: run.zig:749-750 backfills a blank gw_base with the primary
/// base_url, so a lone gateway_model posts the prompting model's NAME to the CODING provider's endpoint —
/// which 404s exactly on the cross-provider trios this feature exists to serve. `pick` resolves an unset
/// prompting role back to coding; that self-equal gateway is precisely what run.zig's has_fallback /
/// restingNow test for, so a single-model client stays on the old no-gateway path bit for bit.
fn castTool(app: *App, uid: u64, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize, trio: ModelTrio, args: []const u8, tool_client: bool) []u8 {
    const gpa = app.gpa;
    const base_url = trio.coding.base_url;
    const key = trio.coding.key;
    const model = trio.coding.model;
    const gw = trio.pick(.prompting);
    // "Distinct" by the SAME test run.zig:7406 / agi.zig:447 use to decide a fallback exists (model OR endpoint
    // differs) — so what the manifest declares and what the worker acts on can never disagree.
    const gw_distinct = !std.mem.eql(u8, gw.model, model) or !std.mem.eql(u8, gw.base_url, base_url);
    const A = struct { goal: []const u8 = "", minds: u32 = 3, minutes: u32 = 0, mode: []const u8 = "cast", files: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "cast: could not parse args JSON");
    defer p.deinit();
    const a = p.value;
    if (std.mem.trim(u8, a.goal, " \r\n\t").len == 0) return orchErr(gpa, "cast: a goal is required");
    const user = app.auth.userById(uid) orelse return orchErr(gpa, "cast: user not found");

    // CLIENT MODE (client→server): the hive is about to build in the SERVER's copy of this conversation's
    // workdir, but the veil's files (and any client-side script output / user-dropped assets) live on the
    // CLIENT. Pull the difference down first — one manifest round-trip, then only changed files; same-disk
    // installs detect via the probe and transfer nothing. See chat/sync.zig.
    if (tool_client) {
        const at = std.mem.lastIndexOf(u8, conv_dir, "/convs/");
        if (at) |i| {
            var rb: [700]u8 = undefined;
            const root = cpaths.buildRootFromChatBase(&rb, conv_dir[0..i], conv);
            var wb: [1400]u8 = undefined;
            if (root.len > 0) {
                if (std.fmt.bufPrint(&wb, "{s}/work", .{root})) |work| {
                    pullClientFiles(app, conv_dir, work, ctrl_cursor);
                } else |_| {}
            }
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rq = deploy_service.CastReq{
        .goal = a.goal,
        .minutes = a.minutes,
        .minds = a.minds,
        // The swarm runs on the SAME backend the chat turn uses (local Ollama or hosted): pass the turn's creds.
        .provider = if (isLocalBase(base_url)) "ollama" else "openai",
        .model = model,
        .api_key = key,
        .base_url = base_url,
        // Only when the prompting role is GENUINELY distinct. An unset role resolves back to coding, and sending
        // that self-equal triple would still be functionally inert (run.zig's has_fallback compares model+base
        // and would see no difference) — but run.zig:751 emits a "gateway" act event on `gateway_model.len > 0`
        // alone, so a self-equal gateway would announce a split that isn't there on every single-model cast.
        .gateway_model = if (gw_distinct) gw.model else "",
        .gateway_base_url = if (gw_distinct) gw.base_url else "",
        // The gateway needs its OWN key: a cross-provider gateway authenticates against a different endpoint,
        // and leaving it blank makes run.zig:750 substitute the literal "gateway-local" (right for a keyless
        // local sidecar, a 401 for a hosted second provider).
        .gateway_key = if (gw_distinct) gw.key else "",
        .style = "auto",
        .mode = a.mode,
        .dir = conv, // build in this conversation's dir so the cast + chat co-edit one tree
        .files = a.files,
        // No autonomous public egress: the veil's casts stay local build/research. Telegraph publishing remains a
        // deliberate user action via the deploy path, never something the chat veil triggers on its own.
        .publish = false,
        .post = false,
    };
    switch (deploy_service.castSwarm(app, arena.allocator(), user, rq)) {
        .ok => |sp| return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"cast\",\"id\":\"{s}\",\"minds\":{d},\"state\":\"{s}\",\"note\":\"swarm deployed in this conversation's build dir; it runs ASYNC for its minutes budget. swarm_status WAITS while the hive works (call it to watch progress — no need to re-poll rapidly); steer_swarm to guide it (use this id). do NOT stop_swarm just because it is still running — only if it is off-track\"}}", .{ sp.id, sp.minds, sp.state }) catch emptyRes(),
        .fail => |f| return orchErr(gpa, f.msg),
    }
}

/// steer_swarm — deliver a live directive (op:"say" to all minds) or retarget the goal (op:"set_goal") to a
/// running swarm by appending to its control.jsonl, which the worker drains each round. gpa-owned result.
fn steerTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "", text: []const u8 = "", goal: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "steer_swarm: could not parse args JSON");
    defer p.deinit();
    const a = p.value;
    if (a.id.len == 0) return orchErr(gpa, "steer_swarm: an id is required (from cast/swarm_status)");
    const sw = app.sup.resolve(a.id) orelse return orchErr(gpa, "steer_swarm: no such swarm — check the id");
    if (sw.uid != uid) return orchErr(gpa, "steer_swarm: that swarm isn't yours");

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    const built = build: {
        if (a.goal.len > 0) {
            line.appendSlice(gpa, "{\"op\":\"set_goal\",\"goal\":") catch break :build false;
            http.jstr(gpa, &line, a.goal) catch break :build false;
            line.appendSlice(gpa, "}\n") catch break :build false;
            break :build true;
        }
        if (a.text.len == 0) break :build false;
        line.appendSlice(gpa, "{\"op\":\"say\",\"to\":\"all\",\"text\":") catch break :build false;
        http.jstr(gpa, &line, a.text) catch break :build false;
        line.appendSlice(gpa, "}\n") catch break :build false;
        break :build true;
    };
    if (!built) return orchErr(gpa, "steer_swarm: provide `text` (a directive for the minds) or `goal` (to retarget the hive)");
    const ctl = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{sw.run_dir}) catch return orchErr(gpa, "steer_swarm: out of memory");
    defer gpa.free(ctl);
    http.appendFile(app.io, gpa, ctl, line.items) catch return orchErr(gpa, "steer_swarm: could not write the control channel");
    return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"steer_swarm\",\"note\":\"delivered; the minds read it at their next round\"}") catch emptyRes();
}

/// stop_swarm — cooperative stop of a running swarm (its files + findings are kept). gpa-owned result.
fn stopTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "stop_swarm: could not parse args JSON");
    defer p.deinit();
    if (p.value.id.len == 0) return orchErr(gpa, "stop_swarm: an id is required");
    const sw = app.sup.resolve(p.value.id) orelse return orchErr(gpa, "stop_swarm: no such swarm");
    if (sw.uid != uid) return orchErr(gpa, "stop_swarm: that swarm isn't yours");
    app.sup.stop(sw.id);
    return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"stop_swarm\",\"state\":\"stopping\",\"note\":\"stop requested (cooperative; effective at the swarm's next round). files + findings are kept.\"}") catch emptyRes();
}

/// swarm_status — compact liveness for the veil to decide keep-going / steer / collect: supervisor state, whether
/// the worker process is alive, mind count, and whether a terminal DONE marker exists yet. While the swarm is
/// STILL RUNNING this call BLOCKS (cheap file probes + stop checks, up to SWARM_STATUS_WAIT_S) — the engine-level
/// "wait" the model can't express itself. Without it the model's only move is to re-poll at inference speed,
/// burning the pass's iterations. One blocking call replaces the storm; the result says how long it waited.
/// gpa-owned result.
fn statusTool(app: *App, uid: u64, conv_dir: []const u8, ctrl_cursor: usize, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "swarm_status: could not parse args JSON");
    defer p.deinit();
    if (p.value.id.len == 0) return orchErr(gpa, "swarm_status: an id is required");
    // The friendlier miss matters most to a small model: a bare "no such swarm" after a successful cast reads
    // as the swarm having DIED, and the observed response was to re-poll and then flail into other tools. Say
    // what a valid id looks like and what to do instead — copied verbatim, not retyped, or stop polling.
    var sw = app.sup.resolve(p.value.id) orelse return orchErr(gpa, "swarm_status: no swarm has that exact id — pass the `id` string cast returned, copied VERBATIM (do not retype or shorten it). If you have not cast a swarm in this conversation, do not poll; continue the work with your own tools.");
    if (sw.uid != uid) return orchErr(gpa, "swarm_status: that swarm isn't yours");

    // WAIT while running: probe every ~2s (stop-checked every 250ms), bounded per call. A finished/dead swarm
    // returns immediately; a Stop mid-wait returns the current state so the turn's next boundary ends promptly.
    const t0 = nowSecs(app.io);
    var waited: i64 = 0;
    var last_frame: i64 = 0;
    while (!swarmTerminal(app, sw.run_dir, sw.created) and waited < SWARM_STATUS_WAIT_S) {
        var slice: usize = 0;
        stop: while (slice < 8) : (slice += 1) {
            if (stopRequestedSince(app, conv_dir, ctrl_cursor)) break :stop;
            sleepMsRaw(app.io, 250);
        }
        if (stopRequestedSince(app, conv_dir, ctrl_cursor)) break;
        waited = nowSecs(app.io) - t0;
        if (waited - last_frame >= 15) {
            last_frame = waited;
            var sb: [96]u8 = undefined;
            emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "hive still working — watching it ({d}s)", .{waited}) catch "watching the hive");
        }
        sw = app.sup.resolve(p.value.id) orelse break; // re-resolve: the registry entry can be replaced/removed
        if (sw.uid != uid) return orchErr(gpa, "swarm_status: that swarm isn't yours");
    }

    const ps = app.sup.pidStatus(sw.run_dir);
    const finished = blk: {
        var pb: [1280]u8 = undefined;
        const dp = std.fmt.bufPrint(&pb, "{s}/DONE", .{sw.run_dir}) catch break :blk false;
        if (std.Io.Dir.cwd().access(app.io, dp, .{})) |_| break :blk true else |_| break :blk false;
    };
    const note = if (finished or !ps.alive)
        "the hive is done — read its deliverable files (list_dir/read_file) and fold the results in"
    else
        "still working; this call WAITS while the hive runs — call swarm_status again to keep watching, steer_swarm to guide it, or do other useful work meanwhile. do NOT stop_swarm just because it is still running";
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"tool\":\"swarm_status\",\"id\":\"{s}\",\"state\":\"{s}\",\"minds\":{d},\"alive\":{s},\"finished\":{s},\"waited_s\":{d},\"note\":\"{s}\"}}", .{ sw.id, @tagName(sw.state), sw.minds, if (ps.alive) "true" else "false", if (finished) "true" else "false", waited, note }) catch emptyRes();
}

/// Read the veil's answered-ledger for a swarm ({run_dir}/veil_answered.jsonl — one ask_id per line). gpa-owned
/// blob or empty. The veil is the ONLY writer (in-process chat turn), so there's no cross-process contention.
fn readAnswered(app: *App, run_dir: []const u8) []u8 {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/veil_answered.jsonl", .{run_dir}) catch return emptyRes();
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(256 << 10)) catch emptyRes();
}

/// Is `id` listed (as a whole trimmed line) in a ledger blob?
fn idInLedger(blob: []const u8, id: []const u8) bool {
    if (id.len == 0) return false;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \r\t"), id)) return true;
    }
    return false;
}

/// swarm_asks — the OPEN questions a running swarm's minds raised (ask_veil) that the veil hasn't answered yet.
/// Reads {run_dir}/asks.jsonl (each line {id, mind, q}, a stable random id) and drops any id already in the
/// answered-ledger. gpa-owned JSON result.
fn asksTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "swarm_asks: could not parse args JSON");
    defer p.deinit();
    if (p.value.id.len == 0) return orchErr(gpa, "swarm_asks: an id is required");
    const sw = app.sup.resolve(p.value.id) orelse return orchErr(gpa, "swarm_asks: no such swarm");
    if (sw.uid != uid) return orchErr(gpa, "swarm_asks: that swarm isn't yours");

    const askpath = std.fmt.allocPrint(gpa, "{s}/asks.jsonl", .{sw.run_dir}) catch return orchErr(gpa, "swarm_asks: out of memory");
    defer gpa.free(askpath);
    const asks = std.Io.Dir.cwd().readFileAlloc(app.io, askpath, gpa, .limited(1 << 20)) catch return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"swarm_asks\",\"asks\":[]}") catch emptyRes();
    defer gpa.free(asks);
    const answered = readAnswered(app, sw.run_dir);
    defer if (answered.len > 0) gpa.free(answered);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "{\"ok\":true,\"tool\":\"swarm_asks\",\"asks\":[") catch return emptyRes();
    var count: usize = 0;
    const R = struct { id: []const u8 = "", mind: []const u8 = "", q: []const u8 = "" };
    var it = std.mem.splitScalar(u8, asks, '\n');
    while (it.next()) |raw| {
        if (count >= 20) break; // cap the surfaced asks
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const rp = std.json.parseFromSlice(R, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer rp.deinit();
        if (rp.value.id.len == 0 or std.mem.trim(u8, rp.value.q, " \r\n\t").len == 0) continue;
        if (idInLedger(answered, rp.value.id)) continue;
        var obj: std.ArrayListUnmanaged(u8) = .empty;
        defer obj.deinit(gpa);
        const objs = build: {
            obj.appendSlice(gpa, "{\"ask_id\":") catch break :build false;
            http.jstr(gpa, &obj, rp.value.id) catch break :build false;
            obj.appendSlice(gpa, ",\"mind\":") catch break :build false;
            http.jstr(gpa, &obj, rp.value.mind) catch break :build false;
            obj.appendSlice(gpa, ",\"question\":") catch break :build false;
            http.jstr(gpa, &obj, rp.value.q) catch break :build false;
            obj.append(gpa, '}') catch break :build false;
            break :build true;
        };
        if (!objs) continue; // couldn't build this object — skip it (never emit a partial)
        if (count > 0) out.append(gpa, ',') catch break;
        out.appendSlice(gpa, obj.items) catch break;
        count += 1;
    }
    out.appendSlice(gpa, "]}") catch return emptyRes();
    return out.toOwnedSlice(gpa) catch emptyRes();
}

/// answer_swarm — deliver the veil's answer to a mind's open ask: write an `answer` control op (routed to that
/// mind's inbox by the worker's drainControl) and record the ask_id in the answered-ledger so swarm_asks stops
/// surfacing it. gpa-owned JSON result.
fn answerTool(app: *App, uid: u64, args: []const u8) []u8 {
    const gpa = app.gpa;
    const A = struct { id: []const u8 = "", ask_id: []const u8 = "", mind: []const u8 = "", text: []const u8 = "" };
    const p = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch return orchErr(gpa, "answer_swarm: could not parse args JSON");
    defer p.deinit();
    const a = p.value;
    if (a.id.len == 0 or a.ask_id.len == 0 or a.mind.len == 0 or std.mem.trim(u8, a.text, " \r\n\t").len == 0)
        return orchErr(gpa, "answer_swarm: id, ask_id, mind, and text are all required");
    const sw = app.sup.resolve(a.id) orelse return orchErr(gpa, "answer_swarm: no such swarm");
    if (sw.uid != uid) return orchErr(gpa, "answer_swarm: that swarm isn't yours");

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);
    const built = build: {
        line.appendSlice(gpa, "{\"op\":\"answer\",\"to\":") catch break :build false;
        http.jstr(gpa, &line, a.mind) catch break :build false;
        line.appendSlice(gpa, ",\"id\":") catch break :build false;
        http.jstr(gpa, &line, a.ask_id) catch break :build false;
        line.appendSlice(gpa, ",\"text\":") catch break :build false;
        http.jstr(gpa, &line, a.text) catch break :build false;
        line.appendSlice(gpa, "}\n") catch break :build false;
        break :build true;
    };
    if (!built) return orchErr(gpa, "answer_swarm: out of memory");
    const ctl = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{sw.run_dir}) catch return orchErr(gpa, "answer_swarm: out of memory");
    defer gpa.free(ctl);
    http.appendFile(app.io, gpa, ctl, line.items) catch return orchErr(gpa, "answer_swarm: could not write the control channel");
    // dedup ledger (best-effort — a failed write just means swarm_asks may re-show this ask)
    if (std.fmt.allocPrint(gpa, "{s}/veil_answered.jsonl", .{sw.run_dir})) |ap| {
        defer gpa.free(ap);
        if (std.fmt.allocPrint(gpa, "{s}\n", .{a.ask_id})) |aline| {
            defer gpa.free(aline);
            http.appendFile(app.io, gpa, ap, aline) catch {};
        } else |_| {}
    } else |_| {}
    return gpa.dupe(u8, "{\"ok\":true,\"tool\":\"answer_swarm\",\"note\":\"answer delivered to the mind's inbox; it reads it on its next round\"}") catch emptyRes();
}

/// Tools whose half-executed arguments CORRUPT state (a truncated write lands a half file that reads as
/// complete; a truncated delete could name a shorter-but-real path). Reads are deliberately absent: a cut-off
/// search query just searches worse, and refusing it would cost a round for nothing.
fn isMutatingTool(name: []const u8) bool {
    for ([_][]const u8{ "write_file", "edit_file", "delete_file", "stage_file" }) |m|
        if (std.mem.eql(u8, m, name)) return true;
    return false;
}

/// Did this turn ADVERTISE `name` — or does any static table know it at all?
///
/// A small model routinely invents tool names. Observed live on a 12B: `WebSearch` (the real name is
/// `web_search`), a `Gemma4__1m_check` that never existed anywhere, and `mcp_call{server:"google-search"}`. In
/// client mode EVERY name was shipped straight to the client, which cannot answer for a tool it has never heard
/// of, so the call burned the full 20s ack timeout and came back "(no desk/CLI client picked up …)". The model
/// read that as its TOOLS BEING OFFLINE and abandoned the goal — verbatim, in that conversation: "My search and
/// quick-look tools are currently offline on this session". Three of its six calls died exactly this way.
///
/// The advertised array is checked FIRST, then the full static tables: the compact belt deliberately hides
/// tools that execute()/orchTool still dispatch, and a model naming one of those from memory must still run it.
/// So only a name that exists NOWHERE is refused — recipes and plugin tools ride in `turn_tools` already.
fn knownToolName(turn_tools: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var buf: [160]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"name\":\"{s}\"", .{name}) catch return true; // unmeasurably long ⇒ never block
    return std.mem.indexOf(u8, turn_tools, needle) != null or
        std.mem.indexOf(u8, TURN_TOOLS_FULL, needle) != null or
        std.mem.indexOf(u8, tools.SCHEMA, needle) != null;
}

/// Mask account-material tokens a provider error quotes back ("org-4c48…", "<ak-fbf3…>", "sk-…"): keep a
/// 4-char stub so support conversations still work, star the rest. In-place into `buf`; returns the slice.
/// Only prefixed token SHAPES are touched — the error's prose survives verbatim.
fn scrubAccountIds(buf: []u8, msg: []const u8) []const u8 {
    const n = @min(msg.len, buf.len);
    @memcpy(buf[0..n], msg[0..n]);
    const prefixes = [_][]const u8{ "org-", "ak-", "sk-", "key-" };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        for (prefixes) |p| {
            if (i + p.len >= n or !std.ascii.startsWithIgnoreCase(buf[i..n], p)) continue;
            // token boundary before the prefix, so "fork-" or "mask-" prose can't match
            if (i > 0 and (std.ascii.isAlphanumeric(buf[i - 1]) or buf[i - 1] == '_')) continue;
            var j = i + p.len;
            while (j < n and (std.ascii.isAlphanumeric(buf[j]) or buf[j] == '_')) j += 1;
            if (j - (i + p.len) >= 8) { // real ids are long; keep 4 id chars then star the rest
                for (buf[i + p.len + 4 .. j]) |*ch| ch.* = '*';
            }
            i = j - 1;
            break;
        }
    }
    return buf[0..n];
}

/// Case- and punctuation-insensitive tool-name equality: "WebSearch" ≡ "web_search" ≡ "web-search". Compares
/// only alphanumerics, case-folded — the exact transformations small models apply to names they half-remember.
fn toolNameEqLoose(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and !std.ascii.isAlphanumeric(a[i])) i += 1;
        while (j < b.len and !std.ascii.isAlphanumeric(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

/// The ADVERTISED tool whose loose form matches `name` — exactly one, or null. Ambiguity refuses to guess
/// (running the wrong tool is worse than a correction round), and matching is restricted to the belt this turn
/// actually advertised: a compact turn's "Cast" must get the correction message, not a helpful upgrade into
/// orchestration the belt deliberately hides.
fn canonToolMatch(turn_tools: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > 80) return null;
    var found: ?[]const u8 = null;
    const key = "\"name\":\"";
    var i: usize = 0;
    while (std.mem.indexOf(u8, turn_tools[i..], key)) |rel| {
        const at = i + rel + key.len;
        const end = std.mem.indexOfScalar(u8, turn_tools[at..], '"') orelse break;
        const cand = turn_tools[at .. at + end];
        if (toolNameEqLoose(cand, name)) {
            if (found != null) return null; // two candidates — do not guess
            found = cand;
        }
        i = at + end;
    }
    return found;
}

/// Does a fetched body look like a not-found/error page rather than content? The observed spiral: a small
/// model INVENTS a plausible URL (an arXiv id that never existed), the 404 page comes back as ordinary bytes,
/// and it pivots to the next guessed URL — burning the turn on fabricated citations. Conservative window:
/// "not found" must sit in the first bytes (error pages lead with it; articles don't), the explicit phrases
/// may sit anywhere in the head, and a big body is content no matter what it contains.
fn looksLikeNotFound(body: []const u8) bool {
    if (body.len == 0 or body.len > 16384) return false;
    const head = body[0..@min(body.len, 1024)];
    // 32 bytes, not more: error pages OPEN with the verdict ("Not found …", "<title>404 Not Found"), while
    // prose reaches "not found" mid-sentence — at 96 bytes an article's "a solution was not found by…"
    // false-positived in the regression test, which is exactly the page this must never eat.
    var lead: [32]u8 = undefined;
    const n = @min(body.len, lead.len);
    for (body[0..n], 0..) |ch, i| lead[i] = std.ascii.toLower(ch);
    if (std.mem.indexOf(u8, lead[0..n], "not found") != null) return true;
    const markers = [_][]const u8{ "Page not found", "404 Not Found", "No document for", "Error 404", "page you requested does not exist", "couldn't find that page" };
    for (markers) |mk| if (std.mem.indexOf(u8, head, mk) != null) return true;
    return false;
}

/// Consecutive dud fetches (not-found or bot-challenge pages) that prove the model is GUESSING URLs. Three in
/// a row earns the stop-constructing-URLs instruction on the result; one good fetch resets the streak.
const DUD_FETCH_STREAK = 3;

/// Consecutive poll TIMEOUTS after which further polls this turn are refused outright. Poll is a bounded wait,
/// but its own doctrine ("a long wait is a chain of bounded polls") reads to a model as "poll forever", each
/// timeout returns DIFFERENT text (the t+Ns sample log), so the identical-result echo guard never trips — and
/// each poll blocks up to 180s. Observed live: a model polling a deploy that had already finished held the
/// turn until the user typed "stop polling". Three timeouts with zero matches is not waiting, it is stuck.
const POLL_TIMEOUT_STREAK = 3;

/// Does a fetched body look like a bot-check interstitial rather than the page? Conservative on purpose: the
/// markers are the stub pages' own words, checked only in the HEAD of a SMALL body — a real article that merely
/// mentions Cloudflare is big and keeps its first bytes for itself. False negative = today's behavior; false
/// positive would hide a real page, so every marker must be challenge-page boilerplate, not vocabulary.
fn looksLikeBotChallenge(body: []const u8) bool {
    if (body.len == 0 or body.len > 16384) return false; // challenge stubs are small; articles are not
    const head = body[0..@min(body.len, 2048)];
    const markers = [_][]const u8{
        "Just a moment...",
        "Enable JavaScript and cookies to continue",
        "challenge-platform",
        "Checking your browser before",
        "Pardon Our Interruption",
        "Attention Required! | Cloudflare",
        "cf-chl-",
        "Verifying you are human",
        "#cmsg{animation", // the PerimeterX/Reuters stub observed live
        "enable JS and disable any ad blocker",
    };
    for (markers) |mk| if (std.mem.indexOf(u8, head, mk) != null) return true;
    return false;
}

/// The corrective answer to a hallucinated tool name: say plainly that it does not exist, that nothing ran, and
/// list the names that DO exist, so the next round has the real belt in front of it instead of a bridge error to
/// misread. The names are read back out of the array this turn actually advertised — the belt varies with tier
/// and caps, so any hardcoded list here would eventually lie to the model.
fn unknownToolResult(gpa: std.mem.Allocator, name: []const u8, turn_tools: []const u8) []u8 {
    var names: std.ArrayListUnmanaged(u8) = .empty;
    defer names.deinit(gpa);
    const key = "\"name\":\"";
    var i: usize = 0;
    while (std.mem.indexOf(u8, turn_tools[i..], key)) |rel| {
        const at = i + rel + key.len;
        const end = std.mem.indexOfScalar(u8, turn_tools[at..], '"') orelse break;
        if (names.items.len > 0) names.appendSlice(gpa, ", ") catch break;
        names.appendSlice(gpa, turn_tools[at .. at + end]) catch break;
        i = at + end;
    }
    return std.fmt.allocPrint(gpa, "(there is no tool named \"{s}\" — nothing ran, and this is NOT a tool being offline or a connection problem. Your tools this turn are exactly: {s}. Call one of those by its exact name, or answer without a tool.)", .{ name, names.items }) catch emptyRes();
}

/// CLIENT-MODE tool execution: emit a {kind:"tool_request"} frame and BLOCK the turn until the client posts
/// the result back (POST .../tool_result → tool_results.jsonl). This is how a desk/CLI turn runs file/shell/
/// code tools with ITS OWN harness on the user's machine while the brain stays server-side. Stop-checked and
/// timed out so a disconnected client can't wedge the turn — a timeout returns an error the model then sees.
/// Consecutive never-acked delegation timeouts that prove the client ABSENT for the rest of the turn. One
/// timeout is tolerated (an AV-scan stall, a reconnect window); two in a row — 40s of total silence against a
/// ~1Hz event poller — is a desk that is not there. Without the latch a genuinely detached conversation paid
/// the full ack timeout PER CALL (observed live: six delegated calls ≈ two minutes of dead air), and the
/// model narrated the wait as its tools being permanently broken.
const CLIENT_GONE_AFTER: u32 = 2;

fn delegateTool(app: *App, conv_dir: []const u8, id_in: []const u8, name: []const u8, args: []const u8, ctrl_cursor: usize, no_ack_streak: *u32) []u8 {
    const gpa = app.gpa;
    // LATCHED: the client proved absent earlier THIS turn — answer instantly instead of re-paying the ack
    // timeout. Turn-scoped on purpose: the next turn starts at zero and probes the bridge fresh (a desk that
    // reconnects between turns must not stay condemned).
    if (no_ack_streak.* >= CLIENT_GONE_AFTER)
        return gpa.dupe(u8, "(client tools are unavailable for the REST OF THIS TURN — earlier calls went unacknowledged, so this call was skipped instantly rather than waiting out another timeout. This is a session-connection state, NOT broken tools: stop calling client-side tools this turn, answer from what you already have, and tell the user plainly that the desk/CLI tool bridge is not responding — they can check the desk app and retry.)") catch emptyRes();
    // An id-less call can NEVER round-trip the bridge: /tool_result refuses an empty id (acks included), so the
    // request would sit unanswered for its full timeout and come back "(no desk/CLI client picked up …)" — the
    // exact wall that made every LOCAL model's tools look broken (Ollama-native calls carry no id; llm.zig now
    // mints upstream). Kept here as the backstop so no future call producer can regress the bridge silently.
    const minted: ?[]u8 = if (id_in.len == 0) (llm.mintCallId(gpa) catch null) else null;
    defer if (minted) |m| gpa.free(m);
    const id: []const u8 = minted orelse id_in;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    const built = blk: {
        ev.appendSlice(gpa, "{\"kind\":\"tool_request\",\"id\":") catch break :blk false;
        http.jstr(gpa, &ev, id) catch break :blk false;
        ev.appendSlice(gpa, ",\"tool\":") catch break :blk false;
        http.jstr(gpa, &ev, name) catch break :blk false;
        ev.appendSlice(gpa, ",\"args\":") catch break :blk false;
        http.jstr(gpa, &ev, args) catch break :blk false; // raw args JSON carried as a string; the client parses it
        ev.append(gpa, '}') catch break :blk false;
        break :blk true;
    };
    // Capture the results-channel length BEFORE emitting: this call's answer is written after this point, so
    // the awaiting scan can skip every prior result and read only its own tail.
    const start_offset = toolResultsLen(app, conv_dir);
    if (built) emitEvent(app, conv_dir, ev.items);

    // Heartbeat-aware wait: the client ACKs the request as soon as it picks it up (and the desk keeps
    // heartbeating while its subprocess runs), so a missing client fails FAST instead of blocking the turn
    // for the full tool budget, while a slow-but-alive tool gets its patience refreshed by every heartbeat.
    const CLIENT_ACK_TIMEOUT_S: i64 = 20; // no ack at all → nothing is attached in client mode; fail fast
    const CLIENT_TOOL_TIMEOUT_S: i64 = 180; // patience from t0 AND from each fresh ack/heartbeat
    var acked = false;
    var stopped = false;
    if (awaitClientResult(app, conv_dir, id, ctrl_cursor, start_offset, CLIENT_ACK_TIMEOUT_S, CLIENT_TOOL_TIMEOUT_S, &acked, &stopped)) |result| {
        no_ack_streak.* = 0; // a real round-trip — the bridge is alive, forget any earlier silence
        return result;
    }
    // The wait is being ABANDONED (stop / crash / silence) — tell the client so, by id. Without this frame the
    // desk keeps running the tool to its own timeout (a poll runs up to 180s), keeps showing its "running"
    // chip, and its eventual result POST lands in a turn that no longer exists — observed live as a poll the
    // user could not stop and a chip that never cleared ("why does it show the poll still running?").
    {
        var cv: std.ArrayListUnmanaged(u8) = .empty;
        defer cv.deinit(gpa);
        const built_cancel = cblk: {
            cv.appendSlice(gpa, "{\"kind\":\"tool_cancel\",\"id\":") catch break :cblk false;
            http.jstr(gpa, &cv, id) catch break :cblk false;
            cv.append(gpa, '}') catch break :cblk false;
            break :cblk true;
        };
        if (built_cancel) emitEvent(app, conv_dir, cv.items);
    }
    if (acked) no_ack_streak.* = 0 // the client picked it up and then died mid-run — present, just crashed
    else if (!stopped) no_ack_streak.* += 1; // pure silence counts toward absence (a stop is the user, not the bridge)
    return gpa.dupe(u8, if (stopped)
        "(STOP requested by the user — this tool call was canceled, not failed. Do NOT retry it; acknowledge the stop and end the turn.)"
    else if (acked)
        "(the client started this tool but stopped answering before returning a result — it may have crashed mid-run; verify the state before retrying)"
    else
        "(no desk/CLI client picked up this tool call — the desk/CLI that started this conversation looks disconnected right now. This is a session-connection state, NOT broken tools: do not conclude your tools are gone; if it repeats, answer from what you already have and tell the user the tool bridge is not responding.)") catch emptyRes();
}

/// Absolute ceiling on any client round-trip, heartbeats or not — the backstop against a client that
/// heartbeats forever without ever posting a result (its own tool timeout is far shorter than this).
const CLIENT_HARD_CAP_S: i64 = 1200;

/// Block until the client posts a result for `id` to /tool_result (or a stop lands / the deadline passes).
/// The one wait primitive under every client round-trip: delegated tools AND the sync protocol's manifest /
/// file-pull exchanges. `start_offset` is tool_results.jsonl's length captured just before the request was
/// emitted — the scan starts there and advances a cursor, so each poll reads only the new tail (O(new bytes),
/// not O(whole file) every 150ms). The deadline starts at `no_ack_timeout_s`; every fresh ack the client
/// posts for this id (the desk heartbeats while its tool subprocess runs) extends it to now + `ack_patience_s`,
/// capped at CLIENT_HARD_CAP_S total. `saw_ack` (optional) reports whether the client ever acked, so the caller
/// can tell "client gone" from "client died mid-run". gpa-owned result; null = stopped or timed out.
fn awaitClientResult(app: *App, conv_dir: []const u8, id: []const u8, ctrl_cursor: usize, start_offset: usize, no_ack_timeout_s: i64, ack_patience_s: i64, saw_ack: ?*bool, saw_stop: ?*bool) ?[]u8 {
    const t0 = nowSecs(app.io);
    var deadline = t0 + no_ack_timeout_s;
    const hard_cap = t0 + CLIENT_HARD_CAP_S;
    var cursor: usize = start_offset;
    while (nowSecs(app.io) < @min(deadline, hard_cap)) {
        if (stopRequestedSince(app, conv_dir, ctrl_cursor)) {
            // A user STOP, not a client failure — report which. Conflated, every remaining delegation in the
            // batch instant-failed as "(no desk/CLI client picked up …)", the model read a transient bridge
            // loss and RETRIED against the user's stop (observed live: Stop presses reading as write_file
            // "failures" in bursts while the desk executed everything it was actually asked).
            if (saw_stop) |ss| ss.* = true;
            return null;
        }
        const chan = scanToolChannel(app, conv_dir, id, &cursor);
        if (chan.result) |r| return r;
        if (chan.acks > 0) { // fresh acks since the last poll — client is alive and working
            if (saw_ack) |sa| sa.* = true;
            const fresh = nowSecs(app.io) + ack_patience_s;
            if (fresh > deadline) deadline = fresh;
        }
        sleepMsRaw(app.io, 150);
    }
    return null;
}

// ------------------------------------------------------------------ CLIENT-MODE WORKDIR SYNC (see chat/sync.zig)

/// How long a sync round-trip (manifest / file-pull) waits for the client. Short vs the tool timeout: a client
/// that answers delegated tools answers these instantly; a vanished client must not stall a cast for minutes.
const SYNC_WAIT_S: i64 = 60;

const SyncInfo = struct {
    shared: bool, // the probe token round-tripped: both sides read the SAME directory — no transfer ever needed
    parsed: ?std.json.Parsed(cync.ManifestResp), // the client's manifest (null when it never answered)

    fn deinit(si: *SyncInfo) void {
        if (si.parsed) |p| p.deinit();
    }
    fn manifest(si: *const SyncInfo) ?*const cync.ManifestResp {
        return if (si.parsed) |*p| &p.value else null;
    }
};

/// One manifest round-trip with the client (+ same-disk probe): write a token into the SERVER's copy of the
/// workdir, ask the client for its manifest, and see whether the token came back. A non-empty `root` asks the
/// client to manifest THAT absolute directory on its machine instead of the conv workdir (the sync_dir
/// projection) — the probe then never matches, so a rooted exchange always runs the full protocol, which is
/// exactly right (the source dir is never the server's dest dir). null = the client never answered (no client
/// attached / gone) — callers degrade to their no-manifest behavior, never wedge.
fn syncExchange(app: *App, conv_dir: []const u8, workdir: []const u8, ctrl_cursor: usize, root: []const u8) ?SyncInfo {
    const gpa = app.gpa;
    _ = std.Io.Dir.cwd().createDirPathStatus(app.io, workdir, .default_dir) catch {};
    // the probe token: random hex, written server-side, echoed by the client only if it sees the same disk
    var rnd: [8]u8 = undefined;
    app.io.random(&rnd);
    var tokb: [16]u8 = undefined;
    const token = std.fmt.bufPrint(&tokb, "{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return null;
    var pb: [1500]u8 = undefined;
    const probe_path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ workdir, cync.PROBE_NAME }) catch return null;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = probe_path, .data = token }) catch {};
    defer std.Io.Dir.cwd().deleteFile(app.io, probe_path) catch {};

    var idb: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "sync{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return null;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    const built = blk: {
        ev.appendSlice(gpa, "{\"kind\":\"sync_request\",\"id\":") catch break :blk false;
        http.jstr(gpa, &ev, id) catch break :blk false;
        if (root.len > 0) {
            ev.appendSlice(gpa, ",\"root\":") catch break :blk false;
            http.jstr(gpa, &ev, root) catch break :blk false;
        }
        ev.append(gpa, '}') catch break :blk false;
        break :blk true;
    };
    if (!built) return null;
    const start_offset = toolResultsLen(app, conv_dir);
    emitEvent(app, conv_dir, ev.items);
    const resp = awaitClientResult(app, conv_dir, id, ctrl_cursor, start_offset, SYNC_WAIT_S, SYNC_WAIT_S, null, null) orelse return null;
    defer gpa.free(resp);
    const parsed = std.json.parseFromSlice(cync.ManifestResp, gpa, resp, .{ .ignore_unknown_fields = true }) catch return null;
    const shared = std.mem.eql(u8, std.mem.trim(u8, parsed.value.probe, " \r\n\t"), token);
    return .{ .shared = shared, .parsed = parsed };
}

/// Does the client's manifest already carry `rel` with this exact content hash? (Linear scan — manifests are
/// capped at MAX_FILES entries.)
fn clientHasFile(m: ?*const cync.ManifestResp, rel: []const u8, hash: []const u8) bool {
    const mm = m orelse return false;
    for (mm.files) |e| {
        if (std.mem.eql(u8, e.p, rel) and std.mem.eql(u8, e.h, hash)) return true;
    }
    return false;
}

/// CLIENT MODE, cast time (client→server): the hive is about to build in the SERVER's builds/{conv}/work, but
/// in client mode every file the veil wrote — and anything a client-side script generated or the user dropped
/// in — exists only on the CLIENT. Pull the difference down first: one manifest round-trip, then only the
/// files whose hash differs from the server's copy. Same-disk installs short-circuit on the probe (zero
/// transfers); a client that never answers degrades to casting with what the server has.
fn pullClientFiles(app: *App, conv_dir: []const u8, workdir: []const u8, ctrl_cursor: usize) void {
    _ = pullClientFilesRooted(app, conv_dir, workdir, ctrl_cursor, "");
}

/// The pull engine behind both cast-time workdir sync (root="") and the sync_dir projection (root = an
/// absolute directory on the CLIENT's machine, mirrored into `workdir` server-side). Returns how many files
/// landed; -1 = the client never answered the manifest request.
fn pullClientFilesRooted(app: *App, conv_dir: []const u8, workdir: []const u8, ctrl_cursor: usize, root: []const u8) i64 {
    const gpa = app.gpa;
    var si = syncExchange(app, conv_dir, workdir, ctrl_cursor, root) orelse return -1;
    defer si.deinit();
    if (si.shared) return 0; // same directory — the hive already sees the client's files
    const m = si.manifest() orelse return 0;

    // want-list: every client file the server's copy is missing or has different bytes for
    var paths: std.ArrayListUnmanaged(u8) = .empty;
    defer paths.deinit(gpa);
    var want: usize = 0;
    for (m.files) |e| {
        if (!cync.safeSyncPath(e.p)) continue;
        var fb: [1700]u8 = undefined;
        const full = std.fmt.bufPrint(&fb, "{s}/{s}", .{ workdir, e.p }) catch continue;
        var same = false;
        if (std.Io.Dir.cwd().readFileAlloc(app.io, full, gpa, .limited(cync.FILE_CAP)) catch null) |cur| {
            var hb: [16]u8 = undefined;
            same = std.mem.eql(u8, cync.hashHex(cur, &hb), e.h);
            gpa.free(cur);
        }
        if (same) continue;
        const ok = blk: {
            if (want > 0) paths.append(gpa, ',') catch break :blk false;
            http.jstr(gpa, &paths, e.p) catch break :blk false;
            break :blk true;
        };
        if (!ok) return 0;
        want += 1;
    }
    if (want == 0) return 0;

    // pull the batch and materialize it into the server's workdir
    var rnd: [8]u8 = undefined;
    app.io.random(&rnd);
    var idb: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "pull{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return 0;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    const built = blk: {
        ev.appendSlice(gpa, "{\"kind\":\"file_pull\",\"id\":") catch break :blk false;
        http.jstr(gpa, &ev, id) catch break :blk false;
        if (root.len > 0) {
            ev.appendSlice(gpa, ",\"root\":") catch break :blk false;
            http.jstr(gpa, &ev, root) catch break :blk false;
        }
        ev.appendSlice(gpa, ",\"paths\":[") catch break :blk false;
        ev.appendSlice(gpa, paths.items) catch break :blk false;
        ev.appendSlice(gpa, "]}") catch break :blk false;
        break :blk true;
    };
    if (!built) return 0;
    const start_offset = toolResultsLen(app, conv_dir);
    emitEvent(app, conv_dir, ev.items);
    const resp = awaitClientResult(app, conv_dir, id, ctrl_cursor, start_offset, SYNC_WAIT_S, SYNC_WAIT_S, null, null) orelse return 0;
    defer gpa.free(resp);
    const parsed = std.json.parseFromSlice(cync.PullResp, gpa, resp, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();
    var got: usize = 0;
    for (parsed.value.files) |f| {
        if (!cync.safeSyncPath(f.p) or f.c.len == 0 or f.c.len > cync.FILE_CAP) continue;
        var fb: [1700]u8 = undefined;
        const full = std.fmt.bufPrint(&fb, "{s}/{s}", .{ workdir, f.p }) catch continue;
        if (std.fs.path.dirname(full)) |parent| _ = std.Io.Dir.cwd().createDirPathStatus(app.io, parent, .default_dir) catch {};
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = full, .data = f.c }) catch continue;
        got += 1;
    }
    if (got > 0) {
        var sb: [96]u8 = undefined;
        emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "pulled {d} file(s) from your machine", .{got}) catch "pulled your files");
    }
    return @intCast(got);
}

/// CLIENT MODE, hive done (server→client): a finished cast's files exist only in the SERVER's run dir, but every
/// file tool is delegated to the CLIENT, which reads its own disk — so without a push the veil reads "no such
/// file" over work the hive verifiably produced (then wastefully redoes it), and a remote client never receives
/// the deliverables at all. Called before each delegated tool: once this conversation's cast is terminal and not
/// yet synced, exchange manifests and emit only the CHANGED files as {kind:"file_sync"} frames — the client
/// writes each into its local workdir BEFORE it executes the next delegated tool (frames are processed in
/// order). A same-disk install detects via the probe and transfers nothing. Marker-deduped per run; no-op while
/// the hive still runs or when there is no cast.
fn maybeSyncCastFiles(app: *App, uid: u64, conv: []const u8, conv_dir: []const u8, ctrl_cursor: usize) void {
    var run_buf: [1280]u8 = undefined;
    var run_dir: []const u8 = "";
    if (app.sup.resolve(conv)) |sw| {
        if (sw.uid != uid) return;
        if (!swarmTerminal(app, sw.run_dir, sw.created)) return; // sync once it finishes
        run_dir = copyTo(&run_buf, sw.run_dir) orelse return; // sw points into the registry; copy before slow IO
    } else {
        // Registry entry gone (server restarted after the cast) — fall back to the conventional run dir this
        // conversation's casts always use, and require its terminal DONE marker before syncing anything.
        const at = std.mem.lastIndexOf(u8, conv_dir, "/convs/") orelse return;
        run_dir = std.fmt.bufPrint(&run_buf, "{s}/builds/{s}", .{ conv_dir[0..at], conv }) catch return;
        var db: [1400]u8 = undefined;
        const done = std.fmt.bufPrint(&db, "{s}/DONE", .{run_dir}) catch return;
        _ = std.Io.Dir.cwd().access(app.io, done, .{}) catch return; // never sync a half-written run
    }
    // Dedup marker lives in the RUN dir: a re-cast resets that dir, so the fresh run re-syncs naturally.
    var mb: [1400]u8 = undefined;
    const marker = std.fmt.bufPrint(&mb, "{s}/.filesync_done", .{run_dir}) catch return;
    if (std.Io.Dir.cwd().access(app.io, marker, .{})) |_| return else |_| {}
    // Marker FIRST: a sync that trips a persistent walk error must not re-fire before every future tool call.
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = marker, .data = "" }) catch {};

    var wb: [1400]u8 = undefined;
    const work = std.fmt.bufPrint(&wb, "{s}/work", .{run_dir}) catch return;
    // manifest exchange: shared disk → nothing to push; no answer → push everything (the pre-manifest behavior)
    var si_opt = syncExchange(app, conv_dir, work, ctrl_cursor, "");
    defer if (si_opt) |*si| si.deinit();
    if (si_opt) |si| {
        if (si.shared) return; // the client reads the same directory the hive wrote — already "synced"
    }
    const manifest: ?*const cync.ManifestResp = if (si_opt) |*si| si.manifest() else null;
    const sent = emitRunFiles(app, conv_dir, work, manifest);
    if (sent > 0) {
        var sb: [96]u8 = undefined;
        emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "synced {d} hive file(s) to your workdir", .{sent}) catch "synced hive files");
    }
}

/// Bounded copy of `s` into `buf` (null when it doesn't fit) — for slices whose owner may mutate under us.
fn copyTo(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Emit files under `work` as file_sync frames (recursive, bounded; dot-entries and binaries skipped — a NUL
/// byte can't ride a JSON string). With a client manifest, only files the client is missing (or holds with
/// different bytes) are emitted. Returns how many frames were emitted.
fn emitRunFiles(app: *App, conv_dir: []const u8, work: []const u8, manifest: ?*const cync.ManifestResp) usize {
    var sent: usize = 0;
    var budget: usize = cync.TOTAL_CAP;
    emitRunDirFiles(app, conv_dir, work, "", 0, &sent, &budget, manifest);
    return sent;
}

fn emitRunDirFiles(app: *App, conv_dir: []const u8, abs_dir: []const u8, rel: []const u8, depth: usize, sent: *usize, budget: *usize, manifest: ?*const cync.ManifestResp) void {
    const gpa = app.gpa;
    if (depth > cync.MAX_DEPTH or sent.* >= cync.MAX_FILES or budget.* == 0) return;
    var dir = std.Io.Dir.cwd().openDir(app.io, abs_dir, .{ .iterate = true }) catch return;
    defer dir.close(app.io);
    var it = dir.iterate();
    while (it.next(app.io) catch null) |ent| {
        if (sent.* >= cync.MAX_FILES or budget.* == 0) return;
        if (ent.name.len == 0 or ent.name[0] == '.') continue; // engine scratch (.search_health…) stays server-side
        var ab: [1800]u8 = undefined;
        const child_abs = std.fmt.bufPrint(&ab, "{s}/{s}", .{ abs_dir, ent.name }) catch continue;
        var rb: [512]u8 = undefined;
        const child_rel = (if (rel.len == 0)
            std.fmt.bufPrint(&rb, "{s}", .{ent.name})
        else
            std.fmt.bufPrint(&rb, "{s}/{s}", .{ rel, ent.name })) catch continue;
        switch (ent.kind) {
            .directory => emitRunDirFiles(app, conv_dir, child_abs, child_rel, depth + 1, sent, budget, manifest),
            .file => {
                const data = std.Io.Dir.cwd().readFileAlloc(app.io, child_abs, gpa, .limited(cync.FILE_CAP)) catch continue;
                defer gpa.free(data);
                if (data.len == 0 or data.len > budget.*) continue;
                if (!cync.isTextContent(data)) continue; // binaries can't ride a JSON string
                // DIFF: the client already holds these exact bytes → nothing to transfer
                var hb: [16]u8 = undefined;
                if (clientHasFile(manifest, child_rel, cync.hashHex(data, &hb))) continue;
                scrubUtf8(data);
                var ev: std.ArrayListUnmanaged(u8) = .empty;
                defer ev.deinit(gpa);
                const ok = blk: {
                    ev.appendSlice(gpa, "{\"kind\":\"file_sync\",\"path\":") catch break :blk false;
                    http.jstr(gpa, &ev, child_rel) catch break :blk false;
                    ev.appendSlice(gpa, ",\"content\":") catch break :blk false;
                    http.jstr(gpa, &ev, data) catch break :blk false;
                    ev.append(gpa, '}') catch break :blk false;
                    break :blk true;
                };
                if (!ok) continue;
                emitEvent(app, conv_dir, ev.items);
                budget.* -= data.len;
                sent.* += 1;
            },
            else => {},
        }
    }
}

const ChanScan = struct { result: ?[]u8 = null, acks: u32 = 0 };

/// Byte length of tool_results.jsonl (0 if absent). Captured just BEFORE a request is emitted so the awaiting
/// scan can start past all PRIOR results — the answer to THIS request is always written after that offset.
fn toolResultsLen(app: *App, conv_dir: []const u8) usize {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/tool_results.jsonl", .{conv_dir}) catch return 0;
    defer gpa.free(path);
    const st = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch return 0;
    return std.math.cast(usize, st.size) orelse 0;
}

/// Scan tool_results.jsonl from `*cursor` forward for lines whose "id" matches `id`: a "result" line settles
/// the call (gpa-owned copy in .result); {"ack":true} lines are pickup/heartbeat signals COUNTED into .acks
/// (an ack must never read as an empty result). Only bytes AFTER `*cursor` are read+parsed — the awaiting loop
/// advances the cursor past every complete line it has already seen, so each 150ms poll is O(new bytes), not
/// O(whole file). A trailing PARTIAL line (a large result still being written) is left for the next poll.
/// `*cursor` is advanced past the last complete line consumed. Returns as soon as the matching result is found.
fn scanToolChannel(app: *App, conv_dir: []const u8, id: []const u8, cursor: *usize) ChanScan {
    const gpa = app.gpa;
    var out: ChanScan = .{};
    const path = std.fmt.allocPrint(gpa, "{s}/tool_results.jsonl", .{conv_dir}) catch return out;
    defer gpa.free(path);
    const f = std.Io.Dir.cwd().openFile(app.io, path, .{}) catch return out;
    defer f.close(app.io);
    const size: usize = std.math.cast(usize, f.length(app.io) catch 0) orelse 0;
    if (size <= cursor.*) return out; // nothing new since the last poll
    const want = @min(size - cursor.*, 8 << 20);
    const buf = gpa.alloc(u8, want) catch return out;
    defer gpa.free(buf);
    const n = f.readPositionalAll(app.io, buf, cursor.*) catch return out;
    const data = buf[0..n];
    // consume only up to the last newline: a partial trailing line (mid-write) waits for the next poll
    const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n') orelse return out;
    var line_start: usize = 0;
    while (line_start <= last_nl) {
        const nl = std.mem.indexOfScalarPos(u8, data, line_start, '\n') orelse break;
        const ln = std.mem.trim(u8, data[line_start..nl], " \r\t");
        line_start = nl + 1;
        if (ln.len == 0) continue;
        const R = struct { id: []const u8 = "", result: ?[]const u8 = null, ack: bool = false };
        const p = std.json.parseFromSlice(R, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (!std.mem.eql(u8, p.value.id, id)) continue;
        if (p.value.ack) {
            out.acks += 1;
            continue;
        }
        if (p.value.result) |r| {
            out.result = gpa.dupe(u8, r) catch null;
            cursor.* += line_start; // consume through this line
            return out;
        }
    }
    cursor.* += last_nl + 1; // advance past every complete line read this poll
    return out;
}

/// The completion budget for ONE chat inference, sized off the model's own context window.
///
/// WHY it is not a constant: a chat turn WRITES FILES — a whole page, a whole module — and it emits them as
/// tool-call ARGUMENTS, so the output budget is the size of the largest file the turn can produce in one call.
/// A flat 4096 therefore truncated exactly the turns carrying the most work, and only those: observed live on a
/// 500-line-page build, five consecutive write_file calls cut mid-content, each burning a full ~75s inference
/// (the salvage that catches them is a repair, not a substitute for room to finish).
///
/// The formula is the swarm's, deliberately — run.zig has sized a mind's per-turn budget off the probed window
/// since ctx-scaling landed, and these are the same job. Sharing it means a model with a small window is still
/// asked for proportionally less (it cannot spend 8192 anyway) and the two lanes cannot drift apart again.
/// `NL_MAX_TOKENS` overrides both, with the same clamp.
///
/// The window comes from the CATALOG (modelcfg), not llm.capsSnapshot(): caps is one process-global holding
/// whatever was probed last, so in a server also running casts a chat turn could inherit a local model's
/// window. senseModel is keyed on this turn's own model id and always yields a non-zero ctx_k.
///
/// Raising this also buys the time to spend it, at no extra cost: llm.callTimeoutS derives each call's
/// wall-clock deadline from the budget it asked for, so the deadline widens with the request.
/// An operator kill switch that DEFAULTS ON: only an explicit "0"/"false" turns the feature off. An unset
/// variable must never read as disabled — that is how a reasoning upgrade silently fails to ship.
fn envDisabled(environ: *const std.process.Environ.Map, name: []const u8) bool {
    const v = environ.get(name) orelse return false;
    const t = std.mem.trim(u8, v, " \t\r\n");
    return std.mem.eql(u8, t, "0") or std.ascii.eqlIgnoreCase(t, "false");
}

fn turnTokenBudget(environ: *const std.process.Environ.Map, base_url: []const u8, model: []const u8) u32 {
    if (environ.get("NL_MAX_TOKENS")) |mts| {
        if (std.fmt.parseInt(u32, std.mem.trim(u8, mts, " \t\r\n"), 10)) |v| return std.math.clamp(v, 256, 32768) else |_| {}
    }
    const local_base = std.mem.indexOf(u8, base_url, "127.0.0.1") != null or std.mem.indexOf(u8, base_url, "localhost") != null;
    const ctx_eff: u32 = @min(modelcfg.senseModel(model, local_base).ctx_k * 1024, 32768);
    const scale = std.math.clamp(@as(f32, @floatFromInt(ctx_eff)) / 32768.0, 0.25, 1.0);
    return @max(1024, @as(u32, @intFromFloat(8192.0 * scale)));
}

/// Bytes of WORKING SPAN a turn may accumulate before compaction must fold it, for a turn whose prompt is
/// CONSUMED by `model`. `fixed_bytes` is the part of the prompt compaction cannot touch — the assembled
/// prefix (system blocks + bounded history) plus the tool-schema array.
///
/// Why this exists. The three working-span constants are absolute byte counts, measured on a large window
/// and never related to the window actually being served. On the built-in 12B that serves 8192 tokens
/// (~28 KB of text) they are all bigger than the whole window: compaction does not even TRIGGER until the
/// span passes 24 KB, and the tail it preserves is 32 KB. Add a 20-tool schema array (~13 KB) and the
/// system blocks (~6 KB) and the prompt is over the window long before the fold that was supposed to
/// prevent that can fire. The provider then rejects the request outright — `in:0, out:0` — which is the
/// "prompt exceeds the serving context window" seen in conv c6a6e014f.
///
/// It also disabled the memory path. compactWorking is what flushes queued observes into neuron-db before
/// dropping bytes (MEMORY-BEFORE-FORGETTING). Never reaching the trigger means a small model never banks
/// anything and never gets it back through assoc recall — the DB is wired up correctly and simply never
/// runs for the tier that needs it most.
///
/// LARGE WINDOWS ARE UNTOUCHED, deliberately: when the window can already hold the existing constants this
/// returns WORKING_COMPACT_BYTES unchanged, so every model that works today keeps byte-identical behaviour.
/// Only a window too small for them tightens, and never below a floor that still fits one real tool round.
///
/// The window comes from the LIVE ENGINE when there is one to ask (servingWindowTokens), and only then from
/// the static catalog. The catalog states a model's nominal window; the built-in engine's fit ladder decides
/// the real one at load time and can land anywhere from the configured value down to a 4096 floor depending
/// on the card. Budgeting a turn against a window the box never allocated is how a prompt that "fits" is
/// rejected by the engine that has to hold it.
fn servingWindowTokens(base_url: []const u8) ?usize {
    const b = std.mem.trim(u8, base_url, " \r\n\t");
    // The sentinel is resolved to a loopback URL carrying PATH_PREFIX before a turn runs, so match both
    // forms; anything else is a provider whose window this process does not serve and cannot know.
    if (!builtin_mod.isSentinelBase(b) and std.mem.indexOf(u8, b, builtin_mod.PATH_PREFIX ++ "/") == null) return null;
    const live = builtin_mod.servingCtx();
    return if (live == 0) null else live; // 0 = not loaded yet ⇒ fall back to the catalog
}

test "the live served window is read for the built-in engine and for nothing else" {
    const saved = builtin_mod.servingCtx();
    defer builtin_mod.setServingCtx(saved);

    // nothing loaded: every caller keeps the catalog path it had before this existed
    builtin_mod.setServingCtx(0);
    try std.testing.expect(servingWindowTokens("builtin") == null);
    try std.testing.expect(servingWindowTokens("http://127.0.0.1:8791/builtin/v1") == null);

    // the ladder landed at 9216 — the built-in's two URL forms must both see it
    builtin_mod.setServingCtx(9216);
    try std.testing.expectEqual(@as(?usize, 9216), servingWindowTokens("builtin"));
    try std.testing.expectEqual(@as(?usize, 9216), servingWindowTokens("http://127.0.0.1:8791/builtin/v1"));
    try std.testing.expectEqual(@as(?usize, 9216), servingWindowTokens(" builtin\n")); // trimmed

    // …and NOTHING else may inherit it. A local Ollama shares the loopback host but not the engine, and a
    // BYOK provider's window is not this process's business — both keep the static catalog.
    try std.testing.expect(servingWindowTokens("http://127.0.0.1:11434/v1") == null);
    try std.testing.expect(servingWindowTokens("http://localhost:1234/v1") == null);
    try std.testing.expect(servingWindowTokens("https://api.openai.com/v1") == null);
    try std.testing.expect(servingWindowTokens("https://api.anthropic.com/v1") == null);
    try std.testing.expect(servingWindowTokens("") == null);

    // and the budget itself: a BYOK model keeps WORKING_COMPACT_BYTES exactly, live window or not
    try std.testing.expectEqual(cctx.WORKING_COMPACT_BYTES, workingBudgetBytes("https://api.anthropic.com/v1", "claude-opus-4-8", 20_000));
    // while the built-in, told the truth about a 9216-token window, tightens below it
    try std.testing.expect(workingBudgetBytes("http://127.0.0.1:8791/builtin/v1", "the-veil-12b", 20_000) < cctx.WORKING_COMPACT_BYTES);
}
/// Floor for the scaled recency window. Below this a turn cannot see its own immediate past — the last question
/// and its answer — and the model re-asks what it just resolved, so shrinking past it trades one context failure
/// for a worse one.
const HISTORY_WINDOW_MIN_BYTES: usize = 8 * 1024;
/// Measured size of the assembled system blocks (SYSTEM_PROMPT_COMPACT measures ~2.8 KB; the full prompt and the
/// per-turn directives push it to roughly this). An estimate, used only to size a budget DOWN.
const SYSTEM_BLOCKS_EST_BYTES: usize = 4 * 1024;
/// Allowance for the PROMPT WORKSPACE (recall, durable memory, the tool digest, the belt line, the ledger),
/// which the first cut of this budget omitted entirely — a real error, not a rounding one. workspace.zig budgets
/// PREFIX 12 KiB + VARYING 8 KiB + SUFFIX 2 KiB = 22.5 KiB of ceiling, and a live turn on this machine admitted
/// 6,225 B of it. The ceiling is a bound on the pathological stack, not a forecast, so budgeting against it would
/// peg every small model at the history floor for a stack it will not build; this is the measured-typical figure,
/// rounded up. It is an ESTIMATE, and it is why warnIfPromptCannotFit reports "~" sizes rather than exact ones.
const WORKSPACE_EST_BYTES: usize = 8 * 1024;

/// Bytes of RECENCY WINDOW that may be replayed, for a prompt CONSUMED by `model` at `base_url`.
///
/// cctx.HISTORY_WINDOW_BYTES is a flat 28 KiB written against a 32k-token model, and nothing ever related it to
/// the window actually being served. On the built-in 12B serving 8192 tokens (~24.5 KB at the pessimistic 3
/// bytes/token this file uses elsewhere) the replayed history ALONE is larger than the entire context, so the
/// prompt is over the line before a single tool result — the provider rejects it outright (`in:0, out:0`) and the
/// turn surfaces as "(no reply — the model returned an empty or malformed response this turn)".
///
/// HONEST ABOUT WHAT THIS DOES NOT FIX: on that same 12B the rest of the prefix — tool schemas (~13 KB, the
/// dominant term and larger than everything else combined), the injected summary, the goal pin, and the output
/// reserve — already exceeds the window with a ZERO-byte history. So this returns its floor there and the prompt
/// still does not fit. Scaling the window is necessary and not sufficient; closing the remainder means serving a
/// smaller tool belt to tiny windows, which is a product decision, not a budgeting one. The caller logs the
/// shortfall so that overflow is diagnosed rather than silent.
///
/// `tools_bytes` is the REAL serialized tool array, never a tier estimate — the belt already varies with recipe
/// grants and plugin schemas, and estimating it would overflow on exactly the turns that granted something.
///
/// Quantized DOWN to 4 KiB: `covered` persists across turns, so a window that wobbled by a few hundred bytes
/// because the belt gained one grant would re-open an uncovered band every time it shrank.
fn historyWindowBytes(base_url: []const u8, model: []const u8, tools_bytes: usize) usize {
    const local = std.mem.indexOf(u8, base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, base_url, "localhost") != null;
    const win_tokens: usize = servingWindowTokens(base_url) orelse
        @as(usize, modelcfg.senseModel(model, local).ctx_k) * 1024;
    const win_bytes = win_tokens * 3; // same deliberate pessimism as workingBudgetBytes — under-estimate and fold early
    // everything the prompt must hold before one byte of replayed history
    const other = SYSTEM_BLOCKS_EST_BYTES + WORKSPACE_EST_BYTES + (cctx.SUMMARY_INJECT_CAP + 256) +
        cctx.GOAL_PIN_CAP + turnOutputReserveBytes + tools_bytes + WORKING_MIN_BUDGET_BYTES;
    if (win_bytes <= other) return HISTORY_WINDOW_MIN_BYTES;
    const avail = win_bytes - other;
    if (avail >= cctx.HISTORY_WINDOW_BYTES) return cctx.HISTORY_WINDOW_BYTES; // roomy: today's behaviour, byte-identical
    return @max(HISTORY_WINDOW_MIN_BYTES, (avail / (4 * 1024)) * (4 * 1024));
}

/// Say so when the assembled prompt cannot fit the served window even at the smallest history this engine will
/// replay. Until now that condition produced no signal at all: the request went out, the provider rejected it
/// whole, and the turn ended "(no reply — the model returned an empty or malformed response this turn)" — a
/// message that describes the model as having misbehaved when in fact it was never given a prompt it could read.
/// One line naming the shortfall and the term responsible turns a mystery into arithmetic.
fn warnIfPromptCannotFit(base_url: []const u8, model: []const u8, tools_bytes: usize, hist_win: usize) void {
    const local = std.mem.indexOf(u8, base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, base_url, "localhost") != null;
    const win_tokens: usize = servingWindowTokens(base_url) orelse
        @as(usize, modelcfg.senseModel(model, local).ctx_k) * 1024;
    const win_bytes = win_tokens * 3;
    const need = SYSTEM_BLOCKS_EST_BYTES + WORKSPACE_EST_BYTES + (cctx.SUMMARY_INJECT_CAP + 256) +
        cctx.GOAL_PIN_CAP + turnOutputReserveBytes + tools_bytes + WORKING_MIN_BUDGET_BYTES + hist_win;
    if (need <= win_bytes) return;
    memlog.warn("context: this turn's prompt needs ~{d} KB but {s} serves ~{d} KB — over by ~{d} KB with history already at its {d} KB floor; the tool schemas alone are ~{d} KB. Expect the provider to reject the request (it surfaces as an empty reply).", .{
        need / 1024, model, win_bytes / 1024, (need - win_bytes) / 1024, hist_win / 1024, tools_bytes / 1024,
    });
}

fn workingBudgetBytes(base_url: []const u8, model: []const u8, fixed_bytes: usize) usize {
    const local = std.mem.indexOf(u8, base_url, "127.0.0.1") != null or
        std.mem.indexOf(u8, base_url, "localhost") != null;
    const win_tokens: usize = servingWindowTokens(base_url) orelse
        @as(usize, modelcfg.senseModel(model, local).ctx_k) * 1024;
    // 3 bytes/token is deliberately pessimistic: measured 3.5 on this corpus (5577 tokens for 19639 bytes),
    // and under-estimating the window is the safe direction — it folds early rather than overflowing.
    const win_bytes = win_tokens * 3;
    const reserve = @as(usize, turnOutputReserveBytes) + fixed_bytes;
    if (win_bytes <= reserve) return WORKING_MIN_BUDGET_BYTES;
    const available = win_bytes - reserve;
    if (available >= WORKING_HARD_FOLD_BYTES) return cctx.WORKING_COMPACT_BYTES; // roomy: today's behaviour
    return @max(WORKING_MIN_BUDGET_BYTES, @min(cctx.WORKING_COMPACT_BYTES, available));
}

// The assistant-object head + reasoning_content splice locator now live in llm.zig
// (llm.ASSISTANT_OBJ_HEAD / llm.reasoningSpliceOffset, tested there): the swarm's mind loop turned out to
// send the SAME structured tool_calls turn and needs the SAME heal, so llm.zig — which already owns the
// quirk storage and the error predicate — owns the shared byte-format invariant too. Each loop still owns
// its own fix, because each owns its reasoning text.

/// AUX-CALL dispatch (loop picker / rescue / lesson / course / summary / stuck / afknext / reflect) with
/// the thinking-mode reasoning-echo quirk handled for the AUX model. These payloads embed msgTail slices
/// of conv_buf (or build their own assistant turns), so assistant turns ride along shaped for the CODING
/// model's learned quirk — an aux model on a thinking-mode endpoint 400s the whole call when a bare turn
/// rides in ("must be passed back"), and before this helper every such aux call silently lost its result
/// (worse for the drive picker, whose failure ends the TURN). Mirrors run.zig's completeRung: pre-splice
/// when the quirk is already learned for THIS model; on a fresh echo-400, learn it for the model that
/// actually erred and retry once, spliced. Aux slices hold no saved reasoning, so every echo is the
/// verbatim "" (see llm.withReasoningEcho). Aux calls advertise no tools, hence the fixed "".
fn completeAux(app: *App, dir: []const u8, tag: []const u8, base_url: []const u8, key: []const u8, model: []const u8, messages_json: []const u8, max_tokens: u32, temperature: f32) llm.Step {
    const gpa = app.gpa;
    if (llm.reasoningEchoFor(app.io, model)) {
        if (llm.withReasoningEcho(gpa, messages_json, "")) |spliced| {
            defer gpa.free(spliced);
            return llm.complete(gpa, app.io, dir, tag, base_url, key, model, spliced, "", max_tokens, temperature);
        }
    }
    var step = llm.complete(gpa, app.io, dir, tag, base_url, key, model, messages_json, "", max_tokens, temperature);
    if (!step.ok and llm.isReasoningEchoError(step.content)) {
        llm.learnReasoningEcho(app.io, model); // learn FIRST, keyed on THIS model — even a failed retry leaves later dispatches pre-splicing
        if (llm.withReasoningEcho(gpa, messages_json, "")) |spliced| {
            defer gpa.free(spliced);
            step.deinit(gpa);
            return llm.complete(gpa, app.io, dir, tag, base_url, key, model, spliced, "", max_tokens, temperature);
        }
    }
    return step;
}

fn runInnerAgentic(
    app: *App,
    uid: u64,
    conv: []const u8,
    conv_dir: []const u8,
    run_root: []const u8,
    trio: ModelTrio,
    conv_buf: *std.ArrayListUnmanaged(u8),
    ctx: *tools.ToolCtx,
    steer_cursor: *usize,
    tool_obs: *std.ArrayListUnmanaged([]u8),
    tool_perf: *toolperf.Acc, // per-machine tool latency/reliability learner (records each executed tool)
    tool_client: bool,
    // TURN-scoped consecutive never-acked delegation timeouts (owned by runTurn, like tools_spent): once it
    // reaches CLIENT_GONE_AFTER, delegateTool answers the turn's remaining client calls instantly instead of
    // re-paying the ack timeout per call. Turn-scoped so a reconnected desk gets a fresh probe next turn.
    no_ack_streak: *u32,
    // TURN-scoped consecutive dud fetches (not-found / bot-challenge pages) — the guessed-URL spiral counter;
    // see DUD_FETCH_STREAK at looksLikeNotFound. Owned by runTurn so the streak survives drive steps.
    dud_fetches: *u32,
    // TURN-scoped consecutive poll timeouts — the stuck-in-a-wait counter; see POLL_TIMEOUT_STREAK.
    poll_timeouts: *u32,
    tools_spent: *usize, // turn-scoped executed-call counter (shared across drive steps)
    tool_budget: usize, // ceiling for scheduled runs; maxInt for interactive chats (a human holds Stop)
    // REPEAT-CALL GUARDS, both TURN-scoped (owned by the drive loop — pass-local state forgot every repeat
    // when the next drive step re-entered this function, so a stuck turn re-ran the same exploration step
    // after step). `echo_guard` covers EVERY tool by (name,args)→result-hash: identical call + identical
    // result repeatedly = a loop; a changed result resets the count, so re-reads after writes stay free.
    // `call_ledger` is the stricter network set (see dedupableTool): a model in a research spiral re-issues
    // the SAME network call over and over — observed live: 40+ duplicate web_search/web_fetch calls in one
    // scheduled run. The result is already in context; a repeat is answered with a pointed refusal.
    echo_guard: *[24]EchoRec,
    call_ledger: *std.ArrayListUnmanaged(u64),
    // FILE LEDGER (turn+conv-scoped, owned by runTurn): landed file mutations captured at this pass's
    // dispatch point — the ground-truth half of the fine-needle memory weave.
    file_ledger: *FileLedger,
    // FOREIGN-KNOWLEDGE CONFLICT inputs (turn-scoped, owned by runTurn): the cross-task hive text injected
    // this turn, and the once-per-turn latch for its conflict note.
    foreign_mem: []const u8,
    foreign_warned: *bool,
    // SEARCH-QUERY FORMULATION inputs (turn-scoped, owned by runTurn): what this turn is FOR (the planner's
    // objective when there is one, else the user's own words), and the queries already searched this turn.
    intent: []const u8,
    search_log: *std.ArrayListUnmanaged([]u8),
    // This turn's advertised tools array — the caller's static CAPS variant plus any granted recipe schemas,
    // built ONCE per turn in runTurn (turn-stable, byte-identical across drive passes → prefix-cache safe).
    turn_tools: []const u8,
) InnerResult {
    const gpa = app.gpa;
    // Bind the coding/base triple to the names this body already uses (the main agentic stream is the CODING
    // call), and pick `think` for the context-housekeeping calls (compact/summary). orchTool receives the full
    // trio (it forwards to schedule_task, which persists all three). See ModelTrio for the fallback rule.
    const base_url = trio.coding.base_url;
    const key = trio.coding.key;
    const model = trio.coding.model;
    const think = trio.pick(.thinking);
    const empty: []u8 = &[_]u8{};
    // the last narrated content across tool iterations — the salvage if we exhaust MAX_ITERS or a stop lands mid-loop.
    var last_content: []u8 = empty;
    defer if (last_content.len > 0) gpa.free(last_content);
    var any_tool = false; // did any tool run this pass? gates the drive loop's LOOP_QUESTION for pure-prose answers
    // FAILURE-STREAK deliberation state (this drive step): consecutive failed OUTCOMES of the same tool.
    // The echo guard catches identical-RESULT loops; this catches a model grinding one tool through
    // DIFFERENT failing attempts (observed live: six run_python tracebacks in a row for work write_file/
    // list_dir do natively) — the moment deliberate tool WEIGHING should happen and doesn't.
    var fail_streak_tool: u64 = 0;
    var fail_streak: u32 = 0;
    // LOOP HARD STOP. The echo guard refuses an individual call once it has returned the identical
    // result echo_limit times, but refusing a call is not the same as ending a turn: a model that
    // CYCLES between tools never trips one signature hard enough to matter and just runs to MAX_ITERS.
    // Observed live (conv c6a6df468): edit_file → run_python → run_tests → read_file → edit_file …,
    // every edit rejected for a malformed anchor, the deliverable already written and working, and the
    // desk sat there looking hung until the round cap.
    //
    // Counted per ITERATION, not per refused call: an inference whose batch contained any identical-call
    // refusal (echo guard, or a cross-batch ledger repeat) is one strike; an inference that refused
    // nothing and executed something clears the streak. The earlier shape — every non-refused CALL
    // zeroed the count — quietly disarmed the stop for the very loops it was built for: a ledger-refused
    // search spiral cleared its own strikes (a dedupable call executes exactly once, so it is never
    // echo_blocked and every repeat took the clearing branch), and the c6a6df468 cycle survived whenever
    // one member returned nondeterministic bytes (test timings, tracebacks) and so kept "executing".
    // Per-iteration strikes close both while keeping the c6a75df8b forgiveness intact: a model that read
    // the refusal and genuinely moved on produces a refusal-free next pass, which clears it. Reaching the
    // stop still means the warnings were ignored across LOOP_STOP_REFUSALS consecutive inferences —
    // a model making real progress never sees it.
    var loop_refusals: u32 = 0;

    // Everything already in conv_buf when this pass begins (system + bounded history + prior drive steps). This
    // pass's tool-call/result growth is measured against it so within-turn compaction can bound just the growth.
    var base_len = conv_buf.items.len;
    // THINKING-MODE PREFIX ECHO: once the echo quirk is learned for this model, heal the PREFIX before
    // the first inference. Seeded history and prior passes' settled answers are PLAIN assistant turns,
    // and the newer enforcement rejects ANY assistant message lacking reasoning_content — not just
    // tool-call turns (the replayed-history failure of anomalyco/opencode#24104; the landed fix there
    // injects the "" echo on all assistant history messages). base_len follows the healed length, so
    // within-pass compaction keeps bounding exactly this pass's growth.
    if (llm.reasoningEchoFor(app.io, model)) {
        if (llm.withReasoningEcho(gpa, conv_buf.items, "")) |healed| {
            conv_buf.deinit(gpa);
            conv_buf.* = .fromOwnedSlice(healed);
            base_len = conv_buf.items.len;
        }
    }

    // The browser (+ pixel) and MCP tools ride on every chat turn — the "client-side by default" model: a
    // client's own machine can drive a browser and reach its installed MCP servers, so the chat should always
    // know it has the capability (the client controls visibility via its browser-window setting). Per the
    // accessibility directive ("always include every tool") there is no env/tier gate here either, so a tool can
    // never silently drop out on a machine whose flag was set mid-session; the swarm-mind schema in run.zig keeps
    // its own gate. ~10 extra tool defs of prefill is the price of the capability being available on demand.
    //
    // CAPS is the one thing that does gate, and only because it removes nothing that could have run: a .sandboxed
    // caller's calls are refused by tools.execute's gate before any tool logic, so advertising those defs buys
    // prefill and dead round-trips and nothing else. Static per caller — see TURN_TOOLS_SANDBOXED. `turn_tools`
    // is that caller-static variant (plus any granted recipe schemas) resolved ONCE in runTurn and passed in, so
    // every drive pass advertises the SAME bytes (grants are turn-stable; see buildTurnTools).

    // THINKING-MODE reasoning echo-back (self-heal). DeepSeek's thinking mode 400s a tool-call round whose
    // assistant turn omits reasoning_content ('...must be passed back'), while the classic reasoner 400s the
    // OPPOSITE way — so there is no safe universal default. Build assistant turns WITHOUT it; on that exact
    // error, learn the quirk for this model, splice the saved reasoning into the offending turn, and retry.
    // Thereafter every turn echoes it inline (reasoningEchoFor): one failed round-trip per model per session.
    var asst_reasoning: []u8 = empty; // the last assistant tool-call turn's reasoning, duped to outlive the
    defer if (asst_reasoning.len > 0) gpa.free(asst_reasoning); // step (the buffer has no reasoning to recover)
    // Heals are BOUNDED per pass, not one-shot: a mid-pass compaction or append can mint a NEW bare
    // assistant turn after a heal, and each heal removes every bare turn it can see — so re-healing on
    // fresh bare state is progress, not a spin. A 400 with nothing bare left falls through to the error.
    var reasoning_heals: u32 = 0;
    var iter: usize = 0;
    while (iter < MAX_ITERS) : (iter += 1) {
        // COOPERATIVE CONTROL (before each inference): a stop aborts with whatever narration we have; a steer is
        // folded straight into conv_buf as a user turn so THIS upcoming inference already honors it — folding only
        // at the outer drive-step boundary would delay it by however long a tool loop runs (minutes).
        switch (drainChatControl(app, conv_dir, steer_cursor, conv_buf)) {
            .stop => return .{ .outcome = .stopped, .content = gpa.dupe(u8, last_content) catch empty },
            .none => {},
        }

        // LOOP HARD STOP (see loop_refusals above). Checked HERE — before spending another inference —
        // because the refusals that got us here already proved the next one has nothing new to work with.
        // End the turn honestly rather than grinding to MAX_ITERS: say the loop was cut, keep whatever the
        // model did narrate, and point at the file ledger, which records what genuinely landed on disk (in
        // the observed case the deliverable was already written and working while the model kept retrying).
        if (loop_refusals >= LOOP_STOP_REFUSALS) {
            emitKV(app, conv_dir, "status", "text", "loop guard: stopped this turn — the same calls kept returning the same results");
            return .{
                .outcome = .stopped,
                .content = gpa.dupe(u8, last_content) catch empty,
                .tools_ran = any_tool,
                .engine_note = gpa.dupe(u8, LOOP_STOP_NOTE) catch empty,
            };
        }

        // STREAMING: the model's reply + reasoning type out via streamOnDelta as {kind:token|reasoning,delta}
        // frames. The returned Step is the SAME accumulated shape complete() gives (content + reasoning +
        // tool_calls), so everything below is unchanged — and completeStream falls back to complete() itself
        // on any streaming trouble, so a backend that can't stream still works (on_delta just never fires).
        var sctx = StreamCtx{ .app = app, .conv_dir = conv_dir, .ctrl_cursor = steer_cursor.* };
        var chat_cm = meterBegin(app.io);
        var step = llm.completeStream(gpa, app.io, run_root, "chat", base_url, key, model, conv_buf.items, turn_tools, turnTokenBudget(ctx.environ, base_url, model), 0.7, &sctx, streamOnDelta, streamShouldAbort);
        defer step.deinit(gpa);
        streamFlush(&sctx); // emit the last buffered <FLUSH_CHARS chunk so the tail of the reply/reasoning isn't lost
        // AFTER streamFlush, deliberately: the desk treats a delta that follows a non-delta frame as an inference
        // boundary, so the `llm` frame has to land where one genuinely is — past the tail of this reply, not
        // interleaved into it. (It is the last thing this inference emits either way.)
        //
        // This assignment is what makes this — the ONLY streaming call of the ten — eligible to report
        // `streamed:true`. It stays 0, and the frame stays false, when completeStream fell back to a blocking
        // complete() or the reply carried no deltas at all: in either case there is no first byte we observed.
        chat_cm.fb_ms = sctx.fb_ms;
        meterEnd(app, chat_cm, "chat", .coding, model, step.ok);

        // STOP DURING STREAMING: the abort hook killed the stream mid-generation. Commit the partial that already
        // streamed to the user (step.content) as the stopped narration and end the turn — don't fall through to
        // treat the truncated reply as a settled answer or drive on it.
        if (stopRequestedSince(app, conv_dir, steer_cursor.*)) {
            const partial = if (step.content.len > 0) step.content else last_content;
            return .{ .outcome = .stopped, .content = gpa.dupe(u8, partial) catch empty };
        }

        if (!step.ok) {
            // THINKING-MODE HEAL: this request was rejected because an assistant turn somewhere in it
            // omitted reasoning_content — the newest tool-call turn, an older one, or a PLAIN turn in the
            // PREFIX (seeded history / a prior pass's settled answer: the newer enforcement rejects any
            // bare assistant message, not just tool-call turns — opencode#24104). Learn the quirk, splice
            // the echo into EVERY bare assistant turn of the WHOLE live buffer — the newest gets the
            // saved reasoning verbatim (asst_reasoning may be ""), all others the "" echo — and retry the
            // same inference. Prefix and span are healed as separate pieces so base_len can follow the
            // prefix's growth and the span/prefix boundary stays on a turn edge for compactWorking.
            if (reasoning_heals < 3 and llm.isReasoningEchoError(step.content)) heal: {
                const pre = conv_buf.items[0..base_len];
                const span = conv_buf.items[base_len..];
                const hp = llm.withReasoningEcho(gpa, pre, "");
                defer if (hp) |p| gpa.free(p);
                const hs = llm.withReasoningEcho(gpa, span, asst_reasoning);
                defer if (hs) |s2| gpa.free(s2);
                if (hp == null and hs == null) break :heal; // nothing bare anywhere — surface the error below
                reasoning_heals += 1;
                llm.learnReasoningEcho(app.io, model); // learn FIRST: even an OOM below leaves later turns echoing inline
                // Atomic swap: conv_buf OUTLIVES this pass (the drive loop reuses it), so a partial
                // in-place rewrite on OOM must not be able to corrupt it — either the whole healed
                // buffer lands or the old one stays.
                const new_base = if (hp) |p| p.len else base_len;
                if (std.mem.concat(gpa, u8, &.{ if (hp) |p| p else pre, if (hs) |s2| s2 else span })) |joined| {
                    conv_buf.deinit(gpa);
                    conv_buf.* = .fromOwnedSlice(joined);
                    base_len = new_base;
                } else |_| break :heal;
                continue; // re-drains control, re-infers on the corrected conv_buf
            }
            {
                // Provider errors quote ACCOUNT MATERIAL back at us — observed live: a suspension error
                // carrying the org id and an "<ak-…>" key alias landed verbatim in the durable event log and
                // the desk transcript. The error's meaning survives masking; the identifiers don't need to.
                var eb2: [420]u8 = undefined;
                emitKV(app, conv_dir, "error", "err", scrubAccountIds(&eb2, clipBytes(step.content, 400)));
            }
            return .{ .outcome = .hard_error, .content = empty };
        }
        // reasoning normally streams via the .reasoning deltas above. But if completeStream FELL BACK to a
        // non-streaming complete() (no deltas fired — e.g. a hosted tool-call step, or a backend that ignored
        // stream:true), emit the reasoning once here so the desk still shows the thinking (no regression).
        if (!sctx.streamed and step.reasoning.len > 0)
            emitKV(app, conv_dir, "reasoning", "delta", clipBytes(step.reasoning, 4000));

        // MARKUP TOOL-CALL RECOVERY: a local gpt-oss/DeepSeek model sometimes emits its tool call as Claude-style
        // XML markup in the CONTENT channel (<｜｜DSML｜｜invoke name="…">) instead of a structured tool_calls entry.
        // The transport then returns it as plain content with NO calls, so no tool runs, the markup leaks into the
        // reply, and the drive loop churns on it. Recover the call(s) from the markup + strip it from the content,
        // so the tool actually executes and the turn makes progress.
        if (step.calls.len == 0 and cctx.looksLikeToolMarkup(step.content)) {
            if (cctx.recoverMarkupCalls(gpa, step.content)) |rec| {
                var built: std.ArrayListUnmanaged(llm.ToolCall) = .empty;
                for (rec.calls) |rc| {
                    // MINT, never "": markup never carries an id, and an id-less call cannot round-trip the
                    // client bridge (/tool_result refuses empty ids). Same contract as llm.zig's parse sites —
                    // this recovery path is exactly the local-model shape that needs the bridge to work.
                    const idc = llm.mintCallId(gpa) catch {
                        gpa.free(rc.name);
                        gpa.free(rc.args);
                        continue;
                    };
                    built.append(gpa, .{ .id = idc, .name = rc.name, .args = rc.args }) catch {
                        gpa.free(idc);
                        gpa.free(rc.name);
                        gpa.free(rc.args);
                    };
                }
                gpa.free(rec.calls); // wrapper array only; name/args ownership moved into `built` (or freed above)
                if (built.items.len == 0) {
                    built.deinit(gpa);
                    gpa.free(rec.stripped); // every append OOM-failed — leave the original content untouched
                } else if (built.toOwnedSlice(gpa)) |owned| {
                    gpa.free(step.content);
                    step.content = rec.stripped; // narration with the markup block removed
                    step.calls = owned; // adopted into the Step; freed by step.deinit
                    var nb: [72]u8 = undefined;
                    emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&nb, "recovered {d} tool call(s) from model markup", .{owned.len}) catch "recovered tool call from markup");
                } else |_| {
                    // OOM finalizing the slice — free each built call + the backing array + the stripped content.
                    for (built.items) |c| {
                        gpa.free(c.id);
                        gpa.free(c.name);
                        gpa.free(c.args);
                    }
                    built.deinit(gpa);
                    gpa.free(rec.stripped);
                }
            }
        }

        if (step.calls.len == 0) // no tool calls — this settled answer is the turn's reply for this drive step.
            return .{ .outcome = .settled, .content = gpa.dupe(u8, step.content) catch empty, .tools_ran = any_tool };

        any_tool = true; // this iteration is running tools — the turn did agentic work, so the drive loop may continue

        // remember the last narrated content in case we run out of iterations mid-tool-loop
        if (step.content.len > 0) {
            if (last_content.len > 0) gpa.free(last_content);
            last_content = gpa.dupe(u8, step.content) catch empty;
        }

        // append the assistant tool_call turn to the running context (standard OpenAI tool_calls shape) ...
        // Record where this turn starts + dup its reasoning, so the heal above can splice reasoning_content in
        // if the NEXT inference is rejected for its absence. Freed on replace (and by the defer at pass exit).
        // Dup this turn's reasoning so the heal can splice it back if the NEXT inference is rejected for its
        // absence (the buffer itself carries no reasoning to recover). Freed on replace + by the pass defer.
        if (asst_reasoning.len > 0) gpa.free(asst_reasoning);
        asst_reasoning = gpa.dupe(u8, step.reasoning) catch empty;
        conv_buf.appendSlice(gpa, llm.ASSISTANT_OBJ_HEAD) catch return .{ .outcome = .hard_error, .content = empty };
        // Echo reasoning_content inline once the model is known to require it (learned via the heal). BEFORE
        // content, so this path and the splice (llm.withReasoningEcho) insert at the same offset. Echoed even
        // when this turn carries NO reasoning text (a tool-continuation round often streams none), and then
        // VERBATIM as "": DeepSeek itself returns "" on such turns and expects exactly that passed back —
        // the constraint is the field's presence on every assistant turn, not its truthiness (opencode#24146).
        if (llm.reasoningEchoFor(app.io, model)) {
            conv_buf.appendSlice(gpa, ",\"reasoning_content\":") catch return .{ .outcome = .hard_error, .content = empty };
            http.jstr(gpa, conv_buf, step.reasoning) catch return .{ .outcome = .hard_error, .content = empty };
        }
        conv_buf.appendSlice(gpa, ",\"content\":") catch return .{ .outcome = .hard_error, .content = empty };
        http.jstr(gpa, conv_buf, step.content) catch return .{ .outcome = .hard_error, .content = empty };
        conv_buf.appendSlice(gpa, ",\"tool_calls\":[") catch return .{ .outcome = .hard_error, .content = empty };
        for (step.calls, 0..) |c, i| {
            if (i > 0) conv_buf.append(gpa, ',') catch return .{ .outcome = .hard_error, .content = empty };
            conv_buf.appendSlice(gpa, "{\"id\":") catch return .{ .outcome = .hard_error, .content = empty };
            http.jstr(gpa, conv_buf, c.id) catch return .{ .outcome = .hard_error, .content = empty };
            conv_buf.appendSlice(gpa, ",\"type\":\"function\",\"function\":{\"name\":") catch return .{ .outcome = .hard_error, .content = empty };
            http.jstr(gpa, conv_buf, c.name) catch return .{ .outcome = .hard_error, .content = empty };
            conv_buf.appendSlice(gpa, ",\"arguments\":") catch return .{ .outcome = .hard_error, .content = empty };
            http.jstr(gpa, conv_buf, c.args) catch return .{ .outcome = .hard_error, .content = empty };
            conv_buf.appendSlice(gpa, "}}") catch return .{ .outcome = .hard_error, .content = empty };
        }
        conv_buf.appendSlice(gpa, "]}") catch return .{ .outcome = .hard_error, .content = empty };

        // ... then run each call, narrate + observe its result, and append its result turn. A steer that lands
        // mid-batch is drained into `pending_steer` (a user turn may NOT sit between an assistant tool_calls turn
        // and its tool results — providers 400 on that) and spliced in AFTER the batch, before the next inference.
        var pending_steer: std.ArrayListUnmanaged(u8) = .empty;
        defer pending_steer.deinit(gpa);
        // GROUND-TRUTH CONFLICT note (anti-confabulation): built mid-batch, spliced AFTER the batch — a user
        // turn may not sit between an assistant tool_calls turn and its results (same rule as pending_steer).
        var post_note: std.ArrayListUnmanaged(u8) = .empty;
        defer post_note.deinit(gpa);
        // LOOP STRIKE state for THIS inference's batch (see loop_refusals above): did any call take an
        // identical-call refusal, and did any call genuinely execute? Resolved once at the batch end.
        var iter_refused = false;
        var iter_executed = false;
        // Ledger length when this batch began: a repeat whose FIRST occurrence sits in this same batch was
        // emitted before any "do NOT re-run" feedback existed, so it must not strike (see the guard below).
        const ledger_at_batch = call_ledger.items.len;
        for (step.calls, 0..) |c, ci| {
            // COOPERATIVE CONTROL (between tool calls): a single inference can request many tools, each taking
            // seconds — checking only per-inference lets a Stop (or a steer) wait minutes. A stop aborts with the
            // narration so far; a steer SKIPS the still-queued calls (each still gets a result row — the shape
            // requires one per call id) so the next inference honors it in seconds.
            switch (drainChatControl(app, conv_dir, steer_cursor, &pending_steer)) {
                .stop => return .{ .outcome = .stopped, .content = gpa.dupe(u8, last_content) catch empty },
                .none => {},
            }
            if (pending_steer.items.len > 0) {
                var skipped: usize = 0;
                for (step.calls[ci..]) |sk| {
                    var skobj: std.ArrayListUnmanaged(u8) = .empty;
                    defer skobj.deinit(gpa);
                    const sk_ok = blk: {
                        skobj.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":") catch break :blk false;
                        http.jstr(gpa, &skobj, sk.id) catch break :blk false;
                        skobj.appendSlice(gpa, ",\"content\":\"(skipped — the user steered the conversation mid-batch; honor their newest message first)\"}") catch break :blk false;
                        conv_buf.appendSlice(gpa, skobj.items) catch break :blk false;
                        break :blk true;
                    };
                    if (!sk_ok) return .{ .outcome = .hard_error, .content = empty };
                    skipped += 1;
                }
                var nb: [96]u8 = undefined;
                emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&nb, "steer received — skipped {d} queued tool call(s)", .{skipped}) catch "steer received");
                break;
            }
            emitToolState(app, conv_dir, c.name, "start", "");
            // REPEAT-CALL GUARD (see call_ledger above): an exact repeat of an idempotent network call is
            // answered from the ledger — the model is told to use the result it already has and move on.
            const call_h = std.hash.Fnv1a_64.hash(c.name) ^ std.hash.Fnv1a_64.hash(c.args);
            var repeated = false;
            var repeated_prior = false; // first occurrence was in an EARLIER batch — repeated after seeing feedback
            if (dedupableTool(c.name)) {
                for (call_ledger.items, 0..) |h, hi| {
                    if (h == call_h) {
                        repeated = true;
                        repeated_prior = hi < ledger_at_batch;
                        break;
                    }
                }
                if (!repeated) call_ledger.append(gpa, call_h) catch {};
            }
            // TOOL-ECHO GUARD (see echo_guard above): identical call + identical RESULT repeatedly is a
            // loop, not work. Read-class tools degrade later (6+) — a mind may legitimately need one more
            // look — while everything else refuses at 4+, matching the swarm loop's thresholds.
            var echo_slot: ?*EchoRec = null;
            for (echo_guard) |*g| {
                if (g.count > 0 and g.sig == call_h) {
                    echo_slot = g;
                    break;
                }
            }
            // Reads used to get a larger allowance (6) than everything else, set when compaction folded the
            // WHOLE working span and a re-read was often the model's only way back to bytes the engine had
            // deleted. compactWorking now keeps a verbatim tail (see WORKING_KEEP_TAIL_BYTES), so an IDENTICAL
            // re-read no longer recovers anything the model cannot already see — and each one costs a full
            // round trip plus up to TOOL_RESULT_KEEP bytes re-uploaded on every later inference of the turn.
            // One threshold now. The legitimate case is untouched: the guard keys on the RESULT hash, so a read
            // returning something different (the read-after-write cycle BUILD DISCIPLINE asks for) resets the
            // count and never trips this.
            const echo_limit: u8 = ECHO_LIMIT;
            const echo_blocked = echo_slot != null and echo_slot.?.count >= echo_limit;
            if (echo_blocked) echo_slot.?.count +|= 1;
            // STRIKE MARK (resolved per ITERATION at the batch end — see loop_refusals above): an
            // identical-call refusal marks this whole inference as a loop pass. Echo refusals always count;
            // ledger repeats count only when the first occurrence was in an EARLIER batch — a same-batch
            // duplicate was emitted before the model could see any "do NOT re-run" feedback, and striking it
            // would cut down dup-batching models that are otherwise progressing. Budget refusals and plugin
            // vetoes are neither loop evidence nor progress: they touch neither flag, freezing the streak.
            if (echo_blocked or repeated_prior) iter_refused = true;
            // QUERY FORMULATION (prompting): chat used to hand web_search the model's query verbatim — the swarm
            // has had a formulation step for a while (run.zig scoutQuery) and the chat side had none at all.
            // Gated on the call actually being about to EXECUTE (the three guard conditions below are the ones
            // the result chain checks), because reformulating a query for a call that is about to be refused
            // spends a completion to produce nothing. `run_args` is what runs; `c.args` above already went into
            // conv_buf verbatim, which is deliberate — the cue-threading observe wants the model's own words —
            // so a rewrite has to SAY so in the result, further down.
            var new_query: []u8 = &[_]u8{};
            var spliced_args: []u8 = &[_]u8{};
            defer if (new_query.len > 0) gpa.free(new_query);
            defer if (spliced_args.len > 0) gpa.free(spliced_args);
            var run_args: []const u8 = c.args;
            if (std.mem.eql(u8, c.name, "web_search") and !echo_blocked and !repeated and tools_spent.* < tool_budget) {
                if (searchQuerySpan(c.args)) |span| {
                    const raw_q = c.args[span.start..span.end];
                    var used_q: []const u8 = raw_q;
                    if (formulateSearch(app, run_root, trio.pick(.prompting), intent, raw_q, search_log.items)) |rw| {
                        if (std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ c.args[0..span.start], rw, c.args[span.end..] })) |sp| {
                            spliced_args = sp;
                            run_args = sp;
                            new_query = rw;
                            used_q = rw;
                        } else |_| gpa.free(rw); // the splice failed — run the model's own query, say nothing
                    }
                    // Ledger the query that ACTUALLY runs, so the next formulation this turn has to move off it.
                    if (search_log.items.len < SEARCH_LOG_MAX) {
                        if (gpa.dupe(u8, used_q)) |q| {
                            search_log.append(gpa, q) catch gpa.free(q);
                        } else |_| {}
                    }
                }
            }
            var executed = false; // did the tool genuinely run (vs a dedup/budget guard)? gates perf learning
            var name_fixed: ?[]const u8 = null; // set when a miscapitalized name auto-corrected (WebSearch→web_search)
            const t_call = nowMillis(app.io);
            var result = if (echo_blocked)
                // HONEST REFUSALS: these used to say "the result is above". Compaction may have folded that
                // span into a progress note, so the engine was telling the model to use data it had deleted —
                // then blocking it for asking again. Say what to do when the bytes are genuinely gone.
                (gpa.dupe(u8, "(loop guard: you have made this EXACT call repeatedly and it returned the IDENTICAL result every time — it will not return anything different. If its result is still above, use it; if it was folded into a progress note, recall it or read a NARROWER slice. Either way take a DIFFERENT action now: different arguments, a different tool, or write/settle your deliverable.)") catch @constCast(""))
            else if (repeated)
                (gpa.dupe(u8, "(you already ran this EXACT call earlier this turn — do NOT re-run it. Its result is above unless compaction folded it into a progress note; if you cannot see it, recall it or read a NARROWER slice instead of repeating this. Then MOVE ON to the next step, e.g. writing the deliverable file.)") catch @constCast(""))
            else if (dedupableTool(c.name) and tools_spent.* >= tool_budget) blk_ob: {
                // BUDGET CEILING (scheduled runs): the research appetite is unbounded but the wallet is not.
                // Past the budget, NETWORK research calls are answered with "finalize now" — but LOCAL tools
                // (write_file/edit_file/read_file/run_tests) always execute, because finalizing IS writing:
                // the first cut refused the very write_file the refusal demanded, and the run spun. One
                // status frame the first time it trips.
                if (tools_spent.* == tool_budget) {
                    tools_spent.* += 1;
                    var bb: [96]u8 = undefined;
                    emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&bb, "research budget ({d}) exhausted — steering the run to finalize", .{tool_budget}) catch "research budget exhausted — finalizing");
                }
                break :blk_ob gpa.dupe(u8, "(this scheduled run's RESEARCH budget is exhausted — no further web/search calls will execute. write_file/edit_file/read_file still work: write or finalize the deliverable NOW from what you already gathered, state any remaining gaps inside it, then reply DONE.)") catch @constCast("");
            } else blk: {
                executed = true; // this branch actually runs the tool — its latency/outcome is real learning
                if (dedupableTool(c.name)) tools_spent.* += 1; // only network research spends the budget
                // CLIENT MODE: if this conversation's cast just finished, push its files down FIRST — the frames
                // land before this tool's tool_request, and the client processes frames in order, so a delegated
                // list_dir/read_file sees the hive's work on the client's own disk instead of "no such file".
                if (tool_client) maybeSyncCastFiles(app, uid, conv, conv_dir, steer_cursor.*);
                // PLUGIN POLICY HOOKS: any installed veil.on_policy(fn) sees this call (uid, admin, conv,
                // tool, args) BEFORE it runs and may veto it. First deny wins; the denial string becomes the
                // tool result (shaped like the engine's own "(...)" refusals). A hook that errors fails OPEN
                // (logged) — a buggy plugin must never brick tool use. Runs for orchestration + mind tools
                // alike, so a plugin can gate a cast the same as a shell command.
                if (plugins.current(&app.plugs)) |preg| {
                    if (preg.policyGate(gpa, uid, ctx.caps == .full, conv, c.name, run_args)) |denial| {
                        executed = false; // a vetoed call never ran — don't smear its tool-perf stats
                        emitKV(app, conv_dir, "status", "text", "a plugin policy denied a tool call");
                        break :blk denial;
                    }
                }
                // PLUGIN-OWNED TOOL: a name like plug_<plugin>_<tool> is dispatched to the plugin executor
                // (a sandboxed Lua handler, or a bridged MCP server call) instead of the built-in table.
                if (plugins.current(&app.plugs)) |preg| {
                    if (preg.ownsTool(c.name)) break :blk preg.execTool(gpa, c.name, run_args);
                }
                // ORCHESTRATION verbs (cast/steer_swarm/stop_swarm/swarm_status) are the VEIL's — handled
                // in-process via deploy_service + app.sup, NOT the mind-tool executor. get_credential is also
                // SERVER-side always: its store is the server's memories.jsonl, and the client executor has no
                // durable_path — delegated, it refused every fetch (observed: a desk chat could not retrieve
                // its Discourse key and built around the failure). Everything else executes as a mind tool: in
                // CLIENT mode (a desk/CLI turn) it is DELEGATED to the client's harness so file/shell/code
                // tools act on the USER's machine; otherwise it runs here (a hive/server turn).
                // A name that exists NOWHERE is answered here, instantly, with the real belt (see knownToolName).
                // Delegated instead, a phantom name costs the full ack timeout and returns a bridge error the
                // model misreads as its own tools being offline — which ends the turn on a false conclusion.
                // FIRST, though: a small model's most common miss is a re-cased/re-punctuated REAL name
                // (WebSearch, ListDir, Read_File — all observed live). When the loose form matches exactly ONE
                // advertised tool, run that tool now and teach the exact name in the result note, instead of
                // burning a whole agentic round on a correction the model must read, obey, and re-emit.
                var run_name: []const u8 = c.name;
                if (!knownToolName(turn_tools, c.name)) {
                    if (canonToolMatch(turn_tools, c.name)) |real| {
                        run_name = real;
                        name_fixed = real;
                    } else break :blk unknownToolResult(gpa, c.name, turn_tools);
                }
                // POLL BUDGET: after POLL_TIMEOUT_STREAK consecutive timeouts, further polls are answered
                // instantly instead of blocking the turn another 180s each. The model is told the honest state
                // and the way out; the streak resets on any poll that actually MATCHES (see intake below).
                if (std.mem.eql(u8, run_name, "poll") and poll_timeouts.* >= POLL_TIMEOUT_STREAK)
                    break :blk gpa.dupe(u8, "(NOT executed — poll budget for this turn is exhausted: the last 3 polls all timed out with nothing arriving. The thing you are waiting for is not coming on this turn's clock. STOP waiting: report the current state to the user plainly, or take a different action. If it genuinely needs longer, say so and end the turn — the user can ask again later or schedule a task.)") catch emptyRes();
                // TRUNCATED MUTATION GUARD: `done_reason:"length"` with tool_calls present means the output
                // budget ran out MID-CALL — and Ollama's constrained decoding closes the JSON anyway, so the
                // last call arrives as VALID args whose string content was silently amputated. Executing that
                // writes a half file the model then believes complete (a small local model asked for a 400-line
                // write_file is the textbook case). Only the LAST call is suspect (earlier array entries
                // finished before the budget died), and only mutations corrupt anything — reads just search a
                // little worse. Refuse with the exact recovery move instead of executing the damage.
                if (step.truncated and ci == step.calls.len - 1 and isMutatingTool(run_name))
                    break :blk gpa.dupe(u8, "(NOT executed: this call was CUT OFF by the output-token limit — done_reason=length — so its arguments are almost certainly incomplete, and running it would have written a truncated file that looks finished. Re-issue the SAME call with less content: write the file in smaller pieces (edit_file appends/patches), or shorten what you are writing. Do not assume anything was written.)") catch emptyRes();
                break :blk orchTool(app, uid, ctx, conv, conv_dir, steer_cursor.*, trio, run_name, run_args, tool_client) orelse
                    (if (tool_client and !std.mem.eql(u8, run_name, "get_credential")) delegateTool(app, conv_dir, c.id, run_name, run_args, steer_cursor.*, no_ack_streak) else tools.execute(ctx, run_name, run_args));
            };
            scrubUtf8(result); // fetched bytes may be invalid UTF-8; must be valid before it rides in JSON
            // A reformulated search must SAY so in its own result. The transcript records the query the model
            // asked for, so without this it would read results for a search it never made and have no way to
            // tell. Appended, never prefixed: the observe gate below drops any result starting with '(' — a
            // leading note would silently cost the finding its place in memory.
            // An auto-corrected name must SAY so, or the model keeps using the wrong one forever (the result
            // arriving under its own alias reads as confirmation). Appended, same reason as the search note.
            if (name_fixed) |real| {
                if (std.fmt.allocPrint(gpa, "{s}\n(engine: no tool is named \"{s}\" — this ran {s}, the exact advertised name. Call it {s} from now on.)", .{ result, c.name, real, real })) |noted| {
                    gpa.free(result);
                    result = noted;
                } else |_| {}
            }
            // BOT-CHALLENGE + NOT-FOUND HONESTY: a blocked site answers a fetch with a small interstitial
            // ("Just a moment…", a PerimeterX/Cloudflare stub) and a guessed URL answers with a 404 page —
            // REAL bytes that are not the page. A frontier model shrugs; a small model reads them as content,
            // or pivots to the next INVENTED URL forever (observed live: a 12B burned a research turn on
            // fabricated arXiv ids, each "Not found" page arriving as ordinary bytes). Replace the stub with
            // an honest instruction; prepended '(' deliberately keeps the junk out of the memory weave (the
            // observe gate drops '('-leading results). Three consecutive duds earn the stop-guessing order —
            // the counter is turn-scoped and one real page resets it.
            if (std.mem.eql(u8, name_fixed orelse c.name, "web_fetch") or std.mem.eql(u8, name_fixed orelse c.name, "read_url")) {
                const challenge = looksLikeBotChallenge(result);
                const notfound = !challenge and looksLikeNotFound(result);
                if (challenge or notfound) {
                    dud_fetches.* += 1;
                    const why: []const u8 = if (challenge)
                        "(this is a BOT-CHECK page, not the article — the site blocked automated fetching. Do NOT treat it as content and do NOT retry this URL; use web_search or a different source."
                    else
                        "(this URL answered NOT FOUND — the page does not exist. Do NOT cite it and do NOT construct another URL by pattern; a URL you didn't copy verbatim from a search result or page above is a guess.";
                    const extra: []const u8 = if (dud_fetches.* >= DUD_FETCH_STREAK)
                        " This is the THIRD dead fetch in a row: STOP fetching entirely until a search result above hands you a real URL — search differently, or answer from what you already have."
                    else
                        "";
                    if (std.fmt.allocPrint(gpa, "{s}{s} First bytes, as evidence:)\n{s}", .{ why, extra, clipBytes(result, 400) })) |noted| {
                        gpa.free(result);
                        result = noted;
                    } else |_| {}
                } else if (result.len > 0 and result[0] != '(') {
                    dud_fetches.* = 0; // a real page — the model is fetching URLs that exist again
                }
            }
            // POLL STREAK intake: a "-> timeout" verdict counts toward the budget; a match/up/done resets it.
            // Keyed on the verdict string pollTool itself prints, so the delegated (desk) and server executors
            // are covered identically.
            if (std.mem.eql(u8, name_fixed orelse c.name, "poll")) {
                if (std.mem.indexOf(u8, result, "-> timeout") != null) poll_timeouts.* += 1 else if (result.len > 0 and result[0] != '(') poll_timeouts.* = 0;
            }
            if (new_query.len > 0 and result.len > 0) {
                if (std.fmt.allocPrint(gpa, "{s}\n(engine: this searched \"{s}\" — a focused rewrite of the query you gave, aimed at the same intent.)", .{ result, new_query })) |noted| {
                    gpa.free(result);
                    result = noted;
                } else |_| {}
            }
            const dt = nowMillis(app.io) - t_call;
            const ok = result.len > 0 and result[0] != '(' and std.mem.indexOf(u8, result, "\"ok\":false") == null;
            const outcome_bad = !ok or (std.mem.startsWith(u8, result, "exit=") and !std.mem.startsWith(u8, result, "exit=0"));
            // TOOL-PERFORMANCE LEARNING: record only genuinely-executed calls (dedup/budget guards never ran the
            // tool, so counting them would smear its stats). `ok` mirrors the observe gate — a real result, not
            // an engine error string or an `"ok":false` payload.
            if (executed) tool_perf.record(c.name, ok, !outcome_bad, if (dt > 0) @intCast(dt) else 0);
            // FAILURE-STREAK DELIBERATION NUDGE: the OUTCOME failed — engine-refusal (`(…`), an "ok":false
            // payload, or a non-zero `exit=` result (the run_python/run_tests contract; toolperf's `ok`
            // deliberately counts those as tool-healthy). Two failed outcomes of the SAME tool in a row means
            // one approach is being ground instead of weighed — append the option space to the failing result,
            // at the exact moment it is being ignored. The model still chooses; the engine only makes the
            // choice visible.
            //
            // A GUARD REFUSAL IS A FAILED OUTCOME. This whole block used to sit inside `if (executed)`, which
            // made it unreachable for exactly the runs that need it most: an echo-refused call never executes,
            // so a model grinding one identical call accrued no streak, was never shown the option space, and
            // never heard the arbiter — it just collected refusals until the loop guard killed the turn. The
            // ONE mechanism built to break a grind was switched off by the grind itself. Refusal evidence now
            // counts, gated exactly like the loop strike above (`echo_blocked or repeated_prior`): a same-batch
            // duplicate still does not count, because the model had not yet seen any feedback to ignore.
            if (streakEligible(executed, echo_blocked, repeated_prior)) {
                const th = std.hash.Fnv1a_64.hash(c.name);
                if (outcome_bad) {
                    if (th == fail_streak_tool) fail_streak +|= 1 else {
                        fail_streak_tool = th;
                        fail_streak = 1;
                    }
                } else if (th == fail_streak_tool) fail_streak = 0;
                if (outcome_bad and fail_streak == 2 and result.len > 0) {
                    // STREAK 2 — the cheap generic nudge: name the option space, no LLM cost. TWO texts,
                    // tier-paired with the belt like the system prompt: the full option space names poll /
                    // recall_hive / open_subchat / cast, none of which a compact turn advertises — and this
                    // nudge is served at the exact moment a struggling small model is hunting for ANY new
                    // verb to try (observed live: it landed right after the dud-fetch escalation and offered
                    // a 12B four tools its belt hides).
                    // ADVERTISED check, not knownToolName: the latter falls back to the static full-schema
                    // tables, which is precisely how compact turns still execute "cast" — here the question
                    // is what this turn's belt SHOWS, so only the tools-array needle answers it.
                    const option_space: []const u8 = if (std.mem.indexOf(u8, turn_tools, "\"name\":\"cast\"") != null)
                        "files: write_file/edit_file/read_file/list_dir; waiting or watching anything: poll; web: web_fetch/read_url/fetch_json; stored docs: read_doc/recall_hive; a side-thread: open_subchat; a team: cast"
                    else
                        // read_url and fetch_json were dropped from the small belt in an earlier pass and never
                        // cleaned up here, so this offered a struggling 12B two verbs it cannot call — at the
                        // exact moment it is hunting for any new verb to try. Replaced with the browser pair,
                        // which the tier DOES serve and which is the real answer to "web_fetch didn't work".
                        "files: write_file/edit_file/read_file/list_dir; web: web_search/web_fetch; a page needing JS or a login: browser_navigate then browser_read; run code: run_python/run_tests; stored docs: read_doc; memory: recall";
                    const nudged = std.fmt.allocPrint(gpa, "{s}\n(engine: {s} has produced a FAILED outcome {d} times in a row. STOP and weigh your options before the next call. Is there a dedicated tool for this job — {s}? Pick the SIMPLEST tool that does it, or fix the exact error shown above — never re-run the same approach unchanged.)", .{ result, c.name, fail_streak, option_space }) catch result;
                    if (nudged.ptr != result.ptr) {
                        gpa.free(result);
                        result = nudged;
                    }
                } else if (outcome_bad and fail_streak == 3 and result.len > 0) {
                    // STREAK 3 — ESCALATE, once: a bounded prompting-tier ARBITER reads the goal, the failing
                    // call, its error, and this machine's tool belt, and returns ONE concrete next move. The
                    // generic nudge was ignored twice; a specific suggestion breaks the grind. Deliberation as
                    // escalation (fires once per streak), never a per-call tax. Never auto-executed — advice only.
                    if (toolArbiter(app, run_root, trio.pick(.prompting), intent, c.name, run_args, result, turn_tools)) |adv| {
                        defer gpa.free(adv);
                        const noted = std.fmt.allocPrint(gpa, "{s}\n(engine arbiter — {s} failed 3x; a focused look at your goal, this error, and your tool belt suggests: {s} Weigh it; you decide.)", .{ result, c.name, adv }) catch result;
                        if (noted.ptr != result.ptr) {
                            gpa.free(result);
                            result = noted;
                        }
                    }
                }
            }
            // TOOL-ECHO BOOKKEEPING: hash the result and track consecutive identical echoes; from the 2nd
            // identical repeat the model gets an in-band warning appended to the result so it self-corrects
            // with context (the refusal above only fires once the warnings were ignored).
            if (executed) {
                iter_executed = true; // real work happened this inference — eligible to clear the loop streak at batch end
                const rh = std.hash.Fnv1a_64.hash(result[0..@min(result.len, 4096)]);
                if (echo_slot) |g| {
                    if (g.res == rh) {
                        g.count +|= 1;
                        if (g.count >= 2 and result.len > 0) {
                            const warned = std.fmt.allocPrint(gpa, "{s}\n(loop warning: this exact call has now returned the IDENTICAL result {d} times — do not repeat it; use what you already have, or change arguments/approach.)", .{ result, g.count }) catch result;
                            if (warned.ptr != result.ptr) {
                                gpa.free(result);
                                result = warned;
                            }
                        }
                    } else {
                        g.res = rh; // same call, DIFFERENT result (state moved) — not a loop; restart the count
                        g.count = 1;
                    }
                } else {
                    // claim a slot for this new signature (evict the stalest = lowest count)
                    var victim: *EchoRec = &echo_guard[0];
                    for (echo_guard) |*g| {
                        if (g.count == 0) {
                            victim = g;
                            break;
                        }
                        if (g.count < victim.count) victim = g;
                    }
                    // probe: side-effect-free file reads may be re-opened by a landed mutation (PROBE RE-OPEN below)
                    const probe = std.mem.eql(u8, c.name, "read_file") or std.mem.eql(u8, c.name, "list_dir");
                    victim.* = .{ .sig = call_h, .res = rh, .count = 1, .probe = probe };
                }
            }
            // A fetched credential value must never land in the event stream (events.jsonl outlives the turn).
            emitToolState(app, conv_dir, c.name, "done", if (std.mem.eql(u8, c.name, "get_credential")) "(credential value withheld from the event log)" else clipBytes(result, TOOL_PREVIEW_BYTES));

            // HIPPOCAMPUS (observe): a SUCCESSFUL tool finding is durable knowledge. Gate out engine error strings
            // — "(...)" notes and `"ok":false` payloads — and never observe assistant reply content (confab fix).
            // get_credential results are excluded wholesale: a secret persisted as a memory fact would recirculate
            // through recall into later prompts, exactly what on-demand fetch exists to prevent.
            // QUEUED, not observed inline: each observe spawns a subprocess, which serialized big tool batches.
            // runTurn flushes the queue at turn exit (bounded — a runaway afk turn can't hoard notes forever).
            // memoryEchoTool: recall/observe echoes are memory OUTPUT — re-observing them launders other
            // scopes' facts into this one. resultCredentialed: a probe that RETURNED a token/csrf/secret
            // (args were clean — the value came back in the body) must not persist either.
            const result_credentialed = blk_rc: {
                var rl2: [200]u8 = undefined;
                const head = clipBytes(result, rl2.len);
                const lower = std.ascii.lowerString(rl2[0..head.len], head);
                break :blk_rc containsCredentialKey(lower);
            };
            if (result.len > 0 and result[0] != '(' and std.mem.indexOf(u8, result, "\"ok\":false") == null and !std.mem.eql(u8, c.name, "get_credential") and !memoryEchoTool(c.name) and !result_credentialed and tool_obs.items.len < 200) {
                // CUE THREADING: the fact carries the call's ARGS head alongside the result — the query
                // terms, the path, the URL. neuron-db is lexical-associative: a later step phrased like the
                // ORIGINAL CUE can only hop to this finding if the cue's words live in the fact. Without
                // them, "tool web_search: <results>" was unreachable from the question that asked for it.
                // Exceptions: write/edit args are mostly file CONTENT (noise — the ledger threads paths) and
                // host_command may carry credentials; a credential-shaped key anywhere in the clip drops the
                // cue rather than persist it.
                const args_cue: []const u8 = blk_ac: {
                    if (std.mem.eql(u8, c.name, "write_file") or std.mem.eql(u8, c.name, "edit_file") or std.mem.eql(u8, c.name, "host_command")) break :blk_ac "";
                    const head = clipBytes(c.args, 120);
                    if (looksCredentialed(head)) break :blk_ac "(args redacted)";
                    break :blk_ac head;
                };
                if (std.fmt.allocPrint(gpa, "tool {s} {s}: {s}", .{ c.name, args_cue, clipBytes(result, 200) })) |note| {
                    atomizeNoteInPlace(note); // ONE fact per finding — the store's sentence atomizer must not shred it
                    tool_obs.append(gpa, note) catch gpa.free(note);
                } else |_| {}
            }

            // FILE LEDGER (fine-needle capture): a landed write/edit becomes engine ground truth NOW — in
            // the ledger (woven into every subsequent drive step) and in files.jsonl (the next turn's
            // load). Delegated client results carry the identical strings, so desk-client builds finally
            // register their writes too. No inline neuron-db observe here: the generic tool-note queue
            // above already carries "tool write_file: wrote {path} — …" (batched — an inline spawn per
            // write would re-serialize big write batches), and WITHIN the turn the woven ledger block is
            // the engine-exact source of file truth.
            var file_mutated = false;
            if (parseFileMutation(c.name, result)) |m| {
                file_mutated = true;
                // Normalize separators BEFORE persisting: files.jsonl must hold '/'-paths so ledgerLoad's
                // fail-safe (backslash ⇒ unparseable ⇒ partial) never triggers on our own lines.
                var pbuf: [300]u8 = undefined;
                @memcpy(pbuf[0..m.path.len], m.path);
                for (pbuf[0..m.path.len]) |*ch| {
                    if (ch.* == '\\') ch.* = '/';
                }
                const np = pbuf[0..m.path.len];
                file_ledger.note(gpa, np, m.bytes);
                file_ledger.mutations += 1;
                ledgerPersist(app, conv_dir, c.name, np, m.bytes);
            } else if (std.mem.eql(u8, c.name, "read_file") and std.mem.eql(u8, std.mem.trim(u8, result, " \r\n\t"), "not found")) {
                // GROUND-TRUTH CONFLICT (anti-confabulation): the ledger says this file was WRITTEN, the
                // read says NOT FOUND. Left unreconciled, the model has been observed concluding "the write
                // succeeded" from exactly this evidence and settling. Contradict it mechanically, once per
                // batch, with a concrete resolution path.
                if (argsPath(c.args)) |rp| {
                    if (file_ledger.has(rp)) |lb| {
                        if (post_note.items.len == 0) {
                            var nb2: [560]u8 = undefined;
                            const cn = std.fmt.bufPrint(&nb2, "GROUND-TRUTH CONFLICT: the engine ledger recorded a successful write of {s} ({d} bytes) earlier in this conversation, but read_file just returned NOT FOUND. Resolve this mechanically: list the directory to locate the file; if it is truly missing, RE-WRITE it now. Do NOT conclude the work is done, and do NOT claim the file exists.", .{ clipBytes(rp, 260), lb }) catch "GROUND-TRUTH CONFLICT: a file the ledger recorded as written just read back NOT FOUND — locate or re-write it before settling.";
                            var scratch: std.ArrayListUnmanaged(u8) = .empty;
                            defer scratch.deinit(gpa);
                            const note_ok = blk_pn: {
                                scratch.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :blk_pn false;
                                http.jstr(gpa, &scratch, cn) catch break :blk_pn false;
                                scratch.append(gpa, '}') catch break :blk_pn false;
                                post_note.appendSlice(gpa, scratch.items) catch break :blk_pn false;
                                break :blk_pn true;
                            };
                            if (!note_ok) post_note.clearRetainingCapacity();
                            emitKV(app, conv_dir, "status", "text", "ground-truth conflict: a ledgered file read back NOT FOUND — steering the model to reconcile");
                        }
                    } else if (!foreign_warned.* and post_note.items.len == 0 and foreignMentions(foreign_mem, rp)) {
                        // FOREIGN-MEMORY CONFLICT (anti-adoption): the model probed a file that exists ONLY in
                        // this turn's injected cross-task knowledge — the disk just proved that memory belongs
                        // to a DIFFERENT task. Left unreconciled, the observed failure was to rebuild the old
                        // project from its remembered description; contradict the memory mechanically instead.
                        foreign_warned.* = true;
                        var nb3: [560]u8 = undefined;
                        const cn = std.fmt.bufPrint(&nb3, "FOREIGN-MEMORY CONFLICT: {s} does NOT exist in this conversation — it comes from the injected cross-task knowledge (shared hive), which describes a DIFFERENT task's build. Drop that memory now: do not re-create its files and do not adopt its project as this conversation's goal. This conversation's real state is ONLY what ENGINE GROUND TRUTH / list_dir shows.", .{clipBytes(rp, 240)}) catch "FOREIGN-MEMORY CONFLICT: that file exists only in cross-task hive knowledge, not in this conversation — drop the foreign memory and work from ENGINE GROUND TRUTH.";
                        var scratch: std.ArrayListUnmanaged(u8) = .empty;
                        defer scratch.deinit(gpa);
                        const note_ok = blk_fn: {
                            scratch.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch break :blk_fn false;
                            http.jstr(gpa, &scratch, cn) catch break :blk_fn false;
                            scratch.append(gpa, '}') catch break :blk_fn false;
                            post_note.appendSlice(gpa, scratch.items) catch break :blk_fn false;
                            break :blk_fn true;
                        };
                        if (!note_ok) post_note.clearRetainingCapacity();
                        emitKV(app, conv_dir, "status", "text", "foreign-memory conflict: the model probed a file that exists only in another task's knowledge — steering it to drop that memory");
                    }
                }
            }

            // PROBE RE-OPEN: state on disk just changed — a landed write/edit, or a shell command that may
            // have touched anything. A read-class signature the echo guard already wedged was refused on the
            // claim "it will not return anything different", and a refused call never executes, so the guard
            // could never observe the change that falsifies its own claim (the model is then blocked from
            // re-reading the very file it just rewrote — the read-after-write cycle BUILD DISCIPLINE demands,
            // and the blindness behind the c6a5937fe apology-into-file corruption class). Cap wedged probe
            // slots back to one-below-limit: exactly ONE probe execution — a changed result disarms the slot
            // (count restarts at 1), an identical one re-wedges it on the next call. Cost: at most one cheap
            // local read per landed mutation. Only probe-flagged (side-effect-free read) slots ever re-open;
            // a wedged mutating signature stays refused.
            if (executed and (file_mutated or std.mem.eql(u8, c.name, "host_command"))) {
                for (echo_guard) |*g| {
                    if (g.probe and g.count >= ECHO_LIMIT) g.count = ECHO_LIMIT - 1;
                }
            }

            // Build the whole tool-result object in a scratch list, then append it to conv_buf in ONE shot. A
            // mid-object OOM must never leave conv_buf as a partial/unterminated object — that malformed JSON would
            // ride into the next completion (a 400) instead of a clean hard_error. On any failure: free + hard_error.
            // OVERSIZED results are clipped (head + tail) before they enter the context: every appended byte is
            // re-uploaded on EVERY later inference of the turn, so one giant build/test dump otherwise taxes the
            // whole rest of the conversation (a first-order slowness source on hosted models).
            const kept = clipToolResult(gpa, result);
            var toolobj: std.ArrayListUnmanaged(u8) = .empty;
            defer toolobj.deinit(gpa);
            const obj_ok = blk: {
                toolobj.appendSlice(gpa, ",{\"role\":\"tool\",\"tool_call_id\":") catch break :blk false;
                http.jstr(gpa, &toolobj, c.id) catch break :blk false;
                toolobj.appendSlice(gpa, ",\"content\":") catch break :blk false;
                http.jstr(gpa, &toolobj, kept) catch break :blk false;
                toolobj.append(gpa, '}') catch break :blk false;
                conv_buf.appendSlice(gpa, toolobj.items) catch break :blk false;
                break :blk true;
            };
            if (kept.ptr != result.ptr) gpa.free(kept);
            if (result.len > 0) gpa.free(result); // OOM fallback in execute() can hand back a static "" — don't free that
            if (!obj_ok) return .{ .outcome = .hard_error, .content = empty };
        }
        // LOOP STRIKE (iteration boundary — see loop_refusals above): one refusal-bearing inference is one
        // strike; an inference that refused nothing AND executed something clears the streak. Per-iteration
        // resolution guarantees the model saw the refusal feedback between strikes (a whole batch of
        // duplicates costs at most one), clearing only on a clean pass is the c6a75df8b forgiveness in its
        // precise form, and a batch that neither refused nor executed (all budget-refused/vetoed) freezes
        // the streak rather than feeding either side.
        if (iter_refused) loop_refusals +|= 1 else if (iter_executed) loop_refusals = 0;
        // WITHIN-TURN COMPACTION (step boundary): if this pass's working growth has crossed the budget, compress it
        // into a progress note so a long/afk turn can keep going without overflowing the model window.
        compactWorking(app, run_root, think.base_url, think.key, think.model, conv_buf, base_len, ctx, tool_obs,
            workingBudgetBytes(base_url, model, base_len + turn_tools.len));
        // GROUND-TRUTH CONFLICT SPLICE — after compaction (never folded into a summary), before any steer
        // (the user's live instruction stays last, i.e. most salient).
        if (post_note.items.len > 0)
            conv_buf.appendSlice(gpa, post_note.items) catch return .{ .outcome = .hard_error, .content = empty };
        // MID-BATCH STEER SPLICE — after compaction, so the literal user instruction can never be folded into a
        // summary note. The next completion sees: assistant tool_calls → results (real + skipped) → user steer.
        if (pending_steer.items.len > 0)
            conv_buf.appendSlice(gpa, pending_steer.items) catch return .{ .outcome = .hard_error, .content = empty };
        // loop: feed the tool results back for the next completion
    }

    // Ran out of tool iterations mid-loop: ask for a brief no-tools SUMMARY so the reply is a real closing message
    // ("here's what I built…") rather than a raw step-limit string. Fall back to the last narration, then a
    // friendly note, only if the summary itself fails.
    // These salvage returns follow a full tool loop, so tools_ran reflects the real work (any_tool) — the drive
    // loop must keep its multi-step continuation, not be short-circuited by the no-tools fast path.
    if (summarizeTurn(app, run_root, think.base_url, think.key, think.model, conv_buf.items)) |sum| return .{ .outcome = .settled, .content = sum, .tools_ran = any_tool };
    const fallback: []const u8 = if (last_content.len > 0) last_content else "I did as much as I could this turn — say \"continue\" if there's more you want.";
    return .{ .outcome = .settled, .content = gpa.dupe(u8, fallback) catch empty, .tools_ran = any_tool };
}

/// A brief no-tools completion asking the model to summarize what it just did — used when the tool loop hits its
/// round cap, so the reply is a real closing message instead of a raw step-limit note. gpa-owned text or null (a
/// failed/empty summary lets the caller fall back to the last narration).
fn summarizeTurn(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, conv_items: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    // BOUNDED: the round-cap salvage fires exactly when the transcript is at its biggest — summarize from the
    // freshest boundary-aligned slice (which holds this turn's work) instead of re-prefilling all of it.
    msgs.appendSlice(gpa, msgTail(conv_items, SUMMARY_CTX_BYTES)) catch return null;
    msgs.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, "In 1-3 sentences, tell the user what you accomplished this turn and what (if anything) remains. Do not call any tools.") catch return null;
    msgs.append(gpa, '}') catch return null;
    const summary_cm = meterBegin(app.io);
    var step = completeAux(app, run_root, "summary", base_url, key, model, msgs.items, 1024, 0.5);
    defer step.deinit(gpa);
    meterEnd(app, summary_cm, "summary", .thinking, model, step.ok);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t");
    if (t.len == 0) return null;
    return gpa.dupe(u8, t) catch null;
}

/// STREAK-ESCALATED MICRO-ARBITER: after a tool has failed its OUTCOME three times running, one bounded
/// prompting-tier call looks at what the turn is FOR, the exact failing call + its error, and this machine's
/// learned tool belt, and returns ONE concrete next move (a different tool, or the specific fix). Advice only
/// — never auto-executed; the caller appends it to the failing result as an engine note. Null on any failure
/// (the generic streak-2 nudge already fired, so silence here just means no extra hint). gpa-owned.
fn toolArbiter(app: *App, run_root: []const u8, p: Provider, intent: []const u8, tool_name: []const u8, tool_args: []const u8, err_result: []const u8, tools_json: ?[]const u8) ?[]u8 {
    const gpa = app.gpa;
    // filtered to the turn's advertised belt: advice naming a tool the model can't see is the recall_hive class
    const belt = toolperf.belt(gpa, app.io, app.data, "", tools_json) orelse gpa.dupe(u8, "") catch return null;
    defer gpa.free(belt);
    var ask: std.ArrayListUnmanaged(u8) = .empty;
    defer ask.deinit(gpa);
    ask.appendSlice(gpa, "A tool keeps failing and the agent is stuck repeating it. Recommend ONE concrete next move — either a DIFFERENT tool better suited to the job, or the specific fix for the exact error. Be terse and actionable (1-2 sentences, name the tool + how).\n\nWHAT THE TURN IS FOR: ") catch return null;
    ask.appendSlice(gpa, clipBytes(intent, 500)) catch return null;
    ask.appendSlice(gpa, "\n\nTHE FAILING CALL: ") catch return null;
    ask.appendSlice(gpa, tool_name) catch return null;
    ask.appendSlice(gpa, "  args: ") catch return null;
    ask.appendSlice(gpa, clipBytes(tool_args, 300)) catch return null;
    ask.appendSlice(gpa, "\nITS ERROR/OUTPUT (3rd failure): ") catch return null;
    ask.appendSlice(gpa, clipBytes(err_result, 600)) catch return null;
    if (belt.len > 0) {
        ask.appendSlice(gpa, "\n\n") catch return null;
        ask.appendSlice(gpa, clipBytes(belt, 500)) catch return null;
    }
    // TIER-VARIED, because this is served to compact turns too. It named poll, read_url, fetch_json,
    // recall_hive, open_subchat and cast to a belt that serves none of them — advice the model cannot act on,
    // handed to it on the streak-3 escalation, i.e. precisely when it is out of ideas and most likely to try
    // whatever it is told. The `cast` needle is the same ADVERTISED check the streak-2 nudge uses.
    const has_orch = if (tools_json) |tj| std.mem.indexOf(u8, tj, "\"name\":\"cast\"") != null else true;
    ask.appendSlice(gpa, if (has_orch)
        "\n\nAVAILABLE TOOL FAMILIES: files (write_file/edit_file/read_file/list_dir/delete_file), waiting/watching (poll), web (web_fetch/read_url/web_search/fetch_json), stored docs & memory (read_doc/recall_hive/recall), side-thread (open_subchat), a team (cast), code (run_python/run_tests). Your recommendation:"
    else
        "\n\nAVAILABLE TOOL FAMILIES: files (write_file/edit_file/read_file/list_dir/delete_file), web (web_search/web_fetch), a page needing JS or a login (browser_navigate, then browser_read for refs, then browser_click/browser_type), stored docs & memory (read_doc/recall/observe), images (pixel_search), code (run_python/run_tests). Your recommendation:") catch return null;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, "You are a tool-use arbiter. The agent is grinding one failing tool. In 1-2 terse sentences, tell it the single best next move — a better-suited tool (name it) or the exact fix for the error. Never suggest re-running the same call unchanged.") catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, ask.items) catch return null;
    msgs.append(gpa, '}') catch return null;
    const cm = meterBegin(app.io);
    var step = llm.complete(gpa, app.io, run_root, "arbiter", p.base_url, p.key, p.model, msgs.items, "", 160, 0.3);
    defer step.deinit(gpa);
    meterEnd(app, cm, "arbiter", .prompting, p.model, step.ok);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t\"'`*");
    if (t.len < 8 or t.len > 600) return null;
    return gpa.dupe(u8, t) catch null;
}

/// How many distinct queries the turn's search ledger remembers. It exists to be SHOWN to the reformulator, so it
/// is bounded by what is useful in a ~40-token prompt, not by memory.
const SEARCH_LOG_MAX: usize = 16;

/// Byte span of the `"query"` VALUE inside a web_search arguments object, or null when it is absent or not a plain
/// unescaped string. Escaped queries are declined rather than handled: the caller SPLICES raw bytes back into the
/// arguments JSON, and getting that wrong would corrupt a tool call to save one search.
///
/// Whitespace-tolerant, unlike argsPath's fixed `"path":"` probe. That probe only feeds ledger bookkeeping, so a
/// pretty-printed arguments object costs it one entry; here a missed match silently switches the whole
/// reformulation off, and which of the two spellings arrives is the provider's choice, not ours.
fn searchQuerySpan(args: []const u8) ?struct { start: usize, end: usize } {
    var i = std.mem.indexOf(u8, args, "\"query\"") orelse return null;
    i += "\"query\"".len;
    while (i < args.len and std.ascii.isWhitespace(args[i])) i += 1;
    if (i >= args.len or args[i] != ':') return null;
    i += 1;
    while (i < args.len and std.ascii.isWhitespace(args[i])) i += 1;
    if (i >= args.len or args[i] != '"') return null;
    const start = i + 1;
    const end = std.mem.indexOfScalarPos(u8, args, start, '"') orelse return null;
    if (end == start) return null;
    if (std.mem.indexOfScalar(u8, args[start..end], '\\') != null) return null;
    return .{ .start = start, .end = end };
}

test "searchQuerySpan: extracts a plain query, declines escaped or missing ones" {
    const a = "{\"query\":\"zig 0.16 release notes\",\"limit\":5}";
    const sp = searchQuerySpan(a).?;
    try std.testing.expectEqualStrings("zig 0.16 release notes", a[sp.start..sp.end]);
    // the splice must be able to rebuild the object around the span
    try std.testing.expectEqualStrings("{\"query\":\"", a[0..sp.start]);
    try std.testing.expectEqualStrings("\",\"limit\":5}", a[sp.end..]);
    // pretty-printed arguments are the same call — a provider that spaces its JSON must not disable the rewrite
    const b = "{ \"query\" : \"zig release\", \"source\": \"web\" }";
    const spb = searchQuerySpan(b).?;
    try std.testing.expectEqualStrings("zig release", b[spb.start..spb.end]);
    try std.testing.expect(searchQuerySpan("{\"query\":\"say \\\"hi\\\"\"}") == null);
    try std.testing.expect(searchQuerySpan("{\"query\":\"\"}") == null);
    try std.testing.expect(searchQuerySpan("{\"url\":\"x\"}") == null);
    try std.testing.expect(searchQuerySpan("{\"query\":5}") == null);
}

/// Turn the model's raw web_search query into ONE focused search string under the PROMPTING role. Returns a
/// gpa-owned query, or null to run the model's own query untouched — a failed or implausible reformulation must
/// never cost the search itself.
///
/// Ported from the swarm's scoutQuery, with the inputs a chat turn actually has. There is no knowledge-gap string
/// here; there IS the turn's intent and the list of queries already run this turn, and that list is the
/// load-bearing half. The repeat ledger blocks only an EXACT re-issue, so a model in a research spiral escapes it
/// by re-phrasing — one live run burned 107 web calls doing exactly that. Showing the reformulator what has
/// already been tried is what makes the next query land somewhere new instead of one synonym away.
fn formulateSearch(app: *App, run_root: []const u8, p: Provider, intent: []const u8, raw_query: []const u8, tried: []const []u8) ?[]u8 {
    const gpa = app.gpa;
    if (raw_query.len == 0) return null;
    var ask: std.ArrayListUnmanaged(u8) = .empty;
    defer ask.deinit(gpa);
    ask.appendSlice(gpa, "What the user wants: ") catch return null;
    ask.appendSlice(gpa, clipBytes(intent, 600)) catch return null;
    ask.appendSlice(gpa, "\nThe query as drafted: ") catch return null;
    ask.appendSlice(gpa, clipBytes(raw_query, 300)) catch return null;
    if (tried.len > 0) {
        ask.appendSlice(gpa, "\nAlready searched this turn — do NOT repeat or merely re-word any of these. If the " ++
            "draft is close to one of them, attack a DIFFERENT angle instead: the exact error string, a version, a " ++
            "file or API name, a primary source:") catch return null;
        for (tried) |q| {
            ask.appendSlice(gpa, "\n- ") catch return null;
            ask.appendSlice(gpa, clipBytes(q, 160)) catch return null;
        }
    }
    // The reformulator WRITES the queries, so it needs the date most of all — an undated model "helpfully"
    // adds a guessed year to news queries, and a wrong year is worse than no year.
    var db: [16]u8 = undefined;
    ask.appendSlice(gpa, "\nToday (UTC) is ") catch return null;
    ask.appendSlice(gpa, tools.dateStamp(app.io, &db)) catch return null;
    ask.appendSlice(gpa, " — if the query needs a date, use THIS one, never a guessed one.") catch return null;
    ask.appendSlice(gpa, "\nOutput ONE web-search query:") catch return null;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, SEARCH_QUERY_PROMPT) catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, ask.items) catch return null;
    msgs.append(gpa, '}') catch return null;
    const searchq_cm = meterBegin(app.io);
    var step = llm.complete(gpa, app.io, run_root, "searchq", p.base_url, p.key, p.model, msgs.items, "", 48, 0.3);
    defer step.deinit(gpa);
    meterEnd(app, searchq_cm, "searchq", .prompting, p.model, step.ok);
    if (!step.ok) return null;
    var q = std.mem.trim(u8, step.content, " \r\n\t\"'`*");
    if (std.mem.indexOfScalar(u8, q, '\n')) |nl| q = std.mem.trim(u8, q[0..nl], " \r\t\"'`*");
    // Sanity, mirroring scoutQuery: outside this band the reply is a refusal, a preamble, or a paragraph, none of
    // which belong in a search box. Characters that would need escaping are REJECTED rather than escaped — the
    // caller splices raw bytes into the arguments JSON, so a query carrying a quote or a backslash is not usable.
    if (q.len < 4 or q.len > 160) return null;
    if (std.mem.indexOfAny(u8, q, "\"\\\n\r\t") != null) return null;
    if (std.mem.eql(u8, q, raw_query)) return null; // unchanged — skip the splice and the "searched as" note
    return gpa.dupe(u8, q) catch null;
}

/// The afk stuck-recovery step, WRITTEN rather than templated. Rides the same bounded transcript tail as the drive
/// picker (LOOP_CTX_BYTES) under the PROMPTING role, and returns a gpa-owned instruction — or null, in which case
/// the caller falls back to AFK_STUCK_TMPL.
///
/// The tail is the whole point. This fires only once the loop is CONFIRMED stuck, and at that moment the last few
/// messages contain the thing the static template can only gesture at: the command that failed, its error, the
/// file that was not there. A generic "try a DIFFERENT approach" spends a drive step asking the model to rediscover
/// what is already on screen.
fn stuckStep(app: *App, run_root: []const u8, p: Provider, goal: []const u8, repeated_step: []const u8, conv_items: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, STUCK_SYSTEM) catch return null;
    msgs.appendSlice(gpa, "},") catch return null;
    msgs.appendSlice(gpa, msgTail(conv_items, LOOP_CTX_BYTES)) catch return null;
    var ask: std.ArrayListUnmanaged(u8) = .empty;
    defer ask.deinit(gpa);
    ask.appendSlice(gpa, "The goal: ") catch return null;
    ask.appendSlice(gpa, clipBytes(goal, 400)) catch return null;
    ask.appendSlice(gpa, "\nThe step that just repeated: ") catch return null;
    ask.appendSlice(gpa, clipBytes(repeated_step, 400)) catch return null;
    ask.append(gpa, '\n') catch return null;
    ask.appendSlice(gpa, STUCK_QUESTION) catch return null;
    msgs.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, ask.items) catch return null;
    msgs.append(gpa, '}') catch return null;
    const stuck_cm = meterBegin(app.io);
    var step = completeAux(app, run_root, "stuck", p.base_url, p.key, p.model, msgs.items, 256, 0.6);
    defer step.deinit(gpa);
    meterEnd(app, stuck_cm, "stuck", .prompting, p.model, step.ok);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t`*\"'");
    if (t.len < 24 or t.len > 900) return null; // too vague to act on, or a plan rather than a step
    if (cctx.looksLikeToolMarkup(t)) return null; // it must write an INSTRUCTION, not emit a tool call
    if (nearlySame(t, repeated_step)) return null; // it just re-issued the step that is already stuck
    return gpa.dupe(u8, t) catch null;
}

/// The afk re-drive instruction, written from the transcript tail by the PROMPTING role (see AFK_NEXT_SYSTEM).
/// Mirrors stuckStep exactly — same context slice, same guards, same "null means fall back" contract; the
/// caller posts AFK_KEEP_GOING when this returns null.
fn afkNextStep(app: *App, run_root: []const u8, p: Provider, goal: []const u8, conv_items: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, AFK_NEXT_SYSTEM) catch return null;
    msgs.appendSlice(gpa, "},") catch return null;
    msgs.appendSlice(gpa, msgTail(conv_items, LOOP_CTX_BYTES)) catch return null;
    var ask: std.ArrayListUnmanaged(u8) = .empty;
    defer ask.deinit(gpa);
    ask.appendSlice(gpa, "The goal: ") catch return null;
    ask.appendSlice(gpa, clipBytes(goal, 400)) catch return null;
    ask.append(gpa, '\n') catch return null;
    ask.appendSlice(gpa, AFK_NEXT_QUESTION) catch return null;
    msgs.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, ask.items) catch return null;
    msgs.append(gpa, '}') catch return null;
    const cm = meterBegin(app.io);
    var step = completeAux(app, run_root, "afknext", p.base_url, p.key, p.model, msgs.items, 256, 0.6);
    defer step.deinit(gpa);
    meterEnd(app, cm, "afknext", .prompting, p.model, step.ok);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t`*\"'");
    if (t.len < 16 or t.len > 900) return null; // too vague to act on, or a plan rather than a step
    if (cctx.looksLikeToolMarkup(t)) return null; // it must write an INSTRUCTION, not emit a tool call
    if (loopIsDone(t)) return null; // it just said DONE again — the caller's plain nudge is more honest
    return gpa.dupe(u8, t) catch null;
}

/// One POST-ANSWER CRITIQUE pass: hand thinking the committed answer + the original question and ask ONLY for a
/// material correction. Fresh minimal context (system + user + assistant + critique), no tools. Returns a
/// gpa-owned short note for the caller to APPEND as its own message, or null to say nothing at all.
///
/// Null is the designed outcome, not the failure case — see CRITIQUE_ABSTAIN. The three rejections below are all
/// the same guard from different angles: this call must never reproduce the answer, because appending a
/// restatement is the swap-the-text failure in a costume. A borderline note being dropped is fine; silence is the
/// default. A rewrite getting through is not.
fn critiqueAnswer(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, user_text: []const u8, answer: []const u8, tool_ledger: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, SYSTEM_PROMPT) catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, user_text) catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"assistant\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, answer) catch return null;
    // THE TOOL RECORD, as its own turn ahead of the instruction. Without it the critique was asked to spot
    // "a claim that contradicts what the tools returned" while never being shown what they returned — so it
    // guessed, and the plausible-sounding guess ("an assistant cannot drive a browser") was flatly false in
    // a session that had driven one 31 times. Ground truth first, instruction second.
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    if (tool_ledger.len > 0) {
        const rec = std.fmt.allocPrint(gpa, "TOOL RECORD for the turn that produced that answer — every tool that actually ran, with call counts: {s}", .{tool_ledger}) catch return null;
        defer gpa.free(rec);
        http.jstr(gpa, &msgs, rec) catch return null;
    } else {
        http.jstr(gpa, &msgs, "TOOL RECORD for the turn that produced that answer: no tools ran — the answer was written from the model's own knowledge and the conversation alone.") catch return null;
    }
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, CRITIQUE_PROMPT) catch return null;
    msgs.append(gpa, '}') catch return null;
    // A small output cap is part of the contract, not a saving: a correction that needs more room than this is a
    // rewrite, and it also bounds the abstain path, which is most calls.
    const reflect_cm = meterBegin(app.io);
    var step = completeAux(app, run_root, "reflect", base_url, key, model, msgs.items, 320, 0.3);
    defer step.deinit(gpa);
    meterEnd(app, reflect_cm, "reflect", .thinking, model, step.ok);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t`*\"'");
    if (t.len < CRITIQUE_MIN or t.len > CRITIQUE_MAX) return null;
    if (std.ascii.startsWithIgnoreCase(t, CRITIQUE_ABSTAIN)) return null;
    if (restatesAnswer(answer, t)) return null;
    return gpa.dupe(u8, t) catch null;
}

/// Does `note` quote a chunk of `answer` back at the user? A 48-byte window from the answer's middle appearing
/// verbatim inside a short note means the critique is restating, not correcting. Deliberately one-sided and
/// cheap — it only ever costs a note that was probably not worth appending anyway.
fn restatesAnswer(answer: []const u8, note: []const u8) bool {
    if (answer.len < 96 or note.len < 48) return false;
    const mid = answer.len / 2;
    return std.mem.indexOf(u8, note, answer[mid - 24 .. mid + 24]) != null;
}

test "critique guards: abstain, over-length, and restatement are all silence" {
    const answer = "a" ** 60 ++ "the middle chunk that must not be quoted back verbatim" ++ "b" ** 60;
    try std.testing.expect(restatesAnswer(answer, "You should know: the middle chunk that must not be quoted back verbatim, roughly."));
    try std.testing.expect(!restatesAnswer(answer, "Correction: the version number above is wrong; the current release is 0.16."));
    try std.testing.expect(!restatesAnswer("short", "short")); // too small to judge — never a restatement
    try std.testing.expect(std.ascii.startsWithIgnoreCase("ok", CRITIQUE_ABSTAIN));
    try std.testing.expect(std.ascii.startsWithIgnoreCase("OK.", CRITIQUE_ABSTAIN));
    try std.testing.expect(!std.ascii.startsWithIgnoreCase("Correction: the port is 8077, not 8088.", CRITIQUE_ABSTAIN));
}

/// Current byte length of control.jsonl (0 if absent/unreadable) — the cursor past which a later stop op counts.
/// A stat, not a read: the stop poll fires ~50×/s during a stream, so reading the whole file (O(control-size) on a
/// file that only grows across a long conversation's steers) would be a hot-path cost.
fn controlLen(app: *App, conv_dir: []const u8) usize {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{conv_dir}) catch return 0;
    defer gpa.free(path);
    const st = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch return 0;
    return std.math.cast(usize, st.size) orelse 0;
}

/// The bytes of control.jsonl past `cursor` (gpa-owned; null = nothing new / unreadable). POSITIONAL tail read,
/// mirroring convEvents — never the whole file.
fn readControlTail(app: *App, conv_dir: []const u8, cursor: usize) ?[]u8 {
    const gpa = app.gpa;
    const path = std.fmt.allocPrint(gpa, "{s}/control.jsonl", .{conv_dir}) catch return null;
    defer gpa.free(path);
    const f = std.Io.Dir.cwd().openFile(app.io, path, .{}) catch return null;
    defer f.close(app.io);
    const size: usize = std.math.cast(usize, f.length(app.io) catch 0) orelse 0;
    if (size <= cursor) return null;
    const want = @min(size - cursor, 1 << 20);
    const buf = gpa.alloc(u8, want) catch return null;
    const n = f.readPositionalAll(app.io, buf, cursor) catch {
        gpa.free(buf);
        return null;
    };
    if (n == 0) {
        gpa.free(buf);
        return null;
    }
    return buf[0..n];
}

/// True if control.jsonl carries a `"op":"stop"` in the bytes appended AFTER `cursor` (i.e. since the turn began).
/// Best-effort: any read error means "no stop" (never block the turn on a control-file hiccup).
/// Is a mid-turn steer waiting? The same tail read stopRequestedSince does, for the ops the drain folds in.
/// Peeks only: draining, folding and persisting stay in the one drain that already does all three.
fn steerPendingSince(app: *App, conv_dir: []const u8, cursor: usize) bool {
    const tail = readControlTail(app, conv_dir, cursor) orelse return false;
    defer app.gpa.free(tail);
    return std.mem.indexOf(u8, tail, "\"op\":\"steer\"") != null or std.mem.indexOf(u8, tail, "\"op\":\"say\"") != null;
}

fn stopRequestedSince(app: *App, conv_dir: []const u8, cursor: usize) bool {
    const tail = readControlTail(app, conv_dir, cursor) orelse return false;
    defer app.gpa.free(tail);
    return std.mem.indexOf(u8, tail, "\"op\":\"stop\"") != null;
}

const CtlResult = enum { none, stop };

/// Drain the conv's control.jsonl from *cursor (between drive steps): a `stop` op ENDS the turn; a `steer`/`say`
/// op INJECTS the user's text as a mid-turn user message so the next inference incorporates it — this is the user
/// "posting to steer" a running turn without stopping it. Advances *cursor past everything read.
// ---- DURABLE USER MEMORY: a user's cross-conversation facts (keys/logins/preferences) live in
// {data}/u{uid}/.veil-desk/memories.jsonl — one {"cat","text"} JSON line each.
//
// PER-USER, and it must stay that way. This file is injected verbatim into EVERY turn's system prompt
// (injectDurableMemory, called unconditionally from runTurn) and it backs get_credential. It used to be
// {data}/.veil-desk/memories.jsonl — process-global — which was harmless only because the chat backend
// was admin-only: exactly one person could ever read it. The moment a second account can run a turn, a
// global store hands every user the owner's environment notes, deploy targets and credentials with no
// prompt injection required, because it is already in the system prompt before any tool runs.
//
// Blanking ctx.durable_path for untrusted callers is NOT a substitute: it closes get_credential but not
// the injection, which builds this path directly.
//
// The desk keeps writing the legacy global file. Migration is deliberately read-only and one-way: see
// legacyMemoriesPath below.
const MEM_INJECT_CAP = 96; // newest N durable memories injected (bounded prompt)

const WITHHELD_FOOTER_FULL =
    "(the [withheld] credential values above never ride in prompts — when, and only when, a task needs one, call get_credential with a few identifying words)\n";

/// The compact twin. SYSTEM_PROMPT_COMPACT deliberately drops get_credential (see its doc comment) and the
/// compact belt does not carry it, yet that same prompt asserts "Those are ALL your tools". Emitting the FULL
/// footer to a small model therefore handed it a deadlock: a key exists, its value is withheld, and the only
/// route to it is a tool that does not exist and whose name the model is trained to refuse on sight. Observed
/// live — the veil spent five turns insisting it could not reach a credential the user had already pasted into
/// the chat, and finished by claiming it had no browser and no network either. Asking is the honest route on
/// this tier, and it is also what the tier's design intent already said should happen.
const WITHHELD_FOOTER_COMPACT =
    "(the [withheld] values above are stored but never ride in prompts, and nothing on your belt can read them — if a task needs one, ask the user to paste it; a value the user gives you in chat is yours to use in that task)\n";

test "the withheld footer never names a tool the caller's belt lacks" {
    // the exact live failure: the compact belt has no get_credential, so the compact footer must not name it
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_COMPACT, "\"get_credential\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, WITHHELD_FOOTER_COMPACT, "get_credential") == null);
    // the full belt does carry it, so the full footer may (and should) point at it
    try std.testing.expect(std.mem.indexOf(u8, TURN_TOOLS_FULL, "\"get_credential\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, WITHHELD_FOOTER_FULL, "get_credential") != null);
    // and no footer may name any other off-belt verb
    for ([_][]const u8{ "recall_hive", "cast", "open_subchat", "swarm", "absorb", "mcp_call" }) |verb| {
        if (std.mem.indexOf(u8, WITHHELD_FOOTER_COMPACT, verb) != null) {
            std.debug.print("compact withheld footer names off-belt verb: {s}\n", .{verb});
            return error.OffBeltVerbInFooter;
        }
    }
}

fn memoriesPath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/u{d}/.veil-desk/memories.jsonl", .{ app.data, uid }) catch null;
}

/// The pre-split global store. Read as a FALLBACK for uid 1 only — the local admin, who is the only
/// account that could have written it while chat was admin-gated. Never written, never read for anyone
/// else, so an existing single-user install keeps its memory and no other account inherits it.
fn legacyMemoriesPath(app: *App, uid: u64, buf: []u8) ?[]const u8 {
    if (uid != 1) return null;
    return std.fmt.bufPrint(buf, "{s}/.veil-desk/memories.jsonl", .{app.data}) catch null;
}

/// Read the durable store for a user: their own file, falling back to the legacy global one for uid 1.
/// Caller owns the returned bytes.
fn readDurable(app: *App, uid: u64) ?[]u8 {
    var pb: [700]u8 = undefined;
    if (memoriesPath(app, uid, &pb)) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(256 << 10))) |d| return d else |_| {}
    }
    var lb: [700]u8 = undefined;
    if (legacyMemoriesPath(app, uid, &lb)) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(256 << 10))) |d| return d else |_| {}
    }
    return null;
}

/// Inject the user's durable memory as a "YOUR MEMORY" system message right after the recall block. Additive: an
/// absent/empty store leaves conv_buf unchanged.
fn injectDurableMemory(app: *App, uid: u64, ws: *wsp.Workspace, compact: bool) void {
    const gpa = app.gpa;
    const data = readDurable(app, uid) orelse return;
    defer gpa.free(data);
    // gather non-empty JSON lines, keep the NEWEST cap (append order = oldest first)
    var slices: std.ArrayListUnmanaged([]const u8) = .empty;
    defer slices.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len > 0 and ln[0] == '{') slices.append(gpa, ln) catch break;
    }
    if (slices.items.len == 0) return;
    const from = slices.items.len -| MEM_INJECT_CAP;
    var block: std.ArrayListUnmanaged(u8) = .empty;
    defer block.deinit(gpa);
    block.appendSlice(gpa, "YOUR MEMORY (durable facts this user asked you to keep across conversations — keys, logins, preferences, environment). Use them; do not re-REMEMBER what's already here:\n") catch return;
    const M = struct { cat: []const u8 = "", text: []const u8 = "" };
    var any = false;
    var withheld: usize = 0;
    var injected: u32 = 0;
    for (slices.items[from..]) |ln| {
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        const tx = std.mem.trim(u8, p.value.text, " \r\n\t");
        if (tx.len == 0) continue;
        block.append(gpa, '-') catch break;
        block.append(gpa, ' ') catch break;
        if (p.value.cat.len > 0) {
            block.append(gpa, '[') catch break;
            block.appendSlice(gpa, p.value.cat) catch break;
            block.appendSlice(gpa, "] ") catch break;
        }
        // CREDENTIAL VALUES never ride the broadcast prompt (observed: two live keys shipped to a
        // third-party provider on EVERY call of every conversation). The entry stays visible — value
        // masked — so the model knows it exists; get_credential fetches it in the turn that needs it.
        if (tools.secretiveDurable(p.value.cat, tx)) {
            const masked = tools.maskSecretTokens(gpa, tx);
            defer if (masked.len > 0) gpa.free(masked);
            if (std.mem.eql(u8, masked, tx)) {
                // nothing maskable (a short secret): show only the entry's name — head up to the colon
                const cut = std.mem.indexOfScalar(u8, tx, ':') orelse @min(tx.len, 40);
                block.appendSlice(gpa, tx[0..cut]) catch break;
                block.appendSlice(gpa, ": [withheld]") catch break;
            } else block.appendSlice(gpa, masked) catch break;
            withheld += 1;
        } else block.appendSlice(gpa, tx) catch break;
        block.append(gpa, '\n') catch break;
        any = true;
        injected += 1;
    }
    if (!any) return;
    // The footer must name only tools the caller's belt ACTUALLY advertises. It used to name get_credential
    // unconditionally — but SYSTEM_PROMPT_COMPACT deliberately drops that tool (see its doc comment) and the
    // compact belt does not carry it, while that same prompt tells the model "Those are ALL your tools". A
    // small model was therefore handed a deadlock: a key exists, it is withheld, fetch it with a tool that
    // does not exist and whose name the model is trained to refuse. Observed live — the veil spent five turns
    // insisting it could not reach a credential the user had already pasted into the chat. On the compact
    // belt the honest instruction is to ask, which is also this tier's stated design intent.
    if (withheld > 0) block.appendSlice(gpa, if (compact) WITHHELD_FOOTER_COMPACT else WITHHELD_FOOTER_FULL) catch {};
    ws.bid(.durable_memory, "memories.jsonl", block.items, 0.90, 0, injected);
}

/// True if `fact` (trimmed) is already stored — exact text match against the durable store (dedup).
fn durableMemoryHas(app: *App, uid: u64, fact: []const u8) bool {
    const gpa = app.gpa;
    const data = readDurable(app, uid) orelse return false;
    defer gpa.free(data);
    const M = struct { text: []const u8 = "" };
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0 or ln[0] != '{') continue;
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (std.mem.eql(u8, std.mem.trim(u8, p.value.text, " \r\n\t"), fact)) return true;
    }
    return false;
}

/// Append one durable memory {cat,text} to the shared store (dedup on exact text). Category clamped to one short word.
fn storeDurableMemory(app: *App, uid: u64, cat_in: []const u8, fact_in: []const u8) void {
    const gpa = app.gpa;
    const fact = std.mem.trim(u8, fact_in, " \r\n\t");
    if (fact.len < 2) return;
    const fact_clip = fact[0..@min(fact.len, 260)];
    if (durableMemoryHas(app, uid, fact_clip)) return;
    var cat = std.mem.trim(u8, cat_in, " \r\n\t[]");
    if (cat.len == 0) cat = "fact";
    if (cat.len > 20) cat = cat[0..20];
    var pb: [700]u8 = undefined;
    const path = memoriesPath(app, uid, &pb) orelse return;
    // The per-uid parent may not exist yet on a fresh account, and appendFile's createFile does not
    // create parents — without this the very first REMEMBER: for a new user is silently dropped.
    if (std.fs.path.dirname(path)) |d| _ = std.Io.Dir.cwd().createDirPathStatus(app.io, d, .default_dir) catch {};
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    defer jb.deinit(gpa);
    jb.appendSlice(gpa, "{\"cat\":") catch return;
    http.jstr(gpa, &jb, cat) catch return;
    jb.appendSlice(gpa, ",\"text\":") catch return;
    http.jstr(gpa, &jb, fact_clip) catch return;
    jb.appendSlice(gpa, "}\n") catch return;
    http.appendFile(app.io, gpa, path, jb.items) catch {};
}

/// Drop durable memories whose text contains `match` (case-insensitive) — whole-file rewrite. Held under the
/// append lock across read AND write: this rewrite must be mutually exclusive with storeDurableMemory's
/// appendFile, or a concurrent chat's append that lands between this read and this write is clobbered (the
/// durable-store lost-update race that opens up once two conversations run at once).
fn forgetDurableMemory(app: *App, uid: u64, match_in: []const u8) void {
    const gpa = app.gpa;
    const match = std.mem.trim(u8, match_in, " \r\n\t");
    if (match.len < 2) return;
    var pb: [700]u8 = undefined;
    const path = memoriesPath(app, uid, &pb) orelse return;
    http.appendLock(app.io, path);
    defer http.appendUnlock(app.io, path);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, gpa, .limited(256 << 10)) catch return;
    defer gpa.free(data);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var removed = false;
    const M = struct { text: []const u8 = "" };
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        var drop = false;
        if (ln[0] == '{') {
            if (std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true })) |p| {
                defer p.deinit();
                if (std.ascii.indexOfIgnoreCase(p.value.text, match) != null) drop = true;
            } else |_| {}
        }
        if (drop) {
            removed = true;
            continue;
        }
        out.appendSlice(gpa, ln) catch return;
        out.append(gpa, '\n') catch return;
    }
    if (removed) std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// Parse a REMEMBER: body: an optional leading `[category]` then the fact. Returns cat+fact (cat defaults "fact").
fn parseRemember(body_in: []const u8) struct { cat: []const u8, fact: []const u8 } {
    const body = std.mem.trim(u8, body_in, " \t");
    if (body.len > 0 and body[0] == '[') {
        if (std.mem.indexOfScalar(u8, body, ']')) |cb| {
            const cat = std.mem.trim(u8, body[1..cb], " \t");
            return .{ .cat = if (cat.len > 0) cat else "fact", .fact = std.mem.trim(u8, body[cb + 1 ..], " \t") };
        }
    }
    return .{ .cat = "fact", .fact = body };
}

/// Act on a reply's REMEMBER:/FORGET: lines (store/forget in the shared durable memory) and return the reply with
/// those lines STRIPPED — the desk's processMemory ported. Returns an owned copy when it changed anything, else
/// null (caller keeps the original). `saved` receives the number of directives applied.
fn processMemoryDirectives(app: *App, uid: u64, text: []const u8, saved: *usize) ?[]u8 {
    const gpa = app.gpa;
    saved.* = 0;
    if (std.mem.indexOf(u8, text, "REMEMBER:") == null and std.mem.indexOf(u8, text, "FORGET:") == null) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const ln = std.mem.trim(u8, line, " \r\t");
        if (std.ascii.startsWithIgnoreCase(ln, "REMEMBER:")) {
            const spec = parseRemember(ln["REMEMBER:".len..]);
            if (spec.fact.len >= 2) {
                storeDurableMemory(app, uid, spec.cat, spec.fact);
                saved.* += 1;
            }
            continue; // strip
        }
        if (std.ascii.startsWithIgnoreCase(ln, "FORGET:")) {
            const m = std.mem.trim(u8, ln["FORGET:".len..], " \t");
            if (m.len >= 2) {
                forgetDurableMemory(app, uid, m);
                saved.* += 1;
            }
            continue; // strip
        }
        if (!first) out.append(gpa, '\n') catch return null;
        out.appendSlice(gpa, std.mem.trimEnd(u8, line, "\r")) catch return null;
        first = false;
    }
    // trim + drop a now-dangling intro line ("Saved:", "I've remembered:") left pointing at stripped directives
    var s = std.mem.trim(u8, out.items, " \r\n\t");
    if (saved.* > 0) s = stripDanglingMemoryIntro(s);
    const owned = gpa.dupe(u8, s) catch {
        out.deinit(gpa);
        return null;
    };
    out.deinit(gpa);
    return owned;
}

/// Drop a trailing intro line ("Saved preferences:", "I've remembered:") left dangling after directives were
/// stripped. Ported from the desk stripDanglingMemoryIntro.
fn stripDanglingMemoryIntro(text: []const u8) []const u8 {
    const nl = std.mem.lastIndexOfScalar(u8, text, '\n');
    const last_raw = if (nl) |i| text[i + 1 ..] else text;
    const ll = std.mem.trim(u8, last_raw, " \t*_#>`-");
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
    return std.mem.trimEnd(u8, if (nl) |i| text[0..i] else "", " \r\n\t*_#>`-");
}

/// One last control drain that persists any still-unconsumed steer as a durable user message (drainChatControl
/// does the persisting). The scratch fragments are discarded — no inference follows; the NEXT turn's history
/// replay carries the text instead. Called on every turn-completion path that isn't an explicit user stop.
fn salvageSteers(app: *App, conv_dir: []const u8, cursor: *usize) void {
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(app.gpa);
    if (drainChatControl(app, conv_dir, cursor, &scratch) == .none and scratch.items.len > 0)
        emitKV(app, conv_dir, "status", "text", "steer noted — it will lead the next turn");
}

/// Drain control.jsonl past `cursor`: a `stop` op returns .stop (cursor consumed to EOF); each `steer`/`say` op
/// is appended to `buf` as a `,{"role":"user","content":…}` fragment (the CALLER decides when that buffer is in
/// a position where a user turn is legal — directly conv_buf before an inference, or a pending list mid-tool-batch)
/// AND persisted as a durable user message. Emits a "steering:" status frame per folded op so the client sees it land.
fn drainChatControl(app: *App, conv_dir: []const u8, cursor: *usize, buf: *std.ArrayListUnmanaged(u8)) CtlResult {
    const gpa = app.gpa;
    const tail = readControlTail(app, conv_dir, cursor.*) orelse return .none;
    defer gpa.free(tail);
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const C = struct { op: []const u8 = "", text: []const u8 = "" };
        const p = std.json.parseFromSlice(C, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (std.mem.eql(u8, p.value.op, "stop")) {
            cursor.* += tail.len;
            return .stop;
        }
        if ((std.mem.eql(u8, p.value.op, "steer") or std.mem.eql(u8, p.value.op, "say")) and std.mem.trim(u8, p.value.text, " \r\n\t").len > 0) {
            buf.appendSlice(gpa, ",{\"role\":\"user\",\"content\":") catch continue;
            http.jstr(gpa, buf, p.value.text) catch {};
            buf.append(gpa, '}') catch {};
            // DURABLE: a folded steer is a real user turn — persist it so the NEXT turn's history replay (and a
            // turn that ends before acting on it) still carries the user's course correction instead of dropping
            // it when the next turn re-snapshots the control cursor past it.
            appendMsg(app, conv_dir, "user", p.value.text, "user", nowSecs(app.io));
            var sb: [200]u8 = undefined;
            emitKV(app, conv_dir, "status", "text", std.fmt.bufPrint(&sb, "steering: {s}", .{clipBytes(p.value.text, 120)}) catch "steering");
        }
    }
    cursor.* += tail.len;
    return .none;
}

/// The drive is DONE when the inference's next-step text is exactly a terminal token (desk loopIsDone): trim the
/// chatty punctuation/markers, then case-insensitively match one of the short "finished" words (<=16 bytes).
fn loopIsDone(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n.!\"'`*:");
    if (t.len == 0 or t.len > 16) return false;
    return std.ascii.eqlIgnoreCase(t, "DONE") or
        std.ascii.eqlIgnoreCase(t, "COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "GOAL COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "TASK COMPLETE") or
        std.ascii.eqlIgnoreCase(t, "FINISHED");
}

/// Repeat guard (desk nearlySame): case-insensitive substring containment either way, capped at 400 bytes so it
/// only guards short chatty next-steps, not long build instructions. A near-repeat means the drive isn't
/// progressing, so it stops instead of churning the same step.
fn nearlySame(a_in: []const u8, b_in: []const u8) bool {
    const a = std.mem.trim(u8, a_in, " \r\n\t.!?");
    const b = std.mem.trim(u8, b_in, " \r\n\t.!?");
    if (a.len == 0 or b.len == 0) return false;
    if (a.len > 400 or b.len > 400) return false;
    var la: [400]u8 = undefined;
    var lb: [400]u8 = undefined;
    for (a, 0..) |c, i| la[i] = std.ascii.toLower(c);
    for (b, 0..) |c, i| lb[i] = std.ascii.toLower(c);
    const sa = la[0..a.len];
    const sb = lb[0..b.len];
    return std.mem.indexOf(u8, sa, sb) != null or std.mem.indexOf(u8, sb, sa) != null;
}

/// {"kind":"message","role":"user","content":..}
fn emitUserRole(app: *App, conv_dir: []const u8, content: []const u8) void {
    emitRoleMessage(app, conv_dir, "user", content);
}
/// {"kind":"message","role":"assistant","content":..}
fn emitAssistant(app: *App, conv_dir: []const u8, content: []const u8) void {
    emitRoleMessage(app, conv_dir, "assistant", content);
}
/// `{"kind":"message","role":"system",..}` — an ENGINE-authored row (the loop-guard stop note), on the wire as
/// what it is. Announcing it as "assistant" is not a cosmetic mislabel: the desk folds an incoming message by
/// role, so an engine note arriving as the assistant is stored in the DESK's own transcript as the model's turn
/// and re-fed from there — re-creating, one layer out, the forged-confession loop the server-side split fixed.
fn emitEngineNote(app: *App, conv_dir: []const u8, content: []const u8) void {
    emitRoleMessage(app, conv_dir, "system", content);
}
fn emitRoleMessage(app: *App, conv_dir: []const u8, role: []const u8, content: []const u8) void {
    const gpa = app.gpa;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    ev.appendSlice(gpa, "{\"kind\":\"message\",\"role\":") catch return;
    http.jstr(gpa, &ev, role) catch return;
    ev.appendSlice(gpa, ",\"content\":") catch return;
    http.jstr(gpa, &ev, content) catch return;
    ev.append(gpa, '}') catch return;
    emitEvent(app, conv_dir, ev.items);
}

/// {"kind":"tool","tool":<name>,"state":<state>[,"preview":<preview>]}
fn emitToolState(app: *App, conv_dir: []const u8, name: []const u8, state: []const u8, preview: []const u8) void {
    const gpa = app.gpa;
    var ev: std.ArrayListUnmanaged(u8) = .empty;
    defer ev.deinit(gpa);
    ev.appendSlice(gpa, "{\"kind\":\"tool\",\"tool\":") catch return;
    http.jstr(gpa, &ev, name) catch return;
    ev.appendSlice(gpa, ",\"state\":") catch return;
    http.jstr(gpa, &ev, state) catch return;
    if (preview.len > 0) {
        ev.appendSlice(gpa, ",\"preview\":") catch return;
        http.jstr(gpa, &ev, preview) catch return;
    }
    ev.append(gpa, '}') catch return;
    emitEvent(app, conv_dir, ev.items);
}

/// Append ONE `,{"role":..,"content":..}` object to conv_buf, built whole in a scratch list first so a mid-object
/// OOM can never leave conv_buf as invalid JSON. `content` is clipped to `cap` bytes (UTF-8 safe via clipBytes).
fn appendMsgObj(gpa: std.mem.Allocator, conv_buf: *std.ArrayListUnmanaged(u8), role: []const u8, content: []const u8, cap: usize) void {
    var obj: std.ArrayListUnmanaged(u8) = .empty;
    defer obj.deinit(gpa);
    obj.appendSlice(gpa, ",{\"role\":") catch return;
    http.jstr(gpa, &obj, role) catch return;
    obj.appendSlice(gpa, ",\"content\":") catch return;
    http.jstr(gpa, &obj, clipBytes(content, cap)) catch return;
    obj.append(gpa, '}') catch return;
    conv_buf.appendSlice(gpa, obj.items) catch return;
}

/// Replay a run of stored messages.jsonl lines (`bytes`) into conv_buf as OpenAI message objects. Each stored line
/// is parsed as JSON (content is UNescaped raw text) and re-emitted via appendMsgObj — round-tripping the escaped-
/// on-disk form through jstr again would double-escape it. `cap` clips each message's content.
fn seedLines(gpa: std.mem.Allocator, conv_buf: *std.ArrayListUnmanaged(u8), bytes: []const u8, cap: usize) void {
    const M = struct { role: []const u8 = "", content: []const u8 = "", kind: []const u8 = "" };
    // ENGINE ROWS DO NOT ACCUMULATE. Each loop-guard kill writes one "this turn was cut" row; a streak of cut
    // turns used to replay every one of them, so the window filled with an escalating pile of failure notices
    // that crowded out the actual work and read as a spiralling emergency. The newest row carries everything
    // the older ones said, so only it survives replay. Counted first, then skipped on the emit pass.
    var engine_total: usize = 0;
    var count_it = std.mem.splitScalar(u8, bytes, '\n');
    while (count_it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (p.value.content.len > 0 and std.mem.eql(u8, p.value.kind, "engine")) engine_total += 1;
    }
    var engine_seen: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \r\t");
        if (ln.len == 0) continue;
        const p = std.json.parseFromSlice(M, gpa, ln, .{ .ignore_unknown_fields = true }) catch continue;
        defer p.deinit();
        if (p.value.content.len == 0) continue;
        if (std.mem.eql(u8, p.value.kind, "engine")) {
            engine_seen += 1;
            if (engine_seen < engine_total) continue; // keep only the newest
        }
        // stored role is already an OpenAI role ("user"/"assistant"/"system"); anything else falls back to user.
        // `system` is load-bearing, not cosmetic: it is how an ENGINE-authored row (a loop-guard stop note) is
        // replayed as a machine event instead of as the assistant's own words. Mid-conversation system turns are
        // already an established shape here — the rolling summary is injected exactly this way.
        const role: []const u8 = if (std.mem.eql(u8, p.value.role, "assistant"))
            "assistant"
        else if (std.mem.eql(u8, p.value.role, "system"))
            "system"
        else
            "user";
        appendMsgObj(gpa, conv_buf, role, p.value.content, cap);
    }
}

/// Drop ENGINE-authored rows from a summary span, compacting into `dest` (always shrinks; `span` may alias it).
///
/// seedLines keeps only the newest engine row in the REPLAY window, but the rolling summary reads the span that
/// scrolled PAST that window — so every stop note the window dropped was still handed to the summarizer, which is
/// told to preserve "open threads". The accumulation the replay cap removes would come straight back condensed
/// and permanent: a summary narrating a run that keeps getting cut short, re-read at the top of every later turn,
/// long after the window forgot the individual notices. An engine note is a transient machine event about ONE
/// turn; it is not part of the conversation's durable narrative and must not be summarized into it.
fn dropEngineRows(dest: []u8, span: []const u8) []const u8 {
    var w: usize = 0;
    var it = std.mem.splitScalar(u8, span, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        if (std.mem.indexOf(u8, ln, "\"kind\":\"engine\"") != null) continue;
        if (w > 0) {
            dest[w] = '\n';
            w += 1;
        }
        // leftward compaction only (w never exceeds this line's own offset), so copyForwards is the right move
        std.mem.copyForwards(u8, dest[w .. w + ln.len], ln);
        w += ln.len;
    }
    return dest[0..w];
}

/// Assemble the prior-conversation context into conv_buf under a bounded budget (chat_context): a rolling summary
/// of turns that have scrolled out of the recency window, the pinned original goal, and the recency window itself.
/// Replaces "replay the whole transcript". Best-effort: any read/parse/summary failure degrades to less context,
/// never a crash — the turn still runs on the system prompt + recall + whatever seeded.
fn assembleHistory(app: *App, conv_dir: []const u8, user_text: []const u8, conv_buf: *std.ArrayListUnmanaged(u8), varying_frag: []const u8, win_bytes: usize) void {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return;
    defer gpa.free(mpath);

    const head_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return;
    defer gpa.free(head_buf);
    // `win_bytes` — NOT cctx.HISTORY_WINDOW_BYTES. This allocation is the ONLY thing that sizes the window:
    // computeView ignores its window_bytes argument entirely and derives everything from the tail slice it is
    // handed. refreshSummary must allocate the SAME size or the two disagree about where the window starts, and
    // the band between them belongs to neither the summary nor the replay — see historyWindowBytes.
    const tail_buf = gpa.alloc(u8, win_bytes) catch return;
    defer gpa.free(tail_buf);

    const ht = cctx.readHeadTail(app.io, mpath, head_buf, tail_buf) orelse return; // no history yet → nothing to seed
    const view = cctx.computeView(ht.head, ht.tail, ht.size, win_bytes);

    // ROLLING SUMMARY: when older turns have scrolled past the recency window, inject the condensed running summary
    // of them so continuity survives beyond the window + relevance recall. CRITICAL PATH: only the PERSISTED summary
    // is loaded here (a cheap file read) — the LLM fold-in of newly-dropped history is deferred to refreshSummary at
    // end-of-turn, so the first streamed token never waits on a summarization round-trip. The injected summary can
    // therefore lag by one turn's worth of dropped middle; the recency window + goal pin + relevance recall cover it.
    if (view.gap) {
        const sum = loadSummary(app, conv_dir);
        defer if (sum.len > 0) gpa.free(sum);
        if (sum.len > 0) {
            var sc: std.ArrayListUnmanaged(u8) = .empty;
            defer sc.deinit(gpa);
            sc.appendSlice(gpa, "CONVERSATION SUMMARY (older turns of THIS conversation, condensed — everything before the messages shown below). Treat as grounded context:\n") catch {};
            sc.appendSlice(gpa, sum) catch {};
            if (sc.items.len > 0) appendMsgObj(gpa, conv_buf, "system", sc.items, cctx.SUMMARY_INJECT_CAP + 256);
        }
    }

    // PINNED GOAL: the conversation's first user message anchors the arc even after it scrolls out of the window.
    if (view.goal_line.len > 0) seedLines(gpa, conv_buf, view.goal_line, cctx.GOAL_PIN_CAP);

    // VARYING WORKSPACE CHANNEL (recall, corrections, family, plugin — varies per message): placed here —
    // after the stable prefix, before the window — so the provider's prompt-prefix cache keeps hitting on
    // system + memory + summary + goal across inferences.
    if (varying_frag.len > 0) conv_buf.appendSlice(gpa, varying_frag) catch {};

    // RECENCY WINDOW: replay the newest complete turns verbatim (includes the just-appended user message).
    seedLines(gpa, conv_buf, view.window, cctx.HISTORY_WINDOW_BYTES);

    // SAFETY NET: an EMPTY window means the newest line (the just-appended current user message) is itself larger
    // than the recency window and fell out — so the live question would ride only on the fallible rolling summary
    // (and be delayed for turns if that summary call fails, since the catch-up drains at most
    // SUMMARY_CHUNKS_PER_TURN per completed turn). Seed the current
    // message verbatim (clipped) so the model always sees the actual question it must answer.
    if (view.window.len == 0) appendMsgObj(gpa, conv_buf, "user", user_text, cctx.CURRENT_MSG_PIN_CAP);
}

/// Serializes context.json reads/writes across the (rare) case of a deferred refreshSummary on one turn's thread
/// racing the next turn's loadSummary — held only for the quick file ops, NEVER across the summarization LLM call.
var ctx_json_mtx: std.Io.Mutex = .init;

/// CRITICAL PATH: load ONLY the persisted rolling summary text from {conv_dir}/context.json (a cheap file read, no
/// LLM). The fold-in of newly-dropped history is deferred to refreshSummary at end-of-turn, so the first streamed
/// token never waits on a summarization round-trip. gpa-owned text, or an EMPTY slice (never null) if absent/garbage.
fn loadSummary(app: *App, conv_dir: []const u8) []u8 {
    const gpa = app.gpa;
    const empty: []u8 = &[_]u8{};
    const cpath = std.fmt.allocPrint(gpa, "{s}/context.json", .{conv_dir}) catch return empty;
    defer gpa.free(cpath);
    ctx_json_mtx.lockUncancelable(app.io);
    defer ctx_json_mtx.unlock(app.io);
    const raw = std.Io.Dir.cwd().readFileAlloc(app.io, cpath, gpa, .limited(1 << 20)) catch return empty;
    defer gpa.free(raw);
    const S = struct { covered: usize = 0, summary: []const u8 = "" };
    const p = std.json.parseFromSlice(S, gpa, raw, .{ .ignore_unknown_fields = true }) catch return empty;
    defer p.deinit();
    if (p.value.summary.len == 0) return empty;
    return gpa.dupe(u8, p.value.summary) catch empty;
}

/// DEFERRED (end of a NORMAL turn, after the answer is delivered): if the recency window has rolled forward past
/// what the persisted summary covers, fold the newly-dropped span into the summary (one no-tools ctxsum completion)
/// and persist it for the NEXT turn. This is the ONLY place the summary advances — kept OFF the first-token path,
/// which is the whole point. Re-reads the (now-grown) transcript for a fresh view. Best-effort: any failure leaves
/// the prior summary intact (the next turn retries). The ctxsum LLM call runs OUTSIDE the context.json lock so it
/// never blocks a concurrent loadSummary; two overlapping refreshes just race to persist and the later (wider) wins.
fn refreshSummary(app: *App, conv_dir: []const u8, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, win_bytes: usize) void {
    const gpa = app.gpa;
    const mpath = std.fmt.allocPrint(gpa, "{s}/messages.jsonl", .{conv_dir}) catch return;
    defer gpa.free(mpath);
    const head_buf = gpa.alloc(u8, cctx.HEAD_READ_BYTES) catch return;
    defer gpa.free(head_buf);
    // MUST match assembleHistory's tail_buf exactly (see historyWindowBytes). base_url/key/model above are the
    // SUMMARIZING model; `win_bytes` is sized for the model that CONSUMES the assembled prompt. On the common
    // single-provider setup those are the same model and the distinction is invisible — which is exactly why
    // sizing the window from the parameters already here would be a bug that never showed up in testing.
    const tail_buf = gpa.alloc(u8, win_bytes) catch return;
    defer gpa.free(tail_buf);
    const ht = cctx.readHeadTail(app.io, mpath, head_buf, tail_buf) orelse return;
    const view = cctx.computeView(ht.head, ht.tail, ht.size, win_bytes);
    if (!view.gap) return; // the window still covers everything → nothing has dropped that needs summarizing

    const cpath = std.fmt.allocPrint(gpa, "{s}/context.json", .{conv_dir}) catch return;
    defer gpa.free(cpath);

    // load current {covered, summary} under the lock (quick file read only)
    var covered: usize = 0;
    var summary: []u8 = &[_]u8{};
    {
        ctx_json_mtx.lockUncancelable(app.io);
        defer ctx_json_mtx.unlock(app.io);
        if (std.Io.Dir.cwd().readFileAlloc(app.io, cpath, gpa, .limited(1 << 20))) |raw| {
            defer gpa.free(raw);
            const S = struct { covered: usize = 0, summary: []const u8 = "" };
            if (std.json.parseFromSlice(S, gpa, raw, .{ .ignore_unknown_fields = true })) |p| {
                defer p.deinit();
                covered = p.value.covered;
                if (p.value.summary.len > 0) summary = gpa.dupe(u8, p.value.summary) catch &[_]u8{};
            } else |_| {}
        } else |_| {}
    }
    defer if (summary.len > 0) gpa.free(summary);

    // is there newly-dropped history to fold in? the summary should cover [goal_end, window_start)
    const target = view.window_start;
    var cursor = @max(covered, view.goal_end);
    if (target <= cursor) return; // already covered → nothing to do

    const span_buf = gpa.alloc(u8, cctx.SUMMARY_CHUNK_BYTES) catch return;
    defer gpa.free(span_buf);

    // OLDEST-FIRST CATCH-UP. Fold [cursor, target) forward one line-aligned chunk at a time, persisting after
    // EACH one, so `covered` only ever names bytes a summarizer actually read.
    //
    // The single shot this replaces read the NEWEST 256 KiB of the span and then persisted covered = target
    // regardless of how much it had read. Everything older was discarded AND marked covered: absent from the
    // window, absent from the summary, and unreachable by any later pass. That is silent permanent deletion
    // reported as success, and it is what made a long chat lose its own middle and start the work over.
    //
    // Bounded per turn because this runs before the {done} frame and inside the conversation's turn slot; the
    // next completed turn resumes at exactly this cursor. A `break` leaves the cursor un-advanced and
    // un-persisted, so a failed chunk is retried rather than skipped.
    var chunks: usize = 0;
    while (cursor < target and chunks < cctx.SUMMARY_CHUNKS_PER_TURN) : (chunks += 1) {
        const hs = cctx.readSpanHeadTrimmed(app.io, mpath, cursor, target, span_buf) orelse break;
        // Take `next` BEFORE dropEngineRows: it compacts IN PLACE into span_buf, so hs.bytes.len afterwards is
        // the filtered length, not the file bytes consumed. Advancing the ledger by that would skip real records.
        const next = cursor + hs.consumed;
        // engine stop-notes are per-turn machine events, never durable narrative — see dropEngineRows
        const span = dropEngineRows(span_buf, hs.bytes);
        if (span.len == 0) {
            // The whole chunk was engine notes. Nothing to summarize, but these bytes ARE accounted for — the
            // old code's bare `return` here would pin the cursor and stall every later catch-up behind it.
            ctx_json_mtx.lockUncancelable(app.io);
            defer ctx_json_mtx.unlock(app.io);
            persistSummary(app, cpath, next, summary);
            cursor = next;
            continue;
        }
        const updated = summarizeInto(app, run_root, base_url, key, model, summary, span, hs.clipped) orelse break; // LLM call, NO lock held
        if (summary.len > 0) gpa.free(summary); // the fold REPLACES the prior summary...
        summary = updated; // ...and becomes the next chunk's prior summary; the outer defer frees the last one
        {
            // Lock only around the file write — never across the completion above, which would block the next
            // turn's loadSummary for as long as the model takes.
            ctx_json_mtx.lockUncancelable(app.io);
            defer ctx_json_mtx.unlock(app.io);
            persistSummary(app, cpath, next, summary); // covered advances ONLY over bytes just summarized
        }
        cursor = next;
    }
}

/// One no-tools completion that rewrites the running summary to incorporate a span of just-dropped messages.
/// gpa-owned new summary (clipped) or null on failure. Kept deterministic (low temp) and short.
fn summarizeInto(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, prior_summary: []const u8, span_json: []const u8, clipped: bool) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, "You maintain a running summary of a long assistant/user conversation so older turns can be dropped from the live context without losing continuity. Be faithful and concise; preserve concrete facts, decisions, file names, and open threads. Output ONLY the updated summary, no preamble.") catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    var uc: std.ArrayListUnmanaged(u8) = .empty;
    defer uc.deinit(gpa);
    uc.appendSlice(gpa, "Running summary so far:\n") catch return null;
    uc.appendSlice(gpa, if (prior_summary.len > 0) prior_summary else "(none yet)") catch return null;
    uc.appendSlice(gpa, "\n\nOlder conversation messages now scrolling out of the live window (JSON lines, oldest to newest):\n") catch return null;
    uc.appendSlice(gpa, span_json) catch return null;
    // A chunk cut mid-record (one stored line longer than the chunk) ends in a fragment. Say so, or the model
    // summarizes half a message as a whole one and states its truncated content as fact.
    if (clipped) uc.appendSlice(gpa, "\n(The LAST record above is CUT OFF mid-message — summarize only what is actually there, and do not infer how it ends.)") catch return null;
    uc.appendSlice(gpa, "\n\nRewrite the running summary to incorporate these messages. Keep it under 250 words.") catch return null;
    http.jstr(gpa, &msgs, uc.items) catch return null;
    msgs.append(gpa, '}') catch return null;
    const ctxsum_cm = meterBegin(app.io);
    var step = llm.complete(gpa, app.io, run_root, "ctxsum", base_url, key, model, msgs.items, "", 1024, 0.3);
    defer step.deinit(gpa);
    meterEnd(app, ctxsum_cm, "ctxsum", .thinking, model, step.ok);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t");
    if (t.len == 0) return null;
    return gpa.dupe(u8, clipBytes(t, cctx.SUMMARY_INJECT_CAP)) catch null;
}

/// Persist {covered, summary} to context.json as one atomic overwrite (whole line built first). Best-effort.
fn persistSummary(app: *App, cpath: []const u8, covered: usize, summary: []const u8) void {
    const gpa = app.gpa;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const head = std.fmt.allocPrint(gpa, "{{\"covered\":{d},\"summary\":", .{covered}) catch return;
    defer gpa.free(head);
    out.appendSlice(gpa, head) catch return;
    http.jstr(gpa, &out, summary) catch return;
    out.append(gpa, '}') catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = cpath, .data = out.items }) catch {};
}

/// One no-tools completion that compresses the CURRENT turn's working log (assistant tool_call turns + tool
/// results appended since the pass began) into a short progress note, so a long/afk turn can keep going without
/// its single-turn buffer overflowing the model window. gpa-owned note (clipped) or null on failure.
fn summarizeWorkingSpan(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, span_json: []const u8) ?[]u8 {
    const gpa = app.gpa;
    var msgs: std.ArrayListUnmanaged(u8) = .empty;
    defer msgs.deinit(gpa);
    msgs.appendSlice(gpa, "{\"role\":\"system\",\"content\":") catch return null;
    http.jstr(gpa, &msgs, "You compress the working log of an in-progress task so it can continue without exceeding the context window. Preserve concrete progress: files created/edited, commands run and their key results, decisions made, and what remains. Output ONLY the compressed progress note.") catch return null;
    msgs.appendSlice(gpa, "},{\"role\":\"user\",\"content\":") catch return null;
    var uc: std.ArrayListUnmanaged(u8) = .empty;
    defer uc.deinit(gpa);
    uc.appendSlice(gpa, "Working log so far (assistant tool calls + tool results as JSON):\n") catch return null;
    uc.appendSlice(gpa, clipBytes(span_json, 200 * 1024)) catch return null; // bound the summarizer's own input
    uc.appendSlice(gpa, "\n\nWrite the compressed progress note (<= 200 words).") catch return null;
    http.jstr(gpa, &msgs, uc.items) catch return null;
    msgs.append(gpa, '}') catch return null;
    const compact_cm = meterBegin(app.io);
    var step = llm.complete(gpa, app.io, run_root, "compact", base_url, key, model, msgs.items, "", 1024, 0.3);
    defer step.deinit(gpa);
    meterEnd(app, compact_cm, "compact", .thinking, model, step.ok);
    if (!step.ok) return null;
    const t = std.mem.trim(u8, step.content, " \r\n\t");
    if (t.len == 0) return null;
    return gpa.dupe(u8, clipBytes(t, cctx.SUMMARY_INJECT_CAP)) catch null;
}

/// If this pass's working growth (everything appended after `base_len`) exceeds WORKING_COMPACT_BYTES, replace its
/// OLDER part with a single compressed progress note — the newest WORKING_KEEP_TAIL_BYTES stay verbatim — so the
/// loop can continue bounded without deleting the results the model is actively working from. Called at a STEP
/// BOUNDARY (after all of a step's tool results are appended), so the message sequence stays protocol-valid (no
/// dangling tool_calls). When no safe splice point exists the span is left alone, or folded whole past
/// WORKING_HARD_FOLD_BYTES — see the two constants for both cases.
/// Best-effort: a failed summary leaves the buffer as-is (the MAX_ITERS cap still bounds the pass).
fn compactWorking(app: *App, run_root: []const u8, base_url: []const u8, key: []const u8, model: []const u8, conv_buf: *std.ArrayListUnmanaged(u8), base_len: usize, ctx: *tools.ToolCtx, tool_obs: *std.ArrayListUnmanaged([]u8), budget: usize) void {
    if (conv_buf.items.len <= base_len or conv_buf.items.len - base_len <= budget) return;
    // The tail kept verbatim must be SMALLER than the trigger, or a fold cannot shrink the span. At the
    // stock 24 KB trigger / 32 KB tail it never did: folding only really began at 32 KB. That slack is
    // affordable on a large window and fatal on a small one, so on a tightened budget the tail is half of
    // it — every fold then halves the span and the loop is guaranteed to make progress.
    const roomy = budget >= cctx.WORKING_COMPACT_BYTES;
    const keep_tail = if (roomy) WORKING_KEEP_TAIL_BYTES else @max(2 * 1024, budget / 2);
    const hard_fold = if (roomy) WORKING_HARD_FOLD_BYTES else budget + budget / 2;
    const gpa = app.gpa;
    // MEMORY-BEFORE-FORGETTING: the span about to be folded holds tool findings whose queued observes have
    // not landed yet (the queue normally flushes at turn exit). Flush them NOW — one batched subprocess —
    // so nothing leaves the context window without first landing in neuron-db, where the per-step weave's
    // assoc recall can bring it back the moment a later step needs it. Without this, a compacted finding
    // was unreachable for the REST OF THE TURN: gone from the window, not yet in memory.
    if (tool_obs.items.len > 0) {
        memBank(app, ctx, ctx.scope, tool_obs.items);
        for (tool_obs.items) |note| gpa.free(note);
        tool_obs.clearRetainingCapacity();
    }
    // TAIL-PRESERVING FOLD: summarize only the span OLDER than the newest WORKING_KEEP_TAIL_BYTES, then put that
    // tail back verbatim after the note. Folding the whole span deleted the model's own just-read bytes and it
    // re-read them (see WORKING_KEEP_TAIL_BYTES). msgTail picks the splice point because the splice MUST land on
    // a message boundary: it anchors only on a user/assistant/system object and explicitly refuses an orphan tool
    // result — one whose tool_calls announcement is inside the folded span is an immediate provider 400.
    const span = conv_buf.items[base_len..];
    const tail = msgTail(span, keep_tail);
    // msgTail returns the whole input when it finds no valid anchor in the keep window — one enormous message,
    // or a round whose own tool results fill the window (their announcement sits further back). There is no
    // splice that doesn't tear the sequence then, so keep the span intact and wait for the next round to give
    // it an anchor; only past WORKING_HARD_FOLD_BYTES do we fall back to folding the span whole.
    const splice = tail.len < span.len;
    if (!splice and span.len < hard_fold) return;
    const older = if (splice) span[0 .. span.len - tail.len - 1] else span; // -1 drops msgTail's skipped comma
    if (older.len == 0) return; // nothing older than the tail — nothing to summarize
    const note = summarizeWorkingSpan(app, run_root, base_url, key, model, older) orelse return;
    defer gpa.free(note);
    // `tail` points INTO conv_buf: shrinking only retains the bytes, and appending the note writes straight over
    // them (a grow would reallocate outright). Copy it out — with its joining comma — BEFORE either happens.
    const kept: ?[]u8 = if (splice) (std.fmt.allocPrint(gpa, ",{s}", .{tail}) catch return) else null;
    defer if (kept) |k| gpa.free(k);
    conv_buf.shrinkRetainingCapacity(base_len);
    const note_at = conv_buf.items.len;
    appendMsgObj(gpa, conv_buf, "assistant", note, cctx.SUMMARY_INJECT_CAP);
    // Under a learned echo quirk the folded note must carry reasoning_content like every assistant turn
    // (the enforcement is not tool-call-only); bare, it would 400 the next inference and spend a heal.
    // An OOM leaves it bare — the in-pass heal then repairs it at the cost of that one round-trip.
    if (conv_buf.items.len > note_at and llm.reasoningEchoFor(app.io, model))
        conv_buf.insertSlice(gpa, note_at + llm.ASSISTANT_OBJ_HEAD.len, ",\"reasoning_content\":\"\"") catch {};
    // One shot, so an OOM here drops the tail (the old behaviour) instead of stranding a dangling comma.
    if (kept) |k| conv_buf.appendSlice(gpa, k) catch {};
}

test "file ledger: mutation parsing, upsert, args-path extraction, and the woven ground-truth block" {
    const gpa = std.testing.allocator;

    // the exact success shapes tools.zig returns (identical when delegated to a client)
    const w = parseFileMutation("write_file", "wrote lib/neurondb.ts \xe2\x80\x94 file is now 1117 bytes").?;
    try std.testing.expectEqualStrings("lib/neurondb.ts", w.path);
    try std.testing.expectEqual(@as(u64, 1117), w.bytes);
    const e = parseFileMutation("edit_file", "edited app/layout.tsx \xe2\x80\x94 2 op(s) applied, file is now 528 bytes").?;
    try std.testing.expectEqualStrings("app/layout.tsx", e.path);
    try std.testing.expectEqual(@as(u64, 528), e.bytes);
    const a = parseFileMutation("write_file", "appended to notes.md \xe2\x80\x94 file is now 90 bytes").?;
    try std.testing.expectEqualStrings("notes.md", a.path);
    // an em-dash IN the path: the separator is the LAST " — " before the marker (adversarial-audit find)
    const d = parseFileMutation("write_file", "wrote a \xe2\x80\x94 b.txt \xe2\x80\x94 file is now 7 bytes").?;
    try std.testing.expectEqualStrings("a \xe2\x80\x94 b.txt", d.path);
    try std.testing.expectEqual(@as(u64, 7), d.bytes);
    // failures and non-file tools never mint ledger entries — including edit_file's does-not-exist failure,
    // whose result STARTS with a raw model path that can itself start with "edited " (audit find: the
    // "file is now" marker requirement is what rejects it)
    try std.testing.expect(parseFileMutation("write_file", "could not write file") == null);
    try std.testing.expect(parseFileMutation("write_file", "bad path \xe2\x80\x94 stay inside the workdir") == null);
    try std.testing.expect(parseFileMutation("edit_file", "edited notes.md does not exist \xe2\x80\x94 edit_file only changes an EXISTING file; use write_file to create a new one.") == null);
    try std.testing.expect(parseFileMutation("web_fetch", "wrote nothing \xe2\x80\x94 file is now 5 bytes") == null);
    try std.testing.expect(parseFileMutation("read_file", "not found") == null);

    // args-path: plain path parses; escaped path abstains (fail-safe)
    try std.testing.expectEqualStrings("lib/auth.ts", argsPath("{\"path\":\"lib/auth.ts\"}").?);
    try std.testing.expect(argsPath("{\"path\":\"a\\b.ts\"}") == null);
    try std.testing.expect(argsPath("{\"query\":\"no path here\"}") == null);

    // ledger: upsert by path, exact lookup, bounded block rendering
    var led: FileLedger = .{};
    defer led.deinit(gpa);
    led.note(gpa, "lib/neurondb.ts", 1117);
    led.note(gpa, "app/layout.tsx", 419);
    led.note(gpa, "app\\layout.tsx", 528); // Windows separators are the SAME file — upsert, not duplicate
    try std.testing.expectEqual(@as(usize, 2), led.files.items.len);
    try std.testing.expectEqual(@as(u64, 528), led.has("app/layout.tsx").?);
    try std.testing.expectEqual(@as(u64, 528), led.has("app\\layout.tsx").?); // separator-insensitive lookup
    try std.testing.expect(led.has("never-written.ts") == null);
    try std.testing.expect(!led.partial);

    var blk: std.ArrayListUnmanaged(u8) = .empty;
    defer blk.deinit(gpa);
    ledgerBlock(gpa, &led, &blk);
    try std.testing.expect(std.mem.indexOf(u8, blk.items, "lib/neurondb.ts (1117 B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk.items, "app/layout.tsx (528 B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk.items, "ENGINE GROUND TRUTH") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk.items, "never successfully written") != null); // complete ⇒ may quantify

    // a PARTIAL ledger must stop universally quantifying (audit find: overclaiming invites blind re-writes)
    led.partial = true;
    var blkp: std.ArrayListUnmanaged(u8) = .empty;
    defer blkp.deinit(gpa);
    ledgerBlock(gpa, &led, &blkp);
    try std.testing.expect(std.mem.indexOf(u8, blkp.items, "never successfully written") == null);
    try std.testing.expect(std.mem.indexOf(u8, blkp.items, "may be INCOMPLETE") != null);

    // an empty ledger weaves nothing
    var none: FileLedger = .{};
    defer none.deinit(gpa);
    var blk2: std.ArrayListUnmanaged(u8) = .empty;
    defer blk2.deinit(gpa);
    ledgerBlock(gpa, &none, &blk2);
    try std.testing.expectEqual(@as(usize, 0), blk2.items.len);

    // a disk-surveyed (restart-resume) ledger words the block as RESUME, not as observed writes
    led.partial = false;
    led.from_disk = true;
    var blk3: std.ArrayListUnmanaged(u8) = .empty;
    defer blk3.deinit(gpa);
    ledgerBlock(gpa, &led, &blk3);
    try std.testing.expect(std.mem.indexOf(u8, blk3.items, "RESUMING earlier work") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk3.items, "Do NOT start over") != null);
}

test "continuation-shaped turns: resume phrasings match, real instructions do not" {
    try std.testing.expect(continuationShaped("continue"));
    try std.testing.expect(continuationShaped("  Continue.  "));
    try std.testing.expect(continuationShaped("keep going"));
    try std.testing.expect(continuationShaped("finish your task"));
    try std.testing.expect(continuationShaped(""));
    // the desk's auto-loop arm note is longer than the 80-byte gate — matched by its prefix
    try std.testing.expect(continuationShaped("Auto-loop armed: continue driving toward the goal — pick up the plan (or the last goal) where it left off."));
    try std.testing.expect(!continuationShaped("add a login page with NextAuth and bcrypt"));
    try std.testing.expect(!continuationShaped("the feed pagination is broken — fix it, write tests for it, then redeploy the app to vercel"));
    // word boundary: head words embedded in bigger words are NOT continuations
    try std.testing.expect(!continuationShaped("nextjs app router setup"));
    try std.testing.expect(!continuationShaped("proceedings review"));
    try std.testing.expect(continuationShaped("next, wire the feed api"));
}

test "the loop-stop note speaks as the ENGINE, never in the model's first person" {
    // The spiral this guards: the note is committed to the durable transcript and replayed to the NEXT turn. In
    // the model's voice it reads as the model's own admission of being stuck, sitting right under whatever the
    // user just asked — so a "are you stuck?" turn is answered by a transcript that appears to agree, and the run
    // ruminates instead of working. Any first-person pronoun here re-opens that door.
    try std.testing.expect(std.mem.startsWith(u8, LOOP_STOP_NOTE, "[engine:"));
    for ([_][]const u8{ "I ", "I'", " my ", " me ", " I." }) |first_person|
        try std.testing.expect(std.mem.indexOf(u8, LOOP_STOP_NOTE, first_person) == null);
    // it still has to DO its job: say the turn was cut, and that finished work on disk is real
    try std.testing.expect(std.mem.indexOf(u8, LOOP_STOP_NOTE, "loop guard") != null);
    try std.testing.expect(std.mem.indexOf(u8, LOOP_STOP_NOTE, "workdir") != null);
}

test "replay: an engine row stays a system turn, and only the NEWEST engine row survives" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    // three cut turns in a row, interleaved with real work — the exact shape a spiral writes
    const stored =
        \\{"role":"user","content":"build the parser","kind":"user","ts":1}
        \\{"role":"system","content":"[engine: cut #1]","kind":"engine","ts":2}
        \\{"role":"user","content":"are you stuck exactly?","kind":"user","ts":3}
        \\{"role":"system","content":"[engine: cut #2]","kind":"engine","ts":4}
        \\{"role":"assistant","content":"real narration","kind":"veil","ts":5}
        \\{"role":"system","content":"[engine: cut #3]","kind":"engine","ts":6}
    ;
    seedLines(gpa, &buf, stored, 4096);
    const out = buf.items;
    // the pile does NOT accumulate: the two older cut notices are gone, the newest is kept
    try std.testing.expect(std.mem.indexOf(u8, out, "cut #1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "cut #2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "cut #3") != null);
    // and the survivor is a SYSTEM turn — never the assistant's own words
    try std.testing.expect(std.mem.indexOf(u8, out, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"role\":\"assistant\",\"content\":\"[engine:") == null);
    // ordinary rows are untouched by any of this
    try std.testing.expect(std.mem.indexOf(u8, out, "build the parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "are you stuck exactly?") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "real narration") != null);
}

test "a meta-question about the run is never mistaken for the goal" {
    // "are you stuck?" used to BECOME goal_text, so the drive picker announced it as "THE GOAL of this
    // conversation", the stuck template told the model to re-read it, and recall keyed on it. The engine was
    // instructing the model to work on the meta-question, then the loop guard killed it for not progressing.
    try std.testing.expect(metaQuestionShaped("are you stuck?"));
    try std.testing.expect(metaQuestionShaped("are you stuck exactly?"));
    try std.testing.expect(metaQuestionShaped("  Are you stuck?  "));
    try std.testing.expect(metaQuestionShaped("why is this taking so long?"));
    try std.testing.expect(metaQuestionShaped("what are you doing?"));
    try std.testing.expect(metaQuestionShaped("what happened?"));
    try std.testing.expect(metaQuestionShaped("status?"));
    try std.testing.expect(metaQuestionShaped("still there?"));
    try std.testing.expect(metaQuestionShaped("how's it going?"));
    // NOT meta: real work that happens to be phrased as a question keeps being the goal
    try std.testing.expect(!metaQuestionShaped("why does the parser drop CRLF on windows — can you fix it and add a test?"));
    try std.testing.expect(!metaQuestionShaped("can you add a login page with NextAuth?"));
    // NOT meta — the false positives a first cut of this predicate actually had. Each of these is ordinary work
    // whose FIRST BYTES collide with a meta phrase; matching one silently steers the turn by a stale goal, which
    // is the same harm this predicate exists to prevent, merely pointed the other way.
    try std.testing.expect(!metaQuestionShaped("why is this test failing?"));
    try std.testing.expect(!metaQuestionShaped("why is it returning 404?"));
    try std.testing.expect(!metaQuestionShaped("status of the migration?"));
    try std.testing.expect(!metaQuestionShaped("statuses of the queued jobs?"));
    try std.testing.expect(!metaQuestionShaped("why did you drop the index on users?"));
    try std.testing.expect(!metaQuestionShaped("are we handling null bytes in the parser?"));
    try std.testing.expect(!metaQuestionShaped("did you get the CSV export working?"));
    try std.testing.expect(!metaQuestionShaped("are website builds cached?")); // byte-prefix of "are we"
    try std.testing.expect(!metaQuestionShaped("are workers restarted on deploy?"));
    // NOT meta: no question mark at all
    try std.testing.expect(!metaQuestionShaped("are you stuck"));
    try std.testing.expect(!metaQuestionShaped("add a login page"));
    try std.testing.expect(!metaQuestionShaped(""));
    // a real instruction is never swallowed, which is what the tier-0/1 caution is about
    try std.testing.expect(!metaQuestionShaped("continue"));
}

test "the recency window is sized to the model that CONSUMES the prompt, and never below its floor" {
    const t = std.testing;
    // A roomy hosted model keeps today's behaviour byte-for-byte — this must not perturb anything that works.
    try t.expectEqual(cctx.HISTORY_WINDOW_BYTES, historyWindowBytes("https://api.anthropic.com/v1", "claude-opus-4-8", 13 * 1024));
    try t.expectEqual(cctx.HISTORY_WINDOW_BYTES, historyWindowBytes("https://api.example.com", "deepseek-v4-pro", 8 * 1024));

    // A small local window tightens rather than replaying 28 KB into a context that cannot hold it.
    const tight = historyWindowBytes("http://127.0.0.1:11434", "the-veil-12b", 13 * 1024);
    try t.expect(tight < cctx.HISTORY_WINDOW_BYTES);
    try t.expect(tight >= HISTORY_WINDOW_MIN_BYTES); // never below the floor: a turn must see its own last exchange
    try t.expectEqual(@as(usize, 0), tight % (4 * 1024)); // quantized, so a one-grant belt change cannot wobble it

    // A bigger tool belt leaves less room for history — the belt is the dominant term on a small window.
    const lean = historyWindowBytes("http://127.0.0.1:11434", "the-veil-12b", 2 * 1024);
    const fat = historyWindowBytes("http://127.0.0.1:11434", "the-veil-12b", 20 * 1024);
    try t.expect(lean >= fat);

    // Pathological input must not underflow into a huge window (the failure that would replay the whole file).
    try t.expect(historyWindowBytes("http://127.0.0.1:11434", "the-veil-12b", 10 * 1024 * 1024) == HISTORY_WINDOW_MIN_BYTES);
}

test "the loop-stop and escalation thresholds leave a round for the arbiter to be READ" {
    // A pure echo-grind accrues its first loop strike and its first failure-streak point on the SAME inference,
    // so fail_streak and loop_refusals advance in lockstep. The arbiter spends a real completion at fail_streak
    // == 3; if the turn is cut at loop_refusals == 3 the advice is generated and discarded unread. There must be
    // at least one inference left AFTER the arbiter round. Locked so the two constants cannot silently re-collide.
    const ARBITER_AT: u32 = 3;
    try std.testing.expect(LOOP_STOP_REFUSALS > ARBITER_AT);
    // and the whole ladder still has to fit inside one pass
    try std.testing.expect(@as(usize, ECHO_LIMIT) + LOOP_STOP_REFUSALS < MAX_ITERS);
}

test "engine stop-notes are never laundered into the rolling summary" {
    // seedLines caps the REPLAY window at the newest engine row, but the summary reads the span that scrolled
    // past it — so without this filter the notices come back condensed and permanent ("the run keeps getting
    // cut short"), which is the accumulation the replay cap exists to stop, wearing a different hat.
    var buf: [1024]u8 = undefined;
    const span =
        \\{"role":"user","content":"build the parser","kind":"user","ts":1}
        \\{"role":"system","content":"[engine: cut #1]","kind":"engine","ts":2}
        \\{"role":"assistant","content":"wrote parser.zig","kind":"veil","ts":3}
        \\{"role":"system","content":"[engine: cut #2]","kind":"engine","ts":4}
    ;
    const kept = dropEngineRows(&buf, span);
    try std.testing.expect(std.mem.indexOf(u8, kept, "cut #1") == null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "cut #2") == null);
    // the real conversation survives intact, still one record per line
    try std.testing.expect(std.mem.indexOf(u8, kept, "build the parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "wrote parser.zig") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, kept, "\n"));
    // a span with nothing to drop is returned unharmed
    const clean = "{\"role\":\"user\",\"content\":\"hi\",\"kind\":\"user\",\"ts\":1}";
    var b2: [256]u8 = undefined;
    try std.testing.expectEqualStrings(clean, dropEngineRows(&b2, clean));
}

test "a guard-refused call still feeds the failure streak that breaks a grind" {
    // The spiral's dead end: refused calls never execute, so the nudge/arbiter that exist to force a DIFFERENT
    // approach were gated off by the very condition that needed them. Refusal evidence counts now.
    try std.testing.expect(streakEligible(true, false, false)); // ordinary executed call
    try std.testing.expect(streakEligible(false, true, false)); // echo-refused — the spiral case
    try std.testing.expect(streakEligible(false, false, true)); // ledger repeat from an EARLIER batch
    // a same-batch duplicate is NOT evidence: the model could not yet have seen feedback to ignore
    try std.testing.expect(!streakEligible(false, false, false));
}

test "looksCredentialed: credential keys drop the cue; ordinary cues pass" {
    try std.testing.expect(looksCredentialed("{\"url\":\"https://x.io\",\"headers\":{\"Authorization\":\"Bearer sk-\""));
    try std.testing.expect(looksCredentialed("{\"cmd\":\"export API_KEY=abc\"}"));
    try std.testing.expect(!looksCredentialed("{\"query\":\"neuron-db worker REST endpoints\"}"));
    try std.testing.expect(!looksCredentialed("{\"path\":\"lib/feed.ts\"}"));
}

test "turn slots: one user cannot take the whole server" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Reset the shared table — these globals outlive any single test.
    for (&active_lens) |*l| l.* = 0;
    for (&active_uids) |*u| u.* = 0;
    configureTurnLimits(8, 2); // 8 slots, 2 per account

    // One account fills its share and is then refused, while five slots stand free.
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "a1", 7));
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "a2", 7));
    try t.expectEqual(TurnDenied.user_at_cap, beginTurn(io, "a3", 7));

    // A DIFFERENT account still gets in — this is the whole point of the cap.
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "b1", 8));
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "b2", 8));

    // The same conversation twice is refused for its own reason, not the share.
    try t.expectEqual(TurnDenied.conv_busy, beginTurn(io, "a1", 7));

    // Releasing frees the holder's share again.
    endTurn(io, "a1");
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "a3", 7));
    for (&active_lens) |*l| l.* = 0;
    for (&active_uids) |*u| u.* = 0;
}

test "turn slots: a full server says so, and endTurn clears the owner" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (&active_lens) |*l| l.* = 0;
    for (&active_uids) |*u| u.* = 0;
    configureTurnLimits(2, 2); // deliberately tiny: 2 slots

    try t.expectEqual(TurnDenied.ok, beginTurn(io, "c1", 1));
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "c2", 2));
    // Third caller is a different user, under its own cap — the SERVER is what is full.
    try t.expectEqual(TurnDenied.server_full, beginTurn(io, "c3", 3));

    // A released slot must not keep counting against the user who held it.
    endTurn(io, "c1");
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "c3", 3));
    for (&active_lens) |*l| l.* = 0;
    for (&active_uids) |*u| u.* = 0;
    configureTurnLimits(64, 8); // restore the defaults for any later test
}

test "turnWillConsume: a running turn is not the same question as a readable op" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (&active_lens) |*l| l.* = 0;
    for (&active_uids) |*u| u.* = 0;
    for (&active_ctrl) |*c| c.* = null;
    configureTurnLimits(8, 4);

    // NOTHING RUNNING. The op is on disk and every future turn will snapshot its cursor past it.
    try t.expect(!isTurnLive(io, "k1"));
    try t.expect(!turnWillConsume(io, "k1", 0));
    try t.expect(!turnWillConsume(io, "k1", 4096));

    // THE DEFECT, exactly. The slot is claimed and isTurnLive says true — truthfully — but the turn has not
    // snapshotted its control cursor yet, so that snapshot will land PAST an op already on disk and skip it.
    // Answering this endpoint with isTurnLive hands the client a `true` for words nobody will ever read.
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "k1", 1));
    try t.expect(isTurnLive(io, "k1"));
    try t.expect(!turnWillConsume(io, "k1", 900));

    // Once the turn publishes where it starts reading, an op at or after that point IS inside every tail it
    // reads, and an op before it is not.
    publishCtrlCursor(io, "k1", 900);
    try t.expect(turnWillConsume(io, "k1", 900)); // exactly at the cursor — drainChatControl reads from here
    try t.expect(turnWillConsume(io, "k1", 1400)); // appended after the turn began — the ordinary steer
    try t.expect(!turnWillConsume(io, "k1", 899)); // one byte behind: written before the turn looked

    // A cursor of 0 (no control.jsonl existed when the turn began) must not orphan the very first op.
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "k2", 1));
    publishCtrlCursor(io, "k2", 0);
    try t.expect(turnWillConsume(io, "k2", 0));

    // Conversations do not answer for each other, and an unknown conv is simply "no".
    try t.expect(!turnWillConsume(io, "k3", 0));
    try t.expect(!turnWillConsume(io, "", 0));

    // A RELEASED SLOT MUST FORGET ITS CURSOR. Without that, the next turn to take the slot inherits a stale
    // number and can report `true` for an op it will never read — the same lie, one turn later.
    endTurn(io, "k1");
    try t.expect(!turnWillConsume(io, "k1", 5000));
    try t.expectEqual(TurnDenied.ok, beginTurn(io, "k1", 1));
    try t.expect(isTurnLive(io, "k1"));
    try t.expect(!turnWillConsume(io, "k1", 5000)); // re-claimed, not yet published → still "no"

    // Publishing for a conv that holds no slot is a no-op, not a write into someone else's row.
    publishCtrlCursor(io, "k9", 0);
    try t.expect(!turnWillConsume(io, "k9", 0));
    try t.expect(!turnWillConsume(io, "k1", 5000));

    for (&active_lens) |*l| l.* = 0;
    for (&active_uids) |*u| u.* = 0;
    for (&active_ctrl) |*c| c.* = null;
    configureTurnLimits(64, 8);
}

test "turn limits clamp to something sane rather than trusting the environment" {
    const t = std.testing;
    configureTurnLimits(0, 0); // nonsense in
    try t.expect(turnLimits().capacity >= 1);
    try t.expect(turnLimits().per_user >= 1);
    configureTurnLimits(9999, 9999); // above the table
    try t.expectEqual(@as(usize, MAX_ACTIVE_TURNS), turnLimits().capacity);
    try t.expect(turnLimits().per_user <= turnLimits().capacity);
    configureTurnLimits(64, 0); // 0 per-user = derive a share
    try t.expectEqual(@as(usize, 8), turnLimits().per_user);
}

test "the chat turn's output budget follows the model's window, not a constant" {
    const t = std.testing;
    const gpa = t.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const HOSTED = "https://api.deepseek.com/v1";
    const LOCALHOST = "http://127.0.0.1:11434/v1";

    // A big-window model must be able to emit a whole FILE in one call. The flat cap this replaced was 4096,
    // and every failure it caused was a turn that wanted more than that — so "more than the old constant" is
    // the property, stated against the window the catalog actually reports rather than a remembered number.
    const wide = turnTokenBudget(&env, HOSTED, "deepseek-v4-pro");
    try t.expect(modelcfg.senseModel("deepseek-v4-pro", false).ctx_k * 1024 >= 32768);
    try t.expect(wide > 4096);

    // Proportional, not uniform: a model that cannot hold a big window is not asked to fill one. Derive the
    // expectation from the same catalog reading the function uses, so a catalog change moves both together.
    const small_id = "llama3.1:8b";
    const small_ctx = modelcfg.senseModel(small_id, true).ctx_k * 1024;
    const narrow = turnTokenBudget(&env, LOCALHOST, small_id);
    if (small_ctx < 32768) try t.expect(narrow < wide);
    try t.expect(narrow >= 1024); // ...but never below the floor: even a small model must finish a tool call

    // NL_MAX_TOKENS is the one override, and it is clamped at both ends rather than trusted.
    try env.put("NL_MAX_TOKENS", "16000");
    try t.expectEqual(@as(u32, 16000), turnTokenBudget(&env, HOSTED, "deepseek-v4-pro"));
    try env.put("NL_MAX_TOKENS", "999999");
    try t.expectEqual(@as(u32, 32768), turnTokenBudget(&env, HOSTED, "deepseek-v4-pro"));
    try env.put("NL_MAX_TOKENS", "1");
    try t.expectEqual(@as(u32, 256), turnTokenBudget(&env, HOSTED, "deepseek-v4-pro"));
    try env.put("NL_MAX_TOKENS", "not a number"); // garbage falls back to the derived budget, never to zero
    try t.expectEqual(wide, turnTokenBudget(&env, HOSTED, "deepseek-v4-pro"));
}

// ---------------------------------------------------------------------------
// tests — the two REASONING upgrades (recon-before-plan, mid-turn course check). Both add a model call, and
// a model call cannot be asserted here; what CAN be asserted is the part that must hold no matter what the
// model says. For recon that is the whitelist — a planning pass must not be able to change the project it
// exists to observe. For the course check it is the abstain discipline — silence must be the default, because
// a false correction is paid on every step of a working loop while a missed one merely leaves things as they
// were. Both features also default ON, and an unset kill switch reading as "off" would ship nothing at all.
// ---------------------------------------------------------------------------

test "recon can only LOOK: no probe on the whitelist can change anything" {
    const t = std.testing;
    // The engine hands each probe straight to tools.execute, which is the FULL tool surface. So the
    // whitelist is the only thing standing between "plan this task" and a planning pass writing files
    // before the user has even seen a plan. Every one of these must be absent.
    const mutating = [_][]const u8{
        "write_file",    "edit_file",   "delete_file", "run_python",   "run_tests",
        "host_command",  "make_tool",   "patch_system", "cast",        "stop_swarm",
        "browser_click", "browser_type", "browser_navigate", "observe", "share",
        "get_credential", "stage_delivery", "propose_change", "open_subchat", "send_message",
    };
    for (RECON_TOOLS) |probe| {
        for (mutating) |bad| {
            if (std.mem.eql(u8, probe, bad)) {
                std.debug.print("\nRECON_TOOLS contains the mutating tool '{s}'\n", .{probe});
                return error.ReconToolMutates;
            }
        }
    }
    // And the list is non-empty in the first place — an empty whitelist would silently disable the feature
    // while every test above still passed.
    try t.expect(RECON_TOOLS.len > 0);
    try t.expect(RECON_MAX_PROBES > 0 and RECON_MAX_PROBES <= 5); // bounded: recon is a look, not the work
}

test "course check: silence is the default, and only a concrete correction redirects the loop" {
    const t = std.testing;

    // ABSTAIN, in every shape a model actually produces it.
    try t.expect(courseVerdict("OK") == null);
    try t.expect(courseVerdict("ok") == null);
    try t.expect(courseVerdict("  OK.  ") == null);
    try t.expect(courseVerdict("`OK`") == null);
    try t.expect(courseVerdict("\"OK\"") == null);
    try t.expect(courseVerdict("") == null);

    // A HEDGED abstain is still an abstain. The reviewer approved the step; the trailing musing is exactly
    // how a working loop gets dragged sideways by a reviewer that had no actual objection.
    try t.expect(courseVerdict("OK, though you could also consider refactoring the parser while you are here") == null);
    try t.expect(courseVerdict("OK - but it might be nicer to extract that into its own helper function first") == null);

    // TOO SHORT to act on. "Try something else" names nothing, and swapping a concrete next step for a vague
    // one makes the loop strictly worse.
    try t.expect(courseVerdict("try something else") == null);
    try t.expect(courseVerdict("wrong approach") == null);

    // A reviewer that tried to ACT gets discarded rather than executed — it was told not to call tools, and
    // its markup must never reach the worker as an instruction.
    try t.expect(courseVerdict("<tool_call>{\"name\":\"write_file\",\"arguments\":{\"path\":\"x\"}}</tool_call> and then fix the parser properly") == null);

    // A REAL correction survives, trimmed, and comes back as a slice of the input.
    const real = "You are about to write tests for the old ref-based click path, but that path was replaced two steps ago. Read session.zig first, then test the coordinate path instead.";
    const got = courseVerdict(real) orelse return error.CorrectionSwallowed;
    try t.expectEqualStrings(real, got);
    // Decoration around a real correction does not disqualify it.
    const decorated = try std.fmt.allocPrint(t.allocator, "  \"{s}\"  ", .{real});
    defer t.allocator.free(decorated);
    const got2 = courseVerdict(decorated) orelse return error.CorrectionSwallowed;
    try t.expectEqualStrings(real, got2);
}

test "both upgrades default ON: only an explicit 0/false disables them" {
    const t = std.testing;
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();

    // UNSET is the state on every machine that has not been told otherwise. If this read as disabled, the
    // whole feature would ship dark and nobody would know.
    try t.expect(!envDisabled(&env, "NL_CHAT_RECON"));
    try t.expect(!envDisabled(&env, "NL_CHAT_COURSE"));

    // The kill switches work, in the spellings an operator actually types.
    for ([_][]const u8{ "0", "false", "FALSE", " 0 ", "False\n" }) |off| {
        try env.put("NL_CHAT_RECON", off);
        try t.expect(envDisabled(&env, "NL_CHAT_RECON"));
    }
    // Anything else is ON — including an empty string and a typo'd value. A misconfigured variable must
    // not silently turn reasoning off; the only way off is to mean it.
    for ([_][]const u8{ "1", "true", "yes", "", "no", "off" }) |on| {
        try env.put("NL_CHAT_RECON", on);
        try t.expect(!envDisabled(&env, "NL_CHAT_RECON"));
    }
}

test "every AUXILIARY completion bounds its prompt — only the real turn sends the whole transcript" {
    // A chat turn fires one streamed `chat` call plus a dozen auxiliary completions (loop, lesson,
    // recon, course, plan, planrec, summary, arbiter, searchq, stuck, reflect, ctxsum, compact). The
    // streamed one legitimately carries the whole conversation — that IS the turn. Every auxiliary one
    // is a small distillation job and must send a BOUNDED slice, because it is billed as fresh prefill:
    // toolless requests cannot reuse the provider's tools-bearing cached prefix, and several run on the
    // thinking provider while the turn runs on coding, so there is no same-endpoint prefix either.
    //
    // Two have now been fixed for exactly this (the drive picker, then `lesson` in 0082), each found
    // long after it shipped because nothing said "an aux call may not send conv_buf". This is that rule.
    const SRC = @embedFile("engine.zig");
    const needle = "llm" ++ ".complete(";
    var i: usize = 0;
    var checked: usize = 0;
    while (std.mem.indexOfPos(u8, SRC, i, needle)) |at| {
        // The call's arguments run to the end of that source line — long enough to hold the messages arg.
        const eol = std.mem.indexOfScalarPos(u8, SRC, at, '\n') orelse SRC.len;
        const call = SRC[at..eol];
        i = at + needle.len;
        checked += 1;
        if (std.mem.indexOf(u8, call, "conv_buf.items") != null) {
            std.debug.print(
                "\nan auxiliary llm.complete sends the WHOLE conv_buf:\n  {s}\n" ++
                    "Bound it like summarizeTurn does — msgTail(conv_buf.items, SUMMARY_CTX_BYTES) into a local\n" ++
                    "message list — or this pays a full uncached prefill for a few hundred tokens of output.\n",
                .{call},
            );
            return error.UnboundedAuxiliaryPrompt;
        }
    }
    // Not vacuous: the auxiliary calls really are there. If a refactor renames the call or moves these
    // elsewhere, fail loudly rather than passing on zero matches.
    try std.testing.expect(checked >= 8);

    // ...and the streamed turn DOES still send the whole transcript. If this ever stops being true the
    // rule above has been satisfied by crippling the actual conversation, which is not the intent.
    try std.testing.expect(std.mem.indexOf(u8, SRC, "completeStream(" ) != null);
}

/// The subtask numbers a planrec reply marks complete, from "done: 1, 2". Returns a slice of `out`.
///
/// BOUNDED TWICE, and both bounds fail SAFE. This used to tokenize everything from "done:" to the end of
/// the reply and mark DONE any token that parsed as an in-range integer — so a model that answered the
/// question and then explained itself ("done: 1, 2\nSubtask 3 is still in progress", "done: 2 (took 3
/// tries)") silently marked work complete that was not. The old comment said "'none' and stray prose just
/// skip", which is true of non-numeric tokens and exactly wrong about a numeral INSIDE prose — the case
/// that occurs.
///
/// So: stop at the end of the ANSWER LINE, and stop at the first token that is not a number. Where the
/// two failures are not symmetric, bound toward the recoverable one — a subtask left PENDING is
/// re-examined by the next reconcile pass and the work continues, while one wrongly marked DONE is never
/// revisited and ships incomplete. (Ledger 0087.)
///
/// That bound was first written to stop at sentence punctuation and at "and" as well, which was not
/// caution but a bug wearing its clothes: "done: 1, 2, 3." and "done: 1, 2 and 3" are how people write
/// lists, and dropping their last item made the engine rerun finished work every round. Neither shape is
/// ambiguous with prose, so skipping them costs the guard above nothing. (Ledger 0099.)
fn parseDoneList(content: []const u8, plan_len: usize, out: []usize) []const usize {
    const at = std.mem.indexOf(u8, content, "done:") orelse return out[0..0];
    var rest = content[at + 5 ..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[0..nl]; // the answer is one line
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, rest, ", \t\r");
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, ".;:()[]");
        if (tok.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(tok, "and") or std.mem.eql(u8, tok, "&")) continue;
        const v = std.fmt.parseInt(usize, tok, 10) catch break; // first non-number ends the list
        if (v == 0 or v > plan_len) continue; // out of range: skip, but keep reading the list
        if (n >= out.len) break;
        out[n] = v;
        n += 1;
    }
    return out[0..n];
}

test "parseDoneList: prose after the answer can no longer mark a subtask complete" {
    var buf: [32]usize = undefined;
    // The shape that motivated this: the model answers, then explains. "3" is a token in that prose.
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, parseDoneList("done: 1, 2\nSubtask 3 is still in progress", 5, &buf));
    // Same failure on one line, via a parenthetical count.
    try std.testing.expectEqualSlices(usize, &.{2}, parseDoneList("done: 2 (took 3 tries)", 5, &buf));
    // The ordinary answers still work.
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, parseDoneList("done: 1, 2, 3", 5, &buf));
    try std.testing.expectEqualSlices(usize, &.{2}, parseDoneList("done:2", 5, &buf));
    // A decline marks nothing, and so does a missing header.
    try std.testing.expectEqual(@as(usize, 0), parseDoneList("done: none", 5, &buf).len);
    try std.testing.expectEqual(@as(usize, 0), parseDoneList("nothing to report", 5, &buf).len);
    // Out of range is skipped without ending the list — a hallucinated index must not eat the real ones.
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, parseDoneList("done: 1, 9, 2", 5, &buf));
    // These four were the cost of that truncation, and it was too high: every one is an ordinary way to
    // answer, and dropping the last item made the engine rerun work it had already finished. The prose
    // guard above is unchanged — "(took" and "Subtask" still end the list, as the cases above assert.
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, parseDoneList("done: 1 and 2", 5, &buf));
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, parseDoneList("done: 1, 2, 3.", 5, &buf));
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, parseDoneList("done: 1, 2 and 3", 5, &buf));
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, parseDoneList("done: (1), (2)", 5, &buf));
}

test "planReconcile actually CALLS parseDoneList — the extraction must not become the hiding place" {
    // 0086's lesson, applied the same session it was learned: a unit test proves the parser is right and
    // says nothing about whether the reconciler uses it. Without this, reverting the call site to the old
    // unbounded tokenizer leaves the suite green.
    const SRC = @embedFile("engine.zig");
    const at = std.mem.indexOf(u8, SRC, "fn planReconcile") orelse return error.PlanReconcileMissing;
    const body = SRC[at..@min(at + 4000, SRC.len)];
    if (std.mem.indexOf(u8, body, "parseDoneList(") == null) {
        std.debug.print("\nplanReconcile no longer calls parseDoneList — prose digits can mark subtasks complete again\n", .{});
        return error.DoneListParserNotWired;
    }
}

test "the tiered pairing actually covers a 12B: compact prompt AND compact belt, together" {
    // The full doctrine teaches recall_hive / open_subchat / cast / get_credential, none of which the
    // compact belt advertises. A live capture showed the FULL prompt beside a 20-tool compact-looking
    // belt (fixed since, in a2f5cc7) -- so pin the pairing at the tier that actually runs locally here,
    // not just the abstract "compact prompt is clean" property the neighbouring test already covers.
    const ids = [_][]const u8{
        "xentriom/gemma-4-12B-agentic-fable5-composer2.5-v2",
        "gemma-4-12b-gary-v1",
        "veil-12b",
    };
    for (ids) |id| {
        const sensed = modelcfg.senseModel(id, true); // local backend
        if (sensed.tier != .small) {
            std.debug.print("\n{s} senses as {s}: it would get the FULL doctrine. Its belt must then " ++
                "advertise every verb that doctrine teaches.\n", .{ id, @tagName(sensed.tier) });
            return error.TierWouldTeachUnadvertisedVerbs;
        }
    }
}

test "the working budget tightens for a small window and leaves a roomy one alone" {
    const t = std.testing;
    // ROOMY: a large-window model must behave byte-identically to before this existed. Only a window too
    // small for the stock constants is allowed to change anything.
    try t.expectEqual(cctx.WORKING_COMPACT_BYTES, workingBudgetBytes("https://api.example.com", "deepseek-v4-pro", 8 * 1024));

    // TIGHT: the built-in 12B serves 8192 tokens. Its fixed prefix in a real turn (conv c6a6e014f) was
    // ~19 KB -- ~6 KB of system blocks plus a 13 KB 20-tool schema array -- which together with the answer
    // reserve already exceeds the window. The budget must collapse to the floor instead of sitting at 24 KB,
    // which is what let the span grow past the window before compaction could ever trigger.
    const tight = workingBudgetBytes("http://127.0.0.1:11434", "the-veil-12b", 19 * 1024);
    try t.expect(tight < cctx.WORKING_COMPACT_BYTES);
    try t.expectEqual(WORKING_MIN_BUDGET_BYTES, tight);
    // Never zero however hostile the input -- a zero budget folds every round and the model spends the turn
    // re-reading what the previous fold deleted.
    try t.expect(workingBudgetBytes("http://127.0.0.1:11434", "the-veil-12b", 10 * 1024 * 1024) > 0);
    // A fold on a tightened budget must actually SHRINK the span: the kept tail has to be under the trigger.
    // At the stock 24 KB trigger / 32 KB tail it is not, which is affordable only when the window dwarfs both.
    try t.expect(@max(2 * 1024, tight / 2) < tight);
}

test "the loop hard stop is reachable before MAX_ITERS, or it is dead code" {
    // The echo guard refuses ONE signature after ECHO_LIMIT identical results; the hard stop ends the
    // turn after LOOP_STOP_REFUSALS consecutive refusal-bearing inferences. The two only work as a pair,
    // and the pair only works if the stop can actually be reached inside a turn's round budget. A live
    // loop (conv c6a6df468) cycled edit_file -> run_python -> run_tests -> read_file and ran to
    // MAX_ITERS because nothing counted refusals ACROSS signatures; the per-call forgiveness reset that
    // followed re-opened it from the other side (any executing call zeroed the strikes, so a ledger-
    // refused search spiral — never echo_blocked, since a dedupable call executes exactly once — or one
    // nondeterministic member in the cycle kept the stop disarmed to MAX_ITERS). Strikes are per
    // ITERATION now, cleared only by a refusal-free pass that executed; if someone later raises either
    // constant past the round cap, the stop silently stops firing and that hang comes back with no test
    // failing.
    //
    // Worst case for one signature: ECHO_LIMIT arming passes (one identical call each), then
    // LOOP_STOP_REFUSALS refused passes before the pre-inference check fires.
    const worst_case_rounds: usize = @as(usize, ECHO_LIMIT) + @as(usize, LOOP_STOP_REFUSALS);
    if (worst_case_rounds >= MAX_ITERS) {
        std.debug.print("\nloop hard stop needs up to {d} rounds but MAX_ITERS is {d}: the turn hits the " ++
            "round cap first and the hard stop never fires.\n", .{ worst_case_rounds, MAX_ITERS });
        return error.LoopStopUnreachable;
    }
    // And it must not be so eager that a model taking one extra look trips it: a single refused signature
    // is a nudge, never a turn-ender.
    const t = std.testing;
    try t.expect(LOOP_STOP_REFUSALS > 1);
    try t.expect(ECHO_LIMIT > 1);
}
