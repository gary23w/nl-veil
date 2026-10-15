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
// ONE MORE OBJECT of the same class, named "pad", holds what the tots share: the roster (the account's limit,
// DEFAULT_MAX_TOTS unless the owner set another)
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
// THE DAY-AFTER KIT (docs/docs-src/guide/day-after.md): what a tot does when the model is gone, the lab is quiet
// and attribution is the fight.
//   THE GUARD (/guard, Tot.guard): targets the owner names - a page, with words it must show, a status it must
//   answer, or its content pinned; a DNS name's answers by record type - looked at EVERY heartbeat BEFORE the
//   model is asked and without one, so the watch goes on through a dead, rate-limited or withdrawn model and
//   through a spent daily budget. A change of state is a TRIPWIRE: a chained event, a scratchpad entry every
//   tot reads, a directive in this tot's inbox (its next iteration is brought forward), and - with the ALERT_URL
//   secret - one JSON POST a Discord or Slack webhook renders as it is.
//   THE EVIDENCE CHAIN (emit, chainHash): every event's hash covers the one before it, so the mirrored
//   events.jsonl on the owner's machine is tamper-evident on its own; `veil --tater verify <run>` recomputes it.
//   POSTURE DEFEND (/posture): the runtime is frozen (runtime_edit/deploy refused), a bot check is reported and
//   not worked through, every request names the tot (guardUa) and the prompt holds it to read-only verification.
//   THE LEASH (/leash): no contact from the owner's veil for leash_s holds the goal loop (the guard goes on) until
//   any call from it arrives. A tot never runs on with nobody's veil alive.
//   AGENT GARRETT (garrett, garrett_tools, garrett_launch): github.com/gary23w/garrettstimpson.ca/agent, a Worker
//   of its own the veil server deploys into the account (the desk's Settings button; a tot may ask through the
//   pad's /garrett/* state). A tot deployed or configured with `garrett` (/garrett on|off) reaches it over its
//   stateless MCP endpoint under the GARRETT_MCP_URL / GARRETT_MCP_TOKEN secrets: CVE/KEV/EPSS intel, DNS and
//   certificate transparency, RDAP, email security posture, IOC extraction, evidence manifests, and more. Off
//   for a tot unless asked for: the account's agent is not every tot's business.
//
// THE TOOL MAP (ToolTree, Walk, Learned; a port of src/worker/chat/belt.zig): past MAP_AT tools the belt is no
//   longer a list the model is handed but a tree it walks. The built-in belt stays callable and advertised; what
//   lies beyond it (Agent Garrett's catalogue, 166 tools) is reached through ONE navigation verb, open_tools -
//   families, then groups, each a one-line use case - and a group that opens joins the TOOLS list by name. The
//   engine (this object) holds the whole map, the visited marks and the open set; the model has local vision
//   only. Pre-walk: the step's own words open the best group before the model moves. Auto-open: a tool called
//   by name opens its group and runs. A lost walker is handed `find` unasked. What a step's words led the tot
//   to call is LEARNED (belt_learned), so the pre-walk opens the right group the second time. The open set
//   persists across iterations (belt_open). `/belt map` walks everything but a small core, for a small model.
// GARY'S 4TOPE (loopGraph, unfold; a port of src/worker/chat/net.zig): the do loop's rounds as a dependency
//   graph - a result depends on the step that issued it; a step depends STRONGLY on the earlier result whose
//   distinctive words it reused and weakly on the rest; a later identical call or a later write of the same file
//   SUPERSEDES; a failed call is a DEAD END. The longest path back from the frontier is the CRITICAL CHAIN,
//   whose live results a fold must keep verbatim. When the loop's messages pass LOOP_BYTES they are no longer
//   cut oldest-first: the folded rounds become one NET (the shortest-path tree from the frontier, laid flat
//   under a byte budget: NEXT / ON DISK / RULED OUT / ESTABLISHED, every line verbatim, no model call) and the
//   chain's results stay. The same unfolding is the carry between iterations (last_work.net).
// SELF-HEALING (quirks, runtime revert, the repeated pick): a model's quirks are LEARNED per model and never
//   special-cased by vendor - a model that answers only with three times the room is asked for it first after
//   twice; one that answers nothing three times in a UTC day hands the day to FALLBACK_MODEL and is tried again
//   the next; a context-length error halves the loop's window for that model; a missing model routes to the
//   fallback. The pad keeps the last DEPLOYED runtime source: a revision that fails to deploy reaches the next
//   iteration as a directive, and runtime_revert restores the deployed source as a new revision, so an edit
//   never leaves the tots without a runtime. A pick that repeats the last iteration's step is asked once more
//   for a changed method; a lesson that says the same thing in other words is not kept twice.
//
// Every route needs `Authorization: Bearer <TOT_TOKEN>` (a secret binding the veil server generates at deploy).
//
// No imports and no platform globals beyond fetch/Response/crypto, so cloud/tot.test.mjs runs the whole file
// under node with a Map for storage and a scripted model.

export const VERSION = "11";
// How many tots an account may run: 24 unless the owner sets another, up to MAX_TOTS_CEIL. What an account can
// really carry is its Cloudflare plan's to say: every tot is a Durable Object that wakes every few seconds.
export const DEFAULT_MAX_TOTS = 24;
export const MAX_TOTS_CEIL = 1000;
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
const PY_FILES_BYTES = 1_500_000; // the most of its workspace a script gets beside it when it names no files
const NEURON_WASM = "./neuron_core.wasm"; // the two modules the veil server uploads beside this file
const NEURON_BINDING = "./neuron-db.mjs";
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const TICK_WALL_MS = 8 * 60 * 1000; // an alarm stops starting new model calls after this long
const EVENTS_KEEP = 1500;
const PAD_KEEP = 200;
const LESSONS_MAX = 12;
const ENDED_GOALS_CONTEXT = 64;
const INBOX_MAX = 24;
const JOBS_PENDING_MAX = 4;
const ROAM_BACKOFF_MAX_S = 6 * 3600;
const NOTES_PAGE = 600000; // bytes of note text one /notes answer carries (the server reads at most 1 MiB)
// THE GUARD: targets a tot watches every heartbeat WITHOUT a model (see Tot.guard), so the watch goes on when the
// model is gone. Each target is one fetch per pass inside the alarm's TICK_CALLS_MAX.
const WATCH_MAX = 16;
const WATCH_MIN_S = 30;
const WATCH_BODY_BYTES = 200000;
const DOH = "https://cloudflare-dns.com/dns-query"; // the DNS answers a guarded name gives, from the Worker's edge
// THE LEASH: with leash_s set, no contact from the owner's veil for that long holds the goal loop (the guard goes on).
const LEASH_MIN_S = 60;
const LEASH_MAX_S = 7 * 86400;
const REPO = "https://github.com/gary23w/nl-veil"; // what a tot's own requests point at, so a tot is never anonymous
// THE TOOL MAP (see the header; the numbers are belt.zig's)
const BRANCH_SHOW = 7; // most branches shown at one node: the width a small model picks from reliably
export const OPEN_MAX = 4; // most groups open at once; the least recently USED one closes when a fifth opens
export const NAV_MAX = 4; // navigation rounds in a row before the engine runs `find` for the model
const FIND_TOP = 5;
const PREOPEN_MIN = 5; // a group must answer the step's words at least this well to open unasked
const CUE_MAX = 24;
const LEARNED_MAX = 600; // cue-word -> tool edges a tot keeps (one Durable Object value holds them)
const BONUS_CAP = 3;
export const MAP_AT = 48; // belt size past which "auto" walks what lies beyond the built-in belt
// GARY'S 4TOPE
const LOOP_BYTES = 54000; // the do loop's messages, before the net folds them (halved for a model that said its window is smaller)
const KEEP_ROUNDS = 2; // the newest rounds a fold leaves verbatim
const NET_LOOP_BUDGET = 7000; // characters a fold's net may take
const NET_CARRY_BUDGET = 2400; // ...and the carry into the next iteration
const PROTECT_MAX = 3000; // a chain result kept through a fold is clipped to this (head and tail)
const EXCERPT_MAX = 240;
const NEXT_MAX = 700;
// SELF-HEALING
const EMPTY_LEARN = 2; // empty answers (rescued by 3x the room) before the room is asked for first
const RESCUE_LEARN = 3; // rescues by the fallback model in one UTC day before the day goes to it

