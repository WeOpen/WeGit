import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';

const source = stripTypeScriptTypes(readFileSync(new URL('../src/lib/theme-transition.ts', import.meta.url), 'utf8')).replace('export function', 'function');
function fixture() {
  const events = target => Object.assign(target, { listeners: new Map(), addEventListener(k, f) { this.listeners.set(k, f); }, removeEventListener(k) { this.listeners.delete(k); } });
  const preference = events({ matches: false });
  const captures = [], animations = [];
  const root = { dataset: {}, animate(frames, options) { const a = { frames, options, cancel() { this.cancelled = true; } }; animations.push(a); return a; } };
  const document = events({ documentElement: root, hidden: false, querySelector() { return null; }, startViewTransition(update) {
    let ready, finished;
    const t = { update, ready: new Promise(r => ready = r), finished: new Promise(r => finished = r), readyNow: () => ready(), finish: () => finished(), skipTransition() { this.skipped = true; } };
    captures.push(t); return t;
  } });
  const window = events({});
  const context = { document, window, matchMedia: () => preference, CSS: { supports: () => true }, innerWidth: 1280, innerHeight: 900 };
  vm.createContext(context); vm.runInContext(source, context);
  return { controller: context.createThemeTransition(), captures, animations, root, document, preference, window };
}
test('a click before snapshot capture supersedes the previous theme update', async () => {
  const f = fixture(); let mode = 'light';
  f.controller.run(() => mode = 'dark');
  f.controller.run(() => mode = 'light');
  f.captures[0].update(); f.captures[0].readyNow();
  await Promise.resolve();
  assert.equal(mode, 'light');
  assert.equal(f.animations.length, 0);
  assert.equal(f.root.dataset.themeTransition, undefined);
  f.controller.dispose();
});
test('pixel snapshots finish and disposal cancels animation and listeners', async () => {
  const f = fixture(); let commits = 0;
  f.controller.run(() => commits++); f.captures[0].update(); f.captures[0].readyNow();
  await Promise.resolve();
  assert.equal(commits, 1);
  assert.equal(f.animations[0].frames.length, 25);
  assert.equal(f.animations[0].options.duration, 960);
  f.controller.dispose();
  assert.equal(f.animations[0].cancelled, true);
  assert.equal(f.root.dataset.themeTransition, undefined);
  assert.equal(f.document.listeners.size + f.window.listeners.size + f.preference.listeners.size, 0);
});
test('reduced motion and unsupported browsers commit without snapshots', () => {
  const f = fixture(); let commits = 0;
  f.preference.matches = true; f.controller.run(() => commits++);
  f.preference.matches = false; delete f.document.startViewTransition; f.controller.run(() => commits++);
  assert.equal(commits, 2); assert.equal(f.captures.length, 0);
  f.controller.dispose();
});
