import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
// The module Vitest gives the code as `vscode`
import { commands, EventEmitter, fake, resetFake, Uri } from './testing/vscode.js';
import { activate, deactivate, OPEN_VIEWER_COMMAND } from './main.js';
import { PAGE_DIR } from './viewer-panel.js';

/** The language servers activation made, and what was asked of them. */
const servers = vi.hoisted(() => /** @type {any[]} */ ([]));
vi.mock('./server.js', () => ({
  LanguageServer: class {
    /** @param {object} options */
    constructor(options) {
      this.options = options;
      this.viewportPort = 9001;
      this.started = false;
      this.stopped = false;
      this.viewport = new EventEmitter();
      this.onViewport = this.viewport.event;
      servers.push(this);
    }
    async start() {
      this.started = true;
    }
    async stop() {
      this.stopped = true;
    }
    async preview() {}
    async setParams() {}
  },
}));

/** Where `kupcad` is found: a file the test makes, or nowhere. @type {string | undefined} */
let serverPath;
vi.mock('./binary/resolve.js', () => ({ resolveServerPath: () => serverPath }));

/** An extension installed in a folder of its own, its page built. */
function extension() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-extension-'));
  fs.mkdirSync(path.join(dir, PAGE_DIR));
  fs.writeFileSync(path.join(dir, PAGE_DIR, 'index.html'), '<head></head><body></body>');
  return {
    extensionPath: dir,
    extensionUri: Uri.file(dir),
    subscriptions: /** @type {{ dispose(): void }[]} */ ([]),
  };
}

/** @type {ReturnType<typeof extension>} */
let context;

beforeEach(() => {
  resetFake();
  servers.length = 0;
  serverPath = '/usr/local/bin/kupcad';
  context = extension();
});
afterEach(() => fs.rmSync(context.extensionPath, { recursive: true, force: true }));

describe('activate', () => {
  it('starts the language server found, on the viewport port the settings give', async () => {
    fake.settings['kupcad.viewport.port'] = 9100;
    await activate(/** @type {any} */ (context));
    expect(servers).toHaveLength(1);
    expect(servers[0].options).toMatchObject({
      serverPath: '/usr/local/bin/kupcad',
      viewportPort: 9100,
    });
    expect(servers[0].started).toBe(true);
    await deactivate();
    expect(servers[0].stopped).toBe(true);
  });

  it('opens one viewer, revealed when asked again, and a new one once it was closed', async () => {
    await activate(/** @type {any} */ (context));
    await commands.executeCommand(OPEN_VIEWER_COMMAND);
    await commands.executeCommand(OPEN_VIEWER_COMMAND);
    expect(fake.panels).toHaveLength(1);
    expect(fake.panels[0].revealed).toBe(1);
    expect(fake.panels[0].webview.html).toContain('<meta http-equiv="Content-Security-Policy"');
    fake.panels[0].dispose();
    await commands.executeCommand(OPEN_VIEWER_COMMAND);
    expect(fake.panels).toHaveLength(2);
  });

  it('says where to put kupcad when none is found, and when the viewer is asked for', async () => {
    serverPath = undefined;
    await activate(/** @type {any} */ (context));
    await commands.executeCommand(OPEN_VIEWER_COMMAND);
    expect(servers).toHaveLength(0);
    expect(fake.panels).toHaveLength(0);
    expect(fake.messages.map((m) => m.level)).toEqual(['error', 'error']);
    expect(fake.messages[0].text).toMatch(/kupcad\.serverPath/);
  });
});
