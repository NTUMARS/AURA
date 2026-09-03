/* AURA — reveal-on-scroll for [data-reveal] and count-up for [data-count-to].
   Markup carries the final number, so crawlers, print and static mode read the
   real value; JS only animates from zero when it is allowed to. */
(function () {
  const root = document.documentElement;
  const isStatic = root.classList.contains('is-static');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const targets = document.querySelectorAll('[data-reveal]');

  if (reduce || isStatic || !('IntersectionObserver' in window)) {
    targets.forEach((el) => el.classList.add('is-in'));
    return;
  }

  const io = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-in');
        io.unobserve(entry.target);
      }
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  targets.forEach((el) => io.observe(el));

  const countNodes = document.querySelectorAll('[data-count-to]');
  countNodes.forEach((n) => {
    const decimals = parseInt(n.dataset.countDecimals || '0', 10);
    n.textContent = (0).toFixed(decimals);
  });
  const countIO = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      const node = entry.target;
      const target = parseFloat(node.dataset.countTo);
      const decimals = parseInt(node.dataset.countDecimals || '0', 10);
      const duration = 1400;
      const start = performance.now();
      function tick(now) {
        const t = Math.min(1, (now - start) / duration);
        const eased = 1 - Math.pow(1 - t, 3);
        node.textContent = (target * eased).toFixed(decimals);
        if (t < 1) requestAnimationFrame(tick);
        else node.textContent = target.toFixed(decimals);
      }
      requestAnimationFrame(tick);
      countIO.unobserve(node);
    });
  }, { threshold: 0.4 });
  countNodes.forEach((n) => countIO.observe(n));
})();
