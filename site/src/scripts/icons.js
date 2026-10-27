/** Refined cultural glyphs on a shared 24-unit grid. */
export const ICONS = Object.freeze(["taiji","scroll","plum","cloud","window","fan","brush","seal","chest","bamboo","download","upload","arrow","close","reset","search","home","themes","docs","palette","layers","link","external","check","chevron-right","chevron-down","folder","file","settings","history","branch","tag","commit","stash","terminal","copy","edit","trash","lock","unlock","mail","feedback","info","warning","help","bell","pin","bookmark"]);
export function icon(name, asset) {
  if (!ICONS.includes(name)) throw new Error('Unknown cultural icon: ' + name);
  return `<svg class="culture-icon icon-${name}" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><use href="${asset('icons/culture.svg')}#${name}"></use></svg>`;
}
