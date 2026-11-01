import test from 'node:test';
import assert from 'node:assert/strict';
import { topNavigationItem } from '../src/lib/navigation.mjs';

test('feature anchors select only features for both homepage languages', () => {
  for (const path of ['/', '/zh/', '/zh']) for (const hash of ['features', '#features']) {
    assert.equal(topNavigationItem(path, hash), 'features');
  }
});
test('home and other homepage anchors return to product selection', () => {
  for (const path of ['/', '/zh/']) for (const hash of ['', '#top', 'download', '#footer-logo']) {
    assert.equal(topNavigationItem(path, hash), 'product');
  }
});
test('theme pages keep their selection independently of page anchors', () => {
  for (const path of ['/themes/', '/themes', '/zh/themes/', '/zh/themes']) {
    assert.equal(topNavigationItem(path, '#gallery'), 'themes');
    assert.equal(topNavigationItem(path, 'features'), 'themes');
  }
});
test('privacy and missing pages do not falsely select a product section', () => {
  for (const path of ['/privacy/', '/zh/privacy/', '/zh/missing/', '/404.html/']) {
    assert.equal(topNavigationItem(path, '#features'), null);
  }
});
