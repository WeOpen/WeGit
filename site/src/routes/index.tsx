import { createFileRoute } from '@tanstack/react-router'
import { HomePage } from '../pages/HomePage'
import { pageHead } from '../lib/site'

export const Route = createFileRoute('/')({ head: () => pageHead('en', 'home'), component: HomePage })
