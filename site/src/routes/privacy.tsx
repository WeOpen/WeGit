import { createFileRoute } from '@tanstack/react-router'
import { PrivacyPage } from '../pages/PrivacyPage'
import { pageHead } from '../lib/site'

export const Route = createFileRoute('/privacy')({ head: () => pageHead('en', 'privacy'), component: PrivacyPage })
