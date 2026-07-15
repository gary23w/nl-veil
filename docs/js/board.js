/* FILE NL-VEIL — the evidence board.
   DOM items pinned to cork; red string as verlet ropes on a canvas above them.
   Every item opens a source document. The string is the architecture. */
(function () {
  'use strict';

  const STAGE_W = 1280, STAGE_H = 820, FRAME = 22;
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const stage = document.getElementById('boardStage');
  const scaler = document.getElementById('boardScaler');
  const viewport = document.getElementById('boardViewport');
  const canvas = document.getElementById('stringCanvas');
  const ctx = canvas.getContext('2d');
  if (!stage || !ctx) return;

  /* ---------------- system map SVG ---------------- */
  const MAP_SVG = `
  <svg viewBox="0 0 240 200" role="img" aria-hidden="true" xmlns="http://www.w3.org/2000/svg">
    <rect width="240" height="200" fill="#EDE3C0"/>
    <g stroke="#8a7c58" stroke-width="0.9" opacity="0.55">
      ${Array.from({ length: 9 }, (_, i) => `<path fill="none" d="M${176 + (i % 3) * 2},${18 + i * 20} q 8 ${i % 2 ? 3 : -3} 16 0 q 8 ${i % 2 ? -3 : 3} 16 0" stroke-dasharray="3 3"/>`).join('')}
    </g>
    <path d="M20,30 C40,14 78,10 96,22 C118,10 148,18 156,40 C174,52 178,84 166,104 C176,132 158,162 130,168 C102,180 60,176 44,156 C22,144 12,118 20,96 C8,72 8,46 20,30 Z"
      fill="#E0D0A0" stroke="#4A4234" stroke-width="1.4"/>
    <path d="M216,4 C226,44 230,94 220,142 C216,168 218,186 222,200 L240,200 L240,0 L214,0 Z" fill="#E0D0A0" stroke="#4A4234" stroke-width="1.2"/>
    <g font-family="'Courier Prime',monospace" fill="#4A4234">
      <text x="64" y="46" font-size="11" font-weight="700" letter-spacing="1">NL-VEIL</text>
      <text x="232" y="96" font-size="7" transform="rotate(90 232 96)" letter-spacing="2">OPERATOR SIDE</text>
      <text x="196" y="146" font-size="7.5" transform="rotate(-83 196 146)" letter-spacing="1.5">LOOPBACK NARROWS</text>
      <text x="84" y="150" font-size="7.5">GATEWAY</text>
      <text x="84" y="159" font-size="7.5">LANDING</text>
      <text x="46" y="88" font-size="7.5">AUTH GATE</text>
      <text x="96" y="88" font-size="7.5">WORKER</text>
      <text x="96" y="97" font-size="7.5">YARDS</text>
      <text x="52" y="122" font-size="7.5">CONTROL PLANE</text>
      <text x="120" y="62" font-size="7.5">THE HIVE</text>
      <text x="14" y="14" font-size="7">SHEET 1 OF 1 - NOT TO SCALE</text>
    </g>
    <!-- request current, running inland -->
    <g stroke="#4A4234" stroke-width="1.1" fill="none" opacity="0.8">
      <path d="M186,60 l-4,8 l8,0 z" fill="#4A4234"/><path d="M186,40 L186,60"/>
      <path d="M198,96 l-4,8 l8,0 z" fill="#4A4234"/><path d="M198,76 L198,96"/>
      <path d="M190,138 l-4,8 l8,0 z" fill="#4A4234"/><path d="M190,118 L190,138"/>
    </g>
    <!-- buildings -->
    <rect x="66" y="80" width="5" height="5" fill="#4A4234"/>
    <rect x="118" y="140" width="6" height="5" fill="#4A4234"/>
    <rect x="128" y="54" width="6" height="6" fill="#4A4234"/>
    <!-- the desk pier reaching toward the operator side -->
    <path d="M150,92 L186,86" stroke="#4A4234" stroke-width="2.4"/>
    <g stroke="#4A4234" stroke-width="1"><path d="M158,88 l0,7"/><path d="M166,87 l0,7"/><path d="M174,86 l0,7"/><path d="M182,85 l0,7"/></g>
    <text x="150" y="82" font-size="7.5" font-family="'Courier Prime',monospace" fill="#4A4234">DESK PIER</text>
    <!-- the request route, dashed red: landing, auth, yards, hive -->
    <path d="M120,142 C104,128 84,112 70,86 M74,82 C92,72 108,66 126,58"
      fill="none" stroke="#A8241B" stroke-width="1.6" stroke-dasharray="4 3" opacity="0.85"/>
    <!-- X marks the hive + grease circle -->
    <g stroke="#A8241B" stroke-width="2.2"><path d="M128,54 l7,7 M135,54 l-7,7"/></g>
    <ellipse cx="132" cy="58" rx="17" ry="12" fill="none" stroke="#B3301F" stroke-width="2.4" opacity="0.8" transform="rotate(-8 132 58)"/>
    <!-- compass -->
    <g transform="translate(30,164)" stroke="#4A4234" fill="none">
      <circle r="9" stroke-width="1"/><path d="M0,6 L0,-9 M-3,-4 L0,-9 L3,-4" stroke-width="1.2"/>
      <text x="-2.8" y="-12" font-size="7" font-family="'Courier Prime',monospace" fill="#4A4234" stroke="none">N</text>
    </g>
    <text x="150" y="188" font-size="7" font-family="'Courier Prime',monospace" fill="#4A4234">0</text>
    <path d="M156,186 L196,186" stroke="#4A4234" stroke-width="1"/>
    <text x="199" y="188" font-size="7" font-family="'Courier Prime',monospace" fill="#4A4234">1 CAST</text>
  </svg>`;

  /* ---------------- item manifest ---------------- */
  const skins = {
    polaroid: (it) => `<span class="item-skin"><canvas width="300" height="300" data-scene="${it.scene}"></canvas><span class="pcap">${it.cap}</span></span>`,
    icard: (it) => `<span class="item-skin"><span class="ic-title">${it.title}</span><span class="ic-body">${it.body}</span></span>`,
    ticket: () => `<span class="item-skin">
        <span class="tk-line">NEURON-LOOPS FLEET</span>
        <span class="tk-route">GOAL &rarr; DELIVERABLE</span>
        <span class="tk-line">ONE WAY &middot; DETACHED &middot; SURVIVES THE SERVER</span>
        <span class="tk-no">CAST N&deg; 8787</span>
        <span class="tk-warn">NOT VALID UNLESS CLIPPED BY THE JUDGE</span></span>`,
    matchbook: () => `<span class="item-skin">
        <span class="mb-anchor">&#10022;</span>
        <span class="mb-the">the</span>
        <span class="mb-name">VEIL</span>
        <span class="mb-sub">LOCAL-FIRST &middot; SELF-HOSTED</span>
        <span class="mb-strike">CLOSE COVER BEFORE CASTING</span></span>`,
    mapfrag: () => `<span class="item-skin">${MAP_SVG}</span>`,
    steno: () => `<span class="item-skin">
        <span class="st-head">NEURONS &mdash; CAST 117</span>
        <span class="st-cols"><span>BUDGET
1,200.00
  800.00
  650.00
  400.00
  212.50</span><span> METERED
1,184.20
  795.60
  638.15
  391.80
  212.50</span></span>
        <span class="st-cols" style="color:#A8241B;font-weight:700"><span>&Delta; OVERRUN</span><span>0.00</span></span></span>`,
    tide: () => `<span class="item-skin">
        <span class="td-head">CAST 117<br>FITNESS BY ROUND</span>
        <table><tbody>
          <tr><td>R5</td><td>SCORE</td><td>0.61</td></tr>
          <tr class="td-markrow"><td class="td-mark">R6</td><td>SCORE</td><td>0.74</td></tr>
          <tr><td>R7</td><td>SCORE</td><td>0.88</td></tr>
          <tr><td colspan="2">SMOKE PASS</td><td>R7</td></tr>
          <tr><td colspan="2">JUDGE</td><td>0.91</td></tr>
          <tr><td colspan="2">BUDGET LEFT</td><td>44%</td></tr>
        </tbody></table></span>`
  };

  const manifest = [
    { id: 'hive', type: 'polaroid', x: 552, y: 58, rot: 1.5, w: 170, doc: 'worker/neuron/client', scene: 'hive', tag: 'P-1',
      cap: 'the hive. every mind reads every mind.', label: 'Photograph: the shared hive memory, long exposure' },
    { id: 'desk', type: 'polaroid', x: 72, y: 84, rot: -3, w: 170, doc: 'main', scene: 'desk', tag: 'P-2',
      cap: 'the desk, past midnight. auto-loop armed.', label: 'Photograph: the operator desk, terminal mid-cast' },
    { id: 'swarm', type: 'polaroid', x: 96, y: 366, rot: 2.2, w: 170, doc: 'worker/run', scene: 'swarm', tag: 'P-3',
      cap: 'round 7. eleven minds, one file.', label: 'Photograph: eleven worker minds around one deliverable' },
    { id: 'gate', type: 'polaroid', x: 926, y: 556, rot: -2, w: 170, doc: 'gateway/http', scene: 'gate', tag: 'P-4',
      cap: 'the only door in. show a key.', label: 'Photograph: the gateway door, ajar, port 8787' },
    { id: 'crawl', type: 'polaroid', x: 566, y: 528, rot: -1.8, w: 170, doc: 'worker/crawl', scene: 'crawl', tag: 'P-5',
      cap: 'what the crawler brought back.', label: 'Photograph: crawled pages strung in the dark' },
    { id: 'rsi', type: 'icard', x: 800, y: 128, rot: 1.8, w: 228, doc: 'worker/rsi',
      title: 'RSI &mdash; THE LEARNING LOOP', body: 'Lessons minted from real failures, skills kept only if they pay. <em>THE ENGINE STAYS FIXED. THE MINDS MOVE.</em>',
      label: 'Index card: the recursive self-improvement loop' },
    { id: 'auth', type: 'icard', x: 312, y: 168, rot: -1.5, w: 228, doc: 'auth/auth_core',
      title: 'AUTH &mdash; WHO GOES THERE', body: 'Keys, sessions, a login guard that counts every knock. Brute force meets a locked hall. <em>NO KEY, NO ENTRY.</em>',
      label: 'Index card: authentication' },
    { id: 'vcs', type: 'icard', x: 1004, y: 322, rot: -2.2, w: 228, doc: 'worker/vcs',
      title: 'THE MERGE', body: 'Many minds, one file. Disjoint edits merge on their own; the same region is a CONFLICT, said out loud. <em>NOBODY WRITES BLIND.</em>',
      label: 'Index card: the micro version control for concurrent minds' },
    { id: 'ticket', type: 'ticket', x: 330, y: 622, rot: -4, w: 216, doc: 'worker/control/supervisor', tag: 'E-2', label: 'Cast ticket: goal to deliverable, one way' },
    { id: 'match', type: 'matchbook', x: 724, y: 420, rot: 3, w: 116, doc: 'worker/agi', tag: 'E-3', label: 'Matchbook from the Veil' },
    { id: 'map', type: 'mapfrag', x: 56, y: 588, rot: 1.2, w: 250, doc: 'index', label: 'Map fragment of the nl-veil system' },
    { id: 'steno', type: 'steno', x: 1092, y: 84, rot: -2.5, w: 150, doc: 'plan/billing_seam', tag: 'E-4', label: 'Steno page: neuron budget against metered spend' },
    { id: 'tide', type: 'tide', x: 1108, y: 558, rot: 2, w: 136, doc: 'worker/oscillation', tag: 'E-7', label: 'Fitness table, cast 117, round by round' }
  ];

  const stringPairs = [
    ['gate', 'auth'], ['gate', 'ticket'], ['map', 'gate'],
    ['ticket', 'swarm'], ['steno', 'ticket'],
    ['swarm', 'hive'], ['swarm', 'vcs'], ['swarm', 'rsi'],
    ['rsi', 'hive'], ['hive', 'desk'],
    ['crawl', 'swarm'], ['tide', 'swarm']
  ];

  /* ---------------- build DOM ---------------- */
  const items = {};
  manifest.forEach((it) => {
    const b = document.createElement('button');
    b.className = 'bitem ' + it.type;
    b.type = 'button';
    b.setAttribute('aria-label', it.label + '. Press enter to examine, arrow keys to move.');
    b.dataset.doc = it.doc;
    b.innerHTML = skins[it.type](it);
    if (it.tag) {
      const chip = document.createElement('span');
      chip.className = 'etag';
      chip.textContent = it.tag;
      chip.style.transform = 'rotate(' + ((hashJitter(it.id + 't') * 10 - 5).toFixed(1)) + 'deg)';
      b.appendChild(chip);
    }
    stage.insertBefore(b, canvas);
    // constellation: this item's strings light up under pointer or keyboard focus
    const light = () => { hot = it; wake(1800); render(); };
    const unlight = () => { if (hot === it) { hot = null; wake(1200); render(); } };
    b.addEventListener('pointerenter', light);
    b.addEventListener('pointerleave', unlight);
    b.addEventListener('focus', light);
    b.addEventListener('blur', unlight);
    it.el = b;
    it.px = it.w / 2 + (hashJitter(it.id) * 18 - 9); // pin x within item
    it.py = 13;
    b.style.transformOrigin = it.px + 'px ' + it.py + 'px';
    place(it);
    items[it.id] = it;
    const cv = b.querySelector('canvas[data-scene]');
    if (cv) window.CC.paint(cv, cv.dataset.scene);
  });

  function hashJitter(s) {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return ((h >>> 8) % 1000) / 1000;
  }

  function place(it) {
    const t = `translate3d(${it.x}px,${it.y}px,0) rotate(${it.rot}deg)`;
    it.el.style.setProperty('--place', t);
    it.el.style.transform = t;
  }

  function pinPos(it) { return { x: it.x + it.px, y: it.y + it.py }; }

  /* ---------------- cork ---------------- */
  stage.style.backgroundImage = 'radial-gradient(1100px 700px at 50% 30%, rgba(255,214,150,0.10), rgba(20,8,0,0.28)), url(' + window.CC.corkTile() + ')';

  /* ---------------- verlet ropes ---------------- */
  const GRAV = 1500, DAMP = 0.985, ITER = 4;
  const ropes = stringPairs.map(([a, b], idx) => {
    const A = items[a], B = items[b];
    const pa = pinPos(A), pb = pinPos(B);
    const dist = Math.hypot(pb.x - pa.x, pb.y - pa.y);
    const n = Math.min(24, Math.max(9, Math.round(dist / 30) + 4));
    const rest = (dist * 1.14) / (n - 1);
    const pts = [];
    for (let i = 0; i < n; i++) {
      const t = i / (n - 1);
      const jx = (Math.sin(idx * 7.3 + i * 1.7) * 14) * (reduceMotion ? 0 : 1);
      const jy = (Math.cos(idx * 3.1 + i * 2.3) * 10) * (reduceMotion ? 0 : 1);
      const px = pa.x + (pb.x - pa.x) * t + jx * Math.sin(Math.PI * t);
      const py = pa.y + (pb.y - pa.y) * t + jy * Math.sin(Math.PI * t);
      pts.push({ x: px, y: py, ox: px, oy: py });
    }
    return { A, B, pts, rest, phase: idx * 1.37 };
  });

  let simTime = 0;
  let pluck = null; // { rope, i, x, y } — a finger on the thread
  let hot = null;   // item under pointer/focus: its strings light up

  function step(dt) {
    simTime += dt;
    const g = GRAV * dt * dt;
    for (const r of ropes) {
      const pts = r.pts, last = pts.length - 1;
      for (let i = 1; i < last; i++) {
        const p = pts[i];
        let vx = (p.x - p.ox) * DAMP;
        let vy = (p.y - p.oy) * DAMP;
        p.ox = p.x; p.oy = p.y;
        p.x += vx;
        p.y += vy + g;
        if (!reduceMotion) {
          p.x += Math.sin(simTime * 0.7 + r.phase + p.y * 0.013) * 5.5 * dt;
        }
      }
      const pa = pinPos(r.A), pb = pinPos(r.B);
      pts[0].x = pa.x; pts[0].y = pa.y;
      pts[last].x = pb.x; pts[last].y = pb.y;
      for (let k = 0; k < ITER; k++) {
        for (let i = 0; i < last; i++) {
          const p1 = pts[i], p2 = pts[i + 1];
          let dx = p2.x - p1.x, dy = p2.y - p1.y;
          let d = Math.hypot(dx, dy) || 0.0001;
          const diff = (d - r.rest) / d;
          const f1 = (i === 0) ? 0 : 0.5, f2 = (i + 1 === last) ? 0 : 0.5;
          const tot = f1 + f2 || 1;
          p1.x += dx * diff * (f1 / tot) * (f1 ? 1 : 0);
          p1.y += dy * diff * (f1 / tot) * (f1 ? 1 : 0);
          p2.x -= dx * diff * (f2 / tot) * (f2 ? 1 : 0);
          p2.y -= dy * diff * (f2 / tot) * (f2 ? 1 : 0);
        }
        pts[0].x = pa.x; pts[0].y = pa.y;
        pts[last].x = pb.x; pts[last].y = pb.y;
        if (pluck && pluck.rope === r) {
          const p = pts[pluck.i];
          p.x = pluck.x; p.y = pluck.y; p.ox = pluck.x; p.oy = pluck.y;
        }
      }
    }
  }

  function nearestRopePoint(sx, sy, radius) {
    let best = null, bestD = radius;
    for (const r of ropes) {
      for (let i = 1; i < r.pts.length - 1; i++) {
        const d = Math.hypot(r.pts[i].x - sx, r.pts[i].y - sy);
        if (d < bestD) { bestD = d; best = { rope: r, i }; }
      }
    }
    return best;
  }

  function stageCoords(e) {
    const rect = stage.getBoundingClientRect();
    return { x: (e.clientX - rect.left) / scale, y: (e.clientY - rect.top) / scale };
  }

  /* ---------------- render ---------------- */
  const DPR = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = STAGE_W * DPR;
  canvas.height = STAGE_H * DPR;

  function drawRopePath(pts) {
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length - 1; i++) {
      const mx = (pts[i].x + pts[i + 1].x) / 2;
      const my = (pts[i].y + pts[i + 1].y) / 2;
      ctx.quadraticCurveTo(pts[i].x, pts[i].y, mx, my);
    }
    ctx.lineTo(pts[pts.length - 1].x, pts[pts.length - 1].y);
  }

  function render() {
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.clearRect(0, 0, STAGE_W, STAGE_H);
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    for (const r of ropes) {
      if (!bootDone && !reduceMotion &&
          (!r.A.el.classList.contains('pinned') || !r.B.el.classList.contains('pinned'))) continue;
      const lit = hot && (r.A === hot || r.B === hot);
      const dimmed = hot && !lit;
      // shadow
      ctx.save();
      ctx.translate(3, 5);
      ctx.strokeStyle = 'rgba(25,10,0,0.3)';
      ctx.lineWidth = lit ? 3.1 : 2.6;
      drawRopePath(r.pts); ctx.stroke();
      ctx.restore();
      // thread — the hot item's connections burn brighter, the rest recede
      ctx.globalAlpha = dimmed ? 0.55 : 1;
      ctx.strokeStyle = lit ? '#CE3B22' : '#B3301F';
      ctx.lineWidth = lit ? 2.5 : 2;
      drawRopePath(r.pts); ctx.stroke();
      // highlight
      ctx.strokeStyle = lit ? 'rgba(245,150,110,0.6)' : 'rgba(232,120,90,0.35)';
      ctx.lineWidth = lit ? 1.1 : 0.8;
      drawRopePath(r.pts); ctx.stroke();
      ctx.globalAlpha = 1;
    }
    // pins
    for (const id in items) {
      const it = items[id];
      if (!it.el.classList.contains('pinned') && !reduceMotion && !bootDone) continue;
      const p = pinPos(it);
      ctx.fillStyle = 'rgba(20,8,0,0.4)';
      ctx.beginPath(); ctx.ellipse(p.x + 2.5, p.y + 4, 6.5, 4, 0.4, 0, Math.PI * 2); ctx.fill();
      const grad = ctx.createRadialGradient(p.x - 2.4, p.y - 2.6, 1, p.x, p.y, 8);
      grad.addColorStop(0, '#E2604A');
      grad.addColorStop(0.45, '#B3271A');
      grad.addColorStop(1, '#6E1109');
      ctx.fillStyle = grad;
      ctx.beginPath(); ctx.arc(p.x, p.y, 7.2, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = 'rgba(255,235,225,0.85)';
      ctx.beginPath(); ctx.arc(p.x - 2.6, p.y - 2.8, 1.7, 0, Math.PI * 2); ctx.fill();
    }
  }

  /* ---------------- loop control ---------------- */
  let running = false, rafId = 0, lastT = 0, visible = false, settleUntil = Infinity;
  let bootDone = false;

  function frame(t) {
    rafId = 0;
    const dt = Math.min(0.032, (t - lastT) / 1000 || 0.016);
    lastT = t;
    step(dt);
    render();
    if (running && performance.now() < settleUntil) rafId = requestAnimationFrame(frame);
    else running = false;
  }

  function wake(ms) {
    settleUntil = reduceMotion ? performance.now() + (ms || 1200) : Infinity;
    if (!running && visible && !document.hidden) {
      running = true;
      lastT = performance.now();
      rafId = requestAnimationFrame(frame);
    }
  }
  function sleep() {
    running = false;
    if (rafId) { cancelAnimationFrame(rafId); rafId = 0; }
  }

  const io = new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting;
    if (visible) wake(); else sleep();
  }, { rootMargin: '100px' });
  io.observe(viewport);

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) sleep(); else if (visible) wake();
  });

  // pre-settle for reduced motion so strings read as calm catenaries
  if (reduceMotion) { for (let i = 0; i < 300; i++) step(1 / 60); }

  /* ---------------- scaling ---------------- */
  let scale = 1;
  function layout() {
    const avail = viewport.clientWidth;
    scale = Math.min(1, Math.max(0.62, (avail - 12) / STAGE_W));
    stage.style.transform = 'scale(' + scale + ')';
    scaler.style.width = STAGE_W * scale + 'px';
    scaler.style.height = STAGE_H * scale + 'px';
  }
  layout();
  window.addEventListener('resize', () => { layout(); render(); });

  /* ---------------- dragging ---------------- */
  let drag = null;
  stage.addEventListener('pointerdown', (e) => {
    const btn = e.target.closest('.bitem');
    if (!btn) {
      // finger on the thread?
      const c = stageCoords(e);
      const hit = nearestRopePoint(c.x, c.y, e.pointerType === 'touch' ? 32 : 16);
      if (hit) {
        pluck = { rope: hit.rope, i: hit.i, x: c.x, y: c.y };
        try { stage.setPointerCapture(e.pointerId); } catch (_) {}
        stage.classList.add('plucking');
        wake();
        e.preventDefault();
      }
      return;
    }
    const it = manifest.find((m) => m.el === btn);
    if (!it) return;
    drag = { it, startX: e.clientX, startY: e.clientY, ox: it.x, oy: it.y, moved: false };
    btn.setPointerCapture(e.pointerId);
    wake();
  });
  stage.addEventListener('pointermove', (e) => {
    if (pluck) {
      const c = stageCoords(e);
      pluck.x = clamp(c.x, 4, STAGE_W - 4);
      pluck.y = clamp(c.y, 4, STAGE_H - 4);
      wake();
      return;
    }
    if (!drag) {
      if (e.target === stage) {
        const c = stageCoords(e);
        stage.style.cursor = nearestRopePoint(c.x, c.y, 14) ? 'grab' : '';
      }
      return;
    }
    const dx = (e.clientX - drag.startX) / scale;
    const dy = (e.clientY - drag.startY) / scale;
    if (!drag.moved && Math.hypot(e.clientX - drag.startX, e.clientY - drag.startY) > 6) {
      drag.moved = true;
      drag.it.el.classList.add('dragging');
    }
    if (!drag.moved) return;
    const it = drag.it;
    const hEl = it.el.firstElementChild;
    const ih = hEl ? hEl.offsetHeight : 160;
    it.x = clamp(drag.ox + dx, FRAME - 20, STAGE_W - it.w - FRAME + 20);
    it.y = clamp(drag.oy + dy, FRAME - 8, STAGE_H - ih - FRAME + 24);
    place(it);
    wake();
  });
  function endDrag(e) {
    if (pluck) {
      pluck = null;
      stage.classList.remove('plucking');
      wake(2600);
    }
    if (!drag) return;
    const was = drag;
    drag = null;
    was.it.el.classList.remove('dragging');
    if (was.moved) {
      was.it._suppressClick = true;
      setTimeout(() => { was.it._suppressClick = false; }, 0);
      wake(2600);
    }
  }
  stage.addEventListener('pointerup', endDrag);
  stage.addEventListener('pointercancel', endDrag);

  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }

  // click → examine (unless it was a drag)
  stage.addEventListener('click', (e) => {
    const btn = e.target.closest('.bitem');
    if (!btn) return;
    const it = manifest.find((m) => m.el === btn);
    if (!it || it._suppressClick) return;
    if (window.CCDocs) window.CCDocs.open(it.doc);
  });

  // keyboard: arrows nudge the item, strings follow
  stage.addEventListener('keydown', (e) => {
    const btn = e.target.closest('.bitem');
    if (!btn) return;
    const it = manifest.find((m) => m.el === btn);
    if (!it) return;
    const stepPx = e.shiftKey ? 32 : 12;
    let used = true;
    if (e.key === 'ArrowLeft') it.x -= stepPx;
    else if (e.key === 'ArrowRight') it.x += stepPx;
    else if (e.key === 'ArrowUp') it.y -= stepPx;
    else if (e.key === 'ArrowDown') it.y += stepPx;
    else used = false;
    if (used) {
      it.x = clamp(it.x, FRAME - 20, STAGE_W - it.w - FRAME + 20);
      it.y = clamp(it.y, FRAME - 8, STAGE_H - 120 - FRAME + 24);
      place(it);
      wake(2600);
      e.preventDefault();
    }
  });

  /* ---------------- boot: pin items on, one by one ---------------- */
  const order = ['hive', 'desk', 'auth', 'rsi', 'steno', 'swarm', 'vcs', 'match', 'ticket', 'crawl', 'map', 'gate', 'tide'];
  function boot() {
    order.forEach((id, i) => {
      setTimeout(() => {
        items[id].el.classList.add('pinned');
        if (i === order.length - 1) setTimeout(() => { bootDone = true; }, 600);
      }, reduceMotion ? 0 : 260 + i * 85);
    });
    if (reduceMotion) { bootDone = true; render(); }
    wake(3000);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();

  window.CCBoard = { render, wake, _ropes: ropes, _stage: stage };
})();
