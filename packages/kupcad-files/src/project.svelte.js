// A project open in a host, over the host's file system (the disk, a browser's private file
// system): its tree (`entries`, listed one listing at a time), its closed folders, the scripts
// read (`scripts`), the name being given in the tree and what came of it, the files the person
// gives it, and the saves waiting. What a host does around these is its own: which file it
// opens, how it asks, where it says what went wrong (`onproblem`). One per folder opened: a
// listing of a folder left behind lands on its own, discarded, Project.

import { errorText } from '@kupcad/protocol';
import { SvelteSet } from 'svelte/reactivity';
import { putFiles } from './drop.js';
import { Scripts } from './scripts.svelte.js';
import {
  childPath,
  foldersAbove,
  listFolder,
  nameOf,
  nameProblem,
  parentOf,
  renamedName,
  scriptName,
  within,
} from './tree.js';

/** @import { Clash } from './drop.js' */
/** @import { DirEntry, Entry } from './tree.js' */

/**
 * The host's file system, by paths from the project's root.
 * @typedef {object} ProjectFiles
 * @property {(path: string) => Promise<DirEntry[]>} readDir
 * @property {(path: string) => Promise<string>} read
 * @property {(path: string, text: string) => Promise<void>} write
 * @property {(path: string, bytes: Uint8Array<ArrayBuffer>) => Promise<void>} writeBytes
 * @property {(path: string) => Promise<boolean>} exists
 * @property {(path: string) => Promise<void>} mkdir
 * @property {(from: string, to: string) => Promise<void>} rename
 * @property {(path: string) => Promise<void>} remove to the trash where the system has one
 */

/**
 * @typedef {object} ProjectOptions
 * @property {(text: string) => void} onproblem what went wrong, for the host to show
 * @property {(path: string) => void} onsave a script changed stayed so for `saveAfterMs`: the
 *   host saves it
 * @property {() => number | null} [saveAfterMs] how long a script changed waits to be saved, in
 *   milliseconds; null for not by itself. Read at each change.
 * @property {() => void} [beforeRename] called before an entry is renamed, for the host to keep
 *   what it has of the scripts in it (an editor's snapshot) under their old paths
 * @property {boolean} [ignoresCase] whether the file system takes `A.kup` for `a.kup`: a rename
 *   to the same name in another case is then no clash
 */

/**
 * A name being given: a row's new one, or a new entry's in the folder `in`.
 * @typedef {{ path: string } | { in: string, kind: 'script' | 'folder' }} Naming
 */

export class Project {
  /** The root's path: `/`, or the folder's on the disk. */
  root;
  /** The tree, as listed last. @type {Entry[]} */
  entries = $state.raw([]);
  /** The tree's closed folders, by their paths. */
  collapsed = new SvelteSet();
  /** The scripts read: their texts, what is unsaved, what the disk changed under them. */
  scripts;
  /** The name being given in the tree, if one is. @type {Naming | null} */
  editing = $state(null);
  /** What is wrong with the name given last. @type {string | null} */
  nameError = $state(null);
  /** A name given is being made into an entry: one given again meanwhile is the same. */
  #naming = false;
  /** The listing under way, and whether another is wanted after it. */
  #listing = /** @type {Promise<boolean> | null} */ (null);
  #again = false;
  /** Each script changed that waits to be saved, by its path. @type {Map<string, ReturnType<typeof setTimeout>>} */
  #saves = new Map();
  #fs;
  #options;

  /**
   * @param {string} root
   * @param {ProjectFiles} fs
   * @param {ProjectOptions} options
   */
  constructor(root, fs, options) {
    this.root = root;
    this.#fs = fs;
    this.#options = options;
    this.scripts = new Scripts(fs);
  }

