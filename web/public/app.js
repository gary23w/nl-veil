/* ============================================================================
   the veil — web client
   A port of the native desk (desk/src/*) to the browser. Same product, same
   palette, different constraints:
     - The desk executes tool calls on YOUR machine. A browser cannot, so every
       turn posted from here OMITS `tool_client` and the server runs the whole
       tool surface itself (engine.zig:3705 takes the tools.execute branch when
       the flag is absent). That is the entire "web mode is server-side" story:
       there is no flag to set, only one we must never send.
     - No build step. One file, served straight out of the binary via
       @embedFile (build.zig:71-74), so a rebuild is required to see a change.
   ========================================================================= */

'use strict';

/* ============================================================ state */

const S = {
  me: null,             // {id,email,plan} once authed
  isAdmin: false,
  tab: 'chat',
  online: false,
  fleet: { live: 0, minds: 0, headroom: 0 },
  metrics: null,
  models: null,         // parsed models.json — the shared catalog
  localModels: null,    // {installed:[…]} from this machine's Ollama, or null if unreachable
  keys: [],             // provider keys on file (never the key itself)
  serverDefault: { model: '', base_url: '' },  // what the host configured for users who pick nothing
  // chat
  convs: [],
  conv: null,           // active conversation id
  msgs: [],             // [{role,content,kind,ts}]
  live: false,          // a turn is running for the active conv
  stream: { text: '', reasoning: '', tools: [], status: '' },
  cursor: 0,            // events.jsonl byte offset
  poll: null,
  settings: null,       // filled by loadSettings() at boot
};

const LS = {
  get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
};

function loadSettings() {
  let s = {};
  const raw = LS.get('veil.settings', '');
  if (raw) { try { s = JSON.parse(raw); } catch (e) { s = {}; } }
  return Object.assign({
    base_url: '', model: '', api_key: '',
    think_base_url: '', think_model: '', think_api_key: '',
    prompt_base_url: '', prompt_model: '', prompt_api_key: '',
    oneModel: true,
    loop: 0,
  }, s);
}
function saveSettings() { LS.set('veil.settings', JSON.stringify(S.settings)); }

/* ============================================================ dom helpers */

const $  = (sel, root) => (root || document).querySelector(sel);
const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
const el = (id) => document.getElementById(id);

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

/** Abbreviate the way the desk does (fmtCount, main.zig:1688) — 73.7k, 1.2M. */
function fmtCount(n) {
  n = Number(n) || 0;
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, '') + 'k';
  return String(n);
}

function fmtWhen(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  const now = new Date();
  if (d.toDateString() === now.toDateString()) {
    return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }
  if ((now - d) / 86400000 < 7) return d.toLocaleDateString([], { weekday: 'short' });
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

function toast(title, body, cls) {
  const host = el('toasts');
  if (!host) return;
  const n = document.createElement('div');
  n.className = 'toast ' + (cls || '');
  n.innerHTML = '<b>' + esc(title) + '</b>' + (body ? '<span>' + esc(body) + '</span>' : '');
  host.appendChild(n);
  setTimeout(() => { if (n.parentNode) n.parentNode.removeChild(n); }, 5000);
  // The desk caps the visible stack at 4 (main.zig:7443); match it.
  while (host.children.length > 4) host.removeChild(host.firstChild);
}

/* ============================================================ api */

async function req(path, opts, ms) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), ms || 15000);
  try {
    return await fetch(path, Object.assign({ credentials: 'same-origin', signal: ctl.signal }, opts || {}));
  } finally {
    clearTimeout(timer);
  }
}

async function jget(path, ms) {
  const r = await req(path, null, ms);
  if (r.status === 401) { onSignedOut(); throw new Error('unauthorized'); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.err || ('HTTP ' + r.status)); e.status = r.status; throw e; }
  return j;
}

async function jpost(path, body, ms) {
  const r = await req(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body || {}),
  }, ms);
  if (r.status === 401) { onSignedOut(); throw new Error('unauthorized'); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.err || ('HTTP ' + r.status)); e.status = r.status; throw e; }
  return j;
}

async function jdel(path) {
  const r = await req(path, { method: 'DELETE' });
  if (r.status === 401) { onSignedOut(); throw new Error('unauthorized'); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.err || ('HTTP ' + r.status)); e.status = r.status; throw e; }
  return j;
}

const api = {
  me:       ()      => jget('/api/v1/auth/me'),
  login:    (e, p)  => jpost('/api/v1/auth/login', { email: e, password: p }),
  register: (e, p)  => jpost('/api/v1/auth/register', { email: e, password: p }),
  logout:   ()      => jpost('/api/v1/auth/logout', {}),
  fleet:    ()      => jget('/api/v1/fleet', 6000),
  metrics:  ()      => jget('/api/v1/metrics/llm', 10000),
  models:   ()      => jget('/models.json'),
  convs:    ()      => jget('/api/v1/chat/convs'),
  conv:     (id)    => jget('/api/v1/chat/convs/' + encodeURIComponent(id)),
  convDel:  (id)    => jdel('/api/v1/chat/convs/' + encodeURIComponent(id)),
  send:     (id, b) => jpost('/api/v1/chat/convs/' + encodeURIComponent(id) + '/messages', b, 30000),
  control:  (id, b) => jpost('/api/v1/chat/convs/' + encodeURIComponent(id) + '/control', b),
  sched:    ()      => jget('/api/v1/sched'),
  swarms:   ()      => jget('/api/v1/swarms'),
  convFiles:(id)    => jget('/api/v1/chat/convs/' + encodeURIComponent(id) + '/files'),
  adminUsers:  ()   => jget('/api/v1/admin/users'),
  adminActivity:(uid) => jget('/api/v1/admin/users/' + encodeURIComponent(uid) + '/activity'),
  adminCreate: (e,p) => jpost('/api/v1/admin/users', { email: e, password: p }),
  adminModerate:(e,a) => jpost('/api/v1/admin/users/moderate', { email: e, action: a }),
};

/* ============================================================ theme */

function currentTheme() { return document.documentElement.getAttribute('data-theme') || 'light'; }

function setTheme(t) {
  document.documentElement.setAttribute('data-theme', t);
  LS.set('veil.theme', t);
  $$('meta[name=theme-color]').forEach((m) => m.remove());
  const meta = document.createElement('meta');
  meta.name = 'theme-color';
  meta.content = t === 'dark' ? '#16161e' : '#e9edf5';
  document.head.appendChild(meta);
  const b = el('themeBtn');
  if (b) b.innerHTML = themeIcon();
}

function themeIcon() {
  return currentTheme() === 'dark'
    ? '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4"/></svg>'
    : '<svg viewBox="0 0 24 24"><path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11z"/></svg>';
}

/* ============================================================ boot */

async function boot() {
  S.settings = loadSettings();
  loadModels();
  // /auth/me never 401s: it answers {authed:false, open_registration} when
  // signed out and {authed:true, email, admin, plan, id, entitlements, …}
  // when signed in (auth_api.zig:55-59). There is no `user` wrapper.
  try {
    const me = await api.me();
    S.openReg = !!me.open_registration;
    S.serverDefault = { model: me.default_model || '', base_url: me.default_base_url || '' };
    if (me.authed) return enterApp(me);
  } catch (e) { /* the server is not up yet */ }
  renderAuth();
}

async function loadModels() {
  try { S.models = await api.models(); } catch (e) { S.models = null; }
}

/** Ask the server which local models Ollama actually has. Unreachable is normal
    (hosted-only users have no Ollama), and then we leave the catalog's local
    list alone rather than hiding every local option. */
async function loadLocalModels() {
  try {
    const j = await jget('/api/v1/models/local', 8000);
    S.localModels = j.reachable ? j : null;
  } catch (e) {
    S.localModels = null;
  }
}

function onSignedOut() {
  stopPoll();
  S.me = null;
  S.conv = null;
  renderAuth('Signed out.', 'ok');
}

/* ============================================================ auth screen */

function renderAuth(msg, msgCls) {
  el('app').innerHTML = `
    <div class="auth-wrap">
      <form class="auth-card" id="authForm" autocomplete="on">
        <div class="auth-brand">the veil</div>
        <div class="auth-tag">a hive mind you talk to — running on your machine</div>

        <div class="field">
          <label for="auEmail">Email</label>
          <input id="auEmail" name="email" type="email" autocomplete="username"
                 required autocapitalize="none" spellcheck="false">
        </div>
        <div class="field">
          <label for="auPass">Password</label>
          <input id="auPass" name="password" type="password" autocomplete="current-password" required>
        </div>

        <div class="auth-actions">
          <button class="btn btn-solid" type="submit" id="auLogin">Log in</button>
          ${S.openReg ? '<button class="btn" type="button" id="auReg">Register</button>' : ''}
        </div>
        ${S.openReg ? '' : '<div class="auth-note">Registration is closed on this instance.</div>'}
        <div id="auMsg" class="auth-msg ${msg ? (msgCls || 'ok') : 'hide'}">${esc(msg || '')}</div>
      </form>
    </div>`;

  el('authForm').addEventListener('submit', (ev) => { ev.preventDefault(); doAuth('login'); });
  // The Register button only EXISTS when the instance accepts registrations, so
  // this has to be conditional. Attaching unconditionally threw during boot on
  // any closed instance — which is the default — and the throw happened before
  // focus() ran, so the form rendered but the email field never took focus.
  const reg = el('auReg');
  if (reg) reg.addEventListener('click', () => doAuth('register'));
  el('auEmail').focus();
}

function authMsg(text, cls) {
  const m = el('auMsg');
  if (!m) return;
  m.textContent = text;
  m.className = 'auth-msg ' + (cls || 'err');
}

async function doAuth(mode) {
  const email = el('auEmail').value.trim();
  const pass = el('auPass').value;
  if (!email || !pass) return authMsg('Email and password are required.');
  const btn = mode === 'login' ? el('auLogin') : el('auReg');
  btn.disabled = true;
  try {
    if (mode === 'register') {
      await api.register(email, pass);
      authMsg('Account created — now log in.', 'ok');
    } else {
      await api.login(email, pass);
      // /auth/me answers {authed, email, admin, plan, id, …} — there is no
      // `user` wrapper. Reading one gave enterApp(undefined) and a login that
      // failed with "Cannot read properties of undefined" AFTER the cookie was
      // already set, so the session existed but the app never opened.
      const me = await api.me();
      if (!me.authed) return authMsg('Signed in, but the session did not stick.');
      return enterApp(me);
    }
  } catch (e) {
    authMsg(e.message || 'That did not work.');
  } finally {
    btn.disabled = false;
  }
}

/* ============================================================ shell */

const TABS = [
  { id: 'dashboard', label: 'Dashboard', icon: 'M3 13h6V3H3v10zm0 8h6v-6H3v6zm8 0h10V11H11v10zm0-18v6h10V3H11z' },
  { id: 'chat',      label: 'Chat',      icon: 'M21 11.5a8.4 8.4 0 0 1-9 8.4 9 9 0 0 1-3.9-.9L3 21l1.9-4.6A8.4 8.4 0 0 1 4 11.5a8.5 8.5 0 0 1 17 0z' },
  { id: 'tasks',     label: 'Tasks',     icon: 'M12 8v4l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z' },
  { id: 'swarms',    label: 'Swarms',    icon: 'M12 3v4M12 17v4M3 12h4M17 12h4M7.8 7.8l2.8 2.8M13.4 13.4l2.8 2.8M16.2 7.8l-2.8 2.8M10.6 13.4l-2.8 2.8' },
  { id: 'admin',     label: 'Admin',     adminOnly: true, icon: 'M12 2l7 4v6c0 4.4-3 8.3-7 10-4-1.7-7-5.6-7-10V6l7-4zM9 12l2 2 4-4' },
  { id: 'settings',  label: 'Settings',  icon: 'M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM4.3 14.6l-1.6 1 1.9 3.3 1.8-.7a7 7 0 0 0 1.9 1.1l.3 1.9h3.8l.3-1.9a7 7 0 0 0 1.9-1.1l1.8.7 1.9-3.3-1.6-1a7 7 0 0 0 0-2.2l1.6-1-1.9-3.3-1.8.7a7 7 0 0 0-1.9-1.1L12.4 2H8.6l-.3 1.9a7 7 0 0 0-1.9 1.1l-1.8-.7-1.9 3.3 1.6 1a7 7 0 0 0 0 2.2z' },
];

function enterApp(user) {
  // Defensive: every caller has already checked `authed`, but a shape surprise
  // here used to throw INSIDE the click handler and leave the user staring at a
  // login form that had, in fact, just logged them in.
  if (!user || typeof user !== 'object') {
    renderAuth('The server sent an unexpected sign-in response.', 'err');
    return;
  }
  S.me = user;
  S.isAdmin = !!user.admin;
  S.tab = LS.get('veil.tab', 'chat');
  if (!visibleTabs().some((t) => t.id === S.tab)) S.tab = 'chat';

  el('app').innerHTML = `
    <header class="topbar">
      <div class="brand">the veil <small>${esc(user.email || '')}</small></div>
      <div class="grow"></div>
      <div class="status-chip"><i class="status-dot" id="statusDot"></i><span id="statusText">checking…</span></div>
      <button class="icon-btn" id="themeBtn" title="Toggle light / dark" aria-label="Toggle theme">${themeIcon()}</button>
      <button class="icon-btn" id="outBtn" title="Sign out" aria-label="Sign out">
        <svg viewBox="0 0 24 24"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg>
      </button>
    </header>

    <nav class="tabbar" role="tablist">
      ${visibleTabs().map((t) => `<button class="tab" role="tab" data-tab="${t.id}">${t.label}</button>`).join('')}
    </nav>

    <main class="view" id="view"></main>

    <nav class="mobilenav">
      ${visibleTabs().map((t) => `<button data-tab="${t.id}" aria-label="${t.label}">
        <svg viewBox="0 0 24 24"><path d="${t.icon}"/></svg>${t.label}</button>`).join('')}
    </nav>`;

  el('themeBtn').addEventListener('click', () => setTheme(currentTheme() === 'dark' ? 'light' : 'dark'));
  el('outBtn').addEventListener('click', async () => {
    try { await api.logout(); } catch (e) {}
    onSignedOut();
  });
  $$('[data-tab]').forEach((b) => b.addEventListener('click', () => setTab(b.dataset.tab)));

  setTab(S.tab);
  pollHealth();
  setInterval(pollHealth, 8000);
}

/** Tabs this account may actually use. The Admin tab is not merely hidden — every
    route behind it is admin-gated server-side, so hiding it is presentation, not
    the security boundary. */
function visibleTabs() {
  return TABS.filter((t) => !t.adminOnly || S.isAdmin);
}

function setTab(id) {
  S.tab = id;
  LS.set('veil.tab', id);
  $$('[data-tab]').forEach((b) => b.classList.toggle('active', b.dataset.tab === id));
  // Leaving chat must not leave a poll running against a conversation nobody is
  // looking at — that is one request per second, forever, on cellular.
  if (id !== 'chat') stopPoll();
  const v = el('view');
  if (id === 'dashboard') return renderDashboard(v);
  if (id === 'chat')      return renderChat(v);
  if (id === 'tasks')     return renderTasks(v);
  if (id === 'swarms')    return renderSwarms(v);
  if (id === 'admin')     return renderAdmin(v);
  if (id === 'settings')  return renderSettings(v);
}

async function pollHealth() {
  try {
    const f = await api.fleet();
    S.online = true;
    S.fleet = { live: f.live || f.swarms || 0, minds: f.minds || 0, headroom: f.headroom || 0 };
  } catch (e) {
    S.online = false;
  }
  const dot = el('statusDot'), txt = el('statusText');
  if (dot) dot.className = 'status-dot ' + (S.online ? 'on' : 'off');
  if (txt) txt.textContent = S.online ? (S.fleet.minds + ' minds') : 'server down';
}

/* ============================================================ dashboard */

/** Everything happening for THIS user, in one place. Swarms and scheduled tasks
    each had their own tab, and a running turn was only visible if you happened
    to have that conversation open — so "is anything happening right now?" had no
    answer anywhere. This is that answer, assembled from endpoints that already
    exist rather than a new one. */
