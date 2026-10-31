// Files a person gives a project from outside it, dropped on the tree from the system's file
// manager or picked to upload: put in a folder of it through the host's file system. And what a
// page does with a drop of files that nothing in it takes.

import { childPath, kindOf, nameProblem } from './tree.js';

/**
 * What to do with a file given whose name one in the folder has: write over that one, put it in
 * under a free name, or put none of the files given.
 * @typedef {'replace' | 'rename' | 'cancel'} Clash
 */

/**
 * What a project's files are checked and written with, and the person asked.
 * @typedef {object} PutHost
 * @property {(path: string) => Promise<boolean>} exists
 * @property {(path: string, bytes: Uint8Array<ArrayBuffer>) => Promise<void>} write
 * @property {(name: string, renamed: string) => Promise<Clash> | Clash} clash what to do with the
 *   file `name`, which the folder has one of: `renamed` is the free name it would take
 */

/**
 * The question for a file given whose name the folder has, as AskDialog asks it (and a native
 * dialog may, its message the title and the text): Rename, the safe one, focused.
 * @param {string} name the file's
 * @param {string} renamed the free name it would take
 * @param {string} folder what the folder is called: its name, or `the project` for the root
 */
export function clashQuestion(name, renamed, folder) {
  return {
    title: `“${name}” is in ${folder} already`,
    text: `Replace it with yours, or add yours as “${renamed}”?`,
    answers: [
      { text: 'Cancel', value: 'cancel' },
      { text: 'Replace', value: 'replace' },
      { text: 'Rename', value: 'rename', primary: true },
    ],
    cancel: 'cancel',
  };
}

/**
 * Whether `event` drags files from outside the page (the system's file manager).
 * @param {DragEvent} event
 */
export function draggingFiles(event) {
  return event.dataTransfer?.types.includes('Files') ?? false;
}

/**
 * Refuses a drag of files over the page that nothing in it took (the tree takes one): dropped, a
 * browser would open the file in the page's place. For the window's `dragover` and `drop`.
 * @param {DragEvent} event
 */
export function refuseStrayDrop(event) {
  if (!draggingFiles(event) || event.defaultPrevented) return;
  event.preventDefault();
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'none';
}

/**
 * Puts `files` in the folder `dir`, each by its name: one the tree wouldn't show (no script, no
 * file a script reads, a name it refuses) is left out, and for one a file there has the name of,
 * the person is asked (`clash`) whether it replaces that one or takes a free name, or whether
 * none is put. Every question is asked before anything is written. A write that fails stops it,
 * failing.
 * @param {Iterable<File>} files
 * @param {string} dir
 * @param {PutHost} host
 * @returns {Promise<{ put: string[], refused: string[], cancelled: boolean }>} the paths written,
 *   the names left out, and whether the person put none
 */
export async function putFiles(files, dir, { exists, write, clash }) {
  /** @type {string[]} */
  const refused = [];
  /** @type {{ file: File, path: string }[]} */
  const planned = [];
  /** @param {string} name */
  const free = async (name) => {
    const path = childPath(dir, name);
    return !planned.some((put) => put.path === path) && !(await exists(path));
  };
  for (const file of files) {
    if (nameProblem(file.name) || !kindOf(file.name)) {
      refused.push(file.name);
      continue;
    }
    let name = file.name;
    if (!(await free(name))) {
      const renamed = await freeName(name, free);
      const choice = await clash(name, renamed);
      if (choice === 'cancel') return { put: [], refused, cancelled: true };
      if (choice === 'rename') name = renamed;
    }
    planned.push({ file, path: childPath(dir, name) });
  }
  for (const { file, path } of planned) await write(path, new Uint8Array(await file.arrayBuffer()));
  return { put: planned.map(({ path }) => path), refused, cancelled: false };
}

/**
 * The first free name of `name`'s with a number after its stem, as a file manager keeps both:
 * `lid 2.kup`, `lid 3.kup`; `lid 2.kup`'s is `lid 3.kup`.
 * @param {string} name
 * @param {(name: string) => Promise<boolean>} free
 */
export async function freeName(name, free) {
  const dot = name.lastIndexOf('.');
  const [stem, extension] = dot > 0 ? [name.slice(0, dot), name.slice(dot)] : [name, ''];
  const numbered = /^(.*) (\d+)$/.exec(stem);
  const base = numbered ? numbered[1] : stem;
  for (let n = numbered ? Number(numbered[2]) + 1 : 2; ; n++) {
    const candidate = `${base} ${n}${extension}`;
    if (await free(candidate)) return candidate;
  }
}
