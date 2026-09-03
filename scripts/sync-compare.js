/* AURA — lockstep dual player ([data-sync]).
   Two <video data-sync-video="a|b"> play together from a shared play button
   and scrubber. The timeline is the longer clip; the shorter one holds its
   last frame, and the pair restarts together. Drift is corrected softly
   (rate nudge) or by a hard seek when it grows. */
(function () {
  const root = document.documentElement;
  const isStatic = root.classList.contains('is-static');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const fmt = (t) => {
    if (!isFinite(t) || t < 0) return '0:00';
    const m = Math.floor(t / 60), s = Math.floor(t % 60).toString().padStart(2, '0');
    return `${m}:${s}`;
  };

  document.querySelectorAll('[data-sync]').forEach((rootEl) => {
    const vids = [...rootEl.querySelectorAll('video[data-sync-video]')];
    if (vids.length !== 2) return;
    vids.forEach((v) => { v.muted = true; v.playsInline = true; v.defaultMuted = true; v.loop = false; });

    const pp = rootEl.querySelector('.sync__pp');
    const scrub = rootEl.querySelector('.sync__scrub');
    const fill = rootEl.querySelector('.sync__fill');
    const thumb = rootEl.querySelector('.sync__thumb');
    const timeEl = rootEl.querySelector('.sync__time');
    const speedBtn = rootEl.querySelector('.sync__speed');
    const restartBtn = rootEl.querySelector('.sync__restart');
    const clocks = vids.map((v) => v.closest('.sync__pane')?.querySelector('.sync__clock'));
    const SPEEDS = [1, 1.5, 2];
    let rate = 1;
    let master = vids[0], slave = vids[1];
    let wantPlaying = false;
    let rafId = 0, lastCheck = 0;

    const durations = () => vids.map((v) => (isFinite(v.duration) ? v.duration : 0));
    const pickMaster = () => {
      const d = durations();
      if (d[1] > d[0]) { master = vids[1]; slave = vids[0]; } else { master = vids[0]; slave = vids[1]; }
    };
    const setRate = () => vids.forEach((v) => { try { v.playbackRate = rate; } catch (e) {} });
    const setPlayingClass = () => rootEl.classList.toggle('is-playing', wantPlaying);

    const paint = () => {
      const D = master.duration;
      if (!isFinite(D) || D === 0) return;
      const t = master.currentTime;
      const pct = (t / D) * 100;
      fill.style.width = pct + '%';
      thumb.style.left = pct + '%';
      timeEl.textContent = `${fmt(t)} / ${fmt(D)}`;
      scrub.setAttribute('aria-valuenow', String(Math.round(pct)));
      vids.forEach((v, i) => {
        const c = clocks[i]; if (!c) return;
        const done = v.ended || (isFinite(v.duration) && v.currentTime >= v.duration - 0.05);
        c.innerHTML = done ? `<b>done</b> · ${fmt(v.duration)}` : `<b>${fmt(v.currentTime)}</b>`;
        c.classList.toggle('is-done', done);
      });
    };

    const playBoth = async () => {
      wantPlaying = true; setPlayingClass();
      setRate();
      try {
        await Promise.all(vids.map((v) => (v.ended ? Promise.resolve() : v.play())));
        rootEl.classList.remove('is-blocked');
      } catch (e) {
        wantPlaying = false; setPlayingClass();
        rootEl.classList.add('is-blocked');
      }
      loop();
    };
    const pauseBoth = () => { wantPlaying = false; setPlayingClass(); vids.forEach((v) => v.pause()); cancelAnimationFrame(rafId); paint(); };
    const seekBoth = (t) => {
      vids.forEach((v) => {
        const d = isFinite(v.duration) ? v.duration : 0;
        v.currentTime = Math.min(Math.max(0, t), Math.max(0, d - 0.05));
      });
      paint();
    };
    const restart = () => { seekBoth(0); if (!wantPlaying) playBoth(); else vids.forEach((v) => v.play().catch(() => {})); };

    function loop(now) {
      if (!wantPlaying) return;
      rafId = requestAnimationFrame(loop);
      paint();
      if (!now || now - lastCheck < 250) return;
      lastCheck = now;
      if (master.ended) { restart(); return; }
      if (slave.ended || slave.paused) return;
      const d = slave.currentTime - master.currentTime;
      const ad = Math.abs(d);
      if (ad > 0.14) { slave.currentTime = master.currentTime; slave.playbackRate = rate; }
      else if (ad > 0.03) { slave.playbackRate = rate * (d > 0 ? 0.95 : 1.05); }
      else slave.playbackRate = rate;
    }

    vids.forEach((v) => {
      v.addEventListener('loadedmetadata', () => { pickMaster(); paint(); });
      v.addEventListener('waiting', () => rootEl.classList.add('is-stalled'));
      v.addEventListener('playing', () => rootEl.classList.remove('is-stalled'));
    });
    pickMaster();

    pp.addEventListener('click', () => (wantPlaying ? pauseBoth() : playBoth()));
    rootEl.querySelectorAll('.sync__pane .cmp__media').forEach((m) => m.addEventListener('click', () => (wantPlaying ? pauseBoth() : playBoth())));
    if (restartBtn) restartBtn.addEventListener('click', restart);
    if (speedBtn) speedBtn.addEventListener('click', () => {
      rate = SPEEDS[(SPEEDS.indexOf(rate) + 1) % SPEEDS.length];
      setRate();
      speedBtn.textContent = (Number.isInteger(rate) ? rate : rate.toFixed(1)) + '×';
    });

    const seekFromX = (clientX) => {
      const r = scrub.getBoundingClientRect();
      const x = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
      if (isFinite(master.duration)) seekBoth(x * master.duration);
    };
    scrub.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      const was = wantPlaying; if (was) pauseBoth();
      seekFromX(e.clientX);
      const move = (ev) => seekFromX(ev.clientX);
      const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); if (was) playBoth(); };
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', up);
    });
    scrub.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowLeft') { e.preventDefault(); seekBoth(master.currentTime - 2); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); seekBoth(master.currentTime + 2); }
      else if (e.key === ' ') { e.preventDefault(); wantPlaying ? pauseBoth() : playBoth(); }
    });

    // autostart in view, pause off-screen; warm the buffers just before arrival
    if (!isStatic && !reduce && 'IntersectionObserver' in window) {
      let userPaused = false;
      pp.addEventListener('click', () => { userPaused = !wantPlaying; });
      new IntersectionObserver((entries) => {
        entries.forEach((en) => {
          if (en.isIntersecting) { if (!userPaused && !wantPlaying) playBoth(); }
          else if (wantPlaying) pauseBoth();
        });
      }, { rootMargin: '120px 0px', threshold: 0.3 }).observe(rootEl);
      new IntersectionObserver((entries, obs) => {
        entries.forEach((en) => { if (en.isIntersecting) { vids.forEach((v) => { v.preload = 'auto'; }); obs.disconnect(); } });
      }, { rootMargin: '600px 0px' }).observe(rootEl);
      document.addEventListener('visibilitychange', () => { if (document.hidden && wantPlaying) pauseBoth(); });
    }
    paint();
  });
})();
