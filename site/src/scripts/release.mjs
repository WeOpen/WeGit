const tagPattern = /^v\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?$/;

function assetURL(value, tag, name) {
  try {
    const url = new URL(value);
    const prefix = `/WeOpen/WeGit/releases/download/${encodeURIComponent(tag)}/`;
    return url.origin === 'https://github.com' && !url.search && !url.hash
      && !url.username && !url.password && url.pathname === prefix + encodeURIComponent(name) ? url.href : null;
  } catch { return null; }
}

export function selectRelease(releases) {
  if (!Array.isArray(releases)) throw new Error('Invalid release response');
  const published = releases.filter(item => item.draft === false && tagPattern.test(item.tag_name || ''));
  const release = published.find(item => !item.prerelease) || published[0];
  if (!release) return null;
  const assets = Array.isArray(release.assets) ? release.assets : [];
  const version = release.tag_name.slice(1);
  const archive = assets.find(asset => asset.name === `WeGit-${version}-macos-arm64-adhoc.zip`);
  const checksum = archive && assets.find(asset => asset.name === archive.name + '.sha256');
  const manifest = assets.find(asset => asset.name === 'manifest.json');
  const url = item => item && assetURL(item.browser_download_url, release.tag_name, item.name);
  const download = url(archive), sha256 = url(checksum), receipt = url(manifest);
  return {
    tag: release.tag_name,
    prerelease: Boolean(release.prerelease),
    notes: `https://github.com/WeOpen/WeGit/releases/tag/${encodeURIComponent(release.tag_name)}`,
    download: download && sha256 && receipt ? download : null,
    checksum: sha256,
    manifest: receipt,
  };
}
