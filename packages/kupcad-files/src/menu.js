// The menu of a row of a project's tree, and of the tree itself, as data a host draws: as a
// native menu (the desktop app's), or as a page's (ContextMenu.svelte).

/** @import { Entry } from './tree.js' */

/**
 * An item of a menu: what it says and does, or a separator.
 * @typedef {{ text: string, action: () => void } | '-'} MenuItem
 */

/**
 * What a row's menu does. Uploading and downloading are a browser's: its files are in no folder
 * of the person's own.
 * @typedef {object} RowActions
 * @property {() => void} newScript
 * @property {() => void} newFolder
 * @property {() => void} rename
 * @property {() => void} remove
 * @property {() => void} [upload] puts the person's files in the row's folder
 * @property {() => void} [download] saves the row's file to the person's
 */

/** @param {string} text @param {() => void} action @returns {MenuItem} */
const item = (text, action) => ({ text, action });

/**
 * The menu of a row of the tree (`entry`), or of the tree itself (none): what can be made in
 * its folder, and what can be done to it (a folder isn't downloaded).
 * @param {Entry | null} entry
 * @param {RowActions} actions
 * @param {{ remove?: string }} [labels] what removing says: Move to Trash where the system has one
 * @returns {MenuItem[]}
 */
export function rowMenu(entry, actions, { remove = 'Delete…' } = {}) {
  const make = [item('New Script', actions.newScript), item('New Folder', actions.newFolder)];
  if (actions.upload) make.push(item('Upload Files…', actions.upload));
  if (!entry) return make;
  const download =
    actions.download && entry.kind !== 'folder' ? [item('Download', actions.download)] : [];
  return [...make, '-', ...download, item('Rename…', actions.rename), item(remove, actions.remove)];
}
