/** One header selection for the current page and its feature anchor. */
export function topNavigationItem(pathname, hash = '') {
  const page = pathname.replace(/^\/zh(?=\/|$)/, '').replace(/\/$/, '') || '/';
  if (page === '/') return hash.replace(/^#/, '') === 'features' ? 'features' : 'product';
  return page === '/themes' ? 'themes' : null;
}
