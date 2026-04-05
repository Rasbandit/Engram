import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import typography from '@tailwindcss/typography'

export default defineConfig({
  plugins: [react(), tailwindcss({ plugins: [typography] })],
  base: '/app/',
  build: {
    outDir: '../priv/static/app',
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:4000',
      '/socket': {
        target: 'http://localhost:4000',
        ws: true,
      },
    },
  },
})
