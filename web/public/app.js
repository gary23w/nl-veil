/* neuron-loops — Neovim-themed control UI (vanilla, no build step). The ':' command line IS the minds-debugger. */
'use strict';

const S = {
  user: null,
  swarms: [],            // [{id,name,model,minds,state,created}]
  sel: null,             // selected swarm id
  ev: {},                // id -> { offset:int, lines:[{kind,...}] }
  mode: 'NORMAL',        // NORMAL | INSERT | COMMAND
  focus: 'tick',         // tick | chat | loop
  screen: 'workspace',   // workspace | api | admin  (top-level full-page screens)
  view: 'live',          // live | build
  buildMode: 'code',     // code | preview  (the build tab's editor vs live render)
  openFile: null,        // currently-open build file path
  flash: { msg: '', cls: '' },
  models: null,
  poll: null,
};

// fetch with an abort timeout — a slow/hung request can never block the UI (it resolves to a soft failure)
function tfetch(path, opts = {}, ms = 12000) {
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), ms);
  return fetch(path, { ...opts, signal: ac.signal }).finally(() => clearTimeout(to));
}
const api = {
  async j(method, path, body) {
    try {
      const r = await tfetch(path, { method, credentials: 'include',
        headers: body ? { 'content-type': 'application/json' } : undefined,
        body: body ? JSON.stringify(body) : undefined });
      let data = {}; try { data = await r.json(); } catch (_) {}
      return { status: r.status, data };
    } catch (_) { return { status: 0, data: {} }; }   // timeout/abort -> soft failure, caller retries
  },
  get(p) { return this.j('GET', p); },
  post(p, b) { return this.j('POST', p, b); },
  del(p) { return this.j('DELETE', p); },
  async putRaw(p, body) {
    try {
      const r = await tfetch(p, { method: 'PUT', credentials: 'include', body });
      let data = {}; try { data = await r.json(); } catch (_) {}
      return { status: r.status, data };
    } catch (_) { return { status: 0, data: {} }; }
  },
  async text(p) {
    try {
      const r = await tfetch(p, { credentials: 'include' });
      return { status: r.status, text: await r.text(), next: parseInt(r.headers.get('x-next-offset') || '0', 10) };
    } catch (_) { return { status: 0, text: '', next: 0 }; }
  },
};

