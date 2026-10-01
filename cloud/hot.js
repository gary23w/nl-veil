// hot.js — the HOT runtime (Human Overview Technician): the veil's goal loop, living in the user's own
// Cloudflare account and running with no human in it.
//
// WHAT: one Worker script ("veil-hots") the veil server uploads through the user's Cloudflare login
// (src/config/cf_hot.zig embeds this file). Each hot is one Durable Object: its goal, its iteration log, its
// lessons, its notes and its event tail live in that object's storage, and an ALARM is its heartbeat - every
// alarm runs ONE iteration of the same loop src/worker/chat/goal.zig runs in a chat turn:
//
//     pick -> do -> measure -> record        (then: learn, and set the next alarm)
//
// The model is reached through the account's own AI binding (env.AI): the call never crosses the public
// internet and needs no API key. A hot is never asked anything and never waits for anyone: commands from the
// human land in an inbox the next iteration reads, and a goal that ends (achieved / plateau / budget) hands
// over to the next queued goal, or to one the hot proposes for itself from its charter.
//
// ONE MORE OBJECT of the same class, named "pad", holds what the hots share: the roster (at most MAX_HOTS)
// and the conjoined scratchpad every hot reads at the start of an iteration and may write to.
//
// THE OWNER'S MACHINE: a hot deployed with `local: true` gets one more tool, local_run. It only QUEUES a job;
// the veil server on the owner's machine polls for jobs (outbound only - nothing listens at home), runs each
// as an unattended chat turn with the full local tool surface, and posts the result back to the inbox.
//
// THE LOCAL FOLDER: the veil server mirrors each hot into {data}/u<uid>/_hots/<name>-<deployed at>/ (events,
// status, notes) and the shared scratchpad beside them. Counters here (seq, notes_rev, the pad's seq) let it
// ask only for what changed.
//
// Every route needs `Authorization: Bearer <HOT_TOKEN>` (a secret binding the veil server generates at deploy).
//
// No imports and no platform globals beyond fetch/Response/crypto, so cloud/hot.test.mjs runs the whole file
// under node with a Map for storage and a scripted model.

export const VERSION = "1";
export const MAX_HOTS = 3;
export const PRIMARY = "Gary"; // the first hot of every account

// The goal loop's stop rules. Same numbers as src/worker/chat/goal.zig (cf_hot.zig has a test that compares them).
export const PLATEAU = 3;
export const BUDGET_DEFAULT = 25;

const SIZE_MAX = 8; // minds one hot may run side by side
const TOOL_ROUNDS = 8; // model calls one iteration's "do" may spend
const MIND_ROUNDS = 3; // model calls one mind of an inner swarm may spend
const TICK_CALLS_MAX = 44; // model calls + fetches one alarm may make (a Worker invocation has a subrequest ceiling)
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
  daily_calls: 400, // model calls per UTC day; the hot rests when they are spent
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
const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);
const clampInt = (v, lo, hi, dflt) => {
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : dflt;
};

/// A hot's name: 1-24 of [A-Za-z0-9_-], starting with a letter. It becomes a URL segment and an object name.
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

/// The text of a model answer, whatever envelope the model's family uses, with any reasoning block removed.
export function answerText(r) {
  let t = "";
  if (typeof r === "string") t = r;
  else if (r && typeof r === "object") {
    if (typeof r.response === "string") t = r.response;
    else if (r.response && typeof r.response === "object") t = JSON.stringify(r.response);
    else if (r.choices?.[0]?.message) {
      const c = r.choices[0].message.content;
      t = typeof c === "string" ? c : Array.isArray(c) ? c.map((p) => p?.text ?? "").join("") : "";
    } else if (typeof r.output_text === "string") t = r.output_text;
    else if (Array.isArray(r.output)) {
      t = r.output
        .filter((o) => o?.type === "message")
        .flatMap((o) => (Array.isArray(o.content) ? o.content : []))
        .map((p) => p?.text ?? "")
        .join("");
    } else if (typeof r.result?.response === "string") t = r.result.response;
  }
  return t.replace(/<think>[\s\S]*?<\/think>/gi, "").trim();
}

