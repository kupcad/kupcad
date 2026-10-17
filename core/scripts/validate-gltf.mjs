// Builds models that reach every branch of the glTF exporter (materials of each kind,
// ghosts, several parts, Draco, both containers) with the kupcad binary and checks each
// file with the Khronos glTF Validator. Any error or warning fails. Run `pnpm check:gltf`
// from the repository root after `zig build`.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateBytes } from 'gltf-validator';

const KUPCAD = join(dirname(fileURLToPath(import.meta.url)), '..', 'zig-out', 'bin', 'kupcad');

const MODELS = {
  plain: 'cube(10)',
  materials: `[
  cube(2),
  cube(2).translate(x: 5).material(color: "#FF0000", metallic: 0.5, roughness: 0.2),
  sphere(1).translate(x: 10).material(color: "#00FF00", alpha: 0.5),
  cylinder(r: 1, h: 2).translate(x: 15).material(color: "#FFFFFF", transmission: 0.8),
  (cube(2).material(color: "#0000FF") + cube(2).translate(x: 1)).translate(y: 10),
]`,
  ghost: 'cube(4).translate(y: 10).ghost\ncube(2)',
};

const VARIANTS = [
  { ext: 'glb', args: [] },
  { ext: 'gltf', args: [] },
  { ext: 'glb', args: ['--draco'] },
  { ext: 'gltf', args: ['--draco'] },
];

const dir = mkdtempSync(join(tmpdir(), 'kupcad-gltf-'));
let failed = false;
try {
  for (const [name, source] of Object.entries(MODELS)) {
    const script = join(dir, `${name}.kup`);
    writeFileSync(script, source);
    for (const { ext, args } of VARIANTS) {
      const out = join(dir, `${name}${args.length ? '-draco' : ''}.${ext}`);
      try {
        execFileSync(KUPCAD, ['build', script, '-o', out, ...args], { stdio: 'pipe' });
      } catch (err) {
        process.stderr.write(err.stderr ?? '');
        throw err;
      }
      const report = await validateBytes(new Uint8Array(readFileSync(out)), { uri: out });
      const { numErrors, numWarnings, messages } = report.issues;
      const label = `${name} (${ext}${args.length ? ', draco' : ''})`;
      if (numErrors + numWarnings > 0) {
        failed = true;
        console.error(`${label}: ${numErrors} errors, ${numWarnings} warnings`);
        for (const m of messages.filter((m) => m.severity <= 1)) console.error(`  ${m.code} at ${m.pointer ?? '-'}: ${m.message}`);
      } else {
        console.log(`${label}: valid`);
      }
    }
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
