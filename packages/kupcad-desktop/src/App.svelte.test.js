import { EditorView } from '@codemirror/view';
import { stubRenderer } from '@kupcad/viewer/testing';
import { fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { memorySettings } from '@kupcad/panels';
import App from './App.svelte';
import { fakeServer } from './fake-server.test-helper.js';
import { LanguageServer } from './server.js';

/** @import { Entry } from './folder.js' */

const FOLDER = '/w';
/** @type {Entry[]} */
const ENTRIES = [
  { kind: 'folder', name: 'parts', path: '/w/parts', depth: 0 },
  { kind: 'script', name: 'lid.kup', path: '/w/parts/lid.kup', depth: 1 },
  { kind: 'script', name: 'part.kup', path: '/w/part.kup', depth: 0 },
  { kind: 'data', name: 'sizes.json', path: '/w/sizes.json', depth: 0 },
];
const TEXTS = { '/w/parts/lid.kup': 'cube(2)\n', '/w/part.kup': 'cube(1)\n' };

/** The windows a test opened, closed after it. @type {(() => void)[]} */
const opened = [];
afterEach(() => {
  for (const close of opened.splice(0)) close();
});

/** The window on stand-ins for Tauri's services, with the server and the files they kept. */
function windowOn({
  launched = /** @type {string | null} */ (null),
  settings = memorySettings(),
} = {}) {
  const fake = fakeServer({ port: null });
  /** @type {(() => Promise<boolean>) | null} */
  let canClose = null;
  const platform = {
    pickFolder: vi.fn(async () => FOLDER),
    launchFolder: vi.fn(async () => launched),
    listFolder: vi.fn(async () => ENTRIES),
    files: {
      read: vi.fn(async (/** @type {string} */ path) => TEXTS[/** @type {keyof TEXTS} */ (path)]),
      write: vi.fn(async (/** @type {string} */ _path, /** @type {string} */ _text) => {}),
    },
    save: vi.fn(async () => null),
    tell: vi.fn(async () => {}),
    confirm: vi.fn(async () => false),
    writeFile: vi.fn(async () => {}),
    exportModel: vi.fn(async () => {}),
    server: (/** @type {string} */ rootUri, /** @type {any} */ on) =>
      new LanguageServer({ rootUri, origin: 'tauri://localhost', on, spawn: fake.spawn }),
    onClose: async (/** @type {() => Promise<boolean>} */ ask) => {
      canClose = ask;
      return () => {};
    },
    settings: async () => settings,
  };
  const { unmount } = render(App, {
    props: {
      platform,
      settings,
      viewerOptions: { renderer: stubRenderer().renderer, motionMs: 0 },
    },
  });
  opened.push(unmount);
  return {
    platform,
    fake,
    /** What the server was sent, by method. @param {string} method */
    sent: (method) => fake.processes.flatMap((p) => p.received).filter((m) => m.method === method),
    canClose: () => /** @type {() => Promise<boolean>} */ (canClose)(),
  };
}

/** The editor's CodeMirror view, once it shows a script. */
async function editorView() {
  return vi.waitFor(() => {
    const content = document.querySelector('.cm-content');
    if (!content) throw new Error('no editor yet');
    return /** @type {EditorView} */ (EditorView.findFromDOM(/** @type {HTMLElement} */ (content)));
  });
}

/** Opens the folder, its first script in the editor. */
async function openFolder() {
  await fireEvent.click(screen.getByRole('button', { name: 'Open folder…' }));
  return editorView();
}

describe('the window', () => {
  it("opens a folder: its scripts listed, the first open in the editor and on kupcad's server", async () => {
    const window = windowOn();
    expect(screen.getByRole('heading', { name: 'KupCAD' })).toBeTruthy();
    const view = await openFolder();
    expect(window.platform.listFolder).toHaveBeenCalledWith(FOLDER);
    const files = screen.getByRole('navigation', { name: 'Files' });
    expect(files.textContent).toContain('parts');
    expect(files.textContent).toContain('sizes.json');
    expect(view.state.doc.toString()).toBe('cube(2)\n');
    expect(window.fake.processes[0].received[0].params.rootUri).toBe('file:///w');
    await vi.waitFor(() =>
      expect(window.sent('textDocument/didOpen')[0].params.textDocument.uri).toBe(
        'file:///w/parts/lid.kup',
      ),
    );
    // The preview shows it
    const commands = window.sent('workspace/executeCommand').map((m) => m.params);
    expect(commands).toContainEqual({
      command: 'kupcad.preview',
      arguments: [{ uri: 'file:///w/parts/lid.kup' }],
    });
  });

  it('opens a script clicked in the tree, on the server too', async () => {
    const window = windowOn();
    await openFolder();
    await fireEvent.click(screen.getByRole('button', { name: 'part.kup' }));
    const view = await vi.waitFor(async () => {
      const shown = await editorView();
      expect(shown.state.doc.toString()).toBe('cube(1)\n');
      return shown;
    });
    expect(screen.getByRole('button', { name: 'part.kup' }).getAttribute('aria-current')).toBe(
      'true',
    );
    await vi.waitFor(() =>
      expect(window.sent('textDocument/didOpen').map((m) => m.params.textDocument.uri)).toContain(
        'file:///w/part.kup',
      ),
    );
    expect(view.state.doc.toString()).toBe('cube(1)\n');
  });

  it('marks a script edited as unsaved, and saves it with ⌘S', async () => {
    const window = windowOn();
    const view = await openFolder();
    view.dispatch({ changes: { from: 5, to: 6, insert: '3' } });
    await tick();
    expect(screen.getByRole('button', { name: 'lid.kup, unsaved' })).toBeTruthy();
    await fireEvent.keyDown(globalThis.window, { key: 's', metaKey: true });
    await vi.waitFor(() =>
      expect(window.platform.files.write).toHaveBeenCalledWith('/w/parts/lid.kup', 'cube(3)\n'),
    );
    await vi.waitFor(() => expect(screen.getByRole('button', { name: 'lid.kup' })).toBeTruthy());
    // Its edit back to what is on disk is no change to save
    view.dispatch({ changes: { from: 5, to: 6, insert: '2' } });
    view.dispatch({ changes: { from: 5, to: 6, insert: '3' } });
    await tick();
    expect(screen.getByRole('button', { name: 'Save' })).toHaveProperty('disabled', true);
  });

  it('opens the folder it was started with', async () => {
    const window = windowOn({ launched: FOLDER });
    const view = await editorView();
    expect(window.platform.pickFolder).not.toHaveBeenCalled();
    expect(view.state.doc.toString()).toBe('cube(2)\n');
  });

  it('lays its panes out as the settings keep them, and keeps what the person changes', async () => {
    const settings = memorySettings({ 'app.files': 260, 'app.editor': 600 });
    windowOn({ settings });
    await openFolder();
    const files = screen.getByRole('navigation', { name: 'Files' });
    expect(files.style.width).toBe('260px');
    expect(screen.getByRole('region', { name: 'Script' }).style.width).toBe('600px');
    await fireEvent.keyDown(screen.getByRole('separator', { name: 'Resize the files' }), {
      key: 'ArrowRight',
    });
    expect(settings.get('app.files')).toBe(276);
    // The preview's panes are kept in the same settings
    expect(screen.getByRole('separator', { name: 'Resize the console' })).toBeTruthy();
  });

  it('asks before it closes on unsaved changes, and not without', async () => {
    const window = windowOn();
    const view = await openFolder();
    expect(await window.canClose()).toBe(true);
    view.dispatch({ changes: { from: 0, to: 0, insert: '# a note\n' } });
    await tick();
    expect(await window.canClose()).toBe(false);
    expect(window.platform.confirm).toHaveBeenCalledWith('Close without saving your changes?');
  });
});