// ------------------------------------------------------------------------------------------ the goal rules
// A port of src/worker/chat/goal.zig: the same grammar, the same verdict line, the same arithmetic.

export function newGoal(text, forever, budget, now, id = 0) {
  return {
    id, // which goal this is: a hot's goals are numbered, so two set in the same millisecond still differ
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
  "its effect is SAME. A new failure or a worse measurement is REGRESSED.";

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
    "Prefer a step whose effect a tool can show. A CLAIM OF WORK IS NOT WORK. " +
    tail
  );
}

// ------------------------------------------------------------------------------------------ the tool surface

const TOOLS = [
  { name: "note_write", args: '{"name": "<file name>", "text": "<content>"}', what: "save or replace a note in your own workspace (it lasts across iterations)" },
  { name: "note_read", args: '{"name": "<file name>"}', what: "read one of your notes" },
  { name: "note_list", args: "{}", what: "list your notes with sizes" },
  { name: "note_delete", args: '{"name": "<file name>"}', what: "delete a note" },
  { name: "pad_read", args: "{}", what: "read the scratchpad every hot of this account shares" },
  { name: "pad_write", args: '{"text": "<entry>"}', what: "add an entry to the shared scratchpad (findings other hots can use, claims of work, requests)" },
  { name: "tell", args: '{"hot": "<name>", "text": "<message>"}', what: "send a message to another hot's inbox" },
  { name: "web_fetch", args: '{"url": "https://..."}', what: "fetch a public page or API and read its text" },
  { name: "swarm", args: '{"tasks": ["<task for mind 1>", "<task for mind 2>"]}', what: "run several minds side by side, one task each, and get every report back (use it for work that splits into independent parts)" },
  { name: "goal_queue", args: '{"text": "<a goal>"}', what: "queue a follow-on goal for after the current one ends" },
  { name: "say", args: '{"text": "<message>"}', what: "report to the human (they read it later; never ask them a question and wait)" },
];
const LOCAL_TOOL = {
  name: "local_run",
  args: '{"instruction": "<what to do there>"}',
  what: "queue a job for the veil on the owner's own machine (files, shell, builds, a swarm there); the result arrives in your inbox on a later iteration",
};
const MIND_TOOLS = new Set(["note_write", "note_read", "note_list", "pad_read", "pad_write", "web_fetch"]);

function toolList(tools) {
  return tools.map((t) => `- ${t.name} ${t.args} : ${t.what}`).join("\n");
}

const REPLY_RULE =
  'Reply with exactly ONE JSON object and nothing else. To use a tool: {"tool": "<name>", "args": {...}}. ' +
  'When the step is finished (or cannot go further): {"final": "<what was done and what the tool results showed>"}.';

// ------------------------------------------------------------------------------------------ the Worker (router)

export default {
  async fetch(req, env) {
    try {
      return await route(req, env);
    } catch (e) {
      return bad(`hot runtime error: ${clip(e?.message ?? e, 300)}`, 500);
    }
  },
};

function stubFor(env, key) {
  return env.HOT.get(env.HOT.idFromName(key));
}
const hotKey = (name) => "hot:" + name.toLowerCase();
const call = (stub, path, body) =>
  stub.fetch("https://hot" + path, body === undefined ? undefined : { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });

async function route(req, env) {
  const url = new URL(req.url);
  const auth = req.headers.get("authorization") ?? "";
  if (!sameToken(auth.startsWith("Bearer ") ? auth.slice(7) : "", env.HOT_TOKEN ?? "")) return bad("unauthorized", 401);
  const seg = url.pathname.split("/").filter(Boolean); // ["v1", ...]
  if (seg[0] !== "v1") return bad("not found", 404);
  const method = req.method.toUpperCase();
  const body = method === "POST" ? await req.json().catch(() => null) : null;
  if (method === "POST" && (body === null || typeof body !== "object")) return bad("malformed JSON body");
  const padStub = stubFor(env, "pad");

  if (seg[1] === "version" && method === "GET") return json({ ok: true, version: VERSION, max_hots: MAX_HOTS });

  if (seg[1] === "pad") {
    if (seg[2] === "clear" && method === "POST") return call(padStub, "/pad/clear", {});
    if (method === "GET") return call(padStub, "/pad/read?after=" + encodeURIComponent(url.searchParams.get("after") ?? "0"));
    if (method === "POST") return call(padStub, "/pad/write", { from: "human", text: body.text });
    return bad("method not allowed", 405);
  }

  if (seg[1] === "hots" && seg.length === 2) {
    if (method === "GET") {
      const roster = await (await call(padStub, "/pad/roster")).json();
      const hots = await Promise.all(
        (roster.hots ?? []).map(async (h) => {
          const st = await (await call(stubFor(env, hotKey(h.name)), "/status")).json().catch(() => null);
          return st?.ok ? st.hot : { name: h.name, state: "unreachable" };
        }),
      );
      return json({ ok: true, version: VERSION, max_hots: MAX_HOTS, pad_seq: roster.pad_seq ?? 0, hots });
    }
    if (method === "POST") {
      const claim = await (await call(padStub, "/pad/claim", { name: body.name })).json();
      if (!claim.ok) return bad(claim.err, 409);
      const made = await call(stubFor(env, hotKey(claim.name)), "/init", { ...body, name: claim.name });
      if (made.status !== 200) await call(padStub, "/pad/release", { name: claim.name });
      return made;
    }
    return bad("method not allowed", 405);
  }

  if (seg[1] === "hots" && seg.length >= 3) {
    const name = decodeURIComponent(seg[2]);
    if (!validName(name)) return bad("bad hot name");
    const roster = await (await call(padStub, "/pad/roster")).json();
    const known = (roster.hots ?? []).find((h) => h.name.toLowerCase() === name.toLowerCase());
    if (!known) return bad("no such hot", 404);
    const stub = stubFor(env, hotKey(known.name));
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
    if (op === "jobs" && seg.length === 4 && method === "GET") return call(stub, "/jobs");
    if (op === "jobs" && seg.length === 5 && method === "POST") return call(stub, "/jobs/" + encodeURIComponent(seg[4]), body);
    return bad("not found", 404);
  }
  return bad("not found", 404);
}

// ------------------------------------------------------------------------------------------ the Durable Object

class TickBudget extends Error {}

export class Hot {
  constructor(state, env) {
    this.state = state;
    this.store = state.storage;
    this.env = env;
    this.now = () => Date.now(); // a test replaces it
    this.tick = null; // per-alarm counters
  }

  // ---------------------------------------------------------------- requests from the Worker (already authorized)