async function renderActivity() {
  const host = el('activityBody');
  if (!host) return;
  const [swarms, tasks, convs] = await Promise.all([
    api.swarms().then((j) => j.swarms || []).catch(() => []),
    api.sched().then((j) => j.tasks || []).catch(() => []),   // 403s for non-admins; empty is the honest answer
    api.convs().then((j) => j.convs || []).catch(() => []),
  ]);
  if (S.tab !== 'dashboard') return;

  const live = swarms.filter((s) => swarmState(s) === 'live');
  const due = tasks.filter((t) => t.enabled).sort((a, b) => (a.next_due || 0) - (b.next_due || 0));
  const recent = convs.slice().sort((a, b) => (b.updated || 0) - (a.updated || 0)).slice(0, 5);

  const rows = [];
  for (const s of live) {
    rows.push({ when: 0, cls: 'live', what: 'swarm', who: s.name || s.id,
      detail: (s.minds || 0) + ' minds working', go: () => setTab('swarms') });
  }
  for (const t of due.slice(0, 3)) {
    rows.push({ when: t.next_due || 0, cls: '', what: 'task', who: t.name || t.id,
      detail: t.next_due ? 'next ' + fmtWhen(t.next_due) : taskSchedule(t), go: () => setTab('tasks') });
  }
  for (const c of recent) {
    rows.push({ when: c.updated || 0, cls: '', what: 'chat', who: c.title || c.id,
      detail: (c.msgs || 0) + ' messages · ' + fmtWhen(c.updated), go: () => { S.conv = c.id; setTab('chat'); } });
  }

  host.innerHTML = rows.length ? rows.map((r, i) => `
    <button class="act-row ${r.cls}" data-act-i="${i}">
      <span class="act-kind">${esc(r.what)}</span>
      <span class="act-who grow ellip">${esc(r.who)}</span>
      <span class="act-detail muted ellip">${esc(r.detail)}</span>
    </button>`).join('')
    : '<div class="empty">nothing running — start a chat, or deploy a swarm</div>';
  $$('[data-act-i]', host).forEach((b) => b.addEventListener('click', () => rows[+b.dataset.actI].go()));
}

async function renderDashboard(host) {
  host.innerHTML = '<div class="scroller"><div class="pad" id="dashBody"><div class="empty">reading the ledger…</div></div></div>';
  let m = null;
  try { m = await api.metrics(); } catch (e) { m = null; }
  S.metrics = m;
  if (S.tab !== 'dashboard') return;   // the user moved on while we waited

  const t = (m && m.totals) || { calls: 0, in: 0, out: 0, secs: 0 };
  const speed = t.secs > 0 ? Math.round(t.out / t.secs) : 0;

  const cards = [
    { v: S.online ? 'online' : 'offline', l: 'server', cls: S.online ? 'good' : 'bad' },
    { v: fmtCount(S.fleet.live),  l: 'live swarms' },
    { v: fmtCount(S.fleet.minds), l: 'live minds' },
    { v: fmtCount(t.calls),       l: 'turns' },
    { v: fmtCount(t.in),          l: 'tokens in' },
    { v: fmtCount(t.out),         l: 'tokens out' },
    { v: speed + '/s',            l: 'avg speed' },
  ];

  const models = (m && m.models) || [];
  const days = (m && m.days) || [];
  const peak = days.reduce((a, d) => Math.max(a, (d.in || 0) + (d.out || 0)), 0) || 1;

  el('dashBody').innerHTML = `
    <div class="stat-grid">
      ${cards.map((c) => `<div class="stat ${c.cls || ''}"><b>${esc(c.v)}</b><span>${esc(c.l)}</span></div>`).join('')}
    </div>

    <div class="section-head"><h2>Happening now</h2>
      <button class="btn btn-sm btn-ghost" id="actRefresh">Refresh</button></div>
    <div class="panel" id="activityBody"><div class="empty">looking…</div></div>

    <div class="section-head"><h2>LLM breakdown</h2></div>
    ${models.length ? `<div class="table-wrap"><table class="data">
      <thead><tr><th>model</th><th class="num">calls</th><th class="num">in</th><th class="num">out</th><th class="num">tok/s</th></tr></thead>
      <tbody>${models.map((r) => {
        const tps = r.secs > 0 ? Math.round(r.out / r.secs) : 0;
        return `<tr>
          <td><div>${esc(r.model)}</div><div class="muted" style="font-size:.85em">${esc(r.base || 'local')}</div></td>
          <td class="num">${fmtCount(r.calls)}</td>
          <td class="num" style="color:var(--cyan)">${fmtCount(r.in)}</td>
          <td class="num" style="color:var(--magenta)">${fmtCount(r.out)}</td>
          <td class="num" style="color:var(--green)">${tps}</td>
        </tr>`;
      }).join('')}</tbody></table></div>`
      : '<div class="empty">no LLM usage yet — run a chat or a task</div>'}

    <div class="section-head"><h2>14-day activity</h2></div>
    <div class="panel" style="padding:14px">
      <div class="bars">
        ${days.map((d, i) => {
          const v = (d.in || 0) + (d.out || 0);
          const h = Math.max(2, Math.round((v / peak) * 100));
          return `<i class="${i === days.length - 1 ? 'today' : ''}" style="height:${h}%" title="${fmtCount(v)} tokens"></i>`;
        }).join('')}
      </div>
      <div class="bars-axis"><span>14 days ago</span><span>today</span></div>
    </div>`;

  el('actRefresh').addEventListener('click', renderActivity);
  renderActivity();   // fired after the shell exists, so it can paint into it
}

/* ============================================================ chat */

/** Conversation ids must satisfy safeSeg: 1-64 bytes of [A-Za-z0-9_-]
    (service.zig:47-55). There is no create route — the directory springs into
    existence on the first postMessage — so the client mints the id. */
function newConvId() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return 'web-' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate())
       + '-' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds())
       + '-' + Math.random().toString(36).slice(2, 6);
}

function renderChat(host) {
  host.innerHTML = `
    <div class="chat" id="chatRoot">
      <aside class="chat-list">
        <div class="chat-list-head">
          <button class="btn btn-solid btn-sm grow" id="newConv">+ New chat</button>
          <button class="icon-btn rail-toggle" id="railToggle" title="Collapse the list" aria-label="Collapse the conversation list">
            <svg viewBox="0 0 24 24"><path d="M15 18l-6-6 6-6"/></svg>
          </button>
        </div>
        <div class="scroller" id="convScroll"><div class="empty">loading…</div></div>
      </aside>

      <div class="rail-grip" id="railGrip" role="separator" aria-orientation="vertical"
           aria-label="Resize the conversation list" tabindex="0"></div>

      <section class="chat-main">
        <div class="chat-topline">
          <button class="icon-btn rail-restore hide" id="railRestore" title="Show the conversation list" aria-label="Show the conversation list">
            <svg viewBox="0 0 24 24"><path d="M9 18l6-6-6-6"/></svg>
          </button>
          <button class="icon-btn chat-back" id="backBtn" aria-label="Back to conversations">
            <svg viewBox="0 0 24 24"><path d="M15 18l-6-6 6-6"/></svg>
          </button>
          <div class="grow mono ellip" id="convTitle">—</div>
          <button class="icon-btn" id="filesBtn" title="Files this conversation built" aria-label="Files">
            <svg viewBox="0 0 24 24"><path d="M4 6a2 2 0 0 1 2-2h4l2 2h6a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2z"/></svg>
          </button>
          <button class="icon-btn" id="delConv" title="Delete conversation" aria-label="Delete conversation">
            <svg viewBox="0 0 24 24"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v6M14 11v6"/></svg>
          </button>
        </div>

        <div class="scroller transcript" id="transcript"><div class="empty">pick a conversation, or start a new one</div></div>
        <div class="files-pane hide" id="filesPane"></div>

        <div class="composer" id="composer">
          <div class="composer-chips hide" id="chips"></div>
          <div class="composer-row">
            <textarea id="input" rows="1" placeholder="Ask the veil…" enterkeyhint="send"></textarea>
            <button class="icon-btn" id="attachBtn" title="Attach an image" aria-label="Attach an image">
              <svg viewBox="0 0 24 24"><path d="M21.4 11.05l-9.2 9.2a6 6 0 0 1-8.5-8.5l9.2-9.2a4 4 0 0 1 5.7 5.7l-9.2 9.2a2 2 0 0 1-2.9-2.9l8.5-8.5"/></svg>
            </button>
            <input type="file" id="fileInput" accept="image/*" class="hide">
            <button class="btn btn-solid" id="sendBtn">Send</button>
            <button class="btn btn-danger hide" id="stopBtn">Stop</button>
          </div>
          <div class="composer-foot">
            <span class="muted" id="charCount"></span>
            <span class="grow"></span>
            <span class="muted" id="turnStatus"></span>
          </div>
        </div>
      </section>
    </div>`;

  el('newConv').addEventListener('click', () => openConv(newConvId(), true));
  el('backBtn').addEventListener('click', () => el('chatRoot').classList.remove('on-thread'));
  el('delConv').addEventListener('click', deleteActiveConv);
  el('filesBtn').addEventListener('click', toggleFiles);
  el('railToggle').addEventListener('click', toggleRail);
  el('railRestore').addEventListener('click', toggleRail);
  wireRailGrip();
  setRailCollapsed(LS.get('veil.railCollapsed', '0') === '1');
  el('sendBtn').addEventListener('click', sendTurn);
  el('stopBtn').addEventListener('click', () => sendControl('stop'));
  el('attachBtn').addEventListener('click', () => el('fileInput').click());
  el('fileInput').addEventListener('change', (e) => { if (e.target.files[0]) attachImage(e.target.files[0]); });

  const input = el('input');
  input.addEventListener('input', () => { autoGrow(input); updateCharCount(); });
  input.addEventListener('keydown', (e) => {
    // Enter sends on a real keyboard. On touch it must insert a newline, or the
    // on-screen return key becomes send-and-lose-your-draft.
    if (e.key === 'Enter' && !e.shiftKey && matchMedia('(pointer: fine)').matches) {
      e.preventDefault();
      sendTurn();
    }
  });
  input.addEventListener('paste', (e) => {
    const items = (e.clipboardData && e.clipboardData.items) || [];
    for (const it of items) {
      if (it.type && it.type.indexOf('image/') === 0) {
        const f = it.getAsFile();
        if (f) { e.preventDefault(); attachImage(f); return; }
      }
    }
  });

  const drop = el('composer');
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('drag'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('drag'));
  drop.addEventListener('drop', (e) => {
    e.preventDefault();
    drop.classList.remove('drag');
    const f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
    if (f && f.type.indexOf('image/') === 0) attachImage(f);
  });

  refreshConvs();
  if (S.conv) openConv(S.conv, false);
}

function autoGrow(ta) {
  ta.style.height = 'auto';
  ta.style.height = Math.min(ta.scrollHeight, 180) + 'px';
}

/** The desk scales the input cap to the model's size (inputCharLimit): a small
    local 8B gets 500 characters, a mid model 2000, a frontier model 4000. */
function inputCharLimit() {
  const m = (S.settings.model || '').toLowerCase();
  if (!m) return 4000;
  if (/(^|[^0-9])([1-9]|1[0-3])b\b/.test(m)) return 500;
  if (/(1[4-9]|[2-3][0-9])b\b/.test(m)) return 2000;
  return 4000;
}

/** Callable from any tab: Settings calls this after a model change (the cap
    follows the model's size), and the composer only exists on the Chat tab.
    Without the null guard this throws mid-handler and silently kills whatever
    the caller meant to do next. */
function updateCharCount() {
  const input = el('input');
  const c = el('charCount');
  if (!input || !c) return;
  const n = input.value.length;
  const cap = inputCharLimit();
  c.textContent = n ? (n + ' / ' + cap) : '';
  c.style.color = n > cap ? 'var(--danger)' : '';
}

let _attach = null;   // {b64, name, url}

function attachImage(file) {
  const rd = new FileReader();
  rd.onload = () => {
    const url = String(rd.result);
    _attach = { b64: url.slice(url.indexOf(',') + 1), name: file.name || 'image', url: url };
    const chips = el('chips');
    chips.classList.remove('hide');
    chips.innerHTML = `<div class="chip">
        <img src="${esc(url)}" alt="">
        <span class="ellip">${esc(_attach.name)}</span>
        <button class="chip-x" id="chipX" aria-label="Remove attachment">&times;</button>
      </div>`;
    el('chipX').addEventListener('click', clearAttach);
  };
  rd.readAsDataURL(file);
}

function clearAttach() {
  _attach = null;
  const chips = el('chips');
  if (!chips) return;
  chips.classList.add('hide');
  chips.innerHTML = '';
  el('fileInput').value = '';
}

async function refreshConvs() {
  try {
    const j = await api.convs();
    S.convs = j.convs || [];
  } catch (e) {
    S.convs = [];
  }
  const host = el('convScroll');
  if (!host) return;
  if (!S.convs.length) {
    host.innerHTML = '<div class="empty">no conversations yet</div>';
    return;
  }
  host.innerHTML = S.convs.map((c) => `
    <button class="conv-row ${c.id === S.conv ? 'active' : ''}" data-conv="${esc(c.id)}">
      <div class="conv-title ellip">${esc(c.title || c.id)}</div>
      <div class="conv-meta"><span>${esc(fmtWhen(c.updated))}</span><span>${c.msgs || 0} msgs</span></div>
    </button>`).join('');
  $$('[data-conv]', host).forEach((b) => b.addEventListener('click', () => openConv(b.dataset.conv, true)));
}

async function openConv(id, focus) {
  stopPoll();
  S.conv = id;
  S.msgs = [];
  S.live = false;
  resetStream();
  el('convTitle').textContent = id;
  $$('[data-conv]').forEach((b) => b.classList.toggle('active', b.dataset.conv === id));
  // On a phone the list and the thread are one column each; opening slides to
  // the thread and Back slides home.
  if (focus) el('chatRoot').classList.add('on-thread');

  try {
    const j = await api.conv(id);
    S.msgs = j.messages || [];
    S.live = !!j.live;
  } catch (e) {
    S.msgs = [];   // a freshly minted id 404s until the first message lands
  }
  drawTranscript();
  await baselineCursor();
  setTurnUi(S.live);
  if (S.live) startPoll();
}

async function deleteActiveConv() {
  if (!S.conv) return;
  if (!confirm('Delete this conversation? This cannot be undone.')) return;
  try {
    await api.convDel(S.conv);
    toast('Deleted', S.conv, 'ok');
  } catch (e) {
    toast('Could not delete', e.message, 'err');
  }
  stopPoll();
  S.conv = null;
  S.msgs = [];
  drawTranscript();
  el('chatRoot').classList.remove('on-thread');
  refreshConvs();
}

function resetStream() {
  S.stream = { text: '', shown: 0, reasoning: '', tools: [], status: '', started: 0 };
}

/* ---------------- what the turn built ----------------
   The desk browses the build tree straight off disk. A browser cannot, so
   without these routes a web user had nowhere to look: the AI would report
   having built something and there was no way to see it. */

/* DRAG-RESIZE the conversation rail, the way the desk does it. Two things the
   desk learned the hard way, copied here:
     - commit the width DURING the drag, not on release, or a repaint mid-drag
       snaps the pane back to where it started;
     - use pointer capture, so a fast drag that outruns the cursor keeps
       delivering events to the grip instead of dropping them on whatever it
       flew over. */
/* The floor that actually bit was never this constant — it was flexbox's
   min-width:auto refusing to draw the pane narrower than its content (see
   .chat-list in styles.css). With that fixed, 110px is a real floor: narrow
   enough to be a strip of titles, wide enough to still be a list. Dragging
   past it collapses rather than refusing, because pulling a divider to the edge
   means "get this out of my way". */
const RAIL_MIN = 110, RAIL_MAX = 560;
const RAIL_COLLAPSE_AT = 76;   // drag narrower than this and it snaps shut

function applyRailWidth(px) {
  const w = Math.max(RAIL_MIN, Math.min(RAIL_MAX, Math.round(px)));
  // Set the basis ON THE ELEMENT rather than driving a custom property from the
  // root. Going through a var meant the width depended on the cascade resolving
  // it, and it did not — the variable read back correctly while the computed
  // flex-basis stayed at the fallback, so the pane never moved. An inline
  // longhand has no such ambiguity.
  const list = document.querySelector('.chat-list');
  if (list) list.style.flexBasis = w + 'px';
  return w;
}

