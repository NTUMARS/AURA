/* Copy-to-clipboard for the BibTeX block. */
(function () {
  const btn = document.querySelector('.bib__copy');
  const src = document.getElementById('bibtex-source');
  if (!btn || !src) return;

  btn.addEventListener('click', async () => {
    const text = src.textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
    } catch (e) {
      // Fallback for non-secure contexts
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); } catch (_) {}
      document.body.removeChild(ta);
    }
    const orig = btn.textContent;
    btn.textContent = 'Copied';
    btn.classList.add('is-copied');
    setTimeout(() => {
      btn.textContent = orig;
      btn.classList.remove('is-copied');
    }, 1600);
  });
})();
