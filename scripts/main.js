/* AURA — bootstrap: Lenis smooth scroll + nav scrolled state. */
(function () {
  const root = document.documentElement;
  const isStatic = root.classList.contains('is-static');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // --- Lenis smooth scroll ---------------------------------------------
  function initLenis() {
    if (typeof Lenis === 'undefined' || reduce || isStatic) return;
    const lenis = new Lenis({
      lerp: 0.08,
      wheelMultiplier: 1.0,
      smoothWheel: true,
      prevent: (node) => !!(node.closest && node.closest('[data-lenis-prevent]')),
    });
    window.__lenis = lenis;
    function raf(time) { lenis.raf(time); requestAnimationFrame(raf); }
    requestAnimationFrame(raf);
  }
  window.addEventListener('load', initLenis);

  // --- anchor links: smooth scroll (Lenis) or native with nav offset ----
  const navH = () => parseInt(getComputedStyle(root).getPropertyValue('--nav-height'), 10) || 60;
  document.querySelectorAll('a[href^="#"]').forEach((a) => {
    const href = a.getAttribute('href');
    if (!href || href === '#') return;
    a.addEventListener('click', (e) => {
      const target = document.querySelector(href);
      if (!target) return;
      e.preventDefault();
      if (window.__lenis) {
        window.__lenis.scrollTo(target, { offset: -(navH() + 8), duration: 1.1 });
      } else {
        const y = target.getBoundingClientRect().top + window.scrollY - navH() - 8;
        window.scrollTo({ top: y, behavior: reduce ? 'auto' : 'smooth' });
      }
      history.replaceState(null, '', href);
    });
  });

  // --- nav: solid once the page has moved ------------------------------
  const nav = document.querySelector('.nav');
  if (nav) {
    const sync = () => nav.classList.toggle('is-scrolled', window.scrollY > 24);
    window.addEventListener('scroll', sync, { passive: true });
    sync();
  }
})();
