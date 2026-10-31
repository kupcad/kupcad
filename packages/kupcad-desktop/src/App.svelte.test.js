import { EditorView } from '@codemirror/view';
import { stubRenderer } from '@kupcad/ui/testing';
import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { memorySettings } from '@kupcad/ui';
import App from './App.svelte';
import { fakeServer } from './fake-server.test-helper.js';
import { LanguageServer } from './server.js';

/** @import { Entry } from '@kupcad/files' */
/** @import { MenuEntry } from './menu.js' */
/** @import { Theme } from './theme.js' */

const FOLDER = '/w';
const TEXTS = { '/w/parts/lid.kup': 'cube(2)\n', '/w/part.kup': 'cube(1)\n' };
/** The folder's files, as the disk has them: the scripts' texts, and a data file. */
const DISK = { ...TEXTS, '/w/sizes.json': '{}' };

/** The windows a test opened, closed after it. @type {(() => void)[]} */
const opened = [];
afterEach(() => {
  for (const close of opened.splice(0)) close();
});

/**
 * The window on stand-ins for Tauri's services, with the server, the disk (which a test changes
 * as another program would) and the menus they kept. `update` is the newer version the releases
 * have (none by default), or an error the check ends with; `checkUpdates` looks for it at the
 * start, as a release build does.
 */
