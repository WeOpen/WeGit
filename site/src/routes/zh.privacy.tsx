import { createFileRoute } from '@tanstack/react-router'
import { PrivacyPage } from '../pages/PrivacyPage'
import { pageHead } from '../lib/site'

export const Route = createFileRoute('/zh/privacy')({ head: () => pageHead('zh', 'privacy'), component: PrivacyPage })