function wireRailGrip() {
  const grip = el('railGrip');
  const list = document.querySelector('.chat-list');
  if (!grip || !list) return;

  applyRailWidth(parseInt(LS.get('veil.railW', '260'), 10) || 260);

  grip.addEventListener('pointerdown', (e) => {
    // Collapsed is its own state; dragging out from zero width would surprise.
    if (el('chatRoot').classList.contains('rail-collapsed')) return;
    e.preventDefault();
    // Capture is an OPTIMISATION, not the mechanism, and it must not be able to
    // abort the drag: setPointerCapture throws for a pointer id the browser does
    // not consider active, and an uncaught throw here skipped the listener
    // registration below — leaving a grip that highlighted on hover and then did
    // nothing at all.
    try { grip.setPointerCapture(e.pointerId); } catch (err) {}
    grip.classList.add('dragging');
    const startX = e.clientX;
    const startW = list.getBoundingClientRect().width;

    // Listen on the WINDOW, not the grip: a drag that outruns the pointer leaves
    // the 6px element, and without capture those moves would land elsewhere.
    const root = el('chatRoot');
    const move = (ev) => {
      const want = startW + (ev.clientX - startX);
      // Past the floor, preview the collapse rather than sticking at the minimum —
      // the rail should follow the pointer all the way to the edge.
      const shut = want < RAIL_COLLAPSE_AT;
      if (shut) {
        // Same reason as setRailCollapsed: the inline basis has to go to zero,
        // because a stylesheet rule cannot override it.
        root.classList.add('rail-collapsed');
        list.style.flexBasis = '0px';
      } else {
        root.classList.remove('rail-collapsed');
        LS.set('veil.railW', String(applyRailWidth(want)));
      }
    };
    const up = (ev) => {
      try { grip.releasePointerCapture(ev.pointerId); } catch (err) {}
      grip.classList.remove('dragging');
      // Persist whichever state the drag ended in, so it survives a reload.
      setRailCollapsed(root.classList.contains('rail-collapsed'));
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', up);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
    window.addEventListener('pointercancel', up);
  });

  // A separator that can only be dragged is unusable without a pointer.
  grip.addEventListener('keydown', (e) => {
    const cur = list.getBoundingClientRect().width;
    if (e.key === 'ArrowLeft') { LS.set('veil.railW', String(applyRailWidth(cur - 24))); e.preventDefault(); }
    if (e.key === 'ArrowRight') { LS.set('veil.railW', String(applyRailWidth(cur + 24))); e.preventDefault(); }
  });

  grip.addEventListener('dblclick', toggleRail);
}

/** Collapse and restore the rail.
 *
 *  The width MUST be driven from here, not from a stylesheet rule. applyRailWidth
 *  writes an INLINE flex-basis, and inline always beats a stylesheet declaration —
 *  so `.rail-collapsed .chat-list { flex-basis: 0 }` never applied. The rail hid
 *  its contents and kept its width, leaving a blank column and no way back. */
function setRailCollapsed(collapsed) {
  const root = el('chatRoot');
  const list = document.querySelector('.chat-list');
  if (!root || !list) return;
  root.classList.toggle('rail-collapsed', collapsed);
  if (collapsed) {
    list.style.flexBasis = '0px';
  } else {
    applyRailWidth(parseInt(LS.get('veil.railW', '260'), 10) || 260);
  }
  LS.set('veil.railCollapsed', collapsed ? '1' : '0');
  const b = el('railToggle');
  if (b) b.title = collapsed ? 'Show the list' : 'Collapse the list';
  const r = el('railRestore');
  if (r) r.classList.toggle('hide', !collapsed);
}

function toggleRail() {
  setRailCollapsed(!el('chatRoot').classList.contains('rail-collapsed'));
}

async function toggleFiles() {
  const pane = el('filesPane');
  if (!pane) return;
  if (!pane.classList.contains('hide')) { pane.classList.add('hide'); return; }
  if (!S.conv) return toast('No conversation', 'Open one first.', 'err');
  pane.classList.remove('hide');
  pane.innerHTML = '<div class="files-head"><b>Files</b><span class="muted">reading…</span></div>';
  try {
    const j = await api.convFiles(S.conv);
    const files = j.files || [];
    pane.innerHTML = '<div class="files-head"><b>Files</b>'
      + '<span class="muted">'
      + (files.length ? files.length + ' file' + (files.length === 1 ? '' : 's') + ' · ' + fmtBytes(j.bytes || 0) : 'nothing built yet')
      + (j.truncated ? ' · first ' + files.length + ' shown' : '')
      + '</span></div>'
      + (files.length ? '<div class="files-list">' + files.map((f) =>
          '<button class="file-row" data-file="' + esc(f.path) + '">'
          + '<span class="ellip mono">' + esc(f.path) + '</span>'
          + '<span class="muted">' + fmtBytes(f.size || 0) + '</span></button>').join('') + '</div>'
        : '');
    $$('[data-file]', pane).forEach((b) => b.addEventListener('click', () => openConvFile(b.dataset.file)));
  } catch (e) {
    pane.innerHTML = '<div class="files-head"><b>Files</b><span class="muted">' + esc(e.message) + '</span></div>';
  }
}

async function openConvFile(path) {
  try {
    const r = await req('/api/v1/chat/convs/' + encodeURIComponent(S.conv) + '/file?path=' + encodeURIComponent(path));
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const text = await r.text();
    const pane = el('filesPane');
    // Rendered through the SAME markdown/highlight path the transcript uses, as
    // a fenced block named by the file's extension — one renderer, one look, and
    // the escaping is already proven there.
    const ext = (path.split('.').pop() || '').toLowerCase();
    pane.innerHTML = '<div class="files-head"><b class="ellip mono">' + esc(path) + '</b>'
      + '<button class="linkbtn" id="filesBack">back</button></div>'
      + '<div class="files-view msg-body">' + mdRender('```' + ext + '\n' + text + '\n```') + '</div>';
    wireCodeCopy(pane);
    el('filesBack').addEventListener('click', () => { pane.classList.add('hide'); toggleFiles(); });
  } catch (e) {
    toast('Could not open the file', e.message, 'err');
  }
}

/* ---------------- transcript ----------------
   Rendering is INCREMENTAL. The old version rebuilt every message's markdown on
   each poll tick, which threw away the reader's text selection, re-ran the
   highlighter over the whole history, and made a long conversation heavier with
   every turn. Committed messages are now rendered once and appended; only the
   live block is touched while a turn runs. */

function drawTranscript() {
  const host = el('transcript');
  if (!host) return;
  if (!S.conv) {
    host.innerHTML = '<div class="empty">pick a conversation, or start a new one</div>';
    host._rendered = 0;
    return;
  }
  const stick = isPinnedToBottom(host);

  // A shorter list than we have drawn means a different conversation (or a
  // delete) — start over. Otherwise append only what is new.
  if (typeof host._rendered !== 'number' || S.msgs.length < host._rendered) {
    host.innerHTML = '';
    host._rendered = 0;
  }
  if (host._rendered === 0 && !S.msgs.length && !S.live) {
    host.innerHTML = '<div class="empty">say something to begin</div>';
    return;
  }
  if (host._rendered === 0) host.innerHTML = '';

  for (let i = host._rendered; i < S.msgs.length; i++) {
    const node = document.createElement('div');
    node.innerHTML = renderMsg(S.msgs[i]);
    const msg = node.firstElementChild;
    if (msg) { host.insertBefore(msg, liveNode(host)); wireCodeCopy(msg); }
  }
  host._rendered = S.msgs.length;

  renderLive(host);
  if (stick) host.scrollTop = host.scrollHeight;
}

/** The live block always sits last; committed messages insert before it. */
function liveNode(host) {
  return host.querySelector('.msg.live');
}

function renderLive(host) {
  const want = S.live || S.stream.text || S.stream.tools.length || S.stream.status;
  let live = liveNode(host);
  if (!want) {
    if (live) live.remove();
    return;
  }
  if (!live) {
    live = document.createElement('div');
    live.className = 'msg assistant live';
    live.innerHTML = '<div class="msg-role">veil <span class="live-dot"></span></div>'
      + '<div class="host-activity"></div>'
      + '<div class="tools"></div>'
      + '<div class="msg-body"></div>';
    host.appendChild(live);
  }

  const act = live.querySelector('.host-activity');
  const html = hostActivityHtml();
  if (act.innerHTML !== html) act.innerHTML = html;

  const tools = live.querySelector('.tools');
  const th = S.stream.tools.map(toolChip).join('');
  if (tools.innerHTML !== th) tools.innerHTML = th;
  tools.classList.toggle('hide', !S.stream.tools.length);

  paintTyped(live.querySelector('.msg-body'));
}

/** What the host machine is doing right now, in the engine's own words: the
    latest status frame, plus the tool currently executing and how long it has
    been going. The desk shows this constantly; a web user staring at silence
    has no idea whether the machine is working or wedged. */
function hostActivityHtml() {
  const running = S.stream.tools.filter((t) => t.state !== 'done' && t.state !== 'error');
  const bits = [];
  if (running.length) {
    const t = running[running.length - 1];
    const secs = t.started ? Math.round((Date.now() - t.started) / 1000) : 0;
    bits.push('<span class="spin"></span><b>' + esc(t.tool) + '</b>'
      + (cleanPreview(t.preview) ? ' <span class="muted ellip">' + esc(cleanPreview(t.preview)) + '</span>' : '')
      + (secs > 1 ? ' <span class="muted">' + secs + 's</span>' : ''));
  } else if (S.stream.status) {
    bits.push('<span class="spin"></span>' + esc(S.stream.status));
  } else if (S.live && !S.stream.text) {
    bits.push('<span class="spin"></span>thinking');
  }
  return bits.join('');
}

/* ---------------- the typewriter ----------------
   Frames arrive in ~900ms polls, so painting them as they land makes the reply
   jump in blocks. We keep the received text and reveal it on a rAF loop, which
   turns bursty transport into steady output. The rate is proportional to the
   backlog, so it always catches up rather than falling behind a fast model —
   what it smooths is the arrival pattern, not the model's actual speed. */

let _typeRaf = 0;
let _typeLastPaint = 0;

function scheduleType() {
  if (_typeRaf) return;
  _typeRaf = requestAnimationFrame(typeTick);
}

function typeTick() {
  _typeRaf = 0;
  const host = el('transcript');
  const live = host && liveNode(host);
  if (!live) return;

  const total = S.stream.text.length;
  if (S.stream.shown < total) {
    // Drain the backlog over roughly a dozen frames (~200ms): fast enough that a
    // long paste does not crawl, slow enough that a short sentence still types.
    const backlog = total - S.stream.shown;
    S.stream.shown = Math.min(total, S.stream.shown + Math.max(2, Math.ceil(backlog / 12)));
  }

  const now = performance.now();
  // Markdown + highlighting on every frame is wasted work; the eye cannot tell
  // 60fps from ~25fps here, and this keeps a long code block from stuttering.
  if (now - _typeLastPaint > 40 || S.stream.shown >= total) {
    _typeLastPaint = now;
    const stick = isPinnedToBottom(host);
    paintTyped(live.querySelector('.msg-body'));
    const act = live.querySelector('.host-activity');
    const html = hostActivityHtml();
    if (act && act.innerHTML !== html) act.innerHTML = html;
    if (stick) host.scrollTop = host.scrollHeight;
  }

  // Keep ticking while there is text to reveal, or while a tool is running (the
  // elapsed counter and spinner need frames of their own).
  if (S.stream.shown < total || S.live) scheduleType();
}

function paintTyped(body) {
  if (!body) return;
  if (!S.stream.text) {
    if (!body.querySelector('.shimmer-line')) body.innerHTML = '<span class="shimmer-line"></span>';
    return;
  }
  const revealed = S.stream.text.slice(0, S.stream.shown);
  // Render the revealed prefix as markdown so fences, lists and tables form as
  // they arrive — mdRender tolerates a half-finished fence by design, which is
  // exactly the streaming case.
  const html = mdRender(revealed) + (S.stream.shown < S.stream.text.length ? '<span class="caret"></span>' : '');
  if (body._html !== html) {
    body._html = html;
    body.innerHTML = html;
    wireCodeCopy(body);
  }
}

function isPinnedToBottom(host) {
  // Only auto-scroll when the reader is already at the bottom. Yanking the view
  // while they read history is the worst thing a chat UI can do.
  return host.scrollHeight - host.scrollTop - host.clientHeight < 80;
}

function renderMsg(m) {
  const role = m.role === 'user' ? 'user' : 'assistant';
  return `<div class="msg ${role}">
    <div class="msg-role">${role === 'user' ? 'you' : 'veil'}${m.ts ? ' <span class="muted">· ' + esc(fmtWhen(m.ts)) + '</span>' : ''}</div>
    <div class="msg-body">${mdRender(m.content || '')}</div>
  </div>`;
}

/** Tool previews arrive as a raw slice of the result, so a web_fetch that landed
    on an unrendered page shows "<!DOCTYPE html><html lang=..." — technically the
    truth and useless to read. Strip markup, unescape the handful of entities
    that survive, collapse whitespace, and fall back to naming the shape when
    there is no prose left. The full result is still in the transcript; this is
    a glance, and a glance should be legible. */
function cleanPreview(s) {
    let t = String(s || '');
    if (/^\s*<(!doctype|html|\?xml)/i.test(t)) {
      // Drop the parts that never contain readable page text before anything else.
      t = t.replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, ' ');
    }
    t = t.replace(/<[^>]*>/g, ' ')
         .replace(/&(nbsp|amp|lt|gt|quot|#39);/g, (m) => (
           { '&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" }[m] || ' '
         ))
         .replace(/\s+/g, ' ')
         .trim();
    if (!t) return '';
    // A JSON body reduces to nothing readable; say what it is rather than showing braces.
    if (/^[[{]/.test(String(s).trim()) && t.length > 60) return 'JSON · ' + t.slice(0, 40) + '…';
    return t;
}

/** A tool chip carries its own state and elapsed time — the point is that the
    user can see the host working, not just that something is happening. */
function toolChip(t) {
  const cls = t.state === 'done' ? 'done' : (t.state === 'error' ? 'err' : 'run');
  const mark = t.state === 'done' ? '✓' : (t.state === 'error' ? '✗' : '');
  const secs = t.started && t.ended ? Math.round((t.ended - t.started) / 1000) : 0;
  return '<div class="tool-chip ' + cls + '">'
    + (mark ? '<i class="tool-mark">' + mark + '</i>' : '<i class="tool-mark spin"></i>')
    + '<b>' + esc(t.tool) + '</b>'
    + (cleanPreview(t.preview) ? '<span class="ellip">' + esc(cleanPreview(t.preview)) + '</span>' : '')
    + (secs > 1 ? '<span class="muted">' + secs + 's</span>' : '')
    + '</div>';
}

function wireCodeCopy(host) {
  $$('.code-copy', host).forEach((b) => {
    b.addEventListener('click', () => {
      const code = b.closest('.code-block').querySelector('code');
      let raw = code.textContent;
      if (b.dataset.raw) {
        try { raw = decodeURIComponent(escape(atob(b.dataset.raw))); } catch (e) { /* fall back to textContent */ }
      }
      navigator.clipboard.writeText(raw).then(
        () => { b.textContent = 'copied'; setTimeout(() => { b.textContent = 'copy'; }, 1200); },
        () => toast('Clipboard blocked', 'Select and copy by hand.', 'err')
      );
    });
  });
}

/* ---------------- sending a turn ---------------- */

function setTurnUi(live) {
  S.live = live;
  const send = el('sendBtn'), stop = el('stopBtn'), st = el('turnStatus');
  if (!send) return;
  send.classList.toggle('hide', live);
  stop.classList.toggle('hide', !live);
  if (st && !live) st.textContent = '';
}

async function sendTurn() {
  const input = el('input');
  const text = input.value.trim();
  if (!text) return;
  if (!S.conv) { S.conv = newConvId(); el('convTitle').textContent = S.conv; }

  const body = {
    text: text,
    base_url: S.settings.base_url,
    model: S.settings.model,
    api_key: S.settings.api_key,
    loop: S.settings.loop | 0,
    // tool_client is DELIBERATELY ABSENT. Sending it true makes the server
    // delegate every tool call to a client harness this browser does not have,
    // and each call would burn its 20s ack timeout and come back to the model
    // as a failure (engine.zig:3048). Omitted = the server executes tools.
  };
  if (!S.settings.oneModel) {
    body.think_base_url = S.settings.think_base_url;
    body.think_model = S.settings.think_model;
    body.think_api_key = S.settings.think_api_key;
    body.prompt_base_url = S.settings.prompt_base_url;
    body.prompt_model = S.settings.prompt_model;
    body.prompt_api_key = S.settings.prompt_api_key;
  }
  if (_attach) body.image_b64 = _attach.b64;

  // Optimistic echo: show the line immediately, then let the stream's own
  // `message` frame become the source of truth.
  S.msgs.push({ role: 'user', content: text, ts: Math.floor(Date.now() / 1000) });
  input.value = '';
  autoGrow(input);
  updateCharCount();
  clearAttach();
  resetStream();
  setTurnUi(true);
  drawTranscript();

  await baselineCursor();

  try {
    await api.send(S.conv, body);
    startPoll();
    refreshConvs();
  } catch (e) {
    setTurnUi(false);
    if (e.status === 403) toast('Chat is admin-only', 'This account cannot run server chat yet.', 'err');
    else if (e.status === 409) toast('Busy', e.message, 'err');
    else toast('Could not send', e.message, 'err');
    S.stream.status = 'failed: ' + (e.message || 'unknown');
    drawTranscript();
  }
}

async function sendControl(op, text) {
  if (!S.conv) return;
  try {
    await api.control(S.conv, { op: op, text: text || '' });
    if (op === 'stop') toast('Stopping', 'Asked the turn to wind down.', 'ok');
  } catch (e) {
    toast('Control failed', e.message, 'err');
  }
}

/* ---------------- the event poll ----------------
   Chat has NO server-sent events: the transport is a byte-cursor poll over
   events.jsonl (service.zig:171-225). `from=2^64-1` is a size probe that
   answers {ok,len} without shipping the backlog — that is how a client starts
   at the tail instead of replaying an old conversation's whole history. */

const CURSOR_PROBE = '18446744073709551615';

async function baselineCursor() {
  S.cursor = 0;
  if (!S.conv) return;
  // A brand-new conversation has no directory on the server yet — the client mints
  // the id and the dir springs into existence on the first postMessage — so probing
  // it 404s. The 404 was already harmless (the cursor stays 0, which is correct for
  // an empty log), but it printed a red error in the console on every first message,
  // which reads like a fault. Nothing to baseline against, so do not ask.
  if (!S.msgs.length && !S.convs.some((c) => c.id === S.conv)) return;
  try {
    const r = await req('/api/v1/chat/convs/' + encodeURIComponent(S.conv) + '/events?from=' + CURSOR_PROBE, null, 8000);
    if (!r.ok) return;
    const txt = await r.text();
    if (!txt) return;               // older server: the sentinel reads as past-the-end
    const j = JSON.parse(txt);
    if (j && typeof j.len === 'number') S.cursor = j.len;
  } catch (e) { /* leave the cursor at 0 and replay — correctness over economy */ }
}

function startPoll() {
  stopPoll();
  S.poll = setInterval(pollEvents, 900);
  pollEvents();
}

function stopPoll() {
  if (S.poll) { clearInterval(S.poll); S.poll = null; }
}

let _polling = false;
async function pollEvents() {
  if (_polling || !S.conv) return;
  if (document.hidden) return;   // a backgrounded tab must not poll
  _polling = true;
  try {
    const r = await req('/api/v1/chat/convs/' + encodeURIComponent(S.conv) + '/events?from=' + S.cursor, null, 12000);
    if (!r.ok) return;
    const next = r.headers.get('X-Next-Offset');
    const body = await r.text();
    if (next) S.cursor = Number(next) || S.cursor;
    if (!body) return;
    let touched = false;
    for (const line of body.split('\n')) {
      const s = line.trim();
      if (!s) continue;
      let f;
      try { f = JSON.parse(s); } catch (e) { continue; }  // torn tail line; the next poll re-reads it
      if (applyFrame(f)) touched = true;
    }
    if (touched) drawTranscript();
  } catch (e) {
    /* A dropped poll is not an error: the cursor is durable, so the next tick
       resumes exactly where this one failed. */
  } finally {
    _polling = false;
  }
}

function applyFrame(f) {
  switch (f.kind) {
    case 'token':
      S.stream.text += f.delta || '';
      scheduleType();           // reveal it smoothly rather than in poll-sized blocks
      return false;             // the rAF loop paints; a full redraw here would fight it
    case 'reasoning':
      S.stream.reasoning += f.delta || '';
      return false;             // thinking stays out of the transcript
    case 'status':
      S.stream.status = f.text || '';
      return true;
    case 'tool': {
      const prev = S.stream.tools.find((t) => t.tool === f.tool && t.state !== 'done' && t.state !== 'error');
      if (prev) {
        prev.state = f.state;
        prev.preview = f.preview || prev.preview;
        if (f.state === 'done' || f.state === 'error') prev.ended = Date.now();
      } else {
        S.stream.tools.push({ tool: f.tool, state: f.state, preview: f.preview || '', started: Date.now(), ended: 0 });
      }
      scheduleType();           // keeps the elapsed counter and spinner ticking
      return true;
    }
    case 'message':
      // The committed message. Drop the optimistic echo of the same user text
      // so it does not appear twice.
      if (f.role === 'user') {
        const last = S.msgs[S.msgs.length - 1];
        if (last && last.role === 'user' && last.content === f.content) return false;
      }
      S.msgs.push({ role: f.role, content: f.content, ts: Math.floor(Date.now() / 1000) });
      if (f.role === 'assistant') resetStream();
      return true;
    case 'usage': {
      const st = el('turnStatus');
      if (st && f.text) st.textContent = f.text;
      return false;
    }
    case 'error':
      toast('Turn error', f.err || '', 'err');
      S.stream.status = f.err || 'error';
      return true;
    case 'done':
      setTurnUi(false);
      stopPoll();
      resetStream();
      refreshConvs();
      return true;
    default:
      return false;
  }
}

/* A phone locks its screen mid-turn constantly. The byte cursor makes recovery
   exact: on resume we poll from where we stopped, replaying nothing and losing
   nothing. */
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  if (S.tab === 'chat' && S.conv && S.live) startPoll();
});

/* ============================================================ tasks (scheduled)
   A port of the desk's Tasks tab. Every route here is admin-gated with a 403
   (sched.zig:898-906), so a non-admin gets an honest explanation instead of an
   empty list pretending nothing is scheduled. */

const TASK_KINDS = [
  { id: 'once',  label: 'Once' },
  { id: 'every', label: 'Every N minutes' },
  { id: 'daily', label: 'Daily at' },
];

async function renderTasks(host) {
  host.innerHTML = `
    <div class="scroller"><div class="pad">
      <div class="section-head">
        <h2>Scheduled tasks</h2>
        <button class="btn btn-solid btn-sm" id="newTask">+ New task</button>
      </div>
      <div id="taskForm" class="hide"></div>
      <div id="taskList"><div class="empty">loading…</div></div>
    </div></div>`;
  el('newTask').addEventListener('click', () => showTaskForm(null));
  await refreshTasks();
}

async function refreshTasks() {
  const host = el('taskList');
  if (!host) return;
  let tasks;
  try {
    const j = await api.sched();
    tasks = j.tasks || [];
  } catch (e) {
    host.innerHTML = e.status === 403
      ? '<div class="empty">Scheduled tasks are admin-only on this server.</div>'
      : `<div class="empty">could not load tasks — ${esc(e.message)}</div>`;
    return;
  }
  if (!tasks.length) {
    host.innerHTML = '<div class="empty">no scheduled tasks yet</div>';
    return;
  }
  host.innerHTML = tasks.map(taskCard).join('');
  $$('[data-task-run]', host).forEach((b) => b.addEventListener('click', () => runTask(b.dataset.taskRun)));
  $$('[data-task-del]', host).forEach((b) => b.addEventListener('click', () => delTask(b.dataset.taskDel)));
  $$('[data-task-edit]', host).forEach((b) => {
    b.addEventListener('click', () => showTaskForm(tasks.find((t) => t.id === b.dataset.taskEdit)));
  });
  $$('[data-task-toggle]', host).forEach((b) => {
    b.addEventListener('click', () => toggleTask(b.dataset.taskToggle, b.dataset.enabled !== 'true'));
  });
}

function taskSchedule(t) {
  if (t.kind === 'every') return 'every ' + t.every_min + ' min';
  if (t.kind === 'daily') return 'daily at ' + (t.hm || '—');
  return t.at ? 'once, ' + new Date(t.at * 1000).toLocaleString() : 'once';
}

function taskCard(t) {
  const bad = (t.fail_streak || 0) > 0;
  return `<div class="task-card panel">
    <div class="task-head">
      <div class="grow">
        <div class="task-name">${esc(t.name || t.id)}</div>
        <div class="task-sched muted">${esc(taskSchedule(t))}${t.next_due ? ' · next ' + esc(fmtWhen(t.next_due)) : ''}</div>
      </div>
      <span class="pill ${t.enabled ? 'on' : ''}">${t.enabled ? 'enabled' : 'paused'}</span>
    </div>
    <div class="task-prompt">${esc((t.prompt || '').slice(0, 220))}</div>
    <div class="task-stats muted">
      <span>${t.runs || 0} runs</span>
      ${t.last_run ? '<span>last ' + esc(fmtWhen(t.last_run)) + '</span>' : ''}
      ${t.last_status ? `<span class="${bad ? 'bad' : ''}">${esc(t.last_status)}</span>` : ''}
      ${bad ? '<span class="bad">' + t.fail_streak + ' failing</span>' : ''}
      ${t.model ? '<span class="mono">' + esc(t.model) + '</span>' : ''}
    </div>
    <div class="task-actions">
      <button class="btn btn-sm" data-task-run="${esc(t.id)}">Run now</button>
      <button class="btn btn-sm btn-ghost" data-task-edit="${esc(t.id)}">Edit</button>
      <button class="btn btn-sm btn-ghost" data-task-toggle="${esc(t.id)}" data-enabled="${t.enabled}">${t.enabled ? 'Pause' : 'Resume'}</button>
      <span class="grow"></span>
      <button class="btn btn-sm btn-danger" data-task-del="${esc(t.id)}">Delete</button>
    </div>
  </div>`;
}

function showTaskForm(task) {
  const f = el('taskForm');
  const t = task || { kind: 'daily', enabled: true, hm: '09:00', every_min: 60 };
  f.classList.remove('hide');
  f.innerHTML = `<div class="panel task-form">
    <div class="field"><label for="tfName">Name</label><input id="tfName" type="text" value="${esc(t.name || '')}"></div>
    <div class="field"><label for="tfPrompt">Prompt</label><textarea id="tfPrompt" rows="3">${esc(t.prompt || '')}</textarea></div>
    <div class="field"><label for="tfDetails">Details (optional)</label><textarea id="tfDetails" rows="2">${esc(t.details || '')}</textarea></div>
    <div class="field-row">
      <div class="field"><label for="tfKind">Schedule</label>
        <select id="tfKind">${TASK_KINDS.map((k) => `<option value="${k.id}"${k.id === t.kind ? ' selected' : ''}>${k.label}</option>`).join('')}</select>
      </div>
      <div class="field" id="tfEveryWrap"><label for="tfEvery">Minutes</label><input id="tfEvery" type="number" min="1" value="${t.every_min || 60}"></div>
      <div class="field" id="tfHmWrap"><label for="tfHm">Time</label><input id="tfHm" type="text" placeholder="09:00" value="${esc(t.hm || '')}"></div>
    </div>
    <div class="field"><label for="tfModel">Model (blank = server default)</label><input id="tfModel" type="text" value="${esc(t.model || '')}"></div>
    <div class="row">
      <button class="btn btn-solid" id="tfSave">${task ? 'Save' : 'Create'}</button>
      <button class="btn btn-ghost" id="tfCancel">Cancel</button>
    </div>
  </div>`;

  const sync = () => {
    const k = el('tfKind').value;
    el('tfEveryWrap').classList.toggle('hide', k !== 'every');
    el('tfHmWrap').classList.toggle('hide', k !== 'daily');
  };
  el('tfKind').addEventListener('change', sync);
  sync();
  el('tfCancel').addEventListener('click', () => { f.classList.add('hide'); f.innerHTML = ''; });
  el('tfSave').addEventListener('click', () => saveTask(task ? task.id : null));
}

async function saveTask(id) {
  const body = {
    name: el('tfName').value.trim(),
    prompt: el('tfPrompt').value.trim(),
    details: el('tfDetails').value.trim(),
    kind: el('tfKind').value,
    every_min: parseInt(el('tfEvery').value, 10) || 0,
    hm: el('tfHm').value.trim(),
    model: el('tfModel').value.trim(),
    enabled: true,
  };
  if (!body.name || !body.prompt) return toast('Missing fields', 'A task needs a name and a prompt.', 'err');
  try {
    await jpost(id ? '/api/v1/sched/' + encodeURIComponent(id) : '/api/v1/sched', body);
    toast(id ? 'Task saved' : 'Task created', body.name, 'ok');
    el('taskForm').classList.add('hide');
    el('taskForm').innerHTML = '';
    refreshTasks();
  } catch (e) {
    toast('Could not save', e.message, 'err');
  }
}

async function runTask(id) {
  try {
    const j = await jpost('/api/v1/sched/' + encodeURIComponent(id) + '/run', {});
    toast('Running', 'Opening its conversation.', 'ok');
    if (j.conv) { S.conv = j.conv; setTab('chat'); }
  } catch (e) {
    // A 409 carries the already-running conversation id, which is more useful
    // to the reader than the error text (sched.zig:1108-1112).
    if (e.status === 409 && e.body && e.body.conv) { S.conv = e.body.conv; setTab('chat'); return; }
    toast('Could not run', e.message, 'err');
  }
}

async function toggleTask(id, enabled) {
  try {
    await jpost('/api/v1/sched/' + encodeURIComponent(id), { enabled: enabled });
    refreshTasks();
  } catch (e) { toast('Could not update', e.message, 'err'); }
}

async function delTask(id) {
  if (!confirm('Delete this task?')) return;
  try {
    await jdel('/api/v1/sched/' + encodeURIComponent(id));
    refreshTasks();
  } catch (e) { toast('Could not delete', e.message, 'err'); }
}

/* ============================================================ swarms */

async function renderSwarms(host) {
  host.innerHTML = `
    <div class="scroller"><div class="pad">
      <div class="section-head"><h2>Swarms</h2><button class="btn btn-sm btn-ghost" id="swRefresh">Refresh</button></div>
      <div id="swarmList"><div class="empty">loading…</div></div>
    </div></div>`;
  el('swRefresh').addEventListener('click', refreshSwarms);
  await refreshSwarms();
}

async function refreshSwarms() {
  const host = el('swarmList');
  if (!host) return;
  let swarms;
  try {
    const j = await api.swarms();
    swarms = j.swarms || [];     // note: this route has no top-level `ok`
  } catch (e) {
    host.innerHTML = `<div class="empty">could not load swarms — ${esc(e.message)}</div>`;
    return;
  }
  if (!swarms.length) {
    host.innerHTML = '<div class="empty">no swarms yet — cast one from chat</div>';
    return;
  }
  host.innerHTML = swarms.map(swarmCard).join('');
  $$('[data-sw-stop]', host).forEach((b) => b.addEventListener('click', () => stopSwarm(b.dataset.swStop)));
  $$('[data-sw-del]', host).forEach((b) => b.addEventListener('click', () => delSwarm(b.dataset.swDel)));
  $$('[data-sw-open]', host).forEach((b) => b.addEventListener('click', () => openSwarm(b.dataset.swOpen)));
}

function swarmState(s) {
  const st = s.state || '';
  if (st === 'running' || st === 'starting') return 'live';
  return st || 'idle';
}

function swarmCard(s) {
  const st = swarmState(s);
  return `<div class="task-card panel">
    <div class="task-head">
      <div class="grow">
        <div class="task-name">${esc(s.name || s.id)}</div>
        <div class="task-sched muted mono ellip">${esc(s.id)}</div>
      </div>
      <span class="pill ${st === 'live' ? 'on' : ''}">${esc(st)}</span>
    </div>
    <div class="task-stats muted">
      <span>${s.minds || 0} minds</span>
      ${s.model ? '<span class="mono">' + esc(s.model) + '</span>' : ''}
      ${s.encrypted ? '<span>encrypted</span>' : ''}
    </div>
    <div class="task-actions">
      <button class="btn btn-sm" data-sw-open="${esc(s.id)}">Events</button>
      ${st === 'live' ? `<button class="btn btn-sm btn-ghost" data-sw-stop="${esc(s.id)}">Stop</button>` : ''}
      <span class="grow"></span>
      <button class="btn btn-sm btn-danger" data-sw-del="${esc(s.id)}">Delete</button>
    </div>
    <div class="sw-events hide" id="swev-${esc(s.id)}"></div>
  </div>`;
}

/** Swarms DO have real SSE (fanout.zig:42-152), unlike chat. The stream
    self-closes at a hard 10-minute cap WITHOUT a `gone` frame precisely so
    EventSource reconnects on its own — so no manual retry logic belongs here. */
let _swStream = null;
function openSwarm(id) {
  const box = el('swev-' + id);
  if (!box) return;
  if (!box.classList.contains('hide')) {   // toggle closed
    box.classList.add('hide');
    if (_swStream) { _swStream.close(); _swStream = null; }
    return;
  }
  $$('.sw-events').forEach((b) => b.classList.add('hide'));
  box.classList.remove('hide');
  box.innerHTML = '<div class="muted">connecting…</div>';
  if (_swStream) _swStream.close();
  const lines = [];
  _swStream = new EventSource('/api/v1/swarms/' + encodeURIComponent(id) + '/stream');
  _swStream.onmessage = (ev) => {
    let o;
    try { o = JSON.parse(ev.data); } catch (e) { return; }
    lines.push(o);
    if (lines.length > 200) lines.shift();   // the tail is what matters
    box.innerHTML = lines.map((l) =>
      `<div class="sw-line"><span class="muted mono">${esc(l.kind || l.type || '')}</span> ${esc(l.text || l.msg || JSON.stringify(l).slice(0, 200))}</div>`
    ).join('');
    box.scrollTop = box.scrollHeight;
  };
  _swStream.onerror = () => { box.insertAdjacentHTML('beforeend', '<div class="muted">stream closed</div>'); };
}

async function stopSwarm(id) {
  try {
    await jpost('/api/v1/swarms/' + encodeURIComponent(id) + '/control', { op: 'stop' });
    toast('Stopping', id, 'ok');
    setTimeout(refreshSwarms, 700);
  } catch (e) { toast('Could not stop', e.message, 'err'); }
}

async function delSwarm(id) {
  if (!confirm('Delete this swarm and its run directory?')) return;
  try {
    await jdel('/api/v1/swarms/' + encodeURIComponent(id));
    refreshSwarms();
  } catch (e) { toast('Could not delete', e.message, 'err'); }
}

/* ============================================================ admin console
   Every route behind this tab is admin-gated server-side; hiding the tab is
   presentation, not the security boundary.

   Deliberately METADATA ONLY. It reports what an account is DOING — swarms,
   conversation ids and sizes, state — and never what it SAID. A conversation's
   event stream carries shell output, fetched pages and file contents, so a
   transcript viewer here would be a keylogger over everything that user's AI
   touched. Moderation does not require reading someone's mail. */

async function renderAdmin(host) {
  host.innerHTML = `
    <div class="scroller"><div class="pad">
      <div class="section-head"><h2>Default model</h2></div>
      <div class="panel set-panel" id="cfgPanel"><div class="muted">loading…</div></div>

      <div class="section-head">
        <h2>Users</h2>
        <button class="btn btn-solid btn-sm" id="newUser">+ New user</button>
      </div>
      <div id="newUserForm" class="hide"></div>
      <div id="userList"><div class="empty">loading…</div></div>
      <div id="userDetail"></div>
    </div></div>`;
  el('newUser').addEventListener('click', showNewUserForm);
  renderServerConfig();
  await refreshUsers();
}

/** The setting that decides whether a brand-new account can do anything at all
    without configuring something first. A picker over the same catalog the
    Settings tab uses — an admin should not have to know that
    "@cf/meta/llama-3.3-70b-instruct-fp8-fast" is spelled exactly that way. */
async function renderServerConfig() {
  const host = el('cfgPanel');
  if (!host) return;
  let cur = {};
  let keys = [];
  try {
    cur = await jget('/api/v1/admin/config');
    keys = (await jget('/api/v1/admin/keys')).keys || [];
  } catch (e) {
    host.innerHTML = '<div class="muted">could not read the configuration — ' + esc(e.message) + '</div>';
    return;
  }
  if (!S.models) await loadModels();
  S.adminKeys = keys;
  const trio = !!(cur.think_model || cur.prompt_model);

  const rolePanel = (key, label, hint, model, base) => `
    <div class="role-panel" data-cfgrole="${key}">
      <div class="role-title">${label}<span class="muted"> — ${esc(hint)}</span></div>
      <div class="field">
        <label>Model</label>
        <select data-cfgpick="${key}">${catalogOptions(model || '')}</select>
      </div>
      <div class="field-row">
        <div class="field"><label>Model id</label>
          <input type="text" data-cfgid="${key}" value="${esc(model || '')}" placeholder="${key === '' ? 'none — users choose their own' : 'blank = use the coding model'}"></div>
        <div class="field"><label>Base URL</label>
          <input type="text" data-cfgbase="${key}" value="${esc(base || '')}" placeholder="https://…"></div>
      </div>
      <div class="role-key" data-cfgkey="${key}">${adminKeyState(model, base)}</div>
    </div>`;

  host.innerHTML = `
    <div class="muted" style="margin-bottom:10px">
      Everyone who has not chosen their own model uses this. It applies immediately — no restart.
    </div>
    <div class="set-row">
      <div><b>One model for everything</b>
        <div class="muted">Off = publish a coding / thinking / prompting split for every user, the same
          three roles they can set for themselves.</div></div>
      <input type="checkbox" id="cfgOne" class="w-auto" ${trio ? '' : 'checked'}>
    </div>
    <div id="cfgRoles">
      ${rolePanel('', 'Coding', 'the build stream — and the fallback for every unset role', cur.default_model, cur.default_base_url)}
      ${trio ? rolePanel('think_', 'Thinking', 'planning, reflection, summaries', cur.think_model, cur.think_base_url) : ''}
      ${trio ? rolePanel('prompt_', 'Prompting', 'drives the auto-loop', cur.prompt_model, cur.prompt_base_url) : ''}
    </div>
    <div class="row" style="margin-top:12px">
      <button class="btn btn-solid btn-sm" id="cfgSave">Save</button>
      <button class="btn btn-sm btn-ghost" id="cfgClear">Clear</button>
      <span class="muted" id="cfgState">${cur.default_model
        ? 'currently <b>' + esc(cur.default_model) + '</b>'
        : 'no default — every user must pick a model before they can chat'}</span>
    </div>`;

  el('cfgOne').addEventListener('change', () => {
    // Collapsing to one model clears the other two: a hidden thinking model that
    // still applied would be a setting nobody could see.
    const one = el('cfgOne').checked;
    saveServerConfig(readCfg(''), one ? null : readCfg('think_'), one ? null : readCfg('prompt_'));
  });
  $$('[data-cfgpick]').forEach((sel) => sel.addEventListener('change', () => {
    const role = sel.dataset.cfgpick;
    const m = modelById(sel.value);
    const idEl = host.querySelector('[data-cfgid="' + role + '"]');
    const baseEl = host.querySelector('[data-cfgbase="' + role + '"]');
    idEl.value = sel.value;
    if (m) baseEl.value = providerBase(m.provider);
    const line = host.querySelector('[data-cfgkey="' + role + '"]');
    if (line) { line.innerHTML = adminKeyState(idEl.value, baseEl.value); wireAdminKeys(); }
  }));
  el('cfgSave').addEventListener('click', () => {
    const one = el('cfgOne').checked;
    saveServerConfig(readCfg(''), one ? null : readCfg('think_'), one ? null : readCfg('prompt_'));
  });
  el('cfgClear').addEventListener('click', () => saveServerConfig({ model: '', base: '' }, null, null));
  wireAdminKeys();
}

function readCfg(role) {
  const idEl = document.querySelector('[data-cfgid="' + role + '"]');
  const baseEl = document.querySelector('[data-cfgbase="' + role + '"]');
  return { model: idEl ? idEl.value.trim() : '', base: baseEl ? baseEl.value.trim() : '' };
}

/** The SHARED key for whichever provider this role's endpoint belongs to.
    Without one, a default model is only half an answer — every user still has to
    bring their own key before they can send a message, which is exactly the
    setup step a default model exists to remove. */
function adminKeyState(model, base) {
  const prov = (base && providerForBaseJs(base)) || (modelById(model) || {}).provider;
  if (!prov) return '';
  const p = (S.models && S.models.providers || []).find((x) => x.key === prov);
  if (!p || !p.needs_key || p.base_url === 'local') {
    return '<span class="ok-dot"></span><span class="key-what">no key needed</span>';
  }
  const have = (S.adminKeys || []).find((k) => k.provider === prov);
  if (have) {
    return '<span class="ok-dot"></span><span class="key-what">shared ' + esc(prov) + ' key'
      + (have.last4 ? ' <span class="muted">••••' + esc(have.last4) + '</span>' : '') + '</span>'
      + '<button class="linkbtn" data-adminkeydel="' + esc(prov) + '">remove</button>';
  }
  return '<span class="bad-dot"></span><span class="key-what">' + esc(prov) + '</span>'
    + '<span class="inline-key">'
    + '<input type="password" placeholder="shared ' + esc(prov) + ' key — used by everyone" autocomplete="off"'
    + ' autocapitalize="none" spellcheck="false" data-adminkey="' + esc(prov) + '">'
    + '<button class="btn btn-sm btn-solid" data-adminkeysave="' + esc(prov) + '">Save</button>'
    + '</span>';
}

/** Catalog lookup by base URL. hostOf + the same host-match modelcfg does on the
    server, so the UI names the provider whose key the turn will actually resolve. */
function providerForBaseJs(base) {
  const host = hostOf(base);
  if (!host) return null;
  const p = (S.models && S.models.providers || []).find(
    (x) => x.base_url && x.base_url !== 'local' && x.base_url !== 'cloudflare' && hostOf(x.base_url) === host);
  return p ? p.key : null;
}

function wireAdminKeys() {
  $$('[data-adminkeysave]').forEach((b) => b.addEventListener('click', () => saveAdminKey(b.dataset.adminkeysave)));
  $$('[data-adminkey]').forEach((f) => f.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); saveAdminKey(f.dataset.adminkey); }
  }));
  $$('[data-adminkeydel]').forEach((b) => b.addEventListener('click', async () => {
    const prov = b.dataset.adminkeydel;
    if (!confirm('Remove the shared ' + prov + ' key?\nUsers without a key of their own will stop being able to chat.')) return;
    try { await jdel('/api/v1/admin/keys/' + encodeURIComponent(prov)); renderServerConfig(); }
    catch (e) { toast('Could not remove', e.message, 'err'); }
  }));
}

