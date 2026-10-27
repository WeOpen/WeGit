/** Recovery actions remain local and work for both /404.html and missing document URLs. */
export function initErrorPage({ tr, setMenu }) {
  const updateArt = () => {
    const dark = document.documentElement.dataset.siteMode === 'dark';
    document.querySelectorAll('[data-error-dark]').forEach(source => { source.media = dark ? 'all' : 'not all'; });
  };
  updateArt();
  document.addEventListener('wegit:appearance', updateArt);
  const dialog = document.getElementById('error-search-dialog');
  const input = document.getElementById('error-search-input');
  const trigger = document.querySelector('[data-action="open-search"]');
  trigger.setAttribute('aria-label', tr('error.searchLabel'));
  dialog.querySelector('[data-action="close-search"]').setAttribute('aria-label', tr('error.closeSearch'));
  input.placeholder = tr('error.searchPlaceholder');
  document.addEventListener('click', event => {
    const button = event.target.closest('[data-action]');
    if (!button) return;
    if (button.dataset.action === 'reload-page') { location.reload(); return; }
    if (button.dataset.action === 'open-search') { setMenu(false); document.body.classList.add('preview-open'); dialog.showModal(); input.focus(); }
    if (button.dataset.action === 'close-search') dialog.close();
  });
  dialog.addEventListener('close', () => { document.body.classList.remove('preview-open'); trigger.focus({ preventScroll: true }); });
  // Keep Escape a single-step exit even when the search field contains text.
  dialog.addEventListener('keydown', event => {
    if (event.key === 'Escape') { event.preventDefault(); dialog.close(); }
  });
  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const rect = dialog.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
  });
  input.addEventListener('input', () => {
    const query = input.value.trim().toLocaleLowerCase();
    let count = 0;
    document.querySelectorAll('[data-search-item]').forEach(link => {
      link.hidden = !link.textContent.toLocaleLowerCase().includes(query);
      if (!link.hidden) count++;
    });
    document.getElementById('error-search-empty').hidden = count !== 0;
  });
}
