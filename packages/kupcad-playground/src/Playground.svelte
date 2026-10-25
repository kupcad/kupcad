<!--
  @component
  KupCAD in a page: the script in an editor beside its model, its parameters beside that, all run
  by the core compiled to WebAssembly, in a worker (runner.js says when). The editor marks what
  `check` finds and where the run failed or warned (marks.js); the viewer pane says how the run
  went and lists its problems, one clicked taking the editor there. A model is exported in any
  format the core writes, and the viewer's screenshot saved, as downloads. It keeps nothing of
  the page's: the page gives the script it starts with (`source`).
-->
<script>
  import { onMount, untrack } from 'svelte';
  import { Editor } from '@kupcad/editor/svelte';
  import { EXPORT_FORMATS } from '@kupcad/protocol';
  import { ParamsPanel, problemsOf, runStatusOf, ViewerPane } from '@kupcad/ui';
  import { createKupcadWorker } from '@kupcad/wasm';
  import { download } from './download.js';
  import { marksOf } from './marks.js';
  import { Runner } from './runner.js';

  /** @import { Editor as EditorClass } from '@kupcad/editor' */
  /** @import { ExportFormat, Finding, ParamValues, Preview } from '@kupcad/protocol/types' */
  /** @import { Problem } from '@kupcad/ui' */
  /** @import { ViewerOptions } from '@kupcad/viewer/types' */
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
   */

  /** @type {Props} */
  let { source = '', name = 'model', kupcad, wasm, viewerOptions = {} } = $props();

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

  onMount(() => {
    const made = kupcad ? null : createKupcadWorker(wasm ? { wasm } : {});
    core = kupcad ?? made;
    runner = new Runner(/** @type {KupcadApi} */ (core), {
      onfindings: (next, of) => {
        if (of === value) findings = next;
      },
      onpreview: (preview, of) => {
        ran = { preview, source: of };
        notice = '';
      },
      onerror: (error) => (notice = whyOf(error)),
    });
    runner.run(value, {}, { now: true });
    return () => {
      runner?.dispose();
      made?.terminate();
    };
  });

  /** @param {string} next the user's script */
  function edited(next) {
    findings = [];
    runner?.run(next, $state.snapshot(overrides));
  }

  /** @param {ParamValues} values the panel's */
  function valuesChanged(values) {
    runner?.run(value, values, { now: true });
  }

  /** @param {Problem} problem one with a line, clicked */
  function revealProblem(problem) {
    if (problem.line !== null) editor?.reveal(problem.line, problem.column ?? 1);
  }

  /** @param {Event & { currentTarget: HTMLSelectElement }} event */
  async function exportChosen(event) {
    const format = /** @type {ExportFormat} */ (event.currentTarget.value);
    event.currentTarget.value = '';
    if (!core || !format) return;
    try {
      const bytes = await core.build(value, { format, params: $state.snapshot(overrides) });
      download(bytes, `${name}.${format}`);
      notice = '';
    } catch (error) {
      notice = `The ${format.toUpperCase()} wasn't made: ${whyOf(error)}`;
    }
  }

  /** @param {Blob} image */
  function screenshot(image) {
    download(image, `${name}.png`);
  }

  /** @param {unknown} error */
  function whyOf(error) {
    return error instanceof Error ? error.message : String(error);
  }
</script>

<div class="kc-playground">
  <section class="code" aria-label="Script">
    <Editor bind:value bind:editor findings={marks} label={name} onchange={edited} />
    {#if notice}<p class="notice" role="alert">{notice}</p>{/if}
  </section>
  <section class="view" aria-label="Model">
    <ViewerPane
      model={ran?.preview.model ?? null}
      options={viewerOptions}
      {status}
      {problems}
      onproblem={revealProblem}
      onscreenshot={screenshot}
    >
      {#snippet actions()}
        <select class="kc-control" aria-label="Export" onchange={exportChosen}>
          <option value="" selected disabled>Export…</option>
          {#each EXPORT_FORMATS as choice (choice.format)}
            <option value={choice.format} title={choice.detail}>{choice.label}</option>
          {/each}
        </select>
      {/snippet}
    </ViewerPane>
  </section>
  {#if header && parameters.length > 0}
    <aside class="params" aria-label="Parameters">
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
    flex: 2 1 0;
    min-width: 0;
    border-right: 1px solid var(--kc-border);
  }
  .view {
    flex: 3 1 0;
    min-width: 0;
  }
  .params {
    width: 16em;
    overflow: auto;
    padding: var(--kc-gap);
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
    .code {
      flex-basis: 40%;
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
