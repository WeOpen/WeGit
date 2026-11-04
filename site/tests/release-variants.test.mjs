import test from 'node:test';
import assert from 'node:assert/strict';
import { ARCHITECTURES, architectureHint, chooseArtifact, normalizeRelease, selectRelease } from '../src/scripts/release.mjs';

function release(tag) {
  const variant = { universal: 'universal', arm64: 'applesilicon', x86_64: 'intel' };
  return { tag_name: tag, draft: false, prerelease: tag.includes('-'), wegit: { minimumSystemVersion: '26.0' },
    assets: ARCHITECTURES.flatMap(architecture => {
      const name = `WeGit-${tag.slice(1)}-macos-${variant[architecture]}-adhoc.dmg`;
      return [name, name + '.sha256', `manifest-${variant[architecture]}.json`].map(file => ({ name: file,
        size: 20000000, digest: 'sha256:' + 'a'.repeat(64), state: 'uploaded',
        browser_download_url: `https://github.com/WeOpen/WeGit/releases/download/${tag}/${file}` }));
    }) };
}
test('semantic versions select complete stable packages independently of API order', () => {
  assert.equal(selectRelease([release('v2.9.0'), release('v2.10.0'), release('v3.0.0-rc.2')]).tag, 'v2.10.0');
  assert.equal(selectRelease([release('v3.0.0-rc.2'), release('v3.0.0-rc.10')], { channel: 'candidate' }).tag, 'v3.0.0-rc.10');
  assert.equal(selectRelease([release('v3.0.0-rc.2')], { channel: 'stable' }), null);
});
test('incomplete or withdrawn variants cannot borrow packages from another version', () => {
  const partial = release('v2.1.0'); partial.assets = partial.assets.filter(asset => !asset.name.includes('-intel-'));
  assert.equal(normalizeRelease(partial).complete, false);
  assert.equal(selectRelease([partial, release('v2.0.0')]).tag, 'v2.0.0');
  assert.equal(normalizeRelease({ ...release('v2.0.0'), draft: true }), null);
  const mismatched = release('v2.1.0'); mismatched.assets[0].browser_download_url = release('v2.0.0').assets[0].browser_download_url;
  assert.equal(Object.keys(normalizeRelease(mismatched).artifacts).length, 0);
});
test('valid same-version variants retain checksum, size, manifest and minimum OS', () => {
  const selected = selectRelease([release('v2.0.0')]);
  for (const architecture of ARCHITECTURES) {
    const artifact = chooseArtifact(selected, architecture);
    assert.equal(artifact.architecture, architecture); assert.equal(artifact.sha256, 'a'.repeat(64));
    assert.equal(artifact.minimumOS, '26.0'); assert.equal(artifact.bytes, 20000000);
    assert.match(artifact.download, /v2\.0\.0/);
  }
});
test('missing digests and unsafe package URLs reject modern releases', () => {
  for (const mutate of [asset => { delete asset.digest; }, asset => { asset.size = 31 * 1024 * 1024; }, asset => { asset.browser_download_url += '?token=x'; }, asset => { asset.state = 'new'; }]) {
    const damaged = release('v2.0.0'); mutate(damaged.assets[0]);
    assert.equal(normalizeRelease(damaged).complete, false);
  }
});
test('only known 64-bit Client Hints produce architecture recommendations', () => {
  assert.equal(architectureHint({ platform: 'macOS', architecture: 'arm', bitness: '64' }), 'arm64');
  assert.equal(architectureHint({ platform: 'macOS', architecture: 'x86', bitness: '64' }), 'x86_64');
  for (const hints of [null, {}, { platform: 'MacIntel' }, { architecture: 'arm' }, { architecture: 'x86', bitness: '32' }, { architecture: 'arm', bitness: '64', translated: true }, { architecture: 'x86', bitness: '64', wow64: true }, { architecture: 'arm', bitness: '64', platform: 'Windows' }]) assert.equal(architectureHint(hints), 'universal');
});
