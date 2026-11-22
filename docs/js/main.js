/* nl-veil docs — page shell: reveals, platform detection, scroll spy.
   The page is light only (garrett-mode.css). */
(function () {
  'use strict';

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const root = document.documentElement;

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
