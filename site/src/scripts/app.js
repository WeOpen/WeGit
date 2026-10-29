import { translations } from './translations.js';
import { collection } from './themes.js';
import { selectRelease } from './release.mjs';
import { decodeTheme, MAX_THEME_BYTES, prepareTheme, previewProperties } from './theme-model.js';
import { workbenchHTML } from './workbench.js';
import { icon } from './icons.js';
import { initAnimations } from './animations.js';
import { initParticleFooter } from './footer-effect.js';

const BASE = document.body.dataset.base || '';
const asset = path => `${BASE}/assets/${path}`;
const themes = Object.fromEntries(collection.map(theme => [theme.id, theme]));
const accents = ['#B3322D', '#268AE5', '#12AA73', '#FF8A1C', '#8E59E8', '#EF6B99'];
let lang = document.documentElement.lang.startsWith('zh') ? 'zh' : 'en';
if (document.body.dataset.page === '404' && location.pathname.split('/').includes('zh')) lang = 'zh';
let currentId = 'dark';
let accentOverride = null;
let contrast = 'normal';
let fontType = 'system';
let fontSize = 13;
let toastTimer;
let release = null;
let previewTrigger = null;

function safeLoad(key, fallback) { try { return localStorage.getItem(key) || fallback; } catch { return fallback; } }
function safeSave(key, value) { try { localStorage.setItem(key, value); } catch { /* Private browsing can disable storage. */ } }
function tr(key) { return translations[lang][key] || key; }
function route(page = 'home') {
  const suffix = { home: '', themes: 'themes/', privacy: 'privacy/', '404': '404.html' }[page] || '';
  return `${BASE}/${lang === 'zh' ? 'zh/' : ''}${suffix}`;
}
function themeTitle(theme) { return typeof theme.name === 'string' ? theme.name : theme.name[lang]; }
function themeDesc(theme) { return typeof theme.description === 'string' ? theme.description : theme.description[lang]; }
function toast(message) {
  const element = document.getElementById('toast');
  if (!element) return;
  const dialog = document.getElementById('theme-preview-dialog');
  (dialog?.open ? dialog : document.body).append(element);
  element.textContent = message; element.classList.add('shown');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => element.classList.remove('shown'), 4200);
}

function paint(element, document) {
  element.dataset.previewTheme = document.controls;
  for (const [key, value] of Object.entries(previewProperties(document))) element.style.setProperty(key, value);
}

function clonePreview(theme, className = 'tiny-app') {
  const element = document.createElement('div');
  element.className = `mock-host ${className}`;
  element.innerHTML = workbenchHTML(tr, asset, { compact: true });
  paint(element, theme.document);
  element.setAttribute('aria-hidden', 'true');
  return element;
}

function mountMocks() {
  document.querySelectorAll('.mock-host:not(.tiny-app)').forEach(element => {
    const originalId = element.dataset.themeId || element.dataset.previewTheme;
    element.dataset.themeId = originalId;
    const theme = themes[originalId] || themes.light;
    element.innerHTML = workbenchHTML(tr, asset);
    paint(element, theme.document);
  });
}

function renderHomeThemes() {
  const root = document.getElementById('home-themes'); if (!root) return;
  root.replaceChildren();
  Object.values(themes).slice(0, 4).forEach(theme => {
    const link = document.createElement('a'); link.className = 'theme-mini-item';
    link.href = `${route('themes')}?theme=${encodeURIComponent(theme.id)}`;
    const title = document.createElement('h3'); title.textContent = themeTitle(theme);
    const name = document.createElement('p'); name.textContent = theme.name.en;
    link.append(clonePreview(theme), title, name); root.append(link);
  });
}

function renderThemeGallery() {
  const root = document.getElementById('theme-catalog'); if (!root) return;
  root.replaceChildren();
  Object.values(themes).forEach(theme => {
    const card = document.createElement('article'); card.className = 'theme-card'; card.dataset.themeId = theme.id;
    const row = document.createElement('div'); row.className = 'theme-card-title';
    const title = document.createElement('h3'); title.textContent = themeTitle(theme);
    const tag = document.createElement('span'); tag.className = 'theme-tag'; tag.textContent = theme.name.en;
    row.append(title, tag);
    const description = document.createElement('p'); description.textContent = themeDesc(theme);
    const actions = document.createElement('div'); actions.className = 'theme-card-actions';
    for (const [action, label, classes] of [['downloadTheme', tr('btn.downloadTheme'), 'button-red'], ['selectTheme', tr('btn.previewTheme'), 'button-white'], ['importTheme', lang === 'zh' ? '导入' : 'Import', 'button-white']]) {
      const button = document.createElement('button'); button.className = 'button ' + classes; button.dataset[action] = theme.id;
      button.setAttribute('aria-label', `${label} ${themeTitle(theme)}`);
      button.title = `${label} ${themeTitle(theme)}`;
      if (action === 'selectTheme') button.dataset.goPreview = 'true';
      const motif = action === 'downloadTheme' ? 'download' : action === 'selectTheme' ? 'window' : 'upload';
      const text = document.createElement('span'); text.className = 'theme-action-label'; text.textContent = label;
      button.innerHTML = icon(motif, asset); button.append(text); actions.append(button);
    }
    card.append(clonePreview(theme), row, description, actions); root.append(card);
  });
}

