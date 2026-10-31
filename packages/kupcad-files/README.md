# @kupcad/files

A KupCAD project's files as a tree, for any host of them: the desktop app's folder on the disk,
the browser IDE's in its private file system (OPFS). Svelte components and plain functions; the
host brings the file system.

```svelte
<script>
  import { ContextMenu, FileTree, listFolder, rowMenu } from '@kupcad/files';
  import '@kupcad/ui/tokens.css';

  let entries = $state(await listFolder('/', { readDir }));
</script>

<FileTree
  {entries}
  collapsed={new Set()}
  selected={null}
  unsaved={new Set()}
  root="/"
  onopen={(entry) => open(entry.path)}
  ontoggle={(folder, opening) => toggle(folder.path, opening)}
  onnew={(kind) => startNew(kind)}
/>
```

* **The tree** (`FileTree`): folders, scripts and the files they read, each under its folder, a
  folder opened and closed by a click or the arrow keys, the open script marked, and one with
  unsaved changes. Its bar has its title and the buttons that make a script and a folder
  (`onnew`; `keys` shows the host's shortcuts in their tooltips). A row's menu, and the tree's,
  are the host's (`onmenu`, with where to show it); F2 renames a row, Delete or ⌘⌫ removes it. A
  name being given (`editing`) is a field in the tree, what is wrong with it said under it
  (`problem`). It fills its box, its rows scrolling under the bar, in `@kupcad/ui`'s `--kc-*`
  tokens.
* **The rows' menu** (`rowMenu`): what a row, or the tree, offers, as data: New Script, New
  Folder, Rename…, and removing (`Delete…`, or the host's `Move to Trash`), with Upload Files…
  and a file's Download where the host gives them (a browser's). A desktop app draws it as a
  native menu; a page draws it with `ContextMenu`, a popover at the pointer that the arrow keys
  move through and Escape, a click elsewhere or the focus leaving close.
* **The folder** (`listFolder(root, { readDir })`; alone, without Svelte, from
  `@kupcad/files/tree`, for Node or a module no Svelte compiler sees): the tree of `root`, each
  folder's folders first, hidden folders, `node_modules` and `target` left out, and a folder
  holding files but no script or file a script reads (`kindOf`), at most `MAX_ENTRIES`. The
  names a new entry may take (`nameProblem`, `scriptName`), and paths in it (`childPath`,
  `parentOf`, `within`) with the host's separator, `/` or `\`.
* **The scripts read** (`Scripts`, over the host's `read`, `write` and `exists`): each one's text
  now and as the disk had it, for what is unsaved; a save that finds the disk changed since
  holds the disk's text as a conflict for the person to choose; each script's editor snapshot,
  its undo history, kept while another is shown.

* **Files given from outside** (`putFiles`): files dropped on the tree from the system's file
  manager (`FileTree`'s `ondropfiles`: a folder's row is that folder, a file's row its folder,
  elsewhere the root, marked while they are over it) or picked to upload, put in a folder through
  the host's `exists` and `write`. What the tree wouldn't show is refused; for a name the folder
  has, the person is asked (`clash`): Replace, Rename (the next free name, `lid 2.kup`) or Cancel,
  every question before anything is written. `clashQuestion` words it, which `AskDialog` (a
  page's modal dialog) asks as it is; a desktop asks with its own. `refuseStrayDrop`, on the
  window's `dragover` and `drop`, keeps a drop the page didn't take from opening the file in its
  place.

`pnpm test` runs its tests under jsdom (the popover and the modal dialog are stood in for,
`dom.test-helper.js`).
