// The playground's page (dev/): `pnpm dev` serves it as it changes, and the smoke test builds it
// and drives what is built. The core's worker is an ES module (@kupcad/wasm imports in it), which
// Vite bundles a worker as only in development otherwise.

import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vite';

/** Where the page is served, in development and built. */
export const PORT = 4321;

const server = { host: '127.0.0.1', port: PORT, strictPort: true };

export default defineConfig({
  root: import.meta.dirname,
  plugins: [svelte()],
  server,
  preview: server,
  // Built beside the sources, not among them: dist/ of the package
  build: { outDir: '../dist', emptyOutDir: true },
  worker: { format: 'es' },
});
