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
      /** @type {object[]} what each restart changed */
      this.restarts = [];
      this.viewport = new EventEmitter();
      this.onViewport = this.viewport.event;
      servers.push(this);
    }
    async start() {
      if (binaries.failStart) throw new Error('spawn EACCES');
      this.started = true;
    }
    async stop() {
      this.stopped = true;
      this.started = false;
    }
    /** @param {{ serverPath?: string }} change */
    async restart(change) {
      this.restarts.push(change);
      if (change.serverPath) this.serverPath = change.serverPath;
      this.started = true;
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
  /** Whether the server fails to start, and the look for an update fails. */
  failStart: false,
  updateFails: false,
  prunes: 0,
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
      if (binaries.updateFails) throw new Error('the archive is no zip');
      return binaries.updates.shift() ?? null;
    }
    async prune() {
      binaries.prunes += 1;
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
  binaries.failStart = false;
  binaries.updateFails = false;
  binaries.prunes = 0;
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

  it('runs the kupcad an update installed, the daily look and one asked for, and prunes the old', async () => {
    binaries.updates = ['/storage/bin/0.1.3/kupcad', '/storage/bin/0.1.4/kupcad'];
    await activate(/** @type {any} */ (context));
    await vi.waitFor(() =>
      expect(servers[0].restarts).toEqual([{ serverPath: '/storage/bin/0.1.3/kupcad' }]),
    );
    await commands.executeCommand('kupcad.checkForUpdates');
    expect(servers[0].restarts.at(-1)).toEqual({ serverPath: '/storage/bin/0.1.4/kupcad' });
    expect(binaries.asked).toEqual([false, true]);
    expect(binaries.prunes).toBe(2);
  });

  it('logs an update that failed, and keeps the server running', async () => {
    binaries.updateFails = true;
    await activate(/** @type {any} */ (context));
    await vi.waitFor(() =>
      expect(fake.logs[0].lines).toContain(
        'error: The update of kupcad failed: the archive is no zip',
      ),
    );
    expect(servers[0].started).toBe(true);
  });

  it("says a server that didn't start isn't running, and starts it again on a check asked for", async () => {
    binaries.failStart = true;
    await activate(/** @type {any} */ (context));
    expect(fake.messages[0].text).toMatch(/didn't start: spawn EACCES/);
    await commands.executeCommand(OPEN_VIEWER_COMMAND);
    expect(fake.panels).toHaveLength(0);
    expect(fake.messages[1].text).toMatch(/isn't running/);

    binaries.failStart = false;
    await commands.executeCommand('kupcad.checkForUpdates');
    expect(servers[0].restarts).toEqual([
      { serverPath: '/usr/local/bin/kupcad', viewportPort: 9001 },
    ]);
    expect(binaries.asked).toEqual([]);
    await commands.executeCommand(OPEN_VIEWER_COMMAND);
    expect(fake.panels).toHaveLength(1);
  });

  it('starts the server again when its path or port is set, and not for another setting', async () => {
    await activate(/** @type {any} */ (context));
    fake.changeSettings('kupcad.print.slicer');
    fake.settings['kupcad.viewport.port'] = 9200;
    fake.changeSettings('kupcad.viewport.port');
    await vi.waitFor(() =>
      expect(servers[0].restarts).toEqual([
        { serverPath: '/usr/local/bin/kupcad', viewportPort: 9200 },
      ]),
    );
  });
});
