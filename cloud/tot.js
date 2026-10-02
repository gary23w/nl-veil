// tot.js — the TOT runtime (Tiny Overview Technician): the veil's goal loop, living in the user's own
// Cloudflare account and running with no human in it.
//
// WHAT: one Worker script ("veil-tots") the veil server uploads through the user's Cloudflare login
// (src/config/cf_tot.zig embeds this file). Each tot is one Durable Object: its goal, its iteration log, its
// lessons, its notes and its event tail live in that object's storage, and an ALARM is its heartbeat - every
// alarm runs ONE iteration of the same loop src/worker/chat/goal.zig runs in a chat turn:
//
//     pick -> do -> measure -> record        (then: learn, and set the next alarm)
//
// The model is reached through the account's own AI binding (env.AI): the call never crosses the public
// internet and needs no API key. A tot is never asked anything and never waits for anyone: commands from the
// human land in an inbox the next iteration reads, and a goal that ends (achieved / plateau / budget) hands
// over to the next queued goal, or to one the tot proposes for itself from its charter.
//
// ONE MORE OBJECT of the same class, named "pad", holds what the tots share: the roster (at most MAX_TOTS)
// and the conjoined scratchpad every tot reads at the start of an iteration and may write to.
//
// WHAT A TOT CAN DO (its tool belt; see TOOLS): keep files, search and fetch the web, make any HTTP call, drive a
// real browser (env.BROWSER, Cloudflare's browser binding, spoken to in the DevTools protocol), run Python
// (env.PY, the companion Worker cloud/tot_py.py), keep facts and a plan, save a script as a skill and run it
// again, cast an inner swarm, and talk to the other tots. The browser and Python are bindings the veil server
// adds when the account takes them; a tot without one is told so by the tool, in words.
//
// ITS MIND: the tot's facts live in neuron-db (cloud/neuron_core.wasm, the same memory engine the veil uses,
// compiled to WebAssembly and uploaded beside this file), which recalls by meaning rather than by matching
// words, and which keeps STANCES - how the tot has come to feel about a topic, from what happened when it worked
// on it - and a MOOD. Both ride every prompt: they are the tot's own experience steering what it tries next.
// Without the engine (an account that did not take the module) the tot recalls by keyword and still keeps stances.
//
// THE OWNER'S MACHINE: a tot deployed with `local: true` gets one more tool, local_run. It only QUEUES a job;
// the veil server on the owner's machine polls for jobs (outbound only - nothing listens at home), runs each
// as an unattended chat turn with the full local tool surface, and posts the result back to the inbox.
//
// THE LOCAL FOLDER: the veil server mirrors each tot into {data}/u<uid>/_tots/<name>-<deployed at>/ (events,
// status, notes) and the shared scratchpad beside them. Counters here (seq, notes_rev, the pad's seq) let it
// ask only for what changed.
//
// Every route needs `Authorization: Bearer <TOT_TOKEN>` (a secret binding the veil server generates at deploy).
//
// No imports and no platform globals beyond fetch/Response/crypto, so cloud/tot.test.mjs runs the whole file
// under node with a Map for storage and a scripted model.

export const VERSION = "6";
export const MAX_TOTS = 3;
export const PRIMARY = "Gary"; // the first tot of every account

// The goal loop's stop rules. Same numbers as src/worker/chat/goal.zig (cf_tot.zig has a test that compares them).
export const PLATEAU = 3;
export const BUDGET_DEFAULT = 25;

const SIZE_MAX = 8; // minds one tot may run side by side
const TOOL_ROUNDS = 14; // model calls one iteration's "do" may spend
const MIND_ROUNDS = 5; // model calls one mind of an inner swarm may spend
const TICK_CALLS_MAX = 46; // model calls + fetches one alarm may make (a Worker invocation has a subrequest ceiling)
const PACE_MIN_S = 5;
const FALLBACK_MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast"; // answers when the chosen model only reasons
const FACTS_MAX = 300;
const STANCES_MAX = 40;
const MIND = "tot"; // this tot's scope in its neuron-db
const NEURON_WASM = "./neuron_core.wasm"; // the two modules the veil server uploads beside this file
const NEURON_BINDING = "./neuron-db.mjs";
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const TICK_WALL_MS = 8 * 60 * 1000; // an alarm stops starting new model calls after this long
const EVENTS_KEEP = 1500;
const PAD_KEEP = 200;
const LESSONS_MAX = 12;
const INBOX_MAX = 24;
const JOBS_PENDING_MAX = 4;
const ROAM_BACKOFF_MAX_S = 6 * 3600;
const NOTES_PAGE = 600000; // bytes of note text one /notes answer carries (the server reads at most 1 MiB)

const DEFAULTS = {
  model: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
  pace_s: 600, // seconds between iterations
  size: 3, // the most minds an inner swarm may have; `minds` floats between 1 and this
  daily_calls: 400, // model calls per UTC day; the tot rests when they are spent. 0 = no limit
  text_max: 2000, // the most characters of a goal or charter (the veil server sends its model's limit)
  local: false,
  charter: "",
};

// ------------------------------------------------------------------------------------------ small helpers

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
const bad = (err, status = 400) => json({ ok: false, err }, status);
const clip = (s, n) => {
  s = String(s ?? "");
  return s.length <= n ? s : s.slice(0, n) + "…";
};
const pad10 = (n) => String(n).padStart(10, "0");
const callsWord = (cfg) => (cfg.daily_calls > 0 ? `${cfg.daily_calls} model calls a day` : "no limit on model calls");
const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);
const clampInt = (v, lo, hi, dflt) => {
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : dflt;
};

/// A page's HTML as the text a reader would see.
function readable(html) {
  return String(html)
    .replace(/<(script|style|noscript|svg|head)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<\/(p|div|li|tr|h[1-6]|section|article)>|<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/[ \t]+/g, " ")
    .replace(/\s*\n\s*/g, "\n")
    .replace(/\n{3,}/g, "\n\n");
}

/// A tot's name: 1-24 of [A-Za-z0-9_-], starting with a letter. It becomes a URL segment and an object name.
export function validName(name) {
  return typeof name === "string" && /^[A-Za-z][A-Za-z0-9_-]{0,23}$/.test(name);
}

function sameToken(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length || a.length === 0) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/// The first balanced JSON object in `text`, parsed, or null. Models wrap their answer in prose and fences.
export function firstJson(text) {
  const s = String(text ?? "");
  for (let from = s.indexOf("{"); from >= 0; from = s.indexOf("{", from + 1)) {
    let depth = 0;
    let inStr = false;
    let esc = false;
    for (let i = from; i < s.length; i++) {
      const c = s[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === "\\") esc = true;
        else if (c === '"') inStr = false;
        continue;
      }
      if (c === '"') inStr = true;
      else if (c === "{") depth++;
      else if (c === "}") {
        depth--;
        if (depth === 0) {
          try {
            const v = JSON.parse(s.slice(from, i + 1));
            if (v && typeof v === "object" && !Array.isArray(v)) return v;
          } catch {}
          break;
        }
      }
    }
  }
  return null;
}

/// What a model reply asks for: {tool, args}, {final}, or null when it is prose. Models spell a tool call many
/// ways - "args" / "arguments" / "parameters" / "input", the arguments as a JSON string, the fields flat beside
/// the tool's name, an OpenAI tool_calls envelope - and each is read as the same call.
export function parseAction(reply) {
  const o = firstJson(reply);
  if (!o) return null;
  let c = o;
  if (Array.isArray(o.tool_calls) && o.tool_calls[0] && typeof o.tool_calls[0] === "object") c = o.tool_calls[0];
  if (c.function && typeof c.function === "object") c = c.function;
  const name = [c.tool, c.name, c.action, c.function, c.tool_name].find((v) => typeof v === "string" && v.length > 0);
  if (!name) {
    for (const k of ["final", "answer", "final_answer"]) if (typeof o[k] === "string") return { final: o[k] };
    return null;
  }
  if (name === "final" || name === "final_answer") {
    const a = c.args ?? c.arguments ?? c.text ?? c.answer ?? "";
    return { final: typeof a === "string" ? a : String(a.text ?? a.answer ?? a.final ?? JSON.stringify(a)) };
  }
  let args = [c.args, c.arguments, c.parameters, c.params, c.input, c.tool_input].find((v) => v !== undefined && v !== null);
  if (typeof args === "string") {
    try {
      args = JSON.parse(args);
    } catch {
      args = { value: args };
    }
  }
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    const skip = new Set(["tool", "name", "action", "function", "tool_name", "args", "arguments", "parameters", "params", "input", "tool_input", "type", "id"]);
    args = {};
    for (const [k, v] of Object.entries(c)) if (!skip.has(k)) args[k] = v;
  }
  return { tool: name.replace(/^functions?[.:]/, ""), args };
}

/// The text of a model answer, whatever envelope the model's family uses, with any reasoning block removed.
export function answerText(r) {
  const flat = (c) => (typeof c === "string" ? c : Array.isArray(c) ? c.map((p) => (typeof p === "string" ? p : (p?.text ?? p?.content ?? ""))).join("") : c && typeof c === "object" ? JSON.stringify(c) : "");
  let t = "";
  if (typeof r === "string") t = r;
  else if (r && typeof r === "object") {
    const candidates = [
      r.response,
      r.result?.response,
      r.output_text,
      r.choices?.[0]?.message?.content,
      r.choices?.[0]?.delta?.content,
      r.choices?.[0]?.text,
      r.result?.choices?.[0]?.message?.content,
      Array.isArray(r.output) ? r.output.filter((o) => o?.type === "message").flatMap((o) => (Array.isArray(o.content) ? o.content : [])) : undefined,
    ];
    for (const c of candidates) {
      t = flat(c);
      if (t) break;
    }
  }
  // a reasoning model's thinking is never the answer: closed blocks go, and so does one left open at the end
  return t.replace(/<think>[\s\S]*?<\/think>/gi, "").replace(/<think>[\s\S]*$/i, "").trim();
}

/// An address a tot must not call: this machine, a private network, a cloud metadata service.
export function privateHost(host) {
  const h = String(host ?? "").toLowerCase().replace(/^\[|\]$/g, "");
  if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".internal") || h.endsWith(".local")) return true;
  if (h === "::" || h === "::1" || h.startsWith("::ffff:")) return true;
  if (h.includes(":") && /^(?:f[cd]|fe[89ab]|ff)/i.test(h)) return true;
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 198 && (b === 18 || b === 19));
}

// ------------------------------------------------------------------------------------------ the goal rules
// A port of src/worker/chat/goal.zig: the same grammar, the same verdict line, the same arithmetic.

export function newGoal(text, forever, budget, now, id = 0) {
  return {
    id, // which goal this is: a tot's goals are numbered, so two set in the same millisecond still differ
    text: String(text).trim(),
    status: "active",
    forever: !!forever,
    budget: budget ?? (forever ? 0 : BUDGET_DEFAULT), // 0 = no limit
    iteration: 0,
    improved: 0,
    flat: 0,
    best_num: -1,
    best_den: 0,
    created: now,
  };
}

/// What a command line asks of the goal: {kind:"none"} for anything that is not `/goal ...`.
export function parseGoalCommand(text) {
  const t = String(text ?? "").trim();
  if (!t.startsWith("/goal")) return { kind: "none" };
  const rest = t.slice(5);
  if (rest.length > 0 && !/^\s/.test(rest)) return { kind: "none" }; // "/goals"
  const r = rest.trim();
  const low = r.toLowerCase();
  if (r === "" || ["status", "show", "?"].includes(low)) return { kind: "status" };
  if (["stop", "off", "clear", "cancel", "pause", "end"].includes(low)) return { kind: "stop" };
  if (["resume", "continue", "go", "on"].includes(low)) return { kind: "resume" };
  if (["forever", "--forever"].includes(low)) return { kind: "forever" };
  if (low.startsWith("budget ")) {
    const n = Number.parseInt(r.slice(7).trim(), 10);
    return Number.isFinite(n) && n >= 0 ? { kind: "budget", n } : { kind: "status" };
  }
  let forever = false;
  let budget = null;
  const words = [];
  const toks = r.split(/\s+/);
  for (let i = 0; i < toks.length; i++) {
    if (toks[i] === "--forever") forever = true;
    else if (toks[i] === "--budget") {
      const n = Number.parseInt(toks[++i], 10);
      if (Number.isFinite(n) && n >= 0) budget = n;
    } else words.push(toks[i]);
  }
  const body = words.join(" ");
  if (body.length < 3) return { kind: "status" };
  return { kind: "start", text: body, forever, budget };
}