  async fetch(req) {
    const url = new URL(req.url);
    const p = url.pathname;
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    if (p.startsWith("/pad/")) return this.padRoute(p, url, body);
    if (p === "/init") return this.init(body);
    const cfg = await this.store.get("cfg");
    if (!cfg) return bad("no such hot", 404);
    if (p === "/status") return json({ ok: true, hot: await this.status(cfg) });
    if (p === "/events") return this.events(url);
    if (p === "/notes") return this.notesSince(url);
    if (p === "/command") return this.command(cfg, body);
    if (p === "/config") return this.configure(cfg, body);
    if (p === "/inbox") return this.inboxPush(cfg, body);
    if (p === "/jobs") return this.jobsPending(cfg);
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
    if (p === "/pad/roster") return json({ ok: true, hots: roster, pad_seq: (await this.store.get("padseq")) ?? 0 });
    if (p === "/pad/claim") {
      // The first hot of an account is always the primary; a later one brings its own name.
      const name = roster.length === 0 ? PRIMARY : body.name;
      if (!validName(name)) return bad("a hot's name is 1-24 letters, digits, - or _, starting with a letter");
      if (roster.some((h) => h.name.toLowerCase() === name.toLowerCase())) return bad(`a hot named ${name} already exists`);
      if (roster.length >= MAX_HOTS) return bad(`this account already has ${MAX_HOTS} hots (the limit); delete one first`);
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
    return json({ ok: true, hot: await this.status(cfg) });
  }

  /// The settings a human may change at any time. `local` is not among them.
  applyConfig(cfg, b) {
    if (typeof b.model === "string" && b.model.trim().length > 0) cfg.model = b.model.trim().slice(0, 120);
    if (b.pace_s !== undefined) cfg.pace_s = clampInt(b.pace_s, 30, 86400, cfg.pace_s);
    if (b.size !== undefined) {
      cfg.size = clampInt(b.size, 1, SIZE_MAX, cfg.size);
      cfg.minds = Math.min(cfg.minds, cfg.size);
    }
    if (b.daily_calls !== undefined) cfg.daily_calls = clampInt(b.daily_calls, 10, 100000, cfg.daily_calls);
    if (b.text_max !== undefined) cfg.text_max = clampInt(b.text_max, 500, 16000, cfg.text_max);
    if (typeof b.charter === "string") cfg.charter = clip(b.charter.trim(), cfg.text_max ?? DEFAULTS.text_max);
    if (typeof b.paused === "boolean") cfg.paused = b.paused;
  }

  async configure(cfg, body) {
    const wasPaused = cfg.paused;
    this.applyConfig(cfg, body);
    await this.store.put("cfg", cfg);
    await this.emit("status", `settings changed: model ${cfg.model}, every ${cfg.pace_s}s, up to ${cfg.size} minds, ${cfg.daily_calls} model calls a day${cfg.paused ? ", paused" : ""}`);
    if (cfg.paused) await this.store.deleteAlarm();
    else if (wasPaused || (await this.store.getAlarm()) === null) await this.store.setAlarm(this.now() + 1000);
    return json({ ok: true, hot: await this.status(cfg) });
  }

  async status(cfg) {
    const goal = (await this.store.get("goal")) ?? null;
    const usage = await this.usage();
    const alarm = await this.store.getAlarm();
    const queue = (await this.store.get("queue")) ?? [];
    const lessons = (await this.store.get("lessons")) ?? [];
    let state = "working";
    if (cfg.paused) state = "paused";
    else if (usage.calls >= cfg.daily_calls) state = "resting";
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
    await this.store.put("ev:" + pad10(seq), { seq, t: this.now(), kind, text: clip(text, 4000), ...(extra ?? {}) });
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

  /// Bring the next iteration forward (a message arrived, a job finished). A paused hot stays paused.
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
    return json({ ok: true, reply, hot: await this.status(cfg) });
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
      return cfg.charter.length > 0 ? "Charter set: it is what this hot works toward when no goal is active." : "Charter cleared.";
    }
    if (word === "/pace" || word === "/size" || word === "/model" || word === "/calls") {
      const key = { "/pace": "pace_s", "/size": "size", "/model": "model", "/calls": "daily_calls" }[word];
      this.applyConfig(cfg, { [key]: rest });
      await this.store.put("cfg", cfg);
      return `model ${cfg.model}, every ${cfg.pace_s}s, up to ${cfg.size} minds, ${cfg.daily_calls} model calls a day.`;
    }
    if (word === "/status") return goalStatusText(g);
    if (word.startsWith("/")) return "Commands: /goal <text> [--forever] [--budget N], /goal stop|resume|status|budget N|forever, /queue <goal>, /charter <text>, /pause, /resume, /pace <seconds>, /size <minds>, /model <id>, /calls <per day>. Anything else is a message this hot reads at its next iteration.";
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
  async ask(cfg, messages, maxTokens) {
    const t = this.tick;
    if (t) {
      if (t.calls >= TICK_CALLS_MAX || this.now() - t.started > TICK_WALL_MS) throw new TickBudget("this iteration's call budget is spent");
      t.calls += 1;
    }
    const u = await this.usage();
    if (u.calls >= cfg.daily_calls) throw new TickBudget("today's model-call budget is spent");
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
        if (u.calls >= cfg.daily_calls) {
          await this.emit("status", `today's ${cfg.daily_calls} model calls are spent; resting until tomorrow (UTC). /calls N raises the limit.`);
          nextS = Math.ceil((Date.parse(dayOf(this.now()) + "T00:00:00Z") + 86400000 - this.now()) / 1000) + 5;
        } else await this.emit("status", `iteration cut short: ${e.message}`);
      } else {
        // A failed iteration never ends the hot: it says what failed and comes back.
        const fails = ((await this.store.get("fails")) ?? 0) + 1;
        await this.store.put("fails", fails);
        await this.emit("error", clip(e?.message ?? e, 600));
        nextS = Math.min(3600, cfg.pace_s * Math.min(8, fails + 1));
      }
    } finally {
      this.tick = null;
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

    // No active goal: the next queued one, else one the hot proposes for itself, else a longer and longer rest.
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
      // A goal the human set while the hot was asking itself what to do next wins over the answer.
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
    const system = this.systemPrompt(cfg, g, lessons, padTail);
    const inboxText = inbox.length > 0 ? "\nNEW MESSAGES (a message from human is a directive and outranks your own plan):\n" + inbox.map((m) => `- ${m.from}: ${m.text}`).join("\n") + "\n" : "";

    // PICK
    const pick = (await this.ask(cfg, [{ role: "system", content: system }, { role: "user", content: inboxText + pickQuestion(g, rows) }], 400)).trim();
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
    const tools = cfg.local ? [...TOOLS, LOCAL_TOOL] : TOOLS;
    const claim = await this.toolLoop(cfg, system + "\n\nTOOLS:\n" + toolList(tools) + "\n\n" + REPLY_RULE, inboxText + "THIS ITERATION'S STEP: " + step, tools, TOOL_ROUNDS, record, "");

    // MEASURE
    const transcript = record.length > 0 ? record.map((r) => `TOOL ${r.tool}(${clip(JSON.stringify(r.args), 300)}) -> ${clip(r.result, 1200)}`).join("\n") : "(no tool was used)";
    const verdictLine = await this.ask(cfg, [{ role: "system", content: JUDGE_SYSTEM }, { role: "user", content: `THE STEP: ${step}\n\nTHE RECORD:\n${transcript}\n\nCLOSING CLAIM: ${clip(claim, 800)}\n\n${judgeQuestion(g.text)}` }], 200);
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
    await this.emit("verdict", `${outcome}${row.den > 0 ? ` [${row.num}/${row.den}]` : ""}${row.evidence ? `: ${row.evidence}` : ""}`, { i: row.i, outcome });

    // LEARN: the hot rewrites its own operating rules from what the measurement said.
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
      `You are ${cfg.name}, a hot: an autonomous technician that runs in the cloud for one human and works toward their goals with nobody watching. ` +
      "You never ask the human a question and wait; you decide, act, and report. You keep going until the goal is measurably achieved, and you prefer steps whose effect a tool result can show.\n" +
      (cfg.charter ? `CHARTER (what you serve when no goal is active, and the frame for every goal): ${cfg.charter}\n` : "") +
      (g ? `THE GOAL: ${g.text}\n` : "") +
      (lessons.length > 0 ? "YOUR LESSONS (rules you wrote for yourself from measured outcomes; follow them):\n" + lessons.map((l) => `- ${l.text}`).join("\n") + "\n" : "") +
      (padTail ? "SHARED SCRATCHPAD (newest entries; every hot of this account reads and writes it):\n" + padTail + "\n" : "")
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
      const reply = await this.ask(cfg, messages, 1200);
      const act = firstJson(reply);
      if (act && typeof act.final === "string") return act.final;
      if (act && typeof act.tool === "string") {
        const args = act.args && typeof act.args === "object" ? act.args : {};
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
        await this.emit("act", `${mind ? mind + " " : ""}${act.tool} ${clip(JSON.stringify(args), 600)} -> ${clip(result, 1500)}`, { tool: act.tool });
        messages.push({ role: "assistant", content: clip(reply, 2000) });
        messages.push({ role: "user", content: `RESULT of ${act.tool}:\n${clip(result, 6000)}\n\n${round + 2 >= rounds ? 'This is your last call for this step: reply {"final": ...} now.' : "Next action, or the final answer."}` });
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

  async runTool(cfg, tool, args, mind) {
    const who = mind ? `${cfg.name}/${mind}` : cfg.name;
    switch (tool) {
      case "note_write": {
        const name = String(args.name ?? "").trim();
        if (!/^[A-Za-z0-9._-]{1,64}$/.test(name)) return "ERROR: a note name is 1-64 of letters, digits, . _ -";
        const text = String(args.text ?? "");
        if (text.length > 60000) return "ERROR: a note holds at most 60000 characters; split it";
        const count = (await this.store.list({ prefix: "note:", limit: 201 })).size;
        if (count >= 200 && !(await this.store.get("note:" + name))) return "ERROR: 200 notes already; delete one first";
        // The stamp is unique per write (a later write in the same millisecond still sorts after), so the mirror's
        // "changed after t" never misses one.
        const t = Math.max(this.now(), ((await this.store.get("notes_t")) ?? 0) + 1);
        await this.store.put("notes_t", t);
        await this.store.put("note:" + name, { t, text });
        await this.store.put("notes_rev", ((await this.store.get("notes_rev")) ?? 0) + 1);
        return `saved ${name} (${text.length} characters)`;
      }
      case "note_read": {
        const n = await this.store.get("note:" + String(args.name ?? ""));
        return n ? n.text : "ERROR: no such note";
      }
      case "note_list": {
        const all = await this.store.list({ prefix: "note:", limit: 200 });
        return all.size === 0 ? "(no notes yet)" : [...all.entries()].map(([k, v]) => `${k.slice(5)} (${v.text.length} characters)`).join("\n");
      }
      case "note_delete": {
        if (!(await this.store.delete("note:" + String(args.name ?? "")))) return "ERROR: no such note";
        await this.store.put("notes_rev", ((await this.store.get("notes_rev")) ?? 0) + 1);
        return "deleted";
      }
      case "pad_read": {
        const r = await (await call(stubFor(this.env, "pad"), "/pad/read?after=0")).json();
        return (r.entries ?? []).length === 0 ? "(the scratchpad is empty)" : r.entries.slice(-40).map((e) => `${e.seq}. ${e.from}: ${e.text}`).join("\n");
      }
      case "pad_write": {
        const r = await (await call(stubFor(this.env, "pad"), "/pad/write", { from: who, text: args.text })).json();
        return r.ok ? `scratchpad entry ${r.seq} written` : `ERROR: ${r.err}`;
      }
      case "tell": {
        const target = String(args.hot ?? "");
        if (!validName(target) || target.toLowerCase() === cfg.name.toLowerCase()) return "ERROR: name another hot";
        const roster = await (await call(stubFor(this.env, "pad"), "/pad/roster")).json();
        const known = (roster.hots ?? []).find((h) => h.name.toLowerCase() === target.toLowerCase());
        if (!known) return `ERROR: no hot named ${target}. Hots: ${(roster.hots ?? []).map((h) => h.name).join(", ")}`;
        const r = await (await call(stubFor(this.env, hotKey(known.name)), "/inbox", { from: who, text: args.text })).json();
        return r.ok ? `delivered to ${known.name}` : `ERROR: ${r.err}`;
      }
      case "web_fetch":
        return this.webFetch(String(args.url ?? ""));
      case "swarm":
        return mind ? "ERROR: a mind cannot cast a swarm" : this.swarm(cfg, args);
      case "goal_queue": {
        const text = clip(String(args.text ?? "").trim(), 1000);
        if (text.length < 3) return "ERROR: empty goal";
        const queue = (await this.store.get("queue")) ?? [];
        queue.push(text);
        await this.store.put("queue", queue.slice(-20));
        return `queued (${Math.min(queue.length, 20)} waiting)`;
      }
      case "say": {
        const text = clip(String(args.text ?? "").trim(), 4000);
        if (text.length === 0) return "ERROR: empty message";
        await this.emit("say", text);
        return "reported";
      }
      case "local_run": {
        if (!cfg.local) return "ERROR: this hot was not given the owner's machine";
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

  async webFetch(url) {
    if (!/^https?:\/\//i.test(url)) return "ERROR: an http(s) URL is needed";
    const t = this.tick;
    if (t) {
      if (t.calls >= TICK_CALLS_MAX) throw new TickBudget("this iteration's call budget is spent");
      t.calls += 1;
    }
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 20000);
    try {
      const r = await fetch(url, { signal: ctl.signal, redirect: "follow", headers: { "user-agent": "veil-hot/" + VERSION, accept: "text/html,application/json,text/plain,*/*" } });
      const type = r.headers.get("content-type") ?? "";
      let text = (await r.text()).slice(0, 400000);
      if (type.includes("html")) {
        text = text
          .replace(/<(script|style|noscript|svg)[\s\S]*?<\/\1>/gi, " ")
          .replace(/<[^>]+>/g, " ")
          .replace(/&nbsp;/g, " ")
          .replace(/&amp;/g, "&")
          .replace(/&lt;/g, "<")
          .replace(/&gt;/g, ">")
          .replace(/\s+/g, " ");
      }
      return `HTTP ${r.status}\n${clip(text.trim(), 8000)}`;
    } catch (e) {
      return `ERROR: fetch failed: ${clip(e?.message ?? e, 200)}`;
    } finally {
      clearTimeout(timer);
    }
  }

  /// An inner swarm: one mind per task, side by side, each with its own short tool loop. `minds` is how many
  /// this hot runs at its current size.
  async swarm(cfg, args) {
    const tasks = (Array.isArray(args.tasks) ? args.tasks : []).map((t) => String(t ?? "").trim()).filter((t) => t.length > 2);
    if (tasks.length === 0) return "ERROR: give tasks: a list of one instruction per mind";
    // At least two minds when the size allows it: a swarm of one is just this hot again, slower.
    const width = Math.min(cfg.size, Math.max(2, cfg.minds));
    const run = tasks.slice(0, width);
    const tools = TOOLS.filter((t) => MIND_TOOLS.has(t.name));
    const system =
      `You are one mind of ${cfg.name}'s swarm: you have ONE task, a few tool calls, and nobody to ask. Do the task and report what the tool results showed.\n\nTOOLS:\n` +
      toolList(tools) + "\n\n" + REPLY_RULE;
    await this.emit("swarm", `cast ${run.length} mind(s)${tasks.length > run.length ? ` (${tasks.length - run.length} task(s) left out: this hot runs ${width} at a time now)` : ""}`);
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
    const left = tasks.length > run.length ? `\nNOT RUN (this hot runs ${width} at a time now): ${tasks.slice(run.length).map((t) => clip(t, 120)).join(" | ")}` : "";
    return reports.join("\n") + left;
  }

  // ---------------------------------------------------------------- self-improvement

  /// After every measured iteration the hot changes how it works:
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
          120,
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
  /// writes that copy back whole. Nothing is written for a hot that was deleted meanwhile.
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
      200,
    );
    const text = clip(reply.replace(/^["'`\s]+|["'`\s]+$/g, ""), 600);
    if (text.length < 8 || /^REST\b/i.test(text)) return "";
    await this.emit("status", "no goal left; taking up the next best thing");
    return text;
  }
}
