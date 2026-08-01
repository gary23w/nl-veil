/* nl-veil docs — page shell: theme, reveals, platform detection, scroll spy.
   The theme cycle mirrors the product: the three built-ins the desk compiles in
   (theme.zig initThemes) in the same order, persisted under the same key the
   web client uses so a reader who flips to dark here lands in dark there. */
(function () {
  'use strict';

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const root = document.documentElement;

  /* ---------------- theme ---------------- */
  const THEMES = [
    { id: 'light',  name: 'Light',       chrome: '#e9edf5' },
    { id: 'dark',   name: 'Tokyo Night', chrome: '#16161e' },
    { id: 'matrix', name: 'Matrix',      chrome: '#030a03' }
  ];
  const ICONS = {
    // sun / moon / terminal — the same stroke language as the app's icon set
    light:  '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4"/></svg>',
    dark:   '<svg viewBox="0 0 24 24"><path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11z"/></svg>',
    matrix: '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M13 15h4"/></svg>'
  };

  const themeBtn = document.getElementById('themeBtn');

  function currentTheme() { return root.getAttribute('data-theme') || 'light'; }

  function setTheme(id) {
    const t = THEMES.find((x) => x.id === id) || THEMES[0];
    root.setAttribute('data-theme', t.id);
    try { localStorage.setItem('veil.theme', t.id); } catch (e) {}
    // one theme-color meta, rewritten — the media-query pair in <head> only
    // covers the unset case, and an explicit choice has to beat it
    document.querySelectorAll('meta[name=theme-color]').forEach((m) => m.remove());
    const meta = document.createElement('meta');
    meta.name = 'theme-color';
    meta.content = t.chrome;
    document.head.appendChild(meta);
    if (themeBtn) {
      themeBtn.innerHTML = ICONS[t.id];
      themeBtn.title = 'Theme: ' + t.name + ' (click to cycle)';
      themeBtn.setAttribute('aria-label', 'Theme: ' + t.name + '. Click to cycle.');
    }
    // the map paints its links on a canvas, so a palette change has to be
    // repainted by hand — CSS cannot reach inside a 2D context
    if (window.VeilMap) window.VeilMap.repaint();
  }

  setTheme(currentTheme());
  if (themeBtn) {
    themeBtn.addEventListener('click', () => {
      const i = THEMES.findIndex((x) => x.id === currentTheme());
      setTheme(THEMES[(i + 1) % THEMES.length].id);
    });
  }

  /* ---------------- scroll reveals ---------------- */
  const revealables = document.querySelectorAll('.reveal');
  if (reduceMotion) {
    revealables.forEach((el) => el.classList.add('in'));
  } else {
    const io = new IntersectionObserver((entries) => {
      for (const en of entries) {
        if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); }
      }
    }, { threshold: 0.12, rootMargin: '0px 0px -48px 0px' });
    revealables.forEach((el) => io.observe(el));
  }

  /* ---------------- platform detection ----------------
     Purely additive: every card stays visible and every link stays live, so a
     wrong guess (or no guess) costs nobody a download. */
  (() => {
    const grid = document.getElementById('dlGrid');
    if (!grid) return;
    const ua = navigator.userAgent || '';
    const plat = navigator.platform || '';
    let os = null, label = '';
    if (/Win/i.test(plat) || /Windows/i.test(ua)) { os = 'win'; label = 'for Windows'; }
    // Apple Silicon still reports as Intel in the UA and userAgentData is no
    // better, so Macs guess arm64 (the majority now). Both mac cards sit right
    // there, so a miss is a glance, not a dead end.
    else if (/Mac/i.test(plat) || /Mac OS X/i.test(ua)) { os = 'macarm'; label = 'for macOS'; }
    else if (/Linux/i.test(plat) && !/Android/i.test(ua)) { os = 'linux'; label = 'for Linux'; }
    const card = os && grid.querySelector('.dl-card[data-os="' + os + '"]');
    if (!card) return;
    card.classList.add('is-yours');
    const badge = document.createElement('span');
    badge.className = 'dl-yours';
    badge.textContent = 'your machine';
    card.appendChild(badge);
    const heroBtn = document.querySelector('.hero-cta .btn-solid');
    if (heroBtn && label) heroBtn.appendChild(document.createTextNode(' ' + label));
  })();

  /* ---------------- nav scroll spy ---------------- */
  (() => {
    const links = Array.from(document.querySelectorAll('.nav a[href^="#"]'));
    if (!links.length) return;
    const targets = links
      .map((a) => ({ a, el: document.getElementById(a.getAttribute('href').slice(1)) }))
      .filter((x) => x.el);
    if (!targets.length) return;
    let active = null;
    const spy = new IntersectionObserver((entries) => {
      for (const en of entries) {
        if (!en.isIntersecting) continue;
        const hit = targets.find((t) => t.el === en.target);
        if (!hit || hit === active) continue;
        if (active) active.a.classList.remove('active');
        hit.a.classList.add('active');
        active = hit;
      }
    }, { rootMargin: '-45% 0px -50% 0px' });
    targets.forEach((t) => spy.observe(t.el));
  })();
})();
