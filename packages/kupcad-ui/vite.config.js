import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [svelte(), svelteTesting()],
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.js'],
    // The panels' tests mount the viewer
    setupFiles: ['@kupcad/viewer/testing'],
    // Imported by Node itself, so the module finds its wasm by its own URL (see @kupcad/viewer's)
    server: { deps: { external: [/kupcad-wasm\/src/] } },
  },
});
