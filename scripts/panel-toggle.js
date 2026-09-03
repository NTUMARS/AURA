/* AURA — Demonstrated / Emergent tab panels ([data-toggle]).
   Tabs carry data-panel; panels carry data-panel + [hidden]. Hidden panels
   pause their videos; the shown panel's videos are (re)started by lazy-video. */
(function () {
  document.querySelectorAll('[data-toggle]').forEach((group) => {
    const tabs = [...group.querySelectorAll('.toggle__tab')];
    const panels = [...group.querySelectorAll('.toggle__panel')];
    if (tabs.length < 2 || panels.length < 2) return;

    const show = (name) => {
      tabs.forEach((t) => {
        const on = t.dataset.panel === name;
        t.setAttribute('aria-selected', on ? 'true' : 'false');
        t.tabIndex = on ? 0 : -1;
      });
      panels.forEach((p) => {
        const on = p.dataset.panel === name;
        p.hidden = !on;
        p.querySelectorAll('video').forEach((v) => {
          if (on) { if (window.AURA_lazyVideo) window.AURA_lazyVideo.play(v); }
          else v.pause();
        });
      });
    };

    tabs.forEach((t, i) => {
      t.addEventListener('click', () => show(t.dataset.panel));
      t.addEventListener('keydown', (e) => {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
        e.preventDefault();
        const j = (i + (e.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
        tabs[j].focus();
        show(tabs[j].dataset.panel);
      });
    });
  });
})();
