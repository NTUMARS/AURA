/* MARS Policy — top scroll progress bar (Apple-style, hair-thin).
   Replaces the v2 right-edge dot rail. */

(function () {
  const bar = document.createElement('div');
  bar.className = 'scroll-bar';
  bar.setAttribute('aria-hidden', 'true');
  document.body.appendChild(bar);

  let raf = 0;
  function update() {
    raf = 0;
    const max = document.documentElement.scrollHeight - window.innerHeight;
    const pct = max > 0 ? (window.scrollY / max) * 100 : 0;
    bar.style.width = pct.toFixed(2) + '%';
  }
  function onScroll() {
    if (raf) return;
    raf = requestAnimationFrame(update);
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll);
  update();
})();
