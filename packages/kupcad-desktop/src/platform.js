// What the app's window does its work with, on Tauri: the folder dialog and its files (moved to
// the trash by the native side), the save and message dialogs, the native side's export, the
// bundled kupcad's language server, the window's theme, zoom, menus and its close, and the app's
// updates. App.svelte takes it as a prop, so its tests give it stand-ins.

import { invoke } from '@tauri-apps/api/core';
// From its own module: the package's index of the menus re-exports them in a way nodenext
// resolution can't follow
import { Menu } from '@tauri-apps/api/menu/menu';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { confirm, message, save } from '@tauri-apps/plugin-dialog';
import { readDir, writeFile } from '@tauri-apps/plugin-fs';
import { relaunch } from '@tauri-apps/plugin-process';
import { load } from '@tauri-apps/plugin-store';
import { check } from '@tauri-apps/plugin-updater';
import { listFolder } from '@kupcad/files/tree';
import { memorySettings } from '@kupcad/ui';
import { files, pickFolder, watchFolder } from './folder.js';
import { LanguageServer } from './server.js';

/** @import { ExportFormat } from '@kupcad/protocol/types' */
/** @import { Settings } from '@kupcad/ui' */
/** @import { Entry } from '@kupcad/files/tree' */
/** @import { MenuEntry } from './menu.js' */
/** @import { ServerEvents } from './server.js' */
/** @import { Theme } from './theme.js' */

/**
 * @typedef {object} Platform
 * @property {() => Promise<string | null>} pickFolder
 * @property {() => Promise<string | null>} launchFolder the folder named on the command line
 * @property {(root: string) => Promise<Entry[]>} listFolder
 * @property {(root: string, onchange: (change: { tree: boolean }) => void) => Promise<() => void>} watchFolder
 *   calls `onchange` when a file in `root` may have been written, its tree changed too or not;
 *   resolves to what stops it
 * @property {PlatformFiles} files
 * @property {(path: string) => Promise<void>} trash moves a file or folder of the folder opened
 *   to the system's trash
 * @property {(options: { defaultPath: string, filters: { name: string, extensions: string[] }[], title: string }) => Promise<string | null>} save
 * @property {(text: string) => Promise<void>} tell
 * @property {(text: string) => Promise<boolean>} confirm
 * @property {(text: string, buttons: { yes: string, no: string, cancel: string }) => Promise<string>} ask
 *   a question of three answers: the label of the button pressed (the cancel's for the dialog
 *   closed), the yes the default
 * @property {(path: string, bytes: Uint8Array) => Promise<void>} writeFile
 * @property {(script: string, output: string, format: ExportFormat, params: [string, string][]) => Promise<void>} exportModel
 * @property {(rootUri: string, on: ServerEvents) => Pick<LanguageServer, 'client' | 'start' | 'stop' | 'preview' | 'setParams'>} server
 * @property {(theme: Theme) => Promise<void>} setTheme the window's appearance, which the page's
 *   colour scheme follows (`prefers-color-scheme`); the system's follows the system again
 * @property {(zoom: number) => Promise<void>} setZoom how large the page is drawn, 1 its own size
 * @property {(menus: MenuEntry[]) => Promise<void>} setMenu the app's menu bar, in place of the last
 * @property {(entries: MenuEntry[]) => Promise<void>} popupMenu a menu where the pointer is, its
 *   items doing what they do once chosen
 * @property {(canClose: () => Promise<boolean>) => Promise<() => void>} onClose calls `canClose`
 *   when the window is asked to close, and keeps it open when it says no
 * @property {() => Promise<Settings>} settings the app's settings, read before the window is
 *   laid out and reactive after (`memorySettings`), each change written to the file
 * @property {() => Promise<AppUpdate | null>} checkUpdate the newer version the releases have
 *   (their latest.json, tauri.conf.json's updater), null when this one is the newest
 */

/**
 * A newer version of the app than the one running.
 * @typedef {object} AppUpdate
 * @property {string} version
 * @property {string} current the version running
 * @property {() => Promise<void>} install downloads it, checks the release signed it, installs it
 *   and restarts the app on it (on Windows its installer closes the app itself)
 * @property {() => Promise<void>} dismiss lets it go, not installed
 */

