import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vite';

/** Where the smoke pages are served, for Playwright. */
export const PORT = 5179;

export default defineConfig({
  root: import.meta.dirname,
  // pane.html mounts the Svelte ViewerPane
  plugins: [svelte({ configFile: false })],
  server: { host: '127.0.0.1', port: PORT, strictPort: true },
});
