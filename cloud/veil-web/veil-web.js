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
// Python source's cached copy, Agent Garrett's address and token. All of it in the user's account.
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
//   POST jobs  {task, model}    queue a job          DELETE jobs/<id>   cancel or delete one
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

export const VERSION = "4";
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
const FETCH_TEXT_MAX = 200000;
const MAX_TOKENS_CEIL = 16384;
const AUTH_TTL_MS = 5 * 60 * 1000;
const DENY_TTL_MS = 60 * 1000; // a refused token is not asked about again for this long
const MODELS_TTL_MS = 15 * 60 * 1000;
const LLMS_TTL_MS = 24 * 3600 * 1000;
const LLMS_DIGEST_MAX = 3500;
export const SCHEDULES_MAX = 12;
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

/// The text of a model answer, whatever envelope the model's family uses, reasoning blocks removed.
export function answerText(r) {
  const flat = (c) => (typeof c === "string" ? c : Array.isArray(c) ? c.map((p) => (typeof p === "string" ? p : (p?.text ?? p?.content ?? ""))).join("") : "");
  let t = "";
  if (typeof r === "string") t = r;
  else if (r && typeof r === "object") {
    for (const c of [r.response, r.result?.response, r.output_text, r.choices?.[0]?.message?.content, r.choices?.[0]?.text]) {
      t = flat(c);
      if (t) break;
    }
  }
  return t.replace(/<think>[\s\S]*?<\/think>/gi, "").replace(/<think>[\s\S]*$/i, "").trim();
}

/// The first JSON object in a reply and where it starts (cloud/tot.js firstJson).
function firstJson(text) {
  const s = String(text ?? "");
  for (let from = s.indexOf("{"); from >= 0; from = s.indexOf("{", from + 1)) {
    let depth = 0, inStr = false, esc = false;
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
      else if (c === "}" && --depth === 0) {
        try {
          const v = JSON.parse(s.slice(from, i + 1));
          if (v && typeof v === "object" && !Array.isArray(v)) return v;
        } catch {}
        break;
      }
    }
  }
  return null;
}

/// What a job's reply asks for: {tool, args} or null when it is the answer.
export function parseAction(reply, known) {
  let c = firstJson(reply);
  if (!c) return null;
  if (Array.isArray(c.tool_calls) && c.tool_calls[0] && typeof c.tool_calls[0] === "object") c = c.tool_calls[0];
  if (c.function && typeof c.function === "object") c = c.function;
  const name = [c.tool, c.name, c.tool_name].find((v) => typeof v === "string" && v.length > 0);
  if (!name || !(known.includes(name) || typeof c.tool === "string")) return null;
  let args = [c.args, c.arguments, c.parameters, c.input].find((v) => v !== undefined && v !== null);
  if (typeof args === "string") {
    try {
      args = JSON.parse(args);
    } catch {
      args = {};
    }
  }
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    // a model that writes {"tool": "swarm", "task": "...", "angles": [...]} means those fields as the arguments
    const skip = new Set(["tool", "name", "tool_name", "args", "arguments", "parameters", "input", "type", "id"]);
    args = {};
    // and one that drops a quote writes the first key as `args: {url`: the name after the brace is the key
    for (const [k, v] of Object.entries(c)) if (!skip.has(k)) args[/^(?:args|arguments|parameters|input)\W+(\w+)$/.exec(k)?.[1] ?? k] = v;
  }
  return { tool: name, args };
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
  write_file: '{"name": "<path>", "content": "<the whole file>"} : keep a file with this job',
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
    const h = new Headers(r.headers);
    for (const [k, v] of Object.entries(headers)) h.set(k, v);
    return new Response(r.body, { status: r.status, headers: h });
  },
};

// ------------------------------------------------------------------------------------------ the Durable Object