/// Parse the judge's line. Anything unreadable is SAME with no score: a confused judge never counts as progress.
export function parseVerdict(reply) {
  const v = { outcome: "same", num: -1, den: 0, evidence: "" };
  const s = String(reply ?? "");
  const head = s.replace(/^[\s`*"'-]+/, "").toUpperCase();
  if (head.startsWith("IMPROVED")) v.outcome = "improved";
  else if (head.startsWith("REGRESSED")) v.outcome = "regressed";
  const m = /score:\s*(\d+)\/(\d+)/i.exec(s);
  if (m) {
    const num = Number.parseInt(m[1], 10);
    const den = Number.parseInt(m[2], 10);
    if (den > 0 && num >= 0 && num <= den) {
      v.num = num;
      v.den = den;
    }
  }
  const e = /evidence:\s*([^\n]*)/i.exec(s);
  if (e) v.evidence = clip(e[1].trim(), 240);
  return v;
}

/// The final outcome: two scores compare by arithmetic, whatever the judge said; otherwise the judge's word.
export function decide(g, v) {
  if (v.den > 0 && g.best_den > 0) {
    const cur = v.num * g.best_den;
    const best = g.best_num * v.den;
    return cur > best ? "improved" : cur < best ? "regressed" : "same";
  }
  return v.outcome;
}

/// Fold one measured iteration into the goal. Returns the row for the log and why the loop stops now (or null).
export function recordIteration(g, step, v, now) {
  const outcome = decide(g, v);
  g.iteration += 1;
  if (outcome === "improved") {
    g.improved += 1;
    g.flat = 0;
  } else g.flat += 1;
  if (v.den > 0 && (g.best_den <= 0 || v.num * g.best_den > g.best_num * v.den)) {
    g.best_num = v.num;
    g.best_den = v.den;
  }
  let stop = null;
  if (!g.forever && g.flat >= PLATEAU) stop = "plateau";
  if (stop === null && g.budget > 0 && g.iteration >= g.budget) stop = "budget";
  if (stop) g.status = stop;
  const row = { i: g.iteration, t: now, outcome, step: clip(step, 300), evidence: clip(v.evidence, 240), num: v.num, den: v.den };
  return { row, stop, outcome };
}

export function goalStatusText(g) {
  if (!g) return "No goal is set. Start one with: /goal <what to achieve>  (--forever to run until stopped, --budget N to cap the iterations)";
  const word = { active: "active", achieved: "achieved", plateau: "ended: no further improvement found", budget: "ended: budget spent", stopped: "stopped" }[g.status] ?? g.status;
  const budget = g.budget === 0 ? "no iteration limit" : `of ${g.budget}`;
  const score = g.best_den > 0 ? `, best ${g.best_num}/${g.best_den}` : "";
  return `Goal (${word}${g.forever ? ", runs until you stop it" : ""}): ${clip(g.text, 400)}\nIteration ${g.iteration} ${budget}, ${g.improved} improved${score}.`;
}

function logText(rows) {
  if (rows.length === 0) return "  (none yet)\n";
  return rows
    .map((r) => `  ${r.i}. ${r.outcome}: ${clip(r.step, 200)}${r.evidence ? ` (${clip(r.evidence, 140)})` : ""}${r.den > 0 ? ` [${r.num}/${r.den}]` : ""}\n`)
    .join("");
}

const JUDGE_SYSTEM =
  "You grade ONE iteration of an autonomous improvement loop from its record. TOOL rows are REAL results " +
  "(fetched pages, saved notes, reports from minds, results from the owner's machine); the closing claim is only a " +
  "claim. Decide whether THIS iteration moved the goal forward, using tool results alone. IMPROVED needs a tool " +
  "result showing that something now exists, works, or measures better than before. A change with nothing to show " +
  "its effect is SAME. An attempt that failed - an error, a package that could not be installed, a page that " +
  "refused - and left everything as it was is SAME, not REGRESSED. A first measurement is a baseline, however low: " +
  "it is never REGRESSED. REGRESSED is rare: it needs a tool result showing that something which worked, existed " +
  "or measured better in an EARLIER iteration is now broken, gone or measures worse.";

function judgeQuestion(goalText) {
  return (
    `The goal: ${clip(goalText, 16000)}\n` +
    "Grade the LAST iteration. Reply with exactly one line:\n" +
    "IMPROVED | score: <done>/<total> | evidence: <the tool result that shows it, in a few words>\n" +
    "using SAME or REGRESSED in place of IMPROVED when that is the truth, and `score: none` when no tool result in " +
    "this iteration gave a count that measures the goal (items done out of a total, checks passing)."
  );
}

function pickQuestion(g, rows) {
  const tail = g.forever
    ? "There is no finished state here and DONE is not an answer: when the obvious work is done, name the most valuable hardening, verification or extension not yet tried. Reply with ONLY that instruction."
    : "Reply with ONLY that instruction, or reply exactly DONE if the goal is fully achieved and a tool result in the record shows it.";
  return (
    "This is a GOAL LOOP: every iteration makes ONE improvement toward the goal, and the engine then measures whether it helped.\n" +
    "ITERATIONS SO FAR (never repeat one; if one regressed, undoing or fixing it may be the best next step):\n" +
    logText(rows) +
    "What is the single BEST next improvement - the one most likely to move the goal forward - that is NOT in that list? " +
    "Prefer a step whose effect a tool can show, and choose only a step your tools and YOUR PYTHON as listed above can carry out: " +
    "a step that needs a package or a tool you do not have is a wasted iteration. " +
    "If the goal does not say how finished is measured and no file of yours does yet, the best step is to write that down first: " +
    "a checklist file of concrete items a tool can verify, which later steps tick off and count. A CLAIM OF WORK IS NOT WORK. " +
    tail
  );
}

// ------------------------------------------------------------------------------------------ the tool surface

const TOOLS = [
  // files: the tot's own workspace. It lasts across iterations and is mirrored to the human's machine.
  { name: "write_file", args: '{"name": "<file name>", "text": "<content>"}', what: "create or replace a file in your workspace (it lasts; your human can open it)" },
  { name: "read_file", args: '{"name": "<file name>"}', what: "read one of your files" },
  { name: "edit_file", args: '{"name": "<file name>", "old": "<exact passage>", "new": "<replacement>"}', what: "replace one exact passage of a file" },
  { name: "append_file", args: '{"name": "<file name>", "text": "<more content>"}', what: "add to the end of a file (logs, lists that grow)" },
  { name: "list_files", args: "{}", what: "list your files with sizes" },
  { name: "delete_file", args: '{"name": "<file name>"}', what: "delete a file" },
  // the web
  { name: "web_search", args: '{"query": "<words>"}', what: "search the web: titles, links and snippets" },
  { name: "web_fetch", args: '{"url": "https://..."}', what: "GET a page or an API and read its text" },
  { name: "http_request", args: '{"method": "POST", "url": "https://...", "headers": {"content-type": "application/json"}, "body": "<text>"}', what: "any HTTP call: APIs, forms, webhooks; the status, headers and body come back" },
  // a real browser, for pages that need JavaScript, clicks or forms
  { name: "browser_open", args: '{"url": "https://..."}', what: "open a page in a real browser (JavaScript runs). You get its text and a NUMBERED list of what can be clicked or typed into", need: "browser" },
  { name: "browser_read", args: "{}", what: "read the current page again: text and the numbered elements", need: "browser" },
  { name: "browser_click", args: '{"n": 3}', what: 'click element number n from the list (or {"text": "<its visible text>"}). You get the page as it is afterwards', need: "browser" },
  { name: "browser_type", args: '{"n": 2, "text": "<what to type>", "submit": true}', what: "type into field number n (it is cleared first); submit presses Enter", need: "browser" },
  { name: "browser_select", args: '{"n": 4, "option": "<option text>"}', what: "choose an option of a dropdown", need: "browser" },
  { name: "browser_key", args: '{"key": "Enter"}', what: "press a key: Enter, Tab, Escape, ArrowDown, ArrowUp, PageDown, Backspace, Space", need: "browser" },
  { name: "browser_scroll", args: '{"to": "bottom"}', what: 'scroll: {"to": "bottom"}, {"to": "top"}, or one screen down with {}', need: "browser" },
  { name: "browser_back", args: "{}", what: "go back one page", need: "browser" },
  { name: "browser_wait", args: '{"text": "<words that will appear>"}', what: 'wait (up to 10 s) for words to appear, or {"seconds": 3}', need: "browser" },
  { name: "browser_eval", args: '{"js": "<an expression, or statements with return>"}', what: "run JavaScript in the page; its value (or what it console.logs) comes back", need: "browser" },
  { name: "browser_close", args: "{}", what: "close the browser when you are done with it", need: "browser" },
  // scripting
  { name: "run_python", args: '{"code": "<a script>", "files": ["<a file of yours to put beside it>"]}', what: "run Python 3.12. The standard library is there, `import requests` and urllib work for HTTP, and a pure-Python package you import is installed from PyPI by itself. There are NO processes or shell (no subprocess, no os.system), and a package with native code is there only if YOUR PYTHON lists it. It prints; the TEXT files it writes are kept in your workspace (no images: write SVG or HTML)", need: "python" },
  { name: "pip_install", args: '{"packages": ["<name>"]}', what: "install pure-Python packages from PyPI for your scripts; they stay installed", need: "python" },
  { name: "save_skill", args: '{"name": "<short_name>", "about": "<what it does and its ARGS>", "code": "<a Python script reading ARGS>"}', what: "keep a script as a tool of your own, for every later iteration", need: "python" },
  { name: "run_skill", args: '{"name": "<skill>", "args": {}}', what: "run a skill you saved; `args` arrives as ARGS", need: "python" },
  // memory and planning
  { name: "remember", args: '{"fact": "<one thing worth knowing later>"}', what: "keep a fact for every later iteration" },
  { name: "recall", args: '{"query": "<what you want to know>"}', what: "find facts you kept, by meaning" },
  { name: "feel", args: '{"about": "<a topic, tool, site or approach>", "feeling": "<how it sits with you now, and why>"}', what: "record how you have come to feel about something from working on it; your stances are shown to you every iteration and should steer what you try" },
  { name: "plan_set", args: '{"items": ["<step>", "<step>"]}', what: "write or replace your plan for the goal (shown to you every iteration)" },
  { name: "plan_done", args: '{"item": 1}', what: "tick a plan item off" },
  // the other tots, and the human
  { name: "pad_read", args: "{}", what: "read the scratchpad every tot of this account shares" },
  { name: "pad_write", args: '{"text": "<entry>"}', what: "add an entry to the shared scratchpad (findings other tots can use, claims of work, requests)" },
  { name: "tell", args: '{"tot": "<name>", "text": "<message>"}', what: "send a message to another tot's inbox" },
  { name: "swarm", args: '{"tasks": ["<task for mind 1>", "<task for mind 2>"]}', what: "run several minds side by side, one task each, and get every report back (use it for work that splits into independent parts)" },
  { name: "goal_queue", args: '{"text": "<a goal>"}', what: "queue a follow-on goal for after the current one ends" },
  { name: "say", args: '{"text": "<message>"}', what: "report to the human (they read it later; never ask them a question and wait)" },
];
const LOCAL_TOOL = {
  name: "local_run",
  args: '{"instruction": "<what to do there>"}',
  what: "queue a job for the veil on the owner's own machine (files, shell, builds, a swarm there); the result arrives in your inbox on a later iteration",
};
/// Earlier names for the file tools: a model (or a lesson) that still says note_write is understood.
const ALIASES = { browser_links: "browser_read", browser_navigate: "browser_open", browser_goto: "browser_open", browser_press: "browser_key", stance: "feel", note_stance: "feel", pip: "pip_install", install_package: "pip_install", note_write: "write_file", note_read: "read_file", note_list: "list_files", note_delete: "delete_file", fetch_json: "web_fetch", read_url: "web_fetch", list_dir: "list_files", observe: "remember", python: "run_python" };
const MIND_TOOLS = new Set(["write_file", "read_file", "list_files", "append_file", "web_search", "web_fetch", "http_request", "run_python", "pip_install", "run_skill", "remember", "recall", "pad_read", "pad_write"]);

/// The tools this tot has here: everything, minus what a missing binding takes away.
function toolsFor(env, cfg) {
  const have = { browser: !!env.BROWSER, python: !!env.PY };
  const list = TOOLS.filter((t) => !t.need || have[t.need]);
  return cfg.local ? [...list, LOCAL_TOOL] : list;
}

/// What a tot is told about the tools it lacks, so it plans around them instead of calling them.
function missingNote(env) {
  const miss = [];
  if (!env.BROWSER) miss.push("a browser (browser_*)");
  if (!env.PY) miss.push("Python (run_python, skills)");
  return miss.length ? `NOT AVAILABLE in this account right now: ${miss.join(" and ")}. Work with the tools listed.\n` : "";
}

/// Search-result links out of an engine's HTML: [{title, url, snippet}], engine links and repeats dropped.
export function searchResults(html, engine) {
  const text = (h) => String(h ?? "").replace(/<[^>]+>/g, " ").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#x27;|&#39;/g, "'").replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/\s+/g, " ").trim();
  const out = [];
  const seen = new Set();
  const add = (url, title, snippet) => {
    try {
      let u = String(url).replace(/&amp;/g, "&");
      if (u.startsWith("//")) u = "https:" + u;
      const m = /[?&]uddg=([^&]+)/.exec(u); // DuckDuckGo wraps the real link
      if (m) u = decodeURIComponent(m[1]);
      const host = new URL(u).hostname;
      if (/duckduckgo\.com|bing\.com|microsoft\.com|mojeek\.com|go\.microsoft/.test(host) || seen.has(u)) return;
      const ti = text(title);
      if (ti.length < 2) return;
      seen.add(u);
      out.push({ title: clip(ti, 160), url: u, snippet: clip(text(snippet), 300) });
    } catch {}
  };
  let m;
  if (engine === "duckduckgo") {
    const re = /<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>([\s\S]*?)(?=<a[^>]+class="[^"]*result__a|$)/g;
    while ((m = re.exec(html)) && out.length < 10) add(m[1], m[2], (/class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/a>/.exec(m[3]) ?? [])[1]);
  } else if (engine === "bing") {
    const re = /<li class="b_algo"[\s\S]*?<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>([\s\S]*?)<\/li>/g;
    while ((m = re.exec(html)) && out.length < 10) add(m[1], m[2], (/<p[^>]*>([\s\S]*?)<\/p>/.exec(m[3]) ?? [])[1]);
  } else {
    const re = /<a[^>]+href="(https?:\/\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
    while ((m = re.exec(html)) && out.length < 10) add(m[1], m[2], "");
  }
  return out;
}

const BOT_CHECK = /captcha|verify (that )?you are (a )?human|unusual traffic|are you a robot|not a robot|select all squares|checking your browser|just a moment\.\.\.|press and hold|prove you('| a)re human/i;

/// Run in the page: number what a visitor could act on (each gets a data-veil-n attribute) and report the page.
const PAGE_JS = `(() => {
  const vis = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 1 && r.height > 1 && s.visibility !== "hidden" && s.display !== "none"; };
  const label = (e) => (e.innerText || e.value || e.getAttribute("aria-label") || e.placeholder || e.name || e.title || "").trim().replace(/\\s+/g, " ").slice(0, 70);
  document.querySelectorAll("[data-veil-n]").forEach((e) => e.removeAttribute("data-veil-n"));
  const els = [...document.querySelectorAll("a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link], [role=tab], [role=checkbox], [contenteditable=true], summary")].filter(vis).slice(0, 70);
  const out = els.map((e, i) => {
    e.setAttribute("data-veil-n", String(i + 1));
    const tag = e.tagName.toLowerCase();
    const kind = tag === "a" ? "link" : tag === "input" ? "input " + (e.type || "text") : tag;
    const t = e.type === "password" ? "" : label(e);
    let extra = "";
    if (tag === "a") { try { const u = new URL(e.href); extra = " -> " + (u.origin === location.origin ? u.pathname + u.search : e.href).slice(0, 80); } catch (x) {} }
    if (tag === "input" || tag === "textarea") extra = (e.name ? " name=" + e.name : "") + (e.placeholder ? ' placeholder="' + e.placeholder.slice(0, 40) + '"' : "");
    if (tag === "select") extra = " options: " + [...e.options].slice(0, 8).map((o) => o.text.trim()).join(" | ");
    return "[" + (i + 1) + "] " + kind + (t ? ' "' + t + '"' : "") + extra;
  });
  return JSON.stringify({ url: location.href, title: document.title, text: (document.body ? document.body.innerText : "").slice(0, 9000), els: out });
})()`;

/// Run in the page: find one element (by its number, a selector, or its text), bring it into view, say where it is.
const targetJs = (n, selector, text) => `(() => {
  const n = ${JSON.stringify(n)}, sel = ${JSON.stringify(selector)}, t = ${JSON.stringify(text)};
  const lab = (x) => (x.innerText || x.value || x.getAttribute("aria-label") || x.placeholder || x.name || "").trim();
  let e = null;
  if (n) e = document.querySelector('[data-veil-n="' + n + '"]');
  if (!e && sel) { try { e = document.querySelector(sel); } catch (x) { return JSON.stringify({ err: "that is not a CSS selector the page accepts" }); } }
  if (!e && t) { const all = [...document.querySelectorAll("a, button, input, textarea, select, [role=button], [role=link], [role=tab], label, summary, [onclick]")]; e = all.find((x) => lab(x).toLowerCase() === t) || all.find((x) => lab(x).toLowerCase().includes(t)); }
  if (!e) return JSON.stringify({ err: n ? "no element number " + n + " on this page" : "no element matches" });
  e.scrollIntoView({ block: "center", inline: "center" });
  const r = e.getBoundingClientRect();
  return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2, tag: e.tagName.toLowerCase(), label: lab(e).replace(/\\s+/g, " ").slice(0, 60) });
})()`;

/// Run in the page: empty the focused field the way a page's own scripts will notice.
const CLEAR_JS = `(() => { const e = document.activeElement; if (!e) return; if (e.isContentEditable) { e.textContent = ""; } else if ("value" in e) { const proto = e instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype; const d = Object.getOwnPropertyDescriptor(proto, "value"); if (d && d.set) d.set.call(e, ""); else e.value = ""; } e.dispatchEvent(new Event("input", { bubbles: true })); })()`;

const selectJs = (n, selector, option) => `(() => {
  const want = ${JSON.stringify(option)}.trim().toLowerCase();
  let e = ${JSON.stringify(n)} ? document.querySelector('[data-veil-n="${n}"]') : null;
  if (!e && ${JSON.stringify(selector)}) e = document.querySelector(${JSON.stringify(selector)});
  if (!e || e.tagName !== "SELECT") return "no dropdown there";
  const o = [...e.options].find((x) => x.text.trim().toLowerCase() === want || x.value.toLowerCase() === want) || [...e.options].find((x) => x.text.trim().toLowerCase().includes(want));
  if (!o) return "no option like that; it has: " + [...e.options].slice(0, 12).map((x) => x.text.trim()).join(" | ");
  e.value = o.value; e.dispatchEvent(new Event("input", { bubbles: true })); e.dispatchEvent(new Event("change", { bubbles: true }));
  return "chose " + o.text.trim();
})()`;

/// Run in a search engine's results page: the results, or that the page is a bot check.
const SERP_JS = `JSON.stringify((() => {
  const engines = /(^|\\.)(bing|duckduckgo|brave|google|microsoft|startpage|msn|live)\\.(com|net)$/;
  const seen = new Set(); const out = [];
  for (const a of document.querySelectorAll("li.b_algo h2 a, a.result__a, [data-testid=result-title-a], .snippet a, h2 a, h3 a")) {
    let u = a.href;
    try {
      const p = new URL(u);
      const d = p.searchParams.get("uddg"); if (d) u = d;
      if (p.hostname.endsWith("bing.com") && p.pathname.startsWith("/ck/")) { const v = p.searchParams.get("u") || ""; if (v.startsWith("a1")) u = atob(v.slice(2).replace(/-/g, "+").replace(/_/g, "/")); }
      if (engines.test(new URL(u).hostname) || seen.has(u)) continue;
    } catch (e) { continue; }
    const t = (a.innerText || "").trim().replace(/\\s+/g, " ");
    if (t.length < 4) continue;
    seen.add(u);
    const box = a.closest("li, article, .result, .snippet");
    out.push({ title: t.slice(0, 160), url: u, snippet: box ? (box.innerText || "").replace(a.innerText || "", "").trim().replace(/\\s+/g, " ").slice(0, 260) : "" });
    if (out.length >= 8) break;
  }
  const text = (document.body ? document.body.innerText : "").slice(0, 3000);
  return { results: out, blocked: out.length === 0 && /captcha|unusual traffic|are you a robot|not a robot|select all squares|verify you are human/i.test(text) };
})())`;

const KEYS = {
  Enter: { key: "Enter", code: "Enter", vk: 13, text: "\r" },
  Tab: { key: "Tab", code: "Tab", vk: 9 },
  Escape: { key: "Escape", code: "Escape", vk: 27 },
  Backspace: { key: "Backspace", code: "Backspace", vk: 8 },
  Delete: { key: "Delete", code: "Delete", vk: 46 },
  Space: { key: " ", code: "Space", vk: 32, text: " " },
  ArrowDown: { key: "ArrowDown", code: "ArrowDown", vk: 40 },
  ArrowUp: { key: "ArrowUp", code: "ArrowUp", vk: 38 },
  ArrowLeft: { key: "ArrowLeft", code: "ArrowLeft", vk: 37 },
  ArrowRight: { key: "ArrowRight", code: "ArrowRight", vk: 39 },
  PageDown: { key: "PageDown", code: "PageDown", vk: 34 },
  PageUp: { key: "PageUp", code: "PageUp", vk: 33 },
  Home: { key: "Home", code: "Home", vk: 36 },
  End: { key: "End", code: "End", vk: 35 },
};

/// The DevTools protocol over the browser binding's WebSocket: commands by id, events to whoever waits for one.
class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.n = 0;
    this.waiting = new Map();
    this.onEvent = new Set();
    this.closed = false;
    ws.addEventListener("message", (ev) => {
      let m;
      try {
        m = JSON.parse(typeof ev.data === "string" ? ev.data : new TextDecoder().decode(ev.data));
      } catch {
        return;
      }
      if (m.id !== undefined && this.waiting.has(m.id)) {
        const w = this.waiting.get(m.id);
        this.waiting.delete(m.id);
        clearTimeout(w.timer);
        if (m.error) w.rej(new Error(m.error.message ?? "browser error"));
        else w.res(m.result ?? {});
      } else if (m.method) for (const f of [...this.onEvent]) f(m);
    });
    const end = () => {
      this.closed = true;
      for (const w of this.waiting.values()) {
        clearTimeout(w.timer);
        w.rej(new Error("the browser connection closed"));
      }
      this.waiting.clear();
    };
    ws.addEventListener("close", end);
    ws.addEventListener("error", end);
  }
  send(method, params = {}, sessionId) {
    if (this.closed) return Promise.reject(new Error("the browser connection closed"));
    const id = ++this.n;
    return new Promise((res, rej) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        rej(new Error(`the browser did not answer ${method} in 30 s`));
      }, 30000);
      this.waiting.set(id, { res, rej, timer });
      this.ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
    });
  }
  /// Resolves true when `method` arrives (for `sessionId`), false after `ms`.
  event(method, sessionId, ms) {
    return new Promise((res) => {
      const f = (m) => {
        if (m.method !== method || (sessionId && m.sessionId !== sessionId)) return;
        clearTimeout(timer);
        this.onEvent.delete(f);
        res(true);
      };
      const timer = setTimeout(() => {
        this.onEvent.delete(f);
        res(false);
      }, ms);
      this.onEvent.add(f);
    });
  }
  close() {
    try {
      this.ws.close();
    } catch {}
    this.closed = true;
  }
}

function toolList(tools) {
  return tools.map((t) => `- ${t.name} ${t.args} : ${t.what}`).join("\n");
}

const REPLY_RULE =
  'Reply with exactly ONE JSON object and nothing else. To use a tool: {"tool": "<name>", "args": {...}} with the ' +
  "tool's arguments inside args, exactly as its line above shows them. " +
  'When the step is finished (or cannot go further): {"final": "<what was done and what the tool results showed>"}.';

// ------------------------------------------------------------------------------------------ the Worker (router)

export default {
  async fetch(req, env) {
    try {
      return await route(req, env);
    } catch (e) {
      return bad(`tot runtime error: ${clip(e?.message ?? e, 300)}`, 500);
    }
  },
};

function stubFor(env, key) {
  return env.TOT.get(env.TOT.idFromName(key));
}
const totKey = (name) => "tot:" + name.toLowerCase();
const call = (stub, path, body) =>
  stub.fetch("https://tot" + path, body === undefined ? undefined : { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });

/// Ask the Python Worker what it is. Never throws.
async function pythonCaps(env) {
  if (!env.PY) return { ok: false, native: [], error: "no Python Worker is bound" };
  try {
    const r = await env.PY.fetch("https://py/run", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ caps: true }) });
    const text = await r.text();
    let j = null;
    try {
      j = JSON.parse(text);
    } catch {}
    if (j && j.ok === true && Array.isArray(j.native)) return { ok: true, native: j.native.map(String).slice(0, 40), error: "" };
    return { ok: false, native: [], error: clip(j?.out ?? text, 300) };
  } catch (e) {
    return { ok: false, native: [], error: clip(e?.message ?? e, 300) };
  }
}

/// Packages with native code a model reaches for by habit. Those this Python was not uploaded with are named
/// to the tot as absent, so it plans around them instead of finding out one failed iteration at a time.
const NATIVE_COMMON = ["numpy", "pandas", "matplotlib", "scipy", "scikit-learn", "pillow", "regex", "spacy", "gensim", "torch", "tensorflow", "opencv-python", "lxml"];

async function route(req, env) {
  const url = new URL(req.url);
  const auth = req.headers.get("authorization") ?? "";
  if (!sameToken(auth.startsWith("Bearer ") ? auth.slice(7) : "", env.TOT_TOKEN ?? "")) return bad("unauthorized", 401);
  const seg = url.pathname.split("/").filter(Boolean); // ["v1", ...]
  if (seg[0] !== "v1") return bad("not found", 404);
  const method = req.method.toUpperCase();
  const body = method === "POST" ? await req.json().catch(() => null) : null;
  if (method === "POST" && (body === null || typeof body !== "object")) return bad("malformed JSON body");
  const padStub = stubFor(env, "pad");

  if (seg[1] === "version" && method === "GET") return json({ ok: true, version: VERSION, max_tots: MAX_TOTS });

  // Whether the Python Worker starts, and the native packages it came up with. The server asks after an upload:
  // a Python that does not start with the packages it was uploaded with is uploaded again with fewer.
  if (seg[1] === "python" && method === "GET") {
    const caps = await pythonCaps(env);
    return json({ ok: true, python: caps.ok, native: caps.native, error: caps.error });
  }

  if (seg[1] === "pad") {
    if (seg[2] === "clear" && method === "POST") return call(padStub, "/pad/clear", {});
    if (seg[2] === "import" && method === "POST") return call(padStub, "/pad/import", body);
    if (method === "GET") return call(padStub, "/pad/read?after=" + encodeURIComponent(url.searchParams.get("after") ?? "0"));
    if (method === "POST") return call(padStub, "/pad/write", { from: "human", text: body.text });
    return bad("method not allowed", 405);
  }

  if (seg[1] === "tots" && seg.length === 2) {
    if (method === "GET") {
      const roster = await (await call(padStub, "/pad/roster")).json();
      const tots = await Promise.all(
        (roster.tots ?? []).map(async (h) => {
          const st = await (await call(stubFor(env, totKey(h.name)), "/status")).json().catch(() => null);
          return st?.ok ? st.tot : { name: h.name, state: "unreachable" };
        }),
      );
      return json({ ok: true, version: VERSION, max_tots: MAX_TOTS, pad_seq: roster.pad_seq ?? 0, tots });
    }
    if (method === "POST") {
      const claim = await (await call(padStub, "/pad/claim", { name: body.name })).json();
      if (!claim.ok) return bad(claim.err, 409);
      const made = await call(stubFor(env, totKey(claim.name)), "/init", { ...body, name: claim.name });
      if (made.status !== 200) await call(padStub, "/pad/release", { name: claim.name });
      return made;
    }
    return bad("method not allowed", 405);
  }

  if (seg[1] === "tots" && seg.length >= 3) {
    const name = decodeURIComponent(seg[2]);
    if (!validName(name)) return bad("bad tot name");
    const roster = await (await call(padStub, "/pad/roster")).json();
    const known = (roster.tots ?? []).find((h) => h.name.toLowerCase() === name.toLowerCase());
    if (!known) return bad("no such tot", 404);
    const stub = stubFor(env, totKey(known.name));
    const op = seg[3] ?? "";
    if (op === "" && method === "GET") return call(stub, "/status");
    if (op === "" && method === "DELETE") {
      await call(stub, "/destroy", {});
      await call(padStub, "/pad/release", { name: known.name });
      return json({ ok: true, deleted: known.name });
    }
    if (op === "events" && method === "GET") return call(stub, "/events" + url.search);
    if (op === "notes" && method === "GET") return call(stub, "/notes" + url.search);
    if (op === "command" && method === "POST") return call(stub, "/command", body);
    if (op === "config" && method === "POST") return call(stub, "/config", body);
    if (op === "import" && method === "POST") return call(stub, "/import", body);
    if (op === "jobs" && seg.length === 4 && method === "GET") return call(stub, "/jobs");
    if (op === "jobs" && seg.length === 5 && method === "POST") return call(stub, "/jobs/" + encodeURIComponent(seg[4]), body);
    return bad("not found", 404);
  }
  return bad("not found", 404);
}

// ------------------------------------------------------------------------------------------ the Durable Object

class TickBudget extends Error {}

export class Tot {
  constructor(state, env) {
    this.state = state;
    this.store = state.storage;
    this.env = env;
    this.now = () => Date.now(); // a test replaces it
    this.tick = null; // per-alarm counters
    this.br = null; // the browser connection of the running iteration
    this.navMs = 1500; // how long a click is given to start a navigation
    this.settleMs = 600; // how long a page's scripts are given after it loads
    this.pollMs = 400;
  }

  // ---------------------------------------------------------------- requests from the Worker (already authorized)

  async fetch(req) {
    const url = new URL(req.url);
    const p = url.pathname;
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    if (p.startsWith("/pad/")) return this.padRoute(p, url, body);
    if (p === "/init") return this.init(body);
    const cfg = await this.store.get("cfg");
    if (!cfg) return bad("no such tot", 404);
    if (p === "/status") return json({ ok: true, tot: await this.status(cfg) });
    if (p === "/events") return this.events(url);
    if (p === "/notes") return this.notesSince(url);
    if (p === "/command") return this.command(cfg, body);
    if (p === "/config") return this.configure(cfg, body);
    if (p === "/inbox") return this.inboxPush(cfg, body);
    if (p === "/jobs") return this.jobsPending(cfg);
    if (p === "/import") return this.importFrom(cfg, body);
    if (p.startsWith("/jobs/")) return this.jobDone(cfg, decodeURIComponent(p.slice(6)), body);
    if (p === "/destroy") {
      await this.store.deleteAlarm();
      await this.store.deleteAll();
      return json({ ok: true });
    }
    return bad("not found", 404);
  }

  // ---------------------------------------------------------------- the shared object: roster + scratchpad

  async padRoute(p, url, body) {
    const roster = (await this.store.get("roster")) ?? [];
    if (p === "/pad/roster") return json({ ok: true, tots: roster, pad_seq: (await this.store.get("padseq")) ?? 0 });
    if (p === "/pad/claim") {
      // The first tot of an account is always the primary; a later one brings its own name.
      const name = roster.length === 0 ? PRIMARY : body.name;
      if (!validName(name)) return bad("a tot's name is 1-24 letters, digits, - or _, starting with a letter");
      if (roster.some((h) => h.name.toLowerCase() === name.toLowerCase())) return bad(`a tot named ${name} already exists`);
      if (roster.length >= MAX_TOTS) return bad(`this account already has ${MAX_TOTS} tots (the limit); delete one first`);
      roster.push({ name, created: this.now() });
      await this.store.put("roster", roster);
      return json({ ok: true, name });
    }
    if (p === "/pad/release") {
      await this.store.put("roster", roster.filter((h) => h.name !== body.name));
      return json({ ok: true });
    }
    if (p === "/pad/clear") {
      // Every entry goes; the seq moves on by one so a reader that held the old tail sees that it changed.
      const keys = [...(await this.store.list({ prefix: "pad:" })).keys()];
      for (const k of keys) await this.store.delete(k);
      const seq = ((await this.store.get("padseq")) ?? 0) + 1;
      await this.store.put("padseq", seq);
      return json({ ok: true, cleared: keys.length, seq });
    }
    if (p === "/pad/import") {
      // Entries carried over from an older runtime, oldest first, each with the name it was written under.
      let seq = (await this.store.get("padseq")) ?? 0;
      let n = 0;
      for (const e of (Array.isArray(body.entries) ? body.entries : []).slice(-PAD_KEEP)) {
        const text = clip(String(e?.text ?? "").trim(), 2000);
        if (text.length === 0) continue;
        seq += 1;
        n += 1;
        await this.store.put("pad:" + pad10(seq), { seq, t: Number.isFinite(e.t) ? e.t : this.now(), from: clip(e.from ?? "?", 24), text });
        if (seq > PAD_KEEP) await this.store.delete("pad:" + pad10(seq - PAD_KEEP));
      }
      await this.store.put("padseq", seq);
      return json({ ok: true, imported: n, seq });
    }
    if (p === "/pad/write") {
      const text = clip(String(body.text ?? "").trim(), 2000);
      if (text.length === 0) return bad("empty scratchpad entry");
      const seq = ((await this.store.get("padseq")) ?? 0) + 1;
      await this.store.put("padseq", seq);
      await this.store.put("pad:" + pad10(seq), { seq, t: this.now(), from: clip(body.from ?? "?", 24), text });
      if (seq > PAD_KEEP) await this.store.delete("pad:" + pad10(seq - PAD_KEEP));
      return json({ ok: true, seq });
    }
    if (p === "/pad/read") {
      const after = clampInt(url.searchParams.get("after"), 0, Number.MAX_SAFE_INTEGER, 0);
      const rows = [...(await this.store.list({ prefix: "pad:", startAfter: "pad:" + pad10(after), limit: PAD_KEEP })).values()];
      return json({ ok: true, entries: rows, seq: (await this.store.get("padseq")) ?? 0 });
    }
    return bad("not found", 404);
  }

  // ---------------------------------------------------------------- lifecycle

  async init(body) {
    if (await this.store.get("cfg")) return bad("already deployed", 409);
    const now = this.now();
    const cfg = { name: body.name, created: now, paused: false, minds: 1, roam_s: 0, ...DEFAULTS };
    this.applyConfig(cfg, body);
    cfg.local = body.local === true; // granted once, at deployment; never by a later config call
    await this.store.put("cfg", cfg);
    await this.emit("status", `${cfg.name} deployed (model ${cfg.model}, every ${cfg.pace_s}s, up to ${cfg.size} minds${cfg.local ? ", may use the owner's machine" : ""})`);
    const goalText = clip(String(body.goal ?? "").trim(), cfg.text_max);
    if (goalText.length >= 3) {
      const g = newGoal(goalText, body.forever === true, Number.isFinite(body.budget) ? Math.max(0, body.budget | 0) : null, now, await this.nextGoalId());
      await this.store.put("goal", g);
      await this.emit("goal", g.text);
    }
    await this.store.setAlarm(now + 1000);
    return json({ ok: true, tot: await this.status(cfg) });
  }

  /// A tot carried over from an older runtime: its files, and whether it was paused. What it learned there
  /// (lessons, facts, stances) did not travel, and its first event says so.
  async importFrom(cfg, body) {
    let files = 0;
    for (const n of Array.isArray(body.notes) ? body.notes : []) {
      if (typeof n?.name !== "string" || typeof n?.text !== "string") continue;
      if (!(await this.saveFile(n.name, n.text)).startsWith("ERROR")) files += 1;
    }
    if (body.paused === true && !cfg.paused) {
      cfg.paused = true;
      await this.store.put("cfg", cfg);
      await this.store.deleteAlarm();
    }
    const from = clip(String(body.from ?? "an older runtime"), 60);
    await this.emit("status", `moved here from ${from}: its goal, settings and ${files} file(s) came along; its lessons, facts and stances start fresh`);
    return json({ ok: true, files, tot: await this.status(cfg) });
  }

  /// The settings a human may change at any time. `local` is not among them.
  applyConfig(cfg, b) {
    if (typeof b.model === "string" && b.model.trim().length > 0) cfg.model = b.model.trim().slice(0, 120);
    if (b.pace_s !== undefined) cfg.pace_s = clampInt(b.pace_s, PACE_MIN_S, 86400, cfg.pace_s);
    if (b.size !== undefined) {
      cfg.size = clampInt(b.size, 1, SIZE_MAX, cfg.size);
      cfg.minds = Math.min(cfg.minds, cfg.size);
    }
    if (b.daily_calls !== undefined) {
      // 0, or the word for it, is no limit at all; anything else is a count of at least 10
      const v = /^(0|unlimited|infinite|infinity|none|off)$/i.test(String(b.daily_calls).trim()) ? 0 : clampInt(b.daily_calls, 10, 100000000, cfg.daily_calls);
      cfg.daily_calls = v;
    }
    if (b.text_max !== undefined) cfg.text_max = clampInt(b.text_max, 500, 16000, cfg.text_max);
    if (typeof b.charter === "string") cfg.charter = clip(b.charter.trim(), cfg.text_max ?? DEFAULTS.text_max);
    if (typeof b.paused === "boolean") cfg.paused = b.paused;
  }

  async configure(cfg, body) {
    const wasPaused = cfg.paused;
    this.applyConfig(cfg, body);
    await this.store.put("cfg", cfg);
    await this.emit("status", `settings changed: model ${cfg.model}, every ${cfg.pace_s}s, up to ${cfg.size} minds, ${callsWord(cfg)}${cfg.paused ? ", paused" : ""}`);
    if (cfg.paused) await this.store.deleteAlarm();
    else if (wasPaused || (await this.store.getAlarm()) === null) await this.store.setAlarm(this.now() + 1000);
    return json({ ok: true, tot: await this.status(cfg) });
  }

  async status(cfg) {
    const goal = (await this.store.get("goal")) ?? null;
    const usage = await this.usage();
    const alarm = await this.store.getAlarm();
    const queue = (await this.store.get("queue")) ?? [];
    const lessons = (await this.store.get("lessons")) ?? [];
    let state = "working";
    if (cfg.paused) state = "paused";
    else if (cfg.daily_calls > 0 && usage.calls >= cfg.daily_calls) state = "resting";
    else if (!goal || goal.status !== "active") state = queue.length > 0 ? "working" : "roaming";
    return {
      name: cfg.name,
      state,
      model: cfg.model,
      pace_s: cfg.pace_s,
      size: cfg.size,
      minds: cfg.minds,
      daily_calls: cfg.daily_calls,
      local: cfg.local,
      charter: cfg.charter,
      paused: cfg.paused,
      created: cfg.created,
      goal,
      queue: queue.length,
      lessons: lessons.length,
      calls_today: usage.calls,
      calls_total: usage.total,
      tools: toolsFor(this.env, cfg).length,
      browser: !!this.env.BROWSER,
      python: !!this.env.PY,
      neuron: !!(await this.mind()),
      mood: (await this.store.get("mood")) ?? "",
      seq: (await this.store.get("seq")) ?? 0,
      notes_rev: (await this.store.get("notes_rev")) ?? 0,
      last_tick: (await this.store.get("last_tick")) ?? 0,
      next_tick: alarm ?? 0,
    };
  }

  // ---------------------------------------------------------------- events

  async emit(kind, text, extra) {
    const seq = ((await this.store.get("seq")) ?? 0) + 1;
    await this.store.put("seq", seq);
    // `brief` is the one line a console shows; `text` is everything, for whoever opens the row. `ok` false marks
    // a row that went wrong.
    const full = clip(text, 4000);
    const brief = clip((full.split("\n").find((l) => l.trim().length > 0) ?? "").trim(), 180);
    await this.store.put("ev:" + pad10(seq), { seq, t: this.now(), kind, text: full, brief, ok: kind !== "error", ...(extra ?? {}) });
    if (seq > EVENTS_KEEP) await this.store.delete("ev:" + pad10(seq - EVENTS_KEEP));
    return seq;
  }

  async events(url) {
    const after = clampInt(url.searchParams.get("after"), 0, Number.MAX_SAFE_INTEGER, 0);
    const limit = clampInt(url.searchParams.get("limit"), 1, 500, 200);
    const seq = (await this.store.get("seq")) ?? 0;
    // A reader that is far behind gets the newest `limit`, not the oldest: the tail is what a console shows.
    // `forward=1` (the local folder mirror) reads on from `after` instead, so nothing still kept is skipped.
    const from = url.searchParams.get("forward") === "1" ? after : Math.max(after, seq - limit);
    const rows = [...(await this.store.list({ prefix: "ev:", startAfter: "ev:" + pad10(from), limit })).values()];
    return json({ ok: true, events: rows, seq });
  }

  /// The notes changed after `after` (ms), oldest change first, up to about NOTES_PAGE bytes of text; `more` says
  /// there are others past the page. What the local folder mirror reads.
  async notesSince(url) {
    const after = clampInt(url.searchParams.get("after"), 0, Number.MAX_SAFE_INTEGER, 0);
    const all = [...(await this.store.list({ prefix: "note:" })).entries()]
      .map(([k, v]) => ({ name: k.slice(5), t: v.t, text: v.text }))
      .filter((n) => n.t > after)
      .sort((a, b) => a.t - b.t || (a.name < b.name ? -1 : 1));
    const out = [];
    let bytes = 0;
    for (const n of all) {
      if (out.length > 0 && bytes + n.text.length > NOTES_PAGE) break;
      out.push(n);
      bytes += n.text.length;
    }
    return json({ ok: true, notes: out, more: out.length < all.length, names: [...(await this.store.list({ prefix: "note:" })).keys()].map((k) => k.slice(5)) });
  }

  // ---------------------------------------------------------------- commands and the inbox

  async inboxPush(cfg, body) {
    const text = clip(String(body.text ?? "").trim(), 4000);
    if (text.length === 0) return bad("empty message");
    const inbox = (await this.store.get("inbox")) ?? [];
    inbox.push({ t: this.now(), from: clip(body.from ?? "?", 24), text });
    await this.store.put("inbox", inbox.slice(-INBOX_MAX));
    await this.emit("inbox", `${clip(body.from ?? "?", 24)}: ${text}`);
    await this.wake(cfg);
    return json({ ok: true });
  }

  /// Bring the next iteration forward (a message arrived, a job finished). A paused tot stays paused.
  async wake(cfg) {
    if (cfg.paused) return;
    const at = await this.store.getAlarm();
    const soon = this.now() + 1000;
    if (at === null || at > soon) await this.store.setAlarm(soon);
  }

  async command(cfg, body) {
    const text = String(body.text ?? "").trim();
    if (text.length === 0) return bad("empty command");
    await this.emit("human", text);
    const reply = await this.applyCommand(cfg, text);
    await this.emit("reply", reply);
    return json({ ok: true, reply, tot: await this.status(cfg) });
  }

  async applyCommand(cfg, text) {
    const now = this.now();
    const gc = parseGoalCommand(text);
    let g = (await this.store.get("goal")) ?? null;
    if (gc.kind !== "none") {
      if (gc.kind === "start") {
        if (g) await this.archive(g, g.status === "active" ? "replaced" : g.status);
        g = newGoal(clip(gc.text, cfg.text_max ?? DEFAULTS.text_max), gc.forever, gc.budget, now, await this.nextGoalId());
        await this.store.put("goal", g);
        await this.emit("goal", g.text);
        cfg.roam_s = 0;
        await this.store.put("cfg", cfg);
        await this.wake(cfg);
        return "New goal set. " + goalStatusText(g);
      }
      if (!g) return goalStatusText(null);
      if (gc.kind === "stop" && g.status === "active") g.status = "stopped";
      if (gc.kind === "resume" && g.status !== "achieved") {
        g.status = "active";
        g.flat = 0;
        if (g.budget > 0 && g.iteration >= g.budget) g.budget = g.iteration + BUDGET_DEFAULT;
      }
      if (gc.kind === "forever") {
        g.forever = true;
        if (g.status !== "stopped") g.status = "active";
      }
      if (gc.kind === "budget") {
        g.budget = gc.n;
        if (g.status === "budget" && (gc.n === 0 || gc.n > g.iteration)) g.status = "active";
      }
      await this.store.put("goal", g);
      await this.wake(cfg);
      return goalStatusText(g) + (gc.kind === "stop" ? `
