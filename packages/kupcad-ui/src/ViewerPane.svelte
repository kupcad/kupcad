<!--
  @component
  The viewer, its view cube in a corner and the view's controls in a column over it (fit, the
  render mode, edges, the floor, perspective, the views), what is under the pointer by it (the
  part, its copies, volume and size, the face and its area), a section through the model, a
  screenshot and a host's own actions (which take the controls' look by .kc-control) in a bar
  above, the model's parts beside it (a click on one selecting its copies as a click in the
  viewer does), and how its run went below. Themed by the --kc-viewer-* tokens unless given a
  `theme`.
-->
<script>
  import { onMount } from 'svelte';
  import { RENDER_MODES } from '@kupcad/viewer';
  import { Viewer } from '@kupcad/viewer/svelte';
  import { faceLine, partMeasures, partTitle } from './measures.js';
  import { describeRun } from './run-status.js';
  import { watchTokens } from './theme.js';

  /** @import { Model, Part } from '@kupcad/protocol/types' */
  /** @import { Axis, Bounds, Environment, HoverDetail, RenderMode, Section, Theme, View, ViewerOptions } from '@kupcad/viewer/types' */
  /** @import { Viewer as ViewerClass } from '@kupcad/viewer' */
  /** @import { Snippet } from 'svelte' */
  /** @import { RunStatus } from './run-status.js' */

  /**
   * @typedef {object} Props
   * @property {Model | null} [model]
   * @property {Theme} [theme] by default the --kc-viewer-* tokens', followed as they change
   * @property {string | null} [selected] the part selected; bindable
   * @property {ViewerClass | null} [viewer] the viewer, once mounted; bindable
   * @property {ViewerOptions} [options] what the viewer is made with
   * @property {(image: Blob) => void} [onscreenshot] a screenshot taken; without it, no button
   * @property {Snippet} [actions] a host's own buttons, at the toolbar's end (export)
   * @property {RunStatus | null} [status] how the run shown went, or none to say
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
    status = null,
    onerror,
  } = $props();

  /**
   * Each render mode's button: its text, and its name when the text is short of it.
   * @type {Record<RenderMode, { text: string, name: string }>}
   */
  const MODES = {
    solid: { text: 'Solid', name: 'Solid' },
    xray: { text: 'X-ray', name: 'X-ray' },
    wireframe: { text: 'Wire', name: 'Wireframe' },
  };
  /**
   * The views with a button: the cube, and the keys, give the rest.
   * @type {{ view: View, text: string }[]}
   */
  const VIEW_BUTTONS = [
    { view: 'iso', text: 'Iso' },
    { view: 'top', text: 'Top' },
    { view: 'front', text: 'Front' },
    { view: 'right', text: 'Right' },
  ];
  /** @type {Axis[]} */
  const AXES = ['x', 'y', 'z'];
  /** A section's slider takes this many steps across the model. */
  const SECTION_STEPS = 200;
  /** The tooltip stands this far right of and below the pointer. */
  const TOOLTIP_OFFSET_PX = 14;

  /** @type {HTMLDivElement} */
  let root;
  let tokenTheme = $state(/** @type {Theme | undefined} */ (undefined));
  let renderMode = $state(/** @type {RenderMode} */ ('solid'));
  let edges = $state(true);
  let orthographic = $state(false);
  /** The named view the viewer looks from: none once it was turned by hand. */
  let view = $state(/** @type {View | null} */ ('iso'));
  let environment = $state(/** @type {Environment} */ ('grid'));
  let sectioned = $state(false);
  let axis = $state(/** @type {Axis} */ ('z'));
  let offset = $state(0);
  let bounds = $state(/** @type {Bounds | null} */ (null));
  /** The model shown is a solid's: a drawing isn't cut, and offered no section. */
  let solid = $state(false);
  /** What the pointer is over, as the viewer says. */
  let hovered = $state(/** @type {HoverDetail} */ (null));

  const parts = $derived(/** @type {Part[]} */ (model?.kind === '3d' ? model.parts : []));
  const along = $derived(AXES.indexOf(axis));
  const span = $derived(
    solid && bounds ? { min: bounds.min[along], max: bounds.max[along] } : null,
  );
  const section = $derived(sectioned && span ? { axis, offset } : null);
  const statusText = $derived(status ? describeRun(status) : '');
  const hoveredPart = $derived(parts.find((part) => part.name === hovered?.part) ?? null);
  const hoveredMeasures = $derived(hoveredPart ? partMeasures(hoveredPart) : null);

  onMount(() => watchTokens(root, (next) => (tokenTheme = next)));

  // The view follows the viewer's (its keys, and a turn by hand, change it too), the section
  // too (the wheel with Option moves it), and the tooltip what the pointer is over
  $effect(() => {
    const shown = viewer;
    if (!shown) return;
    shown.addEventListener('view', followView);
    shown.addEventListener('section', followSection);
    shown.addEventListener('hover', followHover);
    return () => {
      shown.removeEventListener('view', followView);
      shown.removeEventListener('section', followSection);
      shown.removeEventListener('hover', followHover);
    };
  });

  /** @param {Event} event the viewer's 'view' */
  function followView(event) {
    view = /** @type {CustomEvent<{ view: View | null }>} */ (event).detail.view;
  }

  /** @param {Event} event the viewer's 'section' */
  function followSection(event) {
    const moved = /** @type {CustomEvent<{ section: Section }>} */ (event).detail.section;
    sectioned = true;
    axis = moved.axis;
    offset = moved.offset;
  }

  /** @param {Event} event the viewer's 'hover' */
  function followHover(event) {
    hovered = /** @type {CustomEvent<HoverDetail>} */ (event).detail;
  }

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

  /**
   * The floor `floor` is, or none when it is already: its button toggles it.
   * @param {Environment} floor
   */
  function toggleFloor(floor) {
    environment = environment === floor ? 'none' : floor;
  }
