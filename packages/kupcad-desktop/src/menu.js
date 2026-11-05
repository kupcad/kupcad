// The window's menus, as data the platform makes native ones of (platform.js): the app's menu
// bar, its items enabled as the window's state allows (a row's menu in the folder's tree is
// @kupcad/files' rowMenu).
// macOS has the app's own menu first (About, Check for Updates…, Settings…, Quit); elsewhere
// Settings and Quit are the File menu's, and Check for Updates… the Help menu's. An item's
// shortcut is its accelerator, which the menu takes before the page sees the key; the Keyboard
// Shortcuts dialog lists the same (SHORTCUTS), where the window wrote them again itself.

/** @import { KeyboardSystem } from '@kupcad/ui' */

/**
 * An item that does something.
 * @typedef {object} MenuAction
 * @property {string} text
 * @property {() => void} action
 * @property {string} [accelerator] its shortcut, as Tauri writes one (`CmdOrCtrl+S`)
 * @property {boolean} [enabled] by default it is
 */

/**
 * An entry of a menu: an item that does something, one the system does (Copy, Quit…), a menu
 * of its own, or a separator.
 * @typedef {MenuAction | { predefined: Predefined } | { text: string, items: MenuEntry[] } | '-'} MenuEntry
 */

/**
 * @typedef {'About' | 'Services' | 'Hide' | 'HideOthers' | 'ShowAll' | 'Quit' | 'Undo' | 'Redo'
 *   | 'Cut' | 'Copy' | 'Paste' | 'SelectAll' | 'Minimize' | 'Maximize' | 'Fullscreen'
 *   | 'CloseWindow'} Predefined
 */

/**
 * What the menus do.
 * @typedef {object} MenuActions
 * @property {() => void} newScript
 * @property {() => void} newFolder
 * @property {() => void} openFolder
 * @property {(path: string) => void} openRecent
 * @property {() => void} clearRecent
 * @property {() => void} save
 * @property {() => void} settings
 * @property {() => void} toggleFiles
 * @property {() => void} zoomIn
 * @property {() => void} zoomOut
 * @property {() => void} zoomReset
 * @property {() => void} shortcuts
 * @property {() => void} checkUpdates
 */

/**
 * The window's state the menus follow.
 * @typedef {object} MenuState
 * @property {boolean} mac
 * @property {boolean} folder a folder is open
 * @property {boolean} canSave the script open has unsaved changes
 * @property {boolean} filesShown
 * @property {string[]} recent the folders opened last, the newest first
 */

/**
 * The app's shortcuts, by the action each is: its menu item's accelerator, as Tauri writes it,
 * and what it does, as the Keyboard Shortcuts dialog says.
 */
export const SHORTCUTS = Object.freeze({
  newScript: { accelerator: 'CmdOrCtrl+N', does: 'New script' },
  newFolder: { accelerator: 'CmdOrCtrl+Shift+N', does: 'New folder' },
  openFolder: { accelerator: 'CmdOrCtrl+O', does: 'Open a folder' },
  save: { accelerator: 'CmdOrCtrl+S', does: 'Save the script' },
  toggleFiles: { accelerator: 'CmdOrCtrl+B', does: 'Show or hide the files' },
  settings: { accelerator: 'CmdOrCtrl+,', does: 'Settings' },
  // ⌘= is ⌘+ without Shift, as browsers take it
  zoomIn: { accelerator: 'CmdOrCtrl+=', does: 'Zoom in' },
  zoomOut: { accelerator: 'CmdOrCtrl+-', does: 'Zoom out' },
});

/** The modifiers as a Mac names them, in the order it writes them (Apple's). */
const MAC_MODIFIERS = { Ctrl: '⌃', Alt: '⌥', Shift: '⇧', CmdOrCtrl: '⌘' };

/**
 * An accelerator (`CmdOrCtrl+Shift+N`) as `system` writes its keys: ⇧⌘N on a Mac, Ctrl+Shift+N
 * elsewhere.
 * @param {string} accelerator
 * @param {KeyboardSystem} system
 */
