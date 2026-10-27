/** Local progressive enhancement: no CDN, scroll polling or hidden initial hero. */
export function initAnimations() {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  const loader = document.createElement('div');
  loader.className = 'page-loader'; loader.id = 'page-loader'; loader.setAttribute('aria-hidden', 'true');
  loader.innerHTML = '<div class="loader-shell"><div class="taiji-loader"><span></span><i></i></div><div class="loader-title">WEGIT</div></div>';
  document.body.prepend(loader);
  let dismissed = false;
  const dismiss = () => {
    if (dismissed) return;
    dismissed = true; loader.classList.add('hidden');
    setTimeout(() => loader.remove(), 650);
  };
  if (document.readyState === 'complete') dismiss();
  else window.addEventListener('load', dismiss, { once: true });
  setTimeout(dismiss, 2000);
  if (!('IntersectionObserver' in window)) return;
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) if (entry.isIntersecting) {
      entry.target.classList.add('in-view');
      observer.unobserve(entry.target);
    }
  }, { threshold: .1, rootMargin: '40px' });
  document.body.classList.add('reveal-ready');
  document.querySelectorAll('.section-heading,.feature-card,.brand-concept-mark,.featured-image,.icon-size-item').forEach(element => {
    element.setAttribute('data-anim', ''); observer.observe(element);
  });
}
