const tagPattern = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(alpha|beta|rc)\.(0|[1-9]\d*))?$/;
export const ARCHITECTURES = Object.freeze(['universal', 'arm64', 'x86_64']);
const variants = { universal: 'universal', arm64: 'applesilicon', x86_64: 'intel' };

export function parseVersion(tag) {
  const match = tagPattern.exec(tag || '');
  if (!match) return null;
  const numbers = [match[1], match[2], match[3], match[5] || '0'].map(Number);
  if (!numbers.every(Number.isSafeInteger)) return null;
  return { numbers, prerelease: !!match[4], rank: { alpha: 0, beta: 1, rc: 2 }[match[4]] ?? 3 };
}
function compare(a, b) {
  for (let index = 0; index < 3; index++) if (a.numbers[index] !== b.numbers[index]) return a.numbers[index] - b.numbers[index];
  return a.rank - b.rank || a.numbers[3] - b.numbers[3];
}

function assetURL(value, tag, name) {
  try {
    const url = new URL(value);
    const prefix = `/WeOpen/WeGit/releases/download/${encodeURIComponent(tag)}/`;
    return url.origin === 'https://github.com' && !url.search && !url.hash
      && !url.username && !url.password && url.pathname === prefix + encodeURIComponent(name) ? url.href : null;
  } catch { return null; }
}

function artifact(release, architecture, modern) {
  const assets = Array.isArray(release.assets) ? release.assets : [];
  const version = release.tag_name.slice(1), variant = variants[architecture];
  let archive = assets.find(asset => asset.name === `WeGit-${version}-macos-${variant}-adhoc.dmg`);
  if (!modern && !archive && architecture === 'arm64' && !assets.some(asset => asset.name === `WeGit-${version}-macos-universal-adhoc.dmg`)) {
    archive = assets.find(asset => asset.name === `WeGit-${version}-macos-arm64-adhoc.zip`);
  }
  if (!archive || archive.state && archive.state !== 'uploaded') return null;
  const checksum = archive && assets.find(asset => asset.name === archive.name + '.sha256');
  const manifest = assets.find(asset => asset.name === `manifest-${variant}.json`) || (!modern && assets.find(asset => asset.name === 'manifest.json'));
  const url = item => item && assetURL(item.browser_download_url, release.tag_name, item.name);
  const download = url(archive), sha256 = url(checksum), receipt = url(manifest);
  const digest = /^sha256:[0-9a-f]{64}$/.test(archive.digest || '') ? archive.digest.slice(7) : null;
  if (!download || !sha256 || !receipt || modern && (!digest || !Number.isSafeInteger(archive.size) || archive.size < 512 || archive.size > 30 * 1024 * 1024)) return null;
  return { architecture, download, checksum: sha256, manifest: receipt, sha256: digest,
    bytes: Number.isSafeInteger(archive.size) ? archive.size : null,
    minimumOS: release.wegit?.minimumSystemVersion ?? null };
}

export function normalizeRelease(release) {
  const version = parseVersion(release?.tag_name);
  if (!version || release.draft !== false || Boolean(release.prerelease) !== version.prerelease) return null;
  const modern = version.numbers[0] >= 2;
  const artifacts = Object.fromEntries(ARCHITECTURES.map(architecture => [architecture, artifact(release, architecture, modern)]).filter(([, value]) => value));
  const complete = !modern || ARCHITECTURES.every(architecture => artifacts[architecture]);
  return { tag: release.tag_name, version: release.tag_name.slice(1), prerelease: version.prerelease,
    channel: version.prerelease ? 'candidate' : 'stable',
    notes: `https://github.com/WeOpen/WeGit/releases/tag/${encodeURIComponent(release.tag_name)}`,
    artifacts: complete ? artifacts : {}, complete, order: version };
}
export function selectRelease(releases, { channel = 'automatic' } = {}) {
  if (!Array.isArray(releases)) throw new Error('Invalid release response');
  const published = releases.map(normalizeRelease).filter(Boolean).sort((a, b) => compare(b.order, a.order));
  const available = channel === 'stable' ? published.filter(item => !item.prerelease) : published;
  const release = channel === 'candidate' ? available.find(item => Object.keys(item.artifacts).length) || available[0] :
    available.find(item => !item.prerelease && item.artifacts.universal)
    || available.find(item => item.artifacts.universal)
    || available.find(item => !item.prerelease && Object.keys(item.artifacts).length)
    || available.find(item => Object.keys(item.artifacts).length)
    || available.find(item => !item.prerelease) || available[0];
  if (!release) return null;
  const chosen = release.artifacts.universal || release.artifacts.arm64 || null;
  return { ...release, download: chosen?.download ?? null, checksum: chosen?.checksum ?? null, manifest: chosen?.manifest ?? null };
}
/** Only Client Hints, never MacIntel/UA tokens or graphics/performance probes. */
export function architectureHint(hints) {
  if (!hints || hints.translated === true || hints.wow64 === true || hints.platform && String(hints.platform).toLowerCase() !== 'macos') return 'universal';
  const architecture = typeof hints.architecture === 'string' ? hints.architecture.trim().toLowerCase() : '';
  if (String(hints.bitness || '').trim() !== '64') return 'universal';
  if (architecture === 'arm') return 'arm64';
  if (architecture === 'x86') return 'x86_64';
  return 'universal';
}
export function chooseArtifact(release, architecture = 'universal') {
  if (!ARCHITECTURES.includes(architecture)) architecture = 'universal';
  return release?.artifacts?.[architecture] || release?.artifacts?.universal || null;
}