function windowOn({
  launched = /** @type {string | null} */ (null),
  settings = memorySettings(),
  update = /** @type {string | Error | null} */ (null),
  checkUpdates = false,
} = {}) {
  const fake = fakeServer({ port: null });
  /** @type {(() => Promise<boolean>) | null} */
  let canClose = null;
  /** Each folder watched: what it is told when it changes, and what stopping it was asked. */
  const watched =
    /** @type {{ root: string, changed: (change: { tree: boolean }) => void, stop: () => void }[]} */ ([]);
  /** The files' texts, and the folders. */
  const disk = new Map(Object.entries(DISK));
  const folders = new Set(['/w', '/w/parts']);
  /** The menu bar set last, and each row's menu shown. */
  const menus = /** @type {{ bar: MenuEntry[], popups: MenuEntry[][] }} */ ({
    bar: [],
    popups: [],
  });
  /** The newer version found, its install and dismissal watched. */
  const found = { install: vi.fn(async () => {}), dismiss: vi.fn(async () => {}) };
  const platform = {
    pickFolder: vi.fn(async () => FOLDER),
    launchFolder: vi.fn(async () => launched),
    readDir: vi.fn(async (/** @type {string} */ dir) => {
      /** Each name in it, and whether it is a folder. @type {Map<string, boolean>} */
      const names = new Map();
      for (const path of [...disk.keys(), ...folders]) {
        if (!path.startsWith(`${dir}/`)) continue;
        const name = path.slice(dir.length + 1).split('/')[0];
        names.set(name, folders.has(`${dir}/${name}`));
      }
      return [...names].map(([name, isDirectory]) => ({
        name,
        isDirectory,
        isFile: !isDirectory,
        isSymlink: false,
      }));
    }),
    watchFolder: vi.fn(
      async (
        /** @type {string} */ root,
        /** @type {(change: { tree: boolean }) => void} */ changed,
      ) => {
        const stop = vi.fn();
        watched.push({ root, changed, stop });
        return stop;
      },
    ),
    files: {
      read: vi.fn(async (/** @type {string} */ path) => {
        const text = disk.get(path);
        if (text === undefined) throw new Error(`${path}: no such file`);
        return text;
      }),
      write: vi.fn(async (/** @type {string} */ path, /** @type {string} */ text) => {
        disk.set(path, text);
      }),
      exists: vi.fn(async (/** @type {string} */ path) => disk.has(path) || folders.has(path)),
      mkdir: vi.fn(async (/** @type {string} */ path) => void folders.add(path)),
      rename: vi.fn(async (/** @type {string} */ from, /** @type {string} */ to) => {
        // A copy: renaming adds to what is iterated
        for (const [path, text] of Array.from(disk)) {
          if (path !== from && !path.startsWith(`${from}/`)) continue;
          disk.delete(path);
          disk.set(to + path.slice(from.length), text);
        }
        if (folders.delete(from)) folders.add(to);
      }),
    },
    trash: vi.fn(async (/** @type {string} */ path) => {
      for (const kept of disk.keys()) if (kept.startsWith(path)) disk.delete(kept);
      for (const kept of folders) if (kept.startsWith(path)) folders.delete(kept);
    }),
    save: vi.fn(async () => null),
    tell: vi.fn(async () => {}),
    confirm: vi.fn(async (/** @type {string} */ _question) => false),
    ask: vi.fn(
      async (
        /** @type {string} */ _question,
        /** @type {{ yes: string, no: string, cancel: string }} */ buttons,
      ) => buttons.cancel,
    ),
    writeFile: vi.fn(async (/** @type {string} */ path, /** @type {Uint8Array} */ bytes) => {
      disk.set(path, new TextDecoder().decode(bytes));
    }),
    exportModel: vi.fn(async () => {}),
    server: (/** @type {string} */ rootUri, /** @type {any} */ on) =>
      new LanguageServer({ rootUri, origin: 'tauri://localhost', on, spawn: fake.spawn }),
    setTheme: vi.fn(async (/** @type {Theme} */ _theme) => {}),
    setZoom: vi.fn(async (/** @type {number} */ _zoom) => {}),
    setMenu: vi.fn(async (/** @type {MenuEntry[]} */ bar) => void (menus.bar = bar)),
    popupMenu: vi.fn(async (/** @type {MenuEntry[]} */ entries) => void menus.popups.push(entries)),
    onClose: async (/** @type {() => Promise<boolean>} */ ask) => {
      canClose = ask;
      return () => {};
    },
    settings: async () => settings,
    checkUpdate: vi.fn(async () => {
      if (update instanceof Error) throw update;
      return update === null ? null : { version: update, current: '0.1.1', ...found };
    }),
  };
  const { unmount } = render(App, {
    props: {
      platform,
      settings,
      viewerOptions: { renderer: stubRenderer().renderer, motionMs: 0 },
      checkUpdates,
    },
  });
  opened.push(unmount);
  return {
    platform,
    fake,
    watched,
    disk,
    folders,
    menus,
    found,
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

/**
 * The item `text` of a menu, at any depth: the menu bar's, or a row's.
 * @param {MenuEntry[]} entries
 * @param {string} text
 * @returns {import('./menu.js').MenuAction | undefined}
 */
function menuItem(entries, text) {
  for (const entry of entries) {
    if (typeof entry !== 'object' || 'predefined' in entry) continue;
    const found =
      'items' in entry ? menuItem(entry.items, text) : entry.text === text ? entry : undefined;
    if (found) return found;
  }
  return undefined;
}

/**
 * Chooses the item `text` of a menu: the menu bar's or a row's.
 * @param {MenuEntry[]} entries
 * @param {string} text
 */
function choose(entries, text) {
  const item = menuItem(entries, text);
  if (!item) throw new Error(`no ${text} in the menu`);
  expect([text, item.enabled ?? true]).toEqual([text, true]);
  item.action();
  return tick();
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
    expect(window.platform.readDir).toHaveBeenCalledWith(FOLDER);
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

  it("keeps the files' width dragged once the drag is done, not at each move of it", async () => {
    const settings = memorySettings();
    windowOn({ settings });
    await openFolder();
    const set = vi.spyOn(settings, 'set');
    // jsdom captures no pointer: the bar takes the drag as a browser gives it
    const capture = HTMLElement.prototype.setPointerCapture;
    HTMLElement.prototype.setPointerCapture = () => {};
    try {
      const bar = screen.getByRole('separator', { name: 'Resize the files' });
      await fireEvent.pointerDown(bar, { button: 0, clientX: 300, pointerId: 1 });
      for (const clientX of [320, 340]) await fireEvent.pointerMove(bar, { clientX, pointerId: 1 });
      expect(filesShown()?.style.width).toBe('264px');
      expect(set).not.toHaveBeenCalled();
      await fireEvent.pointerUp(bar, { pointerId: 1 });
      expect(set).toHaveBeenCalledExactlyOnceWith('app.files', 264);
    } finally {
      HTMLElement.prototype.setPointerCapture = capture;
    }
  });

  it("closes and opens the tree's folders, keeping none of it beyond the folder opened", async () => {
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
    window.disk.delete(LID);
    window.disk.set('/w/parts/lid.stl', 'solid');
    await fireEvent.click(parts());
    await fireEvent.click(screen.getByRole('button', { name: 'Open folder…' }));
    await vi.waitFor(() => expect(screen.getByText('lid.stl')).toBeTruthy());
    expect(parts().getAttribute('aria-expanded')).toBe('true');
    // Only which folder was opened is kept
    const kept = set.mock.calls.map(([key]) => key);
    expect(kept.filter((key) => key !== 'app.folder' && key !== 'app.recent')).toEqual([]);
  });

  it('lists the folder again when what is in it changes, until another is opened', async () => {
    const window = windowOn();
    await openFolder();
    await vi.waitFor(() => expect(window.watched).toHaveLength(1));
    expect(window.watched[0].root).toBe(FOLDER);
    window.disk.set('/w/new.kup', 'cube(5)\n');
    window.watched[0].changed({ tree: true });
    await vi.waitFor(() => expect(screen.getByRole('button', { name: 'new.kup' })).toBeTruthy());
    // A script added is opened as any other
    await fireEvent.click(screen.getByRole('button', { name: 'new.kup' }));
    await vi.waitFor(() => expect(window.platform.files.read).toHaveBeenCalledWith('/w/new.kup'));

    // Another folder: the first isn't watched any more, and what its watcher still says is
    // passed over
    window.folders.add('/v');
    window.disk.set('/v/other.kup', 'cube(6)\n');
    window.platform.pickFolder.mockResolvedValueOnce('/v');
    await fireEvent.click(screen.getByRole('button', { name: 'Open folder…' }));
    await vi.waitFor(() => expect(window.watched).toHaveLength(2));
    expect(window.watched[0].stop).toHaveBeenCalledOnce();
    expect(window.watched[1].root).toBe('/v');
    await vi.waitFor(() => expect(screen.getByRole('button', { name: 'other.kup' })).toBeTruthy());
    window.disk.set('/w/stale.kup', '');
    window.watched[0].changed({ tree: true });
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

  it('are followed as they are set elsewhere: the window given the theme, the console hidden', async () => {
    const settings = memorySettings();
    const window = windowOn({ settings });
    await openFolder();
    settings.set('app.theme', 'dark');
    settings.set('app.console', false);
    await tick();
    expect(window.platform.setTheme).toHaveBeenCalledExactlyOnceWith('dark');
    expect(consoleShown()).toBeNull();
    await fireEvent.click(viewButton('Settings'));
    expect(radio('Dark').checked).toBe(true);
    expect(
      screen.getByRole('checkbox', { name: 'Show the console under the model' }),
    ).toHaveProperty('checked', false);
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

/** The alert above the editor: what the disk did under the script's unsaved changes. */
const alertText = () => screen.queryByRole('alert')?.textContent?.replace(/\s+/g, ' ').trim();
/**
 * Changes the script in the editor as the person would, the window shown as it follows.
 * @param {EditorView} view
 * @param {string} text
 */
async function type(view, text) {
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
  await tick();
}
const LID = '/w/parts/lid.kup';
/** The field a name is given in, in the tree (the editor is a textbox too). */
const files = () => screen.getByRole('navigation', { name: 'Files' });
const field = () => /** @type {HTMLInputElement} */ (within(files()).getByRole('textbox'));
/** Gives the field `name`, then Enter. */
async function give(/** @type {string} */ name) {
  await fireEvent.input(field(), { target: { value: name } });
  await fireEvent.keyDown(field(), { key: 'Enter' });
}
/** The tree's row of lid.kup, with unsaved changes. */
const unsavedLid = () => screen.getByRole('button', { name: 'lid.kup, unsaved' });

describe('a script the disk changed', () => {
  it('follows the disk where nothing is unsaved: a file written, the window back', async () => {
    const window = windowOn();
    const view = await openFolder();
    await vi.waitFor(() => expect(window.watched).toHaveLength(1));
    window.disk.set(LID, 'cube(5)\n');
    window.watched[0].changed({ tree: false });
    await vi.waitFor(() => expect(view.state.doc.toString()).toBe('cube(5)\n'));
    expect(screen.getByRole('button', { name: 'Save' })).toHaveProperty('disabled', true);
    // A change the watcher missed, read when the window has the focus again
    window.disk.set(LID, 'cube(6)\n');
    await fireEvent.focus(globalThis.window);
    await vi.waitFor(() => expect(view.state.doc.toString()).toBe('cube(6)\n'));
    expect(alertText()).toBeUndefined();
  });

  it("keeps the person's unsaved changes, saying the disk's, for them to choose", async () => {
    const window = windowOn();
    const view = await openFolder();
    await vi.waitFor(() => expect(window.watched).toHaveLength(1));
    await type(view, 'mine\n');
    window.disk.set(LID, 'theirs\n');
    window.watched[0].changed({ tree: false });
    await vi.waitFor(() => expect(alertText()).toContain('lid.kup changed on disk.'));
    expect(view.state.doc.toString()).toBe('mine\n');
    await fireEvent.click(screen.getByRole('button', { name: 'Take theirs' }));
    expect(view.state.doc.toString()).toBe('theirs\n');
    expect(alertText()).toBeUndefined();
    expect(screen.getByRole('button', { name: 'Save' })).toHaveProperty('disabled', true);

    // Kept, the next save writes it over the disk's, unasked
    await type(view, 'mine again\n');
    window.disk.set(LID, 'theirs again\n');
    window.watched[0].changed({ tree: false });
    await vi.waitFor(() => expect(alertText()).toContain('changed on disk'));
    await fireEvent.click(screen.getByRole('button', { name: 'Keep mine' }));
    expect(alertText()).toBeUndefined();
    await fireEvent.keyDown(globalThis.window, { key: 's', metaKey: true });
    await vi.waitFor(() => expect(window.disk.get(LID)).toBe('mine again\n'));
    expect(window.platform.confirm).not.toHaveBeenCalled();
  });

  it('asks before a save writes over what the disk changed since, unseen', async () => {
    const window = windowOn();
    const view = await openFolder();
    await type(view, 'mine\n');
    window.disk.set(LID, 'theirs\n');
    await fireEvent.keyDown(globalThis.window, { key: 's', metaKey: true });
    await vi.waitFor(() =>
      expect(window.platform.confirm).toHaveBeenCalledWith(
        'lid.kup changed on disk since it was opened. Save yours over it?',
      ),
    );
    // Declined: nothing written, the disk's said above the editor
    expect(window.disk.get(LID)).toBe('theirs\n');
    await vi.waitFor(() => expect(alertText()).toContain('changed on disk'));
    window.platform.confirm.mockResolvedValueOnce(true);
    await fireEvent.keyDown(globalThis.window, { key: 's', metaKey: true });
    await vi.waitFor(() => expect(window.disk.get(LID)).toBe('mine\n'));
    expect(alertText()).toBeUndefined();
  });

  it('closes a script removed from the disk, and keeps one with changes, a save putting it back', async () => {
    const window = windowOn();
    await openFolder();
    await vi.waitFor(() => expect(window.watched).toHaveLength(1));
    window.disk.delete(LID);
    window.watched[0].changed({ tree: true });
    await vi.waitFor(() => expect(screen.getByText('Open a script from the folder.')).toBeTruthy());
    expect(screen.getByRole('status').textContent).toContain('lid.kup was removed from the disk.');

    await fireEvent.click(partRow());
    const view = await vi.waitFor(async () => {
      const shown = await editorView();
      expect(shown.state.doc.toString()).toBe('cube(1)\n');
      return shown;
    });
    await type(view, 'kept\n');
    window.disk.delete('/w/part.kup');
    window.watched[0].changed({ tree: true });
    await vi.waitFor(() => expect(alertText()).toContain('part.kup was deleted on disk.'));
    await fireEvent.keyDown(globalThis.window, { key: 's', metaKey: true });
    await vi.waitFor(() => expect(window.disk.get('/w/part.kup')).toBe('kept\n'));
  });
});

it('keeps each script’s undo history while another is shown', async () => {
  windowOn();
  const first = await openFolder();
  await type(first, 'cube(9)\n');
  await fireEvent.click(partRow());
  await vi.waitFor(async () => expect((await editorView()).state.doc.toString()).toBe('cube(1)\n'));
  await fireEvent.click(screen.getByRole('button', { name: 'lid.kup, unsaved' }));
  const back = await vi.waitFor(async () => {
    const shown = await editorView();
    expect(shown.state.doc.toString()).toBe('cube(9)\n');
    return shown;
  });
  // Its undo key, as the person presses it (jsdom is no Mac: Ctrl)
  await fireEvent.keyDown(back.contentDOM, { key: 'z', ctrlKey: true });
  expect(back.state.doc.toString()).toBe('cube(2)\n');
});

describe('the files', () => {
  it("makes a script in the open script's folder, named in the tree, and opens it", async () => {
    const window = windowOn();
    await openFolder();
    await fireEvent.click(screen.getByRole('button', { name: 'New script' }));
    expect(field().getAttribute('aria-label')).toBe('New script name');
    await give('cover');
    await vi.waitFor(() => expect(window.disk.get('/w/parts/cover.kup')).toBe(''));
    await vi.waitFor(() =>
      expect(screen.getByRole('button', { name: 'cover.kup' }).getAttribute('aria-current')).toBe(
        'true',
      ),
    );
    expect(within(files()).queryByRole('textbox')).toBeNull();
  });

  it('refuses a name that is there already, or one no system takes, the field kept', async () => {
    const window = windowOn();
    await openFolder();
    await fireEvent.click(screen.getByRole('button', { name: 'New script' }));
    await give('lid');
    await vi.waitFor(() => expect(screen.getByText('lid.kup is there already.')).toBeTruthy());
    await give('a/b');
    expect(screen.getByText(/A name may not have any of/)).toBeTruthy();
    expect(field().getAttribute('aria-invalid')).toBe('true');
    await fireEvent.keyDown(field(), { key: 'Escape' });
    expect(within(files()).queryByRole('textbox')).toBeNull();
    expect(window.platform.files.write).not.toHaveBeenCalled();
  });

  it('makes a folder from the menu bar', async () => {
    const window = windowOn();
    await openFolder();
    await choose(window.menus.bar, 'New Folder');
    expect(field().getAttribute('aria-label')).toBe('New folder name');
    await give('covers');
    await vi.waitFor(() =>
      expect(window.platform.files.mkdir).toHaveBeenCalledWith('/w/parts/covers'),
    );
  });

  it("renames a script from its row's menu, the editor following it, its changes kept", async () => {
    const window = windowOn();
    const view = await openFolder();
    await type(view, 'cube(7)\n');
    await fireEvent.contextMenu(screen.getByRole('button', { name: 'lid.kup, unsaved' }));
    expect(window.platform.popupMenu).toHaveBeenCalledOnce();
    await choose(window.menus.popups[0], 'Rename…');
    expect(field().getAttribute('aria-label')).toBe('Rename lid.kup');
    await give('cover');
    await vi.waitFor(() =>
      expect(window.platform.files.rename).toHaveBeenCalledWith(LID, '/w/parts/cover.kup'),
    );
    await vi.waitFor(() =>
      expect(screen.getByRole('button', { name: 'cover.kup, unsaved' })).toBeTruthy(),
    );
    expect((await editorView()).state.doc.toString()).toBe('cube(7)\n');
    await vi.waitFor(() =>
      expect(window.sent('textDocument/didOpen').map((m) => m.params.textDocument.uri)).toContain(
        'file:///w/parts/cover.kup',
      ),
    );
  });

  it('renames a folder with F2, the script open in it following', async () => {
    const window = windowOn();
    await openFolder();
    parts().focus();
    await fireEvent.keyDown(parts(), { key: 'F2' });
    await give('pieces');
    await vi.waitFor(() =>
      expect(screen.getByRole('button', { name: 'lid.kup' }).getAttribute('title')).toBe(
        '/w/pieces/lid.kup',
      ),
    );
    expect(screen.getByRole('button', { name: 'lid.kup' }).getAttribute('aria-current')).toBe(
      'true',
    );
    expect(window.disk.get('/w/pieces/lid.kup')).toBe('cube(2)\n');
  });

  it('moves a script to the trash once asked, its unsaved changes said, the editor closed', async () => {
    const window = windowOn();
    const view = await openFolder();
    await type(view, 'cube(8)\n');
    unsavedLid().focus();
    await fireEvent.keyDown(unsavedLid(), { key: 'Delete' });
    await vi.waitFor(() =>
      expect(window.platform.confirm).toHaveBeenCalledWith(
        'Move “lid.kup” to the Trash? Its unsaved changes are lost.',
      ),
    );
    expect(window.platform.trash).not.toHaveBeenCalled();
    window.platform.confirm.mockResolvedValueOnce(true);
    await fireEvent.keyDown(unsavedLid(), { key: 'Delete' });
    await vi.waitFor(() => expect(window.platform.trash).toHaveBeenCalledWith(LID));
    await vi.waitFor(() => expect(screen.getByText('Open a script from the folder.')).toBeTruthy());
    // Nothing unsaved is left to ask about
    expect(await window.canClose()).toBe(true);
  });
});

it('shows the folder opened last, not the one whose listing finished last', async () => {
  const window = windowOn();
  window.folders.add('/v');
  window.disk.set('/v/slow.kup', 'cube(3)\n');
  // /v lists slowly; /w, opened meanwhile, lists at once
  /** @type {(() => void) | undefined} */
  let listed;
  const slow = new Promise((done) => (listed = /** @type {() => void} */ (done)));
  const readDir = window.platform.readDir.getMockImplementation();
  window.platform.readDir.mockImplementationOnce(async (dir) => {
    await slow;
    return readDir?.(dir) ?? [];
  });
  window.platform.pickFolder.mockResolvedValueOnce('/v').mockResolvedValueOnce(FOLDER);
  await fireEvent.click(screen.getByRole('button', { name: 'Open folder…' }));
  await fireEvent.click(screen.getByRole('button', { name: 'Open folder…' }));
  await editorView();
  listed?.();
  await tick();
  await tick();
  expect(screen.getByTitle(FOLDER).textContent).toBe('w');
  expect(screen.queryByRole('button', { name: 'slow.kup' })).toBeNull();
  expect(screen.queryByText(/didn't start/)).toBeNull();
});

describe('the folders opened last', () => {
  it('opens the last at the start, unless the settings say not to', async () => {
    const window = windowOn({ settings: memorySettings({ 'app.folder': '/w' }) });
    await editorView();
    expect(window.platform.readDir).toHaveBeenCalledWith('/w');
    window.unmount();
    const not = windowOn({ settings: memorySettings({ 'app.folder': '/w', 'app.reopen': false }) });
    await tick();
    await tick();
    expect(not.platform.readDir).not.toHaveBeenCalled();
    expect(screen.getByRole('heading', { name: 'KupCAD' })).toBeTruthy();
  });

  it('keeps the folders opened, the newest first, and lists them on the welcome', async () => {
    const settings = memorySettings({ 'app.recent': ['/v', '/w'], 'app.reopen': false });
    const window = windowOn({ settings });
    expect(screen.getByRole('heading', { name: 'Recent' })).toBeTruthy();
    window.platform.readDir.mockRejectedValueOnce(new Error('no such folder'));
    await fireEvent.click(screen.getByTitle('/v'));
    await vi.waitFor(() =>
      expect(screen.getByText(/v wasn't listed: no such folder/)).toBeTruthy(),
    );
    expect(screen.getByRole('heading', { name: 'KupCAD' })).toBeTruthy();
    await fireEvent.click(screen.getByTitle('/w'));
    await editorView();
    expect(settings.get('app.recent')).toEqual(['/w', '/v']);
    expect(settings.get('app.folder')).toBe('/w');
  });
});

describe('the menu bar', () => {
  it('follows the window: Save once there is something to save, the files shown or not', async () => {
    const window = windowOn();
    const view = await openFolder();
    await vi.waitFor(() => expect(menuItem(window.menus.bar, 'Save')?.enabled).toBe(false));
    await type(view, 'cube(3)\n');
    await vi.waitFor(() => expect(menuItem(window.menus.bar, 'Save')?.enabled).toBe(true));
    await choose(window.menus.bar, 'Save');
    await vi.waitFor(() => expect(window.disk.get(LID)).toBe('cube(3)\n'));
    await choose(window.menus.bar, 'Hide Files');
    expect(filesShown()).toBeNull();
    await vi.waitFor(() => expect(menuItem(window.menus.bar, 'Show Files')).toBeTruthy());
  });

  it('opens the keyboard shortcuts from Help, before a folder is opened too', async () => {
    const window = windowOn();
    await vi.waitFor(() => expect(window.menus.bar.length).toBeGreaterThan(0));
    await choose(window.menus.bar, 'Keyboard Shortcuts');
    const dialog = await vi.waitFor(() =>
      screen.getByRole('dialog', { name: 'Keyboard shortcuts' }),
    );
    expect(dialog.textContent).toContain('Save the script');
    expect(dialog.textContent).toContain('Rename');
  });

  it('zooms the window in and out, kept for the next start', async () => {
    const settings = memorySettings();
    const window = windowOn({ settings });
    await vi.waitFor(() => expect(window.menus.bar.length).toBeGreaterThan(0));
    expect(window.platform.setZoom).not.toHaveBeenCalled();
    await choose(window.menus.bar, 'Zoom In');
    await choose(window.menus.bar, 'Zoom In');
    expect(settings.get('app.zoom')).toBe(1.25);
    expect(window.platform.setZoom).toHaveBeenLastCalledWith(1.25);
    await choose(window.menus.bar, 'Zoom Out');
    expect(window.platform.setZoom).toHaveBeenLastCalledWith(1.1);
    window.unmount();
    const again = windowOn({ settings });
    await vi.waitFor(() => expect(again.platform.setZoom).toHaveBeenCalledExactlyOnceWith(1.1));
    await choose(again.menus.bar, 'Actual Size');
    expect(again.platform.setZoom).toHaveBeenLastCalledWith(1);
  });
});

describe('updates', () => {
  it('offers a newer version as the window opens, and installs it when told to', async () => {
    const window = windowOn({ update: '0.2.0', checkUpdates: true });
    window.platform.confirm.mockResolvedValueOnce(true);
    await vi.waitFor(() => expect(window.found.install).toHaveBeenCalledOnce());
    expect(window.platform.confirm).toHaveBeenCalledExactlyOnceWith(
      'KupCAD 0.2.0 is out (this is 0.1.1). Install it and restart?',
    );
  });

  it('says nothing as the window opens when there is none, or the check fails offline', async () => {
    const none = windowOn({ checkUpdates: true });
    await vi.waitFor(() => expect(none.platform.checkUpdate).toHaveBeenCalledOnce());
    none.unmount();
    const offline = windowOn({ update: new Error('offline'), checkUpdates: true });
    await vi.waitFor(() => expect(offline.platform.checkUpdate).toHaveBeenCalledOnce());
    await tick();
    expect(offline.platform.tell).not.toHaveBeenCalled();
    expect(screen.queryByRole('status')?.textContent ?? '').not.toContain('Updates');
  });

  it("doesn't look as the window opens unless told to (pnpm dev)", async () => {
    const window = windowOn({ update: '0.2.0' });
    await vi.waitFor(() => expect(window.menus.bar.length).toBeGreaterThan(0));
    expect(window.platform.checkUpdate).not.toHaveBeenCalled();
  });

  it('says from the menu that it is up to date, or why it could not tell', async () => {
    const window = windowOn();
    await vi.waitFor(() => expect(window.menus.bar.length).toBeGreaterThan(0));
    await choose(window.menus.bar, 'Check for Updates…');
    await vi.waitFor(() =>
      expect(window.platform.tell).toHaveBeenCalledExactlyOnceWith('KupCAD is up to date.'),
    );
    window.unmount();
    const offline = windowOn({ update: new Error('offline') });
    await vi.waitFor(() => expect(offline.menus.bar.length).toBeGreaterThan(0));
    await choose(offline.menus.bar, 'Check for Updates…');
    await vi.waitFor(() =>
      expect(screen.getByRole('status').textContent).toContain("Updates weren't checked: offline"),
    );
  });

  it('says why an update failed to install', async () => {
    const window = windowOn({ update: '0.2.0' });
    window.found.install.mockRejectedValueOnce(new Error('the signature is wrong'));
    window.platform.confirm.mockResolvedValueOnce(true);
    await vi.waitFor(() => expect(window.menus.bar.length).toBeGreaterThan(0));
    await choose(window.menus.bar, 'Check for Updates…');
    await vi.waitFor(() =>
      expect(screen.getByRole('status').textContent).toContain(
        "KupCAD 0.2.0 wasn't installed: the signature is wrong",
      ),
    );
  });

  it('asks before restarting on unsaved changes, and lets the update go when told no', async () => {
    const window = windowOn({ update: '0.2.0' });
    const view = await openFolder();
    await type(view, 'cube(3)\n');
    // Install it: yes; restart without saving: no
    window.platform.confirm.mockResolvedValueOnce(true);
    await choose(window.menus.bar, 'Check for Updates…');
    await vi.waitFor(() => expect(window.found.dismiss).toHaveBeenCalledOnce());
    expect(window.platform.confirm).toHaveBeenLastCalledWith(
      'Restart without saving your changes?',
    );
    expect(window.found.install).not.toHaveBeenCalled();
  });
});

it("sizes the editor's font as the settings say", async () => {
  const settings = memorySettings({ 'app.fontSize': 16 });
  windowOn({ settings });
  const desktop = /** @type {HTMLElement} */ (document.querySelector('.kc-desktop'));
  expect(desktop.style.getPropertyValue('--kc-code-font-size')).toBe('16px');
  settings.set('app.fontSize', 18);
  await tick();
  expect(desktop.style.getPropertyValue('--kc-code-font-size')).toBe('18px');
});

it('saves a script a moment after each change where the settings say, never over the disk’s', async () => {
  const window = windowOn({ settings: memorySettings({ 'app.autosave': true }) });
  const view = await openFolder();
  await type(view, 'cube(4)\n');
  expect(window.disk.get(LID)).toBe('cube(2)\n');
  await vi.waitFor(() => expect(window.disk.get(LID)).toBe('cube(4)\n'), { timeout: 3000 });
  await type(view, 'mine\n');
  window.disk.set(LID, 'theirs\n');
  await vi.waitFor(() => expect(alertText()).toContain('changed on disk'), { timeout: 3000 });
  expect(window.disk.get(LID)).toBe('theirs\n');
  expect(window.platform.confirm).not.toHaveBeenCalled();
});

/** A drag from the system's file manager, of `dropped`. @param {File[]} dropped */
const dragging = (dropped) => ({
  dataTransfer: { types: ['Files'], files: dropped, dropEffect: 'none' },
});
/** The paths the window wrote files dropped at. */
const written = (/** @type {ReturnType<typeof windowOn>} */ window) =>
  window.platform.writeFile.mock.calls.map(([path]) => path);

describe('files dropped on the tree from the system', () => {
  it('are added to the folder dropped on, one of a name it has renamed as the person says', async () => {
    const window = windowOn();
    await openFolder();
    window.platform.ask.mockResolvedValueOnce('Rename');
    const listed = window.platform.readDir.mock.calls.length;
    const cover = new File(['cube(3)\n'], 'cover.kup');
    await fireEvent.drop(
      within(files()).getByRole('button', { name: 'parts' }),
      dragging([cover, new File(['cube(9)\n'], 'lid.kup')]),
    );
    await vi.waitFor(() =>
      expect(written(window)).toEqual(['/w/parts/cover.kup', '/w/parts/lid 2.kup']),
    );
    expect(window.platform.ask).toHaveBeenCalledExactlyOnceWith(
      '“lid.kup” is in parts already. Replace it with yours, or add yours as “lid 2.kup”?',
      { yes: 'Rename', no: 'Replace', cancel: 'Cancel' },
    );
    expect(new TextDecoder().decode(window.platform.writeFile.mock.calls[0][1])).toBe('cube(3)\n');
    await vi.waitFor(() =>
      expect(window.platform.readDir.mock.calls.length).toBeGreaterThan(listed),
    );
  });

  it('are none of them added once the person cancels, and what the tree would not show never', async () => {
    const window = windowOn();
    await openFolder();
    const tree = within(files()).getByRole('list');
    await fireEvent.drop(tree, dragging([new File([''], 'a.kup'), new File([''], 'part.kup')]));
    await vi.waitFor(() => expect(window.platform.ask).toHaveBeenCalledOnce());
    await fireEvent.drop(tree, dragging([new File([''], 'notes.txt')]));
    expect(
      await screen.findByText('Not added, being no script or file a script reads: notes.txt'),
    ).toBeTruthy();
    expect(window.platform.writeFile).not.toHaveBeenCalled();
  });
});
