export function themeSearch(input: Record<string, unknown>): { theme?: string } {
  return typeof input.theme === 'string' && input.theme.length <= 100 ? { theme: input.theme } : {}
}
