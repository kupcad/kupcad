import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
// The module Vitest gives the code as `vscode`
import {
  commands,
  documentAt,
  EventEmitter,
  fake,
  resetFake,
  Uri,
  window,
  workspace,
} from './testing/vscode.js';
import { readPresets, writePresets } from '@kupcad/protocol';
import { ScriptValues } from '@kupcad/protocol';
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
 * @param {import('@kupcad/protocol/types').Presets} presets
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
afterEach(() => vi.restoreAllMocks());

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

  it('follows the editor to another script, and stays on it for anything the server runs not', () => {
    fake.activeDocument = PART;
    const { webview, server } = open();
    fake.showEditor(documentAt('/work/lid.kup'));
    fake.showEditor(documentAt('/work/notes.md', 'markdown'));
    fake.showEditor(documentAt('/Untitled-1', 'kupcad', 'untitled'));
    fake.showEditor(documentAt('/work/part.kup', 'kupcad', 'git'));
    // The panel itself focused: no editor is
    fake.showEditor(undefined);
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
    webview.receive({ type: 'setParams', uri: PART_URI, values: { w: [null] } });
    expect(server.asked).toEqual([]);
    expect(log.lines[0]).toMatch(/^warn: The viewer sent a message of no known shape/);
    await vi.waitFor(() => expect(log.lines).toContain('error: show: the server stopped'));
  });

  it('acts on the document it shows alone: a message naming another is refused, and logged', async () => {
    /** @type {unknown[]} */
    const exported = [];
    commands.registerCommand('kupcad.export', (/** @type {unknown} */ uri) => exported.push(uri));
    fake.activeDocument = PART;
    documentAt('/work/other.kup').text = 'x = 1';
    const { webview, server, log } = open();
    const other = 'file:///work/other.kup';
    webview.receive({ type: 'setParams', uri: other, values: { w: 3 } });
    webview.receive({ type: 'applyPreset', uri: other, name: 'Small' });
    webview.receive({ type: 'savePreset', uri: other, values: { w: 3 } });
    webview.receive({ type: 'export', uri: other });
    webview.receive({ type: 'reveal', uri: other, line: 1, column: 1 });
    await new Promise((resolve) => setTimeout(resolve));
    expect(server.asked).toEqual([['preview', PART_URI]]);
    expect(fake.inputs).toEqual([]);
    expect(exported).toEqual([]);
    expect(fake.shownDocuments).toEqual([]);
    expect(log.lines.filter((line) => line.includes("which it isn't shown: refused"))).toHaveLength(
      5,
    );
    // The shown document's own reach their handlers
    webview.receive({ type: 'reveal', uri: PART_URI, line: 1, column: 1 });
    await vi.waitFor(() => expect(fake.shownDocuments).toHaveLength(1));
  });

  it("says why a screenshot wasn't saved", async () => {
    fake.activeDocument = PART;
    const { webview } = open();
    vi.spyOn(workspace.fs, 'writeFile').mockRejectedValueOnce(
      new Error('EACCES: permission denied'),
    );
    fake.saveAnswer = Uri.file('/work/part.png');
    webview.receive({ type: 'screenshot', png: btoa('PNG') });
    await vi.waitFor(() =>
      expect(fake.messages).toContainEqual(
        expect.objectContaining({
          level: 'error',
          text: "The screenshot wasn't saved in part.png: EACCES: permission denied",
        }),
      ),
    );
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

  it('stops following the editor once closed, and tells the page nothing a read finds after', async () => {
    presetsOnDisk({ Small: { w: 1 } });
    fake.activeDocument = PART;
    const { panel, server, webview } = open();
    // Closed while the presets file is read
    panel.dispose();
    expect(panel.closed).toBe(true);
    fake.showEditor(documentAt('/work/lid.kup'));
    server.restart(9100);
    fake.fileChanged(PRESETS);
    await new Promise((resolve) => setTimeout(resolve));
    expect(server.asked).toEqual([['preview', PART_URI]]);
    expect(webview.html).not.toContain('9100');
    expect(postedOf(webview, 'presets')).toEqual([]);
    expect(fake.watchers).toEqual([]);
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

  it("watches the shown script's presets file alone, wherever the script is", async () => {
    fake.activeDocument = PART;
    const { webview } = open();
    await vi.waitFor(() => expect(postedOf(webview, 'presets')).toHaveLength(1));
    fake.showEditor(documentAt('/elsewhere/lid.kup'));
    await vi.waitFor(() => expect(postedOf(webview, 'presets')).toHaveLength(2));
    // part.kup isn't shown any more
    fake.fileChanged(PRESETS);
    fake.fileChanged('/elsewhere/lid.presets.json');
    await vi.waitFor(() => expect(postedOf(webview, 'presets')).toHaveLength(3));
    await new Promise((resolve) => setTimeout(resolve));
    expect(postedOf(webview, 'presets')).toHaveLength(3);
    expect(postedOf(webview, 'presets')[2]).toMatchObject({ uri: 'file:///elsewhere/lid.kup' });
    expect(fake.watchers).toHaveLength(1);
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

  it('applies no preset of a name the file has not', async () => {
    presetsOnDisk({ Small: { w: 1 } });
    fake.activeDocument = PART;
    const { webview, server, values } = open();
    webview.receive({ type: 'applyPreset', uri: PART_URI, name: 'constructor' });
    webview.receive({ type: 'applyPreset', uri: PART_URI, name: 'Large' });
    await new Promise((resolve) => setTimeout(resolve));
    expect(server.asked).toEqual([['preview', PART_URI]]);
    expect(values.has(PART_URI)).toBe(false);
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

  it('keeps what was written to the presets file while the user named the preset', async () => {
    presetsOnDisk({ Small: { w: 1 } });
    fake.activeDocument = PART;
    const { webview } = open();
    vi.spyOn(window, 'showInputBox').mockImplementationOnce(async () => {
      presetsOnDisk({ Small: { w: 1 }, Medium: { w: 5 } });
      return 'Large';
    });
    webview.receive({ type: 'savePreset', uri: PART_URI, values: { w: 9 } });
    await vi.waitFor(() =>
      expect(presetsOf()).toEqual({ Small: { w: 1 }, Medium: { w: 5 }, Large: { w: 9 } }),
    );
  });

  it("says why a preset wasn't written", async () => {
    fake.activeDocument = PART;
    const { webview } = open();
    vi.spyOn(workspace.fs, 'writeFile').mockRejectedValueOnce(new Error('EROFS: read-only'));
    fake.inputAnswer = 'Small';
    webview.receive({ type: 'savePreset', uri: PART_URI, values: { w: 1 } });
    await vi.waitFor(() =>
      expect(fake.messages[0]).toMatchObject({
        level: 'error',
        text: 'The preset "Small" wasn\'t saved in part.presets.json: EROFS: read-only',
      }),
    );
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
    await vi.waitFor(() =>
      expect(fake.messages[0]?.text).toMatch(
        /^The preset "Small" wasn't saved in part\.presets\.json: it is no JSON/,
      ),
    );
    expect(new TextDecoder().decode(fake.files.get(PRESETS))).toBe('{');
  });
});

describe('ViewerPanel export', () => {
  it('runs the export command on the script the page asks for', async () => {
    /** @type {unknown[]} */
    const exported = [];
    commands.registerCommand('kupcad.export', (/** @type {unknown} */ uri) => exported.push(uri));
    fake.activeDocument = PART;
    const { webview } = open();
    webview.receive({ type: 'export', uri: PART_URI });
    await vi.waitFor(() => expect(exported).toEqual([PART_URI]));
  });
});

/**
 * The page names a place in part.kup: what the panel showed for it, once it showed it or said why
 * not.
 * @param {{ line: number, column: number }} place
 */
async function reveal(place) {
  // The panel shows part.kup: it acts on the document it shows alone
  fake.activeDocument ??= fake.documents.get(PART_URI) ?? documentAt('/work/part.kup');
  const { webview } = open();
  webview.receive({ type: 'reveal', uri: PART_URI, ...place });
  await vi.waitFor(() => expect(fake.shownDocuments.length + fake.messages.length).toBe(1));
  return fake.shownDocuments[0];
}

describe('ViewerPanel reveal', () => {
  it("shows the script at the place the page names, as VS Code counts it, in the script's editor", async () => {
    const part = documentAt('/work/part.kup');
    part.text = 'x = 1\nlabel = "é" + 2';
    fake.activeDocument = part;
    fake.visibleEditors = [
      { document: documentAt('/work/other.kup'), viewColumn: 1 },
      { document: part, viewColumn: 2 },
    ];
    // Column 14 of line 2, in UTF-8 bytes, is the `+`: é is two bytes, and one character
    const shown = await reveal({ line: 2, column: 14 });
    expect(shown.uri).toBe(PART_URI);
    expect(shown.viewColumn).toBe(2);
    expect(shown.selection?.start).toEqual({ line: 1, character: 12 });
    expect(shown.selection?.end).toEqual({ line: 1, character: 12 });
  });

  it("shows it in another file's editor when none shows it, else beside the panel", async () => {
    documentAt('/work/part.kup').text = 'x = 1';
    fake.visibleEditors = [{ document: documentAt('/work/other.kup'), viewColumn: 1 }];
    expect((await reveal({ line: 1, column: 1 })).viewColumn).toBe(1);
    fake.visibleEditors = [];
    fake.shownDocuments = [];
    // A line past the end, the script shorter now: its last
    const shown = await reveal({ line: 9, column: 3 });
    expect(shown.viewColumn).toBe(-2);
    expect(shown.selection?.start).toEqual({ line: 0, character: 2 });
  });

  it("says why the script can't be shown", async () => {
    vi.spyOn(workspace, 'openTextDocument').mockRejectedValueOnce(new Error('the file is gone'));
    await reveal({ line: 1, column: 1 });
    expect(fake.messages).toContainEqual(
      expect.objectContaining({
        level: 'error',
        text: "part.kup can't be shown: the file is gone",
      }),
    );
  });
});