export class Harness {
  constructor(state, env) {
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

  async model(model, messages, maxTokens) {
    const sent = messages.reduce((n, m) => n + m.content.length, 0);
    const reply = answerText(await this.env.AI.run(model, { messages, max_tokens: maxTokens }));
    await this.spend(1, sent + reply.length);
    return reply;
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
    const f = String(args.name ?? args.path ?? "").trim().replace(/^\.?\/+/, "");
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
        if (!f || f.length > 200 || f.includes("..")) return "error: bad file name";
        job.files[f] = String(args.content ?? "");
        return `wrote ${f} (${job.files[f].length} characters)`;
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
      { role: "system", content: "You are the veil, working on a queued job with nobody watching. Work the task to the end with these tools:\n" + tools + '\n\nTo use a tool, reply with exactly ONE JSON object and nothing else: {"tool": "<name>", "args": {...}}. When the job is done, or cannot go further, reply in plain text with what was done and what the tool results showed. Never claim something no tool result shows.' + (ref ? "\n\nREFERENCE (from garrettstimpson.ca/llms.txt, about the people and projects behind this veil):\n" + ref : "") },
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
    job.rounds.push({ tool: act.tool, args: act.args, result: clip(result, RESULT_MAX) });
    return false;
  }

  /// Put a job at the back of the queue. The caller has checked there is room. Returns its id.
  async enqueue(index, task, model, schedule = "") {
    const id = Date.now().toString(36) + hex(crypto.getRandomValues(new Uint8Array(3)));
    const job = { id, task, model, schedule, state: "queued", created: Date.now(), started: 0, finished: 0, rounds: [], files: {}, result: "", error: "", note: "", calls: 0 };
    index.push({ id, task: clip(task.replace(/\s+/g, " "), 120), state: "queued", created: job.created, finished: 0, bytes: 0, note: "", schedule });
    await this.saveJob(job, index);
    return id;
  }

  /// Wake when there is next something to do: a job to step (`wait` ms from now) or a schedule coming due.
  async rearm(wait, nextDue) {
    const active = (await this.jobs()).some((j) => ["queued", "running"].includes(j.state));
    const at = Math.min(active ? Date.now() + wait : Infinity, nextDue);
    if (at !== Infinity) await this.store.setAlarm(Math.max(at, Date.now() + 100));
  }

  /// The heartbeat: due schedules queue their jobs, then the job at the head of the queue takes up to ALARM_STEPS
  /// steps, then the next alarm goes on.
  async alarm() {
    const index = await this.jobs();
    const nextDue = await this.runSchedules(index);
    const row = index.find((j) => j.state === "running") ?? index.find((j) => j.state === "queued");
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
      queue: { waiting: index.filter((j) => j.state === "queued").length, running: index.filter((j) => j.state === "running").length, max: QUEUE_MAX, kept: index.length, keep: JOBS_KEEP },
      schedules: { count: sched.length, max: SCHEDULES_MAX, shortest_s: EVERY_MIN_S },
      chats: { count: chats.length, max: CONVS_MAX },
      python: { worker: !!this.env.LOADER },
      garrett: g ? { connected: true, host: new URL(g.url).hostname, tools: g.tools ?? 0 } : { connected: false },
      garrett_dashboard: GARRETT_DASHBOARD,
      mcp: (await this.mcpServers()).map((x) => ({ name: x.name, host: new URL(x.url).hostname, tools: x.tools ?? 0 })),
      clef: CLEF_MODEL,
    };
  }

  async route(req) {
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
      try {
        if (body.stream === true) {
          const stream = await this.env.AI.run(model, { messages, max_tokens: maxTokens, stream: true });
          if (stream instanceof ReadableStream) {
            let got = 0;
            const meter = new TransformStream({ transform: (chunk, c) => { got += chunk.byteLength ?? chunk.length ?? 0; c.enqueue(chunk); }, flush: () => this.spend(1, sent + got) });
            return new Response(stream.pipeThrough(meter), { headers: { "content-type": "text/event-stream", "cache-control": "no-store" } });
          }
          await this.spend(1, sent + JSON.stringify(stream ?? "").length);
          return say({ ok: true, reply: stream });
        }
        const reply = await this.env.AI.run(model, { messages, max_tokens: maxTokens });
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

    if (at === "jobs" && method === "GET") return say({ ok: true, jobs: await this.jobs(), max: QUEUE_MAX });
    if (at === "jobs" && method === "POST") {
      const task = String(body.task ?? "").trim();
      const model = String(body.model ?? "");
      if (!task || task.length > 8000) return bad("task must be 1 to 8000 characters");
      if (!model.startsWith("@")) return bad("model must be a Workers AI model id");
      const index = await this.jobs();
      if (index.filter((j) => j.state === "queued").length >= QUEUE_MAX) return bad(`the queue is full (${QUEUE_MAX} jobs waiting); a job joins when one starts`, 429);
      const id = await this.enqueue(index, task, model);
      await this.store.setAlarm(Date.now() + 100);
      return say({ ok: true, id, position: index.filter((j) => j.state === "queued").length });
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
