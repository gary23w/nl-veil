// veil-web.js - the web veil's worker harness: the model, the hands and the job queue of a veil that lives in
// a browser tab.
//
// WHAT: one Worker ("veil-web") in the user's OWN Cloudflare account, put there by Cloudflare's deploy page
// from this folder (wrangler.jsonc beside this file). The web veil page (docs/chat) keeps the conversation and
// its tool loop in the browser; this Worker is what a tab cannot be:
//   - the MODEL: the account's own AI binding (env.AI). No API key, and the call never crosses the public internet.
//   - the WEB: fetch a page, run a search. A page on another site cannot read those itself (same-origin policy).
//   - the CLOUDFLARE API: it answers no cross-origin page, so the few calls the page needs (who logged in, putting
//     the Python Worker in place) are made here, with the user's own login.
//   - JOBS: work that goes on with the tab closed. A FIFO queue (one job at a time, in arrival order) run by an
//     alarm, each job the same pick-a-tool loop the page runs.
//   - PYTHON: a companion Worker ("veil-web-py": cloud/tot_py.py behind a key) this harness uploads on request.
//   - AGENT GARRETT: the user's own agent, reached over its stateless MCP endpoint (tools/list, tools/call).
//
// WHO MAY CALL IT: only someone logged in to the Cloudflare account that owns it. Every request carries the
// caller's Cloudflare OAuth access token as `Authorization: Bearer`; the harness asks Cloudflare for that
// token's accounts and accepts it only when one of them owns the workers.dev name this Worker answers on.
// There is no shared key to paste or leak. Cross-origin calls are answered for ALLOW_ORIGIN (the page) only.
//
// WHAT IT KEEPS (one Durable Object, "main"): the queue and each job's record, today's usage, the limits, the
// Python Worker's address and key, Agent Garrett's address and token. All of it in the user's account.
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
//   POST python/deploy | python/run {code, files?, args?, packages?}
//   POST garrett {url, token} (empty url forgets it) | garrett/call {method, params}
//
// No imports and no platform globals beyond fetch/Response/crypto, so a test can run this file under node with
// a Map for storage and a scripted env.AI.

export const VERSION = "2";
const API_ROOT = "https://api.cloudflare.com/client/v4";
const PY_SCRIPT = "veil-web-py";
const PY_SOURCE = "https://raw.githubusercontent.com/gary23w/nl-veil/main/cloud/tot_py.py";
const COMPAT_DATE = "2025-09-01";
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
  const allow = String(env.ALLOW_ORIGIN ?? "");
  const h = { vary: "Origin" };
  if (origin && allow && origin === allow) {
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
      if (/duckduckgo\.com|bing\.com|microsoft\.com|go\.microsoft/.test(host) || seen.has(u)) return;
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
  } else {
    const re = /<li class="b_algo"[\s\S]*?<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>([\s\S]*?)<\/li>/g;
    while ((m = re.exec(html)) && out.length < 10) add(m[1], m[2], (/<p[^>]*>([\s\S]*?)<\/p>/.exec(m[3]) ?? [])[1]);
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
  if (!args || typeof args !== "object" || Array.isArray(args)) args = {};
  return { tool: name, args };
}

// The Python Worker's entry: cloud/tot_py.py has no door of its own (the tot runtime reaches it over a service
// binding), so here it sits behind a key only this harness holds.
const PY_ENTRY = `import hmac
from workers import Response, WorkerEntrypoint
import tot_py


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        sent = str(request.headers.get("authorization") or "")
        want = "Bearer " + str(getattr(self.env, "PY_TOKEN", "") or "")
        if len(want) < 40 or not hmac.compare_digest(sent.encode(), want.encode()):
            return Response('{"ok": false, "out": "unauthorized"}', status=401, headers={"content-type": "application/json"})
        return await tot_py.Default.fetch(self, request)
`;

