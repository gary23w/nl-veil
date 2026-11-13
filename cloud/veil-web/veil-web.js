// veil-web.js - the web veil's worker harness: the model, the hands and the job queue of a veil that lives in
// a browser tab.
//
// WHAT: one Worker ("veil-web") in the user's OWN Cloudflare account, put there by Cloudflare's deploy page
// from this folder (wrangler.jsonc beside this file). The web veil page (docs/chat) keeps the conversation and
// its tool loop in the browser; this Worker is what a tab cannot be:
//   - the MODEL: the account's own AI binding (env.AI). No API key, and the call never crosses the public internet.
//   - the WEB: fetch a page, run a search. A page on another site cannot read those itself (same-origin policy).
//   - the CLOUDFLARE API: it answers no cross-origin page, so the few calls the page needs (who logged in, the
//     model list, updating this Worker) are made here, with the user's own login.
//   - JOBS: work that goes on with the tab closed. A FIFO queue (one job at a time, in arrival order) run by an
//     alarm, each job the same pick-a-tool loop the page runs.
//   - PYTHON: cloud/tot_py.py loaded as a Dynamic Worker inside this one (the LOADER binding). Nothing else is
//     deployed. Cloudflare offers that binding on the Workers Paid plan; without it the page runs a chat's
//     Python in the browser and jobs are told Python is not available here.
//   - AGENT GARRETT: the user's agent, reached over MCP (tools/list, tools/call) with the key its dashboard gives.
//   - MCP: any MCP server the owner adds (name, address, token), its tools callable from chat and from jobs.
//   - CLEF: yes/no decisions answered as probabilities by Cloudflare's decision model, as the desktop veil does.
//   - LOCAL JOBS: a job queued with `local: true` is not run here. It waits for the owner's own machine: a
//     desktop veil whose owner allowed it asks for these jobs (nothing here calls the machine), runs each one
//     there and posts the result back. Until one does, the job stays queued.
//   - THE MESH: every veil logged in to this account (a desktop veil, a browser tab of the web veil) can tell
//     the harness it is here: a NODE with an id, a name, what kind it is and whether it runs work sent to it.
//     A local job may be addressed to one node; only that node is handed it. Nothing here calls a node: each
//     one asks. A node that has not said it is here for NODE_ONLINE_MS is listed as offline.
//   - SHARED SETTINGS: small named values (a model choice, a theme) every veil of the account reads and writes.
//     The last write of a name wins; each carries the time the harness took it.
//   - SCHEDULES: a task that queues itself as a job every so often.
//   - CHATS: the page's conversations and their files, kept here so every browser the owner logs in from (and
//     anything else holding their login) sees the same ones.
//   - WHAT IT KNOWS ABOUT ITS MAKER: a daily read of garrettstimpson.ca/llms.txt, cut down to what is about
//     Agent Garrett and the veil, handed to the model as reference.
//
// WHO MAY CALL IT: only someone logged in to the Cloudflare account that owns it. Every request carries the
// caller's Cloudflare OAuth access token as `Authorization: Bearer`; the harness asks Cloudflare for that
// token's accounts and accepts it only when one of them owns the workers.dev name this Worker answers on.
// There is no shared key to paste or leak. Cross-origin calls are answered for ALLOW_ORIGIN (the page) only.
//
// WHAT IT KEEPS (one Durable Object, "main"): the queue and each job's record, today's usage, the limits, the
// Python source's cached copy, Agent Garrett's address and token, the nodes that said they are here, and the
// shared settings. All of it in the user's account.
//
// LIMITS (DEFAULTS; the owner can change them, within CEIL): model calls and transferred bytes per UTC day, and
// bytes of job data kept. A spent day's budget refuses new work until 00:00 UTC; the queue holds QUEUE_MAX waiting
// jobs; finished jobs are dropped oldest first past JOBS_KEEP or past the storage limit.
//
// ROUTES (all under /v1, all needing the login except the CORS preflight)
//   GET  status | me            what is here, usage and limits | who is logged in
//   POST config                 {calls_max?, bytes_max?, storage_max?}
//   POST chat | fetch | search  one model call (stream:true = SSE) | one HTTP call | a web search
//   GET  jobs | jobs/<id>       the queue, oldest first | one job whole
//   POST jobs  {task, model, local?, node?, from?}   queue a job (local: true = for the owner's machine;
//                               node: <id> = for that one node, which makes it local; from: the node asking)
//   DELETE jobs/<id>            cancel or delete one
//   GET  local[?node=<id>]      the local jobs not finished yet, oldest first: {id, t, task, model, state, node}.
//                               With node: that node's jobs and the ones addressed to nobody. Without: only those.
//   GET  nodes                  every node: {id, name, kind, os, version, runs, browser, garrett, mcp, seen, online, waiting}
//   POST nodes/<id>             {name, kind, os?, version?, runs?, browser?, garrett?, mcp?}  "I am here" (again)
//   DELETE nodes/<id>           forget one
//   GET  settings               {settings: {name: {v, at}}}      POST settings {set?: {name: value}, del?: [name]}
//   GET  share                  the connections kept here, whole, for another veil of the owner to use the same
//                               ones: {garrett: {url, token} | null, mcp: [{name, url, token}]}
//   POST local/<id>             {started: true} when the machine takes one | {ok, result} when it has ended
//   POST python/enable (re-upload this Worker with the LOADER binding) | python/run {code, files?, args?, packages?}
//   POST garrett {key} or {url, token} (neither forgets it) | garrett/call {method, params}
//   GET  models                 the account's Workers AI text models
//   GET  schedules   POST schedules {task, model, every_s}   DELETE schedules/<id>
//   GET  convs | convs/<id>     POST convs/<id> {title, at, msgs, files}   DELETE convs/<id>
//   GET  context                the reference text the model is handed (llms.txt digest)
//   POST update                 replace this Worker with the current source from the public repo
//   POST clef  {state, questions: [...]}    yes/no decisions as probabilities (Cloudflare's Clef), or probs: null
//   GET  mcp   POST mcp {name, url, token?}   DELETE mcp/<name>   POST mcp/call {server, method, params, query?}
//
// No imports and no platform globals beyond fetch/Response/crypto, so a test can run this file under node with
// a Map for storage and a scripted env.AI.

export const VERSION = "12";
const API_ROOT = "https://api.cloudflare.com/client/v4";
const PY_SOURCE = "https://raw.githubusercontent.com/gary23w/nl-veil/main/cloud/tot_py.py";
const SELF_SCRIPT = "veil-web";
const SELF_SOURCE = "https://raw.githubusercontent.com/gary23w/nl-veil/main/cloud/veil-web/veil-web.js";
const LLMS_URL = "https://garrettstimpson.ca/llms.txt";
export const GARRETT_MCP = "https://agent.garrettstimpson.ca/mcp";
export const GARRETT_DASHBOARD = "https://agent.garrettstimpson.ca/dashboard";
const COMPAT_DATE = "2025-09-01";
export const CLEF_MODEL = "@cf/cloudflare/clef-flash"; // the id src/worker/chat/clef.zig calls
const CLEF_QUESTIONS_MAX = 64;
export const MCP_MAX = 8; // MCP servers one harness keeps
// what a site answers a datacenter address when it will not serve it
const BLOCKED = new Set([202, 401, 403, 406, 409, 419, 429, 451, 503]);
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const MB = 1 << 20;

export const DEFAULTS = { calls_max: 400, bytes_max: 200 * MB, storage_max: 64 * MB };
const CEIL = { calls_max: 100000, bytes_max: 100000 * MB, storage_max: 1024 * MB };
export const QUEUE_MAX = 16; // jobs waiting at once
export const JOBS_KEEP = 50; // finished jobs kept, oldest dropped first
const JOB_BYTES_MAX = 1500000; // one job's record (a Durable Object value has a size ceiling)
const JOB_ROUNDS = 24; // tool calls one job may make
const ALARM_STEPS = 6; // model calls one alarm makes before handing over to the next alarm
const JOB_LOOP_BYTES = 40000; // a job's messages; older rounds go first
const RESULT_MAX = 10000;
const LOCAL_WAITING = "waiting for the owner's machine"; // a local job's note until a machine takes it
const LOCAL_RUNNING = "running on the owner's machine";
export const NODES_MAX = 16; // nodes one harness lists; the one unseen longest goes first
export const NODE_ONLINE_MS = 90 * 1000; // a node says it is here more often than this
const NODE_KINDS = new Set(["desk", "server", "web"]);
const NODE_ID = /^[a-z0-9]{8,32}$/;
export const SETTINGS_MAX = 128; // shared settings one harness keeps
const SETTING_NAME = /^[a-z][a-z0-9_.]{0,47}$/;
const SETTING_BYTES = 2000; // one value
const FETCH_TEXT_MAX = 200000;
const MAX_TOKENS_CEIL = 16384;
const AUTH_TTL_MS = 5 * 60 * 1000;
// A model that spends its whole reply reasoning answers nothing. Which request field switches that off differs
// by model and is LEARNED, never assumed from the model's name: each is tried in turn when a reply comes back
// empty, and the one that produced an answer is remembered for that model.
const QUIET_KNOBS = [{ enable_thinking: false }, { chat_template_kwargs: { thinking: false } }, { chat_template_kwargs: { enable_thinking: false } }, { reasoning_effort: "low" }];
const THINK_PATIENCE = 6000; // characters of reasoning, with no word of a reply yet, before a job's call is given up on
const TRIAL_PATIENCE = 1500; // the same, for a call sent with a knob that is meant to switch reasoning off
const SOCKETS_MAX = 16; // sockets the harness holds open at once
const EXTRA_KEYS = new Set(["enable_thinking", "chat_template_kwargs", "reasoning_effort"]); // what a caller may add to a model request
const DENY_TTL_MS = 60 * 1000; // a refused token is not asked about again for this long
const MODELS_TTL_MS = 15 * 60 * 1000;
const LLMS_TTL_MS = 24 * 3600 * 1000;
const LLMS_DIGEST_MAX = 3500;
export const SCHEDULES_MAX = 12;
export const SWARMS_MAX = 8; // swarms kept, running or ended
export const SWARM_WORKERS_MAX = 6; // tasks one cycle hands out
export const SWARM_CYCLES_MAX = 40; // cycles one swarm may take
const SWARM_TICK_MS = 5000; // how often a running swarm looks at its workers
const SWARM_TASK_WAIT_MS = 45 * 60 * 1000; // a task on a machine that never answers is given up on
const SWARM_FILES_BYTES = 240 * 1024; // the files a swarm's workers share
const LESSONS_MAX = 40; // lessons kept for later swarms (the harness's lineage)
const MIND_NAMES = ["nova", "ada", "rex", "lux", "sol"]; // the desk's names for a swarm's minds; past them, mind6, mind7
export const EVERY_MIN_S = 300; // the shortest repeat a schedule may have
const CONV_BYTES_MAX = 1500000; // one conversation with its files
export const CONVS_MAX = 200;

const clip = (s, n) => {
  s = String(s ?? "");
  return s.length <= n ? s : s.slice(0, n) + "…";
};
const say = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
const bad = (err, status = 400) => say({ ok: false, err }, status);
const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);
const hex = (buf) => Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");

function cors(req, env) {
  const origin = req.headers.get("origin") ?? "";
  const allow = String(env.ALLOW_ORIGIN ?? "").split(",").map((x) => x.trim()).filter(Boolean);
  const h = { vary: "Origin" };
  if (origin && allow.includes(origin)) {
    h["access-control-allow-origin"] = origin;
    h["access-control-allow-methods"] = "GET, POST, DELETE, OPTIONS";
    h["access-control-allow-headers"] = "authorization, content-type";
    h["access-control-expose-headers"] = "x-git-status, x-git-type";
    h["access-control-max-age"] = "86400";
  }
  return h;
}

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

/// An address this Worker must not call: a private network, a loopback, a cloud metadata service.
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

/// Search results out of an engine's HTML page (the same reader cloud/tot.js uses).
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
      if (/duckduckgo\.com|bing\.com|microsoft\.com|go\.microsoft|mojeek\.com/.test(host) || seen.has(u)) return;
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

// ---- reading what a model sent: one reader for every dialect measured on Workers AI (2026-11-13) ----
// Models asked for `{"tool": ..., "args": {...}}` answer in many shapes: the JSON as text, fenced, or pretty
// printed; the JSON already parsed into an OBJECT by the API; an OpenAI `tool_calls` list; their own markup
// (`<|tool_call>call:write_file {content: \`...\`, path: "x"}<tool_call|>`, `<tool_call>{...}</tool_call>`,
// `name<|tool_call_argument_begin|>{...}`); arguments flat beside the tool's name; a first key that lost a
// quote; `write\_file`. A reply can also be cut off at its length limit in the middle of a call.

/// The text of a model reply, whatever envelope its family uses. An object where text was expected is the
/// model's JSON already parsed: it is put back as JSON. A reply that is only `tool_calls` becomes the call.
function modelText(r) {
  const flat = (c) => (typeof c === "string" ? c : Array.isArray(c) ? c.map((p) => (typeof p === "string" ? p : (p?.text ?? p?.content ?? ""))).join("") : c && typeof c === "object" ? JSON.stringify(c) : typeof c === "number" || typeof c === "boolean" ? String(c) : "");
  if (typeof r === "string") return r;
  if (!r || typeof r !== "object") return "";
  const msg = r.choices?.[0]?.message ?? r.choices?.[0]?.delta;
  for (const c of [r.response, r.result?.response, r.output_text, msg?.content, r.choices?.[0]?.text]) {
    const t = flat(c);
    if (t) return t;
  }
  const call = (r.tool_calls ?? msg?.tool_calls ?? [])[0];
  if (call && typeof call === "object") {
    const f = call.function && typeof call.function === "object" ? call.function : call;
    let args = f.arguments ?? f.args ?? {};
    if (typeof args === "string") {
      try {
        args = JSON.parse(args);
      } catch {
        args = {};
      }
    }
    if (typeof f.name === "string" && f.name) return JSON.stringify({ tool: f.name, args });
  }
  return "";
}