async function saveAdminKey(provider) {
  const f = document.querySelector('[data-adminkey="' + provider + '"]');
  if (!f) return;
  const key = f.value.trim();
  if (!key) { f.focus(); return toast('Key required', 'Paste the provider API key.', 'err'); }
  try {
    await jpost('/api/v1/admin/keys', { provider: provider, key: key, base_url: '' });
    toast('Shared key stored', 'Every user without their own key now uses it.', 'ok');
    renderServerConfig();
  } catch (e) {
    toast('Could not store the key', e.message, 'err');
  } finally {
    f.value = '';   // cleared on every path, success or failure
  }
}

async function saveServerConfig(coding, thinking, prompting) {
  try {
    await jpost('/api/v1/admin/config', {
      default_model: coding.model, default_base_url: coding.base,
      think_model: thinking ? thinking.model : '', think_base_url: thinking ? thinking.base : '',
      prompt_model: prompting ? prompting.model : '', prompt_base_url: prompting ? prompting.base : '',
    });
    toast(coding.model ? 'Default model set' : 'Default cleared', coding.model || 'users now choose their own', 'ok');
    // /auth/me carries this to every client, so refresh our own copy rather than
    // displaying a value only this tab believes in.
    try {
      const me = await api.me();
      S.serverDefault = { model: me.default_model || '', base_url: me.default_base_url || '' };
    } catch (e) {}
    renderServerConfig();
  } catch (e) {
    toast('Could not save', e.message, 'err');
  }
}

