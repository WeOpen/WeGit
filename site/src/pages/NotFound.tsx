import { useEffect, useRef, useState } from 'react'
import { ErrorContent } from './ErrorContent'
import { Icon, SiteLink, Toast, useSite } from '../components/Site'
import { route } from '../lib/site'
import errorCss from '../../.generated/styles/error.css?url'

export function NotFound() {
  const { locale, tr, setOverlay, download } = useSite()
  const [open, setOpen] = useState(false), [query, setQuery] = useState('')
  const dialog = useRef<HTMLDialogElement>(null), input = useRef<HTMLInputElement>(null)
  const setSearchOpen = (value: boolean) => { setOpen(value); setOverlay(value) }
  useEffect(() => {
    if (open && dialog.current && !dialog.current.open) { document.body.classList.add('preview-open'); dialog.current.showModal(); input.current?.focus() }
  }, [open])
  useEffect(() => () => { setOverlay(false); document.body.classList.remove('preview-open') }, [])
  const results = [
    { label: 'WeGit ' + tr('error.aboutTitle'), href: route(locale) + '#features' },
    { label: tr('error.themeTitle'), href: route(locale, 'themes') },
    { label: tr('error.docsTitle'), href: 'https://github.com/WeOpen/WeGit/blob/main/docs/README.md' },
    { label: tr('error.downloadTitle'), href: download },
  ].filter(result => result.label.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))
  return <><title>404 — WeGit</title><meta name="description" content={tr('error.meta')} /><link rel="stylesheet" href={errorCss} /><ErrorContent setSearchOpen={setSearchOpen} />
    <dialog ref={dialog} id="error-search-dialog" className="error-search-dialog" aria-labelledby="error-search-title" onClose={() => { setSearchOpen(false); document.body.classList.remove('preview-open'); document.querySelector<HTMLButtonElement>('[data-action="open-search"]')?.focus({ preventScroll: true }) }} onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); dialog.current?.close() } }} onClick={event => {
      if (event.target !== event.currentTarget) return
      const box = event.currentTarget.getBoundingClientRect()
      if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) event.currentTarget.close()
    }}><div className="error-search-heading"><h2 id="error-search-title">{tr('error.searchTitle')}</h2><button className="icon-button" aria-label={tr('error.closeSearch')} onClick={() => dialog.current?.close()}><Icon name="close" /></button></div><label className="sr-only" htmlFor="error-search-input">{tr('error.searchLabel')}</label><input ref={input} id="error-search-input" type="text" inputMode="search" role="searchbox" autoComplete="off" placeholder={tr('error.searchPlaceholder')} value={query} onChange={event => setQuery(event.target.value)} /><div className="error-search-results">{results.map(result => <SiteLink key={result.href} href={result.href}>{result.label}</SiteLink>)}</div>{!results.length && <p id="error-search-empty">{tr('error.searchEmpty')}</p>}{open && <Toast />}</dialog>
  </>
}
