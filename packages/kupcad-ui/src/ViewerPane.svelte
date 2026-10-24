<!--
  @component
  The viewer with its toolbar (render mode, view, projection, floor, a section through the
  model, fit, screenshot, and a host's own actions, which take the toolbar's look by .kc-control) and the model's parts, a click on one selecting its copies as a click
  in the viewer does. Themed by the --kc-viewer-* tokens unless given a `theme`.
-->
<script>
  import { onMount } from 'svelte';
  import { RENDER_MODES, VIEW_NAMES } from '@kupcad/viewer';
  import { Viewer } from '@kupcad/viewer/svelte';
  import { watchTokens } from './theme.js';

  /** @import { Model, Part } from '@kupcad/protocol/types' */
  /** @import { Axis, Bounds, Environment, RenderMode, Theme, View, ViewerOptions } from '@kupcad/viewer/types' */
  /** @import { Viewer as ViewerClass } from '@kupcad/viewer' */
  /** @import { Snippet } from 'svelte' */

  /**
   * @typedef {object} Props
   * @property {Model | null} [model]
   * @property {Theme} [theme] by default the --kc-viewer-* tokens', followed as they change
   * @property {string | null} [selected] the part selected; bindable
   * @property {ViewerClass | null} [viewer] the viewer, once mounted; bindable
   * @property {ViewerOptions} [options] what the viewer is made with
   * @property {(image: Blob) => void} [onscreenshot] a screenshot taken; without it, no button
   * @property {Snippet} [actions] a host's own buttons, at the toolbar's end (export, print)
   * @property {(error: unknown) => void} [onerror] a model the viewer couldn't show
   */

  /** @type {Props} */
  let {
    model = null,
    theme,
    selected = $bindable(null),
    viewer = $bindable(null),
    options = {},
    onscreenshot,
    actions,
    onerror,
  } = $props();

  /** @type {Record<RenderMode, string>} */
  const MODE_LABELS = { solid: 'Solid', xray: 'X-ray', wireframe: 'Wireframe' };
  /** @type {Record<Environment, string>} */
  const FLOOR_LABELS = { grid: 'Grid', plate: 'Plate', none: 'None' };
  /** @type {Axis[]} */
  const AXES = ['x', 'y', 'z'];
  /** A section's slider takes this many steps across the model. */
  const SECTION_STEPS = 200;

  /** @type {HTMLDivElement} */
  let root;
  let tokenTheme = $state(/** @type {Theme | undefined} */ (undefined));
  let renderMode = $state(/** @type {RenderMode} */ ('solid'));
  let orthographic = $state(false);
  let view = $state(/** @type {View} */ ('iso'));
  let environment = $state(/** @type {Environment} */ ('grid'));
  let sectioned = $state(false);
  let axis = $state(/** @type {Axis} */ ('z'));
  let offset = $state(0);
  let bounds = $state(/** @type {Bounds | null} */ (null));
  /** The model shown is a solid's: a drawing isn't cut, and offered no section. */
  let solid = $state(false);

  const parts = $derived(/** @type {Part[]} */ (model?.kind === '3d' ? model.parts : []));
  const along = $derived(AXES.indexOf(axis));
  const span = $derived(
    solid && bounds ? { min: bounds.min[along], max: bounds.max[along] } : null,
  );
  const section = $derived(sectioned && span ? { axis, offset } : null);

  onMount(() => watchTokens(root, (next) => (tokenTheme = next)));

  /**
   * A model is shown: the toolbar says how the viewer looks at it (a drawing is seen from the
   * top, orthographic), and the section is put across its middle, unless one is on where the
   * model still reaches (an edit of the script keeps the cut where the user put it).
   * @param {ViewerClass} shown
   */
  function modelShown(shown) {
    orthographic = shown.projection === 'orthographic';
    view = shown.view;
    bounds = shown.bounds;
    solid = shown.kind === '3d';
    const kept = sectioned && span && offset >= span.min && offset <= span.max;
    if (!kept) centreSection();
  }

  /** Puts the section across the middle of the model, along its axis. */
  function centreSection() {
    if (span) offset = (span.min + span.max) / 2;
  }

  async function screenshot() {
    const image = await viewer?.screenshot();
    if (image) onscreenshot?.(image);
  }
</script>