const JOB_TOOLS = {
  web_search: '{"query": "<words>"} : search the web',
  web_fetch: '{"url": "<https://...>"} : read a web page as text',
  http_request: '{"url": "<https://...>", "method": "GET", "headers": {}, "body": ""} : any HTTP call, raw answer',
  write_file: '{"name": "<path>", "content": "<the whole file>"} : keep a file with this job',
  read_file: '{"name": "<path>"} : read one of this job\'s files',
  list_files: "{} : list this job's files",
  run_python: '{"code": "<python>"} : run Python (the job\'s files are beside the script; files it changes are kept)',
  garrett_tools: "{} : list Agent Garrett's tools",
  garrett: '{"name": "<tool>", "args": {...}} : call one of Agent Garrett\'s tools',
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
    if (hit && hit.until > Date.now()) return { token, account: hit.account, sub: hit.sub };
    const m = /^[a-z0-9-]+\.([a-z0-9-]+)\.workers\.dev$/.exec(new URL(req.url).hostname);
    if (!m) return null;
    const owns = async (id) => (await this.api(token, "GET", `/accounts/${id}/workers/subdomain`))?.result?.subdomain === m[1];
    let account = await this.store.get("owner");
    if (account) {
      if (!(await owns(account))) return null;
    } else {
      account = null;
      const list = await this.api(token, "GET", "/accounts?per_page=50");
      for (const a of Array.isArray(list?.result) ? list.result : []) {
        if (/^[0-9a-f]{32}$/.test(String(a?.id)) && (await owns(a.id))) {
          account = a.id;
          break;
        }
      }
      if (!account) return null;
      await this.store.put("owner", account);
    }
    if (this.authed.size > 64) this.authed.clear();
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
    return { status: r.status, content_type: type, url: r.url || u.toString(), text: clip(spec.raw === true || !/html/i.test(type) ? raw : readable(raw), FETCH_TEXT_MAX) };
  }

  async search(query) {
    const q = encodeURIComponent(String(query ?? "").trim());
    if (!q) throw new Error("the query is empty");
    const tried = [];
    for (const [engine, url] of [
      ["duckduckgo", `https://html.duckduckgo.com/html/?q=${q}`],
      ["bing", `https://www.bing.com/search?q=${q}&setlang=en`],
    ]) {
      try {
        const r = await fetch(url, { headers: { "user-agent": UA, accept: "text/html" }, signal: AbortSignal.timeout(9000) });
        const html = (await r.text()).slice(0, 800000);
        await this.spend(0, html.length);
        const results = searchResults(html, engine);
        if (results.length >= 2) return results;
        tried.push(`${engine}: HTTP ${r.status}, nothing readable`);
      } catch (e) {
        tried.push(`${engine}: ${clip(e?.message ?? e, 60)}`);
      }
    }
    throw new Error("no search engine answered (" + tried.join("; ") + ")");
  }

  // ---------------------------------------------------------------- Python

  /// Put the Python Worker in the account, with the caller's login. Returns what went wrong in words, or "".
  async pythonDeploy(who) {
    let source;
    try {
      const r = await fetch(this.env.PY_SOURCE || PY_SOURCE);
      source = await r.text();
      if (r.status !== 200 || !source.includes("class Default(WorkerEntrypoint)")) return "could not fetch the Python Worker's source (HTTP " + r.status + ")";
    } catch (e) {
      return "could not fetch the Python Worker's source: " + clip(e?.message ?? e, 120);
    }
    const token = hex(crypto.getRandomValues(new Uint8Array(32)));
    const form = new FormData();
    form.append("metadata", new Blob([JSON.stringify({ main_module: "entry.py", compatibility_date: COMPAT_DATE, compatibility_flags: ["python_workers"], bindings: [{ type: "secret_text", name: "PY_TOKEN", text: token }] })], { type: "application/json" }), "metadata.json");
    form.append("entry.py", new Blob([PY_ENTRY], { type: "text/x-python" }), "entry.py");
    form.append("tot_py.py", new Blob([source], { type: "text/x-python" }), "tot_py.py");
    const base = `/accounts/${who.account}/workers/scripts/${PY_SCRIPT}`;
    const up = await this.api(who.token, "PUT", base, form, "");
    if (!up.success) return "Cloudflare refused the Python Worker: " + clip(up.errors?.[0]?.message ?? "no reason given", 300);
    const on = await this.api(who.token, "POST", base + "/subdomain", { enabled: true });
    if (!on.success) return "could not switch the Python Worker's address on: " + clip(on.errors?.[0]?.message ?? "no reason given", 300);
    await this.store.put("py", { url: (this.env.PY_URL || `https://${PY_SCRIPT}.${who.sub}.workers.dev`) + "/run", token, at: Date.now() });
    return "";
  }

  async pythonRun(spec) {
    const py = await this.store.get("py");
    if (!py) return { ok: false, out: "Python is not set up for this harness yet. The owner deploys it from the web veil's Harness tab.", files: {} };
    try {
      const r = await fetch(py.url, { method: "POST", headers: { "content-type": "application/json", authorization: "Bearer " + py.token }, body: JSON.stringify({ code: String(spec.code ?? ""), files: spec.files ?? {}, args: spec.args ?? null, packages: spec.packages ?? [] }), signal: AbortSignal.timeout(120000) });
      const text = await r.text();
      await this.spend(0, text.length);
      const j = JSON.parse(text);
      return { ok: j.ok === true, out: String(j.out ?? ""), files: j.files && typeof j.files === "object" ? j.files : {} };
    } catch (e) {
      return { ok: false, out: "the Python Worker did not answer: " + clip(e?.message ?? e, 200) + " (a new one can take a minute to come up)", files: {} };
    }
  }

  // ---------------------------------------------------------------- Agent Garrett (MCP)

  async garrettCall(method, params) {
    const g = await this.store.get("garrett");
    if (!g) return "ERROR: Agent Garrett is not connected to this harness";
    let r, text;
    try {
      r = await fetch(g.url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json", authorization: "Bearer " + g.token }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(30000) });
      text = await r.text();
      await this.spend(0, text.length);
    } catch (e) {
      return `ERROR: Agent Garrett did not answer: ${clip(e?.message ?? e, 200)}`;
    }
    let j = null;
    try {
      j = JSON.parse(text);
    } catch {}
    if (!j || typeof j !== "object") return `ERROR: Agent Garrett answered HTTP ${r.status}: ${clip(text, 300)}`;
    if (j.error) return `ERROR: Agent Garrett: ${clip(j.error.message ?? JSON.stringify(j.error), 400)}`;
    if (method === "tools/list") {
      const tools = Array.isArray(j.result?.tools) ? j.result.tools : [];
      return tools.length === 0 ? "(Agent Garrett lists no tools)" : tools.map((t) => `- ${t.name}: ${clip(String(t.description ?? ""), 160)}`).join("\n");
    }
    const out = (Array.isArray(j.result?.content) ? j.result.content : []).filter((c) => c?.type === "text").map((c) => c.text).join("\n");
    return (j.result?.isError ? "FAILED: " : "") + clip(out || "(no text)", 12000);
  }

  // ---------------------------------------------------------------- jobs (FIFO)

  async jobs() {
    return (await this.store.get("jobs")) ?? [];
  }

  /// Drop finished jobs, oldest first, while there are more than JOBS_KEEP or their data is past the limit.
  async evict(index) {
    const { storage_max } = await this.cfg();
    const total = () => index.reduce((n, j) => n + (j.bytes ?? 0), 0);
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
      case "garrett_tools":
        return this.garrettCall("tools/list", {});
      case "garrett":
        return this.garrettCall("tools/call", { name: String(args.name ?? ""), arguments: args.args && typeof args.args === "object" ? args.args : {} });
      default:
        return `error: no tool named ${name}. Tools: ${Object.keys(JOB_TOOLS).join(", ")}`;
    }
  }

  /// One step of a job: one model call, and the tool it asked for. True when the job ended.
  async jobStep(job) {
    const tools = Object.entries(JOB_TOOLS).map(([n, t]) => `- ${n} ${t}`).join("\n");
    const head = [
      { role: "system", content: "You are the veil, working on a queued job with nobody watching. Work the task to the end with these tools:\n" + tools + '\n\nTo use a tool, reply with exactly ONE JSON object and nothing else: {"tool": "<name>", "args": {...}}. When the job is done, or cannot go further, reply in plain text with what was done and what the tool results showed. Never claim something no tool result shows.' },
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
    let result;
    try {
      result = await this.jobTool(job, act.tool, act.args);
    } catch (e) {
      result = "error: " + clip(e?.message ?? e, 300);
    }
    job.rounds.push({ tool: act.tool, args: act.args, result: clip(result, RESULT_MAX) });
    return false;
  }

  /// The heartbeat: the job at the head of the queue takes up to ALARM_STEPS steps, then the next alarm goes on.
  async alarm() {
    const index = await this.jobs();
    const row = index.find((j) => j.state === "running") ?? index.find((j) => j.state === "queued");
    if (!row) return;
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
    if ((await this.jobs()).some((j) => ["queued", "running"].includes(j.state))) await this.store.setAlarm(Date.now() + wait);
  }

  // ---------------------------------------------------------------- routes

  async status(who) {
    const [cfg, usage, index, py, g] = [await this.cfg(), await this.usage(), await this.jobs(), await this.store.get("py"), await this.store.get("garrett")];
    return {
      ok: true,
      version: VERSION,
      ai: !!this.env.AI,
      account: who.account,
      limits: cfg,
      usage,
      storage_bytes: index.reduce((n, j) => n + (j.bytes ?? 0), 0),
      queue: { waiting: index.filter((j) => j.state === "queued").length, running: index.filter((j) => j.state === "running").length, max: QUEUE_MAX, kept: index.length, keep: JOBS_KEEP },
      python: py ? { deployed: true, at: py.at } : { deployed: false },
      garrett: g ? { connected: true, host: new URL(g.url).hostname } : { connected: false },
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
      const id = Date.now().toString(36) + hex(crypto.getRandomValues(new Uint8Array(3)));
      const job = { id, task, model, state: "queued", created: Date.now(), started: 0, finished: 0, rounds: [], files: {}, result: "", error: "", note: "", calls: 0 };
      index.push({ id, task: clip(task.replace(/\s+/g, " "), 120), state: "queued", created: job.created, finished: 0, bytes: 0, note: "" });
      await this.saveJob(job, index);
      if ((await this.store.getAlarm()) === null) await this.store.setAlarm(Date.now() + 100);
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

    if (method === "POST" && at === "python/deploy") {
      const err = await this.pythonDeploy(who);
      return err ? bad(err, 502) : say(await this.status(who));
    }
    if (method === "POST" && at === "python/run") {
      const why = await this.spent(false);
      if (why) return bad(why, 429);
      return say({ ok: true, run: await this.pythonRun(body) });
    }

    if (method === "POST" && at === "garrett") {
      const u = String(body.url ?? "").trim();
      if (!u) {
        await this.store.delete("garrett");
        return say(await this.status(who));
      }
      let parsed;
      try {
        parsed = new URL(u);
      } catch {
        return bad("that is not a URL");
      }
      if (parsed.protocol !== "https:" || privateHost(parsed.hostname)) return bad("Agent Garrett's address must be a public https URL");
      if (String(body.token ?? "").length < 8) return bad("Agent Garrett's token is missing");
      await this.store.put("garrett", { url: parsed.toString(), token: String(body.token) });
      const listed = await this.garrettCall("tools/list", {});
      if (listed.startsWith("ERROR")) {
        await this.store.delete("garrett");
        return bad(listed.slice(7), 502);
      }
      return say(await this.status(who));
    }
    if (method === "POST" && at === "garrett/call") {
      const m = String(body.method ?? "");
      if (m !== "tools/list" && m !== "tools/call") return bad("method must be tools/list or tools/call");
      return say({ ok: true, text: await this.garrettCall(m, body.params && typeof body.params === "object" ? body.params : {}) });
    }
    return bad("not found", 404);
  }
}
