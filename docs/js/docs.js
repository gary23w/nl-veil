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
      { p: 'main', c: 'MN-01', t: 'Entry point — CLI dispatch, the route table, server or app mode', s: 'main.zig' }
    ]},
    { key: 'guide/', label: 'GUIDE — RUNNING THE THING', note: 'not per-file', docs: [
      { p: 'guide/architecture', c: 'GD-01', t: 'Architecture — one server, three clients (web, desk, CLI)', s: 'main.zig · build.zig' },
      { p: 'guide/server', c: 'GD-02', t: 'Running a server — first login, the bind, the default model, accounts', s: 'main.zig · config/' },
      { p: 'guide/accounts', c: 'GD-03', t: 'Accounts and the sandbox — what a non-admin can and cannot do', s: 'worker/tools.zig' },
      { p: 'guide/models', c: 'GD-04', t: 'The model trio — which call runs on coding, thinking or prompting, and how to choose', s: 'chat/engine.zig · llm.zig' }
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
    { key: 'plan/', label: 'PLAN — THE LEDGER', docs: [
      { p: 'plan/billing_seam', c: 'PL-01', t: 'Billing seam — pricing and metering integration', s: 'billing_seam.zig' },
      { p: 'plan/entitlements', c: 'PL-02', t: 'Entitlements — feature gating by plan level', s: 'entitlements.zig' },
      { p: 'plan/neurons', c: 'PL-03', t: 'Neuron plans — resource allocation models', s: 'neurons.zig' }
    ]},
    { key: 'worker/chat/', label: 'WORKER · CHAT — THE BRAIN (server-side)', note: 'the chat loop', docs: [
      { p: 'worker/chat/engine', c: 'CH-01', t: 'The chat brain — the server-side agentic turn loop', s: 'chat/engine.zig' },
      { p: 'worker/chat/service', c: 'CH-02', t: 'Chat REST handlers — convs, messages, events, control', s: 'chat/service.zig' },
      { p: 'worker/chat/tools', c: 'CH-03', t: 'Chat tool surface + the shared /chat/tool endpoint', s: 'chat/tools.zig' },
      { p: 'worker/sched', c: 'CH-04', t: 'Scheduled tasks — each run is a server chat conversation', s: 'sched.zig' }
    ]},
    { key: 'worker/control/', label: 'WORKER · CONTROL — THE SWARM CONTROL PLANE', docs: [
      { p: 'worker/control/supervisor', c: 'CT-01', t: 'Supervisor — detached swarm processes, re-adoption', s: 'control/supervisor.zig' },
      { p: 'worker/control/writer', c: 'CT-02', t: 'Control writer — the swarm control bus (stop / steer / goal)', s: 'control/writer.zig' },
      { p: 'worker/control/fanout', c: 'CT-03', t: 'Event fanout — swarm events.jsonl cursor + SSE stream', s: 'control/fanout.zig' },
      { p: 'worker/deploy/service', c: 'CT-04', t: 'Deploy service — cast/deploy + swarm files and lifecycle', s: 'deploy/service.zig' },
      { p: 'worker/neuron/client', c: 'CT-05', t: 'Neuron client — the neuron-db memory bridge (fail-open)', s: 'neuron/client.zig' }
    ]},
    { key: 'worker/', label: 'WORKER — THE YARDS (runtime)', docs: [
      { p: 'worker/run', c: 'WK-01', t: 'Run loop — the main worker execution cycle', s: 'run.zig' },
      { p: 'worker/agi', c: 'WK-02', t: 'AGI worker core — the autonomous reasoning loop', s: 'agi.zig' },
      { p: 'worker/oscillation', c: 'WK-03', t: 'Oscillation — adaptive recursion, state exploration', s: 'oscillation.zig' },
      { p: 'worker/rsi', c: 'WK-04', t: 'RSI — the recursive self-improvement engine', s: 'rsi.zig' },
      { p: 'worker/writer', c: 'WK-05', t: 'Writer — output generation and formatting', s: 'writer.zig' },
      { p: 'worker/tools', c: 'WK-06', t: 'Tool system — definitions and dispatch', s: 'tools.zig' },
      { p: 'worker/vcs', c: 'WK-07', t: 'VCS — version control for concurrent minds', s: 'vcs.zig' },
      { p: 'worker/bufedit', c: 'WK-08', t: 'Buffer editor — file editing operations', s: 'bufedit.zig' },
      { p: 'worker/crawl', c: 'WK-09', t: 'Web crawler — resource discovery and fetching', s: 'crawl.zig' },
      { p: 'worker/hyperspace', c: 'WK-10', t: 'Hyperspace — vector embedding and similarity search', s: 'hyperspace.zig' },
      { p: 'worker/llm', c: 'WK-11', t: 'LLM integration — inference, prompt management', s: 'llm.zig' },
      { p: 'worker/locs/atlas', c: 'WK-12', t: 'Atlas — the source atlas pointing scouts at nl-rag packs', s: 'locs/atlas.zig' },
      { p: 'worker/commons', c: 'WK-13', t: 'Common utilities — shared helpers', s: 'commons.zig' }
    ]},
    { key: 'desk/', label: 'DESK — THE NATIVE DASHBOARD (veil-desk)', note: 'zig + raylib', docs: [
      { p: 'desk/main', c: 'DK-01', t: 'Entry point — borderless raylib window, render loop, tabs', s: 'main.zig' },
      { p: 'desk/chat', c: 'DK-02', t: 'Chat tab client — sends to the server chat brain, streams + steers (local fallback)', s: 'chat.zig' },
      { p: 'desk/llm', c: 'DK-03', t: 'LLM client — streaming, SSE/NDJSON, tool-call recovery', s: 'llm.zig' },
      { p: 'desk/store', c: 'DK-04', t: 'Shared state — lock-guarded records + rings across threads', s: 'store.zig' },
      { p: 'desk/poller', c: 'DK-05', t: 'The IO thread — fleet liveness, run scan, event tail, notifications', s: 'poller.zig' },
      { p: 'desk/scan', c: 'DK-06', t: 'Filesystem layer — reads veil run dirs for the dashboard', s: 'scan.zig' },
      { p: 'desk/neuron', c: 'DK-07', t: 'Hippocampus client — the neuron-db bridge (fail-open)', s: 'neuron.zig' },
      { p: 'desk/netcli', c: 'DK-08', t: 'Server client — retry/triage wrapper over httpc', s: 'netcli.zig' },
      { p: 'desk/httpc', c: 'DK-09', t: 'HTTP client — curl-free raw-socket loopback', s: 'httpc.zig' },
      { p: 'desk/theme', c: 'DK-10', t: 'Theme + widgets — immediate-mode raylib UI, Tokyo Night', s: 'theme.zig' },
      { p: 'desk/mdutil', c: 'DK-11', t: 'Markdown util — block classification, math, inline cleanup', s: 'mdutil.zig' },
      { p: 'desk/tray', c: 'DK-12', t: 'System tray — icon + native toasts (Windows), no-op on POSIX', s: 'tray.zig' },
      { p: 'desk/catalog', c: 'DK-13', t: 'Model catalog — provider/model/option sets for the picker', s: 'catalog.zig' },
      { p: 'desk/secrets', c: 'DK-14', t: 'Key at rest — DPAPI-sealed on Windows, plain file on POSIX', s: 'secrets.zig' },
      { p: 'desk/log', c: 'DK-15', t: 'Logger — ring buffer to veil-desk.log + the F12 overlay', s: 'log.zig' }
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
