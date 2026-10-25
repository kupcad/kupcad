// What the app's window does its work with, on Tauri: the folder dialog and its files, the save
// and message dialogs, the native side's export, the bundled kupcad's language server, and the
// window's close. App.svelte takes it as a prop, so its tests give it stand-ins.

import { invoke } from '@tauri-apps/api/core';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { confirm, message, save } from '@tauri-apps/plugin-dialog';
import { writeFile } from '@tauri-apps/plugin-fs';
import { files, listFolder, pickFolder } from './folder.js';
import { LanguageServer } from './server.js';

/** @import { ExportFormat } from '@kupcad/protocol/types' */
/** @import { Entry } from './folder.js' */
/** @import { ServerEvents } from './server.js' */

/**
 * @typedef {object} Platform
 * @property {() => Promise<string | null>} pickFolder
 * @property {() => Promise<string | null>} launchFolder the folder named on the command line
 * @property {(root: string) => Promise<Entry[]>} listFolder
 * @property {{ read(path: string): Promise<string>, write(path: string, text: string): Promise<void> }} files
 * @property {(options: { defaultPath: string, filters: { name: string, extensions: string[] }[], title: string }) => Promise<string | null>} save
 * @property {(text: string) => Promise<void>} tell
 * @property {(text: string) => Promise<boolean>} confirm
 * @property {(path: string, bytes: Uint8Array) => Promise<void>} writeFile
 * @property {(script: string, output: string, format: ExportFormat, params: [string, string][]) => Promise<void>} exportModel
 * @property {(rootUri: string, on: ServerEvents) => Pick<LanguageServer, 'client' | 'start' | 'stop' | 'preview' | 'setParams'>} server
 * @property {(canClose: () => Promise<boolean>) => Promise<() => void>} onClose calls `canClose`
 *   when the window is asked to close, and keeps it open when it says no
 */

/** @type {Platform} */
export const tauri = {
  pickFolder: () => pickFolder(),
  launchFolder: () => invoke('launch_folder'),
  listFolder: (root) => listFolder(root),
  files,
  save: (options) => save(options),
  tell: async (text) => void (await message(text, { title: 'KupCAD', kind: 'warning' })),
  confirm: (text) => confirm(text, { title: 'KupCAD', kind: 'warning' }),
  writeFile: (path, bytes) => writeFile(path, bytes),
  exportModel: (script, output, format, params) =>
    invoke('export_model', { script, output, format, params }),
  server: (rootUri, on) => new LanguageServer({ rootUri, origin: location.origin, on }),
  onClose: (canClose) =>
    getCurrentWindow().onCloseRequested(async (event) => {
      if (!(await canClose())) event.preventDefault();
    }),
};
