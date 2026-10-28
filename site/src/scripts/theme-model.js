/** The desktop client's v1 JSON contract. No website-only settings are exported. */
export const MAX_THEME_BYTES = 65_536;
export const COLOR_ROLES = Object.freeze('accent canvas chrome sidebar surface border text secondaryText positive negative modified diffAdded diffRemoved keyword string number comment'.split(' '));
const FOREGROUNDS = ['text', 'secondaryText', 'positive', 'negative', 'modified', 'keyword', 'string', 'number', 'comment'];
const BACKGROUNDS = ['canvas', 'chrome', 'sidebar', 'surface', 'diffAdded', 'diffRemoved'];

export function normalizeHex(value) {
  if (typeof value !== 'string') throw new Error('Invalid color');
  const hex = value.trim().replace(/^#/, '');
  if (!/^[0-9a-f]{6}$/i.test(hex)) throw new Error('Invalid RGB color');
  return '#' + hex.toUpperCase();
}

export function validateTheme(value) {
  if (!value || value.version !== 1 || !['light', 'dark'].includes(value.controls)) throw new Error('Unsupported theme');
  if (typeof value.name !== 'string') throw new Error('Missing theme name');
  const name = value.name.trim();
  if (!name || [...name].length > 60 || new TextEncoder().encode(name).length > 4096) throw new Error('Invalid theme name');
  if (!value.colors || Object.keys(value.colors).length !== COLOR_ROLES.length || !COLOR_ROLES.every(role => Object.hasOwn(value.colors, role))) throw new Error('Expected all 17 color roles');
  const colors = Object.fromEntries(COLOR_ROLES.map(role => [role, normalizeHex(value.colors[role])]));
  return { version: 1, name, controls: value.controls, colors };
}

export function decodeTheme(text) {
  if (new TextEncoder().encode(text).length > MAX_THEME_BYTES) throw new Error('Theme is larger than 64 KiB');
  return validateTheme(JSON.parse(text));
}

export function luminance(hex) {
  const channels = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
  return channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
}

export function contrastRatio(a, b) {
  const levels = [luminance(a), luminance(b)].sort((x, y) => x - y);
  return (levels[1] + .05) / (levels[0] + .05);
}

function blend(a, b, amount) {
  return '#' + [1, 3, 5].map(i => Math.round(parseInt(a.slice(i, i + 2), 16) * (1 - amount) + parseInt(b.slice(i, i + 2), 16) * amount).toString(16).padStart(2, '0')).join('').toUpperCase();
}

/** Contrast changes become actual color values, shared by preview and download. */
/** @param {unknown} document @param {{accent?: string | null, contrast?: 'soft' | 'normal' | 'high'}} options */
export function prepareTheme(document, { accent = null, contrast = 'normal' } = {}) {
  const theme = validateTheme(document);
  if (accent) theme.colors.accent = normalizeHex(accent);
  if (contrast !== 'normal') {
    const backgrounds = BACKGROUNDS.map(role => theme.colors[role]);
    const target = theme.controls === 'dark' ? '#FFFFFF' : '#000000';
    const minimum = contrast === 'high' ? 7 : 4.5;
    for (const role of FOREGROUNDS) {
      const start = contrast === 'soft' ? blend(theme.colors[role], theme.colors.canvas, .08) : theme.colors[role];
      for (let step = 0; step <= 100; step++) {
        const candidate = blend(start, target, step / 100);
        if (backgrounds.every(bg => contrastRatio(candidate, bg) >= minimum)) {
          theme.colors[role] = candidate;
          break;
        }
      }
    }
  }
  return theme;
}

export function previewProperties(document) {
  const { colors } = validateTheme(document);
  const mapping = { canvas: 'bg', chrome: 'chrome', surface: 'panel', sidebar: 'sidebar', text: 'text', secondaryText: 'muted', border: 'border', accent: 'accent', positive: 'positive', negative: 'negative', modified: 'modified', diffAdded: 'diff-added', diffRemoved: 'diff-removed', keyword: 'keyword', string: 'string', number: 'number', comment: 'comment' };
  const properties = Object.fromEntries(Object.entries(mapping).map(([role, key]) => ['--app-' + key, colors[role]]));
  properties['--app-selection-text'] = contrastRatio(colors.accent, '#FFFFFF') >= contrastRatio(colors.accent, '#000000') ? '#FFFFFF' : '#000000';
  return properties;
}
