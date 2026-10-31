<!--
  @component
  The app's window: the folder opened, its files beside the script open in the editor, and the
  script's preview, its parameters with it. The editor and the preview run on the bundled
  kupcad's language server, started for the folder. The folder's tree follows what is made,
  removed or renamed in it, and its closed folders stay closed until a script in one is opened;
  in it the person makes scripts and folders, renames them and moves them to the trash (its
  rows' menus, the File menu). A script read is read again when the disk changes it (Scripts):
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
  A newer version of the app is looked for once the window opens and from the menu (Check for
  Updates…), and installed, the app restarting on it, when the person says so.
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
  import {
    clashQuestion,
    ConflictBar,
    FileTree,
    nameOf,
    Project,
    refuseStrayDrop,
    rowMenu,
    within,
  } from '@kupcad/files';
  import { fileUri } from './folder.js';
  import { createHost } from './host.js';
  import { menuBar } from './menu.js';
  import { fontSizeOf, KEYS, recentOf, withRecent, zoomOf, zoomStep } from './prefs.js';
  import SettingsPane from './SettingsPane.svelte';
  import { themeOf } from './theme.js';

  /** @import { Editor as ScriptEditor } from '@kupcad/editor' */
  /** @import { Clash, Entry, ProjectFiles } from '@kupcad/files' */
  /** @import { Settings, ShortcutGroup } from '@kupcad/ui' */
  /** @import { Platform } from './platform.js' */

  /**
   * @typedef {object} Props
   * @property {Platform} platform what the window does its work with
   * @property {import('@kupcad/ui/viewer/types').ViewerOptions} [viewerOptions] what the
   *   preview's viewer is made with
   * @property {Settings} [settings] where the panes' sizes are kept (the app's settings file)
   * @property {boolean} [checkUpdates] whether to look for a newer version once the window
   *   opens (a release build's, not `pnpm dev`'s)
   */

  /** @type {Props} */
  let {
    platform,
    viewerOptions = {},
    settings = memorySettings(),
    checkUpdates: checkAtStart = false,
  } = $props();

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
  /** The folder open: its tree, its scripts, the name being given in it (@kupcad/files). */
  let project = $state.raw(/** @type {Project | null} */ (null));
  const folder = $derived(project?.root ?? null);
  /** How many folders were opened: what a listing or a watcher of an earlier one checks. */
  let opened = 0;
  /** Stops watching the folder open. */
  let unwatch = /** @type {(() => void) | null} */ (null);
  /** The script open in the editor. */
  let open = $state(/** @type {{ path: string, name: string, uri: string } | null} */ (null));
  /** How many scripts were asked to open: one read after a later one is asked for isn't shown. */
  let opening = 0;
  /** What the disk did to the script open under its unsaved changes, if anything. */
  const conflict = $derived(open ? project?.scripts.conflicts.get(open.path) : undefined);
  /** The project's files, on the disk: the trash is where one removed goes. */
  const projectFiles = /** @type {ProjectFiles} */ ({
    readDir: (path) => platform.readDir(path),
    read: (path) => platform.files.read(path),
    write: (path, text) => platform.files.write(path, text),
    writeBytes: (path, bytes) => platform.writeFile(path, bytes),
    exists: (path) => platform.files.exists(path),
    mkdir: (path) => platform.files.mkdir(path),
    rename: (from, to) => platform.files.rename(from, to),
    remove: (path) => platform.trash(path),
  });
  let server = $state(/** @type {ReturnType<Platform['server']> | null} */ (null));
  let viewportUrl = $state(/** @type {string | null} */ (null));
  let running = $state(false);
  let editor = $state(/** @type {ScriptEditor | null} */ (null));
  /** What went wrong last, shown in the bar until something else does. */
  let problem = $state('');

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

  /**
   * Opens a folder, kept as the last opened; one that can't be listed leaves the window as it
   * was, and one opened while another was being opened wins.
   * @param {string | null} [named] the folder, else the one the person picks
   */
  async function openFolder(named) {
    const picked = named ?? (await platform.pickFolder());
    if (!picked) return;
    if (
      (project?.scripts.unsaved.size ?? 0) > 0 &&
      !(await platform.confirm('Leave this folder without saving?'))
    ) {
      return;
    }
    const mine = ++opened;
    const next = new Project(picked, projectFiles, {
      onproblem: (text) => {
        if (mine === opened) problem = text;
      },
      onsave: (path) => void saveScript(path, { quiet: true }),
      saveAfterMs: () => (autosave ? AUTOSAVE_MS : null),
      beforeRename: keepEditor,
      // macOS and Windows take a name in another case for the same file
      ignoresCase: true,
    });
    if (!(await next.list()) || mine !== opened) return;
    unwatch?.();
    unwatch = null;
    project?.dispose();
    await server?.stop();
    if (mine !== opened) return;
    project = next;
    open = null;
    preview.show(null);
    problem = '';
    showsFiles = true;
    settings.set(KEYS.folder, picked);
    settings.set(KEYS.recent, withRecent(recent, picked));
    platform
      .watchFolder(picked, ({ tree }) => {
        if (tree) void next.list();
        void checkDisk(mine);
      })
      .then((stop) => {
        if (mine === opened) unwatch = stop;
        else stop();
      })
      .catch((error) => (problem = `${nameOf(picked)} isn't watched: ${errorText(error)}`));
    const started = platform.server(fileUri(picked), {
      viewport: (url) => (viewportUrl = url),
      state: (up) => (running = up),
      log: (text) => preview.log(text),
    });
    server = started;
    try {
      await started.start();
    } catch (error) {
      if (mine === opened) problem = `kupcad didn't start: ${errorText(error)}`;
    }
    if (mine !== opened) return;
    const first = next.entries.find((entry) => entry.kind === 'script');
    if (first) await openScript(first);
  }

  /**
   * Reads the scripts again as the disk has them (a file in the folder written, the window
   * back); the one open, gone from the disk with nothing unsaved, is closed.
   * @param {number} [mine] which folder opened it was
   */
  async function checkDisk(mine = opened) {
    const current = project;
    if (mine !== opened || !current) return;
    const dropped = await current.scripts.check();
    if (mine !== opened || !open || !dropped.includes(open.path)) return;
    problem = `${open.name} was removed from the disk.`;
    closeScript();
  }

  /** @param {Entry} entry */
  async function openScript(entry) {
    const current = project;
    if (!current) return;
    const mine = ++opening;
    try {
      await current.scripts.read(entry.path);
    } catch (error) {
      if (mine === opening) problem = `${entry.name} wasn't read: ${errorText(error)}`;
      return;
    }
    if (mine !== opening || current !== project) return;
    keepEditor();
    open = { path: entry.path, name: entry.name, uri: fileUri(entry.path) };
    // Shown in the tree: the folders it is in open
    current.reveal(entry.path);
    preview.show(open);
  }

  /** Keeps the editor of the script open as it is, its undo history with it, for its return. */
  function keepEditor() {
    if (open && editor) project?.scripts.keep(open.path, editor.snapshot());
  }

  function closeScript() {
    open = null;
    preview.show(null);
  }

  /** @param {string} text */
  function edited(text) {
    if (open) project?.edit(open.path, text);
  }

  /**
   * Saves a script, the one open by default. Where the disk changed since it was read, the
   * person is asked before it is written over; saved by itself (`quiet`), it isn't, and the
   * change is said above the editor instead.
   * @param {string | undefined} [path]
   * @param {{ quiet?: boolean }} [options]
   */
  async function saveScript(path = open?.path, { quiet = false } = {}) {
    const current = project;
    if (!path || !current?.scripts.has(path)) return;
    current.saving(path);
    try {
      if ((await current.scripts.save(path)) === 'saved' || quiet) return;
      const question = `${nameOf(path)} changed on disk since it was opened. Save yours over it?`;
      if (await platform.confirm(question)) await current.scripts.save(path, { overwrite: true });
    } catch (error) {
      problem = `${nameOf(path)} wasn't saved: ${errorText(error)}`;
    }
  }

  /**
   * The person's choice for the script open, which the disk changed under their changes.
   * @param {'disk' | 'mine'} keep
   */
  function resolveConflict(keep) {
    if (!open || !project) return;
    project.scripts.resolve(open.path, keep);
    if (!project.scripts.has(open.path)) closeScript();
  }

  /**
   * Shows a script at a place its run named, opening it first if another is open.
   * @param {string} uri
   * @param {number} line
   * @param {number} column
   */
  async function reveal(uri, line, column) {
    if (open?.uri !== uri) {
      const entry = project?.entries.find((candidate) => fileUri(candidate.path) === uri);
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
    if (!project) return;
    showFiles();
    project.startNew(kind, project.folderFor(entry, open?.path));
  }

  /** @param {Entry} entry */
  function startRename(entry) {
    showFiles();
    project?.startRename(entry);
  }

  /** The files, for a name to be given in them: over the settings, which close. */
  function showFiles() {
    if (settingsOpen) void closeSettings();
    showsFiles = true;
  }

  /**
   * Makes the name given in the tree an entry (the project's `commitName`): a script made is
   * opened, to be written; the script open, renamed or in a folder renamed, stays open by its
   * new path.
   * @param {string} given
   */
  async function commitName(given) {
    const current = project;
    const done = await current?.commitName(given);
    if (!done || current !== project) return;
    if ('made' in done) {
      if (done.made.kind !== 'script') return;
      await openScript(done.made);
      await tick();
      editor?.focus();
    } else if (open && within(open.path, done.renamed.from)) {
      const path = done.renamed.to + open.path.slice(done.renamed.from.length);
      open = { path, name: nameOf(path), uri: fileUri(path) };
      preview.show(open);
    }
  }

  /**
   * Moves an entry to the system's trash, once the person says so; the scripts in it, unsaved
   * changes and all, are closed.
   * @param {Entry} entry
   */
  async function trashEntry(entry) {
    if (!project) return;
    const lost = [...project.scripts.unsaved].some((path) => within(path, entry.path));
    const what =
      entry.kind === 'folder'
        ? `the folder “${entry.name}” and everything in it`
        : `“${entry.name}”`;
    const question = `Move ${what} to the ${TRASH}?${lost ? ' Its unsaved changes are lost.' : ''}`;
    if (!(await platform.confirm(question))) return;
    if (!(await project.remove(entry))) return;
    if (open && within(open.path, entry.path)) closeScript();
  }

  /**
   * Puts files dropped on the tree from the system's file manager in the folder `dir` (the
   * project's `addFiles`, asking about a name it has with the system's dialog); a script
   * replaced is read again.
   * @param {File[]} files
   * @param {string} dir
   */
  async function dropFiles(files, dir) {
    const put = await project?.addFiles(files, dir, askClash);
    if (put?.length) await checkDisk();
  }

  /**
   * What to do with a file dropped whose name the folder has, the system's dialog asking.
   * @param {string} named
   * @param {string} renamed the free name it would take
   * @param {string} folderName
   * @returns {Promise<Clash>}
   */
  async function askClash(named, renamed, folderName) {
    const question = clashQuestion(named, renamed, folderName);
    const label = (/** @type {string} */ value) =>
      question.answers.find((answer) => answer.value === value)?.text ?? value;
    const pressed = await platform.ask(`${question.title}. ${question.text}`, {
      yes: label('rename'),
      no: label('replace'),
      cancel: label('cancel'),
    });
    if (pressed === label('rename')) return 'rename';
    return pressed === label('replace') ? 'replace' : 'cancel';
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
        remove: () => entry && void trashEntry(entry),
      },
      { remove: `Move to ${TRASH}` },
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

  /** A look for a newer version is under way: another waits for it to end. */
  let checkingUpdates = false;

  /**
   * Looks for a newer version of the app and offers to install it, the app restarting on it
   * (asking first when there are unsaved changes). At the start (`quiet`) it says nothing unless
   * there is one: an offline start isn't a problem; from the menu it says what it found.
   * @param {boolean} quiet
   */
  async function checkUpdates(quiet) {
    if (checkingUpdates) return;
    checkingUpdates = true;
    try {
      let update;
      try {
        update = await platform.checkUpdate();
      } catch (error) {
        if (!quiet) problem = `Updates weren't checked: ${errorText(error)}`;
        return;
      }
      if (!update) {
        if (!quiet) await platform.tell('KupCAD is up to date.');
        return;
      }
      const install =
        (await platform.confirm(
          `KupCAD ${update.version} is out (this is ${update.current}). Install it and restart?`,
        )) &&
        ((project?.scripts.unsaved.size ?? 0) === 0 ||
          (await platform.confirm('Restart without saving your changes?')));
      if (!install) {
        await update.dismiss();
        return;
      }
      await update
        .install()
        .catch(
          (error) => (problem = `KupCAD ${update.version} wasn't installed: ${errorText(error)}`),
        );
    } finally {
      checkingUpdates = false;
    }
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
    checkUpdates: () => void checkUpdates(false),
  };
  // The menu bar as the window is: what it may do now, the folders opened last
  $effect(() => {
    const menus = menuBar(
      {
        mac: MAC,
        folder: folder !== null,
        canSave: open !== null && (project?.scripts.unsaved.has(open.path) ?? false),
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
      (project?.scripts.unsaved.size ?? 0) === 0
        ? true
        : platform.confirm('Close without saving your changes?'),
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
    if (checkAtStart) void checkUpdates(true);
    return () => {
      opened++;
      unwatch?.();
      project?.dispose();
      void closing.then((stop) => stop());
      void server?.stop();
    };
  });
</script>

<svelte:window
  onkeydown={keydown}
  onfocus={() => void checkDisk()}
  ondragover={refuseStrayDrop}
  ondrop={refuseStrayDrop}
/>

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
    {#if project}
      <header class="bar" inert={settingsOpen}>
        <button type="button" class="kc-control" onclick={() => openFolder()}>Open folder…</button>
        <span class="folder" title={project.root}>{nameOf(project.root)}</span>
        {#if open}
          <span class="script">{open.name}{project.scripts.unsaved.has(open.path) ? ' ●' : ''}</span
          >
          <button
            type="button"
            class="kc-control kc-primary"
            disabled={!project.scripts.unsaved.has(open.path)}
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
      {#if filesShown && project}
        <nav class="side" aria-label="Files" style:width="{filesWidth}px">
          <FileTree
            entries={project.entries}
            collapsed={project.collapsed}
            selected={open?.path ?? null}
            unsaved={project.scripts.unsaved}
            root={project.root}
            editing={project.editing}
            problem={project.nameError}
            onopen={openScript}
            ontoggle={(entry, opening) => project?.toggle(entry.path, opening)}
            oncommit={(given) => void commitName(given)}
            oncancel={() => project?.cancelNaming()}
            onmenu={rowMenuOf}
            onrename={startRename}
            ontrash={(entry) => void trashEntry(entry)}
            onnew={(kind) => startNew(kind)}
            keys={{ script: combo('N'), folder: combo('N', true) }}
            ondropfiles={(dropped, dir) => void dropFiles(dropped, dir)}
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
      {#if project}
        <section class="code" aria-label="Script" style:width="{editorWidth}px">
          {#if open && conflict !== undefined}
            <ConflictBar name={open.name} {conflict} where="on disk" onresolve={resolveConflict} />
          {/if}
          {#if open && server}
            <div class="editor">
              {#key open.path}
                <Editor
                  value={project.scripts.text(open.path)}
                  label={open.name}
                  languageServer={{ client: server.client, uri: open.uri }}
                  restore={project.scripts.snapshot(open.path)}
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
                      <span class="recent-name">{nameOf(path)}</span>
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
  .rail button {
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
  .rail button:hover:not(:disabled) {
    color: var(--kc-fg);
    background: var(--kc-hover);
  }
  .rail button:focus-visible {
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
  .rail svg {
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
    border-right: 1px solid var(--kc-border);
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
