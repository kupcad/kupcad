// The folder the app shows, on the disk: the one the user picked (the dialog puts it in the file
// system's scope, with what is under it), watched for what is made, removed, renamed or written
// in it, its files read and written, and their file URIs, which the language server knows them
// by. Its tree, and the names a new entry may take, are @kupcad/files'.

import { SKIPPED_FOLDER } from '@kupcad/files/tree';
import { open } from '@tauri-apps/plugin-dialog';
import { exists, mkdir, readTextFile, rename, watch, writeTextFile } from '@tauri-apps/plugin-fs';

/** @import { WatchEvent } from '@tauri-apps/plugin-fs' */

/** How long the watcher gathers a folder's changes before it reports them, in milliseconds. */
export const WATCH_DELAY_MS = 300;
/** The language server's kinds of a file's change (LSP FileChangeType). */
const FILE_CHANGE = { created: 1, changed: 2, deleted: 3 };

/** A file changed on disk, as the language server is told (LSP FileEvent). @typedef {{ uri: string, type: number }} FileChange */

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
 * Whether a change the watcher reports under `root` may be to the user's files: anything but a
 * file read, in a folder the tree shows (not .git, node_modules).
 * @param {WatchEvent} event
 * @param {string} root
 */
export function changesFiles(event, root) {
  if (typeof event.type === 'object' && 'access' in event.type) return false;
  return event.paths.length === 0 || event.paths.some((path) => !leftOut(root, path));
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
  if (
    typeof type === 'object' &&
    'modify' in type &&
    (type.modify.kind === 'data' || type.modify.kind === 'metadata')
  ) {
    return false;
  }
  return changesFiles(event, root);
}

/**
 * The files a change the watcher reports under `root` is to, as the language server is told
 * of them: made, removed, or else changed (written, renamed: it reads the disk again); none in
 * the folders the tree leaves out.
 * @param {WatchEvent} event
 * @param {string} root
 * @returns {FileChange[]}
 */
export function fileChangesOf(event, root) {
  if (!changesFiles(event, root)) return [];
  const { type } = event;
  const kind =
    typeof type === 'object' && 'create' in type
      ? FILE_CHANGE.created
      : typeof type === 'object' && 'remove' in type
        ? FILE_CHANGE.deleted
        : FILE_CHANGE.changed;
  return event.paths
    .filter((path) => !leftOut(root, path))
    .map((path) => ({ uri: fileUri(path), type: kind }));
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
 * Watches everything under `root`, calling `onchange` once a moment's changes may be to the
 * user's files (`changesFiles`): a file written, its tree changed too or not (`changesTree`),
 * and the files, as the language server is told of them (`fileChangesOf`).
 * Resolves to what stops it.
 * @param {string} root
 * @param {(change: { tree: boolean, files: FileChange[] }) => void} onchange
 * @param {Pick<typeof import('@tauri-apps/plugin-fs'), 'watch'>} [fs]
 * @returns {Promise<() => void>}
 */
export function watchFolder(root, onchange, fs = { watch }) {
  return fs.watch(
    root,
    (event) => {
      if (changesFiles(event, root)) {
        onchange({ tree: changesTree(event, root), files: fileChangesOf(event, root) });
      }
    },
    { recursive: true, delayMs: WATCH_DELAY_MS },
  );
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

/**
 * The path of the module at `file` in the folder `root`: a path in the project, `/` between its
 * folders, as a frame names a library (the protocol holds it inside the project).
 * @param {string} root
 * @param {string} file
 */
export function modulePath(root, file) {
  const separator = root.includes('\\') && !root.includes('/') ? '\\' : '/';
  return `${root.replace(/[\\/]$/, '')}${separator}${file.replaceAll('/', separator)}`;
}

/** What the app reads, writes, makes and renames the folder's files with. */
export const files = {
  read: readTextFile,
  write: writeTextFile,
  /** @param {string} path */
  exists: (path) => exists(path),
  /** @param {string} path */
  mkdir: (path) => mkdir(path),
  /** @param {string} from @param {string} to */
  rename: (from, to) => rename(from, to),
};
