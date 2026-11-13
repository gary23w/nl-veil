/* ============================================================================
   the veil — chat (https://gary23w.github.io/nl-veil/chat/)
   The veil in a browser tab. Everything of ours runs HERE: the Cloudflare
   login (OAuth with PKCE, no secret), the conversation, the workspace files,
   the tool loop, and the context fold (veil_core.wasm: the server engine's own
   4tope, compiled from src/worker/chat/net.zig).
   What a tab cannot do - call a model, read other sites, call Cloudflare's
   API, work with the tab closed - is done by the WORKER HARNESS, one Worker
   in the user's own Cloudflare account (cloud/veil-web). It obeys only a
   login to the account that owns it. No server of ours is involved.
   No build step: one classic script.
   ========================================================================= */

'use strict';

const CFG = window.VEIL_WEB;
const REDIRECT = location.origin + location.pathname;
const LOOP_BYTES = 54000;     // the loop's messages, before the net folds them (cloud/tot.js LOOP_BYTES)
const KEEP_ROUNDS = 2;        // the newest rounds a fold leaves verbatim
const NET_BUDGET = 7000;      // characters a fold's net may take
const PROTECT_MAX = 3000;     // a chain result kept through a fold is clipped to this
const RESULT_MAX = 10000;     // a tool result, as the loop records it
const ARG_MAX = 2000;         // one argument of a past call, as the model is shown it again
const ROUNDS_MAX = 16;        // tool calls one turn may make
const HISTORY_BYTES = 24000;  // earlier turns handed to the model
const SWARM_MAX = 4;          // minds one swarm call may run side by side
const MB = 1 << 20;

/* ============================================================ small helpers */

const clip = (s, n) => { s = String(s ?? ''); return s.length <= n ? s : s.slice(0, n) + '…'; };
const headTail = (s, n) => { s = String(s ?? ''); return s.length <= n ? s : s.slice(0, Math.floor(n * 0.6)) + '\n…[' + (s.length - n) + ' characters left out]…\n' + s.slice(s.length - Math.floor(n * 0.4)); };
const bytes = (ms) => ms.reduce((n, m) => n + String(m.content ?? '').length, 0);
const mb = (n) => (n / MB < 10 ? (n / MB).toFixed(1) : Math.round(n / MB)) + ' MB';
const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v === false || v === null || v === undefined) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'html') el.innerHTML = v;            // only ever fed NVMarkdown.render (which escapes) or a constant
    else if (k === 'value') el.value = v;
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) el.append(kid);
  return el;
}

const store = (area) => ({
  get(k, d = null) { try { const v = area.getItem(k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { area.setItem(k, JSON.stringify(v)); } catch {} },
  del(k) { try { area.removeItem(k); } catch {} },
});
const ls = store(localStorage);      // what outlives the tab: the harness address, the model, the theme
const ss = store(sessionStorage);    // the Cloudflare login: this tab only

/* Conversations and their files live in IndexedDB, in this browser only. A browser that refuses storage
   (some private windows) gets a Map: the session works, and nothing outlives the tab. */
const db = (() => {
  const mem = new Map();
  let opened = null;
  const open = () => (opened ??= new Promise((res) => {
    // a database another tab is upgrading or deleting can keep an open waiting for good: the page must not
    setTimeout(() => res(null), 1500);
    try {
      const r = indexedDB.open('veilweb', 1);
      r.onupgradeneeded = () => r.result.createObjectStore('kv');
      r.onsuccess = () => res(r.result);
      r.onerror = () => res(null);
    } catch { res(null); }
  }));
  const run = async (mode, fn, fallback) => {
    const d = await open();
    if (!d) return fallback();
    return new Promise((res) => {
      const t = d.transaction('kv', mode);
      const q = fn(t.objectStore('kv'));
      t.oncomplete = () => res(q.result);
      t.onerror = t.onabort = () => res(fallback());
    });
  };
  return {
    get: (k) => run('readonly', (s) => s.get(k), () => mem.get(k)),
    put: (k, v) => { mem.set(k, v); return run('readwrite', (s) => s.put(v, k), () => undefined); },
    del: (k) => { mem.delete(k); return run('readwrite', (s) => s.delete(k), () => undefined); },
  };
})();

/* ============================================================ the wasm core */

const core = {
  x: null,
  head: '',
  async load() {
    try {
      const { instance } = await WebAssembly.instantiate(await (await fetch('veil_core.wasm')).arrayBuffer(), {});
      if (instance.exports.veil_core_abi() !== 1) throw new Error('abi');
      this.x = instance.exports;
      this.head = this.take(this.x.veil_net_head());
    } catch { this.x = null; }
  },
  put(str) {
    const b = new TextEncoder().encode(str);
    const ptr = this.x.veil_alloc(b.length);
    if (!ptr) throw new Error('out of memory');
    new Uint8Array(this.x.memory.buffer, ptr, b.length).set(b);
    return [ptr, b.length];
  },
  take(packed) {
    const v = BigInt.asUintN(64, BigInt(packed));
    if (v === 0n) return '';
    const ptr = Number(v >> 32n), len = Number(v & 0xFFFFFFFFn);
    const s = new TextDecoder().decode(new Uint8Array(this.x.memory.buffer, ptr, len));
    this.x.veil_free(ptr, len);
    return s;
  },
  /* the span's net and the ids of the results the fold must keep whole */
  fold(span, ground, tailFrom) {
    const [sp, sl] = this.put(span);
    const [gp, gl] = this.put(ground);
    try {
      const net = this.take(this.x.veil_net_unfold(sp, sl, NET_BUDGET, gp, gl, tailFrom));
      const ids = this.take(this.x.veil_net_protected(sp, sl)).split('\n').filter(Boolean);
      return { net, keep: new Set(ids) };
    } finally {
      this.x.veil_free(sp, sl);
      this.x.veil_free(gp, gl);
    }
  },
};

/* ============================================================ state */

const S = {
  session: ss.get('veilweb.session'),    // {access, refresh, exp} once logged in with Cloudflare
  harness: ls.get('veilweb.harness'),    // the worker harness's address, once one answered this login
  status: null,                          // the harness's last /v1/status
  me: null,                              // {email, account_name}
  checking: false,                       // looking for the harness right now
  model: ls.get('veilweb.model') || CFG.models[0],
  models: [],                            // the account's Workers AI text models, from the harness
  context: '',                           // the harness's reference text (llms.txt digest)
  convs: [],                             // [{id, title, at}] newest first; the harness's copy and this browser's, merged
  conv: null,                            // the open conversation: {id, title, at, msgs, files}
  live: null,                            // the running turn: {tools, text, status, abort}
  tab: 'code',                           // the side pane: code | jobs | harness
  wide: false,                           // the side pane takes half the window (for reading code)
  file: null,                            // the file open in the editor
  preview: false,                        // the open file is shown rendered, not as text
  jobs: [],                              // the harness's queue, oldest first
  schedules: [],                         // the harness's repeating tasks
  job: null,                             // the job open in the viewer (whole record)
  err: '',                               // the gate's or the setup card's message
  note: '',                              // the side pane's last message
  busy: '',                              // which side-pane action is in flight
  linksOpen: ls.get('veilweb.links', true),
  panes: { rail: false, side: false },   // narrow screens: which drawer is open
};

/* ============================================================ log in with Cloudflare (PKCE, in the page) */

async function login() {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const state = b64url(crypto.getRandomValues(new Uint8Array(18)));
  const challenge = b64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
  ss.set('veilweb.pkce', { state, verifier });
  const q = new URLSearchParams({ response_type: 'code', client_id: CFG.client_id, redirect_uri: REDIRECT, scope: CFG.scopes, state, code_challenge: challenge, code_challenge_method: 'S256' });
  location.assign(CFG.auth_url + '?' + q);
}

async function tokenCall(form) {
  let r;
  try {
    r = await fetch(CFG.token_url, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ client_id: CFG.client_id, ...form }) });
  } catch {
    throw new Error('Cloudflare did not let this page finish the login. This site\'s address is probably not on the OAuth client\'s allowed list yet.');
  }
  const j = await r.json().catch(() => null);
  if (!j?.access_token) throw new Error('Cloudflare refused the login: ' + clip(j?.error_description || j?.error || 'HTTP ' + r.status, 300));
  S.session = { access: j.access_token, refresh: j.refresh_token || form.refresh_token || '', exp: Date.now() + (Number(j.expires_in) || 3600) * 1000 };
  ss.set('veilweb.session', S.session);
}

/* The consent page sent the browser back here with ?code=…&state=… (or ?error=…). */
async function finishLogin() {
  const q = new URLSearchParams(location.search);
  if (!q.has('code') && !q.has('error')) return;
  history.replaceState(null, '', REDIRECT);
  const pkce = ss.get('veilweb.pkce');
  ss.del('veilweb.pkce');
  if (q.has('error')) { S.err = 'Cloudflare did not log you in: ' + clip(q.get('error_description') || q.get('error'), 300); return; }
  if (!pkce || pkce.state !== q.get('state')) { S.err = 'That login did not start in this tab. Try again.'; return; }
  try {
    await tokenCall({ grant_type: 'authorization_code', code: q.get('code'), redirect_uri: REDIRECT, code_verifier: pkce.verifier });
  } catch (e) { S.err = e.message; }
}