  /**
   * Lists the project, now: a listing under way is followed by another, for what changed
   * meanwhile, and this resolves once that one is done too. One that fails is said.
   * @returns {Promise<boolean>} whether it was listed
   */
  list() {
    if (this.#listing) {
      this.#again = true;
      return this.#listing;
    }
    this.#listing = (async () => {
      try {
        do {
          this.#again = false;
          this.entries = await listFolder(this.root, this.#fs);
        } while (this.#again);
        return true;
      } catch (error) {
        this.#options.onproblem(`${this.name} wasn't listed: ${errorText(error)}`);
        return false;
      } finally {
        this.#listing = null;
      }
    })();
    return this.#listing;
  }

  /** The project's own name: the folder's, or `the project` for a root. */
  get name() {
    return nameOf(this.root) || 'the project';
  }

  /** The entry at `path`, if the tree has one. @param {string} path */
  entryAt(path) {
    return this.entries.find((entry) => entry.path === path);
  }

  /**
   * Opens or closes the tree's folder at `path`.
   * @param {string} path
   * @param {boolean} open
   */
  toggle(path, open) {
    if (open) this.collapsed.delete(path);
    else this.collapsed.add(path);
  }

  /** Opens the folder at `path` in the tree, and the folders it is in. @param {string} path */
  reveal(path) {
    for (const folder of [path, ...foldersAbove(this.entries, path)]) this.collapsed.delete(folder);
  }

  /**
   * The folder an entry made from `entry`'s menu goes in: a folder's own, the one a file is in;
   * from none (the bar, the tree's own menu), the file open's, else the root.
   * @param {Entry | null} entry
   * @param {string | null} [openPath] the file open
   */
  folderFor(entry, openPath = null) {
    if (entry) return entry.kind === 'folder' ? entry.path : parentOf(entry.path);
    return openPath ? parentOf(openPath) : this.root;
  }

  /**
   * Starts a new entry's name in the tree, in the folder `dir`, shown open.
   * @param {'script' | 'folder'} kind
   * @param {string} dir
   */
  startNew(kind, dir) {
    this.reveal(dir);
    this.nameError = null;
    this.editing = { in: dir, kind };
  }

  /** @param {Entry} entry */
  startRename(entry) {
    this.nameError = null;
    this.editing = { path: entry.path };
  }

  cancelNaming() {
    this.editing = null;
  }

  /**
   * Makes the name given in the tree an entry: a new one, or a row's new name, the tree listed
   * again. One refused stays in the field, what is wrong with it said under it (`nameError`).
   * @param {string} given
   * @returns {Promise<{ made: Entry } | { renamed: { from: string, to: string } } | null>} what
   *   came of it: the entry made, or the paths renamed from and to; null for nothing
   */
  async commitName(given) {
    const now = this.editing;
    if (!now || this.#naming) return null;
    const wrong = nameProblem(given);
    if (wrong) {
      this.nameError = wrong;
      return null;
    }
    this.#naming = true;
    try {
      return 'in' in now
        ? await this.#make(now.in, now.kind, given)
        : await this.#rename(now.path, given);
    } catch (error) {
      this.nameError = errorText(error);
      return null;
    } finally {
      this.#naming = false;
    }
  }

  /**
   * @param {string} dir
   * @param {'script' | 'folder'} kind
   * @param {string} given
   */
  async #make(dir, kind, given) {
    const named = kind === 'script' ? scriptName(given) : given;
    const path = childPath(dir, named);
    if (await this.#fs.exists(path)) {
      this.nameError = `${named} is there already.`;
      return null;
    }
    if (kind === 'script') await this.#fs.write(path, '');
    else await this.#fs.mkdir(path);
    this.editing = null;
    await this.list();
    const depth = (this.entryAt(dir)?.depth ?? -1) + 1;
    // Listed, unless a folder watcher's listing raced it: then as it will be listed
    return { made: this.entryAt(path) ?? { kind, name: named, path, depth } };
  }

