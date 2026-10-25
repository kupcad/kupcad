// @vitest-environment node
// The app's language server on the real kupcad (core/zig-out/bin/kupcad, which `zig build`
// makes), started by Node as the native side starts it: the client initializes over the framed
// stdio, a script opened gets the server's diagnostics, and the viewport socket, reached as the
// server says, sends the script's model once the app asks to show it.

import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFrame } from '@kupcad/protocol';
import { afterEach, expect, it } from 'vitest';
import { fileUri } from './folder.js';
import { LanguageServer } from './server.js';

/** @import { Preview } from '@kupcad/protocol/types' */
/** @import { Spawn } from './server.js' */

const KUPCAD = fileURLToPath(
  new URL(
    `../../../core/zig-out/bin/kupcad${process.platform === 'win32' ? '.exe' : ''}`,
    import.meta.url,
  ),
);
/** The page's origin the app names: a browser's would have to be it, Node sends none. */
const ORIGIN = 'http://127.0.0.1:1420';
const SCRIPT = 'unused = 1\ncube(10)\n';
/** A first run builds the kernel's caches; a slow machine takes its time. */
const PATIENCE_MS = 60_000;

/** @type {Spawn} */
const nodeProcess = async (origin, on) => {
  const args = ['lsp', '--stdio', '--viewport-origin', origin];
  const child = spawn(KUPCAD, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  child.stdout.on('data', (chunk) => on.stdout(new Uint8Array(chunk)));
  child.stderr.on('data', (chunk) => on.stderr(String(chunk)));
  child.on('exit', (code) => on.exit(code));
  await once(child, 'spawn');
  return {
    write: async (bytes) => void child.stdin.write(bytes),
    kill: async () => void child.kill(),
  };
};

/** @type {(() => Promise<void>)[]} */
const cleanups = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0)) await cleanup();
});

it(
  'speaks with the real kupcad lsp: diagnostics, and the model of the script shown',
  async () => {
    expect(existsSync(KUPCAD), `no kupcad at ${KUPCAD}: build it with \`zig build\``).toBe(true);
    // A folder on disk, as the app opens one, by its real path (the server confines by it)
    const folder = realpathSync(mkdtempSync(join(tmpdir(), 'kupcad-app-')));
    cleanups.push(async () => rmSync(folder, { recursive: true, force: true }));
    writeFileSync(join(folder, 'part.kup'), SCRIPT);
    const uri = fileUri(join(folder, 'part.kup'));
    /** @type {((url: string | null) => void) | null} */
    let viewportAt = null;
    const viewport = new Promise((resolve) => (viewportAt = resolve));
    /** @type {((diagnostics: any[]) => void) | null} */
    let diagnosed = null;
    const diagnostics = new Promise((resolve) => (diagnosed = resolve));
    const server = new LanguageServer({
      rootUri: fileUri(folder),
      origin: ORIGIN,
      spawn: nodeProcess,
      on: { viewport: (url) => viewportAt?.(url), state: () => {}, log: () => {} },
      notifications: {
        'textDocument/publishDiagnostics': (_client, params) => {
          if (params.uri === uri && params.diagnostics.length > 0) diagnosed?.(params.diagnostics);
          return true;
        },
      },
    });
    cleanups.push(() => server.stop());
    await server.start();
    expect(server.client.serverCapabilities?.hoverProvider).toBe(true);

    server.client.notification('textDocument/didOpen', {
      textDocument: { uri, languageId: 'kupcad', version: 1, text: SCRIPT },
    });
    const [found] = await diagnostics;
    expect(found.code).toBe('unused-variable');

    const url = await viewport;
    expect(url).toMatch(/^ws:\/\/127\.0\.0\.1:\d+$/);
    const socket = new WebSocket(/** @type {string} */ (url));
    socket.binaryType = 'arraybuffer';
    cleanups.push(async () => socket.close());
    await once(socket, 'open');
    /** @type {Promise<Preview>} */
    const frame = new Promise((resolve) =>
      socket.addEventListener('message', ({ data }) => resolve(readFrame(data))),
    );
    await server.preview(uri);
    const { header, model } = await frame;
    expect(header.document).toBe(uri);
    expect(header.error).toBeNull();
    expect(model.kind).toBe('3d');
  },
  PATIENCE_MS,
);
