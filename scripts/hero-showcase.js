/* AURA — hero showcase: one frame, four real-robot rollouts, chapter chips.
   Two stacked <video> layers crossfade; the next clip is buffered before the
   switch; a chip click switches at once; everything pauses off-screen. */
(function () {
  const root = document.documentElement;
  const isStatic = root.classList.contains('is-static');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  document.querySelectorAll('[data-showcase]').forEach((box) => {
    const layers = [...box.querySelectorAll('.showcase__layer')];
    const chips = [...box.querySelectorAll('.showcase__chip')];
    const tag = box.querySelector('[data-showcase-tag]');
    const badge = box.querySelector('[data-showcase-badge]');
    if (layers.length < 2 || !chips.length) return;

    const dwell = parseInt(box.dataset.dwell || '8000', 10);
    box.style.setProperty('--dwell', dwell + 'ms');
    layers.forEach((v) => { v.muted = true; v.playsInline = true; v.defaultMuted = true; v.loop = false; });

    let front = 0;         // index of the visible layer
    let current = -1;      // active chip index
    let timer = 0;
    let inView = false;
    let switching = false;

    const clipOf = (i) => chips[i].dataset;

    const setChip = (i) => {
      chips.forEach((c, k) => {
        const on = k === i;
        c.classList.toggle('is-active', on);
        c.setAttribute('aria-pressed', on ? 'true' : 'false');
        c.classList.remove('is-hold');
        if (on) { c.classList.add('is-hold'); void c.offsetWidth; c.classList.remove('is-hold'); }
      });
      const d = clipOf(i);
      if (tag) tag.textContent = d.tag || '';
      if (badge) { badge.textContent = d.badge || ''; badge.hidden = !d.badge; }
    };

    const arm = () => {
      clearTimeout(timer);
      if (!inView || isStatic || reduce) return;
      timer = setTimeout(() => show((current + 1) % chips.length), dwell);
    };

    const show = (i, { immediate = false } = {}) => {
      if (i === current && !immediate) return;
      const d = clipOf(i);
      const back = layers[1 - front];
      const fv = layers[front];
      switching = true;
      current = i;
      setChip(i);
      back.setAttribute('poster', d.poster);
      if (back.getAttribute('src') !== d.clip) { back.setAttribute('src', d.clip); back.load(); }
      else back.currentTime = 0;
      const go = () => {
        back.removeEventListener('canplay', go);
        back.currentTime = 0;
        const p = back.play();
        const swap = () => {
          back.classList.add('is-front');
          fv.classList.remove('is-front');
          back.removeAttribute('aria-hidden');
          fv.setAttribute('aria-hidden', 'true');
          setTimeout(() => { if (fv !== layers[front]) fv.pause(); }, 450);
          front = 1 - front;
          switching = false;
          arm();
        };
        if (p && p.then) p.then(swap).catch(() => { swap(); });
        else swap();
      };
      if (isStatic || reduce) { setChip(i); return; }
      if (back.readyState >= 3) go(); else back.addEventListener('canplay', go);
    };

    // a clip that ends before the dwell elapses advances at once
    layers.forEach((v) => v.addEventListener('ended', () => { if (v === layers[front] && !switching) show((current + 1) % chips.length); }));

    chips.forEach((c, i) => c.addEventListener('click', () => show(i, { immediate: true })));

    const pauseAll = () => { clearTimeout(timer); layers.forEach((v) => v.pause()); };
    const resume = () => {
      if (isStatic || reduce) return;
      const fv = layers[front];
      if (fv.getAttribute('src')) fv.play().catch(() => {});
      arm();
    };

    if ('IntersectionObserver' in window && !isStatic && !reduce) {
      new IntersectionObserver((entries) => {
        entries.forEach((e) => {
          inView = e.isIntersecting;
          if (inView) { if (current < 0) show(0, { immediate: true }); else resume(); }
          else pauseAll();
        });
      }, { threshold: 0.25 }).observe(box);
      document.addEventListener('visibilitychange', () => { if (document.hidden) pauseAll(); else if (inView) resume(); });
    } else {
      setChip(0); current = 0;
    }
  });
})();
