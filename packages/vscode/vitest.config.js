import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true, // Allows using 'describe', 'it', 'expect' without explicit imports
    environment: 'node', // Use 'jsdom' if testing webview components
    exclude: ['**/node_modules/**', '**/dist/**'],
    mockReset: true,
  },
});
