/* AURA — live uncertainty plate ([data-live]).
   A Push-T rollout plays beside a chart that draws the paper's inferred
   uncertainty profile (Fig. 7B) progressively: at clip progress t/T the
   curve is drawn up to the aligned progress p, with a head marker and a
   live read-out. The curve is a pure function of p, so pausing, scrubbing
   and looping all stay consistent. Data: assets/data/pusht_uncertainty.json.
   Exposes window.AURA_live for tests. */
(function () {
  const root = document.documentElement;
  const isStatic = root.classList.contains('is-static');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const instances = [];
  window.AURA_live = { instances, get: (el) => instances.find((i) => i.block === el) };

  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, t) => a + (b - a) * t;

  document.querySelectorAll('[data-live]').forEach((block) => {
    const video = block.querySelector('[data-live-video]');
    const canvas = block.querySelector('[data-live-canvas]');
    const wrap = canvas && canvas.parentElement;
    const chips = [...block.querySelectorAll('[data-live-mode]')];
    const outP = block.querySelector('[data-live-progress]');
    const outV = block.querySelector('[data-live-value]');
    const outPh = block.querySelector('[data-live-phase]');
    const note = block.querySelector('[data-live-note]');
    if (!video || !canvas || !wrap) return;
    const ctx = canvas.getContext('2d');

    let data = null, series = null, mode = null, align = null;
    let dpr = 1, W = 0, H = 0, L = null, theme = null, staticLayer = null;
    let lastP = -1, rafId = 0;
    let progressive = !isStatic && !reduce;

    const inst = {
      block, video,
      get p() { return lastP; }, get mode() { return mode; }, get complete() { return lastP >= 1; },
      setMode: (k) => setMode(k), render: () => render(),
    };
    instances.push(inst);

    // --- data -------------------------------------------------------------
    const normalize = (j) => {
      if (!j || typeof j.schema !== 'string' || !j.schema.startsWith('aura.uncertainty-curve/')) throw new Error('bad schema');
      const prog = j.progress.map(Number);
      for (let i = 1; i < prog.length; i++) if (!(prog[i] > prog[i - 1])) throw new Error('progress not monotone');
      Object.keys(j.modes).forEach((k) => {
        const m = j.modes[k];
        m.progress = (m.progress || prog).map(Number);
        m.mean = m.mean.map(Number);
        if (m.lo && m.hi) { m.lo = m.lo.map(Number); m.hi = m.hi.map(Number); }
        if (m.mean.length !== m.progress.length) throw new Error('length mismatch ' + k);
        m.align = (m.align && m.align.length >= 2) ? m.align.map((pt) => pt.map(Number)) : [[0, 0], [1, 1]];
      });
      return j;
    };

    const warp = (frac) => {
      const a = align;
      if (frac <= a[0][0]) return a[0][1];
      for (let i = 1; i < a.length; i++) {
        if (frac <= a[i][0]) {
          const [x0, y0] = a[i - 1], [x1, y1] = a[i];
          return x1 === x0 ? y1 : lerp(y0, y1, (frac - x0) / (x1 - x0));
        }
      }
      return a[a.length - 1][1];
    };

    const progressOf = (t) => {
      const d = video.duration;
      if (!isFinite(d) || d <= 0) return 0;
      return clamp(warp(clamp(t / d, 0, 1)), 0, 1);
    };

    const sample = (arr, p) => {
      const xs = series.progress;
      const n = xs.length;
      if (p <= xs[0]) return arr[0];
      if (p >= xs[n - 1]) return arr[n - 1];
      let lo = 0, hi = n - 1;
      while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (xs[mid] <= p) lo = mid; else hi = mid; }
      const t = (p - xs[lo]) / (xs[hi] - xs[lo]);
      return lerp(arr[lo], arr[hi], t);
    };
    const at = (p) => ({ mean: sample(series.mean, p), lo: series.lo ? sample(series.lo, p) : null, hi: series.hi ? sample(series.hi, p) : null });
    const phaseAt = (p) => (data.phases || []).find((ph) => p >= ph.range[0] && p <= ph.range[1]) || null;

    // --- theme / geometry ---------------------------------------------------
    const readTheme = () => {
      const cs = getComputedStyle(block);
      const g = (k, d) => (cs.getPropertyValue(k) || d).trim();
      theme = {
        ink: g('--text-display', '#101418'), muted: g('--text-muted', '#6B737C'),
        border: g('--border', '#E1E4E8'), borderStrong: g('--border-strong', '#C9CED5'), paper: g('--bg-elev', '#fff'),
        mono: g('--mono', 'ui-monospace, monospace'),
        modes: { upper: g('--live-upper', '#3A948E'), lower: g('--live-lower', '#3F7FB5') },
      };
    };
    const measure = () => {
      const r = wrap.getBoundingClientRect();
      dpr = Math.min(window.devicePixelRatio || 1, 3);
      W = Math.max(1, Math.round(r.width)); H = Math.max(1, Math.round(r.height));
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.font = `500 11px ${theme.mono}`;
      const tw = ctx.measureText('0.4').width;
      L = { x0: Math.ceil(tw) + 14, x1: W - 10, y0: 30, y1: H - 34 };
      staticLayer = null; lastP = -1;
    };
    const xOf = (p) => L.x0 + (L.x1 - L.x0) * (p - data.x.range[0]) / (data.x.range[1] - data.x.range[0]);
    const yOf = (w) => L.y1 - (L.y1 - L.y0) * (w - data.y.range[0]) / (data.y.range[1] - data.y.range[0]);
    const hair = (v) => Math.round(v) + 0.5;
    const modeColor = () => theme.modes[mode] || theme.ink;

    const spaced = (s) => s.split('').join(' ');

    const buildStatic = () => {
      const off = document.createElement('canvas');
      off.width = canvas.width; off.height = canvas.height;
      const c = off.getContext('2d');
      c.setTransform(dpr, 0, 0, dpr, 0, 0);
      // phase bands
      (data.phases || []).forEach((ph) => {
        c.fillStyle = theme.ink; c.globalAlpha = 0.06;
        c.fillRect(xOf(ph.range[0]), L.y0, xOf(ph.range[1]) - xOf(ph.range[0]), L.y1 - L.y0);
        c.globalAlpha = 1;
      });
      // grid + axes
      c.lineWidth = 1;
      (data.y.ticks || []).forEach((t) => {
        if (t === data.y.range[0]) return;
        c.strokeStyle = theme.border; c.beginPath(); c.moveTo(L.x0, hair(yOf(t))); c.lineTo(L.x1, hair(yOf(t))); c.stroke();
      });
      c.strokeStyle = theme.borderStrong;
      c.beginPath(); c.moveTo(hair(L.x0), L.y0); c.lineTo(hair(L.x0), hair(L.y1)); c.lineTo(L.x1, hair(L.y1)); c.stroke();
      // ticks + labels
      c.fillStyle = theme.muted; c.font = `500 11px ${theme.mono}`; c.textBaseline = 'top'; c.textAlign = 'center';
      (data.x.ticks || []).forEach((t) => {
        const x = hair(xOf(t));
        c.beginPath(); c.moveTo(x, L.y1); c.lineTo(x, L.y1 + 4); c.stroke();
        c.fillText(t.toFixed(1), xOf(t), L.y1 + 8);
      });
      c.textAlign = 'right'; c.textBaseline = 'middle';
      (data.y.ticks || []).forEach((t) => c.fillText(t.toFixed(1), L.x0 - 8, yOf(t)));
      // axis titles
      c.font = `500 10px ${theme.mono}`; c.textAlign = 'center'; c.textBaseline = 'alphabetic';
      c.fillText(spaced((data.x.label || 'PROGRESS').toUpperCase()), (L.x0 + L.x1) / 2, H - 6);
      c.textAlign = 'left';
      c.fillText(spaced('UNCERTAINTY DEGREE'), L.x0, 12);
      // ghost of the full mean line
      c.strokeStyle = theme.ink; c.globalAlpha = 0.12; c.lineWidth = 1; c.lineJoin = 'round';
      c.beginPath();
      series.progress.forEach((x, i) => { const px = xOf(x), py = yOf(series.mean[i]); i ? c.lineTo(px, py) : c.moveTo(px, py); });
      c.stroke(); c.globalAlpha = 1;
      staticLayer = off;
    };

    const drawBand = (p) => {
      if (!series.lo || !series.hi) return;
      const xs = series.progress;
      ctx.fillStyle = modeColor(); ctx.globalAlpha = 0.14;
      ctx.beginPath();
      let n = 0;
      for (let i = 0; i < xs.length && xs[i] <= p; i++) { const x = xOf(xs[i]); n ? ctx.lineTo(x, yOf(series.hi[i])) : ctx.moveTo(x, yOf(series.hi[i])); n++; }
      const end = at(p);
      if (n) ctx.lineTo(xOf(p), yOf(end.hi)); else ctx.moveTo(xOf(p), yOf(end.hi));
      ctx.lineTo(xOf(p), yOf(end.lo));
      for (let i = xs.length - 1; i >= 0; i--) if (xs[i] <= p) ctx.lineTo(xOf(xs[i]), yOf(series.lo[i]));
      ctx.closePath(); ctx.fill(); ctx.globalAlpha = 1;
    };
    const drawMean = (p) => {
      const xs = series.progress;
      ctx.strokeStyle = modeColor(); ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
      ctx.beginPath();
      let n = 0;
      for (let i = 0; i < xs.length && xs[i] <= p; i++) { const x = xOf(xs[i]), y = yOf(series.mean[i]); n ? ctx.lineTo(x, y) : ctx.moveTo(x, y); n++; }
      const end = at(p);
      if (n) ctx.lineTo(xOf(p), yOf(end.mean)); else ctx.moveTo(xOf(p), yOf(end.mean));
      ctx.stroke();
    };
    const drawPhaseLabels = (p) => {
      ctx.font = `500 10px ${theme.mono}`; ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.fillStyle = theme.ink;
      (data.phases || []).forEach((ph) => {
        const a = progressive ? clamp((p - ph.range[0]) / 0.02, 0, 1) : 1;
        if (a <= 0) return;
        ctx.globalAlpha = 0.85 * a;
        ctx.fillText(spaced(ph.label.toUpperCase()), (xOf(ph.range[0]) + xOf(ph.range[1])) / 2, L.y0 + 6);
      });
      ctx.globalAlpha = 1;
    };
    const drawHead = (p) => {
      const end = at(p);
      const x = xOf(p), y = yOf(end.mean);
      ctx.save();
      ctx.setLineDash([3, 3]); ctx.strokeStyle = theme.muted; ctx.globalAlpha = 0.5; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(hair(x), L.y0); ctx.lineTo(hair(x), L.y1); ctx.stroke();
      ctx.restore();
      ctx.beginPath(); ctx.arc(x, y, 5.5, 0, Math.PI * 2); ctx.fillStyle = theme.paper; ctx.fill();
      ctx.beginPath(); ctx.arc(x, y, 3.8, 0, Math.PI * 2); ctx.fillStyle = modeColor(); ctx.fill();
    };

    const draw = (p) => {
      if (!staticLayer) buildStatic();
      ctx.clearRect(0, 0, W, H);
      ctx.drawImage(staticLayer, 0, 0, W, H);
      drawBand(p); drawMean(p); drawPhaseLabels(p);
      if (progressive && p > 0 && p < 1) drawHead(p);
      lastP = p;
    };
    const paint = (p) => {
      const v = at(p);
      const sP = Math.round(p * 100) + ' %', sV = v.mean.toFixed(2), ph = phaseAt(p);
      const sPh = ph ? ph.label : (outPh ? (outPh.dataset.liveIdle || '—') : '—');
      if (outP && outP.textContent !== sP) outP.textContent = sP;
      if (outV && outV.textContent !== sV) outV.textContent = sV;
      if (outPh && outPh.textContent !== sPh) outPh.textContent = sPh;
    };
    const render = () => {
      if (!data) return;
      const p = progressive ? progressOf(video.currentTime) : 1;
      if (p !== lastP) { draw(p); paint(p); }
    };
    const loop = () => { rafId = requestAnimationFrame(loop); render(); };
    const start = () => { cancelAnimationFrame(rafId); loop(); };
    const stop = () => { cancelAnimationFrame(rafId); rafId = 0; render(); };

    const setMode = (key, { swapVideo = true } = {}) => {
      if (!data.modes[key]) return;
      mode = key; series = data.modes[key]; align = series.align;
      chips.forEach((c) => { const on = c.dataset.liveMode === key; c.classList.toggle('is-active', on); c.setAttribute('aria-pressed', on ? 'true' : 'false'); });
      block.style.setProperty('--live-mode', theme.modes[key] || theme.ink);
      block.dataset.liveActive = key;
      staticLayer = null; lastP = -1;
      if (swapVideo) {
        const chip = chips.find((c) => c.dataset.liveMode === key);
        if (chip && chip.dataset.src) {
          if (chip.dataset.poster) video.setAttribute('poster', chip.dataset.poster);
          video.setAttribute('src', chip.dataset.src);
          video.load();
          if (progressive) video.addEventListener('canplay', () => {
            if (window.AURA_lazyVideo) window.AURA_lazyVideo.play(video); else video.play().catch(() => {});
          }, { once: true });
        }
      }
      render();
    };

    const bind = () => {
      ['play', 'playing'].forEach((e) => video.addEventListener(e, start));
      ['pause', 'ended', 'emptied'].forEach((e) => video.addEventListener(e, stop));
      ['seeking', 'seeked', 'timeupdate', 'loadedmetadata', 'durationchange'].forEach((e) => video.addEventListener(e, render));
      document.addEventListener('visibilitychange', () => { if (!document.hidden) render(); });
      if ('ResizeObserver' in window) new ResizeObserver(() => { measure(); render(); }).observe(wrap);
      window.addEventListener('resize', () => { if (Math.min(window.devicePixelRatio || 1, 3) !== dpr) { measure(); render(); } });
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { staticLayer = null; lastP = -1; render(); });
      chips.forEach((c) => c.addEventListener('click', (e) => { e.stopPropagation(); if (c.dataset.liveMode !== mode) setMode(c.dataset.liveMode); }));
      if (reduce && !isStatic) video.addEventListener('play', () => { progressive = true; lastP = -1; render(); }, { once: true });
    };

    const fallback = (why) => {
      block.classList.add('is-fallback');
      console.warn('[uncertainty-live]', why);
      chips.forEach((c) => c.addEventListener('click', () => {
        chips.forEach((k) => { k.classList.toggle('is-active', k === c); k.setAttribute('aria-pressed', k === c ? 'true' : 'false'); });
        if (c.dataset.poster) video.setAttribute('poster', c.dataset.poster);
        video.setAttribute('src', c.dataset.src); video.load(); video.play().catch(() => {});
      }));
    };

    fetch(block.dataset.src)
      .then((r) => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
      .then((j) => {
        data = normalize(j);
        readTheme(); measure();
        const active = chips.find((c) => c.classList.contains('is-active')) || chips[0];
        setMode(active ? active.dataset.liveMode : Object.keys(data.modes)[0], { swapVideo: false });
        if (note) note.textContent = data.source === 'figure-digitized' ? 'Profile: Fig. 7B mean over 20 rollouts, aligned to this rollout’s branch and push moments' : '';
        block.classList.add('is-live');
        bind();
        render();
      })
      .catch(fallback);
  });
})();
