import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { workbenchHTML } from '../src/scripts/workbench.js';
import { icon, ICONS } from '../src/scripts/icons.js';

const translations = JSON.parse(readFileSync(new URL('../data/translations.json', import.meta.url)));
const sprite = readFileSync(new URL('../public/assets/icons/culture.svg', import.meta.url), 'utf8');

test('every registered cultural icon resolves to its vector symbol', () => {
  const symbols = [...sprite.matchAll(/<symbol id="([^"]+)"/g)].map(match => match[1]);
  const catalog = JSON.parse(readFileSync(new URL('../data/icons.json', import.meta.url)));
  assert.equal(symbols.length, 48);
  assert.deepEqual(catalog.map(entry => entry.id).sort(), [...ICONS].sort());
  assert.deepEqual([...ICONS].sort(), symbols.sort());
  for (const name of ICONS) {
    const html = icon(name, path => '/WeGit/assets/' + path);
    assert.ok(html.includes(`/WeGit/assets/icons/culture.svg#${name}`));
    assert.ok(html.includes('aria-hidden="true"'));
  }
  assert.throws(() => icon('unknown', path => path));
});

test('full and thumbnail WeGit workspaces resolve every localized label', () => {
  for (const lang of ['en', 'zh']) for (const compact of [false, true]) {
    const tr = key => { assert.ok(Object.hasOwn(translations[lang], key), `Missing ${lang} ${key}`); return translations[lang][key]; };
    const html = workbenchHTML(tr, path => '/WeGit/assets/' + path, { compact });
    assert.ok(html.includes('Sources/Workbench.swift'));
    assert.ok(html.includes('wg-commit-primary'));
    assert.ok(html.includes('wg-file-selected'));
    assert.ok(!html.includes('class="app-window"'));
  }
});
