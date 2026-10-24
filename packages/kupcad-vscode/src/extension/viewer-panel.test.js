import { beforeEach, describe, expect, it, vi } from 'vitest';
// The module Vitest gives the code as `vscode`
import { documentAt, EventEmitter, fake, resetFake, Uri, window } from './testing/vscode.js';
import { ViewerPanel } from './viewer-panel.js';

/** @import { ParamValues } from '@kupcad/protocol/types' */

/** The page as the build writes it. */
const PAGE =
  '<!doctype html><html><head></head><body><script type="module" src="./main.js"></script></body></html>';
const PART = documentAt('/work/part.kup');
const PART_URI = 'file:///work/part.kup';

/**
 * A stand-in for the language server: its socket's port, and what it was asked.
 * @param {number} port
 */
function serverAt(port) {
  const viewport = new EventEmitter();
  return {
    /** @type {unknown[][]} */
    asked: [],
    /** @type {number | null} */
    viewportPort: port,
    onViewport: viewport.event,
    /** @param {number} next the port of the server started again */
    restart(next) {
      this.viewportPort = next;
      viewport.fire(next);
    },
    /** @param {string} uri */
    async preview(uri) {
      this.asked.push(['preview', uri]);
    },
    /**
     * @param {string} uri
     * @param {ParamValues} values
     */
    async setParams(uri, values) {
      this.asked.push(['setParams', uri, values]);
    },
  };
}

/** A panel over `server`, and what it drew and logged. */
function open(server = serverAt(9001)) {
  const log = window.createOutputChannel();
  const panel = ViewerPanel.open({
    server,
    // The stand-ins are what the panel uses of VS Code's types
    extensionUri: /** @type {any} */ (Uri.file('/ext')),
    page: () => PAGE,
    log: /** @type {any} */ (log),
  });
  const shown = /** @type {(typeof fake.panels)[number]} */ (fake.panels.at(-1));
  return { panel, server, shown, webview: shown.webview, log };
}

beforeEach(() => resetFake());

describe('ViewerPanel', () => {
  it('opens on the script the editor shows, and asks the server for its frame', () => {
    fake.activeDocument = PART;
    const { webview, server, shown } = open();
    expect(webview.posted).toEqual([
      { type: 'document', document: { uri: PART_URI, name: 'part.kup' } },
    ]);
    expect(server.asked).toEqual([['preview', PART_URI]]);
    expect(shown.title).toBe('KupCAD Viewer: part.kup');
    expect(shown.options).toMatchObject({ enableScripts: true });
  });

  it('serves the built page under a CSP that reaches the viewport socket alone', () => {
    const { webview } = open();
    expect(webview.html).toContain('connect-src ws://127.0.0.1:9001');
    expect(webview.html).toContain('<meta name="kupcad-viewport" content="ws://127.0.0.1:9001">');
    expect(webview.html).toMatch(
      /<script nonce="[^"]+" type="module" src="https:\/\/\/webview\/ext\/dist-webview\/main.js">/,
    );
  });

  it('follows the editor to another script, and stays on it for another kind of file', () => {
    fake.activeDocument = PART;
    const { webview, server } = open();
    fake.showEditor(documentAt('/work/lid.kup'));
    fake.showEditor(documentAt('/work/notes.md', 'markdown'));
    fake.showEditor(documentAt('/work/lid.kup'));
    expect(webview.posted.at(-1)).toEqual({
      type: 'document',
      document: { uri: 'file:///work/lid.kup', name: 'lid.kup' },
    });
    expect(server.asked).toEqual([
      ['preview', PART_URI],
      ['preview', 'file:///work/lid.kup'],
    ]);
  });

  it('tells a page that loaded again what it shows, and asks for its frame again', () => {
    fake.activeDocument = PART;
    const { webview, server } = open();
    webview.receive({ type: 'ready' });
    expect(webview.posted).toHaveLength(2);
    expect(server.asked).toEqual([
      ['preview', PART_URI],
      ['preview', PART_URI],
    ]);
  });

  it("gives the server the panel's values, and a restarted server them again, the page its socket", () => {
    fake.activeDocument = PART;
    const { webview, server } = open();
    webview.receive({ type: 'setParams', uri: PART_URI, values: { w: 3 } });
    server.restart(9100);
    expect(server.asked.filter(([what]) => what === 'setParams')).toEqual([
      ['setParams', PART_URI, { w: 3 }],
      ['setParams', PART_URI, { w: 3 }],
    ]);
    expect(webview.html).toContain('ws://127.0.0.1:9100');
    // Shown again, the page is told the values it gave
    fake.showEditor(documentAt('/work/lid.kup'));
    fake.showEditor(PART);
    expect(webview.posted.at(-1)).toEqual({ type: 'overrides', uri: PART_URI, values: { w: 3 } });
  });

  it('drops a message of no known shape, and logs why a request to the server failed', async () => {
    fake.activeDocument = PART;
    const server = serverAt(9001);
    server.preview = async () => {
      throw new Error('the server stopped');
    };
    const { webview, log } = open(server);
    webview.receive({ type: 'setParams', uri: PART_URI, values: { w: [3] } });
    expect(server.asked).toEqual([]);
    expect(log.lines[0]).toMatch(/^warn: The viewer sent a message of no known shape/);
    await vi.waitFor(() => expect(log.lines).toContain('error: show: the server stopped'));
  });

  it('saves a screenshot where the user says, and nothing when the dialog is cancelled', async () => {
    fake.activeDocument = PART;
    const { webview } = open();
    webview.receive({ type: 'screenshot', png: btoa('PNG') });
    await new Promise((resolve) => setTimeout(resolve));
    expect(fake.written.size).toBe(0);
    fake.saveAnswer = Uri.file('/work/part.png');
    webview.receive({ type: 'screenshot', png: btoa('PNG') });
    await vi.waitFor(() => expect(fake.written.has('/work/part.png')).toBe(true));
    expect(new TextDecoder().decode(fake.written.get('/work/part.png'))).toBe('PNG');
  });

  it('stops following the editor once closed', () => {
    fake.activeDocument = PART;
    const { panel, server, webview } = open();
    panel.dispose();
    expect(panel.closed).toBe(true);
    fake.showEditor(documentAt('/work/lid.kup'));
    server.restart(9100);
    expect(server.asked).toEqual([['preview', PART_URI]]);
    expect(webview.html).not.toContain('9100');
  });
});
