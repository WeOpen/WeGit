import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { COLOR_ROLES, MAX_THEME_BYTES, contrastRatio, decodeTheme, prepareTheme, previewProperties, validateTheme } from '../src/scripts/theme-model.js';

const catalog = JSON.parse(readFileSync(new URL('../data/themes.json', import.meta.url)));
const documents = catalog.map(entry => JSON.parse(readFileSync(new URL(`../public/themes/${entry.id}.json`, import.meta.url))));

test('all ten catalog themes use the real desktop schema and round-trip every color', () => {
  assert.equal(documents.length, 10);
  for (const document of documents) {
    assert.deepEqual(decodeTheme(JSON.stringify(document)), document);
    assert.deepEqual(Object.keys(document.colors).sort(), [...COLOR_ROLES].sort());
    assert.deepEqual(Object.keys(prepareTheme(document)).sort(), ['colors', 'controls', 'name', 'version']);
  }
});

test('accent and contrast adjustments export the same values shown in the preview', () => {
  for (const document of documents) {
    const adjusted = prepareTheme(document, { accent: '#268ae5', contrast: 'high', fontFamily: 'mono', fontSize: 16 });
    assert.equal(adjusted.colors.accent, '#268AE5');
    const properties = previewProperties(adjusted);
    assert.equal(properties['--app-bg'], adjusted.colors.canvas);
    assert.equal(properties['--app-diff-added'], adjusted.colors.diffAdded);
    assert.equal(properties['--app-accent'], adjusted.colors.accent);
    assert.equal(Object.hasOwn(adjusted, 'preferences'), false);
    for (const role of ['text', 'secondaryText', 'keyword', 'string', 'number', 'comment']) {
      for (const background of ['canvas', 'surface', 'diffAdded', 'diffRemoved']) assert.ok(contrastRatio(adjusted.colors[role], adjusted.colors[background]) >= 7);
    }
    assert.deepEqual(decodeTheme(JSON.stringify(adjusted)), adjusted);
  }
});

test('preparing a theme does not mutate its source or another theme', () => {
  const before = JSON.stringify(documents);
  prepareTheme(documents[0], { accent: '#123456', contrast: 'soft' });
  assert.equal(JSON.stringify(documents), before);
});

test('import preserves Unicode names and normalizes client-compatible color input', () => {
  const document = structuredClone(documents[0]);
  document.name = '  深海 · My theme 🙂  ';
  document.colors.canvas = ' abcDEF ';
  const imported = validateTheme(document);
  assert.equal(imported.name, '深海 · My theme 🙂');
  assert.equal(imported.colors.canvas, '#ABCDEF');
});

test('malformed, oversized, partial and incompatible imports are refused', () => {
  assert.throws(() => decodeTheme('{broken'));
  assert.throws(() => decodeTheme(' '.repeat(MAX_THEME_BYTES + 1)), /64 KiB/);
  for (const mutate of [document => { document.version = 2; }, document => { document.controls = 'auto'; }, document => { document.name = ''; }, document => { delete document.colors.canvas; }, document => { document.colors.unknown = '#123456'; }, document => { document.colors.accent = 'url(https://example.invalid)'; }]) {
    const document = structuredClone(documents[0]); mutate(document);
    assert.throws(() => validateTheme(document));
  }
  assert.throws(() => validateTheme({ format: 'wegit-theme', version: 1, appearance: 'light', name: 'Old prototype', colors: {} }));
});

test('accent selection text chooses the more readable foreground', () => {
  for (const accent of ['#000000', '#FFFFFF', '#B3322D', '#FF8A1C']) {
    const document = prepareTheme(documents[0], { accent });
    const text = previewProperties(document)['--app-selection-text'];
    assert.ok(contrastRatio(accent, text) >= 4.5);
  }
});
