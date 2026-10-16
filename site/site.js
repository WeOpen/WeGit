import { selectRelease } from './release.mjs';

const chinese = document.documentElement.lang === 'zh-Hans';
const status = document.querySelector('#release-status');
const link = document.querySelector('#release-link');
const text = chinese ? {
  none: '暂未发布公开版本。你可以从源码构建开发预览，或关注 GitHub 的发布动态。',
  unavailable: '暂时无法读取发布状态，请在 GitHub 查看最新版本及安装说明。',
  preparing: '此版本的下载文件尚未齐备，请先查看版本说明。',
  stable: '公开版本', beta: '预发布版本', download: '下载 macOS 版', notes: '查看版本说明',
} : {
  none: 'No public release yet. Build the development preview from source, or follow releases on GitHub.',
  unavailable: 'Release status is unavailable. Check GitHub for the latest version and installation notes.',
  preparing: 'Download files for this release are not complete. Read the release notes first.',
  stable: 'Public release', beta: 'Pre-release', download: 'Download for macOS', notes: 'Read release notes',
};

try {
  const response = await fetch(new URL('./releases.json', import.meta.url), {
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error('Release request failed');
  const release = selectRelease(await response.json());
  if (!release) status.textContent = text.none;
  else {
    document.querySelector('.status-label').textContent = (release.prerelease ? text.beta : text.stable) + ' ' + release.tag;
    link.href = release.download || release.notes;
    link.textContent = release.download ? text.download : text.notes;
    status.textContent = release.download
      ? (chinese ? '下载文件直接来自 GitHub Release。SHA-256 与来源清单对应同一版本。' : 'Download directly from GitHub Releases. The checksum and source manifest belong to the same version.')
      : text.preparing;
    if (release.download) {
      for (const [id, url] of [['checksum-link', release.checksum], ['manifest-link', release.manifest]]) {
        const target = document.getElementById(id); target.href = url; target.hidden = false;
      }
      const notes = document.createElement('a'); notes.href = release.notes; notes.textContent = text.notes;
      document.querySelector('.download-links').append(notes);
    }
  }
} catch {
  status.textContent = text.unavailable;
}
