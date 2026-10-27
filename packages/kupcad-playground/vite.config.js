import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vitest/config';
import { SVELTE_TESTS } from '../../vitest.svelte.js';

export default defineConfig({
  plugins: [svelte({ configFile: false }), svelteTesting()],
  // The playground's tests mount the viewer
  test: { ...SVELTE_TESTS, setupFiles: ['@kupcad/ui/testing'] },
});
