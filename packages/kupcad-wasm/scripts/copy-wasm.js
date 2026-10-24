// Copies the module core/build.zig built (`pnpm build:core:wasm`) into dist/, which the package
// ships it from.

import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const from = new URL('../../../core/zig-out/bin/kupcad.wasm', import.meta.url);
const dist = new URL('../dist/', import.meta.url);

if (!existsSync(from)) {
  console.error(`${fileURLToPath(from)} is missing: build it with \`pnpm build:core:wasm\``);
  process.exit(1);
}
mkdirSync(dist, { recursive: true });
copyFileSync(from, new URL('kupcad.wasm', dist));
