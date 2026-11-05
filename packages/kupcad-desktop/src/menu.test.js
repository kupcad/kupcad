import { describe, expect, it, vi } from 'vitest';
import { keysOf, menuBar, SHORTCUTS, shortcutKeys } from './menu.js';

/** @import { MenuAction, MenuEntry, MenuState } from './menu.js' */

/** Every action, a stand-in. */
const actions = () => ({
  newScript: vi.fn(),
  newFolder: vi.fn(),
  openFolder: vi.fn(),
  openRecent: vi.fn(),
  clearRecent: vi.fn(),
  save: vi.fn(),
  settings: vi.fn(),
  toggleFiles: vi.fn(),
  zoomIn: vi.fn(),
  zoomOut: vi.fn(),
  zoomReset: vi.fn(),
  shortcuts: vi.fn(),
  checkUpdates: vi.fn(),
});

/** @type {MenuState} */
const STATE = { mac: true, folder: true, canSave: false, filesShown: true, recent: [] };

/**
 * The item of the menu named `menu` whose text is `text`, at any depth.
 * @param {MenuEntry[]} bar
 * @param {string} menu
 * @param {string} text
 */
function itemOf(bar, menu, text) {
  /** @param {MenuEntry[]} entries @returns {MenuAction | undefined} */
  const find = (entries) => {
    for (const entry of entries) {
      if (typeof entry !== 'object' || 'predefined' in entry) continue;
      if ('items' in entry) {
        const found = find(entry.items);
        if (found) return found;
      } else if (entry.text === text) return entry;
    }
    return undefined;
  };
  const submenu = submenuOf(bar, menu);
  return submenu ? find(submenu.items) : undefined;
}

/**
 * The menu of the bar named `title`.
 * @param {MenuEntry[]} bar
 * @param {string} title
 * @returns {{ text: string, items: MenuEntry[] } | undefined}
 */
function submenuOf(bar, title) {
  for (const entry of bar) {
    if (typeof entry === 'object' && 'items' in entry && entry.text === title) return entry;
  }
  return undefined;
}
const titles = (/** @type {MenuEntry[]} */ bar) =>
  bar.map((entry) => (typeof entry === 'object' && 'text' in entry ? entry.text : ''));

describe('the menu bar', () => {
  it("has the app's own menu first on a Mac, Settings and Quit in it", () => {
    expect(titles(menuBar(STATE, actions()))).toEqual([
      'KupCAD',
      'File',
      'Edit',
      'View',
      'Window',
      'Help',
    ]);
    const elsewhere = menuBar({ ...STATE, mac: false }, actions());
    expect(titles(elsewhere)).toEqual(['File', 'Edit', 'View', 'Window', 'Help']);
    expect(itemOf(elsewhere, 'File', 'Settings…')?.accelerator).toBe('CmdOrCtrl+,');
    // Checking for updates is the app menu's on a Mac, Help's elsewhere
    expect(itemOf(elsewhere, 'Help', 'Check for Updates…')).toBeTruthy();
    expect(itemOf(menuBar(STATE, actions()), 'Help', 'Check for Updates…')).toBeUndefined();
  });

  it("does what each item says, its shortcut the page's", () => {
    const does = actions();
    const bar = menuBar({ ...STATE, canSave: true }, does);
    for (const [menu, text, action, accelerator] of /** @type {const} */ ([
      ['File', 'New Script', 'newScript', 'CmdOrCtrl+N'],
      ['File', 'New Folder', 'newFolder', 'CmdOrCtrl+Shift+N'],
      ['File', 'Open Folder…', 'openFolder', 'CmdOrCtrl+O'],
      ['File', 'Save', 'save', 'CmdOrCtrl+S'],
      ['KupCAD', 'Settings…', 'settings', 'CmdOrCtrl+,'],
      ['View', 'Hide Files', 'toggleFiles', 'CmdOrCtrl+B'],
      ['View', 'Zoom In', 'zoomIn', 'CmdOrCtrl+='],
      ['View', 'Zoom Out', 'zoomOut', 'CmdOrCtrl+-'],
      ['View', 'Actual Size', 'zoomReset', undefined],
      ['Help', 'Keyboard Shortcuts', 'shortcuts', undefined],
      ['KupCAD', 'Check for Updates…', 'checkUpdates', undefined],
    ])) {
      const found = itemOf(bar, menu, text);
      expect([text, found?.accelerator]).toEqual([text, accelerator]);
      found?.action();
      expect([text, does[action].mock.calls.length]).toEqual([text, 1]);
    }
  });

  it("enables what the window's state allows", () => {
    const empty = menuBar({ ...STATE, folder: false, filesShown: false }, actions());
    expect(itemOf(empty, 'File', 'New Script')?.enabled).toBe(false);
    expect(itemOf(empty, 'File', 'Save')?.enabled).toBe(false);
    expect(itemOf(empty, 'View', 'Show Files')?.enabled).toBe(false);
    expect(itemOf(menuBar({ ...STATE, canSave: true }, actions()), 'File', 'Save')?.enabled).toBe(
      true,
    );
  });

  it('opens a recent folder, and forgets them all', () => {
    const does = actions();
    const bar = menuBar({ ...STATE, recent: ['/w/parts', '/v'] }, does);
    itemOf(bar, 'File', 'parts — /w/parts')?.action();
    expect(does.openRecent).toHaveBeenCalledWith('/w/parts');
    itemOf(bar, 'File', 'Clear Recent')?.action();
    expect(does.clearRecent).toHaveBeenCalledOnce();
    expect(itemOf(menuBar(STATE, actions()), 'File', 'No Recent Folders')?.enabled).toBe(false);
  });

  it("keeps the system's own Edit items: copy and paste need them on a Mac", () => {
    expect(submenuOf(menuBar(STATE, actions()), 'Edit')?.items).toContainEqual({
      predefined: 'Paste',
    });
  });
});

/**
 * The accelerators of `entries`, at any depth.
 * @param {MenuEntry[]} entries
 * @returns {string[]}
 */
const accelerators = (entries) =>
  entries.flatMap((entry) => {
    if (typeof entry !== 'object' || 'predefined' in entry) return [];
    if ('items' in entry) return accelerators(entry.items);
    return entry.accelerator ? [entry.accelerator] : [];
  });

describe('the shortcuts', () => {
  it("are the menu bar's, each listed in the Keyboard Shortcuts dialog", () => {
    const listed = Object.values(SHORTCUTS).map((shortcut) => shortcut.accelerator);
    for (const mac of [true, false]) {
      expect(accelerators(menuBar({ ...STATE, mac }, actions())).toSorted()).toEqual(
        listed.toSorted(),
      );
    }
    expect(shortcutKeys('mac')).toContainEqual(['⌘S', 'Save the script']);
    expect(shortcutKeys('windows')).toContainEqual(['Ctrl+Shift+N', 'New folder']);
  });

  it('are written as the system names its keys', () => {
    expect(keysOf('CmdOrCtrl+Shift+N', 'mac')).toBe('⇧⌘N');
    expect(keysOf('CmdOrCtrl+,', 'mac')).toBe('⌘,');
    expect(keysOf('CmdOrCtrl+-', 'mac')).toBe('⌘-');
    expect(keysOf('CmdOrCtrl+Shift+N', 'windows')).toBe('Ctrl+Shift+N');
    expect(keysOf('CmdOrCtrl+=', 'other')).toBe('Ctrl+=');
  });
});
