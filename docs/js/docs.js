/* FILE NL-VEIL — document viewer + inventory.
   The contents sheet is built from the manifest below; every row and
   every board item opens the real markdown source from docs-src/,
   parsed by the home-built parser and typed onto bond paper. */
(function () {
  'use strict';

  /* ---------------- the contents of file ---------------- */
  const GROUPS = [
    { key: '', label: 'CASE SUMMARY', note: 'start here', docs: [
      { p: 'index', c: 'IX-00', t: 'Module index — the contents of the file', s: 'docs-src' },
      { p: 'main', c: 'MN-01', t: 'Entry point — subsystem init and the event loop', s: 'main.zig' }
    ]},
    { key: 'admin/', label: 'ADMIN — SYSTEM MANAGEMENT', docs: [
      { p: 'admin/admin_service', c: 'AD-01', t: 'Core admin service — API admin operations', s: 'admin_service.zig' }
    ]},
    { key: 'auth/', label: 'AUTH — WHO GOES THERE', docs: [
      { p: 'auth/api_keys', c: 'AU-01', t: 'API key management — creation, rotation, revocation', s: 'api_keys.zig' },
      { p: 'auth/auth_api', c: 'AU-02', t: 'Authentication HTTP API endpoints', s: 'auth_api.zig' },
      { p: 'auth/auth_core', c: 'AU-03', t: 'Core authentication — tokens, sessions, validation', s: 'auth_core.zig' },
      { p: 'auth/login_guard', c: 'AU-04', t: 'Login guard — rate limiting, brute-force protection', s: 'login_guard.zig' }
    ]},
    { key: 'config/', label: 'CONFIG — THE VAULT', docs: [
      { p: 'config/key_vault', c: 'CF-01', t: 'Encrypted key vault — secure storage for secrets', s: 'key_vault.zig' },
      { p: 'config/keys_api', c: 'CF-02', t: 'Key management HTTP API', s: 'keys_api.zig' }
    ]},
    { key: 'gateway/', label: 'GATEWAY — THE ONLY DOOR IN', docs: [
      { p: 'gateway/http', c: 'GW-01', t: 'HTTP gateway — routing, middleware pipeline', s: 'http.zig' }
    ]},
    { key: 'obs/', label: 'OBS — THE RECORD', docs: [
      { p: 'obs/audit_log', c: 'OB-01', t: 'Audit log — structured event recording', s: 'audit_log.zig' }
    ]},
    { key: 'orchestrate/', label: 'ORCHESTRATE — THE FLEET', docs: [
      { p: 'orchestrate/chat_tools', c: 'OR-01', t: 'Chat tool definitions — function calling registry', s: 'chat_tools.zig' },
      { p: 'orchestrate/control_writer', c: 'OR-02', t: 'Control-plane writer — state mutation orchestration', s: 'control_writer.zig' },
      { p: 'orchestrate/deploy_service', c: 'OR-03', t: 'Deploy service — deployment lifecycle', s: 'deploy_service.zig' },
      { p: 'orchestrate/neuron_client', c: 'OR-04', t: 'Neuron client — inter-agent communication', s: 'neuron_client.zig' },
      { p: 'orchestrate/supervisor', c: 'OR-05', t: 'Supervisor — agent lifecycle, health, coordination', s: 'supervisor.zig' },
      { p: 'orchestrate/tail_fanout', c: 'OR-06', t: 'Tail fanout — log streaming and event distribution', s: 'tail_fanout.zig' }
    ]},
    { key: 'plan/', label: 'PLAN — THE LEDGER', docs: [
      { p: 'plan/billing_seam', c: 'PL-01', t: 'Billing seam — pricing and metering integration', s: 'billing_seam.zig' },
      { p: 'plan/entitlements', c: 'PL-02', t: 'Entitlements — feature gating by plan level', s: 'entitlements.zig' },
      { p: 'plan/neurons', c: 'PL-03', t: 'Neuron plans — resource allocation models', s: 'neurons.zig' }
    ]},
    { key: 'worker/', label: 'WORKER — THE YARDS', docs: [
      { p: 'worker/agi', c: 'WK-01', t: 'AGI worker core — the autonomous reasoning loop', s: 'agi.zig' },
      { p: 'worker/bufedit', c: 'WK-02', t: 'Buffer editor — file editing operations', s: 'bufedit.zig' },
      { p: 'worker/commons', c: 'WK-03', t: 'Common utilities — shared helpers', s: 'commons.zig' },
      { p: 'worker/crawl', c: 'WK-04', t: 'Web crawler — resource discovery and fetching', s: 'crawl.zig' },
      { p: 'worker/hyperspace', c: 'WK-05', t: 'Hyperspace — vector embedding and similarity search', s: 'hyperspace.zig' },
      { p: 'worker/llm', c: 'WK-06', t: 'LLM integration — inference, prompt management', s: 'llm.zig' },
      { p: 'worker/locs/atlas', c: 'WK-07', t: 'Atlas — geospatial location services', s: 'locs/atlas.zig' },
      { p: 'worker/oscillation', c: 'WK-08', t: 'Oscillation — adaptive recursion, state exploration', s: 'oscillation.zig' },
      { p: 'worker/rsi', c: 'WK-09', t: 'RSI — the recursive self-improvement engine', s: 'rsi.zig' },
      { p: 'worker/run', c: 'WK-10', t: 'Run loop — the main worker execution cycle', s: 'run.zig' },
      { p: 'worker/tools', c: 'WK-11', t: 'Tool system — definitions and dispatch', s: 'tools.zig' },
      { p: 'worker/vcs', c: 'WK-12', t: 'VCS — version control for concurrent minds', s: 'vcs.zig' },
      { p: 'worker/writer', c: 'WK-13', t: 'Writer — output generation and formatting', s: 'writer.zig' }
    ]}
  ];

  const FLAT = [];
  GROUPS.forEach((g) => g.docs.forEach((d) => { d.group = g; FLAT.push(d); }));
  const BY_PATH = {};
  FLAT.forEach((d, i) => { d.idx = i; BY_PATH[d.p] = d; });

  const dialog = document.getElementById('docview');
  const body = document.getElementById('docviewBody');
  const title = document.getElementById('docviewTitle');
  const closeBtn = document.getElementById('docviewClose');
  const tagChip = document.getElementById('docviewTag');
  const paper = document.getElementById('docviewPaper');
  if (!dialog || !body) return;

  let lastFocus = null;
  let current = null;      // doc entry currently on the paper
  let fetchSeq = 0;        // ignore stale fetches
  const cache = {};        // path -> markdown source

  /* ---------------- build the inventory sheet ---------------- */
  const mount = document.getElementById('invMount');
  if (mount) {
    GROUPS.forEach((g) => {
      const cap = document.createElement('li');
      cap.className = 'inv-group';
      cap.id = 'inv-' + (g.key ? g.key.replace(/\W+/g, '') : 'file');
      cap.innerHTML = (g.key ? '<code>' + g.key + '</code> ' : '') + g.label +
        (g.note ? '<span class="inv-group-note">' + g.note + '</span>' : '');
      mount.appendChild(cap);
      g.docs.forEach((d) => {
        const li = document.createElement('li');
        const btn = document.createElement('button');
        btn.className = 'inv-row';
        btn.dataset.doc = d.p;
        btn.innerHTML = '<span class="inv-no">' + d.c + '</span>' +
          '<span class="inv-title">' + d.t + '</span>' +
          '<span class="inv-date">' + d.s + '</span>';
        btn.addEventListener('click', () => open(d.p));
        li.appendChild(btn);
        mount.appendChild(li);
      });
    });
  }

  /* ---------------- the viewer ---------------- */
  function clearPaper() {
    body.querySelectorAll(':scope > *:not(#docviewTitle)').forEach((n) => n.remove());
  }

  function setHash(path) {
    const want = path ? '#doc=' + path : '#';
    if (location.hash !== want) {
      suppressHash = true;
      if (path) location.hash = 'doc=' + path;
      else history.replaceState(null, '', location.pathname + location.search);
      setTimeout(() => { suppressHash = false; }, 0);
    }
  }

  function open(ref) {
    if (!ref) return;
    const parts = String(ref).split('#');
    const path = parts[0].replace(/^\/+|\/+$/g, '');
    const anchor = parts[1] || '';
    const doc = BY_PATH[path];
    if (!doc) return;

    if (!dialog.open) {
      lastFocus = document.activeElement;
      dialog.showModal();
    }
    current = doc;
    setHash(doc.p);
    if (tagChip) tagChip.textContent = doc.c;
    title.textContent = 'Source document ' + doc.c + ': ' + doc.t;

    clearPaper();
    const wait = document.createElement('p');
    wait.className = 'docview-wait';
    wait.textContent = 'RETRIEVING ' + doc.c + ' FROM THE FILE ';
    body.appendChild(wait);

    const seq = ++fetchSeq;
    load(doc.p).then((src) => {
      if (seq !== fetchSeq) return;
      renderDoc(doc, src, anchor);
    }).catch((err) => {
      if (seq !== fetchSeq) return;
      renderError(doc, err);
    });
  }

  function load(path) {
    if (cache[path] !== undefined) return Promise.resolve(cache[path]);
    return fetch('docs-src/' + path + '.md').then((r) => {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.text();
    }).then((src) => { cache[path] = src; return src; });
  }

  function renderDoc(doc, src, anchor) {
    clearPaper();
    const holder = document.createElement('div');
    holder.innerHTML = window.NVMarkdown.render(src);
    // adopt children so the per-line entrance animation sees them as blocks
    while (holder.firstChild) body.appendChild(holder.firstChild);
    wireLinks(doc);
    appendNav(doc);
    dialog.scrollTop = 0;
    paper.scrollTop = 0;
    if (anchor) {
      const target = body.querySelector('#' + CSS.escape(anchor));
      if (target) target.scrollIntoView({ block: 'start' });
    }
  }

  function renderError(doc, err) {
    clearPaper();
    const div = document.createElement('div');
    div.className = 'docview-err';
    const isFile = location.protocol === 'file:';
    div.innerHTML =
      '<p class="doc-head">RETRIEVAL FAILURE — ' + doc.c + '<br>THE PAGE IS NOT WHERE THE INDEX SAYS IT IS</p>' +
      '<p>The reading room could not produce <code>docs-src/' + doc.p + '.md</code> (' + String(err && err.message || err) + ').</p>' +
      (isFile
        ? '<p>This copy of the file is being read straight off the shelf (<code>file://</code>), and the browser will not fetch loose pages that way. Serve the folder and try again:</p>' +
          '<pre class="md-code"><code>cd docs' + String.fromCharCode(10) + 'python -m http.server 8080</code></pre>' +
          '<p>then visit <code>http://localhost:8080/</code>.</p>'
        : '<p>Check that the <code>docs-src/</code> folder was deployed beside this page, then pull the string again.</p>') +
      '<p class="hand doc-margin">the index never lies twice. try once more. &mdash;g.</p>';
    body.appendChild(div);
    appendNav(doc);
  }

  /* rendered markdown: route internal links back through the viewer */
  function wireLinks(doc) {
    const baseDir = doc.p.indexOf('/') !== -1 ? doc.p.slice(0, doc.p.lastIndexOf('/') + 1) : '';
    body.querySelectorAll('a[data-md]').forEach((a) => {
      a.addEventListener('click', (e) => {
        e.preventDefault();
        open(resolve(baseDir, a.dataset.md));
      });
    });
    body.querySelectorAll('a[data-mod]').forEach((a) => {
      a.addEventListener('click', (e) => {
        e.preventDefault();
        const target = resolve(baseDir, a.dataset.mod);
        close();
        jumpToGroup(target);
      });
    });
    body.querySelectorAll('a[href^="#"]').forEach((a) => {
      a.addEventListener('click', (e) => {
        e.preventDefault();
        const t = body.querySelector('#' + CSS.escape(a.getAttribute('href').slice(1)));
        if (t) t.scrollIntoView({ block: 'start', behavior: 'smooth' });
      });
    });
  }

  function resolve(baseDir, rel) {
    if (rel.charAt(0) === '/') return rel.slice(1);
    const segs = (baseDir + rel).split('/');
    const out = [];
    segs.forEach((s) => {
      if (s === '' || s === '.') return;
      if (s === '..') out.pop();
      else out.push(s);
    });
    return out.join('/') + (rel.slice(-1) === '/' ? '/' : '');
  }

  function jumpToGroup(key) {
    const el = document.getElementById('inv-' + key.replace(/\W+/g, ''));
    const sheet = document.querySelector('.inv-sheet');
    if (el) {
      el.scrollIntoView({ block: 'center', behavior: 'smooth' });
      if (sheet) {
        sheet.classList.remove('flash');
        void sheet.offsetWidth;
        sheet.classList.add('flash');
      }
    }
  }

  function appendNav(doc) {
    const nav = document.createElement('div');
    nav.className = 'docview-nav';
    const prev = FLAT[doc.idx - 1], next = FLAT[doc.idx + 1];
    const mk = (d, dir) => {
      const b = document.createElement('button');
      b.type = 'button';
      if (d) {
        b.innerHTML = dir < 0 ? '&larr; ' + d.c : d.c + ' &rarr;';
        b.title = d.t;
        b.addEventListener('click', () => open(d.p));
      } else b.disabled = true;
      return b;
    };
    nav.appendChild(mk(prev, -1));
    const pos = document.createElement('span');
    pos.className = 'dv-pos';
    pos.textContent = 'SHEET ' + (doc.idx + 1) + ' OF ' + FLAT.length;
    nav.appendChild(pos);
    nav.appendChild(mk(next, 1));
    body.appendChild(nav);
  }

  // Cleanup after the dialog is dismissed. Idempotent — safe to call from the
  // several paths that can close it (button, backdrop, Escape) since not every
  // browser fires the dialog 'close' event on a programmatic .close().
  function afterClosed() {
    current = null;
    setHash('');
    if (lastFocus && lastFocus.focus) { lastFocus.focus(); lastFocus = null; }
  }

  function close() {
    if (dialog.open) dialog.close();
    afterClosed();
  }

  closeBtn.addEventListener('click', close);
  dialog.addEventListener('click', (e) => {
    if (e.target === dialog) close(); // backdrop click
  });
  // Escape dismisses a modal dialog natively without routing through close();
  // 'cancel' fires for it, 'close' fires where supported. Both land on cleanup.
  dialog.addEventListener('cancel', () => setTimeout(afterClosed, 0));
  dialog.addEventListener('close', afterClosed);

  /* ---------------- deep links ---------------- */
  let suppressHash = false;
  function fromHash() {
    if (suppressHash) return;
    const m = /^#doc=(.+)$/.exec(location.hash);
    if (m) {
      const ref = decodeURIComponent(m[1]);
      if (!current || current.p !== ref.split('#')[0]) open(ref);
    } else if (dialog.open) {
      close();
    }
  }
  window.addEventListener('hashchange', fromHash);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fromHash);
  else fromHash();

  /* timeline source chips */
  document.querySelectorAll('.src-link[data-doc]').forEach((b) => {
    b.addEventListener('click', () => open(b.dataset.doc));
  });

  window.CCDocs = { open, close, docs: FLAT };
})();