const DEFAULTS = {
  model: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
  pace_s: 600, // seconds between iterations
  size: 3, // the most minds an inner swarm may have; `minds` floats between 1 and this
  daily_calls: 400, // model calls per UTC day; the tot rests when they are spent. 0 = no limit
  text_max: 2000, // the most characters of a goal or charter (the veil server sends its model's limit)
  local: false,
  charter: "",
  posture: "normal", // "defend": the runtime is frozen, bot checks are reported, every request names the tot
  leash_s: 0, // 0 = no leash
  garrett: false, // Agent Garrett's tools on this tot's belt (the account's agent must be deployed for them to answer)
  belt: "auto", // "auto": the map holds what lies beyond the built-in belt; "map": everything but a small core; "flat": a list
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
/// Tool calls a model wrote in its own native markup instead of JSON, e.g.
/// <|tool_call_begin|>functions.read_file:1<|tool_call_argument_begin|>{"path": "x"}<|tool_call_end|>. Pure.
export function nativeCalls(text) {
  const out = [];
  const re = /(?:functions?[.:])?([A-Za-z_][\w-]*)(?::\d+)?\s*<\|tool_call_argument_begin\|>([\s\S]*?)<\|tool_call_end\|>/g;
  let m;
  while ((m = re.exec(String(text ?? ""))) !== null) {
    let args;
    try {
      args = JSON.parse(m[2]);
    } catch {
      args = { value: m[2].trim() };
    }
    out.push({ tool: m[1], args: args && typeof args === "object" && !Array.isArray(args) ? args : { value: args } });
  }
  return out;
}

/// A step the model wrote as native tool-call markup, turned back into one plain instruction: what it said before
/// the markup, then the calls it meant. Any other markup token goes. Pure.
export function pickText(reply) {
  const s = String(reply ?? "");
  if (!s.includes("<|")) return s.trim();
  const calls = nativeCalls(s);
  if (calls.length === 0) return s.replace(/<\|[^|]*\|>/g, " ").replace(/\s+/g, " ").trim();
  const lead = s.split("<|")[0].trim();
  const said = calls.map((c) => `${c.tool} ${JSON.stringify(c.args)}`).join(", then ");
  const text = [lead, said ? `Do this: ${said}.` : ""].filter(Boolean).join(" ");
  return text.replace(/<\|[^|]*\|>/g, " ").replace(/\s+/g, " ").trim();
}

export function parseAction(reply) {
  if (String(reply ?? "").includes("<|tool_call")) {
    const calls = nativeCalls(reply);
    if (calls.length > 0) return { tool: calls[0].tool, args: calls[0].args };
  }
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
  if (e) v.evidence = clip(e[1].split(/\|\s*proof:/i)[0].trim(), 240);
  return v;
}

function resultFailed(result) {
  return /^(?:ERROR\b|FAILED\b|no such tool:|HTTP [45]\d\d\b)/i.test(String(result).trim());
}

// Keep the error or confirmation at the end of a long page, as well as its title and URL.
function resultExcerpt(result, limit = 1800) {
  const text = String(result ?? "");
  if (text.length <= limit) return text;
  const head = Math.floor(limit * 2 / 3);
  return text.slice(0, head) + "\n...(middle omitted)...\n" + text.slice(-(limit - head));
}

function fingerprint(text) {
  let h = 2166136261;
  for (const c of String(text)) h = Math.imul(h ^ c.codePointAt(0), 16777619);
  return (h >>> 0).toString(16);
}

const CLAIM_TOOLS = new Set(["write_file", "append_file", "edit_file", "say", "remember", "recall", "feel", "pad_write", "pad_read", "tell", "plan_set", "plan_done", "list_files", "list_skills", "save_skill", "local_run", "swarm", "open_tools"]);

/// A judge must point at an actual observation. Saving or repeating a claim cannot prove it.
/// Clearing the score on rejected evidence also prevents decide() from overriding SAME with arithmetic.
export function evidenceVerdict(reply, record, known = []) {
  const v = { ...parseVerdict(reply), verified: false, complete: false, proof_key: "" };
  const reject = (why) => ({ ...v, outcome: "same", num: -1, den: 0, evidence: why });
  const at = /\bproof:\s*/i.exec(String(reply));
  const proof = at ? firstJson(String(reply).slice(at.index + at[0].length)) : null;
  if (!proof || !Number.isInteger(proof.tool) || !["observation", "artifact"].includes(proof.kind) || typeof proof.quote !== "string")
    return reject(v.outcome === "same" && v.den <= 0 ? v.evidence : "no cited tool observation supports the verdict");
  const row = record[proof.tool - 1];
  const quote = proof.quote.trim();
  if (!row || quote.length < 4 || !String(row.result).includes(quote)) return reject("the cited quote is absent from that tool result");
  if (CLAIM_TOOLS.has(row.tool) || (row.tool === "read_file") !== (proof.kind === "artifact"))
    return reject("a saved claim or an action acknowledgement does not verify the requested outcome");
  if (v.outcome !== "regressed" && resultFailed(row.result)) return reject("the cited tool failed; no improvement was verified");
  // A failed check may prove a regression, but a contradictory score must never turn it into progress.
  if (resultFailed(row.result)) { v.num = -1; v.den = 0; }
  if (/^(?:saved\b|reported\b|queued\b|typed into\b|clicked\b|exit ok\s*$|\(no output\))/i.test(quote))
    return reject("the quote acknowledges an attempt without showing its outcome");
  // File verification identifies the whole content: quoting a different line of the same file is no new work.
  const subject = row.args?.url ?? row.args?.name ?? row.args?.path ?? row.args?.query ?? String(row.result).match(/^https?:\/\/\S+$/m)?.[0] ?? "";
  const content = proof.kind === "artifact" ? String(row.result) : quote.replace(/\s+/g, " ").toLowerCase();
  v.proof_key = `${proof.kind}:${subject}:${fingerprint(content)}`;
  v.verified = true;
  v.complete = proof.complete === true && v.outcome !== "regressed" && (v.den <= 0 || v.num === v.den);
  if (known.includes(v.proof_key) || (v.outcome === "improved" && v.den > 0 && v.num === 0))
    return { ...v, outcome: "same", num: -1, den: 0, evidence: "unchanged observation: " + v.evidence };
  return v;
}

/// Catch an unchanged goal even when punctuation or a short preamble disguises a repeat.
export function repeatedGoal(text, ended) {
  const words = (s) => new Set(String(s).toLowerCase().match(/[\p{L}\p{N}_]+/gu) ?? []);
  const next = words(text);
  return ended.some((g) => {
    const old = words(g.text);
    if (next.size === 0 || old.size === 0) return false;
    const common = [...next].filter((w) => old.has(w)).length;
    return common / (next.size + old.size - common) >= 0.9;
  });
}

/// What a tot's own requests say they are. The guard's checks always, and a defending tot's every call: a tot
/// is never one of the "hard to attribute" agents.
function guardUa(cfg) {
  return `veil-tot/${VERSION} (${cfg?.name ?? "tot"}; +${REPO})`;
}
const posture = (cfg) => (cfg?.posture === "defend" ? "defend" : "normal");

/// A config an older runtime stored gets this one's fields, in place.
function upgraded(cfg) {
  if (!cfg) return cfg;
  if (!Array.isArray(cfg.watch)) cfg.watch = [];
  if (cfg.posture !== "defend") cfg.posture = "normal";
  if (!Number.isFinite(cfg.leash_s)) cfg.leash_s = 0;
  if (cfg.garrett !== true) cfg.garrett = false;
  if (!["auto", "map", "flat"].includes(cfg.belt)) cfg.belt = "auto";
  return cfg;
}
const beltMode = (cfg) => (["map", "flat"].includes(cfg?.belt) ? cfg.belt : "auto");

/// Two texts that say the same thing in other words: the share of their content words in common (Jaccard over
/// the words of four letters or more, and any number). Pure.
export function similarText(a, b) {
  const words = (s) => new Set((String(s).toLowerCase().match(/[\p{L}\p{N}_]+/gu) ?? []).filter((w) => w.length >= 4 || /\p{N}/u.test(w)));
  const x = words(a);
  const y = words(b);
  if (x.size === 0 || y.size === 0) return 0;
  const common = [...x].filter((w) => y.has(w)).length;
  return common / (x.size + y.size - common);
}

/// A pick that repeats an earlier iteration's step in other words. The rules say never to; a model that does
/// anyway is asked once more. Pure.
export function repeatedStep(step, rows) {
  return rows.some((r) => similarText(step, r.step) >= 0.8);
}

/// What went wrong with a model call, by class, so the remedy can be learned per model and never per vendor:
/// `context` (the window is smaller than the request), `missing` (no such model), `busy` (rate limited), or "".
export function classifyModelError(message) {
  const m = String(message ?? "");
  if (/context (?:window|length)|too (?:long|many tokens)|maximum (?:context|input|number of tokens)|exceeds? (?:its|the) (?:context|limit|maximum)|input is too long|prompt is too long|token limit/i.test(m)) return "context";
  if (/no such model|model not found|does not exist|unknown model|unsupported model|\b404\b/i.test(m)) return "missing";
  if (/\b429\b|rate.?limit|too many requests|capacity|overloaded/i.test(m)) return "busy";
  return "";
}

/// Words and "quoted phrases" of a command line.
function splitArgs(s) {
  const out = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let m;
  while ((m = re.exec(s))) out.push(m[1] ?? m[2] ?? m[3]);
  return out;
}

const DNS_TYPES = new Set(["A", "AAAA", "NS", "MX", "TXT", "CNAME", "CAA", "SOA"]);
const DNS_TYPE_NUM = { A: 1, AAAA: 28, NS: 2, MX: 15, TXT: 16, CNAME: 5, CAA: 257, SOA: 6 };
const GUARD_USAGE = 'Usage: /guard add <https://...> [--text "<words that must be on the page>"] [--status <code>] [--every <seconds>] [--pin]  |  /guard add dns:<name> [--type A|AAAA|NS|MX|TXT|CNAME|CAA|SOA] [--every <seconds>]  |  /guard rm <target or #n>  |  /guard clear  |  /guard';

/// The /guard grammar: what to watch and how. Pure.
export function parseGuardCommand(rest) {
  const words = splitArgs(String(rest ?? "").trim());
  const op = (words[0] ?? "").toLowerCase();
  if (op === "" || op === "list" || op === "ls") return { op: "list" };
  if (op === "clear") return { op: "clear" };
  if (op === "rm" || op === "remove" || op === "del") {
    const what = words[1] ?? "";
    if (!what) return { op: "error", err: GUARD_USAGE };
    const n = /^#?(\d+)$/.exec(what);
    if (n) return { op: "rm", index: Number(n[1]) };
    return { op: "rm", key: what.startsWith("dns:") ? `dns:${what.slice(4).toLowerCase().replace(/\.$/, "")}/${(words[2] ?? "A").toUpperCase()}` : "http:" + what };
  }
  if (op !== "add" && op !== "watch") return { op: "error", err: GUARD_USAGE };
  const what = words[1] ?? "";
  const flags = {};
  for (let i = 2; i < words.length; i++) {
    const w = words[i];
    if (w === "--pin") flags.pin = true;
    else if (/^--(text|status|every|type)$/.test(w) && i + 1 < words.length) flags[w.slice(2)] = words[++i];
    else return { op: "error", err: `unknown option ${clip(w, 40)}. ${GUARD_USAGE}` };
  }
  const every_s = flags.every === undefined ? 0 : clampInt(flags.every, WATCH_MIN_S, 86400, 0);
  if (what.startsWith("dns:")) {
    const name = what.slice(4).toLowerCase().replace(/\.$/, "");
    if (!/^(?=.{1,253}$)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(name)) return { op: "error", err: "dns: needs a host name, like dns:example.com" };
    const type = String(flags.type ?? "A").toUpperCase();
    if (!DNS_TYPES.has(type)) return { op: "error", err: "--type is one of A, AAAA, NS, MX, TXT, CNAME, CAA, SOA" };
    return { op: "add", target: { dns: name, type, every_s } };
  }
  if (!/^https?:\/\//i.test(what) || what.length > 500) return { op: "error", err: "a guarded address starts with https:// (or http://), or is dns:<name>" };
  try {
    if (privateHost(new URL(what).hostname)) return { op: "error", err: "a tot guards the public internet, not a private address" };
  } catch {
    return { op: "error", err: "that is not a URL" };
  }
  const status = flags.status === undefined ? 0 : Number.parseInt(flags.status, 10);
  if (!(status === 0 || (status >= 100 && status <= 599))) return { op: "error", err: "--status is an HTTP status code, 100 to 599" };
  return { op: "add", target: { url: what, text: clip(String(flags.text ?? ""), 200), status, every_s, pin: flags.pin === true } };
}

export function watchKey(t) {
  return t.dns ? `dns:${t.dns}/${t.type}` : `http:${t.url}`;
}
export function watchLabel(t) {
  return t.dns ? `dns ${t.dns} ${t.type}` : t.url;
}

/// What one observation of a guarded target says: `tripped` or `ok`, and why. `change` is a one-time note (a
/// pinned page's content, a DNS answer) that does not trip the target: the new value becomes the baseline. Pure.
export function judgeTarget(t, obs, last) {
  if (obs.error) return { state: "tripped", why: `unreachable: ${obs.error}`, change: "" };
  if (t.dns) {
    if (obs.status !== 0) return { state: "tripped", why: `DNS status ${obs.status}${obs.status === 3 ? " (NXDOMAIN)" : obs.status === 2 ? " (SERVFAIL)" : ""}`, change: "" };
    const answers = obs.answers ?? [];
    if (answers.length === 0) return { state: "tripped", why: `no ${t.type} answer`, change: "" };
    const change = last?.answers?.length > 0 && last.answers.join(" ") !== answers.join(" ") ? `${t.type} answer changed: [${last.answers.join(", ")}] -> [${answers.join(", ")}]` : "";
    return { state: "ok", why: `${answers.length} ${t.type} answer(s)`, change };
  }
  if (t.status ? obs.status !== t.status : obs.status < 200 || obs.status >= 400) return { state: "tripped", why: `HTTP ${obs.status}${t.status ? ` (expected ${t.status})` : ""}`, change: "" };
  if (t.text && !String(obs.text ?? "").includes(t.text)) return { state: "tripped", why: `expected text missing: "${t.text}"`, change: "" };
  const change = t.pin && last?.hash && obs.hash && obs.hash !== last.hash ? `content changed (fingerprint ${last.hash} -> ${obs.hash})` : "";
  return { state: "ok", why: `HTTP ${obs.status}`, change };
}

/// THE EVIDENCE CHAIN: every event's hash covers the hash of the event before it, its seq, its time, its kind and
/// its text, so the mirrored events.jsonl on the owner's machine is tamper-evident on its own (`veil --tater
/// verify <run>` walks it; src/cli/tot.zig recomputes exactly this).
export async function chainHash(prev, seq, t, kind, text) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${prev}\n${seq}\n${t}\n${kind}\n${text}`));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Walk event rows, oldest first: every signed row must hash as written and point at the signed row before it.
/// Rows an older runtime wrote unsigned are counted, not judged. `{ok, signed, unsigned, seq, why}`.
export async function verifyChain(rows) {
  let prev = null;
  let signed = 0;
  let unsigned = 0;
  for (const r of rows) {
    if (typeof r.hash !== "string" || r.hash.length !== 64) {
      unsigned += 1;
      continue;
    }
    if (prev !== null && r.prev !== prev) return { ok: false, signed, unsigned, seq: r.seq, why: `event ${r.seq} does not follow the event before it (prev ${clip(r.prev, 12)}, expected ${clip(prev, 12)})` };
    if ((await chainHash(r.prev ?? "", r.seq, r.t, r.kind, r.text)) !== r.hash) return { ok: false, signed, unsigned, seq: r.seq, why: `event ${r.seq} was altered: its hash does not match its text` };
    prev = r.hash;
    signed += 1;
  }
  return { ok: true, signed, unsigned, seq: 0, why: "" };
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
  "or measured better in an EARLIER iteration is now broken, gone or measures worse. " +
  "Measure the human's requested outcome, not activity. A checklist, a larger file, a failed-login note, a generic " +
  "homepage or a saved error page is not progress toward collecting data or completing an external action. " +
  "write_file, say, remembered facts and reports from minds contain the agent's own claims; saving them does not " +
  "prove their contents. For a factual goal cite the source observation; for a goal to create an artifact cite its " +
  "read-back content and assess whether it actually meets the request. Unknown, inaccessible and not found are " +
  "different states. Do not infer account existence, identity, wrongdoing, login success, submission success or " +
  "elapsed time from an attempt. Previously observed information is not a new improvement. " +
  "Use complete:true only when the entire goal is verified, including any external confirmation it requires.";

function judgeQuestion(goalText) {
  return (
    `The goal: ${clip(goalText, 16000)}\n` +
    "Grade the LAST iteration. Reply with exactly one line:\n" +
    'IMPROVED | score: <done>/<total> | evidence: <what changed toward the goal> | proof: {"tool": 1, "quote": "<exact substring of that tool result>", "kind": "observation", "complete": false}\n' +
    "using SAME or REGRESSED in place of IMPROVED when that is the truth, and `score: none` when no tool result in " +
    "this iteration gave a count that measures the goal (items done out of a total, checks passing). " +
    "tool is the numbered T row; quote must be verbatim, including whitespace. kind is observation for source or " +
    "execution results, artifact only for read_file checking an artifact the human requested. An action acknowledgement " +
    "alone is insufficient. For SAME with no observation, omit proof."
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
    "State the action, the expected observable result and how to verify it in one concise instruction. " +
    "Use the last failure to choose a changed method or repair its cause; merely retrying it or renaming the goal is no new approach. " +
    "Prefer a step whose effect a tool can show, and choose only a step your tools and YOUR PYTHON as listed above can carry out: " +
    "a step that needs a package or a tool you do not have is a wasted iteration. " +
    "Establish how finished is measured once, in plan_set or an existing plan; then execute it. Do not spend repeated " +
    "iterations rewriting checklists. A CLAIM OF WORK IS NOT WORK. " +
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
  { name: "run_python", args: '{"code": "<a script>", "files": ["<a file of yours to put beside it>"]}', what: "run Python 3.12. The standard library is there, `import requests` and urllib work for HTTP, and a pure-Python package you import is installed from PyPI by itself. There are NO processes or shell (no subprocess, no os.system), and a package with native code is there only if YOUR PYTHON lists it. Your files are in its working directory under their plain names (all of them, or only those you list in files): open them by name, never by a /workspace or /tmp path. It prints; the TEXT files it writes are kept in your workspace (no images: write SVG or HTML)", need: "python" },
  { name: "pip_install", args: '{"packages": ["<name>"]}', what: "install pure-Python packages from PyPI for your scripts; they stay installed", need: "python" },
  { name: "save_skill", args: '{"name": "<short_name>", "about": "<what it does and its ARGS>", "code": "<a Python script reading ARGS>"}', what: "keep a script as a tool of your own, for every later iteration", need: "python" },
  { name: "run_skill", args: '{"name": "<skill>", "args": {}}', what: "run a skill you saved; `args` arrives as ARGS", need: "python" },
  // recursive self-improvement: the actual Worker source, shared by this account's tots
  { name: "runtime_read", args: '{"offset": 0, "limit": 4000}', what: 'read your runtime source and revision, including prompts, tools and stop rules; use {"find": "<function or constant>"} to jump to code, or page through it with next_offset' },
  { name: "runtime_edit", args: '{"revision": 0, "find": "<exact passage>", "replace": "<replacement>"}', what: "edit your runtime source at the revision you read; any code may be changed. Use source instead of find/replace to replace the whole runtime. Changes are shared by every tot in this account" },
  { name: "runtime_deploy", args: '{"revision": 1}', what: "deploy your edited runtime without an approval step. The owner's running veil uploads it on its next sync; runtime_read reports deployment or compiler errors. No local-machine execution grant is needed" },
  { name: "runtime_revert", args: '{"revision": 2}', what: "restore the last successfully DEPLOYED runtime source as a new revision, at the revision you read: the way back when an edit failed to deploy or made things worse" },
  // Agent Garrett: a second Worker in this account (github.com/gary23w/garrettstimpson.ca/agent), a blue-team belt over MCP
  { name: "garrett_tools", args: "{}", what: "list Agent Garrett's security tools (CVE / KEV / EPSS intel, DNS and certificate transparency, RDAP, email security posture, IOC extraction, evidence manifests, forensic timelines, and more) and the argument names they take", need: "garrett" },
  { name: "garrett", args: '{"name": "<garrett tool>", "args": {"target": "example.com"}}', what: "run one of Agent Garrett's tools over MCP by name (with or without its security_ prefix; calling security_<name> directly is the same); its text comes back with its evidence metadata. Preserve each tool's typed JSON arguments", need: "garrett" },
  { name: "garrett_launch", args: "{}", what: "ask your human's veil to launch Agent Garrett into this account as a second Worker and point every tot at it; garrett and garrett_tools appear in your belt once it answers" },
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
const MIND_TOOLS = new Set(["tool_schema", "write_file", "read_file", "list_files", "append_file", "web_search", "web_fetch", "http_request", "run_python", "pip_install", "run_skill", "remember", "recall", "pad_read", "pad_write", "garrett", "garrett_tools"]);

/// Agent Garrett is reachable when the veil server set both secrets on this Worker (cf_tot.zig launchGarrett, or
/// `veil --tater key garrett_url` / `garrett_token` for an agent the owner deployed by hand).
const hasGarrett = (env) => /^https:\/\//i.test(String(env.GARRETT_MCP_URL ?? "")) && typeof env.GARRETT_MCP_TOKEN === "string" && env.GARRETT_MCP_TOKEN.length > 0;

/// Whether this tot was asked to carry Agent Garrett: deployed or configured with `garrett` (/garrett on|off).
const wantsGarrett = (cfg) => cfg.garrett === true;

/// The tools this tot has here: everything, minus what a missing binding takes away. Agent Garrett's verbs are
/// opt-in per tot: garrett / garrett_tools only when it was asked for AND the account has the agent;
/// garrett_launch only when it was asked for and the account has none yet.
function toolsFor(env, cfg) {
  const want = wantsGarrett(cfg);
  const have = { browser: !!env.BROWSER, python: !!env.PY, garrett: want && hasGarrett(env) };
  const list = [{name:"tool_schema",args:'{"name":"<available tool>"}',what:"inspect one available tool\'s complete typed input schema or example arguments before calling it"}, ...TOOLS].filter((t) => !t.need || have[t.need]).filter((t) => t.name !== "garrett_launch" || (cfg.garrett === true && !hasGarrett(env)));
  const full = [...list, ...(have.garrett ? env.SECURITY_TOOLS ?? [] : [])];
  return cfg.local ? [...full, LOCAL_TOOL] : full;
}

/// What a tot is told about the tools it lacks, so it plans around them instead of calling them.
function missingNote(env, cfg) {
  const miss = [];
  if (!env.BROWSER) miss.push("a browser (browser_*)");
  if (!env.PY) miss.push("Python (run_python, skills)");
  if (wantsGarrett(cfg) && !hasGarrett(env)) miss.push("Agent Garrett security tools (the deployment connection is not ready)");
  return miss.length ? `NOT AVAILABLE in this account right now: ${miss.join(", ")}. Work with the tools listed.\n` : "";
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

export function toolIndex(tools) {
  return tools.map((t) => `- ${t.name}: ${clip(t.what, 100)}`).join("\n");
}

export function toolList(tools) {
  return tools.map((t) => t.name.startsWith("security_")
    ? `- ${t.name}: ${clip(t.what, 100)} (typed arguments: call tool_schema)`
    : `- ${t.name} ${t.args} : ${t.what}`).join("\n");
}

// ------------------------------------------------------------------------------------------ the tool map
// A port of src/worker/chat/belt.zig: the belt as a tree the model walks. The ENGINE (this object) holds the whole
// map, the visited marks, the path and the open set; the MODEL sees the branches where it stands, at most
// BRANCH_SHOW of them, and does the one thing a tiny model does reliably: pick the line that matches, go deeper,
// back out when it was wrong. Reaching a GROUP opens it: its tools join the TOOLS list by name. The tree only
// ever shrinks what is ADVERTISED, never what is CALLABLE: runTool dispatches every tool, and a call by a known
// name opens its group and runs in the same round.

export const NAV_TOOL = "open_tools";
const NAV_DEF = {
  name: NAV_TOOL,
  args: '{"path": "<branch>"}  or  {"find": "<what you need>"}  or  {"back": true}  or  {}',
  what: "your tools are a MAP, not a list: with no arguments it shows the families; path walks into one and OPENS its tools, callable by name from then on; find searches the whole map at once; back leaves a branch that did not fit. A tool whose name you already know can be called directly: it opens itself",
};
const DOCTRINE =
  "YOUR TOOLS ARE A MAP. The tools listed are callable now; open_tools reaches the rest. When you need something you " +
  "have no tool for, call open_tools with no arguments: it shows the families, each with one line saying what it is for. " +
  "Pick the line that matches and call open_tools with its path; keep going one level at a time until a branch OPENS and " +
  "lists tools you can call by name. If a branch does not fit, open_tools back=true and try another. If you know the " +
  "tool's name already, just call it. Never say a tool is missing before you have looked at the map.";
/// The core a small model keeps when the whole belt is walked (/belt map).
const CORE_SMALL = new Set(["tool_schema", "write_file", "read_file", "edit_file", "append_file", "list_files", "web_search", "web_fetch", "remember", "recall", "plan_set", "plan_done", "say"]);

const TOOL_PATH = {
  write_file: "files", read_file: "files", edit_file: "files", append_file: "files", list_files: "files", delete_file: "files",
  web_search: "web/fetch", web_fetch: "web/fetch", http_request: "web/fetch",
  run_python: "code", pip_install: "code", save_skill: "code", run_skill: "code",
  runtime_read: "self/runtime", runtime_edit: "self/runtime", runtime_deploy: "self/runtime", runtime_revert: "self/runtime", tool_schema: "self/schema",
  remember: "mind/memory", recall: "mind/memory", feel: "mind/memory", plan_set: "mind/plan", plan_done: "mind/plan",
  pad_read: "tots/pad", pad_write: "tots/pad", tell: "tots/pad", swarm: "tots/swarm",
  say: "human", goal_queue: "human", local_run: "human",
  garrett_tools: "security/garrett", garrett: "security/garrett", garrett_launch: "security/garrett",
};
const hasAny = (name, keys) => keys.some((k) => name.includes(k));

/// Agent Garrett's catalogue, grouped by what a tool is for: keyword rules rather than a name table, so a tool the
/// catalogue gains next month lands somewhere sensible. The same rules as belt.zig's securityPath.
function securityPath(n) {
  if (n.startsWith("gary_")) {
    const g = n.slice(5);
    if (hasAny(g, ["shell"])) return "security/agent/shell";
    if (hasAny(g, ["traffic"])) return "security/agent/traffic";
    if (hasAny(g, ["finding", "fact", "retest"])) return "security/agent/findings";
    if (hasAny(g, ["asset", "company", "scope"])) return "security/agent/assets";
    if (hasAny(g, ["tool", "mcp", "skill", "llm"])) return "security/agent/extend";
    if (hasAny(g, ["web", "fetch"])) return "security/agent/web";
    if (["read", "write", "edit", "multiedit", "glob", "grep", "ls", "bash"].includes(g)) return "security/agent/files";
    if (hasAny(g, ["trace", "output", "graph", "node", "digest"])) return "security/agent/inspect";
    return "security/agent/tasks";
  }
  if (n === "hash_id" || hasAny(n, ["crypto", "jwt", "encode", "decode"])) return "security/decode";
  if (hasAny(n, ["nvd", "epss", "kev", "cve", "cvss", "mitre", "circl", "exposure"])) return "security/intel";
  if (hasAny(n, ["dns", "cert", "crtsh", "subdomain", "rdap", "asn", "cidr", "ip_geo", "tor_exit", "origin_ip", "shodan", "greynoise", "whois"])) return "security/dns-ip";
  if (hasAny(n, ["email", "gravatar", "holehe", "pwned", "breach", "leak", "stealer", "paste"])) return "security/email-breach";
  if (hasAny(n, ["people", "username", "github", "devto", "keybase", "phone", "image_osint", "opencorporates", "edgar"])) return "security/people";
  if (hasAny(n, ["forensic", "disk_", "memory_", "pcap", "evtx", "eventlog", "artifact", "evidence", "timestamp", "timeline"])) return "security/forensics";
  if (hasAny(n, ["onion"])) return "security/darkweb";
  if (hasAny(n, ["fetch", "crawl", "http", "cors", "fingerprint", "wellknown", "favicon", "urlscan", "wayback", "archive", "unshorten", "dork", "search", "typosquat", "phish"])) return "security/web";
  if (hasAny(n, ["hash", "yara", "file_analyze", "reverse_analyze", "malware", "urlhaus", "ransomware", "ioc", "persistence"])) return "security/malware";
  if (hasAny(n, ["nmap", "vuln", "bucket", "poc", "disclosure"])) return "security/scan";
  return "security/other";
}

/// The belt's security tools nearest to a name the model guessed: the most shared `_` tokens, then a substring
/// either way. " Nearest: a, b." or "" when nothing comes close. Pure.
export function nearestSecurity(name, tools) {
  const want = String(name ?? "").toLowerCase().replace(/^security_/, "");
  if (want.length < 2) return "";
  const toks = want.split("_").filter((t) => t.length > 1);
  const scored = [];
  for (const t of tools) {
    const bare = String(t.name).replace(/^security_/, "");
    let s = toks.filter((k) => bare.split("_").includes(k)).length * 2;
    if (bare.includes(want) || want.includes(bare)) s += 3;
    if (s > 0) scored.push({ name: t.name, s });
  }
  scored.sort((a, b) => b.s - a.s || (a.name < b.name ? -1 : 1));
  return scored.length > 0 ? ` Nearest: ${scored.slice(0, 5).map((x) => x.name).join(", ")}.` : "";
}

/// Agent Garrett's catalogue as the belt holds it, by branch, each tool by its belt name with the argument names
/// it takes: every tool on one screen, so a step never guesses a name. Pure.
export function beltListing(tools) {
  const groups = new Map();
  for (const t of tools) {
    const path = toolPath(t.name);
    if (!groups.has(path)) groups.set(path, []);
    const props = Object.keys(t.inputSchema?.properties ?? {});
    groups.get(path).push(`${t.name}${props.length > 0 ? ` (${props.slice(0, 6).join(", ")}${props.length > 6 ? ", ..." : ""})` : ""}`);
  }
  const lines = [...groups].sort((a, b) => (a[0] < b[0] ? -1 : 1)).map(([path, names]) => `${path} - ${BRANCH_DESC[path] ?? "tools"}:\n  ${names.join(", ")}`);
  return `Agent Garrett's ${tools.length} tool${tools.length === 1 ? "" : "s"} on your belt, by branch (each with the argument names it takes):\n${lines.join("\n")}\nCall one by its security_ name as a tool of your own; tool_schema {"name": "<it>"} shows its full typed schema. The garrett wrapper takes the same name, with or without security_.`;
}

/// Where a tool sits on the map. Pure.
export function toolPath(name) {
  if (TOOL_PATH[name]) return TOOL_PATH[name];
  if (name.startsWith("security_")) return securityPath(name.slice(9));
  if (name.startsWith("browser_")) return "web/browser";
  if (name.startsWith("runtime_")) return "self/runtime";
  return "other";
}

/// The one line a BRANCH shows for itself: what it is FOR. A branch not listed describes itself by its tools.
const BRANCH_DESC = {
  files: "your workspace: write, read, edit, append, list and delete your files (they last; your human can open them)",
  web: "anything on the web: fetch a page or an API, search, make any HTTP call, or drive a real browser",
  "web/fetch": "fetch a URL's text or JSON without a browser; search the web; make any HTTP call",
  "web/browser": "a real browser: open a page, read it as numbered elements, click, type, select, scroll, run JavaScript",
  code: "run Python beside your files, install packages, keep a script as a skill and run it again",
  self: "your own runtime and tool schemas: read, edit, deploy or revert the code every tot of this account runs",
  "self/runtime": "read, edit, deploy and revert the shared runtime source: prompts, tools, stop rules",
  "self/schema": "the complete typed input schema of one tool, before calling it",
  mind: "what you keep between iterations: facts, how you feel, your plan",
  "mind/memory": "keep and recall facts; record how you have come to feel about a topic",
  "mind/plan": "write or tick your plan for the goal",
  tots: "the other tots of this account: the shared scratchpad, messages, an inner swarm",
  "tots/pad": "read and write the scratchpad every tot shares; message another tot",
  "tots/swarm": "run several minds side by side, one task each",
  human: "report to your human, queue a follow-on goal, or queue a job for their machine",
  security: "Agent Garrett, your human's own blue-team agent: threat intel, DNS and certificates, email and breach checks, people and company OSINT, malware and forensics, scanning, and its own task system",
  "security/garrett": "Agent Garrett itself: list its tools, call one by name, or ask your human's veil to launch it",
  "security/intel": "vulnerability intelligence: CVE details, EPSS probability, CISA KEV status, CVSS, MITRE, exposure search",
  "security/dns-ip": "DNS records, certificate transparency, subdomains, RDAP and ASN registration, IP geolocation, Shodan and GreyNoise",
  "security/web": "a target web site: fetch, crawl, headers, CORS, tech fingerprint, .well-known, URL scans, Wayback, phishing and typosquat checks",
  "security/email-breach": "email security posture (SPF, DMARC, DNSSEC), breach and leak checks, pastes, stealer logs",
  "security/people": "OSINT on a person or company: usernames, GitHub, phone, image, corporate registries",
  "security/malware": "hashes, YARA, file and reverse analysis, IOC extraction, URLhaus, ransomware and persistence",
  "security/forensics": "disk, memory, PCAP, event-log and timeline forensics; evidence manifests; timestamps",
  "security/darkweb": "Tor .onion search, fetch and intel",
  "security/decode": "decode and encode data, identify hashes, JWTs, crypto addresses",
  "security/scan": "active scanning of a target in scope: nmap, vulnerability scan, buckets, CVE proof-of-concept, disclosure drafts",
  "security/agent": "Agent Garrett's own task system: shells, files, tasks and workers, findings, assets, traffic, extensions",
  "security/agent/shell": "open, drive, read and close interactive shells on the agent",
  "security/agent/files": "read, write, edit, search and list files on the agent",
  "security/agent/tasks": "spawn, steer, pause and stop the agent's tasks; set its goals, hints and constraints",
  "security/agent/inspect": "look inside running work: task graphs, worker traces and output, digests",
  "security/agent/findings": "record, list and retest findings and facts",
  "security/agent/assets": "assets, companies and scope on the agent's cases",
  "security/agent/traffic": "captured request/response traffic",
  "security/agent/extend": "the agent's custom tools, MCP connections and skills",
  "security/agent/web": "the agent's own web search and fetch",
  "security/other": "the rest of Agent Garrett's tools",
  other: "tools no family claims",
};

const STOP_WORDS = new Set(["that", "this", "with", "from", "have", "will", "your", "into", "then", "than", "they", "them", "what", "when", "which", "there", "their", "about", "would", "should", "could", "these", "those", "where", "after", "before", "while", "using", "based", "first", "other", "because", "also", "just", "only", "more", "most", "some", "such", "very", "each", "every", "over", "under", "does", "done", "make", "made", "take", "need", "want", "like", "been", "being", "were", "here", "next", "step", "goal", "tool", "tools", "iteration", "verify", "check", "result", "results", "file", "files", "save", "write", "read", "then", "note", "notes", "human", "report", "whether", "actual", "single", "best"]);

/// The content words of a request, lower-cased, deduplicated: 4-32 characters, no stop words. Pure.
export function cueTokens(text) {
  const out = [];
  const seen = new Set();
  for (const m of String(text ?? "").matchAll(/[A-Za-z0-9][A-Za-z0-9_]*/g)) {
    const tok = m[0].toLowerCase();
    if (tok.length < 4 || tok.length > 32 || STOP_WORDS.has(tok) || seen.has(tok)) continue;
    seen.add(tok);
    out.push(tok);
    if (out.length >= CUE_MAX) break;
  }
  return out;
}

/// How well a tool answers the cue: a cue word in its name or its line counts one; the tool's own name counts
/// four more (the step named it); plus what the walk has learned ties those words to it.
function toolScore(n, cue, learned) {
  let s = 0;
  const name = n.name.toLowerCase();
  const desc = n.desc.toLowerCase();
  for (const c of cue) {
    if (name.includes(c) || desc.includes(c)) s += 1;
    if (name === c) s += 4;
    if (learned) s += learned.bonus(c, n.name);
  }
  return s;
}

/// How well a branch answers the cue: its best tool, weighted, plus a little for each tool that answers at all
/// and for its own line, so one strong match beats a dozen weak ones.
function branchScore(tree, idx, cue, learned) {
  const n = tree.nodes[idx];
  if (n.kind === "tool") return toolScore(n, cue, learned) * 3;
  let best = 0;
  let hits = 0;
  for (const c of n.children) {
    const s = branchScore(tree, c, cue, learned);
    if (s > best) best = s;
    if (s > 0) hits += 1;
  }
  let own = 0;
  const desc = n.desc.toLowerCase();
  const name = n.name.toLowerCase();
  for (const c of cue) if (desc.includes(c) || name.includes(c)) own += 2;
  return best + Math.min(hits, 4) + own;
}

/// The map: families, groups and tools. Every tool entry is the belt's own (name, args, what, inputSchema...).
export class ToolTree {
  constructor() {
    this.nodes = [{ kind: "family", path: "", name: "", desc: "every tool, by what it is for", parent: -1, children: [], tool_count: 0 }];
    this.byPath = new Map([["", 0]]);
    this.byName = new Map();
  }
  /// `path` is the GROUP the tool joins ("web/browser"); the families above it are made as needed. A tool that
  /// lands on a family (a path that already has branches) goes into that family's `misc` group.
  addTool(path, entry) {
    if (!entry?.name || this.byName.has(entry.name)) return;
    const segs = String(path).split("/").filter(Boolean);
    if (segs.length === 0) segs.push("other");
    let parent = 0;
    let acc = "";
    for (let i = 0; i < segs.length; i++) {
      acc = acc ? `${acc}/${segs[i]}` : segs[i];
      const last = i === segs.length - 1;
      let idx = this.byPath.get(acc);
      if (idx === undefined) {
        idx = this.nodes.length;
        this.nodes.push({ kind: last ? "group" : "family", path: acc, name: segs[i], desc: BRANCH_DESC[acc] ?? "", parent, children: [], tool_count: 0 });
        this.nodes[parent].children.push(idx);
        this.byPath.set(acc, idx);
      } else if (last && this.nodes[idx].kind === "family") {
        parent = idx;
        acc = `${acc}/misc`;
        idx = this.byPath.get(acc);
        if (idx === undefined) {
          idx = this.nodes.length;
          this.nodes.push({ kind: "group", path: acc, name: "misc", desc: `the rest of ${segs[i]}`, parent, children: [], tool_count: 0 });
          this.nodes[parent].children.push(idx);
          this.byPath.set(acc, idx);
        }
      } else if (!last && this.nodes[idx].kind === "group") {
        this.nodes[idx].kind = "family"; // a group gains branches: its own tools stay on it as a group would hold them
      }
      parent = idx;
    }
    const t = this.nodes.length;
    this.nodes.push({ kind: "tool", path: `${acc}/${entry.name}`, name: entry.name, desc: String(entry.what ?? ""), def: entry, parent, children: [], tool_count: 0 });
    this.nodes[parent].children.push(t);
    this.byName.set(entry.name, t);
    for (let up = parent; up >= 0; up = this.nodes[up].parent) this.nodes[up].tool_count += 1;
  }
  groupOf(tool) {
    return this.nodes[tool].parent;
  }
  /// The tools under a node, at any depth, by name.
  namesUnder(idx) {
    const out = [];
    const stack = [idx];
    while (stack.length > 0) {
      const n = this.nodes[stack.pop()];
      if (n.kind === "tool") out.push(n.name);
      else for (let i = n.children.length - 1; i >= 0; i--) stack.push(n.children[i]);
    }
    return out;
  }
}

/// The map built from a tool list, every tool under toolPath's branch for it. Pure.
export function buildTree(tools) {
  const tree = new ToolTree();
  for (const t of tools) tree.addTool(toolPath(t.name), t);
  return tree;
}

/// What the walk has learned on this tot: cue word -> tool edges, from finds that led to calls and from each
/// step's words tied to the tools it ended up calling. Capped; the weakest edge goes when the cap is reached.
export class Learned {
  constructor(rows) {
    this.edges = new Map();
    for (const r of Array.isArray(rows) ? rows : []) if (Array.isArray(r) && typeof r[0] === "string" && typeof r[1] === "string") this.edges.set(`${r[0]}\t${r[1]}`, Math.max(1, Number(r[2]) || 1));
  }
  note(cue, tool) {
    for (const tok of cueTokens(cue)) this.bump(tok, tool);
  }
  bump(tok, tool) {
    const k = `${tok}\t${tool}`;
    if (this.edges.has(k)) {
      this.edges.set(k, this.edges.get(k) + 1);
      return;
    }
    if (this.edges.size >= LEARNED_MAX) {
      let weakest = null;
      for (const [key, n] of this.edges) if (weakest === null || n < this.edges.get(weakest)) weakest = key;
      this.edges.delete(weakest);
    }
    this.edges.set(k, 1);
  }
  bonus(tok, tool) {
    return Math.min(BONUS_CAP, this.edges.get(`${tok}\t${tool}`) ?? 0);
  }
  rows() {
    return [...this.edges].map(([k, n]) => [...k.split("\t"), n]);
  }
}

/// One step's walk through the map: what is open, where the model stands, what it has tried and left. `core`
/// names the tools advertised beside the map whatever is open; `saved` is the previous step's open set.
export class Walk {
  constructor(tree, cue, core, learned) {
    this.tree = tree;
    this.cue = String(cue ?? "");
    this.core = core ?? new Set();
    this.learned = learned ?? null;
    this.here = 0;
    this.open = []; // [{g, stamp, opened_at}], at most OPEN_MAX
    this.dead = new Set(); // nodes entered and left without a call from under them
    this.seen = new Set();
    this.round = 1;
    this.nav_streak = 0;
    this.dirty = true; // the TOOLS list changed since the model last saw it
    this.closed = -1; // the group closed to make room, for the next view's note
    this.pending_find = "";
    this.called = new Set();
  }
  /// Step start: restore the previous step's open set, then the engine's own read of the map: the best group for
  /// the cue opens if anything answers it well enough. No model call, no round spent.
  start(saved) {
    for (const p of Array.isArray(saved) ? saved : []) {
      const idx = this.tree.byPath.get(String(p));
      if (idx !== undefined && this.tree.nodes[idx].kind === "group") this.openGroup(idx);
    }
    const g = this.bestGroup(this.cue);
    if (g !== null) this.openGroup(g);
    this.dirty = true;
  }
  bestGroup(cue) {
    const toks = cueTokens(cue);
    if (toks.length === 0) return null;
    let best = null;
    let bestS = 0;
    this.tree.nodes.forEach((n, i) => {
      if (n.kind !== "group") return;
      const s = branchScore(this.tree, i, toks, this.learned);
      if (s > bestS) {
        bestS = s;
        best = i;
      }
    });
    return bestS >= PREOPEN_MIN ? best : null;
  }
  tick() {
    this.round += 1;
  }
  slotOf(g) {
    return this.open.findIndex((o) => o.g === g);
  }
  openGroup(g) {
    const s = this.slotOf(g);
    if (s >= 0) {
      this.open[s].stamp = this.round;
      return;
    }
    if (this.open.length >= OPEN_MAX) {
      let lru = 0;
      this.open.forEach((o, i) => {
        if (o.stamp < this.open[lru].stamp) lru = i;
      });
      this.closed = this.open[lru].g;
      this.open.splice(lru, 1);
    }
    this.open.push({ g, stamp: this.round, opened_at: this.round });
    this.seen.add(g);
    this.dead.delete(g);
    this.dirty = true;
  }
  /// A tool was called by name: its group stays warm, the walk is no longer wandering, and if the group was not
  /// open (a name the model knew) it opens now; the caller runs the call in the same round. Returns the group's
  /// path when this call OPENED it, else null. A core tool opens nothing: it is always advertised.
  noteCall(name) {
    this.nav_streak = 0;
    const t = this.tree.byName.get(name);
    if (t === undefined) return null;
    const g = this.tree.groupOf(t);
    this.dead.delete(g);
    this.called.add(name);
    if (this.pending_find) {
      this.learned?.note(this.pending_find, name);
      this.pending_find = "";
    }
    if (this.core.has(name)) return null;
    const s = this.slotOf(g);
    if (s >= 0) {
      this.open[s].stamp = this.round;
      return null;
    }
    this.openGroup(g);
    return this.tree.nodes[g].path;
  }
  isOpen(name) {
    if (this.core.has(name)) return true;
    const t = this.tree.byName.get(name);
    return t !== undefined && this.slotOf(this.tree.groupOf(t)) >= 0;
  }
  knows(name) {
    return this.tree.byName.has(name);
  }
  /// The tools the model sees now: the core, the navigation verb, then every open group's tools. Clears `dirty`.
  tools() {
    const out = [];
    const seen = new Set();
    for (const n of this.tree.nodes) {
      if (n.kind !== "tool" || !this.core.has(n.name)) continue;
      out.push(n.def);
      seen.add(n.name);
    }
    out.push(NAV_DEF);
    for (const o of this.open) {
      for (const c of this.tree.nodes[o.g].children) {
        const n = this.tree.nodes[c];
        if (n.kind !== "tool" || seen.has(n.name)) continue;
        out.push(n.def);
        seen.add(n.name);
      }
    }
    this.dirty = false;
    return out;
  }
  /// The open set for the next step: group paths, most recently used first.
  save() {
    return this.open.slice().sort((a, b) => b.stamp - a.stamp).map((o) => this.tree.nodes[o.g].path);
  }
  /// Step end: what this step asked for is tied to the tools it ended up calling, so the pre-walk opens them
  /// unasked next time the step sounds like this one.
  finish() {
    if (!this.learned) return;
    for (const name of this.called) if (!this.core.has(name)) this.learned.note(this.cue, name);
  }
  /// The open_tools verb. Returns the text the model reads: a view of a branch, the tools a group opened, or a
  /// find result.
  navigate(args) {
    const a = args && typeof args === "object" ? args : {};
    const find = String(a.find ?? a.query ?? a.search ?? "").trim();
    const path = String(a.path ?? a.branch ?? a.name ?? (typeof a.value === "string" ? a.value : "")).trim();
    const back = a.back === true || /^(true|yes|1)$/i.test(String(a.back ?? "")) || path === "..";
    if (find.length > 0) return this.renderFind(find, false);
    if (back) {
      this.leave();
      return this.renderView(this.here);
    }
    this.nav_streak += 1;
    if (this.nav_streak > NAV_MAX) {
      this.nav_streak = 0;
      return "(you have been walking the map for a while without calling a tool, so here is the whole map searched for what this step is about)\n" + this.renderFind(this.cue, true);
    }
    if (path.length === 0 || path === "/") {
      this.here = 0;
      return this.renderView(0);
    }
    const target = this.resolve(path);
    if (target === null) return `No branch named "${clip(path, 60)}" here. ` + this.renderView(this.here);
    const n = this.tree.nodes[target];
    if (n.kind === "tool") return this.enterGroup(this.tree.groupOf(target));
    if (n.kind === "group") return this.enterGroup(target);
    if (this.here !== target && this.here !== 0 && !this.isAncestor(this.here, target)) this.markLeft(this.here);
    this.here = target;
    return this.renderView(target);
  }
  // ---- internals ----
  isAncestor(maybe, idx) {
    for (let up = this.tree.nodes[idx].parent; up >= 0; up = this.tree.nodes[up].parent) if (up === maybe) return true;
    return false;
  }
  /// Leaving `idx`: a group opened this step and never called from is a dead end; a family whose viewed groups
  /// are all dead is dead too.
  markLeft(idx) {
    if (idx <= 0) return;
    const n = this.tree.nodes[idx];
    if (n.kind === "group") {
      const s = this.slotOf(idx);
      if (s >= 0 && this.open[s].stamp === this.open[s].opened_at) this.dead.add(idx);
    } else if (n.kind === "family") {
      let any = false;
      let allDead = true;
      for (const c of n.children) {
        if (!this.seen.has(c)) continue;
        any = true;
        if (!this.dead.has(c)) allDead = false;
      }
      if (any && allDead) this.dead.add(idx);
    }
  }
  leave() {
    this.nav_streak += 1;
    if (this.here === 0) return;
    this.markLeft(this.here);
    this.here = Math.max(0, this.tree.nodes[this.here].parent);
  }
  /// `path` as the model wrote it: from the root, else relative to where it stands, else a bare name anywhere.
  resolve(path) {
    const p = String(path).replace(/^[\s/]+|[\s/]+$/g, "");
    if (p.length === 0) return 0;
    const abs = this.tree.byPath.get(p);
    if (abs !== undefined) return abs;
    if (this.here !== 0) {
      const rel = this.tree.byPath.get(`${this.tree.nodes[this.here].path}/${p}`);
      if (rel !== undefined) return rel;
    }
    if (!p.includes("/")) {
      const i = this.tree.nodes.findIndex((n) => n.kind !== "tool" && n.name === p);
      if (i >= 0) return i;
      const t = this.tree.byName.get(p);
      if (t !== undefined) return t;
    }
    return null;
  }
  enterGroup(g) {
    if (this.here !== g && this.here !== 0 && this.here !== this.tree.nodes[g].parent) this.markLeft(this.here);
    this.here = g;
    this.closed = -1;
    this.openGroup(g);
    const n = this.tree.nodes[g];
    let out = `OPENED ${n.path} - ${n.desc}. These tools are callable by name now:\n`;
    for (const c of n.children) {
      const tn = this.tree.nodes[c];
      if (tn.kind === "tool") out += `  ${tn.name} - ${clip(tn.desc, 140)}\n`;
    }
    return out + this.renderOpenSet(g);
  }
  renderOpenSet(except) {
    const others = this.open.filter((o) => o.g !== except).map((o) => this.tree.nodes[o.g].path);
    let out = others.length > 0 ? `Also open: ${others.join(", ")}.` : "";
    if (this.closed >= 0) {
      out += ` Closed to make room: ${this.tree.nodes[this.closed].path} (reopen it with open_tools if you need it again).`;
      this.closed = -1;
    }
    return out.length > 0 ? out.trim() + "\n" : "";
  }
  /// The first few tool names under a branch with no line of its own.
  sampleNames(idx) {
    const names = this.tree.namesUnder(idx);
    return names.slice(0, 4).join(", ") + (names.length > 4 ? ", ..." : "");
  }
  /// The branches at `idx`: ranked for the cue, dead ends last and labelled, at most BRANCH_SHOW.
  renderView(idx) {
    const n = this.tree.nodes[idx];
    this.seen.add(idx);
    let out = idx === 0 ? 'TOOL MAP - the families. Pick the one whose line matches what you need: open_tools path="<name>".\n' : `TOOL MAP - you are at: ${n.path} (${n.desc}). Pick a branch: open_tools path="<name>".\n`;
    const cue = cueTokens(this.cue);
    const scored = n.children.map((c, i) => ({ c, i, s: this.dead.has(c) ? 0 : branchScore(this.tree, c, cue, this.learned) + 1 }));
    scored.sort((a, b) => b.s - a.s || a.i - b.i);
    const shown = scored.slice(0, BRANCH_SHOW);
    for (const { c } of shown) {
      const cn = this.tree.nodes[c];
      out += `  ${cn.name} - ${cn.desc || this.sampleNames(c)}`;
      if (cn.kind === "group") out += ` (${cn.tool_count} tools${this.slotOf(c) >= 0 ? ", open" : ""})`;
      else if (cn.kind === "family") out += ` (${cn.tool_count} tools in ${cn.children.length} branches)`;
      if (this.dead.has(c)) out += " [looked already: nothing fit]";
      out += "\n";
    }
    if (n.children.length > shown.length) out += `...and ${n.children.length - shown.length} more: name one, or open_tools find="what you need".\n`;
    if (idx !== 0) out += "Up one level: open_tools back=true. ";
    out += 'Anywhere at once: open_tools find="what you need".\n';
    return out + this.renderOpenSet(-1);
  }
  /// Breadth-first over every tool for the words in `q`: the best FIND_TOP with their paths; the best one's group
  /// is opened when there is a clear best (always, when the engine ran the find unasked).
  renderFind(q, unasked) {
    const cue = cueTokens(q);
    if (!unasked) this.pending_find = clip(q, 160);
    const top = [];
    this.tree.nodes.forEach((n, i) => {
      if (n.kind !== "tool") return;
      const s = toolScore(n, cue, this.learned);
      // a find is for what is not at hand: on a tie, a tool the model cannot call yet ranks above a core one
      if (s > 0) top.push({ i, s, core: this.core.has(n.name) ? 1 : 0 });
    });
    top.sort((a, b) => b.s - a.s || a.core - b.core || a.i - b.i);
    const best = top.slice(0, FIND_TOP);
    if (best.length === 0) return `Nothing on the map matches "${clip(q, 80)}". ` + this.renderView(0);
    let out = `FOUND for "${clip(q, 80)}":\n`;
    for (const { i, core } of best) {
      const n = this.tree.nodes[i];
      out += `  ${n.name} - ${clip(n.desc, 140)}  (in ${this.tree.nodes[n.parent].path}${core ? ", callable already" : ""})\n`;
    }
    const clear = best.length === 1 || best[0].s > best[1].s || best[0].core < best[1].core || this.tree.groupOf(best[0].i) === this.tree.groupOf(best[1].i);
    if (clear || unasked) {
      const g = this.tree.groupOf(best[0].i);
      this.here = g;
      this.closed = -1;
      this.openGroup(g);
      out += `Opened ${this.tree.nodes[g].path}: its tools are callable by name now.\n` + this.renderOpenSet(g);
    } else out += 'Two branches match equally. Open one: open_tools path="<its branch>".\n';
    return out;
  }
}

/// The walk for a step, or null when the belt stays a list: "flat" always; "auto" until the belt passes MAP_AT
/// tools (then the built-in belt is the core and the map holds what lies beyond it, Agent Garrett's catalogue);
/// "map" always, with CORE_SMALL as the core. `saved` is the previous step's open set, `learned` this tot's edges.
export function beltFor(cfg, tools, cue, saved, learned) {
  const mode = beltMode(cfg);
  if (mode === "flat" || (mode === "auto" && tools.length <= MAP_AT)) return null;
  const core = new Set(tools.filter((t) => (mode === "map" ? CORE_SMALL.has(t.name) : !t.name.startsWith("security_"))).map((t) => t.name));
  const w = new Walk(buildTree(tools), cue, core, learned);
  w.start(saved);
  return w;
}

/// The pick's view of a walked belt: the core, one line each, then the map's groups with the NAMES of their tools,
/// so the plan can name any tool on the belt without paying for every tool's line.
export function mapIndex(walk) {
  const lines = [];
  for (const n of walk.tree.nodes) if (n.kind === "tool" && walk.core.has(n.name)) lines.push(`- ${n.name}: ${clip(n.desc, 100)}`);
  lines.push("TOOL MAP (the rest of the belt; the step reaches a branch with open_tools, or calls a tool by name):");
  walk.tree.nodes.forEach((n, i) => {
    if (n.kind !== "group") return;
    const names = walk.tree.namesUnder(i).filter((x) => !walk.core.has(x));
    if (names.length > 0) lines.push(`  ${n.path} - ${n.desc || "tools"} (${names.length}): ${names.join(", ")}`);
  });
  return lines.join("\n");
}

// ------------------------------------------------------------------------------------------ Gary's 4tope
// A port of src/worker/chat/net.zig for the do loop: its rounds as a DAG, the critical chain, and the net.

const W_USED = 2;
const W_ISSUED = 1;
const W_THREAD = 1;
const W_WEAK = 0;
const C_USED = 1;
const C_ISSUED = 1;
const C_WEAK = 3;
const C_SUPERSEDED = 4;
const C_DEAD = 1;
const NET_HEAD = "CONTINUATION (Gary's 4tope: the earlier rounds of this step, laid out from where you stand; every line is verbatim from a tool result, so nothing here is a paraphrase):\n";
const FILE_TOOLS = new Set(["read_file", "write_file", "edit_file", "append_file", "delete_file"]);
const COMMON_WORDS = new Set(["which", "there", "their", "about", "would", "should", "could", "these", "those", "where", "after", "before", "while", "using", "based", "first", "other", "because", "return", "returns", "content", "result", "results", "value", "values", "string", "number", "false", "error", "function", "const", "write", "check", "tools", "model", "please", "thanks", "found", "output", "input", "lines", "bytes", "assistant", "system", "message", "messages", "status", "working", "being", "final", "args"]);

/// Does a result read as a failure? Judged on its opening, where every tool here puts it. Pure.
export function looksDead(text) {
  const head = String(text ?? "").slice(0, 400);
  if (resultFailed(head)) return true;
  if (/^(?:Error:|error:|\(no |\(failed|Traceback|BOT CHECK)/.test(head)) return true;
  return /Traceback \(most recent|No such file|not found|command not found|timed out|refused|exit code [12]\b|did not answer|could not be reached/.test(head);
}

/// Tokens a later step could only have got from THIS text: 5+ characters, carrying a letter, not a common word.
/// Paths and identifiers keep their punctuation. Pure.
export function distinctiveTokens(text, max = 32) {
  const out = [];
  const seen = new Set();
  for (const m of String(text ?? "").matchAll(/[A-Za-z0-9_./-]+/g)) {
    const tok = m[0].replace(/^[./_-]+|[./_-]+$/g, "");
    if (tok.length < 5 || tok.length > 64 || !/[A-Za-z]/.test(tok)) continue;
    const low = tok.toLowerCase();
    if (COMMON_WORDS.has(low) || seen.has(low)) continue;
    seen.add(low);
    out.push(tok);
    if (out.length >= max) break;
  }
  return out;
}

const oneLine = (s, max) => {
  const t = String(s ?? "").replace(/\s+/g, " ").trim();
  if (t.length <= max) return t;
  const cut = t.slice(0, max);
  const sp = cut.lastIndexOf(" ");
  return (sp > max / 2 ? cut.slice(0, sp) : cut).trimEnd() + "...";
};

/// The body of a RESULT message the loop wrote (`RESULT of <tool>:\n<text>\n\n<engine's line>`), or the message.
function resultBody(content) {
  const s = String(content ?? "");
  const m = /^RESULT of [^\n]*\n([\s\S]*?)(?:\n\n(?:This attempt failed\.|Check whether this result|This is your last call|Next action, or the final answer)[\s\S]*)?$/.exec(s);
  return m ? m[1] : s;
}

/// The do loop's messages as a dependency graph. `from` is where the rounds start (after the system message,
/// the task and any net a fold left). Nodes are in order, which is a topological order: every edge points at an
/// older node. Pure.
export function loopGraph(messages, from = 2) {
  const g = { nodes: [], calls: [], frontier: -1 };
  let round = 0;
  let prevStep = -1;
  for (let i = from; i < messages.length; i++) {
    const m = messages[i];
    const content = String(m?.content ?? "");
    if (m?.role === "assistant") {
      const act = parseAction(content);
      const call = act && typeof act.tool === "string" ? { name: ALIASES[act.tool] ?? act.tool, args: oneLine(JSON.stringify(act.args ?? {}), 160) } : null;
      if (call && call.name === NAV_TOOL) {
        // a walk of the map is the engine's business, not a derivation: it never rides the net
        g.nodes.push({ kind: "engine", at: i, round, name: "", args: "", text: "", full: "", deps: [], superseded: false, dead: false, bytes: content.length });
        continue;
      }
      if (call) round += 1;
      const node = { kind: call ? "step" : "note", at: i, round, name: call?.name ?? "", args: call?.args ?? "", text: oneLine(content, NEXT_MAX), full: "", deps: [], superseded: false, dead: false, bytes: content.length };
      const idx = g.nodes.push(node) - 1;
      g.frontier = idx;
      if (call) g.calls.push({ ...call, step: idx });
      // what this step READ: the previous round's results whose distinctive words its own words or arguments reuse
      if (prevStep >= 0) node.deps.push({ to: prevStep, w: W_THREAD });
      const toks = distinctiveTokens(content + " " + (call?.args ?? ""));
      for (let j = prevStep + 1; j < idx; j++) {
        const r = g.nodes[j];
        if (r.kind !== "result") continue;
        const used = toks.some((t) => r.full.includes(t.toLowerCase()));
        node.deps.push({ to: j, w: used ? W_USED : W_WEAK });
      }
      prevStep = idx;
      continue;
    }
    if (m?.role === "user" && /^RESULT of /.test(content) && !/^RESULT of open_tools:/.test(content)) {
      const body = resultBody(content);
      const issuer = g.calls.length > 0 && g.calls[g.calls.length - 1].step === prevStep ? g.calls[g.calls.length - 1] : null;
      const node = { kind: "result", at: i, round, name: issuer?.name ?? /^RESULT of ([^:\n]+)/.exec(content)?.[1] ?? "tool", args: issuer?.args ?? "", text: oneLine(body, EXCERPT_MAX), full: body.slice(0, 6000).toLowerCase(), deps: [], superseded: false, dead: looksDead(body), bytes: content.length };
      if (issuer) node.deps.push({ to: issuer.step, w: W_ISSUED });
      g.nodes.push(node);
      continue;
    }
    g.nodes.push({ kind: "engine", at: i, round, name: "", args: "", text: oneLine(content, EXCERPT_MAX), full: "", deps: [], superseded: false, dead: false, bytes: content.length });
  }
  // a later identical call, or a later read or write of the same file, makes the earlier result stale
  const fileOf = (args) => /"(?:name|path)":"([^"]+)"/.exec(args)?.[1] ?? "";
  for (let i = 0; i < g.nodes.length; i++) {
    const older = g.nodes[i];
    if (older.kind !== "result" || !older.name) continue;
    const file = FILE_TOOLS.has(older.name) ? fileOf(older.args) : "";
    for (let j = i + 1; j < g.nodes.length; j++) {
      const newer = g.nodes[j];
      if (newer.kind !== "result" || !newer.name) continue;
      if ((newer.name === older.name && newer.args === older.args) || (file && FILE_TOOLS.has(newer.name) && fileOf(newer.args) === file)) {
        older.superseded = true;
        break;
      }
    }
  }
  return g;
}

/// THE CRITICAL CHAIN: the longest weighted dependency path from the frontier back through the loop (the DAG
/// recurrence, one pass in order). Frontier first; empty when there is no frontier. Pure.
export function criticalChain(g) {
  if (g.frontier < 0) return [];
  const dist = new Array(g.nodes.length).fill(0);
  const via = new Array(g.nodes.length).fill(-1);
  g.nodes.forEach((node, i) => {
    for (const d of node.deps) {
      const cand = dist[d.to] + d.w;
      // ties go to the NEWER dependency: the frontier's recent reads over its old ones
      if (cand > dist[i] || (cand === dist[i] && via[i] >= 0 && d.to > via[i])) {
        dist[i] = cand;
        via[i] = d.to;
      }
    }
  });
  const out = [];
  for (let at = g.frontier; at >= 0; at = via[at]) out.push(at);
  return out;
}

/// THE SOURCE UNFOLDING: Dijkstra from the frontier over the graph (both directions, weighted so what the frontier
/// read is nearer than what it merely saw, and stale or failed results are farther), nodes taken in distance
/// order until `budget` characters are spoken for, laid out in shortest-path-tree order: NEXT (the frontier's own
/// words) / ON DISK (`ground`, verbatim) / RULED OUT (dead ends) / ESTABLISHED (each derivation contiguous). Nodes
/// `skip` names (a kept tail) are left out of the selection. "" when there is nothing to carry. Pure.
export function unfold(g, budget, ground = "", skip = null) {
  if (g.frontier < 0 || budget < 200) return "";
  const n = g.nodes.length;
  const INF = Number.MAX_SAFE_INTEGER;
  const dist = new Array(n).fill(INF);
  const parent = new Array(n).fill(-1);
  const done = new Array(n).fill(false);
  dist[g.frontier] = 0;
  const relax = (from, to, w) => {
    const target = g.nodes[to];
    let c = w === W_USED ? C_USED : w === W_WEAK ? C_WEAK : C_ISSUED;
    if (target.superseded) c += C_SUPERSEDED;
    if (target.dead) c += C_DEAD;
    if (dist[from] !== INF && dist[from] + c < dist[to]) {
      dist[to] = dist[from] + c;
      parent[to] = from;
    }
  };
  for (let left = n; left > 0; left--) {
    let u = -1;
    for (let i = 0; i < n; i++) if (!done[i] && dist[i] !== INF && (u < 0 || dist[i] < dist[u])) u = i;
    if (u < 0) break;
    done[u] = true;
    for (const d of g.nodes[u].deps) relax(u, d.to, d.w);
    g.nodes.forEach((node, i) => {
      for (const d of node.deps) if (d.to === u) relax(u, i, d.w);
    });
  }
  const frontier = g.nodes[g.frontier];
  const nextText = oneLine(frontier.text, Math.max(80, Math.floor(budget / 3)));
  const groundText = oneLine(ground, Math.floor(budget / 4));
  let spent = nextText.length + 64 + groundText.length + 200;
  const order = [...Array(n).keys()].sort((x, y) => dist[x] - dist[y] || y - x);
  const chosen = new Array(n).fill(false);
  for (const i of order) {
    if (dist[i] === INF) break;
    const node = g.nodes[i];
    if (i === g.frontier || node.kind !== "result" || node.superseded || node.text.length === 0) continue;
    if (skip && skip.has(i)) continue;
    const cost = node.text.length + node.name.length + node.args.length + 24;
    if (spent + cost > budget) continue;
    spent += cost;
    chosen[i] = true;
  }
  const line = (i) => {
    const node = g.nodes[i];
    return `- r${node.round} ${node.name || "tool"}${node.args ? " " + node.args : ""}${node.dead ? " -> " : ": "}${node.text}\n`;
  };
  let out = "NEXT (the frontier, in its own last words): ";
  if (nextText.length > 0) out += nextText;
  else {
    const calls = g.calls.filter((c) => c.step === g.frontier).map((c) => `${c.name}${c.args ? " " + c.args : ""}`);
    out += calls.length > 0 ? `it had just called ${calls.join(", ")}` : "(no words; see the results below)";
  }
  out += "\n";
  if (groundText.length > 0) out += `ON DISK: ${groundText}\n`;
  let anyDead = false;
  for (const i of order) {
    if (!chosen[i] || !g.nodes[i].dead) continue;
    if (!anyDead) out += "RULED OUT (calls that failed; do not repeat them as they were):\n";
    anyDead = true;
    out += line(i);
  }
  let anyEst = false;
  const visited = new Array(n).fill(false);
  const stack = [g.frontier];
  while (stack.length > 0) {
    const u = stack.pop();
    if (visited[u]) continue;
    visited[u] = true;
    if (chosen[u] && !g.nodes[u].dead) {
      if (!anyEst) out += "ESTABLISHED (what the frontier rests on, nearest first, each derivation contiguous):\n";
      anyEst = true;
      out += line(u);
    }
    const kids = [];
    parent.forEach((p, i) => {
      if (p === u) kids.push(i);
    });
    kids.sort((x, y) => dist[y] - dist[x]); // farthest first, so the nearest is walked first
    stack.push(...kids);
  }
  return anyDead || anyEst || groundText.length > 0 ? out : "";
}

/// Where a loop's rounds start: after the system message, the task, and any net a fold left.
const roundsFrom = (messages) => (messages[2]?.role === "user" && String(messages[2].content).startsWith(NET_HEAD) ? 3 : 2);

/// ON DISK for a tot: the files this step's record wrote, by name.
function filesWritten(record) {
  const names = [...new Set(record.filter((r) => ["write_file", "append_file", "edit_file"].includes(r.tool) && !resultFailed(r.result)).map((r) => String(r.args?.name ?? r.args?.path ?? "").trim()).filter(Boolean))];
  return names.length > 0 ? `files written this step: ${names.join(", ")}` : "";
}

/// THE FOLD: when the loop's messages pass `limit`, the rounds before the newest KEEP_ROUNDS become one net and
/// the critical chain's live results stay verbatim (clipped); the oldest round is no longer the one that goes.
/// What an earlier fold established rides on under EARLIER. Pure; returns a new array.
export function netFold(messages, limit, ground = "") {
  const size = (ms) => ms.reduce((n, m) => n + String(m.content ?? "").length, 0);
  if (size(messages) <= limit) return messages;
  const from = roundsFrom(messages);
  const pairs = Math.floor((messages.length - from) / 2);
  if (pairs <= KEEP_ROUNDS) return messages;
  const tailStart = from + 2 * (pairs - KEEP_ROUNDS);
  const g = loopGraph(messages, from);
  const tail = new Set();
  g.nodes.forEach((node, i) => {
    if (node.at >= tailStart) tail.add(i);
  });
  const protect = new Set();
  for (const i of criticalChain(g)) {
    const node = g.nodes[i];
    if (node.kind === "result" && !node.superseded && !node.dead && node.at < tailStart) protect.add(node.at);
  }
  const net = unfold(g, NET_LOOP_BUDGET, ground, tail) + earlierLines(messages, Math.floor(NET_LOOP_BUDGET / 3));
  const out = messages.slice(0, 2);
  out.push({ role: "user", content: NET_HEAD + (net || "(the earlier rounds established nothing a tool result shows)\n") });
  for (let i = from; i < tailStart; i += 2) {
    if (!protect.has(i + 1)) continue;
    out.push({ role: "assistant", content: clip(String(messages[i].content), 600) });
    const u = String(messages[i + 1].content);
    out.push({ role: "user", content: u.length > PROTECT_MAX ? resultExcerpt(u, PROTECT_MAX) : u });
  }
  out.push(...messages.slice(tailStart));
  return out;
}

/// What an earlier fold's net established and ruled out, verbatim, so a second fold (or the carry) keeps it.
function earlierLines(messages, budget) {
  if (roundsFrom(messages) !== 3) return "";
  // what was ruled out first: negative knowledge is what a cut forgets soonest and a clip must keep longest
  const rows = String(messages[2].content).slice(NET_HEAD.length).split("\n").filter((l) => l.startsWith("- r"));
  const lines = [...rows.filter((l) => / -> /.test(l)), ...rows.filter((l) => !/ -> /.test(l))].join("\n");
  return lines.length > 0 ? `EARLIER (from the fold before this one):\n${clip(lines, budget)}\n` : "";
}

/// The carry into the next iteration: the whole loop unfolded under NET_CARRY_BUDGET. "" when nothing to carry.
export function netOf(messages, ground = "") {
  const net = unfold(loopGraph(messages, roundsFrom(messages)), NET_CARRY_BUDGET, ground);
  return net.length > 0 ? net + earlierLines(messages, Math.floor(NET_CARRY_BUDGET / 3)) : "";
}

/// The last resort under a model's window: pairs go oldest first, never the system message, the task or a net.
function recentMessages(messages, limit = LOOP_BYTES) {
  const bounded = messages.slice();
  const from = roundsFrom(bounded);
  let size = bounded.reduce((n, m) => n + String(m.content ?? "").length, 0);
  while (size > limit && bounded.length > from + 2) {
    const removed = bounded.splice(from, 2);
    size -= removed.reduce((n, m) => n + String(m.content ?? "").length, 0);
  }
  return bounded;
}

const REPLY_RULE =
  'Reply with exactly ONE JSON object and nothing else. To use a tool: {"tool": "<name>", "args": {...}} with the ' +
  "tool's argument values inside args. For security_* tools, first use tool_schema to read the full input schema; preserve objects, arrays, booleans and numbers, and send argument values rather than the schema itself. " +
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

  if (seg[1] === "version" && method === "GET") return json({ ok: true, version: VERSION, max_tots: DEFAULT_MAX_TOTS, max_tots_ceil: MAX_TOTS_CEIL });
  if (seg[1] === "runtime") {
    if (method === "GET" && seg.length === 2) return call(padStub, "/runtime/state");
    if (method === "POST" && ["seed", "result", "upgrade"].includes(seg[2])) return call(padStub, "/runtime/" + seg[2], body);
    return bad("method not allowed", 405);
  }
  // Agent Garrett's launch: a tot asks (request), the owner's veil deploys it and answers (result). See padRoute.
  if (seg[1] === "garrett") {
    if (method === "GET" && seg.length === 2) return call(padStub, "/garrett/state");
    if (method === "POST" && ["request", "result", "clear"].includes(seg[2])) return call(padStub, "/garrett/" + seg[2], body);
    return bad("method not allowed", 405);
  }

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
      return json({ ok: true, version: VERSION, max_tots: roster.max_tots ?? DEFAULT_MAX_TOTS, pad_seq: roster.pad_seq ?? 0, tots });
    }
    if (method === "POST") {
      const claim = await (await call(padStub, "/pad/claim", { name: body.name, max_tots: body.max_tots })).json();
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
    if (p.startsWith("/runtime/")) return this.runtimeRoute(p, body);
    if (p.startsWith("/pad/") || p.startsWith("/garrett/")) return this.padRoute(p, url, body);
    if (p === "/init") return this.init(body);
    const cfg = upgraded(await this.store.get("cfg"));
    if (!cfg) return bad("no such tot", 404);
    // Every route but a sibling's /inbox is the owner's veil (it holds the token): contact, for the leash.
    if (p !== "/inbox") await this.contact(cfg);
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

  // ---------------------------------------------------------------- the shared runtime source

  async runtimeRoute(path, body) {
    // A transaction keeps two tots' edits from silently replacing one another. Source is chunked because
    // Durable Object values have a per-value size limit; the runtime can be larger than one value.
    return this.store.transaction(async (store) => {
      let state = await store.get("runtime");
      const readChunks = async (prefix) => [...(await store.list({ prefix })).values()].join("");
      const writeChunks = async (prefix, source) => {
        for (const key of (await store.list({ prefix })).keys()) await store.delete(key);
        for (let i = 0; i < source.length; i += 16000) await store.put(prefix + pad10(i), source.slice(i, i + 16000));
      };
      const readSource = () => readChunks("runtime:source:");
      const writeSource = (source) => writeChunks("runtime:source:", source);
      // the last source that DEPLOYED, kept apart from the drafts: the way back from an edit that failed
      const readGood = () => readChunks("runtime:good:");
      const keepGood = (source) => writeChunks("runtime:good:", source);
      // `host`: the current revision was written by the owner's veil (the seed, or a newer build offered as a
      // revision) rather than by a tot. A state an older runtime wrote has no flag: its seed is the host's.
      const hostOwned = (s) => s.host === true || (s.host === undefined && s.revision === 0);
      if (path === "/runtime/seed") {
        if (state) return json({ ok: true, ...state });
        if (typeof body.source !== "string" || !body.source.trim()) return bad("runtime source is required");
        await writeSource(body.source);
        await keepGood(body.source);
        state = { revision: Number(body.revision) || 0, deployed_revision: Number(body.revision) || 0, status: "deployed", error: "", length: body.source.length, host: true, good_host: true };
        await store.put("runtime", state);
        return json({ ok: true, ...state });
      }
      if (!state) return path === "/runtime/state" ? json({ ok: true, initialized: false }) : bad("runtime source has not synced yet; the owner's veil seeds it on its next sync");
      if (path === "/runtime/state") return json({ ok: true, initialized: true, ...state, host: hostOwned(state), source: state.status === "pending" ? await readSource() : "" });
      if (path === "/runtime/revert") {
        if (body.revision !== state.revision) return bad(`runtime revision changed to ${state.revision}; runtime_read before reverting`, 409);
        const good = await readGood();
        if (!good) return bad("no deployed runtime source is kept to revert to");
        await writeSource(good);
        state = { ...state, revision: state.revision + 1, deployed_revision: state.revision + 1, status: "deployed", error: "", length: good.length, author: body.author ?? "", reverted_from: state.revision, host: state.good_host === true };
        await store.put("runtime", state);
        return json({ ok: true, ...state, message: "the last deployed source is the current revision again; the Worker on Cloudflare already runs it" });
      }
      if (path === "/runtime/upgrade") {
        // THE HOST'S RUNTIME AS A REVISION: a newer veil carries a newer tot.js. It is applied only over a runtime
        // the host itself wrote that is deployed with nothing pending - the tots' own edits, drafts and uploads
        // are theirs, and a host never swaps beneath them - and it is a revision like any other: the next sync
        // uploads it, runtime_read shows it, runtime_revert takes it back.
        if (typeof body.source !== "string" || !body.source.trim()) return bad("runtime source is required");
        if (body.revision !== state.revision) return bad(`runtime revision changed to ${state.revision}`, 409);
        if (!hostOwned(state)) return bad(`the tots own this runtime: revision ${state.revision} was written by a tot, so the host's newer source is not applied over it (runtime_revert to a host revision would let it in)`);
        if (state.status !== "deployed" || state.revision !== state.deployed_revision) return bad(`revision ${state.revision} is ${state.status}; the host's source waits until it has deployed`);
        if ((await readSource()) === body.source) return json({ ok: true, ...state, unchanged: true });
        await writeSource(body.source);
        state = { ...state, revision: state.revision + 1, status: "pending", error: "", length: body.source.length, author: clip(String(body.by ?? "veil"), 40), host: true };
        await store.put("runtime", state);
        return json({ ok: true, ...state, message: "the host's newer runtime is the next revision; the owner's veil uploads it on its next sync" });
      }
      if (path === "/runtime/read") {
        const source = await readSource();
        let offset = Math.max(0, Number.parseInt(body.offset, 10) || 0);
        if (typeof body.find === "string" && body.find) {
          const at = source.indexOf(body.find, offset);
          if (at < 0) return bad("that text was not found in the runtime source");
          offset = Math.max(0, at - 200);
        }
        const limit = Math.min(6000, Math.max(1, Number.parseInt(body.limit, 10) || 4000)); // fit the tool-result context
        return json({ ok: true, ...state, offset, next_offset: Math.min(source.length, offset + limit), source: source.slice(offset, offset + limit) });
      }
      if (path === "/runtime/result") {
        if (!Number.isSafeInteger(body.revision) || body.revision < 0 || body.revision > state.revision) return bad("unknown runtime revision");
        if (!body.err) {
          state.deployed_revision = Math.max(state.deployed_revision, body.revision);
          // what is up there now is the way back for the next edit (the current source when this is the newest revision)
          if (body.revision === state.revision) {
            await keepGood(await readSource());
            state.good_host = hostOwned(state);
          }
        }
        // An older upload finishing must not discard a newer edit or its deployment request.
        if (body.revision === state.revision) {
          state.status = body.err ? "failed" : "deployed";
          state.error = String(body.err || "");
        }
        await store.put("runtime", state);
        return json({ ok: true, ...state });
      }
      if (body.revision !== state.revision) return bad(`runtime revision changed to ${state.revision}; runtime_read before editing or deploying again`, 409);
      if (path === "/runtime/edit") {
        let source;
        if (typeof body.source === "string") source = body.source;
        else {
          source = await readSource();
          if (typeof body.find !== "string" || !body.find.length || typeof body.replace !== "string") return bad("give find and replace strings, or the full source");
          const at = source.indexOf(body.find);
          if (at < 0 || source.indexOf(body.find, at + body.find.length) >= 0) return bad("find must match exactly one passage; read a larger passage and try again");
          source = source.slice(0, at) + body.replace + source.slice(at + body.find.length);
        }
        await writeSource(source);
        state = { ...state, revision: state.revision + 1, status: "draft", error: "", length: source.length, author: body.author ?? "", host: false };
        await store.put("runtime", state);
        return json({ ok: true, ...state });
      }
      if (path === "/runtime/deploy") {
        state.status = "pending";
        state.error = "";
        await store.put("runtime", state);
        return json({ ok: true, ...state, message: "queued for upload by the owner's veil on its next sync; runtime_read reports the result" });
      }
      return bad("not found", 404);
    });
  }

  // ---------------------------------------------------------------- the shared object: roster + scratchpad

  async padRoute(p, url, body) {
    const roster = (await this.store.get("roster")) ?? [];
    if (p === "/pad/roster") return json({ ok: true, tots: roster, pad_seq: (await this.store.get("padseq")) ?? 0, max_tots: (await this.store.get("max_tots")) ?? DEFAULT_MAX_TOTS });
    if (p === "/pad/claim") {
      // The first tot of an account is always the primary; a later one brings its own name.
      const name = roster.length === 0 ? PRIMARY : body.name;
      if (!validName(name)) return bad("a tot's name is 1-24 letters, digits, - or _, starting with a letter");
      if (roster.some((h) => h.name.toLowerCase() === name.toLowerCase())) return bad(`a tot named ${name} already exists`);
      // the owner's limit comes with each deployment (the veil server keeps it); the last one seen stands otherwise
      const limit = clampInt(body.max_tots, 1, MAX_TOTS_CEIL, (await this.store.get("max_tots")) ?? DEFAULT_MAX_TOTS);
      await this.store.put("max_tots", limit);
      if (roster.length >= limit) return bad(`this account already has ${limit} tater-tots (its limit); raise the limit or delete one first`);
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
    // Agent Garrett, shared by the account's tots: none -> pending (a tot asked, or the owner did) -> deployed |
    // failed. The owner's veil reads `pending` on its sync, launches the Worker through the Cloudflare login,
    // sets this Worker's GARRETT_MCP_URL / GARRETT_MCP_TOKEN secrets, and posts the result here.
    if (p.startsWith("/garrett/")) {
      const g = (await this.store.get("garrett")) ?? { status: "none" };
      if (p === "/garrett/state") return json({ ok: true, ...g });
      if (p === "/garrett/request") {
        if (g.status !== "deployed" && g.status !== "pending") {
          g.status = "pending";
          g.asked_by = clip(String(body.by ?? "?"), 24);
          g.asked_at = this.now();
          await this.store.put("garrett", g);
        }
        return json({ ok: true, ...g });
      }
      if (p === "/garrett/result") {
        if (body.err) {
          g.status = "failed";
          g.error = clip(String(body.err), 600);
        } else {
          g.status = "deployed";
          g.url = clip(String(body.url ?? ""), 300);
          g.error = "";
          g.deployed_at = this.now();
        }
        await this.store.put("garrett", g);
        return json({ ok: true, ...g });
      }
      if (p === "/garrett/clear") {
        await this.store.delete("garrett");
        return json({ ok: true, status: "none" });
      }
    }
    return bad("not found", 404);
  }

  // ---------------------------------------------------------------- lifecycle

  async init(body) {
    if (await this.store.get("cfg")) return bad("already deployed", 409);
    const now = this.now();
    const cfg = { name: body.name, created: now, paused: false, minds: 1, roam_s: 0, watch: [], ...DEFAULTS };
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
    if (typeof b.posture === "string" && /^(normal|defend)$/i.test(b.posture.trim())) cfg.posture = b.posture.trim().toLowerCase();
    if (b.leash_s !== undefined) cfg.leash_s = /^(0|off|none|no)$/i.test(String(b.leash_s).trim()) ? 0 : clampInt(b.leash_s, LEASH_MIN_S, LEASH_MAX_S, cfg.leash_s ?? 0);
    // Agent Garrett on this tot's belt: a boolean from the API, "on" / "off" from the command line
    if (b.garrett !== undefined) cfg.garrett = b.garrett === true || /^(on|true|yes|1)$/i.test(String(b.garrett).trim());
    // the belt as a map: auto (what lies beyond the built-in belt), map (everything but a small core), flat
    if (typeof b.belt === "string" && /^(auto|map|flat)$/i.test(b.belt.trim())) cfg.belt = b.belt.trim().toLowerCase();
  }

  settingsLine(cfg) {
    return `model ${cfg.model}, every ${cfg.pace_s}s, up to ${cfg.size} minds, ${callsWord(cfg)}${posture(cfg) === "defend" ? ", posture DEFEND" : ""}${cfg.leash_s > 0 ? `, leash ${cfg.leash_s}s` : ""}${wantsGarrett(cfg) ? ", Agent Garrett" : ""}${beltMode(cfg) !== "auto" ? `, belt ${beltMode(cfg)}` : ""}${cfg.paused ? ", paused" : ""}`;
  }

  async configure(cfg, body) {
    const wasPaused = cfg.paused;
    this.applyConfig(cfg, body);
    await this.store.put("cfg", cfg);
    await this.emit("status", `settings changed: ${this.settingsLine(cfg)}`);
    if (cfg.paused) await this.store.deleteAlarm();
    else if (wasPaused || (await this.store.getAlarm()) === null) {
      await this.store.put("loop_due", 0);
      await this.store.setAlarm(this.now() + 1000);
    }
    return json({ ok: true, tot: await this.status(cfg) });
  }

  async status(cfg) {
    const goal = (await this.store.get("goal")) ?? null;
    const usage = await this.usage();
    const alarm = await this.store.getAlarm();
    const queue = (await this.store.get("queue")) ?? [];
    const lessons = (await this.store.get("lessons")) ?? [];
    const leashed = !!(await this.store.get("leashed"));
    let state = "working";
    if (cfg.paused) state = "paused";
    else if (leashed) state = "leashed";
    else if (cfg.daily_calls > 0 && usage.calls >= cfg.daily_calls) state = "resting";
    else if (!goal || goal.status !== "active") state = queue.length > 0 ? "working" : "roaming";
    let guard_ok = 0;
    let guard_tripped = 0;
    for (const t of cfg.watch ?? []) {
      const w = await this.store.get("watch:" + watchKey(t));
      if (w?.state === "tripped") guard_tripped += 1;
      else if (w?.state === "ok") guard_ok += 1;
    }
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
      garrett: wantsGarrett(cfg) && hasGarrett(this.env), // its verbs are on this tot's belt
      garrett_on: wantsGarrett(cfg), // it was asked for, whether or not the account has the agent yet
      posture: posture(cfg),
      leash_s: cfg.leash_s ?? 0,
      leashed,
      belt: beltMode(cfg),
      belt_open: (await this.store.get("belt_open")) ?? [], // the map's open groups, carried between iterations
      learned: ((await this.store.get("belt_learned")) ?? []).length, // cue-word -> tool edges the walk has learned
      watch: (cfg.watch ?? []).length,
      guard_ok,
      guard_tripped,
      chain: (await this.store.get("chain")) ?? "",
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
    // a row that went wrong. `prev` and `hash` chain the row to the one before it (chainHash): well-formed text,
    // so the bytes hashed here are the bytes the mirror writes.
    const cut = clip(text, 4000);
    const full = typeof cut.toWellFormed === "function" ? cut.toWellFormed() : cut;
    const brief = clip((full.split("\n").find((l) => l.trim().length > 0) ?? "").trim(), 180);
    const t = this.now();
    const prev = (await this.store.get("chain")) ?? "";
    const hash = await chainHash(prev, seq, t, kind, full);
    await this.store.put("ev:" + pad10(seq), { seq, t, kind, text: full, brief, ok: kind !== "error", ...(extra ?? {}), prev, hash });
    await this.store.put("chain", hash);
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
    await this.store.put("loop_due", 0); // whatever rest or backoff the goal loop was in, this is worth an iteration
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
      else {
        await this.store.put("loop_due", 0);
        await this.store.setAlarm(now + 1000);
      }
      return cfg.paused ? `${cfg.name} is paused. /resume starts it again.` : `${cfg.name} is running again.`;
    }
    if (word === "/guard") return this.guardCommand(cfg, rest);
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
    if (word === "/pace" || word === "/size" || word === "/model" || word === "/calls" || word === "/posture" || word === "/leash" || word === "/garrett" || word === "/belt") {
      const key = { "/pace": "pace_s", "/size": "size", "/model": "model", "/calls": "daily_calls", "/posture": "posture", "/leash": "leash_s", "/garrett": "garrett", "/belt": "belt" }[word];
      if (word === "/posture" && !/^(normal|defend)$/i.test(rest)) return "Usage: /posture defend | normal. DEFEND freezes the runtime, reports bot checks instead of working through them, names this tot in every request and keeps it to read-only verification unless you ask for more.";
      if (word === "/leash" && !/^(\d+|off|none|no)$/i.test(rest)) return `Usage: /leash <seconds> | off. With a leash, no contact from your veil for that long holds the goal loop until it is back; the guard goes on. ${LEASH_MIN_S} to ${LEASH_MAX_S} seconds.`;
      if (word === "/garrett" && !/^(on|off)$/i.test(rest)) return "Usage: /garrett on | off. On, Agent Garrett's security tools (garrett, garrett_tools) are on this tot's belt once your human has deployed the agent (Settings > Deploy Agent Garrett); garrett_launch asks for it until then.";
      if (word === "/belt" && !/^(auto|map|flat)$/i.test(rest)) return `Usage: /belt auto | map | flat. The tools as a MAP the model walks (open_tools): auto walks only what lies beyond the built-in belt once there are more than ${MAP_AT} tools (Agent Garrett's catalogue); map walks everything but a small core, for a small model; flat is the whole list every call.`;
      this.applyConfig(cfg, { [key]: rest });
      await this.store.put("cfg", cfg);
      if (word === "/posture") await this.emit("status", `posture ${posture(cfg).toUpperCase()}${posture(cfg) === "defend" ? ": the runtime is frozen, bot checks are reported, every request names this tot, read-only unless the human asks for more" : ""}`);
      if (word === "/garrett") await this.emit("status", wantsGarrett(cfg) ? (hasGarrett(this.env) ? "Agent Garrett is on this tot's belt (garrett, garrett_tools)" : "Agent Garrett asked for: its tools are on this tot's belt once your human deploys the agent (garrett_launch asks)") : "Agent Garrett is off this tot's belt");
      if (word === "/belt") await this.emit("status", `belt ${beltMode(cfg)}: ${{ auto: "the map holds what lies beyond the built-in belt", map: "everything but a small core is reached through open_tools", flat: "every tool is listed on every call" }[beltMode(cfg)]}`);
      return this.settingsLine(cfg) + ".";
    }
    if (word === "/status") return goalStatusText(g);
    if (word.startsWith("/")) return "Commands: /goal <text> [--forever] [--budget N], /goal stop|resume|status|budget N|forever, /queue <goal>, /charter <text>, /pause, /resume, /pace <seconds>, /size <minds>, /model <id>, /calls <per day>, /guard add|rm|clear ..., /posture defend|normal, /leash <seconds>|off, /garrett on|off, /belt auto|map|flat. Anything else is a message this tot reads at its next iteration.";
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
    // what this tot has learned about the chosen model (never about its vendor): the room it needs, whether the
    // day went to the fallback, whether its window is smaller than the loop's
    const q = await this.quirk(cfg.model);
    const today = dayOf(this.now());
    const c = q.route === "fallback" && q.day === today && cfg.model !== FALLBACK_MODEL ? { ...cfg, model: FALLBACK_MODEL } : cfg;
    const qc = c === cfg ? q : await this.quirk(c.model); // the room is the answering model's
    const room = maxTokens * (qc.tokens_x >= 3 ? 3 : 1);
    let text;
    try {
      text = await this.askOnce(c, messages, room);
    } catch (e) {
      text = await this.healCall(c, messages, room, e);
    }
    if (text.length > 0) return text;
    if (room === maxTokens) {
      const again = await this.askOnce(c, messages, maxTokens * 3);
      if (again.length > 0) {
        // it answers with three times the room: after EMPTY_LEARN such rescues it is asked for that room first
        const learned = await this.learnQuirk(c.model, (x) => {
          x.empties = (x.empties ?? 0) + 1;
          if (x.empties >= EMPTY_LEARN && !(x.tokens_x >= 3)) {
            x.tokens_x = 3;
            return true;
          }
          return false;
        });
        if (learned) await this.emit("status", `learned: ${c.model} answers only with three times the room (its reasoning eats the rest); it is asked for that room first from now on`);
        return again;
      }
    }
    // Still nothing visible: the same question goes to a model that does not reason, so the iteration goes on.
    let rescueWhy = "";
    if (c.model !== FALLBACK_MODEL) {
      const rescue = await this.askOnce({ ...c, model: FALLBACK_MODEL }, messages, maxTokens).catch((e) => {
        rescueWhy = String(e?.message ?? e); // a provider error on the fallback is said, not read as silence
        return "";
      });
      if (rescue.length > 0) {
        if (!this.tick || !this.tick.rescued) await this.emit("status", `${c.model} returned no visible answer; ${FALLBACK_MODEL} answered instead (/model <id> picks another)`);
        if (this.tick) this.tick.rescued = true;
        // RESCUE_LEARN rescues in one UTC day: the rest of the day goes to the fallback, and tomorrow the chosen
        // model is tried again (the human's setting is untouched)
        const routed = await this.learnQuirk(c.model, (x) => {
          if (x.day !== today) {
            x.day = today;
            x.rescues = 0;
            x.route = "";
          }
          x.rescues = (x.rescues ?? 0) + 1;
          if (x.rescues >= RESCUE_LEARN && x.route !== "fallback") {
            x.route = "fallback";
            return true;
          }
          return false;
        });
        if (routed) await this.emit("status", `${c.model} answered nothing ${RESCUE_LEARN} times today; ${FALLBACK_MODEL} answers for it until tomorrow (UTC), then ${c.model} is tried again. /model <id> picks another`);
        return rescue;
      }
    }
    throw new Error(`the model (${c.model}) returned no text twice${rescueWhy ? `, and ${FALLBACK_MODEL} failed: ${clip(rescueWhy, 200)}` : ""} - it may be spending its whole reply on reasoning; /model <id> picks another`);
  }

  /// A model call failed: the remedy for its class is learned for that model and the call is retried ONCE.
  /// `context` (its window is smaller than the loop's): the window halves for this model and the messages are
  /// cut to it; `missing` (no such model): the fallback answers and the day is routed there. Any other error, or
  /// a failed remedy, surfaces the original error: every heal is fail-open.
  async healCall(cfg, messages, room, e) {
    const kind = classifyModelError(e?.message ?? e);
    if (kind === "context") {
      const first = await this.learnQuirk(cfg.model, (x) => {
        if (x.ctx_small) return false;
        x.ctx_small = true;
        return true;
      });
      if (first) await this.emit("status", `learned: ${cfg.model} has a smaller window than the loop assumed; its messages are held to half from now on`);
      try {
        return await this.askOnce(cfg, recentMessages(messages, Math.floor(LOOP_BYTES / 2)), room);
      } catch (again) {
        throw new Error(`${e?.message ?? e}; retried with the messages halved: ${again?.message ?? again}`, { cause: e });
      }
    }
    if (kind === "missing" && cfg.model !== FALLBACK_MODEL) {
      const first = await this.learnQuirk(cfg.model, (x) => {
        const today = dayOf(this.now());
        const was = x.route;
        x.day = today;
        x.route = "fallback";
        x.missing = true;
        return was !== "fallback";
      });
      if (first) await this.emit("status", `${cfg.model} is not available in this account (${clip(e?.message ?? e, 120)}); ${FALLBACK_MODEL} answers for it today. /model <id> picks another`);
      try {
        return await this.askOnce({ ...cfg, model: FALLBACK_MODEL }, messages, room);
      } catch (again) {
        throw new Error(`${e?.message ?? e}; ${FALLBACK_MODEL} also failed: ${again?.message ?? again}`, { cause: e });
      }
    }
    throw e;
  }

  /// What is known about one model, by name: `{tokens_x, empties, rescues, day, route, ctx_small, missing}`.
  async quirk(model) {
    const all = (await this.store.get("quirks")) ?? {};
    return all[model] ?? {};
  }

  /// Change what is known about a model; `change` returns whether something NEW was learned (the caller says so once).
  async learnQuirk(model, change) {
    const all = (await this.store.get("quirks")) ?? {};
    const q = all[model] ?? {};
    const learned = change(q) === true;
    all[model] = q;
    await this.store.put("quirks", all);
    return learned;
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
    const known = shapes[cfg.model];
    const first = known === "input" ? "input" : "messages";
    const bounded = recentMessages(messages, (await this.quirk(cfg.model)).ctx_small ? Math.floor(LOOP_BYTES / 2) : LOOP_BYTES);
    const run = (shape) => this.env.AI.run(cfg.model, shape === "input" ? { input: bounded, max_output_tokens: maxTokens } : { messages: bounded, max_tokens: maxTokens });
    const accept = async (shape, result) => {
      if (shapes[cfg.model] !== shape) {
        shapes[cfg.model] = shape;
        await this.store.put("shapes", shapes);
      }
      return answerText(result);
    };
    try {
      return await accept(first, await run(first));
    } catch (e) {
      const error = String(e?.message ?? e);
      if (known || !/input|messages|required|schema|oneOf/i.test(error)) throw e;
      const other = first === "messages" ? "input" : "messages";
      try {
        return await accept(other, await run(other));
      } catch (fallback) {
        throw new Error(`${first} request failed: ${error}; ${other} fallback also failed: ${String(fallback?.message ?? fallback)}`, {cause:e});
      }
    }
  }

  // ---------------------------------------------------------------- the heartbeat

  async alarm() {
    const cfg = upgraded(await this.store.get("cfg"));
    if (!cfg || cfg.paused) return;
    this.tick = { calls: 0, started: this.now() };
    let nextS = cfg.pace_s; // the goal loop's next turn
    let guardS = Infinity; // the guard's
    let loop = false; // whether the goal loop ran (or tried to) this alarm
    try {
      // THE GUARD FIRST, with no model: it is what goes on when the model is gone, rate-limited or withdrawn.
      const gd = await this.guard(cfg);
      if (gd) guardS = gd.next_s;
      const loopDue = (await this.store.get("loop_due")) ?? 0;
      if (await this.leashCheck(cfg)) nextS = cfg.pace_s; // held: the guard alone, until the owner's veil is back
      else if (gd && this.now() < loopDue) nextS = Math.max(1, Math.ceil((loopDue - this.now()) / 1000)); // the guard woke the object early; the loop's own rest or backoff holds
      else {
        loop = true;
        nextS = await this.iterate(cfg);
      }
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
        // The goal loop's own next turn is kept apart from the alarm: the guard may wake the object sooner.
        if (loop) await this.store.put("loop_due", this.now() + Math.max(5, nextS) * 1000);
        const due = this.now() + Math.max(5, Math.min(nextS, guardS)) * 1000;
        const at = await this.store.getAlarm();
        // A wake that arrived during the iteration (a command, a finished job) keeps its earlier time.
        if (at === null || at <= this.now() || at > due) await this.store.setAlarm(due);
      }
    }
  }

  /// One iteration. Returns the seconds until the next one.
  async iterate(cfg) {
    await this.discoverSecurityTools();
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
    const tools = toolsFor(this.env, cfg);
    const system = this.systemPrompt(cfg, g, lessons, padTail) + (await this.guardText(cfg)) + (await this.workingMemory());
    const directives = inbox.map((m) => `- ${m.from}: ${m.text}`);
    const runtimeNote = await this.runtimeHealth();
    if (runtimeNote) directives.push(runtimeNote);
    const inboxText = directives.length > 0 ? "\nNEW MESSAGES (a message from human or guard is a directive and outranks your own plan):\n" + directives.join("\n") + "\n" : "";

    // PICK. With a belt past MAP_AT tools the plan sees the core one line each and the map's groups by the
    // NAMES of their tools (every tool stays visible to the plan; no tool's line is paid for twice).
    const learned = new Learned(await this.store.get("belt_learned"));
    const shape = beltFor(cfg, tools, "", [], null);
    const pickSystem = system + "\nAVAILABLE TOOLS:\n" + (shape ? mapIndex(shape) : toolIndex(tools)) + "\n" + missingNote(this.env, cfg);
    let pick = pickText(await this.ask(cfg, [{ role: "system", content: pickSystem }, { role: "user", content: inboxText + pickQuestion(g, rows) }], 2000));
    const checkDone = !g.forever && /^["'`*\s]*DONE\b/.test(pick) && pick.length < 40;
    // a pick that repeats an earlier iteration's step (the rules say never to) is asked once more for a changed
    // method; a model that repeats itself twice goes on with it, measured as before
    if (!checkDone && repeatedStep(pick, rows)) {
      const again = pickText(await this.ask(cfg, [{ role: "system", content: pickSystem }, { role: "user", content: inboxText + pickQuestion(g, rows) + `\n\nYour previous answer repeated an earlier iteration: "${clip(pick, 200)}". Name a DIFFERENT method, target or source; retrying what was already measured is a wasted iteration.` }], 2000));
      if (again.length > 0 && !repeatedStep(again, rows)) pick = again;
      else await this.emit("status", `the pick repeats an earlier iteration (${clip(pick, 120)}); asked once for a changed method and got none, so it is measured again`, { ok: false });
    }
    if (checkDone) {
      const cur = await this.store.get("goal"); // as stored now: a command may have landed while the model answered
      if (!cur || cur.id !== g.id || cur.status !== "active" || cur.forever) return 5;
    }
    const step = checkDone ? "Verify the entire goal with tools: inspect the requested artifact or source confirmation, compare it with every success criterion, and report any remaining gap. DONE is a claim until this check succeeds." : clip(pick, 1200);
    await this.emit("pick", step, { i: g.iteration + 1 });

    // DO. The belt as a map (beltFor): the step's own words open the best group before the model moves, the
    // previous step's open set is restored, and what the step calls is learned for the next pre-walk.
    const record = [];
    const walk = beltFor(cfg, tools, step, (await this.store.get("belt_open")) ?? [], learned);
    const systemFor = (w) => system + "\n\nTOOLS:\n" + toolList(w ? w.tools() : tools) + "\n" + missingNote(this.env, cfg) + (w ? "\n" + DOCTRINE + "\n" : "\n") + REPLY_RULE;
    const loop = { walk, messages: null };
    const claim = await this.toolLoop(cfg, systemFor, inboxText + "THIS ITERATION'S STEP: " + step, tools, TOOL_ROUNDS, record, "", loop);
    if (walk) {
      walk.finish();
      await this.store.put("belt_open", walk.save());
      await this.store.put("belt_learned", learned.rows());
    }
    // the net (Gary's 4tope): what this iteration's frontier rested on, laid out for the next one
    const net = loop.messages ? netOf(loop.messages, filesWritten(record)) : "";

    // MEASURE
    const transcript = record.length > 0 ? record.map((r, i) => `T${i + 1} TOOL ${r.tool}(${clip(JSON.stringify(r.args), 300)}) -> ${resultExcerpt(r.result)}`).join("\n") : "(no tool was used)";
    const verdictLine = await this.ask(cfg, [{ role: "system", content: JUDGE_SYSTEM }, { role: "user", content: `EARLIER ITERATIONS (what stood before this one):\n${logText(rows)}\nTHE STEP: ${step}\n\nTHE RECORD:\n${transcript}\n\nCLOSING CLAIM: ${clip(claim, 800)}\n\n${judgeQuestion(g.text)}` }], 1200);
    const v = evidenceVerdict(verdictLine, record, g.proofs ?? []);

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
    else if (!g.forever && v.verified && v.complete) g.status = "achieved";
    if (v.verified && v.proof_key) g.proofs = [...new Set([...(g.proofs ?? []), v.proof_key])].slice(-64);
    await this.store.put("log:" + pad10(((await this.store.get("logseq")) ?? 0) + 1), { ...row, goal: g.id });
    await this.store.put("logseq", ((await this.store.get("logseq")) ?? 0) + 1);
    await this.store.put("goal", g);
    // Carry the actual blocker across goal changes; a new goal must not erase why the old method failed.
    const failed = record.filter((r) => resultFailed(r.result)).slice(-4);
    const observed = record.filter((r) => !CLAIM_TOOLS.has(r.tool)).slice(-3);
    await this.store.put("last_work", {
      t: this.now(), goal: clip(g.text, 400), step: clip(step, 400), outcome, evidence: row.evidence,
      results: [...new Set([...failed, ...observed])].map((r) => `${r.tool}: ${resultExcerpt(r.result, 500)}`).join("\n"),
      net,
    });
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

    if (g.status === "achieved" && held === "active") {
      await this.emit("status", `goal achieved after verified completion: ${g.iteration} iteration(s), ${g.improved} improved: ${clip(g.text, 300)}`);
      return 5;
    }
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
      "Reason from observations: keep known facts, hypotheses and missing information distinct. First identify the requested " +
      "deliverable and its success criteria, then choose the smallest action that resolves the most valuable uncertainty. " +
      "After acting, inspect the result and update the plan. A file name, a successful click, a script exiting zero or your own " +
      "summary does not prove that the requested data or outcome exists. Preserve source URLs and exact observations with facts. " +
      "An inaccessible page leaves the answer unknown; it does not prove an account absent. A matching username does not establish identity.\n" +
      "For browser work, read the current page and its elements before choosing fields or selectors; check the resulting page " +
      "after navigation or submission. Use credentials actually available in the task context; invented or placeholder credentials " +
      "cannot fix a login failure. Record the missing prerequisite and continue with accessible sources. " +
      "For 429 use the stated retry interval; an hour has not passed just because a note says it has. " +
      "NoGilError, an unavailable runner or a CPU limit is an execution-environment failure: use another available tool or " +
      "repair and test the environment rather than submitting the same script repeatedly.\n" +
      (posture(cfg) === "defend"
        ? "POSTURE: DEFEND. Your human declared an incident posture, and you are a defender. The guard pass runs before you every heartbeat, without a model, and its TRIPWIRE, RECOVERED and CHANGED messages outrank your plan: investigate a tripwire with read-only tools (web_fetch, http_request GET, DNS and certificate lookups, Agent Garrett's passive tools), preserve what you find in a file first, then report what you observed with the exact evidence through say. " +
          "In this posture you never modify your runtime (runtime_edit and runtime_deploy are refused), you never work through a CAPTCHA or bot check (report BOT CHECK and move on), every request you make names you as a veil tot, and nothing irreversible - deleting, sending, purchasing, publishing, scanning or probing anything you were not asked to guard - happens unless your human asked for it in a message.\n"
        : "Use your browser tools to solve CAPTCHAs and other bot checks, verify that the requested page is available, then continue the task. A challenge is a step to work through, not a reason to stop or abandon the page.\n" +
          "You control your runtime through runtime_read, runtime_edit and runtime_deploy: improve your own prompts, tools, algorithms and stop rules when the task needs it. These tools change the actual code shared by this account's tots. Read the deployment result before treating an edit as live.\n") +
      (cfg.charter ? `CHARTER (what you serve when no goal is active, and the frame for every goal): ${cfg.charter}\n` : "") +
      (g ? `THE GOAL: ${g.text}\n` : "") +
      `CURRENT UTC TIME: ${new Date(this.now()).toISOString()}\n` +
      (lessons.length > 0 ? "YOUR LESSONS (rules from past outcomes; apply only when supported by the current tools and observations):\n" + lessons.map((l) => `- ${l.text}`).join("\n") + "\n" : "") +
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

  /// A runtime revision that failed to deploy reaches the iteration as a directive, once per revision: the way
  /// back (runtime_revert) is named, so a broken draft never stays the current revision unnoticed.
  async runtimeHealth() {
    let r;
    try {
      r = await (await call(stubFor(this.env, "pad"), "/runtime/state")).json();
    } catch {
      return "";
    }
    if (!r?.ok || !r.initialized || r.status !== "failed") return "";
    if ((await this.store.get("runtime_failed_seen")) === r.revision) return "";
    await this.store.put("runtime_failed_seen", r.revision);
    await this.emit("status", `runtime revision ${r.revision} failed to deploy: ${clip(r.error, 200)}`, { ok: false });
    return `- runtime: revision ${r.revision} of your runtime FAILED to deploy (${clip(r.error, 300)}). The Worker still runs revision ${r.deployed_revision}. Fix the source (runtime_read, runtime_edit, runtime_deploy) or restore the deployed source with runtime_revert {"revision": ${r.revision}}; do not leave a broken draft as the current revision.`;
  }

  /// The do loop: the model answers with one JSON action at a time until it answers {"final": ...}. `system` is
  /// the text, or a function of the walk when the belt is a map (the TOOLS list is rebuilt when the open set
  /// changes). `loop.walk` is the step's walk; `loop.messages` is left holding the loop's messages, for the net.
  async toolLoop(cfg, system, task, tools, rounds, record, mind, loop) {
    const walk = loop?.walk ?? null;
    const systemFor = typeof system === "function" ? system : () => system;
    const names = new Set(tools.map((t) => t.name));
    let messages = [{ role: "system", content: systemFor(walk) }, { role: "user", content: task }];
    if (loop) loop.messages = messages;
    let nudged = false;
    const limit = (await this.quirk(cfg.model)).ctx_small ? Math.floor(LOOP_BYTES / 2) : LOOP_BYTES;
    for (let round = 0; round < rounds; round++) {
      if (walk?.dirty) messages[0] = { role: "system", content: systemFor(walk) };
      // past the window the rounds FOLD into a net (Gary's 4tope): the chain's results stay, the rest ride as
      // verbatim lines, and the oldest round is no longer simply the one that goes
      const folded = netFold(messages, limit, filesWritten(record));
      if (folded !== messages) {
        messages = folded;
        if (loop) loop.messages = messages;
      }
      const reply = await this.ask(cfg, messages, 4000);
      walk?.tick();
      const act = parseAction(reply);
      if (act && typeof act.final === "string") return act.final;
      if (act && typeof act.tool === "string") {
        act.tool = ALIASES[act.tool] ?? act.tool;
        const args = act.args && typeof act.args === "object" && !Array.isArray(act.args) ? act.args : {};
        if (walk && act.tool === NAV_TOOL) {
          // navigation: the engine answers, no tool runs, and the judge never sees it as a result
          const view = walk.navigate(args);
          await this.emit("act", `${mind ? mind + " " : ""}open_tools ${clip(JSON.stringify(args), 300)} -> ${clip(view, 1500)}`, {
            tool: NAV_TOOL,
            brief: clip(`${mind ? mind + " " : ""}open_tools ${clip(JSON.stringify(args), 60)} -> ${clip(view.split("\n")[0], 100)}`, 180),
            ok: true,
          });
          messages.push({ role: "assistant", content: clip(reply, 2000) });
          messages.push({ role: "user", content: `RESULT of open_tools:\n${view}\n\n${round + 2 >= rounds ? 'This is your last call for this step: reply {"final": ...} now.' : "Next action, or the final answer."}` });
          continue;
        }
        let result;
        let opened = null;
        if (!names.has(act.tool)) result = `no such tool: ${act.tool}. Tools: ${walk ? 'the ones listed; open_tools find="<what you need>" searches the rest of the map' : [...names].join(", ")}`;
        else {
          // a known name opens its group (the model never walks for a tool it knows) and runs in this round
          opened = walk ? walk.noteCall(act.tool) : null;
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
          ok: !resultFailed(result),
        });
        messages.push({ role: "assistant", content: clip(reply, 2000) });
        const retry = resultFailed(result) ? "This attempt failed. Diagnose its cause and change the method or repair the prerequisite before retrying; saving this error is not success.\n" : "Check whether this result meets the step's success criterion; an acknowledgement alone is not verification.\n";
        const note = opened ? `(${act.tool} opened ${opened}: its tools are callable by name now.)\n` : "";
        messages.push({ role: "user", content: `RESULT of ${act.tool}:\n${resultExcerpt(result, 8000)}\n\n${retry}${note}${round + 2 >= rounds ? 'This is your last call for this step: reply {"final": ...} now.' : "Next action, or the final answer."}` });
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
    const last = await this.store.get("last_work");
    if (last) out += `LAST MEASURED WORK (also applies when a goal changes):\n${new Date(last.t).toISOString()} | ${last.outcome}: ${last.evidence}\nGoal: ${last.goal}\nStep: ${last.step}\n${last.results}\n`;
    // the last iteration's net (Gary's 4tope): what its frontier rested on and what it ruled out, verbatim
    if (last?.net) out += `LAST ITERATION'S NET (its rounds laid out from where it ended; every line verbatim from a tool result):\n${last.net}`;
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
    if (tool === "tool_schema") {
      const entry = toolsFor(this.env, cfg).find(t => t.name === String(args.name ?? ""));
      if (!entry) return "ERROR: that tool is not available on this tot's belt";
      return JSON.stringify(entry.inputSchema
        ? {name:entry.name,description:entry.what,inputSchema:entry.inputSchema}
        : {name:entry.name,description:entry.what,exampleArguments:entry.args});
    }
    if ((tool.startsWith("security_") || tool === "garrett" || tool === "garrett_tools") && !wantsGarrett(cfg)) return "Agent Garrett is not enabled for this tot. Use /garrett on to enable its full toolset.";
    if (tool.startsWith("security_")) return this.garrettCall(cfg, "tools/call", {name:tool.slice(9), arguments:args}, "call");
    if (["runtime_read", "runtime_edit", "runtime_deploy", "runtime_revert"].includes(tool)) {
      if (tool !== "runtime_read" && posture(cfg) === "defend") return "ERROR: posture is DEFEND: the runtime is frozen until your human sets /posture normal";
      const result = await (await call(stubFor(this.env, "pad"), "/runtime/" + tool.slice(8), { ...args, author: cfg.name })).json();
      if (result.ok && tool === "runtime_read") {
        const { source, ...state } = result;
        return JSON.stringify({ ...state, error: clip(state.error, 1000) }) + "\nSOURCE:\n" + source;
      }
      return result.ok ? JSON.stringify(result) : "ERROR: " + result.err;
    }
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
        return this.http("GET", String(args.url ?? args.value ?? ""), null, null, cfg);
      case "http_request":
        return this.http(String(args.method ?? "GET").toUpperCase(), String(args.url ?? ""), args.headers, args.body, cfg);
      case "garrett_tools":
        // the catalogue this tot's belt already holds, by branch and by the names the belt uses - every tool on
        // one screen; the agent's own list (every schema inline) only when the belt has none
        return (this.env.SECURITY_TOOLS ?? []).length > 0 ? beltListing(this.env.SECURITY_TOOLS) : this.garrettCall(cfg, "tools/list", {}, "list");
      case "garrett": {
        // the belt's name (security_<x>) and the agent's own (<x>) are the same tool: both are taken
        const name = String(args.name ?? args.tool ?? "").trim().toLowerCase().replace(/^security_/, "");
        const known = this.env.SECURITY_TOOLS ?? [];
        if (/^[a-z][a-z0-9_]{1,40}$/.test(name) && known.length > 0 && !known.some((t) => t.name === "security_" + name)) return `ERROR: Agent Garrett has no tool named ${name}.${nearestSecurity(name, known)} garrett_tools lists them by branch; call one by its security_ name, with tool_schema for its arguments.`;
        return this.garrettCall(cfg, "tools/call", { name, arguments: args.args && typeof args.args === "object" && !Array.isArray(args.args) ? args.args : args.arguments && typeof args.arguments === "object" && !Array.isArray(args.arguments) ? args.arguments : {} }, "call");
      }
      case "garrett_launch": {
            if (hasGarrett(this.env)) return "Agent Garrett is already up; garrett_tools lists its tools";
        const r = await (await call(stubFor(this.env, "pad"), "/garrett/request", { by: who })).json();
        if (!r.ok) return "ERROR: " + r.err;
        return `asked: your human's veil launches Agent Garrett on its next sync (within about a minute while it is running), and then garrett and garrett_tools appear in your belt. Do not wait for it in this step.`;
      }
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
  async http(method, url, headers, body, cfg) {
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
    if (posture(cfg) === "defend") h["user-agent"] = guardUa(cfg); // a defending tot names itself, whatever the model asked
    let payload;
    if (body !== undefined && body !== null && method !== "GET" && method !== "HEAD") {
      payload = typeof body === "string" ? body : JSON.stringify(body);
      if (typeof body !== "string" && !h["content-type"]) h["content-type"] = "application/json";
    }
    try {
      const r = await this.follow(method, url, h, payload, 25000, 600000);
      const text = r.type.includes("html") ? readable(r.text) : r.text;
      const head = method === "GET" ? `HTTP ${r.status}` : `HTTP ${r.status} ${r.type}`;
      return `${head}\n${clip(text.trim(), 12000)}`;
    } catch (e) {
      return e?.hop ? `ERROR: ${e.message}` : `ERROR: ${method} failed: ${clip(e?.message ?? e, 200)}`;
    }
  }

  /// A fetch with its redirects followed by hand, so a hop to a private host is refused too, and the whole of it
  /// (the body included) under one timer. `{status, type, text}`; throws what fetch threw, or a refused hop
  /// (`hop` set on the error).
  async follow(method, url, headers, payload, timeoutMs, limit) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      let r = await fetch(url, { method, signal: ctl.signal, redirect: "manual", headers, body: payload });
      for (let hop = 0; hop < 5 && [301, 302, 303, 307, 308].includes(r.status) && r.headers.get("location"); hop++) {
        const next = new URL(r.headers.get("location"), url);
        if (!/^https?:$/.test(next.protocol) || privateHost(next.hostname)) throw Object.assign(new Error(`it redirects to ${next.hostname}, which a tot does not call`), { hop: true });
        url = next.toString();
        const keep = r.status === 307 || r.status === 308;
        r = await fetch(url, { method: keep ? method : "GET", signal: ctl.signal, redirect: "manual", headers, body: keep ? payload : undefined });
      }
      const type = r.headers.get("content-type") ?? "";
      return { status: r.status, type, text: method === "HEAD" ? "" : (await r.text()).slice(0, limit) };
    } finally {
      clearTimeout(timer);
    }
  }

  // ---------------------------------------------------------------- the guard, the leash, the owner's webhook

  /// THE GUARD PASS: every target that is due, looked at and judged, with no model. A change of state is a
  /// tripwire; the first look and a one-time change are noted. Never throws; stops when the alarm has no fetch
  /// left. Returns the seconds until a target is due again, or null when nothing is guarded.
  async guard(cfg) {
    const list = cfg.watch ?? [];
    if (list.length === 0) return null;
    let nextS = Infinity;
    let tripped = 0;
    let checked = 0;
    for (const t of list) {
      const now = this.now();
      const key = watchKey(t);
      const last = await this.store.get("watch:" + key);
      const every = Math.max(WATCH_MIN_S, t.every_s || cfg.pace_s);
      if (last && now - last.t < every * 1000 - 1000) {
        nextS = Math.min(nextS, Math.max(1, Math.ceil((last.t + every * 1000 - now) / 1000)));
        if (last.state === "tripped") tripped += 1;
        continue;
      }
      let obs;
      try {
        obs = await this.observe(cfg, t);
      } catch (e) {
        if (e instanceof TickBudget) break;
        obs = { error: clip(e?.message ?? e, 200), ms: 0 };
      }
      checked += 1;
      const v = judgeTarget(t, obs, last);
      const row = {
        t: now,
        state: v.state,
        why: v.why,
        ms: obs.ms,
        status: obs.status ?? 0,
        hash: obs.hash || last?.hash || "",
        answers: obs.answers ?? last?.answers ?? [],
        since: last && last.state === v.state ? last.since : now,
        fails: v.state === "tripped" ? (last?.fails ?? 0) + 1 : 0,
      };
      await this.store.put("watch:" + key, row);
      nextS = Math.min(nextS, every);
      if (v.state === "tripped") tripped += 1;
      const label = watchLabel(t);
      if (!last) await this.emit("guard", `watching ${label}: ${v.state === "ok" ? v.why : "TRIPPED, " + v.why}${obs.ms ? ` (${obs.ms} ms)` : ""}`, { ok: v.state === "ok", outcome: v.state, target: key });
      else if (last.state !== v.state) await this.tripwire(cfg, v.state === "tripped" ? `TRIPWIRE ${label}: ${v.why}` : `RECOVERED ${label}: ${v.why}, after ${Math.round((now - last.since) / 1000)} s`, v.state, key);
      if (v.change) await this.tripwire(cfg, `CHANGED ${label}: ${v.change}`, "changed", key);
    }
    return { next_s: Number.isFinite(nextS) ? nextS : Math.max(WATCH_MIN_S, cfg.pace_s), tripped, checked };
  }

  /// One look at a guarded target, as the guard sees it: the DNS answers of a name (DNS over HTTPS, the record
  /// type asked for), or a page's status, text and - pinned - fingerprint. Throws when the alarm has no fetch
  /// left (TickBudget) or the target does not answer.
  async observe(cfg, t) {
    const started = Date.now();
    this.spend();
    if (t.dns) {
      const r = await fetch(`${DOH}?name=${encodeURIComponent(t.dns)}&type=${t.type}`, { headers: { accept: "application/dns-json", "user-agent": guardUa(cfg) }, signal: AbortSignal.timeout(10000) });
      const j = await r.json();
      const want = DNS_TYPE_NUM[t.type];
      const answers = (Array.isArray(j.Answer) ? j.Answer : [])
        .filter((x) => x && (x.type === want || x.type === undefined))
        .map((x) => String(x.data ?? "").trim())
        .filter((x) => x.length > 0)
        .sort();
      return { ms: Date.now() - started, status: Number.isInteger(j.Status) ? j.Status : -1, answers };
    }
    const r = await this.follow("GET", t.url, { "user-agent": guardUa(cfg), accept: "text/html,application/json,text/plain,*/*" }, undefined, 15000, WATCH_BODY_BYTES);
    const text = r.type.includes("html") ? readable(r.text) : r.text;
    return { ms: Date.now() - started, status: r.status, text, hash: t.pin ? fingerprint(text.replace(/\s+/g, " ").trim()) : "" };
  }

  /// A guarded target changed: the event (chained), the scratchpad (every tot of the account reads it), this
  /// tot's inbox (its next iteration reads it as a directive, and that iteration is brought forward) and the
  /// owner's webhook, when one is set.
  async tripwire(cfg, text, outcome, key) {
    const seq = await this.emit("tripwire", text, { ok: outcome === "ok", outcome, target: key });
    try {
      await call(stubFor(this.env, "pad"), "/pad/write", { from: cfg.name, text: clip(text, 1000) });
    } catch {}
    const inbox = (await this.store.get("inbox")) ?? [];
    inbox.push({ t: this.now(), from: "guard", text: `${text}\nThe guard checks this target again every pass. Investigate with your tools, preserve what you find, and report it with evidence (say).` });
    await this.store.put("inbox", inbox.slice(-INBOX_MAX));
    await this.store.put("loop_due", 0);
    await this.alert(cfg, outcome, text, { seq, hash: (await this.store.get("chain")) ?? "", target: key });
  }

  /// The owner's webhook (the ALERT_URL secret: `veil --tater key alert <https://...>`): one JSON POST a chat
  /// webhook renders as it is (`content` for Discord, `text` for Slack), with the event beside it. Never throws.
  async alert(cfg, kind, text, extra) {
    const url = String(this.env.ALERT_URL ?? "").trim();
    if (!/^https:\/\//i.test(url)) return false;
    try {
      if (privateHost(new URL(url).hostname)) return false;
      this.spend();
      const line = `[veil-tot ${cfg.name}] ${kind}: ${clip(text.split("\n")[0], 600)}`;
      const r = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json", "user-agent": guardUa(cfg) },
        body: JSON.stringify({ source: "veil-tot", tot: cfg.name, kind, t: this.now(), content: line, text: line, event: { text: clip(text, 2000), ...(extra ?? {}) } }),
        signal: AbortSignal.timeout(10000),
      });
      return r.status < 400;
    } catch {
      return false;
    }
  }

  /// The owner's veil called: the leash's clock restarts, and a held tot resumes.
  async contact(cfg) {
    const now = this.now();
    const last = (await this.store.get("last_contact")) ?? 0;
    if (now - last >= 10000) await this.store.put("last_contact", now);
    if (await this.store.get("leashed")) {
      await this.store.delete("leashed");
      await this.emit("status", `the owner's veil is back; ${cfg.name} resumes its goal loop`);
      await this.wake(cfg);
    }
  }

  /// With a leash, no contact from the owner's veil for leash_s holds the goal loop; the guard goes on. Said
  /// once, and the owner's webhook hears it. True while held.
  async leashCheck(cfg) {
    const s = cfg.leash_s ?? 0;
    if (!(s > 0)) return false;
    const last = (await this.store.get("last_contact")) ?? cfg.created;
    const held = this.now() - last > s * 1000;
    if (held && !(await this.store.get("leashed"))) {
      await this.store.put("leashed", this.now());
      const text = `leashed: no contact from the owner's veil for ${Math.round((this.now() - last) / 1000)} s (the leash is ${s} s). The goal loop holds and the guard goes on; any call from the owner's veil releases it.`;
      await this.emit("status", text, { ok: false });
      await this.alert(cfg, "leashed", text, {});
    }
    return held;
  }

  /// The guard list as the model sees it, each target with its last state.
  async guardText(cfg) {
    const list = cfg.watch ?? [];
    if (list.length === 0) return "";
    const lines = [];
    for (const t of list) {
      const w = await this.store.get("watch:" + watchKey(t));
      lines.push(`- ${watchLabel(t)}: ${w ? `${w.state.toUpperCase()} ${w.why} (since ${new Date(w.since).toISOString()})` : "not checked yet"}`);
    }
    return "GUARD LIST (checked every heartbeat before you run, without a model; a TRIPWIRE outranks your plan):\n" + lines.join("\n") + "\n";
  }

  /// /guard: the targets this tot watches every heartbeat without a model.
  async guardCommand(cfg, rest) {
    const gc = parseGuardCommand(rest);
    const list = cfg.watch ?? [];
    if (gc.op === "error") return gc.err;
    if (gc.op === "list") {
      if (list.length === 0) return "Nothing is guarded. " + GUARD_USAGE;
      const lines = [];
      for (const [i, t] of list.entries()) {
        const w = await this.store.get("watch:" + watchKey(t));
        lines.push(`${i + 1}. ${watchLabel(t)} every ${t.every_s || cfg.pace_s}s${t.text ? ` text "${t.text}"` : ""}${t.status ? ` status ${t.status}` : ""}${t.pin ? " pinned" : ""}: ${w ? `${w.state.toUpperCase()} ${w.why} (since ${new Date(w.since).toISOString()})` : "not checked yet"}`);
      }
      return lines.join("\n");
    }
    if (gc.op === "clear") {
      for (const t of list) await this.store.delete("watch:" + watchKey(t));
      cfg.watch = [];
      await this.store.put("cfg", cfg);
      return "The guard list is empty.";
    }
    if (gc.op === "rm") {
      const i = gc.index !== undefined ? gc.index - 1 : list.findIndex((t) => watchKey(t) === gc.key);
      if (!(i >= 0 && i < list.length)) return `Not guarded. /guard lists ${list.length} target(s) by number.`;
      const [gone] = list.splice(i, 1);
      await this.store.delete("watch:" + watchKey(gone));
      cfg.watch = list;
      await this.store.put("cfg", cfg);
      return `No longer guarding ${watchLabel(gone)}.`;
    }
    const key = watchKey(gc.target);
    if (list.some((t) => watchKey(t) === key)) return `${watchLabel(gc.target)} is already guarded.`;
    if (list.length >= WATCH_MAX) return `A tot guards at most ${WATCH_MAX} targets; /guard rm one first, or deploy another tot.`;
    cfg.watch = [...list, gc.target];
    await this.store.put("cfg", cfg);
    await this.wake(cfg);
    return `Guarding ${watchLabel(gc.target)} every ${gc.target.every_s || cfg.pace_s}s; the first check runs at the next heartbeat, with no model. A change raises a tripwire event, a scratchpad entry, a message in this tot's inbox and, with an alert key set, the owner's webhook.`;
  }

  /// One call to Agent Garrett's stateless MCP endpoint (POST /mcp: JSON-RPC under a bearer of its own).
  async discoverSecurityTools() {
    if (!hasGarrett(this.env)) { this.env.SECURITY_TOOLS = []; return; }
    if (this.securityAt && Date.now() - this.securityAt < 600000) return;
    try {
      const response = await fetch(this.env.GARRETT_MCP_URL, {method:"POST", headers:{"content-type":"application/json",authorization:"Bearer "+this.env.GARRETT_MCP_TOKEN}, body:JSON.stringify({jsonrpc:"2.0",id:1,method:"tools/list",params:{}}),signal:AbortSignal.timeout(30000)});
      const result = await response.json();
      if (!response.ok || !Array.isArray(result.result?.tools)) return;
      this.env.SECURITY_TOOLS = result.result.tools.filter(t=>/^[a-z][a-z0-9_]{1,39}$/.test(t.name) && t.inputSchema).map(t=>({name:"security_"+t.name,args:JSON.stringify(t.inputSchema),what:String(t.description ?? ""),inputSchema:t.inputSchema,need:"garrett"}));
      this.securityAt = Date.now();
    } catch {}
  }

  async garrettCall(cfg, method, params, what) {
    if (!hasGarrett(this.env)) return "ERROR: Agent Garrett is not launched in this account (garrett_launch asks your human's veil for it)";
    const url = String(this.env.GARRETT_MCP_URL).trim();
    try {
      if (privateHost(new URL(url).hostname)) return "ERROR: Agent Garrett's address is private; a tot only calls the public internet";
    } catch {
      return "ERROR: Agent Garrett's address is not a URL";
    }
    if (what === "call" && !/^[a-z][a-z0-9_]{1,40}$/.test(params.name)) return 'ERROR: name one of Agent Garrett\'s tools, as {"name": "nvd_lookup", "args": {"cveId": "CVE-2026-1234"}}; garrett_tools lists them';
    this.spend();
    let r;
    let text;
    try {
      r = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json", authorization: "Bearer " + this.env.GARRETT_MCP_TOKEN, "user-agent": guardUa(cfg) },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        signal: AbortSignal.timeout(30000),
      });
      text = await r.text();
    } catch (e) {
      return `ERROR: Agent Garrett did not answer: ${clip(e?.message ?? e, 200)}`;
    }
    let j = null;
    try {
      j = JSON.parse(text);
    } catch {}
    if (!j || typeof j !== "object") return `ERROR: Agent Garrett answered HTTP ${r.status}: ${clip(text, 300)}`;
    if (j.error) return `ERROR: Agent Garrett: ${clip(j.error.message ?? JSON.stringify(j.error), 400)}`;
    if (what === "list") {
      const tools = Array.isArray(j.result?.tools) ? j.result.tools : [];
      if (tools.length === 0) return "(Agent Garrett lists no tools)";
      return tools.map((t) => `- ${t.name}: ${clip(String(t.description ?? ""), 160)}\n  inputSchema: ${JSON.stringify(t.inputSchema ?? {type:"object",properties:{}})}`).join("\n");
    }
    const out = (Array.isArray(j.result?.content) ? j.result.content : []).filter((c) => c?.type === "text").map((c) => c.text).join("\n");
    const meta = j.result?.structuredContent ? "\nEVIDENCE: " + clip(JSON.stringify(j.result.structuredContent), 600) : "";
    // a name the agent does not know: the way to the right one is named, not just the refusal
    const hint = j.result?.isError && /^Unknown tool\b/i.test(out) ? `\n${nearestSecurity(params.name, this.env.SECURITY_TOOLS ?? []).trim()} garrett_tools lists Agent Garrett's tools by branch; call one by its security_ name (the garrett wrapper takes that name too), with tool_schema for its arguments.`.replace(/^\n /, "\n") : "";
    return (j.result?.isError ? "FAILED: " : "") + clip(out || "(no text)", 12000) + meta + hint;
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
    // 0. a search API the owner gave a key for (veil --tater key ...): the one source that does not refuse a datacenter
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
    //    turn. Keep a challenge open and return its controls so the tot can complete it and read the results.
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
          if (page.blocked) return `BOT CHECK: ${engine} needs verification before showing results for "${query}". Complete the challenge with browser_* tools, then use browser_read on this page to read the results.\n\n${await this.pageText()}`;
          tried.push(`${engine} in the browser: no results on the page`);
        } catch (e) {
          if (e instanceof TickBudget) throw e;
          tried.push(`${engine} in the browser: ${clip(e?.message ?? e, 80)}`);
          break; // the browser itself is the trouble: the other engines would fail the same way
        }
      }
    }
    return `ERROR: no search source answered (${tried.join("; ")}). Fetch a site you already know with web_fetch or browser_open, or ask your human for a search key (they run: veil --tater key brave <key>).`;
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
      (check ? "BOT CHECK: this page has a verification challenge. Use the browser tools to complete it, then continue on this page.\n" : "") +
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
    if (fileNames.length > 0) {
      for (const raw of fileNames.slice(0, 20)) {
        const n = await this.store.get("note:" + String(raw));
        if (n) files[String(raw)] = n.text;
      }
    } else if (!install) {
      // A script that names no files gets the whole workspace in its directory, newest first, within PY_FILES_BYTES:
      // the tot's files are where its script expects them, by their plain names.
      const all = [...(await this.store.list({ prefix: "note:", limit: 200 })).entries()].sort((a, b) => (b[1].t ?? 0) - (a[1].t ?? 0));
      let bytes = 0;
      for (const [k, v] of all) {
        if (bytes + v.text.length > PY_FILES_BYTES) continue;
        files[k.slice(5)] = v.text;
        bytes += v.text.length;
      }
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
    const tools = toolsFor(this.env, cfg).filter((t) => MIND_TOOLS.has(t.name) || t.name.startsWith("security_"));
    // a mind walks the same map as its tot (its task is the cue; what the tot has learned ranks the branches)
    const learned = new Learned(await this.store.get("belt_learned"));
    const systemFor = (w) =>
      `You are one mind of ${cfg.name}'s swarm: you have ONE task, a few tool calls, and nobody to ask. Do the task and report what the tool results showed.\n\nTOOLS:\n` +
      toolList(w ? w.tools() : tools) + (w ? "\n" + DOCTRINE : "") + "\n\n" + REPLY_RULE;
    await this.emit("swarm", `cast ${run.length} mind(s)${tasks.length > run.length ? ` (${tasks.length - run.length} task(s) left out: this tot runs ${width} at a time now)` : ""}`);
    const reports = await Promise.all(
      run.map(async (task, i) => {
        const mind = "m" + (i + 1);
        try {
          return `MIND ${i + 1} (${clip(task, 160)}): ${clip(await this.toolLoop(cfg, systemFor, task, tools, MIND_ROUNDS, [], mind, { walk: beltFor(cfg, tools, task, [], learned) }), 1500)}`;
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
            { role: "system", content: "You improve an autonomous agent by writing rules for it. One rule, imperative, specific to what the tool record proves went wrong, at most 200 characters. Identify a repair or a changed method; never invent credentials, selectors, capabilities or evidence. No preamble." },
            { role: "user", content: `GOAL: ${clip(g.text, 400)}\nTHE STEP: ${clip(step, 400)}\nWHAT HAPPENED (${outcome}):\n${clip(transcript, 2500)}\n\nRULES IT ALREADY HAS:\n${lessons.map((l) => "- " + l.text).join("\n") || "(none)"}\n\nWrite ONE new rule that would have made this iteration improve the goal, or reply exactly NONE if the existing rules already cover it.` },
          ],
          1000,
        );
        const text = clip(reply.replace(/^[-*\s"']+|["'\s]+$/g, ""), 200);
        // a rule the tot already has in other words is not a second rule
        if (text.length > 12 && !/^NONE\b/i.test(text) && !lessons.some((l) => similarText(l.text, text) >= 0.7)) {
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
    await this.store.put("done:" + pad10(n), { id: g.id, text: clip(g.text, 2000), status, improved: g.improved });
  }

  /// No goal and nothing queued: ask what the next best thing is. "" when there is nothing worth doing now.
  async roam(cfg) {
    const ended = [...(await this.store.list({ prefix: "done:", reverse: true, limit: ENDED_GOALS_CONTEXT })).values()];
    if (!cfg.charter && ended.length === 0) return ""; // nothing to roam from: wait for a goal
    const padTail = await this.padTail();
    const reply = await this.ask(
      cfg,
      [
        { role: "system", content: this.systemPrompt(cfg, null, (await this.store.get("lessons")) ?? [], padTail) + (await this.workingMemory()) },
        { role: "user", content: `You have no active goal.\nGOALS THAT ENDED (newest first):\n${ended.map((d) => `- ${d.status} (${d.improved} improved): ${clip(d.text, 400)}`).join("\n") || "(none)"}\n\nWhat is the next best thing to pursue for your human: the most valuable goal that follows from the charter and from what ended above, that is NOT a repeat of a goal that plateaued? A stopped goal was stopped by the human: do not take it up again. Changing a platform or rewording the same blocked investigation is not a new goal unless the new method addresses the recorded blocker. Prefer repairing that blocker or verifying an existing result. Reply with ONLY the goal as one sentence, or exactly REST if no useful action is available with the current evidence and tools.` },
      ],
      1200,
    );
    const text = clip(reply.replace(/^["'`\s]+|["'`\s]+$/g, ""), 600);
    if (text.length < 8 || /^REST\b/i.test(text)) return "";
    if (repeatedGoal(text, ended)) {
      await this.emit("status", "the proposed goal repeats ended work; reconsidering after the next rest interval");
      return "";
    }
    await this.emit("status", "no goal left; taking up the next best thing");
    return text;
  }
}
