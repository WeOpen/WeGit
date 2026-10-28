export const LETTER_DURATION_MS = 520;
export const LETTER_STAGGER_MS = 140;

/** Each letter eases upward independently; reduced motion reveals the complete mark. */
export function letterReveal(index, elapsed, immediate = false) {
  if (immediate) return { progress: 1, offset: 0 };
  const time = Math.max(0, Math.min(1, (elapsed - index * LETTER_STAGGER_MS) / LETTER_DURATION_MS));
  const progress = 1 - (1 - time) ** 3;
  return { progress, offset: (1 - progress) * 18 };
}
