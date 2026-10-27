// The app's page, served to Tauri's webview: under `tauri dev` by Vite at a fixed port (Tauri
// loads its devUrl), and built into dist/ for `tauri build`. Its tests run under jsdom.

import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vitest/config';
import { SVELTE_TESTS } from '../../vitest.svelte.js';

/** Where `tauri dev` finds the page (src-tauri/tauri.conf.json's devUrl). */
export const DEV_PORT = 1420;

export default defineConfig({
  plugins: [svelte({ configFile: false }), svelteTesting()],
  // Rust's errors stay on the screen, and the Rust side's files aren't the page's
  clearScreen: false,
  server: {
    host: '127.0.0.1',
    port: DEV_PORT,
    strictPort: true,
    watch: { ignored: ['**/src-tauri/**'] },
  },
  // The webviews Tauri 2 runs on: WebKit (macOS, Linux) and WebView2
  build: { target: ['safari16', 'chrome110'] },
  test: { ...SVELTE_TESTS, setupFiles: ['@kupcad/ui/testing'] },
});