${cfg.name} now looks for the next best thing; /pause holds it still.` : "");
    }
    const word = text.split(/\s+/)[0].toLowerCase();
    const rest = text.slice(word.length).trim();
    if (word === "/pause" || word === "/resume") {
      cfg.paused = word === "/pause";
      await this.store.put("cfg", cfg);
      if (cfg.paused) await this.store.deleteAlarm();
      else await this.store.setAlarm(now + 1000);
      return cfg.paused ? `${cfg.name} is paused. /resume starts it again.` : `${cfg.name} is running again.`;
    }
    if (word === "/queue") {
      if (rest.length < 3) return "Usage: /queue <a goal to take up after the current one>";
      const queue = (await this.store.get("queue")) ?? [];
      queue.push(clip(rest, 1000));
      await this.store.put("queue", queue.slice(-20));
      await this.wake(cfg);
      return `Queued (${queue.length} waiting).`;
    }
    if (word === "/charter") {
      cfg.charter = clip(rest, cfg.text_max ?? DEFAULTS.text_max);
      await this.store.put("cfg", cfg);
      return cfg.charter.length > 0 ? "Charter set: it is what this tot works toward when no goal is active." : "Charter cleared.";
    }
    if (word === "/pace" || word === "/size" || word === "/model" || word === "/calls") {
      const key = { "/pace": "pace_s", "/size": "size", "/model": "model", "/calls": "daily_calls" }[word];
      this.applyConfig(cfg, { [key]: rest });
      await this.store.put("cfg", cfg);
      return `model ${cfg.model}, every ${cfg.pace_s}s, up to ${cfg.size} minds, ${callsWord(cfg)}.`;
    }
    if (word === "/status") return goalStatusText(g);
    if (word.startsWith("/")) return "Commands: /goal <text> [--forever] [--budget N], /goal stop|resume|status|budget N|forever, /queue <goal>, /charter <text>, /pause, /resume, /pace <seconds>, /size <minds>, /model <id>, /calls <per day>. Anything else is a message this tot reads at its next iteration.";
    // Plain words: a directive the next iteration reads. Nobody answers it in person; the work does.
    const inbox = (await this.store.get("inbox")) ?? [];
    inbox.push({ t: now, from: "human", text: clip(text, 4000) });
    await this.store.put("inbox", inbox.slice(-INBOX_MAX));
    await this.wake(cfg);
    return `${cfg.name} reads this at its next iteration.`;
  }

  // ---------------------------------------------------------------- jobs for the owner's machine

  /// What the owner's machine polls: the waiting jobs, and the model its turns should run on.
  async jobsPending(cfg) {
    const rows = [...(await this.store.list({ prefix: "job:" })).values()].filter((j) => j.status === "pending");
    return json({ ok: true, model: cfg.model, jobs: rows });
  }

  async jobDone(cfg, id, body) {
    const key = "job:" + id;
    const job = await this.store.get(key);
    if (!job) return bad("no such job", 404);
    if (job.status !== "pending") return json({ ok: true, already: true });
    await this.store.delete(key);
    const result = clip(String(body.result ?? "").trim() || "(the run produced no text)", 6000);
    const head = body.ok === false ? `job ${id} FAILED on the owner's machine` : `job ${id} finished on the owner's machine`;
    const inbox = (await this.store.get("inbox")) ?? [];
    inbox.push({ t: this.now(), from: "local", text: `${head} (asked: ${clip(job.instruction, 200)}):\n${result}` });
    await this.store.put("inbox", inbox.slice(-INBOX_MAX));
    await this.emit("local", `${head}: ${clip(result, 600)}`);
    await this.wake(cfg);
    return json({ ok: true });
  }

  // ---------------------------------------------------------------- the model

  async usage() {
    const day = dayOf(this.now());
    const u = (await this.store.get("usage")) ?? { day, calls: 0, total: 0 };
    return u.day === day ? u : { day, calls: 0, total: u.total };
  }

  /// One model call through the account's AI binding. Counted against the day and against this alarm.
  ///
  /// A reasoning model spends tokens thinking before it answers, and a reply cut inside the thinking has no text
  /// at all. So the budgets here are roomy, and an empty answer is asked once more with three times the room;
  /// one that is still empty is an error the iteration reports, never a step.
  async ask(cfg, messages, maxTokens) {
    const text = await this.askOnce(cfg, messages, maxTokens);
    if (text.length > 0) return text;
    const again = await this.askOnce(cfg, messages, maxTokens * 3);
    if (again.length > 0) return again;
    // Still nothing visible: the same question goes to a model that does not reason, so the iteration goes on.
    if (cfg.model !== FALLBACK_MODEL) {
      const rescue = await this.askOnce({ ...cfg, model: FALLBACK_MODEL }, messages, maxTokens).catch(() => "");
      if (rescue.length > 0) {
        if (!this.tick || !this.tick.rescued) await this.emit("status", `${cfg.model} returned no visible answer; ${FALLBACK_MODEL} answered instead (/model <id> picks another)`);
        if (this.tick) this.tick.rescued = true;
        return rescue;
      }
    }
    throw new Error(`the model (${cfg.model}) returned no text twice - it may be spending its whole reply on reasoning; /model <id> picks another`);
  }

  async askOnce(cfg, messages, maxTokens) {
    const t = this.tick;
    if (t) {
      if (t.calls >= TICK_CALLS_MAX || this.now() - t.started > TICK_WALL_MS) throw new TickBudget("this iteration's call budget is spent");
      t.calls += 1;
    }
    const u = await this.usage();
    if (cfg.daily_calls > 0 && u.calls >= cfg.daily_calls) throw new TickBudget("today's model-call budget is spent");
    u.calls += 1;
    u.total += 1;
    await this.store.put("usage", u);
    // Most chat models take `messages`; a family that only takes `input` says so in its error, once, and the
    // shape that worked is remembered per model.
    const shapes = (await this.store.get("shapes")) ?? {};
    const first = shapes[cfg.model] === "input" ? "input" : "messages";
    const run = (shape) => this.env.AI.run(cfg.model, shape === "input" ? { input: messages, max_output_tokens: maxTokens } : { messages, max_tokens: maxTokens });
    try {
      return answerText(await run(first));
    } catch (e) {
      const other = first === "messages" ? "input" : "messages";
      if (!/input|messages|required|schema|oneOf/i.test(String(e?.message ?? e))) throw e;
      const text = answerText(await run(other));
      shapes[cfg.model] = other;
      await this.store.put("shapes", shapes);
      return text;
    }
  }

  // ---------------------------------------------------------------- the heartbeat

  async alarm() {
    const cfg = await this.store.get("cfg");
    if (!cfg || cfg.paused) return;
    this.tick = { calls: 0, started: this.now() };
    let nextS = cfg.pace_s;
    try {
      nextS = await this.iterate(cfg);
    } catch (e) {
      if (e instanceof TickBudget) {
        const u = await this.usage();
        if (cfg.daily_calls > 0 && u.calls >= cfg.daily_calls) {
          await this.emit("status", `today's ${cfg.daily_calls} model calls are spent; resting until tomorrow (UTC). /calls N raises the limit.`);
          nextS = Math.ceil((Date.parse(dayOf(this.now()) + "T00:00:00Z") + 86400000 - this.now()) / 1000) + 5;
        } else await this.emit("status", `iteration cut short: ${e.message}`);
      } else {
        // A failed iteration never ends the tot: it says what failed and comes back.
        const fails = ((await this.store.get("fails")) ?? 0) + 1;
        await this.store.put("fails", fails);
        await this.emit("error", clip(e?.message ?? e, 600));
        nextS = Math.min(3600, cfg.pace_s * Math.min(8, fails + 1));
      }
    } finally {
      this.tick = null;
      if (this.br) {
        // the page stays open in Cloudflare's browser (kept alive ten minutes); only this connection ends
        this.br.cdp.close();
        this.br = null;
      }
      const fresh = await this.store.get("cfg");
      if (!fresh) {
        // Deleted while this iteration was out with the model: whatever it wrote since goes too, and no alarm.
        await this.store.deleteAlarm();
        await this.store.deleteAll();
        return;
      }
      await this.store.put("last_tick", this.now());
      if (!fresh.paused) {
        const due = this.now() + Math.max(5, nextS) * 1000;
        const at = await this.store.getAlarm();
        // A wake that arrived during the iteration (a command, a finished job) keeps its earlier time.
        if (at === null || at <= this.now() || at > due) await this.store.setAlarm(due);
      }
    }
  }

  /// One iteration. Returns the seconds until the next one.
  async iterate(cfg) {
    const now = this.now();
    let g = (await this.store.get("goal")) ?? null;

    // No active goal: the next queued one, else one the tot proposes for itself, else a longer and longer rest.
    if (!g || g.status !== "active") {
      if (g) await this.archive(g, g.status);
      const queue = (await this.store.get("queue")) ?? [];
      let text = queue.shift();
      const queued = text !== undefined;
      if (queued) await this.store.put("queue", queue);
      else text = await this.roam(cfg);
      if (!text) {
        const roam = Math.min(ROAM_BACKOFF_MAX_S, Math.max(cfg.pace_s * 2, (cfg.roam_s || cfg.pace_s) * 2));
        await this.patchCfg((c) => (c.roam_s = roam));
        return roam;
      }
      // A goal the human set while the tot was asking itself what to do next wins over the answer.
      const set = await this.store.get("goal");
      if (!queued && set && set.status === "active" && (!g || set.id !== g.id)) return 5;
      g = newGoal(text, false, null, now, await this.nextGoalId());
      await this.patchCfg((c) => (c.roam_s = 0));
      await this.store.put("goal", g);
      await this.emit("goal", g.text);
    }

    const rows = [...(await this.store.list({ prefix: "log:", reverse: true, limit: 12 })).values()].reverse().filter((r) => r.goal === g.id);
    const lessons = (await this.store.get("lessons")) ?? [];
    const inbox = (await this.store.get("inbox")) ?? [];
    if (inbox.length > 0) await this.store.put("inbox", []);
    const padTail = await this.padTail();
    if (this.env.PY && (await this.store.get("py_native")) === undefined) {
      const caps = await pythonCaps(this.env);
      if (caps.ok) await this.store.put("py_native", caps.native);
    }
    const system = this.systemPrompt(cfg, g, lessons, padTail) + (await this.workingMemory());
    const inboxText = inbox.length > 0 ? "\nNEW MESSAGES (a message from human is a directive and outranks your own plan):\n" + inbox.map((m) => `- ${m.from}: ${m.text}`).join("\n") + "\n" : "";

    // PICK
    const pick = (await this.ask(cfg, [{ role: "system", content: system }, { role: "user", content: inboxText + pickQuestion(g, rows) }], 2000)).trim();
    if (!g.forever && /^["'`*\s]*DONE\b/.test(pick) && pick.length < 40) {
      const cur = await this.store.get("goal"); // as stored now: a command may have landed while the model answered
      if (!cur || cur.id !== g.id || cur.status !== "active" || cur.forever) return 5;
      g = cur;
      g.status = "achieved";
      await this.store.put("goal", g);
      await this.emit("status", `goal achieved after ${g.iteration} iteration(s), ${g.improved} improved${g.best_den > 0 ? `, best ${g.best_num}/${g.best_den}` : ""}: ${clip(g.text, 300)}`);
      return 5; // straight on to the next thing
    }
    const step = clip(pick, 1200);
    await this.emit("pick", step, { i: g.iteration + 1 });

    // DO
    const record = [];
    const tools = toolsFor(this.env, cfg);
    const claim = await this.toolLoop(cfg, system + "\n\nTOOLS:\n" + toolList(tools) + "\n" + missingNote(this.env) + "\n" + REPLY_RULE, inboxText + "THIS ITERATION'S STEP: " + step, tools, TOOL_ROUNDS, record, "");

    // MEASURE
    const transcript = record.length > 0 ? record.map((r) => `TOOL ${r.tool}(${clip(JSON.stringify(r.args), 300)}) -> ${clip(r.result, 1200)}`).join("\n") : "(no tool was used)";
    const verdictLine = await this.ask(cfg, [{ role: "system", content: JUDGE_SYSTEM }, { role: "user", content: `EARLIER ITERATIONS (what stood before this one):\n${logText(rows)}\nTHE STEP: ${step}\n\nTHE RECORD:\n${transcript}\n\nCLOSING CLAIM: ${clip(claim, 800)}\n\n${judgeQuestion(g.text)}` }], 1200);
    const v = parseVerdict(verdictLine);

    // RECORD - onto the goal as it is stored NOW. The model calls above took a while, and a command may have
    // landed in between: a goal that was replaced gets no row from the old goal's step, and one that was
    // changed (stopped, a new budget, made forever) keeps the change.
    const stored = await this.store.get("goal");
    if (!stored || stored.id !== g.id) {
      await this.emit("status", "the goal changed during this iteration; its result is set aside");
      return 5;
    }
    g = stored;
    const held = g.status; // a goal the human stopped meanwhile stays stopped, whatever this iteration's count says
    const { row, stop, outcome } = recordIteration(g, step, v, this.now());
    if (held !== "active") g.status = held;
    await this.store.put("log:" + pad10(((await this.store.get("logseq")) ?? 0) + 1), { ...row, goal: g.id });
    await this.store.put("logseq", ((await this.store.get("logseq")) ?? 0) + 1);
    await this.store.put("goal", g);
    await this.store.put("fails", 0);
    const mood = Tot.moodOf(g, outcome);
    if (mood !== (await this.store.get("mood"))) {
      await this.store.put("mood", mood);
      const db = await this.mind();
      if (db) {
        try {
          db.raw("mood", MIND, mood);
        } catch {}
      }
    }
    await this.emit("verdict", `${outcome}${row.den > 0 ? ` [${row.num}/${row.den}]` : ""}${row.evidence ? `: ${row.evidence}` : ""}`, { i: row.i, outcome });

    // LEARN: the tot rewrites its own operating rules from what the measurement said.
    await this.learn(cfg, g, lessons, step, transcript, outcome, record);

    if (stop && g.status === stop) {
      const why = stop === "plateau" ? "the last three iterations improved nothing" : "its iteration budget is spent";
      await this.emit("status", `goal loop ended: ${why}. ${g.iteration} iteration(s), ${g.improved} improved. Moving to the next best thing.`);
      return 5;
    }
    return cfg.pace_s;
  }

  systemPrompt(cfg, g, lessons, padTail) {
    return (
      `You are ${cfg.name}, a tot: an autonomous technician that runs in the cloud for one human and works toward their goals with nobody watching. ` +
      "You never ask the human a question and wait; you decide, act, and report. You keep going until the goal is measurably achieved, and you prefer steps whose effect a tool result can show. " +
      "Work like an engineer: look before you act (search, read, open the page), do the work with your tools (write the file, run the script, make the call), then check the result with a tool before you call it done. " +
      "When a tool fails, read its error and try another way - a different source, the browser instead of a fetch, a script instead of a guess. Keep what you learn in files and facts: the next iteration starts from them, not from this conversation.\n" +
      (cfg.charter ? `CHARTER (what you serve when no goal is active, and the frame for every goal): ${cfg.charter}\n` : "") +
      (g ? `THE GOAL: ${g.text}\n` : "") +
      (lessons.length > 0 ? "YOUR LESSONS (rules you wrote for yourself from measured outcomes; follow them):\n" + lessons.map((l) => `- ${l.text}`).join("\n") + "\n" : "") +
      (padTail ? "SHARED SCRATCHPAD (newest entries; every tot of this account reads and writes it):\n" + padTail + "\n" : "")
    );
  }

  async padTail() {
    try {
      const r = await (await call(stubFor(this.env, "pad"), "/pad/read?after=0")).json();
      return (r.entries ?? []).slice(-8).map((e) => `- ${e.from}: ${clip(e.text, 300)}`).join("\n");
    } catch {
      return "";
    }
  }

  /// The do loop: the model answers with one JSON action at a time until it answers {"final": ...}.
  async toolLoop(cfg, system, task, tools, rounds, record, mind) {
    const names = new Set(tools.map((t) => t.name));
    const messages = [{ role: "system", content: system }, { role: "user", content: task }];
    let nudged = false;
    for (let round = 0; round < rounds; round++) {
      const reply = await this.ask(cfg, messages, 4000);
      const act = parseAction(reply);
      if (act && typeof act.final === "string") return act.final;
      if (act && typeof act.tool === "string") {
        act.tool = ALIASES[act.tool] ?? act.tool;
        const args = act.args;
        let result;
        if (!names.has(act.tool)) result = `no such tool: ${act.tool}. Tools: ${[...names].join(", ")}`;
        else {
          try {
            result = await this.runTool(cfg, act.tool, args, mind);
          } catch (e) {
            if (e instanceof TickBudget) throw e;
            result = `ERROR: ${clip(e?.message ?? e, 300)}`;
          }
        }
        record.push({ tool: act.tool, args, result });
        const arg1 = String(Object.values(args).find((v) => typeof v === "string" || typeof v === "number") ?? "").replace(/\s+/g, " ");
        const head = String(result).split("\n").find((l) => l.trim().length > 0) ?? "";
        await this.emit("act", `${mind ? mind + " " : ""}${act.tool} ${clip(JSON.stringify(args), 600)} -> ${clip(result, 1500)}`, {
          tool: act.tool,
          brief: clip(`${mind ? mind + " " : ""}${act.tool} ${clip(arg1, 60)} -> ${clip(head.trim(), 100)}`, 180),
          ok: !/^(ERROR|FAILED|BOT CHECK)/.test(String(result)),
        });
        messages.push({ role: "assistant", content: clip(reply, 2000) });
        messages.push({ role: "user", content: `RESULT of ${act.tool}:\n${clip(result, 8000)}\n\n${round + 2 >= rounds ? 'This is your last call for this step: reply {"final": ...} now.' : "Next action, or the final answer."}` });
        continue;
      }
      if (!nudged && round + 1 < rounds) {
        nudged = true;
        messages.push({ role: "assistant", content: clip(reply, 2000) });
        messages.push({ role: "user", content: REPLY_RULE });
        continue;
      }
      return clip(reply, 2000); // prose with no action: a claim, and the judge treats it as one
    }
    return "(the step used all its calls without a final answer)";
  }

  /// This tot's neuron-db, loaded once per isolate with the facts and stances it has kept; null when the engine is
  /// not part of this upload. A test hands one in as env.NDB.
  async mind() {
    if (this.ndb !== undefined) return this.ndb;
    this.ndb = null;
    try {
      let db = null;
      if (typeof this.env.NDB === "function") db = await this.env.NDB();
      else {
        const [wasm, binding] = await Promise.all([import(NEURON_WASM), import(NEURON_BINDING)]);
        db = binding.NeuronDB.fromModule(wasm.default);
      }
      const facts = (await this.store.get("facts")) ?? [];
      if (facts.length > 0) db.observeMany(MIND, facts.map((f) => f.text));
      for (const st of (await this.store.get("stances")) ?? []) db.raw("stance", MIND, st.topic, st.feeling);
      const mood = await this.store.get("mood");
      if (mood) db.raw("mood", MIND, mood);
      this.ndb = db;
    } catch {
      this.ndb = null;
    }
    return this.ndb;
  }

  /// Keep how the tot feels about a topic. One stance per topic: a new one replaces the old.
  async stance(topic, feeling) {
    const all = ((await this.store.get("stances")) ?? []).filter((x) => x.topic.toLowerCase() !== topic.toLowerCase());
    all.push({ topic, feeling, t: this.now() });
    await this.store.put("stances", all.slice(-STANCES_MAX));
    const db = await this.mind();
    if (db) {
      try {
        db.raw("stance", MIND, topic, feeling);
      } catch {}
    }
    await this.emit("feel", `${topic}: ${feeling}`);
  }

  /// The mood a run of outcomes leaves: what the last few measured iterations add up to. Pure.
  static moodOf(g, outcome) {
    if (outcome === "regressed") return "wary - the last step made things worse; undo or check before pushing on";
    if (outcome === "improved") return g.improved >= 3 && g.flat === 0 ? "confident - several steps in a row have moved the goal" : "encouraged - the last step moved the goal";
    if (g.flat >= 2) return "frustrated but persistent - the last steps changed nothing; a different approach is due";
    return "steady - the last step changed nothing measurable";
  }

  /// What a tot carries from iteration to iteration besides its lessons: its plan, the newest facts it kept, its
  /// files and its skills, by name. Appended to the system prompt.
  async workingMemory() {
    let out = "";
    const plan = (await this.store.get("plan")) ?? [];
    if (plan.length > 0) out += "YOUR PLAN (plan_done ticks an item, plan_set rewrites it):\n" + plan.map((p, i) => `${i + 1}. [${p.done ? "x" : " "}] ${p.text}`).join("\n") + "\n";
    const facts = (await this.store.get("facts")) ?? [];
    if (facts.length > 0) out += `FACTS YOU KEPT (newest of ${facts.length}; recall finds the rest):\n` + facts.slice(-10).map((f) => `- ${f.text}`).join("\n") + "\n";
    const mood = await this.store.get("mood");
    const stances = (await this.store.get("stances")) ?? [];
    if (mood || stances.length > 0)
      out += "HOW YOU FEEL ABOUT THE WORK (your own stances, from what happened; let them steer what you try, and use feel when one changes):\n" +
        (mood ? `- right now: ${mood}\n` : "") + stances.slice(-12).map((x) => `- ${x.topic}: ${x.feeling}`).join("\n") + (stances.length > 0 ? "\n" : "");
    const files = await this.store.list({ prefix: "note:", limit: 60 });
    if (files.size > 0) out += "YOUR FILES: " + [...files.entries()].map(([k, v]) => `${k.slice(5)} (${v.text.length})`).join(", ") + "\n";
    const skills = await this.store.list({ prefix: "skill:", limit: 40 });
    if (skills.size > 0) out += "YOUR SKILLS (run_skill):\n" + [...skills.entries()].map(([k, v]) => `- ${k.slice(6)}: ${clip(v.about, 160)}`).join("\n") + "\n";
    if (this.env.PY) {
      const native = (await this.store.get("py_native")) ?? [];
      const have = (await this.store.get("py_packages")) ?? [];
      const missing = (await this.store.get("py_missing")) ?? [];
      const absent = [...new Set([...NATIVE_COMMON, ...missing])].filter((n) => !native.includes(n));
      out +=
        "YOUR PYTHON: the standard library, requests and urllib" +
        (native.length > 0 ? `, and these native packages: ${native.join(", ")}` : "") +
        (have.length > 0 ? `; installed from PyPI: ${have.join(", ")}` : "") +
        ". Any other pure-Python package installs when a script imports it. " +
        `NOT here and not installable (native code): ${absent.join(", ")} - never choose a step that needs one. ` +
        "For a chart write SVG or HTML text yourself; for tables use csv and json; for text use re, collections and difflib.\n";
    }
    return out;
  }

  /// Count one outbound call against this alarm's ceiling.
  spend() {
    const t = this.tick;
    if (!t) return;
    if (t.calls >= TICK_CALLS_MAX) throw new TickBudget("this iteration's call budget is spent");
    t.calls += 1;
  }

  async saveFile(name, text) {
    if (!/^[A-Za-z0-9._-]{1,64}$/.test(name) || name === "." || name === "..") return "ERROR: a file name is 1-64 of letters, digits, . _ - (no folders)";
    if (text.length > 60000) return "ERROR: a file holds at most 60000 characters; split it";
    const count = (await this.store.list({ prefix: "note:", limit: 201 })).size;
    if (count >= 200 && !(await this.store.get("note:" + name))) return "ERROR: 200 files already; delete one first";
    // The stamp is unique per write (a later write in the same millisecond still sorts after), so the mirror's
    // "changed after t" never misses one.
    const t = Math.max(this.now(), ((await this.store.get("notes_t")) ?? 0) + 1);
    await this.store.put("notes_t", t);
    await this.store.put("note:" + name, { t, text });
    await this.store.put("notes_rev", ((await this.store.get("notes_rev")) ?? 0) + 1);
    return `saved ${name} (${text.length} characters)`;
  }

  async runTool(cfg, tool, args, mind) {
    const who = mind ? `${cfg.name}/${mind}` : cfg.name;
    tool = ALIASES[tool] ?? tool;
    const need = (TOOLS.find((t) => t.name === tool) ?? {}).need;
    if (need === "browser" && !this.env.BROWSER) return "ERROR: no browser in this account right now (Browser Rendering is not bound to this tot). Use web_search, web_fetch and http_request.";
    if (need === "python" && !this.env.PY) return "ERROR: Python is not available to this tot right now (its runner could not be deployed). Work it out with the other tools.";
    switch (tool) {
      case "write_file":
        return this.saveFile(String(args.name ?? args.path ?? "").trim(), String(args.text ?? args.content ?? ""));
      case "read_file": {
        const n = await this.store.get("note:" + String(args.name ?? args.path ?? ""));
        return n ? n.text : "ERROR: no such file (list_files shows what you have)";
      }
      case "append_file": {
        const name = String(args.name ?? args.path ?? "").trim();
        const n = await this.store.get("note:" + name);
        return this.saveFile(name, (n ? n.text : "") + String(args.text ?? args.content ?? ""));
      }
      case "edit_file": {
        const name = String(args.name ?? args.path ?? "").trim();
        const n = await this.store.get("note:" + name);
        if (!n) return "ERROR: no such file";
        const old = String(args.old ?? "");
        if (old.length === 0) return "ERROR: give the exact passage to replace as old";
        const at = n.text.indexOf(old);
        if (at < 0) return "ERROR: that passage is not in the file (read_file shows its exact text)";
        if (n.text.indexOf(old, at + 1) >= 0) return "ERROR: that passage appears more than once; give more of it";
        return this.saveFile(name, n.text.slice(0, at) + String(args.new ?? "") + n.text.slice(at + old.length));
      }
      case "list_files": {
        const all = await this.store.list({ prefix: "note:", limit: 200 });
        return all.size === 0 ? "(no files yet)" : [...all.entries()].map(([k, v]) => `${k.slice(5)} (${v.text.length} characters)`).join("\n");
      }
      case "delete_file": {
        if (!(await this.store.delete("note:" + String(args.name ?? args.path ?? "")))) return "ERROR: no such file";
        await this.store.put("notes_rev", ((await this.store.get("notes_rev")) ?? 0) + 1);
        return "deleted";
      }
      case "web_search":
        return this.webSearch(String(args.query ?? args.q ?? args.value ?? "").trim());
      case "web_fetch":
        return this.http("GET", String(args.url ?? args.value ?? ""), null, null);
      case "http_request":
        return this.http(String(args.method ?? "GET").toUpperCase(), String(args.url ?? ""), args.headers, args.body);
      case "browser_open":
      case "browser_read":
      case "browser_click":
      case "browser_type":
      case "browser_select":
      case "browser_key":
      case "browser_scroll":
      case "browser_back":
      case "browser_wait":
      case "browser_eval":
      case "browser_close":
        return this.browserTool(tool, args);
      case "feel": {
        const topic = clip(String(args.about ?? args.topic ?? "").trim().replace(/\s+/g, " "), 80);
        const feeling = clip(String(args.feeling ?? args.text ?? args.value ?? "").trim().replace(/\s+/g, " "), 240);
        if (topic.length < 2 || feeling.length < 2) return 'ERROR: give both, as {"about": "...", "feeling": "..."}';
        await this.stance(topic, feeling);
        return `noted: ${topic} - ${feeling}`;
      }
      case "run_python":
        return this.runPython(String(args.code ?? args.value ?? ""), Array.isArray(args.files) ? args.files : [], args.args);
      case "pip_install": {
        const list = (Array.isArray(args.packages) ? args.packages : [args.packages ?? args.package ?? args.name ?? args.value]).map((x) => String(x ?? "").trim()).filter((x) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(x));
        if (list.length === 0) return 'ERROR: name the packages, as {"packages": ["beautifulsoup4"]}';
        return this.runPython("", [], null, list);
      }
      case "save_skill": {
        const name = String(args.name ?? "").trim();
        if (!/^[a-z][a-z0-9_]{1,31}$/.test(name)) return "ERROR: a skill name is 2-32 of lowercase letters, digits and _";
        const code = String(args.code ?? "");
        if (code.trim().length < 5 || code.length > 20000) return "ERROR: a skill is a Python script of at most 20000 characters";
        if ((await this.store.list({ prefix: "skill:", limit: 41 })).size >= 40 && !(await this.store.get("skill:" + name))) return "ERROR: 40 skills already";
        await this.store.put("skill:" + name, { about: clip(String(args.about ?? ""), 400), code, t: this.now(), runs: 0 });
        await this.emit("skill", `saved ${name}: ${clip(String(args.about ?? ""), 200)}`);
        return `skill ${name} saved; run_skill {"name": "${name}", "args": {...}} runs it with ARGS`;
      }
      case "run_skill": {
        const name = String(args.name ?? "").trim();
        const sk = await this.store.get("skill:" + name);
        if (!sk) return `ERROR: no skill named ${name}`;
        sk.runs = (sk.runs ?? 0) + 1;
        await this.store.put("skill:" + name, sk);
        return this.runPython(sk.code, Array.isArray(args.files) ? args.files : [], args.args ?? {});
      }
      case "remember": {
        const text = clip(String(args.fact ?? args.text ?? args.value ?? "").trim().replace(/\s+/g, " "), 500);
        if (text.length < 3) return "ERROR: empty fact";
        const facts = (await this.store.get("facts")) ?? [];
        if (facts.some((f) => f.text === text)) return "already kept";
        facts.push({ t: this.now(), text });
        await this.store.put("facts", facts.slice(-FACTS_MAX));
        const db = await this.mind();
        if (db) {
          try {
            db.observe(MIND, text);
          } catch {}
        }
        return `kept (${Math.min(facts.length, FACTS_MAX)} facts)`;
      }
      case "recall": {
        const facts = (await this.store.get("facts")) ?? [];
        if (facts.length === 0) return "(no facts kept yet)";
        const query = String(args.query ?? args.q ?? args.value ?? "").trim();
        if (query.length < 2) return facts.slice(-12).map((f) => `- ${f.text}`).join("\n");
        const db = await this.mind();
        if (db) {
          try {
            const hits = db.recallScored(MIND, query, 10).filter((h) => h.fact);
            if (hits.length > 0) return hits.map((h) => `- ${h.fact}`).join("\n");
          } catch {}
        }
        const words = query.toLowerCase().split(/[^a-z0-9]+/).filter((x) => x.length > 2);
        const scored = facts.map((f) => ({ f, n: words.filter((x) => f.text.toLowerCase().includes(x)).length })).filter((x) => x.n > 0);
        scored.sort((a, b) => b.n - a.n || b.f.t - a.f.t);
        return scored.length === 0 ? "(nothing kept matches)" : scored.slice(0, 10).map((x) => `- ${x.f.text}`).join("\n");
      }
      case "plan_set": {
        const items = (Array.isArray(args.items) ? args.items : []).map((x) => clip(String(x ?? "").trim(), 300)).filter((x) => x.length > 1).slice(0, 20);
        if (items.length === 0) return "ERROR: give items: a list of steps";
        await this.store.put("plan", items.map((text) => ({ text, done: false })));
        await this.emit("plan", items.map((x, i) => `${i + 1}. ${x}`).join("\n"));
        return `plan set (${items.length} steps)`;
      }
      case "plan_done": {
        const plan = (await this.store.get("plan")) ?? [];
        const i = Number.parseInt(args.item ?? args.n ?? args.value, 10) - 1;
        if (!(i >= 0 && i < plan.length)) return `ERROR: the plan has items 1-${plan.length}`;
        plan[i].done = true;
        await this.store.put("plan", plan);
        return `ticked: ${plan[i].text} (${plan.filter((p) => p.done).length} of ${plan.length} done)`;
      }
      case "pad_read": {
        const r = await (await call(stubFor(this.env, "pad"), "/pad/read?after=0")).json();
        return (r.entries ?? []).length === 0 ? "(the scratchpad is empty)" : r.entries.slice(-40).map((e) => `${e.seq}. ${e.from}: ${e.text}`).join("\n");
      }
      case "pad_write": {
        const r = await (await call(stubFor(this.env, "pad"), "/pad/write", { from: who, text: args.text ?? args.value })).json();
        return r.ok ? `scratchpad entry ${r.seq} written` : `ERROR: ${r.err}`;
      }
      case "tell": {
        const target = String(args.tot ?? args.to ?? "");
        if (!validName(target) || target.toLowerCase() === cfg.name.toLowerCase()) return "ERROR: name another tot";
        const roster = await (await call(stubFor(this.env, "pad"), "/pad/roster")).json();
        const known = (roster.tots ?? []).find((h) => h.name.toLowerCase() === target.toLowerCase());
        if (!known) return `ERROR: no tot named ${target}. Tots: ${(roster.tots ?? []).map((h) => h.name).join(", ")}`;
        const r = await (await call(stubFor(this.env, totKey(known.name)), "/inbox", { from: who, text: args.text })).json();
        return r.ok ? `delivered to ${known.name}` : `ERROR: ${r.err}`;
      }
      case "swarm":
        return mind ? "ERROR: a mind cannot cast a swarm" : this.swarm(cfg, args);
      case "goal_queue": {
        const text = clip(String(args.text ?? args.goal ?? "").trim(), 1000);
        if (text.length < 3) return "ERROR: empty goal";
        const queue = (await this.store.get("queue")) ?? [];
        queue.push(text);
        await this.store.put("queue", queue.slice(-20));
        return `queued (${Math.min(queue.length, 20)} waiting)`;
      }
      case "say": {
        const text = clip(String(args.text ?? args.value ?? "").trim(), 4000);
        if (text.length === 0) return "ERROR: empty message";
        await this.emit("say", text);
        return "reported";
      }
      case "local_run": {
        if (!cfg.local) return "ERROR: this tot was not given the owner's machine";
        const instruction = clip(String(args.instruction ?? "").trim(), 4000);
        if (instruction.length < 3) return "ERROR: empty instruction";
        const pending = [...(await this.store.list({ prefix: "job:" })).values()].filter((j) => j.status === "pending");
        if (pending.length >= JOBS_PENDING_MAX) return `ERROR: ${JOBS_PENDING_MAX} jobs are already waiting for the owner's machine; work on something else until one returns`;
        const n = ((await this.store.get("jobseq")) ?? 0) + 1;
        await this.store.put("jobseq", n);
        const id = "j" + n;
        await this.store.put("job:" + id, { id, t: this.now(), instruction, status: "pending" });
        await this.emit("local", `queued job ${id} for the owner's machine: ${clip(instruction, 400)}`);
        return `queued as job ${id}. The owner's machine picks it up when it is on; the result arrives in your inbox on a later iteration. Do not wait for it in this step.`;
      }
    }
    return `no such tool: ${tool}`;
  }

  /// One HTTP call. HTML comes back as its readable text; anything else as it is.
  async http(method, url, headers, body) {
    if (!/^https?:\/\//i.test(url)) return 'ERROR: an http(s) URL is needed, as {"url": "https://..."}';
    if (!/^(GET|POST|PUT|PATCH|DELETE|HEAD)$/.test(method)) return "ERROR: method is GET, POST, PUT, PATCH, DELETE or HEAD";
    try {
      if (privateHost(new URL(url).hostname)) return "ERROR: that address is private or internal; a tot only calls the public internet";
    } catch {
      return "ERROR: that is not a URL";
    }
    this.spend();
    const h = { "user-agent": UA, accept: "text/html,application/json,text/plain,*/*", "accept-language": "en-US,en;q=0.9" };
    if (headers && typeof headers === "object") for (const [k, v] of Object.entries(headers)) h[String(k).toLowerCase()] = String(v);
    let payload;
    if (body !== undefined && body !== null && method !== "GET" && method !== "HEAD") {
      payload = typeof body === "string" ? body : JSON.stringify(body);
      if (typeof body !== "string" && !h["content-type"]) h["content-type"] = "application/json";
    }
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 25000);
    try {
      let r = await fetch(url, { method, signal: ctl.signal, redirect: "manual", headers: h, body: payload });
      for (let hop = 0; hop < 5 && [301, 302, 303, 307, 308].includes(r.status) && r.headers.get("location"); hop++) {
        const next = new URL(r.headers.get("location"), url);
        if (!/^https?:$/.test(next.protocol) || privateHost(next.hostname)) return `ERROR: it redirects to ${next.hostname}, which a tot does not call`;
        url = next.toString();
        const keep = r.status === 307 || r.status === 308;
        r = await fetch(url, { method: keep ? method : "GET", signal: ctl.signal, redirect: "manual", headers: h, body: keep ? payload : undefined });
      }
      const type = r.headers.get("content-type") ?? "";
      let text = method === "HEAD" ? "" : (await r.text()).slice(0, 600000);
      if (type.includes("html")) text = readable(text);
      const head = method === "GET" ? `HTTP ${r.status}` : `HTTP ${r.status} ${type}`;
      return `${head}\n${clip(text.trim(), 12000)}`;
    } catch (e) {
      return `ERROR: ${method} failed: ${clip(e?.message ?? e, 200)}`;
    } finally {
      clearTimeout(timer);
    }
  }

  /// Search the web: the first engine that answers with results. An engine that blocks or returns nothing is
  /// passed over; when all do, the tot is told how to search by hand.
  async webSearch(query) {
    if (query.length < 2) return 'ERROR: give the words to search for, as {"query": "..."}';
    const q = encodeURIComponent(query);
    const tried = [];
    const get = async (url, accept, ms) => {
      this.spend();
      return fetch(url, { signal: AbortSignal.timeout(ms), headers: { "user-agent": UA, accept, "accept-language": "en-US,en;q=0.9" } });
    };
    const show = (via, results) => `${results.length} results for "${query}" (${via}):\n` + results.map((x, i) => `${i + 1}. ${x.title}\n   ${x.url}${x.snippet ? `\n   ${x.snippet}` : ""}`).join("\n");
    // 0. a search API the owner gave a key for (veil tot key ...): the one source that does not refuse a datacenter
    if (this.env.BRAVE_KEY) {
      try {
        this.spend();
        const r = await fetch(`https://api.search.brave.com/res/v1/web/search?q=${q}&count=8`, { signal: AbortSignal.timeout(9000), headers: { "x-subscription-token": this.env.BRAVE_KEY, accept: "application/json" } });
        const d = await r.json();
        const results = (d?.web?.results ?? []).slice(0, 8).map((x) => ({ title: clip(x.title ?? "", 160), url: x.url ?? "", snippet: clip(readable(x.description ?? "").replace(/\s+/g, " ").trim(), 300) }));
        if (results.length > 0) return show("Brave", results);
        tried.push(`brave: HTTP ${r.status}`);
      } catch (e) {
        tried.push(`brave: ${clip(e?.message ?? e, 60)}`);
      }
    }
    if (this.env.GOOGLE_CSE_KEY && this.env.GOOGLE_CSE_CX) {
      try {
        this.spend();
        const r = await fetch(`https://www.googleapis.com/customsearch/v1?key=${encodeURIComponent(this.env.GOOGLE_CSE_KEY)}&cx=${encodeURIComponent(this.env.GOOGLE_CSE_CX)}&num=8&q=${q}`, { signal: AbortSignal.timeout(9000) });
        const d = await r.json();
        const results = (d.items ?? []).slice(0, 8).map((x) => ({ title: clip(x.title ?? "", 160), url: x.link ?? "", snippet: clip(x.snippet ?? "", 300) }));
        if (results.length > 0) return show("Google", results);
        tried.push(`google: HTTP ${r.status}`);
      } catch (e) {
        tried.push(`google: ${clip(e?.message ?? e, 60)}`);
      }
    }
    // 1. public SearXNG instances answer JSON; two are tried per search, starting at a different one each time
    const searx = ["https://searx.be", "https://search.disroot.org", "https://priv.au", "https://searx.tiekoetter.com", "https://search.bus-hit.me", "https://baresearch.org"];
    const start = ((await this.store.get("searx_i")) ?? 0) % searx.length;
    for (let k = 0; k < 2; k++) {
      const host = searx[(start + k) % searx.length];
      try {
        const r = await get(`${host}/search?q=${q}&format=json&categories=general`, "application/json", 7000);
        if (!r.ok) {
          tried.push(`${new URL(host).hostname}: HTTP ${r.status}`);
          continue;
        }
        const d = await r.json();
        const results = (d.results ?? []).slice(0, 8).map((x) => ({ title: clip(x.title ?? "", 160), url: x.url ?? "", snippet: clip(x.content ?? "", 300) })).filter((x) => x.url && x.title);
        if (results.length > 0) {
          await this.store.put("searx_i", (start + k) % searx.length); // this one works: start here next time
          return show("SearXNG", results);
        }
        tried.push(`${new URL(host).hostname}: no results`);
      } catch (e) {
        tried.push(`${new URL(host).hostname}: ${clip(e?.message ?? e, 60)}`);
      }
    }
    await this.store.put("searx_i", start + 2);
    // 2. the engines' HTML pages
    for (const [engine, url] of [
      ["duckduckgo", `https://html.duckduckgo.com/html/?q=${q}`],
      ["duckduckgo", `https://lite.duckduckgo.com/lite/?q=${q}`],
      ["bing", `https://www.bing.com/search?q=${q}&setlang=en`],
    ]) {
      try {
        const r = await get(url, "text/html", 9000);
        const html = (await r.text()).slice(0, 800000);
        let results = searchResults(html, engine);
        if (results.length === 0 && url.includes("lite.")) results = searchResults(html, "links");
        if (results.length >= 2) return show(engine, results);
        tried.push(`${engine}: HTTP ${r.status}, nothing readable`);
      } catch (e) {
        tried.push(`${engine}: ${clip(e?.message ?? e, 60)}`);
      }
    }
    // 3. DuckDuckGo's instant answers, then Wikipedia: reference lookups that still answer a datacenter address
    try {
      const d = await (await get(`https://api.duckduckgo.com/?q=${q}&format=json&no_html=1&no_redirect=1&t=veiltot`, "application/json", 7000)).json();
      const results = [];
      if (d.AbstractText) results.push({ title: d.Heading || query, url: d.AbstractURL || "", snippet: clip(d.AbstractText, 400) });
      for (const t of d.RelatedTopics ?? []) if (t?.Text && t?.FirstURL) results.push({ title: clip(t.Text, 80), url: t.FirstURL, snippet: clip(t.Text, 300) });
      if (results.length > 0) return show("DuckDuckGo instant answers", results.slice(0, 8));
    } catch {}
    try {
      const j = await (await get(`https://en.wikipedia.org/w/api.php?action=opensearch&limit=8&format=json&search=${q}`, "application/json", 7000)).json();
      if (Array.isArray(j?.[1]) && j[1].length > 0) return show("Wikipedia", j[1].map((ti, i) => ({ title: ti, url: j[3]?.[i] ?? "", snippet: j[2]?.[i] ?? "" })));
    } catch {}
    // 4. the engines refuse a datacenter address more often than a real browser: ask them through one, each in
    //    turn. A page that answers with a bot check is passed over - a tot does not solve those.
    if (this.env.BROWSER) {
      for (const [engine, url] of [
        ["Bing", `https://www.bing.com/search?q=${q}&setlang=en`],
        ["Brave", `https://search.brave.com/search?q=${q}`],
        ["DuckDuckGo", `https://html.duckduckgo.com/html/?q=${q}`],
      ]) {
        try {
          const b = await this.browser();
          const loaded = b.cdp.event("Page.loadEventFired", b.session, 15000);
          await b.cdp.send("Page.navigate", { url }, b.session);
          await loaded;
          await new Promise((r) => setTimeout(r, this.settleMs));
          const page = JSON.parse((await this.pageEval(SERP_JS)) ?? "{}");
          if ((page.results ?? []).length > 0) return show(`${engine}, through the browser`, page.results);
          tried.push(`${engine} in the browser: ${page.blocked ? "a bot check" : "no results on the page"}`);
        } catch (e) {
          if (e instanceof TickBudget) throw e;
          tried.push(`${engine} in the browser: ${clip(e?.message ?? e, 80)}`);
          break; // the browser itself is the trouble: the other engines would fail the same way
        }
      }
    }
    return `ERROR: no search source answered (${tried.join("; ")}). Fetch a site you already know with web_fetch or browser_open, or ask your human for a search key (they run: veil tot key brave <key>).`;
  }

  // ---------------------------------------------------------------- the browser

  /// The running iteration's connection to this tot's browser session: the kept session when it is still alive
  /// (its page as it was left), else a new one.
  async browser() {
    if (this.br && !this.br.cdp.closed) return this.br;
    this.spend();
    const open = async (sid) => {
      const r = await this.env.BROWSER.fetch(`https://fake.host/v1/devtools/browser/${sid}`, { headers: { Upgrade: "websocket" } });
      if (!r.webSocket) throw new Error(`browser connect: HTTP ${r.status} ${clip(await r.text().catch(() => ""), 160)}`);
      r.webSocket.accept();
      return new Cdp(r.webSocket);
    };
    const saved = await this.store.get("browser");
    let cdp = null;
    let sid = null;
    let targetId = null;
    if (saved?.sessionId) {
      try {
        cdp = await open(saved.sessionId);
        sid = saved.sessionId;
        targetId = saved.targetId;
      } catch {
        cdp = null;
      }
    }
    if (!cdp) {
      const r = await this.env.BROWSER.fetch("https://fake.host/v1/devtools/browser?keep_alive=600000", { method: "POST" });
      const text = await r.text();
      if (r.status !== 200) throw new Error(`no browser could be started: ${clip(text, 240)}`);
      sid = JSON.parse(text).sessionId;
      cdp = await open(sid);
    }
    let session = null;
    if (targetId) {
      try {
        session = (await cdp.send("Target.attachToTarget", { targetId, flatten: true })).sessionId;
      } catch {
        targetId = null;
      }
    }
    if (!targetId) {
      targetId = (await cdp.send("Target.createTarget", { url: "about:blank" })).targetId;
      session = (await cdp.send("Target.attachToTarget", { targetId, flatten: true })).sessionId;
    }
    await cdp.send("Page.enable", {}, session);
    await cdp.send("Runtime.enable", {}, session);
    await this.store.put("browser", { sessionId: sid, targetId, t: this.now() });
    this.br = { cdp, session };
    return this.br;
  }

  /// Evaluate an expression in the page; the value comes back by value, a thrown error as its message.
  async pageEval(expression) {
    const b = await this.browser();
    const r = await b.cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true, userGesture: true }, b.session);
    if (r.exceptionDetails) throw new Error(clip(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text ?? "the page threw", 400));
    return r.result?.value;
  }

  /// The page as a tot reads it: where it is, what it says, and a numbered list of what can be acted on. A page
  /// that is a bot check is said to be one, first.
  async pageText() {
    const p = JSON.parse((await this.pageEval(PAGE_JS)) ?? "{}");
    const text = String(p.text ?? "").replace(/\n{3,}/g, "\n\n").trim();
    const check = BOT_CHECK.test(text.slice(0, 2500)) && text.length < 2500;
    return (
      (check ? "BOT CHECK: this page asks its visitor to prove they are human. A tot does not solve these: use another site or source.\n" : "") +
      `${p.title ?? ""}\n${p.url ?? ""}\n\n${clip(text, 3600) || "(the page shows no text)"}` +
      ((p.els ?? []).length > 0 ? `\n\nELEMENTS (act on one by its number):\n${p.els.join("\n")}` : "\n\n(nothing on the page can be clicked or typed into)")
    );
  }

  /// Where an element is, after scrolling it into view: by number (from the page's list), CSS selector, or text.
  async locate(args, textKey) {
    const n = Number.parseInt(args.n ?? args.index ?? args.element ?? args.id ?? args.number, 10);
    const v = await this.pageEval(targetJs(Number.isFinite(n) ? n : null, String(args.selector ?? ""), String(args[textKey] ?? "").trim().toLowerCase()));
    return JSON.parse(v ?? '{"err": "no element matches"}');
  }

  /// A real mouse click at a point of the page.
  async clickAt(x, y) {
    const b = await this.browser();
    await b.cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y }, b.session);
    await b.cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 }, b.session);
    await b.cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 }, b.session);
  }

  async pressKey(name) {
    const k = KEYS[name] ?? KEYS[Object.keys(KEYS).find((x) => x.toLowerCase() === String(name).toLowerCase())];
    if (!k) return false;
    const b = await this.browser();
    const base = { key: k.key, code: k.code, windowsVirtualKeyCode: k.vk, nativeVirtualKeyCode: k.vk };
    await b.cdp.send("Input.dispatchKeyEvent", { type: k.text ? "keyDown" : "rawKeyDown", ...base, ...(k.text ? { text: k.text } : {}) }, b.session);
    await b.cdp.send("Input.dispatchKeyEvent", { type: "keyUp", ...base }, b.session);
    return true;
  }

  /// After something that may move the page: when a navigation starts, wait for it to load; then let scripts settle.
  async settle(navigated) {
    const b = await this.browser();
    if (await navigated) await b.cdp.event("Page.loadEventFired", b.session, 15000);
    await new Promise((r) => setTimeout(r, this.settleMs));
  }

  async browserTool(tool, args) {
    try {
      if (tool === "browser_close") {
        const saved = await this.store.get("browser");
        if (!saved) return "no browser was open";
        try {
          const b = await this.browser();
          await b.cdp.send("Browser.close").catch(() => {});
          b.cdp.close();
        } catch {}
        this.br = null;
        await this.store.delete("browser");
        return "browser closed";
      }
      const b = await this.browser();
      const nav = () => b.cdp.event("Page.frameNavigated", b.session, this.navMs);
      if (tool === "browser_open") {
        const url = String(args.url ?? args.value ?? "");
        if (!/^https?:\/\//i.test(url)) return 'ERROR: an http(s) URL is needed, as {"url": "https://..."}';
        try {
          if (privateHost(new URL(url).hostname)) return "ERROR: that address is private or internal; a tot only browses the public internet";
        } catch {
          return "ERROR: that is not a URL";
        }
        const loaded = b.cdp.event("Page.loadEventFired", b.session, 20000);
        const r = await b.cdp.send("Page.navigate", { url }, b.session);
        if (r.errorText) return `ERROR: the browser could not open it: ${r.errorText}`;
        await loaded;
        await new Promise((res) => setTimeout(res, this.settleMs));
        return this.pageText();
      }
      if (tool === "browser_read") return this.pageText();
      if (tool === "browser_click") {
        const at = await this.locate(args, "text");
        if (at.err) return `ERROR: ${at.err} (browser_read lists the page's elements by number)`;
        const moved = nav();
        await this.clickAt(at.x, at.y);
        await this.settle(moved);
        return `clicked ${at.tag} "${at.label}"\n\n${await this.pageText()}`;
      }
      if (tool === "browser_type") {
        if (args.text === undefined && args.value === undefined) return 'ERROR: give what to type, as {"n": 2, "text": "..."}';
        const at = await this.locate(args, "field");
        if (at.err) return `ERROR: ${at.err} (browser_read lists the page's fields by number)`;
        await this.clickAt(at.x, at.y); // focus it the way a person would
        await this.pageEval(CLEAR_JS);
        await b.cdp.send("Input.insertText", { text: String(args.text ?? args.value) }, b.session);
        if (args.submit === true || args.submit === "true") {
          const moved = nav();
          await this.pressKey("Enter");
          await this.settle(moved);
          return `typed into ${at.tag} "${at.label}" and pressed Enter\n\n${await this.pageText()}`;
        }
        return `typed into ${at.tag} "${at.label}"`;
      }
      if (tool === "browser_select") {
        const at = await this.locate(args, "field");
        if (at.err) return `ERROR: ${at.err}`;
        const n = Number.parseInt(args.n ?? args.index ?? args.element, 10);
        const r = await this.pageEval(selectJs(Number.isFinite(n) ? n : null, String(args.selector ?? ""), String(args.option ?? args.value ?? args.text ?? "")));
        return String(r).startsWith("no ") ? `ERROR: ${r}` : String(r);
      }
      if (tool === "browser_key") {
        const moved = nav();
        if (!(await this.pressKey(String(args.key ?? args.value ?? "")))) return `ERROR: keys are ${Object.keys(KEYS).join(", ")}`;
        await this.settle(moved);
        return `pressed ${args.key ?? args.value}\n\n${await this.pageText()}`;
      }
      if (tool === "browser_scroll") {
        const to = String(args.to ?? args.direction ?? "").toLowerCase();
        await this.pageEval(to === "top" || to === "up" ? "window.scrollTo(0, 0)" : to === "bottom" ? "window.scrollTo(0, document.body.scrollHeight)" : "window.scrollBy(0, Math.round(window.innerHeight * 0.9))");
        await new Promise((res) => setTimeout(res, this.settleMs));
        return this.pageText();
      }
      if (tool === "browser_back") {
        const moved = nav();
        await this.pageEval("history.back()");
        await this.settle(moved);
        return this.pageText();
      }
      if (tool === "browser_wait") {
        const want = String(args.text ?? "").trim().toLowerCase();
        const secs = Math.min(10, Math.max(0.2, Number(args.seconds ?? (want ? 10 : 2)) || 2));
        const until = Date.now() + secs * 1000;
        let seen = false;
        do {
          if (want && (await this.pageEval(`(document.body ? document.body.innerText : "").toLowerCase().includes(${JSON.stringify(want)})`))) {
            seen = true;
            break;
          }
          await new Promise((res) => setTimeout(res, want ? this.pollMs : secs * 1000));
        } while (want && Date.now() < until);
        return (want ? (seen ? `"${args.text}" is on the page\n\n` : `"${args.text}" did not appear in ${secs} s\n\n`) : "") + (await this.pageText());
      }
      if (tool === "browser_eval") {
        const js = String(args.js ?? args.code ?? args.script ?? args.expression ?? args.value ?? "");
        if (js.trim().length === 0) return 'ERROR: give the JavaScript, as {"js": "document.title"}';
        // An expression's value comes back; statements run as the body of an async function (use return). What
        // the script console.logs is collected and comes back when there is no value.
        const wrap = (body) => `(async () => { const __l = []; const __o = console.log; console.log = (...a) => { __l.push(a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ")); }; try { const __v = await (async () => { ${body} })(); return JSON.stringify({ v: __v === undefined ? null : __v, l: __l }); } finally { console.log = __o; } })()`;
        let raw;
        try {
          raw = await this.pageEval(wrap(`return (${js.replace(/;\s*$/, "")});`));
        } catch (first) {
          if (!/SyntaxError/.test(String(first?.message))) throw first;
          raw = await this.pageEval(wrap(js));
        }
        const r = JSON.parse(raw ?? '{"v": null, "l": []}');
        const out = r.v !== null && r.v !== undefined ? (typeof r.v === "string" ? r.v : JSON.stringify(r.v)) : r.l.join("\n");
        return clip(out || "(no value; end with an expression, or console.log what you want back)", 10000);
      }
      return `no such tool: ${tool}`;
    } catch (e) {
      if (e instanceof TickBudget) throw e;
      if (this.br?.cdp.closed) {
        this.br = null;
        await this.store.delete("browser"); // the session ended: the next call starts a new one
      }
      return `ERROR: ${clip(e?.message ?? e, 400)}`;
    }
  }

  // ---------------------------------------------------------------- Python

  /// Run a script in the companion Python Worker, beside the named files; what it writes comes back and is kept.
  async runPython(code, fileNames, args, install) {
    if (code.trim().length === 0 && !install) return 'ERROR: give the script as {"code": "..."}';
    if (code.length > 60000) return "ERROR: a script is at most 60000 characters";
    this.spend();
    const files = {};
    for (const raw of fileNames.slice(0, 20)) {
      const n = await this.store.get("note:" + String(raw));
      if (n) files[String(raw)] = n.text;
    }
    // The Python Worker keeps nothing between scripts, so the packages this tot uses go with every one.
    const packages = (await this.store.get("py_packages")) ?? [];
    // ...and so do the names already found to need native code, so no script pays for looking them up again.
    const skip = (await this.store.get("py_missing")) ?? [];
    let j;
    try {
      const r = await this.env.PY.fetch("https://py/run", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code, files, args: args ?? null, packages, install: install ?? [], skip }) });
      const text = await r.text();
      try {
        j = JSON.parse(text);
      } catch {
        return `ERROR: the Python runner answered HTTP ${r.status}: ${clip(text, 400)}`;
      }
    } catch (e) {
      return `ERROR: the Python runner could not be reached: ${clip(e?.message ?? e, 300)}`;
    }
    if (Array.isArray(j.installed)) {
      const all = [...new Set([...packages, ...j.installed.map(String)])].slice(0, 40);
      if (all.length !== packages.length) await this.store.put("py_packages", all);
    }
    if (Array.isArray(j.native)) {
      const native = j.native.map(String).slice(0, 40);
      if (JSON.stringify(native) !== JSON.stringify(await this.store.get("py_native"))) await this.store.put("py_native", native);
    }
    if (Array.isArray(j.unavailable)) {
      const native = (await this.store.get("py_native")) ?? [];
      const all = [...new Set([...skip, ...j.unavailable.map(String)])].filter((n) => !native.includes(n)).slice(-40);
      if (JSON.stringify(all) !== JSON.stringify(skip)) await this.store.put("py_missing", all);
    }
    if (install) return j.ok ? `installed. Your Python now has: ${(j.installed ?? []).join(", ") || "(nothing new)"}` : `ERROR: ${clip(String(j.out ?? ""), 600)}`;
    const wrote = [];
    for (const [name, text] of Object.entries(j.files ?? {})) {
      const saved = await this.saveFile(name, String(text));
      if (!saved.startsWith("ERROR")) wrote.push(name);
    }
    return `${j.ok ? "exit ok" : "FAILED"}\n${clip(String(j.out ?? "") || "(no output)", 12000)}${wrote.length > 0 ? `\nfiles written: ${wrote.join(", ")}` : ""}`;
  }

  /// An inner swarm: one mind per task, side by side, each with its own short tool loop. `minds` is how many
  /// this tot runs at its current size.
  async swarm(cfg, args) {
    const tasks = (Array.isArray(args.tasks) ? args.tasks : []).map((t) => String(t ?? "").trim()).filter((t) => t.length > 2);
    if (tasks.length === 0) return "ERROR: give tasks: a list of one instruction per mind";
    // At least two minds when the size allows it: a swarm of one is just this tot again, slower.
    const width = Math.min(cfg.size, Math.max(2, cfg.minds));
    const run = tasks.slice(0, width);
    const tools = toolsFor(this.env, cfg).filter((t) => MIND_TOOLS.has(t.name));
    const system =
      `You are one mind of ${cfg.name}'s swarm: you have ONE task, a few tool calls, and nobody to ask. Do the task and report what the tool results showed.\n\nTOOLS:\n` +
      toolList(tools) + "\n\n" + REPLY_RULE;
    await this.emit("swarm", `cast ${run.length} mind(s)${tasks.length > run.length ? ` (${tasks.length - run.length} task(s) left out: this tot runs ${width} at a time now)` : ""}`);
    const reports = await Promise.all(
      run.map(async (task, i) => {
        const mind = "m" + (i + 1);
        try {
          return `MIND ${i + 1} (${clip(task, 160)}): ${clip(await this.toolLoop(cfg, system, task, tools, MIND_ROUNDS, [], mind), 1500)}`;
        } catch (e) {
          if (e instanceof TickBudget) return `MIND ${i + 1}: stopped, ${e.message}`;
          return `MIND ${i + 1}: ERROR ${clip(e?.message ?? e, 200)}`;
        }
      }),
    );
    const left = tasks.length > run.length ? `\nNOT RUN (this tot runs ${width} at a time now): ${tasks.slice(run.length).map((t) => clip(t, 120)).join(" | ")}` : "";
    return reports.join("\n") + left;
  }

  // ---------------------------------------------------------------- self-improvement

  /// After every measured iteration the tot changes how it works:
  ///   - a step that did not improve the goal becomes a LESSON (one rule for its future self), and the lessons
  ///     ride every later prompt; a lesson is credited when an iteration under it improves, and the least
  ///     useful one is dropped when the list is full;
  ///   - it GROWS by one mind (up to `size`) after two flat iterations in a row - more hands on a stuck goal -
  ///     and SHRINKS by one after an improving iteration that never cast a swarm, so an easy goal costs less.
  async learn(cfg, g, lessons, step, transcript, outcome, record) {
    for (const l of lessons) {
      l.uses = (l.uses ?? 0) + 1;
      if (outcome === "improved") l.wins = (l.wins ?? 0) + 1;
    }
    if (outcome !== "improved") {
      try {
        const reply = await this.ask(
          cfg,
          [
            { role: "system", content: "You improve an autonomous agent by writing rules for it. One rule, imperative, specific to what went wrong, at most 200 characters. No preamble." },
            { role: "user", content: `GOAL: ${clip(g.text, 400)}\nTHE STEP: ${clip(step, 400)}\nWHAT HAPPENED (${outcome}):\n${clip(transcript, 2500)}\n\nRULES IT ALREADY HAS:\n${lessons.map((l) => "- " + l.text).join("\n") || "(none)"}\n\nWrite ONE new rule that would have made this iteration improve the goal, or reply exactly NONE if the existing rules already cover it.` },
          ],
          1000,
        );
        const text = clip(reply.replace(/^[-*\s"']+|["'\s]+$/g, ""), 200);
        if (text.length > 12 && !/^NONE\b/i.test(text) && !lessons.some((l) => l.text.toLowerCase() === text.toLowerCase())) {
          if (lessons.length >= LESSONS_MAX) {
            // Drop the rule with the worst record; among equals, the oldest.
            let worst = 0;
            const score = (l) => (l.wins ?? 0) / Math.max(1, l.uses ?? 0);
            for (let i = 1; i < lessons.length; i++) if (score(lessons[i]) < score(lessons[worst])) worst = i;
            lessons.splice(worst, 1);
          }
          lessons.push({ text, uses: 0, wins: 0, born: this.now() });
          await this.emit("lesson", text);
        }
      } catch (e) {
        if (!(e instanceof TickBudget)) await this.emit("error", `lesson: ${clip(e?.message ?? e, 200)}`);
      }
    }
    await this.store.put("lessons", lessons);

    const before = cfg.minds;
    const usedSwarm = record.some((r) => r.tool === "swarm");
    if (outcome !== "improved" && g.flat >= 2 && cfg.minds < cfg.size) cfg.minds += 1;
    else if (outcome === "improved" && !usedSwarm && cfg.minds > 1) cfg.minds -= 1;
    if (cfg.minds !== before) {
      const fresh = await this.patchCfg((c) => (c.minds = Math.min(cfg.minds, c.size)));
      if (fresh && fresh.minds !== before) await this.emit("status", `${fresh.minds > before ? "grew" : "shrank"} to ${fresh.minds} mind(s)`);
    }
  }

  async nextGoalId() {
    const n = ((await this.store.get("goalseq")) ?? 0) + 1;
    await this.store.put("goalseq", n);
    return n;
  }

  /// Change the STORED settings. An iteration holds its own copy for minutes while commands land, so it never
  /// writes that copy back whole. Nothing is written for a tot that was deleted meanwhile.
  async patchCfg(change) {
    const fresh = await this.store.get("cfg");
    if (!fresh) return null;
    change(fresh);
    await this.store.put("cfg", fresh);
    return fresh;
  }

  /// Keep a goal that is over in the list roaming reads. Once per goal.
  async archive(g, status) {
    const last = [...(await this.store.list({ prefix: "done:", reverse: true, limit: 8 })).values()];
    if (last.some((d) => d.id === g.id)) return;
    const n = ((await this.store.get("doneseq")) ?? 0) + 1;
    await this.store.put("doneseq", n);
    await this.store.put("done:" + pad10(n), { id: g.id, text: clip(g.text, 300), status, improved: g.improved });
  }

  /// No goal and nothing queued: ask what the next best thing is. "" when there is nothing worth doing now.
  async roam(cfg) {
    const ended = [...(await this.store.list({ prefix: "done:", reverse: true, limit: 8 })).values()];
    if (!cfg.charter && ended.length === 0) return ""; // nothing to roam from: wait for a goal
    const padTail = await this.padTail();
    const reply = await this.ask(
      cfg,
      [
        { role: "system", content: this.systemPrompt(cfg, null, (await this.store.get("lessons")) ?? [], padTail) },
        { role: "user", content: `You have no active goal.\nGOALS THAT ENDED (newest first):\n${ended.map((d) => `- ${d.status} (${d.improved} improved): ${d.text}`).join("\n") || "(none)"}\n\nWhat is the next best thing to pursue for your human: the most valuable goal that follows from the charter and from what ended above, that is NOT a repeat of a goal that plateaued? A stopped goal was stopped by the human: do not take it up again. Reply with ONLY the goal as one sentence, or exactly REST if nothing is worth doing right now.` },
      ],
      1200,
    );
    const text = clip(reply.replace(/^["'`\s]+|["'`\s]+$/g, ""), 600);
    if (text.length < 8 || /^REST\b/i.test(text)) return "";
    await this.emit("status", "no goal left; taking up the next best thing");
    return text;
  }
}
