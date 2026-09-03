/* AURA — play-in-view / pause-off-screen for every video[data-autoplay].
   Caps concurrent players (mobile decoders blank out beyond ~6 streams). */
(function () {
  const root = document.documentElement;
  const isStatic = root.classList.contains('is-static');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const videos = [...document.querySelectorAll('video[data-autoplay]')];
  if (!videos.length) return;

  const MAX_ACTIVE = 6;
  const active = []; // most-recently-entered last

  videos.forEach((v) => { v.muted = true; v.playsInline = true; v.defaultMuted = true; });

  function play(v) {
    if (isStatic || reduce) return;
    if (v.closest('[hidden]')) return;
    if (!active.includes(v)) active.push(v);
    while (active.length > MAX_ACTIVE) {
      const old = active.shift();
      if (old !== v) old.pause();
    }
    const p = v.play();
    if (p && p.catch) {
      p.then(() => { const m = v.closest('.cmp__media'); if (m) m.classList.remove('is-blocked'); })
       .catch(() => { const m = v.closest('.cmp__media'); if (m) m.classList.add('is-blocked'); });
    }
  }
  function pause(v) {
    const i = active.indexOf(v);
    if (i > -1) active.splice(i, 1);
    v.pause();
  }

  if (!('IntersectionObserver' in window)) { videos.forEach(play); return; }

  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { e.isIntersecting ? play(e.target) : pause(e.target); });
  }, { rootMargin: '160px 0px', threshold: 0.2 });
  videos.forEach((v) => io.observe(v));

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) active.slice().forEach((v) => v.pause());
    else active.slice().forEach((v) => v.play().catch(() => {}));
  });

  // let other modules request a (re)start after they swap sources or panels
  window.AURA_lazyVideo = { play, pause };
})();