<div class="kc-viewer-pane" bind:this={root}>
  <div class="toolbar">
    <div class="segments" role="group" aria-label="Render mode">
      {#each RENDER_MODES as mode (mode)}
        <button
          type="button"
          class="kc-control"
          aria-pressed={renderMode === mode}
          onclick={() => (renderMode = mode)}
        >
          {MODE_LABELS[mode]}
        </button>
      {/each}
    </div>
    <label>
      View
      <select class="kc-control" bind:value={view} onchange={() => viewer?.setCamera({ view })}>
        {#each VIEW_NAMES as view (view)}
          <option value={view}>{view}</option>
        {/each}
      </select>
    </label>
    <label><input type="checkbox" bind:checked={orthographic} /> Orthographic</label>
    <label>
      Floor
      <select class="kc-control" bind:value={environment}>
        {#each Object.entries(FLOOR_LABELS) as [value, label] (value)}
          <option {value}>{label}</option>
        {/each}
      </select>
    </label>
    <label><input type="checkbox" bind:checked={sectioned} disabled={!span} /> Section</label>
    {#if sectioned && span}
      <select
        class="kc-control"
        aria-label="Section axis"
        bind:value={axis}
        onchange={centreSection}
      >
        {#each AXES as name (name)}
          <option value={name}>{name.toUpperCase()}</option>
        {/each}
      </select>
      <input
        type="range"
        aria-label="Section offset"
        min={span.min}
        max={span.max}
        step={(span.max - span.min) / SECTION_STEPS || 'any'}
        bind:value={offset}
      />
    {/if}
    <button type="button" class="kc-control" onclick={() => viewer?.fit()}>Fit</button>
    {#if onscreenshot}
      <button type="button" class="kc-control" onclick={screenshot}>Screenshot</button>
    {/if}
    {@render actions?.()}
  </div>
  <div class="body">
    <div class="canvas">
      <Viewer
        {model}
        theme={theme ?? tokenTheme}
        {environment}
        {renderMode}
        projection={orthographic ? 'orthographic' : 'perspective'}
        {section}
        bind:selected
        bind:viewer
        {options}
        onmodel={modelShown}
        {onerror}
      />
    </div>
    {#if parts.length > 0}
      <ul class="parts" aria-label="Parts">
        {#each parts as part (part.name)}
          <li>
            <button
              type="button"
              aria-pressed={selected === part.name}
              onclick={() => (selected = selected === part.name ? null : part.name)}
            >
              <span class="swatch" style:background={part.color ?? 'var(--kc-muted)'}></span>
              <span class="name">{part.name}</span>
              {#if part.count > 1}<span class="count">×{part.count}</span>{/if}
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</div>

<style>
  .kc-viewer-pane {
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
    font-family: var(--kc-font);
    font-size: var(--kc-font-size);
    color: var(--kc-fg);
    background: var(--kc-bg);
  }
  .toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--kc-gap);
    padding: 4px var(--kc-gap);
    border-bottom: 1px solid var(--kc-border);
  }
  .segments {
    display: flex;
  }
  .segments button {
    border-radius: 0;
  }
  .segments button:first-child {
    border-radius: var(--kc-radius) 0 0 var(--kc-radius);
  }
  .segments button:last-child {
    border-radius: 0 var(--kc-radius) var(--kc-radius) 0;
  }
  label {
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .body {
    display: flex;
    flex: 1;
    min-height: 0;
  }
  .canvas {
    flex: 1;
    min-width: 0;
  }
  .parts {
    list-style: none;
    margin: 0;
    padding: var(--kc-gap);
    min-width: 10em;
    overflow: auto;
    border-left: 1px solid var(--kc-border);
  }
  .parts button {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    font: inherit;
    color: var(--kc-fg);
    border: 1px solid transparent;
    border-radius: var(--kc-radius);
    padding: 2px 8px;
    background: none;
    text-align: left;
    cursor: pointer;
  }
  .parts button[aria-pressed='true'] {
    color: var(--kc-accent-fg);
    background: var(--kc-accent);
    border-color: var(--kc-accent);
  }
  .swatch {
    width: 10px;
    height: 10px;
    border-radius: 2px;
    flex: none;
  }
  .name {
    flex: 1;
  }
  .count {
    color: var(--kc-muted);
  }
  [aria-pressed='true'] .count {
    color: inherit;
  }
</style>