function showNewUserForm() {
  const f = el('newUserForm');
  f.classList.remove('hide');
  f.innerHTML = `<div class="panel task-form">
    <div class="muted" style="margin-bottom:10px">
      Registration is closed on most installs, so this is how an account gets made. Hand the password
      over out of band — it is not shown again.
    </div>
    <div class="field-row">
      <div class="field"><label for="nuEmail">Email</label>
        <input id="nuEmail" type="email" autocapitalize="none" spellcheck="false"></div>
      <div class="field"><label for="nuPass">Password (8+ characters)</label>
        <input id="nuPass" type="password" autocomplete="new-password"></div>
    </div>
    <div class="row">
      <button class="btn btn-solid" id="nuSave">Create account</button>
      <button class="btn btn-ghost" id="nuCancel">Cancel</button>
    </div>
  </div>`;
  el('nuCancel').addEventListener('click', () => { f.classList.add('hide'); f.innerHTML = ''; });
  el('nuSave').addEventListener('click', createUser);
}

async function createUser() {
  const email = el('nuEmail').value.trim();
  const pass = el('nuPass').value;
  if (!email || !pass) return toast('Missing fields', 'Both an email and a password are required.', 'err');
  try {
    await api.adminCreate(email, pass);
    toast('Account created', email, 'ok');
    el('newUserForm').classList.add('hide');
    el('newUserForm').innerHTML = '';
    refreshUsers();
  } catch (e) {
    toast('Could not create the account', e.message, 'err');
  } finally {
    const p = el('nuPass');
    if (p) p.value = '';   // the password does not linger in the DOM, on either path
  }
}

async function refreshUsers() {
  const host = el('userList');
  if (!host) return;
  let users;
  try {
    const j = await api.adminUsers();
    users = j.users || [];
  } catch (e) {
    host.innerHTML = `<div class="empty">could not load users — ${esc(e.message)}</div>`;
    return;
  }
  host.innerHTML = `<div class="table-wrap"><table class="data">
    <thead><tr><th>account</th><th>plan</th><th class="num">swarms</th><th class="num">minds</th><th>state</th><th></th></tr></thead>
    <tbody>${users.map((u) => `<tr>
      <td><button class="linkbtn" data-user-open="${esc(String(u.id))}">${esc(u.email)}</button></td>
      <td>${esc(u.plan || 'free')}</td>
      <td class="num">${u.swarms || 0}</td>
      <td class="num">${u.live_minds || 0}</td>
      <td>${u.banned ? '<span class="pill">suspended</span>' : '<span class="pill on">active</span>'}</td>
      <td class="row-actions">
        <button class="btn btn-sm btn-ghost" data-user-mod="${esc(u.email)}" data-act="${u.banned ? 'unban' : 'ban'}">${u.banned ? 'Restore' : 'Suspend'}</button>
        <button class="btn btn-sm btn-danger" data-user-mod="${esc(u.email)}" data-act="delete">Delete</button>
      </td>
    </tr>`).join('')}</tbody></table></div>`;

  $$('[data-user-open]', host).forEach((b) => b.addEventListener('click', () => showUserActivity(b.dataset.userOpen)));
  $$('[data-user-mod]', host).forEach((b) => b.addEventListener('click', () => moderate(b.dataset.userMod, b.dataset.act)));
}

async function moderate(email, action) {
  const verb = action === 'delete' ? 'Delete' : (action === 'ban' ? 'Suspend' : 'Restore');
  if (!confirm(verb + ' ' + email + '?' + (action === 'delete' ? '\nThis cannot be undone.' : ''))) return;
  try {
    await api.adminModerate(email, action);
    toast(verb + 'd', email, 'ok');
    refreshUsers();
    el('userDetail').innerHTML = '';
  } catch (e) {
    toast('Could not ' + verb.toLowerCase(), e.message, 'err');
  }
}

async function showUserActivity(uid) {
  const host = el('userDetail');
  host.innerHTML = '<div class="empty">reading activity…</div>';
  let a;
  try {
    a = await api.adminActivity(uid);
  } catch (e) {
    host.innerHTML = `<div class="empty">could not read activity — ${esc(e.message)}</div>`;
    return;
  }
  const convs = a.convs || [];
  host.innerHTML = `
    <div class="section-head"><h2>${esc(a.email)}</h2>
      <button class="btn btn-sm btn-ghost" id="closeDetail">Close</button></div>
    <div class="stat-grid">
      <div class="stat"><b>${a.swarms || 0}</b><span>swarms</span></div>
      <div class="stat"><b>${a.live_minds || 0}</b><span>live minds</span></div>
      <div class="stat"><b>${convs.length}</b><span>conversations</span></div>
      <div class="stat ${a.banned ? 'bad' : 'good'}"><b>${a.banned ? 'suspended' : 'active'}</b><span>state</span></div>
    </div>
    <div class="panel set-panel">
      <div class="muted" style="margin-bottom:8px">
        Conversation metadata only — ids and sizes. Message content is not readable from here, by design.
      </div>
      ${convs.length ? `<div class="table-wrap"><table class="data">
        <thead><tr><th>conversation</th><th class="num">size</th></tr></thead>
        <tbody>${convs.map((c) => `<tr><td class="mono">${esc(c.id)}</td><td class="num">${fmtBytes(c.bytes || 0)}</td></tr>`).join('')}</tbody>
      </table></div>` : '<div class="muted">no conversations</div>'}
    </div>`;
  el('closeDetail').addEventListener('click', () => { host.innerHTML = ''; });
}

function fmtBytes(n) {
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  return (n / 1048576).toFixed(1) + ' MB';
}

/* ============================================================ settings */

const ROLES = [
  { key: '',        label: 'Coding',    hint: 'the build stream — and the fallback for every unset role' },
  { key: 'think_',  label: 'Thinking',  hint: 'planning, reflection, summaries' },
  { key: 'prompt_', label: 'Prompting', hint: 'drives the auto-loop' },
];

