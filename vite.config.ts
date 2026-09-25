import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GitHub Pages serves this repo from /crownnemesis/ (renamed from /tactica/
// -- Jared: "instead of '.../tactica', rename it to '.../crownnemesis'"), so
// the production build needs that prefix on its asset URLs. The dev server
// stays at the root.
export default defineConfig(({ mode }) => ({
  plugins: [react()],
  base: mode === 'production' ? '/crownnemesis/' : '/',
  server: { port: 5173 },
}))
