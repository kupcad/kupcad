<!--
  @component
  The app's window: the folder opened, its files beside the script open in the editor, and the
  script's preview, its parameters with it. The editor and the preview run on the bundled
  kupcad's language server, started for the folder. A script is saved with ⌘S (Ctrl+S); the
  window asks before it closes on unsaved changes. The bars between the panes resize them, the
  sizes kept in the app's settings (`settings`).
-->
<script>
  import { Editor } from '@kupcad/editor/svelte';
  import { errorText } from '@kupcad/protocol';
  import { memorySettings, PreviewPanel, sizeSetting, Splitter } from '@kupcad/ui';
  import { onMount, tick, untrack } from 'svelte';
  import { SvelteMap, SvelteSet } from 'svelte/reactivity';
  import FileTree from './FileTree.svelte';
  import { fileUri } from './folder.js';
  import { createHost } from './host.js';

  /** @import { Editor as ScriptEditor } from '@kupcad/editor' */
  /** @import { Entry } from './folder.js' */
  /** @import { Settings } from '@kupcad/ui' */
  /** @import { Platform } from './platform.js' */

  /**
   * @typedef {object} Props
   * @property {Platform} platform what the window does its work with
   * @property {import('@kupcad/viewer/types').ViewerOptions} [viewerOptions] what the
   *   preview's viewer is made with
   * @property {Settings} [settings] where the panes' sizes are kept (the app's settings file)
   */

  /** @type {Props} */
  let { platform, viewerOptions = {}, settings = memorySettings() } = $props();

  /** The settings' keys: the folder's tree's width and the editor's. */
  const KEYS = { files: 'app.files', editor: 'app.editor' };
  let filesWidth = $state(untrack(() => sizeSetting(settings, KEYS.files, 224)));
  let editorWidth = $state(untrack(() => sizeSetting(settings, KEYS.editor, 520)));

  /** The folder open, by its path. */
  let folder = $state(/** @type {string | null} */ (null));
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
    await server?.stop();
    texts.clear();
    unsaved.clear();
    open = null;
    preview.show(null);
    folder = picked;
    entries = await platform.listFolder(picked);
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

  /** @param {KeyboardEvent} event */
  function keydown(event) {
    if ((event.metaKey || event.ctrlKey) && event.key === 's') {
      event.preventDefault();
      void saveScript();
    }
  }

  onMount(() => {
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
      void closing.then((stop) => stop());
      void server?.stop();
    };
  });
</script>

<svelte:window onkeydown={keydown} />

<div class="kc-desktop">
  {#if folder}
    <header class="bar">
      <button type="button" class="kc-control" onclick={() => openFolder()}>Open folder…</button>
      <span class="folder" title={folder}>{name(folder)}</span>
      {#if open}
        <span class="script">{open.name}{unsaved.has(open.path) ? ' ●' : ''}</span>
        <button
          type="button"
          class="kc-control"
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
    <div class="body">
      <nav class="files" aria-label="Files" style:width="{filesWidth}px">
        <FileTree {entries} selected={open?.path ?? null} {unsaved} onopen={openScript} />
      </nav>
      <Splitter
        bind:size={filesWidth}
        min={140}
        max={480}
        label="Resize the files"
        onchange={(size) => settings.set(KEYS.files, size)}
      />
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
        {#key viewportUrl}
          <PreviewPanel
            host={preview.host}
            {viewportUrl}
            {viewerOptions}
            {settings}
            presets={false}
          />
        {/key}
      </section>
    </div>
  {:else}
    <div class="welcome">
      <h1>KupCAD</h1>
      <p>Open a folder of scripts: they are edited here, and their models shown beside them.</p>
      <button type="button" class="kc-control" onclick={() => openFolder()}>Open folder…</button>
    </div>
  {/if}
</div>

<style>
  .kc-desktop {
    display: flex;
    flex-direction: column;
    height: 100%;
    color: var(--kc-fg);
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
  .files {
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
