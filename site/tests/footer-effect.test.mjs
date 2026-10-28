import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { letterReveal } from '../src/scripts/footer-sequence.mjs';

const source = readFileSync(new URL('../src/scripts/footer-effect.js', import.meta.url), 'utf8').replace(/^import .*\n/m, '').replace('export function', 'function');

function fixture() {
  const events = target => Object.assign(target, {
    listeners: new Map(),
    addEventListener(type, callback) { this.listeners.set(type, callback); },
    removeEventListener(type) { this.listeners.delete(type); },
    fire(type) { this.listeners.get(type)?.(); }
  });
  const contexts = [];
  function canvas() {
    const ctx = {
      paints: 0, fills: [], fillStyle: '#000',
      setTransform() {}, clearRect() { this.paints++; }, save() {}, restore() {}, translate() {}, scale() {},
      fillText() {}, measureText(word) { return { width: word.length * 20 }; },
      getImageData(x, y, w, h) { return { data: new Uint8ClampedArray(w * h * 4).fill(255) }; },
      fillRect() { this.fills.push(this.fillStyle); },
      drawImage() {}
    };
    contexts.push(ctx);
    return { getContext() { return ctx; } };
  }
  const stages = ['wordmark', 'wordmark'].map(kind => events({
    dataset: { footerPixels: kind },
    classList: { add() {} },
    getBoundingClientRect() { return { width: 120, height: 60 }; },
    output: canvas(),
    querySelector() { return this.output; }
  }));
  const footer = { dataset: {}, querySelectorAll() { return stages; } };
  const document = events({
    hidden: false,
    documentElement: {},
    querySelector() { return footer; },
    createElement() { return canvas(); }
  });
  const preference = events({ matches: false });
  const pending = new Map();
  const observers = { intersection: [], resize: [], mutation: [] };
  const observer = kind => class {
    constructor(callback) { this.callback = callback; observers[kind].push(this); }
    observe() {}
    disconnect() { this.disconnected = true; }
    emit(entries) { this.callback(entries); }
  };
  let next = 0, mode = 'light';
  const window = events({
    IntersectionObserver: observer('intersection'), ResizeObserver: observer('resize')
  });
  const environment = {
    letterReveal,
    document, window,
    IntersectionObserver: window.IntersectionObserver,
    ResizeObserver: window.ResizeObserver,
    MutationObserver: observer('mutation'),
    devicePixelRatio: 2,
    matchMedia(query) { return query.includes('reduced') ? preference : { matches: false }; },
    getComputedStyle() { return { getPropertyValue(name) { return mode + name; } }; },
    requestAnimationFrame(callback) { pending.set(++next, callback); return next; },
    cancelAnimationFrame(id) { pending.delete(id); }
  };
  vm.createContext(environment);
  vm.runInContext(source, environment);
  const init = () => environment.initParticleFooter();
  const step = time => {
    const callbacks = [...pending.values()]; pending.clear();
    for (const callback of callbacks) callback(time);
  };
  const show = flags => observers.intersection[0].emit(stages.map((target, i) => ({ target, isIntersecting: flags[i] })));
  return { init, step, show, contexts, stages, document, window, preference, observers, pending,
    changeMode() { mode = 'dark'; observers.mutation[0].emit([]); } };
}

test('both stages share a bounded clock and offscreen stages do no drawing', () => {
  const f = fixture(); f.init();
  assert.equal(f.pending.size, 0);
  f.show([false, false]);
  assert.equal(f.pending.size, 0);
  f.show([true, false]);
  for (let i = 0; i < 120; i++) f.step(100 + i * (1000 / 120));
  assert.ok(f.contexts[0].paints > 0 && f.contexts[0].paints <= 30);
  assert.equal(f.contexts[1].paints, 0);
  f.show([true, true]);
  assert.equal(f.pending.size, 1);
  f.step(1300);
  assert.ok(f.contexts[1].paints > 0);
  const before = f.contexts.map(c => c.paints);
  f.show([false, false]); f.step(1400);
  assert.equal(f.pending.size, 0);
  assert.deepEqual(f.contexts.map(c => c.paints), before);
});

test('hidden-page preference and resize changes cannot restart drawing', () => {
  const f = fixture(); f.init(); f.show([true, true]); f.step(100);
  f.document.hidden = true; f.document.fire('visibilitychange');
  const before = f.contexts.map(c => c.paints);
  f.observers.resize[0].emit(f.stages.map(target => ({ target })));
  f.changeMode(); f.preference.fire('change'); f.step(200);
  assert.equal(f.pending.size, 0);
  assert.deepEqual(f.contexts.map(c => c.paints), before);
  f.document.hidden = false; f.document.fire('visibilitychange'); f.step(300);
  assert.equal(f.pending.size, 1);
  assert.ok(f.contexts[0].paints > before[0]);
});

test('reduced motion remains static and repaints in the current appearance', () => {
  const f = fixture(); f.preference.matches = true; f.init(); f.show([true, true]);
  assert.equal(f.pending.size, 0);
  const before = f.contexts.map(c => c.paints);
  f.step(1000);
  assert.deepEqual(f.contexts.map(c => c.paints), before);
  f.changeMode();
  assert.equal(f.pending.size, 0);
  assert.ok(f.contexts[0].paints > before[0]);
  assert.ok(f.contexts.slice(2).some(c => c.fills.includes('dark--footer-hot')));
  f.preference.matches = false; f.preference.fire('change');
  assert.equal(f.pending.size, 1);
});

test('initialization is idempotent and unsupported observers retain the fallback', () => {
  const f = fixture(); f.init(); f.init();
  assert.equal(f.observers.intersection.length, 1);
  assert.equal(f.observers.resize.length, 1);
  const unsupported = fixture(); delete unsupported.window.ResizeObserver;
  assert.doesNotThrow(unsupported.init);
  assert.equal(unsupported.observers.intersection.length, 0);
  assert.equal(unsupported.pending.size, 0);
});

test('React unmount removes the clock, observers and preference listeners', () => {
  const f = fixture(); const dispose = f.init(); f.show([true, true]); f.step(100);
  assert.equal(f.pending.size, 1);
  dispose();
  const before = f.contexts.map(c => c.paints);
  f.preference.fire('change'); f.document.fire('visibilitychange'); f.window.fire('pageshow'); f.step(200);
  assert.equal(f.pending.size, 0);
  assert.deepEqual(f.contexts.map(c => c.paints), before);
  assert.ok(Object.values(f.observers).flat().every(observer => observer.disconnected));
  assert.ok(f.stages.every(stage => stage.listeners.size === 0));
});
