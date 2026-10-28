import test from 'node:test';
import assert from 'node:assert/strict';
import { letterReveal, LETTER_DURATION_MS, LETTER_STAGGER_MS } from '../src/scripts/footer-sequence.mjs';

test('WeGit letters begin one after another in reading order', () => {
  assert.ok(letterReveal(0, 100).progress > 0);
  assert.equal(letterReveal(1, 100).progress, 0);
  const values = [0, 1, 2, 3, 4].map(index => letterReveal(index, LETTER_STAGGER_MS * 2 + 50).progress);
  assert.ok(values[0] > values[1] && values[1] > values[2] && values[2] > 0);
  assert.equal(values[3], 0); assert.equal(values[4], 0);
});
test('all letters settle completely without a repeating reveal', () => {
  const end = LETTER_STAGGER_MS * 4 + LETTER_DURATION_MS;
  for (const index of [0, 1, 2, 3, 4]) {
    assert.deepEqual(letterReveal(index, end), { progress: 1, offset: 0 });
    assert.deepEqual(letterReveal(index, end + 10_000), { progress: 1, offset: 0 });
  }
});
test('reduced motion shows the entire logo immediately', () => {
  for (const index of [0, 1, 2, 3, 4]) assert.deepEqual(letterReveal(index, 0, true), { progress: 1, offset: 0 });
});