function renderSettings(host) {
  const st = S.settings;
  host.innerHTML = `
    <div class="scroller"><div class="pad">

      <div class="section-head"><h2>Appearance</h2></div>
      <div class="panel set-panel">
        <div class="set-row">
          <div><b>Theme</b><div class="muted">Light and dark, matching the desktop app.</div></div>
          <button class="btn btn-sm" id="setTheme">${currentTheme() === 'dark' ? 'Dark' : 'Light'}</button>
        </div>
        <div class="set-row">
          <div><b>Text size</b><div class="muted">Scales the whole interface.</div></div>
          <select id="setScale" class="w-auto">
            ${[['0.9', 'Small'], ['1', 'Normal'], ['1.12', 'Large'], ['1.25', 'Larger']].map(
              ([v, l]) => `<option value="${v}"${String(getScale()) === v ? ' selected' : ''}>${l}</option>`).join('')}
          </select>
        </div>
      </div>

      <div class="section-head"><h2>Models</h2></div>
      <div class="panel set-panel">
        ${S.serverDefault && S.serverDefault.model ? `
        <div class="set-row">
          <div><b>Use the server default</b>
            <div class="muted">This server is set up with <span class="mono">${esc(S.serverDefault.model)}</span>.
              Leave this on and you never have to think about models.</div>
          </div>
          <input type="checkbox" id="useDefault" class="w-auto" ${usingServerDefault() ? 'checked' : ''}>
        </div>` : ''}
        <div class="set-row">
          <div><b>One model for everything</b><div class="muted">Off = point coding, thinking and prompting at different models.</div></div>
          <input type="checkbox" id="setOne" class="w-auto" ${st.oneModel ? 'checked' : ''}>
        </div>
        <div id="rolePanels"></div>
      </div>

      <div class="section-head"><h2>Auto-loop</h2></div>
      <div class="panel set-panel">
        <div class="set-row">
          <div><b>Loop mode</b><div class="muted">Let a turn keep driving itself toward the goal.</div></div>
          <select id="setLoop" class="w-auto">
            <option value="0"${st.loop === 0 ? ' selected' : ''}>Off</option>
            <option value="1"${st.loop === 1 ? ' selected' : ''}>Auto-loop</option>
            <option value="2"${st.loop === 2 ? ' selected' : ''}>AFK (persistent)</option>
          </select>
        </div>
      </div>

      <div class="section-head"><h2>Provider keys</h2></div>
      <div class="panel set-panel">
        <div class="muted" style="margin-bottom:10px">
          Stored server-side in the sealed vault, scoped to your account — never in this browser.
        </div>
        <div id="keyList"><div class="muted">loading…</div></div>
        <div class="field-row" style="margin-top:10px">
          <div class="field"><label for="kProv">Provider</label>
            <input id="kProv" type="text" placeholder="openai" autocapitalize="none" spellcheck="false"></div>
          <div class="field"><label for="kBase">Base URL (optional)</label>
            <input id="kBase" type="text" placeholder="https://…" autocapitalize="none" spellcheck="false"></div>
        </div>
        <div class="field">
          <label for="kKey">API key</label>
          <input id="kKey" type="password" placeholder="sk-…" autocomplete="off"
                 autocapitalize="none" spellcheck="false" enterkeyhint="done">
        </div>
        <div class="key-add">
          <button class="btn btn-solid btn-sm" id="kAdd">Add a provider key</button>
          <span class="muted">sent once to your local server and sealed there — never stored in this browser</span>
        </div>
      </div>

      <div class="section-head"><h2>Account</h2></div>
      <div class="panel set-panel">
        <div class="set-row">
          <div><b>${esc(S.me ? S.me.email : '')}</b>
            <div class="muted">${esc(S.me && S.me.plan ? S.me.plan : 'free')}${S.isAdmin ? ' · admin' : ''}</div>
          </div>
          <button class="btn btn-sm btn-danger" id="setOut">Sign out</button>
        </div>
      </div>

    </div></div>`;

  el('setTheme').addEventListener('click', () => {
    setTheme(currentTheme() === 'dark' ? 'light' : 'dark');
    el('setTheme').textContent = currentTheme() === 'dark' ? 'Dark' : 'Light';
  });
  el('setScale').addEventListener('change', (e) => setScale(e.target.value));
  el('setOne').addEventListener('change', (e) => {
    S.settings.oneModel = e.target.checked;
    saveSettings();
    drawRolePanels();
  });
  el('setLoop').addEventListener('change', (e) => { S.settings.loop = parseInt(e.target.value, 10) || 0; saveSettings(); });
  el('setOut').addEventListener('click', async () => { try { await api.logout(); } catch (e) {} onSignedOut(); });
  el('kAdd').addEventListener('click', addProviderKey);
  if (el('useDefault')) el('useDefault').addEventListener('change', (e) => {
    // Clearing BOTH fields is what SELECTS the server default — the server only
    // applies it when the pair is blank, so half-clearing would silently do
    // nothing and look like the setting was ignored.
    if (e.target.checked) {
      S.settings.model = '';
      S.settings.base_url = '';
      S.settings.think_model = ''; S.settings.think_base_url = '';
      S.settings.prompt_model = ''; S.settings.prompt_base_url = '';
    } else if (S.serverDefault.model) {
      // Turning it OFF pre-fills with the server's own choice, so "customise"
      // starts from something that works rather than from empty fields.
      S.settings.model = S.serverDefault.model;
      S.settings.base_url = S.serverDefault.base_url || '';
    }
    saveSettings();
    drawRolePanels();
  });
  el('kKey').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); addProviderKey(); } });

  drawRolePanels();
  refreshKeys();
  // Redraw once the machine has answered about its own Ollama, so the local
  // group reflects what is pulled rather than what is merely catalogued.
  loadLocalModels().then(() => { if (S.tab === 'settings') drawRolePanels(); });
}

function getScale() { return parseFloat(LS.get('veil.textScale', '1')) || 1; }
function setScale(v) {
  LS.set('veil.textScale', String(v));
  document.documentElement.style.setProperty('--text-scale', String(v));
}

/* ---------------- the model catalog ----------------
   models.json ships 79 models across 14 providers with context window, tool
   reliability, cost tier and a prose note. A blank text box asks the user to
   have memorised a model slug; a grouped picker just shows them what exists.
   The free-text row stays underneath, because a custom endpoint must remain
   expressible — the catalog is a shortcut, not a cage. */

function providerLabel(key) {
  const p = S.models && S.models.providers && S.models.providers.find((x) => x.key === key);
  return p ? p.label : key;
}

function providerBase(key) {
  const p = S.models && S.models.providers && S.models.providers.find((x) => x.key === key);
  if (!p) return '';
  // "local" and "cloudflare" are sentinels, not URLs: Ollama is resolved by the
  // server's own default and Workers AI goes through the OAuth token path.
  if (!p.base_url || p.base_url === 'local' || p.base_url === 'cloudflare') return '';
  return p.base_url;
}

function modelById(id) {
  return (S.models && S.models.models || []).find((m) => m.id === id) || null;
}

/** Group the catalog by provider, hosting-local first so an offline user sees
    what actually runs on their machine before a list of paid endpoints.

    Local entries are reconciled against what Ollama has really pulled: the
    catalog says which local models are worth running, not which are installed,
    and offering one the machine has never downloaded produces a first-turn
    stall that reads like an app bug. Anything installed but not in the catalog
    is offered too — the user's own machine is authoritative about itself. */
function catalogOptions(selected) {
  const models = ((S.models && S.models.models) || []).slice();
  if (!models.length) return '';

  const installed = S.localModels && S.localModels.installed;
  if (installed) {
    const known = new Set(models.map((m) => m.id));
    for (const id of installed) {
      if (!known.has(id)) {
        models.push({ id: id, label: id, provider: 'ollama', hosting: 'local', installed: true });
      }
    }
  }

  const byProv = new Map();
  for (const m of models) {
    if (m.hosting === 'local' && installed && !installed.includes(m.id)) continue; // not pulled here
    if (!byProv.has(m.provider)) byProv.set(m.provider, []);
    byProv.get(m.provider).push(m);
  }
  const keys = Array.from(byProv.keys()).sort((a, b) => {
    const la = byProv.get(a)[0].hosting === 'local' ? 0 : 1;
    const lb = byProv.get(b)[0].hosting === 'local' ? 0 : 1;
    return la - lb || providerLabel(a).localeCompare(providerLabel(b));
  });
  let html = '<option value="">— custom / not listed —</option>';
  for (const k of keys) {
    html += `<optgroup label="${esc(providerLabel(k))}">`;
    for (const m of byProv.get(k)) {
      const tags = [];
      if (m.context) tags.push(Math.round(m.context / 1000) + 'k');
      if (m.tools && m.tools !== 'reliable') tags.push('tools: ' + m.tools);
      if (m.cost) tags.push(m.cost);
      html += `<option value="${esc(m.id)}"${m.id === selected ? ' selected' : ''}>`
            + esc(m.label) + (tags.length ? ' · ' + esc(tags.join(' · ')) : '') + '</option>';
    }
    html += '</optgroup>';
  }
  return html;
}

/** True when this account has chosen nothing and is riding the server's default.
    The server decides this the same way — a BLANK model+base pair — so the UI and
    the turn agree on what "using the default" means. */
function usingServerDefault() {
  return !!(S.serverDefault && S.serverDefault.model) && !S.settings.model && !S.settings.base_url;
}

function drawRolePanels() {
  const host = el('rolePanels');
  if (!host) return;
  const roles = S.settings.oneModel ? [ROLES[0]] : ROLES;
  const loaded = !!(S.models && S.models.models && S.models.models.length);
  const locked = usingServerDefault();
  // Disabled rather than hidden: the reader can still see WHAT they are getting,
  // and the fields explain themselves the moment the switch goes off.
  host.classList.toggle('locked', locked);
  if (locked) {
    host.innerHTML = '<div class="role-panel"><div class="role-title">Coding, thinking and prompting'
      + '<span class="muted"> — all using the server default</span></div>'
      + '<div class="muted mono">' + esc(S.serverDefault.model)
      + (S.serverDefault.base_url ? ' <span class="dim">· ' + esc(hostOf(S.serverDefault.base_url)) + '</span>' : '')
      + '</div></div>';
    return;
  }

  host.innerHTML = roles.map((r) => {
    const cur = S.settings[r.key + 'model'] || '';
    const known = modelById(cur);
    return `
    <div class="role-panel">
      <div class="role-title">${r.label}<span class="muted"> — ${esc(r.hint)}</span></div>
      ${loaded ? `
        <div class="field">
          <label>Model</label>
          <select data-pick="${r.key}">${catalogOptions(cur)}</select>
          <div class="model-note muted" data-note="${r.key}">${known && known.note ? esc(known.note) : ''}</div>
        </div>` : '<div class="muted" style="margin-bottom:10px">catalog unavailable — enter a model by hand</div>'}
      <div class="field-row">
        <div class="field"><label>Model id</label>
          <input type="text" data-set="${r.key}model" value="${esc(cur)}" placeholder="gpt-oss:20b"></div>
        <div class="field"><label>Base URL</label>
          <input type="text" data-set="${r.key}base_url" value="${esc(S.settings[r.key + 'base_url'] || '')}" placeholder="http://127.0.0.1:11434/v1"></div>
      </div>
      <div class="role-key" data-keystate="${r.key}">${roleKeyState(r.key)}</div>
    </div>`;
  }).join('');

  $$('[data-pick]', host).forEach((sel) => {
    sel.addEventListener('change', () => {
      const role = sel.dataset.pick;
      const id = sel.value;
      const m = modelById(id);
      S.settings[role + 'model'] = id;
      // Picking from the catalog fills the base URL too, since a model id
      // pointed at the wrong endpoint is the most common way to get a 404 that
      // reads like a model problem.
      if (m) S.settings[role + 'base_url'] = providerBase(m.provider);
      saveSettings();
      const idIn = host.querySelector('[data-set="' + role + 'model"]');
      const baseIn = host.querySelector('[data-set="' + role + 'base_url"]');
      if (idIn) idIn.value = S.settings[role + 'model'];
      if (baseIn) baseIn.value = S.settings[role + 'base_url'] || '';
      const note = host.querySelector('[data-note="' + role + '"]');
      if (note) note.textContent = m && m.note ? m.note : '';
      updateCharCount();   // the composer's cap follows the coding model's size
      refreshRoleKeyStates();
      if (m && m.provider) needsKeyHint(m.provider);
    });
  });

  $$('[data-set]', host).forEach((inp) => {
    inp.addEventListener('change', () => {
      S.settings[inp.dataset.set] = inp.value.trim();
      saveSettings();
      // A hand-typed id may not be in the catalog; drop the select to "custom"
      // rather than letting it claim a model the user did not choose.
      if (inp.dataset.set.endsWith('model')) {
        const role = inp.dataset.set.slice(0, -'model'.length);
        const sel = host.querySelector('[data-pick="' + role + '"]');
        if (sel) sel.value = modelById(inp.value.trim()) ? inp.value.trim() : '';
      }
    });
  });
}

/** Which provider does a role's base URL resolve to? Mirrors the server's own
    host match (modelcfg.providerForBase) so the UI and the turn agree on which
    vault entry will be used. */
function roleProvider(roleKey) {
  const base = S.settings[roleKey + 'base_url'] || '';
  const model = S.settings[roleKey + 'model'] || '';
  const m = modelById(model);
  if (m) return m.provider;
  if (!base) return '';
  const host = hostOf(base);
  const p = (S.models && S.models.providers || []).find(
    (x) => x.base_url && x.base_url !== 'local' && x.base_url !== 'cloudflare' && hostOf(x.base_url) === host);
  return p ? p.key : '';
}

function hostOf(url) {
  let s = String(url || '').trim();
  const i = s.indexOf('://');
  if (i >= 0) s = s.slice(i + 3);
  const j = s.search(/[/?#]/);
  return j >= 0 ? s.slice(0, j) : s;
}

/** Say, per role, which credential the turn will actually use. The key itself
    never comes to the browser — the server resolves it from this user's sealed
    vault when the request carries a blank key — so the honest thing to show is
    which provider it will look up and whether anything is on file. */
function roleKeyState(roleKey) {
  const prov = roleProvider(roleKey);
  if (!prov) return '';
  const p = (S.models && S.models.providers || []).find((x) => x.key === prov);
  if (!p) return '';
  if (p.base_url === 'local' || !p.needs_key) {
    return '<span class="ok-dot"></span><span class="key-what">' + esc(providerLabel(prov)) + ' · no key needed</span>';
  }
  const stored = (S.keys || []).find((k) => k.provider === prov);
  // The key lives WITH the model that needs it — sending someone to a different
  // panel to paste a key for the choice they just made is what read as broken.
  // The row is deliberately terse: a status dot, the provider, and the control.
  // The explanatory prose that used to sit here said nothing the field did not.
  if (stored) {
    return '<span class="ok-dot"></span>'
      + '<span class="key-what">' + esc(prov)
      + (stored.last4 ? ' <span class="muted">••••' + esc(stored.last4) + '</span>' : '') + '</span>'
      + '<button class="linkbtn" data-key-remove="' + esc(prov) + '">remove</button>';
  }
  // No disclosure toggle: when the key is missing, the field IS the message.
  return '<span class="bad-dot"></span>'
    + '<span class="key-what">' + esc(prov) + '</span>'
    + '<span class="inline-key" data-inlinefor="' + esc(prov) + '">'
    + '<input type="password" placeholder="' + esc(prov) + ' API key" autocomplete="off"'
    + ' autocapitalize="none" spellcheck="false" data-inlinekey="' + esc(prov) + '">'
    + '<button class="btn btn-sm btn-solid" data-inlinesave="' + esc(prov) + '">Save</button>'
    + '</span>';
}

function refreshRoleKeyStates() {
  $$('[data-keystate]').forEach((n) => { n.innerHTML = roleKeyState(n.dataset.keystate); });
}

/* DELEGATION, not per-node listeners. These controls live inside markup that is
   rebuilt with innerHTML from several independent paths (drawRolePanels, the
   model picker's change handler, refreshKeys resolving), and any repaint after
   a wiring pass silently orphans every listener attached to the old nodes — the
   buttons render perfectly and simply do nothing, which is indistinguishable
   from a styling bug. One document-level listener keyed on data attributes
   cannot be orphaned, so the render order stops mattering. */
document.addEventListener('click', (e) => {
  const t = e.target.closest ? e.target.closest('[data-inlinesave],[data-key-remove]') : null;
  if (!t) return;
  if (t.dataset.inlinesave !== undefined) return saveInlineKey(t.dataset.inlinesave);
  if (t.dataset.keyRemove !== undefined) return removeKey(t.dataset.keyRemove);
});

document.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter') return;
  const f = e.target;
  if (!f || !f.dataset || f.dataset.inlinekey === undefined) return;
  e.preventDefault();
  saveInlineKey(f.dataset.inlinekey);
});