const el = (id) => document.getElementById(id);
const esc = (s) => (s || '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ===================================================================== boot
async function boot() {
  const me = await api.get('/api/v1/auth/me');
  if (me.status === 200 && me.data.authed) { S.user = me.data; await loadModels(); enterWorkspace(); }
  else renderLogin(!!(me.data && me.data.open_registration));
}
async function loadModels() {
  try { const r = await fetch('/models.json'); S.models = await r.json(); } catch (_) { S.models = { models: [], defaults: {} }; }
}

// ===================================================================== login
function renderLogin(openReg) {
  document.body.classList.remove('in-app');
  el('app').innerHTML = `
    <div class="login">
      <h1><span class="n">neuron</span><span class="l">-loops</span></h1>
      <div class="sub">deploy minds. watch them think. steer them live.</div>
      <label>email</label><input id="li-email" type="email" autocomplete="username" autofocus>
      <label>password</label><input id="li-pass" type="password" autocomplete="current-password">
      <div class="row">
        <button class="btn-primary" id="li-login">log in</button>
        ${openReg ? '<button class="btn-ghost" id="li-register">register</button>' : ''}
      </div>
      ${openReg ? '' : '<div class="sub" style="margin-top:10px;opacity:.55">private beta — sign-in only</div>'}
      <div class="msg" id="li-msg"></div>
    </div>`;
  const go = async (path) => {
    const ei = el('li-email'), pi = el('li-pass'), msg = el('li-msg');
    if (!ei || !pi || !msg) return;   // login form no longer mounted (already in the workspace) — ignore
    const email = ei.value.trim(), password = pi.value;
    if (!email || !password) { msg.className = 'msg err'; msg.textContent = 'email + password required'; return; }
    const r = await api.post(path, { email, password });
    if (r.status === 200 || r.status === 201) {
      if (path.endsWith('register')) { msg.className = 'msg ok'; msg.textContent = 'registered — logging in…';
        const lg = await api.post('/api/v1/auth/login', { email, password });
        if (lg.status !== 200) { msg.className = 'msg err'; msg.textContent = 'login failed'; return; }
      }
      const me = await api.get('/api/v1/auth/me'); S.user = me.data; await loadModels(); enterWorkspace();
    } else { msg.className = 'msg err'; msg.textContent = r.data.err || ('error ' + r.status); }
  };
  el('li-login').onclick = () => go('/api/v1/auth/login');
  { const reg = el('li-register'); if (reg) reg.onclick = () => go('/api/v1/auth/register'); } // absent in closed beta
  // Enter submits — bind to the login box (a child of #app), so it's removed with the form on enterWorkspace()
  // rather than lingering on #app and firing go() (against now-missing inputs) on every Enter in the workspace.
  el('app').querySelector('.login').addEventListener('keydown', e => { if (e.key === 'Enter') go('/api/v1/auth/login'); });
}

// ===================================================================== workspace
function enterWorkspace() {
  document.body.classList.add('in-app');
  el('app').innerHTML = `
    <div class="tabline">
      <span class="brand"><span class="n">neuron</span><span class="l">-loops</span></span>
      <span class="tab tab-screen active" data-screen="workspace" id="tab-workspace">workspace</span>
      <span class="tab tab-screen" data-screen="api" id="tab-api">⚿ api</span>
      ${S.user.admin ? '<span class="tab tab-screen" data-screen="admin" id="tab-admin">⚙ admin</span>' : ''}
      <span class="tab tab-btn" id="btn-deploy">+ deploy</span>
      <span class="spacer"></span>
      <span class="user">${esc(S.user.email)}</span>
      <span class="plan ${S.user.plan === 'free' ? 'plan-up' : ''}" id="plan-badge">[${esc(S.user.plan)}]${S.user.plan === 'free' ? ' ↑' : ''}</span>
    </div>
    <div class="stage" id="stage">
    <div class="work" id="screen-workspace">
      <div class="explorer" id="explorer"></div>
      <div class="mainstage">
        <div class="viewtabs">
          <span class="vtab active" data-view="live" id="vt-live">◧ live</span>
          <span class="vtab" data-view="build" id="vt-build">⛭ build</span>
          <span class="vtab" data-view="growth" id="vt-growth">🌱 growth</span>
          <span class="vt-status" id="vt-status"></span>
        </div>
        <div class="ckpt-banner" id="ckpt-banner" style="display:none"></div>
        <div class="panes" id="panes">
          <div class="pane p-tick" data-pane="tick"><div class="winbar"><span class="dot" id="dot-tick"></span> minds — thinking</div><div class="pane-body" id="body-tick"></div></div>
          <div class="pane p-chat" data-pane="chat"><div class="winbar"><span class="dot"></span> swarm chat — minds talking</div><div class="pane-body" id="body-chat" style="flex:1;min-height:0"></div><div class="chatbar"><input id="chatinput" placeholder="message the swarm…" spellcheck="false" autocomplete="off"><button id="chatsend">send</button></div><div class="winbar" style="border-top:1px solid rgba(255,255,255,.08)"><span class="dot" style="background:#d9b04a;box-shadow:0 0 6px #d9b04a"></span> the veil — your direct line to the consciousness</div><div class="pane-body" id="body-veil" style="flex:1;min-height:0"></div><div class="chatbar"><input id="veilinput" placeholder="instruct the veil…" spellcheck="false" autocomplete="off"><button id="veilsend">send</button></div></div>
          <div class="pane p-loop" data-pane="loop"><div class="winbar"><span class="dot" id="dot-loop"></span> loop console</div><div class="pane-body" id="body-loop"></div></div>
        </div>
        <div class="buildview" id="buildview" style="display:none">
          <div class="filetree" id="filetree"></div>
          <div class="fileview">
            <div class="winbar">
              <span id="fv-name">— select a file —</span>
              <span class="fv-actions">
                <span class="fv-btn fv-tab active" id="fv-code">code</span>
                <span class="fv-btn fv-tab" id="fv-preview">▶ live</span>
                <span class="fv-sep"></span>
                <span class="fv-btn" id="fv-add">+ file</span>
                <span class="fv-btn" id="fv-save">save</span>
                <span class="fv-btn" id="fv-dl">↓ export</span>
                <span class="fv-btn fv-deploy" id="fv-deploy">☁ deploy</span>
              </span>
            </div>
            <textarea class="filecontent" id="fv-body" spellcheck="false" placeholder="select a file to view + edit · ‘+ file’ to add your own · ‘save’ writes it back · ‘▶ live’ renders the built site as the minds build it"></textarea>
            <iframe class="filepreview" id="fv-frame" style="display:none" sandbox="allow-scripts" title="live preview of what the swarm is building"></iframe>
          </div>
        </div>
        <div class="growthview" id="growthview" style="display:none"></div>
      </div>
    </div>
      <div class="screen" id="screen-api" style="display:none"></div>
      ${S.user.admin ? '<div class="screen" id="screen-admin" style="display:none"></div>' : ''}
    </div>
    <div class="cmdarea">
      <div class="statusline">
        <span class="mode ${S.mode}" id="sl-mode">${S.mode}</span>
        <span class="seg swarm" id="sl-swarm">no swarm</span>
        <span class="seg flash" id="sl-flash"></span>
        <span class="spacer"></span>
        <span class="seg" id="sl-live">0 live minds / 5</span>
        <span class="seg pos" id="sl-pos">${esc(S.user.email)}</span>
      </div>
      <div class="cmdline">
        <span class="prompt" id="cl-prompt">:</span>
        <input id="cmdinput" spellcheck="false" autocomplete="off" placeholder="press : for a command — try :help">
      </div>
    </div>`;
  document.querySelectorAll('.pane').forEach(p => p.onclick = () => setFocus(p.dataset.pane));
  el('btn-deploy').onclick = openWizard;
  document.querySelectorAll('.tab-screen').forEach(t => t.onclick = () => setScreen(t.dataset.screen));
  if (el('plan-badge')) el('plan-badge').onclick = () => { if (S.user.plan === 'free') showUpgradeNudge(); };
  document.querySelectorAll('.vtab').forEach(t => t.onclick = () => setView(t.dataset.view));
  const sendChat = async () => {
    const v = el('chatinput').value.trim(); if (!v) return flash('type a message first', 'err');
    if (!S.sel) { if (S.swarms && S.swarms.length) selectSwarm(S.swarms[0].id); else return flash('deploy or select a swarm first', 'err'); }
    el('chatinput').value = '';
    // optimistic echo: show YOUR message instantly (the swarm only drains control at the next round, so
    // without this it looks like nothing happened for ~30s)
    const st = S.ev[S.sel] || (S.ev[S.sel] = { offset: 0, lines: [] });
    st.lines.push({ kind: 'mind_msg', frm: 'you', to: 'all', text: v });
    if (S.view === 'live') renderPanes();
    await api.post(`/api/v1/swarms/${S.sel}/control`, { op: 'say', to: 'all', text: v });
    flash('sent — the swarm reads it next round', 'ok');
  };
  el('chatsend').onclick = sendChat;
  el('chatinput').addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') { e.preventDefault(); sendChat(); } });
  // THE VEIL — a direct line to the unified consciousness (op:"veil"), distinct from the swarm broadcast above.
  const sendVeil = async () => {
    const v = el('veilinput').value.trim(); if (!v) return flash('type an instruction first', 'err');
    if (!S.sel) { if (S.swarms && S.swarms.length) selectSwarm(S.swarms[0].id); else return flash('deploy or select a swarm first', 'err'); }
    el('veilinput').value = '';
    const st = S.ev[S.sel] || (S.ev[S.sel] = { offset: 0, lines: [] });
    st.lines.push({ kind: 'veil_msg', frm: 'user', text: v }); // optimistic echo (the veil replies next round)
    if (S.view === 'live') renderPanes();
    await api.post(`/api/v1/swarms/${S.sel}/control`, { op: 'veil', text: v });
    flash('the veil hears you — it replies next round', 'ok');
  };
  el('veilsend').onclick = sendVeil;
  el('veilinput').addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') { e.preventDefault(); sendVeil(); } });
  el('fv-add').onclick = addBuildFile;
  el('fv-save').onclick = saveBuildFile;
  el('fv-dl').onclick = downloadBuildFile;
  el('fv-code').onclick = () => setBuildMode('code');
  el('fv-preview').onclick = () => setBuildMode('preview');
  el('fv-deploy').onclick = deployToCloudflare;
  el('fv-body').addEventListener('keydown', e => e.stopPropagation());  // don't fire global keys while editing
  setupKeys();
  refreshSwarms();
  startPoll();
  flash('welcome — :deploy <name> to launch a mind, :help for commands', 'ok');
}

function setFocus(pane) {
  S.focus = pane;
  document.querySelectorAll('.pane').forEach(p => p.classList.toggle('focus', p.dataset.pane === pane));
}
function setMode(m) { S.mode = m; const e = el('sl-mode'); if (e) { e.textContent = m; e.className = 'mode ' + m; } }
function flash(msg, cls = '') { S.flash = { msg, cls }; const e = el('sl-flash'); if (e) { e.textContent = msg; e.className = 'seg flash ' + cls; } }

// ---- explorer ----
function renderExplorer() {
  const ex = el('explorer'); if (!ex) return;
  let h = `<div class="expl-h">swarms <span class="expl-cap">${S.swarms.filter(x => x.state === 'running' || x.state === 'starting').length}/3</span><span class="expl-add" id="expl-add">+ new</span></div>`;
  if (!S.swarms.length) h += '<div class="expl-empty">no swarms yet.<br>click <b>+ new</b> to deploy</div>';
  for (const s of S.swarms) {
    const running = s.state === 'running' || s.state === 'starting';
    h += `<div class="swarm-item ${s.id === S.sel ? 'sel' : ''}" data-id="${s.id}"><span class="si-name">▸ ${esc(s.name)}${s.encrypted ? ' 🔒' : ''}</span><span class="st ${s.state}">${s.state}</span><span class="si-actions">${running ? `<span class="si-act si-stop" data-stop="${s.id}" title="stop">■</span>` : ''}<span class="si-act si-del" data-del="${s.id}" title="delete">✕</span></span></div>`;
    if (s.id === S.sel) for (const m of (s._minds || []))
      h += `<div class="mind-item">· ${esc(m.name)}${m.lead ? ' <span class="lead">★lead</span>' : ''}</div>`;
  }
  ex.innerHTML = h;
  el('expl-add').onclick = openWizard;
  ex.querySelectorAll('.swarm-item').forEach(it => it.onclick = (e) => { if (!e.target.dataset.stop && !e.target.dataset.del) selectSwarm(it.dataset.id); });
  ex.querySelectorAll('[data-stop]').forEach(b => b.onclick = async (e) => { e.stopPropagation(); await api.post(`/api/v1/swarms/${b.dataset.stop}/control`, { op: 'stop' }); flash('stopping…', 'ok'); refreshSwarms(); });
  ex.querySelectorAll('[data-del]').forEach(b => b.onclick = async (e) => { e.stopPropagation(); if (b.dataset.del === S.sel) S.sel = null; await api.del(`/api/v1/swarms/${b.dataset.del}`); flash('deleted', 'ok'); refreshSwarms(); });
  const live = S.swarms.filter(s => s.state === 'running' || s.state === 'starting').reduce((a, s) => a + s.minds, 0);
  if (el('sl-live')) el('sl-live').textContent = `${live} live minds / 5`;
}

async function refreshSwarms() {
  const r = await api.get('/api/v1/swarms');
  if (r.status === 200) { S.swarms = r.data.swarms || []; if (!S.sel && S.swarms.length) selectSwarm(S.swarms[0].id, false); renderExplorer(); }
}
function selectSwarm(id, doRender = true) {
  S.sel = id;
  const s = S.swarms.find(x => x.id === id);
  if (el('sl-swarm')) el('sl-swarm').textContent = s ? `◆ ${s.name} · ${s.model}` : 'no swarm';
  connectStream(id);   // open the live SSE push for the newly selected swarm (poll is the fallback)
  if (doRender) { renderExplorer(); renderPanes(); }
}

// ---- event panes ----
const lineFor = (e, n) => {
  const ln = `<span class="ln">${n}</span>`;
  if (e.kind === 'round') return `<div class="ev round">${ln}<span class="body">── round ${e.round} ──</span></div>`;
  if (e.kind === 'board') return `<div class="ev board">${ln}<span class="body">board · ${e.done} done / ${e.open} open · ${e.files} files</span></div>`;
  if (e.kind === 'started') return `<div class="ev round">${ln}<span class="body">▶ started · ${e.minds ? e.minds.length : 0} minds · ${esc((e.goal || '').slice(0, 60))}</span></div>`;
  if (e.kind === 'stopped') return `<div class="ev err">${ln}<span class="body">■ stopped (${e.reason})</span></div>`;
  if (e.kind === 'mind_msg') return `<div class="ev"><span class="ln">${n}</span><span class="mind">${esc(e.frm)}→${esc(e.to)}</span><span class="body">${esc(e.text)}</span></div>`;
  if (e.kind === 'veil_msg') { const isU = e.frm === 'user' || e.frm === 'you'; return `<div class="ev veil-line"><span class="ln">${n}</span><span class="${isU ? 'you' : 'mind'}"${isU ? '' : ' style="color:#d9b04a"'}>${isU ? 'you' : '🜂 veil'}</span><span class="body">${esc(e.text)}</span></div>`; }
  if (e.kind === 'control') return `<div class="ev"><span class="ln">${n}</span><span class="you">you</span><span class="body">↪ steered (${e.applied})</span></div>`;
  if (e.kind === 'checkpoint') return `<div class="ev ckpt"><span class="ln">${n}</span><span class="body">⏸ checkpoint @r${e.round} — ${esc((e.summary || '').slice(0, 120))} · awaiting direction</span></div>`;
  if (e.kind === 'research') return `<div class="ev research"><span class="ln">${n}</span><span class="mind">${esc(e.mind || 'mind')} · parked</span><span class="body">🔬 ${esc((e.proposal || '').slice(0, 200))}</span></div>`;
  if (e.kind === 'resumed') return `<div class="ev resumed"><span class="ln">${n}</span><span class="body">▶ resumed → ${esc((e.goal || '').slice(0, 100))}</span></div>`;
  if (e.kind === 'act') {
    if (e.tool === 'thinking') return `<div class="ev act"><span class="ln">${n}</span><span class="mind">${esc(e.mind)}</span><span class="body">… thinking</span></div>`;
    const ai = (e.args || '').replace(/[{}"]/g, '').slice(0, 70);
    const ro = (e.result || '').replace(/\s+/g, ' ').slice(0, 80);
    return `<div class="ev act"><span class="ln">${n}</span><span class="mind">${esc(e.mind)}</span><span class="body">⚙ ${esc(e.tool)}${ai ? ' ' + esc(ai) : ''}${ro ? ' → ' + esc(ro) : ''}</span></div>`;
  }
  if (e.kind === 'heartbeat') return '';   // liveness only — don't clutter the feed
  if (e.kind === 'tick') {
    if (e.error) return `<div class="ev tick err">${ln}<span class="mind">${esc(e.mind)}</span><span class="body err">${esc(e.error)}</span></div>`;
    const seq = (e.trace || []).join(' › ');
    const facts = (e.stored || []).map(f => `<div class="tk-fact">＋ ${esc(f)}</div>`).join('');
    const finding = e.finding ? `<div class="tk-find">⌥ ${esc(e.finding.slice(0, 220))}</div>` : '';
    const stance = e.stance ? `<span class="tk-stance">♥ ${esc(e.stance)}</span>` : '';
    return `<div class="ev tk">${ln}<div class="tk-main"><div class="tk-head"><span class="mind">${esc(e.mind)}</span><span class="tk-dt">${e.dt}s · r${e.round}</span>${e.built ? '<span class="you">+built</span>' : ''}${stance}</div>${e.monologue ? `<div class="tk-mono">${esc(e.monologue)}</div>` : ''}${seq ? `<div class="tk-seq">${esc(seq)}</div>` : ''}${facts}${finding}</div></div>`;
  }
  return `<div class="ev">${ln}<span class="body">${esc(JSON.stringify(e))}</span></div>`;
};

function renderPanes() {
  const data = (S.sel && S.ev[S.sel]) ? S.ev[S.sel].lines : [];
  const CAP = 60;   // re-render only the live TAIL: rebuilding innerHTML for the whole 2000-line log every poll
                    // freezes the renderer on rich paid-model events (long monologues/traces). The tail is enough.
  const fill = (id, arr, dot) => {
    const b = el(id); if (!b) return;
    const tail = arr.length > CAP ? arr.slice(-CAP) : arr;
    const base = arr.length - tail.length;
    if (!tail.length) { b.innerHTML = '<div class="tilde">~</div>'.repeat(3); }
    else { b.innerHTML = tail.map((e, i) => lineFor(e, base + i + 1)).join(''); b.scrollTop = b.scrollHeight; }
    if (dot) { const d = el(dot); if (d) d.classList.toggle('live', isLive()); }
  };
  fill('body-tick', data.filter(e => e.kind === 'tick'), 'dot-tick');
  fill('body-chat', data.filter(e => e.kind === 'mind_msg'), null);
  fill('body-veil', data.filter(e => e.kind === 'veil_msg'), null);
  fill('body-loop', data, 'dot-loop');
}
function isLive() { const s = S.swarms.find(x => x.id === S.sel); return s && (s.state === 'running' || s.state === 'starting'); }

// the human-in-the-loop banner: when a checkpoint-mode swarm parks at a milestone, show its summary +
// what it researched while parked + clickable directions. Picking one (or typing your own) sends set_goal
// and the swarm resumes. Only rebuilds when the checkpoint changes, so it never clobbers your typing.
function renderCheckpointBanner() {
  const b = el('ckpt-banner'); if (!b) return;
  const data = (S.sel && S.ev[S.sel]) ? S.ev[S.sel].lines : [];
  let cp = null, resolved = false;
  for (const e of data) {
    if (e.kind === 'checkpoint') { cp = e; resolved = false; }
    else if (cp && (e.kind === 'resumed' || e.kind === 'stopped')) resolved = true;
  }
  if (!cp || resolved) { if (b.style.display !== 'none') { b.style.display = 'none'; b.innerHTML = ''; b.dataset.cp = ''; } return; }
  if (b.dataset.cp === String(cp.round)) return;   // already showing this checkpoint — don't clobber the input
  const props = data.filter(e => e.kind === 'research').slice(-3)
    .map(e => `<div class="ckpt-prop">🔬 ${esc((e.proposal || '').slice(0, 160))}</div>`).join('');
  const dirs = (cp.directions || []).map(d => `<button class="ckpt-dir" data-dir="${esc(d)}">${esc(d)}</button>`).join('');
  const nm = (S.swarms.find(s => s.id === S.sel) || {}).name || 'this swarm';
  b.dataset.cp = String(cp.round); b.style.display = '';
  b.innerHTML = `<div class="ckpt-h">⏸ <b>${esc(nm)}</b> hit a milestone — pick a direction to continue</div>
    <div class="ckpt-sum">${esc(cp.summary || '')}</div>
    ${props ? `<div class="ckpt-props"><span class="ckpt-k">researched while parked:</span>${props}</div>` : ''}
    <div class="ckpt-dirs">${dirs}</div>
    <div class="ckpt-custom"><input id="ckpt-input" placeholder="…or type your own direction" spellcheck="false" autocomplete="off"><button id="ckpt-send">send →</button></div>`;
  const resume = (g) => { g = (g || '').trim(); if (!g) return; api.post(`/api/v1/swarms/${S.sel}/control`, { op: 'set_goal', goal: g }); flash('direction sent — resuming', 'ok'); b.style.display = 'none'; b.dataset.cp = ''; };
  b.querySelectorAll('[data-dir]').forEach(btn => btn.onclick = () => resume(btn.dataset.dir));
  el('ckpt-send').onclick = () => resume(el('ckpt-input').value);
  el('ckpt-input').addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') resume(el('ckpt-input').value); });
}

// ---- live events: Server-Sent Events push (primary) + HTTP tail (fallback/replay) ----
// Events stream from GET /swarms/:id/stream over SSE. The 1s poll below stays as a fallback while SSE is
// down (and to refresh the swarm roster, which isn't in the stream). Both feed ingestLine(), which dedups by
// the event's monotonic `seq`, so the two transports can never double-render the same event.
function ingestLine(st, t) {
  let e; try { e = JSON.parse(t); } catch (_) { return; }
  if (typeof e.seq === 'number') { if (e.seq <= (st.maxSeq || 0)) return; st.maxSeq = e.seq; }
  st.lines.push(e);
}
// Coalesce rapid event bursts into at most ~15fps of rendering. A busy swarm streams many events per second;
// re-rendering the panes/growth on EVERY event froze the whole UI (so even typing in chat did nothing). We
// always render with the latest accumulated lines, and the trailing event still schedules a final render.
let _renderQueued = false;
function afterEvents(st) {
  if (st.lines.length > 2000) st.lines = st.lines.slice(-2000);
  if (_renderQueued) return;
  _renderQueued = true;
  setTimeout(() => {
    _renderQueued = false;
    if (S.view === 'build') { renderBuild(); if (S.buildMode === 'preview') loadPreview(false); }
    else if (S.view === 'growth') renderGrowth(); else renderPanes();
    renderCheckpointBanner();   // surface a parked checkpoint (any view) so you can steer it
    updateStatus();
  }, 66);
}
function connectStream(id) {
  closeStream();
  if (!id || typeof EventSource === 'undefined') return;   // unsupported → the poll fallback covers it
  const st = S.ev[id] || (S.ev[id] = { offset: 0, lines: [] });
  let es; try { es = new EventSource(`/api/v1/swarms/${id}/stream`); } catch (_) { return; }
  S.es = es; S.streamOk = false;
  es.onopen = () => { if (id === S.sel) S.streamOk = true; };
  es.onmessage = (e) => {
    if (id !== S.sel) return;                  // a stale stream (user switched swarms) — ignore
    const t = (e.data || '').trim(); if (!t) return;
    ingestLine(st, t);
    afterEvents(st);
  };
  es.addEventListener('gone', () => closeStream());   // swarm removed server-side
  es.onerror = () => { S.streamOk = false; };          // EventSource auto-reconnects; the poll covers the gap
}
function closeStream() {
  if (S.es) { try { S.es.close(); } catch (_) {} S.es = null; }
  S.streamOk = false;
}
function startPoll() {
  stopPoll();
  S.polling = true;
  const loop = async () => {
    if (!S.polling) return;
    try { await pollTick(); } catch (_) {}            // never let a slow poll wedge the loop
    if (S.polling) S.poll = setTimeout(loop, 1000);   // schedule the NEXT only after this one finishes (no pile-up)
  };
  loop();
}
function stopPoll() {
  S.polling = false;
  if (S.poll) { clearTimeout(S.poll); S.poll = null; }
  closeStream();
}
async function pollTick() {
  if (S.sel && !S.streamOk) {                          // SSE down/unsupported → pull the tail to stay current
    const st = S.ev[S.sel] || (S.ev[S.sel] = { offset: 0, lines: [] });
    const r = await api.text(`/api/v1/swarms/${S.sel}/events?from=${st.offset}`);
    if (r.status === 200 && r.text) {
      for (const ln of r.text.split('\n')) { const t = ln.trim(); if (t) ingestLine(st, t); }
      st.offset = r.next || st.offset;
      afterEvents(st);
    }
  }
  await refreshSwarms();
}

// ---- build view: see what the minds actually produce ----
function latestFiles(id) {
  const lines = (id && S.ev[id]) ? S.ev[id].lines : [];
  for (let i = lines.length - 1; i >= 0; i--) if (lines[i].kind === 'files') return lines[i];
  return null;
}
function updateStatus() {
  const s = el('vt-status'); if (!s) return;
  const ev = (S.sel && S.ev[S.sel]) ? S.ev[S.sel].lines : [];
  if (!ev.length) { s.innerHTML = '<span class="vs-idle">○ waiting for the swarm…</span>'; return; }
  let round = 0, ticks = 0, built = 0, stopped = false;
  for (const e of ev) {
    if (e.kind === 'round') round = Math.max(round, e.round || 0);
    else if (e.kind === 'tick') { ticks++; if (e.built) built++; }
    else if (e.kind === 'stopped') stopped = true;
  }
  const f = latestFiles(S.sel);
  const files = f ? (f.n || 0) : 0, kb = f ? Math.round((f.bytes || 0) / 1024) : 0;
  const live = !stopped && isLive();
  const dot = `<span class="vs-dot ${live ? 'on' : 'off'}"></span>`;
  s.innerHTML = `${dot}<span class="vs">r${round}</span><span class="vs">${ticks} ticks</span>` +
    `<span class="vs vs-built">${built} built</span><span class="vs">${files} files</span>` +
    `<span class="vs">${kb}KB</span>${stopped ? '<span class="vs vs-stop">stopped</span>' : ''}`;
}
// ---- top-level screen router (workspace | api | admin are full pages, not modals) ----
function setScreen(name) {
  if (name === 'admin' && !(S.user && S.user.admin)) { flash('admin only', 'err'); return; }
  S.screen = name;
  document.querySelectorAll('.tab-screen').forEach(t => t.classList.toggle('active', t.dataset.screen === name));
  const show = (id, on) => { const e = el(id); if (e) e.style.display = on ? '' : 'none'; };
  show('screen-workspace', name === 'workspace');
  show('screen-api', name === 'api');
  show('screen-admin', name === 'admin');
  if (name === 'api') renderApiScreen();
  else if (name === 'admin') renderAdminScreen();
}
function setView(v) {
  if (S.screen !== 'workspace') setScreen('workspace'); // a view tab/cmd implies the workspace screen
  S.view = v;
  document.querySelectorAll('.vtab').forEach(t => t.classList.toggle('active', t.dataset.view === v));
  el('panes').style.display = v === 'live' ? '' : 'none';
  el('buildview').style.display = v === 'build' ? 'flex' : 'none';
  el('growthview').style.display = v === 'growth' ? '' : 'none';
  if (v === 'build') { renderBuild(); setBuildMode(S.buildMode); } else if (v === 'growth') renderGrowth(); else renderPanes();
}
function renderBuild() {
  const tree = el('filetree'); if (!tree) return;
  const f = latestFiles(S.sel);
  const files = f ? (f.files || []) : [];
  if (!files.length) { tree.innerHTML = '<div class="ft-empty">no files yet.<br>this swarm is thinking,<br>not building — yet.</div>'; return; }
  tree.innerHTML = files.map(x =>
    `<div class="ft-item ${x.path === S.openFile ? 'sel' : ''}" data-path="${esc(x.path)}"><span class="ft-name">${esc(x.path)}</span><span class="ft-size">${fmtSize(x.size)}</span></div>`
  ).join('');
  tree.querySelectorAll('.ft-item').forEach(it => it.onclick = () => openBuildFile(it.dataset.path));
}
function fmtSize(n) { return n < 1024 ? n + 'b' : (n / 1024).toFixed(1) + 'k'; }
async function openBuildFile(path) {
  if (S.buildMode === 'preview') setBuildMode('code');  // opening a file = editing its source
  S.openFile = path;
  el('fv-name').textContent = path;
  const r = await api.text(`/api/v1/swarms/${S.sel}/file?path=${encodeURIComponent(path)}`);
  el('fv-body').value = r.status === 200 ? r.text : '(' + r.status + ' — could not read)';
  document.querySelectorAll('.ft-item').forEach(it => it.classList.toggle('sel', it.dataset.path === path));
}
async function saveBuildFile() {
  if (!S.sel || !S.openFile) return flash('open a file first', 'err');
  const r = await api.putRaw(`/api/v1/swarms/${S.sel}/file?path=${encodeURIComponent(S.openFile)}`, el('fv-body').value);
  flash(r.status === 200 ? 'saved ' + S.openFile : 'save failed: ' + (r.data.err || r.status), r.status === 200 ? 'ok' : 'err');
  if (r.status === 200) setTimeout(renderBuild, 300);
}
function downloadBuildFile() {
  if (!S.openFile) return flash('open a file first', 'err');
  const blob = new Blob([el('fv-body').value], { type: 'text/plain' });
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = S.openFile.split('/').pop();
  document.body.appendChild(a); a.click(); a.remove(); URL.revokeObjectURL(a.href);
}
async function addBuildFile() {
  if (!S.sel) return flash('select a swarm first', 'err');
  const path = prompt('new file path (e.g. src/util.js):'); if (!path) return;
  const r = await api.putRaw(`/api/v1/swarms/${S.sel}/file?path=${encodeURIComponent(path)}`, '');
  if (r.status === 200) { flash('added ' + path, 'ok'); setTimeout(() => { renderBuild(); openBuildFile(path); }, 350); }
  else flash('add failed: ' + (r.data.err || r.status), 'err');
}

// ---- live preview: render what the swarm is actually building, in real time ----
function setBuildMode(m) {
  S.buildMode = m;
  const code = el('fv-body'), frame = el('fv-frame');
  if (!code || !frame) return;
  if (el('fv-code')) el('fv-code').classList.toggle('active', m === 'code');
  if (el('fv-preview')) el('fv-preview').classList.toggle('active', m === 'preview');
  code.style.display = m === 'code' ? '' : 'none';
  frame.style.display = m === 'preview' ? '' : 'none';
  if (m === 'preview') loadPreview(true);
}
function loadPreview(force) {
  const frame = el('fv-frame'); if (!frame || !S.sel) return;
  const f = latestFiles(S.sel);
  const sig = f ? `${f.n}:${f.bytes}` : '0';
  if (!force && sig === S._previewSig) return;   // only reload the iframe when the build actually changed
  S._previewSig = sig;
  frame.src = `/api/v1/swarms/${S.sel}/site/index.html?t=${Date.now()}`;
}
async function deployToCloudflare() {
  if (!S.sel) return flash('select a swarm first', 'err');
  flash('preparing Cloudflare deploy…');
  const r = await api.post(`/api/v1/swarms/${S.sel}/deploy/cloudflare`, {});
  if (r.status === 200) showDeployModal(r.data);
  else flash('deploy: ' + (r.data.err || r.status), 'err');
}
function showDeployModal(d) {
  document.querySelectorAll('.helphud').forEach(x => x.remove());
  const ov = document.createElement('div'); ov.className = 'helphud';
  ov.innerHTML = `<div class="hh-panel">
    <div class="hh-h">☁ deploy to Cloudflare <span class="hh-x" id="dp-x">esc</span></div>
    <div class="dp-body">
      <p class="dp-line">${d.paid
        ? 'Your plan deploys this build to our Cloudflare account and returns a live URL — one click.'
        : 'On the free plan, export the build and run this with your own Cloudflare account to push it live on Cloudflare Pages:'}</p>
      <pre class="dp-cmd" id="dp-cmd">${esc(d.command || '')}</pre>
      <div class="dp-actions">
        <span class="fv-btn" id="dp-copy">copy command</span>
        ${d.paid ? '<span class="fv-btn fv-deploy" id="dp-go">deploy now ▸</span>'
                 : '<span class="dp-note">project: <b>' + esc(d.project || '') + '</b> · upgrade for one-click deploy</span>'}
      </div>
    </div></div>`;
  document.body.appendChild(ov);
  ov.onclick = e => { if (e.target === ov || e.target.id === 'dp-x') ov.remove(); };
  el('dp-copy').onclick = () => { (navigator.clipboard ? navigator.clipboard.writeText(d.command || '') : 0); flash('command copied', 'ok'); };
  const go = el('dp-go'); if (go) go.onclick = () => flash('paid auto-deploy seam — wiring to the platform CF account is the terraform phase', 'ok');
}

// ---- admin: full-page console (users + plans/neurons + all swarms). Owner only. ----
function admUserRow(x) {
  const plans = ['free', 'pro', 'max'];
  const opts = plans.map(p => `<option value="${p}"${p === x.plan ? ' selected' : ''}>${p}</option>`).join('');
  const isOwner = x.id === 1;
  return `<div class="adm-row" data-email="${esc(x.email)}">
    <span class="adm-email">${esc(x.email)}${isOwner ? ' <span class="adm-tag">admin</span>' : ''}${x.banned ? ' <span class="ad-banned">banned</span>' : ''}</span>
    <span class="adm-stats">id ${x.id} · ${x.live_minds} live · ${x.swarms} swarms</span>
    <select class="adm-plan" data-mail="${esc(x.email)}" title="set plan">${opts}</select>
    <span class="adm-topup"><input class="adm-neurons" data-mail="${esc(x.email)}" type="number" min="0" step="100000" placeholder="+ neurons" autocomplete="off"><span class="fv-btn adm-grant" data-mail="${esc(x.email)}">grant</span></span>
    ${isOwner ? '<span class="adm-acts"></span>' : `<span class="adm-acts"><span class="ad-act ad-ban" data-mod="${x.banned ? 'unban' : 'ban'}" data-mail="${esc(x.email)}">${x.banned ? 'unban' : 'ban'}</span><span class="ad-act ad-del" data-mod="delete" data-mail="${esc(x.email)}">delete</span></span>`}
  </div>`;
}
function renderAdminScreen() {
  const host = el('screen-admin'); if (!host) return;
  host.innerHTML = `<div class="scr">
    <div class="scr-head"><div>
      <h1 class="scr-title">⚙ admin</h1>
      <p class="scr-sub">Manage users, plans, and neuron grants; oversee every running swarm.</p>
    </div><div class="adm-kpis" id="adm-kpis"></div></div>
    <div class="card">
      <div class="card-h">users <span class="card-meta" id="adm-ucount">·</span><input id="adm-search" class="scr-search" placeholder="filter by email…" autocomplete="off"></div>
      <div class="adm-users" id="adm-users"><div class="ad-empty">loading…</div></div>
    </div>
    <div class="card">
      <div class="card-h">all swarms <span class="card-meta" id="adm-scount">·</span></div>
      <div class="adm-swarms" id="adm-swarms"><div class="ad-empty">loading…</div></div>
    </div>
  </div>`;
  const load = async () => {
    const [u, s] = await Promise.all([api.get('/api/v1/admin/users'), api.get('/api/v1/admin/swarms')]);
    if (u.status !== 200) { flash('admin only', 'err'); setScreen('workspace'); return; }
    const users = u.data.users || [], swarms = s.data.swarms || [];
    const liveMinds = users.reduce((a, x) => a + (x.live_minds || 0), 0);
    el('adm-kpis').innerHTML = `<span class="kpi"><b>${users.length}</b>users</span><span class="kpi"><b>${swarms.length}</b>swarms</span><span class="kpi"><b>${liveMinds}</b>live minds</span>`;
    el('adm-ucount').textContent = users.length; el('adm-scount').textContent = swarms.length;
    el('adm-users').innerHTML = users.map(admUserRow).join('') || '<div class="ad-empty">no users</div>';
    el('adm-swarms').innerHTML = swarms.length ? swarms.map(x => `<div class="adm-srow"><span class="adm-email">▸ ${esc(x.name)}${x.encrypted ? ' 🔒' : ''}</span><span class="adm-stats">u${x.uid} · ${esc(x.model)} · ${x.minds} minds · <span class="st ${esc(x.state)}">${esc(x.state)}</span></span><span class="ad-kill" data-kill="${esc(x.id)}">kill ✕</span></div>`).join('') : '<div class="ad-empty">no swarms running</div>';
    bind();
  };
  const bind = () => {
    const search = el('adm-search');
    search.onkeydown = e => e.stopPropagation();
    search.oninput = () => { const q = search.value.toLowerCase(); host.querySelectorAll('#adm-users .adm-row').forEach(r => { r.style.display = (r.dataset.email || '').toLowerCase().includes(q) ? '' : 'none'; }); };
    host.querySelectorAll('.adm-plan').forEach(elx => elx.onchange = async () => {
      const r = await api.post('/api/v1/admin/billing', { email: elx.dataset.mail, plan: elx.value });
      flash(r.status === 200 ? `${elx.dataset.mail} → ${elx.value}` : 'failed', r.status === 200 ? 'ok' : 'err'); load();
    });
    host.querySelectorAll('.adm-neurons').forEach(elx => elx.onkeydown = e => { e.stopPropagation(); if (e.key === 'Enter') host.querySelector(`.adm-grant[data-mail="${CSS.escape(elx.dataset.mail)}"]`).click(); });
    host.querySelectorAll('.adm-grant').forEach(elx => elx.onclick = async () => {
      const inp = host.querySelector(`.adm-neurons[data-mail="${CSS.escape(elx.dataset.mail)}"]`);
      const topup = parseInt(inp.value, 10) || 0;
      if (topup <= 0) return flash('enter a neuron amount to grant', 'err');
      const r = await api.post('/api/v1/admin/billing', { email: elx.dataset.mail, topup });
      const okGrant = r.status === 200 && r.data.topup_applied;
      flash(okGrant ? `+${topup.toLocaleString()} neurons → ${elx.dataset.mail}` : (r.data.note || 'grant failed'), okGrant ? 'ok' : 'err');
      if (okGrant) inp.value = '';
    });
    host.querySelectorAll('.ad-act').forEach(elx => elx.onclick = async () => {
      const action = elx.dataset.mod, email = elx.dataset.mail;
      if (action === 'delete' && !confirm(`Delete ${email}? This removes their account + ends their sessions.`)) return;
      const r = await api.post('/api/v1/admin/users/moderate', { email, action });
      flash(r.status === 200 ? `${email}: ${action}` : `failed: ${r.data.err || r.status}`, r.status === 200 ? 'ok' : 'err'); load();
    });
    host.querySelectorAll('.ad-kill').forEach(elx => elx.onclick = async () => {
      if (!confirm('Kill + wipe this swarm?')) return;
      await api.del(`/api/v1/admin/swarms/${elx.dataset.kill}`); flash('killed + wiped', 'ok'); refreshSwarms(); load();
    });
  };
  load();
}
async function showUpgradeNudge() {
  const r = await api.post('/api/v1/billing/checkout', {});
  const d = r.data || {}, up = d.upgrade || {};
  const ent = S.user.entitlements || { max_swarms: 1, max_minds: 3 };
  document.querySelectorAll('.helphud').forEach(x => x.remove());
  const ov = document.createElement('div'); ov.className = 'helphud';
  ov.innerHTML = `<div class="hh-panel">
    <div class="hh-h">↑ upgrade to Pro <span class="hh-x" id="up-x">esc</span></div>
    <div class="dp-body">
      <p class="dp-line">You're on <b>${esc(d.plan || 'free')}</b>. <b>Pro</b> — $${up.price_usd || 15}/mo — unlocks:</p>
      <div class="up-grid">
        <div>▸ up to <b>${up.max_swarms || 3}</b> concurrent swarms <span class="up-now">(now ${ent.max_swarms})</span></div>
        <div>▸ up to <b>${up.max_minds || 5}</b> live minds <span class="up-now">(now ${ent.max_minds})</span></div>
        <div>▸ <b>Cloudflare Workers AI</b> inference — no API key needed</div>
        <div>▸ one-click <b>deploy to Cloudflare</b></div>
      </div>
      <p class="dp-note">${esc(d.note || '')}</p>
      <div class="dp-actions"><span class="fv-btn fv-deploy" id="up-go">${d.status === 'coming_soon' ? 'billing launches with Cloudflare ▸' : 'upgrade ▸'}</span></div>
    </div></div>`;
  document.body.appendChild(ov);
  ov.onclick = e => { if (e.target === ov || e.target.id === 'up-x' || e.target.id === 'up-go') ov.remove(); };
}

// ---- API access: full-page screen — manage programmatic keys (nlk_…) + a complete endpoint reference ----
function akRow(k) {
  const when = k.created ? new Date(k.created * 1000).toISOString().slice(0, 10) : '—';
  return `<div class="ak-keyrow"><span class="ak-keyname">⚿ ${esc(k.name || 'key')}</span><code class="ak-keypfx">${esc(k.prefix || '')}</code><span class="ak-keywhen">${when}</span><span class="ak-revoke" data-id="${esc(k.id)}">revoke</span></div>`;
}
// the canonical API reference, grouped — rendered into the docs column (and the single source for the copy curls)
function apiReference(base) {
  const A = 'Authorization: Bearer nlk_…';
  const groups = [
    { name: 'Quick start — one call births a hive', note: `Send a goal, get back a swarm id and the URLs to stream its work + pull its files. The <code>nl</code> CLI (in <code>cli/</code>) wraps this: <code>nl run "build a CLI todo app" --out ./todo</code> births the hive and mirrors files into your dir live.`, eps: [
      { m: 'POST', p: '/api/v1/run', d: 'The one-call entrypoint. Minimal body <code>{"goal":"…"}</code> (everything else optional: <code>model, provider, minds, minutes, style, stack, mode</code>; defaults to the Workers-AI backbone + a lead-led team). Returns <code>{id, stream_url, events_url, files_url, bundle_url, archive_url, control_url}</code> — <b>or</b> send <code>Accept: text/event-stream</code> to birth + stream the work in the SAME request (the first <code>started</code> frame carries the id).', curl: `# births, returns the URL set:\ncurl -X POST ${base}/api/v1/run -H "${A}" \\\n  -H "content-type: application/json" \\\n  -d '{"goal":"Build a single-page site that says Hello."}'\n\n# one curl that births AND streams live:\ncurl -N -X POST ${base}/api/v1/run -H "${A}" \\\n  -H "content-type: application/json" -H "Accept: text/event-stream" \\\n  -d '{"goal":"Build a single-page site."}'` },
    ] },
    { name: 'Authentication', note: `Send your key on every request: <code>${esc(A)}</code>. The key inherits its owner's plan, neuron budget, and caps. A session cookie works too (that's what the web app uses).`, eps: [
      { m: 'GET', p: '/api/v1/auth/me', d: 'Verify a key and return the owner — plan, entitlements, and neuron balance.', curl: `curl -H "${A}" ${base}/api/v1/auth/me` },
      { m: 'POST', p: '/api/v1/auth/login', d: 'Exchange email + password for a session cookie (browser flow; API clients use a key instead).' },
      { m: 'POST', p: '/api/v1/auth/logout', d: 'Invalidate the current session cookie.' },
    ] },
    { name: 'API keys', note: 'Mint, list, and revoke programmatic keys. The raw key is shown once at creation — only its hash is stored.', eps: [
      { m: 'POST', p: '/api/v1/apikeys', d: 'Create a key. Body: <code>{"name":"ci-robot"}</code>. Returns the raw <code>nlk_…</code> once.', curl: `curl -X POST ${base}/api/v1/apikeys \\\n  -H "${A}" -H "content-type: application/json" \\\n  -d '{"name":"ci-robot"}'` },
      { m: 'GET', p: '/api/v1/apikeys', d: 'List your keys (name, display prefix, created) — never the raw key.', curl: `curl -H "${A}" ${base}/api/v1/apikeys` },
      { m: 'DELETE', p: '/api/v1/apikeys/:id', d: 'Revoke a key by id. Any client using it stops working immediately.', curl: `curl -X DELETE -H "${A}" ${base}/api/v1/apikeys/KEY_ID` },
    ] },
    { name: 'Swarms', note: 'Deploy a swarm of minds, preview the cost/caps, or list what you have running.', eps: [
      { m: 'POST', p: '/api/v1/swarms', d: 'Deploy a swarm. Returns its <code>id</code>.', curl: `curl -X POST ${base}/api/v1/swarms \\\n  -H "${A}" -H "content-type: application/json" \\\n  -d '{\n    "name": "api-swarm",\n    "provider": "workers-ai",\n    "model": "@cf/meta/llama-3.3-70b-instruct-fp8-fast",\n    "goal": "Write a one-page brief on X with a recommendation.",\n    "style": "build", "mode": "checkpoint", "minutes": 0,\n    "minds": [{"name":"nova","role":"Lead","lead":true,"duty":"build"}]\n  }'` },
      { m: 'POST', p: '/api/v1/swarms/resolve', d: 'Dry-run: resolve a deploy against your caps + neuron budget without launching.', curl: `curl -X POST ${base}/api/v1/swarms/resolve \\\n  -H "${A}" -H "content-type: application/json" \\\n  -d '{"provider":"workers-ai","model":"@cf/meta/llama-3.3-70b-instruct-fp8-fast","minds":[{"name":"nova"}]}'` },
      { m: 'GET', p: '/api/v1/swarms', d: 'List your swarms (id, name, model, minds, state).', curl: `curl -H "${A}" ${base}/api/v1/swarms` },
    ] },
    { name: 'Steer + stream', note: 'Watch a swarm think in real time and steer it mid-run. Events are an append-only NDJSON log addressed by byte offset.', eps: [
      { m: 'GET', p: '/api/v1/swarms/:id/events?from=N', d: 'Pull events from a byte offset (replay / polling). The <code>x-next-offset</code> response header is your next cursor — pass it back as <code>?from=</code>.', curl: `curl -H "${A}" "${base}/api/v1/swarms/SWARM_ID/events?from=0"` },
      { m: 'GET', p: '/api/v1/swarms/:id/stream', d: 'Server-Sent Events push — each NDJSON line arrives as a <code>data:</code> frame; <code>event: gone</code> on teardown.', curl: `curl -N -H "${A}" ${base}/api/v1/swarms/SWARM_ID/stream` },
      { m: 'POST', p: '/api/v1/swarms/:id/control', d: 'Steer the swarm. Body <code>{"op":"say","to":"all","text":"…"}</code> — ops: <code>say</code>, <code>broadcast</code>, <code>veil</code> (speak to the veil directly), <code>set_goal</code>, <code>stop</code>.', curl: `curl -X POST ${base}/api/v1/swarms/SWARM_ID/control \\\n  -H "${A}" -H "content-type: application/json" \\\n  -d '{"op":"set_goal","text":"Now focus on a landing page."}'` },
    ] },
    { name: 'Files + delete', note: "Receive the work: list the manifest, pull one file or the whole bundle, render the site, or tear it down.", eps: [
      { m: 'GET', p: '/api/v1/swarms/:id/files', d: 'The file manifest — <code>{files:[{path,size,hash}], n, bytes, state}</code> (the <code>hash</code> is a content hash, so a client catches same-size edits). Mirrors the SSE <code>files</code> event.', curl: `curl -H "${A}" ${base}/api/v1/swarms/SWARM_ID/files` },
      { m: 'GET', p: '/api/v1/swarms/:id/bundle', d: 'Every built file in one call — <code>{files:[{path,content}], n, truncated}</code> (text, ≤8MB total). The fastest way to grab the whole deliverable.', curl: `curl -H "${A}" ${base}/api/v1/swarms/SWARM_ID/bundle` },
      { m: 'GET', p: '/api/v1/swarms/:id/archive', d: 'Every built file as a real (ustar) <b>tar</b> — binary-safe (images + any asset intact), unlike the text bundle. Pipe straight into tar.', curl: `curl -H "${A}" ${base}/api/v1/swarms/SWARM_ID/archive | tar -x -C ./out` },
      { m: 'GET', p: '/api/v1/swarms/:id/file?path=…', d: 'Read one built file (used by <code>nl</code> to mirror changed files live as they appear in the stream).', curl: `curl -H "${A}" "${base}/api/v1/swarms/SWARM_ID/file?path=index.html"` },
      { m: 'PUT', p: '/api/v1/swarms/:id/file?path=…', d: 'Write/overwrite one file (raw body, ≤4MB).', curl: `curl -X PUT --data-binary @local.html -H "${A}" "${base}/api/v1/swarms/SWARM_ID/file?path=index.html"` },
      { m: 'GET', p: '/api/v1/swarms/:id/site/*', d: 'Render the built site live (real content-types) — point an iframe or browser at it.' },
      { m: 'DELETE', p: '/api/v1/swarms/:id', d: 'Stop + remove a swarm and wipe its run dir.', curl: `curl -X DELETE -H "${A}" ${base}/api/v1/swarms/SWARM_ID` },
    ] },
  ];
  const badge = m => `<span class="ep-m ep-${m.toLowerCase()}">${m}</span>`;
  return groups.map(g => `<div class="ref-group">
    <div class="ref-gh">${esc(g.name)}</div>
    ${g.note ? `<p class="ref-note">${g.note}</p>` : ''}
    ${g.eps.map(e => `<div class="ep">
      <div class="ep-sig">${badge(e.m)}<code class="ep-path">${esc(e.p)}</code></div>
      <div class="ep-d">${e.d}</div>
      ${e.curl ? `<div class="ep-curl"><pre class="ak-pre">${esc(e.curl)}</pre><span class="ak-cp fv-btn" data-cmd="${esc(e.curl)}">copy</span></div>` : ''}
    </div>`).join('')}
  </div>`).join('');
}
function renderApiScreen() {
  const host = el('screen-api'); if (!host) return;
  const base = location.origin;
  host.innerHTML = `<div class="scr">
    <div class="scr-head"><div>
      <h1 class="scr-title">⚿ API access</h1>
      <p class="scr-sub">Drive neuron-loops from your own code. Mint a key, then call any endpoint with <code>Authorization: Bearer nlk_…</code>.</p>
    </div></div>
    <div class="scr-grid api-grid">
      <section class="scr-col">
        <div class="card">
          <div class="card-h">your API keys <span class="card-meta" id="ak-count">·</span></div>
          <div class="ak-create-box">
            <input id="ak-name" placeholder="name this key (e.g. ci-robot)" autocomplete="off" maxlength="48">
            <button class="btn-primary ak-create-btn" id="ak-create">create key</button>
          </div>
          <div class="ak-shown" id="ak-shown" style="display:none"></div>
          <div class="ak-list" id="ak-list"><div class="ad-empty">loading…</div></div>
        </div>
        <div class="card ak-tip">🔒 Treat a key like a password. It carries your plan, neuron budget, and caps. We store only its hash — if you lose it, revoke it and mint a new one.</div>
      </section>
      <section class="scr-col scr-col-wide">
        <div class="card">
          <div class="card-h">API reference</div>
          <div class="ak-ref">${apiReference(base)}</div>
        </div>
      </section>
    </div>
  </div>`;
  const listEl = () => el('ak-list'), countEl = () => el('ak-count');
  const bindRows = () => host.querySelectorAll('.ak-revoke').forEach(elx => elx.onclick = async () => {
    if (!confirm('Revoke this key? Any client using it stops working immediately.')) return;
    const dr = await api.del('/api/v1/apikeys/' + encodeURIComponent(elx.dataset.id));
    flash(dr.status === 200 ? 'key revoked' : 'revoke failed', dr.status === 200 ? 'ok' : 'err'); load();
  });
  const load = async () => {
    const rr = await api.get('/api/v1/apikeys'); const ks = (rr.data && rr.data.keys) || [];
    listEl().innerHTML = ks.length ? ks.map(akRow).join('') : '<div class="ad-empty">no keys yet — create one to start using the API</div>';
    countEl().textContent = ks.length; bindRows();
  };
  el('ak-name').onkeydown = e => { e.stopPropagation(); if (e.key === 'Enter') el('ak-create').click(); };
  el('ak-create').onclick = async () => {
    const name = (el('ak-name').value || '').trim() || 'API key';
    const cr = await api.post('/api/v1/apikeys', { name });
    if (cr.status !== 201 || !cr.data.key) { flash('could not create key: ' + (cr.data.err || cr.status), 'err'); return; }
    const sh = el('ak-shown'); sh.style.display = 'block';
    sh.innerHTML = `<div class="ak-shown-h">⚠ copy this key now — it is shown only once and cannot be retrieved later</div>
      <div class="ak-shown-row"><code class="ak-key" id="ak-rawkey">${esc(cr.data.key)}</code><span class="fv-btn fv-deploy" id="ak-copy">copy</span></div>`;
    el('ak-copy').onclick = () => { if (navigator.clipboard) navigator.clipboard.writeText(cr.data.key); flash('key copied', 'ok'); };
    el('ak-name').value = ''; load();
  };
  host.querySelectorAll('.ak-cp').forEach(elx => elx.onclick = () => { if (navigator.clipboard) navigator.clipboard.writeText(elx.dataset.cmd); flash('copied', 'ok'); });
  load();
}

// ---- growth view: a live picture of memory forming inside the swarm ----
// Derived entirely from the retained line buffer (capped at 2000): it streams each fact/stance as it is BORN
// (from tick.stored + growth.stances + observe acts), tallies per-mind tool use from act/trace, and rolls the
// swarm up with a facts-per-round sparkline. No reliance on full history — the feed is a live tail.
function gvCleanArg(s) {
  try { const o = JSON.parse(s); return String(o.query || o.url || o.path || o.text || JSON.stringify(o)).slice(0, 96); }
  catch (_) { return String(s || '').replace(/[{}"]/g, '').slice(0, 96); }
}
function gvKpi(v, l, raw) { return `<div class="gv-kpi"><b>${raw ? v : esc(String(v))}</b><span>${esc(l)}</span></div>`; }
function gvStat(k, v) { return `<div class="gv-stat"><span class="gv-k">${k}</span><span class="gv-v">${esc(String(v))}</span></div>`; }
function gvSpark(series) {
  const w = 64, h = 16; if (!series.length) return `<svg width="${w}" height="${h}"></svg>`;
  const max = Math.max(1, ...series), n = series.length;
  const pts = series.map((v, i) => `${(n < 2 ? w : (i / (n - 1)) * w).toFixed(1)},${(h - (v / max) * (h - 2) - 1).toFixed(1)}`).join(' ');
  return `<svg width="${w}" height="${h}" class="gv-spark" viewBox="0 0 ${w} ${h}"><polyline points="${pts}" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>`;
}
function renderGrowth() {
  const g = el('growthview'); if (!g) return;
  const lines = (S.sel && S.ev[S.sel]) ? S.ev[S.sel].lines : [];
  const minds = {};
  const M = (n) => minds[n] || (minds[n] = { facts: 0, recalled: 0, age: 0, dt: 0, skills: 0, stances: new Set(), tools: {}, mono: '' });
  const born = [], series = [], factSeen = new Set(), stanceSeen = {};
  let started = null, board = null;
  for (const e of lines) {
    if (e.kind === 'started') { started = e; continue; }
    if (e.kind === 'board') { board = e; continue; }
    if (!e.mind) continue;
    const c = M(e.mind);
    if (e.kind === 'tick') {
      if (e.monologue) c.mono = e.monologue;
      if (e.dt != null) c.dt = e.dt;
      (e.stored || []).forEach(f => { if (f && !f.startsWith('(reached')) { const k = e.mind + '|' + f; if (!factSeen.has(k)) { factSeen.add(k); born.push({ mind: e.mind, kind: 'fact', text: f }); } } });
      let tr = []; try { tr = Array.isArray(e.trace) ? e.trace : JSON.parse(e.trace || '[]'); } catch (_) { }
      tr.forEach(t => { if (t && t !== 'recall') c.tools[t] = (c.tools[t] || 0) + 1; });
    } else if (e.kind === 'growth') {
      if (e.facts != null) c.facts = e.facts; if (e.recalled != null) c.recalled = e.recalled; if (e.age != null) c.age = e.age; if (e.skills != null) c.skills = e.skills;
      const ss = stanceSeen[e.mind] || (stanceSeen[e.mind] = new Set());
      (e.stances || []).forEach(s => { c.stances.add(s); if (!ss.has(s)) { ss.add(s); born.push({ mind: e.mind, kind: 'stance', text: s }); } });
      series.push(Object.values(minds).reduce((a, x) => a + (x.facts || 0), 0));
    } else if (e.kind === 'act') {
      if (e.tool === 'thinking' || e.tool === 'skills' || e.tool === 'build_state') continue; // context beacons, not tool calls
      if (e.tool === 'recall') { born.push({ mind: e.mind, kind: 'recall', text: gvCleanArg(e.args) }); continue; } // RAG context
      if (e.tool) c.tools[e.tool] = (c.tools[e.tool] || 0) + 1;
      if (e.tool === 'save_skill') born.push({ mind: e.mind, kind: 'skill', text: gvCleanArg(e.args) });
      if (e.tool === 'web_search') born.push({ mind: e.mind, kind: 'search', text: gvCleanArg(e.args) });
      else if (e.tool === 'read_url' || e.tool === 'web_fetch' || e.tool === 'fetch_json') born.push({ mind: e.mind, kind: 'read', text: gvCleanArg(e.args) });
      else if (e.tool === 'write_file') born.push({ mind: e.mind, kind: 'file', text: gvCleanArg(e.args) });
    }
  }
  const names = Object.keys(minds).sort();
  if (!names.length) { g.innerHTML = '<div class="gv-empty">no growth yet — deploy or select a running swarm and watch memories form in real time.</div>'; return; }

  const totalFacts = names.reduce((a, n) => a + minds[n].facts, 0);
  const totalSkills = Math.max(0, ...names.map(n => minds[n].skills || 0)); // skills are swarm-shared
  const allStances = new Set(); names.forEach(n => minds[n].stances.forEach(s => allStances.add(s)));
  const round = board ? board.round : Math.max(0, ...names.map(n => minds[n].age));
  const model = (started && started.model) || ((S.swarms.find(s => s.id === S.sel) || {}).model) || '';
  const swarmName = (started && started.swarm) || ((S.swarms.find(s => s.id === S.sel) || {}).name) || 'swarm';

  const rollup = `<div class="gv-roll">
    <div class="gv-roll-l"><span class="gv-dot ${isLive() ? 'live' : ''}"></span><b>${esc(swarmName)}</b><span class="gv-sub">${esc(model)} · round ${round}</span></div>
    <div class="gv-kpis">
      ${gvKpi(names.length, 'minds')}${gvKpi(totalFacts, 'facts')}${gvKpi(totalSkills, 'skills')}${gvKpi(allStances.size, 'stances')}
      ${gvKpi(board ? board.done : 0, 'tasks')}${gvKpi(board ? board.files : 0, 'files')}${gvKpi(gvSpark(series), 'facts/round', true)}
    </div></div>`;

  const ICON = { fact: '🧠', stance: '❤', search: '🔍', read: '📄', file: '📝', recall: '🧩', skill: '🛠' };
  const feed = born.length
    ? born.slice(-60).reverse().map(b => `<div class="gv-mem gv-mem-${b.kind}"><span class="gv-bm">${esc(b.mind)}</span><span class="gv-bi">${ICON[b.kind] || '·'}</span><span class="gv-bt">${esc(b.text)}</span></div>`).join('')
    : '<div class="gv-sub">no memories yet — minds are warming up…</div>';

  const cards = names.map(n => {
    const m = minds[n];
    const stage = m.facts === 0 ? 'born' : (m.facts < 8 ? 'learning' : 'growing');
    const tools = Object.entries(m.tools).sort((a, b) => b[1] - a[1]).slice(0, 6).map(([t, c]) => `<span class="gv-tool">${esc(t)}<i>${c}</i></span>`).join('');
    const st = [...m.stances].slice(-4).map(s => `<span class="gv-stance">${esc(s)}</span>`).join('');
    return `<div class="gv-card">
      <div class="gv-top"><span class="gv-name">${esc(n)}</span><span class="gv-stage gv-${stage}">${stage}</span></div>
      <div class="gv-bars">${gvStat('facts', m.facts)}${gvStat('skills', m.skills)}${gvStat('recalled', m.recalled)}${gvStat('age', m.age + 'r')}${gvStat('stances', m.stances.size)}</div>
      ${tools ? `<div class="gv-tools">${tools}</div>` : ''}
      ${m.mono ? `<div class="gv-mono">${esc(m.mono.slice(0, 160))}</div>` : ''}
      ${st ? `<div class="gv-stances">${st}</div>` : ''}
    </div>`;
  }).join('');

  g.innerHTML = rollup +
    `<div class="gv-grid">
      <div class="gv-col"><div class="gv-h">🌱 memories being born</div><div class="gv-feed">${feed}</div></div>
      <div class="gv-col"><div class="gv-h">minds · ${names.length}</div><div class="gv-cards">${cards}</div></div>
    </div>`;
}

// ---- mind rosters (from started events) ----
function indexRoster() {
  for (const s of S.swarms) {
    const ev = S.ev[s.id]; if (!ev) continue;
    const start = ev.lines.find(e => e.kind === 'started');
    if (start && start.minds) s._minds = start.minds;
  }
}

// ===================================================================== command line / keys
const COMMANDS = [
  ['deploy <name> [n]', 'quick-launch n mock minds (1–5)'],
  ['new', 'open the deploy wizard (model, key, timer)'],
  ['feed <text>', 'message the selected swarm (operator → minds)'],
  ['goal <text>', 'change the selected swarm\'s goal live'],
  ['stop', 'stop the selected swarm (clean)'],
  ['delete', 'delete the swarm + wipe all its data'],
  ['sel <n>', 'select swarm number n'],
  ['live | build | growth', 'switch the workspace view'],
  ['workspace | api | admin', 'switch the top-level screen'],
  ['open <path>', 'open a build file in the editor'],
  ['save', 'save the open build file back to the swarm'],
  ['files', 'show the build file count'],
  ['models', 'how many models are wired in'],
  ['api | keys', 'manage API keys + read the API reference'],
  ['upgrade', 'what Pro unlocks (plan + caps)'],
  ['admin', 'owner: manage users, plans, neurons + all swarms'],
  ['logout', 'sign out'],
  ['help', 'show this reference'],
];
function showHelpHUD() {
  const existing = document.querySelector('.helphud');
  if (existing) { existing.remove(); return; }
  const ov = document.createElement('div'); ov.className = 'helphud';
  ov.innerHTML = `<div class="hh-panel"><div class="hh-h">command reference — the ‘:’ console <span class="hh-x" id="hh-x">esc</span></div>
    <div class="hh-grid">${COMMANDS.map(([c, d]) => `<div class="hh-cmd">:${esc(c)}</div><div class="hh-desc">${esc(d)}</div>`).join('')}</div>
    <div class="hh-foot">keys: <b>:</b> command · <b>d</b> deploy · <b>t</b> cycle view · <b>j/k</b> select swarm · <b>r</b> refresh · <b>esc</b> close</div></div>`;
  document.body.appendChild(ov);
  ov.onclick = e => { if (e.target === ov || e.target.id === 'hh-x') ov.remove(); };
}

async function runCmd(raw) {
  const line = raw.trim(); if (!line) return;
  const [cmd, ...rest] = line.split(/\s+/); const arg = rest.join(' ');
  const needSel = () => { if (!S.sel) { flash('select a swarm first', 'err'); return false; } return true; };
  switch (cmd) {
    case 'help': case '?': showHelpHUD(); break;
    case 'new': openWizard(); break;
    case 'deploy': {
      const name = rest[0] || ('mind-' + Math.floor(Date.now() % 9999));
      const n = Math.max(1, Math.min(5, parseInt(rest[1] || '1', 10) || 1));
      const minds = Array.from({ length: n }, (_, i) => ({ name: ['nova', 'ada', 'rex', 'lux', 'sol'][i] || ('m' + i), role: i === 0 ? 'Lead' : 'Maker', lead: i === 0, duty: 'build' }));
      const r = await api.post('/api/v1/swarms', { name, provider: 'mock', model: 'mock', style: 'build', stack: 'static', goal: 'Build something real.', minds });
      if (r.status === 201) { flash(`deployed ${name} (${n} mind${n > 1 ? 's' : ''})`, 'ok'); await refreshSwarms(); selectSwarm(r.data.id); }
      else flash(r.data.err || ('deploy failed ' + r.status), 'err');
      break;
    }
    case 'feed': case 'say': if (!needSel()) break;
      await api.post(`/api/v1/swarms/${S.sel}/control`, { op: 'say', to: 'all', text: arg }); flash('sent: ' + arg, 'ok'); break;
    case 'veil': if (!needSel()) break;
      await api.post(`/api/v1/swarms/${S.sel}/control`, { op: 'veil', text: arg }); flash('instructed the veil: ' + arg, 'ok'); break;
    case 'goal': if (!needSel()) break;
      await api.post(`/api/v1/swarms/${S.sel}/control`, { op: 'set_goal', goal: arg }); flash('goal updated', 'ok'); break;
    case 'stop': if (!needSel()) break;
      await api.post(`/api/v1/swarms/${S.sel}/control`, { op: 'stop' }); flash('stopping…', 'ok'); refreshSwarms(); break;
    case 'delete': case 'rm': case 'del': if (!needSel()) break;
      { const id = S.sel; S.sel = null; await api.del(`/api/v1/swarms/${id}`); flash('deleted + wiped', 'ok'); refreshSwarms(); } break;
    case 'sel': { const i = parseInt(arg, 10) - 1; if (S.swarms[i]) selectSwarm(S.swarms[i].id); else flash('no swarm ' + arg, 'err'); break; }
    case 'live': case 'build': case 'growth': setView(cmd); break;
    case 'open': if (!needSel()) break; setView('build'); openBuildFile(arg); break;
    case 'save': saveBuildFile(); break;
    case 'files': { const f = latestFiles(S.sel); setView('build'); flash(f ? `${f.n} files · ${Math.round((f.bytes || 0) / 1024)}KB` : 'no files yet', 'ok'); break; }
    case 'models': flash(`${S.models ? S.models.models.length : 0} models wired · default free ${S.models?.defaults?.free_local || '—'}`, 'ok'); break;
    case 'upgrade': case 'plan': showUpgradeNudge(); break;
    case 'api': case 'keys': case 'apikeys': setScreen('api'); break;
    case 'workspace': case 'ws': setScreen('workspace'); break;
    case 'admin': setScreen('admin'); break;
    case 'logout': await api.post('/api/v1/auth/logout'); stopPoll(); S.user = null; renderLogin(); break;
    default: flash('not a command: ' + cmd + '  —  :help', 'err');
  }
}

function setupKeys() {
  const ci = el('cmdinput');
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { const h = document.querySelector('.helphud'); if (h) { h.remove(); e.preventDefault(); return; }
      if (S.screen !== 'workspace' && document.activeElement && !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) { setScreen('workspace'); e.preventDefault(); return; } }
    if (S.mode === 'COMMAND') {
      if (e.key === 'Escape') { ci.value = ''; ci.blur(); setMode('NORMAL'); e.preventDefault(); }
      else if (e.key === 'Enter') { const v = ci.value; ci.value = ''; ci.blur(); setMode('NORMAL'); runCmd(v); e.preventDefault(); }
      return;
    }
    // don't let vim-style global keys (j/k/d/t/r/:) hijack typing in ANY editable field (textarea/select too)
    const _t = e.target.tagName;
    if (_t === 'INPUT' || _t === 'TEXTAREA' || _t === 'SELECT' || e.target.isContentEditable) return;
    if (e.key === ':') { setMode('COMMAND'); ci.focus(); e.preventDefault(); }
    else if (S.screen !== 'workspace') { /* full-page screen: only :, d, esc are global — ignore vim view/select keys */ if (e.key === 'd') { openWizard(); e.preventDefault(); } }
    else if (e.key === 'j') moveSel(1);
    else if (e.key === 'k') moveSel(-1);
    else if (e.key === 'd') { openWizard(); e.preventDefault(); }
    else if (e.key === 't') setView(S.view === 'live' ? 'build' : S.view === 'build' ? 'growth' : 'live');
    else if (e.key === 'r') { refreshSwarms(); flash('refreshed'); }
    else if (e.ctrlKey && e.key === 'w') { S._cw = true; e.preventDefault(); }
    else if (S._cw) { const map = { h: 'tick', l: 'chat', j: 'loop', k: 'tick' }; if (map[e.key]) setFocus(map[e.key]); S._cw = false; }
  });
  ci.addEventListener('blur', () => { if (S.mode === 'COMMAND') setMode('NORMAL'); });
}
function moveSel(d) {
  if (!S.swarms.length) return;
  let i = S.swarms.findIndex(s => s.id === S.sel); i = Math.max(0, Math.min(S.swarms.length - 1, (i < 0 ? 0 : i) + d));
  selectSwarm(S.swarms[i].id);
}

// ===================================================================== clickable deploy wizard
function openWizard() {
  if (document.querySelector('.wizmodal')) return;
  const m = S.models || { providers: [], models: [], defaults: {} };
  const ent = S.user.entitlements || { per_swarm_minds: 5, encrypted: false };
  const maxMinds = ent.per_swarm_minds || 5;
  // Local models (Ollama / localhost) are an ADMIN-ONLY testing backend — a Cloudflare worker can't reach the operator's
  // local llama, so it's hidden from regular users (the backend also blocks it for non-admins as defense in depth).
  const isAdmin = !!(S.user && S.user.admin);
  const provs = m.providers.filter(p => isAdmin || (p.key !== 'ollama' && p.base_url !== 'local'));
  const cfReady = !!(S.user && S.user.workers_ai_available); // Workers AI only works when the OPERATOR set CF creds server-side
  const provOpts = provs.map(p => {
    const cfOff = (p.key === 'workers-ai' && !cfReady); // honest: don't offer the no-key backbone if this server can't serve it
    return `<option value="${p.key}"${cfOff ? ' disabled' : ''}>${esc(p.label)}${p.needs_key ? ' (key)' : ''}${cfOff ? ' — not configured on this server' : ''}</option>`;
  }).join('') || '<option value="mock">mock</option>';
  const ov = document.createElement('div');
  ov.className = 'wizmodal';
  ov.innerHTML = `<div class="wizard">
    <div class="wiz-h">deploy a swarm <span class="wiz-x" id="wz-x">esc</span></div>
    <label>name</label><input id="wz-name" value="swarm-${Math.floor(Date.now() % 9999)}" autocomplete="off">
    <div class="wiz-row">
      <div><label>provider</label><select id="wz-prov"><option value="mock">Mock (no model, free)</option>${provOpts}</select></div>
      <div><label>model</label><select id="wz-model"></select></div>
    </div>
    <div class="wiz-row" id="wz-keyrow" style="display:none">
      <div><label>API key — your own (BYOK, kept on the server, never logged)</label><input id="wz-key" type="password" placeholder="sk-…" autocomplete="off"></div>
    </div>
    <div class="wiz-row">
      <div><label>minds — max ${maxMinds}</label><input id="wz-n" type="number" min="1" max="${maxMinds}" value="3"></div>
      <div><label>style</label><select id="wz-style"><option value="build">build</option><option value="build_use">build + use</option><option value="investigate">investigate</option><option value="debate">debate</option></select></div>
      <div><label>run for (timer)</label><select id="wz-min"><option value="0">until stopped</option><option value="5">5 min</option><option value="15">15 min</option><option value="30">30 min</option><option value="60">1 hour</option></select></div>
    </div>
    <div class="wiz-row">
      <div><label>deliverable</label><select id="wz-kind">
        <option value="general">report / document</option>
        <option value="general">research / analysis</option>
        <option value="general">code / tool</option>
        <option value="general">data / dataset</option>
        <option value="static">website (static HTML/CSS/JS)</option>
        <option value="node">web app (node)</option>
      </select></div>
      <div><label>when done</label><select id="wz-mode">
        <option value="continuous">keep building until I stop it</option>
        <option value="checkpoint">build it, then ask me for direction</option>
        <option value="refine">keep refining the one result</option>
      </select></div>
    </div>
    <div class="wiz-row">
      <div><label>gateway model <span style="opacity:.6">(optional — cheap model for digests/classify; blank = use main model)</span></label><input id="wz-gateway" type="text" placeholder="e.g. gpt-4.1-nano — leave blank to bypass" spellcheck="false"></div>
      <div><label>living hive</label><label class="wiz-enc" style="margin-top:6px"><input type="checkbox" id="wz-pop"> 🌱 let the veil birth / retire minds as the work needs (bounded)</label></div>
    </div>
    <label>goal — describe the deliverable; the swarm produces whatever you ask</label><textarea id="wz-goal" rows="2" spellcheck="false">Research the best approaches to X and write a clear one-page brief with a recommendation.</textarea>
    ${ent.encrypted ? '<label class="wiz-enc"><input type="checkbox" id="wz-enc"> 🔒 encrypt mind memory — seal the BYOK key at rest (AES-256-GCM)</label>' : ''}
    <div class="wiz-note" id="wz-note"></div>
    <div class="wiz-actions"><button class="btn-ghost" id="wz-cancel">cancel</button><button class="btn-primary" id="wz-go">deploy ▸</button></div>
  </div>`;
  document.body.appendChild(ov);
  const close = () => ov.remove();
  const fillModels = () => {
    const prov = el('wz-prov').value;
    if (prov === 'mock') { el('wz-model').innerHTML = '<option value="mock">mock (deterministic)</option>'; }
    else {
      const ms = m.models.filter(x => x.provider === prov);
      el('wz-model').innerHTML = ms.map(x => `<option value="${esc(x.id)}">${esc(x.label)} · ${x.tools} tools · ${x.cost}</option>`).join('') || '<option value="">(no models)</option>';
      // default to a cheap + reliable tool-using model, not the pricey flagship (e.g. gpt-4.1-mini over gpt-5)
      const pick = ms.find(x => x.cost === 'low' && x.tools === 'reliable') || ms.find(x => x.tools === 'reliable') || ms[0];
      if (pick) el('wz-model').value = pick.id;
    }
    const p = m.providers.find(x => x.key === prov);
    el('wz-keyrow').style.display = (p && p.needs_key) ? '' : 'none';
    note();
  };
  const note = () => {
    const mm = m.models.find(x => x.id === el('wz-model').value);
    el('wz-note').textContent = mm ? mm.note : (el('wz-prov').value === 'mock' ? 'Mock minds run free + deterministic — great for testing the pipeline (no real thinking).' : '');
  };
  el('wz-prov').onchange = fillModels; el('wz-model').onchange = note;
  el('wz-x').onclick = close; el('wz-cancel').onclick = close;
  ov.addEventListener('keydown', e => { if (e.key === 'Escape') close(); });
  // Default to the Cloudflare Workers AI backbone ONLY when this server actually has it configured (operator CF creds);
  // otherwise leave the honest free default (Mock, the first option) selected so a self-hoster doesn't dead-end on a
  // "Workers AI is not configured on this server" error. Real work then comes from BYOK (add your own key).
  if (S.user && S.user.workers_ai_available && m.providers.some(p => p.key === 'workers-ai')) el('wz-prov').value = 'workers-ai';
  fillModels(); el('wz-name').focus();
  el('wz-go').onclick = async () => {
    const n = Math.max(1, Math.min(5, parseInt(el('wz-n').value, 10) || 1));
    const names = ['nova', 'ada', 'rex', 'lux', 'sol'];
    const minds = Array.from({ length: n }, (_, i) => ({ name: names[i] || ('m' + i), role: i === 0 ? 'Lead' : 'Maker', lead: i === 0, duty: 'build' }));
    const prov = el('wz-prov').value;
    const pr = m.providers.find(x => x.key === prov);
    let base_url = pr ? pr.base_url : '';
    if (base_url === 'local') base_url = 'http://localhost:11434/v1';
    const api_key = (prov !== 'mock' && el('wz-key')) ? el('wz-key').value : '';
    const minutes = parseInt(el('wz-min').value, 10) || 0;
    const encrypt = el('wz-enc') ? el('wz-enc').checked : false;
    const gateway_model = (el('wz-gateway') ? el('wz-gateway').value.trim() : ''); // cheap relay for mechanical calls; '' = bypass (main model)
    const veil_population = el('wz-pop') ? el('wz-pop').checked : false; // let the veil birth/retire sub-minds
    const body = { name: el('wz-name').value || 'swarm', provider: prov, model: el('wz-model').value || 'mock', style: el('wz-style').value, stack: (el('wz-kind') ? el('wz-kind').value : 'general'), mode: (el('wz-mode') ? el('wz-mode').value : 'continuous'), goal: el('wz-goal').value, api_key, base_url, minutes, encrypt, gateway_model, veil_population, minds };
    el('wz-go').textContent = 'deploying…'; el('wz-go').disabled = true;
    try {
      const r = await api.post('/api/v1/swarms', body);
      if (r.status === 201) {
        close(); flash(`deployed ${body.name} (${n} mind${n > 1 ? 's' : ''} · ${body.model})`, 'ok');
        await refreshSwarms(); selectSwarm(r.data.id); return;
      }
      el('wz-note').textContent = 'error: ' + (r.data.err || r.status);
      if (r.status === 429 && S.user.plan === 'free') setTimeout(showUpgradeNudge, 350);  // hit a plan cap
    } catch (e) {
      el('wz-note').textContent = 'deploy failed: ' + (e && e.message ? e.message : e);
    }
    // never leave the button stuck on "deploying…": always re-enable unless we closed on success
    el('wz-go').textContent = 'deploy ▸'; el('wz-go').disabled = false;
  };
}

// keep rosters fresh as events arrive
setInterval(indexRoster, 1200);
boot();
