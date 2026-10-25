// The site: Astro, its pages' interactive parts Svelte components (the playground). The core's
// worker is an ES module (@kupcad/wasm imports in it), as Vite bundles a worker by default
// only in development.
import svelte from '@astrojs/svelte';
import { defineConfig } from 'astro/config';

/** Where `pnpm dev` and `pnpm preview` serve the site. */
export const PORT = 4321;

export default defineConfig({
  integrations: [svelte()],
  server: { host: '127.0.0.1', port: PORT },
  vite: { worker: { format: 'es' } },
});
