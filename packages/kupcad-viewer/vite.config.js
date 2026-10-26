import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vitest/config';
import { SVELTE_TESTS } from '../../vitest.svelte.js';

export default defineConfig({
  plugins: [svelte({ configFile: false }), svelteTesting()],
  test: { ...SVELTE_TESTS, setupFiles: ['src/testing.js'] },
});