</script>

<div class="kc-viewer-pane" bind:this={root}>
  <div class="toolbar">
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
    <span class="spacer"></span>
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
        {edges}
        projection={orthographic ? 'orthographic' : 'perspective'}
        {section}
        bind:selected
        bind:viewer
        {options}
        onmodel={modelShown}
        {onerror}
      />
      <div class="controls" role="toolbar" aria-label="View" aria-orientation="vertical">
        <button type="button" class="kc-control" onclick={() => viewer?.fit()}>Fit</button>
        <div class="group" role="group" aria-label="Render mode">
          {#each RENDER_MODES as mode (mode)}
            <button
              type="button"
              class="kc-control"
              aria-label={MODES[mode].name}
              aria-pressed={renderMode === mode}
              onclick={() => (renderMode = mode)}
            >
              {MODES[mode].text}
            </button>
          {/each}
        </div>
        <div class="group">
          <button
            type="button"
            class="kc-control"
            aria-pressed={edges}
            onclick={() => (edges = !edges)}
          >
            Edges
          </button>
          <button
            type="button"
            class="kc-control"
            aria-pressed={environment === 'grid'}
            onclick={() => toggleFloor('grid')}
          >
            Grid
          </button>
          <button
            type="button"
            class="kc-control"
            aria-pressed={environment === 'plate'}
            onclick={() => toggleFloor('plate')}
          >
            Plate
          </button>
          <button
            type="button"
            class="kc-control"
            aria-label="Perspective"
            aria-pressed={!orthographic}
            onclick={() => (orthographic = !orthographic)}
          >
            Persp
          </button>
        </div>
        <div class="group" role="group" aria-label="Views">
          {#each VIEW_BUTTONS as button (button.view)}
            <button
              type="button"
              class="kc-control"
              aria-pressed={view === button.view}
              onclick={() => viewer?.setCamera({ view: button.view })}
            >
              {button.text}
            </button>
          {/each}
        </div>
      </div>
      {#if hovered && (hovered.part || hovered.face)}
        <div
          class="tooltip"
          role="tooltip"
          style:left="{hovered.x + TOOLTIP_OFFSET_PX}px"
          style:top="{hovered.y + TOOLTIP_OFFSET_PX}px"
        >
          {#if hovered.part}
            <p class="title">{hoveredPart ? partTitle(hoveredPart) : hovered.part}</p>
            {#if hoveredMeasures}<p>{hoveredMeasures}</p>{/if}
          {/if}
          {#if hovered.face}<p>{faceLine(hovered.face)}</p>{/if}
        </div>
      {/if}
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
  {#if status}
    <div class="status" role="status">
      <span class="dot {status.state}"></span>
      {statusText}
    </div>
  {/if}
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
  .spacer {
    flex: 1;
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
    position: relative;
    flex: 1;
    min-width: 0;
  }
  /* Under the view cube (8px from the top, 96px high) */
  .controls {
    position: absolute;
    top: 112px;
    right: 8px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    width: 64px;
  }
  .group {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .controls button {
    width: 100%;
    padding: 2px 4px;
    font-size: 0.92em;
  }
  .tooltip {
    position: absolute;
    max-width: 22em;
    padding: 4px 8px;
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
    background: var(--kc-bg);
    pointer-events: none;
  }
  .tooltip p {
    margin: 0;
    white-space: nowrap;
  }
  .tooltip .title {
    font-weight: 600;
  }
  .status {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 2px var(--kc-gap);
    border-top: 1px solid var(--kc-border);
    color: var(--kc-muted);
  }
  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--kc-muted);
  }
  .dot.ready {
    background: var(--kc-accent);
  }
  .dot.failed {
    background: var(--kc-error);
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