/**
 * What the folder's files are read, written, made and renamed with.
 * @typedef {object} PlatformFiles
 * @property {(path: string) => Promise<string>} read
 * @property {(path: string, text: string) => Promise<void>} write
 * @property {(path: string) => Promise<boolean>} exists
 * @property {(path: string) => Promise<void>} mkdir
 * @property {(from: string, to: string) => Promise<void>} rename
 */

/**
 * Tauri's options for the menu entries `entries`.
 * @param {MenuEntry[]} entries
 * @returns {import('@tauri-apps/api/menu/menu').MenuOptions['items']}
 */
function nativeItems(entries) {
  return entries.map((entry) => {
    if (entry === '-') return { item: 'Separator' };
    if ('predefined' in entry) {
      return entry.predefined === 'About'
        ? { item: { About: { name: 'KupCAD' } } }
        : { item: entry.predefined };
    }
    if ('items' in entry) return { text: entry.text, items: nativeItems(entry.items) };
    return {
      text: entry.text,
      accelerator: entry.accelerator,
      enabled: entry.enabled ?? true,
      action: () => entry.action(),
    };
  });
}

/** Which call to setMenu is the latest: an earlier one done after it is passed over. */
let menus = 0;

/**
 * Lets a menu go, a native resource until then (its `close`, a Resource's, which the package's
 * types reach by an import nodenext doesn't follow).
 * @param {Menu | null} menu
 */
async function release(menu) {
  await /** @type {{ close(): Promise<void> } | null} */ (/** @type {unknown} */ (menu))?.close();
}

/** The app's settings file, in its config folder (macOS: ~/Library/Application Support/<id>/). */
const SETTINGS_FILE = 'settings.json';
/** How long the store waits after a change before writing the file, in milliseconds. */
const SETTINGS_SAVE_MS = 250;

/** @type {Platform} */
export const tauri = {
  pickFolder: () => pickFolder(),
  launchFolder: () => invoke('launch_folder'),
  listFolder: (root) => listFolder(root, { readDir }),
  watchFolder: (root, onchange) => watchFolder(root, onchange),
  files,
  trash: (path) => invoke('move_to_trash', { path }),
  save: (options) => save(options),
  tell: async (text) => void (await message(text, { title: 'KupCAD', kind: 'warning' })),
  confirm: (text) => confirm(text, { title: 'KupCAD', kind: 'warning' }),
  ask: (text, buttons) => message(text, { title: 'KupCAD', kind: 'warning', buttons }),
  writeFile: (path, bytes) => writeFile(path, bytes),
  exportModel: (script, output, format, params) =>
    invoke('export_model', { script, output, format, params }),
  server: (rootUri, on) => new LanguageServer({ rootUri, origin: location.origin, on }),
  setTheme: (theme) => getCurrentWindow().setTheme(theme === 'system' ? null : theme),
  setZoom: (zoom) => getCurrentWebview().setZoom(zoom),
  async setMenu(entries) {
    const mine = ++menus;
    const menu = await Menu.new({ items: nativeItems(entries) });
    if (mine !== menus) {
      await release(menu);
      return;
    }
    await release(await menu.setAsAppMenu());
  },
  async popupMenu(entries) {
    // Kept until the page goes: an item chosen is told through it after the menu is gone
    const menu = await Menu.new({ items: nativeItems(entries) });
    await menu.popup();
  },
  onClose: (canClose) =>
    getCurrentWindow().onCloseRequested(async (event) => {
      if (!(await canClose())) event.preventDefault();
    }),
  async settings() {
    const store = await load(SETTINGS_FILE, { defaults: {}, autoSave: SETTINGS_SAVE_MS });
    // Reactive as memorySettings are, each change written to the file too
    const settings = memorySettings(Object.fromEntries(await store.entries()));
    return {
      get: settings.get,
      set(key, value) {
        settings.set(key, value);
        void store.set(key, value);
      },
    };
  },
  async checkUpdate() {
    const update = await check();
    if (!update) return null;
    return {
      version: update.version,
      current: update.currentVersion,
      async install() {
        await update.downloadAndInstall();
        await relaunch();
      },
      // A native resource until then, as a menu is
      dismiss: () => update.close(),
    };
  },
};
