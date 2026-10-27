<!--
  @component
  The app's window: the folder opened, its files beside the script open in the editor, and the
  script's preview, its parameters with it. The editor and the preview run on the bundled
  kupcad's language server, started for the folder. The folder's tree follows what is made,
  removed or renamed in it, and its closed folders stay closed until a script in one is opened;
  in it the person makes scripts and folders, renames them and moves them to the trash (its
  rows' menus, the File menu). A script read is read again when the disk changes it (scripts.svelte.js):
  one with no unsaved changes follows the disk, one with them says so above the editor, for
  the person to choose; a save never writes over what someone else wrote unasked. Each script
  keeps its undo history while another is shown. A script is saved with ⌘S (Ctrl+S), or a
  moment after each change where the settings say; the window asks before it closes on unsaved
  changes. The bars between the panes resize them, the sizes kept in the app's settings
  (`settings`), with the theme, the zoom, the editor's font size and the folders opened last,
  the last opened again at the start. The strip at the window's left edge shows or hides the
  files, and opens the app's settings (⌘, or Ctrl+, too): a page over the workspace, which stays
  as it was under it, out of reach until Escape, the page's close button or the strip gives it
  back. The app's menu bar is the window's (menu.js), its shortcuts listed in a dialog (Help).
-->
<script>
  import { Editor } from '@kupcad/editor/svelte';
  import { errorText } from '@kupcad/protocol';
  import {
    memorySettings,
    PreviewPanel,
    ShortcutsDialog,
    sizeSetting,
    Splitter,
    VIEWER_SHORTCUTS,
  } from '@kupcad/ui';
  import { onMount, tick } from 'svelte';
  import { SvelteSet } from 'svelte/reactivity';
  import FileTree from './FileTree.svelte';
  import {
    childPath,
    fileUri,
    foldersAbove,
    nameProblem,
    parentOf,
    scriptName,
    within,
  } from './folder.js';
  import { createHost } from './host.js';
  import { menuBar, rowMenu } from './menu.js';
  import { fontSizeOf, KEYS, recentOf, withRecent, zoomOf, zoomStep } from './prefs.js';
  import { Scripts } from './scripts.svelte.js';
  import SettingsPane from './SettingsPane.svelte';
  import { themeOf } from './theme.js';

  /** @import { Editor as ScriptEditor } from '@kupcad/editor' */
  /** @import { Entry } from './folder.js' */
  /** @import { Settings, ShortcutGroup } from '@kupcad/ui' */
  /** @import { Platform } from './platform.js' */

  /**
   * @typedef {object} Props
   * @property {Platform} platform what the window does its work with
   * @property {import('@kupcad/ui/viewer/types').ViewerOptions} [viewerOptions] what the
   *   preview's viewer is made with
   * @property {Settings} [settings] where the panes' sizes are kept (the app's settings file)
   */

  /** @type {Props} */
  let { platform, viewerOptions = {}, settings = memorySettings() } = $props();

  /** How long a script changed waits to be saved, where the settings say it is, in milliseconds. */
  const AUTOSAVE_MS = 1000;
  const MAC = globalThis.navigator?.userAgent.includes('Mac') ?? false;
  /** The shortcuts' key as this system names it, in the strip's tooltips. */
  const MOD = MAC ? '⌘' : 'Ctrl+';
  /** Where a file moved away goes. */
  const TRASH = globalThis.navigator?.userAgent.includes('Windows') ? 'Recycle Bin' : 'Trash';

  // As the settings have them; a size dragged is the pane's own until the drag is done
  let filesWidth = $derived(sizeSetting(settings, KEYS.files, 224));
  let editorWidth = $derived(sizeSetting(settings, KEYS.editor, 520));
  const theme = $derived(themeOf(settings.get(KEYS.theme)));
  const showsConsole = $derived(settings.get(KEYS.console) !== false);
  const zoom = $derived(zoomOf(settings.get(KEYS.zoom)));
  const fontSize = $derived(fontSizeOf(settings.get(KEYS.fontSize)));
  const autosave = $derived(settings.get(KEYS.autosave) === true);
  const recent = $derived(recentOf(settings.get(KEYS.recent)));
  /** The tree's closed folders, by their paths: none in a folder just opened. */
  const collapsed = new SvelteSet();

  /** The folder open, by its path. */
  let folder = $state(/** @type {string | null} */ (null));
  /** How many folders were opened: what a listing or a watcher of an earlier one checks. */
  let opened = 0;
  /** Stops watching the folder open. */
  let unwatch = /** @type {(() => void) | null} */ (null);
  let entries = $state(/** @type {Entry[]} */ ([]));
  /** The script open in the editor. */
  let open = $state(/** @type {{ path: string, name: string, uri: string } | null} */ (null));
  /** The scripts read: their texts, what is unsaved, what the disk changed under them. */
  const scripts = new Scripts({
    read: (path) => platform.files.read(path),
    write: (path, text) => platform.files.write(path, text),
    exists: (path) => platform.files.exists(path),
  });
  /** What the disk did to the script open under its unsaved changes, if anything. */
  const conflict = $derived(open ? scripts.conflicts.get(open.path) : undefined);
  let server = $state(/** @type {ReturnType<Platform['server']> | null} */ (null));
  let viewportUrl = $state(/** @type {string | null} */ (null));
  let running = $state(false);
  let editor = $state(/** @type {ScriptEditor | null} */ (null));
  /** What went wrong last, shown in the bar until something else does. */
  let problem = $state('');

  /** A name being given in the tree, and what is wrong with the last one given. */
  let editing = $state(
    /** @type {{ path: string } | { in: string, kind: 'script' | 'folder' } | null} */ (null),
  );
  let nameError = $state(/** @type {string | null} */ (null));
  /** A name given is being made into an entry: one given again meanwhile is the same. */
  let naming = false;
  /** Each script changed that waits to be saved, by its path. */
  const autosaves = new Map();

  /** Whether the files show beside the editor: none before a folder is opened. */
  let showsFiles = $state(true);
  const filesShown = $derived(showsFiles && folder !== null);
  /** Whether the settings show, over the workspace. */
  let settingsOpen = $state(false);
  /** What had the focus before the settings opened, given it back when they close. */
  let focusBefore = /** @type {HTMLElement | null} */ (null);
  let page = $state(/** @type {HTMLElement | null} */ (null));
  let settingsButton = $state(/** @type {HTMLButtonElement | null} */ (null));
  let shortcutsOpen = $state(false);

  /** A shortcut as this system writes it: ⇧⌘N on a Mac, Ctrl+Shift+N elsewhere. */
  const combo = (/** @type {string} */ key, shift = false) =>
    MAC ? `${shift ? '⇧' : ''}⌘${key}` : `Ctrl+${shift ? 'Shift+' : ''}${key}`;
  /** @type {ShortcutGroup[]} */
  const SHORTCUTS = [
    {
      title: 'KupCAD',
      keys: [
        [combo('S'), 'Save the script'],
        [combo('N'), 'New script'],
        [combo('N', true), 'New folder'],
        [combo('O'), 'Open a folder'],
        [combo('B'), 'Show or hide the files'],
        [combo(','), 'Settings'],
        [`${combo('=')} / ${combo('-')}`, 'Zoom in / out'],
        ['Esc', 'Close the settings'],
      ],
    },
    {
      title: 'Files',
      keys: [
        ['↑ ↓', 'Move between the rows'],
        ['→ ←', 'Open or close a folder'],
        ['F2', 'Rename'],
        [`Delete, ${combo('⌫')}`, `Move to the ${TRASH}`],
        ['Shift+F10', "The row's menu"],
      ],
    },
    {
      title: 'Editor',
      keys: [
        [combo('F'), 'Find'],
        [combo('Z'), 'Undo'],
        [combo('Z', true), 'Redo'],
        ['Tab', 'Indent'],
      ],
    },
  ];

  const preview = createHost({
    server: {
      preview: (uri) => (server ? server.preview(uri) : Promise.resolve()),
      setParams: (uri, values) => (server ? server.setParams(uri, values) : Promise.resolve()),
    },
    save: (options) => platform.save(options),
    tell: (text) => platform.tell(text),
    exportModel: (...args) => platform.exportModel(...args),
    writeFile: (path, bytes) => platform.writeFile(path, bytes),
    reveal: (uri, line, column) => void reveal(uri, line, column),
    log: (text) => (problem = text),
  });

  const name = (/** @type {string} */ path) => path.split(/[\\/]/).at(-1) ?? path;

  /**
   * Opens a folder, kept as the last opened; one that can't be listed leaves the window as it was.
   * @param {string | null} [named] the folder, else the one the person picks
   */
  async function openFolder(named) {
    const picked = named ?? (await platform.pickFolder());
    if (!picked) return;
    if (
      scripts.unsaved.size > 0 &&
      !(await platform.confirm('Leave this folder without saving?'))
    ) {
      return;
    }
    let listed;
    try {
      listed = await platform.listFolder(picked);
    } catch (error) {
      problem = `${name(picked)} wasn't opened: ${errorText(error)}`;
      return;
    }
    const mine = ++opened;
    unwatch?.();
    unwatch = null;
    stopAutosaves();
    await server?.stop();
    scripts.clear();
    collapsed.clear();
    editing = null;
    open = null;
    preview.show(null);
    problem = '';
    folder = picked;
    showsFiles = true;
    entries = listed;
    settings.set(KEYS.folder, picked);
    settings.set(KEYS.recent, withRecent(recent, picked));
    const relist = listAgain(picked, mine);
    platform
      .watchFolder(picked, ({ tree }) => {
        if (tree) void relist();
        void checkDisk(mine);
      })
      .then((stop) => {
        if (mine === opened) unwatch = stop;
        else stop();
      })
      .catch((error) => (problem = `${name(picked)} isn't watched: ${errorText(error)}`));
    const started = platform.server(fileUri(picked), {
      viewport: (url) => (viewportUrl = url),
      state: (up) => (running = up),
      log: (text) => preview.log(text),
    });
    server = started;
    try {
      await started.start();
    } catch (error) {
      problem = `kupcad didn't start: ${errorText(error)}`;
    }
    const first = entries.find((entry) => entry.kind === 'script');
    if (first) await openScript(first);
  }

  /**
   * What lists the folder `root` again when the watcher says its tree changed: one listing at a
   * time, another after it for what changed meanwhile, none once another folder is opened.
   * @param {string} root
   * @param {number} mine which folder opened it was
   */
  function listAgain(root, mine) {
    let listing = false;
    let again = false;
    return async () => {
      if (listing) {
        again = true;
        return;
      }
      listing = true;
      try {
        do {
          again = false;
          const listed = await platform.listFolder(root);
          if (mine !== opened) return;
          entries = listed;
        } while (again);
      } catch (error) {
        if (mine === opened) problem = `${name(root)} wasn't listed again: ${errorText(error)}`;
      } finally {
        listing = false;
      }
    };
  }

  /** Lists the folder open again now: an entry was made, renamed or moved away. */
  async function listNow() {
    if (!folder) return;
    const mine = opened;
    try {
      const listed = await platform.listFolder(folder);
      if (mine === opened) entries = listed;
    } catch (error) {
      if (mine === opened) problem = `${name(folder)} wasn't listed again: ${errorText(error)}`;
    }
  }

  /**
   * Reads the scripts again as the disk has them (a file in the folder written, the window
   * back); the one open, gone from the disk with nothing unsaved, is closed.
   * @param {number} [mine] which folder opened it was
   */
  async function checkDisk(mine = opened) {
    if (mine !== opened) return;
    const dropped = await scripts.check();
    if (mine !== opened || !open || !dropped.includes(open.path)) return;
    problem = `${open.name} was removed from the disk.`;
    closeScript();
  }

  /**
   * Opens or closes the tree's folder at `path`.
   * @param {string} path
   * @param {boolean} opening
   */
  function toggle(path, opening) {
    if (opening) collapsed.delete(path);
    else collapsed.add(path);
  }

  /** @param {Entry} entry */
  async function openScript(entry) {
    try {
      await scripts.read(entry.path);
    } catch (error) {
      problem = `${entry.name} wasn't read: ${errorText(error)}`;
      return;
    }
    keepEditor();
    open = { path: entry.path, name: entry.name, uri: fileUri(entry.path) };
    // Shown in the tree: the folders it is in open
    for (const path of foldersAbove(entries, entry.path)) collapsed.delete(path);
    preview.show(open);
  }

  /** Keeps the editor of the script open as it is, its undo history with it, for its return. */
  function keepEditor() {
    if (open && editor) scripts.keep(open.path, editor.snapshot());
  }

  function closeScript() {
    open = null;
    preview.show(null);
  }

  /** @param {string} text */
  function edited(text) {
    if (!open) return;
    const { path } = open;
    scripts.edit(path, text);
    if (!autosave) return;
    clearTimeout(autosaves.get(path));
    autosaves.set(
      path,
      setTimeout(() => {
        autosaves.delete(path);
        void saveScript(path, { quiet: true });
      }, AUTOSAVE_MS),
    );
  }

  function stopAutosaves() {
    for (const timer of autosaves.values()) clearTimeout(timer);
    autosaves.clear();
  }

  /**
   * Saves a script, the one open by default. Where the disk changed since it was read, the
   * person is asked before it is written over; saved by itself (`quiet`), it isn't, and the
   * change is said above the editor instead.
   * @param {string | undefined} [path]
   * @param {{ quiet?: boolean }} [options]
   */
  async function saveScript(path = open?.path, { quiet = false } = {}) {
    if (!path || !scripts.has(path)) return;
    clearTimeout(autosaves.get(path));
    autosaves.delete(path);
    try {
      if ((await scripts.save(path)) === 'saved' || quiet) return;
      const question = `${name(path)} changed on disk since it was opened. Save yours over it?`;
      if (await platform.confirm(question)) await scripts.save(path, { overwrite: true });
    } catch (error) {
      problem = `${name(path)} wasn't saved: ${errorText(error)}`;
    }
  }

  /**
   * The person's choice for the script open, which the disk changed under their changes.
   * @param {'disk' | 'mine'} keep
   */
  function resolveConflict(keep) {
    if (!open) return;
    scripts.resolve(open.path, keep);
    if (!scripts.has(open.path)) closeScript();
  }

  /**
   * Shows a script at a place its run named, opening it first if another is open.
   * @param {string} uri
   * @param {number} line
   * @param {number} column
   */
  async function reveal(uri, line, column) {
    if (open?.uri !== uri) {
      const entry = entries.find((candidate) => fileUri(candidate.path) === uri);
      if (!entry) return;
      await openScript(entry);
      await tick();
    }
    editor?.reveal(line, column);
  }

  /**
   * Starts a new entry's name in the tree: in the folder of `entry` (a folder's own, else the one
   * it is in), or, for none, the open script's, else the folder opened.
   * @param {'script' | 'folder'} kind
   * @param {Entry | null} [entry]
   */
  function startNew(kind, entry = null) {
    if (!folder) return;
    let dir = folder;
    if (entry) dir = entry.kind === 'folder' ? entry.path : parentOf(entry.path);
    else if (open) dir = parentOf(open.path);
    collapsed.delete(dir);
    for (const path of foldersAbove(entries, dir)) collapsed.delete(path);
    if (settingsOpen) void closeSettings();
    showsFiles = true;
    nameError = null;
    editing = { in: dir, kind };
  }

  /** @param {Entry} entry */
  function startRename(entry) {
    if (settingsOpen) void closeSettings();
    showsFiles = true;
    nameError = null;
    editing = { path: entry.path };
  }

  /**
   * Makes the name given in the tree an entry: a new one, or a row's new name. One refused stays
   * in the field, what is wrong with it said under it.
   * @param {string} given
   */
  async function commitName(given) {
    const now = editing;
    if (!now || !folder || naming) return;
    const wrong = nameProblem(given);
    if (wrong) {
      nameError = wrong;
      return;
    }
    naming = true;
    try {
      if ('in' in now) await makeEntry(now.in, now.kind, given);
      else await renameEntry(now.path, given);
    } catch (error) {
      nameError = errorText(error);
    } finally {
      naming = false;
    }
  }

  /**
   * @param {string} dir
   * @param {'script' | 'folder'} kind
   * @param {string} given
   */
  async function makeEntry(dir, kind, given) {
    const named = kind === 'script' ? scriptName(given) : given;
    const path = childPath(dir, named);
    if (await platform.files.exists(path)) {
      nameError = `${named} is there already.`;
      return;
    }
    if (kind === 'script') await platform.files.write(path, '');
    else await platform.files.mkdir(path);
    editing = null;
    await listNow();
    if (kind !== 'script') return;
    const depth = (entries.find((entry) => entry.path === dir)?.depth ?? -1) + 1;
    await openScript(
      entries.find((entry) => entry.path === path) ?? { kind, name: named, path, depth },
    );
    await tick();
    editor?.focus();
  }

  /**
   * @param {string} from
   * @param {string} given
   */
  async function renameEntry(from, given) {
    const kind = entries.find((entry) => entry.path === from)?.kind;
    const named = kind === 'script' ? scriptName(given) : given;
    const to = childPath(parentOf(from), named);
    // Only its case changed: the same file to a system that ignores case
    if (to.toLowerCase() !== from.toLowerCase() && (await platform.files.exists(to))) {
      nameError = `${named} is there already.`;
      return;
    }
    keepEditor();
    await platform.files.rename(from, to);
    scripts.rename(from, to);
    // A copy: renaming adds to what is iterated
    for (const path of Array.from(collapsed)) {
      if (!within(path, from)) continue;
      collapsed.delete(path);
      collapsed.add(to + path.slice(from.length));
    }
    if (open && within(open.path, from)) {
      const path = to + open.path.slice(from.length);
      open = { path, name: name(path), uri: fileUri(path) };
      preview.show(open);
    }
    editing = null;
    await listNow();
  }

  /**
   * Moves an entry to the system's trash, once the person says so; the scripts in it, unsaved
   * changes and all, are closed.
   * @param {Entry} entry
   */
  async function trashEntry(entry) {
    const lost = [...scripts.unsaved].some((path) => within(path, entry.path));
    const what =
      entry.kind === 'folder'
        ? `the folder “${entry.name}” and everything in it`
        : `“${entry.name}”`;
    const question = `Move ${what} to the ${TRASH}?${lost ? ' Its unsaved changes are lost.' : ''}`;
    if (!(await platform.confirm(question))) return;
    try {
      await platform.trash(entry.path);
    } catch (error) {
      problem = `${entry.name} wasn't moved to the ${TRASH}: ${errorText(error)}`;
      return;
    }
    scripts.drop(entry.path);
    for (const path of collapsed) if (within(path, entry.path)) collapsed.delete(path);
    if (open && within(open.path, entry.path)) closeScript();
    await listNow();
  }

  /**
   * The menu of a row of the tree, or of the tree itself (null), where the pointer is.
   * @param {Entry | null} entry
   */
  function rowMenuOf(entry) {
    const menu = rowMenu(
      entry,
      {
        newScript: () => startNew('script', entry),
        newFolder: () => startNew('folder', entry),
        rename: () => entry && startRename(entry),
        trash: () => entry && void trashEntry(entry),
      },
      TRASH,
    );
    platform.popupMenu(menu).catch((error) => (problem = errorText(error)));
  }

  /** Shows the files or hides them; over the settings, shows them as it closes the settings. */
  function toggleFiles() {
    if (settingsOpen) {
      showsFiles = true;
      void closeSettings();
    } else showsFiles = !showsFiles;
  }

  function toggleSettings() {
    void (settingsOpen ? closeSettings() : openSettings());
  }

  /** Opens the settings over the workspace, the theme chosen focused. */
  async function openSettings() {
    if (!settingsOpen) {
      const active = document.activeElement;
      focusBefore = active instanceof HTMLElement && active !== document.body ? active : null;
      settingsOpen = true;
    }
    await tick();
    /** @type {HTMLInputElement | null | undefined} */ (
      page?.querySelector('input:checked')
    )?.focus();
  }

  /** Gives the workspace back, the focus where it was (else on the button that opens them). */
  async function closeSettings() {
    settingsOpen = false;
    await tick();
    const back = focusBefore?.isConnected ? focusBefore : settingsButton;
    focusBefore = null;
    back?.focus();
  }

  /** Whether the window was given a theme: until it is, the system's is its own. */
  let themed = false;
  // The window's theme as the settings have it, set again whenever they change it
  $effect(() => {
    const wanted = theme;
    if (wanted === 'system' && !themed) return;
    themed = true;
    platform
      .setTheme(wanted)
      .catch((error) => (problem = `The theme wasn't set: ${errorText(error)}`));
  });

  /** Whether the window was zoomed: until it is, it is drawn at its own size. */
  let zoomed = false;
  // The window's zoom as the settings have it
  $effect(() => {
    const wanted = zoom;
    if (wanted === 1 && !zoomed) return;
    zoomed = true;
    platform
      .setZoom(wanted)
      .catch((error) => (problem = `The zoom wasn't set: ${errorText(error)}`));
  });

  /** @type {import('./menu.js').MenuActions} */
  const menuActions = {
    newScript: () => startNew('script'),
    newFolder: () => startNew('folder'),
    openFolder: () => void openFolder(),
    openRecent: (path) => void openFolder(path),
    clearRecent: () => settings.set(KEYS.recent, []),
    save: () => void saveScript(),
    settings: () => void openSettings(),
    toggleFiles,
    zoomIn: () => settings.set(KEYS.zoom, zoomStep(zoom, 1)),
    zoomOut: () => settings.set(KEYS.zoom, zoomStep(zoom, -1)),
    zoomReset: () => settings.set(KEYS.zoom, 1),
    shortcuts: () => (shortcutsOpen = true),
  };
  // The menu bar as the window is: what it may do now, the folders opened last
  $effect(() => {
    const menus = menuBar(
      {
        mac: MAC,
        folder: folder !== null,
        canSave: open !== null && scripts.unsaved.has(open.path),
        filesShown,
        recent,
      },
      menuActions,
    );
    platform
      .setMenu(menus)
      .catch((error) => (problem = `The menu wasn't set: ${errorText(error)}`));
  });

  /** @param {KeyboardEvent} event */
  function keydown(event) {
    const command = event.metaKey || event.ctrlKey;
    if (command && event.key === 's') {
      event.preventDefault();
      void saveScript();
    } else if (command && event.key === ',') {
      event.preventDefault();
      void openSettings();
    } else if (event.key === 'Escape' && settingsOpen) {
      // Wherever the focus is: the workspace under them, the editor too, is out of its reach
      void closeSettings();
    }
  }

  onMount(() => {
    const closing = platform.onClose(async () =>
      scripts.unsaved.size === 0 ? true : platform.confirm('Close without saving your changes?'),
    );
    platform
      .launchFolder()
      .then(async (named) => {
        // Else the last one, where the settings say so
        const last = settings.get(KEYS.reopen) === false ? null : settings.get(KEYS.folder);
        const chosen = named ?? (typeof last === 'string' ? last : null);
        if (chosen) await openFolder(chosen);
      })
      .catch((error) => (problem = errorText(error)));
    return () => {
      opened++;
      unwatch?.();
      stopAutosaves();
      void closing.then((stop) => stop());
      void server?.stop();
    };
  });
</script>

<svelte:window onkeydown={keydown} onfocus={() => void checkDisk()} />

<div class="kc-desktop" style:--kc-code-font-size="{fontSize}px">
  <nav class="rail" aria-label="Views">
    <button
      type="button"
      aria-label="Files"
      title="Files ({combo('B')})"
      aria-pressed={filesShown && !settingsOpen}
      disabled={!folder}
      onclick={toggleFiles}
    >
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="M5 17V4.5A1.5 1.5 0 0 1 6.5 3H14" />
        <path d="M9 7h6l4 4v8.5a1.5 1.5 0 0 1-1.5 1.5h-7A1.5 1.5 0 0 1 9 19.5z" />
        <path d="M15 7v4h4" />
      </svg>
    </button>
    <button
      type="button"
      class="settings"
      aria-label="Settings"
      title="Settings ({MOD},)"
      aria-pressed={settingsOpen}
      onclick={toggleSettings}
      bind:this={settingsButton}
    >
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path
          d="M13.06 4.88L14.22 2.76L16.96 3.9L16.28 6.21L17.79 7.72L20.1 7.04L21.24 9.78L19.12 10.94L19.12 13.06L21.24 14.22L20.1 16.96L17.79 16.28L16.28 17.79L16.96 20.1L14.22 21.24L13.06 19.12L10.94 19.12L9.78 21.24L7.04 20.1L7.72 17.79L6.21 16.28L3.9 16.96L2.76 14.22L4.88 13.06L4.88 10.94L2.76 9.78L3.9 7.04L6.21 7.72L7.72 6.21L7.04 3.9L9.78 2.76L10.94 4.88Z"
        />
        <circle cx="12" cy="12" r="3" />
      </svg>
    </button>
  </nav>
  <div class="main">
    {#if folder}
      <header class="bar" inert={settingsOpen}>
        <button type="button" class="kc-control" onclick={() => openFolder()}>Open folder…</button>
        <span class="folder" title={folder}>{name(folder)}</span>
        {#if open}
          <span class="script">{open.name}{scripts.unsaved.has(open.path) ? ' ●' : ''}</span>
          <button
            type="button"
            class="kc-control kc-primary"
            disabled={!scripts.unsaved.has(open.path)}
            onclick={() => saveScript()}
          >
            Save
          </button>
        {/if}
        <span class="status" role="status">
          {#if problem}{problem}{:else if !running}Starting kupcad…{/if}
        </span>
      </header>
    {/if}
    <div class="body" inert={settingsOpen}>
      {#if filesShown && folder}
        <nav class="side" aria-label="Files" style:width="{filesWidth}px">
          <div class="side-bar">
            <span class="side-title">Files</span>
            <button
              type="button"
              class="side-action"
              aria-label="New script"
              title="New script ({combo('N')})"
              onclick={() => startNew('script')}
            >
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M7 3.5h7l4 4v13H7z" />
                <path d="M14 3.5v4h4M12.5 11v6M9.5 14h6" />
              </svg>
            </button>
            <button
              type="button"
              class="side-action"
              aria-label="New folder"
              title="New folder ({combo('N', true)})"
              onclick={() => startNew('folder')}
            >
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M3.5 6.5h6l2 2h9v11h-17z" />
                <path d="M12 11v6M9 14h6" />
              </svg>
            </button>
          </div>
          <FileTree
            {entries}
            {collapsed}
            selected={open?.path ?? null}
            unsaved={scripts.unsaved}
            root={folder}
            {editing}
            problem={nameError}
            onopen={openScript}
            ontoggle={(entry, opening) => toggle(entry.path, opening)}
            oncommit={(given) => void commitName(given)}
            oncancel={() => (editing = null)}
            onmenu={rowMenuOf}
            onrename={startRename}
            ontrash={(entry) => void trashEntry(entry)}
          />
        </nav>
        <Splitter
          bind:size={filesWidth}
          min={140}
          max={480}
          label="Resize the files"
          onchange={(size) => settings.set(KEYS.files, size)}
        />
      {/if}
      {#if folder}
        <section class="code" aria-label="Script" style:width="{editorWidth}px">
          {#if open && conflict !== undefined}
            <div class="conflict" role="alert">
              {#if conflict === null}
                <span>{open.name} was removed from the disk. Saving puts it back.</span>
                <button type="button" class="kc-control" onclick={() => resolveConflict('disk')}>
                  Discard mine
                </button>
              {:else}
                <span>{open.name} changed on disk.</span>
                <button type="button" class="kc-control" onclick={() => resolveConflict('disk')}>
                  Load from disk
                </button>
              {/if}
              <button type="button" class="kc-control" onclick={() => resolveConflict('mine')}>
                Keep mine
              </button>
            </div>
          {/if}
          {#if open && server}
            <div class="editor">
              {#key open.path}
                <Editor
                  value={scripts.text(open.path)}
                  label={open.name}
                  languageServer={{ client: server.client, uri: open.uri }}
                  restore={scripts.snapshot(open.path)}
                  onchange={edited}
                  bind:editor
                />
              {/key}
            </div>
          {:else}
            <p class="empty">Open a script from the folder.</p>
          {/if}
        </section>
        <Splitter
          bind:size={editorWidth}
          min={280}
          label="Resize the script"
          onchange={(size) => settings.set(KEYS.editor, size)}
        />
        <section class="preview" aria-label="Preview">
          <PreviewPanel
            host={preview.host}
            {viewportUrl}
            {viewerOptions}
            {settings}
            presets={false}
            console={showsConsole}
            shortcuts={SHORTCUTS}
            bind:shortcutsOpen
          />
        </section>
      {:else}
        <div class="welcome">
          <h1>KupCAD</h1>
          <p>Open a folder of scripts: they are edited here, and their models shown beside them.</p>
          <button type="button" class="kc-control kc-primary" onclick={() => openFolder()}>
            Open folder…
          </button>
          {#if problem}<p class="problem" role="status">{problem}</p>{/if}
          {#if recent.length > 0}
            <section class="recent" aria-labelledby="recent-title">
              <h2 id="recent-title">Recent</h2>
              <ul>
                {#each recent as path (path)}
                  <li>
                    <button type="button" title={path} onclick={() => openFolder(path)}>
                      <span class="recent-name">{name(path)}</span>
                      <span class="recent-path">{path}</span>
                    </button>
                  </li>
                {/each}
              </ul>
            </section>
          {/if}
        </div>
        <ShortcutsDialog groups={[...SHORTCUTS, VIEWER_SHORTCUTS]} bind:open={shortcutsOpen} />
      {/if}
    </div>
    {#if settingsOpen}
      <div class="settings-page" role="dialog" aria-label="Settings" bind:this={page}>
        <SettingsPane {settings} onclose={closeSettings} />
      </div>
    {/if}
  </div>
</div>

<style>
  .kc-desktop {
    display: flex;
    height: 100%;
    color: var(--kc-fg);
    background: var(--kc-bg);
  }
  /* The strip: the files' toggle, and the settings at its foot */
  .rail {
    flex: none;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
    width: 44px;
    padding: 6px 0;
    background: var(--kc-section-bg);
    border-right: 1px solid var(--kc-border);
  }
  .rail button,
  .side-action {
    position: relative;
    display: grid;
    place-items: center;
    width: 36px;
    height: 36px;
    padding: 0;
    color: var(--kc-muted);
    background: none;
    border: none;
    border-radius: var(--kc-radius);
    cursor: pointer;
  }
  .rail button:hover:not(:disabled),
  .side-action:hover {
    color: var(--kc-fg);
    background: var(--kc-hover);
  }
  .rail button:focus-visible,
  .side-action:focus-visible {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .rail button:disabled {
    opacity: 0.4;
    cursor: default;
  }
  /* What shows: its icon in the text's colour, the accent a bar at the strip's edge */
  .rail button[aria-pressed='true'] {
    color: var(--kc-fg);
  }
  .rail button[aria-pressed='true']::before {
    content: '';
    position: absolute;
    top: 6px;
    bottom: 6px;
    left: -4px;
    width: 2px;
    border-radius: 1px;
    background: var(--kc-accent);
  }
  .rail .settings {
    margin-top: auto;
  }
  .rail svg,
  .side-action svg {
    width: 22px;
    height: 22px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.5;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  .main {
    position: relative;
    display: flex;
    flex: 1;
    flex-direction: column;
    min-width: 0;
  }
  /* Over the workspace, which stays as it is under it: above its splitters' handles too */
  .settings-page {
    position: absolute;
    inset: 0;
    z-index: 2;
    overflow: auto;
    background: var(--kc-bg);
  }
  .bar {
    display: flex;
    align-items: center;
    gap: var(--kc-gap);
    padding: 6px var(--kc-gap);
    border-bottom: 1px solid var(--kc-border);
  }
  .folder {
    font-weight: 600;
  }
  .script,
  .status {
    color: var(--kc-muted);
  }
  .status {
    margin-left: auto;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .body {
    display: flex;
    flex: 1;
    min-height: 0;
  }
  .side {
    flex: none;
    overflow: auto;
    border-right: 1px solid var(--kc-border);
  }
  /* The files' own bar: their title, and what can be made in them */
  .side-bar {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 2px 4px 2px 12px;
  }
  .side-title {
    flex: 1;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--kc-muted);
  }
  .side-action {
    width: 26px;
    height: 26px;
  }
  .side-action svg {
    width: 18px;
    height: 18px;
  }
  .code {
    position: relative;
    display: flex;
    flex: none;
    flex-direction: column;
    min-width: 0;
    border-right: 1px solid var(--kc-border);
  }
  .editor {
    flex: 1;
    min-height: 0;
  }
  /* What the disk did to the script under its unsaved changes, and the person's choice */
  .conflict {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--kc-gap);
    padding: 6px var(--kc-gap);
    background: var(--kc-accent-subtle);
    border-bottom: 1px solid var(--kc-accent);
  }
  .conflict span {
    flex: 1 1 12em;
  }
  /* What the others leave, however wide they are made: the window's least width keeps some */
  .preview {
    flex: 1;
    min-width: 320px;
  }
  .empty {
    margin: var(--kc-gap);
    color: var(--kc-muted);
  }
  .welcome {
    display: flex;
    flex: 1;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: var(--kc-gap);
  }
  .welcome h1 {
    margin: 0;
  }
  .welcome p {
    margin: 0;
    color: var(--kc-muted);
  }
  .welcome .problem {
    color: var(--kc-error);
  }
  .recent {
    width: min(420px, 90%);
    margin-top: 16px;
  }
  .recent h2 {
    margin: 0 0 4px;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--kc-muted);
  }
  .recent ul {
    margin: 0;
    padding: 0;
    list-style: none;
  }
  .recent button {
    display: flex;
    gap: var(--kc-gap);
    align-items: baseline;
    width: 100%;
    padding: 4px 8px;
    font: inherit;
    text-align: left;
    color: var(--kc-accent-text);
    background: none;
    border: none;
    border-radius: var(--kc-radius);
    cursor: pointer;
  }
  .recent button:hover {
    background: var(--kc-hover);
  }
  .recent button:focus-visible {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .recent-name {
    flex: none;
  }
  .recent-path {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--kc-muted);
  }
</style>
