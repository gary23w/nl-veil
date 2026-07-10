/* FILE NL-VEIL — load choreography, scroll reveals, grease-pencil circles. */
(function () {
  'use strict';

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // "click" is a mouse word — fingers tap
  const hintVerb = document.getElementById('hintVerb');
  if (hintVerb && window.matchMedia('(pointer: coarse)').matches) hintVerb.textContent = 'TAP';

  // ---- the veil persona: pull the cord to darken the reading room ----
  const cord = document.getElementById('veilCord');
  const cordLabel = document.getElementById('veilCordLabel');
  const root = document.documentElement;
  function paintCord() {
    const on = root.hasAttribute('data-veil');
    if (cord) {
      cord.setAttribute('aria-pressed', String(on));
      cord.setAttribute('aria-label', on ? 'Leave the veil — back to the reading room' : 'Enter the veil — a darker reading room');
    }
    if (cordLabel) cordLabel.textContent = on ? 'LEAVE THE VEIL' : 'ENTER THE VEIL';
  }
  paintCord();
  if (cord) {
    cord.addEventListener('click', () => {
      const on = root.toggleAttribute('data-veil');
      try { localStorage.setItem('nl-veil-persona', on ? 'veil' : 'file'); } catch (e) {}
      paintCord();
    });
  }

  // load sequence
  requestAnimationFrame(() => {
    requestAnimationFrame(() => document.body.classList.add('loaded'));
  });

  // scroll reveals
  const revealables = document.querySelectorAll('.reveal');
  if (reduceMotion) {
    revealables.forEach((el) => el.classList.add('in'));
  } else {
    const io = new IntersectionObserver((entries) => {
      for (const en of entries) {
        if (en.isIntersecting) {
          en.target.classList.add('in');
          io.unobserve(en.target);
        }
      }
    }, { threshold: 0.12, rootMargin: '0px 0px -48px 0px' });
    revealables.forEach((el) => io.observe(el));
  }

  // grease-pencil circles on the flagged rounds
  const CIRCLE_PATH = 'M18,34 C12,16 58,6 96,9 C134,12 152,24 148,38 C144,52 100,58 62,55 C28,52 12,44 22,28 C30,15 70,8 108,12';
  document.querySelectorAll('.tl-entry[data-circle]').forEach((entry) => {
    const timeEl = entry.querySelector('.tl-time');
    if (!timeEl) return;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'tl-circle');
    svg.setAttribute('viewBox', '0 0 164 64');
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', CIRCLE_PATH);
    svg.appendChild(path);
    timeEl.appendChild(svg);
    const len = path.getTotalLength();
    path.style.strokeDasharray = String(len);
    if (reduceMotion) {
      path.style.strokeDashoffset = '0';
    } else {
      path.style.strokeDashoffset = String(len);
      path.style.transition = 'stroke-dashoffset 1.1s cubic-bezier(.5,.1,.3,1) .35s';
      const io2 = new IntersectionObserver((entries) => {
        for (const en of entries) {
          if (en.isIntersecting) {
            path.style.strokeDashoffset = '0';
            io2.disconnect();
          }
        }
      }, { threshold: 0.4 });
      io2.observe(entry);
    }
  });
})();
