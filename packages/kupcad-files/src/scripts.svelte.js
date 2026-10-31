// The scripts a host read, by their paths: each one's text now and as the disk (whatever keeps
// them) had it when it was last read or saved, for what is unsaved, and its editor's snapshot
// (its undo history) while another is shown. The disk is read again when the host says a file
// changed, or the window is back (`check`): a script with no unsaved changes takes the disk's
// text; one with them keeps its own, the disk's held as a conflict for the person to choose
// (`resolve`); one gone from the disk is dropped, or kept, unsaved, where it has changes. A save
// that finds the disk changed since writes nothing unless told to (`overwrite`): nothing
// someone else wrote is lost unasked.

import { SvelteMap } from 'svelte/reactivity';
import { within } from './tree.js';

/**
 * What the scripts are read and written with.
 * @typedef {object} ScriptFiles
 * @property {(path: string) => Promise<string>} read
 * @property {(path: string, text: string) => Promise<void>} write
 * @property {(path: string) => Promise<boolean>} exists
 */

/**
 * A script read: its text now, and the disk's when it was last read or saved (null: gone from
 * the disk since).
 * @typedef {{ text: string, saved: string | null }} Held
 */

export class Scripts {
  /** @type {SvelteMap<string, Held>} */
  #held = new SvelteMap();
  /**
   * The disk's text of each script it changed under unsaved changes (null: it was removed), until
   * the person chooses.
   * @type {SvelteMap<string, string | null>}
   */
  conflicts = new SvelteMap();
  /** Each script's editor as it was left, its undo history with it (Editor's `snapshot()`). */
  #snapshots = new Map();
  /** The paths being written: what the disk says of one meanwhile is the save's. */
  #writing = new Set();
  /** @type {ScriptFiles} */
  #files;

  /** The paths of the scripts whose text isn't the disk's. */
  unsaved = $derived(
    new Set([...this.#held].filter(([, held]) => held.text !== held.saved).map(([path]) => path)),
  );

  /** @param {ScriptFiles} files */
  constructor(files) {
    this.#files = files;
  }

  /** @param {string} path */
  has(path) {
    return this.#held.has(path);
  }

  /** The script's text now; none for one not read. @param {string} path */
  text(path) {
    return this.#held.get(path)?.text ?? '';
  }

  /**
   * The script at `path`, read from the disk unless it was: its text.
   * @param {string} path
   */
  async read(path) {
    if (!this.#held.has(path)) {
      const text = await this.#files.read(path);
      if (!this.#held.has(path)) this.#held.set(path, { text, saved: text });
    }
    return this.text(path);
  }

  /**
   * The person changed the script at `path` to `text`.
   * @param {string} path
   * @param {string} text
   */
  edit(path, text) {
    const held = this.#held.get(path);
    if (held) this.#held.set(path, { text, saved: held.saved });
  }

  /**
   * Writes the script at `path`; if the disk changed since it was read or saved, nothing unless
   * `overwrite`, the disk's text held as a conflict.
   * @param {string} path
   * @param {{ overwrite?: boolean }} [options]
   * @returns {Promise<'saved' | 'changed'>}
   */
  async save(path, { overwrite = false } = {}) {
    const held = this.#held.get(path);
    // Nothing to write where the disk has the text already
    if (!held || held.text === held.saved) return 'saved';
    const { text } = held;
    this.#writing.add(path);
    try {
      if (!overwrite && held.saved !== null) {
        const disk = await this.#onDisk(path);
        if (disk !== null && disk !== held.saved && disk !== text) {
          this.conflicts.set(path, disk);
          return 'changed';
        }
      }
      await this.#files.write(path, text);
    } finally {
      this.#writing.delete(path);
    }
    // What was typed while it was written stays, unsaved; a script dropped or renamed meanwhile
    // isn't brought back
    const now = this.#held.get(path);
    if (now) this.#held.set(path, { text: now.text, saved: text });
    this.conflicts.delete(path);
    return 'saved';
  }

  /**
   * Reads each script again as the disk has it now: a change of the disk's under none of the
   * person's is taken, under theirs held as a conflict; a script gone from the disk is dropped,
   * or kept, unsaved. One the disk can't be read for is left as it is.
   * @returns {Promise<string[]>} the paths dropped
   */
  async check() {
    /** @type {string[]} */
    const dropped = [];
    for (const path of this.#held.keys()) {
      if (this.#writing.has(path)) continue;
      let disk;
      try {
        disk = await this.#onDisk(path);
      } catch {
        continue;
      }
      const held = this.#held.get(path);
      if (!held || this.#writing.has(path) || disk === held.saved) continue;
      if (disk === null && held.text === held.saved) {
        this.drop(path);
        dropped.push(path);
      } else if (disk === null) {
        this.#held.set(path, { text: held.text, saved: null });
        this.conflicts.set(path, null);
      } else if (held.text === held.saved || held.text === disk) {
        this.#held.set(path, { text: disk, saved: disk });
        this.conflicts.delete(path);
      } else {
        this.conflicts.set(path, disk);
      }
    }
    return dropped;
  }

  /**
   * The person's choice for the script at `path`, which the disk changed under their changes:
   * the disk's text (for one removed, the script dropped), or theirs, which the next save writes
   * over the disk's (or back, for one removed).
   * @param {string} path
   * @param {'disk' | 'mine'} keep
   */
  resolve(path, keep) {
    const disk = this.conflicts.get(path);
    const held = this.#held.get(path);
    if (disk === undefined || !held) return;
    this.conflicts.delete(path);
    if (keep === 'mine') this.#held.set(path, { text: held.text, saved: disk });
    else if (disk === null) this.drop(path);
    else this.#held.set(path, { text: disk, saved: disk });
  }

  /**
   * Keeps the snapshot of the script's editor, its undo history with it, while another is shown.
   * @param {string} path
   * @param {unknown} snapshot
   */
  keep(path, snapshot) {
    this.#snapshots.set(path, snapshot);
  }

  /** The snapshot of the script's editor, as it was left; none for one not left. @param {string} path */
  snapshot(path) {
    return this.#snapshots.get(path);
  }

  /**
   * Moves what is held of the scripts at or under `from` to `to`, as the person renamed it.
   * @param {string} from
   * @param {string} to
   */
  rename(from, to) {
    for (const map of [this.#held, this.conflicts, this.#snapshots]) {
      // A copy: renaming adds to what is iterated
      for (const [path, value] of Array.from(map)) {
        if (!within(path, from)) continue;
        map.delete(path);
        map.set(to + path.slice(from.length), value);
      }
    }
  }

  /**
   * Forgets the scripts at or under `path`, unsaved changes and all.
   * @param {string} path
   */
  drop(path) {
    for (const map of [this.#held, this.conflicts, this.#snapshots]) {
      for (const held of map.keys()) if (within(held, path)) map.delete(held);
    }
  }

  /** Forgets every script: another folder is opened. */
  clear() {
    this.#held.clear();
    this.conflicts.clear();
    this.#snapshots.clear();
  }

  /**
   * The disk's text of `path`; null where it is gone.
   * @param {string} path
   */
  async #onDisk(path) {
    try {
      return await this.#files.read(path);
    } catch (error) {
      if (await this.#files.exists(path).catch(() => true)) throw error;
      return null;
    }
  }
}
