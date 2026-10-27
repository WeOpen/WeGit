// Resolve appearance before styles and background images load.
try {
  const saved = localStorage.getItem('wegit-site-mode');
  document.documentElement.dataset.siteMode = ['light', 'dark'].includes(saved)
    ? saved : (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
} catch {
  document.documentElement.dataset.siteMode = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
