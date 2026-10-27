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
/** @import { Theme } from './theme.js' */

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
  /** Each folder watched: what it is told when it changes, and what stopping it was asked. */
  const watched = /** @type {{ root: string, changed: () => void, stop: () => void }[]} */ ([]);
  const platform = {
    pickFolder: vi.fn(async () => FOLDER),
    launchFolder: vi.fn(async () => launched),
    listFolder: vi.fn(async (/** @type {string} */ _root) => ENTRIES),
    watchFolder: vi.fn(async (/** @type {string} */ root, /** @type {() => void} */ changed) => {
      const stop = vi.fn();
      watched.push({ root, changed, stop });
      return stop;
    }),
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
    setTheme: vi.fn(async (/** @type {Theme} */ _theme) => {}),
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
    watched,
    /** Closes the window before the test ends. */
    unmount() {
      opened.splice(opened.indexOf(unmount), 1);
      unmount();
    },
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

/** The tree's row of the folder parts. */
const parts = () => screen.getByRole('button', { name: 'parts' });
/** The tree's row of the script part.kup. */
const partRow = () => screen.getByRole('button', { name: 'part.kup' });

/** The strip's buttons: Files, Settings. */
const viewButton = (/** @type {string} */ name) => screen.getByRole('button', { name });
const pressed = (/** @type {string} */ name) => viewButton(name).getAttribute('aria-pressed');
const filesShown = () => screen.queryByRole('navigation', { name: 'Files' });
const settingsShown = () => screen.queryByRole('dialog', { name: 'Settings' });
const radio = (/** @type {string} */ name) =>
  /** @type {HTMLInputElement} */ (screen.getByRole('radio', { name }));
const consoleShown = () => screen.queryByRole('region', { name: 'Console' });
/**
 * Whether an element is out of reach, in an inert one: jsdom has no `inert` of its own, so Svelte
 * sets it as a property, where a browser reflects it as the attribute.
 * @param {Element | null | undefined} element
 */
function inert(element) {
  for (let at = element; at; at = at.parentElement) {
    if (/** @type {HTMLElement} */ (at).inert || at.hasAttribute('inert')) return true;
  }
  return false;
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

  it("closes and opens the tree's folders, keeping none of it beyond the folder open", async () => {
    const settings = memorySettings();
    const set = vi.spyOn(settings, 'set');
    const window = windowOn({ settings });
    await openFolder();
    expect(parts().getAttribute('aria-expanded')).toBe('true');
    await fireEvent.click(parts());
    expect(parts().getAttribute('aria-expanded')).toBe('false');
    expect(screen.queryByRole('button', { name: 'lid.kup' })).toBeNull();
    // The editor keeps the script, hidden in the tree or not
    expect((await editorView()).state.doc.toString()).toBe('cube(2)\n');
    await fireEvent.click(parts());
    expect(screen.getByRole('button', { name: 'lid.kup' })).toBeTruthy();

    // Opened again, every folder is open: here the first script, opened with it, is in none
    window.platform.listFolder.mockResolvedValue([
      { kind: 'folder', name: 'parts', path: '/w/parts', depth: 0 },
      { kind: 'data', name: 'lid.stl', path: '/w/parts/lid.stl', depth: 1 },
      { kind: 'script', name: 'part.kup', path: '/w/part.kup', depth: 0 },
    ]);
    await fireEvent.click(parts());
    await fireEvent.click(screen.getByRole('button', { name: 'Open folder…' }));
    await vi.waitFor(() => expect(screen.getByText('lid.stl')).toBeTruthy());
    expect(parts().getAttribute('aria-expanded')).toBe('true');
    expect(set).not.toHaveBeenCalled();
  });

  it('lists the folder again when what is in it changes, until another is opened', async () => {
    const window = windowOn();
    await openFolder();
    await vi.waitFor(() => expect(window.watched).toHaveLength(1));
    expect(window.watched[0].root).toBe(FOLDER);
    /** @type {Entry} */
    const added = { kind: 'script', name: 'new.kup', path: '/w/new.kup', depth: 0 };
    window.platform.listFolder.mockResolvedValueOnce([...ENTRIES, added]);
    window.watched[0].changed();
    await vi.waitFor(() => expect(screen.getByRole('button', { name: 'new.kup' })).toBeTruthy());
    // A script added is opened as any other
    await fireEvent.click(screen.getByRole('button', { name: 'new.kup' }));
    await vi.waitFor(() => expect(window.platform.files.read).toHaveBeenCalledWith('/w/new.kup'));

    // Another folder: the first isn't watched any more, and what its watcher still says is
    // passed over
    window.platform.pickFolder.mockResolvedValueOnce('/v');
    await fireEvent.click(screen.getByRole('button', { name: 'Open folder…' }));
    await vi.waitFor(() => expect(window.watched).toHaveLength(2));
    expect(window.watched[0].stop).toHaveBeenCalledOnce();
    expect(window.watched[1].root).toBe('/v');
    /** @type {Entry} */
    const stale = { kind: 'script', name: 'stale.kup', path: '/w/stale.kup', depth: 0 };
    window.platform.listFolder.mockResolvedValueOnce([stale]);
    window.watched[0].changed();
    await tick();
    await tick();
    expect(screen.queryByRole('button', { name: 'stale.kup' })).toBeNull();

    // Closed, it watches nothing
    window.unmount();
    expect(window.watched[1].stop).toHaveBeenCalledOnce();
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

describe('the strip', () => {
  it('shows or hides the files, the script kept, and shows them for a folder opened', async () => {
    windowOn();
    await openFolder();
    expect(filesShown()).toBeTruthy();
    expect([pressed('Files'), pressed('Settings')]).toEqual(['true', 'false']);
    await fireEvent.click(viewButton('Files'));
    expect(filesShown()).toBeNull();
    expect(screen.queryByRole('separator', { name: 'Resize the files' })).toBeNull();
    expect(pressed('Files')).toBe('false');
    expect((await editorView()).state.doc.toString()).toBe('cube(2)\n');
    await fireEvent.click(viewButton('Files'));
    expect(filesShown()).toBeTruthy();

    await fireEvent.click(viewButton('Files'));
    await fireEvent.click(screen.getByRole('button', { name: 'Open folder…' }));
    await vi.waitFor(() => expect(filesShown()).toBeTruthy());
  });

  it('opens the settings over the workspace, which stays as it was under them', async () => {
    const window = windowOn();
    const view = await openFolder();
    await vi.waitFor(() => expect(window.sent('textDocument/didOpen')).toHaveLength(1));
    view.dispatch({ changes: { from: 5, to: 6, insert: '3' } });
    await tick();
    const console = consoleShown();
    await fireEvent.click(viewButton('Settings'));
    expect(settingsShown()).toBeTruthy();
    expect([pressed('Files'), pressed('Settings')]).toEqual(['false', 'true']);
    // Under them, out of reach: the bar and the panes, not the strip
    expect(inert(screen.getByRole('button', { name: 'Open folder…' }))).toBe(true);
    expect(inert(filesShown())).toBe(true);
    expect(inert(screen.getByRole('region', { name: 'Script' }))).toBe(true);
    expect(inert(screen.getByRole('region', { name: 'Preview' }))).toBe(true);
    expect(inert(viewButton('Settings'))).toBe(false);

    await fireEvent.click(screen.getByRole('button', { name: 'Close settings' }));
    expect(settingsShown()).toBeNull();
    expect(inert(screen.getByRole('region', { name: 'Script' }))).toBe(false);
    expect(inert(filesShown())).toBe(false);
    // The same editor with its edit, the script never opened again, the same console
    expect(await editorView()).toBe(view);
    expect(view.state.doc.toString()).toBe('cube(3)\n');
    expect(screen.getByRole('button', { name: 'lid.kup, unsaved' })).toBeTruthy();
    expect(window.sent('textDocument/didOpen')).toHaveLength(1);
    expect(window.sent('textDocument/didClose')).toEqual([]);
    expect(consoleShown()).toBe(console);
  });

  it('offers the settings over the welcome, before a folder is opened', async () => {
    windowOn();
    expect(viewButton('Files')).toHaveProperty('disabled', true);
    expect(pressed('Files')).toBe('false');
    await fireEvent.click(viewButton('Settings'));
    expect(settingsShown()).toBeTruthy();
    expect(inert(screen.getByRole('heading', { name: 'KupCAD' }))).toBe(true);
    await fireEvent.click(screen.getByRole('button', { name: 'Close settings' }));
    await openFolder();
    expect(filesShown()).toBeTruthy();
  });

  it('opens the settings with ⌘, or Ctrl+, and gives the focus back as they close', async () => {
    windowOn();
    await openFolder();
    partRow().focus();
    await fireEvent.keyDown(partRow(), { key: ',', metaKey: true });
    expect(settingsShown()).toBeTruthy();
    await vi.waitFor(() => expect(document.activeElement).toBe(radio('System')));
    await fireEvent.keyDown(radio('System'), { key: 'Escape' });
    expect(settingsShown()).toBeNull();
    await vi.waitFor(() => expect(document.activeElement).toBe(partRow()));

    // The shortcut again never closes them; Escape from the strip does
    await fireEvent.keyDown(globalThis.window, { key: ',', ctrlKey: true });
    await fireEvent.keyDown(globalThis.window, { key: ',', ctrlKey: true });
    expect(settingsShown()).toBeTruthy();
    await fireEvent.keyDown(viewButton('Settings'), { key: 'Escape' });
    expect(settingsShown()).toBeNull();

    // Opened with nothing focused, the gear clicked again: the focus on the gear
    /** @type {HTMLElement} */ (document.activeElement).blur();
    await fireEvent.click(viewButton('Settings'));
    await fireEvent.click(viewButton('Settings'));
    expect(settingsShown()).toBeNull();
    await vi.waitFor(() => expect(document.activeElement).toBe(viewButton('Settings')));
  });

  it('closes the settings for the files, shown again if they were hidden', async () => {
    windowOn();
    await openFolder();
    await fireEvent.click(viewButton('Files'));
    await fireEvent.click(viewButton('Settings'));
    await fireEvent.click(viewButton('Files'));
    expect(settingsShown()).toBeNull();
    expect(filesShown()).toBeTruthy();
    expect([pressed('Files'), pressed('Settings')]).toEqual(['true', 'false']);
  });
});

describe('the settings', () => {
  it('set the theme chosen and keep it, for the window to take when the app starts', async () => {
    const settings = memorySettings();
    const first = windowOn({ settings });
    await tick();
    // The system's is the window's own: nothing to set
    expect(first.platform.setTheme).not.toHaveBeenCalled();
    await fireEvent.click(viewButton('Settings'));
    expect(radio('System').checked).toBe(true);
    await fireEvent.click(radio('Dark'));
    expect(first.platform.setTheme).toHaveBeenCalledExactlyOnceWith('dark');
    expect(settings.get('app.theme')).toBe('dark');
    first.unmount();

    const again = windowOn({ settings });
    await vi.waitFor(() => expect(again.platform.setTheme).toHaveBeenCalledExactlyOnceWith('dark'));
    await fireEvent.click(viewButton('Settings'));
    expect(radio('Dark').checked).toBe(true);
    await fireEvent.click(radio('System'));
    expect(again.platform.setTheme).toHaveBeenLastCalledWith('system');
    expect(settings.get('app.theme')).toBe('system');
  });

  it("take a kept theme they don't know as the system's", async () => {
    const window = windowOn({ settings: memorySettings({ 'app.theme': 'sepia' }) });
    await tick();
    expect(window.platform.setTheme).not.toHaveBeenCalled();
    await fireEvent.click(viewButton('Settings'));
    expect(radio('System').checked).toBe(true);
  });

  it("say when the theme wasn't set", async () => {
    const window = windowOn();
    window.platform.setTheme.mockRejectedValueOnce(new Error('not allowed'));
    await openFolder();
    await fireEvent.click(viewButton('Settings'));
    await fireEvent.click(radio('Light'));
    await vi.waitFor(() => expect(screen.getByText(/The theme wasn't set/)).toBeTruthy());
    expect(radio('Light').checked).toBe(true);
  });

  it('hide the console under the model, and keep it hidden', async () => {
    const settings = memorySettings();
    const first = windowOn({ settings });
    await openFolder();
    expect(consoleShown()).toBeTruthy();
    await fireEvent.click(viewButton('Settings'));
    const shows = screen.getByRole('checkbox', { name: 'Show the console under the model' });
    expect(shows).toHaveProperty('checked', true);
    await fireEvent.click(shows);
    expect(consoleShown()).toBeNull();
    expect(screen.queryByRole('separator', { name: 'Resize the console' })).toBeNull();
    expect(settings.get('app.console')).toBe(false);
    first.unmount();

    windowOn({ settings });
    await openFolder();
    expect(consoleShown()).toBeNull();
    await fireEvent.click(viewButton('Settings'));
    await fireEvent.click(
      screen.getByRole('checkbox', { name: 'Show the console under the model' }),
    );
    expect(consoleShown()).toBeTruthy();
    expect(settings.get('app.console')).toBe(true);
  });
});
