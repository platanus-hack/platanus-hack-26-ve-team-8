import type { ReactNode } from 'react'
import { createRootRoute, HeadContent, Outlet, Scripts } from '@tanstack/react-router'
import css from '../styles.css?url'

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { title: 'Arkangel — an AI investigator for your Mac' },
      {
        name: 'description',
        content: 'A local, privacy-first macOS investigator that uses Claude to explain what is running on your Mac, with evidence.',
      },
    ],
    links: [
      { rel: 'stylesheet', href: css },
      { rel: 'icon', type: 'image/png', href: '/icon.png' },
    ],
  }),
  component: () => (
    <Document>
      <Outlet />
    </Document>
  ),
})

function Document({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}
