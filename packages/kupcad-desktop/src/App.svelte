<!--
  @component
  The app's window: the folder opened, its files beside the script open in the editor, and the
  script's preview, its parameters with it. The editor and the preview run on the bundled
  kupcad's language server, started for the folder. The folder's tree follows what is made,
  removed or renamed in it, and its closed folders stay closed until a script in one is opened.
  A script is saved with ⌘S (Ctrl+S); the window asks before it closes on unsaved changes. The
  bars between the panes resize them, the sizes kept in the app's settings (`settings`).
  The strip at the window's left edge shows or hides the files, and opens the app's settings
  (the theme, the console; ⌘, or Ctrl+, too): a page over the workspace, which stays as it was
  under it, out of reach until Escape, the page's close button or the strip gives it back.
-->
<script>
  import { Editor } from '@kupcad/editor/svelte';
  import { errorText } from '@kupcad/protocol';
  import { memorySettings, PreviewPanel, sizeSetting, Splitter } from '@kupcad/panels';
  import { onMount, tick, untrack } from 'svelte';
  import { SvelteMap, SvelteSet } from 'svelte/reactivity';
  import FileTree from './FileTree.svelte';
  import { fileUri, foldersAbove } from './folder.js';
  import { createHost } from './host.js';
  import SettingsPane from './SettingsPane.svelte';
  import { themeOf } from './theme.js';

  /** @import { Editor as ScriptEditor } from '@kupcad/editor' */
  /** @import { Entry } from './folder.js' */
  /** @import { Settings } from '@kupcad/panels' */
  /** @import { Platform } from './platform.js' */
  /** @import { Theme } from './theme.js' */

  /**
   * @typedef {object} Props
   * @property {Platform} platform what the window does its work with
   * @property {import('@kupcad/viewer/types').ViewerOptions} [viewerOptions] what the
   *   preview's viewer is made with
   * @property {Settings} [settings] where the panes' sizes are kept (the app's settings file)
   */

  /** @type {Props} */
  let { platform, viewerOptions = {}, settings = memorySettings() } = $props();

  /**
   * The settings' keys: the files' width and the editor's, the theme, and whether the
   * console shows.
   */
  const KEYS = {
    files: 'app.files',
    editor: 'app.editor',
    theme: 'app.theme',
    console: 'app.console',
  };
  let filesWidth = $state(untrack(() => sizeSetting(settings, KEYS.files, 224)));
  let editorWidth = $state(untrack(() => sizeSetting(settings, KEYS.editor, 520)));
  let theme = $state(untrack(() => themeOf(settings.get(KEYS.theme))));
  let showsConsole = $state(untrack(() => settings.get(KEYS.console) !== false));
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
  /** Each script read, by its path: its text now, and as it was last read or saved. */
  const texts = new SvelteMap();
  /** The paths of the scripts whose text isn't what is on disk. */
  const unsaved = new SvelteSet();
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
  /** The shortcuts' key as this system names it, in the strip's tooltips. */
  const MOD = globalThis.navigator?.userAgent.includes('Mac') ? '⌘' : 'Ctrl+';

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

  /** @param {string | null} [named] the folder, else the one the person picks */
  async function openFolder(named) {
    const picked = named ?? (await platform.pickFolder());
    if (!picked) return;
    if (unsaved.size > 0 && !(await platform.confirm('Leave this folder without saving?'))) return;
    const mine = ++opened;
    unwatch?.();
    unwatch = null;
    await server?.stop();
    texts.clear();
    unsaved.clear();
    collapsed.clear();
    open = null;
    preview.show(null);
    folder = picked;
    showsFiles = true;
    entries = await platform.listFolder(picked);
    platform
      .watchFolder(picked, listAgain(picked, mine))
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
   * What lists the folder `root` again when the watcher says it changed: one listing at a time,
   * another after it for what changed meanwhile, none once another folder is opened.
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
    if (!texts.has(entry.path)) {
      try {
        const text = await platform.files.read(entry.path);
        texts.set(entry.path, { text, saved: text });
      } catch (error) {
        problem = `${entry.name} wasn't read: ${errorText(error)}`;
        return;
      }
    }
    open = { path: entry.path, name: entry.name, uri: fileUri(entry.path) };
    // Shown in the tree: the folders it is in open
    for (const path of foldersAbove(entries, entry.path)) collapsed.delete(path);
    preview.show(open);
  }

  /** @param {string} text */
  function edited(text) {
    if (!open) return;
    const kept = texts.get(open.path);
    texts.set(open.path, { text, saved: kept?.saved ?? '' });
    if (text === kept?.saved) unsaved.delete(open.path);
    else unsaved.add(open.path);
  }

  async function saveScript() {
    if (!open) return;
    const { path } = open;
    const { text } = texts.get(path);
    try {
      await platform.files.write(path, text);
    } catch (error) {
      problem = `${open.name} wasn't saved: ${errorText(error)}`;
      return;
    }
    // What was typed while it was written stays, unsaved
    const now = texts.get(path)?.text ?? text;
    texts.set(path, { text: now, saved: text });
    if (now === text) unsaved.delete(path);
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

  /** @param {Theme} chosen */
  function chooseTheme(chosen) {
    theme = chosen;
    settings.set(KEYS.theme, chosen);
    applyTheme();
  }

  function applyTheme() {
    platform
      .setTheme(theme)
      .catch((error) => (problem = `The theme wasn't set: ${errorText(error)}`));
  }

  /** @param {boolean} shows */
  function chooseConsole(shows) {
    showsConsole = shows;
    settings.set(KEYS.console, shows);
  }

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
    // The system's is the window's own until told otherwise
    if (theme !== 'system') applyTheme();
    const closing = platform.onClose(async () =>
      unsaved.size === 0 ? true : platform.confirm('Close without saving your changes?'),
    );
    platform
      .launchFolder()
      .then(async (named) => {
        if (named) await openFolder(named);
      })
      .catch((error) => (problem = errorText(error)));
    return () => {
      opened++;
      unwatch?.();
      void closing.then((stop) => stop());
      void server?.stop();
    };
  });
