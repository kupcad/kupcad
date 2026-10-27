// The window's menus, as data the platform makes native ones of (platform.js): the app's menu
// bar, its items enabled as the window's state allows, and a row's menu in the folder's tree.
// macOS has the app's own menu first (About, Settings…, Quit); elsewhere Settings and Quit are
// the File menu's. An item's shortcut is its accelerator, which the menu takes before the page
// sees the key.

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
  const settings = item('Settings…', actions.settings, { accelerator: 'CmdOrCtrl+,' });
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
          accelerator: 'CmdOrCtrl+N',
          enabled: state.folder,
        }),
        item('New Folder', actions.newFolder, {
          accelerator: 'CmdOrCtrl+Shift+N',
          enabled: state.folder,
        }),
        '-',
        item('Open Folder…', actions.openFolder, { accelerator: 'CmdOrCtrl+O' }),
        { text: 'Open Recent', items: recent },
        '-',
        item('Save', actions.save, { accelerator: 'CmdOrCtrl+S', enabled: state.canSave }),
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
          accelerator: 'CmdOrCtrl+B',
          enabled: state.folder,
        }),
        '-',
        // ⌘= is ⌘+ without Shift, as browsers take it
        item('Zoom In', actions.zoomIn, { accelerator: 'CmdOrCtrl+=' }),
        item('Zoom Out', actions.zoomOut, { accelerator: 'CmdOrCtrl+-' }),
        // No ⌘0: the viewer's keys look from the iso view with it
        item('Actual Size', actions.zoomReset),
        ...(state.mac ? /** @type {MenuEntry[]} */ (['-', system('Fullscreen')]) : []),
      ],
    },
    {
      text: 'Window',
      items: [system('Minimize'), system('Maximize'), '-', system('CloseWindow')],
    },
    { text: 'Help', items: [item('Keyboard Shortcuts', actions.shortcuts)] },
  ];
}

/**
 * The menu of a row of the folder's tree (`entry`), or of the tree itself (none): what can be
 * made in its folder, and what can be done to it.
 * @param {import('./folder.js').Entry | null} entry
 * @param {{ newScript: () => void, newFolder: () => void, rename: () => void, trash: () => void }} actions
 * @param {string} [trash] what the system calls where a file moved away goes
 * @returns {MenuEntry[]}
 */
export function rowMenu(entry, actions, trash = 'Trash') {
  /** @type {MenuEntry[]} */
  const make = [item('New Script', actions.newScript), item('New Folder', actions.newFolder)];
  if (!entry) return make;
  return [...make, '-', item('Rename…', actions.rename), item(`Move to ${trash}`, actions.trash)];
}
