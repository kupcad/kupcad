import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [svelte(), svelteTesting()],
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.js'],
    setupFiles: ['src/testing.js'],
    // Imported by Node itself: under jsdom, Vite would make the module's URL of its wasm one its
    // dev server serves, and the tests run none
    server: { deps: { external: [/kupcad-wasm\/src/] } },
  },
});
