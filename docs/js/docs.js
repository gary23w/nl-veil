/* nl-veil docs — the source-document index and its reader.
   The manifest below is the contents of the tree; every row and every node on
   the architecture map opens the real markdown under docs-src/, parsed by the
   home-built parser and rendered in the app's own reading surface. */
(function () {
  'use strict';

  /* ---------------- the contents of the tree ---------------- */
  const GROUPS = [
    { key: '', label: 'OVERVIEW', note: 'start here', docs: [
      { p: 'index', c: 'IX-00', t: 'Module index — the contents of the tree', s: 'docs-src' },
      { p: 'main', c: 'MN-01', t: 'Entry point — CLI dispatch, the route table, server or app mode', s: 'main.zig' }
    ]},
    { key: 'guide/', label: 'GUIDE — RUNNING THE THING', note: 'not per-file', docs: [
      { p: 'guide/architecture', c: 'GD-01', t: 'Architecture — one server, three clients (web, desk, CLI)', s: 'main.zig · build.zig' },
      { p: 'guide/server', c: 'GD-02', t: 'Running a server — first login, the bind, the default model, accounts', s: 'main.zig · config/' },
      { p: 'guide/accounts', c: 'GD-03', t: 'Accounts and the sandbox — what a non-admin can and cannot do', s: 'worker/tools.zig' },
      { p: 'guide/models', c: 'GD-04', t: 'The model trio — which call runs on coding, thinking or prompting, and how to choose', s: 'chat/engine.zig · llm.zig' },
      { p: 'guide/extensions', c: 'GD-05', t: 'Extending veil — themes and plugins across web, desk and CLI', s: 'plug/' },
      { p: 'guide/themes', c: 'GD-06', t: 'Authoring a theme — the 16 palette slots, mono_ui, the workspace', s: 'plug/theme.zig' },
      { p: 'guide/plugins', c: 'GD-07', t: 'Writing a plugin — tools, policy + prompt hooks, MCP, the sandbox', s: 'plug/plugins.zig · plug/lua.zig' }
    ]},
    { key: 'admin/', label: 'ADMIN — SYSTEM MANAGEMENT', docs: [
      { p: 'admin/admin_service', c: 'AD-01', t: 'Admin service — god-mode handlers, every action audited', s: 'admin_service.zig' }
    ]},
    { key: 'auth/', label: 'AUTH — WHO GOES THERE', docs: [
      { p: 'auth/api_keys', c: 'AU-01', t: 'API keys — nlk_ bearer keys, only hashes stored', s: 'api_keys.zig' },
      { p: 'auth/auth_api', c: 'AU-02', t: 'Auth API — register/login/logout/me, thin shims over auth_core', s: 'auth_api.zig' },
      { p: 'auth/auth_core', c: 'AU-03', t: 'Auth core — users and sessions on neuron-db, argon2id', s: 'auth_core.zig' },
      { p: 'auth/login_guard', c: 'AU-04', t: 'Login guard — five fails per IP, five-minute lockout', s: 'login_guard.zig' }
    ]},
    { key: 'cli/', label: 'CLI — THE VERBS', docs: [
      { p: 'cli', c: 'CL-01', t: 'CLI client — every veil verb a thin authenticated call to the local server', s: 'cli.zig' },
      { p: 'cli/chat', c: 'CL-02', t: 'veil chat REPL — server-side brain, client-mode tool delegation', s: 'cli/chat.zig' },
      { p: 'cli/exec_tool', c: 'CL-03', t: 'Shared client tool executor — one tools.execute in the invoker cwd', s: 'cli/exec_tool.zig' },
      { p: 'cli/hub', c: 'CL-04', t: 'Fleet console — roster, broadcast say/goal, stopall over the API', s: 'cli/hub.zig' }
    ]},
    { key: 'config/', label: 'CONFIG — THE VAULT', docs: [
      { p: 'config/key_vault', c: 'CF-01', t: 'Key vault — write-only BYOK: seal in, never read out', s: 'key_vault.zig' },
      { p: 'config/keys_api', c: 'CF-02', t: 'Keys API — POST sealed, GET metadata, DELETE by provider', s: 'keys_api.zig' },
      { p: 'config/cf_oauth', c: 'CF-03', t: 'Log in with Cloudflare — PKCE public client, vault-sealed tokens', s: 'cf_oauth.zig' },
      { p: 'config/lan', c: 'CF-04', t: 'LAN addresses — ipconfig/ifconfig parse for the startup URL', s: 'lan.zig' },
      { p: 'config/local_models', c: 'CF-05', t: 'Installed Ollama models — loopback /api/tags relay', s: 'local_models.zig' },
      { p: 'config/server_config', c: 'CF-06', t: 'Admin runtime defaults — model trio + browser preference, JSON-persisted', s: 'server_config.zig' }
    ]},
    { key: 'plug/', label: 'PLUG — THE EXTENSION LAYER', docs: [
      { p: 'plug/plugins', c: 'PG-01', t: 'Plugin registry — Lua manifests, tool/policy/prompt hooks, swap-on-reload', s: 'plugins.zig' },
      { p: 'plug/lua', c: 'PG-02', t: 'Embedded Lua 5.4 — sandboxed Vm with instruction and memory caps', s: 'lua.zig' },
      { p: 'plug/theme', c: 'PG-03', t: 'Theme workspace — 16-slot Lua palettes, one model for web/desk/CLI', s: 'theme.zig' }
    ]},
    { key: 'gateway/', label: 'GATEWAY — THE ONLY DOOR IN', docs: [
      { p: 'gateway/http', c: 'GW-01', t: 'HTTP gateway — routing, middleware pipeline', s: 'http.zig' }
    ]},
    { key: 'obs/', label: 'OBS — THE RECORD', docs: [
      { p: 'obs/audit_log', c: 'OB-01', t: 'Audit log — append-only, hash-chained privileged-action trail', s: 'audit_log.zig' }
    ]},
    { key: 'plan/', label: 'PLAN — THE LEDGER', docs: [
      { p: 'plan/billing_seam', c: 'PL-01', t: 'Billing seam — the checkout stub (billing not live)', s: 'billing_seam.zig' },
      { p: 'plan/entitlements', c: 'PL-02', t: 'Entitlements — the enforcement wall: plan to caps, pure', s: 'entitlements.zig' },
      { p: 'plan/neurons', c: 'PL-03', t: 'Neuron ledger — the metered-AI budget per user', s: 'neurons.zig' }
    ]},
    { key: 'worker/chat/', label: 'WORKER · CHAT — THE BRAIN (server-side)', note: 'the chat loop', docs: [
      { p: 'worker/chat/engine', c: 'CH-01', t: 'The chat brain — the server-side agentic turn loop', s: 'chat/engine.zig' },
      { p: 'worker/chat/service', c: 'CH-02', t: 'Chat REST handlers — convs, messages, events, control', s: 'chat/service.zig' },
      { p: 'worker/chat/tools', c: 'CH-03', t: 'Chat tool surface + the shared /chat/tool endpoint', s: 'chat/tools.zig' },
      { p: 'worker/sched', c: 'CH-04', t: 'Scheduled tasks — each run is a server chat conversation', s: 'sched.zig' },
      { p: 'worker/chat/context', c: 'CH-05', t: 'Context assembly — bounded LLM context for the turn', s: 'chat/context.zig' },
      { p: 'worker/chat/paths', c: 'CH-06', t: 'Paths — conversation id to build-tree mapping', s: 'chat/paths.zig' },
      { p: 'worker/chat/plan', c: 'CH-07', t: 'Plan board — the durable per-conversation plan', s: 'chat/plan.zig' },
      { p: 'worker/chat/sync', c: 'CH-08', t: 'Workdir sync — the shared protocol pieces', s: 'chat/sync.zig' },
      { p: 'worker/chat/toolperf', c: 'CH-09', t: 'Tool perf — per-machine learned tool behavior', s: 'chat/toolperf.zig' }
    ]},
    { key: 'worker/browser/', label: 'WORKER · BROWSER — THE DRIVER', docs: [
      { p: 'worker/browser/manager', c: 'BR-01', t: 'Manager — the process-global browser-session registry', s: 'browser/manager.zig' },
      { p: 'worker/browser/session', c: 'BR-02', t: 'Session — one headless browser', s: 'browser/session.zig' },
      { p: 'worker/browser/cdp', c: 'BR-03', t: 'CDP — the self-contained DevTools WebSocket client', s: 'browser/cdp.zig' },
      { p: 'worker/browser/launch', c: 'BR-04', t: 'Launch — browser discovery and headless start', s: 'browser/launch.zig' },
      { p: 'worker/browser/host', c: 'BR-05', t: 'Host — the local-host daemon and its client side', s: 'browser/host.zig' },
      { p: 'worker/browser/broker', c: 'BR-06', t: 'Broker — loopback broker for invented browser tools', s: 'browser/broker.zig' },
      { p: 'worker/browser/util', c: 'BR-07', t: 'Util — raw-thread-safe browser helpers', s: 'browser/util.zig' },
      { p: 'worker/browser/ext', c: 'BR-08', t: 'Ext — the CDP relay through the user’s own Chrome/Edge', s: 'browser/ext.zig' },
      { p: 'worker/browser/ext_api', c: 'BR-09', t: 'Ext API — the extension’s routes and its loopback-only pairing', s: 'browser/ext_api.zig' }
    ]},
    { key: 'worker/model', label: 'WORKER · MODEL — THE BUILT-IN ENGINE', note: 'no runtime to install', docs: [
      { p: 'worker/builtin', c: 'BI-01', t: 'Builtin — the contracts: sentinel base, per-boot bearer, weights store', s: 'builtin.zig' },
      { p: 'worker/builtin_endpoint', c: 'BI-02', t: 'Builtin endpoint — the loopback engine surface, native + OpenAI dialects', s: 'builtin_endpoint.zig' },
      { p: 'worker/llamaeng', c: 'BI-03', t: 'Llamaeng — embedded inference behind the Engine interface', s: 'llamaeng.zig' },
      { p: 'worker/modelpull', c: 'BI-04', t: 'Modelpull — resumable, sha-verified weights download and import', s: 'modelpull.zig' },
      { p: 'worker/gemma4', c: 'BI-05', t: 'Gemma4 — the wire format, rendered here and pinned byte-for-byte', s: 'gemma4.zig' }
    ]},
    { key: 'worker/mcp/', label: 'WORKER · MCP — THE FOREIGN TOOLS', docs: [
      { p: 'worker/mcp/discovery', c: 'MC-01', t: 'Discovery — local MCP and AI-runtime discovery', s: 'mcp/discovery.zig' },
      { p: 'worker/mcp/client', c: 'MC-02', t: 'Client — the minimal stdio MCP client', s: 'mcp/client.zig' }
    ]},
    { key: 'worker/control/', label: 'WORKER · CONTROL — THE SWARM CONTROL PLANE', docs: [
      { p: 'worker/control/supervisor', c: 'CT-01', t: 'Supervisor — detached swarm processes, re-adoption', s: 'control/supervisor.zig' },
      { p: 'worker/control/writer', c: 'CT-02', t: 'Control writer — the swarm control bus (stop / steer / goal)', s: 'control/writer.zig' },
      { p: 'worker/control/fanout', c: 'CT-03', t: 'Event fanout — swarm events.jsonl cursor + SSE stream', s: 'control/fanout.zig' },
      { p: 'worker/evcursor', c: 'CT-06', t: 'Event cursor — the poll contract both events endpoints share', s: 'evcursor.zig' },
      { p: 'worker/deploy/service', c: 'CT-04', t: 'Deploy service — cast/deploy + swarm files and lifecycle', s: 'deploy/service.zig' },
      { p: 'worker/neuron/client', c: 'CT-05', t: 'Neuron client — the neuron-db memory bridge (fail-open)', s: 'neuron/client.zig' }
    ]},
    { key: 'worker/', label: 'WORKER — THE YARDS (runtime)', docs: [
      { p: 'worker/run', c: 'WK-01', t: 'Run — the hive worker process, the per-round tick loop', s: 'run.zig' },
      { p: 'worker/agi', c: 'WK-02', t: 'AGI — the Veil: consciousness faculties over the worker', s: 'agi.zig' },
      { p: 'worker/oscillation', c: 'WK-03', t: 'Oscillation — the worker gateway to neuron-db', s: 'oscillation.zig' },
      { p: 'worker/rsi', c: 'WK-04', t: 'RSI — outcome-driven self-tuning (params, roles, playbook — never source)', s: 'rsi.zig' },
      { p: 'worker/writer', c: 'WK-05', t: 'Writer — the grounding scaffold: numbered sources, resolved citations', s: 'writer.zig' },
      { p: 'worker/tools', c: 'WK-06', t: 'Tools — the toolbelt: schema array in, executed tool_call out', s: 'tools.zig' },
      { p: 'worker/vcs', c: 'WK-07', t: 'VCS — version control for concurrent minds', s: 'vcs.zig' },
      { p: 'worker/bufedit', c: 'WK-08', t: 'Bufedit — line-addressable, anchor-based edit ops', s: 'bufedit.zig' },
      { p: 'worker/crawl', c: 'WK-09', t: 'Crawl — HTML to clean markdown, density heuristic, no browser', s: 'crawl.zig' },
      { p: 'worker/hyperspace', c: 'WK-10', t: 'Hyperspace — the working-memory oscillator over neuron-db', s: 'hyperspace.zig' },
      { p: 'worker/llm', c: 'WK-11', t: 'LLM — the client: loopback via httpc, hosted via curl', s: 'llm.zig' },
      { p: 'worker/locs/atlas', c: 'WK-12', t: 'Atlas — the source atlas pointing scouts at nl-rag packs', s: 'locs/atlas.zig' },
      { p: 'worker/commons', c: 'WK-13', t: 'Commons — the swarm message bus + event-sourced task board', s: 'commons.zig' },
      { p: 'worker/httpc', c: 'WK-14', t: 'httpc — bounded raw-socket HTTP/1.1 loopback client', s: 'httpc.zig' },
      { p: 'worker/lineage', c: 'WK-15', t: 'Lineage — cross-run swarm memory keyed to a lineage id', s: 'lineage.zig' },
      { p: 'worker/metrics', c: 'WK-16', t: 'Metrics — per-role LLM usage metering for the Dashboard', s: 'metrics.zig' },
      { p: 'worker/modelcfg', c: 'WK-17', t: 'Modelcfg — the one model catalog, comptime from models.yaml', s: 'modelcfg.zig' },
      { p: 'worker/hashline', c: 'WK-18', t: 'Hashline — hash-anchored line edits with atomic batches', s: 'hashline.zig' },
      { p: 'worker/deps', c: 'WK-19', t: 'Deps — dependency probe: detect and instruct, never install', s: 'deps.zig' },
      { p: 'worker/rate', c: 'WK-20', t: 'Rate — per-host outbound pacing for hosted LLM backends', s: 'rate.zig' },
      { p: 'worker/rerank', c: 'WK-21', t: 'Rerank — second-stage LLM reranking with an abstain floor', s: 'rerank.zig' },
      { p: 'worker/recipes', c: 'WK-22', t: 'Recipes — the granted-recipe data layer: parse, validate, substitute', s: 'recipes.zig' },
      { p: 'worker/toolchain', c: 'WK-23', t: 'Toolchain — project-toolchain floor: bootstrap + derived checks', s: 'toolchain.zig' },
      { p: 'worker/ragingest', c: 'WK-24', t: 'Ragingest — offline local-file RAG ingest into the hive', s: 'ragingest.zig' },
      { p: 'worker/ragmirror', c: 'WK-25', t: 'Ragmirror — local nl-rag pack mirror + atlas extension', s: 'ragmirror.zig' },
      { p: 'worker/ocr', c: 'WK-26', t: 'OCR — OS-native shims: vision as text', s: 'ocr.zig' },
      { p: 'worker/pixelrag', c: 'WK-27', t: 'Pixelrag — screenshot-tile ingest and retrieval', s: 'pixelrag.zig' }
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
      { p: 'desk/catalog', c: 'DK-13', t: 'Model catalog — provider/model sets re-exported from models.yaml', s: 'catalog.zig' },
      { p: 'desk/secrets', c: 'DK-14', t: 'Secrets — plaintext key files (legacy DPAPI unseal only)', s: 'secrets.zig' },
      { p: 'desk/log', c: 'DK-15', t: 'Logger — ring buffer to veil-desk.log + the F12 overlay', s: 'log.zig' },
      { p: 'desk/gitvc', c: 'DK-16', t: 'Gitvc — git + GitHub operations for the chat', s: 'gitvc.zig' },
      { p: 'desk/assets', c: 'DK-17', t: 'Assets — icons + OpenDyslexic embedded in the exe', s: 'assets.zig' },
      { p: 'desk/runner', c: 'DK-18', t: 'Runner — the engine door to the server; loopback vtable', s: 'runner.zig' }
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
  const pathChip = document.getElementById('docviewPath');
  const paper = document.getElementById('docviewPaper');
  if (!dialog || !body) return;

  let lastFocus = null;
  let current = null;      // the doc on screen
  let fetchSeq = 0;        // ignore stale fetches
  const cache = {};        // path -> markdown source

  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  /* ---------------- the index ---------------- */
  const mount = document.getElementById('invMount');
  const rows = [];   // { d, li, groupLi }
  const groupEls = [];

  if (mount) {
    GROUPS.forEach((g) => {
      const cap = document.createElement('li');
      cap.className = 'idx-group';
      cap.id = 'idx-' + (g.key ? g.key.replace(/\W+/g, '') : 'top');
      cap.innerHTML = (g.key ? '<code>' + esc(g.key) + '</code>' : '') + esc(g.label) +
        (g.note ? '<span class="idx-group-note">' + esc(g.note) + '</span>' : '');
      mount.appendChild(cap);
      const entry = { el: cap, rows: [] };
      groupEls.push(entry);

      g.docs.forEach((d) => {
        const li = document.createElement('li');
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'idx-row';
        btn.dataset.doc = d.p;
        btn.addEventListener('click', () => open(d.p));
        li.appendChild(btn);
        mount.appendChild(li);
        const row = { d, li, btn, group: entry, hay: (d.c + ' ' + d.t + ' ' + d.s + ' ' + d.p + ' ' + g.label).toLowerCase() };
        paintRow(row, '');
        entry.rows.push(row);
        rows.push(row);
      });
    });
  }

  /** Row markup, with the query highlighted in the title when there is one. */
  function paintRow(row, q) {
    const d = row.d;
    row.btn.innerHTML =
      '<span class="idx-no">' + esc(d.c) + '</span>' +
      '<span class="idx-title">' + mark(d.t, q) + '</span>' +
      '<span class="idx-src">' + mark(d.s, q) + '</span>';
  }

  function mark(text, q) {
    const safe = esc(text);
    if (!q) return safe;
    const i = safe.toLowerCase().indexOf(q);
    if (i === -1) return safe;
    return safe.slice(0, i) + '<mark>' + safe.slice(i, i + q.length) + '</mark>' + safe.slice(i + q.length);
  }

  /* ---------------- filter ---------------- */
  const search = document.getElementById('idxSearch');
  const countEl = document.getElementById('idxCount');
  const statDocs = document.getElementById('statDocs');
  if (statDocs) statDocs.textContent = String(FLAT.length);

  function setCount(n) {
    if (!countEl) return;
    countEl.textContent = n === FLAT.length
      ? FLAT.length + ' documents'
      : n + ' of ' + FLAT.length + ' documents';
  }
  setCount(FLAT.length);

  function applyFilter() {
    const q = (search ? search.value : '').trim().toLowerCase();
    let shown = 0;
    groupEls.forEach((g) => {
      let any = false;
      g.rows.forEach((row) => {
        const hit = !q || row.hay.indexOf(q) !== -1;
        row.li.hidden = !hit;
        if (hit) { any = true; shown++; paintRow(row, q); }
      });
      g.el.hidden = !any;
    });
    setCount(shown);
    let empty = document.getElementById('idxEmpty');
    if (!shown) {
      if (!empty && mount) {
        empty = document.createElement('li');
        empty.id = 'idxEmpty';
        empty.className = 'idx-empty';
        mount.appendChild(empty);
      }
      if (empty) { empty.hidden = false; empty.textContent = 'No module matches “' + q + '”.'; }
    } else if (empty) empty.hidden = true;
  }

  if (search) {
    search.addEventListener('input', applyFilter);
    search.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { search.value = ''; applyFilter(); }
      // Enter on a single match opens it — the fastest path from thought to page
      if (e.key === 'Enter') {
        const hit = rows.filter((r) => !r.li.hidden);
        if (hit.length === 1) open(hit[0].d.p);
      }
    });
    // "/" focuses the filter from anywhere, like the app's command surfaces
    document.addEventListener('keydown', (e) => {
      if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return;
      const t = e.target;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
      if (dialog.open) return;
      e.preventDefault();
      search.focus();
      search.select();
    });
  }

  /* ---------------- the reader ---------------- */
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
    if (pathChip) pathChip.textContent = doc.s;
    title.textContent = 'Source document ' + doc.c + ': ' + doc.t;

    clearPaper();
    const wait = document.createElement('p');
    wait.className = 'docview-wait';
    wait.innerHTML = '<span class="spin"></span> loading ' + esc(doc.c) + '…';
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
    while (holder.firstChild) body.appendChild(holder.firstChild);
    wireLinks(doc);
    appendNav(doc);
    if (paper) paper.scrollTop = 0;
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
      '<h3>' + esc(doc.c) + ' could not be loaded</h3>' +
      '<p><code>docs-src/' + esc(doc.p) + '.md</code> did not come back (' + esc(String(err && err.message || err)) + ').</p>' +
      (isFile
        ? '<p>This page is open straight off the disk (<code>file://</code>), and the browser will not fetch loose files that way. Serve the folder instead:</p>' +
          '<pre class="md-code"><code>cd docs' + String.fromCharCode(10) + 'python -m http.server 8080</code></pre>' +
          '<p>then open <code>http://localhost:8080/</code>.</p>'
        : '<p>Check that <code>docs-src/</code> was deployed beside this page.</p>');
    body.appendChild(div);
    appendNav(doc);
  }

  /* rendered markdown: route internal links back through the reader */
  function wireLinks(doc) {
    const baseDir = doc.p.indexOf('/') !== -1 ? doc.p.slice(0, doc.p.lastIndexOf('/') + 1) : '';
    body.querySelectorAll('a[data-md]').forEach((a) => {
      a.addEventListener('click', (e) => { e.preventDefault(); open(resolve(baseDir, a.dataset.md)); });
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
    // a filter in force would hide the group we are jumping to
    if (search && search.value) { search.value = ''; applyFilter(); }
    const el = document.getElementById('idx-' + key.replace(/\W+/g, ''));
    if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }

  function appendNav(doc) {
    const nav = document.createElement('div');
    nav.className = 'docview-nav';
    const prev = FLAT[doc.idx - 1], next = FLAT[doc.idx + 1];
    const mk = (d, dir) => {
      const b = document.createElement('button');
      b.type = 'button';
      if (d) {
        b.innerHTML = dir < 0 ? '&larr; ' + esc(d.c) : esc(d.c) + ' &rarr;';
        b.title = d.t;
        b.addEventListener('click', () => open(d.p));
      } else b.disabled = true;
      return b;
    };
    nav.appendChild(mk(prev, -1));
    const pos = document.createElement('span');
    pos.className = 'dv-pos';
    pos.textContent = (doc.idx + 1) + ' of ' + FLAT.length;
    nav.appendChild(pos);
    nav.appendChild(mk(next, 1));
    body.appendChild(nav);
  }

  // Cleanup after the dialog is dismissed. Idempotent — not every browser fires
  // 'close' on a programmatic .close(), and Escape goes through 'cancel'.
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
  dialog.addEventListener('click', (e) => { if (e.target === dialog) close(); });
  dialog.addEventListener('cancel', () => setTimeout(afterClosed, 0));
  dialog.addEventListener('close', afterClosed);

  // ← / → step through the tree while the reader is open
  dialog.addEventListener('keydown', (e) => {
    if (!current || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA')) return;
    if (e.key === 'ArrowLeft' && FLAT[current.idx - 1]) { open(FLAT[current.idx - 1].p); e.preventDefault(); }
    if (e.key === 'ArrowRight' && FLAT[current.idx + 1]) { open(FLAT[current.idx + 1].p); e.preventDefault(); }
  });

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

  window.VeilDocs = { open: open, close: close, docs: FLAT };
})();