export function keysOf(accelerator, system) {
  const modifiers = accelerator.split('+');
  const key = modifiers.pop();
  if (system !== 'mac')
    return [...modifiers.map((m) => (m === 'CmdOrCtrl' ? 'Ctrl' : m)), key].join('+');
  const named = Object.entries(MAC_MODIFIERS).filter(([modifier]) => modifiers.includes(modifier));
  return named.map(([, sign]) => sign).join('') + key;
}

/**
 * The app's shortcuts as the Keyboard Shortcuts dialog lists them, their keys as `system` writes
 * them.
 * @param {KeyboardSystem} system
 * @returns {[keys: string, what: string][]}
 */
export const shortcutKeys = (system) =>
  Object.values(SHORTCUTS).map(({ accelerator, does }) => [keysOf(accelerator, system), does]);

/** @param {string} text @param {() => void} action @param {Partial<MenuAction>} [more] */
const item = (text, action, more = {}) => ({ text, action, ...more });
/** @param {Predefined} predefined */
const system = (predefined) => ({ predefined });
/** A folder's own name, the last of its path. @param {string} path */
const name = (path) => path.split(/[\\/]/).at(-1) || path;

/**
 * The app's menu bar.
 * @param {MenuState} state
 * @param {MenuActions} actions
 * @returns {MenuEntry[]}
 */
export function menuBar(state, actions) {
  const settings = item('Settings…', actions.settings, {
    accelerator: SHORTCUTS.settings.accelerator,
  });
  const updates = item('Check for Updates…', actions.checkUpdates);
  /** @type {MenuEntry[]} */
  const recent =
    state.recent.length === 0
      ? [item('No Recent Folders', () => {}, { enabled: false })]
      : [
          ...state.recent.map((path) =>
            item(`${name(path)} — ${path}`, () => actions.openRecent(path)),
          ),
          '-',
          item('Clear Recent', actions.clearRecent),
        ];
  return [
    ...(state.mac
      ? [
          {
            text: 'KupCAD',
            items: /** @type {MenuEntry[]} */ ([
              system('About'),
              updates,
              '-',
              settings,
              '-',
              system('Services'),
              '-',
              system('Hide'),
              system('HideOthers'),
              system('ShowAll'),
              '-',
              system('Quit'),
            ]),
          },
        ]
      : []),
    {
      text: 'File',
      items: [
        item('New Script', actions.newScript, {
          accelerator: SHORTCUTS.newScript.accelerator,
          enabled: state.folder,
        }),
        item('New Folder', actions.newFolder, {
          accelerator: SHORTCUTS.newFolder.accelerator,
          enabled: state.folder,
        }),
        '-',
        item('Open Folder…', actions.openFolder, {
          accelerator: SHORTCUTS.openFolder.accelerator,
        }),
        { text: 'Open Recent', items: recent },
        '-',
        item('Save', actions.save, {
          accelerator: SHORTCUTS.save.accelerator,
          enabled: state.canSave,
        }),
        ...(state.mac ? [] : /** @type {MenuEntry[]} */ (['-', settings, '-', system('Quit')])),
      ],
    },
    {
      text: 'Edit',
      items: [
        system('Undo'),
        system('Redo'),
        '-',
        system('Cut'),
        system('Copy'),
        system('Paste'),
        system('SelectAll'),
      ],
    },
    {
      text: 'View',
      items: [
        item(state.filesShown ? 'Hide Files' : 'Show Files', actions.toggleFiles, {
          accelerator: SHORTCUTS.toggleFiles.accelerator,
          enabled: state.folder,
        }),
        '-',
        item('Zoom In', actions.zoomIn, { accelerator: SHORTCUTS.zoomIn.accelerator }),
        item('Zoom Out', actions.zoomOut, { accelerator: SHORTCUTS.zoomOut.accelerator }),
        // No ⌘0: the viewer's keys look from the iso view with it
        item('Actual Size', actions.zoomReset),
        ...(state.mac ? /** @type {MenuEntry[]} */ (['-', system('Fullscreen')]) : []),
      ],
    },
    {
      text: 'Window',
      items: [system('Minimize'), system('Maximize'), '-', system('CloseWindow')],
    },
    {
      text: 'Help',
      items: [
        item('Keyboard Shortcuts', actions.shortcuts),
        ...(state.mac ? [] : /** @type {MenuEntry[]} */ (['-', updates])),
      ],
    },
  ];
}
