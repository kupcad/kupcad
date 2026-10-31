// A project's files as a tree, whatever keeps them (the disk, a browser's private file system):
// its folders, scripts and the files they read, listed through the host's `readDir`, which of
// them a tree shows with some folders closed, the names a new entry may take, and the paths of
// entries in folders. A path is the host's: `/` or `\` between its names.

/** What a script reads as data: a mesh, a drawing, a JSON file, a font. */
export const DATA_EXTENSIONS = new Set([
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
export const SCRIPT_EXTENSION = 'kup';
/** Folders that hold no file of the user's: hidden ones (.git, .kupcad's packages) and build output. */
export const SKIPPED_FOLDER = /^\.|^node_modules$|^target$/;
/** A folder with more files than this is no project: the list stops there. */
export const MAX_ENTRIES = 5000;

/**
 * An entry of the folder's tree, in the order it is shown: a folder before what is in it.
 * @typedef {object} Entry
 * @property {'folder' | 'script' | 'data'} kind
 * @property {string} name
 * @property {string} path
 * @property {number} depth how many folders down it is
 */

/**
 * An entry of a folder, as the host's `readDir` gives it.
 * @typedef {object} DirEntry
 * @property {string} name
 * @property {boolean} isDirectory
 * @property {boolean} isFile
 * @property {boolean} [isSymlink]
 */

/** @typedef {{ readDir: (path: string) => Promise<DirEntry[]> }} DirReader */

/**
 * The tree of `root`: its folders, scripts and data files, each folder's entries by name (its
 * folders first), at most MAX_ENTRIES. A folder holding files but none of these is left out;
 * an empty one (made a moment ago, for what goes in it) is not.
 * @param {string} root
 * @param {DirReader} fs
 * @returns {Promise<Entry[]>}
 */
export async function listFolder(root, fs) {
  /** @type {Entry[]} */
  const entries = [];
  /**
   * @param {string} dir
   * @param {number} depth
   * @returns {Promise<boolean>} whether it is shown: it holds anything listed, or nothing at all
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
    return any || children.length === 0;
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
 * What a file is to KupCAD, by its extension: a script, data a script reads, or nothing.
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
 * What is wrong with `name` as a new entry's, or null: one the system takes in any folder, not
 * one the tree leaves out (a hidden one).
 * @param {string} name
 * @returns {string | null}
 */
export function nameProblem(name) {
  if (name.trim() === '') return 'A name is needed.';
  if (name !== name.trim()) return 'A name may not start or end with a space.';
  if (/[\\/:*?"<>|]/.test(name) || /\p{Cc}/u.test(name)) {
    return 'A name may not have any of \\ / : * ? " < > |.';
  }
  if (name.startsWith('.'))
    return "A name starting with a dot is hidden: the tree wouldn't show it.";
  return null;
}

/**
 * The name a new script takes for `name`: with its extension, which the tree knows it by.
 * @param {string} name
 */
export function scriptName(name) {
  return kindOf(name) === 'script' ? name : `${name}.${SCRIPT_EXTENSION}`;
}

/**
 * The folder `path` is in.
 * @param {string} path
 */
export function parentOf(path) {
  const at = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  return at <= 0 ? path.slice(0, at + 1) : path.slice(0, at);
}

/**
 * Whether `path` is `under`, or in it, however deep. `under` may end with its separator (the
 * root, `/`).
 * @param {string} path
 * @param {string} under
 */
export function within(path, under) {
  if (path === under) return true;
  if (under.endsWith('/') || under.endsWith('\\')) return path.startsWith(under);
  return path.startsWith(`${under}/`) || path.startsWith(`${under}\\`);
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