let refreshing = null;
function refresh() {
  if (!S.session?.refresh) return Promise.reject(new Error('the Cloudflare login expired'));
  return (refreshing ??= tokenCall({ grant_type: 'refresh_token', refresh_token: S.session.refresh }).finally(() => { refreshing = null; }));
}

function logout(why = '') {
  ss.del('veilweb.session');
  S.session = null; S.status = null; S.me = null; S.live = null;
  S.err = why;
  draw();
}

/* ============================================================ the harness */

/* One call to the harness with the login. An access token near its end is renewed first; a 401 is retried once
   with a renewed one. A lost login sends the user back to the gate. */
async function harness(path, init = {}, base = S.harness) {
  const call = () => fetch(base + path, {
    method: init.method ?? (init.body === undefined ? 'GET' : 'POST'),
    headers: { authorization: 'Bearer ' + S.session.access, ...(init.body === undefined ? {} : { 'content-type': 'application/json' }) },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
    signal: init.signal,
  });
  if (!S.session) throw new Error('not logged in');
  if (S.session.exp - Date.now() < 60000 && S.session.refresh) await refresh().catch(() => {});
  let r = await call();
  if (r.status === 401 && S.session.refresh) {
    try { await refresh(); r = await call(); } catch { logout('Your Cloudflare login expired. Log in again.'); throw new Error('the Cloudflare login expired'); }
  }
  return r;
}

async function harnessJson(path, init) {
  const r = await harness(path, init);
  const j = await r.json().catch(() => null);
  if (!j) throw new Error('the harness answered HTTP ' + r.status + ' with no JSON');
  if (!j.ok) throw new Error(j.err || 'HTTP ' + r.status);
  return j;
}

/* What the user typed for their harness, as an address: a workers.dev name, a host, or a URL. */
function harnessUrl(typed) {
  let t = String(typed ?? '').trim().replace(/\/+$/, '');
  if (!t) return null;
  if (/^[a-z0-9-]+$/i.test(t)) t = `${CFG.script}.${t}.workers.dev`;
  if (!/^https?:\/\//i.test(t)) t = 'https://' + t;
  let u;
  try { u = new URL(t); } catch { return null; }
  const loop = u.hostname === 'localhost' || u.hostname === '127.0.0.1';
  if (u.protocol !== 'https:' && !loop) return null;
  return u.origin;
}

const outdated = () => !!S.status && Number(S.status.version) < CFG.harness_version;

/* Is there a harness at `url` that this login owns? Sets S.harness + S.status when there is, then loads what
   the harness keeps: who is logged in, the model list, the reference text, the chats, the jobs. */
async function findHarness(url, quiet = false) {
  S.checking = true;
  if (!quiet) S.err = '';
  draw();
  try {
    const r = await harness('/v1/status', {}, url);
    const j = await r.json().catch(() => null);
    if (r.status === 401) throw new Error('A Worker answers there, but this Cloudflare login does not own it. Log in with the account you deployed it to.');
    if (!j?.ok) throw new Error('That address did not answer like a veil worker harness (HTTP ' + r.status + ').');
    S.harness = url;
    S.status = j;
    ls.set('veilweb.harness', url);
    harnessJson('/v1/me').then((me) => { S.me = me; draw(); }).catch(() => {});
    loadHarnessData();
  } catch (e) {
    if (!quiet) S.err = e instanceof TypeError ? 'Nothing answered at that address. A new Worker can take a minute to come up; check the name and try again.' : e.message;
    else if (!(e instanceof TypeError)) S.err = e.message;
  }
  S.checking = false;
  draw();
}

/* Everything past /v1/status. A harness older than this page lacks some of these routes; each is optional. */
function loadHarnessData() {
  refreshJobs();
  if (outdated()) return;
  harnessJson('/v1/models').then((j) => {
    S.models = j.models;
    if (S.models.length && !S.models.some((m) => m.id === S.model) && !ls.get('veilweb.model')) S.model = S.models[0].id;
    draw();
  }).catch(() => {});
  harnessJson('/v1/context').then((j) => { S.context = j.digest || ''; }).catch(() => {});
  harnessJson('/v1/schedules').then((j) => { S.schedules = j.schedules; drawSide(); }).catch(() => {});
  pullConvs();
}

async function refreshStatus() {
  try { S.status = await harnessJson('/v1/status'); } catch {}
  drawSide();
}

async function refreshJobs() {
  const live = (jobs) => jobs.filter((j) => j.state === 'queued' || j.state === 'running').length;
  const before = live(S.jobs);
  try { S.jobs = (await harnessJson('/v1/jobs')).jobs; } catch {}
  if (S.tab !== 'jobs' && live(S.jobs) !== before) drawSide();   // the tab's count
  const row = S.job && S.jobs.find((j) => j.id === S.job.id);
  if (row && (row.state !== S.job.state || row.state === 'running')) {
    try { S.job = (await harnessJson('/v1/jobs/' + S.job.id)).job; } catch {}
  }
  if (S.tab === 'jobs') drawSide();
}
setInterval(() => { if (S.status && !document.hidden && (S.tab === 'jobs' || S.jobs.some((j) => j.state === 'queued' || j.state === 'running') || S.schedules.length)) refreshJobs(); }, 5000);

/* A side-pane action: one at a time, its failure shown in the pane. */
async function act(name, fn) {
  if (S.busy) return;
  S.busy = name; S.note = '';
  drawSide();
  try { await fn(); } catch (e) { S.note = e.message; }
  S.busy = '';
  drawSide();
}

/* Replace the harness with the current one from the public repo, then wait for the new version to answer. */
async function updateHarness() {
  const was = S.status.version;
  try {
    const u = await harnessJson('/v1/update', { body: {} });
    if (u.same) return toast('Your harness is already the newest (version ' + u.now + ').');
  } catch (e) {
    if (/not found|HTTP 404/i.test(e.message)) throw new Error('This harness is from before it could update itself. Deploy it once more from Cloudflare\'s deploy page (the same button as before); later updates are one click here.');
    throw e;
  }
  // Cloudflare takes the new code at once but the harness's Durable Object can keep the old for some minutes
  toast('Update accepted. Cloudflare can take a few minutes to switch over; this page will say when it has.');
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 6000));
    try { S.status = await harnessJson('/v1/status'); } catch {}
    if (S.status.version !== was) { loadHarnessData(); draw(); toast('Harness updated to version ' + S.status.version + '.'); return; }
  }
  throw new Error('The update was accepted but the new version has not answered yet. Reload in a minute.');
}

/* ============================================================ the model */

function answerText(r) {
  const flat = (c) => (typeof c === 'string' ? c : Array.isArray(c) ? c.map((p) => (typeof p === 'string' ? p : (p?.text ?? p?.content ?? ''))).join('') : '');
  let t = '';
  if (typeof r === 'string') t = r;
  else if (r && typeof r === 'object') {
    for (const c of [r.response, r.result?.response, r.output_text, r.choices?.[0]?.message?.content, r.choices?.[0]?.delta?.content, r.choices?.[0]?.text]) {
      t = flat(c);
      if (t) break;
    }
  }
  return t;
}
const noThink = (t) => String(t).replace(/<think>[\s\S]*?<\/think>/gi, '').replace(/<think>[\s\S]*$/i, '').trim();

/* One model call through the harness. `onText` is handed the reply so far as it streams. */
async function callModel(messages, onText, signal, maxTokens = 4096) {
  const r = await harness('/v1/chat', { body: { model: S.model, messages, max_tokens: maxTokens, stream: true }, signal });
  const type = r.headers.get('content-type') ?? '';
  if (!type.includes('event-stream')) {
    const j = await r.json().catch(() => null);
    if (!j) throw new Error('the harness answered HTTP ' + r.status);
    if (!j.ok) throw new Error(j.err || 'HTTP ' + r.status);
    const t = noThink(answerText(j.reply));
    onText?.(t);
    return t;
  }
  const reader = r.body.getReader();
  const dec = new TextDecoder();
  let buf = '', text = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (data === '[DONE]') continue;
      try {
        const piece = answerText(JSON.parse(data));
        if (piece) { text += piece; onText?.(noThink(text)); }
      } catch {}
    }
  }
  return noThink(text);
}

/* ============================================================ tools */

