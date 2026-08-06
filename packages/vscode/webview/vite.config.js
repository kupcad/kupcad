import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  plugins: [],
  root: resolve(__dirname),
  build: {
    outDir: resolve(__dirname, '../dist-webview'),
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    strictPort: true,
  },
});
