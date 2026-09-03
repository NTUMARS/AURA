/* AURA — per-tile control bar for every .cmp__media[data-controls]:
   play/pause, draggable progress, elapsed / total, speed cycle.
   Playback is started/stopped by lazy-video.js; speed-ups are baked into the
   files, so the default rate is 1× (override with data-rate). */
(function () {
  const tiles = document.querySelectorAll('.cmp__media[data-controls]');
  if (!tiles.length) return;
  const SPEEDS = [1, 1.5, 2];

  const fmt = (t) => {
    if (!isFinite(t) || t < 0) return '0:00';
    const m = Math.floor(t / 60), s = Math.floor(t % 60).toString().padStart(2, '0');
    return `${m}:${s}`;
  };
  const label = (r) => (Number.isInteger(r) ? r : r.toFixed(1)) + '×';

  tiles.forEach((media) => {
    const video = media.querySelector('video');
    if (!video) return;
    let rate = parseFloat(media.dataset.rate || '1') || 1;
    const applyRate = () => { try { video.playbackRate = rate; } catch (e) {} };
    video.addEventListener('loadedmetadata', applyRate);
    video.addEventListener('play', applyRate);

    const ctrl = document.createElement('div');
    ctrl.className = 'cmp__ctrl';
    ctrl.innerHTML =
      '<button class="cmp__pp" type="button" aria-label="Play / pause"></button>' +
      '<div class="cmp__scrub" role="slider" tabindex="0" aria-label="Seek" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">' +
        '<div class="cmp__scrub-fill"></div><div class="cmp__scrub-thumb"></div>' +
      '</div>' +
      '<span class="cmp__time">0:00</span>' +
      '<button class="cmp__speed" type="button" aria-label="Playback speed">' + label(rate) + '</button>';
    media.appendChild(ctrl);

    const pp = ctrl.querySelector('.cmp__pp');
    const scrub = ctrl.querySelector('.cmp__scrub');
    const fill = ctrl.querySelector('.cmp__scrub-fill');
    const thumb = ctrl.querySelector('.cmp__scrub-thumb');
    const timeEl = ctrl.querySelector('.cmp__time');
    const speedBtn = ctrl.querySelector('.cmp__speed');

    const syncPP = () => {
      media.classList.toggle('is-playing', !video.paused);
      media.classList.toggle('is-paused', video.paused);
    };
    video.addEventListener('play', syncPP);
    video.addEventListener('pause', syncPP);
    syncPP();

    const toggle = () => {
      if (video.paused) video.play().then(() => media.classList.remove('is-blocked')).catch(() => {});
      else video.pause();
    };
    pp.addEventListener('click', (e) => { e.stopPropagation(); toggle(); });
    media.addEventListener('click', (e) => { if (e.target.closest('.cmp__ctrl')) return; toggle(); });

    const paint = () => {
      if (!isFinite(video.duration) || video.duration === 0) return;
      const pct = (video.currentTime / video.duration) * 100;
      fill.style.width = pct + '%';
      thumb.style.left = pct + '%';
      timeEl.textContent = `${fmt(video.currentTime)} / ${fmt(video.duration)}`;
      scrub.setAttribute('aria-valuenow', String(Math.round(pct)));
    };
    video.addEventListener('timeupdate', paint);
    video.addEventListener('loadedmetadata', paint);

    let wasPlaying = false;
    const seekTo = (clientX) => {
      const r = scrub.getBoundingClientRect();
      const x = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
      if (isFinite(video.duration)) video.currentTime = x * video.duration;
    };
    scrub.addEventListener('pointerdown', (e) => {
      e.preventDefault(); e.stopPropagation();
      wasPlaying = !video.paused; video.pause();
      media.classList.add('is-scrubbing');
      seekTo(e.clientX);
      const move = (ev) => seekTo(ev.clientX);
      const up = () => {
        media.classList.remove('is-scrubbing');
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', up);
        if (wasPlaying) video.play().catch(() => {});
      };
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', up);
    });
    scrub.addEventListener('keydown', (e) => {
      if (!isFinite(video.duration)) return;
      if (e.key === 'ArrowLeft') { e.preventDefault(); video.currentTime = Math.max(0, video.currentTime - 2); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); video.currentTime = Math.min(video.duration, video.currentTime + 2); }
      else if (e.key === ' ') { e.preventDefault(); toggle(); }
    });

    speedBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const i = SPEEDS.indexOf(rate);
      rate = SPEEDS[(i + 1) % SPEEDS.length];
      applyRate();
      speedBtn.textContent = label(rate);
    });
  });
})();