/// One value in JSON or in the looser object syntax models write (unquoted keys, single quotes, backtick
/// strings, raw line breaks in strings, trailing commas), starting at s[i]. Returns [value, index after it].
/// Throws "cut" when the text ends before the value does, and "bad" on anything it cannot read.
function looseValue(s, i) {
  const ws = () => {
    while (i < s.length && /\s/.test(s[i])) i++;
  };
  const end = () => {
    if (i >= s.length) throw new Error("cut");
  };
  ws();
  end();
  const c = s[i];
  if (c === "{") {
    const out = {};
    i++;
    for (;;) {
      ws();
      end();
      if (s[i] === "}") return [out, i + 1];
      let key;
      if (s[i] === '"' || s[i] === "'" || s[i] === "`") [key, i] = looseValue(s, i);
      else {
        const m = /^[A-Za-z_$][\w$-]*/.exec(s.slice(i, i + 80));
        if (!m) throw new Error("bad");
        key = m[0];
        i += key.length;
      }
      ws();
      end();
      if (s[i] !== ":" && s[i] !== "=") throw new Error("bad");
      i++;
      let v;
      [v, i] = looseValue(s, i);
      out[String(key)] = v;
      ws();
      end();
      if (s[i] === ",") i++;
      else if (s[i] !== "}") throw new Error("bad");
    }
  }
  if (c === "[") {
    const out = [];
    i++;
    for (;;) {
      ws();
      end();
      if (s[i] === "]") return [out, i + 1];
      let v;
      [v, i] = looseValue(s, i);
      out.push(v);
      ws();
      end();
      if (s[i] === ",") i++;
      else if (s[i] !== "]") throw new Error("bad");
    }
  }
  if (c === '"' || c === "'" || c === "`") {
    let out = "";
    i++;
    for (;;) {
      end();
      const ch = s[i];
      if (ch === c) return [out, i + 1];
      if (ch === "\\") {
        i++;
        end();
        const e = s[i];
        if (e === "u" && /^[0-9a-fA-F]{4}$/.test(s.slice(i + 1, i + 5))) {
          out += String.fromCharCode(parseInt(s.slice(i + 1, i + 5), 16));
          i += 5;
          continue;
        }
        out += { n: "\n", t: "\t", r: "\r", b: "\b", f: "\f", 0: "\0" }[e] ?? e;
        i++;
        continue;
      }
      out += ch;
      i++;
    }
  }
  const lit = /^(?:-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null|undefined)/.exec(s.slice(i, i + 40));
  if (!lit) throw new Error("bad");
  const word = lit[0];
  return [word === "true" ? true : word === "false" ? false : word === "null" || word === "undefined" ? null : Number(word), i + word.length];
}

/// What a reply asks for. {tool, args, say, cut?} when it is a tool call (`say` = what was said before it;
/// `cut` = a fenced block it relied on never closed); {broken: why} when it began a call that cannot be read,
/// which is what a reply cut off at its length limit looks like; null when it is the answer.
/// `known` is the list of tool names: prose that merely contains JSON stays an answer.
function toolCall(reply, known) {
  const text = String(reply ?? "").replace(/\\_/g, "_");
  const names = new Set(known);
  const finish = (name, args, at, endAt) => {
    if (!args || typeof args !== "object" || Array.isArray(args)) args = {};
    // {"arguments": {...}} or {"args": {...}} alone is a wrapper, not the arguments
    for (const k of ["args", "arguments", "parameters", "input"]) {
      if (Object.keys(args).length === 1 && args[k] && typeof args[k] === "object" && !Array.isArray(args[k])) args = args[k];
      else if (Object.keys(args).length === 1 && typeof args[k] === "string") {
        try {
          const inner = JSON.parse(args[k]);
          if (inner && typeof inner === "object") args = inner;
        } catch {}
      }
    }
    const out = { tool: String(name).replace(/^functions?[.:]/, ""), args, say: text.slice(0, at).replace(/```\w*\s*$/, "").replace(/<\|?[\w|]*$/, "").trim().slice(0, 700) };
    // A long file sent as a call WITHOUT its content, followed by the text in a fenced block: nothing to escape.
    if ((out.tool === "write_file" || out.tool === "append_file") && typeof args.content !== "string" && typeof args.text !== "string") {
      // (a call that was itself fenced closes its fence first; a model's closing tag may sit between)
      const fence = /^\s*(?:```[ \t]*\r?\n\s*)?(?:<\|?\/?tool_call\|?>\s*)?```[\w.+-]*[ \t]*\r?\n([\s\S]*?)(\r?\n```|$)/.exec(text.slice(endAt));
      if (fence) {
        args.content = fence[1] + (fence[2] ? "\n" : "");   // a whole block is whole lines, so parts join cleanly
        if (!fence[2]) out.cut = true;
      }
    }
    return out;
  };

  // 1. a model's own tool-call markup
  const mark = /<\|?tool_call(?:_begin)?\|?>\s*(?:call\s*[:=]\s*)?(?:functions?[.:])?([A-Za-z_][\w-]*)?(?::\d+)?\s*(?:<\|tool_call_argument_begin\|>)?\s*(?=\{)|(?:functions?[.:])?([A-Za-z_][\w-]*)(?::\d+)?\s*<\|tool_call_argument_begin\|>\s*(?=\{)/.exec(text);
  if (mark) {
    const at = mark.index + mark[0].length;
    let obj, endAt;
    try {
      [obj, endAt] = looseValue(text, at);
    } catch (e) {
      return { broken: e.message === "cut" ? "cut off before the call ended" : "not readable as a tool call" };
    }
    const named = mark[1] ?? mark[2];
    if (named) return finish(named, obj, mark.index, endAt);
    const inner = [obj.tool, obj.name, obj.tool_name].find((v) => typeof v === "string" && v);
    if (!inner) return { broken: "a tool call with no tool name" };
    return finish(inner, obj.args ?? obj.arguments ?? obj.parameters ?? obj.input ?? Object.fromEntries(Object.entries(obj).filter(([k]) => !["tool", "name", "tool_name", "type", "id"].includes(k))), mark.index, endAt);
  }

  // 2. an object: at the start of the reply (after an optional fence), or the first one anywhere that names a tool
  const lead = /^\s*(?:```[\w-]*\s*)?(?=\{)/.exec(text);
  const tries = [];
  if (lead) tries.push(lead[0].length);
  for (let at = text.indexOf("{"); at >= 0 && tries.length < 12; at = text.indexOf("{", at + 1)) if (!tries.includes(at)) tries.push(at);
  for (const at of tries) {
    let obj, endAt;
    try {
      [obj, endAt] = looseValue(text, at);
    } catch (e) {
      // an object the reply OPENS with, that begins like a call and never closes, is a call that was cut off
      if (lead && at === lead[0].length && /^\{\s*["'`]?(?:tool|name|tool_name|tool_calls|function)["'`]?\s*[:=]/.test(text.slice(at, at + 60))) return { broken: e.message === "cut" ? "cut off before the call ended" : "not readable as a tool call" };
      continue;
    }
    let c = obj;
    if (!c || typeof c !== "object" || Array.isArray(c)) continue;
    if (Array.isArray(c.tool_calls) && c.tool_calls[0] && typeof c.tool_calls[0] === "object") c = c.tool_calls[0];
    if (c.function && typeof c.function === "object") c = c.function;
    const name = [c.tool, c.name, c.tool_name].find((v) => typeof v === "string" && v.length > 0);
    const opens = !!lead && at === lead[0].length;
    if (!name || !(names.has(name.replace(/^functions?[.:]/, "")) || (opens && typeof c.tool === "string"))) continue;
    let args = [c.args, c.arguments, c.parameters, c.input].find((v) => v !== undefined && v !== null);
    if (typeof args === "string") {
      try {
        args = JSON.parse(args);
      } catch {
        args = undefined;
      }
    }
    if (!args || typeof args !== "object" || Array.isArray(args)) {
      // the fields flat beside the tool's name are its arguments; a first key that lost a quote reads `args: {url`
      const skip = new Set(["tool", "name", "tool_name", "args", "arguments", "parameters", "input", "type", "id"]);
      args = {};
      for (const [k, v] of Object.entries(c)) if (!skip.has(k)) args[/^(?:args|arguments|parameters|input)\W+(\w+)$/.exec(k)?.[1] ?? k] = v;
    }
    return finish(name, args, at, endAt);
  }
  return null;
}

/// The text of a model answer with any reasoning block removed.
export function answerText(r) {
  return modelText(r).replace(/<think>[\s\S]*?<\/think>/gi, "").replace(/<think>[\s\S]*$/i, "").trim();
}

/// A model's completion made fit to insert: no code fence, no repeat of the line being typed, nothing that runs
/// on into what is already after the cursor, a dozen lines at most.
export function tidyCompletion(text, prefix, suffix) {
  let t = String(text ?? "");
  const ins = /<ins>([\s\S]*?)(?:<\/ins>|$)/.exec(t);
  if (ins) t = ins[1];
  const fence = /^\s*```[\w-]*\r?\n([\s\S]*?)(?:\r?\n```\s*$|$)/.exec(t);
  if (fence) t = fence[1];
  const line = prefix.slice(prefix.lastIndexOf("\n") + 1);
  if (line.trim()) {
    if (t.startsWith(line)) t = t.slice(line.length);
    else if (t.trimStart().startsWith(line.trimStart())) t = t.trimStart().slice(line.trimStart().length);
  }
  const next = suffix.trimStart().split("\n")[0].trim();
  if (next.length > 3) {
    const i = t.indexOf(next);
    if (i >= 0) t = t.slice(0, i);
  }
  t = t.split("\n").slice(0, 13).join("\n").trimEnd();
  // a model that answers with what the file already says just above the cursor is suggesting nothing
  const said = t.split("\n").map((l) => l.trim()).filter((l) => l.length > 3);
  const near = new Set(prefix.split("\n").slice(-80).map((l) => l.trim()));
  if (said.length >= 2 && said.filter((l) => near.has(l)).length >= Math.ceil(said.length * 0.6)) return "";
  return t.trim() ? t : "";
}

/// What a job's reply asks for: {tool, args, cut?}, {broken}, or null when it is the answer.
export function parseAction(reply, known) {
  return toolCall(reply, known);
}

/// llms.txt cut down to what the veil should carry: its opening, About, Topics, and only the posts that are
/// about Agent Garrett or the veil. Everything else on that site is its own subject and stays there.
export function llmsDigest(text) {
  const keep = [];
  let section = "";
  for (const raw of String(text ?? "").split(/\r?\n/)) {
    const line = raw.trimEnd();
    if (line.startsWith("## ")) {
      section = line.slice(3).trim().toLowerCase();
      if (section !== "posts") keep.push(line);
      else keep.push("## Posts about Agent Garrett and the veil");
      continue;
    }
    if (section === "posts") {
      if (/agent garrett|nl-veil|the veil/i.test(line)) keep.push(clip(line, 420));
      continue;
    }
    if (line.trim()) keep.push(clip(line, 420));
  }
  return clip(keep.join("\n"), LLMS_DIGEST_MAX);
}

const JOB_TOOLS = {
  web_search: '{"query": "<words>"} : search the web',
  web_fetch: '{"url": "<https://...>"} : read a web page as text',
  http_request: '{"url": "<https://...>", "method": "GET", "headers": {}, "body": ""} : any HTTP call, raw answer',
  write_file: '{"name": "<path>", "content": "<text>"} : keep a file with this job',
  append_file: '{"name": "<path>", "content": "<text>"} : add to the end of one of this job\'s files',
  read_file: '{"name": "<path>"} : read one of this job\'s files',
  list_files: "{} : list this job's files",
  run_python: '{"code": "<python>"} : run Python (the job\'s files are beside the script; files it changes are kept)',
  swarm: '{"task": "<the question>", "angles": ["<a way to look at it>", "..."]} : ask up to 4 minds at once, one per angle',
  garrett_tools: '{"query": "<words, optional>"} : list the tools of Agent Garrett (those matching the words)',
  garrett: '{"name": "<tool>", "args": {...}} : call one of Agent Garrett\'s tools',
  mcp_tools: '{"server": "<name>", "query": "<words, optional>"} : list the tools of a connected MCP server',
  mcp_call: '{"server": "<name>", "tool": "<tool>", "args": {...}} : call a tool of a connected MCP server',
};

// ------------------------------------------------------------------------------------------ the Worker (door)

export default {
  async fetch(req, env) {
    const headers = cors(req, env);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
    let r;
    try {
      if (!env.HARNESS) r = bad("this Worker has no HARNESS Durable Object binding", 500);
      else r = await env.HARNESS.get(env.HARNESS.idFromName("main")).fetch(req);
    } catch (e) {
      r = bad("veil-web error: " + clip(e?.message ?? e, 300), 500);
    }
    if (r.status === 101) return r; // a WebSocket, handed over as it is
    const h = new Headers(r.headers);
    for (const [k, v] of Object.entries(headers)) h.set(k, v);
    return new Response(r.body, { status: r.status, headers: h });
  },
};

// ------------------------------------------------------------------------------------------ the Durable Object

export class Harness {
  constructor(state, env) {
    this.state = state;
    this.store = state.storage;
    this.env = env;
    this.authed = new Map(); // sha256(token) -> {account, sub, until}
  }

  async fetch(req) {
    try {
      return await this.route(req);
    } catch (e) {
      return bad("veil-web error: " + clip(e?.message ?? e, 300), 500);
    }
  }

  // ---------------------------------------------------------------- who is calling