function renderIcons() {
  const root = document.getElementById('icon-sizes'); if (!root) return;
  root.replaceChildren();
  for (const [display, pixels] of [[120, 512], [83, 256], [64, 128], [48, 64], [35, 32], [24, 16]]) {
    const item = document.createElement('div'); item.className = 'icon-size-item'; item.style.setProperty('--icon-size', `${display}px`);
    const image = document.createElement('img'); image.dataset.brandIcon = String(pixels); image.width = pixels; image.height = pixels;
    image.src = asset(`brand/icon-${document.documentElement.dataset.siteMode}-${pixels}.png`); image.loading = 'lazy'; image.alt = `WeGit ${pixels} × ${pixels}`;
    const size = document.createElement('small'); size.textContent = `${pixels} × ${pixels}`;
    const label = document.createElement('small'); label.textContent = lang === 'zh' ? '应用图标' : 'App icon';
    item.append(image, size, label); root.append(item);
  }
}

function siteMode(mode) {
  document.documentElement.dataset.siteMode = mode; safeSave('wegit-site-mode', mode);
  document.querySelectorAll('.mode-symbol').forEach(element => { element.innerHTML = icon('taiji', asset); });
  document.querySelectorAll('.mode-toggle').forEach(button => {
    button.setAttribute('aria-label', tr(mode === 'dark' ? 'a11y.toLight' : 'a11y.toDark'));
    button.setAttribute('title', tr(mode === 'dark' ? 'a11y.toLight' : 'a11y.toDark'));
    button.setAttribute('aria-pressed', String(mode === 'dark'));
  });
  document.querySelectorAll('[data-native-image]').forEach(image => {
    const path = asset(`screenshots/wegit-${mode}.webp`);
    if (image.getAttribute('src') !== path) image.src = path;
    image.alt = tr('workbench.description');
  });
  document.querySelectorAll('[data-brand-icon]').forEach(image => { image.src = asset(`brand/icon-${mode}-${image.dataset.brandIcon}.png`); });
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', mode === 'dark' ? '#151719' : '#faf8f3');
  document.dispatchEvent(new CustomEvent('wegit:appearance'));
}

function applyI18n() {
  document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
  document.querySelectorAll('[data-i18n]').forEach(element => { element.textContent = tr(element.dataset.i18n); });
  document.querySelectorAll('[data-i18n-html]').forEach(element => { element.innerHTML = tr(element.dataset.i18nHtml); });
  document.querySelectorAll('.lang-toggle').forEach(element => { element.textContent = lang === 'zh' ? 'EN' : '中文'; });
  document.querySelectorAll('[data-route]').forEach(link => { link.href = route(link.dataset.route) + (link.dataset.section ? '#' + link.dataset.section : ''); });
  if (['home', 'themes'].includes(document.body.dataset.page)) {
    document.title = document.body.dataset.page === 'themes' ? (lang === 'zh' ? 'WeGit — 主题中心' : 'WeGit — Theme Studio') : (lang === 'zh' ? 'WeGit — 原生 macOS Git 客户端' : 'WeGit — Native macOS Git Client');
  }
  mountMocks(); renderHomeThemes(); renderThemeGallery(); renderIcons(); applyLiveTheme();
  siteMode(document.documentElement.dataset.siteMode);
  document.querySelector('.preview-close')?.setAttribute('aria-label', tr('a11y.closePreview'));
  const reset = document.getElementById('reset-theme');
  if (reset) { reset.innerHTML = icon('reset', asset); const label = document.createElement('span'); label.textContent = tr('themes.reset'); reset.append(label); }
  const menu = document.querySelector('[data-action="toggle-menu"]');
  menu?.setAttribute('aria-label', tr(menu.getAttribute('aria-expanded') === 'true' ? 'a11y.closeMenu' : 'a11y.openMenu'));
  document.getElementById('year').textContent = String(new Date().getFullYear());
}

