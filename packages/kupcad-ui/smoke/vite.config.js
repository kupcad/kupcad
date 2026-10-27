import { defineConfig } from 'vite';

/** Where the smoke page is served, for Playwright. */
export const PORT = 5179;

export default defineConfig({
  root: import.meta.dirname,
  server: { host: '127.0.0.1', port: PORT, strictPort: true },
});