  async api(token, method, path, body, type = "application/json") {
    const headers = { authorization: "Bearer " + token };
    if (body !== undefined && type) headers["content-type"] = type;
    try {
      const r = await fetch((this.env.API_ROOT || API_ROOT) + path, { method, headers, body: body === undefined ? undefined : typeof body === "string" || body instanceof FormData ? body : JSON.stringify(body) });
      const j = await r.json().catch(() => null);
      return j && typeof j === "object" ? j : { success: false, errors: [{ message: "HTTP " + r.status }] };
    } catch (e) {
      return { success: false, errors: [{ message: "could not reach the Cloudflare API: " + clip(e?.message ?? e, 120) }] };
    }
  }

  /// The caller, when their Cloudflare login belongs to the account that owns this Worker; null otherwise.
  async owner(req) {
    const auth = req.headers.get("authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (token.length < 20) return null;
    const key = hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)));
    const hit = this.authed.get(key);
    if (hit && hit.until > Date.now()) return hit.account ? { token, account: hit.account, sub: hit.sub } : null;
    const m = /^[a-z0-9-]+\.([a-z0-9-]+)\.workers\.dev$/.exec(new URL(req.url).hostname);
    if (!m) return null;
    // a refused token is remembered briefly, so repeating it costs the owner no further API calls
    const deny = () => {
      if (this.authed.size > 256) this.authed.clear();
      this.authed.set(key, { account: "", sub: "", until: Date.now() + DENY_TTL_MS });
      return null;
    };
    const owns = async (id) => (await this.api(token, "GET", `/accounts/${id}/workers/subdomain`))?.result?.subdomain === m[1];
    let account = await this.store.get("owner");
    if (account) {
      if (!(await owns(account))) return deny();
    } else {
      account = null;
      const list = await this.api(token, "GET", "/accounts?per_page=50");
      for (const a of Array.isArray(list?.result) ? list.result : []) {
        if (/^[0-9a-f]{32}$/.test(String(a?.id)) && (await owns(a.id))) {
          account = a.id;
          break;
        }
      }
      if (!account) return deny();
      await this.store.put("owner", account);
    }
    if (this.authed.size > 256) this.authed.clear();
    this.authed.set(key, { account, sub: m[1], until: Date.now() + AUTH_TTL_MS });
    return { token, account, sub: m[1] };
  }

  // ---------------------------------------------------------------- limits and usage

  async cfg() {
    return { ...DEFAULTS, ...((await this.store.get("cfg")) ?? {}) };
  }
  async usage() {
    const day = dayOf(Date.now());
    const u = await this.store.get("usage");
    return u && u.day === day ? u : { day, calls: 0, bytes: 0 };
  }
  async spend(calls, bytes) {
    const u = await this.usage();
    u.calls += calls;
    u.bytes += bytes;
    await this.store.put("usage", u);
  }
  /// Why new work is refused right now, or "".
  async spent(needsModel) {
    const [c, u] = [await this.cfg(), await this.usage()];
    if (needsModel && u.calls >= c.calls_max) return `today's model-call budget (${c.calls_max}) is spent; it resets at 00:00 UTC`;
    if (u.bytes >= c.bytes_max) return `today's data budget (${Math.round(c.bytes_max / MB)} MB) is spent; it resets at 00:00 UTC`;
    return "";
  }

  // ---------------------------------------------------------------- the model and the web

  /// One streamed model call, read here. Resolves {reply, gaveUp}: with `patience`, a call still only reasoning
  /// after that many characters is dropped (`gaveUp`) rather than waited out.
  async ask(model, messages, room, extra, patience, flat = false) {
    // a model whose host re-parses streamed tokens (`reparsed`, below) is asked for its reply whole
    if (flat) return { reply: answerText(await this.env.AI.run(model, { messages, max_tokens: room, ...(extra ?? {}) })), gaveUp: false };
    const out = await this.env.AI.run(model, { messages, max_tokens: room, stream: true, ...(extra ?? {}) });
    if (!(out instanceof ReadableStream)) return { reply: answerText(out), gaveUp: false };
    const reader = out.getReader();
    const dec = new TextDecoder();
    const calls = [];
    let buf = "", text = "", whole = null, reasoning = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line.startsWith("data:")) continue;
        let j;
        try {
          j = JSON.parse(line.slice(5).trim());
        } catch {
          continue; // [DONE], or a line that is not JSON
        }
        const d = j.choices?.[0]?.delta;
        for (const tc of d?.tool_calls ?? j.tool_calls ?? []) {
          const c = (calls[tc.index ?? 0] ??= { name: "", args: "" });
          c.name += tc.function?.name ?? tc.name ?? "";
          const g = tc.function?.arguments ?? tc.arguments;
          c.args += typeof g === "string" ? g : g ? JSON.stringify(g) : "";
        }
        const piece = d?.content ?? j.response;
        if (typeof piece === "number" || typeof piece === "boolean") {
          // text the host parsed token by token: digits come as numbers, quoted words lose their quotes
          reader.cancel().catch(() => {});
          return { reply: "", gaveUp: false, reparsed: true };
        }
        if (typeof piece === "string") text += piece;
        else if (piece && typeof piece === "object") whole = piece; // a reply the model's host already parsed
        const think = String(d?.reasoning_content ?? d?.reasoning ?? "");
        reasoning += think.length;
        if (patience && !text && !whole && !calls.length && reasoning > patience) {
          reader.cancel().catch(() => {});
          return { reply: "", gaveUp: true };
        }
      }
    }
    const message = { content: text || null, ...(calls[0]?.name ? { tool_calls: calls.map((c) => ({ function: { name: c.name, arguments: c.args } })) } : {}) };
    return { reply: answerText(whole !== null ? { response: whole } : { choices: [{ message }] }), gaveUp: false };
  }

  /// A model call for a job. A model that reasons on without a word of reply is not waited out: the call is
  /// dropped and asked again with each knob that may quiet it; the one that did is remembered for the model, and
  /// so is that none does (it then gets three times the room and all the time it wants).
  async model(model, messages, maxTokens) {
    const sent = messages.reduce((n, m) => n + m.content.length, 0);
    const quirks = (await this.store.get("quirks")) ?? {};
    const known = quirks[model]?.quiet;
    const ask = async (extra, room, patience) => {
      let got = await this.ask(model, messages, room, extra, patience, quirks[model]?.flat === true);
      if (got.reparsed) {
        quirks[model] = { ...quirks[model], flat: true };
        await this.store.put("quirks", quirks);
        got = await this.ask(model, messages, room, extra, patience, true);
      }
      await this.spend(1, sent + got.reply.length);
      return got.reply;
    };
    const roomy = () => ask(null, Math.min(MAX_TOKENS_CEIL, maxTokens * 3), 0);
    if (known === -1) return roomy();
    let reply = await ask(known !== undefined ? QUIET_KNOBS[known] : null, maxTokens, known === undefined ? THINK_PATIENCE : 0);
    if (reply) return reply;
    let quiet = -1;
    for (let i = 0; i < QUIET_KNOBS.length && quiet < 0; i++) {
      if (i === known) continue;
      try {
        reply = await ask(QUIET_KNOBS[i], maxTokens, TRIAL_PATIENCE);
      } catch {
        continue; // a model that rejects the field is not one it works on
      }
      if (reply) quiet = i;
    }
    quirks[model] = { ...quirks[model], quiet };
    await this.store.put("quirks", quirks);
    return reply || (await roomy());
  }

  async httpCall(spec) {
    let u;
    try {
      u = new URL(String(spec.url ?? ""));
    } catch {
      throw new Error("url is not a URL");
    }
    if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error("only http and https");
    if (privateHost(u.hostname)) throw new Error("that address is private");
    const method = String(spec.method ?? "GET").toUpperCase();
    if (!["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].includes(method)) throw new Error("method not allowed");
    const headers = { "user-agent": UA, accept: "text/html,application/json;q=0.9,*/*;q=0.8" };
    if (spec.headers && typeof spec.headers === "object") for (const [k, v] of Object.entries(spec.headers)) headers[String(k).toLowerCase()] = String(v);
    const r = await fetch(u.toString(), { method, headers, body: method === "GET" || method === "HEAD" ? undefined : String(spec.body ?? ""), redirect: "follow", signal: AbortSignal.timeout(20000) });
    const type = r.headers.get("content-type") ?? "";
    const raw = (await r.text()).slice(0, 2000000);
    await this.spend(0, raw.length);
    const text = clip(spec.raw === true || !/html/i.test(type) ? raw : readable(raw), FETCH_TEXT_MAX);
    const out = { status: r.status, content_type: type, url: r.url || u.toString(), text };
    // A site that refuses Cloudflare's addresses answers a block status or an empty shell. A plain page read
    // then falls back to the Internet Archive's newest copy, and says so: it may be days or months old.
    const refused = BLOCKED.has(r.status) || (/html/i.test(type) && text.trim().length < 200);
    if (!refused) return out;
    out.blocked = true;
    if (method !== "GET" || spec.raw === true || spec.archive === false) return out;
    try {
      const a = await fetch("https://archive.org/wayback/available?url=" + encodeURIComponent(u.toString()), { signal: AbortSignal.timeout(8000) });
      const snap = (await a.json())?.archived_snapshots?.closest;
      if (!snap?.available || !/^\d{14}$/.test(String(snap.timestamp))) return out;
      // the Archive refuses a datacenter address that claims to be a browser (HTTP 429) and serves one that says what it is
      const copy = await fetch(`https://web.archive.org/web/${snap.timestamp}id_/${u.toString()}`, { headers: { "user-agent": `nl-veil-web/${VERSION} (+https://github.com/gary23w/nl-veil)` }, redirect: "follow", signal: AbortSignal.timeout(20000) });
      const body = (await copy.text()).slice(0, 2000000);
      await this.spend(0, body.length);
      const read = clip(readable(body), FETCH_TEXT_MAX);
      if (copy.status !== 200 || read.trim().length < 200) return out;
      const t = String(snap.timestamp);
      return { status: 200, content_type: "text/html", url: u.toString(), text: read, blocked: true, via: `the Internet Archive's copy of ${t.slice(0, 4)}-${t.slice(4, 6)}-${t.slice(6, 8)} (the site refused a direct read)` };
    } catch {
      return out;
    }
  }

  // ---------------------------------------------------------------- clef (yes/no decisions)

  /// Ask Cloudflare's Clef every question about `state`: the probability that each answer is yes, or null when
  /// there is no usable answer (the caller then decides as it would without clef). The account's AI binding is
  /// tried first; with a login in hand the REST route the desktop veil uses is the second try.
  async clef(who, state, questions) {
    const qs = (Array.isArray(questions) ? questions : []).map(String).filter(Boolean);
    if (qs.length === 0 || qs.length > CLEF_QUESTIONS_MAX) return null;
    const body = { model: "clef-flash", state: clip(state, 60000), questions: Object.fromEntries(qs.map((q, i) => ["q" + i, { type: "noul", instructions: q }])) };
    const read = (raw) => {
      const root = raw?.result && typeof raw.result === "object" ? raw.result : raw;
      const probs = qs.map((_, i) => Number(root?.answers?.["q" + i]?.noul));
      return probs.every((x) => x >= 0 && x <= 1) ? probs : null;
    };
    await this.spend(1, JSON.stringify(body).length);
    let probs = null;
    try {
      probs = read(await this.env.AI.run(CLEF_MODEL, body));
    } catch {}
    if (!probs && who?.token) probs = read(await this.api(who.token, "POST", `/accounts/${who.account}/ai/run/${CLEF_MODEL}`, body));
    return probs;
  }

  // ---------------------------------------------------------------- MCP servers

  async mcpServers() {
    return (await this.store.get("mcp")) ?? [];
  }

  /// Greet an MCP server and count its tools. {tools, session} or {err}. No tool is run.
  async mcpHello(server) {
    const hello = await this.garrettRpc(server, "initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "nl-veil-web", version: VERSION } });
    if (hello.err) return hello;
    const withSession = { ...server, session: hello.session || "" };
    if (withSession.session) await this.garrettRpc(withSession, "notifications/initialized", undefined, true);
    const listed = await this.garrettRpc(withSession, "tools/list", {});
    if (listed.err) return listed;
    const tools = Array.isArray(listed.j?.result?.tools) ? listed.j.result.tools : [];
    return { tools, session: withSession.session };
  }

  /// One call to a named MCP server, as text for a model. A server that has forgotten its session is greeted again.
  async mcpCall(name, method, params, query = "") {
    const list = await this.mcpServers();
    const server = list.find((x) => x.name === String(name ?? ""));
    if (!server) return `ERROR: no MCP server named ${clip(name, 40)}. Connected: ${list.map((x) => x.name).join(", ") || "(none)"}`;
    let got = await this.garrettRpc(server, method, params);
    if (got.err && server.session) {
      const again = await this.mcpHello(server);
      if (!again.err) {
        server.session = again.session;
        await this.store.put("mcp", list);
        got = await this.garrettRpc(server, method, params);
      }
    }
    if (got.err) return `ERROR: ${server.name} ${got.err}`;
    return this.mcpText(server.name, method, got.j, query);
  }

  /// An MCP answer as text: a tool list (narrowed by `query`, names only when long) or a tool's text content.
  mcpText(label, method, j, query = "") {
    if (method === "tools/list") {
      const all = Array.isArray(j.result?.tools) ? j.result.tools : [];
      if (all.length === 0) return `(${label} lists no tools)`;
      const words = String(query ?? "").toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 1);
      const tools = words.length === 0 ? all : all.filter((t) => words.every((w) => `${t.name} ${t.description ?? ""}`.toLowerCase().includes(w)));
      if (tools.length === 0) return `none of ${label}'s ${all.length} tools match "${clip(query, 80)}". Try fewer or other words.`;
      if (tools.length > 40) return `${tools.length} tools. Names: ${tools.map((t) => t.name).join(", ")}\nAsk again with a query (for example {"query": "dns"}) to see what a group does.`;
      return tools.map((t) => `- ${t.name}: ${clip(String(t.description ?? ""), 200)}${t.inputSchema?.properties ? "\n  args: " + clip(Object.keys(t.inputSchema.properties).join(", "), 200) : ""}`).join("\n");
    }
    const out = (Array.isArray(j.result?.content) ? j.result.content : []).filter((c) => c?.type === "text").map((c) => c.text).join("\n");
    return (j.result?.isError ? "FAILED: " : "") + clip(out || "(no text)", 12000);
  }

  async search(query) {
    const q = encodeURIComponent(String(query ?? "").trim());
    if (!q) throw new Error("the query is empty");
    const tried = [];
    const get = async (url, accept, ms) => {
      const r = await fetch(url, { headers: { "user-agent": UA, accept, "accept-language": "en-US,en;q=0.9" }, signal: AbortSignal.timeout(ms) });
      const text = (await r.text()).slice(0, 800000);
      await this.spend(0, text.length);
      return { r, text };
    };
    const json = (text) => {
      try {
        return JSON.parse(text);
      } catch {
        return null;
      }
    };
    // The same ladder cloud/tot.js climbs: the engines' own pages refuse a datacenter address more often than
    // not, so the open ones are asked first.
    // 1. public SearXNG instances answer JSON; two are tried per search, starting at a different one each time
    const searx = ["https://searx.be", "https://search.disroot.org", "https://priv.au", "https://searx.tiekoetter.com", "https://search.bus-hit.me", "https://baresearch.org"];
    const start = ((await this.store.get("searx_i")) ?? 0) % searx.length;
    for (let k = 0; k < 2; k++) {
      const host = searx[(start + k) % searx.length];
      try {
        const { r, text } = await get(`${host}/search?q=${q}&format=json&categories=general`, "application/json", 7000);
        const results = (json(text)?.results ?? []).slice(0, 8).map((x) => ({ title: clip(x.title ?? "", 160), url: x.url ?? "", snippet: clip(x.content ?? "", 300) })).filter((x) => x.url && x.title);
        if (results.length > 0) {
          await this.store.put("searx_i", (start + k) % searx.length); // this one works: start here next time
          return results;
        }
        tried.push(`${new URL(host).hostname}: HTTP ${r.status}, no results`);
      } catch (e) {
        tried.push(`${new URL(host).hostname}: ${clip(e?.message ?? e, 60)}`);
      }
    }
    await this.store.put("searx_i", start + 2);
    // 2. the engines' HTML pages
    for (const [engine, url] of [
      ["duckduckgo", `https://html.duckduckgo.com/html/?q=${q}`],
      ["links", `https://lite.duckduckgo.com/lite/?q=${q}`],
      ["bing", `https://www.bing.com/search?q=${q}&setlang=en`],
      ["links", `https://www.mojeek.com/search?q=${q}`],
    ]) {
      try {
        const { r, text } = await get(url, "text/html", 9000);
        const results = searchResults(text, engine);
        if (results.length >= 2) return results;
        tried.push(`${new URL(url).hostname}: HTTP ${r.status}, nothing readable`);
      } catch (e) {
        tried.push(`${new URL(url).hostname}: ${clip(e?.message ?? e, 60)}`);
      }
    }
    // 3. DuckDuckGo's instant answers, then Wikipedia: reference lookups that still answer a datacenter address
    try {
      const d = json((await get(`https://api.duckduckgo.com/?q=${q}&format=json&no_html=1&no_redirect=1`, "application/json", 7000)).text) ?? {};
      const results = [];
      if (d.AbstractText) results.push({ title: d.Heading || String(query), url: d.AbstractURL || "", snippet: clip(d.AbstractText, 400) });
      for (const t of d.RelatedTopics ?? []) if (t?.Text && t?.FirstURL) results.push({ title: clip(t.Text, 80), url: t.FirstURL, snippet: clip(t.Text, 300) });
      if (results.length > 0) return results.slice(0, 8);
      tried.push("duckduckgo instant answers: nothing");
    } catch (e) {
      tried.push(`duckduckgo instant answers: ${clip(e?.message ?? e, 60)}`);
    }
    try {
      const j = json((await get(`https://en.wikipedia.org/w/api.php?action=opensearch&limit=8&format=json&search=${q}`, "application/json", 7000)).text);
      if (Array.isArray(j?.[1]) && j[1].length > 0) return j[1].map((ti, i) => ({ title: ti, url: j[3]?.[i] ?? "", snippet: j[2]?.[i] || "(Wikipedia article)" }));
      tried.push("wikipedia: nothing");
    } catch (e) {
      tried.push(`wikipedia: ${clip(e?.message ?? e, 60)}`);
    }
    throw new Error("no search source answered (" + tried.join("; ") + "). Fetch a likely page directly with web_fetch instead.");
  }

  // ---------------------------------------------------------------- what the account and the maker's site offer

  /// The account's Workers AI text models, asked of Cloudflare with the caller's login and kept for a while.
  async models(who) {
    const kept = await this.store.get("models");
    if (kept && Date.now() - kept.at < MODELS_TTL_MS) return kept.list;
    const j = await this.api(who.token, "GET", `/accounts/${who.account}/ai/models/search?task=Text%20Generation&hide_experimental=true&per_page=100`);
    const prop = (m, id) => (Array.isArray(m?.properties) ? m.properties.find((p) => p?.property_id === id)?.value : undefined);
    const list = (Array.isArray(j?.result) ? j.result : [])
      .filter((m) => typeof m?.name === "string" && m.name.startsWith("@"))
      .map((m) => ({ id: m.name, context: Number(prop(m, "context_window")) || 0, tools: String(prop(m, "function_calling")) === "true", reasoning: String(prop(m, "reasoning")) === "true" }))
      .sort((a, b) => a.id.localeCompare(b.id));
    if (list.length === 0) return kept?.list ?? [];
    await this.store.put("models", { at: Date.now(), list });
    return list;
  }

  /// garrettstimpson.ca/llms.txt, read once a day and cut to what is about Agent Garrett and the veil. Never throws.
  async context() {
    const kept = await this.store.get("llms");
    if (kept && Date.now() - kept.at < LLMS_TTL_MS) return kept;
    try {
      const r = await fetch(this.env.LLMS_URL || LLMS_URL, { headers: { "user-agent": UA, accept: "text/plain" }, signal: AbortSignal.timeout(10000) });
      const text = (await r.text()).slice(0, 400000);
      await this.spend(0, text.length);
      if (r.status !== 200 || !text.startsWith("#")) throw new Error("HTTP " + r.status);
      const fresh = { at: Date.now(), source: LLMS_URL, digest: llmsDigest(text) };
      await this.store.put("llms", fresh);
      return fresh;
    } catch {
      // a failed read is not retried on every request: the old copy (or nothing) stands for an hour
      const stale = { at: Date.now() - LLMS_TTL_MS + 3600 * 1000, source: LLMS_URL, digest: kept?.digest ?? "" };
      await this.store.put("llms", stale);
      return stale;
    }
  }

  /// Replace this Worker with the current source from the public repo, with the caller's login. The bindings are
  /// the ones wrangler.jsonc declares; the Durable Object and its data stay. {err} in words, {same} when the
  /// repo has nothing newer, or {version} of what was put in place.
  async selfUpdate(who, loader = !!this.env.LOADER) {
    let source;
    try {
      const r = await fetch(this.env.SELF_SOURCE || SELF_SOURCE, { headers: { "cache-control": "no-cache" } });
      source = await r.text();
      if (r.status !== 200) return { err: "could not fetch the harness's source (HTTP " + r.status + ")" };
    } catch (e) {
      return { err: "could not fetch the harness's source: " + clip(e?.message ?? e, 120) };
    }
    const version = /export const VERSION = "(\d+)";/.exec(source)?.[1];
    if (!version || !source.includes("export class Harness")) return { err: "what the repo serves is not a harness" };
    if (Number(version) < Number(VERSION)) return { err: `the repo's harness (version ${version}) is older than this one (${VERSION})` };
    if (Number(version) === Number(VERSION) && loader === !!this.env.LOADER) return { same: true, version };
    const origin = String(this.env.ALLOW_ORIGIN ?? "");
    const form = new FormData();
    form.append("metadata", new Blob([JSON.stringify({
      main_module: "veil-web.js",
      compatibility_date: COMPAT_DATE,
      compatibility_flags: ["global_fetch_strictly_public"],
      bindings: [{ type: "ai", name: "AI" }, { type: "durable_object_namespace", name: "HARNESS", class_name: "Harness" }, { type: "plain_text", name: "ALLOW_ORIGIN", text: origin }, ...(loader ? [{ type: "worker_loader", name: "LOADER" }] : [])],
      keep_bindings: ["secret_text"],
    })], { type: "application/json" }), "metadata.json");
    form.append("veil-web.js", new Blob([source], { type: "application/javascript+module" }), "veil-web.js");
    const up = await this.api(who.token, "PUT", `/accounts/${who.account}/workers/scripts/${SELF_SCRIPT}`, form, "");
    if (!up.success) return { err: "Cloudflare refused the update: " + clip(up.errors?.[0]?.message ?? "no reason given", 300) };
    return { version };
  }

  // ---------------------------------------------------------------- schedules

  async schedules() {
    return (await this.store.get("schedules")) ?? [];
  }

  /// Queue a job for every schedule that is due. A schedule whose last job is still waiting or running is passed
  /// over this time, so a slow task never stacks up behind itself.
  async runSchedules(index) {
    const list = await this.schedules();
    const now = Date.now();
    let changed = false;
    for (const s of list) {
      if (s.next > now) continue;
      s.next = now + s.every_s * 1000;
      changed = true;
      const busy = index.some((j) => j.id === s.last_job && ["queued", "running"].includes(j.state));
      if (busy || index.filter((j) => j.state === "queued").length >= QUEUE_MAX) continue;
      s.last_job = await this.enqueue(index, s.task, s.model, s.id);
      s.runs = (s.runs ?? 0) + 1;
    }
    if (changed) await this.store.put("schedules", list);
    return list.reduce((t, s) => Math.min(t, s.next), Infinity);
  }

  // ---------------------------------------------------------------- chats kept for every browser

  async convs() {
    return (await this.store.get("convs")) ?? [];
  }

  // ---------------------------------------------------------------- Python

  /// cloud/tot_py.py from the public repo, kept for a day. "" when it cannot be had.
  async pySource() {
    const kept = await this.store.get("py_src");
    if (kept && Date.now() - kept.at < LLMS_TTL_MS) return kept.text;
    try {
      const r = await fetch(this.env.PY_SOURCE || PY_SOURCE);
      const text = await r.text();
      if (r.status !== 200 || !text.includes("class Default(WorkerEntrypoint)")) return kept?.text ?? "";
      await this.store.put("py_src", { at: Date.now(), text });
      return text;
    } catch {
      return kept?.text ?? "";
    }
  }

  /// Run one script in Python INSIDE this Worker: tot_py.py as a Dynamic Worker (env.LOADER), the same module
  /// the tot runtime runs behind a service binding. Nothing else is deployed and nothing listens anywhere.
  async pythonRun(spec) {
    if (!this.env.LOADER) return { ok: false, out: "This harness has no Python runtime of its own: Cloudflare's Worker Loader is not bound to it (the Harness tab enables it; Cloudflare offers it on the Workers Paid plan). In a chat the page runs Python in the browser instead.", files: {} };
    const source = await this.pySource();
    if (!source) return { ok: false, out: "the Python runtime's source could not be fetched from the repo", files: {} };
    try {
      const id = "py-" + hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(source))).slice(0, 16);
      const worker = this.env.LOADER.get(id, () => ({ compatibilityDate: COMPAT_DATE, compatibilityFlags: ["python_workers"], mainModule: "tot_py.py", modules: { "tot_py.py": { py: source } } }));
      const r = await worker.getEntrypoint().fetch(new Request("https://py/run", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code: String(spec.code ?? ""), files: spec.files ?? {}, args: spec.args ?? null, packages: spec.packages ?? [] }) }));
      const text = await r.text();
      await this.spend(0, text.length);
      const j = JSON.parse(text);
      return { ok: j.ok === true, out: String(j.out ?? ""), files: j.files && typeof j.files === "object" ? j.files : {} };
    } catch (e) {
      return { ok: false, out: "Python did not run: " + clip(e?.message ?? e, 300), files: {} };
    }
  }

  // ---------------------------------------------------------------- Agent Garrett (MCP)

  /// One JSON-RPC request to an MCP endpoint: {j} the parsed answer, or {err} in words.
  async garrettRpc(g, method, params, notify = false) {
    let r, text;
    const headers = { "content-type": "application/json", accept: "application/json, text/event-stream" };
    if (g.token) headers.authorization = "Bearer " + g.token;
    if (g.session) headers["mcp-session-id"] = g.session;
    try {
      r = await fetch(g.url, { method: "POST", headers, body: JSON.stringify(notify ? { jsonrpc: "2.0", method } : { jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(30000) });
      text = await r.text();
      await this.spend(0, text.length);
    } catch (e) {
      return { err: `did not answer: ${clip(e?.message ?? e, 200)}` };
    }
    if (notify) return { j: {} };
    const session = r.headers.get("mcp-session-id") ?? "";
    // a server may answer a single request as one SSE event: the JSON is its data line
    const data = /^data:\s*(\{[\s\S]*\})\s*$/m.exec(text)?.[1] ?? text;
    let j = null;
    try {
      j = JSON.parse(data);
    } catch {}
    if (!j || typeof j !== "object") return { err: `answered HTTP ${r.status}: ${clip(text, 300)}` };
    if (j.error) return { err: clip(j.error.message ?? JSON.stringify(j.error), 400) };
    return { j, session };
  }

  /// One MCP call. `query` narrows a tools/list to the tools whose name or description holds every word of it;
  /// a long unfiltered catalogue is answered as names only, so it fits a model's room.
  async garrettCall(method, params, query = "") {
    const g = await this.store.get("garrett");
    if (!g) return "ERROR: Agent Garrett is not connected to this harness";
    const { j, err } = await this.garrettRpc(g, method, params);
    if (err) return "ERROR: Agent Garrett " + err;
    return this.mcpText("Agent Garrett", method, j, query);
  }

  // ---------------------------------------------------------------- jobs (FIFO)

  async jobs() {
    return (await this.store.get("jobs")) ?? [];
  }

  /// Drop finished jobs, oldest first, while there are more than JOBS_KEEP or their data is past the limit.
  async evict(index) {
    const { storage_max } = await this.cfg();
    const chats = (await this.convs()).reduce((n, c) => n + (c.bytes ?? 0), 0);
    const total = () => chats + index.reduce((n, j) => n + (j.bytes ?? 0), 0);
    const done = () => index.filter((j) => !["queued", "running"].includes(j.state));
    while (done().length > 0 && (done().length > JOBS_KEEP || total() > storage_max)) {
      const oldest = done()[0];
      index.splice(index.indexOf(oldest), 1);
      await this.store.delete("job:" + oldest.id);
    }
    return index;
  }

  async saveJob(job, index) {
    let text = JSON.stringify(job);
    // a record past its ceiling loses its oldest results first
    for (let i = 0; text.length > JOB_BYTES_MAX && i < job.rounds.length; i++) {
      job.rounds[i].result = clip(job.rounds[i].result, 200);
      text = JSON.stringify(job);
    }
    if (text.length > JOB_BYTES_MAX) {
      job.files = {};
      job.state = "failed";
      job.error = "this job's data passed the size one job may keep; its files were dropped";
      text = JSON.stringify(job);
    }
    await this.store.put("job:" + job.id, job);
    const row = index.find((j) => j.id === job.id);
    Object.assign(row, { state: job.state, finished: job.finished ?? 0, bytes: text.length, note: job.note ?? "" });
    await this.store.put("jobs", await this.evict(index));
  }

  async jobTool(job, name, args) {
    const f = String(args.name ?? args.path ?? args.file ?? args.filename ?? "").trim().replace(/^\.?\/+/, "");
    switch (name) {
      case "web_search":
        return (await this.search(args.query ?? args.q)).map((r, i) => `${i + 1}. ${r.title}\n   ${r.url}\n   ${r.snippet}`).join("\n");
      case "web_fetch":
      case "http_request": {
        const raw = name === "http_request";
        const r = await this.httpCall({ url: args.url, method: raw ? args.method : "GET", headers: raw ? args.headers : undefined, body: raw ? args.body : undefined, raw });
        return `HTTP ${r.status} ${r.url}\n\n${r.text}`;
      }
      case "write_file":
      case "append_file":
        if (!f || f.length > 200 || f.includes("..")) return "error: bad file name";
        if (typeof (args.content ?? args.text) !== "string") return `error: ${name} needs content: put it in args, or leave it out and follow the call with the text in one fenced code block`;
        job.files[f] = (name === "append_file" ? (job.files[f] ?? "") : "") + String(args.content ?? args.text);
        return `${name === "append_file" ? "appended to" : "wrote"} ${f} (${job.files[f].length} characters now)`;
      case "read_file":
        return f in job.files ? job.files[f] : `error: no file named ${f}`;
      case "list_files":
        return Object.keys(job.files).length ? Object.entries(job.files).map(([n, c]) => `${n} (${c.length} characters)`).join("\n") : "(no files yet)";
      case "run_python": {
        const r = await this.pythonRun({ code: args.code, files: job.files });
        for (const [n, c] of Object.entries(r.files)) if (typeof c === "string") job.files[n] = c;
        return (r.ok ? "" : "error: ") + (r.out || "(no output)");
      }
      case "swarm": {
        const task = String(args.task ?? "").trim();
        const angles = (Array.isArray(args.angles) ? args.angles : []).map(String).filter(Boolean).slice(0, 4);
        if (!task || angles.length < 2) return 'error: swarm needs a task and at least two angles, as {"tool": "swarm", "args": {"task": "...", "angles": ["...", "..."]}}';
        const minds = await Promise.all(angles.map(async (angle, i) => {
          try {
            const t = await this.model(job.model, [
              { role: "system", content: "You are one mind of a small swarm. Answer the task from the one angle you are given, in under 250 words. Say what you are unsure of." },
              { role: "user", content: `TASK: ${task}\n\nYOUR ANGLE: ${angle}` },
            ], 700);
            return `MIND ${i + 1} (${angle}):\n${t || "(answered nothing)"}`;
          } catch (e) {
            return `MIND ${i + 1} (${angle}): error: ${clip(e?.message ?? e, 200)}`;
          }
        }));
        job.calls += angles.length;
        return minds.join("\n\n");
      }
      case "garrett_tools":
        return this.garrettCall("tools/list", {}, args.query);
      case "garrett":
        return this.garrettCall("tools/call", { name: String(args.name ?? ""), arguments: args.args && typeof args.args === "object" ? args.args : {} });
      case "mcp_tools":
        return this.mcpCall(args.server, "tools/list", {}, args.query);
      case "mcp_call":
        return this.mcpCall(args.server, "tools/call", { name: String(args.tool ?? args.name ?? ""), arguments: args.args && typeof args.args === "object" ? args.args : {} });
      default:
        return `error: no tool named ${name}. Tools: ${Object.keys(JOB_TOOLS).join(", ")}`;
    }
  }

  /// One step of a job: one model call, and the tool it asked for. True when the job ended.
  async jobStep(job) {
    const tools = Object.entries(JOB_TOOLS).map(([n, t]) => `- ${n} ${t}`).join("\n");
    const ref = (await this.context()).digest;
    const head = [
      { role: "system", content: "You are the veil, working on a queued job with nobody watching. Work the task to the end with these tools:\n" + tools + '\n\nTo use a tool, reply with exactly ONE JSON object and nothing else: {"tool": "<name>", "args": {...}}. When the job is done, or cannot go further, reply in plain text with what was done and what the tool results showed. Never claim something no tool result shows. A long file is easier sent as the call WITHOUT content followed by the file text in one fenced code block, and in parts: write_file the first part, append_file the rest.' + (ref ? "\n\nREFERENCE (from garrettstimpson.ca/llms.txt, about the people and projects behind this veil):\n" + ref : "") },
      { role: "user", content: job.task },
    ];
    const pairs = job.rounds.map((r) => [
      { role: "assistant", content: JSON.stringify({ tool: r.tool, args: r.args }).slice(0, 2000) },
      { role: "user", content: `RESULT of ${r.tool}:\n${r.result}` },
    ]);
    while (pairs.length > 2 && pairs.flat().reduce((n, m) => n + m.content.length, 0) > JOB_LOOP_BYTES) pairs.shift();
    const reply = await this.model(job.model, [...head, ...pairs.flat()], 2048);
    job.calls += 1;
    if (!reply) throw new Error("the model answered nothing");
    const act = parseAction(reply, Object.keys(JOB_TOOLS));
    if (!act) {
      job.result = reply;
      job.state = "done";
      return true;
    }
    if (act.broken) {
      // a call that could not be read is told so, as a round, and counts toward the same-failure stop
      const last = job.rounds.at(-1);
      if (job.rounds.slice(-2).filter((r) => r.tool === "(unreadable call)").length === 2) {
        job.state = "failed";
        job.error = "stopped: three tool calls in a row could not be read (" + act.broken + ")";
        return true;
      }
      job.rounds.push({ tool: "(unreadable call)", args: {}, result: `error: that tool call was ${act.broken}. Replies have a length limit. Send the call again, complete; for a long file send write_file with the first part (about 100 lines) and append_file for the rest.` });
      return false;
    }
    if (job.rounds.length >= JOB_ROUNDS) {
      job.state = "failed";
      job.error = `stopped after ${JOB_ROUNDS} tool calls without finishing`;
      return true;
    }
    const same = (r) => r.tool === act.tool && JSON.stringify(r.args) === JSON.stringify(act.args) && /^(error|ERROR|FAILED)/.test(r.result);
    if (job.rounds.slice(-2).filter(same).length === 2) {
      job.state = "failed";
      job.error = `stopped: the same ${act.tool} call failed three times in a row (${clip(job.rounds.at(-1).result, 200)})`;
      return true;
    }
    let result;
    try {
      result = await this.jobTool(job, act.tool, act.args);
    } catch (e) {
      result = "error: " + clip(e?.message ?? e, 300);
    }
    if (act.cut) result += " NOTE: the code block was cut off before its closing fence. Continue the file from exactly where it stops with append_file.";
    job.rounds.push({ tool: act.tool, args: act.args, result: clip(result, RESULT_MAX) });
    return false;
  }

  /// Put a job at the back of the queue. The caller has checked there is room. Returns its id.
  /// `local`: the job is for the owner's machine. The alarm never runs it; it waits for /v1/local.
  /// `node`: the one node it is for ("" = any of the owner's machines). `from`: the node that asked ("" = not said).
  async enqueue(index, task, model, schedule = "", local = false, node = "", from = "") {
    const id = Date.now().toString(36) + hex(crypto.getRandomValues(new Uint8Array(3)));
    const note = local ? LOCAL_WAITING : "";
    const job = { id, task, model, schedule, state: "queued", created: Date.now(), started: 0, finished: 0, rounds: [], files: {}, result: "", error: "", note, calls: 0 };
    const row = { id, task: clip(task.replace(/\s+/g, " "), 120), state: "queued", created: job.created, finished: 0, bytes: 0, note, schedule };
    if (local) job.local = row.local = true;
    if (node) job.node = row.node = node;
    if (from) job.from = row.from = from;
    index.push(row);
    await this.saveJob(job, index);
    return id;
  }

  /// Wake when there is next something to do: a job to step (`wait` ms from now) or a schedule coming due.
  async rearm(wait, nextDue) {
    // a local job is the owner's machine's to run: it keeps no alarm going while it waits
    const active = (await this.jobs()).some((j) => !j.local && ["queued", "running"].includes(j.state));
    const at = Math.min(active ? Date.now() + wait : Infinity, nextDue, this.swarmDue ?? Infinity);
    if (at !== Infinity) await this.store.setAlarm(Math.max(at, Date.now() + 100));
  }

  /// The heartbeat: due schedules queue their jobs, then the job at the head of the queue takes up to ALARM_STEPS
  /// steps, then the next alarm goes on.
  async alarm() {
    const index = await this.jobs();
    const nextDue = await this.runSchedules(index);
    const swarmWait = await this.runSwarms(index);
    this.swarmDue = swarmWait ? Date.now() + swarmWait : Infinity;
    const row = index.find((j) => !j.local && j.state === "running") ?? index.find((j) => !j.local && j.state === "queued");
    if (!row) return this.rearm(1000, nextDue);
    const job = await this.store.get("job:" + row.id);
    if (!job) {
      index.splice(index.indexOf(row), 1);
      await this.store.put("jobs", index);
      return this.store.setAlarm(Date.now() + 1000);
    }
    if (job.state === "queued") {
      job.state = "running";
      job.started = Date.now();
    }
    let wait = 1000;
    for (let i = 0; i < ALARM_STEPS; i++) {
      const why = await this.spent(true);
      if (why) {
        job.note = "waiting: " + why;
        wait = 15 * 60 * 1000;
        break;
      }
      job.note = "";
      let ended;
      try {
        ended = await this.jobStep(job);
        job.fails = 0;
      } catch (e) {
        job.fails = (job.fails ?? 0) + 1;
        job.note = "model call failed: " + clip(e?.message ?? e, 200);
        ended = job.fails >= 3;
        if (ended) {
          job.state = "failed";
          job.error = job.note;
        } else {
          wait = 30000;
          break;
        }
      }
      if (ended) {
        job.finished = Date.now();
        break;
      }
    }
    await this.saveJob(job, index);
    await this.rearm(wait, nextDue);
  }

  // ---------------------------------------------------------------- swarms

  /// A SWARM works toward one goal with nobody watching. It runs here, in the harness, so it goes on with every
  /// tab closed. Each CYCLE a coordinator (one model call) reads what the workers brought back, writes down what
  /// was learned, decides whether the goal is met, and hands out the next tasks; each task is a job in the queue
  /// (or, when the swarm runs on the mesh, a job for one of the owner's machines), with the swarm's shared files
  /// beside it. Lessons outlive the swarm: the next one starts with what earlier ones learned.
  async swarms() {
    return (await this.store.get("swarms")) ?? [];
  }

  async saveSwarm(sw, list) {
    sw.updated = Date.now();
    sw.log = sw.log.slice(-120);
    await this.store.put("swarm:" + sw.id, sw);
    const row = { id: sw.id, name: sw.name, state: sw.state, phase: sw.phase, cycle: sw.cycle, cycles: sw.cycles, workers: sw.workers, where: sw.where, created: sw.created, updated: sw.updated, note: sw.note ?? "" };
    const i = list.findIndex((x) => x.id === sw.id);
    if (i >= 0) list[i] = row;
    else list.push(row);
    await this.store.put("swarms", list);
  }

  /// What a coordinator's reply says: {done, summary, lessons, tasks}, or null when it cannot be read.
  swarmPlan(reply, workers) {
    const at = reply.indexOf("{");
    if (at < 0) return null;
    let v;
    try {
      [v] = looseValue(reply, at);
    } catch {
      return null;
    }
    if (!v || typeof v !== "object") return null;
    const text = (x, n) => clip(String(x ?? "").trim(), n);
    const tasks = (Array.isArray(v.tasks) ? v.tasks : []).map((t) => ({ role: text(t?.role ?? t?.name ?? "worker", 60) || "worker", task: text(t?.task ?? t?.brief ?? (typeof t === "string" ? t : ""), 4000) })).filter((t) => t.task).slice(0, workers);
    return { done: v.done === true || (v.done === "true"), summary: text(v.summary ?? v.report, 6000), lessons: (Array.isArray(v.lessons) ? v.lessons : []).map((x) => text(x, 300)).filter(Boolean).slice(0, 6), tasks };
  }

  /// One step of one running swarm. Returns how soon it wants to be looked at again (ms), or 0 when none runs.
  async runSwarms(index) {
    const list = await this.swarms();
    const row = list.filter((x) => x.state === "running").sort((a, b) => a.updated - b.updated)[0]; // the one that has waited longest
    if (!row) return 0;
    const sw = await this.store.get("swarm:" + row.id);
    if (!sw) {
      await this.store.put("swarms", list.filter((x) => x.id !== row.id));
      return SWARM_TICK_MS;
    }
    const say = (text) => sw.log.push({ at: Date.now(), text: clip(text, 400) });

    if (sw.phase === "work") {
      // the cycle's tasks: each is a job; the cycle ends when every one of them has
      const now = Date.now();
      let open = 0;
      for (const t of sw.tasks.filter((x) => x.cycle === sw.cycle && x.state === "working")) {
        const jr = index.find((j) => j.id === t.job);
        if (jr && ["queued", "running"].includes(jr.state) && now - t.started < SWARM_TASK_WAIT_MS) {
          open++;
          continue;
        }
        const job = jr ? await this.store.get("job:" + t.job) : null;
        if (!job) {
          t.state = "lost";
          t.result = "the job was removed before it ended";
        } else if (["queued", "running"].includes(job.state)) {
          t.state = "failed";
          t.result = "no answer in time from " + (t.node ? "the machine it was sent to" : "the queue");
        } else {
          t.state = job.state === "done" ? "done" : "failed";
          t.result = clip(job.state === "done" ? job.result : job.error || job.result || "failed", 3000);
          sw.calls += job.calls ?? 0;
          // what the worker wrote joins the swarm's shared files, while there is room
          let room = SWARM_FILES_BYTES - Object.values(sw.files).reduce((n, c) => n + c.length, 0);
          for (const [name, text] of Object.entries(job.files ?? {})) {
            if (typeof text !== "string" || sw.files[name] === text) continue;
            const grow = text.length - (sw.files[name]?.length ?? 0);
            if (grow > room) {
              say(`${name} from ${t.role} was not kept: the swarm's shared files are full`);
              continue;
            }
            sw.files[name] = text;
            room -= grow;
          }
        }
        t.finished = now;
        say(`${t.role}: ${t.state}`);
      }
      if (open === 0) sw.phase = "plan";
      await this.saveSwarm(sw, list);
      return SWARM_TICK_MS;
    }

    // phase "plan": the coordinator
    const why = await this.spent(true);
    if (why) {
      sw.note = "waiting: " + why;
      await this.saveSwarm(sw, list);
      return 15 * 60 * 1000;
    }
    sw.note = "";
    const last = sw.tasks.filter((t) => t.cycle === sw.cycle);
    const earlier = sw.tasks.filter((t) => t.cycle < sw.cycle).slice(-12);
    const lessons = [...new Set([...((await this.store.get("lessons")) ?? []), ...sw.lessons])].slice(-24);
    const nodes = sw.where === "mesh" ? (await this.nodes()).filter((n) => n.runs && Date.now() - n.seen < NODE_ONLINE_MS) : [];
    const head = `You coordinate a swarm of up to ${sw.workers} workers toward ONE goal, with nobody watching. This is cycle ${sw.cycle + 1} of at most ${sw.cycles}.\n` +
      "Each cycle you read what the workers brought back, write down what was learned, decide whether the goal is met, and hand out the next tasks.\n" +
      `A worker knows ONLY the task you write for it (plus the shared files and the lessons): write each task whole, with what to produce and where to put it. A worker has these tools: ${Object.keys(JOB_TOOLS).join(", ")}. Files a worker writes are shared with the whole swarm.\n` +
      "Be adaptive: when an approach failed, change it; split work so workers do not repeat each other; verify what matters with a second worker.\n" +
      'Reply with exactly ONE JSON object and nothing else.\nTo go on: {"done": false, "summary": "<where things stand>", "lessons": ["<a short thing worth remembering>"], "tasks": [{"role": "<a short name>", "task": "<the whole brief>"}]}\n' +
      'When the goal is met, or nothing more can move it: {"done": true, "summary": "<the final report for the owner: what was achieved, where the results are, what was not done>", "lessons": ["..."]}';
    const body = `THE GOAL:\n${sw.goal}\n\n` +
      (sw.steer.length ? `FROM THE OWNER, since the start (follow these):\n${sw.steer.map((x) => "- " + x).join("\n")}\n\n` : "") +
      (lessons.length ? `LESSONS (from this swarm and earlier ones):\n${lessons.map((x) => "- " + x).join("\n")}\n\n` : "") +
      (Object.keys(sw.files).length ? `SHARED FILES: ${Object.entries(sw.files).map(([n, c]) => `${n} (${c.length} characters)`).join(", ")}\n\n` : "") +
      (earlier.length ? `EARLIER CYCLES, in short:\n${earlier.map((t) => `- cycle ${t.cycle + 1}, ${t.role}: ${t.state}. ${clip(t.result, 300)}`).join("\n")}\n\n` : "") +
      (last.length ? `THE LAST CYCLE'S RESULTS:\n${last.map((t) => `## ${t.role} (${t.state})\nTask: ${clip(t.task, 400)}\nResult: ${t.result}`).join("\n\n")}\n\n` : "Nothing has been done yet: this is the first cycle.\n\n") +
      (nodes.length ? `Tasks go to the owner's machines this cycle: ${nodes.map((n) => n.name).join(", ")}.\n` : "") +
      (sw.cycle + 1 >= sw.cycles ? "This is the LAST cycle allowed: reply with done true and the final report.\n" : "");
    let plan = null;
    try {
      const reply = await this.model(sw.model, [{ role: "system", content: head }, { role: "user", content: body }], 3000);
      sw.calls += 1;
      plan = this.swarmPlan(reply, sw.workers);
      if (!plan) say("the coordinator's reply could not be read; asking again");
    } catch (e) {
      say("the coordinator's model call failed: " + clip(e?.message ?? e, 200));
    }
    if (!plan) {
      sw.fails = (sw.fails ?? 0) + 1;
      if (sw.fails >= 3) {
        sw.state = "failed";
        sw.summary = sw.summary || "The coordinator could not plan three times in a row. " + (sw.log.at(-1)?.text ?? "");
      }
      await this.saveSwarm(sw, list);
      return 30000;
    }
    sw.fails = 0;
    if (plan.lessons.length) sw.lessons = [...new Set([...sw.lessons, ...plan.lessons])].slice(-24);
    if (plan.summary) sw.summary = plan.summary;
    const lastCycle = sw.cycle + 1 >= sw.cycles;
    if (plan.done || !plan.tasks.length || lastCycle) {
      sw.state = plan.done ? "done" : "stopped";
      if (!plan.done) sw.summary = (sw.summary ? sw.summary + "\n\n" : "") + (lastCycle ? `(Stopped at its limit of ${sw.cycles} cycles.)` : "(Stopped: the coordinator handed out no more tasks.)");
      sw.finished = Date.now();
      say(plan.done ? "goal met" : "stopped");
      // what this swarm learned is there for the next one
      if (sw.lessons.length) await this.store.put("lessons", [...new Set([...((await this.store.get("lessons")) ?? []), ...sw.lessons])].slice(-LESSONS_MAX));
      await this.saveSwarm(sw, list);
      return SWARM_TICK_MS;
    }
    if (last.length) sw.cycle += 1;
    const room = Math.max(0, QUEUE_MAX - index.filter((j) => j.state === "queued").length);
    const shared = Object.keys(sw.files).length ? `\n\nThe swarm's shared files are beside you: ${Object.keys(sw.files).join(", ")}. Read what you need; write your results as files.` : "\n\nWrite your results as files: they are shared with the rest of the swarm.";
    const known = sw.lessons.length ? `\n\nLessons so far:\n${sw.lessons.slice(-8).map((x) => "- " + x).join("\n")}` : "";
    let n = 0;
    for (const t of plan.tasks.slice(0, Math.max(1, room))) {
      const node = nodes.length ? nodes[n % nodes.length] : null;
      const brief = `You are ${MIND_NAMES[n] ?? "mind" + (n + 1)}, "${t.role}", one mind of a swarm working toward this goal:\n${clip(sw.goal, 1500)}\n\nYOUR TASK:\n${t.task}${shared}${known}\n\nEnd with a short written result: what you did, what you found, which files you wrote.`;
      const id = await this.enqueue(index, brief, sw.model, "", !!node, node?.id ?? "", "");
      t.role = `${MIND_NAMES[n] ?? "mind" + (n + 1)} · ${t.role}`;
      const job = await this.store.get("job:" + id);
      job.swarm = sw.id;
      if (!node) job.files = { ...sw.files };
      await this.store.put("job:" + id, job);
      sw.tasks.push({ cycle: sw.cycle, role: t.role, task: t.task, job: id, node: node?.name ?? "", state: "working", result: "", started: Date.now(), finished: 0 });
      n++;
    }
    sw.tasks = sw.tasks.slice(-80);
    sw.phase = "work";
    say(`cycle ${sw.cycle + 1}: ${n} task${n === 1 ? "" : "s"} handed out (${plan.tasks.slice(0, n).map((t) => t.role).join(", ")})`);
    await this.saveSwarm(sw, list);
    return 1000;
  }

  /// A new swarm from what the owner set. {err} in words when it cannot start.
  async swarmStart(body) {
    const goal = String(body.goal ?? "").trim();
    const model = String(body.model ?? "");
    if (goal.length < 8 || goal.length > 12000) return { err: "the goal must be 8 to 12000 characters" };
    if (!model.startsWith("@")) return { err: "model must be a Workers AI model id" };
    const list = await this.swarms();
    if (list.filter((x) => x.state === "running" || x.state === "paused").length >= 2) return { err: "two swarms are already at work; stop one first" };
    // room is made by letting the oldest ended swarm go
    while (list.length >= SWARMS_MAX) {
      const old = list.find((x) => !["running", "paused"].includes(x.state));
      if (!old) return { err: `the harness keeps ${SWARMS_MAX} swarms; delete one` };
      list.splice(list.indexOf(old), 1);
      await this.store.delete("swarm:" + old.id);
    }
    const int = (v, lo, hi, d) => Math.min(hi, Math.max(lo, Math.floor(Number(v)) || d));
    const now = Date.now();
    const sw = {
      id: now.toString(36) + hex(crypto.getRandomValues(new Uint8Array(3))),
      name: clip(String(body.name ?? "").replace(/\s+/g, " ").trim(), 60) || clip(goal.replace(/\s+/g, " "), 48),
      goal, model,
      workers: int(body.minds ?? body.workers, 1, SWARM_WORKERS_MAX, 3),
      cycles: int(body.rounds ?? body.cycles, 1, SWARM_CYCLES_MAX, 8),
      where: body.where === "mesh" ? "mesh" : "harness",
      state: "running", phase: "plan", cycle: 0, tasks: [], lessons: [], steer: [], files: {}, log: [{ at: now, text: "deployed" }], summary: "", note: "", calls: 0, created: now, updated: now, finished: 0,
    };
    await this.saveSwarm(sw, list);
    await this.store.setAlarm(Date.now() + 100);
    return { id: sw.id };
  }

  // ---------------------------------------------------------------- the mesh

  async nodes() {
    return (await this.store.get("nodes")) ?? [];
  }

  async nodeCounts() {
    const list = await this.nodes();
    const now = Date.now();
    return { count: list.length, online: list.filter((n) => now - n.seen < NODE_ONLINE_MS).length, max: NODES_MAX };
  }

  /// A node's own words about itself, cut to what is kept. {err} in words when it cannot be kept.
  nodeFrom(id, body, old) {
    const name = clip(String(body.name ?? "").replace(/\s+/g, " ").trim(), 48);
    if (!name) return { err: "a node needs a name" };
    const kind = String(body.kind ?? "");
    if (!NODE_KINDS.has(kind)) return { err: "kind must be desk, server or web" };
    const mcp = Array.isArray(body.mcp) ? body.mcp.slice(0, 16).map((x) => clip(String(x), 32)).filter(Boolean) : [];
    const now = Date.now();
    return { id, name, kind, os: clip(String(body.os ?? ""), 24), version: clip(String(body.version ?? ""), 24), runs: body.runs === true, browser: body.browser === true, garrett: body.garrett === true, mcp, first: old?.first ?? now, seen: now };
  }

  async settings() {
    return (await this.store.get("settings")) ?? {};
  }

  // ---------------------------------------------------------------- routes

  async status(who) {
    const [cfg, usage, index, py, g, chats, sched] = [await this.cfg(), await this.usage(), await this.jobs(), null, await this.store.get("garrett"), await this.convs(), await this.schedules()];
    return {
      ok: true,
      version: VERSION,
      ai: !!this.env.AI,
      account: who.account,
      limits: cfg,
      usage,
      storage_bytes: index.reduce((n, j) => n + (j.bytes ?? 0), 0) + chats.reduce((n, c) => n + (c.bytes ?? 0), 0),
      queue: { waiting: index.filter((j) => j.state === "queued").length, running: index.filter((j) => j.state === "running").length, max: QUEUE_MAX, kept: index.length, keep: JOBS_KEEP, local: index.filter((j) => j.local && ["queued", "running"].includes(j.state)).length },
      schedules: { count: sched.length, max: SCHEDULES_MAX, shortest_s: EVERY_MIN_S },
      swarms: { count: (await this.swarms()).length, running: (await this.swarms()).filter((x) => x.state === "running").length, max: SWARMS_MAX },
      chats: { count: chats.length, max: CONVS_MAX },
      nodes: await this.nodeCounts(),
      python: { worker: !!this.env.LOADER },
      garrett: g ? { connected: true, host: new URL(g.url).hostname, tools: g.tools ?? 0 } : { connected: false },
      garrett_dashboard: GARRETT_DASHBOARD,
      mcp: (await this.mcpServers()).map((x) => ({ name: x.name, host: new URL(x.url).hostname, tools: x.tools ?? 0 })),
      clef: CLEF_MODEL,
    };
  }

  // ---------------------------------------------------------------- the socket (suggestions for the editor)

  /// A WebSocket for the page's editor. A browser cannot send a login header with one, so the socket is taken
  /// first and its FIRST message must be the login: until then it is answered nothing. Sockets hibernate, so an
  /// idle one costs the account nothing.
  socket(req) {
    if (new URL(req.url).pathname !== "/v1/socket") return bad("not found", 404);
    if (this.state.getWebSockets().length >= SOCKETS_MAX) return bad("too many open sockets", 429);
    const pair = new WebSocketPair();
    this.state.acceptWebSocket(pair[1]);
    pair[1].serializeAttachment({ url: req.url, ok: false });
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws, data) {
    let m;
    try {
      m = JSON.parse(typeof data === "string" ? data : new TextDecoder().decode(data));
    } catch {
      return ws.close(4400, "not JSON");
    }
    const att = ws.deserializeAttachment() ?? {};
    try {
      if (!att.ok) {
        const who = await this.owner(new Request(att.url, { headers: { authorization: "Bearer " + String(m?.auth ?? "") } }));
        if (!who) return ws.close(4401, "unauthorized");
        ws.serializeAttachment({ ...att, ok: true });
        return ws.send(JSON.stringify({ hello: VERSION }));
      }
      if (m?.op === "complete") return ws.send(JSON.stringify({ id: m.id, ...(await this.complete(m)) }));
      ws.send(JSON.stringify({ id: m?.id, err: "unknown op" }));
    } catch (e) {
      try {
        ws.send(JSON.stringify({ id: m?.id, err: clip(e?.message ?? e, 200) }));
      } catch {}
    }
  }

  webSocketClose(ws) {
    try {
      ws.close();
    } catch {}
  }

  /// What a model would type next at the caret: {text}, or {text: "", why} when the day's limit is spent.
  async complete(b) {
    const prefix = String(b?.prefix ?? "").slice(-6000);
    const suffix = String(b?.suffix ?? "").slice(0, 1500);
    const model = String(b?.model ?? "");
    if (!model.startsWith("@") || !prefix.trim()) return { text: "" };
    // the buffer: the same text around the caret is answered from memory
    const key = model + "\u0000" + prefix.slice(-800) + "\u0000" + suffix.slice(0, 120);
    this.completions ??= new Map();
    if (this.completions.has(key)) return { text: this.completions.get(key), kept: true };
    const why = await this.spent(true);
    if (why) return { text: "", why };
    const reply = await this.model(model, [
      { role: "system", content: "You complete code inside an editor. You are given the text BEFORE the cursor and the text AFTER it. Reply with the text to insert at the cursor between <ins> and </ins>, and nothing else: no explanation, no code fence, nothing that is already before or after the cursor. What is between the tags is taken exactly as it is: when the insertion starts on a NEW line, begin with a line break right after <ins>. Finish the statement or the small block being typed, a dozen lines at most, and never repeat code the file already has. If nothing should be inserted, reply <ins></ins>." },
      { role: "user", content: `File: ${clip(String(b?.path ?? ""), 200)}\n<before>\n${prefix}</before>\n<after>\n${suffix}</after>` },
    ], 192);
    const text = tidyCompletion(reply, prefix, suffix);
    this.completions.set(key, text);
    if (this.completions.size > 300) this.completions.delete(this.completions.keys().next().value);
    return { text };
  }

  /// One git smart-HTTP request, passed on for the page's clone, fetch or push: a browser cannot make it itself
  /// (git hosts send no CORS headers). Only the three git endpoints of a public https host are reached.
  async git(body) {
    let u;
    try {
      u = new URL(String(body.url ?? ""));
    } catch {
      return bad("url is not a URL");
    }
    const service = u.searchParams.get("service") ?? "";
    const refs = u.pathname.endsWith("/info/refs") && (service === "git-upload-pack" || service === "git-receive-pack");
    const rpc = u.pathname.endsWith("/git-upload-pack") || u.pathname.endsWith("/git-receive-pack");
    if (u.protocol !== "https:" || privateHost(u.hostname) || !(refs || rpc)) return bad("only git's own endpoints on a public https host are reached");
    const method = rpc ? "POST" : "GET";
    const headers = { "user-agent": "git/veil-web" };
    for (const k of ["accept", "content-type", "git-protocol", "authorization"]) {
      const v = body.headers?.[k];
      if (typeof v === "string" && v.length < 4000) headers[k] = v;
    }
    const sent = rpc ? Uint8Array.from(atob(String(body.body ?? "")), (c) => c.charCodeAt(0)) : undefined;
    const r = await fetch(u.toString(), { method, headers, body: sent, redirect: "follow", signal: AbortSignal.timeout(120000) });
    await this.spend(0, (sent?.length ?? 0) + (Number(r.headers.get("content-length")) || 0));
    return new Response(r.body, { status: 200, headers: { "content-type": "application/octet-stream", "x-git-status": String(r.status), "x-git-type": r.headers.get("content-type") ?? "", "cache-control": "no-store" } });
  }

  async route(req) {
    if ((req.headers.get("upgrade") ?? "").toLowerCase() === "websocket") return this.socket(req);
    const who = await this.owner(req);
    if (!who) return bad("unauthorized: log in with the Cloudflare account that owns this Worker", 401);
    const url = new URL(req.url);
    const seg = url.pathname.split("/").filter(Boolean);
    if (seg[0] !== "v1") return bad("not found", 404);
    const method = req.method.toUpperCase();
    const body = method === "POST" ? await req.json().catch(() => null) : null;
    if (method === "POST" && (body === null || typeof body !== "object")) return bad("malformed JSON body");
    const at = seg.slice(1).join("/");

    if (method === "GET" && at === "status") return say(await this.status(who));
    if (method === "GET" && at === "me") {
      const [u, a] = [await this.api(who.token, "GET", "/user"), await this.api(who.token, "GET", `/accounts/${who.account}`)];
      return say({ ok: true, email: String(u?.result?.email ?? ""), account_name: String(a?.result?.name ?? ""), account: who.account });
    }
    if (method === "POST" && at === "config") {
      const cfg = await this.cfg();
      for (const k of Object.keys(DEFAULTS)) {
        if (body[k] === undefined) continue;
        const n = Number(body[k]);
        if (!Number.isFinite(n) || n < 1) return bad(`${k} must be a positive number`);
        cfg[k] = Math.min(CEIL[k], Math.floor(n));
      }
      await this.store.put("cfg", cfg);
      await this.store.put("jobs", await this.evict(await this.jobs()));
      return say(await this.status(who));
    }

    if (method === "POST" && at === "chat") {
      if (!this.env.AI) return bad("this Worker has no AI binding", 500);
      const model = String(body.model ?? "");
      if (!model.startsWith("@")) return bad("model must be a Workers AI model id");
      if (!Array.isArray(body.messages) || body.messages.length === 0) return bad("messages must be a non-empty list");
      const why = await this.spent(true);
      if (why) return bad(why, 429);
      const maxTokens = Math.min(MAX_TOKENS_CEIL, Math.max(16, Number.parseInt(body.max_tokens, 10) || 2048));
      const messages = body.messages.map((m) => ({ role: String(m?.role ?? "user"), content: String(m?.content ?? "") }));
      const sent = messages.reduce((n, m) => n + m.content.length, 0);
      const extra = {};
      if (body.extra && typeof body.extra === "object") for (const [k, v] of Object.entries(body.extra)) if (EXTRA_KEYS.has(k)) extra[k] = v;
      try {
        if (body.stream === true) {
          const stream = await this.env.AI.run(model, { messages, max_tokens: maxTokens, stream: true, ...extra });
          if (stream instanceof ReadableStream) {
            let got = 0;
            const meter = new TransformStream({ transform: (chunk, c) => { got += chunk.byteLength ?? chunk.length ?? 0; c.enqueue(chunk); }, flush: () => this.spend(1, sent + got) });
            return new Response(stream.pipeThrough(meter), { headers: { "content-type": "text/event-stream", "cache-control": "no-store" } });
          }
          await this.spend(1, sent + JSON.stringify(stream ?? "").length);
          return say({ ok: true, reply: stream });
        }
        const reply = await this.env.AI.run(model, { messages, max_tokens: maxTokens, ...extra });
        await this.spend(1, sent + JSON.stringify(reply ?? "").length);
        return say({ ok: true, reply });
      } catch (e) {
        return bad(clip(e?.message ?? e, 600), 502);
      }
    }
    if (method === "POST" && (at === "fetch" || at === "search")) {
      const why = await this.spent(false);
      if (why) return bad(why, 429);
      try {
        return say(at === "fetch" ? { ok: true, ...(await this.httpCall(body)) } : { ok: true, results: await this.search(body.q) });
      } catch (e) {
        return bad(clip(e?.message ?? e, 300), /private|not a URL|only http|not allowed|empty/.test(String(e?.message)) ? 400 : 502);
      }
    }

    // Swarms: deploy one toward a goal, watch it, steer it, stop it.
    if (at === "swarms" && method === "GET") return say({ ok: true, swarms: await this.swarms(), max: SWARMS_MAX, workers_max: SWARM_WORKERS_MAX, cycles_max: SWARM_CYCLES_MAX, lessons: (await this.store.get("lessons")) ?? [] });
    if (at === "swarms" && method === "POST") {
      const made = await this.swarmStart(body);
      return made.err ? bad(made.err) : say({ ok: true, id: made.id });
    }
    if (seg[1] === "swarms" && seg.length === 3) {
      const list = await this.swarms();
      const sw = await this.store.get("swarm:" + seg[2]);
      if (!sw) return bad("no such swarm", 404);
      if (method === "GET") return say({ ok: true, swarm: sw });
      if (method === "DELETE") {
        await this.store.delete("swarm:" + sw.id);
        await this.store.put("swarms", list.filter((x) => x.id !== sw.id));
        return say({ ok: true });
      }
      if (method === "POST") {
        const op = String(body.op ?? "");
        const live = ["running", "paused"].includes(sw.state);
        if (op === "set_goal") {
          const goal = String(body.goal ?? body.text ?? "").trim();
          if (goal.length < 8 || goal.length > 12000) return bad("the goal must be 8 to 12000 characters");
          if (!live) return bad("that swarm has ended");
          sw.goal = goal;
          sw.log.push({ at: Date.now(), text: "the owner set a new goal" });
        } else if (op === "steer" || op === "say") {
          const text = clip(String(body.text ?? "").trim(), 1000);
          if (!text) return bad("say what the swarm should take into account");
          if (!live) return bad("that swarm has ended");
          sw.steer = [...sw.steer, text].slice(-12);
          sw.log.push({ at: Date.now(), text: "the owner: " + clip(text, 200) });
        } else if (op === "pause" && sw.state === "running") sw.state = "paused";
        else if (op === "resume" && sw.state === "paused") sw.state = "running";
        else if (op === "stop" && live) {
          sw.state = "stopped";
          sw.finished = Date.now();
          sw.summary = (sw.summary ? sw.summary + "\n\n" : "") + "(Stopped by the owner.)";
          sw.log.push({ at: Date.now(), text: "stopped by the owner" });
        } else return bad("op must be say, set_goal, pause, resume or stop, and fit the swarm's state");
        await this.saveSwarm(sw, list);
        if (sw.state === "running") await this.store.setAlarm(Date.now() + 100);
        return say({ ok: true, swarm: sw });
      }
    }

    if (at === "jobs" && method === "GET") return say({ ok: true, jobs: await this.jobs(), max: QUEUE_MAX });
    if (at === "jobs" && method === "POST") {
      const task = String(body.task ?? "").trim();
      const model = String(body.model ?? "");
      if (!task || task.length > 8000) return bad("task must be 1 to 8000 characters");
      if (!model.startsWith("@")) return bad("model must be a Workers AI model id");
      const index = await this.jobs();
      if (index.filter((j) => j.state === "queued").length >= QUEUE_MAX) return bad(`the queue is full (${QUEUE_MAX} jobs waiting); a job joins when one starts`, 429);
      const node = String(body.node ?? "");
      const from = String(body.from ?? "");
      if (node && !(await this.nodes()).some((n) => n.id === node)) return bad("no such node: ask for the nodes first", 404);
      if (from && !NODE_ID.test(from)) return bad("from must be a node id");
      const local = body.local === true || node !== "";
      const id = await this.enqueue(index, task, model, "", local, node, from);
      if (!local) await this.store.setAlarm(Date.now() + 100);
      return say({ ok: true, id, local, node, position: index.filter((j) => j.state === "queued").length });
    }

    // The mesh: who is here.
    if (at === "nodes" && method === "GET") {
      const now = Date.now();
      const index = await this.jobs();
      const waiting = (id) => index.filter((j) => j.local && j.node === id && ["queued", "running"].includes(j.state)).length;
      return say({ ok: true, now, online_ms: NODE_ONLINE_MS, max: NODES_MAX, nodes: (await this.nodes()).map((n) => ({ ...n, online: now - n.seen < NODE_ONLINE_MS, waiting: waiting(n.id) })) });
    }
    if (seg[1] === "nodes" && seg.length === 3 && (method === "POST" || method === "DELETE")) {
      if (!NODE_ID.test(seg[2])) return bad("a node id is 8 to 32 lower-case letters and digits");
      const list = await this.nodes();
      const old = list.find((n) => n.id === seg[2]);
      const rest = list.filter((n) => n.id !== seg[2]);
      if (method === "DELETE") {
        await this.store.put("nodes", rest);
        return say({ ok: true, deleted: seg[2] });
      }
      const node = this.nodeFrom(seg[2], body, old);
      if (node.err) return bad(node.err);
      rest.push(node);
      rest.sort((a, b) => a.first - b.first);
      while (rest.length > NODES_MAX) rest.splice(rest.indexOf(rest.filter((n) => n.id !== node.id).reduce((a, b) => (a.seen <= b.seen ? a : b))), 1);
      await this.store.put("nodes", rest);
      return say({ ok: true, id: node.id, nodes: rest.length });
    }

    // Shared settings: the last write of a name wins.
    if (at === "settings" && method === "GET") return say({ ok: true, now: Date.now(), settings: await this.settings(), max: SETTINGS_MAX });
    if (at === "settings" && method === "POST") {
      const all = await this.settings();
      const now = Date.now();
      const set = body.set && typeof body.set === "object" ? Object.entries(body.set) : [];
      for (const [k, v] of set) {
        if (!SETTING_NAME.test(k)) return bad(`"${clip(k, 60)}" is not a setting name: a letter, then letters, digits, . or _ (48 at most)`);
        if (!["string", "number", "boolean"].includes(typeof v) || (typeof v === "number" && !Number.isFinite(v))) return bad(`${k} must be text, a number or true/false`);
        if (typeof v === "string" && v.length > SETTING_BYTES) return bad(`${k} is longer than ${SETTING_BYTES} characters`);
        all[k] = { v, at: now };
      }
      for (const k of Array.isArray(body.del) ? body.del : []) delete all[String(k)];
      if (Object.keys(all).length > SETTINGS_MAX) return bad(`this harness keeps at most ${SETTINGS_MAX} settings`, 429);
      await this.store.put("settings", all);
      return say({ ok: true, now, settings: all });
    }

    // The connections kept here, whole. The caller is the owner (every route's check): it is how another veil of
    // theirs uses the same Agent Garrett and the same MCP servers without the key being typed again.
    if (at === "share" && method === "GET") {
      const g = await this.store.get("garrett");
      return say({ ok: true, garrett: g ? { url: g.url, token: g.token, tools: g.tools ?? 0, at: g.at ?? 0 } : null, mcp: (await this.mcpServers()).map((x) => ({ name: x.name, url: x.url, token: x.token ?? "" })) });
    }

    // The owner's machine: it asks for the local jobs, says when it takes one, and posts how each ended.
    if (at === "local" && method === "GET") {
      const index = await this.jobs();
      const me = url.searchParams.get("node") ?? "";
      const jobs = [];
      // a job addressed to a node goes to that node only; one addressed to nobody goes to whoever asks
      for (const row of index.filter((j) => j.local && ["queued", "running"].includes(j.state) && (!j.node || j.node === me))) {
        const job = await this.store.get("job:" + row.id);
        if (job) jobs.push({ id: job.id, t: job.created, task: job.task, model: job.model, state: job.state, node: job.node ?? "", from: job.from ?? "" });
      }
      return say({ ok: true, jobs });
    }
    if (seg[1] === "local" && seg.length === 3 && method === "POST") {
      const index = await this.jobs();
      const row = index.find((j) => j.id === seg[2]);
      const job = row && row.local ? await this.store.get("job:" + row.id) : null;
      if (!job) return bad("no such local job", 404);
      if (!["queued", "running"].includes(job.state)) return bad("that job has already ended", 409);
      if (body.started === true) {
        if (job.state === "queued") {
          job.state = "running";
          job.started = Date.now();
        }
        job.note = LOCAL_RUNNING;
      } else {
        if (typeof body.ok !== "boolean") return bad("send {started: true}, or {ok, result}");
        const text = clip(String(body.result ?? ""), RESULT_MAX);
        job.state = body.ok ? "done" : "failed";
        if (body.ok) job.result = text;
        else job.error = text || "the owner's machine reported a failure";
        job.note = "";
        if (!job.started) job.started = Date.now();
        job.finished = Date.now();
      }
      await this.saveJob(job, index);
      return say({ ok: true, id: job.id, state: job.state });
    }
    if (seg[1] === "jobs" && seg.length === 3) {
      const index = await this.jobs();
      const row = index.find((j) => j.id === seg[2]);
      if (!row) return bad("no such job", 404);
      if (method === "GET") return say({ ok: true, job: await this.store.get("job:" + row.id) });
      if (method === "DELETE") {
        index.splice(index.indexOf(row), 1);
        await this.store.delete("job:" + row.id);
        await this.store.put("jobs", index);
        return say({ ok: true, deleted: row.id });
      }
    }

    if (method === "POST" && at === "python/enable") {
      if (this.env.LOADER) return say({ ok: true, already: true });
      const u = await this.selfUpdate(who, true);
      return u.err ? bad(u.err + ". Cloudflare offers the Worker Loader on the Workers Paid plan; without it, Python in a chat runs in your browser.", 502) : say({ ok: true, version: u.version });
    }
    if (method === "POST" && at === "python/run") {
      const why = await this.spent(false);
      if (why) return bad(why, 429);
      return say({ ok: true, run: await this.pythonRun(body) });
    }

    if (method === "POST" && at === "garrett") {
      // {key}: the key Agent Garrett's dashboard gives, for the hosted agent. {url, token}: an agent of your own.
      const key = String(body.key ?? "").trim();
      const u = key ? this.env.GARRETT_MCP || GARRETT_MCP : String(body.url ?? "").trim();
      const token = key || String(body.token ?? "");
      if (!u) {
        await this.store.delete("garrett");
        return say(await this.status(who));
      }
      if (key && !/^gtt_[0-9a-f]{64}$/.test(key)) return bad("that is not an Agent Garrett key. It starts with gtt_ and comes from " + GARRETT_DASHBOARD);
      let parsed;
      try {
        parsed = new URL(u);
      } catch {
        return bad("that is not a URL");
      }
      if (parsed.protocol !== "https:" || privateHost(parsed.hostname)) return bad("Agent Garrett's address must be a public https URL");
      if (token.length < 8) return bad("Agent Garrett's token is missing");
      // the same check the desktop veil makes: an MCP handshake, then the tool list. No tool is run.
      const g = { url: parsed.toString(), token };
      const hello = await this.garrettRpc(g, "initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "nl-veil-web", version: VERSION } });
      const listed = hello.err ? hello : await this.garrettRpc(g, "tools/list", {});
      const count = Array.isArray(listed.j?.result?.tools) ? listed.j.result.tools.length : 0;
      if (listed.err || count === 0) return bad("Agent Garrett could not verify this " + (key ? "key. Check your plan, that your agent is ready, and the key in its dashboard" : "address and token") + (listed.err ? ` (${listed.err})` : ""), 502);
      await this.store.put("garrett", { ...g, tools: count, at: Date.now() });
      return say(await this.status(who));
    }
    if (method === "POST" && at === "garrett/call") {
      const m = String(body.method ?? "");
      if (m !== "tools/list" && m !== "tools/call") return bad("method must be tools/list or tools/call");
      return say({ ok: true, text: await this.garrettCall(m, body.params && typeof body.params === "object" ? body.params : {}, body.query) });
    }

    if (method === "POST" && at === "complete") return say({ ok: true, ...(await this.complete(body)) });
    if (method === "POST" && at === "git") return this.git(body);

    if (method === "POST" && at === "clef") {
      const why = await this.spent(true);
      if (why) return say({ ok: true, probs: null, why });
      return say({ ok: true, probs: await this.clef(who, String(body.state ?? ""), body.questions) });
    }

    if (at === "mcp" && method === "GET") return say({ ok: true, servers: (await this.mcpServers()).map((x) => ({ name: x.name, url: x.url, tools: x.tools ?? 0 })), max: MCP_MAX });
    if (at === "mcp" && method === "POST") {
      const name = String(body.name ?? "").trim().toLowerCase();
      if (!/^[a-z][a-z0-9_-]{0,23}$/.test(name) || name === "garrett") return bad("give the server a short name: a letter, then letters, digits, - or _ (24 at most)");
      let parsed;
      try {
        parsed = new URL(String(body.url ?? "").trim());
      } catch {
        return bad("that is not a URL");
      }
      if (parsed.protocol !== "https:" || privateHost(parsed.hostname)) return bad("an MCP server's address must be a public https URL");
      const list = await this.mcpServers();
      if (list.length >= MCP_MAX && !list.some((x) => x.name === name)) return bad(`this harness keeps at most ${MCP_MAX} MCP servers; remove one first`, 429);
      const server = { name, url: parsed.toString(), token: String(body.token ?? "") };
      const hello = await this.mcpHello(server);
      if (hello.err) return bad(`that server did not answer as MCP (${hello.err})`, 502);
      const kept = { ...server, session: hello.session, tools: hello.tools.length, at: Date.now() };
      await this.store.put("mcp", [...list.filter((x) => x.name !== name), kept]);
      return say(await this.status(who));
    }
    if (seg[1] === "mcp" && seg.length === 3 && method === "DELETE") {
      const list = await this.mcpServers();
      await this.store.put("mcp", list.filter((x) => x.name !== seg[2]));
      return say(await this.status(who));
    }
    if (method === "POST" && at === "mcp/call") {
      const m = String(body.method ?? "");
      if (m !== "tools/list" && m !== "tools/call") return bad("method must be tools/list or tools/call");
      return say({ ok: true, text: await this.mcpCall(body.server, m, body.params && typeof body.params === "object" ? body.params : {}, body.query) });
    }

    if (method === "GET" && at === "models") return say({ ok: true, models: await this.models(who) });
    if (method === "GET" && at === "context") return say({ ok: true, ...(await this.context()) });
    if (method === "POST" && at === "update") {
      const u = await this.selfUpdate(who);
      return u.err ? bad(u.err, 502) : say({ ok: true, was: VERSION, now: u.version, same: u.same === true });
    }

    if (at === "schedules" && method === "GET") return say({ ok: true, schedules: await this.schedules(), max: SCHEDULES_MAX });
    if (at === "schedules" && method === "POST") {
      const task = String(body.task ?? "").trim();
      const model = String(body.model ?? "");
      const every = Math.floor(Number(body.every_s));
      if (!task || task.length > 8000) return bad("task must be 1 to 8000 characters");
      if (!model.startsWith("@")) return bad("model must be a Workers AI model id");
      if (!Number.isFinite(every) || every < EVERY_MIN_S || every > 30 * 86400) return bad(`every_s must be between ${EVERY_MIN_S} seconds and 30 days`);
      const list = await this.schedules();
      if (list.length >= SCHEDULES_MAX) return bad(`this harness keeps at most ${SCHEDULES_MAX} schedules; delete one first`, 429);
      const s = { id: "s" + Date.now().toString(36) + hex(crypto.getRandomValues(new Uint8Array(2))), task, model, every_s: every, next: Date.now() + every * 1000, created: Date.now(), runs: 0, last_job: "" };
      list.push(s);
      await this.store.put("schedules", list);
      await this.rearm(1000, list.reduce((t, x) => Math.min(t, x.next), Infinity));
      return say({ ok: true, schedule: s });
    }
    if (seg[1] === "schedules" && seg.length === 3 && method === "DELETE") {
      const list = await this.schedules();
      const i = list.findIndex((s) => s.id === seg[2]);
      if (i < 0) return bad("no such schedule", 404);
      list.splice(i, 1);
      await this.store.put("schedules", list);
      return say({ ok: true, deleted: seg[2] });
    }

    if (at === "convs" && method === "GET") return say({ ok: true, convs: await this.convs(), max: CONVS_MAX });
    if (seg[1] === "convs" && seg.length === 3) {
      const id = seg[2];
      if (!/^[a-z0-9]{6,24}$/.test(id)) return bad("bad conversation id");
      const list = await this.convs();
      const i = list.findIndex((c) => c.id === id);
      if (method === "GET") return i < 0 ? bad("no such conversation", 404) : say({ ok: true, conv: await this.store.get("conv:" + id) });
      if (method === "DELETE") {
        if (i >= 0) list.splice(i, 1);
        await this.store.delete("conv:" + id);
        await this.store.put("convs", list);
        return say({ ok: true, deleted: id });
      }
      if (method === "POST") {
        const conv = { id, title: clip(String(body.title ?? "Chat"), 120), at: Number(body.at) || Date.now(), msgs: Array.isArray(body.msgs) ? body.msgs : [], files: body.files && typeof body.files === "object" ? body.files : {} };
        const size = JSON.stringify(conv).length;
        if (size > CONV_BYTES_MAX) return bad("this conversation and its files are larger than one the harness keeps (1.5 MB); it stays in this browser only", 413);
        const { storage_max } = await this.cfg();
        const others = list.reduce((n, c) => n + (c.id === id ? 0 : c.bytes ?? 0), 0);
        if (others + size > storage_max) return bad("the harness's storage limit is reached; delete old chats or raise the limit", 413);
        // a copy from another browser that is newer than what is being sent wins: the sender is told to take it
        if (i >= 0 && list[i].at > conv.at) return say({ ok: true, stale: true, at: list[i].at });
        const row = { id, title: conv.title, at: conv.at, bytes: size };
        if (i >= 0) list[i] = row;
        else list.push(row);
        list.sort((a, b) => b.at - a.at);
        while (list.length > CONVS_MAX) await this.store.delete("conv:" + list.pop().id);
        await this.store.put("conv:" + id, conv);
        await this.store.put("convs", list);
        return say({ ok: true, at: conv.at });
      }
    }
    return bad("not found", 404);
  }
}
