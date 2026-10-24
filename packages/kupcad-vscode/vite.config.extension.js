// The extension's host side, for VS Code's extension host: one CommonJS file with its
// dependencies (the language client) in it, VS Code's API and Node's modules left to the host.

import { builtinModules } from 'node:module';
import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    lib: {
      entry: 'src/extension/main.js',
      formats: ['cjs'],
      fileName: () => 'extension.cjs',
    },
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: true,
    minify: false,
    rollupOptions: {
      external: ['vscode', ...builtinModules, ...builtinModules.map((name) => `node:${name}`)],
    },
  },
  // The language client's Node entry
  resolve: { conditions: ['node'] },
});
