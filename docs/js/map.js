/* nl-veil docs — the architecture map.
   Module cards pinned to a stage, links drawn on a canvas underneath them. The
   layout is the request path: clients on the left, the door, the brain and the
   control plane in the middle, the minds and the shared memory on the right.
   Every node opens its source document; nodes drag, and the links follow. */
(function () {
  'use strict';

  const STAGE_W = 1200, STAGE_H = 580, PADDING = 16;
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const viewport = document.getElementById('mapViewport');
  const scaler = document.getElementById('mapScaler');
  const stage = document.getElementById('mapStage');
  const canvas = document.getElementById('linkCanvas');
  if (!stage || !canvas) return;
  const ctx = canvas.getContext('2d');

  /* ---------------- kinds: one colour per layer, straight off the palette ---------------- */
  const KINDS = {
    client: { label: 'client', varName: '--green' },
    door:   { label: 'door',   varName: '--cyan' },
    brain:  { label: 'brain',  varName: '--blue' },
    mind:   { label: 'mind',   varName: '--magenta' },
    memory: { label: 'memory', varName: '--teal' },
    record: { label: 'record', varName: '--orange' },
    extend: { label: 'extend', varName: '--yellow' }
  };

  /* ---------------- the map ---------------- */
  const NODES = [
    { id: 'desk',    kind: 'client', x: 20,  y: 52,  title: 'veil-desk',      role: 'the native desktop shell',        doc: 'desk/main' },
    { id: 'cli',     kind: 'client', x: 20,  y: 176, title: 'veil (CLI)',     role: 'every verb, one authed call',     doc: 'cli' },
    { id: 'plug',    kind: 'extend', x: 20,  y: 424, title: 'plugins + themes', role: 'sandboxed Lua, all 3 clients',  doc: 'plug/plugins' },

    { id: 'gateway', kind: 'door',   x: 252, y: 108, title: 'the gateway',    role: 'routing, middleware, the only door in', doc: 'gateway/http' },
    { id: 'auth',    kind: 'door',   x: 252, y: 254, title: 'auth',           role: 'keys, sessions, a login guard',   doc: 'auth/auth_core' },
    { id: 'neurons', kind: 'record', x: 252, y: 452, title: 'neuron ledger',  role: 'the metered budget per user',     doc: 'plan/neurons' },

    { id: 'chat',    kind: 'brain',  x: 486, y: 36,  title: 'the chat brain', role: 'the server-side agentic turn loop', doc: 'worker/chat/engine' },
    { id: 'super',   kind: 'brain',  x: 486, y: 188, title: 'supervisor',     role: 'detached casts, re-adoption',     doc: 'worker/control/supervisor' },
    { id: 'audit',   kind: 'record', x: 486, y: 452, title: 'audit log',      role: 'append-only, hash-chained',       doc: 'obs/audit_log' },

    { id: 'run',     kind: 'mind',   x: 720, y: 144, title: 'the worker',     role: 'the per-round tick loop',         doc: 'worker/run' },
    { id: 'tools',   kind: 'mind',   x: 720, y: 292, title: 'the toolbelt',   role: 'schema in, executed call out',    doc: 'worker/tools' },
    { id: 'vcs',     kind: 'mind',   x: 720, y: 428, title: 'the merge',      role: 'many minds, one file',            doc: 'worker/vcs' },

    { id: 'rsi',     kind: 'mind',   x: 954, y: 44,  title: 'the learning loop', role: 'lessons minted from real failures', doc: 'worker/rsi' },
    { id: 'hive',    kind: 'memory', x: 954, y: 214, title: 'the hive',       role: 'one shared memory, on neuron-db', doc: 'worker/oscillation' },
    { id: 'crawl',   kind: 'memory', x: 954, y: 386, title: 'the crawler',    role: 'the outside, quoted verbatim',    doc: 'worker/crawl' }
  ];

  const LINKS = [
    ['desk', 'gateway'], ['cli', 'gateway'],
    ['gateway', 'auth'], ['gateway', 'chat'], ['gateway', 'super'], ['gateway', 'neurons'],
    ['auth', 'audit'], ['neurons', 'audit'],
    ['chat', 'tools'], ['chat', 'hive'],
    ['super', 'run'],
    ['run', 'tools'], ['run', 'vcs'], ['run', 'rsi'], ['run', 'hive'], ['run', 'crawl'],
    ['rsi', 'hive'], ['crawl', 'hive'],
    ['plug', 'tools'], ['plug', 'chat']
  ];

  /* ---------------- build ---------------- */
  const byId = {};
  NODES.forEach((n) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'map-node';
    b.dataset.doc = n.doc;
    b.style.setProperty('--kind', 'var(' + KINDS[n.kind].varName + ')');
    b.style.setProperty('--w', (n.w || 196) + 'px');
    b.innerHTML =
      '<span class="node-kind">' + KINDS[n.kind].label + '</span>' +
      '<span class="node-title">' + n.title + '</span>' +
      '<span class="node-role">' + n.role + '</span>';
    b.setAttribute('aria-label', n.title + ' — ' + n.role + '. Enter to read the module; arrow keys move it.');
    stage.appendChild(b);
    n.el = b;
    n.w = n.w || 196;
    place(n);
    byId[n.id] = n;

    const light = () => setHot(n);
    const unlight = () => { if (hot === n) setHot(null); };
    b.addEventListener('pointerenter', light);
    b.addEventListener('pointerleave', unlight);
    b.addEventListener('focus', light);
    b.addEventListener('blur', unlight);
  });

  const links = LINKS.map(([a, b]) => ({ a: byId[a], b: byId[b] })).filter((l) => l.a && l.b);
  // adjacency, so hovering a node can dim everything it does not touch
  const near = {};
  links.forEach((l) => {
    (near[l.a.id] = near[l.a.id] || new Set()).add(l.b.id);
    (near[l.b.id] = near[l.b.id] || new Set()).add(l.a.id);
  });

  function place(n) {
    n.el.style.transform = 'translate3d(' + n.x + 'px,' + n.y + 'px,0)';
  }
  function anchor(n) {
    const h = n.el.offsetHeight || 74;
    return { x: n.x + n.w / 2, y: n.y + h / 2 };
  }

  /* ---------------- legend ---------------- */
  (() => {
    const mount = document.getElementById('mapLegend');
    if (!mount) return;
    const used = [];
    NODES.forEach((n) => { if (used.indexOf(n.kind) === -1) used.push(n.kind); });
    mount.innerHTML = used.map((k) =>
      '<span><i style="--k:var(' + KINDS[k].varName + ')"></i>' + KINDS[k].label + '</span>').join('');
  })();

  /* ---------------- painting ---------------- */
  let hot = null;
  let palette = {};

  function readPalette() {
    const cs = getComputedStyle(document.documentElement);
    palette = {};
    Object.keys(KINDS).forEach((k) => {
      palette[k] = (cs.getPropertyValue(KINDS[k].varName) || '#888').trim();
    });
  }

  function setHot(n) {
    if (hot === n) return;
    hot = n;
    NODES.forEach((x) => {
      x.el.classList.toggle('dim', !!hot && x !== hot && !(near[hot.id] && near[hot.id].has(x.id)));
    });
    render();
  }

  const DPR = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = STAGE_W * DPR;
  canvas.height = STAGE_H * DPR;
  canvas.style.width = STAGE_W + 'px';
  canvas.style.height = STAGE_H + 'px';

  /* A link is a cubic with horizontal handles: it leaves a node sideways, which
     reads as a data path rather than a taut string between two pins. */
  function curve(p, q) {
    const dx = Math.max(40, Math.abs(q.x - p.x) * 0.45);
    return [p, { x: p.x + dx, y: p.y }, { x: q.x - dx, y: q.y }, q];
  }
  function pathOf(c) {
    ctx.beginPath();
    ctx.moveTo(c[0].x, c[0].y);
    ctx.bezierCurveTo(c[1].x, c[1].y, c[2].x, c[2].y, c[3].x, c[3].y);
  }
  function pointOn(c, t) {
    const u = 1 - t, a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t;
    return {
      x: a * c[0].x + b * c[1].x + d * c[2].x + e * c[3].x,
      y: a * c[0].y + b * c[1].y + d * c[2].y + e * c[3].y
    };
  }

  let phase = 0;

  function render() {
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.clearRect(0, 0, STAGE_W, STAGE_H);
    ctx.lineCap = 'round';

    links.forEach((l, i) => {
      const p = anchor(l.a), q = anchor(l.b);
      const c = curve(p, q);
      const lit = hot && (l.a === hot || l.b === hot);
      const dimmed = hot && !lit;

      const grad = ctx.createLinearGradient(p.x, p.y, q.x, q.y);
      grad.addColorStop(0, palette[l.a.kind]);
      grad.addColorStop(1, palette[l.b.kind]);

      ctx.globalAlpha = dimmed ? 0.1 : (lit ? 0.95 : 0.42);
      ctx.strokeStyle = grad;
      ctx.lineWidth = lit ? 2.2 : 1.4;
      pathOf(c);
      ctx.stroke();

      // one slow pulse per link — the engine is a running thing, not a diagram
      if (!reduceMotion && !dimmed) {
        const t = ((phase * 0.06) + i * 0.17) % 1;
        const pt = pointOn(c, t);
        ctx.globalAlpha = (lit ? 0.95 : 0.5) * (0.35 + 0.65 * Math.sin(Math.PI * t));
        ctx.fillStyle = palette[l.b.kind];
        ctx.beginPath();
        ctx.arc(pt.x, pt.y, lit ? 2.6 : 2, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    });
  }

  function repaint() { readPalette(); render(); }
  readPalette();

  /* ---------------- loop: only while on screen ---------------- */
  let raf = 0, visible = false, last = 0;
  function frame(t) {
    raf = 0;
    phase += Math.min(0.05, (t - last) / 1000 || 0.016);
    last = t;
    render();
    if (visible && !document.hidden && !reduceMotion) raf = requestAnimationFrame(frame);
  }
  function wake() {
    if (raf || !visible || document.hidden) { render(); return; }
    last = performance.now();
    if (reduceMotion) render();
    else raf = requestAnimationFrame(frame);
  }
  function sleep() { if (raf) { cancelAnimationFrame(raf); raf = 0; } }

  const io = new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting;
    if (visible) wake(); else sleep();
  }, { rootMargin: '120px' });
  io.observe(viewport);
  document.addEventListener('visibilitychange', () => { if (document.hidden) sleep(); else wake(); });

  /* ---------------- layout ---------------- */
  let scale = 1;
  function layout() {
    const avail = viewport.clientWidth - 2;
    scale = Math.min(1, Math.max(0.62, avail / STAGE_W));
    stage.style.transform = 'scale(' + scale + ')';
    scaler.style.width = STAGE_W * scale + 'px';
    scaler.style.height = STAGE_H * scale + 'px';
  }
  layout();
  window.addEventListener('resize', () => { layout(); render(); });

  /* ---------------- dragging ---------------- */
  let drag = null;
  stage.addEventListener('pointerdown', (e) => {
    const btn = e.target.closest('.map-node');
    if (!btn) return;
    const n = NODES.find((x) => x.el === btn);
    if (!n) return;
    drag = { n, sx: e.clientX, sy: e.clientY, ox: n.x, oy: n.y, moved: false };
    try { btn.setPointerCapture(e.pointerId); } catch (_) {}
  });
  stage.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const dx = (e.clientX - drag.sx) / scale;
    const dy = (e.clientY - drag.sy) / scale;
    if (!drag.moved && Math.hypot(e.clientX - drag.sx, e.clientY - drag.sy) < 5) return;
    if (!drag.moved) { drag.moved = true; drag.n.el.classList.add('dragging'); }
    const n = drag.n;
    const h = n.el.offsetHeight || 74;
    n.x = clamp(drag.ox + dx, -PADDING, STAGE_W - n.w + PADDING);
    n.y = clamp(drag.oy + dy, -PADDING, STAGE_H - h + PADDING);
    place(n);
    render();
  });
  function endDrag() {
    if (!drag) return;
    const was = drag;
    drag = null;
    was.n.el.classList.remove('dragging');
    // a drag that ends on the node must not also count as a click
    if (was.moved) {
      was.n._noClick = true;
      setTimeout(() => { was.n._noClick = false; }, 0);
    }
  }
  stage.addEventListener('pointerup', endDrag);
  stage.addEventListener('pointercancel', endDrag);
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }

  /* ---------------- open / keyboard ---------------- */
  stage.addEventListener('click', (e) => {
    const btn = e.target.closest('.map-node');
    if (!btn) return;
    const n = NODES.find((x) => x.el === btn);
    if (!n || n._noClick) return;
    if (window.VeilDocs) window.VeilDocs.open(n.doc);
  });

  stage.addEventListener('keydown', (e) => {
    const btn = e.target.closest('.map-node');
    if (!btn) return;
    const n = NODES.find((x) => x.el === btn);
    if (!n) return;
    const step = e.shiftKey ? 32 : 12;
    let used = true;
    if (e.key === 'ArrowLeft') n.x -= step;
    else if (e.key === 'ArrowRight') n.x += step;
    else if (e.key === 'ArrowUp') n.y -= step;
    else if (e.key === 'ArrowDown') n.y += step;
    else used = false;
    if (!used) return;
    const h = n.el.offsetHeight || 74;
    n.x = clamp(n.x, -PADDING, STAGE_W - n.w + PADDING);
    n.y = clamp(n.y, -PADDING, STAGE_H - h + PADDING);
    place(n);
    render();
    e.preventDefault();
  });

  /* ---------------- boot ---------------- */
  function boot() {
    layout();
    NODES.forEach((n, i) => {
      if (reduceMotion) { n.el.classList.add('in'); return; }
      setTimeout(() => { n.el.classList.add('in'); render(); }, 60 + i * 45);
    });
    render();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();

  window.VeilMap = { repaint: repaint, render: render };
})();
