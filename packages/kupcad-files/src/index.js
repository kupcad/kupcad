// @kupcad/files: a project's files as a tree, for any host of them (the desktop app's on the
// disk, the browser IDE's in its private file system): the tree (FileTree), its rows' menu
// (rowMenu, drawn by a host's native menu or by ContextMenu), the folder listed through the
// host's `readDir` and the paths and names in it (tree.js), and the scripts read, their unsaved
// changes and undo histories (Scripts).

export { default as ContextMenu } from './ContextMenu.svelte';
export { default as FileTree } from './FileTree.svelte';
export { rowMenu } from './menu.js';
export { Scripts } from './scripts.svelte.js';
export {
  childPath,
  DATA_EXTENSIONS,
  foldersAbove,
  kindOf,
  listFolder,
  MAX_ENTRIES,
  nameProblem,
  parentOf,
  SCRIPT_EXTENSION,
  scriptName,
  shownEntries,
  SKIPPED_FOLDER,
  within,
} from './tree.js';

/** @typedef {import('./tree.js').Entry} Entry */
/** @typedef {import('./tree.js').DirEntry} DirEntry */
/** @typedef {import('./tree.js').DirReader} DirReader */
/** @typedef {import('./menu.js').MenuItem} MenuItem */
/** @typedef {import('./menu.js').RowActions} RowActions */
/** @typedef {import('./scripts.svelte.js').ScriptFiles} ScriptFiles */
