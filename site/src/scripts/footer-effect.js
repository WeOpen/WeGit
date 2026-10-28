/** Canvas 2D particle wordmark; no dependencies or continuous offscreen work. */
export function initParticleFooter() {
  const stage = document.querySelector('[data-footer-particles]');
  const canvas = stage?.querySelector('canvas');
  if (!canvas || !canvas.getContext || !('IntersectionObserver' in window)) return;
  const context = canvas.getContext('2d', { alpha: true });
  if (!context) return;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const coarse = matchMedia('(pointer: coarse)');
  let particles = [], width = 0, height = 0, frame = 0, visible = false, lastTime = 0, age = 0;
  let target = { x: -1000, y: -1000 }, pointer = { x: -1000, y: -1000 };
  const dpr = () => Math.min(devicePixelRatio || 1, 2);
  function rebuild() {
    const bounds = stage.getBoundingClientRect();
    width = Math.round(bounds.width);
    height = Math.round(bounds.height);
    if (width < 1 || height < 1) return;
    canvas.width = Math.round(width * dpr());
    canvas.height = Math.round(height * dpr());
    context.setTransform(dpr(), 0, 0, dpr(), 0, 0);
    const off = document.createElement('canvas');
    off.width = width;
    off.height = height;
    const ink = off.getContext('2d', { willReadFrequently: true });
    if (!ink) return;
    const size = Math.min(width * .235, height * .59, 290);
    ink.font = '900 ' + size + 'px Arial, Helvetica, sans-serif';
    ink.textAlign = 'center';
    ink.textBaseline = 'middle';
    const word = 'WEGIT';
    const textWidth = ink.measureText(word).width;
    const scale = Math.min(1, (width * .82) / textWidth);
    ink.translate(width / 2, height * .53);
    ink.scale(scale, scale);
    ink.fillText(word, 0, 0);
    const pixels = ink.getImageData(0, 0, width, height).data;
    const step = width < 500 ? 5 : width < 950 ? 6 : 7;
    const candidates = [];
    for (let y = 0; y < height; y += step) {
      for (let x = 0; x < width; x += step) {
        if (pixels[(y * width + x) * 4 + 3] > 100) candidates.push([x, y]);
      }
    }
    // Cap particles for low-powered devices and high-density displays.
    const stride = Math.max(1, Math.ceil(candidates.length / (coarse.matches ? 1700 : 3300)));
    particles = candidates.filter((_, i) => i % stride === 0).map(([x, y], index) => ({
      x, y, px: x, py: y, phase: (index * 1.618) % 6.283,
      radius: .65 + ((index * 13) % 9) / 13,
      warm: (index * 7) % 5 === 0
    }));
    stage.classList.add('is-canvas-ready');
    paint(0);
  }
  function paint(time) {
    if (!width || !height) return;
    context.clearRect(0, 0, width, height);
    const glow = context.createRadialGradient(width*.5, height*.55, 0, width*.5, height*.55, width*.4);
    glow.addColorStop(0, 'rgba(201,74,48,.17)');
    glow.addColorStop(1, 'rgba(201,74,48,0)');
    context.fillStyle = glow; context.fillRect(0, 0, width, height);
    const active = !reduced.matches;
    for (const p of particles) {
      const dx = p.x - pointer.x, dy = p.y - pointer.y;
      const dist = Math.hypot(dx, dy) || 1;
      const force = active && dist < 125 ? Math.pow(1 - dist / 125, 2) * 36 : 0;
      const sway = active ? Math.sin(time*.0007 + p.phase) * 1.1 : 0;
      const tx = p.x + dx / dist * force + sway;
      const ty = p.y + dy / dist * force + (active ? Math.cos(time*.0006 + p.phase) * 1.2 : 0);
      p.px += (tx - p.px) * .14;
      p.py += (ty - p.py) * .14;
      const light = .60 + (active ? .24 * Math.sin(time*.0014 + p.phase) : .16);
      context.fillStyle = p.warm ? 'rgba(255,194,137,' + light + ')' : 'rgba(230,104,75,' + light + ')';
      context.beginPath(); context.arc(p.px, p.py, p.radius, 0, Math.PI*2); context.fill();
    }
  }
  function tick(time) {
    frame = 0;
    if (!visible || reduced.matches) return;
    if (time - lastTime >= 33) {
      lastTime = time;
      pointer.x += (target.x - pointer.x) * .18;
      pointer.y += (target.y - pointer.y) * .18;
      paint(time);
    }
    frame = requestAnimationFrame(tick);
  }
  function sync() {
    cancelAnimationFrame(frame); frame = 0;
    if (visible && !reduced.matches) frame = requestAnimationFrame(tick);
    else paint(0);
  }
  const observer = new IntersectionObserver(entries => {
    visible = entries[0]?.isIntersecting ?? false; sync();
  }, { rootMargin: '80px' });
  observer.observe(stage);
  const resize = new ResizeObserver(() => { rebuild(); sync(); });
  resize.observe(stage);
  stage.addEventListener('pointermove', event => {
    if (coarse.matches || reduced.matches) return;
    const rect = stage.getBoundingClientRect();
    target = { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }, { passive: true });
  stage.addEventListener('pointerleave', () => { target = { x: -1000, y: -1000 }; });
  document.addEventListener('visibilitychange', () => { if (document.hidden) { cancelAnimationFrame(frame); frame = 0; } else sync(); });
  reduced.addEventListener('change', sync);
  rebuild();
}
