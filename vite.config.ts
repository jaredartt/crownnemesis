import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The site is served from the root of https://crownnemesis.com (a custom domain
// on GitHub Pages; public/CNAME tells Pages which one). Until v0.67 it lived
// under /crownnemesis/ on jaredartt.github.io, and GitHub redirects that old
// address to the new one, so the build no longer needs a path prefix.
export default defineConfig(() => ({
  plugins: [react()],
  base: '/',
  server: { port: 5173 },
}))
