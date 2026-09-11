/* AURA — hero mosaic: four real-robot cells, each rotating through a pool of
   clips with a two-layer crossfade (the next clip is buffered on the back
   layer before the switch). Playback is self-managed — the layers carry no
   data-autoplay, because lazy-video.js's player cap would evict the mosaic's
   own front layers mid-fade. Pool entries (data-pool JSON):
     clip, poster, tag [, badge, tone, href, go, aria, dwell (ms; 0 = play to
     the end), start (s), pos (object-position)]
   Exposes window.AURA_mosaic for tests. */
(function () {
  const root = document.documentElement;
  const isStatic = root.classList.contains('is-static');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const cells = [];
  window.AURA_mosaic = { cells };

  document.querySelectorAll('[data-mosaic]').forEach((box) => {
    const dwellDefault = parseInt(box.dataset.dwell || '12000', 10);
    const shared = { busyUntil: 0 };   // one crossfade at a time across the whole mosaic

    [...box.querySelectorAll('[data-mosaic-cell]')].forEach((cell, k) => {
      let pool = [];
      try { pool = JSON.parse(cell.dataset.pool || '[]'); } catch (e) { pool = []; }
      const layers = [...cell.querySelectorAll('.mosaic__layer')];
      const tag = cell.querySelector('[data-mosaic-tag]');
      const badge = cell.querySelector('[data-mosaic-badge]');
      const goText = cell.querySelector('[data-mosaic-go-text]');
      if (!pool.length || layers.length < 2) return;
      const cellHref = cell.getAttribute('href') || '#';
      layers.forEach((v) => { v.muted = true; v.defaultMuted = true; v.playsInline = true; v.loop = pool.length === 1; });

      let front = 0, idx = 0, timer = 0, guard = 0, inView = false, switching = false, started = false;

      const apply = (e) => {
        if (tag) { tag.textContent = e.tag || ''; if (e.tone) tag.dataset.tone = e.tone; else delete tag.dataset.tone; }
        if (badge) { badge.textContent = e.badge || ''; badge.hidden = !e.badge; }
        if (goText) goText.textContent = e.go || '';
        cell.setAttribute('href', e.href || cellHref);
        if (e.aria) cell.setAttribute('aria-label', e.aria);
      };

      const prefetch = (i) => {
        const e = pool[i];
        const back = layers[1 - front];
        if (back.getAttribute('src') !== e.clip) {
          back.setAttribute('poster', e.poster);
          back.style.objectPosition = e.pos || '';
          back.preload = 'auto';
          back.setAttribute('src', e.clip);
          back.load();
        }
      };

      const dwellOf = (e) => (e.dwell === 0 ? Infinity : (e.dwell || dwellDefault));

      const arm = (extra = 0) => {
        clearTimeout(timer); timer = 0;
        if (!inView || pool.length < 2) return;
        const d = dwellOf(pool[idx]);
        if (isFinite(d)) timer = setTimeout(next, d + extra);
        prefetch((idx + 1) % pool.length);
      };

      const next = () => {
        if (switching || !inView || pool.length < 2) return;
        const wait = shared.busyUntil - Date.now();
        if (wait > 0) { clearTimeout(timer); timer = setTimeout(next, wait + 60); return; }
        show((idx + 1) % pool.length);
      };

      const show = (i) => {
        const e = pool[i];
        const back = layers[1 - front], fv = layers[front];
        switching = true;
        shared.busyUntil = Date.now() + 900;
        prefetch(i);
        const go = () => {
          back.removeEventListener('canplay', go);
          clearTimeout(guard);
          try { back.currentTime = e.start || 0; } catch (err) { /* not seekable yet */ }
          const swap = () => {
            idx = i; apply(e);
            back.classList.add('is-front'); fv.classList.remove('is-front');
            back.removeAttribute('aria-hidden'); fv.setAttribute('aria-hidden', 'true');
            setTimeout(() => { if (fv !== layers[front]) fv.pause(); }, 450);
            front = 1 - front;
            switching = false;
            arm();
          };
          const p = back.play();
          if (p && p.then) p.then(swap).catch(() => { swap(); });
          else swap();
        };
        // a stalled download must not freeze the cell: give up on this switch and re-arm
        guard = setTimeout(() => { back.removeEventListener('canplay', go); switching = false; arm(); }, 8000);
        if (back.readyState >= 3) go(); else back.addEventListener('canplay', go);
      };

      const play = (v) => {
        const p = v.play();
        if (p && p.catch) p.then(() => cell.classList.remove('is-blocked')).catch(() => cell.classList.add('is-blocked'));
      };
      const resume = () => { const fv = layers[front]; if (fv.getAttribute('src')) play(fv); arm(); };
      const pauseAll = () => { clearTimeout(timer); timer = 0; layers.forEach((v) => v.pause()); };
      const begin = () => { started = true; apply(pool[0]); play(layers[front]); arm(k * 1200); };   // stagger first switches

      layers.forEach((v) => v.addEventListener('ended', () => { if (v === layers[front] && !switching) next(); }));

      cells.push({
        cell,
        get idx() { return idx; }, get front() { return front; },
        get playing() { return !layers[front].paused && !layers[front].ended; },
        retry: () => { if (inView && layers[front].paused) play(layers[front]); },
      });

      if (isStatic || reduce) { apply(pool[0]); return; }

      if ('IntersectionObserver' in window) {
        new IntersectionObserver((entries) => {
          entries.forEach((en) => {
            inView = en.isIntersecting;
            if (inView) { if (!started) begin(); else resume(); }
            else pauseAll();
          });
        }, { threshold: 0.25, rootMargin: '80px 0px' }).observe(cell);
      } else {
        inView = true; begin();
      }
      document.addEventListener('visibilitychange', () => { if (document.hidden) pauseAll(); else if (inView) resume(); });
    });

    // a user gesture unlocks playback where autoplay was refused (Low Power Mode, Data Saver)
    box.addEventListener('pointerdown', () => cells.forEach((c) => c.retry()), { passive: true });
  });
})();
