<!--
  @component
  The viewer, its view cube in a corner and what is under the pointer by it (the part, its
  copies, volume and size, the face and its area). Beside it a panel, which the toolbar's Panel
  button hides: the view's controls (the render mode; edges, axes, the floor; fit, perspective,
  the views) over the model's parts (a click on one selecting its copies, as a click in the
  viewer does), half of it each. A bar above: a section through the model, a screenshot and a
  host's own actions (which take the controls' look by .kc-control), the Panel button, and a
  host's toggles of its own panes beside this one. Below: how its run went, and what it said
  went wrong, one with a line clicked given to the host (`onproblem`), and a button that lists
  the keyboard shortcuts (the host's own, then the viewer's). How the view looks (the render mode,
  edges, axes, floor, projection) is the host's `settings`' view.* keys (`viewChoice`), written
  as the person chooses, and followed as they are set wherever from. Themed by the
  --kc-viewer-* tokens unless given a `theme`.
-->
<script>
  import { onMount } from 'svelte';
  import { RENDER_MODES } from './viewer/index.js';
  import Viewer from './Viewer.svelte';
  import { faceLine, partMeasures, partTitle } from './measures.js';
  import { fillOf } from './range.js';
  import { describeRun } from './run-status.js';
  import { memorySettings } from './settings.js';
  import { VIEWER_SHORTCUTS } from './shortcuts.js';
  import ShortcutsDialog from './ShortcutsDialog.svelte';
  import { watchTokens } from './theme.js';
  import { VIEW_KEYS, viewChoice } from './view-settings.js';

  /** @import { Model, Part } from '@kupcad/protocol/types' */
  /** @import { Axis, Bounds, Environment, HoverDetail, RenderMode, Section, Theme, View, ViewerOptions } from './viewer/types.js' */
  /** @import { Viewer as ViewerClass } from './viewer/index.js' */
  /** @import { Snippet } from 'svelte' */
  /** @import { Problem, RunStatus } from './run-status.js' */
  /** @import { Settings } from './settings.js' */
  /** @import { ShortcutGroup } from './shortcuts.js' */

  /**
   * @typedef {object} Props
   * @property {Model | null} [model]
   * @property {Theme} [theme] by default the --kc-viewer-* tokens', followed as they change
   * @property {string | null} [selected] the part selected; bindable
   * @property {ViewerClass | null} [viewer] the viewer, once mounted; bindable
   * @property {boolean} [panel] whether the panel beside the viewer shows (the Panel button's);
   *   bindable, for a host to keep
   * @property {ViewerOptions} [options] what the viewer is made with
   * @property {(image: Blob) => void} [onscreenshot] a screenshot taken; without it, no button
   * @property {Snippet} [actions] a host's own buttons, at the toolbar's end (export)
   * @property {Snippet} [toggles] a host's toggles of its panes beside this one (its
   *   parameters'), after the Panel button: at the end nearest them
   * @property {RunStatus | null} [status] how the run shown went, or none to say
   * @property {Problem[]} [problems] what the run shown said went wrong (`problemsOf(header)`)
   * @property {(problem: Problem) => void} [onproblem] a problem with a line clicked: the host
   *   shows the script there; without it, none can be clicked
   * @property {(error: unknown) => void} [onerror] a model the viewer couldn't show
   * @property {Settings} [settings] where how the view looks is kept (`VIEW_KEYS`); by default
   *   the page's memory
   * @property {readonly ShortcutGroup[]} [shortcuts] the host's own, listed before the viewer's
   * @property {boolean} [shortcutsOpen] whether the shortcuts' dialog shows; bindable, for a
   *   host to open it (a menu's item)
   */

  /** @type {Props} */
  let {
    model = null,
    theme,
    selected = $bindable(null),
    viewer = $bindable(null),
    panel = $bindable(true),
    options = {},
    onscreenshot,
    actions,
    toggles,
    status = null,
    problems = [],
    onproblem,
    onerror,
    settings = memorySettings(),
    shortcuts = [],
    shortcutsOpen = $bindable(false),
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
  /** What a problem's kind is called. @type {Record<Problem['severity'], string>} */
  const SEVERITIES = { error: 'Error', warning: 'Warning' };
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

  /** The panel's and its groups' ids: this pane's own. */
  const id = $props.id();

  /** @type {HTMLDivElement} */
  let root;
  let tokenTheme = $state(/** @type {Theme | undefined} */ (undefined));
  // As the settings have them, each read by its own key, and set as the person chooses
  const renderMode = $derived(viewChoice(settings, 'renderMode'));
  const edges = $derived(viewChoice(settings, 'edges'));
  const axes = $derived(viewChoice(settings, 'axes'));
  const environment = $derived(viewChoice(settings, 'environment'));
  /**
   * How a drawing shown is seen (from the top, orthographic) until the person chooses: no choice
   * of theirs, so kept apart from the settings; null while the view is as chosen.
   */
  let drawingOrthographic = $state(/** @type {boolean | null} */ (null));
  const orthographic = $derived(
    drawingOrthographic ?? viewChoice(settings, 'projection') === 'orthographic',
  );
  /** The named view the viewer looks from: none once it was turned by hand. */
  let view = $state(/** @type {View | null} */ ('iso'));
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
  const shortcutGroups = $derived([...shortcuts, VIEWER_SHORTCUTS]);

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
   * A model is shown: the toolbar says how the viewer looks at it, and the section is put across
   * its middle, unless one is on where the model still reaches (an edit of the script keeps the
   * cut where the user put it). A drawing is seen from the top, orthographic, the choice kept for
   * the next solid; a solid as chosen, though the viewer, after a drawing, brings back how it saw
   * the last one (the choice may have changed since).
   * @param {ViewerClass} shown
   */
  function modelShown(shown) {
    if (shown.kind === '3d') {
      const chosen = viewChoice(settings, 'projection');
      if (shown.projection !== chosen) shown.setCamera({ projection: chosen });
      drawingOrthographic = null;
    } else {
      drawingOrthographic = shown.projection === 'orthographic';
    }
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
    settings.set(VIEW_KEYS.environment, environment === floor ? 'none' : floor);
  }

  /**
   * Orthographic or not, as the person chose: what the settings keep, and the view, a drawing's
   * too, shows.
   * @param {boolean} chosen
   */
  function chooseOrthographic(chosen) {
    drawingOrthographic = null;
    settings.set(VIEW_KEYS.projection, chosen ? 'orthographic' : 'perspective');
  }
</script>

<div class="kc-viewer-pane" bind:this={root}>
  <div class="toolbar">
    <label
      ><input class="kc-check" type="checkbox" bind:checked={sectioned} disabled={!span} /> Section</label
    >
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
        class="kc-range"
        type="range"
        aria-label="Section offset"
        min={span.min}
        max={span.max}
        step={(span.max - span.min) / SECTION_STEPS || 'any'}
        style:--kc-range-fill={fillOf(offset, span.min, span.max)}
        bind:value={offset}
      />
    {/if}
    <span class="spacer"></span>
    {#if onscreenshot}
      <button type="button" class="kc-control" onclick={screenshot}>Screenshot</button>
    {/if}
    {@render actions?.()}
    <button
      type="button"
      class="kc-control"
      aria-controls="{id}-panel"
      aria-expanded={panel}
      onclick={() => (panel = !panel)}
    >
      Panel
    </button>
    {@render toggles?.()}
  </div>
  <div class="body">
    <div class="canvas">
      <Viewer
        {model}
        theme={theme ?? tokenTheme}
        {environment}
        {renderMode}
        {edges}
        {axes}
        projection={orthographic ? 'orthographic' : 'perspective'}
        {section}
        bind:selected
        bind:viewer
        {options}
        onmodel={modelShown}
        {onerror}
      />
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
    <aside class="panel" id="{id}-panel" aria-label="View and parts" hidden={!panel}>
      <div class="controls" role="toolbar" aria-label="View" aria-orientation="vertical">
        <div class="group modes" role="group" aria-labelledby="{id}-mode">
          <p class="caption" id="{id}-mode">Render mode</p>
          {#each RENDER_MODES as mode (mode)}
            <button
              type="button"
              class="kc-control"
              aria-label={MODES[mode].name}
              aria-pressed={renderMode === mode}
              onclick={() => settings.set(VIEW_KEYS.renderMode, mode)}
            >
              {MODES[mode].text}
            </button>
          {/each}
        </div>
        <div class="group" role="group" aria-labelledby="{id}-show">
          <p class="caption" id="{id}-show">Show</p>
          <button
            type="button"
            class="kc-control"
            aria-pressed={edges}
            onclick={() => settings.set(VIEW_KEYS.edges, !edges)}
          >
            Edges
          </button>
          <button
            type="button"
            class="kc-control"
            aria-pressed={axes}
            onclick={() => settings.set(VIEW_KEYS.axes, !axes)}
          >
            Axes
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
        </div>
        <div class="group" role="group" aria-labelledby="{id}-camera">
          <p class="caption" id="{id}-camera">Camera</p>
          <button type="button" class="kc-control" onclick={() => viewer?.fit()}>Fit</button>
          <button
            type="button"
            class="kc-control"
            aria-label="Perspective"
            aria-pressed={!orthographic}
            onclick={() => chooseOrthographic(!orthographic)}
          >
            Persp
          </button>
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
      <div class="parts">
        <p class="caption" id="{id}-parts">Parts</p>
        {#if parts.length > 0}
          <ul aria-labelledby="{id}-parts">
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
        {:else}
          <p class="none">None</p>
        {/if}
      </div>
    </aside>
  </div>
  <div class="run">
    <div class="line">
      {#if status}
        <div class="status" role="status">
          <span class="dot {status.state}"></span>
          {statusText}
        </div>
      {/if}
      <button
        type="button"
        class="shortcuts"
        aria-label="Keyboard shortcuts"
        aria-haspopup="dialog"
        title="Keyboard shortcuts"
        onclick={() => (shortcutsOpen = true)}
      >
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <rect x="2.5" y="6" width="19" height="12" rx="2" />
          <path d="M6.5 10h1M10.5 10h1M14.5 10h1M17.5 10h.5M7.5 14h9" />
        </svg>
      </button>
    </div>
    {#if problems.length > 0}
      <ul class="problems" aria-label="Problems">
        {#each problems as problem, index (index)}
          <li class={problem.severity}>
            {#if onproblem && problem.line !== null}
              <button type="button" onclick={() => onproblem(problem)}>
                {@render said(problem)}
              </button>
            {:else}
              {@render said(problem)}
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </div>
  <ShortcutsDialog groups={shortcutGroups} bind:open={shortcutsOpen} />
</div>

{#snippet said(/** @type {Problem} */ problem)}
  <span class="severity">{SEVERITIES[problem.severity]}</span>
  <span class="message">{problem.message}</span>
  {#if problem.line !== null}<span class="place">line {problem.line}</span>{/if}
{/snippet}

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
  /* The controls over the parts, half of it each */
  .panel {
    display: flex;
    flex-direction: column;
    width: 12em;
    min-height: 0;
    border-left: 1px solid var(--kc-border);
  }
  .panel[hidden] {
    display: none;
  }
  .controls,
  .parts {
    flex: 1 1 50%;
    min-height: 0;
    overflow: auto;
    padding: var(--kc-gap);
  }
  .controls {
    display: flex;
    flex-direction: column;
    gap: var(--kc-gap);
  }
  .parts {
    border-top: 1px solid var(--kc-border);
  }
  .caption {
    margin: 0 0 2px;
    color: var(--kc-muted);
    font-size: 0.92em;
  }
  .group {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(4.5em, 1fr));
    gap: 2px;
  }
  .group.modes {
    grid-template-columns: repeat(3, 1fr);
  }
  .group .caption {
    grid-column: 1 / -1;
  }
  .group button {
    padding: 2px 4px;
    font-size: 0.92em;
  }
  .parts ul {
    list-style: none;
    margin: 0;
    padding: 0;
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
  /* Tinted as a list's choice is (the desktop app's tree too), its edge in the accent */
  .parts button[aria-pressed='true'] {
    background: var(--kc-accent-subtle);
    border-color: var(--kc-accent);
  }
  .none {
    margin: 0;
    color: var(--kc-muted);
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
  /* How the run went, and what it said went wrong: a few lines, scrolled past them */
  .run {
    border-top: 1px solid var(--kc-border);
  }
  /* The run's status, the shortcuts' button at its end */
  .line {
    display: flex;
    align-items: center;
    gap: var(--kc-gap);
    min-height: 22px;
    padding: 1px var(--kc-gap);
  }
  .status {
    display: flex;
    align-items: center;
    gap: 6px;
    color: var(--kc-muted);
  }
  .shortcuts {
    display: grid;
    place-items: center;
    width: 24px;
    height: 20px;
    margin-left: auto;
    padding: 0;
    color: var(--kc-muted);
    background: none;
    border: none;
    border-radius: var(--kc-radius);
    cursor: pointer;
  }
  .shortcuts:hover {
    color: var(--kc-fg);
    background: var(--kc-hover);
  }
  .shortcuts:focus-visible {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .shortcuts svg {
    width: 16px;
    height: 16px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.5;
    stroke-linecap: round;
    stroke-linejoin: round;
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
  .problems {
    list-style: none;
    margin: 0;
    padding: 0 0 2px;
    max-height: 6.5em;
    overflow: auto;
  }
  .problems li {
    display: flex;
    gap: 6px;
    padding: 1px var(--kc-gap);
  }
  .problems button {
    display: flex;
    flex: 1;
    gap: 6px;
    min-width: 0;
    padding: 0;
    font: inherit;
    color: inherit;
    border: none;
    background: none;
    text-align: left;
    cursor: pointer;
  }
  .problems button:hover .message {
    text-decoration: underline;
  }
  .severity {
    flex: none;
    font-weight: 600;
  }
  .error .severity {
    color: var(--kc-error);
  }
  .warning .severity {
    color: var(--kc-warning);
  }
  .message {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .place {
    flex: none;
    color: var(--kc-muted);
  }
</style>
