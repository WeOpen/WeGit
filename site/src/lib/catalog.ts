import entries from '../../data/themes.json'
export type ThemeDocument = { version: 1; name: string; controls: 'light' | 'dark'; colors: Record<string, string> }
export type ThemeRecord = (typeof entries)[number] & { document: ThemeDocument }
export type ThemeDraft = { records: ThemeRecord[]; selected: ThemeRecord; accent: string | null; contrast: 'soft' | 'normal' | 'high'; font: string; fontSize: number }
const documents = import.meta.glob<ThemeDocument>('../../public/themes/*.json', { eager: true, import: 'default' })
export const catalog: ThemeRecord[] = entries.map(entry => ({ ...entry, document: documents['../../public/themes/' + entry.id + '.json'] }))
