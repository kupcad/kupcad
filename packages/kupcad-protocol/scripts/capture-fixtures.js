// Writes src/fixtures/*.json: the headers of the frames the core's preview worker gives for a
// few scripts, their timings made fixed so the files change only when the protocol does.
//
//   node scripts/capture-fixtures.js [path/to/kupcad]   (default: the core's dev build)

import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/** The worker's message kinds (core/src/cli/lsp_worker.zig's `Kind`) that this sends. */
const KIND = { update: 1, evaluate: 3, setParams: 9 };
const FIXED_TIMING = { runMs: 1.25, renderMs: 0.5 };

/** @type {Record<string, { source: string, params?: object }>} */
const SCRIPTS = {
  solid: {
    source: `# @title Bracket
w = param(:width, default: 20, validate: { min: 10 }, unit: "mm", group: "Size", title: "Width")
bolt = cylinder(r: 2, h: 5).named("bolt").material(color: "#cc3333")
[cube(w).named("plate"), bolt.translate(x: 30), bolt.translate(x: 40)]
`,
    params: { width: 25 },
  },
  sketch: { source: 'square(10).named("plate")\n' },
  refused: {
    source: 'w = param(:width, default: 20, validate: { min: 10 })\ncube(w)\n',
    params: { width: 5 },
  },
};

const kupcad =
  process.argv[2] ?? fileURLToPath(new URL('../../../core/zig-out/bin/kupcad', import.meta.url));
const worker = spawn(kupcad, ['lsp', '--preview-worker'], { stdio: ['pipe', 'pipe', 'inherit'] });

/** @type {Buffer} */
let pending = Buffer.alloc(0);
/** @type {((payload: Buffer) => void)[]} */
const waiting = [];
worker.stdout.on('data', (/** @type {Buffer} */ chunk) => {
  pending = Buffer.concat([pending, chunk]);
  while (pending.length >= 5 && pending.length >= 5 + pending.readUInt32LE(1)) {
    const length = pending.readUInt32LE(1);
    waiting.shift()?.(pending.subarray(5, 5 + length));
    pending = pending.subarray(5 + length);
  }
});

/**
 * Sends the worker a message and gives its reply's payload.
 * @param {number} kind
 * @param {(string | Buffer)[]} parts
 * @returns {Promise<Buffer>}
 */
function request(kind, parts) {
  const payload = Buffer.concat(parts.map((p) => (typeof p === 'string' ? Buffer.from(p) : p)));
  const head = Buffer.alloc(5);
  head.writeUInt8(kind, 0);
  head.writeUInt32LE(payload.length, 1);
  worker.stdin.write(Buffer.concat([head, payload]));
  return new Promise((resolve) => waiting.push(resolve));
}

/** @param {string} path */
const prefixed = (path) => {
  const length = Buffer.alloc(4);
  length.writeUInt32LE(Buffer.byteLength(path));
  return [length, path];
};

for (const [name, { source, params }] of Object.entries(SCRIPTS)) {
  const path = `${name}.kup`;
  await request(KIND.update, [...prefixed(path), source]);
  if (params) await request(KIND.setParams, [...prefixed(path), JSON.stringify(params)]);
  const reply = await request(KIND.evaluate, [
    Buffer.from([1]),
    ...prefixed(path),
    `file:///work/${path}`,
  ]);
  const frame = reply.subarray(1);
  const header = JSON.parse(frame.subarray(4, 4 + frame.readUInt32LE(0)).toString('utf8'));
  header.timing = FIXED_TIMING;
  writeFileSync(
    new URL(`../src/fixtures/${name}.json`, import.meta.url),
    `${JSON.stringify(header, null, 2)}\n`,
  );
}
worker.stdin.end();
