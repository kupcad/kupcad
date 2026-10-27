<!--
  @component
  KupCAD in a page: the script in an editor beside its model, its parameters beside that, all run
  by the core compiled to WebAssembly, in a worker (runner.js says when). The editor marks what
  `check` finds and where the run failed or warned (marks.js); the viewer pane says how the run
  went and lists its problems, one clicked taking the editor there. A model is exported in any
  format the core writes, and the viewer's screenshot saved, as downloads. The console under the
  model keeps each run (what it printed, its warnings and its error) and the core's log. The
  bars between the panes resize them, and the toolbar's Parameters button hides theirs (for the
  model's width); the sizes, what is hidden or folded, and how the view looks are kept in
  `settings` (the page's localStorage by default), and follow them as they are set. It keeps
  nothing else of the page's: the page gives the script it starts with (`source`), and is told
  of each edit of it (`onsource`), for its own buttons in the toolbar (`actions`) to share or
  save it.
-->
<script>
  import { onMount, untrack } from 'svelte';
  import { Editor } from '@kupcad/editor/svelte';
  import { errorText } from '@kupcad/protocol';
  import {
    appendLines,
    ConsolePanel,
    ExportMenu,
    linesOfLog,
    linesOfRun,
    localSettings,
    ParamsPanel,
    plainValues,
    problemsOf,
    runStatusOf,
    sizeSetting,
    Splitter,
    ViewerPane,
  } from '@kupcad/ui';
  import { createKupcadWorker } from '@kupcad/wasm';
  import { download } from './download.js';
  import { marksOf } from './marks.js';
  import { Runner } from './runner.js';

  /** @import { Editor as EditorClass } from '@kupcad/editor' */
  /** @import { ExportFormat, Finding, ParamValues, Preview } from '@kupcad/protocol/types' */
  /** @import { ConsoleLine, Problem, Settings, ShortcutGroup } from '@kupcad/ui' */
  /** @import { Snippet } from 'svelte' */
  /** @import { ViewerOptions } from '@kupcad/ui/viewer/types' */
  /** @import { KupcadApi, WorkerWasmSource } from '@kupcad/wasm/types' */

  /**
   * @typedef {object} Props
   * @property {string} [source] the script it starts with
   * @property {string} [name] what the script is called: its downloads are named after it
   * @property {KupcadApi} [kupcad] the core to run it with; by default one it starts in a worker
   *   (and ends with it)
   * @property {WorkerWasmSource} [wasm] that worker's module, when not the one the wasm package
   *   ships
   * @property {ViewerOptions} [viewerOptions] what the viewer is made with
   * @property {Settings} [settings] where the panes' sizes, and how the view looks, are kept;
   *   by default the page's localStorage
   * @property {(source: string) => void} [onsource] the person's edit changed the script: it now
   *   is `source` (for a host to share it, or save it)
   * @property {Snippet} [actions] a host's own buttons in the model's toolbar, after Export
   *   (`.kc-control` gives them its look)
   * @property {readonly ShortcutGroup[]} [shortcuts] the host's own, listed before the viewer's
   * @property {boolean} [shortcutsOpen] whether the shortcuts' dialog shows; bindable
   */

  /** @type {Props} */
  let {
    source = '',
    name = 'model',
    kupcad,
    wasm,
    viewerOptions = {},
    settings = localSettings(),
    onsource,
    actions: hostActions,
    shortcuts = [],
    shortcutsOpen = $bindable(false),
  } = $props();

  /**
   * The settings' keys: the editor's and the parameters' widths, whether the parameters and the
   * view's panel show, the console's height and state.
   */
  const KEYS = {
    editor: 'playground.editor',
    params: 'playground.params',
    paramsOpen: 'playground.paramsOpen',
    panelOpen: 'playground.panelOpen',
    console: 'playground.console',
    open: 'playground.consoleOpen',
  };
  /** The least the model is given, however wide the editor is made. */
  const MIN_VIEW = 320;
  const id = $props.id();
  // As the settings have them; a size dragged is the pane's own until the drag is done
  let editorWidth = $derived(sizeSetting(settings, KEYS.editor, 460));
  let paramsWidth = $derived(sizeSetting(settings, KEYS.params, 288));
  const paramsOpen = $derived(settings.get(KEYS.paramsOpen) !== false);
  const panelOpen = $derived(settings.get(KEYS.panelOpen) !== false);
  let consoleHeight = $derived(sizeSetting(settings, KEYS.console, 144));
  const consoleOpen = $derived(settings.get(KEYS.open) !== false);
  /** The playground's width, once laid out. */
  let width = $state(0);

  /** The script as the editor has it: the user's, from the one the page gave at first. */
  let value = $state(untrack(() => source));
  let editor = $state(/** @type {EditorClass | null} */ (null));
  /** `check`'s findings of the script as it is, none while it changed since. */
  let findings = $state(/** @type {Finding[]} */ ([]));
  /** The last run's frame, and the script it ran. */
  let ran = $state(/** @type {{ preview: Preview, source: string } | null} */ (null));
  /** The values the parameter panel gives. */
  let overrides = $state(/** @type {ParamValues} */ ({}));
  /** What went wrong outside a run: a call that failed, an export. */
  let notice = $state('');
  let consoleLines = $state(/** @type {ConsoleLine[]} */ ([]));
  /** @type {KupcadApi | null} */
  let core = null;
  /** @type {Runner | null} */
  let runner = null;

  const header = $derived(ran?.preview.header ?? null);
  const status = $derived(runStatusOf(header));
  const problems = $derived(problemsOf(header));
  // Marked where they are in the script as it is: a run of another (older) script marks nothing
  const marks = $derived(marksOf(findings, ran?.source === value ? problems : []));
  const parameters = $derived(header?.params.schema.parameters ?? []);
  /** The parameters' column is there, and not hidden: the model's width is the rest. */
  const paramsShown = $derived(header !== null && parameters.length > 0 && paramsOpen);

  onMount(() => {
    const made = kupcad ? null : createKupcadWorker(wasm ? { wasm, log } : { log });
    core = kupcad ?? made;
    runner = new Runner(/** @type {KupcadApi} */ (core), {
      onfindings: (next, of) => {
        if (of === value) findings = next;
      },
      onpreview: (preview, of) => {
        ran = { preview, source: of };
        notice = '';
        consoleLines = appendLines(consoleLines, linesOfRun(preview.header, name));
      },
      onerror: (error) => (notice = errorText(error)),
    });
    runner.run(value, {}, { now: true });
    return () => {
      runner?.dispose();
      made?.terminate();
    };
  });

  /** @param {string} line of the core's log, which goes to the console */
  function log(line) {
    consoleLines = appendLines(consoleLines, linesOfLog(line));
  }

  /** @param {string} next the user's script */
  function edited(next) {
    findings = [];
    runner?.run(next, plainValues(overrides));
    onsource?.(next);
  }

  /** @param {ParamValues} values the panel's */
  function valuesChanged(values) {
    runner?.run(value, values, { now: true });
  }

  /** @param {Problem | ConsoleLine} place a problem or a console line with a line, clicked */
  function reveal(place) {
    if (place.line !== null) editor?.reveal(place.line, place.column ?? 1);
  }

  /** @param {ExportFormat} format */
  async function exportChosen(format) {
    if (!core) return;
    try {
      const bytes = await core.build(value, { format, params: plainValues(overrides) });
      download(bytes, `${name}.${format}`);
      notice = '';
    } catch (error) {
      notice = `The ${format.toUpperCase()} wasn't made: ${errorText(error)}`;
    }
  }

  /** @param {Blob} image */
  function screenshot(image) {
    download(image, `${name}.png`);
  }
</script>

<div
  class="kc-playground"
  bind:clientWidth={width}
  style:--editor-width="{editorWidth}px"
  style:--params-width="{paramsWidth}px"
>
  <section class="code" aria-label="Script">
    <Editor bind:value bind:editor findings={marks} label={name} onchange={edited} />
    {#if notice}<p class="notice" role="alert">{notice}</p>{/if}
  </section>
  <Splitter
    bind:size={editorWidth}
    min={240}
    max={width > 0 ? width - (paramsShown ? paramsWidth : 0) - MIN_VIEW : undefined}
    label="Resize the script"
    onchange={(size) => settings.set(KEYS.editor, size)}
  />
  <section class="view" aria-label="Model">
    <div class="model">
      <ViewerPane
        model={ran?.preview.model ?? null}
        options={viewerOptions}
        bind:panel={() => panelOpen, (open) => settings.set(KEYS.panelOpen, open)}
        {status}
        {problems}
        onproblem={reveal}
        onscreenshot={screenshot}
        {settings}
        {shortcuts}
        bind:shortcutsOpen
      >
        {#snippet actions()}
          <ExportMenu kind={ran?.preview.model.kind ?? 'none'} onexport={exportChosen} />
          {@render hostActions?.()}
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
    </div>
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
      onreveal={reveal}
      onclear={() => (consoleLines = [])}
    />
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
    <aside class="params" id="{id}-params" aria-label="Parameters" hidden={!paramsOpen}>
      <ParamsPanel
        schema={header.params.schema}
        values={header.params.values}
        error={header.error}
        bind:overrides
        onchange={valuesChanged}
      />
    </aside>
  {/if}
</div>

<style>
  .kc-playground {
    display: flex;
    height: 100%;
    min-height: 0;
    font-family: var(--kc-font);
    font-size: var(--kc-font-size);
    color: var(--kc-fg);
    background: var(--kc-bg);
  }
  .code {
    position: relative;
    flex: none;
    width: var(--editor-width);
    min-width: 0;
    border-right: 1px solid var(--kc-border);
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
    width: var(--params-width);
    overflow: auto;
    padding: 0 var(--kc-gap) var(--kc-gap);
    border-left: 1px solid var(--kc-border);
  }
  .notice {
    position: absolute;
    left: var(--kc-gap);
    right: var(--kc-gap);
    bottom: var(--kc-gap);
    margin: 0;
    padding: 4px var(--kc-gap);
    color: var(--kc-error);
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
    background: var(--kc-bg);
  }
  /* A narrow page: the script over the model, the parameters under it */
  @media (max-width: 800px) {
    .kc-playground {
      flex-direction: column;
    }
    /* Stacked, each the page's width: the columns' bars have nothing to resize */
    .kc-playground > :global(.kc-splitter.columns) {
      display: none;
    }
    .code {
      flex-basis: 40%;
      width: auto;
      border-right: none;
      border-bottom: 1px solid var(--kc-border);
    }
    .view {
      flex-basis: 60%;
      min-height: 20em;
    }
    .params {
      width: auto;
      border-left: none;
      border-top: 1px solid var(--kc-border);
    }
  }
</style>
