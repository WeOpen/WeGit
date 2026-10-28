import { createRouter } from '@tanstack/react-router'
import { routeTree } from './routeTree.gen'
import { createIsomorphicFn } from '@tanstack/react-start'
import { getRequestHeader } from '@tanstack/react-start/server'

const getNonce = createIsomorphicFn().server(() => getRequestHeader('x-wegit-csp-nonce')).client(() => document.querySelector<HTMLMetaElement>('meta[name="csp-nonce"]')?.content)

export function getRouter() {
  return createRouter({ routeTree, scrollRestoration: true, trailingSlash: 'always', defaultPreload: 'intent', ssr: { nonce: getNonce() } })
}
declare module '@tanstack/react-router' {
  interface Register { router: ReturnType<typeof getRouter> }
}
