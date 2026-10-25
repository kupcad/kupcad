// The folder the app shows: the one the user picked (the dialog puts it in the file system's
// scope, with what is under it), its scripts and the files they read, listed as a tree, and
// their file URIs, which the language server knows them by.

import { open } from '@tauri-apps/plugin-dialog';
import { readDir, readTextFile, writeTextFile } from '@tauri-apps/plugin-fs';

/** What a script reads as data: a mesh, a drawing, a JSON file, a font. */
const DATA_EXTENSIONS = new Set([
  'json',
  'stl',
  'obj',
  '3mf',
  'step',
  'stp',
  'svg',
  'dxf',
  'ttf',
  'otf',
]);
const SCRIPT_EXTENSION = 'kup';
/** Folders that hold no file of the user's: hidden ones (.git, .kupcad's packages) and build output. */
const SKIPPED_FOLDER = /^\.|^node_modules$|^target$/;
/** A folder with more files than this is no project: the list stops there. */
export const MAX_ENTRIES = 5000;

/**
 * An entry of the folder's tree, in the order it is shown: a folder before what is in it.
 * @typedef {object} Entry
 * @property {'folder' | 'script' | 'data'} kind
 * @property {string} name
 * @property {string} path its absolute path
 * @property {number} depth how many folders down it is
 */

/** @typedef {Pick<typeof import('@tauri-apps/plugin-fs'), 'readDir'>} DirReader */

/**
 * The folder the user picks, with everything under it in the app's file system scope; null if
 * they pick none.
 * @param {Pick<typeof import('@tauri-apps/plugin-dialog'), 'open'>} [dialog]
 * @returns {Promise<string | null>}
 */
export async function pickFolder(dialog = { open }) {
  const picked = await dialog.open({ directory: true, recursive: true, title: 'Open a folder' });
  return typeof picked === 'string' ? picked : null;
}

/**
 * The tree of `root`: its folders, scripts and data files, each folder's entries by name (its
 * folders first), at most MAX_ENTRIES. A folder with neither is left out.
 * @param {string} root
 * @param {DirReader} [fs]
 * @returns {Promise<Entry[]>}
 */
export async function listFolder(root, fs = { readDir }) {
  /** @type {Entry[]} */
  const entries = [];
  /**
   * @param {string} dir
   * @param {number} depth
   * @returns {Promise<boolean>} whether it holds anything listed
   */
  const walk = async (dir, depth) => {
    const children = (await fs.readDir(dir)).toSorted(
      (a, b) => Number(b.isDirectory) - Number(a.isDirectory) || a.name.localeCompare(b.name),
    );
    let any = false;
    for (const child of children) {
      if (entries.length >= MAX_ENTRIES) return any;
      const path = childPath(dir, child.name);
      if (child.isDirectory) {
        if (SKIPPED_FOLDER.test(child.name) || child.isSymlink) continue;
        const at = entries.push({ kind: 'folder', name: child.name, path, depth }) - 1;
        if (await walk(path, depth + 1)) any = true;
        else entries.splice(at);
      } else if (child.isFile) {
        const kind = kindOf(child.name);
        if (!kind) continue;
        entries.push({ kind, name: child.name, path, depth });
        any = true;
      }
    }
    return any;
  };
  await walk(root, 0);
  return entries;
}

/**
 * What a file is to the app, by its extension: a script, data a script reads, or nothing.
 * @param {string} name
 * @returns {'script' | 'data' | null}
 */
export function kindOf(name) {
  const dot = name.lastIndexOf('.');
  if (dot <= 0) return null;
  const extension = name.slice(dot + 1).toLowerCase();
  if (extension === SCRIPT_EXTENSION) return 'script';
  return DATA_EXTENSIONS.has(extension) ? 'data' : null;
}

/**
 * `name` in the folder `dir`, with the separator `dir` uses.
 * @param {string} dir
 * @param {string} name
 */
export function childPath(dir, name) {
  const separator = dir.includes('\\') && !dir.includes('/') ? '\\' : '/';
  return dir.endsWith(separator) ? `${dir}${name}` : `${dir}${separator}${name}`;
}

/**
 * The file URI of the absolute `path`, each segment percent-encoded, as an editor gives the
 * server a document's (`file:///w/my%20part.kup`; `file:///C%3A/w/a.kup` on Windows).
 * @param {string} path
 */
export function fileUri(path) {
  const forward = path.replaceAll('\\', '/');
  const absolute = forward.startsWith('/') ? forward : `/${forward}`;
  return `file://${absolute.split('/').map(encodeURIComponent).join('/')}`;
}

/** What the app reads and writes a script's text with. */
export const files = { read: readTextFile, write: writeTextFile };
