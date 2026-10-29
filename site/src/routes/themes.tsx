import { createFileRoute } from '@tanstack/react-router'
import { ThemesPage } from '../pages/ThemesPage'
import { pageHead } from '../lib/site'
import { themeSearch } from '../lib/search'

export const Route = createFileRoute('/themes')({ head: () => pageHead('en', 'themes'), component: ThemesPage, validateSearch: themeSearch })