async function saveInlineKey(provider) {
  const f = $('[data-inlinekey="' + provider + '"]');
  if (!f) return;
  const key = f.value.trim();
  if (!key) { f.focus(); return toast('Key required', 'Paste the provider API key.', 'err'); }
  try {
    // base_url is deliberately omitted: the role panel already carries the
    // endpoint, and storing a second copy here is how the two drift apart.
    await jpost('/api/v1/keys', { provider: provider, key: key, base_url: '' });
    toast('Key stored', providerLabel(provider) + ' — sealed server-side.', 'ok');
    await refreshKeys();
  } catch (e) {
    toast('Could not store the key', e.message, 'err');
  } finally {
    f.value = '';   // cleared on every path, success or failure
  }
}

/** One removal path for both the inline line and the Provider keys list, so the
    key list and every role line repaint together and cannot disagree. */
async function removeKey(provider) {
  if (!confirm('Remove the stored ' + provider + ' key?')) return;
  try {
    await jdel('/api/v1/keys/' + encodeURIComponent(provider));
    toast('Key removed', providerLabel(provider), 'ok');
    await refreshKeys();
  } catch (e) {
    toast('Could not remove the key', e.message, 'err');
  }
}

/** Pre-fill the standalone provider field after a model choice, so adding a key
    there is one paste rather than a spelling exercise. The inline affordance is
    the primary path now, so this no longer nags with a toast. */
function needsKeyHint(provider) {
  const prov = el('kProv');
  if (prov && !prov.value.trim()) prov.value = provider;
}

async function refreshKeys() {
  const host = el('keyList');
  if (!host) return;
  try {
    const j = await jget('/api/v1/keys');
    const keys = j.keys || [];
    S.keys = keys;   // needsKeyHint reads this to avoid nagging about a key you already have
    host.innerHTML = keys.length
      ? keys.map((k) => `<div class="key-row">
          <span class="mono grow">${esc(k.provider)}</span>
          <span class="muted">••••${esc(k.last4 || '')}</span>
          <button class="btn btn-sm btn-ghost" data-key-del="${esc(k.provider)}">Remove</button>
        </div>`).join('')
      : '<div class="muted">no provider keys stored</div>';
    refreshRoleKeyStates();   // the role panels report which of these they use
    $$('[data-key-del]', host).forEach((b) => b.addEventListener('click', () => removeKey(b.dataset.keyDel)));
  } catch (e) {
    // Say WHICH failure this is. "could not load keys" on an expired session sent
    // the last reader hunting for a key bug that did not exist — the list was
    // empty because the request was unauthorized, and with no list there was no
    // Remove button, which read as "keys cannot be deleted".
    S.keys = [];
    host.innerHTML = e.message === 'unauthorized'
      ? '<div class="muted">not signed in — reload the page</div>'
      : '<div class="muted">could not load keys — ' + esc(e.message) + '</div>';
    refreshRoleKeyStates();
  }
}

/* A provider key is a credential, so it never lands in S, in localStorage, or in
   any URL: the value goes straight from the field into the POST body and the
   field is cleared immediately, whether the request succeeded or not. The
   server answers with only a last4 and a fingerprint — the key itself never
   comes back. (This used to call prompt(), which browsers block outright in
   several contexts, so there was no way to enter a key at all.) */
async function addProviderKey() {
  const provEl = el('kProv'), keyEl = el('kKey'), baseEl = el('kBase');
  const provider = provEl.value.trim();
  const key = keyEl.value.trim();
  if (!provider) { provEl.focus(); return toast('Provider required', 'e.g. openai, anthropic, deepseek', 'err'); }
  if (!key) { keyEl.focus(); return toast('Key required', 'Paste the provider API key.', 'err'); }

  const btn = el('kAdd');
  btn.disabled = true;
  try {
    await jpost('/api/v1/keys', { provider: provider, key: key, base_url: baseEl.value.trim() });
    toast('Key stored', providerLabel(provider) + ' — sealed server-side.', 'ok');
    provEl.value = '';
    baseEl.value = '';
    refreshKeys();       // repaints the list AND the per-role "uses your stored X key" lines
  } catch (e) {
    toast('Could not store the key', e.message, 'err');
  } finally {
    keyEl.value = '';    // cleared on every path — a failed POST must not leave it sitting in the DOM
    btn.disabled = false;
  }
}

/* ============================================================ markdown
   mdRender() and highlightCode() are defined below this line. */

// ---- chat markdown ------------------------------------------------------------------------------
// A port of the desktop client's hand-written renderer (desk/src/mdutil.zig + renderMsg in main.zig) to
// the browser, so a transcript reads the same in both surfaces: same pragmatic GFM subset, same
// robustness contract — hostile or half-arrived input degrades to readable literals and NEVER throws
// (this runs on every poll tick against a growing string).
// SECURITY: the input is model output and tool results, i.e. untrusted. Every byte of user text goes
// through mdEsc; the only unescaped markup is what this file emits itself, and hrefs are scheme-checked.

const MD_ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

function mdEsc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => MD_ESC[c]);
}

// btoa is latin1-only; percent-encode first so any code point round-trips through the copy button.
function mdB64(s) {
  return btoa(unescape(encodeURIComponent(String(s == null ? '' : s))));
}

// Only http/https/mailto (or a scheme-less relative ref) may become an href; null rejects the link.
// Control characters are dropped BEFORE the scheme test because "java\tscript:" still executes.
function mdSafeUrl(u) {
  let clean = '';
  for (const ch of String(u == null ? '' : u).trim()) {
    const cc = ch.charCodeAt(0);
    if (cc > 32 && cc !== 127) clean += ch;
  }
  const scheme = /^([a-z][a-z0-9+.\-]*):/.exec(clean.toLowerCase());
  if (!scheme) return clean; // relative / fragment / protocol-relative
  return scheme[1] === 'http' || scheme[1] === 'https' || scheme[1] === 'mailto' ? clean : null;
}

const mdIsAlnum = (c) => !!c && /[0-9A-Za-z]/.test(c);
// horizontal rule: 3+ of '-', '*' or '_', spaces allowed, nothing else
const mdIsHr = (tl) => /^(?:-\s*){3,}$|^(?:\*\s*){3,}$|^(?:_\s*){3,}$/.test(tl);
// the |---|:--:|---| row under a table header: only | - : and spaces, with at least one '-'
const mdIsTableSep = (tl) => tl.indexOf('-') >= 0 && /^[|\-: ]+$/.test(tl);
// strip the outer pipes so a plain '|' split yields exactly the cells
const mdCells = (tl) => tl.replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());

// ---- inline grammar ------------------------------------------------------------------------------
// Phase A lifts `code` spans out verbatim into a masked buffer; phase B scans emphasis and links over
// that buffer. The mask is why markers inside inline code stay literal — phase B skips masked bytes.

function mdFenceRun(s, from, fence) {
  for (let i = from; i + fence <= s.length; i++) {
    if (s[i] === '`' && (fence === 1 || s[i + 1] === '`')) return i;
  }
  return -1;
}

function mdLiftCode(src) {
  const w = [];
  const m = [];
  let i = 0;
  while (i < src.length) {
    if (src[i] !== '`') { w.push(src[i]); m.push(false); i++; continue; }
    const fence = src[i + 1] === '`' ? 2 : 1;
    const close = mdFenceRun(src, i + fence, fence);
    if (close < 0) { // no closer — the backticks are literal text
      for (let k = 0; k < fence; k++) { w.push('`'); m.push(false); }
      i += fence;
      continue;
    }
    let body = src.slice(i + fence, close);
    // the `` ` `` convention: a symmetric pad space inside a doubled fence is trimmed
    if (fence === 2 && body.length >= 2 && body[0] === ' ' && body[body.length - 1] === ' ') body = body.slice(1, -1);
    for (const ch of body) { w.push(ch === '\n' || ch === '\t' ? ' ' : ch); m.push(true); }
    i = close + fence;
  }
  return { w, m };
}

// Is a viable CLOSING marker (outside code, non-space before it) ahead? An opener only activates when
// its pair exists — an unmatched ** stays literal instead of restyling the rest of the line.
function mdFindPair(w, m, from, marker, count) {
  for (let i = from; i + count <= w.length; i++) {
    if (m[i] || w[i] !== marker) continue;
    if (count === 2 && (w[i + 1] !== marker || m[i + 1])) continue;
    const prv = i > 0 ? w[i - 1] : ' ';
    if (prv !== ' ' && prv !== marker) return true;
  }
  return false;
}

// A well-formed "[label](url)" starting at `open`; null means the '[' is a literal.
function mdLinkAt(w, open) {
  let rb = open + 1;
  while (rb < w.length && w[rb] !== ']') {
    if (w[rb] === '[') return null; // nested bracket — the whole thing is literal
    rb++;
  }
  if (rb >= w.length || rb === open + 1 || w[rb + 1] !== '(') return null;
  // balanced-paren scan, so a link like .../X_(disambiguation) keeps its closing paren
  let rp = rb + 2;
  let depth = 1;
  while (rp < w.length) {
    if (w[rp] === '(') depth++;
    else if (w[rp] === ')' && --depth === 0) break;
    rp++;
  }
  if (rp >= w.length) return null;
  return { labelEnd: rb, next: rp + 1, url: w.slice(rb + 2, rp).join('') };
}

// Wrap one styled run. Nesting order is fixed (link outermost, code innermost) so every run is
// independently well-formed html no matter which flags are combined.
function mdWrap(text, st) {
  let h = mdEsc(text);
  if (st.code) h = '<code>' + h + '</code>';
  if (st.italic) h = '<em>' + h + '</em>';
  if (st.bold) h = '<strong>' + h + '</strong>';
  if (st.strike) h = '<del>' + h + '</del>';
  if (st.href) h = '<a href="' + mdEsc(st.href) + '" target="_blank" rel="noopener noreferrer nofollow">' + h + '</a>';
  return h;
}

const mdSameStyle = (a, b) =>
  a.bold === b.bold && a.italic === b.italic && a.code === b.code && a.strike === b.strike && a.href === b.href;

// Parse one source line's inline markup to html: `code`/``code`` (verbatim), **bold**/__bold__,
// *italic*/_italic_ (word-flanked, so snake_case and "a * b" survive), ~~strike~~, [label](url),
// ![alt](url) -> alt, bare http(s) autolinks, <br> -> a hard break. Unpaired markers stay literal.
function mdInline(src) {
  const { w, m } = mdLiftCode(String(src == null ? '' : src).replace(/\r/g, '').trim());
  const n = w.length;
  let out = '';
  let buf = '';
  let cur = { bold: false, italic: false, code: false, strike: false, href: null };
  const st = { bold: false, italic: false, code: false, strike: false, href: null };
  const flush = () => { if (buf) { out += mdWrap(buf, cur); buf = ''; } };
  const put = (ch, want) => {
    if (!mdSameStyle(cur, want)) { flush(); cur = Object.assign({}, want); }
    buf += ch;
  };
  const lastCh = () => (buf ? buf[buf.length - 1] : ' ');
  const codeOf = (over) => ({ bold: st.bold, italic: st.italic, code: !!over, strike: st.strike, href: st.href });

  let linkEnd = -1;    // index where an open link's label ends
  let linkResume = -1; // index to continue from (skips the "(url)" tail)
  let i = 0;
  while (i < n) {
    if (st.href && i === linkEnd) { st.href = null; i = linkResume; continue; }
    const c = w[i];
    if (m[i]) { put(c, codeOf(true)); i++; continue; } // inline code: verbatim, emphasis rides along
    // <br> family -> a real hard break
    if (c === '<' && /^<br\s*\/?>/i.test(w.slice(i, i + 8).join(''))) {
      while (buf && buf[buf.length - 1] === ' ') buf = buf.slice(0, -1);
      flush();
      out += '<br>';
      const gt = w.indexOf('>', i);
      i = gt < 0 ? n : gt + 1;
      continue;
    }
    // doubled markers: **bold** __bold__ ~~strike~~
    if ((c === '*' || c === '_' || c === '~') && i + 1 < n && w[i + 1] === c && !m[i + 1]) {
      const strike = c === '~';
      if (!(strike ? st.strike : st.bold)) {
        if ((i + 2 < n ? w[i + 2] : ' ') !== ' ' && mdFindPair(w, m, i + 2, c, 2)) {
          if (strike) st.strike = true; else st.bold = true;
          i += 2;
          continue;
        }
      } else if (lastCh() !== ' ') {
        if (strike) st.strike = false; else st.bold = false;
        i += 2;
        continue;
      }
      put(c, codeOf(false)); // literal marker — the loop revisits the second character
      i++;
      continue;
    }
    // single * / _ -> italic (word-flanked; snake_case underscores survive)
    if (c === '*' || c === '_') {
      const prv = lastCh();
      const nxt = i + 1 < n ? w[i + 1] : ' ';
      if (!st.italic) {
        if (!(c === '_' && mdIsAlnum(prv)) && nxt !== ' ' && nxt !== c && mdFindPair(w, m, i + 1, c, 1)) {
          st.italic = true;
          i++;
          continue;
        }
      } else if (!(c === '_' && mdIsAlnum(nxt)) && prv !== ' ') {
        st.italic = false;
        i++;
        continue;
      }
      put(c, codeOf(false));
      i++;
      continue;
    }
    // [label](url) and ![alt](url) — an image degrades to its alt text, matching the desk
    if (!st.href && (c === '[' || (c === '!' && w[i + 1] === '[' && !m[i + 1]))) {
      const open = c === '!' ? i + 1 : i;
      const lk = mdLinkAt(w, open);
      if (lk) {
        const sp = lk.url.trim().indexOf(' ');
        const u = sp >= 0 ? lk.url.trim().slice(0, sp) : lk.url.trim(); // drop a `"title"` tail
        const safe = u ? mdSafeUrl(u) : null;
        if (safe !== null) {
          flush();
          st.href = safe;
          linkEnd = lk.labelEnd;
          linkResume = lk.next;
          i = open + 1;
          continue;
        }
        // rejected scheme: keep the LABEL as plain text, swallow the url so no href is ever emitted
        for (let k = open + 1; k < lk.labelEnd; k++) put(w[k], codeOf(false));
        i = lk.next;
        continue;
      }
    }
    // bare autolink
    if (!st.href && c === 'h' && /^https?:\/\//.test(w.slice(i, i + 8).join(''))) {
      let end = i;
      while (end < n && w[end] !== ' ' && !m[end]) end++;
      while (end > i && '.,;:!?)"\''.indexOf(w[end - 1]) >= 0) end--; // trailing sentence punctuation isn't url
      const safe = mdSafeUrl(w.slice(i, end).join(''));
      if (end > i + 8 && safe !== null) {
        const want = { bold: st.bold, italic: st.italic, code: st.code, strike: st.strike, href: safe };
        for (let k = i; k < end; k++) put(w[k], want); // one run: the url's _ and * are literal bytes
        i = end;
        continue;
      }
    }
    if (c === ' ' && lastCh() === ' ') { i++; continue; } // collapse space runs outside code
    put(c, codeOf(false));
    i++;
  }
  while (buf && buf[buf.length - 1] === ' ') buf = buf.slice(0, -1);
  flush();
  return out;
}

// ---- block grammar -------------------------------------------------------------------------------

// Nesting depth from leading whitespace: 2 spaces (or one tab) per level, capped at 3 like the desk.
function mdListDepth(raw) {
  let sp = 0;
  for (const c of raw) {
    if (c === ' ') sp++;
    else if (c === '\t') sp += 2;
    else break;
  }
  return Math.min(sp >> 1, 3);
}

// "N. " / "N) " with up to 3 digits -> the marker length, else 0.
function mdOrdLen(tl) {
  const m = /^(\d{1,3})[.)] /.exec(tl);
  return m ? m[0].length : 0;
}

const mdIsItem = (tl) => tl.startsWith('- ') || tl.startsWith('* ') || tl.startsWith('+ ') || mdOrdLen(tl) > 0;

