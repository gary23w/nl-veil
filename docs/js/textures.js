/* FILE NL-VEIL — procedural textures & photographs.
   Everything visual is synthesized here: the cork, and the five
   "polaroids" of the engine at work. No stock photography. */
(function () {
  'use strict';

  // Deterministic PRNG so the file always looks like the same file.
  function mulberry(seed) {
    return function () {
      seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  /* ---------------- cork board tile ---------------- */
  function corkTile() {
    const S = 340, c = document.createElement('canvas');
    c.width = S; c.height = S;
    const x = c.getContext('2d');
    const rnd = mulberry(20260710);
    const img = x.createImageData(S, S);
    const d = img.data;
    for (let i = 0; i < S * S; i++) {
      const px = i % S, py = (i / S) | 0;
      const low = Math.sin(px * 0.045 + Math.sin(py * 0.03) * 2.1) * Math.cos(py * 0.038 + px * 0.011);
      let v = (rnd() - 0.5) * 30 + low * 9;
      const j = i * 4;
      d[j] = 110 + v; d[j + 1] = 74 + v * 0.82; d[j + 2] = 39 + v * 0.6; d[j + 3] = 255;
    }
    x.putImageData(img, 0, 0);
    for (let i = 0; i < 420; i++) {
      const w = 1.5 + rnd() * 5, h = 1 + rnd() * 3;
      x.fillStyle = rnd() > 0.46 ? 'rgba(146,104,58,' + (0.14 + rnd() * 0.22) + ')'
                                 : 'rgba(58,36,14,' + (0.12 + rnd() * 0.2) + ')';
      x.save();
      x.translate(rnd() * S, rnd() * S);
      x.rotate(rnd() * Math.PI);
      x.beginPath(); x.ellipse(0, 0, w, h, 0, 0, Math.PI * 2); x.fill();
      x.restore();
    }
    for (let i = 0; i < 130; i++) { // pinprick holes of boards past
      x.fillStyle = 'rgba(40,22,6,' + (0.1 + rnd() * 0.25) + ')';
      x.beginPath(); x.arc(rnd() * S, rnd() * S, 0.6 + rnd() * 0.9, 0, Math.PI * 2); x.fill();
    }
    return c.toDataURL('image/png');
  }

  /* ---------------- polaroid helpers ---------------- */
  const W = 300, H = 300;

  function finish(x, rnd, opts) {
    opts = opts || {};
    for (let i = 0; i < 1500; i++) { // grain
      const a = 0.02 + rnd() * 0.05;
      x.fillStyle = rnd() > 0.5 ? 'rgba(255,255,255,' + a + ')' : 'rgba(0,0,0,' + a + ')';
      x.fillRect(rnd() * W, rnd() * H, 1.2, 1.2);
    }
    x.fillStyle = 'rgba(90,140,150,' + (opts.cyan ?? 0.09) + ')';
    x.fillRect(0, 0, W, H);
    x.fillStyle = 'rgba(214,160,80,' + (opts.warm ?? 0.07) + ')';
    x.fillRect(0, 0, W, H);
    const v = x.createRadialGradient(W / 2, H / 2, W * 0.32, W / 2, H / 2, W * 0.78);
    v.addColorStop(0, 'rgba(0,0,0,0)');
    v.addColorStop(1, 'rgba(8,6,2,' + (opts.vig ?? 0.5) + ')');
    x.fillStyle = v; x.fillRect(0, 0, W, H);
    if (opts.leak !== false) {
      const l = x.createLinearGradient(W, 0, W - 70, 0);
      l.addColorStop(0, 'rgba(230,140,60,' + (opts.leakA ?? 0.14) + ')');
      l.addColorStop(1, 'rgba(230,140,60,0)');
      x.fillStyle = l; x.fillRect(W - 70, 0, 70, H);
    }
    x.fillStyle = 'rgba(180,180,168,0.05)';
    x.fillRect(0, 0, W, H);
  }

  function glowDot(x, gx, gy, r, core, halo) {
    const g = x.createRadialGradient(gx, gy, 0.5, gx, gy, r);
    g.addColorStop(0, core);
    g.addColorStop(0.25, halo);
    g.addColorStop(1, 'rgba(0,0,0,0)');
    x.fillStyle = g;
    x.beginPath(); x.arc(gx, gy, r, 0, Math.PI * 2); x.fill();
  }

  /* P-1 — the hive: one shared memory, long exposure */
  function sceneHive(x) {
    const rnd = mulberry(111);
    const sky = x.createLinearGradient(0, 0, 0, H);
    sky.addColorStop(0, '#0b1016'); sky.addColorStop(1, '#07090c');
    x.fillStyle = sky; x.fillRect(0, 0, W, H);
    // the memory field: nodes scattered like a constellation
    const nodes = [];
    for (let i = 0; i < 26; i++) {
      nodes.push({ x: 24 + rnd() * 252, y: 30 + rnd() * 240, r: 1 + rnd() * 2.4 });
    }
    const cx = 150, cy = 148; // the hive core
    // threads: each node reaches toward its two nearest neighbours
    x.lineWidth = 0.7;
    for (const a of nodes) {
      const near = nodes.slice().sort((p, q) =>
        (Math.hypot(p.x - a.x, p.y - a.y) - Math.hypot(q.x - a.x, q.y - a.y))).slice(1, 3);
      for (const b of near) {
        x.strokeStyle = 'rgba(214,164,88,' + (0.10 + rnd() * 0.14) + ')';
        x.beginPath(); x.moveTo(a.x, a.y);
        x.quadraticCurveTo((a.x + b.x) / 2 + (rnd() - 0.5) * 14, (a.y + b.y) / 2 + (rnd() - 0.5) * 14, b.x, b.y);
        x.stroke();
      }
      // and every node reaches the core, faintly
      x.strokeStyle = 'rgba(190,140,70,' + (0.05 + rnd() * 0.08) + ')';
      x.beginPath(); x.moveTo(a.x, a.y);
      x.quadraticCurveTo((a.x + cx) / 2 + (rnd() - 0.5) * 20, (a.y + cy) / 2 + (rnd() - 0.5) * 20, cx, cy);
      x.stroke();
    }
    for (const a of nodes) {
      glowDot(x, a.x, a.y, 6 + a.r * 4, 'rgba(240,208,140,0.9)', 'rgba(220,165,80,0.35)');
    }
    glowDot(x, cx, cy, 60, 'rgba(248,216,150,1)', 'rgba(228,172,86,0.5)');
    x.fillStyle = 'rgba(255,242,210,0.95)';
    x.beginPath(); x.arc(cx, cy, 3.4, 0, Math.PI * 2); x.fill();
    // hand-chalked note on the print
    x.font = '400 15px "Caveat", cursive'; x.fillStyle = 'rgba(238,238,230,0.85)'; x.textAlign = 'left';
    x.fillText('every mind, one memory', 20, 284);
    finish(x, rnd, { vig: 0.6, cyan: 0.08, leakA: 0.1 });
  }

  /* P-2 — the desk, past midnight */
  function sceneDesk(x) {
    const rnd = mulberry(222);
    const wall = x.createLinearGradient(0, 0, 0, H);
    wall.addColorStop(0, '#14110d'); wall.addColorStop(1, '#0b0908');
    x.fillStyle = wall; x.fillRect(0, 0, W, H);
    // desk surface
    x.fillStyle = '#1d150e'; x.fillRect(0, 214, W, 86);
    x.strokeStyle = 'rgba(120,84,44,0.35)'; x.lineWidth = 1;
    for (let i = 0; i < 7; i++) { x.beginPath(); x.moveTo(0, 224 + i * 11); x.lineTo(W, 222 + i * 11.5); x.stroke(); }
    // monitor glow washes the wall
    glowDot(x, 150, 130, 190, 'rgba(226,182,102,0.28)', 'rgba(226,182,102,0.14)');
    // the terminal
    x.save(); x.translate(58, 52);
    x.fillStyle = '#0a0c0a'; x.fillRect(-8, -8, 200, 152); // bezel
    x.strokeStyle = '#2a221a'; x.lineWidth = 4; x.strokeRect(-8, -8, 200, 152);
    const scr = x.createLinearGradient(0, 0, 0, 136);
    scr.addColorStop(0, '#141a12'); scr.addColorStop(1, '#0d120c');
    x.fillStyle = scr; x.fillRect(0, 0, 184, 136);
    // typed lines: a cast mid-flight
    x.textAlign = 'left';
    const lines = [
      ['> cast a swarm to build it', 0.95],
      ['  blueprint: 14 files', 0.6],
      ['  round 1 · 11 minds', 0.6],
      ['  write ok  write ok', 0.5],
      ['  write FAIL — recorded', 0.85],
      ['  lesson minted -> hive', 0.7],
      ['  smoke: boot + probe ok', 0.6],
      ['  round 2 …', 0.75]
    ];
    x.font = '700 10px "Courier Prime", monospace';
    lines.forEach((l, i) => {
      x.fillStyle = i === 4 ? 'rgba(226,120,90,' + l[1] + ')' : 'rgba(190,214,150,' + l[1] + ')';
      x.fillText(l[0], 8, 18 + i * 14);
    });
    // caret
    x.fillStyle = 'rgba(190,214,150,0.9)'; x.fillRect(74, 122, 7, 10);
    // scanlines
    for (let i = 0; i < 34; i++) {
      x.fillStyle = 'rgba(0,0,0,0.16)'; x.fillRect(0, i * 4, 184, 1.4);
    }
    // screen glass sheen
    const sheen = x.createLinearGradient(0, 0, 184, 136);
    sheen.addColorStop(0, 'rgba(220,240,220,0.09)'); sheen.addColorStop(0.4, 'rgba(220,240,220,0)');
    x.fillStyle = sheen; x.fillRect(0, 0, 184, 136);
    x.restore();
    // monitor foot
    x.fillStyle = '#0a0c0a';
    x.fillRect(138, 196, 40, 14); x.fillRect(118, 208, 80, 8);
    // the mug, gone cold
    x.fillStyle = '#241c14';
    x.fillRect(238, 186, 30, 30);
    x.strokeStyle = '#241c14'; x.lineWidth = 4;
    x.beginPath(); x.arc(272, 200, 9, -Math.PI / 2, Math.PI / 2); x.stroke();
    x.strokeStyle = 'rgba(226,182,102,0.5)'; x.lineWidth = 1.4;
    x.beginPath(); x.moveTo(240, 189); x.lineTo(266, 189); x.stroke();
    finish(x, rnd, { vig: 0.58, warm: 0.1, cyan: 0.05 });
  }

  /* P-3 — round 7: the minds around one file, from above */
  function sceneSwarm(x) {
    const rnd = mulberry(333);
    x.fillStyle = '#0d0b09'; x.fillRect(0, 0, W, H);
    // table sheen
    glowDot(x, 150, 152, 200, 'rgba(160,120,60,0.14)', 'rgba(160,120,60,0.07)');
    const cx = 150, cy = 150;
    // the deliverable: one bond-paper file in the middle
    x.save(); x.translate(cx, cy); x.rotate(-0.06);
    x.fillStyle = '#e6dcc0'; x.fillRect(-34, -44, 68, 88);
    x.strokeStyle = 'rgba(74,66,52,0.8)'; x.lineWidth = 1;
    for (let i = 0; i < 9; i++) { x.beginPath(); x.moveTo(-26, -32 + i * 9); x.lineTo(26, -32 + i * 9); x.stroke(); }
    x.fillStyle = 'rgba(168,36,27,0.85)'; x.fillRect(-26, -40, 22, 4);
    x.restore();
    // eleven minds in a working ring
    const N = 11;
    for (let i = 0; i < N; i++) {
      const ang = (i / N) * Math.PI * 2 - Math.PI / 2 + (rnd() - 0.5) * 0.18;
      const rad = 96 + rnd() * 26;
      const mx = cx + Math.cos(ang) * rad, my = cy + Math.sin(ang) * rad * 0.86;
      const busy = i !== 4;
      // reach: a faint line from mind to the file
      x.strokeStyle = busy ? 'rgba(214,164,88,0.35)' : 'rgba(200,80,60,0.5)';
      x.lineWidth = busy ? 0.9 : 1.3;
      x.setLineDash(busy ? [] : [3, 3]);
      x.beginPath(); x.moveTo(mx, my);
      x.quadraticCurveTo((mx + cx) / 2 + (rnd() - 0.5) * 16, (my + cy) / 2 + (rnd() - 0.5) * 16, cx, cy);
      x.stroke();
      x.setLineDash([]);
      glowDot(x, mx, my, 18, busy ? 'rgba(240,208,140,0.95)' : 'rgba(235,130,95,0.95)',
        busy ? 'rgba(220,165,80,0.4)' : 'rgba(210,90,60,0.4)');
      x.fillStyle = busy ? 'rgba(255,244,214,0.95)' : 'rgba(255,214,196,0.95)';
      x.fillRect(mx - 2.4, my - 2.4, 4.8, 4.8);
    }
    // chalk circle around the struggling mind (index 4: lower left-ish)
    const ang4 = (4 / N) * Math.PI * 2 - Math.PI / 2;
    const m4x = cx + Math.cos(ang4) * 108, m4y = cy + Math.sin(ang4) * 108 * 0.86;
    x.strokeStyle = 'rgba(238,238,230,0.9)'; x.lineWidth = 2.4; x.lineCap = 'round';
    x.beginPath(); x.ellipse(m4x, m4y, 22, 17, 0.2, 0.2, Math.PI * 2.2); x.stroke();
    x.font = '400 15px "Caveat", cursive'; x.fillStyle = 'rgba(238,238,230,0.9)';
    x.textAlign = 'left';
    x.fillText('stalled. the governor saw it first', 26, 282);
    finish(x, rnd, { vig: 0.62, cyan: 0.06, warm: 0.05, leak: false });
  }

  /* P-4 — the gateway: the only door in */
  function sceneGate(x) {
    const rnd = mulberry(444);
    const wall = x.createLinearGradient(0, 0, 0, H);
    wall.addColorStop(0, '#12100c'); wall.addColorStop(1, '#0a0908');
    x.fillStyle = wall; x.fillRect(0, 0, W, H);
    // brick suggestion
    x.strokeStyle = 'rgba(90,70,50,0.22)'; x.lineWidth = 1;
    for (let r = 0; r < 15; r++) {
      const y = r * 20 + 4;
      x.beginPath(); x.moveTo(0, y); x.lineTo(W, y); x.stroke();
      for (let ccol = 0; ccol < 6; ccol++) {
        const bx = ccol * 50 + (r % 2 ? 25 : 0);
        x.beginPath(); x.moveTo(bx, y); x.lineTo(bx, y + 20); x.stroke();
      }
    }
    // floor
    x.fillStyle = '#0e0c09'; x.fillRect(0, 246, W, 54);
    // the door, ajar, warm light through the gap
    x.save(); x.translate(96, 62);
    x.fillStyle = '#060505'; x.fillRect(0, 0, 108, 186); // dark reveal
    // light spilling through the gap
    const spill = x.createLinearGradient(64, 0, 130, 0);
    spill.addColorStop(0, 'rgba(240,196,110,0.95)'); spill.addColorStop(1, 'rgba(240,196,110,0)');
    x.fillStyle = spill;
    x.beginPath(); x.moveTo(64, 2); x.lineTo(78, 2); x.lineTo(130, 184); x.lineTo(64, 184); x.closePath(); x.fill();
    // door leaf
    const leaf = x.createLinearGradient(0, 0, 64, 0);
    leaf.addColorStop(0, '#241b10'); leaf.addColorStop(1, '#38281506');
    x.fillStyle = '#241b10'; x.fillRect(0, 0, 66, 186);
    x.strokeStyle = 'rgba(150,110,60,0.4)'; x.lineWidth = 2;
    x.strokeRect(6, 8, 54, 80); x.strokeRect(6, 100, 54, 78);
    // knob catching the light
    glowDot(x, 60, 96, 8, 'rgba(250,220,150,1)', 'rgba(240,190,100,0.5)');
    x.restore();
    // light pooling on the floor
    const pool = x.createRadialGradient(176, 258, 4, 176, 258, 90);
    pool.addColorStop(0, 'rgba(238,190,105,0.5)'); pool.addColorStop(1, 'rgba(238,190,105,0)');
    x.fillStyle = pool;
    x.beginPath(); x.ellipse(176, 258, 90, 22, 0, 0, Math.PI * 2); x.fill();
    // the port plate over the door
    x.fillStyle = '#171310'; x.fillRect(118, 34, 64, 20);
    x.strokeStyle = '#c8bfa8'; x.lineWidth = 1.4; x.strokeRect(118, 34, 64, 20);
    x.fillStyle = '#c8bfa8'; x.font = '700 13px "Courier Prime", monospace'; x.textAlign = 'center';
    x.fillText('8787', 150, 49);
    // the key on its nail, beside the door
    x.save(); x.translate(232, 120); x.rotate(0.16);
    x.fillStyle = 'rgba(40,22,6,0.9)';
    x.beginPath(); x.arc(0, -8, 1.6, 0, Math.PI * 2); x.fill(); // nail
    x.strokeStyle = '#b9a263'; x.lineWidth = 3.4; x.lineCap = 'round';
    x.beginPath(); x.arc(0, 0, 7, 0, Math.PI * 2); x.stroke(); // bow
    x.beginPath(); x.moveTo(0, 7); x.lineTo(0, 34); x.stroke(); // shaft
    x.beginPath(); x.moveTo(0, 34); x.lineTo(7, 34); x.moveTo(0, 27); x.lineTo(5, 27); x.stroke(); // bits
    x.restore();
    x.font = '400 14px "Caveat", cursive'; x.fillStyle = 'rgba(238,238,230,0.8)'; x.textAlign = 'left';
    x.fillText('no key, no entry. no exceptions', 88, 288);
    finish(x, rnd, { vig: 0.55, warm: 0.1, cyan: 0.05, leakA: 0.1 });
  }

  /* P-5 — what the crawler brought back */
  function sceneCrawl(x) {
    const rnd = mulberry(555);
    x.fillStyle = '#090b0e'; x.fillRect(0, 0, W, H);
    // the outside: pages strung on threads, receding into dark
    const pages = [];
    for (let i = 0; i < 15; i++) {
      const depth = rnd();
      pages.push({
        x: 22 + rnd() * 256, y: 22 + rnd() * 210,
        w: 16 + (1 - depth) * 22, d: depth
      });
    }
    // link threads: each page to two others
    for (const p of pages) {
      const near = pages.slice().sort((a, b) =>
        (Math.hypot(a.x - p.x, a.y - p.y) - Math.hypot(b.x - p.x, b.y - p.y))).slice(1, 3);
      for (const q of near) {
        x.strokeStyle = 'rgba(150,160,175,' + (0.08 + (1 - (p.d + q.d) / 2) * 0.14) + ')';
        x.lineWidth = 0.7;
        x.beginPath(); x.moveTo(p.x, p.y); x.lineTo(q.x, q.y); x.stroke();
      }
    }
    // the pages
    for (const p of pages) {
      const a = 0.25 + (1 - p.d) * 0.55;
      x.save(); x.translate(p.x, p.y); x.rotate((rnd() - 0.5) * 0.3);
      x.fillStyle = 'rgba(214,206,182,' + a + ')';
      x.fillRect(-p.w / 2, -p.w * 0.65, p.w, p.w * 1.3);
      x.strokeStyle = 'rgba(60,56,48,' + a + ')'; x.lineWidth = 0.8;
      for (let l = 1; l < 5; l++) {
        x.beginPath(); x.moveTo(-p.w / 2 + 2, -p.w * 0.65 + l * p.w * 0.24);
        x.lineTo(p.w / 2 - 2, -p.w * 0.65 + l * p.w * 0.24); x.stroke();
      }
      x.restore();
    }
    // the one that mattered: lit, lower right
    const hx = 216, hy = 206;
    glowDot(x, hx, hy, 54, 'rgba(240,208,140,0.8)', 'rgba(220,165,80,0.35)');
    x.save(); x.translate(hx, hy); x.rotate(-0.08);
    x.fillStyle = '#e9dfc2'; x.fillRect(-20, -26, 40, 52);
    x.strokeStyle = 'rgba(74,66,52,0.9)'; x.lineWidth = 1;
    for (let l = 1; l < 6; l++) { x.beginPath(); x.moveTo(-15, -26 + l * 9); x.lineTo(15, -26 + l * 9); x.stroke(); }
    x.fillStyle = 'rgba(168,36,27,0.9)'; x.fillRect(-15, -22, 14, 3);
    x.restore();
    // the crawl route, dashed red, in from the edge
    x.strokeStyle = 'rgba(179,48,31,0.85)'; x.lineWidth = 1.6; x.setLineDash([5, 4]);
    x.beginPath(); x.moveTo(6, 40);
    x.bezierCurveTo(70, 60, 96, 130, 140, 150);
    x.bezierCurveTo(170, 164, 190, 184, hx - 14, hy - 10);
    x.stroke(); x.setLineDash([]);
    // arrowhead
    x.fillStyle = 'rgba(179,48,31,0.9)';
    x.beginPath(); x.moveTo(hx - 12, hy - 8); x.lineTo(hx - 24, hy - 10); x.lineTo(hx - 16, hy - 20); x.closePath(); x.fill();
    x.font = '400 15px "Caveat", cursive'; x.fillStyle = 'rgba(238,238,230,0.85)'; x.textAlign = 'left';
    x.fillText('quoted verbatim, or it never happened', 18, 282);
    finish(x, rnd, { vig: 0.6, cyan: 0.1, warm: 0.04 });
  }

  const scenes = { hive: sceneHive, desk: sceneDesk, swarm: sceneSwarm, gate: sceneGate, crawl: sceneCrawl };

  window.CC = {
    corkTile,
    paint(canvas, name) {
      canvas.width = W; canvas.height = H;
      const x = canvas.getContext('2d');
      if (scenes[name]) scenes[name](x);
    }
  };
})();
