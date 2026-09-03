/* AURA — one scroll-spy for the nav links and the hero film strip.
   section[data-spy-section] → every [data-spy-for="<id>"] gets .is-active. */
(function () {
  const sections = [...document.querySelectorAll('[data-spy-section]')];
  const marks = [...document.querySelectorAll('[data-spy-for]')];
  if (!sections.length || !marks.length || !('IntersectionObserver' in window)) return;

  const setActive = (id) => {
    marks.forEach((m) => {
      const on = m.dataset.spyFor === id;
      m.classList.toggle('is-active', on);
      if (on) m.setAttribute('aria-current', 'location'); else m.removeAttribute('aria-current');
    });
  };

  const visible = new Map();
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => visible.set(e.target, e.isIntersecting ? e.intersectionRatio : 0));
    let best = null, bestTop = Infinity;
    sections.forEach((s) => {
      if (!visible.get(s)) return;
      const top = Math.abs(s.getBoundingClientRect().top);
      if (top < bestTop) { bestTop = top; best = s; }
    });
    if (best) setActive(best.id);
  }, { rootMargin: '-35% 0px -55% 0px', threshold: [0, 0.01, 0.2] });
  sections.forEach((s) => io.observe(s));
})();