const TOOLS = {
  write_file: { args: '{"name": "<path>", "content": "<the whole file>"}', does: 'create or replace a file in the workspace' },
  read_file: { args: '{"name": "<path>"}', does: 'read a workspace file' },
  edit_file: { args: '{"name": "<path>", "find": "<exact text>", "replace": "<new text>"}', does: 'replace one exact passage of a workspace file' },
  list_files: { args: '{}', does: 'list the workspace' },
  delete_file: { args: '{"name": "<path>"}', does: 'delete a workspace file' },
  web_search: { args: '{"query": "<words>"}', does: 'search the web; returns titles, links and snippets' },
  web_fetch: { args: '{"url": "<https://...>"}', does: 'read a web page as text' },
  http_request: { args: '{"url": "<https://...>", "method": "GET", "headers": {}, "body": ""}', does: 'make any HTTP call and see the raw answer' },
  swarm: { args: '{"task": "<the question>", "angles": ["<a way to look at it>", "..."]}', does: 'ask up to ' + SWARM_MAX + ' minds at once, one per angle, and get every answer back to weigh' },
  queue_job: { args: '{"task": "<the whole task, self-contained>"}', does: 'hand a long task to the worker harness; it runs there in turn (first in, first out) even with this tab closed, and the user reads the result in the Jobs tab' },
  schedule_job: { args: '{"task": "<the whole task, self-contained>", "every_minutes": 60}', does: 'have the harness queue this task again and again, every so many minutes (5 at the least)', when: () => !outdated() },
  run_python: { args: '{"code": "<python>"}', does: 'run Python on the harness\'s Python Worker; the workspace files are beside the script and files it changes come back', when: () => S.status?.python?.deployed },
  garrett_tools: { args: '{"query": "<words, optional>"}', does: 'list Agent Garrett\'s security tools (those matching the words)', when: () => S.status?.garrett?.connected },
  garrett: { args: '{"name": "<tool>", "args": {...}}', does: 'call one of Agent Garrett\'s tools', when: () => S.status?.garrett?.connected },
};
const toolsNow = () => Object.entries(TOOLS).filter(([, t]) => !t.when || t.when());

const fileName = (v) => String(v ?? '').trim().replace(/\\/g, '/').replace(/^\.?\/+/, '');

async function runTool(name, args, signal) {
  const files = S.conv.files;
  const f = fileName(args.name ?? args.path ?? args.file);
  switch (name) {
    case 'write_file': {
      if (!f || f.length > 200 || f.includes('..')) return 'error: bad file name';
      const body = String(args.content ?? args.text ?? '');
      files[f] = body;
      S.file = f;   // the Code tab follows what is being written
      return `wrote ${f} (${body.length} characters)`;
    }
    case 'read_file':
      return f in files ? files[f] : `error: no file named ${f}. Files: ${Object.keys(files).join(', ') || '(none)'}`;
    case 'edit_file': {
      if (!(f in files)) return `error: no file named ${f}`;
      const find = String(args.find ?? args.old ?? '');
      if (!find) return 'error: find is empty';
      const n = files[f].split(find).length - 1;
      if (n !== 1) return `error: find matches ${n} places in ${f}; it must match exactly one`;
      files[f] = files[f].replace(find, () => String(args.replace ?? args.new ?? ''));
      S.file = f;
      return `edited ${f} (${files[f].length} characters now)`;
    }
    case 'list_files':
      return Object.keys(files).length ? Object.entries(files).map(([n, c]) => `${n} (${c.length} characters)`).join('\n') : '(the workspace is empty)';
    case 'delete_file':
      if (!(f in files)) return `error: no file named ${f}`;
      delete files[f];
      if (S.file === f) S.file = null;
      return `deleted ${f}`;
    case 'web_search': {
      const j = await harnessJson('/v1/search', { body: { q: String(args.query ?? args.q ?? '') }, signal });
      return j.results.map((r, i) => `${i + 1}. ${r.title}\n   ${r.url}\n   ${r.snippet}`).join('\n');
    }
    case 'web_fetch':
    case 'http_request': {
      const raw = name === 'http_request';
      const j = await harnessJson('/v1/fetch', { body: { url: String(args.url ?? ''), method: raw ? args.method : 'GET', headers: raw ? args.headers : undefined, body: raw ? args.body : undefined, raw }, signal });
      return `HTTP ${j.status} ${j.url}\n\n${j.text}`;
    }
    case 'swarm': {
      const task = String(args.task ?? '').trim();
      const angles = (Array.isArray(args.angles) ? args.angles : []).map(String).filter(Boolean).slice(0, SWARM_MAX);
      if (!task || angles.length < 2) return 'error: swarm needs a task and at least two angles';
      const minds = await Promise.all(angles.map(async (angle, i) => {
        try {
          const t = await callModel([
            { role: 'system', content: 'You are one mind of a small swarm. Answer the task from the one angle you are given, in under 250 words. Say what you are unsure of.' },
            { role: 'user', content: `TASK: ${task}\n\nYOUR ANGLE: ${angle}` },
          ], null, signal, 700);
          return `MIND ${i + 1} (${angle}):\n${t || '(answered nothing)'}`;
        } catch (e) {
          return `MIND ${i + 1} (${angle}): error: ${e.message}`;
        }
      }));
      return minds.join('\n\n');
    }
    case 'queue_job': {
      const j = await harnessJson('/v1/jobs', { body: { task: String(args.task ?? ''), model: S.model }, signal });
      refreshJobs();
      return `queued as job ${j.id}, number ${j.position} in line. It runs on the harness; its result appears in the Jobs tab.`;
    }
    case 'schedule_job': {
      const minutes = Math.max(5, Math.floor(Number(args.every_minutes) || 60));
      const j = await harnessJson('/v1/schedules', { body: { task: String(args.task ?? ''), model: S.model, every_s: minutes * 60 }, signal });
      S.schedules = (await harnessJson('/v1/schedules')).schedules;
      return `scheduled: the harness queues this task every ${minutes} minutes, first at ${new Date(j.schedule.next).toISOString().slice(11, 16)} UTC. It is listed in the Jobs tab, where it can be deleted.`;
    }
    case 'run_python': {
      const j = await harnessJson('/v1/python/run', { body: { code: String(args.code ?? ''), files }, signal });
      for (const [n, c] of Object.entries(j.run.files)) if (typeof c === 'string') files[fileName(n)] = c;
      return (j.run.ok ? '' : 'error: ') + (j.run.out || '(no output)');
    }
    case 'garrett_tools':
      return (await harnessJson('/v1/garrett/call', { body: { method: 'tools/list', params: {}, query: String(args.query ?? '') }, signal })).text;
    case 'garrett':
      return (await harnessJson('/v1/garrett/call', { body: { method: 'tools/call', params: { name: String(args.name ?? ''), arguments: args.args && typeof args.args === 'object' ? args.args : {} } }, signal })).text;
    default:
      return `error: no tool named ${name}. Tools: ${toolsNow().map(([n]) => n).join(', ')}`;
  }
}

/* ============================================================ the loop */

/* The first JSON object in a reply (cloud/tot.js firstJson), and where it starts. */
function firstJson(text) {
  const s = String(text ?? '');
  for (let from = s.indexOf('{'); from >= 0; from = s.indexOf('{', from + 1)) {
    let depth = 0, inStr = false, esc = false;
    for (let i = from; i < s.length; i++) {
      const c = s[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === '\\') esc = true;
        else if (c === '"') inStr = false;
        continue;
      }
      if (c === '"') inStr = true;
      else if (c === '{') depth++;
      else if (c === '}' && --depth === 0) {
        try {
          const v = JSON.parse(s.slice(from, i + 1));
          if (v && typeof v === 'object' && !Array.isArray(v)) return { value: v, at: from };
        } catch {}
        break;
      }
    }
  }
  return null;
}

/* What a reply asks for: {tool, args, say} or null when it is the answer. A reply is a tool call when its JSON
   names one of the tools; an answer that merely contains JSON stays an answer. */
function parseAction(reply) {
  const found = firstJson(reply);
  if (!found) return null;
  let c = found.value;
  if (Array.isArray(c.tool_calls) && c.tool_calls[0] && typeof c.tool_calls[0] === 'object') c = c.tool_calls[0];
  if (c.function && typeof c.function === 'object') c = c.function;
  const name = [c.tool, c.name, c.tool_name].find((v) => typeof v === 'string' && v.length > 0);
  const starts = /^\s*(```\w*\s*)?\{/.test(reply);
  if (!name || !(name in TOOLS || (starts && typeof c.tool === 'string'))) return null;
  let args = [c.args, c.arguments, c.parameters, c.input].find((v) => v !== undefined && v !== null);
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch { args = {}; } }
  if (!args || typeof args !== 'object' || Array.isArray(args)) args = {};
  return { tool: name, args, say: clip(String(reply).slice(0, found.at).replace(/```\w*\s*$/, '').trim(), 700) };
}

