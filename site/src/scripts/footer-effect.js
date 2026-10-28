/** Cached letter tiles; one clock paints visible wordmarks at most 30 times/s. */
export function initParticleFooter(panel = document.querySelector('.footer-logo-panel')) {
  if (!panel || panel.dataset.pixelsInitialized || !('IntersectionObserver' in window) || !('ResizeObserver' in window)) return;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const coarse = matchMedia('(pointer: coarse)');
  const renderers = [];
  let frame = 0, lastTick = 0, lastPaint = -Infinity, elapsed = 0;
  const random = n => { const x = Math.sin(n * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); };

  for (const stage of panel.querySelectorAll('[data-footer-pixels]')) {
    const canvas = stage.querySelector('canvas');
    const context = canvas?.getContext('2d', { alpha: true });
    if (!context) continue;
    const layer = document.createElement('canvas');
    const ink = layer.getContext('2d', { willReadFrequently: true });
    if (!ink) continue;
    const renderer = { stage, visible: false, dirty: true, ready: false };
    let width = 0, height = 0, step = 1, colors, moving = [], pointer = null;

    renderer.rebuild = () => {
      const bounds = stage.getBoundingClientRect();
      width = Math.round(bounds.width); height = Math.round(bounds.height);
      if (!width || !height) { renderer.ready = false; return; }
      const ratio = Math.min(devicePixelRatio || 1, 2);
      canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio);
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      layer.width = width; layer.height = height;
      const style = getComputedStyle(stage);
      colors = Object.fromEntries(['pixel', 'hot'].map(key => [key, style.getPropertyValue('--footer-' + key).trim()]));
      moving = [];
      const size = Math.min(width * .33, height * 1.18);
      ink.font = '700 ' + size + 'px Arial, Helvetica, sans-serif';
      ink.textAlign = 'center'; ink.textBaseline = 'middle';
      const scale = Math.min(1, width * .98 / ink.measureText('WeGit').width);
      const iStart = width / 2 + (ink.measureText('WeG').width - ink.measureText('WeGit').width / 2) * scale;
      const iEnd = iStart + ink.measureText('i').width * scale;
      ink.save(); ink.translate(width / 2, height * .53); ink.scale(scale, scale); ink.fillText('WeGit', 0, 0); ink.restore();
      const pixels = ink.getImageData(0, 0, width, height).data;
      // Find the actual blank row below the i dot rather than tinting the stem.
      let dotBottom = height, sawDot = false;
      for (let y = 0; y < height; y++) {
        let hasInk = false;
        for (let x = Math.max(0, Math.floor(iStart)); x < Math.min(width, Math.ceil(iEnd)); x++) {
          if (pixels[(y * width + x) * 4 + 3] > 100) { hasInk = true; break; }
        }
        if (hasInk) sawDot = true;
        else if (sawDot) { dotBottom = y; break; }
      }
      ink.clearRect(0, 0, width, height);
      step = Math.max(3, Math.ceil(width / (coarse.matches ? 120 : 165)));
      for (let y = 0; y < height; y += step) {
        for (let x = 0; x < width; x += step) {
          if (pixels[(y * width + x) * 4 + 3] < 100) continue;
          const dot = x >= iStart && x < iEnd && y < dotBottom;
          const noise = random(x + y * 997);
          if (!dot && noise > .86) {
            moving.push({ x, y, phase: x / width * 6 + random(x * 11 + y) * 1.5, warm: noise > .985 });
          } else {
            ink.fillStyle = dot ? colors.hot : colors.pixel;
            ink.fillRect(x, y, step - 1, step - 1);
          }
        }
      }
      renderer.dirty = false; renderer.ready = true;
      stage.classList.add('is-canvas-ready');
    };
    renderer.paint = time => {
      if (!renderer.ready) return;
      context.clearRect(0, 0, width, height);
      context.drawImage(layer, 0, 0);
      const active = !reduced.matches;
      for (const p of moving) {
        const pulse = active ? Math.max(0, Math.sin(time * .0008 - p.phase)) ** 12 : 0;
        const near = pointer && active ? Math.max(0, 1 - Math.hypot(p.x - pointer.x, p.y - pointer.y) / 100) : 0;
        // Tiles drift and settle on the same grid, keeping the letter silhouette clear.
        const x = p.x + Math.round(Math.sin(p.phase * 5) * pulse * 2) * step;
        const y = p.y + Math.round(Math.cos(p.phase * 3) * pulse * 2) * step;
        context.globalAlpha = 1 - pulse * .35;
        context.fillStyle = p.warm || near > .35 ? colors.hot : colors.pixel;
        context.fillRect(x, y, step - 1, step - 1);
      }
      context.globalAlpha = 1;
    };
    const move = event => {
      if (coarse.matches || reduced.matches) return;
      const bounds = stage.getBoundingClientRect();
      pointer = { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
    };
    const leave = () => { pointer = null; };
    stage.addEventListener('pointermove', move, { passive: true });
    stage.addEventListener('pointerleave', leave);
    renderer.dispose = () => { stage.removeEventListener('pointermove', move); stage.removeEventListener('pointerleave', leave); };
    renderers.push(renderer);
  }
  if (!renderers.length) return;
  panel.dataset.pixelsInitialized = 'true';

  function tick(now) {
    frame = 0;
    if (document.hidden || reduced.matches || !renderers.some(r => r.visible)) return;
    if (lastTick) elapsed += Math.min(now - lastTick, 100);
    lastTick = now;
    if (now - lastPaint >= 1000 / 30) {
      lastPaint = now;
      for (const r of renderers) if (r.visible) {
        if (r.dirty) r.rebuild();
        r.paint(elapsed);
      }
    }
    frame = requestAnimationFrame(tick);
  }
  function sync() {
    cancelAnimationFrame(frame); frame = 0; lastTick = 0; lastPaint = -Infinity;
    if (document.hidden) return;
    for (const r of renderers) if (r.visible) {
      if (r.dirty) r.rebuild();
      if (reduced.matches) r.paint(0);
    }
    if (!reduced.matches && renderers.some(r => r.visible)) frame = requestAnimationFrame(tick);
  }
  const visibility = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const r = renderers.find(r => r.stage === entry.target);
      if (r) r.visible = entry.isIntersecting;
    }
    sync();
  });
  const resize = new ResizeObserver(entries => {
    for (const entry of entries) {
      const r = renderers.find(r => r.stage === entry.target);
      if (r) r.dirty = true;
    }
    sync();
  });
  const appearance = new MutationObserver(() => {
    for (const r of renderers) r.dirty = true;
    sync();
  });
  for (const r of renderers) { visibility.observe(r.stage); resize.observe(r.stage); }
  appearance.observe(document.documentElement, { attributes: true, attributeFilter: ['data-site-mode'] });
  document.addEventListener('visibilitychange', sync);
  window.addEventListener('pageshow', sync);
  reduced.addEventListener('change', sync);
  return () => {
    cancelAnimationFrame(frame);
    visibility.disconnect(); resize.disconnect(); appearance.disconnect();
    document.removeEventListener('visibilitychange', sync);
    window.removeEventListener('pageshow', sync);
    reduced.removeEventListener('change', sync);
    for (const renderer of renderers) renderer.dispose();
    delete panel.dataset.pixelsInitialized;
  };
}
