import { animate } from 'motion/mini'

type Playback = ReturnType<typeof animate>
type Saved = { opacity: string; transform: string; transition: string; willChange: string }
type Entry = { node: HTMLElement; saved: Saved; shown: boolean; inView: boolean; delay: number; control?: Playback }

const ease = [0.22, 1, 0.36, 1] as const
const selector = [
  '.section-heading', '.feature-card', '.theme-mini-item', '.theme-card',
  '.brand-concept-mark', '.brand-quote', '.icon-size-item', '.step',
  '.featured-image', '.featured-copy', '.import-custom', '.final-cta-inner > *',
  '.error-message > *', '.error-card', '.error-brand-lockup', '.error-brand-copy',
  '.section > .wrap > h1', '.section > .wrap > p',
].join(',')

/** Progressive enhancement with native compositor animations and scoped cleanup. */
export function initPageMotion(root: HTMLElement) {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)')
  if (reduced.matches || !('IntersectionObserver' in window) || typeof root.animate !== 'function') return () => {}
  let disposed = false
  const entries: Entry[] = []
  const columnCounts = new Map<Element, number>()
  const save = (node: HTMLElement): Saved => ({ opacity: node.style.opacity, transform: node.style.transform, transition: node.style.transition, willChange: node.style.willChange })
  const restore = (entry: Entry) => { Object.assign(entry.node.style, entry.saved) }
  // Read the layout once, before assigning any initial styles.
  for (const node of root.querySelectorAll<HTMLElement>(selector)) {
    const bounds = node.getBoundingClientRect()
    if (!bounds.width || !bounds.height) continue
    const parent = node.parentElement!
    if (!columnCounts.has(parent)) columnCounts.set(parent, getComputedStyle(parent).gridTemplateColumns.split(' ').filter(value => value !== 'none').length || 1)
    const columns = columnCounts.get(parent)!
    const index = Array.from(parent.children).indexOf(node)
    entries.push({ node, saved: save(node), shown: bounds.top < innerHeight - 8, inView: bounds.bottom > 0 && bounds.top < innerHeight, delay: columns > 1 ? index % columns * 0.07 : 0 })
  }
  for (const entry of entries) if (!entry.shown) {
    entry.node.style.transition = 'none'
    entry.node.style.opacity = '0'
    entry.node.style.transform = 'translateY(18px)'
    entry.node.dataset.motionState = 'waiting'
  }
  const play = (entry: Entry, gentle = false) => {
    if (disposed || reduced.matches) return
    entry.shown = true
    entry.node.dataset.motionState = 'running'
    entry.node.style.transition = 'none'
    entry.node.style.willChange = 'transform, opacity'
    const control = animate(entry.node, { opacity: [gentle ? 0.85 : 0, 1], transform: [gentle ? 'translateY(12px)' : 'translateY(18px)', 'translateY(0px)'] }, { duration: 0.52, delay: entry.delay, ease: [...ease] })
    entry.control = control
    if (document.hidden) control.pause()
    void control.then(() => {
      if (disposed || entry.control !== control) return
      restore(entry)
      entry.control = undefined
      entry.node.dataset.motionState = 'shown'
    })
  }
  const floating = Array.from(root.querySelectorAll<HTMLElement>('.floating-seal'))
  const floatVisible = new Map<HTMLElement, boolean>()
  const syncFloats = () => {
    for (const node of floating) node.style.animationPlayState = !document.hidden && !reduced.matches && floatVisible.get(node) ? 'running' : 'paused'
  }
  const observer = new IntersectionObserver(changes => {
    for (const change of changes) {
      const entry = entries.find(entry => entry.node === change.target)
      if (entry) {
        entry.inView = change.isIntersecting
        if (entry.inView && !entry.shown) { play(entry); observer.unobserve(entry.node) }
      } else if (floatVisible.has(change.target as HTMLElement)) floatVisible.set(change.target as HTMLElement, change.isIntersecting)
    }
    syncFloats()
  }, { threshold: 0.08 })
  for (const entry of entries) if (!entry.shown) observer.observe(entry.node)
  for (const node of floating) { floatVisible.set(node, false); observer.observe(node) }
  for (const entry of entries) if (entry.shown && entry.node.matches('.error-message > *, .section > .wrap > h1, .section > .wrap > p')) play(entry, true)
  // The native hero screenshot stays visible and never enters a hidden queue.
  for (const [index, node] of Array.from(root.querySelectorAll<HTMLElement>('.hero-copy > *')).entries()) {
    if (!node.getBoundingClientRect().height) continue
    const entry: Entry = { node, saved: save(node), shown: false, inView: true, delay: index * 0.08 }
    entries.push(entry); play(entry, true)
  }
  const finishAll = () => {
    for (const entry of entries) {
      entry.control?.cancel(); entry.control = undefined; entry.shown = true
      restore(entry); entry.node.dataset.motionState = 'shown'; observer.unobserve(entry.node)
    }
    syncFloats()
  }
  const preferenceChanged = () => { if (reduced.matches) finishAll(); else syncFloats() }
  const visibilityChanged = () => {
    for (const entry of entries) {
      if (document.hidden) entry.control?.pause()
      else if (!reduced.matches) entry.control?.play()
    }
    syncFloats()
  }
  const focus = (event: FocusEvent) => {
    const target = event.target
    if (!(target instanceof Element)) return
    for (const entry of entries) if (entry.node.contains(target)) {
      entry.control?.cancel(); entry.control = undefined; entry.shown = true
      restore(entry); entry.node.dataset.motionState = 'shown'; observer.unobserve(entry.node)
    }
  }
  root.addEventListener('focusin', focus)
  reduced.addEventListener('change', preferenceChanged)
  document.addEventListener('visibilitychange', visibilityChanged)
  root.dataset.pageMotion = 'ready'
  return () => {
    disposed = true; observer.disconnect()
    for (const entry of entries) { entry.control?.cancel(); restore(entry); delete entry.node.dataset.motionState }
    for (const node of floating) node.style.animationPlayState = 'paused'
    root.removeEventListener('focusin', focus)
    reduced.removeEventListener('change', preferenceChanged)
    document.removeEventListener('visibilitychange', visibilityChanged)
    delete root.dataset.pageMotion
  }
}
