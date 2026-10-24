import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
// The module Vitest gives the code as `vscode`
import { commands, EventEmitter, fake, memento, resetFake, Uri } from './testing/vscode.js';
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
      this.serverPath = /** @type {{ serverPath: string }} */ (options).serverPath;
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
    /** @param {string} next */
    async restart(next) {
      this.restartedOn = next;
    }
    async preview() {}
    async setParams() {}
  },
}));

/** What the binary manager finds, and the updates it installs, as the test sets them. */
const binaries = vi.hoisted(() => ({
  /** @type {{ path: string, version: string, source: string } | null} */
  found: null,
  /** @type {(string | null)[]} what each look for an update installs */
  updates: /** @type {(string | null)[]} */ ([]),
  /** @type {boolean[]} */
  asked: /** @type {boolean[]} */ ([]),
}));
vi.mock('./binary/manager.js', () => ({
  CHECK_FOR_UPDATES_COMMAND: 'kupcad.checkForUpdates',
  BinaryManager: class {
    /** @param {object} options */
    constructor(options) {
      this.options = options;
    }
    async server() {
      return binaries.found;
    }
    /** @param {{ asked: boolean }} how */
    async checkForUpdates({ asked }) {
      binaries.asked.push(asked);
      return binaries.updates.shift() ?? null;
    }
  },
}));

/** An extension installed in a folder of its own, its page built. */
function extension() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-extension-'));
  fs.mkdirSync(path.join(dir, PAGE_DIR));
  fs.writeFileSync(path.join(dir, PAGE_DIR, 'index.html'), '<head></head><body></body>');
  return {
    extensionPath: dir,
    extensionUri: Uri.file(dir),
    globalStorageUri: Uri.file(path.join(dir, 'storage')),
    globalState: memento(),
    extension: { packageJSON: { kupcad: { core: '>=0.1.0 <0.2.0' } } },
    subscriptions: /** @type {{ dispose(): void }[]} */ ([]),
  };
}

/** @type {ReturnType<typeof extension>} */
let context;

beforeEach(() => {
  resetFake();
  servers.length = 0;
  binaries.found = { path: '/usr/local/bin/kupcad', version: '0.1.0', source: 'path' };
  binaries.updates = [];
  binaries.asked = [];
  context = extension();
});
afterEach(async () => {
  await deactivate();
  fs.rmSync(context.extensionPath, { recursive: true, force: true });
});

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

  it('starts no server when the manager has none, and says so when the viewer is asked for', async () => {
    binaries.found = null;
    await activate(/** @type {any} */ (context));
    await commands.executeCommand(OPEN_VIEWER_COMMAND);
    expect(servers).toHaveLength(0);
    expect(fake.panels).toHaveLength(0);
    expect(fake.messages[0].text).toMatch(/language server isn't running/);
  });

  it('runs the kupcad an update installed: the daily look, and one asked for', async () => {
    binaries.updates = ['/storage/bin/0.1.3/kupcad', '/storage/bin/0.1.4/kupcad'];
    await activate(/** @type {any} */ (context));
    await vi.waitFor(() => expect(servers[0].restartedOn).toBe('/storage/bin/0.1.3/kupcad'));
    await commands.executeCommand('kupcad.checkForUpdates');
    expect(servers[0].restartedOn).toBe('/storage/bin/0.1.4/kupcad');
    expect(binaries.asked).toEqual([false, true]);
  });
});
