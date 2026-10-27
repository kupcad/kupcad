// The folder the app shows: the one the user picked (the dialog puts it in the file system's
// scope, with what is under it), its scripts and the files they read, listed as a tree and
// watched for what is made, removed or renamed in it, and their file URIs, which the language
// server knows them by.

import { open } from '@tauri-apps/plugin-dialog';
import { readDir, readTextFile, watch, writeTextFile } from '@tauri-apps/plugin-fs';

/** @import { WatchEvent } from '@tauri-apps/plugin-fs' */

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
/** How long the watcher gathers a folder's changes before it reports them, in milliseconds. */
export const WATCH_DELAY_MS = 300;

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
 * The entries a tree shows with the folders in `collapsed` closed: a closed folder's row, and
 * nothing of what is under it.
 * @param {Entry[]} entries
 * @param {ReadonlySet<string>} collapsed the closed folders' paths
 * @returns {Entry[]}
 */
export function shownEntries(entries, collapsed) {
  /** @type {Entry[]} */
  const shown = [];
  // The depth of the closed folder whose entries are being passed over
  let closed = Infinity;
  for (const entry of entries) {
    if (entry.depth > closed) continue;
    closed = Infinity;
    shown.push(entry);
    if (entry.kind === 'folder' && collapsed.has(entry.path)) closed = entry.depth;
  }
  return shown;
}

/**
 * The folders the entry at `path` is in, the outermost first: in the tree's order, the nearest
 * entry before it at each depth above its own. None for one the tree doesn't hold.
 * @param {Entry[]} entries
 * @param {string} path
 * @returns {string[]}
 */
export function foldersAbove(entries, path) {
  const at = entries.findIndex((entry) => entry.path === path);
  if (at < 0) return [];
  /** @type {string[]} */
  const above = [];
  let depth = entries[at].depth;
  for (let i = at - 1; i >= 0 && depth > 0; i--) {
    if (entries[i].depth < depth) {
      above.unshift(entries[i].path);
      depth = entries[i].depth;
    }
  }
  return above;
}

/**
 * Whether a change the watcher reports under `root` may change its tree: an entry made,
 * removed or renamed, or one the system can't say what of; not a file read, or one written in
 * place (a save), nor anything in the folders the tree leaves out (.git, node_modules).
 * @param {WatchEvent} event
 * @param {string} root
 */
export function changesTree(event, root) {
  const { type } = event;
  if (typeof type === 'object') {
    if ('access' in type) return false;
    if ('modify' in type && (type.modify.kind === 'data' || type.modify.kind === 'metadata')) {
      return false;
    }
  }
  return event.paths.length === 0 || event.paths.some((path) => !leftOut(root, path));
}

/**
 * Whether `path`, under `root`, is what the tree leaves out: in a skipped folder, or one itself
 * (a hidden file too). A path the root isn't a prefix of (the system's real path for it) may be
 * anything.
 * @param {string} root
 * @param {string} path
 */
function leftOut(root, path) {
  if (!path.startsWith(root)) return false;
  return path
    .slice(root.length)
    .split(/[\\/]/)
    .some((name) => name !== '' && SKIPPED_FOLDER.test(name));
}

/**
 * Watches everything under `root`, calling `onchange` once a moment's changes may have changed
 * its tree (`changesTree`); resolves to what stops it.
 * @param {string} root
 * @param {() => void} onchange
 * @param {Pick<typeof import('@tauri-apps/plugin-fs'), 'watch'>} [fs]
 * @returns {Promise<() => void>}
 */
export function watchFolder(root, onchange, fs = { watch }) {
  return fs.watch(
    root,
    (event) => {
      if (changesTree(event, root)) onchange();
    },
    { recursive: true, delayMs: WATCH_DELAY_MS },
  );
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
