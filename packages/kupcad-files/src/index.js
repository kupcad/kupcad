// @kupcad/files: a project's files as a tree, for any host of them (the desktop app's on the
// disk, the browser IDE's in its private file system): the tree (FileTree), its rows' menu
// (rowMenu, drawn by a host's native menu or by ContextMenu), the folder listed through the
// host's `readDir` and the paths and names in it (tree.js), the scripts read, their unsaved
// changes and undo histories (Scripts), and the files a person drops on the tree or uploads, put
// in a folder (putFiles), a name the folder has asked about (AskDialog, for a page). The folder
// alone, for a module that loads no Svelte (Node, a plain script), is `@kupcad/files/tree`.

export { default as AskDialog } from './AskDialog.svelte';
export { default as ConflictBar } from './ConflictBar.svelte';
export { default as ContextMenu } from './ContextMenu.svelte';
export { default as FileTree } from './FileTree.svelte';
export { clashQuestion, putFiles, refuseStrayDrop } from './drop.js';
export { rowMenu } from './menu.js';
export { Project } from './project.svelte.js';
export { Scripts } from './scripts.svelte.js';
export {
  childPath,
  DATA_EXTENSIONS,
  foldersAbove,
  kindOf,
  languageOf,
  listFolder,
  MAX_ENTRIES,
  nameOf,
  nameProblem,
  parentOf,
  renamedName,
  SCRIPT_EXTENSION,
  scriptName,
  SKIPPED_FOLDER,
  within,
} from './tree.js';

/** @typedef {import('./tree.js').Entry} Entry */
/** @typedef {import('./tree.js').DirEntry} DirEntry */
/** @typedef {import('./tree.js').DirReader} DirReader */
/** @typedef {import('./menu.js').MenuItem} MenuItem */
/** @typedef {import('./drop.js').Clash} Clash */
/** @typedef {import('./drop.js').PutHost} PutHost */
/** @typedef {import('./menu.js').RowActions} RowActions */
/** @typedef {import('./scripts.svelte.js').ScriptFiles} ScriptFiles */
/** @typedef {import('./project.svelte.js').ProjectFiles} ProjectFiles */
/** @typedef {import('./project.svelte.js').ProjectOptions} ProjectOptions */
/** @typedef {import('./project.svelte.js').Naming} Naming */
