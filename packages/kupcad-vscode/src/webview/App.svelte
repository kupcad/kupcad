<!--
  @component
  The viewer's page: the model of the document the extension says it shows, as the language
  server's socket sends it, with its parameters beside it. The panel's values go to the
  extension, which gives them to the server; the frame that comes back is of a run with them.
  What the run warned of without a line (the rest are in the Problems view), and why it failed,
  are shown over the model.
-->
<script>
  import { onMount } from 'svelte';
  import { ParamsPanel, ViewerPane } from '@kupcad/ui';
  import { toBase64 } from './base64.js';
  import { connectViewport } from './socket.js';

  /** @import { ParamValues, Preview, ShownDocument } from '@kupcad/protocol/types' */
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
  /** The panel's values of each document shown, by URI. */
  const valuesOf = new Map();

  const header = $derived(preview?.header ?? null);
  const parameters = $derived(header?.params.schema.parameters ?? []);
  /** The warnings with no line: those with one are diagnostics, in the Problems view. */
  const unplaced = $derived(header?.warnings.filter((w) => w.line === null) ?? []);
  const status = $derived(statusOf());

  function statusOf() {
    if (!viewportUrl) return 'Waiting for the KupCAD language server…';
    if (!connected) return 'Connecting to the language server…';
    if (!shown) return 'Open a .kup file to see its model.';
    if (!preview) return `Running ${shown.name}…`;
    return null;
  }

  onMount(() => {
    const stopListening = host.listen((message) => {
      if (message.type === 'document') {
        if (message.document?.uri !== shown?.uri) preview = null;
        shown = message.document;
        overrides = (shown && valuesOf.get(shown.uri)) ?? {};
      } else {
        valuesOf.set(message.uri, message.values);
        if (message.uri === shown?.uri) overrides = message.values;
      }
    });
    const disconnect = viewportUrl
      ? connect(viewportUrl, {
          open: () => host.post({ type: 'ready' }),
          state: (open) => (connected = open),
          frame: (next) => {
            // The socket sends every viewer the shown document's frame: one of another is late
            if (shown && next.header.document !== shown.uri) return;
            preview = next;
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
    if (!shown) return;
    valuesOf.set(shown.uri, values);
    host.post({ type: 'setParams', uri: shown.uri, values });
  }

  /** @param {Blob} image */
  async function screenshot(image) {
    host.post({ type: 'screenshot', png: toBase64(new Uint8Array(await image.arrayBuffer())) });
  }

  /** @param {unknown} error */
  function failed(error) {
    host.post({ type: 'problem', message: error instanceof Error ? error.message : String(error) });
  }
</script>

<main class="kc-app">
  <section class="view">
    <ViewerPane
      model={preview?.model ?? null}
      options={viewerOptions}
      onscreenshot={screenshot}
      onerror={failed}
    />
    {#if status}
      <p class="status">{status}</p>
    {/if}
    {#if header?.error || unplaced.length > 0}
      <div class="problems" role="alert">
        {#if header?.error}
          <p class="error">
            {header.error.message}{#if header.error.line !== null}
              (line {header.error.line}){/if}
          </p>
        {/if}
        {#each unplaced as warning, index (index)}
          <p class="warning">{warning.message}</p>
        {/each}
      </div>
    {/if}
  </section>
  {#if header && parameters.length > 0}
    <aside class="params" aria-label="Parameters">
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
  .status {
    position: absolute;
    inset: 50% 0 auto;
    margin: 0;
    text-align: center;
    color: var(--kc-muted);
    pointer-events: none;
  }
  .problems {
    position: absolute;
    left: var(--kc-gap);
    right: var(--kc-gap);
    bottom: var(--kc-gap);
    padding: 4px var(--kc-gap);
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
    background: var(--kc-bg);
  }
  .problems p {
    margin: 2px 0;
  }
  .error {
    color: var(--kc-error);
  }
  .warning {
    color: var(--kc-muted);
  }
</style>
