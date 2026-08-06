import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, 'src/extension.js'),
      formats: ['cjs'],
      fileName: () => 'extension.cjs',
    },
    outDir: 'dist',
    rollupOptions: {
      external: ['vscode', 'path', 'fs', 'crypto'],
    },
    sourcemap: true,
    minify: false
  }
});
