import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true, // Allows using 'describe', 'it', 'expect' without explicit imports
    environment: 'node', // Use 'jsdom' if testing webview components
    // extension.test.js imports `vscode` and runs inside VS Code via @vscode/test-cli (.vscode-test.mjs).
    exclude: ['**/node_modules/**', '**/dist/**', 'test/extension.test.js'],
    mockReset: true,
  },
});