function systemPrompt() {
  const tools = toolsNow().map(([n, t]) => `- ${n} ${t.args} : ${t.does}`).join('\n');
  const garrett = S.status?.garrett?.connected
    ? 'Agent Garrett, the security agent by the same author as this veil, is connected: its tools are on your belt as garrett_tools (find one) and garrett (call one). Use them for security work.'
    : 'Agent Garrett is a security agent by the same author as this veil. It is NOT connected here. When the user asks for security work that needs tools you lack (CVE, KEV or EPSS lookups, DNS and certificate-transparency recon, RDAP, email security posture, IOC extraction, evidence manifests), first do what you honestly can with your own tools, then say once, in a sentence, that connecting Agent Garrett adds those tools to this chat: Harness tab, with a key from ' + CFG.garrett.dashboard + '. Do not bring it up for other work, do not repeat it, and never state a result its tools would have given.';
  return 'You are the veil, running as the veil\'s web chat: a chat in the user\'s browser. Your model calls and web requests go through a worker harness in the user\'s own Cloudflare account.\n' +
    'You have a workspace of files (the user watches it in the Code tab beside the chat, can edit it, and can preview a web page live) and these tools:\n' + tools + '\n\n' +
    'To use a tool, reply with exactly ONE JSON object and nothing else: {"tool": "<name>", "args": {...}}. You are then given the result and may use another tool or answer.\n' +
    'When you are done, answer the user in plain text (markdown is fine), never as JSON. Do not say a file was written or a page was read unless a tool result shows it. ' +
    'When asked to build an app, page or script, write it as files with write_file (a web page as index.html plus its own .css and .js files) so the user sees it in the Code tab; do not paste whole files into the answer. ' +
    'If web_search fails, fetch a likely page directly with web_fetch. You cannot reach the user\'s computer from here; say so when it matters.\n' +
    garrett + '\n' +
    (S.context ? '\nREFERENCE (from garrettstimpson.ca/llms.txt, about the people and projects behind this veil; answer questions about Agent Garrett, NL-VEIL and their author from it, with its links):\n' + S.context + '\n' : '') +
    'Today is ' + new Date().toISOString().slice(0, 10) + '.';
}

/* Earlier turns, newest kept first, under HISTORY_BYTES. */
function pastTurns(msgs) {
  const out = [];
  let room = HISTORY_BYTES;
  for (let i = msgs.length - 1; i >= 0 && room > 0; i--) {
    const m = msgs[i];
    if (m.role !== 'user' && m.role !== 'assistant') continue;
    const content = clip(m.content, m.role === 'assistant' ? 4000 : 6000);
    room -= content.length;
    out.unshift({ role: m.role, content });
  }
  while (out.length && out[0].role !== 'user') out.shift();
  return out;
}

/* A past call as the model is shown it: a long argument (a whole file body) is clipped, its result says what landed. */
const shortArgs = (args, max) => Object.fromEntries(Object.entries(args).map(([k, v]) => [k, typeof v === 'string' && v.length > max ? headTail(v, max) : v]));
const pair = (r, resultMax = RESULT_MAX, argMax = ARG_MAX) => [
  { role: 'assistant', content: (r.say ? r.say + '\n' : '') + JSON.stringify({ tool: r.name, args: shortArgs(r.args, argMax) }) },
  { role: 'user', content: `RESULT of ${r.name}:\n${headTail(r.result, resultMax)}` },
];

/* The turn as net.zig reads a span: OpenAI-shaped messages, each object starting {"role":" */
function spanOf(task, rounds) {
  const ms = [{ role: 'user', content: task }];
  for (const r of rounds) {
    ms.push({ role: 'assistant', content: r.say || '', tool_calls: [{ id: r.id, type: 'function', function: { name: r.name, arguments: JSON.stringify(shortArgs(r.args, ARG_MAX)) } }] });
    ms.push({ role: 'tool', tool_call_id: r.id, content: r.result });
  }
  return JSON.stringify(ms).slice(1, -1);
}

/* The messages one model call is handed. Past LOOP_BYTES the rounds before the newest KEEP_ROUNDS become one net
   (the wasm core) and the critical chain's results stay whole; without the core the oldest rounds go. */
function buildMessages(head, task, rounds) {
  const whole = rounds.flatMap((r) => pair(r));
  if (bytes(whole) <= LOOP_BYTES || rounds.length <= KEEP_ROUNDS) return { messages: [...head, ...whole], folded: false };
  const keepFrom = rounds.length - KEEP_ROUNDS;
  const tail = rounds.slice(keepFrom).flatMap((r) => pair(r));
  if (core.x) {
    try {
      const ground = Object.entries(S.conv.files).map(([n, c]) => `${n} (${c.length} characters)`).join(', ');
      const { net, keep } = core.fold(spanOf(task, rounds), ground ? 'workspace files: ' + ground : '', 1 + 2 * keepFrom);
      const kept = rounds.slice(0, keepFrom).filter((r) => keep.has(r.id)).flatMap((r) => pair(r, PROTECT_MAX, 600));
      const note = { role: 'user', content: core.head + (net || '(the earlier rounds established nothing a tool result shows)\n') };
      return { messages: [...head, note, ...kept, ...tail], folded: true };
    } catch {}
  }
  return { messages: [...head, { role: 'user', content: `(${keepFrom} earlier tool rounds of this turn were dropped for room)` }, ...tail], folded: false };
}

