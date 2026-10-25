<!--
  @component
  The viewer's page: the model of the document the extension says it shows, as the language
  server's socket sends it, with its parameters beside it. The panel's values go to the
  extension, which gives them to the server; the frame that comes back is of a run with them.
  Why the run failed and what it warned of are listed under the model: one with a line, clicked,
  is shown in the script's editor. The document's presets are above its parameters: one applied,
  or the panel's values saved as one.
-->
<script>
  import { onMount } from 'svelte';
  import { errorText } from '@kupcad/protocol';
  import { ParamsPanel, problemsOf, runStatusOf, ViewerPane } from '@kupcad/ui';
  import { toBase64 } from './base64.js';
  import { connectViewport } from './socket.js';

  /** @import { ParamValues, Preview, ShownDocument } from '@kupcad/protocol/types' */
  /** @import { Problem } from '@kupcad/ui' */
  /** @import { ViewerOptions } from '@kupcad/viewer/types' */
  /** @import { Host } from './bridge.js' */

  /**
   * @typedef {object} Props
   * @property {Host} host
   * @property {string | null} viewportUrl the language server's socket, once it is up
   * @property {typeof connectViewport} [connect]
   * @property {ViewerOptions} [viewerOptions] what the viewer is made with
   */

  /** @type {Props} */
  let { host, viewportUrl, connect = connectViewport, viewerOptions = {} } = $props();

  let shown = $state(/** @type {ShownDocument | null} */ (null));
  let preview = $state(/** @type {Preview | null} */ (null));
  let connected = $state(false);
  let overrides = $state(/** @type {ParamValues} */ ({}));
  let presets = $state(/** @type {string[]} */ ([]));
  /** Why the viewer can't show the frame's model, until the next frame. */
  let unshown = $state('');

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
      if (message.type === 'document') {
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
    const disconnect = viewportUrl
      ? connect(viewportUrl, {
          open: () => host.post({ type: 'ready' }),
          state: (open) => (connected = open),
          frame: (next) => {
            // The socket sends every viewer the frame of the document the server shows: one of
            // another (late, or with none shown here) isn't this page's
            if (next.header.document !== shown?.uri) return;
            preview = next;
            unshown = '';
          },
          problem: (message) => host.post({ type: 'problem', message }),
        })
      : () => {};
    return () => {
      stopListening();
      disconnect();
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
    if (shown)
      host.post({ type: 'savePreset', uri: shown.uri, values: $state.snapshot(overrides) });
  }

  /** Asks the host to export the shown document, with its values. */
  function exportShown() {
    if (shown) host.post({ type: 'export', uri: shown.uri });
  }

  /**
   * Asks the host to show the script where `problem` was, in its editor.
   * @param {Problem} problem
   */
  function revealProblem(problem) {
    if (!shown || problem.line === null) return;
    host.post({ type: 'reveal', uri: shown.uri, line: problem.line, column: problem.column ?? 1 });
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

<main class="kc-app">
  <section class="view">
    <ViewerPane
      model={preview?.model ?? null}
      options={viewerOptions}
      status={run}
      {problems}
      onproblem={revealProblem}
      onscreenshot={screenshot}
      onerror={failed}
    >
      {#snippet actions()}
        {#if shown}
          <button type="button" class="kc-control" onclick={exportShown}>Export…</button>
        {/if}
      {/snippet}
    </ViewerPane>
    {#if status}
      <p class="notice">{status}</p>
    {/if}
  </section>
  {#if header && parameters.length > 0}
    <aside class="params" aria-label="Parameters">
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
      <ParamsPanel
        schema={header.params.schema}
        values={header.params.values}
        error={header.error}
        bind:overrides
        onchange={changed}
      />
    </aside>
  {/if}
</main>

<style>
  :global(html),
  :global(body),
  :global(#app) {
    height: 100%;
    margin: 0;
    padding: 0;
    background: var(--kc-bg);
  }
  .kc-app {
    display: flex;
    height: 100%;
    font-family: var(--kc-font);
    font-size: var(--kc-font-size);
    color: var(--kc-fg);
  }
  .view {
    position: relative;
    flex: 1;
    min-width: 0;
  }
  .params {
    width: 18em;
    overflow: auto;
    padding: var(--kc-gap);
    border-left: 1px solid var(--kc-border);
  }
  .presets {
    display: flex;
    gap: 4px;
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
