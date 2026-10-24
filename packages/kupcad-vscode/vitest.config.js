// The tests: the host side's in Node, VS Code's API a stand-in (src/extension/testing/vscode.js);
// the page's under jsdom, on the models the real core makes.

import { fileURLToPath } from 'node:url';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vitest/config';
import { SVELTE_TESTS } from '../../vitest.svelte.js';

const VSCODE = fileURLToPath(new URL('./src/extension/testing/vscode.js', import.meta.url));

export default defineConfig({
  test: {
    projects: [
      {
        resolve: { alias: { vscode: VSCODE } },
        test: { name: 'host', environment: 'node', include: ['src/extension/**/*.test.js'] },
      },
      {
        plugins: [svelte(), svelteTesting()],
        test: {
          ...SVELTE_TESTS,
          name: 'webview',
          include: ['src/webview/**/*.test.js'],
          setupFiles: ['@kupcad/viewer/testing'],
        },
      },
    ],
  },
});
