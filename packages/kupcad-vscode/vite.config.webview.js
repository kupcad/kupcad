// The viewer's page, for the extension's webview: built into dist-webview/, its assets'
// URLs relative, which the extension turns into the webview's.

import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [svelte()],
  root: 'src/webview',
  base: './',
  build: {
    outDir: '../../dist-webview',
    emptyOutDir: true,
  },
});
