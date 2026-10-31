import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vitest/config';
import { SVELTE_TESTS } from '../../vitest.svelte.js';

export default defineConfig({
  plugins: [svelte({ configFile: false }), svelteTesting()],
  // The context menu is a popover, which jsdom lacks
  test: { ...SVELTE_TESTS, setupFiles: ['src/popover.test-helper.js'] },
});