function applyLiveTheme() {
  const element = document.getElementById('theme-live-preview'); if (!element) return;
  const theme = themes[currentId] || themes.dark;
  paint(element, prepareTheme(theme.document, { accent: accentOverride, contrast }));
  element.dataset.appFont = fontType; element.style.setProperty('--mock-font-size', `${fontSize}px`);
  document.getElementById('current-theme-label').textContent = themeTitle(theme);
  document.querySelectorAll('#accent-picker .color-chip').forEach(button => {
    const selected = button.dataset.accent === (accentOverride || theme.document.colors.accent);
    button.classList.toggle('selected', selected); button.setAttribute('aria-pressed', String(selected));
  });
  document.querySelectorAll('#contrast-selector button').forEach(button => { button.classList.toggle('selected', button.dataset.contrast === contrast); button.setAttribute('aria-pressed', String(button.dataset.contrast === contrast)); });
  document.getElementById('font-select').value = fontType;
  document.getElementById('font-size').value = fontSize;
  document.getElementById('font-size-output').value = `${fontSize}px`;
}

function selectTheme(id, open = false, trigger = null) {
  if (!themes[id]) return;
  currentId = id; accentOverride = null; contrast = 'normal'; fontType = 'system'; fontSize = 13;
  applyLiveTheme(); safeSave('wegit-selected-theme', id);
  const url = new URL(location.href); url.searchParams.set('theme', id); history.replaceState(null, '', url);
  if (open) openPreview(trigger);
}

function openPreview(trigger = null) {
  const dialog = document.getElementById('theme-preview-dialog');
  if (!dialog) return;
  previewTrigger = trigger instanceof HTMLElement ? trigger : document.querySelector(`[data-select-theme="${CSS.escape(currentId)}"]`);
  document.body.classList.add('preview-open');
  if (!dialog.open) dialog.showModal();
}

function makeThemeData(id = currentId) {
  const theme = themes[id];
  return prepareTheme(theme.document, id === currentId ? { accent: accentOverride, contrast } : {});
}

function downloadTheme(id = currentId) {
  if (!themes[id]) return;
  const blob = new Blob([JSON.stringify(makeThemeData(id), null, 2) + '\n'], { type: 'application/json;charset=utf-8' });
  const url = URL.createObjectURL(blob); const link = document.createElement('a');
  link.href = url; link.download = `WeGit-${id.replace(/[^a-z0-9-]/gi, '-')}.json`;
  document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 2000);
  toast(tr('toast.themeDownload'));
}

async function loadThemeFile(file, trigger) {
  if (!file || file.size > MAX_THEME_BYTES) { toast(tr('toast.invalidFile')); return; }
  try {
    const document = decodeTheme(await file.text()); const id = 'custom-' + crypto.randomUUID();
    themes[id] = { id, name: { zh: document.name, en: document.name }, description: { zh: translations.zh['themes.customDescription'], en: translations.en['themes.customDescription'] }, document };
    renderThemeGallery(); selectTheme(id, true, trigger); toast(tr('toast.imported'));
  } catch { toast(tr('toast.invalidFile')); }
}

function setMenu(open, restoreFocus = false) {
  document.getElementById('main-nav').classList.toggle('open', open);
  const toggle = document.querySelector('[data-action="toggle-menu"]'); toggle.setAttribute('aria-expanded', String(open));
  toggle.setAttribute('aria-label', tr(open ? 'a11y.closeMenu' : 'a11y.openMenu'));
  const symbol = toggle.querySelector('.menu-symbol'); if (symbol) symbol.innerHTML = icon(open ? 'close' : 'fan', asset);
  if (restoreFocus) toggle.focus();
}