/// Render a whole markdown message to html. Line-oriented like the desk renderer: every source line is a
/// block candidate, so a single newline inside a paragraph is a real line break (<br>) — chat text relies
/// on that — and a blank line separates paragraphs.
function mdRender(src) {
  const lines = String(src == null ? '' : src).replace(/\r/g, '').split('\n');
  const out = [];
  const stack = []; // open lists: { depth, ordered, li }
  let codeIdx = 0;
  const closeTop = () => {
    const top = stack.pop();
    if (top.li) out.push('</li>');
    out.push(top.ordered ? '</ol>' : '</ul>');
  };
  const closeLists = () => { while (stack.length) closeTop(); };

  let i = 0;
  while (i < lines.length) {
    const raw = lines[i];
    const tl = raw.trim();

    // fenced code block, grouped by lookahead to the closing fence. An UNCLOSED fence still renders to
    // the end of input: while streaming, the last fence is usually incomplete, and dropping it would
    // make the tail of every reply flicker in and out as tokens arrive.
    if (tl.startsWith('```')) {
      closeLists();
      let j = i + 1;
      while (j < lines.length && !lines[j].trim().startsWith('```')) j++;
      const lang = tl.slice(3).replace(/[`\s]/g, '').toLowerCase();
      const code = lines.slice(i + 1, j).join('\n');
      out.push('<div class="code-block"><div class="code-head"><span class="code-lang">' + mdEsc(lang || 'text') +
        '</span><button class="code-copy" data-code-idx="' + codeIdx + '" data-raw="' + mdEsc(mdB64(code)) +
        '">copy</button></div><pre><code>' + highlightCode(code, lang) + '</code></pre></div>');
      codeIdx++;
      i = j + 1;
      continue;
    }
    if (mdIsHr(tl)) { closeLists(); out.push('<hr>'); i++; continue; }
    // GFM table: a pipe row whose NEXT line is the |---|---| separator. Wrapped so css can give the
    // table its own horizontal scroll — the desk pans wide tables rather than amputating cells.
    if (tl.indexOf('|') >= 0 && i + 1 < lines.length && mdIsTableSep(lines[i + 1].trim())) {
      closeLists();
      const align = mdCells(lines[i + 1].trim()).map((c) => {
        const l = c.startsWith(':');
        const r = c.endsWith(':');
        return l && r ? 'center' : r ? 'right' : l ? 'left' : '';
      });
      const sty = (k) => (align[k] ? ' style="text-align:' + align[k] + '"' : '');
      const head = mdCells(tl);
      let h = '<div class="table-wrap"><table><thead><tr>';
      for (let k = 0; k < head.length; k++) h += '<th' + sty(k) + '>' + mdInline(head[k]) + '</th>';
      h += '</tr></thead><tbody>';
      let j = i + 2;
      while (j < lines.length && lines[j].trim().indexOf('|') >= 0) {
        const row = lines[j].trim();
        if (!mdIsTableSep(row)) {
          const cells = mdCells(row);
          h += '<tr>';
          for (let k = 0; k < head.length; k++) h += '<td' + sty(k) + '>' + mdInline(cells[k] || '') + '</td>';
          h += '</tr>';
        }
        j++;
      }
      out.push(h + '</tbody></table></div>');
      i = j;
      continue;
    }
    const hm = /^(#{1,6})\s*(.*)$/.exec(tl); // ATX heading
    if (hm) {
      closeLists();
      out.push('<h' + hm[1].length + '>' + mdInline(hm[2]) + '</h' + hm[1].length + '>');
      i++;
      continue;
    }
    // blockquote — consecutive '>' lines fold into one quote, hard-broken like a paragraph
    if (tl.startsWith('>')) {
      closeLists();
      const parts = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        parts.push(mdInline(lines[i].trim().slice(1).replace(/^ /, '')));
        i++;
      }
      out.push('<blockquote>' + parts.join('<br>') + '</blockquote>');
      continue;
    }
    if (!tl) { closeLists(); i++; continue; } // blank line closes any open list and ends the paragraph

    // list item: bullet, task or ordered, with indent-based nesting
    if (mdIsItem(tl)) {
      const ordLen = mdOrdLen(tl);
      const ordered = ordLen > 0;
      const depth = mdListDepth(raw);
      while (stack.length && stack[stack.length - 1].depth > depth) closeTop();
      let top = stack[stack.length - 1];
      if (top && top.depth === depth && top.ordered !== ordered) { closeTop(); top = stack[stack.length - 1]; }
      if (!top || top.depth < depth) {
        // a deeper list opens INSIDE the parent's still-open <li> — that is what makes nesting valid html
        out.push(ordered ? '<ol>' : '<ul>');
        stack.push({ depth, ordered, li: false });
      } else if (top.li) {
        out.push('</li>');
        top.li = false;
      }
      let body = ordered ? tl.slice(ordLen) : tl.slice(2);
      let box = '';
      const tm = !ordered && /^\[([ xX])\](\s|$)/.exec(body);
      if (tm) {
        box = '<input type="checkbox" disabled' + (tm[1] === ' ' ? '' : ' checked') + '> ';
        body = body.slice(3).replace(/^\s+/, '');
      }
      out.push('<li' + (box ? ' class="task"' : '') + '>' + box + mdInline(body));
      stack[stack.length - 1].li = true;
      i++;
      continue;
    }
    // plain prose — consecutive lines join into one paragraph with hard breaks between them
    closeLists();
    const para = [];
    while (i < lines.length) {
      const t2 = lines[i].trim();
      if (!t2 || t2.startsWith('```') || t2.startsWith('>') || t2.startsWith('#') || mdIsHr(t2) || mdIsItem(t2)) break;
      if (t2.indexOf('|') >= 0 && i + 1 < lines.length && mdIsTableSep(lines[i + 1].trim())) break;
      para.push(mdInline(t2));
      i++;
    }
    if (para.length) out.push('<p>' + para.join('<br>') + '</p>');
    else i++; // defensive: never let the outer loop stall on a line no branch consumed
  }
  closeLists();
  return out.join('');
}

// ---- syntax highlighting -------------------------------------------------------------------------
// CONTRACT: `code` is RAW text, never pre-escaped. This function escapes internally, so there is exactly
// one escaping layer — mdRender hands it the fence body verbatim.
//
// Regex-based, not a real tokenizer. The one correctness property that matters: comment and string rules
// come FIRST in the alternation, and a combined alternation matches leftmost-first, so a keyword inside a
// string literal is never re-coloured.

const SYN_WORDS = {
  js: { kw: 'const let var function return if else for while do break continue new class extends super this typeof instanceof in of delete void yield async await try catch finally throw switch case default import export from as static get set with debugger interface type enum namespace declare implements readonly public private protected abstract satisfies keyof infer', ty: 'string number boolean any unknown never object symbol bigint true false null undefined Array Object Promise Map Set JSON Math Date RegExp Error String Number Boolean console window document' },
  python: { kw: 'def class return if elif else for while break continue pass import from as with try except finally raise lambda yield global nonlocal assert del in is not and or async await match case', ty: 'int float str bool list dict set tuple bytes object type self cls None True False Exception ValueError TypeError KeyError print len range enumerate zip open super property staticmethod classmethod' },
  zig: { kw: 'const var fn pub return if else while for switch break continue defer errdefer try catch orelse comptime inline struct enum union error test unreachable and or usingnamespace async await suspend resume export extern packed align threadlocal noalias volatile allowzero anytype linksection callconv opaque nosuspend', ty: 'u1 u8 u16 u32 u64 u128 usize i8 i16 i32 i64 i128 isize f16 f32 f64 f80 f128 bool void type noreturn anyerror anyopaque anyframe c_int c_uint c_long c_ulong c_char null true false undefined std' },
  rust: { kw: 'fn let mut const static struct enum impl trait for while loop if else match return break continue use mod pub crate super as ref move where type dyn unsafe async await extern in yield', ty: 'i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 usize isize f32 f64 bool char str String Vec Option Result Box Rc Arc RefCell HashMap HashSet Some None Ok Err Self self true false' },
  go: { kw: 'func var const type struct interface package import return if else for range switch case default break continue go defer chan map select fallthrough goto', ty: 'int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 complex64 complex128 string bool byte rune error any nil true false make new len cap append copy delete panic recover' },
  c: { kw: 'if else for while do switch case default break continue return goto sizeof typedef struct union enum static const volatile extern register inline auto restrict class public private protected virtual override final template typename namespace using new delete this operator try catch throw constexpr explicit friend mutable noexcept', ty: 'void char short int long float double signed unsigned bool size_t ssize_t ptrdiff_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE NULL nullptr true false std string vector map' },
  sql: { ci: true, kw: 'select from where insert into values update set delete create table drop alter add index view join left right inner outer full cross on group by order having limit offset union all distinct as and or not null is like ilike between exists case when then else end primary foreign key references default unique constraint begin commit rollback with returning asc desc count sum avg min max coalesce cast', ty: 'int integer bigint smallint serial bigserial varchar char text boolean date timestamp timestamptz time interval numeric decimal real double precision json jsonb uuid blob bytea array' },
  bash: { kw: 'if then else elif fi for while until do done case esac function return in select break continue local export readonly declare typeset shift eval exec source alias unalias unset trap set let time', ty: 'echo printf read cd pwd ls cat grep sed awk cut sort uniq head tail wc cp mv rm mkdir rmdir touch chmod chown ln find xargs tar gzip curl wget ssh scp git npm npx node python python3 pip cargo zig go make docker kubectl systemctl sudo test true false' },
  yaml: { kw: 'true false null yes no on off', ty: '' },
  json: { kw: 'true false null', ty: '' },
  css: { kw: '', ty: '' },
  html: { kw: '', ty: '' },
  text: { kw: '', ty: '' },
};

const SYN_ALIAS = {
  javascript: 'js', typescript: 'js', ts: 'js', jsx: 'js', tsx: 'js', mjs: 'js', node: 'js',
  py: 'python', python3: 'python', rs: 'rust', golang: 'go',
  cpp: 'c', 'c++': 'c', cc: 'c', h: 'c', hpp: 'c', java: 'c', cs: 'c', csharp: 'c', kotlin: 'c', swift: 'c',
  shell: 'bash', sh: 'bash', zsh: 'bash', console: 'bash', terminal: 'bash', powershell: 'bash', ps1: 'bash',
  yml: 'yaml', toml: 'yaml', ini: 'yaml', conf: 'yaml', scss: 'css', less: 'css',
  xml: 'html', svg: 'html', vue: 'html', postgres: 'sql', postgresql: 'sql', mysql: 'sql', sqlite: 'sql',
  md: 'text', markdown: 'text', diff: 'text', log: 'text', plaintext: 'text', txt: 'text', '': 'text',
};

const SYN_SETS = {};
function synSet(lang, which) {
  const key = lang + ':' + which;
  if (!SYN_SETS[key]) SYN_SETS[key] = new Set((SYN_WORDS[lang][which] || '').split(' ').filter(Boolean));
  return SYN_SETS[key];
}

// Rule sources. Every sub-group MUST be non-capturing: the tokenizer maps capture-group index to rule.
const SYN_STR_D = '"(?:\\\\.|[^"\\\\\\n])*"?';   // double quotes may stay open (streaming / wrapped lines)
const SYN_STR_S = "'(?:\\\\.|[^'\\\\\\n])*'";    // single quotes must close, so prose apostrophes don't run
const SYN_CHR = "'(?:\\\\[^\\n]|[^'\\\\\\n])'";  // a CHAR literal is exactly one char — a rust lifetime
                                                 // (&'a str) then can't swallow up to the next quote
const SYN_TPL = '`(?:\\\\.|[^`\\\\])*`?';
const SYN_NUM = '\\b(?:0[xXbBoO][0-9a-fA-F_]+|\\d[\\d_]*(?:\\.[\\d_]+)?(?:[eE][+-]?\\d+)?)\\b';
const SYN_FN = '[A-Za-z_$][\\w$]*(?=\\s*\\()';
const SYN_ID = '[A-Za-z_$][\\w$]*';
const SYN_BLOCK_C = '\\/\\*[\\s\\S]*?(?:\\*\\/|$)';

// ORDER IS THE CONTRACT: comments, then strings, then numbers, then words.
function synRules(lang) {
  const rules = [];
  if (lang === 'html') {
    rules.push({ src: '<!--[\\s\\S]*?(?:-->|$)', cls: 'syn-comment' });
    rules.push({ src: SYN_STR_D, cls: 'syn-string' }, { src: SYN_STR_S, cls: 'syn-string' });
    rules.push({ src: '(?:<\\/?)[A-Za-z][\\w:-]*', cls: 'syn-keyword' });
    rules.push({ src: '[A-Za-z-]+(?=\\s*=)', cls: 'syn-type' });
    return rules;
  }
  if (lang === 'css') {
    rules.push({ src: SYN_BLOCK_C, cls: 'syn-comment' });
    rules.push({ src: SYN_STR_D, cls: 'syn-string' }, { src: SYN_STR_S, cls: 'syn-string' });
    rules.push({ src: '@[A-Za-z-]+', cls: 'syn-keyword' });
    rules.push({ src: '[.#][A-Za-z_-][\\w-]*', cls: 'syn-function' });
    rules.push({ src: '[A-Za-z-]+(?=\\s*:)', cls: 'syn-type' });
    rules.push({ src: '(?:#[0-9a-fA-F]{3,8}|' + SYN_NUM + '(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?)', cls: 'syn-number' });
    return rules;
  }
  const hash = lang === 'python' || lang === 'yaml' || lang === 'bash';
  if (lang === 'python') rules.push({ src: '(?:"""|\'\'\')[\\s\\S]*?(?:"""|\'\'\'|$)', cls: 'syn-string' });
  rules.push({ src: (hash ? '#' : lang === 'sql' ? '\\-\\-' : '\\/\\/') + '[^\\n]*', cls: 'syn-comment' });
  if (!hash && lang !== 'zig') rules.push({ src: SYN_BLOCK_C, cls: 'syn-comment' });
  if (lang === 'zig') rules.push({ src: '\\\\\\\\[^\\n]*', cls: 'syn-string' }); // zig \\ multiline string
  const charLit = lang === 'rust' || lang === 'c' || lang === 'zig' || lang === 'go';
  rules.push({ src: SYN_STR_D, cls: 'syn-string' }, { src: charLit ? SYN_CHR : SYN_STR_S, cls: 'syn-string' });
  if (lang === 'js' || lang === 'bash') rules.push({ src: SYN_TPL, cls: 'syn-string' });
  if (lang === 'yaml') rules.push({ src: '^[ \\t-]*[A-Za-z_][\\w.-]*(?=\\s*:)', cls: 'syn-type' });
  if (lang === 'bash') rules.push({ src: '\\$(?:\\{[^}\\n]*\\}|[A-Za-z_]\\w*|[0-9@*#?])', cls: 'syn-type' });
  rules.push({ src: SYN_NUM, cls: 'syn-number' });
  const kw = synSet(lang, 'kw');
  const ty = synSet(lang, 'ty');
  const ci = !!SYN_WORDS[lang].ci; // sql keywords are conventionally upper-case
  const word = (t) => {
    const k = ci ? t.toLowerCase() : t;
    return kw.has(k) ? 'syn-keyword' : ty.has(k) ? 'syn-type' : null;
  };
  rules.push({ src: SYN_FN, cls: (t) => word(t) || 'syn-function' });
  rules.push({ src: SYN_ID, cls: (t) => word(t) || 'syn-default' });
  return rules;
}

const SYN_RE = {};
function synRe(lang) {
  if (!SYN_RE[lang]) {
    const rules = synRules(lang);
    SYN_RE[lang] = { re: new RegExp(rules.map((r) => '(' + r.src + ')').join('|'), 'gm'), rules };
  }
  return SYN_RE[lang];
}

function synSpan(cls, text) {
  if (!text) return '';
  if (cls === 'syn-default' && !text.trim()) return mdEsc(text); // don't wrap bare whitespace
  return '<span class="' + cls + '">' + mdEsc(text) + '</span>';
}

/// Highlight RAW source `code` for `lang`, returning html with syn-* spans. An unrecognised language
/// falls back to the generic c-like pass, so comments/strings/numbers still read correctly.
function highlightCode(code, lang) {
  const src = String(code == null ? '' : code);
  let key = String(lang == null ? '' : lang).trim().toLowerCase();
  key = SYN_ALIAS[key] || key;
  if (!SYN_WORDS[key]) key = 'js';
  const { re, rules } = synRe(key);
  re.lastIndex = 0;
  let out = '';
  let last = 0;
  let pend = ''; // run of unclassified text, merged into ONE span instead of one per word
  const flushPend = () => { out += synSpan('syn-default', pend); pend = ''; };
  let m;
  while ((m = re.exec(src)) !== null) {
    if (m[0] === '') { re.lastIndex++; continue; } // a zero-width match would spin forever
    if (m.index > last) pend += src.slice(last, m.index);
    let gi = 1;
    while (gi <= rules.length && m[gi] === undefined) gi++;
    const rule = rules[gi - 1];
    const cls = typeof rule.cls === 'function' ? rule.cls(m[gi]) : rule.cls;
    if (cls === 'syn-default') pend += m[gi];
    else { flushPend(); out += synSpan(cls, m[gi]); }
    last = re.lastIndex;
  }
  pend += src.slice(last);
  flushPend();
  return out;
}

boot();
