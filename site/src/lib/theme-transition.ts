/** A bounded pixel wave on native snapshots; no DOM tiles or idle frame loop. */
export function createThemeTransition() {
  const root = document.documentElement
  const reduced = matchMedia('(prefers-reduced-motion: reduce)')
  let current: ViewTransition | undefined
  let animation: Animation | undefined
  let generation = 0
  const stop = () => {
    current?.skipTransition(); current = undefined
    animation?.cancel(); animation = undefined
    delete root.dataset.themeTransition
  }
  const preference = () => { if (reduced.matches) stop() }
  const visibility = () => { if (document.hidden) stop() }
  reduced.addEventListener('change', preference)
  document.addEventListener('visibilitychange', visibility)
  document.addEventListener('wegit-route-change', stop)
  window.addEventListener('resize', stop, { passive: true })
  return {
    run(update: () => void) {
      const id = ++generation
      const busy = !!current
      stop()
      // Repeated clicks commit the latest intent immediately, even before capture.
      if (busy || reduced.matches || document.hidden || !document.startViewTransition || !CSS.supports('clip-path', "path('M0 0h1v1z')")) { update(); return }
      const button = document.querySelector('[data-action="toggle-mode"]')?.getBoundingClientRect()
      const x = button ? button.left + button.width / 2 : innerWidth / 2
      const y = button ? button.top + button.height / 2 : 0
      const size = Math.max(48, Math.ceil(Math.sqrt(innerWidth * innerHeight / 900)))
      const distance = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y)) || 1
      const tiles: { path: string; at: number }[] = []
      for (let top = 0; top < innerHeight; top += size) for (let left = 0; left < innerWidth; left += size) {
        const noise = (Math.sin(left * 12.9898 + top * 78.233) * 43758.5453) % 1
        tiles.push({ path: `M${left} ${top}h${size}v${size}h-${size}z`, at: .75 * Math.hypot(left + size / 2 - x, top + size / 2 - y) / distance + .25 * Math.abs(noise) })
      }
      const frames = Array.from({ length: 25 }, (_, index) => ({
        clipPath: `path('M0 0${tiles.filter(tile => tile.at <= index / 24 * 1.1).map(tile => tile.path).join('')}')`,
        offset: index / 24, easing: 'steps(1, end)',
      }))
      root.dataset.themeTransition = 'pixels'
      const transition = document.startViewTransition(() => { if (id === generation) update() })
      current = transition
      void transition.ready.then(() => {
        if (id !== generation || current !== transition) return
        animation = root.animate(frames, { duration: 720, fill: 'both', pseudoElement: '::view-transition-new(root)' })
      }).catch(() => { /* Unsupported snapshot animation retains the committed theme. */ })
      void transition.finished.catch(() => {}).then(() => { if (id === generation) stop() })
    },
    dispose() {
      generation++
      stop()
      reduced.removeEventListener('change', preference)
      document.removeEventListener('visibilitychange', visibility)
      document.removeEventListener('wegit-route-change', stop)
      window.removeEventListener('resize', stop)
    },
  }
}