async function runTurn(text) {
  const conv = S.conv;
  const head = [{ role: 'system', content: systemPrompt() }, ...pastTurns(conv.msgs), { role: 'user', content: text }];
  conv.msgs.push({ role: 'user', content: text });
  if (conv.msgs.length === 1) conv.title = clip(text.replace(/\s+/g, ' '), 48);
  const abort = new AbortController();
  S.live = { tools: [], text: '', status: 'thinking…', abort };
  draw();
  const rounds = [];
  let answer = '', error = '';
  try {
    for (let n = 0; ; n++) {
      const { messages, folded } = buildMessages(head, text, rounds);
      S.live.status = folded ? 'thinking… (earlier rounds folded by the 4tope)' : 'thinking…';
      S.live.text = '';
      drawLive();
      const reply = await callModel(messages, (t) => {
        // a tool call on its way is not words for the user: show only what was said before it
        const cut = t.search(/(```\w*\s*)?\{\s*"(tool|tool_calls)"\s*:/);
        S.live.text = cut >= 0 ? t.slice(0, cut).trim() : /^\s*(```\w*\s*)?\{/.test(t) ? '' : t;
        drawLive();
      }, abort.signal);
      if (!reply) throw new Error('the model answered nothing');
      const act = parseAction(reply);
      if (!act) { answer = reply; break; }
      if (n >= ROUNDS_MAX) { answer = `I stopped after ${ROUNDS_MAX} tool calls without finishing. Ask me to continue.`; break; }
      const chip = { name: act.tool, args: act.args, result: '', failed: false, running: true };
      S.live.tools.push(chip);
      S.live.text = '';
      S.live.status = 'running ' + act.tool + '…';
      drawLive();
      let result;
      try {
        result = await runTool(act.tool, act.args, abort.signal);
      } catch (e) {
        if (abort.signal.aborted) throw e;
        result = 'error: ' + e.message;
      }
      chip.result = result;
      chip.failed = /^error: /.test(result);
      chip.running = false;
      rounds.push({ id: 'c' + (rounds.length + 1), name: act.tool, args: act.args, say: act.say, result });
      if (['write_file', 'edit_file'].includes(act.tool) && !chip.failed) S.tab = 'code';   // watch the code as it lands
      drawSide();
    }
  } catch (e) {
    error = abort.signal.aborted ? 'stopped' : e.message;
  }
  if (!S.live) return;   // logged out mid-turn
  const tools = S.live.tools.map(({ name, args, result, failed }) => ({ name, args, result: clip(result, RESULT_MAX), failed }));
  if (answer || tools.length) conv.msgs.push({ role: 'assistant', content: answer, tools });
  if (error) conv.msgs.push({ role: 'error', content: error });
  S.live = null;
  await saveConv();
  draw();
  refreshStatus();
}

/* ============================================================ conversations */

/* A conversation lives in this browser (IndexedDB) and, when the harness is new enough, in the harness too, so
   another browser logged in to the same account finds it. The newer copy wins by its `at` stamp. */

const putIndex = () => db.put('convs', S.convs);

async function saveConv() {
  const c = S.conv;
  if (!c || c.msgs.length === 0) return;
  c.at = Date.now();
  await db.put('conv:' + c.id, c);
  S.convs = [{ id: c.id, title: c.title, at: c.at }, ...S.convs.filter((x) => x.id !== c.id)];
  await putIndex();
  pushConv(c);
}

/* Best effort: a conversation the harness cannot take (too large, storage full) stays in this browser. */
let pushTimer = null;
function pushConv(c) {
  if (!S.status || outdated()) return;
  clearTimeout(pushTimer);
  pushTimer = setTimeout(async () => {
    try {
      await harnessJson('/v1/convs/' + c.id, { body: { title: c.title, at: c.at, msgs: c.msgs, files: c.files } });
    } catch (e) {
      toast('Not synced to the harness: ' + e.message);
    }
  }, 800);
}

/* The harness's list, merged into this browser's: what only the harness has, or has newer, is marked to fetch. */
async function pullConvs() {
  let remote;
  try { remote = (await harnessJson('/v1/convs')).convs; } catch { return; }
  const mine = new Map(S.convs.map((c) => [c.id, c]));
  for (const r of remote) {
    const m = mine.get(r.id);
    if (!m || r.at > m.at) mine.set(r.id, { id: r.id, title: r.title, at: r.at, fetch: true });
  }
  S.convs = [...mine.values()].sort((a, b) => b.at - a.at);
  await putIndex();
  // what this browser has and the harness lacks goes up, a few at a time
  const theirs = new Set(remote.map((r) => r.id));
  for (const c of S.convs.filter((x) => !theirs.has(x.id)).slice(0, 5)) {
    const full = await db.get('conv:' + c.id);
    if (full) harnessJson('/v1/convs/' + c.id, { body: { title: full.title, at: full.at, msgs: full.msgs, files: full.files } }).catch(() => {});
  }
  draw();
}

function newConv() {
  S.conv = { id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6), title: 'New chat', at: Date.now(), msgs: [], files: {} };
  S.file = null;
  S.preview = false;
}

async function openConv(id) {
  if (S.live) return;
  const row = S.convs.find((x) => x.id === id);
  let c = await db.get('conv:' + id);
  if (row?.fetch || !c) {
    try {
      c = (await harnessJson('/v1/convs/' + id)).conv;
      await db.put('conv:' + id, c);
      if (row) delete row.fetch;
      await putIndex();
    } catch (e) {
      if (!c) return toast('Could not open that chat: ' + e.message);
    }
  }
  S.conv = c;
  S.file = Object.keys(c.files)[0] ?? null;
  S.preview = false;
  S.panes.rail = false;
  draw();
}

async function deleteConv(id) {
  if (S.live) return;
  if (!confirm('Delete this conversation and its files, here and on your harness?')) return;
  await db.del('conv:' + id);
  S.convs = S.convs.filter((x) => x.id !== id);
  await putIndex();
  if (S.status && !outdated()) harnessJson('/v1/convs/' + id, { method: 'DELETE' }).catch(() => {});
  if (S.conv?.id === id) newConv();
  draw();
}

/* A workspace file changed by hand in the editor: kept at once, saved a moment after the typing stops. */
let editTimer = null;
function fileEdited(name, text) {
  S.conv.files[name] = text;
  touchConv();
}
function touchConv() {
  clearTimeout(editTimer);
  editTimer = setTimeout(() => {
    if (S.conv.msgs.length === 0) S.conv.title = S.conv.title === 'New chat' ? 'Workspace' : S.conv.title;
    S.conv.at = Date.now();
    db.put('conv:' + S.conv.id, S.conv);
    if (!S.convs.some((x) => x.id === S.conv.id)) { S.convs.unshift({ id: S.conv.id, title: S.conv.title, at: S.conv.at }); putIndex(); }
    pushConv(S.conv);
  }, 700);
}

/* ============================================================ drawing */

const app = document.getElementById('app');
const barSlot = document.getElementById('barSlot');
const render = (md) => window.NVMarkdown.render(String(md ?? ''));
const ext = (name) => (/\.([a-z0-9]+)$/i.exec(name)?.[1] ?? '').toLowerCase();
const link = (item, cls = '') => h('a', { class: cls, href: item.href, ...(item.href.startsWith('http') ? { target: '_blank', rel: 'noopener' } : {}) }, item.label);

/* A short message that needs no answer: shown at the bottom for a few seconds. */
function toast(text) {
  let box = document.getElementById('toasts');
  if (!box) { box = h('div', { id: 'toasts', class: 'toasts', role: 'status', 'aria-live': 'polite' }); document.body.append(box); }
  const t = h('div', { class: 'toast' }, text);
  box.append(t);
  setTimeout(() => { t.classList.add('out'); setTimeout(() => t.remove(), 300); }, 5000);
}

function toolChip(t) {
  return h('details', { class: 'tool' + (t.failed ? ' failed' : '') + (t.running ? ' running' : '') },
    h('summary', {}, h('span', { class: 'mark' }, t.running ? '' : t.failed ? '✕' : '✓'), (t.name ?? t.tool) + ' ' + clip(JSON.stringify(t.args), 120)),
    h('pre', {}, t.running ? 'running…' : t.result));
}

function message(m) {
  if (m.role === 'user') return h('div', { class: 'msg user' }, h('div', { class: 'role' }, 'you'), h('div', { class: 'body' }, m.content));
  if (m.role === 'error') return h('div', { class: 'msg error' }, h('div', { class: 'role' }, 'error'), h('div', { class: 'body' }, m.content));
  return h('div', { class: 'msg assistant' }, h('div', { class: 'role' }, 'veil'),
    (m.tools ?? []).map(toolChip),
    m.content ? h('div', { class: 'body md', html: render(m.content) }) : null);
}

function liveNode() {
  const L = S.live;
  return h('div', { class: 'msg assistant live', id: 'live' }, h('div', { class: 'role' }, 'veil'),
    L.tools.map(toolChip),
    L.text ? h('div', { class: 'body md', html: render(L.text) }) : h('div', { class: 'status' }, h('span', { class: 'dots', 'aria-hidden': 'true' }, h('i'), h('i'), h('i')), L.status));
}

let liveQueued = false;
function drawLive() {
  if (liveQueued) return;
  liveQueued = true;
  requestAnimationFrame(() => {
    liveQueued = false;
    const old = document.getElementById('live');
    if (!old || !S.live) return;
    const box = old.parentElement;
    const pinned = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
    const next = liveNode();
    next.classList.add('settled');   // only a message's first appearance animates
    old.replaceWith(next);
    if (pinned) box.scrollTop = box.scrollHeight;
  });
}

function download(name, text) {
  const a = h('a', { href: URL.createObjectURL(new Blob([text], { type: 'text/plain' })), download: name.split('/').pop() });
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

/* ---- side pane: Code (the workspace as an editor, with a live preview) ---- */

/* An HTML file as one self-contained document: the workspace stylesheets and scripts it names are put inline,
   so the preview shows the page the files make together. */
function inlined(html, files) {
  const at = (ref) => files[fileName(ref.split(/[?#]/)[0])];
  return String(html)
    .replace(/<link\b[^>]*\bhref=["']([^"']+)["'][^>]*>/gi, (tag, ref) => (/stylesheet/i.test(tag) && at(ref) !== undefined ? `<style>${at(ref)}</style>` : tag))
    .replace(/<script\b([^>]*)\bsrc=["']([^"']+)["']([^>]*)>\s*<\/script>/gi, (tag, a, ref, b) => (at(ref) !== undefined ? `<script${a}${b}>${at(ref).replace(/<\/script/gi, '<\\/script')}</` + 'script>' : tag));
}

const previewable = (name) => ['html', 'htm', 'svg', 'md', 'markdown'].includes(ext(name));

function codeTab() {
  const files = Object.keys(S.conv.files).sort();
  const open = S.file !== null && S.file in S.conv.files ? S.file : null;
  const addFile = () => {
    const name = fileName(prompt('New file name (for example index.html):') ?? '');
    if (!name || name.includes('..') || name.length > 200) return;
    if (!(name in S.conv.files)) fileEdited(name, '');
    S.file = name; S.preview = false;
    drawSide();
  };
  let body = null;
  if (open !== null) {
    const text = S.conv.files[open];
    const kind = ext(open);
    if (S.preview && (kind === 'md' || kind === 'markdown')) body = h('div', { class: 'doc md', html: render(text) });
    else if (S.preview && previewable(open)) body = h('iframe', { class: 'preview', title: 'Preview of ' + open, sandbox: 'allow-scripts', srcdoc: kind === 'svg' ? text : inlined(text, S.conv.files) });
    else body = h('textarea', { id: 'editor', class: 'editor', spellcheck: 'false', autocapitalize: 'off', autocomplete: 'off', 'aria-label': 'Contents of ' + open, value: text, oninput: (e) => fileEdited(open, e.target.value), onkeydown: (e) => {
      if (e.key !== 'Tab' || e.shiftKey || e.altKey || e.ctrlKey || e.metaKey) return;
      e.preventDefault();   // Tab indents; Escape then Tab leaves the editor
      const el = e.target, at = el.selectionStart;
      el.setRangeText('  ', at, el.selectionEnd, 'end');
      fileEdited(open, el.value);
    } });
  }
  return [
    h('div', { class: 'filebar' },
      files.map((n) => h('button', { class: 'file' + (n === open ? ' on' : ''), title: n, onclick: () => { S.file = n; S.preview = false; drawSide(); } }, n)),
      h('button', { class: 'file add', 'aria-label': 'New file', onclick: addFile }, '+ file')),
    open === null
      ? h('div', { class: 'empty' }, files.length ? 'Pick a file.' : 'Code the veil writes shows up here as it is written. You can edit it, preview a web page live, and download what you want to keep. Ask for something to be built, or start a file yourself.')
      : h('div', { class: 'viewer' },
          h('div', { class: 'vh' }, h('span', { class: 'name' }, open), h('span', { class: 'meta' }, S.conv.files[open].length + ' chars'),
            previewable(open) ? h('button', { class: 'btn btn-sm' + (S.preview ? ' btn-solid' : ''), 'aria-pressed': String(S.preview), onclick: () => { S.preview = !S.preview; drawSide(); } }, S.preview ? 'Code' : 'Preview') : null,
            h('button', { class: 'btn btn-ghost btn-sm', onclick: () => download(open, S.conv.files[open]) }, 'Download'),
            h('button', { class: 'btn btn-ghost btn-sm', 'aria-label': 'Delete ' + open, onclick: () => { if (!confirm('Delete ' + open + '?')) return; delete S.conv.files[open]; S.file = null; touchConv(); drawSide(); } }, 'Delete')),
          body),
  ];
}

/* ---- side pane: Jobs (the harness's FIFO queue and its schedules) ---- */
const REPEATS = [['0', 'Once'], ['900', 'Every 15 minutes'], ['3600', 'Every hour'], ['21600', 'Every 6 hours'], ['86400', 'Every day']];
const everyWords = (s) => (s % 86400 === 0 ? `${s / 86400} d` : s % 3600 === 0 ? `${s / 3600} h` : `${Math.round(s / 60)} min`);

function jobsTab() {
  const q = S.status?.queue;
  const task = h('textarea', { id: 'jobTask', rows: '3', placeholder: 'A task for the harness to work through on its own', 'aria-label': 'Job task' });
  const repeat = h('select', { id: 'jobRepeat', 'aria-label': 'Repeat', disabled: outdated() }, REPEATS.map(([v, l]) => h('option', { value: v }, l)));
  const queue = () => act('queue', async () => {
    const text = task.value.trim();
    if (!text) return;
    const every = Number(repeat.value);
    if (every > 0) await harnessJson('/v1/schedules', { body: { task: text, model: S.model, every_s: every } });
    else await harnessJson('/v1/jobs', { body: { task: text, model: S.model } });
    task.value = '';
    if (every > 0) S.schedules = (await harnessJson('/v1/schedules')).schedules;
    await refreshJobs();
    await refreshStatus();
  });
  const J = S.job;
  return [
    h('div', { class: 'block' },
      h('p', {}, `Jobs run on your worker harness, one at a time, first in first out, and go on with this tab closed.${q ? ` Up to ${q.max} can wait; the newest ${q.keep} finished are kept.` : ''} A repeating task queues itself each time it comes due.`),
      task,
      h('div', { class: 'acts' }, repeat, h('button', { class: 'btn btn-solid btn-sm', disabled: !!S.busy, onclick: queue }, S.busy === 'queue' ? 'Queuing…' : 'Queue job')),
      S.note && S.tab === 'jobs' ? h('div', { class: 'err' }, S.note) : null),
    S.schedules.length === 0 ? null : h('div', { class: 'block' }, h('h3', {}, 'Repeating'),
      S.schedules.map((s) => h('div', { class: 'item static' },
        h('span', { class: 'state running' }, everyWords(s.every_s)),
        h('span', { class: 'name', title: s.task }, s.task),
        h('span', { class: 'meta' }, 'next ' + new Date(s.next).toISOString().slice(11, 16) + ' UTC'),
        h('button', { class: 'x show', 'aria-label': 'Delete schedule', onclick: () => act('sched', async () => { await harnessJson('/v1/schedules/' + s.id, { method: 'DELETE' }); S.schedules = S.schedules.filter((x) => x.id !== s.id); }) }, '✕')))),
    h('div', { class: 'list' },
      S.jobs.length === 0 ? h('div', { class: 'empty' }, 'No jobs yet.') : null,
      [...S.jobs].reverse().map((j) => h('button', { class: 'item' + (J?.id === j.id ? ' on' : ''), onclick: async () => { try { S.job = (await harnessJson('/v1/jobs/' + j.id)).job; } catch (e) { S.note = e.message; } drawSide(); } },
        h('span', { class: 'state ' + j.state }, j.state), h('span', { class: 'name' }, j.task)))),
    !J ? null : h('div', { class: 'viewer' },
      h('div', { class: 'vh' }, h('span', { class: 'state ' + J.state }, J.state), h('span', { class: 'name' }, `${J.calls} model calls`),
        h('button', { class: 'btn btn-ghost btn-sm', onclick: () => act('jobdel', async () => { await harnessJson('/v1/jobs/' + J.id, { method: 'DELETE' }); S.job = null; await refreshJobs(); await refreshStatus(); }) }, J.state === 'queued' || J.state === 'running' ? 'Cancel' : 'Delete'),
        h('button', { class: 'btn btn-ghost btn-sm', 'aria-label': 'Close job', onclick: () => { S.job = null; drawSide(); } }, '✕')),
      h('div', { class: 'doc' },
        h('p', { class: 'fine' }, J.task),
        J.note ? h('p', { class: 'status' }, J.note) : null,
        J.rounds.map(toolChip),
        J.error ? h('div', { class: 'err' }, J.error) : null,
        J.result ? h('div', { class: 'md', html: render(J.result) }) : null,
        Object.keys(J.files).map((n) => h('div', { class: 'item static' }, h('span', { class: 'name' }, n),
          h('button', { class: 'btn btn-ghost btn-sm', onclick: () => { fileEdited(n, J.files[n]); S.file = n; S.tab = 'code'; drawSide(); } }, 'Open in Code'),
          h('button', { class: 'btn btn-ghost btn-sm', onclick: () => download(n, J.files[n]) }, 'Download'))))),
  ];
}

/* ---- side pane: Harness (update, usage, limits, Python, Agent Garrett) ---- */
function meter(label, used, max, fmt = String) {
  const part = max > 0 ? Math.min(1, used / max) : 0;
  return h('div', { class: 'meter' + (part >= 0.9 ? ' hot' : '') },
    h('div', { class: 'line' }, h('span', {}, label), h('span', {}, `${fmt(used)} / ${fmt(max)}`)),
    h('div', { class: 'track', role: 'progressbar', 'aria-label': label, 'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-valuenow': String(Math.round(part * 100)) }, h('div', { class: 'fill', style: `width:${(part * 100).toFixed(1)}%` })));
}

function garrettBlock(st) {
  const G = CFG.garrett;
  if (st.garrett.connected) return h('div', { class: 'block', id: 'garrett' }, h('h3', {}, 'Agent Garrett'),
    h('p', {}, `Connected to ${st.garrett.host}${st.garrett.tools ? ` (${st.garrett.tools} tools)` : ''}. Its security tools are on the veil's belt in chat and in jobs.`),
    h('div', { class: 'acts' }, h('a', { class: 'btn btn-sm', href: G.dashboard, target: '_blank', rel: 'noopener' }, 'Open dashboard'),
      h('button', { class: 'btn btn-sm btn-ghost', disabled: !!S.busy, onclick: () => act('garrett', async () => { S.status = await harnessJson('/v1/garrett', { body: {} }); }) }, 'Disconnect')));
  const key = h('input', { id: 'gKey', type: 'password', placeholder: 'gtt_…', 'aria-label': 'Agent Garrett key', autocomplete: 'off', spellcheck: 'false' });
  const gUrl = h('input', { id: 'gUrl', type: 'url', placeholder: 'https://…/mcp', 'aria-label': 'Agent Garrett MCP address' });
  const gTok = h('input', { id: 'gTok', type: 'password', placeholder: 'its MCP token', 'aria-label': 'Agent Garrett MCP token', autocomplete: 'off' });
  return h('div', { class: 'block feature', id: 'garrett' }, h('h3', {}, 'Agent Garrett: security tools for this veil'),
    h('p', {}, 'Agent Garrett is a security agent by the same author as the veil. Connected, it puts its tools on the veil\'s belt here: CVE, KEV and EPSS intelligence, DNS and certificate transparency, RDAP, email security posture, IOC extraction, evidence manifests and more.'),
    h('p', {}, link({ label: 'What is Agent Garrett?', href: G.what }), ' · ', link({ label: 'How to use it', href: G.how }), ' · ', link({ label: 'Blog', href: G.blog })),
    h('ol', { class: 'steps' },
      h('li', {}, 'Get a key: ', link({ label: 'open the Agent Garrett dashboard', href: G.dashboard }), ', set up your agent, and copy its API key.'),
      h('li', {}, 'Paste it here. It is kept in your harness, not in this browser.')),
    key,
    h('div', { class: 'acts' }, h('button', { class: 'btn btn-sm btn-solid', disabled: !!S.busy || outdated(), onclick: () => act('garrett', async () => { S.status = await harnessJson('/v1/garrett', { body: { key: key.value.trim() } }); toast('Agent Garrett is connected.'); }) }, S.busy === 'garrett' ? 'Connecting…' : 'Connect Agent Garrett')),
    h('details', { class: 'more' }, h('summary', {}, 'Running an agent of your own?'),
      gUrl, h('div', { style: 'height:6px' }), gTok,
      h('div', { class: 'acts' }, h('button', { class: 'btn btn-sm', disabled: !!S.busy, onclick: () => act('garrett', async () => { S.status = await harnessJson('/v1/garrett', { body: { url: gUrl.value.trim(), token: gTok.value } }); }) }, 'Connect by address'))));
}

function harnessTab() {
  const st = S.status;
  if (!st) return [h('div', { class: 'empty' }, 'Asking the harness…')];
  const num = (id, label, value) => [h('label', { for: id }, label), h('input', { id, type: 'number', min: '1', value: String(value) })];
  return [
    outdated() ? h('div', { class: 'block feature' }, h('h3', {}, 'Update your harness'),
      h('p', {}, `Your harness is version ${st.version}; this page is written for version ${CFG.harness_version}. Until it is updated, the model list, schedules, chat sync, the better web search and one-step Agent Garrett are off.`),
      h('div', { class: 'acts' }, h('button', { class: 'btn btn-sm btn-solid', disabled: !!S.busy, onclick: () => act('update', updateHarness) }, S.busy === 'update' ? 'Updating…' : 'Update harness'))) : null,
    S.note && S.tab === 'harness' ? h('div', { class: 'block' }, h('div', { class: 'err' }, S.note)) : null,
    h('div', { class: 'block' }, h('h3', {}, 'Today (UTC)'),
      meter('Model calls', st.usage.calls, st.limits.calls_max),
      meter('Data moved', st.usage.bytes, st.limits.bytes_max, mb),
      meter('Chats and job data kept', st.storage_bytes, st.limits.storage_max, mb),
      meter('Jobs waiting', st.queue.waiting, st.queue.max),
      h('p', {}, 'A spent daily budget refuses new work until 00:00 UTC. Past the storage limit, the oldest finished jobs are dropped first.')),
    garrettBlock(st),
    h('div', { class: 'block' }, h('h3', {}, 'Python'),
      st.python.deployed
        ? h('p', {}, 'The Python Worker is in place (veil-web-py). The veil can run Python in chat and in jobs.')
        : h('p', {}, 'The veil\'s Python runs in a second Worker in your account (veil-web-py). The harness puts it there with your login.'),
      h('div', { class: 'acts' }, h('button', { class: 'btn btn-sm' + (st.python.deployed ? '' : ' btn-solid'), disabled: !!S.busy, onclick: () => act('python', async () => { S.status = await harnessJson('/v1/python/deploy', { body: {} }); }) },
        S.busy === 'python' ? 'Deploying…' : st.python.deployed ? 'Deploy again' : 'Deploy Python'))),
    h('div', { class: 'block' }, h('h3', {}, 'Limits'),
      num('limCalls', 'Model calls a day', st.limits.calls_max),
      num('limBytes', 'Data a day (MB)', Math.round(st.limits.bytes_max / MB)),
      num('limStore', 'Chats and job data kept (MB)', Math.round(st.limits.storage_max / MB)),
      h('div', { class: 'acts' }, h('button', { class: 'btn btn-sm', disabled: !!S.busy, onclick: () => act('limits', async () => {
        const v = (id) => Number(document.getElementById(id).value);
        S.status = await harnessJson('/v1/config', { body: { calls_max: v('limCalls'), bytes_max: v('limBytes') * MB, storage_max: v('limStore') * MB } });
      }) }, 'Save limits'))),
    h('div', { class: 'block' }, h('h3', {}, 'This harness'),
      h('p', { class: 'mono' }, S.harness.replace(/^https?:\/\//, '') + ' · version ' + st.version),
      h('p', {}, 'Context fold: ' + (core.x ? 'veil_core.wasm (4tope) loaded.' : 'the wasm core did not load; the oldest rounds are dropped instead.')),
      h('p', {}, 'Anything logged in to this Cloudflare account can use this harness: this page in any browser, and other veils that hold your login.'),
      h('div', { class: 'acts' },
        outdated() ? null : h('button', { class: 'btn btn-sm', disabled: !!S.busy, onclick: () => act('update', updateHarness) }, S.busy === 'update' ? 'Updating…' : 'Check for a newer harness'),
        h('button', { class: 'btn btn-sm btn-danger', onclick: () => { if (confirm('Forget this harness in this browser? The Worker stays in your Cloudflare account until you delete it there.')) { ls.del('veilweb.harness'); S.harness = null; S.status = null; draw(); } } }, 'Forget this harness'))),
  ];
}

function sidePane() {
  const tab = (id, label) => h('button', { class: S.tab === id ? 'on' : '', role: 'tab', 'aria-selected': String(S.tab === id), onclick: () => { S.tab = id; S.note = ''; drawSide(); if (id === 'jobs') refreshJobs(); if (id === 'harness') refreshStatus(); } }, label);
  const active = S.jobs.filter((j) => j.state === 'queued' || j.state === 'running').length;
  const files = Object.keys(S.conv.files).length;
  return h('aside', { class: 'side', id: 'side' },
    h('div', { class: 'tabs', role: 'tablist' }, tab('code', files ? `Code (${files})` : 'Code'), tab('jobs', active ? `Jobs (${active})` : 'Jobs'), tab('harness', outdated() ? 'Harness •' : 'Harness'),
      h('span', { class: 'grow' }),
      h('button', { class: 'widen', 'aria-label': S.wide ? 'Narrow this panel' : 'Widen this panel', 'aria-pressed': String(S.wide), title: S.wide ? 'Narrow' : 'Widen', onclick: () => { S.wide = !S.wide; document.querySelector('.shell')?.classList.toggle('wide', S.wide); drawSide(); } }, S.wide ? '⇥' : '⇤')),
    h('div', { class: 'pane tab-' + S.tab }, S.tab === 'code' ? codeTab() : S.tab === 'jobs' ? jobsTab() : harnessTab()));
}

function drawSide() {
  const old = document.getElementById('side');
  if (!old) return;
  // what is half-typed in the pane survives its redraw, and so does the caret
  const keep = {};
  for (const el of old.querySelectorAll('input, textarea, select')) if (el.id && el.id !== 'editor' && (document.activeElement === el || (el.value && el.type !== 'number'))) keep[el.id] = el.value;
  const focus = document.activeElement?.id;
  const caret = focus === 'editor' ? [document.activeElement.selectionStart, document.activeElement.selectionEnd, document.activeElement.scrollTop] : null;
  const scroll = old.querySelector('.pane')?.scrollTop ?? 0;
  old.replaceWith(sidePane());
  for (const [id, v] of Object.entries(keep)) { const el = document.getElementById(id); if (el) el.value = v; }
  const pane = document.querySelector('#side .pane');
  if (pane) pane.scrollTop = scroll;
  const again = focus && document.getElementById(focus);
  if (again && (keep[focus] !== undefined || caret)) {
    again.focus();
    if (caret) { again.setSelectionRange(caret[0], caret[1]); again.scrollTop = caret[2]; }
  }
}

function send(text) {
  const box = document.getElementById('prompt');
  const said = (text ?? box.value).trim();
  if (!said || S.live) return;
  box.value = '';
  box.style.height = 'auto';
  runTurn(said);
}

const SUGGESTIONS = [
  'Build a one-page site for a coffee shop and show it in the Code tab',
  'Put three minds on this: should a small team self-host its git?',
  'Queue a job: read today\'s Cloudflare blog and write me a summary file',
  'Who is Agent Garrett?',
];

function welcome() {
  const G = CFG.garrett;
  return h('div', { class: 'welcome' }, h('h1', {}, 'What are we working on?'),
    h('p', {}, 'The veil can search and read the web, write code you watch and preview in the Code tab, put several minds on one question, and hand long or repeating work to your harness as jobs.'),
    h('div', { class: 'chips' }, SUGGESTIONS.map((s) => h('button', { class: 'suggest', onclick: () => send(s) }, s))),
    S.status?.garrett?.connected ? null : h('div', { class: 'panel promo' },
      h('div', {}, h('strong', {}, 'Add Agent Garrett\'s security tools'),
        h('p', {}, 'CVE and KEV intelligence, DNS and certificate recon, IOC extraction and more, called by the veil in this chat. ', link({ label: 'What is Agent Garrett?', href: G.what }))),
      h('button', { class: 'btn btn-solid btn-sm', onclick: () => { S.tab = 'harness'; S.panes.side = true; draw(); queueMicrotask(() => document.getElementById('garrett')?.scrollIntoView({ block: 'start' })); } }, 'Connect')));
}

function linksBlock() {
  return h('div', { class: 'links' },
    h('button', { class: 'pane-head toggle', 'aria-expanded': String(!!S.linksOpen), onclick: () => { S.linksOpen = !S.linksOpen; ls.set('veilweb.links', S.linksOpen); draw(); } }, 'Links', h('span', { 'aria-hidden': 'true' }, S.linksOpen ? '–' : '+')),
    S.linksOpen ? CFG.links.map((g) => h('div', { class: 'link-group' }, h('div', { class: 'link-head' }, g.group), g.items.map((i) => link(i, 'item')))) : null);
}

function dashboard() {
  const c = S.conv;
  const transcript = h('div', { class: 'transcript' },
    c.msgs.length === 0 && !S.live ? welcome() : null,
    c.msgs.map(message),
    S.live ? liveNode() : null);
  const close = () => { S.panes.rail = false; S.panes.side = false; draw(); };
  const shell = h('div', { class: 'shell' + (S.wide ? ' wide' : '') + (S.panes.rail ? ' show-rail' : '') + (S.panes.side ? ' show-side' : '') },
    h('aside', { class: 'rail' },
      h('div', { class: 'pane-head' }, 'Chats', h('button', { class: 'btn btn-ghost btn-sm', disabled: !!S.live, onclick: () => { newConv(); S.panes.rail = false; draw(); } }, '+ New')),
      h('div', { class: 'list' },
        S.convs.length === 0 ? h('div', { class: 'empty' }, 'Your chats are kept in your harness, so they follow your login to any browser.') : null,
        S.convs.map((x) => h('div', { class: 'item' + (x.id === c.id ? ' on' : ''), role: 'button', tabindex: '0', onclick: () => openConv(x.id), onkeydown: (e) => { if (e.key === 'Enter') openConv(x.id); } },
          h('span', { class: 'name' }, x.title),
          h('button', { class: 'x', 'aria-label': 'Delete conversation', onclick: (e) => { e.stopPropagation(); deleteConv(x.id); } }, '✕')))),
      linksBlock(),
      h('div', { class: 'who' }, h('span', { class: 'name', title: S.me?.email || '' }, S.me?.email || S.me?.account_name || 'Logged in with Cloudflare'),
        h('button', { class: 'btn btn-ghost btn-sm', onclick: () => logout() }, 'Log out'))),
    h('main', { class: 'chat' }, transcript,
      h('div', { class: 'composer' },
        h('textarea', { id: 'prompt', rows: '1', placeholder: 'Message the veil', 'aria-label': 'Message', onkeydown: (e) => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); } }, oninput: (e) => { e.target.style.height = 'auto'; e.target.style.height = Math.min(220, e.target.scrollHeight) + 'px'; } }),
        S.live ? h('button', { class: 'btn', onclick: () => S.live.abort.abort() }, 'Stop') : h('button', { class: 'btn btn-solid', onclick: () => send() }, 'Send'))),
    sidePane(),
    h('div', { class: 'scrim', onclick: close }));
  queueMicrotask(() => { transcript.scrollTop = transcript.scrollHeight; if (!S.live && !S.panes.rail && !S.panes.side && matchMedia('(min-width: 981px)').matches) document.getElementById('prompt')?.focus(); });
  return shell;
}

/* Arrival: nothing but the login. */
function gate() {
  return h('div', { class: 'gate' }, h('div', { class: 'panel gate-card' },
    h('div', { class: 'section-eyebrow' }, 'the veil · in your browser'),
    h('h1', {}, 'Log in with Cloudflare to chat'),
    h('p', {}, 'The chat runs in this tab on your own Cloudflare account: the model is your account\'s Workers AI, and the work is done by a worker harness that lives in your account.'),
    h('ul', {},
      h('li', {}, 'The login happens between this page and Cloudflare. No server of ours sees it.'),
      h('li', {}, 'Chats, code and jobs are kept in your harness, so they follow your login.'),
      h('li', {}, 'The login is kept for this tab only; closing the tab ends it.')),
    h('div', { class: 'gate-acts' }, h('button', { class: 'btn btn-solid btn-lg', onclick: login }, 'Log in with Cloudflare'),
      h('a', { class: 'btn btn-ghost', href: '../#get' }, 'Or get the desktop app')),
    h('div', { class: 'err', role: 'alert' }, S.err),
    h('p', { class: 'fine gate-links' }, CFG.links[0].items.flatMap((i, n) => [n ? ' · ' : '', link(i)]))));
}

/* Logged in, no harness yet: deploy one, or find the one already there. */
function setup() {
  const name = h('input', { id: 'hname', type: 'text', placeholder: 'your workers.dev name, or the Worker\'s address', 'aria-label': 'Your workers.dev name or the Worker\'s address', autocomplete: 'off', spellcheck: 'false', value: S.harness ? S.harness.replace(/^https?:\/\//, '') : '', onkeydown: (e) => { if (e.key === 'Enter') go(); } });
  const go = () => { const u = harnessUrl(name.value); if (!u) { S.err = `That is not a workers.dev name or a Worker address. The address looks like ${CFG.script}.<your-name>.workers.dev`; return draw(); } findHarness(u); };
  return h('div', { class: 'gate' }, h('div', { class: 'panel gate-card' },
    h('div', { class: 'section-eyebrow' }, 'logged in · one step left'),
    h('h1', {}, 'Deploy your worker harness'),
    h('p', {}, 'The harness is one Worker in your Cloudflare account. It calls the model, reads the web, keeps your chats, runs queued and repeating jobs in turn, and keeps to daily limits you can change. Only a login to your account can use it.'),
    h('div', { class: 'gate-acts' }, h('a', { class: 'btn btn-solid btn-lg', href: CFG.deploy_url, target: '_blank', rel: 'noopener' }, 'Deploy to Cloudflare'),
      h('span', { class: 'fine' }, 'Opens Cloudflare\'s deploy page. It builds the Worker from a copy of its source in a GitHub or GitLab account of yours.')),
    h('hr', { class: 'gate-sep' }),
    h('p', {}, 'Deployed it, or have one already? Tell this page where it is and it checks that your login owns it.'),
    h('div', { class: 'gate-field' }, name, h('button', { class: 'btn', disabled: S.checking, onclick: go }, S.checking ? 'Checking…' : 'Find my harness')),
    h('p', { class: 'fine', style: 'margin-top:8px' }, 'Your workers.dev name is the middle part of any of your Worker addresses: ' + CFG.script + '.<name>.workers.dev.'),
    h('div', { class: 'err', role: 'alert' }, S.err),
    h('div', { class: 'gate-acts' }, h('button', { class: 'btn btn-ghost btn-sm', onclick: () => logout() }, 'Log out'))));
}

function pickModel(sel) {
  if (sel.value === '+') {
    const id = (prompt('Workers AI model id (starts with @cf/ or @hf/):', S.model) ?? '').trim();
    if (id.startsWith('@')) S.model = id;
  } else S.model = sel.value;
  ls.set('veilweb.model', S.model);
  draw();
}

/* The model picker: the account's own list from the harness, grouped by who made the model. */
function modelSelect() {
  const ids = [...new Set([...(S.models.length ? S.models.map((m) => m.id) : CFG.models), S.model])].sort();
  const groups = new Map();
  for (const id of ids) {
    const maker = id.split('/')[1] ?? 'other';
    if (!groups.has(maker)) groups.set(maker, []);
    groups.get(maker).push(id);
  }
  return h('select', { 'aria-label': 'Model', title: S.model, disabled: !!S.live, onchange: (e) => pickModel(e.target) },
    [...groups].map(([maker, list]) => h('optgroup', { label: maker }, list.map((m) => h('option', { value: m, selected: m === S.model }, m.split('/').slice(2).join('/') || m)))),
    h('option', { value: '+' }, 'Other model…'));
}

function draw() {
  const on = !!(S.session && S.status);
  const draft = document.getElementById('prompt')?.value ?? '';
  const typed = document.getElementById('hname')?.value ?? '';
  const sideKeep = {};
  for (const el of document.querySelectorAll('#side input, #side textarea:not(#editor), #side select')) if (el.id && el.value && el.type !== 'number') sideKeep[el.id] = el.value;
  barSlot.replaceChildren(...(on ? [
    h('button', { class: 'icon-btn only-narrow', 'aria-label': 'Chats and links', onclick: () => { S.panes.rail = !S.panes.rail; S.panes.side = false; draw(); } }, '☰'),
    modelSelect(),
    outdated()
      ? h('button', { class: 'chip warn', onclick: () => { S.tab = 'harness'; S.panes.side = true; draw(); } }, h('span', { class: 'chip-dot' }), 'update harness')
      : h('span', { class: 'chip', title: S.harness }, h('span', { class: 'chip-dot' }), 'harness connected'),
    h('button', { class: 'icon-btn only-narrow', 'aria-label': 'Code, jobs and harness', onclick: () => { S.panes.side = !S.panes.side; S.panes.rail = false; draw(); } }, '▤'),
  ] : []));
  app.replaceChildren(!S.session ? gate() : on ? dashboard() : setup());
  const box = document.getElementById('prompt');
  if (box && draft) box.value = draft;
  const a = document.getElementById('hname');
  if (a && typed) a.value = typed;
  for (const [id, v] of Object.entries(sideKeep)) { const el = document.getElementById(id); if (el) el.value = v; }
}

/* ============================================================ theme (the site's three, the site's key) */

const THEMES = ['light', 'dark', 'matrix'];
const THEME_ICONS = {
  light: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4"/></svg>',
  dark: '<svg viewBox="0 0 24 24"><path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11z"/></svg>',
  matrix: '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M13 15h4"/></svg>',
};
function setTheme(id) {
  if (!THEMES.includes(id)) id = 'light';
  document.documentElement.setAttribute('data-theme', id);
  try { localStorage.setItem('veil.theme', id); } catch {}
  const btn = document.getElementById('themeBtn');
  btn.innerHTML = THEME_ICONS[id];
  btn.title = 'Theme: ' + id + ' (click to cycle)';
}
document.getElementById('themeBtn').addEventListener('click', () => setTheme(THEMES[(THEMES.indexOf(document.documentElement.getAttribute('data-theme')) + 1) % THEMES.length]));
setTheme(document.documentElement.getAttribute('data-theme'));

/* ============================================================ boot */

(async () => {
  S.convs = (await db.get('convs')) ?? [];
  newConv();
  await finishLogin();
  draw();
  core.load();
  if (S.session && S.harness) findHarness(S.harness, true);
})();
