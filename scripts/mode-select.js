/* AURA — segmented mode chips on a video tile.
   [data-mode-tile] holds one <video> and N .mode-pick__btn chips carrying
   data-src / data-poster / optional data-caption / data-badge / data-order.
   Swapping keeps the same <video> element so the control bar and the
   lazy-play observer stay attached. */
(function () {
  const isStatic = document.documentElement.classList.contains('is-static');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  document.querySelectorAll('[data-mode-tile]').forEach((tile) => {
    const video = tile.querySelector('video');
    const btns = [...tile.querySelectorAll('.mode-pick__btn')];
    if (!video || btns.length < 2) return;
    const caption = tile.querySelector('[data-mode-caption]');
    const badge = tile.querySelector('.cmp__badge');
    const order = tile.querySelector('[data-mode-order]');

    const apply = (btn) => {
      btns.forEach((b) => { b.classList.remove('is-active'); b.setAttribute('aria-pressed', 'false'); });
      btn.classList.add('is-active');
      btn.setAttribute('aria-pressed', 'true');
      if (btn.dataset.poster) video.setAttribute('poster', btn.dataset.poster);
      video.setAttribute('src', btn.dataset.src);
      video.load();
      if (caption && btn.dataset.caption !== undefined) caption.innerHTML = btn.dataset.caption;
      if (badge && btn.dataset.badge !== undefined) { badge.textContent = btn.dataset.badge; badge.hidden = !btn.dataset.badge; }
      if (order && btn.dataset.order !== undefined) {
        order.innerHTML = btn.dataset.order.split(',').map((s) => `<i>${s.trim()}</i>`).join('');
      }
      if (!isStatic && !reduce) video.play().catch(() => {});
    };

    btns.forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (btn.classList.contains('is-active')) return;
        apply(btn);
      });
    });
  });
})();
