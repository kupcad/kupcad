import { beforeEach, describe, expect, it, vi } from 'vitest';
// The module Vitest gives the code as `vscode`
import {
  commands,
  documentAt,
  EventEmitter,
  fake,
  resetFake,
  Uri,
  window,
} from './testing/vscode.js';
import { readPresets, writePresets } from './presets.js';
import { ScriptValues } from './values.js';
import { ViewerPanel } from './viewer-panel.js';

/** @import { ParamValues } from '@kupcad/protocol/types' */

/** The page as the build writes it. */
const PAGE =
  '<!doctype html><html><head></head><body><script type="module" src="./main.js"></script></body></html>';
const PART = documentAt('/work/part.kup');
const PART_URI = 'file:///work/part.kup';
const PRESETS = '/work/part.presets.json';

/**
 * Puts presets in the presets file of part.kup.
 * @param {import('./presets.js').Presets} presets
 */
const presetsOnDisk = (presets) =>
  fake.files.set(PRESETS, new TextEncoder().encode(writePresets(presets)));
/** The presets in part.kup's file. */
const presetsOf = () => readPresets(new TextDecoder().decode(fake.files.get(PRESETS)));
/** What the panel posted the page of the type given. @param {{ posted: unknown[] }} webview @param {string} type */
const postedOf = (webview, type) =>
  webview.posted.filter((m) => /** @type {{ type: string }} */ (m).type === type);

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
  const values = new ScriptValues();
  const panel = ViewerPanel.open({
    server,
    values,
    // The stand-ins are what the panel uses of VS Code's types
    extensionUri: /** @type {any} */ (Uri.file('/ext')),
    page: () => PAGE,
    log: /** @type {any} */ (log),
  });
  const shown = /** @type {(typeof fake.panels)[number]} */ (fake.panels.at(-1));
  return { panel, server, values, shown, webview: shown.webview, log };
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
      /<script nonce="[^"]+" type="module" src="https:\/\/webview\/ext\/dist-webview\/main.js">/,
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

  it("gives the server the panel's values, keeps them for it, and follows a restarted server's socket", () => {
    fake.activeDocument = PART;
    const { webview, server, values } = open();
    webview.receive({ type: 'setParams', uri: PART_URI, values: { w: 3 } });
    expect(server.asked.filter(([what]) => what === 'setParams')).toEqual([
      ['setParams', PART_URI, { w: 3 }],
    ]);
    // The server is given them again when it restarts (LanguageServer), from this store
    expect(values.of(PART_URI)).toEqual({ w: 3 });
    server.restart(9100);
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
    expect(fake.files.size).toBe(0);
    fake.saveAnswer = Uri.file('/work/part.png');
    webview.receive({ type: 'screenshot', png: btoa('PNG') });
    await vi.waitFor(() => expect(fake.files.has('/work/part.png')).toBe(true));
    expect(new TextDecoder().decode(fake.files.get('/work/part.png'))).toBe('PNG');
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

describe('ViewerPanel presets', () => {
  it("tells the page the shown script's presets, again when their file changes", async () => {
    presetsOnDisk({ Small: { w: 1 } });
    fake.activeDocument = PART;
    const { webview } = open();
    await vi.waitFor(() =>
      expect(postedOf(webview, 'presets')).toEqual([
        { type: 'presets', uri: PART_URI, names: ['Small'] },
      ]),
    );
    presetsOnDisk({ Small: { w: 1 }, Large: { w: 9 } });
    fake.fileChanged(PRESETS);
    fake.fileChanged('/work/lid.presets.json');
    await vi.waitFor(() => expect(postedOf(webview, 'presets')).toHaveLength(2));
    expect(postedOf(webview, 'presets')[1]).toEqual({
      type: 'presets',
      uri: PART_URI,
      names: ['Small', 'Large'],
    });
  });

  it("applies a preset: the server runs with its values, and the page's panel shows them", async () => {
    presetsOnDisk({ Small: { w: 1, label: 'S' } });
    fake.activeDocument = PART;
    const { webview, server } = open();
    webview.receive({ type: 'applyPreset', uri: PART_URI, name: 'Small' });
    await vi.waitFor(() =>
      expect(server.asked).toContainEqual(['setParams', PART_URI, { w: 1, label: 'S' }]),
    );
    expect(postedOf(webview, 'overrides')).toEqual([
      { type: 'overrides', uri: PART_URI, values: { w: 1, label: 'S' } },
    ]);
  });

  it("saves the panel's values as a preset under the name given, asking before replacing one", async () => {
    presetsOnDisk({ Small: { w: 1 } });
    fake.activeDocument = PART;
    const { webview } = open();
    fake.inputAnswer = ' Large ';
    webview.receive({ type: 'savePreset', uri: PART_URI, values: { w: 9 } });
    await vi.waitFor(() => expect(presetsOf()).toEqual({ Small: { w: 1 }, Large: { w: 9 } }));

    // A name taken: left as it was unless the user says replace
    fake.inputAnswer = 'Small';
    webview.receive({ type: 'savePreset', uri: PART_URI, values: { w: 2 } });
    await vi.waitFor(() => expect(fake.messages).toHaveLength(1));
    expect(fake.messages[0]).toMatchObject({ level: 'warning', buttons: ['Replace'], modal: true });
    expect(presetsOf().Small).toEqual({ w: 1 });
    fake.answer = 'Replace';
    webview.receive({ type: 'savePreset', uri: PART_URI, values: { w: 2 } });
    await vi.waitFor(() => expect(presetsOf().Small).toEqual({ w: 2 }));
    expect(fake.inputs).toHaveLength(3);

    // Cancelled, nothing is written
    fake.inputAnswer = undefined;
    webview.receive({ type: 'savePreset', uri: PART_URI, values: { w: 3 } });
    await new Promise((resolve) => setTimeout(resolve));
    expect(presetsOf()).toEqual({ Small: { w: 2 }, Large: { w: 9 } });
  });

  it("lists none of a presets file it can't read, says why, and saves nothing over it", async () => {
    fake.files.set(PRESETS, new TextEncoder().encode('{'));
    fake.activeDocument = PART;
    const { webview, log } = open();
    await vi.waitFor(() =>
      expect(postedOf(webview, 'presets')).toEqual([{ type: 'presets', uri: PART_URI, names: [] }]),
    );
    expect(log.lines[0]).toMatch(/part\.presets\.json can't be read: it is no JSON/);
    fake.inputAnswer = 'Small';
    webview.receive({ type: 'savePreset', uri: PART_URI, values: { w: 1 } });
    await vi.waitFor(() => expect(fake.messages[0]?.text).toMatch(/so the preset wasn't saved/));
    expect(new TextDecoder().decode(fake.files.get(PRESETS))).toBe('{');
    expect(fake.inputs).toHaveLength(0);
  });
});

describe('ViewerPanel export and print', () => {
  it('runs the export and print commands on the script the page asks for', async () => {
    /** @type {unknown[][]} */
    const ran = [];
    commands.registerCommand('kupcad.export', (/** @type {unknown} */ uri) =>
      ran.push(['export', uri]),
    );
    commands.registerCommand('kupcad.print', (/** @type {unknown} */ uri) =>
      ran.push(['print', uri]),
    );
    fake.activeDocument = PART;
    const { webview } = open();
    webview.receive({ type: 'export', uri: PART_URI });
    webview.receive({ type: 'print', uri: PART_URI });
    await vi.waitFor(() =>
      expect(ran).toEqual([
        ['export', PART_URI],
        ['print', PART_URI],
      ]),
    );
  });
});
