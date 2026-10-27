<!--
  @component
  A language server's preview: the model of the document the host says it shows, as the
  server's viewport socket sends it, with its parameters beside it. The panel's values go to the
  host (a ViewerHost: the VS Code extension, the desktop app), which gives them to the server;
  the frame that comes back is of a run with them. Why the run failed and what it warned of are
  listed under the model: one with a line, clicked, is shown in the script's editor. The
  document's presets are above its parameters: one applied, or the panel's values saved as one.
  The console under the model keeps each run (what it printed, its warnings and its error) and
  the host's log, as OpenSCAD's does. The parameters' column and the console are resized by the
  bars beside them, and the column hidden by the toolbar's Parameters button (for the model's
  width); their sizes, the column and the view's panel (the Panel button's) hidden or not, and
  the console folded or not are kept in the host's `settings`, and follow them as they are set;
  how the view looks too (the pane's view.* keys). A host's own shortcuts (`shortcuts`) are
  listed before the viewer's in the dialog the pane's bottom bar opens (`shortcutsOpen`).
-->
<script>
  import { onMount, untrack } from 'svelte';
  import { errorText } from '@kupcad/protocol';
  import ConsolePanel from './ConsolePanel.svelte';
  import ExportMenu from './ExportMenu.svelte';
  import { appendLines, linesOfLog, linesOfRun } from './console.js';
  import { plainValues } from './values.svelte.js';
  import ParamsPanel from './ParamsPanel.svelte';
  import { memorySettings, sizeSetting } from './settings.js';
  import Splitter from './Splitter.svelte';
  import ViewerPane from './ViewerPane.svelte';
  import { toBase64 } from './base64.js';
  import { problemsOf, runStatusOf } from './run-status.js';
  import { connectViewport } from './viewport-socket.js';

  /** @import { ExportFormat, ParamValues, Preview, ShownDocument, ViewerHost } from '@kupcad/protocol/types' */
  /** @import { ViewerOptions } from './viewer/types.js' */
  /** @import { ConsoleLine } from './console.js' */
  /** @import { Problem } from './run-status.js' */
  /** @import { Settings } from './settings.js' */
  /** @import { ShortcutGroup } from './shortcuts.js' */

  /**
   * @typedef {object} Props
   * @property {ViewerHost} host
   * @property {string | null} viewportUrl the language server's socket, once it is up
   * @property {typeof connectViewport} [connect]
   * @property {ViewerOptions} [viewerOptions] what the viewer is made with
   * @property {boolean} [presets] whether the host keeps presets, which the panel then offers
   * @property {boolean} [console] whether the console shows under the model
   * @property {Settings} [settings] where the panes' sizes, and how the view looks, are kept; by
   *   default the page's memory
   * @property {readonly ShortcutGroup[]} [shortcuts] the host's own, listed before the viewer's
   * @property {boolean} [shortcutsOpen] whether the shortcuts' dialog shows; bindable
   */

  /** @type {Props} */
  let {
    host,
    viewportUrl,
    connect = connectViewport,
    viewerOptions = {},
    presets: offersPresets = true,
    console: showsConsole = true,
    settings = memorySettings(),
    shortcuts = [],
    shortcutsOpen = $bindable(false),
  } = $props();

  /**
   * The settings' keys: the parameters' width and whether they show, whether the view's panel
   * shows, the console's height and whether it is open.
   */
  const KEYS = {
    params: 'preview.params',
    paramsOpen: 'preview.paramsOpen',
    panelOpen: 'preview.panelOpen',
    console: 'preview.console',
    open: 'preview.consoleOpen',
  };
  const id = $props.id();
  // As the settings have them; a size dragged is the pane's own until the drag is done
  let paramsWidth = $derived(sizeSetting(settings, KEYS.params, 288));
  const paramsOpen = $derived(settings.get(KEYS.paramsOpen) !== false);
  const panelOpen = $derived(settings.get(KEYS.panelOpen) !== false);
  let consoleHeight = $derived(sizeSetting(settings, KEYS.console, 144));
  const consoleOpen = $derived(settings.get(KEYS.open) !== false);

  let shown = $state(/** @type {ShownDocument | null} */ (null));
  let preview = $state(/** @type {Preview | null} */ (null));
  let connected = $state(false);
  let overrides = $state(/** @type {ParamValues} */ ({}));
  let presets = $state(/** @type {string[]} */ ([]));
  /** Why the viewer can't show the frame's model, until the next frame. */
  let unshown = $state('');
  let consoleLines = $state(/** @type {ConsoleLine[]} */ ([]));
  /** The header of the run the console has last: a frame sent again is the same run. */
  let lastRun = '';

  const header = $derived(preview?.header ?? null);
  /** How the shown document's run went, for the pane's status line. */
  const run = $derived(shown ? runStatusOf(header) : null);
  const problems = $derived(problemsOf(header));
  const parameters = $derived(header?.params.schema.parameters ?? []);
  const status = $derived(statusOf());

  function statusOf() {
    if (!viewportUrl) return 'Waiting for the KupCAD language server…';
    if (!connected) return 'Connecting to the language server…';
    if (!shown) return 'Open a .kup file to see its model.';
    if (!preview) return `Running ${shown.name}…`;
    if (unshown) return `The model can't be shown: ${unshown}`;
    return null;
  }

  onMount(() => {
    const stopListening = host.listen((message) => {
      // The host holds the values and presets of every document: it says the shown one's
      // with each document, and again when they change
      if (message.type === 'log') {
        consoleLines = appendLines(consoleLines, linesOfLog(message.text));
      } else if (message.type === 'document') {
        if (message.document?.uri !== shown?.uri) preview = null;
        shown = message.document;
        overrides = {};
        presets = [];
      } else if (message.uri !== shown?.uri) {
        return;
      } else if (message.type === 'overrides') {
        overrides = message.values;
      } else {
        presets = message.names;
      }
    });
    return stopListening;
  });

  // The socket of the server up now: one started again (it ended) has another, and the panel
  // keeps what it shows and its console across it
  $effect(() => {
    const url = viewportUrl;
    if (!url) return;
    const disconnect = untrack(() =>
      connect(url, {
        open: () => host.post({ type: 'ready' }),
        state: (open) => (connected = open),
        frame: (next) => {
          // The socket sends every viewer the frame of the document the server shows: one of
          // another (late, or with none shown here) isn't this page's
          if (!shown || next.header.document !== shown.uri) return;
          preview = next;
          unshown = '';
          const thisRun = JSON.stringify(next.header);
          if (thisRun !== lastRun) {
            lastRun = thisRun;
            consoleLines = appendLines(consoleLines, linesOfRun(next.header, shown.name));
          }
        },
        problem: (message) => host.post({ type: 'problem', message }),
      }),
    );
    return () => {
      disconnect();
      connected = false;
    };
  });

  /** @param {ParamValues} values */
  function changed(values) {
    if (shown) host.post({ type: 'setParams', uri: shown.uri, values });
  }

  /** @param {Event & { currentTarget: HTMLSelectElement }} event */
  function applyPreset(event) {
    const name = event.currentTarget.value;
    event.currentTarget.value = '';
    if (shown && name) host.post({ type: 'applyPreset', uri: shown.uri, name });
  }

  function savePreset() {
    if (shown) host.post({ type: 'savePreset', uri: shown.uri, values: plainValues(overrides) });
  }

  /**
   * Asks the host to export the shown document in `format`, with its values.
   * @param {ExportFormat} format
   */
  function exportShown(format) {
    if (shown) host.post({ type: 'export', uri: shown.uri, format });
  }

  /**
   * Asks the host to show the script where `problem` was, in its editor.
   * @param {Problem} problem
   */
  function revealProblem(problem) {
    if (!shown || problem.line === null) return;
    host.post({ type: 'reveal', uri: shown.uri, line: problem.line, column: problem.column ?? 1 });
  }

  /**
   * Shows the script where a console line names, in its editor.
   * @param {ConsoleLine} line
   */
  function revealLine(line) {
    if (!shown || line.line === null) return;
    host.post({ type: 'reveal', uri: shown.uri, line: line.line, column: line.column ?? 1 });
  }

  /** @param {Blob} image */
  async function screenshot(image) {
    host.post({ type: 'screenshot', png: toBase64(new Uint8Array(await image.arrayBuffer())) });
  }

  /** @param {unknown} error the viewer's: a model it can't show */
  function failed(error) {
    unshown = errorText(error);
    host.post({ type: 'problem', message: unshown });
  }
</script>

<div class="kc-preview">
  <section class="view">
    <div class="model">
      <ViewerPane
        model={preview?.model ?? null}
        subject={shown?.uri ?? null}
        options={viewerOptions}
        bind:panel={() => panelOpen, (open) => settings.set(KEYS.panelOpen, open)}
        {settings}
        {shortcuts}
        bind:shortcutsOpen
        status={run}
        {problems}
        onproblem={revealProblem}
        onscreenshot={screenshot}
        onerror={failed}
      >
        {#snippet actions()}
          {#if shown}
            <ExportMenu kind={preview?.model.kind ?? 'none'} onexport={exportShown} />
          {/if}
        {/snippet}
        {#snippet toggles()}
          {#if header && parameters.length > 0}
            <button
              type="button"
              class="kc-control"
              aria-controls="{id}-params"
              aria-expanded={paramsOpen}
              onclick={() => settings.set(KEYS.paramsOpen, !paramsOpen)}
            >
              Parameters
            </button>
          {/if}
        {/snippet}
      </ViewerPane>
      {#if status}
        <p class="notice">{status}</p>
      {/if}
    </div>
    {#if showsConsole}
      {#if consoleOpen}
        <Splitter
          between="rows"
          pane="after"
          bind:size={consoleHeight}
          min={48}
          label="Resize the console"
          onchange={(size) => settings.set(KEYS.console, size)}
        />
      {/if}
      <ConsolePanel
        lines={consoleLines}
        height={consoleHeight}
        bind:open={() => consoleOpen, (open) => settings.set(KEYS.open, open)}
        onreveal={revealLine}
        onclear={() => (consoleLines = [])}
      />
    {/if}
  </section>
  {#if header && parameters.length > 0}
    {#if paramsOpen}
      <Splitter
        pane="after"
        bind:size={paramsWidth}
        min={200}
        max={640}
        label="Resize the parameters"
        onchange={(size) => settings.set(KEYS.params, size)}
      />
    {/if}
    <!-- Hidden, not gone: what its fields hold stays, and the toggle has it to control -->
    <aside
      class="params"
      id="{id}-params"
      aria-label="Parameters"
      hidden={!paramsOpen}
      style:width="{paramsWidth}px"
    >
      {#if offersPresets}
        <div class="presets">
          <select
            class="kc-control"
            aria-label="Preset"
            disabled={presets.length === 0}
            onchange={applyPreset}
          >
            <option value="" selected disabled>
              {presets.length > 0 ? 'Apply a preset…' : 'No presets'}
            </option>
            {#each presets as name (name)}
              <option value={name}>{name}</option>
            {/each}
          </select>
          <button type="button" class="kc-control" onclick={savePreset}>Save as preset…</button>
        </div>
      {/if}
      <ParamsPanel
        schema={header.params.schema}
        values={header.params.values}
        error={header.error}
        bind:overrides
        onchange={changed}
      />
    </aside>
  {/if}
</div>

<style>
  .kc-preview {
    display: flex;
    height: 100%;
    background: var(--kc-bg);
    font-family: var(--kc-font);
    font-size: var(--kc-font-size);
    color: var(--kc-fg);
  }
  .view {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
  }
  .model {
    position: relative;
    flex: 1;
    min-height: 0;
  }
  /* No space at its top: the parameters' bar, held there as they scroll, has its own */
  .params {
    flex: none;
    overflow: auto;
    padding: 0 var(--kc-gap) var(--kc-gap);
    border-left: 1px solid var(--kc-border);
  }
  .presets {
    display: flex;
    gap: 4px;
    /* The column gives no space at its top */
    padding-top: var(--kc-gap);
    margin-bottom: var(--kc-gap);
  }
  .presets select {
    flex: 1;
    min-width: 0;
  }
  .notice {
    position: absolute;
    inset: 50% 0 auto;
    margin: 0;
    text-align: center;
    color: var(--kc-muted);
    pointer-events: none;
  }
</style>
