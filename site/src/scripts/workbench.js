import { icon } from './icons.js';

/** Mirrors WeGit's real Changes workspace: sidebar, staged files, diff and commit draft. */
export function workbenchHTML(tr, asset, { compact = false } = {}) {
  const glyph = name => icon(name, asset);
  const nav = [['brush', 'changes'], ['history', 'history'], ['branch', 'branches'], ['stash', 'stashes'], ['tag', 'tags']];
  const rows = compact ? [
    ['3', '', 'struct Workbench {', 'keyword'], ['4', '−', '  var title = "WeGit"', 'removed'], ['4', '+', '  var title = "Paper & ink"', 'added'], ['5', '+', '  var staged = 2', 'added'], ['6', '', '}', ''],
  ] : [
    ['1', '', 'import Foundation', 'keyword'], ['2', '', '', ''], ['3', '', 'struct Workbench {', 'keyword'],
    ['4', '−', '  var title = "WeGit"', 'removed'], ['5', '−', '  var staged = 1', 'removed'],
    ['4', '+', '  var title = "Paper & ink"', 'added'], ['5', '+', '  var staged = 2', 'added'],
    ['6', '', '', ''], ['7', '', '  func refresh() {', 'keyword'], ['8', '−', '    print(title)', 'removed'],
    ['8', '+', '    print("Ready: \\(title)")', 'added'], ['9', '', '  }', ''], ['10', '', '}', ''],
  ];
  const code = rows.map(([line, sign, text, kind]) => `<div class="wg-code-row ${kind ? 'wg-' + kind : ''}"><span class="wg-line-number">${line}</span><span class="wg-diff-sign">${sign}</span><code>${text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}</code></div>`).join('');
  return `<div class="wegit-workbench ${compact ? 'wg-compact' : ''}" role="img" aria-label="${tr('workbench.description')}">
    <div class="wg-toolbar"><div class="wg-repository">${glyph('folder')}<span><strong>WeGit</strong><small>main</small></span></div><div class="wg-sync"><span class="wg-native-pill">${glyph('plum')} main <b>↑1 ↓0</b></span><span class="wg-native-pill">${glyph('cloud')}${tr('workbench.fetch')}</span><span class="wg-native-pill">${glyph('download')}${tr('workbench.pull')} <i>0</i></span><span class="wg-native-pill">${glyph('upload')}${tr('workbench.push')} <i>1</i></span><span class="wg-toolbar-symbol">${glyph('reset')}</span></div></div>
    <div class="wg-body"><aside class="wg-sidebar"><span class="wg-section-label">${tr('workbench.workspace')}</span>${nav.map(([name, key]) => `<div class="wg-nav-row ${key === 'changes' ? 'wg-nav-active' : ''}">${glyph(name)}<span>${tr('workbench.' + key)}</span>${key === 'changes' ? '<b>2</b>' : ''}</div>`).join('')}<span class="wg-section-label wg-repos-label">${tr('workbench.repositories')}</span><div class="wg-nav-row wg-repo-item">${glyph('folder')}<span>WeGit<small>main</small></span></div><div class="wg-brand"><img src="${asset('brand/symbol.png')}" width="24" height="24" alt=""><strong>WeGit</strong><span>+</span></div></aside>
      <div class="wg-main"><div class="wg-editors"><section class="wg-files"><div class="wg-files-heading">${glyph('brush')}<strong>${tr('workbench.changes')}</strong><b>2</b></div><div class="wg-search">${glyph('search')}<span>${tr('workbench.filter')}</span></div><div class="wg-file-group">☑ ${tr('workbench.staged')} (1)</div><div class="wg-file-row wg-file-selected"><span class="wg-check">✓</span>${glyph('bamboo')}<span><strong>Workbench.swift</strong><small>Sources</small></span><b>M</b></div><div class="wg-file-group">□ ${tr('workbench.untracked')} (1)</div><div class="wg-file-row">${glyph('bamboo')}<span><strong>Palette.swift</strong><small>Sources</small></span><b>?</b></div></section>
        <section class="wg-diff"><div class="wg-diff-heading"><div><strong>Sources/Workbench.swift</strong><small>${tr('workbench.index')} ↔ HEAD</small></div><span class="wg-diff-count">+3 <em>−3</em></span><span class="wg-layout-toggle">${tr('workbench.unified')}　${tr('workbench.split')}</span></div><div class="wg-diff-options">${tr('workbench.context')} <b>3 ${tr('workbench.lines')}</b><span>□ ${tr('workbench.whitespace')}</span></div><div class="wg-hunk-heading"><code>@@ −1,10 +1,10 @@</code><span>${tr('workbench.copyPatch')}</span></div><div class="wg-code">${code}</div></section></div>
        <div class="wg-commit"><div class="wg-draft"><span>${tr('workbench.draft')}</span><small>1 ${tr('workbench.staged')}　□ ${tr('workbench.amend')}</small></div><div class="wg-commit-actions"><span class="wg-commit-primary">${tr('workbench.commit')} (1)</span><span>${tr('workbench.commitPush')}</span></div></div></div></div></div>`;
}