</script>

<svelte:window onkeydown={keydown} />

<div class="kc-desktop">
  <nav class="rail" aria-label="Views">
    <button
      type="button"
      aria-label="Files"
      title="Files"
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
          <span class="script">{open.name}{unsaved.has(open.path) ? ' ●' : ''}</span>
          <button
            type="button"
            class="kc-control kc-primary"
            disabled={!unsaved.has(open.path)}
            onclick={saveScript}
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
      {#if filesShown}
        <nav class="side" aria-label="Files" style:width="{filesWidth}px">
          <FileTree
            {entries}
            {collapsed}
            selected={open?.path ?? null}
            {unsaved}
            onopen={openScript}
            ontoggle={(entry, opening) => toggle(entry.path, opening)}
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
          {#if open && server}
            {#key open.path}
              <Editor
                value={texts.get(open.path)?.text ?? ''}
                label={open.name}
                languageServer={{ client: server.client, uri: open.uri }}
                onchange={edited}
                bind:editor
              />
            {/key}
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
          />
        </section>
      {:else}
        <div class="welcome">
          <h1>KupCAD</h1>
          <p>Open a folder of scripts: they are edited here, and their models shown beside them.</p>
          <button type="button" class="kc-control kc-primary" onclick={() => openFolder()}>
            Open folder…
          </button>
        </div>
      {/if}
    </div>
    {#if settingsOpen}
      <div class="settings-page" role="dialog" aria-label="Settings" bind:this={page}>
        <SettingsPane
          {theme}
          console={showsConsole}
          ontheme={chooseTheme}
          onconsole={chooseConsole}
          onclose={closeSettings}
        />
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
    overflow: auto;
    border-right: 1px solid var(--kc-border);
  }
  .code {
    position: relative;
    flex: none;
    min-width: 0;
    border-right: 1px solid var(--kc-border);
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
</style>
