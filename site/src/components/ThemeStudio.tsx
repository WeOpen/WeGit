import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import { useNavigate, useSearch } from '@tanstack/react-router'
import { catalog, type ThemeDocument, type ThemeRecord } from '../lib/catalog'
import { decodeTheme, MAX_THEME_BYTES, prepareTheme } from '../scripts/theme-model.js'
import { Icon, Toast, useSite, Workbench } from './Site'
import { translate } from '../lib/site'

type Contrast = 'soft' | 'normal' | 'high'
type Studio = {
  records: ThemeRecord[]; selected: ThemeRecord; prepared: ThemeDocument; open: boolean
  accent: string | null; contrast: Contrast; font: string; fontSize: number
  setAccent: (value: string) => void; setContrast: (value: Contrast) => void
  setFont: (value: string) => void; setFontSize: (value: number) => void
  openTheme: (id: string, trigger?: HTMLElement) => void; close: () => void
  download: (id?: string, importing?: boolean) => void; importFile: (file: File, trigger: HTMLElement) => Promise<void>; reset: () => void
}
const Context = createContext<Studio | null>(null)
export function useThemeStudio() { const value = useContext(Context); if (!value) throw new Error('Missing theme studio'); return value }

export function ThemeStudioProvider({ children }: { children: ReactNode }) {
  const { locale, tr, notify, setOverlay, themeDraft } = useSite()
  const navigate = useNavigate()
  const search = useSearch({ strict: false })
  const query = typeof search.theme === 'string' ? search.theme : null
  const [records, setRecords] = useState<ThemeRecord[]>(() => themeDraft.current?.records ?? catalog)
  const [selected, setSelected] = useState(() => themeDraft.current?.selected ?? catalog.find(theme => theme.id === 'dark')!)
  const [open, setOpen] = useState(false)
  const [accent, setAccent] = useState<string | null>(() => themeDraft.current?.accent ?? null)
  const [contrast, setContrast] = useState<Contrast>(() => themeDraft.current?.contrast ?? 'normal')
  const [font, setFont] = useState(() => themeDraft.current?.font ?? 'system')
  const [fontSize, setFontSize] = useState(() => themeDraft.current?.fontSize ?? 13)
  const trigger = useRef<HTMLElement | null>(null)
  const prepared = prepareTheme(selected.document, { accent, contrast }) as ThemeDocument
  const resetValues = () => { setAccent(null); setContrast('normal'); setFont('system'); setFontSize(13) }
  useEffect(() => {
    const theme = records.find(theme => theme.id === query)
    if (theme) { setSelected(theme); if (themeDraft.current?.selected.id !== theme.id) resetValues(); setOpen(true); setOverlay(true) }
  }, [query])
  useEffect(() => { themeDraft.current = { records, selected, accent, contrast, font, fontSize } }, [records, selected, accent, contrast, font, fontSize, themeDraft])
  useEffect(() => () => { setOverlay(false); document.body.classList.remove('preview-open') }, [])
  const show = (theme: ThemeRecord, element?: HTMLElement) => {
    trigger.current = element ?? null; setSelected(theme); resetValues(); setOpen(true); setOverlay(true)
    void navigate({ to: locale === 'zh' ? '/zh/themes/' : '/themes/', search: { theme: theme.id }, replace: true, resetScroll: false })
  }
  const close = () => {
    setOpen(false); setOverlay(false); document.body.classList.remove('preview-open')
    void navigate({ to: locale === 'zh' ? '/zh/themes/' : '/themes/', search: {}, replace: true, resetScroll: false })
    if (trigger.current?.isConnected) trigger.current.focus({ preventScroll: true })
  }
  const download = (id = selected.id, importing = false) => {
    const theme = records.find(theme => theme.id === id)
    if (!theme) return
    const value = id === selected.id ? prepared : theme.document
    const url = URL.createObjectURL(new Blob([JSON.stringify(value, null, 2) + '\n'], { type: 'application/json;charset=utf-8' }))
    const link = document.createElement('a'); link.href = url; link.download = 'WeGit-' + id.replace(/[^a-z0-9-]/gi, '-') + '.json'
    document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 2000)
    notify(tr(importing ? 'toast.importInstructions' : 'toast.themeDownload'))
  }
  const importFile = async (file: File, element: HTMLElement) => {
    if (file.size > MAX_THEME_BYTES) { notify(tr('toast.invalidFile')); return }
    try {
      const document = decodeTheme(await file.text()) as ThemeDocument
      const theme: ThemeRecord = { ...catalog[0], id: 'custom-' + crypto.randomUUID(), name: { en: document.name, zh: document.name }, description: { en: translate('en', 'themes.customDescription'), zh: translate('zh', 'themes.customDescription') }, document }
      setRecords(previous => [...previous, theme]); show(theme, element); notify(tr('toast.imported'))
    } catch { notify(tr('toast.invalidFile')) }
  }
  return <Context.Provider value={{ records, selected, prepared, open, accent, contrast, font, fontSize, setAccent, setContrast, setFont, setFontSize, openTheme: (id, element) => { const theme = records.find(theme => theme.id === id); if (theme) show(theme, element) }, close, download, importFile, reset: () => { resetValues(); notify(tr('toast.reset')) } }}>{children}<ThemePreviewDialog /></Context.Provider>
}
export function ThemeGallery() {
  const { locale, tr } = useSite(), studio = useThemeStudio()
  return <div className="theme-card-grid" id="theme-catalog">{studio.records.map(theme => <article className="theme-card" key={theme.id} data-theme-id={theme.id}><Workbench theme={theme.document} compact /><div className="theme-card-title"><h3>{theme.name[locale]}</h3><span className="theme-tag">{theme.name.en}</span></div><p>{theme.description[locale]}</p><div className="theme-card-actions">
    <button className="button button-red" data-download-theme={theme.id} aria-label={tr('btn.downloadTheme') + ' ' + theme.name[locale]} title={tr('btn.downloadTheme') + ' ' + theme.name[locale]} onClick={() => studio.download(theme.id)}><Icon name="download" /><span className="theme-action-label">{tr('btn.downloadTheme')}</span></button>
    <button className="button button-white" data-select-theme={theme.id} aria-label={tr('btn.previewTheme') + ' ' + theme.name[locale]} title={tr('btn.previewTheme') + ' ' + theme.name[locale]} onClick={event => studio.openTheme(theme.id, event.currentTarget)}><Icon name="window" /><span className="theme-action-label">{tr('btn.previewTheme')}</span></button>
    <button className="button button-white" aria-label={(locale === 'zh' ? '导入' : 'Import') + ' ' + theme.name[locale]} title={(locale === 'zh' ? '导入' : 'Import') + ' ' + theme.name[locale]} onClick={() => studio.download(theme.id, true)}><Icon name="upload" /><span className="theme-action-label">{locale === 'zh' ? '导入' : 'Import'}</span></button>
  </div></article>)}</div>
}
export function ThemeImport() {
  const { tr } = useSite(), studio = useThemeStudio()
  const input = useRef<HTMLInputElement>(null), trigger = useRef<HTMLButtonElement>(null)
  return <div className="import-custom"><div><h3>{tr('themes.yourOwn')}</h3><p>{tr('themes.yourOwnDesc')}</p></div><button className="button button-white import-label" id="theme-import-button" ref={trigger} onClick={() => input.current?.click()}>{tr('btn.importTheme')}<Icon name="upload" /></button><input type="file" id="theme-file-input" ref={input} accept=".json,.wegit-theme,application/json" hidden onChange={event => { const file = event.target.files?.[0]; event.target.value = ''; if (file && trigger.current) void studio.importFile(file, trigger.current) }} /></div>
}
function ThemePreviewDialog() {
  const { locale, tr } = useSite(), studio = useThemeStudio()
  const dialog = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const node = dialog.current
    if (studio.open && node && !node.open) { document.body.classList.add('preview-open'); node.showModal() }
    else if (!studio.open && node?.open) node.close()
  }, [studio.open])
  return <dialog ref={dialog} className="theme-preview-dialog" id="theme-preview-dialog" aria-labelledby="current-theme-label" onClose={studio.close} onClick={event => {
    if (event.target !== event.currentTarget) return
    const bounds = event.currentTarget.getBoundingClientRect()
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) event.currentTarget.close()
  }}><header className="preview-dialog-heading"><h2 id="current-theme-label">{studio.selected.name[locale]}</h2><button className="icon-button preview-close" aria-label={tr('a11y.closePreview')} onClick={() => dialog.current?.close()}><Icon name="close" /></button></header><div className="preview-dialog-grid"><div className="preview-dialog-stage"><div id="theme-live-preview"><Workbench theme={studio.prepared} font={studio.font} fontSize={studio.fontSize} /></div><p className="preview-caption">{tr('workbench.previewNote')}</p></div><aside className="theme-settings"><h3>{tr('themes.settingsTitle')}</h3><span className="form-label" id="accent-label">{tr('themes.accent')}</span><div className="color-picker" id="accent-picker" role="group" aria-labelledby="accent-label">{['#B3322D', '#268AE5', '#12AA73', '#FF8A1C', '#8E59E8', '#EF6B99'].map(color => <button key={color} className={'color-chip' + ((studio.accent || studio.selected.document.colors.accent) === color ? ' selected' : '')} style={{ background: color }} aria-label={'Accent ' + color} aria-pressed={(studio.accent || studio.selected.document.colors.accent) === color} onClick={() => studio.setAccent(color)} />)}</div>
    <div className="settings-row"><span className="form-label" id="contrast-label">{tr('themes.contrast')}</span><div className="segmented" id="contrast-selector" role="group" aria-labelledby="contrast-label">{(['soft', 'normal', 'high'] as const).map(value => <button key={value} className={studio.contrast === value ? 'selected' : ''} aria-pressed={studio.contrast === value} onClick={() => studio.setContrast(value)}>{tr('themes.' + value)}</button>)}</div></div>
    <div className="settings-row"><label className="form-label" htmlFor="font-select">{tr('themes.font')}</label><select id="font-select" value={studio.font} onChange={event => studio.setFont(event.target.value)}><option value="system">{tr('themes.systemFont')}</option><option value="mono">{tr('themes.monoFont')}</option></select></div><div className="settings-row"><label className="form-label" htmlFor="font-size">{tr('themes.fontSize')}</label><input id="font-size" type="range" min="11" max="16" step="1" value={studio.fontSize} onChange={event => studio.setFontSize(Number(event.target.value))} /><output id="font-size-output" htmlFor="font-size">{studio.fontSize}px</output></div><p className="preview-scope">{tr('themes.previewScope')}</p><div className="settings-divider" /><div className="settings-actions">
      <button className="button button-red full" id="preview-download" onClick={() => studio.download()}><Icon name="download" />{tr('btn.downloadTheme')}</button><button className="button button-white full" id="preview-import" onClick={() => studio.download(undefined, true)}>{tr('btn.importToWeGit')}<Icon name="arrow" /></button><button className="text-button" id="reset-theme" onClick={studio.reset}><Icon name="reset" />{tr('themes.reset')}</button>
    </div></aside></div>{studio.open && <Toast />}</dialog>
}