  /**
   * @param {string} from
   * @param {string} given
   */
  async #rename(from, given) {
    const entry = this.entryAt(from);
    const named = entry ? renamedName(entry, given) : given;
    const to = childPath(parentOf(from), named);
    const sameName = this.#options.ignoresCase && to.toLowerCase() === from.toLowerCase();
    if (!sameName && (await this.#fs.exists(to))) {
      this.nameError = `${named} is there already.`;
      return null;
    }
    this.#options.beforeRename?.();
    await this.#fs.rename(from, to);
    this.scripts.rename(from, to);
    // A copy: renaming adds to what is iterated
    for (const path of Array.from(this.collapsed)) {
      if (!within(path, from)) continue;
      this.collapsed.delete(path);
      this.collapsed.add(to + path.slice(from.length));
    }
    for (const path of Array.from(this.#saves.keys())) {
      if (!within(path, from)) continue;
      clearTimeout(this.#saves.get(path));
      this.#saves.delete(path);
    }
    this.editing = null;
    await this.list();
    return { renamed: { from, to } };
  }

  /**
   * Removes an entry (the host asked the person first): the scripts in it, unsaved changes and
   * all, are forgotten, and the tree listed again.
   * @param {Entry} entry
   * @returns {Promise<boolean>} whether it was removed
   */
  async remove(entry) {
    try {
      await this.#fs.remove(entry.path);
    } catch (error) {
      this.#options.onproblem(`${entry.name} wasn't removed: ${errorText(error)}`);
      return false;
    }
    this.forget(entry.path);
    await this.list();
    return true;
  }

  /**
   * Forgets what is held of the entries at or under `path`: the scripts, the folders closed, the
   * saves waiting. For one removed, or gone from the disk.
   * @param {string} path
   */
  forget(path) {
    this.scripts.drop(path);
    for (const folder of this.collapsed) if (within(folder, path)) this.collapsed.delete(folder);
    for (const [waiting, timer] of this.#saves) {
      if (!within(waiting, path)) continue;
      clearTimeout(timer);
      this.#saves.delete(waiting);
    }
  }

  /**
   * Puts files the person gave (dropped on the tree, picked to upload) in the folder `dir`,
   * asking about a name it has (`clash`: Replace, Rename, Cancel); those the tree wouldn't show
   * are said to be refused. The folder is shown open and the tree listed again where any was put.
   * @param {Iterable<File>} files
   * @param {string} dir
   * @param {(name: string, renamed: string, folder: string) => Promise<Clash> | Clash} clash
   * @returns {Promise<string[]>} the paths put
   */
  async addFiles(files, dir, clash) {
    const folder = dir === this.root ? this.name : nameOf(dir);
    let added;
    try {
      added = await putFiles(files, dir, {
        exists: (path) => this.#fs.exists(path),
        write: (path, bytes) => this.#fs.writeBytes(path, bytes),
        clash: (name, renamed) => clash(name, renamed, folder),
      });
    } catch (error) {
      this.#options.onproblem(`The files weren't added: ${errorText(error)}`);
      return [];
    }
    if (added.refused.length > 0) {
      this.#options.onproblem(
        `Not added, being no script or file a script reads: ${added.refused.join(', ')}`,
      );
    }
    if (added.put.length === 0) return [];
    this.reveal(dir);
    await this.list();
    return added.put;
  }

  /**
   * The person changed the script at `path` to `text`: held, and saved once it stays so for
   * `saveAfterMs` (the host's `onsave`).
   * @param {string} path
   * @param {string} text
   */
  edit(path, text) {
    this.scripts.edit(path, text);
    const after = this.#options.saveAfterMs?.() ?? null;
    clearTimeout(this.#saves.get(path));
    this.#saves.delete(path);
    if (after === null) return;
    this.#saves.set(
      path,
      setTimeout(() => {
        this.#saves.delete(path);
        this.#options.onsave(path);
      }, after),
    );
  }

  /** The save of `path` waiting, if one is, is off: the host saves it now. @param {string} path */
  saving(path) {
    clearTimeout(this.#saves.get(path));
    this.#saves.delete(path);
  }

  /** No save waits any more: the project is left. */
  dispose() {
    for (const timer of this.#saves.values()) clearTimeout(timer);
    this.#saves.clear();
  }
}
