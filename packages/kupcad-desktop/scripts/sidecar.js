// Copies a kupcad built for this machine (the one given, else the core's as
// `pnpm build:core:native` built it) to where Tauri bundles a sidecar and `tauri dev` runs it:
// src-tauri/binaries/kupcad-<target triple>, the triple Rust builds the app for here
// (`rustc --print host-tuple`).
//
//   node scripts/sidecar.js [path/to/kupcad]

import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const exe = process.platform === 'win32' ? '.exe' : '';
const built =
  process.argv[2] ??
  fileURLToPath(new URL(`../../../core/zig-out/bin/kupcad${exe}`, import.meta.url));
const binaries = fileURLToPath(new URL('../src-tauri/binaries/', import.meta.url));

if (!existsSync(built)) {
  console.error(`No kupcad at ${built}: run \`pnpm build:core:native\` at the root first.`);
  process.exit(1);
}
const triple = execFileSync('rustc', ['--print', 'host-tuple'], { encoding: 'utf8' }).trim();
const sidecar = `${binaries}kupcad-${triple}${exe}`;
mkdirSync(binaries, { recursive: true });
copyFileSync(built, sidecar);
chmodSync(sidecar, 0o755);
console.log(`kupcad → ${sidecar}`);