async function loadRelease() {
  try {
    const response = await fetch(`${BASE}/releases.json`, { signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error('Release snapshot unavailable');
    release = selectRelease(await response.json());
    for (const [id, url] of [['release-checksum', release?.checksum], ['release-manifest', release?.manifest]]) {
      const link = document.getElementById(id); if (link && release?.download && url) { link.href = url; link.hidden = false; }
    }
  } catch { release = null; }
  document.querySelectorAll('[data-action="app-download"]').forEach(button => {
    const link = document.createElement('a');
    for (const attribute of button.attributes) link.setAttribute(attribute.name, attribute.value);
    link.href = release?.download || release?.notes || 'https://github.com/WeOpen/WeGit/releases';
    link.innerHTML = button.innerHTML; button.replaceWith(link);
  });
}

function init() {
  const mode = safeLoad('wegit-site-mode', ''); siteMode(['light', 'dark'].includes(mode) ? mode : (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
  const query = new URLSearchParams(location.search).get('theme'); const saved = safeLoad('wegit-selected-theme', 'dark');
  currentId = themes[query] ? query : themes[saved] ? saved : 'dark';
  const picker = document.getElementById('accent-picker');
  if (picker) for (const color of accents) {
    const button = document.createElement('button'); button.className = 'color-chip'; button.dataset.accent = color; button.style.background = color; button.setAttribute('aria-label', `Accent ${color}`); picker.append(button);
  }
  applyI18n();
  initParticleFooter();
  if (document.body.dataset.page === '404') import('./error-page.js').then(({ initErrorPage }) => initErrorPage({ tr, setMenu }));
  else initAnimations();
  loadRelease();
  const dialog = document.getElementById('theme-preview-dialog');
  if (dialog) {
    dialog.addEventListener('close', () => {
      document.body.classList.remove('preview-open');
      const notification = document.getElementById('toast'); if (notification) document.body.append(notification);
      const url = new URL(location.href); url.searchParams.delete('theme');
      if (url.hash === '#preview') url.hash = '';
      history.replaceState(null, '', url);
      if (previewTrigger?.isConnected) previewTrigger.focus({ preventScroll: true });
    });
    dialog.addEventListener('click', event => {
      if (event.target !== dialog) return;
      const box = dialog.getBoundingClientRect();
      if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) dialog.close();
    });
    if (query && themes[query]) openPreview();
  }
  document.addEventListener('click', event => {
    const target = event.target.closest('button,a'); if (!target) return;
    const action = target.dataset.action;
    if (action === 'toggle-lang') {
      lang = lang === 'zh' ? 'en' : 'zh'; safeSave('wegit-language', lang);
      const url = new URL(location.href); url.pathname = route(document.body.dataset.page);
      if (!['home', 'themes'].includes(document.body.dataset.page)) { location.href = url.href; return; }
      applyI18n(); history.replaceState(null, '', url); return;
    }
    if (action === 'toggle-mode') { siteMode(document.documentElement.dataset.siteMode === 'dark' ? 'light' : 'dark'); return; }
    if (action === 'toggle-menu') { setMenu(target.getAttribute('aria-expanded') !== 'true'); return; }
    if (action === 'app-download') {
      if (target.tagName !== 'A') location.href = release?.download || release?.notes || 'https://github.com/WeOpen/WeGit/releases';
      return;
    }
    if (action === 'close-preview') { dialog?.close(); return; }
    if (action === 'import-theme-file') { document.getElementById('theme-file-input')?.click(); return; }
    if (target.dataset.selectTheme) { selectTheme(target.dataset.selectTheme, target.dataset.goPreview === 'true', target); return; }
    if (target.dataset.downloadTheme) { downloadTheme(target.dataset.downloadTheme); return; }
    if (target.dataset.importTheme) { downloadTheme(target.dataset.importTheme); toast(tr('toast.importInstructions')); return; }
    if (target.dataset.accent) { accentOverride = target.dataset.accent; applyLiveTheme(); return; }
    if (target.dataset.contrast) { contrast = target.dataset.contrast; applyLiveTheme(); return; }
    if (target.id === 'preview-download') { downloadTheme(); return; }
    if (target.id === 'preview-import') { downloadTheme(); toast(tr('toast.importInstructions')); return; }
    if (target.id === 'reset-theme') { accentOverride = null; contrast = 'normal'; fontType = 'system'; fontSize = 13; applyLiveTheme(); toast(tr('toast.reset')); return; }
    if (target.closest('.main-nav')) setMenu(false);
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !dialog?.open && document.getElementById('main-nav').classList.contains('open')) setMenu(false, true);
  });
  matchMedia('(min-width: 861px)').addEventListener('change', event => { if (event.matches) setMenu(false); });
  document.getElementById('font-select')?.addEventListener('change', event => { fontType = event.target.value; applyLiveTheme(); });
  document.getElementById('font-size')?.addEventListener('input', event => { fontSize = Number(event.target.value); applyLiveTheme(); });
  document.getElementById('theme-file-input')?.addEventListener('change', event => { loadThemeFile(event.target.files[0], document.getElementById('theme-import-button')); event.target.value = ''; });
}

init();
